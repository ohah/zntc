//! Call/new visitor helpers for Transformer.

const ast_mod = @import("../../parser/ast.zig");
const Node = ast_mod.Node;
const NodeIndex = ast_mod.NodeIndex;
const transformer_mod = @import("../transformer.zig");
const Transformer = transformer_mod.Transformer;
const Error = Transformer.Error;

/// call_expression: extra = [callee, args_start, args_len, flags]
pub fn visitCallExpression(self: *Transformer, node: Node) Error!NodeIndex {
    const e = node.data.extra;
    if (e + 3 >= self.ast.extra_data.items.len) return NodeIndex.none;
    const callee_idx = self.readNodeIdx(e, 0);
    const args_start = self.readU32(e, 1);
    const args_len = self.readU32(e, 2);
    const flags = self.readU32(e, 3);

    if (self.options.unsupported.regex_named_groups and args_len == 2) {
        if (try self.tryRewriteReplaceNamedRefs(callee_idx, args_start)) |rewritten_args| {
            const new_callee = try self.visitNode(callee_idx);
            const new_extra = try self.ast.addExtras(&.{
                @intFromEnum(new_callee), rewritten_args.start, rewritten_args.len, flags,
            });
            return self.ast.addNode(.{
                .tag = .call_expression,
                .span = node.span,
                .data = .{ .extra = new_extra },
            });
        }
    }

    const new_callee = try self.visitNode(callee_idx);
    const auto_callee = self.matchAutoWorkletCallee(callee_idx);
    const new_args = if (auto_callee != null)
        try self.visitCallArgsWithAutoWorklet(args_start, args_len, auto_callee.?)
    else
        try self.visitExtraList(.{ .start = args_start, .len = args_len });

    const new_extra = try self.ast.addExtras(&.{
        @intFromEnum(new_callee), new_args.start, new_args.len, flags,
    });
    return self.ast.addNode(.{
        .tag = .call_expression,
        .span = node.span,
        .data = .{ .extra = new_extra },
    });
}

/// new_expression: extra = [callee, args_start, args_len, flags]
pub fn visitNewExpression(self: *Transformer, node: Node) Error!NodeIndex {
    const e = node.data.extra;
    if (e + 3 >= self.ast.extra_data.items.len) return NodeIndex.none;
    const callee_idx = self.readNodeIdx(e, 0);
    const args_start = self.readU32(e, 1);
    const args_len = self.readU32(e, 2);
    const flags = self.readU32(e, 3);
    const new_callee = try self.visitNode(callee_idx);
    const new_args = try self.visitExtraList(.{ .start = args_start, .len = args_len });
    const new_extra = try self.ast.addExtras(&.{
        @intFromEnum(new_callee), new_args.start, new_args.len, flags,
    });
    return self.ast.addNode(.{
        .tag = .new_expression,
        .span = node.span,
        .data = .{ .extra = new_extra },
    });
}
