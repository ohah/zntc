const std = @import("std");
const ast = @import("../parser/ast.zig");
const walk = @import("../parser/ast_walk.zig");
const Scanner = @import("../lexer/scanner.zig").Scanner;
const Parser = @import("../parser/parser.zig").Parser;
const Analyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer;
const Transformer = @import("transformer.zig").Transformer;
const ScopeId = @import("../semantic/scope.zig").ScopeId;

fn check(source: []const u8) !void {
    for ([_]bool{ false, true }) |native_lexical| try checkMode(source, native_lexical);
}
fn checkMode(source: []const u8, native_lexical: bool) !void {
    return checkModeWithDriver(source, native_lexical, false);
}
fn checkModeWithDriver(source: []const u8, native_lexical: bool, full_driver: bool) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var scanner = try Scanner.init(a, source);
    var parser = Parser.init(a, &scanner);
    parser.configureFromExtension(".mjs");
    const source_root = try parser.parse();
    try std.testing.expectEqual(@as(usize, 0), parser.errors.items.len);
    var analyzer = Analyzer.init(a, &parser.ast);
    analyzer.is_module = true;
    analyzer.enable_stmt_info = true;
    try analyzer.analyze();
    var unsupported = @import("transformer.zig").TransformOptions.compat.fromESTarget(.es5);
    if (native_lexical) {
        unsupported.block_scoping = false;
        unsupported.class = false;
        unsupported.object_extensions = false;
    }
    const Original = struct { sid: u32, read: bool, write: bool, stmt: u32, scope_stmt: u32 };
    var original: std.AutoHashMapUnmanaged(u32, Original) = .empty;
    for (analyzer.references.items) |ref| if (!ref.node_index.isNone() and !ref.flags.declare) {
        try original.put(a, @backingInt(ref.node_index), .{ .sid = @backingInt(ref.symbol_id), .read = ref.flags.read, .write = ref.flags.write, .stmt = ref.stmt_idx, .scope_stmt = ref.scope_stmt_idx });
    };
    var source_function_scopes: std.AutoHashMapUnmanaged(u32, ScopeId) = .empty;
    for (parser.ast.nodes.items, 0..) |node, raw| {
        if (node.tag == .function_declaration) {
            if (analyzer.scope_owner_map.get(@intCast(raw))) |owner| {
                const params = parser.ast.readExtraNode(node.data.extra, 1);
                const lexical_root = analyzer.scope_owner_map.get(@backingInt(params)) orelse owner;
                try source_function_scopes.put(a, owner, @fromBackingInt(lexical_root));
            }
        }
    }
    var t = try Transformer.init(a, &parser.ast, .{ .unsupported = unsupported });
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
    if (!full_driver) try t.buildBlockRenameMap();
    const output = if (full_driver) try t.transform() else try t.visitNode(source_root);
    const refs = try @import("../semantic/reference_walk.zig").collectIdentifierReferences(a, t.ast, output);
    var actual: std.AutoHashMapUnmanaged(u32, void) = .empty;
    for (refs) |ref| try actual.put(a, @backingInt(ref), {});
    const Work = struct { node: ast.NodeIndex, scope: ScopeId, stmt: u32 = std.math.maxInt(u32), local_stmt: u32 = std.math.maxInt(u32) };
    var stack: std.ArrayList(Work) = .empty;
    try stack.append(a, .{ .node = output, .scope = @fromBackingInt(0) });
    var output_bindings: std.AutoHashMapUnmanaged(u32, void) = .empty;
    var checked: usize = 0;
    var known_coordinates: usize = 0;
    var tracked_helper_refs: usize = 0;
    var collected_function_roots: usize = 0;
    var var_storage_checks: usize = 0;
    var published_coordinate_checks: usize = 0;
    while (stack.pop()) |work| {
        if (work.node.isNone()) continue;
        const raw = @backingInt(work.node);
        const node = t.ast.getNode(work.node);
        const scope = t.outputOwnedScope(work.node) orelse work.scope;
        const block_owner = switch (node.tag) {
            .block_statement, .for_statement, .for_in_statement, .for_of_statement, .while_statement, .do_while_statement, .switch_statement, .catch_clause => true,
            else => false,
        };
        if (block_owner and scope != work.scope) {
            if (t.semantic_editor.?.scopes.items[scope.toIndex()].parent != work.scope) std.debug.print("case-owner node={d} tag={s} scope={d} parent={d} expectedparent={d}\n", .{ raw, @tagName(node.tag), scope.toIndex(), t.semantic_editor.?.scopes.items[scope.toIndex()].parent.toIndex(), work.scope.toIndex() });
            try std.testing.expectEqual(work.scope, t.semantic_editor.?.scopes.items[scope.toIndex()].parent);
        }
        if (node.tag == .function_expression and source_function_scopes.contains(@backingInt(scope))) {
            collected_function_roots += 1;
            const params = t.ast.readExtraNode(node.data.extra, 1);
            const lexical_root = t.outputOwnedScope(params) orelse source_function_scopes.get(@backingInt(scope)) orelse scope;
            try std.testing.expectEqual(work.scope, t.semantic_editor.?.scopes.items[lexical_root.toIndex()].parent);
        }
        if (node.tag == .function_declaration) {
            const binding = t.ast.readExtraNode(node.data.extra, 0);
            if (!binding.isNone()) if (t.getSymbolIdAt(binding)) |sid| {
                if (sid < analyzer.symbols.items.len) {
                    const function_kind = switch (analyzer.symbols.items[sid].kind) {
                        .function_decl, .generator_decl, .async_function_decl, .async_generator_decl => true,
                        else => false,
                    };
                    if (function_kind) {
                        try std.testing.expectEqual(work.scope, t.semantic_editor.?.symbols.items[sid].scope_id);
                        const params = t.ast.readExtraNode(node.data.extra, 1);
                        const lexical_root = t.outputOwnedScope(params) orelse source_function_scopes.get(@backingInt(scope)) orelse scope;
                        try std.testing.expectEqual(work.scope, t.semantic_editor.?.scopes.items[lexical_root.toIndex()].parent);
                    }
                }
            };
        }
        if (node.tag == .variable_declaration and t.ast.variableDeclarationKind(node) == .@"var") {
            const start = t.ast.readExtra(node.data.extra, 1);
            const len = t.ast.readExtra(node.data.extra, 2);
            for (t.ast.extra_data.items[start .. start + len]) |declarator_raw| {
                const declarator = t.ast.getNode(@fromBackingInt(declarator_raw));
                const pattern = t.ast.readExtraNode(declarator.data.extra, 0);
                var bindings = try walk.bindingIdentifiers(a, t.ast, pattern, .{});
                defer bindings.deinit();
                while (try bindings.next()) |binding| {
                    const sid = t.getSymbolIdAt(binding) orelse return error.MissingActualVarStorageIdentity;
                    var_storage_checks += 1;
                    if (sid < analyzer.symbols.items.len) try std.testing.expectEqual(t.nearestVarScope(scope), t.semantic_editor.?.symbols.items[sid].scope_id);
                }
            }
        }
        if (node.tag == .function_declaration or node.tag == .function_expression or node.tag == .arrow_function_expression) {
            const params = t.ast.readExtraNode(node.data.extra, if (node.tag == .arrow_function_expression) 0 else 1);
            var bindings = try walk.bindingIdentifiers(a, t.ast, params, .{});
            defer bindings.deinit();
            while (try bindings.next()) |binding| try output_bindings.put(a, @backingInt(binding), {});
        }
        if (actual.contains(raw) and !output_bindings.contains(raw)) {
            if (t.tracked_runtime_helper_ref_index.get(raw)) |index| {
                tracked_helper_refs += 1;
                const tracked = t.tracked_runtime_helper_refs.items[index];
                try std.testing.expectEqual(scope, tracked.scope);
                const row = (try t.semantic_editor.?.referenceForNode(work.node)) orelse return error.MissingHelperReference;
                try std.testing.expectEqual(scope, row.scope_id);
                try std.testing.expectEqual(tracked.symbol_id, @backingInt(row.symbol_id));
            }
            const maybe_sid = t.getSymbolIdAt(work.node);
            if (original.contains(raw) and maybe_sid == null) return error.SourceReferenceLostExactIdentity;
            if (maybe_sid) |sid| {
                if (sid < analyzer.symbols.items.len or full_driver) {
                    const ref = (try t.semantic_editor.?.referenceForNode(work.node)) orelse {
                        std.debug.print("missing pre-walk reference node={d} name={s} sid={d} scope={d} source={any}\n", .{ raw, t.ast.identifierNameText(node), sid, scope.toIndex(), original.contains(raw) });
                        return error.MissingSourceReferenceBeforeOutputWalk;
                    };
                    try std.testing.expectEqual(sid, @backingInt(ref.symbol_id));
                    if (original.get(raw)) |before| {
                        try std.testing.expectEqual(before.sid, sid);
                        try std.testing.expectEqual(before.read, ref.flags.read);
                        try std.testing.expectEqual(before.write, ref.flags.write);
                        if (before.stmt != @import("../semantic/symbol.zig").Reference.NO_STMT and before.scope_stmt != @import("../semantic/symbol.zig").Reference.NO_STMT) known_coordinates += 1;
                        if (!full_driver) {
                            try std.testing.expectEqual(before.stmt, ref.stmt_idx);
                            try std.testing.expectEqual(before.scope_stmt, ref.scope_stmt_idx);
                        }
                    }
                    if (full_driver and t.generator_function_coordinate_handoffs.contains(raw)) {
                        published_coordinate_checks += 1;
                        try std.testing.expectEqual(work.stmt, ref.stmt_idx);
                        try std.testing.expectEqual(work.local_stmt, ref.scope_stmt_idx);
                    }
                    if (ref.scope_id != scope) std.debug.print("case-scope node={d} name={s} expected={d} actual={d}\n", .{ raw, t.ast.identifierNameText(node), scope.toIndex(), ref.scope_id.toIndex() });
                    try std.testing.expectEqual(scope, ref.scope_id);
                    checked += 1;
                }
            }
        }
        // Independent statement-list counter: program chooses the enclosing
        // top-level bucket; each actual block chooses its local statement.
        if (node.tag == .program or node.tag == .block_statement) {
            const list = node.data.list;
            for (t.ast.extra_data.items[list.start .. list.start + list.len], 0..) |child, i| {
                try stack.append(a, .{ .node = @fromBackingInt(child), .scope = scope, .stmt = if (node.tag == .program) @intCast(i) else work.stmt, .local_stmt = @intCast(i) });
            }
        } else if (node.tag == .switch_statement) {
            try stack.append(a, .{ .node = t.ast.readExtraNode(node.data.extra, 0), .scope = work.scope, .stmt = work.stmt, .local_stmt = work.local_stmt });
            const start = t.ast.readExtra(node.data.extra, 1);
            const len = t.ast.readExtra(node.data.extra, 2);
            for (t.ast.extra_data.items[start .. start + len]) |child| try stack.append(a, .{ .node = @fromBackingInt(child), .scope = scope, .stmt = work.stmt, .local_stmt = work.local_stmt });
        } else {
            var children = walk.children(t.ast, node);
            while (children.next()) |child| {
                const skips = @import("transformer/semantic_edit.zig").childSkipsOutputScope(t.ast, raw, @backingInt(child));
                try stack.append(a, .{ .node = child, .scope = if (skips) work.scope else scope, .stmt = work.stmt, .local_stmt = work.local_stmt });
            }
        }
    }
    if (full_driver) {
        try std.testing.expect(published_coordinate_checks > 0);
        var publications = t.generator_function_coordinate_handoffs.iterator();
        var selected: ?u32 = null;
        while (publications.next()) |entry| {
            if (entry.value_ptr.scope != t.programScope() and t.tracked_runtime_helper_ref_index.contains(entry.key_ptr.*)) {
                selected = entry.key_ptr.*;
                break;
            }
        }
        const raw = selected orelse return error.MissingNonVacuousHelperPublication;
        const publication = t.generator_function_coordinate_handoffs.get(raw).?;
        const row_index = for (t.semantic_editor.?.references.items, 0..) |row, index| {
            if (!row.flags.declare and row.node_index == @as(ast.NodeIndex, @fromBackingInt(raw))) break index;
        } else return error.MissingPublishedReferenceRow;
        const saved = t.semantic_editor.?.references.items[row_index];
        t.semantic_editor.?.references.items[row_index].scope_id = t.programScope();
        try std.testing.expectError(error.InvalidScope, @import("transformer/semantic_edit.zig").bindOutputScopesAndReferencesChecked(&t, output, t.programScope()));
        t.semantic_editor.?.references.items[row_index] = saved;

        const wrong_sid = for (t.semantic_editor.?.symbols.items, 0..) |symbol, sid| {
            if (sid != @backingInt(publication.symbol_id) and symbol.kind == t.semantic_editor.?.symbols.items[@backingInt(publication.symbol_id)].kind) break sid;
        } else return error.MissingSameKindPublicationDecoy;
        t.generator_function_coordinate_handoffs.getPtr(raw).?.symbol_id = @fromBackingInt(@as(u32, @intCast(wrong_sid)));
        try std.testing.expectError(error.InvalidSymbol, @import("transformer/semantic_edit.zig").bindOutputScopesAndReferencesChecked(&t, output, t.programScope()));
        t.generator_function_coordinate_handoffs.getPtr(raw).?.* = publication;

        _ = t.generator_function_coordinate_handoffs.remove(raw);
        try std.testing.expectError(error.InvalidNode, @import("transformer/semantic_edit.zig").bindOutputScopesAndReferencesChecked(&t, output, t.programScope()));
        try t.generator_function_coordinate_handoffs.put(a, raw, publication);

        t.generator_function_coordinate_handoffs.getPtr(raw).?.scope_stmt += 1;
        try std.testing.expectError(error.InvalidNode, @import("transformer/semantic_edit.zig").bindOutputScopesAndReferencesChecked(&t, output, t.programScope()));
        t.generator_function_coordinate_handoffs.getPtr(raw).?.* = publication;
    }
    if (source_function_scopes.count() > 1) try std.testing.expect(collected_function_roots > 0);
    if (std.mem.indexOf(u8, source, "let local=") != null) try std.testing.expect(var_storage_checks > 0);
    try std.testing.expect(checked > 0);
    try std.testing.expect(known_coordinates > 0);
    if (std.mem.indexOf(u8, source, "yield*") != null) try std.testing.expect(tracked_helper_refs > 0);
}

