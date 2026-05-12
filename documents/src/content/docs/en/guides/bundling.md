---
title: Bundling
description: A detailed guide to ZNTC bundling features.
---

## Basic Bundling

```bash
zntc --bundle entry.ts -o bundle.js
```

## Output Directory

```bash
zntc --bundle entry.ts --outdir dist/
```

## Code Splitting

Splits dynamic imports and shared modules into separate chunks.

```bash
zntc --bundle entry.ts --splitting --outdir dist/
```

## Preserve Modules

Preserves the original directory structure for library builds (Rollup/Rolldown compatible).

```bash
zntc --bundle src/index.ts --preserve-modules --outdir dist/
zntc --bundle src/index.ts --preserve-modules --preserve-modules-root=src --outdir dist/
```

## Platforms

```bash
zntc --bundle entry.ts --platform=browser       # Default, IIFE wrapping
zntc --bundle entry.ts --platform=node          # Node built-ins are external
zntc --bundle entry.ts --platform=react-native  # RN preset
```

### browser (default)

- Defaults to IIFE format when `--format` is not specified
- Automatically defines `process.env.NODE_ENV` as `"production"`
- Replaces Node built-in modules with empty modules

### node

- Automatically externalizes Node built-in modules and their subpaths

### react-native

- Automatically resolves `.native.*` / `.ios.*` / `.android.*` extensions
- `main-fields`: `react-native, browser, module, main`
- Flow is enabled automatically

## External

```bash
zntc --bundle entry.ts --external react --external react-dom
```

## Alias

```bash
zntc --bundle entry.ts --alias:react=preact/compat
```

In the config, two forms are supported (esbuild / Vite compatible).

```ts
// Object form — exact + prefix matching (esbuild alias)
defineConfig({
  alias: { react: "preact/compat", "@/": "./src/" },
});

// Array form — RegExp supported (Vite resolve.alias). build() only, not buildSync.
defineConfig({
  alias: [
    { find: /^@\/(.*)$/, replacement: "./src/$1" },
    { find: "lodash", replacement: "lodash-es" },
  ],
});
```

`alias` is substituted **unconditionally before** normal resolution. To apply only on resolve failure, use `fallback`. See the Babel migration guide for full `babel-plugin-module-resolver` mapping.

## Fallback

Compatible with webpack `resolve.fallback` / Metro `resolver.extraNodeModules`. Applied **only when normal resolution fails**. Mainly used to swap in browser polyfills for Node built-ins.

```ts
defineConfig({
  fallback: {
    fs: false,                       // replace with empty module
    crypto: "crypto-browserify",
    stream: "stream-browserify",
  },
});
```

A string value re-resolves to that specifier. `false` substitutes an empty module.

## Block List

Compatible with Metro `resolver.blockList` / webpack `IgnorePlugin`. Matching absolute paths fail to resolve and are excluded from the bundle graph.

```ts
defineConfig({
  blockList: [
    /\/__mocks__\//,
    /\.test\.tsx?$/,
    "/private-internal/.*",
  ],
});
```

- `RegExp`: extracts `.source` and uses it as the pattern
- `string`: treated as a regex string verbatim
- Supported syntax: literals, `.*`, `^`, `$`, `\x` escapes. `|`, `[]`, `()`, `+?`, `\w\d` are not supported
- With `platform: "react-native"`, Metro's default patterns (`__tests__`, iOS/Android build folders, etc.) are auto-prepended; user patterns are appended after

## Loader

```bash
zntc --bundle entry.ts --loader:.png=file --loader:.svg=dataurl
```

Supported loaders: `js`, `jsx`, `ts`, `tsx`, `json`, `css`, `text`, `file`, `dataurl`, `base64`, `binary`, `copy`, `empty`

## Web Worker

ZNTC auto-detects the `new Worker(new URL("./worker.ts", import.meta.url))` pattern and emits the worker entry as a **standalone IIFE bundle**. No additional build configuration or entry option is needed.

```ts
// src/main.ts
const worker = new Worker(new URL("./worker.ts", import.meta.url));
worker.postMessage({ task: "compute", n: 1000 });
worker.onmessage = (e) => console.log(e.data);

// src/worker.ts
self.onmessage = (e) => {
  const { task, n } = e.data;
  if (task === "compute") {
    let sum = 0;
    for (let i = 0; i < n; i++) sum += i;
    self.postMessage({ sum });
  }
};
```

`SharedWorker` is auto-detected with the same pattern (`new SharedWorker(new URL(...))`).

### Output

