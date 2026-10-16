-- =====================================================================
-- 61_attendance_track.sql — 출결 원본을 앱으로 + OFF-JT/OJT 따로 (docs/MULTI_TEACHER.md 3·3-1단계)
--
-- 사용자 결정(10/16): 노션은 뺀다 · 출석 진도와 학생 앱에서 OFF-JT·OJT 칸을 따로 · 2026 기수 OFF-JT 는
--   100% 이수로 간주 · 전체 훈련시간은 실시신고 시간표(= 월별 예정 시수)를 기준으로.
--
-- 바뀌는 것
--   1) attendance_monthly·attendance_daily 에 track('offjt'|'ojt', 기존 행 = 'ojt'). 유일 키에 track 포함.
--   2) attendance_monthly: source(excel|manual|notion|backfill)·auto_actual(엑셀 계산값)·edited_by·edited_at.
--      엑셀/일별 파일을 올리면 그 달 실적 = 날짜별 인정 합(auto_actual)으로 다시 계산.
--      손으로 고친 값(source='manual')은 다음 올리기에도 덮어쓰지 않는다 → set_attendance_month(..,'revert')로 되돌림.
--      예정 시수(시간표 월 배정)는 비어 있을 때만 '등록된 정규시간 합'으로 채운다.
--   3) bulk_upsert_attendance_daily: 행마다 track(없으면 ojt), 올린 track 만 교체, 끝나면 월 실적 재계산.
--      → 지금 쓰는 app_export.py JSON(OJT 만) 그대로 올려도 된다.
--   4) set_attendance_month: 관리자가 학생·월·track 의 예정·실적·메모를 직접 입력/되돌림(노션 '비고' 대체).
--   5) 노션 완전 제거(사용자 10/16 "노션은 아예 지우자"): 크론 notion-sync-daily 삭제(mju·mju-ksh 모두),
--      노션 경로 RPC bulk_upsert_attendance 삭제. 엣지 함수 sync-attendance·NOTION_TOKEN 은 대시보드/CLI 로 따로 삭제.
--   6) 2026 기수 OFF-JT 100% 채움(mju): 1유형 192h, 2유형 60h 를 2026-07 한 행으로(source='backfill').
--   7) my_attendance / my_attendance_days 반환에 track. 비콘 알림 본문 시수는 ojt 행만.
--
-- 멱등: if not exists / create or replace / on conflict / 인덱스 교체는 존재 확인 후.
-- =====================================================================

-- 1) 칸
alter table public.attendance_monthly add column if not exists track text not null default 'ojt';
alter table public.attendance_monthly add column if not exists source text;
alter table public.attendance_monthly add column if not exists auto_actual numeric;
alter table public.attendance_monthly add column if not exists edited_by text;
alter table public.attendance_monthly add column if not exists edited_at timestamptz;
alter table public.attendance_daily add column if not exists track text not null default 'ojt';
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'attendance_monthly_track_chk') then
    alter table public.attendance_monthly add constraint attendance_monthly_track_chk check (track in ('offjt', 'ojt'));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'attendance_daily_track_chk') then
    alter table public.attendance_daily add constraint attendance_daily_track_chk check (track in ('offjt', 'ojt'));
  end if;
end $$;
update public.attendance_monthly set source = 'notion' where source is null;

drop index if exists public.attendance_monthly_uniq;
create unique index if not exists attendance_monthly_uniq_t
  on public.attendance_monthly (center_id, replace(trim(name), ' ', ''), month, track);
drop index if exists public.attendance_daily_uniq;
create unique index if not exists attendance_daily_uniq_t
  on public.attendance_daily (center_id, replace(trim(name), ' ', ''), day, track);

-- 2) 월 실적 재계산 — 그 달·그 이름들·그 track 들
create or replace function public._attn_recompute(p_center uuid, p_month date, p_names text[], p_tracks text[])
returns int
language plpgsql security definer set search_path = public as $$
declare n int := 0;
begin
  insert into public.attendance_monthly as m (center_id, name, month, track, planned_hours, actual_hours, auto_actual, source, updated_at)
  select p_center, min(trim(d.name)), p_month, d.track,
         sum(d.planned_hours),
         coalesce(sum(d.recognized_hours) filter (where d.status in ('ok', 'short', 'none')), 0),
         coalesce(sum(d.recognized_hours) filter (where d.status in ('ok', 'short', 'none')), 0),
         'excel', now()
    from public.attendance_daily d
   where d.center_id = p_center and d.day >= p_month and d.day < (p_month + interval '1 month')::date
     and replace(trim(d.name), ' ', '') = any(p_names) and d.track = any(p_tracks)
   group by replace(trim(d.name), ' ', ''), d.track
  on conflict (center_id, (replace(trim(name), ' ', '')), month, track) do update
     set auto_actual   = excluded.auto_actual,
         actual_hours  = case when m.source = 'manual' then m.actual_hours else excluded.actual_hours end,
         planned_hours = coalesce(m.planned_hours, excluded.planned_hours),
         source        = case when m.source = 'manual' then 'manual' else 'excel' end,
         updated_at    = now();
  get diagnostics n = row_count;
  return n;
