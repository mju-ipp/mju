-- =====================================================================
-- sql/63_student_calendar.sql — 학생 앱 홈 달력: 지난달·OFF-JT 날짜별 + 능력단위 요소 (2026-10-16)
--
-- 목적: 학생 홈 '일정' 카드에서 ◀ ▶ 로 3월(OFF-JT)~2월(OJT)을 넘기며 관리자 학생 달력과 같은 내용을 본다.
--  1) my_attendance_days 에 p_month('YYYY-MM' 또는 'all', 선택) 추가 + course(수업일정 과목·능력단위) 반환.
--     홈 달력은 'all' 한 번으로 전 기간을 받아 캐시 — 호출 제한(10분 30회, IP 단위)에 걸리지 않게.
--     p_month 없으면 지금처럼 이번 달(KST). 옛 2인자 함수는 지우고 3인자(기본값)로 바꿈 —
--     PostgREST 는 같은 이름·같은 인자 이름의 겹치는 함수를 고르지 못하므로 겹치기 금지. 옛 프론트(2인자 호출)도 그대로 동작.
--  2) my_offjt_units — 내 OFF-JT 수업일정 행(attendance_daily track=offjt, course '수업일정 · …')에 나온
--     과목·능력단위로 offjt_units(학습안내서 시간·요소·수행과업)를 찾아 돌려줌. 같은 단위가 여러 직무에 있으면 내 직무 것 우선.
--     (2유형 융캡디·생성형 AI 처럼 학생 직무와 수업일정 직무가 다른 경우도 단위 이름으로 찾게)
--  · 본인 확인·호출 제한은 my_attendance_days(sql/55·61)·my_offjt_schedule(sql/62)과 같음. anon 직접 접근은 여전히 없음(RPC 만).
--  · 멱등: drop function if exists + create or replace.
-- =====================================================================

drop function if exists public.my_attendance_days(text, text);

create or replace function public.my_attendance_days(p_code text default null::text, p_token text default null::text, p_month text default null::text)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare ip text; v_name text; v_center uuid; v_from date; v_to date; v_days jsonb; v_fetched timestamptz;
begin
  ip := coalesce(current_setting('request.headers', true)::jsonb ->> 'x-forwarded-for', 'unknown');
  begin
    perform check_verify_rate('attnd:' || ip);
  exception when undefined_function then null;
  end;
  if coalesce(p_code, '') <> '' then
    select sc.name, sc.center_id into v_name, v_center from student_codes sc
     where sc.code = upper(regexp_replace(p_code, '[^A-Za-z0-9]', '', 'g')) and sc.active;
  end if;
  if v_name is null and char_length(coalesce(p_token, '')) >= 20 then
    select s.name, s.center_id into v_name, v_center from students s
     where s.phone is not null and make_student_token(s.name, s.phone) = p_token
     limit 1;
  end if;
  if v_name is null then
    return jsonb_build_object('ok', false);
  end if;

  if p_month = 'all' then   -- 학생 홈 달력: 전 기간 한 번에(달 넘길 때마다 부르면 같은 와이파이 학생들이 호출 제한에 걸림)
    v_from := date '1900-01-01'; v_to := date '2999-01-01';
  elsif coalesce(p_month, '') ~ '^\d{4}-\d{2}$' then
    v_from := to_date(p_month || '-01', 'YYYY-MM-DD');
    v_to := (v_from + interval '1 month')::date;
  else
    v_from := date_trunc('month', (now() at time zone 'Asia/Seoul'))::date;
    v_to := (v_from + interval '1 month')::date;
  end if;
  select coalesce(jsonb_agg(jsonb_build_object(
           'day', to_char(a.day, 'YYYY-MM-DD'),
           'track', a.track,
           'start', to_char(a.start_time, 'HH24:MI'),
           'end', to_char(a.end_time, 'HH24:MI'),
           'planned', a.planned_hours,
           'recognized', a.recognized_hours,
           'in', a.in_time, 'out', a.out_time,
           'status', a.status,
           'course', a.course) order by a.day, a.track), '[]'::jsonb),
         max(a.fetched_at)
    into v_days, v_fetched
    from attendance_daily a
   where a.center_id = v_center
     and replace(trim(a.name), ' ', '') = replace(trim(v_name), ' ', '')
     and a.day >= v_from and a.day < v_to;
  return jsonb_build_object('ok', true, 'month', case when p_month = 'all' then 'all' else to_char(v_from, 'YYYY-MM') end,
                            'fetched_at', v_fetched, 'days', v_days);
end $function$;
revoke all on function public.my_attendance_days(text, text, text) from public;
grant execute on function public.my_attendance_days(text, text, text) to anon, authenticated, service_role;

create or replace function public.my_offjt_units(p_code text default null, p_token text default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare ip text; v_name text; v_center uuid; v_jobs text[]; v_year int; v_units jsonb;
begin
  ip := coalesce(current_setting('request.headers', true)::jsonb ->> 'x-forwarded-for', 'unknown');
  begin
    perform check_verify_rate('offjt:' || ip);
  exception when undefined_function then null;
  end;
  if coalesce(p_code, '') <> '' then
    select sc.name, sc.center_id into v_name, v_center from student_codes sc
     where sc.code = upper(regexp_replace(p_code, '[^A-Za-z0-9]', '', 'g')) and sc.active;
  end if;
  if v_name is null and char_length(coalesce(p_token, '')) >= 20 then
    select st.name, st.center_id into v_name, v_center from students st
     where st.phone is not null and make_student_token(st.name, st.phone) = p_token
     limit 1;
  end if;
  if v_name is null then return jsonb_build_object('ok', false); end if;

  -- 같은 이름이 여러 기수면 진행중 → 최근 기수 우선(sql/62 와 같음)
  select st.job_keys, (substring(coalesce(st.cohort, '') from '(\d{4})'))::int into v_jobs, v_year
    from students st
   where st.center_id = v_center and replace(trim(st.name), ' ', '') = replace(trim(v_name), ' ', '')
   order by (st.status = '진행중') desc nulls last, st.cohort desc nulls last
   limit 1;

  with pairs as (   -- 내 수업일정 행의 '과목·능력단위' 쌍
    select distinct trim(split_part(x, '·', 1)) s, trim(substr(x, strpos(x, '·') + 1)) u, extract(year from a.day)::int y
      from attendance_daily a,
           regexp_split_to_table(regexp_replace(a.course, '^수업일정\s*·\s*', ''), ' / ') x
     where a.center_id = v_center and a.track = 'offjt' and a.course like '수업일정%'
       and replace(trim(a.name), ' ', '') = replace(trim(v_name), ' ', '')
       and strpos(x, '·') > 0
  ), pick as (
    select distinct on (u.subject, u.unit) u.subject, u.unit, u.hours, u.elements, u.sort
      from offjt_units u join pairs p on u.subject = p.s and u.unit = p.u and u.year = coalesce(v_year, p.y)
     where u.center_id = v_center
     order by u.subject, u.unit, (u.job_key = any(coalesce(v_jobs, '{}'::text[]))) desc, u.updated_at desc
  )
  select coalesce(jsonb_agg(jsonb_build_object('subject', subject, 'unit', unit, 'hours', hours, 'elements', elements)
           order by sort, subject, unit), '[]'::jsonb)
    into v_units from pick;
  return jsonb_build_object('ok', true, 'units', v_units);
end $$;
revoke all on function public.my_offjt_units(text, text) from public;
grant execute on function public.my_offjt_units(text, text) to anon, authenticated, service_role;
