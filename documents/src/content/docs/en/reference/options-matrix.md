---
title: Options Matrix
description: Cross-reference ZTS option exposure across CLI, JS API, config, and schema.
---

ZTS exposes options through four public surfaces. Use this matrix to catch documentation and implementation drift when adding or checking a feature.

- **CLI**: the `zts` command and `packages/core/bin/cli-flags.mjs`.
- **JS API**: `@zts/core` `transpile()` / `build()` / `watch()` types.
- **Config**: user config loaded from `zts.config.*` / `zts.workspace.*`.
- **Schema**: transpile-only JSON schema. Bundler-only fields are intentionally excluded.

## Surface Matrix

| Feature group | CLI | JS API | Config | Schema | Notes |
| ------------- | --- | ------ | ------ | ------ | ----- |
| I/O (`outfile`, `outdir`, `outbase`, `outExtension`) | ✅ | ✅ | ✅ | ❌ | `outdir` and naming patterns are bundler output options |
| Module format (`format`, `platform`) | ✅ | ✅ | ✅ | ✅ | `react-native` also enables the RN preset |
| ES/runtime targets (`target`, `browserslist`) | ✅ | ✅ | ✅ | ✅ | `browserslist` is config/API-only and takes precedence over `target` |
| Runtime polyfills (`runtimePolyfills`, `runtimeTarget`, `coreJs`) | ✅ | ✅ | ✅ | ❌ | core-js injection from graph usage |
| JSX / TS / Flow transforms | ✅ | ✅ | ✅ | ✅ | selected `tsconfig` fields are used as fallback values |
| define/drop/inject/pure | ✅ | ✅ | ✅ | partial | `dropLabels`, `pure`, and `inject` are mostly bundler-facing |
| Granular minify | ✅ | ✅ | ✅ | ✅ | property mangle options are intentionally unsupported |
| Source maps (`sourcemapMode`, `sourcesContent`, `sourceRoot`) | ✅ | ✅ | ✅ | ✅ | RN sourcemap output flags are covered by the RN CLI docs |
| Resolver (`external`, `alias`, `fallback`, `conditions`) | ✅ | ✅ | ✅ | ❌ | array/RegExp alias requires async `build()` / `watch()` |
| Loader / asset names / public path | ✅ | ✅ | ✅ | ❌ | separate from app-mode HTML/CSS asset rewriting |
| Code splitting / preserve modules | ✅ | ✅ | ✅ | ❌ | `splitting` requires `outdir` |
| `manualChunks` | ❌ | ✅ | ✅ | ❌ | function form requires `zts.config.{ts,js}` or JS API |
| `metafile` / `analyze` | ✅ | ✅ | partial | ❌ | `metafile` is config-capable; `analyze` is CLI/API-oriented. Inspect `meta.json` at [/analyze/](/zts/analyze/) |
| Watch / serve / dev server | ✅ | ✅ | ✅ | ❌ | `watch()` exposes rich events and lazy sourcemap APIs |
| App builder (`dev`, `build`, `preview`) | ✅ | partial | ✅ | ❌ | HTML/env/public/CSS pipeline requires `@zts/web` |
| Plugin hooks | ✅ (`--plugin`) | ✅ | ✅ | ❌ | JS plugins are not supported by `buildSync()` |
| Diagnostics / profile / debug | ✅ | ✅ | partial | ❌ | profile is exposed through CLI and `configureProfile()` |
| Workspace | ✅ | ✅ | ✅ | ❌ | `zts.workspace.*` manages multiple entries |

## Sync API Limits

`buildSync()` cannot run JS plugins, array/RegExp aliases, or host-RegExp hooks because the native worker would need to wait on JS callbacks. Use async `build()` or `watch()` for those features.

## Update Checklist

When adding a new option:

1. Add the field to the public `@zts/core` type when it is part of the JS API.
2. If the feature should be available from CLI, update `cli-flags.mjs`, `zts.mjs`, help text, and parse tests.
3. If config should accept it, update `KNOWN_CONFIG_KEYS`, typo suggestions, and config merge tests.
4. If it is transpile-only, regenerate the schema with `zig build schema` and update `reference/options`.
5. If only some surfaces support it, document the limitation here and in the relevant guide.

## See Also

- [CLI Reference](/zts/en/reference/cli/)
- [NAPI / JS API](/zts/en/reference/napi/)
- [Transpile Options](/zts/en/reference/options/)
- [Config File](/zts/en/guides/config-file/)