end $$;

-- 3) 일별 올리기 — track 지원 + 월 실적 재계산
create or replace function public.bulk_upsert_attendance_daily(p_month text, p_rows jsonb, p_center uuid default null::uuid)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare v_center uuid; v_from date; v_to date; r jsonb; v_day date; v_status text; v_track text;
        n_ins int := 0; n_skip int := 0; n_del int := 0; n_mon int := 0; v_names text[]; v_tracks text[];
begin
  if auth.role() = 'service_role' then
    if p_center is null then raise exception 'center_required'; end if;
    v_center := p_center;
  else
    if not exists (select 1 from admin_users au where au.user_id = auth.uid()) then
      raise exception 'not_admin';
    end if;
    if is_super_admin() then v_center := coalesce(p_center, current_admin_center());
    else v_center := current_admin_center();
    end if;
  end if;
  if v_center is null then raise exception 'no_center'; end if;
  if coalesce(p_month, '') !~ '^\d{4}-\d{2}$' then raise exception 'bad_month'; end if;
  v_from := to_date(p_month || '-01', 'YYYY-MM-DD');
  v_to := (v_from + interval '1 month')::date;

  select coalesce(array_agg(distinct replace(trim(x->>'name'), ' ', '')), '{}')
    into v_names
    from jsonb_array_elements(coalesce(p_rows, '[]'::jsonb)) x
   where trim(coalesce(x->>'name', '')) <> '';
  select coalesce(array_agg(distinct case when x->>'track' = 'offjt' then 'offjt' else 'ojt' end), '{}')
    into v_tracks
    from jsonb_array_elements(coalesce(p_rows, '[]'::jsonb)) x
   where trim(coalesce(x->>'name', '')) <> '';

  -- 올린 학생·올린 track 의 그 달 행만 통째로 교체(정규시간을 옮기면 옛 날짜가 지워지게)
  delete from attendance_daily a
   where a.center_id = v_center and a.day >= v_from and a.day < v_to
     and replace(trim(a.name), ' ', '') = any(v_names) and a.track = any(v_tracks);
  get diagnostics n_del = row_count;

  for r in select * from jsonb_array_elements(coalesce(p_rows, '[]'::jsonb)) loop
    if trim(coalesce(r->>'name', '')) = '' or coalesce(r->>'day', '') !~ '^\d{4}-\d{2}-\d{2}$' then
      n_skip := n_skip + 1; continue;
    end if;
    v_day := to_date(r->>'day', 'YYYY-MM-DD');
    if v_day < v_from or v_day >= v_to then n_skip := n_skip + 1; continue; end if;
    v_status := nullif(r->>'status', '');
    if v_status is not null and v_status not in ('ok', 'short', 'none', 'planned') then v_status := null; end if;
    v_track := case when r->>'track' = 'offjt' then 'offjt' else 'ojt' end;
    insert into attendance_daily (center_id, name, day, track, start_time, end_time, planned_hours, recognized_hours,
                                  in_time, out_time, method, status, course, fetched_at)
    values (v_center, trim(r->>'name'), v_day, v_track,
            nullif(r->>'start', '')::time, nullif(r->>'end', '')::time,
            coalesce(nullif(r->>'planned', '')::numeric, 0), nullif(r->>'recognized', '')::numeric,
            nullif(r->>'in', ''), nullif(r->>'out', ''), nullif(r->>'method', ''), v_status,
            nullif(r->>'course', ''), nullif(r->>'fetched_at', '')::timestamptz)
    on conflict (center_id, (replace(trim(name), ' ', '')), day, track) do nothing;
    if found then n_ins := n_ins + 1; else n_skip := n_skip + 1; end if;
  end loop;

  n_mon := public._attn_recompute(v_center, v_from, v_names, v_tracks);
  return jsonb_build_object('ok', true, 'students', coalesce(array_length(v_names, 1), 0),
                            'deleted', n_del, 'inserted', n_ins, 'skipped', n_skip, 'months', n_mon,
                            'tracks', to_jsonb(v_tracks));
