const std = @import("std");
const Options = @import("transformer.zig").TransformOptions;
const ast = @import("../parser/ast.zig");
const Case = struct { name: []const u8, source: []const u8, native: []const u8, expected: []const u8 };
const cases = [_]Case{
    .{ .name = "own-read", .source = "namespace N{export const get=()=>arguments[0]}console.log(N.get()===N)", .native = "\"use strict\";\nvar N;\n(function (N) {\n    N.get = () => arguments[0];\n})(N || (N = {}));\nconsole.log(N.get() === N);\n", .expected = "true\n" },
    .{ .name = "merged-invocation-lifetime", .source = "namespace N{export const one=()=>arguments}namespace N{export const two=()=>arguments}console.log(N.one()!==N.two(),N.one()[0]===N,N.two()[0]===N)", .native = "\"use strict\";\nvar N;\n(function (N) {\n    N.one = () => arguments;\n})(N || (N = {}));\n(function (N) {\n    N.two = () => arguments;\n})(N || (N = {}));\nconsole.log(N.one() !== N.two(), N.one()[0] === N, N.two()[0] === N);\n", .expected = "true true true\n" },
    .{ .name = "nested-owner", .source = "namespace Outer{export namespace Inner{export const get=()=>arguments[0]}export const get=()=>arguments[0]}console.log(Outer.Inner.get()===Outer.Inner,Outer.get()===Outer)", .native = "\"use strict\";\nvar Outer;\n(function (Outer) {\n    let Inner;\n    (function (Inner) {\n        Inner.get = () => arguments[0];\n    })(Inner = Outer.Inner || (Outer.Inner = {}));\n    Outer.get = () => arguments[0];\n})(Outer || (Outer = {}));\nconsole.log(Outer.Inner.get() === Outer.Inner, Outer.get() === Outer);\n", .expected = "true true\n" },
    .{ .name = "ordinary-owner-frontier", .source = "namespace N{export const one=()=>arguments;export function own(value:number){return(()=>arguments[0])()}export const two=()=>arguments}console.log(N.one()===N.two(),N.own(7),N.one()[0]===N)", .native = "\"use strict\";\nvar N;\n(function (N) {\n    N.one = () => arguments;\n    function own(value) { return (() => arguments[0])(); }\n    N.own = own;\n    N.two = () => arguments;\n})(N || (N = {}));\nconsole.log(N.one() === N.two(), N.own(7), N.one()[0] === N);\n", .expected = "true 7 true\n" },
    .{ .name = "object-mutation", .source = "namespace N{export const get=()=>arguments;arguments[0]={value:7};export const value=get()[0].value}console.log(N.value,N.get()[0].value)", .native = "\"use strict\";\nvar N;\n(function (N) {\n    N.get = () => arguments;\n    arguments[0] = { value: 7 };\n    N.value = N.get()[0].value;\n})(N || (N = {}));\nconsole.log(N.value, N.get()[0].value);\n", .expected = "7 7\n" },
    .{ .name = "strict-callee", .source = "namespace N{export const get=()=>arguments.callee}try{N.get()}catch(e){console.log(e.name)}", .native = "\"use strict\";\nvar N;\n(function (N) {\n    N.get = () => arguments.callee;\n})(N || (N = {}));\ntry {\n    N.get();\n}\ncatch (e) {\n    console.log(e.name);\n}\n", .expected = "TypeError\n" },
    .{ .name = "property-negative", .source = "namespace N{export const get=()=>({arguments:7}).arguments}console.log(N.get())", .native = "\"use strict\";\nvar N;\n(function (N) {\n    N.get = () => ({ arguments: 7 }).arguments;\n})(N || (N = {}));\nconsole.log(N.get());\n", .expected = "7\n" },
    .{ .name = "source-alias-collision", .source = "namespace N{export const _arguments=7;export const arguments$1=9;export const get=()=>arguments[0]}console.log(N.get()===N,N._arguments,N.arguments$1)", .native = "\"use strict\";\nvar N;\n(function (N) {\n    N._arguments = 7;\n    N.arguments$1 = 9;\n    N.get = () => arguments[0];\n})(N || (N = {}));\nconsole.log(N.get() === N, N._arguments, N.arguments$1);\n", .expected = "true 7 9\n" },
    .{ .name = "nested-restored-outer", .source = "namespace Outer{export const first=()=>arguments;export namespace Inner{export const get=()=>arguments}export const second=()=>arguments}console.log(Outer.first()===Outer.second(),Outer.Inner.get()!==Outer.first(),Outer.Inner.get()[0]===Outer.Inner)", .native = "\"use strict\";\nvar Outer;\n(function (Outer) {\n    Outer.first = () => arguments;\n    let Inner;\n    (function (Inner) {\n        Inner.get = () => arguments;\n    })(Inner = Outer.Inner || (Outer.Inner = {}));\n    Outer.second = () => arguments;\n})(Outer || (Outer = {}));\nconsole.log(Outer.first() === Outer.second(), Outer.Inner.get() !== Outer.first(), Outer.Inner.get()[0] === Outer.Inner);\n", .expected = "true true true\n" },
    .{ .name = "this-owner", .source = "namespace N{export const get=()=>this}console.log(N.get()===undefined)", .native = "\"use strict\";\nvar N;\n(function (N) {\n    N.get = () => this;\n})(N || (N = {}));\nconsole.log(N.get() === undefined);\n", .expected = "true\n" },
};
fn runCase(index: usize, rn: bool, minify: bool) !void {
    const case = cases[index];
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const native = try std.process.run(a, std.testing.io, .{ .argv = &.{ "node", "-e", case.native } });
    try std.testing.expect(native.term == .exited and native.term.exited == 0);
    try std.testing.expectEqualStrings(case.expected, native.stdout);
    var unsupported = if (rn) Options.compat.fromReactNativeVersion(0, 80) else Options.compat.fromESTarget(.es2022);
    unsupported.arrow = true;
    std.debug.print("NAMESPACE PROFILE {s} rn={} minify={}\nsource:{s}\n", .{ case.name, rn, minify, case.source });
    const result = try @import("../transpile.zig").transpile(a, case.source, "input.ts", .{ .unsupported = unsupported, .minify_identifiers = minify, .minify_syntax = minify, .minify_whitespace = minify });
    const actual = try std.process.run(a, std.testing.io, .{ .argv = &.{ "node", "-e", result.code } });
    if (actual.term != .exited or actual.term.exited != 0 or !std.mem.eql(u8, case.expected, actual.stdout))
        std.debug.print("code:{s}\nexpected:{s}actual:{s}stderr:{s}\n", .{ result.code, case.expected, actual.stdout, actual.stderr });
    try std.testing.expect(actual.term == .exited and actual.term.exited == 0);
    try std.testing.expectEqualStrings(case.expected, actual.stdout);
}

