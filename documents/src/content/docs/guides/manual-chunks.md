---
title: manualChunks
description: 사용자 정의 청크 분할 — Rollup `manualChunks(id, meta)` 호환 API.
---

ZTS 는 Rollup 의 `manualChunks(id, meta)` 시그니처를 호환합니다. 벤더/공통 코드 분리, content 기반 분류, 그래프 토폴로지 기반 분류 등 프로덕션 청크 최적화에 자주 쓰는 패턴을 모두 지원합니다.

## 기본 사용

```ts
import { build } from "@zts/core";

await build({
  entryPoints: ["./src/main.ts"],
  splitting: true,
  outdir: "./dist",
  manualChunks: (id) => {
    if (id.includes("node_modules")) return "vendor";
    return null;
  },
});
```

`manualChunks` 가 반환한 이름의 청크에 모듈이 묶입니다. `null`/`undefined` 를 반환하면 자동 분배.

## meta API — 그래프 토폴로지 기반 분류

두 번째 인자 `meta` 의 `getModuleInfo(id)` 로 모듈 정보를 조회합니다.

```ts
manualChunks: (id, meta) => {
  const info = meta.getModuleInfo(id);
  if (!info) return null;

  // 2개 이상 모듈에서 import 되는 것만 shared 로
  if (info.importers.length >= 2) return "shared";

  // 외부 의존성은 항상 분리
  if (info.isExternal) return "vendor";

  // tree-shake 후 포함되지 않으면 분류 안 함
  if (!info.isIncluded) return null;

  return null;
},
```

### `ManualChunksModuleInfo` 필드

| 필드 | 타입 | 설명 |
|---|---|---|
| `id` | `string` | 모듈 절대 경로 |
| `isEntry` | `boolean` | 엔트리 모듈 여부 |
| `isExternal` | `boolean` | `external` 패턴 매칭으로 번들 제외된 모듈 |
| `hasModuleSideEffects` | `boolean` | `package.json sideEffects` / 글롭 매칭 결과 |
| `code` | `string \| null` | 모듈 source. external/asset 은 null |
| `isIncluded` | `boolean` | tree-shake 후 번들에 포함됐는지 |
| `exports` | `string[]` | export 된 이름 목록 (default 포함) |
| `importers` | `string[]` | static import 한 모듈들의 절대 경로 |
| `dynamicImporters` | `string[]` | `import()` 한 모듈들 |
| `importedIds` | `string[]` | 이 모듈이 static import 한 것들 (external 포함) |
| `dynamicallyImportedIds` | `string[]` | 이 모듈이 dynamic import 한 것들 |
| `syntheticNamedExports` | `boolean` | plugin 정의 — 현재 항상 false (Phase B 대기) |
| `implicitlyLoadedAfterOneOf` | `string[]` | plugin emitFile 옵션 — 현재 항상 [] |
| `implicitlyLoadedBefore` | `string[]` | 같음 |

`info.ast` 만 미노출 — ESTree adapter (별도 epic) 후 추가 예정.

## inlineDynamicImports

dynamic import target 도 importer 와 같은 chunk 로 흡수해 단일 파일 출력에 가까워집니다.

```ts
await build({
  entryPoints: ["./src/main.ts"],
  splitting: true,
  inlineDynamicImports: true,  // dynamic import 도 inline
  outdir: "./dist",
});
```

내부적으로 dynamic-import target 모듈을 `__esm` 래퍼로 묶고 `import("./x")` 호출을 `Promise.resolve().then(() => (init_x(), exports_x))` 로 재작성합니다.

### 보장
- **namespace identity**: `(await import("./x")) === (await import("./x"))`
- **single-execution**: top-level side effect 정확히 1회 실행 (`__esm` 캐싱)
- **live binding**: `export let counter; counter++` 같은 변경이 caller 에 반영됨

## external 처리

`external` 패턴 매칭된 모듈은 번들에 들어가지 않지만 graph 에는 phantom Module 로 등록됩니다 — Rollup parity.

```ts
await build({
  entryPoints: ["./src/main.ts"],
  external: ["react", "react-dom"],
  manualChunks: (id, meta) => {
    // external 도 직접 조회 가능
    const reactInfo = meta.getModuleInfo("react");
    console.log(reactInfo?.isExternal); // true

    // entry 의 importedIds 에 external 포함
    const entry = meta.getModuleInfo(id);
    console.log(entry?.importedIds.includes("react")); // true if entry imports react

    return null;
  },
});
```

## 패턴별 예제

### 벤더/공통 분리

```ts
manualChunks: (id) => {
  if (id.includes("/node_modules/")) return "vendor";
  if (id.includes("/src/components/")) return "components";
  return null;
}
```

### content 기반 분류

`@vendor` 같은 마커가 source 에 있는 모듈만 별도로:

```ts
manualChunks: (id, meta) => {
  const info = meta.getModuleInfo(id);
  if (info?.code?.includes("@vendor")) return "vendor";
  return null;
}
```

### shared chunk (2개 이상 entry 가 공유)

```ts
manualChunks: (id, meta) => {
  const info = meta.getModuleInfo(id);
  if (!info) return null;
  if (info.isEntry) return null;
  if (info.importers.length >= 2) return "shared";
  return null;
}
```

### tree-shake 가능한 라이브러리만 별도 청크

```ts
manualChunks: (id, meta) => {
  const info = meta.getModuleInfo(id);
  if (info && !info.hasModuleSideEffects) return "pure";
  return null;
}
```

## 정책 / 제한

- `manualChunks` resolver 는 모듈당 정확히 1회 호출 (NAPI TSFN — JS 호출 비용 최소화)
- resolver 가 throw 하면 해당 모듈은 `null` 처리 (auto 분배), 번들 중단되지 않음
- string 외 반환 (number, boolean) 은 `null` 동일 취급 (Rollup 스펙)
- `external` 모듈은 resolver 에 직접 호출되지 않음 — phantom 이라 chunk 배정 대상 아님
- dynamic-import target 도 manual 청크에서 제외 (lazy load 의미 보존). `inlineDynamicImports: true` 시 importer 청크로 흡수

## CLI

`manualChunks` 는 함수라 CLI 직접 노출 X — JS API (`@zts/core`) 또는 `zts.config.{js,ts}` 사용.

```ts
// zts.config.ts
import { defineConfig } from "@zts/core";

export default defineConfig({
  entryPoints: ["./src/main.ts"],
  splitting: true,
  inlineDynamicImports: true,
  manualChunks: (id, meta) => {
    if (meta.getModuleInfo(id)?.isExternal) return "vendor";
    return null;
  },
});
```

## 향후

현재 13/14 Rollup `ModuleInfo` 필드 노출. 진행 중:
- **Phase B** (issue #1880): plugin context API (`this.getModuleInfo`/`emitFile`/`resolve`) + `info.meta` 필드
- **Phase C** (issue #1881): ESTree adapter — `info.ast` 노출
