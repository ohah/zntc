---
title: React Native
description: React Native CLI 프로젝트에서 ZNTC 로 빌드하고 dev server 를 띄우는 방법입니다.
---

ZNTC 는 `--platform=react-native` 프리셋으로 **Metro 호환** RN 번들 출력을 생성합니다. 별도 어댑터 없이 RN CLI 프로젝트에 `zntc dev` / `zntc --bundle` 를 그대로 사용합니다. Expo 프로젝트는 [React Native + Expo](/zntc/guides/react-native-expo/) 참조.

## 프로젝트 구조

```text
my-rn-app/
├── index.js                # entry — registerRootComponent 호출
├── App.tsx
├── ios/                    # native shell (RN CLI)
├── android/                # native shell (RN CLI)
├── zntc.config.ts          # ZNTC 설정
└── package.json
```

## 자동 적용 (RN CLI 프로젝트)

기존 RN CLI 프로젝트에 ZNTC 를 얹는 가장 빠른 방법은 `@zntc/init` 입니다. native shell 을 새로 만들지 않고 `package.json` 의 script 와 `zntc.config.ts` 만 패치합니다.

`zntc-init` 는 모드를 첫 인자로 받으며 RN 은 `react-native` 입니다 (모드를 생략하면 `react-native` 로 동작 — 기존 호환). 다른 모드: `vite`, `rspack`, `web` 은 각 가이드 참조.

```bash
npx @zntc/init react-native
npx @zntc/init react-native --platform=android
npx @zntc/init --help
```

수행 작업:

- `package.json` 에 `@zntc/core`, `@zntc/react-native` 개발 의존성 추가.
- `start` 를 `zntc dev --platform=react-native --rn-platform=<ios|android> index.js` 로 교체.
- `bundle:ios`, `bundle:android` 에 ZNTC RN bundle 명령 추가.
- 기존 Metro 명령은 `start:metro`, `bundle:metro:ios`, `bundle:metro:android` 로 fallback 보존.
- `zntc.config.ts` 가 없으면 기본 RN CLI 설정 생성. 기존 파일은 `--force` 없이는 덮어쓰지 않음.

도움말 출력:

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

### 공통 옵션

| 옵션                                       | 설명                                                       |
| ------------------------------------------ | ---------------------------------------------------------- |
| `--root <dir>`                             | 프로젝트 루트. 기본값은 현재 디렉터리                       |
| `--zntc-version <range>`                   | 추가할 `@zntc/*` 패키지 버전 범위 (기본값: `latest`)         |
| `--package-manager <bun\|npm\|pnpm\|yarn>` | 초기화 후 출력할 install 명령 힌트                          |
| `--force`                                  | 모드가 허용하는 범위에서 기존 파일 덮어쓰기                  |
| `--dry-run`                                | 파일을 쓰지 않고 변경 계획만 출력                            |
| `--help`, `-h`                             | 도움말 출력                                                |

### react-native 모드 옵션

| 옵션                          | 설명                                                              |
| ----------------------------- | ----------------------------------------------------------------- |
| `--platform <ios\|android>`   | `start` script 의 기본 RN platform. 기본값은 `ios`                |
| `--no-metro-fallback`         | `start:metro` / `bundle:metro:*` fallback script 를 추가하지 않음 |

## 수동 적용

자동 init 결과를 직접 작성하려면 다음 두 파일을 만드시면 됩니다.

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

### 기존 metro.config.js 재사용

ZNTC 는 `metro.config.js` 를 자동 탐색하지 않습니다. 기존 Metro 설정을 유지하려면 `zntc.config.ts` 에서 직접 import 한 뒤, ZNTC 가 필요한 entry/server 기본값만 덧붙이세요. Metro config 가 객체를 export 해도 되고, async function 을 export 해도 됩니다.

