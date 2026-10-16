-- =====================================================================
-- 62_offjt_schedule.sql — 직무별 OFF-JT 수업 달력 + 능력단위별 목록 (docs/OFFJT.md 새 3단계)
-- 멱등(create or replace / if not exists / on conflict). 적용 순서: 19·21·37(_norm_co)·59 이후.
--
-- 사용자 결정(10/16): 보기 전용(알림·날짜별 체크 없음) · **직무 기준**, 기업별 파일은 선택으로 올릴 수 있게 ·
--   반도체장비개발(전장설계)은 반공/전자 일정이 달라 직무를 둘로 나눔 · 학습안내서 표는 그림이라
--   능력단위요소·수행과업은 직무당 1회 붙여넣기 입력.
--
--  · offjt_schedule = 수업일정 엑셀의 날짜별 '과목/능력단위' 쌍. company = '' 이면 직무 공통,
--    값이 있으면 그 기업 학생 전용(그 달에 기업 전용 행이 있으면 그 달은 그것만 보임 — `_멜콘 3월` 같은 월별 변형).
--  · offjt_units = 직무·연도별 능력단위 시간표(학습안내서 1쪽) + 능력단위요소·수행과업(elements jsonb).
--      elements = [{"name":"개발환경 구축하기","tasks":["…","…"]}, …]
--  · 쓰기: upload_offjt_schedule(고른 달만 교체) / set_offjt_units(목록 교체, elements 는 키가 있을 때만 바꿈).
--    관리자 / service_role+센터 명시만. 클라 center_id 미신뢰(center_admin 은 자기 센터 강제).
--  · 학생: my_offjt_schedule(코드 또는 서명토큰) SECURITY DEFINER — 서버가 학생 행을 찾아 **그 학생의 직무(·기업)·기수 연도**
--    것만 돌려준다. anon 정책 없음 → rls-check MUST_BE_BLOCKED 등록.
--  · 프론트 폴백: 표/RPC 미적용이면 일정 화면이 지금과 똑같이 보임(회귀 0).
-- =====================================================================

create table if not exists public.offjt_schedule (
  id          uuid primary key default gen_random_uuid(),
  center_id   uuid not null references public.centers(id),
  job_key     text not null,                -- jobs.name (students.job_keys 원소와 같은 이름)
  company     text not null default '',     -- '' = 직무 공통, 값 = 그 기업 전용
  day         date not null,
  seq         int not null default 1,       -- 그날 몇 번째 과목(엑셀 위→아래)
  subject     text not null,                -- 과목(교과목)
  unit        text,                         -- 능력단위(직업기초능력 단독 칸은 null)
  is_new      boolean not null default false,   -- ★ = 그날부터 새 능력단위
  is_basic    boolean not null default false,   -- 직업기초능력
  src_file    text,                         -- 올린 엑셀 파일명(어느 파일에서 왔는지)
  uploaded_by text,
  uploaded_at timestamptz not null default now()
);
create index if not exists offjt_schedule_key on public.offjt_schedule (center_id, job_key, company, day);

create table if not exists public.offjt_units (
  id          uuid primary key default gen_random_uuid(),
  center_id   uuid not null references public.centers(id),
  job_key     text not null,
  year        int not null,                 -- 기수 연도(2027 교과가 바뀌어도 2026 은 그대로)
  subject     text not null,
  unit        text not null,
  hours       numeric,                      -- 학습안내서 1쪽 시간
  sort        int not null default 0,
  elements    jsonb not null default '[]'::jsonb,
  updated_by  text,
  updated_at  timestamptz not null default now()
);
create unique index if not exists offjt_units_uniq on public.offjt_units (center_id, job_key, year, subject, unit);

alter table public.offjt_schedule enable row level security;
alter table public.offjt_units enable row level security;

-- 관리자만 직접 접근(센터 스코프). to public + 헬퍼 패턴(publishable 키에서 to authenticated 미동작 전례).
drop policy if exists "offjt schedule admin all" on public.offjt_schedule;
create policy "offjt schedule admin all" on public.offjt_schedule
  for all to public
  using (is_super_admin() or center_id = current_admin_center())
  with check (is_super_admin() or center_id = current_admin_center());
