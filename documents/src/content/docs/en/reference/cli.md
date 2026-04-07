---
title: CLI Reference
description: Complete list of ZTS CLI options
---

## Transpile

```bash
zts <file.ts>                    # -> stdout
zts <file.ts> -o <out.js>       # -> file
zts <dir/> --outdir <out/>      # Recursive directory transpile
zts - < input.ts                # stdin input
```

## Bundle

```bash
zts --bundle <entry.ts>                              # -> stdout
zts --bundle <entry.ts> -o out.js                    # -> file
zts --bundle <entry.ts> --splitting --outdir dist    # Code splitting
zts --bundle <entry.ts> --preserve-modules --outdir dist  # Per-module output
zts --bundle <entry.ts> --plugin zts.config.js       # JS plugin
```

## Common Options

| Option | Description |
|--------|-------------|
| `--format=esm\|cjs\|iife` | Module format |
| `--platform=browser\|node\|neutral\|react-native` | Target platform |
| `--minify` | Minify output |
| `--sourcemap` | Generate source maps |
| `--ascii-only` | Escape non-ASCII to `\uXXXX` |
| `--quotes=double\|single\|preserve` | Quote style |
| `--drop=console` | Remove console.* calls |
| `--drop=debugger` | Remove debugger statements |
| `--define:KEY=VALUE` | Global substitution |
| `--external <pkg>` | Exclude from bundle |
| `--alias:FROM=TO` | Import path alias |
| `--banner:js=<text>` | Prepend text to output |
| `--footer:js=<text>` | Append text to output |
| `--global-name=<name>` | IIFE export variable name |
| `--public-path=<url>` | Asset URL prefix |
| `--out-extension:.js=<ext>` | Change output extension |

## JSX Options

| Option | Description |
|--------|-------------|
| `--jsx=classic\|automatic\|automatic-dev` | JSX runtime |
| `--jsx-dev` | Shorthand for `--jsx=automatic-dev` |
| `--jsx-factory=<fn>` | Classic factory function |
| `--jsx-fragment=<fn>` | Classic Fragment component |
| `--jsx-import-source=<pkg>` | Automatic mode import source |

## Bundle-only Options

| Option | Description |
|--------|-------------|
| `--splitting` | Code splitting |
| `--preserve-modules` | Per-module output |
| `--preserve-modules-root=<dir>` | Output root path |
| `--entry-names=<pattern>` | Entry filename pattern |
| `--chunk-names=<pattern>` | Chunk filename pattern |
| `--asset-names=<pattern>` | Asset filename pattern |
| `--loader:.ext=type` | Per-extension loader |
| `--metafile=<path>` | Build metadata JSON |
| `--analyze` | Bundle analysis output |
| `--legal-comments=<mode>` | License comment handling |
| `--inject:<path>` | Auto-import into all entries |
| `--keep-names` | Preserve function/class .name |
| `--shim-missing-exports` | Provide undefined for missing exports |
| `--resolve-extensions=<exts>` | Extension resolution order |
| `--main-fields=<fields>` | package.json field order |

## React Native Options

| Option | Description |
|--------|-------------|
| `--rn-platform=ios\|android` | RN sub-platform |
| `--flow` | Flow type stripping |

## Dev Server

| Option | Description |
|--------|-------------|
| `--serve [dir]` | Static file server |
| `--port <number>` | Port (default: 12300) |
| `--host [addr]` | Bind address |
| `--open` | Auto-open browser |
| `--proxy /api=http://host:port` | API proxy |

## Other

| Option | Description |
|--------|-------------|
| `-w, --watch` | Watch for file changes |
| `--watch-json` | NDJSON event output |
| `-p, --project <path>` | tsconfig.json path |
| `--experimental-decorators` | Legacy decorators |
| `--use-define-for-class-fields=false` | Class fields to constructor |
| `--log-level=<level>` | Log level |
| `--charset=utf8` | Keep non-ASCII characters |
| `--preserve-symlinks` | Preserve symlinks |