```ts
import { dirname } from "node:path";
import { fileURLToPath } from "node:url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);

const metroConfigModule = await import("./metro.config.js");
const metroConfigExport = metroConfigModule.default ?? metroConfigModule;
const metroConfig =
  typeof metroConfigExport === "function" ? await metroConfigExport() : await metroConfigExport;

export default {
  ...metroConfig,
  root: __dirname,
  projectRoot: __dirname,
  entry: "index.js",
  dev: true,
  minify: false,
  resolver: {
    ...(metroConfig.resolver ?? {}),
    nodeModulesPaths: [...(metroConfig.resolver?.nodeModulesPaths ?? [])],
  },
  transformer: {
    ...(metroConfig.transformer ?? {}),
    babel: metroConfig.transformer?.babel ?? {},
  },
  serializer: {
    ...(metroConfig.serializer ?? {}),
    polyfills: metroConfig.serializer?.polyfills ?? [],
    prelude: metroConfig.serializer?.prelude ?? [],
  },
  server: {
    ...(metroConfig.server ?? {}),
    port: 8081,
    host: "localhost",
    useGlobalHotkey: true,
    forwardClientLogs: true,
  },
};
```

이 패턴은 Metro config 를 source of truth 로 두면서 ZNTC dev server 를 붙일 때 유용합니다. ZNTC 는 Metro shape 중 `resolver`, `transformer`, `serializer`, `server`, `watchFolders`, `sourcemapSourcesRoot` 를 읽어 RN bundle input 으로 평탄화합니다. 아직 지원하지 않는 Metro 전용 필드는 경고 후 무시될 수 있습니다.

## 기본 빌드 명령

```bash
# 기본 (서브 플랫폼 미지정 — 공통 번들)
zntc --bundle index.js --platform=react-native -o bundle.js

# iOS
zntc --bundle index.js --platform=react-native --rn-platform=ios -o bundle.js

# Android
zntc --bundle index.js --platform=react-native --rn-platform=android -o bundle.js
```

서브 플랫폼이 지정되면 `.ios.*` / `.android.*` extension resolution 이 활성화됩니다.

### 확장자 해석 순서

`--rn-platform=ios` 시:

```
.ios.tsx → .ios.ts → .ios.jsx → .ios.js →
.native.tsx → .native.ts → .native.jsx → .native.js →
.tsx → .ts → .jsx → .js → .json
```

### main-fields

RN 플랫폼에서는 `package.json` 필드 순서가 자동으로 설정됩니다:

```
react-native → browser → module → main
```

## Metro / `react-native bundle` 호환 옵션

`zntc --bundle --platform=react-native` 는 `react-native bundle` (Metro CLI) 의 standard flag 를 그대로 받습니다 — `package.json` 의 `react-native bundle ...` 호출을 `zntc --bundle ...` 로 바꿔도 동작하도록 한 dropin layer 입니다.

| Metro flag | 설명 |
|---|---|
| `--bundle-output <path>` | 번들 출력 경로 (`-o` 와 동일하게 처리, `-o` 미지정 시 fallback) |
| `--sourcemap-output <path>` | 소스맵 출력 경로 — 지정 시 sourcemap 자동 활성 |
| `--source-map-url <url>` | 번들 끝의 `//# sourceMappingURL` 값 (기본: 소스맵 파일명) |
| `--sourcemap-sources-root <dir>` | 소스맵의 `sourceRoot` (`--source-root` 와 동일 의미) |
| `--sourcemap-use-absolute-path` | 소스맵 내 source 경로를 절대 경로로 |
| `--assets-dest <dir>` | 이미지/폰트 등 asset 복사 대상 — production (`--dev` 아님) 빌드에서 asset 로더가 해당 디렉토리로 복사 (iOS 는 1x/2x/3x, Android 는 `res/`) |
| `--asset-catalog-dest <dir>` | iOS asset catalog 대상 — **현재 무시** (받기만 하고 동작 없음, stderr 경고) |
| `--bundle-encoding <utf8\|utf16le\|ascii>` | 번들 파일 인코딩 (기본 `utf-8`) |
| `--reset-cache` | 시작 시 캐시 무효화 |
| `--max-workers <n>` | 병렬 워커 수 — `--jobs` 의 alias |
| `--unstable-transform-profile <name>` | Hermes transform profile — **현재 무시** (받기만 하고 동작 없음, stderr 경고) |
| `--no-interactive` | 터미널 인터랙티브 액션 비활성 (Metro UI 호환) |
| `--watchFolders <a,b>` | 감시 루트 추가 (Metro 의 camelCase 형, comma 구분) — RN preset 의 watchFolders 로 전달. zntc 네이티브 watcher 의 `--watch-folder` 와 별개 |
| `--sourceExts <a,b>` | 추가 소스 확장자 (Metro 의 camelCase 형, comma 구분) |
| `--rn-project-root <dir>` | RN preset 의 projectRoot. 기본 cwd, monorepo root 지정 시 사용 |
| `--transform-option key=value` | Metro transformer 옵션 (반복 가능) — **현재 무시** (Metro graph-bundler 전용, 미지원 stderr 경고만) |
| `--resolver-option key=value` | Metro resolver 옵션 (반복 가능) — **현재 무시** (위와 동일) |

