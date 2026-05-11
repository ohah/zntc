# @zntc/vite-plugin

Vite 의 esbuild transform 을 ZNTC 로 교체하는 플러그인. TypeScript / JSX / Flow / decorators 변환을 ZNTC (Zig 기반) 가 담당하면서 Vite 의 dev server / HMR / plugin 생태계는 그대로 유지.

## 설치

```bash
bun add -D @zntc/vite-plugin @zntc/core
# 또는
npm i -D @zntc/vite-plugin @zntc/core
```

`@zntc/core` 가 dependency 로 함께 따라옴 (NAPI binary 포함).

## 사용

```ts
// vite.config.ts
import { defineConfig } from 'vite';
import { zntc } from '@zntc/vite-plugin';

export default defineConfig({
  plugins: [zntc()],
  // esbuild 자동 비활성화 (zntc 가 .ts/.tsx/.jsx 변환 담당)
  esbuild: false,
});
```

## 옵션

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

## Framework plugin 과 함께 쓰기

대부분의 framework plugin (`@vitejs/plugin-react`, `@vitejs/plugin-vue`,
`@sveltejs/vite-plugin-svelte`, `vite-plugin-solid`) 은 ZNTC 와 충돌 없이 같이
쓸 수 있습니다. 다만 **babel 기반으로 `.tsx` 를 자체적으로 다시 변환하는 plugin**
— 대표적으로 `@preact/preset-vite` — 와 함께 쓰면 `.tsx` 가 둘 다 처리되면서
결과가 깨질 수 있습니다 (component body 의 JSX return 이 비어버림).

이 경우 `jsx: 'preserve'` 옵션을 사용합니다 — ZNTC 는 `.tsx`/`.jsx` 처리를
건너뛰고 framework plugin 이 JSX + TS 까지 모두 담당합니다. `.ts` 는 그대로
ZNTC 가 처리.

```ts
// preact + vite
import { defineConfig } from 'vite';
import preact from '@preact/preset-vite';
import { zntc } from '@zntc/vite-plugin';

export default defineConfig({
  plugins: [zntc({ transpileOptions: { jsx: 'preserve' } }), preact()],
});
```

`jsx: 'preserve'` 는 tsc `"jsx": "preserve"` 와 동등한 의미 — JSX 변환을
downstream tool 에 위임합니다.

## peer

- `vite >= 5.0.0` (8.x 권장)

## 라이센스

MIT.
