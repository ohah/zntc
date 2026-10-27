const std = @import("std");
const ast = @import("../parser/ast.zig");
const Transformer = @import("transformer.zig").Transformer;

test {
    _ = @import("transformer/control_flow.zig");
    _ = @import("deferred_super_class_lowering.zig");
}
const sources = [_][]const u8{
    "let saved;const key=Symbol(\"method\");class P{}class D extends P{x=()=>this;constructor(){saved=()=>this;super()}}const d=new D;console.log(JSON.stringify([d.x.name,saved()===d,Object.getPrototypeOf(d)===D.prototype]));",
    "let saved;const key=Symbol(\"method\");class P{}class D extends P{x=()=>7;constructor(){saved=()=>this;super()}}const d=new D;console.log(JSON.stringify([d.x.name,saved()===d,Object.getPrototypeOf(d)===D.prototype]));",
    "let saved;const key=Symbol(\"method\");class P{}class D extends P{x=function(){};constructor(){saved=()=>this;super()}}const d=new D;console.log(JSON.stringify([d.x.name,saved()===d,Object.getPrototypeOf(d)===D.prototype]));",
    "let saved;const key=Symbol(\"method\");class P{}class D extends P{x=class{};constructor(){saved=()=>this;super()}}const d=new D;console.log(JSON.stringify([d.x.name,saved()===d,Object.getPrototypeOf(d)===D.prototype]));",
    "let saved;const key=Symbol(\"method\");class P{}class D extends P{[\"__proto__\"]=()=>this;constructor(){saved=()=>this;super()}}const d=new D;console.log(JSON.stringify([d.__proto__.name,saved()===d,Object.getPrototypeOf(d)===D.prototype]));",
    "let saved;const key=Symbol(\"method\");class P{}class D extends P{x\\u0079=()=>this;constructor(){saved=()=>this;super()}}const d=new D;console.log(JSON.stringify([d.xy.name,saved()===d,Object.getPrototypeOf(d)===D.prototype]));",
    "let saved;const key=Symbol(\"method\");class P{}class D extends P{#x=()=>this;get(){return this.#x}constructor(){saved=()=>this;super()}}const d=new D;console.log(JSON.stringify([d.get().name,saved()===d,Object.getPrototypeOf(d)===D.prototype]));",
    "let saved;const key=Symbol(\"method\");class P{}class D extends P{#x=function(){};get(){return this.#x}constructor(){saved=()=>this;super()}}const d=new D;console.log(JSON.stringify([d.get().name,saved()===d,Object.getPrototypeOf(d)===D.prototype]));",
    "let saved;const key=Symbol(\"method\");class P{}class D extends P{[key]=function(){};constructor(){saved=()=>this;super()}}const d=new D;console.log(JSON.stringify([d[key].name,saved()===d,Object.getPrototypeOf(d)===D.prototype]));",
    "let saved;const key=Symbol(\"method\");class P{}class D extends P{x=function inner(){};constructor(){saved=()=>this;super()}}const d=new D;console.log(JSON.stringify([d.x.name,saved()===d,Object.getPrototypeOf(d)===D.prototype]));",
};

fn checkName(source: []const u8, case: usize) !void {
    return checkTypedName(source, source, "input.cjs", case);
}

fn checkTypedName(source: []const u8, native_source: []const u8, filename: []const u8, case: usize) !void {
    var failures: usize = 0;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const native = try std.process.run(a, std.testing.io, .{ .argv = &.{ "node", "-e", native_source } });
    try std.testing.expect(native.term == .exited and native.term.exited == 0);
    for ([_]bool{ false, true }) |minify| {
        var unsupported = @import("transformer.zig").TransformOptions.compat.fromReactNativeVersion(0, 80);
        unsupported.arrow = true;
        std.debug.print("NAME START case={d} minify={}\n", .{ case, minify });
        const result = try @import("../transpile.zig").transpile(a, source, filename, .{
            .unsupported = unsupported,
            .use_define_for_class_fields = true,
            .keep_names = true,
            .minify_identifiers = minify,
            .minify_syntax = minify,
            .minify_whitespace = minify,
        });
        const actual = try std.process.run(a, std.testing.io, .{ .argv = &.{ "node", "-e", result.code } });
        if (actual.term != .exited or actual.term.exited != 0 or !std.mem.eql(u8, native.stdout, actual.stdout)) {
            failures += 1;
            std.debug.print("NAME case={d} minify={} expected={s} actual={s} stderr={s} code={s}\n", .{ case, minify, native.stdout, actual.stdout, actual.stderr, result.code });
        }
    }
    try std.testing.expectEqual(@as(usize, 0), failures);
}
test "independent native constructor timing name 0" {
    try checkName(sources[0], 0);
}
test "independent native constructor timing name 1" {
    try checkName(sources[1], 1);
}
test "independent native constructor timing name 2" {
    try checkName(sources[2], 2);
}
test "independent native constructor timing name 3" {
    try checkName(sources[3], 3);
}
test "independent native constructor timing name 4" {
    try checkName(sources[4], 4);
}
test "independent native constructor timing name 5" {
    try checkName(sources[5], 5);
}
test "independent native constructor timing name 6" {
    try checkName(sources[6], 6);
}
test "independent native constructor timing name 7" {
    try checkName(sources[7], 7);
}
test "independent native constructor timing name 8" {
    try checkName(sources[8], 8);
}
test "independent native constructor timing name 9" {
    try checkName(sources[9], 9);
}

test "independent native constructor timing before output walker exact birth tuples" {
    try checkBirth("let saved;class P{}class D extends P{value=saved();constructor(argument){const read=()=>this;saved=read;super();console.log(this.value===this,argument)}}new D(42)");
}

fn checkBirth(source: []const u8) !void {
    return checkBirthOwned(source, false);
}

fn checkBirthOwned(source: []const u8, require_owned_clones: bool) !void {
    var unsupported = @import("transformer.zig").TransformOptions.compat.fromReactNativeVersion(0, 80);
    unsupported.arrow = true;
    return checkBirthWithOwnedOptions(source, ".cjs", unsupported, require_owned_clones, false);
}

fn checkBirthProfile(source: []const u8, unsupported: @TypeOf(@import("transformer.zig").TransformOptions.compat.fromESTarget(.es2015))) !void {
    return checkBirthWithOptions(source, ".mjs", unsupported);
}

fn checkTypedBirth(source: []const u8, extension: []const u8) !void {
    var unsupported = @import("transformer.zig").TransformOptions.compat.fromReactNativeVersion(0, 80);
    unsupported.arrow = true;
    return checkBirthWithOptions(source, extension, unsupported);
}

fn checkBirthWithOptions(source: []const u8, extension: []const u8, unsupported: @import("transformer.zig").TransformOptions.compat.UnsupportedFeatures) !void {
    return checkBirthWithOwnedOptions(source, extension, unsupported, false, false);
}

