-- =====================================================================
-- 89_ojt_daily_units.sql — OJT 일별 능력단위 시수 (docs/OJT_DAILY_UNITS.md 1단계)
--  · ojt_unit_month  — 행정지원시스템 시간표의 학생 × 월 × 능력단위 배정 시간(원천). sort = 그 달 배분 순서.
--  · ojt_unit_daily  — 학생 × 날짜 × 능력단위 시간(화면이 읽는 결과). src auto(자동 배분) | teacher(기업 화면) | admin.
--  · ojt_unit_state  — 학생 × 월 마지막 배분 때의 정규시간 지문(plan_sig). 지문이 바뀌면(휴가·출장으로 옮김, 출결 올리기)
--                       다음 조회 때 자동으로 다시 배분 → 출결 올리기 코드는 손대지 않는다.
--  · 배분 규칙: 그 달 정규시간(attendance_daily, ojt, planned>0) 날짜 순 × 능력단위 sort 순. 하루 중간에 능력단위가 끝나면
--    그날은 두 줄. 고정(teacher·admin) 날은 그대로 두고 그 시간만큼 먼저 뺀다. 정규시간 합 > 능력단위 합이면 넘치는 시간은
--    마지막 능력단위에, 모자라면 뒤 능력단위가 덜 채워짐(관리자 보고서에 표시).
--  · 기업 화면 수정은 기업 코드만 있으면 누구나(by_name 필수). 월 합계(능력단위별)가 바뀌는 수정은 저장하지 않는다(사용자 11/5).
--  · RPC: my_ojt_daily_units(학생) · company_ojt_units / company_set_daily_units / company_reset_daily_units(기업)
--         admin_upsert_unit_month / admin_ojt_unit_report(관리자)
--  · rls-check MUST_BE_BLOCKED 에 세 표. 멱등.
-- =====================================================================

create table if not exists public.ojt_unit_month (
  id          uuid primary key default gen_random_uuid(),
  center_id   uuid not null references public.centers(id),
  name        text not null,
  month       date not null,                 -- 그 달 1일
  unit        text not null,
  hours       numeric not null check (hours > 0),
  sort        int not null default 0,        -- 그 달 배분 순서(먼저 시작한 능력단위 → 평가 시기 빠른 것 → NO)
  eval_month  text,                          -- 내부평가 시기 YYYY-MM(선택)
  course      text,                          -- 시간표 파일·과정 이름(표시용)
  updated_by  text,
  updated_at  timestamptz not null default now()
);
create unique index if not exists ojt_unit_month_uniq
  on public.ojt_unit_month (center_id, (replace(trim(name), ' ', '')), month, unit);

create table if not exists public.ojt_unit_daily (
  id          uuid primary key default gen_random_uuid(),
  center_id   uuid not null references public.centers(id),
  name        text not null,
  day         date not null,
  unit        text not null,
  hours       numeric not null check (hours > 0),
  src         text not null default 'auto' check (src in ('auto', 'teacher', 'admin')),
  by_name     text,
  updated_at  timestamptz not null default now()
);
create unique index if not exists ojt_unit_daily_uniq
  on public.ojt_unit_daily (center_id, (replace(trim(name), ' ', '')), day, unit);
create index if not exists ojt_unit_daily_day on public.ojt_unit_daily (center_id, day);

create table if not exists public.ojt_unit_state (
  center_id   uuid not null references public.centers(id),
  name_key    text not null,
  month       date not null,
  plan_sig    text,
  built_at    timestamptz not null default now(),
  primary key (center_id, name_key, month)
);

alter table public.ojt_unit_month enable row level security;
alter table public.ojt_unit_daily enable row level security;
alter table public.ojt_unit_state enable row level security;

drop policy if exists "ojt unit month admin all" on public.ojt_unit_month;
create policy "ojt unit month admin all" on public.ojt_unit_month
  for all to public
  using (is_super_admin() or center_id = current_admin_center())
  with check (is_super_admin() or center_id = current_admin_center());
