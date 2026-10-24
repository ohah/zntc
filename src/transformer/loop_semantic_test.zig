const std = @import("std");
const Scanner = @import("../lexer/scanner.zig").Scanner;
const Parser = @import("../parser/parser.zig").Parser;
const SemanticAnalyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer;
const transformer_mod = @import("transformer.zig");
const Transformer = transformer_mod.Transformer;
const TransformOptions = transformer_mod.TransformOptions;
const Ast = @import("../parser/ast.zig").Ast;
const NodeIndex = @import("../parser/ast.zig").NodeIndex;
const ScopeId = @import("../semantic/scope.zig").ScopeId;
const Reference = @import("../semantic/symbol.zig").Reference;
const ast_walk = @import("../parser/ast_walk.zig");
const symbol_coverage = @import("symbol_coverage.zig");
const output_scope = @import("output_scope_test_utils.zig");

fn findLoopFunctionBody(allocator: std.mem.Allocator, ast: *const Ast, root: NodeIndex) !NodeIndex {
    var stack: std.ArrayList(NodeIndex) = .empty;
    var seen: std.AutoHashMapUnmanaged(u32, void) = .empty;
    try stack.append(allocator, root);
    while (stack.pop()) |idx| {
        if (idx.isNone() or @backingInt(idx) >= ast.nodes.items.len) continue;
        const raw = @backingInt(idx);
        if (seen.contains(raw)) continue;
        try seen.put(allocator, raw, {});
        const node = ast.getNode(idx);
        if (node.tag == .variable_declarator) {
            const binding = ast.getNode(@fromBackingInt(@intCast(ast.extra_data.items[node.data.extra])));
            const init: NodeIndex = @fromBackingInt(@intCast(ast.extra_data.items[node.data.extra + 2]));
            const name = if (binding.tag == .binding_identifier) ast.getText(binding.data.string_ref) else "";
            if (binding.tag == .binding_identifier and !init.isNone() and
                (std.mem.startsWith(u8, name, "_loop") or std.mem.startsWith(u8, name, "__zntc_loop")) and
                ast.getNode(init).tag == .function_expression)
            {
                return @fromBackingInt(@intCast(ast.extra_data.items[ast.getNode(init).data.extra + 2]));
            }
        }
        var it = ast_walk.children(ast, node);
        while (it.next()) |child| try stack.append(allocator, child);
    }
    return error.TestUnexpectedResult;
}

test "#4819 loop body owner follows control-flow and var-hoist copies" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source =
        \\function collect() {
        \\  var out = [];
        \\  for (let i = 0; i < 2; i++) {
        \\    var lifted = i;
        \\    if (i) { out.push(() => lifted + i); continue; }
        \\    out.push(() => lifted + i);
        \\  }
        \\  return out;
        \\}
    ;
    var scanner = try Scanner.init(allocator, source);
    var parser = Parser.init(allocator, &scanner);
    _ = try parser.parse();
    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    try analyzer.analyze();

    var original_body: NodeIndex = .none;
    var nested_block: NodeIndex = .none;
    for (parser.ast.nodes.items) |node| {
        if (node.tag == .for_statement) {
            original_body = @fromBackingInt(@intCast(parser.ast.extra_data.items[node.data.extra + 3]));
        } else if (node.tag == .if_statement and parser.ast.getNode(node.data.ternary.b).tag == .block_statement) {
            nested_block = node.data.ternary.b;
        }
    }
    try std.testing.expect(!original_body.isNone() and !nested_block.isNone());
    const body_scope = analyzer.scope_owner_map.get(@backingInt(original_body)).?;
    const nested_scope = analyzer.scope_owner_map.get(@backingInt(nested_block)).?;

    var transformer = try Transformer.init(allocator, &parser.ast, .{
        .unsupported = TransformOptions.compat.fromESTarget(.es5),
    });
    try transformer.initSymbolIds(analyzer.symbol_ids.items);
    transformer.symbols = analyzer.symbols.items;
    transformer.class_self_symbol_map = analyzer.class_self_symbol_map;
    transformer.references = analyzer.references.items;
    transformer.scopes = analyzer.scopes.items;
    transformer.scope_maps = analyzer.scope_maps.items;
    transformer.scope_owner_map = analyzer.scope_owner_map;
    transformer.node_scope_provenance = analyzer.node_scope_provenance;
    transformer.unresolved_references = &analyzer.unresolved_references;
    transformer.semantic_edit_enabled = true;
    const root = try transformer.transform();
    const final_body = try findLoopFunctionBody(allocator, transformer.ast, root);
    const edited = (try transformer.finishSemanticEdit()).?;
    try std.testing.expectEqual(@as(?u32, body_scope), edited.scope_owner_map.get(@backingInt(final_body)));
    try std.testing.expect(edited.scope_owner_map.get(@backingInt(original_body)) == null);

    var reachable: std.AutoHashMapUnmanaged(u32, void) = .empty;
    var stack: std.ArrayList(NodeIndex) = .empty;
    try stack.append(allocator, final_body);
    while (stack.pop()) |idx| {
        if (idx.isNone() or @backingInt(idx) >= transformer.ast.nodes.items.len) continue;
        const raw = @backingInt(idx);
        if (reachable.contains(raw)) continue;
        try reachable.put(allocator, raw, {});
        var it = ast_walk.children(transformer.ast, transformer.ast.getNode(idx));
        while (it.next()) |child| try stack.append(allocator, child);
    }
    var nested_owner_reachable = false;
    var owners = edited.scope_owner_map.iterator();
    while (owners.next()) |entry| {
        if (entry.value_ptr.* == nested_scope and reachable.contains(entry.key_ptr.*)) nested_owner_reachable = true;
    }
    try std.testing.expect(nested_owner_reachable);
}

