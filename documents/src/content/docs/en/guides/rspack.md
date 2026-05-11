---
title: Rspack / Webpack
description: Replace swc-loader / babel-loader with ZNTC in an Rspack or Webpack project.
---

ZNTC slots into Rspack / Webpack's `swc-loader` / `babel-loader` position via `@zntc/rspack-loader`. The host bundler's entry / plugins / output / dev server stay unchanged — ZNTC only handles `.ts` / `.tsx` / `.jsx` transformations.

## Project layout

```text
my-rspack-app/
├── rspack.config.mjs       # or webpack.config.mjs
├── src/
│   ├── index.ts
│   └── ...
└── package.json
```

## Automatic setup (`zntc-init rspack`)

```bash
# Rspack — auto-detected from package.json's @rspack/* dependencies
npx @zntc/init rspack

# Webpack — force the bundler choice
npx @zntc/init rspack --bundler=webpack
```

What it does:

- Auto-detects the bundler from `@rspack/core` / `@rspack/cli` or `webpack` / `webpack-cli` in `package.json`. If neither is present, you must pass `--bundler`.
- Adds `@zntc/core` and `@zntc/rspack-loader` to dev dependencies.
- Writes a default `rspack.config.mjs` (or `webpack.config.mjs`) if missing.
- If a config already exists, prints manual-patch instructions. Use `--force` to overwrite.

Generated default config (Rspack):

```js
// rspack.config.mjs
export default {
  module: {
    rules: [
      {
        test: /\.(?:tsx?|jsx?)$/,
        exclude: /node_modules/,
        loader: "@zntc/rspack-loader",
        options: {
          transpileOptions: { target: "es2020", jsx: "automatic" },
        },
      },
    ],
  },
};
```

Webpack uses the same rule shape — only the header comment differs.

## Manual setup

Add this rule to your existing `rspack.config` / `webpack.config`:

```js
{
  test: /\.(?:tsx?|jsx?)$/,
  exclude: /node_modules/,
  loader: "@zntc/rspack-loader",
  options: {
    transpileOptions: { target: "es2020", jsx: "automatic" },
  },
},
```

Remove any existing `swc-loader` / `babel-loader` / `ts-loader` rule — ZNTC's loader takes that slot.

## Commands

Use the regular Rspack / Webpack CLI:

```bash
# Rspack
bun rspack build
bun rspack serve

# Webpack
bun webpack build
bun webpack serve
```

## Options & recipes

Detailed `transpileOptions`, `define`, `tsconfig`, and Flow options live in the [`@zntc/rspack-loader` reference](/zntc/en/guides/rspack-loader/).

Common knobs:

- `target` — `es2015` … `esnext`, or engine targets (`chrome80`, `node18`, …).
- `jsx` — `automatic` (React 17+) / `classic` / `automatic-dev`.
- `define` — compile-time replacement, e.g. `process.env.NODE_ENV`.
- `tsconfigCache` — reuses tsconfig across the same dir tree (on by default).

## Known limitations

- ZNTC's loader runs only at transpile / parse time. Chunk splitting, asset modules, and dev-server behavior are decided by the host bundler — ZNTC's bundler-only options (`manualChunks`, tree-shaking, …) have no effect in this mode.
- Mixing ZNTC's native bundler (`zntc --bundle`) and Rspack/Webpack in the same project can produce inconsistent output. Pick one build path.

## See also

- [`@zntc/rspack-loader` reference](/zntc/en/guides/rspack-loader/) — full loader options, peer dependencies, `define`-based env injection, Flow usage.
