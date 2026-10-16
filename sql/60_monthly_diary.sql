-- =====================================================================
-- 60_monthly_diary.sql — 월 학습활동서 할 일 자동 생성 + 1일·2일 알림 (마감 매월 3일) — docs/OFFJT.md 새 2단계
--
-- 왜 만들었나
--   "M월분 학습일지 작성 + 출석결과확인 등록" 할 일을 관리자가 매달 손으로 고쳐 쓰다 보니
--   10월분 메모에 "8월 학습일지"가 남는 일이 생겼고(10/16 확인), 독촉도 D-3에 손으로 보냈다.
--   사용자 결정(10/16): 학습활동서는 한 달 단위로 체크, 월초에 "지난달 학습일지·출석 확인" 알림, 마감 3일.
--
-- 동작 (센터 설정 centers.auto_monthly_diary = true 인 센터만 — 처음엔 mju 만)
--   매월 1일 09:00  run_monthly_diary('d1')
--     ① 이번 달(M) 할 일 생성: "M월분 학습일지 작성 + 출석결과확인 등록 (고용24)", 마감 M+1월 3일
--     ② 지난달(M-1) 할 일이 없으면 생성, 대상 학생 전원에게 개인 알림 "M-1월 학습활동서 마무리 + 출석결과확인 등록"
--   매월 2일 09:00  run_monthly_diary('d2')
--     지난달 할 일에 앱 완료 체크가 없는 대상 학생에게만 "마감 내일(3일)" 알림
--   대상 = 명단(students) 진행중 + 그 달 마지막 날 기준 단계가 OFF-JT·OJT(또는 기수 미상). 시작 전·종료 제외.
--     (2월분은 3/1에 알리므로, 3월에 '종료'가 된 기수도 2월 말 기준 OJT 라 포함된다.)
--   문구는 단계별: OFF-JT "수업한 날마다 과목별 학습활동서", OJT "학습활동서".
--   같은 날 다시 돌려도 이미 보낸 알림은 건너뜀(created_by = auto:diary-YYYY-MM-d1|d2).
--
-- 기존 10월분 할 일(손으로 만든 것, 완료 체크 1건)은 지우지 않고 자동 할 일로 편입: 마감 11/3, 메모 정정.
-- 멱등: if not exists / create or replace / on conflict / cron 재등록.
-- 전제: sql/40(task_checks·_task_subject_hash), sql/59(student_phase), make_student_token, push-sender.
-- =====================================================================

alter table public.tasks add column if not exists auto_key text;
create unique index if not exists tasks_center_auto_key on public.tasks (center_id, auto_key) where auto_key is not null;

alter table public.centers add column if not exists auto_monthly_diary boolean not null default false;
update public.centers set auto_monthly_diary = true where slug = 'mju' and not auto_monthly_diary;

-- 할 일 메모 — 그 달 숫자로 자동
create or replace function public._diary_task_memo(p_month date)
returns text language sql immutable as $$
  select format('매월 1일부터 가능 — ① 고용24에서 %s월 학습활동서 작성 마무리(OFF-JT는 수업한 날마다 과목별로) '
             || '② [출석결과확인 등록] 버튼 클릭 (⚠️ 저장만 하지 말고 꼭 등록까지!) ③ 앱에서 완료 체크',
                extract(month from p_month)::int)
$$;

-- 기존 10월분 할 일 편입(제목으로 찾음, 한 번만)
update public.tasks t
   set auto_key = 'diary:2026-10', due_date = date '2026-11-03', memo = public._diary_task_memo(date '2026-10-01')
 where t.auto_key is null
   and t.title = '10월분 학습일지 작성 + 출석결과확인 등록 (고용24)'
   and t.center_id = (select id from public.centers where slug = 'mju')
   and not exists (select 1 from public.tasks x where x.center_id = t.center_id and x.auto_key = 'diary:2026-10');

-- 그 달 할 일을 보장하고 id 반환
create or replace function public.ensure_monthly_diary_task(p_center uuid, p_month date)
returns uuid
language plpgsql security definer set search_path = public as $$
declare
  m date := date_trunc('month', p_month)::date;
  k text := 'diary:' || to_char(m, 'YYYY-MM');
  v uuid;
begin
  insert into public.tasks (center_id, title, audience, due_date, kind, memo, published, auto_key)
  values (p_center,
          format('%s월분 학습일지 작성 + 출석결과확인 등록 (고용24)', extract(month from m)::int),
          '매칭학생', (m + interval '1 month')::date + 2, '마감', public._diary_task_memo(m), true, k)
  on conflict (center_id, auto_key) where auto_key is not null do nothing;
  select id into v from public.tasks where center_id = p_center and auto_key = k;
  return v;
end $$;

-- 1일·2일 실행 본체. p_today 는 시험용(기본 = 오늘, 서울).
create or replace function public.run_monthly_diary(p_step text, p_today date default (now() at time zone 'Asia/Seoul')::date)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_cur date := date_trunc('month', p_today)::date;
  v_prev date := (date_trunc('month', p_today) - interval '1 month')::date;
  v_last date := (date_trunc('month', p_today) - interval '1 day')::date;   -- 지난달 마지막 날(단계 판정 기준)
  v_due date := v_cur + 2;                                                  -- 이번 달 3일
  pm int := extract(month from v_prev)::int;
  v_by text;
  c record; r record;
  v_task uuid; v_notice uuid; ph text; h text;
  cnt int; total int := 0; n_centers int := 0; created int := 0;
  v_title text; v_common text; v_body text;
