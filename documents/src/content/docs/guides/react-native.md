---
title: React Native
description: ZNTC를 React Native 프로젝트에서 사용하는 방법을 알아봅니다.
---

## 개요

ZNTC는 `--platform=react-native` 프리셋으로 Metro 호환 RN 번들링을 지원합니다.

## React Native CLI 프로젝트 초기화

기존 React Native CLI 프로젝트에 ZNTC를 얹을 때는 `@zntc/init`을 사용합니다. Expo
프로젝트 생성/초기화는 현재 범위 밖이며, 이 명령은 native shell을 새로 만들지 않고
기존 앱을 패치합니다.

```bash
npx @zntc/init
npx @zntc/init --help
```

도움말 출력:

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

초기화가 수행하는 작업:

- `package.json`에 `@zntc/core`, `@zntc/react-native` 개발 의존성을 추가합니다.
- 기본 `start`를 `zntc dev --platform=react-native --rn-platform=<ios|android> index.js`로 바꿉니다.
- `bundle:ios`, `bundle:android`에 ZNTC RN bundle 명령을 추가합니다.
- 기존 Metro 명령은 `start:metro`, `bundle:metro:ios`, `bundle:metro:android` fallback으로 보존합니다.
- `zntc.config.ts`가 없으면 기본 RN CLI 설정을 생성하고, 기존 파일은 `--force` 없이는 덮어쓰지 않습니다.

주요 옵션:

| 옵션                                       | 설명                                                             |
| ------------------------------------------ | ---------------------------------------------------------------- |
| `--root <dir>`                             | 프로젝트 루트. 기본값은 현재 디렉터리                            |
| `--platform <ios\|android>`                | `start` script의 기본 RN platform. 기본값은 `ios`                |
| `--zntc-version <range>`                   | 추가할 `@zntc/core` / `@zntc/react-native` 버전 범위             |
| `--package-manager <bun\|npm\|pnpm\|yarn>` | 초기화 후 출력할 install 명령 힌트                               |
| `--no-metro-fallback`                      | `start:metro` / `bundle:metro:*` fallback script를 추가하지 않음 |
| `--force`                                  | 기존 `zntc.config.ts` 덮어쓰기                                   |
| `--dry-run`                                | 파일을 쓰지 않고 변경 계획만 출력                                |
| `--help`, `-h`                             | 도움말 출력                                                      |

## 기본 사용법

```bash
zntc --bundle index.js --platform=react-native -o bundle.js
```

## RN 서브 플랫폼

```bash
# iOS 빌드
zntc --bundle index.js --platform=react-native --rn-platform=ios -o bundle.js

# Android 빌드
zntc --bundle index.js --platform=react-native --rn-platform=android -o bundle.js
```

### 확장자 해석 순서

`--rn-platform=ios` 시:

```
.ios.tsx → .ios.ts → .ios.jsx → .ios.js →
.native.tsx → .native.ts → .native.jsx → .native.js →
.tsx → .ts → .jsx → .js → .json
```

## Flow 지원

`--platform=react-native`일 때 Flow가 자동 활성화됩니다. `@flow` pragma가 있는 파일에서 타입을 스트리핑합니다.

## main-fields

RN 플랫폼에서는 `package.json` 필드 순서가 자동으로 설정됩니다:

```
react-native → browser → module → main
```

## Hermes 호환

ZNTC의 ES5 다운레벨링으로 Hermes 엔진과 호환되는 출력을 생성합니다.

```bash
zntc --bundle index.js --platform=react-native --target=hermes0.70 -o bundle.js
```

## Watch + NDJSON

외부 도구 연동을 위한 NDJSON 이벤트 출력:

```bash
zntc --bundle index.js --platform=react-native -o bundle.js --watch-json
```

```jsonl
{"type":"ready","files":2592,"bytes":123456}
{"type":"rebuild","success":true,"changed":["/src/app.tsx"],"modules":["/src/app.tsx"],"bytes":123456}
```

## blockList

Metro `resolver.blockList` 호환. 매칭되는 절대 경로는 resolver 가 해석 실패시켜 그래프에서 제외한다.

- `RegExp[]` 또는 `string[]` (regex 문자열). 두 형태 혼용 가능.
- 지원 구문: 리터럴, `.*`, `^`, `$`, `\x` 이스케이프. `|`, `[]`, `()`, `+?`, `\w\d` 미지원.
- `platform: "react-native"` 시 Metro 기본 패턴(`__tests__`, iOS/Android 빌드 폴더 등)이 자동 prepend. 사용자 패턴은 그 뒤에 append.

```ts
defineConfig({
  platform: 'react-native',
  blockList: [/\.web\.tsx?$/, 'fixtures/.*'],
});
```

## silentConsoleErrorPatterns

RN/Expo native immutable global polyfill 충돌 같은 noise 만 선택적으로 swallow. Prologue 에 `console.error` setter intercept 를 주입한다.

