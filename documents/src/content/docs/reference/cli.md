---
title: CLI 레퍼런스
description: ZNTC CLI 옵션 전체 목록
---

## 트랜스파일

```bash
zntc <file.ts>                      # → stdout
zntc <file.ts> -o <out.js>          # → 파일
zntc <dir/> --outdir <out/>         # 디렉토리 재귀 변환
zntc - < input.ts                   # stdin 입력
```

## 번들

```bash
zntc --bundle <entry.ts>                               # → stdout
zntc --bundle <entry.ts> -o out.js                     # → 파일
zntc --bundle <entry.ts> --splitting --outdir dist     # 코드 스플리팅
zntc --bundle <entry.ts> --preserve-modules --outdir dist  # 모듈별 출력 (라이브러리)
zntc --bundle <entry.ts> --plugin zntc.config.js        # JS 플러그인
```

## 앱 빌더

```bash
zntc dev [root]             # index.html 기반 dev server
zntc build [root]           # HTML rewrite + hashed assets → dist/
zntc preview [outdir]       # 빌드 산출물 정적 서빙
```

기본 구조는 `index.html`, `public/`, `src/main.ts(x)`, `.env*`입니다.
`zntc build`는 `<script type="module" src>`를 번들 엔트리로 사용하고, CSS `url()`,
HTML asset URL, `%ENV%` 토큰을 rewrite하며 static split chunk는 `modulepreload`로
주입합니다. `zntc dev`는 같은 HTML/env/public prepare 단계를 사용하고 CSS 변경은 페이지
전체 reload 없이 stylesheet만 갱신합니다.

| 옵션                        | 설명                                                                       |
| --------------------------- | -------------------------------------------------------------------------- |
| `--entry-html <file>`       | HTML entry 파일 (기본: `index.html`)                                       |
| `--public-dir <dir\|false>` | public 파일 복사 디렉토리 또는 비활성화                                    |
| `--base <path>`             | HTML/CSS asset URL prefix                                                  |
| `--mode <name>`             | env/config mode (`dev`: `development`, `build`: `production`)              |
| `--env-prefix <list>`       | 노출할 env prefix CSV (기본: `VITE_,ZNTC_`)                                |
| `--env-dir <dir>`           | `.env*` 파일 탐색 디렉토리                                                 |
| `--spa-fallback[=file]`     | `preview`에서 route-like 404 요청을 `index.html` 또는 지정 파일로 fallback |

앱 root에 `postcss.config.{js,mjs,cjs,json}` 또는 `.postcssrc*`가 있으면 CSS에 자동
적용됩니다. `zntc dev`는 원본 CSS와 PostCSS `dependency` / `dir-dependency` 메시지를
watch하고 CSS-only 변경은 stylesheet HMR로 보냅니다. Tailwind v4는
`@tailwindcss/postcss` 설정을 지원합니다. 앱 모드는 CSS Modules(`.module.css`)를
scoped class map으로 변환하며 default export와 가능한 named export를 제공합니다.
`.scss` / `.sass`는 선택 의존성 `sass`가 설치되어 있으면 PostCSS 전에 CSS로 컴파일됩니다.

## React Native 초기화 (`@zntc/init`)

기존 React Native CLI 프로젝트에 ZNTC scripts와 설정을 추가하는 별도 npx 진입점입니다.
Expo 프로젝트 생성/초기화는 현재 범위 밖입니다.

```bash
npx @zntc/init
npx @zntc/init --help
```

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

| 옵션                                       | 설명                                                 |
| ------------------------------------------ | ---------------------------------------------------- |
| `--root <dir>`                             | 프로젝트 루트. 기본값은 현재 디렉터리                |
| `--platform <ios\|android>`                | `start` script의 기본 RN platform. 기본값은 `ios`    |
| `--zntc-version <range>`                   | 추가할 `@zntc/core` / `@zntc/react-native` 버전 범위 |
| `--package-manager <bun\|npm\|pnpm\|yarn>` | 초기화 후 출력할 install 명령 힌트                   |
| `--no-metro-fallback`                      | Metro fallback script를 추가하지 않음                |
| `--force`                                  | 기존 `zntc.config.ts` 덮어쓰기                       |
| `--dry-run`                                | 파일을 쓰지 않고 변경 계획만 출력                    |
| `--help`, `-h`                             | 도움말 출력                                          |

