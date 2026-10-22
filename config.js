/* =====================================================================
 *  config.js  —  이 파일 한 곳만 고치면 됩니다 (가장 자주 만지는 설정 파일)
 *  - 한글 깨짐 방지: 반드시 "UTF-8" 인코딩으로 저장하세요.
 *  - 따옴표(' ') 안의 값만 바꾸고, 콤마/중괄호는 건드리지 마세요.
 * ===================================================================== */

/* =====================================================================
 *  [P1] 멀티테넌트 센터 컨텍스트 부트스트랩
 *  - 모든 페이지가 config.js 를 가장 먼저(동기) 로드하므로 여기서 한 번만 정함.
 *  - 활성 센터 식별 우선순위: URL ?center=slug  >  localStorage('ilhak_center')  >  기본값.
 *  - 한 번 들어온 센터는 localStorage 에 저장 → 페이지 이동·PWA 재실행(홈화면 앱)에서도 유지.
 *  ⚠️ window.CENTER_SLUG 는 '화면 표시·컨텍스트 힌트'일 뿐, 데이터 접근 권한의 근거가 아니다.
 *     실제 센터 귀속(누가 어느 센터 데이터를 보는가)은 서버가 정한다 —
 *     초대코드 기반 SECURITY DEFINER RPC 로 도출하며 클라이언트가 보낸 center 값은 신뢰하지 않는다.
 * ===================================================================== */
window.DEFAULT_CENTER = 'mju';   // 명지대(파일럿) — 센터 미지정 시 기본값

// 순수 함수(브라우저·Node 양쪽에서 테스트 가능): 입력 3개로 슬러그 결정
window.__resolveCenterSlug = function (fromUrl, saved, def) {
  var SLUG_RE = /^[a-z0-9-]{1,40}$/;                 // 허용: 소문자/숫자/하이픈
  var pick = (fromUrl || saved || def || 'mju').toString().trim().toLowerCase();
  return SLUG_RE.test(pick) ? pick : (def || 'mju');
};

(function bootstrapCenter() {
  var slug = window.DEFAULT_CENTER;
  try {
    var fromUrl = '', saved = '';
    try { fromUrl = (new URLSearchParams(location.search).get('center') || ''); } catch (_) {}
    try { saved = (localStorage.getItem('ilhak_center') || ''); } catch (_) {}
    slug = window.__resolveCenterSlug(fromUrl, saved, window.DEFAULT_CENTER);
    try { localStorage.setItem('ilhak_center', slug); } catch (_) {}   // 영속화(설치 후에도 유지)
  } catch (_) {}
  window.CENTER_SLUG = slug;
})();

window.APP_CONFIG = {
  // ── 1) Supabase 연결값 (Supabase 대시보드 > Project Settings > API 에서 복사) ──
  //    아직 없으면 placeholder 그대로 두고, README_SETUP.md 2번 순서대로 만든 뒤 붙여넣으세요.
  SUPABASE_URL:      'https://ggitgqijycvnhhraxzgn.supabase.co',
  SUPABASE_ANON_KEY: 'sb_publishable_kZe4svXj8ZmsGeXOT3xHyA_N9z1tFpU', // publishable(공개용) 키 — 노출돼도 안전

  // ── 2) 센터/앱 표시 정보 ──
  CENTER_NAME: '일학습병행 공동훈련센터',
  CENTER_SHORT: '명지대학교',   // 헤더 센터 chip용 짧은 식별명(기관명). 비우면 CENTER_NAME 사용. (멀티테넌트 시 센터별 값)
  APP_TITLE:   '일학습병행 앱',

  // ── 3) 개인정보 처리방침 안내 (가입 동의 화면에 표시) ──
  PRIVACY_RETENTION: '훈련 종료 후 3년',          // 보유기간 (기관 규정에 맞게 수정)
  PRIVACY_TRANSFER:  'Google LLC(미국)', // 국외 이전받는 자 (Supabase 데이터는 서울 리전=국내)
  // ⚠️ 학생 배포 전 반드시 실제값으로 — 개인정보보호법 게시의무(privacy.html에 표시됨):
  PRIVACY_OFFICER:         '권순천 (일학습병행운영팀)',                // 개인정보 보호책임자 성명·직책
  PRIVACY_OFFICER_CONTACT: '전화 031-324-1228 / 이메일 cherry905@mju.ac.kr',  // 보호책임자 연락처(열람·삭제·철회 창구)
  PRIVACY_EFFECTIVE_DATE:  '2026. 6. 11.',                        // 처리방침 시행일
  PRIVACY_RETENTION_APPLICANT: '해당 학년도 모집 종료 후 6개월',     // 지원자(매칭 전) 보유기간 — 학교 합의값으로 수정

  // ── 초대코드 강제 여부 ─ (미사용) 가입이 초대코드 전용으로 바뀌어 항상 필수, 플래그는 무시됨 ──
  REQUIRE_STUDENT_CODE: false,
  REQUIRE_COMPANY_CODE: false,

  // ── 즉시 푸시 ─ (2026-08-20 발송기 이전) Apps Script → Supabase 엣지 함수 push-sender.
  //    공지 발행 직후 이 URL을 깨우면 수초 내 발송, 아니어도 5분 폴링 크론(sql/52)이 처리.
  //    개인 계정 의존 제거(절대규칙 9) — 발송 로직·기록은 supabase/functions/push-sender 참조.
  PUSH_KICK_URL: 'https://ggitgqijycvnhhraxzgn.supabase.co/functions/v1/push-sender',
};

