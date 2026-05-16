//! ZNTC Identifier Mangler — Liveness-based Slot Reuse (oxc 방식)
//!
//! 스코프 분석 + liveness BitSet를 기반으로 로컬 변수 이름을 짧은 이름으로 교체한다.
//! 번들 크기를 ~70% 절감하는 핵심 최적화.
//!
//! 알고리즘 (oxc/esbuild 기반, 그래프 컬러링):
//!   1. parent 배열에서 children 역산 (O(n), 2-pass)
//!   2. references로 per-symbol liveness BitSet 계산
//!   3. DFS로 scope tree 순회, alive하지 않은 slot 재사용 (그래프 컬러링)
//!   4. 빈도순 이름 할당 (Base54, 고빈도 심볼이 짧은 이름)
//!
//! 규칙:
//!   - export된 심볼은 mangling 하지 않음
//!   - import 바인딩은 mangling 하지 않음 (번들러가 처리)
//!   - 예약어/글로벌 이름은 건너뜀
//!   - 함수 파라미터도 mangling 대상
//!
//! 참고:
//!   - oxc: crates/oxc_mangler/src/lib.rs (liveness + graph coloring)
//!   - esbuild: internal/renamer/renamer.go (DFS slot assignment)

const std = @import("std");
const Scope = @import("../semantic/scope.zig").Scope;
const ScopeId = @import("../semantic/scope.zig").ScopeId;
const Symbol = @import("../semantic/symbol.zig").Symbol;
const SymbolKind = @import("../semantic/symbol.zig").SymbolKind;
const Reference = @import("../semantic/symbol.zig").Reference;
const Span = @import("../lexer/token.zig").Span;

pub const ManglerResult = struct {
    /// symbol_id -> 새 이름. codegen의 linking_metadata.renames에 주입.
    renames: std.AutoHashMap(u32, []const u8),
    allocator: std.mem.Allocator,
    /// 이 호출의 측정값. `--mangle-report` 경로 외엔 무시됨. #1760 property harness.
    stats: ManglerStats = .{},

    pub fn deinit(self: *ManglerResult) void {
        var it = self.renames.valueIterator();
        while (it.next()) |v| self.allocator.free(v.*);
        self.renames.deinit();
    }

    /// renames의 소유권을 이전하고, 이 결과를 안전하게 해제 가능한 상태로 만든다.
    /// 호출 후 renames의 값 문자열은 호출자가 해제 책임을 진다.
    pub fn takeRenames(self: *ManglerResult) std.AutoHashMap(u32, []const u8) {
        const taken = self.renames;
        self.renames = std.AutoHashMap(u32, []const u8).init(self.allocator);
        return taken;
    }
};

/// Mangler 호출 1회의 측정값. Unified mangler 로 마이그레이션 전/후의
/// property 검증 (번들 크기 ± 1%, 이름 길이 총합 등) 에 사용.
pub const ManglerStats = struct {
    /// Phase 3 에서 생성된 고유 slot 수 (= 고유 base54 이름 수).
    slot_count: usize = 0,
    /// Phase 4 에서 할당된 slot 이름 길이의 합.
    slot_name_length_sum: usize = 0,
    /// Phase 4 종료 시점의 base54 name_counter 값 (예약어 스킵 포함 소비).
    name_counter_final: u32 = 0,
    /// Phase 3 종료 시점의 reserved_names set 크기.
    reserved_size: usize = 0,
    /// Phase 5 후 renames 에 기록된 심볼 수 (원본과 동일하면 skip 되므로 slot_count 와 다를 수 있음).
    renamed_symbol_count: usize = 0,
    /// Phase 4 base54 발급 루프에서 reserved/global 충돌로 skip 된 1글자 후보 수.
    /// 총 skip 수는 `name_counter_final - starting_name_counter - slot_count` 로 derivable
    /// 이지만, 1-char skip 은 카운터 분포를 모르면 알 수 없어 별도 측정.
    reserved_skips_1char: usize = 0,
};

/// mangle() 입력 데이터.
pub const MangleInput = struct {
    scopes: []const Scope,
    symbols: []const Symbol,
    scope_maps: []const std.StringHashMap(usize),
    /// Mangler 는 (symbol_id, scope_id) 만 소비. node_index/kind 필드는
    /// dead store / property mangle 등 다른 consumer 용.
    references: []const Reference,
    source: []const u8,
    /// 번들 모드에서 mangling 제외할 symbol indices (null이면 없음)
    skip_symbols: ?std.DynamicBitSet = null,
    /// #1760 unified 경로: Phase A 가 소비한 counter 를 Phase B 가 이어받도록.
    /// default=0 이면 기존 동작 그대로.
    starting_name_counter: u32 = 0,
    /// #1760 unified 경로: 외부에서 누적된 reserved set. mangle 시작 시
    /// 내부 reserved_names 에 복사된다. borrowed — caller 소유 유지.
    external_reserved: ?*const std.StringHashMap(void) = null,
    /// 모든 모듈에 공유되는 reserved (runtime helper 등). 매 모듈마다 복제하면
    /// N×G 알로케이션 — caller 가 한 번만 build 후 borrow 로 share. lookup 시
    /// internal/external_reserved 와 함께 검사하므로 internal copy 안 함.
    /// `external_reserved` 가 *per-module* (예: Phase A 의 이 모듈 mangled 이름)
    /// 라면 본 필드는 *전 모듈 공통* (예: runtime helper 이름) 으로 분리된다.
    external_reserved_global: ?*const std.StringHashMap(void) = null,
    /// RFC #3288 c2 인프라: set 된 symbol 은 liveness 초기화를 *선언 scope
    /// 단독* 으로 한다 (`markScopeSubtree` 대신). references 의 ancestor-path
    /// 마킹은 그대로라, 결과 liveness = 선언 scope + 실제 참조 경로 (reference-
    /// precise). 이를 통해 그 symbol 을 free-ref 하지 않는 nested scope 가 같은
    /// slot(1-char) 을 안전하게 재사용 — esbuild/oxc top-level↔nested 공유 모델.
    ///
    /// **정확성 불변식**: 이 집합의 symbol 은 *모든 사용처* 가 `references` 에
    /// 등장해야 한다 (누락 시 under-mark → nested 가 잘못 재사용 → silent
    /// broken). top-level (scope 0) 처럼 subtree 가 모듈 전체라 항상 disjoint
    /// 실패하던 binding 을 reference 기반으로 정밀화하는 용도. caller 소유 유지.
    /// default=null → 전 symbol `markScopeSubtree` (기존 동작 byte-identical).
    precise_liveness: ?*const std.DynamicBitSet = null,
};

