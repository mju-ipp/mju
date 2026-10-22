-- =====================================================================
-- sql/73_company_signup_reopen.sql — 기업 담당자 가입 다시 열기 (2026-10-22)
--
-- 증상(10/22): 기업 초대코드로 가입이 안 됨. 원인 두 가지 —
--   ① config.js TARGET_TYPES 가 학생 전용(8/19)이라 가입 화면에 '기업 담당자' 선택지가 없었음(→ config.js 에서 복원)
--   ② 운영 verify_company_code_solo 의 anon 실행 권한이 빠져 있었음(저장소 sql/09·13·24 는 grant — 운영에서 따로 빠짐).
--  · 이 파일: ② 권한만 되돌림. 함수 본문은 운영 그대로(코드 → 기업명·센터 + HRD 담당자 자동채움, IP 당 10분 30회 제한).
--  · 가입 자체는 register_with_code(기업 코드도 받음)가 하고, 가입 뒤 본인 확인은 프로필 code(_company_me, sql/70).
--  · 멱등.
-- =====================================================================

grant execute on function public.verify_company_code_solo(text) to anon, authenticated;
