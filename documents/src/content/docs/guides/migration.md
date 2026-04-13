---
title: 마이그레이션 가이드
description: esbuild, Vite, webpack에서 ZTS로 마이그레이션하는 방법을 알아봅니다.
---

## esbuild에서 마이그레이션

ZTS는 esbuild와 거의 동일한 CLI 옵션을 지원합니다. 대부분의 경우 `esbuild`를 `zts`로 바꾸면 됩니다.

### CLI 옵션 대응표

| esbuild | ZTS | 비고 |
|---------|-----|------|
| `esbuild src/index.ts --bundle` | `zts --bundle src/index.ts` | 동일 |
| `--outfile=dist/out.js` | `-o dist/out.js` | 축약 지원 |
| `--outdir=dist` | `--outdir dist` | 동일 |
| `--format=esm` | `--format=esm` | 동일 (esm/cjs/iife/umd/amd) |
| `--platform=node` | `--platform=node` | 동일 (browser/node/neutral/react-native) |
| `--minify` | `--minify` | 동일 (`--minify-{whitespace,syntax,identifiers}` 세분화 지원) |
| `--sourcemap` | `--sourcemap` | 동일 |
| `--splitting` | `--splitting` | 동일 |
| `--target=es2020` | `--target=es2020` | 동일 |
| `--external:react` | `--external react` | `:` 대신 공백 |
| `--define:X=Y` | `--define:X=Y` | 동일 |
| `--loader:.css=text` | `--loader:.css=text` | 동일 |
| `--watch` | `--watch` 또는 `-w` | 동일 |
| `--serve` | `--serve` | 동일 |
| `--metafile=meta.json` | `--metafile=meta.json` | 동일 |
| `--legal-comments=eof` | `--legal-comments=eof` | 동일 |
| `--keep-names` | `--keep-names` | 동일 |
| `--drop:console` | `--drop=console` | `:` 대신 `=` |
| `--inject:./shim.js` | `--inject:./shim.js` | 동일 |
| `--alias:react=preact/compat` | `--alias:react=preact/compat` | 동일 |
| `--entry-names=[name]-[hash]` | `--entry-names=[name]-[hash]` | 동일 |
| `--chunk-names=chunks/[hash]` | `--chunk-names=chunks/[hash]` | 동일 |
| `--asset-names=assets/[hash]` | `--asset-names=assets/[hash]` | 동일 |

### esbuild Build API 마이그레이션

```typescript
// esbuild
import * as esbuild from 'esbuild';
await esbuild.build({
  entryPoints: ['src/index.ts'],
  bundle: true,
  outdir: 'dist',
  format: 'esm',
  minify: true,
});

// ZTS — 거의 동일
import { build } from '@zts/plugin';
await build({
  entryPoints: ['src/index.ts'],
  bundle: true,
  outdir: 'dist',
  format: 'esm',
  minify: true,
});
```

### esbuild 플러그인 마이그레이션

ZTS 플러그인은 Rollup/Vite 스타일 훅을 사용합니다.

```typescript
// esbuild 플러그인
const myPlugin = {
  name: 'my-plugin',
  setup(build) {
    build.onResolve({ filter: /^virtual:/ }, args => ({
      path: args.path,
      namespace: 'virtual',
    }));
    build.onLoad({ filter: /.*/, namespace: 'virtual' }, args => ({
      contents: 'export default 42',
      loader: 'js',
    }));
  },
};

// ZTS 플러그인 — Rollup/Vite 스타일
const myPlugin = {
  name: 'my-plugin',
  resolveId(source) {
    if (source.startsWith('virtual:')) {
      return { path: '\0' + source };
    }
    return null;
  },
  load(id) {
    if (id.startsWith('\0virtual:')) {
      return { contents: 'export default 42' };
    }
    return null;
  },
};
```

### 지원하지 않는 esbuild 옵션

| esbuild 옵션 | 대안 |
|-------------|------|
| `--format=umd` | 미지원. IIFE + 수동 UMD 래퍼 사용 |
| `--mangle-props` | 미지원 |
| `--analyze` (상세 트리) | `--analyze` (JSON 출력, 트리 포맷 예정) |

## Vite에서 마이그레이션

Vite는 개발 서버 + 프로덕션 번들러(Rollup/Rolldown)의 조합입니다. ZTS는 단독 번들러이므로 Vite의 모든 기능을 대체하지는 않습니다.

### Vite 프로덕션 빌드 대체

```bash
# Vite
vite build

# ZTS
zts --bundle src/main.ts --outdir dist --format=esm --splitting --minify --sourcemap
```

### vite.config.ts 대응

```typescript
// vite.config.ts
export default defineConfig({
  build: {
    outDir: 'dist',
    minify: true,
    sourcemap: true,
    rollupOptions: {
      external: ['react', 'react-dom'],
    },
  },
});

// zts CLI 대응
// zts --bundle src/main.ts --outdir dist --minify --sourcemap --external react --external react-dom
```

### Vite 플러그인 → ZTS 플러그인

Vite/Rollup 플러그인의 `resolveId`, `load`, `transform` 훅은 ZTS에서 동일하게 동작합니다.

```typescript
// zts.config.ts
import { defineConfig } from '@zts/plugin';

export default defineConfig({
  plugins: [
    {
      name: 'svg-loader',
      load(id) {
        if (id.endsWith('.svg')) {
          const fs = require('fs');
          const svg = fs.readFileSync(id, 'utf8');
          return { contents: `export default ${JSON.stringify(svg)}` };
        }
        return null;
      },
    },
  ],
});
```

### 미지원 Vite 기능

| Vite 기능 | ZTS 대안 |
|----------|---------|
| `import.meta.glob` | 미지원 (구현 예정) |
| `import.meta.env` | `--define:import.meta.env.MODE="production"` |
| CSS Modules | Lightning CSS 플러그인 |
| `@vitejs/plugin-react` | `--jsx=automatic` (자동 React JSX) |
| HMR (`import.meta.hot`) | `--serve --bundle` (지원) |
| HTML 엔트리 | 미지원. JS 엔트리 사용 |

## webpack에서 마이그레이션

webpack은 설정이 복잡하지만 ZTS는 대부분 CLI 옵션으로 해결됩니다.

### webpack.config.js → ZTS CLI

```javascript
// webpack.config.js
module.exports = {
  entry: './src/index.ts',
  output: { path: 'dist', filename: 'bundle.js' },
  resolve: { extensions: ['.ts', '.tsx', '.js'] },
  module: {
    rules: [
      { test: /\.tsx?$/, use: 'ts-loader' },
      { test: /\.css$/, use: ['style-loader', 'css-loader'] },
      { test: /\.svg$/, type: 'asset/resource' },
    ],
  },
  optimization: { minimize: true },
};

// ZTS 대응
// zts --bundle src/index.ts -o dist/bundle.js --minify --loader:.svg=file --loader:.css=text
```

### webpack 로더 → ZTS 로더/플러그인

| webpack 로더 | ZTS 대응 |
|-------------|---------|
| `ts-loader` / `babel-loader` | 불필요 (ZTS가 TS/JSX 직접 처리) |
| `css-loader` + `style-loader` | `--loader:.css=text` 또는 Lightning CSS 플러그인 |
| `file-loader` / `asset/resource` | `--loader:.png=file` |
| `url-loader` / `asset/inline` | `--loader:.png=dataurl` |
| `raw-loader` / `asset/source` | `--loader:.txt=text` |
| `svg-loader` | `--loader:.svg=text` 또는 플러그인 |
