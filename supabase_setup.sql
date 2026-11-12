-- =====================================================================
--  과학 연구 쟁탈전 — 카오스 보드게임 :: Supabase 전체 세팅 SQL
--  사용법: Supabase 대시보드 > SQL Editor 에 전체 붙여넣고 Run (한 번이면 끝)
--  다시 실행해도 안전합니다(함수/설정은 덮어쓰고, 진행 중인 방 데이터는 유지).
--
--  구조 요약
--   - lab_rooms   : 방 1개 = 행 1개. 게임 전체 상태가 state(jsonb) 한 칸에 들어있음
--   - lab_members : 방 참가자 (RLS 판정용)
--   - lab_config  : 밸런스 설정값 (Table Editor에서 숫자만 고치면 다음 판부터 적용)
--   - 모든 판정(주사위/이동/카드/점수)은 아래 lab_* 함수(RPC)에서만 처리
--   - 클라이언트는 테이블을 직접 수정할 수 없음 (읽기만 가능, 그것도 자기 방만)
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. 테이블
-- ---------------------------------------------------------------------
create table if not exists public.lab_rooms (
  id         uuid primary key default gen_random_uuid(),
  code       text not null unique,
  host_id    uuid not null,
  status     text not null default 'lobby' check (status in ('lobby','playing','finished')),
  state      jsonb not null default '{}'::jsonb,
  version    bigint not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.lab_members (
  room_id   uuid not null references public.lab_rooms(id) on delete cascade,
  user_id   uuid not null references auth.users(id) on delete cascade,
  nickname  text not null,
  joined_at timestamptz not null default now(),
  primary key (room_id, user_id)
);
create index if not exists lab_members_user_idx on public.lab_members(user_id);

create table if not exists public.lab_config (
  key   text primary key,
  value jsonb not null,
  note  text
);

-- 기본 설정값 (이미 있으면 건드리지 않음 → 직접 고친 값이 유지됨)
insert into public.lab_config(key, value, note) values
  ('min_players',            '2',     '게임 시작 최소 인원 (혼자 테스트하려면 1)'),
  ('max_players',            '4',     '방 최대 인원'),
  ('rounds_by_players',      '{"1":6,"2":10,"3":8,"4":7}', '인원수별 전체 라운드 수'),
  ('turn_seconds',           '45',    '한 턴 제한 시간(초). 지나면 누구든 자동 넘김 가능'),
  ('afk_turn_seconds',       '10',    '2턴 연속 잠수한 플레이어의 제한 시간(초)'),
  ('dice_max',               '6',     '주사위 최대 눈'),
  ('research_initial',       '12',    '시작 시 지도에 깔리는 연구 수'),
  ('research_min',           '7',     '라운드가 끝날 때 지도 위 연구가 이보다 적으면 보충'),
  ('teleport_radius',        '2.5',   '양자 터널링 이동 가능 반경(칸 좌표 거리)'),
  ('chaos_start_turn',       '2',     '게임 시작 후 이 턴 수가 지나야 카오스 등장 가능'),
  ('chaos_base',             '0.15',  '턴 종료마다 카오스 카드 등장 기본 확률'),
  ('chaos_ramp',             '0.08',  '안 나올 때마다 턴당 더해지는 확률'),
  ('chaos_max_on_board',     '2',     '지도 위에 동시에 존재할 수 있는 카오스 카드 수'),
  ('chaos_allow_duplicates', 'false', '한 게임에서 같은 카오스 카드가 또 나와도 되는지'),
  ('chaos_catchup',          'true',  'true면 카오스 카드가 1등에게서 먼 쪽에 등장')
on conflict (key) do nothing;

-- ---------------------------------------------------------------------
-- 2. RLS (행 수준 보안)
-- ---------------------------------------------------------------------
create or replace function public.lab_is_member(p_room uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.lab_members where room_id = p_room and user_id = auth.uid());
$$;

alter table public.lab_rooms   enable row level security;
alter table public.lab_members enable row level security;
alter table public.lab_config  enable row level security;

drop policy if exists lab_rooms_select   on public.lab_rooms;
drop policy if exists lab_members_select on public.lab_members;
drop policy if exists lab_config_select  on public.lab_config;

create policy lab_rooms_select   on public.lab_rooms   for select to authenticated using (public.lab_is_member(id));
create policy lab_members_select on public.lab_members for select to authenticated using (public.lab_is_member(room_id));
create policy lab_config_select  on public.lab_config  for select to authenticated using (true);
-- insert / update / delete 정책은 일부러 만들지 않음 → 클라이언트 직접 쓰기 전부 차단

revoke all on public.lab_rooms, public.lab_members, public.lab_config from anon, authenticated;
grant select on public.lab_rooms, public.lab_members, public.lab_config to authenticated;

-- ---------------------------------------------------------------------
-- 3. Realtime (방 상태 변경을 실시간으로 받기)
-- ---------------------------------------------------------------------
alter table public.lab_rooms replica identity full;
do $$
begin
  if not exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    create publication supabase_realtime;
  end if;
  if not exists (select 1 from pg_publication_tables
                 where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'lab_rooms') then
    alter publication supabase_realtime add table public.lab_rooms;
  end if;
end $$;

-- ---------------------------------------------------------------------
-- 4. 정적 데이터: 지도 / 연구 카드 / 카오스 카드
--    (클라이언트도 lab_static() 으로 이걸 받아서 그리므로 여기만 고치면 됨)
-- ---------------------------------------------------------------------
-- 지도: 8 x 6 격자 위의 39칸. e = 길(인접), p = 포털(지름길)
create or replace function public.lab_map()
returns jsonb language sql immutable as $$
  with t(id, x, y) as (values
    (0,0,0),(1,1,0),(2,2,0),(3,4,0),(4,5,0),(5,6,0),(6,7,0),
    (7,0,1),(8,2,1),(9,3,1),(10,4,1),(11,6,1),(12,7,1),
    (13,0,2),(14,1,2),(15,3,2),(16,4,2),(17,5,2),(18,6,2),(19,7,2),
    (20,0,3),(21,1,3),(22,2,3),(23,3,3),(24,5,3),(25,6,3),(26,7,3),
    (27,0,4),(28,2,4),(29,3,4),(30,4,4),(31,5,4),(32,7,4),
    (33,0,5),(34,1,5),(35,2,5),(36,5,5),(37,6,5),(38,7,5)
  ),
  e(a, b) as (values
    (0,1),(1,2),(3,4),(4,5),(5,6),
    (0,7),(2,8),(3,10),(6,12),
    (8,9),(9,10),
    (7,13),(9,15),(11,18),(12,19),
    (13,14),(15,16),(16,17),(17,18),(18,19),
    (14,21),(15,23),(17,24),
    (20,21),(21,22),(22,23),(24,25),(25,26),
    (20,27),(22,28),(24,31),(26,32),
    (29,30),(30,31),
    (27,33),(28,35),(31,36),(32,38),
    (33,34),(34,35),(36,37),(37,38)
  ),
  p(a, b) as (values (0,38),(6,33)),
  link(a, b) as (
    select a, b from e union select b, a from e union select a, b from p union select b, a from p
  )
  select jsonb_build_object(
    'w', 8, 'h', 6,
    'starts', '[[1,13],[4,12],[27,34],[25,37]]'::jsonb,   -- 구역별 시작 후보 칸
    'tiles', (
      select jsonb_agg(jsonb_build_object(
        'id', t.id, 'x', t.x, 'y', t.y,
        'zone', (case when t.y <= 2 then 0 else 2 end) + (case when t.x <= 3 then 0 else 1 end),
        'n', (select jsonb_agg(l.b order by l.b) from link l where l.a = t.id),
        'portal', (select case when pp.a = t.id then pp.b else pp.a end from p pp where pp.a = t.id or pp.b = t.id)
      ) order by t.id) from t)
  );
$$;

-- 연구 카드. target: none | player(상대 지정) | tile(칸 지정) | own_card(내 카드 지정)
create or replace function public.lab_research_defs()
returns jsonb language sql immutable as $$ select $j$[
 {"id":"r_em",    "name":"전자기학",       "field":"물리학",     "pts":2, "icon":"🧲", "fx":"dice_plus",     "target":"none",     "desc":"다음 주사위 +2"},
 {"id":"r_rel",   "name":"상대성이론",     "field":"물리학",     "pts":4, "icon":"⏱️", "fx":"extra_turn",    "target":"none",     "desc":"이번 턴이 끝나면 한 턴 더 한다"},
 {"id":"r_tunnel","name":"양자 터널링",    "field":"물리학",     "pts":4, "icon":"🌀", "fx":"teleport",      "target":"tile",     "desc":"가까운 칸으로 벽을 뚫고 순간이동 (도착 칸의 카드도 먹는다)"},
 {"id":"r_bh",    "name":"블랙홀",         "field":"천문학",     "pts":5, "icon":"🕳️", "fx":"pull",          "target":"player",   "desc":"상대 한 명을 내 칸으로 끌어온다"},
 {"id":"r_dark",  "name":"암흑물질",       "field":"천문학",     "pts":3, "icon":"🌑", "fx":"dice_minus",    "target":"player",   "desc":"상대 한 명의 다음 주사위 -3"},
 {"id":"r_nova",  "name":"초신성 폭발",    "field":"천문학",     "pts":4, "icon":"💥", "fx":"aoe_minus",     "target":"none",     "desc":"나를 뺀 모두 -2점"},
 {"id":"r_cat",   "name":"촉매 반응",      "field":"화학",       "pts":3, "icon":"⚗️", "fx":"double_next",   "target":"none",     "desc":"다음에 먹는 연구의 점수 2배"},
 {"id":"r_ent",   "name":"엔트로피 증가",  "field":"화학",       "pts":2, "icon":"🌪️", "fx":"shuffle_board", "target":"none",     "desc":"지도 위 모든 연구의 위치를 뒤섞는다"},
 {"id":"r_boom",  "name":"폭발 반응",      "field":"화학",       "pts":3, "icon":"🧨", "fx":"blast",         "target":"player",   "desc":"상대 한 명을 무작위 칸으로 날려버린다"},
 {"id":"r_synth", "name":"원소 합성",      "field":"화학",       "pts":1, "icon":"🧪", "fx":"synth",         "target":"none",     "desc":"내 옆 칸에 새 연구를 하나 만들어낸다"},
 {"id":"r_mut",   "name":"유전자 변이",    "field":"생물학",     "pts":3, "icon":"🧬", "fx":"recharge",      "target":"own_card", "desc":"이미 쓴 내 연구 능력 하나를 재충전"},
 {"id":"r_photo", "name":"광합성",         "field":"생물학",     "pts":1, "icon":"🌱", "fx":"plus2",         "target":"none",     "desc":"즉시 +2점"},
 {"id":"r_evo",   "name":"진화론",         "field":"생물학",     "pts":2, "icon":"🦎", "fx":"evolve",        "target":"none",     "desc":"단독 꼴찌면 +5점, 아니면 +1점"},
 {"id":"r_swap",  "name":"해킹",           "field":"컴퓨터과학", "pts":3, "icon":"💻", "fx":"swap",          "target":"player",   "desc":"상대 한 명과 위치를 맞바꾼다"},
 {"id":"r_ai",    "name":"인공지능",       "field":"컴퓨터과학", "pts":4, "icon":"🤖", "fx":"copy",          "target":"player",   "desc":"상대의 안 쓴 능력 하나를 무작위로 복제해 온다"},
 {"id":"r_bug",   "name":"치명적 버그",    "field":"컴퓨터과학", "pts":2, "icon":"🐛", "fx":"break",         "target":"player",   "desc":"상대의 안 쓴 능력 하나를 무작위로 고장낸다"},
 {"id":"r_pyth",  "name":"피타고라스 정리","field":"수학",       "pts":2, "icon":"📐", "fx":"dice_six",      "target":"none",     "desc":"다음 주사위는 무조건 최대 눈"},
 {"id":"r_prob",  "name":"확률론",         "field":"수학",       "pts":3, "icon":"🎲", "fx":"dice_adv",      "target":"none",     "desc":"다음 주사위를 두 번 굴려 큰 쪽"},
 {"id":"r_inf",   "name":"무한급수",       "field":"수학",       "pts":5, "icon":"♾️", "fx":"per_card",      "target":"none",     "desc":"내 연구 1장당 +1점"}
]$j$::jsonb $$;

-- 카오스 카드
create or replace function public.lab_chaos_defs()
returns jsonb language sql immutable as $$ select $j$[
 {"id":"c_revolution", "name":"사회주의 혁명",          "icon":"🚩", "fx":"revolution",   "target":"none",   "desc":"현재 1등과 내 점수를 통째로 맞바꾼다"},
 {"id":"c_budget",     "name":"정부 예산 무한 복사",    "icon":"💸", "fx":"double",       "target":"none",   "desc":"내 점수 2배"},
 {"id":"c_einstein",   "name":"아인슈타인의 분노",      "icon":"🤯", "fx":"scatter",      "target":"none",   "desc":"모든 플레이어의 위치가 무작위로 바뀐다"},
 {"id":"c_plagiarism", "name":"논문 표절 대성공",       "icon":"📄", "fx":"plagiarize",   "target":"player", "desc":"상대의 가장 비싼 연구를 점수째로 빼앗는다"},
 {"id":"c_depression", "name":"우주적 대공황",          "icon":"📉", "fx":"halve_all",    "target":"none",   "desc":"모든 플레이어의 점수가 반토막"},
 {"id":"c_parallel",   "name":"평행우주 통합",          "icon":"🪞", "fx":"permute",      "target":"none",   "desc":"모든 플레이어의 점수가 무작위로 뒤바뀐다"},
 {"id":"c_ethics",     "name":"연구 윤리위원회의 습격", "icon":"🚨", "fx":"force_one",    "target":"player", "desc":"상대 한 명의 다음 주사위는 무조건 1"},
 {"id":"c_nobel",      "name":"노벨상 심사 조작",       "icon":"🏅", "fx":"nobel",        "target":"player", "desc":"상대 한 명의 점수 40%를 내 것으로"},
 {"id":"c_singular",   "name":"특이점 도달",            "icon":"🧠", "fx":"recharge_all", "target":"none",   "desc":"내 모든 연구 능력 재충전"},
 {"id":"c_purge",      "name":"과학계 대숙청",          "icon":"🪓", "fx":"purge",        "target":"none",   "desc":"나를 뺀 모두의 안 쓴 연구 능력이 전부 소멸"},
 {"id":"c_embezzle",   "name":"연구비 횡령",            "icon":"🧾", "fx":"embezzle",     "target":"none",   "desc":"모든 상대에게서 2점씩 뜯어온다"},
 {"id":"c_reviewer2",  "name":"리뷰어 2의 저주",        "icon":"✍️", "fx":"halve_leader", "target":"none",   "desc":"현재 1등의 점수가 반토막 (내가 1등이어도!)"},
 {"id":"c_grad",       "name":"대학원생 갈아넣기",      "icon":"⛏️", "fx":"extra2",       "target":"none",   "desc":"이번 턴 뒤에 2턴을 더 한다"},
 {"id":"c_cat",        "name":"슈뢰딩거의 고양이",      "icon":"🐈", "fx":"schrodinger",  "target":"none",   "desc":"50% 확률로 내 점수 3배, 50% 확률로 0점"},
 {"id":"c_eureka",     "name":"유레카!",                "icon":"🛁", "fx":"eureka",       "target":"none",   "desc":"지도에서 가장 비싼 연구 2개를 즉시 획득"},
 {"id":"c_flat",       "name":"지구 평면설 학회",       "icon":"🥞", "fx":"reverse",      "target":"none",   "desc":"순위가 통째로 뒤집힌다 (1등↔꼴찌)"},
 {"id":"c_bigbang",    "name":"빅뱅 리부트",            "icon":"🌌", "fx":"average",      "target":"none",   "desc":"모든 플레이어의 점수가 평균으로 통일"}
]$j$::jsonb $$;

create or replace function public.lab_def(kind text, did text)
returns jsonb language sql immutable as $$
  select d from jsonb_array_elements(
    case when kind = 'research' then public.lab_research_defs() else public.lab_chaos_defs() end) d
  where d->>'id' = did limit 1;
$$;

create or replace function public.lab_cfg()
returns jsonb language sql stable security definer set search_path = public as $$
  select '{"min_players":2,"max_players":4,"rounds_by_players":{"1":6,"2":10,"3":8,"4":7},
           "turn_seconds":45,"afk_turn_seconds":10,"dice_max":6,"research_initial":12,"research_min":7,
           "teleport_radius":2.5,"chaos_start_turn":2,"chaos_base":0.15,"chaos_ramp":0.08,
           "chaos_max_on_board":2,"chaos_allow_duplicates":false,"chaos_catchup":true}'::jsonb
         || coalesce((select jsonb_object_agg(key, value) from public.lab_config), '{}'::jsonb);
