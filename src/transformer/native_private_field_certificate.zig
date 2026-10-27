//! Completed preservation of native private scalar fields in legacy classes.
//! Private identity is structural (source key + class environment), never a SID.
const std = @import("std");
const ast_mod = @import("../parser/ast.zig");
const walk = @import("../parser/ast_walk.zig");
const module_mod = @import("../bundler/module.zig");
const symbols = @import("../semantic/symbol.zig");
const ScopeId = @import("../semantic/scope.zig").ScopeId;
const NodeIndex = ast_mod.NodeIndex;
const Options = @import("transformer.zig").TransformOptions;
const member_helpers = @import("transformer/class_member_helpers.zig");
const helpers = @import("es_helpers.zig");

pub const Member = struct { node: NodeIndex, key: NodeIndex, key_tag: ast_mod.Node.Tag, key_span: @import("../lexer/token.zig").Span, key_ref: ast_mod.StringRef, scope: ?ScopeId, flags: u32, field: bool };
pub const Class = struct { node: NodeIndex, body: NodeIndex, name: NodeIndex, symbol: u32, scope: ScopeId, outer: ScopeId, members: []const Member };
pub const Field = struct { node: NodeIndex, class_index: u32, key: NodeIndex, value: NodeIndex, flags: u32, key_span: @import("../lexer/token.zig").Span, key_ref: ast_mod.StringRef, literal: ast_mod.Node };
pub const Use = struct { node: NodeIndex, class_index: u32, key: NodeIndex, key_span: @import("../lexer/token.zig").Span, key_ref: ast_mod.StringRef, receiver: NodeIndex, receiver_tag: ast_mod.Node.Tag, receiver_sid: ?u32, receiver_storage: ScopeId, receiver_kind: symbols.SymbolKind, receiver_flags: symbols.DeclFlags, scope: ScopeId, flags: u32 };
/// The source graph/AST and all slices are borrowed from the build arena.
pub const Source = struct {
    ast: *const ast_mod.Ast,
    output_ast: ?*const ast_mod.Ast = null,
    owner: module_mod.SemanticOwnerToken,
    classes: []const Class,
    fields: []const Field,
    uses: []const Use,
    pub fn deinit(self: Source, a: std.mem.Allocator) void {
        for (self.classes) |class| a.free(class.members);
        a.free(self.classes);
        a.free(self.fields);
        a.free(self.uses);
    }
};
pub const Kind = enum { class_copy, field_copy, use_copy };
pub const Applied = struct { kind: Kind, source: NodeIndex, output: NodeIndex, scope: ScopeId };

