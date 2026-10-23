/* =====================================================================
 *  app.js  —  여러 페이지가 함께 쓰는 공용 도우미 (보통 고칠 일 없음)
 *  ES 모듈입니다. 각 HTML에서 <script type="module"> 로 불러 씁니다.
 * ===================================================================== */
import { createClient } from 'https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2/+esm';

const cfg = window.APP_CONFIG || {};
const CENTER_REQUIRED = 'CENTER_REQUIRED';

// Supabase 클라이언트 (config.js 값이 비어 있으면 null)
export const supabase =
  (cfg.SUPABASE_URL && cfg.SUPABASE_URL.startsWith('http'))
    ? createClient(cfg.SUPABASE_URL, cfg.SUPABASE_ANON_KEY, {
        global: { headers: { 'x-ilhak-center': (window.CENTER_SLUG || window.DEFAULT_CENTER || 'mju') } },
      })
    : null;

export function configReady() {
  return !!supabase;
}

// URL 쿼리 파라미터 읽기 (예: ?src=2026spring)
export function getQueryParam(name) {
  return new URLSearchParams(location.search).get(name) || '';
}

// [P1] 활성 센터 슬러그 — config.js 의 부트스트랩이 정함(?center > localStorage > 기본 mju).
// ⚠️ 표시·컨텍스트용일 뿐 권한 근거가 아니다. 데이터 귀속은 서버(초대코드 RPC)가 정한다.
export function getCenter() {
  return (window.CENTER_SLUG || window.DEFAULT_CENTER || 'mju');
}
// 같은 센터 컨텍스트를 유지하는 내부 링크 헬퍼(공유용 URL 등 첫 진입에 센터를 실어줄 때).
// 페이지 내 이동은 localStorage 로 이미 유지되므로 일반 <a> 에는 불필요.
export function centerUrl(path) {
  try {
    const u = new URL(path, location.href);
    u.searchParams.set('center', getCenter());
    return (u.pathname.split('/').pop() || 'index.html') + u.search;
  } catch (_) { return path; }
}

// [P3] 활성 센터의 uuid — `center_id_for_slug` RPC(sql/19)로 1회 해석 후 캐시.
// 공개 읽기는 requireCenterId()를 써서 fail-closed로 처리한다. getCenterId()는 복구/폴백 UI용.
let _centerIdCache;   // undefined=미해석(재시도 가능), string=해석 성공(영구 캐시)
let _centerNetFail = false;   // (10/23 점검) 마지막 해석 실패가 연결 문제였는지 — '센터 링크가 잘못'과 구분
export function centerLookupNetFailed() { return _centerNetFail; }
export async function getCenterId() {
  if (_centerIdCache !== undefined) return _centerIdCache;
  // 성공했을 때만 캐시한다. 일시 오류·미초기화로 null 을 캐시하면(_centerIdCache 가 undefined 가 아니게 되면)
  // 페이지 생애 내내 스코프가 꺼져버리므로(공개읽기 미필터·push_tokens.center_id=null) 실패 시엔 캐시하지 않는다.
  _centerNetFail = false;
  if (supabase) {
    try {
      const { data, error } = await supabase.rpc('center_id_for_slug', { p_slug: getCenter() });
      if (!error && data) { _centerIdCache = data; return _centerIdCache; }
      if (error) _centerNetFail = true;   // 응답이 오류 = 서버까지 못 감(정상 응답에 data 가 없으면 = 없는 센터)
    } catch (_) { _centerNetFail = true; }
  }
  return null;   // 미해석 → 캐시 안 함(_centerIdCache 는 undefined 유지) → 다음 호출에서 재시도
}
export async function requireCenterId() {
  const cid = await getCenterId();
  if (cid) return cid;
  const err = new Error('center_required');
  err.code = CENTER_REQUIRED;
  throw err;
}
export function isCenterRequiredError(error) {
  return !!error && (error.code === CENTER_REQUIRED || /center_required/i.test(error.message || ''));
}
export function centerRequiredMessage() {
  return '센터 정보를 확인할 수 없어요. 올바른 센터 링크로 다시 접속해주세요.';
}

