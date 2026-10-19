-- =====================================================================
-- 68_ipp_companies.sql — 관리자 '현황' 메뉴: 연도별 학습기업 참여 현황 (IPP 공고 + 우리 쪽 기록)
-- 멱등(create or replace / if not exists / on conflict). 적용 순서: 19·21·37(_norm_co) 이후.
--
-- 사용자 결정(10/19): 2027 학습기업 현황을 관리자 앱에서 본다. 범위 = 센터 전체 + 내 기업 표시.
--   IPP(ipp.mju.ac.kr)는 로그인 뒤라 앱이 직접 못 읽음 → IPP 에서 북마클릿으로 복사 → 앱에 붙여넣기.
--   진행 단계(①~⑨)는 앱에서 기록하고 노션 체크표는 서류·메모용으로 남김.
--
--  · ipp_postings = IPP '일학습 기업정보'·'매칭 및 선발관리' 공고 한 건 = 한 행(work_seq 기준).
--    숫자·날짜만 저장 — 학생 이름·기업 담당자 연락처는 받지도 저장하지도 않는다.
--  · ipp_company_track = 기업(연도·정규화 이름)별 우리 쪽 기록: 담당직원·단계·매칭·합격인원·메모.
--    IPP 에 아직 공고가 없는 기업(발굴 단계)도 여기만 있으면 목록에 보인다.
--  · 쓰기: upload_ipp_postings(그 연도 공고 통째 교체) / set_ipp_company(넘긴 키만 바꿈).
--    관리자 / service_role+센터 명시만. 클라 center_id 미신뢰(center_admin 은 자기 센터 강제).
--  · anon 정책 없음 → rls-check MUST_BE_BLOCKED 등록.
-- =====================================================================

create table if not exists public.ipp_postings (
  id            uuid primary key default gen_random_uuid(),
  center_id     uuid not null references public.centers(id),
  year          int  not null,                -- IPP WORK_YEAR(참여 연도)
  work_seq      int  not null,                -- IPP 공고 번호
  comp_seq      int,                          -- IPP 기업 번호
  comp_nm       text not null,
  comp_key      text not null,                -- _norm_co(comp_nm) — ipp_company_track 과 잇는 키
  program_nm    text,                         -- 훈련과정
  work_type     text,                         -- 산업형·자율형
  mozip         text,                         -- 모집전·모집중·모집마감
  disposal      text,                         -- 승인대기·승인·반려
  recruit_st    date,
  recruit_end   date,
  recruit_num   int,                          -- 모집 인원
  app_cnt       int,                          -- 지원자 수(매칭 및 선발관리)
  offjt_st      date, offjt_end date,
  ojt_st        date, ojt_end   date,
  reg_date      date,                         -- IPP 등록일
  prof_nm       text,                         -- 담당교수(IPP 기업정보 관리)
  fetched_at    timestamptz,                  -- IPP 에서 읽은 시각
  uploaded_by   text,
  uploaded_at   timestamptz not null default now()
);
create unique index if not exists ipp_postings_uniq on public.ipp_postings (center_id, work_seq);
create index if not exists ipp_postings_year on public.ipp_postings (center_id, year, comp_key);

create table if not exists public.ipp_company_track (
  id          uuid primary key default gen_random_uuid(),
  center_id   uuid not null references public.centers(id),
  year        int  not null,
  comp_key    text not null,                  -- _norm_co(기업명)
  comp_nm     text not null,                  -- 표시용(처음 넣은 이름)
  manager     text,                           -- 우리 쪽 담당직원(권순천·노혜정·길은경·차민정 …)
  stage       text,                           -- '① 참여신청 안내' … '⑨ 실시신고·OJT 안내' · '보류'
  matching    text,                           -- 직무기술서 게시·이력서 송부·면접·합격·미선발
  passed      int,                            -- 합격 인원
  memo        text,
  updated_by  text,
  updated_at  timestamptz not null default now()
);
create unique index if not exists ipp_company_track_uniq on public.ipp_company_track (center_id, year, comp_key);

alter table public.ipp_postings enable row level security;
alter table public.ipp_company_track enable row level security;

-- 관리자만 직접 읽기(센터 스코프). 쓰기는 아래 RPC 로만 — 직접 insert/update 정책을 두지 않는다.
drop policy if exists "ipp postings admin read" on public.ipp_postings;
create policy "ipp postings admin read" on public.ipp_postings
  for select to public
  using (is_super_admin() or center_id = current_admin_center());
drop policy if exists "ipp track admin read" on public.ipp_company_track;
create policy "ipp track admin read" on public.ipp_company_track
  for select to public
  using (is_super_admin() or center_id = current_admin_center());

