//! Primary AST/semantic construction for the selected interop module source.
//! This producer does not activate an output root or execute the module.
const std = @import("std");
const ast_mod = @import("../parser/ast.zig");
const Ast = ast_mod.Ast;
const NodeIndex = ast_mod.NodeIndex;
const Scanner = @import("../lexer/scanner.zig").Scanner;
const Parser = @import("../parser/parser.zig").Parser;
const Analyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer;
const symbol = @import("../semantic/symbol.zig");
const ScopeId = @import("../semantic/scope.zig").ScopeId;
const ModuleSemanticData = @import("module.zig").ModuleSemanticData;
const source_module = @import("../runtime_helper_modules.zig");
const names = @import("../runtime_helper_names.zig");

pub const Binding = struct { node: NodeIndex, declaration: NodeIndex, initializer: NodeIndex, symbol_id: symbol.SymbolId, scope_id: ScopeId };
pub const Anchors = struct { nodes: [10]?NodeIndex = @splat(null), declarations: [10]?NodeIndex = @splat(null), initializers: [10]?NodeIndex = @splat(null), count: usize = 0 };
pub const Built = struct {
    ast: Ast,
    root: NodeIndex,
    semantic: ModuleSemanticData,
    anchors: Anchors,
    helpers: [10]?Binding,
    stmt_info: @import("stmt_info.zig").ModuleStmtInfos,
    flavor: source_module.InteropFlavor,
};

/// The graph retains producer handles; this record is never serialized or
/// reconstructed from emitted helper spellings.
pub const Provider = struct {
    module_index: @import("types.zig").ModuleIndex,
    semantic_owner: @import("module.zig").SemanticOwnerToken,
    root: NodeIndex,
    options: source_module.SourceOptions,
    anchors: Anchors,
    bindings: [10]?Binding,
    active: bool = false,
    wrapped: bool = false,
    reachable: ?*const std.DynamicBitSet = null,
};

pub fn installCandidate(graph: anytype, io: std.Io, options: source_module.SourceOptions) !void {
    const module_mod = @import("module.zig");
    const index = try graph.addModule(io, source_module.interopId(.wrapped));
    const old = graph.moduleAtMut(index) orelse return error.InvalidInteropProgram;
    const path = old.path;
    // This compiler-owned source is analyzed afresh rather than inheriting a
    // stale semantic owner from a module-store or a preserved graph.
    const arena = module_mod.createParseArena(graph.allocator) orelse return error.OutOfMemory;
    errdefer module_mod.destroyParseArena(graph.allocator, arena);
    var built = try build(arena.allocator(), .wrapped, options);
    const semantic_owner = built.semantic.captureOwnerToken();
    var module = module_mod.Module.init(index, path);
    module.parse_arena = arena;
    module.source = built.ast.source;
    module.ast = built.ast;
    module.semantic = built.semantic;
    module.prebuilt_stmt_info = built.stmt_info;
    module.export_bindings = try arena.allocator().alloc(@import("binding_scanner.zig").ExportBinding, 10);
    const exported_names = try arena.allocator().alloc([]const u8, 10);
    inline for (names.ESM_INTEROP_RUNTIME_HELPERS, 0..) |helper, role| {
        const binding = built.helpers[role].?;
        const row = built.semantic.symbols.items[@backingInt(binding.symbol_id)];
        const exported_name = names.esmInteropRuntimeHelperBaseName(helper);
        module.export_bindings[role] = .{
            .exported_name = exported_name,
            .local_name = row.nameText(module.source),
            .local_span = row.declaration_span,
            .local_symbol_node = binding.node,
            .kind = .local,
            .symbol = @import("symbol.zig").SymbolRef.makeSemantic(index, @backingInt(binding.symbol_id)),
            .init_is_fn_or_class = role >= 6,
        };
        exported_names[role] = exported_name;
    }
    module.exported_names = exported_names;
    module.exports_kind = .esm;
    module.has_local_export = true;
    module.module_type = .js;
    module.loader = .javascript;
    module.side_effects = false;
    module.state = .ready;
    old.deinit(graph.allocator);
    old.* = module;
    graph.interop_ast_provider = .{ .module_index = index, .semantic_owner = semantic_owner, .root = built.root, .options = options, .anchors = built.anchors, .bindings = built.helpers };
}

pub fn resolveBindings(graph: anytype) ![10]?Binding {
    const provider = graph.interop_ast_provider orelse return error.InvalidInteropIdentity;
    const module = graph.getModule(provider.module_index) orelse return error.InvalidInteropIdentity;
    const ast = if (module.ast) |*value| value else return error.InvalidInteropIdentity;
    const semantic = if (module.semantic) |*value| value else return error.InvalidInteropIdentity;
    if (semantic.owner_token == .unassigned or semantic.owner_token != provider.semantic_owner) return error.InvalidInteropIdentity;
    if (provider.root.isNone() or @backingInt(provider.root) >= ast.nodes.items.len) return error.InvalidInteropIdentity;
    if ((ast.transformed_root orelse @as(NodeIndex, @fromBackingInt(@as(u32, @intCast(ast.nodes.items.len - 1))))) != provider.root) return error.InvalidInteropIdentity;
    // Revalidate only the known producer tuples. Matching spellings cannot
    // select replacement nodes, rows or a different semantic owner.
    const current_anchors = captureAnchors(ast, provider.root, .wrapped, provider.options) catch return error.InvalidInteropIdentity;
    if (!std.meta.eql(current_anchors, provider.anchors)) return error.InvalidInteropIdentity;
    const scope = semantic.scope_owner_map.get(@backingInt(provider.root)) orelse return error.InvalidInteropIdentity;
    const bindings = try bindAnchors(ast, semantic, provider.anchors);
    if (!std.meta.eql(bindings, provider.bindings)) return error.InvalidInteropIdentity;
    if (module.export_bindings.len != 10 or module.exported_names.len != 10 or module.exports_kind != .esm or !module.has_local_export) return error.InvalidInteropIdentity;
    inline for (names.ESM_INTEROP_RUNTIME_HELPERS, 0..) |helper, index| {
        const binding = bindings[index].?;
        const exported = module.export_bindings[index];
        const expected_name = names.esmInteropRuntimeHelperBaseName(helper);
        if (@backingInt(binding.scope_id) != scope or exported.kind != .local or exported.local_symbol_node != binding.node or
            exported.symbol.moduleIndex() != provider.module_index or exported.symbol.semanticIndex() != @backingInt(binding.symbol_id) or
            !std.mem.eql(u8, exported.exported_name, expected_name) or !std.mem.eql(u8, module.exported_names[index], expected_name)) return error.InvalidInteropIdentity;
    }
    return bindings;
}