// [②b] 센터별 어휘(vocab) 적용 — 담당·유형·단계·설문을 센터 DB값으로 override.
//   (직무·학습기업은 vocab 이 아니라 jobs/companies 마스터 테이블이 원장 — 각 탭이 직접 조회.)
//   vocab 컬럼이 없거나 값이 비어 있으면 조용히 스킵하며, 호출부는 빈 선택지로 닫힌다.
//   ⚠️ 드롭다운(가입폼·관리자 타게팅)을 만들기 '전에' await 로 호출해야 적용된다. 호출부: index.html·admin.html·privacy.html.
let _vocabPromise;
export function applyCenterVocab() {
  // 프로미스 캐시 — 동시 호출(여러 드롭다운 IIFE)이 같은 fetch 를 공유하고 모두 적용 완료까지 대기한다.
  if (_vocabPromise) return _vocabPromise;
  _vocabPromise = (async () => {
    if (!supabase) return;
    try {
      const { data: v } = await supabase.from('centers').select('vocab').eq('slug', getCenter()).maybeSingle();
      if (v && v.vocab) {
        ['TYPES', 'TYPE2', 'MANAGERS', 'STATUSES', 'COMPANY_STAGES', 'COMPANY_SURVEYS'].forEach(k => {
          const val = v.vocab[k.toLowerCase()];
          if (val != null) window[k] = val;
        });
      }
    } catch (_) { /* vocab 컬럼 미적용 → 스킵 */ }
  })();
  return _vocabPromise;
}

// [P3/P4] 활성 센터의 설정을 DB(centers)에서 로드 → APP_CONFIG 키 형태로 반환.
// centers 테이블/행이 없거나 오류면 null. 호출부는 센터 설정을 표시하지 않는다.
export async function loadCenterConfig() {
  if (!supabase) return null;
  await applyCenterVocab();   // vocab override(직무·유형 등) — privacy.html 외 페이지는 직접 applyCenterVocab() 호출
  try {
    const { data, error } = await supabase.from('centers')
      .select('name,app_title,privacy_officer,privacy_officer_contact,privacy_effective_date,privacy_retention,privacy_retention_applicant,privacy_transfer')
      .eq('slug', getCenter()).maybeSingle();
    if (error || !data) return null;
    return {
      CENTER_NAME: data.name, APP_TITLE: data.app_title,
      PRIVACY_OFFICER: data.privacy_officer, PRIVACY_OFFICER_CONTACT: data.privacy_officer_contact,
      PRIVACY_EFFECTIVE_DATE: data.privacy_effective_date, PRIVACY_RETENTION: data.privacy_retention,
      PRIVACY_RETENTION_APPLICANT: data.privacy_retention_applicant, PRIVACY_TRANSFER: data.privacy_transfer,
    };
  } catch (_) { return null; }
}

// 홈 화면에 추가(설치)된 상태로 실행 중인가?
export function isStandalone() {
  return window.matchMedia('(display-mode: standalone)').matches
      || window.navigator.standalone === true; // iOS
}

// 플랫폼 판별
export function getPlatform() {
  const ua = navigator.userAgent || '';
  if (/iPad|iPhone|iPod/.test(ua) || (navigator.platform === 'MacIntel' && navigator.maxTouchPoints > 1)) return 'ios';
  if (/Android/.test(ua)) return 'android';
  return 'other';
}

// 카카오톡/인스타 등 "인앱 브라우저" 감지 (여기서는 푸시·홈화면추가가 막힘)
export function isInAppBrowser() {
  const ua = (navigator.userAgent || '').toLowerCase();
  return /kakaotalk|instagram|fban|fbav|naver|line\/|daumapps|everytimeapp|band/.test(ua);
}

// 학과 라벨 찾기
export function deptLabel(key) {
  const d = (window.DEPARTMENTS || []).find(x => x.key === key);
  return d ? d.label : key;
}

// 간단한 토스트/상태 메시지
export function setStatus(el, msg, type = 'info') {
  if (!el) return;
  el.textContent = msg;
  el.className = 'status ' + type; // info / ok / error
}

