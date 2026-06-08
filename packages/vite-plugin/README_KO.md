# @zntc/vite-plugin

**[English](./README.md)** · 한국어

> Vite 의 esbuild transform 을 ZNTC 로 교체하는 플러그인 — TypeScript / JSX / Flow / decorators 변환을 ZNTC (Zig 기반) 가 담당하면서 Vite 의 dev server / HMR / plugin 생태계는 그대로 유지합니다.

[![npm](https://img.shields.io/npm/v/@zntc/vite-plugin.svg)](https://www.npmjs.com/package/@zntc/vite-plugin)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](https://github.com/ohah/zntc/blob/main/LICENSE)

이 플러그인은 Vite 의 내장 esbuild transform 단계를 Zig 로 작성된 단일 패스 트랜스파일러 [ZNTC](https://github.com/ohah/zntc) 로 교체합니다. TypeScript / JSX / Flow / decorator 변환이 모두 ZNTC 를 거치고, 나머지 Vite 파이프라인(dev server, HMR, 플러그인)은 그대로 유지됩니다.

## 설치

```bash
bun add -D @zntc/vite-plugin @zntc/core
# 또는
npm i -D @zntc/vite-plugin @zntc/core
```

네이티브 NAPI 바이너리를 포함하는 `@zntc/core` 를 플러그인과 함께 설치해야 합니다.

## 사용

```ts
// vite.config.ts
import { defineConfig } from 'vite';
import { zntc } from '@zntc/vite-plugin';

export default defineConfig({
  plugins: [zntc()],
  // esbuild 비활성화 — ZNTC 가 .ts / .tsx / .jsx 변환을 담당합니다.
  esbuild: false,
});
```

### 옵션

```ts
zntc({
  include: /\.(tsx?|jsx)$/, // 변환할 파일 패턴 (default)
  exclude: /node_modules/, // 제외 패턴 (default)
  tsconfigCache: true, // tsconfig autodiscover 결과 캐시 (default: true)
  transpileOptions: {
    // ZNTC transpile 옵션 (target / jsx / decorators 등)
    target: 'es2020',
    jsx: 'automatic',
  },
});
```

### Framework plugin 과 함께 쓰기

대부분의 framework plugin (`@vitejs/plugin-react`, `@vitejs/plugin-vue`, `@sveltejs/vite-plugin-svelte`, `vite-plugin-solid`) 은 ZNTC 와 충돌 없이 같이 쓸 수 있습니다. 다만 **babel 기반으로 `.tsx` 를 자체적으로 다시 변환하는 plugin** — 대표적으로 `@preact/preset-vite` — 와 함께 쓰면 `.tsx` 가 둘 다 처리되면서 결과가 깨질 수 있습니다 (component body 의 JSX return 이 비어버림).

이 경우 `jsx: 'preserve'` 옵션을 사용합니다. ZNTC 는 `.tsx` / `.jsx` 처리를 건너뛰고 framework plugin 이 JSX + TS 까지 모두 담당하며, `.ts` 는 그대로 ZNTC 가 처리합니다.

```ts
// preact + vite
import { defineConfig } from 'vite';
import preact from '@preact/preset-vite';
import { zntc } from '@zntc/vite-plugin';

export default defineConfig({
  plugins: [zntc({ transpileOptions: { jsx: 'preserve' } }), preact()],
});
```

`jsx: 'preserve'` 는 tsc 의 `"jsx": "preserve"` 와 동등한 의미 — JSX 변환을 downstream tool 에 위임합니다.

### Peer 요구사항

- `vite >= 5.0.0` (8.x 권장)

## 문서

- 모노레포: <https://github.com/ohah/zntc>
- 공식 문서: <https://ohah.github.io/zntc>

## 라이센스

MIT
