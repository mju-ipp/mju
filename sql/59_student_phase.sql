-- =====================================================================
-- 59_student_phase.sql — 학생 단계(OFF-JT/OJT) 구분 + 비콘 알림은 OJT 학생만 (docs/OFFJT.md 1단계)
--
-- 왜 만들었나
--   비콘 입·퇴실 알림(send_beacon_reminders, 평일 09:00·16:00)은 '이번 달 실적 < 배정'인
--   학생 전부에게 갔다. OFF-JT(3~7월, 교수 수기출석부)에는 비콘이 없는데, 출결을 앱에 넣기
--   시작하면 3월부터 OFF-JT 학생에게 "입실 비콘 찍어주세요"가 매일 나간다.
--
-- 단계 판정 (운영위키 「운영 유형 (1·2·3유형)」, 기수 Y)
--   1유형(기본) : OFF-JT Y.3~7월, OJT Y.8월~Y+1.2월
--   2유형       : OFF-JT Y.6~7월, OJT Y.8월~Y+1.2월 (3~5월은 '시작 전')
--   3유형       : OJT Y.3월~Y+1.2월 (OFF-JT는 OJT와 병행이라 OJT로 본다)
--   Y+1.3월부터 '종료'. 기수를 못 읽으면 null(→ 알림은 지금처럼 보냄).
--   학생별로 phase_override('offjt'|'ojt')를 두면 그 값이 우선.
--
-- 멱등: add column if not exists / create or replace. 기존 동작 변화는 비콘 알림 대상 조건 1줄뿐
--   (2026-10 현재 학생 23명 모두 2026 기수 1·2유형 → 'ojt' → 대상 그대로).
-- =====================================================================

alter table public.students add column if not exists phase_override text;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'students_phase_override_chk') then
    alter table public.students add constraint students_phase_override_chk
      check (phase_override is null or phase_override in ('offjt', 'ojt'));
  end if;
end $$;

-- 단계 판정 — 'offjt' | 'ojt' | 'before' | 'done' | null(기수 미상)
create or replace function public.student_phase(
  p_cohort text, p_type1 text, p_override text,
  p_day date default (now() at time zone 'Asia/Seoul')::date
) returns text
language plpgsql stable
set search_path = public
as $$
declare
  y int; t text := coalesce(p_type1, '');
  start_off date; start_ojt date;
begin
  if p_override in ('offjt', 'ojt') then return p_override; end if;
  y := (substring(coalesce(p_cohort, '') from '(\d{4})'))::int;
  if y is null then return null; end if;

  if t like '3%' then
    start_off := null;               start_ojt := make_date(y, 3, 1);
  elsif t like '2%' then
    start_off := make_date(y, 6, 1); start_ojt := make_date(y, 8, 1);
  else
    start_off := make_date(y, 3, 1); start_ojt := make_date(y, 8, 1);
  end if;

  if p_day >= make_date(y + 1, 3, 1) then return 'done'; end if;
  if p_day >= start_ojt then return 'ojt'; end if;
  if start_off is not null and p_day >= start_off then return 'offjt'; end if;
  return 'before';
end $$;

-- 관리자 화면용 계산 칸 — PostgREST 에서 students?select=...,phase 로 읽는다(RLS 는 students 그대로)
create or replace function public.phase(s public.students)
returns text language sql stable
set search_path = public
as $$ select public.student_phase(s.cohort, s.type1, s.phase_override) $$;

grant execute on function public.student_phase(text, text, text, date) to authenticated, service_role;
grant execute on function public.phase(public.students) to authenticated, service_role;

-- 관리자 행 편집 RPC — 화이트리스트에 phase_override 추가('' 는 null = 자동으로 되돌림)
create or replace function public.update_student_lifecycle(p_name text, p_phone text, p_patch jsonb)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  v_center uuid; v_phone text; t text; setlist text; n int := 0; tot int := 0;
  tbls text[] := array['students', 'registrations'];
begin
  if not (is_super_admin() or current_admin_center() is not null) then raise exception 'not_admin'; end if;
  v_center := current_admin_center();                  -- 편집은 항상 자기 센터(super 도 홈센터)로 한정
  if v_center is null then raise exception 'no_center'; end if;
  v_phone := nullif(regexp_replace(coalesce(p_phone, ''), '[^0-9]', '', 'g'), '');

  foreach t in array tbls loop
    if to_regclass('public.' || t) is null then continue; end if;
    -- 패치 키 ∩ 화이트리스트 ∩ 실제 컬럼만 동적 set. 값은 %L 로 안전 인용.
    -- phase_override 는 '' → null(자동 판정으로 되돌림, check 제약 위반 방지)
    select string_agg(format('%I = %L', k,
             case when k = 'phase_override' then nullif(p_patch->>k, '') else p_patch->>k end), ', ')
      into setlist
      from jsonb_object_keys(p_patch) k
      where k in ('cohort', 'status', 'manager', 'type1', 'phase_override')
        and exists (select 1 from information_schema.columns c
                    where c.table_schema='public' and c.table_name=t and c.column_name=k);
    if setlist is null then continue; end if;
    -- 이름 일치 + (전화 미지정이면 통과, 지정이면 숫자정규화 후 일치) + 센터 스코프.
    execute format(
      'update public.%I set %s
         where center_id = $1 and name = $2
           and ($3 is null or regexp_replace(coalesce(phone, ''''), ''[^0-9]'', '''', ''g'') = $3)',
      t, setlist) using v_center, p_name, v_phone;
    get diagnostics n = row_count; tot := tot + n;
  end loop;
  return jsonb_build_object('ok', true, 'rows', tot);
end $function$;

-- 비콘 알림 — OJT 학생만(기수 미상은 지금처럼 보냄). 나머지는 운영 정의(10/16) 그대로.
create or replace function public.send_beacon_reminders(p_kind text default 'in'::text)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
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
    -- 어제(직전 실행) 자동 공지 교체 — 센터 단위
    delete from notice_recipients where notice_id in
      (select id from notices where created_by like 'auto:beacon%' and center_id = c.id);
    delete from notices where created_by like 'auto:beacon%' and center_id = c.id;

    v_notice := null; cnt := 0;
    for r in
      select a.name, s.phone, a.planned_hours, coalesce(a.actual_hours, 0) as actual_hours
        from attendance_monthly a
        join students s on s.center_id = a.center_id
         and replace(trim(s.name), ' ', '') = replace(trim(a.name), ' ', '')
       where a.center_id = c.id and a.month = v_month
         and a.planned_hours > 0
         and coalesce(a.actual_hours, 0) < a.planned_hours
         and coalesce(student_phase(s.cohort, s.type1, s.phase_override, v_today), 'ojt') = 'ojt'   -- sql/59
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

  -- 즉시 킥 — 새 발송기(push-sender). 실패해도 5분 폴링이 폴백
  begin
    perform net.http_get('https://ggitgqijycvnhhraxzgn.supabase.co/functions/v1/push-sender');
  exception when others then null;
  end;

  return jsonb_build_object('ok', true, 'kind', p_kind, 'sent', total,
                            'centers', n_centers, 'month', to_char(v_month, 'YYYY-MM'));
end $function$;

revoke all on function public.send_beacon_reminders(text) from public, anon, authenticated;
grant execute on function public.send_beacon_reminders(text) to service_role;
