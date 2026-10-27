//! Initial observations use the real built-in catalog loader, not a path-only
//! fake module or a copied handwritten helper body.
const std = @import("std");
const ast = @import("../parser/ast.zig");
const symbol = @import("../semantic/symbol.zig");
const walk = @import("../parser/ast_walk.zig");
const helpers = @import("../runtime_helper_modules.zig");
const NodeIndex = ast.NodeIndex;

fn originalNode(t: anytype, node: NodeIndex) !NodeIndex {
    if (node.isNone()) return node;
    var raw = @backingInt(node);
    var hops: usize = 0;
    while (t.reference_origin_map.get(raw)) |parent| : (hops += 1) {
        if (parent == raw) break;
        if (hops >= t.ast.nodes.items.len) return error.CyclicOrigin;
        raw = parent;
    }
    return @fromBackingInt(raw);
}

fn observe(a: std.mem.Allocator, id: []const u8, minify: bool, full_driver: bool) !void {
    const source_options: helpers.SourceOptions = .{ .es5 = true, .minify = minify };
    const plugin = helpers.makePlugin(&source_options);
    var hook_context: @import("../bundler/plugin.zig").HookContext = .{};
    const loaded = (try plugin.load.?(plugin.context, id, a, &hook_context)).?;
    var scanner = try @import("../lexer/scanner.zig").Scanner.init(a, loaded.contents);
    scanner.is_module = true;
    var parser = @import("../parser/parser.zig").Parser.init(a, &scanner);
    parser.is_module = true;
    _ = try parser.parse();
    try std.testing.expectEqual(@as(usize, 0), parser.errors.items.len);
    const source_root: NodeIndex = @fromBackingInt(@as(u32, @intCast(parser.ast.nodes.items.len - 1)));
    const source_live = try walk.collectReachableNodeIndicesFrom(a, &parser.ast, source_root);
    var source_reachable: std.AutoHashMapUnmanaged(u32, void) = .empty;
    for (source_live) |raw| try source_reachable.put(a, raw, {});
    var orphan_patterns: usize = 0;
    var regex_literals: usize = 0;
    for (parser.ast.nodes.items, 0..) |node, raw| {
        if ((node.tag == .object_pattern or node.tag == .array_pattern) and !source_reachable.contains(@intCast(raw))) orphan_patterns += 1;
        if (node.tag == .regexp_literal and source_reachable.contains(@intCast(raw))) regex_literals += 1;
    }
    var analyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer.init(a, &parser.ast);
    analyzer.is_module = true;
    analyzer.enable_stmt_info = true;
    analyzer.enable_exact_declaration_anchors = true;
    analyzer.collect_unresolved_reference_nodes = true;
    try analyzer.analyze();
    const initial_symbols = try a.dupe(symbol.Symbol, analyzer.symbols.items);
    const initial_references = try a.dupe(symbol.Reference, analyzer.references.items);
    const initial_scopes = try a.dupe(@import("../semantic/scope.zig").Scope, analyzer.scopes.items);
    var t = try @import("transformer.zig").Transformer.init(a, &parser.ast, .{ .unsupported = @import("compat.zig").fromESTarget(.es5), .minify_whitespace = minify, .emit_runtime_helper_imports = true });
    try t.initSymbolIds(analyzer.symbol_ids.items);
    t.symbols = analyzer.symbols.items;
    t.references = analyzer.references.items;
    t.scopes = analyzer.scopes.items;
    t.scope_maps = analyzer.scope_maps.items;
    t.scope_owner_map = analyzer.scope_owner_map;
    t.node_scope_provenance = analyzer.node_scope_provenance;
    t.class_self_symbol_map = analyzer.class_self_symbol_map;
    t.helper_scope_map = analyzer.helper_scope_map;
    t.unresolved_references = &analyzer.unresolved_references;
    t.unresolved_reference_nodes = &analyzer.unresolved_reference_nodes;
    t.semantic_edit_enabled = true;
    var semantic: @import("../bundler/module.zig").ModuleSemanticData = .{ .symbols = analyzer.symbols, .scopes = analyzer.scopes.items, .scope_maps = analyzer.scope_maps.items, .scope_owner_map = analyzer.scope_owner_map, .node_scope_provenance = analyzer.node_scope_provenance, .symbol_ids = analyzer.symbol_ids.items, .exported_names = analyzer.exported_names, .unresolved_references = analyzer.unresolved_references, .references = analyzer.references.items, .class_self_symbol_map = analyzer.class_self_symbol_map, .helper_scope_map = analyzer.helper_scope_map };
    const certificate = @import("virtual_helper_provider_certificate.zig");
    const selected = try certificate.capture(a, &parser.ast, &semantic, hook_context.runtime_helper_source.?, loaded.contents, source_options, t.options, false);
    if (selected == null) {
        std.debug.print("provider-capture-rejected {s}\n", .{id});
        var tags: std.AutoHashMap(ast.Node.Tag, void) = .init(a);
        for (source_live) |raw| try tags.put(parser.ast.nodes.items[raw].tag, {});
        var tag_iterator = tags.keyIterator();
        while (tag_iterator.next()) |tag| std.debug.print(" tag={s}\n", .{@tagName(tag.*)});
        return error.ExpectedProviderCapture;
    }
    var rejected_options = t.options;
    rejected_options.minify_syntax = true;
    try std.testing.expect((try certificate.capture(a, &parser.ast, &semantic, hook_context.runtime_helper_source.?, loaded.contents, source_options, rejected_options, false)) == null);
    rejected_options = t.options;
    rejected_options.drop_console = true;
    try std.testing.expect((try certificate.capture(a, &parser.ast, &semantic, hook_context.runtime_helper_source.?, loaded.contents, source_options, rejected_options, false)) == null);
    try std.testing.expect((try certificate.capture(a, &parser.ast, &semantic, hook_context.runtime_helper_source.?, loaded.contents, source_options, t.options, true)) == null);
    const first_read = parser.ast.nodes.items[@backingInt(selected.?.leaves[0])];
    const matched_key = parser.ast.getText(first_read.data.string_ref);
    rejected_options = t.options;
    rejected_options.define = &.{.{ .key = matched_key, .value = "42" }};
    try std.testing.expect(@import("transformer/define.zig").astUsesDefine(&parser.ast, rejected_options.define));
    try std.testing.expect((try certificate.capture(a, &parser.ast, &semantic, hook_context.runtime_helper_source.?, loaded.contents, source_options, rejected_options, false)) == null);
    rejected_options.define = &.{.{ .key = "ABSENT_BUILTIN_PROOF", .value = "42" }};
    try std.testing.expect((try certificate.capture(a, &parser.ast, &semantic, hook_context.runtime_helper_source.?, loaded.contents, source_options, rejected_options, false)) != null);
    try certificate.activate(&t, selected.?);
    const root = if (full_driver) try t.transform() else blk: {
        try t.buildBlockRenameMap();
        break :blk try t.visitNode(source_root);
    };
    const references = if (t.semantic_editor) |*editor| editor.references.items else t.references;
    const symbols = if (t.semantic_editor) |*editor| editor.symbols.items else t.symbols;
    const scopes = if (t.semantic_editor) |*editor| editor.scopes.items else t.scopes;
    const live = try walk.collectReachableNodeIndicesFrom(a, t.ast, root);
    var reachable: std.AutoHashMapUnmanaged(u32, void) = .empty;
    for (live) |raw| try reachable.put(a, raw, {});
    var live_rows: std.ArrayList(symbol.Reference) = .empty;
    for (references) |row| {
        const anchor = if (row.flags.declare) row.declaration_node_index else row.node_index;
        if (anchor.isNone() or reachable.contains(@backingInt(anchor))) try live_rows.append(a, row);
    }
    const scope_utils = @import("output_scope_test_utils.zig");
    var parent_map = try scope_utils.buildParentMap(a, t.ast, root);
    var owners: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    for (live) |raw| {
        const node: NodeIndex = @fromBackingInt(raw);
        if (t.outputOwnedScope(node)) |scope| {
            const source_owner = t.scope_owner_origins.get(raw) orelse raw;
            const original_scope = analyzer.scope_owner_map.get(source_owner) orelse return error.UnknownCopiedOwner;
            try std.testing.expectEqual(original_scope, @backingInt(scope));
            try owners.put(a, raw, @backingInt(scope));
        }
    }
    for (live_rows.items) |row| {
        if (row.flags.declare or row.node_index.isNone()) continue;
        const expected = scope_utils.expectedScope(t.ast, root, &parent_map, &owners, @backingInt(row.node_index)) orelse return error.MissingActualUseScope;
        try std.testing.expectEqual(expected, row.scope_id);
    }
    try std.testing.expectEqual(initial_symbols.len, symbols.len);
    try std.testing.expectEqual(initial_scopes.len, scopes.len);
    var engines: usize = 0;
    for (initial_symbols, symbols) |before, after| {
        try std.testing.expectEqual(before.kind, after.kind);
        try std.testing.expectEqual(before.scope_id, after.scope_id);
        try std.testing.expectEqual(before.synthetic_kind, after.synthetic_kind);
        try std.testing.expectEqualStrings(before.nameText(parser.ast.source), after.nameText(t.ast.source));
        try std.testing.expectEqualStrings(before.synthetic_name, after.synthetic_name);
        try std.testing.expectEqualStrings(before.output_name_hint, after.output_name_hint);
        try std.testing.expectEqual(before.synthetic_owner_id, after.synthetic_owner_id);
        try std.testing.expectEqualDeep(before.parameter_copy, after.parameter_copy);
        try std.testing.expectEqualDeep(before.binding_instantiation, after.binding_instantiation);
        try std.testing.expectEqualDeep(before.annex_b_alias, after.annex_b_alias);
        if (before.synthetic_kind == .implicit_arguments) engines += 1;
    }
    for (initial_scopes, scopes) |before, after| {
        try std.testing.expectEqual(before.kind, after.kind);
        try std.testing.expectEqual(before.parent, after.parent);
        try std.testing.expectEqual(before.is_strict, after.is_strict);
    }
    try std.testing.expectEqual(initial_references.len, live_rows.items.len);
    for (initial_references) |before| {
        var count: usize = 0;
        for (live_rows.items) |after| {
            if (after.symbol_id != before.symbol_id or after.scope_id != before.scope_id or !std.meta.eql(after.flags, before.flags)) continue;
            const before_anchor = if (before.flags.declare) before.declaration_node_index else before.node_index;
            const after_anchor = if (after.flags.declare) after.declaration_node_index else after.node_index;
            if (try originalNode(&t, after_anchor) == before_anchor) count += 1;
        }
        try std.testing.expectEqual(@as(usize, 1), count);
    }
    try std.testing.expect(!t.runtime_helpers.hasAny());
    if (full_driver) {
        std.debug.print("provider-before-binder-seal root={d} expected={d}\n", .{ @backingInt(t.virtual_provider_before_binder_root), @backingInt(root) });
        const edited = (try t.finishSemanticEdit()).?;
        semantic.applyEdit(edited);
        const completed = try certificate.complete(&t, &semantic, loaded.contents, root);
        try std.testing.expect(completed);
        // Each independent mutation keeps every AST edge intact. A fresh exact
        // graph audit alone must not stand in for these stable source roles.
        const saved_symbol = semantic.symbols.items[0];
        for (0..10) |mutation| {
            const target = &semantic.symbols.items[0];
            switch (mutation) {
                0 => target.synthetic_name = "foreignProviderBinding",
                1 => target.output_name_hint = "foreignOutputHint",
                2 => target.synthetic_owner_id = @fromBackingInt(@intCast(1)),
                3 => target.parameter_copy.parameter_source = @fromBackingInt(@intCast(1)),
                4 => target.parameter_copy.state = .lowered,
                5 => target.binding_instantiation.parameter_copy = !target.binding_instantiation.parameter_copy,
                6 => target.synthetic_kind = .implicit_arguments,
                7 => target.annex_b_alias.variable = @fromBackingInt(@intCast(1)),
                8 => target.name = semantic.symbols.items[1].name,
                9 => target.kind = if (target.kind == .variable_var) .variable_let else .variable_var,
                else => unreachable,
            }
            const accepted = try certificate.complete(&t, &semantic, loaded.contents, root);
            target.* = saved_symbol;
            try std.testing.expect(!accepted);
            try std.testing.expect(try certificate.complete(&t, &semantic, loaded.contents, root));
        }
        var exports = semantic.exported_names.valueIterator();
        const exported = exports.next() orelse return error.MissingProviderExport;
        const saved_export = exported.*;
        exported.start += 1;
        const accepted_export = try certificate.complete(&t, &semantic, loaded.contents, root);
        exported.* = saved_export;
        try std.testing.expect(!accepted_export);
        try std.testing.expect(try certificate.complete(&t, &semantic, loaded.contents, root));
        const rows = @constCast(semantic.references);
        var read_index: ?usize = null;
        for (rows, 0..) |row, index| if (!row.flags.declare and row.flags.read) {
            read_index = index;
            break;
        };
        const read = &rows[read_index orelse return error.MissingProviderRead];
        const saved_read = read.*;
        for (0..3) |mutation| {
            switch (mutation) {
                0 => read.symbol_id = @fromBackingInt(@intCast(@as(u32, if (@backingInt(read.symbol_id) == 0) 1 else 0))),
                1 => read.scope_id = @fromBackingInt(@intCast(@as(u32, if (@backingInt(read.scope_id) == 0) 1 else 0))),
                2 => read.flags.write = !read.flags.write,
                else => unreachable,
            }
            const accepted_read = try certificate.complete(&t, &semantic, loaded.contents, root);
            read.* = saved_read;
            try std.testing.expect(!accepted_read);
            try std.testing.expect(try certificate.complete(&t, &semantic, loaded.contents, root));
        }
        const saved_seal = t.virtual_provider_before_binder_root;
        t.virtual_provider_before_binder_root = .none;
        const accepted_unsealed = try certificate.complete(&t, &semantic, loaded.contents, root);
        t.virtual_provider_before_binder_root = saved_seal;
        try std.testing.expect(!accepted_unsealed);
        var foreign_ast = parser.ast;
        const saved_domain = t.virtual_provider_source.?.source_domain;
        t.virtual_provider_source.?.source_domain = &foreign_ast;
        const accepted_foreign_domain = try certificate.complete(&t, &semantic, loaded.contents, root);
        t.virtual_provider_source.?.source_domain = saved_domain;
        try std.testing.expect(!accepted_foreign_domain);
        const mutable_scopes = @constCast(semantic.scopes);
        const saved_strictness = mutable_scopes[0].is_strict;
        mutable_scopes[0].is_strict = !saved_strictness;
        const accepted_scope = try certificate.complete(&t, &semantic, loaded.contents, root);
        mutable_scopes[0].is_strict = saved_strictness;
        try std.testing.expect(!accepted_scope);
        var owner_iterator = semantic.scope_owner_map.valueIterator();
        const owner_scope = owner_iterator.next() orelse return error.MissingProviderOwner;
        const saved_owner_scope = owner_scope.*;
        owner_scope.* = if (saved_owner_scope == 0) 1 else 0;
        const accepted_owner = try certificate.complete(&t, &semantic, loaded.contents, root);
        owner_scope.* = saved_owner_scope;
        try std.testing.expect(!accepted_owner);
        try std.testing.expect(try certificate.complete(&t, &semantic, loaded.contents, root));
        const saved_demands = t.runtime_helpers;
        t.runtime_helpers.public_field = true;
        const accepted_demand = try certificate.complete(&t, &semantic, loaded.contents, root);
        t.runtime_helpers = saved_demands;
        try std.testing.expect(!accepted_demand);
        for (live) |raw| {
            const output_node = t.ast.nodes.items[raw];
            if (output_node.tag != .function_expression) continue;
            const extra = output_node.data.extra;
            const saved_return_type = t.ast.extra_data.items[extra + ast.FunctionExtra.return_type];
            t.ast.extra_data.items[extra + ast.FunctionExtra.return_type] = 0;
            const accepted_typed_payload = try certificate.complete(&t, &semantic, loaded.contents, root);
            t.ast.extra_data.items[extra + ast.FunctionExtra.return_type] = saved_return_type;
            try std.testing.expect(!accepted_typed_payload);
            const saved_flags = t.ast.extra_data.items[extra + ast.FunctionExtra.flags];
            t.ast.extra_data.items[extra + ast.FunctionExtra.flags] = saved_flags | ast.FunctionFlags.is_async;
            const accepted_engine_owner_role = try certificate.complete(&t, &semantic, loaded.contents, root);
            t.ast.extra_data.items[extra + ast.FunctionExtra.flags] = saved_flags;
            try std.testing.expect(!accepted_engine_owner_role);
            break;
        }
        try std.testing.expect(try certificate.complete(&t, &semantic, loaded.contents, root));
    }
    try std.testing.expect(root != source_root);
    try std.testing.expect(t.ast != &parser.ast);
    try std.testing.expect(t.scope_owner_remaps.count() > 0);
    std.debug.print("provider-observation id={s} min={any} phase={s} initialSymbols={d} initialRows={d} outputRows={d} engines={d} scopes={d} copiedOwners={d} implicitOwnerRoles={d} orphanPatterns={d} regex={d} demands=0\n", .{ id[helpers.ID_PREFIX.len..], minify, if (full_driver) "before-finish" else "after-visit", initial_symbols.len, initial_references.len, live_rows.items.len, engines, scopes.len, t.scope_owner_remaps.count(), analyzer.implicit_arguments_owners.count(), orphan_patterns, regex_literals });
}