// HTML 이스케이프 (각 페이지에 흩어져 있던 esc()의 공용 버전)
export function esc(s) {
  const e = document.createElement('div'); e.textContent = s || ''; return e.innerHTML;
}

// 이 기기의 가입 프로필 (없으면 {})
export function getProfile() {
  try { return JSON.parse(localStorage.getItem('ilhak_profile') || '{}') || {}; } catch (_) { return {}; }
}

// 회사명 표기차이 흡수 — 공지/자료/일정 타게팅 매칭 공용
export const normCo = (s) => (s || '').replace(/㈜|\(주\)|주식회사|\s/g, '');
// withManagers: 담당자 세그먼트 매칭은 공지에서만 사용(자료/일정의 기존 동작 보존)
export function matchSel(sel, profile, withManagers = false) {
  if (!sel) return false;
  // (10/22) aud = 받는 쪽(관리자 학생/기업 탭) — 다른 쪽이면 안 보임, 다른 조건이 없으면 그 쪽 전체
  if (sel.aud) {
    if ((profile.target_type || 'student') !== sel.aud) return false;
    const some = k => Array.isArray(sel[k]) && sel[k].length > 0;
    if (!['targets', 'jobs', 'companies', 'types', 'managers'].some(some)) return true;
  }
  if (sel.targets && sel.targets.includes(profile.target_type)) return true;
  if (sel.jobs && profile.job_key && sel.jobs.includes(profile.job_key)) return true;
  // 지원자: 단일 job_key 대신 관심직무 배열과 교집합
  if (sel.jobs && Array.isArray(profile.interest_jobs) && profile.interest_jobs.some(j => sel.jobs.includes(j))) return true;
  if (sel.companies && profile.company && sel.companies.map(normCo).includes(normCo(profile.company))) return true;
  if (sel.types && profile.type1 && sel.types.includes(profile.type1)) return true;
  if (withManagers && sel.managers && sel.managers.length && profile.manager && sel.managers.includes(profile.manager.trim())) return true;
  return false;
}
// 공지(notices) 행이 이 기기에 보여야 하는가 — notice.html과 배지 카운트가 같은 규칙을 공유
export function noticeMatches(n, profile) {
  switch (n.target_scope) {
    case 'all':     return true;
    case 'job':     return profile.job_key === n.target_value;
    case 'company': return normCo(profile.company) === normCo(n.target_value);
    case 'target':  return profile.target_type === n.target_value;
    case 'type':    return profile.type1 === n.target_value;
    case 'custom':  { try { return matchSel(JSON.parse(n.target_value || '{}'), profile, true); } catch (_) { return false; } }
    default:        return false;
  }
}

// 휴대폰 입력 자동 하이픈 (010-1234-5678) — 중간 편집 시에도 커서 위치 보존
export function attachPhoneFormat(el) {
  if (!el) return;
  el.addEventListener('input', () => {
    const before = el.value;
    const pos = el.selectionStart == null ? before.length : el.selectionStart;
    const digitsBeforeCaret = before.slice(0, pos).replace(/\D/g, '').length;
    const d = before.replace(/\D/g, '').slice(0, 11);
    let v = d;
    if (d.length > 7)      v = d.slice(0, 3) + '-' + d.slice(3, 7) + '-' + d.slice(7);
    else if (d.length > 3) v = d.slice(0, 3) + '-' + d.slice(3);
    if (before === v) return;
    el.value = v;
    // 커서 복원: 재포맷 전 커서 앞에 있던 '숫자 개수'가 같아지는 지점으로
    let np = 0, cnt = 0;
    while (np < v.length && cnt < digitsBeforeCaret) { if (/\d/.test(v[np])) cnt++; np++; }
    try { el.setSelectionRange(np, np); } catch (_) {}
  });
}

