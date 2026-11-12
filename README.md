# 과학 연구 쟁탈전 — 카오스 보드게임

주사위를 굴려 연구를 먹고, 카오스 카드로 판을 뒤집는 2~4인 웹 보드게임입니다.

## 파일 구성

이 사이트는 빌드 과정이 필요 없는 정적 웹사이트입니다. GitHub Pages가 저장소 루트의 `index.html`을 그대로 배포합니다.

- `index.html` — 페이지 화면과 앱 진입점
- `app.js`, `net.js`, `config.js` — 게임 화면, 네트워크 및 설정
- `style.css` — 화면 스타일
- `supabase_setup.sql` — 온라인 멀티플레이용 데이터베이스 설정
- `.github/workflows/pages.yml` — GitHub Pages 자동 배포

## 사이트 이용

배포 주소: https://sabinmn25.github.io/R-D-survival/

GitHub Actions가 `main` 브랜치의 변경 사항을 자동 배포합니다. 첫 배포가 진행 중이면 저장소의 **Actions** 탭에서 `Deploy to GitHub Pages` 작업이 완료될 때까지 기다려 주세요.

## 온라인 멀티플레이 설정

온라인 방 만들기와 참가를 사용하려면 Supabase 설정이 필요합니다.

1. `supabase_setup.sql` 내용을 Supabase 대시보드의 **SQL Editor**에 붙여넣고 실행합니다.
2. Supabase의 **Authentication → Sign In / Providers**에서 익명 로그인을 허용합니다.
3. `config.js`의 Supabase URL과 공개용 publishable/anon key가 프로젝트에 맞는지 확인합니다. `service_role` 같은 비밀 키는 절대 브라우저 코드에 넣지 않습니다.

아래의 **인터넷 없이 한 기기로 해보기 (로컬 테스트)**는 브라우저에서 바로 시도할 수 있습니다.

## 로컬 실행

파일을 직접 더블클릭하면 브라우저 모듈과 SQL을 불러오지 못할 수 있습니다. Python이 설치되어 있다면 저장소 폴더에서 다음을 실행한 뒤 `http://localhost:8000`을 여세요.

```bash
python3 -m http.server
```
