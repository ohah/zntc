---
title: Bundling
description: A detailed guide to ZTS bundling features.
---

## Basic Bundling

```bash
zts --bundle entry.ts -o bundle.js
```

## Output Directory

```bash
zts --bundle entry.ts --outdir dist/
```

## Code Splitting

Splits dynamic imports and shared modules into separate chunks.

```bash
zts --bundle entry.ts --splitting --outdir dist/
```

## Preserve Modules

Preserves the original directory structure for library builds (Rollup/Rolldown compatible).

```bash
zts --bundle src/index.ts --preserve-modules --outdir dist/
zts --bundle src/index.ts --preserve-modules --preserve-modules-root=src --outdir dist/
```

## Platforms

```bash
zts --bundle entry.ts --platform=browser       # Default, IIFE wrapping
zts --bundle entry.ts --platform=node          # Node built-ins are external
zts --bundle entry.ts --platform=react-native  # RN preset
```

### browser (default)

- Defaults to IIFE format when `--format` is not specified
- Automatically defines `process.env.NODE_ENV` as `"production"`
- Replaces Node built-in modules with empty modules

### node

- Automatically externalizes Node built-in modules and their subpaths

### react-native

- Automatically resolves `.native.*` / `.ios.*` / `.android.*` extensions
- `main-fields`: `react-native, browser, module, main`
- Flow is enabled automatically

## External

```bash
zts --bundle entry.ts --external react --external react-dom
```

## Alias

```bash
zts --bundle entry.ts --alias:react=preact/compat
```

## Loader

```bash
zts --bundle entry.ts --loader:.png=file --loader:.svg=dataurl
```

Supported loaders: `js`, `ts`, `json`, `text`, `css`, `file`, `dataurl`, `binary`, `copy`, `empty`

## Filename Patterns

```bash
zts --bundle entry.ts --outdir dist/ \
  --entry-names="[name]-[hash]" \
  --chunk-names="chunks/[name]-[hash]" \
  --asset-names="assets/[name]-[hash]"
```

## Banner / Footer

```bash
zts --bundle entry.ts -o bundle.js \
  --banner:js="/* MIT License */" \
  --footer:js="/* End of bundle */"
```

## Metafile

```bash
zts --bundle entry.ts -o bundle.js --metafile=meta.json
zts --bundle entry.ts -o bundle.js --analyze
```

## Minify

```bash
zts --bundle entry.ts -o bundle.js --minify  # All three

# Granular (esbuild-compatible) — toggle individually
zts --bundle entry.ts -o bundle.js --minify-whitespace
zts --bundle entry.ts -o bundle.js --minify-syntax
zts --bundle entry.ts -o bundle.js --minify-identifiers
```

## ES Target

```bash
# ES version (es2015~esnext)
zts --bundle entry.ts -o bundle.js --target=es2020

# Engine target — feature-level downleveling
zts --bundle entry.ts -o bundle.js --target=chrome80,safari14
zts --bundle entry.ts -o bundle.js --target=node18
zts --bundle entry.ts -o bundle.js --target=hermes0.70
```

## Output Format

```bash
zts --bundle entry.ts --format=esm    # ESM (default)
zts --bundle entry.ts --format=cjs    # CommonJS
zts --bundle entry.ts --format=iife --global-name=MyLib  # IIFE
zts --bundle entry.ts --format=umd --global-name=MyLib   # UMD
zts --bundle entry.ts --format=amd                       # AMD
```

## Watch Mode

```bash
zts --bundle entry.ts -o bundle.js --watch
zts --bundle entry.ts -o bundle.js --watch-json  # NDJSON event output
```
