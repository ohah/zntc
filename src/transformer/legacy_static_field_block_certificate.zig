//! Narrow source evidence for a native legacy assignment field kept as a block.
const std = @import("std");
const ast = @import("../parser/ast.zig");
const walk = @import("../parser/ast_walk.zig");
const sem_mod = @import("../bundler/module.zig");
const symbol = @import("../semantic/symbol.zig");
const ScopeId = @import("../semantic/scope.zig").ScopeId;
const pub_mod = @import("class_initializer_publication.zig");
pub const Source = pub_mod.Source;

fn scalar(tag: ast.Node.Tag) bool {
    return switch (tag) {
        .numeric_literal, .string_literal, .boolean_literal, .null_literal => true,
        else => false,
    };
}

/// Selection grants no retention authority. Only this exact field's creator
/// can seal a placement; completion and late exact validation remain required.
pub fn sourcePlan(a: std.mem.Allocator, tree: *const ast.Ast, sem: *const sem_mod.ModuleSemanticData, options: @import("transformer.zig").TransformOptions) !?Source {
    if (!options.experimental_decorators or options.emit_decorator_metadata or !options.strip_types or
        options.effectiveUseDefineForClassFields() or options.unsupported.class or options.unsupported.class_static_block or
        options.unsupportedGraphPrePassFeatureUsed(tree) or
        options.minify_syntax or options.keep_names or options.plugins.len != 0 or options.react_refresh or options.styled_components or options.emotion or
        options.drop_console or options.drop_debugger or options.drop_labels.len != 0 or options.define.len != 0 or
        tree.has_jsx or tree.has_ts_namespace_or_enum or tree.has_ts_import_equals or tree.has_ts_export_equals) return null;
    for (sem.scopes) |scope| if (scope.blocksMangling()) return null;
    const reachable = try walk.collectReachableNodeIndices(a, tree);
    defer a.free(reachable);
    var class: ast.NodeIndex = .none;
    var classes: usize = 0;
    var fields: usize = 0;
    for (reachable) |raw| {
        const node = tree.nodes.items[raw];
        switch (node.tag) {
            .class_declaration => {
                class = @fromBackingInt(raw);
                classes += 1;
            },
            .class_expression, .private_identifier, .with_statement, .await_expression, .flow_enum_declaration, .flow_match_expression, .flow_component_wrapper => return null,
            .property_definition => fields += 1,
            else => {},
        }
    }
    if (classes != 1 or fields != 1) return null;
    const node = tree.getNode(class);
    if (!tree.readExtraNode(node.data.extra, ast.ClassExtra.super).isNone() or tree.readExtra(node.data.extra, ast.ClassExtra.deco_len) != 0) return null;
    const class_raw = sem.scope_owner_map.get(@backingInt(class)) orelse return null;
    if (class_raw >= sem.scopes.len or sem.scopes[class_raw].kind != .class_body or !sem.scopes[class_raw].is_strict) return null;
    const class_scope: ScopeId = @fromBackingInt(class_raw);
    const outer = sem.scopes[class_raw].parent;
    const binding = tree.readExtraNode(node.data.extra, ast.ClassExtra.name);
    if (outer.isNone() or outer.toIndex() >= sem.scopes.len or binding.isNone() or @backingInt(binding) >= sem.symbol_ids.len) return null;
    const class_id = sem.symbol_ids[@backingInt(binding)] orelse return null;
    if (class_id >= sem.symbols.items.len or sem.symbols.items[class_id].kind != .class_decl or sem.symbols.items[class_id].scope_id != outer) return null;
    var declarations: usize = 0;
    for (sem.references) |row| if (row.flags.declare and row.declaration_node_index == binding) {
        if (@backingInt(row.symbol_id) != class_id or row.scope_id != outer or !std.meta.eql(row.flags, symbol.ReferenceFlags{ .declare = true })) return null;
        declarations += 1;
    };
    if (declarations != 1) return null;
    const body = tree.readExtraNode(node.data.extra, ast.ClassExtra.body);
    if (body.isNone() or tree.getNode(body).tag != .class_body) return null;
    const members = tree.getNode(body).data.list;
    var field: ast.NodeIndex = .none;
    var field_index: u32 = 0;
    var decorated: usize = 0;
    var methods: std.ArrayList(pub_mod.SourceMethod) = .empty;
    defer methods.deinit(a);
    var blocks: std.ArrayList(pub_mod.SourceBlock) = .empty;
    defer blocks.deinit(a);
    for (tree.extra_data.items[members.start .. members.start + members.len], 0..) |raw, index| {
        const member = tree.nodes.items[raw];
        switch (member.tag) {
            .property_definition => {
                field = @fromBackingInt(raw);
                field_index = @intCast(index);
            },
            .static_block => {
                const scope_raw = sem.scope_owner_map.get(raw) orelse return null;
                const block_body = member.data.unary.operand;
                if (scope_raw >= sem.scopes.len or sem.scopes[scope_raw].kind != .class_static_block or sem.scopes[scope_raw].parent != class_scope or
                    !sem.scopes[scope_raw].is_strict or block_body.isNone() or tree.getNode(block_body).tag != .block_statement or sem.scope_owner_map.get(@backingInt(block_body)) != scope_raw) return null;
                try blocks.append(a, .{ .node = @fromBackingInt(raw), .scope = @fromBackingInt(scope_raw), .index = @intCast(index) });
            },
            .method_definition => {
                if (tree.readExtra(member.data.extra, ast.MethodExtra.flags) != 0 or tree.functionParamsList(member).len != 0) return null;
                const method_key = tree.readExtraNode(member.data.extra, ast.MethodExtra.key);
                if (method_key.isNone() or tree.getNode(method_key).tag != .identifier_reference) return null;
                const deco_len = tree.readExtra(member.data.extra, ast.MethodExtra.deco_len);
                if (deco_len == 0) continue;
                if (deco_len != 1 or std.mem.indexOfScalar(u8, tree.identifierNameText(tree.getNode(method_key)), '\\') != null) return null;
                const deco_node = tree.readExtraNode(tree.readExtra(member.data.extra, ast.MethodExtra.deco_start), 0);
                const deco = tree.getNode(deco_node);
                const expression = if (deco.tag == .decorator) deco.data.unary.operand else deco_node;
                if (expression.isNone() or tree.getNode(expression).tag != .identifier_reference or @backingInt(expression) >= sem.symbol_ids.len) return null;
                const deco_id = sem.symbol_ids[@backingInt(expression)] orelse return null;
                var deco_reference: ?symbol.Reference = null;
                for (sem.references) |row| if (row.node_index == expression) {
                    if (deco_reference != null or @backingInt(row.symbol_id) != deco_id or !std.meta.eql(row.flags, symbol.ReferenceFlags{ .read = true })) return null;
                    deco_reference = row;
                };
                const method_scope = sem.scope_owner_map.get(raw) orelse return null;
                if (method_scope >= sem.scopes.len or sem.scopes[method_scope].parent != class_scope) return null;
                try methods.append(a, .{ .node = @fromBackingInt(raw), .key = method_key, .index = @intCast(index), .scope = @fromBackingInt(method_scope), .decorator = deco_reference orelse return null });
                decorated += 1;
            },
            else => return null,
        }
    }
    if (field.isNone() or blocks.items.len == 0 or decorated == 0) return null;
    const property = tree.getNode(field);
    if (tree.readExtra(property.data.extra, ast.PropertyExtra.flags) != ast.PropertyFlags.is_static or tree.readExtra(property.data.extra, ast.PropertyExtra.deco_len) != 0) return null;
    const key = tree.readExtraNode(property.data.extra, ast.PropertyExtra.key);
    const init = tree.readExtraNode(property.data.extra, ast.PropertyExtra.init);
    if (key.isNone() or init.isNone() or tree.getNode(key).tag != .identifier_reference or tree.getNode(init).tag != .call_expression) return null;
    const call = tree.getNode(init);
    if (tree.readExtra(call.data.extra, 3) != 0) return null;
    const callee = tree.readExtraNode(call.data.extra, 0);
    if (callee.isNone() or tree.getNode(callee).tag != .static_member_expression or tree.readExtra(tree.getNode(callee).data.extra, 2) != 0) return null;
    const object = tree.readExtraNode(tree.getNode(callee).data.extra, 0);
    if (object.isNone() or tree.getNode(object).tag != .identifier_reference or @backingInt(object) >= sem.symbol_ids.len) return null;
    const id = sem.symbol_ids[@backingInt(object)] orelse return null;
    if (id >= sem.symbols.items.len or sem.symbols.items[id].kind != .variable_const or sem.symbols.items[id].scope_id == class_scope or sem.symbols.items[id].synthetic_kind != null) return null;
    const storage = sem.symbols.items[id].scope_id;
    var scope = class_scope;
    var hops: usize = 0;
    while (scope != storage) : (hops += 1) {
        if (scope.isNone() or scope.toIndex() >= sem.scopes.len or hops >= sem.scopes.len) return null;
        scope = sem.scopes[scope.toIndex()].parent;
    }
    var read: ?symbol.Reference = null;
    for (sem.references) |row| if (row.node_index == object) {
        if (read != null or @backingInt(row.symbol_id) != id or row.scope_id != class_scope or !std.meta.eql(row.flags, symbol.ReferenceFlags{ .read = true })) return null;
        read = row;
    };
    if (read == null) return null;
    const args_start = tree.readExtra(call.data.extra, 1);
    const args_len = tree.readExtra(call.data.extra, 2);
    for (tree.extra_data.items[args_start .. args_start + args_len]) |raw| if (!scalar(tree.nodes.items[raw].tag)) return null;
    const owned_blocks = try blocks.toOwnedSlice(a);
    errdefer a.free(owned_blocks);
    const owned_methods = try methods.toOwnedSlice(a);
    return .{ .ast = tree, .owner = sem.owner_token, .class = class, .class_scope = class_scope, .outer_scope = outer, .binding = binding, .class_id = @fromBackingInt(@as(u32, @intCast(class_id))), .body = body, .members_len = members.len, .field = field, .field_index = field_index, .key = key, .init = init, .read = read.?, .storage = storage, .blocks = owned_blocks, .methods = owned_methods };
}

