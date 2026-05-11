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

`zntc-init` takes a mode as its first argument; for RN it's `react-native` (omitting the mode falls back to `react-native` for backward compatibility). Other modes — `vite`, `rspack`, `web` — are covered by their own guides.

```bash
npx @zntc/init react-native
npx @zntc/init react-native --platform=android
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
Usage: zntc-init <mode> [options]

Modes:
  react-native    Overlay ZNTC onto an existing React Native CLI project
  vite            Overlay ZNTC onto an existing Vite project (@zntc/vite-plugin)
  rspack          Overlay ZNTC onto an existing Rspack/Webpack project (@zntc/rspack-loader)
  web             Scaffold a standalone ZNTC web project (no Vite/Rspack)

Common options:
  --root <dir>                Project root (default: cwd)
  --zntc-version <range>      Version range for @zntc packages (default: latest)
  --package-manager <pm>      Install command hint: bun, npm, pnpm, or yarn
  --force                     Overwrite existing files where the mode allows
  --dry-run                   Print planned changes without writing files
  --help, -h                  Show this help message

react-native options:
  --platform <ios|android>    Default platform for the start script (default: ios)
  --no-metro-fallback         Do not add Metro fallback scripts

rspack options:
  --bundler <rspack|webpack>  Force bundler choice (default: auto-detect)

web options:
  --name <pkg-name>           package.json name field (default: directory name)
  --framework <react|vanilla> Starter template (default: react)
```

### Common options

| Option                                     | Description                                                  |
| ------------------------------------------ | ------------------------------------------------------------ |
| `--root <dir>`                             | Project root. Defaults to cwd.                               |
| `--zntc-version <range>`                   | Version range for the `@zntc/*` packages (default: `latest`).|
| `--package-manager <bun\|npm\|pnpm\|yarn>` | Install-command hint printed after init.                     |
| `--force`                                  | Overwrite existing files where the mode allows.              |
| `--dry-run`                                | Print planned changes without writing files.                 |
| `--help`, `-h`                             | Show help.                                                   |

### react-native mode options

| Option                          | Description                                                    |
| ------------------------------- | -------------------------------------------------------------- |
| `--platform <ios\|android>`     | Default RN platform for the `start` script. Defaults to `ios`. |
| `--no-metro-fallback`           | Skip `start:metro` / `bundle:metro:*` fallback scripts.        |

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

## Metro / `react-native bundle` compatibility flags

`zntc --bundle --platform=react-native` accepts the standard `react-native bundle` (Metro CLI) flags — a dropin layer so you can swap a `react-native bundle ...` call in `package.json` for `zntc --bundle ...`.

| Metro flag | Description |
|---|---|
| `--bundle-output <path>` | Bundle output path (treated like `-o`; used as a fallback when `-o` is not given) |
| `--sourcemap-output <path>` | Source map output path — implies sourcemap when set |
| `--source-map-url <url>` | Value for the trailing `//# sourceMappingURL` (default: the source map file name) |
| `--sourcemap-sources-root <dir>` | Source map `sourceRoot` (same meaning as `--source-root`) |
| `--sourcemap-use-absolute-path` | Use absolute paths for sources in the source map |
| `--assets-dest <dir>` | Destination for copied assets (images/fonts) — in production (not `--dev`) builds the asset loader copies there (iOS 1x/2x/3x, Android `res/`) |
| `--asset-catalog-dest <dir>` | Destination for the iOS asset catalog (`.xcassets`) |
| `--bundle-encoding <utf8\|utf16le\|ascii>` | Bundle file encoding (default `utf-8`) |
| `--reset-cache` | Invalidate the cache on startup |
| `--max-workers <n>` | Parallel worker count — alias of `--jobs` |
| `--unstable-transform-profile <name>` | Hermes transform profile (`hermes-stable`, etc.) |
| `--no-interactive` | Disable terminal interactive actions (Metro UI compat) |
| `--watchFolders <a,b>` | Extra watch roots (Metro's camelCase form, comma-separated) — forwarded to the RN preset's watchFolders. Distinct from the native watcher's `--watch-folder` |
| `--sourceExts <a,b>` | Extra source extensions (Metro's camelCase form, comma-separated) |
| `--rn-project-root <dir>` | The RN preset's projectRoot. Defaults to cwd; set it for monorepo roots |
| `--transform-option key=value` | Metro transformer option (repeatable) — **currently ignored** (Metro graph-bundler only; emits an unsupported-stderr warning) |
| `--resolver-option key=value` | Metro resolver option (repeatable) — **currently ignored** (same) |

> `--transform-option` / `--resolver-option` are accepted for compatibility but have no effect. Customize the Babel transform via `transformer.babel` in `zntc.config.ts`.

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
