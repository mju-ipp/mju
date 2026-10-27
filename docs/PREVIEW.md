# 학생·기업 화면 보기 전용 미리보기 (2026-10-27~)

사용자 요청(10/27): "관리자 콘솔에서 기업이랑 학생이 어떻게 보이는지도 보고 싶다."
지금은 시크릿 창에서 초대코드로 가입해야 볼 수 있음 → 가입 기록·읽음 집계·체크가 실제로 바뀜. 그래서 **아무것도 바뀌지 않는** 미리보기를 만든다.

## 목표 (완료 기준)
- 학생 명단 줄·학생 상세 시트·기업 줄에 **[화면 보기]** → 새 탭에 그 학생(또는 기업 담당자)이 보는 홈·일정·공지·대화방·자료실·내 학습기업이 그대로 열림.
- 탭 위에 띠: **"○○ 화면 미리보기 · 보기 전용 · [닫기]"**.
- 미리보기 전후로 아래 표의 행 수가 **같다**(운영 확인 기준): registrations · notice_reads · chat_student_reads · push_tokens · task_checks(학생·기업) · attendance_absences · chat_messages · survey 응답 · consultations.
- 관리자 브라우저의 기기 가입 정보(`localStorage.ilhak_profile`)를 건드리지 않음.

## 조사 결과 (10/27)
- 신원 = 기기의 `ilhak_profile`(target_type·code·token). 학생 함수는 `p_code`(초대코드) 또는 `p_token`(서명토큰 = `make_student_token(이름, 전화)`)으로 본인 확인.
  - 토큰만 받는 함수: `my_targeted_calendar_from`·`my_task_checks`(index) · `my_personal_notices`(notice) · `my_targeted_library`(library) → 미리보기에도 **토큰이 필요**. 관리자 화면은 토큰을 모름 → 서버 함수로 받아야 함.
- 관리자 화면(admin.html)과 학생 앱이 **같은 주소**(mju-ipp.github.io/mju) → localStorage 공유. 미리보기 신원을 localStorage 에 쓰면 그 브라우저의 학생 앱 가입 정보를 덮어씀 → **탭마다 따로인 sessionStorage** 사용.
- 프로필을 읽는 곳: `app.js getProfile()`(5곳) + 각 화면이 localStorage 를 직접 읽는 8곳(index·notice 외 company-survey·consult·faq·install 2·mycompany·survey).
- 열기만 해도 서버가 바뀌는 것:
  - `my_chat_messages` — 방을 열면 `chat_student_reads` 에 읽음 기록(sql/79) → 관리자 '안 읽음 n'이 틀어짐.
  - `mark_notices_read`(app.js) — 공지 화면 열면 `notice_reads` 기록(sql/57).
  - `register_push_token`·`unregister_push_token`(app.js) — 그 브라우저 알림 권한에 따라 기기 등록/삭제 → '알림 n대'·'마지막 앱 사용'이 틀어짐.
  - 그 밖의 읽기 함수(my_attendance·my_absences·company_home·my_company_info·my_chats 등)는 쓰기 없음(확인).
- 누르면 바뀌는 것: complete/uncheck_task·complete/uncheck_company_task·report/cancel_absence·company_absence(_cancel)·post_chat_message·create_consultation·add_consultation_message·submit_survey_answer·submit_company_survey_response·register_*·verify_*(가입) · 화면의 '가입 정보 지우기'(localStorage.removeItem).

## 방식
1. 관리자가 [화면 보기] → 서버 함수 `admin_preview_identity` 로 프로필(이름·기업·유형·담당·직무·초대코드·토큰)을 받음.
2. 1회용 전달: 관리자 탭이 `localStorage.ilhak_preview_handoff` 에 넣고 `index.html?preview=1` 새 탭을 엶 → 새 탭이 읽자마자 지우고 `sessionStorage` 로 옮김(같은 탭 안 이동 동안만 유지, 탭 닫으면 사라짐). URL 에 토큰을 싣지 않음(방문 기록에 남지 않게).
3. 미리보기 탭에서 `getProfile()` 이 sessionStorage 미리보기 프로필을 먼저 돌려줌. 직접 읽는 8곳은 `getProfile()` 로 바꿈.
4. **허용 목록 방식으로 막기** — app.js 가 `supabase.rpc` 를 감싸서, 미리보기 중에는 읽기 함수 목록에 있는 것만 서버로 보냄. 나머지는 서버에 안 가고 `{ok:false, reason:'preview'}` + 토스트 "미리보기에서는 저장되지 않아요". 새 쓰기 함수가 생겨도 기본이 '막힘'이라 안전.
   - 버튼은 숨기지 않음(실제 화면과 같아야 하므로) — 눌렀을 때만 안내.
   - 푸시 등록·해제, `mark_notices_read`, 기기 안 읽음 목록(localStorage), '가입 정보 지우기'(→ 미리보기 닫기로 대체)는 미리보기 중 건너뜀.
