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
