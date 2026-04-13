---
title: CLI Reference
description: Complete list of ZTS CLI options
---

## Transpile

```bash
zts <file.ts>                      # → stdout
zts <file.ts> -o <out.js>          # → file
zts <dir/> --outdir <out/>         # recursive directory
zts - < input.ts                   # stdin
```

## Bundle

```bash
zts --bundle <entry.ts>                               # → stdout
zts --bundle <entry.ts> -o out.js                     # → file
zts --bundle <entry.ts> --splitting --outdir dist     # code splitting
zts --bundle <entry.ts> --preserve-modules --outdir dist  # per-module (library)
zts --bundle <entry.ts> --plugin zts.config.js        # JS plugin
```

## I/O

| Option | Description |
|--------|-------------|
| `-o, --out-file <path>` | Output file path |
| `--outdir <path>` | Output directory (required for dir input / splitting / preserve-modules) |
| `--outbase=<dir>` | Base dir for computing output paths |
| `--out-extension:.js=<ext>` | Change output extension (e.g. `.mjs`) |
| `--allow-overwrite` | Allow overwriting input path |
| `--clean` | Clear outdir before building |

## Format / Platform

| Option | Description |
|--------|-------------|
| `--format=esm\|cjs\|iife\|umd\|amd` | Module format (default: `esm`) |
| `--platform=browser\|node\|neutral\|react-native` | Target platform |
| `--rn-platform=ios\|android` | RN sub-platform (`.ios.*`/`.android.*` extensions) |
| `--target=<spec>` | ES target: `es2015`–`esnext` or engine versions (`chrome80,safari14`) |
| `--global-name=<name>` | IIFE export name |
| `--global-identifier=<id>` | Global identifier override |

## Minify

| Option | Description |
|--------|-------------|
| `--minify` | Enable all three (shortcut) |
| `--minify-whitespace` | Whitespace/semicolons/newlines only (debuggable) |
| `--minify-syntax` | `true`→`!0`, paren removal, constant folding |
| `--minify-identifiers` | Shorten local identifiers |
| `--keep-names` | Preserve function/class `.name` |
| `--charset=utf8\|ascii` | Output charset |
| `--ascii-only` | Non-ASCII → `\uXXXX` (= `--charset=ascii`) |
| `--quotes=double\|single\|preserve` | String quote style |
| `--line-limit=<n>` | Max line length (wrap when minifying) |

## Source Maps

| Option | Description |
|--------|-------------|
| `--sourcemap` | External `.js.map` |
| `--sourcemap=inline` | Inline data URL |
| `--sourcemap=external` | External file, no comment |
| `--sourcemap=hidden` | External only (omit comment) |
| `--sourcemap-debug-ids` | Sentry debugId support |
| `--sources-content=false` | Omit `sourcesContent` |
| `--source-root=<path>` | `sourceRoot` field |

## Transform / Replace

| Option | Description |
|--------|-------------|
| `--define:KEY=VALUE` | Global replace (e.g. `process.env.NODE_ENV` → `"production"`) |
| `--drop=console` | Remove `console.*` calls |
| `--drop=debugger` | Remove `debugger` statements |
| `--drop-labels=<list>` | Remove labeled blocks (e.g. `DEV,TEST`) |
| `--pure:<name>` | Mark call as pure for DCE |
| `--inject:<path>` | Auto-inject import (shim) |
| `--polyfill=<list>` | Runtime polyfill injection |

## JSX

| Option | Description |
|--------|-------------|
| `--jsx=classic\|automatic\|automatic-dev` | JSX runtime |
| `--jsx-dev` | `--jsx=automatic-dev` shortcut |
| `--jsx-factory=<fn>` | Classic factory (default: `React.createElement`) |
| `--jsx-fragment=<fn>` | Classic Fragment |
| `--jsx-import-source=<pkg>` | Automatic import source (default: `react`) |
| `--jsx-in-js` | Allow JSX parsing in `.js` files |
| `--jsx-side-effects` | Mark JSX elements as having side effects (skip DCE) |

## TypeScript

