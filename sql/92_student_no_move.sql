-- =====================================================================
-- 92_student_no_move.sql — 학생 앱에서는 날짜를 못 옮김(11/5 사용자). 훈련 일정은 회사가 과정 단위로 옮김(sql/90).
--  · report_absence(학생 새 체크) → 항상 {ok:false, reason:'company_only'} (옛 앱 캐시가 불러도 안전). 이미 한 체크의 취소(cancel_absence)는 그대로.
-- =====================================================================
create or replace function public.report_absence(p_code text default null, p_token text default null, p_day date default null,
                                                 p_kind text default null, p_note text default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  return jsonb_build_object('ok', false, 'reason', 'company_only');
end $$;
revoke all on function public.report_absence(text, text, date, text, text) from public;
grant execute on function public.report_absence(text, text, date, text, text) to anon, authenticated;
