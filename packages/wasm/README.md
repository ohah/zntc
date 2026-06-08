# @zntc/wasm

English · **[한국어](./README_KO.md)**

> WASM build of [ZNTC](https://github.com/ohah/zntc) — transpile and bundle JavaScript / TypeScript / Flow in the browser, Deno, or Cloudflare Workers, with no native binary required.

[![npm](https://img.shields.io/npm/v/@zntc/wasm.svg)](https://www.npmjs.com/package/@zntc/wasm)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](https://github.com/ohah/zntc/blob/main/LICENSE)

`@zntc/wasm` runs the ZNTC pipeline as pure WebAssembly. It's for environments where the `@zntc/core` NAPI module can't be loaded — browser in-page transpile, Edge runtimes, Cloudflare Workers, Deno — without needing a platform-specific `.node` binary.

For server-side builds on Node / Bun, prefer [`@zntc/core`](https://www.npmjs.com/package/@zntc/core) (native speed). Reach for `@zntc/wasm` when the environment rules out NAPI.

## Installation

```bash
bun add -D @zntc/wasm
# or
npm i -D @zntc/wasm
```

The WASM binaries ship with the package: `zntc.wasm` (~1.1 MB / 388 KB gzipped, transpile-only) and `zntc-bundler.wasm` (~2.0 MB / 675 KB gzipped, bundler).

## Usage

### Browser / Edge runtime / Workers

```ts
import { init, transpile } from '@zntc/wasm';
import wasmUrl from '@zntc/wasm/zntc.wasm?url'; // Vite-specific syntax

await init(wasmUrl);
const result = transpile('const x: number = 1;', { filename: 'input.ts' });
console.log(result.code);
```

> Bundlers other than Vite use `fetch(new URL('@zntc/wasm/zntc.wasm', import.meta.url))` or their own asset-import pattern to obtain the WASM URL.

### Deno / Node.js / Bun (auto-resolve)

```ts
import { init, transpile } from '@zntc/wasm';

await init(); // loads the bundled zntc.wasm automatically (fs.readFileSync)
const result = transpile('const x: number = 1;', { filename: 'input.ts' });
```

### Bundler build

```ts
import { build, initBundler, bundlerLastErrorMessage } from '@zntc/wasm';
import wasmUrl from '@zntc/wasm/zntc-bundler.wasm?url';

await initBundler(wasmUrl); // separate from init() used for transpile
const out = build('/main.ts', { format: 'esm', target: 'es2020' });
if (out === null) throw new Error(bundlerLastErrorMessage());
```

`build` is synchronous and returns `null` on failure — call `bundlerLastErrorMessage()` to read the last error.

## `@zntc/core` vs `@zntc/wasm`

|             | `@zntc/core` (NAPI)   | `@zntc/wasm`                              |
| ----------- | --------------------- | ----------------------------------------- |
| Environment | Node.js / Bun         | + Browser / Edge / Workers / Deno         |
| Speed       | Native                | ~50–70% (WASM overhead)                   |
| Binary size | ~4 MB (`.node`)       | 1.1 MB + 2.0 MB (388 KB + 675 KB gzipped) |
| Install     | Per-platform prebuilt | Single universal `.wasm`                  |

## Documentation

- Repository: <https://github.com/ohah/zntc>
- Official docs: <https://ohah.github.io/zntc>
- Native build: [`@zntc/core`](https://www.npmjs.com/package/@zntc/core)

## License

MIT
