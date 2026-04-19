//! ZTS Bundle-wide Mangler — #1608 Option C
//!
//! 모든 모듈의 scope/symbol/ref_scope_pair를 하나의 scope forest로 concat하여
//! oxc 스타일 slot coloring + Base54 이름 할당을 수행하는 단일 entry point.
//!
//! 기존 `Linker.computeMangling`(top-level cross-module)과 `buildMetadataForAst`의
//! per-module nested mangling을 한 번에 대체한다. 번들 전역에서 slot을 재사용하여
//! 3-char mangled name을 대부분 2-char로 줄이는 것이 목표.
//!
//! 호출 규약:
//!   - `computeRenames()` 이후, `buildMetadataForAst` **이전**에 호출.
//!   - 출력인 per-module renames 맵은 `buildMetadataForAst`가 `LinkingMetadata.renames`
//!     로 merge한다. 기존 per-module nested mangle 호출은 플래그가 켜지면 skip.
//!
//! 알고리즘은 `mangler.zig`의 Phase 1~5와 동일하며, 다음 확장:
//!   - 번들 전역 scope forest (virtual root + 모듈별 scope tree 연결)
//!   - symbol/scope ID offset 재매핑
//!   - per-module source lookup을 위한 `bundle_owner` 테이블

const std = @import("std");
const Module = @import("../bundler/module.zig").Module;
const Scope = @import("../semantic/scope.zig").Scope;
const ScopeId = @import("../semantic/scope.zig").ScopeId;
const Symbol = @import("../semantic/symbol.zig").Symbol;
const RefScopePair = @import("../semantic/symbol.zig").RefScopePair;
const Mangler = @import("mangler.zig");

pub const BundleMangleInput = struct {
    modules: []const Module,
    /// 전역 reserved 이름 (e.g. `globalThis`, user-defined via CLI). mangled 이름이
    /// 이 집합과 겹치지 않도록 base54 할당 시 skip.
    global_identifiers: []const []const u8 = &.{},
};

pub const BundleManglerResult = struct {
    /// renames_per_module[i] = module i의 HashMap(sym_idx → new_name).
    /// codegen의 LinkingMetadata.renames merge용. 값 문자열의 소유권은 이 결과가 보유.
    renames_per_module: []std.AutoHashMap(u32, []const u8),
    allocator: std.mem.Allocator,

    pub fn deinit(self: *BundleManglerResult) void {
        for (self.renames_per_module) |*m| {
            var vit = m.valueIterator();
            while (vit.next()) |v| self.allocator.free(v.*);
            m.deinit();
        }
        self.allocator.free(self.renames_per_module);
    }

    /// 모듈 i의 renames 맵 소유권을 호출자로 이전 (move). 반환 후 slot은 빈 HashMap으로
    /// 교체되어 이후 `BundleManglerResult.deinit`은 double-free 없이 안전하게 호출 가능.
    /// 호출자는 반환된 HashMap의 value 문자열을 별도 ownership 경로(e.g. LinkingMetadata.
    /// owned_rename_values)에 등록하고 본인이 deinit 호출 책임을 진다.
    ///
    /// 병렬 호출 금지 — module_idx 인덱스별로 직렬로만 소비할 것.
    pub fn takeModuleRenames(self: *BundleManglerResult, module_idx: usize) std.AutoHashMap(u32, []const u8) {
        const taken = self.renames_per_module[module_idx];
        self.renames_per_module[module_idx] = std.AutoHashMap(u32, []const u8).init(self.allocator);
        return taken;
    }
};

const SymOwner = struct {
    module_idx: u32,
    /// 모듈 내 원본 sym_idx
    local_idx: u32,
};

