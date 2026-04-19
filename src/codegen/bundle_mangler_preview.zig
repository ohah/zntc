//! ZTS Bundle-wide Mangler Preview (dry-run) — #1608
//!
//! 모든 모듈의 scope/symbol/ref_scope_pair를 하나의 scope forest로 concat하여
//! oxc 스타일 slot coloring을 시뮬레이션한다. 실제 mangling은 변경하지 않고
//! 슬롯 수와 base54 이름 길이 분포만 stderr로 출력.
//!
//! 호출 타이밍: `Linker.computeMangling()` 이후 (per-module nested mangling은
//! buildMetadataForAst가 처리하지만, preview는 번들 전역에서 이름 재사용
//! 가능성을 추정하는 것이 목적이므로 호출 시점에서는 `ModuleSemanticData`의
//! scope/symbol 구조만 읽으면 된다).
//!
//! 알고리즘은 `src/codegen/mangler.zig`의 Phase 1~3을 번들 전역에 맞춰
//! 다시 구성. Phase 4(이름 할당)는 base54 카운터 시뮬레이션으로 길이 히스토그램만 계산.

const std = @import("std");
const Module = @import("../bundler/module.zig").Module;
const Scope = @import("../semantic/scope.zig").Scope;
const ScopeId = @import("../semantic/scope.zig").ScopeId;
const Symbol = @import("../semantic/symbol.zig").Symbol;
const RefScopePair = @import("../semantic/symbol.zig").RefScopePair;
const Mangler = @import("mangler.zig");

/// stderr에 stats JSON 앞에 붙는 고정 접두사. CLI/테스트/bundler에서 공유.
pub const STDERR_PREFIX = "[mangle-preview] ";

pub const PreviewStats = struct {
    module_count: u32,
    total_scope_count: u32,
    mangled_symbol_count: u32,
    slot_count: u32,
    len1: u32,
    len2: u32,
    len3: u32,
    len4: u32,
    len5plus: u32,

    pub fn writeJson(self: PreviewStats, writer: anytype) !void {
        try writer.print(
            "{{\"module_count\":{d},\"total_scope_count\":{d},\"mangled_symbol_count\":{d},\"slot_count\":{d},\"len1\":{d},\"len2\":{d},\"len3\":{d},\"len4\":{d},\"len5plus\":{d}}}",
            .{
                self.module_count,         self.total_scope_count,
                self.mangled_symbol_count, self.slot_count,
                self.len1,                 self.len2,
                self.len3,                 self.len4,
                self.len5plus,
            },
        );
    }
};

