# RFC: Emit Incremental — emit_module_pass Chunk-Level Dirty Marking

상태: **CLOSED · NO-GO (모든 작은 fix 가 noise / 회귀, 재시도 금지)** · 분류: 결정 문서
부모 RFC: [RFC_EMIT_INCREMENTAL_DEV_SERVER.md](./RFC_EMIT_INCREMENTAL_DEV_SERVER.md) PR-C 영역
관련: `src/bundler/emitter.zig:563` (emit_module_pass), `:670` (skip_bundle_concat), `src/bundler/compiled_cache.zig`
선행: [RFC_GRAPH_PERSISTENCE](./RFC_GRAPH_PERSISTENCE.md) NO-GO

## 0. 종결 (Sub-PR-C 시도 결과)

본 RFC 의 모든 sub-PR 영역이 **measurement-first NO-GO**.

### PoC 측정 결과 (2026-05-28, lodash 641 modules, ZNTC dev_server WS HMR)

| Sub-PR | 영역 | 측정 | 결과 |
|---|---|---|---|
| C.1 (#3938) | ChunkEmitCache API skeleton | 호출자 없음, 영향 0 | ✅ 자산 보존 |
| **C.2 — Phase 1.5 parallel** | tryHit + hit.dupe per module 을 thread pool 화 | 307→323ms (-16ms 회귀) | ❌ thread pool overhead > cache lookup 비용 |
| **C.2 — CSS short-circuit** | graph 의 css 모듈 없으면 emitCssBundle DFS skip | 307→307ms (noise) | ❌ Debug 24ms 가 Release 에선 noise 안에 묻힘 |
| **C.2 — dev_codes module cache** | compiled_cache.Entry 에 hmr_code 추가, emit_concat 의 concat skip | 307→304ms (noise) | ❌ Release 에서 noise |

**RFC §6 의 NO-GO 기준 정확히 부합**: "절약 <30ms 또는 정확성 회귀 → RFC_EMIT_INCREMENTAL_CLOSED.md 종결".

### emit sub-phase 의 진짜 분포 (Debug profile, lodash 641 modules incremental rebuild)

```
emit total       151.35ms
├─ emit.concat   95.53ms  (25.9%) ← Debug 측정 최대, 그러나 Release 에선 noise
├─ emit.css      24.54ms  (CSS 없는데도 24ms — DFS traverse, fix 시도 noise)
├─ emit.output   12.51ms (self)
├─ emit.module.pass  16.08ms  (Phase 1.5 lookup, parallel 시도 회귀)
└─ emit.prelude   0.32ms
```

Debug build 측정 vs Release wall 측정 의 *큰 괴리* — Debug 의 ms 단위 sub-phase 가 Release 에선 노이즈 floor 아래.

### 진짜 fix 영역

dev_server HMR 의 진짜 architectural 개선은 **`RFC_LIFECYCLE_SCOPE_REDESIGN`** (별도 mid-term epic):
- build-scope vs graph-scope 메모리 영역 분리
- canonical_name / hmr_code / compiled_cache entry 의 ownership 일관성
- esbuild SymbolID 패턴 (path/ID-based references)
- 1-2 quarter 작업

본 RFC 의 *작은 fix* 들은 모두 *Release noise 안* — 의미 있는 단기 win 없음.

**재시도 금지 영역:**
- Phase 1.5 parallel 화 (16ms 회귀, RFC 영역 NO-GO 확정)
- CSS emitCssBundle short-circuit (Release noise, ROI 측정 불가)
- dev_codes module cache (Release noise, ROI 측정 불가)
- chunk-level dirty marking 단순 wire-up (정확한 ChunkEmitCache hit 시나리오 부재)

**자산 보존 (호출자 없음, 영향 0):**
- `src/bundler/chunk_emit_cache.zig` (Sub-PR-C.1, #3938) — 향후 lifecycle redesign 시 활용 가능
- 단위 테스트 9건

**대안 영역:**
- **PR-A 머지 (#3932) 의 -23% 가 dev_server HMR 의 최대 단기 win** — 추가 작은 fix 없음
- **`RFC_LIFECYCLE_SCOPE_REDESIGN` mid-term epic** — 진짜 esbuild parity
- 측정 노이즈 분리 위한 *RFC_RELEASE_PROFILING_HARNESS* (별개 작은 epic) — Debug/Release 측정 통합 도구

---

(이하 원래 RFC 본문 — Sub-PR-C 의 *원안 design*. 종결됐으나 history 보존.)


## 1. 배경

dev_server lodash HMR latency 분해 (post Sub-PR-B.2):

```
scan      ~38ms
parse     ~54ms
semantic  ~10ms
resolve   ~3ms
graph    ~146ms   ← RFC_GRAPH_PERSISTENCE CLOSED, NO-GO
link      ~61ms
emit      ~80ms   ← PR-A 후 (skip_bundle_output 으로 172→80)
```

esbuild lodash in-process rebuild = 50ms. graph 영역이 architecture lock 으로 막힘.

**emit 영역은 graph 와 *독립* — graph 안 건드리고 fix 가능**:
- `emit_module_pass` (`emitter.zig:563`) 가 매 빌드 mod 단위 emit
- `compiled_cache` (PR-A 의 hash 분리 fix 로 작동) — cache hit/miss 모듈 단위 검사
- *모듈 단위* cache 는 있지만, *chunk 전체* re-emit 은 매번 발생

### 1.1 emit_module_pass 의 현재 동작

`emitter.zig:563-660` (요약):
1. `Phase 1.5`: compiled_cache lookup per module → hit/miss bitmap
2. `Phase 2`: parallel emit per module (miss 만)
3. `Phase 2.5`: cache put per module (miss 만)
4. `Phase 3 (emit_concat)`: 모든 모듈을 chunk 단위 concat (현재는 skip_bundle_output 로 dev mode 시 skip)

**PR-A 후 dev mode 의 emit_concat 은 이미 skip**. 남은 비용 = `emit_module_pass` 의 *모듈 단위 emit per chunk*.

### 1.2 진짜 병목 = 모듈 단위 emit 의 parallel 처리

incremental 의 emit ~80ms (PR-A 후) wall 중:
- cache hit ratio = 640/641 (PR-A 의 hash 분리 효과)
- 즉 *변경 모듈 1개만 진짜 emit*, 나머지 640 모듈은 cache hit (Phase 1.5 의 `cache.tryHit`)
- 그러나 cache hit 자체 비용 (`computeInputHash` per module + `tryHit` + `dupe`) = ~80ms wall 의 큰 부분

esbuild 가 50ms 인 이유:
- chunk-level incremental — 변경 모듈이 포함된 *chunk 하나* 만 re-emit
- 다른 chunk 는 *이전 빌드의 byte stream 그대로 재사용*
- 즉 *cache lookup per module* 도 발생 안 함

## 2. 제안 — Chunk-Level Dirty Marking

### 2.1 핵심 원칙

1. **Chunk-level cache** — chunk 단위 emit byte stream 캐시 (모듈 단위 아닌)
2. **Dirty marking** — 변경 모듈이 속한 chunk 만 dirty 마킹
3. **Non-dirty chunk skip** — emit_module_pass 자체 skip, 이전 byte stream 재사용

### 2.2 graph 영역과의 분리

본 RFC 는 **`ModuleGraph` 인스턴스 lifecycle 안 건드림** (RFC_GRAPH_PERSISTENCE CLOSED 영역). emit 단계의 *결과* (chunk byte stream) 만 cache. graph 가 매 빌드 fresh init 돼도 emit cache 는 graph 외부 (예: IncrementalBundler 또는 emit_store) 에 보존.

cache key = `chunk_id` + `included module hashes`. 변경 모듈의 hash 변경 → 해당 chunk 의 cache miss.

### 2.3 측정 목표

| Phase | 현재 (PR-A 후) | 목표 (PR-C) | 회수치 |
|---|---|---|---|
| emit | ~80ms | ~10ms | -70ms |
| WALL | 307ms | ~240ms | -67ms |
| esbuild 격차 | 6× | ~5× | (graph 가 막혀 한계) |

esbuild 50ms 까지 closer 가지만 graph 146ms 가 architectural lock 이라 *graph + emit fix 합치면 ~30-50ms 가능 (graph 가 lifecycle redesign 후)*. 본 RFC 만으로는 ~240ms 가 한계.

### 2.4 변경 영역

**A) `ChunkEmitCache` 신규**
- 위치: `src/bundler/chunk_emit_cache.zig` (신규)
- key = `(chunk_id, sorted modules hash)`, value = `EmittedChunk { bytes, sourcemap_segments, modules: []ModuleEmitInfo }`
- `tryHit(chunk_id, modules)` / `put(chunk_id, modules, emitted)`
- `IncrementalBundler` 가 owner (graph 외부)

**B) `emit_module_pass` 단계 분기**
- chunk_id 시점에 `ChunkEmitCache.tryHit` 호출
- hit 면 *모든 module emit skip*, cached bytes 직접 chunk output 으로
- miss 면 현재 path (per-module emit + cache put 후 chunk 도 cache put)

**C) Chunk membership 결정의 안정성**
- chunk 분배가 *deterministic* 필요 — 같은 입력 → 같은 chunk id + modules
- dev 모드의 single chunk 는 trivial (모든 모듈이 chunk 0)
- production splitting 시 chunk hash 가 변경 모듈 영향 받음 — 그 chunk 만 cache miss

