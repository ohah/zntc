# Roadmap & Status

## ✅ 완료
| Phase | 내용 | 상태 |
|-------|------|------|
| 1. 렉서 | 토큰 ~208개, SIMD, 유니코드, JSX, RegExp 검증 | ✅ |
| 2. 파서 | AST ~200 Tag, TS/JSX, 에러 복구, semantic analysis | ✅ |
| 3. 트랜스포머 | TS 스트리핑, enum/namespace IIFE, JSX, ESM→CJS, decorator | ✅ |
| 4. 코드젠+CLI | 포맷팅, minify, 소스맵 V3, --ascii-only | ✅ |
| 5. CLI 고급 | stdin, 에러 프레임, --outdir, tsconfig, --watch | ✅ |
| 6a. 번들러 | resolver, 모듈 그래프, linker, tree-shaking, code splitting | ✅ |
| 6a-ts | tree-shaker 2단계 — export 수준 DCE (purity.zig, tslib 95% 감소) | ✅ |
| 6a-si | StmtInfo 기반 statement DCE (rolldown 방식, pathe ESM 77% 감소) | ✅ |
| 6a-ex | exports 조건 해석 Node.js 스펙 준수 (tslib CJS→ESM 해결) | ✅ |
| 6b. Dev server | HTTP+WS, Live Reload, HMR, React Fast Refresh, CSS 핫 리로드 | ✅ |
| Test262 | 50,504건 100% 통과 | ✅ |
| Smoke | 131개 패키지 (mitt, zustand, 엔진 타겟 4개 추가), avg 0.94x, ❌ 0개 | ✅ |
| 7-2. emit 병렬화 | 모듈별 transform+codegen 스레드 풀 실행 | ✅ |
| 7-3. resolve 병렬화 | 배치 내 resolve 스레드 풀 + ResolveCache Mutex | ✅ |
| 7-fix. fixpoint oscillation | 미사용 모듈 제거를 fixpoint 후로 이동 (100회→2회) | ✅ |
| 8. AST 미니파이어 | constant folding, DCE, boolean simplification, comma operator | ✅ |
| 9. 배치 A | 번들러 옵션 10개 (alias, banner, globalName, publicPath, JSON ESM 등) | ✅ |
| 10. 배치 B | content hash + naming 패턴 (--entry-names, --chunk-names) | ✅ |
| 11. 배치 C | Asset 로더 (file, dataurl, text, binary, copy) + --loader CLI | ✅ |
| 12. 배치 D | metafile, analyze, legal-comments, inject, keepNames | ✅ |
| 13. Flow | Flow 타입 스트리핑 (TIER 1+2+3), flow.zig 독립 파싱, Metro 410/410 통과 | ✅ |
| 14. RN Resolve | --resolve-extensions, --main-fields (플랫폼 확장자 + package.json 필드 순서) | ✅ |
| 15. ES 타겟 | --target=es2015~esnext, ES 버전별 다운레벨링 (es2015~es2024 트랜스포머) | ✅ |
| 16. 엔진 타겟 | --target=chrome80,safari14 엔진 버전별 feature-level 다운레벨링 | ✅ |
| 17. Web Worker | new Worker(new URL(...)) 자동 감지 → 별도 IIFE 번들 (esbuild 미지원) | ✅ |
| 18. scan 파이프라인 | 배치→파이프라인 (scanWorker: parse→resolve→spawn), 총합 -15% | ✅ |
| 19. Producer-Consumer | 워커: parse+resolve만, 메인: sole writer. pre-allocation 제거, 포인터 안전 | ✅ |
| 20. RN 플랫폼 | `--platform=react-native` 프리셋 (resolve-extensions, main-fields, Flow, exports 조건) | ✅ |
| 21. watch-json | `--watch-json` NDJSON 이벤트 출력 (외부 번들러 연동용) | ✅ |
| 22. 증분 빌드 | PersistentModuleStore 파싱 캐시 + ResolveCache 보존 (watch/serve 리빌드 최적화) | ✅ |

## 번들러 성능 현황 (2592모듈, 2026-03-31 실측)
ZTS 136ms vs esbuild 110ms (**1.24배**).

| 단계 | ZTS | esbuild | 배율 | 비고 |
|------|-----|---------|------|------|
| scan (resolve+parse) | 101ms | ~80ms | 1.3x | 파이프라인화 완료 |
| tree-shake | 15ms | 1ms | 15x | fixpoint 2회 + stmtinfo + crossBFS |
| link | 16ms | 54ms | 0.3x | ZTS가 빠름 |
| emit | 15ms | 32ms | 0.5x | ZTS가 빠름 |
| **총합** | **134ms** | **107ms** | **1.25x** | |

## 🔜 다음 우선순위

**SIMD 렉서 가속**
- scan이 총합의 75% (101ms) — 대부분이 parse (렉서+파서)
- 렉서 공백/식별자/문자열 스캔에 SIMD 적용 → parse 10-20% 개선 예상
- scan ~10ms 절감 가능 (134ms → ~124ms)

