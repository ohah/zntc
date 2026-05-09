//! Tagged template lowering helpers for Transformer.

const std = @import("std");
const ast_mod = @import("../../parser/ast.zig");
const Node = ast_mod.Node;
const NodeIndex = ast_mod.NodeIndex;
const token_mod = @import("../../lexer/token.zig");
const Span = token_mod.Span;
const es2015_template = @import("../es2015_template.zig");
const es_helpers = @import("../es_helpers.zig");
const transformer_mod = @import("../transformer.zig");
const Transformer = transformer_mod.Transformer;
const Error = Transformer.Error;

/// tagged_template_expression: extra = [tag, template, flags]
pub fn visitTaggedTemplate(self: *Transformer, node: Node) Error!NodeIndex {
    const e = node.data.extra;
    if (e + 2 >= self.ast.extra_data.items.len) return NodeIndex.none;
    const tag_idx = self.readNodeIdx(e, 0);
    const tmpl_idx = self.readNodeIdx(e, 1);
    const flags = self.readU32(e, 2);

    // ES2015 tagged template 다운레벨링
    if (self.options.unsupported.template_literal) {
        return lowerTaggedTemplate(self, tag_idx, tmpl_idx, node.span);
    }

    const new_tag = try self.visitNode(tag_idx);
    const new_tmpl = try self.visitNode(tmpl_idx);
    const new_extra = try self.ast.addExtras(&.{ @intFromEnum(new_tag), @intFromEnum(new_tmpl), flags });
    return self.ast.addNode(.{ .tag = node.tag, .span = node.span, .data = .{ .extra = new_extra } });
}