pub fn outputNames(graph: anytype, renames: anytype) !names.EsmInteropRuntimeNames {
    const provider = graph.interop_ast_provider orelse return error.InvalidInteropIdentity;
    const bindings = try resolveBindings(graph);
    const module = graph.getModule(provider.module_index) orelse return error.InvalidInteropIdentity;
    const semantic = module.semantic orelse return error.InvalidInteropIdentity;
    var result: names.EsmInteropRuntimeNames = .{};
    inline for (names.ESM_INTEROP_RUNTIME_HELPERS, 0..) |helper, index| {
        const id = bindings[index].?.symbol_id;
        const key = @import("symbol.zig").SymbolID.make(provider.module_index, @backingInt(id));
        result.set(helper, renames.get(key) orelse semantic.symbols.items[@backingInt(id)].nameText(module.source));
    }
    return result;
}

/// Only a real included consumer can activate this self-contained provider.
/// Statement reachability follows exact local SymbolIds through ordinary
/// StmtInfo edges; no export-name lookup or opaque whole-module seed occurs.
pub fn activate(graph: anytype, wrapped: bool, shaker: ?*@import("tree_shaker.zig").TreeShaker) !void {
    const provider = if (graph.interop_ast_provider) |*value| value else return;
    const bindings = try resolveBindings(graph);
    const module = graph.moduleAtMut(provider.module_index) orelse return error.InvalidInteropIdentity;
    const arena = module.parse_arena.?.allocator();
    const infos = module.prebuilt_stmt_info orelse return error.InvalidInteropIdentity;
    const seeds = [_]u32{ @backingInt(bindings[7].?.symbol_id), @backingInt(bindings[8].?.symbol_id), @backingInt(bindings[9].?.symbol_id) };
    const reachable = try arena.create(std.DynamicBitSet);
    reachable.* = try infos.computeReachable(arena, if (wrapped) &seeds else seeds[0..1]);
    // Clone before replacing any owned bitset or publishing a new mirror.
    // A failed repeated activation leaves the old state fully usable.
    const replacement: ?std.DynamicBitSet = if (shaker) |s| try reachable.clone(s.allocator) else null;
    provider.active = true;
    provider.wrapped = wrapped;
    provider.reachable = reachable;
    module.is_included = true;
    module.reachable_stmts = reachable;
    module.symbol_to_stmt = infos.symbol_to_stmt;
    if (shaker) |s| {
        const index = provider.module_index.toU32();
        s.included.set(index);
        if (s.reachable_stmts[index]) |*previous| previous.deinit();
        s.reachable_stmts[index] = replacement;
        module.tree_shaker_active = true;
        module.reachable_stmts = &s.reachable_stmts[index].?;
    }
}

pub fn emit(output: *std.ArrayList(u8), allocator: std.mem.Allocator, graph: anytype, linker: anytype, options: anytype) !void {
    const provider = graph.interop_ast_provider orelse return error.InvalidInteropIdentity;
    if (!provider.active) return;
    _ = try resolveBindings(graph);
    const module = graph.getModule(provider.module_index) orelse return error.InvalidInteropIdentity;
    const ast = if (module.ast) |*value| value else return error.InvalidInteropIdentity;
    const semantic = if (module.semantic) |*value| value else return error.InvalidInteropIdentity;
    const infos = module.prebuilt_stmt_info orelse return error.InvalidInteropIdentity;
    const reachable = provider.reachable orelse return error.InvalidInteropIdentity;
    var metadata = try linker.buildMetadataForAst(ast, provider.module_index.toU32(), false, semantic.symbol_ids, options.format, false);
    defer metadata.deinit();
    for (infos.stmts, 0..) |statement, index| {
        if (!reachable.isSet(index)) metadata.skip_nodes.set(statement.node_idx);
    }
    var cg = @import("../codegen/codegen.zig").Codegen.initWithOptions(allocator, ast, .{
        .minify_whitespace = options.minify_whitespace,
        // The selected builtin template already chooses its syntax variant.
        // Keep its descriptor literals stable while codegen handles whitespace.
        .minify_syntax = false,
        .module_format = .esm,
        .linking_metadata = &metadata,
        .semantic_symbol_ids = semantic.symbol_ids,
        .semantic_symbols = semantic.symbols.items,
        .semantic_scope_maps = semantic.scope_maps,
        .generated_iife_scope_owner_map = &semantic.scope_owner_map,
        .require_generated_iife_symbols = true,
        .ascii_only = false,
    });
    defer cg.deinit();
    const root: NodeIndex = @fromBackingInt(@as(u32, @intCast(ast.nodes.items.len - 1)));
    const code = try cg.generate(root);
    try output.appendSlice(allocator, code);
    if (code.len > 0 and code[code.len - 1] != '\n') try output.append(allocator, '\n');
}

