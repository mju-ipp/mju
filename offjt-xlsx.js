// offjt-xlsx.js — 직무별 OFF-JT 수업일정 엑셀 읽기 (docs/OFFJT.md 새 3단계, sql/62)
// admin.html 이 SheetJS(XLSX) 를 넘겨 쓴다. 화면 코드와 분리해 둔 이유: node 에서 2026년 37개 파일로 같은 함수를 시험하려고.
//
// 엑셀 형식(2026년 전 직무 같음): 시트 = 달(3~7월), 2행 'YYYY년 M월', 3행 요일 머리(일~토),
// 날짜 줄(1~31 숫자) 아래 다음 날짜 줄 전까지 날짜 칸마다 '과목 / 능력단위' 가 위에서부터 쌍으로 쌓임.
//  · ★ = 그날부터 새 능력단위(앞·뒤 어디에 붙든 지우고 is_new).
//  · '직업기초능력' 은 글자로 판단(단독 칸). 색칠은 과목별 색 구분이라 기준이 못 됨(10/16 확인).
//  · 날짜 숫자가 빈 칸은 같은 줄 옆 칸에서 추정(경고), 그 달을 넘는 칸(3월 시트 끝의 4/1)은 건너뜀.
//  · 시트 제목 달과 시트 이름 달이 다르면 요일이 맞는 쪽(경고).

const DOW = '일월화수목금토';
const pad = (n) => String(n).padStart(2, '0');
const clean = (s) => String(s).replace(/★/g, '').replace(/\s+/g, ' ').trim();

export function parseOffjtWorkbook(XLSX, wb, fileName = '') {
  const months = {};            // 'YYYY-MM' → { sheet, days: [{ day, items, guessed }], warnings: [] }
  const units = [];             // 엑셀에 나온 순서대로 { subject, unit } (직업기초능력 제외)
  const seenUnit = new Set();
  const skipped = [];           // 읽지 못한 시트

  for (const sheetName of wb.SheetNames) {
    const ws = wb.Sheets[sheetName];
    if (!ws || !ws['!ref']) continue;
    const g = XLSX.utils.sheet_to_json(ws, { header: 1, raw: true, defval: null, blankrows: true });
    const warn = [];

    // 제목 달·시트 이름 달
    let ty = null, tm = null;
    for (let r = 0; r < Math.min(g.length, 8) && ty == null; r++) {
      for (const v of g[r] || []) {
        const m = typeof v === 'string' && v.match(/(\d{4})\s*년\s*(\d{1,2})\s*월/);
        if (m) { ty = +m[1]; tm = +m[2]; break; }
      }
    }
    const sm = sheetName.match(/(\d{1,2})\s*월/);
    if (ty == null) { skipped.push(sheetName); continue; }

    // 요일 머리 줄 → 열별 요일
    let hdrRow = -1; const colWd = {};
    for (let r = 0; r < Math.min(g.length, 10) && hdrRow < 0; r++) {
      const row = g[r] || []; const hit = {};
      row.forEach((v, c) => { if (typeof v === 'string' && v.trim().length === 1 && DOW.includes(v.trim())) hit[c] = DOW.indexOf(v.trim()); });
      if (Object.keys(hit).length >= 5) { hdrRow = r; Object.assign(colWd, hit); }
    }
    if (hdrRow < 0) { skipped.push(sheetName); continue; }
    const cols = Object.keys(colWd).map(Number);

    // 날짜 줄
    const isDay = (v) => typeof v === 'number' && Number.isInteger(v) && v >= 1 && v <= 31;
    const dateRows = [];
    for (let r = hdrRow + 1; r < g.length; r++) if (cols.some(c => isDay((g[r] || [])[c]))) dateRows.push(r);

    // 그 날짜 칸 아래에 글자가 있는지(수업 있는 칸만 요일 점검 — 빈 칸의 숫자 오타는 무시)
    const hasItems = (i, c) => {
      const end = i + 1 < dateRows.length ? dateRows[i + 1] : g.length;
      for (let r = dateRows[i] + 1; r < end; r++) { const v = (g[r] || [])[c]; if (typeof v === 'string' && v.trim()) return true; }
      return false;
    };
    // 달 고르기 — 제목 달 우선, 요일이 안 맞으면 시트 이름 달
    const cands = [tm]; if (sm && +sm[1] !== tm) cands.push(+sm[1]);
    const mismatch = (mo) => {
      let n = 0;
      dateRows.forEach((r, i) => { for (const c of cols) {
        const v = g[r][c]; if (!isDay(v) || !hasItems(i, c)) continue;
        const d = new Date(ty, mo - 1, v);
        if (d.getMonth() !== mo - 1 || d.getDay() !== colWd[c]) n++;
      } });
      return n;
    };
    let mo = cands[0], best = mismatch(cands[0]);
    if (cands[1] && best > 0) { const b2 = mismatch(cands[1]); if (b2 < best) { mo = cands[1]; best = b2; warn.push(`시트 제목은 ${tm}월인데 요일이 ${mo}월과 맞아 ${mo}월로 읽었어요`); } }
    if (best > 0) warn.push(`요일이 안 맞는 날짜 ${best}칸 — 엑셀을 확인해주세요`);
    const ym = `${ty}-${pad(mo)}`;
    const last = new Date(ty, mo, 0).getDate();
    const out = months[ym] || (months[ym] = { sheet: sheetName, days: [], warnings: [] });
    if (months[ym].sheet !== sheetName) warn.push(`같은 달(${mo}월) 시트가 또 있어요: ${sheetName}`);

    dateRows.forEach((dr, i) => {
      const end = i + 1 < dateRows.length ? dateRows[i + 1] : g.length;
      for (const c of cols) {
        const items = [];
        for (let r = dr + 1; r < end; r++) {
          const v = (g[r] || [])[c];
          if (typeof v === 'string' && v.trim()) items.push(v);
        }
        if (!items.length) continue;
        let dnum = g[dr][c], guessed = false;
        if (!isDay(dnum)) {   // 날짜 숫자 빈 칸 → 같은 줄 가장 가까운 숫자 칸에서
          const near = cols.filter(x => isDay(g[dr][x])).sort((a, b) => Math.abs(a - c) - Math.abs(b - c))[0];
          if (near == null) { warn.push(`날짜를 알 수 없는 칸 — ${clean(items[0])} 등 ${items.length}줄 건너뜀`); continue; }
          dnum = g[dr][near] + (colWd[c] - colWd[near]);
          guessed = true;
          if (dnum < 1 || dnum > last) { warn.push(`${mo}월 밖 칸(${clean(items[0])} 등) 건너뜀 — 다음/이전 달 시트에서 읽어요`); continue; }
          warn.push(`${mo}/${dnum} 날짜 숫자가 비어 있어 옆 칸으로 추정했어요`);
        }
        const day = `${ym}-${pad(dnum)}`;
        const list = [];
        for (let j = 0; j < items.length;) {
          const raw = items[j], t = clean(raw);
          if (/직업기초능력/.test(t)) { list.push({ subject: t, unit: null, is_new: raw.includes('★'), is_basic: true }); j++; continue; }
          if (j + 1 >= items.length) { list.push({ subject: t, unit: null, is_new: raw.includes('★'), is_basic: false }); warn.push(`${mo}/${dnum} '${t}' 짝(능력단위)이 없어요`); j++; continue; }
          const rawU = items[j + 1], u = clean(rawU);
          list.push({ subject: t, unit: u, is_new: rawU.includes('★') || raw.includes('★'), is_basic: false });
          const k = t + '|' + u;
          if (!seenUnit.has(k)) { seenUnit.add(k); units.push({ subject: t, unit: u }); }
          j += 2;
        }
        list.forEach((x, n) => { x.seq = n + 1; });
        out.days.push({ day, items: list, guessed });
      }
    });
    out.days.sort((a, b) => (a.day < b.day ? -1 : a.day > b.day ? 1 : 0));
    out.warnings.push(...warn);
  }
  return { file: fileName, months, units, skipped };
}