/* ── 4)·5) 훈련 직무 / 학습기업 ─ [원장 추종] config.js 정적값 폐기 ─────────
 *  직무(상세직무)·학습기업은 더 이상 여기서 하드코딩하지 않는다.
 *  유일 원장 = Supabase 마스터 테이블 `jobs`·`companies`(센터 스코프, 노션 동기화).
 *  모든 탭(가입폼·관리자 타게팅·수기등록)이 이 테이블을 직접 조회한다 → 센터별로 자동 반영.
 *  ⚠️ 식별자는 `name`(예: '정보기술'). registrations.job_key·company 에 name 이 그대로 저장된다.
 */

/* ── 6) 타게팅·편집 어휘 ─ [원장=centers.vocab] ───────────────────────
 *  담당자·유형·운영형태·상태는 Supabase `centers.vocab`에서만 읽는다.
 *  app.js applyCenterVocab()가 관리자 화면을 만들기 전에 window.*에 배급한다.
 */

/* ── 8) 푸시(FCM) 설정 ─ Firebase 콘솔에서 발급. 공개값이라 노출돼도 됨 ──
 *  Firebase 콘솔 → 프로젝트 설정 → '내 앱'(웹 </>) 에서 SDK 설정값 복사,
 *  → Cloud Messaging → '웹 푸시 인증서'에서 키 쌍 생성 후 공개키를 FCM_VAPID_KEY 에.
 */
window.FIREBASE_CONFIG = {
  apiKey:            'AIzaSyDCQj4zs_ebgM18GKotG1-7n-MVXVdHkqs',
  authDomain:        'mjuipp.firebaseapp.com',
  projectId:         'mjuipp',
  messagingSenderId: '13262157393',
  appId:             '1:13262157393:web:45caa766392425a90eaa70',
};
window.FCM_VAPID_KEY = 'BPwU6DR4mAus6qml5sw8A4kokXyuuJIB-V6HkCuvqeUTm-Xkqn9nOFS6APeY1dW6BSTyjkj6vR8cgICmUKkU7pg';

/* ── 7) 대상 구분 ─ (학생 전용 전환 2026-08-19) 기업담당자·지원자 유형 폐지.
 *  (2026-10-22) 기업 담당자만 복원 — '우리 학생 OJT'(company.html)용 기업 초대코드 가입. 지원자는 계속 닫음.
 *  지원자를 복원하려면 { key:'applicant', label:'지원자 (매칭 전 — 채용 알림 받기)' } 를 되살리면 된다. ── */
window.TARGET_TYPES = [
  { key: 'student',  label: '매칭학생 (재학생)' },
  { key: 'company',  label: '학습기업 담당자 (HRD·현장교사)' },
];

/* ── 10) 기업용 만족도 설문 2종 ─ company-survey.html(렌더)과 admin.html(집계 라벨)이 공유 ──
 *  type: 'single'(하나만) | 'multi'(중복 선택). etc:true = '기타(직접입력)' 보기 추가.
 *  score: 보기 순서대로 5점 환산값(①이 최긍정). null = 평균 계산에서 제외(해당없음 등). 없으면 분포만 집계.
 *  overall:true = 기업별 표의 기준 문항(전반 만족도).
 */
