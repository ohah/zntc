//! Constructor function helpers for ES2015 class lowering.

const ast_mod = @import("../../parser/ast.zig");
const NodeIndex = ast_mod.NodeIndex;
const token_mod = @import("../../lexer/token.zig");
const Span = token_mod.Span;
const es_helpers = @import("../es_helpers.zig");
const es2015_params = @import("../es2015_params.zig");
const derived_constructors = @import("derived_constructors.zig");

const MethodExtra = ast_mod.MethodExtra;

pub fn Constructors(comptime Transformer: type) type {
    return struct {
        const derived = derived_constructors.DerivedConstructors(Transformer);
        pub const buildAssertThisInitialized = derived.buildAssertThisInitialized;
        const transformDerivedConstructorReturns = derived.transformDerivedConstructorReturns;
        const postProcessDerivedConstructorBody = derived.postProcessDerivedConstructorBody;
        pub const buildDefaultSuperConstructor = derived.buildDefaultSuperConstructor;

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

            var new_body = try visitMethodBodyWithCtxImpl(self, body_idx, span, null, is_derived);

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
            return visitMethodBodyWithCtxImpl(self, body_idx, span, nt_ctx, false);
        }

        /// visitMethodBodyWithCtx의 내부 구현.
        /// derived constructor는 postProcessDerivedConstructorBody가 `var _this;` 선언과
        /// super() 결과 대입을 맡는다. 여기서 arrow 캡처용 `var _this = this;`를 넣으면
        /// super() 전 this 접근이 되어 Babel helper가 "Super constructor may only be called once"를 던진다.
        fn visitMethodBodyWithCtxImpl(
            self: *Transformer,
            body_idx: NodeIndex,
            span: Span,
            nt_ctx: ?Transformer.NewTargetCtx,
            derived_constructor_this_alias: bool,
        ) Transformer.Error!NodeIndex {
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

            const saved_temp_counter = self.temp_var_counter;

            var new_body = try self.visitNode(body_idx);

            // arrow가 this/arguments를 사용했으면 var _this = this; 등 삽입
            if (self.options.unsupported.arrow and !new_body.isNone() and
                (self.needs_this_var or self.needs_arguments_var))
            {
                var capture_stmts: [2]NodeIndex = undefined;
                var capture_count: usize = 0;

                if (self.needs_this_var and !derived_constructor_this_alias) {
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

            if (self.temp_var_counter > saved_temp_counter and !new_body.isNone()) {
                new_body = try self.hoistTempVars(new_body, saved_temp_counter, span);
            }
            self.temp_var_counter = saved_temp_counter;

            self.arrow_this_depth = saved_arrow_depth;
            self.needs_this_var = saved_needs_this;
            self.needs_arguments_var = saved_needs_args;

            return new_body;
        }
    };
}