/// 번들 전역 slot coloring dry-run 수행.
/// 반환 stats는 호출자가 stderr/로그 등에 출력.
pub fn previewBundleWide(allocator: std.mem.Allocator, modules: []const Module) !PreviewStats {
    // ================================================================
    // Phase 0: 크기 산출 (alloc 용)
    // ================================================================
    // virtual_root(idx 0) + sum(module.scopes.len). 각 모듈의 scope[0]의 parent를
    // virtual_root로 매달아 단일 tree를 만든다.
    const module_count: u32 = @intCast(modules.len);
    var total_scopes: u32 = 1; // virtual root
    var total_symbols: u32 = 0;
    var total_pairs: u32 = 0;
    for (modules) |m| {
        const sem = m.semantic orelse continue;
        total_scopes += @intCast(sem.scopes.len);
        total_symbols += @intCast(sem.symbols.items.len);
        total_pairs += @intCast(sem.ref_scope_pairs.len);
    }

    if (total_symbols == 0) {
        return .{
            .module_count = module_count,
            .total_scope_count = total_scopes,
            .mangled_symbol_count = 0,
            .slot_count = 0,
            .len1 = 0,
            .len2 = 0,
            .len3 = 0,
            .len4 = 0,
            .len5plus = 0,
        };
    }

    // ================================================================
    // Phase 1: concat — scopes / symbols / ref_scope_pairs (단일 pass)
    // ================================================================
    const bundle_scopes = try allocator.alloc(Scope, total_scopes);
    defer allocator.free(bundle_scopes);
    const bundle_symbols = try allocator.alloc(Symbol, total_symbols);
    defer allocator.free(bundle_symbols);
    const bundle_pairs = try allocator.alloc(RefScopePair, total_pairs);
    defer allocator.free(bundle_pairs);

    bundle_scopes[0] = .{
        .parent = ScopeId.none,
        .kind = .global,
        .is_strict = false,
    };

    var scope_off: u32 = 1;
    var symbol_off: u32 = 0;
    var pair_idx: u32 = 0;
    for (modules) |m| {
        const sem = m.semantic orelse continue;
        const s_off = scope_off;
        const y_off = symbol_off;

        for (sem.scopes, 0..) |s, si| {
            var copied = s;
            if (si == 0) {
                copied.parent = @enumFromInt(0);
            } else if (!s.parent.isNone()) {
                copied.parent = @enumFromInt(s.parent.toIndex() + s_off);
            }
            bundle_scopes[s_off + @as(u32, @intCast(si))] = copied;
        }

        for (sem.symbols.items, 0..) |sym, yi| {
            var copied = sym;
            if (!sym.scope_id.isNone()) {
                copied.scope_id = @enumFromInt(sym.scope_id.toIndex() + s_off);
            }
            if (!sym.origin_scope.isNone()) {
                copied.origin_scope = @enumFromInt(sym.origin_scope.toIndex() + s_off);
            }
            bundle_symbols[y_off + @as(u32, @intCast(yi))] = copied;
        }

        for (sem.ref_scope_pairs) |pair| {
            bundle_pairs[pair_idx] = .{
                .symbol_idx = pair.symbol_idx + y_off,
                .scope_id = @enumFromInt(pair.scope_id.toIndex() + s_off),
            };
            pair_idx += 1;
        }

        scope_off += @intCast(sem.scopes.len);
        symbol_off += @intCast(sem.symbols.items.len);
    }

    // ================================================================
    // Phase 2: children list (parent → children adjacency)
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
    // Phase 4: DFS + slot coloring
    // ================================================================
    var slot_liveness: std.ArrayListUnmanaged(std.DynamicBitSet) = .empty;
    defer {
        for (slot_liveness.items) |*s| s.deinit();
        slot_liveness.deinit(allocator);
    }

    const symbol_to_slot = try allocator.alloc(?u32, total_symbols);
    defer allocator.free(symbol_to_slot);
    @memset(symbol_to_slot, null);

    // bindings: 각 scope에 선언된 symbol 인덱스 목록. scope_maps를 번들 전역으로
    // 재구축하지 않기 위해 symbol 배열을 한 번 순회해 역인덱스를 만든다.
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

    var mangled_count: u32 = 0;
    var dfs_stack: std.ArrayListUnmanaged(u32) = .empty;
    defer dfs_stack.deinit(allocator);
    try dfs_stack.append(allocator, 0);

    while (dfs_stack.items.len > 0) {
        const scope_idx = dfs_stack.pop().?;
        if (scope_idx < total_scopes and bundle_scopes[scope_idx].blocksMangling()) {
            // blocksMangling scope 자체는 children 전파도 하지 않는다 (subtree 전체 보존).
            continue;
        }

        // bindings 범위
        const bstart = binding_offsets[scope_idx];
        const bend = binding_offsets[scope_idx + 1];

        // 결정론적 순서를 위해 symbol_idx 오름차순 (이미 그러함 — 삽입 순서 = yi 증가)
        for (bindings[bstart..bend]) |sym_idx| {
            if (symbol_to_slot[sym_idx] != null) continue;
            const sym = bundle_symbols[sym_idx];
            if (shouldSkipPreview(sym)) continue;

            // 합성 심볼도 skip (source span 없음 — 실제 mangling에서도 skip)
            if (sym.isSynthetic()) continue;

            var reused_slot: ?u32 = null;
            for (slot_liveness.items, 0..) |live, slot_idx| {
                if (!Mangler.bitsetIntersects(live, symbol_liveness[sym_idx])) {
                    reused_slot = @intCast(slot_idx);
                    break;
                }
            }

            if (reused_slot) |slot_id| {
                symbol_to_slot[sym_idx] = slot_id;
                slot_liveness.items[slot_id].setUnion(symbol_liveness[sym_idx]);
            } else {
                const new_slot_id: u32 = @intCast(slot_liveness.items.len);
                var new_live = try std.DynamicBitSet.initEmpty(allocator, total_scopes);
                new_live.setUnion(symbol_liveness[sym_idx]);
                try slot_liveness.append(allocator, new_live);
                symbol_to_slot[sym_idx] = new_slot_id;
            }
            mangled_count += 1;
        }

        // children DFS
        const start = children.offsets[scope_idx];
        const end = if (scope_idx + 1 < children.offsets.len) children.offsets[scope_idx + 1] else @as(u32, @intCast(children.list.len));
        var ci = end;
        while (ci > start) {
            ci -= 1;
            try dfs_stack.append(allocator, children.list[ci]);
        }
    }

    // ================================================================
    // Phase 5: base54 카운터 시뮬레이션 → 길이 히스토그램
    // ================================================================
    const slot_count: u32 = @intCast(slot_liveness.items.len);
    var counter: u32 = 0;
    var buf: [8]u8 = undefined;
    var len1: u32 = 0;
    var len2: u32 = 0;
    var len3: u32 = 0;
    var len4: u32 = 0;
    var len5plus: u32 = 0;
    for (0..slot_count) |_| {
        const name = Mangler.nextBase54Name(&counter, &buf);
        switch (name.len) {
            0 => unreachable,
            1 => len1 += 1,
            2 => len2 += 1,
            3 => len3 += 1,
            4 => len4 += 1,
            else => len5plus += 1,
        }
    }

    return .{
        .module_count = module_count,
        .total_scope_count = total_scopes,
        .mangled_symbol_count = mangled_count,
        .slot_count = slot_count,
        .len1 = len1,
        .len2 = len2,
        .len3 = len3,
        .len4 = len4,
        .len5plus = len5plus,
    };
}

// ============================================================
// Preview용 skip 정책 — `is_import`만 제외한다. `is_exported`/`is_default_export`는
// PR 2/3에서 bundle-wide mangler가 top-level도 재매핑한다는 가정이라 제외하지 않음.
// `arguments`/`len<=1`은 per-module source에 의존하는 판정이라 preview에서는 생략 —
// 결과적으로 slot 수가 실제보다 약간 많아지는 conservative upper bound가 된다.
//
// buildChildrenList/markAncestorPath/bitsetIntersects는 `mangler.zig`의 public API를
// 그대로 재사용 (알고리즘 동일).
// ============================================================

fn shouldSkipPreview(sym: Symbol) bool {
    return sym.decl_flags.is_import;
}