drop policy if exists "ojt unit daily admin all" on public.ojt_unit_daily;
create policy "ojt unit daily admin all" on public.ojt_unit_daily
  for all to public
  using (is_super_admin() or center_id = current_admin_center())
  with check (is_super_admin() or center_id = current_admin_center());
drop policy if exists "ojt unit state admin all" on public.ojt_unit_state;
create policy "ojt unit state admin all" on public.ojt_unit_state
  for all to public
  using (is_super_admin() or center_id = current_admin_center())
  with check (is_super_admin() or center_id = current_admin_center());

-- ── 내부: 이름 키 ──
create or replace function public._ojt_key(p text)
returns text language sql immutable set search_path = public as $$
  select replace(trim(coalesce(p, '')), ' ', '')
$$;

-- ── 내부: 그 달 정규시간 지문 ──
create or replace function public._ojt_plan_sig(p_center uuid, p_name text, p_month date)
returns text language sql stable security definer set search_path = public as $$
  select md5(coalesce(string_agg(to_char(a.day, 'MMDD') || ':' || a.planned_hours::text, ',' order by a.day), '')
             || '|' || coalesce((select string_agg(m.unit || ':' || m.hours::text || ':' || m.sort::text, ',' order by m.sort, m.unit)
                                   from ojt_unit_month m
                                  where m.center_id = p_center and _ojt_key(m.name) = _ojt_key(p_name) and m.month = p_month), ''))
    from attendance_daily a
   where a.center_id = p_center and a.track = 'ojt' and coalesce(a.planned_hours, 0) > 0
     and _ojt_key(a.name) = _ojt_key(p_name)
     and a.day >= p_month and a.day < (p_month + interval '1 month')::date
$$;
revoke all on function public._ojt_plan_sig(uuid, text, date) from public, anon, authenticated;

-- ── 내부: 다시 배분 ──
create or replace function public._ojt_units_rebuild(p_center uuid, p_name text, p_month date)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_key text := _ojt_key(p_name);
  v_to date := (p_month + interval '1 month')::date;
  u_name text[]; u_left numeric[]; n int; i int := 1;
  d record; h numeric; take numeric; v_over numeric := 0; v_dropped int := 0;
  v_planned numeric; v_units numeric;
