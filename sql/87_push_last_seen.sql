-- 87. 알림 기기 '마지막 앱 사용' (2026-10-26 사용자: "삭제한것도 알 수 있나" → 앱 삭제는 직접 못 앎, 대신 마지막 사용일)
-- 재실행해도 안전(create or replace). sql/84·85 함수를 넓힘 — 기존 필드는 그대로.
--
--  · 마지막 사용 = push_tokens.updated_at 최댓값. 알림이 켜진 기기는 앱을 열 때 하루 1회 등록을 새로 고침(app.js) → 그 시각.
--    알림을 안 켠 기기·권한을 끈 기기(sql/86 으로 지워짐)는 값 없음. 오래된 날짜 = 앱을 안 열었거나 지웠을 가능성.
--  · admin_company_push_status() 행에 last_seen(그 기업 코드 기기 중 가장 최근).
--  · admin_chat_reads(p_room) 학생마다 last_seen(그 학생 기기 = device_key make_student_token(이름, 휴대폰), admin_chat_rooms 의 push 와 같은 기준).

create or replace function public.admin_company_push_status()
returns jsonb
language plpgsql security definer set search_path = public as $$
declare au public.admin_users; v jsonb;
begin
  select * into au from admin_users where user_id = auth.uid();
  if au.user_id is null then return jsonb_build_object('ok', false, 'reason', 'auth'); end if;
  with dev as (
    select _co_key(cc.company) k, count(distinct p.token)::int n, max(p.updated_at) seen
      from company_codes cc
      left join push_tokens p on p.device_key = _company_device_key(cc.code, cc.center_id) and p.token is not null
     where cc.center_id = au.center_id and cc.active and _co_key(cc.company) is not null
     group by 1
  ), reg as (
    select _co_key(r.company) k, count(*)::int n, max(r.created_at) last_at
      from registrations r
     where r.center_id = au.center_id and r.target_type = 'company' and _co_key(r.company) is not null
     group by 1
  )
  select coalesce(jsonb_agg(jsonb_build_object('key', coalesce(dev.k, reg.k), 'devices', coalesce(dev.n, 0),
                                               'signups', coalesce(reg.n, 0), 'last_signup', reg.last_at, 'last_seen', dev.seen)), '[]'::jsonb)
    into v
    from dev full join reg on reg.k = dev.k;
  return jsonb_build_object('ok', true, 'rows', v);
end $$;

create or replace function public.admin_chat_reads(p_room uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare au public.admin_users; r public.chat_rooms; v jsonb;
begin
  select * into au from admin_users where user_id = auth.uid();
  if au.user_id is null then return jsonb_build_object('ok', false, 'reason', 'auth'); end if;
  select * into r from chat_rooms where id = p_room and center_id = au.center_id;
  if r.id is null then return jsonb_build_object('ok', false, 'reason', 'room'); end if;
  select coalesce(jsonb_agg(jsonb_build_object('name', trim(s.name), 'status', s.status, 'read_at', cr.read_at,
           'last_seen', (select max(p.updated_at) from push_tokens p
                          where p.center_id = s.center_id and s.phone is not null and p.token is not null
                            and p.device_key = make_student_token(s.name, s.phone))) order by trim(s.name)), '[]'::jsonb)
    into v
    from students s
    left join chat_student_reads cr on cr.room_id = r.id and cr.student_id = s.id
   where s.center_id = au.center_id
     and ((r.kind = 'company' and _co_key(s.company) = r.company_key) or (r.kind = 'direct' and s.id = r.student_id));
  return jsonb_build_object('ok', true, 'reads', v);
end $$;

revoke all on function public.admin_company_push_status() from public, anon;
grant execute on function public.admin_company_push_status() to authenticated, service_role;
revoke all on function public.admin_chat_reads(uuid) from public, anon;
grant execute on function public.admin_chat_reads(uuid) to authenticated, service_role;
