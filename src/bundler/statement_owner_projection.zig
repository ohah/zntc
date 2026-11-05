//! Statement coordinates from current AST containment; binding and scope IDs are inputs.
const std = @import("std");
const ast_mod = @import("../parser/ast.zig");
const NodeIndex = ast_mod.NodeIndex;
const SemanticReference = @import("../semantic/symbol.zig").Reference;
pub const Context = @import("../semantic/statement_coordinates.zig").Context;
pub const collect = @import("../semantic/statement_coordinates.zig").collect;

// Native Annex B creates a var-entry declaration without a source binding leaf.
// Only a reachable declaration's existing typed alias can select that entry.
fn projectNativeAnnexBEntries(
    allocator: std.mem.Allocator,
    ast: *const ast_mod.Ast,
    contexts: []const ?Context,
    semantic: anytype,
    anchorless: *std.AutoHashMapUnmanaged(u32, ?Context),
) !bool {
    // Most anchorless entries are class/engine roles already handled above.
    // Avoid another AST scan unless an existing native alias needs coordinates.
    const has_native_alias = blk: {
        for (semantic.symbols.items) |symbol| {
            if (!symbol.annex_b_alias.variable.isNone() and symbol.annex_b_alias.state == .native and
                anchorless.contains(@backingInt(symbol.annex_b_alias.variable))) break :blk true;
        }
        break :blk false;
    };
    if (!has_native_alias) return true;
    const ScopeId = @import("../semantic/scope.zig").ScopeId;
    const Binding = struct { lexical: u32, scope: ScopeId, rows: usize = 0 };
    var bindings: std.AutoHashMapUnmanaged(u32, Binding) = .empty;
    defer bindings.deinit(allocator);
    var aliases: std.AutoHashMapUnmanaged(u32, ScopeId) = .empty;
    defer aliases.deinit(allocator);
    var wanted: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer wanted.deinit(allocator);
    for (contexts, 0..) |context, raw| {
        if (context == null or ast.nodes.items[raw].tag != .function_declaration) continue;
        const declaration: ast_mod.NodeIndex = @fromBackingInt(@intCast(raw));
        const name = ast.readExtraNode(ast.getNode(declaration).data.extra, ast_mod.FunctionExtra.name);
        if (name.isNone()) continue; // Anonymous default declarations have their own role.
        const role = (try @import("../semantic/annex_b_function.zig").forDeclaration(ast, semantic.symbol_ids, semantic.symbols.items, declaration)) orelse continue;
        const variable = @backingInt(role.variable);
        if (role.state != .native or !anchorless.contains(variable)) continue;
        const lexical = @backingInt(role.lexical);
        if (!@import("../lexer/scanner.zig").Scanner.identifierNamesEqual(
            ast.getText(semantic.symbols.items[lexical].name),
            ast.getText(semantic.symbols.items[variable].name),
        )) return false;
        const variable_scope = semantic.symbols.items[variable].scope_id;
        if (variable_scope.isNone() or variable_scope.toIndex() >= semantic.scopes.len or semantic.scopes[variable_scope.toIndex()].kind != .function) return false;
        var owner = semantic.symbols.items[lexical].scope_id;
        var hops: usize = 0;
        while (!owner.isNone() and hops < semantic.scopes.len) : (hops += 1) {
            if (owner.toIndex() >= semantic.scopes.len) return false;
            if (semantic.scopes[owner.toIndex()].kind.isVarScope()) break;
            owner = semantic.scopes[owner.toIndex()].parent;
        }
        if (owner != variable_scope) return false;
        const binding = ast.readExtraNode(ast.getNode(declaration).data.extra, ast_mod.FunctionExtra.name);
        const slot = try bindings.getOrPut(allocator, @backingInt(binding));
        if (slot.found_existing) return false;
        slot.value_ptr.* = .{ .lexical = lexical, .scope = semantic.symbols.items[lexical].scope_id };
        const alias = try aliases.getOrPut(allocator, variable);
        if (alias.found_existing and alias.value_ptr.* != variable_scope) return false;
        alias.value_ptr.* = variable_scope;
        try wanted.put(allocator, @backingInt(variable_scope), {});
    }
    if (aliases.count() == 0) return true;
    for (semantic.references) |reference| {
        const sid = @backingInt(reference.symbol_id);
        if (!reference.flags.declare) continue;
        if (reference.declaration_node_index.isNone()) {
            if (aliases.get(sid)) |scope| if (reference.scope_id != scope) return false;
            continue;
        }
        const binding = bindings.getPtr(@backingInt(reference.declaration_node_index)) orelse continue;
        if (sid != binding.lexical or reference.scope_id != binding.scope) return false;
        binding.rows += 1;
    }
    var declared = bindings.valueIterator();
    while (declared.next()) |binding| if (binding.rows != 1) return false;
    const Owner = struct { node: u32, context: Context };
    var actual: std.AutoHashMapUnmanaged(u32, Owner) = .empty;
    defer actual.deinit(allocator);
    var owners = semantic.scope_owner_map.iterator();
    while (owners.next()) |entry| {
        if (!wanted.contains(entry.value_ptr.*)) continue;
        const raw = entry.key_ptr.*;
        if (raw >= contexts.len) return false;
        const context = contexts[raw] orelse continue;
        switch (ast.nodes.items[raw].tag) {
            .function_declaration, .function_expression, .arrow_function_expression, .method_definition, .function => {},
            else => continue,
        }
        const owner = try actual.getOrPut(allocator, entry.value_ptr.*);
        if (owner.found_existing and owner.value_ptr.node != raw) return false;
        owner.value_ptr.* = .{ .node = raw, .context = context };
    }
    var entries = aliases.iterator();
    while (entries.next()) |entry| {
        const context = (actual.get(@backingInt(entry.value_ptr.*)) orelse return false).context;
        const slot = anchorless.getPtr(entry.key_ptr.*) orelse return false;
        if (slot.*) |previous| if (!std.meta.eql(previous, context)) return false;
        slot.* = context;
    }
    return true;
}