/// Structural ordinal anchors are recorded before any SymbolId exists. A
/// spelling check verifies a known slot; it never searches for another node.
pub fn captureAnchors(ast: *const Ast, root: NodeIndex, flavor: source_module.InteropFlavor, options: source_module.SourceOptions) !Anchors {
    if (root.isNone() or @backingInt(root) >= ast.nodes.items.len) return error.InvalidInteropProgram;
    const program = ast.getNode(root);
    if (program.tag != .program) return error.InvalidInteropProgram;
    if (@as(usize, program.data.list.start) + program.data.list.len > ast.extra_data.items.len) return error.InvalidInteropProgram;
    var anchors: Anchors = .{};
    var statements = ast.iterateExtraList(program.data.list);
    while (statements.next()) |statement| {
        if (statement.isNone() or @backingInt(statement) >= ast.nodes.items.len) return error.InvalidInteropDeclaration;
        const declaration = ast.getNode(statement);
        if (declaration.tag == .export_named_declaration) continue;
        if (declaration.tag != .variable_declaration or @as(usize, declaration.data.extra) + 2 >= ast.extra_data.items.len) return error.InvalidInteropDeclaration;
        const start = ast.readExtra(declaration.data.extra, 1);
        const len = ast.readExtra(declaration.data.extra, 2);
        if (@as(usize, start) + len > ast.extra_data.items.len) return error.InvalidInteropDeclaration;
        for (ast.extra_data.items[start..][0..len]) |raw| {
            if (raw >= ast.nodes.items.len or anchors.count >= 10) return error.InvalidInteropDeclaration;
            const declarator = ast.nodes.items[raw];
            if (declarator.tag != .variable_declarator or @as(usize, declarator.data.extra) + 2 >= ast.extra_data.items.len) return error.InvalidInteropDeclaration;
            const node = ast.readExtraNode(declarator.data.extra, 0);
            const initializer = ast.readExtraNode(declarator.data.extra, 2);
            if (node.isNone() or initializer.isNone() or @backingInt(node) >= ast.nodes.items.len or @backingInt(initializer) >= ast.nodes.items.len) return error.InvalidInteropDeclaration;
            const binding = ast.getNode(node);
            if (binding.tag != .binding_identifier) return error.InvalidInteropDeclaration;
            const helper = names.ESM_INTEROP_RUNTIME_HELPERS[anchors.count];
            const expected = names.helperName(names.esmInteropRuntimeHelperBaseName(helper), options.minify);
            if (!std.mem.eql(u8, expected, ast.getText(binding.data.string_ref))) return error.InvalidInteropDeclaration;
            anchors.nodes[anchors.count] = node;
            anchors.declarations[anchors.count] = @fromBackingInt(raw);
            anchors.initializers[anchors.count] = initializer;
            anchors.count += 1;
        }
    }
    if (anchors.count != @as(usize, if (flavor == .wrapped) 10 else 8)) return error.InvalidInteropDeclaration;
    return anchors;
}

pub fn bindAnchors(ast: *const Ast, semantic: *const ModuleSemanticData, anchors: Anchors) ![10]?Binding {
    if (anchors.count != 8 and anchors.count != 10) return error.InvalidInteropIdentity;
    var bindings: [10]?Binding = @splat(null);
    for (anchors.nodes, 0..) |maybe_node, index| {
        if (index >= anchors.count) {
            if (maybe_node != null) return error.InvalidInteropIdentity;
            continue;
        }
        const node = maybe_node orelse return error.InvalidInteropIdentity;
        const declaration_node = anchors.declarations[index] orelse return error.InvalidInteropIdentity;
        const initializer = anchors.initializers[index] orelse return error.InvalidInteropIdentity;
        if (declaration_node.isNone() or initializer.isNone() or @backingInt(declaration_node) >= ast.nodes.items.len or @backingInt(initializer) >= ast.nodes.items.len) return error.InvalidInteropIdentity;
        const declaration = ast.getNode(declaration_node);
        if (declaration.tag != .variable_declarator or @as(usize, declaration.data.extra) + 2 >= ast.extra_data.items.len or
            ast.readExtraNode(declaration.data.extra, 0) != node or ast.readExtraNode(declaration.data.extra, 2) != initializer) return error.InvalidInteropIdentity;
        const raw = @backingInt(node);
        if (raw >= ast.nodes.items.len or raw >= semantic.symbol_ids.len) return error.InvalidInteropIdentity;
        const id = semantic.symbol_ids[raw] orelse return error.InvalidInteropIdentity;
        if (id >= semantic.symbols.items.len) return error.InvalidInteropIdentity;
        const row = semantic.symbols.items[id];
        if (row.kind != .variable_var or row.scope_id.isNone() or row.scope_id.toIndex() >= semantic.scopes.len) return error.InvalidInteropIdentity;
        const scope = semantic.scopes[row.scope_id.toIndex()];
        const binding = ast.getNode(node);
        if (scope.kind != .module or !scope.parent.isNone() or binding.tag != .binding_identifier or
            !std.mem.eql(u8, row.nameText(ast.source), ast.getText(binding.data.string_ref))) return error.InvalidInteropIdentity;
        bindings[index] = .{ .node = node, .declaration = declaration_node, .initializer = initializer, .symbol_id = @fromBackingInt(id), .scope_id = row.scope_id };
    }
    return bindings;
}

fn listItems(ast: *const Ast, list: ast_mod.NodeList) []const u32 {
    return ast.extra_data.items[list.start..][0..list.len];
}

/// Preserve the module's strict function contexts when its declarations are
/// scope-hoisted into a mixed sloppy CJS/IIFE output. All nodes and additional
/// arrow-body scopes are created before the one initial semantic analysis.
fn makeStrictFunctionBodies(ast: *Ast, original_root: NodeIndex) !NodeIndex {
    const original_count = ast.nodes.items.len;
    const directive_span = try ast.addString("\"use strict\"");
    for (0..original_count) |raw| {
        const node = ast.nodes.items[raw];
        const body_slot: u32 = switch (node.tag) {
            .arrow_function_expression => ast_mod.ArrowExtra.body,
            .function_expression, .function_declaration, .function => ast_mod.FunctionExtra.body,
            else => continue,
        };
        // Every selected builtin variant has simple identifier parameters, for
        // which a strict directive is valid JavaScript syntax.
        for (listItems(ast, ast.functionParamsList(node))) |parameter| {
            var pattern = ast.getNode(@fromBackingInt(parameter));
            if (pattern.tag == .formal_parameter) {
                if (!ast.readExtraNode(pattern.data.extra, ast_mod.FormalParameterExtra.default).isNone()) return error.InvalidInteropProgram;
                pattern = ast.getNode(ast.readExtraNode(pattern.data.extra, ast_mod.FormalParameterExtra.pattern));
            }
            if (pattern.tag != .binding_identifier and
                !(node.tag == .arrow_function_expression and
                    (pattern.tag == .identifier_reference or pattern.tag == .assignment_target_identifier))) return error.InvalidInteropProgram;
        }
        const body = ast.functionBodyBlock(node) orelse return error.InvalidInteropProgram;
        const previous = ast.getNode(body);
        const directive = try ast.addNode(.{ .tag = .directive, .span = directive_span, .data = .{ .none = 0 } });
        if (previous.tag == .block_statement) {
            const statements = try ast.allocator.alloc(NodeIndex, @as(usize, previous.data.list.len) + 1);
            statements[0] = directive;
            for (listItems(ast, previous.data.list), 1..) |statement, index| statements[index] = @fromBackingInt(statement);
            ast.nodes.items[@backingInt(body)].data.list = try ast.addNodeList(statements);
        } else {
            if (node.tag != .arrow_function_expression) return error.InvalidInteropProgram;
            const ret = try ast.addNode(.{ .tag = .return_statement, .span = previous.span, .data = .{ .unary = .{ .operand = body, .flags = 0 } } });
            const block = try ast.addNode(.{ .tag = .block_statement, .span = previous.span, .data = .{ .list = try ast.addNodeList(&.{ directive, ret }) } });
            ast.extra_data.items[node.data.extra + body_slot] = @backingInt(block);
        }
    }
    const root = try ast.addNode(ast.getNode(original_root));
    ast.transformed_root = root;
    return root;
}

