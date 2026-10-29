const std = @import("std");
const Options = @import("transformer.zig").TransformOptions;
const ast = @import("../parser/ast.zig");
const Case = struct { name: []const u8, source: []const u8, native: []const u8, expected: []const u8 };
const cases = [_]Case{
    .{ .name = "own-engine-read", .source = "enum E{A=Number(arguments[0]===E)}console.log(E.A)", .native = "\"use strict\";\nvar E;\n(function (E) {\n    E[E[\"A\"] = Number(arguments[0] === E)] = \"A\";\n})(E || (E = {}));\nconsole.log(E.A);\n", .expected = "1\n" },
    .{ .name = "arrow-own-engine", .source = "enum E{A=Number((()=>arguments[0]===E)())}console.log(E.A)", .native = "\"use strict\";\nvar E;\n(function (E) {\n    E[E[\"A\"] = Number((() => arguments[0] === E)())] = \"A\";\n})(E || (E = {}));\nconsole.log(E.A);\n", .expected = "1\n" },
    .{ .name = "merged-lifetime", .source = "let first,second;enum E{A=((first=()=>arguments),0)}enum E{B=((second=()=>arguments),1)}console.log(first()!==second(),first()[0]===E,second()[0]===E)", .native = "\"use strict\";\nlet first, second;\nvar E;\n(function (E) {\n    E[E[\"A\"] = ((first = () => arguments), 0)] = \"A\";\n})(E || (E = {}));\n(function (E) {\n    E[E[\"B\"] = ((second = () => arguments), 1)] = \"B\";\n})(E || (E = {}));\nconsole.log(first() !== second(), first()[0] === E, second()[0] === E);\n", .expected = "true true true\n" },
    .{ .name = "strict-this", .source = "enum E{A=Number(this===undefined)}console.log(E.A)", .native = "\"use strict\";\nvar E;\n(function (E) {\n    E[E[\"A\"] = Number(this === undefined)] = \"A\";\n})(E || (E = {}));\nconsole.log(E.A);\n", .expected = "1\n" },
    .{ .name = "strict-callee", .source = "try{enum E{A=Number(arguments.callee===null)}console.log(\"miss\")}catch(e){console.log(e.name)}", .native = "\"use strict\";\ntry {\n    let E;\n    (function (E) {\n        E[E[\"A\"] = Number(arguments.callee === null)] = \"A\";\n    })(E || (E = {}));\n    console.log(\"miss\");\n}\ncatch (e) {\n    console.log(e.name);\n}\n", .expected = "TypeError\n" },
    .{ .name = "member-arguments-shadow", .source = "enum E{arguments=7,A=(()=>arguments)()}console.log(E.A)", .native = "\"use strict\";\nvar E;\n(function (E) {\n    E[E[\"arguments\"] = 7] = \"arguments\";\n    E[E[\"A\"] = (() => E.arguments)()] = \"A\";\n})(E || (E = {}));\nconsole.log(E.A);\n", .expected = "7\n" },
    .{ .name = "ordinary-function-frontier", .source = "enum E{A=(function(value:number){return(()=>arguments[0])()})(7)}console.log(E.A)", .native = "\"use strict\";\nvar E;\n(function (E) {\n    E[E[\"A\"] = (function (value) { return (() => arguments[0])(); })(7)] = \"A\";\n})(E || (E = {}));\nconsole.log(E.A);\n", .expected = "7\n" },
    .{ .name = "namespace-owner-frontier", .source = "namespace N{export const get=()=>arguments[0];export enum E{A=Number((()=>arguments[0]===E)())}}console.log(N.get()===N,N.E.A)", .native = "\"use strict\";\nvar N;\n(function (N) {\n    N.get = () => arguments[0];\n    let E;\n    (function (E) {\n        E[E[\"A\"] = Number((() => arguments[0] === E)())] = \"A\";\n    })(E = N.E || (N.E = {}));\n})(N || (N = {}));\nconsole.log(N.get() === N, N.E.A);\n", .expected = "true 1\n" },
    .{ .name = "object-property-mutation", .source = "enum E{A=((arguments[0].seen=7),0),B=Number((()=>arguments[0].seen===7)())}console.log(E.seen,E.B)", .native = "\"use strict\";\nvar E;\n(function (E) {\n    E[E[\"A\"] = ((arguments[0].seen = 7), 0)] = \"A\";\n    E[E[\"B\"] = Number((() => arguments[0].seen === 7)())] = \"B\";\n})(E || (E = {}));\nconsole.log(E.seen, E.B);\n", .expected = "7 1\n" },
    .{ .name = "source-alias-collision", .source = "enum E{arguments$1=7,A=Number((()=>arguments[0]===E)())}console.log(E.A,E.arguments$1)", .native = "\"use strict\";\nvar E;\n(function (E) {\n    E[E[\"arguments$1\"] = 7] = \"arguments$1\";\n    E[E[\"A\"] = Number((() => arguments[0] === E)())] = \"A\";\n})(E || (E = {}));\nconsole.log(E.A, E.arguments$1);\n", .expected = "1 7\n" },
    .{ .name = "strict-eval-this", .source = "enum E{A=eval(\"Number(this===undefined)\")}console.log(E.A)", .native = "\"use strict\";\nvar E;\n(function (E) {\n    E[E[\"A\"] = eval(\"Number(this===undefined)\")] = \"A\";\n})(E || (E = {}));\nconsole.log(E.A);\n", .expected = "1\n" },
    .{ .name = "derived-outer-this-frontier", .source = "class P{};class D extends P{constructor(){enum E{A=Number((()=>this)()===undefined)}console.log(E.A);super()}}new D()", .native = "\"use strict\";class P{};class D extends P{constructor(){var E;(function(E){E.A=Number((()=>this)()===undefined)})(E||(E={}));console.log(E.A);super()}}new D()", .expected = "1\n" },
    .{ .name = "static-block-this-frontier", .source = "class C{static{enum E{A=Number((()=>this)()===undefined)}console.log(E.A)}}", .native = "\"use strict\";class C{static{var E;(function(E){E.A=Number((()=>this)()===undefined)})(E||(E={}));console.log(E.A)}}", .expected = "1\n" },
};
test "enum runtime prelude native oracle preserves ordinary engine and strictness" {
    for (cases) |case| for ([_]bool{ false, true }) |es5| for ([_]bool{ false, true }) |minify| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const reference = try std.process.run(a, std.testing.io, .{ .argv = &.{ "node", "-e", case.native } });
        try std.testing.expect(reference.term == .exited and reference.term.exited == 0);
        try std.testing.expectEqualStrings(case.expected, reference.stdout);
        errdefer std.debug.print("enum case={s} es5={} minify={} source={s}\n", .{ case.name, es5, minify, case.source });
        const unsupported = if (es5) Options.compat.fromESTarget(.es5) else Options.compat.fromReactNativeVersion(0, 80);
        const result = try @import("../transpile.zig").transpile(a, case.source, "input.ts", .{ .unsupported = unsupported, .minify_identifiers = minify, .minify_syntax = minify, .minify_whitespace = minify });
        const actual = try std.process.run(a, std.testing.io, .{ .argv = &.{ "node", "-e", result.code } });
        if (actual.term != .exited or actual.term.exited != 0 or !std.mem.eql(u8, case.expected, actual.stdout)) std.debug.print("enum code={s}\nstdout={s}stderr={s}\n", .{ result.code, actual.stdout, actual.stderr });
        try std.testing.expect(actual.term == .exited and actual.term.exited == 0);
        try std.testing.expectEqualStrings(case.expected, actual.stdout);
    };
}