fn checkBirthWithOwnedOptions(source: []const u8, extension: []const u8, unsupported: @import("transformer.zig").TransformOptions.compat.UnsupportedFeatures, require_owned_clones: bool, require_engine_clones: bool) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var scanner = try @import("../lexer/scanner.zig").Scanner.init(a, source);
    var parser = @import("../parser/parser.zig").Parser.init(a, &scanner);
    parser.configureFromExtension(extension);
    const root = try parser.parse();
    var analyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer.init(a, &parser.ast);
    analyzer.is_module = parser.is_module;
    analyzer.is_strict_mode = parser.is_strict_mode;
    analyzer.enable_stmt_info = true;
    analyzer.enable_exact_declaration_anchors = true;
    analyzer.collect_unresolved_reference_nodes = true;
    try analyzer.analyze();
    var t = try Transformer.init(a, &parser.ast, .{ .unsupported = unsupported, .use_define_for_class_fields = true });
    try t.initSymbolIds(analyzer.symbol_ids.items);
    t.symbols = analyzer.symbols.items;
    t.references = analyzer.references.items;
    t.scopes = analyzer.scopes.items;
    t.scope_maps = analyzer.scope_maps.items;
    t.scope_owner_map = analyzer.scope_owner_map;
    t.class_self_symbol_map = analyzer.class_self_symbol_map;
    t.node_scope_provenance = analyzer.node_scope_provenance;
    t.unresolved_references = &analyzer.unresolved_references;
    t.unresolved_reference_nodes = &analyzer.unresolved_reference_nodes;
    t.semantic_edit_enabled = true;
    t.record_explicit_global_references = true;
    try t.buildBlockRenameMap();
    const output = try t.visitNode(root);
    const utils = @import("output_scope_test_utils.zig");
    var parents = try utils.buildParentMap(a, t.ast, output);
    var owners: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    for (t.ast.nodes.items, 0..) |_, raw| {
        const node: ast.NodeIndex = @fromBackingInt(@as(u32, @intCast(raw)));
        if (node != output and !parents.contains(@intCast(raw))) continue;
        if (t.outputOwnedScope(node)) |scope| try owners.put(a, @intCast(raw), @backingInt(scope));
    }
    const coords = try @import("../semantic/statement_coordinates.zig").collect(a, t.ast, output);
    if (require_owned_clones) {
        const runtime_refs = try @import("../semantic/reference_walk.zig").collectIdentifierReferences(a, t.ast, output);
        for (runtime_refs) |node| {
            const raw = @backingInt(node);
            if (t.getSymbolIdAt(node)) |id| {
                const row = (try t.semantic_editor.?.referenceForNode(node)) orelse return error.MissingRuntimeReference;
                try std.testing.expectEqual(id, @backingInt(row.symbol_id));
            } else {
                const origin = t.reference_origin_map.get(raw) orelse raw;
                if (!t.explicit_global_reference_nodes.contains(raw) and
                    !analyzer.unresolved_reference_nodes.contains(origin))
                {
                    std.debug.print("NULL RUNTIME node={d} text={s} origin={d}\n", .{ raw, t.ast.getText(t.ast.getNode(node).data.string_ref), origin });
                    return error.UnprovenRuntimeExternal;
                }
            }
        }
    }
    if (require_engine_clones) {
        try std.testing.expect(t.native_arguments_declaration_origins.count() >= 2);
        var engines = t.native_arguments_declaration_origins.iterator();
        var engine_scopes: std.AutoHashMapUnmanaged(u32, void) = .empty;
        while (engines.next()) |engine| {
            const id = engine.key_ptr.*;
            const scope = engine.value_ptr.*;
            const symbol = t.semantic_editor.?.symbols.items[id];
            try std.testing.expectEqual(scope, symbol.scope_id);
            try std.testing.expect(symbol.synthetic_kind == .implicit_arguments);
            const gop = try engine_scopes.getOrPut(a, @backingInt(scope));
            try std.testing.expect(!gop.found_existing);
            var declares: usize = 0;
            for (t.semantic_editor.?.references.items) |row| {
                if (@backingInt(row.symbol_id) != id or !row.flags.declare) continue;
                declares += 1;
                try std.testing.expectEqual(scope, row.scope_id);
                try std.testing.expect(row.stmt_idx != @import("../semantic/symbol.zig").Reference.NO_STMT);
            }
            try std.testing.expectEqual(@as(usize, 1), declares);
        }
    }
    var checked: usize = 0;
    var mismatches: usize = 0;
    for (t.semantic_editor.?.references.items) |row| {
        if (row.flags.declare or row.node_index.isNone() or !parents.contains(@backingInt(row.node_index))) continue;
        const raw = @backingInt(row.node_index);
        const actual_scope = utils.expectedScope(t.ast, output, &parents, &owners, raw) orelse return error.MissingActualScope;
        const actual = coords[raw] orelse return error.MissingActualCoordinates;
        const sid = t.getSymbolIdAt(row.node_index);
        checked += 1;
        if (sid == null or sid.? != @backingInt(row.symbol_id) or actual_scope != row.scope_id or actual.stmt_idx != row.stmt_idx or actual.scope_stmt_idx != row.scope_stmt_idx) {
            mismatches += 1;
            std.debug.print("BIRTH node={d} tag={s} sid={d} nodeSID={any} scope={d}/{d} stmt={d}/{d} scopeStmt={d}/{d}\n", .{ raw, @tagName(t.ast.getNode(row.node_index).tag), @backingInt(row.symbol_id), sid, @backingInt(row.scope_id), @backingInt(actual_scope), row.stmt_idx, actual.stmt_idx, row.scope_stmt_idx, actual.scope_stmt_idx });
        }
    }
    try std.testing.expect(checked > 5);
    try std.testing.expectEqual(@as(usize, 0), mismatches);
    if (require_owned_clones) {
        var conditional: ?ast.Node = null;
        for (t.ast.nodes.items, 0..) |node, raw| {
            if (node.tag == .if_statement and parents.contains(@intCast(raw))) {
                conditional = node;
                break;
            }
        }
        const branches = [_]ast.NodeIndex{ conditional.?.data.ternary.b, conditional.?.data.ternary.c };
        var first_nodes: std.AutoHashMapUnmanaged(u32, void) = .empty;
        var first_external: std.AutoHashMapUnmanaged(u32, void) = .empty;
        var shared_external: usize = 0;
        var first_scopes: std.AutoHashMapUnmanaged(u32, void) = .empty;
        var first_bindings: std.AutoHashMapUnmanaged(u32, void) = .empty;
        for (branches, 0..) |branch, index| {
            var stack: std.ArrayList(ast.NodeIndex) = .empty;
            try stack.append(a, branch);
            var bindings: usize = 0;
            while (stack.pop()) |node| {
                if (node.isNone()) continue;
                const raw = @backingInt(node);
                if (index == 0) {
                    const entry = try first_nodes.getOrPut(a, raw);
                    if (entry.found_existing) continue;
                } else try std.testing.expect(!first_nodes.contains(raw));
                if (t.outputOwnedScope(node)) |scope| {
                    if (index == 0) try first_scopes.put(a, @backingInt(scope), {}) else try std.testing.expect(!first_scopes.contains(@backingInt(scope)));
                }
                const value = t.ast.getNode(node);
                if (value.tag == .binding_identifier) {
                    const id = t.getSymbolIdAt(node) orelse return error.MissingClonedBinding;
                    var anchored_declarations: usize = 0;
                    for (t.semantic_editor.?.references.items) |row| {
                        if (!row.flags.declare or row.declaration_node_index != node) continue;
                        anchored_declarations += 1;
                        try std.testing.expectEqual(id, @backingInt(row.symbol_id));
                        try std.testing.expectEqual(t.semantic_editor.?.symbols.items[id].scope_id, row.scope_id);
                    }
                    try std.testing.expectEqual(@as(usize, 1), anchored_declarations);
                    bindings += 1;
                    if (index == 0) try first_bindings.put(a, id, {}) else try std.testing.expect(!first_bindings.contains(id));
                }
                var children = @import("../parser/ast_walk.zig").children(t.ast, value);
                while (children.next()) |child| try stack.append(a, child);
            }
            // References to storage outside the copied function/class stay
            // attached to the same selected identity in both physical sites.
            const branch_refs = try @import("../semantic/reference_walk.zig").collectIdentifierReferences(a, t.ast, branch);
            for (branch_refs) |ref| {
                const id = t.getSymbolIdAt(ref) orelse continue;
                const symbol_scope = t.semantic_editor.?.symbols.items[id].scope_id;
                var scope_owned_by_branch = false;
                var all_owners = owners.iterator();
                while (all_owners.next()) |owner| {
                    if (owner.value_ptr.* != @backingInt(symbol_scope)) continue;
                    var cursor: ?u32 = owner.key_ptr.*;
                    while (cursor) |node_raw| {
                        if (node_raw == @backingInt(branch)) {
                            scope_owned_by_branch = true;
                            break;
                        }
                        cursor = parents.get(node_raw);
                    }
                }
                if (scope_owned_by_branch) continue;
                if (index == 0) try first_external.put(a, id, {}) else if (first_external.contains(id)) {
                    shared_external += 1;
                }
            }
            try std.testing.expect(bindings > 0);
        }
        try std.testing.expect(shared_external > 0);
    }
    var origins = t.native_constructor_reference_origins.iterator();
    var selected: ?u32 = null;
    while (origins.next()) |entry| {
        if (parents.contains(entry.key_ptr.*) and t.tracked_runtime_helper_ref_index.contains(entry.key_ptr.*)) {
            selected = entry.key_ptr.*;
            break;
        }
    }
    if (selected == null) {
        origins = t.native_constructor_reference_origins.iterator();
        while (origins.next()) |entry| {
            if (parents.contains(entry.key_ptr.*) and entry.value_ptr.scope != t.programScope() and t.native_constructor_statement_handoffs.contains(entry.key_ptr.*)) {
                selected = entry.key_ptr.*;
                break;
            }
        }
    }
    const raw = selected orelse return error.NoConstructorHelperBirthTuple;
    const publication = t.native_constructor_statement_handoffs.get(raw).?;
    const edit = @import("transformer/semantic_edit.zig");
    for (t.ast.nodes.items, 0..) |node, index| {
        const id: ast.NodeIndex = @fromBackingInt(@as(u32, @intCast(index)));
        if (node.tag == .block_statement and parents.contains(@intCast(index)) and t.outputOwnedScope(id) == null) {
            const parent = t.ast.getNode(@fromBackingInt(parents.get(@intCast(index)).?));
            if (parent.tag == .for_of_statement or parent.tag == .for_in_statement)
                std.debug.print("UNOWNED LOOP BLOCK node={d} parent={s}\n", .{ index, @tagName(parent.tag) });
        }
    }
    try edit.bindOutputScopesAndReferencesChecked(&t, output, t.programScope());
    t.native_constructor_statement_handoffs.getPtr(raw).?.symbol_id = @fromBackingInt(@backingInt(publication.symbol_id) ^ 1);
    try std.testing.expectError(error.InvalidSymbol, edit.bindOutputScopesAndReferencesChecked(&t, output, t.programScope()));
    t.native_constructor_statement_handoffs.getPtr(raw).?.* = publication;
    t.native_constructor_statement_handoffs.getPtr(raw).?.scope = t.programScope();
    try std.testing.expectError(error.InvalidScope, edit.bindOutputScopesAndReferencesChecked(&t, output, t.programScope()));
    t.native_constructor_statement_handoffs.getPtr(raw).?.* = publication;
    t.native_constructor_statement_handoffs.getPtr(raw).?.stmt = publication.stmt ^ 1;
    try std.testing.expectError(error.InvalidNode, edit.bindOutputScopesAndReferencesChecked(&t, output, t.programScope()));
    t.native_constructor_statement_handoffs.getPtr(raw).?.* = publication;
    t.native_constructor_statement_handoffs.getPtr(raw).?.scope_stmt = publication.scope_stmt ^ 1;
    try std.testing.expectError(error.InvalidNode, edit.bindOutputScopesAndReferencesChecked(&t, output, t.programScope()));
    t.native_constructor_statement_handoffs.getPtr(raw).?.* = publication;
    _ = t.native_constructor_statement_handoffs.remove(raw);
    try std.testing.expectError(error.InvalidNode, edit.bindOutputScopesAndReferencesChecked(&t, output, t.programScope()));
    try t.native_constructor_statement_handoffs.put(a, raw, publication);
    try edit.bindOutputScopesAndReferencesChecked(&t, output, t.programScope());
}

const moved_private_sources = [_][]const u8{
    "let saved;class P{}class D extends P{#value=()=>this;read(){return this.#value}constructor(){saved=()=>this;super()}}let d=new D;console.log(JSON.stringify([d.read().name,d.read()()===d,saved()===d]));",
    "let saved,log=[];class P{constructor(){log.push(\"base\")}}class D extends P{#value=(log.push(\"field\"),function(){});read(){return this.#value}constructor(){log.push(\"before\");saved=()=>this;super();log.push(\"after\")}}new D;console.log(JSON.stringify(log));",
    "let saved;class P{}class D extends P{constructor(_this){saved=()=>this;super();this.argument=_this}#value=()=>this;read(){return this.#value}}let d=new D(42);console.log(JSON.stringify([d.read()()===d,saved()===d,d.argument]));",
    "let saved;class P{}class D extends P{#a=()=>this;#b=()=>this;read(){return[this.#a.name,this.#b.name,this.#a()===this,this.#b()===this]}constructor(){saved=()=>this;super()}}console.log(JSON.stringify(new D().read()));",
    "let saved;class P{}class D extends P{#value=()=>()=>this;read(){return this.#value()()}constructor(){saved=()=>this;super()}}let d=new D;console.log(JSON.stringify([d.read()===d,saved()===d]));",
    "let saved;class P{}class D extends P{#value=()=>function(){return this};read(){return this.#value()}constructor(){saved=()=>this;super()}}let d=new D;let f=d.read();console.log(JSON.stringify([f()===undefined,f.call(42)===42,saved()===d]));",
    "let saved;class P{get value(){return this.answer}}class D extends P{#value=()=>super.value;answer=42;read(){return this.#value()}constructor(){saved=()=>this;super()}}let d=new D;console.log(JSON.stringify([d.read(),saved()===d]));",
    "let saved;function build(){return class extends Object{#value=()=>this;read(){return this.#value}constructor(){saved=()=>this;super()}}}let D=build(),a=new D,b=new D;console.log(JSON.stringify([a.read()()===a,b.read()()===b,a.read()!==b.read()]));",
    "let saved;class Host{static build(){return class extends Object{#value=()=>this;read(){return this.#value}constructor(){saved=()=>this;super()}}}}let D=Host.build(),d=new D;console.log(JSON.stringify([d.read()()===d,saved()===d]));",
    "let saved;class P{constructor(){return{answer:42}}}class D extends P{#value=()=>this;read(){return this.#value}constructor(){saved=()=>this;super();this.get=()=>this.#value}}let d=new D;console.log(JSON.stringify([d.get()()===d,saved()===d,d.answer]));",
};
test "independent moved private field native 0" {
    try checkName(moved_private_sources[0], 100);
}
test "independent moved private field native 1" {
    try checkName(moved_private_sources[1], 101);
}
test "independent moved private field native 2" {
    try checkName(moved_private_sources[2], 102);
}
test "independent moved private field native 3" {
    try checkName(moved_private_sources[3], 103);
}
test "independent moved private field native 4" {
    try checkName(moved_private_sources[4], 104);
}
test "independent moved private field native 5" {
    try checkName(moved_private_sources[5], 105);
}
test "independent moved private field native 6" {
    try checkName(moved_private_sources[6], 106);
}
test "independent moved private field native 7" {
    try checkName(moved_private_sources[7], 107);
}
test "independent moved private field native 8" {
    try checkName(moved_private_sources[8], 108);
}
test "independent moved private field native 9" {
    try checkName(moved_private_sources[9], 109);
}

test "independent moved private before output walker exact birth tuples" {
    try checkBirth(moved_private_sources[0]);
}

test "independent moved private field native new target environment" {
    try checkName("let saved;class Host{constructor(){return class extends Object{#value=()=>new.target;read(){return this.#value()}constructor(){saved=()=>this;super()}}}}const D=new Host;let d=new D;console.log(JSON.stringify([d.read()===undefined,saved()===d]));", 110);
}

