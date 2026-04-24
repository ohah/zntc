---
title: Migration Guide
description: How to migrate from esbuild, Vite, and webpack to ZTS.
---

## Migrating from esbuild

ZTS supports nearly identical CLI options to esbuild. In most cases, replace `esbuild` with `zts`.

### CLI option mapping

| esbuild | ZTS | Note |
|---------|-----|------|
| `esbuild src/index.ts --bundle` | `zts --bundle src/index.ts` | Same |
| `--outfile=dist/out.js` | `-o dist/out.js` | Short form supported |
| `--outdir=dist` | `--outdir dist` | Same |
| `--outbase=src` | `--outbase=src` | Same |
| `--format=esm` | `--format=esm` | Same (esm/cjs/iife/umd/amd) |
| `--platform=node` | `--platform=node` | Same (browser/node/neutral/react-native) |
| `--target=es2020` | `--target=es2020` | Same (engine targets: `chrome80`, `node20`) |
| `--bundle` | `--bundle` | Same |
| `--splitting` | `--splitting` | Same (`--outdir` required) |
| `--packages=external` | `--packages=external` | Same |
| `--external:react` | `--external react` | Space instead of `:` |
| `--minify` | `--minify` | Same (`--minify-{whitespace,syntax,identifiers}` granular) |
| `--sourcemap` | `--sourcemap` | Same |
| (config only: `sourceRoot`) | `--source-root=...` | ZTS exposes as CLI flag |
| `--sources-content=false` | `--sources-content=false` | Same |
| `--define:X=Y` | `--define:X=Y` | Same |
| `--alias:react=preact/compat` | `--alias:react=preact/compat` | Same |
| `--inject:./shim.js` | `--inject:./shim.js` | Same |
| `--pure:Pure.*` | `--pure:Pure.*` | Same (DCE hint) |
| `--drop:console` | `--drop=console` | `=` instead of `:` (`console`/`debugger`) |
| `--drop-labels=DEV` | `--drop-labels=DEV` | Same |
| `--keep-names` | `--keep-names` | Same |
| `--banner:js=...` | `--banner:js=...` | Same |
| `--footer:js=...` | `--footer:js=...` | Same |
| `--global-name=foo` | `--global-name=foo` | IIFE/UMD global name |
| `--public-path=/static/` | `--public-path=/static/` | Same |
| `--out-extension:.js=.mjs` | `--out-extension:.js=.mjs` | Same |
| `--entry-names=[name]-[hash]` | `--entry-names=[name]-[hash]` | Same |
| `--chunk-names=chunks/[hash]` | `--chunk-names=chunks/[hash]` | Same |
| `--asset-names=assets/[hash]` | `--asset-names=assets/[hash]` | Same |
| `--loader:.css=text` | `--loader:.css=text` | Same (`text`/`file`/`dataurl`/`json`/`copy`) |
| `--jsx=automatic` | `--jsx=automatic` | Same (`classic`/`automatic`/`automatic-dev`) |
| `--jsx-dev` | `--jsx-dev` | Same |
| `--jsx-factory=h` | `--jsx-factory=h` | Same |
| `--jsx-fragment=Fragment` | `--jsx-fragment=Fragment` | Same |
| `--jsx-import-source=preact` | `--jsx-import-source=preact` | Same |
| `--jsx-side-effects` | `--jsx-side-effects` | Same |
| `--tsconfig=tsconfig.json` | `-p tsconfig.json` or `--tsconfig-path=...` | `-p` short form |
| `--tsconfig-raw='{...}'` | `--tsconfig-raw='{...}'` | Same |
| `--conditions=prod,foo` | `--conditions=prod,foo` | Same |
| `--main-fields=browser,main` | `--main-fields=browser,main` | Same |
| `--resolve-extensions=.ts,.js` | `--resolve-extensions=.ts,.js` | Same (RN `.ios.ts` etc.) |
| `--preserve-symlinks` | `--preserve-symlinks` | Same |
| `--node-paths=...` | `--node-paths=...` | Same |
| `--charset=utf8` | `--charset=utf8` | Same (preserve UTF-8) |
| `--charset=ascii` | `--ascii-only` | ZTS uses dedicated flag; escapes non-ASCII to `\uXXXX` |
| `--legal-comments=eof` | `--legal-comments=eof` | Same (`none`/`inline`/`eof`/`linked`/`external`) |
| `--metafile=meta.json` | `--metafile=meta.json` | Same |
| `--analyze` | `--analyze` | Same (JSON now, tree format planned) |
| `--log-level=warning` | `--log-level=warning` | Same (`silent`/`error`/`warning`/`info`/`debug`) |
| `--log-limit=10` | `--log-limit=10` | Same |
| `--line-limit=80` | `--line-limit=80` | Same |
| `--ignore-annotations` | `--ignore-annotations` | Same |
| `--allow-overwrite` | `--allow-overwrite` | Same |
| `--watch` | `--watch` or `-w` | Same |
| `--serve` | `--serve` | Same (`--port` supported) |