The worker entry is emitted as a **separate chunk** (not an import dependency of the main bundle). Its filename uses the fixed form `<source-stem>-<crc32-hex>.js` (the `--chunk-names` pattern does not apply here), and the `new Worker(new URL(...))` call site in the main bundle is automatically rewritten to point at the built worker URL. The worker chunk's module format is always IIFE (or CJS when bundling for a Node CJS target).

### Limitations

- Only the **exact static pattern** `new Worker(new URL(...))` / `new SharedWorker(new URL(...))` is auto-detected. These forms are not picked up:
  - URL stored in a variable: `const url = new URL(...); new Worker(url);`
  - Dynamic path: `new Worker(new URL(\`./${name}.ts\`, import.meta.url))`
  - Aliased constructor: `const W = Worker; new W(new URL(...))`
- The second-argument options object (e.g. `{ type: "module" }`) is ignored — workers are always bundled as IIFE. If you need an ESM module worker, build it as a separate entry and pass the URL manually.
- `ServiceWorker` is not auto-detected. Build it as a separate entry and pass the resulting URL manually.

## Filename Patterns

```bash
zntc --bundle entry.ts --outdir dist/ \
  --entry-names="[name]-[hash]" \
  --chunk-names="chunks/[name]-[hash]" \
  --asset-names="assets/[name]-[hash]"
```

## Banner / Footer / Intro / Outro

`banner` / `footer` insert text **outside** the format wrapper, at the very top/bottom (license headers, shebangs). `intro` / `outro` insert text **inside** the wrapper, before/after the bundle code (Rollup `output.intro`/`output.outro` compatible). The difference is most visible with wrapper formats like IIFE/UMD.

```bash
zntc --bundle entry.ts -o bundle.js \
  --banner:js="/* MIT License */" \
  --footer:js="/* End of bundle */" \
  --intro="'use strict';" \
  --outro="globalThis.__BUILD_OK__ = true;"
```

```ts
defineConfig({
  banner: "/* MIT License */",
  footer: "/* End of bundle */",
  intro: "'use strict';",
  outro: "globalThis.__BUILD_OK__ = true;",
});
```

## Metafile

```bash
zntc --bundle entry.ts -o bundle.js --metafile=meta.json
zntc --bundle entry.ts -o bundle.js --analyze
```

Upload `meta.json` to [Metafile Analyze](/zntc/analyze/) to inspect output sizes, input sizes, and the import graph.

### Which metric to look at, and what to do about it

| Metric | What it tells you | Action |
|---|---|---|
| **bytesInOutput per chunk** | Chunk size distribution | If one chunk is bloated, try `--splitting` or `manualChunks` |
| **inputs[].imports** | Which module imports what | Surface unintended deep imports (e.g. all of `lodash`) — switch to named imports |
| **inputs[].bytes vs bytesInOutput** | Input vs output size ratio | Ratio close to 1 means tree-shaking barely fired — check `sideEffects` / `@__PURE__` |
| **outputs[].imports** | Inter-chunk dependency graph | Decide preload/prefetch priority |
| **entry pointer chain** | Hops from entry to first used module | Candidates for shortening initial-load critical path |

## `allowOverwrite`

By default ZNTC refuses output paths that would overwrite an input file. Allow it explicitly when you really intend an in-place transpile.

```bash
zntc --bundle src/index.ts -o src/index.ts --allow-overwrite
```

```ts
defineConfig({
  entryPoints: ["src/index.ts"],
  outfile: "src/index.ts",
  allowOverwrite: true,
});
```

Note: with sourcemaps enabled, overwriting in place causes the second build's sourcemap reference to point at the first build's output. Prefer a separate output directory whenever possible.

## Minify

```bash
zntc --bundle entry.ts -o bundle.js --minify  # All three

# Granular (esbuild-compatible) — toggle individually
zntc --bundle entry.ts -o bundle.js --minify-whitespace
zntc --bundle entry.ts -o bundle.js --minify-syntax
zntc --bundle entry.ts -o bundle.js --minify-identifiers
```

## Code Dropping

```bash
zntc --bundle entry.ts --drop=console --drop=debugger
zntc --bundle entry.ts --drop-labels=DEV,TEST
```

`--drop-labels` removes the whole labeled statement for matching labels. For example,
`DEV: { console.log("dev only"); }` is omitted when `--drop-labels=DEV` is set.

## ES Target

