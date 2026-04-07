---
title: Introduction
description: Learn what ZTS is and why it was built.
---

## What is ZTS?

ZTS is a **TypeScript/JavaScript transpiler and bundler written in Zig**. It aims for production-level quality on par with SWC and oxc.

## Key Features

- **TypeScript/JSX Transpile**: Type stripping, enum conversion, decorators, JSX (classic/automatic)
- **Bundling**: Tree-shaking, code splitting, preserve-modules
- **React Native**: Metro-compatible bundling, Flow stripping, Hermes bytecode compatibility
- **Plugins**: Rollup/Vite-compatible plugin system (JS/TS subprocess)
- **Dev Server**: HMR, proxy, static file serving
- **WASM**: Transpile directly in the browser

## Comparison with esbuild

ZTS is compatible with esbuild's CLI options and behavior while providing a Rollup/Rolldown-style plugin system.

| Feature | ZTS | esbuild |
|---------|-----|---------|
| Language | Zig | Go |
| TypeScript | O | O |
| Flow | O | X |
| React Native | O | X |
| preserve-modules | O | X |
| Plugin style | Rollup-compatible | esbuild-native |
| WASM | O | O |