window.COMPANY_SURVEY_ROUNDS = ['2026 상반기', '2026 하반기'];
window.COMPANY_SURVEYS = {
  teacher: {
    title: '기업현장교사 만족도 조사',
    questions: [
      { key: 'q2', type: 'multi', etc: true, label: '기업현장교사로 활동하시면서 가장 어려움을 느끼시는 부분은 무엇인가요?',
        options: ['일학습병행 제도 이해', '훈련과정 개발 절차', 'NCS 능력단위 훈련 운영', '교수방법 및 내부평가 운영', '학습근로자 상담 및 관리', '교보재 선정', '별다른 어려움이 없다'] },
      { key: 'q3', type: 'multi', etc: true, label: '기업현장교사 업무 수행 시 어떤 지원이 가장 필요하다고 생각하시나요?',
        options: ['일학습병행 제도 이해', '훈련과정 설계 및 구성', 'NCS 능력단위 적용', '교수방법 및 평가 운영', '학습근로자 상담 및 관리', '교보재 선정 및 제작'] },
      { key: 'q4', type: 'multi', etc: true, label: '전담교수로부터 어떤 지원이 필요하다고 생각하시나요?',
        options: ['능력단위별 교수법 안내', 'OJT 훈련 운영 노하우', '내부평가 운영 방법', '학습근로자 면담 기법', 'NCS 및 일학습병행 제도 교육'] },
      { key: 'q5', type: 'single', etc: true, label: '명지대 일학습병행운영팀으로부터 어떤 방식의 지원을 가장 원하시나요?',
        options: ['자료 제공', '전담자 방문 교육 및 안내', '관련 교육 강좌 수강 안내'] },
      { key: 'q6', type: 'single', label: '명지대 일학습병행운영팀과의 소통은 얼마나 원활했다고 느끼시나요?',
        options: ['매우 원활', '원활', '보통', '다소 어려움', '매우 어려움'], score: [5, 4, 3, 2, 1] },
      { key: 'q7', type: 'multi', etc: true, label: '소통 과정에서 불편했던 점은 무엇인가요?',
        options: ['응답이 늦음', '담당자 변경이 잦음', '안내 부족', '자료 부족', '없음'] },
      { key: 'q8', type: 'single', label: '향후 일학습병행 사업에 참여하실 의향이 있으신가요?',
        options: ['매우 있음', '있음', '보통', '없음', '전혀 없음'], score: [5, 4, 3, 2, 1] },
      { key: 'q9', type: 'single', label: '일학습병행 훈련과정을 통해 향상된 실무능력이 현장 업무 수행에 도움이 된다고 생각하십니까?',
        options: ['매우 도움이 된다', '어느 정도 도움이 된다', '보통이다', '도움이 되지 않는다', '전혀 도움이 되지 않는다'], score: [5, 4, 3, 2, 1] },
      { key: 'q10', type: 'single', label: '사업장에서 산업안전 강화를 위해 자체 위험성 평가를 정기적으로 실시하고 있습니까?',
        options: ['정기적으로 실시하고 있다', '필요 시 수시로 실시하고 있다', '일부 부서·공정에 한해 실시하고 있다', '실시하고 있지 않다', '잘 모르겠다', '해당없음'] },
      { key: 'q11', type: 'single', label: '사업장 내 보호장구(안전모, 보호안경, 안전화 등)가 작업 환경에 맞게 충분히 구비되어 있습니까?',
        options: ['매우 그렇다', '그렇다', '보통이다', '그렇지 않다', '전혀 그렇지 않다', '해당없음'], score: [5, 4, 3, 2, 1, null] },
      { key: 'q12', type: 'single', overall: true, label: '명지대 일학습병행운영팀 전반에 대한 만족도는 어떠신가요?',
        options: ['매우 만족', '만족', '보통', '불만족', '매우 불만족'], score: [5, 4, 3, 2, 1] },
      { key: 'q13', type: 'single', label: '(해당 기업만 응답) 타 대학과 비교했을 때 만족도는 어떠신가요?',
        options: ['매우 만족', '만족', '보통', '불만족', '매우 불만족', '해당 없음'], score: [5, 4, 3, 2, 1, null] },
    ],
    commentLabel: '명지대학교 일학습병행운영팀에 바라는 점이나 건의사항이 있다면 자유롭게 작성해주세요!',
  },
  hrd: {
    title: 'HRD담당자 만족도 조사',
    questions: [
      { key: 'q2', type: 'multi', etc: true, label: 'HRD 업무를 수행하시면서 가장 어려움을 느끼시는 부분은 무엇인가요?',
        options: ['수당 신청 및 행정 처리', '학습일지 및 학습활동서 관리', 'OJT 훈련비 신청', '학습근로자 관리', '각종 변경 절차(담당자·장소 등)', '별다른 어려움이 없다'] },
      { key: 'q3', type: 'multi', etc: true, label: 'HRD 업무 수행 시 어떤 행정지원이 가장 필요하다고 생각하시나요?',
        options: ['일학습병행 연간 일정 사전 안내', 'HRD담당자 역할 및 업무 가이드 제공', '전담자 교육 일정 안내', '훈련과정 개발 방법 안내', '행정 처리 절차 매뉴얼 제공'] },
      { key: 'q4', type: 'single', label: '일학습병행 외부평가 국가자격증에 대해 알고 계신가요?',
        options: ['잘 알고 있다', '어느 정도 알고 있다', '들어본 적은 있으나 잘 모른다', '전혀 모른다'] },
      { key: 'q5', type: 'single', label: '귀사에서 훈련 중인 학습근로자가 일학습병행 외부평가 국가자격증을 취득할 경우, 일반 기사자격증과 동일한 효력의 경력으로 인정할 의향이 있으십니까? (L2·L3: 산업기사 수준 / L4·L5: 기사 수준)',
        options: ['동일한 수준으로 인정하고 있거나, 인정할 계획이다', '일부 조건 충족 시 인정할 예정이다', '검토 예정이다', '인정하지 않는다', '잘 모르겠다'] },
      { key: 'q6', type: 'single', etc: true, label: '외부평가 합격 시 지급되는 지원금(240만원)의 활용 방식에 대해 선택해주세요.',
        options: ['학습근로자에게 전액 지급', '학습근로자에게 일부 지급', '기업 훈련 운영비로 활용', '추후 내부 기준 마련 후 결정'] },
      { key: 'q7', type: 'single', label: 'OJT 훈련기간 중 학습근로자가 정규직으로 전환된 경우, 해당 OJT 훈련기간을 경력으로 인정할 계획이 있으십니까?',
        options: ['인정하고 있다', '일부 인정하고 있다', '인정이 어렵다', '전혀 인정하지 않는다'] },
      { key: 'q8', type: 'multi', etc: true, label: '일반 채용자와 비교하여, 일학습병행 이수자에게 제공되는 인사상 우대 또는 혜택에는 어떤 것이 있습니까?',
        options: ['경력 인정', '채용 시 우대', '인사평가(고과) 우대', '자격수당 지급', '승진·보직 부여 우대', '별도의 우대 또는 혜택 없음'] },
      { key: 'q9', type: 'single', label: '학생들을 위한 휴게공간이 적절히 마련되어 있으며, 충분한 휴식을 취할 수 있는 환경이 조성되어 있습니까?',
        options: ['매우 그렇다', '그렇다', '보통이다', '그렇지 않다', '전혀 그렇지 않다'], score: [5, 4, 3, 2, 1] },
      { key: 'q10', type: 'single', etc: true, label: '명지대 일학습병행운영팀으로부터 어떤 방식의 지원을 가장 원하시나요?',
        options: ['자료 제공', '전담자 방문 교육 및 안내', '관련 교육 강좌 수강 안내'] },
      { key: 'q11', type: 'single', label: '명지대 일학습병행운영팀과의 소통은 얼마나 원활했다고 느끼시나요?',
        options: ['매우 원활', '원활', '보통', '다소 어려움', '매우 어려움'], score: [5, 4, 3, 2, 1] },
      { key: 'q12', type: 'multi', etc: true, label: '소통 과정에서 불편했던 점은 무엇인가요?',
        options: ['응답이 늦음', '담당자 변경이 잦음', '안내 부족', '자료 부족', '없음'] },
      { key: 'q13', type: 'single', label: '향후 일학습병행 사업에 참여하실 의향이 있으신가요?',
        options: ['매우 있음', '있음', '보통', '없음', '전혀 없음'], score: [5, 4, 3, 2, 1] },
      { key: 'q14', type: 'single', overall: true, label: '명지대 일학습병행운영팀 전반에 대한 만족도는 어떠신가요?',
        options: ['매우 만족', '만족', '보통', '불만족', '매우 불만족'], score: [5, 4, 3, 2, 1] },
      { key: 'q15', type: 'single', label: '(해당 기업만 응답) 타 대학과 비교했을 때 만족도는 어떠신가요?',
        options: ['매우 만족', '만족', '보통', '불만족', '매우 불만족', '해당 없음'], score: [5, 4, 3, 2, 1, null] },
    ],
    commentLabel: '명지대학교 일학습병행운영팀에 바라는 점이나 건의사항이 있다면 자유롭게 작성해주세요!',
  },
};

/* ── 9) 학습기업 진행단계 (트래커) ─ 관리자 '기업' 탭과 기업담당자 홈 카드가 공유 ── */
window.COMPANY_STAGES = [
  { key: 'apply',     label: '참여신청' },
  { key: 'audit',     label: '공단 현장실사' },
  { key: 'designate', label: '학습기업 지정완료' },
  { key: 'training',  label: '전담인력 양성교육' },
  { key: 'mou',       label: 'MOU 협약' },
  { key: 'recruit',   label: '학생 모집 개시' },
  { key: 'matched',   label: '학생 매칭' },
  { key: 'running',   label: '훈련 운영 중' },
];