fn slot(ast: *const ast_mod.Ast, node: ast_mod.Node, offset: u32) ?NodeIndex {
    if (!ast.hasExtra(node.data.extra, offset)) return null;
    return ast.readExtraNode(node.data.extra, offset);
}
fn listValid(ast: *const ast_mod.Ast, list: ast_mod.NodeList) bool {
    return list.start <= ast.extra_data.items.len and list.len <= ast.extra_data.items.len - list.start;
}
fn scalar(tag: ast_mod.Node.Tag) bool {
    return tag == .numeric_literal or tag == .string_literal or tag == .boolean_literal or tag == .null_literal;
}
fn sameLiteral(actual: ast_mod.Node, expected: ast_mod.Node) bool {
    if (actual.tag != expected.tag or !std.meta.eql(actual.span, expected.span)) return false;
    return switch (actual.tag) {
        .numeric_literal => std.mem.eql(u8, &actual.data.number_bytes, &expected.data.number_bytes),
        .string_literal => std.meta.eql(actual.data.string_ref, expected.data.string_ref),
        .boolean_literal, .null_literal => actual.data.none == expected.data.none,
        else => false,
    };
}
const Topology = struct {
    live: std.AutoHashMapUnmanaged(u32, void) = .empty,
    parents: std.AutoHashMapUnmanaged(u32, u32) = .empty,
    ambiguous: std.AutoHashMapUnmanaged(u32, void) = .empty,
    fn deinit(self: *Topology, a: std.mem.Allocator) void {
        self.live.deinit(a);
        self.parents.deinit(a);
        self.ambiguous.deinit(a);
    }
    fn build(a: std.mem.Allocator, ast: *const ast_mod.Ast, root: NodeIndex) !Topology {
        var result: Topology = .{};
        errdefer result.deinit(a);
        const nodes = try walk.collectReachableNodeIndicesFrom(a, ast, root);
        defer a.free(nodes);
        for (nodes) |raw| {
            try result.live.put(a, raw, {});
            var children = walk.children(ast, ast.nodes.items[raw]);
            while (children.next()) |child| {
                if (child.isNone()) continue;
                const entry = try result.parents.getOrPut(a, @backingInt(child));
                if (entry.found_existing) {
                    if (entry.value_ptr.* != raw) try result.ambiguous.put(a, @backingInt(child), {});
                } else entry.value_ptr.* = raw;
            }
        }
        return result;
    }
    fn classOf(self: *const Topology, ast: *const ast_mod.Ast, start: NodeIndex) ?NodeIndex {
        var raw = @backingInt(start);
        var hops: usize = 0;
        while (hops <= ast.nodes.items.len) : (hops += 1) {
            if (self.ambiguous.contains(raw)) return null;
            raw = self.parents.get(raw) orelse return null;
            const tag = ast.nodes.items[raw].tag;
            if (tag == .class_declaration or tag == .class_expression) return @fromBackingInt(raw);
        }
        return null;
    }
    fn scopeOf(self: *const Topology, ast: *const ast_mod.Ast, owners: *const std.AutoHashMapUnmanaged(u32, u32), start: NodeIndex) ?ScopeId {
        var raw = @backingInt(start);
        var hops: usize = 0;
        while (hops <= ast.nodes.items.len) : (hops += 1) {
            if (self.ambiguous.contains(raw)) return null;
            const parent = self.parents.get(raw) orelse return null;
            if (!@import("transformer/semantic_edit.zig").childSkipsOutputScope(ast, parent, raw)) {
                if (owners.get(parent)) |scope| return @fromBackingInt(scope);
            }
            raw = parent;
        }
        return null;
    }
};