// 목록 로딩 스켈레톤 — 데이터 도착 전 자리표시
export function skeletonList(el, n = 3) {
  if (!el) return;
  el.setAttribute('aria-busy', 'true');
  el.innerHTML = Array.from({ length: n }, () =>
    '<div class="skel-card" style="margin-bottom:14px"><div class="skel skel-line w40"></div>' +
    '<div class="skel skel-line w80"></div><div class="skel skel-line w60"></div></div>').join('');
}
export function clearSkeleton(el) {
  if (!el) return;
  el.removeAttribute('aria-busy');
  el.innerHTML = '';
}

/* ── 공지 읽음 추적 (배지는 이 기기 localStorage, 관리자 집계용 기록은 서버 sql/57) ── */
const READ_KEY = 'ilhak_read_notices';
export function getReadSet() {
  try { return new Set(JSON.parse(localStorage.getItem(READ_KEY) || '[]')); } catch (_) { return new Set(); }
}
export function markNoticesRead(ids) {
  try {
    const s = getReadSet();
    ids.forEach(id => s.add(id));
    localStorage.setItem(READ_KEY, JSON.stringify([...s].slice(-800))); // 무한 증식 방지
  } catch (_) {}
}
// 서버에도 읽음 기록(sql/57 mark_notices_read) — 관리자 '읽음 n / 대상 n' 집계용.
// 본인 확인은 코드 또는 서명토큰(my_attendance 와 같은 방식). RPC 미적용·실패여도 화면은 그대로(응답 안 기다림).
export function recordNoticesRead(ids) {
  const p = getProfile();
  if (!supabase || !ids.length || !(p.code || p.token)) return;
  try {
    supabase.rpc('mark_notices_read', { p_ids: ids.slice(0, 200), p_code: p.code || null, p_token: p.token || null })
      .then(() => {}, () => {});
  } catch (_) {}
}
// 내 대상 공지 중 아직 안 읽은 개수 (최근 100건 기준)
export async function unreadNoticeCount() {
  if (!supabase) return 0;
  const profile = getProfile();
  if (!profile.name) return 0;
  try {
    const read = getReadSet();
    // [P3.5] read-model 우선: public_notices 가 타게팅을 끝낸 목록을 돌려준다(클라 필터 불필요).
    const profSel = { job_key: profile.job_key, company: profile.company, type1: profile.type1,
                      target_type: profile.target_type, interest_jobs: profile.interest_jobs, manager: profile.manager };
    try {
      const { data: rows, error } = await supabase.rpc('public_notices', { p_profile: profSel });
      if (!error && Array.isArray(rows)) return rows.slice(0, 100).filter(n => !read.has(n.id)).length;
    } catch (_) { /* RPC 부재 → 폴백 */ }
    // 폴백: 직조회 + 클라 타게팅 (sql/37 적용 전 동작 보존)
    const cid = await requireCenterId();                     // 센터 해석 실패 시 공개 쿼리 중단
    const q = supabase.from('notices').select('id,target_scope,target_value').eq('published', true).eq('center_id', cid);
    const { data, error } = await q.order('created_at', { ascending: false }).limit(100);
    if (error || !data) return 0;
    return data.filter(n => noticeMatches(n, profile) && !read.has(n.id)).length;
  } catch (_) { return 0; }
}
// 앱 아이콘 배지(홈 화면 숫자) — 푸시 수신 시 SW가 +1, 앱을 열면 실제 안읽음 수로 동기화
// (iOS 16.4+ 설치된 PWA·안드로이드 크롬 지원. 미지원 환경에선 조용히 무시)
function setIconBadge(n) {
  try { if (n) navigator.setAppBadge?.(n); else navigator.clearAppBadge?.(); } catch (_) {}
  try {  // SW 증가 카운터의 기준값도 맞춰둠 (firebase-messaging-sw.js와 공유하는 IndexedDB)
    const open = indexedDB.open('ilhak-badge', 1);
    open.onupgradeneeded = () => { open.result.createObjectStore('kv'); };
    open.onsuccess = () => { try { open.result.transaction('kv', 'readwrite').objectStore('kv').put(n, 'n'); } catch (_) {} };
  } catch (_) {}
}
// 탭바 '공지' 탭과 홈 '공지사항' 타일에 미확인 배지 표시
export async function updateUnreadBadges() {
  const cnt = await unreadNoticeCount();
  setIconBadge(cnt);
  document.querySelectorAll('[data-unread-badge]').forEach(el => { el.remove(); });
  if (!cnt) return;
  const label = cnt > 99 ? '99+' : String(cnt);
  const tab = document.querySelector('.tabbar a[href="./notice.html"]');
  if (tab) {
    const b = document.createElement('span');
    b.className = 'count-badge'; b.dataset.unreadBadge = '1'; b.textContent = label;
    b.setAttribute('aria-label', `안 읽은 공지 ${cnt}건`);
    tab.appendChild(b);
  }
  const tile = document.querySelector('.menu-tile[href="./notice.html"]');
  if (tile) {
    const b = document.createElement('span');
    b.className = 'count-badge mbadge'; b.dataset.unreadBadge = '1'; b.textContent = label;
    b.setAttribute('aria-label', `안 읽은 공지 ${cnt}건`);
    tile.appendChild(b);
  }
}

