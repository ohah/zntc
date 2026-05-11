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
