//! Constructor and derived-constructor body helpers for ES2015 class lowering.

const std = @import("std");
const ast_mod = @import("../../parser/ast.zig");
const Node = ast_mod.Node;
const NodeIndex = ast_mod.NodeIndex;
const token_mod = @import("../../lexer/token.zig");
const Span = token_mod.Span;
const es_helpers = @import("../es_helpers.zig");
const es2015_params = @import("../es2015_params.zig");
const helper_names = @import("../../runtime_helper_names.zig");

const MethodExtra = ast_mod.MethodExtra;

pub fn Constructors(comptime Transformer: type) type {
    return struct {
        /// function_declaration의 body 앞에 문들을 삽입 (in-place).
        ///
        /// body 포인터만 덮어써서 orphan function_declaration을 남기지 않는다.
        /// 이전 구현은 매 호출마다 새 function_declaration 노드를 만들어 intermediate
        /// function을 `ast.nodes`에 orphan으로 남겼는데, 그 orphan이 pass 2
        /// (`lowerAllFunctionParams`)에서 rest-param `var rest = [].slice.call(...)`
        /// 를 prepend받아 `[var rest, var _this, ...]` 같은 인접 var 쌍을 만들고,
        /// minify의 `mergeAdjacentDecls`가 이를 merge하며 공유된 `var _this` 노드의
        /// list_len을 0으로 비워 live body의 `var _this;` 출력이 `var ;`로 깨지는
        /// 문제가 있었다. body만 교체하면 function_declaration은 단일 인스턴스로
        /// 유지되어 이 경로 자체가 제거된다.
        pub fn prependToFunctionBody(self: *Transformer, func_idx: NodeIndex, stmts: []const NodeIndex) Transformer.Error!NodeIndex {
            const func = self.ast.getNode(func_idx);
            const fe = func.data.extra;
            const body_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[fe + 2]);

            const new_body = try self.prependStatementsToBody(body_idx, stmts);
            self.ast.extra_data.items[fe + 2] = @intFromEnum(new_body);
            return func_idx;
        }

        /// constructor method_definition에서 function_declaration 생성.
        pub fn buildFunctionFromConstructor(self: *Transformer, ctor_idx: NodeIndex, name: NodeIndex, instance_fields: []const NodeIndex, is_derived: bool, span: Span) Transformer.Error!NodeIndex {
            const ctor = self.ast.getNode(ctor_idx);
            const me = ctor.data.extra;

            const params_list_old = self.ast.functionParamsList(ctor);
            const body_idx: NodeIndex = self.readNodeIdx(me, MethodExtra.body);

            // derived constructor 안의 this는 super() 전 접근을 런타임에서 검사해야 한다.
            const saved_super_alias = self.super_call_this_alias;
            self.super_call_this_alias = is_derived;
            defer self.super_call_this_alias = saved_super_alias;

            // TS parameter property(`constructor(public x)`)는 modifier 만 strip 되어 일반 형태로 visit 되지만,
            // 이 경로는 visitMethodDefinition 을 거치지 않으므로 `this.x = x` 삽입을 직접 수행해야 함 (#1471).
            var pp = try self.visitParamsCollectProperties(params_list_old);
            defer pp.prop_names.deinit(self.allocator);
            var param_lowering: ?es2015_params.ES2015Params(Transformer).LowerResult = null;
            if (es2015_params.ES2015Params(Transformer).hasDefaultOrRest(self, pp.new_params)) {
                param_lowering = try es2015_params.ES2015Params(Transformer).lowerParamsPass2(self, pp.new_params, span);
            }
            defer if (param_lowering) |*lr| lr.body_stmts.deinit(self.allocator);

            // new.target: class constructor → function_named (ES5 class 변환 후 일반 함수)
            const saved_new_target_ctx = self.new_target_ctx;
            if (self.options.unsupported.new_target) {
                self.new_target_ctx = .{ .function_named = self.ast.getNode(name).data.string_ref };
            }
            defer self.new_target_ctx = saved_new_target_ctx;

            var new_body = try visitMethodBody(self, body_idx, span);

            const lowered_params = if (param_lowering) |lr| lr.new_params else pp.new_params;
            const param_stmts = if (param_lowering) |lr| lr.body_stmts.items else &[_]NodeIndex{};

            if (is_derived) {
                // derived class 의 parameter property `this.x = x` 는 super() 이후에 와야 한다.
                // super() 가 Reflect.construct 로 생성한 새 객체가 인스턴스이고, `this` 는 호출
                // receiver 라 super() 전 할당은 새 인스턴스에 반영되지 않는다.
                // instance_fields 와 합쳐 postProcessDerivedConstructorBody 에서 _this 별칭으로 emit.
                if (pp.prop_names.items.len > 0 and !new_body.isNone()) {
                    const pp_stmts_list = try self.buildParameterPropertyStatements(pp.prop_names.items);
                    const pp_stmts = self.ast.extra_data.items[pp_stmts_list.start .. pp_stmts_list.start + pp_stmts_list.len];
                    const scratch_top = self.scratch.items.len;
                    defer self.scratch.shrinkRetainingCapacity(scratch_top);
                    for (pp_stmts) |raw_idx| try self.scratch.append(self.allocator, @enumFromInt(raw_idx));
                    for (instance_fields) |f| try self.scratch.append(self.allocator, f);
                    try transformDerivedConstructorReturns(self, new_body);
                    new_body = try postProcessDerivedConstructorBody(self, new_body, param_stmts, self.scratch.items[scratch_top..], span);
                } else {
                    try transformDerivedConstructorReturns(self, new_body);
                    new_body = try postProcessDerivedConstructorBody(self, new_body, param_stmts, instance_fields, span);
                }
            } else if ((param_stmts.len > 0 or pp.prop_names.items.len > 0) and !new_body.isNone()) {
                const scratch_top = self.scratch.items.len;
                defer self.scratch.shrinkRetainingCapacity(scratch_top);
                for (param_stmts) |stmt| try self.scratch.append(self.allocator, stmt);
                if (pp.prop_names.items.len > 0) {
                    const pp_stmts_list = try self.buildParameterPropertyStatements(pp.prop_names.items);
                    const pp_stmts = self.ast.extra_data.items[pp_stmts_list.start .. pp_stmts_list.start + pp_stmts_list.len];
                    for (pp_stmts) |raw_idx| try self.scratch.append(self.allocator, @enumFromInt(raw_idx));
                }
                new_body = try self.prependStatementsToBody(new_body, self.scratch.items[scratch_top..]);
            }

            const none = @intFromEnum(NodeIndex.none);
            const new_params_node = try self.ast.addFormalParameters(lowered_params, span);
            const func_extra = try self.ast.addExtras(&.{
                @intFromEnum(name),
                @intFromEnum(new_params_node),
                @intFromEnum(new_body),
                0, // flags (no async/generator)
                none, // return_type
            });
            return self.ast.addNode(.{
                .tag = .function_declaration,
                .span = span,
                .data = .{ .extra = func_extra },
            });
        }

        pub fn buildAssertThisInitialized(self: *Transformer, span: Span) Transformer.Error!NodeIndex {
            const helper = try es_helpers.makeRuntimeHelperRef(self, "__assertThisInitialized");
            const this_ref = try es_helpers.makeIdentifierRef(self, "_this");
            self.runtime_helpers.derived_constructor = true;
            return es_helpers.makeCallExpr(self, helper, &.{this_ref}, span);
        }

        fn buildPossibleConstructorReturn(self: *Transformer, value: NodeIndex, span: Span) Transformer.Error!NodeIndex {
            const helper = try es_helpers.makeRuntimeHelperRef(self, "__possibleConstructorReturn");
            const this_ref = try es_helpers.makeIdentifierRef(self, "_this");
            self.runtime_helpers.derived_constructor = true;
            return es_helpers.makeCallExpr(self, helper, &.{ value, this_ref }, span);
        }

        /// derived constructor의 직접 return을 `__possibleConstructorReturn(value, _this)`로 감싼다.
        /// 중첩 함수/클래스의 return은 별도 this 바인딩이므로 건드리지 않는다.
        fn transformDerivedConstructorReturns(self: *Transformer, idx: NodeIndex) Transformer.Error!void {
            if (idx.isNone()) return;
            const node = self.ast.getNode(idx);

            switch (node.tag) {
                .function_expression,
                .function_declaration,
                .function,
                .arrow_function_expression,
                .class_expression,
                .class_declaration,
                .method_definition,
                => return,
                .return_statement => {
                    const operand = node.data.unary.operand;
                    const replacement = if (operand.isNone())
                        try buildAssertThisInitialized(self, node.span)
                    else
                        try buildPossibleConstructorReturn(self, operand, node.span);
                    self.ast.nodes.items[@intFromEnum(idx)].data.unary.operand = replacement;
                    return;
                },
                else => {},
            }

            switch (node.tag.dataKind()) {
                .leaf => return,
                .unary => {
                    try transformDerivedConstructorReturns(self, node.data.unary.operand);
                },
                .binary => {
                    try transformDerivedConstructorReturns(self, node.data.binary.left);
                    try transformDerivedConstructorReturns(self, node.data.binary.right);
                },
                .ternary => {
                    try transformDerivedConstructorReturns(self, node.data.ternary.a);
                    try transformDerivedConstructorReturns(self, node.data.ternary.b);
                    try transformDerivedConstructorReturns(self, node.data.ternary.c);
                },
                .list => {
                    var iter = self.ast.iterateExtraList(node.data.list);
                    while (iter.next()) |child| {
                        try transformDerivedConstructorReturns(self, child);
                    }
                },
                .extra => {
                    const e = node.data.extra;
                    for (node.tag.extraChildOffsets()) |offset| {
                        try transformDerivedConstructorReturns(self, self.ast.readExtraNode(e, offset));
                    }
                    for (node.tag.extraListOffsets()) |list_offset| {
                        const start = self.ast.readExtra(e, list_offset[0]);
                        const len = self.ast.readExtra(e, list_offset[1]);
                        var iter = self.ast.iterateExtraList(.{ .start = start, .len = len });
                        while (iter.next()) |child| {
                            try transformDerivedConstructorReturns(self, child);
                        }
                    }
                },
            }
        }

        /// derived constructor body를 후처리:
        /// 1. body 앞에 var _this; 선언 추가
        /// 2. super() 직후에 instance fields 삽입
        /// 3. 나머지 constructor body
        /// 4. body 끝에 return __assertThisInitialized(_this); 추가
        ///
        /// ES6 스펙: class fields는 super() 직후, constructor body 이전에 초기화.
        /// lowerSuperCall이 _this = __callSuper(...) 대입식을 생성하므로,
        /// 해당 대입식을 포함하는 statement를 찾아 그 직후에 fields를 삽입한다.
        fn postProcessDerivedConstructorBody(self: *Transformer, body: NodeIndex, param_stmts: []const NodeIndex, instance_fields: []const NodeIndex, span: Span) Transformer.Error!NodeIndex {
            const body_node = self.ast.getNode(body);
            if (body_node.tag != .block_statement) return body;

            const stmts_list = body_node.data.list;
            // extra_data.items slice를 먼저 캡처하면, buildVarDecl 등이 extra_data를
            // grow시켜 재할당하면 dangling pointer가 됨.
            // 따라서 인덱스만 저장하고, 사용할 때 다시 접근한다.
            const stmts_start = stmts_list.start;
            const stmts_len = stmts_list.len;

            const scratch_top = self.scratch.items.len;
            defer self.scratch.shrinkRetainingCapacity(scratch_top);

            // var _newTarget = this.constructor; — derived constructor body 시작에서 NewTarget 캡쳐.
            // arrow 안의 super() 도 closure 로 동일 값을 보존하고, multi-level chain 에서
            // this.constructor 가 항상 top-level NewTarget 으로 평가돼 prototype propagation 이 정확.
            try self.scratch.append(
                self.allocator,
                try self.buildVarDecl("_newTarget", try es_helpers.makeThisDotConstructor(self, span), span),
            );

            // var _this; (초기화 없는 선언) — extra_data grow 가능
            try self.scratch.append(self.allocator, try self.buildVarDecl("_this", .none, span));

            for (param_stmts) |stmt| {
                if (containsSuperCallAssignment(self, stmt)) {
                    try self.scratch.append(self.allocator, try insertInstanceFieldsAfterSuper(self, stmt, instance_fields, span));
                } else {
                    try self.scratch.append(self.allocator, stmt);
                }
            }

            // realloc-safe 순회 — 위 line 2527 의 "인덱스만 저장, 사용 시 재접근" 정책 적용 (#2422).
            var stmts_iter = self.ast.iterateExtraList(.{ .start = stmts_start, .len = stmts_len });
            while (stmts_iter.next()) |stmt_idx| {
                if (containsSuperCallAssignment(self, stmt_idx)) {
                    try self.scratch.append(self.allocator, try insertInstanceFieldsAfterSuper(self, stmt_idx, instance_fields, span));
                } else {
                    try self.scratch.append(self.allocator, stmt_idx);
                }
            }

            // return __assertThisInitialized(_this);
            try self.scratch.append(self.allocator, try self.ast.addNode(.{
                .tag = .return_statement,
                .span = span,
                .data = .{ .unary = .{ .operand = try buildAssertThisInitialized(self, span), .flags = 0 } },
            }));

            const new_list = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
            return self.ast.addNode(.{
                .tag = .block_statement,
                .span = span,
                .data = .{ .list = new_list },
            });
        }

        fn appendInstanceFields(self: *Transformer, instance_fields: []const NodeIndex, span: Span) Transformer.Error!void {
            for (instance_fields) |field_stmt| {
                try self.scratch.append(self.allocator, try replaceThisWithThisAlias(self, field_stmt, span));
            }
        }

        /// instance fields는 `super()`가 실제 실행된 경로에서만 초기화되어야 한다.
        /// 따라서 `if (cond) super();` 같은 분기에서는 if 바깥이 아니라 super() statement
        /// 바로 뒤의 같은 control-flow 경로에 삽입한다.
        fn insertInstanceFieldsAfterSuper(self: *Transformer, stmt_idx: NodeIndex, instance_fields: []const NodeIndex, span: Span) Transformer.Error!NodeIndex {
            if (stmt_idx.isNone() or instance_fields.len == 0) return stmt_idx;
            const stmt = self.ast.getNode(stmt_idx);

            if (isSuperCallAssignmentStatement(self, stmt_idx)) {
                const scratch_top = self.scratch.items.len;
                defer self.scratch.shrinkRetainingCapacity(scratch_top);

                try self.scratch.append(self.allocator, stmt_idx);
                try appendInstanceFields(self, instance_fields, span);

                const new_list = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
                return self.ast.addNode(.{
                    .tag = .block_statement,
                    .span = stmt.span,
                    .data = .{ .list = new_list },
                });
            }

            switch (stmt.tag) {
                .block_statement => {
                    const list = stmt.data.list;
                    const scratch_top = self.scratch.items.len;
                    defer self.scratch.shrinkRetainingCapacity(scratch_top);

                    var iter = self.ast.iterateExtraList(list);
                    while (iter.next()) |child_idx| {
                        if (isSuperCallAssignmentStatement(self, child_idx)) {
                            try self.scratch.append(self.allocator, child_idx);
                            try appendInstanceFields(self, instance_fields, span);
                        } else if (containsSuperCallAssignment(self, child_idx)) {
                            try self.scratch.append(self.allocator, try insertInstanceFieldsAfterSuper(self, child_idx, instance_fields, span));
                        } else {
                            try self.scratch.append(self.allocator, child_idx);
                        }
                    }

                    const new_list = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
                    return self.ast.addNode(.{
                        .tag = .block_statement,
                        .span = stmt.span,
                        .data = .{ .list = new_list },
                    });
                },
                .if_statement => {
                    const consequent = if (containsSuperCallAssignment(self, stmt.data.ternary.b))
                        try insertInstanceFieldsAfterSuper(self, stmt.data.ternary.b, instance_fields, span)
                    else
                        stmt.data.ternary.b;
                    const alternate = if (containsSuperCallAssignment(self, stmt.data.ternary.c))
                        try insertInstanceFieldsAfterSuper(self, stmt.data.ternary.c, instance_fields, span)
                    else
                        stmt.data.ternary.c;

                    return self.ast.addNode(.{
                        .tag = .if_statement,
                        .span = stmt.span,
                        .data = .{ .ternary = .{
                            .a = stmt.data.ternary.a,
                            .b = consequent,
                            .c = alternate,
                        } },
                    });
                },
                // `const result = super(...)` / `let r = super(...)` 같은 declarator-init super 케이스.
                // 선언문 자체를 살린 뒤 같은 control-flow 위치에 instance field init 을 잇도록 block 으로 감싼다.
                .variable_declaration => {
                    const scratch_top = self.scratch.items.len;
                    defer self.scratch.shrinkRetainingCapacity(scratch_top);

                    try self.scratch.append(self.allocator, stmt_idx);
                    try appendInstanceFields(self, instance_fields, span);

                    const new_list = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
                    return self.ast.addNode(.{
                        .tag = .block_statement,
                        .span = stmt.span,
                        .data = .{ .list = new_list },
                    });
                },
                .return_statement => {
                    return self.ast.addNode(.{
                        .tag = .return_statement,
                        .span = stmt.span,
                        .data = .{ .unary = .{
                            .operand = try injectInstanceFieldsAfterSuperExpr(self, stmt.data.unary.operand, instance_fields, span),
                            .flags = 0,
                        } },
                    });
                },
                else => return stmt_idx,
            }
        }

        // NOTE: 모든 list iteration 은 인덱스 기반 (`while (i < len)`) — 재귀
        // injectInstanceFieldsAfterSuperExpr 호출이 addNode/addExtras 로 extra_data 를
        // grow 시킬 수 있어 캡처된 slice 가 realloc 후 invalid 해진다 (#2422).
        fn injectInstanceFieldsAfterSuperExpr(self: *Transformer, expr_idx: NodeIndex, instance_fields: []const NodeIndex, span: Span) Transformer.Error!NodeIndex {
            if (expr_idx.isNone() or instance_fields.len == 0) return expr_idx;
            // sub-tree 안에 super-call 이 없으면 AST 재구성 비용을 들일 필요가 없다.
            // `containsSuperCallAssignment` 는 read-only 라 비용이 작다.
            if (!containsSuperCallAssignment(self, expr_idx)) return expr_idx;
            const node = self.ast.getNode(expr_idx);

            if (isSuperThisAssignment(self, node)) {
                const scratch_top = self.scratch.items.len;
                defer self.scratch.shrinkRetainingCapacity(scratch_top);

                try self.scratch.append(self.allocator, expr_idx);
                for (instance_fields) |field_stmt| {
                    const replaced = try replaceThisWithThisAlias(self, field_stmt, span);
                    const field_node = self.ast.getNode(replaced);
                    if (field_node.tag == .expression_statement) {
                        try self.scratch.append(self.allocator, field_node.data.unary.operand);
                    } else {
                        try self.scratch.append(self.allocator, replaced);
                    }
                }
                try self.scratch.append(self.allocator, try es_helpers.makeIdentifierRef(self, "_this"));

                const list = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
                const seq = try self.ast.addNode(.{
                    .tag = .sequence_expression,
                    .span = node.span,
                    .data = .{ .list = list },
                });
                return es_helpers.makeParenExpr(self, seq, node.span);
            }

            switch (node.tag) {
                .parenthesized_expression => return es_helpers.makeParenExpr(
                    self,
                    try injectInstanceFieldsAfterSuperExpr(self, node.data.unary.operand, instance_fields, span),
                    node.span,
                ),
                .sequence_expression, .array_expression => {
                    const scratch_top = self.scratch.items.len;
                    defer self.scratch.shrinkRetainingCapacity(scratch_top);
                    var iter = self.ast.iterateExtraList(node.data.list);
                    while (iter.next()) |child| {
                        try self.scratch.append(self.allocator, try injectInstanceFieldsAfterSuperExpr(self, child, instance_fields, span));
                    }
                    const new_list = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
                    return self.ast.addNode(.{ .tag = node.tag, .span = node.span, .data = .{ .list = new_list } });
                },
                .call_expression, .new_expression => {
                    const e = node.data.extra;
                    const callee = self.ast.readExtra(e, 0);
                    const args_start = self.ast.readExtra(e, 1);
                    const args_len = self.ast.readExtra(e, 2);
                    const flags = self.ast.readExtra(e, 3);
                    const scratch_top = self.scratch.items.len;
                    defer self.scratch.shrinkRetainingCapacity(scratch_top);
                    var iter = self.ast.iterateExtraList(.{ .start = args_start, .len = args_len });
                    while (iter.next()) |arg| {
                        try self.scratch.append(self.allocator, try injectInstanceFieldsAfterSuperExpr(self, arg, instance_fields, span));
                    }
                    const args = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
                    const new_extra = try self.ast.addExtras(&.{ callee, args.start, args.len, flags });
                    return self.ast.addNode(.{ .tag = node.tag, .span = node.span, .data = .{ .extra = new_extra } });
                },
                .static_member_expression, .computed_member_expression => {
                    const e = node.data.extra;
                    const new_obj = try injectInstanceFieldsAfterSuperExpr(self, self.ast.readExtraNode(e, 0), instance_fields, span);
                    const new_prop = try injectInstanceFieldsAfterSuperExpr(self, self.ast.readExtraNode(e, 1), instance_fields, span);
                    const member_flags = self.ast.readExtra(e, 2);
                    const new_extra = try self.ast.addExtras(&.{
                        @intFromEnum(new_obj),
                        @intFromEnum(new_prop),
                        member_flags,
                    });
                    return self.ast.addNode(.{ .tag = node.tag, .span = node.span, .data = .{ .extra = new_extra } });
                },
                .object_expression => {
                    const scratch_top = self.scratch.items.len;
                    defer self.scratch.shrinkRetainingCapacity(scratch_top);
                    var iter = self.ast.iterateExtraList(node.data.list);
                    while (iter.next()) |prop_idx| {
                        // 부작용 없는 prop 은 그대로 통과 — 매번 복제하면 N props 중 1 개만 super 가 있어도
                        // 전체 list 가 새로 만들어지는 낭비가 발생.
                        if (!containsSuperCallAssignment(self, prop_idx)) {
                            try self.scratch.append(self.allocator, prop_idx);
                            continue;
                        }
                        try self.scratch.append(self.allocator, try injectInstanceFieldsAfterSuperExpr(self, prop_idx, instance_fields, span));
                    }
                    const new_list = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
                    return self.ast.addNode(.{ .tag = .object_expression, .span = node.span, .data = .{ .list = new_list } });
                },
                .object_property => return self.ast.addNode(.{
                    .tag = .object_property,
                    .span = node.span,
                    .data = .{ .binary = .{
                        .left = try injectInstanceFieldsAfterSuperExpr(self, node.data.binary.left, instance_fields, span),
                        .right = try injectInstanceFieldsAfterSuperExpr(self, node.data.binary.right, instance_fields, span),
                        .flags = node.data.binary.flags,
                    } },
                }),
                .logical_expression => return self.ast.addNode(.{
                    .tag = .logical_expression,
                    .span = node.span,
                    .data = .{ .binary = .{
                        .left = try injectInstanceFieldsAfterSuperExpr(self, node.data.binary.left, instance_fields, span),
                        .right = try injectInstanceFieldsAfterSuperExpr(self, node.data.binary.right, instance_fields, span),
                        .flags = node.data.binary.flags,
                    } },
                }),
                .assignment_expression => return self.ast.addNode(.{
                    .tag = .assignment_expression,
                    .span = node.span,
                    .data = .{ .binary = .{
                        .left = try injectInstanceFieldsAfterSuperExpr(self, node.data.binary.left, instance_fields, span),
                        .right = try injectInstanceFieldsAfterSuperExpr(self, node.data.binary.right, instance_fields, span),
                        .flags = node.data.binary.flags,
                    } },
                }),
                .spread_element, .computed_property_key => return self.ast.addNode(.{
                    .tag = node.tag,
                    .span = node.span,
                    .data = .{ .unary = .{
                        .operand = try injectInstanceFieldsAfterSuperExpr(self, node.data.unary.operand, instance_fields, span),
                        .flags = node.data.unary.flags,
                    } },
                }),
                .conditional_expression => return self.ast.addNode(.{
                    .tag = .conditional_expression,
                    .span = node.span,
                    .data = .{ .ternary = .{
                        .a = node.data.ternary.a,
                        .b = try injectInstanceFieldsAfterSuperExpr(self, node.data.ternary.b, instance_fields, span),
                        .c = try injectInstanceFieldsAfterSuperExpr(self, node.data.ternary.c, instance_fields, span),
                    } },
                }),
                else => return expr_idx,
            }
        }

        fn isSuperThisAssignment(self: *Transformer, node: Node) bool {
            if (node.tag != .assignment_expression) return false;
            const left = self.ast.getNode(node.data.binary.left);
            if (left.tag != .identifier_reference and left.tag != .assignment_target_identifier) return false;
            if (!std.mem.eql(u8, self.ast.getText(left.data.string_ref), "_this")) return false;
            const right = self.ast.getNode(node.data.binary.right);
            return isSuperCallLike(self, right);
        }

        fn isSuperCallAssignmentStatement(self: *Transformer, node_idx: NodeIndex) bool {
            if (node_idx.isNone()) return false;
            const node = self.ast.getNode(node_idx);
            if (node.tag != .expression_statement) return false;
            return containsSuperCallAssignment(self, node.data.unary.operand);
        }

        /// lowerSuperCall이 생성하는 `_this = __callSuper(...)` 대입을 포함하는지 재귀 탐색.
        /// LHS=bare identifier + RHS=call_expression 패턴으로 매칭.
        /// (member expression `_this.x = ...` 과 구분)
        fn containsSuperCallAssignment(self: *Transformer, node_idx: NodeIndex) bool {
            if (node_idx.isNone()) return false;
            const node = self.ast.getNode(node_idx);

            switch (node.tag) {
                .expression_statement => {
                    const expr_idx = node.data.unary.operand;
                    if (expr_idx.isNone()) return false;
                    return containsSuperCallAssignment(self, expr_idx);
                },
                .return_statement => {
                    return containsSuperCallAssignment(self, node.data.unary.operand);
                },
                .parenthesized_expression => {
                    return containsSuperCallAssignment(self, node.data.unary.operand);
                },
                .sequence_expression, .array_expression => {
                    const list = node.data.list;
                    for (self.ast.extra_data.items[list.start .. list.start + list.len]) |raw_idx| {
                        if (containsSuperCallAssignment(self, @enumFromInt(raw_idx))) return true;
                    }
                    return false;
                },
                .variable_declaration => {
                    const start = self.ast.extra_data.items[node.data.extra + 1];
                    const len = self.ast.extra_data.items[node.data.extra + 2];
                    for (self.ast.extra_data.items[start .. start + len]) |raw_idx| {
                        if (containsSuperCallAssignment(self, @enumFromInt(raw_idx))) return true;
                    }
                    return false;
                },
                .variable_declarator => {
                    const init: NodeIndex = @enumFromInt(self.ast.extra_data.items[node.data.extra + 2]);
                    return containsSuperCallAssignment(self, init);
                },
                .call_expression, .new_expression => {
                    if (isSuperCallLike(self, node)) return true;
                    const e = node.data.extra;
                    const args_start = self.ast.extra_data.items[e + 1];
                    const args_len = self.ast.extra_data.items[e + 2];
                    for (self.ast.extra_data.items[args_start .. args_start + args_len]) |raw_idx| {
                        if (containsSuperCallAssignment(self, @enumFromInt(raw_idx))) return true;
                    }
                    return false;
                },
                .static_member_expression, .computed_member_expression => {
                    const e = node.data.extra;
                    return containsSuperCallAssignment(self, @enumFromInt(self.ast.extra_data.items[e])) or
                        containsSuperCallAssignment(self, @enumFromInt(self.ast.extra_data.items[e + 1]));
                },
                .object_expression => {
                    const list = node.data.list;
                    for (self.ast.extra_data.items[list.start .. list.start + list.len]) |raw_idx| {
                        if (containsSuperCallAssignment(self, @enumFromInt(raw_idx))) return true;
                    }
                    return false;
                },
                // object_property: key(left) 와 value(right) 둘 다 super-call 을 품을 수 있다
                // (`{ [super(1)]: 'x' }` 처럼 computed key 안에 들어간 경우 포함).
                .object_property => {
                    return containsSuperCallAssignment(self, node.data.binary.left) or
                        containsSuperCallAssignment(self, node.data.binary.right);
                },
                .logical_expression => {
                    return containsSuperCallAssignment(self, node.data.binary.left) or
                        containsSuperCallAssignment(self, node.data.binary.right);
                },
                .spread_element, .computed_property_key => {
                    return containsSuperCallAssignment(self, node.data.unary.operand);
                },
                .assignment_expression => {
                    const left = self.ast.getNode(node.data.binary.left);
                    const right = self.ast.getNode(node.data.binary.right);
                    if ((left.tag == .identifier_reference or left.tag == .assignment_target_identifier) and isSuperCallLike(self, right)) {
                        return true;
                    }
                    return containsSuperCallAssignment(self, node.data.binary.left) or
                        containsSuperCallAssignment(self, node.data.binary.right);
                },
                .if_statement, .conditional_expression => {
                    if (containsSuperCallAssignment(self, node.data.ternary.b)) return true;
                    if (containsSuperCallAssignment(self, node.data.ternary.c)) return true;
                    return false;
                },
                .block_statement => {
                    const list = node.data.list;
                    for (self.ast.extra_data.items[list.start .. list.start + list.len]) |raw_idx| {
                        if (containsSuperCallAssignment(self, @enumFromInt(raw_idx))) return true;
                    }
                    return false;
                },
                else => return false,
            }
        }

        /// `super(...)` 또는 lowering 후의 `_this = __callSuper(...)` 같은 super 호출 패턴인지 판별.
        /// raw super 호출은 lowering 전, helper 호출은 lowering 후 형태.
        fn isSuperCallLike(self: *Transformer, node: Node) bool {
            if (node.tag != .call_expression) return false;
            const callee_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[node.data.extra]);
            if (callee_idx.isNone()) return false;
            const callee = self.ast.getNode(callee_idx);
            if (callee.tag == .super_expression) return true;
            if (callee.tag != .identifier_reference) return false;
            const name = self.ast.getText(callee.data.string_ref);
            return std.mem.eql(u8, name, "__callSuper") or
                std.mem.eql(u8, name, helper_names.NAMES.CALL_SUPER_MIN);
        }

        /// 빈 function declaration (constructor가 없는 경우)
        pub fn buildEmptyFunction(self: *Transformer, name: NodeIndex, span: Span) Transformer.Error!NodeIndex {
            // 빈 body
            const empty_list = try self.ast.addNodeList(&.{});
            const empty_body = try self.ast.addNode(.{
                .tag = .block_statement,
                .span = span,
                .data = .{ .list = empty_list },
            });

            const empty_params = try self.ast.addNodeList(&.{});
            const empty_params_node = try self.ast.addFormalParameters(empty_params, span);
            const none = @intFromEnum(NodeIndex.none);
            const func_extra = try self.ast.addExtras(&.{
                @intFromEnum(name),
                @intFromEnum(empty_params_node),
                @intFromEnum(empty_body),
                0,
                none,
            });
            return self.ast.addNode(.{
                .tag = .function_declaration,
                .span = span,
                .data = .{ .extra = func_extra },
            });
        }

        /// extends가 있고 constructor가 없을 때 기본 constructor 생성:
        /// instance_fields가 없으면: function Child() { var _newTarget = this.constructor; return __callSuper(_super, arguments, _newTarget); }
        /// instance_fields가 있으면: function Child() { var _newTarget = this.constructor; var _this = __callSuper(_super, arguments, _newTarget); <fields on _this>; return _this; }
        pub fn buildDefaultSuperConstructor(self: *Transformer, name: NodeIndex, super_class_span: Span, instance_fields: []const NodeIndex, span: Span) Transformer.Error!NodeIndex {
            const call_super_ref = try es_helpers.makeRuntimeHelperRef(self, "__callSuper");
            const parent_ref = try es_helpers.makeIdentifierRefFromSpan(self, super_class_span);
            const args_ref = try es_helpers.makeIdentifierRef(self, "arguments");
            const new_target_ref = try es_helpers.makeIdentifierRef(self, "_newTarget");
            const call_super = try es_helpers.makeCallExpr(self, call_super_ref, &.{ parent_ref, args_ref, new_target_ref }, span);

            self.runtime_helpers.call_super = true;

            const scratch_top = self.scratch.items.len;
            defer self.scratch.shrinkRetainingCapacity(scratch_top);

            // var _newTarget = this.constructor;
            // multi-level chain 에서도 항상 top NewTarget 으로 평가 → prototype propagation 정확.
            try self.scratch.append(
                self.allocator,
                try self.buildVarDecl("_newTarget", try es_helpers.makeThisDotConstructor(self, span), span),
            );

            if (instance_fields.len > 0) {
                // var _this = __callSuper(_super, arguments, _newTarget);
                try self.scratch.append(self.allocator, try self.buildVarDecl("_this", call_super, span));

                // instance fields: this → _this 치환된 버전 사용
                // instance_fields는 이미 this.x = ... 형태로 생성되었으므로
                // this_expression을 _this로 교체해야 한다.
                // 현재는 transformer가 this_expression을 직접 생성하므로
                // _this 식별자로 새로 생성한다.
                for (instance_fields) |field_stmt| {
                    try self.scratch.append(self.allocator, try replaceThisWithThisAlias(self, field_stmt, span));
                }

                // return _this;
                const this_ref = try es_helpers.makeIdentifierRef(self, "_this");
                try self.scratch.append(self.allocator, try self.ast.addNode(.{
                    .tag = .return_statement,
                    .span = span,
                    .data = .{ .unary = .{ .operand = this_ref, .flags = 0 } },
                }));
            } else {
                // return __callSuper(_super, arguments, _newTarget);
                try self.scratch.append(self.allocator, try self.ast.addNode(.{
                    .tag = .return_statement,
                    .span = span,
                    .data = .{ .unary = .{ .operand = call_super, .flags = 0 } },
                }));
            }

            const body_list = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
            const body = try self.ast.addNode(.{
                .tag = .block_statement,
                .span = span,
                .data = .{ .list = body_list },
            });

            const empty_params = try self.ast.addNodeList(&.{});
            const empty_params_node = try self.ast.addFormalParameters(empty_params, span);
            const none = @intFromEnum(NodeIndex.none);
            const func_extra = try self.ast.addExtras(&.{
                @intFromEnum(name),
                @intFromEnum(empty_params_node),
                @intFromEnum(body),
                0,
                none,
            });
            return self.ast.addNode(.{
                .tag = .function_declaration,
                .span = span,
                .data = .{ .extra = func_extra },
            });
        }

        /// statement 안의 this_expression을 _this identifier로 교체한 복사본 생성.
        /// instance field init에서 사용: this.x = v → _this.x = v
        fn replaceThisWithThisAlias(self: *Transformer, stmt_idx: NodeIndex, span: Span) Transformer.Error!NodeIndex {
            _ = span;
            const stmt = self.ast.getNode(stmt_idx);
            if (stmt.tag != .expression_statement) return stmt_idx;

            const expr_idx = stmt.data.unary.operand;
            if (expr_idx.isNone()) return stmt_idx;
            const expr = self.ast.getNode(expr_idx);

            // assignment: this.x = v → _this.x = v (값에 this가 있으면 _this로 교체)
            if (expr.tag == .assignment_expression) {
                const left = expr.data.binary.left;
                const right = expr.data.binary.right;
                const new_left = try replaceThisInExpr(self, left);
                const new_right = try replaceThisInExpr(self, right);
                if (@intFromEnum(new_left) == @intFromEnum(left) and @intFromEnum(new_right) == @intFromEnum(right)) return stmt_idx;
                const new_assign = try self.ast.addNode(.{
                    .tag = .assignment_expression,
                    .span = expr.span,
                    .data = .{ .binary = .{ .left = new_left, .right = new_right, .flags = expr.data.binary.flags } },
                });
                return self.ast.addNode(.{
                    .tag = .expression_statement,
                    .span = stmt.span,
                    .data = .{ .unary = .{ .operand = new_assign, .flags = 0 } },
                });
            }

            // call: __classPrivateMethodInit(this, ...) → __classPrivateMethodInit(_this, ...)
            if (expr.tag == .call_expression) {
                const new_call = try replaceThisInExpr(self, expr_idx);
                if (@intFromEnum(new_call) == @intFromEnum(expr_idx)) return stmt_idx;
                return self.ast.addNode(.{
                    .tag = .expression_statement,
                    .span = stmt.span,
                    .data = .{ .unary = .{ .operand = new_call, .flags = 0 } },
                });
            }

            return stmt_idx;
        }

        /// 식 안의 this_expression을 _this로 교체. call_expression(fn, [this, ...]) 패턴도 처리.
        fn replaceThisInExpr(self: *Transformer, idx: NodeIndex) Transformer.Error!NodeIndex {
            if (idx.isNone()) return idx;
            const node = self.ast.getNode(idx);

            if (node.tag == .this_expression) {
                return es_helpers.makeIdentifierRef(self, "_this");
            }

            // static_member_expression: extra = [object, property, flags]
            if (node.tag == .static_member_expression) {
                const e = node.data.extra;
                const obj_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[e]);
                const new_obj = try replaceThisInExpr(self, obj_idx);
                if (@intFromEnum(new_obj) == @intFromEnum(obj_idx)) return idx;
                const prop = self.ast.extra_data.items[e + 1];
                const flags = self.ast.extra_data.items[e + 2];
                const new_extra = try self.ast.addExtras(&.{
                    @intFromEnum(new_obj), prop, flags,
                });
                return self.ast.addNode(.{
                    .tag = .static_member_expression,
                    .span = node.span,
                    .data = .{ .extra = new_extra },
                });
            }

            // call_expression: extra = [callee, args_start, args_len, flags]
            // __classPrivateMethodInit(this, _bark) → __classPrivateMethodInit(_this, _bark)
            if (node.tag == .call_expression) {
                const e = node.data.extra;
                const callee: NodeIndex = @enumFromInt(self.ast.extra_data.items[e]);
                const args_start = self.ast.extra_data.items[e + 1];
                const args_len = self.ast.extra_data.items[e + 2];
                const flags = self.ast.extra_data.items[e + 3];

                // callee와 인자 중 this_expression을 _this로 교체
                const new_callee = try replaceThisInExpr(self, callee);
                const scratch_top = self.scratch.items.len;
                defer self.scratch.shrinkRetainingCapacity(scratch_top);
                var changed = @intFromEnum(new_callee) != @intFromEnum(callee);
                for (0..args_len) |i| {
                    const raw_arg = self.ast.extra_data.items[args_start + i];
                    const arg_idx: NodeIndex = @enumFromInt(raw_arg);
                    const new_arg = try replaceThisInExpr(self, arg_idx);
                    if (@intFromEnum(new_arg) != @intFromEnum(arg_idx)) changed = true;
                    try self.scratch.append(self.allocator, new_arg);
                }
                if (!changed) return idx;
                const new_args = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
                const new_extra = try self.ast.addExtras(&.{
                    @intFromEnum(new_callee), new_args.start, new_args.len, flags,
                });
                return self.ast.addNode(.{
                    .tag = .call_expression,
                    .span = node.span,
                    .data = .{ .extra = new_extra },
                });
            }

            return idx;
        }

        /// __extends(Child, Parent) expression_statement 생성.
        /// child_old_idx, parent_old_idx: 원본 AST 노드 인덱스 (symbol_id 전파용).
        pub fn buildExtendsCall(self: *Transformer, child_span: Span, parent_span: Span, child_old_idx: NodeIndex, parent_old_idx: NodeIndex, span: Span) Transformer.Error!NodeIndex {
            const extends_ref = try es_helpers.makeRuntimeHelperRef(self, "__extends");
            const child_ref = try self.makeIdentifierRefWithSymbol(child_span, child_old_idx);
            const parent_ref = try self.makeIdentifierRefWithSymbol(parent_span, parent_old_idx);
            const call = try es_helpers.makeCallExpr(self, extends_ref, &.{ child_ref, parent_ref }, span);

            return self.ast.addNode(.{
                .tag = .expression_statement,
                .span = span,
                .data = .{ .unary = .{ .operand = call, .flags = 0 } },
            });
        }

        /// 메서드 body를 방문하면서 arrow this/arguments 캡처를 관리.
        /// visitFunction과 동일한 save/restore/prepend 로직.
        pub fn visitMethodBody(self: *Transformer, body_idx: NodeIndex, span: Span) Transformer.Error!NodeIndex {
            return visitMethodBodyWithCtx(self, body_idx, span, null);
        }

        /// visitMethodBody + new.target 컨텍스트 지정
        pub fn visitMethodBodyWithCtx(self: *Transformer, body_idx: NodeIndex, span: Span, nt_ctx: ?Transformer.NewTargetCtx) Transformer.Error!NodeIndex {
            // arrow this state save/restore (일반 함수는 자체 this 바인딩)
            const saved_arrow_depth = self.arrow_this_depth;
            const saved_needs_this = self.needs_this_var;
            const saved_needs_args = self.needs_arguments_var;
            self.arrow_this_depth = 0;
            self.needs_this_var = false;
            self.needs_arguments_var = false;

            // new.target context
            const saved_nt = self.new_target_ctx;
            if (nt_ctx) |ctx| self.new_target_ctx = ctx;
            defer self.new_target_ctx = saved_nt;

            var new_body = try self.visitNode(body_idx);

            // arrow가 this/arguments를 사용했으면 var _this = this; 등 삽입
            if (self.options.unsupported.arrow and !new_body.isNone() and
                (self.needs_this_var or self.needs_arguments_var))
            {
                var capture_stmts: [2]NodeIndex = undefined;
                var capture_count: usize = 0;

                if (self.needs_this_var) {
                    const this_init = try self.ast.addNode(.{
                        .tag = .this_expression,
                        .span = span,
                        .data = .{ .none = 0 },
                    });
                    capture_stmts[capture_count] = try self.buildVarDecl("_this", this_init, span);
                    capture_count += 1;
                }
                if (self.needs_arguments_var) {
                    const args_span = try self.ast.addString("arguments");
                    const args_init = try self.ast.addNode(.{
                        .tag = .identifier_reference,
                        .span = args_span,
                        .data = .{ .string_ref = args_span },
                    });
                    capture_stmts[capture_count] = try self.buildVarDecl("_arguments", args_init, span);
                    capture_count += 1;
                }

                new_body = try self.prependStatementsToBody(new_body, capture_stmts[0..capture_count]);
            }

            self.arrow_this_depth = saved_arrow_depth;
            self.needs_this_var = saved_needs_this;
            self.needs_arguments_var = saved_needs_args;

            return new_body;
        }
    };
}