**CSS 번들링**
- 현재 플러그인 위임 (`--loader:.css=text` 또는 PostCSS/Lightning CSS 플러그인)
- 실사용에서 가장 자주 부딪히는 부재 기능
- 자체 CSS 파서 (Zig 네이티브 `@import` 해석, CSS Modules) — XL급

**import.meta.glob**
- Vite 호환 기능, DX 개선 — M급 (1~2일)

**scan Producer-Consumer** ✅ 완료
- bun/esbuild 방식: 워커는 parse+resolve만, 메인 스레드가 sole writer (addModule/addDependency)
- 워커 실행 중 modules realloc 없음 → pre-allocation 해킹 제거, 포인터 안정성 근본 해결
- 성능: 파이프라인 대비 ~10ms 느리나 (배치 경계), 안전성 확보가 우선

**tree-shake 병렬화** (후순위, ROI 낮음)
- 현재 15ms — 이미 fixpoint oscillation 수정으로 51ms → 15ms 개선됨
- StmtInfo 구축 병렬화로 ~5ms 절감 가능하나 총합 대비 체감 미미

## ⏳ 미완료
- **.d.ts 생성** (isolatedDeclarations) — 후순위, 당분간 tsc에 위임
- **SIMD** — 렉서 공백/식별자/문자열 스캔 가속 (parse 10-20% 개선 예상)
- **WASM 공개 AST API** — AST 안정화 후

## 의존성 관계
```
AST 안정화 ──────────────┬──→ WASM 공개 AST API
                         └──→ .d.ts (isolatedDeclarations)

번들러 성능 ─────────────┬──→ ✅ scan 파이프라인화 + Producer-Consumer (완료)
                         └──→ tree-shake 알고리즘 개선 (stmtinfo/crossBFS, 후순위)

번들러 기능 ─────────────┬──→ ✅ 로더 시스템 (JSON, text, file, dataurl)
                         ├──→ CSS 번들링 (별도 파서, 플러그인으로 위임 가능)
                         └──→ ✅ 플러그인 API (1-2단계 완료, N-API 선택적)

독립 (아무 때나): ✅ Flow (완료), SIMD
```

## 미지원 기능 (상용 번들러 대비)

esbuild / rolldown / rspack 기준으로 ZTS에 빠진 기능 목록.
- **난이도**: S(반나절) / M(1~2일) / L(3~5일) / XL(1주+)
- **선행**: 먼저 구현해야 하는 기능. 없으면 독립
- **배치**: 같이 묶어서 한 PR로 할 수 있는 그룹

### Critical (없으면 실사용 어려움)

- ~~**Asset 로더** (file, dataurl, text, binary, copy)~~ — ✅ 완료
  `--loader:.png=file` 로 확장자별 로더 지정. fake JS 모듈 방식 (rolldown 방식).
  file/copy 로더는 content hash 파일명으로 출력 디렉토리에 복사 + URL 문자열 export.
  `--asset-names`, `--public-path` 지원.

- ~~**플러그인 API**~~ — ✅ 1-2단계 완료 ([PLUGINS.md](../PLUGINS.md) 참조)
  - 1단계: ✅ Zig Builtin 플러그인 — 함수 포인터 기반 Plugin struct, 5개 훅
  - 2단계: ✅ JS 플러그인 subprocess — stdin/stdout JSON IPC, @zts/core, CLI --plugin
  - 3단계: N-API .node addon (XL, 2~3주, 선택적) — in-process 호출 최적화
  플러그인 API로 CSS는 사용자가 PostCSS/Lightning CSS 플러그인으로 해결 가능.

- **CSS 번들링** — 현재 플러그인 위임, 자체 구현은 후순위
  현재: `--loader:.css=text`로 문자열 export 또는 플러그인으로 PostCSS/Lightning CSS 위임.
  `--loader:.css=empty`로 CSS import 무시 후 별도 빌드 도구 사용도 가능.
  자체 CSS 파서(Zig 네이티브 `@import` 해석, CSS tree-shaking, CSS Modules)는
  플러그인만으로 부족할 때 검토. Bun도 자체 CSS 번들링 미지원.

- ~~**metafile**~~ — ✅ 완료. `--metafile=meta.json` esbuild 호환 JSON.
- ~~**analyze**~~ — ✅ 완료. `--analyze` metafile JSON stderr 출력 (향후 트리 포맷 개선 예정).
- ~~**inject**~~ — ✅ 완료. `--inject:./file.js` 모든 엔트리에 자동 import.
- ~~**legal comments**~~ — ✅ 완료. `--legal-comments=none|inline|eof` (linked/external은 eof 폴백).
- ~~**keepNames**~~ — ✅ 완료. `--keep-names` minify 시 .name 보존 (`__name()` 헬퍼).

### Important (프로덕션 배포에 자주 필요)

- ~~**엔진 타겟**~~ — ✅ 완료. `--target=chrome80,safari14,node16` 엔진 버전 타겟 지원.
  esbuild compat-table 기반, 8개 엔진(chrome/firefox/safari/edge/node/deno/ios/hermes) × 18개 feature.
  ES 버전 타겟(`--target=es2015~esnext`)도 동일한 UnsupportedFeatures bitmask로 통합.

