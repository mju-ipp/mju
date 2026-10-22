-- =====================================================================
-- sql/74_drop_ipp.sql — 관리자 '현황'(2027 학습기업 참여 현황, sql/68) 데이터까지 삭제 (2026-10-22)
--
-- 사용자 결정(10/22): "데이터까지 아예 지워줘, 쓸모가 없는 것 같아". 관리자 화면의 '현황' 메뉴·코드도 함께 뺌(admin.html).
--  · 지우는 것: ipp_postings(IPP 공고 31건) · ipp_company_track(우리 쪽 기록 8건) 표, upload_ipp_postings · set_ipp_company ·
--    _ipp_center · _ipp_date 함수.
--  · 기업 담당자 화면의 '우리 회사 진행 현황'(my_company_stage → company_stages, sql/04)은 다른 표라 영향 없음.
--  · rls-check MUST_BE_BLOCKED 에서도 두 표를 뺌.
--  · 멱등(if exists). 되돌리려면 sql/68 다시 적용(데이터는 복구 안 됨).
-- =====================================================================

drop function if exists public.upload_ipp_postings(int, jsonb, timestamptz, uuid);
drop function if exists public.set_ipp_company(int, text, jsonb, boolean, uuid);
drop function if exists public._ipp_center(uuid);
drop function if exists public._ipp_date(text);
drop table if exists public.ipp_company_track;
drop table if exists public.ipp_postings;
