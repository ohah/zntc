//! 트랜스포머가 새로 만든 사용자 식별자에 심볼 ID 가 빠지지 않는지 (#4760).
//!
//! 단일 파일 minify 는 변환 뒤 코드를 다시 분석해 이름을 짓는다(#4759) — 그래서 심볼 누락이
//! 출력으로는 드러나지 않는다. 대신 블록 스코핑을 심볼 기준으로 바꾸는 #4760 은 변환 **도중**
//! 심볼이 필요하므로, 고친 지점마다 누락 0 을 검사기로 직접 고정한다.

const std = @import("std");
const Ast = @import("../parser/ast.zig").Ast;
const AstNodeIndex = @import("../parser/ast.zig").NodeIndex;
const Scanner = @import("../lexer/scanner.zig").Scanner;
const Parser = @import("../parser/parser.zig").Parser;
const SemanticAnalyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer;
const Reference = @import("../semantic/symbol.zig").Reference;
const Symbol = @import("../semantic/symbol.zig").Symbol;
const Scope = @import("../semantic/scope.zig").Scope;
const ScopeId = @import("../semantic/scope.zig").ScopeId;
const transformer_mod = @import("transformer.zig");
const Transformer = transformer_mod.Transformer;
const TransformOptions = transformer_mod.TransformOptions;
const coverage = @import("symbol_coverage.zig");
const SemanticEditor = @import("../semantic/editor.zig").SemanticEditor;

fn checkEmptyExactGraph(allocator: std.mem.Allocator, ast: *const Ast, root: @import("../parser/ast.zig").NodeIndex) !coverage.ExactReport {
    const scopes = [_]Scope{.{ .parent = .none, .kind = .global, .is_strict = false }};
    const scope_maps = [_]std.StringHashMapUnmanaged(usize){.empty};
    const owners: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    const unresolved: std.AutoHashMapUnmanaged(u32, void) = .empty;
    const explicit_globals: std.AutoHashMapUnmanaged(u32, void) = .empty;
    const origins: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    return coverage.checkExact(
        allocator,
        ast,
        root,
        0,
        &.{},
        &.{},
        &scopes,
        &scope_maps,
        &owners,
        &.{},
        &.{},
        &.{},
        &unresolved,
        &explicit_globals,
        &origins,
    );
}

test "exact coverage rejects invalid root, child indices, and truncated child layouts" {
    const allocator = std.testing.allocator;
    const NodeIndex = @import("../parser/ast.zig").NodeIndex;

    var empty_ast = Ast.init(allocator, "");
    defer empty_ast.deinit();
    const invalid_root = try checkEmptyExactGraph(allocator, &empty_ast, .none);
    try std.testing.expectEqual(@as(usize, 1), invalid_root.invalid_ast_root);
    try std.testing.expect(!invalid_root.isClean());

    var edge_ast = Ast.init(allocator, "");
    defer edge_ast.deinit();
    const span = try edge_ast.addString("x");
    const invalid_child_index: u32 = 37;
    const bad_child = try edge_ast.addNodeList(&.{@enumFromInt(invalid_child_index)});
    const edge_root = try edge_ast.addListNode(.program, span, bad_child);
    const invalid_edge = try checkEmptyExactGraph(allocator, &edge_ast, edge_root);
    try std.testing.expectEqual(@as(usize, 1), invalid_edge.invalid_ast_edge);
    try std.testing.expectEqual(invalid_child_index, invalid_edge.first_invalid_ast_edge.?.child_node_index);
    try std.testing.expect(!invalid_edge.isClean());

    var list_ast = Ast.init(allocator, "");
    defer list_ast.deinit();
    const list_span = try list_ast.addString("x");
    const invalid_list_root = try list_ast.addNode(.{
        .tag = .program,
        .span = list_span,
        .data = .{ .list = .{ .start = 4, .len = 1 } },
    });
    const invalid_list = try checkEmptyExactGraph(allocator, &list_ast, invalid_list_root);
    try std.testing.expectEqual(@as(usize, 1), invalid_list.invalid_ast_layout);
    try std.testing.expectEqual(coverage.AstLayoutIssue.list_range, invalid_list.first_invalid_ast_layout.?.issue);
    try std.testing.expect(!invalid_list.isClean());

    var extra_ast = Ast.init(allocator, "");
    defer extra_ast.deinit();
    const extra_span = try extra_ast.addString("x");
    const extra_base = try extra_ast.addExtras(&.{ @intFromEnum(NodeIndex.none), 99, 1 });
    const call = try extra_ast.addExtraNode(.call_expression, extra_span, extra_base);
    const extra_root = try extra_ast.addNode(.{
        .tag = .program,
        .span = extra_span,
        .data = .{ .list = try extra_ast.addNodeList(&.{call}) },
    });
    const invalid_extra_list = try checkEmptyExactGraph(allocator, &extra_ast, extra_root);
    try std.testing.expectEqual(@as(usize, 1), invalid_extra_list.invalid_ast_layout);
    try std.testing.expectEqual(coverage.AstLayoutIssue.extra_list_range, invalid_extra_list.first_invalid_ast_layout.?.issue);
    try std.testing.expect(!invalid_extra_list.isClean());

    var missing_slot_ast = Ast.init(allocator, "");
    defer missing_slot_ast.deinit();
    const missing_slot_span = try missing_slot_ast.addString("x");
    const root_children = try missing_slot_ast.addNodeList(&.{NodeIndex.none});
    const missing_slot_root = try missing_slot_ast.addListNode(.program, missing_slot_span, root_children);
    const call_without_extra = try missing_slot_ast.addExtraNode(
        .call_expression,
        missing_slot_span,
        @intCast(missing_slot_ast.extra_data.items.len),
    );
    missing_slot_ast.extra_data.items[root_children.start] = @intFromEnum(call_without_extra);
    const invalid_extra_slot = try checkEmptyExactGraph(allocator, &missing_slot_ast, missing_slot_root);
    try std.testing.expectEqual(@as(usize, 1), invalid_extra_slot.invalid_ast_layout);
    try std.testing.expectEqual(coverage.AstLayoutIssue.extra_child_slot, invalid_extra_slot.first_invalid_ast_layout.?.issue);
    try std.testing.expect(!invalid_extra_slot.isClean());
}

test "exact identity audit rejects declaration rows assigned to a visible descendant scope" {
    const allocator = std.testing.allocator;
    var ast = Ast.init(allocator, "");
    defer ast.deinit();

    const name = try ast.addString("x");
    const binding = try ast.addNode(.{
        .tag = .binding_identifier,
        .span = name,
        .data = .{ .string_ref = name },
    });
    const block = try ast.addListNode(.block_statement, name, try ast.addNodeList(&.{binding}));
    const root = try ast.addListNode(.program, name, try ast.addNodeList(&.{block}));

    const global_scope: ScopeId = @enumFromInt(0);
    const binding_scope: ScopeId = @enumFromInt(1);
    const descendant_scope: ScopeId = @enumFromInt(2);
    const scopes = [_]Scope{
        .{ .parent = .none, .kind = .global, .is_strict = false },
        .{ .parent = global_scope, .kind = .block, .is_strict = false },
        .{ .parent = binding_scope, .kind = .block, .is_strict = false },
    };
    var binding_names: std.StringHashMapUnmanaged(usize) = .empty;
    defer binding_names.deinit(allocator);
    try binding_names.put(allocator, "x", 0);
    const scope_maps = [_]std.StringHashMapUnmanaged(usize){ .empty, binding_names, .empty };
    const symbols = [_]Symbol{
        .{
            .name = name,
            .scope_id = binding_scope,
            .origin_scope = binding_scope,
            .kind = .variable_let,
            .declaration_span = name,
        },
    };
    const symbol_ids = [_]?u32{ 0, null, null };
    var references = [_]Reference{
        .{
            .node_index = .none,
            .scope_id = binding_scope,
            .symbol_id = @enumFromInt(0),
            .flags = .{ .declare = true },
        },
    };
    var owners: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer owners.deinit(allocator);
    try owners.put(allocator, @intFromEnum(root), @intFromEnum(global_scope));
    try owners.put(allocator, @intFromEnum(block), @intFromEnum(binding_scope));
    const helpers: std.StringHashMapUnmanaged(usize) = .empty;
    const unresolved: std.AutoHashMapUnmanaged(u32, void) = .empty;
    const explicit_globals: std.AutoHashMapUnmanaged(u32, void) = .empty;
    const origins: std.AutoHashMapUnmanaged(u32, u32) = .empty;

    const valid = try coverage.checkExact(
        allocator,
        &ast,
        root,
        @intCast(ast.nodes.items.len),
        &symbol_ids,
        &symbols,
        &scopes,
        &scope_maps,
        &owners,
        &references,
        &.{},
        &helpers,
        &unresolved,
        &explicit_globals,
        &origins,
    );
    try std.testing.expectEqual(@as(usize, 0), valid.declaration_scope_mismatch);
    try std.testing.expect(valid.isClean());

    // The wrong declaration scope is still a valid descendant and can see
    // this binding. Visibility checks alone would accept the corrupted row.
    references[0].scope_id = descendant_scope;
    const corrupted = try coverage.checkExact(
        allocator,
        &ast,
        root,
        @intCast(ast.nodes.items.len),
        &symbol_ids,
        &symbols,
        &scopes,
        &scope_maps,
        &owners,
        &references,
        &.{},
        &helpers,
        &unresolved,
        &explicit_globals,
        &origins,
    );
    try std.testing.expectEqual(@as(usize, 1), corrupted.declaration_scope_mismatch);
    try std.testing.expectEqual(@as(usize, 0), corrupted.invalid_scope);
    try std.testing.expectEqual(@as(usize, 0), corrupted.invisible_reference);
    try std.testing.expect(!corrupted.isClean());
}

test "exact scope audit rejects owner scopes detached from their AST parent scopes" {
    const allocator = std.testing.allocator;
    var ast = Ast.init(allocator, "");
    defer ast.deinit();
    const span = try ast.addString("scope");
    const block = try ast.addListNode(.block_statement, span, try ast.addNodeList(&.{}));
    const root = try ast.addListNode(.program, span, try ast.addNodeList(&.{block}));

    const global_scope: ScopeId = @enumFromInt(0);
    const block_scope: ScopeId = @enumFromInt(1);
    const detached_scope: ScopeId = @enumFromInt(2);
    var scopes = [_]Scope{
        .{ .parent = .none, .kind = .global, .is_strict = false },
        .{ .parent = global_scope, .kind = .block, .is_strict = false },
        .{ .parent = global_scope, .kind = .block, .is_strict = false },
    };
    const scope_maps = [_]std.StringHashMapUnmanaged(usize){ .empty, .empty, .empty };
    var owners: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer owners.deinit(allocator);
    try owners.put(allocator, @intFromEnum(root), @intFromEnum(global_scope));
    try owners.put(allocator, @intFromEnum(block), @intFromEnum(block_scope));
    const helpers: std.StringHashMapUnmanaged(usize) = .empty;
    const unresolved: std.AutoHashMapUnmanaged(u32, void) = .empty;
    const explicit_globals: std.AutoHashMapUnmanaged(u32, void) = .empty;
    const origins: std.AutoHashMapUnmanaged(u32, u32) = .empty;

    const correct = try coverage.checkExact(
        allocator,
        &ast,
        root,
        0,
        &.{},
        &.{},
        &scopes,
        &scope_maps,
        &owners,
        &.{},
        &.{},
        &helpers,
        &unresolved,
        &explicit_globals,
        &origins,
    );
    try std.testing.expect(correct.isClean());

    // Every ScopeId remains individually valid and acyclic, but this block's
    // owner now points through a detached sibling scope. No identifier
    // reference exists to expose the broken lexical ancestry indirectly.
    scopes[@intFromEnum(block_scope)].parent = detached_scope;
    const corrupted = try coverage.checkExact(
        allocator,
        &ast,
        root,
        0,
        &.{},
        &.{},
        &scopes,
        &scope_maps,
        &owners,
        &.{},
        &.{},
        &helpers,
        &unresolved,
        &explicit_globals,
        &origins,
    );
    try std.testing.expectEqual(@as(usize, 1), corrupted.scope_owner_mismatch);
    try std.testing.expectEqual(@as(usize, 1), corrupted.scope_owner_parent_mismatch);
    try std.testing.expectEqualStrings("owner-parent-scope", corrupted.first_scope_owner_mismatch.?.issue);
    try std.testing.expectEqual(@as(?u32, @intFromEnum(global_scope)), corrupted.first_scope_owner_mismatch.?.expected_parent_scope_id);
    try std.testing.expectEqual(@as(?u32, @intFromEnum(detached_scope)), corrupted.first_scope_owner_mismatch.?.actual_parent_scope_id);
    try std.testing.expect(!corrupted.isClean());
}

