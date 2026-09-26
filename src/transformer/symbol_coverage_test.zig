//! 트랜스포머가 새로 만든 사용자 식별자에 심볼 ID 가 빠지지 않는지 (#4760).
//!
//! 단일 파일 minify 는 변환 뒤 코드를 다시 분석해 이름을 짓는다(#4759) — 그래서 심볼 누락이
//! 출력으로는 드러나지 않는다. 대신 블록 스코핑을 심볼 기준으로 바꾸는 #4760 은 변환 **도중**
//! 심볼이 필요하므로, 고친 지점마다 누락 0 을 검사기로 직접 고정한다.

const std = @import("std");
const Scanner = @import("../lexer/scanner.zig").Scanner;
const Parser = @import("../parser/parser.zig").Parser;
const SemanticAnalyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer;
const transformer_mod = @import("transformer.zig");
const Transformer = transformer_mod.Transformer;
const TransformOptions = transformer_mod.TransformOptions;
const coverage = @import("symbol_coverage.zig");
const SemanticEditor = @import("../semantic/editor.zig").SemanticEditor;

fn firstHoistedTempSpan(ast: *const @import("../parser/ast.zig").Ast, program_idx: @import("../parser/ast.zig").NodeIndex) @import("../lexer/token.zig").Span {
    const program = ast.getNode(program_idx);
    const declaration = ast.getNode(@enumFromInt(ast.extra_data.items[program.data.list.start]));
    const declarator_start = ast.extra_data.items[declaration.data.extra + 1];
    const declarator = ast.getNode(@enumFromInt(ast.extra_data.items[declarator_start]));
    const binding = ast.getNode(@enumFromInt(ast.extra_data.items[declarator.data.extra]));
    return binding.data.string_ref;
}

test "#4819 temp hoist keeps allocation identity across counter reuse" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var scanner = try Scanner.init(allocator, "");
    var parser = Parser.init(allocator, &scanner);
    _ = try parser.parse();
    var transformer = try Transformer.init(allocator, &parser.ast, .{});
    const root = try transformer.transform();
    const helpers = @import("es_helpers.zig");

    const first = try helpers.makeTempVarSpan(&transformer);
    const first_body = try transformer.hoistTempVars(root, 0, .EMPTY);
    try std.testing.expectEqual(first.start, firstHoistedTempSpan(transformer.ast, first_body).start);

    // 다른 함수가 끝난 것처럼 counter를 되감으면 출력 이름은 같아도 변수는 다르다.
    transformer.temp_var_counter = 0;
    const second = try helpers.makeTempVarSpan(&transformer);
    // 상태 기계의 이전 temp와 이름만 같은 새 temp를 잘못 제외하면 안 된다.
    const second_body = try transformer.hoistTempVarsSkippingSpans(root, 0, .EMPTY, &.{first});
    try std.testing.expectEqualStrings("_a", transformer.ast.getText(first));
    try std.testing.expectEqualStrings("_a", transformer.ast.getText(second));
    try std.testing.expect(first.start != second.start);
    try std.testing.expectEqual(second.start, firstHoistedTempSpan(transformer.ast, second_body).start);
    const skipped = try transformer.hoistTempVarsSkippingSpans(root, 0, .EMPTY, &.{second});
    try std.testing.expectEqual(root, skipped);
}

fn checkNullishIdentifierReferences(source: []const u8, options: TransformOptions, source_replaced: bool) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var scanner = try Scanner.init(allocator, source);
    var parser = Parser.init(allocator, &scanner);
    _ = try parser.parse();
    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    try analyzer.analyze();
    var original_ref: ?@import("../semantic/symbol.zig").Reference = null;
    for (analyzer.references.items) |ref| {
        if (ref.flags.declare) continue;
        const sym = analyzer.symbols.items[@intFromEnum(ref.symbol_id)];
        if (std.mem.eql(u8, sym.nameText(parser.ast.source), "value")) original_ref = ref;
    }
    const source_ref = original_ref orelse return error.TestUnexpectedResult;
    const id = @intFromEnum(source_ref.symbol_id);

    var transformer = try Transformer.init(allocator, &parser.ast, options);
    try transformer.initSymbolIds(analyzer.symbol_ids.items);
    transformer.symbols = analyzer.symbols.items;
    transformer.references = analyzer.references.items;
    transformer.scopes = analyzer.scopes.items;
    transformer.scope_maps = analyzer.scope_maps.items;
    transformer.scope_owner_map = analyzer.scope_owner_map;
    transformer.semantic_edit_enabled = true;
    transformer.unresolved_references = &analyzer.unresolved_references;
    _ = try transformer.transform();
    const edited = (try transformer.finishSemanticEdit()).?;
    var reads: usize = 0;
    var original_is_live = false;
    var distinct: ?@import("../parser/ast.zig").NodeIndex = null;
    for (edited.references) |ref| {
        if (@intFromEnum(ref.symbol_id) != id or ref.flags.declare) continue;
        try std.testing.expect(ref.flags.read);
        try std.testing.expect(!ref.flags.write);
        try std.testing.expectEqual(source_ref.scope_id, ref.scope_id);
        try std.testing.expectEqual(source_ref.stmt_idx, ref.stmt_idx);
        try std.testing.expectEqual(source_ref.scope_stmt_idx, ref.scope_stmt_idx);
        if (distinct) |first| try std.testing.expect(first != ref.node_index);
        if (ref.node_index == source_ref.node_index) original_is_live = true;
        distinct = ref.node_index;
        reads += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), reads);
    try std.testing.expectEqual(@as(u32, 2), edited.symbols.items[id].reference_count);
    try std.testing.expectEqual(!source_replaced, original_is_live);
}

