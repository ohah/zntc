---
title: Plugins
description: Learn how to use the ZNTC plugin system.
---

## Overview

ZNTC provides a Rollup/Vite-compatible plugin interface. Plugins are written in JS/TS and run in-process via C NAPI (via `@zntc/core`).

## Compatibility Summary

| Surface | Status | Use |
| ------- | ------ | --- |
| esbuild-style `setup(build)` | Partial | `build.onResolve`, `build.onLoad`, `build.onTransform`, `build.onResolveContext`, `build.onAstFunction` |
| Rollup/Vite-style `resolveId` / `load` / `transform` | Supported | `vitePlugin()` wrapper or config plugin |
| output hooks `renderChunk` / `generateBundle` | Partial | chunk post-processing and output-list access |
| lifecycle `buildStart` / `buildEnd` / `closeBundle` | Supported | called for `build()` and for each initial/rebuild cycle in `watch()` |
| Rollup context `this.resolve()` / `this.emitFile()` | Unsupported | needs a separate graph mutation surface |
| `buildSync()` + JS plugins | Unsupported | use async `build()` / `watch()` |

The native ZNTC worker calls JS hooks through NAPI threadsafe functions when it reaches a module and waits for the response. Keep hook filters narrow, and prefer the built-in `loader` option for simple extension-based handling.

## Hook Order

```text
buildStart
  -> resolveId / onResolve
  -> load / onLoad
  -> transform / onTransform
  -> native link / tree-shake / emit
  -> renderChunk
  -> generateBundle
buildEnd
write
closeBundle
```

In `watch()`, the same order runs for the initial build and every rebuild. `onReady` or `onRebuild` runs after `buildEnd`.

### Per-hook selection policy with multiple plugins

When two or more plugins register the same hook, the way they combine differs by hook.

| Hook | Policy | Notes |
|---|---|---|
| `resolveId` / `onResolve` | **first-match** | First non-null wins. Subsequent plugins aren't called |
| `load` / `onLoad` | **first-match** | First non-null wins |
| `transform` / `onTransform` | **chaining** | All called in registration order. Each hook's output is the next hook's input |
| `renderChunk` | **chaining** | All called in registration order (chunk-code transforms) |
| `generateBundle` | **all-run, sequential** | All run; return values ignored (observation only) |
| `buildStart` / `buildEnd` / `closeBundle` | **all-run, sequential** | All run; lifecycle signals |

**When plugin order changes the result:**
- `resolveId` / `load` — once an earlier plugin matches, later plugins don't get a chance. Place virtual-module/alias handlers before the default resolver.
- `transform` — chain order matters. If env-substitution → minify is swapped, the result differs.

**Watch-mode lifecycle repetition:**

```text
Initial build: buildStart → resolveId/load/transform → buildEnd → write → onReady → closeBundle
On file change: buildStart → ... → buildEnd → onRebuild → closeBundle
```

`buildStart` / `closeBundle` fire **on every rebuild**. If you need to reuse a long-lived resource (DB/socket), initialize it **outside the build** (at module load) — not in `buildStart`.

**Errors in `buildEnd` / `closeBundle` are swallowed:**

