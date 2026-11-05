-- =====================================================================
-- 90_absence_move.sql — 휴가·출장·회사 일정 알리기 + 옮길 날 고르기 (훈련품질관리, 사용자 11/5)
--  · attendance_absences.want_day  — 기업이 고른 옮길 날(선택, 없으면 센터가 정함)
--  · attendance_absences.moved_to  — 센터가 옮긴(옮길) 날. 관리자 [이동 계획 받기] 때 기록 → 기업·학생 화면에 '11/13 → 11/20'
--  · kind 에 'sched'(회사 일정) 추가
--  · 학생·기업 알리기는 원래 날짜 **전날까지**(오늘·지난 날 = too_late, 센터에 연락) — _absence_put 에서 막음
--  · company_absence_move(p_code, p_student, p_day, p_kind, p_note, p_by_name, p_want) — 옮길 날 검사: 같은 달·평일·
--    내일 이후·원래 날과 다름·그 학생의 그날 정규시간 6시간 미만
--  · company_home / my_absences 에 want_day·moved_to (나머지는 sql/71·69 와 같음)
--  · 멱등.
-- =====================================================================

alter table public.attendance_absences add column if not exists want_day date;
alter table public.attendance_absences add column if not exists moved_to date;
alter table public.attendance_absences drop constraint if exists attendance_absences_kind_check;
alter table public.attendance_absences add constraint attendance_absences_kind_check check (kind in ('leave', 'trip', 'sched'));

