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
const SymbolId = @import("../semantic/symbol.zig").SymbolId;
const Symbol = @import("../semantic/symbol.zig").Symbol;
const SymbolKind = @import("../semantic/symbol.zig").SymbolKind;
const SyntheticKind = @import("../semantic/symbol.zig").SyntheticKind;
const Span = @import("../lexer/token.zig").Span;
const Scope = @import("../semantic/scope.zig").Scope;
const ScopeId = @import("../semantic/scope.zig").ScopeId;
const transformer_mod = @import("transformer.zig");
const Transformer = transformer_mod.Transformer;
const TransformOptions = transformer_mod.TransformOptions;
const es_helpers = @import("es_helpers.zig");
const coverage = @import("symbol_coverage.zig");
const SemanticEditor = @import("../semantic/editor.zig").SemanticEditor;
const runtime_helper_imports = @import("runtime_helper_imports.zig");

fn keepOriginalClassForSyntheticTempTest(
    _: *Transformer,
    source_idx: AstNodeIndex,
    _: @import("../parser/ast.zig").Node,
) Transformer.Error!AstNodeIndex {
    return source_idx;
}

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

fn checkExactFixture(
    allocator: std.mem.Allocator,
    ast: *const Ast,
    root: AstNodeIndex,
    symbol_ids: []const ?u32,
    symbols: []const Symbol,
    scopes: []const Scope,
    scope_maps: []const std.StringHashMapUnmanaged(usize),
    scope_owners: *const std.AutoHashMapUnmanaged(u32, u32),
    references: []const Reference,
) !coverage.ExactReport {
    const helpers: std.StringHashMapUnmanaged(usize) = .empty;
    const unresolved: std.AutoHashMapUnmanaged(u32, void) = .empty;
    const explicit_globals: std.AutoHashMapUnmanaged(u32, void) = .empty;
    const origins: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    return coverage.checkExact(
        allocator,
        ast,
        root,
        @intCast(ast.nodes.items.len),
        symbol_ids,
        symbols,
        scopes,
        scope_maps,
        scope_owners,
        references,
        &.{},
        &helpers,
        &unresolved,
        &explicit_globals,
        &origins,
    );
}

test "exact scope audit permits only the verified CommonJS callback boundary" {
    const allocator = std.testing.allocator;
    var ast = Ast.init(allocator, "");
    defer ast.deinit();
    const span = try ast.addString("cjs");
    const root = try ast.addListNode(.program, span, try ast.addNodeList(&.{}));

    const program_scope: ScopeId = @fromBackingInt(@intCast(0));
    const wrapper_scope: ScopeId = @fromBackingInt(@intCast(1));
    var scopes = [_]Scope{
        .{ .parent = wrapper_scope, .kind = .global, .is_strict = false },
        .{ .parent = .none, .kind = .function, .is_strict = false, .symbol_count = 2 },
    };
    var root_names: std.StringHashMapUnmanaged(usize) = .empty;
    defer root_names.deinit(allocator);
    var wrapper_names: std.StringHashMapUnmanaged(usize) = .empty;
    defer wrapper_names.deinit(allocator);
    try root_names.put(allocator, "exports", 0);
    try root_names.put(allocator, "module", 1);
    try wrapper_names.put(allocator, "exports", 0);
    try wrapper_names.put(allocator, "module", 1);
    const scope_maps = [_]std.StringHashMapUnmanaged(usize){ root_names, wrapper_names };
    const symbols = [_]Symbol{
        .{
            .name = span,
            .scope_id = wrapper_scope,
            .kind = .parameter,
            .decl_flags = .{ .is_parameter = true },
            .declaration_span = span,
            .synthetic_kind = .cjs_wrapper_exports_parameter,
            .synthetic_name = "exports",
        },
        .{
            .name = span,
            .scope_id = wrapper_scope,
            .kind = .parameter,
            .decl_flags = .{ .is_parameter = true },
            .declaration_span = span,
            .synthetic_kind = .cjs_wrapper_module_parameter,
            .synthetic_name = "module",
        },
    };
    var owners: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer owners.deinit(allocator);
    try owners.put(allocator, @backingInt(root), @backingInt(program_scope));

    const valid = try checkExactFixture(allocator, &ast, root, &.{}, &symbols, &scopes, &scope_maps, &owners, &.{});
    try std.testing.expect(valid.isClean());

    // A name-compatible map is not enough: each callback parameter must keep
    // its dedicated synthetic kind and exact SymbolId.
    var wrong_parameter = symbols;
    wrong_parameter[0].synthetic_kind = .cjs_wrapper_module_parameter;
    const wrong_parameter_report = try checkExactFixture(allocator, &ast, root, &.{}, &wrong_parameter, &scopes, &scope_maps, &owners, &.{});
    try std.testing.expect(!wrong_parameter_report.isClean());

    // The historical Program aliases can point only to their corresponding
    // callback parameter, never to a same-shaped sibling identity.
    try root_names.put(allocator, "exports", 1);
    const wrong_alias_maps = [_]std.StringHashMapUnmanaged(usize){ root_names, wrapper_names };
    const wrong_alias = try checkExactFixture(allocator, &ast, root, &.{}, &symbols, &scopes, &wrong_alias_maps, &owners, &.{});
    try std.testing.expect(wrong_alias.scope_map_mismatch > 0);
    try std.testing.expect(!wrong_alias.isClean());
    try root_names.put(allocator, "exports", 0);

    // The one accepted parentless function scope cannot be widened to a
    // general exemption for unrelated parentless scopes.
    const extra_scopes = [_]Scope{
        scopes[0],
        scopes[1],
        .{ .parent = .none, .kind = .function, .is_strict = false },
    };
    const extra_scope_maps = [_]std.StringHashMapUnmanaged(usize){ root_names, wrapper_names, .empty };
    const extra_parentless = try checkExactFixture(allocator, &ast, root, &.{}, &symbols, &extra_scopes, &extra_scope_maps, &owners, &.{});
    try std.testing.expect(extra_parentless.invalid_scope > 0);
    try std.testing.expect(!extra_parentless.isClean());

    // A callback scope with any extra binding no longer matches the linker
    // contract, even if the two required names remain present.
    try wrapper_names.put(allocator, "intruder", 0);
    const extra_binding_maps = [_]std.StringHashMapUnmanaged(usize){ root_names, wrapper_names };
    const extra_binding = try checkExactFixture(allocator, &ast, root, &.{}, &symbols, &scopes, &extra_binding_maps, &owners, &.{});
    try std.testing.expect(!extra_binding.isClean());
}

test "exact scope audit allows only detached graph-output symbol identities" {
    const allocator = std.testing.allocator;
    var ast = Ast.init(allocator, "");
    defer ast.deinit();
    const span = try ast.addString("output");
    const root = try ast.addListNode(.program, span, try ast.addNodeList(&.{}));
    const scopes = [_]Scope{.{ .parent = .none, .kind = .global, .is_strict = false }};
    const scope_maps = [_]std.StringHashMapUnmanaged(usize){.empty};
    var owners: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer owners.deinit(allocator);
    try owners.put(allocator, @backingInt(root), 0);

    const detached_cases = [_]struct {
        kind: SymbolKind,
        synthetic_kind: SyntheticKind,
        name: []const u8,
    }{
        .{ .kind = .variable_var, .synthetic_kind = .cjs_runtime_factory, .name = "__commonJS" },
        .{ .kind = .parameter, .synthetic_kind = .cjs_runtime_internal_local, .name = "cb" },
        .{ .kind = .parameter, .synthetic_kind = .esm_runtime_internal_local, .name = "fn" },
        .{ .kind = .parameter, .synthetic_kind = .esm_runtime_internal_local, .name = "res" },
        .{ .kind = .catch_binding, .synthetic_kind = .esm_runtime_internal_local, .name = "e" },
        .{ .kind = .function_decl, .synthetic_kind = .esm_runtime_internal_local, .name = "__init" },
        .{ .kind = .variable_var, .synthetic_kind = .esm_runtime_internal_local, .name = "f" },
        .{ .kind = .parameter, .synthetic_kind = .esm_interop_runtime_internal_local, .name = "copy_props.to" },
        .{ .kind = .parameter, .synthetic_kind = .esm_interop_runtime_internal_local, .name = "copy_props.from" },
        .{ .kind = .parameter, .synthetic_kind = .esm_interop_runtime_internal_local, .name = "copy_props.desc" },
        .{ .kind = .variable_var, .synthetic_kind = .esm_interop_runtime_internal_local, .name = "copy_props.keys" },
        .{ .kind = .variable_var, .synthetic_kind = .esm_interop_runtime_internal_local, .name = "copy_props.index" },
        .{ .kind = .variable_var, .synthetic_kind = .esm_interop_runtime_internal_local, .name = "copy_props.key" },
        .{ .kind = .parameter, .synthetic_kind = .esm_interop_runtime_internal_local, .name = "copy_props.closure_key" },
        .{ .kind = .parameter, .synthetic_kind = .esm_interop_runtime_internal_local, .name = "to_esm.module" },
        .{ .kind = .parameter, .synthetic_kind = .esm_interop_runtime_internal_local, .name = "to_esm.node_mode" },
        .{ .kind = .parameter, .synthetic_kind = .esm_interop_runtime_internal_local, .name = "to_esm.target" },
        .{ .kind = .parameter, .synthetic_kind = .esm_interop_runtime_internal_local, .name = "export.target" },
        .{ .kind = .parameter, .synthetic_kind = .esm_interop_runtime_internal_local, .name = "export.all" },
        .{ .kind = .variable_var, .synthetic_kind = .esm_interop_runtime_internal_local, .name = "export.name" },
        .{ .kind = .parameter, .synthetic_kind = .esm_interop_runtime_internal_local, .name = "to_common_js.module" },
        .{ .kind = .import_binding, .synthetic_kind = .require_shim_local, .name = "createRequire" },
        .{ .kind = .function_decl, .synthetic_kind = .esm_init, .name = "init_module" },
        .{ .kind = .variable_var, .synthetic_kind = .cjs_exports, .name = "exports_module" },
        .{ .kind = .function_decl, .synthetic_kind = .cjs_require, .name = "require_module" },
        .{ .kind = .variable_var, .synthetic_kind = .bundler_runtime_helper, .name = "__esm" },
    };
    for (detached_cases) |case| {
        const symbol = Symbol{
            .name = span,
            .scope_id = .none,
            .kind = case.kind,
            .decl_flags = case.kind.declFlags(),
            .declaration_span = span,
            .synthetic_kind = case.synthetic_kind,
            .synthetic_name = case.name,
        };
        const valid = try checkExactFixture(allocator, &ast, root, &.{}, &.{symbol}, &scopes, &scope_maps, &owners, &.{});
        try std.testing.expect(valid.isClean());
    }

    const wrong_esm_internal_name = Symbol{
        .name = span,
        .scope_id = .none,
        .kind = SymbolKind.parameter,
        .decl_flags = SymbolKind.parameter.declFlags(),
        .declaration_span = span,
        .synthetic_kind = .esm_runtime_internal_local,
        .synthetic_name = "unregistered",
    };
    const invalid_esm_internal = try checkExactFixture(allocator, &ast, root, &.{}, &.{wrong_esm_internal_name}, &scopes, &scope_maps, &owners, &.{});
    try std.testing.expect(!invalid_esm_internal.isClean());

    const wrong_esm_interop_internal_kind = Symbol{
        .name = span,
        .scope_id = .none,
        .kind = .variable_var,
        .decl_flags = SymbolKind.variable_var.declFlags(),
        .declaration_span = span,
        .synthetic_kind = .esm_interop_runtime_internal_local,
        .synthetic_name = "copy_props.to",
    };
    const invalid_esm_interop_kind = try checkExactFixture(allocator, &ast, root, &.{}, &.{wrong_esm_interop_internal_kind}, &scopes, &scope_maps, &owners, &.{});
    try std.testing.expect(!invalid_esm_interop_kind.isClean());

    const unknown_esm_interop_internal = Symbol{
        .name = span,
        .scope_id = .none,
        .kind = SymbolKind.parameter,
        .decl_flags = SymbolKind.parameter.declFlags(),
        .declaration_span = span,
        .synthetic_kind = .esm_interop_runtime_internal_local,
        .synthetic_name = "unregistered.interop.local",
    };
    const invalid_esm_interop_name = try checkExactFixture(allocator, &ast, root, &.{}, &.{unknown_esm_interop_internal}, &scopes, &scope_maps, &owners, &.{});
    try std.testing.expect(!invalid_esm_interop_name.isClean());

    const invalid_require_shim_rows = [_]Symbol{
        .{
            .name = span,
            .scope_id = .none,
            .kind = .import_binding,
            .decl_flags = SymbolKind.import_binding.declFlags(),
            .declaration_span = span,
            .synthetic_kind = .require_shim_local,
            .synthetic_name = "createRequire$1",
        },
        .{
            .name = span,
            .scope_id = .none,
            .kind = .variable_var,
            .decl_flags = SymbolKind.variable_var.declFlags(),
            .declaration_span = span,
            .synthetic_kind = .require_shim_local,
            .synthetic_name = "createRequire",
        },
    };
    for (invalid_require_shim_rows) |invalid_row| {
        const report = try checkExactFixture(allocator, &ast, root, &.{}, &.{invalid_row}, &scopes, &scope_maps, &owners, &.{});
        try std.testing.expect(!report.isClean());
    }

    const require_shim_output_reference = [_]Reference{.{
        .node_index = .none,
        .scope_id = @fromBackingInt(@intCast(0)),
        .symbol_id = @fromBackingInt(@intCast(0)),
        .flags = .{ .declare = true },
    }};
    const require_shim_output_symbol = Symbol{
        .name = span,
        .scope_id = .none,
        .kind = .import_binding,
        .decl_flags = SymbolKind.import_binding.declFlags(),
        .declaration_span = span,
        .synthetic_kind = .require_shim_local,
        .synthetic_name = "createRequire",
    };
    const require_shim_output_with_edge = try checkExactFixture(
        allocator,
        &ast,
        root,
        &.{},
        &.{require_shim_output_symbol},
        &scopes,
        &scope_maps,
        &owners,
        &require_shim_output_reference,
    );
    try std.testing.expect(require_shim_output_with_edge.invalid_scope > 0);
    try std.testing.expect(!require_shim_output_with_edge.isClean());

    const interop_output_reference = [_]Reference{.{
        .node_index = .none,
        .scope_id = @fromBackingInt(@intCast(0)),
        .symbol_id = @fromBackingInt(@intCast(0)),
        .flags = .{ .declare = true },
    }};
    const interop_output_symbol = Symbol{
        .name = span,
        .scope_id = .none,
        .kind = SymbolKind.parameter,
        .decl_flags = SymbolKind.parameter.declFlags(),
        .declaration_span = span,
        .synthetic_kind = .esm_interop_runtime_internal_local,
        .synthetic_name = "copy_props.to",
    };
    const interop_output_with_edge = try checkExactFixture(allocator, &ast, root, &.{}, &.{interop_output_symbol}, &scopes, &scope_maps, &owners, &interop_output_reference);
    try std.testing.expect(interop_output_with_edge.invalid_scope > 0);
    try std.testing.expect(!interop_output_with_edge.isClean());

    const unclassified = Symbol{
        .name = span,
        .scope_id = .none,
        .kind = .function_decl,
        .decl_flags = SymbolKind.function_decl.declFlags(),
        .declaration_span = span,
        .synthetic_kind = .runtime_helper_preamble,
        .synthetic_name = "helper",
    };
    const unclassified_report = try checkExactFixture(allocator, &ast, root, &.{}, &.{unclassified}, &scopes, &scope_maps, &owners, &.{});
    try std.testing.expectEqual(@as(usize, 1), unclassified_report.invalid_scope);
    try std.testing.expect(!unclassified_report.isClean());

    // A detached identity must remain absent from AST SymbolIds, reference
    // rows, and lexical maps. Any one of those edges invalidates the exception.
    const output_symbol = Symbol{
        .name = span,
        .scope_id = .none,
        .kind = .variable_var,
        .decl_flags = SymbolKind.variable_var.declFlags(),
        .declaration_span = span,
        .synthetic_kind = .cjs_runtime_factory,
        .synthetic_name = "__commonJS",
    };
    const root_mapped_ids = [_]?u32{0};
    const mapped_output = try checkExactFixture(allocator, &ast, root, &root_mapped_ids, &.{output_symbol}, &scopes, &scope_maps, &owners, &.{});
    try std.testing.expectEqual(@as(usize, 1), mapped_output.invalid_scope);
    try std.testing.expect(!mapped_output.isClean());

    const output_reference = [_]Reference{.{
        .node_index = .none,
        .scope_id = @fromBackingInt(@intCast(0)),
        .symbol_id = @fromBackingInt(@intCast(0)),
        .flags = .{ .declare = true },
    }};
    const referenced_output = try checkExactFixture(allocator, &ast, root, &.{}, &.{output_symbol}, &scopes, &scope_maps, &owners, &output_reference);
    try std.testing.expectEqual(@as(usize, 1), referenced_output.invalid_scope);
    try std.testing.expect(!referenced_output.isClean());

    var output_map: std.StringHashMapUnmanaged(usize) = .empty;
    defer output_map.deinit(allocator);
    try output_map.put(allocator, "__commonJS", 0);
    const output_map_scope_maps = [_]std.StringHashMapUnmanaged(usize){output_map};
    const mapped_scope_output = try checkExactFixture(allocator, &ast, root, &.{}, &.{output_symbol}, &scopes, &output_map_scope_maps, &owners, &.{});
    try std.testing.expectEqual(@as(usize, 1), mapped_scope_output.invalid_scope);
    try std.testing.expect(mapped_scope_output.scope_map_mismatch > 0);
    try std.testing.expect(!mapped_scope_output.isClean());
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
    const bad_child = try edge_ast.addNodeList(&.{@fromBackingInt(@intCast(invalid_child_index))});
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
    const extra_base = try extra_ast.addExtras(&.{ @backingInt(NodeIndex.none), 99, 1 });
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
    missing_slot_ast.extra_data.items[root_children.start] = @backingInt(call_without_extra);
    const invalid_extra_slot = try checkEmptyExactGraph(allocator, &missing_slot_ast, missing_slot_root);
    try std.testing.expectEqual(@as(usize, 1), invalid_extra_slot.invalid_ast_layout);
    try std.testing.expectEqual(coverage.AstLayoutIssue.extra_child_slot, invalid_extra_slot.first_invalid_ast_layout.?.issue);
    try std.testing.expect(!invalid_extra_slot.isClean());
}

test "exact scope audit rejects distinct live owners sharing one ScopeId" {
    const allocator = std.testing.allocator;
    var ast = Ast.init(allocator, "");
    defer ast.deinit();

    const span = try ast.addString("{}");
    const first_block = try ast.addListNode(.block_statement, span, try ast.addNodeList(&.{}));
    const second_block = try ast.addListNode(.block_statement, span, try ast.addNodeList(&.{}));
    const root = try ast.addListNode(.program, span, try ast.addNodeList(&.{ first_block, second_block }));

    const global_scope: ScopeId = @fromBackingInt(@intCast(0));
    const first_scope: ScopeId = @fromBackingInt(@intCast(1));
    const second_scope: ScopeId = @fromBackingInt(@intCast(2));
    const scopes = [_]Scope{
        .{ .parent = .none, .kind = .global, .is_strict = false },
        .{ .parent = global_scope, .kind = .block, .is_strict = false },
        .{ .parent = global_scope, .kind = .block, .is_strict = false },
    };
    const scope_maps = [_]std.StringHashMapUnmanaged(usize){ .empty, .empty, .empty };
    var scope_owner_map: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer scope_owner_map.deinit(allocator);
    try scope_owner_map.put(allocator, @backingInt(root), @backingInt(global_scope));
    try scope_owner_map.put(allocator, @backingInt(first_block), @backingInt(first_scope));
    try scope_owner_map.put(allocator, @backingInt(second_block), @backingInt(second_scope));
    const helpers: std.StringHashMapUnmanaged(usize) = .empty;
    const unresolved: std.AutoHashMapUnmanaged(u32, void) = .empty;
    const explicit_globals: std.AutoHashMapUnmanaged(u32, void) = .empty;
    const origins: std.AutoHashMapUnmanaged(u32, u32) = .empty;

    const valid = try coverage.checkExact(
        allocator,
        &ast,
        root,
        @intCast(ast.nodes.items.len),
        &.{},
        &.{},
        &scopes,
        &scope_maps,
        &scope_owner_map,
        &.{},
        &.{},
        &helpers,
        &unresolved,
        &explicit_globals,
        &origins,
    );
    try std.testing.expect(valid.isClean());

    // Stale owner entries are expected after lowering. A duplicate scope is
    // rejected only when both owners are reachable from the emitted root.
    const stale_block = try ast.addListNode(.block_statement, span, try ast.addNodeList(&.{}));
    try scope_owner_map.put(allocator, @backingInt(stale_block), @backingInt(first_scope));
    const stale_owner = try coverage.checkExact(
        allocator,
        &ast,
        root,
        @intCast(ast.nodes.items.len),
        &.{},
        &.{},
        &scopes,
        &scope_maps,
        &scope_owner_map,
        &.{},
        &.{},
        &helpers,
        &unresolved,
        &explicit_globals,
        &origins,
    );
    try std.testing.expect(stale_owner.isClean());

    // Reusing the first block's valid ScopeId leaves all IDs, parents, owner
    // kinds, and empty scope maps individually valid. The exact gate must still
    // reject two distinct reachable lexical boundaries with one identity.
    try scope_owner_map.put(allocator, @backingInt(second_block), @backingInt(first_scope));
    const shared_owner = try coverage.checkExact(
        allocator,
        &ast,
        root,
        @intCast(ast.nodes.items.len),
        &.{},
        &.{},
        &scopes,
        &scope_maps,
        &scope_owner_map,
        &.{},
        &.{},
        &helpers,
        &unresolved,
        &explicit_globals,
        &origins,
    );
    try std.testing.expectEqual(@as(usize, 1), shared_owner.duplicate_scope_owner);
    try std.testing.expectEqualStrings("duplicate-reachable-scope-owner", shared_owner.first_duplicate_scope_owner.?.issue);
    try std.testing.expect(shared_owner.first_duplicate_scope_owner.?.first_owner_node_index.? != shared_owner.first_duplicate_scope_owner.?.node_index);
    try std.testing.expect(!shared_owner.isClean());
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

    const global_scope: ScopeId = @fromBackingInt(@intCast(0));
    const binding_scope: ScopeId = @fromBackingInt(@intCast(1));
    const descendant_scope: ScopeId = @fromBackingInt(@intCast(2));
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
            .symbol_id = @fromBackingInt(@intCast(0)),
            .flags = .{ .declare = true },
        },
    };
    var owners: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer owners.deinit(allocator);
    try owners.put(allocator, @backingInt(root), @backingInt(global_scope));
    try owners.put(allocator, @backingInt(block), @backingInt(binding_scope));
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

test "exact scope audit does not treat a synthetic name as relocation evidence" {
    const allocator = std.testing.allocator;
    var ast = Ast.init(allocator, "");
    defer ast.deinit();

    const name = try ast.addString("_generated");
    const binding = try ast.addNode(.{
        .tag = .binding_identifier,
        .span = name,
        .data = .{ .string_ref = name },
    });
    const block = try ast.addListNode(.block_statement, name, try ast.addNodeList(&.{}));
    const root = try ast.addListNode(.program, name, try ast.addNodeList(&.{ binding, block }));

    const global_scope: ScopeId = @fromBackingInt(@intCast(0));
    const block_scope: ScopeId = @fromBackingInt(@intCast(1));
    const scopes = [_]Scope{
        .{ .parent = .none, .kind = .global, .is_strict = false },
        .{ .parent = global_scope, .kind = .block, .is_strict = false },
    };
    var scope_maps = [_]std.StringHashMapUnmanaged(usize){ .empty, .empty };
    defer {
        for (&scope_maps) |*scope_map| scope_map.deinit(allocator);
    }
    try scope_maps[0].put(allocator, ast.getText(name), 0);
    var owners: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer owners.deinit(allocator);
    try owners.put(allocator, @backingInt(root), @backingInt(global_scope));
    try owners.put(allocator, @backingInt(block), @backingInt(block_scope));
    const symbols = [_]Symbol{.{
        .name = name,
        .scope_id = global_scope,
        .origin_scope = global_scope,
        .kind = .variable_let,
        .declaration_span = name,
        .synthetic_name = ast.getText(name),
    }};
    const symbol_ids = [_]?u32{ 0, null, null };
    const declarations = [_]Reference{.{
        .node_index = .none,
        .scope_id = global_scope,
        .symbol_id = @fromBackingInt(@intCast(0)),
        .flags = .{ .declare = true },
    }};
    const helpers: std.StringHashMapUnmanaged(usize) = .empty;
    const unresolved: std.AutoHashMapUnmanaged(u32, void) = .empty;
    const explicit_globals: std.AutoHashMapUnmanaged(u32, void) = .empty;
    const origins: std.AutoHashMapUnmanaged(u32, u32) = .empty;

    const correct = try coverage.checkExact(
        allocator,
        &ast,
        root,
        0,
        &symbol_ids,
        &symbols,
        &scopes,
        &scope_maps,
        &owners,
        &declarations,
        &.{},
        &helpers,
        &unresolved,
        &explicit_globals,
        &origins,
    );
    try std.testing.expect(correct.isClean());

    // The marker only says this symbol was generated. Moving a lexical
    // binding into a reachable sibling scope must still fail exact ownership.
    var moved_symbols = symbols;
    moved_symbols[0].scope_id = block_scope;
    _ = scope_maps[0].remove(ast.getText(name));
    try scope_maps[1].put(allocator, ast.getText(name), 0);
    const corrupted = try coverage.checkExact(
        allocator,
        &ast,
        root,
        0,
        &symbol_ids,
        &moved_symbols,
        &scopes,
        &scope_maps,
        &owners,
        &declarations,
        &.{},
        &helpers,
        &unresolved,
        &explicit_globals,
        &origins,
    );
    try std.testing.expectEqual(@as(usize, 1), corrupted.binding_scope_mismatch);
    try std.testing.expect(!corrupted.isClean());

    // `var` kind has an AST-derived nearest-var scope of its own; the kind
    // alone must not permit storage in a nearer block scope.
    var moved_var_symbols = symbols;
    moved_var_symbols[0].kind = .variable_var;
    moved_var_symbols[0].synthetic_name = "";
    moved_var_symbols[0].scope_id = block_scope;
    const corrupted_var = try coverage.checkExact(
        allocator,
        &ast,
        root,
        0,
        &symbol_ids,
        &moved_var_symbols,
        &scopes,
        &scope_maps,
        &owners,
        &declarations,
        &.{},
        &helpers,
        &unresolved,
        &explicit_globals,
        &origins,
    );
    try std.testing.expectEqual(@as(usize, 1), corrupted_var.binding_scope_mismatch);
    try std.testing.expect(!corrupted_var.isClean());
}

test "exact identity audit rejects declaration rows swapped within one statement" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var scanner = try Scanner.init(allocator, "let alpha = 1, beta = 2;");
    var parser = Parser.init(allocator, &scanner);
    const root = try parser.parse();
    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    analyzer.enable_stmt_info = true;
    try analyzer.analyze();

    var binding_ids: [2]u32 = undefined;
    var found_bindings: usize = 0;
    for (parser.ast.nodes.items, 0..) |node, raw| {
        if (node.tag != .binding_identifier) continue;
        const name = parser.ast.getText(node.data.string_ref);
        const index = if (std.mem.eql(u8, name, "alpha")) @as(usize, 0) else if (std.mem.eql(u8, name, "beta")) @as(usize, 1) else continue;
        binding_ids[index] = analyzer.symbol_ids.items[raw] orelse return error.TestUnexpectedResult;
        found_bindings += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), found_bindings);

    var declaration_rows: [2]?usize = .{ null, null };
    for (analyzer.references.items, 0..) |reference, index| {
        if (!reference.flags.declare) continue;
        const id = @backingInt(reference.symbol_id);
        if (id == binding_ids[0]) declaration_rows[0] = index;
        if (id == binding_ids[1]) declaration_rows[1] = index;
    }
    try std.testing.expect(declaration_rows[0] != null);
    try std.testing.expect(declaration_rows[1] != null);

    const origins: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    const correct = try coverage.checkExact(
        allocator,
        &parser.ast,
        root,
        @intCast(parser.ast.nodes.items.len),
        analyzer.symbol_ids.items,
        analyzer.symbols.items,
        analyzer.scopes.items,
        analyzer.scope_maps.items,
        &analyzer.scope_owner_map,
        analyzer.references.items,
        analyzer.helper_ref_nodes,
        &analyzer.helper_scope_map,
        &analyzer.unresolved_reference_nodes,
        &.{},
        &origins,
    );
    try std.testing.expect(correct.isClean());

    // Both declaration rows share the same ScopeId and statement index. Only
    // their SymbolIds are swapped; name, scope, counts, and AST bindings stay
    // valid. Exact declaration evidence must still reject this corruption.
    const swapped_references = try allocator.dupe(Reference, analyzer.references.items);
    std.mem.swap(
        SymbolId,
        &swapped_references[declaration_rows[0].?].symbol_id,
        &swapped_references[declaration_rows[1].?].symbol_id,
    );
    const report = try coverage.checkExact(
        allocator,
        &parser.ast,
        root,
        @intCast(parser.ast.nodes.items.len),
        analyzer.symbol_ids.items,
        analyzer.symbols.items,
        analyzer.scopes.items,
        analyzer.scope_maps.items,
        &analyzer.scope_owner_map,
        swapped_references,
        analyzer.helper_ref_nodes,
        &analyzer.helper_scope_map,
        &analyzer.unresolved_reference_nodes,
        &.{},
        &origins,
    );
    try std.testing.expectEqual(@as(usize, 2), report.declaration_identity_mismatch);
    try std.testing.expect(!report.isClean());

    const missing_anchor_references = try allocator.dupe(Reference, analyzer.references.items);
    missing_anchor_references[declaration_rows[0].?].declaration_node_index = .none;
    const missing_anchor = try coverage.checkExact(
        allocator,
        &parser.ast,
        root,
        @intCast(parser.ast.nodes.items.len),
        analyzer.symbol_ids.items,
        analyzer.symbols.items,
        analyzer.scopes.items,
        analyzer.scope_maps.items,
        &analyzer.scope_owner_map,
        missing_anchor_references,
        analyzer.helper_ref_nodes,
        &analyzer.helper_scope_map,
        &analyzer.unresolved_reference_nodes,
        &.{},
        &origins,
    );
    try std.testing.expectEqual(@as(usize, 1), missing_anchor.declaration_identity_mismatch);
    try std.testing.expect(!missing_anchor.isClean());
}