/// Path splits keep every source binding/reference identity, but can move
/// statement buckets. Native class-self and anonymous default-facade
/// declarations and native/IIFE entry roles use their exact producers instead of a leaf.
pub fn project(
    allocator: std.mem.Allocator,
    ast: *const ast_mod.Ast,
    root: ast_mod.NodeIndex,
    semantic: anytype,
) !?[]SemanticReference {
    const contexts = collect(allocator, ast, root) catch return null;
    defer allocator.free(contexts);
    const updated = try allocator.dupe(SemanticReference, semantic.references);
    var updated_transferred = false;
    defer if (!updated_transferred) allocator.free(updated);
    var entry_contexts = (try @import("implicit_arguments_statement_owner.zig").collect(
        allocator,
        ast,
        contexts,
        semantic.symbols.items,
        semantic.scopes,
        &semantic.scope_owner_map,
        semantic.references,
    )) orelse return null;
    defer entry_contexts.deinit(allocator);
    var anchorless_contexts: std.AutoHashMapUnmanaged(u32, ?Context) = .empty;
    defer anchorless_contexts.deinit(allocator);
    for (updated) |reference| {
        if (reference.flags.declare and reference.declaration_node_index.isNone())
            try anchorless_contexts.put(allocator, @backingInt(reference.symbol_id), null);
    }
    if (anchorless_contexts.count() != 0) {
        var facade_owners: std.AutoHashMapUnmanaged(u32, ast_mod.NodeIndex) = .empty;
        defer facade_owners.deinit(allocator);
        for (ast.nodes.items, 0..) |node, raw| {
            if (node.tag != .export_default_declaration) continue;
            const context = contexts[raw] orelse continue;
            const sid = (try @import("default_facade_identity.zig").symbolAt(ast, @fromBackingInt(@as(u32, @intCast(raw))), semantic.symbol_ids, semantic.symbols.items)) orelse continue;
            const slot = anchorless_contexts.getPtr(sid) orelse continue;
            const owner = try facade_owners.getOrPut(allocator, sid);
            const owner_node: ast_mod.NodeIndex = @fromBackingInt(@as(u32, @intCast(raw)));
            if (owner.found_existing and owner.value_ptr.* != owner_node) return null;
            owner.value_ptr.* = owner_node;
            if (slot.*) |previous| if (!std.meta.eql(previous, context)) return null;
            slot.* = context;
        }
        var class_scope_contexts: std.AutoHashMapUnmanaged(u32, Context) = .empty;
        defer class_scope_contexts.deinit(allocator);
        var owners = semantic.scope_owner_map.iterator();
        while (owners.next()) |entry| {
            const raw = entry.key_ptr.*;
            if (raw >= contexts.len) return null;
            const context = contexts[raw] orelse continue;
            const tag = ast.nodes.items[raw].tag;
            if (tag != .class_declaration and tag != .class_expression) continue;
            const slot = try class_scope_contexts.getOrPut(allocator, entry.value_ptr.*);
            if (slot.found_existing and !std.meta.eql(slot.value_ptr.*, context)) return null;
            slot.value_ptr.* = context;
        }
        var classes = semantic.class_self_symbol_map.valueIterator();
        while (classes.next()) |sid| {
            const slot = anchorless_contexts.getPtr(sid.*) orelse continue;
            if (sid.* >= semantic.symbols.items.len) return null;
            const symbol = semantic.symbols.items[sid.*];
            if (symbol.kind != .class_decl or symbol.scope_id.isNone() or
                symbol.scope_id.toIndex() >= semantic.scopes.len) return null;
            if (semantic.scopes[symbol.scope_id.toIndex()].kind != .class_body) return null;
            // The class-self table retains the initial source role; the actual
            // current class node owns that same exact ScopeId after AST copies.
            slot.* = class_scope_contexts.get(@backingInt(symbol.scope_id)) orelse return null;
        }
        // A class expression can lose its source-side class_self_symbol_map
        // key when lowering relocates that entry to the generated wrapper
        // binding. The original inner class declaration row remains
        // anchorless, but its exact class-body ScopeId still has one live AST
        // owner. Project that row by ScopeId even when the sidecar no longer
        // names the original class node.
        var anchorless = anchorless_contexts.iterator();
        while (anchorless.next()) |entry| {
            const slot = entry.value_ptr;
            if (slot.* != null) continue;
            const sid = entry.key_ptr.*;
            if (sid >= semantic.symbols.items.len) continue;
            const symbol = semantic.symbols.items[sid];
            if (symbol.kind != .class_decl or symbol.scope_id.isNone() or
                symbol.scope_id.toIndex() >= semantic.scopes.len or
                semantic.scopes[symbol.scope_id.toIndex()].kind != .class_body) continue;
            slot.* = class_scope_contexts.get(@backingInt(symbol.scope_id)) orelse return null;
        }
        var implicit = entry_contexts.iterator();
        while (implicit.next()) |entry| {
            const slot = anchorless_contexts.getPtr(entry.key_ptr.*) orelse return null;
            if (slot.*) |previous| if (!std.meta.eql(previous, entry.value_ptr.*)) return null;
            slot.* = entry.value_ptr.*;
        }
    }
    if (anchorless_contexts.count() != 0 and !try projectNativeAnnexBEntries(allocator, ast, contexts, semantic, &anchorless_contexts)) return null;
    for (updated) |*reference| {
        const node = if (reference.flags.declare) reference.declaration_node_index else reference.node_index;
        const context = if (node.isNone() and reference.flags.declare)
            (anchorless_contexts.get(@backingInt(reference.symbol_id)) orelse return null) orelse return null
        else if (!node.isNone() and @backingInt(node) < contexts.len)
            contexts[@backingInt(node)] orelse return null
        else
            return null;
        if (node.isNone() and reference.flags.declare and semantic.symbols.items[@backingInt(reference.symbol_id)].decl_flags.is_default_export and
            reference.scope_id.toIndex() != 0) return null;
        reference.stmt_idx = context.stmt_idx;
        reference.scope_stmt_idx = context.scope_stmt_idx;
    }
    updated_transferred = true;
    return updated;
}

