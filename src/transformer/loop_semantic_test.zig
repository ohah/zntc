const std = @import("std");
const Scanner = @import("../lexer/scanner.zig").Scanner;
const Parser = @import("../parser/parser.zig").Parser;
const SemanticAnalyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer;
const transformer_mod = @import("transformer.zig");
const Transformer = transformer_mod.Transformer;
const TransformOptions = transformer_mod.TransformOptions;

/// `_loop(...)`의 각 인자는 원본 헤더 심볼을 읽으며, 그 심볼이 인자 스코프에서
/// 보여야 한다. AST 전체에서 호출을 찾으므로 unreachable 생성 노드도 검사한다.
fn expectExtractedLoopArgumentsVisible(source: []const u8, expected_args: u32) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var scanner = try Scanner.init(allocator, source);
    var parser = Parser.init(allocator, &scanner);
    parser.configureFromExtension(".mjs");
    _ = try parser.parse();

    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    analyzer.is_module = true;
    try analyzer.analyze();

    var transformer = try Transformer.init(allocator, &parser.ast, .{
        .unsupported = TransformOptions.compat.fromESTarget(.es5),
    });
    try transformer.initSymbolIds(analyzer.symbol_ids.items);
    transformer.symbols = analyzer.symbols.items;
    transformer.references = analyzer.references.items;
    transformer.scopes = analyzer.scopes.items;
    transformer.scope_maps = analyzer.scope_maps.items;
    transformer.scope_owner_map = analyzer.scope_owner_map;
    transformer.unresolved_references = &analyzer.unresolved_references;
    transformer.semantic_edit_enabled = true;
    _ = try transformer.transform();
    const edited = (try transformer.finishSemanticEdit()).?;

    var found = false;
    for (transformer.ast.nodes.items) |node| {
        if (node.tag != .call_expression) continue;
        const extra = transformer.ast.extra_data.items;
        const e = node.data.extra;
        var callee: @import("../parser/ast.zig").NodeIndex = @enumFromInt(extra[e]);
        var first_arg: u32 = 0;
        if (transformer.ast.getNode(callee).tag == .static_member_expression) {
            const member = transformer.ast.getNode(callee).data.extra;
            const property = transformer.ast.getNode(@enumFromInt(extra[member + 1]));
            if (!std.mem.eql(u8, transformer.ast.getText(property.data.string_ref), "call")) continue;
            callee = @enumFromInt(extra[member]);
            first_arg = 1;
        }
        const callee_node = transformer.ast.getNode(callee);
        if (callee_node.tag != .identifier_reference) continue;
        if (!std.mem.startsWith(u8, transformer.ast.getText(callee_node.data.string_ref), "_loop")) continue;
        const args_start = extra[e + 1];
        const args_len = extra[e + 2];
        if (args_len != expected_args + first_arg) continue;
        found = true;
        var callee_refs: usize = 0;
        for (edited.references) |ref| {
            if (ref.node_index != callee) continue;
            try std.testing.expectEqual(edited.symbol_ids[@intFromEnum(callee)].?, @intFromEnum(ref.symbol_id));
            try std.testing.expect(ref.flags.read and !ref.flags.write and !ref.flags.declare);
            callee_refs += 1;
        }
        try std.testing.expectEqual(@as(usize, 1), callee_refs);

        for (first_arg..args_len) |offset| {
            const arg: @import("../parser/ast.zig").NodeIndex = @enumFromInt(extra[@as(usize, args_start) + offset]);
            const sym_idx = edited.symbol_ids[@intFromEnum(arg)] orelse return error.TestUnexpectedResult;
            var ref_scope: ?@import("../semantic/scope.zig").ScopeId = null;
            var ref_count: usize = 0;
            for (edited.references) |ref| {
                if (ref.node_index != arg) continue;
                try std.testing.expectEqual(sym_idx, @intFromEnum(ref.symbol_id));
                try std.testing.expect(ref.flags.read and !ref.flags.write and !ref.flags.declare);
                ref_scope = ref.scope_id;
                ref_count += 1;
            }
            try std.testing.expectEqual(@as(usize, 1), ref_count);
            // 이미 현재 출력 이름으로 만든 인자는 재방문 후에도 같은 노드다.
            try std.testing.expectEqual(@as(?u32, null), transformer.reference_origin_map.get(@intFromEnum(arg)));
            var scope = ref_scope orelse return error.TestUnexpectedResult;
            try std.testing.expectEqual(edited.symbols.items[sym_idx].scope_id, scope);
            var visible = false;
            for (0..edited.scopes.len) |_| {
                if (scope.isNone() or scope.toIndex() >= edited.scopes.len) break;
                if (scope == edited.symbols.items[sym_idx].scope_id) {
                    visible = true;
                    break;
                }
                scope = edited.scopes[scope.toIndex()].parent;
            }
            try std.testing.expect(visible);
        }
    }
    try std.testing.expect(found);
}

