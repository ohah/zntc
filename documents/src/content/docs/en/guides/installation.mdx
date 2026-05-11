---
title: Installation
description: Install ZNTC via npm / bun / pnpm / yarn / deno.
---

import { Tabs, TabItem } from "@astrojs/starlight/components";

ZNTC ships as a set of npm packages. Pick the ones you need based on the scenario.

## Packages at a glance

| Package | Purpose | Includes |
|---|---|---|
| `@zntc/core` | CLI + Node/Bun in-process API (NAPI) | `zntc` binary, `transpile()` / `build()` / `buildSync()` / `watch()` / `vitePlugin()` |
| `@zntc/wasm` | Browser · Edge · WASI runtimes | WASM-built transpiler |
| `@zntc/vite-plugin` | Vite integration | Drop-in replacement for esbuild |
| `@zntc/react-native` | React Native bundler / RN 0.72+ | Metro-compatible surface |
| `@zntc/init` | Overlay ZNTC onto an existing RN CLI project | `zntc-init` scaffolder |

## CLI + JS API (`@zntc/core`)

The most common scenario. Provides both the `zntc` command and `import { ... } from '@zntc/core'`.

<Tabs syncKey="pkg">
  <TabItem label="bun">

```bash
bun add -d @zntc/core
```

  </TabItem>
  <TabItem label="npm">

```bash
npm i -D @zntc/core
```

  </TabItem>
  <TabItem label="pnpm">

```bash
pnpm add -D @zntc/core
```

  </TabItem>
  <TabItem label="yarn">

```bash
yarn add -D @zntc/core
```

  </TabItem>
  <TabItem label="deno">

```bash
deno add -D npm:@zntc/core
```

  </TabItem>
</Tabs>

The CLI is available immediately after install:

<Tabs syncKey="pkg">
  <TabItem label="bun">

```bash
bunx zntc --bundle src/index.ts -o dist/bundle.js
```

  </TabItem>
  <TabItem label="npm">

```bash
npx zntc --bundle src/index.ts -o dist/bundle.js
```

  </TabItem>
  <TabItem label="pnpm">

```bash
pnpm dlx zntc --bundle src/index.ts -o dist/bundle.js
```

  </TabItem>
  <TabItem label="yarn">

```bash
yarn dlx zntc --bundle src/index.ts -o dist/bundle.js
```

  </TabItem>
  <TabItem label="deno">

```bash
deno run -A npm:@zntc/core --bundle src/index.ts -o dist/bundle.js
```

  </TabItem>
</Tabs>

JS API:

```typescript
import { init, transpile, build, buildSync, vitePlugin } from "@zntc/core";

init();

// Transpile
const { code } = transpile("const x: number = 1;");

// Sync bundling
const result = buildSync({
  entryPoints: ["src/index.ts"],
  format: "esm",
  minify: true,
});

// Async bundling with JS plugins
const result2 = await build({
  entryPoints: ["src/index.ts"],
  define: { "process.env.NODE_ENV": '"production"' },
  plugins: [{
    name: "css-plugin",
    setup(build) {
      build.onLoad({ filter: /\.css$/ }, () => ({
        contents: 'export default "red";',
      }));
    },
  }],
});

// Vite/Rollup plugin adapter
const result3 = await build({
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

`@zntc/core` automatically pulls in the matching native binary (`@zntc/core-darwin-arm64`, `@zntc/core-linux-x64-gnu`, ...) as an optional dependency.

## WASM — Browser / Edge / WASI

For environments without Node.js (browser playgrounds, Cloudflare Workers, Deno):

<Tabs syncKey="pkg">
  <TabItem label="bun">

```bash
bun add @zntc/wasm
```

  </TabItem>
  <TabItem label="npm">

```bash
npm i @zntc/wasm
```

  </TabItem>
  <TabItem label="pnpm">

```bash
pnpm add @zntc/wasm
```

  </TabItem>
  <TabItem label="yarn">

```bash
yarn add @zntc/wasm
```

  </TabItem>
  <TabItem label="deno">

```bash
deno add npm:@zntc/wasm
```

  </TabItem>
</Tabs>

```typescript
import { init, transpile } from "@zntc/wasm";

