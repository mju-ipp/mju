-- 78. 알림 정리(2026-10-23 사용자) — 재실행해도 안전
-- ① 비콘 알림(평일 09:00·16:00): "공휴일이랑 훈련 없는 날에는 빼야" → 오늘 OJT 정규시간이 등록된 학생에게만.
--    (공휴일·휴가로 옮긴 날·주 2~3일 출근 학생의 쉬는 날은 정규시간이 없으니 자동으로 빠짐.
--     정규시간을 아직 등록하지 않은 과정은 알림도 안 감 — 등록하면 다음 날부터)
-- ② 내부평가·면담일지 마감 알림: "D-3부터 매일", 학생 + 기업 둘 다. 평일 09:05.
--    마감 3일 전~당일, 아직 [받음](done_on) 안 된 field_tasks.
--    · 학생: 내부평가 = 그 과정 학생(월 마감 행의 과정명, '과정명(…)' 포함 — 인지컨트롤스처럼 과정연계·일반이 시간표 하나),
--            과정 학생을 못 찾으면 그 기업 학생 전원 / 면담일지(과정 없음) = 그 기업 학생 전원
--    · 기업: 그 기업 코드로 알림을 켠 기기(아래 ③의 device_key)
--    한 사람에게 여러 건이면 한 알림에 줄로. 지난 알림 글은 매번 지우고 새로 씀(비콘 알림과 같은 방식).
-- ③ register_push_token: 기업 코드로 알림을 켜면 device_key 를 서버가 'co:'||md5(코드||센터) 로 정함(브라우저가 못 꾸밈).
--    학생 기기가 'co:' 로 시작하는 키를 보내면 버림.

-- ① ----------------------------------------------------------------------------------------
create or replace function public.send_beacon_reminders(p_kind text default 'in')
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  v_month date; v_notice uuid; cnt int := 0; total int := 0; n_centers int := 0;
  r record; c record;
  v_title text; v_body_fmt text; v_common text;
  v_today date := (now() at time zone 'Asia/Seoul')::date;
begin
  v_month := date_trunc('month', (now() at time zone 'Asia/Seoul'))::date;

  if p_kind = 'out' then
    v_title := '퇴실 비콘 알림';
    v_common := '퇴근 전 퇴실 비콘 꼭 찍어주세요! 오늘도 수고했어요.';
    v_body_fmt := '퇴근 전 퇴실 비콘 꼭 찍어주세요! 이번 달 출석 진도 %s시간 / 배정 %s시간이에요.';
  else
    v_title := '입실 비콘 알림';
    v_common := '좋은 아침이에요! 출근하면 입실 비콘부터 찍어주세요.';
    v_body_fmt := '출근하면 입실 비콘부터 찍어주세요! 이번 달 출석 진도 %s시간 / 배정 %s시간이에요.';
  end if;

  for c in select id from centers where active order by created_at loop
    delete from notice_recipients where notice_id in
      (select id from notices where created_by like 'auto:beacon%' and center_id = c.id);
    delete from notices where created_by like 'auto:beacon%' and center_id = c.id;

    v_notice := null; cnt := 0;
    for r in
      select a.name, s.phone, a.planned_hours, coalesce(a.actual_hours, 0) as actual_hours
        from attendance_monthly a
        join students s on s.center_id = a.center_id
         and replace(trim(s.name), ' ', '') = replace(trim(a.name), ' ', '')
       where a.center_id = c.id and a.month = v_month and a.track = 'ojt'
         and a.planned_hours > 0
         and coalesce(a.actual_hours, 0) < a.planned_hours
         and coalesce(student_phase(s.cohort, s.type1, s.phase_override, v_today), 'ojt') = 'ojt'
         and coalesce(s.status, '진행중') = '진행중'
         -- (10/23) 오늘 OJT 정규시간이 있는 학생만 — 공휴일·훈련 없는 날 제외
         and exists (select 1 from attendance_daily d
                      where d.center_id = c.id and d.track = 'ojt' and d.day = v_today and d.planned_hours > 0
                        and replace(trim(d.name), ' ', '') = replace(trim(a.name), ' ', ''))
    loop
      if v_notice is null then
        insert into notices (center_id, title, body, target_scope, published, created_by, pushed)
        values (c.id, v_title, v_common, 'personal', true, 'auto:beacon-' || p_kind, false)
        returning id into v_notice;
      end if;
      insert into notice_recipients (notice_id, student_token, title, body, center_id)
      values (v_notice, make_student_token(r.name, r.phone), v_title,
              format(v_body_fmt, r.actual_hours::int, r.planned_hours::int), c.id);
      cnt := cnt + 1;
    end loop;

    total := total + cnt;
    if cnt > 0 then n_centers := n_centers + 1; end if;
  end loop;

  if total = 0 then
    return jsonb_build_object('ok', true, 'kind', p_kind, 'sent', 0,
                              'centers', 0, 'month', to_char(v_month, 'YYYY-MM'), 'note', 'no_targets');
  end if;

  begin
    perform net.http_get('https://ggitgqijycvnhhraxzgn.supabase.co/functions/v1/push-sender');
  exception when others then null;
  end;

  return jsonb_build_object('ok', true, 'kind', p_kind, 'sent', total,
                            'centers', n_centers, 'month', to_char(v_month, 'YYYY-MM'));
end $$;

-- ③ 기업 기기 키 ----------------------------------------------------------------------------
create or replace function public._company_device_key(p_code text, p_center uuid)
returns text language sql immutable as $$ select 'co:' || md5(coalesce(p_code, '') || coalesce(p_center::text, '')) $$;
revoke execute on function public._company_device_key(text, uuid) from public, anon, authenticated;