test "virtual provider actual catalog initial after-visit and before-finish tuples" {
    for ([_][]const u8{ "public-field", "to-property-key", "keep-names" }) |short| {
        for ([_]bool{ false, true }) |minify| {
            for ([_]bool{ false, true }) |full_driver| {
                var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
                defer arena.deinit();
                const a = arena.allocator();
                const id = try std.fmt.allocPrint(a, "{s}{s}", .{ helpers.ID_PREFIX, short });
                try observe(a, id, minify, full_driver);
            }
        }
    }
}

test "virtual provider actual builtin catalog ES5 prepass does not reanalyze RED" {
    const test_helpers = @import("../bundler/test_helpers.zig");
    var total_resyncs: u32 = 0;
    for ([_][]const u8{ "public-field", "to-property-key", "keep-names" }) |short| {
        for ([_]bool{ false, true }) |minify| {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            const base = if (std.mem.eql(u8, short, "public-field")) "__publicField" else if (std.mem.eql(u8, short, "to-property-key")) "__toPropertyKey" else "__name";
            const source = try std.fmt.allocPrint(std.testing.allocator, "import {{ {s} }} from '\\x00zntc:runtime/{s}';console.log(typeof {s});", .{ base, short, base });
            defer std.testing.allocator.free(source);
            try test_helpers.writeFile(tmp.dir, "entry.mjs", source);
            const entry = try test_helpers.absPath(&tmp, "entry.mjs");
            defer std.testing.allocator.free(entry);
            const profile = @import("../profile.zig");
            profile.resetForTest();
            defer profile.resetForTest();
            profile.setIoForTest(std.testing.io);
            profile.addFromCsv("graph.resync.semantic");
            var bundler = @import("../bundler/bundler.zig").Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry}, .platform = .node, .format = .cjs, .unsupported = @import("compat.zig").fromESTarget(.es5), .minify_whitespace = minify });
            defer bundler.deinit();
            const result = try bundler.bundle(std.testing.io);
            defer result.deinit(std.testing.allocator);
            try std.testing.expect(!result.hasErrors());
            std.debug.print("provider-RED short={s} min={any} resync={d}\n", .{ short, minify, profile.count(.graph_resync_semantic) });
            total_resyncs += profile.count(.graph_resync_semantic);
        }
    }
    try std.testing.expectEqual(@as(u32, 0), total_resyncs);
}

