---
title: Options Matrix
description: Cross-reference ZNTC option exposure across CLI, JS API, config, and schema.
---

ZNTC exposes options through four public surfaces. Use this matrix to catch documentation and implementation drift when adding or checking a feature.

- **CLI**: the `zntc` command and `packages/core/bin/cli-flags.mjs`.
- **JS API**: `@zntc/core` `transpile()` / `build()` / `watch()` types.
- **Config**: user config loaded from `zntc.config.*` / `zntc.workspace.*`.
- **Schema**: transpile-only JSON schema. Bundler-only fields are intentionally excluded.

## Surface Matrix

| Feature group | CLI | JS API | Config | Schema | Notes |
| ------------- | --- | ------ | ------ | ------ | ----- |
| I/O (`outfile`, `outdir`, `outbase`, `outExtension`) | ✅ | ✅ | ✅ | ❌ | `outdir` and naming patterns are bundler output options |
| Module format (`format`, `platform`) | ✅ | ✅ | ✅ | ✅ | `react-native` also enables the RN preset |
| ES/runtime targets (`target`, `browserslist`) | ✅ | ✅ | ✅ | ✅ | there's also a `--browserslist` CLI flag (alternative to `--target`); when set it takes precedence over `target` |
| Runtime polyfills (`runtimePolyfills`, `runtimeTarget`, `coreJs`) | ✅ | ✅ | ✅ | ❌ | core-js injection from graph usage |
| JSX / TS / Flow transforms | ✅ | ✅ | ✅ | ✅ | selected `tsconfig` fields are used as fallback values |
| define/drop/inject/pure | ✅ | ✅ | ✅ | partial | `dropLabels`, `pure`, and `inject` are mostly bundler-facing |
| Granular minify | ✅ | ✅ | ✅ | ✅ | property mangle options are intentionally unsupported |
| Source maps (`sourcemapMode`, `sourcesContent`, `sourceRoot`) | ✅ | ✅ | ✅ | ✅ | RN sourcemap output flags are covered by the RN CLI docs |
| Resolver (`external`, `alias`, `fallback`, `conditions`) | ✅ | ✅ | ✅ | ❌ | array/RegExp alias requires async `build()` / `watch()` |
| Loader / asset names / public path | ✅ | ✅ | ✅ | ❌ | separate from app-mode HTML/CSS asset rewriting |
| Code splitting / preserve modules | ✅ | ✅ | ✅ | ❌ | `splitting` requires `outdir` |
| `manualChunks` | ❌ | ✅ | ✅ | ❌ | function form requires `zntc.config.{ts,js}` or JS API |
| `metafile` / `analyze` | ✅ | ✅ | partial | ❌ | `metafile` is config-capable; `analyze` is CLI/API-oriented. Inspect `meta.json` at [/analyze/](/zntc/analyze/) |
| Watch / serve / dev server | ✅ | ✅ | ✅ | ❌ | `watch()` exposes rich events and lazy sourcemap APIs |
| App builder (`dev`, `build`, `preview`) | ✅ | partial | ✅ | ❌ | HTML/env/public/CSS pipeline requires `@zntc/web` |
| Plugin hooks | ✅ (`--plugin`) | ✅ | ✅ | ❌ | JS plugins are not supported by `buildSync()` |
| Diagnostics / profile / debug | ✅ | ✅ | partial | ❌ | profile is exposed through CLI and `configureProfile()` |
| Workspace | ✅ | ✅ | ✅ | ❌ | `zntc.workspace.*` manages multiple entries |

## Sync API Limits

`buildSync()` cannot run JS plugins, array/RegExp aliases, or host-RegExp hooks because the native worker would need to wait on JS callbacks. Use async `build()` or `watch()` for those features.

## Update Checklist

When adding a new option:

1. Add the field to the public `@zntc/core` type when it is part of the JS API.
2. If the feature should be available from CLI, update `cli-flags.mjs`, `zntc.mjs`, help text, and parse tests.
3. If config should accept it, update `KNOWN_CONFIG_KEYS`, typo suggestions, and config merge tests.
4. If it is transpile-only, regenerate the schema with `zig build schema` and update `reference/options`.
5. If only some surfaces support it, document the limitation here and in the relevant guide.

## See Also

- [CLI Reference](/zntc/en/reference/cli/)
- [NAPI / JS API](/zntc/en/reference/napi/)
- [Transpile Options](/zntc/en/reference/options/)
- [Config File](/zntc/en/guides/config-file/)