test "enum runtime prelude exact owners and references exist before the final walker" {
    const ScopeId = @import("../semantic/scope.zig").ScopeId;
    const utils = @import("output_scope_test_utils.zig");
    const sources = [_][]const u8{
        "enum E{A=Number((()=>arguments[0]===E)())}",
        "let first,second;enum E{A=((first=()=>arguments),0)}enum E{B=((second=()=>arguments),1)}",
        "namespace N{export const get=()=>arguments[0];export enum E{A=Number((()=>arguments[0]===E)())}}",
        "enum E{A=Number((()=>this)()===undefined),B=Number((()=>arguments[0]===E)())}",
    };
    for (sources) |source| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var scanner = try @import("../lexer/scanner.zig").Scanner.init(a, source);
        var parser = @import("../parser/parser.zig").Parser.init(a, &scanner);
        parser.configureFromExtension(".ts");
        const root = try parser.parse();
        var analyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer.init(a, &parser.ast);
        analyzer.is_strict_mode = parser.is_strict_mode;
        analyzer.is_module = parser.is_module;
        analyzer.is_ts = true;
        analyzer.enable_stmt_info = true;
        analyzer.enable_exact_declaration_anchors = true;
        try analyzer.analyze();
        try std.testing.expectEqual(@as(usize, 0), analyzer.errors.items.len);
        var t = try @import("transformer.zig").Transformer.init(a, &parser.ast, .{ .unsupported = Options.compat.fromESTarget(.es5) });
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
        const before_frame = t.capture_frame;
        const before_scope = t.capture_scope;
        const before_depth = t.arrow_this_depth;
        const before_this = t.needs_this_var;
        const before_arguments = t.needs_arguments_var;
        const output = try t.visitNode(root);
        try std.testing.expectEqual(before_frame, t.capture_frame);
        try std.testing.expectEqual(before_scope, t.capture_scope);
        try std.testing.expectEqual(before_depth, t.arrow_this_depth);
        try std.testing.expectEqual(before_this, t.needs_this_var);
        try std.testing.expectEqual(before_arguments, t.needs_arguments_var);
        try std.testing.expect(t.enum_capture_plan == null);
        var parents = try utils.buildParentMap(a, t.ast, output);
        var owners: std.AutoHashMapUnmanaged(u32, u32) = .empty;
        var nodes = parents.keyIterator();
        while (nodes.next()) |raw| if (t.outputOwnedScope(@fromBackingInt(raw.*))) |scope| {
            try owners.put(a, raw.*, @backingInt(scope));
        };
        if (t.outputOwnedScope(output)) |scope| try owners.put(a, @backingInt(output), @backingInt(scope));
        const editor = &t.semantic_editor.?;
        var enum_count: usize = 0;
        var checked_reads: usize = 0;
        var checked_declarations: usize = 0;
        var live_nodes = parents.keyIterator();
        while (live_nodes.next()) |raw| {
            const node = t.ast.nodes.items[raw.*];
            if (node.tag == .ts_enum_declaration) {
                enum_count += 1;
                const scope = t.outputOwnedScope(@fromBackingInt(raw.*)) orelse return error.EnumMissingActualScope;
                const prefix = t.ast.readExtraNode(node.data.extra, ast.EnumExtra.runtime_prelude);
                try std.testing.expectEqual(raw.*, parents.get(@backingInt(prefix)).?);
                try std.testing.expectEqual(scope, t.outputOwnedScope(prefix).?);
                try std.testing.expectEqual(.function, editor.scopes.items[scope.toIndex()].kind);
                const block = t.ast.getNode(prefix);
                try std.testing.expect(block.data.list.len >= 2);
                try std.testing.expectEqual(.directive, t.ast.getNode(t.ast.readExtraNode(block.data.list.start, 0)).tag);
            }
            const id = t.getSymbolIdAt(@fromBackingInt(raw.*)) orelse continue;
            var capture = false;
            var cells = t.live_arguments_cells.iterator();
            while (cells.next()) |cell| if (id == cell.key_ptr.* or id == @backingInt(cell.value_ptr.engine_id)) {
                capture = true;
            };
            if (editor.symbols.items[id].synthetic_kind == .this_capture_binding) capture = true;
            // A non-late this capture has no synthetic role; its exact frame
            // handle is still the authoritative producer-selected identity.
            var capture_ids = t.capture_binding_ids.valueIterator();
            while (capture_ids.next()) |capture_id| if (capture_id.* == id) {
                capture = true;
            };
            if (!capture) continue;
            const actual: ScopeId = utils.expectedScope(t.ast, output, &parents, &owners, raw.*) orelse return error.MissingActualEnumReferenceOwner;
            if (node.tag == .binding_identifier) {
                var declarations: usize = 0;
                for (editor.references.items) |reference| if (reference.flags.declare and reference.declaration_node_index == @as(ast.NodeIndex, @fromBackingInt(raw.*))) {
                    try std.testing.expectEqual(id, @backingInt(reference.symbol_id));
                    try std.testing.expectEqual(actual, reference.scope_id);
                    declarations += 1;
                };
                try std.testing.expectEqual(@as(usize, 1), declarations);
                checked_declarations += 1;
            } else if (node.tag == .identifier_reference) {
                const reference = (try editor.referenceForNode(@fromBackingInt(raw.*))) orelse return error.MissingEnumReferenceAtCreation;
                try std.testing.expectEqual(id, @backingInt(reference.symbol_id));
                try std.testing.expectEqual(actual, reference.scope_id);
                try std.testing.expect(reference.flags.read and !reference.flags.write and !reference.flags.declare);
                checked_reads += 1;
            }
        }
        try std.testing.expect(enum_count > 0 and checked_reads >= 2 and checked_declarations >= 1);
        const contexts = try @import("../semantic/statement_coordinates.zig").collect(a, t.ast, output);
        for (editor.references.items) |reference| {
            const anchor = if (reference.flags.declare) reference.declaration_node_index else reference.node_index;
            if (anchor.isNone() or @backingInt(anchor) >= contexts.len) continue;
            const context = contexts[@backingInt(anchor)] orelse continue;
            // Only rows within an enum are published by this producer.
            var cursor = @backingInt(anchor);
            var in_enum = false;
            while (parents.get(cursor)) |parent| {
                if (t.ast.nodes.items[parent].tag == .ts_enum_declaration) {
                    // The outer declaration binding is not evaluated in the
                    // IIFE; merged declarations may share its source anchor.
                    in_enum = cursor != @backingInt(t.ast.readExtraNode(t.ast.nodes.items[parent].data.extra, ast.EnumExtra.name));
                    break;
                }
                cursor = parent;
            }
            if (in_enum) try std.testing.expectEqual(context.scope_stmt_idx, reference.scope_stmt_idx);
        }
    }
}