test "#4819 arrow-to-function copy retains the analyzed function scope owner" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var scanner = try Scanner.init(allocator, "function outer(value) { const read = () => value; return read; }");
    var parser = Parser.init(allocator, &scanner);
    _ = try parser.parse();
    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    try analyzer.analyze();
    var arrow: NodeIndex = .none;
    for (parser.ast.nodes.items, 0..) |node, i| {
        if (node.tag == .arrow_function_expression) arrow = @fromBackingInt(@intCast(@as(u32, @intCast(i))));
    }
    try std.testing.expect(!arrow.isNone());
    const scope = analyzer.scope_owner_map.get(@backingInt(arrow)).?;
    var transformer = try Transformer.init(allocator, &parser.ast, .{
        .unsupported = TransformOptions.compat.fromESTarget(.es5),
    });
    try transformer.initSymbolIds(analyzer.symbol_ids.items);
    transformer.symbols = analyzer.symbols.items;
    transformer.class_self_symbol_map = analyzer.class_self_symbol_map;
    transformer.references = analyzer.references.items;
    transformer.scopes = analyzer.scopes.items;
    transformer.scope_maps = analyzer.scope_maps.items;
    transformer.scope_owner_map = analyzer.scope_owner_map;
    transformer.node_scope_provenance = analyzer.node_scope_provenance;
    transformer.unresolved_references = &analyzer.unresolved_references;
    transformer.semantic_edit_enabled = true;
    _ = try transformer.transform();
    const edited = (try transformer.finishSemanticEdit()).?;
    var replacement: ?u32 = null;
    var owners = edited.scope_owner_map.iterator();
    while (owners.next()) |entry| {
        if (entry.value_ptr.* == scope) replacement = entry.key_ptr.*;
    }
    try std.testing.expect(replacement != null);
    try std.testing.expect(replacement.? != @backingInt(arrow));
    try std.testing.expectEqual(@import("../parser/ast.zig").Node.Tag.function_expression, transformer.ast.nodes.items[replacement.?].tag);
}

