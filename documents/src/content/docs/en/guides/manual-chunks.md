---
title: manualChunks
description: User-defined chunk splitting — compatible with Rollup's `manualChunks(id, meta)`.
---

ZNTC implements Rollup's `manualChunks(id, meta)` signature. Common production patterns — vendor/shared splitting, content-based grouping, and graph-topology-based grouping — are all supported.

## Basic usage

```ts
import { build } from "@zntc/core";

await build({
  entryPoints: ["./src/main.ts"],
  splitting: true,
  outdir: "./dist",
  manualChunks: (id) => {
    if (id.includes("node_modules")) return "vendor";
    return null;
  },
});
```

Modules are grouped into the chunk whose name `manualChunks` returns. Returning `null` / `undefined` falls back to automatic chunking.

## meta API — graph-topology grouping

The second argument `meta` exposes `getModuleInfo(id)` for graph lookups.

```ts
manualChunks: (id, meta) => {
  const info = meta.getModuleInfo(id);
  if (!info) return null;

  // Only modules imported by 2+ other modules go to "shared"
  if (info.importers.length >= 2) return "shared";

  // External dependencies always split off
  if (info.isExternal) return "vendor";

  // Skip modules dropped by tree-shaking
  if (!info.isIncluded) return null;

  return null;
},
```

### `ManualChunksModuleInfo` fields

| Field | Type | Description |
|---|---|---|
| `id` | `string` | Absolute module path |
| `isEntry` | `boolean` | Whether this module is an entry point |
| `isExternal` | `boolean` | Module excluded from the bundle by an `external` pattern |
| `hasModuleSideEffects` | `boolean` | Result of `package.json sideEffects` / glob match |
| `code` | `string \| null` | Module source. `null` for external / asset modules |
| `isIncluded` | `boolean` | Whether the module survived tree-shaking |
| `exports` | `string[]` | Exported names (including default) |
| `importers` | `string[]` | Absolute paths of modules that statically import this one |
| `dynamicImporters` | `string[]` | Modules that reach this one via `import()` |
| `importedIds` | `string[]` | Static imports of this module (external included) |
| `dynamicallyImportedIds` | `string[]` | Dynamic imports of this module |
| `syntheticNamedExports` | `boolean` | Plugin-defined — currently always `false` |
| `implicitlyLoadedAfterOneOf` | `string[]` | Plugin `emitFile` option — currently always `[]` |
| `implicitlyLoadedBefore` | `string[]` | Same as above |

`info.ast` is not yet exposed (depends on the ESTree adapter).

## inlineDynamicImports

Dynamic-import targets are absorbed into the importer's chunk, approximating a single-file output.

```ts
await build({
  entryPoints: ["./src/main.ts"],
  splitting: true,
  inlineDynamicImports: true,  // inline dynamic imports too
  outdir: "./dist",
});
```

Internally each dynamic-import target is wrapped with `__esm` and `import("./x")` calls are rewritten to `Promise.resolve().then(() => (init_x(), exports_x))`.

### Guarantees
- **Namespace identity**: `(await import("./x")) === (await import("./x"))`
- **Single execution**: top-level side effects run exactly once (`__esm` caches)
- **Live bindings**: mutations like `export let counter; counter++` are visible to callers

## external handling

Modules matched by `external` are excluded from the bundle but registered as phantom modules in the graph — Rollup parity.

```ts
await build({
  entryPoints: ["./src/main.ts"],
  external: ["react", "react-dom"],
  manualChunks: (id, meta) => {
    // externals are directly queryable
    const reactInfo = meta.getModuleInfo("react");
    console.log(reactInfo?.isExternal); // true

    // entry.importedIds includes externals
    const entry = meta.getModuleInfo(id);
    console.log(entry?.importedIds.includes("react")); // true if entry imports react

    return null;
  },
});
```

## Patterns

### Vendor / shared split

```ts
manualChunks: (id) => {
  if (id.includes("/node_modules/")) return "vendor";
  if (id.includes("/src/components/")) return "components";
  return null;
}
```

### Content-based grouping

Group only modules whose source contains a `@vendor` marker:

```ts
manualChunks: (id, meta) => {
  const info = meta.getModuleInfo(id);
  if (info?.code?.includes("@vendor")) return "vendor";
  return null;
}
```

### Shared chunk (modules used by 2+ entries)

```ts
manualChunks: (id, meta) => {
  const info = meta.getModuleInfo(id);
  if (!info) return null;
  if (info.isEntry) return null;
  if (info.importers.length >= 2) return "shared";
  return null;
}
```

### Pure / tree-shakable libraries into their own chunk

```ts
manualChunks: (id, meta) => {
  const info = meta.getModuleInfo(id);
  if (info && !info.hasModuleSideEffects) return "pure";
  return null;
}
```

## Behavior & limits

- The `manualChunks` resolver is called exactly once per module (NAPI TSFN — minimal JS round-trips).
- If the resolver throws, the module falls back to `null` (auto chunking); the build is not aborted.
- Non-string returns (number, boolean) are treated as `null` (Rollup semantics).
- `external` modules are not passed to the resolver — phantom modules are not chunk-assignment candidates.
- Dynamic-import targets are excluded from manual chunks by default to preserve lazy-load semantics. Set `inlineDynamicImports: true` to absorb them into the importer's chunk.

## CLI

`manualChunks` is a function, so it cannot be expressed on the CLI directly — use the JS API (`@zntc/core`) or `zntc.config.{js,ts}`.

```ts
// zntc.config.ts
import { defineConfig } from "@zntc/core";

export default defineConfig({
  entryPoints: ["./src/main.ts"],
  splitting: true,
  inlineDynamicImports: true,
  manualChunks: (id, meta) => {
    if (meta.getModuleInfo(id)?.isExternal) return "vendor";
    return null;
  },
});
```

## Coverage

13 of 14 Rollup `ModuleInfo` fields are exposed. `info.ast` and plugin-context APIs (`this.getModuleInfo` / `emitFile` / `resolve`) are not available yet.
