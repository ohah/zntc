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
| `--outbase=src` | `--outbase=src` | 동일 |
| `--format=esm` | `--format=esm` | 동일 (esm/cjs/iife/umd/amd) |
| `--platform=node` | `--platform=node` | 동일 (browser/node/neutral/react-native) |
| `--target=es2020` | `--target=es2020` | 동일 (engine 타겟: `chrome80`, `node20` 등) |
| `--bundle` | `--bundle` | 동일 |
| `--splitting` | `--splitting` | 동일 (`--outdir` 필수) |
| `--packages=external` | `--packages=external` | 동일 |
| `--external:react` | `--external react` | `:` 대신 공백 |
| `--minify` | `--minify` | 동일 (`--minify-{whitespace,syntax,identifiers}` 세분화 지원) |
| `--sourcemap` | `--sourcemap` | 동일 |
| (config only: `sourceRoot`) | `--source-root=...` | ZTS 는 CLI 플래그로도 노출 |
| `--sources-content=false` | `--sources-content=false` | 동일 |
| `--define:X=Y` | `--define:X=Y` | 동일 |
| `--alias:react=preact/compat` | `--alias:react=preact/compat` | 동일 |
| `--inject:./shim.js` | `--inject:./shim.js` | 동일 |
| `--pure:Pure.*` | `--pure:Pure.*` | 동일 (DCE 힌트) |
| `--drop:console` | `--drop=console` | `:` 대신 `=` (`console`/`debugger`) |
| `--drop-labels=DEV` | `--drop-labels=DEV` | 동일 |
| `--keep-names` | `--keep-names` | 동일 |
| `--banner:js=...` | `--banner:js=...` | 동일 |
| `--footer:js=...` | `--footer:js=...` | 동일 |
| `--global-name=foo` | `--global-name=foo` | IIFE/UMD 전역 이름 |
| `--public-path=/static/` | `--public-path=/static/` | 동일 |
| `--out-extension:.js=.mjs` | `--out-extension:.js=.mjs` | 동일 |
| `--entry-names=[name]-[hash]` | `--entry-names=[name]-[hash]` | 동일 |
| `--chunk-names=chunks/[hash]` | `--chunk-names=chunks/[hash]` | 동일 |
| `--asset-names=assets/[hash]` | `--asset-names=assets/[hash]` | 동일 |
| `--loader:.css=text` | `--loader:.css=text` | 동일 (`text`/`file`/`dataurl`/`json`/`copy` 등) |
| `--jsx=automatic` | `--jsx=automatic` | 동일 (`classic`/`automatic`/`automatic-dev`) |
| `--jsx-dev` | `--jsx-dev` | 동일 |
| `--jsx-factory=h` | `--jsx-factory=h` | 동일 |
| `--jsx-fragment=Fragment` | `--jsx-fragment=Fragment` | 동일 |
| `--jsx-import-source=preact` | `--jsx-import-source=preact` | 동일 |
| `--jsx-side-effects` | `--jsx-side-effects` | 동일 |
| `--tsconfig=tsconfig.json` | `-p tsconfig.json` 또는 `--tsconfig-path=...` | 축약 `-p` 지원 |
| `--tsconfig-raw='{...}'` | `--tsconfig-raw='{...}'` | 동일 |
| `--conditions=prod,foo` | `--conditions=prod,foo` | 동일 |
| `--main-fields=browser,main` | `--main-fields=browser,main` | 동일 |
| `--resolve-extensions=.ts,.js` | `--resolve-extensions=.ts,.js` | 동일 (RN `.ios.ts` 등 지원) |
| `--preserve-symlinks` | `--preserve-symlinks` | 동일 |
| `--node-paths=...` | `--node-paths=...` | 동일 |
| `--charset=utf8` | `--charset=utf8` | 동일 (UTF-8 보존) |
| `--charset=ascii` | `--ascii-only` | ZTS 는 전용 플래그. 비-ASCII를 `\uXXXX` 이스케이프 |
| `--legal-comments=eof` | `--legal-comments=eof` | 동일 (`none`/`inline`/`eof`/`linked`/`external`) |
| `--metafile=meta.json` | `--metafile=meta.json` | 동일 |
| `--analyze` | `--analyze` | 동일 (현재 JSON, 트리 포맷 예정) |
| `--log-level=warning` | `--log-level=warning` | 동일 (`silent`/`error`/`warning`/`info`/`debug`) |
| `--log-limit=10` | `--log-limit=10` | 동일 |
| `--line-limit=80` | `--line-limit=80` | 동일 |
| `--ignore-annotations` | `--ignore-annotations` | 동일 |
| `--allow-overwrite` | `--allow-overwrite` | 동일 |
| `--watch` | `--watch` 또는 `-w` | 동일 |
| `--serve` | `--serve` | 동일 (`--port` 지원) |

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
import { build } from '@zts/core';
await build({
  entryPoints: ['src/index.ts'],
  bundle: true,
  outdir: 'dist',
  format: 'esm',
  minify: true,
});
```

### esbuild 플러그인 마이그레이션

ZTS 네이티브 플러그인은 **esbuild 스타일** `setup(build)` 구조를 그대로 사용합니다. 반환값 키 이름(`path`/`contents`)도 동일합니다.

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

// ZTS 플러그인 — esbuild 스타일 동일 (namespace 대신 path prefix로 구분)
import type { ZtsPlugin } from '@zts/core';

const myPlugin: ZtsPlugin = {
  name: 'my-plugin',
  setup(build) {
    build.onResolve({ filter: /^virtual:/ }, args => ({
      path: '\0' + args.path,
    }));
    build.onLoad({ filter: /^\0virtual:/ }, args => ({
      contents: 'export default 42',
    }));
  },
};
```

