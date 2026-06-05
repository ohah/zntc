# RFC: Persistent Linker — dev HMR 보존-hit 의 link 단계 증분화 (lExp/lRes/lInj)

상태: **DRAFT · measure-first · GO/NO-GO 게이트制** · 분류: dev HMR perf / core
선행(완료): [RFC_LIFECYCLE_SCOPE_REDESIGN](./RFC_LIFECYCLE_SCOPE_REDESIGN.md) L.1~L.5c (`Symbol.canonical_name` 제거 → rename cross-build dangling 구조적 종결)
선행(NO-GO, 참조): [RFC_GRAPH_PERSISTENCE](./RFC_GRAPH_PERSISTENCE.md) (graph instance persist = canonical_name dangling 으로 segfault), L.6 persistent ModuleGraph (graph-persist 상한 = dev HMR wall 17%, 진짜 레버 = emit/linker 트랙)
관련: 이슈 #4176, PR #4177(측정 인프라), `src/bundler/{bundler,linker}.zig`, `src/bundler/symbol.zig`(PreservedRenames)
예상 작업량: Phase 1 = S~M, Phase 2 = L (lifecycle scoping 의존)

---

## 1. 배경 — warm 보존-hit link 의 97% 는 lExp/lRes/lInj

PR #4177 의 `link_subphase_bench`(dev HMR 보존-hit rebuild, `IncrementalBundler(dev_mode + enable_persistence)`)로 link 단계를 9-way 분해한 결과(현재 main, debug):

```
warm(보존-hit) | lExp 34% · lRes 26% · lInj 37%
               | lReExp 0% · lImp 0% · lNs 0% · lRen 0% · lChain 0% · lGuard 0%
```

- **lExp** `buildExportMap` — `export_map[(module_index, name)]` 전 모듈 재구축.
- **lRes** `resolveImports` — `resolved_bindings` 전 모듈 재구축(resolveExportChain).
- **lInj** `injectPreservedRenames` — 보존 rename 스냅샷(`snap.entries`)을 **전량** 재주입(`findSymbolIdx`+`dupe`+`assignSymbolCanonical`).

셋의 공통 root: **`Linker` 가 빌드마다 fresh 생성**(`bundler.zig:1417`, `export_map/resolved_bindings/rename_table = .empty`)되어, 변경이 1개여도 **전 모듈 분의 linker state 를 0 부터 다시 채운다**. lReExp/lImp/lNs(부분-skip 이 쉬운 항목)는 측정상 ~0% 라 ROI 없음. lGuard(renameReuseGuard)는 #4173 의 G1 경량화로, lRen(computeRenames)은 #4171/#4170 의 reuse-hit skip 으로 이미 negligible.

> 이 결론은 **L.6 persistent ModuleGraph NO-GO 의 진단과 일치**한다: "graph-persist 가 제거 가능한 상한 = dev HMR wall 의 17%, 나머지 83% = parse(changed)+**link**+mangler+emit = build-scope. 게이트의 주력은 emit/linker 트랙." 본 RFC 가 그 **linker 트랙**이다.

### 1.1 왜 지금까지 못 줄였나 — graph-persistence 가 막힌 벽

[RFC_GRAPH_PERSISTENCE] 는 graph instance 를 빌드 간 보존하려다 **`Linker.assignSymbolCanonical` 의 canonical_name 이 `Linker.deinit` 후 dangling → segfault** 로 NO-GO 됐다. 즉 "linker state 를 빌드 간 살린다"는 시도는 **cross-build memory ownership 벽**에 막혀 있었다.