test "enum runtime prelude canonical edge clone codec and independent statement coordinates" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var scanner = try @import("../lexer/scanner.zig").Scanner.init(a, "before();enum E{A=first(),B=second()}after();");
    var parser = @import("../parser/parser.zig").Parser.init(a, &scanner);
    parser.configureFromExtension(".ts");
    const root = try parser.parse();
    var enum_idx: ast.NodeIndex = .none;
    for (parser.ast.nodes.items, 0..) |node, raw| if (node.tag == .ts_enum_declaration) {
        enum_idx = @fromBackingInt(@as(u32, @intCast(raw)));
    };
    try std.testing.expect(!enum_idx.isNone());
    const en = parser.ast.getNode(enum_idx);
    try std.testing.expect(parser.ast.readExtraNode(en.data.extra, ast.EnumExtra.runtime_prelude).isNone());
    const text = try parser.ast.addString("\"use strict\"");
    const first = try parser.ast.addNode(.{ .tag = .directive, .span = text, .data = .{ .none = 0 } });
    const second = try parser.ast.addNode(.{ .tag = .empty_statement, .span = en.span, .data = .{ .none = 0 } });
    const prefix = try parser.ast.addNode(.{ .tag = .block_statement, .span = en.span, .data = .{ .list = try parser.ast.addNodeList(&.{ first, second }) } });
    parser.ast.extra_data.items[en.data.extra + ast.EnumExtra.runtime_prelude] = @backingInt(prefix);
    const contexts = try @import("../semantic/statement_coordinates.zig").collect(a, &parser.ast, root);
    try std.testing.expectEqual(@as(u32, 0), contexts[@backingInt(first)].?.scope_stmt_idx);
    try std.testing.expectEqual(@as(u32, 1), contexts[@backingInt(second)].?.scope_stmt_idx);
    for (0..2) |index| {
        const member = parser.ast.readExtraNode(parser.ast.extra_data.items[en.data.extra + ast.EnumExtra.members_start], @intCast(index));
        const init = parser.ast.getNode(member).data.binary.right;
        try std.testing.expectEqual(@as(u32, @intCast(2 + index)), contexts[@backingInt(init)].?.scope_stmt_idx);
        try std.testing.expectEqual(@as(u32, 1), contexts[@backingInt(init)].?.stmt_idx);
    }
    const copied = try ast.Ast.cloneForTransformer(&parser.ast, a);
    try std.testing.expectEqual(prefix, copied.readExtraNode(copied.getNode(enum_idx).data.extra, ast.EnumExtra.runtime_prelude));
    const codec = @import("../parser/ast_codec.zig");
    var bytes: std.ArrayList(u8) = .empty;
    try codec.serialize(&copied, &bytes, a);
    const restored = try codec.deserialize(bytes.items, a);
    const reachable = try @import("../parser/ast_walk.zig").collectReachableNodeIndicesFrom(a, &restored, root);
    try std.testing.expect(std.mem.indexOfScalar(u32, reachable, @backingInt(prefix)) != null);
    var codegen = @import("../codegen/codegen.zig").Codegen.init(a, &restored);
    const code = try codegen.generate(root);
    try std.testing.expect(std.mem.indexOf(u8, code, "\"use strict\"") != null);
    std.mem.writeInt(u32, bytes.items[4..8], 5, .little);
    try std.testing.expectError(error.UnsupportedVersion, codec.deserialize(bytes.items, a));
}

