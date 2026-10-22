-- =====================================================================
-- sql/75_daily_extras.sql — 매일 아침 올리는 출결 파일에 월 마감·전담인력수당을 함께 (2026-10-22)
--
-- 사용자 요청(10/22): "매일 아침 출결 점검에 수당 조회와 월 마감 상태를 붙여서 한 번에 올리게".
--   출결점검 scripts\app_export.py 가 만드는 app_upload_<YYYY-MM>.json 에 month_status·allowance 가 같이 실리고,
--   관리자 콘솔 [출결 결과 올리기]가 bulk_upsert_attendance_daily 다음에 이 함수를 부른다.
--
--  · admin_upload_status(p_month 'YYYY-MM', p_status jsonb, p_allowance jsonb) — 관리자(자기 센터)만.
--    p_status   = [{name, course, train_days, diary_days, student_confirmed_on, center_done, fetched}]
--        attendance_month_status 를 (센터, 이름, 그 달) 로 upsert. 학생 출석확인 날짜는 새 값이 있으면 그 값,
--        센터 확인(center_confirmed_on)은 center_done 이면 이미 있던 날짜를 두고 없으면 조회일(fetched)로 — 실제 확인일은
--        시스템 화면에 없어 '처음 확인된 날'로 근사. center_done 이 아니면 손대지 않음(손으로 넣은 값 보존).
--    p_allowance = {checked_at, companies: [{key, label, rows: [{period 'YYYY-MM', state, applied_on}]}]}
--        allowance_status 를 (센터, company_key, 그 달) 로 upsert. 그리고 그 기업들만, OJT 실적이 있는 지난달인데
--        시스템에 신청 기록이 없으면 '미신청'(조회하지 않은 기업은 건드리지 않음).
--  · 멱등(create or replace).
-- =====================================================================

create or replace function public.admin_upload_status(p_month text, p_status jsonb default '[]'::jsonb, p_allowance jsonb default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_center uuid; v_m date; r jsonb; c jsonb; x jsonb; n_ms int := 0; n_al int := 0; n_miss int := 0; k int; v_checked timestamptz;
begin
  if not exists (select 1 from admin_users au where au.user_id = auth.uid()) then raise exception 'not_admin'; end if;
  v_center := current_admin_center();
  if v_center is null then raise exception 'no_center'; end if;
  if coalesce(p_month, '') !~ '^\d{4}-\d{2}$' then raise exception 'bad_month'; end if;
  v_m := to_date(p_month || '-01', 'YYYY-MM-DD');

  for r in select * from jsonb_array_elements(coalesce(p_status, '[]'::jsonb)) loop
    if trim(coalesce(r->>'name', '')) = '' then continue; end if;
    insert into attendance_month_status as t (center_id, name, month, course, train_days, diary_days, student_confirmed_on, center_confirmed_on, updated_at)
    values (v_center, trim(r->>'name'), v_m, nullif(r->>'course', ''), nullif(r->>'train_days', '')::int, nullif(r->>'diary_days', '')::int,
            nullif(r->>'student_confirmed_on', '')::date,
            case when (r->>'center_done')::boolean then coalesce(nullif(r->>'fetched', '')::date, current_date) end, now())
    on conflict (center_id, (replace(trim(name), ' ', '')), month) do update
      set course = coalesce(excluded.course, t.course),
          train_days = coalesce(excluded.train_days, t.train_days),
          diary_days = coalesce(excluded.diary_days, t.diary_days),
          student_confirmed_on = coalesce(excluded.student_confirmed_on, t.student_confirmed_on),
          center_confirmed_on = coalesce(t.center_confirmed_on, excluded.center_confirmed_on),
          updated_at = now();
    n_ms := n_ms + 1;
  end loop;

  if p_allowance is not null then
    v_checked := coalesce(nullif(p_allowance->>'checked_at', '')::timestamptz, now());
    for c in select * from jsonb_array_elements(coalesce(p_allowance->'companies', '[]'::jsonb)) loop
      if coalesce(c->>'key', '') = '' then continue; end if;
      for x in select * from jsonb_array_elements(coalesce(c->'rows', '[]'::jsonb)) loop
        if coalesce(x->>'period', '') !~ '^\d{4}-\d{2}$'
           or coalesce(x->>'state', '') not in ('미신청', '신청', '승인', '확정', '지급완료') then continue; end if;
        insert into allowance_status (center_id, company_key, company_label, period, state, applied_on, checked_at)
        values (v_center, c->>'key', coalesce(nullif(c->>'label', ''), c->>'key'), to_date((x->>'period') || '-01', 'YYYY-MM-DD'),
                x->>'state', nullif(x->>'applied_on', '')::date, v_checked)
        on conflict (center_id, company_key, period) do update
          set state = excluded.state, applied_on = excluded.applied_on, company_label = excluded.company_label, checked_at = excluded.checked_at;
        n_al := n_al + 1;
      end loop;
      -- OJT 실적이 있는 지난달(이번 달 제외)인데 시스템 기록이 없으면 '미신청'
      with ojt as (
        select distinct m.month
          from attendance_monthly m
          join students s on s.center_id = m.center_id and replace(trim(s.name), ' ', '') = replace(trim(m.name), ' ', '')
         where m.center_id = v_center and m.track = 'ojt' and coalesce(m.actual_hours, 0) > 0
           and m.month < date_trunc('month', now() at time zone 'Asia/Seoul')::date
           and _co_key(s.company) = c->>'key'),
      miss as (
        select o.month from ojt o
         where not exists (select 1 from jsonb_array_elements(coalesce(c->'rows', '[]'::jsonb)) y
                            where y->>'period' = to_char(o.month, 'YYYY-MM')))
      insert into allowance_status (center_id, company_key, company_label, period, state, applied_on, checked_at)
      select v_center, c->>'key', coalesce(nullif(c->>'label', ''), c->>'key'), miss.month, '미신청', null, v_checked from miss
      on conflict (center_id, company_key, period) do update set state = '미신청', applied_on = null, checked_at = excluded.checked_at;
      get diagnostics k = row_count;
      n_miss := n_miss + k;
    end loop;
  end if;
  return jsonb_build_object('ok', true, 'month_status', n_ms, 'allowance', n_al, 'missing', n_miss);
end $$;
revoke all on function public.admin_upload_status(text, jsonb, jsonb) from public, anon;
grant execute on function public.admin_upload_status(text, jsonb, jsonb) to authenticated;