**그러나 그 벽의 핵심 한 축은 이미 무너졌다**: [RFC_LIFECYCLE_SCOPE_REDESIGN] L.1~L.5c(PR #3968)가 `semantic.Symbol.canonical_name` field 를 **완전 제거**했다. rename 은 이제 build-scope `Linker.rename_table`(SymbolID→name)이 **유일 출처**이고, graph-scope `Symbol` 에는 rename 문자열이 저장되지 않는다. → graph 가 persist 돼도 rename 으로 인한 dangling 은 발생하지 않는다.

본 RFC 는 이 토대 위에서, **graph 전체가 아니라 linker state(export_map/resolved_bindings/rename_table) 만** 증분화한다.

---

## 2. 문제 분해 — 두 갈래

| 항목 | sink | 빌드 간 잔존? | emit 소비 | 증분화 난이도 |
|---|---|---|---|---|
| lExp `export_map` | linker (`StringHashMap(ExportEntry)`) | ❌ fresh | ✅ `metadata.zig:1625` const-inline 전체 | 中 (키 안정성 = #4174 renumber identity 전제) |
| lRes `resolved_bindings` | linker (`AutoHashMap(BindingKey, …)`) | ❌ fresh | ✅ `getResolvedBinding` 6곳 | 中 |
| lInj `rename_table`/`canonical_strings` | linker | ❌ fresh (스냅샷은 IncrementalBundler 가 보존) | ✅ emit rename | **小 (스냅샷 이미 존재, 주입만 O(N))** |

**lInj 가 가장 손쉬운 갈래다**: rename 스냅샷(`PreservedRenames`)은 이미 `IncrementalBundler.preserved_renames` 로 **빌드 간 보존**된다. 비싼 건 *보존* 이 아니라 매 빌드 **전량 재주입**이다. 즉 lInj 는 "persistence 신설"이 아니라 "주입 비용 절감" 문제다.

lExp/lRes 는 linker-resident 맵을 빌드 간 보존해야 하므로 진짜 persistent-linker 영역이다.

---

## 3. 제안 — 2 Phase, 각 GO/NO-GO 게이트

### Phase 1 — lInj(injectPreservedRenames) 증분화 (低위험, 우선)

`injectPreservedRenames`(`linker.zig:1077`) 현재:
```zig
for (snap.entries) |entry| {
    const fresh_idx = self.findSymbolIdx(module_index, entry.local_name) orelse continue;
    const dup = try self.allocator.dupe(u8, entry.canonical);   // ← 매 빌드 N alloc
    try self.assignSymbolCanonical(id, dup);                     // ← rename_table.put + canonical_strings.append
}
```

세 비용원(Phase 1 착수 전 **내부 분해 측정 선행** — PR #4177 에 sub-category 추가):
1. **`dupe(entry.canonical)` × N** — 스냅샷 문자열은 `preserved_renames`(IncrementalBundler 수명)이 소유. linker 가 빌드마다 자기 사본을 또 만든다. → **borrow 로 전환**(스냅샷이 build 보다 오래 산다)하면 N alloc 제거. canonical_strings 가 borrowed 항목을 free 하지 않도록 ownership flag 분리.
2. **`findSymbolIdx` × N** — by-name 재유도. scope_maps[0] hit 면 O(1)이나, synthetic 이름은 `sem.symbols` 선형 fallback. unchanged 모듈은 idx 가 안정(보존 AST)이라, **스냅샷에 fresh_idx 를 캐시**(첫 주입 시 1회 계산 후 보존)하면 재유도 제거.
3. **`assignSymbolCanonical` 의 rename_table.put + canonical_names_used.put × N** — rename_table 자체가 빌드마다 비므로 N put 불가피. 단 변경 모듈만 다르므로 **변경∪직접importer 한정 재주입 + unchanged 는 직전 rename_table 재사용**이 진짜 해법인데, 이는 rename_table persist(= Phase 2 와 동근원).

**Phase 1 범위**: (1) borrow + (2) fresh_idx 캐시. rename_table 자체 persist 는 Phase 2 로 미룸. 이것만으로 lInj 의 alloc/재유도분(추정 다수)을 제거.

**Phase 1 GO/NO-GO 게이트**: `link_subphase_bench` lInj median 가 **−40% 이상** + byte-identical(보존-hit vs `preserveSafePlugins=false` full-fallback `cmp` 144-lib 회귀 0). 미달 시 Phase 1 종결, Phase 2 로 직행 여부 재평가.

### Phase 2 — export_map/resolved_bindings persist (高위험, lifecycle 의존)

linker 를 `IncrementalBundler` 수명으로 끌어올려(graph 처럼) export_map/resolved_bindings/rename_table 를 빌드 간 보존하고, **변경 모듈 + 직접 importer 만 갱신**한다(#4176 본문의 ②).

- export_map: 변경 모듈 키만 `fetchRemove`+`put`. unchanged 키는 #4174 renumber identity 전제로 그대로 유효(module_index 안정).
- resolved_bindings: 변경 모듈 + 직접 importer(`module.importers`, INVARIANTS §7)만 재해석. source export canonical 이 바뀌면 importer redirect stale.
- rename_table: Phase 1 의 borrow 위에서, 변경 모듈 심볼만 재주입.

**전제 — lifecycle scoping**: persistent linker 는 [RFC_GRAPH_PERSISTENCE] 가 막힌 벽(linker-owned 문자열이 모듈 재파싱 시 dangling)을 다시 만난다. L.5c 가 canonical_name 을 없앴으나, **export_map 키(`makeExportKey` alloc)·resolved_bindings·canonical_strings** 는 여전히 build-scope linker 소유. 변경 모듈 invalidation 시 이들을 정확히 회수/재구축해야 한다. → **[RFC_LIFECYCLE_SCOPE_REDESIGN] 의 build-scope vs persistent-scope 분리가 사실상 선행**이거나, 최소한 linker invalidation API(`invalidateModuleLinkState(idx)`)를 그 audit 위에서 설계해야 한다.

**Phase 2 GO/NO-GO 게이트**: `link_subphase_bench` lExp+lRes median **−60% 이상** + 144-lib byte-identical 회귀 0 + dev HMR e2e(`tests/benchmark/devserver-hmr`) 회귀 0. 정확성 회귀(stale redirect / export_map stale 키) **1건이라도 = 즉시 NO-GO**(graph-persistence 전철).

---

## 4. 정확성 invariant (byte-identical — 가장 깨지기 쉬운 영역)

| invariant | 위험 | 가드 |
|---|---|---|
| export_map 키 `(module_index, name)` 안정 | renumber 가 module_index 바꾸면 stale 키 | **#4174 renumber identity + 위상 불변 전제**. identity 깨지면 full-fallback |
| cross-module rename redirect | 변경 모듈 M 의 export canonical 변경 → M 을 import 하는 importer `ib.symbol` stale | 변경 모듈 + **직접 importer** 둘 다 재계산(`source.findExportBinding`) |
| rename_table borrow 수명 | 스냅샷이 build 보다 먼저 죽으면 dangling | 스냅샷 owner = `IncrementalBundler.preserved_renames`(build 보다 김). 가드 fail 시 스냅샷 drop 경로(F5) 유지 |
| canonical_strings free | borrowed 항목을 free 하면 스냅샷 double-free | owned/borrowed 분리(별도 list 또는 flag), deinit 가 borrowed 미해제 |
| re-export namespace 체인(lNs 무관하나 lRes 체인) | 변경이 re-export 체인 가로지르면 직접 importer 한정 부족 | 체인 끝까지 전파 또는 보수적 full-fallback |

**원칙**: 의심되면 **full-fallback**(현 fresh-linker 경로 = byte-identical baseline). 증분 경로는 항상 full 과 `cmp` 검증.

---

## 5. 단계별 PR 분할

| PR | 범위 | 크기 | 측정 영향 |
|---|---|---|---|
| P1-0 | lInj 내부 분해 측정 카테고리(dupe/findSymbolIdx/put) — PR #4177 확장 | S | 측정 only |
| P1-1 | 스냅샷 문자열 borrow + canonical_strings owned/borrowed 분리 | S | lInj 절감 |
| P1-2 | 스냅샷 fresh_idx 캐시(첫 주입 1회 계산) | S | lInj 절감 |
| P1-G | Phase 1 GO/NO-GO — bench −40% + 144-lib byte-identical | — | gate |
| P2-0 | linker invalidation API(`invalidateModuleLinkState`) + 단위 테스트(호출자 0) | M | 0 |
| P2-1 | Bundler.initWithLinker / IncrementalBundler.persistent_linker opt-in(default off, kill-switch `ZNTC_NO_PERSIST_LINKER`) | M | 0(off) |
| P2-2 | export_map 변경-키 한정 갱신 | M | lExp 절감 |
| P2-3 | resolved_bindings 변경+importer 한정 재해석 | M | lRes 절감 |
| P2-G | Phase 2 GO/NO-GO — bench −60% + e2e 회귀 0 | — | gate |

각 sub-phase 머지마다 **adversarial byte-identical 검증**(#4176 본문 §검증). 단일 큰 PR 금지.

---

## 6. 위험 / RN 영향

- **byte-identical**: 본 영역(linker redirect/export_map 키)은 ZNTC 에서 가장 깨지기 쉽다(#4176). 모든 PR 이 full-fallback `cmp` 게이트 통과 필수.
- **메모리**: persistent linker 는 빌드 간 export_map/canonical_strings 누적 가능 → resolve_cache reset interval(#3751) 패턴 양도(N rebuild 마다 재구축).
- **RN**: RN HMR 은 NAPI watch(`packages/core/src/napi/watch.zig`)가 `IncrementalBundler` 동형 경로. reuse_renames/preserved_renames 이미 RN 적용(#4170 watch.zig 소비처). Phase 1 borrow 는 RN 무영향(주입 로직 공유). Phase 2 persistent linker 는 RN 의 `__zntc_register` wrapper / asset registry 와 호환 검증 필수.
- **선행 NO-GO 재발 위험**: Phase 2 가 graph-persistence 가 막힌 ownership 벽을 다시 만난다. L.5c 가 canonical_name 을 없앴으나 export_map/resolved_bindings ownership 은 미해결. **Phase 2 착수 전 lifecycle audit(L 시리즈) 재확인 필수**.

---

## 7. 결정 / 정책

- **Phase 1 우선**(低위험·스냅샷 이미 존재). lInj −40% 미달이면 Phase 1 도 박제 후 종결.
- **Phase 2 는 Phase 1 결과 + release 8092 실측 후 착수**. 현재 측정은 debug 402-mod. **release+8092 에서 lExp/lRes/lInj 실 비중 확정이 Phase 2 GO 의 전제**(PR #4177 이 `link_*_ms` 를 dev server snapshot 에 노출하므로 측정 가능).
- **NO-GO 기준**: 정확성 회귀 1건 = 즉시 종결(graph-persistence 전철). 본 RFC 를 `RFC_PERSISTENT_LINKER_CLOSED` 로 변경, 측정 박제.
- **kill-switch**: `ZNTC_NO_PERSIST_LINKER`(Phase 2). Phase 1 은 byte-identical 이라 무조건 on.

---

## 8. 미해결 / 후속 측정

- lInj 내부 분해(dupe vs findSymbolIdx vs put 비중) — P1-0 선행. 어느 게 지배인지에 따라 P1-1/P1-2 우선순위.
- release 빌드 상대 분포 — debug 와 다를 수 있음(alloc/hashmap 비중). 8092 실측이 tiebreaker.
- lExp+lRes 가 정말 persistence 로 −60% 회수되는지 — Phase 2 PoC(P2-2/P2-3) 측정 전 미확정. 회수율 낮으면(예: redirect 재계산이 full 과 큰 차 없음) Phase 2 NO-GO.
