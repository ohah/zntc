---
title: CLI Reference
description: Complete list of ZNTC CLI options
---

## Transpile

```bash
zntc <file.ts>                      # → stdout
zntc <file.ts> -o <out.js>          # → file
zntc <dir/> --outdir <out/>         # recursive directory
zntc - < input.ts                   # stdin
```

## Bundle

```bash
zntc --bundle <entry.ts>                               # → stdout
zntc --bundle <entry.ts> -o out.js                     # → file
zntc --bundle <entry.ts> --splitting --outdir dist     # code splitting
zntc --bundle <entry.ts> --preserve-modules --outdir dist  # per-module (library)
zntc --bundle <entry.ts> --plugin zntc.config.js        # JS plugin
```

## App Builder

```bash
zntc dev [root]             # index.html-based dev server
zntc build [root]           # HTML rewrite + hashed assets → dist/
zntc preview [outdir]       # serve built files only
```

The default app layout is `index.html`, `public/`, `src/main.ts(x)`, and `.env*`.
`zntc build` uses `<script type="module" src>` as bundle entries and rewrites CSS
`url()`, HTML asset URLs, and `%ENV%` tokens, and injects `modulepreload` links
for static split chunks. `zntc dev` uses the same HTML/env/public prepare step and
updates stylesheets for CSS edits without a full page reload.

| Option                      | Description                                                                       |
| --------------------------- | --------------------------------------------------------------------------------- |
| `--entry-html <file>`       | HTML entry file (default: `index.html`)                                           |
| `--public-dir <dir\|false>` | public copy directory or disabled                                                 |
| `--base <path>`             | HTML/CSS asset URL prefix                                                         |
| `--mode <name>`             | env/config mode (`dev`: `development`, `build`: `production`)                     |
| `--env-prefix <list>`       | exposed env prefix CSV (default: `VITE_,ZNTC_`)                                   |
| `--env-dir <dir>`           | directory for `.env*` files                                                       |
| `--spa-fallback[=file]`     | in `preview`, fall back route-like 404 requests to `index.html` or the given file |

If the app root contains `postcss.config.{js,mjs,cjs,json}` or `.postcssrc*`,
ZNTC automatically applies it to CSS. In `zntc dev`, original CSS files and PostCSS
`dependency` / `dir-dependency` messages are watched and CSS-only edits are sent
as stylesheet HMR updates. Tailwind v4 works via `@tailwindcss/postcss`. CSS
Modules (`.module.css`) in app mode are transformed into scoped class maps with
default exports and valid named exports. `.scss` / `.sass` files are compiled to
CSS before PostCSS when the optional `sass` dependency is installed.

## React Native Initializer (`@zntc/init`)

This is a separate npx entry point that adds ZNTC scripts and config to an
existing React Native CLI project. Expo project creation/initialization is
currently out of scope.

```bash
npx @zntc/init
npx @zntc/init --help
```

```text
Usage: zntc-init [react-native] [options]

Overlay ZNTC onto an existing React Native CLI project.

Options:
  --root <dir>               Project root (default: cwd)
  --platform <ios|android>   Default platform for the start script (default: ios)
  --zntc-version <range>     Version range for @zntc packages (default: latest)
  --package-manager <pm>     Install command hint: bun, npm, pnpm, or yarn
  --no-metro-fallback        Do not add Metro fallback scripts
  --force                    Overwrite an existing zntc.config.ts
  --dry-run                  Print planned changes without writing files
  --help, -h                 Show this help message
```

| Option                                     | Description                                                   |
| ------------------------------------------ | ------------------------------------------------------------- |
| `--root <dir>`                             | Project root. Defaults to the current directory               |
| `--platform <ios\|android>`                | Default RN platform for the `start` script. Defaults to `ios` |
| `--zntc-version <range>`                   | Version range for `@zntc/core` and `@zntc/react-native`       |
| `--package-manager <bun\|npm\|pnpm\|yarn>` | Install command hint printed after initialization             |
| `--no-metro-fallback`                      | Do not add Metro fallback scripts                             |
| `--force`                                  | Overwrite an existing `zntc.config.ts`                        |
| `--dry-run`                                | Print planned changes without writing files                   |
| `--help`, `-h`                             | Show help                                                     |

## I/O

| Option                      | Description                                                              |
| --------------------------- | ------------------------------------------------------------------------ |
| `-o, --out-file <path>`     | Output file path (the JS wrapper also accepts `--outfile` as alias)      |
| `--outdir <path>`           | Output directory (required for dir input / splitting / preserve-modules) |
| `--outbase=<dir>`           | Base dir for computing output paths                                      |
| `--out-extension:.js=<ext>` | Change output extension (e.g. `.mjs`)                                    |
| `--clean`                   | Clear outdir before building                                             |