/// All backing allocations belong to the caller's arena, including source,
/// parser/analyzer arrays, scope maps and references. No second analysis occurs.
pub fn build(arena: std.mem.Allocator, flavor: source_module.InteropFlavor, options: source_module.SourceOptions) !Built {
    const source = try source_module.interopSource(arena, flavor, options);
    var scanner = try Scanner.init(arena, source);
    var parser = Parser.init(arena, &scanner);
    parser.configureForBundler(".mjs");
    parser.configureForBundlerKind(false, false);
    const parsed_root = try parser.parse();
    if (parser.errors.items.len != 0) {
        for (parser.errors.items) |err| std.debug.print("interop parse error: {s} at {d}, flavor={s} min={any} es5={any} cfg={any}\n", .{ err.message, err.span.start, @tagName(flavor), options.minify, options.es5, options.configurable_exports });
        return error.InvalidInteropProgram;
    }
    const root = try makeStrictFunctionBodies(&parser.ast, parsed_root);
    const anchors = try captureAnchors(&parser.ast, root, flavor, options);
    var analyzer = Analyzer.init(arena, &parser.ast);
    analyzer.is_module = true;
    analyzer.is_strict_mode = parser.is_strict_mode;
    analyzer.enable_stmt_info = true;
    analyzer.enable_exact_declaration_anchors = true;
    analyzer.collect_unresolved_reference_nodes = true;
    try analyzer.analyze();
    if (analyzer.errors.items.len != 0) return error.InvalidInteropProgram;
    const semantic: ModuleSemanticData = .{
        .symbols = analyzer.symbols,
        .scopes = analyzer.scopes.items,
        .scope_maps = analyzer.scope_maps.items,
        .scope_owner_map = analyzer.scope_owner_map,
        .node_scope_provenance = analyzer.node_scope_provenance,
        .class_self_symbol_map = analyzer.class_self_symbol_map,
        .namespace_member_owners = analyzer.namespace_member_owners,
        .namespace_declaration_owners = analyzer.namespace_declaration_owners,
        .exported_names = analyzer.exported_names,
        .symbol_ids = analyzer.symbol_ids.items,
        .unresolved_references = analyzer.unresolved_references,
        .references = analyzer.references.items,
        .numeric_const_texts = analyzer.numeric_const_texts,
        .helper_scope_map = analyzer.helper_scope_map,
    };
    const stmt_info = try @import("stmt_info.zig").buildFromSemantic(arena, &parser.ast, semantic.symbols.items, semantic.scopes, semantic.symbol_ids, semantic.references, &semantic.unresolved_references, false, false) orelse return error.InvalidInteropProgram;
    return .{ .ast = parser.ast, .root = root, .semantic = semantic, .anchors = anchors, .helpers = try bindAnchors(&parser.ast, &semantic, anchors), .stmt_info = stmt_info, .flavor = flavor };
}

test "interop AST primary analysis gives all twelve selected modules real binding and reference scopes" {
    const variants = [_]source_module.SourceOptions{ .{}, .{ .minify = true }, .{ .es5 = true }, .{ .es5 = true, .minify = true }, .{ .configurable_exports = true }, .{ .configurable_exports = true, .minify = true } };
    for (variants) |options| {
        for ([_]source_module.InteropFlavor{ .to_esm, .wrapped }) |flavor| {
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            const built = try build(arena.allocator(), flavor, options);
            const globals: usize = if (flavor == .wrapped) 10 else 8;
            const locals: usize = if (flavor == .wrapped) 14 else 10;
            try std.testing.expectEqual(globals + locals, built.semantic.symbols.items.len);
            for (built.helpers, 0..) |binding, index| {
                if (index >= globals) {
                    try std.testing.expect(binding == null);
                    continue;
                }
                const exact = binding.?;
                try std.testing.expectEqual(@backingInt(exact.symbol_id), built.semantic.symbol_ids[@backingInt(exact.node)].?);
                try std.testing.expect(!exact.scope_id.isNone());
                try std.testing.expectEqual(@import("../semantic/scope.zig").ScopeKind.module, built.semantic.scopes[exact.scope_id.toIndex()].kind);
            }
            for (built.semantic.symbols.items) |row| try std.testing.expect(!row.scope_id.isNone() and row.scope_id.toIndex() < built.semantic.scopes.len);
            try std.testing.expectEqual(built.root, built.ast.transformed_root.?);
            try std.testing.expectEqual(@as(usize, @backingInt(built.root) + 1), built.ast.nodes.items.len);
            for (built.semantic.scopes) |scope| try std.testing.expect(scope.is_strict);
            const reachable = try @import("../parser/ast_walk.zig").collectReachableNodeIndices(arena.allocator(), &built.ast);
            for (reachable) |raw| {
                const node = built.ast.nodes.items[raw];
                if (node.tag != .function_expression and node.tag != .arrow_function_expression) continue;
                const body = built.ast.getNode(built.ast.functionBodyBlock(node).?);
                try std.testing.expectEqual(ast_mod.Node.Tag.block_statement, body.tag);
                const first = built.ast.getNode(@fromBackingInt(listItems(&built.ast, body.data.list)[0]));
                try std.testing.expectEqual(ast_mod.Node.Tag.directive, first.tag);
                try std.testing.expectEqualStrings("\"use strict\"", built.ast.getText(first.span));
            }
            for (built.semantic.references) |reference| {
                try std.testing.expect(!reference.scope_id.isNone() and reference.scope_id.toIndex() < built.semantic.scopes.len);
                try std.testing.expect(@backingInt(reference.symbol_id) < built.semantic.symbols.items.len);
                if (!reference.flags.declare) try std.testing.expect(!reference.node_index.isNone());
            }
        }
    }
}