/// Liveness 기반 mangling.
pub fn mangle(allocator: std.mem.Allocator, input: MangleInput) !ManglerResult {
    const scopes = input.scopes;
    const symbols = input.symbols;
    const scope_maps = input.scope_maps;
    const references = input.references;
    const source = input.source;
    const skip_symbols = input.skip_symbols;

    const scope_count = scopes.len;
    const symbol_count = symbols.len;

    if (scope_count == 0 or symbol_count == 0) {
        return .{
            .renames = std.AutoHashMap(u32, []const u8).init(allocator),
            .allocator = allocator,
        };
    }

    // ================================================================
    // Phase 1: children 역산 (parent 배열 -> children adjacency list)
    // ================================================================
    const children = try buildChildrenList(allocator, scopes);
    defer allocator.free(children.offsets);
    defer allocator.free(children.list);

    // ================================================================
    // Phase 2: per-symbol liveness BitSet 계산
    // ================================================================
    // 각 symbol이 어느 scope에서 alive한지 추적.
    // alive = 선언 scope에서 참조 scope까지의 ancestor 경로 전체.
    //
    // 벌크 할당: symbol_count개의 mask 배열을 단일 버퍼로 할당하여
    // 개별 DynamicBitSet.initEmpty 대신 O(1) 할당.
    const MaskInt = std.DynamicBitSetUnmanaged.MaskInt;
    const masks_per_symbol = (scope_count + @bitSizeOf(MaskInt) - 1) / @bitSizeOf(MaskInt);
    const all_masks = try allocator.alloc(MaskInt, symbol_count * masks_per_symbol);
    defer allocator.free(all_masks);
    @memset(all_masks, 0);

    var symbol_liveness = try allocator.alloc(std.DynamicBitSet, symbol_count);
    defer allocator.free(symbol_liveness);
    for (symbol_liveness, 0..) |*bs, i| {
        const start = i * masks_per_symbol;
        bs.* = .{
            .unmanaged = .{
                .masks = @ptrCast(all_masks[start..].ptr),
                .bit_length = scope_count,
            },
            .allocator = allocator,
        };
    }

    // 선언 scope 자체 + 모든 후손 scope 를 alive 로 표시 (#2956 shadowing 방지).
    //
    // outer binding 은 모든 후손 scope 에서 reference 가능 (closure). 후손 scope 의
    // declaration 이 ancestor 와 같은 slot 을 받으면 mangle 후 자기참조가 됨:
    //   function e(t,n) { ... }
    //   function p(n,t) { const e = e(n); ... }   // const e 가 outer e 를 shadow → ReferenceError
    // declaration scope 의 subtree 전체를 alive 로 표시하면 이 binding 과 후손
    // declaration 이 graph coloring 에서 다른 slot 을 받게 됨. sibling 은 declaration
    // scope 가 같아 이미 충돌 (intersect) 처리되므로 영향 없음.
    for (symbols, 0..) |sym, i| {
        if (!sym.scope_id.isNone() and sym.scope_id.toIndex() < scope_count) {
            const decl_idx = sym.scope_id.toIndex();
            const precise = if (input.precise_liveness) |pl|
                i < pl.capacity() and pl.isSet(i)
            else
                false;
            if (precise) {
                // 선언 scope 단독 — subtree 생략. references 의 ancestor-path
                // 마킹(아래)이 실제 사용 scope 만 정밀 추가 → free-ref 없는
                // nested 가 slot 재사용 가능. 불변식: 사용처가 references 에
                // 완전히 등장해야 함 (MangleInput.precise_liveness 주석 참조).
                symbol_liveness[i].set(decl_idx);
            } else {
                markScopeSubtree(&symbol_liveness[i], children, decl_idx);
            }
        }
    }

    // references: 참조 scope에서 선언 scope까지 ancestor 경로를 모두 set
    for (references) |r| {
        const sym_idx: u32 = @intFromEnum(r.symbol_id);
        if (sym_idx >= symbol_count) continue;
        const decl_scope = symbols[sym_idx].scope_id;
        if (decl_scope.isNone()) continue;
        markAncestorPath(&symbol_liveness[sym_idx], scopes, r.scope_id, decl_scope);
    }

    // ================================================================
    // Phase 3: Slot 할당 (DFS + 그래프 컬러링)
    // ================================================================
    const Slot = struct {
        liveness: std.DynamicBitSet,
        total_refs: u32,
    };

    var slots: std.ArrayListUnmanaged(Slot) = .empty;
    defer {
        for (slots.items) |*s| s.liveness.deinit();
        slots.deinit(allocator);
    }

    // symbol_idx -> slot_id (null이면 미할당)
    var symbol_to_slot = try allocator.alloc(?u32, symbol_count);
    defer allocator.free(symbol_to_slot);
    @memset(symbol_to_slot, null);

    // scope별 bindings를 symbol_idx 기준으로 정렬하기 위한 임시 버퍼
    var binding_buf: std.ArrayListUnmanaged(SymBinding) = .empty;
    defer binding_buf.deinit(allocator);

    // mangling에서 제외된 심볼의 원본 이름은 그대로 출력에 남거나(shouldSkip,
    // blocksMangling) 번들러가 별도로 canonicalize하므로(skip_symbols), base54가
    // 해당 이름을 다른 slot에 재할당하면 동일 스코프 중복 선언(#1609: 9-param
    // pipe의 1글자 param) 또는 shadowing 오염으로 이어진다. 이들 이름을 Phase 4
    // 이름 할당에서 reserved로 취급한다.
    var reserved_names = std.StringHashMap(void).init(allocator);
    defer reserved_names.deinit();

    // #1760: Phase A 에서 누적된 예약어를 Phase B 가 물려받음.
    if (input.external_reserved) |ext| {
        var it = ext.keyIterator();
        while (it.next()) |k| try reserved_names.put(k.*, {});
    }

    // DFS로 scope tree 순회
    var dfs_stack: std.ArrayListUnmanaged(u32) = .empty;
    defer dfs_stack.deinit(allocator);
    try dfs_stack.append(allocator, 0); // root scope

    while (dfs_stack.items.len > 0) {
        const scope_idx = dfs_stack.pop().?;

        // 이 scope의 bindings 수집 (결정론적 순서를 위해 symbol_idx 정렬)
        binding_buf.items.len = 0;
        if (scope_idx < scope_maps.len) {
            var sit = scope_maps[@intCast(scope_idx)].iterator();
            while (sit.next()) |entry| {
                const sym_idx: u32 = @intCast(entry.value_ptr.*);
                if (sym_idx >= symbol_count) continue;

                const sym = symbols[sym_idx];
                const name = entry.key_ptr.*;

                // skip 판정 — 아래 세 경로는 원본 이름이 출력에 살아남으므로 reserved.
                // #1757: 원본 이름과 `canonical_name` (top-level mangler rename 결과)
                // 둘 다 등록해 nested mangler 독립 base54 counter 가 같은 이름 배정 방지.
                if (shouldSkip(sym, name)) {
                    // shouldSkip 의 5 case 분류:
                    //   1. is_exported            → renames 로 ref, 원본 안 emit → reserve 불필요
                    //   2. is_import              → mangled source 로 ref, 원본 안 emit → 불필요
                    //   3. is_class_expr_name     → self-ref 도 mangled → 불필요
                    //   4. "arguments"            → literal 그대로 emit → reserve 필수
                    //   5. name.len <= 1          → literal 그대로 emit → base54 충돌 회피 reserve
                    // 1-3 은 외부 `external_reserved` 가 mangled name 으로 이미 보유 — 추가 안 함.
                    // (blocksMangling path 는 별도 — direct eval/with 는 모든 이름이 동적 lookup
                    // 대상이라 full reserve 필요 — 의도적으로 단순화 안 함.)
                    if (name.len <= 1 or std.mem.eql(u8, name, "arguments")) {
                        try reserved_names.put(name, {});
                    }
                    continue;
                }
                // direct eval / with 스코프의 바인딩은 mangling 차단 (#1258)
                if (!sym.scope_id.isNone()) {
                    const s_idx = sym.scope_id.toIndex();
                    if (s_idx < scopes.len and scopes[s_idx].blocksMangling()) {
                        try reserveNameFor(&reserved_names, sym, name);
                        continue;
                    }
                }
                if (skip_symbols) |ss| {
                    if (sym_idx < ss.capacity() and ss.isSet(sym_idx)) {
                        // skip_symbols (module_scope_symbols) path: 이 binding 은 nested
                        // mangler 가 다루지 않는다 — Phase A 가 mangle 했거나 import binding
                        // (mangled source name 으로 inline). 양쪽 모두 *원본 이름은 출력에
                        // 안 남고* mangled name 만 emit 된다. mangled name 은 외부
                        // `external_reserved` 가 보유 → 여기서 *추가 reserve 불필요*.
                        // 원본 이름 reserve 를 유지하면 1-char 풀 잠식 (J scope-local mangle
                        // epic 의 핵심 root cause — mobx 52 skips_1char 의 직접 원인).
                        continue;
                    }
                }

                try binding_buf.append(allocator, .{ .sym_idx = sym_idx, .name = name });
            }
        }

        // 결정론적 순서: symbol_idx 오름차순
        std.mem.sortUnstable(SymBinding, binding_buf.items, {}, struct {
            fn cmp(_: void, a: SymBinding, b: SymBinding) bool {
                return a.sym_idx < b.sym_idx;
            }
        }.cmp);

        // 각 binding에 slot 할당
        for (binding_buf.items) |binding| {
            const sym_idx = binding.sym_idx;
            if (symbol_to_slot[sym_idx] != null) continue; // 이미 할당됨 (var 호이스팅 등)

            // 기존 slot 중 재사용 가능한 것 찾기:
            // slot의 liveness가 이 symbol의 liveness와 겹치지 않으면 재사용 가능
            var reused_slot: ?u32 = null;
            for (slots.items, 0..) |*slot, slot_idx| {
                // slot.liveness와 symbol_liveness[sym_idx]가 교집합이 없으면 재사용 가능
                if (!bitsetIntersects(slot.liveness, symbol_liveness[sym_idx])) {
                    reused_slot = @intCast(slot_idx);
                    break;
                }
            }

            if (reused_slot) |slot_id| {
                symbol_to_slot[sym_idx] = slot_id;
                // slot의 liveness 확장 (합집합)
                slots.items[slot_id].liveness.setUnion(symbol_liveness[sym_idx]);
                slots.items[slot_id].total_refs += symbols[sym_idx].reference_count;
            } else {
                // 새 slot 생성
                const new_slot_id: u32 = @intCast(slots.items.len);
                var new_liveness = try std.DynamicBitSet.initEmpty(allocator, scope_count);
                new_liveness.setUnion(symbol_liveness[sym_idx]);
                try slots.append(allocator, .{
                    .liveness = new_liveness,
                    .total_refs = symbols[sym_idx].reference_count,
                });
                symbol_to_slot[sym_idx] = new_slot_id;
            }
        }

        // children을 DFS stack에 push (역순으로 넣어서 작은 인덱스부터 처리)
        const start = children.offsets[scope_idx];
        const end = if (scope_idx + 1 < children.offsets.len) children.offsets[scope_idx + 1] else @as(u32, @intCast(children.list.len));
        var ci = end;
        while (ci > start) {
            ci -= 1;
            try dfs_stack.append(allocator, children.list[ci]);
        }
    }

    // ================================================================
    // Phase 4: 빈도순 이름 할당 (Base54)
    // ================================================================
    const slot_count = slots.items.len;
    if (slot_count == 0) {
        return .{
            .renames = std.AutoHashMap(u32, []const u8).init(allocator),
            .allocator = allocator,
        };
    }

    // slot 정렬: total_refs 내림차순, 동률이면 slot_id 오름차순
    const sorted_slots = try allocator.alloc(SlotSortEntry, slot_count);
    defer allocator.free(sorted_slots);
    for (sorted_slots, 0..) |*entry, i| {
        entry.* = .{
            .slot_id = @intCast(i),
            .total_refs = slots.items[i].total_refs,
        };
    }
    std.mem.sortUnstable(SlotSortEntry, sorted_slots, {}, struct {
        fn cmp(_: void, a: SlotSortEntry, b: SlotSortEntry) bool {
            if (a.total_refs != b.total_refs) return a.total_refs > b.total_refs;
            return a.slot_id < b.slot_id;
        }
    }.cmp);

    // slot_id -> base54 이름 할당
    var slot_names = try allocator.alloc(?[]const u8, slot_count);
    defer {
        // slot_names 자체만 해제 (이름 문자열은 renames가 소유)
        allocator.free(slot_names);
    }
    @memset(slot_names, null);

    var name_counter: u32 = input.starting_name_counter;
    var name_buf: [8]u8 = undefined;
    var slot_name_length_sum: usize = 0;
    var reserved_skips_1char: usize = 0;
    for (sorted_slots) |entry| {
        // 예약어/글로벌 + mangling 제외 심볼의 원본 이름은 건너뜀 (#1609).
        // K2-perf (#46): external_reserved_global 은 internal copy 하지 않고 lookup 시 직접
        // 검사 — caller 가 모듈마다 복제하지 않고 한 번만 build 후 share.
        const name = nextNonReservedBase54NameTwo(
            &name_counter,
            &name_buf,
            &reserved_names,
            input.external_reserved_global,
            &reserved_skips_1char,
        );
        slot_names[entry.slot_id] = try allocator.dupe(u8, name);
        slot_name_length_sum += name.len;
    }

    // ================================================================
    // Phase 5: renames 맵 생성
    // ================================================================
    var renames = std.AutoHashMap(u32, []const u8).init(allocator);
    errdefer {
        var it = renames.valueIterator();
        while (it.next()) |v| allocator.free(v.*);
        renames.deinit();
    }

    for (symbol_to_slot, 0..) |maybe_slot, sym_idx| {
        const slot_id = maybe_slot orelse continue;
        const new_name = slot_names[slot_id] orelse continue;
        const sym = symbols[sym_idx];
        // Bundler 합성 심볼(#1338)은 source AST에 식별자 참조가 없고 span이 (0,0).
        // rename은 parser AST의 identifier 노드를 바꾸는 것이라 무의미 — skip.
        if (sym.isSynthetic()) continue;
        const orig_name = sym.nameText(source);

        if (std.mem.eql(u8, orig_name, new_name)) continue;

        // 이미 이름이 할당된 slot에서 왔으므로 dupe 필요 (여러 symbol이 같은 slot 공유)
        try renames.put(@intCast(sym_idx), try allocator.dupe(u8, new_name));
    }

    // slot_names에서 renames로 복사되지 않은 이름 해제
    for (slot_names) |maybe_name| {
        if (maybe_name) |name_str| {
            // renames에 들어간 이름인지 확인하지 않고, 항상 원본을 해제.
            // renames에는 dupe된 복사본이 들어가므로 원본 해제가 안전.
            allocator.free(name_str);
        }
    }

    return .{
        .renames = renames,
        .allocator = allocator,
        .stats = .{
            .slot_count = slot_count,
            .slot_name_length_sum = slot_name_length_sum,
            .name_counter_final = name_counter,
            .reserved_size = reserved_names.count(),
            .renamed_symbol_count = renames.count(),
            .reserved_skips_1char = reserved_skips_1char,
        },
    };
}

