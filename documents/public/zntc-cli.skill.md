---
name: zntc-cli
description: ZNTC (Zig Native Transpiler & Compiler) 설치 + CLI/NAPI 사용. JS/TS/JSX/Flow transpile, bundle, tree-shake, minify. esbuild/Bun/rolldown/rspack 대체용 (transpile small -62% / bundle small 1위)
---

# ZNTC 사용 가이드 (Claude Code skill)

LLM (Claude / GPT 등) 이 ZNTC 의 *설치 + 사용* 을 빠르게 이해하도록 구성. `~/.claude/skills/zntc-cli/SKILL.md` 또는 프로젝트 `.claude/skills/zntc-cli/SKILL.md` 위치.

## 무엇

ZNTC = Zig 로 작성한 JS/TS 트랜스파일러 + 번들러:
- **트랜스파일**: TS 타입 strip, JSX, Flow, ES2015+ 다운레벨
- **번들**: Tree-shake + minify, rolldown/esbuild 동급 속도, 일부 lib 더 작음
- **호출 방식**: CLI binary, C NAPI (.node), WASM, Vite/Rollup plugin adapter

## 설치

### Option A: CLI binary (가장 단순)

```sh
# 한 번에 설치 (release binary 다운로드)
curl -fsSL https://raw.githubusercontent.com/ohah/zntc/main/install.sh | sh

# 또는 npm
npm install -g @zntc/core
```

### Option B: 개별 패키지

```sh
# Bundler / CLI (rolldown 대체)
npm install --save-dev @zntc/core

# Vite 플러그인 (rollup 대체)
npm install --save-dev @zntc/vite-plugin

# Rollup 플러그인
npm install --save-dev @zntc/rollup-plugin
```

## 빠른 시작

### Transpile (TS → JS)

```sh
zntc input.ts -o output.js
zntc input.tsx -o output.js --jsx automatic
zntc src/main.ts --target=es2020 -o dist/main.js
```

### Bundle

```sh
# 단일 파일 번들 (esbuild 동급 사용법)
zntc --bundle src/index.ts -o dist/bundle.js

# Multi-format (rollup-style)
zntc --bundle src/index.ts \
  --format=esm --output=dist/esm/bundle.mjs \
  --format=cjs --output=dist/cjs/bundle.cjs
```

### NAPI (Node.js / Bun in-process — 50× faster than CLI spawn)

```ts
import { transpile, bundle } from '@zntc/core';

// Transpile
const { code, map } = transpile(source, {
  filename: 'input.tsx',
  jsx: 'automatic',
  target: 'es2022',
});

// Bundle
const result = await bundle({
  entryPoints: ['src/index.ts'],
  outdir: 'dist',
  format: 'esm',
  minify: true,
  treeShake: true,
});
```

### Vite plugin (vite.config.ts)

```ts
import { defineConfig } from 'vite';
import zntc from '@zntc/vite-plugin';

export default defineConfig({
  plugins: [zntc()],
});
```

## 주요 옵션

| Flag | 의미 |
|---|---|
| `--bundle` | 번들 모드 (없으면 transpile only) |
| `--format=esm/cjs/iife` | 출력 모듈 형식 |
| `--target=es5/es2015/es2020/es2022` | ECMAScript 타깃 (다운레벨링) |
| `--jsx=automatic/classic/preserve` | JSX 변환 모드 |
| `--minify` / `--minify-identifiers` / `--minify-whitespace` | minify 모드 (esbuild 동등) |
| `--tree-shake` | tree-shaking 활성 (`--bundle` 시 default on) |
| `--watch` | watch mode (HMR — incremental rebuild ~22 ms / 641 module) |
| `--profile=parse,transform,...` | 단계별 timing stdout (debug) |
| `--target-platform=node/browser/react-native` | resolution 플랫폼 |

## 성능 지표 (2026-05-21, darwin arm64, 20-run median)

| Task | ZNTC | esbuild | Bun | rolldown | rspack |
|---|---|---|---|---|---|
| Transpile 100 lines | **1.79 ms** | 3.90 | 5.16 | — | — |
| Transpile 1K lines | 3.02 ms | 4.79 | 5.59 | — | — |
| Bundle 10 modules | **2.62 ms** | 10.8 | 8.05 | 52.3 | 62.4 |
| Bundle 1K modules | **17.0 ms** | 26.8 | 23.3 | 70.2 | 83.8 |
| Bundle 5K modules | 81.7 ms | 89.1 | **66.4** | 126 | 181 |

## 실전 워크플로

### React + TypeScript SPA

```sh
# Dev (watch)
zntc --bundle src/index.tsx --watch --jsx=automatic -o dist/bundle.js

# Production
zntc --bundle src/index.tsx \
  --jsx=automatic \
  --target=es2020 \
  --minify \
  --tree-shake \
  -o dist/bundle.js
```

### Library publish (Multi-format)

```sh
zntc --bundle src/index.ts \
  --format=esm --output=dist/index.mjs \
  --format=cjs --output=dist/index.cjs \
  --target=es2018 \
  --minify
```

### Existing Vite project (drop-in)

```ts
// vite.config.ts
import zntc from '@zntc/vite-plugin';

export default {
  plugins: [zntc({ tsconfig: './tsconfig.json' })],
};
```

## 한계 / 미지원

- WASM build: `.wasm` 타깃 미릴리스 (계획 중)
- Hermes regex named capture group 다운레벨: 미지원 (Hermes 한계, 기록만 strip)
- Multi-format + dev_mode/splitting/MF 조합 거부 (error 명시)
- 일부 minify case 에서 zod/effect 가 rolldown 보다 약간 큼 (mangler 격차, deferred)

## 참고 자료

- 공식 docs: https://ohah.github.io/zntc/
- 영어 docs: https://ohah.github.io/zntc/en/
- llms.txt (사이트맵): https://ohah.github.io/zntc/llms.txt
- llms-full.txt (전체 docs plain text): https://ohah.github.io/zntc/llms-full.txt
- GitHub: https://github.com/ohah/zntc
- Playground: https://ohah.github.io/zntc/playground/

## Claude Code 설치 방법

이 파일을 다음 위치에 저장:
```sh
mkdir -p ~/.claude/skills/zntc-cli
curl -fsSL https://ohah.github.io/zntc/zntc-cli.skill.md > ~/.claude/skills/zntc-cli/SKILL.md
```

또는 프로젝트 단위:
```sh
mkdir -p .claude/skills/zntc-cli
curl -fsSL https://ohah.github.io/zntc/zntc-cli.skill.md > .claude/skills/zntc-cli/SKILL.md
```

설치 후 Claude Code 가 `zntc` 또는 `transpile` 관련 작업 시 이 skill 을 *자동 활용*.