test "#4819 nullish identifier duplication records two exact read references" {
    try checkNullishIdentifierReferences("function read(value) { return value ?? 2; }", .{
        .unsupported = TransformOptions.compat.fromESTarget(.es2019),
    }, false);
    try checkNullishIdentifierReferences("function read(value) { use(value); { let value = 1; return value ?? 2; } }", .{
        .unsupported = TransformOptions.compat.fromESTarget(.es5),
    }, true);
}

test "#4819 function and top-level nullish temps keep separate SymbolIds through deferred hoist" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var scanner = try Scanner.init(allocator, "const _a = 7; function read() { return null; } function local() { return read() ?? 0; } function local2() { return read() ?? 3; } console.log(read() ?? 1, read() ?? 2, _a);");
    var parser = Parser.init(allocator, &scanner);
    parser.configureFromExtension(".mjs");
    _ = try parser.parse();
    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    analyzer.is_module = true;
    try analyzer.analyze();
    const original_symbols = analyzer.symbols.items.len;

    var transformer = try Transformer.init(allocator, &parser.ast, .{
        .unsupported = TransformOptions.compat.fromESTarget(.es5),
    });
    try transformer.initSymbolIds(analyzer.symbol_ids.items);
    transformer.symbols = analyzer.symbols.items;
    transformer.references = analyzer.references.items;
    transformer.scopes = analyzer.scopes.items;
    transformer.scope_maps = analyzer.scope_maps.items;
    transformer.scope_owner_map = analyzer.scope_owner_map;
    transformer.semantic_edit_enabled = true;
    _ = try transformer.transform();
    const edited = (try transformer.finishSemanticEdit()).?;
    try std.testing.expectEqual(original_symbols + 4, edited.symbols.items.len);
    for (edited.symbols.items[original_symbols..], 0..) |generated, offset| {
        try std.testing.expectEqualStrings(if (offset == 3) "_c" else "_b", transformer.ast.getText(generated.name));
        try std.testing.expectEqual(@as(u32, 2), generated.reference_count);
        try std.testing.expectEqual(@as(u32, 1), generated.write_count);
        const generated_id: u32 = @intCast(original_symbols + offset);
        var bindings: usize = 0;
        var refs: usize = 0;
        for (edited.symbol_ids, 0..) |maybe_id, i| {
            if (maybe_id != generated_id) continue;
            switch (transformer.ast.nodes.items[i].tag) {
                .binding_identifier => bindings += 1,
                .identifier_reference => refs += 1,
                else => {},
            }
        }
        try std.testing.expectEqual(@as(usize, 1), bindings);
        try std.testing.expectEqual(@as(usize, 2), refs);
    }
    try std.testing.expect(edited.symbols.items[original_symbols].scope_id != edited.symbols.items[original_symbols + 1].scope_id);
    try std.testing.expect(edited.symbols.items[original_symbols + 1].scope_id != edited.symbols.items[original_symbols + 2].scope_id);
    try std.testing.expectEqual(@as(usize, 0), transformer.pending_temp_ref_chains.count());
}

test "#4819 optional call captures bind their writes and reads across scopes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var scanner = try Scanner.init(allocator, "const _a = 7; const obj = { method: function() { return 3; } }; function get() { return obj; } function f() { return get()?.method?.(); } console.log(get()?.method?.(), f(), _a);");
    var parser = Parser.init(allocator, &scanner);
    parser.configureFromExtension(".mjs");
    _ = try parser.parse();
    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    analyzer.is_module = true;
    try analyzer.analyze();
    const original_symbols = analyzer.symbols.items.len;

    var transformer = try Transformer.init(allocator, &parser.ast, .{
        .unsupported = TransformOptions.compat.fromESTarget(.es5),
    });
    try transformer.initSymbolIds(analyzer.symbol_ids.items);
    transformer.symbols = analyzer.symbols.items;
    transformer.references = analyzer.references.items;
    transformer.scopes = analyzer.scopes.items;
    transformer.scope_maps = analyzer.scope_maps.items;
    transformer.scope_owner_map = analyzer.scope_owner_map;
    transformer.semantic_edit_enabled = true;
    _ = try transformer.transform();
    const edited = (try transformer.finishSemanticEdit()).?;
    try std.testing.expect(edited.symbols.items.len >= original_symbols + 4);
    var top_level_count: usize = 0;
    var function_count: usize = 0;
    for (edited.symbols.items[original_symbols..]) |generated| {
        try std.testing.expectEqual(@import("../semantic/symbol.zig").SymbolKind.variable_var, generated.kind);
        try std.testing.expect(generated.reference_count >= 2);
        try std.testing.expectEqual(@as(u32, 1), generated.write_count);
        if (edited.scopes[generated.scope_id.toIndex()].kind == .function) function_count += 1 else top_level_count += 1;
    }
    try std.testing.expect(top_level_count >= 2);
    try std.testing.expect(function_count >= 2);
    try std.testing.expectEqual(@as(usize, 0), transformer.pending_temp_ref_chains.count());
}

