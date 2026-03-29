//! ES2015 다운레벨링: for-of loop
//!
//! --target < es2015 일 때 활성화.
//!
//! for (const x of arr) { body }
//! → for (var _i = 0, _arr = arr; _i < _arr.length; _i++) { var x = _arr[_i]; body }
//!
//! 배열 기반 변환 (esbuild 호환). 임의 iterable은 미지원.
//! iterable이 부작용을 가질 수 있으므로 임시 변수에 저장.
//!
//! 스펙:
//! - https://tc39.es/ecma262/#sec-for-in-and-for-of-statements (ES2015)
//!
//! 참고:
//! - SWC: crates/swc_ecma_compat_es2015/src/for_of.rs (~724줄)
//! - esbuild: for-of 다운레벨링 미지원 (for-await만)

const ast_mod = @import("../parser/ast.zig");
const Node = ast_mod.Node;
const NodeIndex = ast_mod.NodeIndex;
const Tag = Node.Tag;
const token_mod = @import("../lexer/token.zig");
const Span = token_mod.Span;
const es_helpers = @import("es_helpers.zig");

pub fn ES2015ForOf(comptime Transformer: type) type {
    return struct {
        /// for (const x of arr) { body }
        /// → for (var _a = 0, _b = arr; _a < _b.length; _a++) { var x = _b[_a]; body }
        pub fn lowerForOfStatement(self: *Transformer, node: Node) Transformer.Error!NodeIndex {
            const span = node.span;
            const left = node.data.ternary.a; // loop variable (variable_declaration or expression)
            const right = node.data.ternary.b; // iterable
            const body = node.data.ternary.c; // body

            // 임시 변수: _a (index), _b (array)
            const idx_span = try es_helpers.makeTempVarSpan(self);
            const arr_span = try es_helpers.makeTempVarSpan(self);

            const new_right = try self.visitNode(right);

            // --- init: var _a = 0, _b = arr ---
            // _a = 0
            const idx_binding = try es_helpers.makeBindingIdentifier(self, idx_span);
            const zero = try es_helpers.makeNumericLiteral(self, 0);
            const idx_decl = try es_helpers.makeDeclarator(self, idx_binding, zero, span);

            // _b = arr
            const arr_binding = try es_helpers.makeBindingIdentifier(self, arr_span);
            const arr_decl = try es_helpers.makeDeclarator(self, arr_binding, new_right, span);

            const init = try es_helpers.makeVarDeclaration(self, &.{ idx_decl, arr_decl }, 0, span);

            // --- test: _a < _b.length ---
            const idx_ref = try es_helpers.makeTempVarRef(self, idx_span, idx_span);
            const length_prop = try es_helpers.makeIdentifierRef(self, "length");
            const arr_ref_test = try es_helpers.makeTempVarRef(self, arr_span, arr_span);
            const arr_length = try es_helpers.makeStaticMember(self, arr_ref_test, length_prop, span);
            const test_expr = try self.new_ast.addNode(.{
                .tag = .binary_expression,
                .span = span,
                .data = .{ .binary = .{
                    .left = idx_ref,
                    .right = arr_length,
                    .flags = @intFromEnum(token_mod.Kind.l_angle),
                } },
            });

            // --- update: _a++ ---
            const idx_ref_update = try es_helpers.makeTempVarRef(self, idx_span, idx_span);
            const update_extra = try self.new_ast.addExtras(&.{
                @intFromEnum(idx_ref_update),
                @intFromEnum(token_mod.Kind.plus2) | (ast_mod.UnaryFlags.postfix),
            });
            const update_expr = try self.new_ast.addNode(.{
                .tag = .update_expression,
                .span = span,
                .data = .{ .extra = update_extra },
            });

            // --- body: var x = _b[_a]; original_body ---
            const new_body = try self.visitNode(body);

            // _b[_a]
            const arr_ref_body = try es_helpers.makeTempVarRef(self, arr_span, arr_span);
            const idx_ref_body = try es_helpers.makeTempVarRef(self, idx_span, idx_span);
            const elem_access_extra = try self.new_ast.addExtras(&.{
                @intFromEnum(arr_ref_body), @intFromEnum(idx_ref_body), 0,
            });
            const elem_access = try self.new_ast.addNode(.{
                .tag = .computed_member_expression,
                .span = span,
                .data = .{ .extra = elem_access_extra },
            });

            // var x = _b[_a] (or assignment if left is expression)
            const elem_assign = try buildLoopVarAssign(self, left, elem_access, span);

            // prepend to body
            const final_body = if (!new_body.isNone())
                try self.prependStatementsToBody(new_body, &.{elem_assign})
            else
                new_body;

            // --- for_statement: extra = [init, test, update, body] ---
            const for_extra = try self.new_ast.addExtras(&.{
                @intFromEnum(init),
                @intFromEnum(test_expr),
                @intFromEnum(update_expr),
                @intFromEnum(final_body),
            });
            return self.new_ast.addNode(.{
                .tag = .for_statement,
                .span = span,
                .data = .{ .extra = for_extra },
            });
        }

        /// for-of의 left를 기반으로 `var x = elem` 문 생성.
        /// left가 variable_declaration이면 해당 패턴을 재사용.
        /// left가 expression이면 assignment로 변환.
        fn buildLoopVarAssign(self: *Transformer, left: NodeIndex, elem: NodeIndex, span: Span) Transformer.Error!NodeIndex {
            if (left.isNone()) return NodeIndex.none;
            const left_node = self.old_ast.getNode(left);

            if (left_node.tag == .variable_declaration) {
                // for (const/let/var x of ...) → var x = _b[_a]
                const extras = self.old_ast.extra_data.items;
                const le = left_node.data.extra;
                const list_start = extras[le + 1];
                const list_len = extras[le + 2];
                if (list_len == 0) return NodeIndex.none;

                // 첫 번째 declarator의 binding name 추출
                const first_decl_idx: NodeIndex = @enumFromInt(extras[list_start]);
                const first_decl = self.old_ast.getNode(first_decl_idx);
                if (first_decl.tag != .variable_declarator) return NodeIndex.none;

                const binding_name = try self.visitNode(@enumFromInt(extras[first_decl.data.extra]));

                // var x = elem
                const declarator = try es_helpers.makeDeclarator(self, binding_name, elem, span);
                return es_helpers.makeVarDeclaration(self, &.{declarator}, 0, span);
            } else {
                // for (x of ...) → x = _b[_a]
                const new_left = try self.visitNode(left);
                const assign = try self.new_ast.addNode(.{
                    .tag = .assignment_expression,
                    .span = span,
                    .data = .{ .binary = .{ .left = new_left, .right = elem, .flags = 0 } },
                });
                return self.new_ast.addNode(.{
                    .tag = .expression_statement,
                    .span = span,
                    .data = .{ .unary = .{ .operand = assign, .flags = 0 } },
                });
            }
        }
    };
}

test "ES2015 for-of module compiles" {
    _ = ES2015ForOf;
}
