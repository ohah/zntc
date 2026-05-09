//! Plugin dispatch helpers for Transformer.

const ast_mod = @import("../../parser/ast.zig");
const NodeIndex = ast_mod.NodeIndex;
const ast_plugin_mod = @import("../ast_plugin.zig");
const AstTransformCtx = ast_plugin_mod.AstTransformCtx;
const FunctionInfo = ast_plugin_mod.FunctionInfo;
const transformer_mod = @import("../transformer.zig");
const Transformer = transformer_mod.Transformer;
const Error = Transformer.Error;

pub const VisitorHookKind = enum { on_program, on_object_expression, on_call_expression, on_class_declaration, on_class_expression };

pub fn dispatchVisitor(self: *Transformer, comptime kind: VisitorHookKind, node_idx: NodeIndex) Error!?NodeIndex {
    if (self.options.plugins.len == 0) return null;
    var api = AstTransformCtx{ .transformer = self };
    for (self.options.plugins) |p| {
        const v = p.visitor orelse continue;
        const hook = @field(v, @tagName(kind)) orelse continue;
        const result = hook(p.context, &api, node_idx) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.PluginFailed => continue,
        };
        if (result) |r| return r;
    }
    return null;
}

pub fn dispatchFunctionPlugins(self: *Transformer, result: NodeIndex, func_info: FunctionInfo) Error!?NodeIndex {
    if (self.options.plugins.len == 0) return null;
    var api = AstTransformCtx{ .transformer = self, .modified_body = null };
    defer api.deinitClosureCache();
    for (self.options.plugins) |p| {
        if (p.onFunction) |hook| {
            hook(p.context, &api, func_info) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.PluginFailed => {},
            };
        }
    }
    if (api.modified_body) |new_body_idx| {
        const result_extra = self.ast.getNode(result).data.extra;
        self.ast.extra_data.items[result_extra + functionBodyOffset(func_info.node_tag)] = @intFromEnum(new_body_idx);
    }
    return api.replaced_node;
}

fn functionBodyOffset(tag: ast_mod.Node.Tag) u32 {
    return switch (tag) {
        .arrow_function_expression => 1,
        else => 2,
    };
}
