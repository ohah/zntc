# @zntc/init

ZNTC project initializer. 기존 프로젝트에 ZNTC 를 얹거나 (overlay), 새 web 프로젝트를 스캐폴딩 (scaffold) 한다.

```bash
npx @zntc/init <mode> [options]
```

## Modes

| Mode           | 동작     | 대상                                                    |
| -------------- | -------- | ------------------------------------------------------- |
| `react-native` | overlay  | 기존 React Native CLI 프로젝트                          |
| `vite`         | overlay  | 기존 Vite 프로젝트 (`@zntc/vite-plugin`)                |
| `rspack`       | overlay  | 기존 Rspack / Webpack 프로젝트 (`@zntc/rspack-loader`)  |
| `web`          | scaffold | 빈 디렉토리에 ZNTC 단독 web 프로젝트 (Vite/Rspack 없이) |

```bash
npx @zntc/init react-native       # RN overlay (mode 생략 시에도 동일하게 react-native)
npx @zntc/init vite               # Vite plugin 추가
npx @zntc/init rspack             # rspack-loader 추가 (webpack 도 자동 감지)
npx @zntc/init web --framework react   # 새 react 프로젝트 스캐폴딩
```

## Help

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

## Overlay vs scaffold

- **Overlay** (`react-native` / `vite` / `rspack`): 기존 `package.json` 과 빌드 도구 config 를 손대서 ZNTC 로 transform 을 위임한다.
  - `package.json` 에 `@zntc/core` + 모드별 패키지를 `devDependencies` 로 추가
  - 빌드 도구 config 가 **존재하지 않으면** ZNTC 기본 템플릿 생성
  - 빌드 도구 config 가 **이미 존재하면** 덮어쓰지 않고 `manual` 안내 스니펫을 출력 (사용자가 직접 합치도록). `--force` 로 덮어쓰기.
- **Scaffold** (`web`): 빈 디렉토리에 `package.json` / `tsconfig.json` / `zntc.config.ts` / `index.html` / `src/*` 까지 새로 만든다.
  - `package.json` 이 이미 있으면 거부. `--force` 로 덮어쓰기.

모든 모드 공통으로 `--dry-run` 은 파일 변경 없이 plan 만 출력한다.

## react-native 모드

기존 React Native CLI 프로젝트에 ZNTC dev server / bundler 를 얹는다. Metro fallback scripts (`start:metro`, `bundle:metro:*`) 기본 추가. Expo 는 의도적으로 미지원.

## vite 모드

기존 Vite 프로젝트에 [`@zntc/vite-plugin`](../vite-plugin) 을 등록한다 (`esbuild: false`). Vite 의 dev server / HMR / plugin 생태계는 그대로 유지.

## rspack 모드

기존 Rspack / Webpack 프로젝트에 [`@zntc/rspack-loader`](../rspack-loader) 를 등록한다. `package.json` 에 `@rspack/core` 또는 `webpack` 이 있으면 자동 감지. 명시는 `--bundler rspack|webpack` 으로.

## web 모드

Vite / Rspack 없이 ZNTC 자체 dev server (`@zntc/web`) + bundler 만으로 동작하는 web 프로젝트를 만든다. React / vanilla 템플릿 제공. `bun run dev` → `zntc dev`, `bun run build` → `zntc build`, `bun run preview` → `zntc preview`.