test "independent native constructor typed simple parameter" {
    try checkTypedName(
        "let saved;class P{}class D extends P{value=saved();constructor(argument:number){saved=()=>this;super();this.argument=argument}}let d=new D(42);console.log(JSON.stringify([d.value===d,d.argument]));",
        "let saved;class P{}class D extends P{value=saved();constructor(argument){saved=()=>this;super();this.argument=argument}}let d=new D(42);console.log(JSON.stringify([d.value===d,d.argument]));",
        "input.cts",
        120,
    );
}

test "independent native constructor optional simple parameter" {
    try checkTypedName(
        "let saved;class P{}class D extends P{value=saved();constructor(argument?:number){saved=()=>this;super();this.argument=argument}}let d=new D;console.log(JSON.stringify([d.value===d,d.argument===undefined]));",
        "let saved;class P{}class D extends P{value=saved();constructor(argument){saved=()=>this;super();this.argument=argument}}let d=new D;console.log(JSON.stringify([d.value===d,d.argument===undefined]));",
        "input.cts",
        121,
    );
}

test "independent native constructor parameter property timing" {
    try checkTypedName(
        "let saved;class P{}class D extends P{value=saved();constructor(public argument:number){saved=()=>this;super()}}let d=new D(42);console.log(JSON.stringify([d.value===d,d.argument]));",
        "let saved;class P{}class D extends P{value=saved();constructor(argument){saved=()=>this;super();this.argument=argument}}let d=new D(42);console.log(JSON.stringify([d.value===d,d.argument]));",
        "input.cts",
        122,
    );
}

const private_super_sources = [_][]const u8{
    "let saved,log=[];class P{}class D extends P{#x=(log.push(\"field\"),42);read(){return this.#x}constructor(){saved=()=>this;return{ok:42}}}let d=new D,e;try{saved()}catch(x){e=x.name}console.log(JSON.stringify([d.ok,e,log]));",
    "let saved,log=[];const box={set value(v){log.push([\"setter\",v.read(),saved()===v])}};class P{}class D extends P{#x=(log.push(\"field\"),42);read(){return this.#x}constructor(){saved=()=>this;box.value=super();log.push(\"body\")}}new D;console.log(JSON.stringify(log));",
    "let saved,log=[];class P{}class D extends P{#x=(log.push(\"field\"),42);read(){return this.#x}constructor(){saved=()=>this;(super(),log.push(this.read()))}}new D;console.log(JSON.stringify(log));",
    "let saved;class P{}class D extends P{#x=42;read(){return this.#x}constructor(){saved=()=>this;return super()}}let d=new D;console.log(JSON.stringify([d.read(),saved()===d]));",
    "let saved;class P{}class D extends P{#x=42;read(){return this.#x}constructor(flag){saved=()=>this;if(flag)super();else super()}}let a=new D(true),b=new D(false);console.log(JSON.stringify([a.read(),b.read(),saved()===b]));",
    "let saved,log=[];class P{constructor(fail){if(fail)throw Error(\"base\")}}class D extends P{#x=(log.push(\"field\"),42);read(){return this.#x}constructor(fail){saved=()=>this;try{super(fail)}catch(e){log.push(e.message);return{}}}}let a=new D(false);new D(true);console.log(JSON.stringify([a.read(),log]));",
    "let saved;class P{constructor(value){this.value=value}}class D extends P{#x=42;read(){return this.#x}constructor(flag){saved=()=>this;let result=flag?super(1):super(2);this.same=result===this}}let a=new D(true),b=new D(false);console.log(JSON.stringify([a.read(),a.value,a.same,b.read(),b.value,b.same]));",
    "let saved;const shared={};class P{constructor(){return shared}}class D extends P{#x=42;constructor(){saved=()=>this;return super()}static read(v){return v.#x}}let d=new D;console.log(JSON.stringify([d===shared,D.read(d),saved()===d]));",
    "let saved,log=[];class P{constructor(value){log.push([\"base\",value])}}class D extends P{#x=(log.push(\"field\"),42);constructor(value){saved=()=>this;super((log.push(\"argument\"),value));log.push(\"body\")}}new D(7);console.log(JSON.stringify(log));",
    "let saved,log=[];class P{}class D extends P{#x=(log.push(\"field\"),42);read(){return this.#x}constructor(){saved=()=>this;try{super();super()}catch(e){log.push(e.name)}log.push([this.read(),saved()===this])}}new D;console.log(JSON.stringify(log));",
};
test "independent moved private super control 0" {
    try checkName(private_super_sources[0], 200);
}
test "independent moved private super control 1" {
    try checkName(private_super_sources[1], 201);
}
test "independent moved private super control 2" {
    try checkName(private_super_sources[2], 202);
}
test "independent moved private super control 3" {
    try checkName(private_super_sources[3], 203);
}
test "independent moved private super control 4" {
    try checkName(private_super_sources[4], 204);
}
test "independent moved private super control 5" {
    try checkName(private_super_sources[5], 205);
}
test "independent moved private super control 6" {
    try checkName(private_super_sources[6], 206);
}
test "independent moved private super control 7" {
    try checkName(private_super_sources[7], 207);
}
test "independent moved private super control 8" {
    try checkName(private_super_sources[8], 208);
}
test "independent moved private super control 9" {
    try checkName(private_super_sources[9], 209);
}

test "independent moved private single super before output walker exact site tuples" {
    for ([_]usize{ 0, 1, 2, 3, 5, 7, 8 }) |index| try checkBirth(private_super_sources[index]);
}

test "independent native constructor parameter property before output walker" {
    try checkTypedBirth("let saved;class P{}class D extends P{value=saved();constructor(public argument:number){saved=()=>this;super()}}new D(42)", ".cts");
}

test "independent native constructor simple formal eligibility boundaries" {
    const cases = .{
        .{ "argument:number", true },
        .{ "argument?:number", true },
        .{ "public argument:number", true },
        .{ "private readonly argument:number", true },
        .{ "protected argument:number", true },
        .{ "argument=1", false },
        .{ "public argument:number=1", false },
        .{ "{argument}:any", false },
        .{ "[argument]:any", false },
        .{ "...argument:any[]", false },
    };
    inline for (cases) |case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const source = "class D extends Object{constructor(" ++ case[0] ++ "){super()}}";
        var scanner = try @import("../lexer/scanner.zig").Scanner.init(a, source);
        var parser = @import("../parser/parser.zig").Parser.init(a, &scanner);
        parser.configureFromExtension(".cts");
        const root = try parser.parse();
        const live = try @import("../parser/ast_walk.zig").collectReachableNodeIndicesFrom(a, &parser.ast, root);
        var checked: usize = 0;
        for (live) |raw| {
            const node = parser.ast.getNode(@fromBackingInt(raw));
            if (node.tag != .method_definition) continue;
            const params = parser.ast.getNode(parser.ast.readExtraNode(node.data.extra, ast.MethodExtra.params)).data.list;
            try std.testing.expectEqual(@as(u32, 1), params.len);
            const binding = @import("native_constructor_timing.zig").simpleFormalBinding(.{ .ast = &parser.ast }, parser.ast.readExtraNode(params.start, 0));
            try std.testing.expectEqual(case[1], binding != null);
            checked += 1;
        }
        try std.testing.expectEqual(@as(usize, 1), checked);
    }
}

test "independent native constructor escaped parameter property ordering" {
    try checkTypedName(
        "let saved,log=[];class P{}class D extends P{value=(log.push(this.arg),saved());constructor(public \\u0061rg:number){saved=()=>this;super();log.push(this.arg)}}let d=new D(42);console.log(JSON.stringify([d.value===d,d.arg,log]));",
        "let saved,log=[];class P{}class D extends P{value=(log.push(this.arg),saved());constructor(arg){saved=()=>this;super();this.arg=arg;log.push(this.arg)}}let d=new D(42);console.log(JSON.stringify([d.value===d,d.arg,log]));",
        "input.cts",
        123,
    );
}

test "independent default constructor native arguments before output walker" {
    try checkBirthWithOptions("class P{}class D extends P{}new D(42)", ".mjs", @import("transformer.zig").TransformOptions.compat.fromESTarget(.es5));
}

test "independent private forof getter before output walker" {
    try checkBirthProfile("class CLong {\n  #x = 0;\n  run() {\n    const seen = [];\n    for (this.#x of [1, 2]) seen.push(this.#x);\n    return seen.join() + ':' + this.#x;\n  }\n}\nconsole.log(new CLong().run());\n", @import("transformer.zig").TransformOptions.compat.fromESTarget(.es2015));
}

test "independent private forof getter ES2017 before output walker" {
    try checkBirthProfile("class CLong {\n  #x = 0;\n  run() {\n    const seen = [];\n    for (this.#x of [1, 2]) seen.push(this.#x);\n    return seen.join() + ':' + this.#x;\n  }\n}\nconsole.log(new CLong().run());\n", @import("transformer.zig").TransformOptions.compat.fromESTarget(.es2017));
}

test "independent private forof getter six exact minify runtime controls" {
    const source = "class CLong {\n  #x = 0;\n  run() {\n    const seen = [];\n    for (this.#x of [1, 2]) seen.push(this.#x);\n    return seen.join() + ':' + this.#x;\n  }\n}\nconsole.log(new CLong().run());\n";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const native = try std.process.run(a, std.testing.io, .{ .argv = &.{ "node", "-e", source } });
    try std.testing.expect(native.term == .exited and native.term.exited == 0);
    for ([_]@import("compat.zig").ESTarget{ .es2015, .es2017 }) |target| {
        for ([_]struct { syntax: bool, identifiers: bool }{ .{ .syntax = true, .identifiers = false }, .{ .syntax = false, .identifiers = true }, .{ .syntax = true, .identifiers = true } }) |mode| {
            const result = try @import("../transpile.zig").transpile(a, source, "input.mjs", .{
                .unsupported = @import("transformer.zig").TransformOptions.compat.fromESTarget(target),
                .minify_syntax = mode.syntax,
                .minify_identifiers = mode.identifiers,
            });
            const actual = try std.process.run(a, std.testing.io, .{ .argv = &.{ "node", "-e", result.code } });
            if (actual.term != .exited or actual.term.exited != 0 or !std.mem.eql(u8, native.stdout, actual.stdout)) std.debug.print("FOROF target={s} syntax={} identifiers={} actual={s} stderr={s} code={s}\n", .{ @tagName(target), mode.syntax, mode.identifiers, actual.stdout, actual.stderr, result.code });
            try std.testing.expect(actual.term == .exited and actual.term.exited == 0);
            try std.testing.expectEqualStrings(native.stdout, actual.stdout);
        }
    }
}

const private_owned_clone_sources = [_][]const u8{
    "let saved;class P{}class D extends P{#value=()=>this;read(){return this.#value}constructor(flag){saved=()=>this;if(flag){let _this=11;super();this.argument=_this}else{let _this=22;super();this.argument=_this}}}const a=new D(true),b=new D(false);console.log(JSON.stringify([a.read().name,b.read().name,a.read()()===a,b.read()()===b,a.argument,b.argument]));",
    "let saved;class P{}class D extends P{#value=function named(parameter){let local=parameter;local++;return()=>[named,local,this]};read(){return this.#value}constructor(flag){saved=()=>this;if(flag){super()}else{super()}}}const a=new D(true),b=new D(false),f=a.read(),g=b.read();const x=f.call(a,7)(),y=g.call(b,11)();console.log(JSON.stringify([f.name,g.name,x[0]===f,y[0]===g,x[1],y[1],x[2]===a,y[2]===b]));",
    "let saved;class P{}class D extends P{#value=class Inner{read(){return Inner}};read(){return this.#value}constructor(flag){saved=()=>this;if(flag){super()}else{super()}}}const a=new D(true),b=new D(false),A=a.read(),B=b.read();console.log(JSON.stringify([A.name,B.name,new A().read()===A,new B().read()===B,A!==B]));",
    "let saved;class P{}class D extends P{#value=function named(value){return()=>arguments[0]};read(){return this.#value}constructor(flag){saved=()=>this;if(flag){super()}else{super()}}}const a=new D(true),b=new D(false);console.log(JSON.stringify([a.read()(11)(),b.read()(22)()]));",
};
test "independent moved private owned clone native 0" {
    try checkName(private_owned_clone_sources[0], 300);
}
test "independent moved private owned clone native 1" {
    try checkName(private_owned_clone_sources[1], 301);
}
test "independent moved private owned clone native 2" {
    try checkName(private_owned_clone_sources[2], 302);
}

