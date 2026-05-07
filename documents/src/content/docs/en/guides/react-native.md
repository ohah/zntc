---
title: React Native
description: Learn how to use ZNTC with React Native projects.
---

## Overview

ZNTC supports Metro-compatible React Native bundling via the `--platform=react-native` preset.

## Initialize a React Native CLI Project

Use `@zntc/init` to overlay ZNTC onto an existing React Native CLI project. Expo
project creation/initialization is currently out of scope, and this command does
not create a new native shell. It patches the existing app.

```bash
npx @zntc/init
npx @zntc/init --help
```

Help output:

```text
Usage: zntc-init [react-native] [options]

Overlay ZNTC onto an existing React Native CLI project.

Options:
  --root <dir>               Project root (default: cwd)
  --platform <ios|android>   Default platform for the start script (default: ios)
  --zntc-version <range>     Version range for @zntc packages (default: latest)
  --package-manager <pm>     Install command hint: bun, npm, pnpm, or yarn
  --no-metro-fallback        Do not add Metro fallback scripts
  --force                    Overwrite an existing zntc.config.ts
  --dry-run                  Print planned changes without writing files
  --help, -h                 Show this help message
```

The initializer:

- Adds `@zntc/core` and `@zntc/react-native` dev dependencies to `package.json`.
- Changes the default `start` script to `zntc dev --platform=react-native --rn-platform=<ios|android> index.js`.
- Adds ZNTC RN bundle scripts as `bundle:ios` and `bundle:android`.
- Preserves existing Metro commands as `start:metro`, `bundle:metro:ios`, and `bundle:metro:android` fallback scripts.
- Creates a default `zntc.config.ts` when missing, and does not overwrite an existing file unless `--force` is set.

Key options:

| Option                                     | Description                                                   |
| ------------------------------------------ | ------------------------------------------------------------- |
| `--root <dir>`                             | Project root. Defaults to the current directory               |
| `--platform <ios\|android>`                | Default RN platform for the `start` script. Defaults to `ios` |
| `--zntc-version <range>`                   | Version range for `@zntc/core` and `@zntc/react-native`       |
| `--package-manager <bun\|npm\|pnpm\|yarn>` | Install command hint printed after initialization             |
| `--no-metro-fallback`                      | Do not add `start:metro` / `bundle:metro:*` fallback scripts  |
| `--force`                                  | Overwrite an existing `zntc.config.ts`                        |
| `--dry-run`                                | Print planned changes without writing files                   |
| `--help`, `-h`                             | Show help                                                     |

## Basic Usage

```bash
zntc --bundle index.js --platform=react-native -o bundle.js
```

## RN Sub-platform

```bash
# iOS build
zntc --bundle index.js --platform=react-native --rn-platform=ios -o bundle.js

# Android build
zntc --bundle index.js --platform=react-native --rn-platform=android -o bundle.js
```

### Extension Resolution Order

With `--rn-platform=ios`:

```
.ios.tsx -> .ios.ts -> .ios.jsx -> .ios.js ->
.native.tsx -> .native.ts -> .native.jsx -> .native.js ->
.tsx -> .ts -> .jsx -> .js -> .json
```

## Flow Support

Flow is automatically enabled when `--platform=react-native` is set. Type annotations are stripped from files containing the `@flow` pragma.

## main-fields

On the RN platform, `package.json` field resolution order is automatically configured:

```
react-native -> browser -> module -> main
```

## Hermes Compatibility

ZNTC ES5 downleveling produces output compatible with the Hermes engine.

```bash
zntc --bundle index.js --platform=react-native --target=hermes0.70 -o bundle.js
```

## Watch + NDJSON

NDJSON event output for integration with external tools:

```bash
zntc --bundle index.js --platform=react-native -o bundle.js --watch-json
```

```jsonl
{"type":"ready","files":2592,"bytes":123456}
{"type":"rebuild","success":true,"changed":["/src/app.tsx"],"modules":["/src/app.tsx"],"bytes":123456}
```

## blockList

Metro `resolver.blockList` compatibility. Matching absolute paths cause the resolver to fail resolution and exclude them from the graph.

- `RegExp[]` or `string[]` (regex strings). The two forms can be mixed.
- Supported syntax: literals, `.*`, `^`, `$`, `\x` escapes. `|`, `[]`, `()`, `+?`, `\w\d` are not supported.
- With `platform: "react-native"`, Metro defaults (`__tests__`, iOS/Android build folders, etc.) are auto-prepended. User patterns are appended after.

