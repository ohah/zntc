const std = @import("std");
const helpers = @import("test_helpers.zig");
const Graph = @import("graph.zig").ModuleGraph;
const ResolveCache = @import("resolve_cache.zig").ResolveCache;
const NodeIndex = @import("../parser/ast.zig").NodeIndex;

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