| Option | Description |
|--------|-------------|
| `-p, --project <path>` | tsconfig.json path/directory |
| `--tsconfig-raw=<json>` | Inline tsconfig JSON |
| `--experimental-decorators` | Legacy decorator (`__decorateClass`) |
| `--use-define-for-class-fields=false\|true` | Class field semantics |

## Flow

| Option | Description |
|--------|-------------|
| `--flow` | Flow type stripping (auto-detected via `@flow` pragma) |
| `--ignore-annotations` | Ignore Flow comments/pragmas |

## Bundle-specific

| Option | Description |
|--------|-------------|
| `--bundle` | Enable bundle mode |
| `--splitting` | Code splitting (requires `--outdir`) |
| `--preserve-modules` | Per-module output (library build) |
| `--preserve-modules-root=<dir>` | Root for output structure |
| `--entry-names=<pattern>` | Entry name pattern (`[name]`, `[hash]`) |
| `--chunk-names=<pattern>` | Chunk name pattern |
| `--asset-names=<pattern>` | Asset name pattern |
| `--loader:.ext=type` | Loader by extension (`file\|dataurl\|text\|binary\|copy\|json\|css\|js\|ts\|jsx\|tsx`) |
| `--metafile` / `--metafile=<path>` | Build meta JSON (stdout or file) |
| `--analyze` | Bundle analysis report |
| `--legal-comments=<mode>` | License comments: `none\|inline\|eof\|linked\|external` |
| `--banner:js=<text>` | Prepend text |
| `--footer:js=<text>` | Append text |
| `--public-path=<url>` | Asset URL prefix |
| `--shim-missing-exports` | Shim missing exports with `undefined` |

## Resolve

| Option | Description |
|--------|-------------|
| `--external <pkg>` / `--external=<pkg,...>` | Exclude from bundle (repeatable) |
| `--packages=external` | Mark all npm packages external |
| `--alias:FROM=TO` | Import path alias |
| `--conditions=<list>` | Custom export conditions (e.g. `production,custom`) |
| `--resolve-extensions=<exts>` | Extension lookup order (e.g. `.ios.ts,.ts,.js`) |
| `--main-fields=<fields>` | package.json field order (e.g. `react-native,browser,main`) |
| `--node-paths=<dirs>` | Additional `NODE_PATH` directories |
| `--preserve-symlinks` | Don't resolve symlinks |

## Watch / Dev Server

| Option | Description |
|--------|-------------|
| `-w, --watch` | Watch for file changes (incremental rebuild) |
| `--watch-json` | NDJSON event output (for external HMR integration) |
| `--watch-delay=<ms>` | Debounce delay |
| `--serve [dir]` | Static file server (default: `.`) |
| `--port <n>` | Server port |
| `--host [addr]` | Binding address |
| `--open` | Auto-open browser |
| `--proxy /api=http://host:port` | API proxy |
| `--dev` | Dev mode (HMR + fast rebuild) |
| `--run-before-main=<cmd>` | Inject code to run before bundle entry |

**Dev server external interfaces:** `/sse/events` (SSE build events), `/reset-cache` (Control API), `/mcp` (Model Context Protocol — for LLM agents like Claude Code).

## Plugins / Execution

| Option | Description |
|--------|-------------|
| `--plugin <path>` | JS/TS plugin or config file |
| `--jobs=<n>` | Parallel thread count |

## Diagnostics / Logging

| Option | Description |
|--------|-------------|
| `--log-level=<level>` | `silent\|error\|warning\|info\|debug\|verbose` |
| `--log-limit=<n>` | Max diagnostics shown |
| `--timing` | Per-stage timing output |
| `--tokenize` | Print tokens instead of transpiling |
| `--test262 <dir>` | Run Test262 suite |
| `-h, --help` | Show help |

## See Also

- JS API (`@zts/core`) in `packages/core/index.ts` provides the same options programmatically.
- Use `vite-plugin-zts` or `vitePlugin()` for the Vite adapter.
- Unsupported options and future plans: [docs/ROADMAP.md](https://github.com/ohah/zts/blob/main/docs/ROADMAP.md).