$$;

-- 클라이언트가 한 번 받아가는 정적 묶음
create or replace function public.lab_static()
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object('map', public.lab_map(), 'research', public.lab_research_defs(),
                            'chaos', public.lab_chaos_defs(), 'cfg', public.lab_cfg());
$$;

-- ---------------------------------------------------------------------
-- 5. 내부 엔진 헬퍼 (state jsonb 를 받아서 바꾼 state 를 돌려주는 순수 함수들)
-- ---------------------------------------------------------------------
create or replace function public.lab_ev(s jsonb, e jsonb)
returns jsonb language plpgsql as $$
declare n int := coalesce((s->>'seq')::int, 0) + 1; evs jsonb;
begin
  evs := coalesce(s->'events', '[]'::jsonb) || jsonb_build_array(e || jsonb_build_object('seq', n));
  if jsonb_array_length(evs) > 60 then
    select jsonb_agg(x order by o) into evs
    from jsonb_array_elements(evs) with ordinality t(x, o)
    where o > jsonb_array_length(evs) - 60;
  end if;
  return s || jsonb_build_object('seq', n, 'events', evs);
end $$;

create or replace function public.lab_pset(s jsonb, i int, k text, v jsonb)
returns jsonb language sql immutable as $$ select jsonb_set(s, array['players', i::text, k], v, true) $$;

