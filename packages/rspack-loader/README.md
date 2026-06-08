# @zntc/rspack-loader

English · **[한국어](./README_KO.md)**

> TypeScript / JSX / Flow loader for Rspack and Webpack — a drop-in replacement for `swc-loader` / `esbuild-loader` / `babel-loader`, powered by ZNTC (a Zig-based native transpiler).

[![npm](https://img.shields.io/npm/v/@zntc/rspack-loader.svg)](https://www.npmjs.com/package/@zntc/rspack-loader)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](https://github.com/ohah/zntc/blob/main/LICENSE)

This loader hands TypeScript / JSX / Flow / decorator transforms to ZNTC, so you can drop it straight into the slot where `builtin:swc-loader`, `esbuild-loader`, or `babel-loader` used to live. The loader API is shared between Rspack and Webpack 5, so the same configuration works on both.

## Installation

```bash
bun add -D @zntc/rspack-loader @zntc/core
# or
npm i -D @zntc/rspack-loader @zntc/core
```

`@zntc/core` (which ships the native NAPI binary) is pulled in as a dependency.

## Usage

### Rspack

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

Drops straight into the slot where you previously used `builtin:swc-loader`.

### Webpack 5

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

The loader API is shared across Webpack and Rspack, so the same code runs on both.

### Options

```ts
interface ZntcLoaderOptions {
  transpileOptions?: Omit<TranspileOptions, 'filename'>;
  tsconfigCache?: boolean;
}
```

#### `tsconfigCache` (default: `true`)

Caches the result of the tsconfig autodiscover walk per worker. In dev / watch sessions, files inside the same workspace are walked only once — saving 5–10 fs syscalls per file. Automatically ignored when `transpileOptions.tsconfigPath` / `tsconfigRaw` is set explicitly.

#### `transpileOptions`

Identical to `TranspileOptions` from `@zntc/core` — only `filename` is filled in automatically by the loader from `this.resourcePath`.

**Target / module**

| Option         | Type                                                 | Description                                         |
| -------------- | ---------------------------------------------------- | --------------------------------------------------- |
| `target`       | `'es5' \| 'es2015' \| ... \| 'es2024' \| 'esnext'`   | ES downlevel target                                 |
| `browserslist` | `string \| string[]`                                 | browserslist query (takes precedence over `target`) |
| `platform`     | `'browser' \| 'node' \| 'neutral' \| 'react-native'` | Target platform                                     |
| `format`       | `'esm' \| 'cjs'`                                     | Module format                                       |

**JSX**

| Option            | Type                                          | Description                                     |
| ----------------- | --------------------------------------------- | ----------------------------------------------- |
| `jsx`             | `'classic' \| 'automatic' \| 'automatic-dev'` | JSX runtime                                     |
| `jsxFactory`      | `string`                                      | classic factory (default `React.createElement`) |
| `jsxFragment`     | `string`                                      | classic Fragment (default `React.Fragment`)     |
| `jsxImportSource` | `string`                                      | automatic import source (default `react`)       |
| `jsxInJs`         | `boolean`                                     | Allow JSX in `.js` files too                    |

**TypeScript / Flow / Decorator**

| Option                    | Type      | Description                                                            |
| ------------------------- | --------- | ---------------------------------------------------------------------- |
| `tsconfigPath`            | `string`  | Path to tsconfig.json (file or directory); compilerOptions auto-merged |
| `tsconfigRaw`             | `string`  | Inline tsconfig JSON string (same semantics as esbuild)                |
| `verbatimModuleSyntax`    | `boolean` | TS 5.0+: do not elide unused imports                                   |
| `useDefineForClassFields` | `boolean` | Transform class fields → constructor `this.x = v` (default: `true`)    |
| `flow`                    | `boolean` | Flow type stripping                                                    |
| `experimentalDecorators`  | `boolean` | Legacy decorator transform                                             |
| `emitDecoratorMetadata`   | `boolean` | Emit decorator metadata                                                |

**Source maps**

| Option              | Type      | Description                                |
| ------------------- | --------- | ------------------------------------------ |
| `sourcemap`         | `boolean` | Generate source maps                       |
| `sourcemapDebugIds` | `boolean` | Sentry-compatible Debug IDs                |
| `sourcesContent`    | `boolean` | Include original sources (default: `true`) |
| `sourceRoot`        | `string`  | source map `sourceRoot` field              |

**Minify**

| Option              | Type      | Description                                    |
| ------------------- | --------- | ---------------------------------------------- |
| `minify`            | `boolean` | whitespace + identifiers + syntax (everything) |
| `minifyWhitespace`  | `boolean` | whitespace only                                |
| `minifyIdentifiers` | `boolean` | identifiers only                               |
| `minifySyntax`      | `boolean` | syntax only                                    |
| `dropConsole`       | `boolean` | Remove `console.*` calls                       |
| `dropDebugger`      | `boolean` | Remove `debugger` statements                   |

**Other**

| Option        | Type                                                          | Description                                   |
| ------------- | ------------------------------------------------------------- | --------------------------------------------- |
| `define`      | `Array<{ key: string; value: string }>`                       | Identifier substitution (`value` is raw JSON) |
| `quotes`      | `'double' \| 'single' \| 'preserve'`                          | String quote style                            |
| `asciiOnly`   | `boolean`                                                     | Escape non-ASCII as `\uXXXX`                  |
| `charsetUtf8` | `boolean`                                                     | Do not escape non-ASCII                       |
| `stopAfter`   | `'scan' \| 'parse' \| 'semantic' \| 'transform' \| 'codegen'` | Debug / profile — skip after the given phase  |

For the full option definitions, see [`@zntc/core` `TranspileOptions`](https://github.com/ohah/zntc/blob/main/packages/shared/index.ts).

### Example — environment variable substitution with `define`

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

### Example — Flow code

```js
{
  test: /\.js$/,
  loader: '@zntc/rspack-loader',
  options: { transpileOptions: { flow: true, jsx: 'automatic' } },
}
```

### Example — explicit tsconfig + decorators

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

### Peer dependencies

- `@rspack/core >= 1.0.0` (optional — both Rspack 1.x and 2.x are supported)
- `webpack >= 5.0.0` (optional)

Installing either one is enough.

## Documentation

- Monorepo: <https://github.com/ohah/zntc>
- Docs site: <https://ohah.github.io/zntc>
- Rspack / Webpack integration guide: <https://ohah.github.io/zntc/guides/rspack-loader/>

## License

MIT