test "anchorless class self follows the exact current class body owner" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var scanner = try @import("../lexer/scanner.zig").Scanner.init(allocator, "class Named {}");
    var parser = @import("../parser/parser.zig").Parser.init(allocator, &scanner);
    parser.configureFromExtension(".mjs");
    const root = try parser.parse();
    try std.testing.expectEqual(@as(usize, 0), parser.errors.items.len);
    var analyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer.init(allocator, &parser.ast);
    analyzer.is_module = true;
    analyzer.enable_exact_declaration_anchors = true;
    try analyzer.analyze();
    try std.testing.expectEqual(@as(usize, 0), analyzer.errors.items.len);

    var source_class: ?u32 = null;
    for (parser.ast.nodes.items, 0..) |node, raw| {
        if (node.tag == .class_declaration) {
            source_class = @intCast(raw);
            break;
        }
    }
    const source_class_raw = source_class orelse return error.MissingSourceClass;
    const source_class_node = parser.ast.nodes.items[source_class_raw];
    const source_name_raw = parser.ast.extra_data.items[source_class_node.data.extra + ast_mod.ClassExtra.name];
    const outer_sid = analyzer.symbol_ids.items[source_name_raw] orelse return error.MissingOuterClassSymbol;
    const inner_sid = analyzer.class_self_symbol_map.get(source_class_raw) orelse return error.MissingInnerClassSymbol;
    try std.testing.expect(outer_sid != inner_sid);

    const source_name_node = parser.ast.nodes.items[source_name_raw];
    const output_name = try parser.ast.addLeafNode(
        .binding_identifier,
        source_name_node.span,
        .{ .string_ref = source_name_node.data.string_ref },
    );
    var class_extra = try allocator.dupe(u32, parser.ast.extra_data.items[source_class_node.data.extra..][0..8]);
    class_extra[ast_mod.ClassExtra.name] = @backingInt(output_name);
    const class_extra_start = try parser.ast.addExtras(class_extra);
    const output_class = try parser.ast.addExtraNode(.class_declaration, source_class_node.span, class_extra_start);
    const output_class_raw = @backingInt(output_class);
    const source_root_span = parser.ast.getNode(root).span;
    const output_body = try parser.ast.addNodeList(&.{output_class});
    const output_root = try parser.ast.addListNode(.program, source_root_span, output_body);
    parser.ast.transformed_root = output_root;

    var symbol_ids = try allocator.alloc(?u32, parser.ast.nodes.items.len);
    @memset(symbol_ids, null);
    @memcpy(symbol_ids[0..analyzer.symbol_ids.items.len], analyzer.symbol_ids.items);
    symbol_ids[@backingInt(output_name)] = outer_sid;
    const references = try allocator.dupe(@TypeOf(analyzer.references.items[0]), analyzer.references.items);
    var reanchored_outer = false;
    for (references) |*reference| {
        if (reference.flags.declare and @backingInt(reference.symbol_id) == outer_sid) {
            reference.declaration_node_index = output_name;
            reanchored_outer = true;
        }
    }
    try std.testing.expect(reanchored_outer);

    const class_scope = analyzer.scope_owner_map.get(source_class_raw) orelse return error.MissingClassScopeOwner;
    var scope_owner_map: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    try scope_owner_map.put(allocator, output_class_raw, class_scope);
    var semantic = .{
        .symbols = analyzer.symbols,
        .scopes = analyzer.scopes.items,
        .scope_owner_map = scope_owner_map,
        .class_self_symbol_map = @TypeOf(analyzer.class_self_symbol_map).empty,
        .symbol_ids = symbol_ids,
        .references = references,
    };

    const projected = (try project(std.testing.allocator, &parser.ast, output_root, &semantic)) orelse return error.ClassSelfProjectionRejected;
    defer std.testing.allocator.free(projected);
    try std.testing.expectEqual(references.len, projected.len);
    var found_inner_declaration = false;
    for (projected) |reference| {
        if (!reference.flags.declare or @backingInt(reference.symbol_id) != inner_sid) continue;
        found_inner_declaration = true;
        try std.testing.expectEqual(@as(u32, 0), reference.stmt_idx);
        try std.testing.expectEqual(@as(u32, 0), reference.scope_stmt_idx);
    }
    try std.testing.expect(found_inner_declaration);

    var allocation_failures: usize = 0;
    var completed_without_failure = false;
    for (0..256) |fail_index| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        const candidate = project(failing.allocator(), &parser.ast, output_root, &semantic) catch |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            allocation_failures += 1;
            continue;
        };
        if (candidate) |references_out| {
            failing.allocator().free(references_out);
            completed_without_failure = true;
            break;
        }
        allocation_failures += 1;
    }
    try std.testing.expect(allocation_failures > 0);
    try std.testing.expect(completed_without_failure);

    // A missing output class-scope owner must still fail closed.
    semantic.scope_owner_map = .empty;
    try std.testing.expect((try project(std.testing.allocator, &parser.ast, output_root, &semantic)) == null);
}

