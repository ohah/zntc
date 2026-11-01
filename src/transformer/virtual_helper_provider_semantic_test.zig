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
        if (selected.?.externals.len != 0) {
            try std.testing.expectEqual(@as(usize, if (selected.?.origin.catalog == .super_set) 3 else 2), selected.?.externals.len);
            const external = selected.?.externals[0];
            const output = t.virtual_provider_visits.get(external.node) orelse return error.MissingExternalVisit;
            try std.testing.expect(semantic.symbol_ids[output] == null);
            try std.testing.expect(!t.explicit_global_reference_nodes.contains(output));
            const expected_scope = scope_utils.expectedScope(t.ast, root, &parent_map, &owners, output) orelse return error.MissingExternalActualScope;
            try std.testing.expectEqual(external.owner.scope, @backingInt(expected_scope));
            const ids = @constCast(semantic.symbol_ids);
            const foreign_sid = for (semantic.references) |row| {
                if (!row.flags.declare and !row.node_index.isNone()) break @backingInt(row.symbol_id);
            } else return error.MissingActualProviderRead;
            ids[output] = foreign_sid;
            const accepted_bound = try certificate.complete(&t, &semantic, loaded.contents, root);
            ids[output] = null;
            try std.testing.expect(!accepted_bound);
            try std.testing.expect(try certificate.complete(&t, &semantic, loaded.contents, root));
            const saved_ids = semantic.symbol_ids;
            semantic.symbol_ids = saved_ids[0..output];
            const accepted_missing_slot = try certificate.complete(&t, &semantic, loaded.contents, root);
            semantic.symbol_ids = saved_ids;
            try std.testing.expect(!accepted_missing_slot);
            try std.testing.expect(try certificate.complete(&t, &semantic, loaded.contents, root));
            const external_rows = @constCast(t.virtual_provider_source.?.externals);
            const saved_external = external_rows[0];
            const program_scope = analyzer.scope_owner_map.get(@backingInt(source_root)) orelse return error.MissingInitialProviderRootScope;
            try std.testing.expect(program_scope != external.owner.scope);
            external_rows[0].owner.scope = program_scope;
            const accepted_wrong_use_scope = try certificate.complete(&t, &semantic, loaded.contents, root);
            external_rows[0] = saved_external;
            try std.testing.expect(!accepted_wrong_use_scope);
            try std.testing.expect(try certificate.complete(&t, &semantic, loaded.contents, root));
            const duplicate_index: usize = if (selected.?.origin.catalog == .super_set) 2 else 1;
            const saved_second = external_rows[duplicate_index];
            external_rows[duplicate_index] = external_rows[0];
            const accepted_duplicate_external = try certificate.complete(&t, &semantic, loaded.contents, root);
            external_rows[duplicate_index] = saved_second;
            try std.testing.expect(!accepted_duplicate_external);
            try std.testing.expect(try certificate.complete(&t, &semantic, loaded.contents, root));
            try t.explicit_global_reference_nodes.put(a, output, {});
            const accepted_generated = try certificate.complete(&t, &semantic, loaded.contents, root);
            _ = t.explicit_global_reference_nodes.remove(output);
            try std.testing.expect(!accepted_generated);
            try std.testing.expect(try certificate.complete(&t, &semantic, loaded.contents, root));
            const live_scopes = @constCast(semantic.scopes);
            const saved_parent = live_scopes[external.owner.scope].parent;
            live_scopes[external.owner.scope].parent = .none;
            const accepted_parent = try certificate.complete(&t, &semantic, loaded.contents, root);
            live_scopes[external.owner.scope].parent = saved_parent;
            try std.testing.expect(!accepted_parent);
            try std.testing.expect(try certificate.complete(&t, &semantic, loaded.contents, root));
            if (selected.?.origin.catalog == .super_set) {
                const witness = t.virtual_provider_source.?;
                const error_index = for (witness.externals, 0..) |item, i| {
                    if (std.mem.eql(u8, witness.syntax.getText(witness.syntax.nodes.items[item.node].data.string_ref), "TypeError")) break i;
                } else return error.MissingSourceTypeErrorRole;
                const error_external = witness.externals[error_index];
                const error_output = t.virtual_provider_visits.get(error_external.node) orelse return error.MissingTypeErrorVisit;
                try std.testing.expect(error_output < semantic.symbol_ids.len and semantic.symbol_ids[error_output] == null);
                ids[error_output] = foreign_sid;
                const accepted_error_sid = try certificate.complete(&t, &semantic, loaded.contents, root);
                ids[error_output] = null;
                try std.testing.expect(!accepted_error_sid);
                try t.explicit_global_reference_nodes.put(a, error_output, {});
                const accepted_error_marker = try certificate.complete(&t, &semantic, loaded.contents, root);
                _ = t.explicit_global_reference_nodes.remove(error_output);
                try std.testing.expect(!accepted_error_marker);
                external_rows[error_index].owner.node = @backingInt(source_root);
                const accepted_error_owner = try certificate.complete(&t, &semantic, loaded.contents, root);
                external_rows[error_index] = error_external;
                try std.testing.expect(!accepted_error_owner);
                try std.testing.expect(error_external.owner.scope != external.owner.scope);
                external_rows[error_index].owner.scope = external.owner.scope;
                const accepted_error_scope = try certificate.complete(&t, &semantic, loaded.contents, root);
                external_rows[error_index] = error_external;
                try std.testing.expect(!accepted_error_scope);
                var foreign_output = parser.ast;
                const saved_output_domain = t.virtual_provider_source.?.output_domain;
                t.virtual_provider_source.?.output_domain = &foreign_output;
                const accepted_output_domain = try certificate.complete(&t, &semantic, loaded.contents, root);
                t.virtual_provider_source.?.output_domain = saved_output_domain;
                try std.testing.expect(!accepted_output_domain);
                // Keep the legitimate source/output shape, null slot, owner and
                // counts plausible while substituting a non-runtime property.
                const member_raw = for (witness.nodes) |raw| {
                    const member = witness.syntax.nodes.items[raw];
                    if (member.tag != .static_member_expression) continue;
                    const key = witness.syntax.readExtraNode(member.data.extra, 1);
                    if (std.mem.eql(u8, witness.syntax.getText(witness.syntax.getNode(key).data.string_ref), "writable")) break raw;
                } else return error.MissingActualWritableProperty;
                const property = witness.syntax.readExtraNode(witness.syntax.nodes.items[member_raw].data.extra, 1);
                try std.testing.expect(std.mem.indexOfScalar(NodeIndex, witness.leaves, property) == null);
                const output_member = t.virtual_provider_visits.get(member_raw) orelse return error.MissingPropertyContainerVisit;
                const output_property = t.ast.readExtraNode(t.ast.nodes.items[output_member].data.extra, 1);
                external_rows[error_index].node = @backingInt(property);
                const accepted_property = try certificate.complete(&t, &semantic, loaded.contents, root);
                external_rows[error_index] = error_external;
                try std.testing.expect(!accepted_property);
                const source_nodes = t.virtual_provider_source.?.syntax.nodes.items;
                const saved_source_property = source_nodes[@backingInt(property)];
                const saved_output_property = t.ast.getNode(output_property);
                const error_spelling = source_nodes[error_external.node].data.string_ref;
                source_nodes[@backingInt(property)].data.string_ref = error_spelling;
                t.ast.nodes.items[@backingInt(output_property)].data.string_ref = error_spelling;
                external_rows[error_index].node = @backingInt(property);
                const accepted_nonlexical_type_error = try certificate.complete(&t, &semantic, loaded.contents, root);
                external_rows[error_index] = error_external;
                source_nodes[@backingInt(property)] = saved_source_property;
                t.ast.nodes.items[@backingInt(output_property)] = saved_output_property;
                try std.testing.expect(!accepted_nonlexical_type_error);
                try std.testing.expect(try certificate.complete(&t, &semantic, loaded.contents, root));
            }
        }
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

