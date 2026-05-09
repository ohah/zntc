---
title: Rspack / Webpack integration
description: '@zntc/rspack-loader — drop-in replacement for swc-loader / esbuild-loader / babel-loader in Rspack and Webpack 5.'
---

## Overview

`@zntc/rspack-loader` is a loader that runs source through ZNTC (Zig-based transpiler) instead of `swc-loader`, `esbuild-loader`, or `babel-loader`. It handles TypeScript / JSX / Flow / decorators.

It is a drop-in replacement for `builtin:swc-loader`. Because the loader API is shared between webpack and rspack, the same code runs on both bundlers.

## Install

```bash
bun add -D @zntc/rspack-loader @zntc/core
# or
npm i -D @zntc/rspack-loader @zntc/core
```

`@zntc/core` ships the NAPI binary as a dependency.

## Usage — Rspack

```js
// rspack.config.mjs
export default {
  module: {
    rules: [
      {
        test: /\.(?:tsx?|jsx?)$/,
        exclude: /node_modules/,
        loader: '@zntc/rspack-loader',
        options: {
          transpileOptions: { target: 'es2020', jsx: 'automatic' },
        },
      },
    ],
  },
};
```

## Usage — Webpack 5

```js
// webpack.config.mjs
export default {
  module: {
    rules: [
      {
        test: /\.(?:tsx?|jsx?)$/,
        exclude: /node_modules/,
        use: {
          loader: '@zntc/rspack-loader',
          options: {
            transpileOptions: { target: 'es2020', jsx: 'automatic' },
          },
        },
      },
    ],
  },
};
```

## Options

```ts
interface ZntcLoaderOptions {
  transpileOptions?: Omit<TranspileOptions, 'filename'>;
  tsconfigCache?: boolean;
}
```

### `tsconfigCache` (default: `true`)

Caches the tsconfig autodiscover walk per worker. During dev/watch, files in the same workspace are only walked once — saves 5–10 fs syscalls per file. Automatically ignored when `transpileOptions.tsconfigPath` or `tsconfigRaw` is set.

### `transpileOptions`

Same as `@zntc/core` `TranspileOptions` (the loader fills `filename` from `this.resourcePath`). See the [Transpile Options reference](/zntc/en/reference/options/) or the [`@zntc/core` source](https://github.com/ohah/zntc/blob/main/packages/shared/index.ts) for the full list.

Common options:

| Option                                             | Type                                                 | Description                                  |
| -------------------------------------------------- | ---------------------------------------------------- | -------------------------------------------- |
| `target`                                           | `'es5' \| 'es2015' \| ... \| 'esnext'`               | ES down-level target                         |
| `browserslist`                                     | `string \| string[]`                                 | browserslist query (overrides `target`)      |
| `platform`                                         | `'browser' \| 'node' \| 'neutral' \| 'react-native'` | Target platform                              |
| `format`                                           | `'esm' \| 'cjs'`                                     | Module format                                |
| `jsx`                                              | `'classic' \| 'automatic' \| 'automatic-dev'`        | JSX runtime                                  |
| `jsxImportSource`                                  | `string`                                             | automatic import source (default `react`)    |
| `tsconfigPath`                                     | `string`                                             | Path to tsconfig.json                        |
| `tsconfigRaw`                                      | `string`                                             | Inline tsconfig JSON                         |
| `flow`                                             | `boolean`                                            | Strip Flow types                             |
| `experimentalDecorators` / `emitDecoratorMetadata` | `boolean`                                            | Legacy decorators                            |
| `define`                                           | `Array<{ key, value }>`                              | Identifier replacement (`value` is raw JSON) |
| `sourcemap`                                        | `boolean`                                            | Emit source map                              |
| `minify` / `dropConsole` / `dropDebugger`          | `boolean`                                            | Minification                                 |

## Example — `define` for env replacement

```js
{
  loader: '@zntc/rspack-loader',
  options: {
    transpileOptions: {
      define: [
        { key: 'process.env.NODE_ENV', value: '"production"' },
        { key: '__DEV__', value: 'false' },
      ],
    },
  },
}
```

## Example — Flow

```js
{
  test: /\.js$/,
  loader: '@zntc/rspack-loader',
  options: { transpileOptions: { flow: true, jsx: 'automatic' } },
}
```

## Example — tsconfig + decorators

```js
{
  loader: '@zntc/rspack-loader',
  options: {
    transpileOptions: {
      tsconfigPath: './tsconfig.json',
      experimentalDecorators: true,
      emitDecoratorMetadata: true,
    },
  },
}
```

## Peer

- `@rspack/core >= 1.0.0` (optional, supports rspack 1.x and 2.x)
- `webpack >= 5.0.0` (optional)

Either is fine — only one needs to be installed.

## Relation to builtin loaders

Rspack's `builtin:swc-loader` is compiled into rspack core in Rust, and external packages cannot register under the same prefix. `@zntc/rspack-loader` follows the same JS loader model as `esbuild-loader`, calling the ZNTC native binary through NAPI.

## See also

- [Vite adapter](/zntc/en/guides/dev-server/) — `vite-plugin-zntc`
- [Transpile Options](/zntc/en/reference/options/) — full `TranspileOptions` reference
- [Tool comparison](/zntc/en/guides/comparison/)