// ============================================================
// Liveness 헬퍼
// ============================================================

/// ref_scope에서 decl_scope까지 ancestor 경로의 모든 scope를 liveness에 set.
fn markAncestorPath(
    liveness: *std.DynamicBitSet,
    scopes: []const Scope,
    ref_scope: ScopeId,
    decl_scope: ScopeId,
) void {
    var cur = ref_scope;
    while (!cur.isNone()) {
        const idx = cur.toIndex();
        if (idx >= scopes.len) break;
        liveness.set(idx);
        if (cur.toIndex() == decl_scope.toIndex()) break;
        cur = scopes[idx].parent;
    }
}

/// scope_root 와 그 모든 후손 scope 를 liveness 에 set (#2956 shadowing 방지).
/// children list 를 따라 재귀 DFS. scope tree depth 는 보통 < 100 으로 stack 안전.
fn markScopeSubtree(
    liveness: *std.DynamicBitSet,
    children: ChildrenList,
    scope_root: u32,
) void {
    liveness.set(scope_root);
    if (scope_root + 1 >= children.offsets.len) return;
    const start = children.offsets[scope_root];
    const end = children.offsets[scope_root + 1];
    var ci = start;
    while (ci < end) : (ci += 1) {
        markScopeSubtree(liveness, children, children.list[ci]);
    }
}

