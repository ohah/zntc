const std = @import("std");
const helpers = @import("test_helpers.zig");
const Graph = @import("graph.zig").ModuleGraph;
const ResolveCache = @import("resolve_cache.zig").ResolveCache;
const NodeIndex = @import("../parser/ast.zig").NodeIndex;

const EngineOwnerMutation = enum {
    none,
    wrong_kind,
    unknown_role,
    wrong_reference_scope,
    wrong_scope_kind,
    missing_owner,
    arrow_owner,
    duplicate_owner,
    missing_function_owner,
    wrong_parameter_parent,
    wrong_flags,
    dangling_sid,
    duplicate_engine_sid,
    duplicate_declaration,
};

fn checkImplicitArgumentsProjection(source: []const u8, mutation: EngineOwnerMutation) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var scanner = try @import("../lexer/scanner.zig").Scanner.init(a, source);
    var parser = @import("../parser/parser.zig").Parser.init(a, &scanner);
    parser.configureFromExtension(".mjs");
    const root = try parser.parse();
    try std.testing.expectEqual(@as(usize, 0), parser.errors.items.len);
    var analyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer.init(a, &parser.ast);
    analyzer.is_module = true;
    analyzer.enable_stmt_info = true;
    analyzer.enable_exact_declaration_anchors = true;
    try analyzer.analyze();
    try std.testing.expectEqual(@as(usize, 0), analyzer.errors.items.len);
    const originals = try a.dupe(@import("../semantic/symbol.zig").Reference, analyzer.references.items);
    var semantic = @import("module.zig").ModuleSemanticData{
        .symbols = analyzer.symbols,
        .scopes = analyzer.scopes.items,
        .scope_maps = analyzer.scope_maps.items,
        .scope_owner_map = analyzer.scope_owner_map,
        .class_self_symbol_map = analyzer.class_self_symbol_map,
        .symbol_ids = analyzer.symbol_ids.items,
        .references = analyzer.references.items,
        .exported_names = analyzer.exported_names,
        .unresolved_references = analyzer.unresolved_references,
    };
    const ast = &parser.ast;
    // A real new statement shifts every top-level owner without changing any
    // source SID, ScopeId, leaf anchor or nested statement list.
    const original_list = ast.getNode(root).data.list;
    const old_statements = try a.dupe(u32, ast.extra_data.items[original_list.start..][0..original_list.len]);
    var statements: std.ArrayList(NodeIndex) = .empty;
    try statements.append(a, try ast.addNode(.{ .tag = .empty_statement, .span = .{ .start = 0, .end = 0 }, .data = .{ .none = 0 } }));
    for (old_statements) |raw| try statements.append(a, @fromBackingInt(raw));
    ast.nodes.items[@backingInt(root)].data.list = try ast.addNodeList(statements.items);
    var selected_reference: ?usize = null;
    for (semantic.references, 0..) |reference, index| {
        if (!reference.flags.declare or !reference.declaration_node_index.isNone()) continue;
        if (semantic.symbols.items[@backingInt(reference.symbol_id)].synthetic_kind == .implicit_arguments) {
            selected_reference = index;
            break;
        }
    }
    const ri = selected_reference orelse return error.MissingEngineDeclaration;
    const selected = semantic.references[ri];
    const sid = @backingInt(selected.symbol_id);
    const scope = @backingInt(selected.scope_id);
    var owner: ?u32 = null;
    var owner_iterator = semantic.scope_owner_map.iterator();
    while (owner_iterator.next()) |entry| if (entry.value_ptr.* == scope) {
        try std.testing.expect(owner == null);
        owner = entry.key_ptr.*;
    };
    const owner_raw = owner orelse return error.MissingEngineScopeOwner;
    var function: ?u32 = null;
    if (ast.nodes.items[owner_raw].tag == .formal_parameters) {
        for (ast.nodes.items, 0..) |node, raw| {
            if (node.tag != .function_declaration) continue;
            if (ast.readExtraNode(node.data.extra, 1) == @as(NodeIndex, @fromBackingInt(owner_raw))) function = @intCast(raw);
        }
    }
    switch (mutation) {
        .none => {},
        .wrong_kind => semantic.symbols.items[sid].kind = .variable_let,
        .unknown_role => semantic.symbols.items[sid].synthetic_kind = null,
        .wrong_reference_scope => analyzer.references.items[ri].scope_id = @fromBackingInt(@as(u32, 0)),
        .wrong_scope_kind => analyzer.scopes.items[scope].kind = .block,
        .missing_owner => _ = semantic.scope_owner_map.remove(owner_raw),
        .arrow_owner => ast.nodes.items[function orelse owner_raw].tag = .arrow_function_expression,
        .duplicate_owner => {
            // Distinct children keep statement containment unambiguous. Only
            // the forged second owner of the same engine ScopeId is invalid.
            const params = try ast.addFormalParameters(try ast.addNodeList(&.{}), .{ .start = 0, .end = 0 });
            const body = try ast.addNode(.{ .tag = .block_statement, .span = .{ .start = 0, .end = 0 }, .data = .{ .list = try ast.addNodeList(&.{}) } });
            const none = @backingInt(NodeIndex.none);
            const copy = try ast.addNode(.{ .tag = .function_expression, .span = .{ .start = 0, .end = 0 }, .data = .{ .extra = try ast.addExtras(&.{ none, @backingInt(params), @backingInt(body), 0, none }) } });
            if (function != null) {
                const body_scope: u32 = @intCast(analyzer.scopes.items.len);
                try analyzer.scopes.append(a, .{ .parent = selected.scope_id, .kind = .function, .is_strict = true });
                semantic.scopes = analyzer.scopes.items;
                try semantic.scope_owner_map.put(a, @backingInt(copy), body_scope);
                try semantic.scope_owner_map.put(a, @backingInt(params), scope);
            } else try semantic.scope_owner_map.put(a, @backingInt(copy), scope);
            const statement = try ast.addNode(.{ .tag = .expression_statement, .span = .{ .start = 0, .end = 0 }, .data = .{ .unary = .{ .operand = copy, .flags = 0 } } });
            try statements.append(a, statement);
            ast.nodes.items[@backingInt(root)].data.list = try ast.addNodeList(statements.items);
        },
        .missing_function_owner => _ = semantic.scope_owner_map.remove(function orelse return error.MissingParameterFunction),
        .wrong_parameter_parent => {
            const body_scope = semantic.scope_owner_map.get(function orelse return error.MissingParameterFunction).?;
            analyzer.scopes.items[body_scope].parent = @fromBackingInt(@as(u32, 0));
        },
        .wrong_flags => analyzer.references.items[ri].flags.read = true,
        .dangling_sid => analyzer.references.items[ri].symbol_id = @fromBackingInt(@as(u32, @intCast(semantic.symbols.items.len))),
        .duplicate_engine_sid => try semantic.symbols.append(a, semantic.symbols.items[sid]),
        .duplicate_declaration => {
            const duplicated = try a.alloc(@import("../semantic/symbol.zig").Reference, semantic.references.len + 1);
            @memcpy(duplicated[0..semantic.references.len], semantic.references);
            duplicated[semantic.references.len] = selected;
            semantic.references = duplicated;
        },
    }
    const projected = try @import("statement_owner_projection.zig").project(a, ast, root, &semantic);
    if (mutation != .none) {
        try std.testing.expect(projected == null);
        return;
    }
    const updated = projected orelse return error.EngineProjectionRejected;
    try std.testing.expectEqual(originals.len, updated.len);
    const contexts = try @import("../semantic/statement_coordinates.zig").collect(a, ast, root);
    var checked: usize = 0;
    for (originals, updated) |before, after| {
        try std.testing.expectEqual(before.symbol_id, after.symbol_id);
        try std.testing.expectEqual(before.scope_id, after.scope_id);
        try std.testing.expectEqual(before.node_index, after.node_index);
        try std.testing.expectEqual(before.declaration_node_index, after.declaration_node_index);
        try std.testing.expectEqual(before.flags, after.flags);
        if (!before.flags.declare or !before.declaration_node_index.isNone() or
            semantic.symbols.items[@backingInt(before.symbol_id)].synthetic_kind != .implicit_arguments) continue;
        var actual = semantic.scope_owner_map.iterator();
        var owners: usize = 0;
        while (actual.next()) |entry| {
            if (entry.value_ptr.* != @backingInt(before.scope_id)) continue;
            const expected = contexts[entry.key_ptr.*] orelse continue;
            try std.testing.expectEqual(expected.stmt_idx, after.stmt_idx);
            try std.testing.expectEqual(expected.scope_stmt_idx, after.scope_stmt_idx);
            owners += 1;
        }
        try std.testing.expectEqual(@as(usize, 1), owners);
        checked += 1;
    }
    try std.testing.expect(checked > 0);
}

