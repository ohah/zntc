const std = @import("std");
const ast = @import("../parser/ast.zig");
const Transformer = @import("transformer.zig").Transformer;
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
