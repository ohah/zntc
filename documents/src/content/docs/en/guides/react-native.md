---
title: React Native
description: Build and serve a React Native CLI project with ZNTC.
---

ZNTC ships a `--platform=react-native` preset that emits **Metro-compatible** RN bundles. No extra adapter is required — `zntc dev` / `zntc --bundle` plug straight into an RN CLI project. For Expo projects, see [React Native + Expo](/zntc/en/guides/react-native-expo/).

## Project layout

```text
my-rn-app/
├── index.js                # entry — calls registerRootComponent
├── App.tsx
├── ios/                    # native shell (RN CLI)
├── android/                # native shell (RN CLI)
├── zntc.config.ts          # ZNTC config
└── package.json
```

## Automatic setup (RN CLI projects)

The fastest way to add ZNTC to an existing RN CLI project is `@zntc/init`. It patches `package.json` scripts and writes `zntc.config.ts` — it does not generate a new native shell.

```bash
npx @zntc/init
npx @zntc/init --help
```

What it does:

- Adds `@zntc/core`, `@zntc/react-native` to dev dependencies.
- Replaces `start` with `zntc dev --platform=react-native --rn-platform=<ios|android> index.js`.
- Adds `bundle:ios`, `bundle:android` ZNTC bundle commands.
- Preserves existing Metro commands as `start:metro`, `bundle:metro:ios`, `bundle:metro:android` fallbacks.
- Writes a default `zntc.config.ts` if missing; existing files are not overwritten without `--force`.

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

| Option                                     | Description                                                              |
| ------------------------------------------ | ------------------------------------------------------------------------ |
| `--root <dir>`                             | Project root. Defaults to cwd.                                           |
| `--platform <ios\|android>`                | Default RN platform for the `start` script. Defaults to `ios`.           |
| `--zntc-version <range>`                   | Version range for `@zntc/core` / `@zntc/react-native`.                   |
| `--package-manager <bun\|npm\|pnpm\|yarn>` | Install-command hint printed after init.                                 |
| `--no-metro-fallback`                      | Skip `start:metro` / `bundle:metro:*` fallback scripts.                  |
| `--force`                                  | Overwrite an existing `zntc.config.ts`.                                  |
| `--dry-run`                                | Print planned changes without writing files.                             |
| `--help`, `-h`                             | Show help.                                                               |

## Manual setup

To author the same result yourself, write these two files.

### package.json scripts

```jsonc
{
  "scripts": {
    "start": "zntc dev --platform=react-native --rn-platform=ios index.js",
    "bundle:ios": "zntc --bundle index.js --platform=react-native --rn-platform=ios --minify -o ios/main.jsbundle",
    "bundle:android": "zntc --bundle index.js --platform=react-native --rn-platform=android --minify -o android/app/src/main/assets/index.android.bundle",

    "start:metro": "react-native start",
    "bundle:metro:ios": "react-native bundle --platform ios --entry-file index.js --bundle-output ios/main.jsbundle",
    "bundle:metro:android": "react-native bundle --platform android --entry-file index.js --bundle-output android/app/src/main/assets/index.android.bundle"
  }
}
```

### zntc.config.ts

```ts
import { dirname } from "node:path";
import { fileURLToPath } from "node:url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);

export default {
  root: __dirname,
  entry: "index.js",
  dev: true,
  minify: false,
  transformer: {
    babel: {},
  },
  serializer: {
    polyfills: [],
    prelude: [],
  },
  server: {
    port: 8081,
    host: "localhost",
    useGlobalHotkey: true,
    forwardClientLogs: true,
  },
};
```

## Basic build commands

```bash
# Default (no sub-platform — shared bundle)
zntc --bundle index.js --platform=react-native -o bundle.js

# iOS
zntc --bundle index.js --platform=react-native --rn-platform=ios -o bundle.js

# Android
zntc --bundle index.js --platform=react-native --rn-platform=android -o bundle.js
```

`.ios.*` / `.android.*` extension resolution kicks in once a sub-platform is specified.

### Extension resolution order

With `--rn-platform=ios`:

```
.ios.tsx → .ios.ts → .ios.jsx → .ios.js →
.native.tsx → .native.ts → .native.jsx → .native.js →
.tsx → .ts → .jsx → .js → .json
```

### main-fields

The RN platform sets `package.json` field order automatically:

```
react-native → browser → module → main
```

## Flow / Hermes / Watch

### Flow support

Flow is enabled automatically under `--platform=react-native`. Types are stripped from files with the `@flow` pragma. See [Flow Support](/zntc/en/guides/flow-support/) for details.

