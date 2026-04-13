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
| `--format=esm` | `--format=esm` | Same (esm/cjs/iife) |
| `--platform=node` | `--platform=node` | Same |
| `--minify` | `--minify` | Same |
| `--sourcemap` | `--sourcemap` | Same |
| `--splitting` | `--splitting` | Same |
| `--target=es2020` | `--target=es2020` | Same |
| `--external:react` | `--external react` | Space instead of `:` |
| `--define:X=Y` | `--define:X=Y` | Same |
| `--loader:.css=text` | `--loader:.css=text` | Same |
| `--watch` | `--watch` or `-w` | Same |
| `--serve` | `--serve` | Same |
| `--metafile=meta.json` | `--metafile=meta.json` | Same |
| `--legal-comments=eof` | `--legal-comments=eof` | Same |
| `--keep-names` | `--keep-names` | Same |
| `--drop:console` | `--drop=console` | `=` instead of `:` |
| `--inject:./shim.js` | `--inject:./shim.js` | Same |
| `--alias:react=preact/compat` | `--alias:react=preact/compat` | Same |
| `--entry-names=[name]-[hash]` | `--entry-names=[name]-[hash]` | Same |
| `--chunk-names=chunks/[hash]` | `--chunk-names=chunks/[hash]` | Same |
| `--asset-names=assets/[hash]` | `--asset-names=assets/[hash]` | Same |

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
import { build } from '@zts/plugin';
await build({
  entryPoints: ['src/index.ts'],
  bundle: true,
  outdir: 'dist',
  format: 'esm',
  minify: true,
});
```

### esbuild plugin migration

ZTS plugins use Rollup/Vite-style hooks.

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

// ZTS plugin — Rollup/Vite style
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

### Unsupported esbuild options

| esbuild option | Alternative |
|-------------|------|
| `--format=umd` | Not supported. Use IIFE + manual UMD wrapper |
| `--mangle-props` | Not supported |
| `--analyze` (detailed tree) | `--analyze` (JSON output, tree format planned) |

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

Vite/Rollup plugin hooks (`resolveId`, `load`, `transform`) work identically in ZTS.

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

### Unsupported Vite features

| Vite feature | ZTS alternative |
|----------|---------|
| `import.meta.glob` | Not supported (planned) |
| `import.meta.env` | `--define:import.meta.env.MODE="production"` |
| CSS Modules | Lightning CSS plugin |
| `@vitejs/plugin-react` | `--jsx=automatic` (automatic React JSX) |
| HMR (`import.meta.hot`) | `--serve --bundle` (supported) |
| HTML entry | Not supported. Use JS entry |

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
| `ts-loader` / `babel-loader` | Not needed (ZTS handles TS/JSX directly) |
| `css-loader` + `style-loader` | `--loader:.css=text` or Lightning CSS plugin |
| `file-loader` / `asset/resource` | `--loader:.png=file` |
| `url-loader` / `asset/inline` | `--loader:.png=dataurl` |
| `raw-loader` / `asset/source` | `--loader:.txt=text` |
| `svg-loader` | `--loader:.svg=text` or plugin |
