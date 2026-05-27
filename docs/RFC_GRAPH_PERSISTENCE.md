# RFC: Graph Persistence — Incremental Build 의 ModuleGraph Instance 재사용

상태: **DRAFT · 측정 기반 epic** · 분류: dev UX / core 재설계
부모 RFC: [RFC_EMIT_INCREMENTAL_DEV_SERVER.md](./RFC_EMIT_INCREMENTAL_DEV_SERVER.md) PR-B 영역
관련: `src/bundler/bundler.zig:1073`, `src/bundler/incremental.zig`, `src/bundler/graph.zig`, `src/bundler/graph/build_flow.zig`, `src/bundler/graph/resolve_imports.zig`

## 1. 배경

PR-A (#3932) 머지 후 dev_server lodash HMR latency = **307ms** (steady state). 분해 (incremental, post-PR-A 추정):

```
scan      ~38ms
parse     ~54ms
semantic  ~10ms
resolve   ~3ms
graph    ~146ms   ← wall 의 47%, 최대 phase
link      ~61ms
emit      ~80ms   (PR-A 로 172→80, skip_bundle_output 효과)
```

esbuild lodash in-process rebuild = 50ms. 격차 = ~6×. 진짜 root 는 graph 의 *replay* 영역 (warm discover 27ms 중 96% = replay).

### 1.1 replay 가 왜 매번 실행되는가

`src/bundler/bundler.zig:1073`:
```zig
var graph = ModuleGraph.init(self.allocator, self.getResolveCache());
```

**매 `bundler.bundle()` 호출 시 ModuleGraph instance 가 새로 생성**. graph 의 state (modules, requested_exports, dependency edges, worker_entries 등) 는 *비어있음*. cache hit 모듈도 graph state 를 *replay 로 재구성* 해야 함:

```
resolve_imports.zig:31  replayCachedResolvedDeps  ← cache hit 모듈 한 번 호출
  ├─ addModuleWithResolveDir          ← graph 에 dep 추가
  ├─ replayLinkResolvedDep
  │   ├─ requestDependencyExports     ← requested_exports.put (graph state)
  │   ├─ recordResolvedDep
  │   └─ linkDependency               ← dep edges 기록
  └─ ...
```

641 cache hit 모듈 × ~10 deps × ~20-40us = **누적 25.6ms (replay 의 96%)**.

### 1.2 replay 의 진짜 의미

replay 가 *모듈 단위 cache* 의 graph state 측 반영. 단:
- cache hit 모듈의 *결과* = 이전 빌드와 동일 (resolved_deps 동일, requested_exports 동일)
- 그러나 graph instance 가 매번 새로워 *복원* 필요
- 즉 **graph instance 가 persistent 면 replay 자체 skip 가능**

## 2. 제안 — Graph Instance Persistence

### 2.1 핵심 원칙

1. **`ModuleGraph` lifetime 을 `IncrementalBundler` 와 일치**
   - 매 `rebuild()` 호출이 graph 를 *재사용* (init 안 함)
   - 변경되지 않은 모듈의 state 그대로 보존
2. **변경 모듈만 invalidate**
   - `changed_files` set 의 모듈 → graph entry reset (modules.at(idx).reset)
   - 그 모듈의 *직접 ancestor* (의존하는 모듈) → import_records 재 resolve 필요 (entry 가 새 import 추가 가능)
   - *descendant* (의존되는 모듈) → 영향 없음 (이전 edges 그대로)
3. **replay 단계 short-circuit**
   - persistent graph 에서 cache hit 모듈은 *이미 graph state 가짐* → replay skip
   - 변경 모듈 + ancestor 만 replay

### 2.2 측정 목표

| Phase | 현재 (PR-A 후) | 목표 (PR-B) | 회수치 |
|---|---|---|---|
| graph | ~146ms | ~30ms | -116ms |
| WALL | 307ms | ~190ms | -117ms |
| esbuild 격차 | 6× | ~4× | 향상 |

### 2.3 변경 영역

**A) `ModuleGraph` API**
- `reset()` — 빌드 사이 state 부분 reset (diagnostics, owned strings, worker_entries 등). modules / path_to_module 는 유지.
- `invalidateModule(idx)` — 변경 모듈 1개 entry reset (parsed AST, semantic, resolved_deps). dependency edges 는 ancestor 가 재 resolve 시 갱신.
- `deinitState()` — graph 종료 시 module-local arenas 해제 (path_arena 등).