test "generator case source 1 before output walk" {
    try check("function* run(value){yield value;}");
}
test "generator case source 2 before output walk" {
    try check("function* run(value){let local=value;yield local;return value;}");
}
test "generator case source 3 before output walk" {
    try check("function* run(value){while(value){yield value;value--;}return value;}");
}
test "generator case source 4 before output walk" {
    try check("function* run(value){try{yield value;}catch(error){yield error;}finally{use(value);}}");
}
test "generator case source 5 before output walk" {
    try check("function* run(value){const read=()=>value;yield read();}");
}
test "generator case source 6 before output walk" {
    try check("function* run(values){for(const value of values){yield value;}}");
}
test "generator case source 7 before output walk" {
    try check("function* run(values){for(const key in values){yield key;}}");
}
test "generator case source 8 before output walk" {
    try check("function* run(value){class Box{read(){return value;}}yield new Box().read();}");
}
test "generator case source 9 before output walk" {
    try check("import{value}from\"dep\";function* run(){yield value;}");
}
test "generator case source 10 before output walk" {
    try check("function* run(value){switch(value){case 1:yield value;break;default:return value;}}");
}
test "generator case source 11 before output walk" {
    try check("async function run(value){return await value;}");
}
test "generator case source 12 before output walk" {
    try check("const run=async value=>await value;");
}
test "generator case source 13 before output walk" {
    try check("function* run(value){function* inner(){yield value;}yield* inner();}");
}
test "generator case source 14 before output walk" {
    try check("function* run(value){const box={ [value](){return value;} };yield box[value]();}");
}
test "generator case source 15 before output walk" {
    try check("function* run(value){value+=yield value;return value;}");
}

