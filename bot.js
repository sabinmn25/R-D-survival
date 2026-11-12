// AI 상대의 판단. 화면과 무관한 순수 함수라서 서버 규칙(SQL)은 건드리지 않습니다.
// decide(st, S, i, skip) → { fn, args, iid? } : i번 플레이어가 지금 부를 서버 함수.

const total = (p) => Math.max(p.rp + p.bp, 0);
const CHAOS_VALUE = 6;           // 카오스 카드 한 장을 연구 몇 점짜리로 칠지
const DICE_AVG = 3;              // "가까이"의 기준

function bfs(T, start, max = Infinity) {
  const dist = { [start]: 0 }, prev = {}, q = [start];
  while (q.length) {
    const c = q.shift();
    if (dist[c] >= max) continue;
    for (const n of T[c].n) if (dist[n] === undefined) { dist[n] = dist[c] + 1; prev[n] = c; q.push(n); }
  }
  return { dist, prev };
}

// 지도 위 물건들: [{tile, val}]
function items(st, S, p) {
  const out = {};
  const dbl = p.fx && p.fx.double ? 2 : 1;
  for (const [k, c] of Object.entries(st.board.research)) {
    const d = S.research.find((x) => x.id === c.def);
    out[k] = (out[k] || 0) + (d ? d.pts : 1) * dbl;
  }
  for (const k of Object.keys(st.board.chaos)) out[k] = (out[k] || 0) + CHAOS_VALUE;
  return Object.entries(out).map(([k, v]) => ({ tile: Number(k), val: v }));
}

function chooseMove(st, S, i) {
  const T = S.map.tiles, p = st.players[i], D = st.turn.dice;
  const its = items(st, S, p);
  const near = bfs(T, p.pos, D);
  const lastTurn = st.turn.round >= st.rounds && !(p.fx && p.fx.extra);
  let best = null;
  for (const k of Object.keys(near.dist)) {
    const t = Number(k);
    if (t === p.pos) continue;
    const here = its.find((x) => x.tile === t);
    let score = here ? here.val * 10 : 0;
    if (!lastTurn) {
      const from = bfs(T, t).dist;
      let fut = 0;
      for (const it of its) {
        if (it.tile === t || from[it.tile] === undefined) continue;
        fut = Math.max(fut, it.val / (1 + from[it.tile]));
      }
      score += fut * 4;
    }
    score += Math.random() * 0.5;
    if (!best || score > best.score) best = { t, score };
  }
  const path = [];
  for (let c = best.t; c !== p.pos; c = near.prev[c]) path.unshift(c);
  return path;
}

