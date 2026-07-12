# Usage

CLI 실행법, `@zntc/core` JS API, 그리고 주요 옵션의 동작 규칙을 한곳에 정리한 문서.

## Commands

```bash
zig build [test|test262|napi|wasm|run]
```

- NAPI 테스트: `cd packages/core && bun test` (또는 `node --test napi.test.mjs`)
- 통합 테스트: `cd tests/integration && bun test` (**반드시 이 디렉토리에서 실행** — 루트에서 실행 시 경로 해석 실패)
- 스모크 테스트: `cd tests/benchmark && bun run smoke.ts` (실제 npm 패키지 빌드/실행 검증)
- 전체 CLI 옵션: `zntc --help`

### Vite-style app builder

```bash
zntc dev [root]
zntc build [root]
zntc preview [outdir]
```

기본 앱 구조는 `index.html`, `public/`, `src/main.ts(x)`, `.env*` 이다.
`zntc build`는 HTML의 `<script type="module" src>`를 엔트리로 사용하고,
hashed JS/CSS/assets와 rewritten `dist/index.html`을 출력한다. `public/` 파일은
변환 없이 outdir 루트로 복사하며 번들 산출물과 충돌하면 에러를 낸다.

> **`@zntc/web` 필요** (#2539) — `zntc dev` / `zntc preview` / `zntc build` (app 모드) 는
> `@zntc/web` 패키지를 lazy import 한다. `@zntc/core` 단독 install 사용자가 app
> 모드를 호출하면 친화 에러 메시지 + exit 1. 설치:
>
> ```bash
> bun add -D @zntc/web        # 또는 npm i -D @zntc/web
> ```
>
> `zntc transpile` / `zntc bundle` (라이브러리 모드) 는 web 불필요.

지원 옵션:

- `--entry-html <file>` — 기본 `index.html`
- `--public-dir <dir|false>` — 기본 `public`
- `--base <path>` — HTML/CSS asset URL prefix
- `--lazy` — 동적 `import()` 타겟을 on-demand 로 컴파일. 동적 청크는 처음 빌드에 파싱·출력하지
  않고, 브라우저가 그 청크를 실제로 요청할 때 그 모듈만 컴파일해 응답한다. 진입하지 않은 라우트는
  파싱조차 안 하므로 라우트가 많은 앱일수록 cold-start 가 빨라진다. 파일을 편집해도 미요청 청크는
  계속 lazy 로 유지된다. (dev 전용 — 프로덕션 `zntc build` 는 모든 청크를 정적으로 출력.)
- `--loader:.ext=type`, `--asset-names <pattern>`, `--asset-inline-limit <bytes>` — 자산 옵션.
  `zntc --bundle` 과 같은 vocab 이다 (#4466 이전엔 app 모드가 `--loader` 를 `unknown option` 으로
  거부해 CSS/JS 가 참조하는 자산을 제어할 방법이 없었다). 이미지/폰트/미디어 확장자는 기본
  `file` 로더가 붙으므로 보통은 무설정으로 동작한다 — 아래 [Asset / RN](#asset--rn) 참고.
- `--mode`, `--env-prefix`, `--env-dir`, `--outdir`, `--port`, `--host`, `--proxy`, `--certfile`, `--keyfile`
- `--jsx`, `--jsx-dev`, `--jsx-import-source`, `--jsx-factory`, `--jsx-fragment` — JSX runtime. 미지정 시
  app root의 `tsconfig.json` `compilerOptions.jsx` / `jsxImportSource`를 읽어 적용한다 (`zntc bundle`과 동일
  우선순위: CLI > tsconfig > default classic `React.createElement`). preact/solid 등 비-React JSX 앱은
  tsconfig에 `"jsx": "react-jsx", "jsxImportSource": "preact"`만 지정하면 `zntc dev`/`zntc build` 모두 동작.

Env 로딩 순서는 `.env`, `.env.local`, `.env.{mode}`, `.env.{mode}.local`이며,
기본 prefix는 `VITE_`, `ZNTC_`이다. `import.meta.env.MODE/DEV/PROD/SSR/BASE_URL`,
`import.meta.env.KEY`, full `import.meta.env` object 접근을 지원한다.

앱 root에 `postcss.config.{js,mjs,cjs,json}` 또는 `.postcssrc*`가 있으면 Vite처럼
imported CSS 산출물에 자동 적용한다. Tailwind v4는 `postcss.config.mjs`에
`@tailwindcss/postcss` 플러그인을 설정하면 동작한다.

`zntc dev`는 빌드 에러와 런타임 에러를 브라우저 오버레이로 표시한다. 런타임 stack trace는
source map을 적용해 가능한 경우 원본 `main.ts:line:column` 위치로 보여준다.
세부 동작: [HMR.md § 에러 오버레이](./HMR.md#에러-오버레이).

### 브라우저 런타임 검증 (`zntc verify`)

```bash
zntc verify dist/index.html          # 정적 빌드 결과 검증
zntc verify dist/                    # 디렉토리 → index.html 자동
zntc verify http://localhost:3000/   # 실행 중인 서버 검증
```

빌드 산출물이 실제 브라우저에서 깨지는지 한 줄로 가드 — headless Chromium 으로 페이지를
띄우고 `pageerror` (uncaught + unhandledrejection) / `console.error` / 4xx 응답 /
request 실패를 수집한다. 이벤트 발견 시 **exit 1** 로 CI 가 fail 처리.

```bash
zntc verify dist/ --verify-json --verify-report=verify-report.json
zntc verify dist/ --verify-ignore "third-party warning" --verify-allow-console-error
```

- `--verify-timeout <ms>` — 페이지 로드 타임아웃 (기본 10000)
- `--verify-ignore <pattern>` — 매칭되는 console/url 이벤트는 무시 (정규식, 반복 가능)
- `--verify-allow-console-error` — `console.error` 는 exit 코드에 영향 없음 (pageerror 만 fail)
- `--verify-json` — 사람이 읽는 요약 대신 JSON 보고서를 stdout 에
- `--verify-report <path>` — JSON 보고서를 파일로 저장

다른 모드의 flag 와 격리하기 위해 모두 `--verify-` prefix.

**의존성**: Playwright peer/optional. 미설치 시 친화 에러 + exit 64.

```bash
npm install --save-dev playwright
npx playwright install chromium
```

타입체크와 유닛 테스트가 못 잡는 런타임 회귀 (ESM circular dep, TDZ, scope-hoist
오재작성, 누락된 리소스) 를 잡는 게 목적. 사용자가 `npx playwright` 로 한 번 설치하면
`zntc build && zntc verify dist/` 한 줄로 CI 검증 추가.

## 설정 파일 (`zntc.config.json` / `zntc.config.{ts,js,mjs,cjs,mts,cts}`)

### `zntc.config.json` — TranspileOptions defaults

CLI 실행 시 cwd에 `zntc.config.json`이 있으면 자동으로 로드되어 기본값으로 사용된다.
**우선순위: CLI 인자 > config.json**.

스키마는 `zig build schema`로 생성되는 `transpile-options.schema.json`과 일치하며,
`"$schema": "./transpile-options.schema.json"` 선언으로 VSCode 등에서 자동완성된다.

매핑되는 필드: `target`, `sourcemap`, `minify`, `jsx*`, `platform`, `format`, `quotes`,
`drop*`, `dropLabels`, `flow`, `experimentalDecorators`, `emitDecoratorMetadata`,
`minifyWhitespace/Identifiers/Syntax`, `sourcemapDebugIds`, `sourcesContent`, `sourceRoot`,
`allowOverwrite` 등.
번들러 전용 필드(`external`, `alias` 등)는 **미처리** — CLI 또는 JS 빌드 API에서 지정.

`outfile` 또는 `outdir` 계산 결과가 입력 파일과 같으면 기본적으로 에러가 난다.
정말 제자리 덮어쓰기가 필요한 경우에만 `--allow-overwrite` 또는
`allowOverwrite: true`를 명시한다.

### Label block 제거

`--drop-labels=DEV,TEST`는 지정한 labeled statement 전체를 제거한다. `--drop=console` /
`--drop=debugger`와 독립적인 옵션이며, 프로덕션 전용 dead block을 묶어 제거할 때 쓴다.

### Pure callee hint

`--pure:<callee>`는 반복 지정할 수 있으며, 매칭되는 unused call/new expression을 기존
`@__PURE__` annotation과 같은 DCE 후보로 표시한다.

지원 패턴은 `makeElement`, `React.createElement` 같은 exact identifier/static member
callee와 `PropTypes.*` 같은 namespace wildcard이다. Computed member
(`React["createElement"]`)와 optional-chain callee(`React.createElement?.()`)는 매칭하지 않는다.

```bash
zntc --bundle src/index.ts --drop-labels=DEV,TEST
zntc --bundle src/index.ts --pure:React.createElement --pure:PropTypes.*
```

### JSX pragma 주석 (per-file override)

파일 주석으로 그 파일만의 JSX 설정을 지정할 수 있다 (esbuild/TS/Babel 동일).
**우선순위: file pragma > tsconfig / CLI 옵션 > 기본값.**

- `/** @jsx h */` — classic factory (= `--jsx-factory`)
- `/** @jsxFrag Fragment */` — classic fragment (= `--jsx-fragment`)
- `/** @jsxRuntime automatic|classic */` — JSX 런타임 모드 (= `--jsx`)
- `/** @jsxImportSource preact */` — automatic import source (= `--jsx-import-source`)

`//` 한 줄 주석(`// @jsx h`)도 인식한다. `@jsx` / `@jsxFrag` 는 effective 런타임이
classic 일 때만 효과가 있다 (automatic 모드는 factory 를 안 쓰므로 무시). 프로젝트는
React(`jsx: react-jsx`)인데 특정 파일만 preact / `@emotion/react` 로 쓰고 싶을 때:

```tsx
/** @jsxImportSource preact */
import { render } from "preact";
export const App = () => <p>preact only here</p>;
```

### 플러그인은 `@zntc/core` JS API로 (npm 배포 CLI)

JS 플러그인을 쓰려면 npm 배포 CLI(`packages/core/bin/zntc.mjs`)를 사용. 내부적으로
`@zntc/core` NAPI로 in-process 실행하여 Vite/Rollup 스타일 플러그인(`resolveId`,
`load`, `transform`, `renderChunk`, `generateBundle`, `buildStart`, `buildEnd`,
`closeBundle`)을 지원. 상세: [PLUGINS.md](./PLUGINS.md).

> Zig 독립 바이너리(`zig-out/bin/zntc`)는 JS 플러그인 비지원 (builtin 플러그인만).
> 이전의 `--plugin` / `zntc.config.{ts,js}` 자동 로드는 D101로 제거됨.

## @zntc/core 요약

```typescript
import {
  init,
  transpile,
  buildSync,
  build,
  buildAppSync,
  prepareAppDevSync,
  watch,
  vitePlugin,
} from '@zntc/core';
init();

transpile(src, opts); // 단일 파일 in-memory 변환. filename 생략 시 JS로 파싱
buildSync(opts); // 동기 번들링 (JS 플러그인 미지원 — 데드락 방지)
await build(opts); // 비동기 번들링 (플러그인 가능)
buildAppSync(opts); // HTML entry app build
prepareAppDevSync(opts); // dev server용 HTML/env/public 준비 + entry path 반환
watch(opts); // 증분 빌드 + 파일 감시 (WatchHandle.stop()으로 종료)
```

### TranspileOptions 주요 필드

`target`, `sourcemap`, `minify`, `jsx`, `jsxImportSource`, `flow`, `format`,
`platform`, `quotes`, `dropConsole/Debugger`, `experimentalDecorators`,
`emitDecoratorMetadata`, `useDefineForClassFields`, `asciiOnly`, `browserslist`, `define`.
TypeScript/TSX 문법은 `filename: "input.ts"` 또는 `"input.tsx"`처럼 source type을 명시해야 한다.

### TranspileResult

```typescript
{ code: string; map?: string; errors?: string }
```

`errors`는 시맨틱 에러가 있을 때 CLI와 동일한 rich diagnostic 텍스트로 렌더링된 문자열
(**tsc 호환 정책**: 에러가 있어도 `code`는 함께 반환). 플레이그라운드/IDE는 이 필드를 파싱해 마커로 표시.

### BuildOptions — 플러그인 훅

esbuild 스타일: `onResolve`, `onLoad`, `onTransform`, `onRenderChunk`, `onGenerateBundle`,
`onBuildStart`, `onBuildEnd`, `onCloseBundle`.

- `onResolve`는 `{ disabled: true }` 반환 시 해당 import를 빈 모듈로 처리.
- `build()` 호출 순서: `buildStart → (NAPI build) → buildEnd → write → closeBundle`.
- `watch()` 호출 순서: `buildStart → (NAPI build/rebuild) → buildEnd → onReady/onRebuild → closeBundle`
  (초기 build와 매 rebuild마다 호출).

### Rollup/Vite 호환 어댑터

- `vitePlugin({ name, resolveId, load, transform, renderChunk, generateBundle, buildStart, buildEnd, closeBundle })` — 모든 훅 async 지원
- `@zntc/vite-plugin` — Vite의 esbuild transform을 ZNTC로 교체 (`zntc()` 플러그인)

상세: [docs/PLUGINS.md](./PLUGINS.md)

## 주요 동작 포인트

### 플랫폼 프리셋

- `--platform=browser` + `--bundle` → IIFE 출력 + `NODE_ENV=production` 자동 define + Node 빌트인 빈 모듈 대체
- `--platform=node` → Node 빌트인(`node:fs`, `fs`, 서브패스 포함) 자동 external
- `--platform=react-native` → RN 프리셋: `.ios.*` / `.android.*` / `.native.*` 확장자, `react-native` main-field / exports 조건, `--flow` 자동 활성화
  - 기본(버전 미지정)은 보수적 Hermes 프리셋 — 사실상 ES5에 가깝게 다운레벨
  - `--rn-version=<spec>`을 함께 주면 **RN 버전별 정밀 다운레벨**. 진실 소스는 [RN javascript-environment 문서](https://reactnative.dev/docs/javascript-environment)의 "JavaScript Syntax Transformers" 목록 — 문서에 있는 기능(class/async/destructuring/optional-chaining 등)은 **네이티브로 유지**하고, 문서에 없는 기능(logical-assignment, class static block, top-level await, using, 일부 regex)만 다운레벨한다. 단 Hermes 런타임 버그(#1299) 회피용으로 arrow → function, `let`/`const` → `var`는 항상 강제 다운레벨.
  - `--rn-version`은 `--platform=react-native`를 함의(별도 지정 불필요). 연산자: `0.80` / `>=0.74` / `==0.76`은 그 버전 기준, `<=0.84` / `<0.84`는 가장 보수적(가장 낮은 지원 버전 기준)으로 다운레벨. 예: `zntc --bundle app.tsx --rn-version ">=0.74"`
  - **지원 버전**: RN **0.70 ~ 0.85 (+ latest)**. 이 범위의 문서 Syntax Transformers 목록이 전부 동일해 **현재는 단일 매트릭스**(어떤 버전을 줘도 같은 다운레벨 세트). 0.70 미만은 0.70으로, 범위 초과는 최신으로 클램프. 입력은 `major.minor` 형식 필수(`74` 같은 단일 정수 거부). RN이 향후 목록을 바꾸면 버전 분기점(change-point)을 추가해 해당 버전부터 다르게 분기한다.
  - **출력 크기 효과** (합성 fixture — class/async/generator 120개, src ~93KB, `--minify`):

    | 모드 | minified raw | gzip |
    | --- | --- | --- |
    | `--platform=react-native` (blunt, 사실상 ES5) | 184 KB | 7.0 KB |
    | `--rn-version 0.84` (정밀) | **82 KB (−55%)** | **5.6 KB (−20%)** |
    | 참고: `--target=esnext` (다운레벨 없음, 천장) | 66 KB | 3.1 KB |

    class/async/generator 를 네이티브로 보존해 ES5 보일러플레이트(`_inherits`/`_createClass`/regenerator state machine)를 제거한 결과. precise→native 잔여 gap 은 #1299 안전망(arrow→function, let/const→var) + private-field 다운레벨. (합성 벤치라 실앱 수치는 코드 구성에 따라 달라짐.)
- `--packages=external` → 모든 bare package import를 external 처리. relative/absolute import는 기존처럼 번들

### React Native CLI 초기화

기존 React Native CLI 프로젝트에 ZNTC를 얹을 때는 `@zntc/init`을 사용한다.
Expo 프로젝트 생성/초기화는 현재 범위 밖이다.

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

주요 옵션:

- `--root <dir>` — 프로젝트 루트. 기본값은 현재 디렉터리
- `--platform <ios|android>` — `start` script의 기본 RN platform. 기본값은 `ios`
- `--zntc-version <range>` — 추가할 `@zntc/core` / `@zntc/react-native` 버전 범위. 기본값은 `latest`
- `--package-manager <bun|npm|pnpm|yarn>` — 초기화 후 출력할 install 명령 힌트
- `--no-metro-fallback` — `start:metro` / `bundle:metro:*` fallback script를 추가하지 않음
- `--force` — 기존 `zntc.config.ts` 덮어쓰기
- `--dry-run` — 파일을 쓰지 않고 변경 계획만 출력
- `--help`, `-h` — 도움말 출력

초기화는 native shell을 새로 만들지 않는다. `package.json`에 `@zntc/core`,
`@zntc/react-native`, ZNTC-first `start` / `bundle:*` scripts를 추가하고,
기존 `react-native start`와 `react-native bundle`은 `start:metro` /
`bundle:metro:*` fallback script로 보존한다. `zntc.config.ts`가 없으면 기본 RN CLI
설정을 생성하고, 기존 파일은 `--force` 없이는 덮어쓰지 않는다.

### Watch / Serve

- `--watch` / `--serve` — 증분 빌드 (PersistentModuleStore + ResolveCache 보존, 변경 모듈만 재파싱)
- JS API `watch()` — `onReady` / `onRebuild`는 Promise 반환 가능. 플러그인 lifecycle은 초기 build와 매 rebuild마다 `buildStart → (NAPI build/rebuild) → buildEnd → onReady/onRebuild → closeBundle` 순서로 호출
- `--watch-json` — NDJSON 이벤트를 stdout으로 출력 (외부 HMR 연동용)
- `watchFolders` (JS API / config) — 모듈 그래프 바깥 루트까지 감시 대상에 포함 (Metro 호환)
- `resolver.blockList` — 특정 경로를 resolve에서 제외 (Metro `resolver.blockList` 호환)
- `resolve.fallback` — 해석 실패 시 대체 매핑 (webpack `resolve.fallback` / Metro `extraNodeModules` 호환)

### Dev server 외부 인터페이스

- `/sse/events` — SSE 빌드 이벤트 (`server_ready`, `watch_change`, `bundle_build_*`, `cache_reset`)
- `/reset-cache` — Control API, 외부에서 캐시 무효화 트리거

상세: [docs/HMR.md](./HMR.md)

### ES 다운레벨링

- `--target=es5` ~ `es2025` / `esnext` 지원
- 엔진 타겟(`--target=chrome80,safari14,node16` 등)은 compat-table 기반 feature-level 다운레벨링
- ES2023: hashbang(`#!`) strip
- ES2025: `using` / `await using` 다운레벨, duplicate named capture group (`/(?<y>..)|(?<y>..)/`) — es2018~es2024 타겟에서도 strip+`__wrapRegExp` 로 다운레벨 (#4199)

### 런타임 API 폴리필

- 기본값은 `runtimePolyfills: "off"` — 자동 core-js 주입은 명시해야 켜진다.
- CLI: `--runtime-polyfills=auto|usage|entry|off`, `--runtime-target=<query>` 반복, `--core-js=3.49`.
- JS API/config: `runtimePolyfills`, `coreJs`. 타겟은 Rspack/SWC `env.targets`와 같은 Browserslist query 배열로
  `runtimePolyfills: { targets: ["chrome >= 87", "safari >= 14"] }`처럼 지정한다.
- `auto`/`usage`는 resolve/load/transform 이후 실제 번들 그래프에서 `replaceAll`, `Map`, `Set`, `Promise`,
  `Array.prototype.at`, `Object.hasOwn`, `structuredClone` 사용을 감지해 타겟 미지원 core-js 모듈만 주입한다.
- `entry`는 타겟 기준 필요한 `core-js/modules/es.*` / `web.*`를 엔트리 prelude에 포괄 주입한다.
- 타겟 예: `ios_saf 12`, `iOS >= 12`, `chrome >= 85`, `android >= 5`,
  `samsung >= 14`, `node 18`. `ios12`, `node18`, `iPhone 8`, `Galaxy S10`
  같은 compact shorthand와 피지컬 디바이스 이름은 지원하지 않는다.

### CSS 번들링

- `import './x.css'` → 별도 CSS 파일 자동 생성
- `@import` 체인 인라이닝 (Zig 네이티브 스캐너)
- `--minify` 시 Lightning CSS (optionalDependency)로 CSS minify
- **`url()` 자산 방출 + 재작성** (#4466) — CSS 본문의 `url()` / `image-set()` 이 가리키는 자산을
  JS import 자산과 동일하게 해시 방출하고 url 을 재작성한다. 예전엔 url() 을 통째로 무시해
  자산이 dist 에 안 나오고 CSS 는 원문 그대로였다 (→ 런타임 404).
  - 대상: `@font-face { src: url(...) }`, `background` / `background-image`, `border-image`,
    `cursor`, `mask-image`, `list-style-image`, CSS 커스텀 속성,
    `image-set()` / `-webkit-image-set()` (bare string 포함)
  - `url(./img/hero.png)` → `url("./hero-a1b2c3d4.png")`. `--public-path` 가 있으면 그 prefix,
    없으면 출력 CSS 위치 기준 상대경로
  - `?query` / `#fragment` suffix 보존 — `url(./f.eot?#iefix)` → `url("./f-a1b2c3d4.eot?#iefix")`
    (IE9 훅), `url(./i.svg#icon)` 도 fragment 유지
  - **재작성 제외**(원문 그대로 통과): `url(#gradient)` (SVG filter/gradient 참조 — 파일 아님),
    `url(/abs.png)` (절대경로 = `public/` 디렉토리 규약), `url(https://…)` / `url(//cdn…)` /
    `url(data:…)` / `url(blob:…)` (external)
  - 해석 실패 시 **경고 후 원문 유지** — 빌드를 깨지 않는다 (Vite 동작과 동일).
    메시지: `Cannot resolve CSS url() asset — left unchanged`

상세: [docs/BUNDLER.md](./BUNDLER.md)

### 진단 (Diagnostics)

파서/시맨틱 에러는 rich diagnostic 포맷으로 렌더된다 — 파일 경로, 라인/컬럼, 코드 프레임,
multi-span label(선언 위치 hint, 참조→정의 label), help hint, `ZNTCxxxx` 코드별 docs URL 포함.
CLI는 에러 시 exit 1, `@zntc/core`는 `TranspileResult.errors`에 문자열로 노출.

### Asset / RN

- **기본 asset 로더** (#4466) — 아래 확장자는 `--loader` 없이도 기본 `file` 로더가 붙는다.
  전엔 전부 `.none` 이라 `No loader is configured` 에러였다.
  - 이미지: `.png .jpg .jpeg .jfif .pjpeg .pjp .gif .svg .ico .webp .avif .bmp`
  - 폰트: `.woff .woff2 .eot .ttf .otf`
  - 미디어: `.mp4 .webm .ogg .mp3 .wav .flac .aac .opus .mov .m4a .vtt`
  - 기타: `.webmanifest .pdf`
  - 확장자 비교는 대소문자 무시 (`LOGO.PNG` 도 인식). **목록에 없는 확장자는 여전히
    `--loader:.ext=type` 명시가 필요**하다.
- **`--asset-inline-limit=<bytes>`** (기본 `4096`) — 이 크기 **이하** 자산은 별도 파일 대신
  data URL 로 인라인. `0` = 인라인 끔(항상 파일). Vite `assetsInlineLimit` 상당,
  config/JS API 키는 `assetInlineLimit`.
  - **확장자 기본 테이블로 `file` 이 된 자산에만 적용**된다. `--loader:.png=file` 처럼 **명시**
    지정한 로더는 인라인하지 않는다 (명시 의도가 암묵 기본값을 이긴다).
  - `copy` 로더와 RN asset_registry 모드도 인라인 제외 — AssetRegistry 는 파일 경로 +
    `@2x`/`@3x` scale variant 를 전제로 동작한다.
- `@2x` / `@3x` scale variant 자동 감지 + emit
- Metro AssetRegistry 호환 출력 (`--platform=react-native`)

### Vite 식 query-suffix import (#4467)

specifier 뒤에 붙는 query 로 **import 단위**의 로딩 방식을 고른다 (`--loader` 는 확장자 단위).
예전엔 `ZNTC0100 Cannot resolve module` 로 실패했다.

| suffix | 동작 |
| --- | --- |
| `?raw` | 파일 내용을 문자열로 인라인 (`text` 로더) |
| `?url` | 자산으로 방출하고 URL 문자열 export. **`--asset-inline-limit` 무시** — 사용자가 URL 을 명시 요청한 것이므로 4KB 미만이어도 data URL 이 되지 않고 파일로 나온다 |
| `?inline` | data URL 로 인라인 (`dataurl` 로더). 크기와 무관하게 항상 인라인 |
| `?worker` / `?sharedworker` | Worker 생성 함수를 default export — `new W()` 로 Worker 를 만든다 |

```js
import txt from "./data.txt?raw";      // "hello raw content"
import u   from "./icon.png?url";      // "./icon-a1b2c3d4.png"
import i   from "./icon.png?inline";   // "data:image/png;base64,..."
import W   from "./x.worker.js?worker";
const w = new W();
```

- **같은 파일도 query 마다 다른 모듈**이다 — `x.png` 는 자산, `x.png?raw` 는 문자열. 둘 다
  import 하면 각각 나온다 (모듈 경로가 dedup 키).
- `?worker` 는 표준 worker 패턴(`new Worker(new URL(f, import.meta.url), {type:"module"})`)을
  **합성**해 기존 worker 기계를 재사용한다. 별도 청크로 빌드되고 URL 이 최종 파일명으로 재작성된다.
- `?vue&type=style&lang.css` 같은 **알려지지 않은 query 는 건드리지 않는다** — 플러그인이 가상
  경로로 처리하는 기존 관용구다.
- 표준 대체도 여전히 동작한다: `?url` ≈ `new URL(f, import.meta.url)`,
  `?worker` ≈ `new Worker(new URL(f, import.meta.url), {type:"module"})`.

상세: [docs/BUNDLER.md](./BUNDLER.md)

### Crash report

panic 발생 시 Bun 스타일 crash report 출력 — repro 정보 + GitHub 레포 링크.

### Profile (파이프라인 타이밍)

파이프라인 phase 별 소요시간 측정. CLI/NAPI/env 동일 인터페이스.

```bash
# 전체 phase (table)
zntc input.ts --profile=all

# 특정 phase 만
zntc bundle entry.ts --profile=parse,transform

# JSON 출력 (스크립트 용)
zntc bundle entry.ts --profile=all --profile-format=json

# phase 격리 실행 (debug: 지정 phase 이후 skip)
zntc input.ts --stop-after=parse --profile=parse

# 반복 측정 + 통계 (oxc/swc 에도 없는 CLI 벤치마크)
zntc bench --phase=parse ./src/App.tsx --iterations=100
zntc bench --phase=parse ./src/App.tsx --compare=./baseline.json
```

NAPI:

```ts
await build({ ..., profile: ["parse", "transform"], profileLevel: "detailed" });
benchmark({ file: "./App.tsx", phases: ["parse"], iterations: 100 });
```

상세: [docs/DEBUG.md](./DEBUG.md) § Profile & Benchmark.

### Resolver Conditions

`package.json` `exports` 조건에 사용자 조건을 추가한다. 플랫폼 기본 조건은 유지되고,
사용자 조건은 기본 조건 뒤에 병합된다. 실제 선택 순서는 Node/esbuild처럼 `exports` 객체의
키 순서를 따른다.

```bash
zntc --bundle src/index.ts --conditions=development,react-native
```

### Tokenizer Debug Output

네이티브 scanner의 토큰 스트림을 출력한다. 기본은 사람이 읽는 text, `json`은 snapshot이나
도구 연동용이다.

```bash
zntc src/input.ts --tokenize
zntc src/input.ts --tokenize --tokenize-format=json
```