end $function$;

-- 4) 관리자 직접 입력 / 되돌림
--   p_mode 'set'   : 넘긴 값만 바꿈. p_actual 을 넘기면 source='manual'(다음 엑셀 올리기에도 유지).
--   p_mode 'revert': 실적을 엑셀 계산값(auto_actual)으로 되돌리고 source='excel'.
create or replace function public.set_attendance_month(
  p_name text, p_month text, p_track text default 'ojt',
  p_planned numeric default null, p_actual numeric default null, p_note text default null,
  p_mode text default 'set')
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_center uuid; v_month date; v_track text; v_by text; v_id uuid; v_row public.attendance_monthly%rowtype;
begin
  if not exists (select 1 from admin_users au where au.user_id = auth.uid()) then raise exception 'not_admin'; end if;
  v_center := current_admin_center();
  if v_center is null then raise exception 'no_center'; end if;
  if trim(coalesce(p_name, '')) = '' then raise exception 'bad_name'; end if;
  if coalesce(p_month, '') !~ '^\d{4}-\d{2}$' then raise exception 'bad_month'; end if;
  if p_mode not in ('set', 'revert') then raise exception 'bad_mode'; end if;
  if (p_planned is not null and p_planned < 0) or (p_actual is not null and p_actual < 0) then raise exception 'bad_hours'; end if;
  v_month := to_date(p_month || '-01', 'YYYY-MM-DD');
  v_track := case when p_track = 'offjt' then 'offjt' else 'ojt' end;
  select email into v_by from auth.users where id = auth.uid();

  select id into v_id from attendance_monthly
   where center_id = v_center and month = v_month and track = v_track
     and replace(trim(name), ' ', '') = replace(trim(p_name), ' ', '');
  if v_id is null then
    if p_mode = 'revert' then return jsonb_build_object('ok', false, 'reason', 'not_found'); end if;
    insert into attendance_monthly (center_id, name, month, track, planned_hours, actual_hours, note, source, edited_by, edited_at, updated_at)
    values (v_center, trim(p_name), v_month, v_track, p_planned, p_actual, p_note,
            case when p_actual is not null then 'manual' end, v_by, now(), now())
    returning id into v_id;
  elsif p_mode = 'revert' then
    update attendance_monthly
       set actual_hours = auto_actual, source = case when auto_actual is not null then 'excel' else source end,
           edited_by = v_by, edited_at = now(), updated_at = now()
     where id = v_id;
  else
    update attendance_monthly
       set planned_hours = coalesce(p_planned, planned_hours),
           actual_hours  = coalesce(p_actual, actual_hours),
           note          = coalesce(p_note, note),
           source        = case when p_actual is not null then 'manual' else source end,
           edited_by = v_by, edited_at = now(), updated_at = now()
     where id = v_id;
  end if;
  select * into v_row from attendance_monthly where id = v_id;
  return jsonb_build_object('ok', true, 'planned', v_row.planned_hours, 'actual', v_row.actual_hours,
                            'auto_actual', v_row.auto_actual, 'source', v_row.source);
end $$;
revoke all on function public.set_attendance_month(text, text, text, numeric, numeric, text, text) from public, anon;
grant execute on function public.set_attendance_month(text, text, text, numeric, numeric, text, text) to authenticated;
revoke all on function public._attn_recompute(uuid, date, text[], text[]) from public, anon, authenticated;

-- 5) 노션 경로 제거 — sync-attendance 엣지 함수만 쓰던 RPC
drop function if exists public.bulk_upsert_attendance(jsonb, uuid);

-- 6) 2026 기수 OFF-JT 100% (mju) — 1유형 192h(전공 180 + 직업기초 12), 2유형 60h(45 + 15). 3유형은 해당 없음.
insert into public.attendance_monthly (center_id, name, month, track, planned_hours, actual_hours, auto_actual, units, note, source, updated_at)
select s.center_id, trim(s.name), date '2026-07-01', 'offjt',
       case when coalesce(s.type1, '') like '2%' then 60 else 192 end,
       case when coalesce(s.type1, '') like '2%' then 60 else 192 end,
       null, 'OFF-JT 합계', '2026 OFF-JT 이수 완료로 간주(사용자 결정 2026-10-16)', 'backfill', now()
  from public.students s
  join public.centers c on c.id = s.center_id and c.slug = 'mju'
 where coalesce(s.cohort, '') like '2026%' and coalesce(s.type1, '') not like '3%'
