-- 84. 관리자 기업·초대코드 줄에 가입·알림 표시 (2026-10-26 사용자: "앱에서 기업이 가입했는지, 몇명인지 알림은 켰는지도 표시되어야")
-- 재실행해도 안전(create or replace). sql/83 admin_company_push_status 를 넓힘 — 기존 필드(key, devices)는 그대로.
--
--  · admin_company_push_status() → {ok, rows:[{key, devices, signups, last_signup}]}
--      devices     = 그 기업 활성 코드로 알림을 켠 기기 수(sql/83 그대로)
--      signups     = 내 센터 registrations 중 target_type 'company' 가입 건수(기업 키 _co_key 로 묶음)
--                    ※ 기업 가입은 이름 = 기업명·휴대폰 '' 라 사람을 못 가림 → '다시 가입'도 한 건으로 셈(사람 수 아님)
--      last_signup = 마지막 가입 시각
--      기업 = 활성 코드가 있거나 가입 기록이 있는 곳(코드를 끈 뒤에도 가입 기록은 보이게).

create or replace function public.admin_company_push_status()
returns jsonb
language plpgsql security definer set search_path = public as $$
declare au public.admin_users; v jsonb;
begin
  select * into au from admin_users where user_id = auth.uid();
  if au.user_id is null then return jsonb_build_object('ok', false, 'reason', 'auth'); end if;
  with dev as (
    select _co_key(cc.company) k, count(distinct p.token)::int n
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
                                               'signups', coalesce(reg.n, 0), 'last_signup', reg.last_at)), '[]'::jsonb)
    into v
    from dev full join reg on reg.k = dev.k;
  return jsonb_build_object('ok', true, 'rows', v);
end $$;

revoke all on function public.admin_company_push_status() from public, anon;
grant execute on function public.admin_company_push_status() to authenticated, service_role;
