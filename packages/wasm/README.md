# @zntc/wasm

ZNTC 의 WASM 빌드 — 브라우저 / Bun / Node 환경에서 native binary (`zntc.node`) 없이 순수 WASM 으로 트랜스파일/번들 실행.

`@zntc/core` 의 NAPI 모듈을 쓸 수 없는 환경 (Edge runtime, Cloudflare Workers, 브라우저 in-page transpile 등) 용.

## 설치

```bash
bun add -D @zntc/wasm
# 또는
npm i -D @zntc/wasm
```

WASM binary (`zntc.wasm` ~370KB / `zntc-bundler.wasm` ~700KB) 가 함께 install 됨.

## 사용 예

### Browser / Edge runtime

```ts
import { init, transpile } from '@zntc/wasm';
import wasmUrl from '@zntc/wasm/zntc.wasm?url'; // Vite 전용 syntax

await init(wasmUrl);
const r = transpile('const x: number = 1;', { filename: 'input.ts' });
console.log(r.code);
```

> Vite 가 아닌 bundler 는 `fetch(new URL('@zntc/wasm/zntc.wasm', import.meta.url))` 또는 각자의 asset import 패턴 사용.

### Node.js / Bun (auto-resolve)

```ts
import { init, transpile } from '@zntc/wasm';

await init(); // 동봉 zntc.wasm 자동 로드 (fs.readFileSync)
const r = transpile('const x: number = 1;', { filename: 'input.ts' });
```

### Bundler 사용

```ts
import { bundlerLastErrorMessage, build, init } from '@zntc/wasm';
import wasmUrl from '@zntc/wasm/zntc-bundler.wasm?url';

await init(wasmUrl); // bundler 는 별도 wasm
const out = build('/main.ts', { format: 'esm', target: 'es2020' });
if (out === null) throw new Error(bundlerLastErrorMessage());
```

`build` 는 sync 이며 실패 시 `null` 반환 — `bundlerLastErrorMessage()` 로 마지막 에러 조회.

## NAPI 와 차이

| 항목        | @zntc/core (NAPI) | @zntc/wasm                 |
| ----------- | ----------------- | -------------------------- |
| 환경        | Node.js / Bun     | + Browser / Edge / Workers |
| 속도        | 빠름 (~native)    | 50~70% (WASM 오버헤드)     |
| binary 크기 | ~4MB (.node)      | ~370KB + 700KB (.wasm)     |
| install     | 플랫폼별 prebuilt | 단일 wasm (universal)      |

대부분의 server-side 빌드 사용 사례는 `@zntc/core` 권장. `@zntc/wasm` 은 환경 제약 시.

## 관련

- [@zntc/core](https://npmjs.com/package/@zntc/core) — Native (NAPI) 빌드
- [docs/USAGE.md](https://github.com/ohah/zntc/blob/main/docs/USAGE.md)

## 라이센스

MIT.
