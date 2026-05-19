---
title: Electron
description: Build and develop Electron apps using ZNTC's dev server and CLI alone.
---

ZNTC ships no Electron-specific integration. Like webpack / rspack, you bundle **main · preload · renderer** as three separate entries with ZNTC and wire them together via npm scripts. The renderer is served by ZNTC's own dev server, so no extra plugin is needed.

## Project layout

```text
my-electron-app/
├── src/
│   ├── main.ts            # Electron main process
│   ├── preload.ts         # contextBridge preload
│   └── renderer/
│       ├── index.html
│       └── app.tsx
├── dist/                  # build output
└── package.json
```

## main · preload (Node · CJS)

Keep `electron` and Node built-ins external; emit as CommonJS.

```jsonc
{
  "scripts": {
    "build:main": "zntc --bundle src/main.ts --platform=node --format=cjs --packages=external -o dist/main.cjs",
    "build:preload": "zntc --bundle src/preload.ts --platform=node --format=cjs --packages=external -o dist/preload.cjs"
  }
}
```

- `--packages=external`: keeps every bare import (`electron`, Node built-ins, `electron-store`, …) external; Electron `require`s them at runtime.
- `--format=cjs`: CJS is the most compatible format for the Electron main process. (Use `--format=esm` if you target Electron 28+ ESM main.)

## renderer (browser · dev server)

The renderer is a plain SPA. Serve it with ZNTC's dev server and have the main process point `BrowserWindow` at it.

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

## Using zntc.config.ts (config file)

Instead of long flag lists in npm scripts, you can split the setup into a file — just like webpack's `webpack.config.ts`. `zntc.config.{ts,js,json}` accepts `entryPoints` · `platform` · `format` · `packagesExternal` · `outfile`.

A ZNTC config is **one file = one build** (bundling multiple targets into a single array-style config is not supported). Since Electron's main · preload · renderer differ in platform/format, split the config per target and select it with `--config` — the same as webpack's multi-config Electron setup.

```ts
// zntc.main.config.ts
import { defineConfig } from "@zntc/core";

export default defineConfig({
  entryPoints: ["src/main.ts"],
  platform: "node",
  format: "cjs",          // "esm" for Electron 28+ ESM main
  packagesExternal: true, // keep electron · Node builtin bare imports external
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

The renderer defaults to `browser`, so it needs no config — keep using `zntc dev src/renderer` / `zntc build src/renderer`.

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

When a CLI flag and config both set the same option, the CLI wins (scalar override). For example, `zntc --bundle --config zntc.main.config.ts --format=esm` builds as `esm` instead of the config's `cjs`. A functional config (`defineConfig(({ mode, env }) => ({ … }))`) lets you branch dev/prod.

## Dev / prod scripts

Watch · restart · concurrent execution is wired with standard tooling (`npm-run-all`, `wait-on`, `nodemon`) — the same pattern as webpack/rspack's Electron guides.

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

Renderer HMR is handled by ZNTC's dev server (see [Dev Server](/zntc/en/guides/dev-server/)). When the main / preload bundles rebuild, `nodemon` restarts the Electron process.

## Packaging

Use `electron-builder` or `electron-forge`'s generic mode as-is — ZNTC's output is plain Node CJS / browser bundles, with no extra transform step required.

```jsonc
// package.json — electron-builder example
{
  "build": {
    "appId": "com.example.app",
    "files": ["dist/**/*", "package.json"]
  }
}
```

## Notes

- ZNTC itself does not auto-restart Electron when the main process rebuilds — the `nodemon` script above plays that role.
- IPC type sync, `autoUpdater`, and other Electron ecosystem tools work independently of ZNTC.
