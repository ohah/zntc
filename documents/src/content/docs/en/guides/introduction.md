---
title: Introduction
description: Learn what ZNTC is and why it was built.
---

## What is ZNTC?

ZNTC stands for **Zig Native Transpiler & Compiler**. It is a native-speed transpile and bundling toolchain for JavaScript, TypeScript, and Flow, aiming for production-level quality on par with SWC and oxc.

## Key Features

- **TypeScript/JSX Transpile**: Type stripping, enum conversion, decorators, JSX (classic/automatic)
- **Bundling**: Tree-shaking, code splitting, preserve-modules
- **React Native**: Metro-compatible bundling, Flow stripping, Hermes bytecode compatibility
- **Plugins**: Rollup/Vite-compatible plugin system (C NAPI, in-process)
- **Dev Server**: HMR, proxy, static file serving
- **WASM**: Transpile directly in the browser

## 1st-party transforms, no Babel

Transformations that other bundlers ship as separate Babel plugins or presets are built into ZNTC. A single option enables each one — no `@babel/core` dependency required.

- **styled-components** — `compiler.styledComponents` (replaces `babel-plugin-styled-components`)
- **emotion** — `compiler.emotion` (replaces `@emotion/babel-plugin`)
- **Reanimated worklets** — automatic `"worklet"` directive handling (replaces `react-native-worklets/plugin`; auto-on for React Native)
- **Flow** — type annotations handled in the parser (replaces `@babel/preset-flow`; auto-on for React Native)

See the [Native Transforms guide](/zntc/en/guides/native-transforms/) for full usage.

## Comparison with esbuild

ZNTC is compatible with esbuild's CLI options and behavior while providing a Rollup/Rolldown-style plugin system.

| Feature | ZNTC | esbuild |
|---------|-----|---------|
| Language | Zig | Go |
| TypeScript | O | O |
| Flow | O | X |
| React Native | O | X |
| preserve-modules | O | X |
| Plugin style | Rollup-compatible | esbuild-native |
| WASM | O | O |