test "#4819 spread-new callee captures keep distinct function and module symbols" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var scanner = try Scanner.init(allocator, "const _a = 7; const holder = { Box: function(x) { this.x = x; } }; function local(v) { return new holder.Box(...[v]); } console.log(new holder.Box(...[8]).x, local(9).x, _a);");
    var parser = Parser.init(allocator, &scanner);
    parser.configureFromExtension(".mjs");
    _ = try parser.parse();
    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    analyzer.is_module = true;
    try analyzer.analyze();
    const original_symbols = analyzer.symbols.items.len;

    var transformer = try Transformer.init(allocator, &parser.ast, .{
        .unsupported = TransformOptions.compat.fromESTarget(.es5),
    });
    try transformer.initSymbolIds(analyzer.symbol_ids.items);
    transformer.symbols = analyzer.symbols.items;
    transformer.references = analyzer.references.items;
    transformer.scopes = analyzer.scopes.items;
    transformer.scope_maps = analyzer.scope_maps.items;
    transformer.scope_owner_map = analyzer.scope_owner_map;
    transformer.semantic_edit_enabled = true;
    _ = try transformer.transform();
    const edited = (try transformer.finishSemanticEdit()).?;
    try std.testing.expectEqual(original_symbols + 2, edited.symbols.items.len);
    const local = edited.symbols.items[original_symbols];
    const module = edited.symbols.items[original_symbols + 1];
    try std.testing.expectEqualStrings("_b", transformer.ast.getText(local.name));
    try std.testing.expectEqualStrings("_b", transformer.ast.getText(module.name));
    try std.testing.expect(local.scope_id != module.scope_id);
    for (edited.symbols.items[original_symbols..]) |generated| {
        try std.testing.expectEqual(@as(u32, 2), generated.reference_count);
        try std.testing.expectEqual(@as(u32, 1), generated.write_count);
    }
    try std.testing.expectEqual(@as(usize, 0), transformer.pending_temp_ref_chains.count());
}

test "#4819 nullish assignment value captures keep distinct symbols" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var scanner = try Scanner.init(allocator, "const _a = 1; const box = { x: null }; function obj() { return box; } function key() { return 'x'; } function f() { return obj()[key()] ??= 7; } obj()[key()] ??= 8; console.log(f(), box.x, _a);");
    var parser = Parser.init(allocator, &scanner);
    parser.configureFromExtension(".mjs");
    _ = try parser.parse();
    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    analyzer.is_module = true;
    try analyzer.analyze();
    const original_symbols = analyzer.symbols.items.len;

    var transformer = try Transformer.init(allocator, &parser.ast, .{
        .unsupported = TransformOptions.compat.fromESTarget(.es5),
    });
    try transformer.initSymbolIds(analyzer.symbol_ids.items);
    transformer.symbols = analyzer.symbols.items;
    transformer.references = analyzer.references.items;
    transformer.scopes = analyzer.scopes.items;
    transformer.scope_maps = analyzer.scope_maps.items;
    transformer.scope_owner_map = analyzer.scope_owner_map;
    transformer.semantic_edit_enabled = true;
    _ = try transformer.transform();
    const edited = (try transformer.finishSemanticEdit()).?;
    try std.testing.expectEqual(original_symbols + 6, edited.symbols.items.len);
    for (edited.symbols.items[original_symbols..], 0..) |generated, offset| {
        const name = switch (offset % 3) {
            0 => "_b",
            1 => "_c",
            else => "_d",
        };
        try std.testing.expectEqualStrings(name, transformer.ast.getText(generated.name));
        try std.testing.expectEqual(@as(u32, if (offset % 3 == 2) 2 else 3), generated.reference_count);
        try std.testing.expectEqual(@as(u32, 1), generated.write_count);
    }
    try std.testing.expect(edited.symbols.items[original_symbols].scope_id != edited.symbols.items[original_symbols + 3].scope_id);
    try std.testing.expectEqual(@as(usize, 0), transformer.pending_temp_ref_chains.count());
}

