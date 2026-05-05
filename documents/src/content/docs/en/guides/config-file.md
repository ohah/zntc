---
title: Config file (zts.config.json)
description: Auto-loaded zts.config.json with editor autocomplete via $schema
---

The ZTS CLI auto-loads `zts.config.json` from the current directory. JSON-schema-aware editors (VSCode / IntelliJ / Zed) give you **autocomplete + type checking** via the `$schema` reference.

## Quick start

```json
{
  "$schema": "https://ohah.github.io/zts/schemas/transpile-options.schema.json",
  "target": "es2022",
  "sourcemap": true,
  "minifySyntax": true,
  "platform": "browser"
}
```

Running `zts input.ts` in the same directory picks up these options automatically.

```bash
zts input.ts                  # uses values from config.json
zts input.ts --quotes=double  # CLI argument overrides config (CLI > config)
```

## Option priority

ZTS merges options in this order (**later wins**):

1. Zig defaults
2. `zts.config.json`
3. `tsconfig.json` (selective: `compilerOptions.target`, etc.)
4. CLI arguments

You can override config values from the CLI but not the other way around. To temporarily disable the config, rename or delete the file.

## Editor setup

### VSCode

Works out of the box — the `$schema` field is enough.

### Local schema (offline)

To use a local schema instead of the online URL (ZTS repo contributors only):

```bash
zig build schema
```

## Supported fields

See the [Transpile Options reference](/zts/en/reference/options/) — the schema covers the same fields as the `TranspileOptions` TS interface.

**Note**: bundler-only options (`external`, `alias`, `define`, etc.) are limited in `zts.config.json`. For complex bundler configs, use `zts.config.ts` (TypeScript config with plugin support).

### Common config-shape options

The following options have no CLI flag (or only a partial one) and are typically expressed as objects in the config file.

#### `server` — dev server defaults

Defaults consumed by `zts dev` / `zts --serve`. CLI flags (`--port` / `--host` / `--open`) always take precedence.

```ts
// zts.config.ts
export default defineConfig({
  server: {
    port: 5173,
    host: true,         // true → 0.0.0.0 (matches Vite)
    strictPort: false,  // true exits on port conflict instead of trying the next port
    open: false,
  },
});
```

| Field | Type | Notes |
| ----- | ---- | ----- |
| `port` | `number` | CLI `--port` overrides |
| `host` | `string \| boolean` | `true` = `0.0.0.0`. CLI `--host` overrides |
| `strictPort` | `boolean` | Disable port-conflict fallback |
| `open` | `boolean` | Open browser on startup. CLI `--open` overrides |

#### `alias` — Object or Array (Vite-compatible)

`alias` accepts two shapes:

```ts
// 1. Object form (esbuild-compatible): exact + prefix matching
defineConfig({ alias: { react: 'preact/compat' } });

// 2. Array form (Vite resolve.alias): RegExp `find` supported
defineConfig({
  alias: [{ find: /^@\/(.*)$/, replacement: './src/$1' }],
});
```

- `zts.config.ts` / `.js` — both forms are supported
- `zts.config.json` — Object form only (JSON cannot serialize `RegExp`)
- `buildSync` — Array form not supported (RegExp matching is delegated to the host runtime, so only async `build()` / `watch()` accept it)

#### `compiler` — library-specific 1st-party transforms

Compatible surface with `@next/swc`'s `compiler` option. Carries `styled-components` / `emotion` 1st-party transform settings.

```ts
defineConfig({
  compiler: {
    styledComponents: true,
    emotion: { autoLabel: 'dev-only' },
  },
});
```

For the full option list, see the [Babel migration guide](/zts/en/guides/babel-migration/).

#### Functional config `ConfigEnv.command`

When using `defineConfig(({ command, mode, env }) => ...)` in `zts.config.ts`, `command` can take:

| `command` | When |
| --------- | ---- |
| `"bundle"` | `zts build` / anything else (default) |
| `"serve"`  | `zts dev` / `zts preview` / `--serve` |
| `"watch"`  | `--watch` |

Unlike Vite (`"build" \| "serve"`), ZTS splits `"bundle"` and `"watch"` separately.

## zts.config.ts vs zts.config.json

| | `zts.config.ts` | `zts.config.json` |
|---|---|---|
| Plugins | ✅ Full support | ❌ |
| Dynamic values | ✅ (functions, imports) | ❌ |
| JSON schema autocomplete | ❌ | ✅ |
| CLI auto-discovery | `bundle`/`serve` only | **All commands** |
| Learning curve | Medium | Low |

**Recommendation**:
- Simple transpile / small projects → `zts.config.json`
- Plugins / dynamic config / bundling → `zts.config.ts`

If both exist, `zts.config.ts` takes precedence on the bundle path.

## Regenerating the schema

When you upgrade ZTS, the URL stays the same but the option list may have changed. In VSCode, reopen the workspace or run "JSON: Clear Schema Cache" to force a refresh.

ZTS repo contributors: after editing `src/transpile.zig`'s `TranspileOptionsDto`, run:

```bash
zig build schema
```

This regenerates `documents/public/schemas/transpile-options.schema.json`.