// Supabase/네트워크 오류를 사용자 언어로 변환 (영문 원문은 콘솔로만)
export function friendlyError(error) {
  const m = (error && (error.message || error.msg)) || String(error || '');
  try { console.error(error); } catch (_) {}
  if (isCenterRequiredError(error)) return centerRequiredMessage();
  if (/Failed to fetch|NetworkError|network|timeout|타임아웃/i.test(m)) return '인터넷 연결을 확인한 뒤 다시 시도해주세요.';
  if (/JWT|expired|로그인|session|invalid token/i.test(m)) return '로그인이 만료됐어요. 다시 로그인해주세요.';
  if (/row-level security|permission denied|42501/i.test(m)) return '일시적인 문제가 있어요. 잠시 후 다시 시도하거나 담당자에게 문의해주세요.';
  if (/duplicate|23505|already exists/i.test(m)) return '이미 처리된 내용이에요.';
  return '문제가 발생했어요. 잠시 후 다시 시도해주세요.';
}

// PWA 서비스워커 등록 (홈 화면 추가 시 앱처럼 동작)
// sw.js 는 캐시와 푸시 수신을 겸한다 — 다른 스크립트를 같은 scope 에 등록하면 서로를 밀어낸다(sw.js 상단 주석).
if ('serviceWorker' in navigator) {
  window.addEventListener('load', () => {
    navigator.serviceWorker.register('./sw.js').catch(() => {});
  });
  // 새 sw 가 옛 sw 를 밀어내면(배포) 지금 화면은 옛 파일로 그려진 것 → 한 번만 새로고침해 바로 새 화면으로.
  // 처음 설치(이전 sw 없음)에는 하지 않음. 무한 새로고침 방지는 '30초 안에 또 하지 않기'로
  // (세션당 1회로 막았더니 같은 탭에서 두 번째 배포부터는 새로고침이 안 됐음 — 10/16).
  // 열어 둔 채 다른 앱으로 갔다가 돌아오면(설치 앱은 거의 이렇게 씀) 새 배포가 있는지 확인 → 있으면 아래 controllerchange 로 새로고침
  document.addEventListener('visibilitychange', () => {
    if (document.visibilityState === 'visible') navigator.serviceWorker.getRegistration().then(r => r && r.update()).catch(() => {});
  });
  const hadController = !!navigator.serviceWorker.controller;
  navigator.serviceWorker.addEventListener('controllerchange', () => {
    if (!hadController) return;
    try {
      const last = Number(sessionStorage.getItem('sw-reloaded-at')) || 0;
      if (Date.now() - last < 30000) return;
      sessionStorage.setItem('sw-reloaded-at', String(Date.now()));
    } catch (_) { return; }
    // (10/23 점검) 쓰던 글·고른 답이 있으면 바로 새로고침하지 않고 '누르면 적용' 알림만 — 대화·설문 작성 중 내용이 날아가던 문제
    const dirty = [...document.querySelectorAll('textarea, input:not([type]), input[type=text], input[type=tel], input[type=email]')]
      .some(el => !el.readOnly && !el.disabled && el.offsetParent !== null && el.value.trim() !== '' && el.value !== el.defaultValue)
      || document.querySelector('form input[type=radio]:checked, form input[type=checkbox]:checked, .survey input:checked');
    if (!dirty) { location.reload(); return; }
    if (document.getElementById('sw-update-toast')) return;
    const b = document.createElement('button');
    b.type = 'button'; b.id = 'sw-update-toast'; b.textContent = '새 버전이 있어요 · 다 쓴 뒤 눌러서 적용';
    b.style.cssText = 'position:fixed;left:50%;bottom:calc(16px + env(safe-area-inset-bottom));transform:translateX(-50%);z-index:9999;max-width:calc(100% - 32px);padding:10px 16px;border:0;border-radius:999px;background:#121318;color:#fff;font:inherit;font-size:14px;box-shadow:0 4px 16px rgba(0,0,0,.2);cursor:pointer';
    b.addEventListener('click', () => location.reload());
    document.body.appendChild(b);
  });
}

