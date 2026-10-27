const std = @import("std");
const ast_mod = @import("../parser/ast.zig");

fn markedIdentity(ast: *ast_mod.Ast, ids: []const ?u32, source: []const u8, marker: []const u8) !u32 {
    const start = (std.mem.indexOf(u8, source, marker) orelse return error.MissingMarker) + marker.len;
    for (ast.nodes.items, 0..) |node, index| {
        if (node.tag != .identifier_reference and node.tag != .assignment_target_identifier) continue;
        if (node.span.start == start) return ids[index] orelse error.MissingArgumentsIdentity;
    }
    return error.MissingReference;
}

test "implicit arguments source identity respects ordinary and arrow environments" {
    const Case = struct { source: []const u8, same: bool, outer_implicit: bool, inner_implicit: bool };
    const cases = [_]Case{
        .{ .source = "function f(){/*outer*/arguments;const get=()=>/*inner*/arguments}", .same = true, .outer_implicit = true, .inner_implicit = true },
        .{ .source = "function f(){/*outer*/arguments;function g(){/*inner*/arguments}}", .same = false, .outer_implicit = true, .inner_implicit = true },
        .{ .source = "function f(arguments){/*outer*/arguments;function g(){/*inner*/arguments}}", .same = false, .outer_implicit = false, .inner_implicit = true },
        .{ .source = "function f(){let arguments=1;/*outer*/arguments;function g(){/*inner*/arguments}}", .same = false, .outer_implicit = false, .inner_implicit = true },
        .{ .source = "function f(){/*outer*/arguments;const get=arguments=>/*inner*/arguments}", .same = false, .outer_implicit = true, .inner_implicit = false },
        .{ .source = "function f(arguments){/*outer*/arguments;const get=()=>/*inner*/arguments}", .same = true, .outer_implicit = false, .inner_implicit = false },
        .{ .source = "function f(){/*outer*/arguments;{let arguments=1;const get=()=>/*inner*/arguments}}", .same = false, .outer_implicit = true, .inner_implicit = false },
        .{ .source = "function f(get=()=>/*outer*/arguments){/*inner*/arguments}", .same = true, .outer_implicit = true, .inner_implicit = true },
        .{ .source = "function f(get=()=>/*outer*/arguments){var arguments;/*inner*/arguments}", .same = false, .outer_implicit = true, .inner_implicit = false },
        .{ .source = "const f=function arguments(){/*outer*/arguments;const get=()=>/*inner*/arguments}", .same = true, .outer_implicit = true, .inner_implicit = true },
        .{ .source = "function f(){var arguments;/*outer*/arguments;const get=()=>/*inner*/arguments}", .same = true, .outer_implicit = true, .inner_implicit = true },
        .{ .source = "function f(){'use strict';/*outer*/arguments;const get=()=>/*inner*/arguments}", .same = true, .outer_implicit = true, .inner_implicit = true },
        .{ .source = "function f(get=()=>/*outer*/arguments){let arguments=1;/*inner*/arguments}", .same = false, .outer_implicit = true, .inner_implicit = false },
    };
    for (cases) |case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var scanner = try @import("../lexer/scanner.zig").Scanner.init(a, case.source);
        var parser = @import("../parser/parser.zig").Parser.init(a, &scanner);
        parser.configureFromExtension(".cjs");
        _ = try parser.parse();
        var analyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer.init(a, &parser.ast);
        try analyzer.analyze();
        try std.testing.expectEqual(@as(usize, 0), analyzer.errors.items.len);
        const outer = try markedIdentity(&parser.ast, analyzer.symbol_ids.items, case.source, "/*outer*/");
        const inner = try markedIdentity(&parser.ast, analyzer.symbol_ids.items, case.source, "/*inner*/");
        try std.testing.expectEqual(case.same, outer == inner);
        try std.testing.expectEqual(case.outer_implicit, analyzer.symbols.items[outer].synthetic_kind == .implicit_arguments);
        try std.testing.expectEqual(case.inner_implicit, analyzer.symbols.items[inner].synthetic_kind == .implicit_arguments);
        if (case.same) try std.testing.expectEqual(analyzer.symbols.items[outer].scope_id, analyzer.symbols.items[inner].scope_id);
    }
}