test "regexp-only work retains the graph while syntax and regex helpers keep fallback" {
    const test_helpers = @import("../bundler/test_helpers.zig");
    const profile = @import("../profile.zig");
    const inputs = [_]PublicCase{
        .{ .source = "console.log(42);", .expected = "42\n" },
        public_cases[0],
        .{ .source = "var r=/./s;console.log(r.test('\\n'));", .expected = "true\n" },
        .{ .source = "var r=/(?<name>a)/;console.log(r.exec('a').groups.name);", .expected = "a\n" },
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
        if (index == 0 or index == 2) {
            try std.testing.expectEqual(@as(u32, 0), profile.count(.graph_resync_semantic));
        } else {
            try std.testing.expect(profile.count(.graph_resync_semantic) > 0);
        }
    }
}

test "ES5 regex literal variants compile with exact runtime output and no semantic resync" {
    const test_helpers = @import("../bundler/test_helpers.zig");
    const profile = @import("../profile.zig");
    const Case = struct { source: []const u8, expected: []const u8 };
    const cases = [_]Case{
        .{ .source = "var r=/./s;console.log(r.test('\\n'));", .expected = "true\n" },
        .{ .source = "var r=/a.b/s;console.log(r.test('a\\nb'));", .expected = "true\n" },
        .{ .source = "var r=/a\\.b/s;console.log(r.test('a.b'),r.test('axb'));", .expected = "true false\n" },
        .{ .source = "var r=/[.]/s;console.log(r.test('.'));", .expected = "true\n" },
        .{ .source = "var r=/foo/y;console.log(r.toString());", .expected = "/foo/\n" },
        .{ .source = "var r=/\\u{41}/u;console.log(r.test('A'));", .expected = "true\n" },
        .{ .source = "var r=/\\u{1F600}/u;console.log(r.test('😀'));", .expected = "true\n" },
        .{ .source = "var r=/[\\u{41}-\\u{5A}]/u;console.log(r.test('M'));", .expected = "true\n" },
        .{ .source = "var r=/a.b/sy;console.log(r.test('a\\nb'));", .expected = "true\n" },
        .{ .source = "function matches(input){var r=/x.y/s;return r.test(input)}console.log(matches('x\\ny'));", .expected = "true\n" },
    };
    for (cases, 0..) |case, index| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try test_helpers.writeFile(tmp.dir, "entry.mjs", case.source);
        const entry = try test_helpers.absPath(&tmp, "entry.mjs");
        defer std.testing.allocator.free(entry);
        profile.resetForTest();
        defer profile.resetForTest();
        profile.setIoForTest(std.testing.io);
        profile.addFromCsv("graph.resync.semantic");
        var bundler = @import("../bundler/bundler.zig").Bundler.init(std.testing.allocator, .{
            .entry_points = &.{entry},
            .platform = .node,
            .format = .cjs,
            .unsupported = @import("compat.zig").fromESTarget(.es5),
            .minify_identifiers = index % 2 == 1,
        });
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
        if (profile.count(.graph_resync_semantic) != 0)
            std.debug.print("regex graph retention failed index={d} resync={d}\n", .{ index, profile.count(.graph_resync_semantic) });
        try std.testing.expectEqual(@as(u32, 0), profile.count(.graph_resync_semantic));
    }
}

