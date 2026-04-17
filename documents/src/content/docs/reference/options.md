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

> **주의**: 본 문서가 가리키는 schema는 WASM/NAPI가 Zig 엔진으로 **내부 전달**하는 JSON payload의 스키마입니다. 사용자 친화적 config 파일(`zts.config.json`) 로더는 별도 PR에서 추가될 예정입니다. 현재 TS API(`packages/shared`의 `TranspileOptions` 인터페이스)는 camelCase + kebab-case enum(`"react-native"`)을 쓰지만, 이 schema의 enum은 Zig native 표현(`"react_native"`)입니다.

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
| `sourcemapDebugIds` | `boolean` | `false` | Sentry 호환 Debug ID 삽입 |
| `sourcesContent` | `boolean` | `true` | 소스맵에 원본 소스 포함 |
| `sourceRoot` | `string` | `""` | 소스맵의 `sourceRoot` 필드 |

### Define (치환)

| 옵션 | 타입 | 기본값 | 설명 |
|---|---|---|---|
| `define` | `Array<{key, value}>` | `[]` | 식별자 치환. `value`는 **raw JSON** — 문자열은 인용부호 포함 (예: `value: "\"1.0.0\""`) |

## TS API와의 관계

실제 프로그래머블 사용 시에는 `@zts/core` / `@zts/wasm` 패키지의 `transpile()` 함수에 **camelCase + kebab-case enum**이 허용되는 `TranspileOptions` 인터페이스를 씁니다:

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
