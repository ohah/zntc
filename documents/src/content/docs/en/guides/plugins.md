---
title: Plugins
description: Learn how to use the ZTS plugin system.
---

## Overview

ZTS provides a Rollup/Vite-compatible plugin interface. Plugins are written in JS/TS and run in-process via C NAPI (via `@zts/core`).

## Config File

Create a `zts.config.ts` (or `.js`, `.mjs`, `.mts`, `.cjs`, `.cts`) at the project root.

```typescript
// zts.config.ts
import { defineConfig } from "@zts/core";

export default defineConfig({
  plugins: [
    {
      name: "my-plugin",
      load(id) {
        if (id.endsWith(".txt")) {
          const fs = require("fs");
          return { contents: `export default ${JSON.stringify(fs.readFileSync(id, "utf8"))}` };
        }
        return null;
      },
    },
  ],
});
```

## Plugin Hooks

### resolveId

Custom module path resolution (first-match).

```typescript
{
  name: 'virtual-module',
  resolveId(source) {
    if (source === 'virtual:config') {
      return { path: '\0virtual:config' };
    }
    return null;
  }
}
```

### load

Custom module content loading (first-match).

```typescript
{
  name: 'virtual-module',
  load(id) {
    if (id === '\0virtual:config') {
      return { contents: 'export const version = "1.0.0";' };
    }
    return null;
  }
}
```

#### `loader` option — asset loader override (#2157)

When the object returned from `load` includes `loader`, the graph overrides the module loader to that value (skipping extension inference). Same semantics as esbuild's `onLoad` callback `loader: 'text' | 'binary' | ...`.

```typescript
{
  name: 'md-as-text',
  load(id) {
    if (id.endsWith('.md')) {
      return {
        contents: readFileSync(id, 'utf-8'),
        loader: 'text',     // emit file contents as a string default export
      };
    }
    return null;
  }
}
```

Supported loaders: `text` / `dataurl` / `base64` / `binary` / `empty` / `javascript` / `json` / `css`.

#### `contents` binary support (#2157 follow-up)

`contents` accepts `string` or `Uint8Array` / Node.js `Buffer` — PNG/JPG and other utf-8-invalid byte sequences are forwarded losslessly.

```typescript
{
  name: 'png-as-dataurl',
  load(id) {
    if (id.endsWith('.png')) {
      return {
        contents: readFileSync(id),  // Buffer / Uint8Array — binary safe
        loader: 'dataurl',
      };
    }
    return null;
  }
}
```

### transform

Transform module code (chaining -- all plugins applied in order).

```typescript
{
  name: 'env-replace',
  transform(code, id) {
    if (id.endsWith('.ts') || id.endsWith('.js')) {
      return code.replace(/__APP_VERSION__/g, '"1.0.0"');
    }
    return null;
  }
}
```

### renderChunk

Post-process chunk code before output (chaining).

```typescript
{
  name: 'banner',
  renderChunk(code, chunkName) {
    return `/* chunk: ${chunkName} */\n${code}`;
  }
}
```

### generateBundle

Called after bundle generation is complete.

```typescript
{
  name: 'notify',
  generateBundle(outputs) {
    console.log(`Built ${outputs.length} files`);
  }
}
```

### buildStart / buildEnd / closeBundle (#2156)

Bundle lifecycle hooks. Compatible with esbuild's `onStart` / `onEnd` / `onDispose` and Rollup/Vite/rolldown's `buildStart` / `buildEnd` / `closeBundle`.

| Hook | When | Argument |
|---|---|---|
| `buildStart` | Once at bundle start (initial build and every rebuild in watch mode) | none |
| `buildEnd` | Right after output contents are determined | `error?: Error` (message of the first fatal diagnostic on failure) |
| `closeBundle` | After output files are written | none |

```typescript
{
  name: 'lifecycle',
  buildStart() { console.log('build started'); },
  buildEnd(err) {
    if (err) console.error('build failed:', err.message);
    else console.log('output ready');
  },
  closeBundle() { console.log('write done'); },
}
```

`build()` call order: `buildStart → onLoad / onTransform → buildEnd → write → closeBundle`.
`watch()` call order: `buildStart → onLoad / onTransform → buildEnd → onReady/onRebuild → closeBundle`.
With multiple plugins each hook fires in sequence. Errors thrown from `buildEnd` / `closeBundle` are swallowed so they don't mask the actual build/rebuild result.

## Build API

```typescript
import { build } from "@zts/core";

const result = await build({
  entryPoints: ["src/index.ts"],
  outdir: "dist",
  bundle: true,
  minify: true,
  sourcemap: true,
});

if (result.errors.length > 0) {
  console.error(result.errors);
}
```

### BuildOptions

| Option | Type | Description |
|--------|------|-------------|
| `entryPoints` | `string[]` | Entry files |
| `outdir` | `string` | Output directory |
| `outfile` | `string` | Output file (single) |
| `allowOverwrite` | `boolean` | Explicitly permit output paths to overwrite input files |
| `bundle` | `boolean` | Bundle mode |
| `format` | `"esm" \| "cjs" \| "iife" \| "umd" \| "amd"` | Module format |
| `platform` | `"browser" \| "node" \| "neutral" \| "react-native"` | Target platform |
| `target` | `string \| string[]` | ES version (`"es2020"`) or engines (`["chrome80","safari14"]`) |
| `minify` | `boolean` | Minification (all three) |
| `minifyWhitespace` / `minifySyntax` / `minifyIdentifiers` | `boolean` | Granular toggles |
| `sourcemap` | `boolean` | Source maps |
| `splitting` | `boolean` | Code splitting |
| `write` | `boolean` | `false` to return in-memory |
