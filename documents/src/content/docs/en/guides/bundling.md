---
title: Bundling
description: A detailed guide to ZTS bundling features.
---

## Basic Bundling

```bash
zts --bundle entry.ts -o bundle.js
```

## Output Directory

```bash
zts --bundle entry.ts --outdir dist/
```

## Code Splitting

Splits dynamic imports and shared modules into separate chunks.

```bash
zts --bundle entry.ts --splitting --outdir dist/
```

## Preserve Modules

Preserves the original directory structure for library builds (Rollup/Rolldown compatible).

```bash
zts --bundle src/index.ts --preserve-modules --outdir dist/
zts --bundle src/index.ts --preserve-modules --preserve-modules-root=src --outdir dist/
```

## Platforms

```bash
zts --bundle entry.ts --platform=browser       # Default, IIFE wrapping
zts --bundle entry.ts --platform=node          # Node built-ins are external
zts --bundle entry.ts --platform=react-native  # RN preset
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
zts --bundle entry.ts --external react --external react-dom
```

## Alias

```bash
zts --bundle entry.ts --alias:react=preact/compat
```

## Loader

```bash
zts --bundle entry.ts --loader:.png=file --loader:.svg=dataurl
```

Supported loaders: `js`, `ts`, `json`, `text`, `css`, `file`, `dataurl`, `binary`, `copy`, `empty`

## Filename Patterns

```bash
zts --bundle entry.ts --outdir dist/ \
  --entry-names="[name]-[hash]" \
  --chunk-names="chunks/[name]-[hash]" \
  --asset-names="assets/[name]-[hash]"
```

## Banner / Footer

```bash
zts --bundle entry.ts -o bundle.js \
  --banner:js="/* MIT License */" \
  --footer:js="/* End of bundle */"
```

## Metafile

```bash
zts --bundle entry.ts -o bundle.js --metafile=meta.json
zts --bundle entry.ts -o bundle.js --analyze
```

## Minify

```bash
zts --bundle entry.ts -o bundle.js --minify  # All three

# Granular (esbuild-compatible) — toggle individually
zts --bundle entry.ts -o bundle.js --minify-whitespace
zts --bundle entry.ts -o bundle.js --minify-syntax
zts --bundle entry.ts -o bundle.js --minify-identifiers
```

## Code Dropping

```bash
zts --bundle entry.ts --drop=console --drop=debugger
zts --bundle entry.ts --drop-labels=DEV,TEST
```

`--drop-labels` removes the whole labeled statement for matching labels. For example,
`DEV: { console.log("dev only"); }` is omitted when `--drop-labels=DEV` is set.

## ES Target

```bash
# ES version (es2015~esnext)
zts --bundle entry.ts -o bundle.js --target=es2020

# Engine target — feature-level downleveling
zts --bundle entry.ts -o bundle.js --target=chrome80,safari14
zts --bundle entry.ts -o bundle.js --target=node18
zts --bundle entry.ts -o bundle.js --target=hermes0.70
```

## Runtime Polyfills (core-js)

`--target` lowers syntax. `--runtime-polyfills` fills runtime API gaps with `core-js`. When APIs such as `String.prototype.replaceAll`, `Array.prototype.at`, `Object.hasOwn`, `Promise`, `Map`, `Set`, or `structuredClone` are detected in the bundle graph, ZTS injects the required `core-js/modules/*.js` prelude before the user entry runs.

```bash
bun add core-js core-js-compat

zts --bundle entry.ts -o bundle.js \
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
import { build } from "@zts/core";

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

For observability, enable the runtime polyfill debug category with graph profiling.

```bash
ZTS_DEBUG=runtime_polyfills zts --bundle entry.ts \
  --runtime-polyfills=auto \
  --runtime-target="safari 12" \
  --profile=graph \
  --profile-level=detailed \
  --profile-format=json
```

## Output Format

```bash
zts --bundle entry.ts --format=esm    # ESM (default)
zts --bundle entry.ts --format=cjs    # CommonJS
zts --bundle entry.ts --format=iife --global-name=MyLib  # IIFE
zts --bundle entry.ts --format=umd --global-name=MyLib   # UMD
zts --bundle entry.ts --format=amd                       # AMD
```

## Watch Mode

```bash
zts --bundle entry.ts -o bundle.js --watch
zts --bundle entry.ts -o bundle.js --watch-json  # NDJSON event output
```