test "exact declaration coverage rejects missing and duplicate declaration anchors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var scanner = try Scanner.init(allocator, "let alpha = 1; alpha;");
    var parser = Parser.init(allocator, &scanner);
    const root = try parser.parse();
    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    analyzer.enable_exact_declaration_anchors = true;
    try analyzer.analyze();
    try std.testing.expectEqual(@as(u32, 0), analyzer.stmt_info_count);
    for (analyzer.references.items) |reference| {
        if (!reference.flags.declare) continue;
        try std.testing.expectEqual(Reference.NO_STMT, reference.stmt_idx);
        try std.testing.expectEqual(Reference.NO_STMT, reference.scope_stmt_idx);
    }

    var alpha_binding: ?u32 = null;
    for (parser.ast.nodes.items, 0..) |node, raw| {
        if (node.tag == .binding_identifier and std.mem.eql(u8, parser.ast.getText(node.data.string_ref), "alpha")) {
            alpha_binding = @intCast(raw);
            break;
        }
    }
    const binding = alpha_binding orelse return error.TestUnexpectedResult;
    var omitted_row: ?usize = null;
    for (analyzer.references.items, 0..) |reference, index| {
        if (reference.flags.declare and @backingInt(reference.declaration_node_index) == binding) {
            omitted_row = index;
            break;
        }
    }
    const omitted = omitted_row orelse return error.TestUnexpectedResult;
    const references = try allocator.alloc(Reference, analyzer.references.items.len - 1);
    @memcpy(references[0..omitted], analyzer.references.items[0..omitted]);
    @memcpy(references[omitted..], analyzer.references.items[omitted + 1 ..]);
    const origins: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    const correct = try coverage.checkExactWithDeclarationAnchors(
        allocator,
        &parser.ast,
        root,
        @intCast(parser.ast.nodes.items.len),
        analyzer.symbol_ids.items,
        analyzer.symbols.items,
        analyzer.scopes.items,
        analyzer.scope_maps.items,
        &analyzer.scope_owner_map,
        analyzer.references.items,
        analyzer.helper_ref_nodes,
        &analyzer.helper_scope_map,
        &analyzer.unresolved_reference_nodes,
        &.{},
        &origins,
    );
    try std.testing.expectEqual(@as(usize, 1), correct.declaration_anchors_checked);
    try std.testing.expectEqual(@as(usize, 0), correct.declaration_anchor_mismatch);
    try std.testing.expect(correct.isClean());

    const missing = try coverage.checkExactWithDeclarationAnchors(
        allocator,
        &parser.ast,
        root,
        @intCast(parser.ast.nodes.items.len),
        analyzer.symbol_ids.items,
        analyzer.symbols.items,
        analyzer.scopes.items,
        analyzer.scope_maps.items,
        &analyzer.scope_owner_map,
        references,
        analyzer.helper_ref_nodes,
        &analyzer.helper_scope_map,
        &analyzer.unresolved_reference_nodes,
        &.{},
        &origins,
    );
    try std.testing.expectEqual(@as(usize, 1), missing.declaration_anchors_checked);
    try std.testing.expectEqual(@as(usize, 1), missing.declaration_anchor_mismatch);
    try std.testing.expect(!missing.isClean());

    const duplicate = try allocator.alloc(Reference, analyzer.references.items.len + 1);
    @memcpy(duplicate[0..analyzer.references.items.len], analyzer.references.items);
    duplicate[analyzer.references.items.len] = analyzer.references.items[omitted];
    const duplicated = try coverage.checkExactWithDeclarationAnchors(
        allocator,
        &parser.ast,
        root,
        @intCast(parser.ast.nodes.items.len),
        analyzer.symbol_ids.items,
        analyzer.symbols.items,
        analyzer.scopes.items,
        analyzer.scope_maps.items,
        &analyzer.scope_owner_map,
        duplicate,
        analyzer.helper_ref_nodes,
        &analyzer.helper_scope_map,
        &analyzer.unresolved_reference_nodes,
        &.{},
        &origins,
    );
    try std.testing.expectEqual(@as(usize, 1), duplicated.declaration_anchor_mismatch);
    try std.testing.expect(!duplicated.isClean());
}

test "exact identity audit rejects stale symbol read and write counts independently" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var scanner = try Scanner.init(allocator, "let value = 0; value = 1; value += 2; value;");
    var parser = Parser.init(allocator, &scanner);
    const root = try parser.parse();
    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    analyzer.enable_exact_declaration_anchors = true;
    try analyzer.analyze();

    var value_symbol_id: ?u32 = null;
    for (parser.ast.nodes.items, 0..) |node, raw| {
        if (node.tag != .binding_identifier or
            !std.mem.eql(u8, parser.ast.getText(node.data.string_ref), "value")) continue;
        value_symbol_id = analyzer.symbol_ids.items[raw] orelse return error.TestUnexpectedResult;
        break;
    }
    const value_id = value_symbol_id orelse return error.TestUnexpectedResult;
    try std.testing.expect(value_id < analyzer.symbols.items.len);

    const origins: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    const baseline = try coverage.checkExactWithDeclarationAnchors(
        allocator,
        &parser.ast,
        root,
        @intCast(parser.ast.nodes.items.len),
        analyzer.symbol_ids.items,
        analyzer.symbols.items,
        analyzer.scopes.items,
        analyzer.scope_maps.items,
        &analyzer.scope_owner_map,
        analyzer.references.items,
        analyzer.helper_ref_nodes,
        &analyzer.helper_scope_map,
        &analyzer.unresolved_reference_nodes,
        &.{},
        &origins,
    );
    try std.testing.expect(baseline.isClean());

    const stale_read_symbols = try allocator.dupe(Symbol, analyzer.symbols.items);
    stale_read_symbols[value_id].reference_count += 1;
    const stale_read_count = try coverage.checkExactWithDeclarationAnchors(
        allocator,
        &parser.ast,
        root,
        @intCast(parser.ast.nodes.items.len),
        analyzer.symbol_ids.items,
        stale_read_symbols,
        analyzer.scopes.items,
        analyzer.scope_maps.items,
        &analyzer.scope_owner_map,
        analyzer.references.items,
        analyzer.helper_ref_nodes,
        &analyzer.helper_scope_map,
        &analyzer.unresolved_reference_nodes,
        &.{},
        &origins,
    );
    try std.testing.expectEqual(@as(usize, 1), stale_read_count.reference_count_mismatch);
    try std.testing.expectEqual(@as(usize, 0), stale_read_count.write_count_mismatch);
    try std.testing.expect(!stale_read_count.isClean());

    const stale_write_symbols = try allocator.dupe(Symbol, analyzer.symbols.items);
    stale_write_symbols[value_id].write_count += 1;
    const stale_write_count = try coverage.checkExactWithDeclarationAnchors(
        allocator,
        &parser.ast,
        root,
        @intCast(parser.ast.nodes.items.len),
        analyzer.symbol_ids.items,
        stale_write_symbols,
        analyzer.scopes.items,
        analyzer.scope_maps.items,
        &analyzer.scope_owner_map,
        analyzer.references.items,
        analyzer.helper_ref_nodes,
        &analyzer.helper_scope_map,
        &analyzer.unresolved_reference_nodes,
        &.{},
        &origins,
    );
    try std.testing.expectEqual(@as(usize, 0), stale_write_count.reference_count_mismatch);
    try std.testing.expectEqual(@as(usize, 1), stale_write_count.write_count_mismatch);
    try std.testing.expect(!stale_write_count.isClean());
}

test "exact source scope audit separates parameter expressions from body var bindings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source = "let outside = 3; function f({ a, ...rest }, value = outside) { var outside = 4; return [value, rest.x]; }";
    var scanner = try Scanner.init(allocator, source);
    var parser = Parser.init(allocator, &scanner);
    const root = try parser.parse();
    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    analyzer.enable_exact_declaration_anchors = true;
    try analyzer.analyze();

    var function_node: ?AstNodeIndex = null;
    var outer_symbol: ?u32 = null;
    var body_var_symbol: ?u32 = null;
    for (parser.ast.nodes.items, 0..) |node, raw| {
        if (node.tag == .function_declaration) function_node = @fromBackingInt(@intCast(@as(u32, @intCast(raw))));
    }
    for (analyzer.symbols.items, 0..) |symbol, raw| {
        if (!std.mem.eql(u8, symbol.nameText(parser.ast.source), "outside")) continue;
        if (symbol.scope_id.toIndex() == 0 and symbol.kind == .variable_let) outer_symbol = @intCast(raw);
    }
    const function_idx = function_node orelse return error.TestUnexpectedResult;
    const function_raw = @backingInt(function_idx);
    const function_node_value = parser.ast.getNode(function_idx);
    const params_idx: AstNodeIndex = @fromBackingInt(@intCast(parser.ast.extra_data.items[function_node_value.data.extra + 1]));
    const parameter_scope_raw = analyzer.scope_owner_map.get(@backingInt(params_idx)) orelse return error.TestUnexpectedResult;
    const body_scope_raw = analyzer.scope_owner_map.get(function_raw) orelse return error.TestUnexpectedResult;
    try std.testing.expect(parameter_scope_raw < analyzer.scopes.items.len);
    try std.testing.expect(body_scope_raw < analyzer.scopes.items.len);
    try std.testing.expectEqual(@as(u32, 0), @backingInt(analyzer.scopes.items[parameter_scope_raw].parent));
    try std.testing.expectEqual(@as(u32, @intCast(parameter_scope_raw)), @backingInt(analyzer.scopes.items[body_scope_raw].parent));

    const expected_outer_symbol = outer_symbol orelse return error.TestUnexpectedResult;
    var parameter_default_reference: ?Reference = null;
    for (analyzer.references.items) |reference| {
        if (reference.flags.declare or !reference.flags.read or reference.node_index.isNone()) continue;
        const raw = @backingInt(reference.node_index);
        if (raw >= parser.ast.nodes.items.len) continue;
        const node = parser.ast.getNode(reference.node_index);
        if (node.tag != .identifier_reference or !std.mem.eql(u8, parser.ast.getText(node.data.string_ref), "outside")) continue;
        if (@backingInt(reference.symbol_id) == expected_outer_symbol and @backingInt(reference.scope_id) == parameter_scope_raw)
            parameter_default_reference = reference;
    }
    const default_reference = parameter_default_reference orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(expected_outer_symbol, @backingInt(default_reference.symbol_id));
    try std.testing.expectEqual(parameter_scope_raw, @backingInt(default_reference.scope_id));

    for (parser.ast.nodes.items, 0..) |node, raw| {
        if (node.tag != .binding_identifier or raw >= analyzer.symbol_ids.items.len) continue;
        if (!std.mem.eql(u8, parser.ast.getText(node.data.string_ref), "outside")) continue;
        const id = analyzer.symbol_ids.items[raw] orelse continue;
        if (id < analyzer.symbols.items.len and analyzer.symbols.items[id].scope_id.toIndex() == body_scope_raw)
            body_var_symbol = id;
    }
    try std.testing.expect(body_var_symbol != null);
    try std.testing.expect(body_var_symbol.? != expected_outer_symbol);

    const origins: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    const report = try coverage.checkExactWithDeclarationAnchors(
        allocator,
        &parser.ast,
        root,
        @intCast(parser.ast.nodes.items.len),
        analyzer.symbol_ids.items,
        analyzer.symbols.items,
        analyzer.scopes.items,
        analyzer.scope_maps.items,
        &analyzer.scope_owner_map,
        analyzer.references.items,
        analyzer.helper_ref_nodes,
        &analyzer.helper_scope_map,
        &analyzer.unresolved_reference_nodes,
        &.{},
        &origins,
    );
    try std.testing.expectEqual(@as(usize, 0), report.scope_resolution_mismatch);
    try std.testing.expect(report.isClean());
}

test "exact scope audit follows copied non-simple parameter lists and rejects relocated bindings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source = "function* f({ a, ...rest }, value = 3) { var a; yield [a, value, rest.x]; }";
    var scanner = try Scanner.init(allocator, source);
    var parser = Parser.init(allocator, &scanner);
    const root = try parser.parse();
    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    analyzer.enable_exact_declaration_anchors = true;
    try analyzer.analyze();

    var function_raw: ?u32 = null;
    var parameter_a: ?u32 = null;
    var body_a: ?u32 = null;
    for (parser.ast.nodes.items, 0..) |node, raw| {
        if (node.tag == .function_declaration) function_raw = @intCast(raw);
        if (node.tag != .binding_identifier or raw >= analyzer.symbol_ids.items.len) continue;
        if (!std.mem.eql(u8, parser.ast.getText(node.data.string_ref), "a")) continue;
        const symbol_id = analyzer.symbol_ids.items[raw] orelse continue;
        if (symbol_id >= analyzer.symbols.items.len) continue;
        const symbol = analyzer.symbols.items[symbol_id];
        if (symbol.kind == .parameter) parameter_a = symbol_id;
        if (symbol.kind == .variable_var) body_a = symbol_id;
    }
    const function = function_raw orelse return error.TestUnexpectedResult;
    const parameter_symbol = parameter_a orelse return error.TestUnexpectedResult;
    const body_symbol = body_a orelse return error.TestUnexpectedResult;
    const function_node = parser.ast.nodes.items[function];
    const params_raw = parser.ast.extra_data.items[function_node.data.extra + 1];
    const params_node: AstNodeIndex = @fromBackingInt(@intCast(params_raw));
    const parameter_scope = analyzer.scope_owner_map.get(params_raw) orelse return error.TestUnexpectedResult;
    const body_scope = analyzer.scope_owner_map.get(function) orelse return error.TestUnexpectedResult;
    try std.testing.expect(parameter_scope != body_scope);
    try std.testing.expectEqual(parameter_scope, @backingInt(analyzer.symbols.items[parameter_symbol].scope_id));
    try std.testing.expectEqual(body_scope, @backingInt(analyzer.symbols.items[body_symbol].scope_id));

    // Model the transform's copied formal_parameters container: the output
    // list has a new owner node but retains the exact original parameter nodes.
    const original_params = parser.ast.getNode(params_node);
    const copied_params = try parser.ast.addNode(.{
        .tag = .formal_parameters,
        .span = original_params.span,
        .data = .{ .list = original_params.data.list },
    });
    parser.ast.extra_data.items[function_node.data.extra + 1] = @backingInt(copied_params);
    try analyzer.scope_owner_map.put(allocator, @backingInt(copied_params), parameter_scope);

    const origins: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    const correct = try coverage.checkExactWithDeclarationAnchors(
        allocator,
        &parser.ast,
        root,
        @intCast(parser.ast.nodes.items.len),
        analyzer.symbol_ids.items,
        analyzer.symbols.items,
        analyzer.scopes.items,
        analyzer.scope_maps.items,
        &analyzer.scope_owner_map,
        analyzer.references.items,
        analyzer.helper_ref_nodes,
        &analyzer.helper_scope_map,
        &analyzer.unresolved_reference_nodes,
        &.{},
        &origins,
    );
    try std.testing.expect(correct.isClean());

    // If the exact parameter SymbolId is relocated into the body scope, the
    // stale same-name body var must not make the copied-list exception pass.
    const corrupted_symbols = try allocator.dupe(Symbol, analyzer.symbols.items);
    corrupted_symbols[parameter_symbol].scope_id = @fromBackingInt(@intCast(body_scope));
    const corrupted = try coverage.checkExactWithDeclarationAnchors(
        allocator,
        &parser.ast,
        root,
        @intCast(parser.ast.nodes.items.len),
        analyzer.symbol_ids.items,
        corrupted_symbols,
        analyzer.scopes.items,
        analyzer.scope_maps.items,
        &analyzer.scope_owner_map,
        analyzer.references.items,
        analyzer.helper_ref_nodes,
        &analyzer.helper_scope_map,
        &analyzer.unresolved_reference_nodes,
        &.{},
        &origins,
    );
    try std.testing.expect(corrupted.binding_scope_mismatch > 0);
    try std.testing.expect(!corrupted.isClean());
}

test "parameter default import reference keeps its exact parameter-environment scope" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source = "import { DEFAULT_VALUE } from 'values'; const read = (value = DEFAULT_VALUE) => value; const legacy = function(other = DEFAULT_VALUE) { return other; };";
    var scanner = try Scanner.init(allocator, source);
    var parser = Parser.init(allocator, &scanner);
    parser.configureFromExtension(".mjs");
    const root = try parser.parse();
    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    analyzer.is_module = parser.is_module;
    analyzer.is_strict_mode = parser.is_strict_mode;
    analyzer.enable_exact_declaration_anchors = true;
    try analyzer.analyze();

    var arrow_raw: ?u32 = null;
    var function_raw: ?u32 = null;
    var import_symbol: ?u32 = null;
    for (parser.ast.nodes.items, 0..) |node, raw| {
        if (node.tag == .arrow_function_expression) arrow_raw = @intCast(raw);
        if (node.tag == .function_expression) function_raw = @intCast(raw);
    }
    for (analyzer.symbols.items, 0..) |symbol, raw| {
        if (symbol.kind == .import_binding and std.mem.eql(u8, symbol.nameText(parser.ast.source), "DEFAULT_VALUE"))
            import_symbol = @intCast(raw);
    }
    const arrow = arrow_raw orelse return error.TestUnexpectedResult;
    const params = parser.ast.readExtraNode(parser.ast.getNode(@fromBackingInt(@intCast(arrow))).data.extra, 0);
    const parameter_scope = analyzer.scope_owner_map.get(@backingInt(params)) orelse return error.TestUnexpectedResult;
    const function = function_raw orelse return error.TestUnexpectedResult;
    const function_params = parser.ast.readExtraNode(parser.ast.getNode(@fromBackingInt(@intCast(function))).data.extra, 1);
    const function_parameter_scope = analyzer.scope_owner_map.get(@backingInt(function_params)) orelse return error.TestUnexpectedResult;
    const expected_import = import_symbol orelse return error.TestUnexpectedResult;
    var found_references: usize = 0;
    for (analyzer.references.items) |reference| {
        if (reference.flags.declare or reference.node_index.isNone()) continue;
        const node = parser.ast.getNode(reference.node_index);
        if (node.tag != .identifier_reference or !std.mem.eql(u8, parser.ast.getText(node.data.string_ref), "DEFAULT_VALUE")) continue;
        try std.testing.expectEqual(expected_import, @backingInt(reference.symbol_id));
        const actual_scope = @backingInt(reference.scope_id);
        try std.testing.expect(actual_scope == parameter_scope or actual_scope == function_parameter_scope);
        found_references += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), found_references);

    const origins: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    const report = try coverage.checkExactWithDeclarationAnchors(
        allocator,
        &parser.ast,
        root,
        @intCast(parser.ast.nodes.items.len),
        analyzer.symbol_ids.items,
        analyzer.symbols.items,
        analyzer.scopes.items,
        analyzer.scope_maps.items,
        &analyzer.scope_owner_map,
        analyzer.references.items,
        analyzer.helper_ref_nodes,
        &analyzer.helper_scope_map,
        &analyzer.unresolved_reference_nodes,
        &.{},
        &origins,
    );
    try std.testing.expectEqual(@as(usize, 0), report.scope_resolution_mismatch);
    try std.testing.expect(report.isClean());
}

test "exact identity audit catches same-name binding IDs swapped across scopes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var scanner = try Scanner.init(allocator, "{ let x = 1; { let x = 2; } }");
    var parser = Parser.init(allocator, &scanner);
    const root = try parser.parse();
    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    try analyzer.analyze();

    var binding_nodes: [2]usize = undefined;
    var binding_ids: [2]u32 = undefined;
    var found: usize = 0;
    for (parser.ast.nodes.items, 0..) |node, raw| {
        if (node.tag != .binding_identifier or
            !std.mem.eql(u8, parser.ast.getText(node.data.string_ref), "x")) continue;
        if (found == binding_nodes.len) return error.TestUnexpectedResult;
        binding_nodes[found] = raw;
        binding_ids[found] = analyzer.symbol_ids.items[raw] orelse return error.TestUnexpectedResult;
        found += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), found);
    try std.testing.expect(
        analyzer.symbols.items[binding_ids[0]].scope_id != analyzer.symbols.items[binding_ids[1]].scope_id,
    );

    // Same spelling keeps name-only checks satisfied. Swapping only the exact
    // binding IDs must still be detected as two binding-to-scope violations.
    const swapped_ids = try allocator.dupe(?u32, analyzer.symbol_ids.items);
    swapped_ids[binding_nodes[0]] = binding_ids[1];
    swapped_ids[binding_nodes[1]] = binding_ids[0];
    const origins: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    const report = try coverage.checkExact(
        allocator,
        &parser.ast,
        root,
        @intCast(parser.ast.nodes.items.len),
        swapped_ids,
        analyzer.symbols.items,
        analyzer.scopes.items,
        analyzer.scope_maps.items,
        &analyzer.scope_owner_map,
        analyzer.references.items,
        analyzer.helper_ref_nodes,
        &analyzer.helper_scope_map,
        &analyzer.unresolved_reference_nodes,
        &.{},
        &origins,
    );
    try std.testing.expectEqual(@as(usize, 2), report.binding_scope_mismatch);
    try std.testing.expect(!report.isClean());
}

test "exact identity audit rejects a `$N` source name routed to its unsuffixed sibling" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var scanner = try Scanner.init(allocator, "let x = 1; let x$1 = 2; let y = x$1;");
    var parser = Parser.init(allocator, &scanner);
    const root = try parser.parse();
    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    try analyzer.analyze();

    var unsuffixed_symbol: ?u32 = null;
    var suffixed_symbol: ?u32 = null;
    var suffixed_reference_node: ?u32 = null;
    for (parser.ast.nodes.items, 0..) |node, raw| {
        const name = switch (node.tag) {
            .binding_identifier, .identifier_reference => parser.ast.getText(node.data.string_ref),
            else => continue,
        };
        if (node.tag == .binding_identifier and std.mem.eql(u8, name, "x")) {
            unsuffixed_symbol = analyzer.symbol_ids.items[raw] orelse return error.TestUnexpectedResult;
        } else if (node.tag == .binding_identifier and std.mem.eql(u8, name, "x$1")) {
            suffixed_symbol = analyzer.symbol_ids.items[raw] orelse return error.TestUnexpectedResult;
        } else if (node.tag == .identifier_reference and std.mem.eql(u8, name, "x$1")) {
            suffixed_reference_node = @intCast(raw);
        }
    }
    const unsuffixed_id = unsuffixed_symbol orelse return error.TestUnexpectedResult;
    const suffixed_id = suffixed_symbol orelse return error.TestUnexpectedResult;
    const reference_raw = suffixed_reference_node orelse return error.TestUnexpectedResult;
    try std.testing.expect(unsuffixed_id != suffixed_id);

    const origins: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    const correct = try coverage.checkExact(
        allocator,
        &parser.ast,
        root,
        @intCast(parser.ast.nodes.items.len),
        analyzer.symbol_ids.items,
        analyzer.symbols.items,
        analyzer.scopes.items,
        analyzer.scope_maps.items,
        &analyzer.scope_owner_map,
        analyzer.references.items,
        analyzer.helper_ref_nodes,
        &analyzer.helper_scope_map,
        &analyzer.unresolved_reference_nodes,
        &.{},
        &origins,
    );
    try std.testing.expect(correct.isClean());

    const wrong_ids = try allocator.dupe(?u32, analyzer.symbol_ids.items);
    wrong_ids[reference_raw] = unsuffixed_id;
    const wrong_references = try allocator.dupe(Reference, analyzer.references.items);
    var corrupted_reference_rows: usize = 0;
    for (wrong_references) |*reference| {
        if (@backingInt(reference.node_index) != reference_raw) continue;
        reference.symbol_id = @fromBackingInt(@intCast(unsuffixed_id));
        corrupted_reference_rows += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), corrupted_reference_rows);

    const corrupted = try coverage.checkExact(
        allocator,
        &parser.ast,
        root,
        @intCast(parser.ast.nodes.items.len),
        wrong_ids,
        analyzer.symbols.items,
        analyzer.scopes.items,
        analyzer.scope_maps.items,
        &analyzer.scope_owner_map,
        wrong_references,
        analyzer.helper_ref_nodes,
        &analyzer.helper_scope_map,
        &analyzer.unresolved_reference_nodes,
        &.{},
        &origins,
    );
    try std.testing.expectEqual(@as(usize, 1), corrupted.scope_resolution_mismatch);
    try std.testing.expect(!corrupted.isClean());
}

test "exact scope audit rejects owner scopes detached from their AST parent scopes" {
    const allocator = std.testing.allocator;
    var ast = Ast.init(allocator, "");
    defer ast.deinit();
    const span = try ast.addString("scope");
    const block = try ast.addListNode(.block_statement, span, try ast.addNodeList(&.{}));
    const root = try ast.addListNode(.program, span, try ast.addNodeList(&.{block}));

    const global_scope: ScopeId = @fromBackingInt(@intCast(0));
    const block_scope: ScopeId = @fromBackingInt(@intCast(1));
    const detached_scope: ScopeId = @fromBackingInt(@intCast(2));
    var scopes = [_]Scope{
        .{ .parent = .none, .kind = .global, .is_strict = false },
        .{ .parent = global_scope, .kind = .block, .is_strict = false },
        .{ .parent = global_scope, .kind = .block, .is_strict = false },
    };
    const scope_maps = [_]std.StringHashMapUnmanaged(usize){ .empty, .empty, .empty };
    var owners: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer owners.deinit(allocator);
    try owners.put(allocator, @backingInt(root), @backingInt(global_scope));
    try owners.put(allocator, @backingInt(block), @backingInt(block_scope));
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
    scopes[@backingInt(block_scope)].parent = detached_scope;
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
    try std.testing.expectEqual(@as(?u32, @backingInt(global_scope)), corrupted.first_scope_owner_mismatch.?.expected_parent_scope_id);
    try std.testing.expectEqual(@as(?u32, @backingInt(detached_scope)), corrupted.first_scope_owner_mismatch.?.actual_parent_scope_id);
    try std.testing.expect(!corrupted.isClean());
}