/// Completion consumes the actual finalized graph, including the helper's
/// import binding and provider specifier. The source selector alone grants no
/// permission to ignore a helper demand.
pub fn complete(self: anytype, semantic: *const sem_mod.ModuleSemanticData, root: ast.NodeIndex) !bool {
    const source = self.class_initializer_source orelse return false;
    if (source.owner == .unassigned or source.owner != semantic.owner_token or
        !self.options.emit_runtime_helper_imports or !self.runtime_helpers.legacy_decorator) return false;
    pub_mod.validateFinished(self, semantic, root) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return false,
    };
    const nodes = try walk.collectReachableNodeIndicesFrom(self.allocator, self.ast, root);
    defer self.allocator.free(nodes);
    var live: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer live.deinit(self.allocator);
    var parents: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer parents.deinit(self.allocator);
    for (nodes) |raw| {
        try live.put(self.allocator, raw, {});
        var children = walk.children(self.ast, self.ast.nodes.items[raw]);
        while (children.next()) |child| {
            if (child.isNone()) continue;
            const entry = try parents.getOrPut(self.allocator, @backingInt(child));
            if (entry.found_existing and entry.value_ptr.* != raw) return false;
            entry.value_ptr.* = raw;
        }
    }
    const allowed = [_][]const u8{ "__decorateClass", "__decorateParam", "__defProp2" };
    var seen = [3]bool{ false, false, false };
    var used_class = false;
    const used_methods = try self.allocator.alloc(bool, source.methods.len);
    defer self.allocator.free(used_methods);
    @memset(used_methods, false);

    var imports = self.runtime_helper_import_bindings.iterator();
    while (imports.next()) |binding| {
        const sid = binding.key_ptr.*;
        const local = binding.value_ptr.*;
        if (sid >= semantic.symbols.items.len or local >= semantic.symbol_ids.len or semantic.symbol_ids[local] != sid or !live.contains(local)) return false;
        const symbol_info = semantic.symbols.items[sid];
        if (symbol_info.kind != .import_binding or
            (symbol_info.synthetic_kind != null and symbol_info.synthetic_kind != .runtime_helper_import) or
            symbol_info.scope_id != self.programScope()) return false;
        var role: ?[]const u8 = null;
        var roles = self.runtime_helper_symbol_ids.iterator();
        while (roles.next()) |candidate| {
            if (@backingInt(candidate.value_ptr.*) != sid) continue;
            if (role != null) return false;
            role = candidate.key_ptr.*;
        }
        const base = role orelse return false;
        var selected: ?usize = null;
        for (allowed, 0..) |known, index| {
            if (std.mem.eql(u8, known, base)) selected = index;
        }
        const role_index = selected orelse return false;
        if (seen[role_index]) return false;
        seen[role_index] = true;
        const provider = (try @import("../runtime_helper_modules.zig").idForBase(self.allocator, base)) orelse return false;
        defer self.allocator.free(provider);
        var declarations: usize = 0;
        for (semantic.references) |row| {
            if (@backingInt(row.symbol_id) != sid) continue;
            if (row.flags.declare) {
                if (!row.node_index.isNone() or @backingInt(row.declaration_node_index) != local or row.scope_id != symbol_info.scope_id or
                    !std.meta.eql(row.flags, symbol.ReferenceFlags{ .declare = true })) return false;
                declarations += 1;
                continue;
            }
            // This family creates only ordinary method-decorator calls. The
            // two grouped sibling imports may be unused, never other calls.
            if (role_index != 0 or row.scope_id != source.outer_scope or !std.meta.eql(row.flags, symbol.ReferenceFlags{ .read = true }) or
                row.node_index.isNone() or !live.contains(@backingInt(row.node_index)) or
                @backingInt(row.node_index) >= semantic.symbol_ids.len or semantic.symbol_ids[@backingInt(row.node_index)] != sid) return false;
            const parent_raw = parents.get(@backingInt(row.node_index)) orelse return false;
            const call = self.ast.nodes.items[parent_raw];
            if (call.tag != .call_expression or self.ast.readExtraNode(call.data.extra, 0) != row.node_index or
                self.ast.readExtra(call.data.extra, 3) != 0 or self.ast.readExtra(call.data.extra, 2) != 4) return false;
            const args = self.ast.readExtra(call.data.extra, 1);
            const target = self.ast.nodes.items[self.ast.extra_data.items[args + 1]];
            if (target.tag != .static_member_expression) return false;
            const object = self.ast.readExtraNode(target.data.extra, 0);
            if (@backingInt(object) >= semantic.symbol_ids.len or semantic.symbol_ids[@backingInt(object)] != @as(u32, @intCast(@backingInt(source.class_id)))) return false;
            const prototype_key = self.ast.readExtraNode(target.data.extra, 1);
            if (self.ast.getNode(prototype_key).tag != .identifier_reference or
                !std.mem.eql(u8, self.ast.identifierNameText(self.ast.getNode(prototype_key)), "prototype")) return false;
            const output_key = self.ast.nodes.items[self.ast.extra_data.items[args + 2]];
            const kind = self.ast.nodes.items[self.ast.extra_data.items[args + 3]];
            const decorators = self.ast.nodes.items[self.ast.extra_data.items[args]];
            if (output_key.tag != .string_literal or kind.tag != .numeric_literal or @as(f64, @bitCast(kind.data.number_bytes)) != 1 or
                decorators.tag != .array_expression or decorators.data.list.len != 1) return false;
            const key_text = self.ast.getText(output_key.data.string_ref);
            if (key_text.len < 2) return false;
            const expression: ast.NodeIndex = @fromBackingInt(self.ast.extra_data.items[decorators.data.list.start]);
            var origin = @backingInt(expression);
            var hops: usize = 0;
            var selected_method: ?usize = null;
            while (selected_method == null) : (hops += 1) {
                if (hops >= self.ast.nodes.items.len) return false;
                // The source expression anchor chooses the already-known
                // method descriptor. A public key only validates that role.
                for (source.methods, 0..) |method, method_index| {
                    if (@backingInt(method.decorator.node_index) != origin) continue;
                    if (selected_method != null) return false;
                    selected_method = method_index;
                }
                if (selected_method == null) origin = self.reference_origin_map.get(origin) orelse return false;
            }
            const method_index = selected_method.?;
            if (used_methods[method_index]) return false;
            const method = source.methods[method_index];
            const source_key = source.ast.identifierNameText(source.ast.getNode(method.key));
            if (!std.mem.eql(u8, key_text[1 .. key_text.len - 1], source_key)) return false;
            if (@backingInt(expression) >= semantic.symbol_ids.len or semantic.symbol_ids[@backingInt(expression)] != @as(u32, @intCast(@backingInt(method.decorator.symbol_id)))) return false;
            var deco_rows: usize = 0;
            for (semantic.references) |deco_row| if (deco_row.node_index == expression) {
                if (deco_row.symbol_id != method.decorator.symbol_id or deco_row.scope_id != source.outer_scope or !std.meta.eql(deco_row.flags, method.decorator.flags)) return false;
                deco_rows += 1;
            };
            if (deco_rows != 1) return false;
            used_methods[method_index] = true;
            used_class = true;
        }
        if (declarations != 1) return false;
        var matches: usize = 0;
        for (nodes) |raw| {
            const node = self.ast.nodes.items[raw];
            if (node.tag != .import_declaration) continue;
            const extra = node.data.extra;
            const start = self.ast.readExtra(extra, 0);
            const len = self.ast.readExtra(extra, 1);
            for (0..len) |offset| {
                const specifier = self.ast.getNode(self.ast.readExtraNode(start, @intCast(offset)));
                if (specifier.tag != .import_specifier or @backingInt(specifier.data.binary.right) != local) continue;
                if (!std.mem.eql(u8, self.ast.identifierNameText(self.ast.getNode(specifier.data.binary.left)), base)) return false;
                const specifier_source = self.ast.getNode(self.ast.readExtraNode(extra, 2));
                if (specifier_source.tag != .string_literal) return false;
                const text = self.ast.getText(specifier_source.data.string_ref);
                if (text.len < 2 or !std.mem.eql(u8, text[1 .. text.len - 1], provider)) return false;
                matches += 1;
            }
        }
        if (matches != 1) return false;
    }
    for (seen) |found| if (!found) return false;
    for (used_methods) |found| if (!found) return false;
    return used_class;
}