const ProofFixture = struct { proof: @import("../runtime_helper_source_origin.zig").Origin };
fn staleNullLoad(ctx: ?*anyopaque, _: []const u8, _: std.mem.Allocator, hook: *@import("../bundler/plugin.zig").HookContext) @import("../bundler/plugin.zig").PluginError!?@import("../bundler/plugin.zig").LoadResult {
    const fixture: *const ProofFixture = @ptrCast(@alignCast(ctx.?));
    hook.runtime_helper_source = fixture.proof;
    return null;
}
fn foreignWinner(_: ?*anyopaque, _: []const u8, _: std.mem.Allocator, _: *@import("../bundler/plugin.zig").HookContext) @import("../bundler/plugin.zig").PluginError!?@import("../bundler/plugin.zig").LoadResult {
    return .{ .contents = "export var unrelated=42;" };
}
fn wrapperWinner(ctx: ?*anyopaque, path: []const u8, a: std.mem.Allocator, hook: *@import("../bundler/plugin.zig").HookContext) @import("../bundler/plugin.zig").PluginError!?@import("../bundler/plugin.zig").LoadResult {
    const options: *const helpers.SourceOptions = @ptrCast(@alignCast(ctx.?));
    const builtin = helpers.makePlugin(options);
    return builtin.load.?(builtin.context, path, a, hook);
}

