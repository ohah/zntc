//! ES2015 다운레벨링: default parameters + rest parameters
//!
//! --target < es2015 일 때 활성화.
//!
//! Default parameters:
//!   function f(x = 1) {} → function f(x) { x = x === void 0 ? 1 : x; }
//!
//! Rest parameters:
//!   function f(a, ...rest) {} → function f(a) { var rest = [].slice.call(arguments, 1); }
//!
//! 두 변환 모두 파라미터 목록을 수정하고 함수 바디 앞에 문을 삽입한다.
//!
//! 스펙:
//! - https://tc39.es/ecma262/#sec-function-definitions (ES2015, default/rest)
//!
//! 참고:
//! - SWC: crates/swc_ecma_compat_es2015/src/parameters.rs (~845줄)
//! - esbuild: pkg/js_parser/js_parser_lower.go (lowerFunction)

const std = @import("std");
const ast_mod = @import("../parser/ast.zig");
const Node = ast_mod.Node;
const NodeIndex = ast_mod.NodeIndex;
const NodeList = ast_mod.NodeList;
const Tag = Node.Tag;
const token_mod = @import("../lexer/token.zig");
const Span = token_mod.Span;
const es_helpers = @import("es_helpers.zig");

pub fn ES2015Params(comptime Transformer: type) type {
    return struct {
        /// 파라미터 목록에서 default/rest 파라미터가 있는지 검사한다.
        pub fn hasDefaultOrRest(self: *const Transformer, params: ast_mod.NodeList) bool {
            const old_params = self.ast.extra_data.items[params.start .. params.start + params.len];
            for (old_params) |raw_idx| {
                const param = self.ast.getNode(@enumFromInt(raw_idx));
                if (param.tag == .spread_element or param.tag == .rest_element) return true;
                // destructuring 파라미터도 ES5 변환 필요
                if (param.tag == .object_pattern or param.tag == .array_pattern) return true;
                if (param.tag == .formal_parameter) {
                    const extras = self.ast.extra_data.items;
                    const pe = param.data.extra;
                    const default_val: NodeIndex = @enumFromInt(extras[pe + 2]);
                    if (!default_val.isNone()) return true;
                    // formal_parameter 안의 destructuring 패턴도 체크
                    const pattern_idx: NodeIndex = @enumFromInt(extras[pe]);
                    const pattern_node = self.ast.getNode(pattern_idx);
                    if (pattern_node.tag == .object_pattern or pattern_node.tag == .array_pattern) return true;
                }
                if (param.tag == .assignment_pattern) return true;
            }
            return false;
        }

        /// default/rest 파라미터를 변환한다.
        /// 파라미터 목록에서 default와 rest를 제거하고,
        /// 함수 바디 앞에 초기화 문을 삽입한다.
        ///
        /// pass2=true: Pass 2에서 호출. 노드가 이미 visited 상태이므로
        /// visitNode 대신 인덱스를 그대로 사용한다.
        ///
        /// 반환: { new_params, body_prepend_stmts }
        pub fn lowerParams(
            self: *Transformer,
            params: ast_mod.NodeList,
            span: Span,
        ) Transformer.Error!LowerResult {
            return lowerParamsImpl(self, params, span, false);
        }

        pub fn lowerParamsPass2(
            self: *Transformer,
            params: ast_mod.NodeList,
            span: Span,
        ) Transformer.Error!LowerResult {
            return lowerParamsImpl(self, params, span, true);
        }

        fn lowerParamsImpl(
            self: *Transformer,
            params: ast_mod.NodeList,
            span: Span,
            comptime pass2: bool,
        ) Transformer.Error!LowerResult {
            const param_scratch_top = self.scratch.items.len;
            defer self.scratch.shrinkRetainingCapacity(param_scratch_top);

            var body_stmts: std.ArrayList(NodeIndex) = .empty;

            var param_index: usize = 0; // arguments index tracking

            // pass2에서는 노드가 이미 visited 상태이므로 인덱스를 그대로 사용
            const maybeVisit = struct {
                fn call(t: *Transformer, idx: NodeIndex) Transformer.Error!NodeIndex {
                    if (pass2) return idx;
                    return t.visitNode(idx);
                }
            }.call;

            var i_loop: u32 = 0;
            while (i_loop < params.len) : (i_loop += 1) {
                const raw_idx = self.ast.extra_data.items[params.start + i_loop];
                const param = self.ast.getNode(@enumFromInt(raw_idx));

                if (param.tag == .spread_element or param.tag == .rest_element) {
                    // rest parameter: ...args → var args = [].slice.call(arguments, N)
                    const rest_binding = try maybeVisit(self, param.data.unary.operand);
                    const rest_stmt = try buildRestSlice(self, rest_binding, param_index, span);
                    try body_stmts.append(self.allocator, rest_stmt);
                    // rest를 params에 넣지 않음
                    continue;
                }

                if (param.tag == .formal_parameter) {
                    // extra = [pattern, type_ann, default, flags, deco_start, deco_len]
                    const pe = param.data.extra;
                    const pattern_idx: NodeIndex = self.readNodeIdx(pe, 0);
                    const default_idx: NodeIndex = self.readNodeIdx(pe, 2);

                    if (!default_idx.isNone()) {
                        const pat_node = self.ast.getNode(pattern_idx);
                        if (pat_node.tag == .object_pattern or pat_node.tag == .array_pattern) {
                            const vp = try maybeVisit(self, pattern_idx);
                            const vd = try maybeVisit(self, default_idx);
                            const result = try buildDestructuringDefault(self, vp, vd, &body_stmts, span);
                            try self.scratch.append(self.allocator, result);
                        } else {
                            const new_pattern = try maybeVisit(self, pattern_idx);
                            try self.scratch.append(self.allocator, new_pattern);
                            const new_default = try maybeVisit(self, default_idx);
                            const default_stmt = try buildDefaultCheck(self, new_pattern, new_default, span);
                            try body_stmts.append(self.allocator, default_stmt);
                        }
                        param_index += 1;
                        continue;
                    }
                }

                if (param.tag == .assignment_pattern) {
                    // assignment_pattern: binary { left=pattern, right=default }
                    const pattern_node = self.ast.getNode(param.data.binary.left);
                    if (pattern_node.tag == .object_pattern or pattern_node.tag == .array_pattern) {
                        const vp = try maybeVisit(self, param.data.binary.left);
                        const vd = try maybeVisit(self, param.data.binary.right);
                        const result = try buildDestructuringDefault(self, vp, vd, &body_stmts, span);
                        try self.scratch.append(self.allocator, result);
                    } else {
                        const new_pattern = try maybeVisit(self, param.data.binary.left);
                        try self.scratch.append(self.allocator, new_pattern);
                        const new_default = try maybeVisit(self, param.data.binary.right);
                        const default_stmt = try buildDefaultCheck(self, new_pattern, new_default, span);
                        try body_stmts.append(self.allocator, default_stmt);
                    }
                    param_index += 1;
                    continue;
                }

                // destructuring 파라미터 (default 없음): temp 변수 경유
                // function View({ ref, ...props }) → function View(_param) { var {ref, ...props} = _param; }
                const param_node = self.ast.getNode(@enumFromInt(raw_idx));
                const pattern_idx_raw = if (param_node.tag == .formal_parameter)
                    self.ast.extra_data.items[param_node.data.extra]
                else
                    raw_idx;
                const pattern_node = self.ast.getNode(@enumFromInt(pattern_idx_raw));

                if (pattern_node.tag == .object_pattern or pattern_node.tag == .array_pattern) {
                    const result = try buildDestructuringParam(self, @enumFromInt(pattern_idx_raw), &body_stmts, span);
                    try self.scratch.append(self.allocator, result);
                    param_index += 1;
                    continue;
                }

                // 일반 파라미터: 그대로 방문
                const new_param = try maybeVisit(self, @enumFromInt(raw_idx));
                if (!new_param.isNone()) {
                    try self.scratch.append(self.allocator, new_param);
                }
                param_index += 1;
            }

            const new_params = try self.ast.addNodeList(self.scratch.items[param_scratch_top..]);

            return .{
                .new_params = new_params,
                .body_stmts = body_stmts,
            };
        }

        pub const LowerResult = struct {
            new_params: NodeList,
            body_stmts: std.ArrayList(NodeIndex),
        };

        /// destructuring + default parameter → temp 변수 경유.
        /// ({a = 1} = {}) → (_ref); body에 _ref = _ref === void 0 ? {} : _ref; var {a} = _ref;
        /// visited_pattern, visited_default는 이미 방문된 노드 인덱스.
        fn buildDestructuringDefault(
            self: *Transformer,
            visited_pattern: NodeIndex,
            visited_default: NodeIndex,
            body_stmts: *std.ArrayList(NodeIndex),
            span: Span,
        ) Transformer.Error!NodeIndex {
            const temp_span = try es_helpers.makeTempVarSpan(self);
            const temp_binding = try es_helpers.makeBindingIdentifier(self, temp_span);

            const temp_ref = try es_helpers.makeTempVarRef(self, temp_span, span);
            const default_stmt = try buildDefaultCheck(self, temp_ref, visited_default, span);
            try body_stmts.append(self.allocator, default_stmt);

            const temp_ref2 = try es_helpers.makeTempVarRef(self, temp_span, span);
            const destruct_decl = try es_helpers.makeVarDeclaration(
                self,
                &.{try es_helpers.makeDeclarator(self, visited_pattern, temp_ref2, span)},
                .@"var",
                span,
            );
            try body_stmts.append(self.allocator, destruct_decl);

            return temp_binding;
        }

        /// destructuring parameter (default 없음) → temp 변수 경유.
        /// ({ ref, ...props }) → (_param); body에 var ref = _param.ref, props = __rest(_param, ["ref"]);
        fn buildDestructuringParam(
            self: *Transformer,
            pattern_idx: NodeIndex,
            body_stmts: *std.ArrayList(NodeIndex),
            span: Span,
        ) Transformer.Error!NodeIndex {
            const temp_span = try es_helpers.makeTempVarSpan(self);
            const temp_binding = try es_helpers.makeBindingIdentifier(self, temp_span);

            const scratch_top = self.scratch.items.len;
            defer self.scratch.shrinkRetainingCapacity(scratch_top);

            const pattern = self.ast.getNode(pattern_idx);
            const es2015_destruct = @import("es2015_destructuring.zig").ES2015Destructuring(Transformer);
            try es2015_destruct.emitPatternDeclarators(self, pattern, temp_span, span);

            const declarators = self.scratch.items[scratch_top..];
            if (declarators.len > 0) {
                const decl = try es_helpers.makeVarDeclaration(self, declarators, .@"var", span);
                try body_stmts.append(self.allocator, decl);
            }

            return temp_binding;
        }

        /// x = x === void 0 ? default_value : x
        /// → expression_statement 생성
        fn buildDefaultCheck(self: *Transformer, pattern: NodeIndex, default_val: NodeIndex, span: Span) Transformer.Error!NodeIndex {
            // void 0
            const void_zero = try es_helpers.makeVoidZero(self, span);

            // x === void 0
            const pattern_ref = try copyIdentifier(self, pattern);
            const eq_check = try self.ast.addNode(.{
                .tag = .binary_expression,
                .span = span,
                .data = .{ .binary = .{
                    .left = pattern_ref,
                    .right = void_zero,
                    .flags = @intFromEnum(token_mod.Kind.eq3),
                } },
            });

            // x === void 0 ? default_value : x
            const pattern_ref2 = try copyIdentifier(self, pattern);
            const conditional = try self.ast.addNode(.{
                .tag = .conditional_expression,
                .span = span,
                .data = .{ .ternary = .{
                    .a = eq_check,
                    .b = default_val,
                    .c = pattern_ref2,
                } },
            });

            // x = (conditional)
            const pattern_ref3 = try copyIdentifier(self, pattern);
            const assign = try self.ast.addNode(.{
                .tag = .assignment_expression,
                .span = span,
                .data = .{ .binary = .{ .left = pattern_ref3, .right = conditional, .flags = 0 } },
            });

            // expression_statement
            return self.ast.addNode(.{
                .tag = .expression_statement,
                .span = span,
                .data = .{ .unary = .{ .operand = assign, .flags = 0 } },
            });
        }

        /// var rest = [].slice.call(arguments, N)
        fn buildRestSlice(self: *Transformer, binding: NodeIndex, start_index: usize, span: Span) Transformer.Error!NodeIndex {
            // [] (empty array)
            const empty_arr_list = try self.ast.addNodeList(&.{});
            const empty_arr = try self.ast.addNode(.{
                .tag = .array_expression,
                .span = span,
                .data = .{ .list = empty_arr_list },
            });

            // [].slice
            const slice_prop = try es_helpers.makeIdentifierRef(self, "slice");
            const slice_member = try es_helpers.makeStaticMember(self, empty_arr, slice_prop, span);

            // [].slice.call
            const call_prop = try es_helpers.makeIdentifierRef(self, "call");
            const slice_call = try es_helpers.makeStaticMember(self, slice_member, call_prop, span);

            // arguments
            const args_ref = try es_helpers.makeIdentifierRef(self, "arguments");

            // start_index number
            const idx_node = try es_helpers.makeNumericLiteral(self, @intCast(start_index));

            // [].slice.call(arguments, N)
            const call_node = try es_helpers.makeCallExpr(self, slice_call, &.{ args_ref, idx_node }, span);

            // var rest = [].slice.call(arguments, N)
            const declarator = try es_helpers.makeDeclarator(self, binding, call_node, span);
            return es_helpers.makeVarDeclaration(self, &.{declarator}, .@"var", span);
        }

        /// identifier 노드를 복제한다 (같은 이름의 새 노드).
        fn copyIdentifier(self: *Transformer, node_idx: NodeIndex) Transformer.Error!NodeIndex {
            const node = self.ast.getNode(node_idx);
            return self.ast.addNode(.{
                .tag = .identifier_reference,
                .span = node.span,
                .data = .{ .string_ref = node.data.string_ref },
            });
        }
    };
}

test "ES2015 params module compiles" {
    _ = ES2015Params;
}