```ts
defineConfig({
  platform: 'react-native',
  blockList: [/\.web\.tsx?$/, 'fixtures/.*'],
});
```

## silentConsoleErrorPatterns

Selectively swallow noise like the RN/Expo native immutable global polyfill conflict. Injects a `console.error` setter intercept into the prologue.

- If empty or unset, no wrap is emitted — vanilla RN CLI builds incur 0 dead code.
- Not auto-enabled by the RN preset (the trigger is environment-specific).
- Orthogonal to `entryErrorGuard`.

```ts
defineConfig({
  platform: 'react-native',
  silentConsoleErrorPatterns: ['^Failed to set polyfill\\.\\s+\\w+\\s+is not configurable\\.?$'],
});
```

## assetRegistry

Metro AssetRegistry module path. Controls RN-style asset wrapping.

- `undefined`: platform preset decides. With `platform: "react-native"` defaults to `react-native/Libraries/Image/AssetRegistry`.
- `string`: wraps as `module.exports = require(path).registerAsset({...})`.
- `false`: disabled (emits a plain URL string export, same as web).

```ts
defineConfig({
  platform: 'react-native',
  assetRegistry: 'react-native/Libraries/Image/AssetRegistry',
});
```

## watchFolders / watchInclude / watchExclude

Metro `watchFolders` compatibility. Includes directories outside the bundle graph in the watch root.

- `watchFolders: string[]` — absolute or relative paths. Recursively scanned.
- `watchInclude: string[]` — glob whitelist (relative to root).
- `watchExclude: string[]` — glob blacklist (relative to root).

```ts
defineConfig({
  platform: 'react-native',
  watchFolders: ['../shared', '../design-tokens'],
  watchInclude: ['**/*.ts', '**/*.tsx'],
  watchExclude: ['**/__tests__/**'],
});
```

## moduleSpecifierMap

Cherry-pick rewriting for `import { x } from 'mod'` (babel-plugin-lodash equivalent). Useful for forcing tree-shaking on large packages in RN.

- Conditions: named specifier only, no alias, not type-only. Otherwise the original import is kept.

```ts
defineConfig({
  platform: 'react-native',
  moduleSpecifierMap: { lodash: 'lodash/{name}' },
});
// import { map } from 'lodash' -> import map from 'lodash/map'
```

## runBeforeMain / polyfills / globalIdentifiers

Pre-main resources that run before the entry module.

- `polyfills: string[]` — executed at the start of the bundle. RN's `InitializeCore` family.
- `runBeforeMain: string[]` — modules to execute right before the entry module.
- `globalIdentifiers: string[]` — identifiers reserved during scope hoisting (RN runtime: `__DEV__`, `__r`, `__d`, `__c`, etc.).

```ts
defineConfig({
  platform: 'react-native',
  polyfills: ['react-native/Libraries/Core/InitializeCore.js'],
  runBeforeMain: ['./bootstrap.js'],
  globalIdentifiers: ['__DEV__', '__r', '__d', '__c', 'global'],
});
```

## RN-mode option reference

One-line summary of options commonly used on the RN platform. See each option's JSDoc / docs for full behavior.

| Option                 | Description                                                                                                                                     |
| ---------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------- |
| `workletPluginVersion` | Reanimated worklet `__pluginVersion`. Must match the user's installed `react-native-worklets` version to avoid runtime errors.                  |
| `codegenTransform`     | Replaces `codegenNativeComponent` calls in `*NativeComponent.{js,ts}` with inline view configs. Auto-enabled on the RN platform.                |
| `entryErrorGuard`      | Wraps entry trigger calls in `try/catch + ErrorUtils.reportFatalError` (Metro `guardedLoadModule` equivalent). Auto-enabled on the RN platform. |
| `strictExecutionOrder` | Downgrades function declarations to in-factory assignments to prevent hoisting (Rolldown equivalent). Auto-enabled on the RN platform.          |
| `configurableExports`  | Adds `configurable: true` to `Object.defineProperty` (RN/Hermes compatibility).                                                                 |
| `reactRefresh`         | Enables React Fast Refresh.                                                                                                                     |
| `devMode`              | Wraps modules in a `__zntc_register()` factory and injects the HMR runtime.                                                                     |
| `rootDir`              | Base path for dev-mode module IDs.                                                                                                              |
| `collectModuleCodes`   | Collects per-module codes in dev mode (for HMR rebuilds).                                                                                       |
| `workletTransform`     | Injects `__workletHash`/`__closure`/`__initData` into "worklet" directive functions. Auto-enabled on the RN platform.                           |