// 알림을 이미 켠 기기에서 앱을 열 때 도는 정비 루틴 — 두 가지를 한다.
//  ① 포그라운드 수신: 앱이 화면에 떠 있으면 FCM SDK 는 배너 대신 페이지로 넘긴다.
//     받는 쪽이 없으면 알림이 통째로 사라지므로 인앱 토스트로 보여준다.
//  ② 구독 자가복구: 서비스워커가 알림을 못 띄우던 기간에 iOS(WebKit)가 푸시 구독을
//     조용히 회수해버린 기기가 있다. 이 경우 서버엔 토큰 행이 남아 FCM 은 계속 성공을
//     반환하지만 실제로는 갈 곳이 없다. 학생에게 "알림 다시 켜세요"를 요구하는 대신,
//     앱을 여는 것만으로 새 구독을 만들어 서버 토큰을 갱신한다(하루 1회로 제한).
if ('Notification' in window && Notification.permission === 'granted' && window.FIREBASE_CONFIG) {
  (async () => {
    try {
      const { initializeApp, getApps } = await import('https://www.gstatic.com/firebasejs/10.12.0/firebase-app.js');
      const { getMessaging, getToken, onMessage, isSupported } = await import('https://www.gstatic.com/firebasejs/10.12.0/firebase-messaging.js');
      if (!(await isSupported())) return;
      const fbApp = getApps().length ? getApps()[0] : initializeApp(window.FIREBASE_CONFIG);  // install.html 과 중복 초기화 방지
      const messaging = getMessaging(fbApp);

      onMessage(messaging, (payload) => {
        const n = payload.notification || {};
        showPushToast(n.title || '새 공지', n.body || '', payload.data && payload.data.link);
        updateUnreadBadges();
      });

      const prof = getProfile();
      if (!prof || !prof.name || !window.FCM_VAPID_KEY) return;
      const last = Number(localStorage.getItem('ilhak_push_refresh') || 0);
      if (Date.now() - last < 86400000) return;          // 하루 1회 — 앱 열 때마다 FCM 을 두드리지 않게

      const swReg = await navigator.serviceWorker.register('./sw.js');
      const token = await getToken(messaging, { vapidKey: window.FCM_VAPID_KEY, serviceWorkerRegistration: swReg });
      if (!token) return;
      await supabase.rpc('register_push_token', {          // token 기준 upsert — 반복 호출 안전
        p_slug: getCenter(), p_code: prof.code || null,
        p_row: {
          token, target_type: prof.target_type || null, job_key: prof.job_key || null,
          company: prof.company || null, type1: prof.type1 || null,
          manager: prof.manager || null, device_key: prof.token || null,
          platform: getPlatform(), updated_at: new Date().toISOString(),
        },
      });
      localStorage.setItem('ilhak_push_refresh', String(Date.now()));
    } catch (_) { /* SDK 로드·구독 실패 시 조용히 무시 — 백그라운드 배너는 sw.js 가 처리 */ }
  })();
}