pub fn sourcePlan(a: std.mem.Allocator, ast: *const ast_mod.Ast, sem: *const module_mod.ModuleSemanticData, options: Options) !?Source {
    if (!options.experimental_decorators or !options.strip_types or options.minify_syntax or options.unsupported.class or
        options.unsupported.privateLoweringPlan().fields or options.unsupportedGraphPrePassFeatureUsed(ast) or
        !ast.has_decorator or options.plugins.len != 0 or options.react_refresh or options.styled_components or options.emotion or
        sem.scopes.len == 0 or sem.scopes[0].blocksMangling()) return null;
    const root = ast.transformed_root orelse @as(NodeIndex, @fromBackingInt(@as(u32, @intCast(ast.nodes.items.len - 1))));
    if (ast.getNode(root).tag != .program) return null;
    var topo = try Topology.build(a, ast, root);
    defer topo.deinit(a);
    var classes: std.ArrayList(Class) = .empty;
    defer classes.deinit(a);
    var transferred = false;
    defer if (!transferred) {
        for (classes.items) |class| a.free(class.members);
    };
    var fields: std.ArrayList(Field) = .empty;
    defer fields.deinit(a);
    var uses: std.ArrayList(Use) = .empty;
    defer uses.deinit(a);
    var by_class: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer by_class.deinit(a);
    var opts = options;
    opts.use_define_for_class_fields = options.effectiveUseDefineForClassFields();
    var proof = .{ .allocator = a, .ast = ast, .options = opts };
    var it = topo.live.keyIterator();
    while (it.next()) |raw| {
        const node = ast.nodes.items[raw.*];
        if (node.tag == .with_statement or node.tag == .accessor_property or node.tag == .static_block) return null;
        if (node.tag != .class_declaration and node.tag != .class_expression) continue;
        const class: NodeIndex = @fromBackingInt(raw.*);
        if (node.tag != .class_declaration or topo.classOf(ast, class) != null) return null;
        const name = slot(ast, node, ast_mod.ClassExtra.name) orelse return null;
        const body = slot(ast, node, ast_mod.ClassExtra.body) orelse return null;
        if (name.isNone() or body.isNone() or !ast.readExtraNode(node.data.extra, ast_mod.ClassExtra.super).isNone() or ast.readExtra(node.data.extra, ast_mod.ClassExtra.deco_len) != 0 or
            ast.getNode(name).tag != .binding_identifier or ast.getNode(body).tag != .class_body or !listValid(ast, ast.getNode(body).data.list)) return null;
        if (!member_helpers.canKeepNativePrivateInitializers(&proof, body)) return null;
        const scope_raw = sem.scope_owner_map.get(raw.*) orelse return null;
        if (scope_raw >= sem.scopes.len or sem.scopes[scope_raw].kind != .class_body or !sem.scopes[scope_raw].is_strict) return null;
        const scope: ScopeId = @fromBackingInt(scope_raw);
        const outer = sem.scopes[scope_raw].parent;
        const sid = if (@backingInt(name) < sem.symbol_ids.len) sem.symbol_ids[@backingInt(name)] orelse return null else return null;
        if (sid >= sem.symbols.items.len or outer.isNone() or outer.toIndex() >= sem.scopes.len) return null;
        const symbol = sem.symbols.items[sid];
        if (symbol.kind != .class_decl or !symbol.decl_flags.is_class or symbol.scope_id != outer or symbol.synthetic_kind != null or symbol.synthetic_name.len != 0) return null;
        var declarations: usize = 0;
        for (sem.references) |row| if (row.declaration_node_index == name) {
            if (@backingInt(row.symbol_id) != sid or row.scope_id != outer or !row.node_index.isNone() or !std.meta.eql(row.flags, @as(symbols.ReferenceFlags, .{ .declare = true }))) return null;
            declarations += 1;
        };
        if (declarations != 1) return null;
        var members: std.ArrayList(Member) = .empty;
        defer members.deinit(a);
        const class_index: u32 = @intCast(classes.items.len);
        const members_list = ast.getNode(body).data.list;
        var class_fields: usize = 0;
        for (ast.extra_data.items[members_list.start .. members_list.start + members_list.len]) |member_raw| {
            const member = ast.nodes.items[member_raw];
            const member_node: NodeIndex = @fromBackingInt(member_raw);
            switch (member.tag) {
                .property_definition => {
                    const key = slot(ast, member, ast_mod.PropertyExtra.key) orelse return null;
                    const value = slot(ast, member, ast_mod.PropertyExtra.init) orelse return null;
                    const flags = ast.readExtra(member.data.extra, ast_mod.PropertyExtra.flags);
                    if (key.isNone() or value.isNone() or ast.getNode(key).tag != .private_identifier or
                        flags & ~@as(u32, ast_mod.PropertyFlags.is_static) != 0 or ast.readExtra(member.data.extra, ast_mod.PropertyExtra.deco_len) != 0 or !scalar(ast.getNode(value).tag)) return null;
                    if (@backingInt(key) < sem.symbol_ids.len and sem.symbol_ids[@backingInt(key)] != null) return null;
                    try fields.append(a, .{ .node = member_node, .class_index = class_index, .key = key, .value = value, .flags = flags, .key_span = ast.getNode(key).span, .key_ref = ast.getNode(key).data.string_ref, .literal = ast.getNode(value) });
                    try members.append(a, .{ .node = member_node, .key = key, .key_tag = ast.getNode(key).tag, .key_span = ast.getNode(key).span, .key_ref = ast.getNode(key).data.string_ref, .scope = null, .flags = flags, .field = true });
                    class_fields += 1;
                },
                .method_definition => {
                    const key = slot(ast, member, ast_mod.MethodExtra.key) orelse return null;
                    const flags = ast.readExtra(member.data.extra, ast_mod.MethodExtra.flags);
                    if (key.isNone() or (ast.getNode(key).tag != .identifier_reference and ast.getNode(key).tag != .string_literal) or helpers.isConstructorKey(&proof, key) or flags & ~@as(u32, ast_mod.MethodFlags.is_static) != 0) return null;
                    const method_scope = sem.scope_owner_map.get(member_raw) orelse return null;
                    if (method_scope >= sem.scopes.len or sem.scopes[method_scope].kind != .function or sem.scopes[method_scope].parent != scope) return null;
                    try members.append(a, .{ .node = member_node, .key = key, .key_tag = ast.getNode(key).tag, .key_span = ast.getNode(key).span, .key_ref = ast.getNode(key).data.string_ref, .scope = @fromBackingInt(method_scope), .flags = flags, .field = false });
                },
                else => return null,
            }
        }
        if (class_fields == 0) return null;
        const owned_members = try members.toOwnedSlice(a);
        classes.append(a, .{ .node = class, .body = body, .name = name, .symbol = sid, .scope = scope, .outer = outer, .members = owned_members }) catch |err| {
            a.free(owned_members);
            return err;
        };
        try by_class.put(a, raw.*, class_index);
    }
    if (fields.items.len == 0) return null;
    it = topo.live.keyIterator();
    while (it.next()) |raw| {
        const node = ast.nodes.items[raw.*];
        if (node.tag != .private_field_expression) continue;
        const source: NodeIndex = @fromBackingInt(raw.*);
        const class = topo.classOf(ast, source) orelse return null;
        const index = by_class.get(@backingInt(class)) orelse return null;
        const key = slot(ast, node, 1) orelse return null;
        const receiver = slot(ast, node, 0) orelse return null;
        const flags = ast.readExtra(node.data.extra, 2);
        if (key.isNone() or receiver.isNone() or ast.getNode(key).tag != .private_identifier or flags != 0) return null;
        if (@backingInt(key) < sem.symbol_ids.len and sem.symbol_ids[@backingInt(key)] != null) return null;
        const scope = topo.scopeOf(ast, &sem.scope_owner_map, source) orelse return null;
        const receiver_node = ast.getNode(receiver);
        const sid: ?u32 = if (@backingInt(receiver) < sem.symbol_ids.len) sem.symbol_ids[@backingInt(receiver)] else null;
        if (receiver_node.tag == .identifier_reference) {
            const id = sid orelse return null;
            if (id >= sem.symbols.items.len or sem.symbols.items[id].synthetic_kind != null or sem.symbols.items[id].synthetic_name.len != 0) return null;
        } else if (receiver_node.tag != .this_expression or sid != null) return null;
        try uses.append(a, .{ .node = source, .class_index = index, .key = key, .key_span = ast.getNode(key).span, .key_ref = ast.getNode(key).data.string_ref, .receiver = receiver, .receiver_tag = receiver_node.tag, .receiver_sid = sid, .receiver_storage = if (sid) |id| sem.symbols.items[id].scope_id else .none, .receiver_kind = if (sid) |id| sem.symbols.items[id].kind else .variable_var, .receiver_flags = if (sid) |id| sem.symbols.items[id].decl_flags else .{}, .scope = scope, .flags = flags });
    }
    if (uses.items.len == 0) return null;
    it = topo.live.keyIterator();
    while (it.next()) |raw| {
        if (ast.nodes.items[raw.*].tag != .private_identifier) continue;
        if (topo.ambiguous.contains(raw.*)) return null;
        const parent = topo.parents.get(raw.*) orelse return null;
        const node = ast.nodes.items[parent];
        if (node.tag == .property_definition) {
            if (slot(ast, node, ast_mod.PropertyExtra.key) != @as(NodeIndex, @fromBackingInt(raw.*))) return null;
        } else if (node.tag == .private_field_expression) {
            if (slot(ast, node, 1) != @as(NodeIndex, @fromBackingInt(raw.*))) return null;
        } else return null;
    }
    const owned_classes = try classes.toOwnedSlice(a);
    errdefer {
        for (owned_classes) |class| a.free(class.members);
        a.free(owned_classes);
    }
    const owned_fields = try fields.toOwnedSlice(a);
    errdefer a.free(owned_fields);
    const owned_uses = try uses.toOwnedSlice(a);
    transferred = true;
    return .{ .ast = ast, .owner = sem.owner_token, .classes = owned_classes, .fields = owned_fields, .uses = owned_uses };
}