## Dev server (#2605)

`zntc dev --platform=react-native` starts a Metro-compatible dev server.

```bash
zntc dev --platform=react-native --rn-platform=ios index.js \
  --port=8081 --host=localhost
```

Endpoints (Metro compatible):

- `GET /status` — packager live check (`packager-status:running`).
- `GET /index.bundle?platform=ios&dev=true` — main bundle. With `Accept: multipart/mixed`, returns progress + bundle chunks.
- `GET /index.map?platform=ios` — bundle source map (lazy, build-scoped cache).
- `GET /__zntc_hmr_map/<id>?platform=ios` — per-module HMR source map.
- `GET /assets/*`, `/node_modules/*` — asset registry (iOS @2x/@3x scale variants + 7-strategy package resolve).
- `WS /hot` — HMR (`hmr:update-start` → `hmr:update` → `hmr:update-done` / `hmr:reload` / `hmr:error`).
- `POST /symbolicate` — RN runtime LogBox stack trace symbolication.
- `POST /reload` / `POST /devmenu` / `POST /open-url` — Metro message broadcast.

### Peer-optional packages

Some features lazy-load these packages; missing packages skip gracefully:

| Package                                  | Feature                                                                                                                                                      |
| ---------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `@react-native-community/cli-server-api` | `messageSocketEndpoint.broadcast` (`/reload` / `/devmenu` over WS) + cli websocket endpoints (`/message`, `/events`, `/debugger-proxy`).                     |
| `@react-native/dev-middleware`           | DevTools inspector / `/json` / `/open-debugger` / `/launch-js-devtools` / fusebox. **Resolved from project context** to allow Rozenite-style monkey-patches. |

Install (RN 0.83+ recommended):

```bash
bun add -D @react-native-community/cli-server-api @react-native/dev-middleware
```

### Keyboard shortcuts

In the dev server terminal (Metro compatible):

- `r` — Reload
- `d` — Dev Menu
- `j` — DevTools (`POST /open-debugger`)
- `i` — iOS Simulator open (darwin only)
- `a` — Android Emulator open (`ANDROID_HOME` required)
- `c` — Clear cache
- `?` — Help
- Ctrl+C / Ctrl+D — graceful shutdown

### Programmatic API

```ts
import { buildRnDevServerOptions, serveRn } from '@zntc/react-native';

const handle = await serveRn(
  buildRnDevServerOptions({
    bundle: {
      entry: 'index.js',
      projectRoot: process.cwd(),
      rnPlatform: 'ios',
      dev: true,
    },
    port: 8081,
    host: 'localhost',
    // User enhanceMiddleware hook (Rozenite / other DevTools).
    enhanceMiddleware: (base, ctx) => (req, res, next) => {
      if (req.url?.startsWith('/rozenite/')) {
        // Custom handling...
        return;
      }
      base(req, res, next);
    },
    symbolicator: {
      customizeFrame: async (frame) => ({
        // Collapse node_modules frames in DevTools.
        collapse: frame.file?.includes('/node_modules/') ?? false,
      }),
    },
  }),
);

console.log(`Listening on ${handle.url}`);
// ... handle.stop() for graceful shutdown.
```

### Examples

Validation matrix (both use \`bun run start:zntc\` for the ZNTC dev server):

- [`examples/react-native-bare/`](https://github.com/ohah/zntc/tree/main/examples/react-native-bare) — RN 0.85 bare.
- [`examples/react-native-expo/`](https://github.com/ohah/zntc/tree/main/examples/react-native-expo) — Expo 55 / RN 0.83 (Expo Router).

### Compatibility

- RN `>= 0.83` peer optional. `@zntc/react-native` is compatible with Hermes / the RN runtime HMRClient interface and sourceMappingURL route conventions.
- Runs on Bun and Node 22+. Dev-server lifecycle guarantees graceful shutdown on SIGINT/SIGTERM.