test "#4819 assignment target temps exclude unused candidate references" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var scanner = try Scanner.init(allocator, "const _a = 1; const box = { x: 2 }; function obj() { return box; } function key() { return 'x'; } obj()[key()] ||= 5; obj()[key()] **= 2; console.log(box.x, _a);");
    var parser = Parser.init(allocator, &scanner);
    parser.configureFromExtension(".mjs");
    _ = try parser.parse();
    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    analyzer.is_module = true;
    try analyzer.analyze();
    const original_symbols = analyzer.symbols.items.len;

    var transformer = try Transformer.init(allocator, &parser.ast, .{
        .unsupported = TransformOptions.compat.fromESTarget(.es5),
    });
    try transformer.initSymbolIds(analyzer.symbol_ids.items);
    transformer.symbols = analyzer.symbols.items;
    transformer.references = analyzer.references.items;
    transformer.scopes = analyzer.scopes.items;
    transformer.scope_maps = analyzer.scope_maps.items;
    transformer.scope_owner_map = analyzer.scope_owner_map;
    transformer.semantic_edit_enabled = true;
    _ = try transformer.transform();
    const edited = (try transformer.finishSemanticEdit()).?;
    try std.testing.expectEqual(original_symbols + 4, edited.symbols.items.len);
    for (edited.symbols.items[original_symbols..], 0..) |generated, offset| {
        const expected_name = switch (offset) {
            0 => "_b",
            1 => "_c",
            2 => "_d",
            else => "_e",
        };
        try std.testing.expectEqualStrings(expected_name, transformer.ast.getText(generated.name));
        try std.testing.expectEqual(@as(u32, 2), generated.reference_count);
        try std.testing.expectEqual(@as(u32, 1), generated.write_count);
    }
    try std.testing.expectEqual(@as(usize, 0), transformer.pending_temp_ref_chains.count());
}

test "#4819 transformed scope owners retain their original ScopeId" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var scanner = try Scanner.init(allocator, "function outer() { function inner() { return 1; } return inner(); }");
    var parser = Parser.init(allocator, &scanner);
    parser.configureFromExtension(".mjs");
    _ = try parser.parse();
    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    analyzer.is_module = true;
    try analyzer.analyze();

    var transformer = try Transformer.init(allocator, &parser.ast, .{});
    transformer.scope_owner_map = analyzer.scope_owner_map;
    _ = try transformer.transform();
    try std.testing.expect(transformer.scope_owner_remaps.count() >= 2);

    var editor = try SemanticEditor.init(
        allocator,
        transformer.ast,
        analyzer.symbols.items,
        analyzer.scopes.items,
        analyzer.scope_maps.items,
        analyzer.scope_owner_map,
        analyzer.references.items,
        analyzer.symbol_ids.items,
        analyzer.helper_scope_map,
    );
    defer editor.deinit();
    var owners = analyzer.scope_owner_map.iterator();
    var first_key: ?u32 = null;
    var second_key: ?u32 = null;
    while (owners.next()) |owner| {
        if (transformer.ast.nodes.items[owner.key_ptr.*].tag != .function_declaration) continue;
        if (first_key == null) first_key = owner.key_ptr.* else second_key = owner.key_ptr.*;
    }
    const first_owner: @import("../parser/ast.zig").NodeIndex = @enumFromInt(first_key.?);
    const second_owner: @import("../parser/ast.zig").NodeIndex = @enumFromInt(second_key.?);
    const first_scope = analyzer.scope_owner_map.get(first_key.?).?;
    const second_scope = analyzer.scope_owner_map.get(second_key.?).?;
    try std.testing.expectError(error.ScopeOwnerConflict, editor.remapScopeOwner(first_owner, second_owner));
    try std.testing.expectEqual(first_scope, editor.scope_owner_map.get(first_key.?).?);
    try std.testing.expectEqual(second_scope, editor.scope_owner_map.get(second_key.?).?);
    const unrelated = try transformer.ast.addNode(.{
        .tag = .identifier_reference,
        .span = .EMPTY,
        .data = .{ .string_ref = try transformer.ast.addString("unrelated") },
    });
    try std.testing.expectError(error.InvalidNode, editor.remapScopeOwner(first_owner, unrelated));
    try std.testing.expectEqual(first_scope, editor.scope_owner_map.get(first_key.?).?);
    var remaps = transformer.scope_owner_remaps.iterator();
    while (remaps.next()) |entry| {
        const old: @import("../parser/ast.zig").NodeIndex = @enumFromInt(entry.key_ptr.*);
        const new: @import("../parser/ast.zig").NodeIndex = @enumFromInt(entry.value_ptr.*);
        const original_scope = analyzer.scope_owner_map.get(entry.key_ptr.*).?;
        try editor.remapScopeOwner(old, new);
        try std.testing.expectEqual(@as(?u32, original_scope), editor.scope_owner_map.get(entry.value_ptr.*));
        try std.testing.expectEqual(@as(?u32, null), editor.scope_owner_map.get(entry.key_ptr.*));
    }
}

/// es5 로 변환한 뒤 새로 만든 사용자 식별자 중 심볼이 없는 노드 수.
fn missingSymbols(source: []const u8) !usize {
    return missingSymbolsFor(source, .es5);
}

fn missingSymbolsFor(source: []const u8, target: TransformOptions.compat.ESTarget) !usize {
    return (try countsFor(source, target)).missing;
}

const Counts = struct { missing: usize, wrong: usize };