> `--transform-option` / `--resolver-option` 은 호환을 위해 받기만 하고 동작에 반영하지 않습니다. Babel transform 커스터마이징은 `zntc.config.ts` 의 `transformer.babel` 로 하세요.

## Flow / Hermes / Watch

### Flow 지원

`--platform=react-native` 일 때 Flow 가 자동 활성화됩니다. `@flow` pragma 가 있는 파일에서 타입을 스트리핑합니다. 자세한 내용은 [Flow Support](/zntc/guides/flow-support/) 참조.

### Hermes 호환

ZNTC 의 ES5 다운레벨링으로 Hermes 엔진과 호환되는 출력을 생성합니다.

```bash
zntc --bundle index.js --platform=react-native --target=hermes0.70 -o bundle.js
```

### Watch + NDJSON

외부 도구 연동을 위한 NDJSON 이벤트 출력:

```bash
zntc --bundle index.js --platform=react-native -o bundle.js --watch-json
```

```jsonl
{"type":"ready","files":2592,"bytes":123456}
{"type":"rebuild","success":true,"changed":["/src/app.tsx"],"modules":["/src/app.tsx"],"bytes":123456}
```

## 자주 쓰는 옵션

### blockList

Metro `resolver.blockList` 호환. 매칭되는 절대 경로는 resolver 가 해석 실패시켜 그래프에서 제외합니다.

- `RegExp[]` 또는 `string[]` (regex 문자열). 두 형태 혼용 가능.
- 지원 구문: 리터럴, `.*`, `^`, `$`, `\x` 이스케이프. `|`, `[]`, `()`, `+?`, `\w\d` 미지원.
- `platform: "react-native"` 시 Metro 기본 패턴 (`__tests__`, iOS/Android 빌드 폴더 등) 이 자동 prepend. 사용자 패턴은 그 뒤에 append.

```ts
defineConfig({
  platform: "react-native",
  blockList: [/\.web\.tsx?$/, "fixtures/.*"],
});
```

### silentConsoleErrorPatterns

RN/Expo native immutable global polyfill 충돌 같은 noise 만 선택적으로 swallow. Prologue 에 `console.error` setter intercept 를 주입합니다.

- 값이 비었거나 미지정이면 wrap 자체를 emit 안 함 — vanilla RN CLI 빌드는 dead code 0.
- RN preset 에서 자동 활성화 안 함 (trigger 가 environment-specific).
- `entryErrorGuard` 와 직교.

```ts
defineConfig({
  platform: "react-native",
  silentConsoleErrorPatterns: ["^Failed to set polyfill\\.\\s+\\w+\\s+is not configurable\\.?$"],
});
```

### assetRegistry

Metro AssetRegistry 모듈 경로. RN 스타일 asset wrapping 제어.

