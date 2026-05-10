---
title: Bundler Architecture & How It Works
description: The six stages of the ZNTC bundler pipeline plus the runtime behavior worth knowing — module resolution, execution order, scope hoisting, CJS/ESM interop, code splitting.
---

This guide explains what the ZNTC bundler does between input and output, and which stage is responsible for behaviors you might encounter in your code.

For CLI options see [Bundling](/zntc/en/guides/bundling/); for tree-shaking specifics see [Tree-shaking](/zntc/en/guides/tree-shaking/). This page sits on top of those and answers "why does it work this way?"

## The six stages

```
Entry Points
  → Resolver        (specifier → absolute file path)
  → Module Graph    (parallel BFS parse + DFS execution order)
  → Linker          (scope hoisting, name conflict resolution)
  → Tree-shaker     (drop unused exports/statements)
  → Chunker         (split dynamic imports into chunks)
  → Emitter         (per-module transform + codegen)
  → Output (bundle.js + chunks + .map)
```

Each stage has a **single direction of dependency** — the resolver knows nothing about the graph, the linker knows nothing about the resolver. The output of one becomes the input of the next, and almost every observable behavior in your code is decided by exactly one of these stages.

| Stage | Input | Output | What you might notice |
|---|---|---|---|
| Resolver | import path | absolute file path | "Module not found" errors, alias/fallback behavior |
| Graph | entry points | modules + dependencies + execution order | circular reference warnings, ESM side-effect order |
| Linker | modules + symbols | global symbol table | variables renamed to `Foo$1` |
| Tree-shaker | linked graph | reachability marks | "why is this code still in my bundle?" |
| Chunker | marked graph | chunk list | `chunks/abc.js`, runtime loader |
| Emitter | chunks | JS + sourcemap | final output, line/column mapping |

## 1. Module resolution

Decides which file a specifier like `import './foo'` refers to. Filesystem only — no parser/AST involved.

### Resolution priority

1. **alias** — `defineConfig({ alias: { ... } })` or `--alias:foo=bar` is applied **before** any other resolution. Always.
2. **tsconfig paths** — `compilerOptions.paths` from `tsconfig.json`.
3. **package.json `exports`** — conditional matching. Use `--conditions` to enable arbitrary conditions.
4. **`main-fields` order** — defaults to `module → main` (browser target prepends `browser`, RN target prepends `react-native`).
5. **Auto-extensions** — tried in `--resolve-extensions` order (`.tsx, .ts, .jsx, .js, ...`).
6. **`fallback`** — applied **only** when everything above fails. Compatible with webpack `resolve.fallback` / Metro `extraNodeModules`.

### Per-platform behavior

| `--platform` | Automatic |
|---|---|
| `browser` (default) | Node built-ins (`fs`, `path`, ...) → empty modules, `process.env.NODE_ENV` → `"production"` define |
| `node` | Node built-ins + `node:` subpaths auto-external |
| `react-native` | `.native.*` / `.ios.*` / `.android.*` extensions tried automatically, `react-native` prepended to `main-fields`, Flow auto-enabled, Hermes target forced |

### Conditional exports

```jsonc
{
  "exports": {
    ".": {
      "source": "./src/index.ts",
      "import": "./dist/index.mjs",
      "require": "./dist/index.cjs",
      "default": "./dist/index.js"
    }
  }
}
```

- Pass `--conditions=source` to inline monorepo internal packages directly from src without rebuilding `dist`.
- `--platform=browser` automatically adds the `browser` condition; `--platform=node` adds `node`.

## 2. Module graph and execution order

Starting from the entry points, ZNTC parses dependencies in parallel via BFS. When parsing finishes, it walks the graph in DFS post-order to assign `exec_index`. That index is the order modules are emitted into the final bundle, and the order their ESM side effects run.

### Static ESM imports preserve order

```ts
// entry.ts
import './a';   // top-level of `a` runs
import './b';   // top-level of `b` runs
```

