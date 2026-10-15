-- =====================================================================
-- 56_notice_dedup.sql — 같은 공지 10분 내 재발행을 서버에서 막기 (관리자 개편 후속, docs/ADMIN_REDESIGN.md)
-- 멱등(if not exists / create or replace / drop trigger if exists). 적용 순서: 19·21 이후(centers·set_center_id 트리거).
--
--  · 배경: 9/29 만족도 공지처럼 같은 공지가 연달아 두 번 저장되면 push-sender 는 두 건을 각각 정상 발송한다
--    (sql/52 push-sender 의 선점은 '한 건이 두 번' 나가는 것만 막음). 관리자 화면 경고(admin.html recentSameTitle)는
--    보내기 한 곳뿐이라 자료·일정·채용·기업 공지 경로와 두 번 누르기·두 탭은 못 막는다.
--  · 규칙: 같은 센터 · 같은 제목(앞뒤 공백 무시) · 같은 target_scope · 같은 target_value 공지가
--    10분 안에 이미 있으면 insert 를 'duplicate_notice' 로 거절. detail = 앞선 공지 시각(KST HH:MI).
--  · 우회: 관리자가 일부러 다시 보낼 때 resend_ok = true 로 넣으면 통과(그 행에 기록으로 남음).
--  · 제외: personal(개인 안내·비콘 알림) — 제목이 매번 같은 게 정상이고 수신자는 notice_recipients 가 정한다.
--  · 트리거 이름은 set_center_id 보다 뒤(알파벳 순 실행)여야 center_id 가 채워진 뒤 검사한다 → z_ 접두.
-- =====================================================================

alter table public.notices add column if not exists resend_ok boolean not null default false;

create or replace function public._notice_dedup()
returns trigger
language plpgsql security definer set search_path = public as $$
declare v_prev timestamptz;
begin
  if not coalesce(NEW.published, false) or coalesce(NEW.target_scope, 'all') = 'personal'
     or coalesce(NEW.resend_ok, false) then
    return NEW;
  end if;
  -- 같은 공지를 동시에 두 번 넣는 경우(두 번 누르기·두 탭)도 하나만 통과하게 키 단위로 줄 세운다
  perform pg_advisory_xact_lock(hashtextextended(
    coalesce(NEW.center_id::text, '') || '|' || btrim(coalesce(NEW.title, '')) || '|' ||
    coalesce(NEW.target_scope, 'all') || '|' || coalesce(NEW.target_value, ''), 56));
  select max(n.created_at) into v_prev
    from notices n
   where n.center_id is not distinct from NEW.center_id
     and btrim(n.title) = btrim(coalesce(NEW.title, ''))
     and coalesce(n.target_scope, 'all') = coalesce(NEW.target_scope, 'all')
     and n.target_value is not distinct from NEW.target_value
     and n.created_at > now() - interval '10 minutes';
  if v_prev is not null then
    raise exception using errcode = 'P0001', message = 'duplicate_notice',
      detail = to_char(v_prev at time zone 'Asia/Seoul', 'HH24:MI'),
      hint = '같은 공지를 10분 안에 이미 보냈어요. 일부러 다시 보내려면 resend_ok = true 로 넣으세요.';
  end if;
  return NEW;
end $$;
revoke all on function public._notice_dedup() from public, anon, authenticated;

drop trigger if exists z_notice_dedup on public.notices;
create trigger z_notice_dedup before insert on public.notices
  for each row execute function public._notice_dedup();

-- 검증 쿼리 (적용 후, 관리자 세션 또는 SQL 편집기):
--   insert into notices (center_id, title, body, target_scope, published) values (<센터>, '시험', '본문', 'all', false);  -- 발행 안 함 → 통과
--   같은 행을 published=true 로 두 번 → 두 번째가 duplicate_notice, resend_ok=true 면 통과