### Hermes compatibility

ZNTC's ES5 downleveling produces Hermes-compatible output.

```bash
zntc --bundle index.js --platform=react-native --target=hermes0.70 -o bundle.js
```

### Watch + NDJSON

Stream NDJSON events for external tooling:

```bash
zntc --bundle index.js --platform=react-native -o bundle.js --watch-json
```

```jsonl
{"type":"ready","files":2592,"bytes":123456}
{"type":"rebuild","success":true,"changed":["/src/app.tsx"],"modules":["/src/app.tsx"],"bytes":123456}
```

## Common options

### blockList

Compatible with Metro `resolver.blockList`. Absolute paths matching a pattern are dropped from the graph (the resolver fails them).

- `RegExp[]` or `string[]` (regex strings). Both forms can be mixed.
- Supported syntax: literals, `.*`, `^`, `$`, `\x` escapes. `|`, `[]`, `()`, `+?`, `\w\d` are not.
- Under `platform: "react-native"`, Metro's default patterns (`__tests__`, iOS/Android build folders, …) are prepended; user patterns are appended.

```ts
defineConfig({
  platform: "react-native",
  blockList: [/\.web\.tsx?$/, "fixtures/.*"],
});
```

### silentConsoleErrorPatterns

Selectively swallow noise like RN/Expo native-immutable-global polyfill conflicts. Injects a `console.error` setter intercept into the prologue.

- Empty/unset → the wrapper isn't emitted at all (vanilla RN CLI build pays zero dead code).
- The RN preset does not turn this on automatically (trigger is environment-specific).
- Orthogonal to `entryErrorGuard`.

```ts
defineConfig({
  platform: "react-native",
  silentConsoleErrorPatterns: ["^Failed to set polyfill\\.\\s+\\w+\\s+is not configurable\\.?$"],
});
```

### assetRegistry

Path to Metro's AssetRegistry module. Controls RN-style asset wrapping.

- `undefined`: decided by the platform preset. Under `platform: "react-native"`, defaults to `react-native/Libraries/Image/AssetRegistry`.
- `string`: wraps as `module.exports = require(path).registerAsset({...})`.
- `false`: disabled (asset exports become URL strings, like web).

### watchFolders / watchInclude / watchExclude

Metro `watchFolders` compatible. Adds watch roots that live outside the bundle graph.

```ts
defineConfig({
  platform: "react-native",
  watchFolders: ["../shared", "../design-tokens"],
  watchInclude: ["**/*.ts", "**/*.tsx"],
  watchExclude: ["**/__tests__/**"],
});
```

### moduleSpecifierMap

Cherry-pick rewrite for `import { x } from 'mod'` (equivalent to babel-plugin-lodash). Used to force tree-shaking on large RN packages. Only applies to: named specifiers, no alias, not type-only.

```ts
defineConfig({
  platform: "react-native",
  moduleSpecifierMap: { lodash: "lodash/{name}" },
});
// import { map } from 'lodash' → import map from 'lodash/map'
```

### runBeforeMain / polyfills / globalIdentifiers

Pre-main resources executed before the entry module.