test "virtual provider constructor witness follows actual winning hook and source lifetime" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const options: helpers.SourceOptions = .{ .es5 = true };
    const builtin = helpers.makePlugin(&options);
    const id = helpers.ID_PREFIX ++ "public-field";
    var seed_context: @import("../bundler/plugin.zig").HookContext = .{};
    _ = (try builtin.load.?(builtin.context, id, a, &seed_context)).?;
    var fixture: ProofFixture = .{ .proof = seed_context.runtime_helper_source.? };
    const Plugin = @import("../bundler/plugin.zig").Plugin;
    const Runner = @import("../bundler/plugin.zig").PluginRunner;
    const first: Plugin = .{ .name = "stale-null", .context = @ptrCast(&fixture), .load = staleNullLoad };
    var context: @import("../bundler/plugin.zig").HookContext = .{};
    const plugins = [_]Plugin{ first, builtin };
    const actual = (try Runner.init(&plugins).runLoadWithOrigin(id, a, &context)).?;
    try std.testing.expectEqual(@as(usize, 1), actual.plugin_index);
    const accepted = helpers.acceptWinningLoad(actual, &options).?;
    try std.testing.expect(accepted.contents.ptr != fixture.proof.contents.ptr);
    try std.testing.expect(@import("../runtime_helper_source_origin.zig").matchesContents(accepted, actual.result.contents));
    const stale_plugins = [_]Plugin{ first, .{ .name = "zntc:runtime-helpers", .load = foreignWinner } };
    const foreign = (try Runner.init(&stale_plugins).runLoadWithOrigin(id, a, &context)).?;
    try std.testing.expect(foreign.runtime_helper_source == null);
    try std.testing.expect(helpers.acceptWinningLoad(foreign, &options) == null);
    const override = [_]Plugin{.{ .name = "zntc:runtime-helpers", .context = builtin.context, .load = wrapperWinner }};
    const wrapper = (try Runner.init(&override).runLoadWithOrigin(id, a, &context)).?;
    try std.testing.expect(wrapper.runtime_helper_source != null);
    try std.testing.expect(helpers.acceptWinningLoad(wrapper, &options) == null);
    const duplicate = try a.dupe(u8, actual.result.contents);
    try std.testing.expect(!@import("../runtime_helper_source_origin.zig").matchesContents(accepted, duplicate));
    const mutable = @constCast(actual.result.contents);
    const original = mutable[0];
    mutable[0] = if (original == 'v') 'x' else 'v';
    try std.testing.expect(!@import("../runtime_helper_source_origin.zig").matchesContents(accepted, actual.result.contents));
    mutable[0] = original;
    var corrupt = actual;
    corrupt.runtime_helper_source.?.catalog = .keep_names;
    try std.testing.expect(helpers.acceptWinningLoad(corrupt, &options) == null);
    corrupt = actual;
    corrupt.runtime_helper_source.?.variant = .min;
    try std.testing.expect(helpers.acceptWinningLoad(corrupt, &options) == null);
    try std.testing.expect(helpers.acceptWinningLoad(actual, &options) != null);
}