- 값이 비었거나 미지정이면 wrap 자체를 emit 안 함 — vanilla RN CLI 빌드는 dead code 0.
- RN preset 에서 자동 활성화 안 함 (trigger 가 environment-specific).
- `entryErrorGuard` 와 직교.

```ts
defineConfig({
  platform: 'react-native',
  silentConsoleErrorPatterns: ['^Failed to set polyfill\\.\\s+\\w+\\s+is not configurable\\.?$'],
});
```

## assetRegistry

Metro AssetRegistry 모듈 경로. RN 스타일 asset wrapping 제어.

- `undefined`: 플랫폼 프리셋 결정. `platform: "react-native"` 면 기본 경로 자동 (`react-native/Libraries/Image/AssetRegistry`).
- `string`: 해당 경로의 `registerAsset` 으로 `module.exports = require(path).registerAsset({...})` 래핑.
- `false`: 비활성화 (웹과 동일한 URL 문자열 export).

```ts
defineConfig({
  platform: 'react-native',
  assetRegistry: 'react-native/Libraries/Image/AssetRegistry',
});
```

## watchFolders / watchInclude / watchExclude

Metro `watchFolders` 호환. 번들 그래프 밖 디렉토리도 감시 루트에 추가.

- `watchFolders: string[]` — 절대/상대 경로. 재귀 스캔.
- `watchInclude: string[]` — 루트 기준 상대 경로 glob 화이트리스트.
- `watchExclude: string[]` — 루트 기준 상대 경로 glob 블랙리스트.

```ts
defineConfig({
  platform: 'react-native',
  watchFolders: ['../shared', '../design-tokens'],
  watchInclude: ['**/*.ts', '**/*.tsx'],
  watchExclude: ['**/__tests__/**'],
});
```

## moduleSpecifierMap

`import { x } from 'mod'` cherry-pick 분해 매핑 (babel-plugin-lodash 동등). RN 에서 큰 패키지 트리쉐이킹 강제용.

- 변환 조건: named specifier 만, alias 없음, type-only 아님. 미충족 시 원본 import 유지.

```ts
defineConfig({
  platform: 'react-native',
  moduleSpecifierMap: { lodash: 'lodash/{name}' },
});
// import { map } from 'lodash' → import map from 'lodash/map'
```

## runBeforeMain / polyfills / globalIdentifiers

엔트리 모듈 직전에 실행할 pre-main 자원.

- `polyfills: string[]` — 번들 시작 시 즉시 실행. RN 의 `InitializeCore` 류.
- `runBeforeMain: string[]` — entry 모듈 직전에 실행할 모듈 경로.
- `globalIdentifiers: string[]` — scope hoisting 시 예약할 전역 식별자 (RN runtime: `__DEV__`, `__r`, `__d`, `__c` 등).

```ts
defineConfig({
  platform: 'react-native',
  polyfills: ['react-native/Libraries/Core/InitializeCore.js'],
  runBeforeMain: ['./bootstrap.js'],
  globalIdentifiers: ['__DEV__', '__r', '__d', '__c', 'global'],
});
```

## RN 모드 옵션 레퍼런스

RN 플랫폼에서 자주 쓰는 옵션 한 줄 요약. 자세한 동작은 각 항목 JSDoc / docs 참조.

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

## Dev server (#2605)

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
| `@react-native/dev-middleware`           | DevTools inspector / `/json` / `/open-debugger` / `/launch-js-devtools` / fusebox. **project 기준 resolve** — Rozenite 같은 monkey-patch 도구 호환. |

설치 (RN 0.83+ 권장):

```bash
bun add -D @react-native-community/cli-server-api @react-native/dev-middleware
```

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
    // user enhanceMiddleware hook (Rozenite / 기타 DevTools).
    enhanceMiddleware: (base, ctx) => (req, res, next) => {
      if (req.url?.startsWith('/rozenite/')) {
        // 사용자 정의 처리...
        return;
      }
      base(req, res, next);
    },
    symbolicator: {
      customizeFrame: async (frame) => ({
        // node_modules frame 은 DevTools 에서 collapse.
        collapse: frame.file?.includes('/node_modules/') ?? false,
      }),
    },
  }),
);

console.log(`Listening on ${handle.url}`);
// ... handle.stop() 시 graceful shutdown.
```

### 예제

검증 매트릭스 (둘 다 \`bun run start:zntc\` 로 ZNTC dev server 사용):

- [`examples/react-native-bare/`](https://github.com/ohah/zntc/tree/main/examples/react-native-bare) — RN 0.85 bare.
- [`examples/react-native-expo/`](https://github.com/ohah/zntc/tree/main/examples/react-native-expo) — Expo 55 / RN 0.83 (Expo Router).

### 호환성

- RN `>= 0.83` peer optional. `@zntc/react-native` 가 Hermes / RN runtime 의 HMRClient interface 와 sourceMappingURL 라우트 컨벤션 호환.
- Bun + Node 22+ 에서 동작. dev server lifecycle 은 SIGINT/SIGTERM graceful shutdown 보장.
