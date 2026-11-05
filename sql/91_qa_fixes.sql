-- =====================================================================
-- 91_qa_fixes.sql — 11/5 앱 검수
--  · 기업 화면에서 능력단위 고치기를 뺐으니(능력단위는 시간표대로) 서버 함수도 막음 — 함수는 남기되 익명·로그인 사용자 실행 권한 회수
--  · 휴가·출장 결과 알림: '회사 일정' 종류와 옮긴 날(→11/20)을 문구에 넣음(나머지는 sql/72 와 같음)
-- =====================================================================
revoke execute on function public.company_set_daily_units(text, uuid, date, jsonb, text) from public, anon, authenticated;
revoke execute on function public.company_reset_daily_units(text, uuid, date) from public, anon, authenticated;

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
           string_agg(to_char(a.day, 'FMMM/FMDD') || case a.kind when 'trip' then '(출장)' when 'sched' then '(회사 일정)' else '(휴가)' end || coalesce('→' || to_char(a.moved_to, 'FMMM/FMDD'), ''), '·' order by a.day)
             filter (where a.state = 'applied') as applied,
           string_agg(to_char(a.day, 'FMMM/FMDD') || case a.kind when 'trip' then '(출장)' when 'sched' then '(회사 일정)' else '(휴가)' end || coalesce('→' || to_char(a.moved_to, 'FMMM/FMDD'), ''), '·' order by a.day)
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