const PublicCase = struct { source: []const u8, expected: []const u8 };
const public_cases = [_]PublicCase{
    .{ .source = "import {__publicField as put} from '\\x00zntc:runtime/public-field';var o={};put(o,'x',42);console.log(o.x);", .expected = "42\n" },
    .{ .source = "import {__publicField as put} from '\\x00zntc:runtime/public-field';var __publicField=7,o={};put(o,'x',42);console.log(o.x+__publicField);", .expected = "49\n" },
    .{ .source = "import {__publicField as put} from '\\x00zntc:runtime/public-field';var o={};put(o,'__proto__',42);console.log(Object.prototype.hasOwnProperty.call(o,'__proto__')+':'+o.__proto__);", .expected = "true:42\n" },
    .{ .source = "import {__publicField as put} from '\\x00zntc:runtime/public-field';var o={};put(o,'x',1);put(o,'x',2);console.log(o.x);", .expected = "2\n" },
    .{ .source = "import {__toPropertyKey as key} from '\\x00zntc:runtime/to-property-key';console.log(key(42));", .expected = "42\n" },
    .{ .source = "import {__toPropertyKey as key} from '\\x00zntc:runtime/to-property-key';var o={toString:function(){return 'read'}};console.log(key(o));", .expected = "read\n" },
    .{ .source = "import {__toPropertyKey as key} from '\\x00zntc:runtime/to-property-key';var s=Symbol('x');console.log(key(s)===s);", .expected = "true\n" },
    .{ .source = "import {__name as name} from '\\x00zntc:runtime/keep-names';var f=function(){};name(f,'read');console.log(f.name);", .expected = "read\n" },
    .{ .source = "import {__name as name} from '\\x00zntc:runtime/keep-names';var __name=7,f=function(){};name(f,'read');console.log(f.name+__name);", .expected = "read7\n" },
    .{ .source = "import {__publicField as put} from '\\x00zntc:runtime/public-field';import {__toPropertyKey as key} from '\\x00zntc:runtime/to-property-key';import {__name as name} from '\\x00zntc:runtime/keep-names';var o={},f=function(){};name(f,'read');put(o,key(42),f.name);console.log(o[42]);", .expected = "read\n" },
};

