# ModuleGraph Invariants

`ModuleGraph` 는 번들러의 모든 모듈 메타데이터를 소유한다. 파싱은 worker
thread 에서 병렬로 일어나지만 그래프 자체는 한 번 빌드된 후에는 immutable 로
다뤄져야 한다. 이 문서는 그 사이의 race-safety 와 phase 경계 규약을 정리한다.

본 invariant 는 `#1779` 에픽 (5 PR: #1780/#1781/#1782/#1783/#1784) 작업으로
확립됐다. 새 코드가 그래프를 건드리기 전에 반드시 이 문서를 읽을 것.

## 1. Storage

```zig
pub const ModuleList = std.SegmentedList(Module, 0);
pub const ModuleGraph = struct {
    modules: ModuleList = .{},
    ...
};
```

**핵심 성질**: `SegmentedList` 는 `append` 시 새 chunk 만 alloc 하고 기존
chunk 는 건드리지 않는다. 결과로 **한 번 등록된 `*Module` 포인터는 그래프
수명 동안 영구 유효**. 이 성질이 worker race-safety 의 근간이다.

비교로 이전 `std.ArrayList(Module)` 은 capacity 초과 시 realloc → memcpy 가
일어나서, worker 가 capture 한 포인터를 dangling 으로 만들었다. PR #1783 이
이를 해결했다.

### 금지

- 외부 코드가 `graph.modules` 에 직접 접근 **금지**. accessor API 경유.
- 내부 코드 (graph.zig) 라도 slice 전달 (`graph.modules.items`) 금지 — 이미
  SegmentedList 라서 불가능하지만, 혹시 회귀하지 않도록 명시.

## 2. Phase 정의

| Phase | 위치 | 역할 |
|-------|------|------|
| **init** | `addModule` / `addDisabledModule` | module 슬롯 예약 (한 번) |
| **parse** | `parseModule` / `scanWorker` | 파일 읽기 + AST + semantic. worker thread, 자기 module 만 |
| **resolve** | `applyResolveResult` | import specifier → module index 매칭. main thread |
| **link** | DFS / `promoteExportsKinds` / `populate*` | exec_index / cycle_group / symbol linking. main thread |
| **emit** | `emitter.*` / `chunk.*` | 코드 생성. read-only |

Phase 는 엄격히 순차적이다. build 함수가 모든 parse worker 를 join 한 후에만
resolve 로 진행하고, resolve 가 끝나야 link 를 시작한다.

## 3. Accessor API

외부 코드 (graph.zig 외 모든 파일) 는 `ModuleGraph` 의 아래 API 만 사용:

```zig
// Read
pub inline fn getModule(self: *const ModuleGraph, idx: ModuleIndex) ?*const Module;
pub inline fn moduleCount(self: *const ModuleGraph) usize;
pub inline fn modulesIterator(self: *const ModuleGraph) ModulesIterator;

// Phase-tagged mutation (phase.zig 에서 정의)
pub inline fn parseAccessor(self: *ModuleGraph) ParseAccessor;
pub inline fn resolveAccessor(self: *ModuleGraph) ResolveAccessor;
pub inline fn linkAccessor(self: *ModuleGraph) LinkAccessor;

// 양방향 의존성
pub fn linkDependency(self: *ModuleGraph, from: ModuleIndex, to: ModuleIndex) !void;
```

### `moduleAtMut` 는 accessor 내부 전용

```zig
// graph.zig 에 pub 으로 노출되지만 phase accessor 구현용.
pub inline fn moduleAtMut(self: *ModuleGraph, idx: ModuleIndex) ?*Module;
```

외부 파일이 직접 호출 금지. 테스트 코드에서만 예외 허용 (phase 강제 대상 아님).

## 4. Phase-tagged accessor 규약

`phase.zig` 에 `ParseAccessor` / `ResolveAccessor` / `LinkAccessor` 3개 struct
가 있다. 각각 `*ModuleGraph` 만 보관 (zero-cost) 하고, 자기 phase 가 mutate
권한을 가진 field 의 setter 만 노출한다.

### 단일-phase field (분류)

| Phase | Fields |
|-------|--------|
| **parse only** | source, ast, semantic, parse_arena, import_bindings, export_bindings, line_offsets, legal_comments, prebuilt_stmt_info, mtime, loader, def_format, state, asset_data, css_data, context_expansion_deps |
| **resolve only** | is_module_field, side_effects_user_defined, is_disabled, is_entry_point, is_context_dep |
| **link only** | exec_index, cycle_group, dev_id |

`context_expansion_deps` 는 parse 단계의 `expandRequireContextRecords` 가 plugin
matches 를 모아 채운다. parse_arena 소유라 graph.deinit 시 자동 해제.

`is_context_dep` 는 resolve 단계의 `applyContextDepResults` 가 require.context
match 로 등록된 module 에 마킹. tree-shaker 가 runtime require root 로 보존.

### Multi-phase field (5개)

다음 field 는 parse + resolve 양쪽에서 mutate 되지만, **규칙이 있다**:

| Field | parse | resolve |
|-------|-------|---------|
| `import_records` | slice 확정 (JSX auto-inject 포함) | `records[i].resolved` element-wise 만 |
| `exports_kind` | 초기값 (JSON/CJS 판별) | `.none → .cjs/.esm` 승격만 |
| `wrap_kind` | 초기값 | 승격만 (한 번 정해지면 덮어쓰기 금지) |
| `side_effects` | default (JSON=false) | package.json 정책 적용 (true→false 단조) |
| `uses_top_level_await` | 자기 모듈 await 감지 | transitive 전파 (false→true 단조) |

**slice identity 는 parse phase 에서 freeze**. resolve 가 `setImportRecords`
로 slice 를 재할당하지 않는다 — `setRecordResolved(idx, rec_i, dep)` 만 사용.

## 5. Worker thread 규약

### 허용

- `parseModule(idx)` 에 `ModuleIndex` 만 capture.
- 자기 `idx` 에 해당하는 module 의 field 를 write (phase.zig 의
  `ParseAccessor` 경유).
- `graph.getModule(idx)` 로 읽기 (다른 module 도 읽기는 OK — 단 해당 module
  의 parse 가 이미 완료된 경우만).

### 금지

- inner pointer capture: `&module.ast`, `&module.parse_arena`,
  `module.parse_arena.allocator()` 의 `&arena.state` 등.
  이유: 이들은 `SegmentedList` 와 무관하게 module 이 다른 chunk 로 이동하면
  invalid. 더 본질적으로는 Module 이 같은 chunk 에 머물러도, ArenaAllocator
  같은 struct-in-place 는 copy 시 state 포인터가 깨진다.
- 다른 module 의 field mutate.
- `graph.modules` 의 다른 accessor 직접 접근.

### 체크리스트

새 worker 코드를 추가할 때 스스로 질문:
1. ❓ worker 가 받는 capture 에 `ModuleIndex` 외 다른 pointer/slice 가 있는가?
   있으면 inner pointer race 후보.
2. ❓ worker 가 다른 module 의 field 를 읽/쓰는가? 있으면 phase join 보장
   필요.
3. ❓ worker 가 `graph.modules` 나 `graph.path_to_module` 를 mutate 하는가?
   해야 한다면 main thread 로 이관하거나 mutex 필요.

## 6. Iteration 정책

### read-only 순회 → `modulesIterator`

```zig
var it = graph.modulesIterator();
while (it.next()) |m| {
    // m: *const Module
}
```

`SegmentedList.ConstIterator` 가 internal segment pointer 를 캐싱해 chunk
boundary 를 효율적으로 처리한다.

### index 가 필요한 순회 → count + getModule

```zig
for (0..graph.moduleCount()) |i| {
    const m = graph.getModule(ModuleIndex.fromUsize(i)) orelse continue;
    // i 와 m 둘 다 사용
}
```

### mutation 필요 → phase accessor 또는 linkAccessor

```zig
const la = graph.linkAccessor();
for (0..graph.moduleCount()) |i| {
    const idx = ModuleIndex.fromUsize(i);
    la.setDevId(idx, makeId(...));
}
```

### graph.zig 내부 예외

storage owner 자체는 `self.modules.at(i)` 직접 호출 가능. 외부 파일은 금지.

## 7. `ModuleGraph.linkDependency`

양방향 의존성 등록은 `linkDependency(from, to)` 가 유일한 API.

```zig
try graph.linkDependency(from_idx, to_idx);
// from.dependencies 에 to 추가 + to.importers 에 from 추가
```

이전에 있던 `Module.addDependency(self, alloc, dep, all_modules)` 는 slice
의존 때문에 제거됐다 (PR #1782 Phase 2b).

## 8. 테스트 helper

`src/bundler/chunk_test.zig` 의 `TestGraph` 는 slice 기반 테스트 데이터를
`ModuleGraph` 로 wrap 하는 **owning wrapper**. 동작:

```zig
fn init(alloc, modules: []Module) !TestGraph {
    var graph = ModuleGraph.init(alloc, cache);
    for (modules) |m| try graph.modules.append(alloc, m);  // shallow copy
    return .{ .graph = graph, ... };
}
```

**주의**: Module 의 `dependencies` / `importers` / `dynamic_imports`
ArrayList backing 은 shallow copy 되어 원본과 공유된다. 그래서 `TestGraph.init`
**이전에** modules[i] 를 mutate 하는 것만 안전하고, `init` 후에는 건드리지
말 것. 예외적으로 필요하면 `tg.graph.modules.at(i)` 로 접근.

`TestGraph.deinit` 이 graph 쪽 복사본의 `m.deinit(alloc)` 을 호출하므로
caller 는 `defer for (&modules) |*m| m.deinit(alloc);` 금지 (double-free).

## 9. 변경 시 체크리스트

`ModuleGraph` 또는 `Module` 을 건드리는 PR 을 올릴 때 확인:

- [ ] `graph.modules.items` / `.len` 같은 ArrayList 전용 API 사용 안 함
- [ ] `[]Module` slice 를 새 함수 인자로 받지 않음 (accessor/iterator 사용)
- [ ] 새 worker 가 `ModuleIndex` 외 다른 것을 capture 하지 않음
- [ ] multi-phase field 를 직접 assign 하지 않음 (accessor setter 사용)
- [ ] graph.zig 내부 phase mutation 은 본 문서의 phase 분류표에 맞음
- [ ] 새 field 추가 시 phase 분류표 (§4) 갱신

## References

- `#1779` 에픽 PR: `#1780` (accessor 뼈대), `#1781` (call site 교체),
  `#1782` (slice API 제거), `#1783` (SegmentedList), `#1784` (ModuleList 상수)
- `src/bundler/graph.zig` — storage + accessor 진입점
- `src/bundler/phase.zig` — phase-tagged accessor 정의
- `src/bundler/module.zig` — Module struct + 메서드
- 비교: rolldown (Rust borrow checker), esbuild (Go GC + SoA), Bun (수동 invariant)
