-- =====================================================================
-- 55_attendance_daily.sql — 날짜별 정규시간·인정시간 (관리자 개편 3단계, docs/ADMIN_REDESIGN.md)
-- 멱등(create or replace / if not exists). 적용 순서: 19·21·42·44 이후(centers·헬퍼·make_student_token 필요).
--
--  · attendance_daily = 학생별 '그 날' 정규시간(시작·종료·시간)과 인정 출석시간·상태.
--    원천은 출결점검(행정지원시스템 조회) 결과 — 관리자가 '출결 결과 올리기'(4단계)로 올린다.
--  · PII·개인 출결: anon 정책 없음(직접 조회 전면 차단) → rls-check MUST_BE_BLOCKED 등록 필수.
--  · 쓰기는 bulk_upsert_attendance_daily(관리자 / service_role+센터 명시)만. 클라 center_id 미신뢰.
--    올린 학생의 '그 달' 행을 통째로 교체 — 정규시간을 다른 날로 옮기면 옛 날짜가 남지 않게.
--  · 학생 조회는 my_attendance_days(코드 또는 서명토큰) SECURITY DEFINER 만, 자기 행 + 이번 달(KST)만.
--  · 프론트 폴백: RPC/테이블 미적용이면 달력·카드가 지금과 똑같이 보임(회귀 0).
-- =====================================================================

create table if not exists public.attendance_daily (
  id               uuid primary key default gen_random_uuid(),
  center_id        uuid not null references public.centers(id),
  name             text not null,
  day              date not null,
  start_time       time,                 -- 정규시간 시작(예 09:00). 정규시간 없는 날은 행을 만들지 않는다
  end_time         time,                 -- 정규시간 종료(예 16:00)
  planned_hours    numeric not null default 0,
  recognized_hours numeric,              -- 인정 출석시간. null = 아직 조회 범위 밖(예정)
  in_time          text,                 -- 입실 기록(HH:MM) — '퇴실 누락' 같은 사유 표시용
  out_time         text,                 -- 퇴실 기록(HH:MM)
  method           text,                 -- 비콘 / 직권 등(시스템 표기 그대로)
  status           text check (status in ('ok', 'short', 'none', 'planned')),
                                         -- ok=인정≥정규, short=0<인정<정규, none=인정 0, planned=아직 전
  course           text,                 -- 출결점검 과정 라벨(같은 과정 = 같은 정규시간)
  fetched_at       timestamptz,          -- 행정지원시스템 조회 시각(화면에 '조회 10/15 08:45')
  updated_at       timestamptz not null default now()
);

-- 센터 + 정규화 이름 + 날짜 유일 (attendance_monthly 와 같은 이름 키 — 동명이인은 파일럿 범위 밖)
create unique index if not exists attendance_daily_uniq
  on public.attendance_daily (center_id, (replace(trim(name), ' ', '')), day);
create index if not exists attendance_daily_center_day on public.attendance_daily (center_id, day);

alter table public.attendance_daily enable row level security;

-- 관리자만 직접 접근(센터 스코프). to public + 헬퍼 패턴(publishable 키에서 to authenticated 미동작 전례).
drop policy if exists "attendance daily admin all" on public.attendance_daily;
create policy "attendance daily admin all" on public.attendance_daily
  for all to public
  using (is_super_admin() or center_id = current_admin_center())
  with check (is_super_admin() or center_id = current_admin_center());

revoke all on public.attendance_daily from anon;
grant select, insert, update, delete on public.attendance_daily to authenticated;

