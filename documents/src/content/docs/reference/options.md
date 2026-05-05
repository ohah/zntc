---
title: Transpile 옵션
description: ZTS 트랜스파일러의 전체 옵션 레퍼런스 (JSON Schema 기반)
---

ZTS의 트랜스파일 옵션은 **Zig `TranspileOptionsDto` struct에서 comptime으로 자동 생성된 JSON Schema**를 단일 진실의 소스로 사용합니다. Zig struct를 수정한 뒤 `zig build schema`를 실행하면 이 문서의 기반이 되는 schema가 자동 갱신됩니다.

## Schema URL

`$schema` 참조로 VSCode / IntelliJ 등 에디터에서 JSON 자동완성을 사용할 수 있습니다:

```json
{
  "$schema": "https://ohah.github.io/zts/schemas/transpile-options.schema.json",
  "target": "es2022",
  "sourcemap": true
}
```

> **주의**: 본 문서가 가리키는 schema는 WASM/NAPI가 Zig 엔진으로 **내부 전달**하는 JSON payload의 스키마입니다. 사용자용 `zts.config.*` 로더와 CLI 머지 계층은 `@zts/core`에서 별도로 제공되며 camelCase 옵션을 받습니다. 이 schema의 enum은 Zig native 표현(`"react_native"`)을 사용하므로 config 파일/API 문법과 1:1로 같지 않을 수 있습니다.

## 옵션 목록

### 타겟 / ES 다운레벨

| 옵션 | 타입 | 기본값 | 설명 |
|---|---|---|---|
| `target` | `es5`, `es2015`–`es2025`, `esnext` | `esnext` | ES 다운레벨 타겟. 설정 시 해당 버전 이후 도입된 기능이 자동 downlowering됨 |
| `unsupported` | `integer` (u32) | `0` | `UnsupportedFeatures` 비트마스크 직접 지정. browserslist 해석 결과를 주입할 때 사용 — `target`보다 우선 |
| `runtimePolyfills` | `"off" \| "auto" \| "usage" \| "entry" \| object` | `"off"` | core-js 런타임 API 폴리필 주입. `"auto"`/`"usage"`는 실제 번들 그래프 사용량 기반, `"entry"`는 타겟 기준 전체 필요 모듈 주입 |
| `coreJs` | `string` | installed version | `runtimePolyfills.coreJs`와 같은 core-js-compat 계산 버전 힌트 |

#### Runtime Polyfills / core-js

`target`은 문법 다운레벨링을 담당하고, `runtimePolyfills`는 `Promise`, `Map`, `Object.values`, `String.prototype.replaceAll`, `Array.prototype.at`, `structuredClone` 같은 런타임 API를 `core-js` prelude로 보강합니다.

```ts
import { defineConfig } from "@zts/core";

export default defineConfig({
  entryPoints: ["src/index.ts"],
  bundle: true,
  target: "es5",
  runtimePolyfills: {
    mode: "auto",
    targets: ["ios_saf 12", "safari 12"],
    coreJs: "3.49",
    include: ["es.array.at"],
    exclude: ["web.url"],
  },
});
```

`runtimePolyfills` object는 다음 필드를 받습니다.

| 필드 | 타입 | 설명 |
|---|---|---|
| `mode` | `"auto" \| "usage" \| "entry"` | `"auto"`와 `"usage"`는 동일하게 그래프에서 감지된 사용 API만 후보에서 선택합니다. `"entry"`는 `core-js-compat`가 타겟에 필요하다고 판단한 ES/Web 모듈 전체를 주입합니다 |
| `provider` | `"core-js"` | 현재는 `core-js`만 지원 |
| `targets` | `string \| string[]` | `core-js-compat`에 전달할 Browserslist query. Rspack/SWC `env.targets`와 같은 형식 사용 |
| `coreJs` | `string` | `core-js-compat` 계산에 사용할 core-js 버전. 생략 시 설치된 `core-js/package.json` 버전을 읽음 |
| `include` | `string[]` | 항상 주입할 `core-js` 모듈. `es.array.at` 또는 `core-js/modules/es.array.at.js` 형식 허용 |
| `exclude` | `string[]` | 타겟/usage 계산 뒤 최종 제거할 `core-js` 모듈 |
| `proposals` | `boolean` | `core-js-compat` 조회 시 proposals 포함 |

`runtimePolyfills: "off"`가 기본값이며, 이 경우 `core-js-compat` 로드, graph collector, profile/debug 경로를 실행하지 않습니다. `runtimePolyfills: "auto"` 또는 `"usage"`를 켜면 JS wrapper가 target 기준 주입 가능한 `core-js` 후보와 절대 경로를 계산하고, native bundler가 resolve/load/plugin transform 이후 실제 graph AST에서 사용 API를 집계해 필요한 모듈만 prelude에 넣습니다.

