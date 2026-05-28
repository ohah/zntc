# RFC: Lifecycle Scope Redesign — Cross-Build Memory Ownership 명확화 (esbuild SymbolID 패턴)

상태: **DRAFT · mid-term architectural epic** · 분류: dev UX / core 재설계
선행: [RFC_GRAPH_PERSISTENCE](./RFC_GRAPH_PERSISTENCE.md) CLOSED, [RFC_EMIT_INCREMENTAL](./RFC_EMIT_INCREMENTAL.md) CLOSED
관련: [RFC_EMIT_INCREMENTAL_DEV_SERVER](./RFC_EMIT_INCREMENTAL_DEV_SERVER.md), `src/bundler/{bundler,linker,graph,emitter,compiled_cache}.zig`, `packages/core/src/napi/watch.zig`
예상 작업량: **1-2 quarter**

## 1. 배경

RFC #3933 (graph persistence) + RFC #3939 (emit incremental) 두 epic 이 모두 measurement-first NO-GO 로 종결됐다. 그러나 **root cause 는 같은 architecture lock** — *cross-build memory ownership 의 implicit invariant*.

### 1.1 RFC #3933 NO-GO 의 진짜 root

Sub-PR-B.3 의 PoC segfault:
```
persistent_graph + selective invalidate
→ lodash dev_server first incremental rebuild
→ Linker.assignSymbolCanonical
  → HashMap StringContext.hash → stale string ptr access
```

`Linker` 가 alloc 한 `canonical_name` 문자열을 `Module.semantic.symbols` 의 slice 가 reference. `Linker.deinit` 시 메모리 freed. 다음 빌드의 새 `Linker` 가 graph 의 *stale slice* 접근 → segfault.

### 1.2 RFC #3939 NO-GO 의 진짜 root

emit 영역 작은 fix (Phase 1.5 parallel / CSS short-circuit / dev_codes module cache) 모두 noise. 진짜 fix (variation) 영역 = *모듈 단위 cache 의 ownership* — 같은 ownership 영역.

### 1.3 ZNTC architecture 의 *implicit invariant*

| 메모리 영역 | 현재 owner | 사용 사이트 | cross-build dangling 위험 |
|---|---|---|---|
| `Module.path` | `ModuleGraph.path_arena` | linker / emitter / dev_server | 안전 (graph 수명) |
| `Module.source` | `Module.parse_arena` | linker / emitter | 안전 (build 수명) |
| `Module.ast` | `Module.parse_arena` | linker / emitter | 안전 (build 수명) |
| **`Module.semantic.symbols[i].canonical_name`** | **`Linker`** (build-scope) | `compiled_cache` / `emitter` | **위험 — Linker.deinit 후 dangling** |
| `Module.alias_table` | `Module.parse_arena` | linker / mangler | 위험 — parse_arena ownership 양도 시 stale |
| `Module.export_index_by_name` | `parse_arena` HashMap backing | linker | 위험 |
| `Module.namespace_access_index` | `parse_arena` 안 HashMap | linker / emitter | 위험 |
| `compiled_cache.Entry.compiled.code` | cache allocator | emitter (`hit.dupe`) | 안전 (hit 마다 dupe) |
| `compiled_cache.Entry.compiled.helpers` | cache allocator | 위와 동일 | 안전 |

핵심 문제: **`Linker` 가 build-scope (매 빌드 init/deinit) 인데 graph 의 cross-build state (`Module.semantic.symbols[].canonical_name`) 에 alloc 한 메모리를 write**. graph 가 persistent 면 다음 빌드의 새 Linker 가 stale slice 접근.

### 1.4 ZNTC vs esbuild 의 ownership 차이

| 차원 | ZNTC | esbuild |
|---|---|---|
| symbol identity | path + string slice | `SymbolID = (sourceIndex, innerIndex)` integer |
| canonical_name 저장 | semantic.symbols[].canonical_name (string) | `Symbol.OriginalName` (immutable) + per-build rename table (int → string) |
| cross-build sharing | 모듈 단위 cache (path → CompiledModule) | source array (sourceIndex) 가 process-lifetime |
| dangling 위험 | implicit, runtime segfault 만 발견 | 컴파일러가 막음 (integer 만 cross-build) |

esbuild 는 *symbol identity 자체가 integer* 라 메모리 lifetime 문제가 *원천적으로* 없음. ZNTC 는 *string slice ownership* 을 implicit 으로 관리 — segfault 가 발견 수단.