fn checkEnumBodyOwners(a: std.mem.Allocator, tree: *const ast.Ast, root: ast.NodeIndex, scopes: []const @import("../semantic/scope.zig").Scope, owners: *const std.AutoHashMapUnmanaged(u32, u32)) !@import("symbol_coverage.zig").ExactReport {
    const maps = try a.alloc(std.StringHashMapUnmanaged(usize), scopes.len);
    @memset(maps, .empty);
    const helpers: std.StringHashMapUnmanaged(usize) = .empty;
    const empty: std.AutoHashMapUnmanaged(u32, void) = .empty;
    const origins: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    return @import("symbol_coverage.zig").checkExact(a, tree, root, @intCast(tree.nodes.items.len), &.{}, &.{}, scopes, maps, owners, &.{}, &.{}, &helpers, &empty, &empty, &origins);
}

test "enum runtime prelude exact alias rejects wrong owner duplicate boundary and nonblock edge" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tree = ast.Ast.init(a, "");
    const span: @import("../lexer/token.zig").Span = .{ .start = 0, .end = 0 };
    const prefix = try tree.addNode(.{ .tag = .block_statement, .span = span, .data = .{ .list = try tree.addNodeList(&.{}) } });
    const en = try tree.addNode(.{ .tag = .ts_enum_declaration, .span = span, .data = .{ .extra = try tree.addExtras(&.{ @backingInt(ast.NodeIndex.none), 0, 0, 0, @backingInt(prefix) }) } });
    const root = try tree.addNode(.{ .tag = .program, .span = span, .data = .{ .list = try tree.addNodeList(&.{en}) } });
    const scopes = [_]@import("../semantic/scope.zig").Scope{
        .{ .parent = .none, .kind = .global, .is_strict = false },
        .{ .parent = @fromBackingInt(0), .kind = .function, .is_strict = true },
        .{ .parent = @fromBackingInt(0), .kind = .function, .is_strict = true },
    };
    var owners: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    try owners.put(a, @backingInt(root), 0);
    try owners.put(a, @backingInt(en), 1);
    try owners.put(a, @backingInt(prefix), 1);
    const valid = try checkEnumBodyOwners(a, &tree, root, &scopes, &owners);
    try std.testing.expectEqual(@as(usize, 0), valid.duplicate_scope_owner);
    try std.testing.expectEqual(@as(usize, 0), valid.scope_owner_mismatch);
    try owners.put(a, @backingInt(prefix), 2);
    const wrong = try checkEnumBodyOwners(a, &tree, root, &scopes, &owners);
    try std.testing.expect(wrong.scope_owner_mismatch > valid.scope_owner_mismatch);
    try owners.put(a, @backingInt(prefix), 1);
    const stray = try tree.addNode(.{ .tag = .block_statement, .span = span, .data = .{ .list = try tree.addNodeList(&.{}) } });
    tree.nodes.items[@backingInt(prefix)].data.list = try tree.addNodeList(&.{stray});
    try owners.put(a, @backingInt(stray), 1);
    const duplicate = try checkEnumBodyOwners(a, &tree, root, &scopes, &owners);
    try std.testing.expect(duplicate.duplicate_scope_owner > valid.duplicate_scope_owner);
    tree.nodes.items[@backingInt(prefix)].data.list = try tree.addNodeList(&.{});
    const restored = try checkEnumBodyOwners(a, &tree, root, &scopes, &owners);
    try std.testing.expectEqual(@as(usize, 0), restored.duplicate_scope_owner);
    const bad = try tree.addNode(.{ .tag = .empty_statement, .span = span, .data = .{ .none = 0 } });
    tree.extra_data.items[tree.getNode(en).data.extra + ast.EnumExtra.runtime_prelude] = @backingInt(bad);
    const bad_kind = try checkEnumBodyOwners(a, &tree, root, &scopes, &owners);
    try std.testing.expect(bad_kind.invalid_ast_layout > 0);
}