/// 두 BitSet이 교집합을 가지는지 검사 (하나라도 겹치면 true).
/// std.DynamicBitSet에는 non-destructive 교집합 검사가 없으므로 직접 구현.
fn bitsetIntersects(a: std.DynamicBitSet, b: std.DynamicBitSet) bool {
    const MaskInt = std.DynamicBitSetUnmanaged.MaskInt;
    const bits_per_mask = @bitSizeOf(MaskInt);
    const na = (a.unmanaged.bit_length + bits_per_mask - 1) / bits_per_mask;
    const nb = (b.unmanaged.bit_length + bits_per_mask - 1) / bits_per_mask;
    const len = @min(na, nb);
    for (a.unmanaged.masks[0..len], b.unmanaged.masks[0..len]) |ma, mb| {
        if (ma & mb != 0) return true;
    }
    return false;
}

// ============================================================
// Children 역산 (parent -> children adjacency list)
// ============================================================

const ChildrenList = struct {
    /// offsets[scope_id] = children_list 내 시작 인덱스. 길이 = scope_count + 1.
    offsets: []u32,
    /// flat children 배열.
    list: []u32,
};

fn buildChildrenList(allocator: std.mem.Allocator, scopes: []const Scope) !ChildrenList {
    const n = scopes.len;

    // Pass 1: 각 scope의 children 수 카운트
    var counts = try allocator.alloc(u32, n);
    defer allocator.free(counts);
    @memset(counts, 0);
    for (scopes[1..]) |s| {
        if (!s.parent.isNone() and s.parent.toIndex() < n) {
            counts[s.parent.toIndex()] += 1;
        }
    }

    // Pass 2: prefix sum -> offsets
    var offsets = try allocator.alloc(u32, n + 1);
    offsets[0] = 0;
    for (0..n) |i| {
        offsets[i + 1] = offsets[i] + counts[i];
    }
    const total_children = offsets[n];

    // Pass 3: 채우기
    var list = try allocator.alloc(u32, total_children);
    // counts를 write pointer로 재사용
    @memset(counts, 0);
    for (scopes[1..], 1..) |s, i| {
        if (!s.parent.isNone() and s.parent.toIndex() < n) {
            const pi = s.parent.toIndex();
            list[offsets[pi] + counts[pi]] = @intCast(i);
            counts[pi] += 1;
        }
    }

    return .{ .offsets = offsets, .list = list };
}