test "regex-retained static imports keep normal tree shaking" {
    const test_helpers = @import("../bundler/test_helpers.zig");
    const profile = @import("../profile.zig");
    defer profile.resetForTest();
    for ([_]bool{ false, true }) |minify_identifiers| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try test_helpers.writeFile(tmp.dir, "entry.mjs", "import {live as aLongImportedFunctionName} from './lib.mjs';var check=/./s;console.log(aLongImportedFunctionName(),check.test('\\n'));");
        try test_helpers.writeFile(tmp.dir, "lib.mjs", "export function live(){var r=/./s;return r.test('\\n')}export function dead(){console.log('DEAD')}");
        const entry = try test_helpers.absPath(&tmp, "entry.mjs");
        defer std.testing.allocator.free(entry);
        profile.resetForTest();
        profile.setIoForTest(std.testing.io);
        profile.addFromCsv("graph.resync.semantic");
        var bundler = @import("../bundler/bundler.zig").Bundler.init(std.testing.allocator, .{
            .entry_points = &.{entry},
            .platform = .node,
            .format = .cjs,
            .unsupported = @import("compat.zig").fromESTarget(.es5),
            .minify_identifiers = minify_identifiers,
        });
        defer bundler.deinit();
        const result = try bundler.bundle(std.testing.io);
        defer result.deinit(std.testing.allocator);
        try std.testing.expect(!result.hasErrors());
        try std.testing.expect(std.mem.indexOf(u8, result.output, "DEAD") == null);
        const actual = try std.process.run(std.testing.allocator, std.testing.io, .{ .argv = &.{ "node", "-e", result.output } });
        defer std.testing.allocator.free(actual.stdout);
        defer std.testing.allocator.free(actual.stderr);
        try std.testing.expect(actual.term == .exited);
        try std.testing.expectEqual(@as(u8, 0), actual.term.exited);
        try std.testing.expectEqualStrings("true true\n", actual.stdout);
        try std.testing.expectEqual(@as(u32, 0), profile.count(.graph_resync_semantic));
    }
}

