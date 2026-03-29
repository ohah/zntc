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
| Smoke | 125개 패키지, avg 0.94x, ❌ 0개 | ✅ |
| 7-2. emit 병렬화 | 모듈별 transform+codegen 스레드 풀 실행 | ✅ |
| 7-3. resolve 병렬화 | 배치 내 resolve 스레드 풀 + ResolveCache Mutex | ✅ |
| 7-fix. fixpoint oscillation | 미사용 모듈 제거를 fixpoint 후로 이동 (100회→2회) | ✅ |
| 8. AST 미니파이어 | constant folding, DCE, boolean simplification, comma operator | ✅ |
| 9. 배치 A | 번들러 옵션 10개 (alias, banner, globalName, publicPath, JSON ESM 등) | ✅ |
| 10. 배치 B | content hash + naming 패턴 (--entry-names, --chunk-names) | ✅ |
| 11. 배치 C | Asset 로더 (file, dataurl, text, binary, copy) + --loader CLI | ✅ |

## 번들러 성능 현황 (3242모듈, 2026-03-29 실측)
ZTS 279ms vs esbuild 182ms (**1.5배**).

| 단계 | ZTS | esbuild | 배율 | 비고 |
|------|-----|---------|------|------|
| scan (resolve+parse) | 240ms | 125ms | 1.9x | 배치 구조 한계 |
| tree-shake | 51ms | 1ms | 51x | fixpoint+stmtinfo+crossBFS |
| link | 16ms | 54ms | 0.3x | ZTS가 빠름 |
| emit | 15ms | 32ms | 0.5x | ZTS가 빠름 |
| **총합** | **279ms** | **182ms** | **1.5x** | |

## 🔜 다음 우선순위

**scan 파이프라인화 (배치 경계 제거)**
- 현재: parse 배치 → resolve 배치 → parse 배치 (배치 경계에서 대기 발생)
- 목표: Bun/esbuild처럼 모듈 발견 즉시 다음 파싱 시작 (태스크 큐 기반 파이프라인)
  - Bun: io_pool + worker_pool 2단계 ParseTask
  - esbuild: goroutine + channel
  - ZTS: 스레드 풀 + atomic 큐로 구현 가능 (Zig 0.16 async 불필요)
- 예상: scan 240ms → ~130ms

**tree-shake 알고리즘 개선**
- 현재: fixpoint 2회 + stmtinfo 15ms + crossBFS 25ms = 51ms
- esbuild는 Part 시스템으로 단일 패스 1ms
- 점진적 개선: stmtinfo 병렬화, used_exports를 BitSet으로 교체 등

## ⏳ 미완료
- **.d.ts 생성** (isolatedDeclarations) — 후순위, 당분간 tsc에 위임
- **SIMD** — 렉서 공백/식별자/문자열 스캔 가속 (parse 10-20% 개선 예상)
- **WASM 공개 AST API** — AST 안정화 후

## 의존성 관계
```
AST 안정화 ──────────────┬──→ WASM 공개 AST API
                         └──→ .d.ts (isolatedDeclarations)

번들러 성능 ─────────────┬──→ scan 파이프라인화 (배치 경계 제거)
                         └──→ tree-shake 알고리즘 개선 (stmtinfo/crossBFS)

번들러 기능 ─────────────┬──→ 로더 시스템 (JSON, text, file, dataurl)
                         ├──→ CSS 번들링 (별도 파서)
                         └──→ 플러그인 API (Zig builtin → N-API JS)

독립 (아무 때나): Flow, SIMD
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

- **CSS 번들링** — `XL (2~3주)` | 선행: emitter 출력 다중화 | 배치: 단독
  JS에서 `import './style.css'`를 처리하지 못함. CSS Modules (`import styles from './foo.module.css'`)도 미지원.
  esbuild는 CSS 파서를 내장하여 `@import` 해석 + 중복 제거 + minify까지 처리. rolldown/rspack은 PostCSS/Lightning CSS 통합.
  프론트엔드 앱의 거의 100%가 CSS import를 사용하므로, JSON 로더와 함께 가장 시급한 기능.
  **현황**: CSS 파서를 새로 작성해야 함. ModuleType.css는 정의되어 있으나 파싱/emit 로직 전무. 가장 큰 작업.

- **플러그인 API** — `XL (2~3주)` | 선행: 로더 시스템 안정화 | 배치: 단독
  사용자가 빌드 파이프라인을 확장할 수 없음. 커스텀 로더, 가상 모듈, 코드 변환 등 모두 불가.
  esbuild는 onResolve/onLoad 훅, rolldown은 Rollup 호환 resolveId/load/transform 훅 제공.
  위의 JSON/Asset/CSS도 플러그인 없이는 사용자가 직접 해결할 방법이 없으므로, 생태계 확장의 전제 조건.
  **현황**: 훅 포인트 설계 + Zig 인터페이스 + (이후) N-API JS 바인딩. resolver/graph/emitter 모두 수정 필요.

- **metafile** — `M` | 선행: 없음 | 배치: D
  빌드 결과의 입출력 파일, 사이즈, import 관계를 JSON으로 출력하는 기능이 없음.
  esbuild는 `--metafile=meta.json` 으로 번들 구성 분석 데이터 생성. bundle-buddy, esbuild-visualizer 등 시각화 도구의 입력.
  CI에서 번들 사이즈 회귀 감지, PR 코멘트에 사이즈 변화 표시 등 프로덕션 워크플로에 필수.
  **현황**: emitter에서 모듈/청크 정보는 이미 가지고 있음. JSON 직렬화 + CLI 옵션만 추가.

### Important (프로덕션 배포에 자주 필요)

- **inject** — `M` | 선행: 없음 | 배치: D
- **legal comments** — `M` | 선행: 없음 | 배치: D
- **keepNames** — `M` | 선행: 없음 | 배치: D
- **엔진 타겟** (chrome, firefox, safari, node 버전) — `XL` | 선행: 없음 | 배치: 단독

### Nice to Have

- **analyze** — `S` | 선행: metafile | 배치: D
- **mangleProps** — `XL` | 선행: 없음 | 배치: 단독
- **import.meta.glob** — `M` | 선행: 없음 | 배치: 단독
- **Virtual modules** — `M` | 선행: 플러그인 API | 배치: 플러그인과 함께

### 배치 그룹 & 구현 순서

```
배치 A ✅ 완료 ─────────────────────────────────────────────────
배치 B ✅ 완료 ──────────────────────────────────────────────────
배치 C ✅ 완료 ──────────────────────────────────────────────────

배치 D (2~3일, 독립) ───────────────────────────────────────────
  metafile + analyze + inject + legal comments + keepNames
  → 각각 M 난이도지만 서로 독립. 2~3개씩 묶어서 PR 가능.

단독 XL ────────────────────────────────────────────────────────
  CSS 번들링 (2~3주) — CSS 파서 새로 작성
  플러그인 API (2~3주) — 파이프라인 훅 설계 + N-API
  엔진 타겟 (1주+) — caniuse 데이터 테이블 구축
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
| scan 파이프라인화 | 🔜 | 배치 경계 제거 → 240ms → ~130ms 예상 |
| SIMD | 미착수 | 렉서 공백/식별자/문자열 스캔 가속 |