// ============================================================
// Base54 이름 생성 (oxc 호환 문자 순서)
// ============================================================

/// Base54 문자열. gzip 최적화를 위해 빈도 높은 문자가 앞에 배치.
/// oxc: crates/oxc_mangler/src/base54.rs
const BASE54_CHARS = "etnriaoscludfpmhg_vybxSCwTEDOkAjMNPFILRzBVHUWGKqJYXZQ$0123456789";

/// 숫자 n을 Base54 식별자로 인코딩.
/// 첫 글자: 54개 (숫자 제외, JS IdentifierStart)
/// 후속 글자: 64개 (숫자 포함, JS IdentifierPart)
pub fn base54(n: u32, buf: *[8]u8) []const u8 {
    const FIRST_BASE: u32 = 54;
    const REST_BASE: u32 = 64;

    var num = n;
    var len: usize = 0;

    // 첫 글자
    buf[len] = BASE54_CHARS[num % FIRST_BASE];
    len += 1;
    num /= FIRST_BASE;

    // 나머지 글자
    while (num > 0) {
        num -= 1;
        buf[len] = BASE54_CHARS[num % REST_BASE];
        len += 1;
        num /= REST_BASE;
    }

    return buf[0..len];
}

// ============================================================
// 내부 타입
// ============================================================

const SymBinding = struct {
    sym_idx: u32,
    name: []const u8,
};

const SlotSortEntry = struct {
    slot_id: u32,
    total_refs: u32,
};

// ============================================================
// mangling 제외 판정
// ============================================================

