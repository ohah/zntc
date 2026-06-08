# @zntc/core

**[English](./README.md)** · 한국어

> ZNTC (Zig Native Transpiler & Compiler) 의 코어 — Zig 로 작성된 JS / TS / Flow 트랜스파일러 + 번들러의 NAPI 바인딩 + JS API + `zntc` CLI.

[![npm](https://img.shields.io/npm/v/@zntc/core.svg)](https://www.npmjs.com/package/@zntc/core)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](https://github.com/ohah/zntc/blob/main/LICENSE)

`@zntc/core` 는 네이티브 `.node` NAPI 바인딩과 Node.js / Bun 용 `zntc` CLI 를 제공합니다. SWC / oxc 와 동급 성능을 목표로 in-process 호출 (NAPI), Vite / Rollup 어댑터, 단독 CLI 를 모두 지원하며 transpile · bundle · lightningcss 기반 CSS 처리를 담당합니다.

## 설치

```bash
bun add -D @zntc/core
# 또는
npm i -D @zntc/core
```

플랫폼별 prebuilt binary 가 함께 설치됩니다 (linux / darwin / windows × x64 / arm64).

### Optional (필요 시)

```bash
bun add -D browserslist core-js core-js-compat lightningcss
```

- `browserslist` / `core-js-compat` — `runtimePolyfills` 옵션 사용 시
- `lightningcss` — CSS minify / nesting 사용 시

## 사용법

### CLI

```bash
# 단일 파일 트랜스파일
bunx zntc src/index.ts --outfile out.js

# 번들 (멀티 엔트리)
bunx zntc --bundle src/index.ts --outfile dist/bundle.js --format=esm --target=node
```

전체 옵션: `bunx zntc --help`

App 모드 (`bunx zntc dev / build / preview`) 는 `@zntc/web` 또는 `@zntc/react-native` 가 함께 설치되어 있어야 동작합니다 — 각 패키지 README 를 참고하세요.

### JS / NAPI API

```ts
import { init, transpile, build } from '@zntc/core';

await init();

// 단일 파일 트랜스파일
const r = transpile('const x: number = 1;', { filename: 'input.ts' });
console.log(r.code); // "const x = 1;"

// 번들 (멀티 파일)
const out = await build({
  entryPoints: ['src/index.ts'],
  outdir: 'dist',
  format: 'esm',
  target: 'es2020',
});
```

## 관련 패키지

- [@zntc/web](https://npmjs.com/package/@zntc/web) — dev server + HMR overlay + postcss / sass
- [@zntc/react-native](https://npmjs.com/package/@zntc/react-native) — RN preset + Metro HMR adapter
- [@zntc/wasm](https://npmjs.com/package/@zntc/wasm) — 브라우저용 WASM 빌드 (NAPI 대신)
- [@zntc/init](https://npmjs.com/package/@zntc/init) — 기존 RN 프로젝트에 ZNTC 도입
- [@zntc/vite-plugin](https://npmjs.com/package/@zntc/vite-plugin) — Vite 의 esbuild transform 을 ZNTC 로 교체

## 문서

- 저장소: <https://github.com/ohah/zntc>
- 문서: <https://ohah.github.io/zntc>

## 라이센스

MIT
