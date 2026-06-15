# Configuration

ZNTC 의 설정 시스템 — `zntc.config.{ts,js,json}`, `tsconfig.json`, `.env`, CLI flag, 함수형 config 의 우선순위 / 머지 / 차이점 정리.

## 우선순위 흐름

```
사용자 CLI flag           ─┐  (가장 우선)
                            │
zntc.config.{ts,js,json}    ─┤
                            │
.env / .env.{mode} 파일    ─┤  (define 자동 주입)
                            │
--tsconfig-raw JSON        ─┤
                            │
tsconfig.json              ─┤
                            │
ZNTC defaults               ─┘  (최후 fallback)
```

CLI > config > `--tsconfig-raw` > tsconfig file > defaults. 같은 옵션이 여러 곳에 정의되면 위쪽이 이긴다.

## 옵션별 source 매핑

| 옵션                                         |              CLI flag              |           zntc.config           |         tsconfig          | 비고                                                               |
| -------------------------------------------- | :--------------------------------: | :----------------------------: | :-----------------------: | ------------------------------------------------------------------ |
| `entryPoints`                                |             positional             |               ✅               |            ❌             | CLI 가 비어있으면 config 사용                                      |
| `outdir` / `outfile`                         |          `--outdir` `-o`           |               ✅               |            ❌             | scalar override                                                    |
| `allowOverwrite`                             |        `--allow-overwrite`         |               ✅               |            ❌             | 기본 false; 입력=출력 덮어쓰기 명시 허용                           |
| `format`                                     |           `--format=esm`           |               ✅               |            ❌             | esm/cjs/iife/umd/amd                                               |
| `platform`                                   |         `--platform=node`          |               ✅               |            ❌             | node/browser/react-native                                          |
| `rnVersion`                                  |        `--rn-version=0.80`         |               ✅               |            ❌             | RN 버전 타겟. `platform: "react-native"` 함의 + RN 문서 기준 버전별 다운레벨(blunt 프리셋 대신). `"0.80"`/`">=0.74"`/`"<=0.84"`/`"==0.76"`. `node`/`neutral` 과 충돌. 자세히는 [USAGE](./USAGE.md#플랫폼-프리셋) |
| `target`                                     |         `--target=es2020`          |               ✅               |         `target`          | tsconfig fallback                                                  |
| `browserslist`                               |               (없음)               |               ✅               |            ❌             | string / string[] Browserslist 쿼리. 지정 시 `target` 보다 우선. `platform: "react-native"` 에서는 사용 불가 (Hermes 매트릭스 강제) |
| `runtimePolyfills`                           |        `--runtime-polyfills`       |               ✅               |            ❌             | core-js 런타임 API 폴리필. 타겟은 Rspack/SWC식 Browserslist query  |
| `coreJs`                                     |          `--core-js=3.49`          |               ✅               |            ❌             | core-js-compat 계산에 사용할 core-js 버전                          |
| `jsx`                                        |         `--jsx=automatic`          |               ✅               |           `jsx`           | preserve/transform/automatic                                       |
| `jsxFactory` / `jsxFragment`                 |                flag                |               ✅               |      `jsxFactory` 등      | tsconfig fallback                                                  |
| `external`                                   |          `--external:lib`          |               ✅               |            ❌             | 배열 — CLI 비어있으면 config                                       |
| `packagesExternal`                           |       `--packages=external`        |               ✅               |            ❌             | bare package import 전체 external, relative/absolute는 번들        |
| `alias`                                      |           `--alias:K=V`            |               ✅               |     tsconfig `paths`      | Object/Array 두 형태. Object 는 키 단위 CLI 머지, Array 는 build() 만 (RegExp). resolve **전** 무조건 치환 |
| `fallback`                                   | `--fallback:K=V` / `--fallback:K=false` |          ✅               |            ❌             | resolve **실패 시에만** 적용. webpack `resolve.fallback` 호환. `=false` 면 빈 모듈 |
| `define`                                     |           `--define:K=V`           |               ✅               |            ❌             | 객체 머지: 키 단위 CLI override                                    |
| `loader`                                     |        `--loader:.ext=type`        |               ✅               |            ❌             | 객체 머지                                                          |
| `minify` / `minifyWhitespace` 등             |           `--minify` 등            |               ✅               |            ❌             | boolean — CLI default(false) 시 config=true 만 적용                |
| `sourcemap`                                  |           `--sourcemap`            |               ✅               |        `sourceMap`        | tsconfig fallback                                                  |
| `sourcesContent`                             |     `--sources-content=false`      |               ✅               |            ❌             | default=true; CLI true 시 config=false 만 적용                     |
| `treeShaking`                                |               (없음)               |               ✅               |            ❌             | default=true                                                       |
| `experimentalDecorators`                     |                flag                |               ✅               | `experimentalDecorators`  | tsconfig fallback                                                  |
| `useDefineForClassFields`                    |                flag                |               ✅               | `useDefineForClassFields` | default=true                                                       |
| `verbatimModuleSyntax`                       |     `--verbatim-module-syntax`     |               ✅               |  `verbatimModuleSyntax`   | tsconfig fallback                                                  |
| `tsconfigPath`                               |     `-p path` `--project=path`     |               ❌               |        (자기 자신)        | tsconfig 위치 명시                                                 |
| `tsconfigRaw`                                |      `--tsconfig-raw=<json>`       |               ✅               |        inline JSON        | 파일 기반 tsconfig보다 우선                                        |
| `plugins`                                    |  `--plugin path` (plugins 배열만)  |               ✅               |            ❌             | concat — config plugins + `--plugin` plugins                       |
| `banner` / `footer`                          |         `--banner:js=` 등          |               ✅               |            ❌             | scalar                                                             |
| `intro` / `outro`                            |      `--intro=` / `--outro=`       |               ✅               |            ❌             | 포맷 wrapper 내부 코드 삽입                                        |
| `entryNames` / `chunkNames` / `assetNames` / `cssNames` |       flag         |               ✅               |            ❌             | scalar. `entryNames` / `cssNames` default `[dir]/[name]` (sub-2 부터, breaking) |
| `globalName`                                 |          `--global-name=`          |               ✅               |            ❌             | iife/umd 시 사용                                                   |
| `globals`                                    |        `--global:SPEC=NAME`        |               ✅               |            ❌             | external specifier → IIFE/UMD global                               |
| `publicPath`                                 |          `--public-path=`          |               ✅               |            ❌             | asset URL prefix                                                   |
| `inject`                                     |          `--inject=path`           |               ✅               |            ❌             | 배열                                                               |
| `drop`                                       |        `--drop=console` 등         |               ✅               |            ❌             | 배열                                                               |
| `dropLabels`                                 |      `--drop-labels=DEV,TEST`      |               ✅               |            ❌             | 배열, CLI 값은 쉼표로 분리                                         |
| `pure`                                       |          `--pure:callee`           |               ✅               |            ❌             | 배열, 반복 지정                                                    |
| `keepNames`                                  |           `--keep-names`           |               ✅               |            ❌             | boolean                                                            |
| `shimMissingExports`                         |      `--shim-missing-exports`      |               ✅               |            ❌             | boolean                                                            |
| `flow`                                       |              `--flow`              |               ✅               |            ❌             | Flow 타입 스트리핑                                                 |
| `quotes`                                     |         `--quotes=double`          |               ✅               |            ❌             | single/double                                                      |
| `splitting`                                  |           `--splitting`            |               ✅               |            ❌             | code splitting                                                     |
| `preserveModules` / `preserveModulesRoot`    |                flag                |               ✅               |            ❌             | Rollup 호환                                                        |
| `legalComments`                              |        `--legal-comments=`         |               ✅               |            ❌             | none/inline/eof                                                    |
| `metafile`                                   |            `--metafile`            |               ✅               |            ❌             | esbuild 호환                                                       |
| `resolveExtensions`                          |      `--resolve-extensions=`       |               ✅               |          (간접)           | tsconfig 의 paths 와 별개                                          |
| `mainFields`                                 |          `--main-fields=`          |               ✅               |            ❌             | package.json field 우선순위                                        |
| `conditions`                                 |          `--conditions=`           |               ✅               |            ❌             | package exports 사용자 조건. monorepo internal src 직접 inline 은 [Monorepo](#monorepo--source-exports-condition) 참조 |
| `nodePaths`                                  |          `--node-paths=`           |               ✅               |            ❌             | bare specifier 추가 탐색 경로                                      |
| `profile` / `profileLevel` / `profileFormat` |            `--profile*`            |               ✅               |            ❌             | 디버그/성능 측정                                                   |
| `ignoreAnnotations`                          |       `--ignore-annotations`       |               ✅               |            ❌             | pure/sideEffects annotation 무시                                   |
| `jsxSideEffects`                             |        `--jsx-side-effects`        |               ✅               |            ❌             | unused JSX expression 보존                                         |
| `manualChunks`                               |               (없음)               |     ✅ (record / function)     |            ❌             | Rollup 호환. function form 은 zntc.config.{ts,js} 만                |
| `inlineDynamicImports`                       |     `--inline-dynamic-imports`     |               ✅               |            ❌             | Rollup 호환                                                        |
| `import.meta.env.*`                          | `--define:import.meta.env.X="..."` | (없음 — `.env` 파일 자동 로드) |            ❌             | `.env`/`.env.local`/`.env.${mode}`/`.env.${mode}.local` 4단계 머지 |

## 함수형 config 의 ConfigEnv

```ts
defineConfig(({ command, mode, env }) => ({
  format: command === 'bundle' ? 'esm' : 'cjs',
  minify: mode === 'production',
}));
```

| 필드      | 결정 규칙                                                                                                      |
| --------- | -------------------------------------------------------------------------------------------------------------- |
| `command` | `zntc dev` / `zntc preview` / `--serve` → `"serve"`, `--watch` → `"watch"`, 그 외(`zntc build` 포함) → `"bundle"` |
| `mode`    | `--mode <name>` 명시값. 미지정 시 command 기본 (`serve`/`watch` → `"development"`, 그 외 → `"production"`)     |
| `env`     | `process.env` + `.env*` 머지 (shell env 가 `.env` 를 override — Vite/dotenv 16+ 일치)                          |

## `defineConfig` 예제

`defineConfig` 는 런타임 변환 없이 입력 객체를 그대로 반환하는 identity helper 다. 목적은
`zntc.config.{ts,js}` 에서 타입 체크와 자동완성을 얻는 것이다.

### 기본 객체 config

```ts
// zntc.config.ts
import { defineConfig } from '@zntc/core';

export default defineConfig({
  entryPoints: ['src/index.ts'],
  outfile: 'dist/index.js',
  format: 'esm',
  sourcemap: true,
});
```

### 개발 / 릴리즈 분기

```ts
// zntc.config.ts
import { defineConfig } from '@zntc/core';

export default defineConfig(({ command, mode, env }) => {
  const production = command === 'bundle' && mode === 'production';

  return {
    entryPoints: ['src/index.ts'],
    outdir: 'dist',
    format: production ? 'esm' : 'cjs',
    minify: production,
    define: {
      __APP_ENV__: JSON.stringify(env.ZNTC_APP_ENV ?? mode),
    },
  };
});
```

같은 디렉터리에 `zntc.config.production.ts` 처럼 mode 별 config 를 두면 base
`zntc.config.ts` 위에 shallow merge 된다. 배열은 concat 하지 않고 mode 파일 값이
base 값을 대체한다.

## React Native config 예제

RN 은 개발 서버와 릴리즈 번들의 관심사가 다르다. 개발 서버에는 `server.*`,
`dev: true`, client log forwarding 같은 설정이 필요하고, 릴리즈 번들은 보통
RN CLI/Gradle/Xcode 가 넘기는 `--dev false`, `--minify true`, `--bundle-output`
같은 flag 가 최종값을 결정한다. 따라서 하나의 `zntc.config.ts` 를 쓰되,
`command` / `mode` 로 dev-only 값을 좁히는 형태를 권장한다.

```ts
// zntc.config.ts
import { dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { defineConfig } from '@zntc/core';

const projectRoot = dirname(fileURLToPath(import.meta.url));

export default defineConfig(({ command, mode }) => {
  const production = command === 'bundle' && mode === 'production';

  return {
    root: projectRoot,
    // RN dev server 는 Metro 형태의 `entry` 를 읽고,
    // bundle/build 경로는 `entryPoints` 또는 CLI positional entry 를 쓴다.
    entry: 'index.js',
    entryPoints: ['index.js'],
    dev: !production,
    minify: production,
    resolver: {
      // 현재 platform suffix 뒤에 .native.* fallback 을 함께 허용한다.
      platforms: ['android', 'ios', 'native'],
    },
    transformer: {
      // @react-native/metro-config 의 RN 기본값과 맞춘다.
      inlineRequires: true,
    },
    server: {
      port: 8081,
      host: 'localhost',
      useGlobalHotkey: true,
      forwardClientLogs: true,
    },
  };
});
```

`transformer.babel` 은 기본 설정이 아니다. ZNTC 가 TS/Flow/RN preset/worklets 를
native transform 으로 처리하므로, 앱이 별도의 Babel plugin/preset 을 실제로 요구할 때만
아래처럼 추가한다.

```ts
export default defineConfig({
  transformer: {
    babel: {
      plugins: ['babel-plugin-macros'],
    },
  },
});
```

`serializer.polyfills` / `serializer.prelude` 도 빈 배열을 넣을 필요가 없다. 실제로
entry 전에 실행해야 하는 추가 모듈이 있을 때만 넣으면 preset 의 RN polyfill 뒤에
이어 붙는다.

### RN monorepo 예제

```ts
// apps/mobile/zntc.config.ts
import { createRequire } from 'node:module';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { defineConfig } from '@zntc/core';

const require = createRequire(import.meta.url);
const projectRoot = dirname(fileURLToPath(import.meta.url));
const workspaceRoot = resolve(projectRoot, '../..');

export default defineConfig(({ command, mode }) => {
  const production = command === 'bundle' && mode === 'production';

  return {
    root: projectRoot,
    entry: 'index.js',
    entryPoints: ['index.js'],
    dev: !production,
    minify: production,
    watchFolders: [workspaceRoot],
    preserveSymlinks: true,
    resolveSymlinkSiblings: true,
    resolver: {
      nodeModulesPaths: [
        resolve(projectRoot, 'node_modules'),
        resolve(workspaceRoot, 'node_modules'),
      ],
      sourceExts: ['.tsx', '.ts', '.jsx', '.js', '.mjs', '.cjs', '.json', '.svg'],
      assetExts: ['.bmp', '.gif', '.jpg', '.jpeg', '.png', '.webp', '.avif', '.ico'],
      platforms: ['android', 'ios', 'native'],
      resolveRequest(context, moduleName, platform) {
        if (moduleName === 'redux-saga') {
          // Metro config 에서도 package.json module field 를 피하려는 경우
          // 같은 방식으로 CJS entry 를 고정한다.
          const resolved = require.resolve(moduleName);
          return context.resolveRequest(context, resolved, platform);
        }

        return context.resolveRequest(context, moduleName, platform);
      },
    },
    transformer: {
      inlineRequires: true,
    },
    server: {
      port: 8081,
      host: 'localhost',
      useGlobalHotkey: true,
      forwardClientLogs: true,
    },
  };
});
```

이 예시의 `preserveSymlinks` 는 pnpm workspace 의 logical path 를 유지하고,
`resolveSymlinkSiblings` 는 symlink 된 package 의 realpath 주변 dependency 를 한 번 더
찾기 위한 fallback 이다. 둘은 서로 다른 옵션이지만 pnpm/RN monorepo 에서는 보통 함께
켠다.

## `.env` 파일 자동 로드

CLI 가 항상 자동 호출 (별도 flag 불필요).

```
.env                         # 기본 — committed
.env.local                   # 로컬 override — gitignored
.env.${mode}                 # mode 별 — committed
.env.${mode}.local           # mode 별 로컬 override — gitignored (가장 우선)
```

기본 prefix `["VITE_", "ZNTC_"]` 매칭 키만 노출. `--env-prefix=NEXT_PUBLIC_,CUSTOM_` 으로 변경.

```ts
console.log(import.meta.env.VITE_API); // bundle-time 정적 치환
console.log(import.meta.env.MODE); // 자동 주입: "production"/"development"/...
console.log(import.meta.env.PROD); // mode === "production"
console.log(import.meta.env.DEV); // mode !== "production"
console.log(import.meta.env.SSR); // 항상 false (SSR 미지원)
console.log(import.meta.env.BASE_URL); // --base / publicPath 기반 URL
```

자세한 내용은 `loadEnv` API (`packages/core/src/load-env.ts`) 참조.

## tsconfig 통합

- `compilerOptions.target/jsx/jsxFactory/jsxFragment/jsxImportSource/experimentalDecorators/useDefineForClassFields/verbatimModuleSyntax/sourceMap` — config 미지정 시 tsconfig 값 사용.
- `compilerOptions.paths` / `baseUrl` — alias 로 변환되어 resolver 에 주입. CLI `--alias:` 가 같은 키를 override.
- `--tsconfig-raw=<json>` 이 있으면 파일 기반 `-p path` / `--project=path` 및 자동 탐색보다 우선한다.
- `-p path` / `--project=path` 로 명시 지정. 미지정 시 entry 부모 디렉토리부터 cwd 까지 탐색.

## conflict 케이스 (실측 예시)

### 1. `format` — CLI override

```bash
# zntc.config.json: { "format": "iife", "globalName": "MyLib" }
# CLI 가 명시:
zntc --bundle --format=esm entry.ts
# → format=esm 적용 (CLI 우선). globalName 은 config 그대로 — 단 esm 에서는 무시.
```

### 2. `define` — 객체 키 단위 override

```ts
// zntc.config.ts
export default defineConfig({
  define: {
    __VER__: '"v1.0"',
    __BUILD__: '"production"',
  },
});
```

```bash
zntc --bundle --define:__BUILD__='"staging"' entry.ts
# → __VER__: "v1.0" (config 그대로), __BUILD__: "staging" (CLI override)
```

### 3. `boolean` 머지의 비대칭

```json
// zntc.config.json
{ "minify": true, "sourcesContent": false }
```

```bash
# CLI default 그대로 (--minify 안 줌, --sources-content 안 줌):
zntc --bundle entry.ts
# → minify=true (default false → config true 적용)
#    sourcesContent=false (default true → config false 적용)
```

주의: CLI 가 default 값을 명시적으로 줬는지 (예: `--no-minify`) 구분하지 못한다. `boolean default=false → config true 가 적용 / default=true → config false 가 적용` 의 비대칭 머지. 정밀 제어는 함수형 config 의 `command/mode` 분기로.

### 4. `external` — 배열 정책

```json
// zntc.config.json
{ "external": ["node:fs", "node:path"] }
```

```bash
zntc --bundle entry.ts                              # → ["node:fs", "node:path"] (config)
zntc --bundle --external=react entry.ts             # → ["react"] (CLI 가 비어있지 않으면 CLI 만 사용 — concat 안 함)
```

위 "CLI 비어있지 않으면 CLI 만 사용(replace)" 정책은 실사용 진입점인 **npm CLI(`packages/core/bin/zntc.mjs`, ARRAY_KEYS 머지)** 기준이다.
> **알려진 불일치 (2026-06-15)**: Zig 독립 바이너리(`zig-out/bin/zntc`)의 `applyZntcConfigJson` 은 config 의 `external`/`alias` 배열을 먼저 `external_list` 에 append 한 뒤 CLI flag 도 같은 리스트에 append 하므로 **concat** 으로 동작한다 (위 예시는 `["node:fs", "node:path", "react"]`). 실사용자는 npm CLI 를 쓰므로 영향은 제한적이지만, Zig CLI 를 직접 쓰는 경우 동작이 다르다.

`packagesExternal`은 esbuild 호환 `--packages=external`과 동일하게 모든 bare package import를 external 처리한다. `./local`, `../local`, `/abs/local` 같은 relative/absolute import는 계속 번들 대상이다.

### 5. `tsconfig` + `zntc.config` + CLI 3-way (jsx)

```json
// tsconfig.json
{ "compilerOptions": { "jsx": "preserve" } }
```

```ts
// zntc.config.ts
export default defineConfig({ jsx: 'automatic' });
```

```bash
zntc --bundle --jsx=transform App.tsx
# → jsx=transform (CLI 우선). config 의 automatic / tsconfig 의 preserve 모두 무시.
```

### 6. `.env` shell override

```env
# .env
VITE_HOST=production-default.example.com
```

```bash
VITE_HOST=staging.example.com zntc --bundle entry.ts
# → import.meta.env.VITE_HOST = "staging.example.com" (shell 우선)
# → CI / 컨테이너 환경에서 .env 수정 없이 override 가능.
```

### 7. `--config <path>` 명시 vs 자동 탐색

```bash
zntc --bundle --config ./configs/prod.config.ts entry.ts
# → 자동 탐색 우회 (cwd 의 zntc.config.* 무시).
# → 함수형 config 의 command='bundle', mode 는 --mode 또는 default.
```

### 8. `alias` 와 `fallback` — Node 빌트인 폴리필 / 강제 매핑

webpack `resolve.alias` / `resolve.fallback` 와 동일 시맨틱.

```ts
// zntc.config.ts — Node 라이브러리를 브라우저에서 쓸 때
export default defineConfig({
  platform: 'browser',
  alias: {
    // resolve **전 무조건** 치환. 실제 패키지 설치 여부 무시.
    // 예: axios 1.15+ 처럼 fully-specified 를 강제하는 ESM 라이브러리에서
    //     'process/browser' (확장자 없음) 를 강제로 특정 파일에 매핑.
    'process/browser': './node_modules/process/browser.js',
  },
  fallback: {
    // 일반 해석이 **실패할 때만** 적용. 실제 패키지가 있으면 그쪽 우선.
    fs: false,                    // → 빈 모듈
    crypto: 'crypto-browserify',  // → npm 패키지로 polyfill
    stream: 'stream-browserify',
  },
});
```

CLI 도 동일:

```bash
zntc build entry.ts --platform=browser \
  --alias:process/browser=./node_modules/process/browser.js \
  --fallback:fs=false \
  --fallback:crypto=crypto-browserify
```

#### `alias` 의 두 형태 (Object vs Array)

`alias` 는 esbuild / Vite 호환을 위해 두 형태를 허용한다 — `Record<string, string>` 또는 `Array<{ find: string | RegExp; replacement: string }>`.

```ts
// 1. Object 형태 (esbuild 호환): exact + prefix 매칭. 정해진 specifier 만 치환.
//    `react` 또는 `react/hooks` → `preact/compat[/hooks]`
defineConfig({
  alias: { react: 'preact/compat' },
});

// 2. Array 형태 (Vite `resolve.alias`): RegExp find 지원. 매칭 순서대로 첫 번째 적용.
//    `find` 가 string 이면 prefix, RegExp 이면 host runtime 매칭 + `replacement` 치환.
defineConfig({
  alias: [
    { find: /^@\/(.*)$/, replacement: './src/$1' },
    { find: '~components', replacement: './src/components' },
  ],
});
```

| 형태 | 매칭 | RegExp | `buildSync` | `zntc.config.json` |
| ---- | ---- | :----: | :---------: | :---------------: |
| Object (`Record<string, string>`) | exact + prefix | ❌ | ✅ | ✅ |
| Array (`{ find, replacement }[]`) | string=prefix / RegExp=host runtime | ✅ | ❌ — `build()` 만 | ❌ (JSON 은 RegExp 직렬화 불가) |

Array 형태는 host runtime 의 RegExp 매칭에 위임하므로 sync 경로(`buildSync`)에서는 throw 한다 — async `build()` / `watch()` 만 사용 가능. JSON config 도 RegExp 직렬화가 없으므로 `zntc.config.{ts,js}` 에서만 의미 있음.

차이 요약:

| 옵션       | 적용 시점          | 매칭         | 실제 패키지 우선? | 빈 모듈 처리             |
| ---------- | ------------------ | ------------ | ----------------- | ------------------------ |
| `alias`    | resolve **전 항상**| exact + prefix | ❌ — alias 우선   | ❌ (빈 모듈 → blockList 사용)|
| `fallback` | resolve **실패 시**| exact only   | ✅ — 실패 시에만  | ✅ (`=false`)             |

자동 polyfill 한 줄 매핑 (`node-polyfill-webpack-plugin` 류) 은 ZNTC 가 제공하지 않는다 — esbuild 정책과 동일하게 사용자가 명시 매핑하거나 plugin 으로 처리.

## Monorepo — `source` exports condition

monorepo 안에서 internal package 끼리 import 할 때, 기본 동작은 **package.json `main` / `exports.import` 따라 dist 를 inline bundle**. 즉 의존 package 의 `dist/` 를 먼저 빌드해야 하고, dist 가 stale 이면 옛 코드가 박혀버린다 (build order + stale 위험).

ZNTC 는 producer 의 src 를 직접 inline 하기 위해 **`source` exports condition** 을 지원한다 (parcel / microbundle / preconstruct 와 동일 패턴).

### 설정

producer package 가 자기 src 위치를 선언:

```jsonc
// packages/server/package.json
{
  "source": "./src/index.ts",
  "main": "./dist/index.js",
  "exports": {
    ".": {
      "source": "./src/index.ts",
      "import": "./dist/index.js",
      "types": "./dist/index.d.ts"
    }
  }
}
```

consumer 의 빌드 명령에 `--conditions=source` 추가:

```jsonc
// packages/web/package.json
"build:bundle": "node ../core/bin/zntc.mjs --bundle src/index.ts --outfile dist/index.js --conditions=source --external @zntc/core ..."
```

→ ZNTC 가 `import '@zntc/server'` 만나면 `./src/index.ts` 직접 따라가서 inline. server 의 dist 가 stale 이거나 없어도 무관.

외부 npm 사용자에겐 `source` condition 이 켜지지 않으니 그대로 dist 사용 — monorepo 내부에서만 전환된다.

> 최상위 `"source": "./src/index.ts"` 필드는 ZNTC bundler 가 직접 읽지 않는다 (`exports.source` 만 사용). parcel / microbundle 등 외부 도구 호환을 위해 함께 두는 관행.

### resolver 우선순위

```
1. alias (--alias / build({ alias })) — 명시 override, 항상 우선
2. tsconfig paths
3. package.json exports (--conditions=source 면 source 먼저 매치)
4. exports.import / main (default)
```

esbuild / Vite / Rollup 과 동일 순서. `alias` 는 fork / vendor escape hatch 로만 권장.

### IDE / TS 체커는 여전히 dist 를 본다

bundler 가 src 를 inline 해도 TS `tsc` 와 IDE 는 producer 의 `dist/*.d.ts` 를 따라간다. server src 만 고치고 dist rebuild 를 안 한 상태에서 web/RN 빌드는 새 코드를 inline 하지만, IDE/TS 체커는 옛 타입을 표시한다. 이를 해소하려면 TypeScript Project References (`composite: true` + `references`) 로 cross-package 타입 체크를 묶는 별도 작업이 필요하다 (이번 변경 scope 외).

### 다른 번들러 비교

| 번들러   | 방식                          | 빌드 순서 필요? | stale 위험      |
| -------- | ----------------------------- | --------------- | --------------- |
| esbuild  | dist (또는 monorepo 미사용)   | yes             | 있음            |
| swc/oxc  | turbo + dist                  | yes             | turbo cache 완화|
| Rollup   | `@rollup/plugin-alias` → src  | no              | 없음            |
| Vite     | `resolve.alias` → src         | no              | 없음            |
| Parcel   | `source` exports condition    | no              | 없음            |
| **ZNTC** | `source` exports condition    | **no**          | **없음**        |

## package.json field / exports condition 우선순위

dual-package (CJS + ESM 동시 출시) 라이브러리에서 ZNTC 가 어떤 entry 를 따라가는지.

### main fields

기본값 (`--main-fields` 미지정 시) — `--platform` 별로 다르다 (`src/bundler/resolve_cache.zig` `defaultMainFieldsFor`):

```
node / neutral : "module" → "main"            (ESM 우선)
browser        : "browser" → "module" → "main"
react-native   : "react-native" → "browser" → "main"
```

코드: `src/bundler/resolve_cache.zig` `defaultMainFieldsFor` + `resolver.zig` `resolveByMainFields`. `--main-fields=main,module` 처럼 명시 override 가능 (override 시에는 platform 분기 없이 지정한 목록 그대로 사용).

### exports conditions

기본값:

```
"import" → "module" → "browser" → "default"
```

코드: `src/bundler/resolver.zig` `conditions` 기본값. `--conditions=source,...` 로 추가 condition 만 받고, `module` 등 기본값을 자동 제거하지 않는다 (esbuild 의 "커스텀 조건 시 module 자동 제거" 함정 회피 — `DECISIONS.md` D064).

### platform=node 에서도 ESM 우선 — esbuild 와 차이

esbuild `--platform=node` 는 `main_fields=main,module` + `conditions=node,require,...` 로 잡혀서 **CJS 경로**를 우선한다. ZNTC 의 `node`/`neutral` 기본 main fields 는 `module` → `main` 이므로 `--platform=node` 빌드도 ESM 경로를 먼저 시도한다. (`browser`/`react-native` 는 각각 `browser`/`react-native` 필드를 앞에 두지만, 둘 다 `module`/CJS-only 보다 dual-package ESM 진입을 막지는 않는다.)

**효과**: fp-ts (2.16.x), lodash-es, effect 등 dual-package 라이브러리에서 ESM (`es6/`, `esm/`) 경로로 진입 → cross-module dead code elimination 이 깊게 들어가 esbuild 대비 번들 크기가 크게 줄어든다.

예) fp-ts `pipe(some(1), map(n => n + 1), getOrElse(() => 0))`:
- esbuild `--platform=node`: `lib/Option.js` (CJS) → 17개 typeclass 모듈 keep → 70KB
- ZNTC `--platform=node`: `es6/Option.js` (ESM) → 4개 모듈만 keep → 2.4KB

**주의**: 일부 라이브러리는 CJS 와 ESM 빌드의 동작이 미세하게 다를 수 있다 (특히 `__esModule` interop, default export 처리). esbuild 에서 마이그레이션 중 동작 차이가 의심되면 `--main-fields=main,module` 로 명시해 esbuild 정책에 맞출 수 있다.

## 다른 번들러와의 차이

### Vite

- ZNTC: `defineConfig(fn | obj)` 동일.
- ZNTC: `--mode` / `--config <path>` 동일.
- ZNTC: `.env*` 4단계 우선순위 동일. prefix default 만 차이 (Vite `["VITE_"]`, ZNTC `["VITE_", "ZNTC_"]`).
- ZNTC: `import.meta.env.MODE/PROD/DEV/SSR/BASE_URL` 자동 주입 동일.
- ZNTC: `defineConfig(({ command }))` 의 command 값이 다름 — Vite 는 `"build"|"serve"`, ZNTC 는 `"bundle"|"serve"|"watch"`. 앱 빌더의 `zntc build` 도 config 관점에서는 `"bundle"` 이다.

### esbuild

- esbuild: `zntc.config.*` 같은 명시 config 파일 미지원 (JS API 만). ZNTC 는 양쪽.
- esbuild: tsconfig 통합 (paths/jsx) 동일.
- esbuild: `define` / `external` / `alias` 의미 동일. 에러 메시지·flag 형식만 차이.

### Rolldown

- Rolldown: `rolldown.config.{ts,js}` + `defineConfig`. ZNTC 와 거의 동일.
- Rolldown: 함수형 config 미지원 (객체 only). ZNTC 는 양쪽.
- Rolldown: `manualChunks` 의 record / function form 동일.

## 디버깅

### 어떤 config 가 실제로 적용됐는지

- 자동 탐색: `findConfigPath(cwd)` 가 가장 위 우선순위 매치를 반환. 우선순위는 `.ts > .mts > .cts > .mjs > .js > .cjs > .json`.
- watch 모드: config / `.env*` 변경 시 자동 process restart (`--watch-json` 의 경우 `{type: "restart", reason: "..."}` 이벤트 emit).

### typo 감지

`zntc.config.*` 와 workspace inline config 의 unknown key 는 경고로 표시된다. 가까운 known key 가 있으면 Levenshtein 기반 `did you mean?` 제안을 함께 출력한다.

## 참고 이슈

- 에픽: [#2099](https://github.com/ohah/zntc/issues/2099)
- Phase 1: #2113 / #2114 / #2115 (loader / 자동 탐색 / BuildOptions 머지)
- Phase 2-1: #2119 (함수형 config + `--config` + `--mode`)
- Phase 2-4: #2120 (`.env` 자동 로드)
- Phase 2-5: #2123 (watch hot reload)
- Phase 3-2: #2109 (typo "did you mean?" — 완료)
- Phase 3-5: #2112 (TS BuildOptions ↔ Zig TranspileOptions schema sync)
