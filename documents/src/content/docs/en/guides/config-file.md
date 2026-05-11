---
title: Config file (zntc.config.json)
description: Auto-loaded zntc.config.json with editor autocomplete via $schema
---

The ZNTC CLI auto-loads `zntc.config.json` from the current directory. JSON-schema-aware editors (VSCode / IntelliJ / Zed) give you **autocomplete + type checking** via the `$schema` reference.

## Quick start

```json
{
  "$schema": "https://ohah.github.io/zntc/schemas/transpile-options.schema.json",
  "target": "es2022",
  "sourcemap": true,
  "minifySyntax": true,
  "platform": "browser"
}
```

Running `zntc input.ts` in the same directory picks up these options automatically.

```bash
zntc input.ts                  # uses values from config.json
zntc input.ts --quotes=double  # CLI argument overrides config (CLI > config)
```

## Option priority

ZNTC merges options in this order (**later wins**):

1. Zig defaults
2. `zntc.config.json`
3. `tsconfig.json` (selective: `compilerOptions.target`, etc.)
4. CLI arguments

You can override config values from the CLI but not the other way around. To temporarily disable the config, rename or delete the file.

## Advanced merge rules

Most options follow simple "higher wins", but a few have asymmetric/special behaviors that bite users.

### Boolean options merge asymmetrically

A boolean flag like `--minify` cannot distinguish between "not passed" and "passed as false". Hence the asymmetry below.

```json
// zntc.config.json
{ "minify": true, "sourcesContent": false }
```

```bash
zntc --bundle entry.ts            # CLI passes neither --minify nor --sources-content
# → minify=true            (default=false, so config's true applies)
# → sourcesContent=false   (default=true, so config's false applies)
```

Rule: **only config values opposite to the default actually take effect.**

| Default | config=true | config=false |
|---|---|---|
| `false` | ✅ applied | (no-op — already false) |
| `true` | (no-op — already true) | ✅ applied |

For precise control across CLI and config, use the functional config form's `command`/`mode` branching.

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

Other array options (`external`, `inject`, `drop`, ...) follow "**CLI replaces config when non-empty**", but `plugins` is concatenated. Since order affects hook results (see first-match / chaining policy in the [Plugins guide](/zntc/en/guides/plugins/)), be intentional with registration order.

### `--tsconfig-raw` for inline JSON

You can pass tsconfig contents as a raw JSON string on the CLI — bypassing both `-p path` and auto-discovery.

```bash
zntc --bundle entry.ts --tsconfig-raw='{"compilerOptions":{"jsx":"preserve"}}'
```

Useful in CI / Docker where you'd rather not write a tsconfig file just to flip an option. Priority: `--tsconfig-raw` > `-p path` > auto-discovery.

### tsconfig + `zntc.config` + CLI 3-way (e.g. `jsx`)

If the same option is defined in all three, priority resolves "highest wins".

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
# → config's automatic and tsconfig's preserve are both ignored
```

If only `zntc.config` is present (no CLI flag), `automatic` applies. If even that is missing, tsconfig's `preserve` is the fallback.

## Editor setup

### VSCode

Works out of the box — the `$schema` field is enough.

### Local schema (offline)

To use a local schema instead of the online URL (ZNTC repo contributors only):

```bash
zig build schema
```

## Supported fields

See the [Transpile Options reference](/zntc/en/reference/options/) — the schema covers the same fields as the `TranspileOptions` TS interface.

**Note**: bundler-only options (`external`, `alias`, `define`, etc.) are limited in `zntc.config.json`. For complex bundler configs, use `zntc.config.ts` (TypeScript config with plugin support).

### Common config-shape options

The following options have no CLI flag (or only a partial one) and are typically expressed as objects in the config file.

#### `server` — dev server defaults

Defaults consumed by `zntc dev` / `zntc --serve`. CLI flags (`--port` / `--host` / `--open`) always take precedence.

```ts
// zntc.config.ts
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

- `zntc.config.ts` / `.js` — both forms are supported
- `zntc.config.json` — Object form only (JSON cannot serialize `RegExp`)
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

For the full option list, see the [Babel migration guide](/zntc/en/guides/babel-migration/).

#### Env tokens inside `index.html` (EJS style)

Place `<%= ZNTC_KEY %>` tokens directly inside `index.html`. They get substituted with `.env` values during both `dev` and `build` — completely independent of the JS-side `import.meta.env.X` mechanism.

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

- Token form: `<%= KEY %>` (whitespace inside delimiters allowed — `<%=KEY%>` / `<%=   KEY   %>` all work).
- Prefix is restricted to **`ZNTC_`** only. Even if the JS side `envPrefixes` allows `VITE_*`, those keys are not exposed in HTML — prevents secret leakage.
- Other prefix tokens (`<%= VITE_API_KEY %>`) are **left as-is plus warning** (the raw token is visible on the page, making the mistake easy to spot).
- Missing keys (`<%= ZNTC_UNDEFINED %>`) are **replaced with an empty string plus warning** (same as Vite / CRA).
- Expression evaluation (`<%= mode === 'prod' ? '/' : '/dev/' %>`) is **not supported** — key-only.

#### Functional config `ConfigEnv.command`

When using `defineConfig(({ command, mode, env }) => ...)` in `zntc.config.ts`, `command` can take:

| `command` | When |
| --------- | ---- |
| `"bundle"` | `zntc build` / anything else (default) |
| `"serve"`  | `zntc dev` / `zntc preview` / `--serve` |
| `"watch"`  | `--watch` |

Unlike Vite (`"build" \| "serve"`), ZNTC splits `"bundle"` and `"watch"` separately.

## zntc.config.ts vs zntc.config.json

| | `zntc.config.ts` | `zntc.config.json` |
|---|---|---|
| Plugins | ✅ Full support | ❌ |
| Dynamic values | ✅ (functions, imports) | ❌ |
| JSON schema autocomplete | ❌ | ✅ |
| CLI auto-discovery | `bundle`/`serve` only | **All commands** |
| Learning curve | Medium | Low |

**Recommendation**:
- Simple transpile / small projects → `zntc.config.json`
- Plugins / dynamic config / bundling → `zntc.config.ts`

If both exist, `zntc.config.ts` takes precedence on the bundle path.

## Regenerating the schema

When you upgrade ZNTC, the URL stays the same but the option list may have changed. In VSCode, reopen the workspace or run "JSON: Clear Schema Cache" to force a refresh.

ZNTC repo contributors: after editing `src/transpile.zig`'s `TranspileOptionsDto`, run:

```bash
zig build schema
```

This regenerates `documents/public/schemas/transpile-options.schema.json`.
