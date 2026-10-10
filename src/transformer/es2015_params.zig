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
const ast_walk = @import("../parser/ast_walk.zig");
const Node = ast_mod.Node;
const NodeIndex = ast_mod.NodeIndex;
const NodeList = ast_mod.NodeList;
const Tag = Node.Tag;
const token_mod = @import("../lexer/token.zig");
const Span = token_mod.Span;
const es_helpers = @import("es_helpers.zig");
const SymbolKind = @import("../semantic/symbol.zig").SymbolKind;
const ScopeKind = @import("../semantic/scope.zig").ScopeKind;

pub fn ES2015Params(comptime Transformer: type) type {
    return struct {
        /// The emitted formal parameter and body declarations have different
        /// SymbolKinds. Register each binding before emitting references to it.
        fn registerDestructuringTempAtCreation(
            self: *Transformer,
            binding: NodeIndex,
            name_span: Span,
            declaration_span: Span,
            kind: SymbolKind,
        ) Transformer.Error!void {
            if (!self.semantic_edit_enabled) return;
            const scope = self.current_scope;
            const scopes = if (self.semantic_editor) |*editor| editor.scopes.items else self.scopes;
            if (scope.isNone() or scope.toIndex() >= scopes.len or scopes[scope.toIndex()].kind != ScopeKind.function)
                std.debug.panic("destructuring parameter temp requires an active function scope", .{});
            const id = if (kind == .variable_var)
                try self.declareSyntheticTempInScope(binding, declaration_span, scope)
            else
                try self.declareSyntheticInScope(binding, declaration_span, kind, scope);
            const symbol_id = id orelse std.debug.panic("destructuring parameter temp has no creation SymbolId", .{});
            const raw_id = @intFromEnum(symbol_id);
            const binding_id = self.getSymbolIdAt(binding) orelse
                std.debug.panic("destructuring parameter temp binding missed its creation SymbolId", .{});
            if (binding_id != raw_id)
                std.debug.panic("destructuring parameter temp binding missed its creation SymbolId", .{});
            const editor = if (self.semantic_editor) |*editor| editor else std.debug.panic("destructuring parameter temp was not registered in the semantic editor", .{});
            if (raw_id >= editor.symbols.items.len)
                std.debug.panic("destructuring parameter temp SymbolId is outside the semantic editor", .{});
            const symbol = editor.symbols.items[raw_id];
            if (symbol.scope_id != scope or symbol.kind != kind)
                std.debug.panic("destructuring parameter temp SymbolId has the wrong owner", .{});
            try self.destructuring_temp_symbol_ids.put(self.allocator, name_span.start, raw_id);
        }

        fn emitParameterPatternDeclarators(
            self: *Transformer,
            pattern: Node,
            read_span: Span,
            span: Span,
        ) Transformer.Error!void {
            const es2015_destruct = @import("es2015_destructuring.zig").ES2015Destructuring(Transformer);
            const saved_kind = self.destructuring_temp_kind;
            self.destructuring_temp_kind = .variable_var;
            defer self.destructuring_temp_kind = saved_kind;
            try es2015_destruct.emitPatternDeclarators(self, pattern, read_span, span, .@"var");
        }

        /// 파라미터 패턴 안에 object rest (`{a, ...r}`, ES2018) 가 있는지 검사 (#4251).
        /// default_params(ES2015) 는 지원하나 object_spread(ES2018) 만 미지원인
        /// 타겟(es2016/es2017)에서, object rest 가 든 param 만 lowering 하기 위한
        /// target-aware 게이트. (default-param-only 함수의 불필요 lowering 회피.)
        pub fn hasObjectRestParam(self: *const Transformer, params: ast_mod.NodeList) Transformer.Error!bool {
            const old_params = self.ast.extra_data.items[params.start .. params.start + params.len];
            for (old_params) |raw_idx| {
                if (try parameterHasObjectRest(self, @enumFromInt(raw_idx))) return true;
            }
            return false;
        }

        /// Return the first parameter whose binding pattern needs ES2018
        /// object-rest lowering. Later parameter initializers are moved into
        /// the body to preserve the pattern's evaluation order.
        pub fn firstObjectRestParamIndex(self: *const Transformer, params: ast_mod.NodeList) Transformer.Error!?usize {
            const old_params = self.ast.extra_data.items[params.start .. params.start + params.len];
            for (old_params, 0..) |raw_idx, i| {
                if (try parameterHasObjectRest(self, @enumFromInt(raw_idx))) return i;
            }
            return null;
        }

        fn parameterHasObjectRest(self: *const Transformer, param_idx: NodeIndex) Transformer.Error!bool {
            if (param_idx.isNone() or @intFromEnum(param_idx) >= self.ast.nodes.items.len) return false;
            const param = self.ast.getNode(param_idx);
            const pattern_idx: NodeIndex = switch (param.tag) {
                .formal_parameter => blk: {
                    const extra = param.data.extra;
                    if (extra + ast_mod.FormalParameterExtra.pattern >= self.ast.extra_data.items.len) break :blk .none;
                    break :blk @enumFromInt(self.ast.extra_data.items[extra + ast_mod.FormalParameterExtra.pattern]);
                },
                .assignment_pattern => param.data.binary.left,
                else => param_idx,
            };
            return bindingPatternHasObjectRest(self, pattern_idx);
        }

        /// Search only binding-pattern positions. Default expressions and computed
        /// keys may contain object spread, which does not require parameter lowering.
        fn bindingPatternHasObjectRest(self: *const Transformer, root: NodeIndex) Transformer.Error!bool {
            if (root.isNone() or @intFromEnum(root) >= self.ast.nodes.items.len) return false;
            var pending: std.ArrayList(NodeIndex) = .empty;
            defer pending.deinit(self.allocator);
            try pending.append(self.allocator, root);

            while (pending.pop()) |idx| {
                if (idx.isNone() or @intFromEnum(idx) >= self.ast.nodes.items.len) continue;
                const node = self.ast.getNode(idx);
                switch (node.tag) {
                    .formal_parameter => {
                        const extra = node.data.extra;
                        if (extra + ast_mod.FormalParameterExtra.pattern >= self.ast.extra_data.items.len) continue;
                        const pattern: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra + ast_mod.FormalParameterExtra.pattern]);
                        if (!pattern.isNone()) try pending.append(self.allocator, pattern);
                    },
                    .assignment_pattern => {
                        if (!node.data.binary.left.isNone()) try pending.append(self.allocator, node.data.binary.left);
                    },
                    .object_pattern => {
                        const split = self.ast.nodeListSplitRest(node.data.list);
                        if (split.rest_operand != null) return true;
                        for (split.elements) |raw_child| {
                            const child_idx: NodeIndex = @enumFromInt(raw_child);
                            if (child_idx.isNone() or @intFromEnum(child_idx) >= self.ast.nodes.items.len) continue;
                            const child = self.ast.getNode(child_idx);
                            if (child.tag == .object_property) {
                                const value = ast_mod.Ast.objectPropertyValue(child);
                                if (!value.isNone()) try pending.append(self.allocator, value);
                            } else {
                                try pending.append(self.allocator, child_idx);
                            }
                        }
                    },
                    .array_pattern => {
                        const split = self.ast.nodeListSplitRest(node.data.list);
                        for (split.elements) |raw_child| {
                            const child: NodeIndex = @enumFromInt(raw_child);
                            if (!child.isNone()) try pending.append(self.allocator, child);
                        }
                        if (split.rest_operand) |rest| try pending.append(self.allocator, rest);
                    },
                    .rest_element, .binding_rest_element => {
                        if (!node.data.unary.operand.isNone()) try pending.append(self.allocator, node.data.unary.operand);
                    },
                    .object_property => {
                        const value = ast_mod.Ast.objectPropertyValue(node);
                        if (!value.isNone()) try pending.append(self.allocator, value);
                    },
                    else => {},
                }
            }
            return false;
        }

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
            var param_tdz_names: std.ArrayList(Span) = .empty;
            defer param_tdz_names.deinit(self.allocator);
            const name_starts = try self.allocator.alloc(usize, params.len);
            defer self.allocator.free(name_starts);

            var name_i: u32 = 0;
            while (name_i < params.len) : (name_i += 1) {
                name_starts[name_i] = param_tdz_names.items.len;
                const raw_idx = self.ast.extra_data.items[params.start + name_i];
                try collectBindingNames(self, @enumFromInt(raw_idx), &param_tdz_names);
            }

            // pass2에서는 노드가 이미 visited 상태이므로 인덱스를 그대로 사용
            const maybeVisit = struct {
                fn call(t: *Transformer, idx: NodeIndex) Transformer.Error!NodeIndex {
                    if (pass2) return idx;
                    return t.visitNode(idx);
                }
            }.call;

            var object_rest_seen = false;
            var i_loop: u32 = 0;
            while (i_loop < params.len) : (i_loop += 1) {
                const raw_idx = self.ast.extra_data.items[params.start + i_loop];
                const param = self.ast.getNode(@enumFromInt(raw_idx));

                if (param.tag == .spread_element or param.tag == .rest_element) {
                    // #4251: rest parameter(`...args`)는 ES2015 — default_params 지원
                    // 타겟(es2016/es2017)에선 native 유지. arguments 기반 lowering 은
                    // arrow 에 arguments 가 없어 ReferenceError(이 경로가 es2017 에서
                    // 도는 건 object_spread 만 미지원이라 object rest 때문). es5(default_
                    // params 미지원)만 `var args = [].slice.call(arguments, N)`.
                    if (!self.options.unsupported.default_params) {
                        const new_rest = try maybeVisit(self, @enumFromInt(raw_idx));
                        try self.scratch.append(self.allocator, new_rest);
                        continue;
                    }
                    // rest parameter: ...args → var args = [].slice.call(arguments, N)
                    const rest_binding = try maybeVisit(self, param.data.unary.operand);
                    const rest_stmt = try buildRestSlice(self, rest_binding, param_index, span);
                    try body_stmts.append(self.allocator, rest_stmt);
                    // rest를 params에 넣지 않음
                    continue;
                }

                // ES2016/2017 keep native default/destructuring parameters. Only
                // parameters before the first ES2018 object-rest parameter can
                // stay native. Parameters after it must keep body-lowering order
                // because their initializers run after that parameter's pattern.
                const has_object_rest = if (self.options.unsupported.default_params)
                    false
                else
                    try parameterHasObjectRest(self, @enumFromInt(raw_idx));
                if (!self.options.unsupported.default_params and !object_rest_seen and !has_object_rest) {
                    const kept = try maybeVisit(self, @enumFromInt(raw_idx));
                    if (!kept.isNone()) try self.scratch.append(self.allocator, kept);
                    param_index += 1;
                    continue;
                }
                if (has_object_rest) object_rest_seen = true;

                if (param.tag == .formal_parameter) {
                    const pe = param.data.extra;
                    const pattern_idx: NodeIndex = self.readNodeIdx(pe, ast_mod.FormalParameterExtra.pattern);
                    const default_idx: NodeIndex = self.readNodeIdx(pe, ast_mod.FormalParameterExtra.default);

                    if (!default_idx.isNone()) {
                        if (!self.options.unsupported.default_params) {
                            const visited_pattern = try maybeVisit(self, pattern_idx);
                            const visited_default = try maybeVisit(self, default_idx);
                            try es_helpers.rewriteTDZReferences(self, visited_default, param_tdz_names.items[name_starts[i_loop]..]);
                            const temp = try buildDestructuringParam(self, visited_pattern, &body_stmts, span);
                            const extras = try self.ast.addExtras(&.{
                                @intFromEnum(temp),
                                @intFromEnum(NodeIndex.none),
                                @intFromEnum(visited_default),
                                self.ast.extra_data.items[pe + ast_mod.FormalParameterExtra.flags],
                                self.ast.extra_data.items[pe + ast_mod.FormalParameterExtra.deco_start],
                                self.ast.extra_data.items[pe + ast_mod.FormalParameterExtra.deco_len],
                            });
                            const lowered_param = try self.ast.addExtraNode(.formal_parameter, param.span, extras);
                            try self.scratch.append(self.allocator, lowered_param);
                            param_index += 1;
                            continue;
                        }
                        const pat_node = self.ast.getNode(pattern_idx);
                        if (pat_node.tag == .object_pattern or pat_node.tag == .array_pattern) {
                            const vp = try maybeVisit(self, pattern_idx);
                            const vd = try maybeVisit(self, default_idx);
                            try es_helpers.rewriteTDZReferences(self, vd, param_tdz_names.items[name_starts[i_loop]..]);
                            const result = try buildDestructuringDefault(self, vp, vd, &body_stmts, span);
                            try self.scratch.append(self.allocator, result);
                        } else {
                            const new_pattern = try maybeVisit(self, pattern_idx);
                            try self.scratch.append(self.allocator, new_pattern);
                            const new_default = try maybeVisit(self, default_idx);
                            try es_helpers.rewriteTDZReferences(self, new_default, param_tdz_names.items[name_starts[i_loop]..]);
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
                    if (!self.options.unsupported.default_params and
                        (try bindingPatternHasObjectRest(self, param.data.binary.left)))
                    {
                        const visited_pattern = try maybeVisit(self, param.data.binary.left);
                        const visited_default = try maybeVisit(self, param.data.binary.right);
                        try es_helpers.rewriteTDZReferences(self, visited_default, param_tdz_names.items[name_starts[i_loop]..]);
                        const temp = try buildDestructuringParam(self, visited_pattern, &body_stmts, span);
                        const lowered_param = try self.ast.addNode(.{
                            .tag = .assignment_pattern,
                            .span = param.span,
                            .data = .{ .binary = .{
                                .left = temp,
                                .right = visited_default,
                                .flags = param.data.binary.flags,
                            } },
                        });
                        try self.scratch.append(self.allocator, lowered_param);
                        param_index += 1;
                        continue;
                    }
                    if (pattern_node.tag == .object_pattern or pattern_node.tag == .array_pattern) {
                        const vp = try maybeVisit(self, param.data.binary.left);
                        const vd = try maybeVisit(self, param.data.binary.right);
                        try es_helpers.rewriteTDZReferences(self, vd, param_tdz_names.items[name_starts[i_loop]..]);
                        const result = try buildDestructuringDefault(self, vp, vd, &body_stmts, span);
                        try self.scratch.append(self.allocator, result);
                    } else {
                        const new_pattern = try maybeVisit(self, param.data.binary.left);
                        try self.scratch.append(self.allocator, new_pattern);
                        const new_default = try maybeVisit(self, param.data.binary.right);
                        try es_helpers.rewriteTDZReferences(self, new_default, param_tdz_names.items[name_starts[i_loop]..]);
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
            const temp_binding = try es_helpers.makeSyntheticBinding(self, temp_span);
            try registerDestructuringTempAtCreation(self, temp_binding, temp_span, span, .parameter);
            es_helpers.consumeTempVarSpan(self, temp_span);

            const default_stmt = try buildDefaultCheckForTemp(self, temp_span, visited_default, span);
            try body_stmts.append(self.allocator, default_stmt);

            const temp_ref2 = try es_helpers.makeTrackedTempRef(self, temp_span, span, .{ .read = true });
            const pattern_node = self.ast.getNode(visited_pattern);
            const es2015_destruct = @import("es2015_destructuring.zig").ES2015Destructuring(Transformer);
            var read_binding: NodeIndex = .none;
            const read_span = if (pattern_node.tag == .array_pattern) blk: {
                const read_span = try es_helpers.makeTempVarSpan(self);
                read_binding = try es_helpers.makeSyntheticBinding(self, read_span);
                try registerDestructuringTempAtCreation(self, read_binding, read_span, span, .variable_var);
                es_helpers.consumeTempVarSpan(self, read_span);
                const read_init = try es2015_destruct.buildArrayRead(self, temp_ref2, pattern_node, span);
                const read_decl = try es_helpers.makeVarDeclaration(
                    self,
                    &.{try es_helpers.makeDeclarator(self, read_binding, read_init, span)},
                    .@"var",
                    span,
                );
                try body_stmts.append(self.allocator, read_decl);
                break :blk read_span;
            } else temp_span;

            const scratch_top = self.scratch.items.len;
            defer self.scratch.shrinkRetainingCapacity(scratch_top);
            try emitParameterPatternDeclarators(self, pattern_node, read_span, span);
            const declarators = self.scratch.items[scratch_top..];
            if (declarators.len > 0) {
                const destruct_decl = try es_helpers.makeVarDeclaration(self, declarators, .@"var", span);
                try body_stmts.append(self.allocator, destruct_decl);
            }

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
            const temp_binding = try es_helpers.makeSyntheticBinding(self, temp_span);
            try registerDestructuringTempAtCreation(self, temp_binding, temp_span, span, .parameter);
            es_helpers.consumeTempVarSpan(self, temp_span);

            const scratch_top = self.scratch.items.len;
            defer self.scratch.shrinkRetainingCapacity(scratch_top);

            const pattern = self.ast.getNode(pattern_idx);
            const es2015_destruct = @import("es2015_destructuring.zig").ES2015Destructuring(Transformer);
            var read_binding: NodeIndex = .none;
            const read_span = if (pattern.tag == .array_pattern) blk: {
                const read_span = try es_helpers.makeTempVarSpan(self);
                read_binding = try es_helpers.makeSyntheticBinding(self, read_span);
                try registerDestructuringTempAtCreation(self, read_binding, read_span, span, .variable_var);
                es_helpers.consumeTempVarSpan(self, read_span);
                const temp_ref = try es_helpers.makeTrackedTempRef(self, temp_span, span, .{ .read = true });
                const read_init = try es2015_destruct.buildArrayRead(self, temp_ref, pattern, span);
                const read_decl = try es_helpers.makeDeclarator(self, read_binding, read_init, span);
                try self.scratch.append(self.allocator, read_decl);
                break :blk read_span;
            } else temp_span;
            try emitParameterPatternDeclarators(self, pattern, read_span, span);

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
            const pattern_ref = try copyIdentifier(self, pattern, .{ .read = true });
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
            const pattern_ref2 = try copyIdentifier(self, pattern, .{ .read = true });
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
            const pattern_ref3 = try copyIdentifier(self, pattern, .{ .write = true });
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

        fn buildDefaultCheckForTemp(self: *Transformer, temp_span: Span, default_val: NodeIndex, span: Span) Transformer.Error!NodeIndex {
            const void_zero = try es_helpers.makeVoidZero(self, span);
            const test_ref = try es_helpers.makeTrackedTempRef(self, temp_span, span, .{ .read = true });
            const eq_check = try self.ast.addNode(.{
                .tag = .binary_expression,
                .span = span,
                .data = .{ .binary = .{ .left = test_ref, .right = void_zero, .flags = @intFromEnum(token_mod.Kind.eq3) } },
            });
            const value_ref = try es_helpers.makeTrackedTempRef(self, temp_span, span, .{ .read = true });
            const conditional = try self.ast.addNode(.{
                .tag = .conditional_expression,
                .span = span,
                .data = .{ .ternary = .{ .a = eq_check, .b = default_val, .c = value_ref } },
            });
            const write_ref = try es_helpers.makeTrackedTempRef(self, temp_span, span, .{ .write = true });
            const assign = try self.ast.addNode(.{
                .tag = .assignment_expression,
                .span = span,
                .data = .{ .binary = .{ .left = write_ref, .right = conditional, .flags = 0 } },
            });
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
            const slice_prop = try es_helpers.makePropertyName(self, "slice");
            const slice_member = try es_helpers.makeStaticMember(self, empty_arr, slice_prop, span);

            // [].slice.call
            const call_prop = try es_helpers.makePropertyName(self, "call");
            const slice_call = try es_helpers.makeStaticMember(self, slice_member, call_prop, span);

            // arguments
            const args_ref = try es_helpers.makeGlobalRef(self, "arguments");

            // start_index number
            const idx_node = try es_helpers.makeNumericLiteral(self, @intCast(start_index));

            // [].slice.call(arguments, N)
            const call_node = try es_helpers.makeCallExpr(self, slice_call, &.{ args_ref, idx_node }, span);

            // var rest = [].slice.call(arguments, N)
            const declarator = try es_helpers.makeDeclarator(self, binding, call_node, span);
            return es_helpers.makeVarDeclaration(self, &.{declarator}, .@"var", span);
        }

        /// identifier 노드를 복제한다 (같은 이름·같은 심볼의 새 노드). 심볼을 물려주지 않으면
        /// minify 가 매개변수 선언만 바꾸고 이 참조는 원래 이름으로 남는다 (#4762).
        fn copyIdentifier(self: *Transformer, node_idx: NodeIndex, flags: @import("../semantic/symbol.zig").ReferenceFlags) Transformer.Error!NodeIndex {
            const node = self.ast.getNode(node_idx);
            const ref = try self.makeIdentifierRefWithSymbolAt(node.data.string_ref, node.span, node_idx);
            const use_scope = if (self.getSymbolIdAt(node_idx)) |raw_id| blk: {
                const symbols = if (self.semantic_editor) |*editor| editor.symbols.items else self.symbols;
                if (raw_id < symbols.len) break :blk symbols[raw_id].scope_id;
                break :blk self.current_scope;
            } else self.current_scope;
            if (flags.read) try self.trackUserReadFromBinding(ref, node_idx, use_scope);
            if (flags.write) try self.trackUserWriteFromBinding(ref, node_idx, use_scope);
            return ref;
        }

        fn collectBindingNames(self: *Transformer, idx: NodeIndex, out: *std.ArrayList(Span)) Transformer.Error!void {
            // cover-grammar 결과 (identifier_reference / assignment_target_identifier) 도
            // 동일하게 spans 로 수집 — caller (param TDZ 검사) 가 그 형태를 기대한다.
            var it = try ast_walk.bindingIdentifiers(self.allocator, self.ast, idx, .{});
            defer it.deinit();
            while (try it.next()) |leaf_idx| {
                const emitted_name = self.ast.getNode(leaf_idx).data.string_ref;
                try out.append(self.allocator, emitted_name);
                // Forward reads can still have the source spelling: the
                // analyzer registers parameters in order and does not yet
                // model their separate environment. Keep both spellings of
                // this exact binding for the existing TDZ lowering, including
                // when a body function forced a parameter alias.
                if (self.getSymbolIdAt(leaf_idx)) |id| {
                    const symbols = if (self.semantic_editor) |*editor| editor.symbols.items else self.symbols;
                    if (id < symbols.len and symbols[id].kind == .parameter) {
                        const source_name = symbols[id].name;
                        if (!std.mem.eql(u8, self.ast.getText(source_name), self.ast.getText(emitted_name)))
                            try out.append(self.allocator, source_name);
                    }
                }
            }
        }
    };
}

test "ES2015 params module compiles" {
    _ = ES2015Params;
}
