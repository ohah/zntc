//! Tree-shaking helpers used during bundle emission.

const std = @import("std");
const Module = @import("../module.zig").Module;
const Linker = @import("../linker.zig").Linker;
const Ast = @import("../../parser/ast.zig").Ast;
const CallFlags = @import("../../parser/ast.zig").CallFlags;
const stmt_info_mod = @import("../stmt_info.zig");
const TreeShaker = @import("../tree_shaker.zig").TreeShaker;
const profile = @import("../../profile.zig");

/// Cross-module @__NO_SIDE_EFFECTS__ 전파.
///
/// 단일 모듈 내에서는 semantic analyzer가 callee symbol의 no_side_effects 플래그를 보고
/// call_expression에 is_pure를 자동 설정한다 (analyzer.zig:863-876).
/// 하지만 cross-module import의 경우, importing 모듈의 semantic analyzer는 원본 모듈의
/// symbol을 모르므로 is_pure가 설정되지 않는다.
///
/// 이 함수는 linker가 해석한 import→export 바인딩을 활용하여:
/// 1. import한 symbol이 원본 모듈에서 no_side_effects로 선언되었는지 확인
/// 2. 해당 symbol을 callee로 사용하는 call_expression에 is_pure 플래그 설정
pub fn propagateCrossModulePurity(
    linker: *const Linker,
    module: *const Module,
    ast: *Ast,
    symbol_ids: []const ?u32,
    allocator: std.mem.Allocator,
) void {
    const sem = module.semantic orelse return;
    if (linker.graph.getModule(module.index) != module) return;
    if (module.import_bindings.len == 0) return;
    if (symbol_ids.len == 0) return;

    const sym_count = sem.symbols.items.len;
    if (sym_count == 0) return;

    var purity_scope = profile.begin(.emit_output_purity);
    defer purity_scope.end();

    const CandidateCall = struct {
        symbol_idx: usize,
        flags_extra_idx: usize,
    };
    var candidate_calls: std.ArrayListUnmanaged(CandidateCall) = .empty;
    defer candidate_calls.deinit(allocator);

    // import 목록 전체를 linker로 해석하기 전에, import binding을 callee로 쓰는 호출만
    // 추린다. 값/인자로만 쓰이는 대량 import는 이후 단계에서 건너뛴다.
    {
        var scope = profile.begin(.emit_output_purity_candidates);
        defer scope.end();
        for (ast.nodes.items) |node| {
            if (node.tag != .call_expression and node.tag != .new_expression) continue;
            const e = node.data.extra;
            if (!ast.hasExtra(e, 3)) continue;

            const callee_idx = ast.readExtraNode(e, 0);
            if (callee_idx.isNone()) continue;
            const callee_ni = @backingInt(callee_idx);
            if (callee_ni >= ast.nodes.items.len or callee_ni >= symbol_ids.len) continue;
            if (ast.nodes.items[callee_ni].tag != .identifier_reference) continue;
            const sym_idx = symbol_ids[callee_ni] orelse continue;
            if (sym_idx >= sym_count or sem.symbols.items[sym_idx].kind != .import_binding) continue;

            candidate_calls.append(allocator, .{
                .symbol_idx = @intCast(sym_idx),
                .flags_extra_idx = @intCast(e + 3),
            }) catch return;
        }
    }
    if (candidate_calls.items.len == 0) return;

    // 0 = 무관, 1 = 호출 callee 후보, 2 = @__NO_SIDE_EFFECTS__ import.
    // 기존과 같이 작은 모듈은 stack, 큰 모듈만 emitter arena를 사용한다.
    var import_call_state_buf: [256]u8 = @splat(0);
    const import_call_state: []u8 = if (sym_count <= import_call_state_buf.len)
        import_call_state_buf[0..sym_count]
    else
        allocator.alloc(u8, sym_count) catch return;
    defer if (sym_count > import_call_state_buf.len) allocator.free(import_call_state);
    if (sym_count > import_call_state_buf.len) @memset(import_call_state, 0);
    for (candidate_calls.items) |call| import_call_state[call.symbol_idx] = 1;

    var has_any_pure = false;
    {
        var scope = profile.begin(.emit_output_purity_bindings);
        defer scope.end();
        for (module.import_bindings) |ib| {
            if (ib.kind == .namespace) continue;
            _ = module.checkedImportBindingLocalName(ib) catch continue;
            const local_sym_idx = ib.local_symbol.semanticIndex() orelse continue;
            if (local_sym_idx >= sym_count or import_call_state[local_sym_idx] != 1) continue;

            if (ib.import_record_index >= module.import_records.len) continue;
            const record = module.import_records[ib.import_record_index];
            if (record.resolved.isNone() or record.is_external) continue;
            const canonical = linker.resolveExportChain(record.resolved, ib.imported_name, 0) orelse continue;
            if (canonical.synthetic_member != null) continue;
            const target_module = linker.graph.getModule(canonical.module_index) orelse continue;
            const target_sem = target_module.semantic orelse continue;
            const target_binding = target_module.findExportBinding(canonical.export_name) orelse continue;
            const target_ref = @import("../cross_chunk_export.zig").checkedSymbol(allocator, target_module, target_binding) catch continue;
            const target_sym_idx = target_ref.semanticIndex() orelse continue;
            if (!target_sem.symbols.items[target_sym_idx].decl_flags.no_side_effects) continue;

            import_call_state[local_sym_idx] = 2;
            has_any_pure = true;
        }
    }

    if (!has_any_pure) return;

    // 후보 호출만 다시 확인해 import callee를 pure로 표시한다.
    {
        var scope = profile.begin(.emit_output_purity_apply);
        defer scope.end();
        for (candidate_calls.items) |call| {
            if (import_call_state[call.symbol_idx] == 2) {
                ast.extra_data.items[call.flags_extra_idx] |= CallFlags.is_pure;
            }
        }
    }
}