### esbuild Build API migration

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

// ZTS — almost identical
import { build } from '@zts/core';
await build({
  entryPoints: ['src/index.ts'],
  bundle: true,
  outdir: 'dist',
  format: 'esm',
  minify: true,
});
```

### esbuild plugin migration

ZTS native plugins use the **esbuild-style** `setup(build)` structure directly. Return value keys (`path`/`contents`) are identical.

```typescript
// esbuild plugin
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

// ZTS plugin — same esbuild style (use path prefix instead of namespace)
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

If you want to use Rollup/Vite-style plugins (`resolveId`/`load`/`transform`) as-is, wrap them with `vitePlugin()`.

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

### Unsupported esbuild options

| esbuild option | Alternative |
|-------------|------|
| `--mangle-props=<regex>` | Not supported (mangling limited to `--minify-identifiers` on internal names) |
| `--mangle-cache=<path>` | Not supported |
| `--mangle-quoted` | Not supported |
| `--analyze` (tree format) | `--analyze` (JSON only, tree format planned) |
| `--servedir=<path>` | `--serve <dir>` (positional arg) |
| `--bundle=false` (off by default) | Same default. ZTS transpiles only without `--bundle` |
| `--splitting=false` | Off by default. No flag means default |
| `--tree-shaking=false` | Not supported. Workaround: `--packages=external` or per-package `--external` |
| `--color=true|false` | Not supported. Auto-detected from terminal |
| `--log-override:X=Y` | Not supported. Only `--log-level` |
| `--supported:bigint=false` | Not supported. Use `--target` for global control |
| `--reserve-props=<regex>` | Not supported |

## Migrating from Vite

Vite is a combination of dev server + production bundler (Rollup/Rolldown). ZTS is a standalone bundler and doesn't replace all Vite features.

### Vite production build replacement

```bash
# Vite
vite build

# ZTS
zts --bundle src/main.ts --outdir dist --format=esm --splitting --minify --sourcemap
```

### vite.config.ts mapping

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

// ZTS CLI equivalent
// zts --bundle src/main.ts --outdir dist --minify --sourcemap --external react --external react-dom
```

### Vite plugin → ZTS plugin

Vite/Rollup plugin hooks (`resolveId`/`load`/`transform`) work when wrapped with `vitePlugin()`. Return value keys follow the Rollup convention (`{ id, code }`).

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

To write native-style plugins, use `setup(build) { build.onLoad(...) }`.

### Vite feature mapping

| Vite feature | ZTS equivalent |
|----------|---------|
| `vite` (dev server) | `zts --serve --bundle <entry>` (HMR supported) |
| `vite build` | `zts --bundle <entry> --outdir dist --splitting --minify --sourcemap` |
| `vite preview` | Not supported. Use `zts --serve dist` for static serving |
| `import.meta.env.MODE` | `--define:import.meta.env.MODE=\"production\"` |
| `import.meta.env.DEV` | `--define:import.meta.env.DEV=true` (manual) |
| `.env` / `.env.production` auto-load | Not supported. Use `dotenv` + `--define` to inject manually |
| `import.meta.glob` | Not supported (planned) |
| `import.meta.hot` | Supported (`--serve --bundle`) |
| `import.meta.url` | Supported (ESM standard) |
| `@vitejs/plugin-react` | `--jsx=automatic` (automatic runtime built-in) |
| `@vitejs/plugin-react` Fast Refresh | Built-in HMR (React Refresh) |
| `@vitejs/plugin-vue` | Not supported |
| `@vitejs/plugin-legacy` | Partial via `--target=es5` etc. |
| CSS Modules (`.module.css`) | Built-in Lightning CSS post-processing (auto-detected) |
| CSS `@import` | Built-in Lightning CSS or `--loader:.css=text` |
| PostCSS (`postcss.config.js`) | Not supported. Replaced by Lightning CSS post-processing |
| Sass/Less/Stylus | Not supported. Pre-compile before build |
| `public/` static directory | Not supported. Copy manually or use `--loader:.svg=file` |
| HTML entry (`index.html`) | Not supported. Only JS/TS entries |
| `resolve.alias` | `--alias:name=target` |
| `resolve.conditions` | `--conditions=...` |
| `optimizeDeps` (pre-bundling) | Not needed (handled during bundling) |
| `ssr` / SSR build | Not supported |
| `worker.format` | Not supported (general Worker bundle support separate) |
| Rollup plugin compat | `resolveId`/`load`/`transform` hooks compatible |