begin
  -- 정규시간이 없어졌거나 시간이 바뀐 날의 고정 행은 지움(옮겨진 날)
  with plan as (
    select a.day, a.planned_hours from attendance_daily a
     where a.center_id = p_center and a.track = 'ojt' and coalesce(a.planned_hours, 0) > 0
       and _ojt_key(a.name) = v_key and a.day >= p_month and a.day < v_to
  ), fixed as (
    select f.day, sum(f.hours) s from ojt_unit_daily f
     where f.center_id = p_center and _ojt_key(f.name) = v_key and f.src <> 'auto'
       and f.day >= p_month and f.day < v_to
     group by f.day
  ), bad as (
    select x.day from fixed x left join plan p on p.day = x.day
     where p.day is null or p.planned_hours <> x.s
  )
  delete from ojt_unit_daily f using bad
   where f.center_id = p_center and _ojt_key(f.name) = v_key and f.src <> 'auto' and f.day = bad.day;
  get diagnostics v_dropped = row_count;

  delete from ojt_unit_daily f
   where f.center_id = p_center and _ojt_key(f.name) = v_key and f.src = 'auto'
     and f.day >= p_month and f.day < v_to;

  -- 능력단위별 남은 시간 = 배정 − 고정
  select array_agg(m.unit order by m.sort, m.unit),
         array_agg(m.hours - coalesce((select sum(f.hours) from ojt_unit_daily f
                                        where f.center_id = p_center and _ojt_key(f.name) = v_key and f.src <> 'auto'
                                          and f.unit = m.unit and f.day >= p_month and f.day < v_to), 0)
                   order by m.sort, m.unit)
    into u_name, u_left
    from ojt_unit_month m
   where m.center_id = p_center and _ojt_key(m.name) = v_key and m.month = p_month;
  n := coalesce(array_length(u_name, 1), 0);

  if n > 0 then
    for d in
      select a.day, a.planned_hours from attendance_daily a
       where a.center_id = p_center and a.track = 'ojt' and coalesce(a.planned_hours, 0) > 0
         and _ojt_key(a.name) = v_key and a.day >= p_month and a.day < v_to
         and not exists (select 1 from ojt_unit_daily f
                          where f.center_id = p_center and _ojt_key(f.name) = v_key and f.src <> 'auto' and f.day = a.day)
       order by a.day
    loop
      h := d.planned_hours;
      while h > 0 and i <= n loop
        take := least(h, greatest(u_left[i], 0));
        if take > 0 then
          insert into ojt_unit_daily (center_id, name, day, unit, hours, src)
          values (p_center, trim(p_name), d.day, u_name[i], take, 'auto');
          h := h - take; u_left[i] := u_left[i] - take;
        end if;
        if u_left[i] <= 0 then i := i + 1; end if;
      end loop;
      if h > 0 then   -- 능력단위 시간을 다 쓴 뒤 남는 정규시간 → 마지막 능력단위에 더함
        v_over := v_over + h;
        insert into ojt_unit_daily (center_id, name, day, unit, hours, src)
        values (p_center, trim(p_name), d.day, u_name[n], h, 'auto')
        on conflict (center_id, (replace(trim(name), ' ', '')), day, unit)
        do update set hours = ojt_unit_daily.hours + excluded.hours, updated_at = now();
      end if;
    end loop;
  end if;

  insert into ojt_unit_state (center_id, name_key, month, plan_sig, built_at)
  values (p_center, v_key, p_month, _ojt_plan_sig(p_center, p_name, p_month), now())
  on conflict (center_id, name_key, month) do update set plan_sig = excluded.plan_sig, built_at = excluded.built_at;

  select coalesce(sum(a.planned_hours), 0) into v_planned from attendance_daily a
   where a.center_id = p_center and a.track = 'ojt' and coalesce(a.planned_hours, 0) > 0
     and _ojt_key(a.name) = v_key and a.day >= p_month and a.day < v_to;
  select coalesce(sum(m.hours), 0) into v_units from ojt_unit_month m
   where m.center_id = p_center and _ojt_key(m.name) = v_key and m.month = p_month;
  return jsonb_build_object('planned', v_planned, 'units', v_units, 'over', v_over, 'dropped', v_dropped);
end $$;
revoke all on function public._ojt_units_rebuild(uuid, text, date) from public, anon, authenticated;

-- ── 내부: 지문이 바뀌었으면 다시 배분 ──
create or replace function public._ojt_units_fresh(p_center uuid, p_name text, p_month date)
returns void language plpgsql security definer set search_path = public as $$
declare s text;
begin
  if not exists (select 1 from ojt_unit_month m
                  where m.center_id = p_center and _ojt_key(m.name) = _ojt_key(p_name) and m.month = p_month) then
    return;
  end if;
  select plan_sig into s from ojt_unit_state
   where center_id = p_center and name_key = _ojt_key(p_name) and month = p_month;
  if s is distinct from _ojt_plan_sig(p_center, p_name, p_month) then
    perform _ojt_units_rebuild(p_center, p_name, p_month);
  end if;
end $$;
revoke all on function public._ojt_units_fresh(uuid, text, date) from public, anon, authenticated;

