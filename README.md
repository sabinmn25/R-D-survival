# 과학 연구 쟁탈전 — 카오스 보드게임

주사위를 굴려 연구를 먹고, 카오스 카드로 판을 뒤집는 2~4인 웹 보드게임.

## 폴더 구성
- `index.html`, `css/`, `js/` — 게임 화면 (빌드 과정 없음, 그대로 올리면 됨)
- `js/config.js` — Supabase 주소와 공개 키 (secret 키는 절대 넣지 않기)
- `sql/supabase_setup.sql` — Supabase SQL Editor에서 한 번 실행하는 세팅 파일. 게임 규칙·판정이 전부 여기 있음

## Supabase에서 해야 할 것
1. SQL Editor에 `sql/supabase_setup.sql` 전체를 붙여넣고 Run
2. Authentication → Sign In / Providers → **Allow anonymous sign-ins** 켜기

## GitHub Pages 배포
1. 이 폴더 안의 파일을 전부 저장소 최상위에 올리기
2. 저장소 Settings → Pages → Source: **Deploy from a branch**, Branch: **main / (root)** → Save
3. 1~2분 뒤 `https://<아이디>.github.io/<저장소 이름>/` 에서 열림

## 밸런스 조정
Supabase Table Editor의 `lab_config` 표에서 숫자를 고치면 다음 판부터 적용됩니다
(라운드 수, 턴 제한 시간, 카오스 카드 등장 확률 등).
카드 내용과 지도는 `sql/supabase_setup.sql`의 4번 구역을 고친 뒤 SQL을 다시 실행하면 됩니다.

## 로컬 테스트
첫 화면의 "인터넷 없이 한 기기로 해보기"는 브라우저 안에서 같은 SQL을 돌려 서버와 똑같은 규칙으로 판정합니다.
파일을 더블클릭으로 열면 동작하지 않으니, 배포된 주소에서 열거나 `python3 -m http.server` 로 띄워서 여세요.
