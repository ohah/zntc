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

> **Note**: This schema describes the **internal JSON payload** that WASM/NAPI forwards to the Zig engine. A user-friendly `zts.config.json` loader will land in a later PR. The current TS API (`TranspileOptions` in `packages/shared`) accepts camelCase + kebab-case enums (`"react-native"`); the schema enums use the Zig-native form (`"react_native"`).

## Options

### Target / downlevel

| Option | Type | Default | Description |
|---|---|---|---|
| `target` | `es5`, `es2015`–`es2025`, `esnext` | `esnext` | ES downlevel target. When set, features introduced after the target version are auto-lowered |
| `unsupported` | `integer` (u32) | `0` | Direct `UnsupportedFeatures` bitmask. Used to inject browserslist-derived feature sets — takes precedence over `target` |

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
| `sourcemapDebugIds` | `boolean` | `false` | Sentry-compatible Debug ID |
| `sourcesContent` | `boolean` | `true` | Include original source in sourcemap |
| `sourceRoot` | `string` | `""` | Sourcemap `sourceRoot` field |

### Define

| Option | Type | Default | Description |
|---|---|---|---|
| `define` | `Array<{key, value}>` | `[]` | Identifier substitution. `value` is **raw JSON** — strings must be quoted (e.g., `value: "\"1.0.0\""`) |

## Relation to the TS API

When calling the transpiler programmatically, use the `TranspileOptions` interface from `@zts/core` / `@zts/wasm` — it accepts camelCase + kebab-case enums:

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