test "implicit arguments enum and namespace have their actual IIFE owner" {
    const Case = struct { source: []const u8, tag: ast_mod.Node.Tag, role: @import("../semantic/symbol.zig").SyntheticKind };
    const cases = [_]Case{
        .{ .source = "function f(){/*outer*/arguments;enum E{A=Number(/*inner*/arguments[0]===E)}}", .tag = .ts_enum_declaration, .role = .enum_iife_parameter },
        .{ .source = "function f(){/*outer*/arguments;namespace N{export const value=/*inner*/arguments[0]}}", .tag = .ts_module_declaration, .role = .namespace_iife_parameter },
    };
    for (cases) |case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var scanner = try @import("../lexer/scanner.zig").Scanner.init(a, case.source);
        var parser = @import("../parser/parser.zig").Parser.init(a, &scanner);
        parser.configureFromExtension(".ts");
        _ = try parser.parse();
        var analyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer.init(a, &parser.ast);
        try analyzer.analyze();
        try std.testing.expectEqual(@as(usize, 0), analyzer.errors.items.len);
        const outer = try markedIdentity(&parser.ast, analyzer.symbol_ids.items, case.source, "/*outer*/");
        const inner = try markedIdentity(&parser.ast, analyzer.symbol_ids.items, case.source, "/*inner*/");
        try std.testing.expect(outer != inner);
        const engine = analyzer.symbols.items[inner];
        try std.testing.expectEqual(@import("../semantic/symbol.zig").SyntheticKind.implicit_arguments, engine.synthetic_kind.?);
        try std.testing.expectEqual(@import("../semantic/symbol.zig").SymbolKind.parameter, engine.kind);
        var creators: usize = 0;
        for (parser.ast.nodes.items, 0..) |node, raw| {
            if (node.tag != case.tag) continue;
            const scope = analyzer.scope_owner_map.get(@intCast(raw)) orelse return error.MissingIifeScope;
            try std.testing.expectEqual(scope, @backingInt(engine.scope_id));
            try std.testing.expect(scope != @backingInt(analyzer.symbols.items[outer].scope_id));
            var parameters: usize = 0;
            for (analyzer.symbols.items) |symbol| {
                if (symbol.scope_id == engine.scope_id and symbol.synthetic_kind == case.role) {
                    try std.testing.expectEqual(@import("../semantic/symbol.zig").SymbolKind.parameter, symbol.kind);
                    parameters += 1;
                }
            }
            try std.testing.expectEqual(@as(usize, 1), parameters);
            creators += 1;
        }
        try std.testing.expectEqual(@as(usize, 1), creators);
    }
}

const live_sources = [_][]const u8{
    "function f(){const get=()=>arguments;arguments=['changed'];console.log(get()[0],arguments[0])}f('initial')",
    "function f(){const set=()=>arguments=['changed'];set();console.log(arguments[0])}f('initial')",
    "function f(){const get=()=>arguments[0];const set=()=>{arguments=['changed'];return arguments[0]};console.log(set(),get(),arguments[0])}f('initial')",
    "function f(){const get=()=>arguments;arguments+='suffix';console.log(typeof get(),get()===arguments)}f('initial')",
    "function f(){const get=()=>arguments;[arguments]=[['changed']];console.log(get()[0],arguments[0])}f('initial')",
    "function f(){const get=()=>arguments;arguments++;console.log(Number.isNaN(get()),Number.isNaN(arguments))}f('initial')",
    "function f(arguments){const get=()=>arguments;arguments='changed';console.log(get(),arguments)}f('initial')",
    "function f(){let arguments='initial';const get=()=>arguments;arguments='changed';console.log(get(),arguments)}f('input')",
    "function* f(){for(let i=0;i<2;i++){yield i;arguments=['changed'];yield(()=>arguments[0]+i)()}return arguments[0]}const g=f('initial');console.log(g.next().value,g.next().value,g.next().value,g.next().value,g.next().value)",
    "async function f(){const get=()=>arguments;await 0;arguments=['changed'];console.log(get()[0],arguments[0])}f('initial')",
    "function f(value){const get=()=>arguments[0];value='changed';console.log(get(),arguments[0])}f('initial')",
    "function f(){var arguments='initial';const get=()=>arguments;arguments='changed';console.log(get(),arguments)}f('input')",
    "function f(){const get=()=>{var arguments;return arguments};console.log(get()===undefined)}f('input')",
    "function f(arguments){const get=()=>arguments;function own(){return arguments[0]}arguments='changed';console.log(get(),own('own'))}f('initial')",
    "async function* collect(items){for await(const item of items){yield (()=>this.base+arguments.length+item)();}}(async()=>{const values=[];for await(const value of collect.call({base:10},[1,2]))values.push(value);console.log(values.join(','))})()",
    "async function* collect(items){for await(const item of items){arguments=['changed'];yield (()=>arguments[0]+item)();}}(async()=>{const values=[];for await(const value of collect([1,2]))values.push(value);console.log(values.join(','))})()",
};