-- ── 내부: 한 학생 한 달 묶음(학생·기업 화면 공통) ──
create or replace function public._ojt_units_month_json(p_center uuid, p_name text, p_month date)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_to date := (p_month + interval '1 month')::date; v_key text := _ojt_key(p_name);
begin
  perform _ojt_units_fresh(p_center, p_name, p_month);
  return jsonb_build_object(
    'month', to_char(p_month, 'YYYY-MM'),
    'units', (select coalesce(jsonb_agg(jsonb_build_object(
                       'unit', m.unit, 'hours', m.hours, 'sort', m.sort, 'eval_month', m.eval_month,
                       'days', (select count(distinct f.day) from ojt_unit_daily f
                                 where f.center_id = p_center and _ojt_key(f.name) = v_key and f.unit = m.unit
                                   and f.day >= p_month and f.day < v_to),
                       'daily_hours', (select coalesce(sum(f.hours), 0) from ojt_unit_daily f
                                        where f.center_id = p_center and _ojt_key(f.name) = v_key and f.unit = m.unit
                                          and f.day >= p_month and f.day < v_to))
                     order by m.sort, m.unit), '[]'::jsonb)
                from ojt_unit_month m
               where m.center_id = p_center and _ojt_key(m.name) = v_key and m.month = p_month),
    'days', (select coalesce(jsonb_agg(jsonb_build_object('day', to_char(x.day, 'YYYY-MM-DD'), 'units', x.units) order by x.day), '[]'::jsonb)
               from (select f.day,
                            jsonb_agg(jsonb_build_object('unit', f.unit, 'hours', f.hours, 'src', f.src, 'by', f.by_name)
                                      order by coalesce((select m.sort from ojt_unit_month m
                                                          where m.center_id = p_center and _ojt_key(m.name) = v_key
                                                            and m.month = p_month and m.unit = f.unit), 999), f.unit) units
                       from ojt_unit_daily f
                      where f.center_id = p_center and _ojt_key(f.name) = v_key and f.day >= p_month and f.day < v_to
                      group by f.day) x));
end $$;
revoke all on function public._ojt_units_month_json(uuid, text, date) from public, anon, authenticated;

-- ── 내부: 'YYYY-MM' → 그 달 1일(없으면 이번 달) ──
create or replace function public._ojt_month(p text)
returns date language sql stable set search_path = public as $$
  select case when coalesce(p, '') ~ '^\d{4}-\d{2}$' then to_date(p || '-01', 'YYYY-MM-DD')
              else date_trunc('month', (now() at time zone 'Asia/Seoul'))::date end
$$;

