-- =====================================================================
-- sql/70_field_page.sql — 학습기업 담당자 페이지 자료 (2026-10-22, docs/FIELD.md)
--
-- 사용자 결정(10/22): 들어오는 길은 **학생과 똑같이** — 앱에 기업 초대코드(company_codes)로 가입한 기업 담당자 프로필의 코드로
--   본인 확인. 현장교사/HRD담당자로 **나누지 않고 회사 하나**로(같은 화면). 그래서 sql/69 의 기업 링크(company_links)는 쓰지 않는다
--   (표는 남겨 둠, 관리자 화면에서 뺌). 비콘은 인정 시간·상태만(입실·퇴실 시각은 돌려주지 않음). 외부평가 없음.
--
--  · _company_me(p_code) — 활성 company_codes 한 행(기업·센터). 실패만 IP 10분 30회('cofail:') — 회사 와이파이 공용 IP.
--  · attendance_month_status — 학생·달마다 마감 단계: 훈련일 수·학습활동서 작성일 수·학생 출석확인 날짜·센터 확인 날짜.
--      센터가 출석결과 엑셀에서 올림(다음 단계). 관리자만 직접 접근.
--  · allowance_status — 기업·기간(월)마다 전담인력활동수당 상태(미신청/신청/승인/확정/지급완료)·신청일. 센터가 행정지원시스템
--      비용관리(전담자)에서 확인한 값. 금액은 두지 않음. 관리자만 직접 접근.
--  · field_tasks — 기업별 월말 할 일(내부평가·면담일지·기타). course 가 있으면 그 과정만. 관리자만 직접 접근.
--  · 기업 담당자 RPC(코드 = 프로필 code):
--      company_home(p_code, p_month)        → 그 기업 학생들의 그 달 날짜별 정규시간·인정·상태 + 휴가·출장 + 전 기간 월 행(예정·실적·
--                                             능력단위) + OJT 능력단위 요소(학생별 'OJT:<이름>') + 월 마감 상태 + 수당 + 월말 할 일
--      company_absence(p_code, p_student, p_day, p_kind, p_note, p_by_name) / company_absence_cancel(p_code, p_id)
--  · attendance_absences.by_role 에 'company'(기업 담당자) 추가.
--  · rls-check MUST_BE_BLOCKED 에 attendance_month_status·allowance_status·field_tasks.
--  · 멱등: if not exists / create or replace / drop … if exists.
-- =====================================================================

-- 휴가·출장을 기업 담당자가 알린 것 = by_role 'company'
alter table public.attendance_absences drop constraint if exists attendance_absences_by_role_check;
alter table public.attendance_absences add constraint attendance_absences_by_role_check
  check (by_role in ('student', 'teacher', 'admin', 'company'));

create table if not exists public.attendance_month_status (
  id uuid primary key default gen_random_uuid(),
  center_id uuid not null references public.centers(id),
  name text not null,
  month date not null,                   -- 그 달 1일
  course text,
  train_days int,                        -- 정규시간이 있는 훈련일 수
  diary_days int,                        -- 학습활동서를 쓴 훈련일 수
  student_confirmed_on date,             -- 학생 출석확인 날짜
  center_confirmed_on date,              -- 센터 [출석결과 확인] 날짜
  updated_at timestamptz not null default now()
);
create unique index if not exists attendance_month_status_uniq
  on public.attendance_month_status (center_id, (replace(trim(name), ' ', '')), month);

create table if not exists public.allowance_status (
  id uuid primary key default gen_random_uuid(),
  center_id uuid not null references public.centers(id),
  company_key text not null,             -- _co_key(기업명)
  company_label text not null,
  period date not null,                  -- 대상 달 1일
  state text not null check (state in ('미신청', '신청', '승인', '확정', '지급완료')),
  applied_on date,
  checked_at timestamptz not null default now(),   -- 센터가 행정지원시스템에서 확인한 때
  note text
);
create unique index if not exists allowance_status_uniq on public.allowance_status (center_id, company_key, period);

-- 기업별 월말 할 일(사용자 10/22 "해당 월말에 필요한 내부평가랑 면담일지 일정도")
create table if not exists public.field_tasks (
  id uuid primary key default gen_random_uuid(),
  center_id uuid not null references public.centers(id),
  company_key text not null,
  course text,
  kind text not null check (kind in ('내부평가', '면담일지', '기타')),
  month date not null,                   -- 대상 달 1일
  due_on date,                           -- 마감(보통 그 달 말)
  title text not null,                   -- 예: '인공지능 학습데이터 획득 내부평가'
  note text,
  done_on date,                          -- 센터가 받은 날
  updated_at timestamptz not null default now()
);
create index if not exists field_tasks_co on public.field_tasks (center_id, company_key, month);