test "virtual provider ten public ES5 entries retain exact providers and runtime" {
    const test_helpers = @import("../bundler/test_helpers.zig");
    const profile = @import("../profile.zig");
    var resync_totals: [3]u32 = .{ 0, 0, 0 };
    for (public_cases, 0..) |case, index| for (0..3) |mode| {
        const minify = mode == 1;
        const minify_ids = mode == 2;
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try test_helpers.writeFile(tmp.dir, "entry.mjs", case.source);
        const entry = try test_helpers.absPath(&tmp, "entry.mjs");
        defer std.testing.allocator.free(entry);
        profile.resetForTest();
        defer profile.resetForTest();
        profile.setIoForTest(std.testing.io);
        profile.addFromCsv("graph.resync.semantic");
        var bundler = @import("../bundler/bundler.zig").Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry}, .platform = .node, .format = .cjs, .unsupported = @import("compat.zig").fromESTarget(.es5), .minify_whitespace = minify, .minify_identifiers = minify_ids });
        defer bundler.deinit();
        const result = try bundler.bundle(std.testing.io);
        defer result.deinit(std.testing.allocator);
        try std.testing.expect(!result.hasErrors());
        const actual = try std.process.run(std.testing.allocator, std.testing.io, .{ .argv = &.{ "node", "-e", result.output } });
        defer std.testing.allocator.free(actual.stdout);
        defer std.testing.allocator.free(actual.stderr);
        try std.testing.expect(actual.term == .exited);
        try std.testing.expectEqual(@as(u8, 0), actual.term.exited);
        try std.testing.expectEqualStrings(case.expected, actual.stdout);
        std.debug.print("provider-public case={d} min={any} ids={any} resync={d}\n", .{ index, minify, minify_ids, profile.count(.graph_resync_semantic) });
        resync_totals[mode] += profile.count(.graph_resync_semantic);
    };
    try std.testing.expectEqual(@as(u32, 0), resync_totals[0]);
    try std.testing.expectEqual(@as(u32, 0), resync_totals[1]);
    // Identifier minification runs the existing entry prepass once. The frozen
    // per-module trace proves provider completion/exact and no provider resync.
    try std.testing.expectEqual(@as(u32, public_cases.len), resync_totals[2]);
}