**B) `Bundler` API**
- `Bundler.initWithGraph(allocator, options, graph: *ModuleGraph)` — 신규
- `bundler.bundle()` 가 graph instance 를 *재사용 vs init* 분기

**C) `IncrementalBundler`**
- `persistent_graph: ?ModuleGraph` field 추가
- `doBuild` 가 graph instance 를 *유지* + `bundler` 에게 전달

**D) `buildIncremental` (build_flow.zig)**
- changed_files set 의 모듈만 `replayCachedResolvedDeps` 호출
- 그 외 cache hit 모듈은 이미 graph 에 state 있음 → skip
- 단 *graph_changed* (새 import / 모듈 추가) 감지 시 full rebuild fallback

**E) `replayCachedResolvedDeps`**
- short-circuit: `mod_ptr.state == .ready` + persistent graph 면 skip
- 변경 모듈의 *ancestor* 가 import_records 변경 시 *그 모듈만* re-replay

### 2.4 정확성 invariant

| invariant | 검증 방법 |
|---|---|
| 모듈 path 변경 (rename) | `path_to_module` HashMap 의 stale entry → full rebuild fallback |
| 모듈 삭제 | graph_changed detection → full rebuild |
| 모듈 추가 (새 import) | ancestor 의 import_records 변경 감지 → ancestor replay |
| 모듈 내용 변경 (mtime) | `invalidateModule(idx)` → 그 모듈만 reset + re-parse + replay |
| dependency 변경 (import 추가/제거) | invalidated 모듈의 새 resolved_deps 가 graph state 재기록 |

### 2.5 위험 영역

