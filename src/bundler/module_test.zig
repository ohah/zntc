const std = @import("std");
const module = @import("module.zig");
const Module = module.Module;
const ModuleSemanticData = module.ModuleSemanticData;
const ExportBinding = module.ExportBinding;
const Span = @import("../lexer/token.zig").Span;
const ScopeId = @import("../semantic/scope.zig").ScopeId;
const symbol_mod = @import("symbol.zig");
const semantic_symbol = @import("../semantic/symbol.zig");

fn livenessTestSymbol() semantic_symbol.Symbol {
    return .{
        .name = Span.EMPTY,
        .scope_id = ScopeId.none,
        .kind = .variable_const,
        .declaration_span = Span.EMPTY,
    };
}

// ============================================================
// Tests
// ============================================================

test "Module: init defaults" {
    const m = Module.init(@fromBackingInt(@intCast(0)), "src/index.ts");
    try std.testing.expectEqual(Module.State.reserved, m.state);
    try std.testing.expectEqual(std.math.maxInt(u32), m.exec_index);
    try std.testing.expectEqual(@as(u32, 0), m.cycle_group);
    try std.testing.expect(m.side_effects);
    try std.testing.expect(m.ast == null);
    try std.testing.expectEqual(@as(usize, 0), m.dependencies.items.len);
    try std.testing.expectEqual(@as(usize, 0), m.importers.items.len);
}

test "Module.isExportBindingAlive uses exact SymbolId across hostile spellings and owners" {
    const allocator = std.testing.allocator;
    var test_module = Module.init(@fromBackingInt(@as(u32, 0)), "namespace.ts");
    defer test_module.deinit(allocator);

    const scope_maps = try allocator.alloc(std.StringHashMapUnmanaged(usize), 1);
    defer allocator.free(scope_maps);
    scope_maps[0] = .empty;
    defer scope_maps[0].deinit(allocator);
    // All plausible names deliberately point at symbol 0. The exported binding owns symbol 1.
    for ([_][]const u8{ "counter", "counter$4", "public", "not-a-binding" }) |name| {
        try scope_maps[0].put(allocator, name, 0);
    }

    var semantic = ModuleSemanticData{
        .symbols = .empty,
        .scopes = &.{},
        .scope_maps = scope_maps,
        .exported_names = .empty,
        .symbol_ids = &.{},
        .unresolved_references = .empty,
    };
    defer semantic.symbols.deinit(allocator);
    try semantic.symbols.append(allocator, livenessTestSymbol());
    try semantic.symbols.append(allocator, livenessTestSymbol());
    test_module.semantic = semantic;
    // Statement 0 is dead and statement 1 is reachable. Index 2 is deliberately present in
    // the map but outside the semantic table, so the symbol-table bounds guard is observable.
    var reachable = try std.DynamicBitSet.initEmpty(allocator, 2);
    defer reachable.deinit();
    reachable.set(1);
    test_module.reachable_stmts = &reachable;
    const symbol_to_stmt = [_]?u32{ 0, 1, 0 };
    test_module.symbol_to_stmt = &symbol_to_stmt;
    test_module.tree_shaker_active = true;
    test_module.is_included = true;

    const exact_live = symbol_mod.SymbolRef.makeSemantic(test_module.index, 1);
    const exact_dead = symbol_mod.SymbolRef.makeSemantic(test_module.index, 0);
    const base = ExportBinding{
        .exported_name = "public",
        .local_name = "counter$4",
        .local_span = Span.EMPTY,
        .kind = .local,
        .symbol = exact_live,
    };
    const Scenario = struct {
        binding: ExportBinding,
        expected_alive: bool,
    };
    const scenarios = [_]Scenario{
        .{ .binding = base, .expected_alive = true },
        .{ .binding = .{ .exported_name = "public", .local_name = "counter", .local_span = Span.EMPTY, .kind = .local, .symbol = exact_live }, .expected_alive = true },
        .{ .binding = .{ .exported_name = "public", .local_name = "public", .local_span = Span.EMPTY, .kind = .local, .symbol = exact_live }, .expected_alive = true },
        .{ .binding = .{ .exported_name = "other", .local_name = "not-a-binding$12", .local_span = Span.EMPTY, .kind = .local, .symbol = exact_live }, .expected_alive = true },
        .{ .binding = .{ .exported_name = "renamed", .local_name = "counter", .local_span = Span.EMPTY, .kind = .local, .symbol = exact_live }, .expected_alive = true },
        .{ .binding = .{ .exported_name = "counter", .local_name = "actual", .local_span = Span.EMPTY, .kind = .local, .symbol = exact_dead }, .expected_alive = false },
        .{ .binding = .{ .exported_name = "public", .local_name = "counter", .local_span = Span.EMPTY, .kind = .local }, .expected_alive = true },
        .{ .binding = .{ .exported_name = "public", .local_name = "counter", .local_span = Span.EMPTY, .kind = .local, .symbol = symbol_mod.SymbolRef.makeSemantic(test_module.index, std.math.maxInt(u32)) }, .expected_alive = true },
        .{ .binding = .{ .exported_name = "public", .local_name = "counter", .local_span = Span.EMPTY, .kind = .local, .symbol = symbol_mod.SymbolRef.makeSemantic(@fromBackingInt(@as(u32, 1)), 0) }, .expected_alive = true },
        .{ .binding = .{ .exported_name = "public", .local_name = "counter", .local_span = Span.EMPTY, .kind = .local, .symbol = symbol_mod.SymbolRef.makeSemantic(test_module.index, 2) }, .expected_alive = true },
        .{ .binding = .{ .exported_name = "counter", .local_name = "counter", .local_span = Span.EMPTY, .kind = .re_export, .symbol = exact_dead }, .expected_alive = true },
    };
    for (scenarios) |scenario| {
        try std.testing.expectEqual(scenario.expected_alive, test_module.isExportBindingAlive(scenario.binding));
    }

    // Exact SID lookup does not require a spelling map once the symbol table exists.
    test_module.semantic.?.scope_maps = &.{};
    try std.testing.expect(!test_module.isExportBindingAlive(scenarios[5].binding));
    test_module.symbol_to_stmt = null;
    try std.testing.expect(test_module.isExportBindingAlive(scenarios[5].binding));
    test_module.tree_shaker_active = false;
    test_module.reachable_stmts = null;
    test_module.symbol_to_stmt = &symbol_to_stmt;
    try std.testing.expect(test_module.isExportBindingAlive(scenarios[5].binding));
    test_module.tree_shaker_active = true;
    test_module.is_included = true;
    try std.testing.expect(!test_module.isExportBindingAlive(scenarios[5].binding));

    var no_semantic = Module.init(test_module.index, "without-semantic.ts");
    defer no_semantic.deinit(allocator);
    try std.testing.expect(no_semantic.isExportBindingAlive(base));

    test_module.tree_shaker_active = true;
    test_module.is_included = false;
    try std.testing.expect(!test_module.isExportBindingAlive(scenarios[6].binding));
}