test "exact scope audit allows only source-owned scope bridges to generated owners" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var ast = Ast.init(allocator, "");
    defer ast.deinit();

    const name = try ast.addString("_generated");
    const binding = try ast.addNode(.{ .tag = .binding_identifier, .span = name, .data = .{ .string_ref = name } });
    const generated_block = try ast.addListNode(.block_statement, name, try ast.addNodeList(&.{binding}));
    const sibling_generated_block = try ast.addListNode(.block_statement, name, try ast.addNodeList(&.{}));
    const parent_block = try ast.addListNode(.block_statement, name, try ast.addNodeList(&.{ sibling_generated_block, generated_block }));
    const root = try ast.addListNode(.program, name, try ast.addNodeList(&.{parent_block}));
    const detached_source_block = try ast.addListNode(.block_statement, name, try ast.addNodeList(&.{}));
    const source_class_body = try ast.addListNode(.class_body, name, try ast.addNodeList(&.{}));
    const class_none = @intFromEnum(AstNodeIndex.none);
    const source_class_extra = try ast.addExtras(&.{
        class_none,
        class_none,
        @intFromEnum(source_class_body),
        class_none,
        0,
        0,
        0,
        0,
    });
    const source_class = try ast.addNode(.{ .tag = .class_expression, .span = name, .data = .{ .extra = source_class_extra } });

    const global_scope: ScopeId = @enumFromInt(0);
    const emitted_parent_scope: ScopeId = @enumFromInt(1);
    const retained_source_class_scope: ScopeId = @enumFromInt(2);
    const detached_source_scope: ScopeId = @enumFromInt(3);
    const sibling_generated_scope: ScopeId = @enumFromInt(4);
    const generated_scope: ScopeId = @enumFromInt(5);
    const scopes = [_]Scope{
        .{ .parent = .none, .kind = .global, .is_strict = false },
        .{ .parent = global_scope, .kind = .block, .is_strict = false },
        .{ .parent = emitted_parent_scope, .kind = .class_body, .is_strict = false },
        .{ .parent = global_scope, .kind = .block, .is_strict = false },
        .{ .parent = emitted_parent_scope, .kind = .block, .is_strict = false },
        .{ .parent = retained_source_class_scope, .kind = .block, .is_strict = false },
    };
    var generated_names: std.StringHashMapUnmanaged(usize) = .empty;
    defer generated_names.deinit(allocator);
    try generated_names.put(allocator, "_generated", 0);
    const scope_maps = [_]std.StringHashMapUnmanaged(usize){ .empty, .empty, .empty, .empty, .empty, generated_names };
    const symbols = [_]Symbol{.{
        .name = name,
        .scope_id = generated_scope,
        .origin_scope = generated_scope,
        .kind = .variable_let,
        .declaration_span = name,
        .synthetic_name = "_generated",
    }};
    const symbol_ids = [_]?u32{0};
    const references = [_]Reference{.{
        .node_index = .none,
        .scope_id = generated_scope,
        .symbol_id = @enumFromInt(0),
        .flags = .{ .declare = true },
    }};
    var scope_owner_map: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer scope_owner_map.deinit(allocator);
    try scope_owner_map.put(allocator, @intFromEnum(root), @intFromEnum(global_scope));
    try scope_owner_map.put(allocator, @intFromEnum(parent_block), @intFromEnum(emitted_parent_scope));
    try scope_owner_map.put(allocator, @intFromEnum(sibling_generated_block), @intFromEnum(sibling_generated_scope));
    try scope_owner_map.put(allocator, @intFromEnum(generated_block), @intFromEnum(generated_scope));
    try scope_owner_map.put(allocator, @intFromEnum(detached_source_block), @intFromEnum(detached_source_scope));
    try scope_owner_map.put(allocator, @intFromEnum(source_class), @intFromEnum(retained_source_class_scope));
    const helpers: std.StringHashMapUnmanaged(usize) = .empty;
    const unresolved: std.AutoHashMapUnmanaged(u32, void) = .empty;
    const explicit_globals: std.AutoHashMapUnmanaged(u32, void) = .empty;
    const origins: std.AutoHashMapUnmanaged(u32, u32) = .empty;

    const report = try coverage.checkExactWithScopeBoundary(
        allocator,
        &ast,
        root,
        0,
        &symbol_ids,
        &symbols,
        &scopes,
        &scope_maps,
        &scope_owner_map,
        &references,
        &.{},
        &helpers,
        &unresolved,
        &explicit_globals,
        &origins,
        4,
    );
    try std.testing.expect(report.isClean());

    // Source-owned scopes may bridge the generated owner to its emitted AST
    // parent, but the full chain must reach that exact parent.
    var corrupted_scopes = scopes;
    corrupted_scopes[@intFromEnum(retained_source_class_scope)].parent = detached_source_scope;
    const detached_class_scope = try coverage.checkExactWithScopeBoundary(
        allocator,
        &ast,
        root,
        0,
        &symbol_ids,
        &symbols,
        &corrupted_scopes,
        &scope_maps,
        &scope_owner_map,
        &references,
        &.{},
        &helpers,
        &unresolved,
        &explicit_globals,
        &origins,
        4,
    );
    try std.testing.expectEqual(@as(usize, 1), detached_class_scope.scope_owner_parent_mismatch);
    try std.testing.expect(!detached_class_scope.isClean());

    // A generated sibling scope cannot bridge even when it eventually reaches
    // the emitted AST parent.
    corrupted_scopes = scopes;
    corrupted_scopes[@intFromEnum(generated_scope)].parent = sibling_generated_scope;
    const generated_scope_bridge = try coverage.checkExactWithScopeBoundary(
        allocator,
        &ast,
        root,
        0,
        &symbol_ids,
        &symbols,
        &corrupted_scopes,
        &scope_maps,
        &scope_owner_map,
        &references,
        &.{},
        &helpers,
        &unresolved,
        &explicit_globals,
        &origins,
        4,
    );
    try std.testing.expectEqual(@as(usize, 1), generated_scope_bridge.scope_owner_parent_mismatch);
    try std.testing.expect(!generated_scope_bridge.isClean());
}

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

fn checkDuplicatedIdentifierReferences(source: []const u8, options: TransformOptions, source_replaced: bool) !void {
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
    transformer.class_self_symbol_map = analyzer.class_self_symbol_map;
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
        if (@intFromEnum(ref.node_index) >= transformer.parser_node_count) {
            try std.testing.expectEqual(@as(?u32, @intFromEnum(source_ref.node_index)), transformer.reference_origin_map.get(@intFromEnum(ref.node_index)));
        }
        distinct = ref.node_index;
        reads += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), reads);
    try std.testing.expectEqual(@as(u32, 2), edited.symbols.items[id].reference_count);
    try std.testing.expectEqual(!source_replaced, original_is_live);
}

test "#4819 nullish identifier duplication records two exact read references" {
    try checkDuplicatedIdentifierReferences("function read(value) { return value ?? 2; }", .{
        .unsupported = TransformOptions.compat.fromESTarget(.es2019),
    }, false);
    try checkDuplicatedIdentifierReferences("function read(value) { use(value); { let value = 1; return value ?? 2; } }", .{
        .unsupported = TransformOptions.compat.fromESTarget(.es5),
    }, true);
}

test "optional chain duplicates exact local reads after block renaming" {
    try checkDuplicatedIdentifierReferences("function read(value) { return value?.field; }", .{
        .unsupported = TransformOptions.compat.fromESTarget(.es2019),
    }, false);
    try checkDuplicatedIdentifierReferences("function read(value) { return value?.(); }", .{
        .unsupported = TransformOptions.compat.fromESTarget(.es2019),
    }, false);
    try checkDuplicatedIdentifierReferences("function read(value) { use(value); { let value = {field: 1}; return value?.field; } }", .{
        .unsupported = TransformOptions.compat.fromESTarget(.es5),
    }, true);
}