-- ── 관리자 일괄 교체 RPC ──
-- p_month: 'YYYY-MM'. p_rows: [{name, day:'YYYY-MM-DD', start:'09:00', end:'16:00', planned, recognized,
--          in, out, method, status, course, fetched_at}]
-- 올라온 학생마다 그 달 행을 지우고 새로 넣는다(올라오지 않은 학생의 행은 건드리지 않음).
create or replace function public.bulk_upsert_attendance_daily(p_month text, p_rows jsonb, p_center uuid default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_center uuid; v_from date; v_to date; r jsonb; v_day date; v_status text;
        n_ins int := 0; n_skip int := 0; n_del int := 0; v_names text[];
begin
  if auth.role() = 'service_role' then
    if p_center is null then raise exception 'center_required'; end if;
    v_center := p_center;
  else
    if not exists (select 1 from admin_users au where au.user_id = auth.uid()) then
      raise exception 'not_admin';
    end if;
    if is_super_admin() then v_center := coalesce(p_center, current_admin_center());
    else v_center := current_admin_center();   -- center_admin 은 클라값 무시(강제)
    end if;
  end if;
  if v_center is null then raise exception 'no_center'; end if;
  if coalesce(p_month, '') !~ '^\d{4}-\d{2}$' then raise exception 'bad_month'; end if;
  v_from := to_date(p_month || '-01', 'YYYY-MM-DD');
  v_to := (v_from + interval '1 month')::date;

  -- 교체 대상 학생(정규화 이름) — 이름 빈 행은 제외
  select coalesce(array_agg(distinct replace(trim(x->>'name'), ' ', '')), '{}')
    into v_names
    from jsonb_array_elements(coalesce(p_rows, '[]'::jsonb)) x
   where trim(coalesce(x->>'name', '')) <> '';

  delete from attendance_daily a
   where a.center_id = v_center and a.day >= v_from and a.day < v_to
     and replace(trim(a.name), ' ', '') = any(v_names);
  get diagnostics n_del = row_count;

  for r in select * from jsonb_array_elements(coalesce(p_rows, '[]'::jsonb)) loop
    if trim(coalesce(r->>'name', '')) = '' or coalesce(r->>'day', '') !~ '^\d{4}-\d{2}-\d{2}$' then
      n_skip := n_skip + 1; continue;
    end if;
    v_day := to_date(r->>'day', 'YYYY-MM-DD');
    if v_day < v_from or v_day >= v_to then n_skip := n_skip + 1; continue; end if;   -- 다른 달 날짜는 받지 않음
    v_status := nullif(r->>'status', '');
    if v_status is not null and v_status not in ('ok', 'short', 'none', 'planned') then v_status := null; end if;
    insert into attendance_daily (center_id, name, day, start_time, end_time, planned_hours, recognized_hours,
                                  in_time, out_time, method, status, course, fetched_at)
    values (v_center, trim(r->>'name'), v_day,
            nullif(r->>'start', '')::time, nullif(r->>'end', '')::time,
            coalesce(nullif(r->>'planned', '')::numeric, 0), nullif(r->>'recognized', '')::numeric,
            nullif(r->>'in', ''), nullif(r->>'out', ''), nullif(r->>'method', ''), v_status,
            nullif(r->>'course', ''), nullif(r->>'fetched_at', '')::timestamptz)
    on conflict (center_id, (replace(trim(name), ' ', '')), day) do nothing;   -- 같은 파일 안 중복 행은 첫 행만
    if found then n_ins := n_ins + 1; else n_skip := n_skip + 1; end if;
  end loop;
  return jsonb_build_object('ok', true, 'students', coalesce(array_length(v_names, 1), 0),
                            'deleted', n_del, 'inserted', n_ins, 'skipped', n_skip);
end $$;
revoke all on function public.bulk_upsert_attendance_daily(text, jsonb, uuid) from public, anon;
grant execute on function public.bulk_upsert_attendance_daily(text, jsonb, uuid) to authenticated, service_role;

-- ── 학생 조회 RPC — 초대코드 또는 서명토큰으로 본인 확인(my_attendance 와 같은 경로), 자기 행 + 이번 달만 ──
create or replace function public.my_attendance_days(p_code text default null, p_token text default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
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

  v_from := date_trunc('month', (now() at time zone 'Asia/Seoul'))::date;   -- '그 달만' = 이번 달(KST)
  v_to := (v_from + interval '1 month')::date;
  select coalesce(jsonb_agg(jsonb_build_object(
           'day', to_char(a.day, 'YYYY-MM-DD'),
           'start', to_char(a.start_time, 'HH24:MI'),
           'end', to_char(a.end_time, 'HH24:MI'),
           'planned', a.planned_hours,
           'recognized', a.recognized_hours,
           'in', a.in_time, 'out', a.out_time,
           'status', a.status) order by a.day), '[]'::jsonb),
         max(a.fetched_at)
    into v_days, v_fetched
    from attendance_daily a
   where a.center_id = v_center
     and replace(trim(a.name), ' ', '') = replace(trim(v_name), ' ', '')
     and a.day >= v_from and a.day < v_to;
  return jsonb_build_object('ok', true, 'month', to_char(v_from, 'YYYY-MM'),
                            'fetched_at', v_fetched, 'days', v_days);
end $$;
grant execute on function public.my_attendance_days(text, text) to anon, authenticated;

-- 검증 쿼리 (적용 후):
--   set local role anon; select count(*) from attendance_daily;            -- → permission denied 여야 정상
--   select my_attendance_days('WRONGCODE');                               -- → ok:false
--   select my_attendance_days('실제코드');                                 -- → ok:true, days: [] (업로드 전)
