/* sw.js — PWA 서비스워커 (캐시 + FCM 푸시 수신 통합)
 *
 * ⚠️ 통합 이유 (2026-08-21) — 건드리기 전에 반드시 읽을 것
 *   app.js 는 모든 페이지에서 './sw.js' 를, install.html 은 './firebase-messaging-sw.js' 를
 *   등록했는데 **둘 다 scope 가 /mju/ 로 같다**. 같은 scope 에는 등록이 하나만 존재하므로
 *   나중 등록이 앞 등록을 밀어낸다. install.html 이 app.js 를 import 하는 탓에 sw.js 가
 *   먼저 활성화되고, 뒤이어 등록된 FCM SW 는 skipWaiting 이 없어 waiting 에 갇힌다.
 *   push 이벤트는 active 워커로만 가는데 그게 push 핸들러 없는 sw.js 였고, 그래서
 *   FCM 이 success 를 반환해도 기기에 배너가 뜨지 않았다.
 *   (정확히는 "한 번도 안 떴다"가 아니다 — 학생이 알림을 켠 뒤 앱을 완전히 닫아
 *    controlled client 가 0 이 되면 waiting 이던 FCM SW 가 active 로 승격돼 그 구간엔
 *    배너가 떴다. 다음 실행 때 app.js 가 sw.js 를 재등록하면 skipWaiting 으로 즉시
 *    되찾아 FCM SW 는 redundant 가 된다. 8/20 은 떴는데 8/21 은 안 뜬 이유가 이것이다.)
 *   → 스코프를 분리하면 PushSubscription 이 새로 생겨 기존 학생 토큰이 전부 무효가 되므로,
 *     같은 scope 를 유지한 채 이 파일 하나에 푸시 수신을 합쳤다. 기존 토큰 그대로 살아있다.
 *   따라서 './firebase-messaging-sw.js' 를 다시 등록하는 코드를 넣지 말 것.
 *
 * 코드를 고친 뒤 반영이 안 되면 CACHE 버전 숫자를 올리세요(브라우저 캐시 갱신). */
const CACHE = 'ilhak-v90';   // 관리자 '화면 보기' 미리보기 모드(sql/88)
const ASSETS = ['./', './index.html', './install.html', './notice.html', './library.html', './calendar.html',
  './consult.html', './chat.html', './survey.html', './company-survey.html', './faq.html', './privacy.html',
  './qna.html', './mycompany.html',
  './company.html', './styles.css', './student.css', './app.js', './config.js', './survey-ui.js', './manifest.json', './assets/logo-mono-white.png', './assets/mju-tree.png', './assets/mju-tree-white.png'];

const APP_URL = './notice.html';

// ── FCM 수신부 ───────────────────────────────────────────────────────────────
// SW 는 config.js 를 못 읽으므로 firebaseConfig 를 직접 적는다(공개값이라 OK).
const FB = {
  apiKey: 'AIzaSyDCQj4zs_ebgM18GKotG1-7n-MVXVdHkqs',
  authDomain: 'mjuipp.firebaseapp.com',
  projectId: 'mjuipp',
  messagingSenderId: '13262157393',
  appId: '1:13262157393:web:45caa766392425a90eaa70'
};

let fcmReady = false;
try {
  importScripts('https://www.gstatic.com/firebasejs/10.12.0/firebase-app-compat.js');
  importScripts('https://www.gstatic.com/firebasejs/10.12.0/firebase-messaging-compat.js');
  firebase.initializeApp(FB);
  const messaging = firebase.messaging();
  // notification 페이로드는 SDK 가 백그라운드에서 자동 표시(클릭 시 fcm_options.link 로 이동).
  // 여기서는 앱 아이콘 배지만 올린다 — 중복 표시 아님.
  messaging.onBackgroundMessage(() => { bumpBadge(); });
  fcmReady = true;
} catch (_) {
  // gstatic 이 막히거나 오프라인이면 SDK 없이도 알림은 떠야 하므로 수동 폴백을 건다.
  fcmReady = false;
}