test "optional chain keeps unresolved globals external with exact clone provenance" {
    for ([_][]const u8{ "external?.field;", "external?.();", "delete external?.field;" }) |source| {
        // Production does not collect per-node audit evidence; both modes
        // must distinguish external reads from missing local References.
        for ([_]bool{ false, true }) |audit| {
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            const allocator = arena.allocator();
            var scanner = try Scanner.init(allocator, source);
            var parser = Parser.init(allocator, &scanner);
            _ = try parser.parse();
            var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
            analyzer.collect_unresolved_reference_nodes = audit;
            try analyzer.analyze();
            try std.testing.expect(analyzer.unresolved_references.contains("external"));
            try std.testing.expectEqual(@as(usize, 0), analyzer.references.items.len);

            var original: ?u32 = null;
            for (parser.ast.nodes.items, 0..) |node, raw| {
                if (node.tag == .identifier_reference and std.mem.eql(u8, parser.ast.getText(node.data.string_ref), "external"))
                    original = @intCast(raw);
            }
            try std.testing.expect(original != null);

            var transformer = try Transformer.init(allocator, &parser.ast, .{
                .unsupported = TransformOptions.compat.fromESTarget(.es2019),
            });
            try transformer.initSymbolIds(analyzer.symbol_ids.items);
            transformer.symbols = analyzer.symbols.items;
            transformer.references = analyzer.references.items;
            transformer.scopes = analyzer.scopes.items;
            transformer.scope_maps = analyzer.scope_maps.items;
            transformer.scope_owner_map = analyzer.scope_owner_map;
            transformer.unresolved_references = &analyzer.unresolved_references;
            transformer.semantic_edit_enabled = true;
            if (audit) {
                transformer.synthetic_idents = .empty;
                transformer.unresolved_reference_nodes = &analyzer.unresolved_reference_nodes;
            }
            const root = try transformer.transform();
            const edited = (try transformer.finishSemanticEdit()).?;
            try std.testing.expectEqual(@as(usize, 0), edited.references.len);

            const reachable = try @import("../parser/ast_walk.zig").collectReachableNodeIndices(allocator, transformer.ast);
            var external_reads: usize = 0;
            for (reachable) |raw| {
                const node = transformer.ast.nodes.items[raw];
                if (node.tag != .identifier_reference or !std.mem.eql(u8, transformer.ast.getText(node.data.string_ref), "external")) continue;
                try std.testing.expectEqual(@as(?u32, null), edited.symbol_ids[raw]);
                if (audit and raw != original.?)
                    try std.testing.expectEqual(original, transformer.reference_origin_map.get(raw));
                external_reads += 1;
            }
            try std.testing.expectEqual(@as(usize, 2), external_reads);
            if (audit) {
                const exact = try coverage.checkExact(
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
                    &analyzer.unresolved_reference_nodes,
                    &transformer.explicit_global_reference_nodes,
                    &transformer.reference_origin_map,
                );
                try std.testing.expect(exact.isClean());
            }
        }
    }
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
    transformer.class_self_symbol_map = analyzer.class_self_symbol_map;
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
    transformer.class_self_symbol_map = analyzer.class_self_symbol_map;
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
    transformer.class_self_symbol_map = analyzer.class_self_symbol_map;
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
    transformer.class_self_symbol_map = analyzer.class_self_symbol_map;
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
        try std.testing.expectEqual(@as(u32, 2), generated.reference_count);
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
    transformer.class_self_symbol_map = analyzer.class_self_symbol_map;
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

fn scopeHasAncestor(scopes: []const @import("../semantic/scope.zig").Scope, child: @import("../semantic/scope.zig").ScopeId, ancestor: @import("../semantic/scope.zig").ScopeId) bool {
    var cursor = child;
    var hops: usize = 0;
    while (!cursor.isNone() and hops < scopes.len) : (hops += 1) {
        if (cursor == ancestor) return true;
        if (cursor.toIndex() >= scopes.len) return false;
        cursor = scopes[cursor.toIndex()].parent;
    }
    return false;
}

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
    transformer.class_self_symbol_map = analyzer.class_self_symbol_map;
    transformer.references = analyzer.references.items;
    transformer.synthetic_idents = .empty;
    transformer.scope_owner_map = analyzer.scope_owner_map;
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
    transformer.class_self_symbol_map = analyzer.class_self_symbol_map;
    transformer.references = analyzer.references.items;
    transformer.scopes = analyzer.scopes.items;
    transformer.scope_maps = analyzer.scope_maps.items;
    transformer.scope_owner_map = analyzer.scope_owner_map;
    transformer.semantic_edit_enabled = true;
    _ = try transformer.transform();
    const edited = (try transformer.finishSemanticEdit()).?;
    // The output keeps a callback-local `index` identity and splits the
    // emitted `var index` storage into the enclosing function scope.
    try std.testing.expectEqual(original_symbols + 2, edited.symbols.items.len);
    const generated_id: u32 = @intCast(original_symbols);
    try std.testing.expectEqualStrings("_loop2", transformer.ast.getText(edited.symbols.items[generated_id].name));
    const loop_storage_id = generated_id + 1;
    try std.testing.expectEqualStrings("index", transformer.ast.getText(edited.symbols.items[loop_storage_id].name));
    try std.testing.expectEqual(@import("../semantic/symbol.zig").SymbolKind.variable_var, edited.symbols.items[loop_storage_id].kind);
    try std.testing.expectEqual(@as(u32, 3), edited.symbols.items[loop_storage_id].reference_count);
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
    const emitted_header_id = loop_storage_id;
    try std.testing.expect(emitted_header_id != header_id);
    try std.testing.expectEqual(@as(?u32, emitted_header_id), edited.symbol_ids[@intFromEnum(argument)]);
    try std.testing.expectEqual(@as(?u32, null), transformer.reference_origin_map.get(@intFromEnum(argument)));
    var argument_refs: usize = 0;
    for (edited.references) |ref| {
        if (ref.node_index != argument) continue;
        try std.testing.expectEqual(emitted_header_id, @intFromEnum(ref.symbol_id));
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
    transformer.class_self_symbol_map = analyzer.class_self_symbol_map;
    transformer.references = analyzer.references.items;
    transformer.scopes = analyzer.scopes.items;
    transformer.scope_maps = analyzer.scope_maps.items;
    transformer.scope_owner_map = analyzer.scope_owner_map;
    transformer.semantic_edit_enabled = true;
    _ = try transformer.transform();
    const edited = (try transformer.finishSemanticEdit()).?;
    try std.testing.expectEqual(original_symbols + 5, edited.symbols.items.len);
    try std.testing.expectEqual(original_scopes + 4, edited.scopes.len);
    var template_symbol_ids: std.ArrayList(u32) = .empty;
    defer template_symbol_ids.deinit(allocator);
    var runtime_helper_preambles: usize = 0;
    for (edited.symbols.items[original_symbols..], original_symbols..) |symbol, raw_id| {
        if (symbol.synthetic_kind == .runtime_helper_preamble) {
            runtime_helper_preambles += 1;
            try std.testing.expectEqual(@as(?usize, raw_id), edited.helper_scope_map.get(symbol.synthetic_name));
            continue;
        }
        try template_symbol_ids.append(allocator, @intCast(raw_id));
    }
    try std.testing.expectEqual(@as(usize, 1), runtime_helper_preambles);
    try std.testing.expectEqual(@as(usize, 4), template_symbol_ids.items.len);
    for (0..2) |i| {
        const fn_id = template_symbol_ids.items[i * 2];
        const data_id = template_symbol_ids.items[i * 2 + 1];
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
    try std.testing.expect(edited.symbols.items[template_symbol_ids.items[0]].scope_id != edited.symbols.items[template_symbol_ids.items[3]].scope_id);
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
    transformer.class_self_symbol_map = analyzer.class_self_symbol_map;
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
        transformer.class_self_symbol_map = analyzer.class_self_symbol_map;
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

test "#4819 JSX runtime imports bind exact helper symbols before resync" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source = "const _jsx = 1; const _jsxs = 2; const _Fragment = 3; const _createElement = 4; export function View() { const view = <><A /><B /></>; const fallback = <A {...props} key=\"x\" />; return [view, fallback]; } console.log(_jsx, _jsxs, _Fragment, _createElement);";
    var scanner = try Scanner.init(allocator, source);
    var parser = Parser.init(allocator, &scanner);
    parser.configureFromExtension(".tsx");
    _ = try parser.parse();
    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    analyzer.is_module = true;
    try analyzer.analyze();
    try std.testing.expectEqual(@as(usize, 0), analyzer.errors.items.len);
    const user_jsx_id = analyzer.scope_maps.items[0].get("_jsx").?;
    const user_jsxs_id = analyzer.scope_maps.items[0].get("_jsxs").?;
    const user_fragment_id = analyzer.scope_maps.items[0].get("_Fragment").?;
    const user_create_element_id = analyzer.scope_maps.items[0].get("_createElement").?;
    var expected_call_scope: ?u32 = null;
    var scope_owners = analyzer.scope_owner_map.iterator();
    while (scope_owners.next()) |entry| {
        if (parser.ast.nodes.items[entry.key_ptr.*].tag == .function_declaration) expected_call_scope = entry.value_ptr.*;
    }
    const function_scope = expected_call_scope orelse return error.MissingJsxFunctionScope;

    var transformer = try Transformer.init(allocator, &parser.ast, .{
        .jsx_transform = true,
        .jsx_runtime = .automatic,
        .emit_runtime_helper_imports = true,
    });
    try transformer.initSymbolIds(analyzer.symbol_ids.items);
    transformer.symbols = analyzer.symbols.items;
    transformer.class_self_symbol_map = analyzer.class_self_symbol_map;
    transformer.references = analyzer.references.items;
    transformer.scopes = analyzer.scopes.items;
    transformer.scope_maps = analyzer.scope_maps.items;
    transformer.scope_owner_map = analyzer.scope_owner_map;
    transformer.semantic_edit_enabled = true;
    _ = try transformer.transform();
    const edited = (try transformer.finishSemanticEdit()).?;

    const cases = [_]struct { local: []const u8, user_id: usize }{
        .{ .local = transformer.jsx_import_info.jsx_local, .user_id = user_jsx_id },
        .{ .local = transformer.jsx_import_info.jsxs_local, .user_id = user_jsxs_id },
        .{ .local = transformer.jsx_import_info.fragment_local, .user_id = user_fragment_id },
        .{ .local = transformer.jsx_import_info.createElement_local, .user_id = user_create_element_id },
    };
    for (cases) |case| {
        try std.testing.expect(case.local.len > 0);
        const helper_id = edited.helper_scope_map.get(case.local) orelse return error.MissingJsxHelperSymbol;
        try std.testing.expect(helper_id != case.user_id);
        try std.testing.expectEqual(@import("../semantic/symbol.zig").SymbolKind.import_binding, edited.symbols.items[helper_id].kind);
        var declarations: usize = 0;
        var reads: usize = 0;
        for (edited.references) |reference| {
            if (@intFromEnum(reference.symbol_id) != helper_id) continue;
            if (reference.flags.declare) {
                declarations += 1;
            } else if (reference.flags.read) {
                reads += 1;
                try std.testing.expectEqual(function_scope, @intFromEnum(reference.scope_id));
                const node = transformer.ast.getNode(reference.node_index);
                try std.testing.expectEqual(@as(?u32, @intCast(helper_id)), edited.symbol_ids[@intFromEnum(reference.node_index)]);
                try std.testing.expectEqualStrings(case.local, transformer.ast.identifierNameText(node));
            }
        }
        try std.testing.expectEqual(@as(usize, 1), declarations);
        try std.testing.expect(reads >= 1);
        try std.testing.expectEqual(@as(u32, @intCast(reads)), edited.symbols.items[helper_id].reference_count);
    }
    try std.testing.expectEqual(@as(usize, 0), transformer.pending_runtime_helper_chains.count());
}

test "#4819 classic JSX factory reference follows its lexical binding" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var scanner = try Scanner.init(allocator, "// @flow\nexport function View(React) { return <div />; }");
    var parser = Parser.init(allocator, &scanner);
    parser.configureFromExtension(".jsx");
    _ = try parser.parse();
    try std.testing.expectEqual(@as(usize, 0), parser.errors.items.len);

    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    analyzer.is_module = true;
    try analyzer.analyze();
    try std.testing.expectEqual(@as(usize, 0), analyzer.errors.items.len);
    var expected_symbol: ?u32 = null;
    for (analyzer.symbols.items, 0..) |symbol, raw| {
        if (symbol.kind == .parameter and std.mem.eql(u8, symbol.nameText(parser.ast.source), "React"))
            expected_symbol = @intCast(raw);
    }
    const react_parameter = expected_symbol orelse return error.MissingReactParameter;

    var transformer = try Transformer.init(allocator, &parser.ast, .{
        .jsx_transform = true,
        .jsx_runtime = .classic,
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

    var factory_reads: usize = 0;
    for (transformer.ast.nodes.items, 0..) |node, raw| {
        if (node.tag != .identifier_reference or !std.mem.eql(u8, transformer.ast.getText(node.span), "React")) continue;
        try std.testing.expect(raw < edited.symbol_ids.len);
        try std.testing.expectEqual(@as(?u32, react_parameter), edited.symbol_ids[raw]);
        var has_reference = false;
        for (edited.references) |reference| {
            if (@intFromEnum(reference.node_index) != raw) continue;
            try std.testing.expectEqual(react_parameter, @intFromEnum(reference.symbol_id));
            try std.testing.expect(reference.flags.read);
            has_reference = true;
        }
        try std.testing.expect(has_reference);
        factory_reads += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), factory_reads);
    try std.testing.expectEqual(@as(u32, 1), edited.symbols.items[react_parameter].reference_count);
}

test "#4819 classic JSX custom factory binds through the current scope" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var scanner = try Scanner.init(allocator, "// @flow\nfunction View(h) { return <div />; }");
    var parser = Parser.init(allocator, &scanner);
    parser.configureFromExtension(".jsx");
    _ = try parser.parse();
    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    try analyzer.analyze();
    var expected_symbol: ?u32 = null;
    for (analyzer.symbols.items, 0..) |symbol, raw| {
        if (symbol.kind == .parameter and std.mem.eql(u8, symbol.nameText(parser.ast.source), "h"))
            expected_symbol = @intCast(raw);
    }
    const factory_symbol = expected_symbol orelse return error.MissingJsxFactoryParameter;

    var transformer = try Transformer.init(allocator, &parser.ast, .{
        .jsx_transform = true,
        .jsx_runtime = .classic,
        .jsx_factory = "h",
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

    var factory_reads: usize = 0;
    for (transformer.ast.nodes.items, 0..) |node, raw| {
        if (node.tag != .identifier_reference or !std.mem.eql(u8, transformer.ast.getText(node.span), "h")) continue;
        try std.testing.expect(raw < edited.symbol_ids.len);
        try std.testing.expectEqual(@as(?u32, factory_symbol), edited.symbol_ids[raw]);
        factory_reads += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), factory_reads);
    try std.testing.expectEqual(@as(u32, 1), edited.symbols.items[factory_symbol].reference_count);
}

test "#4819 Flow component classic JSX reads are recorded in the transform graph" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source = "// @flow\nimport React from 'react'; " ++
        "export component View(ref?: mixed, value: number, ...props: { label?: string }) { " ++
        "return <><div value={value} /><span>{props.label}</span></>; }";
    var scanner = try Scanner.init(allocator, source);
    var parser = Parser.init(allocator, &scanner);
    parser.configureFromExtension(".jsx");
    _ = try parser.parse();
    try std.testing.expectEqual(@as(usize, 0), parser.errors.items.len);

    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    analyzer.is_module = true;
    try analyzer.analyze();
    try std.testing.expectEqual(@as(usize, 0), analyzer.errors.items.len);
    const react_symbol: u32 = @intCast(analyzer.scope_maps.items[0].get("React") orelse return error.MissingReactImport);

    var transformer = try Transformer.init(allocator, &parser.ast, .{
        .jsx_transform = true,
        .jsx_runtime = .classic,
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

    var react_reads: usize = 0;
    for (transformer.ast.nodes.items, 0..) |node, raw| {
        if (node.tag != .identifier_reference or !std.mem.eql(u8, transformer.ast.getText(node.span), "React")) continue;
        try std.testing.expect(raw < edited.symbol_ids.len);
        try std.testing.expectEqual(@as(?u32, react_symbol), edited.symbol_ids[raw]);
        var has_reference = false;
        for (edited.references) |reference| {
            if (@intFromEnum(reference.node_index) != raw) continue;
            try std.testing.expectEqual(react_symbol, @intFromEnum(reference.symbol_id));
            try std.testing.expect(reference.flags.read);
            has_reference = true;
        }
        try std.testing.expect(has_reference);
        react_reads += 1;
    }
    try std.testing.expectEqual(@as(usize, 5), react_reads);
    try std.testing.expectEqual(@as(u32, 5), edited.symbols.items[react_symbol].reference_count);
}

test "#4819 JSX dev runtime call binds its isolated import symbol" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source = "const _jsxDEV = 1; export function View() { return <A />; } console.log(_jsxDEV);";
    var scanner = try Scanner.init(allocator, source);
    var parser = Parser.init(allocator, &scanner);
    parser.configureFromExtension(".tsx");
    _ = try parser.parse();
    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    analyzer.is_module = true;
    try analyzer.analyze();
    try std.testing.expectEqual(@as(usize, 0), analyzer.errors.items.len);
    const user_id = analyzer.scope_maps.items[0].get("_jsxDEV").?;
    var expected_call_scope: ?u32 = null;
    var scope_owners = analyzer.scope_owner_map.iterator();
    while (scope_owners.next()) |entry| {
        if (parser.ast.nodes.items[entry.key_ptr.*].tag == .function_declaration) expected_call_scope = entry.value_ptr.*;
    }
    const function_scope = expected_call_scope orelse return error.MissingJsxDevFunctionScope;

    var transformer = try Transformer.init(allocator, &parser.ast, .{
        .jsx_transform = true,
        .jsx_runtime = .automatic_dev,
        .emit_runtime_helper_imports = true,
    });
    try transformer.initSymbolIds(analyzer.symbol_ids.items);
    transformer.symbols = analyzer.symbols.items;
    transformer.class_self_symbol_map = analyzer.class_self_symbol_map;
    transformer.references = analyzer.references.items;
    transformer.scopes = analyzer.scopes.items;
    transformer.scope_maps = analyzer.scope_maps.items;
    transformer.scope_owner_map = analyzer.scope_owner_map;
    transformer.semantic_edit_enabled = true;
    _ = try transformer.transform();
    const edited = (try transformer.finishSemanticEdit()).?;

    const local = transformer.jsx_import_info.jsxDEV_local;
    const helper_id = edited.helper_scope_map.get(local) orelse return error.MissingJsxDevHelperSymbol;
    try std.testing.expect(helper_id != user_id);
    try std.testing.expectEqual(@import("../semantic/symbol.zig").SymbolKind.import_binding, edited.symbols.items[helper_id].kind);
    var reads: usize = 0;
    for (edited.references) |reference| {
        if (@intFromEnum(reference.symbol_id) != helper_id or reference.flags.declare) continue;
        try std.testing.expect(reference.flags.read);
        try std.testing.expectEqual(function_scope, @intFromEnum(reference.scope_id));
        const node = transformer.ast.getNode(reference.node_index);
        try std.testing.expectEqual(@as(?u32, @intCast(helper_id)), edited.symbol_ids[@intFromEnum(reference.node_index)]);
        try std.testing.expectEqualStrings(local, transformer.ast.identifierNameText(node));
        reads += 1;
    }
    try std.testing.expectEqual(@as(u32, @intCast(reads)), edited.symbols.items[helper_id].reference_count);
    try std.testing.expect(reads >= 1);
    try std.testing.expectEqual(@as(usize, 0), transformer.pending_runtime_helper_chains.count());
}

test "#4819 standalone JSX imports bind exact symbols without bundler helper imports" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source = "const _jsx = 'user'; export function View() { return <A />; } console.log(_jsx);";
    var scanner = try Scanner.init(allocator, source);
    var parser = Parser.init(allocator, &scanner);
    parser.configureFromExtension(".tsx");
    _ = try parser.parse();
    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    analyzer.is_module = true;
    try analyzer.analyze();
    const user_id = analyzer.scope_maps.items[0].get("_jsx").?;
    var function_scope: ?u32 = null;
    var scope_owners = analyzer.scope_owner_map.iterator();
    while (scope_owners.next()) |entry| {
        if (parser.ast.nodes.items[entry.key_ptr.*].tag == .function_declaration) function_scope = entry.value_ptr.*;
    }
    const expected_function_scope = function_scope orelse return error.MissingStandaloneJsxFunctionScope;

    var transformer = try Transformer.init(allocator, &parser.ast, .{
        .jsx_transform = true,
        .jsx_runtime = .automatic,
        .emit_jsx_runtime_imports = true,
    });
    try transformer.initSymbolIds(analyzer.symbol_ids.items);
    transformer.symbols = analyzer.symbols.items;
    transformer.class_self_symbol_map = analyzer.class_self_symbol_map;
    transformer.references = analyzer.references.items;
    transformer.scopes = analyzer.scopes.items;
    transformer.scope_maps = analyzer.scope_maps.items;
    transformer.scope_owner_map = analyzer.scope_owner_map;
    transformer.semantic_edit_enabled = true;
    _ = try transformer.transform();
    const edited = (try transformer.finishSemanticEdit()).?;

    const local = transformer.jsx_import_info.jsx_local;
    try std.testing.expectEqualStrings("_jsx2", local);
    const helper_id = edited.helper_scope_map.get(local) orelse return error.MissingStandaloneJsxHelperSymbol;
    try std.testing.expect(helper_id != user_id);
    try std.testing.expectEqual(@import("../semantic/symbol.zig").SymbolKind.import_binding, edited.symbols.items[helper_id].kind);
    var declarations: usize = 0;
    var reads: usize = 0;
    for (edited.references) |reference| {
        if (@intFromEnum(reference.symbol_id) != helper_id) continue;
        if (reference.flags.declare) {
            declarations += 1;
        } else if (reference.flags.read) {
            reads += 1;
            try std.testing.expectEqual(expected_function_scope, @intFromEnum(reference.scope_id));
            try std.testing.expectEqual(@as(?u32, @intCast(helper_id)), edited.symbol_ids[@intFromEnum(reference.node_index)]);
        }
    }
    try std.testing.expectEqual(@as(usize, 1), declarations);
    try std.testing.expectEqual(@as(usize, 1), reads);
    try std.testing.expectEqual(@as(u32, @intCast(reads)), edited.symbols.items[helper_id].reference_count);
    try std.testing.expectEqual(@as(usize, 0), transformer.pending_runtime_helper_chains.count());
}

test "#4819 for-in temporaries bind symbols during lowering" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const NodeIndex = @import("../parser/ast.zig").NodeIndex;
    const source = "for (const value in source) use(value);";
    var scanner = try Scanner.init(allocator, source);
    var parser = Parser.init(allocator, &scanner);
    parser.configureFromExtension(".mjs");
    _ = try parser.parse();
    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    analyzer.is_module = true;
    try analyzer.analyze();
    var source_loop: ?NodeIndex = null;
    for (parser.ast.nodes.items, 0..) |node, index| {
        if (node.tag == .for_in_statement) source_loop = @enumFromInt(index);
    }
    const loop = source_loop orelse return error.MissingForInLoop;
    const loop_scope = analyzer.scope_owner_map.get(@intFromEnum(loop)) orelse return error.MissingForInScope;

    var transformer = try Transformer.init(allocator, &parser.ast, .{});
    try transformer.initSymbolIds(analyzer.symbol_ids.items);
    transformer.symbols = analyzer.symbols.items;
    transformer.class_self_symbol_map = analyzer.class_self_symbol_map;
    transformer.references = analyzer.references.items;
    transformer.scopes = analyzer.scopes.items;
    transformer.scope_maps = analyzer.scope_maps.items;
    transformer.scope_owner_map = analyzer.scope_owner_map;
    transformer.semantic_edit_enabled = true;
    transformer.current_scope = @enumFromInt(loop_scope);
    const lowering = @import("es2015_for_of.zig").ES2015ForOf(Transformer);
    _ = try lowering.rewriteForIn(&transformer, loop, parser.ast.getNode(loop));

    const expected_names = [_][]const u8{ "_a", "_b", "_keys", "_idx" };
    var found: usize = 0;
    for (transformer.ast.nodes.items[transformer.parser_node_count..], transformer.parser_node_count..) |node, raw| {
        if (node.tag != .binding_identifier) continue;
        const name = transformer.ast.getText(node.data.string_ref);
        var expected = false;
        for (expected_names) |expected_name| {
            if (std.mem.eql(u8, name, expected_name)) expected = true;
        }
        if (!expected) continue;
        found += 1;
        const symbol_id = if (raw < transformer.symbol_ids.items.len) transformer.symbol_ids.items[raw] else null;
        try std.testing.expect(symbol_id != null);
    }
    try std.testing.expectEqual(expected_names.len, found);
}