test "ES5 regex graph retention keeps static imports and rejects hostile combinations" {
    const test_helpers = @import("../bundler/test_helpers.zig");
    const profile = @import("../profile.zig");
    defer profile.resetForTest();
    const Case = struct {
        name: []const u8,
        entry: []const u8,
        library: []const u8,
        minify_identifiers: bool,
        expected_resyncs: u32,
        expected_stdout: ?[]const u8 = null,
    };
    const cases = [_]Case{
        .{ .name = "exported regex only", .entry = "import {live} from './lib.mjs';console.log(live());", .library = "export function live(){var r=/./s;return r.test('\\n')}", .minify_identifiers = false, .expected_resyncs = 0 },
        .{ .name = "import plus exported regex", .entry = "import {live} from './lib.mjs';var check=/./s;console.log(live(),check.test('\\n'));", .library = "export function live(){var r=/./s;return r.test('\\n')}", .minify_identifiers = false, .expected_resyncs = 0 },
        .{ .name = "minified import plus exported regex", .entry = "import {live as aLongImportedFunctionName} from './lib.mjs';var check=/./s;console.log(aLongImportedFunctionName(),check.test('\\n'));", .library = "export function live(){var r=/./s;return r.test('\\n')}", .minify_identifiers = true, .expected_resyncs = 0 },
        .{ .name = "named capture retains entry graph with one helper resync", .entry = "import {live} from './lib.mjs';var check=/(?<name>a)/;console.log(live(),check.test('a'));", .library = "export function live(){return true}", .minify_identifiers = false, .expected_resyncs = 1, .expected_stdout = "true true\n" },
        .{ .name = "class lowering keeps static import fallback", .entry = "import {live} from './lib.mjs';var check=/./s;class Marker{}console.log(live(),check.test('\\n'),Marker.name);", .library = "export function live(){return true}", .minify_identifiers = false, .expected_resyncs = 1 },
        .{ .name = "import attributes keep static import fallback", .entry = "import {live} from './lib.mjs' with { mode: 'hostile' };var check=/./s;console.log(live(),check.test('\\n'));", .library = "export function live(){return true}", .minify_identifiers = false, .expected_resyncs = 1 },
        .{ .name = "side-effect import attributes keep static import fallback", .entry = "import './lib.mjs' with { mode: 'hostile' };var check=/./s;console.log(check.test('\\n'));", .library = "export function live(){return true}", .minify_identifiers = false, .expected_resyncs = 1 },
        .{ .name = "direct eval keeps static import fallback", .entry = "import {live} from './lib.mjs';eval('void 0');var check=/./s;console.log(live(),check.test('\\n'));", .library = "export function live(){return true}", .minify_identifiers = false, .expected_resyncs = 1 },
    };
    for (cases) |case| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try test_helpers.writeFile(tmp.dir, "entry.mjs", case.entry);
        try test_helpers.writeFile(tmp.dir, "lib.mjs", case.library);
        const entry = try test_helpers.absPath(&tmp, "entry.mjs");
        defer std.testing.allocator.free(entry);
        profile.resetForTest();
        profile.setIoForTest(std.testing.io);
        profile.addFromCsv("graph.resync.semantic");
        var bundler = @import("../bundler/bundler.zig").Bundler.init(std.testing.allocator, .{
            .entry_points = &.{entry},
            .platform = .node,
            .format = .cjs,
            .unsupported = @import("compat.zig").fromESTarget(.es5),
            .minify_identifiers = case.minify_identifiers,
        });
        defer bundler.deinit();
        const result = try bundler.bundle(std.testing.io);
        defer result.deinit(std.testing.allocator);
        try std.testing.expect(!result.hasErrors());
        if (case.expected_resyncs != profile.count(.graph_resync_semantic))
            std.debug.print("regex graph boundary failed case={s} expected={d} actual={d}\n", .{
                case.name,
                case.expected_resyncs,
                profile.count(.graph_resync_semantic),
            });
        try std.testing.expectEqual(case.expected_resyncs, profile.count(.graph_resync_semantic));
        if (case.expected_stdout) |expected| {
            const actual = try std.process.run(std.testing.allocator, std.testing.io, .{ .argv = &.{ "node", "-e", result.output } });
            defer std.testing.allocator.free(actual.stdout);
            defer std.testing.allocator.free(actual.stderr);
            try std.testing.expect(actual.term == .exited);
            try std.testing.expectEqual(@as(u8, 0), actual.term.exited);
            try std.testing.expectEqualStrings(expected, actual.stdout);
        }
    }
}

test "virtual provider actual winning load disk source copy preserves current graph" {
    const test_helpers = @import("../bundler/test_helpers.zig");
    const profile = @import("../profile.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try test_helpers.writeFile(tmp.dir, "entry.mjs", public_cases[0].source);
    const entry = try test_helpers.absPath(&tmp, "entry.mjs");
    defer std.testing.allocator.free(entry);
    const cache = try test_helpers.absPath(&tmp, "cache");
    defer std.testing.allocator.free(cache);
    var counts: [2]u32 = .{ 0, 0 };
    for (0..2) |phase| {
        profile.resetForTest();
        defer profile.resetForTest();
        profile.setIoForTest(std.testing.io);
        profile.addFromCsv("graph.resync.semantic");
        var bundler = @import("../bundler/bundler.zig").Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry}, .platform = .node, .format = .cjs, .unsupported = @import("compat.zig").fromESTarget(.es5), .disk_cache_dir = cache });
        defer bundler.deinit();
        const result = try bundler.bundle(std.testing.io);
        defer result.deinit(std.testing.allocator);
        try std.testing.expect(!result.hasErrors());
        counts[phase] = profile.count(.graph_resync_semantic);
        std.debug.print("provider-warm-copy phase={d} semanticResync={d}\n", .{ phase, counts[phase] });
    }
    try std.testing.expectEqual(@as(u32, 0), counts[0]);
    try std.testing.expectEqual(@as(u32, 0), counts[1]);
}