fn shouldSkip(sym: Symbol, name: []const u8) bool {
    if (sym.isExported()) return true;
    if (sym.decl_flags.is_import) return true;
    // `const Foo = class Bar {}` 의 inner `Bar` (#2197). mangle 시 `.name` 프로퍼티도
    // 함께 바뀌므로 spec 준수를 위해 원본 이름 보존.
    if (sym.decl_flags.is_class_expr_name) return true;
    if (std.mem.eql(u8, name, "arguments")) return true;
    if (name.len <= 1) return true;
    return false;
}

/// Phase 3 의 세 skip 경로 공용: 원본 이름 + `canonical_name` (top-level mangler
/// rename 결과) 둘 다 reserved 로 등록. `StringHashMap.put` 은 idempotent.
///
/// #1760 Step 3c 실측: Phase B 의 `external_reserved` 로 Phase A 의 모든 이름을
/// 전달하는 전역 공유 방식은 nested 이름을 과도하게 밀어내 번들 크기 +5~10%
/// 회귀를 유발. canonical 을 scope-local reserved 로 보존하는 이 방어막이
/// 실질적 이점 — 전역 pool 공유보다 over-reserving 이 적음.
fn reserveNameFor(reserved: *std.StringHashMap(void), sym: Symbol, name: []const u8) !void {
    try reserved.put(name, {});
    if (sym.hasCanonicalName()) try reserved.put(sym.canonical_name, {});
}

// ============================================================
// 예약어/글로벌 체크
// ============================================================

pub fn isReservedOrGlobal(name: []const u8) bool {
    // CJS wrap callback param 단축 이름 (`(e, m) => {...}`) — emitter 의 `cjs_wrap_substitute`
    // 가 wrapper body 의 unresolved `exports`/`module` 을 `e`/`m` 로 substitute 한다.
    // mangler 가 다른 binding 에 같은 이름을 부여하면 wrapper param 과 redeclare/shadow.
    if (name.len == 1 and (name[0] == 'e' or name[0] == 'm')) return true;
    // JS 예약어 + 리터럴 + 글로벌 (길이 2~6만 체크 — 1글자는 'e'/'m' 외엔 충돌 없고
    // 7글자+는 base54에서 도달 어려움)
    const reserved = [_][]const u8{
        // 2글자
        "do",     "if",     "in",     "of",
        // 3글자
        "for",    "let",    "new",    "try",
        "var",    "NaN",
        // 4글자
           "case",   "else",
        "enum",   "null",   "this",   "true",
        "void",   "with",
        // 5글자
          "await",  "break",
        "catch",  "class",  "const",  "false",
        "super",  "throw",  "while",  "yield",
        // 6글자
        "delete", "export", "import", "return",
        "switch", "typeof",
    };
    for (reserved) |r| {
        if (std.mem.eql(u8, name, r)) return true;
    }
    // #1618 / #1621: bundler runtime helper 축약 이름 — base54 가 사용자 심볼에
    //                동일 이름을 배정해 preamble 정의를 덮어쓰는 것을 방지.
    //                #1752: `runtime_helper_names.PAIRS` 공용 모듈 — 단일 소스 + mangler
    //                가 bundler 를 import 하지 않도록 레이어 역전 회피.
    const names = @import("../runtime_helper_names.zig");
    for (names.ALL_SHORT_NAMES) |s| {
        if (std.mem.eql(u8, name, s)) return true;
    }
    return false;
}

// ============================================================
// 번들 모드 전용: Base54 이름 생성 (예약어 자동 스킵)
// ============================================================

/// Base54 이름을 하나 생성 (외부에서 카운터 관리). 예약어는 자동 스킵.
pub fn nextBase54Name(counter: *u32, buf: *[8]u8) []const u8 {
    var name = base54(counter.*, buf);
    counter.* += 1;
    while (isReservedOrGlobal(name)) {
        name = base54(counter.*, buf);
        counter.* += 1;
    }
    return name;
}

/// `nextBase54Name` + 외부 reserved set 충돌까지 함께 skip. skip 시 1글자 후보였던
/// 횟수만 `skips_1char` 에 누적 (총 skip 수는 counter 차로 derivable).
pub fn nextNonReservedBase54Name(
    counter: *u32,
    buf: *[8]u8,
    reserved: *const std.StringHashMap(void),
    skips_1char: *usize,
) []const u8 {
    return nextNonReservedBase54NameTwo(counter, buf, reserved, null, skips_1char);
}

/// `nextNonReservedBase54Name` 의 2-set variant — 추가 reserved set (전 모듈 공유) 도 함께
/// 검사. caller 가 global set 을 모듈마다 복제하지 않고 한 번만 build 후 share 하는 hot-path
/// 용 (#1760 K2-perf). 한쪽이 null 이면 1-set 와 동등.
pub fn nextNonReservedBase54NameTwo(
    counter: *u32,
    buf: *[8]u8,
    reserved_a: *const std.StringHashMap(void),
    reserved_b: ?*const std.StringHashMap(void),
    skips_1char: *usize,
) []const u8 {
    var name = nextBase54Name(counter, buf);
    while (reserved_a.contains(name) or (reserved_b != null and reserved_b.?.contains(name))) {
        if (name.len == 1) skips_1char.* += 1;
        name = nextBase54Name(counter, buf);
    }
    return name;
}

