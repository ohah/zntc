---
title: Config file (zntc.config.ts)
description: Auto-loaded zntc.config.ts / zntc.config.json with the full option set
---

The ZNTC CLI auto-loads a config file from the current directory. Use `zntc.config.ts` when you need plugins, dynamic values, or bundle settings; use `zntc.config.json` for simple transpilation.

## Quick start — `zntc.config.ts`

Write a type-safe config with `defineConfig` from `@zntc/core`.

```ts
// zntc.config.ts
import { defineConfig } from "@zntc/core";

export default defineConfig({
  target: "es2022",
  platform: "browser",
  sourcemap: true,
  minifySyntax: true,
});
```

Running `zntc input.ts` from the same directory applies these options automatically. CLI args always win over config.

```bash
zntc input.ts                  # uses config.ts values
zntc input.ts --quotes=double  # CLI arg overrides config (CLI > config)
```

A functional config can branch on `command` / `mode` / `env`.

```ts
export default defineConfig(({ command, mode }) => ({
  minify: command === "bundle" && mode === "production",
}));
```

### `zntc.config.json` (schema autocomplete)

If you don't need plugins, write JSON instead. The `$schema` reference gives **autocomplete + type checking** in VSCode / IntelliJ / Zed.

```json
{
  "$schema": "https://ohah.github.io/zntc/schemas/transpile-options.schema.json",
  "target": "es2022",
  "sourcemap": true,
  "minifySyntax": true,
  "platform": "browser"
}
```

### Which one to use

| | `zntc.config.ts` | `zntc.config.json` |
|---|---|---|
| Plugins | ✅ full support | ❌ |
| Dynamic values | ✅ (functions, import) | ❌ |
| JSON schema autocomplete | ❌ | ✅ |
| CLI auto-discovery | bundle/serve only | **all commands** |
| Learning cost | medium | low |

**Recommendation**: simple transpilation / small projects → `zntc.config.json`; plugins / dynamic config / bundling → `zntc.config.ts`. When both exist, `zntc.config.ts` wins (bundle path). Supported extensions: `zntc.config.{ts,mts,cts,mjs,js,cjs,json}`.

## Option priority

ZNTC merges options in this order (**later wins**):

1. Zig defaults
2. `zntc.config.{ts,json}`
3. `tsconfig.json` (a few fields like `compilerOptions.target`)
4. CLI args

CLI args can override config values, but not the reverse. To temporarily disable the config file, rename or delete it.

## Full options

In config files you use **camelCase keys + kebab-case enums** (e.g. `platform: "react-native"`, `jsx: "automatic-dev"`). The tables below are every available option.

### Target / ES downleveling

| Option | Type | Default | Description |
|---|---|---|---|
| `target` | `es5`, `es2015`–`es2025`, `esnext` | `esnext` | ES downlevel target. Features introduced after the version are auto-downlowered |
| `unsupported` | `integer` (u32) | `0` | Set the `UnsupportedFeatures` bitmask directly. Use to inject browserslist resolution — takes precedence over `target` |
| `runtimePolyfills` | `"off" \| "auto" \| "usage" \| "entry" \| object` | `"off"` | core-js runtime API polyfill injection. `"auto"`/`"usage"` are bundle-graph usage based, `"entry"` injects everything required by the target |
| `coreJs` | `string` | installed version | core-js-compat version hint, same as `runtimePolyfills.coreJs` |

When `runtimePolyfills` is an object it accepts `mode` / `provider` / `targets` / `coreJs` / `include` / `exclude` / `proposals`. For modes, execution order, and `@babel/preset-env useBuiltIns` mapping see the [Runtime polyfills guide](/zntc/guides/runtime-polyfills/) and the [Transpile options reference](/zntc/reference/options/).

### Parsing

| Option | Type | Default | Description |
|---|---|---|---|
| `flow` | `boolean` | `false` | Enable Flow type stripping |
| `jsxInJs` | `boolean` | `false` | Allow JSX in `.js` / `.jsx` files too (default is `.tsx` only) |
| `experimentalDecorators` | `boolean` | `false` | Legacy TC39 stage-1 decorators |
| `emitDecoratorMetadata` | `boolean` | `false` | Emit decorator metadata (requires `experimentalDecorators`) |

### JSX

| Option | Type | Default | Description |
|---|---|---|---|
| `jsx` | `classic`, `automatic`, `automatic-dev` | `classic` | JSX runtime selection |
| `jsxFactory` | `string` | `"React.createElement"` | Classic-mode factory |
| `jsxFragment` | `string` | `"React.Fragment"` | Classic-mode Fragment |
| `jsxImportSource` | `string` | `"react"` | Automatic-mode import source |

### Output