test "implicit arguments coordinates follow ten actual ordinary function owners" {
    const sources = [_][]const u8{
        "function read(value){return arguments[0]}",
        "function read(value=1){return arguments[0]}",
        "async function read(value=1){return arguments[0]}",
        "function* read(value=1){yield arguments[0]}",
        "async function* read(value=1){yield arguments[0]}",
        "class Read{read(value=1){return arguments[0]}}",
        "const object={read(value=1){return arguments[0]}};",
        "function outer(){function read(value=1){return arguments[0]}return read()}",
        "function read(value){return(()=>arguments[0])()}",
        "const read=function(value=1){return arguments[0]};",
    };
    for (sources) |source| try checkImplicitArgumentsProjection(source, .none);
}

test "implicit arguments coordinates reject forged roles scopes owners and duplicates" {
    for (std.meta.tags(EngineOwnerMutation)) |mutation| {
        if (mutation == .none) continue;
        try checkImplicitArgumentsProjection("function read(value=1){return arguments[0]}", mutation);
    }
}

fn expectMapOwner(is_typescript: bool) !void {
    const bodies = [_][]const u8{
        "console.log(map);",                                           "console.log(map,filter);",  "function read(map){return map} console.log(map,read(1));",
        "function read(value=map){return value} console.log(read());", "console.log((()=>map)());", "class Read{read(){return map+filter}} console.log(new Read().read());",
        "console.log({map});",                                         "export {map};",             "console.log(map);",
        "console.log(reduce(filter(map)));",
    };
    try expectMapBodies(is_typescript, &bodies, false);
}

// Independent test oracle: an anchored row uses its actual live leaf; a typed
// native/IIFE entry uses the unique actual primary owning its existing Scope.
fn iifeReferenceContexts(a: std.mem.Allocator, ast: *@import("../parser/ast.zig").Ast, root: NodeIndex, semantic: *const @import("module.zig").ModuleSemanticData) ![]@import("statement_owner_projection.zig").Context {
    const Context = @import("statement_owner_projection.zig").Context;
    const nodes = try @import("../semantic/statement_coordinates.zig").collect(a, ast, root);
    const rows = try a.alloc(Context, semantic.references.len);
    for (semantic.references, rows) |reference, *expected| {
        const anchor = if (reference.flags.declare) reference.declaration_node_index else reference.node_index;
        if (!anchor.isNone()) {
            expected.* = nodes[@backingInt(anchor)] orelse return error.MissingLiveMapAnchor;
            continue;
        }
        const symbol = semantic.symbols.items[@backingInt(reference.symbol_id)];
        try std.testing.expect(reference.flags.declare and symbol.kind == .parameter and symbol.scope_id == reference.scope_id);
        try std.testing.expect(symbol.synthetic_kind == .implicit_arguments or symbol.synthetic_kind == .namespace_iife_parameter or symbol.synthetic_kind == .enum_iife_parameter);
        var owner: ?Context = null;
        var owners = semantic.scope_owner_map.iterator();
        while (owners.next()) |entry| {
            if (entry.value_ptr.* != @backingInt(reference.scope_id)) continue;
            const tag = ast.nodes.items[entry.key_ptr.*].tag;
            if (tag != .ts_module_declaration and tag != .ts_enum_declaration and tag != .formal_parameters and
                tag != .function_declaration and tag != .function_expression and tag != .function and tag != .method_definition) continue;
            const actual = nodes[entry.key_ptr.*] orelse continue;
            try std.testing.expect(owner == null);
            owner = actual;
        }
        expected.* = owner orelse return error.MissingLiveIifePrimary;
    }
    return rows;
}