create or replace function public._absence_put(st public.students, p_day date, p_kind text, p_note text,
                                               p_role text, p_by text, p_link uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare d public.attendance_daily; ex public.attendance_absences; v_note text := nullif(btrim(coalesce(p_note, '')), ''); v_id uuid;
begin
  if p_kind not in ('leave', 'trip', 'sched') then return jsonb_build_object('ok', false, 'reason', 'kind'); end if;
  -- (11/5 훈련품질관리) 학생·기업은 원래 날짜 전날까지만 — 지난 날·오늘은 센터에 연락(시간표 변경은 변경예정일 전일까지)
  if p_role in ('student', 'company', 'teacher') and p_day <= (now() at time zone 'Asia/Seoul')::date then
    return jsonb_build_object('ok', false, 'reason', 'too_late');
  end if;
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

create or replace function public.company_absence_move(p_code text default null, p_student uuid default null, p_day date default null,
                                                       p_kind text default null, p_note text default null, p_by_name text default null,
                                                       p_want date default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare c public.company_codes; st public.students; v_by text := nullif(left(btrim(coalesce(p_by_name, '')), 40), '');
        v_today date := (now() at time zone 'Asia/Seoul')::date; v_wh numeric; r jsonb;
begin
  c := _company_me(p_code);
  if c.code is null then return jsonb_build_object('ok', false); end if;
  if v_by is null then return jsonb_build_object('ok', false, 'reason', 'name'); end if;
  if p_day is null or p_day <= v_today then return jsonb_build_object('ok', false, 'reason', 'too_late'); end if;
  select * into st from students s
   where s.id = p_student and s.center_id = c.center_id and _co_key(s.company) = _co_key(c.company);
  if st.id is null then return jsonb_build_object('ok', false, 'reason', 'student'); end if;
  if p_want is not null then
    if p_want <= v_today or p_want = p_day or date_trunc('month', p_want) <> date_trunc('month', p_day)
       or extract(isodow from p_want) > 5 then
      return jsonb_build_object('ok', false, 'reason', 'want_day');
    end if;
    select coalesce(sum(a.planned_hours), 0) into v_wh from attendance_daily a
     where a.center_id = c.center_id and a.track = 'ojt' and a.day = p_want
       and replace(trim(a.name), ' ', '') = replace(trim(st.name), ' ', '');
    if v_wh >= 6 then return jsonb_build_object('ok', false, 'reason', 'want_full'); end if;
  end if;
  if (select count(*) from attendance_absences a join students s2 on s2.id = a.student_id
       where a.center_id = c.center_id and a.by_role = 'company' and _co_key(s2.company) = _co_key(c.company)
         and a.updated_at > now() - interval '10 minutes') >= 60 then
    return jsonb_build_object('ok', false, 'reason', 'rate');
  end if;
  r := _absence_put(st, p_day, p_kind, p_note, 'company', v_by, null);
  if (r->>'ok')::boolean then
    update attendance_absences set want_day = p_want where id = (r->>'id')::uuid;
  end if;
  return r;
end $$;
revoke all on function public.company_absence_move(text, uuid, date, text, text, text, date) from public;
grant execute on function public.company_absence_move(text, uuid, date, text, text, text, date) to anon, authenticated;

create or replace function public.my_absences(p_code text default null, p_token text default null, p_month text default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare st public.students; v_from date := _absence_month(p_month); v_to date; v jsonb; v_course text;
begin
  st := _chat_me(p_code, p_token);
  if st.id is null then return jsonb_build_object('ok', false); end if;
  v_to := (v_from + interval '1 month')::date;
  select coalesce(jsonb_agg(jsonb_build_object('id', a.id, 'day', a.day, 'kind', a.kind, 'note', a.note, 'state', a.state,
                                               'by_role', a.by_role, 'by_name', a.by_name, 'at', a.updated_at,
                                               'want_day', a.want_day, 'moved_to', a.moved_to) order by a.day), '[]'::jsonb)
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
revoke all on function public.my_absences(text, text, text) from public;
grant execute on function public.my_absences(text, text, text) to anon, authenticated;

create or replace function public.company_home(p_code text default null, p_month text default null)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare c public.company_codes; v_key text; v_from date := _absence_month(p_month); v_to date; v_studs jsonb; v_allow jsonb; v_tasks jsonb;
begin
  c := _company_me(p_code);
  if c.code is null then return jsonb_build_object('ok', false); end if;
  v_key := _co_key(c.company);
  v_to := (v_from + interval '1 month')::date;
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', s.id, 'name', trim(s.name),
           'days', (select coalesce(jsonb_agg(jsonb_build_object('day', a.day, 'course', a.course, 'hours', a.planned_hours,
                                                                 'start', to_char(a.start_time, 'HH24:MI'), 'end', to_char(a.end_time, 'HH24:MI'),
                                                                 'status', coalesce(a.status, 'planned'), 'recognized', a.recognized_hours)
                                               order by a.day), '[]'::jsonb)
                      from attendance_daily a
                     where a.center_id = s.center_id and a.track = 'ojt' and a.day >= v_from and a.day < v_to
                       and coalesce(a.planned_hours, 0) > 0
                       and replace(trim(a.name), ' ', '') = replace(trim(s.name), ' ', '')),
           'absences', (select coalesce(jsonb_agg(jsonb_build_object('id', b.id, 'day', b.day, 'kind', b.kind, 'note', b.note,
                                                                     'state', b.state, 'by_role', b.by_role, 'by_name', b.by_name, 'at', b.updated_at,
                                                                     'want_day', b.want_day, 'moved_to', b.moved_to)
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
                       where t.center_id = s.center_id and replace(trim(t.name), ' ', '') = replace(trim(s.name), ' ', '')),
           -- 학생이 앱에서 'M월분 학습일지 작성 + 출석결과확인 등록' 완료 체크한 달(sql/60·71)
           'checks', (select coalesce(jsonb_agg(substr(t.auto_key, 7) order by t.auto_key), '[]'::jsonb)
                        from tasks t
                        join task_checks tc on tc.task_id = t.id and tc.subject_kind = 'student'
                                           and tc.subject_hash = _task_subject_hash(make_student_token(s.name, s.phone))
                       where t.center_id = s.center_id and t.auto_key like 'diary:%'))
           order by s.name), '[]'::jsonb)
    into v_studs
    from students s
   where s.center_id = c.center_id and _co_key(s.company) = v_key and coalesce(s.status, '진행중') = '진행중';
  select coalesce(jsonb_agg(jsonb_build_object('period', to_char(a.period, 'YYYY-MM'), 'state', a.state,
                                               'applied_on', a.applied_on, 'checked_at', a.checked_at) order by a.period desc), '[]'::jsonb)
    into v_allow
    from allowance_status a where a.center_id = c.center_id and a.company_key = v_key;
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
revoke all on function public.company_home(text, text) from public;
grant execute on function public.company_home(text, text) to anon, authenticated;
