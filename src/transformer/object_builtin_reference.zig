//! External Object reads minted only by the two object-lowering producers.
//! Recording is independent of graph retention/debug; it grants no retention.
const std = @import("std");
const ast = @import("../parser/ast.zig");
const NodeIndex = ast.NodeIndex;
const Scope = @import("../semantic/scope.zig").Scope;
const ScopeId = @import("../semantic/scope.zig").ScopeId;
const Transformer = @import("transformer.zig").Transformer;
const helpers = @import("es_helpers.zig");

pub const Error = Transformer.Error || error{InvalidNode};

pub fn productionFailure(err: Error) Transformer.Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidNode => std.debug.panic("invalid object builtin producer context", .{}),
    };
}

pub const Operation = enum { accessor_define_property, home_prototype };
pub const UseScope = union(enum) { output: ScopeId, deferred_until_reanalysis };
pub const AccessorOrigins = struct {
    source_ast: *const ast.Ast,
    output_ast: *const ast.Ast,
    source_node_count: u32,
    object: NodeIndex,
    pairs: std.AutoHashMapUnmanaged(NodeIndex, NodeIndex) = .empty,

    pub fn init(self: *const Transformer, object: NodeIndex) Error!AccessorOrigins {
        const result: AccessorOrigins = .{ .source_ast = self.semantic_source_ast orelse return error.InvalidNode, .output_ast = self.ast, .source_node_count = self.parser_node_count, .object = object };
        try result.validateDomain(self, object);
        return result;
    }
    pub fn deinit(self: *AccessorOrigins, allocator: std.mem.Allocator) void {
        self.pairs.deinit(allocator);
    }
    fn validateDomain(self: *const AccessorOrigins, transformer: *const Transformer, object: NodeIndex) Error!void {
        if (self.source_ast != transformer.semantic_source_ast or self.output_ast != transformer.ast or
            self.source_node_count != transformer.parser_node_count or self.object != object or
            object.isNone() or @backingInt(object) >= self.source_node_count or
            self.source_node_count > self.source_ast.nodes.items.len or self.source_ast.getNode(object).tag != .object_expression) return error.InvalidNode;
    }
    pub fn record(self: *AccessorOrigins, transformer: *Transformer, source_member: NodeIndex, output_member: NodeIndex) Error!void {
        try self.validateDomain(transformer, self.object);
        // Capture validates the member against the original object's exact list.
        _ = try captureAccessor(transformer, self.object, source_member);
        if (output_member.isNone() or @backingInt(output_member) >= transformer.ast.nodes.items.len or
            transformer.ast.getNode(output_member).tag != .method_definition or self.pairs.contains(output_member)) return error.InvalidNode;
        try self.pairs.put(transformer.allocator, output_member, source_member);
    }
    pub fn sourceFor(self: *const AccessorOrigins, transformer: *const Transformer, object: NodeIndex, output_member: NodeIndex) Error!NodeIndex {
        try self.validateDomain(transformer, object);
        const source_member = self.pairs.get(output_member) orelse return error.InvalidNode;
        _ = try captureAccessor(transformer, object, source_member);
        return source_member;
    }
};

pub const Context = struct {
    output_ast: *const ast.Ast,
    source_ast: *const ast.Ast,
    source_node_count: u32,
    source_scopes: []const Scope,
    object: NodeIndex,
    member: NodeIndex,
    output_member: NodeIndex,
    accessor_origins: ?*const AccessorOrigins,
    operation: Operation,
    source_owner_scope: ?ScopeId,
    use_scope: UseScope,
};

