-- 83. 기업에 알림 보내기 버튼 (2026-10-23 사용자: "학습일지 출석 눌러달라는 거랑 전담인력수당 신청 알람도 보낼 수 있게" → 받는 쪽 기업, 버튼으로)
-- 재실행해도 안전(create or replace).
--
--  · admin_company_push_status() → {ok, rows:[{key, devices}]} — 내 센터 기업마다 알림을 켠 기업 기기 수.
--      기업 기기 = push_tokens.device_key = _company_device_key(그 기업 활성 코드)(sql/78 — 기업 코드로 알림을 켠 기기).
--  · admin_company_nudge(p_kind, p_keys, p_title, p_body) — 관리자(자기 센터)만. 고른 기업(기업 키 _co_key)의 기업 기기에 개인 알림
--      (notices personal + notice_recipients, push-sender 가 device_key 로 발송). 문구는 관리자가 화면에서 고쳐 보냄.
--      p_kind = 'diary'(학습일지·출석 확인 요청) | 'allowance'(전담인력수당 신청) — 기록·중복 방지용.
--      같은 종류를 10분 안에 또 보내면 'recent'(두 번 눌림 방지). 기기가 없는 기업은 no_device 로 돌려줌(화면에 표시).

create or replace function public.admin_company_push_status()
returns jsonb
language plpgsql security definer set search_path = public as $$
declare au public.admin_users; v jsonb;
begin
  select * into au from admin_users where user_id = auth.uid();
  if au.user_id is null then return jsonb_build_object('ok', false, 'reason', 'auth'); end if;
  select coalesce(jsonb_agg(jsonb_build_object('key', k, 'devices', n)), '[]'::jsonb) into v from (
    select _co_key(cc.company) k, count(distinct p.token)::int n
      from company_codes cc
      left join push_tokens p on p.device_key = _company_device_key(cc.code, cc.center_id) and p.token is not null
     where cc.center_id = au.center_id and cc.active and _co_key(cc.company) is not null
     group by 1
  ) x;
  return jsonb_build_object('ok', true, 'rows', v);
end $$;

create or replace function public.admin_company_nudge(p_kind text, p_keys text[], p_title text, p_body text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  au public.admin_users; v_title text := btrim(coalesce(p_title, '')); v_body text := btrim(coalesce(p_body, ''));
  v_notice uuid; n int := 0; v_cos int := 0; v_none jsonb;
begin
  select * into au from admin_users where user_id = auth.uid();
  if au.user_id is null then return jsonb_build_object('ok', false, 'reason', 'auth'); end if;
  if coalesce(p_kind, '') not in ('diary', 'allowance') then return jsonb_build_object('ok', false, 'reason', 'kind'); end if;
  if v_title = '' or char_length(v_title) > 80 or v_body = '' or char_length(v_body) > 1000 then
    return jsonb_build_object('ok', false, 'reason', 'length');
  end if;
  if coalesce(array_length(p_keys, 1), 0) = 0 then return jsonb_build_object('ok', false, 'reason', 'none'); end if;
  if exists (select 1 from notices where center_id = au.center_id and created_by like 'admin:co-nudge-' || p_kind || '-%'
               and created_at > now() - interval '10 minutes') then
    return jsonb_build_object('ok', false, 'reason', 'recent');
  end if;

  -- 고른 기업 중 활성 코드가 있는 곳 → 그 코드로 알림을 켠 기기
  create temp table if not exists _cn_dev (k text, label text, dk text) on commit drop;
  delete from _cn_dev;
  insert into _cn_dev
  select distinct _co_key(cc.company), trim(cc.company), _company_device_key(cc.code, cc.center_id)
    from company_codes cc
   where cc.center_id = au.center_id and cc.active and _co_key(cc.company) = any (p_keys);
  select count(distinct k) into v_cos from _cn_dev;
  select coalesce(jsonb_agg(distinct d.label), '[]'::jsonb) into v_none from _cn_dev d
   where not exists (select 1 from push_tokens p where p.device_key = d.dk and p.token is not null);

  if exists (select 1 from _cn_dev d join push_tokens p on p.device_key = d.dk and p.token is not null) then
    insert into notices (center_id, title, body, target_scope, published, created_by, pushed)
    values (au.center_id, v_title, v_body, 'personal', true,
            'admin:co-nudge-' || p_kind || '-' || to_char(now() at time zone 'Asia/Seoul', 'MMDDHH24MISS'), false)
    returning id into v_notice;
    insert into notice_recipients (notice_id, student_token, title, body, center_id)
    select distinct v_notice, d.dk, v_title, v_body, au.center_id
      from _cn_dev d where exists (select 1 from push_tokens p where p.device_key = d.dk and p.token is not null);
    get diagnostics n = row_count;
    begin
      perform net.http_get('https://ggitgqijycvnhhraxzgn.supabase.co/functions/v1/push-sender');
    exception when others then null;
    end;
  end if;
  return jsonb_build_object('ok', true, 'sent', n, 'companies', v_cos, 'no_device', v_none);
end $$;

revoke all on function public.admin_company_push_status() from public, anon;
revoke all on function public.admin_company_nudge(text, text[], text, text) from public, anon;
grant execute on function public.admin_company_push_status() to authenticated, service_role;
grant execute on function public.admin_company_nudge(text, text[], text, text) to authenticated, service_role;