fn nearestFunctionScope(semantic: *const ModuleSemanticData, start: ScopeId) ?ScopeId {
    var scope = start;
    var remaining = semantic.scopes.len;
    while (!scope.isNone() and scope.toIndex() < semantic.scopes.len and remaining > 0) : (remaining -= 1) {
        if (semantic.scopes[scope.toIndex()].kind == .function) return scope;
        scope = semantic.scopes[scope.toIndex()].parent;
    }
    return null;
}

test "interop AST getter capture owns the additional min arrow child scope" {
    const variants = [_]source_module.SourceOptions{ .{}, .{ .minify = true }, .{ .es5 = true }, .{ .es5 = true, .minify = true }, .{ .configurable_exports = true }, .{ .configurable_exports = true, .minify = true } };
    for (variants) |options| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const built = try build(arena.allocator(), .to_esm, options);
        const copy_props = built.helpers[@backingInt(names.EsmInteropRuntimeHelper.copy_props)].?;
        const nodes = try @import("../parser/ast_walk.zig").collectReachableNodeIndicesFrom(arena.allocator(), &built.ast, copy_props.initializer);
        var key_id: ?symbol.SymbolId = null;
        var key_scope: ?ScopeId = null;
        var getter_scope: ?ScopeId = null;
        var nested_functions: usize = 0;
        for (nodes) |raw| {
            if (raw == @backingInt(copy_props.initializer)) continue;
            const node = built.ast.nodes.items[raw];
            if (node.tag != .function_expression and node.tag != .arrow_function_expression) continue;
            nested_functions += 1;
            const params = built.ast.functionParams(node);
            const scope: ScopeId = @fromBackingInt(built.semantic.scope_owner_map.get(raw) orelse return error.MissingGetterOwner);
            if (params.len == 1) {
                const id = built.semantic.symbol_ids[params[0]] orelse return error.MissingGetterParameter;
                try std.testing.expectEqualStrings("k", built.semantic.symbols.items[id].nameText(built.ast.source));
                key_id = @fromBackingInt(id);
                key_scope = scope;
                try std.testing.expectEqual(scope, built.semantic.symbols.items[id].scope_id);
            } else if (params.len == 0) getter_scope = scope else return error.UnexpectedGetterShape;
        }
        const min_arrow = options.minify and !options.es5 and !options.configurable_exports;
        try std.testing.expectEqual(@as(usize, if (min_arrow) 2 else 1), nested_functions);
        try std.testing.expect(key_id != null and key_scope != null);
        const use_scope = if (min_arrow) getter_scope orelse return error.MissingGetterChild else key_scope.?;
        if (min_arrow) {
            try std.testing.expect(use_scope != key_scope.?);
            try std.testing.expectEqual(key_scope.?, nearestFunctionScope(&built.semantic, built.semantic.scopes[use_scope.toIndex()].parent).?);
        }
        var reads: usize = 0;
        for (built.semantic.references) |reference| {
            if (reference.flags.declare or reference.symbol_id != key_id.?) continue;
            reads += 1;
            try std.testing.expectEqual(use_scope, nearestFunctionScope(&built.semantic, reference.scope_id).?);
        }
        try std.testing.expect(reads > 0);
        // All cross-helper uses are bound in this module. Only the intrinsic
        // global Object remains external; no helper free reference is hidden.
        try std.testing.expectEqual(@as(u32, 1), built.semantic.unresolved_references.count());
        try std.testing.expect(built.semantic.unresolved_references.contains("Object"));
    }
}

test "interop AST cache preserves producer anchors without scope-map recovery" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const built = try build(a, .wrapped, .{ .minify = true });
    var anchors: Anchors = .{ .count = 10 };
    for (built.helpers, 0..) |binding, index| {
        anchors.nodes[index] = binding.?.node;
        anchors.declarations[index] = binding.?.declaration;
        anchors.initializers[index] = binding.?.initializer;
    }
    var bytes: std.ArrayList(u8) = .empty;
    try @import("module_codec.zig").serialize(&built.ast, &built.semantic, &bytes, a);
    const decoded = try @import("module_codec.zig").deserialize(bytes.items, a);
    const bindings = try bindAnchors(&decoded.ast, &decoded.semantic, anchors);
    try std.testing.expectEqualDeep(built.helpers, bindings);
    // Changing the spelling lookup cannot select a different binding ID.
    var semantic = decoded.semantic;
    var map = @constCast(&semantic.scope_maps[bindings[0].?.scope_id.toIndex()]);
    const first_name = semantic.symbols.items[@backingInt(bindings[0].?.symbol_id)].nameText(decoded.ast.source);
    try map.put(a, first_name, @backingInt(bindings[1].?.symbol_id));
    try std.testing.expectEqualDeep(bindings, try bindAnchors(&decoded.ast, &semantic, anchors));
    const slot = @backingInt(bindings[0].?.node);
    @constCast(semantic.symbol_ids)[slot] = @backingInt(bindings[1].?.symbol_id);
    try std.testing.expectError(error.InvalidInteropIdentity, bindAnchors(&decoded.ast, &semantic, anchors));
}

test "interop AST anchors fail closed on ten malformed producer handles" {
    for (0..10) |corruption| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var built = try build(arena.allocator(), .wrapped, .{});
        var anchors: Anchors = .{ .count = 10 };
        for (built.helpers, 0..) |binding, index| {
            anchors.nodes[index] = binding.?.node;
            anchors.declarations[index] = binding.?.declaration;
            anchors.initializers[index] = binding.?.initializer;
        }
        const first = built.helpers[0].?;
        switch (corruption) {
            0 => anchors.nodes[0] = null,
            1 => anchors.nodes[0] = .none,
            2 => anchors.nodes[0] = @fromBackingInt(@as(u32, 999_999)),
            3 => @constCast(built.semantic.symbol_ids)[@backingInt(first.node)] = null,
            4 => @constCast(built.semantic.symbol_ids)[@backingInt(first.node)] = 999_999,
            5 => @constCast(built.semantic.symbol_ids)[@backingInt(first.node)] = @backingInt(built.helpers[1].?.symbol_id),
            6 => built.semantic.symbols.items[@backingInt(first.symbol_id)].kind = .parameter,
            7 => built.semantic.symbols.items[@backingInt(first.symbol_id)].scope_id = .none,
            8 => anchors.initializers[0] = @fromBackingInt(@as(u32, 999_999)),
            9 => anchors.declarations[0] = anchors.declarations[1],
            else => unreachable,
        }
        try std.testing.expectError(error.InvalidInteropIdentity, bindAnchors(&built.ast, &built.semantic, anchors));
    }
}

