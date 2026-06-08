# @zntc/core

English · **[한국어](./README_KO.md)**

> The core of ZNTC (Zig Native Transpiler & Compiler) — a NAPI binding + JS API + `zntc` CLI for a JS / TS / Flow transpiler and bundler written in Zig.

[![npm](https://img.shields.io/npm/v/@zntc/core.svg)](https://www.npmjs.com/package/@zntc/core)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](https://github.com/ohah/zntc/blob/main/LICENSE)

`@zntc/core` ships the native `.node` NAPI binding plus the `zntc` CLI for Node.js and Bun. It targets SWC / oxc-class performance and provides in-process (NAPI) calls, Vite / Rollup adapters, and a standalone CLI — covering transpile, bundle, and lightningcss-based CSS handling.

## Installation

```bash
bun add -D @zntc/core
# or
npm i -D @zntc/core
```

Platform-specific prebuilt binaries are installed automatically (linux / darwin / windows × x64 / arm64).

### Optional (as needed)

```bash
bun add -D browserslist core-js core-js-compat lightningcss
```

- `browserslist` / `core-js-compat` — required for the `runtimePolyfills` option
- `lightningcss` — required for CSS minify / nesting

## Usage

### CLI

```bash
# Transpile a single file
bunx zntc src/index.ts --outfile out.js

# Bundle (multi-entry)
bunx zntc --bundle src/index.ts --outfile dist/bundle.js --format=esm --target=node
```

See `bunx zntc --help` for the full list of options.

App mode (`bunx zntc dev / build / preview`) requires `@zntc/web` or `@zntc/react-native` to also be installed — see each package's README.

### JS / NAPI API

```ts
import { init, transpile, build } from '@zntc/core';

await init();

// Transpile a single file
const r = transpile('const x: number = 1;', { filename: 'input.ts' });
console.log(r.code); // "const x = 1;"

// Bundle (multi-file)
const out = await build({
  entryPoints: ['src/index.ts'],
  outdir: 'dist',
  format: 'esm',
  target: 'es2020',
});
```

## Related packages

- [@zntc/web](https://npmjs.com/package/@zntc/web) — dev server + HMR overlay + postcss / sass
- [@zntc/react-native](https://npmjs.com/package/@zntc/react-native) — RN preset + Metro HMR adapter
- [@zntc/wasm](https://npmjs.com/package/@zntc/wasm) — browser-side WASM build (instead of NAPI)
- [@zntc/init](https://npmjs.com/package/@zntc/init) — add ZNTC to an existing RN project
- [@zntc/vite-plugin](https://npmjs.com/package/@zntc/vite-plugin) — replace Vite's esbuild transform with ZNTC

## Documentation

- Repository: <https://github.com/ohah/zntc>
- Docs: <https://ohah.github.io/zntc>

## License

MIT
