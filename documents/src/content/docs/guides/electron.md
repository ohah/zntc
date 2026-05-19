---
title: Electron
description: ZNTC 의 dev server 와 CLI 만으로 Electron 앱을 빌드하고 개발하는 예제입니다.
---

ZNTC 는 Electron 전용 통합을 제공하지 않습니다. webpack / rspack 과 동일하게 **main · preload · renderer 세 진입점을 각각 ZNTC 로 빌드하고 npm script 로 묶는 방식** 입니다. renderer 는 ZNTC 자체 dev server 를 그대로 사용하므로 별도 플러그인이 필요 없습니다.

## 프로젝트 구조

```text
my-electron-app/
├── src/
│   ├── main.ts            # Electron main process
│   ├── preload.ts         # contextBridge preload
│   └── renderer/
│       ├── index.html
│       └── app.tsx
├── dist/                  # 빌드 산출물
└── package.json
```

## main · preload (Node · CJS)

`electron` 모듈과 Node 내장 모듈은 external 로 두고, CommonJS 로 emit 합니다.

```jsonc
{
  "scripts": {
    "build:main": "zntc --bundle src/main.ts --platform=node --format=cjs --packages=external -o dist/main.cjs",
    "build:preload": "zntc --bundle src/preload.ts --platform=node --format=cjs --packages=external -o dist/preload.cjs"
  }
}
```

- `--packages=external`: `electron`, Node builtin, `electron-store` 같은 bare import 를 전부 external 로 유지합니다. 런타임에서 Electron 이 직접 require.
- `--format=cjs`: Electron main 은 CJS 가 가장 호환성이 높습니다. (Electron 28+ 의 ESM main 을 쓰시려면 `--format=esm`.)

## renderer (browser · dev server)

renderer 는 일반 SPA 와 동일합니다. ZNTC dev server 로 띄우고, main 의 `BrowserWindow` 가 dev 서버 URL 을 로드합니다.

```jsonc
{
  "scripts": {
    "dev:renderer": "zntc dev src/renderer",
    "build:renderer": "zntc build src/renderer"
  }
}
```

```ts
// src/main.ts
import { app, BrowserWindow } from "electron";
import { join } from "node:path";

const isDev = process.env.NODE_ENV === "development";

app.whenReady().then(() => {
  const win = new BrowserWindow({
    webPreferences: { preload: join(__dirname, "preload.cjs") },
  });

  if (isDev) {
    win.loadURL("http://localhost:12300");
  } else {
    win.loadFile(join(__dirname, "renderer/index.html"));
  }
});
```

## zntc.config.ts 로 묶기 (config 파일 방식)

위처럼 npm script 에 flag 를 길게 나열하는 대신, webpack 의 `webpack.config.ts` 처럼 설정을 파일로 분리할 수 있습니다. `zntc.config.{ts,js,json}` 은 `entryPoints` · `platform` · `format` · `packagesExternal` · `outfile` 을 모두 받습니다.

ZNTC config 는 **파일 하나가 빌드 한 개** 입니다(여러 타깃을 한 파일에 배열로 묶는 형태는 미지원). Electron 은 main · preload · renderer 가 platform/format 이 서로 다르므로, webpack 의 Electron 멀티 config 와 동일하게 **타깃별로 config 파일을 나누고 `--config` 로 지정** 합니다.

```ts
// zntc.main.config.ts
import { defineConfig } from "@zntc/core";

export default defineConfig({
  entryPoints: ["src/main.ts"],
  platform: "node",
  format: "cjs",          // Electron 28+ ESM main 은 "esm"
  packagesExternal: true, // electron · Node builtin 등 bare import 유지
  outfile: "dist/main.cjs",
});
```

```ts
// zntc.preload.config.ts
import { defineConfig } from "@zntc/core";

export default defineConfig({
  entryPoints: ["src/preload.ts"],
  platform: "node",
  format: "cjs",
  packagesExternal: true,
  outfile: "dist/preload.cjs",
});
```

renderer 는 browser 가 기본값이라 별도 config 가 필요 없습니다 — `zntc dev src/renderer` / `zntc build src/renderer` 를 그대로 씁니다.

```jsonc
{
  "scripts": {
    "build:main": "zntc --bundle --config zntc.main.config.ts",
    "build:preload": "zntc --bundle --config zntc.preload.config.ts",
    "build:renderer": "zntc build src/renderer",
    "build": "npm-run-all build:main build:preload build:renderer"
  }
}
```

CLI flag 와 config 를 동시에 주면 CLI 가 이깁니다(scalar override). 예: `zntc --bundle --config zntc.main.config.ts --format=esm` 는 config 의 `cjs` 대신 `esm` 으로 빌드합니다. 함수형 config(`defineConfig(({ mode, env }) => ({ … }))`) 로 dev/prod 분기도 가능합니다.

## 개발 / 프로덕션 스크립트

watch · 재시작 · 동시 실행은 webpack/rspack 의 Electron 가이드와 동일하게 `npm-run-all`, `wait-on`, `nodemon` 등 표준 도구로 구성합니다.

```jsonc
{
  "scripts": {
    "dev:renderer": "zntc dev src/renderer",
    "dev:main": "zntc --bundle src/main.ts --platform=node --format=cjs --packages=external --watch -o dist/main.cjs",
    "dev:preload": "zntc --bundle src/preload.ts --platform=node --format=cjs --packages=external --watch -o dist/preload.cjs",
    "dev:electron": "wait-on tcp:12300 && nodemon --watch dist/main.cjs --watch dist/preload.cjs --exec electron dist/main.cjs",
    "dev": "npm-run-all -p dev:renderer dev:main dev:preload dev:electron",

    "build:main": "zntc --bundle src/main.ts --platform=node --format=cjs --packages=external -o dist/main.cjs",
    "build:preload": "zntc --bundle src/preload.ts --platform=node --format=cjs --packages=external -o dist/preload.cjs",
    "build:renderer": "zntc build src/renderer",
    "build": "npm-run-all build:main build:preload build:renderer",

    "package": "electron-builder"
  }
}
```

renderer 의 HMR 은 ZNTC dev server 가 처리합니다 ([Dev Server](/zntc/guides/dev-server/) 참조). main · preload 는 빌드 산출물이 바뀌면 `nodemon` 이 Electron 프로세스를 재시작합니다.

## 패키징

`electron-builder` 또는 `electron-forge` 의 generic 모드를 그대로 사용하시면 됩니다. ZNTC 의 빌드 산출물은 표준 Node CJS / browser 번들이므로 추가 변환이 필요하지 않습니다.

```jsonc
// package.json — electron-builder 예제
{
  "build": {
    "appId": "com.example.app",
    "files": ["dist/**/*", "package.json"]
  }
}
```

## 참고

- ZNTC 자체로는 main process 변경 시 Electron 자동 재시작 같은 통합 워크플로우를 제공하지 않습니다. 위 `nodemon` 스크립트가 그 역할입니다.
- IPC 타입 sync, `autoUpdater` 같은 Electron 생태계 도구는 ZNTC 와 독립적으로 사용 가능합니다.