Even after scope hoisting fuses everything into one file, **`a`'s top-level code runs before `b`'s.** This matches the ESM spec and is what makes side-effect modules (polyfills, CSS injection, …) work correctly.

### Circular references

```ts
// a.ts
import { B } from './b';
export const A = () => B();

// b.ts
import { A } from './a';
export const B = () => A();
```

ZNTC treats cycles as a **warning, not an error**, and packs them into the same chunk. The cycle's entry module runs first, and by the time functions are actually called both sides are initialized (matching Node.js ESM behavior). One caveat: **calling something inside the cycle at top level** can still trip TDZ.

### Dynamic imports

```ts
const mod = await import('./heavy');
```

Dynamic imports are tracked as separate dependencies. With `--splitting` they become standalone chunks; without splitting they get inlined into the same bundle.

### Top-level await

```ts
// data.ts
export const data = await fetch('/data.json').then(r => r.json());
```

A module with top-level await **must be evaluated dynamically and cannot be statically hoisted.** Every module that imports it is automatically promoted to async evaluation — be aware that this can propagate further than you expect.

## 3. Scope hoisting (Linker)

Fusing many modules into one file causes name collisions. ZNTC renames automatically.

### Same-name collisions

```ts
// a.ts
const value = 1;
export const A = value;

// b.ts
const value = 2;
export const B = value;

// entry.ts
import { A } from './a';
import { B } from './b';
```

Bundle output:

```js
// a.ts
const value = 1;
const A = value;
// b.ts
const value$1 = 2;       // automatic suffix
const B = value$1;
```

That's why you see `$1`, `$2` suffixes. Original names are preserved in the sourcemap.

### Global protection

User variables that collide with `window`, `document`, `console`, `Math`, etc., are renamed automatically to prevent TDZ or shadowing accidents.

### `default` handling

```ts
// component.ts
export default function Component() { ... }

// entry.ts
import Component from './component';
```

`default` isn't a usable identifier in the hoisted output, so default exports are renamed to a module-derived identifier (e.g. `component_default`).

### Debugging tips

- Build with `sourcemap: true` — devtools shows the original variable names.
- `--metafile=meta.json` + the [Metafile analyzer](/zntc/analyze/) visualizes which module went into which chunk and where.

## 4. CJS ↔ ESM Interop

This stage decides what happens when CommonJS imports ESM, or vice versa.

### When `require()` is converted to import

Importing a CJS module from ESM picks one of two modes:

| Importer kind | Mode | Behavior |
|---|---|---|
| `.mjs` / `.mts` / `package.json` `"type": "module"` | **Node mode** | `__toESM(require(), 1)` — matches Node.js native behavior |
| Everything else (`.js` / `.ts` / regular import) | **Babel mode** | `__toESM(require())` — honors `__esModule`, extracts default |

### `default` import vs namespace import

```ts
// react.ts (CJS, exports.default = ..., module.exports.useState = ...)
import React from 'react';        // default
import * as ReactNs from 'react'; // namespace
```

| Form | Result for a CJS module |
|---|---|
| `import X from 'cjs-mod'` | `module.exports.default` if `__esModule` is true, else `module.exports` itself |
| `import * as X from 'cjs-mod'` | A namespace object wrapping every enumerable property of `module.exports` |
| `import { x } from 'cjs-mod'` | `module.exports.x` — only when statically provable (see below) |

For CJS named imports to work, ZNTC must **statically prove** the export. Supported patterns:

- `exports.foo = ...`
- `module.exports = { foo, bar }`
- `Object.defineProperty(exports, 'foo', { value })` / `{ get }`

Conservatively preserved (not statically provable):

- `exports[k] = ...` (dynamic key)
- `if (cond) exports.foo = ...` (runtime branch)
- Dynamic getter side effects

### `export *` and default

```ts
// re-export.ts
export * from './source';
```