- `polyfills: string[]` — executed first thing in the bundle (e.g. RN's `InitializeCore`).
- `runBeforeMain: string[]` — module paths run right before the entry.
- `globalIdentifiers: string[]` — globals reserved during scope hoisting (RN runtime: `__DEV__`, `__r`, `__d`, `__c`, …).

```ts
defineConfig({
  platform: "react-native",
  polyfills: ["react-native/Libraries/Core/InitializeCore.js"],
  runBeforeMain: ["./bootstrap.js"],
  globalIdentifiers: ["__DEV__", "__r", "__d", "__c", "global"],
});
```

### RN mode option reference

One-line summary of the RN-specific options.

| Option                 | Description                                                                                                                              |
| ---------------------- | ---------------------------------------------------------------------------------------------------------------------------------------- |
| `workletPluginVersion` | Reanimated worklet's `__pluginVersion`. Must match the installed `react-native-worklets` version, or you'll get a runtime error.         |
| `codegenTransform`     | Replaces `codegenNativeComponent(...)` in `*NativeComponent.{js,ts}` with an inline view config. Auto-enabled by the RN platform.        |
| `entryErrorGuard`      | Wraps the entry trigger in `try/catch + ErrorUtils.reportFatalError` (Metro `guardedLoadModule` equivalent). Auto-enabled.               |
| `strictExecutionOrder` | Demotes function declarations to in-factory assignments to prevent hoisting (Rolldown equivalent). Auto-enabled.                         |
| `configurableExports`  | Adds `configurable: true` to `Object.defineProperty` (RN / Hermes compatibility).                                                        |
| `reactRefresh`         | Enables React Fast Refresh.                                                                                                              |
| `devMode`              | Wraps modules in a `__zntc_register()` factory and injects the HMR runtime.                                                              |
| `rootDir`              | Base path for dev-mode module IDs.                                                                                                       |
| `collectModuleCodes`   | Collects per-module code in dev mode (used by HMR rebuilds).                                                                             |
| `workletTransform`     | Injects `__workletHash` / `__closure` / `__initData` into `"worklet"` directive functions. Auto-enabled.                                 |

## Dev server

`zntc dev --platform=react-native` starts a Metro-compatible dev server.

```bash
zntc dev --platform=react-native --rn-platform=ios index.js \
  --port=8081 --host=localhost
```

Endpoints (Metro-compatible):

- `GET /status` — packager liveness check (`packager-status:running`).
- `GET /index.bundle?platform=ios&dev=true` — main bundle. With `multipart/mixed` Accept, returns progress + bundle chunks.
- `GET /index.map?platform=ios` — source map (lazy, per-build cache).
- `GET /__zntc_hmr_map/<id>?platform=ios` — per-module HMR source map.
- `GET /assets/*`, `/node_modules/*` — asset registry (iOS @2x/@3x scale variants + 7-strategy package resolve).
- `WS /hot` — HMR (`hmr:update-start` → `hmr:update` → `hmr:update-done` / `hmr:reload` / `hmr:error`).
- `POST /symbolicate` — reverse-map RN LogBox stack traces.
- `POST /reload` / `POST /devmenu` / `POST /open-url` — emits Metro-compatible messages.

### Optional peer packages

The dev server lazy-loads some features; missing ones degrade gracefully:

| Package                                   | Feature                                                                                                                                              |
| ----------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------- |
| `@react-native-community/cli-server-api`  | `messageSocketEndpoint.broadcast` (`/reload` / `/devmenu` ws) + CLI websocket endpoints (`/message`, `/events`, `/debugger-proxy`).                  |
| `@react-native/dev-middleware`            | DevTools inspector / `/json` / `/open-debugger` / `/launch-js-devtools` / fusebox. Resolved per project — compatible with monkey-patchers like Rozenite. |

Install (recommended on RN 0.83+):

```bash
bun add -D @react-native-community/cli-server-api @react-native/dev-middleware
```

### Keyboard shortcuts

In the dev server terminal (Metro-compatible):

- `r` — Reload
- `d` — Dev Menu
- `j` — DevTools (`POST /open-debugger`)
- `i` — iOS Simulator open (darwin only)
- `a` — Android Emulator open (requires `ANDROID_HOME`)
- `c` — Clear cache
- `?` — Help
- Ctrl+C / Ctrl+D — graceful shutdown

### Programmatic API

```ts
import { buildRnDevServerOptions, serveRn } from "@zntc/react-native";

const handle = await serveRn(
  buildRnDevServerOptions({
    bundle: {
      entry: "index.js",
      projectRoot: process.cwd(),
      rnPlatform: "ios",
      dev: true,
    },
    port: 8081,
    host: "localhost",
    enhanceMiddleware: (base, ctx) => (req, res, next) => {
      if (req.url?.startsWith("/rozenite/")) {
        // user-defined handling...
        return;
      }
      base(req, res, next);
    },
    symbolicator: {
      customizeFrame: async (frame) => ({
        collapse: frame.file?.includes("/node_modules/") ?? false,
      }),
    },
  }),
);

console.log(`Listening on ${handle.url}`);
// ... handle.stop() for graceful shutdown.
```

## Examples

Verification matrix (both use `bun run start:zntc` for the ZNTC dev server):

- [`examples/react-native-bare/`](https://github.com/ohah/zntc/tree/main/examples/react-native-bare) — RN 0.85 bare.
- [`examples/react-native-expo/`](https://github.com/ohah/zntc/tree/main/examples/react-native-expo) — Expo 55 / RN 0.83 (Expo Router).

## Compatibility

- RN `>= 0.83` peer-optional. `@zntc/react-native` matches the Hermes / RN-runtime HMRClient interface and Metro's `sourceMappingURL` route conventions.
- Runs on Bun + Node 22+. Dev-server lifecycle handles SIGINT / SIGTERM with a graceful shutdown.