fn expectCachedCapture(a: std.mem.Allocator, current: *@import("../bundler/module.zig").Module, source_options: helpers.SourceOptions, expected: bool) !void {
    const options: @import("transformer.zig").TransformOptions = .{ .unsupported = @import("compat.zig").fromESTarget(.es5), .emit_runtime_helper_imports = true };
    const capture = try @import("virtual_helper_provider_certificate.zig").captureFromModule(a, current, source_options, options, false);
    try std.testing.expectEqual(expected, capture != null);
}

test "virtual provider disk-copy actual producer rejects foreign ownership and restores atomically" {
    try expectDiskCopyAuthority("public-field");
}

test "virtual super-get provider disk-copy retains its actual winning constructor and scopes" {
    try expectDiskCopyAuthority("super-get");
}

fn expectDiskCopyAuthority(comptime short: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Plugin = @import("../bundler/plugin.zig").Plugin;
    const Runner = @import("../bundler/plugin.zig").PluginRunner;
    const module_mod = @import("../bundler/module.zig");
    const certificate = @import("virtual_helper_provider_certificate.zig");
    const source_options: helpers.SourceOptions = .{ .es5 = true };
    const plugins = [_]Plugin{helpers.makePlugin(&source_options)};
    const runner = Runner.init(&plugins);
    const id = helpers.ID_PREFIX ++ short;
    var hook: @import("../bundler/plugin.zig").HookContext = .{};
    const winning = (try runner.runLoadWithOrigin(id, a, &hook)).?;
    const origin = helpers.acceptWinningLoad(winning, &source_options).?;
    var scanner = try @import("../lexer/scanner.zig").Scanner.init(a, winning.result.contents);
    scanner.is_module = true;
    var parser = @import("../parser/parser.zig").Parser.init(a, &scanner);
    parser.is_module = true;
    _ = try parser.parse();
    var analyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer.init(a, &parser.ast);
    analyzer.is_module = true;
    analyzer.enable_stmt_info = true;
    analyzer.enable_exact_declaration_anchors = true;
    analyzer.collect_unresolved_reference_nodes = true;
    try analyzer.analyze();
    const semantic: module_mod.ModuleSemanticData = .{ .symbols = analyzer.symbols, .scopes = analyzer.scopes.items, .scope_maps = analyzer.scope_maps.items, .scope_owner_map = analyzer.scope_owner_map, .node_scope_provenance = analyzer.node_scope_provenance, .symbol_ids = analyzer.symbol_ids.items, .exported_names = analyzer.exported_names, .unresolved_references = analyzer.unresolved_references, .references = analyzer.references.items, .class_self_symbol_map = analyzer.class_self_symbol_map, .helper_scope_map = analyzer.helper_scope_map };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cache_path = try @import("../bundler/test_helpers.zig").absPath(&tmp, "cache");
    defer std.testing.allocator.free(cache_path);
    var store = try @import("../bundler/disk_module_store.zig").DiskModuleStore.init(std.testing.allocator, cache_path);
    defer store.deinit();
    const key: u64 = 0x4819;
    try store.store(std.testing.io, std.testing.allocator, key, &parser.ast, &semantic);
    const restored = (try store.load(std.testing.io, std.testing.allocator, a, key)).?;
    const foreign_pair = (try store.load(std.testing.io, std.testing.allocator, a, key)).?;
    var current = module_mod.Module.init(@fromBackingInt(@intCast(0)), id);
    current.module_type = .js;
    current.source = winning.result.contents;
    current.runtime_helper_source = origin;
    current.ast = restored.ast;
    current.semantic = restored.semantic;
    current.parse_arena = &arena;
    current.disk_cache_key = key;
    try std.testing.expect(current.ast.?.source.ptr != current.source.ptr);
    try expectCachedCapture(a, &current, source_options, false);
    try std.testing.expect(!certificate.recordInstalledDiskSource(&current, &foreign_pair, source_options));
    try std.testing.expectEqual(module_mod.SemanticOwnerToken.unassigned, current.semantic.?.owner_token);
    try std.testing.expect(current.runtime_helper_cache_source == null);
    const original_ast = current.ast;
    const original_semantic = current.semantic;
    const original_source = current.source;
    const initial_scopes = try a.dupe(@import("../semantic/scope.zig").Scope, current.semantic.?.scopes);
    const initial_rows = try a.dupe(symbol.Reference, current.semantic.?.references);
    try std.testing.expect(!certificate.recordInstalledDiskSource(&current, &restored, .{ .es5 = false }));
    for (0..6) |mutation| {
        switch (mutation) {
            0 => current.runtime_helper_source = null,
            1 => current.runtime_helper_source.?.variant = .min,
            2 => current.source = try a.dupe(u8, current.source),
            3 => current.ast.?.source = try a.dupe(u8, current.ast.?.source),
            4 => current.semantic = foreign_pair.semantic,
            5 => current.ast = foreign_pair.ast,
            else => unreachable,
        }
        const accepted = certificate.recordInstalledDiskSource(&current, &restored, source_options);
        current.ast = original_ast;
        current.semantic = original_semantic;
        current.source = original_source;
        current.runtime_helper_source = origin;
        try std.testing.expect(!accepted);
        try std.testing.expect(current.runtime_helper_cache_source == null);
        try std.testing.expectEqual(module_mod.SemanticOwnerToken.unassigned, current.semantic.?.owner_token);
        try std.testing.expectEqualDeep(initial_scopes, current.semantic.?.scopes);
        try std.testing.expectEqualDeep(initial_rows, current.semantic.?.references);
    }
    try std.testing.expect(certificate.recordInstalledDiskSource(&current, &restored, source_options));
    try expectCachedCapture(a, &current, source_options, true);
    const saved_copy = current.runtime_helper_cache_source;
    const saved_owner = current.semantic.?.owner_token;
    const saved_scopes = try a.dupe(@import("../semantic/scope.zig").Scope, current.semantic.?.scopes);
    const saved_rows = try a.dupe(symbol.Reference, current.semantic.?.references);
    try std.testing.expect(!certificate.recordInstalledDiskSource(&current, &foreign_pair, source_options));
    try std.testing.expect(std.meta.eql(saved_copy, current.runtime_helper_cache_source));
    try std.testing.expectEqual(saved_owner, current.semantic.?.owner_token);
    try expectCachedCapture(a, &current, source_options, true);

    var foreign_hook: @import("../bundler/plugin.zig").HookContext = .{};
    const foreign_winner = (try runner.runLoadWithOrigin(id, a, &foreign_hook)).?;
    var other = module_mod.Module.init(@fromBackingInt(@intCast(1)), id);
    other.module_type = .js;
    other.source = foreign_winner.result.contents;
    other.runtime_helper_source = helpers.acceptWinningLoad(foreign_winner, &source_options).?;
    other.ast = foreign_pair.ast;
    other.semantic = foreign_pair.semantic;
    other.parse_arena = &arena;
    other.disk_cache_key = key;
    try std.testing.expect(certificate.recordInstalledDiskSource(&other, &foreign_pair, source_options));
    try expectCachedCapture(a, &other, source_options, true);
    try std.testing.expect(saved_owner != other.semantic.?.owner_token);

    const pending_pair = (try store.load(std.testing.io, std.testing.allocator, a, key)).?;
    var foreign_owner_pair = pending_pair;
    foreign_owner_pair.semantic.owner_token = other.semantic.?.owner_token;
    var pending_hook: @import("../bundler/plugin.zig").HookContext = .{};
    const pending_winner = (try runner.runLoadWithOrigin(id, a, &pending_hook)).?;
    var pending = module_mod.Module.init(@fromBackingInt(@intCast(2)), id);
    pending.module_type = .js;
    pending.source = pending_winner.result.contents;
    pending.runtime_helper_source = helpers.acceptWinningLoad(pending_winner, &source_options).?;
    pending.ast = foreign_owner_pair.ast;
    pending.semantic = foreign_owner_pair.semantic;
    pending.parse_arena = &arena;
    pending.disk_cache_key = key;
    try std.testing.expect(!certificate.recordInstalledDiskSource(&pending, &foreign_owner_pair, source_options));
    try std.testing.expect(pending.runtime_helper_cache_source == null);
    try std.testing.expectEqual(other.semantic.?.owner_token, pending.semantic.?.owner_token);
    try std.testing.expectEqualDeep(initial_scopes, pending.semantic.?.scopes);
    try std.testing.expectEqualDeep(initial_rows, pending.semantic.?.references);
    pending.semantic = pending_pair.semantic;
    try std.testing.expect(certificate.recordInstalledDiskSource(&pending, &pending_pair, source_options));
    try expectCachedCapture(a, &pending, source_options, true);
    try std.testing.expect(pending.semantic.?.owner_token != other.semantic.?.owner_token);
    var another_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer another_arena.deinit();
    const saved_current_semantic = current.semantic;
    for (0..12) |mutation| {
        switch (mutation) {
            0 => current.runtime_helper_cache_source = null,
            1 => current.runtime_helper_cache_source = other.runtime_helper_cache_source,
            2 => current.runtime_helper_cache_source.?.ast_domain = &other.ast.?,
            3 => current.runtime_helper_cache_source.?.semantic_domain = &other.semantic.?,
            4 => current.runtime_helper_cache_source.?.owner = other.semantic.?.owner_token,
            5 => current.runtime_helper_cache_source.?.arena_domain = &another_arena,
            6 => current.runtime_helper_cache_source.?.root = @fromBackingInt(@intCast(0)),
            7 => current.runtime_helper_cache_source.?.cache_key ^= 1,
            8 => current.source = try a.dupe(u8, current.source),
            9 => current.ast.?.source = try a.dupe(u8, current.ast.?.source),
            10 => {
                current.ast = other.ast;
                current.ast.?.source = restored.ast.source;
            },
            11 => {
                current.semantic = other.semantic;
                current.semantic.?.owner_token = saved_owner;
            },
            else => unreachable,
        }
        try expectCachedCapture(a, &current, source_options, false);
        current.runtime_helper_cache_source = saved_copy;
        current.source = original_source;
        current.ast = original_ast;
        current.semantic = saved_current_semantic;
        try std.testing.expectEqual(saved_owner, current.semantic.?.owner_token);
        try std.testing.expectEqualDeep(saved_scopes, current.semantic.?.scopes);
        try std.testing.expectEqualDeep(saved_rows, current.semantic.?.references);
        try expectCachedCapture(a, &current, source_options, true);
    }
}