fn registered(self: anytype, kind: Kind, source_node: NodeIndex) bool {
    const source = self.native_private_field_source orelse return false;
    switch (kind) {
        .class_copy => for (source.classes) |class| {
            if (class.node == source_node) return true;
        },
        .field_copy => for (source.fields) |field| {
            if (field.node == source_node) return true;
        },
        .use_copy => for (source.uses) |use| {
            if (use.node == source_node) return true;
        },
    }
    return false;
}
pub fn record(self: anytype, kind: Kind, source: NodeIndex, output: NodeIndex) !void {
    if (!registered(self, kind, source)) return;
    try self.native_private_field_applications.append(self.allocator, .{ .kind = kind, .source = source, .output = output, .scope = self.current_scope });
}
fn application(self: anytype, kind: Kind, source: NodeIndex) ?Applied {
    var found: ?Applied = null;
    for (self.native_private_field_applications.items) |value| if (value.kind == kind and value.source == source) {
        if (found != null) return null;
        found = value;
    };
    return found;
}
fn privateKey(ast: *const ast_mod.Ast, sem: *const module_mod.ModuleSemanticData, key: NodeIndex, span: @import("../lexer/token.zig").Span, ref: ast_mod.StringRef) bool {
    if (key.isNone() or @backingInt(key) >= ast.nodes.items.len or ast.getNode(key).tag != .private_identifier or
        !std.meta.eql(ast.getNode(key).span, span) or !std.meta.eql(ast.getNode(key).data.string_ref, ref) or
        (@backingInt(key) < sem.symbol_ids.len and sem.symbol_ids[@backingInt(key)] != null)) return false;
    for (sem.references) |row| if (row.node_index == key or row.declaration_node_index == key) return false;
    return true;
}

