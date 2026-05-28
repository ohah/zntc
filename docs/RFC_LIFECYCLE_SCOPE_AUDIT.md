# RFC #3940 Sub-PR-L.1 — Cross-Build Memory Ownership Audit

상태: **COMPLETE · Phase 1 산출물** · 분류: dev UX / core 재설계
상위: [RFC_LIFECYCLE_SCOPE_REDESIGN](./RFC_LIFECYCLE_SCOPE_REDESIGN.md) (Phase 1, Sub-PR-L.1)
선행: [RFC_RELEASE_PROFILING_HARNESS](./RFC_RELEASE_PROFILING_HARNESS.md) (Sub-PR-L.0, 완료)
대상: `src/bundler/{linker,emitter,graph,module,compiled_cache,...}.zig`, `src/semantic/symbol.zig`, `src/codegen/`

## 1. 목적

RFC #3940 Phase 2 의 big-bang (`Sub-PR-L.5`: `Symbol.canonical_name` field 제거) 은
*cross-build dangling 후보의 완전한 목록* 없이는 안전하게 착수할 수 없다. 누락된 후보가
하나라도 있으면 graph persistence 도입(Phase 3) 직후 runtime segfault 로 발견된다 —
정확히 RFC #3933 Sub-PR-B.3 PoC 가 겪은 시나리오.

본 audit 은 `Linker`/`emitter`/`graph`/`semantic`/`cache` 5개 영역의 alloc·write·read
사이트를 전수 walk 하여 (1) 각 메모리의 owner scope (build / graph / cache), (2) build-scope
메모리를 graph-scope 가 reference 하는 *모든* dangling 후보, (3) SymbolID + RenameTable
패턴 이관의 readiness 와 설계 보정점을 확정한다.

## 2. 방법론

5개 영역을 독립적으로 정밀 walk:

| 영역 | 대상 파일 | 관점 |
|---|---|---|
| Symbol 정의 | `src/semantic/symbol.zig`, `src/bundler/symbol.zig`, `src/bundler/module.zig` | struct field 의 owner / dangling 후보 |
| Linker (write) | `src/bundler/linker.zig`, `linker/metadata*.zig` | canonical_name *write* sink + lifetime |
| Emitter (read) | `src/bundler/emitter.zig`, `emitter/{esm_wrap,chunks}.zig`, `src/codegen/` | canonical_name *read* + RenameTable readiness |
| Graph/Module | `src/bundler/graph.zig`, `graph/{build_flow,transform_prepass}.zig`, `module_store.zig` | parse_arena ownership + ModuleIndex 안정성 |
| Cache | `src/bundler/{compiled_cache,compiled_module,chunk_emit_cache,incremental}.zig` | cache-scope 청정성 + invalidate |

## 3. 3-Scope 분류 결과

RFC #3940 §2.1 의 3-scope 가 실제 코드와 어떻게 대응하는지:

| Scope | 수명 | 실제 구현 | 소유 메모리 |
|---|---|---|---|
| **build-scope** | 단일 `bundler.bundle()` | `Linker` (arena 없음, `self.allocator` 직접), `TreeShaker`, temp arena | `canonical_strings`, `unified_result`, `export_map`, `ns_*_cache`, TreeShaker bitsets |
| **graph-scope** | `IncrementalBundler` lifetime | `ModuleGraph` 인스턴스(매 build 새로) + `PersistentModuleStore`(재사용) | `path_arena`, `modules`, `path_to_module`, 각 `Module.parse_arena` 와 그 안 전부 |
| **cache-scope** | 모듈 변경 시 invalidate | `CompiledOutputCache`, `ChunkEmitCache`(skeleton) | `Entry.compiled.{code,helpers,mappings,names,...}` — 전부 deep-dupe |

**핵심 모델 차이**: 현재 ZNTC 는 *graph 인스턴스는 비-persistent, Module(parse_arena)만
persistent* 다. `PersistentModuleStore` (`module_store.zig:45`) 가 `path → CachedModule`
맵으로 parse_arena 소유권을 build 간 보존하고, `ModuleGraph` 인스턴스 자체는 매 build 새로
만들어진다 (`build_flow.zig:886` `transferModulesToStore` 가 graph.deinit 직전 양도,
`build_flow.zig:718` `buildIncremental` 이 mtime 매칭 시 환원). RFC #3940 Phase 3 의
"graph persistent" 는 이 store 패턴을 graph 인스턴스 자체로 끌어올리는 작업이다.

