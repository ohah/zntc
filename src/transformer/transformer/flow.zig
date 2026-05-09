//! Flow syntax lowering helpers for Transformer.

const std = @import("std");
const ast_mod = @import("../../parser/ast.zig");
const Node = ast_mod.Node;
const NodeIndex = ast_mod.NodeIndex;
const NodeList = ast_mod.NodeList;
const token_mod = @import("../../lexer/token.zig");
const es_helpers = @import("../es_helpers.zig");
const transformer_mod = @import("../transformer.zig");
const Transformer = transformer_mod.Transformer;
const Error = Transformer.Error;

/// Flow match expression → (function(_m){if(_m===P){B}else if...})(expr)
pub fn visitFlowMatch(self: *Transformer, node: Node) Error!NodeIndex {
    const span = node.span;
    const e = node.data.extra;
    const discriminant_idx = self.readNodeIdx(e, 0);
    const arms_start = self.readU32(e, 1);
    const arms_len = self.readU32(e, 2);

    // arm 인덱스를 미리 로컬에 복사 (visitNode가 extra_data를 재할당할 수 있으므로)
    const arm_indices = try self.allocator.alloc(u32, arms_len);
    defer self.allocator.free(arm_indices);
    for (0..arms_len) |i| {
        arm_indices[i] = self.ast.extra_data.items[arms_start + i];
    }

    const new_discriminant = try self.visitNode(discriminant_idx);

    // 임시 변수 _m
    const match_var = try es_helpers.makeTempVarSpan(self);
    const match_param = try es_helpers.makeBindingIdentifier(self, match_var);
    var else_branch: NodeIndex = .none;

    var i: usize = arm_indices.len;
    while (i > 0) {
        i -= 1;
        const arm = self.ast.getNode(@enumFromInt(arm_indices[i]));
        const pattern = arm.data.binary.left;
        const body_idx = arm.data.binary.right;
        const new_body_raw = try self.visitNode(body_idx);
        // body를 { return body; } 또는 block 그대로 사용
        const body_node = self.ast.getNode(new_body_raw);
        const new_body = if (body_node.tag == .block_statement)
            new_body_raw
        else blk: {
            // expression → { return expr; }
            const return_stmt = try self.ast.addNode(.{
                .tag = .return_statement,
                .span = span,
                .data = .{ .unary = .{ .operand = new_body_raw, .flags = 0 } },
            });
            const stmts = try self.ast.addNodeList(&.{return_stmt});
            break :blk try self.ast.addNode(.{
                .tag = .block_statement,
                .span = span,
                .data = .{ .list = stmts },
            });
        };

        // wildcard `_` 감지
        const pat_node = self.ast.getNode(pattern);
        const is_wildcard = blk: {
            if (pat_node.tag == .identifier_reference) {
                const text = self.ast.getText(pat_node.span);
                break :blk std.mem.eql(u8, text, "_");
            }
            break :blk false;
        };

        if (is_wildcard) {
            else_branch = new_body;
        } else {
            const new_pattern = try self.visitNode(pattern);
            const match_ref = try es_helpers.makeTempVarRef(self, match_var, match_var);
            // _m === pattern
            const test_expr = try self.ast.addNode(.{
                .tag = .binary_expression,
                .span = span,
                .data = .{ .binary = .{
                    .left = match_ref,
                    .right = new_pattern,
                    .flags = @intFromEnum(token_mod.Kind.eq3),
                } },
            });
            else_branch = try self.ast.addNode(.{
                .tag = .if_statement,
                .span = span,
                .data = .{ .ternary = .{ .a = test_expr, .b = new_body, .c = else_branch } },
            });
        }
    }

    // function(_m) { if-chain }
    const body_list = if (!else_branch.isNone())
        try self.ast.addNodeList(&.{else_branch})
    else
        NodeList{ .start = 0, .len = 0 };
    const fn_body = try self.ast.addNode(.{
        .tag = .block_statement,
        .span = span,
        .data = .{ .list = body_list },
    });
    const fn_params_list = try self.ast.addNodeList(&.{match_param});
    const fn_params_node = try self.ast.addFormalParameters(fn_params_list, span);
    const fn_extra = try self.ast.addExtras(&.{
        @intFromEnum(NodeIndex.none), // name (anonymous)
        @intFromEnum(fn_params_node),
        @intFromEnum(fn_body),
        0, // flags
        @intFromEnum(NodeIndex.none), // return type
    });
    const fn_expr = try self.ast.addNode(.{
        .tag = .function_expression,
        .span = span,
        .data = .{ .extra = fn_extra },
    });

    // (function(_m){...})(discriminant)
    // function expression을 parenthesized로 감싸서 IIFE 형태로 만듦
    const paren_fn = try es_helpers.makeParenExpr(self, fn_expr, span);
    // call_expression extra: [callee, args_start, args_len, flags]
    const args_list = try self.ast.addNodeList(&.{new_discriminant});
    const call_extra = try self.ast.addExtras(&.{
        @intFromEnum(paren_fn),
        args_list.start,
        args_list.len,
        0, // flags
    });
    return self.ast.addNode(.{
        .tag = .call_expression,
        .span = span,
        .data = .{ .extra = call_extra },
    });
}

/// Flow component with ref → 2개 statement로 변환:
///   function Name_withRef({...props}, ref) { ... }    ← pending_nodes
///   const Name = React.forwardRef(Name_withRef);       ← 반환값
///
/// extra = [name, params_start, params_len, body]
/// Flow component with ref: 파서가 생성한 2개 statement를 방문.
/// extra = [func_decl, const_decl]
/// func_decl은 pending_nodes에, const_decl은 반환.
pub fn visitFlowComponentWrapper(self: *Transformer, node: Node) Error!NodeIndex {
    const e = node.data.extra;
    const func_decl_idx = self.readNodeIdx(e, 0);
    const const_decl_idx = self.readNodeIdx(e, 1);

    // function Name_withRef 방문 (ES2015 lowering 등 적용)
    const new_func = try self.visitNode(func_decl_idx);
    try self.pending_nodes.append(self.allocator, new_func);

    // const Name = React.forwardRef(Name_withRef) 방문
    return self.visitNode(const_decl_idx);
}