/// No writes: this certificate grants only a native-private source-veto demand.
pub fn complete(self: anytype, sem: *const module_mod.ModuleSemanticData, root: NodeIndex) !bool {
    const source = self.native_private_field_source orelse return false;
    if (source.ast != self.semantic_source_ast or source.output_ast != self.ast or source.owner == .unassigned or source.owner != sem.owner_token or
        source.fields.len == 0 or self.native_private_field_applications.items.len != source.classes.len + source.fields.len + source.uses.len or
        self.options.unsupported.privateLoweringPlan().fields) return false;
    if (root.isNone() or @backingInt(root) >= self.ast.nodes.items.len or self.ast.getNode(root).tag != .program) return false;
    var topo = try Topology.build(self.allocator, self.ast, root);
    defer topo.deinit(self.allocator);
    const ast = self.ast;
    var outputs: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer outputs.deinit(self.allocator);
    for (source.classes) |class| {
        if (class.node.isNone() or @backingInt(class.node) >= source.ast.nodes.items.len or source.ast.getNode(class.node).tag != .class_declaration or
            slot(source.ast, source.ast.getNode(class.node), ast_mod.ClassExtra.name) != class.name or
            slot(source.ast, source.ast.getNode(class.node), ast_mod.ClassExtra.body) != class.body or
            !source.ast.readExtraNode(source.ast.getNode(class.node).data.extra, ast_mod.ClassExtra.super).isNone()) return false;
        const source_members = source.ast.getNode(class.body).data.list;
        if (source.ast.getNode(class.body).tag != .class_body or !listValid(source.ast, source_members) or source_members.len != class.members.len) return false;
        for (class.members, 0..) |member, offset| if (source.ast.readExtraNode(source_members.start, @intCast(offset)) != member.node) return false;
        const applied = application(self, .class_copy, class.node) orelse return false;
        if (!topo.live.contains(@backingInt(applied.output)) or (try outputs.getOrPut(self.allocator, @backingInt(applied.output))).found_existing or applied.scope != class.scope or
            self.outputOwnedScope(applied.output) != class.scope or class.scope.toIndex() >= sem.scopes.len or sem.scopes[class.scope.toIndex()].kind != .class_body or !sem.scopes[class.scope.toIndex()].is_strict or sem.scopes[class.scope.toIndex()].parent != class.outer or topo.scopeOf(ast, &sem.scope_owner_map, applied.output) != class.outer) return false;
        const actual = ast.getNode(applied.output);
        if (actual.tag != .class_declaration or slot(ast, actual, ast_mod.ClassExtra.name) != class.name or
            !ast.readExtraNode(actual.data.extra, ast_mod.ClassExtra.super).isNone() or ast.readExtra(actual.data.extra, ast_mod.ClassExtra.deco_len) != 0 or
            @backingInt(class.name) >= sem.symbol_ids.len or sem.symbol_ids[@backingInt(class.name)] != class.symbol or class.symbol >= sem.symbols.items.len) return false;
        var declarations: usize = 0;
        for (sem.references) |row| if (row.declaration_node_index == class.name) {
            if (@backingInt(row.symbol_id) != class.symbol or row.scope_id != class.outer or !row.node_index.isNone() or
                !std.meta.eql(row.flags, @as(symbols.ReferenceFlags, .{ .declare = true }))) return false;
            declarations += 1;
        };
        if (declarations != 1) return false;
        const symbol = sem.symbols.items[class.symbol];
        if (symbol.kind != .class_decl or !symbol.decl_flags.is_class or symbol.scope_id != class.outer or symbol.synthetic_kind != null or symbol.synthetic_name.len != 0) return false;
        const body = slot(ast, actual, ast_mod.ClassExtra.body) orelse return false;
        if (body.isNone() or ast.getNode(body).tag != .class_body or !member_helpers.canKeepNativePrivateInitializers(self, body)) return false;
        const members = ast.getNode(body).data.list;
        if (!listValid(ast, members) or members.len != class.members.len) return false;
        for (class.members, 0..) |member, offset| {
            const actual_node = ast.readExtraNode(members.start, @intCast(offset));
            const node = ast.getNode(actual_node);
            const key = ast.getNode(member.key);
            if (key.tag != member.key_tag or !std.meta.eql(key.span, member.key_span) or !std.meta.eql(key.data.string_ref, member.key_ref)) return false;
            if (member.field) {
                const field_app = application(self, .field_copy, member.node) orelse return false;
                if (field_app.output != actual_node or field_app.scope != class.scope or node.tag != .property_definition or ast.readExtra(node.data.extra, ast_mod.PropertyExtra.flags) != member.flags) return false;
            } else {
                if (node.tag != .method_definition or slot(ast, node, ast_mod.MethodExtra.key) != member.key or
                    ast.readExtra(node.data.extra, ast_mod.MethodExtra.flags) != member.flags or self.outputOwnedScope(actual_node) != member.scope or
                    member.scope.?.toIndex() >= sem.scopes.len or sem.scopes[member.scope.?.toIndex()].kind != .function or !sem.scopes[member.scope.?.toIndex()].is_strict or sem.scopes[member.scope.?.toIndex()].parent != class.scope) return false;
            }
        }
    }
    for (source.fields) |field| {
        if (field.class_index >= source.classes.len) return false;
        if (field.node.isNone() or @backingInt(field.node) >= source.ast.nodes.items.len or source.ast.getNode(field.node).tag != .property_definition or
            slot(source.ast, source.ast.getNode(field.node), ast_mod.PropertyExtra.key) != field.key or slot(source.ast, source.ast.getNode(field.node), ast_mod.PropertyExtra.init) != field.value or
            source.ast.readExtra(source.ast.getNode(field.node).data.extra, ast_mod.PropertyExtra.flags) != field.flags) return false;
        const applied = application(self, .field_copy, field.node) orelse return false;
        const class_app = application(self, .class_copy, source.classes[field.class_index].node) orelse return false;
        if (!topo.live.contains(@backingInt(applied.output)) or (try outputs.getOrPut(self.allocator, @backingInt(applied.output))).found_existing or
            topo.classOf(ast, applied.output) != class_app.output or applied.scope != source.classes[field.class_index].scope) return false;
        const node = ast.getNode(applied.output);
        if (node.tag != .property_definition or slot(ast, node, ast_mod.PropertyExtra.key) != field.key or slot(ast, node, ast_mod.PropertyExtra.init) != field.value or
            ast.readExtra(node.data.extra, ast_mod.PropertyExtra.flags) != field.flags or ast.readExtra(node.data.extra, ast_mod.PropertyExtra.deco_len) != 0 or
            !privateKey(ast, sem, field.key, field.key_span, field.key_ref) or !sameLiteral(ast.getNode(field.value), field.literal)) return false;
    }
    for (source.uses) |use| {
        if (use.class_index >= source.classes.len) return false;
        if (use.node.isNone() or @backingInt(use.node) >= source.ast.nodes.items.len or source.ast.getNode(use.node).tag != .private_field_expression or
            slot(source.ast, source.ast.getNode(use.node), 0) != use.receiver or slot(source.ast, source.ast.getNode(use.node), 1) != use.key or
            source.ast.readExtra(source.ast.getNode(use.node).data.extra, 2) != use.flags) return false;
        const applied = application(self, .use_copy, use.node) orelse return false;
        const class_app = application(self, .class_copy, source.classes[use.class_index].node) orelse return false;
        if (!topo.live.contains(@backingInt(applied.output)) or (try outputs.getOrPut(self.allocator, @backingInt(applied.output))).found_existing or
            topo.classOf(ast, applied.output) != class_app.output or applied.scope != use.scope or topo.scopeOf(ast, &sem.scope_owner_map, applied.output) != use.scope) return false;
        const node = ast.getNode(applied.output);
        if (node.tag != .private_field_expression or slot(ast, node, 1) != use.key or ast.readExtra(node.data.extra, 2) != use.flags or !privateKey(ast, sem, use.key, use.key_span, use.key_ref)) return false;
        const receiver = slot(ast, node, 0) orelse return false;
        if (receiver.isNone() or ast.getNode(receiver).tag != use.receiver_tag) return false;
        const sid: ?u32 = if (@backingInt(receiver) < sem.symbol_ids.len) sem.symbol_ids[@backingInt(receiver)] else null;
        if (sid != use.receiver_sid) return false;
        if (use.receiver_sid) |id| {
            if (id >= sem.symbols.items.len or sem.symbols.items[id].scope_id != use.receiver_storage or sem.symbols.items[id].kind != use.receiver_kind or
                !std.meta.eql(sem.symbols.items[id].decl_flags, use.receiver_flags) or sem.symbols.items[id].synthetic_kind != null or sem.symbols.items[id].synthetic_name.len != 0) return false;
            var count: usize = 0;
            for (sem.references) |row| if (row.node_index == receiver) {
                if (@backingInt(row.symbol_id) != id or row.scope_id != use.scope or !std.meta.eql(row.flags, @as(symbols.ReferenceFlags, .{ .read = true }))) return false;
                count += 1;
            };
            if (count != 1) return false;
        }
    }
    var live_private: usize = 0;
    var it = topo.live.keyIterator();
    while (it.next()) |raw| {
        const tag = ast.nodes.items[raw.*].tag;
        if (tag == .private_identifier) {
            if (topo.ambiguous.contains(raw.*)) return false;
            const parent = topo.parents.get(raw.*) orelse return false;
            if (!outputs.contains(parent)) return false;
        }
        if (tag != .property_definition and tag != .private_field_expression) continue;
        if (!outputs.contains(raw.*)) return false;
        live_private += 1;
    }
    return live_private == source.fields.len + source.uses.len;
}