test "virtual super-get provider preserves its actual initial graph without post-transform analysis" {
    const test_helpers = @import("../bundler/test_helpers.zig");
    const profile = @import("../profile.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try test_helpers.writeFile(tmp.dir, "entry.mjs", "var parent={value:7};var object={get ['value'](){return super.value}};Object.setPrototypeOf(object,parent);console.log(object.value);");
    const entry = try test_helpers.absPath(&tmp, "entry.mjs");
    defer std.testing.allocator.free(entry);
    var cache = @import("../bundler/resolve_cache.zig").ResolveCache.init(std.testing.allocator, .{ .platform = .node });
    defer cache.deinit();
    var graph = @import("../bundler/graph.zig").ModuleGraph.init(std.testing.allocator, &cache);
    defer graph.deinit();
    graph.minify_identifiers = true;
    graph.transform_options_base.unsupported = @import("compat.zig").fromESTarget(.es5);
    profile.resetForTest();
    defer profile.resetForTest();
    profile.setIoForTest(std.testing.io);
    profile.addFromCsv("graph.discover.pm.semantic,graph.resync.semantic");
    try graph.build(std.testing.io, &.{entry});
    const provider = graph.findModuleByPath(helpers.ID_PREFIX ++ "super-get") orelse return error.MissingActualSuperGetProvider;
    try std.testing.expect(provider.ast != null and provider.semantic != null);
    std.debug.print("super-get initial={d} post={d} winning={any}\n", .{ profile.count(.graph_discover_pm_semantic), profile.count(.graph_resync_semantic), provider.runtime_helper_source != null });
    // Initial parser/analyzer execution is required; only the additional
    // post-transform refresh of this real provider should disappear.
    try std.testing.expect(profile.count(.graph_discover_pm_semantic) != 0);
    try std.testing.expectEqual(@as(u32, 0), profile.count(.graph_resync_semantic));
}

test "virtual super-get provider preserves actual external roles and loop owners" {
    for ([_]bool{ false, true }) |minify| {
        for ([_]bool{ false, true }) |full_driver| {
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            try observe(arena.allocator(), helpers.ID_PREFIX ++ "super-get", minify, full_driver);
        }
    }
}

test "virtual super-set provider observes exact initial lexical external roles" {
    for ([_]bool{ false, true }) |minify| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const options: helpers.SourceOptions = .{ .es5 = true, .minify = minify };
        const plugin = helpers.makePlugin(&options);
        var hook: @import("../bundler/plugin.zig").HookContext = .{};
        const loaded = (try plugin.load.?(plugin.context, helpers.ID_PREFIX ++ "super-set", a, &hook)).?;
        var scanner = try @import("../lexer/scanner.zig").Scanner.init(a, loaded.contents);
        scanner.is_module = true;
        var parser = @import("../parser/parser.zig").Parser.init(a, &scanner);
        parser.is_module = true;
        _ = try parser.parse();
        try std.testing.expectEqual(@as(usize, 0), parser.errors.items.len);
        var analyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer.init(a, &parser.ast);
        analyzer.is_module = true;
        analyzer.enable_stmt_info = true;
        analyzer.enable_exact_declaration_anchors = true;
        analyzer.collect_unresolved_reference_nodes = true;
        try analyzer.analyze();
        const root: NodeIndex = @fromBackingInt(@as(u32, @intCast(parser.ast.nodes.items.len - 1)));
        const utils = @import("output_scope_test_utils.zig");
        var parents = try utils.buildParentMap(a, &parser.ast, root);
        const leaves = try @import("../semantic/reference_walk.zig").collectIdentifierReferences(a, &parser.ast, root);
        var objects: usize = 0;
        var errors: usize = 0;
        for (leaves) |leaf| {
            const raw = @backingInt(leaf);
            try std.testing.expect(raw < analyzer.symbol_ids.items.len);
            if (analyzer.symbol_ids.items[raw] != null) continue;
            const node = parser.ast.getNode(leaf);
            try std.testing.expectEqual(ast.Node.Tag.identifier_reference, node.tag);
            const spelling = parser.ast.getText(node.data.string_ref);
            var owner = raw;
            while (!analyzer.scope_owner_map.contains(owner)) owner = parents.get(owner) orelse return error.MissingInitialExternalOwner;
            const scope = analyzer.scope_owner_map.get(owner).?;
            const actual = utils.expectedScope(&parser.ast, root, &parents, &analyzer.scope_owner_map, raw) orelse return error.MissingInitialExternalScope;
            try std.testing.expectEqual(scope, @backingInt(actual));
            for (analyzer.references.items) |row| try std.testing.expect(row.node_index != leaf and row.declaration_node_index != leaf);
            try std.testing.expect(analyzer.unresolved_reference_nodes.contains(raw));
            if (std.mem.eql(u8, spelling, "Object")) {
                objects += 1;
            } else if (std.mem.eql(u8, spelling, "TypeError")) {
                errors += 1;
                try std.testing.expectEqual(@import("../semantic/scope.zig").ScopeKind.block, analyzer.scopes.items[scope].kind);
            } else return error.UnexpectedSuperSetLexicalExternal;
            std.debug.print("super-set initial min={any} role={s} node={d} null-slot=1 owner={d}:{s} scope={d}:{s} rows=0\n", .{ minify, spelling, raw, owner, @tagName(parser.ast.nodes.items[owner].tag), scope, @tagName(analyzer.scopes.items[scope].kind) });
        }
        try std.testing.expectEqual(@as(usize, 2), objects);
        try std.testing.expectEqual(@as(usize, 1), errors);
    }
}