test "mangle: string_table 기반 생성 심볼도 rename 결과에 포함" {
    const allocator = std.testing.allocator;

    const scopes = [_]Scope{
        .{ .parent = .none, .kind = .global, .is_strict = false, .symbol_count = 0 },
        .{ .parent = @enumFromInt(0), .kind = .function, .is_strict = false, .symbol_count = 1 },
    };

    const string_table_bit: u32 = 0x80000000;
    const symbols = [_]Symbol{
        .{
            .name = .{ .start = string_table_bit, .end = string_table_bit + 5 },
            .scope_id = @enumFromInt(1),
            .origin_scope = @enumFromInt(1),
            .kind = .variable_var,
            .decl_flags = SymbolKind.variable_var.declFlags(),
            .declaration_span = Span{ .start = string_table_bit, .end = string_table_bit + 5 },
            .reference_count = 2,
            .synthetic_name = "_this",
        },
    };

    var empty_scope = std.StringHashMap(usize).init(allocator);
    defer empty_scope.deinit();
    var function_scope = std.StringHashMap(usize).init(allocator);
    defer function_scope.deinit();
    try function_scope.put("_this", 0);

    const scope_maps = [_]std.StringHashMap(usize){ empty_scope, function_scope };
    const refs = [_]Reference{
        .{
            .node_index = @enumFromInt(0),
            .scope_id = @enumFromInt(1),
            .symbol_id = @enumFromInt(0),
            .flags = .{ .read = true },
        },
    };

    var result = try mangle(allocator, .{
        .scopes = &scopes,
        .symbols = &symbols,
        .scope_maps = &scope_maps,
        .references = &refs,
        .source = "",
    });
    defer result.deinit();

    // base54 첫 이름 'e' 는 CJS wrap callback param 으로 reserved (다음 후보 't').
    try std.testing.expectEqualStrings("t", result.renames.get(0).?);
}

test "markScopeSubtree: declaration scope + 모든 후손 set, sibling/ancestor 는 제외 (#2956)" {
    const allocator = std.testing.allocator;

    // scope tree:
    //   0 (root)
    //     ├─ 1
    //     │   └─ 3
    //     └─ 2
    const scopes = [_]Scope{
        .{ .parent = .none, .kind = .global, .is_strict = false, .symbol_count = 0 },
        .{ .parent = @enumFromInt(0), .kind = .function, .is_strict = false, .symbol_count = 0 },
        .{ .parent = @enumFromInt(0), .kind = .function, .is_strict = false, .symbol_count = 0 },
        .{ .parent = @enumFromInt(1), .kind = .block, .is_strict = false, .symbol_count = 0 },
    };

    const children = try buildChildrenList(allocator, &scopes);
    defer allocator.free(children.offsets);
    defer allocator.free(children.list);

    var liveness = try std.DynamicBitSet.initEmpty(allocator, scopes.len);
    defer liveness.deinit();

    // scope 1 의 subtree (1, 3) 만 set 되어야 한다.
    markScopeSubtree(&liveness, children, 1);
    try std.testing.expect(liveness.isSet(1));
    try std.testing.expect(liveness.isSet(3));
    try std.testing.expect(!liveness.isSet(0)); // ancestor 는 제외
    try std.testing.expect(!liveness.isSet(2)); // sibling 은 제외
}

test "markScopeSubtree: leaf scope 은 자기 자신만 set" {
    const allocator = std.testing.allocator;

    const scopes = [_]Scope{
        .{ .parent = .none, .kind = .global, .is_strict = false, .symbol_count = 0 },
        .{ .parent = @enumFromInt(0), .kind = .function, .is_strict = false, .symbol_count = 0 },
    };

    const children = try buildChildrenList(allocator, &scopes);
    defer allocator.free(children.offsets);
    defer allocator.free(children.list);

    var liveness = try std.DynamicBitSet.initEmpty(allocator, scopes.len);
    defer liveness.deinit();

    markScopeSubtree(&liveness, children, 1);
    try std.testing.expect(liveness.isSet(1));
    try std.testing.expect(!liveness.isSet(0));
}