create or replace function public.lab_fx_set(s jsonb, i int, k text, v jsonb)
returns jsonb language sql immutable as $$ select jsonb_set(s, array['players', i::text, 'fx', k], v, true) $$;

create or replace function public.lab_fx_add(s jsonb, i int, k text, d int)
returns jsonb language sql immutable as $$
  select jsonb_set(s, array['players', i::text, 'fx', k],
                   to_jsonb(coalesce((s->'players'->i->'fx'->>k)::int, 0) + d), true) $$;

create or replace function public.lab_gone(s jsonb, i int)
returns boolean language sql immutable as $$ select coalesce((s->'players'->i->>'gone')::boolean, false) $$;

-- 총점 = 연구 획득 점수(rp) + 카드 효과 보정 점수(bp)
create or replace function public.lab_total(s jsonb, i int)
returns int language sql immutable as $$
  select greatest((s->'players'->i->>'rp')::int + (s->'players'->i->>'bp')::int, 0) $$;

create or replace function public.lab_set_total(s jsonb, i int, t int)
returns jsonb language sql immutable as $$
  select jsonb_set(s, array['players', i::text, 'bp'],
                   to_jsonb(greatest(t, 0) - (s->'players'->i->>'rp')::int)) $$;

create or replace function public.lab_add(s jsonb, i int, d int)
returns jsonb language sql immutable as $$ select public.lab_set_total(s, i, public.lab_total(s, i) + d) $$;

create or replace function public.lab_active(s jsonb)
returns int[] language sql immutable as $$
  select array_agg(o order by o) from generate_series(0, jsonb_array_length(s->'players') - 1) o
  where not public.lab_gone(s, o) $$;

create or replace function public.lab_leader(s jsonb)
returns int language sql immutable as $$
  select o from unnest(public.lab_active(s)) o
  order by public.lab_total(s, o) desc, jsonb_array_length(s->'players'->o->'research') desc, o limit 1 $$;

create or replace function public.lab_pick(a int[])
returns int language sql volatile as $$
  select case when a is null or array_length(a, 1) is null then null
              else a[1 + floor(random() * array_length(a, 1))::int] end $$;

-- 플레이어도 카드도 없는 빈 칸들
create or replace function public.lab_empty_tiles(s jsonb)
returns int[] language sql immutable as $$
  select array_agg((t->>'id')::int)
  from jsonb_array_elements(public.lab_map()->'tiles') t
  where not (coalesce(s->'board'->'research', '{}'::jsonb) ? (t->>'id'))
    and not (coalesce(s->'board'->'chaos', '{}'::jsonb) ? (t->>'id'))
    and not exists (
      select 1 from jsonb_array_elements(s->'players') p
      where (p->>'pos')::int = (t->>'id')::int and not coalesce((p->>'gone')::boolean, false));
$$;

create or replace function public.lab_next_iid(s jsonb)
returns jsonb language sql immutable as $$
  select s || jsonb_build_object('iid', coalesce((s->>'iid')::int, 0) + 1) $$;

-- 연구 한 장을 지도에 깔기
create or replace function public.lab_spawn_research(s jsonb, p_tile int, p_zone int, p_avoid int[], p_quiet boolean)
returns jsonb language plpgsql as $$
declare tile int := p_tile; tiles int[]; pool text[]; did text;
begin
  if tile is null then
    select array_agg(x) into tiles from unnest(public.lab_empty_tiles(s)) x
    where (p_avoid is null or not (x = any(p_avoid)))
      and (p_zone is null or (public.lab_map()->'tiles'->x->>'zone')::int = p_zone);
    if tiles is null and (p_zone is not null or p_avoid is not null) then
      tiles := public.lab_empty_tiles(s);
    end if;
    tile := public.lab_pick(tiles);
  end if;
  if tile is null then return s; end if;

  -- 지금 지도에도 없고 누구 손에도 없는 연구 우선
  select array_agg(d->>'id') into pool from jsonb_array_elements(public.lab_research_defs()) d
  where not exists (select 1 from jsonb_each(s->'board'->'research') b where b.value->>'def' = d->>'id')
    and not exists (select 1 from jsonb_array_elements(s->'players') p,
                                  jsonb_array_elements(p->'research') c where c->>'def' = d->>'id');
  if pool is null then
    select array_agg(d->>'id') into pool from jsonb_array_elements(public.lab_research_defs()) d;
  end if;
  did := pool[1 + floor(random() * array_length(pool, 1))::int];

  s := public.lab_next_iid(s);
  s := jsonb_set(s, array['board', 'research', tile::text],
                 jsonb_build_object('iid', 'k' || (s->>'iid'), 'def', did), true);
  if not p_quiet then
    s := public.lab_ev(s, jsonb_build_object('t', 'spawn_research', 'tile', tile, 'def', did));
  end if;
  return s;
end $$;

-- 카오스 카드 한 장을 지도에 깔기
create or replace function public.lab_spawn_chaos(s jsonb)
returns jsonb language plpgsql as $$
declare tiles int[]; tile int; pool text[]; did text; lead int; lx int; ly int; m jsonb := public.lab_map();
begin
  tiles := public.lab_empty_tiles(s);
  if tiles is null then return s; end if;

  if coalesce((s->'cfg'->>'chaos_catchup')::boolean, true) then
    lead := public.lab_leader(s);
    if lead is not null and public.lab_total(s, lead) > 0 then
      lx := (m->'tiles'->((s->'players'->lead->>'pos')::int)->>'x')::int;
      ly := (m->'tiles'->((s->'players'->lead->>'pos')::int)->>'y')::int;
      select array_agg(x) into tiles from (
        select x from unnest(tiles) x
        order by power((m->'tiles'->x->>'x')::int - lx, 2) + power((m->'tiles'->x->>'y')::int - ly, 2) desc
        limit greatest(array_length(tiles, 1) / 2, 1)) q;
    end if;
  end if;
  tile := public.lab_pick(tiles);

  select array_agg(d->>'id') into pool from jsonb_array_elements(public.lab_chaos_defs()) d
  where coalesce((s->'cfg'->>'chaos_allow_duplicates')::boolean, false)
     or not (coalesce(s->'chaos_seen', '[]'::jsonb) ? (d->>'id'));
  if pool is null then
    select array_agg(d->>'id') into pool from jsonb_array_elements(public.lab_chaos_defs()) d;
    s := s || '{"chaos_seen":[]}'::jsonb;
  end if;
  did := pool[1 + floor(random() * array_length(pool, 1))::int];

  s := public.lab_next_iid(s);
  s := jsonb_set(s, array['board', 'chaos', tile::text],
                 jsonb_build_object('iid', 'c' || (s->>'iid'), 'def', did), true);
  s := s || jsonb_build_object('chaos_seen', coalesce(s->'chaos_seen', '[]'::jsonb) || to_jsonb(did), 'pity', 0);
  return public.lab_ev(s, jsonb_build_object('t', 'chaos_spawn', 'tile', tile, 'def', did));