## Format / Platform

| Option                                            | Description                                                           |
| ------------------------------------------------- | --------------------------------------------------------------------- |
| `--format=esm\|cjs\|iife\|umd\|amd`               | Module format (default: `esm`)                                        |
| `--platform=browser\|node\|neutral\|react-native` | Target platform                                                       |
| `--rn-platform=ios\|android`                      | RN sub-platform (`.ios.*`/`.android.*` extensions)                    |
| `--target=<spec>`                                 | ES target: `es2015`–`esnext` or engine versions (`chrome80,safari14`) |
| `--runtime-polyfills=auto\|usage\|entry\|off`     | Inject core-js runtime API polyfills. `auto`/`usage` use graph usage  |
| `--runtime-target=<query>`                        | core-js polyfill Browserslist target. Repeatable (`ios_saf 12`)       |
| `--core-js=<version>`                             | core-js version used by core-js-compat                                |
| `--global-name=<name>`                            | IIFE export name                                                      |

## Minify

| Option                              | Description                                                                |
| ----------------------------------- | -------------------------------------------------------------------------- |
| `--minify`                          | Enable all three (shortcut)                                                |
| `--minify-whitespace`               | Whitespace/semicolons/newlines only (debuggable)                           |
| `--minify-syntax`                   | `true`→`!0`, paren removal, constant folding                               |
| `--minify-identifiers`              | Shorten local identifiers                                                  |
| `--keep-names`                      | Preserve function/class `.name`                                            |
| `--charset=utf8`                    | Preserve non-ASCII verbatim (parser only accepts `utf8`)                   |
| `--ascii-only`                      | Non-ASCII → `\uXXXX` (asymmetric — `--charset=ascii` is not accepted)      |
| `--mangle-report=<path>`            | Emit original-to-mangled identifier map JSON (with `--minify-identifiers`) |
| `--quotes=double\|single\|preserve` | String quote style                                                         |
| `--line-limit=<n>`                  | Wrap long output lines at safe token boundaries (`0` disables wrapping)    |

## Source Maps