/// Statement metadata may change; SymbolId/ScopeId and source read identities do not.
pub fn refresh(module: *@import("module.zig").Module, shaker: ?*@import("tree_shaker.zig").TreeShaker, newly_live: []const NodeIndex) !void {
    const a = module.parse_arena.?.allocator();
    const ast = &module.ast.?;
    const sem = &module.semantic.?;
    const rebuilt = try @import("stmt_info.zig").buildFromSemantic(a, ast, sem.symbols.items, sem.scopes, sem.symbol_ids, sem.references, &sem.unresolved_references, false, false) orelse return;
    module.prebuilt_stmt_info = rebuilt;
    const s = shaker orelse return;
    const index = module.index.toU32();
    if (index >= s.module_stmt_infos.len or index >= s.reachable_stmts.len) return error.InvalidGuardedStatementState;
    const old = s.module_stmt_infos[index] orelse return; // Preserve opaque wrapped-module policy.
    var alive: std.AutoHashMapUnmanaged(u32, void) = .empty;
    if (s.reachable_stmts[index]) |reachable| {
        for (old.stmts, 0..) |statement, i| if (i < reachable.capacity() and reachable.isSet(i)) try alive.put(a, statement.node_idx, {});
    }
    for (newly_live) |statement| try alive.put(a, @backingInt(statement), {});
    var replacement = try std.DynamicBitSet.initEmpty(s.allocator, rebuilt.stmts.len);
    errdefer replacement.deinit();
    for (rebuilt.stmts, 0..) |statement, i| if (alive.contains(statement.node_idx)) replacement.set(i);
    if (s.prebuilt_mask) |*mask| {
        if (!mask.isSet(index)) {
            var owned = old;
            owned.deinit();
        }
        mask.set(index);
    } else return error.InvalidGuardedStatementState;
    if (s.reachable_stmts[index]) |*previous| previous.deinit();
    s.reachable_stmts[index] = replacement;
    s.module_stmt_infos[index] = rebuilt;
    module.reachable_stmts = &s.reachable_stmts[index].?;
    module.symbol_to_stmt = rebuilt.symbol_to_stmt;
}

