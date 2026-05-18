---
title: Roadmap
description: Planned features and current limitations of ZNTC, from a user perspective.
---

This page covers only features as you encounter them. Internal phases, progress percentages, and implementation details live in the GitHub repository.

## Planned

### Bundler

#### Public WASM AST API

Expose the ZNTC AST as a WASM module so it can be consumed outside Node and the browser. The WASM build that today powers the Playground and Metafile Analyze pages will be stabilized and published as a user-facing API. Depends on AST schema stabilization.

#### External Zig plugins

Zig plugins currently exist only for built-in transforms (worklet, Fast Refresh). User-authored Zig modules will be loadable as plugins, statically linked at build time and called in-process. No JS↔native serialization overhead, but the Zig compiler must be available at build time.

#### Rollup plugin context API extension (ESTree AST)

The `vitePlugin()` adapter supports the main Rollup hooks (`resolveId` · `load` · `transform` · `renderChunk` · `generateBundle`) and most fields of `getModuleInfo()`. Remaining items are parts of the plugin context API (`this.parse()` · `this.resolve()` · `this.emitFile()` · `ModuleInfo.meta`) and `ModuleInfo.ast` — an ESTree adapter that exposes each module's **ESTree-compatible AST** to plugins. It depends on converting ZNTC's internal AST to the ESTree shape.

#### Per-chunk CSS splitting

`import './style.css'` auto-emit, `@import` inlining, and Lightning CSS minification already work. Splitting CSS per output chunk during code-splitting is deferred. (`.module.css` class-name hashing / scoping is already built in for app mode — see [Plugin Recipes / CSS Modules](/zntc/en/guides/plugin-recipes/#css-modules).)

#### Refined dead-code elimination (innerGraph)

Straight-line dead stores on local variables are eliminated. Dead-store analysis across `if` / `for` / `try` control flow is in progress.

#### lazyBarrel refinement

Barrel re-exports (`export * from`, `export { X } from`, `import * as X; export { X }`) skip compilation for pure / local / namespace patterns. Wrapper barrels that mutate imported bindings (e.g. lodash-es's `lodash.default.js`) currently disable lazy mode entirely as a conservative fallback. Refining this to apply lazy mode to non-mutating parts only is pending. See [Tree-shaking](/zntc/en/guides/tree-shaking/) for current limits.

#### mangleProps

Cross-module property mangling, esbuild-style. Not implemented yet.

#### Improved module concatenation

Scope-hoisting at the level of rspack / rolldown.

#### Persistent disk cache

Only an in-memory parse cache + resolve cache lives across rebuilds within a watch / serve session. A persistent on-disk cache to speed up cold rebuilds is on the backlog.

#### Lazy compilation

On-demand module compilation for faster dev startup. Not implemented yet.

### Transpiler

#### `.d.ts` emission (isolatedDeclarations)

Currently delegated to `tsc`. Native isolatedDeclarations-based emission is planned.

### Dev server

#### Converging to a single Zig dev server

Two dev servers coexist today:

- **Zig native** (`zntc serve` / `zntc dev`) — standalone, no Node required.
- **JS** (`zntc dev <root>` app mode) — used to delegate to JS-ecosystem plugins (postcss / sass).

The long-term goal is to vendor BoringSSL, abstract the plugin host, and converge on the Zig server (similar to Bun's model). This sits behind the stability / CSS / ecosystem milestones.

### Ecosystem

#### Plugin examples

Reference plugins for common cases: PostCSS, Tailwind, SVG, YAML.

#### Migration guides

Expand the esbuild → ZNTC and Vite → ZNTC mapping tables. Some material already lives under [Migration](/zntc/en/guides/migration/).

#### Framework integration (Next.js · Remix · SvelteKit · Expo)

Each of these ships its own bundler tightly coupled to the framework, so an adapter ends up being a partial reimplementation of the framework's compiler. This is the last milestone.

- **Expo**: A meta-framework on top of React Native. Plain React Native apps already build via `--platform=react-native`, but integrating with Expo Router's filesystem-routing manifest, the `expo prebuild` step, and the EAS build pipeline requires a dedicated adapter.

#### Vite-compatible mode

Read `vite.config.js` directly for zero-cost migration. Long-term goal.

## Current limitations

### Cannot build Next.js / Remix directly

These frameworks bake the bundler into the framework itself — RSC payload serialization, filesystem-routing manifests, loader/action server-client separation. A general-purpose bundler cannot stand in for them. Plain React / Vue / Svelte SPAs and React Native (Metro-compatible output) are supported.

### `.module.css` auto-transform in core `--bundle` mode

App mode (`zntc dev` / `zntc build`) supports `.module.css` class-name hashing / scoping out of the box — see [Plugin Recipes / CSS Modules](/zntc/en/guides/plugin-recipes/#css-modules). Core `--bundle` mode does not auto-transform `.module.css`; go through the Vite adapter or a user plugin (PostCSS Modules / Lightning CSS Modules) instead.

### Per-chunk CSS splitting

CSS is emitted as a single artifact even when JS is code-split. Per-chunk CSS is deferred.

### Persistent disk cache · Lazy compilation · mangleProps

See the corresponding "Planned" items.

### Control-flow-aware dead stores

Dead assignments inside `if` / `for` / `try` may be preserved. Only straight-line dead stores are eliminated today.

### Wrapper-barrel mutation pattern

When a barrel module mutates an imported binding (some libraries do this — e.g. lodash-es), the lazy-barrel optimization is disabled wholesale for that module. Correctness is preserved, but the bundle can be larger than necessary.

### Large `tsconfig` `paths` (hundreds of entries)

Only the first resolve walks the array linearly; subsequent resolves hit the resolver cache. No measurable impact at normal project sizes.

### Public WASM AST API

`@zntc/wasm` exposes `transpile()`, `build()`, `buildChunks()`, and `VirtualFileSystem` for user `import`; see the WASM section of [Installation](/zntc/en/guides/installation/) for the usage surface. Direct module-level access to the ESTree-compatible AST from plugins is the remaining gap — see the "Planned / Public WASM AST API" entry above. AST schema stabilization is the prerequisite.