revoke all on public.ipp_postings from anon;
revoke all on public.ipp_company_track from anon;
grant select on public.ipp_postings to authenticated;
grant select on public.ipp_company_track to authenticated;

-- 관리자 센터 해석(55·61·62 와 같은 규칙)
create or replace function public._ipp_center(p_center uuid)
returns uuid
language plpgsql stable security definer set search_path = public as $$
declare v uuid;
begin
  if auth.role() = 'service_role' then
    if p_center is null then raise exception 'center_required'; end if;
    return p_center;
  end if;
  if not exists (select 1 from admin_users au where au.user_id = auth.uid()) then
    raise exception 'not_admin';
  end if;
  if is_super_admin() then v := coalesce(p_center, current_admin_center());
  else v := current_admin_center();          -- center_admin 은 클라값 무시(강제)
  end if;
  if v is null then raise exception 'no_center'; end if;
  return v;
end $$;
revoke all on function public._ipp_center(uuid) from public, anon;

-- 'YYYY.MM.DD' · 'YYYY-MM-DD' → date, 그 밖(빈칸·'~')은 null
create or replace function public._ipp_date(s text)
returns date
language sql immutable as $$
  select case when coalesce(s, '') ~ '^\s*\d{4}[.-]\d{2}[.-]\d{2}'
              then to_date(substring(s from '\d{4}[.-]\d{2}[.-]\d{2}'), 'YYYY-MM-DD') end
$$;
revoke all on function public._ipp_date(text) from public, anon;

