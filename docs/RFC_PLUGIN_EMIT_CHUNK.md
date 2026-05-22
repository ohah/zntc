# RFC: plugin `this.emitFile({ type: 'chunk' })` — 동적 entry chunk emit

상태: **Draft (조사 완료, 구현 보류)** · 분류: XL · 선행: #1880 PR5/6/7-2a
관련: `project_plugin_emit_file_pr5` · `project_determinism_epic_3564_complete` · Rollup/rolldown emit_chunk

## 1. 배경 & 목표

`this.emitFile`(#1880)은 PR5/6 에서 asset, PR7-2a 에서 chunk 요청 수집(`EmitStore.chunks`)까지 구현됐다. 본 RFC 는 **PR7-2b** — emit 된 chunk 를 실제 별도 output chunk 로 출력하는 설계를 확정한다.

목표: plugin 이 resolveId/load/transform hook 에서 `this.emitFile({ type: 'chunk', id, name? })` 를 호출하면, `id`(모듈 specifier)를 새 entry 로 graph 에 주입해 별도 chunk 로 분리하고 reference id 를 반환한다 (Rollup `this.emitFile` chunk 호환). 주 use case: 코드에 정적 import 가 없는 worker 파일·동적 진입점을 plugin 이 번들에 추가.

## 2. asset 과의 근본 차이 (왜 XL 인가)

| | asset (PR5/6) | **chunk (PR7-2)** |
|---|---|---|
| 입력 | source 바이트 | **모듈 id** (resolve 대상) |
| 처리 | list append | **resolve→load→parse→graph 주입→청킹** |
| graph mutation | ❌ 없음 | ✅ **필수** (새 entry 모듈) |
| 결정성 영향 | path 정렬로 충분 | **renumber seed 필요** (#3564) |
| tree-shaking | 무관 | **DFS 루트로 추가** 필요 (아니면 제거됨) |
| 파일명 | emit 시 즉시(source hash) | **청킹 후 lazy** (PR7-2c) |

asset 은 EmitStore append 가 전부지만, chunk 는 graph build 파이프라인(resolution·discovery·renumber·finalize·청킹) 6 곳을 건드린다.

## 3. 스레딩 모델 & race 분석 (설계의 토대)

`build_async_entry.zig:221` 이 별도 `std.Thread`(`buildWorkerThread`)에서 `bundler.bundle()` 을 실행한다. 따라서 스레드가 셋:

- **Node main thread**: 이벤트 루프 + `callJsCallback`(plugin JS) → `emit_store.chunks` **write**
- **Zig build thread**: `graph.build()` discovery loop(`channel.recv()` 로 block) → `emit_store.chunks` **read**
- **Zig scan pool threads**: `scanWorker` → TSFN(blocking) 으로 Node main 에 hook 위임

asset(PR5/6)이 mutex 없이 안전했던 이유: `emit_store.assets` 를 build 종료 **후** merge 단계에서만 read(모든 hook drain 후). chunk 도 같은 원리를 따라야 한다.

**옵션 A (디스커버리 *도중* read)**: Zig build thread 가 루프 안에서 `emit_store.chunks` 를 read → Node main 의 write 와 동시 → **mutex 필수**. ZTS race 회피 원칙(`feedback_race_dont_mitigate`, PR3 self-only 재설계)과 충돌. **기각.**

**옵션 B (디스커버리 패스 *종료 후* read) — 채택**: 디스커버리 패스(`while inflight>0`)가 끝나면 `inflight==0` = 모든 scanWorker 의 hook(emit write 포함) 완료·visible(condvar/channel happens-before). 이때 build thread 가 `emit_store.chunks` 를 read → 새 entry 주입 → **패스 재실행(fixpoint)**. write↔read 가 패스 경계로 분리돼 **mutex 불필요**, asset 모델과 동형.

```
반복:
  병렬 디스커버리 패스 실행 (기존 build_flow.zig:111-126 event-queue)
  ← 패스 종료(inflight==0) = 모든 hook drain·visible
  emit_store.chunks 신규분 드레인 → resolve → addModule → 새 entry 표시 → requestAll
while (신규 entry 추가됨)   // 보통 1패스, emit 중첩 시 N패스 (addModule dedup 으로 bounded)
```

## 4. 설계

### 4.1 emit 요청 수집 (PR7-2a 완료)
`EmitStore.chunks: ArrayList(EmittedChunk{ reference_id, id, name? })` + `emitChunk(id, name?)` → `"chunk-N"`. 메인스레드 직렬 write. (머지됨: d791b9fb)

### 4.2 emit chunk id resolution
entry_points 는 build() 에 **이미 resolve 된 abs path** 로 전달된다. emit chunk `id` 는 plugin 제공 specifier(상대/패키지)일 수 있어 resolve 필요.

- `self.resolve_cache.resolveThreadSafe(source_dir, id, .static_import)` 사용 (sharded-mutex thread-safe, build thread 에서 호출 안전).
- `source_dir` = importer 기준. emit chunk 는 importer 가 없을 수 있음 → **MVP: project_root(또는 entry_dir) 기준 resolve**. (Rollup 도 importer 미지정 시 cwd 기준)
- 미해결 시 build 진단(error) — silent drop 금지.

### 4.3 fixpoint 재-discovery (`build_flow.zig`)
`build()` 의 `applyRuntimePolyfills` **후**, `linkExecutionRoots` **전**에 신규 함수 `injectEmittedChunks(self, &emitted_chunk_indices)`:

```zig
fn injectEmittedChunks(self, out_indices) !void {
    if (self.emit_store == null) return;            // ← hot path 0 (chunk 미사용)
    var prev: usize = 0;
    while (true) {
        const store: *EmitStore = @ptrCast(self.emit_store.?);
        const cur = store.chunks.items.len;
        if (cur <= prev) break;                      // fixpoint
        const discover_from = self.modules.count();
        for (store.chunks.items[prev..cur]) |chk| {
            const abs = resolveEmitChunkId(self, chk.id) orelse { 진단; continue; };
            const idx = try self.addModule(abs);     // dedup: 이미 있으면 기존 idx
            self.modules.at(@intFromEnum(idx)).is_emitted_chunk_entry = true;
            _ = try graph_requested_exports.requestAll(self, idx);
            try out_indices.append(self.allocator, idx);
        }
        prev = cur;
        try discoverPendingModulesSequential(self, discover_from); // 신규 모듈만
    }
}
```

- pool 은 기존 디스커버리 블록에서 `defer deinit` 으로 닫혀 재사용 불가 → 재-discovery 는 `discoverPendingModulesSequential`(순차). emit chunk 서브그래프는 보통 작아 허용. (대량 시 pool 재생성은 follow-up)
- `addModule` dedup(`path_to_module`)으로 동일 id 반복·이미 import 된 모듈도 안전(무한 루프 방지).

### 4.4 `Module.is_emitted_chunk_entry` 플래그 (federation 패턴 재사용)
`chunk.zig` 에 이미 `is_federation_expose` → `addDynamicEntry` 로 별도 chunk 를 만드는 패턴이 있다. emit chunk 도 동일 플래그 방식:

- `Module.is_emitted_chunk_entry: bool = false` 추가 (federation 과 나란히).
- `chunk.zig` generateChunks Phase 1 에 federation block 과 동형 블록 추가:
  ```zig
  // emit chunk → dynamic entry (lazy 청크)
  while (mi < module_count) : (mi += 1) {
      const m = graph.getModule(...) orelse continue;
      if (!m.is_emitted_chunk_entry) continue;
      try addDynamicEntry(allocator, &entries, &dynamic_seen, graph, idx);
  }
  ```
- `is_dynamic = true` → manual chunk 제외 자동, Phase 2 BFS 도달성 자동, 별도 chunk 분리 자동.

### 4.5 emit chunk 가 손봐야 할 3곳 (코드 확인으로 확정)

emit chunk 모듈이 "발견 → **생존** → 실행순서 → **별도 chunk**" 를 완성하려면 세 단계가 각각 다른 파일에서 루트를 결정한다. 셋 다 기존 패턴(inject/run-before-main/federation) 옆에 `if (m.is_emitted_chunk_entry) ...` 한 블록씩 동형 추가 — 난이도는 낮으나 **빠짐없이 셋 다** 필요.

**(1) `tree_shaker.zig:316-338` — 모듈 생존 (가장 중요)**
tree_shaker 는 **entry_points / inject_files / run_before_main 경로 매칭**으로만 `entry_set` 을 정한다(`is_entry_point` 플래그·`dynamic_imports` 안 봄). dynamic import 대상이 사는 이유는 importer(entry)가 entry_set 이라 BFS 가 dynamic edge 로 도달하기 때문 — **emit chunk 는 importer 가 없어 BFS 로 도달 불가 → entry_set 누락 → tree-shaking 으로 제거**. tree-shaking 은 청킹보다 먼저라, 여기서 제거되면 §4.7 청킹에 도달조차 못 한다.
→ `tree_shaker.zig:337` 뒤(run_before_main 블록 옆)에 `if (m.is_emitted_chunk_entry) self.entry_set.set(i)` 추가. **이것이 진짜 생존 지점.** (`addDynamicEntry`(§4.7)는 청킹일 뿐 생존이 아님 — 이전 초안 오류 정정.)

**(2) `finalizeGraph` (`build_flow.zig:283-296`) — exec_index + export 보존**
entry_points 경로에서만 DFS(exec_index) + `is_entry_point`. emit chunk 도 DFS 루트로 안 넣으면 exec_index 미부여 + `is_entry_point=false`(emitter.zig:1164 export 보존 누락).
→ `finalizeGraph(self, entry_points, emitted_chunk_indices)` 확장: emit chunk indices 도 `is_entry_point=true` + `dfs` + `entry_indices` append 후 `markViaDynamic`.

**(3) `chunk.zig` generateChunks Phase 1 (§4.7) — 별도 chunk 분리**
federation block 옆에 `is_emitted_chunk_entry → addDynamicEntry` 동형 추가.

### 4.6 renumber — orphan path-sort 가 결정성 보장 (seed 는 선택)

`renumber.zig` `renumberModulesDeterministically(entry_points)` 는 entry 경로 BFS 로 index 재부여하되, **BFS 미도달 모듈(orphan)은 `lessThanByPath` 알파벳 정렬로 결정적 번호**를 받는다(`renumber.zig:71-82`). emit chunk(+그 서브그래프)는 entry 경로에 없어 orphan 이 되지만 **path-sort 로 이미 결정적** — 즉 **#3564 invariant 위반 아님**(이전 초안의 "renumber seed 필수, 누락 시 비재현" 은 과장, 정정).

→ renumber seed 추가는 **결정성 방어가 아니라 번호 품질 선택**(emit chunk 를 orphan 맨 뒤로 둘지 vs user entry BFS 순서에 섞을지). 성능: renumber 자체가 `#3564` 실측 **0.16ms/0.1%**(lodash-es 641 module, shallow copy). emit chunk 는 finalize 에서 **1회**(fixpoint 매 패스 아님), emit 모듈 수만큼만 선형.

### 4.7 chunk.zig 분리 (4.4 참조)
addDynamicEntry 재사용으로 별도 chunk. 파일명: `name` 명시 시 `[name]`, 아니면 id stem. entry chunk 는 `chunk_names` 패턴(Rollup emit chunk 도 chunk_names).

### 4.8 파일명 / getFileName lazy (PR7-2c, 별도)
chunk 파일명은 청킹 후 확정 → `getFileName(chunkRef)` 는 lazy. `ChunkGraph` 에 `emitted_reference_to_chunk: StringHashMap(ChunkIndex)` 를 Phase 3 후 채우고, getFileName 이 chunk refId 면 그 chunk 의 filename 반환. **PR7-2c 범위.**

## 5. 단계 제약 (Rollup/rolldown 동일)
discovery(buildStart/resolveId/load/transform) 중에만 emit 허용. renderChunk/generateBundle 에선 throw (graph 토폴로지가 청킹 전 확정돼야). rolldown="tx 채널 죽으면 throw", rollup="phase>LOAD_AND_PARSE throw". ZTS: emit_store 가 discovery hook_ctx 에만 연결돼 자연 강제(이후 hook 은 throw — PR7-1 forwardEmitContext 와 동일 매트릭스).

## 6. 정확성 불변식 (correctness-critical)
1. **tree-shaking 생존 (최우선)**: emit chunk 는 §4.5(1) `tree_shaker.entry_set` 에 들어가야 제거 안 됨. **통합 테스트로 "신규 emit chunk 가 실제 output chunk 로 나오는가" 실증** — 메커니즘은 §4.5 셋이 다 맞물려야 성립(하나라도 누락 시 사라지거나 export 깎임). 진짜 위험은 코드 위치가 아니라 이 end-to-end 검증.
2. **결정성(#3564)**: orphan path-sort 가 보장(§4.6) — seed 안 해도 재현 가능. 그래도 N=10 determinism CI(`Build Determinism`)로 emit chunk 사용 빌드 재현성 확인.
3. **dedup**: emit chunk id 가 이미 graph 에 있으면(이미 import) addModule 이 기존 idx 반환 → 그 모듈이 별도 chunk 로 승격(static import 였어도). 의도된 동작.
4. **fixpoint 종료**: addModule dedup 으로 동일 id 반복은 chunks 증가 없음 → 루프 bounded.

## 7. 성능
- **chunk 미사용 빌드(대부분)**: `injectEmittedChunks` 첫 줄 `if (emit_store == null) return` + (연결 시) `chunks.len==0` 체크. 추가 비용 = 비교 2개, **graph_discover hot path(lodash-es 641 module 21.7ms) 대비 측정 noise floor 아래**.
- **게이트**: PR7-2b 머지 전 `graph_discover` bench A/B 로 미사용 빌드 회귀 0 실측 (`feedback_measure_before_optimize`).
- **chunk 사용 빌드**: emit 서브그래프의 정상 디스커버리 비용(dynamic import 와 동급, 신규 병목 아님).

## 8. 분할 계획
- **PR7-2a** ✅ MERGED (d791b9fb): EmitStore.chunks 수집 토대.
- **PR7-2b-i** (저위험): emit chunk id 가 **이미 graph 에 있는 모듈**일 때만 별도 chunk 분리 — §4.5(2) finalize `is_entry_point` + §4.5(3)/§4.7 chunk.zig `addDynamicEntry` + `is_emitted_chunk_entry` 플래그. **tree_shaker 생존(§4.5(1)) 불필요**(이미 import 돼 reachable), resolution/fixpoint/renumber-seed 불필요(이미 discovery·renumber 됨). emitFileCallback/JS 활성화하되 **id 가 graph 에 없으면(신규 모듈) 명시적 throw**(silent-broken 방지 — B-ii 대기). end-to-end 동작 최소 안전 증분.
- **PR7-2b-ii** (고위험): 신규 모듈 지원 — §4.2 resolution + §4.3 fixpoint 재-discovery + **§4.5(1) tree_shaker.entry_set 추가(생존 핵심)**. renumber seed 는 선택(§4.6 orphan 안전망). 통합 테스트(신규 emit chunk output 실증) + 결정성 CI 게이트.
- **PR7-2c**: getFileName lazy (§4.8).

> 권장: B-i 로 청킹/finalize 골격을 이미-있는-모듈로 안전 검증 → B-ii 에서 tree_shaker 생존 + 신규 모듈 resolution 격리. B-i 만으론 "코드에 없는 worker emit"(주 use case) 미지원 → B-ii 까지가 실용 완성. (B-i 의 "이미 있는 모듈을 별도 chunk 로" 도 manualChunks/code-splitting 미세제어로 독립 가치 있음.)

## 9. 미해결 질문
- emit chunk importer 기본값(project_root vs entry_dir vs cwd) — Rollup 동작 재확인 필요 (B-ii).
- B-i: emit chunk 로 별도 분리할 "이미 있는 모듈" 이 user entry 와 정적 의존 공유 시 BitSet common chunk 거동 — 의도대로 별도 chunk 승격되는지 테스트.
- preserve_modules / code_splitting=false 모드에서 emit chunk 의미(별도 chunk 강제? inline? 아니면 throw?).
- 동일 id 를 user entry 와 emit chunk 둘 다 지정 시 우선순위.

## 10. 대안 (기각)
- **옵션 A (디스커버리 중 read + mutex)**: §3. race-aversion 충돌, 복잡도↑, 이득(패스 1회 절감)<위험. 기각.
- **build 완전 종료 후 별도 2nd 빌드**: graph 재구축 비용 + 상태 공유 복잡. fixpoint(§4.3)가 기존 graph 재사용으로 더 깔끔.

## 11. 레퍼런스
- rolldown `crates/rolldown_common/src/file_emitter.rs::emit_chunk` (ModuleLoaderMsg::AddEntryModule), `module_loader.rs` (try_spawn_new_task, EntryPointKind::EmittedUserDefined), `code_splitting.rs` (chunk_idx_to_reference_ids).
- rollup `src/utils/FileEmitter.ts::emitChunk` (BuildPhase.LOAD_AND_PARSE 게이트), `ModuleLoader.ts::addEntryModules`, facadeChunkByModule(파일명 lazy).
- ZTS 기존: federation expose(`chunk.zig` is_federation_expose → addDynamicEntry), dynamic import(`resolve_imports.zig` linkDynamicImport).
