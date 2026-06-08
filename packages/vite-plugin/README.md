# @zntc/vite-plugin

English · **[한국어](./README_KO.md)**

> Replace Vite's esbuild transform with ZNTC — TypeScript / JSX / Flow / decorators handled by ZNTC (Zig-based), while Vite's dev server / HMR / plugin ecosystem stays intact.

[![npm](https://img.shields.io/npm/v/@zntc/vite-plugin.svg)](https://www.npmjs.com/package/@zntc/vite-plugin)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](https://github.com/ohah/zntc/blob/main/LICENSE)

This plugin swaps Vite's built-in esbuild transform step for [ZNTC](https://github.com/ohah/zntc), a single-pass transpiler written in Zig. TypeScript, JSX, Flow, and decorator transforms all flow through ZNTC, and you keep the rest of the Vite pipeline (dev server, HMR, plugins) untouched.

## Installation

```bash
bun add -D @zntc/vite-plugin @zntc/core
# or
npm i -D @zntc/vite-plugin @zntc/core
```

`@zntc/core` (which ships the native NAPI binary) is required alongside the plugin.

## Usage

```ts
// vite.config.ts
import { defineConfig } from 'vite';
import { zntc } from '@zntc/vite-plugin';

export default defineConfig({
  plugins: [zntc()],
  // Disable esbuild — ZNTC handles .ts / .tsx / .jsx transforms.
  esbuild: false,
});
```

### Options

```ts
zntc({
  include: /\.(tsx?|jsx)$/, // files to transform (default)
  exclude: /node_modules/, // files to skip (default)
  tsconfigCache: true, // cache tsconfig autodiscovery results (default: true)
  transpileOptions: {
    // ZNTC transpile options (target / jsx / decorators, etc.)
    target: 'es2020',
    jsx: 'automatic',
  },
});
```

### Using with framework plugins

Most framework plugins (`@vitejs/plugin-react`, `@vitejs/plugin-vue`, `@sveltejs/vite-plugin-svelte`, `vite-plugin-solid`) work alongside ZNTC without conflict. The exception is a **Babel-based plugin that re-transforms `.tsx` on its own** — most notably `@preact/preset-vite` — where `.tsx` gets processed twice and the output can break (the JSX return inside a component body ends up empty).

In that case set `jsx: 'preserve'`. ZNTC then skips `.tsx` / `.jsx` and lets the framework plugin handle both JSX and TS, while `.ts` is still processed by ZNTC.

```ts
// preact + vite
import { defineConfig } from 'vite';
import preact from '@preact/preset-vite';
import { zntc } from '@zntc/vite-plugin';

export default defineConfig({
  plugins: [zntc({ transpileOptions: { jsx: 'preserve' } }), preact()],
});
```

`jsx: 'preserve'` is equivalent to tsc's `"jsx": "preserve"` — it delegates JSX transformation to a downstream tool.

### Peer requirements

- `vite >= 5.0.0` (8.x recommended)

## Documentation

- Monorepo: <https://github.com/ohah/zntc>
- Docs: <https://ohah.github.io/zntc>

## License

MIT