const Fixture = struct {
    transformer: @import("transformer.zig").Transformer,
    semantic: sem_mod.ModuleSemanticData,
    root: ast.NodeIndex,

    fn init(a: std.mem.Allocator) !Fixture {
        const source = "// @flow\nconst events=[];function decorate(target:any,key?:string):void{events.push('decor:'+key);}class Box{static field:number=events.push('field');static{events.push('block');}@decorate method():void{}@decorate extra():void{}}console.log(Box.field,events.join(','));";
        var scanner = try @import("../lexer/scanner.zig").Scanner.init(a, source);
        var parser = @import("../parser/parser.zig").Parser.init(a, &scanner);
        parser.is_flow = true;
        _ = try parser.parse();
        try std.testing.expectEqual(@as(usize, 0), parser.errors.items.len);
        const tree = try a.create(ast.Ast);
        tree.* = parser.ast;
        var analyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer.init(a, tree);
        analyzer.is_flow = true;
        analyzer.enable_stmt_info = true;
        analyzer.enable_exact_declaration_anchors = true;
        analyzer.collect_unresolved_reference_nodes = true;
        try analyzer.analyze();
        var semantic: sem_mod.ModuleSemanticData = .{ .symbols = analyzer.symbols, .scopes = analyzer.scopes.items, .scope_maps = analyzer.scope_maps.items, .scope_owner_map = analyzer.scope_owner_map, .node_scope_provenance = analyzer.node_scope_provenance, .symbol_ids = analyzer.symbol_ids.items, .exported_names = analyzer.exported_names, .unresolved_references = analyzer.unresolved_references, .references = analyzer.references.items, .class_self_symbol_map = analyzer.class_self_symbol_map, .helper_scope_map = analyzer.helper_scope_map };
        const owner = semantic.captureOwnerToken();
        const options: @import("transformer.zig").TransformOptions = .{ .experimental_decorators = true, .emit_runtime_helper_imports = true };
        const selected = (try sourcePlan(a, tree, &semantic, options)) orelse return error.MissingSourcePlan;
        var t = try @import("transformer.zig").Transformer.init(a, tree, options);
        try t.initSymbolIds(semantic.symbol_ids);
        t.symbols = semantic.symbols.items;
        t.references = semantic.references;
        t.scopes = semantic.scopes;
        t.scope_maps = semantic.scope_maps;
        t.scope_owner_map = semantic.scope_owner_map;
        t.node_scope_provenance = semantic.node_scope_provenance;
        t.class_self_symbol_map = semantic.class_self_symbol_map;
        t.helper_scope_map = semantic.helper_scope_map;
        t.unresolved_references = &analyzer.unresolved_references;
        t.unresolved_reference_nodes = &analyzer.unresolved_reference_nodes;
        t.semantic_edit_enabled = true;
        try pub_mod.activate(&t, selected, owner);
        const root = try t.transform();
        semantic.applyEdit((try t.finishSemanticEdit()).?);
        return .{ .transformer = t, .semantic = semantic, .root = root };
    }
};

