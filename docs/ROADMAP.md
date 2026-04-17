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
| Smoke | 131개 패키지 (mitt, zustand, 엔진 타겟 4개 추가), avg 0.96x, ❌ 0개 | ✅ |
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
| 23. jsx-dev | React 개발 모드 `jsxDEV` + `__source`/`__self`, `--jsx=automatic-dev` / `--jsx-dev` | ✅ |
| 24. RN 호환 | self-require 방지, shimMissingExports, __rest Symbol, class field _this 캡처 | ✅ |
| 25. ES5 다운레벨 | let→var void 0 초기화, spread string, for-in destructuring, computed destr, super computed | ✅ |
| 26. compat-table | kangax ES5~ES2022 100% + SWC 비교 29 cases × 9 targets CI | ✅ |
| 27. ES2023 | `--target=es2023`, hashbang (#!) 다운레벨, compat_table 엔진 버전 | ✅ |
| 28. NAPI | C NAPI 바인딩: transpile, buildSync, build (async + plugins) | ✅ |
| 29. Node.js CLI | Zig CLI → Node.js/Bun CLI 전환 (Rolldown 방식), watch/serve JS 구현 | ✅ |
| 30. Vite 어댑터 | `vitePlugin()` Rollup→ZTS 플러그인 변환, resolveId/load/transform | ✅ |
| 31. define/alias | NAPI BuildOptions에 `define`/`alias` 옵션 노출 | ✅ |
| 32. tsconfig | CLI에서 tsconfig.json 자동 탐색+로드 (experimentalDecorators, jsx 등) | ✅ |
| 33. BuildOptions 확장 | loader, conditions, resolveExtensions, mainFields, target, outdir, outfile, write | ✅ |
| 34. 플러그인 훅 확장 | renderChunk/generateBundle NAPI 노출 + vitePlugin 매핑 | ✅ |
| 35. async 플러그인 | 모든 훅 async/Promise 반환 지원 (MaybePromise) | ✅ |
| 36. import.meta.glob | Vite 호환 `import.meta.glob()`, eager/import 옵션 | ✅ |
| 37. Stage 3 decorators | TC39 Stage 3 데코레이터 (method/getter/setter/field/accessor/class, MobX 6 호환) | ✅ |
| 38. CSS 번들링 | @import 인라이닝, 별도 .css 파일 emit, Lightning CSS minify 연동 | ✅ |

## 번들러 성능 현황 (2026-04-10 실측)

### 합성 벤치마크 (200모듈, CLI 직접 호출)
| Tool | Avg (ms) | vs fastest |
|------|----------|------------|
| **ZTS** | **7** | 1.0x |
| Bun | 10 | 1.4x |
| esbuild | 13 | 1.9x |
| rolldown | 62 | 8.9x |

### 실제 npm 패키지 (131개 스모크 테스트)
평균 번들 사이즈 비율: **0.96x** (esbuild 대비 4% 작음). 122/131 케이스에서 ZTS가 더 작음.

주요 실측:
| 라이브러리 | ZTS | esbuild | rolldown |
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

- **SSE 이벤트 스트림** (`/sse/events`) — `server_ready`, `watch_change`, `bundle_build_*`, `cache_reset` 실시간 브로드캐스트 (rollipop 호환)
- **Control API** (`/reset-cache`) — 외부에서 캐시 무효화 트리거
- **MCP 서버** (`/mcp`) — JSON-RPC 2.0, `initialize`/`tools/list`/`tools/call`. 도구: `reset_cache`, `get_build_events`. Claude Code 등 LLM 에이전트가 `.mcp.json`으로 직접 연결 가능

## ✅ 최근 추가 (CLI / Config / Diagnostics / RN)

- **`zts.config.json` 자동 로드** — cwd에 있으면 CLI 기본값으로 적용. `"$schema"` 선언으로 VSCode autocomplete (e8b8e9cf)
- **TranspileOptions JSON schema 자동 생성** — `zig build schema` → `transpile-options.schema.json` (comptime reflection, 단일 소스 진실) (e9272ac1)
- **TranspileOptions 단일 JSON payload** — CLI/NAPI/WASM 간 옵션 전달을 필드별 인자 → JSON 페이로드로 통일 (8047603a)
- **Rich diagnostic 오버홀**
  - `TranspileResult.errors`에 시맨틱 에러를 렌더된 문자열로 노출 (9dfea7dd)
  - Multi-span label + redeclaration previously-here hint (9d9b3ab5)
  - Previously-declared-here labels — 6개 재선언 에러 (75626350)
  - Reference-to-definition label — 3개 에러 (853ad5c2)
  - Help hint + 에러별 `ZTSxxxx` docs URL (fa257fed, 2698079e)
  - 에러 발생 시 CLI exit 1 (05e12e5a)
- **Bun 스타일 crash report** — panic handler + GitHub 신고 안내 (abd1d11b)
- **React Native 통합 강화**
  - Asset `@2x` / `@3x` scale variant 자동 감지 + emit (25114fd8)
  - Metro AssetRegistry 호환 출력 (68d3418b)
  - `asset_registry` 모듈 `require → require_xxx` 변환 (89a57756)
  - `resolver.blockList` (7918387a), `resolve.fallback` (e6559104), `watchFolders` (b104b828)
- **Plugin API 확장** — `onResolve` 훅이 `{ disabled: true }` 반환 허용 (49955634)
- **BuildOptions 보완** — `strictExecutionOrder`, `scopeHoist`, `workletTransform` 추가 (eb909fcc)

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

esbuild / rolldown / rspack 기준으로 ZTS에 빠진 기능 목록.
- **난이도**: S(반나절) / M(1~2일) / L(3~5일) / XL(1주+)
- **선행**: 먼저 구현해야 하는 기능. 없으면 독립
- **배치**: 같이 묶어서 한 PR로 할 수 있는 그룹

### Critical (없으면 실사용 어려움)

- ~~**Asset 로더** (file, dataurl, text, binary, copy)~~ — ✅ 완료
  `--loader:.png=file` 로 확장자별 로더 지정. fake JS 모듈 방식 (rolldown 방식).
  file/copy 로더는 content hash 파일명으로 출력 디렉토리에 복사 + URL 문자열 export.
  `--asset-names`, `--public-path` 지원.

- ~~**플러그인 API**~~ — ✅ 완료 ([PLUGINS.md](./PLUGINS.md) 참조)
  - 1단계: ✅ Zig Builtin 플러그인 — 함수 포인터 기반 Plugin struct, 5개 훅 (worklet/refresh 등 내부 전용)
  - ~~2단계: JS 플러그인 subprocess~~ — ❌ D101로 제거. NAPI(3단계)가 기본 경로
  - 3단계: ✅ N-API .node addon — in-process 호출, TSFN 기반 async 브릿지 (기본 JS 플러그인 경로)
  - 4단계: ✅ Vite/Rollup 어댑터 — vitePlugin() + async 훅 + renderChunk/generateBundle
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
- **manualChunks** — `L` | 사용자 정의 청크 분할 규칙 (rolldown advancedChunks, rspack splitChunks)
  프로덕션 청크 최적화 시 벤더/공통 코드 분리 필수. rolldown은 `advancedChunks`, rspack은 webpack의 `splitChunks` 호환.
- ~~**preserveModules**~~ — ✅ 완료. `--preserve-modules` + `--preserve-modules-root` (Rollup/Rolldown 호환)
- ~~**using 다운레벨링**~~ — ✅ 완료. `using`/`await using` → try-finally + `__using`/`__callDispose` (esbuild 호환)
- ~~**설정 파일 (zts.config.js)**~~ — ✅ 완료. `packages/core`에서 `defineConfig()` 내보냄.
- ~~**JS Build API**~~ — ✅ 완료. `packages/core`에서 `build()` 함수 내보냄 (NAPI 기반, in-process).
- ~~**HTTPS dev server**~~ — ✅ 완료. `--certfile`/`--keyfile` TLS 지원 (Node.js/Bun CLI)

### Nice to Have

- **mangleProps** — `XL` | 선행: 없음 | 배치: 단독
- ~~**import.meta.glob**~~ — ✅ 완료. Vite 호환 `import.meta.glob()` (eager/import 옵션 지원)
- ~~**Virtual modules**~~ — ✅ 완료. `\0` prefix 기반 virtual module 지원 (플러그인 resolveId/load)
- ~~**Stage 3 decorators**~~ — ✅ 완료. TC39 Stage 3 데코레이터 다운레벨링 (method/getter/setter/field/accessor/class, initializer 체이닝, MobX 6 호환)
- **Module Concatenation 고도화** — `XL` | rspack/rolldown 수준 scope hoisting
- **innerGraph** — `L` | 변수 할당 분석으로 더 정밀한 DCE
- **lazyBarrel** — `L` | barrel 파일 re-export 컴파일 생략 (rolldown)
- ~~**realContentHash**~~ — ✅ 완료. SHA-256 기반 `[hash]` 패턴 (emitter/chunks.zig)
- ~~**sourcemapDebugIds**~~ — ✅ 완료. `--sourcemap-debug-ids` UUID v4, 번들+소스맵 매칭
- ~~**shimMissingExports**~~ — ✅ 완료. `--shim-missing-exports` 롤다운 호환

### 번들러 인프라 — rolldown/rspack 비교

| 항목 | 난이도 | esbuild | rolldown | rspack | ZTS | 설명 |
|------|--------|---------|----------|--------|-----|------|
| ~~**CSS 번들링**~~ | ✅ | ✅ | ✅ | ✅ | ✅ | @import 인라이닝 + Lightning CSS minify (CSS Modules 후순위) |
| **manualChunks** | L | ❌ | ✅ advancedChunks | ✅ splitChunks | ❌ | 사용자 정의 청크 분할 규칙 |
| **innerGraph** | L | ❌ | ✅ | ✅ | ❌ | 변수 할당 추적으로 정밀 DCE |
| **Persistent caching** | XL | ❌ | ❌ | ✅ | ❌ | 디스크 캐시, 콜드 리빌드 250%↑ |
| **Module Federation** | XL | ❌ | ❌ | ✅ | ❌ | 마이크로프론트엔드 코드/리소스 공유 |
| **Lazy compilation** | XL | ❌ | ❌ | ✅ | ❌ | 온디맨드 모듈 컴파일 (dev 시작 가속) |
| ~~**Stage 3 decorators**~~ | ✅ | ❌ | ✅ | ✅ | ✅ | TC39 Stage 3 데코레이터 (legacy + Stage 3) |
| **mangleProps** | XL | ✅ | ❌ | ❌ | ❌ | cross-module 프로퍼티 난독화 |
| **lazyBarrel** | L | ❌ | ✅ | ❌ | ❌ | barrel re-export 컴파일 생략 |
| ~~**import.meta.glob**~~ | ✅ | ❌ | ✅ | ❌ | ✅ | Vite 호환 glob import |
| ~~**플러그인 N-API**~~ | ✅ | ✅ (Go) | ✅ (Rust) | ✅ | ✅ | in-process NAPI + async 훅 + Vite 어댑터 |
| ~~**HMR module-level**~~ | ✅ | ❌ | ✅ | ✅ | ✅ | `import.meta.hot.accept()` |
| ~~**설정 파일**~~ | ✅ | ❌ | ✅ | ✅ | ✅ | `defineConfig()` |
| ~~**JS Build API**~~ | ✅ | ✅ | ✅ | ✅ | ✅ | `build()` |
| ~~**HTTPS dev server**~~ | ✅ | ❌ | ✅ | ✅ | ✅ | `--certfile`/`--keyfile` |

### 배치 그룹 & 구현 순서

```
배치 A ✅ 완료 ─────────────────────────────────────────────────
배치 B ✅ 완료 ──────────────────────────────────────────────────
배치 C ✅ 완료 ──────────────────────────────────────────────────

배치 D ✅ 완료 ──────────────────────────────────────────────────
  metafile + analyze + inject + legal comments + keepNames

배치 E ✅ 완료 ──────────────────────────────────────────────────
  --outbase, --packages=external, --drop-labels, --pure:fn,
  --line-limit, --allow-overwrite, --log-limit, --tsconfig-raw,
  --node-paths, output.intro/outro, output.globals,
  inlineDynamicImports, cleanDir, --jsx-side-effects,
  --ignore-annotations, --watch-delay, --servedir,
  shimMissingExports, extensionAlias, sanitizeFileName

단독 XL ────────────────────────────────────────────────────────
  CSS 번들링 ✅ Phase 1 완료 — @import 인라이닝 + Lightning CSS minify (CSS Modules 후순위)
  플러그인 API ✅ 1-4단계 완료 — NAPI + Vite 어댑터 + async 훅
  엔진 타겟 ✅ 완료 — esbuild compat-table 기반 (8엔진 × 18 feature)
  Web Worker ✅ 완료 — new Worker(new URL(...)) 자동 감지+IIFE 번들 (esbuild 미지원)
  import.meta.glob ✅ 완료 — Vite 호환 glob import (eager/import 옵션)
  mangleProps (1주+) — cross-module 프로퍼티 추적
  Stage 3 decorators ✅ 완료 — TC39 Stage 3 데코레이터 (legacy + Stage 3, MobX 6 호환)
  Module Concatenation 고도화 — rspack/rolldown 수준 scope hoisting
  manualChunks (3~5일) — 사용자 정의 청크 분할
  innerGraph (3~5일) — 변수 할당 추적 정밀 DCE
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
- ✅ _default 합성 변수 충돌: 여러 ESM 모듈의 export default가 같은 변수 공유 (#704)
- ✅ re-export default 할당 누락: `export { default } from` 패턴에서 __esm body 비어있음 (#705)
- ✅ var _default 중복 선언: import + export default 패턴에서 호이스팅 충돌 (#706)
- ✅ CJS 엔트리 자동 호출 누락: IIFE 번들에서 `require_index()` 미삽입 (#707)
- ✅ JSX 파서: closing tag 뒤 텍스트 파싱 실패 (advanceAfterJSXClose)
- ✅ enum re-export: `enum Foo {} export { Foo }` semantic 에러
- ✅ CLI memory leak: `--plugin`, `--proxy` 옵션의 ArrayList 미해제

### 알려진 제한 (Known Limitations)

**CJS wrap Asset 모듈의 tree-shaking 미지원**
Asset 모듈은 `exports_kind = .commonjs`, `wrap_kind = .cjs`로 처리됨.
미사용 import라도 `require_X()` 호출이 side-effect로 간주되어 tree-shaker가 제거하지 못함.
esbuild는 `NoSideEffects_PureData` 마킹으로 이를 해결하지만, ZTS의 tree-shaker는 CJS wrap에 대해 아직 이 최적화를 수행하지 않음.
(JSON 모듈은 ESM AST 변환으로 tree-shaking 가능 — PR #589)

## ES 다운레벨링 커버리지 (kangax/compat-table)

`bun run test:compat`으로 실행. CI에서 자동 검증.

| Target | Pass | Total | Rate |
|--------|------|-------|------|
| ES5 | 237 | 237 | 100% |
| ES2015 | 17 | 17 | 100% |
| ES2016 | 14 | 14 | 100% |
| ES2017 | 14 | 14 | 100% |
| ES2018 | 12 | 12 | 100% |
| ES2019 | 10 | 10 | 100% |
| ES2020 | 9 | 9 | 100% |

네이티브 엔진 전용 테스트 스킵 (GeneratorFunction 생성자, iterable 프로토콜).
SWC 비교 테스트: 29 cases × 9 targets 전부 통과.

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
| tree-shake 알고리즘 최적화 | ✅ 완료 | clearUsedExports 제거, has_direct_used_export O(1) 배열 (#917) |
| resolve 캐시 스택 버퍼 | ✅ 완료 | 캐시 키 alloc/free 제거, graph -7% (#918) |
| 파서 inline scan | ✅ 완료 | import/binding scanner AST 재순회 제거 (#919) |
| StmtInfo semantic 사전 구축 | ✅ 완료 | tree-shake 29.8→5.6ms (-81%), total 82.7→56.9ms (-31%) (#920) |
| resolveExportChain 메모이제이션 | ✅ 완료 | re-export chain 조건부 캐시 (#918) |
| SIMD | ✅ 부분 적용 | `@Vector(16, u8)` 공백/식별자 스캔 적용 완료 (scanner.zig). 추가 확장 여지 있음 |

## 프로덕션 로드맵

기능은 대부분 갖춰졌으나, 실제 프로젝트에서 esbuild/Vite를 대체하려면 아래 항목이 필요.

### 1단계: 안정성 (현재 가장 중요)

| 항목 | 난이도 | 현재 상태 | 설명 |
|------|--------|----------|------|
| **통합 테스트 확대** | L | 부분 완료 | ✅ Vite: multi-module TS/TSX 앱을 `vite-plugin-zts`로 프로덕션 번들 → Playwright 브라우저 실행 E2E (`tests/e2e/tests/vite-app-e2e.test.ts`). **Remix/Next.js는 3단계(프레임워크 통합)로 이동** — 아래 "1단계 범위 결정" 참조 |
| **watch/serve 장시간 안정성** | M | 부분 완료 | 150회 연속 rebuild 시뮬레이션 스트레스 테스트(`tests/integration/tests/watch-stress.test.ts`)로 RSS 기울기 <20KB/rebuild 검증 (실측 0.05). 실시간 8시간+ 실측은 수동 릴리즈 전 검증으로 유지 |
| ~~**에러 메시지 품질**~~ | ✅ | 완료 | ANSI 컬러 출력 + Levenshtein "did you mean?" 제안 (ansi.zig, levenshtein.zig) |
| ~~**source map 품질 검증**~~ | ✅ | 완료 | Playwright + CDP로 Chromium이 `sourceMappingURL`을 파싱하고 TS 파일명 breakpoint가 해석되는 E2E (`tests/e2e/tests/sourcemap-e2e.test.ts`) |
| ~~**Node.js 호환성 edge case**~~ | ✅ | 완료 | `import.meta.{url,dirname,filename}` CJS/ESM 실행 검증, 심볼릭링크·상대경로 entry 번들 통합 테스트 (`tests/integration/tests/node-compat.test.ts`) |

#### 1단계 범위 결정: Vite만 포함, Remix/Next.js는 3단계

ROADMAP 원문은 "Next.js, Remix, Vite 앱 E2E 번들링 검증"을 묶었으나, 세 프레임워크의 ZTS 삽입 난이도가 질적으로 다르다. 1단계는 Vite만 수용.

**Vite** — 번들러 교체 가능 구조. Vite 코어가 dev server / HMR / plugin API를 제공하고 TS/JSX 변환은 esbuild에 위임. `vite-plugin-zts`가 esbuild 자리에 들어감. 플러그인 하나로 통합.

**Next.js** — 번들러(webpack / Turbopack)가 프레임워크 일부로 고정. ZTS 삽입 시 다음을 **전부** 다시 구현해야 함:
- React Server Components (RSC payload 직렬화, 서버/클라이언트 경계 자동 분리)
- `app/` / `pages/` 파일시스템 routing → manifest 생성
- `next/image`, `next/link` 전용 transform + 런타임
- SSR streaming, edge runtime, middleware, API routes 서버 전용 분리

사실상 Turbopack 클론 작업. Vercel이 Rust로 2년+ 투입 중.

**Remix (React Router v7)** — `@remix-run/dev` compiler가 핵심:
- 파일시스템 routing → route manifest 변환
- loader/action AST 분석 기반 **서버-클라이언트 이중 빌드** (loader 코드를 클라이언트 번들에서 자동 제거)
- hydration 규약, Remix 런타임과의 manifest 계약

ZTS의 일반 번들러로 이 경계 분리 불가. Remix compiler 클론 필요.

**결론**: Next.js / Remix 지원은 "별도 어댑터 레이어"가 곧 "프레임워크 클론"을 의미하므로 **3단계(생태계)의 프레임워크 통합**에 귀속. 1단계 안정성 범위 밖. 얕은 검증("Remix 스타일 routes.tsx를 ZTS 일반 번들로 빌드만 성공")은 가치 대비 비용이 낮아 수요 발생 시 재검토.

### 2단계: CSS + 배포

| 항목 | 난이도 | 현재 상태 | 설명 |
|------|--------|----------|------|
| ~~**CSS 번들링**~~ | ✅ | Phase 1 완료 (@import 인라이닝 + Lightning CSS minify) | CSS Modules, 청크별 CSS는 후순위 |
| **npm 배포** | L | 로컬 빌드만 | `npm install zts`로 설치. cross-platform prebuilt binary (macOS/Linux/Windows arm64/x64) |
| **CI 크로스 플랫폼** | M | 없음 | GitHub Actions: Linux/macOS/Windows × arm64/x64 빌드+테스트 |
| **릴리즈 자동화** | M | 없음 | 태그 push → 바이너리 빌드 → npm publish → GitHub Release |

### 3단계: 생태계

| 항목 | 난이도 | 현재 상태 | 설명 |
|------|--------|----------|------|
| **플러그인 예제** | S~M | 없음 | PostCSS, Tailwind, SVG, YAML 등 커뮤니티 플러그인 레퍼런스 |
| ~~**import.meta.glob**~~ | ✅ | 완료 | Vite 호환 glob import (eager/import 옵션) |
| **마이그레이션 가이드** | S | 없음 | esbuild → ZTS, Vite → ZTS 설정 대응표 |
| ~~**vite-plugin-zts**~~ | ✅ | 완료 | Vite의 esbuild transform을 ZTS로 교체하는 플러그인 |
| **프레임워크 통합** | XL | 없음 | Next.js/Remix/SvelteKit 어댑터. 각 프레임워크가 번들러를 내장하고 있어 사실상 어댑터 = compiler 클론 (Next는 RSC/라우터/transform, Remix는 loader 경계 분리). 1단계 통합 테스트에서 분리된 배경은 위 "1단계 범위 결정" 참조 |
| **Vite 호환 모드** | XL | 없음 | `vite.config.js` 읽어서 마이그레이션 비용 제로 (장기 목표) |

### 우선순위 흐름

```
안정성 ──→ CSS + npm 배포 ──→ 생태계
  │             │                │
  │             │                └─ 프레임워크 통합, Vite 호환
  │             └─ 없으면 웹 프로젝트에서 사용 불가
  └─ 없으면 프로덕션 신뢰 불가
```