## 2. 제안 — 3-Scope 메모리 영역 명확 분리

### 2.1 Scope 정의

| Scope | 수명 | 예 |
|---|---|---|
| **build-scope** | 단일 `bundler.bundle()` 호출 | Linker / Parser / 임시 ArrayList / temp arena |
| **graph-scope** | `IncrementalBundler` lifetime (watch 세션 전체) | `Module` 의 path / semantic.symbols (canonical_name 제외) |
| **cache-scope** | 모듈 변경 시 invalidate | compiled_cache.Entry / dev_codes / sourcemap |

### 2.2 invariant

1. **build-scope 메모리는 graph-scope/cache-scope 에 reference 못 함** (write 금지)
2. **graph-scope 메모리는 cache-scope 의 owner 만이 invalidate 가능**
3. **cache-scope 메모리는 module path + input_hash 로 lookup 만**
4. **cross-scope reference 는 *integer ID* 만** (esbuild SymbolID 패턴)

### 2.3 esbuild SymbolID 패턴 양도

```zig
// AFTER (제안):
pub const SymbolID = packed struct {
    source_index: u32,  // graph-scope (Module 의 idx)
    inner_index: u32,   // module-local symbol idx
};

pub const Symbol = struct {
    original_name: []const u8,  // module.parse_arena 소유 (build/graph 둘 다 안전)
    kind: SymbolKind,
    // canonical_name 제거 — 별도 per-build rename table 로 이관
};

// per-build (build-scope):
pub const RenameTable = struct {
    // SymbolID → final name (per-build, no cross-build sharing)
    map: std.AutoHashMap(SymbolID, []const u8),
    // 메모리: build-scope, build 종료 시 일괄 free
};

// Linker 가 RenameTable 작성 → emitter 가 SymbolID 로 lookup → emit
// 다음 빌드의 새 Linker 가 새 RenameTable 작성 — *graph 안 건드림*
```

핵심: `Symbol` struct 에서 `canonical_name: []const u8` field **제거**. `SymbolID → name` 매핑을 *build-scope 의 RenameTable* 로 이관. graph 의 Symbol 은 *immutable identity* 만.

## 3. 측정 목표

dev_server lodash HMR latency:
- 현재 (PR-A 후): 307ms
- 본 RFC 후 목표: **~50ms (esbuild parity)**

phase 분포 변화 추정 (Debug profile 기준):
| Phase | 현재 | 목표 | 회수치 |
|---|---|---|---|
| graph | 146ms | 30ms | -116ms (persistent + selective replay 가능) |
| link | 61ms | 20ms | -41ms (RenameTable per-build, graph 안 안 건드림) |
| emit (incl. concat) | 80ms (Release) | 20ms | -60ms (chunk-level cache 작동 가능) |

총 ~217ms 절약 → wall ~90ms (release). esbuild 50ms 와 1.8× 거리 — 추가 parallel/architectural fix 후 도달.

## 4. 단계별 PR 분할 (큰 epic, 9-12 sub-PR 예상)

### Phase 1 — 분석 + 측정 도구 (1-2주)

**Sub-PR-L.0**: `RFC_RELEASE_PROFILING_HARNESS` (별도 작은 RFC)
- Debug profile + Release wall 측정 통합 도구
- emit 영역 작은 fix 의 ROI 정확 측정 가능
- 본 RFC 의 prerequisite — 측정 noise floor 분리

**Sub-PR-L.1**: cross-build memory ownership 정밀 audit
- `src/bundler/{linker,emitter,graph,semantic}.zig` 전체 walk
- 각 alloc 사이트의 scope (build/graph/cache) 표시
- audit 문서로 follow-up PR 들의 scope 결정

### Phase 2 — SymbolID 패턴 도입 (3-4주)

**Sub-PR-L.2**: `SymbolID` struct 신규 + 점진적 migration
- `Symbol` struct 에 `id: SymbolID` field 추가 (기존 field 보존)
- 모든 `Symbol` reference 가 *옵션으로* SymbolID 사용 가능
- 영향 0 (사용자 없음)

**Sub-PR-L.3**: `RenameTable` 신규 + Linker 가 alloc
- `RenameTable: SymbolID → []const u8` map (build-scope)
- `Linker.computeRenames` 가 RenameTable 작성
- 기존 `Symbol.canonical_name` 도 *동시* 작성 (병행)

**Sub-PR-L.4**: emitter 가 RenameTable lookup 으로 전환
- `emitter` 의 `canonical_name` 접근 → `rename_table.get(symbol.id)` 로 변경
- 결과물 동일 (regression test 통과)