test "live arguments static writes share the original cell across sixteen inputs" {
    const Options = @import("transformer.zig").TransformOptions;
    for (live_sources) |source| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const native = try std.process.run(a, std.testing.io, .{ .argv = &.{ "node", "-e", source }, .stdout_limit = .limited(16384), .stderr_limit = .limited(16384) });
        try std.testing.expectEqual(@as(u8, 0), native.term.exited);
        for ([_]bool{ false, true }) |rn| for ([_]bool{ false, true }) |minify| {
            var unsupported = if (rn) Options.compat.fromReactNativeVersion(0, 80) else Options.compat.fromESTarget(.es2022);
            unsupported.arrow = true;
            const output = try @import("../transpile.zig").transpile(a, source, "input.cjs", .{ .unsupported = unsupported, .minify_identifiers = minify, .minify_syntax = minify, .minify_whitespace = minify });
            const actual = try std.process.run(a, std.testing.io, .{ .argv = &.{ "node", "-e", output.code }, .stdout_limit = .limited(16384), .stderr_limit = .limited(16384) });
            if (actual.term != .exited or actual.term.exited != 0 or !std.mem.eql(u8, native.stdout, actual.stdout)) std.debug.print("source:{s}\ncode:{s}\nexpected:{s}actual:{s}stderr:{s}\n", .{ source, output.code, native.stdout, actual.stdout, actual.stderr });
            try std.testing.expectEqual(@as(u8, 0), actual.term.exited);
            try std.testing.expectEqualStrings(native.stdout, actual.stdout);
        };
    }
}