end $$;

-- 지도 위 연구 한 장을 플레이어에게
create or replace function public.lab_gain_research(s jsonb, me int, tile int)
returns jsonb language plpgsql as $$
declare c jsonb := s->'board'->'research'->(tile::text); pts int; p jsonb; dbl boolean;
begin
  if c is null then return s; end if;
  pts := (public.lab_def('research', c->>'def')->>'pts')::int;
  p := s->'players'->me;
  dbl := coalesce((p->'fx'->>'double')::boolean, false);
  p := jsonb_set(p, '{research}', (p->'research') || jsonb_build_array(
         jsonb_build_object('iid', c->>'iid', 'def', c->>'def', 'pts', pts, 'used', false)));
  p := jsonb_set(p, '{rp}', to_jsonb((p->>'rp')::int + pts));
  if dbl then
    p := jsonb_set(p, '{bp}', to_jsonb((p->>'bp')::int + pts));
    p := p #- '{fx,double}';
  end if;
  s := jsonb_set(s, array['players', me::text], p);
  s := s #- array['board', 'research', tile::text];
  return public.lab_ev(s, jsonb_build_object('t', 'gain_research', 'p', me, 'tile', tile,
                                             'def', c->>'def', 'pts', pts, 'double', dbl));
end $$;

-- 플레이어가 서 있는 칸의 카드 줍기
create or replace function public.lab_pickup(s jsonb, me int)
returns jsonb language plpgsql as $$
declare pos int := (s->'players'->me->>'pos')::int; c jsonb;
begin
  s := public.lab_gain_research(s, me, pos);
  c := s->'board'->'chaos'->(pos::text);
  if c is not null then
    s := jsonb_set(s, array['players', me::text, 'chaos'],
                   (s->'players'->me->'chaos') || jsonb_build_array(c));
    s := s #- array['board', 'chaos', pos::text];
    s := public.lab_ev(s, jsonb_build_object('t', 'gain_chaos', 'p', me, 'tile', pos, 'def', c->>'def'));
  end if;
  return s;
end $$;

-- 현재 턴 플레이어의 제한 시간 세팅
create or replace function public.lab_arm(s jsonb)
returns jsonb language plpgsql as $$
declare i int := (s->'turn'->>'idx')::int; secs int;
begin
  secs := case when coalesce((s->'players'->i->>'afk')::int, 0) >= 2
               then (s->'cfg'->>'afk_turn_seconds')::int else (s->'cfg'->>'turn_seconds')::int end;
  return jsonb_set(s, '{turn,deadline}', to_jsonb(now() + make_interval(secs => secs)), true);
end $$;

-- 게임 종료 처리
create or replace function public.lab_finish(s jsonb)
returns jsonb language plpgsql as $$
declare res jsonb;
begin
  select jsonb_agg(o order by public.lab_total(s, o) desc,
                              jsonb_array_length(s->'players'->o->'research') desc, o)
    into res from unnest(public.lab_active(s)) o;
  s := s || jsonb_build_object('phase', 'finished', 'result', coalesce(res, '[]'::jsonb));
  s := s #- '{turn,deadline}';
  return public.lab_ev(s, jsonb_build_object('t', 'end', 'result', coalesce(res, '[]'::jsonb)));
end $$;

-- 턴 종료 → 카오스 등장 판정 → 다음 플레이어 / 라운드 / 게임 종료
create or replace function public.lab_end_turn(s jsonb)
returns jsonb language plpgsql as $$
declare
  cur int := (s->'turn'->>'idx')::int;
  n int := jsonb_array_length(s->'players');
  i int; wrapped boolean := false; rnd int; cnt int; prev int; guard int := 0;
  tn int := coalesce((s->'turn'->>'n')::int, 0) + 1;
  pity int := coalesce((s->>'pity')::int, 0) + 1;
  extra int;
begin
  s := jsonb_set(s, '{turn,n}', to_jsonb(tn), true);
  s := s || jsonb_build_object('pity', pity);

  -- 카오스 카드 등장 판정 (서버 난수)
  select count(*) into cnt from jsonb_object_keys(s->'board'->'chaos');
  if tn >= (s->'cfg'->>'chaos_start_turn')::int
     and cnt < (s->'cfg'->>'chaos_max_on_board')::int
     and random() < (s->'cfg'->>'chaos_base')::numeric + (s->'cfg'->>'chaos_ramp')::numeric * (pity - 1) then
    s := public.lab_spawn_chaos(s);
  end if;

  -- 추가 턴
  extra := coalesce((s->'players'->cur->'fx'->>'extra')::int, 0);
  if extra > 0 and not public.lab_gone(s, cur) then
    s := public.lab_fx_set(s, cur, 'extra', to_jsonb(extra - 1));
    s := jsonb_set(s, '{turn}', (s->'turn') || '{"phase":"roll","dice":null}'::jsonb);
    s := public.lab_ev(s, jsonb_build_object('t', 'extra_turn', 'p', cur));
    return public.lab_arm(s);
  end if;

  -- 다음 플레이어
  i := cur;
  loop
    i := i + 1; guard := guard + 1;
    if i >= n then i := 0; wrapped := true; end if;
    exit when not public.lab_gone(s, i) or guard > n;
  end loop;

  if wrapped then
    rnd := (s->'turn'->>'round')::int + 1;
    if rnd > (s->>'rounds')::int then
      return public.lab_finish(s);
    end if;
    s := jsonb_set(s, '{turn,round}', to_jsonb(rnd));
    -- 연구 보충
    loop
      select count(*) into cnt from jsonb_object_keys(s->'board'->'research');
      exit when cnt >= (s->'cfg'->>'research_min')::int;
      prev := cnt;
      s := public.lab_spawn_research(s, null, null, null, false);
      select count(*) into cnt from jsonb_object_keys(s->'board'->'research');
      exit when cnt = prev;
    end loop;
  end if;

  s := jsonb_set(s, '{turn}', (s->'turn') || jsonb_build_object('idx', i, 'phase', 'roll', 'dice', null));
  s := public.lab_ev(s, jsonb_build_object('t', 'turn', 'p', i, 'round', (s->'turn'->>'round')::int));
  return public.lab_arm(s);
end $$;

-- ---------------------------------------------------------------------
-- 6. 카드 효과 (연구 능력 + 카오스 카드)
--    사용 시점 규칙은 단 하나: "내 턴, 주사위 굴리기 전". 그래서 효과끼리 충돌이 없음.
--    주사위 보정 우선순위: 무조건 1 > 무조건 최대 > 두 번 굴리기 > (+보너스 -페널티)
-- ---------------------------------------------------------------------
create or replace function public.lab_apply(s jsonb, me int, d jsonb, tg jsonb)
returns jsonb language plpgsql as $$
declare
  fx text := d->>'fx';
  m jsonb := public.lab_map();
  act int[] := public.lab_active(s);
  cnt int := array_length(public.lab_active(s), 1);
  mypos int := (s->'players'->me->>'pos')::int;
  me_n text := s->'players'->me->>'name';
  tp int; tp_n text; tt int; i int; k int; v int; w int;
  tiles int[]; keys text[]; vals jsonb; arr jsonb; c jsonb; ord int[]; tot int[]; kk text;
  msg text := '';
