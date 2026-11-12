// 공개돼도 되는 값만 넣습니다. secret / service_role 키는 절대 넣지 마세요.
export const CONFIG = {
  SUPABASE_URL: 'https://lrduykklpmmafgfcgohf.supabase.co',
  SUPABASE_KEY: 'sb_publishable_uufIrxXkHH-NNQp7gK4yQg_exFxk6vf',

  // 외부 라이브러리 (CDN)
  SUPABASE_JS_URL: 'https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2/+esm',
  // 로컬 테스트 모드 전용: 브라우저 안에서 Postgres 를 돌려 서버와 똑같은 SQL 로 판정합니다.
  PGLITE_URL: 'https://cdn.jsdelivr.net/npm/@electric-sql/pglite@0.5.16/dist/index.js',
};