// SDK 를 못 불러온 경우에만 직접 push/notificationclick 을 처리한다(둘 다 걸면 배너가 2번 뜬다).
if (!fcmReady) {
  self.addEventListener('push', (e) => {
    let n = {}, link = APP_URL;
    try {
      const d = e.data ? e.data.json() : {}; n = d.notification || (d.data && d.data.notification) || {};
      link = (d.fcmOptions && d.fcmOptions.link) || (d.data && d.data.link) || APP_URL;   // 대화방 = chat.html?room=<id>
    } catch (_) {}
    const title = n.title || '일학습병행';
    const body = n.body || '';
    e.waitUntil((async () => {
      await self.registration.showNotification(title, { body, icon: './assets/logo-mono-white.png', data: { link } });
      bumpBadge();
    })());
  });
  self.addEventListener('notificationclick', (e) => {
    e.notification.close();
    const url = new URL((e.notification.data && e.notification.data.link) || APP_URL, self.location.href).href;
    e.waitUntil((async () => {
      const all = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
      for (const c of all) { if (c.url.startsWith(self.registration.scope) && 'focus' in c) { await c.navigate(url); return c.focus(); } }
      if (self.clients.openWindow) return self.clients.openWindow(url);
    })());
  });
}

// 앱 아이콘 배지(홈 화면 숫자) +1 — 앱을 열면 app.js가 실제 안읽음 수로 다시 맞춤
function bumpBadge() {
  try {
    const open = indexedDB.open('ilhak-badge', 1);
    open.onupgradeneeded = () => { open.result.createObjectStore('kv'); };
    open.onsuccess = () => {
      try {
        const tx = open.result.transaction('kv', 'readwrite');
        const st = tx.objectStore('kv');
        const g = st.get('n');
        g.onsuccess = () => {
          const n = (typeof g.result === 'number' ? g.result : 0) + 1;
          st.put(n, 'n');
          if (navigator.setAppBadge) navigator.setAppBadge(n).catch(() => {});
        };
      } catch (_) {}
    };
  } catch (_) {}
}

// ── PWA 캐시부 ───────────────────────────────────────────────────────────────
self.addEventListener('install', (e) => {
  // cache:'reload' — 브라우저 HTTP 캐시(GitHub Pages max-age 600)의 옛 파일을 새 캐시에 담지 않게
  e.waitUntil(caches.open(CACHE).then((c) => c.addAll(ASSETS.map(u => new Request(u, { cache: 'reload' })))).catch(()=>{}));
  self.skipWaiting();
});
self.addEventListener('activate', (e) => {
  e.waitUntil(caches.keys().then((keys) => Promise.all(keys.filter(k => k !== CACHE).map(k => caches.delete(k)))));
  self.clients.claim();
});
self.addEventListener('fetch', (e) => {
  const req = e.request;
  if (req.method !== 'GET') return;
  // 네트워크 우선, 실패 시 캐시 (공지 등 최신 데이터가 중요하므로).
  // 같은 사이트 파일은 cache:'no-cache' 로 매번 서버에 확인(ETag — 안 바뀌었으면 304) —
  // 그냥 fetch 하면 브라우저 HTTP 캐시(최대 10분)의 옛 app.js·styles.css 가 나와 배포가 늦게 보였음(10/16).
  // 페이지 이동(navigate) 요청은 RequestInit 를 붙일 수 없어 주소로 다시 만든다.
  let net;
  if (new URL(req.url).origin !== self.location.origin) net = fetch(req);
  else if (req.mode === 'navigate') net = fetch(req.url, { cache: 'no-cache', credentials: 'same-origin' });
  else net = fetch(req, { cache: 'no-cache' });
  e.respondWith(net.catch(() => caches.match(req)));
});