- `undefined`: 플랫폼 프리셋 결정. `platform: "react-native"` 면 기본 경로 자동 (`react-native/Libraries/Image/AssetRegistry`).
- `string`: 해당 경로의 `registerAsset` 으로 `module.exports = require(path).registerAsset({...})` 래핑.
- `false`: 비활성화 (웹과 동일한 URL 문자열 export).

### watchFolders / watchInclude / watchExclude

Metro `watchFolders` 호환. 번들 그래프 밖 디렉토리도 감시 루트에 추가.

```ts
defineConfig({
  platform: "react-native",
  watchFolders: ["../shared", "../design-tokens"],
  watchInclude: ["**/*.ts", "**/*.tsx"],
  watchExclude: ["**/__tests__/**"],
});
```

### moduleSpecifierMap

`import { x } from 'mod'` cherry-pick 분해 매핑 (babel-plugin-lodash 동등). RN 에서 큰 패키지 트리쉐이킹 강제용. 변환 조건: named specifier 만, alias 없음, type-only 아님.

```ts
defineConfig({
  platform: "react-native",
  moduleSpecifierMap: { lodash: "lodash/{name}" },
});
// import { map } from 'lodash' → import map from 'lodash/map'
```

### runBeforeMain / polyfills / globalIdentifiers

엔트리 모듈 직전에 실행할 pre-main 자원.

- `polyfills: string[]` — 번들 시작 시 즉시 실행. RN 의 `InitializeCore` 류.
- `runBeforeMain: string[]` — entry 모듈 직전에 실행할 모듈 경로.
- `globalIdentifiers: string[]` — scope hoisting 시 예약할 전역 식별자 (RN runtime: `__DEV__`, `__r`, `__d`, `__c` 등).

```ts
defineConfig({
  platform: "react-native",
  polyfills: ["react-native/Libraries/Core/InitializeCore.js"],
  runBeforeMain: ["./bootstrap.js"],
  globalIdentifiers: ["__DEV__", "__r", "__d", "__c", "global"],
});
```

### RN 모드 옵션 레퍼런스

RN 플랫폼에서 자주 쓰는 옵션 한 줄 요약.

| 옵션                   | 설명                                                                                                                              |
| ---------------------- | --------------------------------------------------------------------------------------------------------------------------------- |
| `workletPluginVersion` | Reanimated worklet 의 `__pluginVersion` 값. 사용자 환경 `react-native-worklets` 패키지 버전과 일치해야 런타임 에러 없음.          |
| `codegenTransform`     | `*NativeComponent.{js,ts}` 의 `codegenNativeComponent` 호출을 inline view config 로 교체. RN 플랫폼에서 자동 활성.                |
| `entryErrorGuard`      | entry trigger 호출을 `try/catch + ErrorUtils.reportFatalError` 로 wrap (Metro `guardedLoadModule` 동등). RN 플랫폼에서 자동 활성. |
| `strictExecutionOrder` | 함수 선언을 factory 내부 assignment 로 다운그레이드해 호이스팅 방지 (Rolldown 동등). RN 플랫폼에서 자동 활성.                     |
| `configurableExports`  | `Object.defineProperty` 에 `configurable: true` 추가 (RN/Hermes 호환).                                                            |
| `reactRefresh`         | React Fast Refresh 활성화.                                                                                                        |
| `devMode`              | 모듈을 `__zntc_register()` 팩토리로 래핑 + HMR 런타임 주입.                                                                       |
| `rootDir`              | dev mode 모듈 ID 기준 경로.                                                                                                       |
| `collectModuleCodes`   | dev mode per-module codes 수집 (HMR rebuild 용).                                                                                  |
| `workletTransform`     | "worklet" 디렉티브 함수에 `__workletHash`/`__closure`/`__initData` 주입. RN 플랫폼에서 자동 활성.                                 |

## Dev server

`zntc dev --platform=react-native` 으로 Metro 호환 dev server 를 띄울 수 있습니다.

```bash
zntc dev --platform=react-native --rn-platform=ios index.js \
  --port=8081 --host=localhost
```

엔드포인트 (Metro 호환):