test "#4819 generator for-of temporaries bind symbols during lowering" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const NodeIndex = @import("../parser/ast.zig").NodeIndex;
    const source = "for (const value of source) use(value);";
    var scanner = try Scanner.init(allocator, source);
    var parser = Parser.init(allocator, &scanner);
    parser.configureFromExtension(".mjs");
    _ = try parser.parse();
    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    analyzer.is_module = true;
    try analyzer.analyze();
    var source_loop: ?NodeIndex = null;
    for (parser.ast.nodes.items, 0..) |node, index| {
        if (node.tag == .for_of_statement) source_loop = @enumFromInt(index);
    }
    const loop = source_loop orelse return error.MissingForOfLoop;
    const loop_scope = analyzer.scope_owner_map.get(@intFromEnum(loop)) orelse return error.MissingForOfScope;

    var transformer = try Transformer.init(allocator, &parser.ast, .{});
    try transformer.initSymbolIds(analyzer.symbol_ids.items);
    transformer.symbols = analyzer.symbols.items;
    transformer.class_self_symbol_map = analyzer.class_self_symbol_map;
    transformer.references = analyzer.references.items;
    transformer.scopes = analyzer.scopes.items;
    transformer.scope_maps = analyzer.scope_maps.items;
    transformer.scope_owner_map = analyzer.scope_owner_map;
    transformer.semantic_edit_enabled = true;
    transformer.current_scope = @enumFromInt(loop_scope);
    transformer.state_machine_depth = 1;
    const lowering = @import("es2015_for_of.zig").ES2015ForOf(Transformer);
    _ = try lowering.rewriteForOf(&transformer, loop, parser.ast.getNode(loop), .none, true);

    const expected_names = [_][]const u8{ "_a", "_b", "_c", "_d", "_step" };
    var found: usize = 0;
    for (transformer.ast.nodes.items[transformer.parser_node_count..], transformer.parser_node_count..) |node, raw| {
        if (node.tag != .binding_identifier) continue;
        const name = transformer.ast.getText(node.data.string_ref);
        var expected = false;
        for (expected_names) |expected_name| {
            if (std.mem.eql(u8, name, expected_name)) expected = true;
        }
        if (!expected) continue;
        found += 1;
        const symbol_id = if (raw < transformer.symbol_ids.items.len) transformer.symbol_ids.items[raw] else null;
        try std.testing.expect(symbol_id != null);
    }
    try std.testing.expectEqual(expected_names.len, found);
}

test "#4819 optional catch binding gets a symbol in its catch scope" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var scanner = try Scanner.init(allocator, "const _a = 9; const _b = 8; try { throw 1; } catch { console.log(_a, _b); } try { throw 2; } catch { console.log(_a, _b); }");
    var parser = Parser.init(allocator, &scanner);
    parser.configureFromExtension(".mjs");
    _ = try parser.parse();
    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    analyzer.is_module = true;
    try analyzer.analyze();
    const original_symbols = analyzer.symbols.items.len;
    var outer_b_id: ?usize = null;
    for (analyzer.symbols.items, 0..) |symbol, id| {
        if (std.mem.eql(u8, symbol.nameText(parser.ast.source), "_b")) outer_b_id = id;
    }

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
    transformer.semantic_edit_enabled = true;
    _ = try transformer.transform();
    const edited = (try transformer.finishSemanticEdit()).?;
    try std.testing.expectEqual(original_symbols + 2, edited.symbols.items.len);
    try std.testing.expect(edited.symbols.items[original_symbols].scope_id != edited.symbols.items[original_symbols + 1].scope_id);
    for (edited.symbols.items[original_symbols..]) |generated| {
        try std.testing.expectEqual(@import("../semantic/symbol.zig").SymbolKind.catch_binding, generated.kind);
        try std.testing.expectEqual(@import("../semantic/scope.zig").ScopeKind.catch_clause, edited.scopes[generated.scope_id.toIndex()].kind);
        try std.testing.expectEqualStrings("_c", transformer.ast.getText(generated.name));
        try std.testing.expectEqual(@as(u32, 0), generated.reference_count);
    }
    var outer_b_reads: usize = 0;
    for (edited.references) |reference| {
        if (@intFromEnum(reference.symbol_id) == (outer_b_id orelse return error.TestUnexpectedResult) and reference.flags.read) outer_b_reads += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), outer_b_reads);
    var bindings: usize = 0;
    for (edited.symbol_ids, 0..) |maybe_id, i| {
        if (maybe_id != null and maybe_id.? >= original_symbols and transformer.ast.nodes.items[i].tag == .binding_identifier) bindings += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), bindings);
}

