-- =====================================================================
-- sql/69_absence.sql — 휴가·출장 체크 → 정규시간 옮기기 1단계: 표와 함수 (2026-10-22, docs/LEAVE.md)
--
-- 사용자 결정(10/22): 선생님이 그 달 OJT 정규시간을 먼저 등록해 두고, 휴가·출장 가는 날만 체크하면 그날을 옮긴다.
--   체크는 학생·현장교사 둘 다(누가 했는지 남김), 마감 없음(지난 날도), 출장도 옮김, 현장교사는 기업 링크로 그 기업 학생만.
--
--  · attendance_absences — 학생 한 명·하루 한 건(접수·반영 중인 것). kind 'leave'(휴가) / 'trip'(출장).
--      state 'open'(접수) → 'applied'(정규시간 옮김) / 'canceled'(취소) / 'rejected'(반려). 센터 스코프, 관리자만 직접 접근.
--  · company_links — 현장교사용 기업 링크. 원문 토큰은 만들 때 한 번만 돌려주고 sha256 만 저장. 끊기 = revoked_at.
--  · 체크할 수 있는 날 = 그 학생에게 OJT 정규시간(예정 포함, attendance_daily track=ojt, planned_hours>0)이 있는 날.
--  · 학생 RPC(본인 확인 = _chat_me: 코드 또는 서명토큰, 실패만 IP 제한):
--      my_absences(p_code, p_token, p_month)                  → 내 체크 목록 + 같은 과정 학생 수
--      report_absence(p_code, p_token, p_day, p_kind, p_note)  → 체크(접수 중이면 종류·메모만 바꿈)
--      cancel_absence(p_code, p_token, p_id)                   → 접수 중인 내 체크 취소
--  · 현장교사 RPC(링크 확인 실패는 IP 당 10분 30회 — 'linkfail:'):
--      company_plan(p_link, p_month)                          → 그 기업 학생 × 날짜별 정규시간 + 체크
--      company_report_absence(p_link, p_student, p_day, p_kind, p_note, p_by_name)
--      company_cancel_absence(p_link, p_id)
--  · 관리자: 두 표 직접 접근(센터 스코프 RLS) + admin_make_company_link(p_company, p_label, p_days) → 원문 링크 토큰.
--  · anon 은 표 직접 접근 없음 → rls-check MUST_BE_BLOCKED 에 attendance_absences·company_links.
--  · 멱등: if not exists / create or replace / drop policy if exists.
-- =====================================================================

