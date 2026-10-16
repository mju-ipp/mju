# 대화방 — 기업방 · 1:1 (2026-10-16~)

사용자 결정(10/16): 기업마다 그 기업 학생 여럿 + **센터 선생님**이 함께 있는 방(단톡방처럼 서로 글이 다 보임, 기업 HRD 담당자는 없음) + 학생 한 명과 선생님의 1:1. **선생님 글만 푸시**(학생 글은 푸시 없음). 알림은 운영으로 강제 — 콘솔에 기업별 알림 받는 학생 수 표시 예정.

## 단계
1. **DB·학생 함수 — sql/65_chat_rooms.sql** (이 문서와 함께)
2. **학생 페이지 chat.html(10/16)** — 홈 '소통·참여' 맨 위 '대화방 (우리 회사·선생님)'(학생만). 방 목록(기업방·1:1, 마지막 글) → 대화(내 글 오른쪽 파랑, 선생님 글 연파랑, 다른 학생 이름). 자동 새로고침 없음: 열 때·보낼 때·'새로 불러오기'·앱으로 돌아와 1분 지났을 때. `chat.html?room=<id>` 로 바로 열림(4단계 푸시 링크용). sw 캐시 목록에 chat.html.
3. **관리자 '상담 › 대화방 (기업방·1:1)' (10/16, sql/66)** — 상담 버튼의 첫 화면. [내 담당|전체](명단 담당직원 = 내 이름)·[기업방|1:1], 방마다 학생 수·알림 받는 학생 n/m(못 받으면 주황)·마지막 글·새 글 수. 방을 열면 학생 명단(알림 꺼짐 표시)·글(숨기기/다시 보이기)·보내기. 내 이름은 [이름 바꾸기](set_my_display_name). '상담' 배지 = 미답변 상담 + 대화방 새 글. sql/66: chat_reads(선생님별 읽음), admin_chat_rooms(명단 기준으로 방을 미리 만들어 둠 — 학생이 앱을 안 열어도 선생님이 먼저 씀), admin_chat_read, set_my_display_name, 권순천 계정 이름 채움. pglite 16 PASS(test66.mjs). 알림 받는지 = push_tokens.device_key = 학생 서명토큰(10/16 운영 17명 중 15명).
4. 푸시: push-sender 에 chat_messages(push_state='pending') 줄 — 기업방 → 그 기업 학생 기기(push_tokens.company 정규화), 1:1 → 그 학생 기기(device_key = 학생 서명토큰)

## sql/65 요점
- `chat_rooms`(kind company/direct, company_key = `_co_key(기업명)` — sql/18 정규화와 같음) · `chat_messages`(sender student/teacher, hidden, push_state). 센터 스코프 RLS, anon 직접 접근 없음 → rls-check MUST_BE_BLOCKED·DELETE_BLOCKED 등록.
- `admin_users.display_name` 추가 — 선생님 글 이름('○○ 선생님')은 `admin_post_chat` 이 서버에서 붙임. 비어 있으면 '센터 선생님'.
- 학생: `my_chats(p_code, p_token)` 내 방 목록(없으면 만듦) · `my_chat_messages(…, p_room)` 최근 200 · `post_chat_message(…, p_room, p_text)` 1~2000자. 소속 기업은 **명단 students.company**(클라가 보낸 기업명 안 씀).
- 호출 제한: 본인 확인 **실패만** IP 10분 30회(`chatfail:`) — 회사 와이파이·통신사 공용 IP 학생들이 방을 열 때 걸리지 않게. 학생 글은 10분 20개.
- 기존 1:1 상담(consultations)은 그대로 둠 — 표 정의가 저장소에 없고 상담 id 만 알면 열리는 방식이라, 새 1:1 은 코드·토큰 본인 확인으로 따로 만듦. 상담을 새 1:1 로 합칠지는 2단계 뒤 결정.
- 시험: scratchpad pgl/test65.mjs(pglite) 34개 PASS — 다른 기업·다른 센터·남의 1:1 0건, anon 직접·내부 함수·관리자 함수 차단, 숨긴 글 비표시, 제한.