test "independent moved private multi super before output walker exact site tuples" {
    for ([_]usize{ 4, 6, 9 }) |index| try checkBirth(private_super_sources[index]);
    for (private_owned_clone_sources) |source| try checkBirthOwned(source, true);
}

test "independent moved private owned clone native 3" {
    try checkName(private_owned_clone_sources[3], 303);
}

test "independent moved private actual engine clone before output walker" {
    var unsupported = @import("transformer.zig").TransformOptions.compat.fromReactNativeVersion(0, 80);
    unsupported.arrow = true;
    try checkBirthWithOwnedOptions(private_owned_clone_sources[3], ".cjs", unsupported, true, true);
}

test "independent initializer clone exact named role rejects foreign identities" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var scanner = try @import("../lexer/scanner.zig").Scanner.init(a, "const first=function alpha(){return()=>this};const second=function beta(){return()=>this};first();second();");
    var parser = @import("../parser/parser.zig").Parser.init(a, &scanner);
    const root = try parser.parse();
    var analyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer.init(a, &parser.ast);
    analyzer.enable_stmt_info = true;
    analyzer.enable_exact_declaration_anchors = true;
    try analyzer.analyze();
    var unsupported = @import("transformer.zig").TransformOptions.compat.fromReactNativeVersion(0, 80);
    unsupported.arrow = true;
    var t = try Transformer.init(a, &parser.ast, .{ .unsupported = unsupported });
    try t.initSymbolIds(analyzer.symbol_ids.items);
    t.symbols = analyzer.symbols.items;
    t.references = analyzer.references.items;
    t.scopes = analyzer.scopes.items;
    t.scope_maps = analyzer.scope_maps.items;
    t.scope_owner_map = analyzer.scope_owner_map;
    t.class_self_symbol_map = analyzer.class_self_symbol_map;
    t.node_scope_provenance = analyzer.node_scope_provenance;
    t.semantic_edit_enabled = true;
    try t.buildBlockRenameMap();
    const output = try t.visitNode(root);
    const parents = try @import("output_scope_test_utils.zig").buildParentMap(a, t.ast, output);
    var functions: std.ArrayList(ast.NodeIndex) = .empty;
    for (t.ast.nodes.items, 0..) |node, raw| {
        if (node.tag == .function_expression and !t.ast.readExtraNode(node.data.extra, 0).isNone() and parents.contains(@intCast(raw))) try functions.append(a, @fromBackingInt(@as(u32, @intCast(raw))));
    }
    try std.testing.expectEqual(@as(usize, 2), functions.items.len);
    const owner = functions.items[0];
    const second = functions.items[1];
    const name = t.ast.readExtraNode(t.ast.getNode(owner).data.extra, 0);
    const other_name = t.ast.readExtraNode(t.ast.getNode(second).data.extra, 0);
    const id = t.getSymbolIdAt(name).?;
    const other_id = t.getSymbolIdAt(other_name).?;
    const validate = @import("initializer_clone.zig").namedExpressionScope;
    const from = t.programScope();
    const scope = try validate(&t, owner, from);
    const body = t.outputOwnedScope(owner).?;
    // A different valid function SID is insufficient: this physical function
    // must have the exact self-name scope as its own body's parent.
    t.symbol_ids.items[@backingInt(name)] = other_id;
    try std.testing.expectError(error.InvalidCloneOwnership, validate(&t, owner, from));
    t.symbol_ids.items[@backingInt(name)] = null;
    try std.testing.expectError(error.InvalidCloneOwnership, validate(&t, owner, from));
    t.symbol_ids.items[@backingInt(name)] = @intCast(t.semantic_editor.?.symbols.items.len);
    try std.testing.expectError(error.InvalidCloneOwnership, validate(&t, owner, from));
    t.symbol_ids.items[@backingInt(name)] = id;
    const kind = t.semantic_editor.?.symbols.items[id].kind;
    t.semantic_editor.?.symbols.items[id].kind = .variable_let;
    try std.testing.expectError(error.InvalidCloneOwnership, validate(&t, owner, from));
    t.semantic_editor.?.symbols.items[id].kind = kind;
    const scope_kind = t.semantic_editor.?.scopes.items[scope.toIndex()].kind;
    t.semantic_editor.?.scopes.items[scope.toIndex()].kind = .function;
    try std.testing.expectError(error.InvalidCloneOwnership, validate(&t, owner, from));
    t.semantic_editor.?.scopes.items[scope.toIndex()].kind = scope_kind;
    t.semantic_editor.?.scopes.items[scope.toIndex()].parent = body;
    try std.testing.expectError(error.InvalidCloneOwnership, validate(&t, owner, from));
    t.semantic_editor.?.scopes.items[scope.toIndex()].parent = from;
    const body_parent = t.semantic_editor.?.scopes.items[body.toIndex()].parent;
    t.semantic_editor.?.scopes.items[body.toIndex()].parent = from;
    try std.testing.expectError(error.InvalidCloneOwnership, validate(&t, owner, from));
    t.semantic_editor.?.scopes.items[body.toIndex()].parent = body_parent;
    const body_kind = t.semantic_editor.?.scopes.items[body.toIndex()].kind;
    t.semantic_editor.?.scopes.items[body.toIndex()].kind = .block;
    try std.testing.expectError(error.InvalidCloneOwnership, validate(&t, owner, from));
    t.semantic_editor.?.scopes.items[body.toIndex()].kind = body_kind;
    const owner_tag = t.ast.nodes.items[@backingInt(owner)].tag;
    t.ast.nodes.items[@backingInt(owner)].tag = .function_declaration;
    try std.testing.expectError(error.InvalidCloneOwnership, validate(&t, owner, from));
    t.ast.nodes.items[@backingInt(owner)].tag = owner_tag;
    const name_tag = t.ast.nodes.items[@backingInt(name)].tag;
    t.ast.nodes.items[@backingInt(name)].tag = .identifier_reference;
    try std.testing.expectError(error.InvalidCloneOwnership, validate(&t, owner, from));
    t.ast.nodes.items[@backingInt(name)].tag = name_tag;
    try std.testing.expectEqual(scope, try validate(&t, owner, from));
    try std.testing.expectEqual(t.semantic_editor.?.symbols.items[other_id].scope_id, try validate(&t, second, from));
}

const deferred_super_sources = [_][]const u8{
    "class P{}class D extends P{x=42;constructor(){const go=()=>super();go()}}console.log(JSON.stringify(new D().x));",
    "class P{}class D extends P{#x=42;read(){return this.#x}constructor(){const go=()=>super();go()}}console.log(JSON.stringify(new D().read()));",
    "class P{}class D extends P{#x=()=>this;read(){return this.#x}constructor(){const go=()=>super();go()}}const d=new D;console.log(JSON.stringify([d.read()()===d,d.read().name]));",
    "const log=[];class P{constructor(){log.push('base')}}class D extends P{x=(log.push('field'),42);constructor(){const go=()=>{log.push('arrow');return super()};log.push('before');go();log.push('after')}}const d=new D;console.log(JSON.stringify([log,d.x]));",
    "class P{}class D extends P{#x=42;read(){return this.#x}constructor(){const go=()=>()=>super();go()()}}console.log(JSON.stringify(new D().read()));",
    "class P{}class D extends P{#x=42;read(){return this.#x}constructor(flag){const go=flag?()=>super():()=>super();go()}}console.log(JSON.stringify([new D(true).read(),new D(false).read()]));",
    "class P{}class D extends P{x=this;constructor(){const go=()=>super();const actual=go();console.log(JSON.stringify([actual===this,this.x===this]))}}new D;",
    "class P{constructor(){return {ready:7}}}class D extends P{x=this.ready+1;constructor(){const go=()=>super();go()}}console.log(JSON.stringify(new D().x));",
    "let fields=0;class P{constructor(){throw Error('base')}}class D extends P{x=++fields;constructor(){const go=()=>super();try{go()}catch(e){return {message:e.message}}}}const d=new D;console.log(JSON.stringify([d.message,fields]));",
    "let fields=0;class P{}class D extends P{x=++fields;constructor(){const go=()=>super();return {go}}}const holder=new D;const before=fields;const actual=holder.go();console.log(JSON.stringify([before,fields,actual.x,actual instanceof D]));",
};

fn checkDeferredSuper(case: usize) !void {
    return checkDeferredSuperSource(deferred_super_sources[case], case);
}

fn checkDeferredSuperSource(source: []const u8, case: usize) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const native = try std.process.run(a, std.testing.io, .{ .argv = &.{ "node", "-e", source } });
    try std.testing.expect(native.term == .exited and native.term.exited == 0);
    const Profiles = enum { es2015, es2017, es5, rn080_arrow };
    var supported_failures: usize = 0;
    var residual_failures: usize = 0;
    inline for (std.meta.tags(Profiles)) |profile| {
        var unsupported = switch (profile) {
            .es2015 => @import("transformer.zig").TransformOptions.compat.fromESTarget(.es2015),
            .es2017 => @import("transformer.zig").TransformOptions.compat.fromESTarget(.es2017),
            .es5 => @import("transformer.zig").TransformOptions.compat.fromESTarget(.es5),
            .rn080_arrow => @import("transformer.zig").TransformOptions.compat.fromReactNativeVersion(0, 80),
        };
        if (profile == .rn080_arrow) unsupported.arrow = true;
        for ([_]bool{ false, true }) |minify| {
            std.debug.print("DEFERRED START case={d} profile={s} minify={}\n", .{ case, @tagName(profile), minify });
            const result = @import("../transpile.zig").transpile(a, source, "input.cjs", .{
                .unsupported = unsupported,
                .use_define_for_class_fields = true,
                .keep_names = true,
                .minify_syntax = minify,
                .minify_identifiers = minify,
                .minify_whitespace = minify,
            }) catch |err| {
                if (profile != .rn080_arrow) supported_failures += 1 else residual_failures += 1;
                std.debug.print("DEFERRED RESULT case={d} profile={s} minify={} status=transform-error error={s}\n", .{ case, @tagName(profile), minify, @errorName(err) });
                continue;
            };
            const actual = try std.process.run(a, std.testing.io, .{ .argv = &.{ "node", "-e", result.code } });
            const passed = actual.term == .exited and actual.term.exited == 0 and std.mem.eql(u8, native.stdout, actual.stdout);
            std.debug.print("DEFERRED RESULT case={d} profile={s} minify={} status={s}\n", .{ case, @tagName(profile), minify, if (passed) "pass" else "runtime-fail" });
            if (!passed) {
                if (profile != .rn080_arrow) supported_failures += 1 else residual_failures += 1;
                std.debug.print("DEFERRED FAILURE case={d} profile={s} minify={} expected={s} actual={s} stderr={s} code={s}\n", .{ case, @tagName(profile), minify, native.stdout, actual.stdout, actual.stderr, result.code });
            }
        }
    }
    std.debug.print("DEFERRED SUMMARY case={d} supportedFailures={d} residualFailures={d}\n", .{ case, supported_failures, residual_failures });
    try std.testing.expectEqual(@as(usize, 0), supported_failures);
}

test "deferred native super repro 00" {
    try checkDeferredSuper(0);
}