fn equalSourceTransform(_: ?*anyopaque, code: []const u8, id: []const u8, _: std.mem.Allocator, _: *@import("../bundler/plugin.zig").HookContext) @import("../bundler/plugin.zig").PluginError!?[]const u8 {
    if (!std.mem.startsWith(u8, id, helpers.ID_PREFIX)) return null;
    return code;
}
fn copiedSourceTransform(_: ?*anyopaque, code: []const u8, id: []const u8, a: std.mem.Allocator, _: *@import("../bundler/plugin.zig").HookContext) @import("../bundler/plugin.zig").PluginError!?[]const u8 {
    if (!std.mem.startsWith(u8, id, helpers.ID_PREFIX)) return null;
    return try a.dupe(u8, code);
}
fn untouchedAst(_: ?*anyopaque, _: *@import("../bundler/plugin.zig").AstTransformCtx, _: NodeIndex) @import("../bundler/plugin.zig").PluginError!?NodeIndex {
    return null;
}

test "virtual provider actual source transform and AST hook preserve fallback" {
    const test_helpers = @import("../bundler/test_helpers.zig");
    const profile = @import("../profile.zig");
    const Plugin = @import("../bundler/plugin.zig").Plugin;
    const controls = [_]Plugin{
        .{ .name = "equal-source-transform", .transform = equalSourceTransform },
        .{ .name = "copied-source-transform", .transform = copiedSourceTransform },
        .{ .name = "untouched-AST", .visitor = .{ .on_program = untouchedAst } },
    };
    for (controls, 0..) |control, index| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try test_helpers.writeFile(tmp.dir, "entry.mjs", public_cases[0].source);
        const entry = try test_helpers.absPath(&tmp, "entry.mjs");
        defer std.testing.allocator.free(entry);
        profile.resetForTest();
        defer profile.resetForTest();
        profile.setIoForTest(std.testing.io);
        profile.addFromCsv("graph.resync.semantic");
        var bundler = @import("../bundler/bundler.zig").Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry}, .platform = .node, .format = .cjs, .unsupported = @import("compat.zig").fromESTarget(.es5), .plugins = &.{control} });
        defer bundler.deinit();
        const result = try bundler.bundle(std.testing.io);
        defer result.deinit(std.testing.allocator);
        try std.testing.expect(!result.hasErrors());
        const actual = try std.process.run(std.testing.allocator, std.testing.io, .{ .argv = &.{ "node", "-e", result.output } });
        defer std.testing.allocator.free(actual.stdout);
        defer std.testing.allocator.free(actual.stderr);
        try std.testing.expect(actual.term == .exited);
        try std.testing.expectEqual(@as(u8, 0), actual.term.exited);
        try std.testing.expectEqualStrings(public_cases[0].expected, actual.stdout);
        std.debug.print("provider-fallback producer={d} resync={d}\n", .{ index, profile.count(.graph_resync_semantic) });
        try std.testing.expect(profile.count(.graph_resync_semantic) > 0);
    }
}