-- ── IPP 공고 올리기 ──
-- p_rows: [{work_seq, comp_seq, comp_nm, program_nm, work_type, mozip, disposal, recruit_st, recruit_end,
--           recruit_num, app_cnt, offjt_st, offjt_end, ojt_st, ojt_end, reg_date, prof_nm}]
-- 그 연도 공고를 통째로 교체: 올린 목록에 없는 work_seq 는 지운다(IPP 에서 내려간 공고).
create or replace function public.upload_ipp_postings(
  p_year int, p_rows jsonb, p_fetched_at timestamptz default null, p_center uuid default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_center uuid; r jsonb; v_by text; n_ins int := 0; n_del int := 0; n_skip int := 0;
        v_seqs int[];
begin
  v_center := _ipp_center(p_center);
  if p_year is null or p_year < 2000 or p_year > 2100 then raise exception 'bad_year'; end if;
  if jsonb_typeof(coalesce(p_rows, 'null'::jsonb)) <> 'array' then raise exception 'bad_rows'; end if;
  select email into v_by from auth.users where id = auth.uid();

  select coalesce(array_agg((x->>'work_seq')::int), '{}') into v_seqs
    from jsonb_array_elements(p_rows) x
   where coalesce(x->>'work_seq', '') ~ '^\d+$' and trim(coalesce(x->>'comp_nm', '')) <> '';
  -- 빈 목록으로 그 해 공고를 다 지우는 사고 방지
  if coalesce(array_length(v_seqs, 1), 0) = 0 then raise exception 'empty_rows'; end if;

  delete from ipp_postings p
   where p.center_id = v_center and p.year = p_year and not (p.work_seq = any(v_seqs));
  get diagnostics n_del = row_count;

  for r in select * from jsonb_array_elements(p_rows) loop
    if coalesce(r->>'work_seq', '') !~ '^\d+$' or trim(coalesce(r->>'comp_nm', '')) = '' then
      n_skip := n_skip + 1; continue;
    end if;
    insert into ipp_postings as p (center_id, year, work_seq, comp_seq, comp_nm, comp_key, program_nm, work_type,
        mozip, disposal, recruit_st, recruit_end, recruit_num, app_cnt, offjt_st, offjt_end, ojt_st, ojt_end,
        reg_date, prof_nm, fetched_at, uploaded_by, uploaded_at)
    values (v_center, p_year, (r->>'work_seq')::int, nullif(r->>'comp_seq', '')::int, trim(r->>'comp_nm'),
        _norm_co(r->>'comp_nm'), nullif(trim(coalesce(r->>'program_nm', '')), ''), nullif(r->>'work_type', ''),
        nullif(r->>'mozip', ''), nullif(r->>'disposal', ''), _ipp_date(r->>'recruit_st'), _ipp_date(r->>'recruit_end'),
        case when coalesce(r->>'recruit_num', '') ~ '^\d+$' then (r->>'recruit_num')::int end,
        case when coalesce(r->>'app_cnt', '') ~ '^\d+$' then (r->>'app_cnt')::int end,
        _ipp_date(r->>'offjt_st'), _ipp_date(r->>'offjt_end'), _ipp_date(r->>'ojt_st'), _ipp_date(r->>'ojt_end'),
        _ipp_date(r->>'reg_date'), nullif(trim(coalesce(r->>'prof_nm', '')), ''), coalesce(p_fetched_at, now()), v_by, now())
    on conflict (center_id, work_seq) do update
       set year = excluded.year, comp_seq = excluded.comp_seq, comp_nm = excluded.comp_nm, comp_key = excluded.comp_key,
           program_nm = excluded.program_nm, work_type = excluded.work_type, mozip = excluded.mozip,
           disposal = excluded.disposal, recruit_st = excluded.recruit_st, recruit_end = excluded.recruit_end,
           recruit_num = excluded.recruit_num, app_cnt = excluded.app_cnt, offjt_st = excluded.offjt_st,
           offjt_end = excluded.offjt_end, ojt_st = excluded.ojt_st, ojt_end = excluded.ojt_end,
           reg_date = excluded.reg_date, prof_nm = coalesce(excluded.prof_nm, p.prof_nm),
           fetched_at = excluded.fetched_at, uploaded_by = excluded.uploaded_by, uploaded_at = now();
    n_ins := n_ins + 1;
  end loop;
  return jsonb_build_object('ok', true, 'saved', n_ins, 'deleted', n_del, 'skipped', n_skip);
end $$;
revoke all on function public.upload_ipp_postings(int, jsonb, timestamptz, uuid) from public, anon;
grant execute on function public.upload_ipp_postings(int, jsonb, timestamptz, uuid) to authenticated, service_role;

-- ── 기업별 우리 쪽 기록 저장 ──
-- p_fields: {manager?, stage?, matching?, passed?, memo?} — 넘긴 키만 바꾼다(빈 문자열 = 지움).
-- p_delete = true 면 그 기업 기록 행을 지운다(IPP 공고는 그대로).
create or replace function public.set_ipp_company(
  p_year int, p_company text, p_fields jsonb default '{}'::jsonb, p_delete boolean default false,
  p_center uuid default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_center uuid; v_key text; v_by text; f jsonb := coalesce(p_fields, '{}'::jsonb); t record;
begin
  v_center := _ipp_center(p_center);
  if p_year is null or p_year < 2000 or p_year > 2100 then raise exception 'bad_year'; end if;
  v_key := _norm_co(p_company);
  if v_key = '' then raise exception 'company_required'; end if;
  if jsonb_typeof(f) <> 'object' then raise exception 'bad_fields'; end if;
  if f ? 'passed' and coalesce(f->>'passed', '') <> '' and (f->>'passed') !~ '^\d+$' then raise exception 'bad_passed'; end if;
  if f ? 'stage' and coalesce(f->>'stage', '') <> '' and (f->>'stage') !~ '^([①②③④⑤⑥⑦⑧⑨] .+|보류)$' then
    raise exception 'bad_stage';
  end if;
  select email into v_by from auth.users where id = auth.uid();

  if p_delete then
    delete from ipp_company_track where center_id = v_center and year = p_year and comp_key = v_key;
    return jsonb_build_object('ok', true, 'deleted', true);
  end if;

  insert into ipp_company_track as c (center_id, year, comp_key, comp_nm, updated_by, updated_at)
  values (v_center, p_year, v_key, trim(p_company), v_by, now())
  on conflict (center_id, year, comp_key) do nothing;

  update ipp_company_track c set
    manager  = case when f ? 'manager'  then nullif(trim(f->>'manager'), '')  else c.manager end,
    stage    = case when f ? 'stage'    then nullif(trim(f->>'stage'), '')    else c.stage end,
    matching = case when f ? 'matching' then nullif(trim(f->>'matching'), '') else c.matching end,
    passed   = case when f ? 'passed'   then nullif(f->>'passed', '')::int    else c.passed end,
    memo     = case when f ? 'memo'     then nullif(trim(f->>'memo'), '')     else c.memo end,
    updated_by = v_by, updated_at = now()
  where c.center_id = v_center and c.year = p_year and c.comp_key = v_key
  returning c.* into t;

  return jsonb_build_object('ok', true, 'company', t.comp_nm, 'manager', t.manager, 'stage', t.stage,
                            'matching', t.matching, 'passed', t.passed, 'memo', t.memo);
end $$;
revoke all on function public.set_ipp_company(int, text, jsonb, boolean, uuid) from public, anon;
grant execute on function public.set_ipp_company(int, text, jsonb, boolean, uuid) to authenticated, service_role;