await init();
const result = transpile("const x: number = 1;");
console.log(result.code); // "const x = 1;"
```

## Vite plugin

Drop-in replacement for esbuild:

<Tabs syncKey="pkg">
  <TabItem label="bun">

```bash
bun add -d @zntc/vite-plugin
```

  </TabItem>
  <TabItem label="npm">

```bash
npm i -D @zntc/vite-plugin
```

  </TabItem>
  <TabItem label="pnpm">

```bash
pnpm add -D @zntc/vite-plugin
```

  </TabItem>
  <TabItem label="yarn">

```bash
yarn add -D @zntc/vite-plugin
```

  </TabItem>
  <TabItem label="deno">

```bash
deno add -D npm:@zntc/vite-plugin
```

  </TabItem>
</Tabs>

```ts
// vite.config.ts
import { defineConfig } from "vite";
import zntc from "@zntc/vite-plugin";

export default defineConfig({
  plugins: [zntc()],
});
```

## React Native

Overlay ZNTC onto an existing React Native CLI project — one-shot:

<Tabs syncKey="pkg">
  <TabItem label="bun">

```bash
bunx @zntc/init
```

  </TabItem>
  <TabItem label="npm">

```bash
npx @zntc/init
```

  </TabItem>
  <TabItem label="pnpm">

```bash
pnpm dlx @zntc/init
```

  </TabItem>
  <TabItem label="yarn">

```bash
yarn dlx @zntc/init
```

  </TabItem>
  <TabItem label="deno">

```bash
deno run -A npm:@zntc/init
```

  </TabItem>
</Tabs>

See the [React Native guide](/zntc/en/guides/react-native/) for the full option list.

Direct install:

<Tabs syncKey="pkg">
  <TabItem label="bun">

```bash
bun add -d @zntc/core @zntc/react-native
```

  </TabItem>
  <TabItem label="npm">

```bash
npm i -D @zntc/core @zntc/react-native
```

  </TabItem>
  <TabItem label="pnpm">

```bash
pnpm add -D @zntc/core @zntc/react-native
```

  </TabItem>
  <TabItem label="yarn">

```bash
yarn add -D @zntc/core @zntc/react-native
```

  </TabItem>
  <TabItem label="deno">

```bash
deno add -D npm:@zntc/core npm:@zntc/react-native
```

  </TabItem>
</Tabs>

## Global install (CLI only)

To use the `zntc` command system-wide, independent of any specific project:

<Tabs syncKey="pkg">
  <TabItem label="bun">

```bash
bun add -g @zntc/core
```

  </TabItem>
  <TabItem label="npm">

```bash
npm i -g @zntc/core
```

  </TabItem>
  <TabItem label="pnpm">

```bash
pnpm add -g @zntc/core
```

  </TabItem>
  <TabItem label="yarn">

```bash
yarn global add @zntc/core
```

  </TabItem>
  <TabItem label="deno">

```bash
deno install -A -g npm:@zntc/core
```

  </TabItem>
</Tabs>

## Build from source (contributors / latest main)

If you want to run the latest `main` (or your own modifications) instead of the published npm version:

### Prerequisites

- **Zig 0.15.2** (install via [mise](https://mise.jdx.dev/) recommended)
- **Bun 1.3+** or **Node.js 24+**
- **Git**

### Build

```bash
git clone https://github.com/ohah/zntc.git
cd zntc
zig build -Doptimize=ReleaseFast
```

Built binary: `zig-out/bin/zntc`. Add it to PATH and it works the same as the npm-installed CLI:

```bash
# ~/.zshrc or ~/.bashrc
export PATH="$PATH:/path/to/zntc/zig-out/bin"
```

To rebuild the NAPI / WASM artifacts directly:

```bash
zig build napi               # native binary for @zntc/core
zig build wasm wasm-bundler  # .wasm for @zntc/wasm
```