test "deferred native super repro 01" {
    try checkDeferredSuper(1);
}

test "deferred native super repro 02" {
    try checkDeferredSuper(2);
}

test "deferred native super repro 03" {
    try checkDeferredSuper(3);
}

test "deferred native super repro 04" {
    try checkDeferredSuper(4);
}

test "deferred native super repro 05" {
    try checkDeferredSuper(5);
}

test "deferred native super repro 06" {
    try checkDeferredSuper(6);
}

test "deferred native super repro 07" {
    try checkDeferredSuper(7);
}

test "deferred native super repro 08" {
    try checkDeferredSuper(8);
}

test "deferred native super repro 09" {
    try checkDeferredSuper(9);
}

fn checkDeferredSuperBirth(source: []const u8, target: @import("compat.zig").ESTarget) !void {
    return checkDeferredSuperBirthWithPlacement(source, target, true);
}

fn checkDeferredSuperBirthWithPlacement(source: []const u8, target: @import("compat.zig").ESTarget, check_placement: bool) !void {
    return checkDeferredSuperBirthWithFeatures(source, @import("compat.zig").fromESTarget(target), target == .es5, check_placement);
}

fn checkDeferredSuperBirthWithFeatures(source: []const u8, unsupported: @import("compat.zig").UnsupportedFeatures, lowered: bool, check_placement: bool) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var scanner = try @import("../lexer/scanner.zig").Scanner.init(a, source);
    var parser = @import("../parser/parser.zig").Parser.init(a, &scanner);
    const root = try parser.parse();
    var analyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer.init(a, &parser.ast);
    analyzer.enable_stmt_info = true;
    analyzer.enable_exact_declaration_anchors = true;
    analyzer.collect_unresolved_reference_nodes = true;
    try analyzer.analyze();
    var t = try Transformer.init(a, &parser.ast, .{
        .unsupported = unsupported,
        .use_define_for_class_fields = true,
    });
    try t.initSymbolIds(analyzer.symbol_ids.items);
    t.symbols = analyzer.symbols.items;
    t.references = analyzer.references.items;
    t.scopes = analyzer.scopes.items;
    t.scope_maps = analyzer.scope_maps.items;
    t.scope_owner_map = analyzer.scope_owner_map;
    t.class_self_symbol_map = analyzer.class_self_symbol_map;
    t.node_scope_provenance = analyzer.node_scope_provenance;
    t.unresolved_references = &analyzer.unresolved_references;
    t.unresolved_reference_nodes = &analyzer.unresolved_reference_nodes;
    t.semantic_edit_enabled = true;
    t.record_explicit_global_references = true;
    try t.buildBlockRenameMap();
    const output = try t.visitNode(root);
    try std.testing.expect(std.meta.eql(unsupported, t.options.unsupported));
    try std.testing.expect(t.active_lowered_class == null);
    try std.testing.expect(t.pending_deferred_super_class_plan == null);
    if (!unsupported.class and unsupported.arrow) {
        try std.testing.expectEqual(lowered, t.class_factory_statement_lists_changed);
        if (!lowered) try std.testing.expect(!t.runtime_helpers.extends and !t.runtime_helpers.call_super);
    }
    // Nothing below creates scopes, references or coordinate publication.
    const utils = @import("output_scope_test_utils.zig");
    const parents = try utils.buildParentMap(a, t.ast, output);
    var owners: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    for (t.ast.nodes.items, 0..) |_, raw| {
        if (!parents.contains(@intCast(raw)) and raw != @backingInt(output)) continue;
        if (t.outputOwnedScope(@fromBackingInt(@as(u32, @intCast(raw))))) |scope| try owners.put(a, @intCast(raw), @backingInt(scope));
    }
    const coordinates = try @import("../semantic/statement_coordinates.zig").collect(a, t.ast, output);
    const refs = try @import("../semantic/reference_walk.zig").collectIdentifierReferences(a, t.ast, output);
    var checked: usize = 0;
    for (refs) |node| {
        const raw = @backingInt(node);
        if (t.getSymbolIdAt(node)) |id| {
            const row = (try t.semantic_editor.?.referenceForNode(node)) orelse return error.MissingDeferredReference;
            const actual = coordinates[raw] orelse return error.MissingDeferredCoordinates;
            try std.testing.expectEqual(id, @backingInt(row.symbol_id));
            const physical_scope = utils.expectedScope(t.ast, output, &parents, &owners, raw).?;
            if (physical_scope != row.scope_id) std.debug.print("DEFERRED SCOPE node={d} name={s} SID={d} rowScope={d} actualScope={d} stmt={d}/{d} scopeStmt={d}/{d}\n", .{ raw, t.ast.getText(t.ast.getNode(node).data.string_ref), id, @backingInt(row.scope_id), @backingInt(physical_scope), row.stmt_idx, actual.stmt_idx, row.scope_stmt_idx, actual.scope_stmt_idx });
            try std.testing.expectEqual(physical_scope, row.scope_id);
            if (actual.stmt_idx != row.stmt_idx or actual.scope_stmt_idx != row.scope_stmt_idx) std.debug.print("DEFERRED BIRTH node={d} name={s} sid={d} scope={d} stmt={d}/{d} scopeStmt={d}/{d} recordedOrigin={}\n", .{ raw, t.ast.getText(t.ast.getNode(node).data.string_ref), id, @backingInt(row.scope_id), row.stmt_idx, actual.stmt_idx, row.scope_stmt_idx, actual.scope_stmt_idx, t.native_constructor_reference_origins.contains(raw) });
            try std.testing.expectEqual(actual.stmt_idx, row.stmt_idx);
            try std.testing.expectEqual(actual.scope_stmt_idx, row.scope_stmt_idx);
            checked += 1;
        } else {
            const origin = t.reference_origin_map.get(raw) orelse raw;
            if (!t.explicit_global_reference_nodes.contains(raw) and !analyzer.unresolved_reference_nodes.contains(origin)) std.debug.print("DEFERRED NULL node={d} name={s} origin={d} capture={} tag={s}\n", .{ raw, t.ast.getText(t.ast.getNode(node).data.string_ref), origin, t.capture_ref_by_origin.contains(origin), @tagName(t.ast.getNode(node).tag) });
            try std.testing.expect(t.explicit_global_reference_nodes.contains(raw) or analyzer.unresolved_reference_nodes.contains(origin));
        }
    }
    try std.testing.expect(checked > 0);
    if (!check_placement) {
        try @import("transformer/semantic_edit.zig").bindOutputScopesAndReferencesChecked(&t, output, t.programScope());
        return;
    }
    if (lowered) {
        const declarations = @import("transformer/declarations.zig");
        var markers = t.generated_super_call_assignments.iterator();
        var sites: usize = 0;
        while (markers.next()) |entry| {
            const raw = entry.key_ptr.*;
            const marker = entry.value_ptr.*;
            if (marker.native or !parents.contains(raw)) continue;
            sites += 1;
            const assignment = t.ast.nodes.items[raw];
            try std.testing.expectEqual(ast.Node.Tag.assignment_expression, assignment.tag);
            try std.testing.expectEqual(ast.Node.Tag.assignment_target_identifier, t.ast.getNode(assignment.data.binary.left).tag);
            const id = t.getSymbolIdAt(assignment.data.binary.left).?;
            const scope = t.semantic_editor.?.symbols.items[id].scope_id;
            var frame: ?u32 = null;
            var bindings = t.capture_binding_ids.iterator();
            while (bindings.next()) |binding| {
                if (binding.value_ptr.* != id or binding.key_ptr.* & 3 != @backingInt(@import("transformer.zig").LexicalCaptureKind.this_value)) continue;
                try std.testing.expect(frame == null);
                frame = @intCast(binding.key_ptr.* >> 2);
            }
            const use_scope = utils.expectedScope(t.ast, output, &parents, &owners, raw).?;
            try declarations.validateLoweredSuperSite(&t, @fromBackingInt(raw), marker, .{ .frame = frame.?, .scope = scope, .target = @fromBackingInt(id) }, use_scope);
            var result_declarations: usize = 0;
            for (t.semantic_editor.?.references.items) |row| {
                if (row.symbol_id == marker.result_symbol.? and row.flags.declare) result_declarations += 1;
            }
            try std.testing.expectEqual(@as(usize, 1), result_declarations);
            const parent = t.ast.nodes.items[parents.get(raw).?];
            try std.testing.expectEqual(ast.Node.Tag.sequence_expression, parent.tag);
            const list = t.ast.extra_data.items[parent.data.list.start .. parent.data.list.start + parent.data.list.len];
            try std.testing.expect(list.len >= 3);
            if (parents.get(raw).? == @backingInt(marker.evaluation_sequence)) {
                // A constructor without instance initializers keeps the exact
                // evaluation sequence; assigning this is itself the result.
                try std.testing.expectEqual(raw, list[2]);
                continue;
            }
            try std.testing.expectEqual(raw, list[0]);
            const result: ast.NodeIndex = @fromBackingInt(list[list.len - 1]);
            try std.testing.expect(result != assignment.data.binary.left);
            try std.testing.expectEqual(id, t.getSymbolIdAt(result).?);
            const read = (try t.semantic_editor.?.referenceForNode(result)).?;
            try std.testing.expectEqual(use_scope, read.scope_id);
            try std.testing.expect(read.flags.read and !read.flags.write);
        }
        try std.testing.expect(sites > 0);
        try @import("transformer/semantic_edit.zig").bindOutputScopesAndReferencesChecked(&t, output, t.programScope());
        return;
    }
    try std.testing.expectEqual(@as(usize, 0), t.native_constructor_timing_plans.count());
    try std.testing.expect(!t.runtime_helpers.derived_constructor);
    var sites: usize = 0;
    var site_nodes: std.AutoHashMapUnmanaged(u32, void) = .empty;
    for (t.ast.nodes.items, 0..) |node, raw| {
        if (node.tag != .call_expression or !parents.contains(@intCast(raw))) continue;
        const callee = t.ast.getNode(t.ast.readExtraNode(node.data.extra, 0));
        if (callee.tag != .super_expression) continue;
        sites += 1;
        const sequence_idx = parents.get(@intCast(raw)).?;
        const sequence = t.ast.nodes.items[sequence_idx];
        try std.testing.expectEqual(ast.Node.Tag.sequence_expression, sequence.tag);
        const list = t.ast.extra_data.items[sequence.data.list.start .. sequence.data.list.start + sequence.data.list.len];
        try std.testing.expect(list.len >= 3);
        try std.testing.expectEqual(@as(u32, @intCast(raw)), list[0]);
        try std.testing.expectEqual(ast.Node.Tag.this_expression, t.ast.nodes.items[list[list.len - 1]].tag);
        var cursor = parents.get(@intCast(raw));
        var arrows: usize = 0;
        var constructor_scope: ?u32 = null;
        while (cursor) |parent_raw| {
            const parent_node = t.ast.nodes.items[parent_raw];
            if (parent_node.tag == .arrow_function_expression) arrows += 1;
            if (parent_node.tag == .method_definition) {
                try std.testing.expect(@import("es_helpers.zig").isConstructorKey(&t, t.ast.readExtraNode(parent_node.data.extra, ast.MethodExtra.key)));
                constructor_scope = owners.get(parent_raw).?;
                break;
            }
            cursor = parents.get(parent_raw);
        }
        try std.testing.expect(arrows > 0);
        try std.testing.expect(constructor_scope != null);
        const use_scope = utils.expectedScope(t.ast, output, &parents, &owners, @intCast(raw)).?;
        try std.testing.expect(@backingInt(use_scope) != constructor_scope.?);
        var stack: std.ArrayList(ast.NodeIndex) = .empty;
        try stack.append(a, @fromBackingInt(sequence_idx));
        var local_nodes: std.AutoHashMapUnmanaged(u32, void) = .empty;
        while (stack.pop()) |child| {
            if (child.isNone()) continue;
            const child_raw = @backingInt(child);
            const local = try local_nodes.getOrPut(a, child_raw);
            if (local.found_existing) continue;
            try std.testing.expect(!site_nodes.contains(child_raw));
            var children = @import("../parser/ast_walk.zig").children(t.ast, t.ast.getNode(child));
            while (children.next()) |next| try stack.append(a, next);
        }
        var nodes = local_nodes.keyIterator();
        while (nodes.next()) |child| try site_nodes.put(a, child.*, {});
    }
    try std.testing.expect(sites > 0);
    try @import("transformer/semantic_edit.zig").bindOutputScopesAndReferencesChecked(&t, output, t.programScope());
}

