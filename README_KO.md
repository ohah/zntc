# ZNTC

**[English](./README.md)** · 한국어

> **Zig Native Transpiler & Compiler** — JavaScript / TypeScript / Flow 를 네이티브 속도로 처리하는 트랜스파일러 + 번들러.

[![License](https://img.shields.io/badge/license-MIT-blue.svg)](./LICENSE)
[![Docs](https://img.shields.io/badge/docs-ohah.github.io/zntc-2b6cb0.svg)](https://ohah.github.io/zntc)
[![Test262](https://img.shields.io/badge/Test262-50,504%20/%2050,504-brightgreen.svg)](https://github.com/ohah/zntc/tree/main/docs/TESTING.md)
[![Status](https://img.shields.io/badge/status-pre--release-orange.svg)](#status)

ZNTC 는 SWC / oxc / esbuild 수준의 프로덕션 품질을 목표로 만들어진 단일 패스 툴체인입니다. 트랜스파일과 번들링이 같은 파이프라인을 공유하고, **Babel 없이도** styled-components / emotion / Reanimated worklets / Flow 같은 1st-party transform 을 본체에 내장합니다.

- 📦 **Single dependency** — `@zntc/core` 하나로 transpile + bundle + dev server (`zntc` CLI 포함)
- ⚡ **Native speed** — SIMD 렉서, Arena + mimalloc, 인덱스 기반 24B 고정 AST, Producer-Consumer 파이프라인
- 🔌 **Plugin compat** — Rollup / Vite 호환 훅 (`resolveId` / `load` / `transform`) + esbuild 호환 CLI / 옵션
- 📱 **React Native 1st-class** — Metro 호환 번들링, Flow, Reanimated worklets, Hermes 타겟, dev server
- 🌐 **Runs anywhere** — Node 24+, Bun 1.3+, 브라우저 WASM (transpile-only + bundler 포함)

---

## Installation

```bash
# Node / Bun
bun add -D @zntc/core
# npm i -D @zntc/core
# pnpm add -D @zntc/core
```

| 시나리오 | 추가로 필요한 패키지 |
|---|---|
| transpile / bundle (라이브러리 모드) | `@zntc/core` 단독 |
| dev / preview / build (postcss · sass · CSS Modules · HMR overlay) | `+ @zntc/web` |
| Vite 사용자 — esbuild transform 만 ZNTC 로 교체 | `@zntc/vite-plugin` |
| React Native (init / preset / dev server) | `+ @zntc/react-native` |
| 브라우저 playground / Workers | `@zntc/wasm` |

> **Status**: pre-release. NAPI 바이너리는 macOS / Linux / Windows × x64 / arm64 사전 빌드. 자세한 빌드 매트릭스는 [docs/PUBLISH.md](./docs/PUBLISH.md).

## Quick start

### CLI

```bash
# 단일 파일 트랜스파일 (.ts → .js, sourcemap 동반)
npx zntc src/index.ts --outdir dist

# 번들 (esbuild 호환 옵션)
npx zntc src/index.ts --bundle --outdir dist --format=esm --target=es2022

# Dev server + HMR + Fast Refresh
npx zntc serve src/main.tsx --port 5173

# React Native (Metro 호환)
npx zntc --bundle index.js --platform=react-native --rn-platform=ios -o bundle.js
```

`zntc --help` 로 전체 옵션 확인.

### `@zntc/core` JS / NAPI API

```ts
import { transpile, build } from "@zntc/core";

// 단일 파일 트랜스파일 — NAPI 바인딩은 첫 호출 시 자동 로드
const { code, map } = transpile(source, {
  filename: "input.ts",
  jsx: "automatic",
  target: "es2022",
  sourcemap: true,
});

// 번들링 (esbuild / Vite / Rollup 호환 플러그인 훅)
const result = await build({
  entryPoints: ["src/index.ts"],
  bundle: true,
  format: "esm",
  platform: "browser",
  target: ["chrome100", "safari16"],
  define: { "process.env.NODE_ENV": '"production"' },
  plugins: [
    {
      name: "my-plugin",
      setup(build) {
        build.onResolve({ filter: /^virtual:/ }, (args) => ({ path: args.path, namespace: "virtual" }));
        build.onLoad({ filter: /.*/, namespace: "virtual" }, () => ({ contents: "export const x = 1" }));
      },
    },
  ],
});
```

### Vite 통합

```ts
// vite.config.ts
import { defineConfig } from "vite";
import zntc from "@zntc/vite-plugin";

export default defineConfig({
  plugins: [zntc()],
});
```

Vite 의 esbuild transform 단계가 ZNTC 로 교체되어 TS / JSX / Flow / 1st-party transform 까지 단일 패스로 처리됩니다.

### React Native CLI 프로젝트 부착

```bash
npx @zntc/init
```

기존 RN CLI 앱의 `start` / `bundle:*` 스크립트를 ZNTC 로 교체합니다 (Metro fallback 은 보존). 자세한 절차는 [React Native 가이드](https://ohah.github.io/zntc/guides/react-native/)와 [`zntc.config.ts` 예시](./docs/CONFIG.md#react-native-config-예제)를 참고합니다.

## Features

### Babel 없이 1st-party transform

다른 번들러에서 별도 Babel 플러그인이 필요한 변환을 ZNTC 는 본체에 내장합니다.

```ts
// zntc.config.ts
import { defineConfig } from "@zntc/core";

export default defineConfig({
  platform: "react-native",      // flow / worklets / RN preset 자동
  jsxImportSource: "@emotion/react",
  compiler: {
    styledComponents: true,      // babel-plugin-styled-components 대응
    emotion: { autoLabel: "dev-only" },  // @emotion/babel-plugin 대응
  },
});
```

| Babel 플러그인 | ZNTC 옵션 |
|---|---|
| `babel-plugin-styled-components` | `compiler.styledComponents` |
| `@emotion/babel-plugin` | `compiler.emotion` |
| `react-native-worklets/plugin` | `workletTransform` (RN 자동) |
| `@babel/preset-flow` | `flow: true` (RN 자동) |
| `@babel/preset-env` | `target: "es2020"` / `target: "hermes0.70"` |

자세한 사용법: [네이티브 트랜스폼 가이드](https://ohah.github.io/zntc/guides/native-transforms/).

### Plugin / 옵션 호환

- **Rollup / Vite 스타일 훅**: `resolveId`, `load`, `transform` (filter 함수 / RegExp / string 모두 지원)
- **esbuild 호환 옵션 surface**: `entryPoints`, `bundle`, `format`, `target`, `define`, `loader`, `external`, `metafile`
- **Vite alias 호환**: object `Record<string, string>` + array `{ find, replacement }` 형태 모두
- **`zntc.config.{ts,js,json}`** + tsconfig + `.env` + CLI flag 우선순위 머지 ([docs/CONFIG.md](./docs/CONFIG.md))

### 성능

| 항목 | 결과 |
|---|---|
| Test262 TC39 정합성 | **50,504 / 50,504 통과 (100%, 0 fail)** |
| 144 npm 패키지 스모크 (build + execute) | esbuild 대비 평균 **0.82x bundle size** |
| 합성 벤치 (parse + emit) | ZNTC **7ms** · Bun 10ms · esbuild 13ms · rolldown 62ms |
| RN core (`react-native` 0.74) | 410 개 `@flow` 파일 회귀 통과 |
| HMR warm rebuild | **< 100ms** (PR #1747) |

자세한 데이터: [docs/ROADMAP.md](./docs/ROADMAP.md) · [docs/TESTING.md](./docs/TESTING.md) · [벤치마크 사이트](https://ohah.github.io/zntc/reference/benchmarks/).

## Documentation

📚 **공식 문서 사이트: <https://ohah.github.io/zntc>**

주요 가이드:

- [소개](https://ohah.github.io/zntc/guides/introduction/) · [설치](https://ohah.github.io/zntc/guides/installation/) · [빠른 시작](https://ohah.github.io/zntc/guides/quick-start/)
- [설정 파일](https://ohah.github.io/zntc/guides/config-file/) · [네이티브 트랜스폼 (Babel 없이)](https://ohah.github.io/zntc/guides/native-transforms/)
- [번들링 개요](https://ohah.github.io/zntc/guides/bundling/) · [트리쉐이킹](https://ohah.github.io/zntc/guides/tree-shaking/) · [구조와 동작 원리](https://ohah.github.io/zntc/guides/bundler-deep-dive/)
- [React Native](https://ohah.github.io/zntc/guides/react-native/) · [Flow 지원](https://ohah.github.io/zntc/guides/flow-support/) · [Babel 이관](https://ohah.github.io/zntc/guides/babel-migration/)
- [플러그인](https://ohah.github.io/zntc/guides/plugins/) · [플러그인 레시피](https://ohah.github.io/zntc/guides/plugin-recipes/) · [Rspack / Webpack 통합](https://ohah.github.io/zntc/guides/rspack-loader/)
- [도구 비교](https://ohah.github.io/zntc/guides/comparison/) · [다른 도구에서 이관](https://ohah.github.io/zntc/guides/migration/)
- [CLI 레퍼런스](https://ohah.github.io/zntc/reference/cli/) · [NAPI / JS API](https://ohah.github.io/zntc/reference/napi/) · [Transpile 옵션](https://ohah.github.io/zntc/reference/options/)

기여자용 내부 문서 (저장소 내):

- [docs/ARCHITECTURE.md](./docs/ARCHITECTURE.md) · [docs/BUNDLER.md](./docs/BUNDLER.md) · [docs/HMR.md](./docs/HMR.md) · [docs/PLUGINS.md](./docs/PLUGINS.md)
- [docs/ROADMAP.md](./docs/ROADMAP.md) · [docs/TESTING.md](./docs/TESTING.md) · [docs/DECISIONS.md](./docs/DECISIONS.md) · [docs/INVARIANTS.md](./docs/INVARIANTS.md)
- [docs/FLOW.md](./docs/FLOW.md) · [docs/DEBUG.md](./docs/DEBUG.md) · [docs/AST_PLUGINS.md](./docs/AST_PLUGINS.md) · [docs/BACKLOG.md](./docs/BACKLOG.md)

## Packages

| 패키지 | 역할 |
|---|---|
| **`@zntc/core`** | NAPI .node 바인딩 + Node / Bun CLI (`zntc`) + transpile / bundle / lightningcss |
| **`@zntc/web`** | dev server + HMR overlay + postcss / sass pipeline + dev controller |
| **`@zntc/vite-plugin`** | Vite 의 esbuild transform 을 ZNTC 로 교체 (`@zntc/core` 만 사용) |
| **`@zntc/rspack-loader`** | Rspack / Webpack 의 TS/JSX/Flow loader (swc-loader / esbuild-loader 대체) |
| **`@zntc/react-native`** | RN preset + Metro 호환 dev server + Reanimated worklets / Flow / Hermes |
| **`@zntc/init`** | `npx @zntc/init` — 신규 프로젝트 scaffold + 기존 RN CLI 앱 overlay |
| **`@zntc/wasm`** | WASM 빌드 (브라우저 playground / Deno / Workers) |
| `@zntc/server` | private — protocol / WS frame / watcher / HMR channel (web 의 dist 에 inline, 사용자 install 불필요) |

## Status

**Phase 1–6 전반 완료** — 렉서 / 파서 / 세만틱 / 트랜스포머 / 코드젠 / 번들러 / Dev 서버 / HMR.

- Test262: **50,504 / 50,504 (100%)**, 0 fail
- npm 패키지 스모크: **144 / 144** 통과 (esbuild / rolldown / rspack 비교)
- RN core (`react-native` 0.74) 410 개 `@flow` 파일 회귀 통과

미해결 이슈와 백로그는 [docs/ROADMAP.md](./docs/ROADMAP.md) · [docs/BACKLOG.md](./docs/BACKLOG.md) · [GitHub Issues](https://github.com/ohah/zntc/issues).

## Contributing

ZNTC 의 핵심은 Zig 로 작성되어 있습니다. 소스에서 빌드하려면 Zig 0.15.2 가 필요합니다 (mise 권장).

```bash
git clone https://github.com/ohah/zntc.git
cd zntc
mise install

# 빌드
zig build                          # zntc CLI + lib (Debug)
zig build -Doptimize=ReleaseFast   # 성능 측정용
zig build run -- src/index.ts      # CLI 직접 실행

# 테스트
zig build test                     # Zig 유닛 / 통합 테스트
zig build test262-run              # Test262 50,504건 실행
zig build napi                     # @zntc/core 용 NAPI .node
zig build wasm                     # transpile-only WASM
zig build wasm-bundler             # bundler 포함 WASM (wasm32-wasi + threads)
zig build schema                   # BuildOptions JSON 스키마 자동 생성
```

JS 사이드 테스트:

```bash
cd tests/integration && bun test       # CLI / NAPI 통합 테스트
cd tests/e2e && bun test               # Playwright E2E
cd tests/benchmark && bun run smoke.ts # 144 패키지 빌드+실행 vs esbuild/rolldown/rspack
```

기여 워크플로 — [CLAUDE.md](./CLAUDE.md): feature branch → PR → merge. main 직접 push 금지. PR 제목은 `feat(lexer): add numeric literal tokenization` 형식, 본문 한국어.

## References

- [Bun JS Parser](https://github.com/oven-sh/bun) (Zig, MIT) — 파서 / 렉서 / SIMD
- [oxc](https://github.com/oxc-project/oxc) (Rust, MIT) — 트랜스포머 / Reference flags
- [SWC](https://github.com/swc-project/swc) (Rust, Apache-2.0) — 다운레벨 비교
- [esbuild](https://github.com/evanw/esbuild) (Go, MIT) — 번들러 아키텍처 / 호환
- [Rolldown](https://github.com/rolldown/rolldown) (Rust, MIT) — Rollup 호환 / Vite 통합
- [Hermes](https://github.com/facebook/hermes) (C++, MIT) — Flow 파서 임베딩 + RN 런타임
- [Metro](https://github.com/facebook/metro) (JS, MIT) — React Native 번들러 호환
- [TypeScript](https://github.com/microsoft/TypeScript) (TS, Apache-2.0) — 다운레벨 / decorator 케이스
- [Test262](https://github.com/tc39/test262) — TC39 정합성 50,504건

## License

MIT
