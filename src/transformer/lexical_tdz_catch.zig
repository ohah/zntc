//! Fresh source catch cells for a selected downlevel pattern.
//! Native simple catch parameters supply fresh mutable environments without
//! extracting the source body across a function/control-flow boundary.
const std = @import("std");
const ast = @import("../parser/ast.zig");
const NodeIndex = ast.NodeIndex;
const helpers = @import("es_helpers.zig");
const blocks = @import("loop_scope_producer.zig");

pub fn lower(self: anytype, source: NodeIndex, node: ast.Node) !NodeIndex {
    const source_scope = self.outputOwnedScope(source) orelse @panic("catch pattern has no source owner");
    if (source_scope != self.current_scope) @panic("catch pattern changed its source execution owner");
    const saved_scope = self.current_scope;
    defer self.current_scope = saved_scope;
    const pattern = node.data.binary.left;
    var reservations = try helpers.PrivateNameAllocator.init(self.allocator, self.ast);
    defer reservations.deinit();
    const temp_name = try reservations.makeUniqueName("__zntc_caught");
    const temp_span = try self.ast.addString(temp_name);
    const temp_binding = try helpers.makeExactSyntheticBindingFromSpan(self, temp_span);
    _ = (try self.declareSyntheticInScope(temp_binding, node.span, .catch_binding, source_scope)) orelse
        @panic("catch value parameter has no compiler-owned SymbolId");

    const outer_body = try blocks.createBlock(self, source_scope, node.span);
    var innermost = outer_body;
    var bindings = try @import("../parser/ast_walk.zig").bindingIdentifiers(self.allocator, self.ast, pattern, .{});
    defer bindings.deinit();
    while (try bindings.next()) |binding| {
        if (self.ast.getNode(binding).tag != .binding_identifier) continue;
        const sid = self.getSymbolIdAt(binding) orelse @panic("catch pattern leaf has no source SymbolId");
        const symbol = self.semantic_editor.?.symbols.items[sid];
        if (symbol.kind != .catch_binding or symbol.scope_id != source_scope)
            @panic("catch pattern leaf changed its source declaration owner");
        const binding_node = self.ast.getNode(binding);
        const name = if (self.tableRenameOf(binding)) |selected|
            try self.ast.addString(selected)
        else
            binding_node.data.string_ref;
        const output_binding = try self.makeUserBinding(name, .none);
        const clause = try self.ast.addNode(.{ .tag = .catch_clause, .span = node.span, .data = .{ .binary = .{ .left = output_binding, .right = .none, .flags = 0 } } });
        const scope = try self.addGeneratedCatchScope(innermost.scope, clause);
        try self.relocateOutputSymbolAs(sid, scope, output_binding);
        try self.propagateSymbolId(binding, output_binding);
        const catch_body = try blocks.createBlock(self, scope, node.span);
        self.ast.nodes.items[@backingInt(clause)].data.binary.right = catch_body.node;
        const try_body = try blocks.createBlock(self, innermost.scope, node.span);
        self.current_scope = try_body.scope;
        self.runtime_helpers.tdz = true;
        const marker = try helpers.makeRuntimeHelperRef(self, "__tdz");
        const initialize_cell = try self.ast.addNode(.{ .tag = .throw_statement, .span = binding_node.span, .data = .{ .unary = .{ .operand = marker, .flags = 0 } } });
        try blocks.fillBlock(self, try_body.node, &.{initialize_cell});
        const statement = try self.ast.addNode(.{ .tag = .try_statement, .span = node.span, .data = .{ .ternary = .{ .a = try_body.node, .b = clause, .c = .none } } });
        try blocks.fillBlock(self, innermost.node, &.{statement});
        innermost = catch_body;
    }

    // Pattern defaults live outside the source body block. Reparent those
    // actual lexical frontiers independently, preserving their own scopes.
    try self.reparentGeneratedBodyScopes(source_scope, innermost.scope, pattern);
    try self.reparentGeneratedBodyScopes(source_scope, innermost.scope, node.data.binary.right);
    self.current_scope = innermost.scope;
    const caught = try self.makeIdentifierRefWithSymbolAt(temp_span, node.span, temp_binding);
    try self.trackUserReadFromBinding(caught, temp_binding, innermost.scope);
    const initialize = try @import("es2015_destructuring.zig").ES2015Destructuring(@TypeOf(self.*)).lowerBindingPatternStatement(
        self,
        self.ast.getNode(pattern),
        caught,
        node.span,
        .{ .use_scope = innermost.scope, .source_scope = innermost.scope },
    );
    const initialize_statement = initialize.statement;
    const body = try self.visitNode(node.data.binary.right);
    try blocks.fillBlock(self, innermost.node, &.{ initialize_statement, body });
    const output = try self.ast.addNode(.{ .tag = .catch_clause, .span = node.span, .data = .{ .binary = .{ .left = temp_binding, .right = outer_body.node, .flags = 0 } } });
    try self.remapCopiedScopeOwner(source, output);
    return output;
}