test "source scope-owner audit finds a wrong owner kind with a valid parent" {
    const allocator = std.testing.allocator;
    var ast = Ast.init(allocator, "");
    defer ast.deinit();

    const span = try ast.addString("class");
    const body = try ast.addListNode(.class_body, span, try ast.addNodeList(&.{}));
    const none = @backingInt(AstNodeIndex.none);
    const class_extra = try ast.addExtras(&.{ none, none, @backingInt(body), none, 0, 0, 0, 0 });
    const class_expr = try ast.addNode(.{
        .tag = .class_expression,
        .span = span,
        .data = .{ .extra = class_extra },
    });
    const root = try ast.addListNode(.program, span, try ast.addNodeList(&.{class_expr}));

    const global_scope: ScopeId = @fromBackingInt(@intCast(0));
    const wrong_kind_scope: ScopeId = @fromBackingInt(@intCast(1));
    const scopes = [_]Scope{
        .{ .parent = .none, .kind = .global, .is_strict = false },
        .{ .parent = global_scope, .kind = .block, .is_strict = false },
    };
    const scope_maps = [_]std.StringHashMapUnmanaged(usize){ .empty, .empty };
    var owners: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer owners.deinit(allocator);
    try owners.put(allocator, @backingInt(root), @backingInt(global_scope));
    try owners.put(allocator, @backingInt(class_expr), @backingInt(wrong_kind_scope));
    const helpers: std.StringHashMapUnmanaged(usize) = .empty;
    const unresolved: std.AutoHashMapUnmanaged(u32, void) = .empty;
    const explicit_globals: std.AutoHashMapUnmanaged(u32, void) = .empty;
    const origins: std.AutoHashMapUnmanaged(u32, u32) = .empty;

    const report = try coverage.checkExact(
        allocator,
        &ast,
        root,
        @intCast(ast.nodes.items.len),
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
    try std.testing.expect(report.scope_owner_mismatch > 0);
    try std.testing.expectEqual(@as(usize, 0), report.scope_owner_parent_mismatch);
    try std.testing.expectEqualStrings("owner-kind", report.first_scope_owner_mismatch.?.issue);
    try std.testing.expect(!report.isClean());
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
    const class_none = @backingInt(AstNodeIndex.none);
    const source_class_extra = try ast.addExtras(&.{
        class_none,
        class_none,
        @backingInt(source_class_body),
        class_none,
        0,
        0,
        0,
        0,
    });
    const source_class = try ast.addNode(.{ .tag = .class_expression, .span = name, .data = .{ .extra = source_class_extra } });

    const global_scope: ScopeId = @fromBackingInt(@intCast(0));
    const emitted_parent_scope: ScopeId = @fromBackingInt(@intCast(1));
    const retained_source_class_scope: ScopeId = @fromBackingInt(@intCast(2));
    const detached_source_scope: ScopeId = @fromBackingInt(@intCast(3));
    const sibling_generated_scope: ScopeId = @fromBackingInt(@intCast(4));
    const generated_scope: ScopeId = @fromBackingInt(@intCast(5));
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
        .symbol_id = @fromBackingInt(@intCast(0)),
        .flags = .{ .declare = true },
    }};
    var scope_owner_map: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer scope_owner_map.deinit(allocator);
    try scope_owner_map.put(allocator, @backingInt(root), @backingInt(global_scope));
    try scope_owner_map.put(allocator, @backingInt(parent_block), @backingInt(emitted_parent_scope));
    try scope_owner_map.put(allocator, @backingInt(sibling_generated_block), @backingInt(sibling_generated_scope));
    try scope_owner_map.put(allocator, @backingInt(generated_block), @backingInt(generated_scope));
    try scope_owner_map.put(allocator, @backingInt(detached_source_block), @backingInt(detached_source_scope));
    try scope_owner_map.put(allocator, @backingInt(source_class), @backingInt(retained_source_class_scope));
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
    corrupted_scopes[@backingInt(retained_source_class_scope)].parent = detached_source_scope;
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
    corrupted_scopes[@backingInt(generated_scope)].parent = sibling_generated_scope;
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
    const declaration = ast.getNode(@fromBackingInt(@intCast(ast.extra_data.items[program.data.list.start])));
    const declarator_start = ast.extra_data.items[declaration.data.extra + 1];
    const declarator = ast.getNode(@fromBackingInt(@intCast(ast.extra_data.items[declarator_start])));
    const binding = ast.getNode(@fromBackingInt(@intCast(ast.extra_data.items[declarator.data.extra])));
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
        const sym = analyzer.symbols.items[@backingInt(ref.symbol_id)];
        if (std.mem.eql(u8, sym.nameText(parser.ast.source), "value")) original_ref = ref;
    }
    const source_ref = original_ref orelse return error.TestUnexpectedResult;
    const id = @backingInt(source_ref.symbol_id);

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
        if (@backingInt(ref.symbol_id) != id or ref.flags.declare) continue;
        try std.testing.expect(ref.flags.read);
        try std.testing.expect(!ref.flags.write);
        try std.testing.expectEqual(source_ref.scope_id, ref.scope_id);
        try std.testing.expectEqual(source_ref.stmt_idx, ref.stmt_idx);
        try std.testing.expectEqual(source_ref.scope_stmt_idx, ref.scope_stmt_idx);
        if (distinct) |first| try std.testing.expect(first != ref.node_index);
        if (ref.node_index == source_ref.node_index) original_is_live = true;
        if (@backingInt(ref.node_index) >= transformer.parser_node_count) {
            try std.testing.expectEqual(@as(?u32, @backingInt(source_ref.node_index)), transformer.reference_origin_map.get(@backingInt(ref.node_index)));
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

test "optional chain captures unresolved globals once and tracks exact temp provenance" {
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
            for (edited.references) |reference| {
                const symbol = edited.symbols.items[@backingInt(reference.symbol_id)];
                try std.testing.expectEqual(@import("../semantic/symbol.zig").SymbolKind.variable_var, symbol.kind);
                try std.testing.expect(symbol.synthetic_name.len > 0);
            }

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
            try std.testing.expectEqual(@as(usize, 1), external_reads);
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
    try std.testing.expectEqual(@as(usize, 6), transformer.synthetic_temp_symbol_ids.count());
    const edited = (try transformer.finishSemanticEdit()).?;
    try std.testing.expectEqual(original_symbols + 6, edited.symbols.items.len);
    var name_counts = [_]usize{ 0, 0, 0 };
    for (edited.symbols.items[original_symbols..]) |generated| {
        const name = transformer.ast.getText(generated.name);
        const name_index: usize = if (std.mem.eql(u8, name, "_b"))
            0
        else if (std.mem.eql(u8, name, "_c"))
            1
        else if (std.mem.eql(u8, name, "_d"))
            2
        else
            return error.TestUnexpectedResult;
        name_counts[name_index] += 1;
        try std.testing.expectEqual(@as(u32, 2), generated.reference_count);
        try std.testing.expectEqual(@as(u32, 1), generated.write_count);
    }
    try std.testing.expectEqualSlices(usize, &.{ 2, 2, 2 }, &name_counts);

    var capture_scopes: [2]u32 = undefined;
    var capture_count: usize = 0;
    var capture_ids = transformer.synthetic_temp_symbol_ids.valueIterator();
    while (capture_ids.next()) |raw_id_ptr| {
        const raw_id = raw_id_ptr.*;
        try std.testing.expect(raw_id >= original_symbols);
        const capture = edited.symbols.items[raw_id];
        if (!std.mem.eql(u8, "_d", transformer.ast.getText(capture.name))) continue;
        try std.testing.expectEqual(@as(u32, 2), capture.reference_count);
        try std.testing.expectEqual(@as(u32, 1), capture.write_count);
        try std.testing.expectEqual(@as(usize, @intCast(raw_id)), edited.scope_maps[capture.scope_id.toIndex()].get("_d").?);

        var bindings: usize = 0;
        var references: usize = 0;
        for (edited.symbol_ids, 0..) |maybe_id, node_index| {
            if (maybe_id != raw_id) continue;
            switch (transformer.ast.nodes.items[node_index].tag) {
                .binding_identifier => bindings += 1,
                .identifier_reference => references += 1,
                else => {},
            }
        }
        try std.testing.expectEqual(@as(usize, 1), bindings);
        try std.testing.expectEqual(@as(usize, 2), references);
        capture_scopes[capture_count] = capture.scope_id.toIndex();
        capture_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), capture_count);
    try std.testing.expect(capture_scopes[0] != capture_scopes[1]);
    try std.testing.expectEqual(@as(usize, 0), transformer.pending_temp_ref_chains.count());
}

test "#4819 assignment target temps exclude unused candidate references" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var scanner = try Scanner.init(allocator, "const _a = 1; const box = { x: 2 }; function obj() { return box; } function key() { return 'x'; } function updateInside() { obj()[key()] ||= 5; obj()[key()] **= 2; } updateInside(); obj()[key()] ||= 6; obj()[key()] **= 3; console.log(box.x, _a);");
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
    try std.testing.expectEqual(@as(usize, 8), transformer.synthetic_temp_symbol_ids.count());
    try std.testing.expectEqual(@as(usize, 0), transformer.pending_temp_ref_chains.count());
    const edited = (try transformer.finishSemanticEdit()).?;
    try std.testing.expectEqual(original_symbols + 8, edited.symbols.items.len);
    var observed_scopes = [_]u32{ std.math.maxInt(u32), std.math.maxInt(u32) };
    var symbols_per_scope = [_]usize{ 0, 0 };
    var names_per_scope: [2][4][]const u8 = undefined;
    for (edited.symbols.items[original_symbols..], original_symbols..) |generated, symbol_index| {
        try std.testing.expectEqual(@as(u32, 2), generated.reference_count);
        try std.testing.expectEqual(@as(u32, 1), generated.write_count);
        var bindings: usize = 0;
        var references: usize = 0;
        for (edited.symbol_ids, 0..) |maybe_id, node_index| {
            const id = maybe_id orelse continue;
            if (@as(usize, @intCast(id)) != symbol_index) continue;
            switch (transformer.ast.nodes.items[node_index].tag) {
                .binding_identifier => bindings += 1,
                .identifier_reference, .assignment_target_identifier => references += 1,
                else => {},
            }
        }
        try std.testing.expectEqual(@as(usize, 1), bindings);
        try std.testing.expectEqual(@as(usize, 2), references);
        const scope_raw = generated.scope_id.toIndex();
        var scope_index: usize = 0;
        while (scope_index < observed_scopes.len and observed_scopes[scope_index] != scope_raw) : (scope_index += 1) {}
        if (scope_index == observed_scopes.len) {
            scope_index = 0;
            while (scope_index < observed_scopes.len and observed_scopes[scope_index] != std.math.maxInt(u32)) : (scope_index += 1) {}
            try std.testing.expect(scope_index < observed_scopes.len);
            observed_scopes[scope_index] = scope_raw;
        }
        try std.testing.expect(symbols_per_scope[scope_index] < names_per_scope[scope_index].len);
        names_per_scope[scope_index][symbols_per_scope[scope_index]] = transformer.ast.getText(generated.name);
        symbols_per_scope[scope_index] += 1;
    }
    try std.testing.expect(observed_scopes[0] != observed_scopes[1]);
    try std.testing.expectEqualSlices(usize, &.{ 4, 4 }, &symbols_per_scope);
    var repeated_names: usize = 0;
    for (names_per_scope[0]) |first_name| {
        for (names_per_scope[1]) |second_name| {
            if (std.mem.eql(u8, first_name, second_name)) repeated_names += 1;
        }
    }
    try std.testing.expect(repeated_names > 0);
    try std.testing.expectEqual(@as(usize, 0), transformer.pending_temp_ref_chains.count());
}

test "#4819 assignment target temp references keep producer SymbolIds after span lookup is dropped" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var scanner = try Scanner.init(
        allocator,
        "function getObject() { return {}; } function getKey() { return 'x'; } getObject()[getKey()] ||= 1;",
    );
    var parser = Parser.init(allocator, &scanner);
    parser.configureFromExtension(".mjs");
    const root = try parser.parse();
    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    analyzer.is_module = true;
    try analyzer.analyze();
    const program_scope = analyzer.scope_owner_map.get(@backingInt(root)) orelse
        return error.MissingProgramScope;

    var transformer = try Transformer.init(allocator, &parser.ast, .{});
    try transformer.initSymbolIds(analyzer.symbol_ids.items);
    transformer.symbols = analyzer.symbols.items;
    transformer.class_self_symbol_map = analyzer.class_self_symbol_map;
    transformer.references = analyzer.references.items;
    transformer.scopes = analyzer.scopes.items;
    transformer.scope_maps = analyzer.scope_maps.items;
    transformer.scope_owner_map = analyzer.scope_owner_map;
    transformer.semantic_edit_enabled = true;
    transformer.current_scope = @fromBackingInt(@intCast(program_scope));

    var member_target: ?AstNodeIndex = null;
    for (parser.ast.nodes.items, 0..) |node, index| {
        if (node.tag == .computed_member_expression) {
            member_target = @fromBackingInt(@intCast(index));
            break;
        }
    }
    const left = member_target orelse return error.MissingAssignmentMemberTarget;
    const left_span = transformer.ast.getNode(left).span;
    const prepared = (try es_helpers.prepareAssignmentTargetRef(&transformer, left, left_span)) orelse
        return error.MissingPreparedAssignmentTarget;

    var temp_count: usize = 0;
    for (prepared.temps) |maybe_temp| {
        const temp = maybe_temp orelse continue;
        const symbol_id = temp.identity.symbol_id orelse return error.MissingProducerTempSymbolId;
        const producer_write = (try transformer.semantic_editor.?.referenceForNode(temp.first_write)) orelse
            return error.MissingProducerTempWriteReference;
        try std.testing.expectEqual(symbol_id, producer_write.symbol_id);
        try std.testing.expectEqual(temp.identity.reference_scope, producer_write.scope_id);
        try std.testing.expect(producer_write.flags.write);
        try std.testing.expectEqual(@as(?u32, @backingInt(symbol_id)), transformer.getSymbolIdAt(temp.first_write));
        var matched_temp_slot = false;
        var temp_slots = transformer.temp_span_by_counter.iterator();
        while (temp_slots.next()) |entry| {
            if (entry.value_ptr.start != temp.identity.span.start or entry.value_ptr.end != temp.identity.span.end) continue;
            try std.testing.expectEqual(@as(?u32, @backingInt(symbol_id)), transformer.temp_symbol_ids_by_counter.get(entry.key_ptr.*));
            if (matched_temp_slot) return error.DuplicateProducerTempSlot;
            matched_temp_slot = true;
        }
        try std.testing.expect(matched_temp_slot);
        try std.testing.expectEqual(@as(?u32, null), transformer.getSymbolIdAt(temp.value_read));
        try std.testing.expectEqual(@as(?u32, null), transformer.getSymbolIdAt(temp.write_read));
        transformer.forgetSyntheticTempSymbolLookup(temp.identity.span, temp.identity.reference_scope);
        temp_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), temp_count);
    try std.testing.expectEqual(@as(usize, 0), transformer.synthetic_temp_symbol_ids.count());

    try es_helpers.trackAssignmentTargetRefs(&transformer, prepared, true, true);
    for (prepared.temps) |maybe_temp| {
        const temp = maybe_temp orelse continue;
        const symbol_id = temp.identity.symbol_id.?;
        inline for (.{ temp.value_read, temp.write_read }) |reference_node| {
            const reference = (try transformer.semantic_editor.?.referenceForNode(reference_node)) orelse
                return error.MissingTrackedAssignmentTempReadReference;
            try std.testing.expectEqual(symbol_id, reference.symbol_id);
            try std.testing.expectEqual(temp.identity.reference_scope, reference.scope_id);
            try std.testing.expect(reference.flags.read);
            try std.testing.expectEqual(@as(?u32, @backingInt(symbol_id)), transformer.getSymbolIdAt(reference_node));
        }
    }
}

test "#4819 tracked temp references reserve exact symbols in known scopes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var scanner = try Scanner.init(
        allocator,
        "const _a = 0; const key = 'value'; function build(key) { return { before: 0, [key]: 1 }; } const nested = build(key); const top = { before: 2, [key]: 3 }; console.log(nested.value, top.value, _a);",
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
        .defer_runtime_helper_name_resolution = true,
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
    try std.testing.expectEqual(@as(usize, 2), transformer.synthetic_temp_symbol_ids.count());
    try std.testing.expectEqual(@as(usize, 0), transformer.pending_temp_ref_chains.count());

    const edited = (try transformer.finishSemanticEdit()).?;
    try std.testing.expectEqual(original_symbols + 2, edited.symbols.items.len);
    var temp_scopes = [_]u32{ std.math.maxInt(u32), std.math.maxInt(u32) };
    var temp_names: [2][]const u8 = undefined;
    for (edited.symbols.items[original_symbols..], original_symbols..) |generated, symbol_index| {
        try std.testing.expect(generated.synthetic_kind == .standalone_temp_binding);
        try std.testing.expectEqual(@as(?usize, symbol_index), edited.scope_maps[@backingInt(generated.scope_id)].get(generated.synthetic_name));
        try std.testing.expectEqual(@as(u32, 3), generated.reference_count);
        try std.testing.expectEqual(@as(u32, 1), generated.write_count);
        var bindings: usize = 0;
        var references: usize = 0;
        for (edited.symbol_ids, 0..) |maybe_id, node_index| {
            const id = maybe_id orelse continue;
            if (@as(usize, @intCast(id)) != symbol_index) continue;
            switch (transformer.ast.nodes.items[node_index].tag) {
                .binding_identifier => bindings += 1,
                .identifier_reference, .assignment_target_identifier => references += 1,
                else => {},
            }
        }
        try std.testing.expectEqual(@as(usize, 1), bindings);
        try std.testing.expectEqual(@as(usize, 3), references);
        temp_scopes[symbol_index - original_symbols] = generated.scope_id.toIndex();
        temp_names[symbol_index - original_symbols] = transformer.ast.getText(generated.name);
    }
    try std.testing.expect(temp_scopes[0] != temp_scopes[1]);
    try std.testing.expectEqualStrings(temp_names[0], temp_names[1]);
    try std.testing.expectEqualStrings("_b", temp_names[0]);
}

fn checkTrackedTempsStayFixedWhenDynamicLookupCanObserveThem(source: []const u8, extension: []const u8, is_module: bool) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var scanner = try Scanner.init(allocator, source);
    var parser = Parser.init(allocator, &scanner);
    parser.configureFromExtension(extension);
    _ = try parser.parse();
    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    analyzer.is_module = is_module;
    try analyzer.analyze();
    const original_symbols = analyzer.symbols.items.len;

    var transformer = try Transformer.init(allocator, &parser.ast, .{
        .unsupported = TransformOptions.compat.fromESTarget(.es5),
        .defer_runtime_helper_name_resolution = true,
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
    const reachable = try @import("../parser/ast_walk.zig").collectReachableNodeIndices(allocator, transformer.ast);

    var temp_count: usize = 0;
    var temp_ids = transformer.synthetic_temp_symbol_ids.valueIterator();
    while (temp_ids.next()) |raw_id| {
        const id: usize = @intCast(raw_id.*);
        try std.testing.expect(id >= original_symbols and id < edited.symbols.items.len);
        const symbol = edited.symbols.items[id];
        try std.testing.expect(symbol.synthetic_kind != .standalone_temp_binding);
        try std.testing.expectEqual(@as(?usize, id), edited.scope_maps[@backingInt(symbol.scope_id)].get(symbol.synthetic_name));
        var references: usize = 0;
        for (edited.references) |reference| {
            if (@backingInt(reference.symbol_id) != id or reference.flags.declare) continue;
            try std.testing.expect(std.mem.indexOfScalar(u32, reachable, @backingInt(reference.node_index)) != null);
            try std.testing.expectEqual(@as(?u32, @intCast(id)), edited.symbol_ids[@backingInt(reference.node_index)]);
            references += 1;
        }
        try std.testing.expect(references > 0);
        temp_count += 1;
    }
    try std.testing.expect(temp_count > 0);
}

test "#4819 tracked temp names stay fixed when eval or with can observe them" {
    try checkTrackedTempsStayFixedWhenDynamicLookupCanObserveThem(
        "function build(key) { return { before: 0, [key]: 1 }; } function sibling() { eval(''); } build('value');",
        ".mjs",
        true,
    );
    try checkTrackedTempsStayFixedWhenDynamicLookupCanObserveThem(
        "function build(key) { with (globalThis) { return { before: 0, [key]: 1 }; } } build('value');",
        ".js",
        false,
    );
}

fn checkTlaResultTempLateName(source: []const u8, expected_late_name: bool) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var scanner = try Scanner.init(allocator, source);
    var parser = Parser.init(allocator, &scanner);
    parser.configureFromExtension(".mjs");
    const root = try parser.parse();
    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    analyzer.is_module = true;
    try analyzer.analyze();
    const original_symbol_count = analyzer.symbols.items.len;
    const program_scope = analyzer.scope_owner_map.get(@backingInt(root)) orelse
        return error.MissingProgramScope;

    var transformer = try Transformer.init(allocator, &parser.ast, .{
        .unsupported = .{ .top_level_await = true },
        .defer_runtime_helper_name_resolution = true,
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

    const stmt_idx = transformer.tla_iife_stmt orelse return error.MissingTlaPromiseStatement;
    const stmt = transformer.ast.getNode(stmt_idx);
    if (stmt.tag != .variable_declaration) return error.InvalidTlaPromiseStatement;
    const extra = stmt.data.extra;
    if (extra + 2 >= transformer.ast.extra_data.items.len) return error.InvalidTlaPromiseDeclaration;
    const list_start = transformer.ast.extra_data.items[extra + 1];
    const list_len = transformer.ast.extra_data.items[extra + 2];
    if (list_len != 1 or list_start >= transformer.ast.extra_data.items.len)
        return error.InvalidTlaPromiseDeclaration;
    const decl_idx: AstNodeIndex = @fromBackingInt(@intCast(transformer.ast.extra_data.items[list_start]));
    const decl = transformer.ast.getNode(decl_idx);
    if (decl.tag != .variable_declarator or decl.data.extra >= transformer.ast.extra_data.items.len)
        return error.InvalidTlaPromiseBinding;
    const binding_idx: AstNodeIndex = @fromBackingInt(@intCast(transformer.ast.extra_data.items[decl.data.extra]));
    const binding = transformer.ast.getNode(binding_idx);
    if (binding.tag != .binding_identifier) return error.InvalidTlaPromiseBinding;
    const raw_binding = @backingInt(binding_idx);
    if (raw_binding >= edited.symbol_ids.len) return error.MissingTlaPromiseSymbolId;
    const symbol_id = edited.symbol_ids[raw_binding] orelse return error.MissingTlaPromiseSymbolId;
    if (symbol_id >= edited.symbols.items.len) return error.InvalidTlaPromiseSymbolId;
    try std.testing.expect(symbol_id >= original_symbol_count);
    for (edited.symbols.items[0..original_symbol_count]) |source_symbol| {
        try std.testing.expect(source_symbol.synthetic_kind != .standalone_temp_binding);
    }
    const symbol = edited.symbols.items[symbol_id];
    try std.testing.expectEqual(@as(u32, program_scope), @backingInt(symbol.scope_id));
    try std.testing.expectEqual(expected_late_name, symbol.synthetic_kind == .standalone_temp_binding);
    try std.testing.expectEqual(
        @as(?usize, symbol_id),
        edited.scope_maps[program_scope].get(symbol.synthetic_name),
    );
}

test "#4819 TLA result temp late naming follows its exact SymbolId and dynamic-scope gate" {
    try checkTlaResultTempLateName("const _a = 1; await Promise.resolve();", true);
    try checkTlaResultTempLateName("eval(''); await Promise.resolve();", false);
}

test "#4819 lexical synthetic temps finalize only through their exact binding ID" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var scanner = try Scanner.init(allocator, "export {};");
    var parser = Parser.init(allocator, &scanner);
    parser.configureFromExtension(".mjs");
    const root = try parser.parse();
    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    analyzer.is_module = true;
    try analyzer.analyze();
    const program_scope = analyzer.scope_owner_map.get(@backingInt(root)) orelse return error.MissingProgramScope;

    var transformer = try Transformer.init(allocator, &parser.ast, .{
        .defer_runtime_helper_name_resolution = true,
    });
    try transformer.initSymbolIds(analyzer.symbol_ids.items);
    transformer.symbols = analyzer.symbols.items;
    transformer.references = analyzer.references.items;
    transformer.scopes = analyzer.scopes.items;
    transformer.scope_maps = analyzer.scope_maps.items;
    transformer.scope_owner_map = analyzer.scope_owner_map;
    transformer.semantic_edit_enabled = true;

    const name_span = try transformer.ast.addUniqueString("_lexicalTemp");
    const binding = try @import("es_helpers.zig").makeSyntheticBinding(&transformer, name_span);
    try transformer.bindSyntheticTempInScope(binding, name_span, .EMPTY, .variable_const, @fromBackingInt(@intCast(program_scope)));
    const id = transformer.getSymbolIdAt(binding) orelse return error.MissingSyntheticTempSymbol;
    const edited = (try transformer.finishSemanticEdit()).?;
    const symbol = edited.symbols.items[id];
    try std.testing.expectEqual(SymbolKind.variable_const, symbol.kind);
    try std.testing.expect(symbol.synthetic_kind == .standalone_temp_binding);
    try std.testing.expectEqual(@as(u32, program_scope), @backingInt(symbol.scope_id));
    try std.testing.expectEqual(@as(?usize, id), edited.scope_maps[program_scope].get(symbol.synthetic_name));
    try std.testing.expectEqual(@as(?u32, id), edited.symbol_ids[@backingInt(binding)]);
}

test "#4819 tracked captures attach the write SymbolId before reads" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const helpers = @import("es_helpers.zig");
    var scanner = try Scanner.init(allocator, "const source = 'value';");
    var parser = Parser.init(allocator, &scanner);
    parser.configureFromExtension(".mjs");
    const root = try parser.parse();
    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    analyzer.is_module = true;
    try analyzer.analyze();
    const program_scope = analyzer.scope_owner_map.get(@backingInt(root)) orelse
        return error.MissingProgramScope;
    var value: ?AstNodeIndex = null;
    for (parser.ast.nodes.items, 0..) |node, index| {
        if (node.tag == .string_literal) value = @fromBackingInt(@intCast(index));
    }
    const value_idx = value orelse return error.MissingCapturedValue;
    const value_node = parser.ast.getNode(value_idx);

    var transformer = try Transformer.init(allocator, &parser.ast, .{});
    try transformer.initSymbolIds(analyzer.symbol_ids.items);
    transformer.symbols = analyzer.symbols.items;
    transformer.class_self_symbol_map = analyzer.class_self_symbol_map;
    transformer.references = analyzer.references.items;
    transformer.scopes = analyzer.scopes.items;
    transformer.scope_maps = analyzer.scope_maps.items;
    transformer.scope_owner_map = analyzer.scope_owner_map;
    transformer.semantic_edit_enabled = true;
    transformer.current_scope = @fromBackingInt(@intCast(program_scope));

    const captured = try helpers.captureToTrackedTemp(&transformer, value_idx, value_node.span);
    const assignment = transformer.ast.getNode(captured.paren_assign);
    const write = assignment.data.binary.left;
    const write_id = transformer.getSymbolIdAt(write) orelse return error.MissingCapturedTempWriteSymbol;
    const read = try helpers.makeTrackedTempRef(&transformer, captured.span, value_node.span, .{ .read = true });
    const read_id = transformer.getSymbolIdAt(read) orelse return error.MissingCapturedTempReadSymbol;
    try std.testing.expectEqual(write_id, read_id);
    try std.testing.expectEqual(@as(usize, 1), transformer.synthetic_temp_symbol_ids.count());
    try std.testing.expectEqual(@as(usize, 0), transformer.pending_temp_ref_chains.count());
}

test "#4819 constructor spread capture refs reserve one immediate SymbolId" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const spread = @import("es2015_spread.zig").ES2015Spread(Transformer);
    var scanner = try Scanner.init(
        allocator,
        "function Pair(left, right) {} function getPair() { return Pair; } new (getPair())(...[1, 2]);",
    );
    var parser = Parser.init(allocator, &scanner);
    parser.configureFromExtension(".mjs");
    const root = try parser.parse();
    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    analyzer.is_module = true;
    try analyzer.analyze();
    const program_scope = analyzer.scope_owner_map.get(@backingInt(root)) orelse
        return error.MissingProgramScope;
    var source_new: ?AstNodeIndex = null;
    for (parser.ast.nodes.items, 0..) |node, index| {
        if (node.tag == .new_expression) source_new = @fromBackingInt(@intCast(index));
    }
    const new_idx = source_new orelse return error.MissingSpreadConstructor;

    var transformer = try Transformer.init(allocator, &parser.ast, .{});
    try transformer.initSymbolIds(analyzer.symbol_ids.items);
    transformer.symbols = analyzer.symbols.items;
    transformer.class_self_symbol_map = analyzer.class_self_symbol_map;
    transformer.references = analyzer.references.items;
    transformer.scopes = analyzer.scopes.items;
    transformer.scope_maps = analyzer.scope_maps.items;
    transformer.scope_owner_map = analyzer.scope_owner_map;
    transformer.semantic_edit_enabled = true;
    transformer.current_scope = @fromBackingInt(@intCast(program_scope));

    _ = try spread.lowerSpreadNew(&transformer, parser.ast.getNode(new_idx));
    try std.testing.expectEqual(@as(usize, 1), transformer.synthetic_temp_symbol_ids.count());
    try std.testing.expectEqual(@as(usize, 0), transformer.pending_temp_ref_chains.count());
    var temp_ids = transformer.synthetic_temp_symbol_ids.valueIterator();
    const temp_id = temp_ids.next() orelse return error.MissingSpreadTempSymbol;
    var exact_refs: usize = 0;
    for (transformer.ast.nodes.items, 0..) |node, index| {
        if (node.tag != .identifier_reference) continue;
        const id = transformer.getSymbolIdAt(@fromBackingInt(@intCast(index))) orelse continue;
        if (id == temp_id.*) exact_refs += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), exact_refs);
}