```bash
# ES version (es2015~esnext)
zntc --bundle entry.ts -o bundle.js --target=es2020

# Engine target — feature-level downleveling
zntc --bundle entry.ts -o bundle.js --target=chrome80,safari14
zntc --bundle entry.ts -o bundle.js --target=node18
zntc --bundle entry.ts -o bundle.js --target=hermes0.70
```

### `browserslist`

You can specify the downleveling matrix with a Browserslist query string (or string array) instead of `target`. When set, `browserslist` **takes precedence** over `target`. With `platform: "react-native"`, the Hermes matrix is enforced and `browserslist` cannot be passed (ignored at runtime).

```ts
defineConfig({
  browserslist: "> 0.5%, last 2 versions, not dead",
  // or
  // browserslist: ["chrome >= 80", "safari >= 14"],
});
```

The matrix is shared with CSS post-processing (Lightning CSS).

## Runtime Polyfills (core-js)

`--target` lowers syntax; `--runtime-polyfills` fills runtime API gaps (`Promise`, `Map`, `String.prototype.replaceAll`, `Array.prototype.at`, `structuredClone`, …) with `core-js`. The `core-js/modules/*.js` the target doesn't support are detected in the bundle graph and injected as a prelude that runs before the user entry.

```bash
bun add core-js core-js-compat
zntc --bundle entry.ts -o bundle.js --target=es5 --runtime-polyfills=auto --runtime-target="ios_saf 12"
```

Modes (`auto`/`usage`/`entry`/`off`), the `runtimePolyfills` config object, the `@babel/preset-env useBuiltIns` mapping, execution order — see → **[Runtime Polyfills (core-js)](/zntc/en/guides/runtime-polyfills/)**.
## Output Format

```bash
zntc --bundle entry.ts --format=esm    # ESM (default)
zntc --bundle entry.ts --format=cjs    # CommonJS
zntc --bundle entry.ts --format=iife --global-name=MyLib  # IIFE
zntc --bundle entry.ts --format=umd --global-name=MyLib   # UMD
zntc --bundle entry.ts --format=amd                       # AMD
```

### IIFE/UMD external → global mapping (`globals`)

Compatible with Rollup `output.globals`. In IIFE/UMD output, substitutes `external` specifiers with runtime global variables.

```bash
zntc --bundle entry.ts -o bundle.js --format=umd --global-name=MyLib \
  --external react --external react-dom \
  --global:react=React --global:react-dom=ReactDOM
```

```ts
defineConfig({
  format: "umd",
  globalName: "MyLib",
  external: ["react", "react-dom"],
  globals: { react: "React", "react-dom": "ReactDOM" },
});
```

## Watch Mode

```bash
zntc --bundle entry.ts -o bundle.js --watch
zntc --bundle entry.ts -o bundle.js --watch-json  # NDJSON event output
```

## Debugging — limits worth knowing

The cases you most commonly trip over when bundle output isn't what you expect.

### CJS wrapper modules don't tree-shake

```ts
// my-lib (CJS)
const featureA = require('./feature-a');
const featureB = require('./feature-b');
module.exports = { featureA, featureB };
```

```ts
// entry.ts
import { featureA } from 'my-lib';   // featureB is also bundled
```

A `require_X()` call counts as a side effect, so the entire CJS wrap module is preserved even when the named import is unused. Either migrate the library to ESM or import the deep path directly:

```ts
import featureA from 'my-lib/feature-a';  // only what you need
```

JSON modules are converted to ESM ASTs and *do* tree-shake at the named-export level.

### Variables that shadow globals get auto-renamed

```ts
const document = createVirtualDocument();
document.title = "Hi";
```

In the bundle this becomes `document$1` or similar — automatic protection against TDZ and shadowing accidents. Sourcemaps preserve the original names. Which names are protected depends on the target environment (`browser` / `node` / `react-native`).

### Namespace re-export hurts tree-shaking precision

```ts
// barrel.ts
import * as utils from './utils';
export { utils };
```

This pattern marks every export of `utils` as used. Prefer explicit re-exports when you can:

```ts
export { foo, bar } from './utils';
```

### `--define` values must be JavaScript literals

```bash
# ✗ Wrong — admin becomes an identifier, producing unintended code
zntc --bundle entry.ts --define:USERNAME=admin

# ✓ Right — quote it so it becomes a string literal
zntc --bundle entry.ts --define:USERNAME='"admin"'

# ✓ Numbers / booleans / null are literals as-is
zntc --bundle entry.ts --define:DEBUG=false --define:MAX=100
```

Shell quoting gotcha: in bash/zsh you need to wrap the double quotes in single quotes to keep them.