test "generator case source 16 nested switch block before output walk" {
    try check("function* run(value){switch(value){case 1:{let local=value;yield local;break;}default:{value+=1;yield value;}}}");
}
test "generator case source 17 delegated helper reference before output walk" {
    try check("function* run(values){yield* values;}");
}

test "generator case source 18 catch block function before output walk" {
    try check("function* run(value){try{yield value;throw 42;}catch(error){yield 2;function read(input){return input+error;}use(read(value));}}");
}
test "generator case source 19 recursive block function before output walk" {
    try check("function* run(value){try{yield value;throw 42;}catch(error){function read(input){return input?read(input-1):error;}yield read(2);}}");
}

test "generator case source 20 mutually recursive block functions" {
    try check("function* run(value){try{throw value;}catch(error){function even(n){return n?odd(n-1):error;}function odd(n){return n?even(n-1):error;}yield even(2);}}");
}
test "generator case source 21 separate block function cells" {
    try check("function* run(value){{function read(){return value;}yield read();}{function read(){return value+1;}yield read();}}");
}

test "generator function cells preserve native values and identity across suspension" {
    const sources = [_][]const u8{
        "function* run(){try{throw 42;}catch(error){function read(){return error;}const saved=read;yield 0;return[saved===read,read.name,read()];}}",
        "function* run(){try{throw 42;}catch(error){const saved=read;yield 0;function read(){return error;}return[saved===read,read()];}}",
        "function* run(){try{throw 42;}catch(error){function even(n){return n?odd(n-1):error;}function odd(n){return n?even(n-1):error;}yield 0;return even(4);}}",
        "function* run(){{function read(){return 41;}yield read();}{function read(){return 42;}return read();}}",
        "function* run(){function read(n){if(n){read=()=>42;return read(0);}return 1;}yield 0;return read(1);}",
        "function* run(){function read(){return local;}let local=41;yield 0;local++;return read();}",
        "function* run(){const reads=[];for(let i=0;i<2;i++){function read(){return i;}reads.push(read);yield i;}return reads.map(read=>read());}",
        "function* run(){function __proto__(a,b){return 42;}const saved=__proto__;yield 0;return[saved===__proto__,__proto__.name,__proto__.length,typeof __proto__.prototype];}",
        "function* run(){function f\\u006fo(){return 42;}const saved=foo;yield 0;return[saved===foo,foo.name,foo()];}",
        "function* run(){function read(){return 1;}function read(){return 42;}const saved=read;yield 0;return[saved===read,read()];}",
    };
    var mismatches: usize = 0;
    for ([_]bool{ true, false }) |module_mode| for ([_]bool{ false, true }) |native_lexical| for (sources, 1..) |body, case_number| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const source = try std.fmt.allocPrint(a, "{s}const iterator=run();let step;const events=[];do{{step=iterator.next();events.push([step.value,step.done]);}}while(!step.done);console.log(JSON.stringify(events));", .{body});
        const native = try std.process.run(a, std.testing.io, .{ .argv = &.{ "node", if (module_mode) "--input-type=module" else "--input-type=commonjs", "-e", source }, .stdout_limit = .limited(16384), .stderr_limit = .limited(16384) });
        try std.testing.expectEqual(@as(u8, 0), native.term.exited);
        var unsupported = @import("transformer.zig").TransformOptions.compat.fromESTarget(.es5);
        if (native_lexical) {
            unsupported.block_scoping = false;
            unsupported.class = false;
            unsupported.object_extensions = false;
        }
        for ([_]bool{ false, true }) |minify| {
            const result = try @import("../transpile.zig").transpile(a, source, if (module_mode) "input.mjs" else "input.cjs", .{ .unsupported = unsupported, .minify_identifiers = minify, .minify_syntax = minify, .minify_whitespace = minify });
            const actual = try std.process.run(a, std.testing.io, .{ .argv = &.{ "node", if (module_mode) "--input-type=module" else "--input-type=commonjs", "-e", result.code }, .stdout_limit = .limited(16384), .stderr_limit = .limited(16384) });
            if (actual.term != .exited or actual.term.exited != 0 or !std.mem.eql(u8, native.stdout, actual.stdout)) std.debug.print("function cell mismatch minify={any}\nsource:{s}\ncode:{s}\nexpected:{s}\nactual:{s}\nstderr:{s}\n", .{ minify, source, result.code, native.stdout, actual.stdout, actual.stderr });
            if (actual.term != .exited or actual.term.exited != 0 or !std.mem.eql(u8, native.stdout, actual.stdout)) {
                std.debug.print("function cell failed case={d} module={any} nativeLexical={any} minify={any}\n", .{ case_number, module_mode, native_lexical, minify });
                mismatches += 1;
            }
        }
    };
    try std.testing.expectEqual(@as(usize, 0), mismatches);
}

