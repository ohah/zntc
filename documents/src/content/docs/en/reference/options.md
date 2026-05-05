---
title: Transpile Options
description: Full reference of ZTS transpile options, generated from the Zig `TranspileOptionsDto` struct.
---

ZTS transpile options are sourced from a **JSON Schema auto-generated at comptime from the Zig `TranspileOptionsDto` struct**. After editing the struct, run `zig build schema` to regenerate the schema that powers this page.

## Schema URL

Use `$schema` to get autocomplete in VSCode / IntelliJ / any JSON-schema-aware editor:

```json
{
  "$schema": "https://ohah.github.io/zts/schemas/transpile-options.schema.json",
  "target": "es2022",
  "sourcemap": true
}
```

> **Note**: This schema describes the **internal JSON payload** that WASM/NAPI forwards to the Zig engine. User-facing `zts.config.*` loading and CLI merge logic are implemented separately in `@zts/core` and accept camelCase options. This schema uses Zig-native enum spellings such as `"react_native"`, so it is not always identical to config-file/API syntax.

## Options

### Target / downlevel

| Option | Type | Default | Description |
|---|---|---|---|
| `target` | `es5`, `es2015`–`es2025`, `esnext` | `esnext` | ES downlevel target. When set, features introduced after the target version are auto-lowered |
| `unsupported` | `integer` (u32) | `0` | Direct `UnsupportedFeatures` bitmask. Used to inject browserslist-derived feature sets — takes precedence over `target` |
| `runtimePolyfills` | `"off" \| "auto" \| "usage" \| "entry" \| object` | `"off"` | Inject core-js runtime API polyfills. `"auto"`/`"usage"` select from actual bundle graph usage; `"entry"` injects every target-required module |
| `coreJs` | `string` | installed version | Version hint for core-js-compat; same role as `runtimePolyfills.coreJs` |

#### Runtime Polyfills / core-js

`target` handles syntax downleveling. `runtimePolyfills` handles runtime APIs such as `Promise`, `Map`, `Object.values`, `String.prototype.replaceAll`, `Array.prototype.at`, and `structuredClone` by adding a `core-js` prelude.

```ts
import { defineConfig } from "@zts/core";

export default defineConfig({
  entryPoints: ["src/index.ts"],
  bundle: true,
  target: "es5",
  runtimePolyfills: {
    mode: "auto",
    targets: ["ios_saf 12", "safari 12"],
    coreJs: "3.49",
    include: ["es.array.at"],
    exclude: ["web.url"],
  },
});
```

The `runtimePolyfills` object accepts these fields.

| Field | Type | Description |
|---|---|---|
| `mode` | `"auto" \| "usage" \| "entry"` | `"auto"` and `"usage"` both select target-compatible modules from graph-detected usage. `"entry"` injects every ES/Web module that `core-js-compat` reports as required by the target |
| `provider` | `"core-js"` | Only `core-js` is currently supported |
| `targets` | `string \| string[]` | Browserslist queries passed to `core-js-compat`, using the same shape as Rspack/SWC `env.targets` |
| `coreJs` | `string` | core-js version used by `core-js-compat`. When omitted, ZTS reads the installed `core-js/package.json` version |
| `include` | `string[]` | `core-js` modules to always inject. Both `es.array.at` and `core-js/modules/es.array.at.js` are accepted |
| `exclude` | `string[]` | `core-js` modules to remove after target and usage calculation |
| `proposals` | `boolean` | Include proposal polyfills when querying `core-js-compat` |

`runtimePolyfills: "off"` is the default. In this mode, ZTS does not load `core-js-compat`, run the graph collector, or enter the profile/debug paths. With `"auto"` or `"usage"`, the JS wrapper computes target-compatible `core-js` candidates and absolute paths, then the native bundler reads the real graph AST after resolve/load/plugin transforms and injects only the modules that were actually used.

`core-js-compat` and `core-js` are optional dependencies. Install them in projects that enable runtime polyfills.

```bash
bun add core-js core-js-compat
```

Targets use Browserslist syntax.

```ts
runtimePolyfills: {
  mode: "auto",
  targets: ["chrome >= 87", "edge >= 88", "firefox >= 78", "safari >= 14"],
}
```

Explicit queries such as `ios_saf 12`, `safari 12`, and `node 18` are supported. Compact shorthand such as `ios12` or `node18`, and physical device names such as `"iPhone 8"`, are not supported. Use `platform: "react-native"` for the default Hermes runtime target. ZTS does not expose a top-level `runtimeTargets` option.

Detection is based on the static graph AST. Local bindings/imports that shadow `Map`, `Object`, `Promise`, and similar globals are not treated as global API usage, and dynamic computed access such as `obj["replaceAll"]()` is not inferred. Use `include` or `"entry"` for those cases.

### Parsing

| Option | Type | Default | Description |
|---|---|---|---|
| `flow` | `boolean` | `false` | Enable Flow type stripping |
| `jsxInJs` | `boolean` | `false` | Allow JSX in `.js` / `.jsx` (default: only `.tsx`) |
| `experimentalDecorators` | `boolean` | `false` | Legacy TC39 stage-1 decorators |
| `emitDecoratorMetadata` | `boolean` | `false` | Emit decorator metadata (requires `experimentalDecorators`) |

### JSX

| Option | Type | Default | Description |
|---|---|---|---|
| `jsx` | `classic`, `automatic`, `automatic_dev` | `classic` | JSX runtime |
| `jsxFactory` | `string` | `"React.createElement"` | Classic-mode factory |
| `jsxFragment` | `string` | `"React.Fragment"` | Classic-mode Fragment |
| `jsxImportSource` | `string` | `"react"` | Automatic-mode import source |

### Output

