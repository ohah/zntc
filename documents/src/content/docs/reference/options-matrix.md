---
title: 옵션 매트릭스
description: CLI, JS API, config, schema 사이의 ZTS 옵션 노출 상태를 한곳에서 확인합니다.
---

ZTS 옵션은 네 개의 surface로 노출됩니다. 새 기능을 추가하거나 문서를 확인할 때는 이 표를 기준으로 누락을 점검하세요.

- **CLI**: `zts` 명령과 `packages/core/bin/cli-flags.mjs`.
- **JS API**: `@zts/core`의 `transpile()` / `build()` / `watch()` 타입.
- **Config**: `zts.config.*` / `zts.workspace.*` 로더가 받는 사용자 설정.
- **Schema**: transpile-only JSON schema. 번들러 전용 필드는 포함하지 않습니다.

## 핵심 매트릭스

| 기능군 | CLI | JS API | Config | Schema | 비고 |
| ------ | --- | ------ | ------ | ------ | ---- |
| 입출력 (`outfile`, `outdir`, `outbase`, `outExtension`) | ✅ | ✅ | ✅ | ❌ | `outdir`/패턴 옵션은 번들러 출력 전용 |
| 모듈 포맷 (`format`, `platform`) | ✅ | ✅ | ✅ | ✅ | `react-native`는 RN preset을 함께 켭니다 |
| ES/엔진 타겟 (`target`, `browserslist`) | ✅ | ✅ | ✅ | ✅ | `browserslist`는 config/API 전용, 지정 시 `target`보다 우선 |
| 런타임 폴리필 (`runtimePolyfills`, `runtimeTarget`, `coreJs`) | ✅ | ✅ | ✅ | ❌ | graph usage 기반 core-js 주입 |
| JSX / TS / Flow 변환 | ✅ | ✅ | ✅ | ✅ | `tsconfig` 일부 필드는 config 미지정 시 fallback |
| define/drop/inject/pure | ✅ | ✅ | ✅ | 일부 | `dropLabels`, `pure`, `inject`는 번들러 쪽 의미가 큼 |
| minify 세분화 | ✅ | ✅ | ✅ | ✅ | `mangle-props`류 property mangle은 정책상 미지원 |
| source map (`sourcemapMode`, `sourcesContent`, `sourceRoot`) | ✅ | ✅ | ✅ | ✅ | RN sourcemap 출력 옵션은 RN CLI 문서 참고 |
| resolver (`external`, `alias`, `fallback`, `conditions`) | ✅ | ✅ | ✅ | ❌ | array/RegExp alias는 async `build()`/`watch()`만 |
| loader / asset names / public path | ✅ | ✅ | ✅ | ❌ | app mode의 HTML/CSS asset rewrite와 별도 |
| code splitting / preserve modules | ✅ | ✅ | ✅ | ❌ | `splitting`은 `outdir` 필요 |
| `manualChunks` | ❌ | ✅ | ✅ | ❌ | 함수형은 `zts.config.{ts,js}` 또는 JS API 전용 |
| `metafile` / `analyze` | ✅ | ✅ | 부분 | ❌ | `metafile`은 config 가능, `analyze`는 CLI/API 중심. `meta.json`은 [/analyze/](/zts/analyze/)에서 확인 가능 |
| watch / serve / dev server | ✅ | ✅ | ✅ | ❌ | `watch()`는 rich event payload와 lazy sourcemap API 제공 |
| app builder (`dev`, `build`, `preview`) | ✅ | 일부 | ✅ | ❌ | HTML/env/public/CSS pipeline은 `@zts/web` 필요 |
| plugin hooks | ✅ (`--plugin`) | ✅ | ✅ | ❌ | `buildSync()`에서는 JS plugin 미지원 |
| diagnostics / profile / debug | ✅ | ✅ | 일부 | ❌ | profile은 CLI와 `configureProfile()` 양쪽 |
| workspace | ✅ | ✅ | ✅ | ❌ | `zts.workspace.*`로 여러 entry를 관리 |

## 동기 API 제약

`buildSync()`는 native worker가 JS callback을 기다리는 구조와 충돌하므로 JS plugin, array/RegExp alias, host RegExp 기반 hook을 실행하지 않습니다. 같은 설정이 필요하면 async `build()` 또는 `watch()`를 사용하세요.

## 갱신 체크리스트

새 옵션을 추가할 때는 다음 순서로 확인합니다.

1. `@zts/core` public type에 필드가 있는지 확인합니다.
2. CLI로 노출해야 하는 기능이면 `cli-flags.mjs`와 `zts.mjs` help/parse 테스트를 갱신합니다.
3. config에서 받아야 하면 `KNOWN_CONFIG_KEYS`, typo suggestion, config merge 테스트를 갱신합니다.
4. transpile-only 옵션이면 `zig build schema`로 schema와 `reference/options`를 갱신합니다.
5. CLI / JS API / config 중 일부만 가능한 경우 이 매트릭스와 관련 가이드에 제약을 명시합니다.

## 관련 문서

- [CLI 레퍼런스](/zts/reference/cli/)
- [NAPI / JS API](/zts/reference/napi/)
- [Transpile 옵션](/zts/reference/options/)
- [설정 파일](/zts/guides/config-file/)