begin
  if d->>'target' = 'player' then
    tp := (tg->>'player')::int;
    if tp is null or tp = me or not (tp = any(act)) then raise exception 'BAD_TARGET'; end if;
    tp_n := s->'players'->tp->>'name';
  end if;

  case fx
  -- ===== 연구 능력 =====
  when 'dice_plus' then
    s := public.lab_fx_add(s, me, 'plus', 2);
    msg := me_n || '의 다음 주사위 +2';
  when 'extra_turn' then
    s := public.lab_fx_add(s, me, 'extra', 1);
    msg := me_n || '은(는) 한 턴 더 움직인다';
  when 'teleport' then
    tt := (tg->>'tile')::int;
    if tt is null or tt < 0 or tt >= jsonb_array_length(m->'tiles') or tt = mypos then
      raise exception 'BAD_TARGET';
    end if;
    if sqrt(power((m->'tiles'->tt->>'x')::int - (m->'tiles'->mypos->>'x')::int, 2)
          + power((m->'tiles'->tt->>'y')::int - (m->'tiles'->mypos->>'y')::int, 2))
       > (s->'cfg'->>'teleport_radius')::numeric then
      raise exception 'TOO_FAR';
    end if;
    s := public.lab_pset(s, me, 'pos', to_jsonb(tt));
    s := public.lab_ev(s, jsonb_build_object('t', 'warp', 'p', me, 'to', tt));
    s := public.lab_pickup(s, me);
    msg := me_n || '이(가) 벽을 뚫고 순간이동!';
  when 'pull' then
    s := public.lab_pset(s, tp, 'pos', to_jsonb(mypos));
    s := public.lab_ev(s, jsonb_build_object('t', 'warp', 'p', tp, 'to', mypos));
    msg := tp_n || '이(가) ' || me_n || '의 블랙홀에 빨려 들어갔다';
  when 'dice_minus' then
    s := public.lab_fx_add(s, tp, 'minus', 3);
    msg := tp_n || '의 다음 주사위 -3';
  when 'aoe_minus' then
    foreach i in array act loop
      if i <> me then s := public.lab_add(s, i, -2); end if;
    end loop;
    msg := me_n || '만 빼고 전원 -2점';
  when 'double_next' then
    s := public.lab_fx_set(s, me, 'double', 'true'::jsonb);
    msg := me_n || '의 다음 연구는 점수 2배';
  when 'shuffle_board' then
    select array_agg(e.key), jsonb_agg(e.value) into keys, vals from jsonb_each(s->'board'->'research') e;
    if keys is not null then
      tiles := coalesce(public.lab_empty_tiles(s), '{}'::int[]) || (keys::int[]);
      select array_agg(x) into tiles from (
        select x from unnest(tiles) x order by random() limit array_length(keys, 1)) q;
      arr := '{}'::jsonb;
      for i in 1..array_length(keys, 1) loop
        arr := arr || jsonb_build_object(tiles[i]::text, vals->(i - 1));
      end loop;
      s := jsonb_set(s, '{board,research}', arr);
    end if;
    msg := '지도 위 연구가 전부 뒤섞였다';
  when 'blast' then
    tt := public.lab_pick(public.lab_empty_tiles(s));
    if tt is not null then
      s := public.lab_pset(s, tp, 'pos', to_jsonb(tt));
      s := public.lab_ev(s, jsonb_build_object('t', 'warp', 'p', tp, 'to', tt));
    end if;
    msg := tp_n || '이(가) 폭발에 휘말려 날아갔다';
  when 'synth' then
    select array_agg(x) into tiles from unnest(public.lab_empty_tiles(s)) x
    where (m->'tiles'->mypos->'n') @> to_jsonb(x);
    if tiles is null then tiles := public.lab_empty_tiles(s); end if;
    if tiles is not null then
      s := public.lab_spawn_research(s, public.lab_pick(tiles), null, null, false);
    end if;
    msg := me_n || '이(가) 새 연구를 합성했다';
  when 'recharge' then
    select (o - 1)::int into k
    from jsonb_array_elements(s->'players'->me->'research') with ordinality t(c, o)
    where t.c->>'iid' = tg->>'card' and (t.c->>'used')::boolean limit 1;
    if k is null then raise exception 'BAD_TARGET'; end if;
    s := jsonb_set(s, array['players', me::text, 'research', k::text, 'used'], 'false'::jsonb);
    msg := me_n || '이(가) 능력 하나를 재충전했다';
  when 'plus2' then
    s := public.lab_add(s, me, 2);
    msg := me_n || ' +2점';
  when 'evolve' then
    v := public.lab_total(s, me);
    if cnt > 1 and not exists (select 1 from unnest(act) o where o <> me and public.lab_total(s, o) <= v) then
      s := public.lab_add(s, me, 5); msg := me_n || '이(가) 꼴찌에서 진화했다! +5점';
    else
      s := public.lab_add(s, me, 1); msg := me_n || ' +1점 (진화 실패)';
    end if;
  when 'swap' then
    tt := (s->'players'->tp->>'pos')::int;
    s := public.lab_pset(s, tp, 'pos', to_jsonb(mypos));
    s := public.lab_pset(s, me, 'pos', to_jsonb(tt));
    s := public.lab_ev(s, jsonb_build_object('t', 'warp', 'p', tp, 'to', mypos));
    s := public.lab_ev(s, jsonb_build_object('t', 'warp', 'p', me, 'to', tt));
    msg := me_n || '와(과) ' || tp_n || '의 위치가 뒤바뀌었다';
  when 'copy' then
    select t.c into c from jsonb_array_elements(s->'players'->tp->'research') with ordinality t(c, o)
    where not (t.c->>'used')::boolean order by random() limit 1;
    if c is null then
      msg := tp_n || '에게는 복제할 능력이 없었다…';
    else
      s := public.lab_next_iid(s);
      s := jsonb_set(s, array['players', me::text, 'research'],
             (s->'players'->me->'research') || jsonb_build_array(jsonb_build_object(
               'iid', 'k' || (s->>'iid'), 'def', c->>'def', 'pts', 0, 'used', false, 'copy', true)));
      msg := me_n || '이(가) ' || tp_n || '의 「' || (public.lab_def('research', c->>'def')->>'name') || '」 능력을 복제했다';
    end if;
  when 'break' then
    select (o - 1)::int into k from jsonb_array_elements(s->'players'->tp->'research') with ordinality t(c, o)
    where not (t.c->>'used')::boolean order by random() limit 1;
    if k is null then
      msg := tp_n || '에게는 고장낼 능력이 없었다…';
    else
      msg := tp_n || '의 「' || (public.lab_def('research', s->'players'->tp->'research'->k->>'def')->>'name') || '」 능력이 고장났다';
      s := jsonb_set(s, array['players', tp::text, 'research', k::text, 'used'], 'true'::jsonb);
    end if;
  when 'dice_six' then
    s := public.lab_fx_set(s, me, 'six', 'true'::jsonb);
    msg := me_n || '의 다음 주사위는 무조건 최대';
  when 'dice_adv' then
    s := public.lab_fx_set(s, me, 'adv', 'true'::jsonb);
    msg := me_n || '은(는) 다음 주사위를 두 번 굴린다';
  when 'per_card' then
    v := jsonb_array_length(s->'players'->me->'research');
    s := public.lab_add(s, me, v);
    msg := me_n || ' +' || v || '점';

  -- ===== 카오스 카드 =====
  when 'revolution' then
    i := public.lab_leader(s);
    if i = me then
      msg := '혁명 실패! ' || me_n || '이(가) 이미 1등이라 아무 일도 일어나지 않았다';
    else
      v := public.lab_total(s, me); w := public.lab_total(s, i);
      s := public.lab_set_total(s, me, w);
      s := public.lab_set_total(s, i, v);
      msg := me_n || '이(가) 1등 ' || (s->'players'->i->>'name') || '와(과) 점수를 맞바꿨다';
    end if;
  when 'double' then
    s := public.lab_set_total(s, me, public.lab_total(s, me) * 2);
    msg := me_n || '의 점수가 2배가 되었다';
  when 'scatter' then
    foreach i in array act loop
      tt := public.lab_pick(public.lab_empty_tiles(s));
      if tt is not null then
        s := public.lab_pset(s, i, 'pos', to_jsonb(tt));
        s := public.lab_ev(s, jsonb_build_object('t', 'warp', 'p', i, 'to', tt));
      end if;
    end loop;
    msg := '모두가 어딘가로 날아갔다';
  when 'plagiarize' then
    select (o - 1)::int into k from jsonb_array_elements(s->'players'->tp->'research') with ordinality t(c, o)
    order by (t.c->>'pts')::int desc, random() limit 1;
    if k is null then
      v := least(3, public.lab_total(s, tp));
      s := public.lab_add(s, tp, -v);
      s := public.lab_add(s, me, v);
      msg := tp_n || '은(는) 연구가 없어서 대신 ' || v || '점을 뜯겼다';
    else
      c := s->'players'->tp->'research'->k;
      v := (c->>'pts')::int;
      s := jsonb_set(s, array['players', tp::text, 'research'], (s->'players'->tp->'research') - k);
      s := public.lab_pset(s, tp, 'rp', to_jsonb((s->'players'->tp->>'rp')::int - v));
      if (s->'players'->tp->>'rp')::int + (s->'players'->tp->>'bp')::int < 0 then
        s := public.lab_pset(s, tp, 'bp', to_jsonb(-(s->'players'->tp->>'rp')::int));
      end if;
      s := jsonb_set(s, array['players', me::text, 'research'],
                     (s->'players'->me->'research') || jsonb_build_array(c));
      s := public.lab_pset(s, me, 'rp', to_jsonb((s->'players'->me->>'rp')::int + v));
      msg := me_n || '이(가) ' || tp_n || '의 「' || (public.lab_def('research', c->>'def')->>'name') || '」을(를) 통째로 표절했다';
    end if;
  when 'halve_all' then
    foreach i in array act loop
      s := public.lab_set_total(s, i, public.lab_total(s, i) / 2);
    end loop;
    msg := '모든 플레이어의 점수가 반토막 났다';
  when 'permute' then
    select array_agg(public.lab_total(s, o) order by random()) into tot from unnest(act) o;
    for i in 1..cnt loop
      s := public.lab_set_total(s, act[i], tot[i]);
    end loop;
    msg := '평행우주가 합쳐지며 점수가 뒤죽박죽이 되었다';
  when 'force_one' then
    s := public.lab_fx_set(s, tp, 'one', 'true'::jsonb);
    msg := tp_n || '의 다음 주사위는 무조건 1';
  when 'nobel' then
    v := ceil(public.lab_total(s, tp) * 0.4)::int;
    s := public.lab_add(s, tp, -v);
    s := public.lab_add(s, me, v);
    msg := me_n || '이(가) ' || tp_n || '의 ' || v || '점을 가로챘다';
  when 'recharge_all' then
    select coalesce(jsonb_agg(t.c || '{"used":false}'::jsonb order by o), '[]'::jsonb) into arr
    from jsonb_array_elements(s->'players'->me->'research') with ordinality t(c, o);
    s := public.lab_pset(s, me, 'research', arr);
    msg := me_n || '의 모든 연구 능력이 되살아났다';
  when 'purge' then
    foreach i in array act loop
      if i <> me then
        select coalesce(jsonb_agg(t.c || '{"used":true}'::jsonb order by o), '[]'::jsonb) into arr
        from jsonb_array_elements(s->'players'->i->'research') with ordinality t(c, o);
        s := public.lab_pset(s, i, 'research', arr);
      end if;
    end loop;
    msg := me_n || '만 빼고 모두의 연구 능력이 숙청당했다';
  when 'embezzle' then
    w := 0;
    foreach i in array act loop
      if i <> me then
        v := least(2, public.lab_total(s, i));
        s := public.lab_add(s, i, -v);
        w := w + v;
      end if;
    end loop;
    s := public.lab_add(s, me, w);
    msg := me_n || '이(가) 연구비 ' || w || '점을 횡령했다';
  when 'halve_leader' then
    i := public.lab_leader(s);
    s := public.lab_set_total(s, i, public.lab_total(s, i) / 2);
    msg := '1등 ' || (s->'players'->i->>'name') || '의 점수가 반토막 났다';
  when 'extra2' then
    s := public.lab_fx_add(s, me, 'extra', 2);
    msg := me_n || '은(는) 2턴을 더 움직인다';
  when 'schrodinger' then
    if random() < 0.5 then
      s := public.lab_set_total(s, me, public.lab_total(s, me) * 3);
      msg := '고양이는 살아 있었다! ' || me_n || '의 점수 3배';
    else
      s := public.lab_set_total(s, me, 0);
      msg := '고양이는… ' || me_n || '의 점수가 0점이 되었다';
    end if;
  when 'eureka' then
    for i in 1..2 loop
      select e.key into kk from jsonb_each(s->'board'->'research') e
      order by (public.lab_def('research', e.value->>'def')->>'pts')::int desc, random() limit 1;
      exit when kk is null;
      s := public.lab_gain_research(s, me, kk::int);
      kk := null;
    end loop;
    msg := me_n || '이(가) 욕조에서 뛰쳐나와 연구를 쓸어 담았다';
  when 'reverse' then
    select array_agg(o order by public.lab_total(s, o) desc, o),
           array_agg(public.lab_total(s, o) order by public.lab_total(s, o) desc, o)
      into ord, tot from unnest(act) o;
    for i in 1..cnt loop
      s := public.lab_set_total(s, ord[i], tot[cnt + 1 - i]);
    end loop;
    msg := '순위가 통째로 뒤집혔다';
  when 'average' then
    select round(avg(public.lab_total(s, o)))::int into v from unnest(act) o;
    foreach i in array act loop
      s := public.lab_set_total(s, i, v);
    end loop;
    msg := '빅뱅 리부트! 모두의 점수가 ' || v || '점이 되었다';
  else
    raise exception 'UNKNOWN_EFFECT';
  end case;

  return public.lab_ev(s, jsonb_build_object('t', 'msg', 'text', msg));
