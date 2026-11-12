// 백엔드 두 가지: 온라인(Supabase) / 로컬 테스트(브라우저 내장 Postgres).
// 둘 다 같은 SQL(sql/supabase_setup.sql)의 lab_* 함수를 부르므로 게임 규칙은 한 곳에만 있습니다.
import { CONFIG } from './config.js';

const ERR = {
  NOT_AUTHENTICATED: '로그인 정보가 없어요. 새로고침해 주세요.',
  ROOM_NOT_FOUND: '그런 방이 없어요. 코드를 다시 확인해 주세요.',
  ROOM_FULL: '방이 가득 찼어요.',
  GAME_ALREADY_STARTED: '이미 게임이 시작된 방이에요.',
  BAD_NICKNAME: '닉네임을 1~12자로 입력해 주세요.',
  NOT_HOST: '방장만 할 수 있어요.',
  NOT_ENOUGH_PLAYERS: '인원이 부족해요. 2명 이상 모여야 시작할 수 있어요.',
  NOT_A_MEMBER: '이 방의 참가자가 아니에요.',
  NOT_YOUR_TURN: '지금은 내 차례가 아니에요.',
  WRONG_PHASE: '지금은 할 수 없는 행동이에요.',
  NOT_PLAYING: '게임이 진행 중이 아니에요.',
  BAD_PATH: '그 칸으로는 갈 수 없어요.',
  BAD_TARGET: '대상을 다시 골라 주세요.',
  TOO_FAR: '너무 먼 칸이에요.',
  ALREADY_USED: '이미 사용한 능력이에요.',
  CARD_NOT_FOUND: '그 카드는 이제 없어요.',
  ALREADY_PLAYING: '이미 게임이 진행 중이에요.',
  NOT_FINISHED: '게임이 끝난 뒤에만 할 수 있어요.',
  'Anonymous sign-ins are disabled': 'Supabase에서 익명 로그인이 꺼져 있어요. Authentication → Sign In / Providers → Allow anonymous sign-ins 를 켜 주세요.',
  'Failed to fetch': '서버에 연결하지 못했어요. 인터넷 연결을 확인해 주세요.',
};

export function errText(e) {
  const m = String((e && (e.message || e.error_description || e.msg)) || e || '');
  const k = Object.keys(ERR).find((k) => m.includes(k));
  return k ? ERR[k] : '문제가 생겼어요: ' + m;
}

// ------------------------------------------------------------------ 온라인
export async function createOnline() {
  const { createClient } = await import(CONFIG.SUPABASE_JS_URL);
  const sb = createClient(CONFIG.SUPABASE_URL, CONFIG.SUPABASE_KEY);

  let { data: { session } } = await sb.auth.getSession();
  if (!session) {
    const { data, error } = await sb.auth.signInAnonymously();
    if (error) throw error;
    session = data.session;
  }
  const uid = session.user.id;
  let channel = null;
  let poll = null;

  const net = {
    mode: 'online',
    uid: () => uid,
    setActor() {},
    async rpc(fn, args = {}) {
      const { data, error } = await sb.rpc(fn, args);
      if (error) throw error;
      return data;
    },
    static: () => net.rpc('lab_static'),
    // 내가 들어가 있는 진행 중인 방 (재접속용)
    async myRoom() {
      const { data, error } = await sb.from('lab_rooms').select('*')
        .in('status', ['lobby', 'playing']).order('updated_at', { ascending: false }).limit(1);
      if (error) throw error;
      return data[0] || null;
    },
    async fetchRoom(id) {
      const { data, error } = await sb.from('lab_rooms').select('*').eq('id', id).maybeSingle();
      if (error) throw error;
      return data; // 방이 사라졌거나 내가 빠졌으면 null
    },
    watch(id, cb) {
      net.unwatch();
      channel = sb.channel('room-' + id)
        .on('postgres_changes', { event: '*', schema: 'public', table: 'lab_rooms', filter: 'id=eq.' + id }, (p) => {
          if (p.eventType === 'DELETE') return cb(null);
          if (p.new && p.new.state && p.new.state.phase) return cb(p.new);
          net.fetchRoom(id).then(cb).catch(() => {});
        })
        .subscribe();
      // 실시간 연결이 끊겨도 상태가 어긋나지 않도록 주기적으로 확인
      poll = setInterval(() => { net.fetchRoom(id).then(cb).catch(() => {}); }, 4000);
    },
    unwatch() {
      if (channel) { sb.removeChannel(channel); channel = null; }
      if (poll) { clearInterval(poll); poll = null; }
    },
  };
  return net;
}

// ------------------------------------------------------------------ 로컬 테스트
const PRELUDE = `
create schema auth;
create table auth.users(id uuid primary key);
create function auth.uid() returns uuid language sql stable as $$
  select nullif(current_setting('test.uid', true), '')::uuid $$;
create role anon; create role authenticated;
`;
const CAST = { p_room: 'uuid', p_user: 'uuid', p_path: 'int[]', p_target: 'jsonb' };

export async function createLocal(names) {
  const { PGlite } = await import(CONFIG.PGLITE_URL);
  const db = new PGlite();
  await db.exec(PRELUDE);
  const sql = await (await fetch('sql/supabase_setup.sql')).text();
  await db.exec(sql);

  const uids = names.map((_, i) => `00000000-0000-4000-8000-00000000000${i + 1}`);
  for (const u of uids) await db.query('insert into auth.users values ($1)', [u]);
  let actor = uids[0];

  async function call(u, fn, args = {}) {
    await db.query(`select set_config('test.uid', $1, false)`, [u]);
    const keys = Object.keys(args);
    const vals = keys.map((k) => {
      const v = args[k];
      if (Array.isArray(v)) return '{' + v.join(',') + '}';
      if (v && typeof v === 'object') return JSON.stringify(v);
      return v;
    });
    const params = keys.map((k, i) => `${k} => $${i + 1}::${CAST[k] || 'text'}`).join(', ');
    if (fn === 'lab_leave_room' || fn === 'lab_kick') {
      await db.query(`select public.${fn}(${params})`, vals);
      return null;
    }
    const res = await db.query(`select to_jsonb(x) as r from public.${fn}(${params}) x`, vals);
    return res.rows[0] ? res.rows[0].r : null;
  }

  const net = {
    mode: 'local',
    uids,
    uid: () => actor,
    setActor(u) { actor = u; },
    rpc: (fn, args) => call(actor, fn, args),
    async static() {
      await db.query(`select set_config('test.uid', $1, false)`, [actor]);
      return (await db.query('select public.lab_static() as s')).rows[0].s;
    },
    async myRoom() { return null; },
    async fetchRoom(id) {
      const r = await db.query('select to_jsonb(r) as r from public.lab_rooms r where id = $1', [id]);
      return r.rows[0] ? r.rows[0].r : null;
    },
    watch() {},
    unwatch() {},
    // 한 기기에서 여러 명: 방 만들고 전원 입장까지 한 번에
    async quickRoom() {
      let room = await call(uids[0], 'lab_create_room', { p_nickname: names[0] });
      for (let i = 1; i < names.length; i++) {
        room = await call(uids[i], 'lab_join_room', { p_code: room.code, p_nickname: names[i] });
      }
      return room;
    },
  };
  return net;
}
