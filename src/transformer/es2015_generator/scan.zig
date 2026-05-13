//! AST scan helpers for ES2015 generator lowering.

const std = @import("std");
const ast_mod = @import("../../parser/ast.zig");
const NodeIndex = ast_mod.NodeIndex;

fn pushNode(self: anytype, stack: *std.ArrayList(NodeIndex), child: NodeIndex) bool {
    stack.append(self.allocator, child) catch return false;
    return true;
}

/// AST 서브트리에 yield_expression 또는 generator labeled jump가 있는지 체크.
///
/// 명시 stack DFS — recursive 였을 때 deep AST 에서 stack overflow 위험. children
/// enumeration 은 기존 switch 구조 그대로 유지 (behavior 100% 보존). short-circuit
/// `or` 는 children 을 모두 push 한 뒤 다음 iteration 에서 자연 종료.
///
/// OOM 시 보수적으로 true 반환 — state machine 변환을 안 하는 것보다 하는 게 안전
/// (호출부가 더 보수적 변환 path 선택).
pub fn containsYield(self: anytype, root_idx: NodeIndex) bool {
    if (root_idx.isNone()) return false;
    var stack: std.ArrayList(NodeIndex) = .empty;
    defer stack.deinit(self.allocator);
    stack.append(self.allocator, root_idx) catch return true;

    while (stack.items.len > 0) {
        const idx = stack.pop() orelse break;
        if (idx.isNone()) continue;
        const node = self.ast.getNode(idx);

        if (node.tag == .yield_expression or node.tag == .await_expression) return true;
        if (node.tag == .for_await_of_statement and self.options.unsupported.needsForAwaitOfDownlevel()) return true;
        if (node.tag == .break_statement or node.tag == .continue_statement) {
            if (node.data.unary.operand.isNone()) {
                if (self.generator_label_stack.items.len > 0) return true;
            } else if (self.generator_label_stack.items.len > 0) {
                const label_node = self.ast.getNode(node.data.unary.operand);
                const label_text = self.ast.getText(label_node.span);
                for (self.generator_label_stack.items) |entry| {
                    if (std.mem.eql(u8, entry.name, label_text)) return true;
                }
            }
        }
        // function/arrow 경계: nested generator/arrow 의 yield 는 다른 스코프
        if (node.tag == .function_declaration or node.tag == .function_expression or
            node.tag == .arrow_function_expression) continue;

        switch (node.tag) {
            .block_statement,
            .function_body,
            .array_expression,
            .object_expression,
            .sequence_expression,
            .template_literal,
            .formal_parameters,
            .class_body,
            => {
                const members = self.ast.extra_data.items[node.data.list.start .. node.data.list.start + node.data.list.len];
                for (members) |raw_idx| {
                    if (!pushNode(self, &stack, @enumFromInt(raw_idx))) return true;
                }
            },
            .expression_statement,
            .return_statement,
            .throw_statement,
            .spread_element,
            .rest_element,
            .parenthesized_expression,
            .ts_as_expression,
            .ts_satisfies_expression,
            .ts_non_null_expression,
            .ts_type_assertion,
            .ts_instantiation_expression,
            .flow_as_expression,
            .flow_type_cast_expression,
            => {
                if (!pushNode(self, &stack, node.data.unary.operand)) return true;
            },
            .unary_expression, .update_expression => {
                const extras = self.ast.extra_data.items;
                const e = node.data.extra;
                if (e >= extras.len) continue;
                if (!pushNode(self, &stack, @enumFromInt(extras[e]))) return true;
            },
            .assignment_expression,
            .binary_expression,
            .logical_expression,
            .object_property,
            => {
                if (!pushNode(self, &stack, node.data.binary.left)) return true;
                if (!pushNode(self, &stack, node.data.binary.right)) return true;
            },
            .static_member_expression,
            .computed_member_expression,
            .tagged_template_expression,
            => {
                const extras = self.ast.extra_data.items;
                const e = node.data.extra;
                if (!pushNode(self, &stack, @enumFromInt(extras[e]))) return true;
                if (!pushNode(self, &stack, @enumFromInt(extras[e + 1]))) return true;
            },
            .conditional_expression,
            .if_statement,
            .for_in_statement,
            .for_of_statement,
            .for_await_of_statement,
            .try_statement,
            => {
                if (!pushNode(self, &stack, node.data.ternary.a)) return true;
                if (!pushNode(self, &stack, node.data.ternary.b)) return true;
                if (!pushNode(self, &stack, node.data.ternary.c)) return true;
            },
            .catch_clause,
            .while_statement,
            .do_while_statement,
            .labeled_statement,
            => {
                if (!pushNode(self, &stack, node.data.binary.left)) return true;
                if (!pushNode(self, &stack, node.data.binary.right)) return true;
            },
            .for_statement => {
                const extras = self.ast.extra_data.items;
                const e = node.data.extra;
                if (e + 3 >= extras.len) continue;
                if (!pushNode(self, &stack, @enumFromInt(extras[e + 3]))) return true; // body
            },
            .switch_statement, .variable_declaration => {
                // extra = [_, list_start, list_len]
                const extras = self.ast.extra_data.items;
                const e = node.data.extra;
                if (e + 2 >= extras.len) continue;
                const list_start = extras[e + 1];
                const list_len = extras[e + 2];
                const items = extras[list_start .. list_start + list_len];
                for (items) |raw_idx| {
                    if (!pushNode(self, &stack, @enumFromInt(raw_idx))) return true;
                }
            },
            .switch_case => {
                // extra = [test, stmts_start, stmts_len] — test 는 yield 안 가짐 (literal)
                const extras = self.ast.extra_data.items;
                const e = node.data.extra;
                if (e + 2 >= extras.len) continue;
                const stmts_start = extras[e + 1];
                const stmts_len = extras[e + 2];
                const stmts = extras[stmts_start .. stmts_start + stmts_len];
                for (stmts) |raw_idx| {
                    if (!pushNode(self, &stack, @enumFromInt(raw_idx))) return true;
                }
            },
            .call_expression, .new_expression => {
                // extra = [callee, args_start, args_len, flags]
                const extras = self.ast.extra_data.items;
                const e = node.data.extra;
                if (e + 2 >= extras.len) continue;
                if (!pushNode(self, &stack, @enumFromInt(extras[e]))) return true;
                const args_start = extras[e + 1];
                const args_len = extras[e + 2];
                const args = extras[args_start .. args_start + args_len];
                for (args) |raw_idx| {
                    if (!pushNode(self, &stack, @enumFromInt(raw_idx))) return true;
                }
            },
            .variable_declarator => {
                const extras = self.ast.extra_data.items;
                const e = node.data.extra;
                if (e + 2 >= extras.len) continue;
                if (!pushNode(self, &stack, @enumFromInt(extras[e + 2]))) return true; // init
            },
            else => {},
        }
    }
    return false;
}