fn expectMapBodies(is_typescript: bool, bodies: []const []const u8, iife: bool) !void {
    for (bodies, 0..) |body, index| {
        errdefer std.debug.print("Map owner TS={} IIFE={} case={d} source={s}\n", .{ is_typescript, iife, index, body });
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const names = if (iife) "map" else if (index == 1 or index == 5) "map,filter" else if (index == 9) "map,filter,reduce" else if (index == 8) "m\\u0061p" else "map";
        const source = try std.fmt.allocPrint(std.testing.allocator, "import {{{s}}} from './library.mjs';{s}", .{ names, body });
        defer std.testing.allocator.free(source);
        const filename = if (is_typescript) "consumer.ts" else "consumer.mjs";
        try helpers.writeFile(tmp.dir, filename, source);
        try helpers.writeFile(tmp.dir, "library.mjs", "export const map=1,filter=2,reduce=3;");
        if (iife) try helpers.writeFile(tmp.dir, "parts/map.mjs", "export default 1;");
        const entry = try helpers.absPath(&tmp, filename);
        defer std.testing.allocator.free(entry);
        var cache = ResolveCache.init(std.testing.allocator, .{});
        defer cache.deinit();
        var graph = Graph.init(std.testing.allocator, &cache);
        defer graph.deinit();
        const mapping = [_]@import("../transformer/options.zig").ModuleSpecifierMapEntry{.{ .module = "./library.mjs", .template = "./parts/{name}.mjs" }};
        // Runtime TS creators already require a prepass during graph.build.
        // Its cached root intentionally prevents a second transform, so supply
        // the mapping before that real producer runs.
        if (iife) graph.transform_options_base.module_specifier_map = &mapping;
        try graph.build(std.testing.io, &.{entry});
        try std.testing.expectEqual(@as(usize, 0), graph.diagnostics.items.len);
        const module = graph.moduleAtMut(graph.path_to_module.get(entry).?).?;
        const original = module.semantic.?;
        const owner = module.semantic.?.captureOwnerToken();
        const bindings = module.import_bindings;
        const before_contexts = if (iife) try iifeReferenceContexts(module.parse_arena.?.allocator(), &module.ast.?, module.ast.?.transformed_root.?, &original) else null;
        if (before_contexts) |actual| for (original.references, actual) |row, context| {
            if (row.stmt_idx != context.stmt_idx or row.scope_stmt_idx != context.scope_stmt_idx)
                std.debug.print("pre-prefix Map producer coordinate debt case={d} sid={d} scope={d} row={d}/{d} actual={d}/{d}\n", .{ index, @backingInt(row.symbol_id), @backingInt(row.scope_id), row.stmt_idx, row.scope_stmt_idx, context.stmt_idx, context.scope_stmt_idx });
            try std.testing.expectEqual(context.stmt_idx, row.stmt_idx);
            try std.testing.expectEqual(context.scope_stmt_idx, row.scope_stmt_idx);
        };
        try std.testing.expectEqual(@as(usize, if (iife) 1 else if (index == 1 or index == 5) 2 else if (index == 9) 3 else 1), bindings.len);
        if (iife) {
            try std.testing.expect(module.transform_cache != null);
            try std.testing.expectEqual(@import("../parser/ast.zig").Node.Tag.import_default_specifier, module.ast.?.getNode(bindings[0].local_symbol_node.?).tag);
            try std.testing.expectEqualStrings("./parts/map.mjs", module.import_records[bindings[0].import_record_index].specifier);
            // Move the real mapped module's statement buckets independently of
            // its binding graph, then invoke the same Map coordinate consumer.
            const ast = &module.ast.?;
            const root = ast.transformed_root.?;
            for (try @import("../parser/ast_walk.zig").collectReachableNodeIndicesFrom(module.parse_arena.?.allocator(), ast, root)) |raw| {
                const node = ast.nodes.items[raw];
                if (node.tag != .ts_module_declaration) continue;
                const primary_scope = original.scope_owner_map.get(raw) orelse return error.MissingMappedNamespacePrimary;
                try std.testing.expectEqual(@import("../semantic/scope.zig").ScopeKind.function, original.scopes[primary_scope].kind);
                try std.testing.expectEqual(@as(?u32, primary_scope), original.scope_owner_map.get(@backingInt(node.data.binary.right)));
            }
            const list = ast.getNode(root).data.list;
            const old = try module.parse_arena.?.allocator().dupe(u32, ast.extra_data.items[list.start..][0..list.len]);
            var shifted: std.ArrayList(NodeIndex) = .empty;
            try shifted.append(module.parse_arena.?.allocator(), try ast.addNode(.{ .tag = .empty_statement, .span = .{ .start = 0, .end = 0 }, .data = .{ .none = 0 } }));
            for (old) |raw| try shifted.append(module.parse_arena.?.allocator(), @fromBackingInt(raw));
            const new_list = try ast.addNodeList(shifted.items);
            ast.nodes.items[@backingInt(root)].data.list = new_list;
            module.semantic.?.references = (try @import("statement_owner_projection.zig").project(module.parse_arena.?.allocator(), ast, root, &module.semantic.?)) orelse return error.IifeMapProjectionRejected;
        } else {
            graph.transform_options_base.module_specifier_map = &mapping;
            graph.runTransformerPrePass(module, module.parse_arena.?.allocator());
        }
        const current = module.semantic.?;
        try std.testing.expectEqual(owner, current.owner_token);
        try std.testing.expectEqual(original.symbols.items.len, current.symbols.items.len);
        try std.testing.expectEqual(original.scopes.len, current.scopes.len);
        try std.testing.expectEqual(bindings.len, module.import_bindings.len);
        const after_contexts = if (iife) try iifeReferenceContexts(module.parse_arena.?.allocator(), &module.ast.?, module.ast.?.transformed_root.?, &current) else null;
        if (iife) for (original.references, current.references, before_contexts.?, after_contexts.?) |before, after, actual_before, actual_after| {
            try std.testing.expectEqual(before.symbol_id, after.symbol_id);
            try std.testing.expectEqual(before.scope_id, after.scope_id);
            try std.testing.expectEqual(before.flags, after.flags);
            try std.testing.expectEqual(before.node_index, after.node_index);
            try std.testing.expectEqual(before.declaration_node_index, after.declaration_node_index);
            try std.testing.expectEqual(actual_before.stmt_idx + 1, after.stmt_idx);
            try std.testing.expectEqual(actual_after.stmt_idx, after.stmt_idx);
            try std.testing.expectEqual(actual_after.scope_stmt_idx, after.scope_stmt_idx);
        };
        // Derive current top-level coordinates independently from actual AST
        // containment, rather than accepting the old import's statement bucket.
        var top_statements: std.AutoHashMapUnmanaged(u32, u32) = .empty;
        defer top_statements.deinit(std.testing.allocator);
        const ast = &module.ast.?;
        const root_list = ast.getNode(ast.transformed_root.?).data.list;
        for (0..root_list.len) |statement_index| {
            var pending: std.ArrayList(NodeIndex) = .empty;
            defer pending.deinit(std.testing.allocator);
            try pending.append(std.testing.allocator, @fromBackingInt(ast.extra_data.items[root_list.start + statement_index]));
            while (pending.pop()) |node| {
                if (node.isNone()) continue;
                try top_statements.put(std.testing.allocator, @backingInt(node), @intCast(statement_index));
                var children = @import("../parser/ast_walk.zig").children(ast, ast.getNode(node));
                while (children.next()) |child| try pending.append(std.testing.allocator, child);
            }
        }
        for (current.references) |reference| {
            const node = if (reference.flags.declare) reference.declaration_node_index else reference.node_index;
            if (!node.isNone()) {
                try std.testing.expectEqual(top_statements.get(@backingInt(node)).?, reference.stmt_idx);
            } else {
                const symbol = current.symbols.items[@backingInt(reference.symbol_id)];
                if (symbol.synthetic_kind == .implicit_arguments or symbol.synthetic_kind == .namespace_iife_parameter or
                    symbol.synthetic_kind == .enum_iife_parameter)
                {
                    try std.testing.expectEqual(@import("../semantic/symbol.zig").SymbolKind.parameter, symbol.kind);
                    try std.testing.expectEqual(symbol.scope_id, reference.scope_id);
                    var engine_owners = current.scope_owner_map.iterator();
                    var found_engine_owner: usize = 0;
                    while (engine_owners.next()) |engine_owner| {
                        if (engine_owner.value_ptr.* != @backingInt(reference.scope_id)) continue;
                        const statement = top_statements.get(engine_owner.key_ptr.*) orelse continue;
                        const tag = ast.nodes.items[engine_owner.key_ptr.*].tag;
                        if (tag == .block_statement or tag == .ts_module_block) continue;
                        try std.testing.expect(tag == .formal_parameters or tag == .function_declaration or
                            tag == .function_expression or tag == .function or tag == .method_definition or
                            tag == .ts_module_declaration or tag == .ts_enum_declaration);
                        try std.testing.expectEqual(statement, reference.stmt_idx);
                        found_engine_owner += 1;
                    }
                    try std.testing.expectEqual(@as(usize, 1), found_engine_owner);
                    continue;
                }
                var class_roles = current.class_self_symbol_map.valueIterator();
                var checked_class_role = false;
                while (class_roles.next()) |sid| {
                    if (sid.* != @backingInt(reference.symbol_id)) continue;
                    var owners = current.scope_owner_map.iterator();
                    while (owners.next()) |owner_entry| {
                        if (owner_entry.value_ptr.* != @backingInt(reference.scope_id)) continue;
                        const statement_index = top_statements.get(owner_entry.key_ptr.*) orelse continue;
                        try std.testing.expectEqual(statement_index, reference.stmt_idx);
                        checked_class_role = true;
                    }
                }
                try std.testing.expect(checked_class_role);
            }
        }
        for (bindings, module.import_bindings) |before, after| {
            const anchor = before.local_symbol_node.?;
            try std.testing.expectEqual(@as(?NodeIndex, anchor), after.local_symbol_node);
            const sid = original.symbol_ids[@backingInt(anchor)].?;
            try std.testing.expectEqual(@as(?u32, sid), current.symbol_ids[@backingInt(anchor)]);
            try std.testing.expectEqual(original.symbols.items[sid].scope_id, current.symbols.items[sid].scope_id);
            try std.testing.expectEqual(original.symbols.items[sid].kind, current.symbols.items[sid].kind);
            try std.testing.expectEqual(@import("../parser/ast.zig").Node.Tag.import_default_specifier, module.ast.?.getNode(anchor).tag);
        }
        var bytes: std.ArrayList(u8) = .empty;
        defer bytes.deinit(std.testing.allocator);
        try @import("module_codec.zig").serialize(ast, &current, &bytes, std.testing.allocator);
        var decoded_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer decoded_arena.deinit();
        var decoded = try @import("module_codec.zig").deserialize(bytes.items, decoded_arena.allocator());
        try std.testing.expectEqual(@import("module.zig").SemanticOwnerToken.unassigned, decoded.semantic.owner_token);
        try std.testing.expectEqualSlices(?u32, current.symbol_ids, decoded.semantic.symbol_ids);
        try std.testing.expectEqualDeep(current.references, decoded.semantic.references);
        const cached_records = try @import("import_scanner.zig").extractImports(decoded_arena.allocator(), &decoded.ast);
        const cached_bindings = try @import("binding_scanner.zig").extractImportBindings(decoded_arena.allocator(), &decoded.ast, cached_records, null);
        try std.testing.expectEqual(module.import_bindings.len, cached_bindings.len);
        for (module.import_bindings, cached_bindings) |before, restored| {
            try std.testing.expectEqual(before.local_symbol_node, restored.local_symbol_node);
            const local = @import("binding_scanner.zig").resolveImportLocalSymbol(restored, .{
                .module_index = module.index,
                .ast = &decoded.ast,
                .symbol_ids = decoded.semantic.symbol_ids,
                .symbols = decoded.semantic.symbols.items,
            });
            try std.testing.expectEqual(before.local_symbol.semanticIndex(), local.semanticIndex());
        }
    }
}

