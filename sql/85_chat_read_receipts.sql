-- 85. 관리자 대화방 읽음 표시 (2026-10-26 사용자: "대화방에서 카톡처럼 나한테만 누가 읽었는지 뜨면 좋겠는데")
-- 재실행해도 안전(create or replace).
--
--  · admin_chat_reads(p_room) → {ok, reads:[{name, status, read_at}]} — 그 방 학생마다 '여기까지 읽음'(sql/79 chat_student_reads).
--      학생 = 방 멤버(admin_chat_rooms 와 같은 기준: 기업방 = 그 기업 명단 학생, 1:1 = 그 학생). read_at 없으면 null(한 번도 안 염).
--      관리자(자기 센터 방)만. 학생 화면에는 읽음이 안 나감 — chat_student_reads 직접 접근은 그대로 막힘.
--  · '읽음' = 학생이 앱에서 그 방을 연 시각(my_chat_messages). 푸시만 보고 안 열면 안 읽음. 10/23 전 기록 없음.

create or replace function public.admin_chat_reads(p_room uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare au public.admin_users; r public.chat_rooms; v jsonb;
begin
  select * into au from admin_users where user_id = auth.uid();
  if au.user_id is null then return jsonb_build_object('ok', false, 'reason', 'auth'); end if;
  select * into r from chat_rooms where id = p_room and center_id = au.center_id;
  if r.id is null then return jsonb_build_object('ok', false, 'reason', 'room'); end if;
  select coalesce(jsonb_agg(jsonb_build_object('name', trim(s.name), 'status', s.status, 'read_at', cr.read_at) order by trim(s.name)), '[]'::jsonb)
    into v
    from students s
    left join chat_student_reads cr on cr.room_id = r.id and cr.student_id = s.id
   where s.center_id = au.center_id
     and ((r.kind = 'company' and _co_key(s.company) = r.company_key) or (r.kind = 'direct' and s.id = r.student_id));
  return jsonb_build_object('ok', true, 'reads', v);
end $$;

revoke all on function public.admin_chat_reads(uuid) from public, anon;
grant execute on function public.admin_chat_reads(uuid) to authenticated, service_role;
