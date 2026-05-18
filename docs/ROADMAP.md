# Roadmap & Status

## ✅ 완료

| Phase                       | 내용                                                                                                                                                                                                                                                                                                       | 상태 |
| --------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---- |
| 1. 렉서                     | 토큰 ~208개, SIMD, 유니코드, JSX, RegExp 검증                                                                                                                                                                                                                                                              | ✅   |
| 2. 파서                     | AST ~200 Tag, TS/JSX, 에러 복구, semantic analysis                                                                                                                                                                                                                                                         | ✅   |
| 3. 트랜스포머               | TS 스트리핑, enum/namespace IIFE, JSX, ESM→CJS, decorator                                                                                                                                                                                                                                                  | ✅   |
| 4. 코드젠+CLI               | 포맷팅, minify, 소스맵 V3, --ascii-only                                                                                                                                                                                                                                                                    | ✅   |
| 5. CLI 고급                 | stdin, 에러 프레임, --outdir, tsconfig, --watch                                                                                                                                                                                                                                                            | ✅   |
| 6a. 번들러                  | resolver, 모듈 그래프, linker, tree-shaking, code splitting                                                                                                                                                                                                                                                | ✅   |
| 6a-ts                       | tree-shaker 2단계 — export 수준 DCE (purity.zig, tslib 95% 감소)                                                                                                                                                                                                                                           | ✅   |
| 6a-si                       | StmtInfo 기반 statement DCE (rolldown 방식, pathe ESM 77% 감소)                                                                                                                                                                                                                                            | ✅   |
| 6a-ex                       | exports 조건 해석 Node.js 스펙 준수 (tslib CJS→ESM 해결)                                                                                                                                                                                                                                                   | ✅   |
| 6b. Dev server              | HTTP+WS, Live Reload, HMR, React Fast Refresh, CSS 핫 리로드                                                                                                                                                                                                                                               | ✅   |
| Test262                     | 50,504건 / 50,504 통과 / **0 fail** (100%)                                                                                                                                                                                                                                                                 | ✅   |
| Smoke                       | **136 케이스** (엔진 타겟 변형 포함), avg **0.82x**, ❌ 0개                                                                                                                                                                                                                                                | ✅   |
| 7-2. emit 병렬화            | 모듈별 transform+codegen 스레드 풀 실행                                                                                                                                                                                                                                                                    | ✅   |
| 7-3. resolve 병렬화         | 배치 내 resolve 스레드 풀 + ResolveCache Mutex                                                                                                                                                                                                                                                             | ✅   |
| 7-fix. fixpoint oscillation | 미사용 모듈 제거를 fixpoint 후로 이동 (100회→2회)                                                                                                                                                                                                                                                          | ✅   |
| 8. AST 미니파이어           | constant folding, DCE, boolean simplification, comma operator                                                                                                                                                                                                                                              | ✅   |
| 9. 배치 A                   | 번들러 옵션 10개 (alias, banner, globalName, publicPath, JSON ESM 등)                                                                                                                                                                                                                                      | ✅   |
| 10. 배치 B                  | content hash + naming 패턴 (--entry-names, --chunk-names)                                                                                                                                                                                                                                                  | ✅   |
| 11. 배치 C                  | Asset 로더 (file, dataurl, text, binary, copy) + --loader CLI                                                                                                                                                                                                                                              | ✅   |
| 12. 배치 D                  | metafile, analyze, legal-comments, inject, keepNames                                                                                                                                                                                                                                                       | ✅   |
| 13. Flow                    | Flow 타입 스트리핑 (TIER 1+2+3), flow.zig 독립 파싱, Metro 410/410 통과                                                                                                                                                                                                                                    | ✅   |
| 14. RN Resolve              | --resolve-extensions, --main-fields (플랫폼 확장자 + package.json 필드 순서)                                                                                                                                                                                                                               | ✅   |
| 15. ES 타겟                 | --target=es2015~esnext, ES 버전별 다운레벨링 (es2015~es2024 트랜스포머)                                                                                                                                                                                                                                    | ✅   |
| 16. 엔진 타겟               | --target=chrome80,safari14 엔진 버전별 feature-level 다운레벨링                                                                                                                                                                                                                                            | ✅   |
| 17. Web Worker              | new Worker(new URL(...)) 자동 감지 → 별도 IIFE 번들 (esbuild 미지원)                                                                                                                                                                                                                                       | ✅   |
| 18. scan 파이프라인         | 배치→파이프라인 (scanWorker: parse→resolve→spawn), 총합 -15%                                                                                                                                                                                                                                               | ✅   |
| 19. Producer-Consumer       | 워커: parse+resolve만, 메인: sole writer. pre-allocation 제거, 포인터 안전                                                                                                                                                                                                                                 | ✅   |
| 20. RN 플랫폼               | `--platform=react-native` 프리셋 (resolve-extensions, main-fields, Flow, exports 조건)                                                                                                                                                                                                                     | ✅   |
| 21. watch-json              | `--watch-json` NDJSON 이벤트 출력 (외부 번들러 연동용)                                                                                                                                                                                                                                                     | ✅   |
| 22. 증분 빌드               | PersistentModuleStore 파싱 캐시 + ResolveCache 보존 (watch/serve 리빌드 최적화)                                                                                                                                                                                                                            | ✅   |
| 23. jsx-dev                 | React 개발 모드 `jsxDEV` + `__source`/`__self`, `--jsx=automatic-dev` / `--jsx-dev`                                                                                                                                                                                                                        | ✅   |
| 24. RN 호환                 | self-require 방지, shimMissingExports, \_\_rest Symbol, class field \_this 캡처                                                                                                                                                                                                                            | ✅   |
| 25. ES5 다운레벨            | let→var void 0 초기화, spread string, for-in destructuring, computed destr, super computed                                                                                                                                                                                                                 | ✅   |
| 26. compat-table            | kangax ES5~ES2022 100% + SWC 비교 29 cases × 9 targets CI                                                                                                                                                                                                                                                  | ✅   |
| 27. ES2023                  | `--target=es2023`, hashbang (#!) 다운레벨, compat_table 엔진 버전                                                                                                                                                                                                                                          | ✅   |
| 28. NAPI                    | C NAPI 바인딩: transpile, buildSync, build (async + plugins)                                                                                                                                                                                                                                               | ✅   |
| 29. Node.js CLI             | Zig CLI → Node.js/Bun CLI 전환 (Rolldown 방식), watch/serve JS 구현                                                                                                                                                                                                                                        | ✅   |
| 30. Vite 어댑터             | `vitePlugin()` Rollup→ZNTC 플러그인 변환, resolveId/load/transform + lifecycle                                                                                                                                                                                                                              | ✅   |
| 31. define/alias            | NAPI BuildOptions에 `define`/`alias` 옵션 노출                                                                                                                                                                                                                                                             | ✅   |
| 32. tsconfig                | CLI에서 tsconfig.json 자동 탐색+로드 (experimentalDecorators, jsx 등)                                                                                                                                                                                                                                      | ✅   |
| 33. BuildOptions 확장       | loader, conditions, resolveExtensions, mainFields, target, outdir, outfile, write                                                                                                                                                                                                                          | ✅   |
| 33a. CLI debug/resolve 노출 | `--conditions`, `--profile*`, `--tokenize` JS CLI 노출 및 문서 동기화                                                                                                                                                                                                                                      | ✅   |
| 34. 플러그인 훅 확장        | renderChunk/generateBundle + buildStart/buildEnd/closeBundle NAPI 노출, watch lifecycle 매핑                                                                                                                                                                                                               | ✅   |
| 35. async 플러그인          | 모든 훅 async/Promise 반환 지원 (MaybePromise)                                                                                                                                                                                                                                                             | ✅   |
| 36. import.meta.glob        | Vite 호환 `import.meta.glob()`, eager/import 옵션                                                                                                                                                                                                                                                          | ✅   |
| 37. Stage 3 decorators      | TC39 Stage 3 데코레이터 (method/getter/setter/field/accessor/class, MobX 6 호환). ES5 타겟 lowering 포함. `accessor #x` (private key, #1511) / `accessor [k]` (computed key, #1524) ES5 direct path 까지 구현 — Babel/esbuild/oxc parity                                                                  | ✅   |
| 38. CSS 번들링              | @import 인라이닝, 별도 .css 파일 emit, Lightning CSS minify 연동                                                                                                                                                                                                                                           | ✅   |
| 39. Minify 확장             | 미참조 class expression name 익명화 — fast/non-fast path 통합 (#1587 + #1596)                                                                                                                                                                                                                              | ✅   |
| 40. Import attributes       | ES2024 `with {...}` 라운드트립: static / dynamic / export named / export \* 네 경로 전부 AST 보존. `assert` → `with` 자동 마이그레이션                                                                                                                                                                     | ✅   |
| 41. manualChunks            | Rollup `manualChunks(id, meta)` 호환. record + function 형, NAPI TSFN, 동적 그룹화, dynamic import 정책, manualChunks meta API (id/isEntry/isExternal/code/isIncluded/exports/importers/dynamicImporters/importedIds/dynamicallyImportedIds/hasModuleSideEffects/syntheticNamedExports/implicitlyLoaded\*) | ✅   |
| 42. external phantom        | external 모듈을 phantom Module 로 graph 등록 — Rollup parity (`getModuleInfo("react").isExternal === true`, `info.importedIds` 에 external 포함)                                                                                                                                                           | ✅   |
| 43. inlineDynamicImports    | Rollup `output.inlineDynamicImports` — chunk 구조 (A) + 런타임 registry (B). `import("./x")` → `__esm` / `__commonJS` 래퍼로 재작성. namespace identity / single-execution / live binding 보장                                                                                                             | ✅   |

## 번들러 성능 현황 (2026-04-10 실측)

> 성능 시간 표는 ReleaseFast 빌드 + CI macos-latest 환경 기준. Debug 빌드 (`zig build` 기본값) 측정시 cold-start 가 5~10x 느려지므로 비교 시 빌드 모드 확인 필수.

### 합성 벤치마크 (200모듈, CLI 직접 호출)

| Tool     | Avg (ms) | vs fastest |
| -------- | -------- | ---------- |
| **ZNTC**  | **7**    | 1.0x       |
| Bun      | 10       | 1.4x       |
| esbuild  | 13       | 1.9x       |
| rolldown | 62       | 8.9x       |

### 실제 npm 패키지 (136개 스모크 테스트)

평균 번들 사이즈 비율: **0.82x** (esbuild 대비 18% 작음). 132/136 케이스에서 ZNTC가 더 작음 (2026-04-26 실측).

주요 실측 (시간 — 2026-04-10):
| 라이브러리 | ZNTC | esbuild | rolldown |
|---|---|---|---|
| vue (1.6MB) | 29ms | 56ms | 152ms |
| cheerio (1.7MB) | 37ms | 85ms | 192ms |
| express (787KB) | 29ms | 63ms | 180ms |
| react-dom (1.1MB) | 14ms | 13ms | 60ms |
| rxjs (329KB) | 27ms | 27ms | 88ms |

## 🔜 다음 우선순위

~~**배치 E (S급 일괄)**~~ — ✅ 완료 (CLI 옵션 13개: outbase, packages=external, drop-labels, pure, line-limit 등)

~~**CSS 번들링**~~ — ✅ Phase 1 완료 (자체 @import 스캐너 + Lightning CSS minify 연동)

- ✅ `import './style.css'` → 별도 `.css` 파일 자동 생성
- ✅ CSS `@import` 체이닝 → Zig 네이티브 스캐너로 모듈 그래프에 통합 + 인라이닝
- ✅ `--minify` 시 Lightning CSS로 CSS minify (optionalDependency)
- 후순위: CSS Modules (`.module.css`), 코드 스플리팅 시 청크별 CSS 분리

~~**플러그인 3단계 (N-API)**~~ — ✅ 완료. 이후 subprocess 경로(2단계)는 중복되어 D101로 제거.

~~**HMR 고도화**~~ — ✅ 완료

- `import.meta.hot.accept()` / `dispose()` / `decline()` 구현
- WebSocket HMR 채널 + 파일 감시 + React Fast Refresh

~~**설정 파일 + JS Build API**~~ — ✅ 완료

- `packages/core`에서 `defineConfig()` + `build()` 내보냄
- CLI `--plugin <path>`로 JS 설정 파일 로드

~~**import.meta.glob**~~ — ✅ 완료

- Vite 호환 `import.meta.glob()`, eager/import 옵션 지원

## ⏳ 미완료

- **.d.ts 생성** (isolatedDeclarations) — 후순위, 당분간 tsc에 위임
- **SIMD 확장** — 렉서에 `@Vector(16, u8)` 부분 적용 완료 (공백/식별자 스캔). 추가 확장 여지 있음
- **WASM 공개 AST API** — AST 안정화 후

## ✅ 최근 추가 (Dev Server 확장)

- **SSE 이벤트 스트림** (`/sse/events`) — `server_ready`, `watch_change`, `bundle_build_*`, `cache_reset` 실시간 브로드캐스트 (Rolldown DevEngine 호환)
- **Control API** (`/reset-cache`) — 외부에서 캐시 무효화 트리거
- **MCP 서버** (`/mcp`) — JSON-RPC 2.0, `initialize`/`tools/list`/`tools/call`. 도구: `reset_cache`, `get_build_events`. Claude Code 등 LLM 에이전트가 `.mcp.json`으로 직접 연결 가능

## ✅ 최근 추가 (CLI / Config / Diagnostics / RN)

- **`zntc.config.json` 자동 로드** — cwd에 있으면 CLI 기본값으로 적용. `"$schema"` 선언으로 VSCode autocomplete (e8b8e9cf)
- **TranspileOptions JSON schema 자동 생성** — `zig build schema` → `transpile-options.schema.json` (comptime reflection, 단일 소스 진실) (e9272ac1)
- **TranspileOptions 단일 JSON payload** — CLI/NAPI/WASM 간 옵션 전달을 필드별 인자 → JSON 페이로드로 통일 (8047603a)
- **Rich diagnostic 오버홀**
  - `TranspileResult.errors`에 시맨틱 에러를 렌더된 문자열로 노출 (9dfea7dd)
  - Multi-span label + redeclaration previously-here hint (9d9b3ab5)
  - Previously-declared-here labels — 6개 재선언 에러 (75626350)
  - Reference-to-definition label — 3개 에러 (853ad5c2)
  - Help hint + 에러별 `ZNTCxxxx` docs URL (fa257fed, 2698079e)
  - 에러 발생 시 CLI exit 1 (05e12e5a)
- **Bun 스타일 crash report** — panic handler + GitHub 신고 안내 (abd1d11b)
- **React Native 통합 강화**
  - Asset `@2x` / `@3x` scale variant 자동 감지 + emit (25114fd8)
  - Metro AssetRegistry 호환 출력 (68d3418b)
  - `asset_registry` 모듈 `require → require_xxx` 변환 (89a57756)
  - `resolver.blockList` (7918387a), `resolve.fallback` (e6559104), `watchFolders` (b104b828)
- **Plugin API 확장** — `onResolve` 훅이 `{ disabled: true }` 반환 허용 (49955634)
- **BuildOptions 보완** — `strictExecutionOrder`, `scopeHoist`, `workletTransform` 추가 (eb909fcc)

## ✅ 최근 추가 (2026-04 transformer / bundler)

- **Runtime helper virtual module** (#1961, PR 1a~1h, 2026-04-26) — splitting + single-bundle 양쪽에서 helper 를 가상 모듈로 모델링 (`__esm`, `__commonJS` 등). HelperBit enum 화 (#1982) 등 후속 정리 5건.
- **ESM external import preserve** (#1962, #1983) — bare external 을 `require()` 로 변환하지 않고 `import` 그대로 보존.
- **Lazy sourcemap** (#1727 Phase B, 5 PR) — `serialize` 비용 29ms→0.22ms, NAPI HMR 183→162ms. `sourceURL` 주석 분리 emit.
- **Type-only import elision** (#1791, #1797 + 7 PR) — named 한정 + oxc-style Reference flags. for-of `let` closure capture fix + sentinel AST layout 수정 동반.
- **Worker race safety** (#1779 에픽 7 PR) — `StableSegmentedList` 도입, std.SegmentedList.dynamic_segments race 근본 해결.
- **Tree shaker statement-level symbol graph** (#1558, #1560-1562) — rolldown 방식 단일 소스. reference_count 는 mangler 전용으로 분리.
- **Symbol table Phase 4e** (#1328, 6 PR) — semantic 통합.
- **Transformer epic D2** (#1672) — Profile 에픽 12 PR 완료, 실삽입 9개. NAPI `phaseDurations.parse_ms` 는 `graph_ns` 의 legacy 이름 (트랩 주의).
- **Transformer 미세 fix 17건** (2026-04-26) — super property/static/logical-assign, optional method/eval call, exponentiation assign 등 edge case 정리.

## 의존성 관계

```
AST 안정화 ──────────────┬──→ WASM 공개 AST API
                         └──→ .d.ts (isolatedDeclarations)

번들러 성능 ─────────────┬──→ ✅ scan 파이프라인화 + Producer-Consumer (완료)
                         └──→ tree-shake 알고리즘 개선 (stmtinfo/crossBFS, 후순위)

번들러 기능 ─────────────┬──→ ✅ 로더 시스템 (JSON ESM, text, file, dataurl)
                         ├──→ CSS 번들링 (별도 파서, 플러그인으로 위임 가능)
                         ├──→ 배치 E (S급 CLI 옵션 일괄)
                         └──→ ✅ 플러그인 API (1-2단계 완료, N-API 선택적)

독립 (아무 때나): ✅ Flow, ✅ jsx-dev, ✅ using 다운레벨링, ✅ sourcemapDebugIds, ✅ SIMD (부분)
```

## 미지원 기능 (상용 번들러 대비)

esbuild / rolldown / rspack 기준으로 ZNTC에 빠진 기능 목록.

- **난이도**: S(반나절) / M(1~2일) / L(3~5일) / XL(1주+)
- **선행**: 먼저 구현해야 하는 기능. 없으면 독립
- **배치**: 같이 묶어서 한 PR로 할 수 있는 그룹

### Critical (없으면 실사용 어려움)

- ~~**Asset 로더** (file, dataurl, text, binary, copy)~~ — ✅ 완료
  `--loader:.png=file` 로 확장자별 로더 지정. fake JS 모듈 방식 (rolldown 방식).
  file/copy 로더는 content hash 파일명으로 출력 디렉토리에 복사 + URL 문자열 export.
  `--asset-names`, `--public-path` 지원.

- ~~**플러그인 API**~~ — ✅ 완료 ([PLUGINS.md](./PLUGINS.md) 참조)
  - 1단계: ✅ Zig Builtin 플러그인 — 함수 포인터 기반 Plugin struct, 5개 string 훅 + onFunction AST 훅. 내장 AST 플러그인 프리셋(`builtin.zig`)에 등록된 것은 `worklet` 하나뿐 — refresh/styled/emotion 등은 별도 graph-level transform 플래그(`transformer/options.zig`)이지 onFunction 내장 플러그인이 아님
  - ~~2단계: JS 플러그인 subprocess~~ — ❌ D101로 제거. NAPI(3단계)가 기본 경로
  - 3단계: ✅ N-API .node addon — in-process 호출, TSFN 기반 async 브릿지 (기본 JS 플러그인 경로)
  - 4단계: ✅ Vite/Rollup 어댑터 — vitePlugin() + async 훅 + renderChunk/generateBundle + lifecycle/watch
    플러그인 API로 CSS는 사용자가 PostCSS/Lightning CSS 플러그인으로 해결 가능.

- ~~**CSS 번들링**~~ — ✅ Phase 1 완료
  `import './style.css'` → 별도 `.css` 파일 자동 생성. Zig 네이티브 `@import` 스캐너로
  모듈 그래프에 통합 + 인라이닝. `--minify` 시 Lightning CSS로 CSS minify (optional).
  후순위: CSS Modules (`.module.css`), 코드 스플리팅 시 청크별 CSS 분리.

- ~~**metafile**~~ — ✅ 완료. `--metafile=meta.json` esbuild 호환 JSON.
- ~~**analyze**~~ — ✅ 완료. `--analyze` metafile JSON stderr 출력 (향후 트리 포맷 개선 예정).
- ~~**inject**~~ — ✅ 완료. `--inject:./file.js` 모든 엔트리에 자동 import.
- ~~**legal comments**~~ — ✅ 완료. `--legal-comments=none|inline|eof` (linked/external은 eof 폴백).
- ~~**keepNames**~~ — ✅ 완료. `--keep-names` minify 시 .name 보존 (`__name()` 헬퍼).

### Important (프로덕션 배포에 자주 필요)

- ~~**엔진 타겟**~~ — ✅ 완료. `--target=chrome80,safari14,node16` 엔진 버전 타겟 지원.
  esbuild compat-table 기반, 8개 엔진(chrome/firefox/safari/edge/node/deno/ios/hermes) × 18개 feature.
  ES 버전 타겟(`--target=es2015~esnext`)도 동일한 UnsupportedFeatures bitmask로 통합.

- ~~**jsx-dev**~~ — ✅ 완료. `--jsx=automatic-dev` / `--jsx-dev` React 개발 모드 `jsxDEV` + `__source`/`__self`
- ~~**UMD/AMD 포맷**~~ — ✅ 완료. `--format=umd` / `--format=amd` + external dependency array + factory params
- ~~**manualChunks**~~ — ✅ 완료. Rollup `manualChunks(id, meta)` 호환. record + function 형, manualChunks meta API (`getModuleInfo`) 13/14 필드 노출, external phantom Module 처리, `inlineDynamicImports` (chunk 구조 + 런타임 registry).
  남은 1필드 (`info.ast`) 는 ESTree adapter epic (#1881) — Phase C 로 분리.
- ~~**preserveModules**~~ — ✅ 완료. `--preserve-modules` + `--preserve-modules-root` (Rollup/Rolldown 호환)
- ~~**using 다운레벨링**~~ — ✅ 완료. `using`/`await using` → try-finally + `__using`/`__callDispose` (esbuild 호환)
- ~~**설정 파일 (zntc.config.js)**~~ — ✅ 완료. `packages/core`에서 `defineConfig()` 내보냄.
- ~~**JS Build API**~~ — ✅ 완료. `packages/core`에서 `build()` 함수 내보냄 (NAPI 기반, in-process).
- ~~**HTTPS dev server**~~ — ✅ 완료. `--certfile`/`--keyfile` TLS 지원 (Node.js/Bun CLI)

### Nice to Have

- **mangleProps** — `XL` | 선행: 없음 | 배치: 단독
- ~~**import.meta.glob**~~ — ✅ 완료. Vite 호환 `import.meta.glob()` (eager/import 옵션 지원)
- ~~**Virtual modules**~~ — ✅ 완료. `\0` prefix 기반 virtual module 지원 (플러그인 resolveId/load)
- ~~**Stage 3 decorators**~~ — ✅ 완료. TC39 Stage 3 데코레이터 다운레벨링 (method/getter/setter/field/accessor/class, initializer 체이닝, MobX 6 호환). ES5 타겟 포함 (dispatch 수정 #1389). `accessor #x` (private key, #1511) + `accessor [k]` (computed key, #1524) ES5 direct path 까지 구현 — Babel/esbuild/oxc parity.
- **Module Concatenation 고도화** — `XL` | rspack/rolldown 수준 scope hoisting
- **innerGraph** — `L` | 🟡 부분 완료. 순수 local statement, overwritten assignment, overwritten declaration initializer, direct block/function declaration body의 straight-line dead store 제거 완료. 남은 범위: reference 기반 일반 dead store, branch/loop/try control-flow 분석.
- **lazyBarrel** — `L` | 🟡 부분 완료. 순수 re-export / local re-export / namespace barrel (`import * as X; export { X }`, `re_export_namespace`) emit skip 완료. `requested_exports.zig` + `linker.zig:1237` + `tree_shaker.zig:1220` 에서 namespace 경계 명시 처리. 남은 범위: **wrapper-barrel body mutation 정밀 분석** — 현재 `isWrapperBarrel` 가 lodash-es `lodash.default.js` 같이 imported binding 을 mutate 하는 패턴을 통째 lazy 비활성화 (보수적). mutation 영역만 부분 lazy 적용은 미완.
- ~~**realContentHash**~~ — ✅ 완료. SHA-256 기반 `[hash]` 패턴 (emitter/chunks.zig)
- ~~**sourcemapDebugIds**~~ — ✅ 완료. `--sourcemap-debug-ids` UUID v4, 번들+소스맵 매칭
- ~~**shimMissingExports**~~ — ✅ 완료. `--shim-missing-exports` 롤다운 호환

### 번들러 인프라 — rolldown/rspack 비교

| 항목                         | 난이도 | esbuild | rolldown          | rspack         | ZNTC | 설명                                                                             |
| ---------------------------- | ------ | ------- | ----------------- | -------------- | --- | -------------------------------------------------------------------------------- |
| ~~**CSS 번들링**~~           | ✅     | ✅      | ✅                | ✅             | ✅  | @import 인라이닝 + Lightning CSS minify (CSS Modules 후순위)                     |
| ~~**manualChunks**~~         | ✅     | ❌      | ✅ advancedChunks | ✅ splitChunks | ✅  | Rollup `manualChunks(id, meta)` 호환 + meta API 13/14 필드                       |
| ~~**inlineDynamicImports**~~ | ✅     | ❌      | ✅                | ❌             | ✅  | Rollup `output.inlineDynamicImports` — `__esm`/`__commonJS` 래핑으로 런타임 처리 |
| ~~**external phantom**~~     | ✅     | ❌      | ✅                | ❌             | ✅  | external 도 graph 1급 노드 — Rollup `getModuleInfo("react").isExternal` 동작     |
| **innerGraph**               | L      | ❌      | ✅                | ✅             | 🟡  | 변수 할당 추적으로 정밀 DCE — straight-line dead store 일부 완료                 |
| **Persistent caching**       | XL     | ❌      | ❌                | ✅             | ❌  | 디스크 캐시, 콜드 리빌드 250%↑                                                   |
| **Module Federation**        | XL     | ❌      | ❌                | ✅             | ❌  | 마이크로프론트엔드 코드/리소스 공유                                              |
| **Lazy compilation**         | XL     | ❌      | ❌                | ✅             | ❌  | 온디맨드 모듈 컴파일 (dev 시작 가속)                                             |
| ~~**Stage 3 decorators**~~   | ✅     | ❌      | ✅                | ✅             | ✅  | TC39 Stage 3 데코레이터 (legacy + Stage 3)                                       |
| **mangleProps**              | XL     | ✅      | ❌                | ❌             | ❌  | cross-module 프로퍼티 난독화                                                     |
| **lazyBarrel**               | L      | ❌      | ✅                | ❌             | 🟡  | barrel re-export 컴파일 생략 — 순수/local/namespace barrel 처리 완료, wrapper-barrel mutation 정밀화 미완 |
| ~~**import.meta.glob**~~     | ✅     | ❌      | ✅                | ❌             | ✅  | Vite 호환 glob import                                                            |
| ~~**플러그인 N-API**~~       | ✅     | ✅ (Go) | ✅ (Rust)         | ✅             | ✅  | in-process NAPI + async 훅 + Vite 어댑터                                         |
| ~~**HMR module-level**~~     | ✅     | ❌      | ✅                | ✅             | ✅  | `import.meta.hot.accept()`                                                       |
| ~~**설정 파일**~~            | ✅     | ❌      | ✅                | ✅             | ✅  | `defineConfig()`                                                                 |
| ~~**JS Build API**~~         | ✅     | ✅      | ✅                | ✅             | ✅  | `build()`                                                                        |
| ~~**HTTPS dev server**~~     | ✅     | ❌      | ✅                | ✅             | ✅  | `--certfile`/`--keyfile`                                                         |

### 배치 그룹 & 구현 순서

```
배치 A ✅ 완료 ─────────────────────────────────────────────────
배치 B ✅ 완료 ──────────────────────────────────────────────────
배치 C ✅ 완료 ──────────────────────────────────────────────────

배치 D ✅ 완료 ──────────────────────────────────────────────────
  metafile + analyze + inject + legal comments + keepNames

배치 E 부분 완료 ────────────────────────────────────────────────
  완료: --outbase, --log-limit, inlineDynamicImports, cleanDir,
  --watch-delay, --serve <dir>, shimMissingExports, extensionAlias,
  --packages=external, --pure:callee, --line-limit,
  sanitizeFileName, --allow-overwrite
  미완료/미노출:
  --tsconfig-raw, --node-paths,
  output.intro/outro, output.globals, --jsx-side-effects,
  --ignore-annotations

단독 XL ────────────────────────────────────────────────────────
  CSS 번들링 ✅ Phase 1 완료 — @import 인라이닝 + Lightning CSS minify (CSS Modules 후순위)
  플러그인 API ✅ 1-4단계 완료 — NAPI + Vite 어댑터 + async 훅
  엔진 타겟 ✅ 완료 — esbuild compat-table 기반 (8엔진 × 18 feature)
  Web Worker ✅ 완료 — new Worker(new URL(...)) 자동 감지+IIFE 번들 (esbuild 미지원)
  import.meta.glob ✅ 완료 — Vite 호환 glob import (eager/import 옵션)
  mangleProps (1주+) — cross-module 프로퍼티 추적
  Stage 3 decorators ✅ 완료 — TC39 Stage 3 데코레이터 (legacy + Stage 3, MobX 6 호환)
  Module Concatenation 고도화 — rspack/rolldown 수준 scope hoisting
  manualChunks ✅ 완료 — Rollup 호환 (record + function + meta API 13/14 필드)
  innerGraph 🟡 부분 완료 — straight-line local dead store 제거 완료. 다음: reference 기반 일반 dead store/control-flow 확장
  Rollup ModuleInfo Phase B (#1880) — plugin context API + meta 필드 (1.5~2주)
  Rollup ModuleInfo Phase C (#1881) — ESTree adapter (info.ast, 2~4주)
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

- ✅ TLA(Top-Level Await): `__esm` 래핑 시 `async` 키워드 누락 + preamble `await` 누락 (#779)
- ✅ \_default 합성 변수 충돌: 여러 ESM 모듈의 export default가 같은 변수 공유 (#704)
- ✅ re-export default 할당 누락: `export { default } from` 패턴에서 \_\_esm body 비어있음 (#705)
- ✅ var \_default 중복 선언: import + export default 패턴에서 호이스팅 충돌 (#706)
- ✅ CJS 엔트리 자동 호출 누락: IIFE 번들에서 `require_index()` 미삽입 (#707)
- ✅ JSX 파서: closing tag 뒤 텍스트 파싱 실패 (advanceAfterJSXClose)
- ✅ enum re-export: `enum Foo {} export { Foo }` semantic 에러
- ✅ CLI memory leak: `--plugin`, `--proxy` 옵션의 ArrayList 미해제

### 알려진 제한 (Known Limitations)

**CJS wrap Asset 모듈의 tree-shaking — ✅ 해결**
Asset 모듈은 `exports_kind = .commonjs`, `wrap_kind = .cjs` 로 처리되지만, 로더가 `module.side_effects = false` 를 마킹 (`graph/loaders.zig:172`, `graph/json_module.zig:38`, `graph/module_registry.zig:87`, `graph/plugins.zig:126`). `tree_shaker.zig:785-794` 가 이 마킹을 받아 `side_effects=false` 모듈은 stmt 시드를 건너뛰므로 미사용 시 모듈 통째 제거 — esbuild `NoSideEffects_PureData` 동치 동작.

**tsconfig `paths` resolver 선형 스캔 — ResolveCache 로 실효 영향 무시 수준**
`tryTsPaths` (`resolver.zig:291`) 가 `ts_paths` 배열을 O(N) 선형으로 훑는 건 그대로지만,
`ResolveCache` (`resolve_cache.zig:334`) 가 specifier 단위로 결과를 캐시하므로 **같은 import 는
첫 resolve 만 선형 스캔**, 이후는 캐시 히트로 즉시 반환. 같은 alias 가 여러 파일에서 반복되는
대형 프로젝트일수록 캐시 히트율이 높아 실효 오버헤드는 측정값보다 훨씬 작음.

원시 측정 (2026-04-18, 캐시 미스 기준):

| N (paths)           | graph scan 오버헤드 | Import 당 비용 |
| ------------------- | ------------------- | -------------- |
| 100 (대형 프로젝트) | ~1.4ms              | ~7µs           |
| 200                 | ~5ms                | ~10µs          |
| 500 (극단)          | ~19ms               | ~19µs          |

HashMap 화는 wildcard (`@foo/*` prefix/suffix 매칭) 때문에 ~50% 만 가능. ResolveCache 가
이미 압도적으로 흡수하므로 현재는 복잡도 대비 이득 부족 판단. 실사용 bottleneck 제보 시 재검토.

## ES 다운레벨링 커버리지 (kangax/compat-table)

`bun run test:compat`으로 실행. CI에서 자동 검증. 2026-04-26 실측.

| Target | Pass | Total | Rate                 |
| ------ | ---- | ----- | -------------------- |
| ES5    | 241  | 242   | 99.6% (1 known fail) |
| ES2015 | 18   | 18    | 100%                 |
| ES2016 | 15   | 15    | 100%                 |
| ES2017 | 15   | 15    | 100%                 |
| ES2018 | 13   | 13    | 100%                 |
| ES2019 | 11   | 11    | 100%                 |
| ES2020 | 10   | 10    | 100%                 |
| ES2021 | 1    | 1     | 100%                 |

ES5 known fail: tagged template `\x` arbitrary escape sequence (`template literals`). 네이티브 엔진 전용 테스트 스킵 (GeneratorFunction 생성자, iterable 프로토콜).
SWC 비교 테스트: 29 cases × 9 targets 전부 통과.

## Test262 (2026-04-26 실측)

`zntc --test262 tests/test262` (test262 repo root 자동 감지 → `test/` 만 walk).

| 카테고리  | Total      | Pass       | Fail         |
| --------- | ---------- | ---------- | ------------ |
| annexB    | 1,079      | 1,079      | 0            |
| built-ins | 22,729     | 22,729     | 0            |
| harness   | 116        | 116        | 0            |
| intl402   | 1,566      | 1,566      | 0            |
| language  | 23,384     | 23,384     | 0            |
| staging   | 1,630      | 1,630      | 0            |
| **TOTAL** | **50,504** | **50,504** | **0** (100%) |

이전 annexB 6 fail (`language/function-code/*-func-skip-early-err.js`, B.3.3.1 sloppy function hoisting — outer `let f` 충돌 시 var-bound 호이스팅 skip) 은 d2a393ee 에서 semantic analyzer 가 outer lexical 충돌 감지 시 hoist 를 건너뛰도록 수정해 해소.

## 성능 최적화 현황

| 최적화                          | 상태         | 효과                                                                                |
| ------------------------------- | ------------ | ----------------------------------------------------------------------------------- |
| Arena allocator                 | ✅ 완료      | 번들러 기반                                                                         |
| mimalloc                        | ✅ 완료      | c_allocator 대비 8% 추가 개선                                                       |
| 멀티스레드 parse+finalize       | ✅ 완료      | finalize를 parseModule에 통합                                                       |
| tree-shaker 역인덱스            | ✅ 완료      | stmt_info O(N log S) + sym→stmt 역인덱스                                            |
| emit 병렬화                     | ✅ 완료      | 74ms → 15ms (-80%)                                                                  |
| resolve 병렬화                  | ✅ 완료      | 191ms → 134ms (-30%, 캐시 히트율 높아 제한적)                                       |
| fixpoint oscillation 수정       | ✅ 완료      | 100회 → 2회 수렴, tree-shake 238ms → 51ms                                           |
| scan 파이프라인화               | ✅ 완료      | 배치→파이프라인→Producer-Consumer, pre-allocation 제거, 포인터 안전                 |
| 증분 빌드 (파싱 캐시)           | ✅ 완료      | PersistentModuleStore + ResolveCache 보존, watch/serve 리빌드 시 변경 모듈만 재파싱 |
| tree-shake 알고리즘 최적화      | ✅ 완료      | clearUsedExports 제거, has_direct_used_export O(1) 배열 (#917)                      |
| resolve 캐시 스택 버퍼          | ✅ 완료      | 캐시 키 alloc/free 제거, graph -7% (#918)                                           |
| 파서 inline scan                | ✅ 완료      | import/binding scanner AST 재순회 제거 (#919)                                       |
| StmtInfo semantic 사전 구축     | ✅ 완료      | tree-shake 29.8→5.6ms (-81%), total 82.7→56.9ms (-31%) (#920)                       |
| resolveExportChain 메모이제이션 | ✅ 완료      | re-export chain 조건부 캐시 (#918)                                                  |
| SIMD                            | ✅ 부분 적용 | `@Vector(16, u8)` 공백/식별자 스캔 적용 완료 (scanner.zig). 추가 확장 여지 있음     |

## 프로덕션 로드맵

기능은 대부분 갖춰졌으나, 실제 프로젝트에서 esbuild/Vite를 대체하려면 아래 항목이 필요.

### 1단계: 안정성 (현재 가장 중요)

| 항목                             | 난이도 | 현재 상태 | 설명                                                                                                                                                                                                                         |
| -------------------------------- | ------ | --------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **통합 테스트 확대**             | L      | 부분 완료 | ✅ Vite: multi-module TS/TSX 앱을 `@zntc/vite-plugin`로 프로덕션 번들 → Playwright 브라우저 실행 E2E (`tests/e2e/tests/vite-app-e2e.test.ts`). **Remix/Next.js는 3단계(프레임워크 통합)로 이동** — 아래 "1단계 범위 결정" 참조 |
| **watch/serve 장시간 안정성**    | M      | 부분 완료 | 150회 연속 rebuild 시뮬레이션 스트레스 테스트(`tests/integration/tests/watch-stress.test.ts`)로 RSS 기울기 <20KB/rebuild 검증 (실측 0.05). 실시간 8시간+ 실측은 수동 릴리즈 전 검증으로 유지                                 |
| ~~**에러 메시지 품질**~~         | ✅     | 완료      | ANSI 컬러 출력 + Levenshtein "did you mean?" 제안 (ansi.zig, levenshtein.zig)                                                                                                                                                |
| ~~**source map 품질 검증**~~     | ✅     | 완료      | Playwright + CDP로 Chromium이 `sourceMappingURL`을 파싱하고 TS 파일명 breakpoint가 해석되는 E2E (`tests/e2e/tests/sourcemap-e2e.test.ts`)                                                                                    |
| ~~**Node.js 호환성 edge case**~~ | ✅     | 완료      | `import.meta.{url,dirname,filename}` CJS/ESM 실행 검증, 심볼릭링크·상대경로 entry 번들 통합 테스트 (`tests/integration/tests/node-compat.test.ts`)                                                                           |

#### 1단계 범위 결정: Vite만 포함, Remix/Next.js는 3단계

ROADMAP 원문은 "Next.js, Remix, Vite 앱 E2E 번들링 검증"을 묶었으나, 세 프레임워크의 ZNTC 삽입 난이도가 질적으로 다르다. 1단계는 Vite만 수용.

**Vite** — 번들러 교체 가능 구조. Vite 코어가 dev server / HMR / plugin API를 제공하고 TS/JSX 변환은 esbuild에 위임. `@zntc/vite-plugin`가 esbuild 자리에 들어감. 플러그인 하나로 통합.

**Next.js** — 번들러(webpack / Turbopack)가 프레임워크 일부로 고정. ZNTC 삽입 시 다음을 **전부** 다시 구현해야 함:

- React Server Components (RSC payload 직렬화, 서버/클라이언트 경계 자동 분리)
- `app/` / `pages/` 파일시스템 routing → manifest 생성
- `next/image`, `next/link` 전용 transform + 런타임
- SSR streaming, edge runtime, middleware, API routes 서버 전용 분리

사실상 Turbopack 클론 작업. Vercel이 Rust로 2년+ 투입 중.

**Remix (React Router v7)** — `@remix-run/dev` compiler가 핵심:

- 파일시스템 routing → route manifest 변환
- loader/action AST 분석 기반 **서버-클라이언트 이중 빌드** (loader 코드를 클라이언트 번들에서 자동 제거)
- hydration 규약, Remix 런타임과의 manifest 계약

ZNTC의 일반 번들러로 이 경계 분리 불가. Remix compiler 클론 필요.

**결론**: Next.js / Remix 지원은 "별도 어댑터 레이어"가 곧 "프레임워크 클론"을 의미하므로 **3단계(생태계)의 프레임워크 통합**에 귀속. 1단계 안정성 범위 밖. 얕은 검증("Remix 스타일 routes.tsx를 ZNTC 일반 번들로 빌드만 성공")은 가치 대비 비용이 낮아 수요 발생 시 재검토.

### 2단계: CSS + 배포

| 항목                       | 난이도 | 현재 상태                                              | 설명                                                                                                                                                                                                |
| -------------------------- | ------ | ------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| ~~**CSS 번들링**~~         | ✅     | Phase 1 완료 (@import 인라이닝 + Lightning CSS minify) | CSS Modules, 청크별 CSS는 후순위                                                                                                                                                                    |
| ~~**npm 배포**~~           | ✅     | 완료                                                   | 9 platform prebuilt sub-package (`@zntc/core-{darwin,linux,win32}-{arm64,x64,ia32}*`) + main `@zntc/core` optionalDependencies 매칭. Linux musl/glibc, Windows ia32 포함                            |
| ~~**CI 크로스 플랫폼**~~   | ✅     | 완료                                                   | `.github/workflows/ci.yml` (debug-test / release-build / napi / napi-package-smoke / publish-smoke / wasm) + `integration.yml` (ubuntu / macos / hermes / compat-table / smoke) GitHub Actions 매트릭스 |
| ~~**릴리즈 자동화**~~      | ✅     | 완료                                                   | `release.yml` — `v*` 태그 push → 9 platform NAPI + CLI 매트릭스 빌드 (ReleaseFast) → sub-package 배포 → `release.ts` 로 npm publish (NPM_TOKEN / OIDC trusted publishing 준비, `--provenance`) → GitHub Release tarball |

### 3단계: 생태계

| 항목                     | 난이도 | 현재 상태 | 설명                                                                                                                                                                                                                        |
| ------------------------ | ------ | --------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **플러그인 예제**        | S~M    | 부분      | PostCSS / Tailwind / SVG / YAML 모두 현재 plugin API (`onResolve`/`onLoad`/`transform`) 또는 `vitePlugin()` Rollup 호환 어댑터로 활용 가능 — [PLUGINS.md "활용 가능한 플러그인"](./PLUGINS.md#활용-가능한-플러그인) 참조. 공식 레퍼런스 예제 (`examples/postcss` 등) 와 빌트인 통합은 미공급 — `appDev` 추상화 (4-4) 와 같이 정리 예정 |
| ~~**import.meta.glob**~~ | ✅     | 완료      | Vite 호환 glob import (eager/import 옵션)                                                                                                                                                                                   |
| **마이그레이션 가이드**  | S      | 없음      | esbuild → ZNTC, Vite → ZNTC 설정 대응표                                                                                                                                                                                       |
| ~~**@zntc/vite-plugin**~~  | ✅     | 완료      | Vite의 esbuild transform을 ZNTC로 교체하는 플러그인                                                                                                                                                                          |
| **프레임워크 통합**      | XL     | 없음      | Next.js/Remix/SvelteKit 어댑터. 각 프레임워크가 번들러를 내장하고 있어 사실상 어댑터 = compiler 클론 (Next는 RSC/라우터/transform, Remix는 loader 경계 분리). 1단계 통합 테스트에서 분리된 배경은 위 "1단계 범위 결정" 참조 |
| **Vite 호환 모드**       | XL     | 없음      | `vite.config.js` 읽어서 마이그레이션 비용 제로 (장기 목표)                                                                                                                                                                  |
| **NativeWind 지원**      | L      | 부분 (Babel pass-through) | RN 에서 Tailwind (`className` → style). 현재 `nativewind/babel` 이 custom plugin pass-through 로 동작 (ZNTC native list 제외 — `babel.ts`). 1급 지원·CSS 컴파일 통합·예제·E2E 미공급. 아래 "NativeWind 지원 계획" 참조 |

### NativeWind 지원 계획

NativeWind v4 = ① `nativewind/babel` preset (JSX `className` → CSS interop 변환 + `jsxImportSource`) ② `tailwindcss` 가 글로벌 CSS 를 RN 런타임용 스타일 객체로 컴파일 ③ `react-native-css-interop` 런타임이 `className` → `style` 매핑. ZNTC 는 RN preset (Phase 20) · Flow · Metro 호환 · babel pass-through (`packages/react-native/src/plugins/babel.ts`) 인프라가 이미 있어 점진 도입 가능.

| 단계 | 항목 | 난이도 | 선행 | 설명 |
|---|---|---|---|---|
| NW-1 | **Babel pass-through 검증 + 예제 + E2E** | M | — | 현재 `nativewind/babel` 은 custom plugin 으로 forward 됨 (동작 확인됨, `babel.test.ts`). `examples/react-native-*` 중 하나에 NativeWind v4 통합 + RN 빌드 E2E (`tests/integration` 또는 RN smoke) 로 className 변환·tailwind CSS emit 회귀 가드 |
| NW-2 | **Tailwind CSS 컴파일 파이프라인 통합** | L | NW-1, CSS 번들링 ✅ | `global.css` (`@tailwind` 디렉티브) 를 RN preset 빌드에 entry 로 연결 — Metro transformer 가 하던 tailwind 호출을 ZNTC plugin API (`onLoad`/`transform`) 뒤로. 사용자가 `tailwindcss` 의존성 제공 (ZNTC 미번들, PLUGINS.md PostCSS 패턴과 동일) |
| NW-3 | **className → style 네이티브 transform (선택)** | XL | NW-2 | Babel 의존 제거 — `nativewind/babel` 의 JSX className 변환을 ZNTC transformer 에서 직접. `jsxImportSource` 재지정 + CSS interop wrapper 주입. ROI 선검증 필수 (Babel pass-through 가 이미 동작하므로 성능/번들 이득 measure-first) |
| NW-4 | **`--platform=react-native` 프리셋 자동 감지** | S | NW-2 | `package.json` 에 `nativewind` 존재 시 tailwind entry·CSS interop 을 RN 프리셋이 자동 배선 (zero-config). 미존재 시 무영향 |

**범위 결정**: NW-1 (검증 + 예제 + E2E) 가 즉시 가치 — Babel pass-through 가 이미 동작하므로 "지원됨"을 회귀 가드와 함께 명문화하는 게 핵심. NW-3 (네이티브 transform) 은 Babel 제거 외 이득이 불명확하므로 measure-first 후 결정 (RN 빌드는 어차피 reanimated 등 다른 babel plugin 도 pass-through 경유 — NativeWind 만 네이티브화해도 Babel 라운드트립이 사라지지 않음). 우선순위는 1~2단계(안정성/CSS) 뒤, 3단계 생태계 내 RN 트랙.

### 우선순위 흐름

```
안정성 ──→ CSS + npm 배포 ──→ 생태계
  │             │                │
  │             │                └─ 프레임워크 통합, Vite 호환
  │             └─ 없으면 웹 프로젝트에서 사용 불가
  └─ 없으면 프로덕션 신뢰 불가
```

### 4단계: Dev Server 통일 (장기, Bun 모델)

현재 dev server는 두 곳에 공존한다:

- **Zig 네이티브** (`src/server/dev_server.zig`) — `zntc serve` / `zntc dev` (Zig 바이너리). Node 미설치 환경에서도 standalone 동작.
- **JS** (`packages/core/bin/zntc.mjs:runServe`) — `zntc dev <root>` app 모드. Node/Bun 런타임에서 esbuild/postcss/sass/chokidar 등 JS 생태계 통합.

분리 배경은 **(1) HTTPS** (Zig std에 TLS 서버 미존재 → Node `node:https` / Bun TLS로 우회) **(2) JS bundler 생태계 호출** (postcss / sass / esbuild plugin) 두 축이다.

**목표**: Bun 모델로 수렴 — Zig 단일 dev server + plugin API로 JS 생태계 위임. JS dev server 폐지 또는 plugin host 로만 유지.

**Bun 참조**: HTTP/HTTPS 서버 = Zig + uWebSockets + BoringSSL. Bundler = Zig native. Watcher = kqueue/inotify 직접. PostCSS/Sass = `Bun.plugin`으로 사용자 위임.

**단계**

**TLS 결정**: **BoringSSL vendoring**. Bun 과 동일 스택. mbedTLS 대비 Chromium 호환성 / TLS 1.3 / ALPN 성숙도 우위. 빌드 사이즈 / cross-compile 비용은 감수. Bun이 `vendor/boringssl/` 로 가져가는 패턴을 참조해 `vendor/boringssl/` 아래 서브트리 또는 git submodule 로 도입 예정.

| 단계 | 항목 | 난이도 | 선행 |
|---|---|---|---|
| 4-1 | BoringSSL vendoring (`vendor/boringssl/`) + `build.zig` 통합 (정적 링크, libssl/libcrypto 산출물) | L | — |
| 4-2 | Zig dev server에 TLS 추가 + `--certfile`/`--keyfile` JS CLI와 동일 플래그로 미러링 | M | 4-1 |
| 4-3 | dev overlay 클라이언트 단일 `.js` 추출 (현재 `dev_server.zig:380-622` ≒ `zntc.mjs:814-1083` 중복) — Zig는 `@embedFile`, JS는 `readFileSync` | S | — (선행 무관, 독립) |
| 4-4 | `appDev` 컨트롤러의 postcss / sass / esbuild 호출을 plugin API 뒤로 추상화 (NAPI 플러그인 호스트 재사용) | L | 플러그인 API 4단계 ✅ |
| 4-5 | JS bundler 호출 경로 (`runBundle` esbuild/bun 분기) → ZNTC native bundler로 단일화 | XL | bundler 성숙 (현재 진행 중) |
| 4-6 | JS `runServe` 폐지 또는 plugin host로 축소 — `zntc dev` 진입점은 Zig 서버로 통일 | M | 4-2, 4-4, 4-5 |
| 4-7 | dev server proxy / middleware 옵션을 webpack-dev-server 수준으로 확장 — `pathRewrite` / `changeOrigin` / `secure` / `ws` (WebSocket proxy) / 커스텀 헤더 / `bypass` / `setupMiddlewares` 훅. **현재 한계**: `zntc.mjs:1590-1648` 의 단순 prefix→target fetch 매핑만 존재 (Bun 경로는 method/body 미전달, Node 경로는 body 미전달). 옵션 확장은 Zig 단일 dev server 도입 후 한 번에 구현 — JS `runServe` 가 4-6 에서 폐지될 운명이라 지금 JS 측 webpack-급 옵션은 throwaway | M | 4-2, 4-6 |

**현재 우선순위**: 위 1~3단계 (안정성 / CSS+배포 / 생태계) 모두 뒤. 단 4-3 (overlay 클라이언트 추출) 은 다른 단계와 독립이라 언제든 가능.

**미결정 항목**

- `appDev` 추상화 시 사용자 plugin 시그니처 호환 (Vite plugin / Rollup plugin) 유지 범위.
- 폐지 대신 plugin host 잔존 시, 두 경로(Zig serve / JS plugin host) 라우팅 분담 결정.
- BoringSSL 도입 형태: git submodule vs subtree vs prebuilt static lib 다운로드. cross-compile (Linux/macOS/Windows × arm64/x64) 매트릭스 영향.
