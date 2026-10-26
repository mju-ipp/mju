-- 86. 알림 권한을 끈 기기는 앱을 열 때 바로 등록 지우기 (2026-10-26 사용자: "알림 켜놓고 끄면 그것도 잡히나" → 앱 열 때 바로 빠지게)
-- 재실행해도 안전(create or replace).
--
--  · 전엔 권한을 꺼도 push_tokens 행이 남아 관리자 '알림 n대'·대화방 '알림 꺼짐'이 그대로였음.
--    다음 발송 때 FCM 이 UNREGISTERED 를 돌려줘야 push-sender 가 지웠음(그 기기로 보낼 일이 없으면 계속 켬으로 보임).
--  · 이제 앱이 알림을 켤 때(install.html)·하루 1회 갱신 때(app.js) 받은 FCM 토큰을 그 기기 localStorage('ilhak_push_token')에 두고,
--    앱을 열었는데 권한이 'granted' 가 아니면 이 함수로 그 토큰 행을 지운다.
--  · unregister_push_token(p_token) → {ok, removed} — 비로그인(anon) 호출. 토큰 원문을 아는 기기만 지울 수 있음
--    (토큰은 그 기기 FCM 구독 번호라 남이 알 수 없음, 지우는 것뿐이라 다시 켜면 그대로 복구). 다른 표·행은 못 건드림.

create or replace function public.unregister_push_token(p_token text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if p_token is null or char_length(p_token) < 20 or char_length(p_token) > 4096 then
    return jsonb_build_object('ok', false, 'reason', 'token');
  end if;
  delete from push_tokens where token = p_token;
  get diagnostics n = row_count;
  return jsonb_build_object('ok', true, 'removed', n);
end $$;

revoke all on function public.unregister_push_token(text) from public;
grant execute on function public.unregister_push_token(text) to anon, authenticated, service_role;