| Option | Type | Default | Description |
|---|---|---|---|
| `format` | `esm`, `cjs` | `esm` | Module format |
| `quotes` | `double`, `single`, `preserve` | `double` | String quote style |
| `platform` | `browser`, `node`, `neutral`, `react_native` | `browser` | Target platform. Affects Node built-in externals, `import.meta` polyfill, etc. |
| `useDefineForClassFields` | `boolean` | `true` | `[[Define]]` semantics for class fields |
| `asciiOnly` | `boolean` | `false` | Escape non-ASCII as hex escape sequences |
| `charsetUtf8` | `boolean` | `false` | Preserve non-ASCII verbatim |

`asciiOnly` and `charsetUtf8` are paired toggles for the same output charset dimension. The CLI mapping is asymmetric — `--charset=utf8` maps to `charsetUtf8=true` and `--ascii-only` maps to `asciiOnly=true`, but `--charset=ascii` is not accepted.

### Code Splitting / Chunks

| Option | Type | Default | Description |
|---|---|---|---|
| `splitting` | `boolean` | `false` | Split chunks at dynamic-import boundaries and extract shared modules |
| `manualChunks` | `(id, meta) => string \| null` or `[{name, patterns}]` | — | Rollup-compatible custom chunking. Function form via JS API; record form via `zts.config.json` (#2186). [See guide](/zts/guides/manual-chunks/) |
| `inlineDynamicImports` | `boolean` | `false` | Absorb dynamic-import targets into the importer chunk + `__esm` wrapping (single-file output). CLI: `--inline-dynamic-imports` (#2185) |
| `external` | `string[]` | `[]` | Specifiers to exclude from the bundle. Registered as phantom modules in the graph |
| `preserveModules` | `boolean` | `false` | Preserve original directory structure instead of bundling (Rollup compatible) |
| `outputExports` | `auto`, `named`, `default`, `none` | `auto` | CJS/UMD entry export shape (Rollup `output.exports` compatible). See full semantics below |

`outputExports` 4-value semantics:

| Value      | Behavior                                                                                                              |
| ---------- | --------------------------------------------------------------------------------------------------------------------- |
| `"auto"`   | default-only → `module.exports = X`. named-only → `exports.X = X` (no `__esModule`). mixed → `exports.X = X` + `__esModule` flag |
| `"named"`  | Always named (`exports.X = X`). When a default export is also present, `__esModule` flag is added automatically (rolldown `IfDefaultProp`) |
| `"default"`| Single `module.exports = X`. Only emits correctly when the entry has default-only exports — mixing in named exports triggers a warning and **empty output** |
| `"none"`   | Do not emit any export                                                                                                |

`outputExports` is ignored for ESM output.

### Minify

| Option | Type | Default | Description |
|---|---|---|---|
| `minifyWhitespace` | `boolean` | `false` | Remove whitespace |
| `minifyIdentifiers` | `boolean` | `false` | Mangle local identifiers |
| `minifySyntax` | `boolean` | `false` | Syntax-level optimization |

### Drop

| Option | Type | Default | Description |
|---|---|---|---|
| `dropConsole` | `boolean` | `false` | Remove `console.*` calls |
| `dropDebugger` | `boolean` | `false` | Remove `debugger` statements |

### Sourcemap

| Option | Type | Default | Description |
|---|---|---|---|
| `sourcemap` | `boolean` | `false` | Emit sourcemap JSON |
| `sourcemapMode` | `linked`, `external`, `inline` | `linked` | Sourcemap output style. `linked` = external `.js.map` + `sourceMappingURL` comment (esbuild/rolldown default) |
| `sourcemapDebugIds` | `boolean` | `false` | Sentry-compatible Debug ID |
| `sourcesContent` | `boolean` | `true` | Include original source in sourcemap |
| `sourceRoot` | `string` | `""` | Sourcemap `sourceRoot` field |

### Define

| Option | Type | Default | Description |
|---|---|---|---|
| `define` | `Array<{key, value}>` | `[]` | Identifier substitution. `value` is **raw JSON** — strings must be quoted (e.g., `value: "\"1.0.0\""`) |

### Diagnostics / Logging

| Option | Type | Default | Description |
|---|---|---|---|
| `logLevel` | `"silent" \| "error" \| "warning" \| "info" \| "debug" \| "verbose"` | `"warning"` | Filter applied to the NAPI build result `errors`/`warnings` arrays. `"silent"` empties both arrays. `"error"` empties only `warnings`. `"warning"` (default) keeps both. `"info"` / `"debug"` / `"verbose"` currently behave like `"warning"` (no info-level diagnostics are emitted yet). `build()` does **not** throw based on `logLevel` — failures must be inspected via `result.errors` |
| `logLimit` | `number` | `0` | Per-array cap on `errors` and `warnings`. `0` means unlimited. Mirrors esbuild `logLimit` |

## Relation to the TS API

When calling the transpiler programmatically, use the `TranspileOptions` interface from `@zts/core` / `@zts/wasm` — it accepts camelCase + kebab-case enums. Project configuration is handled by the `zts.config.{ts,mts,cts,mjs,js,cjs,json}` / `zts.workspace.*` loaders:

```ts
import { transpile } from "@zts/wasm";

transpile(source, {
  target: "es2021",
  platform: "react-native",  // hyphen allowed — JS wrapper converts to "react_native"
  jsx: "automatic-dev",      // same — converted to "automatic_dev"
});
```

The TS interface is handwritten to keep JSDoc / IDE hover rich (same policy as biome / swc). The two forms are bridged by `buildOptionsJson` in the JS wrapper.

## Regenerating the schema

After editing the DTO:

```bash
zig build schema
```

`documents/public/schemas/transpile-options.schema.json` is updated and served at `/zts/schemas/transpile-options.schema.json` on the docs site.
