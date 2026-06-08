# @zntc/react-native

English · **[한국어](./README_KO.md)**

> ZNTC React Native platform layer — RN preset + Metro-compatible dev server + Reanimated worklets / Flow / Hermes.

[![npm](https://img.shields.io/npm/v/@zntc/react-native.svg)](https://www.npmjs.com/package/@zntc/react-native)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](https://github.com/ohah/zntc/blob/main/LICENSE)

`@zntc/react-native` adapts the [ZNTC](https://github.com/ohah/zntc) toolchain to React Native. It turns a small user input into Metro-compatible NAPI build options, ships a Metro-compatible HMR dev server, and wires in the RN-specific transforms (Flow, Reanimated worklets, Hermes target) — all built into the ZNTC core, **without Babel**.

What it provides:

- **RN preset** — `buildRnBundleOptions(input)` / `bundleRn(input)` / `watchRn(input)`. RN-specific build options (Hermes/ES5 target, Flow, automatic-dev JSX, worklets, dev mode, Fast Refresh, polyfills, RN prelude banner) are applied automatically.
- **Metro-compatible dev server** — `serveRn(options)` / `buildRnDevServerOptions(input)`. Per-platform watch, HMR bridge over the `/hot` endpoint, and terminal actions, wired together for you.
- **Metro HMR adapter** — `createMetroHmrAdapter()` emits messages compatible with the RN runtime's HMRClient interface (`hmr:update-start` / `hmr:update` / `hmr:update-done` / `hmr:reload` / `hmr:error` / `log`).
- **RN runtime** — `runtime/zntc-hmr-client.cjs`, an HMRClient-compatible client for the RN runtime.
- **Plugin factories** — `createAssetPlugin` / `createBabelPlugin` / `createCodegenPlugin` / `createRequireContextPlugin` / `createMetroResolveRequestPlugin`.
- **RN constants / helpers** — `RN_GLOBAL_IDENTIFIERS` / `tryResolve` / `resolveRnPolyfills`.

Out of scope (handled elsewhere): iOS / Android native build orchestration (`run-android` / `run-ios` / autolinking) belongs to `@react-native-community/cli`.

## Installation

```bash
bun add -D @zntc/react-native @zntc/core
# npm i -D @zntc/react-native @zntc/core
# pnpm add -D @zntc/react-native @zntc/core
```

Some features rely on optional peer packages — install the ones your setup needs:

```bash
bun add -D @babel/core @react-native/babel-preset metro-resolver react-native
```

`@react-native-community/cli-server-api` is required for the dev server's reload / dev-menu broadcasts.

## Usage

### Attaching to an existing React Native CLI project

The simplest path is the scaffolder, which rewrites the `start` / `bundle:*` scripts of an existing RN CLI app to use ZNTC (Metro fallback is preserved):

```bash
npx @zntc/init
```

See the [React Native guide](https://ohah.github.io/zntc/guides/react-native/) for details.

### RN preset — `buildRnBundleOptions`

Convert a small RN input into ZNTC NAPI build options, then run a build:

```ts
import { init, build } from '@zntc/core';
import { buildRnBundleOptions } from '@zntc/react-native';

await init();

const result = await build(
  buildRnBundleOptions({
    entry: '/abs/path/index.ts',
    projectRoot: '/abs/path',
    rnPlatform: 'ios', // 'ios' | 'android'
    dev: false,
    sourcemap: true,
  }),
);
```

`bundleRn(input)` is a one-call shorthand for `build(buildRnBundleOptions(input))`, and `watchRn(input)` starts a watching build.

The preset auto-enables the RN-compatible defaults (Hermes/ES5 target, Flow, worklets, polyfills, RN prelude banner, asset loaders, and so on). In dev mode it additionally enables automatic-dev JSX, Fast Refresh, and the dev-mode runtime. You can layer user overrides on top via `input.override` (dictionaries deep-merge, arrays/primitives replace).

### Metro-compatible dev server — `serveRn`

```ts
import { buildRnDevServerOptions, serveRn } from '@zntc/react-native';

const handle = await serveRn(
  buildRnDevServerOptions({
    bundle: {
      entry: '/abs/path/index.ts',
      projectRoot: '/abs/path',
      rnPlatform: 'ios',
      dev: true,
    },
    port: 8081,
    host: 'localhost',
  }),
);

// handle.url / handle.port — connect the RN app to this server
// await handle.stop(); — graceful shutdown
```

`serveRn` lazily loads `@react-native-community/cli-server-api` and the RN dev middleware, runs a per-platform watching build, serves HMR over `/hot`, and sets up terminal actions (reload / dev menu). The HMR messages are Metro HMRClient-compatible, so the standard RN runtime connects without changes.

## Documentation

- Monorepo: <https://github.com/ohah/zntc>
- Docs: <https://ohah.github.io/zntc>
- React Native guide: <https://ohah.github.io/zntc/guides/react-native/>

## License

MIT