## 입출력

| 옵션                        | 설명                                                             |
| --------------------------- | ---------------------------------------------------------------- |
| `-o, --out-file <path>`     | 출력 파일 경로 (JS wrapper 는 `--outfile` alias 도 받음)         |
| `--outdir <path>`           | 출력 디렉토리 (디렉토리 입력·`--splitting`·`--preserve-modules`) |
| `--outbase=<dir>`           | 출력 기준 디렉토리 (공통 prefix 계산)                            |
| `--out-extension:.js=<ext>` | 출력 확장자 변경 (예: `.mjs`)                                    |
| `--clean`                   | 빌드 전 outdir 비우기                                            |

## 모듈 포맷 / 플랫폼

| 옵션                                              | 설명                                                               |
| ------------------------------------------------- | ------------------------------------------------------------------ |
| `--format=esm\|cjs\|iife\|umd\|amd`               | 모듈 포맷 (기본: `esm`)                                            |
| `--platform=browser\|node\|neutral\|react-native` | 타겟 플랫폼                                                        |
| `--rn-platform=ios\|android`                      | RN 서브 플랫폼 (`.ios.*`/`.android.*` 확장자)                      |
| `--target=<spec>`                                 | ES 타겟: `es2015`~`esnext` 또는 엔진 버전 (`chrome80,safari14` 등) |
| `--runtime-polyfills=auto\|usage\|entry\|off`     | core-js 런타임 API 폴리필 주입. `auto`/`usage`는 graph usage 기반  |
| `--runtime-target=<query>`                        | core-js 폴리필 Browserslist 타겟. 반복 가능 (`ios_saf 12`)         |
| `--core-js=<version>`                             | core-js-compat 계산에 사용할 core-js 버전                          |
| `--global-name=<name>`                            | IIFE export 변수명                                                 |

## 미니파이

| 옵션                                | 설명                                                           |
| ----------------------------------- | -------------------------------------------------------------- |
| `--minify`                          | 세 가지 모두 켜기 (shortcut)                                   |
| `--minify-whitespace`               | 공백/세미콜론/줄바꿈만 축약 (디버깅 가능)                      |
| `--minify-syntax`                   | `true`→`!0`, 괄호 제거, constant folding                       |
| `--minify-identifiers`              | 지역 변수명 단축                                               |
| `--keep-names`                      | 함수/클래스 `.name` 보존                                       |
| `--charset=utf8`                    | non-ASCII 문자를 그대로 유지 (parser 는 `utf8` 만 받음)        |
| `--ascii-only`                      | non-ASCII → `\uXXXX` (반대 방향 — `--charset=ascii` 는 미지원) |
| `--mangle-report=<path>`            | minify-identifiers 적용 시 원본↔축약 매핑 JSON 출력            |
| `--quotes=double\|single\|preserve` | 문자열 따옴표 스타일                                           |
| `--line-limit=<n>`                  | 안전한 토큰 경계에서 긴 출력 라인 줄바꿈 (`0`은 무제한)        |

## 소스맵