end $$;

-- ---------------------------------------------------------------------
-- 7. 공통 내부 함수 (인증 / 방 잠금 / 저장 / 퇴장)
-- ---------------------------------------------------------------------
create or replace function public.lab_uid()
returns uuid language plpgsql stable as $$
declare u uuid := auth.uid();
begin
  if u is null then raise exception 'NOT_AUTHENTICATED'; end if;
  return u;
end $$;

-- 방을 잠그고(동시 요청 직렬화) 내가 참가자인지 확인
create or replace function public.lab_lock(p_room uuid)
returns public.lab_rooms language plpgsql security definer set search_path = public as $$
declare r public.lab_rooms; u uuid := public.lab_uid();
begin
  select * into r from public.lab_rooms where id = p_room for update;
  if not found then raise exception 'ROOM_NOT_FOUND'; end if;
  if not exists (select 1 from public.lab_members where room_id = p_room and user_id = u) then
    raise exception 'NOT_A_MEMBER';
  end if;
  return r;
end $$;

create or replace function public.lab_save(p_room uuid, s jsonb)
returns public.lab_rooms language plpgsql security definer set search_path = public as $$
declare r public.lab_rooms;
begin
  update public.lab_rooms
     set state = s || jsonb_build_object('now', now()),
         status = s->>'phase',
         host_id = (s->>'host')::uuid,
         version = version + 1,
         updated_at = now()
   where id = p_room
   returning * into r;
  return r;
end $$;

create or replace function public.lab_my_idx(s jsonb, u uuid)
returns int language sql immutable as $$
  select (o - 1)::int from jsonb_array_elements(s->'players') with ordinality t(p, o)
  where t.p->>'uid' = u::text and not coalesce((t.p->>'gone')::boolean, false) limit 1 $$;

-- 내 턴인지 확인하고 내 인덱스를 돌려줌
create or replace function public.lab_my_turn(s jsonb, p_phase text)
returns int language plpgsql stable as $$
declare me int;
begin
  if s->>'phase' <> 'playing' then raise exception 'NOT_PLAYING'; end if;
  me := public.lab_my_idx(s, public.lab_uid());
  if me is null or me <> (s->'turn'->>'idx')::int then raise exception 'NOT_YOUR_TURN'; end if;
  if s->'turn'->>'phase' <> p_phase then raise exception 'WRONG_PHASE'; end if;
  return me;
end $$;

