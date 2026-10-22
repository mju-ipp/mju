// =====================================================================
// push-sender — 공지 푸시 발송기 (Apps Script 대체, 2026-08-20)
// 미발송 공지(published & !pushed)를 읽어 FCM HTTP v1 로 발송.
//  · personal 스코프: notice_recipients → push_tokens(device_key) 매칭, 수신자별 제목·본문
//  · 그 외: push_tokens 전체에서 타겟 매칭(all/job/company/target/type/custom — custom 의 aud 는 학생/기업 구분, 10/22)
//  · 클릭 시 https://mju-ipp.github.io/mju/notice.html 열림(신규 주소)
//  · 무효 토큰(UNREGISTERED)은 자동 정리, push_logs 기록, pushed=true 는 발송 전에 선점 마킹(중복 발송 방지)
//  · 대화방(2026-10-16, docs/CHAT.md 4단계): 선생님 글(chat_messages push_state='pending')만 발송.
//      받는 기기는 sql/67 chat_push_pending 이 계산 — 기업방 = 그 기업 명단 학생, 1:1 = 그 학생,
//      기기 = push_tokens.device_key = 학생 서명토큰. 클릭 시 chat.html?room=<id>. pending→sent 선점 후 발송.
//  · 호출: pg_cron 5분 폴링 + 관리자 발행 즉시 킥(GET/POST 모두 처리, 멱등)
//  · secret: FIREBASE_SERVICE_ACCOUNT (서비스 계정 JSON 전체)
// =====================================================================
import { createClient } from 'npm:@supabase/supabase-js@2'
import { importPKCS8, SignJWT } from 'npm:jose@5'

