# ZNTC

English · **[한국어](./README_KO.md)**

> **Zig Native Transpiler & Compiler** — a transpiler and bundler for JavaScript / TypeScript / Flow, written in Zig and shipped as a native NAPI addon.

[![License](https://img.shields.io/badge/license-MIT-blue.svg)](./LICENSE)
[![Docs](https://img.shields.io/badge/docs-ohah.github.io/zntc-2b6cb0.svg)](https://ohah.github.io/zntc)
[![Test262](https://img.shields.io/badge/Test262-50,504%20/%2050,504-brightgreen.svg)](https://github.com/ohah/zntc/tree/main/docs/TESTING.md)
[![Status](https://img.shields.io/badge/status-pre--release-orange.svg)](#status)

ZNTC is a single-pass toolchain targeting the production quality of SWC / oxc / esbuild. Transpile and bundle share the same pipeline, and 1st-party transforms like styled-components / emotion / Reanimated worklets / Flow are built into the core — **no Babel required**.

- 📦 **Single dependency** — `@zntc/core` covers transpile + bundle + dev server (ships the `zntc` CLI)
- ⚡ **Native speed** — SIMD lexer, arena + mimalloc, index-based 24B fixed-size AST, producer-consumer pipeline
- 🔌 **Plugin compatible** — Rollup / Vite hooks (`resolveId` / `load` / `transform`) + esbuild-compatible CLI / options
- 📱 **React Native first-class** — Metro-compatible bundling, Flow, Reanimated worklets, Hermes target, dev server
- 🌐 **Runs anywhere** — Node 24+, Bun 1.3+, browser WASM (transpile-only and full bundler builds)

---

## Installation

```bash
# Node / Bun
bun add -D @zntc/core
# npm i -D @zntc/core
# pnpm add -D @zntc/core
```

| Scenario | Additional package |
|---|---|
| transpile / bundle (library mode) | `@zntc/core` only |
| dev / preview / build (postcss · sass · CSS Modules · HMR overlay) | `+ @zntc/web` |
| Vite users — replace just the esbuild transform with ZNTC | `@zntc/vite-plugin` |
| React Native (init / preset / dev server) | `+ @zntc/react-native` |
| Browser playground / Workers | `@zntc/wasm` |

> **Status**: pre-release. Prebuilt NAPI binaries are provided for macOS / Linux / Windows × x64 / arm64. See [docs/PUBLISH.md](./docs/PUBLISH.md) for the full build matrix.

## Quick start

### CLI

```bash
# Transpile a single file (.ts → .js, sourcemap included)
npx zntc src/index.ts --outdir dist

# Bundle (esbuild-compatible options)
npx zntc src/index.ts --bundle --outdir dist --format=esm --target=es2022

# Dev server + HMR + Fast Refresh
npx zntc serve src/main.tsx --port 5173

# React Native (Metro-compatible)
npx zntc --bundle index.js --platform=react-native --rn-platform=ios -o bundle.js
```

Run `zntc --help` for the full list of options.

### `@zntc/core` JS / NAPI API

```ts
import { transpile, build } from "@zntc/core";

// Single-file transpile — the NAPI binding is loaded lazily on first use
const { code, map } = transpile(source, {
  filename: "input.ts",
  jsx: "automatic",
  target: "es2022",
  sourcemap: true,
});

// Bundle (esbuild / Vite / Rollup-compatible plugin hooks)
const result = await build({
  entryPoints: ["src/index.ts"],
  bundle: true,
  format: "esm",
  platform: "browser",
  target: ["chrome100", "safari16"],
  define: { "process.env.NODE_ENV": '"production"' },
  plugins: [
    {
      name: "my-plugin",
      setup(build) {
        build.onResolve({ filter: /^virtual:/ }, (args) => ({ path: args.path, namespace: "virtual" }));
        build.onLoad({ filter: /.*/, namespace: "virtual" }, () => ({ contents: "export const x = 1" }));
      },
    },
  ],
});
```

### Vite integration

```ts
// vite.config.ts
import { defineConfig } from "vite";
import zntc from "@zntc/vite-plugin";

export default defineConfig({
  plugins: [zntc()],
});
```

Vite's esbuild transform step is swapped out for ZNTC, so TS / JSX / Flow and 1st-party transforms all flow through a single pass.

### Attaching to a React Native CLI project

```bash
npx @zntc/init
```

This rewrites the `start` / `bundle:*` scripts of an existing RN CLI app to use ZNTC (Metro fallback is preserved). See the [React Native guide](https://ohah.github.io/zntc/guides/react-native/) and the [`zntc.config.ts` example](./docs/CONFIG.md#react-native-config-예제) for details.

## Features

### 1st-party transforms — no Babel

Transforms that require separate Babel plugins in other bundlers are built into the ZNTC core.

```ts
// zntc.config.ts
import { defineConfig } from "@zntc/core";

export default defineConfig({
  platform: "react-native",      // auto-enables flow / worklets / RN preset
  jsxImportSource: "@emotion/react",
  compiler: {
    styledComponents: true,      // covers babel-plugin-styled-components
    emotion: { autoLabel: "dev-only" },  // covers @emotion/babel-plugin
  },
});
```

| Babel plugin | ZNTC option |
|---|---|
| `babel-plugin-styled-components` | `compiler.styledComponents` |
| `@emotion/babel-plugin` | `compiler.emotion` |
| `react-native-worklets/plugin` | `workletTransform` (automatic on RN) |
| `@babel/preset-flow` | `flow: true` (automatic on RN) |
| `@babel/preset-env` | `target: "es2020"` / `target: "hermes0.70"` |

Details: [native transforms guide](https://ohah.github.io/zntc/guides/native-transforms/).

### Plugin / options compatibility

- **Rollup / Vite-style hooks**: `resolveId`, `load`, `transform` (supports filter functions, RegExp, and string)
- **esbuild-compatible option surface**: `entryPoints`, `bundle`, `format`, `target`, `define`, `loader`, `external`, `metafile`
- **Vite alias compatible**: both `Record<string, string>` and `{ find, replacement }` array forms
- **`zntc.config.{ts,js,json}`** + tsconfig + `.env` + CLI flag with documented merge precedence ([docs/CONFIG.md](./docs/CONFIG.md))

### Performance

| Metric | Result |
|---|---|
| Test262 TC39 conformance | **50,504 / 50,504 pass (100%, 0 fail)** |
| 144-package npm smoke (build + execute) | average **0.82x bundle size** vs esbuild |
| Synthetic bench (parse + emit) | ZNTC **7ms** · Bun 10ms · esbuild 13ms · rolldown 62ms |
| RN core (`react-native` 0.74) | 410 `@flow` files pass regression |
| HMR warm rebuild | **< 100ms** (PR #1747) |

Full data: [docs/ROADMAP.md](./docs/ROADMAP.md) · [docs/TESTING.md](./docs/TESTING.md) · [benchmark site](https://ohah.github.io/zntc/reference/benchmarks/).

## Documentation

📚 **Official docs: <https://ohah.github.io/zntc>**

Key guides:

- [Introduction](https://ohah.github.io/zntc/guides/introduction/) · [Installation](https://ohah.github.io/zntc/guides/installation/) · [Quick start](https://ohah.github.io/zntc/guides/quick-start/)
- [Config file](https://ohah.github.io/zntc/guides/config-file/) · [Native transforms (without Babel)](https://ohah.github.io/zntc/guides/native-transforms/)
- [Bundling overview](https://ohah.github.io/zntc/guides/bundling/) · [Tree shaking](https://ohah.github.io/zntc/guides/tree-shaking/) · [Bundler deep dive](https://ohah.github.io/zntc/guides/bundler-deep-dive/)
- [React Native](https://ohah.github.io/zntc/guides/react-native/) · [Flow support](https://ohah.github.io/zntc/guides/flow-support/) · [Migrating from Babel](https://ohah.github.io/zntc/guides/babel-migration/)
- [Plugins](https://ohah.github.io/zntc/guides/plugins/) · [Plugin recipes](https://ohah.github.io/zntc/guides/plugin-recipes/) · [Rspack / Webpack integration](https://ohah.github.io/zntc/guides/rspack-loader/)
- [Tooling comparison](https://ohah.github.io/zntc/guides/comparison/) · [Migrating from other tools](https://ohah.github.io/zntc/guides/migration/)
- [CLI reference](https://ohah.github.io/zntc/reference/cli/) · [NAPI / JS API](https://ohah.github.io/zntc/reference/napi/) · [Transpile options](https://ohah.github.io/zntc/reference/options/)

Contributor docs (in-tree):

- [docs/ARCHITECTURE.md](./docs/ARCHITECTURE.md) · [docs/BUNDLER.md](./docs/BUNDLER.md) · [docs/HMR.md](./docs/HMR.md) · [docs/PLUGINS.md](./docs/PLUGINS.md)
- [docs/ROADMAP.md](./docs/ROADMAP.md) · [docs/TESTING.md](./docs/TESTING.md) · [docs/DECISIONS.md](./docs/DECISIONS.md) · [docs/INVARIANTS.md](./docs/INVARIANTS.md)
- [docs/FLOW.md](./docs/FLOW.md) · [docs/DEBUG.md](./docs/DEBUG.md) · [docs/AST_PLUGINS.md](./docs/AST_PLUGINS.md) · [docs/BACKLOG.md](./docs/BACKLOG.md)

## Packages

| Package | Role |
|---|---|
| **`@zntc/core`** | NAPI `.node` binding + Node / Bun CLI (`zntc`) + transpile / bundle / lightningcss |
| **`@zntc/web`** | dev server + HMR overlay + postcss / sass pipeline + dev controller |
| **`@zntc/vite-plugin`** | Replace Vite's esbuild transform with ZNTC (only depends on `@zntc/core`) |
| **`@zntc/rspack-loader`** | TS / JSX / Flow loader for Rspack / Webpack (drop-in replacement for swc-loader / esbuild-loader) |
| **`@zntc/react-native`** | RN preset + Metro-compatible dev server + Reanimated worklets / Flow / Hermes |
| **`@zntc/init`** | `npx @zntc/init` — scaffold new projects or overlay an existing RN CLI app |
| **`@zntc/wasm`** | WASM build (browser playground / Deno / Workers) |
| `@zntc/server` | private — protocol / WS frame / watcher / HMR channel (inlined into `@zntc/web` dist; users do not install directly) |

## Status

**Phase 1–6 largely complete** — lexer / parser / semantic / transformer / codegen / bundler / dev server / HMR.

- Test262: **50,504 / 50,504 (100%)**, 0 fail
- npm package smoke: **144 / 144** passing (compared against esbuild / rolldown / rspack)
- RN core (`react-native` 0.74) 410 `@flow` files pass regression

Open issues and backlog: [docs/ROADMAP.md](./docs/ROADMAP.md) · [docs/BACKLOG.md](./docs/BACKLOG.md) · [GitHub Issues](https://github.com/ohah/zntc/issues).

## Contributing

The core of ZNTC is written in Zig. You need Zig 0.15.2 to build from source (mise is recommended).

```bash
git clone https://github.com/ohah/zntc.git
cd zntc
mise install

# Build
zig build                          # zntc CLI + lib (Debug)
zig build -Doptimize=ReleaseFast   # for performance measurement
zig build run -- src/index.ts      # invoke the CLI directly

# Test
zig build test                     # Zig unit / integration tests
zig build test262-run              # run the 50,504 Test262 cases
zig build napi                     # NAPI .node for @zntc/core
zig build wasm                     # transpile-only WASM
zig build wasm-bundler             # bundler-inclusive WASM (wasm32-wasi + threads)
zig build schema                   # auto-generate the BuildOptions JSON schema
```

JS-side tests:

```bash
cd tests/integration && bun test       # CLI / NAPI integration
cd tests/e2e && bun test               # Playwright E2E
cd tests/benchmark && bun run smoke.ts # build + execute 144 packages vs esbuild / rolldown / rspack
```

Workflow — see [CLAUDE.md](./CLAUDE.md): feature branch → PR → merge. Direct pushes to `main` are not allowed. PR titles use the `feat(lexer): add numeric literal tokenization` style; PR descriptions are written in Korean.

## References

- [Bun JS Parser](https://github.com/oven-sh/bun) (Zig, MIT) — parser / lexer / SIMD
- [oxc](https://github.com/oxc-project/oxc) (Rust, MIT) — transformer / reference flags
- [SWC](https://github.com/swc-project/swc) (Rust, Apache-2.0) — downlevel reference
- [esbuild](https://github.com/evanw/esbuild) (Go, MIT) — bundler architecture / compatibility surface
- [Rolldown](https://github.com/rolldown/rolldown) (Rust, MIT) — Rollup-compatible / Vite integration
- [Hermes](https://github.com/facebook/hermes) (C++, MIT) — embedded Flow parser + RN runtime
- [Metro](https://github.com/facebook/metro) (JS, MIT) — React Native bundler compatibility
- [TypeScript](https://github.com/microsoft/TypeScript) (TS, Apache-2.0) — downlevel / decorator cases
- [Test262](https://github.com/tc39/test262) — TC39 conformance, 50,504 cases

## License

MIT
