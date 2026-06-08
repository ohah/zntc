# @zntc/web

English · **[한국어](./README_KO.md)**

> ZNTC web platform layer — dev server (HTTP/HTTPS + WebSocket HMR), HMR overlay, postcss / sass / lightningcss CSS pipeline, and dev controller (file watcher + module graph).

[![npm](https://img.shields.io/npm/v/@zntc/web.svg)](https://www.npmjs.com/package/@zntc/web)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](https://github.com/ohah/zntc/blob/main/LICENSE)

`@zntc/web` powers the app-mode side of [ZNTC](https://github.com/ohah/zntc): the `zntc dev` / `zntc preview` / `zntc build` commands. It adds a dev server with WebSocket-based HMR, an error overlay, a CSS pipeline (postcss / sass / lightningcss), and a dev controller that wires a file watcher to the module graph. The `zntc` CLI loads this package automatically, so you rarely import it yourself.

## Installation

```bash
bun add -D @zntc/web
# or
npm i -D @zntc/web
```

`@zntc/core` (which ships the native NAPI binary and the `zntc` CLI) is installed automatically as a dependency.

### Optional — CSS pipeline

```bash
bun add -D postcss postcss-load-config sass
```

- `postcss` / `postcss-load-config` — auto-discovers `postcss.config.{js,ts}` for Tailwind and other PostCSS plugins
- `sass` — handles `.scss` / `.sass` files

These are optional dependencies; install only what your project needs.

## Usage

### Dev server + HMR

In app mode, the `zntc` CLI dynamically imports `@zntc/web` for you — installing the package is all that's required:

```bash
bunx zntc dev       # dev server + HMR
bunx zntc build     # production app build
bunx zntc preview   # production preview server
```

`zntc dev` serves your app over HTTP (or HTTPS when TLS options are set), pushes Hot Module Replacement updates over WebSocket, and surfaces build errors through the HMR overlay in the browser.

### postcss / sass

When the optional CSS packages are installed, the CSS pipeline activates automatically:

- `postcss.config.{js,ts}` is auto-discovered (Tailwind / PostCSS plugins).
- `.scss` / `.sass` files are compiled through `sass`.
- lightningcss handles transforms and minification.

No extra configuration is needed beyond installing the relevant packages.

### Direct import (advanced)

`createAppDevController` is the dev controller's main entry point. It consumes the result of `prepareAppDevSync` from `@zntc/core` and exposes a broad option surface for embedding the dev server in custom tooling. The package also exports a `@zntc/web/css` entry for the CSS pipeline. See the [HMR guide](https://ohah.github.io/zntc) for usage examples.

## Documentation

📚 **Official docs: <https://ohah.github.io/zntc>**

- Monorepo / source: <https://github.com/ohah/zntc>
- Config reference and HMR details are part of the main ZNTC documentation.

Related packages:

- [@zntc/core](https://www.npmjs.com/package/@zntc/core) — transpiler / bundler core
- [@zntc/react-native](https://www.npmjs.com/package/@zntc/react-native) — React Native platform layer
- [@zntc/vite-plugin](https://www.npmjs.com/package/@zntc/vite-plugin) — apply the ZNTC transform when using Vite

## License

MIT