Per ESM spec (15.2.3.5) `export *` **does not include default**. To re-export both:

```ts
export { default } from './source';
export * from './source';
```

### Namespace barrel re-export

```ts
// barrel.ts
import * as utils from './utils';
export { utils };
```

This pattern materializes the namespace object inline — meaning every export of `utils` is treated as used and tree-shaking can no longer prune them. Prefer explicit re-exports when possible:

```ts
export { foo, bar } from './utils';
```

## 5. Code splitting (Chunker)

When `--splitting` is on and a dynamic import is encountered, ZNTC partitions the module graph into chunks.

### Split rules

1. **Dynamic import target → its own chunk**
   ```ts
   const mod = await import('./pages/about');
   // → chunks/about-XXXXXX.js
   ```
2. **Common modules auto-extracted** — modules shared by multiple entry points get their own chunk (the "vendor chunk" effect).
3. **Cycles stay in one chunk** — splitting a cycle would break ESM evaluation order, so they're forced together.

### Runtime loader

When chunks are split, ZNTC emits a tiny ESM-based loader as the entry chunk's prelude. No additional runtime dependencies (esbuild/Rolldown style).

### Filename patterns

```bash
zntc --bundle entry.ts --splitting --outdir dist/ \
  --entry-names="[name]-[hash]" \
  --chunk-names="chunks/[name]-[hash]" \
  --asset-names="assets/[name]-[hash]"
```

- `[name]` — module basename (e.g. `about`)
- `[hash]` — content hash (cache busting)
- `[ext]` — extension

## 6. Emitter

The emitter places module bodies in `exec_index` order per chunk, running each through transformer + codegen.

### Output shape per format

| `--format` | Output |
|---|---|
| `esm` (default) | `import` / `export` left intact, top-level code |
| `cjs` | Converted to `require()` / `module.exports` |
| `iife` | Wrapped as `(function() { ... })()`, exposed via `--global-name` |
| `umd` | UMD wrapper (CJS / AMD / global fallback) |
| `amd` | `define([...], function (...) { ... })` |

### `banner` / `footer` vs `intro` / `outro`

- `banner` / `footer` — **outside** the wrapper (license headers, shebangs)
- `intro` / `outro` — **inside** the wrapper, before/after bundle code (Rollup `output.intro/outro` compatible)

The distinction matters for IIFE/UMD wrap formats.

### Sourcemaps

- `--sourcemap` — external `.map` file plus URL comment
- `--sourcemap=inline` — base64 inline data URL
- `--sourcemap=hidden` — emit map file but omit URL comment (production)

Bundle sourcemaps are computed via direct AST-span mapping (no chaining required). If the input already has a sourcemap, it's chained automatically.

## Debugging — which stage owns this symptom?

| Symptom | Suspect stage | Tool |
|---|---|---|
| `Could not resolve '...'` | Resolver | `--log-level=debug`, `inputs` in `--metafile` |
| Variables renamed unexpectedly | Linker | sourcemap, `output` mapping in `--metafile` |
| Dead code not removed | Tree-shaker | See limits in [Tree-shaking](/zntc/en/guides/tree-shaking/) |
| CJS named import doesn't work | Interop | See "statically provable patterns" above |
| Chunks split too aggressively | Chunker | Disable `--splitting` or use `manualChunks` |
| Output format isn't what you wanted | Emitter | Check `--format`, `--global-name` |

## Further reading

- [Tree-shaking](/zntc/en/guides/tree-shaking/) — `@__PURE__`, `sideEffects`, type-only elision, statement-level DCE
- [Bundling](/zntc/en/guides/bundling/) — full CLI option reference
- Contributor design docs: [`docs/BUNDLER.md`](https://github.com/ohah/zntc/blob/main/docs/BUNDLER.md), [`docs/ARCHITECTURE.md`](https://github.com/ohah/zntc/blob/main/docs/ARCHITECTURE.md)