### Nice to Have

- **mangleProps** — `XL` | 선행: 없음 | 배치: 단독
- **import.meta.glob** — `M` | 선행: 없음 | 배치: 단독
- ~~**Virtual modules**~~ — ✅ 완료. `\0` prefix 기반 virtual module 지원 (플러그인 resolveId/load)

### 배치 그룹 & 구현 순서

```
배치 A ✅ 완료 ─────────────────────────────────────────────────
배치 B ✅ 완료 ──────────────────────────────────────────────────
배치 C ✅ 완료 ──────────────────────────────────────────────────

배치 D ✅ 완료 ──────────────────────────────────────────────────
  metafile + analyze + inject + legal comments + keepNames

단독 XL ────────────────────────────────────────────────────────
  CSS 번들링 — 현재 플러그인 위임 (자체 CSS 파서는 후순위)
  플러그인 API ✅ 1-2단계 완료 — N-API 3단계는 선택적
  엔진 타겟 ✅ 완료 — esbuild compat-table 기반 (8엔진 × 18 feature)
  Web Worker ✅ 완료 — new Worker(new URL(...)) 자동 감지+IIFE 번들 (esbuild 미지원)
  mangleProps (1주+) — cross-module 프로퍼티 추적
```

### 기술부채 & 구조적 제약

현재 번들러는 **JS 전용으로 설계**되어 있음. 배치 A~D는 이 구조에 영향 없이 안전하게 구현 가능.
CSS 번들링/플러그인 API는 JS 전용 경계를 넘어야 함.

**JS 전용 구조 — 수정이 필요한 계층 (CSS/플러그인 시):**
| 계층 | 파일 | 필요한 변경 |
|------|------|-----------|
| Module 구조체 | module.zig | CSS 모듈 진입 시 null 방어 체크 또는 전용 필드 |
| Linker | linker.zig | CSS 모듈은 link() 시 스킵하거나 별도 경로 |
| Tree Shaker | tree_shaker.zig | CSS는 ast=null → side_effects=true 고정 |
| Emitter 필터 | emitter.zig | CSS 포함으로 필터 확장 + 타입별 emit 분기 |
| Chunk | chunk.zig | CSS 별도 청크 타입 추가 |

### 최근 버그 수정
- ✅ JSX 파서: closing tag 뒤 텍스트 파싱 실패 (advanceAfterJSXClose — Vite 템플릿 번들링 가능)
- ✅ enum re-export: `enum Foo {} export { Foo }` semantic 에러 (predeclareEnumDecl 추가)
- ✅ CLI memory leak: `--plugin`, `--proxy` 옵션의 ArrayList 미해제
- ✅ `--external=pkg` 형태 미지원 (기존 `--external pkg`만 가능)

### 알려진 제한 (Known Limitations)

**CJS wrap 모듈의 tree-shaking 미지원**
Asset/JSON 모듈은 `exports_kind = .commonjs`, `wrap_kind = .cjs`로 처리됨.
미사용 import라도 `require_X()` 호출이 side-effect로 간주되어 tree-shaker가 제거하지 못함.
esbuild는 `NoSideEffects_PureData` 마킹으로 이를 해결하지만, ZTS의 tree-shaker는 CJS wrap에 대해 아직 이 최적화를 수행하지 않음.
별도 이슈로 개선 필요 — Asset 로더뿐 아니라 JSON 모듈, 기타 CJS 모듈 전체에 영향.

## 성능 최적화 현황
| 최적화 | 상태 | 효과 |
|--------|------|------|
| Arena allocator | ✅ 완료 | 번들러 기반 |
| mimalloc | ✅ 완료 | c_allocator 대비 8% 추가 개선 |
| 멀티스레드 parse+finalize | ✅ 완료 | finalize를 parseModule에 통합 |
| tree-shaker 역인덱스 | ✅ 완료 | stmt_info O(N log S) + sym→stmt 역인덱스 |
| emit 병렬화 | ✅ 완료 | 74ms → 15ms (-80%) |
| resolve 병렬화 | ✅ 완료 | 191ms → 134ms (-30%, 캐시 히트율 높아 제한적) |
| fixpoint oscillation 수정 | ✅ 완료 | 100회 → 2회 수렴, tree-shake 238ms → 51ms |
| scan 파이프라인화 | ✅ 완료 | 배치→파이프라인→Producer-Consumer, pre-allocation 제거, 포인터 안전 |
| 증분 빌드 (파싱 캐시) | ✅ 완료 | PersistentModuleStore + ResolveCache 보존, watch/serve 리빌드 시 변경 모듈만 재파싱 |
| tree-shake 병렬화 | 후순위 | 현재 15ms, StmtInfo 병렬화로 ~5ms 절감 가능하나 ROI 낮음 |
| SIMD | 미착수 | 렉서 공백/식별자/문자열 스캔 가속 (scan ~10ms 절감 예상) |