**D) Dev mode 우선**
- production splitting 시 chunk hash 변경 추적 복잡 — 별도 PR
- 본 RFC scope = dev mode (single chunk) 만 우선 적용

### 2.5 단계별 PR 분할

**Sub-PR-C.1: `ChunkEmitCache` API skeleton (S)**
- 신규 struct + init/deinit/tryHit/put. 호출자 없음.
- 단위 테스트.
- 영향 0.

**Sub-PR-C.2: Dev mode single-chunk wire-up + PoC 측정 (M, GO/NO-GO)**
- `emit_module_pass` 시작 시 ChunkEmitCache.tryHit
- single chunk + dev mode 케이스 한정
- ZNTC_EMIT_INCREMENTAL=1 env opt-in (kill-switch)
- lodash dev_server HMR 측정 — emit 80→? (목표 ≤30ms)
- **GO/NO-GO 결정**

**Sub-PR-C.3: 정확성 가드 + production opt-in (M)**
- HMR client 가 받는 dev_codes / sourcemap segments 의 wire form 회귀 가드
- chunk dirty marking 의 false negative (변경 안 잡힘) 검증
- ZNTC_EMIT_INCREMENTAL default true 전환

**Sub-PR-C.4: Production splitting 지원 (L, 후속)**
- 여러 chunk 환경에서 dirty chunk 만 re-emit
- chunk hash 변경 추적
- RN 회귀 가드