/// ES2015 tagged template 다운레벨링.
/// tag`hello ${name} world` →
///   function _templateObject() { var data = __taggedTemplateLiteral(["hello "," world"]); _templateObject = function(){ return data; }; return data; }
///   tag(_templateObject(), name)
fn lowerTaggedTemplate(self: *Transformer, tag_idx: NodeIndex, tmpl_idx: NodeIndex, span: Span) Error!NodeIndex {
    const tmpl = self.ast.getNode(tmpl_idx);
    const source = self.ast.source;

    // template_literal의 quasis(element)와 expressions 분리
    // 구조: [element, expr, element, expr, ..., element]
    // substitution이 없으면 data.none=0, element 1개뿐

    const is_substitution = blk: {
        var pos = tmpl.span.start + 1;
        while (pos < tmpl.span.end) {
            if (source[pos] == '\\') {
                pos += 2;
                continue;
            }
            if (source[pos] == '$' and pos + 1 < tmpl.span.end and source[pos + 1] == '{') break :blk true;
            pos += 1;
        }
        break :blk false;
    };

    // --- cooked/raw/expr 배열 구축 (scratch 사용, 힙 할당 없음) ---
    const scratch_base = self.scratch.items.len;
    defer self.scratch.shrinkRetainingCapacity(scratch_base);

    // scratch에 순서대로: [cooked... | raw... | expr...]
    // 각 영역의 시작 위치를 기록
    var cooked_count: u32 = 0;
    var raw_count: u32 = 0;
    var has_escape = false;

    // ES2018 "Lifting Template Literal Restriction" — invalid escape 면 cooked element 를
    // `undefined` 로. buildCookedElement 가 검사 + dispatch 양쪽을 담당.
    if (!is_substitution) {
        const text = es2015_template.getTemplateElementText(source, tmpl.span);
        try self.scratch.append(self.allocator, try es2015_template.buildCookedElement(self, text, tmpl.span));
        cooked_count = 1;
    } else {
        const tl_start = tmpl.data.list.start;
        const tl_len = tmpl.data.list.len;
        var i: u32 = 0;
        while (i < tl_len) : (i += 1) {
            const raw_idx = self.ast.extra_data.items[tl_start + i];
            const member = self.ast.getNode(@enumFromInt(raw_idx));
            if (member.tag == .template_element) {
                const text = es2015_template.getTemplateElementText(source, member.span);
                try self.scratch.append(self.allocator, try es2015_template.buildCookedElement(self, text, member.span));
                cooked_count += 1;
            }
        }
    }

    // raw 배열 (cooked 뒤에 append)
    const raw_start = self.scratch.items.len;
    if (!is_substitution) {
        const raw_text = es2015_template.getTemplateElementText(source, tmpl.span);
        try self.scratch.append(self.allocator, try es2015_template.buildRawStringLiteral(self, raw_text));
        if (std.mem.indexOf(u8, raw_text, "\\") != null) has_escape = true;
        raw_count = 1;
    } else {
        const tl_start2 = tmpl.data.list.start;
        const tl_len2 = tmpl.data.list.len;
        var j: u32 = 0;
        while (j < tl_len2) : (j += 1) {
            const raw_idx2 = self.ast.extra_data.items[tl_start2 + j];
            const member2 = self.ast.getNode(@enumFromInt(raw_idx2));
            if (member2.tag == .template_element) {
                const raw_text = es2015_template.getTemplateElementText(source, member2.span);
                try self.scratch.append(self.allocator, try es2015_template.buildRawStringLiteral(self, raw_text));
                if (std.mem.indexOf(u8, raw_text, "\\") != null) has_escape = true;
                raw_count += 1;
            }
        }
    }

    // expr 배열 (raw 뒤에 append)
    const expr_start = self.scratch.items.len;
    if (is_substitution) {
        const tl_start3 = tmpl.data.list.start;
        const tl_len3 = tmpl.data.list.len;
        var k: u32 = 0;
        while (k < tl_len3) : (k += 1) {
            const raw_idx3 = self.ast.extra_data.items[tl_start3 + k];
            const member3 = self.ast.getNode(@enumFromInt(raw_idx3));
            if (member3.tag != .template_element) {
                try self.scratch.append(self.allocator, try self.visitNode(@enumFromInt(raw_idx3)));
            }
        }
    }
    const expr_count = self.scratch.items.len - expr_start;

    const cooked_slice = self.scratch.items[scratch_base .. scratch_base + cooked_count];
    const raw_slice = self.scratch.items[raw_start .. raw_start + raw_count];
    const expr_slice = self.scratch.items[expr_start .. expr_start + expr_count];

    // --- _templateObject 함수명 생성 ---
    self.tagged_template_counter += 1;
    const fn_name = if (self.tagged_template_counter == 1)
        "_templateObject"
    else blk: {
        break :blk try std.fmt.allocPrint(self.allocator, "_templateObject{d}", .{self.tagged_template_counter});
    };
    defer if (self.tagged_template_counter > 1) self.allocator.free(fn_name);

    // --- cooked 배열 노드 ---
    const cooked_list = try self.ast.addNodeList(cooked_slice);
    const cooked_arr = try self.ast.addNode(.{
        .tag = .array_expression,
        .span = span,
        .data = .{ .list = cooked_list },
    });

    // --- __taggedTemplateLiteral(cooked, [raw]) 호출 ---
    const helper_ref = try es_helpers.makeRuntimeHelperRef(self, "__taggedTemplateLiteral");
    var call_args: [2]NodeIndex = undefined;
    var call_arg_count: u32 = 1;
    call_args[0] = cooked_arr;

    if (has_escape) {
        const raw_list = try self.ast.addNodeList(raw_slice);
        const raw_arr = try self.ast.addNode(.{
            .tag = .array_expression,
            .span = span,
            .data = .{ .list = raw_list },
        });
        call_args[1] = raw_arr;
        call_arg_count = 2;
    }

    const helper_args = try self.ast.addNodeList(call_args[0..call_arg_count]);
    const helper_call_extra = try self.ast.addExtras(&.{
        @intFromEnum(helper_ref), helper_args.start, helper_args.len, 0,
    });
    const helper_call = try self.ast.addNode(.{
        .tag = .call_expression,
        .span = span,
        .data = .{ .extra = helper_call_extra },
    });

    // --- var data = __taggedTemplateLiteral(...) ---
    const data_decl = try self.buildVarDecl("data", helper_call, span);

    // --- _templateObject = function() { return data; } ---
    const fn_name_ref = try es_helpers.makeIdentifierRef(self, fn_name);
    const data_ref = try es_helpers.makeIdentifierRef(self, "data");
    const return_stmt = try self.ast.addNode(.{
        .tag = .return_statement,
        .span = span,
        .data = .{ .unary = .{ .operand = data_ref, .flags = 0 } },
    });
    const inner_body_list = try self.ast.addNodeList(&.{return_stmt});
    const inner_body = try self.ast.addNode(.{
        .tag = .block_statement,
        .span = span,
        .data = .{ .list = inner_body_list },
    });
    const none = @intFromEnum(NodeIndex.none);
    const inner_empty_params = try self.ast.addNodeList(&.{});
    const inner_params_node = try self.ast.addFormalParameters(inner_empty_params, span);
    const inner_func_extra = try self.ast.addExtras(&.{
        none, @intFromEnum(inner_params_node), @intFromEnum(inner_body), 0, none,
    });
    const inner_func = try self.ast.addNode(.{
        .tag = .function_expression,
        .span = span,
        .data = .{ .extra = inner_func_extra },
    });

    // _templateObject = function() { return data; }
    const reassign = try self.ast.addNode(.{
        .tag = .assignment_expression,
        .span = span,
        .data = .{ .binary = .{ .left = fn_name_ref, .right = inner_func, .flags = 0 } },
    });
    const reassign_stmt = try self.ast.addNode(.{
        .tag = .expression_statement,
        .span = span,
        .data = .{ .unary = .{ .operand = reassign, .flags = 0 } },
    });

    // return data
    const data_ref2 = try es_helpers.makeIdentifierRef(self, "data");
    const return_stmt2 = try self.ast.addNode(.{
        .tag = .return_statement,
        .span = span,
        .data = .{ .unary = .{ .operand = data_ref2, .flags = 0 } },
    });

    // --- function _templateObject() { var data = ...; _templateObject = ...; return data; } ---
    const outer_body_list = try self.ast.addNodeList(&.{ data_decl, reassign_stmt, return_stmt2 });
    const outer_body = try self.ast.addNode(.{
        .tag = .block_statement,
        .span = span,
        .data = .{ .list = outer_body_list },
    });
    const fn_name_binding_span = try self.ast.addString(fn_name);
    const fn_name_binding = try self.ast.addNode(.{
        .tag = .binding_identifier,
        .span = fn_name_binding_span,
        .data = .{ .string_ref = fn_name_binding_span },
    });
    const outer_empty_params = try self.ast.addNodeList(&.{});
    const outer_params_node = try self.ast.addFormalParameters(outer_empty_params, span);
    const outer_func_extra = try self.ast.addExtras(&.{
        @intFromEnum(fn_name_binding), @intFromEnum(outer_params_node), @intFromEnum(outer_body), 0, none,
    });
    const fn_decl = try self.ast.addNode(.{
        .tag = .function_declaration,
        .span = span,
        .data = .{ .extra = outer_func_extra },
    });

    // 호이스팅 목록에 추가
    try self.tagged_template_fns.append(self.allocator, fn_decl);
    self.runtime_helpers.tagged_template_literal = true;

    // --- tag(_templateObject(), ...exprs) 호출 ---
    const new_tag = try self.visitNode(tag_idx);
    const fn_call_ref = try es_helpers.makeIdentifierRef(self, fn_name);
    const empty_args = try self.ast.addNodeList(&.{});
    const tmpl_call_extra = try self.ast.addExtras(&.{
        @intFromEnum(fn_call_ref), empty_args.start, empty_args.len, 0,
    });
    const tmpl_call = try self.ast.addNode(.{
        .tag = .call_expression,
        .span = span,
        .data = .{ .extra = tmpl_call_extra },
    });

    // tag(_templateObject(), expr1, expr2, ...)
    // scratch에서 최종 인자 목록 구성 (기존 cooked/raw/expr 뒤에 append)
    const final_start = self.scratch.items.len;
    try self.scratch.append(self.allocator, tmpl_call);
    for (expr_slice) |expr| {
        try self.scratch.append(self.allocator, expr);
    }
    const final_args = try self.ast.addNodeList(self.scratch.items[final_start..]);
    const final_call_extra = try self.ast.addExtras(&.{
        @intFromEnum(new_tag), final_args.start, final_args.len, 0,
    });
    return self.ast.addNode(.{
        .tag = .call_expression,
        .span = span,
        .data = .{ .extra = final_call_extra },
    });
}