## Migrating from webpack

webpack configuration is complex, but ZTS handles most of it via CLI options.

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

// ZTS equivalent
// zts --bundle src/index.ts -o dist/bundle.js --minify --loader:.svg=file --loader:.css=text
```

### webpack loaders → ZTS loaders/plugins

| webpack loader | ZTS equivalent |
|-------------|---------|
| `ts-loader` / `babel-loader` | Not needed. ZTS handles TS/JSX directly |
| `@swc/swc-loader` / `esbuild-loader` | Not needed. Replaced by ZTS |
| `css-loader` + `style-loader` | `--loader:.css=text` or built-in Lightning CSS post-processing |
| `file-loader` / `asset/resource` | `--loader:.png=file` |
| `url-loader` / `asset/inline` | `--loader:.png=dataurl` |
| `raw-loader` / `asset/source` | `--loader:.txt=text` |
| `svg-loader` / `@svgr/webpack` | `--loader:.svg=text`/`file`/`dataurl` or plugin |
| `json-loader` | `--loader:.json=json` (built-in default) |
| `sass-loader` / `less-loader` / `stylus-loader` | Not supported. Pre-compile needed |
| `postcss-loader` | Not supported. Replaced by Lightning CSS post-processing |
| `html-loader` | Not supported. `--loader:.html=text` for string conversion |
| `worker-loader` | Not supported (general Worker bundle support separate) |
| `thread-loader` | Not needed. ZTS has built-in parallel pipeline (`--jobs=N`) |
| `cache-loader` | Not needed. Uses `.zig-cache` / module-level cache |

### webpack plugins → ZTS equivalents

| webpack plugin | ZTS equivalent |
|----------------|---------|
| `DefinePlugin` | `--define:KEY=VALUE` |
| `ProvidePlugin` | `--inject:./shim.js` |
| `IgnorePlugin` | `--external <pkg>` or `--block-list=<pattern>` |
| `BannerPlugin` | `--banner:js=...` |
| `SplitChunksPlugin` | `--splitting` (automatic) |
| `MiniCssExtractPlugin` | Built-in Lightning CSS post-processing (separate CSS chunks) |
| `HtmlWebpackPlugin` | Not supported. Manage static `index.html` manually |
| `CopyWebpackPlugin` | Not supported. Per-asset copy via `--loader:.svg=copy` |
| `TerserPlugin` | `--minify` built-in |
| `CssMinimizerPlugin` | Handled by Lightning CSS post-processing |
| `CompressionPlugin` (gzip/brotli) | Not supported. Handle in post-build |
| `webpack.ContextReplacementPlugin` | Not supported |
| Module Federation | Not supported |
| DllPlugin / DllReferencePlugin | Not supported |

### Unsupported webpack features

| webpack feature | Alternative |
|-------------|------|
| `require.context` | Supported (`require.context(dir, deep, regex)` — resolved via plugin `onResolveContext` hook) |
| Lazy chunk (`import(/* webpackChunkName: "x" */ ...)`) | Dynamic import itself supported. Magic comments are not |
| `webpack.config.js` function / multi-config | Not supported. Single-export `zts.config.ts` |
| `devServer.proxy` | Not supported. `--serve` serves static/bundle only |
| Dev server overlay | Not supported (HMR errors go to console) |
| Persistent cache (`cache.type: 'filesystem'`) | Not needed. Built-in cache |
| Stats JSON | `--metafile=meta.json` provides similar info |