## 3. PoC 계획

### Step 1 — emit_module_pass 의 *진짜* sub-phase 분포 측정 (이번 RFC 작성 전제)

PR-A 후 emit ~80ms 의 분해:
- compiled_cache.tryHit per module: ?
- emitModule per module (miss 만): ?
- compiled_cache.put per module: ?
- dev_codes collection: ?
- sourcemap segment 누적: ?

incremental 측정 + ZNTC_PROFILE detailed 로 확인 필요. PoC step 2 의 prerequisite.

### Step 2 — `ChunkEmitCache.tryHit` PoC 시뮬레이션

미구현 시 측정 — emit 단계 *전체 skip* 시 wall 의 이론적 하한 확인:
- `emit_module_pass` 시작점에서 즉시 *cached output* 반환 (dummy)
- 측정: wall = scan + parse + semantic + resolve + graph + link = ? ms
- 이 값이 *graph fix 없이 도달 가능한 하한*

### Step 3 — Sub-PR-C.1 (next session)

API skeleton + 단위 테스트.

### Step 4 — Sub-PR-C.2 (PoC GO/NO-GO)

본격 wire-up + lodash 측정.

## 4. 회귀 가드

- `tests/benchmark/devserver-hmr.ts` — dev_server WS HMR latency (bench follow-up PR)
- 내장 `incremental_bench_v4` — emit sub-phases timing
- 새 fixture: HMR client 의 dev_codes wire form 정확성

## 5. RN 영향

| Sub-PR | RN 영향 |
|---|---|
| C.1 (API skeleton) | 0 (호출자 없음) |
| C.2 (dev mode wire-up) | 0 (RN HMR 은 NAPI watch path, 본 RFC scope 외) |
| C.3 (정확성 가드) | 0 |
| **C.4 (production splitting)** | **잠재 risk** — RN bundle (single IIFE) 의 emit 영향. 회귀 가드 (RN bare/large/expo) 필수 |

NAPI watch.zig 의 RN HMR 은 별도 incremental loop — 본 RFC 와 무관.

## 6. 정책 / 결정

### GO/NO-GO 기준 (Sub-PR-C.2)

- ✅ GO: lodash emit 80→≤30ms (~60% 절약). PR-C.3/C.4 진행.
- ❌ NO-GO: 절약 <30ms 또는 정확성 회귀 → RFC_EMIT_INCREMENTAL_CLOSED.md 종결.

### Out of scope

- **Graph persistence** — RFC_GRAPH_PERSISTENCE CLOSED. 본 RFC 는 graph 안 건드림.
- **Lifecycle scope redesign** — 별도 epic, mid-term.
- **mangler size gap** — RFC_MANGLER_SIZE_GAP_CLOSED 영역.

### 진짜 의의

RFC_GRAPH_PERSISTENCE 가 NO-GO 라 graph 146ms 는 architectural lock. 그러나 *emit 80ms 영역은 graph 와 독립* — 안전하게 fix 가능. dev_server HMR 307ms → ~240ms (~22% 절약) 의 단기 win. 진짜 esbuild parity (~50ms) 는 lifecycle redesign 후.
