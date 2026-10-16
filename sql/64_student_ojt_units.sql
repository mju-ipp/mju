-- =====================================================================
-- sql/64_student_ojt_units.sql — 학생 홈 달력 OJT 날: 그 달 능력단위의 학습내용(요소·수행과업) (2026-10-16)
--
-- 목적: OFF-JT 처럼 OJT 날짜를 눌러도 그 달 능력단위(attendance_monthly track=ojt 의 units)의 시간·요소·수행과업이 보이게.
--  · 데이터: offjt_units 에 학생별 OJT 행(job_key 'OJT:<이름>', subject 'OJT', unit = 월 행 units 의 이름 그대로).
--    같은 단위라도 과정(학습안내서)마다 시간이 달라 학생별로 둠. 요소·수행과업은 각 학생 과정 학습안내서(03_과정개발) 기준.
--  · my_offjt_units 가 위 OJT 행도 함께 돌려줌(subject='OJT'). 인자·권한·호출 제한은 sql/63 과 같음.
--  · 멱등: create or replace.
-- =====================================================================

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
  ), ojt as (   -- 내 OJT 능력단위(학생마다 한 벌: job_key 'OJT:<이름>', unit = 월 행 units 이름)
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
revoke all on function public.my_offjt_units(text, text) from public;
grant execute on function public.my_offjt_units(text, text) to anon, authenticated, service_role;