fn expectPrehoistedClassKeyProducerIdentity(source: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var scanner = try Scanner.init(allocator, source);
    var parser = Parser.init(allocator, &scanner);
    parser.configureFromExtension(".mjs");
    const root = try parser.parse();
    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    analyzer.is_module = true;
    try analyzer.analyze();
    const program_scope = analyzer.scope_owner_map.get(@backingInt(root)) orelse
        return error.MissingProgramScope;
    var source_class: ?AstNodeIndex = null;
    for (parser.ast.nodes.items, 0..) |node, index| {
        if (node.tag == .class_declaration or node.tag == .class_expression)
            source_class = @fromBackingInt(@intCast(index));
    }
    const class_idx = source_class orelse return error.MissingPrehoistedClass;

    var transformer = try Transformer.init(allocator, &parser.ast, .{});
    try transformer.initSymbolIds(analyzer.symbol_ids.items);
    transformer.symbols = analyzer.symbols.items;
    transformer.class_self_symbol_map = analyzer.class_self_symbol_map;
    transformer.references = analyzer.references.items;
    transformer.scopes = analyzer.scopes.items;
    transformer.scope_maps = analyzer.scope_maps.items;
    transformer.scope_owner_map = analyzer.scope_owner_map;
    transformer.semantic_edit_enabled = true;
    transformer.current_scope = @fromBackingInt(@intCast(program_scope));

    _ = try transformer.lowerClassWithPrehoistedKeys(
        class_idx,
        parser.ast.getNode(class_idx),
        keepOriginalClassForSyntheticTempTest,
    );
    try std.testing.expect(transformer.synthetic_temp_symbol_ids.count() > 0);
    try std.testing.expectEqual(@as(usize, 0), transformer.pending_temp_ref_chains.count());
    const editor = if (transformer.semantic_editor) |*value| value else return error.MissingSemanticEditor;
    var temp_ids = transformer.synthetic_temp_symbol_ids.valueIterator();
    while (temp_ids.next()) |temp_id| {
        var exact_refs: usize = 0;
        for (transformer.ast.nodes.items, 0..) |node, index| {
            if (node.tag != .identifier_reference and node.tag != .assignment_target_identifier) continue;
            const node_idx: AstNodeIndex = @fromBackingInt(@intCast(index));
            const id = transformer.getSymbolIdAt(node_idx) orelse continue;
            if (id != temp_id.*) continue;
            const reference = (try editor.referenceForNode(node_idx)) orelse return error.MissingPrehoistedTempReference;
            try std.testing.expectEqual(temp_id.*, @backingInt(reference.symbol_id));
            try std.testing.expect(editor.symbolVisibleFrom(reference.symbol_id, reference.scope_id));
            exact_refs += 1;
        }
        try std.testing.expect(exact_refs >= 2);
    }
}

test "#4819 prehoisted class key producer IDs survive hostile source forms" {
    const hostile_sources = [_][]const u8{
        "class Box { [getKey()]() {} value = 1; }",
        "class Box { [getKey()] = 1; }",
        "class Box { static [getKey()] = 1; }",
        "class Box { get [getKey()]() { return 1; } set [setKey()](value) {} value = 1; }",
        "class Box { [firstKey()]() {} [secondKey()]() {} value = 1; }",
        "class Box extends getBase() { [getKey()]() {} value = 1; }",
        "class Box { ['fixed']() {} [Symbol.iterator]() {} value = 1; }",
        "class Box { [(() => getKey())()]() {} value = 1; }",
        "const Box = class { [getKey()]() {} value = 1; };",
        "class Box { static [firstKey()] = 1; [secondKey()]() {} get [thirdKey()]() { return 2; } value = 1; }",
    };
    for (hostile_sources) |source| try expectPrehoistedClassKeyProducerIdentity(source);
}

test "#4819 known hoisted temp refs use the producer SymbolId after lookup removal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const helpers = @import("es_helpers.zig");
    var scanner = try Scanner.init(allocator, "function callback() {} const value = 'value';");
    var parser = Parser.init(allocator, &scanner);
    parser.configureFromExtension(".mjs");
    const root = try parser.parse();
    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    analyzer.is_module = true;
    try analyzer.analyze();
    const program_scope = analyzer.scope_owner_map.get(@backingInt(root)) orelse
        return error.MissingProgramScope;
    var nested_function_scope: ?u32 = null;
    for (analyzer.scopes.items, 0..) |scope, index| {
        if (scope.kind == .function) {
            nested_function_scope = @intCast(index);
            break;
        }
    }
    const reference_scope = nested_function_scope orelse return error.MissingNestedFunctionScope;

    var transformer = try Transformer.init(allocator, &parser.ast, .{});
    try transformer.initSymbolIds(analyzer.symbol_ids.items);
    transformer.symbols = analyzer.symbols.items;
    transformer.class_self_symbol_map = analyzer.class_self_symbol_map;
    transformer.references = analyzer.references.items;
    transformer.scopes = analyzer.scopes.items;
    transformer.scope_maps = analyzer.scope_maps.items;
    transformer.scope_owner_map = analyzer.scope_owner_map;
    transformer.semantic_edit_enabled = true;
    transformer.current_scope = @fromBackingInt(@intCast(program_scope));

    const identity = try helpers.reserveTrackedTempIdentity(&transformer, parser.ast.getNode(root).span);
    const expected_id = identity.symbol_id orelse return error.MissingReservedTempSymbol;
    const counter = transformer.temp_var_counter - 1;
    try std.testing.expectEqual(@as(?u32, @backingInt(expected_id)), transformer.temp_symbol_ids_by_counter.get(counter));
    transformer.forgetSyntheticTempSymbolLookup(identity.span, identity.reference_scope);
    try std.testing.expect(transformer.lookupSyntheticTempSymbol(identity.span, identity.reference_scope) == null);
    const reference = try helpers.makeSyntheticRefFromSpan(&transformer, identity.span);
    const write_reference = try transformer.ast.addNode(.{
        .tag = .assignment_target_identifier,
        .span = parser.ast.getNode(root).span,
        .data = .{ .string_ref = identity.span },
    });
    try std.testing.expect(try helpers.trackKnownHoistedTempRef(
        &transformer,
        reference,
        @fromBackingInt(@intCast(reference_scope)),
        .{ .read = true },
    ));
    try std.testing.expect(try helpers.trackKnownHoistedTempRef(
        &transformer,
        write_reference,
        @fromBackingInt(@intCast(reference_scope)),
        .{ .write = true },
    ));

    const actual_id = transformer.getSymbolIdAt(reference) orelse return error.MissingKnownTempReferenceSymbol;
    const actual_write_id = transformer.getSymbolIdAt(write_reference) orelse return error.MissingKnownTempWriteSymbol;
    try std.testing.expectEqual(@backingInt(expected_id), actual_id);
    try std.testing.expectEqual(@backingInt(expected_id), actual_write_id);
    try std.testing.expectEqual(@as(usize, 0), transformer.synthetic_temp_symbol_ids.count());
    try std.testing.expectEqual(@as(usize, 0), transformer.pending_temp_ref_chains.count());
    try std.testing.expectEqual(@as(usize, 0), transformer.pending_temp_refs.items.len);
    const editor = if (transformer.semantic_editor) |*value| value else return error.MissingSemanticEditor;
    const semantic_ref = (try editor.referenceForNode(reference)) orelse return error.MissingKnownTempReference;
    const semantic_write_ref = (try editor.referenceForNode(write_reference)) orelse return error.MissingKnownTempWriteReference;
    try std.testing.expectEqual(expected_id, semantic_ref.symbol_id);
    try std.testing.expectEqual(@as(u32, @intCast(reference_scope)), @backingInt(semantic_ref.scope_id));
    try std.testing.expect(semantic_ref.flags.read and !semantic_ref.flags.write);
    try std.testing.expectEqual(expected_id, semantic_write_ref.symbol_id);
    try std.testing.expectEqual(@as(u32, @intCast(reference_scope)), @backingInt(semantic_write_ref.scope_id));
    try std.testing.expect(semantic_write_ref.flags.write and !semantic_write_ref.flags.read);

    const fallback_span = try helpers.makeTempVarSpan(&transformer);
    const fallback_counter = transformer.temp_var_counter - 1;
    try std.testing.expect(transformer.temp_symbol_ids_by_counter.get(fallback_counter) == null);
    const fallback_binding = try helpers.makeSyntheticBinding(&transformer, fallback_span);
    const fallback_id = (try transformer.declareSyntheticTempInScope(
        fallback_binding,
        parser.ast.getNode(root).span,
        @fromBackingInt(@intCast(program_scope)),
    )) orelse return error.MissingFallbackTempSymbol;
    const fallback_reference = try helpers.makeSyntheticRefFromSpan(&transformer, fallback_span);
    try std.testing.expect(try helpers.trackKnownHoistedTempRef(
        &transformer,
        fallback_reference,
        @fromBackingInt(@intCast(reference_scope)),
        .{ .read = true },
    ));
    try std.testing.expectEqual(@as(?u32, @backingInt(fallback_id)), transformer.getSymbolIdAt(fallback_reference));
    try std.testing.expectEqual(@as(usize, 0), transformer.pending_temp_refs.items.len);
}

fn expectSuperProtoAliasSymbolIdentity(source: []const u8, lower_generator: bool, lower_optional_chain: bool) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var scanner = try Scanner.init(allocator, source);
    var parser = Parser.init(allocator, &scanner);
    parser.configureFromExtension(".mjs");
    _ = try parser.parse();
    try std.testing.expectEqual(@as(usize, 0), parser.errors.items.len);

    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    analyzer.is_module = true;
    analyzer.collect_unresolved_reference_nodes = true;
    try analyzer.analyze();
    try std.testing.expectEqual(@as(usize, 0), analyzer.errors.items.len);

    var options: TransformOptions = .{
        .unsupported = TransformOptions.compat.fromESTarget(if (lower_optional_chain) .es2019 else .es2021),
    };
    options.unsupported.generator = lower_generator;
    var transformer = try Transformer.init(allocator, &parser.ast, options);
    try transformer.initSymbolIds(analyzer.symbol_ids.items);
    transformer.symbols = analyzer.symbols.items;
    transformer.class_self_symbol_map = analyzer.class_self_symbol_map;
    transformer.references = analyzer.references.items;
    transformer.scopes = analyzer.scopes.items;
    transformer.scope_maps = analyzer.scope_maps.items;
    transformer.scope_owner_map = analyzer.scope_owner_map;
    transformer.unresolved_reference_nodes = &analyzer.unresolved_reference_nodes;
    transformer.semantic_edit_enabled = true;

    const transformed_root = try transformer.transform();
    const reachable = try @import("../parser/ast_walk.zig").collectReachableNodeIndicesFrom(allocator, transformer.ast, transformed_root);
    defer allocator.free(reachable);

    var alias_name_span_opt: ?Span = null;
    // Generator lowering may move the alias initializer into a state-machine
    // assignment, so find the name from the actual __superGet base first.
    // The initializer fallback keeps this test useful for paths that do not
    // produce a __superGet call (for example, if the super access is rewritten
    // by an earlier transform).
    for (reachable) |raw| {
        const node = transformer.ast.nodes.items[raw];
        if (node.tag == .call_expression) {
            const call_extra = node.data.extra;
            const callee = transformer.readNodeIdx(call_extra, 0);
            const callee_node = transformer.ast.getNode(callee);
            if (callee_node.tag != .identifier_reference or
                !std.mem.eql(u8, transformer.ast.getText(callee_node.data.string_ref), "__superGet")) continue;
            const args_start = transformer.readU32(call_extra, 1);
            const args_len = transformer.readU32(call_extra, 2);
            if (args_len == 0) continue;
            const base: AstNodeIndex = @fromBackingInt(@intCast(transformer.ast.extra_data.items[args_start]));
            const base_node = transformer.ast.getNode(base);
            if (base_node.tag != .identifier_reference) continue;
            alias_name_span_opt = base_node.data.string_ref;
            break;
        }
    }
    if (alias_name_span_opt == null) {
        for (reachable) |raw| {
            const node = transformer.ast.nodes.items[raw];
            if (node.tag != .variable_declarator) continue;
            const initializer = transformer.readNodeIdx(node.data.extra, 2);
            if (initializer.isNone() or transformer.ast.getNode(initializer).tag != .call_expression) continue;
            const callee = transformer.readNodeIdx(transformer.ast.getNode(initializer).data.extra, 0);
            if (transformer.ast.getNode(callee).tag != .static_member_expression) continue;
            const property = transformer.readNodeIdx(transformer.ast.getNode(callee).data.extra, 1);
            const property_node = transformer.ast.getNode(property);
            if (property_node.tag != .identifier_reference or
                !std.mem.eql(u8, transformer.ast.getText(property_node.data.string_ref), "getPrototypeOf")) continue;
            const binding = transformer.readNodeIdx(node.data.extra, 0);
            const binding_node = transformer.ast.getNode(binding);
            if (binding_node.tag != .binding_identifier) continue;
            alias_name_span_opt = binding_node.data.string_ref;
            break;
        }
    }
    const alias_name_span = alias_name_span_opt orelse return error.MissingSuperProtoAliasBindingSpan;
    var alias_binding: ?AstNodeIndex = null;
    for (reachable) |raw| {
        const index: usize = raw;
        const node = transformer.ast.nodes.items[index];
        if (index < transformer.parser_node_count or node.tag != .binding_identifier) continue;
        if (node.data.string_ref.start != alias_name_span.start or node.data.string_ref.end != alias_name_span.end) continue;
        if (alias_binding != null) return error.DuplicateSuperProtoAliasBinding;
        alias_binding = @fromBackingInt(@intCast(index));
    }
    const alias_binding_node = alias_binding orelse return error.MissingSuperProtoAliasBinding;
    const binding_node = transformer.ast.getNode(alias_binding_node);
    try std.testing.expect(binding_node.tag == .binding_identifier);
    const alias_name = transformer.ast.getText(binding_node.data.string_ref);
    const alias_id = transformer.getSymbolIdAt(alias_binding_node) orelse return error.MissingSuperProtoAliasBindingSymbol;
    try std.testing.expect(alias_id >= analyzer.symbols.items.len);
    const alias_owner_scope = transformer.semantic_editor.?.symbols.items[alias_id].scope_id;
    try std.testing.expect(transformer.lookupSyntheticTempSymbol(alias_name_span, alias_owner_scope) == null);
    const live_editor = &transformer.semantic_editor.?;
    var live_alias_reference_count: usize = 0;
    for (reachable) |raw| {
        const node = transformer.ast.nodes.items[raw];
        if (node.tag != .identifier_reference or
            node.data.string_ref.start != alias_name_span.start or
            node.data.string_ref.end != alias_name_span.end) continue;
        try std.testing.expectEqual(alias_id, transformer.getSymbolIdAt(@fromBackingInt(@intCast(raw))) orelse
            return error.MissingLiveSuperProtoAliasReadSymbol);
        const reference = (try live_editor.referenceForNode(@fromBackingInt(@intCast(raw)))) orelse
            return error.MissingLiveSuperProtoAliasReference;
        try std.testing.expectEqual(alias_id, @backingInt(reference.symbol_id));
        live_alias_reference_count += 1;
    }
    try std.testing.expect(live_alias_reference_count > 0);

    var alias_class_read: ?AstNodeIndex = null;
    for (reachable) |raw| {
        const node = transformer.ast.nodes.items[raw];
        if (node.tag != .call_expression) continue;
        const callee = transformer.readNodeIdx(node.data.extra, 0);
        const callee_node = transformer.ast.getNode(callee);
        if (callee_node.tag != .static_member_expression) continue;
        const property = transformer.readNodeIdx(callee_node.data.extra, 1);
        const property_node = transformer.ast.getNode(property);
        if (property_node.tag != .identifier_reference or
            !std.mem.eql(u8, transformer.ast.getText(property_node.data.string_ref), "getPrototypeOf")) continue;
        const args_start = transformer.readU32(node.data.extra, 1);
        const args_len = transformer.readU32(node.data.extra, 2);
        if (args_len == 0) continue;
        const prototype = @as(AstNodeIndex, @fromBackingInt(@intCast(transformer.ast.extra_data.items[args_start])));
        const prototype_node = transformer.ast.getNode(prototype);
        if (prototype_node.tag != .static_member_expression) continue;
        const class_read = transformer.readNodeIdx(prototype_node.data.extra, 0);
        if (transformer.ast.getNode(class_read).tag != .identifier_reference) continue;
        if (alias_class_read != null) return error.DuplicateSuperProtoAliasClassRead;
        alias_class_read = class_read;
    }
    const class_read_node = alias_class_read orelse return error.MissingSuperProtoAliasClassRead;
    const class_read_id = transformer.getSymbolIdAt(class_read_node) orelse
        return error.MissingSuperProtoAliasClassReadSymbol;
    try std.testing.expect(class_read_id != alias_id);

    var binding_count: usize = 0;
    for (reachable) |raw| {
        const index: usize = raw;
        const node = transformer.ast.nodes.items[index];
        if (index < transformer.parser_node_count or node.tag != .binding_identifier) continue;
        if (node.data.string_ref.start != alias_name_span.start or node.data.string_ref.end != alias_name_span.end) continue;
        const binding_id = transformer.getSymbolIdAt(@fromBackingInt(@intCast(index))) orelse
            std.debug.panic("super alias binding has no live SymbolId at node {d}: {s}", .{ index, alias_name });
        try std.testing.expectEqual(alias_id, binding_id);
        binding_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), binding_count);
    const edited = (try transformer.finishSemanticEdit()).?;
    try std.testing.expectEqual(alias_id, edited.symbol_ids[@backingInt(alias_binding_node)] orelse return error.MissingSuperProtoAliasBindingSymbolAfterEdit);
    var edited_binding_count: usize = 0;
    for (reachable) |raw| {
        const index: usize = raw;
        const node = transformer.ast.nodes.items[index];
        if (index < transformer.parser_node_count or node.tag != .binding_identifier) continue;
        if (node.data.string_ref.start != alias_name_span.start or node.data.string_ref.end != alias_name_span.end) continue;
        try std.testing.expectEqual(alias_id, edited.symbol_ids[index] orelse return error.MissingSuperProtoAliasBindingSymbolAfterEdit);
        edited_binding_count += 1;
    }
    try std.testing.expectEqual(binding_count, edited_binding_count);
    try std.testing.expectEqual(@import("../semantic/symbol.zig").SymbolKind.variable_var, edited.symbols.items[alias_id].kind);
    try std.testing.expectEqual(class_read_id, edited.symbol_ids[@backingInt(class_read_node)] orelse return error.MissingSuperProtoAliasClassReadSymbolAfterEdit);
    var alias_class_reference_found = false;
    for (edited.references) |reference| {
        if (reference.node_index != class_read_node) continue;
        try std.testing.expectEqual(class_read_id, @backingInt(reference.symbol_id));
        try std.testing.expect(reference.flags.read);
        alias_class_reference_found = true;
        break;
    }
    try std.testing.expect(alias_class_reference_found);
    var alias_reference_count: u32 = 0;
    var alias_read_reference_count: u32 = 0;
    for (reachable) |raw| {
        const node = transformer.ast.nodes.items[raw];
        if (node.tag != .identifier_reference or
            node.data.string_ref.start != alias_name_span.start or node.data.string_ref.end != alias_name_span.end) continue;
        try std.testing.expectEqual(alias_id, edited.symbol_ids[raw] orelse return error.MissingReachableSuperProtoAliasReadSymbol);
        var matching_read = false;
        for (edited.references) |reference| {
            if (reference.node_index != @as(AstNodeIndex, @fromBackingInt(@intCast(raw)))) continue;
            try std.testing.expectEqual(alias_id, @backingInt(reference.symbol_id));
            try std.testing.expect(reference.flags.read or reference.flags.write);
            if (reference.flags.read) alias_read_reference_count += 1;
            try std.testing.expect(reference.scope_id != alias_owner_scope);
            var cursor = reference.scope_id;
            var visible_from_owner = false;
            var hops: usize = 0;
            while (!cursor.isNone() and hops < edited.scopes.len) : (hops += 1) {
                if (cursor == alias_owner_scope) {
                    visible_from_owner = true;
                    break;
                }
                if (cursor.toIndex() >= edited.scopes.len) break;
                cursor = edited.scopes[cursor.toIndex()].parent;
            }
            try std.testing.expect(visible_from_owner);
            matching_read = true;
            break;
        }
        try std.testing.expect(matching_read);
        alias_reference_count += 1;
    }
    try std.testing.expect(alias_reference_count >= 1);
    try std.testing.expect(alias_read_reference_count > 0);
    try std.testing.expectEqual(alias_reference_count, edited.symbols.items[alias_id].reference_count);
    try std.testing.expectEqual(@as(usize, 0), transformer.pending_temp_ref_chains.count());
}

test "#4819 super proto-chain alias keeps its exact SymbolId" {
    try expectSuperProtoAliasSymbolIdentity(
        "function getBase() { return class Base {}; } class Child extends getBase() { #value() { const Child = 1; return super.value; } #other() { return super.other; } method() { return [this.#value(), this.#other()]; } }",
        false,
        false,
    );
    try expectSuperProtoAliasSymbolIdentity(
        "function getBase() { return class Base {}; } function build() { return class Child extends getBase() { #value() { const Child = 1; return super.value; } #other() { return super.other; } method() { return [this.#value(), this.#other()]; } }; }",
        false,
        false,
    );
    try expectSuperProtoAliasSymbolIdentity(
        "function getBase() { return class Base {}; } function build(_a) { class Child extends getBase() { #value() { const Child = 1; return super.value; } #other() { return super.other; } method() { const _a = 1; return [this.#value(), this.#other()]; } } return Child; }",
        false,
        false,
    );
    try expectSuperProtoAliasSymbolIdentity(
        "function getBase() { return class Base {}; } function* build() { class Child extends getBase() { #value() { const Child = 1; return super.value; } #other() { return super.other; } method() { return [this.#value(), this.#other()]; } } yield Child; }",
        true,
        false,
    );
    try expectSuperProtoAliasSymbolIdentity(
        "function getBase() { return class Base {}; } class Child extends getBase() { #value() { return super.value?.(); } method() { return this.#value(); } }",
        false,
        true,
    );
    try expectSuperProtoAliasSymbolIdentity(
        "function getBase() { return class Base {}; } class Child extends getBase() { #value() { const _a = 1; return () => super.value; } method() { return this.#value()(); } }",
        false,
        false,
    );
    try expectSuperProtoAliasSymbolIdentity(
        "function getBase() { return class Base {}; } class Child extends getBase() { #value() { return 1; } *method() { yield super.value; } }",
        true,
        false,
    );
    try expectSuperProtoAliasSymbolIdentity(
        "function getBase() { return class Base {}; } class Child extends getBase() { #value() { const _a = 1; const object = { read() { return super.toString(); } }; { let _a = 2; return super.value + super.other + object.read(); } } method() { return this.#value(); } }",
        false,
        false,
    );
    try expectSuperProtoAliasSymbolIdentity(
        "function getBase() { return class Base {}; } function build(_a, _a2) { if (_a) { return class Child extends getBase() { #value() { const _a = _a2; return super.value; } }; } }",
        false,
        false,
    );
    try expectSuperProtoAliasSymbolIdentity(
        "function getBase() { return class Base {}; } function build() { return class Child extends getBase() { #value() { const _a = 1; return super.value?.(); } }; }",
        false,
        true,
    );
    try expectSuperProtoAliasSymbolIdentity(
        "function getBase() { return class Base {}; } class Child extends getBase() { #value() { const Inner = class { [super.value]() {} }; return super.value; } method() { return this.#value(); } }",
        false,
        false,
    );
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
    const first_owner: @import("../parser/ast.zig").NodeIndex = @fromBackingInt(@intCast(first_key.?));
    const second_owner: @import("../parser/ast.zig").NodeIndex = @fromBackingInt(@intCast(second_key.?));
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
        const old: @import("../parser/ast.zig").NodeIndex = @fromBackingInt(@intCast(entry.key_ptr.*));
        const new: @import("../parser/ast.zig").NodeIndex = @fromBackingInt(@intCast(entry.value_ptr.*));
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
        const callee: @import("../parser/ast.zig").NodeIndex = @fromBackingInt(@intCast(extra[e]));
        if (transformer.ast.getNode(callee).tag != .identifier_reference) continue;
        if (!std.mem.eql(u8, transformer.ast.getText(transformer.ast.getNode(callee).data.string_ref), "_loop2")) continue;
        if (extra[e + 2] != 1) continue;
        loop_arg = @fromBackingInt(@intCast(extra[extra[e + 1]]));
    }
    const argument = loop_arg orelse return error.TestUnexpectedResult;
    const emitted_header_id = loop_storage_id;
    try std.testing.expect(emitted_header_id != header_id);
    try std.testing.expectEqual(@as(?u32, emitted_header_id), edited.symbol_ids[@backingInt(argument)]);
    try std.testing.expectEqual(@as(?u32, null), transformer.reference_origin_map.get(@backingInt(argument)));
    var argument_refs: usize = 0;
    for (edited.references) |ref| {
        if (ref.node_index != argument) continue;
        try std.testing.expectEqual(emitted_header_id, @backingInt(ref.symbol_id));
        try std.testing.expect(ref.flags.read);
        try std.testing.expect(!ref.flags.write and !ref.flags.declare);
        argument_refs += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), argument_refs);
}

fn expectGeneratedLoopExactIdentity(source: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var scanner = try Scanner.init(allocator, source);
    var parser = Parser.init(allocator, &scanner);
    parser.configureFromExtension(".mjs");
    _ = try parser.parse();
    try std.testing.expectEqual(@as(usize, 0), parser.errors.items.len);

    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    analyzer.is_module = true;
    analyzer.collect_unresolved_reference_nodes = true;
    try analyzer.analyze();
    try std.testing.expectEqual(@as(usize, 0), analyzer.errors.items.len);
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
    transformer.unresolved_reference_nodes = &analyzer.unresolved_reference_nodes;
    transformer.semantic_edit_enabled = true;
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

    var source_loop_id: ?u32 = null;
    for (analyzer.symbols.items, 0..) |symbol, index| {
        if (!std.mem.eql(u8, symbol.nameText(parser.ast.source), "_loop")) continue;
        source_loop_id = @intCast(index);
    }
    const outer_id = source_loop_id orelse return error.MissingOuterLoopDecoy;

    var generated_loop_id: ?u32 = null;
    for (edited.symbols.items, 0..) |symbol, index| {
        if (index < original_symbol_count or symbol.kind != .variable_var) continue;
        if (!std.mem.startsWith(u8, transformer.ast.getText(symbol.name), "_loop")) continue;
        try std.testing.expect(generated_loop_id == null);
        generated_loop_id = @intCast(index);
    }
    const loop_id = generated_loop_id orelse return error.MissingGeneratedLoopSymbol;
    try std.testing.expect(loop_id != outer_id);

    const generated = edited.symbols.items[loop_id];
    const loop_name = transformer.ast.getText(generated.name);
    const owner_scope_index = generated.scope_id.toIndex();
    try std.testing.expect(owner_scope_index < edited.scope_maps.len);
    try std.testing.expectEqual(@as(?usize, loop_id), edited.scope_maps[owner_scope_index].get(loop_name));

    var binding_count: usize = 0;
    var identifier_reads: usize = 0;
    for (edited.symbol_ids, 0..) |maybe_id, node_index| {
        if (maybe_id != loop_id) continue;
        const node = transformer.ast.nodes.items[node_index];
        switch (node.tag) {
            .binding_identifier => binding_count += 1,
            .identifier_reference => {
                try std.testing.expectEqualStrings(loop_name, transformer.ast.getText(node.data.string_ref));
                identifier_reads += 1;
            },
            else => return error.UnexpectedGeneratedLoopSymbolNode,
        }
    }
    try std.testing.expect(binding_count > 0);
    try std.testing.expect(identifier_reads > 0);

    var reference_reads: usize = 0;
    var reference_writes: usize = 0;
    var call_scope: ?ScopeId = null;
    var outer_reads: usize = 0;
    for (edited.references) |reference| {
        const id = @backingInt(reference.symbol_id);
        if (id == loop_id) {
            if (reference.flags.declare) {
                continue;
            }
            try std.testing.expect(!reference.node_index.isNone());
            try std.testing.expectEqual(.identifier_reference, transformer.ast.getNode(reference.node_index).tag);
            try std.testing.expectEqual(loop_id, edited.symbol_ids[@backingInt(reference.node_index)].?);
            if (reference.flags.read) {
                try std.testing.expect(!reference.flags.write);
                call_scope = reference.scope_id;
                reference_reads += 1;
            }
            if (reference.flags.write) {
                try std.testing.expect(!reference.flags.read);
                reference_writes += 1;
            }
        } else if (id == outer_id and reference.flags.read) {
            if (transformer.ast.getNode(reference.node_index).tag != .identifier_reference) continue;
            if (!std.mem.eql(u8, transformer.ast.getText(transformer.ast.getNode(reference.node_index).data.string_ref), "_loop")) continue;
            outer_reads += 1;
        }
    }
    try std.testing.expect(reference_reads > 0);
    try std.testing.expectEqual(@as(u32, @intCast(reference_reads + reference_writes)), generated.reference_count);
    try std.testing.expectEqual(@as(u32, @intCast(reference_writes)), generated.write_count);
    try std.testing.expect(outer_reads > 0);

    var visible_scope = call_scope orelse return error.MissingGeneratedLoopCallScope;
    var visible = false;
    for (0..edited.scopes.len) |_| {
        if (visible_scope.isNone() or visible_scope.toIndex() >= edited.scopes.len) break;
        if (visible_scope == generated.scope_id) {
            visible = true;
            break;
        }
        visible_scope = edited.scopes[visible_scope.toIndex()].parent;
    }
    try std.testing.expect(visible);
}

test "#4819 while-extracted generator loop keeps exact binding and call identity" {
    try expectGeneratedLoopExactIdentity(
        \\export function* collect() {
        \\  const _loop = 7;
        \\  let index = 0;
        \\  while (index < 2) {
        \\    let value = index++;
        \\    yield () => value + _loop;
        \\  }
        \\}
    );
}

test "#4819 do-while-extracted generator loop keeps exact binding and call identity" {
    try expectGeneratedLoopExactIdentity(
        \\export function* collect() {
        \\  const _loop = 7;
        \\  let index = 0;
        \\  do {
        \\    let value = index++;
        \\    yield () => value + _loop;
        \\  } while (index < 2);
        \\}
    );
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
            if (@backingInt(ref.symbol_id) != data_id or !ref.flags.read) continue;
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
            if (@backingInt(ref.symbol_id) != helper_id or !ref.flags.read) continue;
            try std.testing.expectEqual(@as(?u32, @intCast(helper_id)), edited.symbol_ids[@backingInt(ref.node_index)]);
            if (case.inside_function) try std.testing.expectEqual(@import("../semantic/scope.zig").ScopeKind.function, edited.scopes[ref.scope_id.toIndex()].kind);
            bound_refs += 1;
        }
        try std.testing.expect(bound_refs >= 1);
        try std.testing.expectEqual(@as(usize, 0), transformer.tracked_runtime_helper_ref_index.count());
    }
}