test "generator Annex B alias timing and FDI copies use exact source roles across ten controls" {
    const sources = [_][]const u8{
        "function* run(){const outer=()=>typeof read;{yield[typeof read,outer()];function read(){return 42}yield[typeof read,outer()];}}const it=run();console.log(JSON.stringify([it.next().value,it.next().value]));",
        "function* run(read){const outer=()=>read;{yield[typeof read,outer()];function read(){return 42}return outer();}}const it=run(7);console.log(JSON.stringify([it.next().value,it.next().value]));",
        "function* run(){var read=7;const outer=()=>read;{yield[typeof outer(),outer()];function read(){return 42}return[typeof outer(),outer()()];}}const it=run();console.log(JSON.stringify([it.next().value,it.next().value]));",
        "function* run(){const outer=()=>read;{yield read();function read(){return 1}yield outer()();function read(){return 42}return outer()();}}const it=run();console.log(JSON.stringify([it.next().value,it.next().value,it.next().value]));",
        "function* run(){const outer=()=>read;{yield typeof outer();function read(){return 41}yield outer()();}{yield outer()();function read(){return 42}return outer()();}}const it=run();console.log(JSON.stringify([it.next().value,it.next().value,it.next().value,it.next().value]));",
        "function* run(){const outer=()=>typeof read;{yield[typeof read,outer()];label:function read(){return 42}return[typeof read,outer()];}}const it=run();console.log(JSON.stringify([it.next().value,it.next().value]));",
        "let change;function* run(value=1,set=(change=()=>value++)){var value;yield value;}const it=run();change();console.log(it.next().value);",
        "let change;function* run(value=1,set=(change=()=>value++)){var value;function read(){return value}yield value;return read();}const it=run();change();console.log(JSON.stringify([it.next().value,it.next().value]));",
        "let change;async function* run(value=1,set=(change=()=>value++)){var value;function read(){return value}yield value;return read();}const it=run();change();(async()=>console.log(JSON.stringify([(await it.next()).value,(await it.next()).value])))();",
        "let change;function* run(value=1,set=(change=()=>value++)){{function value(){return 42}yield value();}return value;}const it=run();change();console.log(JSON.stringify([it.next().value,it.next().value]));",
    };
    for (sources, 0..) |source, index| for ([_]bool{ false, true }) |native_parameters| for ([_]bool{ false, true }) |minify| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const native = try std.process.run(a, std.testing.io, .{ .argv = &.{ "node", "-e", source }, .stdout_limit = .limited(16384), .stderr_limit = .limited(16384) });
        try std.testing.expectEqual(@as(u8, 0), native.term.exited);
        var unsupported = @import("transformer.zig").TransformOptions.compat.fromESTarget(.es5);
        if (native_parameters) {
            unsupported.default_params = false;
            unsupported.block_scoping = false;
            unsupported.arrow = false;
        }
        const result = try @import("../transpile.zig").transpile(a, source, "input.cjs", .{ .unsupported = unsupported, .minify_identifiers = minify, .minify_syntax = minify, .minify_whitespace = minify });
        const actual = try std.process.run(a, std.testing.io, .{ .argv = &.{ "node", "-e", result.code }, .stdout_limit = .limited(16384), .stderr_limit = .limited(16384) });
        if (actual.term != .exited or actual.term.exited != 0 or !std.mem.eql(u8, native.stdout, actual.stdout)) std.debug.print("AnnexB/FDI cell case={d} nativeParams={any} minify={any}\nsource={s}\ncode={s}\nexpected={s}\nactual={s}\nerror={s}\n", .{ index, native_parameters, minify, source, result.code, native.stdout, actual.stdout, actual.stderr });
        try std.testing.expectEqual(@as(u8, 0), actual.term.exited);
        try std.testing.expectEqualStrings(native.stdout, actual.stdout);
    };
}

test "generator FDI var storage exists in its actual wrapper before final output walk" {
    const source = "let change;async function* run(value=1,set=(change=()=>value++)){var value;function read(){return value}yield value;return read();}const it=run();change();";
    try checkModeWithDriver(source, false, true);
    try checkModeWithDriver(source, true, true);
}