test "#4819 ES5 for-of iterator uses one var symbol across loop and finally" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var scanner = try Scanner.init(allocator,
        \\export function consume(values) {
        \\  const seen = [];
        \\  outer: for (const value of values) { seen.push(value); if (value === 2) break outer; }
        \\  return seen;
        \\}
    );
    var parser = Parser.init(allocator, &scanner);
    parser.configureFromExtension(".mjs");
    _ = try parser.parse();
    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    analyzer.is_module = true;
    try analyzer.analyze();
    var source_loop_scope: ?@import("../semantic/scope.zig").ScopeId = null;
    for (parser.ast.nodes.items, 0..) |node, raw| {
        if (node.tag != .for_of_statement) continue;
        source_loop_scope = @enumFromInt(analyzer.scope_owner_map.get(@intCast(raw)) orelse return error.TestUnexpectedResult);
    }
    const loop_scope = source_loop_scope orelse return error.TestUnexpectedResult;
    const outer_scope = analyzer.scopes.items[loop_scope.toIndex()].parent;
    const original_symbols = analyzer.symbols.items.len;

    var transformer = try Transformer.init(allocator, &parser.ast, .{ .unsupported = TransformOptions.compat.fromESTarget(.es5) });
    try transformer.initSymbolIds(analyzer.symbol_ids.items);
    transformer.symbols = analyzer.symbols.items;
    transformer.references = analyzer.references.items;
    transformer.scopes = analyzer.scopes.items;
    transformer.scope_maps = analyzer.scope_maps.items;
    transformer.scope_owner_map = analyzer.scope_owner_map;
    transformer.semantic_edit_enabled = true;
    _ = try transformer.transform();
    const edited = (try transformer.finishSemanticEdit()).?;

    var iterator_id: ?u32 = null;
    var step_id: ?u32 = null;
    var completion_id: ?u32 = null;
    var did_error_id: ?u32 = null;
    var error_value_id: ?u32 = null;
    var catch_parameter_id: ?u32 = null;
    for (edited.symbols.items[original_symbols..], original_symbols..) |symbol, id| {
        if (symbol.kind == .catch_binding) catch_parameter_id = @intCast(id);
        if (std.mem.eql(u8, transformer.ast.getText(symbol.name), "_a")) completion_id = @intCast(id);
        if (std.mem.eql(u8, transformer.ast.getText(symbol.name), "_b")) did_error_id = @intCast(id);
        if (std.mem.eql(u8, transformer.ast.getText(symbol.name), "_c")) error_value_id = @intCast(id);
        if (std.mem.eql(u8, transformer.ast.getText(symbol.name), "_d")) iterator_id = @intCast(id);
        if (std.mem.startsWith(u8, transformer.ast.getText(symbol.name), "_step")) step_id = @intCast(id);
    }
    const id = iterator_id orelse return error.TestUnexpectedResult;
    const symbol = edited.symbols.items[id];
    try std.testing.expectEqual(@import("../semantic/symbol.zig").SymbolKind.variable_var, symbol.kind);
    try std.testing.expectEqual(@import("../semantic/scope.zig").ScopeKind.function, edited.scopes[symbol.scope_id.toIndex()].kind);

    const reachable_nodes = try @import("../parser/ast_walk.zig").collectReachableNodeIndices(allocator, transformer.ast);
    var bindings: usize = 0;
    var reads: usize = 0;
    for (reachable_nodes) |raw| {
        const maybe_id = edited.symbol_ids[raw];
        if (maybe_id != id) continue;
        const tag = transformer.ast.nodes.items[raw].tag;
        if (tag == .binding_identifier) bindings += 1;
        if (tag == .identifier_reference) reads += 1;
    }
    // The final hoist leaves one reachable `var _d` binding node for this
    // legal var SymbolId; removed intermediate declarations carry no identity.
    try std.testing.expectEqual(@as(usize, 1), bindings);
    try std.testing.expectEqual(@as(usize, 3), reads);
    try std.testing.expectEqual(@as(u32, 3), symbol.reference_count);
    var semantic_reads: usize = 0;
    var loop_reads: usize = 0;
    var finally_reads: usize = 0;
    for (edited.references) |ref| {
        if (@intFromEnum(ref.symbol_id) != id or ref.flags.declare) continue;
        try std.testing.expect(ref.flags.read);
        try std.testing.expectEqual(@as(?u32, id), edited.symbol_ids[@intFromEnum(ref.node_index)]);
        if (ref.scope_id == loop_scope) {
            loop_reads += 1;
        } else if (ref.scope_id == outer_scope) {
            finally_reads += 1;
        } else {
            if (scopeHasAncestor(edited.scopes, ref.scope_id, loop_scope)) {
                loop_reads += 1;
            } else if (scopeHasAncestor(edited.scopes, ref.scope_id, outer_scope)) {
                finally_reads += 1;
            } else return error.TestUnexpectedResult;
        }
        semantic_reads += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), semantic_reads);
    try std.testing.expectEqual(@as(usize, 1), loop_reads);
    try std.testing.expectEqual(@as(usize, 2), finally_reads);

    const step = step_id orelse return error.TestUnexpectedResult;
    const step_symbol = edited.symbols.items[step];
    try std.testing.expectEqual(@import("../semantic/symbol.zig").SymbolKind.variable_var, step_symbol.kind);
    try std.testing.expectEqual(symbol.scope_id, step_symbol.scope_id);
    try std.testing.expectEqual(@as(u32, 2), step_symbol.reference_count);
    var step_bindings: usize = 0;
    var step_reads: usize = 0;
    var step_writes: usize = 0;
    for (edited.symbol_ids, 0..) |maybe_id, raw| {
        if (maybe_id != step) continue;
        const tag = transformer.ast.nodes.items[raw].tag;
        if (tag == .binding_identifier) step_bindings += 1;
        if (tag == .identifier_reference) {
            for (edited.references) |ref| {
                if (@intFromEnum(ref.node_index) != raw or @intFromEnum(ref.symbol_id) != step) continue;
                try std.testing.expect(scopeHasAncestor(edited.scopes, ref.scope_id, loop_scope));
                if (ref.flags.read) step_reads += 1;
                if (ref.flags.write) step_writes += 1;
            }
        }
    }
    try std.testing.expectEqual(@as(usize, 1), step_bindings);
    try std.testing.expectEqual(@as(usize, 1), step_reads);
    try std.testing.expectEqual(@as(usize, 1), step_writes);

    const completion = completion_id orelse return error.TestUnexpectedResult;
    const completion_symbol = edited.symbols.items[completion];
    try std.testing.expectEqual(@import("../semantic/symbol.zig").SymbolKind.variable_var, completion_symbol.kind);
    try std.testing.expectEqual(symbol.scope_id, completion_symbol.scope_id);
    try std.testing.expectEqual(@as(u32, 3), completion_symbol.reference_count);
    var completion_bindings: usize = 0;
    var completion_loop_writes: usize = 0;
    var completion_finally_reads: usize = 0;
    for (reachable_nodes) |raw| {
        const maybe_id = edited.symbol_ids[raw];
        if (maybe_id != completion) continue;
        const tag = transformer.ast.nodes.items[raw].tag;
        if (tag == .binding_identifier) completion_bindings += 1;
        if (tag == .identifier_reference) {
            for (edited.references) |ref| {
                if (@intFromEnum(ref.node_index) != raw or @intFromEnum(ref.symbol_id) != completion) continue;
                if (ref.scope_id == loop_scope and ref.flags.write) completion_loop_writes += 1;
                if (scopeHasAncestor(edited.scopes, ref.scope_id, outer_scope) and ref.flags.read) completion_finally_reads += 1;
            }
        }
    }
    // Only the final reachable completion binding remains after for-of
    // lowering; discarded initializer bindings have no emitted identity.
    try std.testing.expectEqual(@as(usize, 1), completion_bindings);
    try std.testing.expectEqual(@as(usize, 2), completion_loop_writes);
    try std.testing.expectEqual(@as(usize, 1), completion_finally_reads);

    const catch_parameter = catch_parameter_id orelse return error.TestUnexpectedResult;
    const catch_symbol = edited.symbols.items[catch_parameter];
    const catch_scope = catch_symbol.scope_id;
    try std.testing.expectEqual(@import("../semantic/symbol.zig").SymbolKind.catch_binding, catch_symbol.kind);
    try std.testing.expectEqual(@import("../semantic/scope.zig").ScopeKind.catch_clause, edited.scopes[catch_scope.toIndex()].kind);
    try std.testing.expect(scopeHasAncestor(edited.scopes, catch_scope, outer_scope));
    try std.testing.expectEqual(@as(u32, 1), catch_symbol.reference_count);
    const reachable = try @import("../parser/ast_walk.zig").collectReachableNodeIndices(allocator, transformer.ast);
    var live_catch_owners: usize = 0;
    for (reachable) |raw| {
        if (transformer.ast.nodes.items[raw].tag != .catch_clause) continue;
        if (edited.scope_owner_map.get(raw) == @intFromEnum(catch_scope)) live_catch_owners += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), live_catch_owners);
    for ([_]u32{ did_error_id orelse return error.TestUnexpectedResult, error_value_id orelse return error.TestUnexpectedResult }) |temp| {
        const generated = edited.symbols.items[temp];
        try std.testing.expectEqual(@import("../semantic/symbol.zig").SymbolKind.variable_var, generated.kind);
        try std.testing.expectEqual(symbol.scope_id, generated.scope_id);
        try std.testing.expectEqual(@as(u32, 2), generated.reference_count);
        var temp_bindings: usize = 0;
        var catch_writes: usize = 0;
        var temp_finally_reads: usize = 0;
        for (reachable_nodes) |raw| {
            const maybe_id = edited.symbol_ids[raw];
            if (maybe_id != temp) continue;
            if (transformer.ast.nodes.items[raw].tag == .binding_identifier) temp_bindings += 1;
        }
        for (edited.references) |ref| {
            if (@intFromEnum(ref.symbol_id) != temp or ref.flags.declare) continue;
            try std.testing.expectEqual(@as(?u32, temp), edited.symbol_ids[@intFromEnum(ref.node_index)]);
            if (scopeHasAncestor(edited.scopes, ref.scope_id, catch_scope) and ref.flags.write) catch_writes += 1;
            if (scopeHasAncestor(edited.scopes, ref.scope_id, outer_scope) and ref.flags.read) temp_finally_reads += 1;
        }
        // The final catch body retains one binding node for this function-
        // scoped symbol; intermediate hoist declarations are discarded.
        try std.testing.expectEqual(@as(usize, 1), temp_bindings);
        try std.testing.expectEqual(@as(usize, 1), catch_writes);
        try std.testing.expectEqual(@as(usize, 1), temp_finally_reads);
    }
    var catch_bindings: usize = 0;
    var catch_reads: usize = 0;
    for (reachable_nodes) |raw| {
        const maybe_id = edited.symbol_ids[raw];
        if (maybe_id != catch_parameter) continue;
        if (transformer.ast.nodes.items[raw].tag == .binding_identifier) catch_bindings += 1;
    }
    for (edited.references) |ref| {
        if (@intFromEnum(ref.symbol_id) != catch_parameter or ref.flags.declare) continue;
        try std.testing.expect(scopeHasAncestor(edited.scopes, ref.scope_id, catch_scope));
        try std.testing.expect(ref.flags.read);
        catch_reads += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), catch_bindings);
    try std.testing.expectEqual(@as(usize, 1), catch_reads);
}

test "#4819 for-of using head keeps one generated binding and reference" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var scanner = try Scanner.init(allocator,
        \\export function consume(resources, _using) {
        \\  for (using item of resources) { globalThis.item = item; }
        \\  return _using;
        \\}
    );
    var parser = Parser.init(allocator, &scanner);
    parser.configureFromExtension(".mjs");
    _ = try parser.parse();
    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    analyzer.is_module = true;
    try analyzer.analyze();
    var source_scope: ?@import("../semantic/scope.zig").ScopeId = null;
    for (parser.ast.nodes.items, 0..) |node, raw| {
        if (node.tag == .for_of_statement)
            source_scope = @enumFromInt(analyzer.scope_owner_map.get(@intCast(raw)) orelse return error.TestUnexpectedResult);
    }
    const loop_scope = source_scope orelse return error.TestUnexpectedResult;
    const var_scope = analyzer.scopes.items[loop_scope.toIndex()].parent;
    const original_symbols = analyzer.symbols.items.len;

    var transformer = try Transformer.init(allocator, &parser.ast, .{ .unsupported = TransformOptions.compat.fromESTarget(.es5) });
    try transformer.initSymbolIds(analyzer.symbol_ids.items);
    transformer.symbols = analyzer.symbols.items;
    transformer.references = analyzer.references.items;
    transformer.scopes = analyzer.scopes.items;
    transformer.scope_maps = analyzer.scope_maps.items;
    transformer.scope_owner_map = analyzer.scope_owner_map;
    transformer.semantic_edit_enabled = true;
    _ = try transformer.transform();
    const edited = (try transformer.finishSemanticEdit()).?;

    var head_id: ?u32 = null;
    for (edited.symbols.items[original_symbols..], original_symbols..) |symbol, id| {
        if (std.mem.eql(u8, transformer.ast.getText(symbol.name), "_using2")) head_id = @intCast(id);
    }
    const id = head_id orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(var_scope, edited.symbols.items[id].scope_id);
    try std.testing.expectEqual(@import("../semantic/scope.zig").ScopeKind.function, edited.scopes[var_scope.toIndex()].kind);
    try std.testing.expectEqual(@import("../semantic/symbol.zig").SymbolKind.variable_const, edited.symbols.items[id].kind);
    try std.testing.expectEqual(@as(u32, 1), edited.symbols.items[id].reference_count);
    var bindings: usize = 0;
    var reads: usize = 0;
    for (edited.symbol_ids, 0..) |maybe_id, raw| {
        if (maybe_id != id) continue;
        const tag = transformer.ast.nodes.items[raw].tag;
        if (tag == .binding_identifier) bindings += 1;
        if (tag == .identifier_reference) reads += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), bindings);
    try std.testing.expectEqual(@as(usize, 1), reads);
    for (edited.references) |ref| {
        if (@intFromEnum(ref.symbol_id) != id or ref.flags.declare) continue;
        try std.testing.expect(scopeHasAncestor(edited.scopes, ref.scope_id, loop_scope));
        try std.testing.expect(ref.flags.read);
    }
}

test "#4819 downlevel using lowering preserves exact transform identities" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source = "function run(resource: any, _stack: any, _error: any, _hasError: any, _: any, __using: any, __callDispose: any) { " ++
        "using local = resource; return local + _stack; } " ++
        "async function wait(resource: any) { await using asyncLocal = resource; return asyncLocal; } " ++
        "function nested(resource: any) { { using blockLocal = resource; use(blockLocal); } return 1; } " ++
        "function loop(resources: any) { for (using item of resources) use(item); }";
    var scanner = try Scanner.init(allocator, source);
    var parser = Parser.init(allocator, &scanner);
    parser.configureFromExtension(".ts");
    _ = try parser.parse();
    try std.testing.expectEqual(@as(usize, 0), parser.errors.items.len);

    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    analyzer.collect_unresolved_reference_nodes = true;
    try analyzer.analyze();
    try std.testing.expectEqual(@as(usize, 0), analyzer.errors.items.len);

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
    transformer.synthetic_idents = .empty;
    transformer.unresolved_reference_nodes = &analyzer.unresolved_reference_nodes;
    const transformed_root = try transformer.transform();
    try std.testing.expect(!transformed_root.isNone());
    const edited = (try transformer.finishSemanticEdit()).?;

    var exact = try coverage.checkExact(
        allocator,
        transformer.ast,
        transformed_root,
        transformer.parser_node_count,
        transformer.symbol_ids.items,
        edited.symbols.items,
        edited.scopes,
        edited.scope_maps,
        &edited.scope_owner_map,
        edited.references,
        transformer.helper_ref_nodes.items,
        &edited.helper_scope_map,
        &analyzer.unresolved_reference_nodes,
        &transformer.explicit_global_reference_nodes,
        &transformer.reference_origin_map,
    );
    try std.testing.expect(exact.isClean());
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