test "#4819 runtime helper reference owns its SymbolId before its import exists" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var scanner = try Scanner.init(allocator, "const __extends = 'user';");
    scanner.is_module = true;
    var parser = Parser.init(allocator, &scanner);
    _ = try parser.parse();
    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    analyzer.is_module = true;
    try analyzer.analyze();
    const user_id = analyzer.scope_maps.items[0].get("__extends").?;

    var transformer = try Transformer.init(allocator, &parser.ast, .{ .emit_runtime_helper_imports = true });
    try transformer.initSymbolIds(analyzer.symbol_ids.items);
    transformer.symbols = analyzer.symbols.items;
    transformer.references = analyzer.references.items;
    transformer.scopes = analyzer.scopes.items;
    transformer.scope_maps = analyzer.scope_maps.items;
    transformer.scope_owner_map = analyzer.scope_owner_map;
    transformer.semantic_edit_enabled = true;
    transformer.current_scope = transformer.programScope();

    const helper_name = try transformer.ast.addString("__extends");
    const helper_ref = try transformer.ast.addNode(.{
        .tag = .identifier_reference,
        .span = helper_name,
        .data = .{ .string_ref = helper_name },
    });
    try transformer.markRuntimeHelperRef(helper_ref);
    _ = try transformer.trackRuntimeHelperRef(helper_ref, "__extends");

    const helper_id = transformer.getSymbolIdAt(helper_ref) orelse return error.MissingRuntimeHelperIdAtCreation;
    try std.testing.expect(@as(usize, helper_id) != user_id);
    try transformer.propagateSymbolId(helper_ref, helper_ref);
    try std.testing.expectEqual(@as(?u32, helper_id), transformer.getSymbolIdAt(helper_ref));
    const editor = &transformer.semantic_editor.?;
    try std.testing.expectEqual(@as(?usize, @intCast(helper_id)), editor.helper_scope_map.get("__extends"));
    const helper_reference = (try editor.referenceForNode(helper_ref)) orelse return error.MissingRuntimeHelperReference;
    try std.testing.expectEqual(helper_id, @backingInt(helper_reference.symbol_id));

    // A local node with another spelling cannot steal the reserved helper ID.
    const wrong_name = try transformer.ast.addString("__rest");
    const wrong_local = try transformer.ast.addNode(.{
        .tag = .identifier_reference,
        .span = wrong_name,
        .data = .{ .string_ref = wrong_name },
    });
    try std.testing.expectError(
        error.InvalidSymbol,
        editor.attachRuntimeHelperImport(wrong_local, @fromBackingInt(@intCast(helper_id)), .{ .start = 0, .end = 0 }),
    );
    try std.testing.expectEqual(@as(?u32, null), editor.symbol_ids.items[@backingInt(wrong_local)]);

    const local = try transformer.ast.addNode(.{
        .tag = .identifier_reference,
        .span = helper_name,
        .data = .{ .string_ref = helper_name },
    });
    try transformer.bindRuntimeHelperImport(local, "__extends", .{ .start = 0, .end = 0 });
    try std.testing.expectEqual(@as(?u32, helper_id), transformer.getSymbolIdAt(local));
    try std.testing.expectEqual(@as(?usize, user_id), editor.scope_maps.items[0].get("__extends"));
    try std.testing.expectEqual(@as(?u32, @intCast(@backingInt(local))), transformer.runtime_helper_import_bindings.get(helper_id));
}

test "#4819 later runtime helper callsites reuse their already selected SymbolId" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var scanner = try Scanner.init(allocator, "const value = 1;");
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
    transformer.semantic_edit_enabled = true;
    transformer.current_scope = transformer.programScope();

    const first = try es_helpers.makeRuntimeHelperRef(&transformer, "__extends");
    const first_id = transformer.getSymbolIdAt(first) orelse return error.MissingFirstRuntimeHelperId;

    // Simulate later name-resolution state discovering a collision after the
    // producer already selected the helper identity. Subsequent callsites must
    // follow the existing SymbolId instead of resolving the helper spelling again.
    transformer.runtime_helper_aliases.clearRetainingCapacity();
    try transformer.synthetic_taken.put(allocator, "__extends", {});

    const second = try es_helpers.makeRuntimeHelperRef(&transformer, "__extends");
    try std.testing.expectEqual(@as(?u32, first_id), transformer.getSymbolIdAt(second));
    try std.testing.expectEqualStrings("__extends", transformer.ast.getText(transformer.ast.getNode(second).data.string_ref));
    const editor = &transformer.semantic_editor.?;
    const first_reference = (try editor.referenceForNode(first)) orelse return error.MissingFirstRuntimeHelperReference;
    const second_reference = (try editor.referenceForNode(second)) orelse return error.MissingSecondRuntimeHelperReference;
    try std.testing.expectEqual(first_id, @backingInt(first_reference.symbol_id));
    try std.testing.expectEqual(first_id, @backingInt(second_reference.symbol_id));
    try std.testing.expect(first_reference.flags.read and second_reference.flags.read);
}

test "#4819 bundler runtime helper import consumes its callsite SymbolId" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source = "const $eX = 'user'; class Base {} export class Derived extends Base {}";
    var scanner = try Scanner.init(allocator, source);
    scanner.is_module = true;
    var parser = Parser.init(allocator, &scanner);
    _ = try parser.parse();
    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    analyzer.is_module = true;
    try analyzer.analyze();
    try std.testing.expectEqual(@as(usize, 0), analyzer.errors.items.len);
    const user_id = analyzer.scope_maps.items[0].get("$eX") orelse return error.MissingRuntimeHelperCollisionBinding;

    var transformer = try Transformer.init(allocator, &parser.ast, .{
        .unsupported = TransformOptions.compat.fromESTarget(.es5),
        .emit_runtime_helper_imports = true,
        .minify_whitespace = true,
    });
    try transformer.initSymbolIds(analyzer.symbol_ids.items);
    transformer.symbols = analyzer.symbols.items;
    transformer.class_self_symbol_map = analyzer.class_self_symbol_map;
    transformer.references = analyzer.references.items;
    transformer.scopes = analyzer.scopes.items;
    transformer.scope_maps = analyzer.scope_maps.items;
    transformer.scope_owner_map = analyzer.scope_owner_map;
    transformer.unresolved_references = &analyzer.unresolved_references;
    transformer.semantic_edit_enabled = true;
    _ = try transformer.transform();

    const helper_id = transformer.runtime_helper_symbol_ids.get("__extends") orelse return error.MissingCallsiteRuntimeHelperSymbolId;
    const raw_helper_id: u32 = @backingInt(helper_id);
    const helper_local_node = transformer.runtime_helper_import_bindings.get(raw_helper_id) orelse return error.MissingRuntimeHelperImportBinding;
    try std.testing.expectEqualStrings("$eX", transformer.ast.identifierNameText(transformer.ast.getNode(@fromBackingInt(@intCast(helper_local_node)))));
    try std.testing.expectEqual(@as(?u32, raw_helper_id), transformer.getSymbolIdAt(@fromBackingInt(@intCast(helper_local_node))));
    try std.testing.expect(raw_helper_id != user_id);
    try std.testing.expectEqual(@as(?usize, raw_helper_id), transformer.semantic_editor.?.helper_scope_map.get("$eX"));

    const edited = (try transformer.finishSemanticEdit()).?;
    try std.testing.expectEqual(@import("../semantic/symbol.zig").SymbolKind.import_binding, edited.symbols.items[raw_helper_id].kind);
    var reads: usize = 0;
    for (edited.references) |reference| {
        if (@backingInt(reference.symbol_id) != raw_helper_id or reference.flags.declare) continue;
        try std.testing.expect(reference.flags.read);
        reads += 1;
    }
    try std.testing.expect(reads >= 1);
    try std.testing.expectEqual(@as(u32, @intCast(reads)), edited.symbols.items[raw_helper_id].reference_count);
}

test "#4819 grouped bundler runtime helper imports register exact IDs without callsites" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var scanner = try Scanner.init(allocator, "export {};");
    scanner.is_module = true;
    var parser = Parser.init(allocator, &scanner);
    const root = try parser.parse();
    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    analyzer.is_module = true;
    try analyzer.analyze();
    try std.testing.expectEqual(@as(usize, 0), analyzer.errors.items.len);

    var transformer = try Transformer.init(allocator, &parser.ast, .{
        .emit_runtime_helper_imports = true,
        .minify_whitespace = true,
    });
    try transformer.initSymbolIds(analyzer.symbol_ids.items);
    transformer.symbols = analyzer.symbols.items;
    transformer.class_self_symbol_map = analyzer.class_self_symbol_map;
    transformer.references = analyzer.references.items;
    transformer.scopes = analyzer.scopes.items;
    transformer.scope_maps = analyzer.scope_maps.items;
    transformer.scope_owner_map = analyzer.scope_owner_map;
    transformer.semantic_edit_enabled = true;
    transformer.current_scope = transformer.programScope();

    const bases = [_][]const u8{
        "__assertThisInitialized",
        "__assertThisUninitialized",
        "__possibleConstructorReturn",
    };
    const callsite = try es_helpers.makeRuntimeHelperRef(&transformer, bases[0]);
    const callsite_id = transformer.runtime_helper_symbol_ids.get(bases[0]) orelse return error.MissingCallsiteRuntimeHelperSymbolId;
    try std.testing.expectEqual(@as(u32, @backingInt(callsite_id)), transformer.getSymbolIdAt(callsite).?);
    for (bases[1..]) |base| try std.testing.expectEqual(@as(?SymbolId, null), transformer.runtime_helper_symbol_ids.get(base));

    var imports: std.ArrayList(AstNodeIndex) = .empty;
    try runtime_helper_imports.appendHelperImports(
        &transformer,
        .{ .derived_constructor = true },
        parser.ast.getNode(root).span,
        &imports,
    );
    try std.testing.expectEqual(@as(usize, 1), imports.items.len);

    var seen = std.AutoHashMapUnmanaged(u32, void).empty;
    for (bases) |base| {
        const symbol_id = transformer.runtime_helper_symbol_ids.get(base) orelse return error.MissingGroupedRuntimeHelperSymbolId;
        const raw_id = @backingInt(symbol_id);
        const gop = try seen.getOrPut(allocator, raw_id);
        try std.testing.expect(!gop.found_existing);

        const editor = &transformer.semantic_editor.?;
        const symbol = editor.symbols.items[raw_id];
        try std.testing.expectEqual(SymbolKind.import_binding, symbol.kind);
        try std.testing.expectEqual(transformer.programScope(), symbol.scope_id);

        const local_raw = transformer.runtime_helper_import_bindings.get(raw_id) orelse return error.MissingGroupedRuntimeHelperImportBinding;
        const local: AstNodeIndex = @fromBackingInt(@intCast(local_raw));
        try std.testing.expectEqual(@as(?u32, raw_id), transformer.getSymbolIdAt(local));
        const local_name = transformer.ast.identifierNameText(transformer.ast.getNode(local));
        try std.testing.expectEqualStrings(local_name, symbol.synthetic_name);
        try std.testing.expect(!std.mem.eql(u8, base, local_name));
        try std.testing.expectEqual(@as(?usize, raw_id), editor.helper_scope_map.get(local_name));
    }

    _ = try transformer.prependStatementsToBody(root, imports.items);
    const edited = (try transformer.finishSemanticEdit()).?;
    for (bases) |base| {
        const symbol_id = transformer.runtime_helper_symbol_ids.get(base).?;
        const raw_id = @backingInt(symbol_id);
        const symbol = edited.symbols.items[raw_id];
        try std.testing.expectEqual(SymbolKind.import_binding, symbol.kind);
        try std.testing.expectEqual(transformer.programScope(), symbol.scope_id);
        const local_raw = transformer.runtime_helper_import_bindings.get(raw_id).?;
        try std.testing.expectEqual(@as(?u32, raw_id), edited.symbol_ids[local_raw]);
        try std.testing.expectEqualStrings(
            transformer.ast.identifierNameText(transformer.ast.getNode(@fromBackingInt(@intCast(local_raw)))),
            symbol.synthetic_name,
        );
    }
}

test "#4819 private field runtime import keeps its producer-selected alias under a user collision" {
    const source = "const __zntcClassPrivateFieldSet = 'user'; class Fields { #value = 0; write(next) { return this.#value = next; } }";
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
    const user_id = analyzer.scope_maps.items[0].get("__zntcClassPrivateFieldSet") orelse return error.MissingUserCollisionBinding;

    var transformer = try Transformer.init(allocator, &parser.ast, .{
        .unsupported = TransformOptions.compat.fromESTarget(.es2015),
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

    const helper_id = transformer.runtime_helper_symbol_ids.get("__classPrivateFieldSet") orelse return error.MissingCallsiteRuntimeHelperSymbolId;
    const helper_raw: u32 = @backingInt(helper_id);
    try std.testing.expect(helper_raw != user_id);
    try std.testing.expectEqual(@as(?usize, helper_raw), edited.helper_scope_map.get("__zntcClassPrivateFieldSet"));
    const import_node_raw = transformer.runtime_helper_import_bindings.get(helper_raw) orelse return error.MissingRuntimeHelperImportBinding;
    const import_node = transformer.ast.getNode(@fromBackingInt(@intCast(import_node_raw)));
    try std.testing.expectEqualStrings("__zntcClassPrivateFieldSet", transformer.ast.getText(import_node.data.string_ref));
    try std.testing.expectEqual(@as(?u32, helper_raw), transformer.getSymbolIdAt(@fromBackingInt(@intCast(import_node_raw))));
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

    const cases = [_]struct { local: []const u8, user_id: usize, symbol_id: ?SymbolId }{
        .{ .local = transformer.jsx_import_info.jsx_local, .user_id = user_jsx_id, .symbol_id = transformer.jsx_import_info.jsx_symbol_id },
        .{ .local = transformer.jsx_import_info.jsxs_local, .user_id = user_jsxs_id, .symbol_id = transformer.jsx_import_info.jsxs_symbol_id },
        .{ .local = transformer.jsx_import_info.fragment_local, .user_id = user_fragment_id, .symbol_id = transformer.jsx_import_info.fragment_symbol_id },
        .{ .local = transformer.jsx_import_info.createElement_local, .user_id = user_create_element_id, .symbol_id = transformer.jsx_import_info.createElement_symbol_id },
    };
    for (cases) |case| {
        try std.testing.expect(case.local.len > 0);
        const exact_id = case.symbol_id orelse return error.MissingJsxHelperSymbol;
        const helper_id = edited.helper_scope_map.get(case.local) orelse return error.MissingJsxHelperSymbol;
        try std.testing.expectEqual(@as(usize, @intCast(@backingInt(exact_id))), helper_id);
        try std.testing.expect(helper_id != case.user_id);
        try std.testing.expectEqual(@import("../semantic/symbol.zig").SymbolKind.import_binding, edited.symbols.items[helper_id].kind);
        var declarations: usize = 0;
        var reads: usize = 0;
        for (edited.references) |reference| {
            if (@backingInt(reference.symbol_id) != helper_id) continue;
            if (reference.flags.declare) {
                declarations += 1;
            } else if (reference.flags.read) {
                reads += 1;
                try std.testing.expectEqual(function_scope, @backingInt(reference.scope_id));
                const node = transformer.ast.getNode(reference.node_index);
                try std.testing.expectEqual(@as(?u32, @intCast(helper_id)), edited.symbol_ids[@backingInt(reference.node_index)]);
                try std.testing.expectEqualStrings(case.local, transformer.ast.identifierNameText(node));
            }
        }
        try std.testing.expectEqual(@as(usize, 1), declarations);
        try std.testing.expect(reads >= 1);
        try std.testing.expectEqual(@as(u32, @intCast(reads)), edited.symbols.items[helper_id].reference_count);
    }
    try std.testing.expectEqual(@as(usize, 0), transformer.tracked_runtime_helper_ref_index.count());
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
            if (@backingInt(reference.node_index) != raw) continue;
            try std.testing.expectEqual(react_parameter, @backingInt(reference.symbol_id));
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

test "#4819 Emotion css prop reads the exact imported SymbolId in its use scope" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source = "import { css as cx } from '@emotion/react'; " ++
        "const _emotionCss = 1; const _emotionCss2 = 2; " ++
        "function render(cx) { return <div css={{ color: 'red' }} />; }";
    var scanner = try Scanner.init(allocator, source);
    var parser = Parser.init(allocator, &scanner);
    parser.configureFromExtension(".tsx");
    _ = try parser.parse();
    try std.testing.expectEqual(@as(usize, 0), parser.errors.items.len);

    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    analyzer.is_module = true;
    try analyzer.analyze();
    try std.testing.expectEqual(@as(usize, 0), analyzer.errors.items.len);

    var import_local: ?@import("../parser/ast.zig").NodeIndex = null;
    for (parser.ast.nodes.items) |node| {
        if (node.tag != .import_specifier) continue;
        const imported: @import("../parser/ast.zig").NodeIndex = node.data.binary.left;
        const local: @import("../parser/ast.zig").NodeIndex = node.data.binary.right;
        if (std.mem.eql(u8, parser.ast.getText(parser.ast.getNode(imported).span), "css") and
            std.mem.eql(u8, parser.ast.getText(parser.ast.getNode(local).span), "cx"))
        {
            import_local = local;
            break;
        }
    }
    const import_node = import_local orelse return error.MissingEmotionCssImportLocal;
    const import_symbol = analyzer.symbol_ids.items[@backingInt(import_node)] orelse
        return error.MissingEmotionCssImportSymbol;
    try std.testing.expectEqual(@import("../semantic/symbol.zig").SymbolKind.import_binding, analyzer.symbols.items[import_symbol].kind);

    var shadow_symbol: ?u32 = null;
    for (analyzer.symbols.items, 0..) |symbol, raw| {
        if (symbol.kind == .parameter and std.mem.eql(u8, symbol.nameText(parser.ast.source), "cx")) {
            shadow_symbol = @intCast(raw);
        }
    }
    const shadow_id = shadow_symbol orelse return error.MissingShadowingCssParameter;
    try std.testing.expect(import_symbol != shadow_id);

    var transformer = try Transformer.init(allocator, &parser.ast, .{
        .emotion = true,
        .jsx_transform = true,
        .jsx_runtime = .classic,
        .defer_runtime_helper_name_resolution = true,
    });
    try transformer.initSymbolIds(analyzer.symbol_ids.items);
    transformer.symbols = analyzer.symbols.items;
    transformer.class_self_symbol_map = analyzer.class_self_symbol_map;
    transformer.references = analyzer.references.items;
    transformer.scopes = analyzer.scopes.items;
    transformer.scope_maps = analyzer.scope_maps.items;
    transformer.scope_owner_map = analyzer.scope_owner_map;
    transformer.unresolved_references = &analyzer.unresolved_references;
    transformer.semantic_edit_enabled = true;
    transformer.synthetic_idents = .empty;
    const output_root = try transformer.transform();
    const edited = (try transformer.finishSemanticEdit()).?;

    const stored_import_node = transformer.plugins.emotion.css_binding_node orelse
        return error.MissingEmotionCssImportNodeHandle;
    try std.testing.expectEqual(import_node, stored_import_node);
    const alias_binding = transformer.plugins.emotion.css_prop_alias_binding orelse
        return error.MissingEmotionCssAliasBinding;
    const synthetic_idents = if (transformer.synthetic_idents) |*set| set else return error.MissingSyntheticIdentifierSet;
    try std.testing.expect(synthetic_idents.contains(@backingInt(alias_binding)));
    const alias_symbol = transformer.getSymbolIdAt(alias_binding) orelse
        return error.MissingEmotionCssAliasSymbol;
    try std.testing.expectEqual(@import("../semantic/symbol.zig").SymbolKind.import_binding, edited.symbols.items[alias_symbol].kind);
    try std.testing.expectEqual(@as(?SyntheticKind, .runtime_helper_import), edited.symbols.items[alias_symbol].synthetic_kind);
    const alias_staging_name = transformer.ast.getText(transformer.ast.getNode(alias_binding).span);
    try std.testing.expectEqualStrings("_emotionCss3", alias_staging_name);
    try std.testing.expectEqualStrings(
        "_emotionCss",
        transformer.late_output_name_bases.get(alias_staging_name) orelse return error.MissingEmotionCssOutputNameBase,
    );
    try std.testing.expect(transformer.plugins.emotion.css_prop_use_alias);
    try std.testing.expect(!transformer.plugins.emotion.css_prop_import_required);
    const alias_import = transformer.plugins.emotion.css_prop_alias_import orelse
        return error.MissingEmotionCssAliasImport;
    const output_program = transformer.ast.getNode(output_root);
    try std.testing.expectEqual(@import("../parser/ast.zig").Node.Tag.program, output_program.tag);
    var retained_import = false;
    var retained_alias_import = false;
    for (transformer.ast.extra_data.items[output_program.data.list.start .. output_program.data.list.start + output_program.data.list.len]) |raw| {
        const child: @import("../parser/ast.zig").NodeIndex = @fromBackingInt(@intCast(raw));
        if (transformer.ast.getNode(child).tag == .import_declaration) retained_import = true;
        if (child == alias_import) retained_alias_import = true;
    }
    try std.testing.expect(retained_import);
    try std.testing.expect(retained_alias_import);

    const ExpectedReference = struct {
        symbol: u32,
        scope: @TypeOf(analyzer.symbols.items[import_symbol].scope_id),
    };
    var alias_reads: usize = 0;
    for (transformer.ast.nodes.items, 0..) |node, raw| {
        if (raw < transformer.parser_node_count or node.tag != .identifier_reference) continue;
        const name = transformer.ast.getText(node.data.string_ref);
        const expected: ExpectedReference = if (std.mem.eql(u8, name, transformer.ast.getText(transformer.ast.getNode(alias_binding).span))) .{
            .symbol = alias_symbol,
            .scope = analyzer.symbols.items[shadow_id].scope_id,
        } else continue;
        try std.testing.expectEqual(@as(?u32, expected.symbol), edited.symbol_ids[raw]);
        var node_references: usize = 0;
        for (edited.references) |reference| {
            if (@backingInt(reference.node_index) != raw) continue;
            try std.testing.expectEqual(expected.symbol, @backingInt(reference.symbol_id));
            try std.testing.expectEqual(expected.scope, reference.scope_id);
            try std.testing.expect(reference.flags.read);
            try std.testing.expect(!reference.flags.write and !reference.flags.declare);
            node_references += 1;
        }
        try std.testing.expectEqual(@as(usize, 1), node_references);
        alias_reads += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), alias_reads);
    try std.testing.expectEqual(@as(u32, 0), edited.symbols.items[import_symbol].reference_count);
    try std.testing.expectEqual(@as(u32, 1), edited.symbols.items[alias_symbol].reference_count);
    try std.testing.expectEqual(@as(u32, 0), edited.symbols.items[shadow_id].reference_count);
}

test "#4819 Emotion css alias early-name path avoids descendant direct eval names" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source = "import { css as cx } from '@emotion/react'; " ++
        "const _emotionCss = 0; " ++
        "function render(cx) { eval('_emotionCss' + '2'); return <div css={{ color: 'red' }} />; }";
    try std.testing.expectEqualStrings("_emotionCss3", try transformEmotionCssAliasForTest(allocator, source));
}

test "#4819 Emotion css alias avoids hostile static eval name forms in early-name mode" {
    const EvalForm = enum {
        literal_single,
        concat_suffix,
        concat_prefix,
        parenthesized_concat,
        split_middle,
        three_part_concat,
        nested_concat,
        template_literal,
        template_expression,
        double_quote_concat,
        escaped_literal,
    };
    const forms = [_]EvalForm{
        .literal_single,
        .concat_suffix,
        .concat_prefix,
        .parenthesized_concat,
        .split_middle,
        .three_part_concat,
        .nested_concat,
        .template_literal,
        .template_expression,
        .double_quote_concat,
        .escaped_literal,
    };

    for (forms, 0..) |form, index| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        const occupied_suffix: u32 = @intCast(index + 2);
        const suffix = try std.fmt.allocPrint(allocator, "{d}", .{occupied_suffix});
        const eval_expression = try switch (form) {
            .literal_single => std.fmt.allocPrint(allocator, "'_emotionCss{s}'", .{suffix}),
            .concat_suffix => std.fmt.allocPrint(allocator, "'_emotionCss' + '{s}'", .{suffix}),
            .concat_prefix => std.fmt.allocPrint(allocator, "'_' + 'emotionCss{s}'", .{suffix}),
            .parenthesized_concat => std.fmt.allocPrint(allocator, "('_emotionCss' + ('{s}'))", .{suffix}),
            .split_middle => std.fmt.allocPrint(allocator, "'_emotion' + 'Css{s}'", .{suffix}),
            .three_part_concat => std.fmt.allocPrint(allocator, "'_' + 'emotion' + 'Css{s}'", .{suffix}),
            .nested_concat => std.fmt.allocPrint(allocator, "'_emotionCss' + ('{s}' + '')", .{suffix}),
            .template_literal => std.fmt.allocPrint(allocator, "`_emotionCss{s}`", .{suffix}),
            .template_expression => std.fmt.allocPrint(allocator, "`${{'_emotionCss'}}{s}`", .{suffix}),
            .double_quote_concat => std.fmt.allocPrint(allocator, "\"_emotionCss\" + \"{s}\"", .{suffix}),
            .escaped_literal => std.fmt.allocPrint(allocator, "'\\x5femotionCss{s}'", .{suffix}),
        };

        var source: []const u8 = "import { css as cx } from '@emotion/react';\nconst _emotionCss = 0;\n";
        var reserved_suffix: u32 = 2;
        while (reserved_suffix < occupied_suffix) : (reserved_suffix += 1) {
            source = try std.fmt.allocPrint(allocator, "{s}const _emotionCss{d} = 0;\n", .{ source, reserved_suffix });
        }
        source = try std.fmt.allocPrint(allocator, "{s}function render(cx) {{ eval({s}); return <div css=", .{ source, eval_expression });
        source = try std.fmt.allocPrint(allocator, "{s}{s}", .{ source, "{{ color: 'red' } } />; }" });

        const actual_name = try transformEmotionCssAliasForTest(allocator, source);
        const expected_name = try std.fmt.allocPrint(allocator, "_emotionCss{d}", .{occupied_suffix + 1});
        try std.testing.expectEqualStrings(expected_name, actual_name);
    }
}

fn transformEmotionCssAliasForTest(allocator: std.mem.Allocator, source: []const u8) ![]const u8 {
    var scanner = try Scanner.init(allocator, source);
    var parser = Parser.init(allocator, &scanner);
    parser.configureFromExtension(".tsx");
    _ = try parser.parse();
    try std.testing.expectEqual(@as(usize, 0), parser.errors.items.len);

    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    analyzer.is_module = true;
    try analyzer.analyze();
    try std.testing.expectEqual(@as(usize, 0), analyzer.errors.items.len);

    var transformer = try Transformer.init(allocator, &parser.ast, .{
        .emotion = true,
        .jsx_transform = true,
        .jsx_runtime = .classic,
        .defer_runtime_helper_name_resolution = false,
    });
    try transformer.initSymbolIds(analyzer.symbol_ids.items);
    transformer.symbols = analyzer.symbols.items;
    transformer.class_self_symbol_map = analyzer.class_self_symbol_map;
    transformer.references = analyzer.references.items;
    transformer.scopes = analyzer.scopes.items;
    transformer.scope_maps = analyzer.scope_maps.items;
    transformer.scope_owner_map = analyzer.scope_owner_map;
    transformer.unresolved_references = &analyzer.unresolved_references;
    transformer.semantic_edit_enabled = true;
    transformer.synthetic_idents = .empty;
    _ = try transformer.transform();
    const edited = (try transformer.finishSemanticEdit()).?;

    const alias_binding = transformer.plugins.emotion.css_prop_alias_binding orelse
        return error.MissingEmotionCssAliasBinding;
    const alias_symbol = transformer.getSymbolIdAt(alias_binding) orelse
        return error.MissingEmotionCssAliasSymbol;
    try std.testing.expectEqual(SymbolKind.import_binding, edited.symbols.items[alias_symbol].kind);
    try std.testing.expectEqual(transformer.programScope(), edited.symbols.items[alias_symbol].scope_id);
    return transformer.ast.getText(transformer.ast.getNode(alias_binding).span);
}

