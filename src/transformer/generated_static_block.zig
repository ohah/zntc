//! Scope birth for generated static syntax that can remain native.
const ast = @import("../parser/ast.zig");
const ScopeId = @import("../semantic/scope.zig").ScopeId;
const Span = @import("../lexer/token.zig").Span;

pub const Block = struct { node: ast.NodeIndex, scope: ScopeId };

/// A removed/downleveled block keeps its existing intermediate body scope.
/// A retained native block owns a strict var environment, with its body as
/// the one canonical syntax alias. Both edges exist before callers bind refs.
pub fn create(self: anytype, parent: ScopeId, body: ast.NodeIndex, span: Span) !Block {
    const node = try self.ast.addNode(.{
        .tag = .static_block,
        .span = span,
        .data = .{ .unary = .{ .operand = body, .flags = 0 } },
    });
    if (!self.semantic_edit_enabled) return .{ .node = node, .scope = parent };
    const retained = !self.options.unsupported.class and !self.options.unsupported.class_static_block;
    const scope = try self.addGeneratedScope(parent, if (retained) node else body, if (retained) .class_static_block else .block);
    if (retained) {
        const environment = self.semantic_editor.?.scopes.items[scope.toIndex()];
        if (environment.kind != .class_static_block or !environment.kind.isVarScope() or !environment.is_strict)
            @panic("generated native static block has no strict var boundary");
        if (self.ast.getNode(body).tag != .block_statement or self.outputOwnedScope(body) != null)
            @panic("generated native static block lost its unowned canonical body");
        try self.semantic_editor.?.scope_owner_map.put(self.allocator, @backingInt(body), @backingInt(scope));
        try self.transformed_scope_owner_map.put(self.allocator, @backingInt(body), @backingInt(scope));
        try self.scope_owner_origins.put(self.allocator, @backingInt(body), @backingInt(body));
    }
    return .{ .node = node, .scope = scope };
}
