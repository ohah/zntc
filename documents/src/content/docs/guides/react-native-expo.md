---
title: React Native + Expo
description: Expo / Expo Router 프로젝트에서 ZNTC 의 withExpo() 헬퍼로 빌드하고 dev server 를 띄우는 방법입니다.
---

ZNTC 는 일반 React Native (`--platform=react-native`) 위에 `@zntc/react-native` 의 `withExpo()` 헬퍼를 얹어 Expo 와 Expo Router 프로젝트를 지원합니다. Expo 의 native shell 자동 생성 (`expo prebuild` / EAS) 은 그대로 사용하시고, 번들링 / dev server 부분만 ZNTC 로 대체하는 방식입니다.

`@zntc/init` 의 자동 초기화는 현재 RN CLI 프로젝트만 지원하며, Expo 프로젝트는 아래 수동 설정 예제를 사용해 주세요. 자동 init 어댑터는 [Roadmap](/zntc/roadmap/) 의 "프레임워크 통합 — Expo" 항목에 잡혀 있습니다.

## 프로젝트 구조

```text
my-expo-app/
├── index.js                     # entry — registerRootComponent
├── app/                         # Expo Router 라우트 (사용 시)
├── ios/                         # expo prebuild 산출물
├── android/                     # expo prebuild 산출물
├── zntc.config.ts               # ZNTC 설정 — withExpo() 호출
├── app.json                     # Expo 설정 (그대로 유지)
└── package.json
```

## 설정

### package.json scripts

기본 RN script 는 [React Native 가이드](/zntc/guides/react-native/) 와 동일합니다. Expo Router 를 쓰는 경우 entry 는 `expo-router/entry` 입니다.

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

native shell 생성과 디바이스 실행 (`prebuild`, `run:ios`, `run:android`) 은 Expo 의 CLI 를 그대로 쓰십시오 — ZNTC 는 번들러 / dev server 자리에만 들어갑니다.

### zntc.config.ts

`withExpo()` 가 RN 기본 설정을 받아 Expo 전용 옵션을 자동으로 덧붙입니다.

```ts
import { dirname } from "node:path";
import { fileURLToPath } from "node:url";

import { withExpo } from "@zntc/react-native";

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);

export default withExpo({
  root: __dirname,
  entry: "index.js", // Expo Router 면 "expo-router/entry"
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

## Rozenite DevTools

ZNTC 의 React Native dev server 는 Metro 의 `server.enhanceMiddleware` 형태를 받아들이므로 Rozenite 의 Metro adapter 를 그대로 사용할 수 있습니다. Expo 예제는 `@rozenite/metro` 의 `withRozenite()` 로 `withExpo()` 결과를 한 번 더 감쌉니다.

먼저 필요한 패키지를 dev dependency 로 설치합니다. 사용할 패널만 `include` 에 넣으면 됩니다.

```bash
bun add -D @rozenite/metro \
  @rozenite/controls-plugin \
  @rozenite/expo-atlas-plugin \
  @rozenite/network-activity-plugin \
  @rozenite/react-navigation-plugin \
  @rozenite/redux-devtools-plugin \
  @rozenite/require-profiler-plugin \
  @rozenite/sqlite-plugin \
  @rozenite/storage-plugin \
  @rozenite/tanstack-query-plugin
```

`zntc.config.ts` 예제:

```ts
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import { withRozenite } from "@rozenite/metro";
import { withExpo } from "@zntc/react-native";

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);

const rozenitePlugins = [
  "@rozenite/controls-plugin",
  "@rozenite/expo-atlas-plugin",
  "@rozenite/network-activity-plugin",
  "@rozenite/react-navigation-plugin",
  "@rozenite/redux-devtools-plugin",
  "@rozenite/require-profiler-plugin",
  "@rozenite/sqlite-plugin",
  "@rozenite/storage-plugin",
  "@rozenite/tanstack-query-plugin",
] as const;

const config = withExpo({
  root: __dirname,
  projectRoot: __dirname,
  entry: "index.js",
  dev: true,
  minify: false,
  outDir: join(__dirname, ".zntc"),
  preserveSymlinks: true,
  resolveSymlinkSiblings: true,
  resolver: {
    sourceExts: [".tsx", ".ts", ".jsx", ".js", ".mjs", ".cjs", ".json"],
    assetExts: [".bmp", ".gif", ".jpg", ".jpeg", ".png", ".webp", ".avif", ".ico", ".svg"],
    platforms: ["ios", "android", "native"],
    preferNativePlatform: true,
    nodeModulesPaths: [join(__dirname, "node_modules"), join(__dirname, "../../node_modules")],
  },
  transformer: {
    minifier: "terser",
    inlineRequires: false,
    babel: {},
  },
  serializer: {
    polyfills: [],
    prelude: [],
    bundleType: "plain",
  },
  server: {
    port: 8081,
    host: "localhost",
    useGlobalHotkey: true,
    forwardClientLogs: true,
    verifyConnections: false,
  },
});