5. `my_chat_messages` 에 `p_peek boolean default false` 추가 — true 면 글만 주고 읽음 기록 안 함. 학생이 넘겨도 자기 읽음만 안 남는 것이라 해 없음.

## 단계
1. **sql/88_admin_preview.sql** — ✅ 10/27 운영 적용(pglite 27 PASS, 운영 API: 기존 3인자 호출 동작·anon 차단)
   - `admin_preview_identity(p_kind text, p_id text)` — kind 'student'(students.id) / 'company'(기업명). 로그인한 관리자 + **같은 센터**만. 학생: 명단 값 + 초대코드(student_codes) + `make_student_token`. 기업: 기업 초대코드. 전화번호는 돌려주지 않음.
   - 누가 언제 누구 화면을 봤는지 `admin_logs` 에 한 줄(토큰을 받아가는 함수라서).
   - `my_chat_messages` `p_peek` 추가.
   - pglite 시험: 다른 센터·비로그인·anon 차단, peek 이면 chat_student_reads 0행, 기존 호출(peek 없음)은 그대로 읽음 기록.
   - SQL 은 보여드리고 승인 후 운영 적용.
2. **학생 앱 미리보기 모드 (app.js + 화면 8곳)** — ✅ 10/27 커밋(배포는 3단계와 함께). 전달·sessionStorage·getProfile 우선·rpc 허용 목록(막히면 오류 code PREVIEW + 토스트, friendlyError 문구)·띠·푸시/읽음 건너뛰기. `my_chat_messages` 는 app.js 가 미리보기면 `p_peek:true` 를 붙임(chat.html 수정 없음). 다시 가입 링크 = 미리보기 닫기. 상담은 이 기기 상담 번호 대신 새 상담 화면. sw.js CACHE v90. 모의(launch `preview-mode-mock` 5198): 학생 10개·기업 화면 오류 0, 쓰기 호출 0, 기기 ilhak_profile·읽음 목록 그대로, 60초 지난 전달값 무시, 평소 모드 글쓰기·읽음 그대로.
3. **관리자 버튼 (admin.html)** — ✅ 10/27 배포. 학생 › 명단 줄 '관리' 칸 눈 아이콘(명단 dbId 없으면 꺼짐)·학생 상세 창 머리 [학생 화면 보기](이름→students id, 진행중·최근 기수 먼저)·기업 › 기업·초대코드 줄 [화면 보기](켜진 코드만). 클릭 직후 빈 탭을 먼저 열어 팝업 차단 회피. 모의 확인 3곳 모두 열림. (원래 계획: 학생 명단 줄·학생 상세 시트·기업·초대코드 줄에 [화면 보기]. 내 학생/전체 보기 모두 가능(10/16 결정 ① — 권한 차단 아님, 같은 센터).
4. **확인**
   - 모의(mockserver)로 화면별 오류 0, 막힌 버튼 눌러 토스트 확인, 서버로 나간 요청 목록에 쓰기 함수 0.
   - 운영: 사용자 로그인 후 학생 1명·기업 1곳 미리보기 → 위 9개 표 행 수 전후 비교(같아야 함), 관리자 브라우저 `ilhak_profile` 그대로인지.

## 정할 것
- 범위: 학생 + 기업 담당자만(지원자·가입 전 화면은 제외) — 제안.
- 다른 선생님 학생도 미리보기 가능 — 제안(기존 '전체 보기'와 같은 원칙).
- 열람 기록(admin_logs) 남김 — 제안.
- 막힌 버튼: 숨기지 않고 눌렀을 때 안내 — 제안.

## 하지 않는 것
- 미리보기에서 대신 체크·신고·글쓰기(필요하면 관리자 화면 기존 기능으로).
- 실제 휴대폰 화면 크기 흉내(새 탭은 PC 폭 그대로 — 필요하면 브라우저 개발자 도구 기기 모드).