`core-js-compat`와 `core-js`는 optional dependency입니다. 런타임 폴리필을 켤 프로젝트에서는 설치가 필요합니다.

```bash
bun add core-js core-js-compat
```

타겟 query는 Browserslist 문법을 사용합니다.

```ts
runtimePolyfills: {
  mode: "auto",
  targets: ["chrome >= 87", "edge >= 88", "firefox >= 78", "safari >= 14"],
}
```

`ios_saf 12`, `safari 12`, `node 18`처럼 명시적인 query는 지원하지만 `ios12`, `node18` 같은 compact shorthand와 `"iPhone 8"` 같은 physical device name은 지원하지 않습니다. React Native 기본 Hermes 타겟은 `platform: "react-native"`에서 선택하고, top-level `runtimeTargets` 옵션은 제공하지 않습니다.

감지는 정적 graph AST 기준입니다. 로컬 binding/import로 가려진 `Map`, `Object`, `Promise` 등은 전역 API 사용으로 보지 않고, `obj["replaceAll"]()` 같은 동적 computed access는 추론하지 않습니다. 그런 경우 `include`로 명시하거나 `"entry"` 모드를 사용합니다.

### 파싱

| 옵션 | 타입 | 기본값 | 설명 |
|---|---|---|---|
| `flow` | `boolean` | `false` | Flow 타입 스트리핑 활성화 |
| `jsxInJs` | `boolean` | `false` | `.js` / `.jsx` 파일에서도 JSX 허용 (기본은 `.tsx`만) |
| `experimentalDecorators` | `boolean` | `false` | 레거시 TC39 stage-1 데코레이터 |
| `emitDecoratorMetadata` | `boolean` | `false` | 데코레이터 메타데이터 emit (`experimentalDecorators` 필요) |

### JSX

| 옵션 | 타입 | 기본값 | 설명 |
|---|---|---|---|
| `jsx` | `classic`, `automatic`, `automatic_dev` | `classic` | JSX 런타임 선택 |
| `jsxFactory` | `string` | `"React.createElement"` | Classic 모드 factory |
| `jsxFragment` | `string` | `"React.Fragment"` | Classic 모드 Fragment |
| `jsxImportSource` | `string` | `"react"` | Automatic 모드 import source |

### 출력

| 옵션 | 타입 | 기본값 | 설명 |
|---|---|---|---|
| `format` | `esm`, `cjs` | `esm` | 모듈 포맷 |
| `quotes` | `double`, `single`, `preserve` | `double` | 문자열 따옴표 스타일 |
| `platform` | `browser`, `node`, `neutral`, `react_native` | `browser` | 타겟 플랫폼. Node 빌트인 externals, import.meta polyfill 등에 영향 |
| `useDefineForClassFields` | `boolean` | `true` | class field에 `[[Define]]` 시맨틱 적용 |
| `asciiOnly` | `boolean` | `false` | 비-ASCII 문자를 hex 이스케이프로 치환 |
| `charsetUtf8` | `boolean` | `false` | 비-ASCII 문자 그대로 유지 |

`asciiOnly` 와 `charsetUtf8` 은 같은 출력 charset 차원을 양쪽에서 토글하는 짝입니다. CLI 매핑은 비대칭 — `--charset=utf8` 은 `charsetUtf8=true` 로, `--ascii-only` 는 `asciiOnly=true` 로 매핑되며 `--charset=ascii` 는 받지 않습니다.

### Code Splitting / Chunks

