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

Supported loaders: `js`, `ts`, `json`, `text`, `css`, `file`, `dataurl`, `binary`, `copy`, `empty`

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

`--target` lowers syntax. `--runtime-polyfills` fills runtime API gaps with `core-js`. When APIs such as `String.prototype.replaceAll`, `Array.prototype.at`, `Object.hasOwn`, `Promise`, `Map`, `Set`, or `structuredClone` are detected in the bundle graph, ZNTC injects the required `core-js/modules/*.js` prelude before the user entry runs.

```bash
bun add core-js core-js-compat

zntc --bundle entry.ts -o bundle.js \
  --target=es5 \
  --runtime-polyfills=auto \
  --runtime-target="ios_saf 12" \
  --core-js=3.49
```

Modes:

| Mode | Behavior |
|---|---|
| `off` | Default. Does not load `core-js-compat` or run the graph collector |
| `auto` | Injects only graph-used `core-js` modules that the target does not support |
| `usage` | Alias for the same graph usage mode as `auto` |
| `entry` | Injects every target-required `core-js` ES/Web module into the entry prelude regardless of usage |

`auto`/`usage` does not use a Babel pre-scan in the JS wrapper. It runs from the native graph after resolve, package exports, aliases, plugin load, and plugin transform. Dependency code is included in detection, and when code splitting is enabled the runtime prelude remains a graph root that executes before user entries.

Config/API usage can pass an object for `include`/`exclude` control.

```ts
import { build } from "@zntc/core";

await build({
  entryPoints: ["src/index.ts"],
  bundle: true,
  outfile: "dist/index.js",
  target: "es5",
  runtimePolyfills: {
    mode: "auto",
    targets: ["safari 12", "ios_saf 12"],
    coreJs: "3.49",
    include: ["es.array.at"],
    exclude: ["web.url"],
  },
});
```

`include` forces modules into the runtime prelude. `exclude` removes modules after target and usage calculation. Values can be written as `es.string.replace-all` or `core-js/modules/es.string.replace-all.js`.

Runtime targets are Browserslist queries using the same shape as Rspack/SWC `env.targets`. Use explicit queries such as `ios_saf 12`, `safari 12`, or `node 18`; compact shorthand such as `ios12` or `node18`, and physical device names such as `"iPhone 8"`, are not supported. Use `--platform=react-native` for the default Hermes target.

Detection is static AST based. Local bindings/imports that shadow globals are ignored, and dynamic computed access such as `obj["replaceAll"]()` is not inferred. Cover those cases with `include` or `entry` mode.

Execution order preserves existing manual polyfills and entry hooks.

```text
manual polyfills / inject roots -> runtime core-js prelude -> runBeforeMain -> user entry
```

`runBeforeMain` is an array of module paths to run immediately before the entry module. They are pulled into the bundle graph and emitted as a prelude that runs after manual polyfills / runtime polyfills and just before the user entry. Use it for environment setup that must run before the entry — for example the React Native polyfill flow (`InitializeCore` and friends). For plain polyfill injection that runs at the very start of the bundle, use `polyfills` instead.

```ts
defineConfig({
  runBeforeMain: ["./src/setup-env.ts"],
});
```

For observability, enable the runtime polyfill debug category with graph profiling.

```bash
ZNTC_DEBUG=runtime_polyfills zntc --bundle entry.ts \
  --runtime-polyfills=auto \
  --runtime-target="safari 12" \
  --profile=graph \
  --profile-level=detailed \
  --profile-format=json
```

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
