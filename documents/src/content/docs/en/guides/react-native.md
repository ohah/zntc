---
title: React Native
description: Learn how to use ZTS with React Native projects.
---

## Overview

ZTS supports Metro-compatible React Native bundling via the `--platform=react-native` preset.

## Basic Usage

```bash
zts --bundle index.js --platform=react-native -o bundle.js
```

## RN Sub-platform

```bash
# iOS build
zts --bundle index.js --platform=react-native --rn-platform=ios -o bundle.js

# Android build
zts --bundle index.js --platform=react-native --rn-platform=android -o bundle.js
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

ZTS ES5 downleveling produces output compatible with the Hermes engine.

```bash
zts --bundle index.js --platform=react-native --target=hermes0.70 -o bundle.js
```

## Watch + NDJSON

NDJSON event output for integration with external tools:

```bash
zts --bundle index.js --platform=react-native -o bundle.js --watch-json
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
  platform: "react-native",
  blockList: [/\.web\.tsx?$/, "fixtures/.*"],
});
```

## silentConsoleErrorPatterns

Selectively swallow noise like the RN/Expo native immutable global polyfill conflict. Injects a `console.error` setter intercept into the prologue.

- If empty or unset, no wrap is emitted — vanilla RN CLI builds incur 0 dead code.
- Not auto-enabled by the RN preset (the trigger is environment-specific).
- Orthogonal to `entryErrorGuard`.

```ts
defineConfig({
  platform: "react-native",
  silentConsoleErrorPatterns: [
    "^Failed to set polyfill\\.\\s+\\w+\\s+is not configurable\\.?$",
  ],
});
```

## assetRegistry

Metro AssetRegistry module path. Controls RN-style asset wrapping.

- `undefined`: platform preset decides. With `platform: "react-native"` defaults to `react-native/Libraries/Image/AssetRegistry`.
- `string`: wraps as `module.exports = require(path).registerAsset({...})`.
- `false`: disabled (emits a plain URL string export, same as web).

```ts
defineConfig({
  platform: "react-native",
  assetRegistry: "react-native/Libraries/Image/AssetRegistry",
});
```

## watchFolders / watchInclude / watchExclude

Metro `watchFolders` compatibility. Includes directories outside the bundle graph in the watch root.

- `watchFolders: string[]` — absolute or relative paths. Recursively scanned.
- `watchInclude: string[]` — glob whitelist (relative to root).
- `watchExclude: string[]` — glob blacklist (relative to root).

```ts
defineConfig({
  platform: "react-native",
  watchFolders: ["../shared", "../design-tokens"],
  watchInclude: ["**/*.ts", "**/*.tsx"],
  watchExclude: ["**/__tests__/**"],
});
```

## moduleSpecifierMap

Cherry-pick rewriting for `import { x } from 'mod'` (babel-plugin-lodash equivalent). Useful for forcing tree-shaking on large packages in RN.

- Conditions: named specifier only, no alias, not type-only. Otherwise the original import is kept.

```ts
defineConfig({
  platform: "react-native",
  moduleSpecifierMap: { lodash: "lodash/{name}" },
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
  platform: "react-native",
  polyfills: ["react-native/Libraries/Core/InitializeCore.js"],
  runBeforeMain: ["./bootstrap.js"],
  globalIdentifiers: ["__DEV__", "__r", "__d", "__c", "global"],
});
```

## RN-mode option reference

One-line summary of options commonly used on the RN platform. See each option's JSDoc / docs for full behavior.

| Option | Description |
|---|---|
| `workletPluginVersion` | Reanimated worklet `__pluginVersion`. Must match the user's installed `react-native-worklets` version to avoid runtime errors. |
| `codegenTransform` | Replaces `codegenNativeComponent` calls in `*NativeComponent.{js,ts}` with inline view configs. Auto-enabled on the RN platform. |
| `entryErrorGuard` | Wraps entry trigger calls in `try/catch + ErrorUtils.reportFatalError` (Metro `guardedLoadModule` equivalent). Auto-enabled on the RN platform. |
| `strictExecutionOrder` | Downgrades function declarations to in-factory assignments to prevent hoisting (Rolldown equivalent). Auto-enabled on the RN platform. |
| `configurableExports` | Adds `configurable: true` to `Object.defineProperty` (RN/Hermes compatibility). |
| `reactRefresh` | Enables React Fast Refresh. |
| `devMode` | Wraps modules in a `__zts_register()` factory and injects the HMR runtime. |
| `rootDir` | Base path for dev-mode module IDs. |
| `collectModuleCodes` | Collects per-module codes in dev mode (for HMR rebuilds). |
| `workletTransform` | Injects `__workletHash`/`__closure`/`__initData` into "worklet" directive functions. Auto-enabled on the RN platform. |
