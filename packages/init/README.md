# @zntc/init

English · **[한국어](./README_KO.md)**

> Scaffold a new ZNTC project, or overlay ZNTC onto an existing React Native CLI / Vite / Rspack app.

[![npm](https://img.shields.io/npm/v/@zntc/init.svg)](https://www.npmjs.com/package/@zntc/init)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](https://github.com/ohah/zntc/blob/main/LICENSE)

`@zntc/init` is the project initializer for [ZNTC](https://github.com/ohah/zntc), a transpiler and bundler for JavaScript / TypeScript / Flow written in Zig. Run it with `npx` — no install step required. It can either **overlay** ZNTC onto an existing project (rewriting `package.json` and build-tool config to delegate transforms to ZNTC) or **scaffold** a standalone ZNTC web project into an empty directory.

## Usage

```bash
npx @zntc/init <mode> [options]
```

### Modes

| Mode           | Action   | Target                                                               |
| -------------- | -------- | -------------------------------------------------------------------- |
| `react-native` | overlay  | Existing React Native CLI project                                    |
| `vite`         | overlay  | Existing Vite project (`@zntc/vite-plugin`)                          |
| `rspack`       | overlay  | Existing Rspack / Webpack project (`@zntc/rspack-loader`)            |
| `web`          | scaffold | Standalone ZNTC web project in an empty directory (no Vite / Rspack) |

```bash
npx @zntc/init react-native            # RN overlay (also the default when the mode is omitted)
npx @zntc/init vite                    # Add the Vite plugin
npx @zntc/init rspack                  # Add rspack-loader (webpack is auto-detected too)
npx @zntc/init web --framework react   # Scaffold a new React project
```

### Overlay vs scaffold

- **Overlay** (`react-native` / `vite` / `rspack`) — touches your existing `package.json` and build-tool config to delegate transforms to ZNTC.
  - Adds `@zntc/core` plus the mode-specific package to `devDependencies`.
  - If no build-tool config exists, a ZNTC default template is generated.
  - If a build-tool config already exists, it is **not** overwritten — a manual snippet is printed for you to merge yourself. Use `--force` to overwrite.
- **Scaffold** (`web`) — creates a fresh project (`package.json`, `tsconfig.json`, `zntc.config.ts`, `index.html`, `src/*`) in an empty directory.
  - Refuses to run if a `package.json` already exists. Use `--force` to overwrite.

Every mode supports `--dry-run`, which prints the planned changes without writing any files.

### Mode details

- **`react-native`** — overlays the ZNTC dev server / bundler onto an existing React Native CLI project. Metro fallback scripts (`start:metro`, `bundle:metro:*`) are added by default. Expo is intentionally unsupported.
- **`vite`** — registers [`@zntc/vite-plugin`](https://github.com/ohah/zntc/tree/main/packages/vite-plugin) (with `esbuild: false`). Vite's dev server / HMR / plugin ecosystem stays as-is.
- **`rspack`** — registers [`@zntc/rspack-loader`](https://github.com/ohah/zntc/tree/main/packages/rspack-loader). The bundler is auto-detected from `@rspack/core` or `webpack` in `package.json`; override it with `--bundler rspack|webpack`.
- **`web`** — builds a web project that runs on the ZNTC dev server (`@zntc/web`) + bundler alone, without Vite or Rspack. React / vanilla templates are provided, and `dev` / `build` / `preview` scripts map to `zntc dev` / `zntc build` / `zntc preview`.

### Options

```text
Common options:
  --root <dir>                Project root (default: cwd)
  --zntc-version <range>      Version range for @zntc packages (default: latest)
  --package-manager <pm>      Install command hint: bun, npm, pnpm, or yarn
  --force                     Overwrite existing files where the mode allows
  --dry-run                   Print planned changes without writing files
  --help, -h                  Show the help message

react-native options:
  --platform <ios|android>    Default platform for the start script (default: ios)
  --no-metro-fallback         Do not add Metro fallback scripts

rspack options:
  --bundler <rspack|webpack>  Force bundler choice (default: auto-detect)

web options:
  --name <pkg-name>           package.json name field (default: directory name)
  --framework <react|vanilla> Starter template (default: react)
```

## Documentation

- Monorepo: <https://github.com/ohah/zntc>
- Official docs: <https://ohah.github.io/zntc>
- React Native guide: <https://ohah.github.io/zntc/guides/react-native/>

## License

MIT