on conflict (center_id, (replace(trim(name), ' ', '')), month, track) do nothing;

-- 7) 학생 조회 RPC — track·source 추가(그 외 sql/44·47 그대로)
create or replace function public.my_attendance(p_code text default null::text, p_token text default null::text)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare ip text; rows jsonb; v_name text; v_center uuid;
begin
  ip := coalesce(current_setting('request.headers', true)::jsonb ->> 'x-forwarded-for', 'unknown');
  begin
    perform check_verify_rate('attn:' || ip);
  exception when undefined_function then null;
  end;
  if coalesce(p_code, '') <> '' then
    select sc.name, sc.center_id into v_name, v_center from student_codes sc
     where sc.code = upper(regexp_replace(p_code, '[^A-Za-z0-9]', '', 'g')) and sc.active;
  end if;
  if v_name is null and char_length(coalesce(p_token, '')) >= 20 then
    select s.name, s.center_id into v_name, v_center from students s
     where make_student_token(s.name, s.phone) = p_token
     limit 1;
  end if;
  if v_name is null then
    return jsonb_build_object('ok', false);
  end if;
  select coalesce(jsonb_agg(jsonb_build_object(
           'month', to_char(a.month, 'YYYY-MM'),
           'track', a.track,
           'planned', a.planned_hours,
           'actual', a.actual_hours,
           'units', a.units,
           'source', a.source,
           'updated_at', a.updated_at) order by a.month, a.track), '[]'::jsonb)
    into rows
    from attendance_monthly a
   where a.center_id = v_center
     and replace(trim(a.name), ' ', '') = replace(trim(v_name), ' ', '');
  return jsonb_build_object('ok', true, 'rows', rows);
end $function$;

create or replace function public.my_attendance_days(p_code text default null::text, p_token text default null::text)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare ip text; v_name text; v_center uuid; v_from date; v_to date; v_days jsonb; v_fetched timestamptz;
begin
  ip := coalesce(current_setting('request.headers', true)::jsonb ->> 'x-forwarded-for', 'unknown');
  begin
    perform check_verify_rate('attnd:' || ip);
  exception when undefined_function then null;
  end;
  if coalesce(p_code, '') <> '' then
    select sc.name, sc.center_id into v_name, v_center from student_codes sc
     where sc.code = upper(regexp_replace(p_code, '[^A-Za-z0-9]', '', 'g')) and sc.active;
  end if;
  if v_name is null and char_length(coalesce(p_token, '')) >= 20 then
    select s.name, s.center_id into v_name, v_center from students s
     where s.phone is not null and make_student_token(s.name, s.phone) = p_token
     limit 1;
  end if;
  if v_name is null then
    return jsonb_build_object('ok', false);
  end if;

  v_from := date_trunc('month', (now() at time zone 'Asia/Seoul'))::date;
  v_to := (v_from + interval '1 month')::date;
  select coalesce(jsonb_agg(jsonb_build_object(
           'day', to_char(a.day, 'YYYY-MM-DD'),
           'track', a.track,
           'start', to_char(a.start_time, 'HH24:MI'),
           'end', to_char(a.end_time, 'HH24:MI'),
           'planned', a.planned_hours,
           'recognized', a.recognized_hours,
           'in', a.in_time, 'out', a.out_time,
           'status', a.status) order by a.day, a.track), '[]'::jsonb),
         max(a.fetched_at)
    into v_days, v_fetched
    from attendance_daily a
   where a.center_id = v_center
     and replace(trim(a.name), ' ', '') = replace(trim(v_name), ' ', '')
     and a.day >= v_from and a.day < v_to;
  return jsonb_build_object('ok', true, 'month', to_char(v_from, 'YYYY-MM'),
                            'fetched_at', v_fetched, 'days', v_days);
end $function$;

-- 비콘 알림 — 본문 시수는 OJT 행만(sql/59 판정 그대로)
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
end $function$;
revoke all on function public.send_beacon_reminders(text) from public, anon, authenticated;
grant execute on function public.send_beacon_reminders(text) to service_role;

-- 노션 자동 동기화 크론 삭제(모든 센터)
do $$
begin
  if exists (select 1 from cron.job where jobname = 'notion-sync-daily') then perform cron.unschedule('notion-sync-daily'); end if;
end $$;
