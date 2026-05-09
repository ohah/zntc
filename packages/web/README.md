# @zntc/web

ZNTC 의 web platform layer — dev server (HTTP/HTTPS + WebSocket HMR), HMR overlay, postcss/sass/lightningcss CSS pipeline, dev controller (file watcher + module graph).

## 설치

```bash
bun add -D @zntc/web
# 또는
npm i -D @zntc/web
```

`@zntc/core` 가 dependency 로 자동 install 됨 (NAPI binary 포함).

### Optional (CSS pipeline)

```bash
bun add -D postcss postcss-load-config sass
```

- `postcss` / `postcss-load-config` — `postcss.config.{js,ts}` 자동 탐색 / Tailwind / PostCSS plugins
- `sass` — `.scss` / `.sass` 파일 처리

## 사용

`zntc dev`, `zntc preview`, `zntc build` (app mode) CLI 가 자동으로 `@zntc/web` 을 dynamic import 해서 사용. 사용자 코드에서 직접 import 할 일은 거의 없음.

```bash
bunx zntc dev       # dev server + HMR
bunx zntc build     # production app build
bunx zntc preview   # production preview server
```

자세한 설정: [docs/CONFIG.md](https://github.com/ohah/zntc/blob/main/docs/CONFIG.md) · [docs/HMR.md](https://github.com/ohah/zntc/blob/main/docs/HMR.md)

## 직접 import (고급)

`createAppDevController` 가 dev controller 의 main entry. 옵션 surface 가 넓고 `@zntc/core` 의 `prepareAppDevSync` 결과를 받음 — 사용 예는 [docs/HMR.md](https://github.com/ohah/zntc/blob/main/docs/HMR.md) 참조.

## 관련 패키지

- [@zntc/core](https://npmjs.com/package/@zntc/core) — 트랜스파일러 / 번들러 코어
- [@zntc/react-native](https://npmjs.com/package/@zntc/react-native) — RN platform layer
- [vite-plugin-zntc](https://npmjs.com/package/vite-plugin-zntc) — Vite 사용 시 ZNTC transform 적용

## 라이센스

MIT.