test "#4819 Emotion css prop import keeps its staging name when descendant eval can observe it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source = "import { css as cx } from '@emotion/react'; " ++
        "function render(cx, suffix) { eval('_emotionCss' + suffix); return <div css={{ color: 'red' }} />; }";
    var scanner = try Scanner.init(allocator, source);
    var parser = Parser.init(allocator, &scanner);
    parser.configureFromExtension(".tsx");
    _ = try parser.parse();
    try std.testing.expectEqual(@as(usize, 0), parser.errors.items.len);

    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    analyzer.is_module = true;
    try analyzer.analyze();
    try std.testing.expectEqual(@as(usize, 0), analyzer.errors.items.len);

    var transformer = try Transformer.init(allocator, &parser.ast, .{
        .emotion = true,
        .jsx_transform = true,
        .jsx_runtime = .classic,
        .defer_runtime_helper_name_resolution = true,
    });
    try transformer.initSymbolIds(analyzer.symbol_ids.items);
    transformer.symbols = analyzer.symbols.items;
    transformer.class_self_symbol_map = analyzer.class_self_symbol_map;
    transformer.references = analyzer.references.items;
    transformer.scopes = analyzer.scopes.items;
    transformer.scope_maps = analyzer.scope_maps.items;
    transformer.scope_owner_map = analyzer.scope_owner_map;
    transformer.unresolved_references = &analyzer.unresolved_references;
    transformer.semantic_edit_enabled = true;
    transformer.synthetic_idents = .empty;
    _ = try transformer.transform();
    const edited = (try transformer.finishSemanticEdit()).?;

    const binding = transformer.plugins.emotion.css_prop_alias_binding orelse
        return error.MissingEmotionCssAliasBinding;
    const symbol_id = transformer.getSymbolIdAt(binding) orelse return error.MissingEmotionCssAliasSymbol;
    try std.testing.expectEqual(@as(?SyntheticKind, null), edited.symbols.items[symbol_id].synthetic_kind);
    try std.testing.expectEqualStrings("_emotionCss2", transformer.ast.getText(transformer.ast.getNode(binding).span));
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
            if (@backingInt(reference.node_index) != raw) continue;
            try std.testing.expectEqual(react_symbol, @backingInt(reference.symbol_id));
            try std.testing.expect(reference.flags.read);
            has_reference = true;
        }
        try std.testing.expect(has_reference);
        react_reads += 1;
    }
    try std.testing.expectEqual(@as(usize, 5), react_reads);
    try std.testing.expectEqual(@as(u32, 5), edited.symbols.items[react_symbol].reference_count);
}

test "#4819 Flow forwardRef helper avoids ten hostile static eval names in early-name mode" {
    const eval_arguments = [_][]const u8{
        "'View_withRef'",
        "'View_withRef' + ''",
        "'' + 'View_withRef'",
        "('View_withRef' + '')",
        "'View_' + 'withRef'",
        "'View' + '_withRef'",
        "'View' + ('_withRef')",
        "`View_withRef`",
        "`${'View_withRef'}`",
        "'View_\\x77ithRef'",
    };

    for (eval_arguments) |eval_argument| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        const source = try std.fmt.allocPrint(
            allocator,
            "// @flow\nimport React from 'react';\nfunction observe() {{ eval({s}); }}\n" ++
                "export component View(ref?: mixed, value: number, ...props: {{ label?: string }}) {{ " ++
                "return <div value={{value}} />; }}",
            .{eval_argument},
        );
        try std.testing.expectEqualStrings("View_withRef2", try transformFlowForwardRefHelperForTest(allocator, source));
    }
}

fn transformFlowForwardRefHelperForTest(allocator: std.mem.Allocator, source: []const u8) ![]const u8 {
    const FunctionExtra = @import("../parser/ast.zig").FunctionExtra;
    var scanner = try Scanner.init(allocator, source);
    var parser = Parser.init(allocator, &scanner);
    parser.configureFromExtension(".jsx");
    _ = try parser.parse();
    try std.testing.expectEqual(@as(usize, 0), parser.errors.items.len);

    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    analyzer.is_module = true;
    try analyzer.analyze();
    try std.testing.expectEqual(@as(usize, 0), analyzer.errors.items.len);

    var transformer = try Transformer.init(allocator, &parser.ast, .{
        .jsx_transform = true,
        .jsx_runtime = .classic,
        .unsupported = TransformOptions.compat.fromESTarget(.es5),
        .defer_runtime_helper_name_resolution = false,
    });
    try transformer.initSymbolIds(analyzer.symbol_ids.items);
    transformer.symbols = analyzer.symbols.items;
    transformer.class_self_symbol_map = analyzer.class_self_symbol_map;
    transformer.references = analyzer.references.items;
    transformer.scopes = analyzer.scopes.items;
    transformer.scope_maps = analyzer.scope_maps.items;
    transformer.scope_owner_map = analyzer.scope_owner_map;
    transformer.unresolved_references = &analyzer.unresolved_references;
    transformer.semantic_edit_enabled = true;

    _ = try transformer.transform();
    const edited = (try transformer.finishSemanticEdit()).?;
    var helper_name_idx: ?AstNodeIndex = null;
    var helper_name: ?[]const u8 = null;
    for (transformer.ast.nodes.items) |node| {
        if (node.tag != .function_declaration) continue;
        const name_idx = transformer.readNodeIdx(node.data.extra, FunctionExtra.name);
        if (name_idx.isNone()) continue;
        const name = transformer.ast.getText(transformer.ast.getNode(name_idx).span);
        if (!std.mem.startsWith(u8, name, "View_withRef")) continue;
        helper_name_idx = name_idx;
        helper_name = name;
    }
    const binding = helper_name_idx orelse return error.MissingFlowForwardRefHelperBinding;
    const name = helper_name orelse return error.MissingFlowForwardRefHelperName;
    const symbol_id = transformer.getSymbolIdAt(binding) orelse return error.MissingFlowForwardRefHelperSymbolId;
    const symbol = edited.symbols.items[symbol_id];
    try std.testing.expectEqual(SymbolKind.function_decl, symbol.kind);
    try std.testing.expectEqual(transformer.programScope(), symbol.scope_id);
    var forward_ref_argument_found = false;
    for (transformer.ast.nodes.items, 0..) |node, raw| {
        if (node.tag != .identifier_reference or
            !std.mem.eql(u8, transformer.ast.getText(node.span), name)) continue;
        try std.testing.expectEqual(@as(?u32, symbol_id), edited.symbol_ids[raw]);
        forward_ref_argument_found = true;
    }
    try std.testing.expect(forward_ref_argument_found);
    return name;
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
    const exact_id = transformer.jsx_import_info.jsxDEV_symbol_id orelse return error.MissingJsxDevHelperSymbol;
    try std.testing.expectEqual(helper_id, @as(usize, @intCast(@backingInt(exact_id))));
    try std.testing.expect(helper_id != user_id);
    try std.testing.expectEqual(@import("../semantic/symbol.zig").SymbolKind.import_binding, edited.symbols.items[helper_id].kind);
    var reads: usize = 0;
    for (edited.references) |reference| {
        if (@backingInt(reference.symbol_id) != helper_id or reference.flags.declare) continue;
        try std.testing.expect(reference.flags.read);
        try std.testing.expectEqual(function_scope, @backingInt(reference.scope_id));
        const node = transformer.ast.getNode(reference.node_index);
        try std.testing.expectEqual(@as(?u32, @intCast(helper_id)), edited.symbol_ids[@backingInt(reference.node_index)]);
        try std.testing.expectEqualStrings(local, transformer.ast.identifierNameText(node));
        reads += 1;
    }
    try std.testing.expectEqual(@as(u32, @intCast(reads)), edited.symbols.items[helper_id].reference_count);
    try std.testing.expect(reads >= 1);
    try std.testing.expectEqual(@as(usize, 0), transformer.tracked_runtime_helper_ref_index.count());
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
    const exact_id = transformer.jsx_import_info.jsx_symbol_id orelse return error.MissingStandaloneJsxHelperSymbol;
    try std.testing.expectEqual(helper_id, @as(usize, @intCast(@backingInt(exact_id))));
    try std.testing.expect(helper_id != user_id);
    try std.testing.expectEqual(@import("../semantic/symbol.zig").SymbolKind.import_binding, edited.symbols.items[helper_id].kind);
    var declarations: usize = 0;
    var reads: usize = 0;
    for (edited.references) |reference| {
        if (@backingInt(reference.symbol_id) != helper_id) continue;
        if (reference.flags.declare) {
            declarations += 1;
        } else if (reference.flags.read) {
            reads += 1;
            try std.testing.expectEqual(expected_function_scope, @backingInt(reference.scope_id));
            try std.testing.expectEqual(@as(?u32, @intCast(helper_id)), edited.symbol_ids[@backingInt(reference.node_index)]);
        }
    }
    try std.testing.expectEqual(@as(usize, 1), declarations);
    try std.testing.expectEqual(@as(usize, 1), reads);
    try std.testing.expectEqual(@as(u32, @intCast(reads)), edited.symbols.items[helper_id].reference_count);
    try std.testing.expectEqual(@as(usize, 0), transformer.tracked_runtime_helper_ref_index.count());
}

test "#4819 for-in temporaries bind symbols during lowering" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const NodeIndex = @import("../parser/ast.zig").NodeIndex;
    // Occupy the usual generated spellings so this also checks that the
    // generated binding handle, not a repeated spelling lookup, owns refs.
    const source = "const _a = 0, _b = 0, _keys = 0, _idx = 0; for (const value in source) use(value);";
    var scanner = try Scanner.init(allocator, source);
    var parser = Parser.init(allocator, &scanner);
    parser.configureFromExtension(".mjs");
    _ = try parser.parse();
    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    analyzer.is_module = true;
    try analyzer.analyze();
    var source_loop: ?NodeIndex = null;
    for (parser.ast.nodes.items, 0..) |node, index| {
        if (node.tag == .for_in_statement) source_loop = @fromBackingInt(@intCast(index));
    }
    const loop = source_loop orelse return error.MissingForInLoop;
    const loop_scope = analyzer.scope_owner_map.get(@backingInt(loop)) orelse return error.MissingForInScope;

    var transformer = try Transformer.init(allocator, &parser.ast, .{});
    try transformer.initSymbolIds(analyzer.symbol_ids.items);
    transformer.symbols = analyzer.symbols.items;
    transformer.class_self_symbol_map = analyzer.class_self_symbol_map;
    transformer.references = analyzer.references.items;
    transformer.scopes = analyzer.scopes.items;
    transformer.scope_maps = analyzer.scope_maps.items;
    transformer.scope_owner_map = analyzer.scope_owner_map;
    transformer.semantic_edit_enabled = true;
    transformer.current_scope = @fromBackingInt(@intCast(loop_scope));
    // Model generator operation collection: the wrapper binding identity is
    // known, but references must wait for their final output ScopeIds.
    transformer.state_machine_depth = 1;
    const lowering = @import("es2015_for_of.zig").ES2015ForOf(Transformer);
    _ = try lowering.rewriteForIn(&transformer, loop, parser.ast.getNode(loop));

    const expected_names = [_][]const u8{ "_c", "_d", "_keys2", "_idx2" };
    var binding_ids: [expected_names.len]?u32 = @splat(null);
    var reference_counts: [expected_names.len]usize = @splat(0);
    for (transformer.ast.nodes.items[transformer.parser_node_count..], transformer.parser_node_count..) |node, raw| {
        if (node.tag != .binding_identifier) continue;
        const name = transformer.ast.getText(node.data.string_ref);
        for (expected_names, 0..) |expected_name, expected_index| {
            if (!std.mem.eql(u8, name, expected_name)) continue;
            try std.testing.expect(binding_ids[expected_index] == null);
            const symbol_id = if (raw < transformer.symbol_ids.items.len) transformer.symbol_ids.items[raw] else null;
            binding_ids[expected_index] = symbol_id orelse return error.MissingGeneratedTempSymbol;
        }
    }
    for (binding_ids) |symbol_id| try std.testing.expect(symbol_id != null);

    for (transformer.ast.nodes.items[transformer.parser_node_count..], transformer.parser_node_count..) |node, raw| {
        if (node.tag != .identifier_reference) continue;
        const name = transformer.ast.getText(node.data.string_ref);
        for (expected_names, 0..) |expected_name, expected_index| {
            if (!std.mem.eql(u8, name, expected_name)) continue;
            const exact_id = transformer.exact_output_ref_symbol_ids.get(@intCast(raw)) orelse
                return error.MissingDeferredSyntheticTempReference;
            try std.testing.expectEqual(binding_ids[expected_index].?, exact_id);
            reference_counts[expected_index] += 1;
        }
    }
    for (reference_counts) |count| try std.testing.expect(count > 0);
    try std.testing.expectEqual(@as(usize, 0), transformer.pending_temp_ref_chains.count());
}

test "#4819 generator for-await temporaries bind exact symbols during lowering" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const NodeIndex = @import("../parser/ast.zig").NodeIndex;
    const source = "const _a = 0, _b = 0, _step = 0, _ret = 0, _errObj = 0; async function drain(source) { for await (const value of source) use(value); }";
    var scanner = try Scanner.init(allocator, source);
    var parser = Parser.init(allocator, &scanner);
    parser.configureFromExtension(".mjs");
    _ = try parser.parse();
    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    analyzer.is_module = true;
    try analyzer.analyze();
    var source_loop: ?NodeIndex = null;
    for (parser.ast.nodes.items, 0..) |node, index| {
        if (node.tag == .for_await_of_statement) source_loop = @fromBackingInt(@intCast(index));
    }
    const loop = source_loop orelse return error.MissingForAwaitLoop;
    const loop_scope = analyzer.scope_owner_map.get(@backingInt(loop)) orelse return error.MissingForAwaitScope;

    var transformer = try Transformer.init(allocator, &parser.ast, .{});
    try transformer.initSymbolIds(analyzer.symbol_ids.items);
    transformer.symbols = analyzer.symbols.items;
    transformer.class_self_symbol_map = analyzer.class_self_symbol_map;
    transformer.references = analyzer.references.items;
    transformer.scopes = analyzer.scopes.items;
    transformer.scope_maps = analyzer.scope_maps.items;
    transformer.scope_owner_map = analyzer.scope_owner_map;
    transformer.semantic_edit_enabled = true;
    transformer.current_scope = @fromBackingInt(@intCast(loop_scope));
    transformer.state_machine_depth = 1;
    transformer.generator_state_machine_scope = transformer.nearestVarScope(transformer.current_scope);

    const lowering = @import("es2018_for_await.zig").ES2018ForAwait(Transformer);
    _ = try lowering.rewriteForAwait(&transformer, loop, parser.ast.getNode(loop), .none, false, true);
    try std.testing.expectEqual(@as(usize, 4), transformer.generator_temp_var_spans.items.len);

    var binding_ids: [4]?u32 = @splat(null);
    var ref_counts: [4]usize = @splat(0);
    for (transformer.generator_temp_var_spans.items, 0..) |temp_span, temp_index| {
        const temp_name = transformer.ast.getText(temp_span);
        for (transformer.ast.nodes.items[transformer.parser_node_count..], transformer.parser_node_count..) |node, raw| {
            if (node.tag != .binding_identifier or !std.mem.eql(u8, transformer.ast.getText(node.data.string_ref), temp_name)) continue;
            try std.testing.expect(binding_ids[temp_index] == null);
            const id = if (raw < transformer.symbol_ids.items.len) transformer.symbol_ids.items[raw] else null;
            binding_ids[temp_index] = id orelse return error.MissingGeneratedForAwaitTempSymbol;
        }
        const recorded_id = transformer.generator_state_temp_symbols.get(temp_span.start) orelse return error.MissingRecordedForAwaitTempSymbol;
        try std.testing.expectEqual(binding_ids[temp_index] orelse return error.MissingGeneratedForAwaitTempSymbol, recorded_id);
    }

    for (transformer.ast.nodes.items[transformer.parser_node_count..], transformer.parser_node_count..) |node, raw| {
        if (node.tag != .identifier_reference) continue;
        const ref_name = transformer.ast.getText(node.data.string_ref);
        for (transformer.generator_temp_var_spans.items, 0..) |temp_span, temp_index| {
            if (!std.mem.eql(u8, ref_name, transformer.ast.getText(temp_span))) continue;
            const exact_id = transformer.exact_output_ref_symbol_ids.get(@intCast(raw)) orelse
                return error.MissingDeferredSyntheticTempReference;
            try std.testing.expectEqual(binding_ids[temp_index] orelse return error.MissingGeneratedForAwaitTempSymbol, exact_id);
            ref_counts[temp_index] += 1;
        }
    }
    for (ref_counts) |count| try std.testing.expect(count > 0);
    try std.testing.expectEqual(@as(usize, 0), transformer.pending_temp_ref_chains.count());
}

test "#4819 generator for-of temporaries bind symbols during lowering" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const NodeIndex = @import("../parser/ast.zig").NodeIndex;
    const source = "const _err = 'outer'; for (const value of source) use(value); use(_err);";
    var scanner = try Scanner.init(allocator, source);
    var parser = Parser.init(allocator, &scanner);
    parser.configureFromExtension(".mjs");
    _ = try parser.parse();
    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    analyzer.is_module = true;
    try analyzer.analyze();
    var source_err_id: ?u32 = null;
    for (analyzer.symbols.items, 0..) |symbol, id| {
        if (symbol.kind == .variable_const and std.mem.eql(u8, symbol.nameText(parser.ast.source), "_err")) {
            source_err_id = @intCast(id);
        }
    }
    const outer_err_id = source_err_id orelse return error.MissingOuterErrSymbol;
    var source_loop: ?NodeIndex = null;
    for (parser.ast.nodes.items, 0..) |node, index| {
        if (node.tag == .for_of_statement) source_loop = @fromBackingInt(@intCast(index));
    }
    const loop = source_loop orelse return error.MissingForOfLoop;
    const loop_scope = analyzer.scope_owner_map.get(@backingInt(loop)) orelse return error.MissingForOfScope;

    var transformer = try Transformer.init(allocator, &parser.ast, .{});
    try transformer.initSymbolIds(analyzer.symbol_ids.items);
    transformer.symbols = analyzer.symbols.items;
    transformer.class_self_symbol_map = analyzer.class_self_symbol_map;
    transformer.references = analyzer.references.items;
    transformer.scopes = analyzer.scopes.items;
    transformer.scope_maps = analyzer.scope_maps.items;
    transformer.scope_owner_map = analyzer.scope_owner_map;
    transformer.semantic_edit_enabled = true;
    transformer.current_scope = @fromBackingInt(@intCast(loop_scope));
    transformer.state_machine_depth = 1;
    const lowering = @import("es2015_for_of.zig").ES2015ForOf(Transformer);
    _ = try lowering.rewriteForOf(&transformer, loop, parser.ast.getNode(loop), .none, true);
    try std.testing.expectEqual(@as(usize, 5), transformer.generator_temp_var_spans.items.len);

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

    var catch_binding: ?NodeIndex = null;
    var catch_clause_raw: ?u32 = null;
    for (transformer.ast.nodes.items[transformer.parser_node_count..], transformer.parser_node_count..) |node, raw| {
        if (node.tag != .catch_clause or node.data.binary.left.isNone()) continue;
        try std.testing.expect(catch_binding == null);
        catch_binding = node.data.binary.left;
        catch_clause_raw = @intCast(raw);
    }
    const binding = catch_binding orelse return error.MissingGeneratedForOfCatchBinding;
    const binding_raw = @backingInt(binding);
    const catch_id = transformer.symbol_ids.items[binding_raw] orelse return error.MissingGeneratedForOfCatchSymbol;
    const catch_name = transformer.ast.getText(transformer.ast.getNode(binding).data.string_ref);
    try std.testing.expectEqualStrings("_err", catch_name);
    try std.testing.expect(catch_id != outer_err_id);
    for (transformer.generator_temp_var_spans.items) |temp_span| {
        try std.testing.expect(!std.mem.eql(u8, transformer.ast.getText(temp_span), catch_name));
    }

    const editor = &transformer.semantic_editor.?;
    const catch_symbol = editor.symbols.items[catch_id];
    const catch_scope = catch_symbol.scope_id;
    try std.testing.expectEqual(@import("../semantic/symbol.zig").SymbolKind.catch_binding, catch_symbol.kind);
    try std.testing.expectEqual(@import("../semantic/scope.zig").ScopeKind.catch_clause, editor.scopes.items[catch_scope.toIndex()].kind);
    try std.testing.expectEqual(@as(?u32, @backingInt(catch_scope)), editor.scope_owner_map.get(catch_clause_raw.?));
    try std.testing.expectEqual(@as(?usize, catch_id), editor.scope_maps.items[catch_scope.toIndex()].get(catch_name));
    var catch_reads: usize = 0;
    var outer_reads: usize = 0;
    for (editor.references.items) |reference| {
        if (reference.flags.declare or !reference.flags.read) continue;
        const symbol_id = @backingInt(reference.symbol_id);
        const reference_raw = @backingInt(reference.node_index);
        if (symbol_id == catch_id) {
            catch_reads += 1;
            try std.testing.expectEqual(catch_scope, reference.scope_id);
            try std.testing.expectEqual(@as(?u32, catch_id), transformer.symbol_ids.items[reference_raw]);
        }
        if (symbol_id == outer_err_id) {
            outer_reads += 1;
            try std.testing.expectEqual(@as(?u32, outer_err_id), transformer.symbol_ids.items[reference_raw]);
            try std.testing.expect(reference.scope_id != catch_scope);
        }
    }
    try std.testing.expectEqual(@as(usize, 1), catch_reads);
    try std.testing.expectEqual(@as(usize, 1), outer_reads);
}

fn checkStandaloneForOfTempFinalization(source: []const u8, expect_late_names: bool) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const NodeIndex = @import("../parser/ast.zig").NodeIndex;
    var scanner = try Scanner.init(allocator, source);
    var parser = Parser.init(allocator, &scanner);
    parser.configureFromExtension(".mjs");
    _ = try parser.parse();
    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    analyzer.is_module = true;
    try analyzer.analyze();
    const original_symbols = analyzer.symbols.items.len;
    var source_loop: ?NodeIndex = null;
    for (parser.ast.nodes.items, 0..) |node, raw| {
        if (node.tag == .for_of_statement) source_loop = @fromBackingInt(@intCast(raw));
    }
    const loop = source_loop orelse return error.MissingForOfLoop;
    const loop_scope_raw = analyzer.scope_owner_map.get(@backingInt(loop)) orelse return error.MissingForOfScope;
    const loop_scope: ScopeId = @fromBackingInt(@intCast(loop_scope_raw));

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
    transformer.unresolved_references = &analyzer.unresolved_references;
    transformer.semantic_edit_enabled = true;
    const expected_temp_scope = transformer.nearestVarScope(loop_scope);

    _ = try transformer.transform();
    const edited = (try transformer.finishSemanticEdit()).?;
    var temp_count: usize = 0;
    for (edited.symbols.items[original_symbols..], original_symbols..) |symbol, id| {
        const name = symbol.synthetic_name;
        if (symbol.kind != SymbolKind.variable_var or name.len != 2 or name[0] != '_' or name[1] < 'a' or name[1] > 'z') continue;
        try std.testing.expectEqual(expected_temp_scope, symbol.scope_id);
        try std.testing.expectEqual(expect_late_names, symbol.synthetic_kind == SyntheticKind.standalone_temp_binding);
        try std.testing.expectEqual(@as(?usize, id), edited.scope_maps[symbol.scope_id.toIndex()].get(name));

        var binding_count: usize = 0;
        for (transformer.ast.nodes.items, 0..) |node, raw| {
            if (node.tag != .binding_identifier or raw >= edited.symbol_ids.len) continue;
            if (edited.symbol_ids[raw] == @as(?u32, @intCast(id))) binding_count += 1;
        }
        try std.testing.expectEqual(@as(usize, 1), binding_count);
        var reference_count: usize = 0;
        for (edited.references) |reference| {
            if (@backingInt(reference.symbol_id) != id or reference.node_index.isNone()) continue;
            try std.testing.expectEqual(@as(?u32, @intCast(id)), edited.symbol_ids[@backingInt(reference.node_index)]);
            reference_count += 1;
        }
        try std.testing.expect(reference_count > 0);
        temp_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 4), temp_count);
}

test "#4819 standalone for-of temps finalize by exact IDs outside dynamic scopes" {
    try checkStandaloneForOfTempFinalization(
        "for (const value of source) use(value);",
        true,
    );
    try checkStandaloneForOfTempFinalization(
        "eval(''); for (const value of source) use(value);",
        false,
    );
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
        .defer_runtime_helper_name_resolution = true,
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
    var producer_symbol_ids: [2]u32 = undefined;
    var producer_symbol_count: usize = 0;
    for (transformer.ast.nodes.items) |node| {
        if (node.tag != .catch_clause) continue;
        const param = node.data.binary.left;
        if (param.isNone() or @backingInt(param) < transformer.parser_node_count or
            transformer.ast.getNode(param).tag != .binding_identifier) continue;
        if (producer_symbol_count == producer_symbol_ids.len) return error.UnexpectedGeneratedCatchBinding;
        const symbol_id = transformer.getSymbolIdAt(param) orelse return error.MissingProducerCatchBindingSymbolId;
        try std.testing.expect(@as(usize, @intCast(symbol_id)) >= original_symbols);
        for (producer_symbol_ids[0..producer_symbol_count]) |prior_id| {
            try std.testing.expect(symbol_id != prior_id);
        }
        producer_symbol_ids[producer_symbol_count] = symbol_id;
        producer_symbol_count += 1;
    }
    try std.testing.expectEqual(producer_symbol_ids.len, producer_symbol_count);
    const edited = (try transformer.finishSemanticEdit()).?;
    try std.testing.expectEqual(original_symbols + 2, edited.symbols.items.len);
    try std.testing.expect(edited.symbols.items[original_symbols].scope_id != edited.symbols.items[original_symbols + 1].scope_id);
    for (edited.symbols.items[original_symbols..]) |generated| {
        try std.testing.expectEqual(@import("../semantic/symbol.zig").SymbolKind.catch_binding, generated.kind);
        try std.testing.expectEqual(
            @import("../semantic/symbol.zig").SyntheticKind.optional_catch_binding,
            generated.synthetic_kind.?,
        );
        try std.testing.expectEqual(@import("../semantic/scope.zig").ScopeKind.catch_clause, edited.scopes[generated.scope_id.toIndex()].kind);
        try std.testing.expectEqualStrings("_unused", transformer.ast.getText(generated.name));
        try std.testing.expectEqual(@as(u32, 0), generated.reference_count);
    }
    var outer_b_reads: usize = 0;
    for (edited.references) |reference| {
        if (@backingInt(reference.symbol_id) == (outer_b_id orelse return error.TestUnexpectedResult) and reference.flags.read) outer_b_reads += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), outer_b_reads);
    var bindings: usize = 0;
    for (edited.symbol_ids, 0..) |maybe_id, i| {
        if (maybe_id != null and maybe_id.? >= original_symbols and transformer.ast.nodes.items[i].tag == .binding_identifier) bindings += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), bindings);
}