// 올리기용 평탄화 — [{ day, seq, subject, unit, is_new, is_basic }]
export function offjtRows(parsed, ymList) {
  const rows = [];
  for (const ym of ymList) for (const d of (parsed.months[ym]?.days || [])) for (const it of d.items) {
    rows.push({ day: d.day, seq: it.seq, subject: it.subject, unit: it.unit, is_new: it.is_new, is_basic: it.is_basic });
  }
  return rows;
}

// 붙여넣기 → 능력단위요소·수행과업. '1. 요소' / '1) 요소' 줄이 요소, 그 아래 줄은 수행과업.
// NCS 사이트처럼 '1.1 …' 번호가 붙은 줄은 수행과업으로(번호는 지움). 빈 줄·'- ' 머리표 무시.
export function parseElements(text) {
  const els = [];
  for (const line0 of String(text || '').split(/\r?\n/)) {
    const line = line0.replace(/\s+/g, ' ').trim();
    if (!line) continue;
    const sub = line.match(/^\d+\s*[.\-]\s*\d+\s*\.?\s+(.*)$/);
    const top = !sub && line.match(/^(\d+)\s*[.)]\s*(.+)$/);
    if (top) { els.push({ name: top[2].trim(), tasks: [] }); continue; }
    const task = (sub ? sub[1] : line).replace(/^[-·•▪○●]\s*/, '').trim();
    if (!task) continue;
    if (!els.length) els.push({ name: '(요소 이름 없음)', tasks: [] });
    els[els.length - 1].tasks.push(task);
  }
  return els;
}