test "live arguments cell has exact binding engine and reference scopes before output walk" {
    const ScopeId = @import("../semantic/scope.zig").ScopeId;
    const RefFlags = @import("../semantic/symbol.zig").ReferenceFlags;
    const Options = @import("transformer.zig").TransformOptions;
    const Snapshot = struct { node: ast_mod.NodeIndex, id: u32, scope: ScopeId, flags: RefFlags };
    for (live_sources) |source| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var scanner = try @import("../lexer/scanner.zig").Scanner.init(a, source);
        var parser = @import("../parser/parser.zig").Parser.init(a, &scanner);
        parser.configureFromExtension(".cjs");
        const root = try parser.parse();
        var analyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer.init(a, &parser.ast);
        analyzer.enable_exact_declaration_anchors = true;
        try analyzer.analyze();
        var t = try @import("transformer.zig").Transformer.init(a, &parser.ast, .{ .unsupported = Options.compat.fromReactNativeVersion(0, 80) });
        try t.initSymbolIds(analyzer.symbol_ids.items);
        t.symbols = analyzer.symbols.items;
        t.references = analyzer.references.items;
        t.scopes = analyzer.scopes.items;
        t.scope_maps = analyzer.scope_maps.items;
        t.scope_owner_map = analyzer.scope_owner_map;
        t.class_self_symbol_map = analyzer.class_self_symbol_map;
        t.node_scope_provenance = analyzer.node_scope_provenance;
        t.unresolved_references = &analyzer.unresolved_references;
        t.semantic_edit_enabled = true;
        try t.buildBlockRenameMap();
        const output = try t.visitNode(root);
        if (t.live_arguments_cells.count() == 0) continue;
        var engines: std.AutoHashMapUnmanaged(u32, ScopeId) = .empty;
        var cells = t.live_arguments_cells.iterator();
        while (cells.next()) |entry| {
            const cell = entry.value_ptr;
            try std.testing.expect(!cell.declaration.isNone());
            const engine = t.semantic_editor.?.symbols.items[@backingInt(cell.engine_id)];
            const storage = t.semantic_editor.?.symbols.items[entry.key_ptr.*];
            try std.testing.expectEqual(cell.scope, engine.scope_id);
            try std.testing.expectEqual(cell.scope, storage.scope_id);
            try std.testing.expectEqual(@import("../semantic/symbol.zig").SymbolKind.variable_var, storage.kind);
            try std.testing.expectEqual(@import("../semantic/symbol.zig").SyntheticKind.implicit_arguments, engine.synthetic_kind.?);
            try engines.put(a, @backingInt(cell.engine_id), cell.scope);
        }
        var snapshots: std.ArrayList(Snapshot) = .empty;
        var bindings: std.AutoHashMapUnmanaged(u32, usize) = .empty;
        const Work = struct { node: ast_mod.NodeIndex, scope: ScopeId, ordinary: ScopeId };
        var stack: std.ArrayList(Work) = .empty;
        try stack.append(a, .{ .node = output, .scope = @fromBackingInt(0), .ordinary = .none });
        while (stack.pop()) |work| {
            if (work.node.isNone()) continue;
            const node = t.ast.getNode(work.node);
            const scope = t.outputOwnedScope(work.node) orelse work.scope;
            var ordinary = work.ordinary;
            switch (node.tag) {
                .function_declaration, .function_expression, .function => {
                    ordinary = t.outputOwnedScope(work.node) orelse return error.MissingOrdinaryFunctionOwner;
                    const params = t.ast.readExtraNode(node.data.extra, 1);
                    if (!params.isNone()) ordinary = t.outputOwnedScope(params) orelse ordinary;
                },
                else => {},
            }
            if (t.getSymbolIdAt(work.node)) |id| {
                if (t.live_arguments_cells.get(id)) |cell| {
                    if (node.tag == .binding_identifier) {
                        try std.testing.expectEqual(cell.scope, ordinary);
                        const count = try bindings.getOrPut(a, id);
                        if (!count.found_existing) count.value_ptr.* = 0;
                        count.value_ptr.* += 1;
                        var declaration_found = false;
                        for (t.semantic_editor.?.references.items) |reference| {
                            if (reference.flags.declare and reference.declaration_node_index == work.node and @backingInt(reference.symbol_id) == id) {
                                try std.testing.expectEqual(cell.scope, reference.scope_id);
                                declaration_found = true;
                            }
                        }
                        if (!declaration_found) {
                            std.debug.print("missing declaration source:{s}\nnode={d} id={d} owner={d} text={s}\n", .{ source, @backingInt(work.node), id, @backingInt(ordinary), t.ast.getText(node.data.string_ref) });
                            for (t.semantic_editor.?.references.items) |r| if (@backingInt(r.symbol_id) == id and r.flags.declare) std.debug.print("decl node={d} scope={d}\n", .{ @backingInt(r.declaration_node_index), @backingInt(r.scope_id) });
                        }
                        try std.testing.expect(declaration_found);
                    } else if (node.tag == .identifier_reference or node.tag == .assignment_target_identifier) {
                        const ref = (try t.semantic_editor.?.referenceForNode(work.node)) orelse return error.MissingCellReferenceAtCreation;
                        try std.testing.expectEqual(id, @backingInt(ref.symbol_id));
                        if (scope != ref.scope_id) std.debug.print("birth mismatch source:{s}\nnode={d} id={d} actualscope={d} recorded={d} ordinary={d}\n", .{ source, @backingInt(work.node), id, @backingInt(scope), @backingInt(ref.scope_id), @backingInt(ordinary) });
                        try std.testing.expectEqual(scope, ref.scope_id);
                        if (node.tag == .assignment_target_identifier) try std.testing.expect(ref.flags.write) else try std.testing.expect(ref.flags.read);
                        try snapshots.append(a, .{ .node = work.node, .id = id, .scope = scope, .flags = ref.flags });
                    }
                } else if (engines.get(id)) |owner| {
                    try std.testing.expectEqual(owner, ordinary);
                    const ref = (try t.semantic_editor.?.referenceForNode(work.node)) orelse return error.MissingEngineReferenceAtCreation;
                    try std.testing.expectEqual(id, @backingInt(ref.symbol_id));
                    try std.testing.expectEqual(scope, ref.scope_id);
                    try std.testing.expect(ref.flags.read and !ref.flags.write);
                    try snapshots.append(a, .{ .node = work.node, .id = id, .scope = scope, .flags = ref.flags });
                }
            }
            var children = @import("../parser/ast_walk.zig").children(t.ast, node);
            while (children.next()) |child| try stack.append(a, .{ .node = child, .scope = scope, .ordinary = ordinary });
        }
        cells = t.live_arguments_cells.iterator();
        while (cells.next()) |entry| try std.testing.expect((bindings.get(entry.key_ptr.*) orelse 0) >= 1);
        try std.testing.expect(snapshots.items.len > 0);
        t.ast.transformed_root = output;
        const final = (try t.finishSemanticEdit()) orelse return error.MissingFinalSemanticGraph;
        for (snapshots.items) |snapshot| {
            try std.testing.expectEqual(snapshot.id, final.symbol_ids[@backingInt(snapshot.node)].?);
            var found = false;
            for (final.references) |reference| if (reference.node_index == snapshot.node) {
                try std.testing.expect(!found);
                found = true;
                try std.testing.expectEqual(snapshot.id, @backingInt(reference.symbol_id));
                try std.testing.expectEqual(snapshot.scope, reference.scope_id);
                try std.testing.expectEqual(snapshot.flags, reference.flags);
            };
            try std.testing.expect(found);
        }
    }
}