pub fn captureAccessor(self: *const Transformer, object: NodeIndex, member: NodeIndex) Error!Context {
    return capture(self, object, member, .accessor_define_property);
}
pub fn captureAccessorWithOrigins(self: *const Transformer, object: NodeIndex, output_member: NodeIndex, origins: *const AccessorOrigins) Error!Context {
    const source_member = try origins.sourceFor(self, object, output_member);
    var context = try captureAccessor(self, object, source_member);
    context.output_member = output_member;
    context.accessor_origins = origins;
    try validate(self, context);
    return context;
}
pub fn captureHome(self: *const Transformer, home: Transformer.ObjectSuperHomeIdentity) Error!Context {
    const active = self.current_super_home_object orelse return error.InvalidNode;
    if (active.producer_node != home.producer_node) return error.InvalidNode;
    return capture(self, home.producer_node, .none, .home_prototype);
}
fn capture(self: *const Transformer, object: NodeIndex, member: NodeIndex, operation: Operation) Error!Context {
    const context: Context = .{
        .output_ast = self.ast,
        .source_ast = self.semantic_source_ast orelse return error.InvalidNode,
        .source_node_count = self.parser_node_count,
        .source_scopes = self.scopes,
        .object = object,
        .member = member,
        .output_member = member,
        .accessor_origins = null,
        .operation = operation,
        .source_owner_scope = if (!member.isNone()) if (self.scope_owner_map.get(@backingInt(member))) |raw| @fromBackingInt(raw) else null else null,
        // The source analyzer is not the output editor. A fallback transform
        // has no final output scope yet; never substitute scope zero for it.
        .use_scope = if (self.semantic_editor != null and !self.current_scope.isNone()) .{ .output = self.current_scope } else .deferred_until_reanalysis,
    };
    try validate(self, context);
    return context;
}
pub fn validate(self: *const Transformer, context: Context) Error!void {
    if (context.output_ast != self.ast or context.source_scopes.ptr != self.scopes.ptr or context.source_scopes.len != self.scopes.len) return error.InvalidNode;
    if (self.semantic_source_ast != context.source_ast or context.source_node_count != self.parser_node_count or
        context.source_node_count > context.source_ast.nodes.items.len) return error.InvalidNode;
    if (context.object.isNone() or @backingInt(context.object) >= context.source_node_count) return error.InvalidNode;
    const object = context.source_ast.getNode(context.object);
    if (object.tag != .object_expression) return error.InvalidNode;
    switch (context.operation) {
        .accessor_define_property => {
            if (context.member.isNone() or @backingInt(context.member) >= context.source_node_count) return error.InvalidNode;
            const member = context.source_ast.getNode(context.member);
            if (member.tag != .method_definition) return error.InvalidNode;
            const flags = context.source_ast.extra_data.items[member.data.extra + ast.MethodExtra.flags];
            if (flags & (ast.MethodFlags.is_getter | ast.MethodFlags.is_setter) == 0) return error.InvalidNode;
            var members = context.source_ast.iterateExtraList(object.data.list);
            var found = false;
            while (members.next()) |node| if (node == context.member) {
                found = true;
            };
            if (!found) return error.InvalidNode;
            if (context.output_member.isNone() or @backingInt(context.output_member) >= self.ast.nodes.items.len or self.ast.getNode(context.output_member).tag != .method_definition) return error.InvalidNode;
            if (context.accessor_origins) |origins| {
                if (try origins.sourceFor(self, context.object, context.output_member) != context.member) return error.InvalidNode;
            } else if (context.output_member != context.member) return error.InvalidNode;
            const owner = self.scope_owner_map.get(@backingInt(context.member));
            if (owner) |raw| {
                if (raw >= self.scopes.len or context.source_owner_scope == null or context.source_owner_scope.? != @as(ScopeId, @fromBackingInt(raw))) return error.InvalidNode;
            } else if (context.source_owner_scope != null) return error.InvalidNode;
        },
        .home_prototype => {
            if (!context.member.isNone() or !context.output_member.isNone() or context.accessor_origins != null or context.source_owner_scope != null) return error.InvalidNode;
            const active = self.current_super_home_object orelse return error.InvalidNode;
            if (active.producer_node != context.object) return error.InvalidNode;
        },
    }
    switch (context.use_scope) {
        .deferred_until_reanalysis => if (self.semantic_editor != null and !self.current_scope.isNone()) return error.InvalidNode,
        .output => |scope| {
            const editor = self.semantic_editor orelse return error.InvalidNode;
            if (scope.isNone() or scope != self.current_scope or scope.toIndex() >= editor.scopes.items.len) return error.InvalidNode;
        },
    }
}
pub fn makeReference(self: *Transformer, context: Context) Error!NodeIndex {
    try validate(self, context);
    // Reserve registration first. An allocation failure must not return an
    // unmarked read that a fallback analyzer could bind to a source Object.
    try self.explicit_global_reference_nodes.ensureUnusedCapacity(self.allocator, 1);
    const first_fresh = self.ast.nodes.items.len;
    const reference = try helpers.makeGlobalRef(self, "Object");
    const raw = @backingInt(reference);
    if (raw < first_fresh or self.ast.getNode(reference).tag != .identifier_reference or
        (raw < self.symbol_ids.items.len and self.symbol_ids.items[raw] != null)) return error.InvalidNode;
    self.explicit_global_reference_nodes.putAssumeCapacity(raw, {});
    return reference;
}
