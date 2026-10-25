const std = @import("std");
const ast = @import("../parser/ast.zig");
const Scanner = @import("../lexer/scanner.zig").Scanner;
const Parser = @import("../parser/parser.zig").Parser;
const Analyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer;
const Transformer = @import("transformer.zig").Transformer;
const roles = @import("../semantic/annex_b_function.zig");

test "Annex B parameter copy owns exact references before finish in ten ordinary function environments" {
    const sources = [_][]const u8{
        "function root(value=1){{function value(){return 42}}return value}",
        "var root=function(value=1){{function value(){return 42}}return value};",
        "var root=(value=1)=>{{function value(){return 42}}return value};",
        "var object={root(value=1){{function value(){return 42}}return value}};",
        "function root({value}={value:1}){{function value(){return 42}}return value}",
        "function root(value=1,set=()=>value++){{function value(){return 42}}return value}",
        "function root(value=1,...rest){{function value(){return 42}}return value}",
        "function root(value=1){var value;{function value(){return 42}}return value}",
        "function root(value=1){{function value(){return 41}function value(){return 42}}return value}",
        "function root(value=1){try{throw 1}catch(error){{function value(){return 42}}}return value}",
    };
    for (sources, 0..) |source, case_index| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        var scanner = try Scanner.init(allocator, source);
        var parser = Parser.init(allocator, &scanner);
        _ = try parser.parse();
        var analyzer = Analyzer.init(allocator, &parser.ast);
        analyzer.enable_exact_declaration_anchors = true;
        try analyzer.analyze();
        try std.testing.expectEqual(@as(usize, 0), analyzer.errors.items.len);
        var transformer = try Transformer.init(allocator, &parser.ast, .{ .unsupported = @import("transformer.zig").TransformOptions.compat.fromESTarget(.es5) });
        try transformer.initSymbolIds(analyzer.symbol_ids.items);
        transformer.symbols = analyzer.symbols.items;
        transformer.references = analyzer.references.items;
        transformer.scopes = analyzer.scopes.items;
        transformer.scope_maps = analyzer.scope_maps.items;
        transformer.scope_owner_map = analyzer.scope_owner_map;
        transformer.node_scope_provenance = analyzer.node_scope_provenance;
        transformer.class_self_symbol_map = analyzer.class_self_symbol_map;
        transformer.unresolved_references = &analyzer.unresolved_references;
        transformer.semantic_edit_enabled = true;
        const output = try transformer.transform();
        const editor = &transformer.semantic_editor.?;
        var observed: usize = 0;
        for (analyzer.symbols.items, 0..) |symbol, lexical| {
            if (symbol.annex_b_alias.parameter_source.isNone()) continue;
            const role = (try roles.forSymbol(editor.symbols.items, @fromBackingInt(@as(u32, @intCast(lexical))))).?;
            if (role.state != .parameter_lowered) std.debug.print("Annex B copy case {d}: state={s}, plans={d}\n", .{ case_index, @tagName(role.state), transformer.parameter_body_var_copies.items.len });
            try std.testing.expectEqual(@import("../semantic/symbol.zig").AnnexBFunctionAlias.State.parameter_lowered, role.state);
            try std.testing.expectEqual(symbol.annex_b_alias.variable, role.variable);
            try std.testing.expectEqual(symbol.annex_b_alias.parameter_source, role.parameter_source);
            var mask = try roles.nativeBindingMask(std.testing.allocator, editor.symbols.items);
            defer mask.deinit();
            try std.testing.expect(mask.isSet(lexical));
            try std.testing.expect(mask.isSet(@backingInt(role.variable)));
            try std.testing.expect(!mask.isSet(@backingInt(role.parameter_source)));
            var exact_copy: usize = 0;
            const reachable = try @import("../parser/ast_walk.zig").collectReachableNodeIndicesFrom(allocator, transformer.ast, output);
            for (reachable) |raw| {
                const node = transformer.ast.nodes.items[raw];
                if (node.tag != .assignment_expression) continue;
                if (transformer.getSymbolIdAt(node.data.binary.left) != @backingInt(role.variable) or
                    transformer.getSymbolIdAt(node.data.binary.right) != @backingInt(role.parameter_source)) continue;
                var write = false;
                var read = false;
                for (editor.references.items) |reference| {
                    if (reference.node_index == node.data.binary.left and reference.symbol_id == role.variable and reference.flags.write) {
                        try std.testing.expectEqual(editor.symbols.items[@backingInt(role.variable)].scope_id, reference.scope_id);
                        write = true;
                    }
                    if (reference.node_index == node.data.binary.right and reference.symbol_id == role.parameter_source and reference.flags.read) {
                        try std.testing.expectEqual(editor.symbols.items[@backingInt(role.variable)].scope_id, reference.scope_id);
                        read = true;
                    }
                }
                try std.testing.expect(write and read);
                exact_copy += 1;
            }
            try std.testing.expectEqual(@as(usize, 1), exact_copy);
            observed += 1;
        }
        try std.testing.expect(observed > 0);
        _ = try transformer.finishSemanticEdit();
    }
}