Rollup/Vite 스타일 플러그인(`resolveId`/`load`/`transform`)을 그대로 쓰고 싶다면 `vitePlugin()` 래퍼로 감쌉니다.

```typescript
import { vitePlugin } from '@zts/core';

export default defineConfig({
  plugins: [
    vitePlugin({
      name: 'virtual-loader',
      resolveId(source) {
        if (source.startsWith('virtual:')) return '\0' + source;
        return null;
      },
      load(id) {
        if (id.startsWith('\0virtual:')) return { code: 'export default 42' };
        return null;
      },
    }),
  ],
});
```

### 지원하지 않는 esbuild 옵션

| esbuild 옵션 | 대안 |
|-------------|------|
| `--mangle-props=<regex>` | 미지원 (mangle 자체는 `--minify-identifiers`로 내부 식별자만) |
| `--mangle-cache=<path>` | 미지원 |
| `--mangle-quoted` | 미지원 |
| `--analyze` (tree 포맷) | `--analyze` (현재 JSON만, tree 포맷 예정) |
| `--servedir=<path>` | `--serve <dir>` (위치 인자) |
| `--bundle=false` (기본 off) | 기본 동작 동일. ZTS도 `--bundle` 없으면 트랜스파일만 |
| `--splitting=false` | 기본 off. 플래그 없는 상태가 기본 |
| `--tree-shaking=false` | 미지원. `--packages=external` 또는 개별 `--external`로 우회 |
| `--color=true|false` | 미지원. 터미널 자동 감지 |
| `--log-override:X=Y` | 미지원. `--log-level`만 |
| `--supported:bigint=false` | 미지원. `--target`으로 일괄 제어 |
| `--reserve-props=<regex>` | 미지원 |

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

Vite/Rollup 플러그인의 `resolveId`/`load`/`transform` 훅은 `vitePlugin()` 래퍼로 감싸면 그대로 동작합니다. 반환값 키는 Rollup 규약대로 `{ id, code }` 사용.

```typescript
// zts.config.ts
import { defineConfig, vitePlugin } from '@zts/core';
import fs from 'node:fs';

export default defineConfig({
  plugins: [
    vitePlugin({
      name: 'svg-loader',
      load(id) {
        if (id.endsWith('.svg')) {
          const svg = fs.readFileSync(id, 'utf8');
          return { code: `export default ${JSON.stringify(svg)}` };
        }
        return null;
      },
    }),
  ],
});
```

네이티브 스타일로 직접 쓰고 싶다면 `setup(build) { build.onLoad(...) }` 구조를 사용하세요.

### Vite 기능 대응표

