---
title: React Native + Expo
description: Build and serve Expo / Expo Router projects with ZNTC's withExpo() helper.
---

ZNTC adds Expo / Expo Router support on top of its generic React Native preset via the `withExpo()` helper from `@zntc/react-native`. You keep using Expo for native-shell generation (`expo prebuild`, EAS) — ZNTC only replaces the bundler and dev server.

`@zntc/init`'s automatic setup currently supports only RN CLI projects. Use the manual setup below for Expo; an automatic init adapter is tracked in the [Roadmap](/zntc/en/roadmap/) under "Framework integration — Expo".

## Project layout

```text
my-expo-app/
├── index.js                     # entry — registerRootComponent
├── app/                         # Expo Router routes (if used)
├── ios/                         # produced by expo prebuild
├── android/                     # produced by expo prebuild
├── zntc.config.ts               # ZNTC config — calls withExpo()
├── app.json                     # Expo config (unchanged)
└── package.json
```

## Setup

### package.json scripts

The base RN scripts are identical to the [React Native guide](/zntc/en/guides/react-native/). When using Expo Router, the entry becomes `expo-router/entry`.

```jsonc
{
  "scripts": {
    "start": "zntc dev --platform=react-native --rn-platform=ios index.js",
    "bundle:ios": "zntc --bundle index.js --platform=react-native --rn-platform=ios --minify -o ios/main.jsbundle",
    "bundle:android": "zntc --bundle index.js --platform=react-native --rn-platform=android --minify -o android/app/src/main/assets/index.android.bundle",

    "prebuild": "expo prebuild",
    "ios": "expo run:ios",
    "android": "expo run:android"
  }
}
```

Keep using Expo's CLI for native-shell generation and device runs (`prebuild`, `run:ios`, `run:android`) — ZNTC slots into the bundler / dev-server position only.

### zntc.config.ts

`withExpo()` takes a base RN config and appends Expo-specific options.

```ts
import { dirname } from "node:path";
import { fileURLToPath } from "node:url";

import { withExpo } from "@zntc/react-native";

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);

export default withExpo({
  root: __dirname,
  entry: "index.js", // "expo-router/entry" for Expo Router
  dev: true,
  minify: false,
  transformer: { babel: {} },
  serializer: { polyfills: [], prelude: [] },
  server: {
    port: 8081,
    host: "localhost",
    useGlobalHotkey: true,
    forwardClientLogs: true,
  },
});
```

### What withExpo() adds

It mirrors `@expo/metro-config`'s opt-in pattern. Calling it merges in:

| Area                                | Added                                                                                                                       |
| ----------------------------------- | --------------------------------------------------------------------------------------------------------------------------- |
| `serializer.prelude`                | `expo/winter` (TextEncoderStream / Location polyfill) + `@expo/metro-runtime` (resolved off `expo-router` to guarantee a single instance). |
| `resolver.assetExts`                | `.heic`, `.avif`, `.db` (`expo-image`, `expo-sqlite`).                                                                       |
| `resolver.blockList`                | `.expo/types/**` (generated d.ts).                                                                                          |
| `server.silentConsoleErrorPatterns` | Swallows only the winter polyfill warning emitted when redefining a Hermes `configurable: false` global.                    |

Paths are resolved relative to `config.root`, so unrelated workspace packages that hoist `expo` cannot leak Expo into a plain RN config.

### Your options are preserved

`withExpo()` **appends** to your existing `resolver.assetExts` / `resolver.blockList` / `serializer.prelude` / `server.silentConsoleErrorPatterns`. Duplicate extensions are de-duplicated.

```ts
withExpo({
  // ...
  resolver: {
    assetExts: [".lottie"], // your additions are merged with withExpo's
    blockList: [/\.web\.tsx?$/],
  },
});
```

## Expo Router

Expo Router projects only differ in the `entry` field.

```ts
export default withExpo({
  root: __dirname,
  entry: "expo-router/entry",
  // ... same as above
});
```

When `expo-router` is hoisted or `expo` lives only at the monorepo root, `withExpo` resolves `@expo/metro-runtime` from the `expo-router` `dirname` to keep a single runtime instance.

## Detecting Expo automatically

`detectExpo()` checks whether the project's own `package.json` declares `expo` or `expo-router` as a direct dependency. Hoisted monorepo dependencies do **not** trigger detection (intentional — so unrelated workspaces don't accidentally enter Expo mode).

```ts
import { detectExpo, withExpo } from "@zntc/react-native";

const base = {
  root: __dirname,
  entry: "index.js",
  // ...
};

export default detectExpo(__dirname) ? withExpo(base) : base;
```

## Dev commands

```bash
# 1) one-time — generate the native shell
bun expo prebuild

# 2) ZNTC dev server (sits in Metro's slot)
bun run start

# 3) in another terminal — run on a device
bun expo run:ios     # or run:android
```

iOS / Android build outputs are unchanged, so EAS Build, `expo run:*`, and the dev client (`expo-dev-client`) all work without additional configuration.

## Production bundle

Use ZNTC's bundle command instead of `expo export`.

```bash
zntc --bundle index.js --platform=react-native --rn-platform=ios --minify \
  -o ios/main.jsbundle

zntc --bundle index.js --platform=react-native --rn-platform=android --minify \
  -o android/app/src/main/assets/index.android.bundle
```

EAS Build / `expo run:ios --configuration Release` packages those bundles as-is during the native build.

## Known limitations

- `@zntc/init` automatic setup is RN CLI only. For Expo, use the manual setup above; auto-adapter is tracked in the [Roadmap — Framework integration](/zntc/en/roadmap/).
- `expo export`'s web / PWA output (`--platform web`) is outside the verification matrix. Generic SPA builds still work with `zntc build`.
- Expo Router's filesystem-routing manifest in `app/` is produced by Expo itself; ZNTC only bundles the modules that manifest references.

## Example

- [`examples/react-native-expo/`](https://github.com/ohah/zntc/tree/main/examples/react-native-expo) — Expo 55 / RN 0.83 / Expo Router. Verified with the ZNTC dev server (`bun run start:zntc`) + `expo run:ios`.