test "legacy static field block completed certificate rejects foreign identity and publication" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fixture = try Fixture.init(a);
    const t = &fixture.transformer;
    const semantic = &fixture.semantic;
    try std.testing.expect(try complete(t, semantic, fixture.root));
    const frame = t.class_initializer_frames.items[0];
    var row_index: ?usize = null;
    for (semantic.references, 0..) |row, index| if (row.node_index == frame.reference) {
        row_index = index;
    };
    const index = row_index.?;
    const original = semantic.references[index];
    const original_frames = try a.dupe(pub_mod.Frame, t.class_initializer_frames.items);
    const original_rows = try a.dupe(symbol.Reference, semantic.references);
    for (0..7) |attack| {
        switch (attack) {
            0 => @constCast(semantic.references)[index].symbol_id = frame.source.class_id,
            1 => @constCast(semantic.references)[index].scope_id = frame.source.class_scope,
            2 => @constCast(semantic.references)[index].flags.write = true,
            3 => @constCast(semantic.references)[index].scope_stmt_idx += 1,
            4 => t.class_initializer_frames.items[0].published = null,
            5 => t.class_initializer_frames.items[0].source.field_index += 1,
            6 => semantic.owner_token = .unassigned,
            else => unreachable,
        }
        const attacked_row = semantic.references[index];
        const attacked_frame = t.class_initializer_frames.items[0];
        try std.testing.expect(!try complete(t, semantic, fixture.root));
        try std.testing.expect(std.meta.eql(attacked_row, semantic.references[index]));
        try std.testing.expect(std.meta.eql(attacked_frame, t.class_initializer_frames.items[0]));
        @constCast(semantic.references)[index] = original;
        t.class_initializer_frames.items[0] = frame;
        semantic.owner_token = frame.source.owner;
        try std.testing.expect(try complete(t, semantic, fixture.root));
    }
    for (original_rows, semantic.references) |before, after| try std.testing.expect(std.meta.eql(before, after));
    for (original_frames, t.class_initializer_frames.items) |before, after| try std.testing.expect(std.meta.eql(before, after));
}

