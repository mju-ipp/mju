-- =====================================================================
-- sql/67_chat_push.sql — 대화방 4단계: 선생님 글 푸시 대상 (2026-10-16, docs/CHAT.md)
--
--  · chat_push_pending(p_limit) — push-sender(service_role)만. push_state='pending' 인 선생님 글과 받을 기기 토큰.
--      받는 사람 = 그 방 명단 학생(기업방: 같은 센터·_co_key(students.company) = 방 company_key / 1:1: 그 student_id)
--      기기 = push_tokens.device_key = make_student_token(이름, 전화) — 관리자 콘솔 '알림 n/m'(sql/66)과 같은 기준.
--      push_tokens.company 로 고르지 않는 이유: 그 칸은 기기가 등록할 때 클라가 보낸 값이라, 회사를 옮긴 학생·
--      다른 사람 기기가 섞일 수 있음. 명단 + 서명토큰이면 방 사람과 받는 사람이 정확히 같다.
--  · 숨긴 글·하루 넘게 밀린 글은 보내지 않고 'none' 으로 정리(배포 직후 옛 글이 한꺼번에 울리지 않게).
--  · 'sent' 표시는 발송기가 함(보내기 직전 pending→sent 선점, 공지 pushed 와 같은 방식 — 5분 폴링과 즉시 킥이 겹쳐도 한 번만).
--  · 멱등.
-- =====================================================================

create or replace function public.chat_push_pending(p_limit int default 20)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v jsonb;
begin
  update chat_messages set push_state = 'none'
   where push_state = 'pending' and (hidden or created_at < now() - interval '1 day');

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', m.id, 'room_id', m.room_id, 'center_id', m.center_id, 'kind', r.kind,
           'room_title', case when r.kind = 'company' then r.company_label else '선생님 1:1' end,
           'log_target', case when r.kind = 'company' then r.company_label else r.student_name end,   -- 발송 기록용
           'sender_name', m.sender_name, 'body', left(m.body, 300),
           'tokens', (select coalesce(jsonb_agg(distinct jsonb_build_object('id', p.id, 'token', p.token)), '[]'::jsonb)
                        from students s
                        join push_tokens p on p.center_id = s.center_id and s.phone is not null
                                          and p.device_key = make_student_token(s.name, s.phone)
                       where s.center_id = m.center_id and p.token is not null
                         and ((r.kind = 'company' and _co_key(s.company) = r.company_key)
                           or (r.kind = 'direct' and s.id = r.student_id))))
           order by m.created_at), '[]'::jsonb)
    into v
    from (select * from chat_messages
           where push_state = 'pending' and sender = 'teacher'
           order by created_at limit greatest(1, least(coalesce(p_limit, 20), 50))) m
    join chat_rooms r on r.id = m.room_id and r.center_id = m.center_id;
  return v;
end $$;

revoke all on function public.chat_push_pending(int) from public, anon, authenticated;
grant execute on function public.chat_push_pending(int) to service_role;
