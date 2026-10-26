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
    var failures: usize = 0;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const native = try std.process.run(a, std.testing.io, .{ .argv = &.{ "node", "-e", source } });
    try std.testing.expect(native.term == .exited and native.term.exited == 0);
    for ([_]bool{ false, true }) |minify| {
        var unsupported = @import("transformer.zig").TransformOptions.compat.fromReactNativeVersion(0, 80);
        unsupported.arrow = true;
        std.debug.print("NAME START case={d} minify={}\n", .{ case, minify });
        const result = try @import("../transpile.zig").transpile(a, source, "input.cjs", .{
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
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var scanner = try @import("../lexer/scanner.zig").Scanner.init(a, source);
    var parser = @import("../parser/parser.zig").Parser.init(a, &scanner);
    parser.configureFromExtension(".cjs");
    const root = try parser.parse();
    var analyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer.init(a, &parser.ast);
    analyzer.enable_stmt_info = true;
    analyzer.enable_exact_declaration_anchors = true;
    try analyzer.analyze();
    var unsupported = @import("transformer.zig").TransformOptions.compat.fromReactNativeVersion(0, 80);
    unsupported.arrow = true;
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
    t.semantic_edit_enabled = true;
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