function showPushToast(title, body, link) {
  try {
    document.querySelector('[data-push-toast]')?.remove();
    const el = document.createElement('div');
    el.dataset.pushToast = '1';
    el.setAttribute('role', 'status');
    el.style.cssText = 'position:fixed;left:12px;right:12px;bottom:calc(72px + env(safe-area-inset-bottom));z-index:9999;'
      + 'background:#002968;color:#fff;border-radius:14px;padding:12px 14px;box-shadow:0 8px 24px rgba(0,0,0,.28);'
      + 'font-size:14px;line-height:1.45;cursor:pointer';
    const t = document.createElement('div'); t.style.cssText = 'font-weight:800;margin-bottom:2px'; t.textContent = title;
    const b = document.createElement('div'); b.style.cssText = 'opacity:.9'; b.textContent = body;
    el.append(t, b);   // textContent — 공지 본문이 마크업으로 해석되지 않게
    // 대화방 알림은 data.link = chat.html?room=<id>(push-sender). 같은 오리진 주소만 따라감
    let to = './notice.html';
    try { const u = new URL(link || '', location.href); if (link && u.origin === location.origin) to = u.href; } catch (_) {}
    el.addEventListener('click', () => { location.href = to; });
    document.body.appendChild(el);
    setTimeout(() => el.remove(), 6000);
  } catch (_) {}
}

// 하단 탭 네비게이션 — .ph-body 가 있는 학생 페이지에만 주입(관리자 콘솔 등은 제외)
(function injectTabbar() {
  try {
    if (!document.querySelector('.ph-body, [data-tabbar]')) return;
    if (document.querySelector('.tabbar')) return;
    let page = location.pathname.split('/').pop() || 'index.html';
    if (page === 'company.html') page = 'index.html';   // 기업 담당자 첫 화면 = 우리 학생 OJT(10/22)
    // (학생 전용 전환) 지원자·모집 탭 폐지 — 가입된 학생 기기에만 운영 탭 표시
    const prof = getProfile();
    if (!prof.name || prof.target_type === 'applicant') return;
    const items = [
      ['index.html', 'home', '홈'],
      ['notice.html', 'megaphone', '공지'],
      ['library.html', 'folder', '자료'],
      // (10/16) '일정' 탭 폐지 — 홈 달력으로 합침(calendar.html 은 홈으로 넘김)
      // (10/22 사용자) '상담' 탭 뺌 — 학생·기업 모두. 1:1 상담은 학생 홈 메뉴 타일로
    ];
    const nav = document.createElement('nav');
    nav.className = 'tabbar';
    nav.setAttribute('aria-label', '주요 메뉴');
    nav.innerHTML = items.map(([href, ic, label]) =>
      `<a href="./${href}"${page === href ? ' class="on" aria-current="page"' : ''}><i data-lucide="${ic}"></i>${label}</a>`).join('');
    document.body.appendChild(nav);
    document.body.classList.add('has-tabbar');
    if (window.lucide && window.lucide.createIcons) window.lucide.createIcons();
    // 가입된 기기면 '공지' 탭에 미확인 배지 (공지 페이지 자신은 읽음 처리 후 직접 갱신)
    if (page !== 'notice.html') updateUnreadBadges();
  } catch (_) {}
})();