fn countsFor(source: []const u8, target: TransformOptions.compat.ESTarget) !Counts {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var scanner = try Scanner.init(allocator, source);
    var parser = Parser.init(allocator, &scanner);
    parser.configureFromExtension(".mjs");
    _ = try parser.parse();

    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    analyzer.is_strict_mode = parser.is_strict_mode;
    analyzer.is_module = parser.is_module;
    try analyzer.analyze();

    var transformer = try Transformer.init(allocator, &parser.ast, .{
        .unsupported = TransformOptions.compat.fromESTarget(target),
    });
    try transformer.initSymbolIds(analyzer.symbol_ids.items);
    transformer.symbols = analyzer.symbols.items;
    transformer.references = analyzer.references.items;
    transformer.synthetic_idents = .empty;
    const root = try transformer.transform();

    var report = try coverage.check(allocator, transformer.ast, root, transformer.parser_node_count, transformer.symbol_ids.items, analyzer.symbols.items, if (transformer.synthetic_idents) |*s| s else null);
    defer report.deinit(allocator);
    try std.testing.expect(report.new_user_idents > 0);
    return .{ .missing = report.missing.items.len, .wrong = report.wrong.items.len };
}

test "#4762 es5 기본값 매개변수 검사의 참조는 매개변수 심볼을 가진다" {
    try std.testing.expectEqual(@as(usize, 0), try missingSymbols(
        \\export function f(alpha, opts = { k: 2 }) { return alpha + opts.k; }
    ));
}

test "#4760 es5 상태 기계가 대입·선언으로 접은 바인딩은 원래 심볼을 가진다" {
    try std.testing.expectEqual(@as(usize, 0), try missingSymbols(
        \\export function* gen(items) {
        \\  for (const value of items) {
        \\    const doubled = yield value;
        \\    record(doubled);
        \\  }
        \\}
    ));
    // catch 파라미터·블록 구조분해 선언은 이름만 모아 `name$N` 으로 바꾸는 경로로 올라간다.
    try std.testing.expectEqual(@as(usize, 0), try missingSymbols(
        \\export function* gen2(source) {
        \\  try { yield 1; } catch (failure) { record(failure); }
        \\  { const { first, second } = source; yield first; record(second); }
        \\}
    ));
}

test "#4760 es5 루프 캡처 `_loop` 의 매개변수·인자·끌어올린 var 는 원래 심볼을 가진다" {
    try std.testing.expectEqual(@as(usize, 0), try missingSymbols(
        \\export function collect(limit) {
        \\  const getters = [];
        \\  for (let index = 0; index < limit; index++) {
        \\    var latest = index * 2;
        \\    getters.push(() => index + latest);
        \\  }
        \\  return getters;
        \\}
    ));
}

test "#4819 generated loop binding and call share one appended SymbolId" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var scanner = try Scanner.init(allocator,
        \\export function collect(limit) {
        \\  const _loop = 7;
        \\  const getters = [];
        \\  for (let index = 0; index < limit; index++) getters.push(() => index + _loop);
        \\  return getters;
        \\}
    );
    var parser = Parser.init(allocator, &scanner);
    parser.configureFromExtension(".mjs");
    _ = try parser.parse();
    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    analyzer.is_module = true;
    try analyzer.analyze();
    const original_symbols = analyzer.symbols.items.len;

    var transformer = try Transformer.init(allocator, &parser.ast, .{
        .unsupported = TransformOptions.compat.fromESTarget(.es5),
    });
    try transformer.initSymbolIds(analyzer.symbol_ids.items);
    transformer.symbols = analyzer.symbols.items;
    transformer.references = analyzer.references.items;
    transformer.scopes = analyzer.scopes.items;
    transformer.scope_maps = analyzer.scope_maps.items;
    transformer.scope_owner_map = analyzer.scope_owner_map;
    transformer.semantic_edit_enabled = true;
    _ = try transformer.transform();
    const edited = (try transformer.finishSemanticEdit()).?;
    try std.testing.expectEqual(original_symbols + 1, edited.symbols.items.len);
    const generated_id: u32 = @intCast(original_symbols);
    try std.testing.expectEqualStrings("_loop2", transformer.ast.getText(edited.symbols.items[generated_id].name));
    var bindings: usize = 0;
    var calls: usize = 0;
    for (edited.symbol_ids, 0..) |maybe_id, i| {
        if (maybe_id != generated_id) continue;
        switch (transformer.ast.nodes.items[i].tag) {
            .binding_identifier => bindings += 1,
            .identifier_reference => calls += 1,
            else => {},
        }
    }
    try std.testing.expectEqual(@as(usize, 1), bindings);
    try std.testing.expect(calls >= 1);
    try std.testing.expectEqual(@as(u32, 1), edited.symbols.items[generated_id].reference_count);

    var index_id: ?u32 = null;
    for (analyzer.symbols.items, 0..) |sym, i| {
        if (std.mem.eql(u8, sym.nameText(parser.ast.source), "index")) index_id = @intCast(i);
    }
    const header_id = index_id orelse return error.TestUnexpectedResult;
    var loop_arg: ?@import("../parser/ast.zig").NodeIndex = null;
    for (transformer.ast.nodes.items) |node| {
        if (node.tag != .call_expression) continue;
        const extra = transformer.ast.extra_data.items;
        const e = node.data.extra;
        const callee: @import("../parser/ast.zig").NodeIndex = @enumFromInt(extra[e]);
        if (transformer.ast.getNode(callee).tag != .identifier_reference) continue;
        if (!std.mem.eql(u8, transformer.ast.getText(transformer.ast.getNode(callee).data.string_ref), "_loop2")) continue;
        if (extra[e + 2] != 1) continue;
        loop_arg = @enumFromInt(extra[extra[e + 1]]);
    }
    const argument = loop_arg orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(?u32, header_id), edited.symbol_ids[@intFromEnum(argument)]);
    var argument_refs: usize = 0;
    for (edited.references) |ref| {
        if (ref.node_index != argument) continue;
        try std.testing.expectEqual(header_id, @intFromEnum(ref.symbol_id));
        try std.testing.expect(ref.flags.read);
        try std.testing.expect(!ref.flags.write and !ref.flags.declare);
        argument_refs += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), argument_refs);
}

