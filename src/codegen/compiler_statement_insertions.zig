//! Typed statement holes in a separately parsed compiler-owned output program.
//! User statements are emitted in their own AST/name domain before insertion.
const std = @import("std");
const Ast = @import("../parser/ast.zig").Ast;
const Node = @import("../parser/ast.zig").Node;
const NodeIndex = @import("../parser/ast.zig").NodeIndex;
const Owner = @import("../bundler/codegen_output_domain.zig").Owner;
pub const Error = error{InvalidCompilerStatementInsertion};

pub const Entry = struct {
    owner: Owner,
    statement: NodeIndex,
    expression: NodeIndex,
    statement_snapshot: Node,
    expression_snapshot: Node,
    bytes: []const u8,
};

pub const Set = struct {
    owner: Owner,
    domain: *const Ast,
    entries: []const Entry,

    pub fn validate(self: *const Set, domain: *const Ast, owner: Owner) Error!void {
        if (owner == .unassigned or self.owner != owner or self.domain != domain)
            return error.InvalidCompilerStatementInsertion;
        for (self.entries, 0..) |entry, i| {
            if (entry.owner != owner or entry.statement.isNone() or entry.expression.isNone() or
                @backingInt(entry.statement) >= domain.nodes.items.len or
                @backingInt(entry.expression) >= domain.nodes.items.len)
                return error.InvalidCompilerStatementInsertion;
            const statement = domain.getNode(entry.statement);
            const expression = domain.getNode(entry.expression);
            if (statement.tag != .expression_statement or statement.data.unary.operand != entry.expression or
                expression.tag != .string_literal or entry.statement_snapshot.tag != statement.tag or
                entry.expression_snapshot.tag != expression.tag or !std.meta.eql(statement.span, entry.statement_snapshot.span) or
                !std.meta.eql(expression.span, entry.expression_snapshot.span) or
                entry.statement_snapshot.data.unary.operand != entry.expression or
                !std.meta.eql(expression.data.string_ref, entry.expression_snapshot.data.string_ref)) return error.InvalidCompilerStatementInsertion;
            for (self.entries[0..i]) |prior| if (prior.statement == entry.statement)
                return error.InvalidCompilerStatementInsertion;
        }
    }

    pub fn get(self: *const Set, domain: *const Ast, statement: NodeIndex) Error!?[]const u8 {
        try self.validate(domain, self.owner);
        for (self.entries) |entry| if (entry.statement == statement) return entry.bytes;
        return null;
    }
};
