# 대화방 — 기업방 · 1:1 (2026-10-16~)

사용자 결정(10/16): 기업마다 그 기업 학생 여럿 + **센터 선생님**이 함께 있는 방(단톡방처럼 서로 글이 다 보임, 기업 HRD 담당자는 없음) + 학생 한 명과 선생님의 1:1. **선생님 글만 푸시**(학생 글은 푸시 없음). 알림은 운영으로 강제 — 콘솔에 기업별 알림 받는 학생 수 표시 예정.

## 단계
1. **DB·학생 함수 — sql/65_chat_rooms.sql** (이 문서와 함께)
2. 학생 페이지 '우리 회사 방'·1:1 (홈 '소통·참여')
3. 관리자 콘솔 '기업방' 탭(내 담당 기업 기본·전체, 새 글 표시, 숨기기, 알림 받는 학생 수)
4. 푸시: push-sender 에 chat_messages(push_state='pending') 줄 — 기업방 → 그 기업 학생 기기(push_tokens.company 정규화), 1:1 → 그 학생 기기(device_key = 학생 서명토큰)

## sql/65 요점
- `chat_rooms`(kind company/direct, company_key = `_co_key(기업명)` — sql/18 정규화와 같음) · `chat_messages`(sender student/teacher, hidden, push_state). 센터 스코프 RLS, anon 직접 접근 없음 → rls-check MUST_BE_BLOCKED·DELETE_BLOCKED 등록.
- `admin_users.display_name` 추가 — 선생님 글 이름('○○ 선생님')은 `admin_post_chat` 이 서버에서 붙임. 비어 있으면 '센터 선생님'.
- 학생: `my_chats(p_code, p_token)` 내 방 목록(없으면 만듦) · `my_chat_messages(…, p_room)` 최근 200 · `post_chat_message(…, p_room, p_text)` 1~2000자. 소속 기업은 **명단 students.company**(클라가 보낸 기업명 안 씀).
- 호출 제한: 본인 확인 **실패만** IP 10분 30회(`chatfail:`) — 회사 와이파이·통신사 공용 IP 학생들이 방을 열 때 걸리지 않게. 학생 글은 10분 20개.
- 기존 1:1 상담(consultations)은 그대로 둠 — 표 정의가 저장소에 없고 상담 id 만 알면 열리는 방식이라, 새 1:1 은 코드·토큰 본인 확인으로 따로 만듦. 상담을 새 1:1 로 합칠지는 2단계 뒤 결정.
- 시험: scratchpad pgl/test65.mjs(pglite) 34개 PASS — 다른 기업·다른 센터·남의 1:1 0건, anon 직접·내부 함수·관리자 함수 차단, 숨긴 글 비표시, 제한.