test "#4819 tagged template helpers keep distinct function and data scopes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var scanner = try Scanner.init(allocator,
        \\const _templateObject = 1, _templateObject2 = 2, data = 3;
        \\function tag(strings) { return strings[0]; }
        \\function nested() { return tag`one`; }
        \\console.log(nested(), tag`two`, _templateObject, _templateObject2, data);
    );
    var parser = Parser.init(allocator, &scanner);
    parser.configureFromExtension(".mjs");
    _ = try parser.parse();
    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    analyzer.is_module = true;
    try analyzer.analyze();
    const original_symbols = analyzer.symbols.items.len;
    const original_scopes = analyzer.scopes.items.len;

    var transformer = try Transformer.init(allocator, &parser.ast, .{
        .unsupported = TransformOptions.compat.fromESTarget(.es5),
    });
    try transformer.initSymbolIds(analyzer.symbol_ids.items);
    transformer.symbols = analyzer.symbols.items;
    transformer.references = analyzer.references.items;
    transformer.scopes = analyzer.scopes.items;
    transformer.scope_maps = analyzer.scope_maps.items;
    transformer.scope_owner_map = analyzer.scope_owner_map;
    transformer.semantic_edit_enabled = true;
    _ = try transformer.transform();
    const edited = (try transformer.finishSemanticEdit()).?;
    try std.testing.expectEqual(original_symbols + 4, edited.symbols.items.len);
    try std.testing.expectEqual(original_scopes + 4, edited.scopes.len);
    for (0..2) |i| {
        const fn_id = original_symbols + i * 2;
        const data_id = fn_id + 1;
        const fn_symbol = edited.symbols.items[fn_id];
        const data_symbol = edited.symbols.items[data_id];
        try std.testing.expectEqual(@import("../semantic/symbol.zig").SymbolKind.function_decl, fn_symbol.kind);
        try std.testing.expectEqual(@import("../semantic/symbol.zig").SymbolKind.variable_var, data_symbol.kind);
        try std.testing.expectEqualStrings(if (i == 0) "_templateObject3" else "_templateObject4", transformer.ast.getText(fn_symbol.name));
        try std.testing.expectEqualStrings("data", transformer.ast.getText(data_symbol.name));
        try std.testing.expectEqual(transformer.programScope(), fn_symbol.scope_id);
        try std.testing.expectEqual(fn_symbol.scope_id, edited.scopes[data_symbol.scope_id.toIndex()].parent);
        try std.testing.expectEqual(@as(u32, 2), fn_symbol.reference_count);
        try std.testing.expectEqual(@as(u32, 1), fn_symbol.write_count);
        try std.testing.expectEqual(@as(u32, 2), data_symbol.reference_count);
        var nested_data_refs: usize = 0;
        for (edited.references) |ref| {
            if (@intFromEnum(ref.symbol_id) != data_id or !ref.flags.read) continue;
            if (ref.scope_id != data_symbol.scope_id) {
                try std.testing.expectEqual(data_symbol.scope_id, edited.scopes[ref.scope_id.toIndex()].parent);
                nested_data_refs += 1;
            }
        }
        try std.testing.expectEqual(@as(usize, 1), nested_data_refs);
    }
}