test "deferred native super exact birth before output walker" {
    for (deferred_super_sources) |source| {
        try checkDeferredSuperBirth(source, .es2015);
        try checkDeferredSuperBirth(source, .es2017);
    }
}

test "deferred ES5 exact birth before output walker" {
    for (deferred_super_sources) |source| try checkDeferredSuperBirth(source, .es5);
}

test "deferred ES5 marker rejects sibling frame scope and SID" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source = "class P{}class Other extends P{constructor(){super()}}class D extends P{x=42;constructor(){const go=()=>super();go()}}new Other;new D;";
    var scanner = try @import("../lexer/scanner.zig").Scanner.init(a, source);
    var parser = @import("../parser/parser.zig").Parser.init(a, &scanner);
    const root = try parser.parse();
    var analyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer.init(a, &parser.ast);
    analyzer.enable_stmt_info = true;
    analyzer.enable_exact_declaration_anchors = true;
    analyzer.collect_unresolved_reference_nodes = true;
    try analyzer.analyze();
    var t = try Transformer.init(a, &parser.ast, .{ .unsupported = @import("transformer.zig").TransformOptions.compat.fromESTarget(.es5), .use_define_for_class_fields = true });
    try t.initSymbolIds(analyzer.symbol_ids.items);
    t.symbols = analyzer.symbols.items;
    t.references = analyzer.references.items;
    t.scopes = analyzer.scopes.items;
    t.scope_maps = analyzer.scope_maps.items;
    t.scope_owner_map = analyzer.scope_owner_map;
    t.class_self_symbol_map = analyzer.class_self_symbol_map;
    t.node_scope_provenance = analyzer.node_scope_provenance;
    t.unresolved_references = &analyzer.unresolved_references;
    t.unresolved_reference_nodes = &analyzer.unresolved_reference_nodes;
    t.semantic_edit_enabled = true;
    t.record_explicit_global_references = true;
    try t.buildBlockRenameMap();
    const output = try t.visitNode(root);
    const utils = @import("output_scope_test_utils.zig");
    const parents = try utils.buildParentMap(a, t.ast, output);
    var owners: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    for (t.ast.nodes.items, 0..) |_, raw| {
        if (!parents.contains(@intCast(raw)) and raw != @backingInt(output)) continue;
        if (t.outputOwnedScope(@fromBackingInt(@as(u32, @intCast(raw))))) |scope| try owners.put(a, @intCast(raw), @backingInt(scope));
    }
    var selected_node: ?u32 = null;
    var sibling: ?Transformer.GeneratedSuperCall = null;
    var markers = t.generated_super_call_assignments.iterator();
    while (markers.next()) |entry| {
        if (!parents.contains(entry.key_ptr.*) or entry.value_ptr.native) continue;
        if (entry.value_ptr.use_scope != entry.value_ptr.constructor_scope) selected_node = entry.key_ptr.* else sibling = entry.value_ptr.*;
    }
    const raw = selected_node.?;
    const index: ast.NodeIndex = @fromBackingInt(raw);
    const marker = t.generated_super_call_assignments.get(raw).?;
    const foreign = sibling.?;
    const lhs = t.ast.getNode(index).data.binary.left;
    const id = t.getSymbolIdAt(lhs).?;
    const scope = t.semantic_editor.?.symbols.items[id].scope_id;
    const use_scope = utils.expectedScope(t.ast, output, &parents, &owners, raw).?;
    var frame: ?u32 = null;
    var captures = t.capture_binding_ids.iterator();
    while (captures.next()) |capture| {
        if (capture.value_ptr.* == id and capture.key_ptr.* & 3 == @backingInt(@import("transformer.zig").LexicalCaptureKind.this_value)) {
            try std.testing.expect(frame == null);
            frame = @intCast(capture.key_ptr.* >> 2);
        }
    }
    const validation = @import("transformer/declarations.zig");
    const owner = validation.LoweredConstructorOwner{ .frame = frame.?, .scope = scope, .target = @fromBackingInt(id) };
    try validation.validateLoweredSuperSite(&t, index, marker, owner, use_scope);
    try std.testing.expect(foreign.target_symbol != marker.target_symbol and foreign.constructor_scope != marker.constructor_scope and foreign.constructor_frame != marker.constructor_frame);
    var bad = marker;
    bad.constructor_frame = foreign.constructor_frame;
    try std.testing.expectError(error.InvalidScope, validation.validateLoweredSuperSite(&t, index, bad, owner, use_scope));
    bad = marker;
    bad.constructor_scope = foreign.constructor_scope;
    try std.testing.expectError(error.InvalidScope, validation.validateLoweredSuperSite(&t, index, bad, owner, use_scope));
    bad = marker;
    bad.use_scope = foreign.use_scope;
    try std.testing.expectError(error.InvalidScope, validation.validateLoweredSuperSite(&t, index, bad, owner, use_scope));
    bad = marker;
    bad.target_symbol = foreign.target_symbol;
    try std.testing.expectError(error.InvalidSymbol, validation.validateLoweredSuperSite(&t, index, bad, owner, use_scope));
    bad = marker;
    bad.target_symbol = null;
    try std.testing.expectError(error.InvalidSymbol, validation.validateLoweredSuperSite(&t, index, bad, owner, use_scope));
    bad = marker;
    bad.callee_symbol = foreign.target_symbol;
    try std.testing.expectError(error.InvalidSymbol, validation.validateLoweredSuperSite(&t, index, bad, owner, use_scope));
    bad = marker;
    bad.flags = .{ .read = true };
    try std.testing.expectError(error.InvalidSymbol, validation.validateLoweredSuperSite(&t, index, bad, owner, use_scope));
    bad = marker;
    bad.native = true;
    try std.testing.expectError(error.InvalidNode, validation.validateLoweredSuperSite(&t, index, bad, owner, use_scope));
    t.symbol_ids.items[@backingInt(lhs)] = @backingInt(foreign.target_symbol.?);
    try std.testing.expectError(error.InvalidSymbol, validation.validateLoweredSuperSite(&t, index, marker, owner, use_scope));
    t.symbol_ids.items[@backingInt(lhs)] = id;
    const row_index = t.semantic_editor.?.reference_index.get(@backingInt(lhs)).?;
    const row = t.semantic_editor.?.references.items[row_index];
    t.semantic_editor.?.references.items[row_index].scope_id = foreign.use_scope;
    try std.testing.expectError(error.InvalidScope, validation.validateLoweredSuperSite(&t, index, marker, owner, use_scope));
    t.semantic_editor.?.references.items[row_index] = row;
    t.semantic_editor.?.references.items[row_index].flags = .{ .read = true };
    try std.testing.expectError(error.InvalidSymbol, validation.validateLoweredSuperSite(&t, index, marker, owner, use_scope));
    t.semantic_editor.?.references.items[row_index] = row;
    bad = marker;
    bad.result_assignment = foreign.result_assignment;
    try std.testing.expectError(error.InvalidNode, validation.validateLoweredSuperSite(&t, index, bad, owner, use_scope));
    bad = marker;
    bad.result_symbol = foreign.result_symbol;
    try std.testing.expectError(error.InvalidSymbol, validation.validateLoweredSuperSite(&t, index, bad, owner, use_scope));
    bad = marker;
    bad.result_symbol = null;
    try std.testing.expectError(error.InvalidSymbol, validation.validateLoweredSuperSite(&t, index, bad, owner, use_scope));
    bad = marker;
    bad.pending_result_producer_id = 1;
    try std.testing.expectError(error.InvalidSymbol, validation.validateLoweredSuperSite(&t, index, bad, owner, use_scope));
    bad = marker;
    bad.result_scope = foreign.result_scope;
    try std.testing.expectError(error.InvalidSymbol, validation.validateLoweredSuperSite(&t, index, bad, owner, use_scope));
    bad = marker;
    bad.evaluation_sequence = foreign.evaluation_sequence;
    try std.testing.expectError(error.InvalidNode, validation.validateLoweredSuperSite(&t, index, bad, owner, use_scope));
    bad = marker;
    bad.check_symbol = foreign.target_symbol;
    try std.testing.expectError(error.InvalidSymbol, validation.validateLoweredSuperSite(&t, index, bad, owner, use_scope));
    const evaluation = t.ast.getNode(marker.evaluation_sequence).data.list;
    std.mem.swap(u32, &t.ast.extra_data.items[evaluation.start], &t.ast.extra_data.items[evaluation.start + 1]);
    try std.testing.expectError(error.InvalidNode, validation.validateLoweredSuperSite(&t, index, marker, owner, use_scope));
    std.mem.swap(u32, &t.ast.extra_data.items[evaluation.start], &t.ast.extra_data.items[evaluation.start + 1]);
    const result_write = t.ast.getNode(marker.result_assignment).data.binary.left;
    const result_row_index = t.semantic_editor.?.reference_index.get(@backingInt(result_write)).?;
    const result_row = t.semantic_editor.?.references.items[result_row_index];
    t.semantic_editor.?.references.items[result_row_index].flags = .{ .read = true };
    try std.testing.expectError(error.InvalidSymbol, validation.validateLoweredSuperSite(&t, index, marker, owner, use_scope));
    t.semantic_editor.?.references.items[result_row_index] = result_row;
    try validation.validateLoweredSuperSite(&t, index, marker, owner, use_scope);
    // This fragment owns AST, but its constructor cells and temp storage are
    // external bindings. Copy only the exact producer handles and references.
    var cloned = try @import("initializer_clone.zig").clone(&t, &.{marker.evaluation_sequence}, use_scope, use_scope);
    defer cloned.deinit(a);
    const cloned_index = cloned.nodes.get(raw).?;
    const cloned_marker = t.generated_super_call_assignments.get(@backingInt(cloned_index)).?;
    try std.testing.expect(cloned_index != index);
    try std.testing.expect(cloned_marker.result_assignment != marker.result_assignment);
    try std.testing.expect(cloned_marker.evaluation_sequence != marker.evaluation_sequence);
    try std.testing.expectEqual(marker.target_symbol, cloned_marker.target_symbol);
    try std.testing.expectEqual(marker.result_symbol, cloned_marker.result_symbol);
    try std.testing.expectEqual(marker.check_symbol, cloned_marker.check_symbol);
    try validation.validateLoweredSuperSite(&t, cloned_index, cloned_marker, owner, use_scope);
}