export default withRozenite(config as any, {
  enabled: true,
  include: [...rozenitePlugins],
  projectType: "expo",
});
```

### 예제 코드 해설

- `withExpo()` 를 먼저 호출합니다. Expo 전용 prelude, asset 확장자, blockList, console noise 필터가 기본 RN 설정에 병합됩니다.
- `withRozenite()` 는 그 결과 config 를 받아 Rozenite middleware 와 클라이언트 주입 설정을 덧붙입니다. 그래서 export 는 `withRozenite(withExpo(...))` 순서가 됩니다.
- `rozenitePlugins` 는 앱에서 활성화할 Rozenite 패널 목록입니다. 설치하지 않은 플러그인은 `include` 에 넣지 마세요.
- `enabled: true` 는 dev server 에 Rozenite 를 명시적으로 켭니다. 실제 앱 설정에서는 `process.env` 로 개발 환경에서만 켜도록 분기해도 됩니다.
- `projectType: "expo"` 는 Rozenite 가 Expo 프로젝트에 맞는 패널/경로 처리를 선택하게 합니다.
- `projectRoot` 와 `root` 는 예제 앱의 루트를 가리킵니다. monorepo 에서는 `nodeModulesPaths` 에 앱의 `node_modules` 와 workspace 루트 `node_modules` 를 같이 넣으면 hoist 된 패키지도 해석됩니다.
- `preserveSymlinks` 와 `resolveSymlinkSiblings` 는 pnpm/yarn berry 같은 symlink 기반 workspace 에서 패키지 identity 를 유지하면서, 필요한 경우 sibling dependency 를 realpath 기준으로 보완합니다.
- `transformer.minifier`, `transformer.inlineRequires`, `serializer.bundleType`, `server.verifyConnections` 는 Metro config 와 형태를 맞추기 위한 호환 필드입니다. ZNTC dev server 는 아직 일부 필드를 직접 사용하지 않으므로 경고 후 무시할 수 있습니다.
- `serializer.polyfills` / `serializer.prelude` 는 Metro serializer 호환 필드입니다. Rozenite 나 Expo adapter 가 필요한 항목을 병합할 수 있도록 빈 배열로 두어도 됩니다.
- `server.forwardClientLogs` 를 켜면 앱 런타임 로그가 dev server 터미널로 전달되어 Rozenite 패널과 터미널 로그를 함께 확인하기 쉽습니다.

Rozenite UI 는 dev server 가 실행 중일 때 React Native DevTools / Fusebox 경로를 통해 열립니다. ZNTC 는 `/rozenite/*` middleware 경로와 RN DevTools endpoint 를 Metro 호환 형태로 연결합니다.

### metro.config.js 와 함께 쓰기

이미 `metro.config.js` 에 Rozenite 나 Expo 관련 설정을 모아두었다면, 그 파일을 `zntc.config.ts` 에서 불러와 `withExpo()` / `withRozenite()` 순서로 감쌀 수 있습니다.

```ts
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import { withRozenite } from "@rozenite/metro";
import { withExpo } from "@zntc/react-native";

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);

const metroConfigModule = await import("./metro.config.js");
const metroConfigExport = metroConfigModule.default ?? metroConfigModule;
const metroConfig =
  typeof metroConfigExport === "function" ? await metroConfigExport() : await metroConfigExport;

const config = withExpo({
  ...metroConfig,
  root: __dirname,
  projectRoot: __dirname,
  entry: "index.js",
  outDir: join(__dirname, ".zntc"),
  resolver: {
    ...(metroConfig.resolver ?? {}),
    nodeModulesPaths: [
      ...(metroConfig.resolver?.nodeModulesPaths ?? []),
      join(__dirname, "node_modules"),
      join(__dirname, "../../node_modules"),
    ],
  },
  server: {
    ...(metroConfig.server ?? {}),
    port: 8081,
    host: "localhost",
    forwardClientLogs: true,
  },
});

export default withRozenite(config as any, {
  enabled: true,
  include: ["@rozenite/controls-plugin", "@rozenite/require-profiler-plugin"],
  projectType: "expo",
});
```

주의할 점은 `withRozenite()` 를 가장 마지막에 호출하는 것입니다. 그래야 Metro config 또는 `withExpo()` 가 만든 middleware chain 위에 Rozenite endpoint 가 최종적으로 붙습니다.

### withExpo() 가 추가하는 것

`@expo/metro-config` 의 opt-in 패턴을 미러링합니다. 호출 결과로 다음이 자동 병합됩니다.

| 영역                              | 추가                                                                                                                        |
| --------------------------------- | --------------------------------------------------------------------------------------------------------------------------- |
| `serializer.prelude`              | `expo/winter` (TextEncoderStream / Location polyfill) + `@expo/metro-runtime` (Expo Router 시 동일 인스턴스 보장 resolve). |
| `resolver.assetExts`              | `.heic`, `.avif`, `.db` (`expo-image`, `expo-sqlite`).                                                                       |
| `resolver.blockList`              | `.expo/types/**` (generated d.ts).                                                                                          |
| `server.silentConsoleErrorPatterns` | Hermes 의 `configurable: false` global 위에 redefine 시도 → 무해 `console.error` 로 흘리는 winter polyfill warning 만 swallow. |

경로는 `config.root` 를 기준으로 resolve 하므로, monorepo 의 다른 workspace 에 expo 가 hoist 되어 있더라도 vanilla RN config 로 누설되지 않습니다.

### 사용자 옵션은 보존됩니다

`withExpo()` 는 기존 `resolver.assetExts` / `resolver.blockList` / `serializer.prelude` / `server.silentConsoleErrorPatterns` 에 **append** 합니다. 중복 확장자는 자동 제거.

```ts
withExpo({
  // ...
  resolver: {
    assetExts: [".lottie"], // 사용자 정의 → withExpo 가 추가하는 항목과 병합
    blockList: [/\.web\.tsx?$/],
  },
});
```

## Expo Router

Expo Router 프로젝트는 entry 만 다르고, 나머지는 동일합니다.

```ts
export default withExpo({
  root: __dirname,
  entry: "expo-router/entry",
  // ... 위와 동일
});
```

`expo-router` 가 hoist 되었거나 `expo` 가 monorepo 루트에만 있는 경우, `withExpo` 는 `expo-router` 의 `dirname` 을 기준으로 `@expo/metro-runtime` 을 resolve 해 인스턴스 분기를 막습니다.

## Expo 자동 감지

`detectExpo()` 가 프로젝트 `package.json` 의 `dependencies` / `devDependencies` 에 `expo` 또는 `expo-router` 가 직접 선언돼 있는지 확인합니다. monorepo 루트의 hoisted dependency 는 감지에 사용되지 않습니다 (의도 — 관련 없는 workspace 가 우연히 Expo 모드로 빠지지 않도록).

```ts
import { detectExpo, withExpo } from "@zntc/react-native";

const base = {
  root: __dirname,
  entry: "index.js",
  // ...
};

export default detectExpo(__dirname) ? withExpo(base) : base;
```

## 개발 명령

```bash
# 1) 처음 한 번 — native shell 생성
bun expo prebuild

# 2) ZNTC dev server (Metro 자리)
bun run start

# 3) 다른 터미널에서 디바이스 실행
bun expo run:ios     # or run:android
```

iOS / Android 빌드 산출물을 그대로 사용하므로 EAS Build, `expo run:*`, dev client (`expo-dev-client`) 모두 추가 설정 없이 동작합니다.

## 프로덕션 번들

`expo export` 대신 ZNTC 의 bundle 명령을 사용합니다.

```bash
zntc --bundle index.js --platform=react-native --rn-platform=ios --minify \
  -o ios/main.jsbundle

zntc --bundle index.js --platform=react-native --rn-platform=android --minify \
  -o android/app/src/main/assets/index.android.bundle
```

EAS Build / `expo run:ios --configuration Release` 가 native 빌드 시 위 번들 산출물을 그대로 packaging 합니다.

## 알려진 한계

- `@zntc/init` 의 자동 초기화는 RN CLI 만 지원합니다. Expo 는 위 수동 설정을 사용하시고, 향후 자동 어댑터는 [Roadmap — 프레임워크 통합](/zntc/roadmap/) 참조.
- `expo export` (web / PWA) 의 `--platform web` 출력은 별도 검증 매트릭스 밖입니다. 일반 SPA 빌드는 `zntc build` 로 가능합니다.
- Expo Router `app/` 의 파일시스템 routing manifest 는 Expo 가 직접 생성합니다. ZNTC 는 그 manifest 가 가리키는 모듈만 번들합니다.

## 예제

- [`examples/react-native-expo/`](https://github.com/ohah/zntc/tree/main/examples/react-native-expo) — Expo 55 / RN 0.83 / Expo Router. ZNTC dev server (`bun run start:zntc`) + `expo run:ios` 매트릭스로 검증.
