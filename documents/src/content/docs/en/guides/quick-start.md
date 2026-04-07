---
title: Quick Start
description: Get started with ZTS to quickly transpile TypeScript.
---

## Single File Transpile

```bash
# Output to stdout
zts hello.ts

# Output to file
zts hello.ts -o hello.js
```

## Directory Transpile

```bash
zts src/ --outdir dist/
```

## Bundling

```bash
# Single bundle
zts --bundle src/index.ts -o dist/bundle.js

# Code splitting
zts --bundle src/index.ts --splitting --outdir dist/

# Library build (preserve module structure)
zts --bundle src/index.ts --preserve-modules --outdir dist/
```

## Minify

```bash
zts --bundle src/index.ts -o dist/bundle.js --minify
```

## Source Maps

```bash
zts --bundle src/index.ts -o dist/bundle.js --sourcemap
```

## Watch Mode

```bash
zts --bundle src/index.ts -o dist/bundle.js --watch
```

## Dev Server

```bash
# Static file serving
zts --serve

# Bundle + HMR
zts --serve --bundle src/index.ts
```