// 헤더 워드마크 락업 — 전 학생 페이지의 .ph-lockup 을 KDP 워드마크로 통일(한 곳에서 일괄).
//   KOREA DUAL PROGRAM 마크(GO) + 「일학습병행 / KOREA DUAL PROGRAM」 워드마크 + 센터명 chip.
//   다크모드는 토큰으로 자동 대응. index.html 이 import 직후 #t-center 에 쓰므로 충돌 피하려 DOMContentLoaded 에 실행.
const KDP_MARK_SVG = '<svg width="24" height="22" viewBox="0 0 58 54" aria-hidden="true" style="display:block">'
  + '<g fill="#1078C4">'
  + '<rect x="42.5" y="12.4" width="5" height="5.4" rx="1" transform="rotate(0 42.5 27)"/>'
  + '<rect x="42.5" y="12.4" width="5" height="5.4" rx="1" transform="rotate(45 42.5 27)"/>'
  + '<rect x="42.5" y="12.4" width="5" height="5.4" rx="1" transform="rotate(90 42.5 27)"/>'
  + '<rect x="42.5" y="12.4" width="5" height="5.4" rx="1" transform="rotate(135 42.5 27)"/>'
  + '<rect x="42.5" y="12.4" width="5" height="5.4" rx="1" transform="rotate(180 42.5 27)"/>'
  + '<rect x="42.5" y="12.4" width="5" height="5.4" rx="1" transform="rotate(225 42.5 27)"/>'
  + '<rect x="42.5" y="12.4" width="5" height="5.4" rx="1" transform="rotate(270 42.5 27)"/>'
  + '<rect x="42.5" y="12.4" width="5" height="5.4" rx="1" transform="rotate(315 42.5 27)"/>'
  + '<circle cx="42.5" cy="27" r="11.2"/></g>'
  + '<circle cx="42.5" cy="27" r="5.4" fill="#fff"/>'
  + '<path d="M40.2 29.3 L44.8 24.7" stroke="#1078C4" stroke-width="1.7" stroke-linecap="round"/>'
  + '<circle cx="44.9" cy="24.6" r="1.3" fill="#1078C4"/>'
  + '<path d="M38.16 37.29 A 17.5 17.5 0 1 1 38.16 16.71" fill="none" stroke="#EF7D00" stroke-width="7" stroke-linecap="round"/>'
  + '<rect x="30.5" y="33.4" width="7.5" height="6.6" rx="2" fill="#EF7D00"/>'
  + '<path d="M17.5 25 Q17.5 31 24 31 Q30.5 31 30.5 25 Z" fill="#EF7D00"/>'
  + '<polygon points="24,17 39.5,24 24,30 8.5,24" fill="#EF7D00"/>'
  + '<rect x="23.4" y="15.4" width="1.2" height="3.2" fill="#EF7D00"/>'
  + '<circle cx="24" cy="15.2" r="1.7" fill="#EF7D00"/>'
  + '<path d="M12 24 L12 31.4" stroke="#EF7D00" stroke-width="1.6" stroke-linecap="round"/>'
  + '<rect x="10.5" y="31" width="3" height="4" rx="1" fill="#EF7D00"/></svg>';
function renderHeaderLockup() {
  try {
    const cc = (window.APP_CONFIG || {});
    const center = cc.CENTER_SHORT || cc.CENTER_NAME || '';   // chip은 짧은 식별명(기관) 우선
    // 명지대 센터는 '일학습병행' 옆에 명지대 나무 로고(틀 없이) — 밝은 머리는 남색, 먹색 머리·다크 모드는 흰색(CSS 가 골라 보임).
    // 다른 센터는 KDP 마크.
    const mark = getCenter() === 'mju'
      ? '<img class="mju-mark mm-l" src="./assets/mju-tree.png" alt="명지대학교" width="27" height="28" />'
        + '<img class="mju-mark mm-d" src="./assets/mju-tree-white.png" alt="" width="27" height="28" />'
      : KDP_MARK_SVG;
    document.querySelectorAll('.ph-lockup').forEach(el => {
      el.innerHTML = '<span class="kdp-mark">' + mark + '</span>'
        + '<span class="kdp-word"><b>일학습병행</b><small>KOREA DUAL PROGRAM</small></span>'
        + (center ? '<span class="ph-center-chip">' + esc(center) + '</span>' : '');
    });
  } catch (_) {}
}
// 각 페이지 인라인 스크립트(index 의 #t-center 설정 등)가 끝난 뒤 실행되도록 매크로태스크로 지연 → 충돌 없이 항상 적용.
setTimeout(renderHeaderLockup, 0);

// 접근성 — 상태 메시지를 스크린리더가 자동 낭독하도록
(function a11yStatus() {
  try {
    document.querySelectorAll('.status').forEach(el => {
      if (!el.hasAttribute('role')) { el.setAttribute('role', 'status'); el.setAttribute('aria-live', 'polite'); }
    });
  } catch (_) {}
})();
