import { createOnline, createLocal, errText } from './net.js';
import { decide } from './bot.js';

// ------------------------------------------------------------------ 도우미
const $ = (s, r = document) => r.querySelector(s);
const esc = (s) => String(s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const COLORS = ['#ff5a5f', '#2f9bff', '#ffb020', '#9a6bff'];
const FIELD = { '물리학': '#2f9bff', '화학': '#ff7a3d', '생물학': '#39b76a', '천문학': '#7a5cff', '수학': '#e0457b', '컴퓨터과학': '#14a3a3' };
const ZONES = ['물리동', '천문대', '온실', '전산실'];
const CELL = 100, PAD = 62;
const cx = (t) => PAD + t.x * CELL, cy = (t) => PAD + t.y * CELL;

// ------------------------------------------------------------------ 상태
let net = null, onlineNet = null;
let S = null;                 // 정적 데이터 (지도, 카드 정의, 설정)
let room = null, st = null;   // 현재 방 / 게임 상태
let version = -1, lastSeq = 0;
let animQ = Promise.resolve(), animating = false, sending = false;
let sel = null;               // 이동 선택 {tile, path}
let targetMode = null;        // 칸 지정 카드 사용 중 {iid, tiles:Set}
let clockOff = -Infinity;     // 서버 시계 - 내 시계
let pawnPos = {}, lastGame = null, lastDice = null, resultShownFor = null, timeoutKey = null;
let muted = localStorage.getItem('lab_muted') === '1';

const rdef = (id) => S.research.find((d) => d.id === id);
const cdef = (id) => S.chaos.find((d) => d.id === id);
const total = (p) => Math.max(p.rp + p.bp, 0);
const meIdx = () => (st && st.players ? st.players.findIndex((p) => p.uid === net.uid() && !p.gone) : -1);
const myTurn = () => st && st.phase === 'playing' && st.turn.idx === meIdx();
const isHost = () => st && st.host === net.uid();
const hotseat = () => net.mode === 'local' && !net.solo;   // 한 화면을 돌려가며 하는 모드
const botTurn = () => st && st.phase === 'playing' && net.solo && net.isBot(st.players[st.turn.idx].uid);

function show(id) {
  for (const s of document.querySelectorAll('.screen')) s.hidden = s.id !== id;
}

// ------------------------------------------------------------------ 소리
let actx = null;
function sfx(name) {
  if (muted) return;
  try {
    actx = actx || new (window.AudioContext || window.webkitAudioContext)();
    const seq = {
      step: [[520, 0.05]], dice: [[300, 0.04], [420, 0.04], [360, 0.04], [620, 0.08]],
      gain: [[660, 0.07], [880, 0.12]], chaos: [[220, 0.12], [180, 0.12], [220, 0.12], [140, 0.3]],
      use: [[440, 0.08], [330, 0.14]], turn: [[740, 0.09], [990, 0.14]], end: [[523, 0.12], [659, 0.12], [784, 0.12], [1047, 0.3]],
    }[name] || [];
    let t = actx.currentTime;
    for (const [f, d] of seq) {
      const o = actx.createOscillator(), g = actx.createGain();
      o.type = name === 'chaos' ? 'sawtooth' : 'triangle';
      o.frequency.value = f;
      g.gain.setValueAtTime(0.12, t);
      g.gain.exponentialRampToValueAtTime(0.001, t + d);
      o.connect(g).connect(actx.destination);
      o.start(t); o.stop(t + d);
      t += d;
    }
  } catch (e) { /* 소리는 없어도 됨 */ }
}

// ------------------------------------------------------------------ 토스트 / 배너 / 모달 / 기록
function toast(text, kind = '') {
  const el = document.createElement('div');
  el.className = 'toast ' + kind;
  el.textContent = text;
  $('#toasts').appendChild(el);
  setTimeout(() => el.classList.add('out'), 2200);
  setTimeout(() => el.remove(), 2600);
}

function log(text) {
  const box = $('#log');
  const el = document.createElement('p');
  el.textContent = text;
  box.appendChild(el);
  while (box.children.length > 40) box.firstChild.remove();
  box.scrollTop = box.scrollHeight;
}

function banner(html, kind, ms) {
  return new Promise((res) => {
    const b = $('#banner');
    b.className = kind;
    b.innerHTML = html;
    b.hidden = false;
    let done = false;
    const end = () => { if (done) return; done = true; b.hidden = true; b.onclick = null; res(); };
    b.onclick = end;
    setTimeout(end, ms);
  });
}

function openModal(html, sticky = false) {
  const m = $('#modal');
  m.innerHTML = `<div class="sheet">${html}</div>`;
  m.dataset.sticky = sticky ? '1' : '';
  m.hidden = false;
}
function closeModal() { $('#modal').hidden = true; $('#modal').innerHTML = ''; }

// ------------------------------------------------------------------ 서버 호출
async function call(fn, args) {
  if (sending) return;
  sending = true;
  try {
    const r = await net.rpc(fn, args);
    if (r && r.state) applyRoom(r);
    return r;
  } catch (e) {
    toast(errText(e), 'err');
  } finally {
    sending = false;
  }
}

// ------------------------------------------------------------------ 방 상태 반영
function applyRoom(r) {
  if (r === null) { if (room) goHome('방에서 나왔어요.'); return; }
  if (!r || !r.state || !net) return;
  if (room && r.id === room.id && r.version <= version) return;
  const first = !room || room.id !== r.id;
  const ns = r.state;
  const evs = (ns.events || []).filter((e) => e.seq > lastSeq);
  room = r; version = r.version; lastSeq = ns.seq || 0;

  animQ = animQ.then(async () => {
    const prev = st;
    if (ns.now) clockOff = Math.max(clockOff, Date.parse(ns.now) - Date.now());
    const canPlay = !first && prev && prev.phase === 'playing' && prev.game === ns.game
      && evs.length > 0 && evs.length < 30 && !document.hidden;
    if (canPlay) await play(evs, ns);
    else if (!first && ns.phase === 'playing' && (!prev || prev.phase !== 'playing')) sfx('turn');
    st = ns; sel = null; targetMode = null; pawnPos = {};
    render();
    botKick();
  }).catch((e) => console.error(e));
}

// ------------------------------------------------------------------ AI 상대 (혼자 하기)
let botBusy = false, botSkip = new Set(), botSkipKey = null;
function botKick() {
  if (botBusy || !botTurn()) return;
  botBusy = true;
  const myNet = net, myRoom = room.id, seq = st.seq, i = st.turn.idx;
  setTimeout(async () => {
    try {
      if (net !== myNet || !room || room.id !== myRoom || !botTurn() || st.seq !== seq || st.turn.idx !== i) return;
      const key = st.game + ':' + st.turn.n;
      if (key !== botSkipKey) { botSkipKey = key; botSkip = new Set(); }
      const d = decide(st, S, i, botSkip);
      let r;
      try {
        r = await myNet.rpcAs(st.players[i].uid, d.fn, { p_room: myRoom, ...d.args });
      } catch (e) {
        console.warn('AI 행동 실패', d, e);
        if (d.iid) botSkip.add(d.iid);                       // 못 쓰는 카드는 이번 턴에 다시 시도하지 않음
        else r = await myNet.rpcAs(st.players[i].uid, 'lab_timeout', { p_room: myRoom }).catch(() => null);
      }
      if (net === myNet && r && r.state) applyRoom(r);
    } finally {
      botBusy = false;
      animQ.then(botKick);
    }
  }, 650);
}

async function enter(n, r) {
  net = n;
  S = await net.static();
  buildBoard();
  room = null; st = null; version = -1; lastSeq = 0; lastGame = null; lastDice = null; resultShownFor = null;
  $('#log').innerHTML = '';
  net.watch(r.id, applyRoom);
  applyRoom(r);
}

function goHome(msg) {
  if (net) net.unwatch();
  room = null; st = null; version = -1;
  closeModal();
  show('home');
  if (msg) toast(msg);
  if (net && net.mode === 'local') net = onlineNet;
}

// ------------------------------------------------------------------ 이벤트 재생 (애니메이션)
async function play(evs, ns) {
  animating = true;
  renderAction();
  const nm = (i) => (ns.players[i] ? ns.players[i].name : '?');
  for (const e of evs) {
    switch (e.t) {
      case 'roll': {
        const die = $('#die');
        sfx('dice');
        if (die) {
          die.classList.add('rolling');
          for (let i = 0; i < 7; i++) { die.textContent = 1 + Math.floor(Math.random() * 6); await sleep(55); }
          die.classList.remove('rolling');
          die.textContent = e.dice;
        }
        lastDice = e.dice;
        const extra = e.rolls.length > 1 ? ` (${e.rolls.join(', ')} 중 큰 수)` : e.dice !== e.base ? ` (${e.base}에서 보정)` : '';
        log(`${nm(e.p)} 주사위 ${e.dice}${extra}`);
        if (extra) toast(`주사위 ${e.dice}${extra}`);
        await sleep(250);
        break;
      }
      case 'move':
        for (const t of e.path) { pawnPos[e.p] = t; placePawns(); sfx('step'); await sleep(170); }
        break;
      case 'warp':
        pawnPos[e.p] = e.to; placePawns();
        await sleep(380);
        break;
      case 'gain_research': {
        const d = rdef(e.def);
        const it = $(`#lyItems [data-at="${e.tile}"]`); if (it) it.remove();
        sfx('gain');
        toast(`${nm(e.p)}  ${d.icon} ${d.name}  +${e.double ? e.pts * 2 : e.pts}점${e.double ? ' (2배!)' : ''}`, 'gain');
        log(`${nm(e.p)} 연구 획득: ${d.name} (+${e.double ? e.pts * 2 : e.pts})`);
        await sleep(420);
        break;
      }
      case 'gain_chaos': {
        const d = cdef(e.def);
        const it = $(`#lyItems [data-at="${e.tile}"]`); if (it) it.remove();
        sfx('gain');
        toast(`${nm(e.p)}이(가) 카오스 카드 「${d.name}」을(를) 손에 넣었다`, 'chaos');
        log(`${nm(e.p)} 카오스 카드 획득: ${d.name}`);
        await sleep(600);
        break;
      }
      case 'chaos_spawn': {
        const d = cdef(e.def);
        sfx('chaos');
        log(`카오스 카드 출현: ${d.name}`);
        await banner(`<p class="b-kicker">카오스 카드 출현</p><p class="b-icon">${d.icon}</p>
          <p class="b-title">${esc(d.name)}</p><p class="b-desc">${esc(d.desc)}</p>
          <p class="b-foot">먼저 밟는 사람이 임자</p>`, 'spawn', 2000);
        break;
      }
      case 'use': {
        const d = e.kind === 'chaos' ? cdef(e.def) : rdef(e.def);
        const tg = e.target && e.target.player != null ? ` → ${nm(e.target.player)}` : '';
        sfx(e.kind === 'chaos' ? 'chaos' : 'use');
        log(`${nm(e.p)} ${e.kind === 'chaos' ? '카오스 카드' : '연구 능력'} 사용: ${d.name}${tg}`);
        await banner(`<p class="b-kicker">${esc(nm(e.p))}${esc(tg)}</p><p class="b-icon">${d.icon}</p>
          <p class="b-title">${esc(d.name)}</p><p class="b-desc">${esc(d.desc)}</p>`,
          e.kind === 'chaos' ? 'use-chaos' : 'use-research', e.kind === 'chaos' ? 1900 : 1300);
        break;
      }
      case 'msg':
        toast(e.text, 'msg'); log(e.text);
        await sleep(450);
        break;
      case 'extra_turn': toast(`${nm(e.p)} 한 턴 더!`); break;
      case 'timeout': toast(`${nm(e.p)} 시간 초과 — 턴을 넘겨요`); log(`${nm(e.p)} 시간 초과`); break;
      case 'left': toast(`${nm(e.p)}이(가) 나갔어요`); log(`${nm(e.p)} 퇴장`); break;
      case 'turn': sfx('turn'); break;
      case 'end': sfx('end'); break;
      default: break;
    }
  }
  animating = false;
}

// ------------------------------------------------------------------ 지도 (정적 부분)
function buildBoard() {
  const m = S.map, T = m.tiles;
  const W = PAD * 2 + (m.w - 1) * CELL, H = PAD * 2 + (m.h - 1) * CELL;
  const svg = $('#board');
  svg.setAttribute('viewBox', `0 0 ${W} ${H}`);
  let h = `<defs>
    <pattern id="grid" width="25" height="25" patternUnits="userSpaceOnUse">
      <path d="M25 0H0V25" fill="none" stroke="rgba(255,255,255,.10)" stroke-width="1"/></pattern>
    <pattern id="grid2" width="100" height="100" patternUnits="userSpaceOnUse" x="${PAD - 50}" y="${PAD - 50}">
      <path d="M100 0H0V100" fill="none" stroke="rgba(255,255,255,.20)" stroke-width="1.5"/></pattern>
    <pattern id="hz" width="14" height="14" patternUnits="userSpaceOnUse" patternTransform="rotate(45)">
      <rect width="14" height="14" fill="#ffd23f"/><rect width="7" height="14" fill="#1d2b33"/></pattern>
  </defs>
  <rect width="${W}" height="${H}" rx="26" class="mat"/>
  <rect width="${W}" height="${H}" rx="26" fill="url(#grid)"/>
  <rect width="${W}" height="${H}" rx="26" fill="url(#grid2)"/>`;
  // 구역 이름
  const zp = [[PAD + 150, PAD + 108], [W - PAD - 150, PAD + 108], [PAD + 150, H - PAD - 96], [W - PAD - 150, H - PAD - 96]];
  ZONES.forEach((z, i) => { h += `<text class="zone-label" x="${zp[i][0]}" y="${zp[i][1]}">${z}</text>`; });
  // 길
  for (const t of T) for (const n of t.n) {
    if (n > t.id && n !== t.portal) {
      const u = T[n];
      h += `<line class="road" x1="${cx(t)}" y1="${cy(t)}" x2="${cx(u)}" y2="${cy(u)}"/>`;
    }
  }
  for (const t of T) for (const n of t.n) {
    if (n > t.id && n !== t.portal) {
      const u = T[n];
      h += `<line class="road-mid" x1="${cx(t)}" y1="${cy(t)}" x2="${cx(u)}" y2="${cy(u)}"/>`;
    }
  }
  // 칸
  const portals = T.filter((t) => t.portal != null).map((t) => Math.min(t.id, t.portal));
  const pairs = [...new Set(portals)];
  for (const t of T) {
    const pi = t.portal != null ? pairs.indexOf(Math.min(t.id, t.portal)) : -1;
    h += `<g class="tile z${t.zone}${pi >= 0 ? ' portal p' + pi : ''}" data-tile="${t.id}" transform="translate(${cx(t)},${cy(t)})">
      <rect x="-36" y="-33" width="72" height="72" rx="17" class="tile-shadow"/>
      <rect x="-36" y="-37" width="72" height="72" rx="17" class="tile-face"/>
      ${pi >= 0 ? `<circle r="25" cy="-1" class="portal-ring"/><circle r="15" cy="-1" class="portal-ring in"/><text class="portal-t" y="34">포털 ${'AB'[pi]}</text>` : ''}
    </g>`;
  }
  h += `<g id="lyHi"></g><g id="lyItems"></g><g id="lyPawns"></g>`;
  svg.innerHTML = h;
}

// ------------------------------------------------------------------ 이동 계산
function reach() {
  const T = S.map.tiles, start = st.players[meIdx()].pos, D = st.turn.dice;
  const dist = { [start]: 0 }, prev = {}, q = [start];
  while (q.length) {
    const c = q.shift();
    if (dist[c] >= D) continue;
    for (const n of T[c].n) if (dist[n] === undefined) { dist[n] = dist[c] + 1; prev[n] = c; q.push(n); }
  }
  return { dist, prev, start };
}
function pathTo(r, t) {
  const p = []; let c = t;
  while (c !== r.start) { p.unshift(c); c = r.prev[c]; }
  return p;
}
function teleportTiles() {
  const T = S.map.tiles, me = T[st.players[meIdx()].pos], R = Number(st.cfg.teleport_radius);
  return new Set(T.filter((t) => t.id !== me.id && Math.hypot(t.x - me.x, t.y - me.y) <= R).map((t) => t.id));
}

// ------------------------------------------------------------------ 렌더
function render() {
  if (!st || !net) return;
  if (net.mode === 'local') net.setActor(st.phase === 'playing' ? st.players[st.turn.idx].uid : st.host);
  if (st.phase === 'lobby') { closeModal(); resultShownFor = null; show('lobby'); renderLobby(); return; }
  show('game');
  if (st.game !== lastGame) { lastGame = st.game; $('#lyPawns').innerHTML = ''; lastDice = null; $('#log').innerHTML = ''; fitBoard(); }
  renderTop(); renderScores(); renderBoard(); renderAction(); renderHand(); renderResult();
}

function renderLobby() {
  $('#lobbyCode').textContent = room.code;
  const min = Number(S.cfg.min_players), n = st.players.length;
  $('#lobbyPlayers').innerHTML = st.players.map((p, i) => `
    <li><span class="dot" style="background:${COLORS[i % 4]}"></span>
      <span class="lp-name">${esc(p.name)}</span>
      ${p.uid === st.host ? '<span class="tag host">방장</span>' : ''}
      ${p.uid === net.uid() ? '<span class="tag me">나</span>' : ''}
      ${isHost() && p.uid !== st.host && net.mode === 'online' ? `<button class="kick" data-act="kick" data-uid="${p.uid}">내보내기</button>` : ''}
    </li>`).join('') + Array.from({ length: Math.max(0, 4 - n) }, () => '<li class="empty">빈 자리</li>').join('');
  const b = $('#btnStart');
  b.hidden = !isHost();
  b.disabled = n < min;
  $('#lobbyHint').textContent = isHost()
    ? (n < min ? `${min}명 이상 모이면 시작할 수 있어요. 방 코드를 친구에게 알려 주세요.` : `${n}명 준비 완료. 시작해도 좋아요.`)
    : '방장이 게임을 시작하기를 기다리는 중…';
}

function renderTop() {
  const t = st.turn, p = st.players[t.idx];
  const local = net.mode === 'local' ? `<span class="local-tag">${net.solo ? 'AI 대전' : '로컬 테스트'}</span>` : '';
  $('#top').innerHTML = `
    <div class="round">라운드 <b>${Math.min(t.round, st.rounds)}</b>/${st.rounds}</div>
    <div class="turn-name"><span class="dot" style="background:${COLORS[t.idx % 4]}"></span>
      ${st.phase === 'finished' ? '게임 종료' : (myTurn() && !hotseat() ? '내 차례' : esc(p.name) + '의 차례')}${local}</div>
    <div id="timer" class="timer"></div>
    <div id="die" class="die">${st.phase === 'playing' && t.dice ? t.dice : (lastDice || '?')}</div>
    <button class="menu-btn" data-act="menu" aria-label="메뉴">☰</button>`;
  tick();
}

function fxBadges(p) {
  const f = p.fx || {}, b = [];
  if (f.one) b.push('주사위=1'); else {
    if (f.six) b.push('주사위 MAX');
    if (f.adv) b.push('주사위 ×2회');
    if (f.plus) b.push('주사위 +' + f.plus);
    if (f.minus) b.push('주사위 -' + f.minus);
  }
  if (f.double) b.push('다음 연구 2배');
  if (f.extra) b.push('추가 턴 ' + f.extra);
  return b.map((x) => `<span class="fx">${x}</span>`).join('');
}

function renderScores() {
  const order = st.players.map((p, i) => i).filter((i) => !st.players[i].gone)
    .sort((a, b) => total(st.players[b]) - total(st.players[a]) || st.players[b].research.length - st.players[a].research.length || a - b);
  $('#scores').innerHTML = order.map((i, rank) => {
    const p = st.players[i];
    const ready = p.research.filter((c) => !c.used).length;
    return `<button class="score${st.turn.idx === i && st.phase === 'playing' ? ' now' : ''}${i === meIdx() && !hotseat() ? ' mine' : ''}" data-act="peek" data-p="${i}" style="--pc:${COLORS[i % 4]}">
      <span class="rank">${rank + 1}</span>
      <span class="s-name">${esc(p.name)}</span>
      <span class="s-total">${total(p)}<small>점</small></span>
      <span class="s-sub">연구 ${p.rp}${p.bp ? ` · 보정 ${p.bp > 0 ? '+' : ''}${p.bp}` : ''} · 능력 ${ready}${p.chaos.length ? ` · 카오스 ${p.chaos.length}` : ''}</span>
      <span class="s-fx">${fxBadges(p)}</span>
    </button>`;
  }).join('');
}

const OFF = { 1: [[0, 0]], 2: [[-15, 0], [15, 0]], 3: [[-16, 8], [16, 8], [0, -14]], 4: [[-16, -14], [16, -14], [-16, 14], [16, 14]] };
function placePawns() {
  const g = $('#lyPawns'), T = S.map.tiles, by = {};
  st.players.forEach((p, i) => {
    if (p.gone) return;
    const t = pawnPos[i] != null ? pawnPos[i] : p.pos;
    (by[t] = by[t] || []).push(i);
  });
  const want = new Set();
  for (const [t, arr] of Object.entries(by)) {
    arr.forEach((i, k) => {
      want.add(String(i));
      let el = g.querySelector(`[data-p="${i}"]`);
      if (!el) {
        el = document.createElementNS('http://www.w3.org/2000/svg', 'g');
        el.setAttribute('class', 'pawn');
        el.dataset.p = i;
        el.innerHTML = `<ellipse cx="0" cy="17" rx="13" ry="4" class="pawn-sh"/>
          <path d="M-6 -22h12v9l10 20a7 7 0 0 1-6 10h-20a7 7 0 0 1-6-10l10-20z" fill="${COLORS[i % 4]}" class="pawn-body"/>
          <rect x="-8" y="-25" width="16" height="5" rx="2.5" fill="${COLORS[i % 4]}" class="pawn-body"/>
          <text y="12" class="pawn-t">${esc([...st.players[i].name][0] || '?')}</text>`;
        g.appendChild(el);
      }
      const o = (OFF[arr.length] || OFF[4])[k % 4];
      el.style.transform = `translate(${cx(T[t]) + o[0]}px, ${cy(T[t]) + o[1] - 6}px)`;
      el.classList.toggle('turn', st.phase === 'playing' && st.turn.idx === i);
    });
  }
  for (const el of [...g.children]) if (!want.has(el.dataset.p)) el.remove();
}

function renderBoard() {
  const T = S.map.tiles;
  let items = '', hi = '';
  for (const [k, c] of Object.entries(st.board.research)) {
    const d = rdef(c.def), t = T[k];
    items += `<g class="item research" data-at="${k}" transform="translate(${cx(t)},${cy(t) - 3})">
      <circle r="25" fill="${FIELD[d.field] || '#888'}" class="it-bg"/><text class="it-ico" y="10">${d.icon}</text>
      <g transform="translate(22,-22)"><circle r="12" class="it-pts"/><text class="it-pts-t" y="5">${d.pts}</text></g></g>`;
  }
  for (const [k, c] of Object.entries(st.board.chaos)) {
    const d = cdef(c.def), t = T[k];
    items += `<g class="item chaos" data-at="${k}" transform="translate(${cx(t)},${cy(t) - 3})">
      <g class="chaos-spin"><rect x="-27" y="-27" width="54" height="54" rx="9" fill="url(#hz)" class="hz"/>
      <rect x="-20" y="-20" width="40" height="40" rx="6" class="hz-in"/></g><text class="it-ico" y="10">${d.icon}</text></g>`;
  }
  const ring = (t, cls) => `<rect class="hi ${cls}" x="${cx(T[t]) - 40}" y="${cy(T[t]) - 41}" width="80" height="80" rx="20"/>`;
  if (targetMode) {
    for (const t of targetMode.tiles) hi += ring(t, 'tgt');
  } else if (myTurn() && st.turn.phase === 'move' && !animating) {
    const r = reach();
    for (const k of Object.keys(r.dist)) if (Number(k) !== r.start) hi += ring(k, 'reach');
    if (sel) {
      hi += ring(sel.tile, 'sel');
      sel.path.slice(0, -1).forEach((t) => { hi += `<circle class="path-dot" cx="${cx(T[t])}" cy="${cy(T[t]) - 1}" r="9"/>`; });
    }
  }
  $('#lyItems').innerHTML = items;
  $('#lyHi').innerHTML = hi;
  placePawns();
}

function itemInfo(tile) {
  const r = st.board.research[tile], c = st.board.chaos[tile];
  if (r) { const d = rdef(r.def); return `${d.icon} ${d.name} (${d.pts}점) — ${d.desc}`; }
  if (c) { const d = cdef(c.def); return `${d.icon} 카오스 「${d.name}」 — ${d.desc}`; }
  return '';
}

function renderAction() {
  const a = $('#action');
  if (!st || st.phase !== 'playing') { a.innerHTML = ''; return; }
  const p = st.players[st.turn.idx];
  const who = hotseat() ? `<b style="color:${COLORS[st.turn.idx % 4]}">${esc(p.name)}</b> ` : '';
  if (animating) { a.innerHTML = '<p class="hint">…</p>'; return; }
  if (targetMode) {
    a.innerHTML = `<p class="hint">순간이동할 칸(보라색)을 누르세요</p><button class="btn" data-act="cancel-target">취소</button>`;
  } else if (!myTurn()) {
    a.innerHTML = `<p class="hint">${esc(p.name)}${botTurn() ? '이(가) 생각하는 중…' : '의 차례를 기다리는 중…'}</p>`;
  } else if (st.turn.phase === 'roll') {
    const me = st.players[meIdx()];
    const usable = me.research.some((c) => !c.used) || me.chaos.length;
    a.innerHTML = `<button class="btn big primary" data-act="roll">${who}주사위 굴리기</button>
      ${usable ? '<p class="hint small">카드는 굴리기 전에만 쓸 수 있어요</p>' : ''}`;
  } else if (sel) {
    const info = itemInfo(sel.tile);
    a.innerHTML = `<button class="btn big primary" data-act="go">${who}여기로 이동 (${sel.path.length}칸)</button>
      ${info ? `<p class="hint small">${esc(info)}</p>` : ''}`;
  } else {
    a.innerHTML = `<p class="hint">${who}주사위 <b>${st.turn.dice}</b> — 빛나는 칸 중 갈 곳을 누르세요</p>`;
  }
}

function cardHtml(c, kind) {
  const d = kind === 'chaos' ? cdef(c.def) : rdef(c.def);
  return `<button class="card ${kind}${c.used ? ' used' : ''}" data-act="card" data-iid="${c.iid}" style="--fc:${kind === 'chaos' ? '#1d2b33' : FIELD[d.field]}">
    <span class="c-top"><span class="c-ico">${d.icon}</span>
      <span class="c-pts">${kind === 'chaos' ? '카오스' : c.copy ? '복제' : d.pts + '점'}</span></span>
    <span class="c-name">${esc(d.name)}</span>
    <span class="c-desc">${esc(d.desc)}</span>
    ${c.used ? '<span class="c-used">사용함</span>' : ''}
  </button>`;
}

function renderHand() {
  const i = meIdx(), h = $('#hand');
  if (i < 0) { h.innerHTML = '<p class="hand-empty">관전 중이에요.</p>'; return; }
  const p = st.players[i];
  const cards = [...p.chaos.map((c) => cardHtml(c, 'chaos')),
    ...p.research.filter((c) => !c.used).map((c) => cardHtml(c, 'research')),
    ...p.research.filter((c) => c.used).map((c) => cardHtml(c, 'research'))];
  h.innerHTML = cards.length ? cards.join('') : '<p class="hand-empty">아직 카드가 없어요. 지도에서 연구를 먹으면 여기에 쌓여요.</p>';
}

function renderResult() {
  if (st.phase !== 'finished') {
    if (resultShownFor != null) { resultShownFor = null; closeModal(); }
    return;
  }
  if (resultShownFor === st.game && !$('#modal').hidden) return;
  resultShownFor = st.game;
  const medals = ['🥇', '🥈', '🥉', ''];
  const rows = st.result.map((i, k) => {
    const p = st.players[i];
    return `<li style="--pc:${COLORS[i % 4]}"><span class="r-medal">${medals[k] || ''}</span>
      <span class="r-name">${esc(p.name)}</span>
      <span class="r-total">${total(p)}점</span>
      <span class="r-sub">연구 ${p.research.filter((c) => !c.copy).length}개로 ${p.rp}점 · 카드 효과 ${p.bp >= 0 ? '+' : ''}${p.bp}점</span></li>`;
  }).join('');
  const w = st.players[st.result[0]];
  openModal(`<h2 class="res-title">${w ? esc(w.name) + ' 우승!' : '게임 종료'}</h2>
    <ol class="result">${rows}</ol>
    ${isHost() ? `<button class="btn big primary" data-act="again">같은 멤버로 다시 하기</button>
      <button class="btn" data-act="lobby">대기실로 돌아가기</button>`
    : '<p class="hint">방장이 다음 판을 정하는 중…</p>'}
    <button class="btn ghost" data-act="leave">방 나가기</button>`, true);
}

// ------------------------------------------------------------------ 타이머
function tick() {
  const el = $('#timer');
  if (!st || st.phase !== 'playing' || !st.turn.deadline) { if (el) el.textContent = ''; return; }
  const left = (Date.parse(st.turn.deadline) - (Date.now() + (isFinite(clockOff) ? clockOff : 0))) / 1000;
  if (el) { el.textContent = Math.max(0, Math.ceil(left)); el.classList.toggle('low', left <= 10); }
  const key = st.game + ':' + st.turn.n + ':' + st.turn.phase + ':' + st.turn.deadline;
  if (left < -0.7 && timeoutKey !== key && !animating) {
    timeoutKey = key;
    const wait = myTurn() ? 0 : 1200 + Math.random() * 1800;   // 여러 명이 동시에 부르지 않게 살짝 엇갈림
    setTimeout(() => {
      if (st && st.phase === 'playing' && key === st.game + ':' + st.turn.n + ':' + st.turn.phase + ':' + st.turn.deadline) {
        net.rpc('lab_timeout', { p_room: room.id }).then((r) => r && r.state && applyRoom(r)).catch(() => {});
      }
    }, wait);
  }
}
setInterval(tick, 250);

// ------------------------------------------------------------------ 카드 사용 흐름
function findMyCard(iid) {
  const p = st.players[meIdx()];
  if (!p) return null;
  const r = p.research.find((c) => c.iid === iid);
  if (r) return { c: r, d: rdef(r.def), kind: 'research' };
  const c = p.chaos.find((x) => x.iid === iid);
  return c ? { c, d: cdef(c.def), kind: 'chaos' } : null;
}

function bigCard(d, kind, sub) {
  return `<div class="bigcard ${kind}" style="--fc:${kind === 'chaos' ? '#1d2b33' : FIELD[d.field]}">
    <p class="bc-ico">${d.icon}</p><h3>${esc(d.name)}</h3>
    <p class="bc-meta">${kind === 'chaos' ? '카오스 카드' : esc(d.field) + ' · ' + (sub ? '복제본 (점수 없음)' : d.pts + '점')}</p>
    <p class="bc-desc">${esc(d.desc)}</p></div>`;
}

function openCard(iid) {
  const f = findMyCard(iid);
  if (!f) return;
  const { c, d, kind } = f;
  let why = '';
  if (c.used) why = '이미 사용한 능력이에요. 점수는 그대로 남아 있어요.';
  else if (!myTurn()) why = '내 차례가 오면 쓸 수 있어요.';
  else if (st.turn.phase !== 'roll') why = '카드는 주사위를 굴리기 전에만 쓸 수 있어요.';
  else if (animating) why = '잠시만요…';
  let body = '';
  if (!why && d.target === 'player') {
    const others = st.players.map((p, i) => i).filter((i) => i !== meIdx() && !st.players[i].gone);
    body = '<p class="pick-title">누구에게 쓸까요?</p>' + others.map((i) =>
      `<button class="btn pick" data-act="use" data-iid="${iid}" data-player="${i}" style="--pc:${COLORS[i % 4]}">
        <span class="dot" style="background:${COLORS[i % 4]}"></span>${esc(st.players[i].name)} <small>${total(st.players[i])}점</small></button>`).join('');
  } else if (!why && d.target === 'own_card') {
    const used = st.players[meIdx()].research.filter((x) => x.used);
    body = used.length ? '<p class="pick-title">어떤 능력을 되살릴까요?</p>' + used.map((x) =>
      `<button class="btn pick" data-act="use" data-iid="${iid}" data-card="${x.iid}">${rdef(x.def).icon} ${esc(rdef(x.def).name)}</button>`).join('')
      : '<p class="why">아직 사용한 능력이 없어서 되살릴 게 없어요.</p>';
  } else if (!why && d.target === 'tile') {
    body = `<button class="btn big primary" data-act="pick-tile" data-iid="${iid}">갈 칸 고르기</button>`;
  } else if (!why) {
    body = `<button class="btn big primary" data-act="use" data-iid="${iid}">사용하기</button>`;
  }
  openModal(`${bigCard(d, kind, c.copy)}${why ? `<p class="why">${why}</p>` : body}
    <button class="btn ghost" data-act="close">닫기</button>`);
}

function peek(i) {
  const p = st.players[i];
  const cards = [...p.chaos.map((c) => cardHtml(c, 'chaos')), ...p.research.map((c) => cardHtml(c, 'research'))];
  openModal(`<h2 class="peek-title"><span class="dot" style="background:${COLORS[i % 4]}"></span>${esc(p.name)} · ${total(p)}점</h2>
    <p class="hint small">연구 점수 ${p.rp} · 카드 효과 ${p.bp >= 0 ? '+' : ''}${p.bp}</p>
    <div class="peek-cards">${cards.join('') || '<p class="hand-empty">카드가 없어요.</p>'}</div>
    <button class="btn ghost" data-act="close">닫기</button>`);
}

const RULES = `<h2>게임 방법</h2>
  <ol class="rules">
    <li><b>주사위를 굴려 이동해요.</b> 나온 수만큼까지 길을 따라 움직이고, 원하는 칸에서 멈출 수 있어요.</li>
    <li><b>연구를 밟으면 내 것.</b> 점수를 얻고, 한 번 쓸 수 있는 능력도 생겨요.</li>
    <li><b>능력은 내 차례, 주사위를 굴리기 전에 써요.</b> 상대를 날려버리거나 내 주사위를 키울 수 있어요.</li>
    <li><b>가끔 카오스 카드가 나타나요.</b> 먼저 밟은 사람이 가져가고, 쓰면 판이 뒤집혀요.</li>
    <li><b>마지막 라운드가 끝났을 때 점수가 가장 높은 사람이 이겨요.</b></li>
  </ol>
  <p class="hint small">모서리의 포털 A끼리, B끼리는 한 칸으로 이어져 있어요. 한 턴은 45초예요.</p>
  <button class="btn primary" data-act="close">알겠어요</button>`;

// ------------------------------------------------------------------ 클릭 처리
document.addEventListener('click', async (ev) => {
  const el = ev.target.closest('[data-act]');
  if (!el) {
    if (ev.target.id === 'modal' && !$('#modal').dataset.sticky) closeModal();
    return;
  }
  const act = el.dataset.act;
  if (act === 'close') return closeModal();
  if (act === 'rules') return openModal(RULES);
  if (act === 'menu') {
    return openModal(`<h2>메뉴</h2>
      <button class="btn" data-act="rules">게임 방법</button>
      <button class="btn" data-act="mute">소리 ${muted ? '켜기' : '끄기'}</button>
      <button class="btn danger" data-act="leave">방 나가기</button>
      <button class="btn ghost" data-act="close">닫기</button>`);
  }
  if (act === 'mute') { muted = !muted; localStorage.setItem('lab_muted', muted ? '1' : '0'); return closeModal(); }
  if (!st || !room) return;
  if (act === 'leave') {
    try { await net.rpc('lab_leave_room', { p_room: room.id }); } catch (e) { /* 이미 없는 방이면 그냥 나감 */ }
    return goHome();
  }
  if (act === 'kick') return net.rpc('lab_kick', { p_room: room.id, p_user: el.dataset.uid }).catch((e) => toast(errText(e), 'err'));
  if (act === 'again') return call('lab_start_game', { p_room: room.id });
  if (act === 'lobby') return call('lab_to_lobby', { p_room: room.id });
  if (act === 'peek') return peek(Number(el.dataset.p));
  if (act === 'card') return openCard(el.dataset.iid);
  if (act === 'roll') return call('lab_roll', { p_room: room.id });
  if (act === 'go' && sel) return call('lab_move', { p_room: room.id, p_path: sel.path });
  if (act === 'cancel-target') { targetMode = null; renderBoard(); return renderAction(); }
  if (act === 'pick-tile') {
    targetMode = { iid: el.dataset.iid, tiles: teleportTiles() };
    closeModal(); renderBoard(); return renderAction();
  }
  if (act === 'use') {
    const tg = {};
    if (el.dataset.player != null) tg.player = Number(el.dataset.player);
    if (el.dataset.card) tg.card = el.dataset.card;
    closeModal();
    return call('lab_use_card', { p_room: room.id, p_iid: el.dataset.iid, p_target: tg });
  }
});

// 지도 칸 누르기
$('#board').addEventListener('click', (ev) => {
  if (pz.dragged || !st || st.phase !== 'playing' || animating) return;
  const g = ev.target.closest('[data-tile]');
  if (!g) return;
  const t = Number(g.dataset.tile);
  if (targetMode) {
    if (!targetMode.tiles.has(t)) return toast('보라색으로 표시된 칸만 고를 수 있어요.');
    const iid = targetMode.iid;
    targetMode = null;
    return call('lab_use_card', { p_room: room.id, p_iid: iid, p_target: { tile: t } });
  }
  if (myTurn() && st.turn.phase === 'move') {
    const r = reach();
    if (t === r.start || r.dist[t] === undefined) return toast(`주사위 ${st.turn.dice}(으)로는 갈 수 없는 칸이에요.`);
    if (sel && sel.tile === t) return call('lab_move', { p_room: room.id, p_path: sel.path });
    sel = { tile: t, path: pathTo(r, t) };
    renderBoard(); renderAction();
    return;
  }
  const info = itemInfo(t);
  if (info) toast(info);
});

// ------------------------------------------------------------------ 지도 확대 / 이동
const pz = { k: 1, x: 0, y: 0, dragged: false, pts: new Map(), last: null };
const wrap = $('#boardWrap');
function applyPz() {
  const W = wrap.clientWidth, H = wrap.clientHeight;
  pz.k = Math.min(3, Math.max(1, pz.k));
  pz.x = Math.min(0, Math.max(W * (1 - pz.k), pz.x));
  pz.y = Math.min(0, Math.max(H * (1 - pz.k), pz.y));
  $('#board').style.transform = `translate(${pz.x}px, ${pz.y}px) scale(${pz.k})`;
  wrap.classList.toggle('zoomed', pz.k > 1.01);
}
function zoomAt(f, px, py) {
  const k0 = pz.k, k1 = Math.min(3, Math.max(1, k0 * f));
  pz.x = px - (px - pz.x) * (k1 / k0);
  pz.y = py - (py - pz.y) * (k1 / k0);
  pz.k = k1;
  applyPz();
}
function fitBoard() { pz.k = 1; pz.x = 0; pz.y = 0; applyPz(); }
wrap.addEventListener('pointerdown', (e) => {
  pz.pts.set(e.pointerId, { x: e.clientX, y: e.clientY });
  pz.dragged = false; pz.moved = 0;
});
wrap.addEventListener('pointermove', (e) => {
  if (!pz.pts.has(e.pointerId)) return;
  const prev = pz.pts.get(e.pointerId), cur = { x: e.clientX, y: e.clientY };
  const rect = wrap.getBoundingClientRect();
  if (pz.pts.size === 1) {
    pz.moved += Math.abs(cur.x - prev.x) + Math.abs(cur.y - prev.y);
    if (pz.moved > 8) pz.dragged = true;
    if (pz.k > 1) { pz.x += cur.x - prev.x; pz.y += cur.y - prev.y; applyPz(); }
  } else if (pz.pts.size === 2) {
    const other = [...pz.pts.entries()].find(([id]) => id !== e.pointerId)[1];
    const d0 = Math.hypot(prev.x - other.x, prev.y - other.y), d1 = Math.hypot(cur.x - other.x, cur.y - other.y);
    pz.dragged = true;
    if (d0 > 0) zoomAt(d1 / d0, (cur.x + other.x) / 2 - rect.left, (cur.y + other.y) / 2 - rect.top);
  }
  pz.pts.set(e.pointerId, cur);
});
const pzUp = (e) => { pz.pts.delete(e.pointerId); setTimeout(() => { if (!pz.pts.size) pz.dragged = false; }, 0); };
wrap.addEventListener('pointerup', pzUp);
wrap.addEventListener('pointercancel', pzUp);
wrap.addEventListener('wheel', (e) => {
  e.preventDefault();
  const rect = wrap.getBoundingClientRect();
  zoomAt(e.deltaY < 0 ? 1.15 : 1 / 1.15, e.clientX - rect.left, e.clientY - rect.top);
}, { passive: false });
$('#zoomBtns').addEventListener('click', (e) => {
  const z = e.target.dataset.zoom;
  if (z == null) return;
  if (z === '0') return fitBoard();
  zoomAt(z === '1' ? 1.4 : 1 / 1.4, wrap.clientWidth / 2, wrap.clientHeight / 2);
});
window.addEventListener('resize', applyPz);

// ------------------------------------------------------------------ 첫 화면
const nickEl = $('#nick'), codeEl = $('#code'), statusEl = $('#netStatus');
nickEl.value = localStorage.getItem('lab_nick') || '';
const qp = new URLSearchParams(location.search).get('room');
if (qp) codeEl.value = qp.toUpperCase().slice(0, 5);

function nick() {
  const n = nickEl.value.trim();
  if (!n) { toast('닉네임을 먼저 입력해 주세요.', 'err'); nickEl.focus(); return null; }
  localStorage.setItem('lab_nick', n);
  return n;
}

let connecting = null;
function connect() {
  if (onlineNet) return Promise.resolve(onlineNet);
  if (!connecting) {
    statusEl.textContent = '서버에 연결하는 중…';
    statusEl.className = 'net-status';
    connecting = createOnline().then((n) => {
      onlineNet = n;
      statusEl.textContent = '서버 연결됨';
      statusEl.className = 'net-status ok';
      return n;
    }).catch((e) => {
      statusEl.textContent = errText(e);
      statusEl.className = 'net-status bad';
      connecting = null;
      throw e;
    });
  }
  return connecting;
}

async function online(fn, args) {
  const n = nick();
  if (!n) return;
  try {
    const o = await connect();
    const r = await o.rpc(fn, { ...args, p_nickname: n });
    await enter(o, r);
  } catch (e) { toast(errText(e), 'err'); }
}
$('#btnCreate').addEventListener('click', () => online('lab_create_room', {}));
$('#btnJoin').addEventListener('click', () => {
  const c = codeEl.value.trim().toUpperCase();
  if (c.length < 5) { toast('방 코드 5자리를 입력해 주세요.', 'err'); return codeEl.focus(); }
  online('lab_join_room', { p_code: c });
});
codeEl.addEventListener('keydown', (e) => { if (e.key === 'Enter') $('#btnJoin').click(); });
$('#btnRules').addEventListener('click', () => openModal(RULES));

for (const b of document.querySelectorAll('[data-local]')) {
  b.addEventListener('click', async () => {
    const n = Number(b.dataset.local);
    const pool = ['뉴턴', '퀴리', '다윈', '튜링'];
    const names = pool.slice(0, n);
    if (nickEl.value.trim()) names[0] = nickEl.value.trim().slice(0, 12);
    startLocal(b, names, false);
  });
}

// 혼자 하기: 나 + AI 1~3명
for (const b of document.querySelectorAll('[data-solo]')) {
  b.addEventListener('click', () => {
    const me = (nickEl.value.trim() || '나').slice(0, 12);
    if (nickEl.value.trim()) localStorage.setItem('lab_nick', nickEl.value.trim());
    const bots = ['퀴리봇', '다윈봇', '튜링봇'].filter((x) => x !== me).slice(0, Number(b.dataset.solo));
    startLocal(b, [me, ...bots], true);
  });
}

async function startLocal(b, names, solo) {
  const old = b.textContent;
  b.disabled = true; b.textContent = '준비 중…';
  try {
    const l = await createLocal(names, solo);
    const r = await l.quickRoom();
    await enter(l, r);
    await call('lab_start_game', { p_room: r.id });
  } catch (e) {
    console.error(e);
    toast('게임을 시작하지 못했어요: ' + (e.message || e), 'err');
  } finally { b.disabled = false; b.textContent = old; }
}

$('#btnStart').addEventListener('click', () => call('lab_start_game', { p_room: room.id }));
$('#btnLeaveLobby').addEventListener('click', async () => {
  try { await net.rpc('lab_leave_room', { p_room: room.id }); } catch (e) { /* 무시 */ }
  goHome();
});
$('#btnCopy').addEventListener('click', async () => {
  const url = `${location.origin}${location.pathname}?room=${room.code}`;
  try { await navigator.clipboard.writeText(url); toast('초대 링크를 복사했어요.'); }
  catch (e) { toast('방 코드: ' + room.code); }
});

// 시작: 서버 연결 + 진행 중이던 방이 있으면 자동 복귀
connect().then(async (o) => {
  const r = await o.myRoom();
  if (r && !room) { await enter(o, r); toast('진행 중이던 방으로 돌아왔어요.'); }
}).catch(() => {});
window.__lab = () => ({ st, S, room, animating });