test "module map retained prepass preserves original semantic owner and bindings in ten contexts" {
    try expectMapOwner(false);
}

test "module map TypeScript value imports preserve original owner and bindings in ten contexts" {
    try expectMapOwner(true);
}

fn expectImportErasureRetirement(source: []const u8, path: []const u8, declaration_type_only: bool) !void {
    const Allocator = std.mem.Allocator;
    const Parser = @import("../parser/parser.zig").Parser;
    const Scanner = @import("../lexer/scanner.zig").Scanner;
    const SemanticAnalyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer;
    const Transformer = @import("../transformer/transformer.zig").Transformer;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator: Allocator = arena.allocator();
    var scanner = try Scanner.init(allocator, source);
    defer scanner.deinit();
    var parser = Parser.init(allocator, &scanner);
    defer parser.deinit();
    parser.configureFromExtension(path);
    const source_root = try parser.parse();

    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    defer analyzer.deinit();
    analyzer.is_module = parser.is_module;
    analyzer.is_strict_mode = parser.is_strict_mode;
    analyzer.is_ts = std.mem.endsWith(u8, path, ".ts") or std.mem.endsWith(u8, path, ".tsx");
    analyzer.enable_stmt_info = true;
    analyzer.enable_exact_declaration_anchors = true;
    try analyzer.analyze();
    try std.testing.expectEqual(@as(usize, 0), analyzer.errors.items.len);

    var import_declaration: ?NodeIndex = null;
    for (parser.ast.nodes.items, 0..) |node, raw| {
        if (node.tag == .import_declaration) {
            import_declaration = @fromBackingInt(@intCast(raw));
            break;
        }
    }
    const declaration = import_declaration orelse return error.MissingSourceImport;
    const extras = @import("../parser/module.zig").readImportDeclExtras(&parser.ast, parser.ast.getNode(declaration).data.extra);
    try std.testing.expect(extras.specs_len == 1);
    const specifier: NodeIndex = @fromBackingInt(parser.ast.extra_data.items[extras.specs_start]);
    const spec = parser.ast.getNode(specifier);
    const local = switch (spec.tag) {
        .import_specifier => spec.data.binary.right,
        .import_default_specifier, .import_namespace_specifier => specifier,
        else => return error.InvalidSourceImportSpecifier,
    };
    const source_symbol = analyzer.symbol_ids.items[@backingInt(local)] orelse return error.MissingSourceImportSymbol;

    const mapping = [_]@import("../transformer/options.zig").ModuleSpecifierMapEntry{.{ .module = "./library.mjs", .template = "./parts/{name}.mjs" }};
    var transformer = try Transformer.init(allocator, &parser.ast, .{
        .strip_types = analyzer.is_ts,
        .module_specifier_map = &mapping,
    });
    defer transformer.deinit();
    try transformer.initSymbolIds(analyzer.symbol_ids.items);
    transformer.symbols = analyzer.symbols.items;
    transformer.references = analyzer.references.items;
    transformer.scopes = analyzer.scopes.items;
    transformer.scope_maps = analyzer.scope_maps.items;
    transformer.scope_owner_map = analyzer.scope_owner_map;
    transformer.node_scope_provenance = analyzer.node_scope_provenance;
    transformer.source_owned_retirements = analyzer.source_owned_retirements;
    transformer.scope_history = analyzer.scope_history;
    transformer.class_self_symbol_map = analyzer.class_self_symbol_map;
    transformer.helper_scope_map = analyzer.helper_scope_map;
    transformer.namespace_member_owners = &analyzer.namespace_member_owners;
    transformer.namespace_declaration_owners = &analyzer.namespace_declaration_owners;
    transformer.semantic_edit_enabled = true;
    transformer.unresolved_references = &analyzer.unresolved_references;

    const output_root = try transformer.transform();
    try std.testing.expectEqual(output_root, transformer.ast.transformed_root.?);
    const edited = (try transformer.finishSemanticEdit()) orelse return error.MissingImportSemanticEdit;
    try std.testing.expectEqual(@as(usize, 1), edited.source_owned_retirements.count());
    const retired = edited.source_owned_retirements.get(source_symbol) orelse return error.MissingImportRetirementWitness;
    try std.testing.expectEqual(source_symbol, @backingInt(retired.symbol_id));
    try std.testing.expectEqual(.erased_import_binding, retired.reason);
    const receipt = retired.erased_import orelse return error.MissingImportErasureReceipt;
    try std.testing.expectEqual(declaration, receipt.declaration);
    try std.testing.expectEqual(specifier, receipt.specifier);
    try std.testing.expectEqual(local, receipt.local);
    if (declaration_type_only) {
        try std.testing.expectEqual(.declaration_type_only, receipt.policy);
    } else {
        try std.testing.expectEqual(.unused, receipt.policy);
    }
    const reachable = try @import("../parser/ast_walk.zig").collectReachableNodeIndicesFrom(allocator, transformer.ast, output_root);
    defer allocator.free(reachable);
    for (reachable) |raw| try std.testing.expect(transformer.ast.nodes.items[raw].tag != .import_declaration);
    _ = source_root;
}