begin
  if p_step not in ('d1', 'd2') then raise exception 'bad_step'; end if;
  v_by := 'auto:diary-' || to_char(v_prev, 'YYYY-MM') || '-' || p_step;

  if p_step = 'd1' then
    v_title := format('%s월 학습활동서·출석 확인', pm);
    v_common := format('%s월 학습활동서를 마무리하고 고용24에서 [출석결과확인 등록]까지 눌러주세요. 마감 %s월 %s일.',
                       pm, extract(month from v_due)::int, extract(day from v_due)::int);
  else
    v_title := format('%s월 학습활동서 마감 내일', pm);
    v_common := format('%s월 학습활동서 작성 + [출석결과확인 등록] 마감이 내일(%s/%s)이에요.',
                       pm, extract(month from v_due)::int, extract(day from v_due)::int);
  end if;

  for c in select id from public.centers where active and auto_monthly_diary order by created_at loop
    if p_step = 'd1' then
      if not exists (select 1 from public.tasks where center_id = c.id and auto_key = 'diary:' || to_char(v_cur, 'YYYY-MM')) then
        created := created + 1;
      end if;
      perform public.ensure_monthly_diary_task(c.id, v_cur);
    end if;
    v_task := public.ensure_monthly_diary_task(c.id, v_prev);

    -- 같은 단계 알림을 이미 보냈으면 건너뜀(재실행 안전)
    if exists (select 1 from public.notices where center_id = c.id and created_by = v_by) then continue; end if;

    v_notice := null; cnt := 0;
    for r in
      with roster as (
        select s.name, s.phone, s.cohort, s.type1, s.phase_override,
               row_number() over (
                 partition by regexp_replace(coalesce(s.name, ''), '\s', '', 'g'),
                              regexp_replace(coalesce(s.phone, ''), '\D', '', 'g')
                 order by s.name) as rn
          from public.students s
         where s.center_id = c.id and coalesce(s.status, '진행중') = '진행중'
      )
      select name, phone, cohort, type1, phase_override from roster where rn = 1 order by name
    loop
      ph := public.student_phase(r.cohort, r.type1, r.phase_override, v_last);
      if ph is not null and ph not in ('offjt', 'ojt') then continue; end if;   -- 시작 전·종료 제외
      if p_step = 'd2' then
        h := public._task_subject_hash(public.make_student_token(r.name, r.phone));
        if exists (select 1 from public.task_checks tc
                    where tc.task_id = v_task and tc.subject_kind = 'student' and tc.subject_hash = h) then
          continue;                                                              -- 완료 체크한 학생 제외
        end if;
        v_body := format('아직 앱 완료 체크가 없어요. %s월 학습활동서 작성 + 고용24 [출석결과확인 등록] 마감이 내일(%s/%s)이에요. 이미 했다면 앱 홈에서 완료 체크만 눌러주세요.',
                         pm, extract(month from v_due)::int, extract(day from v_due)::int);
      elsif ph = 'offjt' then
        v_body := format('%s월 수업한 날마다 과목별 학습활동서를 마무리하고 고용24에서 [출석결과확인 등록]까지 눌러주세요. 마감 %s월 %s일 — 다 하면 앱 홈에서 완료 체크!',
                         pm, extract(month from v_due)::int, extract(day from v_due)::int);
      else
        v_body := format('%s월 학습활동서를 마무리하고 고용24에서 [출석결과확인 등록]까지 눌러주세요(저장만 하지 말고 꼭 등록까지). 마감 %s월 %s일 — 다 하면 앱 홈에서 완료 체크!',
                         pm, extract(month from v_due)::int, extract(day from v_due)::int);
      end if;

      if v_notice is null then
        insert into public.notices (center_id, title, body, target_scope, published, created_by, pushed)
        values (c.id, v_title, v_common, 'personal', true, v_by, false)
        returning id into v_notice;
      end if;
      insert into public.notice_recipients (notice_id, student_token, title, body, center_id)
      values (v_notice, public.make_student_token(r.name, r.phone), v_title, v_body, c.id);
      cnt := cnt + 1;
    end loop;

    total := total + cnt;
    if cnt > 0 then n_centers := n_centers + 1; end if;
  end loop;

  if total > 0 then
    begin
      perform net.http_get('https://ggitgqijycvnhhraxzgn.supabase.co/functions/v1/push-sender');
    exception when others then null;
    end;
  end if;

  return jsonb_build_object('ok', true, 'step', p_step, 'month', to_char(v_prev, 'YYYY-MM'),
                            'sent', total, 'centers', n_centers, 'tasks_created', created);
end $$;

revoke all on function public.run_monthly_diary(text, date) from public, anon, authenticated;
revoke all on function public.ensure_monthly_diary_task(uuid, date) from public, anon, authenticated;
grant execute on function public.run_monthly_diary(text, date) to service_role;
grant execute on function public.ensure_monthly_diary_task(uuid, date) to service_role;

-- 크론(UTC) — 매월 1일·2일 00:00 UTC = 09:00 서울
do $$
begin
  if exists (select 1 from cron.job where jobname = 'monthly-diary-d1') then perform cron.unschedule('monthly-diary-d1'); end if;
  if exists (select 1 from cron.job where jobname = 'monthly-diary-d2') then perform cron.unschedule('monthly-diary-d2'); end if;
  perform cron.schedule('monthly-diary-d1', '0 0 1 * *', $c$select public.run_monthly_diary('d1')$c$);
  perform cron.schedule('monthly-diary-d2', '0 0 2 * *', $c$select public.run_monthly_diary('d2')$c$);
end $$;