create table if not exists public.attendance_absences (
  id uuid primary key default gen_random_uuid(),
  center_id uuid not null references public.centers(id),
  student_id uuid not null,              -- students.id
  name text not null,                    -- 명단 이름(attendance_daily.name 과 맞춤)
  company text,                          -- 명단 기업명(접수 당시)
  course text,                           -- 그날 정규시간의 과정(attendance_daily.course)
  day date not null,
  kind text not null check (kind in ('leave', 'trip')),
  note text check (char_length(note) <= 300),
  by_role text not null check (by_role in ('student', 'teacher', 'admin')),
  by_name text,                          -- 현장교사가 적은 이름 / 학생 이름 / 관리자 표시 이름
  link_id uuid,                          -- 현장교사 링크로 들어온 것
  state text not null default 'open' check (state in ('open', 'applied', 'canceled', 'rejected')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  handled_at timestamptz,
  handled_by uuid                        -- 반영·반려한 관리자
);
create unique index if not exists attendance_absences_live_uniq
  on public.attendance_absences (center_id, student_id, day) where state in ('open', 'applied');
create index if not exists attendance_absences_center_day on public.attendance_absences (center_id, day);

create table if not exists public.company_links (
  id uuid primary key default gen_random_uuid(),
  center_id uuid not null references public.centers(id),
  company_key text not null,             -- _co_key(기업명)
  company_label text not null,           -- 보여줄 기업명
  label text,                            -- 누구에게 준 링크인지(예: '현장교사 ○○○')
  token_hash text not null unique,       -- sha256(원문 토큰) hex
  created_by uuid,
  created_at timestamptz not null default now(),
  expires_at timestamptz,
  revoked_at timestamptz,
  last_used_at timestamptz
);
create index if not exists company_links_center on public.company_links (center_id, company_key);

alter table public.attendance_absences enable row level security;
alter table public.company_links enable row level security;

-- 관리자만 직접 접근(센터 스코프). to public + 헬퍼 패턴(sql/62·65 와 같음)
drop policy if exists "absences admin all" on public.attendance_absences;
create policy "absences admin all" on public.attendance_absences
  for all to public
  using (is_super_admin() or center_id = current_admin_center())
  with check (is_super_admin() or center_id = current_admin_center());
drop policy if exists "company links admin all" on public.company_links;
create policy "company links admin all" on public.company_links
  for all to public
  using (is_super_admin() or center_id = current_admin_center())
  with check (is_super_admin() or center_id = current_admin_center());

revoke all on public.attendance_absences from anon;
revoke all on public.company_links from anon;
grant select, insert, update, delete on public.attendance_absences to authenticated;
grant select, insert, update, delete on public.company_links to authenticated;

-- 그 학생의 그날 OJT 정규시간(예정 포함) — 없으면 null
create or replace function public._absence_day(p_center uuid, p_name text, p_day date)
returns public.attendance_daily
language sql stable security definer set search_path = public as $$
  select * from attendance_daily a
   where a.center_id = p_center and a.track = 'ojt' and a.day = p_day and coalesce(a.planned_hours, 0) > 0
     and replace(trim(a.name), ' ', '') = replace(trim(p_name), ' ', '')
   limit 1
$$;
revoke all on function public._absence_day(uuid, text, date) from public, anon, authenticated;

-- 체크 한 건 넣기(학생·현장교사 공통). 접수 중인 같은 날이 있으면 종류·메모만 바꿈, 반영된 날은 그대로 둠
create or replace function public._absence_put(st public.students, p_day date, p_kind text, p_note text,
                                               p_role text, p_by text, p_link uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare d public.attendance_daily; ex public.attendance_absences; v_note text := nullif(btrim(coalesce(p_note, '')), ''); v_id uuid;
begin
  if p_kind not in ('leave', 'trip') then return jsonb_build_object('ok', false, 'reason', 'kind'); end if;
  if v_note is not null and char_length(v_note) > 300 then return jsonb_build_object('ok', false, 'reason', 'length'); end if;
  d := _absence_day(st.center_id, st.name, p_day);
  if d.id is null then return jsonb_build_object('ok', false, 'reason', 'no_day'); end if;
  select * into ex from attendance_absences a
   where a.center_id = st.center_id and a.student_id = st.id and a.day = p_day and a.state in ('open', 'applied');
  if ex.id is not null then
    if ex.state = 'applied' then return jsonb_build_object('ok', false, 'reason', 'applied', 'id', ex.id); end if;
    update attendance_absences set kind = p_kind, note = v_note, by_role = p_role, by_name = p_by, link_id = p_link, updated_at = now()
     where id = ex.id;
    return jsonb_build_object('ok', true, 'id', ex.id, 'updated', true);
  end if;
  insert into attendance_absences (center_id, student_id, name, company, course, day, kind, note, by_role, by_name, link_id)
  values (st.center_id, st.id, trim(st.name), trim(st.company), d.course, p_day, p_kind, v_note, p_role, p_by, p_link)
  returning id into v_id;
  return jsonb_build_object('ok', true, 'id', v_id, 'updated', false);
end $$;
revoke all on function public._absence_put(public.students, date, text, text, text, text, uuid) from public, anon, authenticated;

-- 같은 과정(그 달 정규시간의 course 가 같은) 학생 수 — "이 날은 과정 전체가 옮겨집니다" 안내용
create or replace function public._absence_course_size(p_center uuid, p_course text, p_from date, p_to date)
returns int
language sql stable security definer set search_path = public as $$
  select count(distinct replace(trim(a.name), ' ', ''))::int from attendance_daily a
   where a.center_id = p_center and a.track = 'ojt' and a.course = p_course and a.day >= p_from and a.day < p_to
$$;
revoke all on function public._absence_course_size(uuid, text, date, date) from public, anon, authenticated;

create or replace function public._absence_month(p_month text)
returns date
language sql stable set search_path = public as $$
  select case when coalesce(p_month, '') ~ '^\d{4}-\d{2}$' then to_date(p_month || '-01', 'YYYY-MM-DD')
              else date_trunc('month', (now() at time zone 'Asia/Seoul'))::date end
$$;

-- ---------- 학생 ----------
create or replace function public.my_absences(p_code text default null, p_token text default null, p_month text default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare st public.students; v_from date := _absence_month(p_month); v_to date; v jsonb; v_course text;
begin
  st := _chat_me(p_code, p_token);
  if st.id is null then return jsonb_build_object('ok', false); end if;
  v_to := (v_from + interval '1 month')::date;
  select coalesce(jsonb_agg(jsonb_build_object('id', a.id, 'day', a.day, 'kind', a.kind, 'note', a.note, 'state', a.state,
                                               'by_role', a.by_role, 'by_name', a.by_name, 'at', a.updated_at) order by a.day), '[]'::jsonb)
    into v from attendance_absences a
   where a.center_id = st.center_id and a.student_id = st.id and a.day >= v_from and a.day < v_to
     and a.state <> 'canceled';
  select a.course into v_course from attendance_daily a
   where a.center_id = st.center_id and a.track = 'ojt' and a.day >= v_from and a.day < v_to
     and replace(trim(a.name), ' ', '') = replace(trim(st.name), ' ', '') and a.course is not null
   limit 1;
  return jsonb_build_object('ok', true, 'month', to_char(v_from, 'YYYY-MM'), 'absences', v,
                            'course_size', case when v_course is null then 1 else _absence_course_size(st.center_id, v_course, v_from, v_to) end);
end $$;

create or replace function public.report_absence(p_code text default null, p_token text default null, p_day date default null,
                                                 p_kind text default null, p_note text default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare st public.students;
begin
  st := _chat_me(p_code, p_token);
  if st.id is null then return jsonb_build_object('ok', false); end if;
  if (select count(*) from attendance_absences a where a.student_id = st.id and a.updated_at > now() - interval '10 minutes') >= 30 then
    return jsonb_build_object('ok', false, 'reason', 'rate');
  end if;
  return _absence_put(st, p_day, p_kind, p_note, 'student', trim(st.name), null);
end $$;

create or replace function public.cancel_absence(p_code text default null, p_token text default null, p_id uuid default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare st public.students; ex public.attendance_absences;
begin
  st := _chat_me(p_code, p_token);
  if st.id is null then return jsonb_build_object('ok', false); end if;
  select * into ex from attendance_absences a where a.id = p_id and a.center_id = st.center_id and a.student_id = st.id;
  if ex.id is null then return jsonb_build_object('ok', false, 'reason', 'not_found'); end if;
  if ex.state <> 'open' then return jsonb_build_object('ok', false, 'reason', ex.state); end if;
  update attendance_absences set state = 'canceled', updated_at = now() where id = ex.id;
  return jsonb_build_object('ok', true);
end $$;

-- ---------- 현장교사(기업 링크) ----------
-- 링크 확인: 끊기지 않고 기한 안이면 그 링크 행. 실패하면 IP 실패 횟수 +1
create or replace function public._link_me(p_link text)
returns public.company_links
language plpgsql security definer set search_path = public as $$
declare l public.company_links; ip text;
begin
  if char_length(coalesce(p_link, '')) >= 32 then
    select * into l from company_links c
     where c.token_hash = encode(sha256(convert_to(p_link, 'UTF8')), 'hex')
       and c.revoked_at is null and (c.expires_at is null or c.expires_at > now());
  end if;
  if l.id is null then
    ip := coalesce(current_setting('request.headers', true)::jsonb ->> 'x-forwarded-for', 'unknown');
    begin
      perform check_verify_rate('linkfail:' || ip);
    exception when undefined_function then null;
    end;
  else
    update company_links set last_used_at = now() where id = l.id;
  end if;
  return l;
end $$;
revoke all on function public._link_me(text) from public, anon, authenticated;

create or replace function public.company_plan(p_link text default null, p_month text default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare l public.company_links; v_from date := _absence_month(p_month); v_to date; v jsonb;
begin
  l := _link_me(p_link);
  if l.id is null then return jsonb_build_object('ok', false); end if;
  v_to := (v_from + interval '1 month')::date;
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', s.id, 'name', trim(s.name),
           'days', (select coalesce(jsonb_agg(jsonb_build_object('day', a.day, 'course', a.course, 'hours', a.planned_hours,
                                                                 'start', to_char(a.start_time, 'HH24:MI'), 'end', to_char(a.end_time, 'HH24:MI'))
                                               order by a.day), '[]'::jsonb)
                      from attendance_daily a
                     where a.center_id = s.center_id and a.track = 'ojt' and a.day >= v_from and a.day < v_to
                       and coalesce(a.planned_hours, 0) > 0
                       and replace(trim(a.name), ' ', '') = replace(trim(s.name), ' ', '')),
           'absences', (select coalesce(jsonb_agg(jsonb_build_object('id', b.id, 'day', b.day, 'kind', b.kind, 'note', b.note,
                                                                     'state', b.state, 'by_role', b.by_role, 'by_name', b.by_name)
                                                   order by b.day), '[]'::jsonb)
                          from attendance_absences b
                         where b.center_id = s.center_id and b.student_id = s.id and b.day >= v_from and b.day < v_to
                           and b.state <> 'canceled'))
           order by s.name), '[]'::jsonb)
    into v
    from students s
   where s.center_id = l.center_id and _co_key(s.company) = l.company_key and coalesce(s.status, '진행중') = '진행중';
  return jsonb_build_object('ok', true, 'company', l.company_label, 'month', to_char(v_from, 'YYYY-MM'), 'students', v);
end $$;

create or replace function public.company_report_absence(p_link text default null, p_student uuid default null, p_day date default null,
                                                         p_kind text default null, p_note text default null, p_by_name text default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare l public.company_links; st public.students; v_by text := nullif(left(btrim(coalesce(p_by_name, '')), 40), '');
begin
  l := _link_me(p_link);
  if l.id is null then return jsonb_build_object('ok', false); end if;
  select * into st from students s
   where s.id = p_student and s.center_id = l.center_id and _co_key(s.company) = l.company_key;
  if st.id is null then return jsonb_build_object('ok', false, 'reason', 'student'); end if;
  if (select count(*) from attendance_absences a where a.link_id = l.id and a.updated_at > now() - interval '10 minutes') >= 60 then
    return jsonb_build_object('ok', false, 'reason', 'rate');
  end if;
  return _absence_put(st, p_day, p_kind, p_note, 'teacher', coalesce(v_by, l.label, '현장교사'), l.id);
end $$;

create or replace function public.company_cancel_absence(p_link text default null, p_id uuid default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare l public.company_links; ex public.attendance_absences;
begin
  l := _link_me(p_link);
  if l.id is null then return jsonb_build_object('ok', false); end if;
  select a.* into ex from attendance_absences a join students s on s.id = a.student_id
   where a.id = p_id and a.center_id = l.center_id and _co_key(s.company) = l.company_key;
  if ex.id is null then return jsonb_build_object('ok', false, 'reason', 'not_found'); end if;
  if ex.state <> 'open' then return jsonb_build_object('ok', false, 'reason', ex.state); end if;
  update attendance_absences set state = 'canceled', updated_at = now() where id = ex.id;
  return jsonb_build_object('ok', true);
end $$;

-- ---------- 관리자 ----------
-- 기업 링크 만들기: 원문 토큰(64자)은 이때 한 번만 돌려줌. 기업은 명단 기업명으로(같은 센터 학생이 있어야 함)
create or replace function public.admin_make_company_link(p_company text, p_label text default null, p_days int default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare au public.admin_users; v_key text := _co_key(p_company); v_label text; v_tok text; v_id uuid;
begin
  select * into au from admin_users where user_id = auth.uid();
  if au.user_id is null then return jsonb_build_object('ok', false, 'reason', 'auth'); end if;
  select trim(s.company) into v_label from students s
   where s.center_id = au.center_id and _co_key(s.company) = v_key
   order by (s.status = '진행중') desc nulls last limit 1;
  if v_key is null or v_label is null then return jsonb_build_object('ok', false, 'reason', 'company'); end if;
  v_tok := replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '');
  insert into company_links (center_id, company_key, company_label, label, token_hash, created_by, expires_at)
  values (au.center_id, v_key, v_label, nullif(left(btrim(coalesce(p_label, '')), 40), ''),
          encode(sha256(convert_to(v_tok, 'UTF8')), 'hex'), au.user_id,
          case when p_days is not null and p_days > 0 then now() + make_interval(days => p_days) end)
  returning id into v_id;
  return jsonb_build_object('ok', true, 'id', v_id, 'company', v_label, 'token', v_tok);
end $$;

revoke all on function public.my_absences(text, text, text) from public;
revoke all on function public.report_absence(text, text, date, text, text) from public;
revoke all on function public.cancel_absence(text, text, uuid) from public;
revoke all on function public.company_plan(text, text) from public;
revoke all on function public.company_report_absence(text, uuid, date, text, text, text) from public;
revoke all on function public.company_cancel_absence(text, uuid) from public;
revoke all on function public.admin_make_company_link(text, text, int) from public, anon;
grant execute on function public.my_absences(text, text, text) to anon, authenticated;
grant execute on function public.report_absence(text, text, date, text, text) to anon, authenticated;
grant execute on function public.cancel_absence(text, text, uuid) to anon, authenticated;
grant execute on function public.company_plan(text, text) to anon, authenticated;
grant execute on function public.company_report_absence(text, uuid, date, text, text, text) to anon, authenticated;
grant execute on function public.company_cancel_absence(text, uuid) to anon, authenticated;
grant execute on function public.admin_make_company_link(text, text, int) to authenticated;