test "virtual provider no-demand and syntax or regexp work keep existing paths" {
    const test_helpers = @import("../bundler/test_helpers.zig");
    const profile = @import("../profile.zig");
    const inputs = [_]PublicCase{
        .{ .source = "console.log(42);", .expected = "42\n" },
        public_cases[0],
        .{ .source = "var r=/./s;console.log(r.test('\\n'));", .expected = "true\n" },
    };
    for (inputs, 0..) |case, index| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try test_helpers.writeFile(tmp.dir, "entry.mjs", case.source);
        const entry = try test_helpers.absPath(&tmp, "entry.mjs");
        defer std.testing.allocator.free(entry);
        profile.resetForTest();
        defer profile.resetForTest();
        profile.setIoForTest(std.testing.io);
        profile.addFromCsv("graph.resync.semantic");
        var bundler = @import("../bundler/bundler.zig").Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry}, .platform = .node, .format = .cjs, .unsupported = @import("compat.zig").fromESTarget(.es5), .minify_syntax = index == 1 });
        defer bundler.deinit();
        const result = try bundler.bundle(std.testing.io);
        defer result.deinit(std.testing.allocator);
        try std.testing.expect(!result.hasErrors());
        const actual = try std.process.run(std.testing.allocator, std.testing.io, .{ .argv = &.{ "node", "-e", result.output } });
        defer std.testing.allocator.free(actual.stdout);
        defer std.testing.allocator.free(actual.stderr);
        try std.testing.expect(actual.term == .exited);
        try std.testing.expectEqual(@as(u8, 0), actual.term.exited);
        try std.testing.expectEqualStrings(case.expected, actual.stdout);
        std.debug.print("provider-work-bound index={d} resync={d}\n", .{ index, profile.count(.graph_resync_semantic) });
        if (index == 0) try std.testing.expectEqual(@as(u32, 0), profile.count(.graph_resync_semantic)) else try std.testing.expect(profile.count(.graph_resync_semantic) > 0);
    }
}
