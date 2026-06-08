# @zntc/init

**[English](./README.md)** · 한국어

> 새 ZNTC 프로젝트를 스캐폴딩하거나, 기존 React Native CLI / Vite / Rspack 앱에 ZNTC 를 얹습니다 (overlay).

[![npm](https://img.shields.io/npm/v/@zntc/init.svg)](https://www.npmjs.com/package/@zntc/init)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](https://github.com/ohah/zntc/blob/main/LICENSE)

`@zntc/init` 은 Zig 로 작성된 JavaScript / TypeScript / Flow 트랜스파일러 + 번들러 [ZNTC](https://github.com/ohah/zntc) 의 프로젝트 이니셜라이저입니다. `npx` 로 바로 실행하며 별도 설치가 필요 없습니다. 기존 프로젝트에 ZNTC 를 **overlay** (`package.json` 과 빌드 도구 config 를 손대 transform 을 ZNTC 로 위임) 하거나, 빈 디렉토리에 ZNTC 단독 web 프로젝트를 **scaffold** 할 수 있습니다.

## Usage

```bash
npx @zntc/init <mode> [options]
```

### 모드

| 모드           | 동작     | 대상                                                      |
| -------------- | -------- | --------------------------------------------------------- |
| `react-native` | overlay  | 기존 React Native CLI 프로젝트                            |
| `vite`         | overlay  | 기존 Vite 프로젝트 (`@zntc/vite-plugin`)                  |
| `rspack`       | overlay  | 기존 Rspack / Webpack 프로젝트 (`@zntc/rspack-loader`)    |
| `web`          | scaffold | 빈 디렉토리에 ZNTC 단독 web 프로젝트 (Vite / Rspack 없이) |

```bash
npx @zntc/init react-native            # RN overlay (모드 생략 시에도 동일하게 react-native)
npx @zntc/init vite                    # Vite plugin 추가
npx @zntc/init rspack                  # rspack-loader 추가 (webpack 도 자동 감지)
npx @zntc/init web --framework react   # 새 react 프로젝트 스캐폴딩
```

### Overlay vs scaffold

- **Overlay** (`react-native` / `vite` / `rspack`) — 기존 `package.json` 과 빌드 도구 config 를 손대 transform 을 ZNTC 로 위임합니다.
  - `package.json` 에 `@zntc/core` + 모드별 패키지를 `devDependencies` 로 추가합니다.
  - 빌드 도구 config 가 **존재하지 않으면** ZNTC 기본 템플릿을 생성합니다.
  - 빌드 도구 config 가 **이미 존재하면** 덮어쓰지 않고, 직접 합칠 수 있도록 manual 안내 스니펫을 출력합니다. `--force` 로 덮어쓰기.
- **Scaffold** (`web`) — 빈 디렉토리에 `package.json` / `tsconfig.json` / `zntc.config.ts` / `index.html` / `src/*` 까지 새로 만듭니다.
  - `package.json` 이 이미 있으면 거부합니다. `--force` 로 덮어쓰기.

모든 모드 공통으로 `--dry-run` 은 파일 변경 없이 plan 만 출력합니다.

### 모드별 상세

- **`react-native`** — 기존 React Native CLI 프로젝트에 ZNTC dev server / bundler 를 얹습니다. Metro fallback scripts (`start:metro`, `bundle:metro:*`) 가 기본으로 추가됩니다. Expo 는 의도적으로 미지원입니다.
- **`vite`** — [`@zntc/vite-plugin`](https://github.com/ohah/zntc/tree/main/packages/vite-plugin) 을 등록합니다 (`esbuild: false`). Vite 의 dev server / HMR / plugin 생태계는 그대로 유지됩니다.
- **`rspack`** — [`@zntc/rspack-loader`](https://github.com/ohah/zntc/tree/main/packages/rspack-loader) 를 등록합니다. `package.json` 의 `@rspack/core` 또는 `webpack` 로 번들러를 자동 감지하며, `--bundler rspack|webpack` 으로 명시할 수 있습니다.
- **`web`** — Vite / Rspack 없이 ZNTC 자체 dev server (`@zntc/web`) + bundler 만으로 동작하는 web 프로젝트를 만듭니다. React / vanilla 템플릿을 제공하며, `dev` / `build` / `preview` 스크립트가 `zntc dev` / `zntc build` / `zntc preview` 로 매핑됩니다.

### 옵션

```text
공통 옵션:
  --root <dir>                프로젝트 루트 (기본값: cwd)
  --zntc-version <range>      @zntc 패키지 버전 범위 (기본값: latest)
  --package-manager <pm>      설치 명령 힌트: bun, npm, pnpm, yarn
  --force                     모드가 허용하는 경우 기존 파일 덮어쓰기
  --dry-run                   파일을 쓰지 않고 변경 계획만 출력
  --help, -h                  도움말 출력

react-native 옵션:
  --platform <ios|android>    start 스크립트 기본 플랫폼 (기본값: ios)
  --no-metro-fallback         Metro fallback scripts 추가 안 함

rspack 옵션:
  --bundler <rspack|webpack>  번들러 강제 지정 (기본값: 자동 감지)

web 옵션:
  --name <pkg-name>           package.json name 필드 (기본값: 디렉토리 이름)
  --framework <react|vanilla> 스타터 템플릿 (기본값: react)
```

## Documentation

- 모노레포: <https://github.com/ohah/zntc>
- 공식 문서: <https://ohah.github.io/zntc>
- React Native 가이드: <https://ohah.github.io/zntc/guides/react-native/>

## License

MIT