/// `module.exports = { used, unused }` object-shape 의 unused property 노드를
/// transformer AST 쪽 인덱스로 변환해 `skip_nodes` 에 마킹.
/// span -> new_ni map 을 1회 구축해 fact 마다 nodes 전체를 재스캔하던 O(F×N) 회피.
pub fn markUnusedCjsObjectProperties(
    arena: std.mem.Allocator,
    module: *const Module,
    new_ast: *const Ast,
    ts_infos: stmt_info_mod.ModuleStmtInfos,
    shaker: *const TreeShaker,
    mod_idx: u32,
    skip_nodes: *std.DynamicBitSet,
) !void {
    var has_unused = false;
    for (ts_infos.cjs_export_facts) |fact| {
        if (!fact.is_safe_to_prune) continue;
        if (fact.kind == .object_property and !shaker.isExportUsed(mod_idx, fact.export_name)) {
            has_unused = true;
            break;
        }
    }
    if (!has_unused) return;

    const source_ast = module.ast orelse return;

    const SpanKey = struct { start: u32, end: u32 };
    var span_to_ni: std.AutoHashMapUnmanaged(SpanKey, u32) = .empty;
    defer span_to_ni.deinit(arena);
    for (new_ast.nodes.items, 0..) |new_node, ni| {
        if (new_node.tag != .object_property) continue;
        try span_to_ni.put(arena, .{ .start = new_node.span.start, .end = new_node.span.end }, @intCast(ni));
    }

    for (ts_infos.cjs_export_facts) |fact| {
        if (!fact.is_safe_to_prune) continue;
        if (fact.kind != .object_property) continue;
        if (shaker.isExportUsed(mod_idx, fact.export_name)) continue;
        const prop_node_idx = fact.property_node orelse continue;
        if (prop_node_idx >= source_ast.nodes.items.len) continue;
        const prop_span = source_ast.nodes.items[prop_node_idx].span;
        if (span_to_ni.get(.{ .start = prop_span.start, .end = prop_span.end })) |new_ni| {
            skip_nodes.set(new_ni);
        }
    }
}