- **path_arena**: 모듈 path/resolve_dir 의 arena 가 graph deinit 시 일괄 해제. persistent 면 path 누적 → 메모리 monotonic growth. resolve_cache reset interval (#3751) 패턴 양도 필요.
- **requested_exports**: graph-level state. 변경 모듈의 ancestor 가 *그 모듈의 export 요청* 가지면 invalidate 필요. 정확한 추적 = complex.
- **worker_entries / inject_indices / runtime_polyfill_roots**: 빌드 간 누적 가능성. reset 정책 필요.

## 3. 단계별 PR 분할

**Sub-PR-B.1: ModuleGraph reset/invalidate API (S)**
- `ModuleGraph.reset()` + `invalidateModule(idx)` 신규 API 만 추가. 호출자 없음 (테스트 only).
- 단위 테스트로 정확성 검증.
- 측정 영향: 0. 다음 PR 의 prerequisite.

**Sub-PR-B.2: Bundler.initWithGraph API + persistence-off path 유지 (S)**
- `Bundler.initWithGraph(graph)` 추가. 기존 `bundler.bundle()` 가 graph init 분기 (received vs new).
- IncrementalBundler 가 graph 보유 + 매 `doBuild` 에서 received path 사용.
- 단 `persistent_graph` flag 가 false 면 기존 동작 (init/deinit 매번). default false 로 *opt-in*.
- 측정 영향: 0 (default off).

**Sub-PR-B.3: replay short-circuit + PoC 측정 (M)**
- `buildIncremental` 가 changed_files 활용해서 *unchanged 모듈의 replay skip*
- persistent_graph flag true 일 때만 적용
- ZNTC_INCREMENTAL_PERSIST=1 env 로 opt-in (kill-switch).
- lodash bench 측정 — graph 146ms → 목표 30ms 확인. ROI 검증.
- **여기서 GO/NO-GO 결정**. wash 면 RFC §6 의 closed RFC 처럼 종결.

**Sub-PR-B.4: graph_changed detection 강화 + 정확성 가드 (M)**
- import_records 변경 (새 import 추가/제거) 정확 감지
- 모듈 삭제 / 추가 정확 감지
- 회귀 fixture: lodash + 모듈 변경 (새 import 추가, import 제거, 모듈 삭제 등)

**Sub-PR-B.5: production opt-in + RN 가드 (M)**
- ZNTC_INCREMENTAL_PERSIST default true (production opt-in)
- RN-specific 회귀 가드 (`__zntc_register` wrapper, dev_codes 정확성)

## 4. PoC 계획

### Step 1 — ModuleGraph 의 reset/invalidate 의도 + scope 확정 (이번 세션)

- `src/bundler/graph.zig` 의 fields 정밀 분석 — 어떤 state 가 module-local vs graph-global
- `reset` / `invalidateModule` API 의 정확한 의미 정의

### Step 2 — Sub-PR-B.1 (next session)

- API 추가 + 단위 테스트
- 작은 PR (S)

### Step 3 — Sub-PR-B.2 (next session)

- `Bundler.initWithGraph` + opt-in path
- 측정 영향 0 검증

### Step 4 — Sub-PR-B.3 (PoC GO/NO-GO)

- replay short-circuit 구현
- ZNTC_INCREMENTAL_PERSIST=1 로 lodash 측정
- **성공 기준**: graph 146→30ms 이내, 정확성 회귀 0
- **실패 기준**: graph 변동 < 50ms 절약, 또는 정확성 회귀 발생 → RFC NO-GO, closed 문서로 종결 (RFC §3 MANGLER_SIZE_GAP_CLOSED 패턴 양도)

## 5. 회귀 가드

- `tests/benchmark/devserver-hmr.ts` — dev_server WS HMR latency (bench follow-up PR)
- 내장 `incremental_bench_v4` (`zig build test`) — replay sub-phases timing
- 새 fixture: 모듈 추가/제거/import 변경 정확성 검증

## 6. RN 영향

| 영역 | RN 영향 | 비고 |
|---|---|---|
| Sub-PR-B.1/B.2 (API 추가) | 0 | opt-in 미사용 |
| Sub-PR-B.3 (replay skip) | **잠재 — 정확성 risk** | RN HMR 도 IncrementalBundler 사용? NAPI 는 직접 Bundler.initWithResolveCache 호출 (별개 path). 즉 RN HMR 의 ModuleGraph 도 매번 new instance. RN 도 잠재 수혜자 — 단 RN 만의 emit 단계 (`rn_codegen_plugin`, `__zntc_register` wrapper, asset registry) 가 persistent graph 와 호환 필수 |
| Sub-PR-B.4 (정확성) | 가드 필수 | RN 의 모듈 동적 추가 / Hermes precompile 흐름 영향 |

RN HMR 의 path 검증 후 RN 회귀 가드 추가 — 측정 필요.

## 7. 결정 / 정책

- **PoC GO/NO-GO 기준**: Sub-PR-B.3 의 lodash 측정에서 graph 146→ ≤80ms (~45% 절약).
- **GO 시**: Sub-PR-B.4/B.5 진행. production opt-in 으로 default true 전환.
- **NO-GO 시**: 본 RFC 를 RFC_GRAPH_PERSISTENCE_CLOSED.md 로 변경. 측정 데이터 박제. `replay` 영역의 *부분 최적화* (예: requested_exports 자료구조 HashSet 화) 만 진행.
- `src/bundler/bundler.zig:1073` 의 `ModuleGraph.init(self.allocator, ...)` 매번 새 instance 가 모든 추후 incremental 최적화의 *상한*. 본 RFC 가 그 상한 자체를 깨려는 시도.

PoC 단일 큰 PR 시도 금지 — Sub-PR-B.1~B.3 까지가 *측정 전제 조건*. B.3 의 GO/NO-GO 후 본격 또는 종결.
