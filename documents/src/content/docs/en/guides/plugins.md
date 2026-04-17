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
| `bundle` | `boolean` | Bundle mode |
| `format` | `"esm" \| "cjs" \| "iife" \| "umd" \| "amd"` | Module format |
| `platform` | `"browser" \| "node" \| "neutral" \| "react-native"` | Target platform |
| `target` | `string \| string[]` | ES version (`"es2020"`) or engines (`["chrome80","safari14"]`) |
| `minify` | `boolean` | Minification (all three) |
| `minifyWhitespace` / `minifySyntax` / `minifyIdentifiers` | `boolean` | Granular toggles |
| `sourcemap` | `boolean` | Source maps |
| `splitting` | `boolean` | Code splitting |
| `write` | `boolean` | `false` to return in-memory |