test "interop AST single bundle activates exact graph providers across ten live inputs" {
    const Bundler = @import("bundler.zig").Bundler;
    const helpers = @import("test_helpers.zig");
    const entries = [_][]const u8{
        "import * as value from './dep.cjs'; console.log(JSON.stringify(value));",
        "import value from './dep.cjs'; console.log(value.answer);",
        "export {default} from './dep.cjs';",
        "import('./dep.cjs').then(value => console.log(value.default.answer));",
        "import * as value from './dep.cjs'; const __copyProps = 3; console.log(value.answer, __copyProps);",
        "import * as value from './dep.cjs'; function read(__toESM) { return __toESM; } console.log(value.answer, read(6));",
        "import * as value from './dep.cjs'; const Object = {answer: 7}; console.log(value.answer, Object.answer);",
        "import * as value from './dep.cjs'; const __getOwnPropDesc = 8; console.log(value.answer, __getOwnPropDesc);",
        "const value = require('./dep.mjs'); console.log(value.answer);",
        "import * as value from './dep.cjs'; console.log(value.answer);",
    };
    var missing_providers: usize = 0;
    for (entries, 0..) |entry_source, index| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try helpers.writeFile(tmp.dir, "entry.js", entry_source);
        try helpers.writeFile(tmp.dir, "dep.cjs", "exports.answer = 42;");
        try helpers.writeFile(tmp.dir, "dep.mjs", "export const answer = 42;");
        const entry = try helpers.absPath(&tmp, "entry.js");
        defer std.testing.allocator.free(entry);
        var options: @import("bundler.zig").BundleOptions = .{ .entry_points = &.{entry}, .inline_dynamic_imports = true };
        if (index == 7 or index == 9) {
            options.minify_identifiers = true;
            options.minify_whitespace = true;
        }
        if (index == 7) options.configurable_exports = true;
        if (index == 9) options.unsupported.arrow = true;
        var cache = Bundler.initResolveCacheFromOptions(std.testing.allocator, options);
        defer cache.deinit();
        var graph = @import("graph.zig").ModuleGraph.init(std.testing.allocator, &cache);
        defer graph.deinit();
        var bundler = Bundler.initWithGraph(std.testing.allocator, options, &cache, &graph);
        defer bundler.deinit();
        const result = try bundler.bundle(std.testing.io);
        defer result.deinit(std.testing.allocator);
        try std.testing.expect(!result.hasErrors());
        const provider = graph.interop_ast_provider orelse {
            missing_providers += 1;
            continue;
        };
        if (!provider.active) std.debug.print("inactive interop fixture {d}\n", .{index});
        try std.testing.expect(provider.active);
        try std.testing.expectEqual(index == 8, provider.wrapped);
        const bindings = try resolveBindings(&graph);
        const module = graph.getModule(provider.module_index).?;
        try std.testing.expectEqual(@as(usize, 24), module.semantic.?.symbols.items.len);
        for (module.semantic.?.symbols.items) |row| try std.testing.expect(!row.scope_id.isNone());
        var all_modules = graph.modulesIterator();
        while (all_modules.next()) |current| {
            if (current.semantic) |semantic| {
                try std.testing.expect(semantic.runtime_identities == null or semantic.runtime_identities.?.interop_helpers == null);
                for (semantic.symbols.items) |row| {
                    try std.testing.expect(row.synthetic_kind != .esm_interop_runtime_internal_local);
                    if (row.synthetic_kind == .bundler_runtime_helper) {
                        inline for (names.ESM_INTEROP_RUNTIME_HELPERS) |helper| try std.testing.expect(!std.mem.eql(u8, row.synthetic_name, names.esmInteropRuntimeHelperBaseName(helper)));
                    }
                }
            }
        }
        var live_dependencies: usize = 0;
        all_modules = graph.modulesIterator();
        while (all_modules.next()) |current| {
            for (current.dependencies.items) |dependency| {
                if (dependency == provider.module_index) {
                    try std.testing.expect(current.is_included);
                    live_dependencies += 1;
                }
            }
        }
        try std.testing.expect(live_dependencies > 0);
        try std.testing.expect(bindings[7].?.scope_id == bindings[0].?.scope_id);
    }
    if (missing_providers != 0) std.debug.print("missing primary interop providers: {d}/{d}\n", .{ missing_providers, entries.len });
    try std.testing.expectEqual(@as(usize, 0), missing_providers);
}

test "interop AST unused and side effect only consumers do not execute a provider" {
    const Bundler = @import("bundler.zig").Bundler;
    const helpers = @import("test_helpers.zig");
    const entries = [_][]const u8{
        "import './dep.cjs'; console.log(1);",
        "import * as unused from './dep.cjs'; console.log(2);",
        "import unused from './dep.cjs'; console.log(3);",
        "import {answer as unused} from './dep.cjs'; console.log(4);",
        "require('./dep.cjs'); console.log(5);",
        "function unused() { return import('./dep.cjs'); } console.log(6);",
    };
    for (entries, 0..) |entry_source, index| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try helpers.writeFile(tmp.dir, "entry.js", entry_source);
        try helpers.writeFile(tmp.dir, "dep.cjs", "exports.answer = 42; console.log('side effect');");
        const entry = try helpers.absPath(&tmp, "entry.js");
        defer std.testing.allocator.free(entry);
        const options: @import("bundler.zig").BundleOptions = .{ .entry_points = &.{entry}, .inline_dynamic_imports = true, .minify_syntax = true };
        var cache = Bundler.initResolveCacheFromOptions(std.testing.allocator, options);
        defer cache.deinit();
        var graph = @import("graph.zig").ModuleGraph.init(std.testing.allocator, &cache);
        defer graph.deinit();
        var bundler = Bundler.initWithGraph(std.testing.allocator, options, &cache, &graph);
        defer bundler.deinit();
        const result = try bundler.bundle(std.testing.io);
        defer result.deinit(std.testing.allocator);
        try std.testing.expect(!result.hasErrors());
        if (graph.interop_ast_provider) |provider| {
            if (provider.active) std.debug.print("unexpected active interop control {d}\n", .{index});
            try std.testing.expect(!provider.active);
            try std.testing.expect(!graph.getModule(provider.module_index).?.is_included);
        }
        if (graph.dynamic_import_ast_provider) |provider| try std.testing.expect(!provider.active);
        try std.testing.expect(std.mem.indexOf(u8, result.output, "getOwnPropertyDescriptor") == null);
        if (std.mem.indexOf(u8, result.output, "__toESM") != null) std.debug.print("dead interop control {d}:\n{s}\n", .{ index, result.output });
        try std.testing.expect(std.mem.indexOf(u8, result.output, "__toESM") == null);
    }
}

