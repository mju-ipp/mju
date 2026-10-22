-- =====================================================================
-- sql/70_field_page.sql — 기업 담당자 페이지(현장교사 / HRD담당자) 자료 (2026-10-22, docs/FIELD.md 시안 v2)
--
-- 사용자 결정(10/22): 기업 링크마다 역할 — 현장교사(이번 달·능력단위·내부평가·자료) / HRD담당자(월별 출결·전담인력수당·휴가·출장·자료).
--   비콘은 인정 시간·상태만(입실·퇴실 시각은 돌려주지 않음). 외부평가 없음.
--
--  · company_links.role 'teacher' | 'hrd' (기본 teacher). admin_make_company_link 에 p_role 추가(옛 3인자 함수는 지움 —
--    PostgREST 가 3인자 호출을 두 함수 중 어느 쪽으로 보낼지 못 정하므로).
--  · attendance_month_status — 학생·달마다 마감 단계: 훈련일 수·학습활동서 작성일 수·학생 출석확인 날짜·센터 확인 날짜.
--      센터가 출석결과 엑셀에서 올림(출결점검 app_export → 관리자 올리기, 다음 단계). 관리자만 직접 접근.
--  · allowance_status — 기업·기간(월)마다 전담인력활동수당 상태(미신청/신청/승인/확정/지급완료)·신청일. 센터가 행정지원시스템
--      비용관리(전담자)에서 확인한 값. 금액은 두지 않음(표시 여부 미정). 관리자만 직접 접근.
--  · field_home(p_link, p_month) — 링크 확인(_link_me, sql/69) 뒤 그 기업 학생들의
--      그 달 날짜별 정규시간·인정·상태 + 휴가·출장 + 전 기간 월 행(예정·실적·능력단위) + OJT 능력단위 요소(학생별 'OJT:<이름>')
--      + (HRD 만) 월 마감 상태·전담인력수당. 입실·퇴실 시각·출석방식은 넣지 않음.
--  · field_tasks — 기업별 월말 할 일(내부평가·면담일지), field_home 이 그 달·다음 달·안 끝난 지난 것을 돌려줌(두 역할 모두).
--  · rls-check MUST_BE_BLOCKED 에 attendance_month_status·allowance_status·field_tasks.
--  · 멱등: if not exists / create or replace / drop … if exists.
-- =====================================================================

alter table public.company_links add column if not exists role text not null default 'teacher';
do $$ begin
  alter table public.company_links add constraint company_links_role_chk check (role in ('teacher', 'hrd'));
exception when duplicate_object then null;
end $$;

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

-- 기업별 월말 할 일(사용자 10/22 "해당 월말에 필요한 내부평가랑 면담일지 일정도") — 내부평가(시간표 '내부평가시기' 달)·면담일지.
--   course 가 있으면 그 과정만, 없으면 기업 전체. 센터가 넣음(내부평가는 시간표에서 채우는 길을 다음 단계에 둠).
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
alter table public.field_tasks enable row level security;
drop policy if exists "field tasks admin all" on public.field_tasks;
create policy "field tasks admin all" on public.field_tasks
  for all to public
  using (is_super_admin() or center_id = current_admin_center())
  with check (is_super_admin() or center_id = current_admin_center());
revoke all on public.field_tasks from anon;
grant select, insert, update, delete on public.field_tasks to authenticated;

alter table public.attendance_month_status enable row level security;
alter table public.allowance_status enable row level security;
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
revoke all on public.attendance_month_status from anon;
revoke all on public.allowance_status from anon;
grant select, insert, update, delete on public.attendance_month_status to authenticated;
grant select, insert, update, delete on public.allowance_status to authenticated;

-- 링크 만들기 — 역할 추가. 옛 3인자는 지움(같은 이름 겹침 방지)
drop function if exists public.admin_make_company_link(text, text, int);
create or replace function public.admin_make_company_link(p_company text, p_label text default null, p_days int default null,
                                                          p_role text default 'teacher')
returns jsonb
language plpgsql security definer set search_path = public as $$
declare au public.admin_users; v_key text := _co_key(p_company); v_label text; v_tok text; v_id uuid;
        v_role text := case when p_role = 'hrd' then 'hrd' else 'teacher' end;