create or replace function public.register_push_token(p_slug text, p_code text, p_row jsonb)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  v_center uuid;
  v_token text;
  v_row jsonb;
  updated boolean;
  cc public.company_codes;
begin
  v_center := public._center_from_slug_or_code(p_slug, p_code);
  if v_center is null then
    return jsonb_build_object('ok', false, 'reason', 'center');
  end if;
  v_token := coalesce(p_row ->> 'token', '');
  if v_token = '' then
    return jsonb_build_object('ok', false, 'reason', 'token');
  end if;

  v_row := public._jsonb_pick_keys(coalesce(p_row, '{}'::jsonb), array[
      'token','target_type','job_key','company','type1','manager','device_key',
      'interest_jobs','platform','updated_at'
    ])
    || jsonb_build_object('center_id', v_center, 'token', v_token);
  -- (10/23) 기업 코드면 기업·키를 서버가 정함. 학생 기기가 기업 키를 흉내 내면 버림
  if coalesce(p_code, '') <> '' then
    select * into cc from company_codes
     where code = upper(regexp_replace(p_code, '[^A-Za-z0-9]', '', 'g')) and active;
  end if;
  if cc.code is not null then
    v_row := v_row || jsonb_build_object('target_type', 'company', 'company', cc.company,
                                         'device_key', public._company_device_key(cc.code, cc.center_id), 'center_id', cc.center_id);
  elsif coalesce(v_row ->> 'device_key', '') like 'co:%' then
    v_row := v_row || jsonb_build_object('device_key', null);
  end if;

  updated := public._jsonb_update_by_text_public('push_tokens', v_row, 'token', v_token);
  if not updated then
    begin
      perform public._jsonb_insert_public('push_tokens', v_row);
    exception when unique_violation then
      perform public._jsonb_update_by_text_public('push_tokens', v_row, 'token', v_token);
      return jsonb_build_object('ok', true, 'duplicate', true, 'center_id', v_center);
    end;
  end if;
  return jsonb_build_object('ok', true, 'center_id', v_center);
end $$;

-- ② 마감 알림 -------------------------------------------------------------------------------
create or replace function public.send_field_task_reminders()
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  v_today date := (now() at time zone 'Asia/Seoul')::date;
  c record; v_rows jsonb; v_notice uuid; n int; total int := 0;
  v_title text := '내부평가·면담일지 마감 알림';
begin
  if extract(isodow from v_today) > 5 then return jsonb_build_object('ok', true, 'note', 'weekend'); end if;
  for c in select id from centers where active order by created_at loop
    delete from notice_recipients where notice_id in
      (select id from notices where created_by like 'auto:fieldtask%' and center_id = c.id);
    delete from notices where created_by like 'auto:fieldtask%' and center_id = c.id;

    with t as (
      select ft.company_key, ft.course, ft.kind, ft.title, ft.due_on, (ft.due_on - v_today) dd
        from field_tasks ft
       where ft.center_id = c.id and ft.done_on is null and ft.due_on between v_today and v_today + 3
    ), line as (
      select t.*, format('%s · %s (%s/%s %s까지)',
               case when dd = 0 then '오늘 마감' else 'D-' || dd end, t.title,
               extract(month from t.due_on)::int, extract(day from t.due_on)::int,
               (array['일','월','화','수','목','금','토'])[extract(dow from t.due_on)::int + 1]) txt
        from t
    ), stu as (
      select s.name, s.phone, _co_key(s.company) ck, replace(trim(s.name), ' ', '') nm
        from students s
       where s.center_id = c.id and coalesce(s.status, '진행중') = '진행중' and s.phone is not null and s.company is not null
    ), cm as (
      select distinct course, replace(trim(name), ' ', '') nm from attendance_month_status where center_id = c.id and course is not null
    ), rcpt as (
      select make_student_token(stu.name, stu.phone) k, l.txt
        from line l join stu on stu.ck = l.company_key
       where l.course is null
          or not exists (select 1 from cm where cm.course = l.course or cm.course like l.course || '(%')
          or exists (select 1 from cm where (cm.course = l.course or cm.course like l.course || '(%') and cm.nm = stu.nm)
      union all
      select public._company_device_key(cc.code, cc.center_id), l.txt
        from line l join company_codes cc on cc.center_id = c.id and cc.active and _co_key(cc.company) = l.company_key
    )
    select jsonb_agg(jsonb_build_object('k', k, 'body', body)) into v_rows
      from (select k, string_agg(distinct txt, E'\n' order by txt) body from rcpt group by k) x;

    if v_rows is null then continue; end if;
    insert into notices (center_id, title, body, target_scope, published, created_by, pushed)
    values (c.id, v_title, '마감이 다가오는 내부평가·면담일지가 있어요.', 'personal', true, 'auto:fieldtask-' || to_char(v_today, 'YYYY-MM-DD'), false)
    returning id into v_notice;
    insert into notice_recipients (notice_id, student_token, title, body, center_id)
    select v_notice, e ->> 'k', v_title, e ->> 'body', c.id from jsonb_array_elements(v_rows) e;
    get diagnostics n = row_count;
    total := total + n;
  end loop;

  if total > 0 then
    begin
      perform net.http_get('https://ggitgqijycvnhhraxzgn.supabase.co/functions/v1/push-sender');
    exception when others then null;
    end;
  end if;
  return jsonb_build_object('ok', true, 'recipients', total);
end $$;
revoke execute on function public.send_field_task_reminders() from public, anon, authenticated;

-- 평일 09:05(한국) = 00:05 UTC
select cron.unschedule('fieldtask-reminders') where exists (select 1 from cron.job where jobname = 'fieldtask-reminders');
select cron.schedule('fieldtask-reminders', '5 0 * * 1-5', $$select public.send_field_task_reminders()$$);