test "#4819 decorator access functions own separate parameter symbols" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var scanner = try Scanner.init(allocator,
        \\const obj = 7, value = 8;
        \\function dec(v, context) { return v; }
        \\class C { @dec first = 1; @dec second = 2; }
        \\console.log(obj, value, new C().first);
    );
    var parser = Parser.init(allocator, &scanner);
    parser.configureFromExtension(".ts");
    _ = try parser.parse();
    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    analyzer.is_module = true;
    try analyzer.analyze();
    const original_symbols = analyzer.symbols.items.len;
    const original_scopes = analyzer.scopes.items.len;

    var transformer = try Transformer.init(allocator, &parser.ast, .{});
    try transformer.initSymbolIds(analyzer.symbol_ids.items);
    transformer.symbols = analyzer.symbols.items;
    transformer.references = analyzer.references.items;
    transformer.scopes = analyzer.scopes.items;
    transformer.scope_maps = analyzer.scope_maps.items;
    transformer.scope_owner_map = analyzer.scope_owner_map;
    transformer.semantic_edit_enabled = true;
    _ = try transformer.transform();
    const edited = (try transformer.finishSemanticEdit()).?;
    var access_params: usize = 0;
    var access_scope_ids: std.AutoHashMapUnmanaged(u32, void) = .empty;
    for (edited.symbols.items[original_symbols..], original_symbols..) |symbol, id| {
        if (symbol.kind != .parameter) continue;
        const name = transformer.ast.getText(symbol.name);
        if (!std.mem.eql(u8, name, "obj") and !std.mem.eql(u8, name, "value")) continue;
        access_params += 1;
        try std.testing.expect(symbol.scope_id.toIndex() >= original_scopes);
        try std.testing.expectEqual(@as(u32, 1), symbol.reference_count);
        var bindings: usize = 0;
        var refs: usize = 0;
        const generated_id: u32 = @intCast(id);
        for (edited.symbol_ids, 0..) |maybe_id, i| {
            if (maybe_id != generated_id) continue;
            switch (transformer.ast.nodes.items[i].tag) {
                .binding_identifier => bindings += 1,
                .identifier_reference => refs += 1,
                else => {},
            }
        }
        try std.testing.expectEqual(@as(usize, 1), bindings);
        try std.testing.expectEqual(@as(usize, 1), refs);
        try access_scope_ids.put(allocator, symbol.scope_id.toIndex(), {});
    }
    try std.testing.expectEqual(@as(usize, 8), access_params);
    try std.testing.expectEqual(@as(usize, 6), access_scope_ids.count());
}

test "#4819 runtime helper calls bind isolated import symbols before resync" {
    const cases = [_]struct { src: []const u8, local: []const u8, minify: bool, inside_function: bool = false }{
        .{ .src = "const __extends = 'shadow'; export class Child extends Object {} console.log(__extends);", .local = "__extends", .minify = false },
        .{ .src = "const $eX = 'shadow'; export class Child extends Object {} console.log($eX);", .local = "$eX", .minify = true },
        .{ .src = "const __rest = 'shadow'; function pick({a, ...rest}) { return rest.b; } console.log(pick({a: 1, b: 2}), __rest);", .local = "__rest", .minify = false, .inside_function = true },
    };
    for (cases) |case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        var scanner = try Scanner.init(allocator, case.src);
        var parser = Parser.init(allocator, &scanner);
        parser.configureFromExtension(".mjs");
        _ = try parser.parse();
        var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
        analyzer.is_module = true;
        try analyzer.analyze();
        const user_id = analyzer.scope_maps.items[0].get(case.local).?;

        var transformer = try Transformer.init(allocator, &parser.ast, .{
            .unsupported = TransformOptions.compat.fromESTarget(.es5),
            .emit_runtime_helper_imports = true,
            .minify_whitespace = case.minify,
        });
        try transformer.initSymbolIds(analyzer.symbol_ids.items);
        transformer.symbols = analyzer.symbols.items;
        transformer.references = analyzer.references.items;
        transformer.scopes = analyzer.scopes.items;
        transformer.scope_maps = analyzer.scope_maps.items;
        transformer.scope_owner_map = analyzer.scope_owner_map;
        transformer.semantic_edit_enabled = true;
        _ = try transformer.transform();
        const edited = (try transformer.finishSemanticEdit()).?;
        const helper_id = edited.helper_scope_map.get(case.local).?;
        try std.testing.expect(helper_id != user_id);
        try std.testing.expectEqual(@as(?usize, user_id), edited.scope_maps[0].get(case.local));
        try std.testing.expectEqual(@import("../semantic/symbol.zig").SymbolKind.import_binding, edited.symbols.items[helper_id].kind);
        try std.testing.expect(edited.symbols.items[helper_id].reference_count >= 1);
        var bound_refs: usize = 0;
        for (edited.references) |ref| {
            if (@intFromEnum(ref.symbol_id) != helper_id or !ref.flags.read) continue;
            try std.testing.expectEqual(@as(?u32, @intCast(helper_id)), edited.symbol_ids[@intFromEnum(ref.node_index)]);
            if (case.inside_function) try std.testing.expectEqual(@import("../semantic/scope.zig").ScopeKind.function, edited.scopes[ref.scope_id.toIndex()].kind);
            bound_refs += 1;
        }
        try std.testing.expect(bound_refs >= 1);
        try std.testing.expectEqual(@as(usize, 0), transformer.pending_runtime_helper_chains.count());
    }
}