test "module map receipts retain split siblings and retire only erased import identities" {
    try expectImportErasureRetirement(
        "import {unused} from './library.mjs';console.log('kept');",
        ".ts",
        false,
    );
    try expectImportErasureRetirement(
        "import type {OnlyType} from './library.mjs';export interface Box{value:OnlyType}",
        ".ts",
        true,
    );
}

test "module map retains exact anonymous default facade owner across ten expression forms" {
    const expressions = [_][]const u8{
        "map+filter",                    "({map,filter})",                    "[map,filter]", "(()=>map+filter)",
        "function(){return map+filter}", "class {read(){return map+filter}}", "(map,filter)", "map?filter:0",
        "map===filter",                  "String(map+filter)",
    };
    var owner_resets: usize = 0;
    for (expressions) |expression| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const source = try std.fmt.allocPrint(std.testing.allocator, "import {{map,filter}} from './library.mjs';export default {s};", .{expression});
        defer std.testing.allocator.free(source);
        try helpers.writeFile(tmp.dir, "consumer.mjs", source);
        try helpers.writeFile(tmp.dir, "library.mjs", "export const map=1,filter=2;");
        const entry = try helpers.absPath(&tmp, "consumer.mjs");
        defer std.testing.allocator.free(entry);
        var cache = ResolveCache.init(std.testing.allocator, .{});
        defer cache.deinit();
        var graph = Graph.init(std.testing.allocator, &cache);
        defer graph.deinit();
        try graph.build(std.testing.io, &.{entry});
        try std.testing.expectEqual(@as(usize, 0), graph.diagnostics.items.len);
        const module = graph.moduleAtMut(graph.path_to_module.get(entry).?).?;
        const old = module.semantic.?;
        const owner = module.semantic.?.captureOwnerToken();
        const facade = module.findExportBinding("default").?.symbol.semanticIndex().?;
        try std.testing.expect(old.symbols.items[facade].decl_flags.is_default_export);
        const mapping = [_]@import("../transformer/options.zig").ModuleSpecifierMapEntry{.{ .module = "./library.mjs", .template = "./parts/{name}.mjs" }};
        graph.transform_options_base.module_specifier_map = &mapping;
        graph.runTransformerPrePass(module, module.parse_arena.?.allocator());
        const current = module.semantic.?;
        if (current.owner_token != owner) {
            owner_resets += 1;
            continue;
        }
        try std.testing.expectEqual(old.symbols.items.len, current.symbols.items.len);
        try std.testing.expectEqual(old.scopes.len, current.scopes.len);
        try std.testing.expectEqual(@as(?u32, facade), module.findExportBinding("default").?.symbol.semanticIndex());
        const ast = &module.ast.?;
        const list = ast.getNode(ast.transformed_root.?).data.list;
        const export_node: NodeIndex = @fromBackingInt(ast.extra_data.items[list.start + 2]);
        try std.testing.expectEqual(@import("../parser/ast.zig").Node.Tag.export_default_declaration, ast.getNode(export_node).tag);
        try std.testing.expectEqual(@as(?u32, facade), current.symbol_ids[@backingInt(export_node)]);
        var declarations: usize = 0;
        for (current.references) |reference| {
            if (!reference.flags.declare or @backingInt(reference.symbol_id) != facade) continue;
            declarations += 1;
            try std.testing.expect(reference.declaration_node_index.isNone());
            try std.testing.expectEqual(@as(u32, 2), reference.stmt_idx);
            try std.testing.expectEqual(@as(u32, 2), reference.scope_stmt_idx);
            try std.testing.expectEqual(@as(u32, 0), @backingInt(reference.scope_id));
        }
        try std.testing.expectEqual(@as(usize, 1), declarations);
        const role = @import("default_facade_identity.zig");
        try std.testing.expectEqual(@as(?u32, facade), try role.symbolAt(ast, export_node, current.symbol_ids, current.symbols.items));
        const ids = try std.testing.allocator.dupe(?u32, current.symbol_ids);
        defer std.testing.allocator.free(ids);
        ids[@backingInt(export_node)] = null;
        try std.testing.expectEqual(@as(?u32, null), try role.symbolAt(ast, export_node, ids, current.symbols.items));
        ids[@backingInt(export_node)] = @intCast(current.symbols.items.len);
        try std.testing.expectError(error.InvalidDefaultFacade, role.symbolAt(ast, export_node, ids, current.symbols.items));
        ids[@backingInt(export_node)] = facade;
        const symbols = try std.testing.allocator.dupe(@import("../semantic/symbol.zig").Symbol, current.symbols.items);
        defer std.testing.allocator.free(symbols);
        symbols[facade].decl_flags.is_default_export = false;
        try std.testing.expectEqual(@as(?u32, null), try role.symbolAt(ast, export_node, ids, symbols));
        symbols[facade] = current.symbols.items[facade];
        symbols[facade].kind = .variable_let;
        try std.testing.expectEqual(@as(?u32, null), try role.symbolAt(ast, export_node, ids, symbols));
        symbols[facade] = current.symbols.items[facade];
        symbols[facade].scope_id = @fromBackingInt(1);
        try std.testing.expectEqual(@as(?u32, null), try role.symbolAt(ast, export_node, ids, symbols));
        var bytes: std.ArrayList(u8) = .empty;
        defer bytes.deinit(std.testing.allocator);
        try @import("module_codec.zig").serialize(ast, &current, &bytes, std.testing.allocator);
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var decoded = try @import("module_codec.zig").deserialize(bytes.items, arena.allocator());
        try std.testing.expectEqual(@import("module.zig").SemanticOwnerToken.unassigned, decoded.semantic.owner_token);
        try std.testing.expectEqual(@as(?u32, facade), try role.symbolAt(&decoded.ast, export_node, decoded.semantic.symbol_ids, decoded.semantic.symbols.items));
        try std.testing.expectEqualDeep(current.references, decoded.semantic.references);
    }
    try std.testing.expectEqual(@as(usize, 0), owner_resets);
}

