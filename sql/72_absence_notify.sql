-- =====================================================================
-- sql/72_absence_notify.sql — 휴가·출장 체크 5단계: 반영·반려 알림 (2026-10-22, docs/LEAVE.md)
--
-- 사용자 결정(10/22): 반영("옮겼어요")·반려 둘 다 학생 본인에게 알림, 기업 담당자 푸시는 보류(등록 기기 0대),
--   선생님 콘솔 배지는 '내 학생' 기본(admin.html 쪽).
--
--  · attendance_absences.notified_at — 반영·반려를 학생에게 알린 시각. null = 아직 안 알림.
--      이 파일을 적용할 때 이미 반영·반려된 건은 알린 것으로 표시(배포 직후 옛 건으로 알림이 울리지 않게).
--  · admin_absence_notify() — 관리자(자기 센터)만. 반영·반려됐는데 안 알린 건을 학생마다 한 통으로 묶어
--      개인 공지(notices personal + notice_recipients) → push-sender 깨움. 받는 사람 = 체크한 사람과 상관없이 그 학생 본인.
--      · 처리한 지 3일 넘은 건은 보내지 않고 알린 것으로만 표시(뒤늦게 옛 건이 울리지 않게).
--      · 전화가 없어 서명토큰을 못 만드는 학생도 알린 것으로 표시(매번 다시 시도하지 않게) — 'nophone' 으로 셈.
--      · notified_at 을 먼저 찍고 보내므로 두 번 불러도 한 번만(동시 호출은 for update skip locked).
--  · 멱등: add column if not exists / create or replace.
-- =====================================================================

alter table public.attendance_absences add column if not exists notified_at timestamptz;

-- 적용 시점까지 반영·반려된 건 = 알린 것으로(처음 적용할 때만 의미 있음 — 그 뒤엔 대상 없음)
update public.attendance_absences set notified_at = coalesce(handled_at, updated_at)
 where state in ('applied', 'rejected') and notified_at is null
   and not exists (select 1 from pg_proc where proname = 'admin_absence_notify' and pronamespace = 'public'::regnamespace);

create or replace function public.admin_absence_notify()
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  au public.admin_users; v_center uuid; v_notice uuid; v_by text;
  r record; tok text; v_title text; v_body text; cnt int := 0; stale int := 0; nophone int := 0;
  ids uuid[];
begin
  select * into au from admin_users where user_id = auth.uid();
  if au.user_id is null then return jsonb_build_object('ok', false, 'reason', 'auth'); end if;
  v_center := au.center_id;

  -- 먼저 잡아서 표시(동시에 두 콘솔이 불러도 같은 건을 두 번 보내지 않게)
  select coalesce(array_agg(id), '{}') into ids from (
    select id from attendance_absences
     where center_id = v_center and state in ('applied', 'rejected') and notified_at is null
     for update skip locked) x;
  if array_length(ids, 1) is null then return jsonb_build_object('ok', true, 'sent', 0, 'stale', 0, 'nophone', 0); end if;
  update attendance_absences set notified_at = now() where id = any(ids);

  select count(*) into stale from attendance_absences
   where id = any(ids) and coalesce(handled_at, updated_at) < now() - interval '3 days';

  v_by := 'admin:absence-notify-' || to_char(now() at time zone 'Asia/Seoul', 'MMDDHH24MISS');
  for r in
    select a.student_id, s.name, s.phone,
           string_agg(to_char(a.day, 'FMMM/FMDD') || case a.kind when 'trip' then '(출장)' else '(휴가)' end, '·' order by a.day)
             filter (where a.state = 'applied') as applied,
           string_agg(to_char(a.day, 'FMMM/FMDD') || case a.kind when 'trip' then '(출장)' else '(휴가)' end, '·' order by a.day)
             filter (where a.state = 'rejected') as rejected
      from attendance_absences a
      join students s on s.id = a.student_id and s.center_id = a.center_id
     where a.id = any(ids) and coalesce(a.handled_at, a.updated_at) >= now() - interval '3 days'
     group by a.student_id, s.name, s.phone
  loop
    if r.phone is null then nophone := nophone + 1; continue; end if;
    tok := make_student_token(r.name, r.phone);
    v_title := case when r.applied is not null then '휴가·출장 정규시간을 옮겼어요' else '휴가·출장 체크가 반려됐어요' end;
    v_body := concat_ws(' ',
      case when r.applied is not null then r.applied || ' 빠지는 정규시간을 다른 날로 옮겼어요. 앱 홈 달력에서 바뀐 날을 확인하세요.' end,
      case when r.rejected is not null then r.rejected || ' 체크는 반려됐어요. 궁금하면 선생님께 물어보세요.' end);
    if v_notice is null then
      insert into notices (center_id, title, body, target_scope, published, created_by, pushed)
      values (v_center, '휴가·출장 체크 결과', '체크한 날의 처리 결과를 알려드려요.', 'personal', true, v_by, false)
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
  return jsonb_build_object('ok', true, 'sent', cnt, 'stale', stale, 'nophone', nophone);
end $$;
revoke all on function public.admin_absence_notify() from public, anon;
grant execute on function public.admin_absence_notify() to authenticated;
