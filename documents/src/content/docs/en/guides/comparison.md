---
title: Tool Comparison
description: Compare ZTS against Rolldown, esbuild, SWC, Rspack, and Vite.
---

ZTS focuses on providing a **TypeScript/Flow transpiler, library/app bundler, and dev server** from one binary/package. It is not trying to clone the entire Vite ecosystem or webpack loader/plugin universe.

## Status Terms

| Term | Meaning |
| ---- | ------- |
| Supported | Public surface is documented and covered by regression tests |
| Partial | The main path works, but some options, hooks, formats, or edge cases are limited |
| Policy difference | ZTS intentionally chooses different semantics |
| Unsupported | No current public surface |

## Bundling / Transpilation

| Area | ZTS | Rolldown | esbuild | SWC | Rspack/Vite |
| ---- | --- | -------- | ------- | --- | ----------- |
| TS/JSX/Flow single-file transform | Supported | Partial | TS/JSX, no Flow | Supported | loader/plugin layer |
| Library bundling | Supported | Supported | Supported | spack/swcpack planned to be dropped in v2 | Rspack supported, Vite uses Rollup/Rolldown |
| App builder (`index.html`, env, public) | Supported | Recommended through Vite | serve/build primitives | Unsupported | Vite/Rspack strength |
| Code splitting | Supported | Supported | Supported | Limited | Supported |
| Manual chunks | Supported (`config`/API) | Supported | Unsupported | Unsupported | Supported |
| Runtime core-js polyfills | Supported | plugin/user-managed | Unsupported | `env`-oriented | Rspack/SWC loader layer |
| React Native preset | Supported | Unsupported | Unsupported | usable as transformer | Metro/Rspack separate |
| WASM playground | Supported | Wasm build available | browser build available | wasm packages | varies |

## Plugin/API Compatibility

| Area | ZTS status | Notes |
| ---- | ---------- | ----- |
| esbuild-style `setup(build)` | Partial | Focused on `onResolve`, `onLoad`, `onTransform`, `onResolveContext`, `onAstFunction` |
| Rollup/Vite-style `resolveId` / `load` / `transform` | Supported | Use the `vitePlugin()` wrapper |
| Output hooks (`renderChunk`, `generateBundle`) | Partial | General post-processing works. Not every Rollup hook is implemented |
| Lifecycle (`buildStart`, `buildEnd`, `closeBundle`) | Supported | Runs on initial build and every rebuild in `watch()` |
| `this.resolve()` / `this.emitFile()` | Unsupported | Requires a separate graph mutation surface |
| `buildSync()` + JS plugins | Unsupported | Conflicts with the native worker waiting on JS callbacks |
| Plugin hook filter | Partial | esbuild-style filters are supported; not identical to Rolldown object-hook filters |

Rolldown has a stronger Rollup-compatible plugin API and lifecycle reference. ZTS accepts common hooks through `vitePlugin()`, but advanced Rollup context APIs are still narrow.

## CLI and Analysis

| Area | ZTS | Comparison |
| ---- | --- | ---------- |
| CLI/JS API/config options | Mostly covered | See [Options Matrix](/zts/en/reference/options-matrix/) |
| `metafile` JSON | Supported | esbuild-compatible basic format |
| Interactive bundle analyzer | Supported | Upload `meta.json` at [/analyze/](/zts/analyze/) |
| `--analyze` tree output | Partial | Currently JSON-oriented. CLI tree format is follow-up work |
| Profile/benchmark | Supported | `--profile*`, `zts bench`, JS `benchmark()` |
| Diagnostic docs URL | Supported | Linked to `ZTSxxxx` error-code docs |

## App Features vs Vite/Rspack

| Feature | ZTS | Notes |
| ------- | --- | ----- |
| `zts dev` / `zts build` / `zts preview` | Supported | dev/build/preview semantics are kept aligned |
| HTML entry rewrite | Supported | uses `<script type="module" src>` as entry |
| `.env*` / `import.meta.env.*` | Supported | `--env-dir`, `--env-prefix` |
| `public/` copy | Supported | `--public-dir` |
| CSS Modules | Supported | app mode |
| PostCSS / Tailwind v4 | Supported | through `@tailwindcss/postcss` |
| Sass/SCSS | Supported | optional `sass` dependency required |
| Less/Stylus | Unsupported | precompile or use plugin-level handling |
| CSS-only HMR | Supported | includes PostCSS dependency watch |
| Error overlay | Supported | build/runtime overlay with sourcemap remapping |
| `import.meta.glob` | Unsupported | candidate Vite-compatible surface |
| SSR build | Unsupported | outside the current app-builder boundary |
| Dev proxy | Supported | `--proxy /api=http://...` |

## Intentional Policy Differences

| Item | ZTS policy |
| ---- | ---------- |
| Import attributes loader override | `with { type }` is pass-through metadata. Loader selection is extension/loader-option based |
| Physical device runtime target | physical names such as `iPhone 8` are rejected. Use Browserslist queries |
| Auto node polyfill bundle | not provided. Use explicit `fallback`, `alias`, or plugins |
| Property mangle | lower priority due to public API stability and debugging cost |
| SSR | unlike Vite/Rspack, not in the current app-builder core boundary |

## Official References

- [esbuild API](https://esbuild.github.io/api/)
- [esbuild Bundle Size Analyzer](https://esbuild.github.io/analyze/)
- [Rolldown Getting Started](https://rolldown.rs/guide/getting-started)
- [Rolldown Plugin API](https://rolldown.rs/apis/plugin-api)
- [SWC Getting Started](https://swc.rs/docs/getting-started)
- [SWC Bundling (swcpack)](https://swc.rs/docs/usage/bundling)
- [SWC Plugin Guide](https://swc.rs/docs/plugin/ecmascript/getting-started)
