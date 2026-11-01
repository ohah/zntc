//! Exact syntax handoff from `export =` lowering to a real CJS callback.
const std = @import("std");
const ast_mod = @import("../parser/ast.zig");
const ScopeId = @import("../semantic/scope.zig").ScopeId;
const NodeIndex = ast_mod.NodeIndex;

pub const ModuleReference = struct {
    source_buffer: []const u8,
    source: NodeIndex,
    source_expression: NodeIndex,
    expression: NodeIndex,
    statement: NodeIndex,
    assignment: NodeIndex,
    member: NodeIndex,
    property: NodeIndex,
    reference: NodeIndex,
    scope: ScopeId,

    pub fn validates(self: ModuleReference, ast: *const ast_mod.Ast) bool {
        if (self.source_buffer.ptr != ast.source.ptr or self.source_buffer.len != ast.source.len or self.scope.isNone()) return false;
        const boundary = ast.transform_boundary orelse return false;
        if (self.source.isNone() or @backingInt(self.source) >= boundary) return false;
        for ([_]NodeIndex{ self.source, self.source_expression, self.expression, self.statement, self.assignment, self.member, self.property, self.reference }) |index| {
            if (index.isNone() or @backingInt(index) >= ast.nodes.items.len) return false;
        }
        const source = ast.getNode(self.source);
        const statement = ast.getNode(self.statement);
        const assignment = ast.getNode(self.assignment);
        const member = ast.getNode(self.member);
        const reference = ast.getNode(self.reference);
        const property = ast.getNode(self.property);
        if (source.tag != .ts_export_assignment or source.data.unary.operand != self.source_expression or
            statement.tag != .expression_statement or statement.data.unary.operand != self.assignment or
            assignment.tag != .assignment_expression or assignment.data.binary.left != self.member or
            assignment.data.binary.right != self.expression or assignment.data.binary.flags != 0 or
            member.tag != .static_member_expression or !ast.hasExtra(member.data.extra, 2) or
            ast.readExtraNode(member.data.extra, 0) != self.reference or
            ast.readExtraNode(member.data.extra, 1) != self.property or ast.extra_data.items[member.data.extra + 2] != 0 or
            reference.tag != .identifier_reference or property.tag != .identifier_reference or
            !std.mem.eql(u8, ast.getText(reference.data.string_ref), "module") or
            !std.mem.eql(u8, ast.getText(property.data.string_ref), "exports") or
            !std.meta.eql(source.span, statement.span) or !std.meta.eql(source.span, assignment.span) or
            !std.meta.eql(source.span, member.span)) return false;
        const root = ast.transformed_root orelse return false;
        if (root.isNone() or @backingInt(root) >= ast.nodes.items.len) return false;
        const program = ast.getNode(root);
        if (program.tag != .program) return false;
        const list = program.data.list;
        if (list.start > ast.extra_data.items.len or list.len > ast.extra_data.items.len - list.start) return false;
        var occurrences: usize = 0;
        for (ast.extra_data.items[list.start .. list.start + list.len]) |raw| if (raw == @backingInt(self.statement)) {
            occurrences += 1;
        };
        return occurrences == 1;
    }
};