test "#4819 for-await error catch binds its generated reference by exact symbol and scope" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var scanner = try Scanner.init(allocator,
        \\const _err = "outer";
        \\async function run(iterable) {
        \\  try { for await (const value of iterable) { void value; } }
        \\  catch (caught) { console.log(`${_err}:${caught.message}`); }
        \\}
    );
    var parser = Parser.init(allocator, &scanner);
    parser.configureFromExtension(".mjs");
    _ = try parser.parse();
    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    analyzer.is_module = true;
    try analyzer.analyze();

    const original_symbols = analyzer.symbols.items.len;
    var outer_id: ?u32 = null;
    for (analyzer.symbols.items, 0..) |symbol, id| {
        if (symbol.kind == .variable_const and std.mem.eql(u8, symbol.nameText(parser.ast.source), "_err")) {
            outer_id = @intCast(id);
        }
    }
    const source_outer_id = outer_id orelse return error.MissingOuterErrSymbol;

    var transformer = try Transformer.init(allocator, &parser.ast, .{
        .unsupported = TransformOptions.compat.fromESTarget(.es2017),
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

    var generated_catch_id: ?u32 = null;
    for (edited.symbols.items[original_symbols..], original_symbols..) |symbol, id| {
        if (symbol.kind != .catch_binding or !std.mem.eql(u8, transformer.ast.getText(symbol.name), "_err")) continue;
        try std.testing.expect(generated_catch_id == null);
        generated_catch_id = @intCast(id);
    }
    const catch_id = generated_catch_id orelse return error.MissingGeneratedErrSymbol;
    try std.testing.expect(catch_id != source_outer_id);

    const catch_symbol = edited.symbols.items[catch_id];
    const catch_scope = catch_symbol.scope_id;
    try std.testing.expectEqual(@import("../semantic/scope.zig").ScopeKind.catch_clause, edited.scopes[catch_scope.toIndex()].kind);
    try std.testing.expectEqual(@as(u32, 1), catch_symbol.reference_count);
    try std.testing.expectEqual(@as(?usize, @intCast(catch_id)), edited.scope_maps[catch_scope.toIndex()].get("_err"));

    const reachable = try @import("../parser/ast_walk.zig").collectReachableNodeIndices(allocator, transformer.ast);
    var catch_bindings: usize = 0;
    var catch_clauses: usize = 0;
    for (reachable) |raw| {
        if (edited.symbol_ids[raw] != catch_id) continue;
        if (transformer.ast.nodes.items[raw].tag == .binding_identifier) catch_bindings += 1;
    }
    for (reachable) |raw| {
        const node = transformer.ast.nodes.items[raw];
        if (node.tag != .catch_clause or node.data.binary.left.isNone()) continue;
        const binding_raw = @backingInt(node.data.binary.left);
        if (edited.symbol_ids[binding_raw] != catch_id) continue;
        catch_clauses += 1;
        try std.testing.expectEqual(@as(?u32, @backingInt(catch_scope)), edited.scope_owner_map.get(raw));
    }
    try std.testing.expectEqual(@as(usize, 1), catch_bindings);
    try std.testing.expectEqual(@as(usize, 1), catch_clauses);

    var generated_reads: usize = 0;
    var source_reads: usize = 0;
    for (edited.references) |reference| {
        if (reference.flags.declare or !reference.flags.read) continue;
        const symbol_id = @backingInt(reference.symbol_id);
        const reference_raw = @backingInt(reference.node_index);
        if (symbol_id == catch_id) {
            generated_reads += 1;
            try std.testing.expectEqual(@as(?u32, catch_id), edited.symbol_ids[reference_raw]);
            try std.testing.expectEqual(@import("../parser/ast.zig").Node.Tag.identifier_reference, transformer.ast.nodes.items[reference_raw].tag);
            try std.testing.expectEqualStrings("_err", transformer.ast.getText(transformer.ast.nodes.items[reference_raw].data.string_ref));
            try std.testing.expect(scopeHasAncestor(edited.scopes, reference.scope_id, catch_scope));
        }
        if (symbol_id == source_outer_id) {
            source_reads += 1;
            try std.testing.expectEqual(@as(?u32, source_outer_id), edited.symbol_ids[reference_raw]);
            try std.testing.expectEqualStrings("_err", transformer.ast.getText(transformer.ast.nodes.items[reference_raw].data.string_ref));
            try std.testing.expect(reference.scope_id != catch_scope);
        }
    }
    try std.testing.expectEqual(@as(usize, 1), generated_reads);
    try std.testing.expectEqual(@as(usize, 1), source_reads);
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
        source_loop_scope = @fromBackingInt(@intCast(analyzer.scope_owner_map.get(@intCast(raw)) orelse return error.TestUnexpectedResult));
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
        if (@backingInt(ref.symbol_id) != id or ref.flags.declare) continue;
        try std.testing.expect(ref.flags.read);
        try std.testing.expectEqual(@as(?u32, id), edited.symbol_ids[@backingInt(ref.node_index)]);
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
                if (@backingInt(ref.node_index) != raw or @backingInt(ref.symbol_id) != step) continue;
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
                if (@backingInt(ref.node_index) != raw or @backingInt(ref.symbol_id) != completion) continue;
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
        if (edited.scope_owner_map.get(raw) == @backingInt(catch_scope)) live_catch_owners += 1;
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
            if (@backingInt(ref.symbol_id) != temp or ref.flags.declare) continue;
            try std.testing.expectEqual(@as(?u32, temp), edited.symbol_ids[@backingInt(ref.node_index)]);
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
        if (@backingInt(ref.symbol_id) != catch_parameter or ref.flags.declare) continue;
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
            source_scope = @fromBackingInt(@intCast(analyzer.scope_owner_map.get(@intCast(raw)) orelse return error.TestUnexpectedResult));
    }
    const loop_scope = source_scope orelse return error.TestUnexpectedResult;
    const var_scope = analyzer.scopes.items[loop_scope.toIndex()].parent;
    const original_symbols = analyzer.symbols.items.len;

    var transformer = try Transformer.init(allocator, &parser.ast, .{
        .unsupported = TransformOptions.compat.fromESTarget(.es5),
        .defer_runtime_helper_name_resolution = true,
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

    var head_id: ?u32 = null;
    for (edited.symbols.items[original_symbols..], original_symbols..) |symbol, id| {
        if (std.mem.eql(u8, transformer.ast.getText(symbol.name), "_using2")) head_id = @intCast(id);
    }
    const id = head_id orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(var_scope, edited.symbols.items[id].scope_id);
    try std.testing.expectEqual(@import("../semantic/scope.zig").ScopeKind.function, edited.scopes[var_scope.toIndex()].kind);
    try std.testing.expectEqual(@import("../semantic/symbol.zig").SymbolKind.variable_const, edited.symbols.items[id].kind);
    try std.testing.expectEqual(@as(?SyntheticKind, .standalone_temp_binding), edited.symbols.items[id].synthetic_kind);
    try std.testing.expectEqual(@as(u32, 1), edited.symbols.items[id].reference_count);
    var bindings: usize = 0;
    var reads: usize = 0;
    for (edited.symbol_ids, 0..) |maybe_id, raw| {
        if (maybe_id != @as(?u32, @intCast(id))) continue;
        const tag = transformer.ast.nodes.items[raw].tag;
        if (tag == .binding_identifier) bindings += 1;
        if (tag == .identifier_reference) reads += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), bindings);
    try std.testing.expectEqual(@as(usize, 1), reads);
    for (edited.references) |ref| {
        if (@backingInt(ref.symbol_id) != id or ref.flags.declare) continue;
        try std.testing.expect(scopeHasAncestor(edited.scopes, ref.scope_id, loop_scope));
        try std.testing.expect(ref.flags.read);
    }
}

test "#4819 for-of using head keeps its staging name when descendant eval can observe it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var scanner = try Scanner.init(allocator,
        \\export function consume(resources, suffix) {
        \\  for (using item of resources) { eval("_" + suffix); globalThis.item = item; }
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
        .defer_runtime_helper_name_resolution = true,
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

    var head_id: ?usize = null;
    for (edited.symbols.items[original_symbols..], original_symbols..) |symbol, id| {
        if (symbol.kind != .variable_const or !std.mem.startsWith(u8, symbol.synthetic_name, "_using")) continue;
        try std.testing.expect(head_id == null);
        head_id = id;
    }
    const id = head_id orelse return error.TestUnexpectedResult;
    const symbol = edited.symbols.items[id];
    try std.testing.expectEqual(@as(?SyntheticKind, null), symbol.synthetic_kind);
    try std.testing.expectEqual(@as(?usize, id), edited.scope_maps[symbol.scope_id.toIndex()].get(symbol.synthetic_name));
    var bindings: usize = 0;
    var reads: usize = 0;
    for (edited.symbol_ids, 0..) |maybe_id, raw| {
        if (maybe_id != @as(?u32, @intCast(id))) continue;
        switch (transformer.ast.nodes.items[raw].tag) {
            .binding_identifier => bindings += 1,
            .identifier_reference => reads += 1,
            else => {},
        }
    }
    try std.testing.expectEqual(@as(usize, 1), bindings);
    try std.testing.expectEqual(@as(usize, 1), reads);
}

test "#4819 downlevel using lowering preserves exact transform identities" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    // Async-using temps receive their exact var owner before generator hoisting
    // sees the same binding nodes. Keep the ID and owner stable across that handoff.
    const source = "function run(resource: any, _stack: any, _error: any, _hasError: any, _: any, __using: any, __callDispose: any) { " ++
        "using local = resource; return local + _stack; } " ++
        "async function wait(resource: any, _stack3: any, _error3: any, _hasError3: any) { " ++
        "await using asyncLocal = resource; { await using nestedLocal = resource; " ++
        "await Promise.resolve(nestedLocal); } return asyncLocal; } " ++
        "async function nestedMachine(resource: any) { async function inner() { " ++
        "await using nestedInner = resource; await Promise.resolve(nestedInner); } " ++
        "await Promise.resolve(); return inner; } " ++
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

test "#4819 generated default-export reference keeps its exact allocated name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var scanner = try Scanner.init(allocator,
        \\const _default = 1;
        \\using handle = open();
        \\export default 2;
    );
    var parser = Parser.init(allocator, &scanner);
    parser.configureFromExtension(".mjs");
    _ = try parser.parse();
    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    analyzer.is_module = true;
    try analyzer.analyze();
    const original_symbols = analyzer.symbols.items.len;

    var transformer = try Transformer.init(allocator, &parser.ast, .{
        .unsupported = TransformOptions.compat.fromESTarget(.es2022),
    });
    try transformer.initSymbolIds(analyzer.symbol_ids.items);
    transformer.symbols = analyzer.symbols.items;
    transformer.class_self_symbol_map = analyzer.class_self_symbol_map;
    transformer.references = analyzer.references.items;
    transformer.scopes = analyzer.scopes.items;
    transformer.scope_maps = analyzer.scope_maps.items;
    transformer.scope_owner_map = analyzer.scope_owner_map;
    transformer.semantic_edit_enabled = true;

    // uniqueSourceName intentionally selects _default2 because that spelling is
    // absent from source text. Simulate an earlier generated owner reserving it:
    // an identity-known reference must still use the binding's exact spelling.
    try transformer.synthetic_taken.put(allocator, "_default2", {});
    _ = try transformer.transform();
    const edited = (try transformer.finishSemanticEdit()).?;

    var local_ref: ?AstNodeIndex = null;
    for (transformer.ast.nodes.items) |node| {
        if (node.tag != .export_specifier) continue;
        const candidate = node.data.binary.left;
        if (candidate.isNone()) continue;
        if (transformer.ast.getNode(candidate).tag == .identifier_reference) {
            local_ref = candidate;
            break;
        }
    }
    const reference_node = local_ref orelse return error.TestUnexpectedResult;
    const reference_name = transformer.ast.getText(transformer.ast.getNode(reference_node).data.string_ref);
    try std.testing.expectEqualStrings("_default22", reference_name);

    const raw_symbol_id = edited.symbol_ids[@backingInt(reference_node)] orelse return error.TestUnexpectedResult;
    const symbol_id: SymbolId = @fromBackingInt(@intCast(raw_symbol_id));
    const symbol = edited.symbols.items[raw_symbol_id];
    try std.testing.expectEqualStrings("_default22", transformer.ast.getText(symbol.name));
    try std.testing.expectEqual(transformer.programScope(), symbol.scope_id);
    try std.testing.expect(raw_symbol_id >= original_symbols);

    var matched_reference = false;
    for (edited.references) |reference| {
        if (reference.node_index != reference_node) continue;
        try std.testing.expectEqual(symbol_id, reference.symbol_id);
        try std.testing.expectEqual(transformer.programScope(), reference.scope_id);
        try std.testing.expect(reference.flags.read);
        matched_reference = true;
    }
    try std.testing.expect(matched_reference);
}

test "#4819 SymbolId reference helper ignores resolver reservations for its exact name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var scanner = try Scanner.init(allocator,
        \\const _default = 1;
    );
    var parser = Parser.init(allocator, &scanner);
    parser.configureFromExtension(".mjs");
    _ = try parser.parse();
    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    analyzer.is_module = true;
    try analyzer.analyze();

    var transformer = try Transformer.init(allocator, &parser.ast, .{});
    try transformer.initSymbolIds(analyzer.symbol_ids.items);
    transformer.symbols = analyzer.symbols.items;
    transformer.class_self_symbol_map = analyzer.class_self_symbol_map;
    transformer.references = analyzer.references.items;
    transformer.scopes = analyzer.scopes.items;
    transformer.scope_maps = analyzer.scope_maps.items;
    transformer.scope_owner_map = analyzer.scope_owner_map;
    transformer.semantic_edit_enabled = true;
    const scope = transformer.programScope();
    transformer.current_scope = scope;

    // The binding resolver chooses _default22 because a previous generated
    // owner reserved _default2. Then reserve the selected spelling too: a
    // string-based second resolution would incorrectly change it to _default222.
    try transformer.synthetic_taken.put(allocator, "_default2", {});
    const binding_span = try transformer.ast.addString("_default2");
    const binding = try @import("es_helpers.zig").makeSyntheticBinding(&transformer, binding_span);
    const symbol_id = (try transformer.declareSyntheticInScope(
        binding,
        transformer.ast.getNode(binding).span,
        .variable_var,
        scope,
    )) orelse return error.TestUnexpectedResult;
    const raw_symbol_id = @backingInt(symbol_id);
    const editor = transformer.semantic_editor orelse return error.TestUnexpectedResult;
    const selected_name_span = editor.symbols.items[raw_symbol_id].name;
    const selected_name = transformer.ast.getText(selected_name_span);
    try std.testing.expectEqualStrings("_default22", selected_name);
    try transformer.synthetic_taken.put(allocator, selected_name, {});

    const reference_node = try transformer.makeSyntheticRefForSymbol(symbol_id, scope, .{ .read = true });
    try std.testing.expectEqualStrings(
        selected_name,
        transformer.ast.getText(transformer.ast.getNode(reference_node).data.string_ref),
    );
    try std.testing.expectEqual(@as(?u32, raw_symbol_id), transformer.getSymbolIdAt(reference_node));

    var matched_reference = false;
    for (transformer.semantic_editor.?.references.items) |reference| {
        if (reference.node_index != reference_node) continue;
        try std.testing.expectEqual(symbol_id, reference.symbol_id);
        try std.testing.expectEqual(scope, reference.scope_id);
        try std.testing.expect(reference.flags.read);
        matched_reference = true;
    }
    try std.testing.expect(matched_reference);
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

test "#4819 private field helper references retain their producer SymbolIds" {
    const source =
        \\class Fields {
        \\  #value = 1;
        \\  static #count = 2;
        \\  static { this.#count += 1; }
        \\  read() { return this.#value; }
        \\  write(next) { this.#value = next; return this.#value; }
        \\  has(other) { return #value in other; }
        \\  static read() { return this.#count; }
        \\  static write(next) { this.#count = next; return this.#count; }
        \\}
        \\new Fields().read();
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
        const original_symbol_count = analyzer.symbols.items.len;

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

        if (target == .es2015) {
            const outer_class_id: u32 = @intCast(analyzer.scope_maps.items[0].get("Fields") orelse return error.TestUnexpectedResult);
            var static_block_class_refs: usize = 0;
            for (edited.references) |reference| {
                if (reference.node_index.isNone()) continue;
                const node = transformer.ast.getNode(reference.node_index);
                if (node.tag != .identifier_reference or !std.mem.eql(u8, transformer.ast.getText(node.data.string_ref), "Fields")) continue;
                if (edited.scopes[reference.scope_id.toIndex()].kind != .block) continue;
                try std.testing.expectEqual(outer_class_id, @backingInt(reference.symbol_id));
                static_block_class_refs += 1;
            }
            try std.testing.expect(static_block_class_refs > 0);
        }

        const helper_names = [_][]const u8{ "_value", "_count" };
        const nodes = try @import("../parser/ast_walk.zig").collectReachableNodeIndices(allocator, transformer.ast);
        for (helper_names) |helper_name| {
            var helper_id: ?usize = null;
            for (edited.symbols.items[original_symbol_count..], original_symbol_count..) |symbol, id| {
                if (std.mem.eql(u8, transformer.ast.getText(symbol.name), helper_name)) helper_id = id;
            }
            const id = helper_id orelse return error.TestUnexpectedResult;
            const symbol = edited.symbols.items[id];
            try std.testing.expect(symbol.scope_id.toIndex() < edited.scopes.len);
            var bindings: usize = 0;
            var references: usize = 0;
            for (nodes) |raw| {
                const node = transformer.ast.nodes.items[raw];
                if (node.tag != .binding_identifier and node.tag != .identifier_reference and node.tag != .assignment_target_identifier)
                    continue;
                if (!std.mem.eql(u8, transformer.ast.getText(node.data.string_ref), helper_name)) continue;
                try std.testing.expectEqual(@as(?u32, @intCast(id)), edited.symbol_ids[raw]);
                if (node.tag == .binding_identifier) {
                    bindings += 1;
                    continue;
                }

                var rows: usize = 0;
                for (edited.references) |ref| {
                    if (ref.node_index.isNone() or @backingInt(ref.node_index) != raw) continue;
                    try std.testing.expectEqual(@as(u32, @intCast(id)), @backingInt(ref.symbol_id));
                    try std.testing.expect(scopeHasAncestor(edited.scopes, ref.scope_id, symbol.scope_id));
                    rows += 1;
                }
                try std.testing.expectEqual(@as(usize, 1), rows);
                references += 1;
            }
            try std.testing.expect(bindings > 0);
            try std.testing.expect(references > 0);
        }
    }
}

test "#4819 private method helpers retain their producer SymbolIds" {
    const source =
        \\class Methods {
        \\  #guard() { return 1; }
        \\  #read() { return this.#guard(); }
        \\  get #entry() { return this.#guard(); }
        \\  set #entry(value) { this.#guard(); }
        \\  has(other) { return #guard in other; }
        \\  static #staticGate() { return 3; }
        \\  static readStatic() { return Methods.#staticGate(); }
        \\  read() { return this.#read() + this.#entry; }
        \\  write(next) { this.#entry = next; }
        \\}
        \\new Methods().read();
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
        const original_symbol_count = analyzer.symbols.items.len;

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
        const nodes = try @import("../parser/ast_walk.zig").collectReachableNodeIndices(allocator, transformer.ast);

        const helper_names = [_][]const u8{
            "_guard",         "_read",    "_entry",     "_staticGate",
            "_guard_fn",      "_read_fn", "_entry_get", "_entry_set",
            "_staticGate_fn",
        };
        for (helper_names) |helper_name| {
            var helper_id: ?u32 = null;
            var bindings: usize = 0;
            var references: usize = 0;
            for (nodes) |raw| {
                const node = transformer.ast.nodes.items[raw];
                if (node.tag != .binding_identifier and node.tag != .identifier_reference and node.tag != .assignment_target_identifier)
                    continue;
                if (!std.mem.eql(u8, transformer.ast.getText(node.data.string_ref), helper_name)) continue;
                const sid = edited.symbol_ids[raw] orelse return error.TestUnexpectedResult;
                try std.testing.expect(sid >= original_symbol_count);
                if (helper_id) |expected| {
                    try std.testing.expectEqual(expected, sid);
                } else {
                    helper_id = sid;
                }
                if (node.tag == .binding_identifier) {
                    bindings += 1;
                    continue;
                }

                var rows: usize = 0;
                for (edited.references) |ref| {
                    if (ref.node_index.isNone() or @backingInt(ref.node_index) != raw) continue;
                    try std.testing.expectEqual(sid, @backingInt(ref.symbol_id));
                    const symbol = edited.symbols.items[sid];
                    try std.testing.expect(scopeHasAncestor(edited.scopes, ref.scope_id, symbol.scope_id));
                    rows += 1;
                }
                try std.testing.expectEqual(@as(usize, 1), rows);
                references += 1;
            }
            try std.testing.expect(helper_id != null);
            try std.testing.expectEqual(@as(usize, 1), bindings);
            try std.testing.expect(references > 0);
        }
    }
}

test "#4819 class-self captured private methods keep separate inner and outer function SymbolIds" {
    const source =
        \\class Methods {
        \\  #guard() { return Methods; }
        \\  #read() { return this.#guard(); }
        \\  read() { return this.#read(); }
        \\}
        \\new Methods().read();
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
        const original_symbol_count = analyzer.symbols.items.len;

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
        const nodes = try @import("../parser/ast_walk.zig").collectReachableNodeIndices(allocator, transformer.ast);

        var binding_ids: [2]?u32 = .{ null, null };
        var binding_count: usize = 0;
        var read_counts: [2]usize = .{ 0, 0 };
        var write_counts: [2]usize = .{ 0, 0 };
        for (nodes) |raw| {
            const node = transformer.ast.nodes.items[raw];
            if (node.tag != .binding_identifier) continue;
            if (!std.mem.eql(u8, transformer.ast.getText(node.data.string_ref), "_guard_fn")) continue;
            const sid = edited.symbol_ids[raw] orelse return error.TestUnexpectedResult;
            try std.testing.expect(sid >= original_symbol_count);
            if (binding_count >= binding_ids.len) return error.TestUnexpectedResult;
            binding_ids[binding_count] = sid;
            binding_count += 1;
        }
        try std.testing.expectEqual(@as(usize, 2), binding_count);
        try std.testing.expect(binding_ids[0] != null and binding_ids[1] != null);
        try std.testing.expect(binding_ids[0].? != binding_ids[1].?);

        for (nodes) |raw| {
            const node = transformer.ast.nodes.items[raw];
            if (node.tag != .identifier_reference and node.tag != .assignment_target_identifier) continue;
            if (!std.mem.eql(u8, transformer.ast.getText(node.data.string_ref), "_guard_fn")) continue;
            const sid = edited.symbol_ids[raw] orelse return error.TestUnexpectedResult;
            const binding_index: usize = if (sid == binding_ids[0].?)
                0
            else if (sid == binding_ids[1].?)
                1
            else
                return error.TestUnexpectedResult;
            var rows: usize = 0;
            for (edited.references) |ref| {
                if (ref.node_index.isNone() or @backingInt(ref.node_index) != raw) continue;
                try std.testing.expectEqual(sid, @backingInt(ref.symbol_id));
                const symbol = edited.symbols.items[sid];
                try std.testing.expect(scopeHasAncestor(edited.scopes, ref.scope_id, symbol.scope_id));
                if (ref.flags.read) read_counts[binding_index] += 1;
                if (ref.flags.write) write_counts[binding_index] += 1;
                rows += 1;
            }
            try std.testing.expectEqual(@as(usize, 1), rows);
        }

        const outer_index: usize = if (write_counts[0] > 0) 0 else 1;
        const inner_index = 1 - outer_index;
        try std.testing.expect(write_counts[outer_index] > 0);
        try std.testing.expectEqual(@as(usize, 0), write_counts[inner_index]);
        try std.testing.expect(read_counts[outer_index] > 0);
        try std.testing.expect(read_counts[inner_index] > 0);
    }
}

test "#4819 static private method extraction retains class-self capture from parameters" {
    const source =
        \\class Counter {
        \\  static #method(value = Counter) {
        \\    function nested() { return Counter; }
        \\    return [Counter, value, nested()];
        \\  }
        \\  static #evalClass() { return eval('Counter'); }
        \\  static #assignClass() { Counter = null; }
        \\  static #shadow(Counter) { function nested() { return Counter; } return [Counter, nested()]; }
        \\  static get #entry() { return Counter; }
        \\  static set #entry(value) { globalThis.observedClass = Counter; }
        \\  static run() { return this.#method(); }
        \\  static evalRun() { return this.#evalClass(); }
        \\  static assignRun() { return this.#assignClass(); }
        \\  static shadowRun() { return this.#shadow('parameter'); }
        \\  static read() { return this.#entry; }
        \\  static write() { this.#entry = 1; }
        \\}
        \\const Saved = Counter;
        \\Counter = null;
        \\Saved.run();
    ;

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
    transformer.semantic_edit_enabled = true;
    _ = try transformer.transform();
    _ = try transformer.finishSemanticEdit();
}

test "#4819 synthesized private accessors retain exact function and parameter scopes" {
    const source =
        \\class Accessors {
        \\  accessor #entry = 1;
        \\  read() { return this.#entry; }
        \\  write(next) { this.#entry = next; return this.#entry; }
        \\}
        \\new Accessors().read();
    ;
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
    transformer.semantic_edit_enabled = true;
    _ = try transformer.transform();
    const edited = (try transformer.finishSemanticEdit()).?;

    const nodes = try @import("../parser/ast_walk.zig").collectReachableNodeIndices(allocator, transformer.ast);
    const parents = try allocator.alloc(AstNodeIndex, transformer.ast.nodes.items.len);
    @memset(parents, .none);
    for (nodes) |parent_raw| {
        var children = @import("../parser/ast_walk.zig").children(transformer.ast, transformer.ast.nodes.items[parent_raw]);
        while (children.next()) |child| {
            if (!child.isNone()) parents[@backingInt(child)] = @fromBackingInt(@intCast(parent_raw));
        }
    }
    var getter_scope: ?ScopeId = null;
    var setter_scope: ?ScopeId = null;
    for (nodes) |raw| {
        const node = transformer.ast.nodes.items[raw];
        if (node.tag != .function_declaration) continue;
        const name_idx = transformer.readNodeIdx(node.data.extra, @import("../parser/ast.zig").FunctionExtra.name);
        if (name_idx.isNone()) continue;
        const name = transformer.ast.getText(transformer.ast.getNode(name_idx).data.string_ref);
        if (std.mem.eql(u8, name, "_entry_get")) {
            getter_scope = transformer.outputOwnedScope(@fromBackingInt(@intCast(raw))) orelse return error.TestUnexpectedResult;
        } else if (std.mem.eql(u8, name, "_entry_set")) {
            setter_scope = transformer.outputOwnedScope(@fromBackingInt(@intCast(raw))) orelse return error.TestUnexpectedResult;
        }
    }
    const get_scope = getter_scope orelse return error.TestUnexpectedResult;
    const set_scope = setter_scope orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@import("../semantic/scope.zig").ScopeKind.function, edited.scopes[get_scope.toIndex()].kind);
    try std.testing.expectEqual(@import("../semantic/scope.zig").ScopeKind.function, edited.scopes[set_scope.toIndex()].kind);

    var value_binding_count: usize = 0;
    var value_symbol: ?SymbolId = null;
    for (nodes) |raw| {
        const node = transformer.ast.nodes.items[raw];
        if (node.tag != .binding_identifier or !std.mem.eql(u8, transformer.ast.getText(node.data.string_ref), "value")) continue;
        value_binding_count += 1;
        value_symbol = @fromBackingInt(@intCast(edited.symbol_ids[raw] orelse return error.TestUnexpectedResult));
    }
    try std.testing.expectEqual(@as(usize, 1), value_binding_count);
    const value_id = value_symbol orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(set_scope, edited.symbols.items[@backingInt(value_id)].scope_id);

    var value_reference_count: usize = 0;
    for (nodes) |raw| {
        const node = transformer.ast.nodes.items[raw];
        if (node.tag != .identifier_reference or !std.mem.eql(u8, transformer.ast.getText(node.data.string_ref), "value")) continue;
        var ancestor = parents[raw];
        var in_setter_scope = false;
        while (!ancestor.isNone()) {
            if (transformer.outputOwnedScope(ancestor)) |scope| {
                if (scope == set_scope) {
                    in_setter_scope = true;
                    break;
                }
            }
            ancestor = parents[@backingInt(ancestor)];
        }
        if (!in_setter_scope) continue;
        try std.testing.expectEqual(@as(?u32, @backingInt(value_id)), edited.symbol_ids[raw]);
        var exact_rows: usize = 0;
        for (edited.references) |ref| {
            if (ref.node_index.isNone() or @backingInt(ref.node_index) != raw) continue;
            try std.testing.expectEqual(value_id, ref.symbol_id);
            try std.testing.expectEqual(set_scope, ref.scope_id);
            exact_rows += 1;
        }
        try std.testing.expectEqual(@as(usize, 1), exact_rows);
        value_reference_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), value_reference_count);
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
                if (@backingInt(ref.node_index) != raw) continue;
                try std.testing.expectEqual(symbol_id, @backingInt(ref.symbol_id));
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

fn checkPrivateForInTargetTemp(source: []const u8, expect_late_name: bool) !void {
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
    const original_symbol_count = analyzer.symbols.items.len;
    var expected_method_scope: ?u32 = null;
    for (parser.ast.nodes.items, 0..) |node, raw| {
        if (node.tag != .method_definition) continue;
        const key: AstNodeIndex = @fromBackingInt(@intCast(parser.ast.extra_data.items[node.data.extra + @import("../parser/ast.zig").MethodExtra.key]));
        if (!std.mem.eql(u8, parser.ast.getText(parser.ast.getNode(key).span), "run")) continue;
        expected_method_scope = analyzer.scope_owner_map.get(@intCast(raw));
    }
    const method_scope = expected_method_scope orelse return error.MissingMethodScope;
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
        try std.testing.expectEqual(method_scope, @backingInt(symbol.scope_id));
        try std.testing.expectEqual(expect_late_name, symbol.synthetic_kind == .standalone_temp_binding);
        try std.testing.expectEqual(@as(?usize, id), edited.scope_maps[symbol.scope_id.toIndex()].get(symbol.synthetic_name));
        var exact_refs: usize = 0;
        for (edited.references) |ref| {
            if (@backingInt(ref.symbol_id) != id or ref.node_index.isNone()) continue;
            try std.testing.expect(reachable.contains(@backingInt(ref.node_index)));
            try std.testing.expect(ref.flags.read);
            try std.testing.expect(!ref.flags.write);
            try std.testing.expectEqual(@as(?u32, @intCast(id)), edited.symbol_ids[@backingInt(ref.node_index)]);
            exact_refs += 1;
        }
        try std.testing.expectEqual(@as(usize, 1), exact_refs);
        var binding_count: usize = 0;
        for (transformer.ast.nodes.items, 0..) |node, raw| {
            if (node.tag != .binding_identifier or raw >= edited.symbol_ids.len) continue;
            if (edited.symbol_ids[raw] == @as(?u32, @intCast(id))) binding_count += 1;
        }
        try std.testing.expectEqual(@as(usize, 1), binding_count);
        temp_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), temp_count);
}

test "#4819 private for-in target temp uses exact var-owner scope and late-name gate" {
    try checkPrivateForInTargetTemp(
        "class Counter { static #method() {} static run() { { for (this.#method in {x: 1}) {} } } } Counter.run();",
        true,
    );
    try checkPrivateForInTargetTemp(
        "class Counter { static #method() {} static run() { eval(''); { for (this.#method in {x: 1}) {} } } } Counter.run();",
        false,
    );
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
    const member_extra = try ast.addExtras(&.{ @backingInt(local_read), @backingInt(static_key), 0 });
    const member = try ast.addExtraNode(.static_member_expression, storage, member_extra);
    const list = try ast.addNodeList(&.{ binding, member, global_read });
    const root = try ast.addNode(.{ .tag = .program, .span = storage, .data = .{ .list = list } });
    var marked: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer marked.deinit(allocator);
    try marked.put(allocator, @backingInt(binding), {});
    var unresolved: std.StringHashMapUnmanaged(void) = .empty;
    defer unresolved.deinit(allocator);
    // A name-only unresolved-global table cannot distinguish this generated
    // local read from an unrelated global with the same spelling.
    try unresolved.put(allocator, "_x", {});
    var scope_owner_map: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer scope_owner_map.deinit(allocator);
    var report = try coverage.checkStrict(allocator, &ast, root, 0, &.{}, &.{}, &.{}, &scope_owner_map, &.{}, &marked, &unresolved);
    defer report.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), report.counts[@backingInt(coverage.StrictStatus.missing_binding)]);
    try std.testing.expectEqual(@as(usize, 2), report.counts[@backingInt(coverage.StrictStatus.unclassified)]);
    try std.testing.expect(!report.hasCompleteExactCoverage());
    try std.testing.expectEqual(@as(usize, 1), report.marked_synthetic);
    try std.testing.expectEqual(@backingInt(binding), report.findings.items[0].node);
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
    missing_detail.counts[@backingInt(coverage.StrictStatus.bound)] = 1;
    // Conversely, a positive aggregate without a corresponding finding is
    // report drift and must not be accepted as exact coverage.
    try std.testing.expect(!missing_detail.hasCompleteExactCoverage());

    var hidden_orphan: coverage.StrictReport = .{};
    defer hidden_orphan.deinit(allocator);
    try hidden_orphan.orphan_symbol_findings.append(allocator, .{
        .symbol_id = 4,
        .name = "_orphan",
        .kind = .variable_var,
        .scope_id = @fromBackingInt(@intCast(0)),
    });
    try std.testing.expect(!hidden_orphan.hasCompleteExactCoverage());

    var marked_count_drift: coverage.StrictReport = .{};
    defer marked_count_drift.deinit(allocator);
    marked_count_drift.marked_synthetic = 1;
    try std.testing.expect(!marked_count_drift.hasCompleteExactCoverage());
}

test "strict symbol identity delegates only binding scope traces" {
    const allocator = std.testing.allocator;
    inline for (std.meta.tags(coverage.StrictStatus)) |status| {
        var report: coverage.StrictReport = .{};
        defer report.deinit(allocator);
        report.counts[@backingInt(status)] = 1;
        try report.findings.append(allocator, .{
            .node = 1,
            .name = "x",
            .tag = if (status == .scope_mismatch) .binding_identifier else .identifier_reference,
            .status = status,
            .marked_synthetic = false,
        });

        try std.testing.expect(report.isConsistent());
        const expected_complete = status == .bound or status == .external or status == .scope_mismatch;
        try std.testing.expectEqual(expected_complete, report.hasCompleteSymbolIdentity());
        try std.testing.expectEqual(status == .bound or status == .external, report.hasCompleteExactCoverage());
    }

    var bad_reference_scope: coverage.StrictReport = .{};
    defer bad_reference_scope.deinit(allocator);
    bad_reference_scope.counts[@backingInt(coverage.StrictStatus.scope_mismatch)] = 1;
    try bad_reference_scope.findings.append(allocator, .{
        .node = 2,
        .name = "x",
        .tag = .identifier_reference,
        .status = .scope_mismatch,
        .marked_synthetic = false,
    });
    try std.testing.expect(bad_reference_scope.isConsistent());
    try std.testing.expect(!bad_reference_scope.hasCompleteSymbolIdentity());
    try std.testing.expect(!bad_reference_scope.hasCompleteExactCoverage());
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
    const parser_node_count = @backingInt(copied_external);
    const exact_root = try ast.addListNode(.program, object_name, try ast.addNodeList(&.{ copied_external, explicit_global }));
    const mixed_root = try ast.addListNode(.program, object_name, try ast.addNodeList(&.{ copied_external, explicit_global, mismatched_origin, no_origin }));

    const global_scope: ScopeId = @fromBackingInt(@intCast(0));
    const scopes = [_]Scope{.{ .parent = .none, .kind = .global, .is_strict = false }};
    var owners: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer owners.deinit(allocator);
    try owners.put(allocator, @backingInt(exact_root), @backingInt(global_scope));
    try owners.put(allocator, @backingInt(mixed_root), @backingInt(global_scope));
    var unresolved_nodes: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer unresolved_nodes.deinit(allocator);
    try unresolved_nodes.put(allocator, @backingInt(source_ref), {});
    var explicit_globals: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer explicit_globals.deinit(allocator);
    try explicit_globals.put(allocator, @backingInt(explicit_global), {});
    var origins: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer origins.deinit(allocator);
    try origins.put(allocator, @backingInt(copied_external), @backingInt(source_ref));
    try origins.put(allocator, @backingInt(mismatched_origin), @backingInt(source_ref));
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
    try std.testing.expectEqual(@as(usize, 2), exact.counts[@backingInt(coverage.StrictStatus.external)]);
    try std.testing.expectEqual(@as(usize, 0), exact.counts[@backingInt(coverage.StrictStatus.unclassified)]);
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
    try std.testing.expectEqual(@as(usize, 2), mixed.counts[@backingInt(coverage.StrictStatus.external)]);
    try std.testing.expectEqual(@as(usize, 2), mixed.counts[@backingInt(coverage.StrictStatus.unclassified)]);
    try std.testing.expect(!mixed.hasCompleteExactCoverage());
}

test "strict inventory reports generated symbols with no reachable binding" {
    const allocator = std.testing.allocator;
    var ast = Ast.init(allocator, "");
    defer ast.deinit();
    const name = try ast.addString("_unused");
    const root = try ast.addNode(.{ .tag = .program, .span = name, .data = .{ .list = try ast.addNodeList(&.{}) } });
    const global_scope: ScopeId = @fromBackingInt(@intCast(0));
    const scopes = [_]Scope{.{ .parent = .none, .kind = .global, .is_strict = false }};
    const symbols = [_]Symbol{
        .{ .name = name, .scope_id = global_scope, .origin_scope = global_scope, .kind = .variable_var, .declaration_span = name, .synthetic_name = "_unused" },
    };
    var owners: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer owners.deinit(allocator);
    try owners.put(allocator, @backingInt(root), @backingInt(global_scope));
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

    // Generated transformer symbols also carry their stable name in the AST
    // string table. If the redundant synthetic_name marker is lost, the exact
    // audit must still recognize the row as generated and reject its missing
    // reachable binding.
    var missing_name_marker_symbols = symbols;
    missing_name_marker_symbols[0].synthetic_name = "";
    var missing_name_marker = try coverage.checkStrict(
        allocator,
        &ast,
        root,
        0,
        &.{},
        &missing_name_marker_symbols,
        &scopes,
        &owners,
        &.{},
        &synthetic,
        &unresolved,
    );
    defer missing_name_marker.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), missing_name_marker.orphan_symbols);
    try std.testing.expect(!missing_name_marker.hasCompleteExactCoverage());

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
    try owners.put(allocator, @backingInt(root_with_binding), @backingInt(global_scope));
    const symbol_ids = [_]?u32{ null, 0, null };
    var attached = try coverage.checkStrict(allocator, &ast, root_with_binding, 0, &symbol_ids, &symbols, &scopes, &owners, &.{}, &synthetic, &unresolved);
    defer attached.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), attached.orphan_symbols);
    try std.testing.expect(attached.hasCompleteExactCoverage());
}

test "strict inventory checks generated identity and exact lexical scope" {
    const allocator = std.testing.allocator;
    var ast = Ast.init(allocator, "x");
    defer ast.deinit();
    const name: @import("../lexer/token.zig").Span = .{ .start = 0, .end = 1 };
    const binding = try ast.addNode(.{ .tag = .binding_identifier, .span = name, .data = .{ .string_ref = name } });
    const read = try ast.addNode(.{ .tag = .identifier_reference, .span = name, .data = .{ .string_ref = name } });
    const block = try ast.addNode(.{ .tag = .block_statement, .span = name, .data = .{ .list = try ast.addNodeList(&.{ binding, read }) } });
    const root = try ast.addNode(.{ .tag = .program, .span = name, .data = .{ .list = try ast.addNodeList(&.{block}) } });

    const global_scope: ScopeId = @fromBackingInt(@intCast(0));
    const block_scope: ScopeId = @fromBackingInt(@intCast(1));
    const sibling_scope: ScopeId = @fromBackingInt(@intCast(2));
    const scopes = [_]Scope{
        .{ .parent = .none, .kind = .global, .is_strict = false },
        .{ .parent = global_scope, .kind = .block, .is_strict = false },
        .{ .parent = global_scope, .kind = .block, .is_strict = false },
    };
    var owners: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer owners.deinit(allocator);
    try owners.put(allocator, @backingInt(root), @backingInt(global_scope));
    try owners.put(allocator, @backingInt(block), @backingInt(block_scope));

    const symbols = [_]Symbol{
        .{ .name = name, .scope_id = block_scope, .origin_scope = block_scope, .kind = .variable_const, .declaration_span = name },
        .{ .name = name, .scope_id = sibling_scope, .origin_scope = sibling_scope, .kind = .variable_const, .declaration_span = name },
    };
    var symbol_ids = [_]?u32{ 0, 0, null, null };
    const references = [_]Reference{.{
        .node_index = read,
        .scope_id = block_scope,
        .symbol_id = @fromBackingInt(@intCast(0)),
        .flags = .{ .read = true },
    }};
    var synthetic: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer synthetic.deinit(allocator);
    try synthetic.put(allocator, @backingInt(binding), {});
    try synthetic.put(allocator, @backingInt(read), {});
    const unresolved: std.StringHashMapUnmanaged(void) = .empty;

    var correct = try coverage.checkStrict(allocator, &ast, root, 0, &symbol_ids, &symbols, &scopes, &owners, &references, &synthetic, &unresolved);
    defer correct.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), correct.counts[@backingInt(coverage.StrictStatus.bound)]);
    try std.testing.expect(correct.hasCompleteExactCoverage());

    // A different in-range SymbolId with the same spelling must not pass as bound.
    symbol_ids[@backingInt(read)] = 1;
    var wrong_id = try coverage.checkStrict(allocator, &ast, root, 0, &symbol_ids, &symbols, &scopes, &owners, &references, &synthetic, &unresolved);
    defer wrong_id.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), wrong_id.counts[@backingInt(coverage.StrictStatus.identity_mismatch)]);
    symbol_ids[@backingInt(read)] = 0;

    // Matching ID records are still invalid when that same-name symbol lives
    // in an inaccessible sibling scope.
    symbol_ids[@backingInt(read)] = 1;
    var sibling_reference = references;
    sibling_reference[0].symbol_id = @fromBackingInt(@intCast(1));
    var invisible = try coverage.checkStrict(allocator, &ast, root, 0, &symbol_ids, &symbols, &scopes, &owners, &sibling_reference, &synthetic, &unresolved);
    defer invisible.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), invisible.counts[@backingInt(coverage.StrictStatus.invisible_reference)]);
    symbol_ids[@backingInt(read)] = 0;

    // A valid but lexically incorrect scope must fail even though the symbol ID is right.
    var wrong_scope_references = references;
    wrong_scope_references[0].scope_id = global_scope;
    var wrong_scope = try coverage.checkStrict(allocator, &ast, root, 0, &symbol_ids, &symbols, &scopes, &owners, &wrong_scope_references, &synthetic, &unresolved);
    defer wrong_scope.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), wrong_scope.counts[@backingInt(coverage.StrictStatus.scope_mismatch)]);
    try std.testing.expect(!wrong_scope.hasCompleteSymbolIdentity());
    try std.testing.expect(!wrong_scope.hasCompleteExactCoverage());

    // A SymbolId copied onto a read without the matching Reference record is incomplete.
    var missing_reference = try coverage.checkStrict(allocator, &ast, root, 0, &symbol_ids, &symbols, &scopes, &owners, &.{}, &synthetic, &unresolved);
    defer missing_reference.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), missing_reference.counts[@backingInt(coverage.StrictStatus.missing_reference)]);

    // A transformed binding may keep its source origin after moving into the
    // output AST's exact binding scope.
    var wrong_binding_symbols = symbols;
    wrong_binding_symbols[0].origin_scope = sibling_scope;
    var wrong_binding_scope = try coverage.checkStrict(allocator, &ast, root, 0, &symbol_ids, &wrong_binding_symbols, &scopes, &owners, &references, &synthetic, &unresolved);
    defer wrong_binding_scope.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), wrong_binding_scope.counts[@backingInt(coverage.StrictStatus.bound)]);
    try std.testing.expect(wrong_binding_scope.hasCompleteExactCoverage());

    // A valid but unrelated storage ScopeId must fail even if origin_scope is
    // correct. The old check validated scope_id's range but never compared it.
    var wrong_storage_symbols = symbols;
    wrong_storage_symbols[0].scope_id = sibling_scope;
    wrong_storage_symbols[0].origin_scope = block_scope;
    var wrong_storage_scope = try coverage.checkStrict(allocator, &ast, root, 0, &symbol_ids, &wrong_storage_symbols, &scopes, &owners, &references, &synthetic, &unresolved);
    defer wrong_storage_scope.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), wrong_storage_scope.counts[@backingInt(coverage.StrictStatus.scope_mismatch)]);
    const bad_binding = for (wrong_storage_scope.findings.items) |finding| {
        if (finding.node == @backingInt(binding)) break finding;
    } else return error.MissingExpectedFinding;
    try std.testing.expectEqual(@as(?u32, @backingInt(block_scope)), bad_binding.expected_scope_id);
    try std.testing.expectEqual(@as(?u32, @backingInt(sibling_scope)), bad_binding.symbol_scope_id);
    try std.testing.expectEqual(@as(?u32, @backingInt(block_scope)), bad_binding.symbol_origin_scope_id);

    // A valid ID with a different symbol spelling is not accepted as identity.
    const other_name = try ast.addString("y");
    var wrong_name_symbols = symbols;
    wrong_name_symbols[0].name = other_name;
    var wrong_name = try coverage.checkStrict(allocator, &ast, root, 0, &symbol_ids, &wrong_name_symbols, &scopes, &owners, &references, &synthetic, &unresolved);
    defer wrong_name.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), wrong_name.counts[@backingInt(coverage.StrictStatus.name_mismatch)]);

    // Out-of-range IDs and scopes must fail closed instead of passing as valid.
    symbol_ids[@backingInt(read)] = 9;
    var invalid_id = try coverage.checkStrict(allocator, &ast, root, 0, &symbol_ids, &symbols, &scopes, &owners, &references, &synthetic, &unresolved);
    defer invalid_id.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), invalid_id.counts[@backingInt(coverage.StrictStatus.invalid_id)]);
    symbol_ids[@backingInt(read)] = 0;

    var invalid_scope_references = references;
    invalid_scope_references[0].scope_id = @fromBackingInt(@intCast(99));
    var invalid_scope = try coverage.checkStrict(allocator, &ast, root, 0, &symbol_ids, &symbols, &scopes, &owners, &invalid_scope_references, &synthetic, &unresolved);
    defer invalid_scope.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), invalid_scope.counts[@backingInt(coverage.StrictStatus.invalid_scope)]);

    // One AST reference must have one semantic record; duplicated evidence is ambiguous.
    const duplicate_references = [_]Reference{ references[0], references[0] };
    var duplicate = try coverage.checkStrict(allocator, &ast, root, 0, &symbol_ids, &symbols, &scopes, &owners, &duplicate_references, &synthetic, &unresolved);
    defer duplicate.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), duplicate.counts[@backingInt(coverage.StrictStatus.duplicate_reference)]);

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
    try owners.put(allocator, @backingInt(shared_root), @backingInt(global_scope));
    try owners.put(allocator, @backingInt(sibling_block), @backingInt(sibling_scope));
    var ambiguous = try coverage.checkStrict(allocator, &ast, shared_root, 0, &symbol_ids, &symbols, &scopes, &owners, &references, &synthetic, &unresolved);
    defer ambiguous.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), ambiguous.counts[@backingInt(coverage.StrictStatus.scope_ambiguous)]);
}