pub fn mangleBundleWide(allocator: std.mem.Allocator, input: BundleMangleInput) !BundleManglerResult {
    const modules = input.modules;
    const module_count: u32 = @intCast(modules.len);

    // ================================================================
    // Phase 0: 크기 산출
    // ================================================================
    // 각 모듈의 scope[0](module scope)는 scope-hoisting 후 번들 top-level이 된다.
    // 따라서 virtual_root(bundle idx 0)를 모든 모듈의 scope[0]에 해당하는 "통합 bundle
    // 모듈 스코프"로 재사용한다 — 모듈별 scope[0]을 별도 bundle scope로 복사하지 않음.
    // 이렇게 해야 서로 다른 모듈의 top-level 심볼이 같은 scope 내로 들어와 liveness가
    // 올바르게 겹쳐 slot coloring이 conflict를 정확히 회피한다.
    var total_scopes: u32 = 1; // virtual root
    var total_symbols: u32 = 0;
    var total_pairs: u32 = 0;
    for (modules) |m| {
        const sem = m.semantic orelse continue;
        if (sem.scopes.len == 0) continue;
        total_scopes += @intCast(sem.scopes.len - 1); // scope[0] 제외 (virtual root로 흡수)
        total_symbols += @intCast(sem.symbols.items.len);
        total_pairs += @intCast(sem.ref_scope_pairs.len);
    }

    // 빈 결과 초기화 (modules 없음 / 심볼 없음)
    var renames_arr = try allocator.alloc(std.AutoHashMap(u32, []const u8), module_count);
    for (renames_arr) |*m| m.* = std.AutoHashMap(u32, []const u8).init(allocator);
    errdefer {
        for (renames_arr) |*m| {
            var vit = m.valueIterator();
            while (vit.next()) |v| allocator.free(v.*);
            m.deinit();
        }
        allocator.free(renames_arr);
    }

    if (total_symbols == 0) {
        return .{ .renames_per_module = renames_arr, .allocator = allocator };
    }

    // ================================================================
    // Phase 1: concat — scopes / symbols / ref_scope_pairs / owner map
    // ================================================================
    const bundle_scopes = try allocator.alloc(Scope, total_scopes);
    defer allocator.free(bundle_scopes);
    const bundle_symbols = try allocator.alloc(Symbol, total_symbols);
    defer allocator.free(bundle_symbols);
    const bundle_pairs = try allocator.alloc(RefScopePair, total_pairs);
    defer allocator.free(bundle_pairs);
    const bundle_owner = try allocator.alloc(SymOwner, total_symbols);
    defer allocator.free(bundle_owner);

    bundle_scopes[0] = .{
        .parent = ScopeId.none,
        .kind = .global,
        .is_strict = false,
    };

    // 각 모듈의 local scope_id를 bundle scope_id로 remap.
    // local_id == 0 → 0 (virtual root), else → module_base + local_id - 1
    var scope_off: u32 = 1;
    var symbol_off: u32 = 0;
    var pair_idx: u32 = 0;
    // 재사용할 virtual_root의 blocksMangling 속성: 어느 모듈이라도 top-level에 direct eval이
    // 있으면 전체 top-level 차단이 옳다. OR 축적.
    for (modules, 0..) |m, mi| {
        const sem = m.semantic orelse continue;
        if (sem.scopes.len == 0) continue;
        const module_base = scope_off; // scope[1..]이 들어갈 시작 인덱스
        const y_off = symbol_off;

        // 모듈 scope[0]의 eval/with 속성은 virtual root로 전파 (top-level 전체 차단 유지).
        if (sem.scopes[0].subtree_has_direct_eval) bundle_scopes[0].subtree_has_direct_eval = true;
        if (sem.scopes[0].subtree_has_with) bundle_scopes[0].subtree_has_with = true;

        // scope[1..]: parent을 remap해서 복사
        for (sem.scopes[1..], 1..) |s, si| {
            var copied = s;
            if (!s.parent.isNone()) {
                const p = s.parent.toIndex();
                copied.parent = @enumFromInt(if (p == 0) 0 else (module_base + p - 1));
            }
            bundle_scopes[module_base + @as(u32, @intCast(si)) - 1] = copied;
        }

        for (sem.symbols.items, 0..) |sym, yi| {
            var copied = sym;
            if (!sym.scope_id.isNone()) {
                const sid = sym.scope_id.toIndex();
                copied.scope_id = @enumFromInt(if (sid == 0) 0 else (module_base + sid - 1));
            }
            if (!sym.origin_scope.isNone()) {
                const oid = sym.origin_scope.toIndex();
                copied.origin_scope = @enumFromInt(if (oid == 0) 0 else (module_base + oid - 1));
            }
            bundle_symbols[y_off + @as(u32, @intCast(yi))] = copied;
            bundle_owner[y_off + @as(u32, @intCast(yi))] = .{
                .module_idx = @intCast(mi),
                .local_idx = @intCast(yi),
            };
        }

        for (sem.ref_scope_pairs) |pair| {
            const rid = pair.scope_id.toIndex();
            bundle_pairs[pair_idx] = .{
                .symbol_idx = pair.symbol_idx + y_off,
                .scope_id = @enumFromInt(if (rid == 0) 0 else (module_base + rid - 1)),
            };
            pair_idx += 1;
        }

        scope_off += @intCast(sem.scopes.len - 1);
        symbol_off += @intCast(sem.symbols.items.len);
    }

    // ================================================================
    // Phase 2: children list (Mangler.buildChildrenList 재사용)
    // ================================================================
    const children = try Mangler.buildChildrenList(allocator, bundle_scopes);
    defer allocator.free(children.offsets);
    defer allocator.free(children.list);

    // ================================================================
    // Phase 3: per-symbol liveness BitSet
    // ================================================================
    const MaskInt = std.DynamicBitSetUnmanaged.MaskInt;
    const masks_per_symbol = (total_scopes + @bitSizeOf(MaskInt) - 1) / @bitSizeOf(MaskInt);
    const all_masks = try allocator.alloc(MaskInt, @as(usize, total_symbols) * masks_per_symbol);
    defer allocator.free(all_masks);
    @memset(all_masks, 0);

    var symbol_liveness = try allocator.alloc(std.DynamicBitSet, total_symbols);
    defer allocator.free(symbol_liveness);
    for (symbol_liveness, 0..) |*bs, i| {
        const start = i * masks_per_symbol;
        bs.* = .{
            .unmanaged = .{
                .masks = @ptrCast(all_masks[start..].ptr),
                .bit_length = total_scopes,
            },
            .allocator = allocator,
        };
    }

    for (bundle_symbols, 0..) |sym, i| {
        if (!sym.scope_id.isNone() and sym.scope_id.toIndex() < total_scopes) {
            symbol_liveness[i].set(sym.scope_id.toIndex());
        }
    }

    for (bundle_pairs) |pair| {
        if (pair.symbol_idx >= total_symbols) continue;
        const sym = bundle_symbols[pair.symbol_idx];
        if (sym.scope_id.isNone()) continue;
        Mangler.markAncestorPath(&symbol_liveness[pair.symbol_idx], bundle_scopes, pair.scope_id, sym.scope_id);
    }

    // ================================================================
    // Phase 4a: bindings per scope (scope → symbol indices)
    // ================================================================
    const binding_counts = try allocator.alloc(u32, total_scopes);
    defer allocator.free(binding_counts);
    @memset(binding_counts, 0);
    for (bundle_symbols) |sym| {
        if (sym.scope_id.isNone()) continue;
        const s_idx = sym.scope_id.toIndex();
        if (s_idx >= total_scopes) continue;
        binding_counts[s_idx] += 1;
    }
    const binding_offsets = try allocator.alloc(u32, total_scopes + 1);
    defer allocator.free(binding_offsets);
    binding_offsets[0] = 0;
    for (0..total_scopes) |i| binding_offsets[i + 1] = binding_offsets[i] + binding_counts[i];
    const total_bindings = binding_offsets[total_scopes];
    const bindings = try allocator.alloc(u32, total_bindings);
    defer allocator.free(bindings);
    @memset(binding_counts, 0);
    for (bundle_symbols, 0..) |sym, yi| {
        if (sym.scope_id.isNone()) continue;
        const s_idx = sym.scope_id.toIndex();
        if (s_idx >= total_scopes) continue;
        bindings[binding_offsets[s_idx] + binding_counts[s_idx]] = @intCast(yi);
        binding_counts[s_idx] += 1;
    }

    // ================================================================
    // Phase 4b: DFS + slot coloring
    // ================================================================
    // Slot 구조: liveness BitSet + 합산 reference_count (Base54 빈도 정렬용)
    const Slot = struct {
        liveness: std.DynamicBitSet,
        total_refs: u32,
    };

    var slots: std.ArrayListUnmanaged(Slot) = .empty;
    defer {
        for (slots.items) |*s| s.liveness.deinit();
        slots.deinit(allocator);
    }

    const symbol_to_slot = try allocator.alloc(?u32, total_symbols);
    defer allocator.free(symbol_to_slot);
    @memset(symbol_to_slot, null);

    // skip된 심볼의 원본 이름은 출력에 살아남으므로 mangled 이름으로 재할당되지 않도록
    // reserved_names에 예약 (mangler.zig의 #1609 수정과 동일 정책).
    var reserved_names = std.StringHashMap(void).init(allocator);
    defer reserved_names.deinit();

    // global_identifiers도 전역 예약
    for (input.global_identifiers) |gid| {
        try reserved_names.put(gid, {});
    }

    var dfs_stack: std.ArrayListUnmanaged(u32) = .empty;
    defer dfs_stack.deinit(allocator);
    try dfs_stack.append(allocator, 0);

    while (dfs_stack.items.len > 0) {
        const scope_idx = dfs_stack.pop().?;
        if (scope_idx < total_scopes and bundle_scopes[scope_idx].blocksMangling()) {
            // eval/with이 있는 subtree는 전체 mangling 차단 — bindings 이름을 reserved에 넣고
            // children DFS 건너뜀.
            const bstart = binding_offsets[scope_idx];
            const bend = binding_offsets[scope_idx + 1];
            for (bindings[bstart..bend]) |sym_idx| {
                const sym = bundle_symbols[sym_idx];
                if (sym.isSynthetic()) continue;
                const name = originalName(modules, bundle_owner[sym_idx], sym);
                if (name.len > 0) try reserved_names.put(name, {});
            }
            continue;
        }

        const bstart = binding_offsets[scope_idx];
        const bend = binding_offsets[scope_idx + 1];

        // 결정론적 순서: bundle symbol_idx 오름차순 (삽입 순서 = yi 증가 → 이미 정렬됨)
        for (bindings[bstart..bend]) |sym_idx| {
            if (symbol_to_slot[sym_idx] != null) continue; // var hoisting 등 이미 할당
            const sym = bundle_symbols[sym_idx];
            if (sym.isSynthetic()) continue;

            const owner = bundle_owner[sym_idx];
            const name = originalName(modules, owner, sym);
            if (shouldSkipBundle(sym, name, modules[owner.module_idx].is_entry_point)) {
                if (name.len > 0) try reserved_names.put(name, {});
                continue;
            }

            var reused_slot: ?u32 = null;
            for (slots.items, 0..) |*slot, slot_i| {
                if (!Mangler.bitsetIntersects(slot.liveness, symbol_liveness[sym_idx])) {
                    reused_slot = @intCast(slot_i);
                    break;
                }
            }

            if (reused_slot) |slot_id| {
                symbol_to_slot[sym_idx] = slot_id;
                slots.items[slot_id].liveness.setUnion(symbol_liveness[sym_idx]);
                slots.items[slot_id].total_refs += sym.reference_count;
            } else {
                const new_slot_id: u32 = @intCast(slots.items.len);
                var new_live = try std.DynamicBitSet.initEmpty(allocator, total_scopes);
                new_live.setUnion(symbol_liveness[sym_idx]);
                try slots.append(allocator, .{
                    .liveness = new_live,
                    .total_refs = sym.reference_count,
                });
                symbol_to_slot[sym_idx] = new_slot_id;
            }
        }

        // children DFS (역순 push → 작은 인덱스부터 처리)
        const start = children.offsets[scope_idx];
        const end = if (scope_idx + 1 < children.offsets.len) children.offsets[scope_idx + 1] else @as(u32, @intCast(children.list.len));
        var ci = end;
        while (ci > start) {
            ci -= 1;
            try dfs_stack.append(allocator, children.list[ci]);
        }
    }

    // ================================================================
    // Phase 5a: slot을 빈도순 정렬 → Base54 이름 할당
    // ================================================================
    const slot_count = slots.items.len;
    if (slot_count == 0) {
        return .{ .renames_per_module = renames_arr, .allocator = allocator };
    }

    const SlotSort = struct { slot_id: u32, total_refs: u32 };
    const sorted = try allocator.alloc(SlotSort, slot_count);
    defer allocator.free(sorted);
    for (sorted, 0..) |*e, i| e.* = .{ .slot_id = @intCast(i), .total_refs = slots.items[i].total_refs };
    std.mem.sortUnstable(SlotSort, sorted, {}, struct {
        fn cmp(_: void, a: SlotSort, b: SlotSort) bool {
            if (a.total_refs != b.total_refs) return a.total_refs > b.total_refs;
            return a.slot_id < b.slot_id;
        }
    }.cmp);

    // slot_id → base54 이름. 예약어/글로벌/reserved_names 자동 skip.
    var slot_names = try allocator.alloc([]const u8, slot_count);
    defer {
        for (slot_names) |n| allocator.free(n);
        allocator.free(slot_names);
    }

    var name_counter: u32 = 0;
    var name_buf: [8]u8 = undefined;
    for (sorted) |e| {
        var name = Mangler.base54(name_counter, &name_buf);
        name_counter += 1;
        while (Mangler.isReservedOrGlobal(name) or reserved_names.contains(name)) {
            name = Mangler.base54(name_counter, &name_buf);
            name_counter += 1;
        }
        slot_names[e.slot_id] = try allocator.dupe(u8, name);
    }

    // ================================================================
    // Phase 5b: renames 맵 (per-module)
    // ================================================================
    for (symbol_to_slot, 0..) |maybe_slot, bundle_sym_i| {
        const slot_id = maybe_slot orelse continue;
        const new_name = slot_names[slot_id];
        const sym = bundle_symbols[bundle_sym_i];
        if (sym.isSynthetic()) continue;

        const owner = bundle_owner[bundle_sym_i];
        const orig_name = originalName(modules, owner, sym);
        if (std.mem.eql(u8, orig_name, new_name)) continue;

        // 여러 bundle 심볼이 같은 slot을 공유하므로 per-module entry마다 dupe.
        const dup = try allocator.dupe(u8, new_name);
        try renames_arr[owner.module_idx].put(owner.local_idx, dup);
    }

    return .{ .renames_per_module = renames_arr, .allocator = allocator };
}

