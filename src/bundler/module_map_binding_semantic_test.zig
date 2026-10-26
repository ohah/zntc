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
    for (bodies, 0..) |body, index| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const names = if (index == 1 or index == 5) "map,filter" else if (index == 9) "map,filter,reduce" else if (index == 8) "m\\u0061p" else "map";
        const source = try std.fmt.allocPrint(std.testing.allocator, "import {{{s}}} from './library.mjs';{s}", .{ names, body });
        defer std.testing.allocator.free(source);
        const filename = if (is_typescript) "consumer.ts" else "consumer.mjs";
        try helpers.writeFile(tmp.dir, filename, source);
        try helpers.writeFile(tmp.dir, "library.mjs", "export const map=1,filter=2,reduce=3;");
        const entry = try helpers.absPath(&tmp, filename);
        defer std.testing.allocator.free(entry);
        var cache = ResolveCache.init(std.testing.allocator, .{});
        defer cache.deinit();
        var graph = Graph.init(std.testing.allocator, &cache);
        defer graph.deinit();
        try graph.build(std.testing.io, &.{entry});
        try std.testing.expectEqual(@as(usize, 0), graph.diagnostics.items.len);
        const module = graph.moduleAtMut(graph.path_to_module.get(entry).?).?;
        const original = module.semantic.?;
        const owner = module.semantic.?.captureOwnerToken();
        const bindings = module.import_bindings;
        try std.testing.expectEqual(@as(usize, if (index == 1 or index == 5) 2 else if (index == 9) 3 else 1), bindings.len);
        const mapping = [_]@import("../transformer/options.zig").ModuleSpecifierMapEntry{.{ .module = "./library.mjs", .template = "./parts/{name}.mjs" }};
        graph.transform_options_base.module_specifier_map = &mapping;
        graph.runTransformerPrePass(module, module.parse_arena.?.allocator());
        const current = module.semantic.?;
        try std.testing.expectEqual(owner, current.owner_token);
        try std.testing.expectEqual(original.symbols.items.len, current.symbols.items.len);
        try std.testing.expectEqual(original.scopes.len, current.scopes.len);
        try std.testing.expectEqual(bindings.len, module.import_bindings.len);
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
                if (symbol.synthetic_kind == .implicit_arguments) {
                    try std.testing.expectEqual(@import("../semantic/symbol.zig").SymbolKind.parameter, symbol.kind);
                    try std.testing.expectEqual(symbol.scope_id, reference.scope_id);
                    var engine_owners = current.scope_owner_map.iterator();
                    var found_engine_owner: usize = 0;
                    while (engine_owners.next()) |engine_owner| {
                        if (engine_owner.value_ptr.* != @backingInt(reference.scope_id)) continue;
                        const statement = top_statements.get(engine_owner.key_ptr.*) orelse continue;
                        const tag = ast.nodes.items[engine_owner.key_ptr.*].tag;
                        try std.testing.expect(tag == .formal_parameters or tag == .function_declaration or
                            tag == .function_expression or tag == .function or tag == .method_definition);
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