test "strict inventory recognizes a lowered var declaration independently of source kind" {
    const allocator = std.testing.allocator;
    var ast = Ast.init(allocator, "");
    defer ast.deinit();
    const name = try ast.addString("_using");
    const binding = try ast.addNode(.{ .tag = .binding_identifier, .span = name, .data = .{ .string_ref = name } });
    const none = @backingInt(@import("../parser/ast.zig").NodeIndex.none);
    const declarator_extra = try ast.addExtras(&.{ @backingInt(binding), none, none });
    const declarator = try ast.addNode(.{ .tag = .variable_declarator, .span = name, .data = .{ .extra = declarator_extra } });
    const declarators = try ast.addNodeList(&.{declarator});
    const declaration_extra = try ast.addExtras(&.{
        @backingInt(@import("../parser/ast.zig").VariableDeclarationKind.@"var"),
        declarators.start,
        declarators.len,
    });
    const declaration = try ast.addNode(.{ .tag = .variable_declaration, .span = name, .data = .{ .extra = declaration_extra } });
    const block = try ast.addNode(.{ .tag = .block_statement, .span = name, .data = .{ .list = try ast.addNodeList(&.{declaration}) } });
    const root = try ast.addNode(.{ .tag = .program, .span = name, .data = .{ .list = try ast.addNodeList(&.{block}) } });

    const global_scope: ScopeId = @fromBackingInt(@intCast(0));
    const block_scope: ScopeId = @fromBackingInt(@intCast(1));
    const scopes = [_]Scope{
        .{ .parent = .none, .kind = .global, .is_strict = false },
        .{ .parent = global_scope, .kind = .block, .is_strict = false },
    };
    var owners: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer owners.deinit(allocator);
    try owners.put(allocator, @backingInt(root), @backingInt(global_scope));
    try owners.put(allocator, @backingInt(block), @backingInt(block_scope));
    const symbols = [_]Symbol{
        .{ .name = name, .scope_id = global_scope, .origin_scope = block_scope, .kind = .variable_const, .declaration_span = name, .synthetic_name = "_using" },
    };
    const symbol_ids = [_]?u32{ 0, null, null, null, null };
    var synthetic: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer synthetic.deinit(allocator);
    try synthetic.put(allocator, @backingInt(binding), {});
    const unresolved: std.StringHashMapUnmanaged(void) = .empty;

    var report = try coverage.checkStrict(allocator, &ast, root, 0, &symbol_ids, &symbols, &scopes, &owners, &.{}, &synthetic, &unresolved);
    defer report.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), report.counts[@backingInt(coverage.StrictStatus.bound)]);
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

    const global_scope: ScopeId = @fromBackingInt(@intCast(0));
    const function_scope: ScopeId = @fromBackingInt(@intCast(1));
    const block_scope: ScopeId = @fromBackingInt(@intCast(2));
    const sibling_scope: ScopeId = @fromBackingInt(@intCast(3));
    const scopes = [_]Scope{
        .{ .parent = .none, .kind = .global, .is_strict = false },
        .{ .parent = global_scope, .kind = .function, .is_strict = false },
        .{ .parent = function_scope, .kind = .block, .is_strict = false },
        .{ .parent = function_scope, .kind = .block, .is_strict = false },
    };
    var owners: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer owners.deinit(allocator);
    try owners.put(allocator, @backingInt(root), @backingInt(global_scope));
    try owners.put(allocator, @backingInt(block), @backingInt(block_scope));

    const symbols = [_]Symbol{
        .{ .name = name, .scope_id = function_scope, .origin_scope = block_scope, .kind = .variable_var, .declaration_span = name },
        .{ .name = name, .scope_id = block_scope, .origin_scope = block_scope, .kind = .variable_const, .declaration_span = name },
        .{ .name = name, .scope_id = block_scope, .origin_scope = block_scope, .kind = .function_decl, .declaration_span = name },
    };
    const symbol_ids = [_]?u32{ 0, 1, 2, null, null };
    var synthetic: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer synthetic.deinit(allocator);
    try synthetic.put(allocator, @backingInt(var_binding), {});
    try synthetic.put(allocator, @backingInt(lexical_binding), {});
    try synthetic.put(allocator, @backingInt(function_binding), {});
    const unresolved: std.StringHashMapUnmanaged(void) = .empty;

    var report = try coverage.checkStrict(allocator, &ast, root, 0, &symbol_ids, &symbols, &scopes, &owners, &.{}, &synthetic, &unresolved);
    defer report.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 3), report.counts[@backingInt(coverage.StrictStatus.bound)]);
    try std.testing.expect(report.hasCompleteExactCoverage());

    var hoisted_origin = symbols;
    hoisted_origin[0].origin_scope = function_scope;
    var hoisted_origin_report = try coverage.checkStrict(allocator, &ast, root, 0, &symbol_ids, &hoisted_origin, &scopes, &owners, &.{}, &synthetic, &unresolved);
    defer hoisted_origin_report.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 3), hoisted_origin_report.counts[@backingInt(coverage.StrictStatus.bound)]);

    var wrong_var_storage = symbols;
    wrong_var_storage[0].scope_id = global_scope;
    var wrong_storage_report = try coverage.checkStrict(allocator, &ast, root, 0, &symbol_ids, &wrong_var_storage, &scopes, &owners, &.{}, &synthetic, &unresolved);
    defer wrong_storage_report.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), wrong_storage_report.counts[@backingInt(coverage.StrictStatus.scope_mismatch)]);
    try std.testing.expect(!wrong_storage_report.hasCompleteExactCoverage());

    var wrong_var_origin = symbols;
    wrong_var_origin[0].origin_scope = sibling_scope;
    var wrong_origin_report = try coverage.checkStrict(allocator, &ast, root, 0, &symbol_ids, &wrong_var_origin, &scopes, &owners, &.{}, &synthetic, &unresolved);
    defer wrong_origin_report.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 3), wrong_origin_report.counts[@backingInt(coverage.StrictStatus.bound)]);
    try std.testing.expect(wrong_origin_report.hasCompleteExactCoverage());

    var invalid_var_origin = symbols;
    invalid_var_origin[0].origin_scope = .none;
    var invalid_origin_report = try coverage.checkStrict(allocator, &ast, root, 0, &symbol_ids, &invalid_var_origin, &scopes, &owners, &.{}, &synthetic, &unresolved);
    defer invalid_origin_report.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), invalid_origin_report.counts[@backingInt(coverage.StrictStatus.invalid_scope)]);

    // A regular function declaration inside a block remains block-scoped in
    // this analyzer; the function_scoped flag alone is not enough to hoist it.
    var wrong_function_scope = symbols;
    wrong_function_scope[2].scope_id = global_scope;
    var wrong_function_report = try coverage.checkStrict(allocator, &ast, root, 0, &symbol_ids, &wrong_function_scope, &scopes, &owners, &.{}, &synthetic, &unresolved);
    defer wrong_function_report.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), wrong_function_report.counts[@backingInt(coverage.StrictStatus.scope_mismatch)]);
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
    const global_scope: ScopeId = @fromBackingInt(@intCast(0));
    const scopes = [_]Scope{.{ .parent = .none, .kind = .global, .is_strict = false }};
    const scope_maps = [_]std.StringHashMapUnmanaged(usize){.empty};
    var owners: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer owners.deinit(allocator);
    try owners.put(allocator, @backingInt(root), @backingInt(global_scope));
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
    ast.nodes.items[@backingInt(root)].data.list = try ast.addNodeList(&.{@fromBackingInt(@intCast(invalid_child_index))});
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
    ast.nodes.items[@backingInt(root)].data.list = try ast.addNodeList(&.{root});
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

    ast.nodes.items[@backingInt(root)].data.list = try ast.addNodeList(&.{shared_parent_a});
    ast.nodes.items[@backingInt(shared_parent_a)].data.list = try ast.addNodeList(&.{shared_parent_b});
    ast.nodes.items[@backingInt(shared_parent_b)].data.list = try ast.addNodeList(&.{shared_parent_a});
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

fn checkFunctionNameScopeAsGenerated(
    allocator: std.mem.Allocator,
    ast: *const Ast,
    root: AstNodeIndex,
    analyzer: *SemanticAnalyzer,
    scopes: []const Scope,
    scope_maps: []const std.StringHashMapUnmanaged(usize),
    references: []const Reference,
    first_generated_scope: usize,
) !coverage.ExactReport {
    const origins: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    const explicit_globals: std.AutoHashMapUnmanaged(u32, void) = .empty;
    return coverage.checkExactWithScopeBoundary(
        allocator,
        ast,
        root,
        @intCast(ast.nodes.items.len),
        analyzer.symbol_ids.items,
        analyzer.symbols.items,
        scopes,
        scope_maps,
        &analyzer.scope_owner_map,
        references,
        analyzer.helper_ref_nodes,
        &analyzer.helper_scope_map,
        &analyzer.unresolved_reference_nodes,
        &explicit_globals,
        &origins,
        first_generated_scope,
    );
}

test "exact scope audit accepts a generated function-expression self-name scope only in its exact shape" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var scanner = try Scanner.init(allocator, "var holder = function named(value) { return value; };");
    var parser = Parser.init(allocator, &scanner);
    const root = try parser.parse();
    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    try analyzer.analyze();

    // The analyzer models the self-name as a block scope around the function
    // scope. Treat it (and everything after it) as transform-generated, the
    // way a lowering that names a generated function expression creates it.
    var function_raw: ?u32 = null;
    for (parser.ast.nodes.items, 0..) |node, raw| {
        if (node.tag == .function_expression) function_raw = @intCast(raw);
    }
    const function_scope = analyzer.scope_owner_map.get(function_raw orelse return error.TestUnexpectedResult) orelse
        return error.TestUnexpectedResult;
    var name_scope = analyzer.scopes.items[function_scope].parent.toIndex();
    if (analyzer.scopes.items[name_scope].kind != .block) name_scope = analyzer.scopes.items[name_scope].parent.toIndex();
    try std.testing.expectEqual(@import("../semantic/scope.zig").ScopeKind.block, analyzer.scopes.items[name_scope].kind);
    try std.testing.expectEqual(@as(usize, 1), analyzer.scope_maps.items[name_scope].count());

    const scopes = analyzer.scopes.items;
    const scope_maps = analyzer.scope_maps.items;
    const references = analyzer.references.items;
    const accepted = try checkFunctionNameScopeAsGenerated(allocator, &parser.ast, root, &analyzer, scopes, scope_maps, references, name_scope);
    try std.testing.expectEqual(@as(usize, 0), accepted.scope_owner_mismatch);
    try std.testing.expect(accepted.isClean());

    // The transform editor anchors a generated name's declaration row in its
    // own scope; a declaration row is not an evaluated reference.
    var name_symbol: ?u32 = null;
    var it_names = scope_maps[name_scope].valueIterator();
    while (it_names.next()) |id| name_symbol = @intCast(id.*);
    const anchored_references = try allocator.alloc(Reference, references.len + 1);
    @memcpy(anchored_references[0..references.len], references);
    anchored_references[references.len] = .{
        .node_index = .none,
        .scope_id = @fromBackingInt(@intCast(name_scope)),
        .symbol_id = @fromBackingInt(@intCast(name_symbol orelse return error.TestUnexpectedResult)),
        .flags = .{ .declare = true },
    };
    const anchored = try checkFunctionNameScopeAsGenerated(allocator, &parser.ast, root, &analyzer, scopes, scope_maps, anchored_references, name_scope);
    try std.testing.expectEqual(@as(usize, 0), anchored.scope_owner_mismatch);

    // A second binding in the self-name scope is not the analyzer's shape.
    const crowded_maps = try allocator.dupe(std.StringHashMapUnmanaged(usize), scope_maps);
    crowded_maps[name_scope] = try scope_maps[name_scope].clone(allocator);
    try crowded_maps[name_scope].put(allocator, "intruder", 0);
    const crowded = try checkFunctionNameScopeAsGenerated(allocator, &parser.ast, root, &analyzer, scopes, crowded_maps, references, name_scope);
    try std.testing.expect(crowded.scope_owner_mismatch > 0);
    try std.testing.expect(!crowded.isClean());

    // A reference recorded directly in the self-name scope is rejected:
    // nothing evaluates in that scope.
    const moved_references = try allocator.dupe(Reference, references);
    var moved_one = false;
    for (moved_references) |*reference| {
        if (reference.flags.declare) continue;
        reference.scope_id = @fromBackingInt(@intCast(name_scope));
        moved_one = true;
        break;
    }
    try std.testing.expect(moved_one);
    const referenced = try checkFunctionNameScopeAsGenerated(allocator, &parser.ast, root, &analyzer, scopes, scope_maps, moved_references, name_scope);
    try std.testing.expect(referenced.scope_owner_mismatch > 0);
    try std.testing.expect(!referenced.isClean());

    // Only a block scope can hold the self-name.
    const function_kind_scopes = try allocator.dupe(Scope, scopes);
    function_kind_scopes[name_scope].kind = .function;
    const wrong_kind = try checkFunctionNameScopeAsGenerated(allocator, &parser.ast, root, &analyzer, function_kind_scopes, scope_maps, references, name_scope);
    try std.testing.expect(wrong_kind.scope_owner_mismatch > 0);
    try std.testing.expect(!wrong_kind.isClean());

    // Without its function expression in the AST the scope has no owner.
    const empty_root = try parser.ast.addNode(.{ .tag = .program, .span = .EMPTY, .data = .{ .list = try parser.ast.addNodeList(&.{}) } });
    try analyzer.scope_owner_map.put(allocator, @backingInt(empty_root), 0);
    const detached = try checkFunctionNameScopeAsGenerated(allocator, &parser.ast, empty_root, &analyzer, scopes, scope_maps, references, name_scope);
    try std.testing.expect(detached.scope_owner_mismatch > 0);
    try std.testing.expect(!detached.isClean());
}
