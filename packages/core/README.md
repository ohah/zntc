# @zntc/core

ZNTC (Zig Native Transpiler & Compiler) 의 코어 — Zig 로 작성된 JS/TS/Flow 트랜스파일러 + 번들러의 Node.js NAPI 바인딩 + JS API + CLI.

SWC / oxc 와 동급 성능을 목표로, in-process 호출 (NAPI) + Vite/Rollup 어댑터 / 단독 CLI 모두 제공.

## 설치

```bash
bun add -D @zntc/core
# 또는
npm i -D @zntc/core
```

플랫폼별 prebuilt binary 가 함께 install 됨 (linux/darwin/windows × x64/arm64).

### Optional (필요 시)

```bash
bun add -D browserslist core-js core-js-compat lightningcss
```

- `browserslist` / `core-js-compat` — `runtimePolyfills` 옵션 사용 시
- `lightningcss` — CSS minify / nesting 사용 시

## CLI

```bash
# transpile single file
bunx zntc src/index.ts --outfile out.js

# bundle (multi-entry)
bunx zntc --bundle src/index.ts --outfile dist/bundle.js --format=esm --target=node
```

전체 옵션: `bunx zntc --help`

App-mode (`bunx zntc dev / build / preview`) 는 `@zntc/web` 또는 `@zntc/react-native` 가 함께 install 되어야 동작 — 각 패키지 README 참조.

## JS API

```ts
import { init, transpile, build } from '@zntc/core';

await init();

// 단일 파일 transpile
const r = transpile('const x: number = 1;', { filename: 'input.ts' });
console.log(r.code); // "const x = 1;"

// bundle (multi-file)
const out = await build({
  entryPoints: ['src/index.ts'],
  outdir: 'dist',
  format: 'esm',
  target: 'es2020',
});
```

자세한 옵션: [docs/CONFIG.md](https://github.com/ohah/zts/blob/main/docs/CONFIG.md) · [docs/USAGE.md](https://github.com/ohah/zts/blob/main/docs/USAGE.md)

## 관련 패키지

- [@zntc/web](https://npmjs.com/package/@zntc/web) — dev server + HMR overlay + postcss/sass
- [@zntc/react-native](https://npmjs.com/package/@zntc/react-native) — RN preset + Metro HMR adapter
- [@zntc/wasm](https://npmjs.com/package/@zntc/wasm) — browser-side WASM 빌드 (NAPI 대신)
- [@zntc/init](https://npmjs.com/package/@zntc/init) — 기존 RN 프로젝트에 ZNTC 도입
- [@zntc/vite-plugin](https://npmjs.com/package/@zntc/vite-plugin) — Vite 의 esbuild transform 을 ZNTC 로 교체

## 라이센스

MIT.