test "#4819 generated function owner follows reversed revisits independently" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var scanner = try Scanner.init(allocator, "");
    var parser = Parser.init(allocator, &scanner);
    _ = try parser.parse();
    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    try analyzer.analyze();
    var transformer = try Transformer.init(allocator, &parser.ast, .{});
    try transformer.initSymbolIds(analyzer.symbol_ids.items);
    transformer.symbols = analyzer.symbols.items;
    transformer.class_self_symbol_map = analyzer.class_self_symbol_map;
    transformer.references = analyzer.references.items;
    transformer.scopes = analyzer.scopes.items;
    transformer.scope_maps = analyzer.scope_maps.items;
    transformer.scope_owner_map = analyzer.scope_owner_map;
    transformer.node_scope_provenance = analyzer.node_scope_provenance;
    transformer.semantic_edit_enabled = true;
    const root = try transformer.transform();
    const parent = transformer.programScope();
    var generated: [2]NodeIndex = undefined;
    var scopes: [2]@import("../semantic/scope.zig").ScopeId = undefined;
    for (0..2) |i| {
        const empty = try transformer.ast.addNodeList(&.{});
        const params = try transformer.ast.addFormalParameters(empty, .EMPTY);
        const body = try transformer.ast.addNode(.{ .tag = .block_statement, .span = .EMPTY, .data = .{ .list = empty } });
        const extra = try transformer.ast.addExtras(&.{
            @backingInt(NodeIndex.none), @backingInt(params), @backingInt(body), 0, @backingInt(NodeIndex.none),
        });
        generated[i] = try transformer.ast.addNode(.{ .tag = .function_expression, .span = .EMPTY, .data = .{ .extra = extra } });
        scopes[i] = try transformer.addGeneratedFunctionScope(parent, generated[i]);
    }
    var final: [2]NodeIndex = undefined;
    final[1] = try transformer.visitNode(generated[1]);
    // Revisiting an earlier generated owner creates a dead branch. The final
    // AST, not visit order, must decide which copy owns its function scope.
    _ = try transformer.visitNode(generated[0]);
    final[0] = try transformer.visitNode(generated[0]);
    try std.testing.expectEqual(root, transformer.ast.transformed_root.?);
    var stmts: [2]NodeIndex = undefined;
    for (final, 0..) |func, i| {
        stmts[i] = try transformer.ast.addUnaryNode(.expression_statement, .EMPTY, func, 0);
    }
    transformer.ast.nodes.items[@backingInt(root)].data.list = try transformer.ast.addNodeList(&stmts);
    const edited = (try transformer.finishSemanticEdit()).?;
    for (0..2) |i| {
        try std.testing.expect(generated[i] != final[i]);
        try std.testing.expectEqual(@as(?u32, @backingInt(scopes[i])), edited.scope_owner_map.get(@backingInt(final[i])));
        try std.testing.expect(edited.scope_owner_map.get(@backingInt(generated[i])) == null);
    }
}
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
    transformer.class_self_symbol_map = analyzer.class_self_symbol_map;
    transformer.references = analyzer.references.items;
    transformer.scopes = analyzer.scopes.items;
    transformer.scope_maps = analyzer.scope_maps.items;
    transformer.scope_owner_map = analyzer.scope_owner_map;
    transformer.node_scope_provenance = analyzer.node_scope_provenance;
    transformer.unresolved_references = &analyzer.unresolved_references;
    transformer.semantic_edit_enabled = true;
    _ = try transformer.transform();
    const edited = (try transformer.finishSemanticEdit()).?;

    var found = false;
    for (transformer.ast.nodes.items) |node| {
        if (node.tag != .call_expression) continue;
        const extra = transformer.ast.extra_data.items;
        const e = node.data.extra;
        var callee: @import("../parser/ast.zig").NodeIndex = @fromBackingInt(@intCast(extra[e]));
        var first_arg: u32 = 0;
        if (transformer.ast.getNode(callee).tag == .static_member_expression) {
            const member = transformer.ast.getNode(callee).data.extra;
            const property = transformer.ast.getNode(@fromBackingInt(@intCast(extra[member + 1])));
            if (!std.mem.eql(u8, transformer.ast.getText(property.data.string_ref), "call")) continue;
            callee = @fromBackingInt(@intCast(extra[member]));
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
            try std.testing.expectEqual(edited.symbol_ids[@backingInt(callee)].?, @backingInt(ref.symbol_id));
            try std.testing.expect(ref.flags.read and !ref.flags.write and !ref.flags.declare);
            callee_refs += 1;
        }
        try std.testing.expectEqual(@as(usize, 1), callee_refs);

        for (first_arg..args_len) |offset| {
            const arg: @import("../parser/ast.zig").NodeIndex = @fromBackingInt(@intCast(extra[@as(usize, args_start) + offset]));
            const sym_idx = edited.symbol_ids[@backingInt(arg)] orelse return error.TestUnexpectedResult;
            var ref_scope: ?@import("../semantic/scope.zig").ScopeId = null;
            var ref_count: usize = 0;
            for (edited.references) |ref| {
                if (ref.node_index != arg) continue;
                try std.testing.expectEqual(sym_idx, @backingInt(ref.symbol_id));
                try std.testing.expect(ref.flags.read and !ref.flags.write and !ref.flags.declare);
                ref_scope = ref.scope_id;
                ref_count += 1;
            }
            try std.testing.expectEqual(@as(usize, 1), ref_count);
            // 이미 현재 출력 이름으로 만든 인자는 재방문 후에도 같은 노드다.
            try std.testing.expectEqual(@as(?u32, null), transformer.reference_origin_map.get(@backingInt(arg)));
            var scope = ref_scope orelse return error.TestUnexpectedResult;
            // Lowered generators store loop state in the outer wrapper while
            // the call argument executes inside the nested state-machine
            // callback. The reference must retain that callback scope and see
            // its binding through the parent chain.
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

fn isReachable(ast: *const @import("../parser/ast.zig").Ast, root: NodeIndex, wanted: NodeIndex) !bool {
    const Context = struct {
        wanted: NodeIndex,
        found: bool = false,

        fn visit(ctx: *@This(), idx: NodeIndex, _: @import("../parser/ast.zig").Node) ast_walk.WalkAction {
            if (idx == ctx.wanted) {
                ctx.found = true;
                return .stop;
            }
            return .descend;
        }
    };
    var ctx = Context{ .wanted = wanted };
    try ast_walk.walkPreorderIterative(ast.allocator, ast, root, &ctx, Context.visit);
    return ctx.found;
}

/// Each fixture declares one uniquely named `var` inside an extracted loop.
/// Its generated write must keep the original binding ID and match the final
/// AST scope, including when generator lowering moves it into a state callback.
fn expectHoistedVarWrite(source: []const u8) !void {
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

    var binding: NodeIndex = .none;
    for (parser.ast.nodes.items, 0..) |node, i| {
        if (node.tag != .binding_identifier) continue;
        if (!std.mem.eql(u8, parser.ast.getText(node.data.string_ref), "sourceWrite")) continue;
        try std.testing.expect(binding.isNone());
        binding = @fromBackingInt(@intCast(@as(u32, @intCast(i))));
    }
    try std.testing.expect(!binding.isNone());
    const symbol_id = analyzer.symbol_ids.items[@backingInt(binding)] orelse return error.TestUnexpectedResult;
    const before_writes = analyzer.symbols.items[symbol_id].write_count;
    const is_generator = std.mem.indexOf(u8, source, "function*") != null;

    // Find the tightest original scope owner for the for-of owner assertion
    // below. Generated reference scopes are checked against the final AST.
    const binding_span = parser.ast.getNode(binding).span;
    var expected_scope: ScopeId = .none;
    var expected_owner: NodeIndex = .none;
    var narrowest: u32 = std.math.maxInt(u32);
    var owners = analyzer.scope_owner_map.iterator();
    while (owners.next()) |entry| {
        const owner = parser.ast.getNode(@fromBackingInt(@intCast(entry.key_ptr.*)));
        if (owner.span.start > binding_span.start or owner.span.end < binding_span.end) continue;
        const width = owner.span.end - owner.span.start;
        if (width < narrowest) {
            narrowest = width;
            expected_scope = @fromBackingInt(@intCast(entry.value_ptr.*));
            expected_owner = @fromBackingInt(@intCast(entry.key_ptr.*));
        }
    }
    try std.testing.expect(!expected_scope.isNone());

    var transformer = try Transformer.init(allocator, &parser.ast, .{
        .unsupported = TransformOptions.compat.fromESTarget(.es5),
    });
    try transformer.initSymbolIds(analyzer.symbol_ids.items);
    transformer.symbols = analyzer.symbols.items;
    transformer.class_self_symbol_map = analyzer.class_self_symbol_map;
    transformer.references = analyzer.references.items;
    transformer.scopes = analyzer.scopes.items;
    transformer.scope_maps = analyzer.scope_maps.items;
    transformer.scope_owner_map = analyzer.scope_owner_map;
    transformer.node_scope_provenance = analyzer.node_scope_provenance;
    transformer.unresolved_references = &analyzer.unresolved_references;
    transformer.semantic_edit_enabled = true;
    const root = try transformer.transform();
    const edited = (try transformer.finishSemanticEdit()).?;
    var maybe_coverage: ?symbol_coverage.StrictReport = if (is_generator) try symbol_coverage.checkStrict(
        allocator,
        transformer.ast,
        root,
        transformer.parser_node_count,
        edited.symbol_ids,
        edited.symbols.items,
        edited.scopes,
        &edited.scope_owner_map,
        edited.references,
        if (transformer.synthetic_idents) |*synthetic| synthetic else null,
        &analyzer.unresolved_references,
    ) else null;
    defer if (maybe_coverage) |*coverage| coverage.deinit(allocator);
    var output_parents = try output_scope.buildParentMap(allocator, transformer.ast, root);
    defer output_parents.deinit(allocator);

    var writes: usize = 0;
    for (edited.references) |ref| {
        if (@backingInt(ref.node_index) < transformer.parser_node_count or ref.node_index.isNone()) continue;
        const node = transformer.ast.getNode(ref.node_index);
        if (node.tag != .identifier_reference) continue;
        if (!std.mem.eql(u8, transformer.ast.getText(node.data.string_ref), "sourceWrite")) continue;
        if (!ref.flags.write) continue;
        writes += 1;
        try std.testing.expectEqual(symbol_id, @backingInt(ref.symbol_id));
        try std.testing.expectEqual(@as(?u32, symbol_id), edited.symbol_ids[@backingInt(ref.node_index)]);
        const expected_output_scope = output_scope.expectedScope(
            transformer.ast,
            root,
            &output_parents,
            &edited.scope_owner_map,
            @backingInt(ref.node_index),
        ) orelse return error.TestUnexpectedResult;
        if (expected_output_scope != ref.scope_id) {
            std.debug.print("scope mismatch: source={s} node={d} expected={d} actual={d}\n", .{
                source,
                @backingInt(ref.node_index),
                @backingInt(expected_output_scope),
                @backingInt(ref.scope_id),
            });
        }
        try std.testing.expectEqual(expected_output_scope, ref.scope_id);
        try std.testing.expect(!ref.flags.read and !ref.flags.declare);
        try std.testing.expectEqual(Reference.NO_STMT, ref.stmt_idx);
        try std.testing.expectEqual(Reference.NO_STMT, ref.scope_stmt_idx);
        try std.testing.expect(try isReachable(transformer.ast, root, ref.node_index));
        var saw_bound_finding = false;
        if (maybe_coverage) |coverage| {
            for (coverage.findings.items) |finding| {
                if (finding.node != @backingInt(ref.node_index)) continue;
                try std.testing.expectEqual(symbol_coverage.StrictStatus.bound, finding.status);
                saw_bound_finding = true;
            }
            try std.testing.expect(saw_bound_finding);
        }
    }
    try std.testing.expectEqual(@as(usize, 1), writes);
    try std.testing.expectEqual(before_writes + 1, edited.symbols.items[symbol_id].write_count);
    // Generator state-machine collection consumes its temporary iterator AST;
    // its live output reference is checked above by strict final-AST coverage.
    if (parser.ast.getNode(expected_owner).tag == .for_of_statement and
        std.mem.indexOf(u8, source, "function*") == null)
    {
        var found_final_owner = false;
        var final_owners = edited.scope_owner_map.iterator();
        while (final_owners.next()) |entry| {
            if (entry.value_ptr.* != @backingInt(expected_scope)) continue;
            const owner_idx: NodeIndex = @fromBackingInt(@intCast(entry.key_ptr.*));
            try std.testing.expectEqual(@import("../parser/ast.zig").Node.Tag.for_statement, transformer.ast.getNode(owner_idx).tag);
            try std.testing.expect(try isReachable(transformer.ast, root, owner_idx));
            found_final_owner = true;
        }
        try std.testing.expect(found_final_owner);
    }
}

test "#4819 hoisted var assignment records source block write" {
    try expectHoistedVarWrite(
        \\export function ordinary(out) {
        \\  for (let i = 0; i < 2; i++) {
        \\    out.push(() => i);
        \\    var sourceWrite = i;
        \\  }
        \\}
    );
}

test "#4819 hoisted var assignment records nested block write" {
    try expectHoistedVarWrite(
        \\export function nested(out) {
        \\  for (let i = 0; i < 2; i++) {
        \\    out.push(() => i);
        \\    if (i) { var sourceWrite = i; }
        \\  }
        \\}
    );
}

test "#4819 hoisted var assignment retains nested scope through control flow copy" {
    try expectHoistedVarWrite(
        \\export function flow(out) {
        \\  for (let i = 0; i < 2; i++) {
        \\    out.push(() => i);
        \\    if (i) { var sourceWrite = i; break; }
        \\  }
        \\}
    );
}

test "#4819 hoisted var assignment records catch body write" {
    try expectHoistedVarWrite(
        \\export function caught(out) {
        \\  for (let i = 0; i < 2; i++) {
        \\    out.push(() => i);
        \\    try { throw i; } catch (error) { var sourceWrite = error; }
        \\  }
        \\}
    );
}

test "#4819 hoisted var assignment records unbraced body write" {
    try expectHoistedVarWrite(
        \\export function unbraced() {
        \\  for (let i = 0; i < 2; i++)
        \\    if (i) var sourceWrite = (() => i)();
        \\}
    );
}

test "#4819 hoisted var assignment records nested for initializer write" {
    try expectHoistedVarWrite(
        \\export function forInit(out) {
        \\  for (let i = 0; i < 2; i++) {
        \\    out.push(() => i);
        \\    for (var sourceWrite = 0; sourceWrite < 1; sourceWrite++) {}
        \\  }
        \\}
    );
}

test "#4819 hoisted var assignment records nested for-in header write" {
    try expectHoistedVarWrite(
        \\export function forIn(out) {
        \\  for (let i = 0; i < 2; i++) {
        \\    out.push(() => i);
        \\    for (var sourceWrite in { value: i }) {}
        \\  }
        \\}
    );
}

test "#4819 hoisted var assignment records nested for-of header write" {
    try expectHoistedVarWrite(
        \\export function forOf(out) {
        \\  for (let i = 0; i < 2; i++) {
        \\    out.push(() => i);
        \\    for (var sourceWrite of [i]) {}
        \\  }
        \\}
    );
}

test "#4819 hoisted var assignment records labeled for-of header write" {
    try expectHoistedVarWrite(
        \\export function labeledForOf(out) {
        \\  for (let i = 0; i < 2; i++) {
        \\    out.push(() => i);
        \\    iter: for (var sourceWrite of [i]) { break iter; }
        \\  }
        \\}
    );
}

test "#4819 hoisted var assignment records generator body write" {
    try expectHoistedVarWrite(
        \\export function* generated() {
        \\  for (let i = 0; i < 2; i++) {
        \\    yield () => i;
        \\    var sourceWrite = i;
        \\  }
        \\}
    );
}

test "#4819 hoisted var assignment records generator for-of header write" {
    try expectHoistedVarWrite(
        \\export function* generatedForOf() {
        \\  for (let i = 0; i < 2; i++) {
        \\    yield () => i;
        \\    for (var sourceWrite of [i]) { yield sourceWrite; }
        \\  }
        \\}
    );
}

test "#4819 hostile switch case var write uses switch scope" {
    try expectHoistedVarWrite(
        \\export function switched(out) {
        \\  for (let i = 0; i < 2; i++) {
        \\    out.push(() => i);
        \\    switch (i) { case 0: var sourceWrite = i; break; }
        \\  }
        \\}
    );
}

test "#4819 hostile generator switch case var write uses source scope" {
    try expectHoistedVarWrite(
        \\export function* switched() {
        \\  for (let i = 0; i < 2; i++) {
        \\    yield () => i;
        \\    switch (i) { case 0: var sourceWrite = i; break; }
        \\  }
        \\}
    );
}

test "#4819 hostile unbraced try catch var write uses catch scope" {
    try expectHoistedVarWrite(
        \\export function caught(out) {
        \\  for (let i = 0; i < 2; i++) {
        \\    out.push(() => i);
        \\    if (i) try { throw i; } catch (error) { var sourceWrite = error; }
        \\  }
        \\}
    );
}

test "#4819 hostile generator yield initializer keeps one live write" {
    try expectHoistedVarWrite(
        \\export function* generated() {
        \\  for (let i = 0; i < 2; i++) {
        \\    yield () => i;
        \\    var sourceWrite = yield i;
        \\  }
        \\}
    );
}

test "#4819 hostile finally return keeps one live write" {
    try expectHoistedVarWrite(
        \\export function finished(out) {
        \\  for (let i = 0; i < 2; i++) {
        \\    out.push(() => i);
        \\    try { var sourceWrite = i; if (i) return i; }
        \\    finally { out.push(() => i); }
        \\  }
        \\}
    );
}

test "#4819 hostile generator nested for-of body write" {
    try expectHoistedVarWrite(
        \\export function* generatedForOf() {
        \\  for (let i = 0; i < 2; i++) {
        \\    yield () => i;
        \\    for (let item of [i]) { var sourceWrite = item; yield sourceWrite; }
        \\  }
        \\}
    );
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

test "#4819 extracted loop body temps bind to the exact generated function scope" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source =
        \\function get(value) { return value; }
        \\function run() {
        \\  var callbacks = [];
        \\  var i = 0;
        \\  while (i < 2) {
        \\    const result = get({ value: i })?.value;
        \\    callbacks.push(() => result);
        \\    i++;
        \\  }
        \\  return callbacks;
        \\}
    ;
    var scanner = try Scanner.init(allocator, source);
    var parser = Parser.init(allocator, &scanner);
    _ = try parser.parse();
    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    try analyzer.analyze();

    var transformer = try Transformer.init(allocator, &parser.ast, .{
        .unsupported = TransformOptions.compat.fromESTarget(.es5),
        .emit_runtime_helper_imports = false,
        .defer_runtime_helper_name_resolution = true,
    });
    try transformer.initSymbolIds(analyzer.symbol_ids.items);
    transformer.symbols = analyzer.symbols.items;
    transformer.class_self_symbol_map = analyzer.class_self_symbol_map;
    transformer.references = analyzer.references.items;
    transformer.scopes = analyzer.scopes.items;
    transformer.scope_maps = analyzer.scope_maps.items;
    transformer.scope_owner_map = analyzer.scope_owner_map;
    transformer.node_scope_provenance = analyzer.node_scope_provenance;
    transformer.unresolved_references = &analyzer.unresolved_references;
    transformer.semantic_edit_enabled = true;

    const root = try transformer.transform();
    const loop_body = try findLoopFunctionBody(allocator, transformer.ast, root);
    const edited = (try transformer.finishSemanticEdit()).?;
    const reachable = try ast_walk.collectReachableNodeIndices(allocator, transformer.ast);
    var output_parents = try output_scope.buildParentMap(allocator, transformer.ast, root);
    defer output_parents.deinit(allocator);

    var function_scope: ScopeId = .none;
    var owner_count: usize = 0;
    var owners = edited.scope_owner_map.iterator();
    while (owners.next()) |entry| {
        const owner: NodeIndex = @fromBackingInt(@intCast(entry.key_ptr.*));
        const node = transformer.ast.getNode(owner);
        if (node.tag != .function_expression or
            @as(NodeIndex, @fromBackingInt(@intCast(transformer.ast.extra_data.items[node.data.extra + 2]))) != loop_body or
            !(try isReachable(transformer.ast, root, owner))) continue;
        function_scope = @fromBackingInt(@intCast(entry.value_ptr.*));
        owner_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), owner_count);
    try std.testing.expectEqual(@import("../semantic/scope.zig").ScopeKind.function, edited.scopes[function_scope.toIndex()].kind);

    var temp_count: usize = 0;
    for (edited.symbols.items, 0..) |symbol, symbol_index| {
        if (symbol.scope_id != function_scope or symbol.synthetic_kind != .standalone_temp_binding) continue;
        temp_count += 1;
        try std.testing.expectEqual(@as(?usize, symbol_index), edited.scope_maps[function_scope.toIndex()].get(symbol.synthetic_name));

        var binding_count: usize = 0;
        for (reachable) |raw| {
            if (transformer.ast.nodes.items[raw].tag == .binding_identifier and
                raw < edited.symbol_ids.len and edited.symbol_ids[raw] == @as(u32, @intCast(symbol_index))) binding_count += 1;
        }
        try std.testing.expectEqual(@as(usize, 1), binding_count);

        var reference_count: usize = 0;
        for (edited.references) |reference| {
            if (@backingInt(reference.symbol_id) != symbol_index or reference.node_index.isNone()) continue;
            try std.testing.expect(try isReachable(transformer.ast, root, reference.node_index));
            const expected_scope = output_scope.expectedScope(
                transformer.ast,
                root,
                &output_parents,
                &edited.scope_owner_map,
                @backingInt(reference.node_index),
            ) orelse return error.TestUnexpectedResult;
            try std.testing.expectEqual(expected_scope, reference.scope_id);
            try std.testing.expectEqual(@as(?u32, @intCast(symbol_index)), edited.symbol_ids[@backingInt(reference.node_index)]);
            reference_count += 1;
        }
        try std.testing.expectEqual(symbol.reference_count, reference_count);
    }
    try std.testing.expect(temp_count > 0);

    const unresolved_nodes: std.AutoHashMapUnmanaged(u32, void) = .empty;
    const exact = try symbol_coverage.checkExact(
        allocator,
        transformer.ast,
        root,
        transformer.parser_node_count,
        edited.symbol_ids,
        edited.symbols.items,
        edited.scopes,
        edited.scope_maps,
        &edited.scope_owner_map,
        edited.references,
        transformer.helper_ref_nodes.items,
        &edited.helper_scope_map,
        &unresolved_nodes,
        &transformer.explicit_global_reference_nodes,
        &transformer.scope_owner_origins,
    );
    if (!exact.isClean()) symbol_coverage.printExact("loop-body-temp-test", exact);
    try std.testing.expect(exact.isClean());
}

test "#4819 extracted loop for-of temps retain exact references" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source =
        \\function collect(values) {
        \\  let index = 0;
        \\  const readers = [];
        \\  while (index < 1) {
        \\    const local = index;
        \\    for (const value of values) readers.push(value + local);
        \\    readers.push(() => local);
        \\    index++;
        \\  }
        \\  return readers;
        \\}
    ;
    var scanner = try Scanner.init(allocator, source);
    var parser = Parser.init(allocator, &scanner);
    parser.configureFromExtension(".mjs");
    _ = try parser.parse();
    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    analyzer.is_module = true;
    analyzer.collect_unresolved_reference_nodes = true;
    try analyzer.analyze();

    var transformer = try Transformer.init(allocator, &parser.ast, .{
        .unsupported = TransformOptions.compat.fromESTarget(.es5),
    });
    try transformer.initSymbolIds(analyzer.symbol_ids.items);
    transformer.symbols = analyzer.symbols.items;
    transformer.class_self_symbol_map = analyzer.class_self_symbol_map;
    transformer.references = analyzer.references.items;
    transformer.scopes = analyzer.scopes.items;
    transformer.scope_maps = analyzer.scope_maps.items;
    transformer.scope_owner_map = analyzer.scope_owner_map;
    transformer.node_scope_provenance = analyzer.node_scope_provenance;
    transformer.unresolved_references = &analyzer.unresolved_references;
    transformer.unresolved_reference_nodes = &analyzer.unresolved_reference_nodes;
    transformer.semantic_edit_enabled = true;
    transformer.synthetic_idents = .empty;

    const root = try transformer.transform();
    const loop_body = try findLoopFunctionBody(allocator, transformer.ast, root);
    const edited = (try transformer.finishSemanticEdit()).?;
    var report = try symbol_coverage.checkStrictWithExactExternalEvidence(
        allocator,
        transformer.ast,
        root,
        transformer.parser_node_count,
        edited.symbol_ids,
        edited.symbols.items,
        edited.scopes,
        &edited.scope_owner_map,
        edited.references,
        if (transformer.synthetic_idents) |*synthetic| synthetic else null,
        .{
            .unresolved_reference_nodes = &analyzer.unresolved_reference_nodes,
            .explicit_global_reference_nodes = &transformer.explicit_global_reference_nodes,
            .reference_origin_map = &transformer.reference_origin_map,
        },
    );
    defer report.deinit(allocator);
    if (!report.hasCompleteExactCoverage()) symbol_coverage.printStrict("extracted-loop-for-of-temp-identity.mjs", &report);
    try std.testing.expect(report.hasCompleteExactCoverage());

    var output_parents = try output_scope.buildParentMap(allocator, transformer.ast, root);
    defer output_parents.deinit(allocator);
    var function_scope: ScopeId = .none;
    var function_owner_count: usize = 0;
    var owners = edited.scope_owner_map.iterator();
    while (owners.next()) |entry| {
        const owner: NodeIndex = @fromBackingInt(@intCast(entry.key_ptr.*));
        const owner_node = transformer.ast.getNode(owner);
        if (owner_node.tag != .function_expression or
            @as(NodeIndex, @fromBackingInt(@intCast(transformer.ast.extra_data.items[owner_node.data.extra + 2]))) != loop_body) continue;
        function_scope = @fromBackingInt(@intCast(entry.value_ptr.*));
        function_owner_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), function_owner_count);

    const expected_temp_names = [_][]const u8{ "_a", "_b", "_c", "_d", "_step" };
    for (expected_temp_names) |expected_name| {
        var temp_symbol_id: ?u32 = null;
        for (edited.symbols.items, 0..) |symbol, raw_id| {
            if (!std.mem.eql(u8, symbol.synthetic_name, expected_name)) continue;
            try std.testing.expect(temp_symbol_id == null);
            temp_symbol_id = @intCast(raw_id);
            try std.testing.expectEqual(function_scope, symbol.scope_id);
        }
        const id = temp_symbol_id orelse return error.MissingExtractedForOfTempSymbol;
        var reference_count: usize = 0;
        for (edited.references) |reference| {
            if (@backingInt(reference.symbol_id) != id or reference.node_index.isNone()) continue;
            const expected_scope = output_scope.expectedScope(
                transformer.ast,
                root,
                &output_parents,
                &edited.scope_owner_map,
                @backingInt(reference.node_index),
            ) orelse return error.TestUnexpectedResult;
            try std.testing.expectEqual(expected_scope, reference.scope_id);
            reference_count += 1;
        }
        try std.testing.expect(reference_count > 0);
    }
}