// ============================================================
// 내부 헬퍼
// ============================================================

fn originalName(modules: []const Module, owner: SymOwner, sym: Symbol) []const u8 {
    if (owner.module_idx >= modules.len) return "";
    const m = modules[owner.module_idx];
    // name.start/end가 source 경계를 벗어난 합성 심볼 방어. nameText는 synthetic_name을
    // 먼저 반환하므로 이 검사는 합성이 아닌 out-of-range 케이스만 대상.
    if (sym.synthetic_name.len == 0 and (sym.name.start >= m.source.len or sym.name.end > m.source.len)) return "";
    return sym.nameText(m.source);
}

/// Bundle-wide skip 정책:
///   - `is_import`: 외부 패키지 참조 (이름 보존 필수)
///   - `is_exported || is_default_export` + entry 모듈: 외부 공개 API
///   - `"arguments"`: JS 예약 의미
///   - `len<=1`: 이미 최단
fn shouldSkipBundle(sym: Symbol, name: []const u8, is_entry_module: bool) bool {
    if (sym.decl_flags.is_import) return true;
    if (is_entry_module and (sym.decl_flags.is_exported or sym.decl_flags.is_default_export)) return true;
    if (std.mem.eql(u8, name, "arguments")) return true;
    if (name.len <= 1) return true;
    return false;
}