drop policy if exists "offjt units admin all" on public.offjt_units;
create policy "offjt units admin all" on public.offjt_units
  for all to public
  using (is_super_admin() or center_id = current_admin_center())
  with check (is_super_admin() or center_id = current_admin_center());

revoke all on public.offjt_schedule from anon;
revoke all on public.offjt_units from anon;
grant select, insert, update, delete on public.offjt_schedule to authenticated;
grant select, insert, update, delete on public.offjt_units to authenticated;

-- 관리자 센터 해석(55·61 과 같은 규칙)
create or replace function public._offjt_center(p_center uuid)
returns uuid
language plpgsql stable security definer set search_path = public as $$
declare v uuid;
begin
  if auth.role() = 'service_role' then
    if p_center is null then raise exception 'center_required'; end if;
    return p_center;
  end if;
  if not exists (select 1 from admin_users au where au.user_id = auth.uid()) then
    raise exception 'not_admin';
  end if;
  if is_super_admin() then v := coalesce(p_center, current_admin_center());
  else v := current_admin_center();          -- center_admin 은 클라값 무시(강제)
  end if;
  if v is null then raise exception 'no_center'; end if;
  return v;
end $$;
revoke all on function public._offjt_center(uuid) from public, anon;

-- ── 수업일정 올리기 ──
-- p_months: ['2026-04', …] 교체할 달. p_rows: [{day:'YYYY-MM-DD', seq, subject, unit, is_new, is_basic}]
-- p_companies: [] 또는 null = 직무 공통, ['멜콘', …] = 그 기업들 전용(같은 행을 기업마다 넣음).
-- 고른 달의 (직무, 기업) 행만 지우고 새로 넣는다 — 월별 수정본(_4월.xlsx)은 그 달만 바뀜.
create or replace function public.upload_offjt_schedule(
  p_job text, p_months text[], p_rows jsonb, p_companies text[] default null,
  p_file text default null, p_center uuid default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_center uuid; v_cos text[]; v_co text; m text; v_from date; r jsonb; v_day date;
        n_del int := 0; n_ins int := 0; n_skip int := 0; k int; v_by text;
begin
  v_center := _offjt_center(p_center);
  if coalesce(trim(p_job), '') = '' then raise exception 'job_required'; end if;
  if coalesce(array_length(p_months, 1), 0) = 0 then raise exception 'months_required'; end if;
  foreach m in array p_months loop
    if coalesce(m, '') !~ '^\d{4}-\d{2}$' then raise exception 'bad_month'; end if;
  end loop;
  select coalesce(array_agg(distinct trim(c)) filter (where trim(coalesce(c, '')) <> ''), '{}') into v_cos
    from unnest(coalesce(p_companies, '{}'::text[])) c;
  if coalesce(array_length(v_cos, 1), 0) = 0 then v_cos := array['']; end if;
  select email into v_by from auth.users where id = auth.uid();

  foreach v_co in array v_cos loop
    foreach m in array p_months loop
      v_from := to_date(m || '-01', 'YYYY-MM-DD');
      delete from offjt_schedule s
       where s.center_id = v_center and s.job_key = trim(p_job) and s.company = v_co
         and s.day >= v_from and s.day < (v_from + interval '1 month')::date;
      get diagnostics k = row_count; n_del := n_del + k;
    end loop;
    for r in select * from jsonb_array_elements(coalesce(p_rows, '[]'::jsonb)) loop
      if coalesce(r->>'day', '') !~ '^\d{4}-\d{2}-\d{2}$' or trim(coalesce(r->>'subject', '')) = '' then
        n_skip := n_skip + 1; continue;
      end if;
      v_day := to_date(r->>'day', 'YYYY-MM-DD');
      if not (to_char(v_day, 'YYYY-MM') = any(p_months)) then n_skip := n_skip + 1; continue; end if;
      insert into offjt_schedule (center_id, job_key, company, day, seq, subject, unit, is_new, is_basic, src_file, uploaded_by)
      values (v_center, trim(p_job), v_co, v_day, coalesce((r->>'seq')::int, 1), trim(r->>'subject'),
              nullif(trim(coalesce(r->>'unit', '')), ''), coalesce((r->>'is_new')::boolean, false),
              coalesce((r->>'is_basic')::boolean, false), nullif(p_file, ''), v_by);
      n_ins := n_ins + 1;
    end loop;
  end loop;
  return jsonb_build_object('ok', true, 'deleted', n_del, 'inserted', n_ins, 'skipped', n_skip,
                            'companies', to_jsonb(v_cos));
end $$;
revoke all on function public.upload_offjt_schedule(text, text[], jsonb, text[], text, uuid) from public, anon;
grant execute on function public.upload_offjt_schedule(text, text[], jsonb, text[], text, uuid) to authenticated, service_role;

-- ── 능력단위 시간표 저장 ──
-- p_rows: [{subject, unit, hours, sort, elements?}] — 이 목록이 그 직무·연도의 전부(빠진 단위는 지움).
-- elements 키가 없으면 기존 요소·수행과업을 그대로 둔다(시간만 고쳐도 붙여넣은 문장이 안 지워지게).
create or replace function public.set_offjt_units(p_job text, p_year int, p_rows jsonb, p_center uuid default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_center uuid; r jsonb; n int := 0; n_del int := 0; v_by text; v_keys text[];
begin
  v_center := _offjt_center(p_center);
  if coalesce(trim(p_job), '') = '' then raise exception 'job_required'; end if;
  if p_year is null or p_year < 2000 or p_year > 2100 then raise exception 'bad_year'; end if;
  select email into v_by from auth.users where id = auth.uid();
  select coalesce(array_agg(trim(x->>'subject') || '|' || trim(x->>'unit')), '{}') into v_keys
    from jsonb_array_elements(coalesce(p_rows, '[]'::jsonb)) x
   where trim(coalesce(x->>'subject', '')) <> '' and trim(coalesce(x->>'unit', '')) <> '';
  delete from offjt_units u
   where u.center_id = v_center and u.job_key = trim(p_job) and u.year = p_year
     and not ((u.subject || '|' || u.unit) = any(v_keys));
  get diagnostics n_del = row_count;
  for r in select * from jsonb_array_elements(coalesce(p_rows, '[]'::jsonb)) loop
    if trim(coalesce(r->>'subject', '')) = '' or trim(coalesce(r->>'unit', '')) = '' then continue; end if;
    if r ? 'elements' and jsonb_typeof(r->'elements') <> 'array' then raise exception 'bad_elements'; end if;
    insert into offjt_units as u (center_id, job_key, year, subject, unit, hours, sort, elements, updated_by, updated_at)
    values (v_center, trim(p_job), p_year, trim(r->>'subject'), trim(r->>'unit'),
            nullif(r->>'hours', '')::numeric, coalesce((r->>'sort')::int, 0),
            case when r ? 'elements' then r->'elements' else '[]'::jsonb end, v_by, now())
    on conflict (center_id, job_key, year, subject, unit) do update
       set hours = excluded.hours, sort = excluded.sort,
           elements = case when r ? 'elements' then excluded.elements else u.elements end,
           updated_by = excluded.updated_by, updated_at = now();
    n := n + 1;
  end loop;
  return jsonb_build_object('ok', true, 'saved', n, 'deleted', n_del);
end $$;
revoke all on function public.set_offjt_units(text, int, jsonb, uuid) from public, anon;
grant execute on function public.set_offjt_units(text, int, jsonb, uuid) to authenticated, service_role;

-- ── 학생 조회 ──
-- 본인 확인은 my_attendance_days 와 같음(코드 → student_codes, 아니면 서명토큰 → students).
-- 학생 행에서 직무(job_keys 중 일정이 있는 첫 직무)·기업·기수 연도를 서버가 정한다.
-- 달마다: 그 기업 전용 행이 있으면 그것, 없으면 직무 공통. 기수 연도의 날짜만.
create or replace function public.my_offjt_schedule(p_code text default null, p_token text default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare ip text; v_name text; v_center uuid; s record; v_job text; v_year int; v_co text;
        v_days jsonb; v_units jsonb;
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

  -- 같은 이름이 여러 기수면 진행중 → 최근 기수 우선
  select st.job_keys, st.company, st.cohort into s from students st
   where st.center_id = v_center and replace(trim(st.name), ' ', '') = replace(trim(v_name), ' ', '')
   order by (st.status = '진행중') desc nulls last, st.cohort desc nulls last
   limit 1;
  if not found then return jsonb_build_object('ok', true, 'job', null, 'days', '[]'::jsonb, 'units', '[]'::jsonb); end if;
  v_year := (substring(coalesce(s.cohort, '') from '(\d{4})'))::int;
  v_co := _norm_co(s.company);

  select j into v_job from unnest(coalesce(s.job_keys, '{}'::text[])) with ordinality as t(j, o)
   where exists (select 1 from offjt_schedule x where x.center_id = v_center and x.job_key = t.j
                   and (v_year is null or extract(year from x.day)::int = v_year))
   order by o limit 1;
  if v_job is null then
    return jsonb_build_object('ok', true, 'job', (s.job_keys)[1], 'year', v_year, 'days', '[]'::jsonb, 'units', '[]'::jsonb);
  end if;

  with base as (
    select x.* from offjt_schedule x
     where x.center_id = v_center and x.job_key = v_job
       and (v_year is null or extract(year from x.day)::int = v_year)
       and (x.company = '' or (v_co <> '' and _norm_co(x.company) = v_co))
  ), pick as (   -- 달마다 기업 전용이 있으면 그것만
    select b.* from base b
     where b.company <> ''
        or not exists (select 1 from base b2 where b2.company <> ''
                         and date_trunc('month', b2.day) = date_trunc('month', b.day))
  ), per_day as (
    select p.day, jsonb_agg(jsonb_build_object('subject', p.subject, 'unit', p.unit,
             'is_new', p.is_new, 'is_basic', p.is_basic) order by p.seq) items
      from pick p group by p.day
  )
  select coalesce(jsonb_agg(jsonb_build_object('day', to_char(d.day, 'YYYY-MM-DD'), 'items', d.items) order by d.day), '[]'::jsonb)
    into v_days from per_day d;

  select coalesce(jsonb_agg(jsonb_build_object('subject', u.subject, 'unit', u.unit, 'hours', u.hours,
           'sort', u.sort, 'elements', u.elements) order by u.sort, u.subject, u.unit), '[]'::jsonb)
    into v_units
    from offjt_units u
   where u.center_id = v_center and u.job_key = v_job
     and u.year = coalesce(v_year, (select max(u2.year) from offjt_units u2 where u2.center_id = v_center and u2.job_key = v_job));

  return jsonb_build_object('ok', true, 'job', v_job, 'year', v_year, 'days', v_days, 'units', v_units);
end $$;
revoke all on function public.my_offjt_schedule(text, text) from public;
grant execute on function public.my_offjt_schedule(text, text) to anon, authenticated, service_role;

-- ── 직무 나누기(사용자 10/16): 반도체장비개발(전장설계) 반공/전자 — mju 만, 이미 있으면 그대로 ──
-- 기존 '반도체장비개발(전장설계)_L5' 는 2026 학생·지난 공지 대상이 쓰고 있어 그대로 둔다(학생 직무 변경은 관리자가 따로).
do $jobs$
declare mju uuid; v_types text[];
begin
  select id into mju from public.centers where slug = 'mju';
  if mju is null or to_regclass('public.jobs') is null then return; end if;
  select types into v_types from public.jobs where center_id = mju and name = '반도체장비개발(전장설계)_L5' limit 1;
  insert into public.jobs (notion_id, name, types, active, updated_at, center_id)
  select 'app:mju:' || n, n, coalesce(v_types, '{}'), true, now(), mju
    from unnest(array['반도체장비개발(전장설계)_L5(반공)', '반도체장비개발(전장설계)_L5(전자)']) n
   where not exists (select 1 from public.jobs j where j.center_id = mju and j.name = n)
  on conflict (notion_id) do nothing;
end
$jobs$;
