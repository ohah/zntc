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

### Code Splitting / Chunks

| 옵션 | 타입 | 기본값 | 설명 |
|---|---|---|---|
| `splitting` | `boolean` | `false` | dynamic import 경계에서 청크 분리 + 공유 모듈 추출 |
| `manualChunks` | `(id, meta) => string \| null` 또는 `[{name, patterns}]` | — | Rollup 호환 사용자 정의 분할. JS API 는 함수형, `zts.config.json` 은 record form (#2186). [상세 가이드](/zts/guides/manual-chunks/) |
| `inlineDynamicImports` | `boolean` | `false` | dynamic import target 을 importer chunk 로 흡수 + `__esm` 래핑 (단일 파일 출력). CLI: `--inline-dynamic-imports` (#2185) |
| `external` | `string[]` | `[]` | 번들에서 제외할 specifier 목록. graph 에는 phantom Module 로 등록 |
| `preserveModules` | `boolean` | `false` | 번들 대신 원본 디렉토리 구조 유지 (Rollup 호환) |
| `outputExports` | `auto`, `named`, `default`, `none` | `auto` | CJS/UMD entry export 형식 (Rollup `output.exports` 호환, #2159). `default` 모드 + named export 섞이면 빌드 실패 |

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
| `sourcemapMode` | `linked`, `inline`, `external`, `hidden` | `linked` | 소스맵 출력 형식 (#2152). `linked` = 외부 파일 + `sourceMappingURL` 주석 (esbuild/rolldown 기본값) |
| `sourcemapDebugIds` | `boolean` | `false` | Sentry 호환 Debug ID 삽입 |
| `sourcesContent` | `boolean` | `true` | 소스맵에 원본 소스 포함 |
| `sourceRoot` | `string` | `""` | 소스맵의 `sourceRoot` 필드 |

### Define (치환)

| 옵션 | 타입 | 기본값 | 설명 |
|---|---|---|---|
| `define` | `Array<{key, value}>` | `[]` | 식별자 치환. `value`는 **raw JSON** — 문자열은 인용부호 포함 (예: `value: "\"1.0.0\""`) |

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
