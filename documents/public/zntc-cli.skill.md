---
name: zntc-cli
description: ZNTC (Zig Native Transpiler & Compiler) install + CLI/NAPI usage. Transpile JS/TS/JSX/Flow, bundle, tree-shake, minify. Drop-in alternative to esbuild/Bun/rolldown/rspack (transpile small -62% / bundle small 1st place)
---

# ZNTC usage guide (Claude Code skill)

A Claude Code skill that teaches LLMs how to install and use ZNTC. Place at `~/.claude/skills/zntc-cli/SKILL.md` (global) or `.claude/skills/zntc-cli/SKILL.md` (per-project).

## What is ZNTC

ZNTC is a JS/TS transpiler + bundler written in Zig:

- **Transpile**: strip TypeScript types, JSX, Flow; downlevel ES2015+
- **Bundle**: tree-shake + minify; on par with rolldown/esbuild in speed and sometimes smaller in output
- **Invocation**: CLI binary, C NAPI (`.node`), WASM, or Vite/Rollup plugin adapter

## Installation

### Option A: CLI binary (simplest)

```sh
# One-line installer (downloads release binary)
curl -fsSL https://raw.githubusercontent.com/ohah/zntc/main/install.sh | sh

# Or via npm
npm install -g @zntc/core
```

### Option B: Individual packages

```sh
# Core bundler / CLI (rolldown alternative)
npm install --save-dev @zntc/core

# Vite plugin (rollup alternative)
npm install --save-dev @zntc/vite-plugin

# Rollup plugin
npm install --save-dev @zntc/rollup-plugin
```

## Quick start

### Transpile (TS → JS)

```sh
zntc input.ts -o output.js
zntc input.tsx -o output.js --jsx automatic
zntc src/main.ts --target=es2020 -o dist/main.js
```

### Bundle

```sh
# Single-file bundle (esbuild-equivalent usage)
zntc --bundle src/index.ts -o dist/bundle.js

# Multi-format (rollup-style)
zntc --bundle src/index.ts \
  --format=esm --output=dist/esm/bundle.mjs \
  --format=cjs --output=dist/cjs/bundle.cjs
```

### NAPI (Node.js / Bun in-process — ~50× faster than CLI spawn)

```ts
import { transpile, bundle } from '@zntc/core';

// Transpile
const { code, map } = transpile(source, {
  filename: 'input.tsx',
  jsx: 'automatic',
  target: 'es2022',
});

// Bundle
const result = await bundle({
  entryPoints: ['src/index.ts'],
  outdir: 'dist',
  format: 'esm',
  minify: true,
  treeShake: true,
});
```

### Vite plugin (vite.config.ts)

```ts
import { defineConfig } from 'vite';
import zntc from '@zntc/vite-plugin';

export default defineConfig({
  plugins: [zntc()],
});
```

## Key options

| Flag | Meaning |
|---|---|
| `--bundle` | bundle mode (without this flag, transpile only) |
| `--format=esm/cjs/iife` | output module format |
| `--target=es5/es2015/es2020/es2022` | ECMAScript target (for downleveling) |
| `--jsx=automatic/classic/preserve` | JSX transform mode |
| `--minify` / `--minify-identifiers` / `--minify-whitespace` | minify (esbuild-equivalent flags) |
| `--tree-shake` | enable tree-shaking (default on with `--bundle`) |
| `--watch` | watch mode (HMR — incremental rebuild ~22 ms / 641 modules) |
| `--profile=parse,transform,...` | print per-phase timing to stderr (debug) |
| `--target-platform=node/browser/react-native` | resolution platform |

## Performance (2026-05-21, darwin arm64, 20-run median)

| Task | ZNTC | esbuild | Bun | rolldown | rspack |
|---|---|---|---|---|---|
| Transpile 100 lines | **1.79 ms** | 3.90 | 5.16 | — | — |
| Transpile 1K lines | 3.02 ms | 4.79 | 5.59 | — | — |
| Bundle 10 modules | **2.62 ms** | 10.8 | 8.05 | 52.3 | 62.4 |
| Bundle 1K modules | **17.0 ms** | 26.8 | 23.3 | 70.2 | 83.8 |
| Bundle 5K modules | 81.7 ms | 89.1 | **66.4** | 126 | 181 |

## Practical workflows

### React + TypeScript SPA

```sh
# Dev (watch)
zntc --bundle src/index.tsx --watch --jsx=automatic -o dist/bundle.js

# Production
zntc --bundle src/index.tsx \
  --jsx=automatic \
  --target=es2020 \
  --minify \
  --tree-shake \
  -o dist/bundle.js
```

### Library publish (Multi-format)

```sh
zntc --bundle src/index.ts \
  --format=esm --output=dist/index.mjs \
  --format=cjs --output=dist/index.cjs \
  --target=es2018 \
  --minify
```

### Drop-in to an existing Vite project

```ts
// vite.config.ts
import zntc from '@zntc/vite-plugin';

export default {
  plugins: [zntc({ tsconfig: './tsconfig.json' })],
};
```

## Limitations / not supported

- WASM build: `.wasm` target not released yet (planned)
- Hermes regex named capture group downleveling: not supported (Hermes limitation — only kept in original form)
- Multi-format + dev_mode/splitting/MF combination is rejected (explicit error)
- Some minify cases: zod/effect output is slightly larger than rolldown's (mangler gap, deferred work)

## References

- Official docs: https://ohah.github.io/zntc/
- English docs: https://ohah.github.io/zntc/en/
- llms.txt (sitemap): https://ohah.github.io/zntc/llms.txt
- llms-full.txt (entire docs as plain text): https://ohah.github.io/zntc/llms-full.txt
- GitHub: https://github.com/ohah/zntc
- Playground: https://ohah.github.io/zntc/en/playground/

## How to install this skill (Claude Code)

```sh
# Global (works in every project)
mkdir -p ~/.claude/skills/zntc-cli
curl -fsSL https://ohah.github.io/zntc/zntc-cli.skill.md > ~/.claude/skills/zntc-cli/SKILL.md
```

Or per-project:

```sh
mkdir -p .claude/skills/zntc-cli
curl -fsSL https://ohah.github.io/zntc/zntc-cli.skill.md > .claude/skills/zntc-cli/SKILL.md
```

After installing, Claude Code automatically invokes this skill when it detects `zntc`, `transpile`, or `bundle`-related tasks.