| Option                    | Description                                                          |
| ------------------------- | -------------------------------------------------------------------- |
| `--sourcemap`             | External `.js.map` with `sourceMappingURL` comment (linked, default) |
| `--sourcemap=linked`      | Explicit linked mode (#2152) — same as above                         |
| `--sourcemap=inline`      | Inline data URL                                                      |
| `--sourcemap=external`    | External file, no comment                                            |
| `--sourcemap-debug-ids`   | Sentry debugId support                                               |
| `--sources-content=false` | Omit `sourcesContent`                                                |
| `--source-root=<path>`    | `sourceRoot` field                                                   |

## Transform / Replace

| Option                   | Description                                                                 |
| ------------------------ | --------------------------------------------------------------------------- |
| `--define:KEY=VALUE`     | Global replace (e.g. `process.env.NODE_ENV` → `"production"`)               |
| `--drop=console`         | Remove `console.*` calls                                                    |
| `--drop=debugger`        | Remove `debugger` statements                                                |
| `--drop-labels=DEV,TEST` | Remove whole labeled statements for matching labels                         |
| `--inject:<path>`        | Auto-inject import (shim)                                                   |
| `--pure:CALL`            | Register a pure call pattern (for example `--pure:React.createElement`)     |
| `--ignore-annotations`   | Ignore tree-shaking annotations such as `/* @__PURE__ */` and `sideEffects` |

## JSX

| Option                                    | Description                                       |
| ----------------------------------------- | ------------------------------------------------- |
| `--jsx=classic\|automatic\|automatic-dev` | JSX runtime                                       |
| `--jsx-dev`                               | `--jsx=automatic-dev` shortcut                    |
| `--jsx-factory=<fn>`                      | Classic factory (default: `React.createElement`)  |
| `--jsx-fragment=<fn>`                     | Classic Fragment                                  |
| `--jsx-import-source=<pkg>`               | Automatic import source (default: `react`)        |
| `--jsx-in-js`                             | Allow JSX parsing in `.js` files                  |
| `--jsx-side-effects`                      | Preserve unused JSX expressions as side-effectful |

## TypeScript

| Option                                         | Description                                                                  |
| ---------------------------------------------- | ---------------------------------------------------------------------------- |
| `-p, --project <path>, --tsconfig-path <path>` | tsconfig.json path/directory                                                 |
| `--experimental-decorators`                    | Legacy decorator (`__decorateClass`)                                         |
| `--emit-decorator-metadata`                    | Emit decorator metadata (requires `experimentalDecorators`, JS-wrapper-only) |
| `--use-define-for-class-fields=false\|true`    | Class field semantics                                                        |
| `--verbatim-module-syntax`                     | Preserve TS `verbatimModuleSyntax` imports/exports                           |
| `--tsconfig-raw=<json>`                        | Inline tsconfig JSON string, compatible with esbuild `tsconfigRaw`           |

## Flow

| Option   | Description                                            |
| -------- | ------------------------------------------------------ |
| `--flow` | Flow type stripping (auto-detected via `@flow` pragma) |

## Bundle-specific

| Option                             | Description                                                                                                                                    |
| ---------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------- |
| `--bundle`                         | Enable bundle mode                                                                                                                             |
| `--splitting`                      | Code splitting (requires `--outdir`)                                                                                                           |
| `--no-splitting`                   | Disable splitting from config at the CLI layer                                                                                                 |
| `--preserve-modules`               | Per-module output (library build)                                                                                                              |
| `--preserve-modules-root=<dir>`    | Root for output structure                                                                                                                      |
| `--inline-dynamic-imports`         | Absorb dynamic-import targets into the entry chunk (Rollup `inlineDynamicImports`, #2185)                                                      |
| `--output-exports=<mode>`          | CJS/UMD entry export shape — `auto\|named\|default\|none` (Rollup `output.exports`, #2159)                                                     |
| `--entry-names=<pattern>`          | Entry name pattern (`[name]`, `[hash]`)                                                                                                        |
| `--chunk-names=<pattern>`          | Chunk name pattern                                                                                                                             |
| `--asset-names=<pattern>`          | Asset name pattern                                                                                                                             |
| `--loader:.ext=type`               | Loader by extension (`file\|dataurl\|base64\|text\|binary\|copy\|empty\|json\|css\|js\|ts\|jsx\|tsx`)                                          |
| `--metafile` / `--metafile=<path>` | Build meta JSON (stdout or file)                                                                                                               |
| `--analyze`                        | Bundle analysis report (printed to stderr). Pair with `--metafile=<path>` to also write JSON to disk; upload it at [/analyze/](/zntc/analyze/) |
| `--legal-comments=<mode>`          | License comments: `none\|inline\|eof\|linked\|external` (`linked`/`external` currently fall back to `eof`)                                     |
| `--packages=external`              | Treat all bare package imports as external                                                                                                     |
| `--banner:js=<text>`               | Prepend text (the bare `--banner=` form is JS-wrapper-only)                                                                                    |
| `--footer:js=<text>`               | Append text (the bare `--footer=` form is JS-wrapper-only)                                                                                     |
| `--intro=<text>`                   | Prepend wrapper-internal bundle text (JS-wrapper-only — native parser does not accept it)                                                      |
| `--outro=<text>`                   | Append wrapper-internal bundle text (JS-wrapper-only — native parser does not accept it)                                                       |
| `--global:FROM=TO`                 | Map an IIFE/UMD external specifier to a global variable name                                                                                   |
| `--global-identifier=<name>`       | Reserve a global identifier during scope hoisting (repeatable)                                                                                 |
| `--polyfill=<path>`                | Run-on-startup polyfill module path (repeatable, resolved to absolute path)                                                                    |
| `--run-before-main=<path>`         | Module to execute right before the entry module (repeatable, resolved to absolute path)                                                        |
| `--public-path=<url>`              | Asset URL prefix                                                                                                                               |
| `--shim-missing-exports`           | Shim missing exports with `undefined`                                                                                                          |

## Resolve

| Option                                  | Description                                                                      |
| --------------------------------------- | -------------------------------------------------------------------------------- |
| `--external <pkg>` / `--external=<pkg>` | Exclude from bundle (repeatable)                                                 |
| `--alias:FROM=TO`                       | Import path alias                                                                |
| `--resolve-extensions=<exts>`           | Extension lookup order (e.g. `.ios.ts,.ts,.js`)                                  |
| `--main-fields=<fields>`                | package.json field order (e.g. `react-native,browser,main`)                      |
| `--conditions=<list>`                   | Add package exports conditions from a CSV list (for example `prod,react-native`) |
| `--node-paths=<list>`                   | Additional bare-specifier lookup paths from a CSV list                           |
| `--preserve-symlinks`                   | Don't resolve symlinks                                                           |

## Watch / Dev Server

| Option                          | Description                                                                                             |
| ------------------------------- | ------------------------------------------------------------------------------------------------------- |
| `-w, --watch`                   | Watch for file changes (incremental rebuild)                                                            |
| `--watch-json`                  | NDJSON event output (for external HMR integration)                                                      |
| `--watch-delay=<ms>`            | Debounce delay                                                                                          |
| `--watch-folder=<dir>`          | Add a directory to watch roots (Metro `watchFolders` compatible, resolved to absolute path, repeatable) |
| `--watch-include=<glob>`        | Whitelist glob for watchFolders scanning (repeatable)                                                   |
| `--watch-exclude=<glob>`        | Exclude glob for watchFolders scanning (repeatable)                                                     |
| `--dev`                         | Enable dev mode (turn on dev-only behavior such as HMR runtime injection)                               |
| `--serve [dir]`                 | Static file server (default: `.`)                                                                       |
| `--port <n>`                    | Server port                                                                                             |
| `--host [addr]`                 | Binding address                                                                                         |
| `--strict-port`                 | Fail instead of falling through to the next port when the requested port is busy                        |
| `--certfile <path>`             | HTTPS certificate file (`preview`/serve)                                                                |
| `--keyfile <path>`              | HTTPS private key file (`preview`/serve)                                                                |
| `--open`                        | Auto-open browser                                                                                       |
| `--proxy /api=http://host:port` | API proxy                                                                                               |

**Dev server external interfaces:** `/sse/events` (SSE build events), `/reset-cache` (Control API), `/mcp` (Model Context Protocol — for LLM agents like Claude Code).

## Plugins / Execution

| Option                      | Description                                                  |
| --------------------------- | ------------------------------------------------------------ |
| `--plugin <path>`           | JS/TS plugin or config file                                  |
| `--jobs=<n>`                | Parallel thread count                                        |
| `--config <path>`           | Use an explicit `zntc.config.*` instead of auto-discovery    |
| `--workspace-config <path>` | Use an explicit `zntc.workspace.*` instead of auto-discovery |
| `--workspace <name>`        | Select one workspace entry                                   |

## Diagnostics / Logging

| Option                       | Description                                                                               |
| ---------------------------- | ----------------------------------------------------------------------------------------- |
| `--log-level=<level>`        | `silent\|error\|warning\|info\|debug\|verbose`                                            |
| `--log-limit=<n>`            | Max diagnostics shown                                                                     |
| `--profile=<list>`           | Collect profile categories from a CSV list (`all`, `parse`, `transform`, etc.)            |
| `--profile-level=<level>`    | Profile detail level: `summary\|detailed\|per-module\|per-pass`                           |
| `--profile-format=<format>`  | Profile output: `table\|tree\|json\|csv`                                                  |
| `--tokenize[=false]`         | Print scanner tokens instead of generated code                                            |
| `--tokenize-format=<format>` | Token output format: `text\|json`                                                         |
| `--stop-after=<phase>`       | Debug option to stop after a compiler phase (`scan\|parse\|semantic\|transform\|codegen`) |
| `--test262 <dir>`            | Run the Zig Test262 runner                                                                |
| `--allow-overwrite`          | Explicitly permit an output path to overwrite an input file. Blocked by default.          |
| `-h, --help`                 | Show help                                                                                 |

## Benchmark (`zntc bench`)

A subcommand that runs the requested phases N times and prints mean/median/p95/p99/stddev/min/max statistics. Use baseline save/compare for before/after optimization analysis.

| Option                    | Description                                                                                             |
| ------------------------- | ------------------------------------------------------------------------------------------------------- |
| `--phase=<list>`          | Profile categories to measure as a CSV (required, e.g. `parse,transform`). `all`/`none` are not allowed |
| `--iterations=<n>`        | Iteration count (default: 100, must be ≥ 1)                                                             |
| `--warmup=<n>`            | Warmup runs before measured runs (default: 10)                                                          |
| `--save=<path>`           | Save the run as a baseline JSON                                                                         |
| `--compare=<path>`        | Compare against an existing baseline JSON                                                               |
| `--format=<fmt>`          | Output format — `table\|tree\|json\|csv` (default: `table`)                                             |
| `--profile-level=<level>` | Profile detail level (`summary\|detailed\|per-module\|per-pass`)                                        |

```bash
zntc bench --phase=parse,transform --iterations=200 --warmup=20 src/large.ts
zntc bench --phase=parse --save=baseline.json src/main.ts
zntc bench --phase=parse --compare=baseline.json src/main.ts
```

## See Also

- JS API (`@zntc/core`) in `packages/core/index.ts` provides the same options programmatically.
- Surface-level option coverage is listed in the [Options Matrix](/zntc/en/reference/options-matrix/).
- Visualize `--metafile` output on the [Metafile Analyze](/zntc/analyze/) page.
- Use `vite-plugin-zntc` or `vitePlugin()` for the Vite adapter.
- Unsupported options and future plans: [docs/ROADMAP.md](https://github.com/ohah/zntc/blob/main/docs/ROADMAP.md).
