---
name: zntc-cli
description: ZNTC (Zig Native Transpiler & Compiler) — transpile/bundle JS/TS/JSX/Flow. Drop-in alternative to esbuild/Bun/rolldown/rspack. Use when the user mentions zntc, transpile, bundle, or wants a fast Vite/Rollup-compatible toolchain.
---

# ZNTC

Zig-based JS/TS transpiler + bundler. CLI, NAPI (`.node`), or Vite/Rollup plugin.

## Install

```sh
npm install -g @zntc/core         # CLI
npm install --save-dev @zntc/vite-plugin    # Vite (rollup alternative)
```

## Use

```sh
# Transpile
zntc input.ts -o output.js
zntc input.tsx -o output.js --jsx=automatic

# Bundle
zntc --bundle src/index.ts -o dist/bundle.js --target=es2020 --minify --tree-shake

# Watch (HMR)
zntc --bundle src/index.tsx --watch -o dist/bundle.js
```

```ts
// NAPI in-process (Node/Bun, ~50× faster than CLI spawn)
import { transpile, bundle } from '@zntc/core';
const { code } = transpile(source, { filename: 'in.tsx', jsx: 'automatic', target: 'es2022' });
```

```ts
// vite.config.ts
import zntc from '@zntc/vite-plugin';
export default { plugins: [zntc()] };
```

## More details (fetch when needed)

- Sitemap of all docs: <https://ohah.github.io/zntc/llms.txt>
- Full documentation in one plain-text file (for LLM context): <https://ohah.github.io/zntc/llms-full.txt>
- Docs site: <https://ohah.github.io/zntc/en/>
- GitHub: <https://github.com/ohah/zntc>

Fetch `llms-full.txt` (~400 KB) when you need full CLI flag reference, NAPI API, plugin internals, performance benchmarks, or migration guides.