fn expectExtractedForOfTempHandoff(source: []const u8, expected_steps: usize) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var scanner = try Scanner.init(allocator, source);
    var parser = Parser.init(allocator, &scanner);
    parser.configureFromExtension(".mjs");
    _ = try parser.parse();
    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    analyzer.is_module = true;
    analyzer.collect_unresolved_reference_nodes = true;
    try analyzer.analyze();

    var source_for_of_count: usize = 0;
    for (parser.ast.nodes.items) |node| {
        if (node.tag == .for_of_statement) source_for_of_count += 1;
    }
    try std.testing.expect(source_for_of_count >= expected_steps);

    var transformer = try Transformer.init(allocator, &parser.ast, .{
        .unsupported = TransformOptions.compat.fromESTarget(.es5),
    });
    try transformer.initSymbolIds(analyzer.symbol_ids.items);
    transformer.symbols = analyzer.symbols.items;
    transformer.class_self_symbol_map = analyzer.class_self_symbol_map;
    transformer.references = analyzer.references.items;
    transformer.scopes = analyzer.scopes.items;
    transformer.scope_maps = analyzer.scope_maps.items;
    transformer.scope_owner_map = analyzer.scope_owner_map;
    transformer.node_scope_provenance = analyzer.node_scope_provenance;
    transformer.unresolved_references = &analyzer.unresolved_references;
    transformer.unresolved_reference_nodes = &analyzer.unresolved_reference_nodes;
    transformer.semantic_edit_enabled = true;
    transformer.synthetic_idents = .empty;

    const root = try transformer.transform();
    const loop_body = try findLoopFunctionBody(allocator, transformer.ast, root);
    const edited = (try transformer.finishSemanticEdit()).?;
    var report = try symbol_coverage.checkStrictWithExactExternalEvidence(
        allocator,
        transformer.ast,
        root,
        transformer.parser_node_count,
        edited.symbol_ids,
        edited.symbols.items,
        edited.scopes,
        &edited.scope_owner_map,
        edited.references,
        if (transformer.synthetic_idents) |*synthetic| synthetic else null,
        .{
            .unresolved_reference_nodes = &analyzer.unresolved_reference_nodes,
            .explicit_global_reference_nodes = &transformer.explicit_global_reference_nodes,
            .reference_origin_map = &transformer.reference_origin_map,
        },
    );
    defer report.deinit(allocator);
    try std.testing.expect(report.hasCompleteExactCoverage());

    var loop_function_scope: ScopeId = .none;
    var owners = edited.scope_owner_map.iterator();
    while (owners.next()) |entry| {
        const owner: NodeIndex = @fromBackingInt(@intCast(entry.key_ptr.*));
        const owner_node = transformer.ast.getNode(owner);
        if (owner_node.tag != .function_expression or
            @as(NodeIndex, @fromBackingInt(@intCast(transformer.ast.extra_data.items[owner_node.data.extra + 2]))) != loop_body) continue;
        loop_function_scope = @fromBackingInt(@intCast(entry.value_ptr.*));
    }
    try std.testing.expect(!loop_function_scope.isNone());

    var output_parents = try output_scope.buildParentMap(allocator, transformer.ast, root);
    defer output_parents.deinit(allocator);
    var step_symbols: usize = 0;
    for (edited.symbols.items, 0..) |symbol, raw_id| {
        if (!std.mem.startsWith(u8, symbol.synthetic_name, "_step")) continue;
        var cursor = symbol.scope_id;
        var belongs_to_loop = false;
        while (!cursor.isNone()) {
            if (cursor == loop_function_scope) {
                belongs_to_loop = true;
                break;
            }
            if (cursor.toIndex() >= edited.scopes.len) break;
            cursor = edited.scopes[cursor.toIndex()].parent;
        }
        if (!belongs_to_loop) continue;
        step_symbols += 1;
        var reference_count: usize = 0;
        for (edited.references) |reference| {
            if (@backingInt(reference.symbol_id) != raw_id or reference.node_index.isNone()) continue;
            const expected_scope = output_scope.expectedScope(
                transformer.ast,
                root,
                &output_parents,
                &edited.scope_owner_map,
                @backingInt(reference.node_index),
            ) orelse return error.TestUnexpectedResult;
            try std.testing.expectEqual(expected_scope, reference.scope_id);
            reference_count += 1;
        }
        try std.testing.expect(reference_count > 0);
    }
    try std.testing.expect(step_symbols >= expected_steps);
}