test "legacy static field block completed certificate rejects helper provider and valid sibling origins" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fixture = try Fixture.init(a);
    const t = &fixture.transformer;
    const semantic = &fixture.semantic;
    try std.testing.expect(try complete(t, semantic, fixture.root));
    const frame = t.class_initializer_frames.items[0];
    const helper = t.runtime_helper_symbol_ids.get("__decorateClass").?;
    const helper_local = t.runtime_helper_import_bindings.get(@backingInt(helper)).?;
    var helper_rows: std.ArrayList(usize) = .empty;
    for (semantic.references, 0..) |row, index| if (row.symbol_id == helper and row.flags.read) try helper_rows.append(a, index);
    try std.testing.expectEqual(@as(usize, 2), helper_rows.items.len);
    var parents: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    const live = try walk.collectReachableNodeIndicesFrom(a, t.ast, fixture.root);
    var provider: ast.NodeIndex = .none;
    for (live) |raw| {
        const node = t.ast.nodes.items[raw];
        var children = walk.children(t.ast, node);
        while (children.next()) |child| try parents.put(a, @backingInt(child), raw);
        if (node.tag != .import_declaration) continue;
        const start = t.ast.readExtra(node.data.extra, 0);
        const len = t.ast.readExtra(node.data.extra, 1);
        for (0..len) |offset| {
            const specifier = t.ast.getNode(t.ast.readExtraNode(start, @intCast(offset)));
            if (specifier.tag == .import_specifier and @backingInt(specifier.data.binary.right) == helper_local)
                provider = t.ast.readExtraNode(node.data.extra, 2);
        }
    }
    try std.testing.expect(!provider.isNone());
    const call = t.ast.nodes.items[parents.get(@backingInt(semantic.references[helper_rows.items[0]].node_index)).?];
    const other_call = t.ast.nodes.items[parents.get(@backingInt(semantic.references[helper_rows.items[1]].node_index)).?];
    const args = t.ast.readExtra(call.data.extra, 1);
    const other_args = t.ast.readExtra(other_call.data.extra, 1);
    const deco_array = t.ast.nodes.items[t.ast.extra_data.items[args]];
    const other_array = t.ast.nodes.items[t.ast.extra_data.items[other_args]];
    const target = t.ast.nodes.items[t.ast.extra_data.items[args + 1]];
    const target_node = t.ast.readExtraNode(target.data.extra, 0);
    const source_block = frame.source.blocks[0];
    const saved_provider = t.ast.getNode(provider);
    const saved_local_id = semantic.symbol_ids[helper_local];
    const saved_target_id = semantic.symbol_ids[@backingInt(target_node)];
    const saved_helper_row = semantic.references[helper_rows.items[0]];
    const saved_scope = semantic.scopes[frame.scope.toIndex()];
    const saved_source_scope = semantic.scopes[source_block.scope.toIndex()];
    const saved_decorator = t.ast.extra_data.items[deco_array.data.list.start];
    const saved_owner = semantic.scope_owner_map.get(@backingInt(frame.block)).?;
    const saved_read_rows = semantic.references;
    for (0..10) |attack| {
        switch (attack) {
            0 => @constCast(semantic.symbol_ids)[helper_local] = @intCast(@backingInt(frame.source.class_id)),
            1 => @constCast(semantic.references)[helper_rows.items[0]].flags.write = true,
            2 => @constCast(semantic.scopes)[frame.scope.toIndex()].kind = .block,
            3 => @constCast(semantic.scopes)[frame.scope.toIndex()].is_strict = false,
            4 => @constCast(semantic.scopes)[source_block.scope.toIndex()].parent = frame.source.outer_scope,
            5 => t.ast.nodes.items[@backingInt(provider)].data = .{ .string_ref = t.ast.nodes.items[t.ast.extra_data.items[t.ast.readExtra(t.ast.getNode(frame.value).data.extra, 1)]].data.string_ref },
            6 => @constCast(semantic.symbol_ids)[@backingInt(target_node)] = @intCast(@backingInt(frame.source.read.symbol_id)),
            // Both are live, same-SID decorator reads. Only their actual source
            // expression origin tells which method call owns each reference.
            7 => t.ast.extra_data.items[deco_array.data.list.start] = t.ast.extra_data.items[other_array.data.list.start],
            8 => try semantic.scope_owner_map.put(a, @backingInt(frame.block), @backingInt(frame.source.class_scope)),
            9 => {
                const duplicate = try a.alloc(symbol.Reference, saved_read_rows.len + 1);
                @memcpy(duplicate[0..saved_read_rows.len], saved_read_rows);
                var original_read: ?symbol.Reference = null;
                for (saved_read_rows) |row| if (row.node_index == frame.reference) {
                    original_read = row;
                };
                duplicate[saved_read_rows.len] = original_read.?;
                semantic.references = duplicate;
            },
            else => unreachable,
        }
        try std.testing.expect(!try complete(t, semantic, fixture.root));
        semantic.references = saved_read_rows;
        @constCast(semantic.symbol_ids)[helper_local] = saved_local_id;
        @constCast(semantic.symbol_ids)[@backingInt(target_node)] = saved_target_id;
        @constCast(semantic.references)[helper_rows.items[0]] = saved_helper_row;
        @constCast(semantic.scopes)[frame.scope.toIndex()] = saved_scope;
        @constCast(semantic.scopes)[source_block.scope.toIndex()] = saved_source_scope;
        t.ast.nodes.items[@backingInt(provider)] = saved_provider;
        t.ast.extra_data.items[deco_array.data.list.start] = saved_decorator;
        try semantic.scope_owner_map.put(a, @backingInt(frame.block), saved_owner);
        try std.testing.expect(try complete(t, semantic, fixture.root));
    }
}