test "interop AST provider cache and owner corruption fail closed across ten inputs and detached graph controls" {
    const Bundler = @import("bundler.zig").Bundler;
    const helpers = @import("test_helpers.zig");
    for (0..13) |corruption| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try helpers.writeFile(tmp.dir, "entry.js", "import * as value from './dep.cjs'; const unusedDecoy = 0; console.log(JSON.stringify(value));");
        try helpers.writeFile(tmp.dir, "dep.cjs", "exports.answer = 42;");
        const entry = try helpers.absPath(&tmp, "entry.js");
        defer std.testing.allocator.free(entry);
        const options: @import("bundler.zig").BundleOptions = .{ .entry_points = &.{entry} };
        var cache = Bundler.initResolveCacheFromOptions(std.testing.allocator, options);
        defer cache.deinit();
        var graph = @import("graph.zig").ModuleGraph.init(std.testing.allocator, &cache);
        defer graph.deinit();
        var bundler = Bundler.initWithGraph(std.testing.allocator, options, &cache, &graph);
        defer bundler.deinit();
        const result = try bundler.bundle(std.testing.io);
        defer result.deinit(std.testing.allocator);
        try std.testing.expect(!result.hasErrors());
        const original = graph.interop_ast_provider orelse return error.MissingInteropAstProvider;
        const module = graph.moduleAtMut(original.module_index).?;
        const count = module.semantic.?.symbols.items.len;
        var linker = @import("linker.zig").Linker.init(std.testing.allocator, &graph, .esm);
        defer linker.deinit();
        const source_owner = graph.moduleAtMut(graph.path_to_module.get(entry).?).?;
        const source_binding = source_owner.import_bindings[0];
        try std.testing.expect(linker.isInteropImportLive(source_owner, source_binding));
        // A spelling lookup points at an unused decoy; the exact import stays live.
        const source_semantic = &source_owner.semantic.?;
        const source_map = @constCast(&source_semantic.scope_maps[0]);
        const decoy_id = source_map.get("unusedDecoy").?;
        try source_map.put(source_owner.parse_arena.?.allocator(), "value", decoy_id);
        try std.testing.expect(linker.isInteropImportLive(source_owner, source_binding));
        const selected = try linker.esmInteropRuntimeNames();
        inline for (names.ESM_INTEROP_RUNTIME_HELPERS, 0..) |helper, index| {
            try std.testing.expectEqualStrings(module.semantic.?.symbols.items[@backingInt(original.bindings[index].?.symbol_id)].nameText(module.source), selected.get(helper));
        }
        switch (corruption) {
            0 => graph.interop_ast_provider = null,
            1 => module.semantic = null,
            2 => module.semantic.?.owner_token = .unassigned,
            3 => {
                module.semantic.?.owner_token = .unassigned;
                _ = module.semantic.?.captureOwnerToken();
            },
            4 => module.ast = null,
            5 => @constCast(module.semantic.?.symbol_ids)[@backingInt(original.bindings[0].?.node)] = null,
            6 => @constCast(module.semantic.?.symbol_ids)[@backingInt(original.bindings[0].?.node)] = @backingInt(original.bindings[1].?.symbol_id),
            7 => graph.interop_ast_provider.?.anchors.initializers[0] = .none,
            8 => graph.interop_ast_provider.?.bindings[0].?.symbol_id = original.bindings[1].?.symbol_id,
            9 => module.semantic.?.symbols.items[@backingInt(original.bindings[0].?.symbol_id)].scope_id = .none,
            10 => module.ast.?.nodes.items[@backingInt(original.root)].data.list.len = 0,
            11 => {
                _ = module.semantic.?.scope_owner_map.remove(@backingInt(original.root));
            },
            12 => module.export_bindings[0].symbol = module.export_bindings[1].symbol,
            else => unreachable,
        }
        try std.testing.expectError(error.InvalidInteropIdentity, linker.esmInteropRuntimeNames());
        if (module.semantic) |semantic| try std.testing.expectEqual(count, semantic.symbols.items.len);
    }
}

