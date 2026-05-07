---
title: Quick Start
description: Get started with ZNTC to quickly transpile TypeScript.
---

## Single File Transpile

```bash
# Output to stdout
zntc hello.ts

# Output to file
zntc hello.ts -o hello.js
```

## Directory Transpile

```bash
zntc src/ --outdir dist/
```

## Bundling

```bash
# Single bundle
zntc --bundle src/index.ts -o dist/bundle.js

# Code splitting
zntc --bundle src/index.ts --splitting --outdir dist/

# Library build (preserve module structure)
zntc --bundle src/index.ts --preserve-modules --outdir dist/
```

## Minify

```bash
zntc --bundle src/index.ts -o dist/bundle.js --minify
```

## Source Maps

```bash
zntc --bundle src/index.ts -o dist/bundle.js --sourcemap
```

## Watch Mode

```bash
zntc --bundle src/index.ts -o dist/bundle.js --watch
```

## Dev Server

```bash
# Static file serving
zntc --serve

# Bundle + HMR
zntc --serve --bundle src/index.ts
```

## App Builder

For Vite-style `index.html` apps, use `zntc dev` / `zntc build`.

```html
<!-- index.html -->
<link rel="stylesheet" href="/src/style.css" />
<script type="module" src="/src/main.ts"></script>
```

```bash
# HTML/env/public prepare + bundle + CSS HMR
zntc dev

# write dist/
zntc build
```

If the app root contains `postcss.config.*`, ZNTC applies it to CSS in both dev
and build. Tailwind v4 uses `@tailwindcss/postcss`.