test "virtual super-set provider preserves its actual initial graph without post-transform analysis" {
    const test_helpers = @import("../bundler/test_helpers.zig");
    const profile = @import("../profile.zig");
    var counts: [2]u32 = undefined;
    for ([_]bool{ false, true }, 0..) |minify, i| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try test_helpers.writeFile(tmp.dir, "entry.mjs", "var base={set value(v){this.seen=v}};var object={set['value'](v){super.value=v}};Object.setPrototypeOf(object,base);object.value=7;console.log(object.seen);");
        const entry = try test_helpers.absPath(&tmp, "entry.mjs");
        defer std.testing.allocator.free(entry);
        var cache = @import("../bundler/resolve_cache.zig").ResolveCache.init(std.testing.allocator, .{ .platform = .node });
        defer cache.deinit();
        var graph = @import("../bundler/graph.zig").ModuleGraph.init(std.testing.allocator, &cache);
        defer graph.deinit();
        graph.minify_identifiers = minify;
        graph.transform_options_base.unsupported = @import("compat.zig").fromESTarget(.es5);
        profile.resetForTest();
        defer profile.resetForTest();
        profile.setIoForTest(std.testing.io);
        profile.addFromCsv("graph.discover.pm.semantic,graph.resync.semantic");
        try graph.build(std.testing.io, &.{entry});
        const provider = graph.findModuleByPath(helpers.ID_PREFIX ++ "super-set") orelse return error.MissingSuperSetProvider;
        try std.testing.expect(provider.ast != null and provider.semantic != null);
        counts[i] = profile.count(.graph_resync_semantic);
        std.debug.print("super-set Graph min={any} initial={d} post={d} winning={any}\n", .{ minify, profile.count(.graph_discover_pm_semantic), counts[i], provider.runtime_helper_source != null });
        try std.testing.expect(profile.count(.graph_discover_pm_semantic) != 0);
    }
    try std.testing.expectEqual([_]u32{ 0, 0 }, counts);
}

test "virtual super-set provider preserves actual external roles before binder and completion" {
    for ([_]bool{ false, true }) |minify| {
        for ([_]bool{ false, true }) |full_driver| {
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            try observe(arena.allocator(), helpers.ID_PREFIX ++ "super-set", minify, full_driver);
        }
    }
}

test "virtual super-set provider disk-copy retains its actual winning constructor and scopes" {
    try expectDiskCopyAuthority("super-set");
}