test "interop AST persistent module cache rebuilds a fresh provider owner with identical output" {
    const Bundler = @import("bundler.zig").Bundler;
    const helpers = @import("test_helpers.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try helpers.writeFile(tmp.dir, "entry.js", "import * as value from './dep.cjs'; const __copyProps = 7; console.log(JSON.stringify(value), __copyProps);");
    try helpers.writeFile(tmp.dir, "dep.cjs", "exports.answer = 42;");
    const entry = try helpers.absPath(&tmp, "entry.js");
    defer std.testing.allocator.free(entry);
    var store = @import("module_store.zig").PersistentModuleStore.init(std.testing.allocator);
    defer store.deinit();
    const options: @import("bundler.zig").BundleOptions = .{ .entry_points = &.{entry}, .module_store = &store, .minify_identifiers = true, .minify_whitespace = true };
    var cache = Bundler.initResolveCacheFromOptions(std.testing.allocator, options);
    defer cache.deinit();
    var graph = @import("graph.zig").ModuleGraph.init(std.testing.allocator, &cache);
    defer graph.deinit();
    var bundler = Bundler.initWithGraph(std.testing.allocator, options, &cache, &graph);
    defer bundler.deinit();
    var previous_output: ?[]u8 = null;
    defer if (previous_output) |value| std.testing.allocator.free(value);
    var previous_owner: @import("module.zig").SemanticOwnerToken = .unassigned;
    for (0..3) |round| {
        const result = try bundler.bundle(std.testing.io);
        defer result.deinit(std.testing.allocator);
        try std.testing.expect(!result.hasErrors());
        try std.testing.expectEqual(@as(usize, if (round == 0) 2 else 0), result.reparsed_modules.?);
        const provider = graph.interop_ast_provider orelse return error.MissingInteropAstProvider;
        try std.testing.expect(provider.active);
        try std.testing.expect(provider.semantic_owner != .unassigned and provider.semantic_owner != previous_owner);
        previous_owner = provider.semantic_owner;
        _ = try resolveBindings(&graph);
        try std.testing.expect(!store.modules.contains(source_module.interopId(.wrapped)));
        try std.testing.expect(store.modules.count() >= 2);
        if (previous_output) |expected| try std.testing.expectEqualStrings(expected, result.output) else previous_output = try std.testing.allocator.dupe(u8, result.output);
    }
}

test "interop AST repeated activation clone failure retains the previous owned state" {
    const Bundler = @import("bundler.zig").Bundler;
    const helpers = @import("test_helpers.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try helpers.writeFile(tmp.dir, "entry.js", "import * as value from './dep.cjs';console.log(value.answer);");
    try helpers.writeFile(tmp.dir, "dep.cjs", "exports.answer=42;");
    const entry = try helpers.absPath(&tmp, "entry.js");
    defer std.testing.allocator.free(entry);
    const options: @import("bundler.zig").BundleOptions = .{ .entry_points = &.{entry} };
    var cache = Bundler.initResolveCacheFromOptions(std.testing.allocator, options);
    defer cache.deinit();
    var graph = @import("graph.zig").ModuleGraph.init(std.testing.allocator, &cache);
    defer graph.deinit();
    var bundler = Bundler.initWithGraph(std.testing.allocator, options, &cache, &graph);
    defer bundler.deinit();
    const result = try bundler.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);
    var linker = @import("linker.zig").Linker.init(std.testing.allocator, &graph, .esm);
    defer linker.deinit();
    var shaker = try @import("tree_shaker.zig").TreeShaker.init(std.testing.allocator, &graph, &linker);
    defer shaker.deinit();
    shaker.reachable_stmts = try std.testing.allocator.alloc(?std.DynamicBitSet, graph.moduleCount());
    @memset(shaker.reachable_stmts, null);
    const provider = graph.interop_ast_provider.?;
    const index = provider.module_index.toU32();
    shaker.reachable_stmts[index] = try provider.reachable.?.clone(std.testing.allocator);
    shaker.included.set(index);
    const module = graph.moduleAtMut(provider.module_index).?;
    module.reachable_stmts = &shaker.reachable_stmts[index].?;
    const before = shaker.reachable_stmts[index].?;
    const before_count = before.count();
    const before_mirror = module.reachable_stmts;
    shaker.allocator = std.testing.failing_allocator;
    const failed = activate(&graph, true, &shaker);
    shaker.allocator = std.testing.allocator;
    try std.testing.expectError(error.OutOfMemory, failed);
    try std.testing.expectEqualDeep(provider, graph.interop_ast_provider.?);
    try std.testing.expectEqualDeep(before, shaker.reachable_stmts[index].?);
    try std.testing.expectEqual(before_mirror, module.reachable_stmts);
    try std.testing.expectEqual(before_count, module.reachable_stmts.?.count());
    try std.testing.expect(shaker.included.isSet(index));
    // The old state is valid for a later successful replacement and cleanup.
    try activate(&graph, true, &shaker);
    try std.testing.expect(graph.interop_ast_provider.?.wrapped);
    try std.testing.expect(shaker.reachable_stmts[index].?.count() > before_count);
}

test "interop AST verbatim imports retain only value source evaluation" {
    const Bundler = @import("bundler.zig").Bundler;
    const helpers = @import("test_helpers.zig");
    const cases = [_]struct { prefix: []const u8, verbatim: bool = true, evaluates_types: bool = false }{
        .{ .prefix = "import type {Answer} from './types.cjs';let annotation:Answer;" },
        .{ .prefix = "import type * as Types from './types.cjs';let annotation:Types.Answer;" },
        .{ .prefix = "import type Answer from './types.cjs';let annotation:Answer;" },
        .{ .prefix = "import {answer as unused} from './types.cjs';", .evaluates_types = true },
        .{ .prefix = "import * as unused from './types.cjs';", .evaluates_types = true },
        .{ .prefix = "import unused from './types.cjs';", .evaluates_types = true },
        .{ .prefix = "import unused from './types.cjs';", .verbatim = false },
    };
    for (cases) |case| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const source = try std.fmt.allocPrint(std.testing.allocator, "{s}import * as value from './runtime.cjs';console.log(value.answer);", .{case.prefix});
        defer std.testing.allocator.free(source);
        try helpers.writeFile(tmp.dir, "entry.ts", source);
        try helpers.writeFile(tmp.dir, "types.cjs", "console.log('TYPE EVALUATED');exports.answer=9;");
        try helpers.writeFile(tmp.dir, "runtime.cjs", "console.log('VALUE EVALUATED');exports.answer=42;");
        const entry = try helpers.absPath(&tmp, "entry.ts");
        defer std.testing.allocator.free(entry);
        const options: @import("bundler.zig").BundleOptions = .{ .entry_points = &.{entry}, .verbatim_module_syntax = case.verbatim };
        var cache = Bundler.initResolveCacheFromOptions(std.testing.allocator, options);
        defer cache.deinit();
        var graph = @import("graph.zig").ModuleGraph.init(std.testing.allocator, &cache);
        defer graph.deinit();
        var bundler = Bundler.initWithGraph(std.testing.allocator, options, &cache, &graph);
        defer bundler.deinit();
        const result = try bundler.bundle(std.testing.io);
        defer result.deinit(std.testing.allocator);
        try std.testing.expect(!result.hasErrors());
        try std.testing.expect(graph.interop_ast_provider.?.active);
        try std.testing.expectEqual(case.evaluates_types, std.mem.indexOf(u8, result.output, "TYPE EVALUATED") != null);
        const entry_module = graph.getModule(graph.path_to_module.get(entry).?).?;
        var linker = @import("linker.zig").Linker.init(std.testing.allocator, &graph, .esm);
        defer linker.deinit();
        var found_value = false;
        for (entry_module.import_bindings) |binding| {
            if (std.mem.eql(u8, entry_module.import_records[binding.import_record_index].specifier, "./runtime.cjs")) {
                try std.testing.expectEqual(@as(?bool, false), binding.source_type_only);
                try std.testing.expect(linker.isInteropImportLive(entry_module, binding));
                found_value = true;
            }
        }
        try std.testing.expect(found_value);
    }
}
