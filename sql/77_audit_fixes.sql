-- 77. 앱 점검(2026-10-23) 급한 수정 — 학생 조회 호출 제한 · 기업 정보 조회 · 기업 휴가·출장 취소
-- 재실행해도 안전(create or replace / drop if exists).
--
-- ① my_attendance / my_attendance_days / my_offjt_units
--    전엔 호출할 때마다 IP 기준으로 셌음(10분 30회) → 같은 와이파이(OFF-JT 강의실)에서 학생 20명이 홈을 두 번씩 열면
--    출석 카드가 사라짐. 이제 코드·토큰이 안 맞을 때(=찍어 보기)만 센다. 맞는 학생의 조회는 세지 않음.
-- ② my_company_info — 기업명만 보내면 그 기업 담당자 이름·비콘·출퇴근 안내가 나왔음(코드 불필요).
--    이제 학생 코드·토큰 또는 기업 코드로 서버가 기업을 정한다. p_company 는 받지 않음.
-- ③ company_absence_cancel — 기업은 기업이 알린 휴가·출장(by_role='company')만 취소. 학생·센터가 넣은 건 못 지움.
--    company_absence — 지난 날짜(오늘 이전, 한국 시각)는 받지 않음(화면에만 있던 제한을 서버에도).

-- ① 학생 조회 3종 ---------------------------------------------------------------------------
create or replace function public.my_attendance(p_code text default null, p_token text default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare ip text; rows jsonb; v_name text; v_center uuid;
begin
  if coalesce(p_code, '') <> '' then
    select sc.name, sc.center_id into v_name, v_center from student_codes sc
     where sc.code = upper(regexp_replace(p_code, '[^A-Za-z0-9]', '', 'g')) and sc.active;
  end if;
  if v_name is null and char_length(coalesce(p_token, '')) >= 20 then
    select s.name, s.center_id into v_name, v_center from students s
     where make_student_token(s.name, s.phone) = p_token
     limit 1;
  end if;
  if v_name is null then
    ip := coalesce(current_setting('request.headers', true)::jsonb ->> 'x-forwarded-for', 'unknown');
    begin perform check_verify_rate('attn:' || ip); exception when undefined_function then null; end;
    return jsonb_build_object('ok', false);
  end if;
  select coalesce(jsonb_agg(jsonb_build_object(
           'month', to_char(a.month, 'YYYY-MM'),
           'track', a.track,
           'planned', a.planned_hours,
           'actual', a.actual_hours,
           'units', a.units,
           'source', a.source,
           'updated_at', a.updated_at) order by a.month, a.track), '[]'::jsonb)
    into rows
    from attendance_monthly a
   where a.center_id = v_center
     and replace(trim(a.name), ' ', '') = replace(trim(v_name), ' ', '');
  return jsonb_build_object('ok', true, 'rows', rows);
end $$;

create or replace function public.my_attendance_days(p_code text default null, p_token text default null, p_month text default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare ip text; v_name text; v_center uuid; v_from date; v_to date; v_days jsonb; v_fetched timestamptz;
begin
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
    ip := coalesce(current_setting('request.headers', true)::jsonb ->> 'x-forwarded-for', 'unknown');
    begin perform check_verify_rate('attnd:' || ip); exception when undefined_function then null; end;
    return jsonb_build_object('ok', false);
  end if;

  if p_month = 'all' then   -- 학생 홈 달력: 전 기간 한 번에
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
end $$;

create or replace function public.my_offjt_units(p_code text default null, p_token text default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare ip text; v_name text; v_center uuid; v_jobs text[]; v_year int; v_units jsonb;
begin
  if coalesce(p_code, '') <> '' then
    select sc.name, sc.center_id into v_name, v_center from student_codes sc
     where sc.code = upper(regexp_replace(p_code, '[^A-Za-z0-9]', '', 'g')) and sc.active;
  end if;
  if v_name is null and char_length(coalesce(p_token, '')) >= 20 then
    select st.name, st.center_id into v_name, v_center from students st
     where st.phone is not null and make_student_token(st.name, st.phone) = p_token
     limit 1;
  end if;
  if v_name is null then
    ip := coalesce(current_setting('request.headers', true)::jsonb ->> 'x-forwarded-for', 'unknown');
    begin perform check_verify_rate('offjt:' || ip); exception when undefined_function then null; end;
    return jsonb_build_object('ok', false);
  end if;

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
  ), ojt as (   -- 내 OJT 능력단위(학생마다 한 벌: job_key 'OJT:<이름>')
    select u.subject, u.unit, u.hours, u.elements, u.sort
      from offjt_units u
     where u.center_id = v_center and u.subject = 'OJT'
       and u.job_key = 'OJT:' || replace(trim(v_name), ' ', '')
       and (v_year is null or u.year = v_year)
  ), allu as (
    select * from pick union all select * from ojt
  )
  select coalesce(jsonb_agg(jsonb_build_object('subject', subject, 'unit', unit, 'hours', hours, 'elements', elements)
           order by sort, subject, unit), '[]'::jsonb)
    into v_units from allu;
  return jsonb_build_object('ok', true, 'units', v_units);
end $$;

-- ② 내 학습기업 안내 — 코드·토큰으로만 ---------------------------------------------------------
drop function if exists public.my_company_info(text);
create or replace function public.my_company_info(p_code text default null, p_token text default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare ip text; v_center uuid; v_company text; v_name text; norm_in text; ci record; cc public.company_codes;
begin
  -- 기업 코드 → 그 기업
  if coalesce(p_code, '') <> '' then
    select * into cc from company_codes
     where code = upper(regexp_replace(p_code, '[^A-Za-z0-9]', '', 'g')) and active;
    if cc.code is not null then v_center := cc.center_id; v_company := cc.company; end if;
  end if;
  -- 학생 코드 → 그 학생의 기업
  if v_company is null and coalesce(p_code, '') <> '' then
    select sc.name, sc.center_id into v_name, v_center from student_codes sc
     where sc.code = upper(regexp_replace(p_code, '[^A-Za-z0-9]', '', 'g')) and sc.active;
  end if;
  if v_company is null and v_name is null and char_length(coalesce(p_token, '')) >= 20 then
    select s.name, s.center_id into v_name, v_center from students s
     where s.phone is not null and make_student_token(s.name, s.phone) = p_token
     limit 1;
  end if;
  if v_company is null and v_name is not null then
    select s.company into v_company from students s
     where s.center_id = v_center and replace(trim(s.name), ' ', '') = replace(trim(v_name), ' ', '')
     order by (s.status = '진행중') desc nulls last, s.cohort desc nulls last
     limit 1;
  end if;
  if v_company is null then
    ip := coalesce(current_setting('request.headers', true)::jsonb ->> 'x-forwarded-for', 'unknown');
    begin perform check_verify_rate('coinfo:' || ip); exception when undefined_function then null; end;
    return null;
  end if;

  norm_in := replace(replace(replace(replace(lower(v_company), '㈜', ''), '(주)', ''), '주식회사', ''), ' ', '');
  select * into ci from public.company_info
   where center_id = v_center
     and replace(replace(replace(replace(lower(company), '㈜', ''), '(주)', ''), '주식회사', ''), ' ', '') = norm_in
   limit 1;

  return jsonb_build_object(
    'company', coalesce(ci.company, v_company),
    'info', case when ci.company is null then null else
      jsonb_build_object('beacon', ci.beacon, 'commute', ci.commute, 'schedule', ci.schedule, 'extra', ci.extra, 'updated_at', ci.updated_at) end,
    'contacts', coalesce((
      select jsonb_agg(jsonb_build_object('role', c2.role, 'name', c2.name) order by c2.role)
        from public.company_contacts c2
       where c2.center_id = v_center
         and coalesce(c2.status, '') <> '종료'
         and c2.name is not null and c2.name <> ''
         and replace(replace(replace(replace(lower(c2.company), '㈜', ''), '(주)', ''), '주식회사', ''), ' ', '') = norm_in
    ), '[]'::jsonb)
  );
end $$;
grant execute on function public.my_company_info(text, text) to anon, authenticated;

-- ③ 기업 휴가·출장 --------------------------------------------------------------------------
create or replace function public.company_absence_cancel(p_code text default null, p_id uuid default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare c public.company_codes; ex public.attendance_absences;
begin
  c := _company_me(p_code);
  if c.code is null then return jsonb_build_object('ok', false); end if;
  select a.* into ex from attendance_absences a join students s on s.id = a.student_id
   where a.id = p_id and a.center_id = c.center_id and _co_key(s.company) = _co_key(c.company);
  if ex.id is null then return jsonb_build_object('ok', false, 'reason', 'not_found'); end if;
  if ex.by_role <> 'company' then return jsonb_build_object('ok', false, 'reason', 'not_mine'); end if;   -- 학생·센터가 넣은 건 기업이 못 지움
  if ex.state <> 'open' then return jsonb_build_object('ok', false, 'reason', ex.state); end if;
  update attendance_absences set state = 'canceled', updated_at = now() where id = ex.id;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.company_absence(p_code text default null, p_student uuid default null, p_day date default null,
                                                  p_kind text default null, p_note text default null, p_by_name text default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare c public.company_codes; st public.students; v_by text := nullif(left(btrim(coalesce(p_by_name, '')), 40), '');
begin
  c := _company_me(p_code);
  if c.code is null then return jsonb_build_object('ok', false); end if;
  if p_day is null or p_day < (now() at time zone 'Asia/Seoul')::date then return jsonb_build_object('ok', false, 'reason', 'past'); end if;
  select * into st from students s
   where s.id = p_student and s.center_id = c.center_id and _co_key(s.company) = _co_key(c.company);
  if st.id is null then return jsonb_build_object('ok', false, 'reason', 'student'); end if;
  if (select count(*) from attendance_absences a join students s2 on s2.id = a.student_id
       where a.center_id = c.center_id and a.by_role = 'company' and _co_key(s2.company) = _co_key(c.company)
         and a.updated_at > now() - interval '10 minutes') >= 60 then
    return jsonb_build_object('ok', false, 'reason', 'rate');
  end if;
  return _absence_put(st, p_day, p_kind, p_note, 'company', coalesce(v_by, '기업 담당자'), null);
end $$;