// 이 카드를 지금 쓸까? 쓸 거면 대상(target 객체), 아니면 null
function wantUse(st, S, i, d, ctx) {
  const p = st.players[i], f = p.fx || {};
  const { others, leader, mine, lead, avg, lowest, nearest, its, T } = ctx;
  const final = st.turn.round >= st.rounds;
  const diceSet = f.six || f.adv || f.plus || f.one;
  const far = nearest > DICE_AVG && nearest < 99;
  switch (d.fx) {
    // ----- 연구 능력
    case 'plus2': case 'evolve': case 'extra_turn': case 'synth': case 'aoe_minus': return {};
    case 'per_card': return p.research.length >= 5 || final ? {} : null;
    case 'dice_plus': case 'dice_six': case 'dice_adv': return far && !diceSet ? {} : null;
    case 'double_next': return !f.double && st.board.research && Object.keys(st.board.research).length ? {} : null;
    case 'shuffle_board': return nearest >= 5 && nearest < 99 ? {} : null;
    case 'teleport': {
      const me = T[p.pos], R = Number(st.cfg.teleport_radius);
      const c = its.filter((x) => x.tile !== p.pos && x.val >= 4 && ctx.dist[x.tile] > DICE_AVG
        && Math.hypot(T[x.tile].x - me.x, T[x.tile].y - me.y) <= R).sort((a, b) => b.val - a.val)[0];
      return c ? { tile: c.tile } : null;
    }
    case 'recharge': {
      const used = p.research.filter((c) => c.used && c.def !== d.id);
      if (!used.length) return null;
      used.sort((a, b) => (b.pts || 0) - (a.pts || 0));
      return { card: used[0].iid };
    }
    case 'dice_minus': case 'blast': return leader != null && lead >= mine ? { player: leader } : null;
    case 'copy': case 'break': {
      const t = others.filter((o) => st.players[o].research.some((c) => !c.used))
        .sort((a, b) => total(st.players[b]) - total(st.players[a]))[0];
      return t != null ? { player: t } : null;
    }
    case 'pull': case 'swap': return null;
    // ----- 카오스 카드
    case 'embezzle': case 'extra2': case 'eureka': return {};
    case 'revolution': return lead - mine >= 3 ? {} : null;
    case 'double': return mine >= 6 || (final && mine > 0) ? {} : null;
    case 'scatter': return nearest >= 5 && nearest < 99 ? {} : null;
    case 'plagiarize': {
      const t = others.filter((o) => st.players[o].research.some((c) => !c.copy))
        .sort((a, b) => Math.max(...st.players[b].research.map((c) => c.pts || 0))
          - Math.max(...st.players[a].research.map((c) => c.pts || 0)))[0];
      return t != null ? { player: t } : null;
    }
    case 'halve_all': case 'average': return mine < avg ? {} : null;
    case 'permute': case 'reverse': return lowest && lead > mine ? {} : null;
    case 'force_one': return leader != null ? { player: leader } : null;
    case 'nobel': return leader != null && lead >= 5 ? { player: leader } : null;
    case 'recharge_all': return p.research.filter((c) => c.used).length >= 2 ? {} : null;
    case 'purge': return others.reduce((n, o) => n + st.players[o].research.filter((c) => !c.used).length, 0) >= 2 ? {} : null;
    case 'halve_leader': return lead > mine && lead >= 6 ? {} : null;
    case 'schrodinger': return (lead - mine >= 6 || mine <= 2) ? {} : null;
    default: return null;
  }
}

export function decide(st, S, i, skip = new Set()) {
  const p = st.players[i];
  if (st.turn.phase === 'move') return { fn: 'lab_move', args: { p_path: chooseMove(st, S, i) } };

  const T = S.map.tiles;
  const others = st.players.map((_, k) => k).filter((k) => k !== i && !st.players[k].gone);
  const leader = others.length ? others.reduce((a, b) => (total(st.players[b]) > total(st.players[a]) ? b : a)) : null;
  const mine = total(p), lead = leader != null ? total(st.players[leader]) : 0;
  const all = [i, ...others].map((k) => total(st.players[k]));
  const its = items(st, S, p), dist = bfs(T, p.pos).dist;
  const ctx = {
    T, others, leader, mine, lead, its, dist,
    avg: all.reduce((a, b) => a + b, 0) / all.length,
    lowest: others.every((o) => total(st.players[o]) >= mine),
    nearest: its.reduce((m, x) => Math.min(m, dist[x.tile] === undefined || x.tile === p.pos ? 99 : dist[x.tile]), 99),
  };
  const hand = [
    ...p.chaos.map((c) => ({ c, d: S.chaos.find((x) => x.id === c.def) })),
    ...p.research.filter((c) => !c.used).map((c) => ({ c, d: S.research.find((x) => x.id === c.def) })),
  ];
  for (const { c, d } of hand) {
    if (!d || skip.has(c.iid)) continue;
    const tg = wantUse(st, S, i, d, ctx);
    if (tg) return { fn: 'lab_use_card', args: { p_iid: c.iid, p_target: tg }, iid: c.iid };
  }
  return { fn: 'lab_roll', args: {} };
}
