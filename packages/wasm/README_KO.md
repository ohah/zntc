# @zntc/wasm

**[English](./README.md)** · 한국어

> [ZNTC](https://github.com/ohah/zntc) 의 WASM 빌드 — 네이티브 바이너리 없이 브라우저 / Deno / Cloudflare Workers 에서 JavaScript / TypeScript / Flow 를 트랜스파일·번들.

[![npm](https://img.shields.io/npm/v/@zntc/wasm.svg)](https://www.npmjs.com/package/@zntc/wasm)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](https://github.com/ohah/zntc/blob/main/LICENSE)

`@zntc/wasm` 은 ZNTC 파이프라인을 순수 WebAssembly 로 실행합니다. `@zntc/core` 의 NAPI 모듈을 로드할 수 없는 환경 — 브라우저 in-page transpile, Edge runtime, Cloudflare Workers, Deno — 에서 플랫폼별 `.node` 바이너리 없이 동작합니다.

Node / Bun 의 서버사이드 빌드에는 네이티브 속도의 [`@zntc/core`](https://www.npmjs.com/package/@zntc/core) 를 권장합니다. `@zntc/wasm` 은 환경 제약으로 NAPI 를 쓸 수 없을 때 사용하세요.

## 설치

```bash
bun add -D @zntc/wasm
# 또는
npm i -D @zntc/wasm
```

WASM 바이너리가 패키지와 함께 설치됩니다: `zntc.wasm` (~1.1 MB / gzipped 388 KB, transpile 전용), `zntc-bundler.wasm` (~2.0 MB / gzipped 675 KB, bundler).

## 사용법

### Browser / Edge runtime / Workers

```ts
import { init, transpile } from '@zntc/wasm';
import wasmUrl from '@zntc/wasm/zntc.wasm?url'; // Vite 전용 syntax

await init(wasmUrl);
const result = transpile('const x: number = 1;', { filename: 'input.ts' });
console.log(result.code);
```

> Vite 가 아닌 bundler 는 `fetch(new URL('@zntc/wasm/zntc.wasm', import.meta.url))` 또는 각자의 asset import 패턴으로 WASM URL 을 얻습니다.

### Deno / Node.js / Bun (auto-resolve)

```ts
import { init, transpile } from '@zntc/wasm';

await init(); // 동봉된 zntc.wasm 자동 로드 (fs.readFileSync)
const result = transpile('const x: number = 1;', { filename: 'input.ts' });
```

### Bundler 빌드

```ts
import { build, initBundler, bundlerLastErrorMessage } from '@zntc/wasm';
import wasmUrl from '@zntc/wasm/zntc-bundler.wasm?url';

await initBundler(wasmUrl); // transpile 용 init() 와 별도
const out = build('/main.ts', { format: 'esm', target: 'es2020' });
if (out === null) throw new Error(bundlerLastErrorMessage());
```

`build` 는 동기 함수이며 실패 시 `null` 을 반환합니다 — `bundlerLastErrorMessage()` 로 마지막 에러를 조회하세요.

## `@zntc/core` 와 차이

|               | `@zntc/core` (NAPI) | `@zntc/wasm`                              |
| ------------- | ------------------- | ----------------------------------------- |
| 환경          | Node.js / Bun       | + Browser / Edge / Workers / Deno         |
| 속도          | 네이티브            | ~50–70% (WASM 오버헤드)                   |
| 바이너리 크기 | ~4 MB (`.node`)     | 1.1 MB + 2.0 MB (gzipped 388 KB + 675 KB) |
| 설치          | 플랫폼별 prebuilt   | 단일 universal `.wasm`                    |

## 문서

- 저장소: <https://github.com/ohah/zntc>
- 공식 문서: <https://ohah.github.io/zntc>
- 네이티브 빌드: [`@zntc/core`](https://www.npmjs.com/package/@zntc/core)

## 라이센스

MIT