test "legacy static field block selector preserves actual unrelated downlevel boundaries" {
    const field_source = "const events=[];function decorate(target,key){}class Box{static field=events.push('field');static{events.push('block');}@decorate method(){}}";
    const Shape = struct { prefix: []const u8, unsupported: @import("compat.zig").UnsupportedFeatures, selected: bool };
    const cases = [_]Shape{
        .{ .prefix = "", .unsupported = .{ .default_params = true }, .selected = true },
        .{ .prefix = "function separate(value=1){return value;}", .unsupported = .{ .default_params = true }, .selected = false },
        .{ .prefix = "function separate(value=1){return value;}", .unsupported = .{}, .selected = true },
        .{ .prefix = "function separate(){return ()=>this;}", .unsupported = .{ .arrow = true }, .selected = false },
        .{ .prefix = "const separate=()=>1;", .unsupported = .{ .arrow = true }, .selected = true },
        .{ .prefix = "const separate=()=>1;", .unsupported = .{}, .selected = true },
    };
    for (cases, 0..) |case, case_index| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const source = try std.fmt.allocPrint(a, "{s}{s}", .{ case.prefix, field_source });
        var scanner = try @import("../lexer/scanner.zig").Scanner.init(a, source);
        var parser = @import("../parser/parser.zig").Parser.init(a, &scanner);
        _ = try parser.parse();
        try std.testing.expectEqual(@as(usize, 0), parser.errors.items.len);
        var analyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer.init(a, &parser.ast);
        analyzer.enable_stmt_info = true;
        analyzer.enable_exact_declaration_anchors = true;
        try analyzer.analyze();
        const semantic: sem_mod.ModuleSemanticData = .{ .symbols = analyzer.symbols, .scopes = analyzer.scopes.items, .scope_maps = analyzer.scope_maps.items, .scope_owner_map = analyzer.scope_owner_map, .node_scope_provenance = analyzer.node_scope_provenance, .symbol_ids = analyzer.symbol_ids.items, .exported_names = analyzer.exported_names, .unresolved_references = analyzer.unresolved_references, .references = analyzer.references.items, .class_self_symbol_map = analyzer.class_self_symbol_map, .helper_scope_map = analyzer.helper_scope_map };
        const plan = try sourcePlan(a, &parser.ast, &semantic, .{ .experimental_decorators = true, .unsupported = case.unsupported });
        if ((plan != null) != case.selected) std.debug.print("static selector unrelated syntax case={d}\n", .{case_index});
        try std.testing.expectEqual(case.selected, plan != null);
    }
}
