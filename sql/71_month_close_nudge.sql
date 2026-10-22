-- =====================================================================
-- sql/71_month_close_nudge.sql — 월 마감 = 학생 앱 완료 체크 + 관리자 [알림 보내기] (2026-10-22, docs/FIELD.md)
--
-- 사용자 요청(10/22): "월 마감도 그냥 학생들 학습일지 및 출결확인 누르면, 내가 버튼 누르면 알람갈 수 있도록".
--   월 마감 상태 = 학생이 앱 홈에서 누르는 'M월분 학습일지 작성 + 출석결과확인 등록' 할 일(sql/60 auto_key 'diary:YYYY-MM')의
--   완료 체크(task_checks). 관리자 화면은 기존 admin_task_progress 로 완료·미완료를 보고, 미완료 학생에게 버튼 하나로 개인 알림.
--
--  · admin_diary_nudge(p_month 'YYYY-MM', p_names text[]) — 관리자(자기 센터)만. 그 달 할 일을 보장하고, 명단(진행중·휴대폰 있음)에서
--      이름이 맞고 아직 완료 체크가 없는 학생에게 개인 공지(notices personal + notice_recipients) → push-sender 깨움.
--      같은 달 알림을 10분 안에 또 누르면 'recent' 로 거절(두 번 눌림 방지).
--  · company_home(sql/70) — 학생마다 'checks'(완료 체크한 달 'YYYY-MM' 목록) 추가. 나머지는 sql/70 과 같음.
--  · 멱등: create or replace.
-- =====================================================================

create or replace function public.admin_diary_nudge(p_month text, p_names text[])
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  au public.admin_users; v_center uuid; m date; v_task uuid; v_notice uuid; v_by text; v_title text; v_body text;
  r record; tok text; cnt int := 0; skipped int := 0; want text[];
begin
  select * into au from admin_users where user_id = auth.uid();
  if au.user_id is null then return jsonb_build_object('ok', false, 'reason', 'auth'); end if;
  v_center := au.center_id;
  if coalesce(p_month, '') !~ '^\d{4}-\d{2}$' then return jsonb_build_object('ok', false, 'reason', 'month'); end if;
  m := to_date(p_month || '-01', 'YYYY-MM-DD');
  select coalesce(array_agg(distinct replace(trim(x), ' ', '')), '{}') into want from unnest(coalesce(p_names, '{}')) x where trim(coalesce(x, '')) <> '';
  if array_length(want, 1) is null then return jsonb_build_object('ok', false, 'reason', 'names'); end if;
  if exists (select 1 from notices where center_id = v_center and created_by like 'admin:diary-nudge-' || p_month || '-%'
               and created_at > now() - interval '10 minutes') then
    return jsonb_build_object('ok', false, 'reason', 'recent');
  end if;
  v_task := ensure_monthly_diary_task(v_center, m);
  v_by := 'admin:diary-nudge-' || p_month || '-' || to_char(now() at time zone 'Asia/Seoul', 'MMDDHH24MI');
  v_title := format('%s월 학습활동서·출석 확인', extract(month from m)::int);
  v_body := format('%s월 학습활동서를 마무리하고 고용24에서 [출석결과확인 등록]까지 눌러주세요(저장만 하지 말고 꼭 등록까지). 다 하면 앱 홈에서 완료 체크를 눌러주세요.',
                   extract(month from m)::int);
  for r in
    select distinct on (replace(trim(s.name), ' ', '')) s.name, s.phone
      from students s
     where s.center_id = v_center and coalesce(s.status, '진행중') = '진행중' and s.phone is not null
       and replace(trim(s.name), ' ', '') = any(want)
     order by replace(trim(s.name), ' ', ''), s.cohort desc nulls last
  loop
    tok := make_student_token(r.name, r.phone);
    if exists (select 1 from task_checks tc where tc.task_id = v_task and tc.subject_kind = 'student' and tc.subject_hash = _task_subject_hash(tok)) then
      skipped := skipped + 1; continue;   -- 그 사이 완료 체크한 학생
    end if;
    if v_notice is null then
      insert into notices (center_id, title, body, target_scope, published, created_by, pushed)
      values (v_center, v_title, v_body, 'personal', true, v_by, false)
      returning id into v_notice;
    end if;
    insert into notice_recipients (notice_id, student_token, title, body, center_id)
    values (v_notice, tok, v_title, v_body, v_center);
    cnt := cnt + 1;
  end loop;
  if cnt > 0 then
    begin
      perform net.http_get('https://ggitgqijycvnhhraxzgn.supabase.co/functions/v1/push-sender');
    exception when others then null;
    end;
  end if;
  return jsonb_build_object('ok', true, 'sent', cnt, 'skipped', skipped, 'asked', array_length(want, 1));
end $$;
revoke all on function public.admin_diary_nudge(text, text[]) from public, anon;
grant execute on function public.admin_diary_nudge(text, text[]) to authenticated;

-- company_home — 학생마다 완료 체크한 달(checks) 추가
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
