---
title: Library Build
description: Build an npm package (library) with ZNTC, the way tsup / tsdown / bunup do.
---

ZNTC builds not only apps and web servers but also **publishable npm packages (libraries)**. What `tsup` / `tsdown` / `bunup` do — entry bundling, ESM/CJS output, externalized dependencies, sourcemaps, minify, watch — ZNTC does the same.

> **Type declarations (`.d.ts`)**: ZNTC does not currently emit `.d.ts` (delegated to `tsc` per the [roadmap](/zntc/en/guides/introduction/)). The recipe below runs `tsc --emitDeclarationOnly` alongside, the standard setup.

## Project layout

```text
my-lib/
├── package.json           # exports/main/module/types + build scripts
├── tsconfig.json          # declaration: true, emitDeclarationOnly → .d.ts only
├── zntc.config.ts         # library build config (optional — CLI alone works too)
└── src/
    └── index.ts           # package entry
```

## Build config

The two essentials of a library build are **not bundling dependencies** (external) and **emitting formats the consumer can pick**.

```ts
// zntc.config.ts
import { defineConfig } from "@zntc/core";

export default defineConfig({
  entryPoints: ["src/index.ts"],
  outdir: "dist",
  format: "esm",
  // neutral: no Node/browser assumption — recommended default for libraries.
  // Use platform: "node" if Node-only.
  platform: "neutral",
  // Treat every bare import (react, lodash, ...) as external — node_modules
  // stays out of the bundle. Same as esbuild `--packages=external`.
  packagesExternal: true,
  target: "es2022",
  sourcemap: true,
  minify: true,
});
```

`clean` (wipe the output directory) is a CLI-only flag (`--clean`) — not a config key, so it appears in the CLI examples below.

CLI-only equivalent:

```bash
zntc --bundle src/index.ts --outdir dist \
  --format=esm --platform=neutral --packages=external \
  --target=es2022 --sourcemap --minify --clean
```

## ESM + CJS at once

A single `build()` / `zntc build` emits **one format only**. Dual format means running the build twice.

Via `package.json` scripts:

```jsonc
{
  "scripts": {
    "build:esm": "zntc --bundle src/index.ts --outdir dist --out-extension:.js=.mjs --format=esm --platform=neutral --packages=external --sourcemap --minify",
    "build:cjs": "zntc --bundle src/index.ts --outdir dist --out-extension:.js=.cjs --format=cjs --platform=neutral --packages=external --sourcemap --minify",
    "build:types": "tsc --emitDeclarationOnly --declaration --outDir dist",
    "build": "zntc --bundle src/index.ts --outdir dist --clean --format=esm && bun run build:cjs && bun run build:types"
  }
}
```

To bundle both formats + types in one script via the JS API:

```ts
// scripts/build.ts
import { build } from "@zntc/core";
import { execFileSync } from "node:child_process";

const common = {
  entryPoints: ["src/index.ts"],
  platform: "neutral" as const,
  packagesExternal: true,
  sourcemap: true,
  minify: true,
};

await build({ ...common, format: "esm", outdir: "dist", outExtension: ".mjs" });
await build({ ...common, format: "cjs", outdir: "dist", outExtension: ".cjs" });

// Type declarations are delegated to tsc (ZNTC does not emit .d.ts).
execFileSync("tsc", ["--emitDeclarationOnly", "--declaration", "--outDir", "dist"], {
  stdio: "inherit",
});
```

```bash
zntc src/build.ts --platform=node && node dist/build.js   # build the build script with ZNTC too
# or: bun run scripts/build.ts
```

## tsconfig (declarations only)

```jsonc
{
  "compilerOptions": {
    "declaration": true,
    "emitDeclarationOnly": true,
    "outDir": "dist",
    "moduleResolution": "Bundler",
    "strict": true,
    "skipLibCheck": true
  },
  "include": ["src"]
}
```

`tsc` emits `.d.ts` only, ZNTC emits `.js` (.mjs/.cjs) + sourcemaps only — no overlap.

## Recommended package.json fields

Declare `exports` so consumers resolve ESM/CJS/types correctly.

```jsonc
{
  "name": "my-lib",
  "type": "module",
  "main": "./dist/index.cjs",
  "module": "./dist/index.mjs",
  "types": "./dist/index.d.ts",
  "exports": {
    ".": {
      "types": "./dist/index.d.ts",
      "import": "./dist/index.mjs",
      "require": "./dist/index.cjs"
    }
  },
  "files": ["dist"],
  "sideEffects": false
}
```

`"sideEffects": false` helps the consumer's bundler tree-shake (only when there are no side effects).

## Preserve module structure (optional)

To keep the `src/` structure 1:1 in `dist/` instead of a single-file bundle (better for consumer-side tree-shaking and partial imports), use `preserveModules`:

```bash
zntc --bundle src/index.ts --outdir dist \
  --format=esm --platform=neutral --packages=external \
  --preserve-modules --preserve-modules-root=src
```

Same as Rollup `output.preserveModules` — each source module stays a 1:1 output file.

## Watch-mode development

Auto-rebuild on library source changes (bundle only — not HMR):

```bash
zntc --bundle src/index.ts --outdir dist --format=esm --packages=external --watch
```

For declarations too, run `tsc -w --emitDeclarationOnly` in a separate terminal.

## vs tsup / tsdown / bunup

| Feature | ZNTC | Note |
| --- | --- | --- |
| ESM / CJS output | ✅ | one build per format (chain via scripts) |
| External deps | ✅ | `packagesExternal` / `--packages=external` |
| sourcemap / minify | ✅ | `sourcemap` / `minify` |
| tree-shaking | ✅ | on by default ([Tree Shaking](/zntc/en/guides/tree-shaking/)) |
| code splitting | ✅ | `splitting: true` |
| preserveModules | ✅ | `--preserve-modules` |
| watch | ✅ | `--watch` |
| multiple entries | ✅ | `entryPoints: [...]` |
| **`.d.ts` generation** | ❌ | **run `tsc --emitDeclarationOnly`** (recipe above) |

Covers most library build scenarios except `.d.ts` emit, which is planned via `isolatedDeclarations`.

## Related

- [Config File](/zntc/en/guides/config-file/) — full `zntc.config.ts` options and functional config.
- [Tree Shaking](/zntc/en/guides/tree-shaking/) — dead-code elimination for library bundles.
- [NAPI / JS API](/zntc/en/reference/napi/) — programmatic `build()` usage.
- [From Other Tools](/zntc/en/guides/migration/) — migration mapping from tsup/tsdown etc.