test "enum runtime prelude survives lazy-editor publication and independent semantic reanalysis" {
    const coverage = @import("symbol_coverage.zig");
    const sources = [_][]const u8{
        "enum E{A=Number(arguments[0]===E)}console.log(E.A)",
        "enum E{A=Number((()=>arguments[0]===E)())}console.log(E.A)",
        "enum E{A=Number((()=>this)()===undefined)}console.log(E.A)",
    };
    for (sources) |source| for ([_]bool{ false, true }) |es5| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var scanner = try @import("../lexer/scanner.zig").Scanner.init(a, source);
        var parser = @import("../parser/parser.zig").Parser.init(a, &scanner);
        parser.configureFromExtension(".ts");
        _ = try parser.parse();
        var initial = @import("../semantic/analyzer.zig").SemanticAnalyzer.init(a, &parser.ast);
        initial.is_strict_mode = parser.is_strict_mode;
        initial.is_ts = true;
        initial.collect_unresolved_reference_nodes = true;
        try initial.analyze();
        var t = try @import("transformer.zig").Transformer.init(a, &parser.ast, .{ .unsupported = Options.compat.fromESTarget(if (es5) .es5 else .esnext) });
        try t.initSymbolIds(initial.symbol_ids.items);
        t.symbols = initial.symbols.items;
        t.references = initial.references.items;
        t.scopes = initial.scopes.items;
        t.scope_maps = initial.scope_maps.items;
        t.scope_owner_map = initial.scope_owner_map;
        t.node_scope_provenance = initial.node_scope_provenance;
        t.class_self_symbol_map = initial.class_self_symbol_map;
        t.unresolved_references = &initial.unresolved_references;
        t.semantic_edit_enabled = true;
        const output = try t.transform();
        const edited = (try t.finishSemanticEdit()) orelse return error.EnumBodyPublicationWasDropped;
        const live = try @import("../parser/ast_walk.zig").collectReachableNodeIndicesFrom(a, t.ast, output);
        var checked: usize = 0;
        for (live) |raw| {
            const node = t.ast.nodes.items[raw];
            if (node.tag != .ts_enum_declaration) continue;
            const prefix = t.ast.readExtraNode(node.data.extra, ast.EnumExtra.runtime_prelude);
            try std.testing.expectEqual(edited.scope_owner_map.get(raw).?, edited.scope_owner_map.get(@backingInt(prefix)).?);
            checked += 1;
        }
        try std.testing.expectEqual(@as(usize, 1), checked);
        var resolved = @import("../semantic/analyzer.zig").SemanticAnalyzer.init(a, t.ast);
        resolved.is_strict_mode = parser.is_strict_mode;
        resolved.collect_unresolved_reference_nodes = true;
        try resolved.analyze();
        const report = try coverage.checkPostMinifyWithNativeOwners(a, t.ast, output, t.symbol_ids.items, resolved.symbol_ids.items, edited.symbols.items, resolved.symbols.items, edited.references, t.helper_ref_nodes.items, &t.helper_scope_map, &resolved.unresolved_reference_nodes, &t.explicit_global_reference_nodes, &t.class_self_symbol_map, &resolved.class_self_symbol_map, .{ .scopes = edited.scopes, .scope_owner_map = &edited.scope_owner_map }, .{ .scopes = resolved.scopes.items, .scope_owner_map = &resolved.scope_owner_map });
        try std.testing.expectEqual(@as(usize, 0), report.missing_binding_id);
        try std.testing.expectEqual(@as(usize, 0), report.missing_reference_id);
        try std.testing.expectEqual(@as(usize, 0), report.wrong_reference_target);
        try std.testing.expect(report.isClean());
    };
}