-- 플레이어 제거 (나가기 / 강퇴 공용). 방이 비면 방 삭제.
create or replace function public.lab_remove(p_room uuid, p_user uuid)
returns void language plpgsql security definer set search_path = public as $$
declare r public.lab_rooms; s jsonb; i int; arr jsonb; act int[];
begin
  select * into r from public.lab_rooms where id = p_room for update;
  if not found then return; end if;
  delete from public.lab_members where room_id = p_room and user_id = p_user;
  if not exists (select 1 from public.lab_members where room_id = p_room) then
    delete from public.lab_rooms where id = p_room;
    return;
  end if;

  s := r.state;
  i := public.lab_my_idx(s, p_user);
  if i is not null then
    if s->>'phase' = 'lobby' then
      select coalesce(jsonb_agg(t.p order by o), '[]'::jsonb) into arr
      from jsonb_array_elements(s->'players') with ordinality t(p, o) where t.p->>'uid' <> p_user::text;
      s := s || jsonb_build_object('players', arr);
    else
      s := public.lab_pset(s, i, 'gone', 'true'::jsonb);
      s := public.lab_ev(s, jsonb_build_object('t', 'left', 'p', i));
      if s->>'phase' = 'playing' then
        act := public.lab_active(s);
        if coalesce(array_length(act, 1), 0) < 2 and (s->'cfg'->>'min_players')::int >= 2 then
          s := public.lab_finish(s);
        elsif (s->'turn'->>'idx')::int = i then
          s := public.lab_end_turn(s);
        end if;
      end if;
    end if;
  end if;

  if s->>'host' = p_user::text then
    s := s || jsonb_build_object('host',
      (select t.p->>'uid' from jsonb_array_elements(s->'players') with ordinality t(p, o)
        where not coalesce((t.p->>'gone')::boolean, false) order by o limit 1));
  end if;
  perform public.lab_save(p_room, s);
end $$;

-- ---------------------------------------------------------------------
-- 8. 공개 RPC — 프런트엔드가 호출하는 함수는 여기 있는 것들뿐
-- ---------------------------------------------------------------------
-- 방 만들기
create or replace function public.lab_create_room(p_nickname text)
returns public.lab_rooms language plpgsql security definer set search_path = public as $$
declare u uuid := public.lab_uid(); nick text := left(btrim(coalesce(p_nickname, '')), 12);
        c text; r public.lab_rooms; abc text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
begin
  if length(nick) < 1 then raise exception 'BAD_NICKNAME'; end if;
  delete from public.lab_rooms where updated_at < now() - interval '12 hours';   -- 오래된 방 청소
  loop
    select string_agg(substr(abc, 1 + floor(random() * length(abc))::int, 1), '') into c
    from generate_series(1, 5);
    exit when not exists (select 1 from public.lab_rooms where code = c);
  end loop;
  insert into public.lab_rooms(code, host_id, status, state)
  values (c, u, 'lobby', jsonb_build_object(
            'phase', 'lobby', 'host', u, 'seq', 0, 'events', '[]'::jsonb, 'now', now(),
            'players', jsonb_build_array(jsonb_build_object('uid', u, 'name', nick))))
  returning * into r;
  insert into public.lab_members(room_id, user_id, nickname) values (r.id, u, nick);
  return r;
end $$;

-- 방 코드로 참가 (이미 참가자면 그대로 방 정보를 돌려줌 = 재접속)
create or replace function public.lab_join_room(p_code text, p_nickname text)
returns public.lab_rooms language plpgsql security definer set search_path = public as $$
declare u uuid := public.lab_uid(); nick text := left(btrim(coalesce(p_nickname, '')), 12);
        r public.lab_rooms; s jsonb;
begin
  select * into r from public.lab_rooms where code = upper(btrim(p_code)) for update;
  if not found then raise exception 'ROOM_NOT_FOUND'; end if;
  if exists (select 1 from public.lab_members where room_id = r.id and user_id = u) then
    return r;
  end if;
  if r.status <> 'lobby' then raise exception 'GAME_ALREADY_STARTED'; end if;
  if length(nick) < 1 then raise exception 'BAD_NICKNAME'; end if;
  s := r.state;
  if jsonb_array_length(s->'players') >= (public.lab_cfg()->>'max_players')::int then
    raise exception 'ROOM_FULL';
  end if;
  insert into public.lab_members(room_id, user_id, nickname) values (r.id, u, nick);
  s := s || jsonb_build_object('players',
         (s->'players') || jsonb_build_array(jsonb_build_object('uid', u, 'name', nick)));
  return public.lab_save(r.id, s);
end $$;

-- 방 나가기
create or replace function public.lab_leave_room(p_room uuid)
returns void language plpgsql security definer set search_path = public as $$
declare u uuid := public.lab_uid();
begin
  if exists (select 1 from public.lab_members where room_id = p_room and user_id = u) then
    perform public.lab_remove(p_room, u);
  end if;
end $$;

-- 강퇴 (방장, 대기실에서만)
create or replace function public.lab_kick(p_room uuid, p_user uuid)
returns void language plpgsql security definer set search_path = public as $$
declare r public.lab_rooms := public.lab_lock(p_room);
begin
  if r.host_id <> public.lab_uid() then raise exception 'NOT_HOST'; end if;
  if r.status <> 'lobby' then raise exception 'NOT_IN_LOBBY'; end if;
  if p_user = r.host_id then raise exception 'BAD_TARGET'; end if;
  perform public.lab_remove(p_room, p_user);
end $$;

-- 게임 시작 (방장). 결과 화면에서 다시 호출하면 같은 멤버로 바로 재시작.
create or replace function public.lab_start_game(p_room uuid)
returns public.lab_rooms language plpgsql security definer set search_path = public as $$
declare
  r public.lab_rooms := public.lab_lock(p_room);
  s jsonb := r.state; cfg jsonb := public.lab_cfg(); m jsonb := public.lab_map();
  pl jsonb; n int; zones int[]; i int; pos int; avoid int[] := '{}';
begin
  if r.host_id <> public.lab_uid() then raise exception 'NOT_HOST'; end if;
  if r.status = 'playing' then raise exception 'ALREADY_PLAYING'; end if;

  select coalesce(jsonb_agg(jsonb_build_object('uid', t.p->>'uid', 'name', t.p->>'name') order by random()), '[]'::jsonb)
    into pl from jsonb_array_elements(s->'players') t(p)
   where not coalesce((t.p->>'gone')::boolean, false);
  n := jsonb_array_length(pl);
  if n < (cfg->>'min_players')::int then raise exception 'NOT_ENOUGH_PLAYERS'; end if;
  if n > 4 then raise exception 'TOO_MANY_PLAYERS'; end if;

  -- 시작 위치: 4개 구역을 섞어서 한 명씩, 구역 안 후보 칸 중 무작위
  select array_agg(z order by random()) into zones from generate_series(0, 3) z;
  for i in 0..n - 1 loop
    pos := (m->'starts'->zones[i + 1]->(floor(random() * jsonb_array_length(m->'starts'->zones[i + 1]))::int))::int;
    avoid := avoid || pos || array(select jsonb_array_elements_text(m->'tiles'->pos->'n')::int);
    pl := jsonb_set(pl, array[i::text], (pl->i) || jsonb_build_object(
            'pos', pos, 'rp', 0, 'bp', 0, 'afk', 0,
            'research', '[]'::jsonb, 'chaos', '[]'::jsonb, 'fx', '{}'::jsonb));
  end loop;

  s := jsonb_build_object(
    'phase', 'playing', 'host', s->>'host',
    'seq', coalesce((s->>'seq')::int, 0), 'events', coalesce(s->'events', '[]'::jsonb),
    'game', coalesce((s->>'game')::int, 0) + 1,
    'cfg', cfg, 'rounds', coalesce((cfg->'rounds_by_players'->>(n::text))::int, 7),
    'players', pl,
    'board', '{"research":{},"chaos":{}}'::jsonb,
    'chaos_seen', '[]'::jsonb, 'pity', 0, 'iid', 0,
    'turn', jsonb_build_object('idx', 0, 'round', 1, 'phase', 'roll', 'dice', null, 'n', 0));

  -- 연구 초기 배치: 구역마다 고르게, 시작 칸과 그 옆 칸은 피해서
  for i in 1..(cfg->>'research_initial')::int loop
    s := public.lab_spawn_research(s, null, (i - 1) % 4, avoid, true);
  end loop;

  s := public.lab_ev(s, jsonb_build_object('t', 'start', 'game', (s->>'game')::int));
  s := public.lab_ev(s, jsonb_build_object('t', 'turn', 'p', 0, 'round', 1));
  return public.lab_save(p_room, public.lab_arm(s));
end $$;

