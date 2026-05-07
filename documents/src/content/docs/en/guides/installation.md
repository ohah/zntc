---
title: Installation
description: Learn how to install ZNTC.
---

## Build from Source

ZNTC currently needs to be built from source.

### Prerequisites

- **Zig 0.15.2** (recommended to install via [mise](https://mise.jdx.dev/))
- **Git**

### Build

```bash
git clone https://github.com/ohah/zntc.git
cd zntc
zig build -Doptimize=ReleaseFast
```

The built binary is located at `zig-out/bin/zntc`.

### Add to PATH

```bash
# ~/.zshrc or ~/.bashrc
export PATH="$PATH:/path/to/zntc/zig-out/bin"
```

## WASM (Browser/Node.js)

```bash
bun add @zntc/wasm
```

```typescript
import { init, transpile } from "@zntc/wasm";

await init();
const result = transpile("const x: number = 1;");
console.log(result.code); // "const x = 1;"
```

## NAPI (Node.js/Bun — Recommended)

```bash
bun add @zntc/core
```

```typescript
import { init, transpile, build, buildSync, vitePlugin } from "@zntc/core";

init();

// Transpile
const { code } = transpile("const x: number = 1;");

// Sync bundling
const result = buildSync({ entryPoints: ["src/index.ts"], minify: true });

// Async bundling with JS plugins
const result2 = await build({
  entryPoints: ["src/index.ts"],
  plugins: [
    vitePlugin({
      name: "env-replace",
      transform(code) {
        return code.replace("import.meta.env.MODE", '"production"');
      },
    }),
  ],
});
```

## JS Build API (NAPI, in-process)

Use `@zntc/core`'s `build()` / `buildSync()` / `watch()` to bundle directly inside Node.js/Bun:

```typescript
import { init, build } from "@zntc/core";
init();

const result = await build({
  entryPoints: ["src/index.ts"],
  outdir: "dist",
  bundle: true,
  plugins: [/* Vite/Rollup-style hooks */],
});
```