const iife_coordinate_sources = [_][]const u8{
    "namespace First{export const value=map;}",
    "namespace First{export const value=arguments.length+map;}",
    "namespace First.Second{export const value=map;}",
    "namespace First{export const value=map;} namespace First{export const other=map;}",
    "namespace First{export namespace Second{export const value=map;}}",
    "enum First{Value=map}",
    "enum First{Value=arguments.length+map}",
    "namespace First{export enum Second{Value=map}}",
    "namespace First{export const read=()=>arguments[0]+map;}",
    "enum First{Value=(()=>arguments.length+map)()}",
};

test "module map retained prepass projects ten namespace enum entry role contexts" {
    try expectMapBodies(true, &iife_coordinate_sources, true);
}

const IifeOwnerMutation = enum {
    none,
    missing_all_declarations,
    missing_role_and_all_declarations,
    dead_owner_without_declarations,
    missing_parameter_declaration,
    duplicate_parameter_declaration,
    duplicate_parameter_sid,
    wrong_parameter_role,
    wrong_parameter_kind,
    wrong_parameter_scope,
    missing_primary,
    wrong_scope_kind,
    duplicate_primary,
    arbitrary_block_alias,
    wrong_canonical_alias_scope,
    duplicate_engine_sid,
    duplicate_engine_declaration,
    malformed_enum_prelude,
};