test "precise_liveness: free-ref 없는 nested 가 top-level slot 재사용 (RFC #3288 c2 인프라)" {
    const allocator = std.testing.allocator;

    // scope tree:  0(global) ├─ 1(fn, aa 참조)  └─ 2(fn, bb 선언·참조, aa 미참조)
    const scopes = [_]Scope{
        .{ .parent = .none, .kind = .global, .is_strict = false, .symbol_count = 1 },
        .{ .parent = @enumFromInt(0), .kind = .function, .is_strict = false, .symbol_count = 0 },
        .{ .parent = @enumFromInt(0), .kind = .function, .is_strict = false, .symbol_count = 1 },
    };
    const stb: u32 = 0x80000000;
    const symbols = [_]Symbol{
        .{ // 0: aa — top-level (scope 0). subtree=모듈전체라 기존엔 항상 disjoint 실패
            .name = .{ .start = stb, .end = stb + 2 },
            .scope_id = @enumFromInt(0),
            .origin_scope = @enumFromInt(0),
            .kind = .variable_var,
            .decl_flags = SymbolKind.variable_var.declFlags(),
            .declaration_span = Span{ .start = stb, .end = stb + 2 },
            .reference_count = 1,
            .synthetic_name = "aa",
        },
        .{ // 1: bb — scope 2 nested. aa 를 free-ref 안 함
            .name = .{ .start = stb, .end = stb + 2 },
            .scope_id = @enumFromInt(2),
            .origin_scope = @enumFromInt(2),
            .kind = .variable_var,
            .decl_flags = SymbolKind.variable_var.declFlags(),
            .declaration_span = Span{ .start = stb, .end = stb + 2 },
            .reference_count = 1,
            .synthetic_name = "bb",
        },
    };
    var s0 = std.StringHashMap(usize).init(allocator);
    defer s0.deinit();
    try s0.put("aa", 0);
    var s1 = std.StringHashMap(usize).init(allocator);
    defer s1.deinit();
    var s2 = std.StringHashMap(usize).init(allocator);
    defer s2.deinit();
    try s2.put("bb", 1);
    const scope_maps = [_]std.StringHashMap(usize){ s0, s1, s2 };
    const refs = [_]Reference{
        .{ .node_index = @enumFromInt(0), .scope_id = @enumFromInt(1), .symbol_id = @enumFromInt(0), .flags = .{ .read = true } },
        .{ .node_index = @enumFromInt(1), .scope_id = @enumFromInt(2), .symbol_id = @enumFromInt(1), .flags = .{ .read = true } },
    };

    // (1) precise_liveness=null → aa subtree(0)={0,1,2} ∩ bb subtree(2)={2} ≠ ∅
    //     → 다른 slot → 다른 이름 (기존 동작, 회귀 0 보장).
    var r_def = try mangle(allocator, .{
        .scopes = &scopes,
        .symbols = &symbols,
        .scope_maps = &scope_maps,
        .references = &refs,
        .source = "",
    });
    defer r_def.deinit();
    try std.testing.expect(!std.mem.eql(u8, r_def.renames.get(0).?, r_def.renames.get(1).?));

    // (2) precise_liveness={0} → aa={0}∪path(1→0)={0,1} ∩ bb subtree(2)={2} = ∅
    //     → 같은 slot 재사용 → 같은 이름 (esbuild/oxc top-level↔nested 공유).
    var pl = try std.DynamicBitSet.initEmpty(allocator, symbols.len);
    defer pl.deinit();
    pl.set(0);
    var r_pre = try mangle(allocator, .{
        .scopes = &scopes,
        .symbols = &symbols,
        .scope_maps = &scope_maps,
        .references = &refs,
        .source = "",
        .precise_liveness = &pl,
    });
    defer r_pre.deinit();
    try std.testing.expectEqualStrings(r_pre.renames.get(0).?, r_pre.renames.get(1).?);
}

test "precise_liveness: 참조되는 scope 의 nested 와는 여전히 slot 분리 (shadow-safety, silent-broken 방지)" {
    const allocator = std.testing.allocator;

    // 위와 동일 tree, 단 aa 가 scope 2 에서도 참조됨 → bb 와 같은 이름이면
    // scope 2 에서 aa 가 bb 에 가려져 silent broken. precise 라도 분리돼야 함.
    const scopes = [_]Scope{
        .{ .parent = .none, .kind = .global, .is_strict = false, .symbol_count = 1 },
        .{ .parent = @enumFromInt(0), .kind = .function, .is_strict = false, .symbol_count = 0 },
        .{ .parent = @enumFromInt(0), .kind = .function, .is_strict = false, .symbol_count = 1 },
    };
    const stb: u32 = 0x80000000;
    const symbols = [_]Symbol{
        .{
            .name = .{ .start = stb, .end = stb + 2 },
            .scope_id = @enumFromInt(0),
            .origin_scope = @enumFromInt(0),
            .kind = .variable_var,
            .decl_flags = SymbolKind.variable_var.declFlags(),
            .declaration_span = Span{ .start = stb, .end = stb + 2 },
            .reference_count = 2,
            .synthetic_name = "aa",
        },
        .{
            .name = .{ .start = stb, .end = stb + 2 },
            .scope_id = @enumFromInt(2),
            .origin_scope = @enumFromInt(2),
            .kind = .variable_var,
            .decl_flags = SymbolKind.variable_var.declFlags(),
            .declaration_span = Span{ .start = stb, .end = stb + 2 },
            .reference_count = 1,
            .synthetic_name = "bb",
        },
    };
    var s0 = std.StringHashMap(usize).init(allocator);
    defer s0.deinit();
    try s0.put("aa", 0);
    var s1 = std.StringHashMap(usize).init(allocator);
    defer s1.deinit();
    var s2 = std.StringHashMap(usize).init(allocator);
    defer s2.deinit();
    try s2.put("bb", 1);
    const scope_maps = [_]std.StringHashMap(usize){ s0, s1, s2 };
    const refs = [_]Reference{
        .{ .node_index = @enumFromInt(0), .scope_id = @enumFromInt(1), .symbol_id = @enumFromInt(0), .flags = .{ .read = true } },
        .{ .node_index = @enumFromInt(2), .scope_id = @enumFromInt(2), .symbol_id = @enumFromInt(0), .flags = .{ .read = true } },
        .{ .node_index = @enumFromInt(1), .scope_id = @enumFromInt(2), .symbol_id = @enumFromInt(1), .flags = .{ .read = true } },
    };

    var pl = try std.DynamicBitSet.initEmpty(allocator, symbols.len);
    defer pl.deinit();
    pl.set(0);
    var r = try mangle(allocator, .{
        .scopes = &scopes,
        .symbols = &symbols,
        .scope_maps = &scope_maps,
        .references = &refs,
        .source = "",
        .precise_liveness = &pl,
    });
    defer r.deinit();
    // aa={0}∪path(1→0)∪path(2→0)={0,1,2} ∩ bb subtree(2)={2} ≠ ∅ → 다른 이름.
    try std.testing.expect(!std.mem.eql(u8, r.renames.get(0).?, r.renames.get(1).?));
}