| Option | Type | Default | Description |
|---|---|---|---|
| `format` | `esm`, `cjs` | `esm` | Module format |
| `quotes` | `double`, `single`, `preserve` | `double` | String quote style |
| `platform` | `browser`, `node`, `neutral`, `react-native` | `browser` | Target platform. Affects Node builtin externals, import.meta polyfill, etc. |
| `useDefineForClassFields` | `boolean` | `true` | Apply `[[Define]]` semantics to class fields |
| `asciiOnly` | `boolean` | `false` | Escape non-ASCII chars as hex |
| `charsetUtf8` | `boolean` | `false` | Keep non-ASCII chars as-is |

### Code Splitting / Chunks

| Option | Type | Default | Description |
|---|---|---|---|
| `splitting` | `boolean` | `false` | Split chunks at dynamic import boundaries + extract shared modules |
| `manualChunks` | `(id, meta) => string \| null` or `[{name, patterns}]` | — | Rollup-compatible custom splitting. JS API is functional, `zntc.config.json` is record form. [Detailed guide](/zntc/guides/manual-chunks/) |
| `inlineDynamicImports` | `boolean` | `false` | Absorb dynamic import targets into the importer chunk + `__esm` wrap (single-file output) |
| `external` | `string[]` | `[]` | Specifiers to exclude from the bundle. Registered as phantom Modules in the graph |
| `preserveModules` | `boolean` | `false` | Keep original directory structure instead of bundling (Rollup-compatible) |
| `outputExports` | `auto`, `named`, `default`, `none` | `auto` | CJS/UMD entry export form (Rollup `output.exports` compatible) |

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
| `sourcemap` | `boolean` | `false` | Generate sourcemap JSON |
| `sourcemapMode` | `linked`, `external`, `inline` | `linked` | Sourcemap output form. `linked` = external file + `sourceMappingURL` comment |
| `sourcemapDebugIds` | `boolean` | `false` | Insert Sentry-compatible Debug IDs |
| `sourcesContent` | `boolean` | `true` | Include original source in sourcemap |
| `sourceRoot` | `string` | `""` | Sourcemap `sourceRoot` field |

### Define (substitution)

| Option | Type | Default | Description |
|---|---|---|---|
| `define` | `Array<{key, value}>` | `[]` | Identifier substitution. `value` is **raw JSON** — strings include quotes (e.g. `value: "\"1.0.0\""`) |

### Diagnostics / Logging

| Option | Type | Default | Description |
|---|---|---|---|
| `logLevel` | `"silent" \| "error" \| "warning" \| "info" \| "debug" \| "verbose"` | `"warning"` | Filter for the NAPI build result errors/warnings arrays. `"silent"` empties both, `"error"` empties only warnings |
| `logLimit` | `number` | `0` | Max items per errors/warnings array. `0` is unlimited |

The full enum values and detailed semantics are managed in the [Transpile options reference](/zntc/reference/options/) as the single source of truth (Zig `TranspileOptionsDto`).

## Config file shape — common object options

These options are object-shaped with no or limited CLI flags, and are mainly handled in the config file.

### `server` — dev server defaults

Defaults used by `zntc dev` / `zntc --serve`. CLI flags (`--port` / `--host` / `--open`) always win.

```ts
// zntc.config.ts
export default defineConfig({
  server: {
    port: 5173,
    host: true,         // true → 0.0.0.0 (same as Vite)
    strictPort: false,  // true: exit on port conflict instead of trying next port
    open: false,
  },
});
```

| Field | Type | Notes |
| ---- | ---- | ---- |
| `port` | `number` | CLI `--port` override |
| `host` | `string \| boolean` | `true` = `0.0.0.0`. CLI `--host` override |
| `strictPort` | `boolean` | No fallback on conflict |
| `open` | `boolean` | Auto-open browser after start. CLI `--open` override |

### `alias` — Object or Array (Vite-compatible)

`alias` supports two forms:

```ts
// 1. Object form (esbuild-compatible): exact + prefix
defineConfig({ alias: { react: 'preact/compat' } });

// 2. Array form (Vite resolve.alias): RegExp find support
defineConfig({
  alias: [{ find: /^@\/(.*)$/, replacement: './src/$1' }],
});
```

- `zntc.config.ts` / `.js` — both forms usable
- `zntc.config.json` — Object form only (JSON has no RegExp serialization)
- `buildSync` — Array form unsupported (RegExp matching is delegated to host runtime, so async `build()` / `watch()` only)

### `compiler` — per-library first-party transforms

A surface compatible with `@next/swc`'s `compiler`. Accepts styled-components / emotion first-party transform options.

```ts
defineConfig({
  compiler: {
    styledComponents: true,
    emotion: { autoLabel: 'dev-only' },
  },
});
```

For the full option list see the [Babel migration guide](/zntc/guides/babel-migration/).

### Environment variables in `index.html` — EJS tokens

Tokens like `<%= ZNTC_KEY %>` in the `index.html` body are automatically replaced with `.env` values in both `dev` and `build`. This is a separate path from the JS-side `import.meta.env.X` — usable directly inside HTML.

