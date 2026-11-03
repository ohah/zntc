//! Call/new visitor helpers for Transformer.

const ast_mod = @import("../../parser/ast.zig");
const Node = ast_mod.Node;
const NodeIndex = ast_mod.NodeIndex;
const transformer_mod = @import("../transformer.zig");
const Transformer = transformer_mod.Transformer;
const Error = Transformer.Error;

/// Construct/lower a call whose children already have an evaluation owner.
/// In particular a suspension planner must not feed them back to visitNode.
pub fn lowerCallWithEvaluatedChildren(self: *Transformer, node: Node, callee: NodeIndex, args: @import("../../parser/ast.zig").NodeList) Error!NodeIndex {
    const flags = self.readU32(node.data.extra, 3);
    const extra = try self.ast.addExtras(&.{ @backingInt(callee), args.start, args.len, flags });
    const evaluated: Node = .{ .tag = node.tag, .span = node.span, .data = .{ .extra = extra } };
    const Spread = @import("../es2015_spread.zig").ES2015Spread(Transformer);
    if (self.options.unsupported.spread and Spread.hasSpreadArg(self, evaluated)) {
        return if (node.tag == .new_expression)
            Spread.lowerSpreadNewWithPrevisitedArgs(self, evaluated)
        else
            Spread.lowerSpreadCallWithPrevisitedArgs(self, evaluated, args.len);
    }
    return self.ast.addNode(evaluated);
}

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
                @backingInt(new_callee), rewritten_args.start, rewritten_args.len, flags,
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

    const call = try lowerCallWithEvaluatedChildren(self, node, new_callee, new_args);
    return @import("../native_derived_this.zig").initializeAfterSuper(self, callee_idx, call, node.span);
}

/// new_expression: extra = [callee, args_start, args_len, flags]
pub fn visitNewExpression(self: *Transformer, node: Node) Error!NodeIndex {
    const e = node.data.extra;
    if (e + 3 >= self.ast.extra_data.items.len) return NodeIndex.none;
    const callee_idx = self.readNodeIdx(e, 0);
    const args_start = self.readU32(e, 1);
    const args_len = self.readU32(e, 2);
    const new_callee = try self.visitNode(callee_idx);
    const new_args = try self.visitExtraList(.{ .start = args_start, .len = args_len });
    return lowerCallWithEvaluatedChildren(self, node, new_callee, new_args);
}
