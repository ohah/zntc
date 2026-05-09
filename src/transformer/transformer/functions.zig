//! Function-like visitor helpers for Transformer.

const ast_mod = @import("../../parser/ast.zig");
const Node = ast_mod.Node;
const NodeIndex = ast_mod.NodeIndex;
const NodeList = ast_mod.NodeList;
const worklet_mod = @import("worklet.zig");
const transformer_mod = @import("../transformer.zig");
const Transformer = transformer_mod.Transformer;
const Error = Transformer.Error;

/// Visit a function body while suppressing define replacement for worklet bodies.
pub fn visitBodyWorkletAware(self: *Transformer, body_idx: NodeIndex) Error!NodeIndex {
    const is_worklet = self.plugins.worklet.auto_next or
        worklet_mod.isWorkletDirectiveGeneric(self, body_idx, "worklet");
    if (is_worklet) self.plugins.worklet.body_depth += 1;
    defer if (is_worklet) {
        self.plugins.worklet.body_depth -= 1;
    };
    return self.visitNode(body_idx);
}

/// Visit a node with Fast Refresh registration suppressed for the nested scope.
pub fn visitWithRefreshSuppressed(self: *Transformer, node_idx: NodeIndex) Error!NodeIndex {
    const saved = self.plugins.refresh.suppress_registration;
    self.plugins.refresh.suppress_registration = true;
    defer self.plugins.refresh.suppress_registration = saved;
    return self.visitNode(node_idx);
}

/// arrow_function_expression: extra = [params_list, body, flags]
pub fn visitArrowFunction(self: *Transformer, node: Node) Error!NodeIndex {
    const e = node.data.extra;
    if (e + 2 >= self.ast.extra_data.items.len) return NodeIndex.none;
    const params_idx = self.readNodeIdx(e, 0);
    const body_idx = self.readNodeIdx(e, 1);
    const flags = self.readU32(e, 2);
    const new_params = try self.visitNode(params_idx);
    const new_body = try self.visitBodyWorkletAware(body_idx);
    const new_extra = try self.ast.addExtras(&.{ @intFromEnum(new_params), @intFromEnum(new_body), flags });
    const result = try self.ast.addNode(.{ .tag = .arrow_function_expression, .span = node.span, .data = .{ .extra = new_extra } });

    const is_auto_worklet = self.plugins.worklet.auto_next;
    if (is_auto_worklet or self.options.plugins.len > 0) {
        const orig_params_list: NodeList = blk: {
            if (params_idx.isNone()) break :blk .{ .start = 0, .len = 0 };
            const n = self.ast.getNode(params_idx);
            break :blk if (n.tag == .formal_parameters) n.data.list else .{ .start = 0, .len = 0 };
        };
        const new_params_list: NodeList = blk: {
            if (new_params.isNone()) break :blk .{ .start = 0, .len = 0 };
            const n = self.ast.getNode(new_params);
            break :blk if (n.tag == .formal_parameters) n.data.list else .{ .start = 0, .len = 0 };
        };

        if (try self.dispatchFunctionPlugins(result, .{
            .node_idx = result,
            .node_tag = .arrow_function_expression,
            .name = null,
            .body_idx = new_body,
            .params = new_params_list,
            .original_params = orig_params_list,
            .original_body_idx = body_idx,
            .flags = flags,
            .source_path = self.options.jsx_filename,
            .is_auto_worklet = is_auto_worklet,
        })) |replacement| {
            return replacement;
        }
    }

    return result;
}