| Vite 기능 | ZTS 대응 |
|----------|---------|
| `vite` (dev server) | `zts --serve --bundle <entry>` (HMR 지원) |
| `vite build` | `zts --bundle <entry> --outdir dist --splitting --minify --sourcemap` |
| `vite preview` | 미지원. `zts --serve dist` 로 정적 서빙 |
| `import.meta.env.MODE` | `--define:import.meta.env.MODE=\"production\"` |
| `import.meta.env.DEV` | `--define:import.meta.env.DEV=true` (수동) |
| `.env` / `.env.production` 자동 로드 | 미지원. `dotenv` + `--define`으로 수동 주입 |
| `import.meta.glob` | 미지원 (구현 예정) |
| `import.meta.hot` | 지원 (`--serve --bundle`) |
| `import.meta.url` | 지원 (ESM 표준) |
| `@vitejs/plugin-react` | `--jsx=automatic` (자동 런타임 내장) |
| `@vitejs/plugin-react` Fast Refresh | HMR 내장 (React Refresh) |
| `@vitejs/plugin-vue` | 미지원 |
| `@vitejs/plugin-legacy` | `--target=es5` 등으로 일부 대응 |
| CSS Modules (`.module.css`) | Lightning CSS 내장 후처리 (자동 감지) |
| CSS `@import` | Lightning CSS 내장 후처리 또는 `--loader:.css=text` |
| PostCSS (`postcss.config.js`) | 미지원. Lightning CSS 후처리로 대체 |
| Sass/Less/Stylus | 미지원. 빌드 전 사전 컴파일 필요 |
| `public/` 정적 디렉토리 | 미지원. 직접 복사 또는 `--loader:.svg=file` 등 |
| HTML 엔트리 (`index.html`) | 미지원. JS/TS 엔트리만 |
| `resolve.alias` | `--alias:name=target` |
| `resolve.conditions` | `--conditions=...` |
| `optimizeDeps` (pre-bundling) | 불필요 (번들 시 직접 처리) |
| `ssr` / SSR 빌드 | 미지원 |
| `worker.format` | 미지원 (Worker 번들 일반 지원은 별도) |
| Rollup 플러그인 호환 | `resolveId`/`load`/`transform` 훅 호환 |

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
| `ts-loader` / `babel-loader` | 불필요. ZTS가 TS/JSX 직접 처리 |
| `@swc/swc-loader` / `esbuild-loader` | 불필요. ZTS가 대체 |
| `css-loader` + `style-loader` | `--loader:.css=text` 또는 내장 Lightning CSS 후처리 |
| `file-loader` / `asset/resource` | `--loader:.png=file` |
| `url-loader` / `asset/inline` | `--loader:.png=dataurl` |
| `raw-loader` / `asset/source` | `--loader:.txt=text` |
| `svg-loader` / `@svgr/webpack` | `--loader:.svg=text`/`file`/`dataurl` 또는 플러그인 |
| `json-loader` | `--loader:.json=json` (기본 내장) |
| `sass-loader` / `less-loader` / `stylus-loader` | 미지원. 사전 컴파일 필요 |
| `postcss-loader` | 미지원. Lightning CSS 플러그인으로 대체 |
| `html-loader` | 미지원. `--loader:.html=text` 로 문자열화는 가능 |
| `worker-loader` | 미지원 (Bundle 내 Worker 일반 지원은 별도) |
| `thread-loader` | 불필요. ZTS 병렬 파이프라인 내장 (`--jobs=N`) |
| `cache-loader` | 불필요. `.zig-cache` / 모듈 레벨 캐시 |

### webpack 플러그인 → ZTS 대응

| webpack 플러그인 | ZTS 대응 |
|----------------|---------|
| `DefinePlugin` | `--define:KEY=VALUE` |
| `ProvidePlugin` | `--inject:./shim.js` |
| `IgnorePlugin` | `--external <pkg>` 또는 `--block-list=<pattern>` |
| `BannerPlugin` | `--banner:js=...` |
| `SplitChunksPlugin` | `--splitting` (자동) |
| `MiniCssExtractPlugin` | 내장 Lightning CSS 후처리 (별도 CSS 청크 출력) |
| `HtmlWebpackPlugin` | 미지원. 정적 `index.html` 직접 관리 |
| `CopyWebpackPlugin` | 미지원. `--loader:.svg=copy` 등으로 에셋 단위 복사 |
| `TerserPlugin` | `--minify` 내장 |
| `CssMinimizerPlugin` | Lightning CSS 플러그인에서 처리 |
| `CompressionPlugin` (gzip/brotli) | 미지원. 후처리로 처리 |
| `webpack.ContextReplacementPlugin` | 미지원 |
| Module Federation | 미지원 |
| DllPlugin / DllReferencePlugin | 미지원 |

### 미지원 webpack 기능

| webpack 기능 | 대안 |
|-------------|------|
| `require.context` | 지원 (`require.context(dir, deep, regex)` — 플러그인의 `onResolveContext` 훅으로 매칭) |
| Lazy chunk (`import(/* webpackChunkName: "x" */ ...)`) | 동적 import 자체는 지원. 매직 코멘트는 미지원 |
| `webpack.config.js` 함수형/멀티 컨피그 | 미지원. `zts.config.ts` 단일 export |
| `devServer.proxy` | 미지원. `--serve` 는 정적/번들만 |
| Dev server overlay | 미지원 (HMR 에러는 콘솔로 전달) |
| Persistent cache (`cache.type: 'filesystem'`) | 불필요. 내장 캐시 사용 |
| Stats JSON | `--metafile=meta.json` 으로 유사 정보 |