test "native Annex B alias entry projection requires exact declaration scope and unique owner" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source = "function run(flag){const values=[];for(let index=0;index<2;index++){function local(){let eval=value=>value+4;return eval(index);}values.push(local());}return values;}console.log(JSON.stringify([run(false),run(true)]));function sibling(){var local=9;return local}";
    var scanner = try @import("../lexer/scanner.zig").Scanner.init(a, source);
    var parser = @import("../parser/parser.zig").Parser.init(a, &scanner);
    parser.configureFromExtension(".cjs");
    const root = try parser.parse();
    var analyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer.init(a, &parser.ast);
    analyzer.enable_exact_declaration_anchors = true;
    try analyzer.analyze();
    var lexical: ?u32 = null;
    var variable: ?u32 = null;
    var foreign: ?u32 = null;
    for (analyzer.symbols.items, 0..) |symbol, id| {
        if (!symbol.annex_b_alias.variable.isNone()) {
            lexical = @intCast(id);
            variable = @backingInt(symbol.annex_b_alias.variable);
        } else if (symbol.kind == .variable_var and std.mem.eql(u8, parser.ast.getText(symbol.name), "local")) foreign = @intCast(id);
    }
    const local = lexical orelse return error.MissingNativeAnnexBRole;
    const alias = variable.?;
    const scope = analyzer.symbols.items[alias].scope_id;
    try std.testing.expect(scope != analyzer.symbols.items[local].scope_id);
    var alias_row: ?usize = null;
    for (analyzer.references.items, 0..) |reference, index| {
        if (reference.flags.declare and @backingInt(reference.symbol_id) == alias and reference.declaration_node_index.isNone()) alias_row = index;
    }
    const row = alias_row orelse return error.MissingNativeAnnexBEntry;
    const references = try a.dupe(SemanticReference, analyzer.references.items);
    var semantic = .{
        .symbols = analyzer.symbols,
        .scopes = analyzer.scopes.items,
        .scope_owner_map = analyzer.scope_owner_map,
        .class_self_symbol_map = analyzer.class_self_symbol_map,
        .symbol_ids = analyzer.symbol_ids.items,
        .references = references,
    };
    const projected = (try project(a, &parser.ast, root, &semantic)) orelse return error.NativeAnnexBEntryRejected;
    try std.testing.expectEqualDeep(references[row].scope_id, projected[row].scope_id);
    try std.testing.expectEqual(references[row].symbol_id, projected[row].symbol_id);
    try std.testing.expect(projected[row].declaration_node_index.isNone());
    var original_owner: ?u32 = null;
    var other_owner: ?u32 = null;
    var owners = analyzer.scope_owner_map.iterator();
    while (owners.next()) |entry| {
        if (parser.ast.nodes.items[entry.key_ptr.*].tag != .function_declaration) continue;
        if (entry.value_ptr.* == @backingInt(scope)) original_owner = entry.key_ptr.*;
        if (entry.value_ptr.* == @backingInt(analyzer.symbols.items[foreign.?].scope_id)) other_owner = entry.key_ptr.*;
    }
    const contexts = try collect(a, &parser.ast, root);
    try std.testing.expectEqualDeep(contexts[original_owner.?].?, Context{ .stmt_idx = projected[row].stmt_idx, .scope_stmt_idx = projected[row].scope_stmt_idx });
    var explicit_parameter_row: ?usize = null;
    for (references, 0..) |reference, index| {
        const symbol = semantic.symbols.items[@backingInt(reference.symbol_id)];
        if (reference.flags.declare and !reference.declaration_node_index.isNone() and symbol.kind == .parameter and symbol.synthetic_kind == null) {
            explicit_parameter_row = index;
            break;
        }
    }
    const parameter_row = explicit_parameter_row orelse return error.MissingActualFormal;
    const original_parameter = references[parameter_row];
    references[parameter_row].declaration_node_index = .none;
    try std.testing.expect((try project(a, &parser.ast, root, &semantic)) == null);
    references[parameter_row] = original_parameter;
    try std.testing.expect(foreign.? != alias);
    try std.testing.expect(analyzer.symbols.items[foreign.?].scope_id != scope);
    const old_role = semantic.symbols.items[local].annex_b_alias;
    semantic.symbols.items[local].annex_b_alias.variable = @fromBackingInt(foreign.?);
    try std.testing.expect((try project(a, &parser.ast, root, &semantic)) == null);
    semantic.symbols.items[local].annex_b_alias = old_role;
    references[row].scope_id = semantic.symbols.items[local].scope_id;
    try std.testing.expect((try project(a, &parser.ast, root, &semantic)) == null);
    references[row] = analyzer.references.items[row];
    const old_other_scope = semantic.scope_owner_map.get(other_owner.?).?;
    try semantic.scope_owner_map.put(a, other_owner.?, @backingInt(scope));
    try std.testing.expect((try project(a, &parser.ast, root, &semantic)) == null);
    try semantic.scope_owner_map.put(a, other_owner.?, old_other_scope);
    try std.testing.expect((try project(a, &parser.ast, root, &semantic)) != null);
}