test "#4819 generator extracted loop argument remains in header binding scope" {
    try expectExtractedLoopArgumentsVisible(
        \\export function* collect() {
        \\  for (let index = 0; index < 2; index++) {
        \\    yield () => index;
        \\  }
        \\}
    , 1);
}

test "#4819 generator extracted loop keeps two header arguments visible" {
    try expectExtractedLoopArgumentsVisible(
        \\export function* collect() {
        \\  for (let index = 0, offset = 10; index < 2; index++, offset--) {
        \\    yield () => index + offset;
        \\  }
        \\}
    , 2);
}

test "#4819 classic for keeps two extracted header arguments visible" {
    try expectExtractedLoopArgumentsVisible(
        \\export function collect() {
        \\  const readers = [];
        \\  for (let index = 0, offset = 10; index < 2; index++, offset--) {
        \\    readers.push(() => index + offset);
        \\  }
        \\  return readers;
        \\}
    , 2);
}

test "#4819 for-in extracted header argument remains visible" {
    try expectExtractedLoopArgumentsVisible(
        \\export function collect(object) {
        \\  const readers = [];
        \\  for (const key in object) readers.push(() => key);
        \\  return readers;
        \\}
    , 1);
}

test "#4819 for-of lowering extracts captured body binding" {
    try expectExtractedLoopArgumentsVisible(
        \\export function collect(values) {
        \\  const readers = [];
        \\  for (const value of values) readers.push(() => value);
        \\  return readers;
        \\}
    , 0);
}

test "#4819 while extracts captured body binding" {
    try expectExtractedLoopArgumentsVisible(
        \\export function collect() {
        \\  const readers = [];
        \\  let index = 0;
        \\  while (index < 2) {
        \\    let value = index++;
        \\    readers.push(() => value);
        \\  }
        \\  return readers;
        \\}
    , 0);
}

test "#4819 generator extracted loop keeps shadowed header identity" {
    try expectExtractedLoopArgumentsVisible(
        \\export function* collect(index) {
        \\  for (let index = 0; index < 2; index++) yield () => index;
        \\  yield index;
        \\}
    , 1);
}

test "#4819 generator for-in lowering extracts captured body binding" {
    try expectExtractedLoopArgumentsVisible(
        \\export function* collect(object) {
        \\  for (const key in object) yield () => key;
        \\}
    , 0);
}

test "#4819 generator for-of extracts captured body binding" {
    try expectExtractedLoopArgumentsVisible(
        \\export function* collect(values) {
        \\  for (const value of values) yield () => value;
        \\}
    , 0);
}

test "#4819 generator do-while extracts captured body binding" {
    try expectExtractedLoopArgumentsVisible(
        \\export function* collect() {
        \\  let index = 0;
        \\  do { let value = index++; yield () => value; } while (index < 2);
        \\}
    , 0);
}

test "#4819 generator extracted loop preserves this call argument identity" {
    try expectExtractedLoopArgumentsVisible(
        \\export function* collect() {
        \\  for (let index = 0; index < 2; index++) yield () => this.base + index;
        \\}
    , 1);
}

test "#4819 generator while extracts captured body binding" {
    try expectExtractedLoopArgumentsVisible(
        \\export function* collect() {
        \\  let index = 0;
        \\  while (index < 2) { let value = index++; yield () => value; }
        \\}
    , 0);
}

test "#4819 generator nested extracted loop retains copied header scope" {
    try expectExtractedLoopArgumentsVisible(
        \\export function* collect(values) {
        \\  for (const value of values) {
        \\    const readers = [];
        \\    for (let index = 0; index < 1; index++) {
        \\      readers.push(() => index + value);
        \\      if (value > 9) return 'stop';
        \\    }
        \\    yield readers[0]();
        \\  }
        \\}
    , 1);
}