/// AST 서브트리에 return_statement가 있는지 체크.
/// generator 내 if body에서 return이 있으면 collectOperations로 처리해야
/// return [2]로 변환됨.
///
/// 명시 stack DFS — recursive 였을 때 deep AST 에서 stack overflow 위험.
/// containsYield (#2803) 와 동일 변환 패턴. behavior 100% 보존.
pub fn containsReturn(self: anytype, root_idx: NodeIndex) bool {
    if (root_idx.isNone()) return false;
    var stack: std.ArrayList(NodeIndex) = .empty;
    defer stack.deinit(self.allocator);
    stack.append(self.allocator, root_idx) catch return true;

    while (stack.items.len > 0) {
        const idx = stack.pop() orelse break;
        if (idx.isNone()) continue;
        const node = self.ast.getNode(idx);

        if (node.tag == .return_statement) return true;
        // function/arrow 경계: nested 함수의 return 은 다른 스코프
        if (node.tag == .function_declaration or node.tag == .function_expression or
            node.tag == .arrow_function_expression) continue;

        switch (node.tag) {
            .block_statement, .function_body => {
                const members = self.ast.extra_data.items[node.data.list.start .. node.data.list.start + node.data.list.len];
                for (members) |raw_idx| {
                    if (!pushNode(self, &stack, @enumFromInt(raw_idx))) return true;
                }
            },
            .if_statement, .for_in_statement, .for_of_statement, .for_await_of_statement => {
                if (!pushNode(self, &stack, node.data.ternary.b)) return true;
                if (!pushNode(self, &stack, node.data.ternary.c)) return true;
            },
            .while_statement, .do_while_statement, .labeled_statement => {
                if (!pushNode(self, &stack, node.data.binary.right)) return true;
            },
            .for_statement => {
                const extras = self.ast.extra_data.items;
                const e = node.data.extra;
                if (e + 3 >= extras.len) continue;
                if (!pushNode(self, &stack, @enumFromInt(extras[e + 3]))) return true;
            },
            .switch_statement => {
                const extras = self.ast.extra_data.items;
                const e = node.data.extra;
                if (e + 2 >= extras.len) continue;
                const cases_start = extras[e + 1];
                const cases_len = extras[e + 2];
                const cases = extras[cases_start .. cases_start + cases_len];
                for (cases) |raw_idx| {
                    if (!pushNode(self, &stack, @enumFromInt(raw_idx))) return true;
                }
            },
            .switch_case => {
                const extras = self.ast.extra_data.items;
                const e = node.data.extra;
                if (e + 2 >= extras.len) continue;
                const stmts_start = extras[e + 1];
                const stmts_len = extras[e + 2];
                const stmts = extras[stmts_start .. stmts_start + stmts_len];
                for (stmts) |raw_idx| {
                    if (!pushNode(self, &stack, @enumFromInt(raw_idx))) return true;
                }
            },
            .try_statement => {
                if (!pushNode(self, &stack, node.data.ternary.a)) return true;
                if (!pushNode(self, &stack, node.data.ternary.b)) return true;
                if (!pushNode(self, &stack, node.data.ternary.c)) return true;
            },
            .catch_clause => {
                if (!pushNode(self, &stack, node.data.binary.right)) return true;
            },
            else => {},
        }
    }
    return false;
}