test "#4819 optional catch binding gets a symbol in its catch scope" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var scanner = try Scanner.init(allocator, "const _a = 9; try { throw 1; } catch { console.log(_a); } try { throw 2; } catch { console.log(_a); }");
    var parser = Parser.init(allocator, &scanner);
    parser.configureFromExtension(".mjs");
    _ = try parser.parse();
    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    analyzer.is_module = true;
    try analyzer.analyze();
    const original_symbols = analyzer.symbols.items.len;

    var transformer = try Transformer.init(allocator, &parser.ast, .{
        .unsupported = TransformOptions.compat.fromESTarget(.es5),
    });
    try transformer.initSymbolIds(analyzer.symbol_ids.items);
    transformer.symbols = analyzer.symbols.items;
    transformer.references = analyzer.references.items;
    transformer.scopes = analyzer.scopes.items;
    transformer.scope_maps = analyzer.scope_maps.items;
    transformer.scope_owner_map = analyzer.scope_owner_map;
    transformer.semantic_edit_enabled = true;
    _ = try transformer.transform();
    const edited = (try transformer.finishSemanticEdit()).?;
    try std.testing.expectEqual(original_symbols + 2, edited.symbols.items.len);
    try std.testing.expect(edited.symbols.items[original_symbols].scope_id != edited.symbols.items[original_symbols + 1].scope_id);
    for (edited.symbols.items[original_symbols..]) |generated| {
        try std.testing.expectEqual(@import("../semantic/symbol.zig").SymbolKind.catch_binding, generated.kind);
        try std.testing.expectEqual(@import("../semantic/scope.zig").ScopeKind.catch_clause, edited.scopes[generated.scope_id.toIndex()].kind);
        try std.testing.expectEqualStrings("_b", transformer.ast.getText(generated.name));
        try std.testing.expectEqual(@as(u32, 0), generated.reference_count);
    }
    var bindings: usize = 0;
    for (edited.symbol_ids, 0..) |maybe_id, i| {
        if (maybe_id != null and maybe_id.? >= original_symbols and transformer.ast.nodes.items[i].tag == .binding_identifier) bindings += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), bindings);
}

test "#4760 static private 멤버를 낮출 때 만드는 클래스 참조는 클래스 심볼을 가진다" {
    // `Counter.#count` → `__classStaticPrivateFieldSpecGet(Counter, Counter, _count)` 의 클래스
    // 참조는 매핑에 이름만 있어 심볼이 없었다.
    try std.testing.expectEqual(@as(usize, 0), try missingSymbolsFor(
        \\export class Counter {
        \\  static #count = 0;
        \\  static #bump() { return ++Counter.#count; }
        \\  static run(other) { return #count in other ? Counter.#bump() : Counter.#count; }
        \\}
    , .es2020));
}

test "#4760 모듈 최상위 using 이 export 를 지정자로 바꿀 때 로컬 참조는 원래 심볼을 가진다" {
    try std.testing.expectEqual(@as(usize, 0), try missingSymbolsFor(
        \\using handle = open();
        \\export class Service { run() { return handle; } }
        \\export const { first, second } = handle;
        \\export default class Main {}
    , .es2022));
}

test "#4763 es5 클래스의 _super 참조는 부모 클래스 심볼을 갖지 않는다" {
    // es5 는 부모를 IIFE 매개변수 `_super` 로 넘긴다. `super.x()` 를 낮춘 `_super` 참조에 부모
    // 클래스의 심볼이 붙으면, 심볼 기준 리네임이 `_super` 대신 바깥 부모 바인딩을 가리킨다.
    const c = try countsFor(
        \\let Parent = class { hello() { return 'A'; } };
        \\export class Child extends Parent {
        \\  constructor() { super(); }
        \\  run() { return super.hello(); }
        \\  static make() { return super.name; }
        \\}
    , .es5);
    try std.testing.expectEqual(@as(usize, 0), c.wrong);
}

test "#4760 클래스 낮추기가 클래스·함수 이름을 span 으로 가리켜도 원래 심볼을 가진다" {
    // 클래스 이름·정적 메서드 수신자·new.target 함수 이름은 낮추기 함수 사이에 span 으로만
    // 전달된다. 지금 낮추는 클래스(`current_class_name_node`)·함수 노드에서 심볼을 얻는다.
    const src =
        \\export class Counter {
        \\  static #count = 0;
        \\  static total = 1;
        \\  static #bump() { return ++Counter.#count; }
        \\  static run(other) { return #count in other ? Counter.#bump() : Counter.#count + Counter.total; }
        \\}
        \\export const Named = class Inner { static who() { return Inner.name; } static base = 2; };
        \\export class Child extends Counter { static make() { return super.run(this); } }
        \\export function Ctor() { return new.target; }
    ;
    for ([_]TransformOptions.compat.ESTarget{ .es5, .es2015, .es2020 }) |target| {
        const c = try countsFor(src, target);
        try std.testing.expectEqual(@as(usize, 0), c.missing);
        try std.testing.expectEqual(@as(usize, 0), c.wrong);
    }
}

test "#4819 static private initializer this uses the active class symbol" {
    const src =
        \\class A {
        \\  static y = 1;
        \\  static #x = () => this.y;
        \\  static get() { return A.#x(); }
        \\}
        \\function nested() {
        \\  class A {
        \\    static y = 2;
        \\    static #x = () => this.y;
        \\    static get() { return A.#x(); }
        \\  }
        \\  return A.get();
        \\}
        \\console.log(A.get(), nested());
    ;
    for ([_]TransformOptions.compat.ESTarget{ .es5, .es2015, .es2017 }) |target| {
        const c = try countsFor(src, target);
        try std.testing.expectEqual(@as(usize, 0), c.missing);
        try std.testing.expectEqual(@as(usize, 0), c.wrong);
    }
}
