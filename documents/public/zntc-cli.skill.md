---
name: zntc-cli
description: ZNTC (Zig Native Transpiler & Compiler) — transpile/bundle JS/TS/JSX/Flow. Drop-in alternative to esbuild/Bun/rolldown/rspack. Use when the user mentions zntc, transpile, bundle, react-native build/transpile, or wants a fast Vite/Rollup-compatible toolchain.
---

# ZNTC

Zig-based JS/TS transpiler + bundler. Use `npx @zntc/init` to overlay onto an existing project or scaffold a new one — no manual config needed.

## Setup with `@zntc/init`

```sh
# Overlay onto an existing project (auto-detects React Native / Vite / Rspack / Webpack)
npx @zntc/init react-native       # RN CLI project (--platform ios|android)
npx @zntc/init vite               # add @zntc/vite-plugin to existing Vite config
npx @zntc/init rspack             # add @zntc/rspack-loader (also handles Webpack)

# Scaffold a brand-new standalone web project (no Vite/Rspack)
npx @zntc/init web --framework react       # React starter
npx @zntc/init web --framework vanilla     # vanilla starter

# Help
npx @zntc/init --help
```

The init tool edits `package.json`, adds `@zntc/core` + the mode-specific package, and creates a default config only if one doesn't already exist.

## Direct CLI use (after init or for one-shot transpile)

```sh
# Transpile a single file
zntc input.ts -o output.js
zntc input.tsx -o output.js --jsx=automatic

# Bundle
zntc --bundle src/index.ts -o dist/bundle.js --target=es2020 --minify --tree-shake

# Watch mode
zntc --bundle src/index.tsx --watch -o dist/bundle.js
```

```ts
// NAPI in-process (Node/Bun, ~50× faster than CLI spawn)
import { transpile, bundle } from '@zntc/core';
const { code } = transpile(source, { filename: 'in.tsx', jsx: 'automatic', target: 'es2022' });
```

## More details (fetch when needed)

- Sitemap of all docs: <https://ohah.github.io/zntc/llms.txt>
- Full documentation in one plain-text file (for LLM context): <https://ohah.github.io/zntc/llms-full.txt>
- Docs site: <https://ohah.github.io/zntc/en/>
- GitHub: <https://github.com/ohah/zntc>

Fetch `llms-full.txt` (~400 KB) when you need the full CLI flag reference, NAPI API, plugin internals, performance benchmarks, or migration guides.