test "native Annex B shadow eval CJS full minify preserves original runtime" {
    const helpers = @import("test_helpers.zig");
    const compat = @import("../transformer/compat.zig");
    const source = "function run(flag){const values=[];for(let index=0;index<2;index++){function local(){let eval=value=>value+4;return eval(index);}values.push(local());}return values;}\nconsole.log(JSON.stringify([run(false),run(true)]));";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const native = try std.process.run(a, std.testing.io, .{ .argv = &.{ "node", "-e", source } });
    try std.testing.expect(native.term == .exited and native.term.exited == 0);
    try std.testing.expectEqualStrings("[[4,5],[4,5]]\n", native.stdout);
    for ([_]compat.UnsupportedFeatures{ compat.fromESTarget(.es5), compat.unsupportedFeatures(&.{.{ .engine = .chrome, .major = 49, .minor = 0 }}) }) |unsupported| {
        for ([_]bool{ false, true }) |minify| {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            try helpers.writeFile(tmp.dir, "input.cjs", source);
            const entry = try helpers.absPath(&tmp, "input.cjs");
            defer std.testing.allocator.free(entry);
            var bundler = @import("bundler.zig").Bundler.init(std.testing.allocator, .{
                .entry_points = &.{entry},
                .format = .cjs,
                .platform = .node,
                .unsupported = unsupported,
                .minify_identifiers = minify,
                .minify_syntax = minify,
                .minify_whitespace = minify,
            });
            defer bundler.deinit();
            const result = try bundler.bundle(std.testing.io);
            defer result.deinit(std.testing.allocator);
            try std.testing.expect(!result.hasErrors());
            try helpers.writeFile(tmp.dir, "output.cjs", result.output);
            const output = try helpers.absPath(&tmp, "output.cjs");
            defer std.testing.allocator.free(output);
            const actual = try std.process.run(a, std.testing.io, .{ .argv = &.{ "node", output } });
            try std.testing.expect(actual.term == .exited and actual.term.exited == 0);
            try std.testing.expectEqualStrings(native.stdout, actual.stdout);
            try std.testing.expectEqualStrings(native.stderr, actual.stderr);
        }
    }
}