Throwing from these two hooks does not affect the build/rebuild result (post-processing failures must not mask the user's build). To surface failures, use an explicit flag/log:

```typescript
let lastBuildOk = true;
const myPlugin = {
  name: 'after-build',
  buildEnd(err) {
    if (err) { lastBuildOk = false; return; }
    try {
      runPostProcess();   // failure is swallowed
    } catch (e) {
      lastBuildOk = false;
      console.error('[after-build] failed:', e);
    }
  },
};
```

## Config File

Create a `zntc.config.ts` (or `.js`, `.mjs`, `.mts`, `.cjs`, `.cts`) at the project root.

```typescript
// zntc.config.ts
import { defineConfig } from "@zntc/core";

export default defineConfig({
  plugins: [
    {
      name: "my-plugin",
      load(id) {
        if (id.endsWith(".txt")) {
          const fs = require("fs");
          return { contents: `export default ${JSON.stringify(fs.readFileSync(id, "utf8"))}` };
        }
        return null;
      },
    },
  ],
});
```

## Plugin Hooks

### resolveId

Custom module path resolution (first-match).

```typescript
{
  name: 'virtual-module',
  resolveId(source) {
    if (source === 'virtual:config') {
      return { path: '\0virtual:config' };
    }
    return null;
  }
}
```

#### `disabled` return — empty module fallback

Returning `disabled: true` replaces the module with an empty object (`module.exports = {}`). The escape hatch for Metro `resolveRequest` returning `{ type: 'empty' }` or webpack `resolve.fallback` set to `false`.

```typescript
{
  name: 'stub-node-builtins',
  resolveId(source) {
    if (source === 'fs' || source === 'path') {
      return { disabled: true };
    }
    return null;
  }
}
```

### load

Custom module content loading (first-match).

```typescript
{
  name: 'virtual-module',
  load(id) {
    if (id === '\0virtual:config') {
      return { contents: 'export const version = "1.0.0";' };
    }
    return null;
  }
}
```

#### `loader` option — asset loader override (#2157)

When the object returned from `load` includes `loader`, the graph overrides the module loader to that value (skipping extension inference). Same semantics as esbuild's `onLoad` callback `loader: 'text' | 'binary' | ...`.

```typescript
{
  name: 'md-as-text',
  load(id) {
    if (id.endsWith('.md')) {
      return {
        contents: readFileSync(id, 'utf-8'),
        loader: 'text',     // emit file contents as a string default export
      };
    }
    return null;
  }
}
```

Supported loaders: `file` / `copy` / `dataurl` / `base64` / `text` / `binary` / `empty` / `json` / `css` / `js` / `jsx` / `ts` / `tsx`.

`js` / `jsx` / `ts` / `tsx` force the `contents` returned from `onLoad` into the matching parser mode — useful for extension-less virtual modules or sources disguised under a different extension.

#### `contents` binary support (#2157 follow-up)

`contents` accepts `string` or `Uint8Array` / Node.js `Buffer` — PNG/JPG and other utf-8-invalid byte sequences are forwarded losslessly.

```typescript
{
  name: 'png-as-dataurl',
  load(id) {
    if (id.endsWith('.png')) {
      return {
        contents: readFileSync(id),  // Buffer / Uint8Array — binary safe
        loader: 'dataurl',
      };
    }
    return null;
  }
}
```

### transform

Transform module code (chaining — all plugins applied in order).

```typescript
{
  name: 'env-replace',
  transform(code, id) {
    if (id.endsWith('.ts') || id.endsWith('.js')) {
      return code.replace(/__APP_VERSION__/g, '"1.0.0"');
    }
    return null;
  }
}
```

### renderChunk

Post-process chunk code before output (chaining).

```typescript
{
  name: 'banner',
  renderChunk(code, chunkName) {
    return `/* chunk: ${chunkName} */\n${code}`;
  }
}
```

### generateBundle

Called after bundle generation is complete.

```typescript
{
  name: 'notify',
  generateBundle(outputs) {
    console.log(`Built ${outputs.length} files`);
  }
}
```

### onResolveContext

Lets the host runtime fill in `require.context(dir, recursive, filter, mode)` matches. ZNTC has no built-in regex executor, so it delegates to the host's RegExp (Node V8 / Bun JSC).

Callback arguments:
- `dir` — first arg of `require.context`.
- `recursive` — second arg.
- `filter` — regex source (no slashes).
- `flags` — regex flags.
- `importer` — the calling module path.

Callback return:
- `{ context: string[] }` — array of matched file paths (empty array = empty context).
- `null` / `undefined` — try the next plugin. If all return null, the graph emits a `require_context_no_handler` diagnostic.

```typescript
import { readdirSync } from "node:fs";
import { join } from "node:path";

{
  name: 'require-context',
  setup(build) {
    build.onResolveContext({ filter: /^\.\/app/ }, ({ dir, filter, flags, importer }) => {
      const re = new RegExp(filter ?? '.', flags ?? '');
      const root = join(importer, '..', dir);
      const files = readdirSync(root).filter((f) => re.test(f)).map((f) => join(root, f));
      return { context: files };
    });
  },
}
```

### onAstFunction

High-power AST hook. For each function in files matching `filter`, receives `AstFunctionInfo` and may return `stripDirective` to remove a directive plus `trailingCode` to inject statements after the function definition.

```typescript
interface AstFunctionInfo {
  name: string | null;
  directives: string[];        // prologue directives in the function body
  closureVars: string[];       // outer identifiers referenced
  params: string[];
  sourcePath: string;
  bodyText: string;
  flags: { async: boolean; generator: boolean };
}

interface AstFunctionResult {
  stripDirective?: string;     // directive to strip from the body prologue
  trailingCode?: string[];     // statements to insert after the function definition
}
```

This is the external surface for 1st-party transforms like Reanimated worklets (injecting hash/closure/initData into `"worklet"`-directive functions). Use it only when you need function-scope metadata that a regular `transform` can't reach.

```typescript
{
  name: 'mark-worklets',
  setup(build) {
    build.onAstFunction({ filter: /\.tsx?$/ }, (info) => {
      if (!info.directives.includes('worklet')) return null;
      return {
        stripDirective: 'worklet',
        trailingCode: [`${info.name}.__hash = ${JSON.stringify(info.bodyText.length)};`],
      };
    });
  },
}
```

### buildStart / buildEnd / closeBundle (#2156)

Bundle lifecycle hooks. Compatible with esbuild's `onStart` / `onEnd` / `onDispose` and Rollup/Vite/rolldown's `buildStart` / `buildEnd` / `closeBundle`.

| Hook | When | Argument |
|---|---|---|
| `buildStart` | Once at bundle start (initial build and every rebuild in watch mode) | none |
| `buildEnd` | Right after output contents are determined | `error?: Error` (message of the first fatal diagnostic on failure) |
| `closeBundle` | After output files are written | none |

```typescript
{
  name: 'lifecycle',
  buildStart() { console.log('build started'); },
  buildEnd(err) {
    if (err) console.error('build failed:', err.message);
    else console.log('output ready');
  },
  closeBundle() { console.log('write done'); },
}
```

`build()` call order: `buildStart → onLoad / onTransform → buildEnd → write → closeBundle`.
`watch()` call order: `buildStart → onLoad / onTransform → buildEnd → onReady/onRebuild → closeBundle`.
With multiple plugins each hook fires in sequence. Errors thrown from `buildEnd` / `closeBundle` are swallowed so they don't mask the actual build/rebuild result.

## Build API

```typescript
import { build } from "@zntc/core";

const result = await build({
  entryPoints: ["src/index.ts"],
  outdir: "dist",
  bundle: true,
  minify: true,
  sourcemap: true,
});

if (result.errors.length > 0) {
  console.error(result.errors);
}
```

### BuildOptions

| Option | Type | Description |
|--------|------|-------------|
| `entryPoints` | `string[]` | Entry files |
| `outdir` | `string` | Output directory |
| `outfile` | `string` | Output file (single) |
| `allowOverwrite` | `boolean` | Explicitly permit output paths to overwrite input files |
| `bundle` | `boolean` | Bundle mode |
| `format` | `"esm" \| "cjs" \| "iife" \| "umd" \| "amd"` | Module format |
| `platform` | `"browser" \| "node" \| "neutral" \| "react-native"` | Target platform |
| `target` | `string \| string[]` | ES version (`"es2020"`) or engines (`["chrome80","safari14"]`) |
| `minify` | `boolean` | Minification (all three) |
| `minifyWhitespace` / `minifySyntax` / `minifyIdentifiers` | `boolean` | Granular toggles |
| `sourcemap` | `boolean` | Source maps |
| `splitting` | `boolean` | Code splitting |
| `write` | `boolean` | `false` to return in-memory |