const APP_URL = 'https://mju-ipp.github.io/mju/notice.html'
const CHAT_URL = 'https://mju-ipp.github.io/mju/chat.html'
const CORS = { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': '*', 'Access-Control-Allow-Methods': 'GET, POST, OPTIONS' }
const json = (b: unknown, s = 200) => new Response(JSON.stringify(b), { status: s, headers: { ...CORS, 'Content-Type': 'application/json' } })

const normCo = (s: string) => (s || '').replace(/㈜|\(주\)|주식회사|\s/g, '')

function matches(scope: string, value: string | null, t: Record<string, unknown>): boolean {
  switch (scope) {
    case 'all': return true
    case 'job': return t.job_key === value
    case 'company': return normCo(String(t.company || '')) === normCo(String(value || ''))
    case 'target': return t.target_type === value
    case 'type': return t.type1 === value
    case 'custom': {
      try {
        const sel = JSON.parse(value || '{}')
        // (2026-10-22) aud = 받는 쪽(관리자 학생/기업 탭) — 다른 쪽 기기는 빼고, 다른 조건이 없으면 그 쪽 전체.
        //   기업 공지가 같은 회사 학생에게 새지 않게(학생 기기도 company 값을 가짐)
        if (sel.aud) {
          if (String(t.target_type || 'student') !== sel.aud) return false
          const some = (k: string) => Array.isArray(sel[k]) && sel[k].length > 0
          if (!['targets', 'jobs', 'companies', 'types', 'managers'].some(some)) return true
        }
        if (sel.targets?.includes(t.target_type)) return true
        if (sel.jobs?.includes(t.job_key)) return true
        if (sel.companies?.map(normCo).includes(normCo(String(t.company || '')))) return true
        if (sel.types?.includes(t.type1)) return true
        if (sel.managers?.length && t.manager && sel.managers.includes(String(t.manager).trim())) return true
      } catch (_) { /* 무시 */ }
      return false
    }
    default: return false
  }
}

async function fcmAccessToken(sa: { private_key: string; client_email: string; token_uri: string }) {
  const key = await importPKCS8(sa.private_key, 'RS256')
  const jwt = await new SignJWT({ scope: 'https://www.googleapis.com/auth/firebase.messaging' })
    .setProtectedHeader({ alg: 'RS256', typ: 'JWT' })
    .setIssuer(sa.client_email).setAudience(sa.token_uri)
    .setIssuedAt().setExpirationTime('1h').sign(key)
  const r = await fetch(sa.token_uri, {
    method: 'POST', headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({ grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer', assertion: jwt }),
  })
  const d = await r.json()
  if (!d.access_token) throw new Error('oauth_failed: ' + JSON.stringify(d).slice(0, 200))
  return d.access_token as string
}

const ICON = 'https://mju-ipp.github.io/mju/icons/icon-192.png'

// link: 알림을 누르면 열 주소 / tag: 같은 tag 알림은 한 장으로 바뀜(대화방은 방마다 하나, renotify 로 다시 울림)
async function sendOne(access: string, project: string, token: string, title: string, body: string,
                       link = APP_URL, tag?: string): Promise<'ok' | 'dead' | 'fail'> {
  const r = await fetch(`https://fcm.googleapis.com/v1/projects/${project}/messages:send`, {
    method: 'POST', headers: { Authorization: `Bearer ${access}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ message: { token,
      notification: { title, body },
      data: { link },   // 앱이 열려 있을 때 토스트·SDK 없는 sw.js 폴백이 같은 주소로 가게
      webpush: {
        headers: { TTL: '86400', Urgency: 'high' },   // 저전력·Doze 상태에서 묶여 지연되지 않게
        notification: { title, body, icon: ICON, badge: ICON, lang: 'ko', ...(tag ? { tag, renotify: true } : {}) },
        fcm_options: { link } } } }),
  })
  if (r.ok) return 'ok'
  const t = await r.text()
  console.error('fcm_send_failed', r.status, t.slice(0, 500))
  // ⚠️ INVALID_ARGUMENT 를 여기 넣지 말 것. 그건 토큰이 죽은 게 아니라 페이로드가 잘못됐을 때도 나온다.
  //    예전엔 포함돼 있어서, 본문이 빈 공지 하나로 수신자 전원의 토큰 행이 지워질 수 있었다.
  return /UNREGISTERED|NOT_FOUND|registration-token-not-registered/i.test(t) ? 'dead' : 'fail'
}

type ChatPush = { id: string; room_id: string; center_id: string; kind: 'company' | 'direct'; room_title: string; log_target: string;
                  sender_name: string; body: string; tokens: { id: string; token: string }[] }

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS })
  try {
    const saRaw = Deno.env.get('FIREBASE_SERVICE_ACCOUNT')
    if (!saRaw) return json({ error: 'no_service_account' }, 500)
    const sa = JSON.parse(saRaw)

    const db = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false } })

    const { data: notices, error: ne } = await db.from('notices')
      .select('id,title,body,target_scope,target_value,center_id')
      .eq('published', true).eq('pushed', false).limit(10)
    if (ne) return json({ error: 'notices_read: ' + ne.message }, 500)
    const { data: chats, error: me } = await db.rpc('chat_push_pending', { p_limit: 20 })
    if (me) console.error('chat_push_pending', me.message)   // 대화방 쪽이 깨져도 공지 발송은 계속
    const chatList = (me ? [] : chats || []) as ChatPush[]
    if (!notices?.length && !chatList.length) return json({ ok: true, processed: 0 })

    // 선점(pending→sent / pushed=true) 전에 토큰부터 받는다 — 인증이 실패하면 아무것도 표시하지 않고 다음 폴링에 다시
    const access = await fcmAccessToken(sa)
    const results: unknown[] = []

    const { data: allTokens } = notices?.length
      ? await db.from('push_tokens').select('id,token,device_key,target_type,job_key,company,type1,manager,center_id')
      : { data: [] }
    for (const n of notices || []) {
      // 선점 — 5분 폴링과 즉시 킥이 같은 순간 겹치면(비콘 09:00·16:00) 두 호출이 같은 공지를 읽는다.
      //   pushed=false → true 전환에 성공한 호출만 발송해 같은 알림이 두 번 나가지 않게 한다.
      //   대가: 발송 도중 함수가 죽으면 그 공지는 재시도되지 않는다(중복 발송보다 낫다).
      const { data: claimed, error: ce } = await db.from('notices')
        .update({ pushed: true }).eq('id', n.id).eq('pushed', false).select('id')
      if (ce || !claimed?.length) continue

      // 공지는 자기 센터 기기에만 — 멀티센터로 늘어나도 남의 학생에게 새지 않게
      const tokens = (allTokens || []).filter((t) => t.center_id === n.center_id)
      let targets: { fcm: string; title: string; body: string; rowId: string }[] = []
      if (n.target_scope === 'personal') {
        const { data: recs } = await db.from('notice_recipients')
          .select('student_token,title,body').eq('notice_id', n.id)
        for (const rec of recs || []) {
          for (const t of tokens) {
            // null === null 로 엉뚱한 기기가 개인 공지를 받지 않게 양쪽 존재를 먼저 확인
            if (t.device_key && rec.student_token && t.device_key === rec.student_token && t.token)
              targets.push({ fcm: t.token, title: rec.title || n.title, body: rec.body || n.body, rowId: t.id })
          }
        }
      } else {
        for (const t of tokens) {
          if (t.token && matches(n.target_scope || 'all', n.target_value, t))
            targets.push({ fcm: t.token, title: n.title, body: n.body, rowId: t.id })
        }
      }

      let ok = 0; const dead: string[] = []
      for (const tg of targets) {
        // 본문이 비면 FCM 이 INVALID_ARGUMENT 를 낸다 → 제목으로 대체
        const r = await sendOne(access, sa.project_id, tg.fcm, tg.title, (tg.body || tg.title || '').slice(0, 300))
        if (r === 'ok') ok++
        else if (r === 'dead') dead.push(tg.rowId)
      }
      if (dead.length) await db.from('push_tokens').delete().in('id', dead)

      await db.from('push_logs').insert({
        scope: n.target_scope || 'all', target: n.target_value || '전체',
        title: n.title, body: (n.body || '').slice(0, 200),
        recipient_count: targets.length, success_count: ok, center_id: n.center_id,
      })
      results.push({ notice: n.title, recipients: targets.length, success: ok, cleaned: dead.length })
    }

    // 대화방 선생님 글 — 공지와 같은 선점 방식(pending→sent 에 성공한 호출만 발송)
    for (const m of chatList) {
      const { data: claimed, error: ce } = await db.from('chat_messages')
        .update({ push_state: 'sent' }).eq('id', m.id).eq('push_state', 'pending').select('id')
      if (ce || !claimed?.length) continue
      const title = m.kind === 'company' ? `${m.room_title} 대화방` : m.room_title
      const body = `${m.sender_name}: ${m.body}`.slice(0, 300)
      const link = `${CHAT_URL}?room=${encodeURIComponent(m.room_id)}`
      let ok = 0; const dead: string[] = []
      for (const t of m.tokens || []) {
        const r = await sendOne(access, sa.project_id, t.token, title, body, link, 'chat-' + m.room_id)
        if (r === 'ok') ok++
        else if (r === 'dead') dead.push(t.id)
      }
      if (dead.length) await db.from('push_tokens').delete().in('id', dead)
      // 기록은 남기되 본문은 안 남김 — 1:1 대화 내용이 발송 기록 화면에 그대로 보이지 않게
      await db.from('push_logs').insert({
        scope: 'chat_' + m.kind, target: m.log_target || m.room_title, title, body: m.sender_name,
        recipient_count: (m.tokens || []).length, success_count: ok, center_id: m.center_id,
      })
      results.push({ chat: m.room_title, recipients: (m.tokens || []).length, success: ok, cleaned: dead.length })
    }
    return json({ ok: true, processed: results.length, results })
  } catch (e) {
    return json({ error: String(e).slice(0, 300) }, 500)
  }
})
