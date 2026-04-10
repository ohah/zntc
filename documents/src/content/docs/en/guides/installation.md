---
title: Installation
description: Learn how to install ZTS.
---

## Build from Source

ZTS currently needs to be built from source.

### Prerequisites

- **Zig 0.15.2** (recommended to install via [mise](https://mise.jdx.dev/))
- **Git**

### Build

```bash
git clone https://github.com/ohah/zts.git
cd zts
zig build -Doptimize=ReleaseFast
```

The built binary is located at `zig-out/bin/zts`.

### Add to PATH

```bash
# ~/.zshrc or ~/.bashrc
export PATH="$PATH:/path/to/zts/zig-out/bin"
```

## WASM (Browser/Node.js)

```bash
bun add @zts/wasm
```

```typescript
import { init, transpile } from "@zts/wasm";

await init();
const result = transpile("const x: number = 1;");
console.log(result.code); // "const x = 1;"
```

## NAPI (Node.js/Bun — Recommended)

```bash
bun add @zts/core
```

```typescript
import { init, transpile, build, buildSync, vitePlugin } from "@zts/core";

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

## JS Plugin API (subprocess)

```bash
bun add @zts/plugin
```

```typescript
import { build } from "@zts/plugin";

const result = await build({
  entryPoints: ["src/index.ts"],
  outdir: "dist",
  bundle: true,
});
```
