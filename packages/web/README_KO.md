# @zntc/web

**[English](./README.md)** · 한국어

> ZNTC 의 web platform layer — dev server (HTTP/HTTPS + WebSocket HMR), HMR overlay, postcss / sass / lightningcss CSS 파이프라인, dev controller (file watcher + module graph).

[![npm](https://img.shields.io/npm/v/@zntc/web.svg)](https://www.npmjs.com/package/@zntc/web)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](https://github.com/ohah/zntc/blob/main/LICENSE)

`@zntc/web` 는 [ZNTC](https://github.com/ohah/zntc) 의 app 모드를 담당합니다 — `zntc dev` / `zntc preview` / `zntc build` 커맨드. WebSocket 기반 HMR 을 갖춘 dev server, 에러 overlay, CSS 파이프라인 (postcss / sass / lightningcss), 그리고 file watcher 와 module graph 를 연결하는 dev controller 를 제공합니다. `zntc` CLI 가 이 패키지를 자동으로 로드하므로 직접 import 할 일은 거의 없습니다.

## 설치

```bash
bun add -D @zntc/web
# 또는
npm i -D @zntc/web
```

`@zntc/core` (네이티브 NAPI 바이너리와 `zntc` CLI 포함) 가 dependency 로 자동 설치됩니다.

### Optional — CSS 파이프라인

```bash
bun add -D postcss postcss-load-config sass
```

- `postcss` / `postcss-load-config` — `postcss.config.{js,ts}` 자동 탐색 (Tailwind / PostCSS 플러그인)
- `sass` — `.scss` / `.sass` 파일 처리

모두 optional dependency 이므로 프로젝트에 필요한 것만 설치하면 됩니다.

## 사용

### Dev server + HMR

app 모드에서는 `zntc` CLI 가 `@zntc/web` 을 자동으로 dynamic import 합니다 — 패키지만 설치하면 됩니다:

```bash
bunx zntc dev       # dev server + HMR
bunx zntc build     # production app build
bunx zntc preview   # production preview server
```

`zntc dev` 는 앱을 HTTP (TLS 옵션 지정 시 HTTPS) 로 서빙하고, Hot Module Replacement 업데이트를 WebSocket 으로 전송하며, 빌드 에러를 브라우저의 HMR overlay 로 표시합니다.

### postcss / sass

optional CSS 패키지가 설치되면 CSS 파이프라인이 자동으로 활성화됩니다:

- `postcss.config.{js,ts}` 자동 탐색 (Tailwind / PostCSS 플러그인)
- `.scss` / `.sass` 파일을 `sass` 로 컴파일
- lightningcss 가 transform / minify 처리

관련 패키지 설치 외에 별도 설정은 필요하지 않습니다.

### 직접 import (고급)

`createAppDevController` 가 dev controller 의 main entry 입니다. `@zntc/core` 의 `prepareAppDevSync` 결과를 받으며, custom 툴링에 dev server 를 임베드할 수 있도록 넓은 옵션 surface 를 제공합니다. CSS 파이프라인용 `@zntc/web/css` entry 도 함께 export 합니다. 사용 예시는 [HMR 가이드](https://ohah.github.io/zntc) 를 참고합니다.

## Documentation

📚 **공식 문서: <https://ohah.github.io/zntc>**

- 모노레포 / 소스: <https://github.com/ohah/zntc>
- Config 레퍼런스와 HMR 세부 사항은 ZNTC 메인 문서에 포함되어 있습니다.

관련 패키지:

- [@zntc/core](https://www.npmjs.com/package/@zntc/core) — 트랜스파일러 / 번들러 코어
- [@zntc/react-native](https://www.npmjs.com/package/@zntc/react-native) — React Native platform layer
- [@zntc/vite-plugin](https://www.npmjs.com/package/@zntc/vite-plugin) — Vite 사용 시 ZNTC transform 적용

## License

MIT