## 4. Cross-Build Dangling 후보 — 완전 목록 (핵심 산출물)

graph-scope 메모리가 build-scope 메모리를 reference 하는 후보. **big-bang(L.5) 전 이 목록이
완전해야 한다.** 총 **4종 확정 + ModuleIndex 의미 불안정 1건**:

| # | 후보 | 정의 | owner (build-scope) | write 사이트 | 현재 cache-hit reset | 비고 |
|---|---|---|---|---|---|---|
| 1 | `Symbol.canonical_name` | `src/semantic/symbol.zig:295` (`[]const u8`) | `Linker.canonical_strings` (`linker.zig:165`) | `assignSymbolCanonical` (`linker.zig:1269`) — 단일 sink | ✅ `build_flow.zig:775` `= ""` | RFC #3933 segfault 의 확정 root |
| 2 | `Alias.canonical_name` | `src/bundler/symbol.zig:90` (`[]const u8`) | `Linker` (`AliasTable.setCanonicalName` 호출처 `linker.zig:1759`) | `populateReExportAliases` (`linker.zig:1737`) | ❌ **reset 안 됨** | 은닉된 2번째 vector. `setCanonicalName` 은 `AliasTable` 메서드. `clearCanonicalNames` 가 alias 는 안 비움 → re-emit 시 stale 잔존 가능 |
| 3 | `Module.reachable_stmts` | `src/bundler/module.zig:365` (`?*const DynamicBitSet`) | `TreeShaker.reachable_stmts` (borrowed mirror) | tree_shake 단계 mirror set | ❌ **reset 안 됨** | **audit 신규 발견.** 주석(`module.zig:360-362`)이 "tree_shaker.deinit 후 dangling" 명시. store 환원 시 stale ptr |
| 4 | `Module.symbol_to_stmt` | `src/bundler/module.zig:368` (`?[]const ?u32`) | `TreeShaker` (borrowed mirror, #3 과 짝) | 동상 | ❌ **reset 안 됨** | **audit 신규 발견.** #3 과 항상 동반 (둘 다 null 또는 둘 다 set) |
| — | `ModuleIndex` 의미 | `src/bundler/module.zig:170` (`enum(u32)`) | (값 type, dangling 아님) | `graph/renumber.zig:90` BFS 재배정 | — | **cross-build 의미 불안정.** 모듈 추가/삭제 시 동일 모듈이 다른 index. SymbolID 의 source_index 로 직접 사용 불가 |

### 4.1 검증된 안전 항목 (dangling 아님)

다음은 build-scope reference 처럼 보이나 실제로 graph-scope arena 소유라 **안전**하게 재확인:

- `Symbol.synthetic_name` — `parse_arena` (extendSymbol), graph 수명 일치
- `Symbol.name` (`Span`) — source byte offset, dangling 불가
- `Module.namespace_access_index` / `transform_cache.*` — `parse_arena` backing
- `Module.export_index_by_name` / `import_bindings` / `export_bindings` — `graph.allocator`, 값은 u32/SymbolRef(값 type)
- `compiled_cache.Entry.*` — 전부 cache allocator deep-dupe (§8)

### 4.2 cache-hit reset 누락이 의미하는 것

후보 #1 (`Symbol.canonical_name`) 은 `build_flow.zig:775` 가 store 환원 모듈에 대해 `= ""` 로
명시 reset 하므로, 다음 build 의 새 `Linker` 가 재계산하기 전까지 stale slice 가 비워진다.
그러나 **#2/#3/#4 는 동일 reset 경로에 포함돼 있지 않다.** 현재 v1 에서는 graph 인스턴스가 매
build 새로 만들어지고 tree_shaker 가 매 build mirror 를 다시 set 하므로 *대체로* 가려지지만,
graph persistence (Phase 3) 도입 시 이 reset 누락이 그대로 노출된다. → **L.5 big-bang scope 에
#2/#3/#4 의 reset(또는 외부화)을 명시 포함해야 한다.**

## 5. SymbolID 도입 Readiness + 설계 보정

### 5.1 Raw material — 존재

- `source_index` 후보: `Module.index: ModuleIndex` (`module.zig:170`, `enum(u32)`)
- `inner_index` 후보: `SymbolId = enum(u32)` (`semantic/symbol.zig:18`) — `symbols[]` 배열 위치.
  `extendSymbol` 이 `@intCast(list.items.len)` 으로 발급 (`symbol.zig:338`)
- **이미 사실상 SymbolID 가 존재**: `SymbolRef.semantic = { module: ModuleIndex, symbol: SemanticSymbolId }`
  (`bundler/symbol.zig:32-36`) 가 정확히 `(source_index, inner_index)` integer pair. `makeSemantic`
  헬퍼(`symbol.zig:41`)도 있다. cross-module 참조는 *이미* 이 integer 식별을 쓴다.

### 5.2 ★ 설계 보정 — ModuleIndex 는 SymbolID 의 안정 키로 부적합

RFC #3940 §2.3 의 `SymbolID { source_index: u32, inner_index: u32 }` 는 `source_index` 가
*cross-build 안정* 임을 암묵 가정한다. 그러나 audit 결과 **`ModuleIndex` 는 build-local**:

- `addModule` (`module_registry.zig:91`) 이 발견 순서로 배정 (worker race 로 비결정)
- `finalizeGraph` → `graph/renumber.zig:23 renumberModulesDeterministically` 가 BFS 순서로 전 모듈
  index 재부여 (`graph/renumber.zig:90`). **같은 그래프 위상이면 결정적이나, 모듈 추가/삭제 시 BFS 순서가
  밀려 동일 모듈이 다른 index 를 받는다.**

따라서 SymbolID 의 안정 키는 **`Module.path`** (= `path_arena` 소유, cross-build 안정, renumber
struct copy 에도 불변) 위에 세워야 한다. 두 가지 설계 옵션:

- **(A)** SymbolID 를 `(stable_module_id, inner_index)` 로 정의하고 `stable_module_id` 를
  path 기반 안정 id 로 발급 (별도 stable-id 테이블)
- **(B)** RenameTable 을 `path → AutoHashMap(inner_index → name)` 2단 맵으로 구성 (ModuleIndex 미사용)

per-build RenameTable 은 build-scope 라 *그 build 내에서만* 유효하면 충분하므로, build 내내
ModuleIndex 가 안정(renumber 이후 고정)하다면 **(B) 의 RenameTable 키로 build-local ModuleIndex 를
써도 무방**하다. 다만 graph persistence(Phase 3) 에서 *cross-build 로 살아남는 식별자*(예: persistent
graph 의 symbol identity)에는 path-stable id 가 필수다. → **L.2 에서 SymbolID 를 정의할 때 "build-local
ModuleIndex 키 (RenameTable 용)" 와 "cross-build path-stable id (graph용)" 를 구분해 설계할 것.**

### 5.3 canonical_name 은 build 마다 재계산이 정책

`transform_prepass.zig:220 preserveCanonicalNamesAfterSemanticResync` 의 carry-over 는 *같은
build 내* prepass→emit resync 한정이고, **rebuild 간 carry-over 가 아니다.** rebuild cache-hit
경로(`build_flow.zig:775`)는 오히려 `= ""` 로 비운다. 즉 canonical_name 은 build 마다 재계산이
정책이며 graph persistent 가 돼도 보존이 불필요하다 (오히려 비워야 안전). → **SymbolID 이관에 유리**:
graph 의 Symbol 은 immutable identity 만 들고, rename 은 build-scope RenameTable 이 매번 새로
계산하면 된다.

## 6. Emitter — RenameTable Readiness (95% 이미 존재)

**핵심 발견: emitter 의 hot path 는 `Symbol.canonical_name` 을 직접 읽지 않는다.** 모든 식별자
rename emit 은 `LinkingMetadata.renames: AutoHashMap(u32 symbol_id → []const u8)`
(`linker/metadata_types.zig:14`) 를 경유한다. 이 맵은 **이미 SymbolID-keyed** 이고 값 문자열은
`putOwnedRename` (`metadata.zig:257`) 이 dupe + owned 추적하여 metadata 가 소유한다.
`Symbol.canonical_name` 은 metadata *빌드 시점*(linker scope)에만 1회 읽혀 dupe 되고, emit
시점에는 참조되지 않는다.

### 6.1 emit 시점에 `Symbol.canonical_name`(또는 linker live)을 직접 읽는 site — 3곳뿐

| read 사이트 | 맥락 | 식별 방식 | L.4 전환 난이도 |
|---|---|---|---|
| `codegen/codegen.zig:323`, `emitter.zig:2127`, `codegen/expressions.zig:318` | identifier rename 출력 (hot path) | `md.renames.get(symbol_id)` | **이미 완료** (SymbolID 모델) |
| `emitter/chunks.zig:825,831` | cross-chunk `export { local as name }` | `l.getCanonicalName(module_index, name_string)` | **중간** — name-string 키 → SymbolID 역인덱스 필요 |
| `emitter/esm_wrap.zig:671,800` | `__esm` live-binding getter | `l.getCanonicalName(module_index, local_name)` | **중간** — fallback 경로, 영향 작음 |
| `module.zig:469` (`syntheticName`), `codegen/mangler.zig:596` | synthetic 출력명 / nested reserve | `symbols[idx]` 인덱스 접근 | **쉬움** — `rename_table.get(id)` 1:1 치환 |

emitter 가 `Symbol.canonical_name` 에 **write** 하거나 graph 메모리를 mutate 하는 site 는 **0건** —
순수 reader (읽기 전용 불변식 만족).

### 6.2 의의

L.4 (`emitter 가 RenameTable lookup 으로 전환`) 작업은 emitter 의 95% 에 대해 *이미 구조적으로
존재*한다 (`metadata.renames` 가 사실상 그 RenameTable). 남은 작업은 위 표의 chunks/esm_wrap 3개
직접 `l.getCanonicalName` 호출을 metadata 경유(또는 SymbolID-keyed RenameTable)로 흡수하는 것뿐.
이 3곳을 흡수하면 *emit 시점 linker-live 의존*이 사라져 `incremental_test.zig:633` 이 가리키는
"conflict 사라진 cache-hit 모듈의 canonical_name UAF" 축이 구조적으로 해소된다.

## 7. Linker — Write Sink + 이관 후보

- **lifetime**: `Linker.init`/`initWithGlobalIdentifiers` (`linker.zig:340/344`), arena **없음** —
  외부 `allocator` 직접 보관. `deinit` (`linker.zig:384`) 가 `canonical_strings.items` 전부 free.
  메인 경로 `bundler.zig:1297` 매 `bundle()` 마다 init + `defer deinit` → **build-scope 확정.**
- **단일 sink**: 모든 canonical write 가 `assignSymbolCanonical` (`linker.zig:1269` `sym.canonical_name = value`)
  로 수렴. **RenameTable.set(SymbolID, name) 의 직접 대체점.**
- **RenameTable 이관 후보 함수** (현재 canonical_name 에 직접 쓰는 함수 = `computeRenames` 로 이관):
  1. `assignSymbolCanonical` (`linker.zig:1263`) — 단일 sink
  2. `computeMangling` (`linker.zig:1170`) — Phase A mangle 결과 주입 (최대 writer)
  3. `calculateRenames` (`linker.zig:677`) + `computeRenames` (`linker.zig:748`) — collision rename
  4. `resolveNestedShadowConflicts` (`linker.zig:783`) — nested shadow rename
  5. `populateReExportAliases` (`linker.zig:1737`) — `AliasTable.canonical_name` writer (후보 #2)
- reset 함수 `clearCanonicalNames` (`linker.zig:2229`) / `clearMangling` (`linker.zig:2240`) 는
  RenameTable 의 per-build 폐기로 자연 대체됨.

## 8. Cache-scope — 청정성 확인

**현재 `compiled_cache` 는 graph-scope/build-scope 메모리를 reference 하지 않는다.** `put` 이 결과
전체를 deep-dupe (`compiled_cache.zig:390` `compiled.dupe(self.allocator)`), `tryHit` 도
`hit.dupe(allocator)` (`emitter.zig:613`) 로 build-scope 에 재복사한다. cache entry 의 모든 slice 는
cache allocator 소유 immutable string (rename 이 baked 된 emit 산출물) — `canonical_name`/`Symbol`/
`Module` ptr 를 잡는 site 없음. (§6 emitter 결론과 일치.)

- **key** = absolute path (`m.path`), 매칭 = path + `input_hash` 둘 다.
- **input_hash** (`computeInputHash`, `compiled_cache.zig:273`): `mtime` + `source`(transform 후) +
  `options_hash` + `used_export_names` + `import_records`(resolved 를 ModuleIndex 가 아닌 **path** 로
  hash — cross-build 안정). `intentionally_unhashed_fields = {"skip_bundle_output"}` (`compiled_cache.zig:104`)
  확인 — 이전 dev_server cache-miss 회귀의 root 였던 항목.
- **ChunkEmitCache** (`chunk_emit_cache.zig`, #3938): **skeleton, production 호출자 0건.** 본체 +
  단위테스트 14개는 완성됐으나 dead path (Phase 4 wire-up 대기). cache 대상 = chunk concat byte stream,
  key = `{chunk_id, modules_hash}` (각 모듈 path+input_hash 결합).
- **invalidate**: selective entry invalidate(`compiled_cache.invalidate(path)`, 정의는 됨)는 production
  미사용. graph 구조 변경 시 `doBuild` (`incremental.zig:289`) 가 **전체 `clear()`**.

### 8.1 graph persistence 후 cache 위험

1. **graph_changed 전체 clear 의존** (`incremental.zig:289`) — graph 가 persistent 해지면 "path set
   동일 + 내용만 변경" 케이스가 늘고, 정확성이 전적으로 `input_hash` 에 의존. selective invalidate
   (이미 정의된 `invalidate(path)`) wire-up 이 필요해진다 (stale entry 누적 방지).
2. **Merkle DAG 부재** (`compiled_cache.zig:20-22` 주석) — `import_records_hash` 가 specifier +
   resolved path 만 보고 *dep 의 mangle/export rename 전파*를 놓친다. 현재는 graph_changed clear 가
   부분적으로 가려주나, persistent graph + 재사용 빈도 증가 시 in-memory stale 위험으로 노출될 수 있음.
   ChunkEmitCache wire-up(Phase 4) 시 `modules_hash` 가 동일 결함을 상속.

## 9. RFC 본문 수정 권고 (RFC_LIFECYCLE_SCOPE_REDESIGN)

audit 결과 RFC 본문에 반영할 보정 3건:

1. **§1.3 dangling 후보 표 확장** — `Alias.canonical_name`, `Module.reachable_stmts`,
   `Module.symbol_to_stmt` 3건 추가. 현재 RFC 표는 `canonical_name` + `alias_table`/`export_index_by_name`/
   `namespace_access_index` 를 들지만, 후자 3개 중 실제 dangling 은 alias_table 의 canonical_name *뿐*이고,
   대신 reachable_stmts/symbol_to_stmt 가 누락돼 있다.
2. **§2.3 SymbolID 설계** — `source_index: u32` 가 `ModuleIndex` 직접 사용임을 암시하나, ModuleIndex 는
   build-local. "build-local RenameTable 키" 와 "cross-build path-stable id" 를 구분 (§5.2).
3. **L.5 scope** — `Symbol.canonical_name` 제거뿐 아니라 `Alias.canonical_name` 외부화 + reachable_stmts/
   symbol_to_stmt 의 build-scope 분류·invalidate 명시 포함.

## 10. Follow-up PR Scope 확정

audit 으로 후속 PR 의 정확한 touch surface 가 확정됨:

| PR | 작업 | 확정된 touch surface | 난이도 |
|---|---|---|---|
| **L.2** | `SymbolID` 정의 (build-local 키 + path-stable id 구분) | `bundler/symbol.zig` (이미 `SymbolRef.semantic` 존재), `module_id.zig`(path-stable) | 낮음 (인프라 존재) |
| **L.3** | `RenameTable` 신규 + Linker write | `linker.zig` 5개 함수(§7), 병행 path | 중간 |
| **L.4** | emitter RenameTable lookup 전환 | `metadata.renames` 승격 + chunks/esm_wrap 3 site(§6.1) | 중간 (95% 완료) |
| **L.5** | big-bang: `canonical_name` 제거 + #2/#3/#4 처리 | `semantic/symbol.zig`, `bundler/symbol.zig`, `module.zig`(reachable_stmts), build_flow reset | **높음 (risk)** |
| **L.6+** | graph persistence (selective invalidate wire-up 동반) | `incremental.zig:289`, `compiled_cache.invalidate` | 높음 |

### 결론

- **dangling 후보는 4종 + ModuleIndex 의미 불안정 1건으로 완전히 식별됨.** RFC 의 1개(canonical_name)
  가정보다 3개 더 많다 (alias canonical, reachable_stmts, symbol_to_stmt).
- **emitter 측 RenameTable 인프라는 이미 95% 존재** (`metadata.renames`) — L.4 는 예상보다 가볍다.
- **cache-scope 는 청정** — deep-dupe 모델이라 graph persistence 도입 시에도 dangling 위험 없음.
  단 selective invalidate wire-up 과 Merkle DAG 부재는 Phase 3/4 에서 별도 처리 필요.
- **가장 큰 risk 는 여전히 L.5 big-bang** 이며, 본 audit 이 그 scope 를 완전하게 만들었다.