test "escaped enum runtime keeps container aliases and auto-counter values exact" {
    const sources = [_][]const u8{
        "enum \\u0045{A=9,B=A+1}console.log(E.B)",
        "enum \\u0053elf{Self=9,B=Self+1}console.log(Self.B)",
        "enum E{\\u0041=9,Z=50,B=A,C}console.log(E.C)",
        "enum E{A=9,Z=50,B=\\u0041,C}console.log(E.C)",
        "const _Self=4;enum Self{Self=9,B=Self+1}console.log(Self.B)",
        "const \\u005fSelf=4;enum Self{Self=9,B=Self+1}console.log(Self.B)",
        "enum E{\"\\u0041\"=9,Z=50,B=A,C}console.log(E.C)",
        "enum E{\"\\\\u0041\"=9,A=4,B=A+6}console.log(E.B)",
        "enum E{A=4,\"\\\\u0041\"=9,B=A+6}console.log(E.B)",
    };
    var failures: usize = 0;
    for (sources, 0..) |source, family| for ([_]bool{ false, true }) |minify| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const result = @import("../transpile.zig").transpile(a, source, "input.ts", .{ .unsupported = Options.compat.fromESTarget(.es5), .minify_identifiers = minify }) catch |err| {
            std.debug.print("escaped-enum-runtime family={d} minify={} build={s}\n", .{ family, minify, @errorName(err) });
            failures += 1;
            continue;
        };
        const actual = try std.process.run(a, std.testing.io, .{ .argv = &.{ "node", "-e", result.code } });
        const ok = actual.term == .exited and actual.term.exited == 0 and std.mem.eql(u8, "10\n", actual.stdout);
        std.debug.print("escaped-enum-runtime family={d} minify={} valid={} stdout={s}\n", .{ family, minify, ok, actual.stdout });
        if (!ok) failures += 1;
    };
    try std.testing.expectEqual(@as(usize, 0), failures);
}

test "escaped enum name reservation preserves existing raw namespace candidates" {
    const source = "const _\\u004e=10;namespace \\u004e{export const value=_\\u004e}console.log(N.value)";
    for ([_]bool{ false, true }) |minify| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const result = try @import("../transpile.zig").transpile(a, source, "input.ts", .{ .unsupported = Options.compat.fromESTarget(.es5), .minify_identifiers = minify });
        const actual = try std.process.run(a, std.testing.io, .{ .argv = &.{ "node", "-e", result.code } });
        std.debug.print("escaped-enum-reservation namespace minify={} code={s} stdout={s} stderr={s}\n", .{ minify, result.code, actual.stdout, actual.stderr });
        try std.testing.expect(actual.term == .exited and actual.term.exited == 0);
        try std.testing.expectEqualStrings("10\n", actual.stdout);
    }
}