| 옵션                      | 설명                                                         |
| ------------------------- | ------------------------------------------------------------ |
| `--sourcemap`             | `.js.map` 외부 파일 + `sourceMappingURL` 주석 (linked, 기본) |
| `--sourcemap=linked`      | linked 명시 (#2152) — 동일                                   |
| `--sourcemap=inline`      | data URL 인라인                                              |
| `--sourcemap=external`    | sourceMappingURL 주석 없이 외부만                            |
| `--sourcemap-debug-ids`   | Sentry debugId 삽입                                          |
| `--sources-content=false` | `sourcesContent` 필드 생략                                   |
| `--source-root=<path>`    | sourceRoot 필드                                              |

## 변환 / 치환

| 옵션                     | 설명                                                             |
| ------------------------ | ---------------------------------------------------------------- |
| `--define:KEY=VALUE`     | 글로벌 치환 (`process.env.NODE_ENV` → `"production"` 등)         |
| `--drop=console`         | `console.*` 호출 제거                                            |
| `--drop=debugger`        | `debugger` 문 제거                                               |
| `--drop-labels=DEV,TEST` | 지정한 labeled statement 전체 제거                               |
| `--inject:<path>`        | 자동 import (shim)                                               |
| `--pure:CALL`            | 순수 호출 패턴 등록 (예: `--pure:React.createElement`)           |
| `--ignore-annotations`   | `/* @__PURE__ */`, `sideEffects` 등 tree-shaking annotation 무시 |

## JSX

| 옵션                                      | 설명                                                               |
| ----------------------------------------- | ------------------------------------------------------------------ |
| `--jsx=classic\|automatic\|automatic-dev` | JSX 런타임                                                         |
| `--jsx-dev`                               | `--jsx=automatic-dev` shortcut                                     |
| `--jsx-factory=<fn>`                      | classic factory (기본: `React.createElement`)                      |
| `--jsx-fragment=<fn>`                     | classic Fragment                                                   |
| `--jsx-import-source=<pkg>`               | automatic import source (기본: `react`)                            |
| `--jsx-in-js`                             | `.js` 파일에서도 JSX 파싱 허용                                     |
| `--jsx-side-effects`                      | 사용되지 않은 JSX expression을 side-effect가 있는 것으로 보고 보존 |

## TypeScript

| 옵션                                           | 설명                                                                     |
| ---------------------------------------------- | ------------------------------------------------------------------------ |
| `-p, --project <path>, --tsconfig-path <path>` | tsconfig.json 경로/디렉토리                                              |
| `--experimental-decorators`                    | legacy decorator (`__decorateClass`)                                     |
| `--emit-decorator-metadata`                    | decorator metadata emit (`experimentalDecorators` 필요, JS wrapper 전용) |
| `--use-define-for-class-fields=false\|true`    | 클래스 필드 의미론                                                       |
| `--verbatim-module-syntax`                     | TS `verbatimModuleSyntax` import/export 보존                             |
| `--tsconfig-raw=<json>`                        | inline tsconfig JSON 문자열 (esbuild `tsconfigRaw` 호환)                 |

## Flow

| 옵션     | 설명                                          |
| -------- | --------------------------------------------- |
| `--flow` | Flow 타입 스트리핑 (`@flow` pragma 자동 감지) |

## 번들 전용

| 옵션                               | 설명                                                                                                                                |
| ---------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------- |
| `--bundle`                         | 번들 모드 활성화                                                                                                                    |
| `--splitting`                      | 코드 스플리팅 (`--outdir` 필요)                                                                                                     |
| `--no-splitting`                   | config에서 켠 splitting을 CLI에서 비활성화                                                                                          |
| `--preserve-modules`               | 모듈별 출력 (라이브러리 빌드)                                                                                                       |
| `--preserve-modules-root=<dir>`    | 출력 구조 기준 디렉토리                                                                                                             |
| `--inline-dynamic-imports`         | dynamic import target 을 entry chunk 에 흡수 (Rollup `inlineDynamicImports`, #2185)                                                 |
| `--output-exports=<mode>`          | CJS/UMD entry export 형식 — `auto\|named\|default\|none` (Rollup `output.exports`, #2159)                                           |
| `--entry-names=<pattern>`          | 엔트리 파일명 패턴 (`[name]`, `[hash]`)                                                                                             |
| `--chunk-names=<pattern>`          | 청크 파일명 패턴                                                                                                                    |
| `--asset-names=<pattern>`          | 에셋 파일명 패턴                                                                                                                    |
| `--loader:.ext=type`               | 확장자별 로더 (`file\|dataurl\|base64\|text\|binary\|copy\|empty\|json\|css\|js\|ts\|jsx\|tsx`)                                     |
| `--metafile` / `--metafile=<path>` | 빌드 메타 JSON (stdout 또는 파일)                                                                                                   |
| `--analyze`                        | 번들 분석 리포트 (stderr 출력). 디스크에 JSON 으로 저장하려면 `--metafile=<path>` 명시. [/analyze/](/zntc/analyze/)에서 업로드 가능 |
| `--legal-comments=<mode>`          | 라이선스 주석: `none\|inline\|eof\|linked\|external` (`linked`/`external` 은 현재 `eof` fallback)                                   |
| `--packages=external`              | bare package import를 모두 external 처리                                                                                            |
| `--banner:js=<text>`               | 출력 앞 텍스트 (bare `--banner=` 은 JS wrapper 만 지원)                                                                             |
| `--footer:js=<text>`               | 출력 뒤 텍스트 (bare `--footer=` 은 JS wrapper 만 지원)                                                                             |
| `--intro=<text>`                   | format wrapper 내부 bundle 앞 텍스트 (JS wrapper 전용 — native parser 미지원)                                                       |
| `--outro=<text>`                   | format wrapper 내부 bundle 뒤 텍스트 (JS wrapper 전용 — native parser 미지원)                                                       |
| `--global:FROM=TO`                 | IIFE/UMD external specifier를 global 변수명에 매핑                                                                                  |
| `--global-identifier=<name>`       | scope hoisting 시 예약할 전역 식별자 (반복 가능)                                                                                    |
| `--polyfill=<path>`                | 번들 시작 시 즉시 실행 폴리필 경로 (반복 가능, 절대 경로 자동 변환)                                                                 |
| `--run-before-main=<path>`         | 엔트리 모듈 직전에 실행할 모듈 경로 (반복 가능, 절대 경로 자동 변환)                                                                |
| `--public-path=<url>`              | 에셋 URL prefix                                                                                                                     |
| `--shim-missing-exports`           | 없는 export에 `undefined` shim                                                                                                      |

## Resolve

| 옵션                                    | 설명                                                     |
| --------------------------------------- | -------------------------------------------------------- |
| `--external <pkg>` / `--external=<pkg>` | 번들에서 제외 (반복 가능)                                |
| `--alias:FROM=TO`                       | import 경로 별칭                                         |
| `--resolve-extensions=<exts>`           | 확장자 탐색 순서 (예: `.ios.ts,.ts,.js`)                 |
| `--main-fields=<fields>`                | package.json 필드 순서 (예: `react-native,browser,main`) |
| `--conditions=<list>`                   | package exports 조건 CSV 추가 (예: `prod,react-native`)  |
| `--node-paths=<list>`                   | bare specifier 추가 탐색 경로 CSV                        |
| `--preserve-symlinks`                   | 심링크 실제 경로 해석 안 함                              |

## Watch / Dev Server

| 옵션                            | 설명                                                                            |
| ------------------------------- | ------------------------------------------------------------------------------- |
| `-w, --watch`                   | 파일 변경 감시 (증분 리빌드)                                                    |
| `--watch-json`                  | NDJSON 이벤트 출력 (외부 HMR 연동)                                              |
| `--watch-delay=<ms>`            | 디바운스 지연                                                                   |
| `--watch-folder=<dir>`          | 감시 루트에 디렉토리 추가 (Metro `watchFolders` 호환, 절대경로 변환, 반복 가능) |
| `--watch-include=<glob>`        | watchFolders 스캔 시 포함할 glob (반복 가능)                                    |
| `--watch-exclude=<glob>`        | watchFolders 스캔 시 제외할 glob (반복 가능)                                    |
| `--dev`                         | dev 모드 활성화 (HMR 런타임 주입 등 dev 관련 동작 켜기)                         |
| `--serve [dir]`                 | 정적 파일 서버 (기본: `.`)                                                      |
| `--port <n>`                    | 서버 포트                                                                       |
| `--host [addr]`                 | 바인딩 주소                                                                     |
| `--strict-port`                 | 지정한 포트를 사용할 수 없으면 다음 포트로 넘어가지 않고 실패                   |
| `--certfile <path>`             | HTTPS 인증서 파일 (`preview`/serve)                                             |
| `--keyfile <path>`              | HTTPS 개인키 파일 (`preview`/serve)                                             |
| `--open`                        | 브라우저 자동 열기                                                              |
| `--proxy /api=http://host:port` | API 프록시                                                                      |

**Dev Server 외부 인터페이스:** `/sse/events` (SSE 빌드 이벤트), `/reset-cache` (Control API), `/mcp` (Model Context Protocol — Claude Code 등 LLM 에이전트 연동).

## 플러그인 / 실행

| 옵션                        | 설명                                                  |
| --------------------------- | ----------------------------------------------------- |
| `--plugin <path>`           | JS/TS 플러그인 또는 설정 파일                         |
| `--jobs=<n>`                | 병렬 스레드 수                                        |
| `--config <path>`           | `zntc.config.*` 자동 탐색 대신 명시 config 사용       |
| `--workspace-config <path>` | `zntc.workspace.*` 자동 탐색 대신 명시 workspace 사용 |
| `--workspace <name>`        | workspace entry 하나만 선택                           |

## 진단 / 로깅

| 옵션                         | 설명                                                                               |
| ---------------------------- | ---------------------------------------------------------------------------------- |
| `--log-level=<level>`        | `silent\|error\|warning\|info\|debug\|verbose`                                     |
| `--log-limit=<n>`            | 표시할 진단 최대 개수                                                              |
| `--profile=<list>`           | profile category CSV 수집 (`all`, `parse`, `transform` 등)                         |
| `--profile-level=<level>`    | profile 상세 수준: `summary\|detailed\|per-module\|per-pass`                       |
| `--profile-format=<format>`  | profile 출력: `table\|tree\|json\|csv`                                             |
| `--tokenize[=false]`         | 코드 생성 대신 scanner token 출력                                                  |
| `--tokenize-format=<format>` | token 출력 형식: `text\|json`                                                      |
| `--stop-after=<phase>`       | 지정 phase 이후 중단하는 디버그 옵션 (`scan\|parse\|semantic\|transform\|codegen`) |
| `--test262 <dir>`            | Zig Test262 runner 실행                                                            |
| `--allow-overwrite`          | 입력 파일과 같은 출력 경로를 명시적으로 허용합니다. 기본값은 차단입니다.           |
| `-h, --help`                 | 도움말                                                                             |

## Benchmark (`zntc bench`)

지정한 phase 를 N 회 반복 실행하며 mean/median/p95/p99/stddev/min/max 를 출력하는 서브커맨드. baseline save/compare 로 최적화 전후 비교에 사용.

| 옵션                      | 설명                                                                         |
| ------------------------- | ---------------------------------------------------------------------------- |
| `--phase=<list>`          | 측정할 profile category CSV (필수, 예: `parse,transform`). `all`/`none` 금지 |
| `--iterations=<n>`        | 반복 횟수 (기본: 100, ≥ 1)                                                   |
| `--warmup=<n>`            | 본 측정 전 warmup 회수 (기본: 10)                                            |
| `--save=<path>`           | 결과를 baseline JSON 으로 저장                                               |
| `--compare=<path>`        | 기존 baseline JSON 과 비교 출력                                              |
| `--format=<fmt>`          | 출력 포맷 — `table\|tree\|json\|csv` (기본: `table`)                         |
| `--profile-level=<level>` | profile 상세 수준 (`summary\|detailed\|per-module\|per-pass`)                |

```bash
zntc bench --phase=parse,transform --iterations=200 --warmup=20 src/large.ts
zntc bench --phase=parse --save=baseline.json src/main.ts
zntc bench --phase=parse --compare=baseline.json src/main.ts
```

## 참고

- JS API(`@zntc/core`)는 `packages/core/index.ts`에서 동일한 옵션을 프로그램적으로 제공합니다.
- 옵션 surface별 지원 범위는 [옵션 매트릭스](/zntc/reference/options-matrix/)에서 확인하세요.
- `--metafile` 결과는 [Metafile 분석](/zntc/analyze/) 페이지에서 시각화할 수 있습니다.
- Vite 어댑터는 `@zntc/vite-plugin` 또는 `vitePlugin()`으로 사용하세요.
- Rspack / Webpack 5 어댑터는 `@zntc/rspack-loader` 를 사용하세요. ([가이드](/zntc/guides/rspack-loader/))
- 미지원 옵션 / 향후 계획은 [docs/ROADMAP.md](https://github.com/ohah/zntc/blob/main/docs/ROADMAP.md) 참고.