test "implicit arguments static name follows analyzer lifetime without owned allocation" {
    const a = std.testing.allocator;
    var scanner = try @import("../lexer/scanner.zig").Scanner.init(a, "function f(get=()=>arguments){return get()}function g(){return arguments}");
    defer scanner.deinit();
    var parser = @import("../parser/parser.zig").Parser.init(a, &scanner);
    defer parser.deinit();
    parser.configureFromExtension(".cjs");
    _ = try parser.parse();
    var analyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer.init(a, &parser.ast);
    defer analyzer.deinit();
    try analyzer.analyze();
    var engines: usize = 0;
    for (analyzer.symbols.items) |symbol| if (symbol.synthetic_kind == .implicit_arguments) {
        try std.testing.expectEqualStrings("arguments", symbol.synthetic_name);
        engines += 1;
    };
    try std.testing.expectEqual(@as(usize, 2), engines);
}

test "implicit arguments codec23 preserves exact native owner scope and rejects prior source graphs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var scanner = try @import("../lexer/scanner.zig").Scanner.init(a, "function f(arguments){return function g(){return arguments}}function h(get=()=>arguments){var arguments;return get}");
    var parser = @import("../parser/parser.zig").Parser.init(a, &scanner);
    parser.configureFromExtension(".cjs");
    _ = try parser.parse();
    var analyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer.init(a, &parser.ast);
    analyzer.enable_exact_declaration_anchors = true;
    try analyzer.analyze();
    const sem = @import("../bundler/module.zig").ModuleSemanticData{
        .symbols = analyzer.symbols,
        .scopes = analyzer.scopes.items,
        .scope_maps = analyzer.scope_maps.items,
        .scope_owner_map = analyzer.scope_owner_map,
        .class_self_symbol_map = analyzer.class_self_symbol_map,
        .exported_names = analyzer.exported_names,
        .symbol_ids = analyzer.symbol_ids.items,
        .unresolved_references = analyzer.unresolved_references,
        .references = analyzer.references.items,
        .numeric_const_texts = analyzer.numeric_const_texts,
        .helper_scope_map = analyzer.helper_scope_map,
    };
    const codec = @import("../bundler/semantic_codec.zig");
    var bytes: std.ArrayList(u8) = .empty;
    try codec.serialize(&sem, &bytes, a);
    const loaded = try codec.deserialize(bytes.items, a);
    var engine_count: usize = 0;
    for (sem.symbols.items, 0..) |symbol, id| {
        if (symbol.synthetic_kind != .implicit_arguments) continue;
        engine_count += 1;
        try std.testing.expectEqual(symbol.synthetic_kind, loaded.symbols.items[id].synthetic_kind);
        try std.testing.expectEqual(symbol.scope_id, loaded.symbols.items[id].scope_id);
        try std.testing.expectEqualStrings("arguments", loaded.symbols.items[id].synthetic_name);
        try std.testing.expectEqual(id, loaded.scope_maps[symbol.scope_id.toIndex()].get("arguments").?);
    }
    try std.testing.expectEqual(@as(usize, 2), engine_count);
    try std.testing.expectEqualSlices(?u32, sem.symbol_ids, loaded.symbol_ids);
    const previous = try a.dupe(u8, bytes.items);
    std.mem.writeInt(u32, previous[4..8], 22, .little);
    try std.testing.expectError(error.UnsupportedVersion, codec.deserialize(previous, a));
}