test "#4819 static private accessor and method temps have exact semantic references" {
    const source =
        \\class Counter {
        \\  static #value = 1;
        \\  static get #entry() { return this.#value; }
        \\  static set #entry(value) { this.#value = value; }
        \\  static #method(value) { return value; }
        \\  static receiver() { return this; }
        \\  static run() { this.receiver().#entry ??= 2; return [this.receiver().#entry++, this.receiver().#method(4)]; }
        \\}
        \\Counter.run();
    ;
    for ([_]TransformOptions.compat.ESTarget{ .es5, .es2015 }) |target| {
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
            .unsupported = TransformOptions.compat.fromESTarget(target),
        });
        try transformer.initSymbolIds(analyzer.symbol_ids.items);
        transformer.symbols = analyzer.symbols.items;
        transformer.class_self_symbol_map = analyzer.class_self_symbol_map;
        transformer.references = analyzer.references.items;
        transformer.scopes = analyzer.scopes.items;
        transformer.scope_maps = analyzer.scope_maps.items;
        transformer.scope_owner_map = analyzer.scope_owner_map;
        transformer.semantic_edit_enabled = true;
        _ = try transformer.transform();
        const edited = (try transformer.finishSemanticEdit()).?;
        try std.testing.expectEqual(@as(usize, 0), transformer.pending_temp_ref_chains.count());

        const nodes = try @import("../parser/ast_walk.zig").collectReachableNodeIndices(allocator, transformer.ast);
        var temp_refs: usize = 0;
        var updates: usize = 0;
        for (nodes) |raw| {
            const node = transformer.ast.nodes.items[raw];
            if (node.tag != .identifier_reference) continue;
            const name = transformer.ast.getText(node.data.string_ref);
            if (name.len != 2 or name[0] != '_' or name[1] < 'a' or name[1] > 'z') continue;
            const symbol_id = edited.symbol_ids[raw] orelse return error.TestUnexpectedResult;
            const symbol = edited.symbols.items[symbol_id];
            try std.testing.expectEqual(node.data.string_ref.start, symbol.name.start);
            try std.testing.expectEqual(@import("../semantic/symbol.zig").SymbolKind.variable_var, symbol.kind);
            try std.testing.expectEqual(@import("../semantic/scope.zig").ScopeKind.function, edited.scopes[symbol.scope_id.toIndex()].kind);
            var found: usize = 0;
            for (edited.references) |ref| {
                if (@intFromEnum(ref.node_index) != raw) continue;
                try std.testing.expectEqual(symbol_id, @intFromEnum(ref.symbol_id));
                try std.testing.expectEqual(symbol.scope_id, ref.scope_id);
                if (ref.flags.read and ref.flags.write) updates += 1;
                found += 1;
            }
            try std.testing.expectEqual(@as(usize, 1), found);
            temp_refs += 1;
        }
        try std.testing.expectEqual(@as(usize, 16), temp_refs);
        try std.testing.expectEqual(@as(usize, 1), updates);
    }
}

test "#4819 static private for-in target temp binds in the method scope" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var scanner = try Scanner.init(allocator, "class Counter { static #method() {} static run() { for (this.#method in {x: 1}) {} } } Counter.run();");
    var parser = Parser.init(allocator, &scanner);
    parser.configureFromExtension(".mjs");
    _ = try parser.parse();
    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    analyzer.is_module = true;
    try analyzer.analyze();
    const original_symbol_count = analyzer.symbols.items.len;
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
    transformer.semantic_edit_enabled = true;
    _ = try transformer.transform();
    const edited = (try transformer.finishSemanticEdit()).?;
    const reachable_nodes = try @import("../parser/ast_walk.zig").collectReachableNodeIndices(allocator, transformer.ast);
    var reachable: std.AutoHashMapUnmanaged(u32, void) = .empty;
    for (reachable_nodes) |node| try reachable.put(allocator, node, {});

    var temp_count: usize = 0;
    for (edited.symbols.items[original_symbol_count..], original_symbol_count..) |symbol, id| {
        const name = transformer.ast.getText(symbol.name);
        if (name.len != 2 or name[0] != '_' or name[1] < 'a' or name[1] > 'z') continue;
        try std.testing.expectEqual(@import("../semantic/scope.zig").ScopeKind.function, edited.scopes[symbol.scope_id.toIndex()].kind);
        var exact_refs: usize = 0;
        for (edited.references) |ref| {
            if (@intFromEnum(ref.symbol_id) != id or ref.node_index.isNone()) continue;
            try std.testing.expect(reachable.contains(@intFromEnum(ref.node_index)));
            try std.testing.expect(ref.flags.read);
            try std.testing.expect(!ref.flags.write);
            try std.testing.expectEqual(@as(?u32, @intCast(id)), edited.symbol_ids[@intFromEnum(ref.node_index)]);
            exact_refs += 1;
        }
        try std.testing.expectEqual(@as(usize, 1), exact_refs);
        temp_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), temp_count);
}

test "strict inventory does not infer generated global identity from spelling" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var ast = @import("../parser/ast.zig").Ast.init(allocator, "");
    defer ast.deinit();
    const storage = try ast.addString("_x");
    const global = try ast.addString("Object");
    const property = try ast.addString("value");
    const binding = try ast.addNode(.{ .tag = .binding_identifier, .span = storage, .data = .{ .string_ref = storage } });
    const local_read = try ast.addNode(.{ .tag = .identifier_reference, .span = storage, .data = .{ .string_ref = storage } });
    const global_read = try ast.addNode(.{ .tag = .identifier_reference, .span = global, .data = .{ .string_ref = global } });
    const static_key = try ast.addNode(.{ .tag = .identifier_reference, .span = property, .data = .{ .string_ref = property } });
    const member_extra = try ast.addExtras(&.{ @intFromEnum(local_read), @intFromEnum(static_key), 0 });
    const member = try ast.addExtraNode(.static_member_expression, storage, member_extra);
    const list = try ast.addNodeList(&.{ binding, member, global_read });
    const root = try ast.addNode(.{ .tag = .program, .span = storage, .data = .{ .list = list } });
    var marked: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer marked.deinit(allocator);
    try marked.put(allocator, @intFromEnum(binding), {});
    var unresolved: std.StringHashMapUnmanaged(void) = .empty;
    defer unresolved.deinit(allocator);
    // A name-only unresolved-global table cannot distinguish this generated
    // local read from an unrelated global with the same spelling.
    try unresolved.put(allocator, "_x", {});
    var scope_owner_map: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer scope_owner_map.deinit(allocator);
    var report = try coverage.checkStrict(allocator, &ast, root, 0, &.{}, &.{}, &.{}, &scope_owner_map, &.{}, &marked, &unresolved);
    defer report.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), report.counts[@intFromEnum(coverage.StrictStatus.missing_binding)]);
    try std.testing.expectEqual(@as(usize, 2), report.counts[@intFromEnum(coverage.StrictStatus.unclassified)]);
    try std.testing.expect(!report.hasCompleteExactCoverage());
    try std.testing.expectEqual(@as(usize, 1), report.marked_synthetic);
    try std.testing.expectEqual(@intFromEnum(binding), report.findings.items[0].node);
}

test "strict exact coverage rejects counter and finding drift" {
    const allocator = std.testing.allocator;
    var hidden_error: coverage.StrictReport = .{};
    defer hidden_error.deinit(allocator);
    try hidden_error.findings.append(allocator, .{
        .node = 1,
        .name = "_missing",
        .tag = .binding_identifier,
        .status = .missing_binding,
        .marked_synthetic = true,
    });
    // A stale zeroed counter array must not hide an error retained in details.
    try std.testing.expect(!hidden_error.hasCompleteExactCoverage());

    var missing_detail: coverage.StrictReport = .{};
    defer missing_detail.deinit(allocator);
    missing_detail.counts[@intFromEnum(coverage.StrictStatus.bound)] = 1;
    // Conversely, a positive aggregate without a corresponding finding is
    // report drift and must not be accepted as exact coverage.
    try std.testing.expect(!missing_detail.hasCompleteExactCoverage());

    var hidden_orphan: coverage.StrictReport = .{};
    defer hidden_orphan.deinit(allocator);
    try hidden_orphan.orphan_symbol_findings.append(allocator, .{
        .symbol_id = 4,
        .name = "_orphan",
        .kind = .variable_var,
        .scope_id = @enumFromInt(0),
    });
    try std.testing.expect(!hidden_orphan.hasCompleteExactCoverage());

    var marked_count_drift: coverage.StrictReport = .{};
    defer marked_count_drift.deinit(allocator);
    marked_count_drift.marked_synthetic = 1;
    try std.testing.expect(!marked_count_drift.hasCompleteExactCoverage());
}

test "strict symbol identity fails closed except bound external and delegated scope traces" {
    const allocator = std.testing.allocator;
    inline for (std.meta.tags(coverage.StrictStatus)) |status| {
        var report: coverage.StrictReport = .{};
        defer report.deinit(allocator);
        report.counts[@intFromEnum(status)] = 1;
        try report.findings.append(allocator, .{
            .node = 1,
            .name = "x",
            .tag = .identifier_reference,
            .status = status,
            .marked_synthetic = false,
        });

        try std.testing.expect(report.isConsistent());
        const expected_complete = status == .bound or status == .external or status == .scope_mismatch;
        try std.testing.expectEqual(expected_complete, report.hasCompleteSymbolIdentity());
    }
}

test "strict exact external references require matching NodeIndex provenance" {
    const allocator = std.testing.allocator;
    var ast = Ast.init(allocator, "");
    defer ast.deinit();
    const object_name = try ast.addString("Object");
    const window_name = try ast.addString("Window");
    const missing_name = try ast.addString("MissingGlobal");
    const source_ref = try ast.addNode(.{ .tag = .identifier_reference, .span = object_name, .data = .{ .string_ref = object_name } });
    const copied_external = try ast.addNode(.{ .tag = .identifier_reference, .span = object_name, .data = .{ .string_ref = object_name } });
    const explicit_global = try ast.addNode(.{ .tag = .identifier_reference, .span = window_name, .data = .{ .string_ref = window_name } });
    const mismatched_origin = try ast.addNode(.{ .tag = .identifier_reference, .span = window_name, .data = .{ .string_ref = window_name } });
    const no_origin = try ast.addNode(.{ .tag = .identifier_reference, .span = missing_name, .data = .{ .string_ref = missing_name } });
    const parser_node_count = @intFromEnum(copied_external);
    const exact_root = try ast.addListNode(.program, object_name, try ast.addNodeList(&.{ copied_external, explicit_global }));
    const mixed_root = try ast.addListNode(.program, object_name, try ast.addNodeList(&.{ copied_external, explicit_global, mismatched_origin, no_origin }));

    const global_scope: ScopeId = @enumFromInt(0);
    const scopes = [_]Scope{.{ .parent = .none, .kind = .global, .is_strict = false }};
    var owners: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer owners.deinit(allocator);
    try owners.put(allocator, @intFromEnum(exact_root), @intFromEnum(global_scope));
    try owners.put(allocator, @intFromEnum(mixed_root), @intFromEnum(global_scope));
    var unresolved_nodes: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer unresolved_nodes.deinit(allocator);
    try unresolved_nodes.put(allocator, @intFromEnum(source_ref), {});
    var explicit_globals: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer explicit_globals.deinit(allocator);
    try explicit_globals.put(allocator, @intFromEnum(explicit_global), {});
    var origins: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer origins.deinit(allocator);
    try origins.put(allocator, @intFromEnum(copied_external), @intFromEnum(source_ref));
    try origins.put(allocator, @intFromEnum(mismatched_origin), @intFromEnum(source_ref));
    const evidence: coverage.StrictExternalEvidence = .{
        .unresolved_reference_nodes = &unresolved_nodes,
        .explicit_global_reference_nodes = &explicit_globals,
        .reference_origin_map = &origins,
    };

    var exact = try coverage.checkStrictWithExactExternalEvidence(
        allocator,
        &ast,
        exact_root,
        parser_node_count,
        &.{},
        &.{},
        &scopes,
        &owners,
        &.{},
        null,
        evidence,
    );
    defer exact.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), exact.counts[@intFromEnum(coverage.StrictStatus.external)]);
    try std.testing.expectEqual(@as(usize, 0), exact.counts[@intFromEnum(coverage.StrictStatus.unclassified)]);
    try std.testing.expect(exact.hasCompleteExactCoverage());

    var mixed = try coverage.checkStrictWithExactExternalEvidence(
        allocator,
        &ast,
        mixed_root,
        parser_node_count,
        &.{},
        &.{},
        &scopes,
        &owners,
        &.{},
        null,
        evidence,
    );
    defer mixed.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), mixed.counts[@intFromEnum(coverage.StrictStatus.external)]);
    try std.testing.expectEqual(@as(usize, 2), mixed.counts[@intFromEnum(coverage.StrictStatus.unclassified)]);
    try std.testing.expect(!mixed.hasCompleteExactCoverage());
}

