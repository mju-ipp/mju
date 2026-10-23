-- 82. 내부평가·면담일지 마감 알림을 3일 전·당일 두 번으로 (2026-10-23 사용자: "D-3부터 계속은 좀 그런가" → 두 번)
-- 재실행해도 안전. 학생·기업 둘 다 같은 규칙(받는 사람·묶는 방식·[받음]이면 멈춤은 sql/78 그대로).
--  · 전: 마감 3일 전~당일 평일 매일(최대 4통). 후: 3일 전 한 번 + 당일 한 번.
--  · 크론이 평일만 돌아서 3일 전이 토·일이면 그 앞 금요일에(D-4·D-5로 표시), 마감일이 토·일이면 당일 알림도 금요일에(D-1·D-2).
--    공휴일은 따로 빼지 않음.
--  · 시험용으로 p_today(한국 날짜) 인자 추가 — 크론은 인자 없이 부름(옛 무인자 함수는 지우고 기본값 있는 하나로).

drop function if exists public.send_field_task_reminders();
create or replace function public.send_field_task_reminders(p_today date default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  v_today date := coalesce(p_today, (now() at time zone 'Asia/Seoul')::date);
  v_fri boolean;
  c record; v_rows jsonb; v_notice uuid; n int; total int := 0;
  v_title text := '내부평가·면담일지 마감 알림';
begin
  if extract(isodow from v_today) > 5 then return jsonb_build_object('ok', true, 'note', 'weekend'); end if;
  v_fri := extract(isodow from v_today) = 5;
  for c in select id from centers where active order by created_at loop
    delete from notice_recipients where notice_id in
      (select id from notices where created_by like 'auto:fieldtask%' and center_id = c.id);
    delete from notices where created_by like 'auto:fieldtask%' and center_id = c.id;

    with t as (
      select ft.company_key, ft.course, ft.kind, ft.title, ft.due_on, (ft.due_on - v_today) dd
        from field_tasks ft
       where ft.center_id = c.id and ft.done_on is null and ft.due_on between v_today and v_today + 5
         -- (sql/82) 3일 전·당일만. 그 날이 주말이면 앞 금요일에: 금요일 D-4·D-5 = 3일 전이 토·일, D-1·D-2 = 마감일이 토·일
         and ((ft.due_on - v_today) in (0, 3) or (v_fri and (ft.due_on - v_today) in (1, 2, 4, 5)))
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
revoke execute on function public.send_field_task_reminders(date) from public, anon, authenticated;
-- 크론(fieldtask-reminders, 평일 09:05)은 그대로 — 'select public.send_field_task_reminders()' 가 새 함수를 부름