const deferred_sibling_sources = [_][]const u8{
    "const log=[];class P{}class D extends P{#x=(log.push('outer'),1);read(){return this.#x}constructor(){function make(){class E extends P{y=(log.push('inner'),2);constructor(){const go=()=>super();go()}}return E}const E=make();const inner=new E;const go=()=>super();go();this.inner=inner}}const d=new D;console.log(JSON.stringify([log,d.read(),d.inner.y]));",
    "const log=[];class P{}class D extends P{#x=(log.push('outer'),1);read(){return this.#x}constructor(){class E extends P{#y=(log.push('inner'),2);read(){return this.#y}constructor(){const go=()=>super();go()}}const go=()=>super();go();this.inner=new E}}const d=new D;console.log(JSON.stringify([log,d.read(),d.inner.read()]));",
};
test "deferred super ordinary function constructor frame isolation" {
    try checkDeferredSuperSource(deferred_sibling_sources[0], 10);
    try checkDeferredSuperBirth(deferred_sibling_sources[0], .es5);
}
test "deferred super nested constructor frame isolation" {
    try checkDeferredSuperSource(deferred_sibling_sources[1], 11);
    try checkDeferredSuperBirth(deferred_sibling_sources[1], .es5);
}

fn checkDeferredDefaultRuntime(source: []const u8, target: @import("compat.zig").ESTarget) !void {
    return checkDeferredProfileRuntime(source, @import("compat.zig").fromESTarget(target));
}

fn checkDeferredProfileRuntime(source: []const u8, unsupported: @import("compat.zig").UnsupportedFeatures) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const native = try std.process.run(a, std.testing.io, .{ .argv = &.{ "node", "-e", source } });
    try std.testing.expect(native.term == .exited and native.term.exited == 0);
    for ([_]bool{ false, true }) |minify| {
        const result = try @import("../transpile.zig").transpile(a, source, "input.cjs", .{
            .unsupported = unsupported,
            .use_define_for_class_fields = true,
            .keep_names = true,
            .minify_syntax = minify,
            .minify_identifiers = minify,
            .minify_whitespace = minify,
        });
        const actual = try std.process.run(a, std.testing.io, .{ .argv = &.{ "node", "-e", result.code } });
        if (actual.term != .exited or actual.term.exited != 0 or !std.mem.eql(u8, native.stdout, actual.stdout))
            std.debug.print("DEFAULT ENV expected={s} actual={s} stderr={s} code={s}\n", .{ native.stdout, actual.stdout, actual.stderr, result.code });
        try std.testing.expect(actual.term == .exited and actual.term.exited == 0);
        try std.testing.expectEqualStrings(native.stdout, actual.stdout);
    }
}

test "deferred default producer runtime and birth" {
    const source = "class P{}class D extends P{x=42;constructor(go=()=>super(),read=()=>this.x){go();this.out=read()}}console.log(JSON.stringify(new D().out));";
    try checkDeferredDefaultRuntime(source, .es5);
    try checkDeferredSuperBirth(source, .es5);
}

test "deferred default producer preserves body var shadow" {
    const source = "const value=7;class P{}class D extends P{x=42;constructor(go=()=>super(),read=()=>value){var value=9;go();this.out=[read(),value]}}console.log(JSON.stringify(new D().out));";
    try checkDeferredDefaultRuntime(source, .es5);
    try checkDeferredSuperBirth(source, .es5);
}

test "deferred default producer leaves native parameters owned" {
    const source = "const value=7;class P{}class D extends P{x=42;constructor(go=()=>super(),read=()=>value){var value=9;go();this.out=[read(),value]}}console.log(JSON.stringify(new D().out));";
    try checkDeferredDefaultRuntime(source, .es2015);
    try checkDeferredSuperBirthWithPlacement(source, .es2015, false);
}

test "lowered repeated super producer 0" {
    const source = "let calls=0,args=0,fields=0;class P{constructor(){calls++}}class D extends P{x=++fields;constructor(){const go=()=>super(++args);go();try{go()}catch(e){this.error=e instanceof ReferenceError}}}const d=new D;console.log(JSON.stringify([calls,args,fields,d.error]));";
    try checkDeferredDefaultRuntime(source, .es5);
    try checkDeferredSuperBirth(source, .es5);
}

test "lowered repeated super producer 1" {
    const source = "let calls=0,fields=0;class P{constructor(){calls++}}class D extends P{x=++fields;constructor(){super();try{super()}catch(e){this.error=e instanceof ReferenceError}}}const d=new D;console.log(JSON.stringify([calls,fields,d.error]));";
    try checkDeferredDefaultRuntime(source, .es5);
    try checkDeferredSuperBirth(source, .es5);
}

test "lowered repeated super producer 2" {
    const source = "let calls=0,fields=0;class P{constructor(){calls++}}class D extends P{x=++fields;constructor(){const outer=()=>()=>super();outer()();try{outer()()}catch(e){this.error=e instanceof ReferenceError}}}const d=new D;console.log(JSON.stringify([calls,fields,d.error]));";
    try checkDeferredDefaultRuntime(source, .es5);
    try checkDeferredSuperBirth(source, .es5);
}

test "lowered repeated super producer 3" {
    const source = "let calls=0,fields=0;class P{constructor(){if(++calls===2)throw Error('second')}}class D extends P{x=++fields;constructor(){const go=()=>super();go();try{go()}catch(e){this.error=e.message}}}const d=new D;console.log(JSON.stringify([calls,fields,d.error]));";
    try checkDeferredDefaultRuntime(source, .es5);
    try checkDeferredSuperBirth(source, .es5);
}

test "lowered repeated super producer 4" {
    const source = "let calls=0,args=0,fields=0;function arg(){if(++args===2)throw Error('arg');return args}class P{constructor(){calls++}}class D extends P{x=++fields;constructor(){const go=()=>super(arg());go();try{go()}catch(e){this.error=e.message}}}const d=new D;console.log(JSON.stringify([calls,args,fields,d.error]));";
    try checkDeferredDefaultRuntime(source, .es5);
    try checkDeferredSuperBirth(source, .es5);
}

test "lowered repeated super producer 5" {
    const source = "let calls=0,fields=0;class P{constructor(){return{n:++calls}}}class D extends P{x=++fields;constructor(){const go=()=>super();go();try{go()}catch(e){this.error=e instanceof ReferenceError}}}const d=new D;console.log(JSON.stringify([calls,fields,d.n,d.error]));";
    try checkDeferredDefaultRuntime(source, .es5);
    try checkDeferredSuperBirth(source, .es5);
}

test "lowered repeated super producer 6" {
    const source = "let calls=0,fields=0,sets=0;const out={set value(v){sets++;}};class P{constructor(){calls++}}class D extends P{x=++fields;constructor(){const go=()=>out.value=super();go();try{go()}catch(e){this.error=e instanceof ReferenceError}}}const d=new D;console.log(JSON.stringify([calls,fields,sets,d.error]));";
    try checkDeferredDefaultRuntime(source, .es5);
    try checkDeferredSuperBirth(source, .es5);
}

test "lowered repeated super producer 7" {
    const source = "let again,calls=0,fields=0;class P{constructor(){if(++calls===1)again()}}class D extends P{x=++fields;constructor(){const go=()=>super();again=go;try{go()}catch(e){this.error=e instanceof ReferenceError}}}const d=new D;console.log(JSON.stringify([calls,fields,d.error]));";
    try checkDeferredDefaultRuntime(source, .es5);
    try checkDeferredSuperBirth(source, .es5);
}

test "lowered repeated super producer 8" {
    const source = "let calls=0,fields=0;class P{constructor(){calls++}}class D extends P{x=++fields;constructor(){const go=()=>super();return{go}}}const h=new D;const d=h.go();let error;try{h.go()}catch(e){error=e instanceof ReferenceError}console.log(JSON.stringify([calls,fields,d.x,error]));";
    try checkDeferredDefaultRuntime(source, .es5);
    try checkDeferredSuperBirth(source, .es5);
}

test "lowered repeated super producer 9" {
    const source = "let calls=0,fields=0;class P{constructor(){calls++}}class D extends P{x=(fields++,this);constructor(){const go=()=>super();const first=go();try{go()}catch(e){this.error=e instanceof ReferenceError}this.same=first===this&&this.x===this}}const d=new D;console.log(JSON.stringify([calls,fields,d.same,d.error]));";
    try checkDeferredDefaultRuntime(source, .es5);
    try checkDeferredSuperBirth(source, .es5);
}

test "RN deferred class producer preserves all birth tuples" {
    const unsupported = @import("compat.zig").fromReactNativeVersion(0, 80);
    try std.testing.expect(!unsupported.class and unsupported.arrow);
    for (deferred_super_sources) |source|
        try checkDeferredSuperBirthWithFeatures(source, unsupported, true, true);
}

test "RN deferred class producer retains surrounding class contexts" {
    const controls = [_]struct { source: []const u8, lowered: bool }{
        .{ .source = "class P{}class D extends P{constructor(){super()}}console.log(JSON.stringify([new D instanceof P,Object.getOwnPropertyDescriptor(D,'prototype').writable]));", .lowered = false },
        .{ .source = "class P{m(){return 7}}class D extends P{constructor(){const go=()=>super();go();class E extends P{m(){return super.m()+1}}this.E=E}}const d=new D;console.log(JSON.stringify(new d.E().m()));", .lowered = true },
        .{ .source = "const log=[];class P{m(){log.push('key');return 7}}class D extends P{constructor(){const go=()=>super();go();class E{[(super.m(),'k')](){return 1}}this.E=E}}const d=new D;console.log(JSON.stringify([log,new d.E().k()]));", .lowered = true },
        .{ .source = "class P{base(){return class{}}}class D extends P{constructor(){const go=()=>super();go();class E extends(super.base()){value=1}this.E=E}}const d=new D;console.log(JSON.stringify(new d.E().value));", .lowered = true },
        .{ .source = "class P{}const D=class extends P{#value=3;read(){return this.#value}constructor(){const go=()=>super();go()}};console.log(JSON.stringify([new D().read(),D.name]));", .lowered = true },
        .{ .source = "class P{}class D extends P{constructor(){const go=()=>super();go()}}class E extends P{constructor(){super()}}console.log(JSON.stringify([new D instanceof P,new E instanceof P,Object.getOwnPropertyDescriptor(E,'prototype').writable]));", .lowered = true },
        .{ .source = "class P{}class D extends P{constructor(){function make(){return class E extends P{#value=4;read(){return this.#value}constructor(){const go=()=>super();go()}}}const E=make();const inner=new E;const go=()=>super();go();this.inner=inner}}console.log(JSON.stringify(new D().inner.read()));", .lowered = true },
        .{ .source = "class P{}class D extends P{constructor(){const go=()=>super();go()}}class E extends D{}console.log(JSON.stringify([new E instanceof E,new E instanceof D]));", .lowered = true },
        .{ .source = "class P{m(){return 8}}class D extends P{m(){const go=()=>8;return super.m()+go()-8}}console.log(JSON.stringify(new D().m()));", .lowered = false },
        .{ .source = "class P{}class D extends P{#value=2;constructor(){super()}read(){return this.#value}}console.log(JSON.stringify(new D().read()));", .lowered = false },
    };
    const unsupported = @import("compat.zig").fromReactNativeVersion(0, 80);
    for (controls, 0..) |control, case| {
        std.debug.print("RN CONTEXT START case={d}\n", .{case});
        try checkDeferredSuperBirthWithFeatures(control.source, unsupported, control.lowered, control.lowered);
        try checkDeferredProfileRuntime(control.source, unsupported);
    }
}

test "RN deferred class producer supports an independently supported private feature" {
    var unsupported = @import("compat.zig").fromESTarget(.es2022);
    unsupported.arrow = true;
    try std.testing.expect(!unsupported.class and !unsupported.privateLoweringPlan().fields);
    const source = "class P{}class D extends P{#value=4;constructor(){const go=()=>super();go()}read(){this.#value++;return this?.#value}}console.log(JSON.stringify(new D().read()));";
    try checkDeferredProfileRuntime(source, unsupported);
    try checkDeferredSuperBirthWithFeatures(source, unsupported, true, true);
}