```html
<!DOCTYPE html>
<html>
  <head>
    <title><%= ZNTC_APP_TITLE %></title>
    <meta name="version" content="<%= ZNTC_BUILD_VERSION %>" />
  </head>
  <body><div id="root"></div></body>
</html>
```

```bash
# .env
ZNTC_APP_TITLE=My App
ZNTC_BUILD_VERSION=2026.05
```

**Spec**:

- Token form: `<%= KEY %>` (whitespace around delimiters allowed — `<%=KEY%>` / `<%=   KEY   %>` both OK).
- Key prefix: **`ZNTC_` only**. Even if the JS-side `envPrefixes` allows `VITE_*`, those are not exposed in HTML body — prevents secret leakage.
- Other-prefix keys (`<%= VITE_API_KEY %>`) are **preserved + warning** (the token is exposed verbatim on the site, so it's immediately detectable).
- Missing keys (`<%= ZNTC_UNDEFINED %>`) become **empty string + warning** (same as Vite / CRA).
- Expression evaluation (`<%= mode === 'prod' ? '/' : '/dev/' %>`) is **unsupported** — key-only.

### Functional config `ConfigEnv.command`

When using `defineConfig(({ command, mode, env }) => ...)` in `zntc.config.ts`, `command` can be:

| `command` | Trigger |
| --------- | --------- |
| `"bundle"` | `zntc build` / others (default) |
| `"serve"`  | `zntc dev` / `zntc preview` / `--serve` |
| `"watch"`  | `--watch` |

Unlike Vite (`"build" \| "serve"`), ZNTC separates `"bundle"` and `"watch"`.

## Advanced merge rules

Most options are simply "higher wins", but a few have asymmetric/special behavior users frequently trip over.

### Asymmetric merge of boolean options

A boolean flag like `--minify` can't distinguish "not given" from "given as false" on the CLI. So the following asymmetry applies.

```json
// zntc.config.json
{ "minify": true, "sourcesContent": false }
```

```bash
zntc --bundle entry.ts            # neither --minify nor --sources-content given on CLI
# → minify=true            (default=false, so config's true applies)
# → sourcesContent=false   (default=true, so config's false applies)
```

Rule: **only config values set opposite to the default take effect.**

| Default | config=true | config=false |
|---|---|---|
| `false` | ✅ applied | (ignored — already false) |
| `true` | (ignored — already true) | ✅ applied |

To precisely control both CLI and config, use the `command`/`mode` branch of a functional config.

```ts
defineConfig(({ command, mode }) => ({
  minify: command === 'bundle' && mode === 'production',
}));
```

### `plugins` is concat (unlike other arrays)

```ts
// zntc.config.ts
defineConfig({ plugins: [a, b] });
```

```bash
zntc --bundle --plugin ./c.js --plugin ./d.js entry.ts
# → plugins = [a, b, c, d]   (config + CLI concat)
```

Other array options (`external`, `inject`, `drop`, ...) **use only CLI when CLI is non-empty** (overwrite), whereas `plugins` is merged. Since order affects hook results (see the first-match / chaining policy in the [Plugins guide](/zntc/guides/plugins/)), write registration order deliberately.

### `--tsconfig-raw` direct JSON injection

You can pass tsconfig content directly as a JSON string on the CLI — bypassing both file-based `-p path` and auto-discovery.

```bash
zntc --bundle entry.ts --tsconfig-raw='{"compilerOptions":{"jsx":"preserve"}}'
```

Useful for injecting options dynamically in CI / Docker without creating a tsconfig file. Priority: `--tsconfig-raw` > `-p path` > auto-discovery.

### tsconfig + `zntc.config` + CLI 3-way (`jsx` example)

When the same option is defined in three places, the highest-priority one wins.

```json
// tsconfig.json
{ "compilerOptions": { "jsx": "preserve" } }
```

```ts
// zntc.config.ts
export default defineConfig({ jsx: 'automatic' });
```

```bash
zntc --bundle --jsx=transform App.tsx
# → jsx=transform   (CLI wins)
# → config's automatic and tsconfig's preserve both ignored
```

With only `zntc.config` and no CLI, `automatic` applies; with no `zntc.config` either, tsconfig's `preserve` is the fallback.

## $schema editor setup

### VSCode

If `zntc.config.json` has a `$schema` field it works automatically with **no extra setup**. Autocomplete and hover docs appear right in the JSON file.

### Local schema reference (offline)

To use a local file instead of the online schema:

```bash
# Generate the schema file at the project root
zig build schema
```

(Only usable inside the ZNTC repo. npm package users should use the URL approach.)

## Regenerating the schema

Upgrading the ZNTC version keeps the schema URL the same, but the internal option list may have changed. To force-refresh the JSON cache in VSCode, reopen the workspace or run "JSON: Clear Schema Cache".

Internal ZNTC repo developers run:

```bash
zig build schema
```

to regenerate `documents/public/schemas/transpile-options.schema.json` — must run whenever the `TranspileOptionsDto` struct in `src/transpile.zig` changes.