| 옵션 | 타입 | 기본값 | 설명 |
|---|---|---|---|
| `splitting` | `boolean` | `false` | dynamic import 경계에서 청크 분리 + 공유 모듈 추출 |
| `manualChunks` | `(id, meta) => string \| null` 또는 `[{name, patterns}]` | — | Rollup 호환 사용자 정의 분할. JS API 는 함수형, `zts.config.json` 은 record form (#2186). [상세 가이드](/zts/guides/manual-chunks/) |
| `inlineDynamicImports` | `boolean` | `false` | dynamic import target 을 importer chunk 로 흡수 + `__esm` 래핑 (단일 파일 출력). CLI: `--inline-dynamic-imports` (#2185) |
| `external` | `string[]` | `[]` | 번들에서 제외할 specifier 목록. graph 에는 phantom Module 로 등록 |
| `preserveModules` | `boolean` | `false` | 번들 대신 원본 디렉토리 구조 유지 (Rollup 호환) |
| `outputExports` | `auto`, `named`, `default`, `none` | `auto` | CJS/UMD entry export 형식 (Rollup `output.exports` 호환). 자세한 시맨틱은 아래 표 |

`outputExports` 4-value 시맨틱:

| 값         | 동작                                                                                                                |
| ---------- | ------------------------------------------------------------------------------------------------------------------- |
| `"auto"`   | default-only → `module.exports = X`. named-only → `exports.X = X` (no `__esModule`). mixed → `exports.X = X` + `__esModule` flag |
| `"named"`  | 항상 named (`exports.X = X`). default 가 함께 있으면 `__esModule` flag 자동 추가 (rolldown `IfDefaultProp` 동작)    |
| `"default"`| `module.exports = X` 단일. default-only 일 때만 정상 출력 — named 가 섞이면 warning + **빈 출력**                   |
| `"none"`   | export 출력 안 함                                                                                                   |

ESM 출력에서는 `outputExports` 가 무시됩니다.

### Minify

| 옵션 | 타입 | 기본값 | 설명 |
|---|---|---|---|
| `minifyWhitespace` | `boolean` | `false` | 공백 제거 |
| `minifyIdentifiers` | `boolean` | `false` | 로컬 식별자 mangling |
| `minifySyntax` | `boolean` | `false` | 구문 레벨 최적화 |

### Drop

| 옵션 | 타입 | 기본값 | 설명 |
|---|---|---|---|
| `dropConsole` | `boolean` | `false` | `console.*` 호출 제거 |
| `dropDebugger` | `boolean` | `false` | `debugger` 문 제거 |

### Sourcemap

| 옵션 | 타입 | 기본값 | 설명 |
|---|---|---|---|
| `sourcemap` | `boolean` | `false` | 소스맵 JSON 생성 |
| `sourcemapMode` | `linked`, `external`, `inline` | `linked` | 소스맵 출력 형식. `linked` = 외부 파일 + `sourceMappingURL` 주석 (esbuild/rolldown 기본값) |
| `sourcemapDebugIds` | `boolean` | `false` | Sentry 호환 Debug ID 삽입 |
| `sourcesContent` | `boolean` | `true` | 소스맵에 원본 소스 포함 |
| `sourceRoot` | `string` | `""` | 소스맵의 `sourceRoot` 필드 |

### Define (치환)

| 옵션 | 타입 | 기본값 | 설명 |
|---|---|---|---|
| `define` | `Array<{key, value}>` | `[]` | 식별자 치환. `value`는 **raw JSON** — 문자열은 인용부호 포함 (예: `value: "\"1.0.0\""`) |

### Diagnostics / Logging

| 옵션 | 타입 | 기본값 | 설명 |
|---|---|---|---|
| `logLevel` | `"silent" \| "error" \| "warning" \| "info" \| "debug" \| "verbose"` | `"warning"` | NAPI build result 의 errors/warnings 배열에 적용되는 필터. `"silent"` 은 errors/warnings 둘 다 빈 배열로 만듦. `"error"` 는 warnings 만 비움. `"warning"` (default) 은 그대로. `"info"` / `"debug"` / `"verbose"` 도 현재 `"warning"` 과 동일 (info-level 진단 미emit). `build()` 는 logLevel 값과 무관하게 throw 하지 않음 — 실패도 `result.errors` 로만 확인 |
| `logLimit` | `number` | `0` | errors/warnings 각 배열의 최대 항목 수. `0` 은 무제한. esbuild `logLimit` 동등 |

## TS API와의 관계

실제 프로그래머블 사용 시에는 `@zts/core` / `@zts/wasm` 패키지의 `transpile()` 함수에 **camelCase + kebab-case enum**이 허용되는 `TranspileOptions` 인터페이스를 씁니다. 프로젝트 설정은 `zts.config.{ts,mts,cts,mjs,js,cjs,json}` / `zts.workspace.*` 로더가 처리합니다:

```ts
import { transpile } from "@zts/wasm";

transpile(source, {
  target: "es2021",
  platform: "react-native",  // 하이픈 허용 — JS 래퍼가 "react_native"로 변환해 전달
  jsx: "automatic-dev",      // 동일 — "automatic_dev"로 변환
});
```

TS 인터페이스는 JSDoc / IDE hover를 풍부하게 유지하기 위해 handwritten입니다 (biome / swc도 동일). 두 표현은 JS 래퍼의 `buildOptionsJson`에서 단방향 변환됩니다.

## Schema 재생성

DTO 수정 후:

```bash
zig build schema
```

`documents/public/schemas/transpile-options.schema.json`이 갱신됩니다. 사이트 배포 시 자동으로 `/zts/schemas/transpile-options.schema.json`로 서빙.