- `GET /status` — packager live check (`packager-status:running`).
- `GET /index.bundle?platform=ios&dev=true` — main bundle. `multipart/mixed` accept 시 progress + bundle chunk.
- `GET /index.map?platform=ios` — bundle source map (lazy, build 단위 cache).
- `GET /__zntc_hmr_map/<id>?platform=ios` — per-module HMR source map.
- `GET /assets/*`, `/node_modules/*` — asset registry (iOS @2x/@3x scale variant + 7-strategy package resolve).
- `WS /hot` — HMR (`hmr:update-start` → `hmr:update` → `hmr:update-done` / `hmr:reload` / `hmr:error`).
- `POST /symbolicate` — RN runtime LogBox stack trace 역매핑.
- `POST /reload` / `POST /devmenu` / `POST /open-url` — Metro 메시지 송출.

### peer optional 패키지

dev server 가 일부 기능에 lazy load. 미설치 시 graceful skip:

| 패키지                                   | 기능                                                                                                                                                |
| ---------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------- |
| `@react-native-community/cli-server-api` | `messageSocketEndpoint.broadcast` (`/reload` / `/devmenu` 메시지 ws) + cli websocket endpoints (`/message`, `/events`, `/debugger-proxy`).          |
| `@react-native/dev-middleware`           | DevTools inspector / `/json` / `/open-debugger` / `/launch-js-devtools` / fusebox. project 기준 resolve — Rozenite 같은 monkey-patch 도구 호환.     |

설치 (RN 0.83+ 권장):

```bash
bun add -D @react-native-community/cli-server-api @react-native/dev-middleware
```

### Rozenite DevTools

Rozenite 는 Metro middleware 를 통해 RN DevTools 에 패널을 추가합니다. ZNTC dev server 는 Metro 의 `server.enhanceMiddleware` 호환 경로를 지원하므로 `@rozenite/metro` 의 `withRozenite()` wrapper 를 `zntc.config.ts` 에 그대로 사용할 수 있습니다.

```ts
import { dirname } from "node:path";
import { fileURLToPath } from "node:url";

import { withRozenite } from "@rozenite/metro";

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);

const config = {
  root: __dirname,
  entry: "index.js",
  server: {
    port: 8081,
    host: "localhost",
    forwardClientLogs: true,
  },
};

export default withRozenite(config as any, {
  enabled: true,
  include: ["@rozenite/controls-plugin", "@rozenite/require-profiler-plugin"],
});
```

더 완전한 Expo 예제와 각 옵션 설명은 [React Native + Expo — Rozenite DevTools](/zntc/guides/react-native-expo/#rozenite-devtools) 를 참조하세요.

### 키보드 단축키

dev server 터미널에서 (Metro 호환):

- `r` — Reload
- `d` — Dev Menu
- `j` — DevTools (`/open-debugger` POST)
- `i` — iOS Simulator open (darwin only)
- `a` — Android Emulator open (`ANDROID_HOME` 필요)
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
        // 사용자 정의 처리...
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
// ... handle.stop() 시 graceful shutdown.
```

## 예제

검증 매트릭스 (둘 다 `bun run start:zntc` 로 ZNTC dev server 사용):

- [`examples/react-native-bare/`](https://github.com/ohah/zntc/tree/main/examples/react-native-bare) — RN 0.85 bare.
- [`examples/react-native-expo/`](https://github.com/ohah/zntc/tree/main/examples/react-native-expo) — Expo 55 / RN 0.83 (Expo Router).

## 호환성

- RN `>= 0.83` peer optional. `@zntc/react-native` 가 Hermes / RN runtime 의 HMRClient interface 와 sourceMappingURL 라우트 컨벤션 호환.
- Node.js 24+ 환경에서 동작하며, Bun 1.3+ 에서도 Node-compatible runtime 으로 사용할 수 있습니다.
- Dev server lifecycle 은 `process` signal handler 기반으로 SIGINT/SIGTERM graceful shutdown 을 처리합니다.
