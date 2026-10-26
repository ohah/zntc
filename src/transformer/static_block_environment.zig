//! The source static block owns a var environment, not a function. A lowered
//! block gets a distinct actual function scope before any body expression visit.
const std = @import("std");
const ast = @import("../parser/ast.zig");
const es = @import("es_helpers.zig");
const ScopeId = @import("../semantic/scope.zig").ScopeId;

pub fn lower(self: anytype, source: ast.NodeIndex, parent: ScopeId, class_name: @import("../lexer/token.zig").Span) @import("transformer.zig").Transformer.Error!ast.NodeIndex {
    const node = self.ast.getNode(source);
    std.debug.assert(node.tag == .static_block);
    const body = node.data.unary.operand;
    const params = try self.ast.addListNode(.formal_parameters, node.span, try self.ast.addNodeList(&.{}));
    const function = try self.addExtraNode(.function_expression, node.span, &.{ @backingInt(ast.NodeIndex.none), @backingInt(params), @backingInt(body), 0, 0 });
    const function_scope = try self.addGeneratedFunctionScope(parent, function);
    try @import("transformer/semantic_edit.zig").transferStaticBlockStorage(self, source, function_scope, body);
    const saved_scope = self.current_scope;
    const saved_new_target = self.new_target_ctx;
    const saved_extracted = self.in_extracted_fn_body;
    self.current_scope = function_scope;
    const environment = es.pushArrowEnv(self);
    defer es.popArrowEnv(self, environment);
    self.new_target_ctx = .method;
    self.in_extracted_fn_body = false;
    const visited = blk: {
        defer self.current_scope = saved_scope;
        defer self.new_target_ctx = saved_new_target;
        defer self.in_extracted_fn_body = saved_extracted;
        break :blk try self.visitNode(body);
    };
    try @import("transformer/semantic_edit.zig").completeStaticBlockBody(self, body, visited, function_scope);
    // The ordinary function owns its body implicitly. Use a fresh syntax
    // container so a source body returned unchanged cannot expose the retired
    // source static-block alias through the original owner map.
    const output_body = try self.ast.addListNode(.block_statement, node.span, self.ast.getNode(visited).data.list);
    try @import("class_strict_context.zig").prependDirective(self, output_body);
    self.ast.extra_data.items[self.ast.getNode(function).data.extra + ast.FunctionExtra.body] = @backingInt(output_body);
    const call_key = try es.makePropertyName(self, "call");
    const callee = try es.makeStaticMember(self, function, call_key, node.span);
    const receiver = blk: {
        const previous = self.current_scope;
        self.current_scope = parent;
        defer self.current_scope = previous;
        break :blk (try @import("static_class_capture.zig").makeThisReference(self)) orelse
            try self.makeCurrentClassRefAtScope(class_name, parent);
    };
    return es.makeExprStmt(self, try es.makeCallExpr(self, callee, &.{receiver}, node.span), node.span);
}