alter table public.attendance_month_status enable row level security;
alter table public.allowance_status enable row level security;
alter table public.field_tasks enable row level security;
drop policy if exists "month status admin all" on public.attendance_month_status;
create policy "month status admin all" on public.attendance_month_status
  for all to public
  using (is_super_admin() or center_id = current_admin_center())
  with check (is_super_admin() or center_id = current_admin_center());
drop policy if exists "allowance admin all" on public.allowance_status;
create policy "allowance admin all" on public.allowance_status
  for all to public
  using (is_super_admin() or center_id = current_admin_center())
  with check (is_super_admin() or center_id = current_admin_center());
drop policy if exists "field tasks admin all" on public.field_tasks;
create policy "field tasks admin all" on public.field_tasks
  for all to public
  using (is_super_admin() or center_id = current_admin_center())
  with check (is_super_admin() or center_id = current_admin_center());
revoke all on public.attendance_month_status from anon;
revoke all on public.allowance_status from anon;
revoke all on public.field_tasks from anon;
grant select, insert, update, delete on public.attendance_month_status to authenticated;
grant select, insert, update, delete on public.allowance_status to authenticated;
grant select, insert, update, delete on public.field_tasks to authenticated;

-- 기업 담당자 본인 확인 — 활성 기업 코드. 실패하면 IP 실패 횟수 +1
create or replace function public._company_me(p_code text)
returns public.company_codes
language plpgsql security definer set search_path = public as $$
declare c public.company_codes; ip text;
begin
  if coalesce(p_code, '') <> '' then
    select * into c from company_codes
     where code = upper(regexp_replace(p_code, '[^A-Za-z0-9]', '', 'g')) and active;
  end if;
  if c.code is null then
    ip := coalesce(current_setting('request.headers', true)::jsonb ->> 'x-forwarded-for', 'unknown');
    begin
      perform check_verify_rate('cofail:' || ip);
    exception when undefined_function then null;
    end;
  end if;
  return c;
end $$;
revoke all on function public._company_me(text) from public, anon, authenticated;