-- 대기실로 돌아가기 (방장, 게임 종료 후)
create or replace function public.lab_to_lobby(p_room uuid)
returns public.lab_rooms language plpgsql security definer set search_path = public as $$
declare r public.lab_rooms := public.lab_lock(p_room); s jsonb := r.state; pl jsonb;
begin
  if r.host_id <> public.lab_uid() then raise exception 'NOT_HOST'; end if;
  if r.status <> 'finished' then raise exception 'NOT_FINISHED'; end if;
  select coalesce(jsonb_agg(jsonb_build_object('uid', t.p->>'uid', 'name', t.p->>'name') order by o), '[]'::jsonb)
    into pl from jsonb_array_elements(s->'players') with ordinality t(p, o)
   where not coalesce((t.p->>'gone')::boolean, false);
  s := jsonb_build_object('phase', 'lobby', 'host', s->>'host', 'players', pl,
                          'seq', (s->>'seq')::int, 'events', '[]'::jsonb, 'game', s->'game');
  return public.lab_save(p_room, s);
end $$;

-- 주사위 굴리기 (서버 난수)
create or replace function public.lab_roll(p_room uuid)
returns public.lab_rooms language plpgsql security definer set search_path = public as $$
declare
  r public.lab_rooms := public.lab_lock(p_room); s jsonb := r.state;
  me int := public.lab_my_turn(s, 'roll');
  f jsonb := coalesce(s->'players'->me->'fx', '{}'::jsonb);
  dmax int := (s->'cfg'->>'dice_max')::int;
  r1 int := 1 + floor(random() * dmax)::int;
  r2 int := 1 + floor(random() * dmax)::int;
  base int; final int;
begin
  if coalesce((f->>'one')::boolean, false) then
    base := 1; final := 1;
  else
    base := case when coalesce((f->>'six')::boolean, false) then dmax
                 when coalesce((f->>'adv')::boolean, false) then greatest(r1, r2)
                 else r1 end;
    final := greatest(1, least(base + coalesce((f->>'plus')::int, 0) - coalesce((f->>'minus')::int, 0), dmax + 3));
  end if;
  s := public.lab_pset(s, me, 'fx', f - 'one' - 'six' - 'adv' - 'plus' - 'minus');
  s := public.lab_pset(s, me, 'afk', '0'::jsonb);
  s := jsonb_set(s, '{turn}', (s->'turn') || jsonb_build_object('phase', 'move', 'dice', final));
  s := public.lab_ev(s, jsonb_build_object('t', 'roll', 'p', me, 'dice', final, 'base', base,
         'rolls', case when coalesce((f->>'adv')::boolean, false) and not coalesce((f->>'one')::boolean, false)
                            and not coalesce((f->>'six')::boolean, false)
                       then jsonb_build_array(r1, r2) else jsonb_build_array(base) end));
  return public.lab_save(p_room, public.lab_arm(s));
end $$;

-- 이동: p_path = 지나갈 칸 id 를 순서대로 (현재 칸 제외, 1칸 이상 주사위 눈 이하)
create or replace function public.lab_move(p_room uuid, p_path int[])
returns public.lab_rooms language plpgsql security definer set search_path = public as $$
declare
  r public.lab_rooms := public.lab_lock(p_room); s jsonb := r.state;
  me int := public.lab_my_turn(s, 'move');
  m jsonb := public.lab_map(); nt int := jsonb_array_length(public.lab_map()->'tiles');
  cur int := (s->'players'->me->>'pos')::int; seen int[]; t int;
  len int := coalesce(array_length(p_path, 1), 0);
begin
  if len < 1 or len > (s->'turn'->>'dice')::int then raise exception 'BAD_PATH'; end if;
  seen := array[cur];
  foreach t in array p_path loop
    if t is null or t < 0 or t >= nt then raise exception 'BAD_PATH'; end if;
    if not ((m->'tiles'->cur->'n') @> to_jsonb(t)) then raise exception 'BAD_PATH'; end if;
    if t = any(seen) then raise exception 'BAD_PATH'; end if;
    seen := seen || t; cur := t;
  end loop;
  s := public.lab_pset(s, me, 'pos', to_jsonb(cur));
  s := public.lab_ev(s, jsonb_build_object('t', 'move', 'p', me, 'path', to_jsonb(p_path)));
  s := public.lab_pickup(s, me);
  return public.lab_save(p_room, public.lab_end_turn(s));
end $$;

-- 카드 사용 (연구 능력 / 카오스 카드 공용). p_iid = 카드 고유 id
-- p_target 예: {"player": 2} / {"tile": 17} / {"card": "k5"}
create or replace function public.lab_use_card(p_room uuid, p_iid text, p_target jsonb default '{}'::jsonb)
returns public.lab_rooms language plpgsql security definer set search_path = public as $$
declare
  r public.lab_rooms := public.lab_lock(p_room); s jsonb := r.state;
  me int := public.lab_my_turn(s, 'roll');
  k int; c jsonb; d jsonb; kind text;
begin
  select (o - 1)::int, t.c into k, c
  from jsonb_array_elements(s->'players'->me->'research') with ordinality t(c, o)
  where t.c->>'iid' = p_iid limit 1;
  if k is not null then
    if (c->>'used')::boolean then raise exception 'ALREADY_USED'; end if;
    kind := 'research';
    d := public.lab_def('research', c->>'def');
    s := jsonb_set(s, array['players', me::text, 'research', k::text, 'used'], 'true'::jsonb);
  else
    select (o - 1)::int, t.c into k, c
    from jsonb_array_elements(s->'players'->me->'chaos') with ordinality t(c, o)
    where t.c->>'iid' = p_iid limit 1;
    if k is null then raise exception 'CARD_NOT_FOUND'; end if;
    kind := 'chaos';
    d := public.lab_def('chaos', c->>'def');
    s := jsonb_set(s, array['players', me::text, 'chaos'], (s->'players'->me->'chaos') - k);
  end if;

  s := public.lab_pset(s, me, 'afk', '0'::jsonb);
  s := public.lab_ev(s, jsonb_build_object('t', 'use', 'kind', kind, 'p', me, 'def', d->>'id',
                                           'target', coalesce(p_target, '{}'::jsonb)));
  s := public.lab_apply(s, me, d, coalesce(p_target, '{}'::jsonb));
  return public.lab_save(p_room, s);
end $$;

-- 시간 초과 넘기기: 제한 시간이 지났으면 방 안의 누구든 호출 가능 (서버가 시간 검증)
create or replace function public.lab_timeout(p_room uuid)
returns public.lab_rooms language plpgsql security definer set search_path = public as $$
declare r public.lab_rooms := public.lab_lock(p_room); s jsonb := r.state; cur int;
begin
  if s->>'phase' <> 'playing' then return r; end if;
  if now() < (s->'turn'->>'deadline')::timestamptz then return r; end if;
  cur := (s->'turn'->>'idx')::int;
  s := public.lab_pset(s, cur, 'afk', to_jsonb(coalesce((s->'players'->cur->>'afk')::int, 0) + 1));
  s := public.lab_ev(s, jsonb_build_object('t', 'timeout', 'p', cur));
  return public.lab_save(p_room, public.lab_end_turn(s));
end $$;

-- ---------------------------------------------------------------------
-- 9. 함수 실행 권한: 내부 함수는 전부 막고, 공개 RPC 만 로그인(익명 포함) 사용자에게 허용
-- ---------------------------------------------------------------------
do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p
           join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname like 'lab\_%' loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
  end loop;
end $$;

grant execute on function public.lab_is_member(uuid)                  to authenticated;
grant execute on function public.lab_static()                         to authenticated;
grant execute on function public.lab_create_room(text)                to authenticated;
grant execute on function public.lab_join_room(text, text)            to authenticated;
grant execute on function public.lab_leave_room(uuid)                 to authenticated;
grant execute on function public.lab_kick(uuid, uuid)                 to authenticated;
grant execute on function public.lab_start_game(uuid)                 to authenticated;
grant execute on function public.lab_to_lobby(uuid)                   to authenticated;
grant execute on function public.lab_roll(uuid)                       to authenticated;
grant execute on function public.lab_move(uuid, int[])                to authenticated;
grant execute on function public.lab_use_card(uuid, text, jsonb)      to authenticated;
grant execute on function public.lab_timeout(uuid)                    to authenticated;

-- 끝. "Success. No rows returned" 가 나오면 정상입니다.
