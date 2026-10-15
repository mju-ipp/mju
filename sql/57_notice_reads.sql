-- =====================================================================
-- 57_notice_reads.sql — 공지 읽음 서버 기록 + 관리자 공지별 읽음 집계 (관리자 개편 후속, docs/ADMIN_REDESIGN.md)
-- 멱등(if not exists / create or replace). 적용 순서: 19·21·37·44 이후(centers·헬퍼·_match_sel_text·make_student_token).
--
--  · notice_reads = 학생이 공지 목록(notice.html)을 열어 그 공지를 본 기록. 기기 localStorage 읽음(app.js
--    markNoticesRead)은 그대로 두고, 같은 순간 서버에도 남긴다.
--  · PII(이름): anon 정책 없음 → rls-check MUST_BE_BLOCKED 등록 필수. 관리자는 자기 센터 행만 조회.
--  · 쓰기는 mark_notices_read(코드 또는 서명토큰 — my_attendance_days 와 같은 본인 확인)만. 클라가 보낸 이름·센터는 받지 않는다.
--  · 공지를 지우면(관리자 삭제·비콘 저녁 정리 sql/51) 읽음 기록도 같이 지워진다(on delete cascade).
--  · 집계는 admin_notice_reads — 대상 = 그 센터 students 명단 중 공지 대상 규칙(public_notices 와 같은 판정)에 맞는 학생.
--    지원자·기업 담당자는 본인 확인 수단이 없어 집계 밖.
-- =====================================================================

create table if not exists public.notice_reads (
  notice_id uuid not null references public.notices(id) on delete cascade,
  center_id uuid not null references public.centers(id),
  name      text not null,
  read_at   timestamptz not null default now()
);
create unique index if not exists notice_reads_uniq
  on public.notice_reads (notice_id, (replace(trim(name), ' ', '')));
create index if not exists notice_reads_center on public.notice_reads (center_id);

alter table public.notice_reads enable row level security;

-- 관리자 조회만(센터 스코프). 쓰기는 RPC(security definer)만 — 관리자도 직접 넣지 않는다.
drop policy if exists "notice reads admin select" on public.notice_reads;
create policy "notice reads admin select" on public.notice_reads
  for select to public
  using (is_super_admin() or center_id = current_admin_center());

revoke all on public.notice_reads from anon;
revoke insert, update, delete on public.notice_reads from authenticated;
grant select on public.notice_reads to authenticated;

-- ── 학생: 본 공지 기록 ──
-- p_ids: 화면에 보인 공지 id(최대 200개). 자기 센터의 발행된 공지만 남고, 이미 있으면 그대로(처음 본 시각 유지).
create or replace function public.mark_notices_read(p_ids uuid[], p_code text default null, p_token text default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare ip text; v_name text; v_center uuid; n int := 0;
begin
  ip := coalesce(current_setting('request.headers', true)::jsonb ->> 'x-forwarded-for', 'unknown');
  begin
    perform check_verify_rate('nread:' || ip);
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
  if v_name is null or v_center is null then
    return jsonb_build_object('ok', false);
  end if;

  insert into notice_reads (notice_id, center_id, name)
  select n.id, v_center, trim(v_name)
    from notices n
   where n.id = any((coalesce(p_ids, '{}'::uuid[]))[1:200])
     and n.center_id = v_center and n.published
  on conflict (notice_id, (replace(trim(name), ' ', ''))) do nothing;
  get diagnostics n = row_count;
  return jsonb_build_object('ok', true, 'recorded', n);
end $$;
revoke all on function public.mark_notices_read(uuid[], text, text) from public;
grant execute on function public.mark_notices_read(uuid[], text, text) to anon, authenticated;

-- ── 관리자: 공지별 읽음 n / 대상 n · 안 읽은 사람 ──
-- 반환: [{id, targets, read, unread:[이름…], others}]  others = 대상 밖인데 읽은 수(받는 대상을 바꾼 학생 등)
-- 자기 센터 공지만(super_admin 은 전체). 다른 센터 id 를 넘기면 결과에서 빠진다.
create or replace function public.admin_notice_reads(p_ids uuid[])
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_out jsonb;
begin
  if not exists (select 1 from admin_users au where au.user_id = auth.uid()) then
    raise exception 'not_admin';
  end if;
  with nn as (
    select n.id, n.center_id, coalesce(n.target_scope, 'all') scope, n.target_value
      from notices n
     where n.id = any((coalesce(p_ids, '{}'::uuid[]))[1:100])
       and (is_super_admin() or n.center_id = current_admin_center())
  ), tg as (   -- 공지별 대상 학생(정규화 이름)
    select nn.id, s.name, replace(trim(s.name), ' ', '') k
      from nn join students s on s.center_id = nn.center_id
     where case nn.scope
             when 'all'      then true
             when 'personal' then s.phone is not null and exists (
                                    select 1 from notice_recipients r
                                     where r.notice_id = nn.id and r.student_token = make_student_token(s.name, s.phone))
             when 'job'      then nn.target_value = any(coalesce(s.job_keys, '{}'))
             when 'company'  then nullif(s.company, '') is not null and _norm_co(s.company) = _norm_co(nn.target_value)
             when 'target'   then s.target_type = nn.target_value
             when 'type'     then s.type1 = nn.target_value
             when 'custom'   then _match_sel_text(nn.target_value, jsonb_build_object(
                                    'job_key', (s.job_keys)[1], 'interest_jobs', to_jsonb(coalesce(s.job_keys, '{}')),
                                    'company', s.company, 'type1', s.type1, 'target_type', s.target_type,
                                    'manager', s.manager), true)
             else false
           end
  ), rd as (
    select nr.notice_id id, replace(trim(nr.name), ' ', '') k from notice_reads nr join nn on nn.id = nr.notice_id
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', nn.id,
           'targets', (select count(distinct tg.k) from tg where tg.id = nn.id),
           'read', (select count(distinct tg.k) from tg join rd on rd.id = tg.id and rd.k = tg.k where tg.id = nn.id),
           'unread', (select coalesce(jsonb_agg(x.name order by x.name), '[]'::jsonb) from (
                        select distinct on (tg.k) tg.name from tg
                         where tg.id = nn.id and not exists (select 1 from rd where rd.id = tg.id and rd.k = tg.k)
                         order by tg.k) x),
           'others', (select count(*) from rd where rd.id = nn.id
                         and not exists (select 1 from tg where tg.id = rd.id and tg.k = rd.k))
         )), '[]'::jsonb)
    into v_out
    from nn;
  return v_out;
end $$;
revoke all on function public.admin_notice_reads(uuid[]) from public, anon;
grant execute on function public.admin_notice_reads(uuid[]) to authenticated;

-- 검증 쿼리 (적용 후):
--   set local role anon; select count(*) from notice_reads;                 -- → permission denied 여야 정상
--   select mark_notices_read(array[<공지id>]::uuid[], 'WRONGCODE');          -- → ok:false
--   (관리자) select admin_notice_reads(array[<공지id>]::uuid[]);              -- → [{targets, read, unread…}]