test "namespace live arguments identities exist before the output walker" {
    const Transformer = @import("transformer.zig").Transformer;
    const ScopeId = @import("../semantic/scope.zig").ScopeId;
    const utils = @import("output_scope_test_utils.zig");
    for (cases) |case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var scanner = try @import("../lexer/scanner.zig").Scanner.init(a, case.source);
        var parser = @import("../parser/parser.zig").Parser.init(a, &scanner);
        parser.configureFromExtension(".ts");
        const root = try parser.parse();
        try std.testing.expectEqual(@as(usize, 0), parser.errors.items.len);
        var analyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer.init(a, &parser.ast);
        analyzer.is_module = parser.is_module;
        analyzer.is_ts = true;
        analyzer.enable_stmt_info = true;
        analyzer.enable_exact_declaration_anchors = true;
        try analyzer.analyze();
        try std.testing.expectEqual(@as(usize, 0), analyzer.errors.items.len);
        var unsupported = Options.compat.fromReactNativeVersion(0, 80);
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
        t.namespace_member_owners = &analyzer.namespace_member_owners;
        t.namespace_declaration_owners = &analyzer.namespace_declaration_owners;
        t.unresolved_references = &analyzer.unresolved_references;
        t.semantic_edit_enabled = true;
        try t.buildBlockRenameMap();
        const saved_frame = t.capture_frame;
        const saved_scope = t.capture_scope;
        const saved_arrow_depth = t.arrow_this_depth;
        const saved_needs_this = t.needs_this_var;
        const saved_needs_arguments = t.needs_arguments_var;
        const output = try t.visitNode(root);
        try std.testing.expectEqual(saved_frame, t.capture_frame);
        try std.testing.expectEqual(saved_scope, t.capture_scope);
        try std.testing.expectEqual(saved_arrow_depth, t.arrow_this_depth);
        try std.testing.expectEqual(saved_needs_this, t.needs_this_var);
        try std.testing.expectEqual(saved_needs_arguments, t.needs_arguments_var);
        var parents = try utils.buildParentMap(a, t.ast, output);
        const editor = &t.semantic_editor.?;
        var cells = t.live_arguments_cells.iterator();
        var checked: usize = 0;
        while (cells.next()) |entry| {
            const cell = entry.value_ptr;
            var namespace_owner: ?ast.NodeIndex = null;
            for (t.ast.nodes.items, 0..) |node, index| {
                if (node.tag != .ts_module_declaration) continue;
                const owner: ast.NodeIndex = @fromBackingInt(@as(u32, @intCast(index)));
                if (t.outputOwnedScope(owner) == cell.scope and parents.contains(@intCast(index))) namespace_owner = owner;
            }
            if (namespace_owner == null) continue; // ordinary nested function control
            try std.testing.expect(!cell.declaration.isNone());
            try std.testing.expect(editor.scopes.items[cell.scope.toIndex()].is_strict);
            try std.testing.expectEqual(cell.scope, editor.symbols.items[entry.key_ptr.*].scope_id);
            try std.testing.expectEqual(cell.scope, editor.symbols.items[@backingInt(cell.engine_id)].scope_id);
            var declarations: usize = 0;
            var engine_reads: usize = 0;
            var source_refs: usize = 0;
            for (editor.references.items) |reference| {
                if (@backingInt(reference.symbol_id) == entry.key_ptr.* and reference.flags.declare) {
                    const anchor = reference.declaration_node_index;
                    try std.testing.expect(!anchor.isNone() and parents.contains(@backingInt(anchor)));
                    const actual = utils.expectedScope(t.ast, output, &parents, &editor.scope_owner_map, @backingInt(anchor)).?;
                    try std.testing.expectEqual(cell.scope, actual);
                    try std.testing.expectEqual(cell.scope, reference.scope_id);
                    declarations += 1;
                }
                if (reference.node_index.isNone() or !parents.contains(@backingInt(reference.node_index))) continue;
                if (reference.symbol_id != cell.engine_id and @backingInt(reference.symbol_id) != entry.key_ptr.*) continue;
                const actual: ScopeId = utils.expectedScope(t.ast, output, &parents, &editor.scope_owner_map, @backingInt(reference.node_index)).?;
                try std.testing.expectEqual(actual, reference.scope_id);
                try std.testing.expectEqual(@backingInt(reference.symbol_id), t.getSymbolIdAt(reference.node_index).?);
                if (reference.symbol_id == cell.engine_id) {
                    try std.testing.expectEqual(cell.scope, actual);
                    try std.testing.expect(reference.flags.read and !reference.flags.write);
                    engine_reads += 1;
                } else source_refs += 1;
            }
            try std.testing.expectEqual(@as(usize, 1), declarations);
            try std.testing.expectEqual(@as(usize, 1), engine_reads);
            try std.testing.expect(source_refs > 0);
            var live_nodes = parents.keyIterator();
            while (live_nodes.next()) |raw| {
                const id = t.getSymbolIdAt(@fromBackingInt(raw.*)) orelse continue;
                if (id != entry.key_ptr.* and id != @backingInt(cell.engine_id)) continue;
                const live_node = t.ast.nodes.items[raw.*];
                if (live_node.tag != .identifier_reference and live_node.tag != .assignment_target_identifier) continue;
                const reference = (try editor.referenceForNode(@fromBackingInt(raw.*))) orelse return error.MissingCreationTimeReference;
                try std.testing.expectEqual(id, @backingInt(reference.symbol_id));
                const actual = utils.expectedScope(t.ast, output, &parents, &editor.scope_owner_map, raw.*).?;
                try std.testing.expectEqual(actual, reference.scope_id);
                try std.testing.expect(reference.flags.read or reference.flags.write);
            }
            checked += 1;
        }
        if (!std.mem.eql(u8, case.name, "property-negative") and !std.mem.eql(u8, case.name, "this-owner")) try std.testing.expect(checked > 0);
    }
}
test "namespace live arguments own-read native-default plain" {
    try runCase(0, false, false);
}
test "namespace live arguments own-read native-default minify" {
    try runCase(0, false, true);
}
test "namespace live arguments own-read rn080 plain" {
    try runCase(0, true, false);
}
test "namespace live arguments own-read rn080 minify" {
    try runCase(0, true, true);
}
test "namespace live arguments merged-invocation-lifetime native-default plain" {
    try runCase(1, false, false);
}
test "namespace live arguments merged-invocation-lifetime native-default minify" {
    try runCase(1, false, true);
}
test "namespace live arguments merged-invocation-lifetime rn080 plain" {
    try runCase(1, true, false);
}
test "namespace live arguments merged-invocation-lifetime rn080 minify" {
    try runCase(1, true, true);
}
test "namespace live arguments nested-owner native-default plain" {
    try runCase(2, false, false);
}
test "namespace live arguments nested-owner native-default minify" {
    try runCase(2, false, true);
}
test "namespace live arguments nested-owner rn080 plain" {
    try runCase(2, true, false);
}
test "namespace live arguments nested-owner rn080 minify" {
    try runCase(2, true, true);
}
test "namespace live arguments ordinary-owner-frontier native-default plain" {
    try runCase(3, false, false);
}
test "namespace live arguments ordinary-owner-frontier native-default minify" {
    try runCase(3, false, true);
}
test "namespace live arguments ordinary-owner-frontier rn080 plain" {
    try runCase(3, true, false);
}
test "namespace live arguments ordinary-owner-frontier rn080 minify" {
    try runCase(3, true, true);
}
test "namespace live arguments object-mutation native-default plain" {
    try runCase(4, false, false);
}
test "namespace live arguments object-mutation native-default minify" {
    try runCase(4, false, true);
}
test "namespace live arguments object-mutation rn080 plain" {
    try runCase(4, true, false);
}
test "namespace live arguments object-mutation rn080 minify" {
    try runCase(4, true, true);
}
test "namespace live arguments strict-callee native-default plain" {
    try runCase(5, false, false);
}
test "namespace live arguments strict-callee native-default minify" {
    try runCase(5, false, true);
}
test "namespace live arguments strict-callee rn080 plain" {
    try runCase(5, true, false);
}
test "namespace live arguments strict-callee rn080 minify" {
    try runCase(5, true, true);
}
test "namespace live arguments property-negative native-default plain" {
    try runCase(6, false, false);
}
test "namespace live arguments property-negative native-default minify" {
    try runCase(6, false, true);
}
test "namespace live arguments property-negative rn080 plain" {
    try runCase(6, true, false);
}
test "namespace live arguments property-negative rn080 minify" {
    try runCase(6, true, true);
}
test "namespace live arguments source-alias-collision native-default plain" {
    try runCase(7, false, false);
}
test "namespace live arguments source-alias-collision native-default minify" {
    try runCase(7, false, true);
}
test "namespace live arguments source-alias-collision rn080 plain" {
    try runCase(7, true, false);
}
test "namespace live arguments source-alias-collision rn080 minify" {
    try runCase(7, true, true);
}
test "namespace live arguments nested-restored-outer native-default plain" {
    try runCase(8, false, false);
}
test "namespace live arguments nested-restored-outer native-default minify" {
    try runCase(8, false, true);
}
test "namespace live arguments nested-restored-outer rn080 plain" {
    try runCase(8, true, false);
}
test "namespace live arguments nested-restored-outer rn080 minify" {
    try runCase(8, true, true);
}
test "namespace live arguments this-owner native-default plain" {
    try runCase(9, false, false);
}
test "namespace live arguments this-owner native-default minify" {
    try runCase(9, false, true);
}
test "namespace live arguments this-owner rn080 plain" {
    try runCase(9, true, false);
}
test "namespace live arguments this-owner rn080 minify" {
    try runCase(9, true, true);
}