fn checkIifeEntryProjection(is_enum: bool, mutation: IifeOwnerMutation) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ast_mod = @import("../parser/ast.zig");
    const symbol_mod = @import("../semantic/symbol.zig");
    const parameter_only = mutation == .missing_all_declarations or mutation == .missing_role_and_all_declarations or mutation == .dead_owner_without_declarations;
    var scanner = try @import("../lexer/scanner.zig").Scanner.init(a, if (is_enum)
        (if (parameter_only) "enum First{Value=1}" else "enum First{Value=arguments.length}")
    else
        (if (parameter_only) "namespace First{export const value=1;}" else "namespace First{export const value=arguments.length;}"));
    var parser = @import("../parser/parser.zig").Parser.init(a, &scanner);
    parser.configureFromExtension(".ts");
    const root = try parser.parse();
    try std.testing.expectEqual(@as(usize, 0), parser.errors.items.len);
    var analyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer.init(a, &parser.ast);
    analyzer.is_module = true;
    analyzer.enable_stmt_info = true;
    analyzer.enable_exact_declaration_anchors = true;
    try analyzer.analyze();
    try std.testing.expectEqual(@as(usize, 0), analyzer.errors.items.len);
    const ast = &parser.ast;
    var semantic = @import("module.zig").ModuleSemanticData{
        .symbols = analyzer.symbols,
        .scopes = analyzer.scopes.items,
        .scope_maps = analyzer.scope_maps.items,
        .scope_owner_map = analyzer.scope_owner_map,
        .class_self_symbol_map = analyzer.class_self_symbol_map,
        .symbol_ids = analyzer.symbol_ids.items,
        .references = try a.dupe(symbol_mod.Reference, analyzer.references.items),
        .exported_names = analyzer.exported_names,
        .unresolved_references = analyzer.unresolved_references,
    };
    const mutable_references = try a.dupe(symbol_mod.Reference, semantic.references);
    semantic.references = mutable_references;
    var parameter_reference: ?usize = null;
    var engine_reference: ?usize = null;
    for (semantic.references, 0..) |reference, index| {
        if (!reference.flags.declare or !reference.declaration_node_index.isNone()) continue;
        const role = semantic.symbols.items[@backingInt(reference.symbol_id)].synthetic_kind;
        if (role == .implicit_arguments) engine_reference = index;
        if (role == @as(symbol_mod.SyntheticKind, if (is_enum) .enum_iife_parameter else .namespace_iife_parameter)) parameter_reference = index;
    }
    const pi = parameter_reference orelse return error.MissingIifeParameter;
    const ei = engine_reference;
    try std.testing.expect(parameter_only == (ei == null));
    const selected = semantic.references[pi];
    const sid = @backingInt(selected.symbol_id);
    const scope = @backingInt(selected.scope_id);
    const list = ast.getNode(root).data.list;
    const primary: NodeIndex = @fromBackingInt(ast.extra_data.items[list.start]);
    try std.testing.expectEqual(scope, semantic.scope_owner_map.get(@backingInt(primary)).?);
    // Publish only the canonical alias from the actual TS creator. The enum
    // prelude is constructed explicitly here to exercise the producer contract;
    // the retained-prepass test above separately exercises actual lowering.
    const alias = if (is_enum) try ast.addNode(.{
        .tag = .block_statement,
        .span = .{ .start = 0, .end = 0 },
        .data = .{ .list = try ast.addNodeList(&.{}) },
    }) else ast.getNode(primary).data.binary.right;
    if (is_enum) ast.extra_data.items[ast.getNode(primary).data.extra + ast_mod.EnumExtra.runtime_prelude] = @backingInt(alias);
    try semantic.scope_owner_map.put(a, @backingInt(alias), scope);
    const empty = try ast.addNode(.{ .tag = .empty_statement, .span = .{ .start = 0, .end = 0 }, .data = .{ .none = 0 } });
    ast.nodes.items[@backingInt(root)].data.list = try ast.addNodeList(&.{ empty, primary });
    switch (mutation) {
        .none => {},
        .missing_all_declarations, .missing_role_and_all_declarations, .dead_owner_without_declarations => {
            if (mutation == .missing_role_and_all_declarations) semantic.symbols.items[sid].synthetic_kind = null;
            var rows: std.ArrayList(symbol_mod.Reference) = .empty;
            for (semantic.references) |reference| {
                if (reference.flags.declare and reference.scope_id == selected.scope_id and reference.declaration_node_index.isNone()) continue;
                try rows.append(a, reference);
            }
            semantic.references = rows.items;
            if (mutation == .dead_owner_without_declarations)
                ast.nodes.items[@backingInt(root)].data.list = try ast.addNodeList(&.{empty});
        },
        .missing_parameter_declaration => mutable_references[pi].flags.declare = false,
        .duplicate_parameter_declaration, .duplicate_engine_declaration => {
            const rows = try a.alloc(symbol_mod.Reference, semantic.references.len + 1);
            @memcpy(rows[0..semantic.references.len], semantic.references);
            rows[semantic.references.len] = semantic.references[if (mutation == .duplicate_parameter_declaration) pi else ei.?];
            semantic.references = rows;
        },
        .duplicate_parameter_sid => try semantic.symbols.append(a, semantic.symbols.items[sid]),
        .duplicate_engine_sid => try semantic.symbols.append(a, semantic.symbols.items[@backingInt(semantic.references[ei.?].symbol_id)]),
        .wrong_parameter_role => semantic.symbols.items[sid].synthetic_kind = if (is_enum) .namespace_iife_parameter else .enum_iife_parameter,
        .wrong_parameter_kind => semantic.symbols.items[sid].kind = .variable_var,
        .wrong_parameter_scope => semantic.symbols.items[sid].scope_id = @fromBackingInt(@as(u32, 0)),
        .missing_primary => _ = semantic.scope_owner_map.remove(@backingInt(primary)),
        .wrong_scope_kind => analyzer.scopes.items[scope].kind = .block,
        .duplicate_primary => {
            const duplicate = try ast.addNode(ast.getNode(primary));
            // Distinct canonical bodies avoid ambiguous containment being the
            // reason for rejection; it is the same-Scope primary claim itself.
            const body = try ast.addNode(.{ .tag = .block_statement, .span = .{ .start = 0, .end = 0 }, .data = .{ .list = try ast.addNodeList(&.{}) } });
            if (is_enum) {
                const extra = ast.getNode(primary).data.extra;
                const copied = try a.dupe(u32, ast.extra_data.items[extra..][0..5]);
                copied[ast_mod.EnumExtra.members_start] = 0;
                copied[ast_mod.EnumExtra.members_len] = 0;
                copied[ast_mod.EnumExtra.name] = @backingInt(try ast.addNode(ast.getNode(ast.readExtraNode(extra, ast_mod.EnumExtra.name))));
                copied[ast_mod.EnumExtra.runtime_prelude] = @backingInt(body);
                ast.nodes.items[@backingInt(duplicate)].data.extra = try ast.addExtras(copied);
            } else {
                const copied_name = try ast.addNode(ast.getNode(ast.getNode(primary).data.binary.left));
                ast.nodes.items[@backingInt(duplicate)].data.binary.left = copied_name;
                ast.nodes.items[@backingInt(duplicate)].data.binary.right = body;
            }
            try semantic.scope_owner_map.put(a, @backingInt(duplicate), scope);
            try semantic.scope_owner_map.put(a, @backingInt(body), scope);
            ast.nodes.items[@backingInt(root)].data.list = try ast.addNodeList(&.{ empty, primary, duplicate });
        },
        .arbitrary_block_alias => {
            const block = try ast.addNode(.{ .tag = .block_statement, .span = .{ .start = 0, .end = 0 }, .data = .{ .list = try ast.addNodeList(&.{}) } });
            try semantic.scope_owner_map.put(a, @backingInt(block), scope);
            ast.nodes.items[@backingInt(root)].data.list = try ast.addNodeList(&.{ empty, primary, block });
        },
        .wrong_canonical_alias_scope => try semantic.scope_owner_map.put(a, @backingInt(alias), 0),
        .malformed_enum_prelude => {
            if (!is_enum) return;
            ast.nodes.items[@backingInt(alias)].tag = .ts_module_block;
        },
    }
    semantic.scopes = analyzer.scopes.items;
    const contexts = @import("../semantic/statement_coordinates.zig").collect(a, ast, root) catch |err| {
        if (mutation != .malformed_enum_prelude) return err;
        try std.testing.expectEqual(error.InvalidStatementList, err);
        return;
    };
    const result = try @import("implicit_arguments_statement_owner.zig").collect(a, ast, contexts, semantic.symbols.items, semantic.scopes, &semantic.scope_owner_map, semantic.references);
    if (mutation == .dead_owner_without_declarations) {
        const empty_result = result orelse return error.ErasedIifeRejected;
        try std.testing.expectEqual(@as(usize, 0), empty_result.count());
        return;
    }
    if (mutation != .none) {
        try std.testing.expect(result == null);
        return;
    }
    const projected = result orelse return error.IifeProjectionRejected;
    try std.testing.expectEqual(@as(usize, 2), projected.count());
    for ([_]usize{ pi, ei.? }) |index| {
        const before = semantic.references[index];
        const actual = projected.get(@backingInt(before.symbol_id)).?;
        try std.testing.expectEqual(@as(u32, 1), actual.stmt_idx);
        try std.testing.expectEqual(@as(u32, 1), actual.scope_stmt_idx);
    }
}

test "implicit arguments namespace enum exact entry roles and canonical aliases" {
    try checkIifeEntryProjection(false, .none);
    try checkIifeEntryProjection(true, .none);
}

test "implicit arguments namespace enum reject decoy roles duplicate owners and arbitrary aliases" {
    for (std.meta.tags(IifeOwnerMutation)) |mutation| {
        if (mutation == .none) continue;
        try checkIifeEntryProjection(false, mutation);
        try checkIifeEntryProjection(true, mutation);
    }
}