test "strict inventory reports generated symbols with no reachable binding" {
    const allocator = std.testing.allocator;
    var ast = Ast.init(allocator, "");
    defer ast.deinit();
    const name = try ast.addString("_unused");
    const root = try ast.addNode(.{ .tag = .program, .span = name, .data = .{ .list = try ast.addNodeList(&.{}) } });
    const global_scope: ScopeId = @enumFromInt(0);
    const scopes = [_]Scope{.{ .parent = .none, .kind = .global, .is_strict = false }};
    const symbols = [_]Symbol{
        .{ .name = name, .scope_id = global_scope, .origin_scope = global_scope, .kind = .variable_var, .declaration_span = name, .synthetic_name = "_unused" },
    };
    var owners: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer owners.deinit(allocator);
    try owners.put(allocator, @intFromEnum(root), @intFromEnum(global_scope));
    var synthetic: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer synthetic.deinit(allocator);
    const unresolved: std.StringHashMapUnmanaged(void) = .empty;

    var orphan = try coverage.checkStrict(allocator, &ast, root, 0, &.{}, &symbols, &scopes, &owners, &.{}, &synthetic, &unresolved);
    defer orphan.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), orphan.orphan_symbols);
    try std.testing.expect(!orphan.hasCompleteExactCoverage());
    try std.testing.expectEqual(@as(usize, 1), orphan.orphan_symbol_findings.items.len);
    try std.testing.expectEqual(@as(u32, 0), orphan.orphan_symbol_findings.items[0].symbol_id);
    try std.testing.expectEqualStrings("_unused", orphan.orphan_symbol_findings.items[0].name);
    try std.testing.expectEqual(@import("../semantic/symbol.zig").SymbolKind.variable_var, orphan.orphan_symbol_findings.items[0].kind);
    try std.testing.expectEqual(global_scope, orphan.orphan_symbol_findings.items[0].scope_id);

    // Expression `export default` uses an intentional symbol-table facade
    // when there is no emitted local declaration to attach it to.
    var default_facade_symbols = symbols;
    default_facade_symbols[0].synthetic_name = "_default";
    default_facade_symbols[0].decl_flags.is_default_export = true;
    var default_facade = try coverage.checkStrict(allocator, &ast, root, 0, &.{}, &default_facade_symbols, &scopes, &owners, &.{}, &synthetic, &unresolved);
    defer default_facade.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), default_facade.orphan_symbols);
    try std.testing.expect(default_facade.hasCompleteExactCoverage());

    // Once the exact symbol is attached to a reachable binding, it is no longer orphaned.
    const binding = try ast.addNode(.{ .tag = .binding_identifier, .span = name, .data = .{ .string_ref = name } });
    const root_with_binding = try ast.addNode(.{ .tag = .program, .span = name, .data = .{ .list = try ast.addNodeList(&.{binding}) } });
    try owners.put(allocator, @intFromEnum(root_with_binding), @intFromEnum(global_scope));
    const symbol_ids = [_]?u32{ null, 0, null };
    var attached = try coverage.checkStrict(allocator, &ast, root_with_binding, 0, &symbol_ids, &symbols, &scopes, &owners, &.{}, &synthetic, &unresolved);
    defer attached.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), attached.orphan_symbols);
    try std.testing.expect(attached.hasCompleteExactCoverage());
}

test "strict inventory checks generated identity and exact lexical scope" {
    const allocator = std.testing.allocator;
    var ast = Ast.init(allocator, "");
    defer ast.deinit();
    const name = try ast.addString("x");
    const binding = try ast.addNode(.{ .tag = .binding_identifier, .span = name, .data = .{ .string_ref = name } });
    const read = try ast.addNode(.{ .tag = .identifier_reference, .span = name, .data = .{ .string_ref = name } });
    const block = try ast.addNode(.{ .tag = .block_statement, .span = name, .data = .{ .list = try ast.addNodeList(&.{ binding, read }) } });
    const root = try ast.addNode(.{ .tag = .program, .span = name, .data = .{ .list = try ast.addNodeList(&.{block}) } });

    const global_scope: ScopeId = @enumFromInt(0);
    const block_scope: ScopeId = @enumFromInt(1);
    const sibling_scope: ScopeId = @enumFromInt(2);
    const scopes = [_]Scope{
        .{ .parent = .none, .kind = .global, .is_strict = false },
        .{ .parent = global_scope, .kind = .block, .is_strict = false },
        .{ .parent = global_scope, .kind = .block, .is_strict = false },
    };
    var owners: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer owners.deinit(allocator);
    try owners.put(allocator, @intFromEnum(root), @intFromEnum(global_scope));
    try owners.put(allocator, @intFromEnum(block), @intFromEnum(block_scope));

    const symbols = [_]Symbol{
        .{ .name = name, .scope_id = block_scope, .origin_scope = block_scope, .kind = .variable_const, .declaration_span = name },
        .{ .name = name, .scope_id = sibling_scope, .origin_scope = sibling_scope, .kind = .variable_const, .declaration_span = name },
    };
    var symbol_ids = [_]?u32{ 0, 0, null, null };
    const references = [_]Reference{.{
        .node_index = read,
        .scope_id = block_scope,
        .symbol_id = @enumFromInt(0),
        .flags = .{ .read = true },
    }};
    var synthetic: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer synthetic.deinit(allocator);
    try synthetic.put(allocator, @intFromEnum(binding), {});
    try synthetic.put(allocator, @intFromEnum(read), {});
    const unresolved: std.StringHashMapUnmanaged(void) = .empty;

    var correct = try coverage.checkStrict(allocator, &ast, root, 0, &symbol_ids, &symbols, &scopes, &owners, &references, &synthetic, &unresolved);
    defer correct.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), correct.counts[@intFromEnum(coverage.StrictStatus.bound)]);
    try std.testing.expect(correct.hasCompleteExactCoverage());

    // A different in-range SymbolId with the same spelling must not pass as bound.
    symbol_ids[@intFromEnum(read)] = 1;
    var wrong_id = try coverage.checkStrict(allocator, &ast, root, 0, &symbol_ids, &symbols, &scopes, &owners, &references, &synthetic, &unresolved);
    defer wrong_id.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), wrong_id.counts[@intFromEnum(coverage.StrictStatus.identity_mismatch)]);
    symbol_ids[@intFromEnum(read)] = 0;

    // Matching ID records are still invalid when that same-name symbol lives
    // in an inaccessible sibling scope.
    symbol_ids[@intFromEnum(read)] = 1;
    var sibling_reference = references;
    sibling_reference[0].symbol_id = @enumFromInt(1);
    var invisible = try coverage.checkStrict(allocator, &ast, root, 0, &symbol_ids, &symbols, &scopes, &owners, &sibling_reference, &synthetic, &unresolved);
    defer invisible.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), invisible.counts[@intFromEnum(coverage.StrictStatus.invisible_reference)]);
    symbol_ids[@intFromEnum(read)] = 0;

    // A valid but lexically incorrect scope must fail even though the symbol ID is right.
    var wrong_scope_references = references;
    wrong_scope_references[0].scope_id = global_scope;
    var wrong_scope = try coverage.checkStrict(allocator, &ast, root, 0, &symbol_ids, &symbols, &scopes, &owners, &wrong_scope_references, &synthetic, &unresolved);
    defer wrong_scope.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), wrong_scope.counts[@intFromEnum(coverage.StrictStatus.scope_mismatch)]);

    // A SymbolId copied onto a read without the matching Reference record is incomplete.
    var missing_reference = try coverage.checkStrict(allocator, &ast, root, 0, &symbol_ids, &symbols, &scopes, &owners, &.{}, &synthetic, &unresolved);
    defer missing_reference.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), missing_reference.counts[@intFromEnum(coverage.StrictStatus.missing_reference)]);

    // A transformed binding may keep its source origin after moving into the
    // output AST's exact binding scope.
    var wrong_binding_symbols = symbols;
    wrong_binding_symbols[0].origin_scope = sibling_scope;
    var wrong_binding_scope = try coverage.checkStrict(allocator, &ast, root, 0, &symbol_ids, &wrong_binding_symbols, &scopes, &owners, &references, &synthetic, &unresolved);
    defer wrong_binding_scope.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), wrong_binding_scope.counts[@intFromEnum(coverage.StrictStatus.bound)]);
    try std.testing.expect(wrong_binding_scope.hasCompleteExactCoverage());

    // A valid but unrelated storage ScopeId must fail even if origin_scope is
    // correct. The old check validated scope_id's range but never compared it.
    var wrong_storage_symbols = symbols;
    wrong_storage_symbols[0].scope_id = sibling_scope;
    wrong_storage_symbols[0].origin_scope = block_scope;
    var wrong_storage_scope = try coverage.checkStrict(allocator, &ast, root, 0, &symbol_ids, &wrong_storage_symbols, &scopes, &owners, &references, &synthetic, &unresolved);
    defer wrong_storage_scope.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), wrong_storage_scope.counts[@intFromEnum(coverage.StrictStatus.scope_mismatch)]);
    const bad_binding = for (wrong_storage_scope.findings.items) |finding| {
        if (finding.node == @intFromEnum(binding)) break finding;
    } else return error.MissingExpectedFinding;
    try std.testing.expectEqual(@as(?u32, @intFromEnum(block_scope)), bad_binding.expected_scope_id);
    try std.testing.expectEqual(@as(?u32, @intFromEnum(sibling_scope)), bad_binding.symbol_scope_id);
    try std.testing.expectEqual(@as(?u32, @intFromEnum(block_scope)), bad_binding.symbol_origin_scope_id);

    // A valid ID with a different symbol spelling is not accepted as identity.
    const other_name = try ast.addString("y");
    var wrong_name_symbols = symbols;
    wrong_name_symbols[0].name = other_name;
    var wrong_name = try coverage.checkStrict(allocator, &ast, root, 0, &symbol_ids, &wrong_name_symbols, &scopes, &owners, &references, &synthetic, &unresolved);
    defer wrong_name.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), wrong_name.counts[@intFromEnum(coverage.StrictStatus.name_mismatch)]);

    // Out-of-range IDs and scopes must fail closed instead of passing as valid.
    symbol_ids[@intFromEnum(read)] = 9;
    var invalid_id = try coverage.checkStrict(allocator, &ast, root, 0, &symbol_ids, &symbols, &scopes, &owners, &references, &synthetic, &unresolved);
    defer invalid_id.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), invalid_id.counts[@intFromEnum(coverage.StrictStatus.invalid_id)]);
    symbol_ids[@intFromEnum(read)] = 0;

    var invalid_scope_references = references;
    invalid_scope_references[0].scope_id = @enumFromInt(99);
    var invalid_scope = try coverage.checkStrict(allocator, &ast, root, 0, &symbol_ids, &symbols, &scopes, &owners, &invalid_scope_references, &synthetic, &unresolved);
    defer invalid_scope.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), invalid_scope.counts[@intFromEnum(coverage.StrictStatus.invalid_scope)]);

    // One AST reference must have one semantic record; duplicated evidence is ambiguous.
    const duplicate_references = [_]Reference{ references[0], references[0] };
    var duplicate = try coverage.checkStrict(allocator, &ast, root, 0, &symbol_ids, &symbols, &scopes, &owners, &duplicate_references, &synthetic, &unresolved);
    defer duplicate.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), duplicate.counts[@intFromEnum(coverage.StrictStatus.duplicate_reference)]);

    // A shared AST node reached under two lexical scopes has no single safe scope.
    const sibling_block = try ast.addNode(.{
        .tag = .block_statement,
        .span = name,
        .data = .{ .list = try ast.addNodeList(&.{read}) },
    });
    const shared_root = try ast.addNode(.{
        .tag = .program,
        .span = name,
        .data = .{ .list = try ast.addNodeList(&.{ block, sibling_block }) },
    });
    try owners.put(allocator, @intFromEnum(shared_root), @intFromEnum(global_scope));
    try owners.put(allocator, @intFromEnum(sibling_block), @intFromEnum(sibling_scope));
    var ambiguous = try coverage.checkStrict(allocator, &ast, shared_root, 0, &symbol_ids, &symbols, &scopes, &owners, &references, &synthetic, &unresolved);
    defer ambiguous.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), ambiguous.counts[@intFromEnum(coverage.StrictStatus.scope_ambiguous)]);
}