test "#4819 hostile extracted for-of temp identity input matrix" {
    const cases = [_]struct { source: []const u8, expected_steps: usize }{
        .{ .source =
        \\function run(values) {
        \\  let index = 0; const readers = [];
        \\  while (index < 1) { const local = index; for (const value of values) readers.push(value + local); readers.push(() => local); index++; }
        \\  return readers;
        \\}
        , .expected_steps = 1 },
        .{ .source =
        \\function run(values) {
        \\  let index = 0; const readers = [];
        \\  do { const local = index; for (const value of values) readers.push(value + local); readers.push(() => local); index++; } while (index < 1);
        \\  return readers;
        \\}
        , .expected_steps = 1 },
        .{ .source =
        \\function run(values) {
        \\  const readers = [];
        \\  for (let index = 0; index < 1; index++) { const local = index; for (const value of values) readers.push(value + local); readers.push(() => local); }
        \\  return readers;
        \\}
        , .expected_steps = 1 },
        .{ .source =
        \\function run(groups) {
        \\  const readers = [];
        \\  for (const key in groups) { const local = key; for (const value of groups[key]) readers.push(value + local); readers.push(() => local); }
        \\  return readers;
        \\}
        , .expected_steps = 1 },
        .{ .source =
        \\function run(groups) {
        \\  let index = 0; const readers = [];
        \\  while (index < 1) { const outer = index; do { const local = outer; for (const value of groups) readers.push(value + local); readers.push(() => local); index++; } while (index < 1); }
        \\  return readers;
        \\}
        , .expected_steps = 1 },
        .{ .source =
        \\function run(values) {
        \\  let index = 0; const readers = [];
        \\  while (index < 1) { const local = index; try { for (const value of values) readers.push(value + local); readers.push(() => local); } finally { index++; } }
        \\  return readers;
        \\}
        , .expected_steps = 1 },
        .{ .source =
        \\function run(groups) {
        \\  let index = 0; const readers = [];
        \\  while (index < 1) { const local = index; for (const group of groups) { for (const value of group) readers.push(() => local + value); } readers.push(() => local); index++; }
        \\  return readers;
        \\}
        , .expected_steps = 2 },
        .{ .source =
        \\function run(entries) {
        \\  let index = 0; const readers = [];
        \\  while (index < 1) { const local = index; for (const [key, value] of entries) readers.push(() => local + key + value); readers.push(() => local); index++; }
        \\  return readers;
        \\}
        , .expected_steps = 1 },
        .{ .source =
        \\function run(values) {
        \\  let index = 0; const readers = [];
        \\  while (index < 1) { const local = index; const visible = eval("local"); for (const value of values) readers.push(value + visible); readers.push(() => local); index++; }
        \\  return readers;
        \\}
        , .expected_steps = 1 },
        .{ .source =
        \\function run(values) {
        \\  let index = 0; const readers = [];
        \\  while (index < 1) { const local = index; for (const value of values) { if (value < 0) continue; readers.push(() => local + value); if (value > 1) break; } readers.push(() => local); index++; }
        \\  return readers;
        \\}
        , .expected_steps = 1 },
    };
    for (cases) |case| try expectExtractedForOfTempHandoff(case.source, case.expected_steps);
}
