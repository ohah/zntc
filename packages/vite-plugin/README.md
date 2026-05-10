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

## peer

- `vite >= 5.0.0` (8.x 권장)

## 라이센스

MIT.