-- 기업 담당자 화면 한 번에
create or replace function public.company_home(p_code text default null, p_month text default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare c public.company_codes; v_key text; v_from date := _absence_month(p_month); v_to date; v_studs jsonb; v_allow jsonb; v_tasks jsonb;
begin
  c := _company_me(p_code);
  if c.code is null then return jsonb_build_object('ok', false); end if;
  v_key := _co_key(c.company);
  v_to := (v_from + interval '1 month')::date;
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', s.id, 'name', trim(s.name),
           -- 그 달 날짜별 정규시간·인정·상태(입실·퇴실 시각·출석방식 없음)
           'days', (select coalesce(jsonb_agg(jsonb_build_object('day', a.day, 'course', a.course, 'hours', a.planned_hours,
                                                                 'start', to_char(a.start_time, 'HH24:MI'), 'end', to_char(a.end_time, 'HH24:MI'),
                                                                 'status', coalesce(a.status, 'planned'), 'recognized', a.recognized_hours)
                                               order by a.day), '[]'::jsonb)
                      from attendance_daily a
                     where a.center_id = s.center_id and a.track = 'ojt' and a.day >= v_from and a.day < v_to
                       and coalesce(a.planned_hours, 0) > 0
                       and replace(trim(a.name), ' ', '') = replace(trim(s.name), ' ', '')),
           'absences', (select coalesce(jsonb_agg(jsonb_build_object('id', b.id, 'day', b.day, 'kind', b.kind, 'note', b.note,
                                                                     'state', b.state, 'by_role', b.by_role, 'by_name', b.by_name, 'at', b.updated_at)
                                                   order by b.day), '[]'::jsonb)
                          from attendance_absences b
                         where b.center_id = s.center_id and b.student_id = s.id and b.state <> 'canceled'
                           and b.day >= (v_from - interval '1 month')::date and b.day < v_to),
           'months', (select coalesce(jsonb_agg(jsonb_build_object('month', to_char(m.month, 'YYYY-MM'), 'planned', m.planned_hours,
                                                                   'actual', m.actual_hours, 'units', m.units) order by m.month), '[]'::jsonb)
                        from attendance_monthly m
                       where m.center_id = s.center_id and m.track = 'ojt'
                         and replace(trim(m.name), ' ', '') = replace(trim(s.name), ' ', '')),
           'units', (select coalesce(jsonb_agg(jsonb_build_object('unit', u.unit, 'hours', u.hours, 'elements', u.elements) order by u.sort, u.unit), '[]'::jsonb)
                       from offjt_units u
                      where u.center_id = s.center_id and u.subject = 'OJT'
                        and u.job_key = 'OJT:' || replace(trim(s.name), ' ', '')),
           'status', (select coalesce(jsonb_agg(jsonb_build_object('month', to_char(t.month, 'YYYY-MM'), 'course', t.course,
                                                                   'train_days', t.train_days, 'diary_days', t.diary_days,
                                                                   'student_confirmed_on', t.student_confirmed_on, 'center_confirmed_on', t.center_confirmed_on)
                                               order by t.month), '[]'::jsonb)
                        from attendance_month_status t
                       where t.center_id = s.center_id and replace(trim(t.name), ' ', '') = replace(trim(s.name), ' ', '')))
           order by s.name), '[]'::jsonb)
    into v_studs
    from students s
   where s.center_id = c.center_id and _co_key(s.company) = v_key and coalesce(s.status, '진행중') = '진행중';
  select coalesce(jsonb_agg(jsonb_build_object('period', to_char(a.period, 'YYYY-MM'), 'state', a.state,
                                               'applied_on', a.applied_on, 'checked_at', a.checked_at) order by a.period desc), '[]'::jsonb)
    into v_allow
    from allowance_status a where a.center_id = c.center_id and a.company_key = v_key;
  -- 월말 할 일: 그 달·다음 달 + 지난달까지 아직 안 끝난 것
  select coalesce(jsonb_agg(jsonb_build_object('id', t.id, 'course', t.course, 'kind', t.kind, 'month', to_char(t.month, 'YYYY-MM'),
                                               'due_on', t.due_on, 'title', t.title, 'note', t.note, 'done_on', t.done_on)
                            order by t.month, t.due_on nulls last, t.kind), '[]'::jsonb)
    into v_tasks
    from field_tasks t
   where t.center_id = c.center_id and t.company_key = v_key
     and ((t.month >= v_from and t.month < (v_to + interval '1 month')::date) or (t.month < v_from and t.done_on is null));
  return jsonb_build_object('ok', true, 'company', c.company,
                            'month', to_char(v_from, 'YYYY-MM'), 'today', to_char(now() at time zone 'Asia/Seoul', 'YYYY-MM-DD'),
                            'students', v_studs, 'allowance', v_allow, 'tasks', v_tasks);
end $$;

create or replace function public.company_absence(p_code text default null, p_student uuid default null, p_day date default null,
                                                  p_kind text default null, p_note text default null, p_by_name text default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare c public.company_codes; st public.students; v_by text := nullif(left(btrim(coalesce(p_by_name, '')), 40), '');
begin
  c := _company_me(p_code);
  if c.code is null then return jsonb_build_object('ok', false); end if;
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

create or replace function public.company_absence_cancel(p_code text default null, p_id uuid default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare c public.company_codes; ex public.attendance_absences;
begin
  c := _company_me(p_code);
  if c.code is null then return jsonb_build_object('ok', false); end if;
  select a.* into ex from attendance_absences a join students s on s.id = a.student_id
   where a.id = p_id and a.center_id = c.center_id and _co_key(s.company) = _co_key(c.company);
  if ex.id is null then return jsonb_build_object('ok', false, 'reason', 'not_found'); end if;
  if ex.state <> 'open' then return jsonb_build_object('ok', false, 'reason', ex.state); end if;
  update attendance_absences set state = 'canceled', updated_at = now() where id = ex.id;
  return jsonb_build_object('ok', true);
end $$;

revoke all on function public.company_home(text, text) from public;
revoke all on function public.company_absence(text, uuid, date, text, text, text) from public;
revoke all on function public.company_absence_cancel(text, uuid) from public;
grant execute on function public.company_home(text, text) to anon, authenticated;
grant execute on function public.company_absence(text, uuid, date, text, text, text) to anon, authenticated;
grant execute on function public.company_absence_cancel(text, uuid) to anon, authenticated;