**Sub-PR-L.5**: `Symbol.canonical_name` field 제거 (**big bang**)
- graph 의 Symbol 이 immutable identity 만
- `Linker.deinit` 후 graph 의 stale slice 위험 0
- **회귀 가드**: 모든 corpus + bench

### Phase 3 — Graph Persistence 재도입 (2-3주)

**Sub-PR-L.6**: persistent ModuleGraph (RFC #3933 의 PoC 재시도)
- `Symbol.canonical_name` 이 제거된 후 graph persistence 가 *안전*
- B.3 의 segfault 가 architecturally 차단됨
- selective invalidate + replay short-circuit 정상 작동

**Sub-PR-L.7**: lodash 측정 GO/NO-GO
- 목표: graph 146→≤80ms (RFC #3933 의 원안 기준)
- ✅ GO: PR-L.8 진행
- ❌ NO-GO: 추가 ownership 영역 fix 필요 (parse_arena ownership 등) — 다른 sub-PR 시리즈

### Phase 4 — Emit Incremental 재도입 (1-2주)

**Sub-PR-L.8**: chunk-level emit cache (RFC #3939 의 영역 재시도)
- ChunkEmitCache (#3938) wire-up
- module-level dev_codes cache (RFC #3939 의 PoC C-3 재시도)
- *graph 가 persistent* 라 chunk hit rate 가 의미 있음

**Sub-PR-L.9**: lodash 측정 GO/NO-GO
- 목표: emit 80→≤20ms
- ✅ GO: production 전환
- ❌ NO-GO: chunk membership 안정성 추가 fix

### Phase 5 — Production Opt-in + RN 가드 (1-2주)

**Sub-PR-L.10**: production opt-in
- `ZNTC_LIFECYCLE_SCOPE_V2=1` default true
- 기존 v1 path 는 kill-switch 로 유지 (3 개월)

**Sub-PR-L.11**: RN bare/large/expo 회귀 가드
- RN HMR (NAPI watch path) 정확성 검증
- `__zntc_register` wrapper 형식 유지
- Hermes precompile 호환성

**Sub-PR-L.12**: v1 path 제거
- kill-switch 3 개월 후 v1 코드 제거
- 코드 cleanup

## 5. PoC 계획

### Step 1 — 측정 도구 (Sub-PR-L.0)

`RFC_RELEASE_PROFILING_HARNESS` 작성 + 측정 도구 prerequisite. Release 측정의 noise floor 분리 가능해야 본 RFC 의 각 PR 의 ROI 정확 측정.

### Step 2 — Audit (Sub-PR-L.1)

cross-build memory ownership 의 *모든 dangling 후보* 식별. Sub-PR-L.5 의 big-bang 전 *완전한 list* 필요.

### Step 3 — SymbolID PoC (Sub-PR-L.2/L.3/L.4)

병행 path — Symbol.canonical_name 과 RenameTable 둘 다 작성. 두 결과 비교 (assertion) 로 정확성 검증.

### Step 4 — Big Bang (Sub-PR-L.5)

`Symbol.canonical_name` 제거. 모든 corpus + bench 회귀 검증. 큰 risk PR.

### Step 5 — Graph Persistence Re-enable (Sub-PR-L.6/L.7)

RFC #3933 의 PoC 재시도. Big Bang 후 *segfault 가 architecturally 차단됨* — 정상 작동 expectation.

### Step 6 — Emit Incremental Re-enable (Sub-PR-L.8/L.9)

RFC #3939 의 영역 재시도. graph persistent + module cache → ChunkEmitCache hit 의미 있음.

## 6. 회귀 가드

### bench 가드

- `tests/benchmark/devserver-hmr.ts` — dev_server WS HMR latency
- `tests/benchmark/napi-watch.ts` — NAPI watch incremental
- `tests/benchmark/inprocess-rebuild.ts` — esbuild / rolldown 공정 비교
- 신규: `tests/benchmark/rn-hmr-cycle.ts` — RN bare/large/expo HMR latency
- 신규: `tests/benchmark/lifecycle-scope-corpus.ts` — corpus-wide 정확성 + size 회귀

### 정확성 가드

- 모든 corpus build 결과 byte-identical (v1 vs v2)
- HMR client 의 dev_codes wire form 동일
- RN bundle 의 `__zntc_register` wrapper 형식 유지
- sourcemap 정확성

### kill-switch

`ZNTC_LIFECYCLE_SCOPE_V2=0` 로 v1 path 강제 복귀. 3 개월 유지 후 제거.

## 7. React Native 영향

| Phase | RN 영향 | 비고 |
|---|---|---|
| Phase 1 (audit/측정) | 0 | 문서 + 측정 도구만 |
| Phase 2 (SymbolID) | 잠재 | Symbol struct 변경 → 모든 platform 영향. 병행 path 라 v1 검증 가능 |
| **Phase 2 Big Bang (L.5)** | **잠재 risk** | 모든 platform 의 mangle/emit 결과 byte 검증 필수. RN bundle 의 wrapper 형식 정확성 |
| Phase 3 (graph persistence) | 잠재 | RN HMR 의 NAPI watch path 가 IncrementalBundler 사용? 확인 필요. 사용 시 graph persistence 자동 적용 |
| Phase 4 (emit incremental) | 잠재 | RN-specific emit 분기 (rn_codegen_plugin, asset_registry) 의 ChunkEmitCache 호환성 |
| Phase 5 (production) | 가드 필수 | RN bare/large/expo 3종 회귀 + Hermes precompile |

## 8. GO/NO-GO 결정 포인트

- **L.5 (Symbol.canonical_name 제거)**: 모든 corpus byte-identical + size 회귀 0
- **L.7 (graph persistence 재시도)**: lodash graph 146→≤80ms + 정확성 회귀 0
- **L.9 (emit incremental 재시도)**: lodash emit 80→≤20ms + 정확성 회귀 0
- **L.10 (production opt-in)**: 모든 corpus + RN 3종 회귀 0

각 GO/NO-GO 에서 NO-GO 시 *해당 phase 만* closed. 다른 phase 의 자산은 보존.

## 9. 영역별 영향 정리

| 영역 | 영향 |
|---|---|
| `src/bundler/symbol.zig` | Symbol struct big-bang 변경 (Phase 2) |
| `src/bundler/linker.zig` | RenameTable 도입, canonical_name 의존 제거 |
| `src/bundler/emitter.zig` | RenameTable lookup 으로 전환 |
| `src/bundler/graph.zig` | persistent lifecycle 추가 (Phase 3) |
| `src/bundler/compiled_cache.zig` | cache-scope ownership 명확화 |
| `src/bundler/incremental.zig` | persistent graph + chunk cache wire-up |
| `src/server/dev_server.zig` | scope v2 path 활용 |
| `packages/core/src/napi/watch.zig` | 동일 |
| 모든 test | corpus regression suite 강화 |

## 10. 정책 / 결정

### Out of scope

- **mangler size gap** — `RFC_MANGLER_SIZE_GAP_CLOSED` 영역. 본 RFC 와 무관 (다른 root).
- **Plugin AST mutation** — plugin 의 AST 변경 영역. 본 RFC 의 ownership 정리와 별개.
- **disk persistent cache** — process 간 cache. 본 RFC 는 in-memory only.

### 진짜 의의

ZNTC dev UX 가 esbuild parity 도달하는 *유일한 path*. RFC #3933 / #3939 의 NO-GO 가 *architectural lock* 임을 확정.

본 RFC 는 *측정으로 결론짓기에 너무 큼* — Sub-PR-L.0 (측정 도구) + L.1 (audit) 후에 *전체 epic 의 ROI 선검증* 가능. 그때 final GO/NO-GO.

### 예상 결과

- 성공 시: ZNTC dev_server HMR ~50ms (esbuild parity), RN HMR 도 같은 수준
- 부분 성공 시: 일부 phase 만 GO, 다른 phase 는 closed (자산은 보존)
- 실패 시: RFC_LIFECYCLE_SCOPE_REDESIGN_CLOSED.md 로 종결, dev UX 의 architectural lock 영구 확정 + PR-A 의 -23% 가 ZNTC dev_server 의 *영구 한계*. 그 경우 marketing 으로 "incremental 우위 영역 없음, treeshake/multi-platform 차별화" 정정.

### 비교: mid-term roadmap 영역

| RFC | 작업량 | 영향 |
|---|---|---|
| 본 RFC (lifecycle redesign) | 1-2 quarter | dev UX 결정적 — esbuild parity |
| Module Federation epic (#3318) | 1 quarter | 차별화 카드 — MF + RN |
| AST plugins (현재 baseline) | 1-2 quarter | ecosystem |

본 RFC 와 MF epic 이 ZNTC mid-term 의 두 큰 epic. 우선순위 = *사용자 가치* 평가.