test "RN deferred class producer preserves native child timing eligibility" {
    const controls = [_][]const u8{
        "class P{}class D extends P{constructor(){const go=()=>super();go();class E extends P{x=42;constructor(){let saved=()=>this;super();this.saved=saved}}this.E=E}}const d=new D;const e=new d.E;console.log(JSON.stringify([e.x,e.saved()===e]));",
        "let saved;class P{}class D extends P{constructor(){const go=()=>super();go();class E extends P{x=saved();constructor(){saved=()=>this;super();this.saved=saved}}this.E=E}}const d=new D;const e=new d.E;console.log(JSON.stringify([e.x===e,e.saved()===e]));",
    };
    const unsupported = @import("compat.zig").fromReactNativeVersion(0, 80);
    for (controls, 0..) |source, case| {
        std.debug.print("RN CHILD START case={d}\n", .{case});
        try checkDeferredProfileRuntime(source, unsupported);
        try checkDeferredSuperBirthWithFeatures(source, unsupported, true, true);
    }
}

test "post super switch discriminant preserves outer reference scope" {
    const source = "function Base(){this.mode=1}class Child extends Base{constructor(){super();switch(this.mode){case 1:this.value=1;break;default:this.value=2}}}var child=new Child;console.log(child.value,child instanceof Child);";
    try checkDeferredSuperBirth(source, .es5);
    try checkDeferredDefaultRuntime(source, .es5);
}

const switch_scope_sources = [_][]const u8{
    "class P{}class D extends P{constructor(){super();switch(this.x){default:this.y=1}}}console.log(new D().y)",
    "class P{}class D extends P{constructor(){super();switch(this.x){case 0:this.y=0;break;default:this.y=2}switch(this.y){case 2:this.z=3}}}console.log(new D().z)",
    "class P{}class D extends P{constructor(){super();switch(this.x){default:let value=4;this.y=value}}}console.log(new D().y)",
    "class P{}class D extends P{constructor(){super();switch(this.x){default:{const value=5;this.y=value}}}}console.log(new D().y)",
    "class P{}class D extends P{constructor(){super();switch((()=>this.x)()){default:this.y=6}}}console.log(new D().y)",
    "class P{}class D extends P{constructor(){super();switch((function(){return 0})()){case 0:this.y=7}}}console.log(new D().y)",
    "class P{}class D extends P{constructor(){super();switch(this.x){default:switch(this.y){default:this.z=8}}}}console.log(new D().z)",
    "class P{}class D extends P{constructor(){super();switch(this.x){case this.y:this.z=9;break;default:this.z=0}}}console.log(new D().z)",
    "let order=[];class P{}class D extends P{constructor(){super();switch((order.push(1),this.x)){case (order.push(2),0):break;default:order.push(3)}}}new D;console.log(order.join(','))",
    "let value=10;class P{}class D extends P{constructor(){super();switch(value){default:let value=11;this.y=value}}}console.log(new D().y)",
};

test "post super switch discriminant native scope controls" {
    for (switch_scope_sources) |source| {
        try checkDeferredSuperBirth(source, .es5);
        try checkDeferredDefaultRuntime(source, .es5);
    }
}

test "post super for in destructuring preserves exact reference scope" {
    const source = "var values={a:1};function Base(){}class Child extends Base{constructor(){super();for(let{length} in values)this.value=length}}var child=new Child;console.log(child.value,child instanceof Child);";
    try checkDeferredSuperBirth(source, .es5);
    try checkDeferredDefaultRuntime(source, .es5);
}

const for_in_scope_sources = [_][]const u8{
    "var values={a:1};class P{}class D extends P{constructor(){super();for(let{length} in values){this.value=length}}}console.log(new D().value)",
    "var values={ab:1};class P{}class D extends P{constructor(){super();for(let{length} in values){{let n=length;this.value=n}}}}console.log(new D().value)",
    "var values={abc:1};class P{}class D extends P{constructor(){super();for(let{length} in values)if(length)this.value=length}}console.log(new D().value)",
    "var values={a:1,bb:2};class P{}class D extends P{constructor(){super();this.value=0;outer:for(let{length} in values){if(length===1)continue outer;this.value=length}}}console.log(new D().value)",
    "var values={ab:1};class P{}class D extends P{constructor(){super();for(let[first,second] in values)this.value=first+second}}console.log(new D().value)",
    "var values={a:1};class P{}class D extends P{constructor(){super();for(let{length:size=9} in values)this.value=size}}console.log(new D().value)",
    "var values={ab:1};class P{}class D extends P{constructor(){super();this.key='length';for(let{[this.key]:size} in values)this.value=size}}console.log(new D().value)",
    "class P{}class D extends P{constructor(){super();this.values={a:1};for(let{length} in this.values)this.value=length}}console.log(new D().value)",
    "var values={a:1};class P{}class D extends P{constructor(){super();for(var{length} in values)this.value=length}}console.log(new D().value)",
    "var values={a:1};class P{}class D extends P{constructor(){super();for(let{length} in values){const get=()=>this;function read(){return 9}this.value=get()===this?read()+length:0}}}console.log(new D().value)",
};

test "post super for in destructuring body owner native controls" {
    for (for_in_scope_sources) |source| {
        try checkDeferredSuperBirth(source, .es5);
        try checkDeferredDefaultRuntime(source, .es5);
    }
}

test "post super for in destructuring native rest neighboring callers" {
    const sources_rest = [_][]const u8{
        "var values={abc:1};class P{}class D extends P{constructor(){super();for(let{length,...rest} in values)this.value=length+Object.keys(rest).length}}console.log(new D().value)",
        "var values=[{x:2,y:3}];class P{}class D extends P{constructor(){super();for(let{x,...rest} of values){this.value=x+rest.y}}}console.log(new D().value)",
        "class P{constructor(){this.values=[{x:2,y:3}]}}class D extends P{constructor(){super();for(let{x,...rest} of this.values)this.value=x+rest.y}}console.log(new D().value)",
        "var values={abc:1},length,rest;class P{}class D extends P{constructor(){super();for({length,...rest} in values)this.value=length+Object.keys(rest).length}}console.log(new D().value)",
    };
    for (sources_rest) |source| try checkDeferredDefaultRuntime(source, .es2017);
}

test "post super for in destructuring owner rejects atomically and restores" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source = "function run(){for(let{length} in values){use(length)}for(let{length} in other){otherUse(length)}}";
    var scanner = try @import("../lexer/scanner.zig").Scanner.init(a, source);
    var parser = @import("../parser/parser.zig").Parser.init(a, &scanner);
    _ = try parser.parse();
    var analyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer.init(a, &parser.ast);
    analyzer.enable_exact_declaration_anchors = true;
    analyzer.enable_stmt_info = true;
    try analyzer.analyze();
    var t = try Transformer.init(a, &parser.ast, .{});
    try t.initSymbolIds(analyzer.symbol_ids.items);
    t.symbols = analyzer.symbols.items;
    t.references = analyzer.references.items;
    t.scopes = analyzer.scopes.items;
    t.scope_maps = analyzer.scope_maps.items;
    t.scope_owner_map = analyzer.scope_owner_map;
    t.semantic_edit_enabled = true;
    var loops: std.ArrayList(ast.NodeIndex) = .empty;
    for (t.ast.nodes.items, 0..) |node, raw| {
        if (node.tag == .for_in_statement) try loops.append(a, @fromBackingInt(@as(u32, @intCast(raw))));
    }
    try std.testing.expectEqual(@as(usize, 2), loops.items.len);
    const first = loops.items[0];
    const second = loops.items[1];
    const node = t.ast.getNode(first);
    const loop_scope = t.outputOwnedScope(first).?;
    const sibling_scope = t.outputOwnedScope(second).?;
    const body_scope = t.outputOwnedScope(node.data.ternary.c).?;
    t.current_scope = loop_scope;
    const D = @import("es2015_destructuring.zig").ES2015Destructuring(Transformer);
    const refs_before = try a.dupe(@import("../semantic/symbol.zig").Reference, analyzer.references.items);
    const scopes_before = try a.dupe(@import("../semantic/scope.zig").Scope, analyzer.scopes.items);
    const ids_before = try a.dupe(?u32, t.symbol_ids.items);
    const node_count = t.ast.nodes.items.len;
    const symbol_count = t.symbols.len;
    const owner_count = t.scope_owner_map.count();
    try std.testing.expectEqual(body_scope, (try D.validateIterationBodyOwner(&t, first, node)).?);
    try std.testing.expectError(error.InvalidIterationBodyOwner, D.validateIterationBodyOwner(&t, .none, node));
    try std.testing.expectError(error.InvalidIterationBodyOwner, D.validateIterationBodyOwner(&t, @fromBackingInt(@as(u32, @intCast(node_count + 1))), node));
    try std.testing.expectError(error.InvalidIterationBodyOwner, D.validateIterationBodyOwner(&t, second, node));
    var wrong_node = node;
    wrong_node.data.ternary.c = t.ast.getNode(second).data.ternary.c;
    try std.testing.expectError(error.InvalidIterationBodyOwner, D.validateIterationBodyOwner(&t, first, wrong_node));
    wrong_node = node;
    wrong_node.tag = .for_of_statement;
    try std.testing.expectError(error.InvalidIterationBodyOwner, D.validateIterationBodyOwner(&t, first, wrong_node));
    t.current_scope = sibling_scope;
    try std.testing.expectError(error.InvalidIterationBodyOwner, D.validateIterationBodyOwner(&t, first, node));
    t.current_scope = .none;
    try std.testing.expectError(error.InvalidIterationBodyOwner, D.validateIterationBodyOwner(&t, first, node));
    t.current_scope = loop_scope;
    analyzer.scopes.items[loop_scope.toIndex()].kind = .function;
    try std.testing.expectError(error.InvalidIterationBodyOwner, D.validateIterationBodyOwner(&t, first, node));
    analyzer.scopes.items[loop_scope.toIndex()] = scopes_before[loop_scope.toIndex()];
    analyzer.scopes.items[body_scope.toIndex()].kind = .function;
    try std.testing.expectError(error.InvalidIterationBodyOwner, D.validateIterationBodyOwner(&t, first, node));
    analyzer.scopes.items[body_scope.toIndex()] = scopes_before[body_scope.toIndex()];
    analyzer.scopes.items[body_scope.toIndex()].parent = sibling_scope;
    try std.testing.expectError(error.InvalidIterationBodyOwner, D.validateIterationBodyOwner(&t, first, node));
    analyzer.scopes.items[body_scope.toIndex()] = scopes_before[body_scope.toIndex()];
    const saved_loop = t.scope_owner_map.fetchRemove(@backingInt(first)).?;
    try std.testing.expectError(error.InvalidIterationBodyOwner, D.validateIterationBodyOwner(&t, first, node));
    try t.scope_owner_map.put(a, saved_loop.key, saved_loop.value);
    const saved_body = t.scope_owner_map.fetchRemove(@backingInt(node.data.ternary.c)).?;
    try std.testing.expectError(error.InvalidIterationBodyOwner, D.validateIterationBodyOwner(&t, first, node));
    try t.scope_owner_map.put(a, saved_body.key, saved_body.value);
    try std.testing.expectEqual(body_scope, (try D.validateIterationBodyOwner(&t, first, node)).?);
    try std.testing.expect(t.semantic_editor == null);
    try std.testing.expectEqual(node_count, t.ast.nodes.items.len);
    try std.testing.expectEqual(symbol_count, t.symbols.len);
    try std.testing.expectEqual(owner_count, t.scope_owner_map.count());
    try std.testing.expectEqualSlices(?u32, ids_before, t.symbol_ids.items);
    for (refs_before, analyzer.references.items) |before, after| try std.testing.expect(std.meta.eql(before, after));
    for (scopes_before, analyzer.scopes.items) |before, after| try std.testing.expect(std.meta.eql(before, after));
}