begin
  select * into au from admin_users where user_id = auth.uid();
  if au.user_id is null then return jsonb_build_object('ok', false, 'reason', 'auth'); end if;
  select trim(s.company) into v_label from students s
   where s.center_id = au.center_id and _co_key(s.company) = v_key
   order by (s.status = '진행중') desc nulls last limit 1;
  if v_key is null or v_label is null then return jsonb_build_object('ok', false, 'reason', 'company'); end if;
  v_tok := replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '');
  insert into company_links (center_id, company_key, company_label, label, token_hash, created_by, expires_at, role)
  values (au.center_id, v_key, v_label, nullif(left(btrim(coalesce(p_label, '')), 40), ''),
          encode(sha256(convert_to(v_tok, 'UTF8')), 'hex'), au.user_id,
          case when p_days is not null and p_days > 0 then now() + make_interval(days => p_days) end, v_role)
  returning id into v_id;
  return jsonb_build_object('ok', true, 'id', v_id, 'company', v_label, 'role', v_role, 'token', v_tok);
end $$;
revoke all on function public.admin_make_company_link(text, text, int, text) from public, anon;
grant execute on function public.admin_make_company_link(text, text, int, text) to authenticated;

-- 기업 담당자 화면 한 번에
create or replace function public.field_home(p_link text default null, p_month text default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare l public.company_links; v_from date := _absence_month(p_month); v_to date; v_year int; v_studs jsonb; v_extra jsonb := '{}'::jsonb;
begin
  l := _link_me(p_link);
  if l.id is null then return jsonb_build_object('ok', false); end if;
  v_to := (v_from + interval '1 month')::date;
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', s.id, 'name', trim(s.name),
           -- 그 달 날짜별 정규시간·인정·상태(시각 없음)
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
           -- 전 기간 OJT 월 행(예정·실적·능력단위)
           'months', (select coalesce(jsonb_agg(jsonb_build_object('month', to_char(m.month, 'YYYY-MM'), 'planned', m.planned_hours,
                                                                   'actual', m.actual_hours, 'units', m.units) order by m.month), '[]'::jsonb)
                        from attendance_monthly m
                       where m.center_id = s.center_id and m.track = 'ojt'
                         and replace(trim(m.name), ' ', '') = replace(trim(s.name), ' ', '')),
           -- 학생별 OJT 능력단위 요소(학습안내서, sql/64 와 같은 행)
           'units', (select coalesce(jsonb_agg(jsonb_build_object('unit', u.unit, 'hours', u.hours, 'elements', u.elements) order by u.sort, u.unit), '[]'::jsonb)
                       from offjt_units u
                      where u.center_id = s.center_id and u.subject = 'OJT'
                        and u.job_key = 'OJT:' || replace(trim(s.name), ' ', '')),
           'status', case when l.role = 'hrd' then
                     (select coalesce(jsonb_agg(jsonb_build_object('month', to_char(t.month, 'YYYY-MM'), 'course', t.course,
                                                                   'train_days', t.train_days, 'diary_days', t.diary_days,
                                                                   'student_confirmed_on', t.student_confirmed_on, 'center_confirmed_on', t.center_confirmed_on)
                                               order by t.month), '[]'::jsonb)
                        from attendance_month_status t
                       where t.center_id = s.center_id and replace(trim(t.name), ' ', '') = replace(trim(s.name), ' ', '')) end)
           order by s.name), '[]'::jsonb)
    into v_studs
    from students s
   where s.center_id = l.center_id and _co_key(s.company) = l.company_key and coalesce(s.status, '진행중') = '진행중';
  if l.role = 'hrd' then
    select jsonb_build_object('allowance', coalesce(jsonb_agg(jsonb_build_object('period', to_char(a.period, 'YYYY-MM'), 'state', a.state,
                                                                                 'applied_on', a.applied_on, 'checked_at', a.checked_at)
                                                              order by a.period desc), '[]'::jsonb))
      into v_extra
      from allowance_status a where a.center_id = l.center_id and a.company_key = l.company_key;
  end if;
  -- 월말 할 일: 그 달·다음 달 + 지난달까지 아직 안 끝난 것
  v_extra := v_extra || jsonb_build_object('tasks', (select coalesce(jsonb_agg(jsonb_build_object(
      'id', t.id, 'course', t.course, 'kind', t.kind, 'month', to_char(t.month, 'YYYY-MM'), 'due_on', t.due_on,
      'title', t.title, 'note', t.note, 'done_on', t.done_on) order by t.month, t.due_on nulls last, t.kind), '[]'::jsonb)
    from field_tasks t
   where t.center_id = l.center_id and t.company_key = l.company_key
     and ((t.month >= v_from and t.month < (v_to + interval '1 month')::date) or (t.month < v_from and t.done_on is null))));
  return jsonb_build_object('ok', true, 'role', l.role, 'company', l.company_label, 'label', l.label,
                            'month', to_char(v_from, 'YYYY-MM'), 'today', to_char(now() at time zone 'Asia/Seoul', 'YYYY-MM-DD'),
                            'students', v_studs) || v_extra;
end $$;
revoke all on function public.field_home(text, text) from public;
grant execute on function public.field_home(text, text) to anon, authenticated;