test "Module: state transitions" {
    var m = Module.init(@fromBackingInt(@intCast(0)), "test.ts");
    defer m.deinit(std.testing.allocator);

    try std.testing.expectEqual(Module.State.reserved, m.state);
    m.state = .parsing;
    try std.testing.expectEqual(Module.State.parsing, m.state);
    m.state = .ready;
    try std.testing.expectEqual(Module.State.ready, m.state);
}

test "bundleOrderLessThan: exec_index 동률 시 path 사전순" {
    // exec_index 동률(초기값 maxInt(u32))에서 stable sort 가 input 순(= module_index)을
    // 보존하던 비결정성을 path 사전순 tie-break 로 차단하는지 검증.
    //
    // ⚠️ 예전 주석은 "dynamic-only 미방문 모듈은 모두 maxInt 라 항상 동률" 이라고 썼는데,
    // #4520 부터는 `import()` 전용 모듈도 DFS 루트가 되어 **진짜 exec_index 를 받는다**
    // (그전엔 방출 순서가 의존성 역순이라 TDZ 였다). 그래서 동률은 이제 "DFS 가 아직
    // 방문하지 않은 모듈"(external/미해결 등)에서만 생긴다 — tie-break 자체는 그대로 필요하다.
    var a = Module.init(@fromBackingInt(@intCast(0)), "z/last.ts");
    var b = Module.init(@fromBackingInt(@intCast(1)), "a/first.ts");
    // exec_index 동률 (default maxInt)
    try std.testing.expectEqual(a.exec_index, b.exec_index);
    // path 사전순 — a/first.ts 가 z/last.ts 보다 우선
    try std.testing.expect(Module.bundleOrderLessThan({}, &b, &a));
    try std.testing.expect(!Module.bundleOrderLessThan({}, &a, &b));
}

test "bundleOrderLessThan: exec_index 우선 (path 사전순 무시)" {
    var a = Module.init(@fromBackingInt(@intCast(0)), "a/first.ts");
    var b = Module.init(@fromBackingInt(@intCast(1)), "z/last.ts");
    a.exec_index = 10;
    b.exec_index = 5;
    // a 의 path 가 사전순 앞이지만 exec_index 가 더 커서 b 가 우선
    try std.testing.expect(Module.bundleOrderLessThan({}, &b, &a));
}