test "strict inventory recognizes a lowered var declaration independently of source kind" {
    const allocator = std.testing.allocator;
    var ast = Ast.init(allocator, "");
    defer ast.deinit();
    const name = try ast.addString("_using");
    const binding = try ast.addNode(.{ .tag = .binding_identifier, .span = name, .data = .{ .string_ref = name } });
    const none = @intFromEnum(@import("../parser/ast.zig").NodeIndex.none);
    const declarator_extra = try ast.addExtras(&.{ @intFromEnum(binding), none, none });
    const declarator = try ast.addNode(.{ .tag = .variable_declarator, .span = name, .data = .{ .extra = declarator_extra } });
    const declarators = try ast.addNodeList(&.{declarator});
    const declaration_extra = try ast.addExtras(&.{
        @intFromEnum(@import("../parser/ast.zig").VariableDeclarationKind.@"var"),
        declarators.start,
        declarators.len,
    });
    const declaration = try ast.addNode(.{ .tag = .variable_declaration, .span = name, .data = .{ .extra = declaration_extra } });
    const block = try ast.addNode(.{ .tag = .block_statement, .span = name, .data = .{ .list = try ast.addNodeList(&.{declaration}) } });
    const root = try ast.addNode(.{ .tag = .program, .span = name, .data = .{ .list = try ast.addNodeList(&.{block}) } });

    const global_scope: ScopeId = @enumFromInt(0);
    const block_scope: ScopeId = @enumFromInt(1);
    const scopes = [_]Scope{
        .{ .parent = .none, .kind = .global, .is_strict = false },
        .{ .parent = global_scope, .kind = .block, .is_strict = false },
    };
    var owners: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer owners.deinit(allocator);
    try owners.put(allocator, @intFromEnum(root), @intFromEnum(global_scope));
    try owners.put(allocator, @intFromEnum(block), @intFromEnum(block_scope));
    const symbols = [_]Symbol{
        .{ .name = name, .scope_id = global_scope, .origin_scope = block_scope, .kind = .variable_const, .declaration_span = name, .synthetic_name = "_using" },
    };
    const symbol_ids = [_]?u32{ 0, null, null, null, null };
    var synthetic: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer synthetic.deinit(allocator);
    try synthetic.put(allocator, @intFromEnum(binding), {});
    const unresolved: std.StringHashMapUnmanaged(void) = .empty;

    var report = try coverage.checkStrict(allocator, &ast, root, 0, &symbol_ids, &symbols, &scopes, &owners, &.{}, &synthetic, &unresolved);
    defer report.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), report.counts[@intFromEnum(coverage.StrictStatus.bound)]);
    try std.testing.expect(report.hasCompleteExactCoverage());
}

test "strict inventory checks emitted storage scopes and accepts relocated source origins" {
    const allocator = std.testing.allocator;
    var ast = Ast.init(allocator, "");
    defer ast.deinit();
    const name = try ast.addString("x");
    const var_binding = try ast.addNode(.{ .tag = .binding_identifier, .span = name, .data = .{ .string_ref = name } });
    const lexical_binding = try ast.addNode(.{ .tag = .binding_identifier, .span = name, .data = .{ .string_ref = name } });
    const function_binding = try ast.addNode(.{ .tag = .binding_identifier, .span = name, .data = .{ .string_ref = name } });
    const block = try ast.addNode(.{ .tag = .block_statement, .span = name, .data = .{ .list = try ast.addNodeList(&.{ var_binding, lexical_binding, function_binding }) } });
    const root = try ast.addNode(.{ .tag = .program, .span = name, .data = .{ .list = try ast.addNodeList(&.{block}) } });

    const global_scope: ScopeId = @enumFromInt(0);
    const function_scope: ScopeId = @enumFromInt(1);
    const block_scope: ScopeId = @enumFromInt(2);
    const sibling_scope: ScopeId = @enumFromInt(3);
    const scopes = [_]Scope{
        .{ .parent = .none, .kind = .global, .is_strict = false },
        .{ .parent = global_scope, .kind = .function, .is_strict = false },
        .{ .parent = function_scope, .kind = .block, .is_strict = false },
        .{ .parent = function_scope, .kind = .block, .is_strict = false },
    };
    var owners: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer owners.deinit(allocator);
    try owners.put(allocator, @intFromEnum(root), @intFromEnum(global_scope));
    try owners.put(allocator, @intFromEnum(block), @intFromEnum(block_scope));

    const symbols = [_]Symbol{
        .{ .name = name, .scope_id = function_scope, .origin_scope = block_scope, .kind = .variable_var, .declaration_span = name },
        .{ .name = name, .scope_id = block_scope, .origin_scope = block_scope, .kind = .variable_const, .declaration_span = name },
        .{ .name = name, .scope_id = block_scope, .origin_scope = block_scope, .kind = .function_decl, .declaration_span = name },
    };
    const symbol_ids = [_]?u32{ 0, 1, 2, null, null };
    var synthetic: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer synthetic.deinit(allocator);
    try synthetic.put(allocator, @intFromEnum(var_binding), {});
    try synthetic.put(allocator, @intFromEnum(lexical_binding), {});
    try synthetic.put(allocator, @intFromEnum(function_binding), {});
    const unresolved: std.StringHashMapUnmanaged(void) = .empty;

    var report = try coverage.checkStrict(allocator, &ast, root, 0, &symbol_ids, &symbols, &scopes, &owners, &.{}, &synthetic, &unresolved);
    defer report.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 3), report.counts[@intFromEnum(coverage.StrictStatus.bound)]);
    try std.testing.expect(report.hasCompleteExactCoverage());

    var hoisted_origin = symbols;
    hoisted_origin[0].origin_scope = function_scope;
    var hoisted_origin_report = try coverage.checkStrict(allocator, &ast, root, 0, &symbol_ids, &hoisted_origin, &scopes, &owners, &.{}, &synthetic, &unresolved);
    defer hoisted_origin_report.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 3), hoisted_origin_report.counts[@intFromEnum(coverage.StrictStatus.bound)]);

    var wrong_var_storage = symbols;
    wrong_var_storage[0].scope_id = global_scope;
    var wrong_storage_report = try coverage.checkStrict(allocator, &ast, root, 0, &symbol_ids, &wrong_var_storage, &scopes, &owners, &.{}, &synthetic, &unresolved);
    defer wrong_storage_report.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), wrong_storage_report.counts[@intFromEnum(coverage.StrictStatus.scope_mismatch)]);
    try std.testing.expect(!wrong_storage_report.hasCompleteExactCoverage());

    var wrong_var_origin = symbols;
    wrong_var_origin[0].origin_scope = sibling_scope;
    var wrong_origin_report = try coverage.checkStrict(allocator, &ast, root, 0, &symbol_ids, &wrong_var_origin, &scopes, &owners, &.{}, &synthetic, &unresolved);
    defer wrong_origin_report.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 3), wrong_origin_report.counts[@intFromEnum(coverage.StrictStatus.bound)]);
    try std.testing.expect(wrong_origin_report.hasCompleteExactCoverage());

    var invalid_var_origin = symbols;
    invalid_var_origin[0].origin_scope = .none;
    var invalid_origin_report = try coverage.checkStrict(allocator, &ast, root, 0, &symbol_ids, &invalid_var_origin, &scopes, &owners, &.{}, &synthetic, &unresolved);
    defer invalid_origin_report.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), invalid_origin_report.counts[@intFromEnum(coverage.StrictStatus.invalid_scope)]);

    // A regular function declaration inside a block remains block-scoped in
    // this analyzer; the function_scoped flag alone is not enough to hoist it.
    var wrong_function_scope = symbols;
    wrong_function_scope[2].scope_id = global_scope;
    var wrong_function_report = try coverage.checkStrict(allocator, &ast, root, 0, &symbol_ids, &wrong_function_scope, &scopes, &owners, &.{}, &synthetic, &unresolved);
    defer wrong_function_report.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), wrong_function_report.counts[@intFromEnum(coverage.StrictStatus.scope_mismatch)]);
}

test "exact coverage detects AST cycles without treating shared children as cycles" {
    const allocator = std.testing.allocator;
    var ast = Ast.init(allocator, "");
    defer ast.deinit();
    const span = try ast.addString("x");
    const leaf = try ast.addNode(.{ .tag = .empty_statement, .span = span, .data = .{ .none = 0 } });
    const shared_parent_a = try ast.addNode(.{
        .tag = .block_statement,
        .span = span,
        .data = .{ .list = try ast.addNodeList(&.{leaf}) },
    });
    const shared_parent_b = try ast.addNode(.{
        .tag = .block_statement,
        .span = span,
        .data = .{ .list = try ast.addNodeList(&.{leaf}) },
    });
    const root = try ast.addNode(.{
        .tag = .program,
        .span = span,
        .data = .{ .list = try ast.addNodeList(&.{ shared_parent_a, shared_parent_b }) },
    });
    const global_scope: ScopeId = @enumFromInt(0);
    const scopes = [_]Scope{.{ .parent = .none, .kind = .global, .is_strict = false }};
    const scope_maps = [_]std.StringHashMapUnmanaged(usize){.empty};
    var owners: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer owners.deinit(allocator);
    try owners.put(allocator, @intFromEnum(root), @intFromEnum(global_scope));
    const helper_scope_map: std.StringHashMapUnmanaged(usize) = .empty;
    const unresolved: std.AutoHashMapUnmanaged(u32, void) = .empty;
    const explicit_globals: std.AutoHashMapUnmanaged(u32, void) = .empty;
    const origins: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    const unresolved_names: std.StringHashMapUnmanaged(void) = .empty;

    const shared_child_report = try coverage.checkExact(
        allocator,
        &ast,
        root,
        0,
        &.{},
        &.{},
        &scopes,
        &scope_maps,
        &owners,
        &.{},
        &.{},
        &helper_scope_map,
        &unresolved,
        &explicit_globals,
        &origins,
    );
    try std.testing.expectEqual(@as(usize, 0), shared_child_report.cyclic_ast_edges);
    try std.testing.expect(shared_child_report.isClean());
    var shared_child_strict_report = try coverage.checkStrict(
        allocator,
        &ast,
        root,
        0,
        &.{},
        &.{},
        &scopes,
        &owners,
        &.{},
        null,
        &unresolved_names,
    );
    defer shared_child_strict_report.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), shared_child_strict_report.cyclic_ast_edges);
    try std.testing.expect(shared_child_strict_report.hasCompleteExactCoverage());
    try std.testing.expect(shared_child_strict_report.hasCompleteSymbolIdentity());

    // An out-of-range child index used to be silently skipped by the exact
    // reachability walk, allowing identifiers below malformed structure to
    // disappear from the coverage audit.
    const invalid_child_index: u32 = @intCast(ast.nodes.items.len + 7);
    ast.nodes.items[@intFromEnum(root)].data.list = try ast.addNodeList(&.{@enumFromInt(invalid_child_index)});
    const invalid_edge_report = try coverage.checkExact(
        allocator,
        &ast,
        root,
        0,
        &.{},
        &.{},
        &scopes,
        &scope_maps,
        &owners,
        &.{},
        &.{},
        &helper_scope_map,
        &unresolved,
        &explicit_globals,
        &origins,
    );
    try std.testing.expectEqual(@as(usize, 1), invalid_edge_report.invalid_ast_edge);
    try std.testing.expectEqual(invalid_child_index, invalid_edge_report.first_invalid_ast_edge.?.child_node_index);
    try std.testing.expect(!invalid_edge_report.isClean());

    // Mutate a reachable child edge into a root self-cycle. The exact audit
    // must fail closed before its generic tree walker can loop forever.
    ast.nodes.items[@intFromEnum(root)].data.list = try ast.addNodeList(&.{root});
    const cyclic_report = try coverage.checkExact(
        allocator,
        &ast,
        root,
        0,
        &.{},
        &.{},
        &scopes,
        &scope_maps,
        &owners,
        &.{},
        &.{},
        &helper_scope_map,
        &unresolved,
        &explicit_globals,
        &origins,
    );
    try std.testing.expectEqual(@as(usize, 1), cyclic_report.cyclic_ast_edges);
    try std.testing.expect(!cyclic_report.isClean());

    ast.nodes.items[@intFromEnum(root)].data.list = try ast.addNodeList(&.{shared_parent_a});
    ast.nodes.items[@intFromEnum(shared_parent_a)].data.list = try ast.addNodeList(&.{shared_parent_b});
    ast.nodes.items[@intFromEnum(shared_parent_b)].data.list = try ast.addNodeList(&.{shared_parent_a});
    const back_edge_report = try coverage.checkExact(
        allocator,
        &ast,
        root,
        0,
        &.{},
        &.{},
        &scopes,
        &scope_maps,
        &owners,
        &.{},
        &.{},
        &helper_scope_map,
        &unresolved,
        &explicit_globals,
        &origins,
    );
    try std.testing.expectEqual(@as(usize, 1), back_edge_report.cyclic_ast_edges);
    try std.testing.expect(!back_edge_report.isClean());
    var back_edge_strict_report = try coverage.checkStrict(
        allocator,
        &ast,
        root,
        0,
        &.{},
        &.{},
        &scopes,
        &owners,
        &.{},
        null,
        &unresolved_names,
    );
    defer back_edge_strict_report.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), back_edge_strict_report.cyclic_ast_edges);
    try std.testing.expect(!back_edge_strict_report.isConsistent());
    try std.testing.expect(!back_edge_strict_report.hasCompleteExactCoverage());
    try std.testing.expect(!back_edge_strict_report.hasCompleteSymbolIdentity());
}