-- ── 학생: 내 그 달(또는 'all' = 능력단위 배정이 있는 모든 달) ──
create or replace function public.my_ojt_daily_units(p_code text default null, p_token text default null, p_month text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare st public.students; v jsonb; m date;
begin
  st := _chat_me(p_code, p_token);
  if st.id is null then return jsonb_build_object('ok', false); end if;
  if p_month = 'all' then
    v := '[]'::jsonb;
    for m in select distinct u.month from ojt_unit_month u
              where u.center_id = st.center_id and _ojt_key(u.name) = _ojt_key(st.name) order by 1
    loop
      v := v || jsonb_build_array(_ojt_units_month_json(st.center_id, st.name, m));
    end loop;
  else
    v := jsonb_build_array(_ojt_units_month_json(st.center_id, st.name, _ojt_month(p_month)));
  end if;
  return jsonb_build_object('ok', true, 'months', v);
end $$;
grant execute on function public.my_ojt_daily_units(text, text, text) to anon, authenticated;

-- ── 기업: 그 기업 학생들의 그 달 ──
create or replace function public.company_ojt_units(p_code text default null, p_month text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare c public.company_codes; m date := _ojt_month(p_month); v jsonb := '[]'::jsonb; s record;
begin
  c := _company_me(p_code);
  if c.code is null then return jsonb_build_object('ok', false); end if;
  for s in select st.id, trim(st.name) nm from students st
            where st.center_id = c.center_id and _co_key(st.company) = _co_key(c.company)
              and coalesce(st.status, '진행중') = '진행중'
            order by st.name
  loop
    v := v || jsonb_build_array(jsonb_build_object('id', s.id, 'name', s.nm) || _ojt_units_month_json(c.center_id, s.nm, m));
  end loop;
  return jsonb_build_object('ok', true, 'month', to_char(m, 'YYYY-MM'), 'students', v);
end $$;
grant execute on function public.company_ojt_units(text, text) to anon, authenticated;

-- ── 기업: 그날 능력단위 고치기(합계 = 그날 정규시간, 능력단위별 월 합계가 바뀌면 저장 안 함) ──
create or replace function public.company_set_daily_units(p_code text default null, p_student uuid default null, p_day date default null,
                                                          p_units jsonb default null, p_by_name text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  c public.company_codes; st public.students; v_by text := nullif(left(btrim(coalesce(p_by_name, '')), 40), '');
  v_month date; v_to date; v_planned numeric; v_sum numeric := 0; r record; bad_unit text;
  v_before jsonb; v_after jsonb; v_unit text; v_lim numeric; v_got numeric;
begin
  c := _company_me(p_code);
  if c.code is null then return jsonb_build_object('ok', false, 'reason', 'auth'); end if;
  if v_by is null then return jsonb_build_object('ok', false, 'reason', 'name'); end if;
  if p_day is null or jsonb_typeof(p_units) <> 'array' or jsonb_array_length(p_units) = 0 or jsonb_array_length(p_units) > 6 then
    return jsonb_build_object('ok', false, 'reason', 'input');
  end if;
  select * into st from students s
   where s.id = p_student and s.center_id = c.center_id and _co_key(s.company) = _co_key(c.company);
  if st.id is null then return jsonb_build_object('ok', false, 'reason', 'student'); end if;
  if (select count(*) from ojt_unit_daily f join students s2 on s2.center_id = f.center_id and _ojt_key(s2.name) = _ojt_key(f.name)
       where f.center_id = c.center_id and f.src = 'teacher' and _co_key(s2.company) = _co_key(c.company)
         and f.updated_at > now() - interval '10 minutes') >= 120 then
    return jsonb_build_object('ok', false, 'reason', 'rate');
  end if;

  v_month := date_trunc('month', p_day)::date; v_to := (v_month + interval '1 month')::date;
  select a.planned_hours into v_planned from attendance_daily a
   where a.center_id = c.center_id and a.track = 'ojt' and _ojt_key(a.name) = _ojt_key(st.name) and a.day = p_day
     and coalesce(a.planned_hours, 0) > 0;
  if v_planned is null then return jsonb_build_object('ok', false, 'reason', 'no_plan'); end if;

  for r in select x->>'unit' unit, (x->>'hours')::numeric hours from jsonb_array_elements(p_units) x loop
    if r.hours is null or r.hours <= 0 or r.hours <> trunc(r.hours) then return jsonb_build_object('ok', false, 'reason', 'hours'); end if;
    if not exists (select 1 from ojt_unit_month m where m.center_id = c.center_id and _ojt_key(m.name) = _ojt_key(st.name)
                     and m.month = v_month and m.unit = r.unit) then
      return jsonb_build_object('ok', false, 'reason', 'unit', 'unit', r.unit);
    end if;
    v_sum := v_sum + r.hours;
  end loop;
  if (select count(distinct x->>'unit') from jsonb_array_elements(p_units) x) <> jsonb_array_length(p_units) then
    return jsonb_build_object('ok', false, 'reason', 'dup');
  end if;
  if v_sum <> v_planned then return jsonb_build_object('ok', false, 'reason', 'day_total', 'planned', v_planned, 'sum', v_sum); end if;

  -- 지금 상태(최신 배분)의 능력단위별 월 합계
  perform _ojt_units_rebuild(c.center_id, st.name, v_month);
  select coalesce(jsonb_object_agg(unit, s), '{}'::jsonb) into v_before from (
    select f.unit, sum(f.hours) s from ojt_unit_daily f
     where f.center_id = c.center_id and _ojt_key(f.name) = _ojt_key(st.name) and f.day >= v_month and f.day < v_to
     group by f.unit) q;

  begin
    delete from ojt_unit_daily f
     where f.center_id = c.center_id and _ojt_key(f.name) = _ojt_key(st.name) and f.day = p_day;
    insert into ojt_unit_daily (center_id, name, day, unit, hours, src, by_name)
    select c.center_id, trim(st.name), p_day, x->>'unit', (x->>'hours')::numeric, 'teacher', v_by
      from jsonb_array_elements(p_units) x;
    perform _ojt_units_rebuild(c.center_id, st.name, v_month);
    select coalesce(jsonb_object_agg(unit, s), '{}'::jsonb) into v_after from (
      select f.unit, sum(f.hours) s from ojt_unit_daily f
       where f.center_id = c.center_id and _ojt_key(f.name) = _ojt_key(st.name) and f.day >= v_month and f.day < v_to
       group by f.unit) q;
    if v_after is distinct from v_before then
      select k, coalesce((v_before->>k)::numeric, 0), coalesce((v_after->>k)::numeric, 0) into v_unit, v_lim, v_got
        from (select jsonb_object_keys(v_before || v_after) k) z
       where coalesce((v_before->>k)::numeric, 0) <> coalesce((v_after->>k)::numeric, 0)
       order by 1 limit 1;
      raise exception 'ojt_unit_total' using detail = jsonb_build_object('unit', v_unit, 'limit', v_lim, 'got', v_got)::text;
    end if;
  exception when raise_exception then
    if sqlerrm = 'ojt_unit_total' then
      declare dt text; begin
        get stacked diagnostics dt = pg_exception_detail;
        return jsonb_build_object('ok', false, 'reason', 'month_total') || coalesce(dt::jsonb, '{}'::jsonb);
      end;
    end if;
    raise;
  end;
  return jsonb_build_object('ok', true) || _ojt_units_month_json(c.center_id, st.name, v_month);
end $$;
grant execute on function public.company_set_daily_units(text, uuid, date, jsonb, text) to anon, authenticated;

-- ── 기업: 그날 자동으로 되돌리기 ──
create or replace function public.company_reset_daily_units(p_code text default null, p_student uuid default null, p_day date default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare c public.company_codes; st public.students; v_month date;
begin
  c := _company_me(p_code);
  if c.code is null then return jsonb_build_object('ok', false, 'reason', 'auth'); end if;
  select * into st from students s
   where s.id = p_student and s.center_id = c.center_id and _co_key(s.company) = _co_key(c.company);
  if st.id is null or p_day is null then return jsonb_build_object('ok', false, 'reason', 'student'); end if;
  v_month := date_trunc('month', p_day)::date;
  delete from ojt_unit_daily f
   where f.center_id = c.center_id and _ojt_key(f.name) = _ojt_key(st.name) and f.day = p_day and f.src = 'teacher';
  perform _ojt_units_rebuild(c.center_id, st.name, v_month);
  return jsonb_build_object('ok', true) || _ojt_units_month_json(c.center_id, st.name, v_month);
end $$;
grant execute on function public.company_reset_daily_units(text, uuid, date) to anon, authenticated;

-- ── 관리자: 시간표 올리기 [{name, month:'YYYY-MM', unit, hours, sort, eval_month, course}] ──
--    올린 (학생, 달)은 통째로 바꾼다(빠진 능력단위는 지움) → 그 달 다시 배분.
create or replace function public.admin_upsert_unit_month(p_rows jsonb, p_by text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare au public.admin_users; v_center uuid; r record; k record; cnt int := 0; res jsonb := '[]'::jsonb;
begin
  select * into au from admin_users where user_id = auth.uid();
  if au.user_id is null then return jsonb_build_object('ok', false, 'reason', 'auth'); end if;
  v_center := au.center_id;
  if jsonb_typeof(p_rows) <> 'array' then return jsonb_build_object('ok', false, 'reason', 'input'); end if;

  for k in select distinct trim(x->>'name') nm, _ojt_month(x->>'month') mo from jsonb_array_elements(p_rows) x
            where coalesce(x->>'name', '') <> '' and coalesce(x->>'month', '') ~ '^\d{4}-\d{2}$'
  loop
    delete from ojt_unit_month m where m.center_id = v_center and _ojt_key(m.name) = _ojt_key(k.nm) and m.month = k.mo;
  end loop;
  for r in select trim(x->>'name') nm, _ojt_month(x->>'month') mo, trim(x->>'unit') unit, (x->>'hours')::numeric hours,
                  coalesce((x->>'sort')::int, 0) sort, nullif(x->>'eval_month', '') ev, nullif(x->>'course', '') course
             from jsonb_array_elements(p_rows) x
            where coalesce(x->>'name', '') <> '' and coalesce(x->>'month', '') ~ '^\d{4}-\d{2}$'
              and coalesce(x->>'unit', '') <> '' and coalesce((x->>'hours')::numeric, 0) > 0
  loop
    insert into ojt_unit_month (center_id, name, month, unit, hours, sort, eval_month, course, updated_by)
    values (v_center, r.nm, r.mo, r.unit, r.hours, r.sort, r.ev, r.course, nullif(left(coalesce(p_by, ''), 40), ''))
    on conflict (center_id, (replace(trim(name), ' ', '')), month, unit)
    do update set hours = excluded.hours, sort = excluded.sort, eval_month = excluded.eval_month, course = excluded.course,
                  updated_by = excluded.updated_by, updated_at = now();
    cnt := cnt + 1;
  end loop;
  for k in select distinct trim(x->>'name') nm, _ojt_month(x->>'month') mo from jsonb_array_elements(p_rows) x
            where coalesce(x->>'name', '') <> '' and coalesce(x->>'month', '') ~ '^\d{4}-\d{2}$'
  loop
    res := res || jsonb_build_array(jsonb_build_object('name', k.nm, 'month', to_char(k.mo, 'YYYY-MM'))
                                    || _ojt_units_rebuild(v_center, k.nm, k.mo));
  end loop;
  return jsonb_build_object('ok', true, 'rows', cnt, 'built', res);
end $$;
grant execute on function public.admin_upsert_unit_month(jsonb, text) to authenticated;

-- ── 관리자: 그 달 보고서(학생별 정규시간 합·능력단위 합·현장교사 수정) — 보면서 지문이 바뀐 학생은 다시 배분 ──
create or replace function public.admin_ojt_unit_report(p_month text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare au public.admin_users; v_center uuid; m date := _ojt_month(p_month); v_to date; s record; v jsonb := '[]'::jsonb;
        v_planned numeric; v_units numeric; v_fixed int;
begin
  select * into au from admin_users where user_id = auth.uid();
  if au.user_id is null then return jsonb_build_object('ok', false, 'reason', 'auth'); end if;
  v_center := au.center_id; v_to := (m + interval '1 month')::date;
  for s in select min(trim(u.name)) nm from ojt_unit_month u
            where u.center_id = v_center and u.month = m group by _ojt_key(u.name) order by 1
  loop
    perform _ojt_units_fresh(v_center, s.nm, m);
    select coalesce(sum(a.planned_hours), 0) into v_planned from attendance_daily a
     where a.center_id = v_center and a.track = 'ojt' and coalesce(a.planned_hours, 0) > 0
       and _ojt_key(a.name) = _ojt_key(s.nm) and a.day >= m and a.day < v_to;
    select coalesce(sum(u.hours), 0) into v_units from ojt_unit_month u
     where u.center_id = v_center and _ojt_key(u.name) = _ojt_key(s.nm) and u.month = m;
    select count(distinct f.day) into v_fixed from ojt_unit_daily f
     where f.center_id = v_center and _ojt_key(f.name) = _ojt_key(s.nm) and f.src <> 'auto' and f.day >= m and f.day < v_to;
    v := v || jsonb_build_array(_ojt_units_month_json(v_center, s.nm, m)
                                || jsonb_build_object('name', s.nm, 'planned', v_planned, 'unit_total', v_units,
                                                      'fixed_days', v_fixed, 'ok', v_planned = v_units));
  end loop;
  return jsonb_build_object('ok', true, 'month', to_char(m, 'YYYY-MM'), 'students', v);
end $$;
grant execute on function public.admin_ojt_unit_report(text) to authenticated;
