//! ES2015 다운레벨링: generator function → 상태 머신
//!
//! --target < es2015 일 때 활성화.
//!
//! function* gen() { yield 1; var x = yield 2; return x; }
//! → function gen() {
//!     return __generator(function(_state) {
//!       switch (_state.label) {
//!         case 0: return [4, 1];
//!         case 1: x = _state.sent(); return [4, 2];
//!         case 2: return [2, _state.sent()];
//!       }
//!     });
//!   }
//!
//! 상태 머신 instruction 코드:
//!   [4, value] — yield (일시정지, value 반환)
//!   [2, value] — return (완료)
//!   [3, label] — break/jump (다른 case로 이동)
//!   [5, iter]  — yield* (위임)
//!
//! __generator 런타임 헬퍼:
//!   _state.label — 현재 case 번호
//!   _state.sent() — .next(value)로 전달된 값
//!
//! 스펙:
//! - https://tc39.es/ecma262/#sec-generator-function-definitions (ES2015)
//!
//! 참고:
//! - SWC: crates/swc_ecma_compat_es2015/src/generator.rs (~3778줄)
//! - TypeScript: src/compiler/transformers/generators.ts
//! - esbuild: 미지원

const std = @import("std");
const ast_walk = @import("../parser/ast_walk.zig");
const ast_mod = @import("../parser/ast.zig");
const Node = ast_mod.Node;
const NodeIndex = ast_mod.NodeIndex;
const NodeList = ast_mod.NodeList;
const Tag = Node.Tag;
const token_mod = @import("../lexer/token.zig");
const Span = token_mod.Span;
const ScopeId = @import("../semantic/scope.zig").ScopeId;
const SymbolId = @import("../semantic/symbol.zig").SymbolId;
const Scanner = @import("../lexer/scanner.zig").Scanner;
const Parser = @import("../parser/parser.zig").Parser;
const es_helpers = @import("es_helpers.zig");
const es2015_destructuring = @import("es2015_destructuring.zig");
const es2015_params = @import("es2015_params.zig");
const es2015_scan = @import("es2015_generator/scan.zig");
const es2015_block_scoping = @import("es2015_block_scoping.zig");

/// 상태 머신의 개별 연산.
const OpCode = enum {
    statement, // 일반 문
    yield_op, // yield value → [4, value]
    yield_star, // yield* iter → [5, iter]
    return_op, // return value → [2, value]
    break_op, // goto label → [3, label]
    break_when_true, // if (expr) goto label
    break_when_false, // if (!expr) goto label
    nop, // case 경계 강제 (빈 연산)
};

/// 연산의 인자.
const OpArg = union(enum) {
    none: void,
    node: NodeIndex, // statement, yield, return의 값
    label: u32, // break_op의 대상 label
    label_and_node: struct { label: u32, node: NodeIndex }, // break_when_true/false
};

/// 하나의 연산 (opcode + 인자).
const Operation = struct {
    code: OpCode,
    arg: OpArg,
};

/// yield_expression / await_expression 노드를 대응되는 OpCode로 변환.
/// yield* delegate는 `unary.flags & 1`로 식별된다 (parser에서 설정).
/// await_expression은 always yield_op (delegate 의미 없음).
fn yieldOpCodeFor(node: Node) OpCode {
    if (node.tag == .yield_expression and (node.data.unary.flags & 1) != 0) return .yield_star;
    return .yield_op;
}

pub fn ES2015Generator(comptime Transformer: type) type {
    return struct {
        const HoistedStateTemp = @import("transformer/lists.zig").HoistedStateTemp;
        const GeneratorTempProducerIdentity = @import("transformer.zig").GeneratorTempProducerIdentity;

        /// generator function을 상태 머신으로 변환.
        /// function*: extra = [name(0), params(1), body(2), flags(3), return_type(4)]
        pub fn lowerGeneratorFunction(self: *Transformer, source_owner: NodeIndex, node: Node) Transformer.Error!NodeIndex {
            const source_boundary = try captureGeneratorSource(self, source_owner);
            defer if (source_boundary) |captured| self.allocator.free(captured.heritages);
            const e = node.data.extra;
            const span = node.span;

            const name_idx: NodeIndex = self.readNodeIdx(e, 0);
            const params_list_old = self.ast.functionParamsList(node);
            const params_start = params_list_old.start;
            const params_len = params_list_old.len;
            const params_idx: NodeIndex = self.readNodeIdx(e, ast_mod.FunctionExtra.params);
            const body_idx: NodeIndex = self.readNodeIdx(e, 2);
            const flags = self.readU32(e, ast_mod.FunctionExtra.flags);
            const source_scope = self.stateMachineOwnerScope(source_owner);

            // An extracted per-iteration generator is an implementation
            // function, not a lexical boundary for arrows in the source loop
            // body. Their `this`/`arguments` belong to the enclosing source
            // generator; keep that frame so its wrapper owns the aliases.
            const extracted_loop = self.deferred_generator_loop_owners.contains(@backingInt(source_owner));
            const arrow_env: ?es_helpers.ArrowEnvSnapshot = if (extracted_loop) null else es_helpers.pushArrowEnv(self);
            defer if (arrow_env) |env| es_helpers.popArrowEnv(self, env);
            const saved_extracted_body = self.in_extracted_fn_body;
            self.in_extracted_fn_body = false;
            defer self.in_extracted_fn_body = saved_extracted_body;

            const new_name = try self.visitNode(name_idx);

            const parameter_temp_start = self.temp_var_counter;
            const param_capture_use_start = self.lexical_capture_uses.items.len;
            var native_params_retained = self.native_parameter_list_retained_for_dynamic_lookup;
            if (self.options.unsupported.default_params and es2015_params.ES2015Params(Transformer).hasDefaultOrRest(
                self,
                params_list_old,
            )) {
                const parameter_environment = @import("parameter_environment.zig");
                const params_dynamic_lookup = try parameter_environment.nodeHasDynamicLookup(self, params_idx);
                const body_dynamic_lookup = try parameter_environment.functionBodyHasDynamicLookup(
                    self,
                    source_scope,
                    body_idx,
                );
                native_params_retained = params_dynamic_lookup or body_dynamic_lookup;
            }
            const parameter_visit = blk: {
                const saved_parameter_output_owner = self.lowered_parameter_temp_output_owner;
                const saved_native_parameter_list_retained = self.native_parameter_list_retained_for_dynamic_lookup;
                self.lowered_parameter_temp_output_owner = source_owner;
                self.native_parameter_list_retained_for_dynamic_lookup = native_params_retained;
                defer self.lowered_parameter_temp_output_owner = saved_parameter_output_owner;
                defer self.native_parameter_list_retained_for_dynamic_lookup = saved_native_parameter_list_retained;
                const new_params = try self.visitParameterList(.{ .start = params_start, .len = params_len });
                break :blk .{ .params = new_params, .temp_end = self.temp_var_counter };
            };
            const new_params = parameter_visit.params;
            const parameter_temp_end = parameter_visit.temp_end;
            const param_needs_this = if (extracted_loop) false else self.needs_this_var;
            const param_needs_arguments = if (extracted_loop) false else self.needs_arguments_var;
            const param_needs_new_target = if (extracted_loop) false else self.hasLexicalCaptureSince(param_capture_use_start, self.capture_frame, .new_target_value);

            const saved_temp_counter = self.temp_var_counter;

            // body 가 `__generator(this, function(_state){…})` 안쪽으로 옮겨진다 →
            // `arguments` 가 그 안쪽 함수 것(= `[_state]`)을 가리키므로 캡처가 필요하다.
            const saved_ext = self.in_extracted_fn_body;
            self.in_extracted_fn_body = true;
            // ⚠️ 이 리스트는 **상태 기계 하나당** 쓰는 것이라 중첩 lowering 이 서로를
            // 덮으면 안 된다. 예전에는 끝에서 통째로 clear 했는데, 바깥 상태 기계를
            // 수집하는 도중에 안쪽 generator 가 낮아지면(#4716 의 `_loopN` 추출이 그렇다)
            // 바깥이 쌓아 둔 temp 가 같이 지워져 선언이 사라진다. 저장 후 복원한다.
            var frame = try enterStateMachineTempsForScope(self, source_scope);
            defer leaveStateMachineTemps(self, &frame);
            // 함수 경계 — 바깥 함수의 라벨은 여기서 보이지 않는다 (#4722).
            try self.label_scope.append(self.allocator, null);
            defer _ = self.label_scope.pop();

            var sm_result = try buildStateMachine(self, body_idx, span, source_scope);
            defer sm_result.hoisted_temps.deinit(self.allocator);
            self.in_extracted_fn_body = saved_ext;
            if (sm_result.body.isNone()) return .none;
            const sm_body = try self.hoistStateMachineTempsAndRestore(sm_result.body, saved_temp_counter, span, &frame.callback_temps);

            // generator function 이름이 있으면 프로토타입 체인 설정을 위해 __generator에 전달.
            // #1756: makeIdentifierRefFromSpan 만 쓰면 symbol_id 가 전파되지 않아
            // 번들 모드에서 mangler rename (`function foo → function t`) 이 반영 안 됨.
            // `__generator(body, foo)` 의 `foo` 가 원본 이름 그대로 emit → ReferenceError.
            // makeIdentifierRefWithSymbol 로 원본 binding 의 symbol_id 까지 전파해야
            // codegen 이 `meta.renames.get(sid)` 로 mangled name 을 찾아 emit 함.
            const genFn_ref: NodeIndex = if (!new_name.isNone()) blk: {
                const ref = try self.makeIdentifierRefWithSymbol(self.ast.getNode(new_name).data.string_ref, new_name);
                try self.trackUserReadFromBinding(ref, new_name, self.current_scope);
                break :blk ref;
            } else .none;
            const gen = try buildGeneratorHelperCallWithProto(self, sm_body, genFn_ref, span);
            try self.bindGeneratedState(source_scope, source_scope, gen.callback, gen.state_param, frame.state_ref_start, sm_result.hoisted_temps.items, frame.callback_temps.items, span);
            if (self.semantic_edit_enabled) try moveCaseReferences(self, gen.callback, self.outputOwnedScope(gen.callback) orelse @panic("generator callback has no actual ScopeId"), generatorTransfer(self, source_boundary, gen));
            const gen_call = gen.call;

            // return __generator(...) 문
            const ret_stmt = try self.ast.addNode(.{
                .tag = .return_statement,
                .span = span,
                .data = .{ .unary = .{ .operand = gen_call, .flags = 0 } },
            });

            // hoisted var + return __generator(...)
            const scratch_top = self.scratch.items.len;
            defer self.scratch.shrinkRetainingCapacity(scratch_top);

            if (!extracted_loop) {
                var capture_stmts: [3]NodeIndex = undefined;
                const count = try es_helpers.fillThisArgumentsCaptures(self, &capture_stmts, span);
                try es_helpers.recordParameterCaptures(self, capture_stmts[0..count], param_needs_this, param_needs_arguments, param_needs_new_target);
                try self.scratch.appendSlice(self.allocator, capture_stmts[0..count]);
            }
            if (!sm_result.var_decl.isNone()) {
                try self.scratch.append(self.allocator, sm_result.var_decl);
            }
            try self.scratch.append(self.allocator, ret_stmt);

            const body_list = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
            const wrapper_body = try self.ast.addNode(.{
                .tag = .block_statement,
                .span = span,
                .data = .{ .list = body_list },
            });
            const new_body = blk: {
                const saved_native_parameter_list_retained = self.native_parameter_list_retained_for_dynamic_lookup;
                const saved_source_owner = self.synthetic_function_source_owner;
                self.native_parameter_list_retained_for_dynamic_lookup = native_params_retained;
                self.synthetic_function_source_owner = source_owner;
                defer self.native_parameter_list_retained_for_dynamic_lookup = saved_native_parameter_list_retained;
                defer self.synthetic_function_source_owner = saved_source_owner;
                break :blk try self.hoistParameterTempsAndRestore(wrapper_body, parameter_temp_start, parameter_temp_end, span);
            };

            // 일반 function으로 변환 (generator 플래그 제거)
            const new_flags = flags & ~@as(u32, ast_mod.FunctionFlags.is_generator);
            const none = @backingInt(NodeIndex.none);
            const new_params_node = try self.ast.addFormalParameters(new_params, span);
            try self.remapCopiedScopeOwner(params_idx, new_params_node);
            const new_extra = try self.ast.addExtras(&.{
                @backingInt(new_name),
                @backingInt(new_params_node),
                @backingInt(new_body),
                new_flags,
                none,
            });
            const result = try self.ast.addNode(.{
                .tag = node.tag,
                .span = span,
                .data = .{ .extra = new_extra },
            });
            if (self.semantic_edit_enabled and source_scope.isNone()) {
                try self.deferred_generator_helper_refs.put(self.allocator, @backingInt(result), gen.helper_ref);
            }
            // Ordinary wrappers bind captures at declaration creation. Extracted
            // loop generators inherit the source generator's exact capture frame.
            return result;
        }

        pub const StateMachineResult = struct {
            body: NodeIndex, // switch 문 (또는 switch를 포함하는 block)
            var_decl: NodeIndex, // 호이스팅된 var 선언 (없으면 .none)
            hoisted_temps: std.ArrayListUnmanaged(HoistedStateTemp) = .empty,
        };

        /// generator body를 switch 문 기반 상태 머신으로 변환.
        /// es2017 결합 변환에서도 호출 (async body의 await를 yield처럼 처리).
        /// 상태 기계 하나를 만들기 **전에** 부른다: 바깥 상태 기계가 쌓아 둔 temp 목록을
        /// 떼어 두고 빈 목록으로 시작한다. 짝인 `leaveStateMachineTemps` 가 되돌린다.
        ///
        /// `generator_temp_var_spans` 는 상태 기계 하나당 쓰는 목록이다. 예전엔 각 호출부가
        /// 끝에서 통째로 clear 했는데, 바깥 상태 기계를 수집하는 도중에 안쪽 함수(중첩 async
        /// 화살표, 추출된 `_loop` generator …)가 낮아지면 **바깥 temp 까지 지워져** 선언이
        /// 사라졌다(`_loop is not defined` — #4716 에서 한 곳, #4722 에서 나머지 셋).
        pub const StateMachineFrame = struct {
            saved_temp_spans: std.ArrayListUnmanaged(Span),
            saved_state_bindings: std.ArrayListUnmanaged(HoistedStateTemp),
            saved_temp_producers: std.ArrayListUnmanaged(GeneratorTempProducerIdentity),
            saved_state_name_span: ?Span,
            saved_state_output_scope: ScopeId,
            state_ref_start: usize,
            callback_temps: std.ArrayListUnmanaged(@import("transformer/lists.zig").HoistedStateTemp) = .empty,
        };

        pub fn enterStateMachineTemps(self: *Transformer) Transformer.Error!StateMachineFrame {
            return enterStateMachineTempsForScope(self, self.current_scope);
        }

        /// Bind late output naming to the exact source owner of this state
        /// machine. `current_scope` can differ for generated async/class paths.
        pub fn enterStateMachineTempsForScope(self: *Transformer, output_scope: ScopeId) Transformer.Error!StateMachineFrame {
            var saved: std.ArrayListUnmanaged(Span) = .empty;
            try saved.appendSlice(self.allocator, self.generator_temp_var_spans.items);
            self.generator_temp_var_spans.clearRetainingCapacity();
            var saved_state_bindings: std.ArrayListUnmanaged(HoistedStateTemp) = .empty;
            try saved_state_bindings.appendSlice(self.allocator, self.generator_state_bindings.items);
            self.generator_state_bindings.clearRetainingCapacity();
            var saved_temp_producers: std.ArrayListUnmanaged(GeneratorTempProducerIdentity) = .empty;
            try saved_temp_producers.appendSlice(self.allocator, self.generator_temp_producer_identities.items);
            self.generator_temp_producer_identities.clearRetainingCapacity();
            const saved_state_name_span = self.generator_state_name_span;
            self.generator_state_name_span = null;
            const saved_state_output_scope = self.generator_state_output_scope;
            self.generator_state_output_scope = output_scope;
            self.state_machine_depth += 1;
            return .{
                .saved_temp_spans = saved,
                .saved_state_bindings = saved_state_bindings,
                .saved_temp_producers = saved_temp_producers,
                .saved_state_name_span = saved_state_name_span,
                .saved_state_output_scope = saved_state_output_scope,
                .state_ref_start = self.generator_state_refs.items.len,
            };
        }

        pub fn leaveStateMachineTemps(self: *Transformer, frame: *StateMachineFrame) void {
            std.debug.assert(self.state_machine_depth > 0);
            self.state_machine_depth -= 1;
            self.generator_state_refs.shrinkRetainingCapacity(frame.state_ref_start);
            self.generator_state_name_span = frame.saved_state_name_span;
            self.generator_state_output_scope = frame.saved_state_output_scope;
            self.generator_temp_var_spans.clearRetainingCapacity();
            self.generator_temp_var_spans.appendSlice(self.allocator, frame.saved_temp_spans.items) catch {};
            self.generator_state_bindings.clearRetainingCapacity();
            self.generator_state_bindings.appendSlice(self.allocator, frame.saved_state_bindings.items) catch {};
            self.generator_temp_producer_identities.clearRetainingCapacity();
            self.generator_temp_producer_identities.appendSlice(self.allocator, frame.saved_temp_producers.items) catch {};
            frame.saved_temp_spans.deinit(self.allocator);
            frame.saved_state_bindings.deinit(self.allocator);
            frame.saved_temp_producers.deinit(self.allocator);
            frame.callback_temps.deinit(self.allocator);
        }

        pub fn buildStateMachine(self: *Transformer, body_idx: NodeIndex, span: Span, wrapper_scope: ScopeId) Transformer.Error!StateMachineResult {
            if (body_idx.isNone()) return .{ .body = .none, .var_decl = .none };

            const saved_state_machine_scope = self.generator_state_machine_scope;
            self.generator_state_machine_scope = wrapper_scope;
            defer self.generator_state_machine_scope = saved_state_machine_scope;

            const body = self.ast.getNode(body_idx);

            // expression body (arrow function): implicit return으로 처리
            if (body.tag != .block_statement and body.tag != .function_body) {
                return buildExpressionBodyStateMachine(self, body_idx, body, span, wrapper_scope);
            }

            // Reserve the actual native write scope before operation collection.
            const reserved_extra = try self.ast.addExtras(&.{ @backingInt(NodeIndex.none), 0, 0 });
            const reserved_switch = try self.ast.addNode(.{ .tag = .switch_statement, .span = span, .data = .{ .extra = reserved_extra } });
            const saved_operation_scope = self.generator_operation_scope;
            self.generator_operation_scope = wrapper_scope;
            defer self.generator_operation_scope = saved_operation_scope;
            const saved_native_scope = self.generator_native_var_scope;
            self.generator_native_var_scope = if (self.semantic_edit_enabled)
                try self.addGeneratedScope(wrapper_scope, reserved_switch, .switch_block)
            else
                .none;
            defer self.generator_native_var_scope = saved_native_scope;

            const body_list = try rewriteUsingForStateMachine(self, body.data.list);
            const stmts_start = body_list.statements.start;
            const stmts_len = body_list.statements.len;

            // Phase 1: 연산 수집 (yield/return/statement를 Operation으로 변환)
            var ops: std.ArrayList(Operation) = .empty;
            defer ops.deinit(self.allocator);

            var next_label: u32 = 1; // label 0은 시작

            // 변수 호이스팅: generator body의 모든 var 선언을 수집.
            // JS의 var는 function-scoped이므로 switch case 안에 두면 안 됨.
            var hoisted_vars: std.ArrayList(NodeIndex) = .empty;
            defer hoisted_vars.deinit(self.allocator);
            // collectBindingIdentifiers가 visitNode를 호출하므로 인덱스 기반 접근 사용
            try collectHoistedVarsRange(self, stmts_start, stmts_len, &hoisted_vars);

            // Initialize each exact function cell once at this body activation.
            _ = try collectFunctionInitializers(self, body_list.statements, &ops);
            // collectOperations는 AST를 변형하므로 인덱스 루프 사용
            var i_stmts: u32 = 0;
            while (i_stmts < stmts_len) : (i_stmts += 1) {
                const raw_idx = self.ast.extra_data.items[stmts_start + i_stmts];
                try collectRewrittenUsingStatement(self, @fromBackingInt(@intCast(raw_idx)), body_list.disposal_try, &ops, &next_label);
            }

            // 암시적 return (마지막에 return이 없으면 추가)
            if (ops.items.len == 0 or ops.items[ops.items.len - 1].code != .return_op) {
                try ops.append(self.allocator, .{ .code = .return_op, .arg = .{ .none = {} } });
            }

            // Phase 2: 연산을 switch case로 변환
            const switch_node = try buildSwitchFromOps(self, ops.items, span, wrapper_scope, reserved_switch);
            if (self.semantic_edit_enabled) {
                try self.bindDeferredGeneratorForInBodyReferences(
                    switch_node,
                    wrapper_scope,
                    self.generator_native_var_scope,
                );
            }
            var state_temps: std.ArrayListUnmanaged(HoistedStateTemp) = .empty;
            errdefer state_temps.deinit(self.allocator);
            const var_decl_node = try buildHoistedVarDecl(self, hoisted_vars.items, span, &state_temps, wrapper_scope);
            return .{ .body = switch_node, .var_decl = var_decl_node, .hoisted_temps = state_temps };
        }

        pub fn appendGeneratorTempSpan(self: *Transformer, span: Span) Transformer.Error!void {
            if (self.generator_temp_var_spans.items.len != self.generator_temp_producer_identities.items.len)
                std.debug.panic("generator temp spans and producer identities are out of sync", .{});
            try self.generator_temp_producer_identities.append(self.allocator, .{});
            errdefer self.generator_temp_producer_identities.shrinkRetainingCapacity(
                self.generator_temp_producer_identities.items.len - 1,
            );
            try self.generator_temp_var_spans.append(self.allocator, span);
        }

        /// Append a generator temp together with the exact identity already
        /// held by its lowering binding. Loop lowerers use this path instead
        /// of round-tripping through the span-keyed state-temp registry.
        pub fn appendGeneratorTempSpanWithIdentity(
            self: *Transformer,
            span: Span,
            symbol_id: ?SymbolId,
            owner_scope: ScopeId,
        ) Transformer.Error!void {
            if (self.generator_temp_var_spans.items.len != self.generator_temp_producer_identities.items.len)
                std.debug.panic("generator temp spans and producer identities are out of sync", .{});
            var identity: GeneratorTempProducerIdentity = .{};
            if (self.semantic_edit_enabled and self.state_machine_depth > 0) {
                const symbol = symbol_id orelse
                    std.debug.panic("generator loop temp has no exact producer SymbolId", .{});
                if (owner_scope.isNone() or self.generator_state_machine_scope.isNone() or
                    owner_scope != self.generator_state_machine_scope)
                    std.debug.panic("generator loop temp has no exact wrapper owner ScopeId", .{});
                const raw_id = @backingInt(symbol);
                const symbols = if (self.semantic_editor) |*editor| editor.symbols.items else self.symbols;
                if (raw_id >= symbols.len or symbols[raw_id].scope_id != owner_scope)
                    std.debug.panic("generator loop temp SymbolId changed its exact wrapper owner", .{});
                identity.symbol_id = raw_id;
                identity.owner_scope = owner_scope;
            }
            try self.generator_temp_producer_identities.append(self.allocator, identity);
            errdefer self.generator_temp_producer_identities.shrinkRetainingCapacity(
                self.generator_temp_producer_identities.items.len - 1,
            );
            try self.generator_temp_var_spans.append(self.allocator, span);
        }

        /// Preserve a known source owner while moving a loop control temp into
        /// this generated callback's wrapper declaration. Semantic-edit
        /// completion relocates the exact SymbolId after validating the live
        /// callback handoff.
        pub fn appendGeneratorTempSpanWithDeferredIdentity(
            self: *Transformer,
            span: Span,
            symbol_id: SymbolId,
            source_scope: ScopeId,
            wrapper_scope: ScopeId,
        ) Transformer.Error!void {
            if (!self.semantic_edit_enabled or self.state_machine_depth == 0)
                std.debug.panic("deferred generator temp identity has no active semantic state machine", .{});
            if (self.generator_state_machine_scope.isNone() or wrapper_scope != self.generator_state_machine_scope or
                source_scope.isNone())
                std.debug.panic("deferred generator temp has no exact source or wrapper owner", .{});
            if (self.generator_temp_var_spans.items.len != self.generator_temp_producer_identities.items.len)
                std.debug.panic("generator temp spans and producer identities are out of sync", .{});

            const editor = if (self.semantic_editor) |*value| value else std.debug.panic("deferred generator temp identity has no semantic editor", .{});
            const raw_id: usize = @intCast(@backingInt(symbol_id));
            if (raw_id >= editor.symbols.items.len or editor.symbols.items[raw_id].scope_id != source_scope)
                std.debug.panic("deferred generator temp SymbolId changed its exact source owner", .{});
            var cursor = wrapper_scope;
            var source_is_ancestor = false;
            for (0..editor.scopes.items.len) |_| {
                if (cursor.isNone() or cursor.toIndex() >= editor.scopes.items.len) break;
                if (cursor == source_scope) {
                    source_is_ancestor = true;
                    break;
                }
                cursor = editor.scopes.items[cursor.toIndex()].parent;
            }
            if (!source_is_ancestor)
                std.debug.panic("deferred generator temp wrapper is outside its exact source owner", .{});

            try self.generator_temp_producer_identities.append(self.allocator, .{
                .symbol_id = @backingInt(symbol_id),
                .owner_scope = wrapper_scope,
                .producer_owned = true,
            });
            errdefer self.generator_temp_producer_identities.shrinkRetainingCapacity(
                self.generator_temp_producer_identities.items.len - 1,
            );
            try self.generator_temp_var_spans.append(self.allocator, span);
        }

        pub fn appendGeneratorTempSpans(self: *Transformer, spans: []const Span) Transformer.Error!void {
            for (spans) |span| try appendGeneratorTempSpan(self, span);
        }

        fn attachGeneratorTempProducerBinding(self: *Transformer, binding: NodeIndex, name_span: Span, symbol_id: SymbolId) void {
            if (self.generator_temp_var_spans.items.len != self.generator_temp_producer_identities.items.len or
                self.generator_temp_producer_identities.items.len == 0)
                std.debug.panic("generator temp binding has no matching producer record", .{});
            const node = self.ast.getNode(binding);
            if (node.tag != .binding_identifier or
                !std.mem.eql(u8, self.ast.getText(node.data.string_ref), self.ast.getText(name_span)))
                std.debug.panic("generator temp binding handle disagrees with its exact name", .{});
            const raw_symbol_id = @backingInt(symbol_id);
            if (self.getSymbolIdAt(binding) != raw_symbol_id)
                std.debug.panic("generator temp binding handle disagrees with its exact SymbolId", .{});
            const producer = &self.generator_temp_producer_identities.items[
                self.generator_temp_producer_identities.items.len - 1
            ];
            if (producer.symbol_id != raw_symbol_id)
                std.debug.panic("generator temp producer record changed its exact SymbolId", .{});
            if (!producer.binding.isNone() and producer.binding != binding)
                std.debug.panic("generator temp producer record changed its binding handle", .{});
            producer.binding = binding;
        }

        fn hasExactCallbackLocalGeneratorTempBinding(self: *Transformer, binding: NodeIndex, name_span: Span) bool {
            var found = false;
            for (self.generator_state_bindings.items) |registered| {
                if (registered.binding != binding) continue;
                if (!registered.callback_local or
                    registered.name_span.start != name_span.start or registered.name_span.end != name_span.end)
                    return false;
                if (found) return false;
                found = true;
            }
            return found;
        }

        fn requireCallbackLocalGeneratorTempBinding(self: *Transformer, binding: NodeIndex, name_span: Span) void {
            if (!hasExactCallbackLocalGeneratorTempBinding(self, binding, name_span))
                std.debug.panic("deferred generator temp has no exact callback-local binding handoff", .{});
        }

        fn recordGeneratorStateBinding(self: *Transformer, binding: NodeIndex, name_span: Span, owner_scope: ScopeId, declaration_span: Span) Transformer.Error!void {
            var symbol_id = self.getSymbolIdAt(binding);
            if (self.semantic_edit_enabled) {
                if (owner_scope.isNone()) std.debug.panic("generator wrapper binding has no exact owner ScopeId", .{});
                if (@backingInt(binding) >= self.parser_node_count) {
                    if (symbol_id) |existing| {
                        const editor = if (self.semantic_editor) |*value| value else std.debug.panic("generated generator wrapper binding has no semantic editor", .{});
                        if (existing >= editor.symbols.items.len)
                            std.debug.panic("generated generator wrapper binding has an invalid SymbolId", .{});
                        const symbol = editor.symbols.items[existing];
                        if (symbol.scope_id != owner_scope or symbol.kind != .variable_var or
                            symbol.name.start != name_span.start or symbol.name.end != name_span.end or
                            !std.mem.eql(u8, symbol.synthetic_name, self.ast.getText(name_span)))
                            std.debug.panic("generated generator wrapper binding changed its exact identity", .{});
                    } else {
                        const registered = try self.registerGeneratedWrapperTemp(binding, name_span, declaration_span, owner_scope) orelse
                            std.debug.panic("generated generator wrapper binding lost its SymbolId", .{});
                        symbol_id = @backingInt(registered);
                    }
                } else {
                    const raw_id = symbol_id orelse std.debug.panic("source generator wrapper binding has no exact SymbolId", .{});
                    const symbols = if (self.semantic_editor) |*editor| editor.symbols.items else self.symbols;
                    if (raw_id >= symbols.len or symbols[raw_id].scope_id != owner_scope)
                        std.debug.panic("source generator wrapper binding has no exact owner scope", .{});
                }
            }
            for (self.generator_state_bindings.items) |existing| {
                if (existing.binding != binding) continue;
                if (self.semantic_edit_enabled) {
                    if (existing.name_span.start != name_span.start or existing.name_span.end != name_span.end)
                        std.debug.panic("generator state binding was recorded with two temp spans", .{});
                    if (existing.symbol_id != symbol_id)
                        std.debug.panic("generator state binding changed its exact SymbolId", .{});
                    if (existing.callback_local)
                        std.debug.panic("callback-local binding was also hoisted to the generator wrapper", .{});
                    if (existing.owner_scope != owner_scope)
                        std.debug.panic("generator state binding changed its exact owner ScopeId", .{});
                }
                return;
            }
            try self.generated_temp_spans.append(self.allocator, name_span);
            try self.generator_state_bindings.append(self.allocator, .{
                .binding = binding,
                .name_span = name_span,
                .symbol_id = symbol_id,
                .owner_scope = if (self.semantic_edit_enabled) owner_scope else .none,
            });
        }

        /// Capture a lowering temp's exact owner and SymbolId at the point its
        /// producer is created. Its aligned identity record travels with the
        /// span list until the wrapper declaration is emitted.
        fn captureGeneratorTempProducer(self: *Transformer, name_span: Span, declaration_span: Span) Transformer.Error!HoistedStateTemp {
            var producer = HoistedStateTemp{ .binding = .none, .name_span = name_span };
            if (self.temp_var_counter == 0)
                std.debug.panic("generator temp producer has no allocator counter slot", .{});
            const counter_index = self.temp_var_counter - 1;
            const allocated_span = self.temp_span_by_counter.get(counter_index) orelse
                std.debug.panic("generator temp producer has no allocator span", .{});
            if (allocated_span.start != name_span.start or allocated_span.end != name_span.end)
                std.debug.panic("generator temp producer span disagrees with its allocator slot", .{});
            const temp_producer_id = self.temp_producer_id_by_counter.get(counter_index) orelse
                std.debug.panic("generator temp producer has no allocator producer ID", .{});
            if (temp_producer_id == 0)
                std.debug.panic("generator temp producer has an invalid allocator producer ID", .{});
            producer.temp_producer_id = temp_producer_id;
            try appendGeneratorTempSpan(self, name_span);
            const identity = &self.generator_temp_producer_identities.items[self.generator_temp_var_spans.items.len - 1];
            identity.temp_producer_id = temp_producer_id;
            if (self.semantic_edit_enabled) {
                if (self.state_machine_depth == 0)
                    std.debug.panic("generator temp producer was captured outside its state machine", .{});
                const owner_scope = self.generator_state_machine_scope;
                if (owner_scope.isNone())
                    std.debug.panic("generator temp producer has no exact wrapper ScopeId", .{});
                const symbol = (try self.reserveSyntheticTempSymbolForProducerInScope(
                    temp_producer_id,
                    name_span,
                    declaration_span,
                    owner_scope,
                )) orelse
                    std.debug.panic("generator temp producer has no exact SymbolId", .{});
                const slot = try self.temp_symbol_ids_by_counter.getOrPut(self.allocator, counter_index);
                if (slot.found_existing and slot.value_ptr.* != @backingInt(symbol))
                    std.debug.panic("generator temp allocator slot changed its exact SymbolId", .{});
                slot.value_ptr.* = @backingInt(symbol);
                producer.symbol_id = @backingInt(symbol);
                producer.owner_scope = owner_scope;
                identity.symbol_id = @backingInt(symbol);
                identity.owner_scope = owner_scope;
                identity.producer_owned = true;
            }
            return producer;
        }

        /// Create a state-temp reference from the SymbolId already held by its
        /// producer. This path deliberately does not consult the span-keyed
        /// generator temp registry; only the callback reference scope is deferred.
        fn makeGeneratorTempRefWithProducerSymbol(
            self: *Transformer,
            name_span: Span,
            node_span: Span,
            symbol_id: @import("../semantic/symbol.zig").SymbolId,
            flags: @import("../semantic/symbol.zig").ReferenceFlags,
        ) Transformer.Error!NodeIndex {
            if (!self.semantic_edit_enabled or self.state_machine_depth == 0)
                std.debug.panic("producer-owned generator temp reference escaped its semantic state machine", .{});
            const ref = try es_helpers.makeTempVarRef(self, name_span, node_span);
            try self.trackGeneratorStateReference(ref, symbol_id, self.current_scope, flags);
            return ref;
        }

        fn makeGeneratorTempRefForProducer(self: *Transformer, producer: HoistedStateTemp, node_span: Span, flags: @import("../semantic/symbol.zig").ReferenceFlags) Transformer.Error!NodeIndex {
            if (self.semantic_edit_enabled) {
                const raw_id = producer.symbol_id orelse
                    std.debug.panic("generator temp reference lost its producer SymbolId", .{});
                return makeGeneratorTempRefWithProducerSymbol(
                    self,
                    producer.name_span,
                    node_span,
                    @fromBackingInt(@intCast(raw_id)),
                    flags,
                );
            }
            return es_helpers.makeTempVarRef(self, producer.name_span, node_span);
        }

        /// 사용자 바인딩(`origin`)에서 온 이름을 wrapper 최상단 `var` 목록에 등록한다.
        /// producer record가 원래 binding node를 직접 보유해 hoist 시 같은 SymbolId를 재사용한다.
        /// 반환한 index는 호출자가 producer record를 다시 검색하지 않도록 전달한다.
        fn registerGeneratorVar(self: *Transformer, span: Span, origin: NodeIndex) Transformer.Error!usize {
            const producer_index = self.generator_temp_var_spans.items.len;
            try appendGeneratorTempSpan(self, span);
            self.generator_temp_producer_identities.items[producer_index].binding = origin;
            if (self.getSymbolIdAt(origin) != null) {
                const producer = &self.generator_temp_producer_identities.items[producer_index];
                producer.source_binding = origin;
            }
            return producer_index;
        }

        /// generator body 의 hoisted `var` 선언과 for-of/await 변환에서 생성한 임시 변수를
        /// 하나의 `var` 선언으로 합쳐 반환. __generator 콜백 밖(함수 스코프)에 배치해야 한다 —
        /// 콜백 안에 두면 매 호출마다 재선언되어 상태가 리셋된다. 합칠 변수가 없으면 `.none`.
        fn buildHoistedVarDecl(self: *Transformer, hoisted_vars: []const NodeIndex, span: Span, state_temps: *std.ArrayListUnmanaged(HoistedStateTemp), wrapper_scope: ScopeId) Transformer.Error!NodeIndex {
            if (self.generator_temp_var_spans.items.len != self.generator_temp_producer_identities.items.len)
                std.debug.panic("generator temp spans and producer identities are out of sync", .{});
            if (hoisted_vars.len == 0 and self.generator_temp_var_spans.items.len == 0) return .none;
            const scratch_top = self.scratch.items.len;
            defer self.scratch.shrinkRetainingCapacity(scratch_top);
            // 같은 이름을 두 번 선언하지 않는다 — 합성 선언 등록(#4722)이 소스 선언과 겹칠 수 있다.
            var seen: std.StringHashMapUnmanaged(void) = .empty;
            defer seen.deinit(self.allocator);
            var source_identities: std.AutoHashMapUnmanaged(u32, void) = .empty;
            defer source_identities.deinit(self.allocator);
            for (hoisted_vars) |binding| {
                if (self.getSymbolIdAt(binding)) |id| {
                    const identity = try source_identities.getOrPut(self.allocator, id);
                    if (identity.found_existing) continue;
                }
                const bnode = self.ast.getNode(binding);
                if (bnode.tag == .binding_identifier) {
                    try seen.put(self.allocator, self.ast.getText(bnode.data.string_ref), {});
                    for (self.generator_temp_var_spans.items, 0..) |temp_span, temp_index| {
                        const producer = self.generator_temp_producer_identities.items[temp_index];
                        if (!producer.source_binding.isNone()) continue;
                        const binding_symbol = self.getSymbolIdAt(binding);
                        const exact_symbol_match = if (producer.symbol_id) |producer_id|
                            binding_symbol == producer_id
                        else
                            false;
                        if (producer.binding == binding or exact_symbol_match) {
                            try recordGeneratorStateBinding(self, binding, temp_span, wrapper_scope, span);
                            break;
                        }
                        // Semantic generation must use the producer's binding or SID. A
                        // shared start offset is only a legacy semantic-less association;
                        // on the semantic path, an ambiguous missing handle fails closed.
                        if (self.semantic_edit_enabled and
                            producer.binding.isNone() and
                            producer.symbol_id == null and
                            binding_symbol == null and
                            bnode.data.string_ref.start == temp_span.start)
                        {
                            std.debug.panic("generator hoist producer matched a binding span without an exact identity", .{});
                        }
                        if (!self.semantic_edit_enabled and bnode.data.string_ref.start == temp_span.start) {
                            try recordGeneratorStateBinding(self, binding, temp_span, wrapper_scope, span);
                            break;
                        }
                    }
                }
                if (self.semantic_edit_enabled) {
                    const id = self.getSymbolIdAt(binding) orelse std.debug.panic("hoisted source storage has no SymbolId", .{});
                    const symbol = self.semantic_editor.?.symbols.items[id];
                    if (symbol.kind != .variable_var and symbol.kind != .parameter) {
                        try state_temps.append(self.allocator, .{
                            .binding = binding,
                            .name_span = bnode.data.string_ref,
                            .symbol_id = id,
                            .owner_scope = wrapper_scope,
                        });
                    }
                }
                const declarator = try es_helpers.makeDeclarator(self, binding, .none, span);
                try self.scratch.append(self.allocator, declarator);
            }
            for (self.generator_temp_var_spans.items, 0..) |temp_span, temp_index| {
                const gop = try seen.getOrPut(self.allocator, self.ast.getText(temp_span));
                if (gop.found_existing) continue;
                // 사용자 바인딩에서 온 이름이면 그 심볼을 물려준다 — 대입·참조만 심볼을 갖고
                // 이 선언이 없으면 minify 가 둘을 다른 이름으로 찍는다 (#4760).
                const producer = self.generator_temp_producer_identities.items[temp_index];
                const origin: ?NodeIndex = if (producer.source_binding.isNone()) null else producer.source_binding;
                if (origin) |source| {
                    if (producer.symbol_id) |producer_id| {
                        const source_id = self.getSymbolIdAt(source) orelse
                            if (self.semantic_edit_enabled)
                                std.debug.panic("generator source binding lost its exact SymbolId", .{})
                            else
                                producer_id;
                        if (producer_id != source_id)
                            std.debug.panic("generator producer and source binding disagree on SymbolId", .{});
                        if (self.semantic_edit_enabled and producer.owner_scope != wrapper_scope)
                            std.debug.panic("generator source binding producer changed its exact owner ScopeId", .{});
                    }
                }
                const binding = if (origin) |source| blk: {
                    if (!producer.binding.isNone() and producer.binding != source) {
                        if (self.getSymbolIdAt(producer.binding) != self.getSymbolIdAt(source))
                            std.debug.panic("generator source cell changed its exact binding", .{});
                        break :blk producer.binding;
                    }
                    break :blk try self.makeUserBinding(temp_span, source);
                } else if (producer.symbol_id) |raw_id| blk: {
                    if (self.semantic_edit_enabled and producer.owner_scope != wrapper_scope)
                        std.debug.panic("generator temp producer owner changed before hoisting", .{});
                    const captured = try self.createSyntheticTempBindingWithIdentity(
                        temp_span,
                        wrapper_scope,
                        @fromBackingInt(@intCast(raw_id)),
                    );
                    if (captured.symbol_id == null or @backingInt(captured.symbol_id.?) != raw_id)
                        std.debug.panic("generator temp hoist changed its producer SymbolId", .{});
                    break :blk captured.node;
                } else try es_helpers.makeExactSyntheticBindingFromSpan(self, temp_span);
                if (origin == null) try self.generated_temp_spans.append(self.allocator, temp_span);
                const symbol_id: ?u32 = if (origin) |source| blk: {
                    const id = self.getSymbolIdAt(source);
                    if (self.semantic_edit_enabled and id == null)
                        std.debug.panic("source generator var temp has no exact SymbolId", .{});
                    break :blk id;
                } else if (producer.symbol_id) |raw_id| raw_id else if (self.semantic_edit_enabled) blk: {
                    const id = try self.declareSyntheticTempInScope(binding, span, wrapper_scope) orelse
                        std.debug.panic("generated generator wrapper temp lost its SymbolId", .{});
                    break :blk @backingInt(id);
                } else null;
                try state_temps.append(self.allocator, .{
                    .binding = binding,
                    .name_span = temp_span,
                    .symbol_id = symbol_id,
                    .owner_scope = if (self.semantic_edit_enabled) wrapper_scope else .none,
                    .temp_producer_id = producer.temp_producer_id,
                });
                const declarator = try es_helpers.makeDeclarator(self, binding, .none, span);
                try self.scratch.append(self.allocator, declarator);
            }
            return es_helpers.makeVarDeclaration(self, self.scratch.items[scratch_top..], .@"var", span);
        }

        /// `return`/`throw` 의 피연산자 식을 yield 추출과 함께 처리한 뒤, 그 자리에 들어갈
        /// 최종 식 노드를 반환한다.
        ///  - `await x` / `yield x` 자체: yield 연산 + nop 을 ops 에 방출하고 `_state.sent()` 반환.
        ///  - 중첩 yield (`f(await x)` 등): yield 들을 추출한 뒤 남은 식 반환.
        ///  - yield 없음: 그냥 visitNode 결과 반환.
        fn lowerYieldingOperand(self: *Transformer, value_idx: NodeIndex, span: Span, ops: *std.ArrayList(Operation), next_label: *u32) Transformer.Error!NodeIndex {
            const value_node = self.ast.getNode(value_idx);
            if (value_node.tag == .yield_expression or value_node.tag == .await_expression) {
                const inner_value = value_node.data.unary.operand;
                const new_inner = try visitExprWithYieldExtraction(self, inner_value, ops, next_label);
                try ops.append(self.allocator, .{ .code = yieldOpCodeFor(value_node), .arg = .{ .node = try asyncGenAwaitValue(self, value_node, new_inner) } });
                next_label.* += 1;
                try ops.append(self.allocator, .{ .code = .nop, .arg = .{ .none = {} } });
                return buildSentCall(self, span);
            }
            if (es2015_scan.containsYield(self, value_idx)) {
                return visitExprWithYieldExtraction(self, value_idx, ops, next_label);
            }
            return self.visitNode(value_idx);
        }

        /// AST 문을 순회하며 연산을 수집.
        fn collectOperations(self: *Transformer, stmt_idx: NodeIndex, ops: *std.ArrayList(Operation), next_label: *u32) Transformer.Error!void {
            if (stmt_idx.isNone()) return;
            if (self.generator_collected_function_declarations.get(@backingInt(stmt_idx))) |sid| {
                try appendCollectedFunctionAlias(self, stmt_idx, sid, ops);
                return;
            }
            const saved_scope = self.generator_operation_scope;
            if (self.semantic_edit_enabled) {
                const raw = @backingInt(stmt_idx);
                const owner_scope = if (self.scope_owner_removed.contains(raw)) null else self.transformed_scope_owner_map.get(raw) orelse
                    self.scope_owner_map.get(raw) orelse
                    if (self.semantic_editor) |*editor| editor.scope_owner_map.get(raw) else null;
                if (owner_scope) |scope| self.generator_operation_scope = @fromBackingInt(@intCast(scope));
            }
            defer self.generator_operation_scope = saved_scope;
            const stmt = self.ast.getNode(stmt_idx);

            switch (stmt.tag) {
                .expression_statement => {
                    // expression_statement 안의 yield/await 감지
                    const expr_idx = stmt.data.unary.operand;
                    const expr = self.ast.getNode(expr_idx);

                    if (expr.tag == .yield_expression or expr.tag == .await_expression) {
                        const value_idx = expr.data.unary.operand;
                        const new_value = try visitExprWithYieldExtraction(self, value_idx, ops, next_label);
                        try ops.append(self.allocator, .{ .code = yieldOpCodeFor(expr), .arg = .{ .node = try asyncGenAwaitValue(self, expr, new_value) } });
                        next_label.* += 1;
                        try ops.append(self.allocator, .{ .code = .nop, .arg = .{ .none = {} } });
                        // _state.sent() — resume 시 throw된 에러를 발생시키기 위해 필수
                        const sent_stmt = try buildSentExprStmt(self, stmt.span);
                        try ops.append(self.allocator, .{ .code = .statement, .arg = .{ .node = sent_stmt } });
                    } else if (expr.tag == .assignment_expression) {
                        // x = yield value / x = await value / x += await value 패턴 감지.
                        // compound (`+=`, `-=`, ...) 의 경우 expr.data.binary.flags 가 op kind
                        // (Kind.plus_eq 등) 를 보존 — assignment node 만들 때 그대로 전달해야
                        // `sum += _state.sent()` 가 `sum = _state.sent()` 로 떨어지지 않음 (#1896).
                        const right_idx = expr.data.binary.right;
                        const right = self.ast.getNode(right_idx);
                        if (right.tag == .yield_expression or right.tag == .await_expression) {
                            const yield_value_idx = right.data.unary.operand;
                            const new_yield_value = try visitExprWithYieldExtraction(self, yield_value_idx, ops, next_label);
                            try ops.append(self.allocator, .{ .code = .yield_op, .arg = .{ .node = new_yield_value } });
                            next_label.* += 1;
                            try ops.append(self.allocator, .{ .code = .nop, .arg = .{ .none = {} } });
                            // `[this.#y, o.b] = yield v` lowers like any assignment (#5728).
                            const assign_stmt = if (patternNeedsLowering(self, expr.data.binary.left)) pattern: {
                                const sent = try buildSentCall(self, stmt.span);
                                const lowered = try es2015_destructuring.ES2015Destructuring(Transformer).lowerDestructuringAssignmentWithRight(self, expr, sent, false);
                                break :pattern try es_helpers.makeExprStmt(self, lowered, stmt.span);
                            } else plain: {
                                const new_left = try self.visitNode(expr.data.binary.left);
                                const sent_call = try buildSentCall(self, stmt.span);
                                const new_left_node = self.ast.getNode(new_left);
                                const is_destructuring = new_left_node.tag == .object_pattern or new_left_node.tag == .array_pattern;
                                // Destructuring 은 spec 상 compound op 불가 (`{a} += x` invalid) → 전용 helper (flags=0 + paren wrap).
                                break :plain if (is_destructuring)
                                    try makeDestructuringAssignStmt(self, new_left, sent_call, stmt.span, self.generator_state_machine_scope)
                                else
                                    try es_helpers.makeAssignStmt(self, new_left, sent_call, stmt.span, expr.data.binary.flags);
                            };
                            try ops.append(self.allocator, .{ .code = .statement, .arg = .{ .node = assign_stmt } });
                        } else if (es2015_scan.containsYield(self, expr_idx)) {
                            // x = [yield 5, yield 6] — 중첩 yield가 있는 assignment.
                            // ⚠️ 우변만 보면 `o[yield k] = 1` 처럼 **좌변**에 있는 yield 를
                            // 놓쳐 raw `yield` 가 남는다 (#4721).
                            // visitExprWithYieldExtraction으로 전체 assignment를 처리하여
                            // 각 yield를 temp 변수로 추출하고 _state.sent()로 대체
                            const new_expr = try visitExprWithYieldExtraction(self, expr_idx, ops, next_label);
                            const new_stmt = try es_helpers.makeExprStmt(self, new_expr, stmt.span);
                            try ops.append(self.allocator, .{ .code = .statement, .arg = .{ .node = new_stmt } });
                        } else {
                            const new_stmt = try self.visitNode(stmt_idx);
                            try ops.append(self.allocator, .{ .code = .statement, .arg = .{ .node = new_stmt } });
                        }
                    } else if (es2015_scan.containsYield(self, expr_idx)) {
                        // foo(await x) — 중첩 yield를 추출 후 expression statement
                        const new_expr = try visitExprWithYieldExtraction(self, expr_idx, ops, next_label);
                        const new_stmt = try es_helpers.makeExprStmt(self, new_expr, stmt.span);
                        try ops.append(self.allocator, .{ .code = .statement, .arg = .{ .node = new_stmt } });
                    } else {
                        const new_stmt = try self.visitNode(stmt_idx);
                        try ops.append(self.allocator, .{ .code = .statement, .arg = .{ .node = new_stmt } });
                    }
                },
                .return_statement => {
                    const value_idx = stmt.data.unary.operand;
                    const new_value = if (value_idx.isNone())
                        NodeIndex.none
                    else
                        try lowerYieldingOperand(self, value_idx, stmt.span, ops, next_label);
                    try ops.append(self.allocator, .{ .code = .return_op, .arg = .{ .node = new_value } });
                },
                .throw_statement => {
                    const value_idx = stmt.data.unary.operand;
                    if (value_idx.isNone() or !es2015_scan.containsYield(self, value_idx)) {
                        const new_stmt = try self.visitNode(stmt_idx);
                        try ops.append(self.allocator, .{ .code = .statement, .arg = .{ .node = new_stmt } });
                    } else {
                        const new_value = try lowerYieldingOperand(self, value_idx, stmt.span, ops, next_label);
                        const throw_stmt = try self.ast.addNode(.{
                            .tag = .throw_statement,
                            .span = stmt.span,
                            .data = .{ .unary = .{ .operand = new_value, .flags = 0 } },
                        });
                        try ops.append(self.allocator, .{ .code = .statement, .arg = .{ .node = throw_stmt } });
                    }
                },
                .variable_declaration => {
                    // 모든 var는 호이스팅됨. init를 assignment로 변환.
                    _ = try collectVarDeclWithYield(self, stmt, ops, next_label, null);
                },
                .block_statement, .function_body => {
                    try collectBodyOperations(self, stmt_idx, ops, next_label);
                },
                .if_statement => {
                    try collectIfOperations(self, stmt_idx, stmt, ops, next_label);
                },
                .for_statement => {
                    try collectForOperations(self, stmt_idx, stmt, ops, next_label);
                },
                .while_statement => {
                    try collectWhileOperations(self, stmt_idx, stmt, ops, next_label);
                },
                .do_while_statement => {
                    try collectDoWhileOperations(self, stmt_idx, stmt, ops, next_label);
                },
                .try_statement => {
                    try collectTryOperations(self, stmt_idx, stmt, ops, next_label, .source);
                },
                .labeled_statement => {
                    // 라벨 붙은 for-of: 라벨을 풀이 결과 안쪽 for 에 붙여 수집한다 — 라벨이 풀이
                    // 블록에 붙으면 `continue <label>` 이 루프를 못 찾는다 (#4746).
                    const child = stmt.data.binary.right;
                    if (!child.isNone()) {
                        _ = try @import("es2025_using.zig").ES2025Using(Transformer).normalizeForOfUsingHead(self, child, false);
                        const child_node = self.ast.getNode(child);
                        if (child_node.tag == .for_of_statement) {
                            const rewritten = try ForOf.rewriteForOf(self, child, child_node, stmt.data.binary.left, true);
                            return collectOperations(self, rewritten, ops, next_label);
                        }
                    }
                    try collectLabeledOperations(self, stmt, ops, next_label);
                },
                .switch_statement => {
                    try collectSwitchOperations(self, stmt_idx, stmt, ops, next_label);
                },
                .for_of_statement, .for_in_statement => {
                    if (try @import("es2025_using.zig").ES2025Using(Transformer).normalizeForOfUsingHead(self, stmt_idx, false))
                        return collectOperations(self, stmt_idx, ops, next_label);
                    if (es2015_scan.hasYieldOrReturn(self, stmt_idx)) {
                        // for-of 는 일반 경로와 같은 풀이(반복자 for + 닫기 try/finally), for-in 은 키
                        // 스냅샷 + 인덱스 for 풀이로 바꿔 그 구조를 수집한다 (#4746).
                        const rewritten = if (stmt.tag == .for_in_statement)
                            try ForOf.rewriteForIn(self, stmt_idx, stmt)
                        else
                            try ForOf.rewriteForOf(self, stmt_idx, stmt, .none, true);
                        try collectOperations(self, rewritten, ops, next_label);
                    } else {
                        const new_stmt = try visitNativeStateRegion(self, stmt_idx);
                        if (!new_stmt.isNone()) {
                            try ops.append(self.allocator, .{ .code = .statement, .arg = .{ .node = new_stmt } });
                        }
                    }
                },
                .with_statement => {
                    if (es2015_scan.hasYieldOrReturn(self, stmt_idx)) return appendVisitedStatement(self, stmt_idx, ops, next_label);
                    const new_stmt = try visitNativeStateRegion(self, stmt_idx);
                    if (!new_stmt.isNone()) try ops.append(self.allocator, .{ .code = .statement, .arg = .{ .node = new_stmt } });
                },
                .for_await_of_statement => {
                    if (try @import("es2025_using.zig").ES2025Using(Transformer).normalizeForOfUsingHead(self, stmt_idx, false))
                        return collectOperations(self, stmt_idx, ops, next_label);
                    // for-await 는 방문 없는 풀이(반복자 while + 닫기 try/finally)로 바꿔 그 구조를
                    // 수집한다 (#4746 3단계). 본문이 상태 기계로 수집되므로 안쪽 for-of/for-in 의
                    // yield 도 제대로 접히고, 반복별 바인딩은 while 의 본문 캡처 추출이 맡는다.
                    // async generator 는 본문 전처리에서 이미 제자리 풀이돼 여기 오지 않는다.
                    const rewritten = try @import("es2018_for_await.zig").ES2018ForAwait(Transformer).rewriteForAwait(self, stmt_idx, stmt, .none, false, true);
                    try collectOperations(self, rewritten, ops, next_label);
                },
                .break_statement, .continue_statement => {
                    const target = resolveBreakContinueTarget(self, stmt);
                    if (target) |t| {
                        try ops.append(self.allocator, .{ .code = .break_op, .arg = .{ .label = t } });
                    } else {
                        const new_stmt = try self.visitNode(stmt_idx);
                        if (!new_stmt.isNone()) {
                            try ops.append(self.allocator, .{ .code = .statement, .arg = .{ .node = new_stmt } });
                        }
                    }
                },
                .class_declaration => {
                    // 헤더에 yield 가 있으면 먼저 꺼내 둔다 (#4723). 없으면 평소대로.
                    const target = if (es2015_scan.containsYield(self, stmt_idx))
                        try extractClassHeaderYields(self, stmt_idx, ops, next_label)
                    else
                        stmt_idx;
                    try appendVisitedStatement(self, try registeredClassAssignment(self, target, self.generator_operation_scope), ops, next_label);
                },
                else => try appendVisitedStatement(self, stmt_idx, ops, next_label),
            }
        }

        /// Visit a retained native statement after removing source var declarations.
        /// Their exact binding nodes were already moved into the wrapper declaration.
        fn visitNativeStateRegion(self: *Transformer, statement: NodeIndex) Transformer.Error!NodeIndex {
            const inherited = if (self.generator_operation_scope.isNone()) self.generator_state_machine_scope else self.generator_operation_scope;
            return self.visitNode(try rewriteNativeStateVars(self, statement, inherited));
        }

        fn nativeWriteScope(self: *Transformer, inherited: ScopeId) ScopeId {
            if (inherited.isNone() or inherited == self.generator_state_machine_scope) return self.generator_native_var_scope;
            return inherited;
        }

        fn nativeAssignmentPattern(self: *Transformer, binding: NodeIndex, scope: ScopeId, assignment_form: bool) Transformer.Error!NodeIndex {
            if (binding.isNone()) return binding;
            var node = self.ast.getNode(binding);
            switch (node.tag) {
                .binding_identifier => {
                    const ref = try self.makeIdentifierRefWithSymbol(node.data.string_ref, binding);
                    try self.trackUserWriteFromBinding(ref, binding, scope);
                    return ref;
                },
                .array_pattern, .object_pattern => {
                    const list = node.data.list;
                    var items: std.ArrayList(NodeIndex) = .empty;
                    defer items.deinit(self.allocator);
                    for (0..list.len) |i| {
                        const child: NodeIndex = @fromBackingInt(self.ast.extra_data.items[list.start + i]);
                        try items.append(self.allocator, try nativeAssignmentPattern(self, child, scope, assignment_form));
                    }
                    node.data.list = try self.ast.addNodeList(items.items);
                    if (assignment_form) node.tag = if (node.tag == .array_pattern) .array_assignment_target else .object_assignment_target;
                },
                .binding_property => {
                    const key = self.ast.getNode(node.data.binary.left);
                    const target = if (node.data.binary.right.isNone()) node.data.binary.left else node.data.binary.right;
                    node.data.binary.right = try nativeAssignmentPattern(self, target, scope, assignment_form);
                    if (key.tag == .binding_identifier) node.data.binary.left = try es_helpers.makePropertyNameFromSpan(self, key.data.string_ref);
                    if (assignment_form) node.tag = .assignment_target_property_property;
                },
                .assignment_pattern => {
                    node.data.binary.left = try nativeAssignmentPattern(self, node.data.binary.left, scope, assignment_form);
                    if (assignment_form) node.tag = .assignment_target_with_default;
                },
                .binding_rest_element => {
                    node.data.unary.operand = try nativeAssignmentPattern(self, node.data.unary.operand, scope, assignment_form);
                    if (assignment_form) node.tag = .assignment_target_rest;
                },
                else => return binding,
            }
            return self.ast.addNode(node);
        }

        fn nativeDeclarationExpression(self: *Transformer, declaration: NodeIndex, scope: ScopeId) Transformer.Error!NodeIndex {
            const node = self.ast.getNode(declaration);
            const start = self.readU32(node.data.extra, 1);
            const len = self.readU32(node.data.extra, 2);
            var expressions: std.ArrayList(NodeIndex) = .empty;
            defer expressions.deinit(self.allocator);
            for (0..len) |i| {
                const item = self.ast.getNode(@fromBackingInt(self.ast.extra_data.items[start + i]));
                const initializer = self.readNodeIdx(item.data.extra, 2);
                if (initializer.isNone()) continue;
                const binding = self.readNodeIdx(item.data.extra, 0);
                const target = try nativeAssignmentPattern(self, binding, scope, false);
                const saved_scope = self.current_scope;
                self.current_scope = scope;
                const statement = makeDestructuringAssignStmt(self, target, initializer, node.span, self.generator_state_machine_scope) catch |err| {
                    self.current_scope = saved_scope;
                    return err;
                };
                self.current_scope = saved_scope;
                try expressions.append(self.allocator, self.ast.getNode(statement).data.unary.operand);
            }
            if (expressions.items.len == 0) return .none;
            if (expressions.items.len == 1) return expressions.items[0];
            return self.ast.addNode(.{ .tag = .sequence_expression, .span = node.span, .data = .{ .list = try self.ast.addNodeList(expressions.items) } });
        }

        fn isNativeSourceVar(self: *Transformer, index: NodeIndex) bool {
            if (index.isNone() or @backingInt(index) >= self.parser_node_count) return false;
            const node = self.ast.getNode(index);
            return node.tag == .variable_declaration and self.ast.variableDeclarationKind(node) == .@"var";
        }

        /// The wrapper already owns this exact outer declaration binding.
        /// Keep the class expression's separate inner self binding on its SID.
        fn registeredClassAssignment(self: *Transformer, index: NodeIndex, inherited: ScopeId) Transformer.Error!NodeIndex {
            const node = self.ast.getNode(index);
            if (node.tag != .class_declaration or self.options.unsupported.class) return index;
            const name = self.readNodeIdx(node.data.extra, ast_mod.ClassExtra.name);
            if (name.isNone()) return index;
            if (!isRegisteredGeneratorBinding(self, name)) try registerStateMachineBindings(self, &.{name});
            if (!isRegisteredGeneratorBinding(self, name)) return index;
            const class_scope = self.outputOwnedScope(index) orelse return index;
            const origin = self.scope_owner_origins.get(@backingInt(index)) orelse @backingInt(index);
            const self_id = self.class_self_symbol_map.get(@backingInt(index)) orelse self.class_self_symbol_map.get(origin) orelse std.debug.panic("collected class has no exact self SID", .{});
            const symbols = if (self.semantic_editor) |*editor| editor.symbols.items else self.symbols;
            const inner_binding = try es_helpers.makeExactSyntheticBindingFromSpan(self, symbols[self_id].name);
            _ = try self.bindClassSelfStorage(index, inner_binding, class_scope);
            var slots: [8]u32 = undefined;
            for (0..slots.len) |i| slots[i] = self.ast.extra_data.items[node.data.extra + i];
            slots[ast_mod.ClassExtra.name] = @backingInt(inner_binding);
            const expression = try self.ast.addNode(.{ .tag = .class_expression, .span = node.span, .data = .{ .extra = try self.ast.addExtras(&slots) } });
            try self.remapCopiedScopeOwner(index, expression);
            try self.class_self_symbol_map.put(self.allocator, @backingInt(expression), self_id);
            const scope = if (inherited.isNone()) self.generator_state_machine_scope else inherited;
            const target = try nativeAssignmentPattern(self, name, nativeWriteScope(self, scope), false);
            return es_helpers.makeAssignStmt(self, target, expression, node.span, 0);
        }

        fn rewriteNativeStateVars(self: *Transformer, index: NodeIndex, inherited: ScopeId) Transformer.Error!NodeIndex {
            if (index.isNone()) return index;
            var node = self.ast.getNode(index);
            const scope = self.outputOwnedScope(index) orelse inherited;
            switch (node.tag) {
                .class_declaration => return registeredClassAssignment(self, index, inherited),
                .variable_declaration => {
                    if (!isNativeSourceVar(self, index)) return index;
                    const expression = try nativeDeclarationExpression(self, index, nativeWriteScope(self, scope));
                    return if (expression.isNone()) self.ast.addNode(.{ .tag = .empty_statement, .span = node.span, .data = .{ .none = 0 } }) else es_helpers.makeExprStmt(self, expression, node.span);
                },
                .block_statement, .function_body => {
                    const list = node.data.list;
                    for (0..list.len) |i| {
                        const child: NodeIndex = @fromBackingInt(self.ast.extra_data.items[list.start + i]);
                        const replacement = try rewriteNativeStateVars(self, child, scope);
                        self.ast.extra_data.items[list.start + i] = @backingInt(replacement);
                    }
                },
                .if_statement, .try_statement => {
                    node.data.ternary.a = if (node.tag == .try_statement) try rewriteNativeStateVars(self, node.data.ternary.a, scope) else node.data.ternary.a;
                    node.data.ternary.b = try rewriteNativeStateVars(self, node.data.ternary.b, scope);
                    node.data.ternary.c = try rewriteNativeStateVars(self, node.data.ternary.c, scope);
                },
                .while_statement, .do_while_statement, .labeled_statement, .catch_clause, .with_statement => node.data.binary.right = try rewriteNativeStateVars(self, node.data.binary.right, scope),
                .for_statement => {
                    const extra = node.data.extra;
                    const head = self.readNodeIdx(extra, 0);
                    if (isNativeSourceVar(self, head)) {
                        const expression = try nativeDeclarationExpression(self, head, nativeWriteScope(self, scope));
                        self.ast.extra_data.items[extra] = @backingInt(expression);
                    }
                    const body = try rewriteNativeStateVars(self, self.readNodeIdx(extra, 3), scope);
                    self.ast.extra_data.items[extra + 3] = @backingInt(body);
                },
                .for_in_statement, .for_of_statement => {
                    const head = node.data.ternary.a;
                    if (isNativeSourceVar(self, head)) {
                        const declaration = self.ast.getNode(head);
                        const item = self.ast.getNode(@fromBackingInt(self.ast.extra_data.items[self.readU32(declaration.data.extra, 1)]));
                        node.data.ternary.a = try nativeAssignmentPattern(self, self.readNodeIdx(item.data.extra, 0), nativeWriteScope(self, scope), true);
                    }
                    // The common loop-body producer preserves the original
                    // block and creates the head's actual lexical boundary.
                    node.data.ternary.c = try rewriteNativeStateVars(self, node.data.ternary.c, scope);
                },
                .switch_statement, .switch_case => {
                    const extra = node.data.extra;
                    const start = self.readU32(extra, 1);
                    const len = self.readU32(extra, 2);
                    for (0..len) |i| {
                        const child: NodeIndex = @fromBackingInt(self.ast.extra_data.items[start + i]);
                        const replacement = try rewriteNativeStateVars(self, child, scope);
                        self.ast.extra_data.items[start + i] = @backingInt(replacement);
                    }
                },
                // A nested function or class owns its own declarations. Expressions
                // also retain their source owner and are visited by the ordinary pass.
                else => return index,
            }
            self.ast.nodes.items[@backingInt(index)] = node;
            return index;
        }

        /// 문장을 visit 해 op 로 넣되, visit 이 `pending_nodes`/`trailing_nodes` 로 **보류한
        /// 문장까지** 같은 자리에 넣는다. (#4723)
        ///
        /// es5 클래스 선언은 `var C = (function () {…})()` 를 `pending_nodes` 에 넣고 `.none` 을
        /// 돌려준다. 보통은 감싼 `visitExtraList` 가 그걸 비워 제자리에 꽂지만, 상태 기계
        /// 수집기는 `visitExtraList` 를 거치지 않는다 — 그래서 보류 노드가 **바깥(모듈 최상위)
        /// 목록**으로 새어 클래스가 generator 밖으로 끌려 나갔다. 클로저(`tag` 등)를 잃고
        /// 모듈 로드 시점에 평가된다.
        fn appendVisitedStatement(self: *Transformer, stmt_idx: NodeIndex, ops: *std.ArrayList(Operation), next_label: *u32) Transformer.Error!void {
            const pending_top = self.pending_nodes.items.len;
            const trailing_top = self.trailing_nodes.items.len;
            const new_stmt = try self.visitNode(stmt_idx);

            // 보류 노드는 복사해 두고 즉시 되돌린다 — 아래 처리 중 또 쌓일 수 있다.
            var pending: std.ArrayListUnmanaged(NodeIndex) = .empty;
            defer pending.deinit(self.allocator);
            try pending.appendSlice(self.allocator, self.pending_nodes.items[pending_top..]);
            self.pending_nodes.shrinkRetainingCapacity(pending_top);
            var trailing: std.ArrayListUnmanaged(NodeIndex) = .empty;
            defer trailing.deinit(self.allocator);
            try trailing.appendSlice(self.allocator, self.trailing_nodes.items[trailing_top..]);
            self.trailing_nodes.shrinkRetainingCapacity(trailing_top);

            for (pending.items) |n| try appendHoistedStatement(self, n, ops, next_label);
            if (!new_stmt.isNone()) {
                try ops.append(self.allocator, .{ .code = .statement, .arg = .{ .node = new_stmt } });
            }
            for (trailing.items) |n| try appendHoistedStatement(self, n, ops, next_label);
        }

        /// 이미 visit 된 보류 문장을 op 로 넣는다. `var` 선언이면 대입으로 접고 이름을
        /// **바깥 함수**의 var 리스트에 등록한다 — 콜백 안 `var` 는 resume 마다 리셋된다.
        fn appendHoistedStatement(self: *Transformer, node_idx: NodeIndex, ops: *std.ArrayList(Operation), next_label: *u32) Transformer.Error!void {
            if (node_idx.isNone()) return;
            const node = self.ast.getNode(node_idx);
            if (node.tag != .variable_declaration) {
                try ops.append(self.allocator, .{ .code = .statement, .arg = .{ .node = node_idx } });
                return;
            }
            _ = try collectVarDeclWithYield(self, node, ops, next_label, null);
            // 등록은 collectVarDeclWithYield **뒤** — 그 안에서 다른 상태 기계가 만들어지면
            // 먼저 넣은 이름이 그쪽 리스트로 빨려 들어간다(#4716 에서 밟음).
            const e = node.data.extra;
            const list_start = self.readU32(e, 1);
            const list_len = self.readU32(e, 2);
            var i: u32 = 0;
            while (i < list_len) : (i += 1) {
                const decl = self.ast.getNode(@fromBackingInt(@intCast(self.ast.extra_data.items[list_start + i])));
                if (decl.tag != .variable_declarator) continue;
                const binding_idx = self.readNodeIdx(decl.data.extra, 0);
                const binding = self.ast.getNode(binding_idx);
                if (binding.tag == .binding_identifier) {
                    _ = try registerGeneratorVar(self, binding.data.string_ref, binding_idx);
                }
            }
        }

        /// if문의 연산 수집.
        fn collectIfOperations(self: *Transformer, stmt_idx: NodeIndex, stmt: Node, ops: *std.ArrayList(Operation), next_label: *u32) Transformer.Error!void {
            const condition = stmt.data.ternary.a;
            const then_body = stmt.data.ternary.b;
            const else_body = stmt.data.ternary.c;

            // body 는 statement → hasYieldOrReturn (yield + return 둘 다 검사),
            // condition 은 expression → return 불가, containsYield 만.
            const has_yield_in_cond = es2015_scan.containsYield(self, condition);
            if (!es2015_scan.hasYieldOrReturn(self, then_body) and !es2015_scan.hasYieldOrReturn(self, else_body) and !has_yield_in_cond) {
                const new_stmt = try visitNativeStateRegion(self, stmt_idx);
                if (!new_stmt.isNone()) {
                    try ops.append(self.allocator, .{ .code = .statement, .arg = .{ .node = new_stmt } });
                }
                return;
            }

            // 조건식에 yield/await가 있으면 먼저 추출 (short-circuit 미보존)
            const new_cond = if (has_yield_in_cond)
                try visitExprWithYieldExtraction(self, condition, ops, next_label)
            else
                try self.visitNode(condition);
            const has_else = !else_body.isNone();

            // `collectForOperations` 와 동일 sentinel/fixup 패턴 — end_label 을 미리 할당
            // 하면 then body 안 yield 가 같은 label 값을 yield-resume 으로 사용해 self-loop
            // 발생 (#1887). for/while/switch 는 이미 sentinel pattern, if 만 누락이었음.
            //
            // else_label 은 sentinel 안 씀 — `break_when_false` 의 ops 인덱스를 알므로 직접
            // patch (linear scan 회피). end_label 만 fixupSentinel 1 회.
            const if_ops_start = ops.items.len;
            const break_when_false_idx = if_ops_start;

            try ops.append(self.allocator, .{
                .code = .break_when_false,
                .arg = .{ .label_and_node = .{ .label = IF_END_SENTINEL, .node = new_cond } },
            });

            try collectBodyOperations(self, then_body, ops, next_label);

            // goto end (sentinel) — then body가 return/break로 끝나면 생략 (dead code 방지)
            if (ops.items.len == 0 or (ops.items[ops.items.len - 1].code != .return_op and ops.items[ops.items.len - 1].code != .break_op)) {
                try ops.append(self.allocator, .{ .code = .break_op, .arg = .{ .label = IF_END_SENTINEL } });
            }

            if (has_else) {
                const else_label = next_label.*;
                next_label.* += 1;
                try ops.append(self.allocator, .{ .code = .nop, .arg = .{ .none = {} } });
                // 직접 patch — break_when_false 가 인덱스 위치에 있음을 보장.
                ops.items[break_when_false_idx].arg.label_and_node.label = else_label;
                try collectBodyOperations(self, else_body, ops, next_label);
            }

            // end_label: then/else body 처리 *후* 에 할당 → yield 와 충돌 안 함.
            const end_label = next_label.*;
            next_label.* += 1;
            try ops.append(self.allocator, .{ .code = .nop, .arg = .{ .none = {} } });
            fixupSentinel(ops.items[if_ops_start..], IF_END_SENTINEL, end_label);
        }

        /// 상태 기계로 접히는 루프에서 `let`/`const` 의 **반복별 바인딩**을 복원한다. (#4716)
        ///
        /// es5 상태 기계는 지역 변수를 전부 함수 최상단 `var` 로 호이스트한다. 그러면
        /// 반복마다 새로 만들어져야 할 `let`/`const` 바인딩이 하나로 합쳐져, 루프 안에서
        /// 만든 클로저가 **전부 마지막 값을 캡처**한다(에러 없이 값만 틀린다).
        ///
        /// 일반 경로는 body 를 `var _loopN = function (x) {…}` 로 추출해 이를 복원한다.
        /// 상태 기계 경로는 body 에 `yield`/`await` 이 있어 평범한 함수로 못 뽑는다 —
        /// 그래서 **generator 로 뽑고 `yield*` 로 위임**한다. 상태 기계가 그 위임을
        /// `[5, __values(_loopN(x))]` 로 접고, `yield*` 의 값이 `_loopN` 의 return 값이라
        /// break/continue/return 신호(`call_and_check`)도 그대로 실려 온다.
        ///
        /// 추출이 필요 없으면 `.none` 을 돌려주고 호출부는 원래 노드를 그대로 쓴다.
        /// 추출하면 `var _loopN = function* (x) {…}` 문을 ops 에 먼저 방출하고, body 가
        /// 호출문으로 바뀐 **새 루프 노드**를 돌려준다.
        fn extractPerIterationLoopBody(
            self: *Transformer,
            stmt_idx: NodeIndex,
            stmt: Node,
            decl_idx: NodeIndex,
            body_idx: NodeIndex,
            ops: *std.ArrayList(Operation),
            next_label: *u32,
        ) Transformer.Error!NodeIndex {
            // The state machine hoists the bindings whether or not the target
            // has native `let` (chrome49 lowers async this way with native
            // block scoping), so the extraction does not depend on it (#4734).
            if (body_idx.isNone()) return .none;

            const BlockScoping = es2015_block_scoping.ES2015BlockScoping(Transformer);
            var lexical_names = try BlockScoping.collectLexicalVarNames(self, decl_idx);
            defer lexical_names.deinit(self.allocator);
            // 헤더 let/const 에 더해 본문 선언(let/const/class)과 catch 파라미터도 본다 — 상태
            // 기계는 이들을 wrapper var 로 올리므로 캡처되면 반복별로 뽑아야 한다 (#4743).
            var capture_names: std.ArrayList([]const u8) = .empty;
            defer capture_names.deinit(self.allocator);
            try capture_names.appendSlice(self.allocator, lexical_names.items);
            try BlockScoping.collectLoopBodyLexicalNames(self, body_idx, true, &capture_names);
            if (!BlockScoping.hasCapturedClosure(self, body_idx, capture_names.items)) return .none;
            var var_names: std.ArrayList([]const u8) = .empty;
            defer var_names.deinit(self.allocator);
            try BlockScoping.collectLoopBodyVarNames(self, body_idx, &var_names);
            var lexical_bindings: std.ArrayList(NodeIndex) = .empty;
            defer lexical_bindings.deinit(self.allocator);
            try BlockScoping.collectLexicalVarBindings(self, decl_idx, &lexical_bindings);
            // 헤더 수집에서 정한 이름으로 생성해야 후속 상태 기계 방문이 인자를
            // 다시 리네임하지 않는다. 캡처 판정은 위에서 원래 이름으로 마쳤다.
            for (lexical_names.items, lexical_bindings.items) |*name, binding| {
                name.* = self.renamedNameOf(binding) orelse name.*;
            }
            var var_bindings: std.ArrayList(NodeIndex) = .empty;
            defer var_bindings.deinit(self.allocator);
            try BlockScoping.collectLoopBodyVarBindings(self, body_idx, &var_bindings);

            var flow = BlockScoping.FlowResult{};
            defer flow.labels.deinit(self.allocator);
            BlockScoping.analyzeControlFlow(self, body_idx, &flow, 0, 0);

            // 라벨 붙은 break/continue 가 바깥 루프를 겨냥해도 추출한다. 호출부 검사가 신호를
            // `continue <label>` 문으로 되살리고(#4722), 상태 기계가 라벨 스택으로 해석한다.
            // (예전엔 검사가 `return` 으로 전달해 라벨 점프가 사라졌기에 여기서 포기했다.)
            const call_scope = loopCallScope(self, stmt_idx, lexical_bindings.items);
            const generator_parent_scope = loopFunctionParent(self, stmt_idx, stmt.tag, call_scope);

            const result = try BlockScoping.buildLoopClosureWithFlow(
                self,
                stmt_idx,
                body_idx,
                lexical_names.items,
                &flow,
                null,
                stmt.span,
                false, // is_async — 상태 기계 안에서는 await 도 yield 로 낮아진다
                BlockScoping.hasLexicalThisReference(self, body_idx),
                true, // is_generator
                null, // 본문은 아직 visit 전 — 추출된 generator 가 나중에 자기 temp 를 가진다
                var_names.items,
                lexical_bindings.items,
                var_bindings.items,
                call_scope,
                generator_parent_scope,
                false,
            );
            // `_loop` is an assignment inside the callback being built, but
            // that callback has no NodeIndex/ScopeId yet. Keep its exact owner
            // identity for the later generator-loop migration. An arbitrary
            // missing owner must still fail instead of using current_scope.
            // This also marks the synthetic boundary as transparent to source
            // lexical arrow captures during its later generator visit.
            try self.deferred_generator_loop_owners.put(self.allocator, @backingInt(result.loop_function), .{
                .function_scope = result.generator_function_scope,
            });

            // `var _loopN = function* (x) {…}` 은 대입문으로 접히므로, 이름을 **바깥 함수**
            // 의 var 리스트에 등록해야 한다. 상태 기계가 만들어진 뒤에 생긴 이름이라
            // 일반 호이스팅 스캔(`collectHoistedVars`)에 안 잡힌다 — 등록을 빠뜨리면
            // `ReferenceError: _loop is not defined`.
            const loop_fn_node = self.ast.getNode(result.loop_fn);
            const loop_binding_node = self.ast.getNode(result.loop_binding);
            if (loop_binding_node.tag != .binding_identifier)
                std.debug.panic("extracted generator loop result lost its exact binding node", .{});
            const loop_name_span = loop_binding_node.data.string_ref;
            // ⚠️ 등록은 **collectVarDeclWithYield 뒤**에 해야 한다. 그 안에서 `_loopN` 의
            // generator 본문이 낮아지며 자기 상태 기계를 만드는데, 먼저 넣어 두면 그
            // 안쪽 리스트로 들어가 `var _loop;` 이 엉뚱한 함수에 선언된다.
            const loop_producer_index = try collectVarDeclWithYield(
                self,
                loop_fn_node,
                ops,
                next_label,
                result.loop_binding,
            );
            if (self.semantic_edit_enabled) {
                const loop_symbol_id = result.loop_symbol_id orelse
                    std.debug.panic("extracted generator loop lost its producer SymbolId", .{});
                const loop_owner_scope = result.loop_owner_scope;
                if (loop_owner_scope.isNone() or loop_owner_scope != self.generator_state_machine_scope)
                    std.debug.panic("extracted generator loop binding owner changed before state-machine hoisting", .{});
                const index = loop_producer_index orelse
                    std.debug.panic("extracted generator loop binding lost its producer handle", .{});
                if (index >= self.generator_temp_producer_identities.items.len or
                    index >= self.generator_temp_var_spans.items.len)
                    std.debug.panic("extracted generator loop producer handle is out of range", .{});
                const producer = &self.generator_temp_producer_identities.items[index];
                if (producer.source_binding != result.loop_binding)
                    std.debug.panic("extracted generator loop producer handle changed its binding", .{});
                const producer_span = self.generator_temp_var_spans.items[index];
                if (producer_span.start != loop_name_span.start or producer_span.end != loop_name_span.end)
                    std.debug.panic("extracted generator loop producer handle changed its name span", .{});
                if (self.getSymbolIdAt(result.loop_binding) != @as(?u32, @backingInt(loop_symbol_id)))
                    std.debug.panic("extracted generator loop AST handoff disagrees with its producer identity", .{});
                if (producer.symbol_id) |existing_id| {
                    if (existing_id != @backingInt(loop_symbol_id))
                        std.debug.panic("extracted generator loop producer record changed its SymbolId", .{});
                }
                if (!producer.owner_scope.isNone() and producer.owner_scope != loop_owner_scope)
                    std.debug.panic("extracted generator loop producer record changed its owner ScopeId", .{});
                producer.symbol_id = @backingInt(loop_symbol_id);
                producer.owner_scope = loop_owner_scope;
                producer.producer_owned = true;
            } else {
                try appendGeneratorTempSpan(self, loop_name_span);
            }
            // break/continue/return 신호를 받는 `_ret` 도 같은 이유로 등록한다.
            if (flow.needsRetVar()) {
                const ret_temp_span = result.ret_temp_span orelse
                    std.debug.panic("extracted generator control-flow check lost its exact return-temp span", .{});
                const ret_temp_binding = result.ret_temp_binding orelse
                    std.debug.panic("extracted generator control-flow check lost its exact return-temp binding", .{});
                const ret_binding_node = self.ast.getNode(ret_temp_binding);
                if (ret_binding_node.tag != .binding_identifier or
                    !std.mem.eql(u8, self.ast.getText(ret_binding_node.data.string_ref), self.ast.getText(ret_temp_span)))
                    std.debug.panic("extracted generator control-flow binding disagrees with its name span", .{});
                if (result.ret_temp_symbol_id) |symbol_id| {
                    if (result.ret_temp_owner_scope == self.generator_state_machine_scope and
                        !result.ret_temp_owner_scope.isNone())
                    {
                        try appendGeneratorTempSpanWithIdentity(self, ret_temp_span, symbol_id, result.ret_temp_owner_scope);
                    } else {
                        try appendGeneratorTempSpanWithDeferredIdentity(
                            self,
                            ret_temp_span,
                            symbol_id,
                            result.ret_temp_owner_scope,
                            self.generator_state_machine_scope,
                        );
                    }
                    attachGeneratorTempProducerBinding(self, ret_temp_binding, ret_temp_span, symbol_id);
                } else if (self.semantic_edit_enabled) {
                    // buildControlFlowCheck already registered this exact
                    // binding with bindHoistedTemp while its callback scope
                    // was unknown. Preserve that NodeIndex handoff instead of
                    // rebuilding the producer from its spelling later.
                    requireCallbackLocalGeneratorTempBinding(self, ret_temp_binding, ret_temp_span);
                } else {
                    // Semantic-less transforms retain the legacy name-only
                    // temp list because no producer graph is available.
                    try appendGeneratorTempSpan(self, ret_temp_span);
                }
            }

            // body 만 교체한 새 루프 노드.
            return switch (stmt.tag) {
                .for_statement => blk: {
                    const e = stmt.data.extra;
                    const new_extra = try self.ast.addExtras(&.{
                        @backingInt(self.readNodeIdx(e, 0)),
                        @backingInt(self.readNodeIdx(e, 1)),
                        @backingInt(self.readNodeIdx(e, 2)),
                        @backingInt(result.call_and_check),
                    });
                    break :blk try self.ast.addNode(.{
                        .tag = .for_statement,
                        .span = stmt.span,
                        .data = .{ .extra = new_extra },
                    });
                },
                .for_of_statement, .for_in_statement, .for_await_of_statement => try self.ast.addNode(.{
                    .tag = stmt.tag,
                    .span = stmt.span,
                    .data = .{ .ternary = .{
                        .a = stmt.data.ternary.a,
                        .b = stmt.data.ternary.b,
                        .c = result.call_and_check,
                    } },
                }),
                .while_statement, .do_while_statement => try self.ast.addNode(.{
                    .tag = stmt.tag,
                    .span = stmt.span,
                    .data = .{ .binary = .{ .left = stmt.data.binary.left, .right = result.call_and_check, .flags = stmt.data.binary.flags } },
                }),
                else => .none,
            };
        }

        /// 제어흐름 재작성은 중첩 루프 노드를 복사하지만 헤더 바인딩은 유지한다.
        /// owner가 없는 복사본도 보존된 SymbolId의 선언 스코프로 호출 위치를 정한다.
        fn loopCallScope(self: *Transformer, stmt_idx: NodeIndex, bindings: []const NodeIndex) @import("../semantic/scope.zig").ScopeId {
            if (!self.semantic_edit_enabled) return self.current_scope;
            if (self.scope_owner_map.get(@backingInt(stmt_idx)) orelse self.transformed_scope_owner_map.get(@backingInt(stmt_idx))) |scope|
                return @fromBackingInt(@intCast(scope));
            for (bindings) |binding| {
                const id = self.getSymbolIdAt(binding) orelse continue;
                const symbols = if (self.semantic_editor) |*editor| editor.symbols.items else self.symbols;
                return symbols[id].scope_id;
            }
            if (!self.generator_operation_scope.isNone()) return self.generator_operation_scope;
            return self.current_scope;
        }

        fn loopFunctionParent(self: *Transformer, owner: NodeIndex, loop_tag: Node.Tag, call_scope: @import("../semantic/scope.zig").ScopeId) @import("../semantic/scope.zig").ScopeId {
            if (!self.semantic_edit_enabled) return .none;
            const has_loop_scope = switch (loop_tag) {
                .for_statement, .for_in_statement, .for_of_statement, .for_await_of_statement => true,
                else => false,
            };
            if (!has_loop_scope) return call_scope;
            const raw = @backingInt(owner);
            const has_exact_loop_owner = !self.scope_owner_removed.contains(raw) and
                (self.transformed_scope_owner_map.contains(raw) or self.scope_owner_map.contains(raw) or
                    (if (self.semantic_editor) |*editor| editor.scope_owner_map.contains(raw) else false));
            // A transformed generator loop can be a synthetic for-statement
            // with no source loop scope. In that case call_scope already is its
            // exact insertion parent; walking to its parent would detach outer
            // lexical bindings such as a captured generator parameter.
            if (!has_exact_loop_owner) return call_scope;
            if (call_scope.isNone()) std.debug.panic("generator loop call has no source scope", .{});
            const scopes = if (self.semantic_editor) |*editor| editor.scopes.items else self.scopes;
            if (call_scope.toIndex() >= scopes.len) std.debug.panic("generator loop call scope is invalid", .{});
            const parent = scopes[call_scope.toIndex()].parent;
            if (parent.isNone()) std.debug.panic("generator loop has no output function parent", .{});
            return parent;
        }

        /// for문의 연산 수집.
        fn collectForOperations(self: *Transformer, stmt_idx: NodeIndex, stmt: Node, ops: *std.ArrayList(Operation), next_label: *u32) Transformer.Error!void {
            const e = stmt.data.extra;
            const init_idx: NodeIndex = self.readNodeIdx(e, 0);
            const test_idx: NodeIndex = self.readNodeIdx(e, 1);
            const update_idx: NodeIndex = self.readNodeIdx(e, 2);
            const body_idx: NodeIndex = self.readNodeIdx(e, 3);
            // 헤더의 let/const 는 루프 스코프 — 고유 이름으로 바꿔 wrapper 에 등록한다 (#4712).
            try registerLoopHeadBindings(self, init_idx);

            // body 는 statement → hasYieldOrReturn, 헤더 세 칸은 expression → containsYield.
            // ⚠️ init/update 를 빼면 헤더에만 yield 가 있을 때 루프가 상태 기계를 안 타고
            // raw `yield` 가 남아 **산출물이 파싱조차 안 된다** (#4721).
            if (!es2015_scan.hasYieldOrReturn(self, body_idx) and
                !es2015_scan.containsYield(self, test_idx) and
                !es2015_scan.containsYield(self, init_idx) and
                !es2015_scan.containsYield(self, update_idx))
            {
                const new_stmt = try visitNativeStateRegion(self, stmt_idx);
                if (!new_stmt.isNone()) {
                    try ops.append(self.allocator, .{ .code = .statement, .arg = .{ .node = new_stmt } });
                }
                return;
            }

            // 반복별 바인딩 복원(#4716) — 필요하면 body 를 `yield* _loopN(x)` 로 바꾼 새
            // 노드로 다시 수집한다. 이 검사는 위 early-return **뒤**라, 상태 기계로 접히는
            // 루프에만 적용된다.
            {
                const rewritten = try extractPerIterationLoopBody(self, stmt_idx, stmt, init_idx, body_idx, ops, next_label);
                if (!rewritten.isNone()) {
                    return collectForOperations(self, rewritten, self.ast.getNode(rewritten), ops, next_label);
                }
            }

            // init: var는 호이스팅 후 assignment로 변환, expression은 그대로
            if (!init_idx.isNone()) {
                const init_node = self.ast.getNode(init_idx);
                if (init_node.tag == .variable_declaration) {
                    // var i = 0 → i = 0 (var는 이미 호이스팅됨)
                    _ = try collectVarDeclWithYield(self, init_node, ops, next_label, null);
                } else {
                    const new_init = try self.visitNode(init_idx);
                    if (!new_init.isNone()) {
                        const init_stmt = try es_helpers.makeExprStmt(self, new_init, stmt.span);
                        try ops.append(self.allocator, .{ .code = .statement, .arg = .{ .node = init_stmt } });
                    }
                }
            }

            // cond_label만 미리 할당. end_label은 body 처리 후 결정 (sentinel+fixup).
            const cond_label = next_label.*;
            next_label.* += 1;

            try ops.append(self.allocator, .{ .code = .nop, .arg = .{ .none = {} } }); // mark cond_label

            // 중첩 루프에서 충돌 방지를 위해 label_stack 깊이 기반 sentinel 사용.
            const depth = self.generator_label_stack.items.len;
            const for_break_sent = breakSentinel(depth);
            const for_continue_sent = continueSentinel(depth);
            const for_ops_start = ops.items.len;

            // test (for_break_sent는 body 처리 후 fixup)
            if (!test_idx.isNone()) {
                const new_test = if (es2015_scan.containsYield(self, test_idx))
                    try visitExprWithYieldExtraction(self, test_idx, ops, next_label)
                else
                    try self.visitNode(test_idx);
                try ops.append(self.allocator, .{
                    .code = .break_when_false,
                    .arg = .{ .label_and_node = .{ .label = for_break_sent, .node = new_test } },
                });
            }

            // unlabeled break/continue를 이 루프로 라우팅. 중첩 루프는 스택으로 분리.
            try self.generator_label_stack.append(self.allocator, .{
                .name = "",
                .break_label = for_break_sent,
                .continue_label = for_continue_sent,
            });
            defer _ = self.generator_label_stack.pop();

            // body
            try collectBodyOperations(self, body_idx, ops, next_label);

            // update (별도 label — continue의 대상)
            const update_label = next_label.*;
            next_label.* += 1;
            self.generator_loop_continue_label = update_label;
            try ops.append(self.allocator, .{ .code = .nop, .arg = .{ .none = {} } }); // mark update_label
            if (!update_idx.isNone()) {
                // update 절에도 yield 가 올 수 있다 — 추출하지 않으면 raw `yield` 가
                // 남아 산출물이 파싱되지 않는다 (#4721).
                const new_update = if (es2015_scan.containsYield(self, update_idx))
                    try visitExprWithYieldExtraction(self, update_idx, ops, next_label)
                else
                    try self.visitNode(update_idx);
                if (!new_update.isNone()) {
                    const update_stmt = try es_helpers.makeExprStmt(self, new_update, stmt.span);
                    try ops.append(self.allocator, .{ .code = .statement, .arg = .{ .node = update_stmt } });
                }
            }

            // goto cond_label
            try ops.append(self.allocator, .{ .code = .break_op, .arg = .{ .label = cond_label } });

            // end_label: body 처리 완료 후 할당
            const end_label = next_label.*;
            next_label.* += 1;

            // fixup: break/continue sentinel → 실제 label
            fixupSentinel(ops.items[for_ops_start..], for_break_sent, end_label);
            fixupSentinel(ops.items[for_ops_start..], for_continue_sent, update_label);

            // mark end_label
            try ops.append(self.allocator, .{ .code = .nop, .arg = .{ .none = {} } });
        }

        /// for-of/for-in 문의 연산 수집.
        /// for (const x of arr) { yield ... }
        /// → for (var _i = 0, _arr = arr; _i < _arr.length; _i++) { var x = _arr[_i]; yield ... }
        /// for-in은 Object.keys(obj) snapshot을 순회하는 동일한 배열 기반 루프로 낮춘다.
        /// while문의 연산 수집.
        fn collectWhileOperations(self: *Transformer, stmt_idx: NodeIndex, stmt: Node, ops: *std.ArrayList(Operation), next_label: *u32) Transformer.Error!void {
            const condition = stmt.data.binary.left;
            const body_idx = stmt.data.binary.right;

            // body 는 statement → hasYieldOrReturn, condition 은 expression → containsYield 만.
            if (!es2015_scan.hasYieldOrReturn(self, body_idx) and !es2015_scan.containsYield(self, condition)) {
                const new_stmt = try visitNativeStateRegion(self, stmt_idx);
                if (!new_stmt.isNone()) {
                    try ops.append(self.allocator, .{ .code = .statement, .arg = .{ .node = new_stmt } });
                }
                return;
            }

            // 본문 선언이 클로저에 캡처되면 반복별로 뽑는다 (#4743).
            {
                const rewritten = try extractPerIterationLoopBody(self, stmt_idx, stmt, .none, body_idx, ops, next_label);
                if (!rewritten.isNone()) return collectWhileOperations(self, rewritten, self.ast.getNode(rewritten), ops, next_label);
            }

            const cond_label = next_label.*;
            next_label.* += 1;

            try ops.append(self.allocator, .{ .code = .nop, .arg = .{ .none = {} } }); // mark cond_label

            const depth = self.generator_label_stack.items.len;
            const while_break_sent = breakSentinel(depth);
            const ops_start = ops.items.len;

            const new_cond = if (es2015_scan.containsYield(self, condition))
                try visitExprWithYieldExtraction(self, condition, ops, next_label)
            else
                try self.visitNode(condition);
            try ops.append(self.allocator, .{
                .code = .break_when_false,
                .arg = .{ .label_and_node = .{ .label = while_break_sent, .node = new_cond } },
            });

            try self.generator_label_stack.append(self.allocator, .{
                .name = "",
                .break_label = while_break_sent,
                .continue_label = cond_label,
            });
            defer _ = self.generator_label_stack.pop();

            // body (yield가 nop를 생성하여 next_label이 증가할 수 있음)
            try collectBodyOperations(self, body_idx, ops, next_label);

            // goto cond_label
            try ops.append(self.allocator, .{ .code = .break_op, .arg = .{ .label = cond_label } });

            // 바깥 labeled statement 가 `continue <label>` 타겟을 찾을 수 있게 남긴다.
            // for-await 는 여기 while 로 낮아지므로, 그 라벨의 continue 타겟이 곧 이
            // while 의 cond_label(= 다음 `await _iter.next()`) 이다. body 수집 **뒤**에
            // 써야 중첩 루프가 아니라 자기 자신이 마지막에 남는다. (#4710)
            self.generator_loop_continue_label = cond_label;

            // end_label을 body 처리 후에 할당 (yield로 인한 label 증가 반영)
            const end_label = next_label.*;
            next_label.* += 1;
            try ops.append(self.allocator, .{ .code = .nop, .arg = .{ .none = {} } }); // mark end_label

            fixupSentinel(ops.items[ops_start..], while_break_sent, end_label);
        }

        /// break/continue 문의 대상 sentinel을 결정.
        /// labeled → generator_label_stack에서 name 매칭 (없으면 null).
        /// unlabeled → 스택 top에서 가장 가까운 적절한 entry 선택
        ///   · break: 가장 안쪽 루프 또는 switch 진입 시 push된 entry
        ///   · continue: continue_label이 있는 가장 안쪽 loop entry (switch 스킵)
        fn resolveBreakContinueTarget(self: *Transformer, stmt: Node) ?u32 {
            const label_idx = stmt.data.unary.operand;
            const stack = self.generator_label_stack.items;
            if (stack.len == 0) return null;

            if (!label_idx.isNone()) {
                const label_text = self.ast.getText(self.ast.getNode(label_idx).span);
                var i = stack.len;
                while (i > 0) {
                    i -= 1;
                    if (Scanner.identifierNamesEqual(stack[i].name, label_text)) {
                        if (stmt.tag == .continue_statement)
                            return stack[i].continue_label orelse stack[i].break_label;
                        return stack[i].break_label;
                    }
                }
                return null;
            }

            // unlabeled
            if (stmt.tag == .continue_statement) {
                var i = stack.len;
                while (i > 0) {
                    i -= 1;
                    if (stack[i].continue_label) |c| return c;
                }
                return null;
            }
            return stack[stack.len - 1].break_label;
        }

        const LABEL_SENTINEL_BASE = std.math.maxInt(u32);

        // Sentinel reserved ranges (모두 LABEL_SENTINEL_BASE 의 offset). fixupSentinel 가
        // ops_start 이후만 처리하므로 nested scope 끼리는 충돌 안 함.
        //   0..depth*2  → break/continue (nesting depth 별 — `breakSentinel`/`continueSentinel`)
        //   100..       → switch case fall-through (`collectSwitchOperations`)
        //   200         → if-end (`collectIfOperations`)
        //   if-else 는 break_when_false 의 인덱스 직접 patch — sentinel 불필요.
        const IF_END_SENTINEL = LABEL_SENTINEL_BASE - 200;

        /// nesting depth에 따라 고유한 break/continue sentinel 생성.
        /// 중첩 labeled scope에서 sentinel 충돌을 방지.
        fn breakSentinel(depth: usize) u32 {
            return LABEL_SENTINEL_BASE - @as(u32, @intCast(depth * 2));
        }
        fn continueSentinel(depth: usize) u32 {
            return LABEL_SENTINEL_BASE - @as(u32, @intCast(depth * 2)) - 1;
        }

        /// ops 슬라이스에서 sentinel 값을 실제 label로 교체.
        fn fixupSentinel(ops_slice: []Operation, sentinel: u32, actual: u32) void {
            for (ops_slice) |*op| {
                switch (op.code) {
                    .break_op => {
                        if (op.arg == .label and op.arg.label == sentinel) {
                            op.arg = .{ .label = actual };
                        }
                    },
                    .break_when_false, .break_when_true => {
                        if (op.arg == .label_and_node and op.arg.label_and_node.label == sentinel) {
                            op.arg = .{ .label_and_node = .{ .label = actual, .node = op.arg.label_and_node.node } };
                        }
                    },
                    else => {},
                }
            }
        }

        /// labeled statement의 연산 수집.
        /// break/continue label은 body 처리 후에 결정 (sentinel+fixup).
        fn collectLabeledOperations(self: *Transformer, stmt: Node, ops: *std.ArrayList(Operation), next_label: *u32) Transformer.Error!void {
            const label_idx = stmt.data.binary.left;
            const body_idx = stmt.data.binary.right;

            const label_name = if (!label_idx.isNone()) blk: {
                const label_node = self.ast.getNode(label_idx);
                break :blk self.ast.getText(label_node.span);
            } else "";

            const body_node = self.ast.getNode(body_idx);
            const is_loop = body_node.tag == .for_statement or
                body_node.tag == .while_statement or
                body_node.tag == .do_while_statement or
                body_node.tag == .for_in_statement or
                body_node.tag == .for_of_statement or
                // ⚠️ for-await 가 빠져 있었다 (#4710). 빠지면 `continue <label>` 이
                // `continue_label orelse break_label` 로 떨어져 **바깥 루프를 끊는다**.
                body_node.tag == .for_await_of_statement;

            // while 을 제외한 모든 루프(for/for-of/for-in/do-while)는 `continue` 타겟
            // (증분·iterator advance·조건 평가)이 body 수집 *후*에야 정해지므로 sentinel +
            // generator_loop_continue_label 로 지연 fixup 한다. while 만 `continue` = cond_label
            // (루프 최상단)이라 즉시 결정.
            const continue_via_update_label = is_loop and body_node.tag != .while_statement;
            const depth = self.generator_label_stack.items.len;
            const break_sent = breakSentinel(depth);
            const continue_sent = continueSentinel(depth);

            const continue_label: ?u32 = if (!is_loop)
                null
            else if (continue_via_update_label)
                continue_sent // body 처리 후 generator_loop_continue_label 로 fixup
            else
                next_label.*; // while: cond_label

            const ops_start = ops.items.len;
            const saved_update_label = self.generator_loop_continue_label;
            self.generator_loop_continue_label = null;

            try self.generator_label_stack.append(self.allocator, .{
                .name = label_name,
                .break_label = break_sent,
                .continue_label = continue_label,
            });

            try self.label_scope.append(self.allocator, label_name);
            try collectOperations(self, body_idx, ops, next_label);
            _ = self.label_scope.pop();

            _ = self.generator_label_stack.pop();

            const actual_continue = if (continue_via_update_label) self.generator_loop_continue_label orelse @as(u32, 0) else @as(u32, 0);
            self.generator_loop_continue_label = saved_update_label;

            const end_label = next_label.*;
            next_label.* += 1;

            // fixup: break sentinel → end_label, continue sentinel → actual_continue
            const ops_slice = ops.items[ops_start..];
            fixupSentinel(ops_slice, break_sent, end_label);
            if (continue_via_update_label) {
                fixupSentinel(ops_slice, continue_sent, actual_continue);
            }

            try ops.append(self.allocator, .{ .code = .nop, .arg = .{ .none = {} } });
        }

        /// switch문의 연산 수집.
        /// switch(x) { case 1: yield a; break; default: yield b; }
        /// → if-else 체인으로 분해 + 각 case body를 순서대로 배치.
        /// case_labels는 sentinel+fixup으로 body 처리 후 결정.
        fn collectSwitchOperations(self: *Transformer, stmt_idx: NodeIndex, stmt: Node, ops: *std.ArrayList(Operation), next_label: *u32) Transformer.Error!void {
            const e = stmt.data.extra;
            const disc_idx: NodeIndex = self.readNodeIdx(e, 0);
            const cases_start_val = self.readU32(e, 1);
            const cases_len_val = self.readU32(e, 2);

            if (!es2015_scan.hasYieldOrReturn(self, stmt_idx)) {
                const new_stmt = try visitNativeStateRegion(self, stmt_idx);
                if (!new_stmt.isNone()) {
                    try ops.append(self.allocator, .{ .code = .statement, .arg = .{ .node = new_stmt } });
                }
                return;
            }

            const new_disc = try self.visitNode(disc_idx);

            // 각 case에 고유 sentinel 할당 (body 처리 후 실제 label로 fixup)
            const sentinel_base = LABEL_SENTINEL_BASE - 100; // 충분히 떨어진 sentinel 영역
            var case_sentinels = try self.allocator.alloc(u32, cases_len_val);
            defer self.allocator.free(case_sentinels);
            var default_case_idx: ?usize = null;

            // Pass 1: sentinel 할당 + default 감지 (visitNode 호출 없음)
            for (0..cases_len_val) |i| {
                case_sentinels[i] = sentinel_base - @as(u32, @intCast(i));

                // default case 감지
                const raw_idx = self.ast.extra_data.items[cases_start_val + i];
                const case_node = self.ast.getNode(@fromBackingInt(@intCast(raw_idx)));
                const ce = case_node.data.extra;
                const test_idx: NodeIndex = self.readNodeIdx(ce, 0);
                if (test_idx.isNone()) {
                    default_case_idx = i;
                }
            }

            const end_sentinel = sentinel_base - @as(u32, @intCast(cases_len_val));
            const ops_start = ops.items.len;

            // 분기 코드: if (disc === caseTest) goto case_sentinel
            // visitNode가 extra_data를 재할당할 수 있으므로 인덱스 루프 사용
            for (0..cases_len_val) |i| {
                const raw_idx = self.ast.extra_data.items[cases_start_val + i];
                const case_node = self.ast.getNode(@fromBackingInt(@intCast(raw_idx)));
                const ce = case_node.data.extra;
                const test_idx: NodeIndex = self.readNodeIdx(ce, 0);

                if (test_idx.isNone()) continue; // default

                const new_test = try self.visitNode(test_idx);
                const eq_check = try self.ast.addNode(.{
                    .tag = .binary_expression,
                    .span = stmt.span,
                    .data = .{ .binary = .{
                        .left = new_disc,
                        .right = new_test,
                        .flags = @backingInt(token_mod.Kind.eq3),
                    } },
                });

                try ops.append(self.allocator, .{
                    .code = .break_when_true,
                    .arg = .{ .label_and_node = .{ .label = case_sentinels[i], .node = eq_check } },
                });
            }

            // default가 있으면 goto default, 없으면 goto end
            if (default_case_idx) |di| {
                try ops.append(self.allocator, .{ .code = .break_op, .arg = .{ .label = case_sentinels[di] } });
            } else {
                try ops.append(self.allocator, .{ .code = .break_op, .arg = .{ .label = end_sentinel } });
            }

            // 각 case body 출력 + 실제 label 할당
            var actual_labels = try self.allocator.alloc(u32, cases_len_val);
            defer self.allocator.free(actual_labels);

            // visitNode/collectOperations가 extra_data를 재할당할 수 있으므로 인덱스 루프 사용
            for (0..cases_len_val) |i| {
                // case body 시작 지점에 실제 label 할당
                actual_labels[i] = next_label.*;
                next_label.* += 1;
                try ops.append(self.allocator, .{ .code = .nop, .arg = .{ .none = {} } });

                const raw_idx = self.ast.extra_data.items[cases_start_val + i];
                const case_node = self.ast.getNode(@fromBackingInt(@intCast(raw_idx)));
                const ce = case_node.data.extra;
                const stmts_s = self.readU32(ce, 1);
                const stmts_l = self.readU32(ce, 2);

                // visitNode/collectOperations가 extra_data를 재할당할 수 있으므로 인덱스 루프 사용
                var j_loop: u32 = 0;
                while (j_loop < stmts_l) : (j_loop += 1) {
                    const case_stmt_raw = self.ast.extra_data.items[stmts_s + j_loop];
                    const case_stmt = self.ast.getNode(@fromBackingInt(@intCast(case_stmt_raw)));
                    if (case_stmt.tag == .break_statement and case_stmt.data.unary.operand.isNone()) {
                        try ops.append(self.allocator, .{ .code = .break_op, .arg = .{ .label = end_sentinel } });
                    } else {
                        try collectOperations(self, @fromBackingInt(@intCast(case_stmt_raw)), ops, next_label);
                    }
                }
            }

            // end label
            const actual_end = next_label.*;
            next_label.* += 1;
            try ops.append(self.allocator, .{ .code = .nop, .arg = .{ .none = {} } });

            // fixup: sentinel → actual labels
            const ops_slice = ops.items[ops_start..];
            for (case_sentinels, 0..) |sent, i| {
                fixupSentinel(ops_slice, sent, actual_labels[i]);
            }
            fixupSentinel(ops_slice, end_sentinel, actual_end);
        }

        /// do-while문의 연산 수집. body → condition 순서.
        fn collectDoWhileOperations(self: *Transformer, stmt_idx: NodeIndex, stmt: Node, ops: *std.ArrayList(Operation), next_label: *u32) Transformer.Error!void {
            const condition = stmt.data.binary.left;
            const body_idx = stmt.data.binary.right;

            // body 는 statement → hasYieldOrReturn, condition 은 expression → containsYield 만.
            if (!es2015_scan.hasYieldOrReturn(self, body_idx) and !es2015_scan.containsYield(self, condition)) {
                const new_stmt = try visitNativeStateRegion(self, stmt_idx);
                if (!new_stmt.isNone()) {
                    try ops.append(self.allocator, .{ .code = .statement, .arg = .{ .node = new_stmt } });
                }
                return;
            }

            // 본문 선언이 클로저에 캡처되면 반복별로 뽑는다 (#4743).
            {
                const rewritten = try extractPerIterationLoopBody(self, stmt_idx, stmt, .none, body_idx, ops, next_label);
                if (!rewritten.isNone()) return collectDoWhileOperations(self, rewritten, self.ast.getNode(rewritten), ops, next_label);
            }

            const body_label = next_label.*;
            next_label.* += 1;

            try ops.append(self.allocator, .{ .code = .nop, .arg = .{ .none = {} } }); // mark body_label

            const depth = self.generator_label_stack.items.len;
            const dw_break_sent = breakSentinel(depth);
            const dw_continue_sent = continueSentinel(depth);
            const ops_start = ops.items.len;

            // unlabeled break/continue를 이 do-while로 라우팅.
            try self.generator_label_stack.append(self.allocator, .{
                .name = "",
                .break_label = dw_break_sent,
                .continue_label = dw_continue_sent,
            });
            {
                defer _ = self.generator_label_stack.pop();
                // body
                try collectBodyOperations(self, body_idx, ops, next_label);
            }

            // continue는 condition 평가 지점으로 점프
            const cond_label = next_label.*;
            next_label.* += 1;
            // 라벨된 `continue label;` 도 (unlabeled 와 동일하게) 조건 평가 지점으로 가도록
            // cond_label 을 generator_loop_continue_label 로 노출 — 이전엔 라벨 경로가 body_label 로
            // 잘못 점프해 조건을 재평가하지 않았다 (#4281).
            self.generator_loop_continue_label = cond_label;
            try ops.append(self.allocator, .{ .code = .nop, .arg = .{ .none = {} } }); // mark cond_label

            // condition → if true, goto body_label
            const new_cond = if (es2015_scan.containsYield(self, condition))
                try visitExprWithYieldExtraction(self, condition, ops, next_label)
            else
                try self.visitNode(condition);
            try ops.append(self.allocator, .{
                .code = .break_when_true,
                .arg = .{ .label_and_node = .{ .label = body_label, .node = new_cond } },
            });

            // end label (break 대상)
            const end_label = next_label.*;
            next_label.* += 1;
            try ops.append(self.allocator, .{ .code = .nop, .arg = .{ .none = {} } });

            fixupSentinel(ops.items[ops_start..], dw_break_sent, end_label);
            fixupSentinel(ops.items[ops_start..], dw_continue_sent, cond_label);
        }

        const TryCollectionRole = enum { source, using_cleanup };

        /// try/catch/finally 안의 yield를 상태 머신으로 변환.
        /// try_statement: ternary { a=block, b=catch_clause, c=finally_block }
        /// catch_clause: binary { left=param, right=body }
        ///
        /// 변환 패턴:
        ///   _state.trys.push([try_label, catch_label, finally_label, end_label])
        ///   try body → yield points
        ///   goto end
        ///   catch: param = _state.sent(); catch body
        ///   finally: finally body + return [7] (endfinally)
        fn collectTryOperations(self: *Transformer, stmt_idx: NodeIndex, stmt: Node, ops: *std.ArrayList(Operation), next_label: *u32, role: TryCollectionRole) Transformer.Error!void {
            const try_body = stmt.data.ternary.a;
            const catch_clause = stmt.data.ternary.b;
            const finally_body = stmt.data.ternary.c;

            // try/catch/finally body 모두 statement → hasYieldOrReturn 으로 일관.
            const requires_lowering = role == .using_cleanup or es2015_scan.hasYieldOrReturn(self, try_body) or
                es2015_scan.hasYieldOrReturn(self, catch_clause) or
                es2015_scan.hasYieldOrReturn(self, finally_body);

            // yield/await 없이도 return은 __generator callback 안에서 raw return으로
            // 남으면 안 된다. __generator body는 [op, value] instruction을 반환해야
            // 하므로 try/catch/finally 안 return도 state-machine op로 수집한다.
            if (!requires_lowering) {
                const new_stmt = try visitNativeStateRegion(self, stmt_idx);
                if (!new_stmt.isNone()) {
                    try ops.append(self.allocator, .{ .code = .statement, .arg = .{ .node = new_stmt } });
                }
                return;
            }

            // try_label = 현재 case 번호. next_label은 1에서 시작하고
            // 각 nop append 직전에 +1되므로, next_label - 1 == 현재 case 번호.
            const try_label = next_label.* - 1;

            // trys.push placeholder — body 처리 후 실제 label로 교체
            const trys_push_slot = ops.items.len;
            try ops.append(self.allocator, .{ .code = .statement, .arg = .{ .node = .none } });

            try collectBodyOperations(self, try_body, ops, next_label);

            const catch_label: ?u32 = if (!catch_clause.isNone()) blk: {
                const label = next_label.*;
                next_label.* += 1;
                break :blk label;
            } else null;

            // try body 끝 break placeholder
            const try_break_slot = ops.items.len;
            try ops.append(self.allocator, .{ .code = .break_op, .arg = .{ .label = 0 } });

            if (!catch_clause.isNone()) {
                try ops.append(self.allocator, .{ .code = .nop, .arg = .{ .none = {} } });

                const catch_node = self.ast.getNode(catch_clause);
                const catch_param = catch_node.data.binary.left;
                const catch_body_idx = catch_node.data.binary.right;

                // catch 파라미터를 고유 이름으로 — 상태 기계는 wrapper 최상단 var 로 올리므로
                // 원래 이름이면 바깥 동명 바인딩·중첩 catch 의 같은 이름을 덮는다 (#4712).
                var param_bindings: std.ArrayList(NodeIndex) = .empty;
                defer param_bindings.deinit(self.allocator);
                if (!catch_param.isNone()) try collectBindingNodes(self, catch_param, &param_bindings);
                // 이미 wrapper 에 등록한 바인딩의 정확한 노드/심볼만 재사용한다. 이름만 같다는
                // 이유로 중첩 catch 둘을 하나의 상태 변수로 합치면 서로의 값을 덮는다.
                if (param_bindings.items.len == 1 and isRegisteredGeneratorBinding(self, param_bindings.items[0])) param_bindings.clearRetainingCapacity();
                try registerStateMachineBindings(self, param_bindings.items);

                const param_is_pattern = !catch_param.isNone() and self.ast.getNode(catch_param).tag != .binding_identifier;
                if (param_is_pattern) {
                    // `catch ({ message })` — 받은 값을 임시 변수에 담고 `let <패턴> = 임시변수` 를
                    // 일반 선언 수집으로 넘긴다. 패턴을 대입 좌변에 그대로 쓰면 (a) es5 에 구조분해
                    // 문법이 남고 (b) 축약형 키가 리네임되고 (c) minify 가 값 자리를 선언과 연결하지
                    // 못한다. 선언 경로는 셋 다 처리한다 (#4712).
                    const tmp = try es_helpers.makeTempVarSpan(self);
                    const producer = try captureGeneratorTempProducer(self, tmp, stmt.span);
                    try appendAssignTempStmt(self, ops, producer, try buildSentCall(self, stmt.span), stmt.span);
                    const decl = try es_helpers.makeVarDeclaration(self, &.{
                        try es_helpers.makeDeclarator(self, catch_param, try makeGeneratorTempRefForProducer(self, producer, tmp, .{ .read = true }), stmt.span),
                    }, .let, stmt.span);
                    _ = try collectVarDeclWithYield(self, self.ast.getNode(decl), ops, next_label, null);
                } else if (!catch_param.isNone()) {
                    const visited_param = try self.visitNode(catch_param);
                    // `catch (e) {…}` → `case N: e = _state.sent();` 로 접을 때, catch 의
                    // **바인딩** 노드를 그대로 대입 좌변에 재사용하면 안 된다. 좌변은 선언이
                    // 아니라 **참조**다. 소스에서 온 catch param 은 스코프 분석이 이미 등록해
                    // 둬서 우연히 해석되지만, 트랜스포머가 합성한 temp(예: for-await 의 `_e`)는
                    // 분석 이후에 만들어져 바인딩 노드가 심볼로 해석되지 않는다 → minify 때
                    // 호이스트된 `var` 선언만 리네임되고 이 좌변은 원래 이름으로 남아
                    // `ReferenceError: _e is not defined` (#4703).
                    const new_param = try bindingToAssignTarget(self, visited_param);
                    const sent = try buildSentCall(self, stmt.span);
                    const assign = try self.ast.addNode(.{
                        .tag = .assignment_expression,
                        .span = stmt.span,
                        .data = .{ .binary = .{ .left = new_param, .right = sent, .flags = 0 } },
                    });
                    const assign_stmt = try es_helpers.makeExprStmt(self, assign, stmt.span);
                    try ops.append(self.allocator, .{ .code = .statement, .arg = .{ .node = assign_stmt } });
                }

                try collectBodyOperations(self, catch_body_idx, ops, next_label);
            }

            // catch body 끝 break placeholder
            const catch_break_slot: ?usize = if (!catch_clause.isNone()) blk: {
                const slot = ops.items.len;
                try ops.append(self.allocator, .{ .code = .break_op, .arg = .{ .label = 0 } });
                break :blk slot;
            } else null;

            var finally_label: ?u32 = null;
            if (!finally_body.isNone()) {
                finally_label = next_label.*;
                next_label.* += 1;
                try ops.append(self.allocator, .{ .code = .nop, .arg = .{ .none = {} } });

                try collectBodyOperations(self, finally_body, ops, next_label);

                const endfinally_ret = try buildInstructionReturn(self, 7, .none, stmt.span);
                try ops.append(self.allocator, .{ .code = .statement, .arg = .{ .node = endfinally_ret } });
            }

            const end_label = next_label.*;
            next_label.* += 1;
            try ops.append(self.allocator, .{ .code = .nop, .arg = .{ .none = {} } });

            // fixup: try/catch body 끝 → 항상 end_label로 break.
            // finally가 있으면 __generator 런타임이 _.label < t[2] 체크로
            // finally로 자동 우회 + _.ops.push(op)로 원래 목적지 보존.
            ops.items[try_break_slot] = .{ .code = .break_op, .arg = .{ .label = end_label } };
            if (catch_break_slot) |slot| {
                ops.items[slot] = .{ .code = .break_op, .arg = .{ .label = end_label } };
            }

            const trys_push = try buildTrysPush(self, try_label, catch_label, finally_label, end_label, stmt.span);
            ops.items[trys_push_slot] = .{ .code = .statement, .arg = .{ .node = trys_push } };
        }

        /// _state.trys.push([try_label, catch_label, finally_label, end_label]) expression_statement 생성.
        /// finally_label이 null이면 void 0을 출력하여 런타임의 _.label < t[2] 체크를 skip시킨다.
        fn buildTrysPush(self: *Transformer, try_label: u32, catch_label: ?u32, finally_label: ?u32, end_label: u32, span: Span) Transformer.Error!NodeIndex {
            const state_ref = try makeGeneratorStateRef(self);

            // _state.trys
            const trys_prop = try es_helpers.makePropertyName(self, "trys");
            const trys_member = try es_helpers.makeStaticMember(self, state_ref, trys_prop, span);

            // _state.trys.push
            const push_prop = try es_helpers.makePropertyName(self, "push");
            const push_member = try es_helpers.makeStaticMember(self, trys_member, push_prop, span);

            // [try_label, catch_label, finally_label, end_label] 배열 (TypeScript __generator 스펙)
            const n0 = try es_helpers.makeNumericLiteral(self, try_label);
            const n1 = if (catch_label) |cl|
                try es_helpers.makeNumericLiteral(self, cl)
            else
                try es_helpers.makeVoidZero(self, span);
            const n2 = if (finally_label) |fl|
                try es_helpers.makeNumericLiteral(self, fl)
            else
                try es_helpers.makeVoidZero(self, span);
            const n3 = try es_helpers.makeNumericLiteral(self, end_label);
            const arr_list = try self.ast.addNodeList(&.{ n0, n1, n2, n3 });
            const arr = try self.ast.addNode(.{
                .tag = .array_expression,
                .span = span,
                .data = .{ .list = arr_list },
            });

            // _state.trys.push([...])
            const call = try es_helpers.makeCallExpr(self, push_member, &.{arr}, span);
            return es_helpers.makeExprStmt(self, call, span);
        }

        /// generator body에서 모든 var 선언의 binding name을 수집 (호이스팅).
        /// let/const는 block-scoped이므로 호이스팅하지 않음 (ES2015 변환에서 var로 바뀌므로 포함).
        /// destructuring 패턴은 개별 identifier로 분해하여 호이스팅.
        /// (var {a, b} = expr → var a, b; 로 호이스팅. var {a, b}; 는 문법 에러)
        fn collectHoistedVarsRange(self: *Transformer, stmts_start: u32, stmts_len: u32, hoisted: *std.ArrayList(NodeIndex)) Transformer.Error!void {
            // 모든 stmt 를 collectHoistedVarFromNode 에 위임 — single source of truth
            // (이전엔 두 함수가 별도 case 분기 가지고 있어 변경 시 한쪽만 update 되어 누락
            // 발생. #1901 의 for_await_of 가 그 예).
            var i_loop: u32 = 0;
            while (i_loop < stmts_len) : (i_loop += 1) {
                const raw_idx = self.ast.extra_data.items[stmts_start + i_loop];
                try collectHoistedVarFromNode(self, @fromBackingInt(@intCast(raw_idx)), hoisted);
            }
        }

        /// 단일 노드에서 호이스팅할 var를 수집 (block이면 재귀).
        fn collectHoistedVarFromNode(self: *Transformer, idx: NodeIndex, hoisted: *std.ArrayList(NodeIndex)) Transformer.Error!void {
            if (idx.isNone()) return;
            const node = self.ast.getNode(idx);
            if (node.tag == .block_statement) {
                // 중첩 블록의 let/const 는 블록 스코프다 — 원래 이름 그대로 wrapper 최상단에
                // 올리면 바깥 동명 바인딩을 가린다. 상태 기계가 그 블록을 실제로 수집할 때
                // 고유 이름으로 바꿔 등록한다(`registerStateMachineBindings`). 수집하지 않는 블록은
                // 일반 방문이 블록 스코핑 규칙대로 처리한다 (#4712).
                var i: u32 = 0;
                while (i < node.data.list.len) : (i += 1) {
                    const child: NodeIndex = @fromBackingInt(@intCast(self.ast.extra_data.items[node.data.list.start + i]));
                    if (stateMachineRenamesBlockScope(self) and isLexicalDeclaration(self, child)) continue;
                    try collectHoistedVarFromNode(self, child, hoisted);
                }
            } else if (node.tag == .function_body) {
                try collectHoistedVarsRange(self, node.data.list.start, node.data.list.len, hoisted);
            } else if (node.tag == .variable_declaration) {
                // for-in/for-of의 left가 variable_declaration인 경우
                const e = node.data.extra;
                const list_start = self.readU32(e, 1);
                const list_len = self.readU32(e, 2);
                // visitNode가 extra_data를 재할당할 수 있으므로 인덱스 루프 사용
                var j_loop: u32 = 0;
                while (j_loop < list_len) : (j_loop += 1) {
                    const decl_raw = self.ast.extra_data.items[list_start + j_loop];
                    const decl = self.ast.getNode(@fromBackingInt(@intCast(decl_raw)));
                    if (decl.tag != .variable_declarator) continue;
                    const binding: NodeIndex = self.readNodeIdx(decl.data.extra, 0);
                    if (!binding.isNone()) {
                        try collectBindingIdentifiers(self, binding, hoisted);
                    }
                }
            } else if (node.tag == .labeled_statement) {
                try collectHoistedVarFromNode(self, node.data.binary.right, hoisted);
            } else if (node.tag == .for_statement) {
                const e = node.data.extra;
                // 헤더의 let/const 는 상태 기계가 루프를 수집할 때 리네임·등록한다 (#4712).
                if (!stateMachineRenamesBlockScope(self) or !isLexicalDeclaration(self, self.readNodeIdx(e, 0))) try collectHoistedVarFromNode(self, self.readNodeIdx(e, 0), hoisted);
                try collectHoistedVarFromNode(self, self.readNodeIdx(e, 3), hoisted);
            } else if (node.tag == .while_statement or node.tag == .do_while_statement or node.tag == .with_statement) {
                try collectHoistedVarFromNode(self, node.data.binary.right, hoisted);
            } else if (node.tag == .for_in_statement or node.tag == .for_of_statement) {
                if (!stateMachineRenamesBlockScope(self) or !isLexicalDeclaration(self, node.data.ternary.a)) try collectHoistedVarFromNode(self, node.data.ternary.a, hoisted);
                try collectHoistedVarFromNode(self, node.data.ternary.c, hoisted);
            } else if (node.tag == .if_statement) {
                try collectHoistedVarFromNode(self, node.data.ternary.b, hoisted);
                try collectHoistedVarFromNode(self, node.data.ternary.c, hoisted);
            } else if (node.tag == .try_statement) {
                // try.a = try block, try.b = catch_clause, try.c = finalizer block.
                try collectHoistedVarFromNode(self, node.data.ternary.a, hoisted);
                try collectHoistedVarFromNode(self, node.data.ternary.b, hoisted);
                try collectHoistedVarFromNode(self, node.data.ternary.c, hoisted);
            } else if (node.tag == .catch_clause) {
                // catch 파라미터는 블록 스코프다 — 여기서 원래 이름으로 올리면 바깥 동명
                // 바인딩을 가린다(yield 없는 평범한 catch 까지). 상태 기계가 catch 를 수집할
                // 때 고유 이름으로 바꿔 등록한다 (#4712).
                if (!stateMachineRenamesBlockScope(self) and !node.data.binary.left.isNone()) {
                    try collectBindingIdentifiers(self, node.data.binary.left, hoisted);
                }
                try collectHoistedVarFromNode(self, node.data.binary.right, hoisted);
            } else if (node.tag == .switch_statement or node.tag == .switch_case) {
                // switch_statement: extra = [discriminant, cases.start, cases.len].
                // 이전엔 `node.data.binary.right` 로 access 했지만 switch_statement 의 data
                // kind 는 .extra — binary.right 는 union padding 영역의 undefined 값. main
                // 에선 우연히 valid index 였지만 새 AST tag 추가 시 padding 변동으로 panic.
                const extras = self.ast.extra_data.items;
                const e = node.data.extra;
                if (e + 2 < extras.len) {
                    const cases_start = extras[e + 1];
                    const cases_len = extras[e + 2];
                    var i: u32 = 0;
                    while (i < cases_len) : (i += 1) {
                        try collectHoistedVarFromNode(self, @fromBackingInt(@intCast(extras[cases_start + i])), hoisted);
                    }
                }
            } else if (node.tag == .for_await_of_statement) {
                // ternary.a = left (var 헤더만 — lexical 은 풀이 후 본문 선언이라 수집 때 리네임),
                // c = body. 풀이의 임시 변수는 초기값 있는 var 라 선언 수집이 등록한다 (#4746).
                if (!stateMachineRenamesBlockScope(self) or !isLexicalDeclaration(self, node.data.ternary.a)) try collectHoistedVarFromNode(self, node.data.ternary.a, hoisted);
                try collectHoistedVarFromNode(self, node.data.ternary.c, hoisted);
            }
        }

        /// binding 패턴에서 모든 binding_identifier를 추출.
        /// destructuring 패턴(object_pattern, array_pattern)은 재귀적으로 분해.
        /// `var {a, b}` → `var a, b` (destructuring 없이 개별 identifier로 호이스팅)
        fn collectBindingIdentifiers(self: *Transformer, binding_idx: NodeIndex, hoisted: *std.ArrayList(NodeIndex)) Transformer.Error!void {
            if (binding_idx.isNone()) return;
            const node = self.ast.getNode(binding_idx);
            switch (node.tag) {
                .binding_identifier => {
                    const new_binding = try self.visitNode(binding_idx);
                    try hoisted.append(self.allocator, new_binding);
                },
                .object_pattern => {
                    const props_start = node.data.list.start;
                    const split = self.ast.nodeListSplitRest(node.data.list);
                    const non_rest_len: u32 = @intCast(split.elements.len);
                    // visitNode가 extra_data를 재할당할 수 있으므로 인덱스 루프 사용
                    var p_loop: u32 = 0;
                    while (p_loop < non_rest_len) : (p_loop += 1) {
                        const raw_idx = self.ast.extra_data.items[props_start + p_loop];
                        const prop = self.ast.getNode(@fromBackingInt(@intCast(raw_idx)));
                        if (prop.tag == .binding_property) {
                            // {key: value} → value 쪽에서 identifier 추출
                            try collectBindingIdentifiers(self, prop.data.binary.right, hoisted);
                        } else if (prop.tag == .assignment_pattern) {
                            // {x = default} → x
                            try collectBindingIdentifiers(self, prop.data.binary.left, hoisted);
                        }
                    }
                    if (split.rest_operand) |op| {
                        try collectBindingIdentifiers(self, op, hoisted);
                    }
                },
                .array_pattern => {
                    const elems_start = node.data.list.start;
                    const split = self.ast.nodeListSplitRest(node.data.list);
                    const non_rest_len: u32 = @intCast(split.elements.len);
                    // visitNode가 extra_data를 재할당할 수 있으므로 인덱스 루프 사용
                    var e_loop: u32 = 0;
                    while (e_loop < non_rest_len) : (e_loop += 1) {
                        const raw_idx = self.ast.extra_data.items[elems_start + e_loop];
                        const elem_idx: NodeIndex = @fromBackingInt(@intCast(raw_idx));
                        if (elem_idx.isNone()) continue; // array hole
                        // `[a, , b]` 의 빈 칸은 `.elision` 노드다 — 이름이 없다. `else => unreachable`
                        // 로 떨어지면 릴리스 빌드에서 빈 이름이 들어가 `var a,,b` 가 된다 (#4791).
                        if (self.ast.getNode(elem_idx).tag == .elision) continue;
                        try collectBindingIdentifiers(self, elem_idx, hoisted);
                    }
                    if (split.rest_operand) |op| {
                        try collectBindingIdentifiers(self, op, hoisted);
                    }
                },
                .assignment_pattern => {
                    // [x = default] → x
                    try collectBindingIdentifiers(self, node.data.binary.left, hoisted);
                },
                // 외부 첫 호출이 직접 rest 노드일 수 있는 경로 안전망 (함수 파라미터 등).
                .rest_element, .binding_rest_element => {
                    try collectBindingIdentifiers(self, node.data.unary.operand, hoisted);
                },
                else => unreachable,
            }
        }

        /// assignment_expression을 expression_statement로 만들되,
        /// object_pattern이 좌변이면 괄호로 감싸서 block statement와 구분.
        /// ({a, b} = expr); vs {a, b} = expr; (후자는 syntax error)
        ///
        /// ES2015 destructuring 이 unsupported 면 binding pattern 좌변을
        /// `(_ref = rhs, x = _ref.x, ..., _ref)` sequence expression 으로 분해해
        /// ES5 호환 statement 로 변환 (#1960). state machine 이 만든 binding pattern
        /// LHS 는 visitNode 트래버설을 거치지 않아 일반 destructuring lowering 이
        /// 도달하지 못하므로 emit 시점에 명시적으로 호출.
        fn makeDestructuringAssignStmt(self: *Transformer, lhs: NodeIndex, rhs: NodeIndex, span: Span, producer_output_scope: @import("../semantic/scope.zig").ScopeId) Transformer.Error!NodeIndex {
            const lhs_node = self.ast.getNode(lhs);
            // 구조분해가 native 인 타겟(Hermes 등)에서도 단순 대입으로 낮춘다. 바인딩 패턴을
            // 대입 좌변에 그대로 두면 minify 의 스코프 재해석이 패턴 안을 **선언**으로 봐서,
            // 호이스트된 선언만 맹글되고 대입 대상은 원래 이름으로 남는다(블록 바인딩이
            // `x$N` 으로 리네임될 때 드러남, #4712).
            if (lhs_node.tag == .object_pattern or lhs_node.tag == .array_pattern) {
                const Es2015D = es2015_destructuring.ES2015Destructuring(Transformer);
                const seq = try Es2015D.lowerBindingPatternAssignment(self, lhs_node, rhs, span, producer_output_scope);
                return es_helpers.makeExprStmt(self, seq, span);
            }
            const assign = try self.ast.addNode(.{
                .tag = .assignment_expression,
                .span = span,
                .data = .{ .binary = .{ .left = lhs, .right = rhs, .flags = 0 } },
            });
            // object_pattern assign 의 paren 은 precedence 재유도가 처리 (#4042 PR8)
            return es_helpers.makeExprStmt(self, assign, span);
        }

        /// yield가 있는 variable_declaration의 각 declarator를 개별 연산으로 변환.
        /// var x = yield 1 → yield 1 (op) + x = _state.sent() (op)
        /// var x = expr (no yield) → x = expr (statement op)
        /// `capture_binding`이 있으면 그 exact binding의 등록 슬롯을 직접 반환한다.
        fn collectVarDeclWithYield(
            self: *Transformer,
            stmt: Node,
            ops: *std.ArrayList(Operation),
            next_label: *u32,
            capture_binding: ?NodeIndex,
        ) Transformer.Error!?usize {
            const e = stmt.data.extra;
            const list_start = self.readU32(e, 1);
            const list_len = self.readU32(e, 2);
            var captured_producer_index: ?usize = null;

            // visitNode가 extra_data를 재할당할 수 있으므로 인덱스 루프 사용
            var i_loop: u32 = 0;
            while (i_loop < list_len) : (i_loop += 1) {
                const decl_raw = self.ast.extra_data.items[list_start + i_loop];
                const decl = self.ast.getNode(@fromBackingInt(@intCast(decl_raw)));
                if (decl.tag != .variable_declarator) continue;

                const binding: NodeIndex = self.readNodeIdx(decl.data.extra, 0);
                const init_idx: NodeIndex = self.readNodeIdx(decl.data.extra, 2);

                if (init_idx.isNone()) continue;

                const init_node = self.ast.getNode(init_idx);
                if (init_node.tag == .yield_expression or init_node.tag == .await_expression) {
                    // var x = yield/await value → yield value + x = _state.sent()
                    const yield_val = init_node.data.unary.operand;
                    const new_val = try visitExprWithYieldExtraction(self, yield_val, ops, next_label);
                    try ops.append(self.allocator, .{ .code = yieldOpCodeFor(init_node), .arg = .{ .node = try asyncGenAwaitValue(self, init_node, new_val) } });
                    next_label.* += 1;
                    try ops.append(self.allocator, .{ .code = .nop, .arg = .{ .none = {} } });

                    // x = _state.sent()
                    const new_binding = try bindingToAssignTarget(self, try self.visitNode(binding));
                    const sent_call = try buildSentCall(self, stmt.span);
                    const assign_stmt = try makeDestructuringAssignStmt(self, new_binding, sent_call, stmt.span, self.generator_state_machine_scope);
                    try ops.append(self.allocator, .{ .code = .statement, .arg = .{ .node = assign_stmt } });
                } else if (es2015_scan.containsYield(self, init_idx)) {
                    // var x = foo(await y) → 중첩 yield 추출 후 x = foo(_state.sent())
                    const new_binding = try bindingToAssignTarget(self, try self.visitNode(binding));
                    const new_init = try visitExprWithYieldExtraction(self, init_idx, ops, next_label);
                    const assign_stmt = try makeDestructuringAssignStmt(self, new_binding, new_init, stmt.span, self.generator_state_machine_scope);
                    try ops.append(self.allocator, .{ .code = .statement, .arg = .{ .node = assign_stmt } });
                } else {
                    // var x = expr (no yield) → x = expr
                    const new_binding = try bindingToAssignTarget(self, try self.visitNode(binding));
                    const new_init = try self.visitNode(init_idx);
                    const assign_stmt = try makeDestructuringAssignStmt(self, new_binding, new_init, stmt.span, self.generator_state_machine_scope);
                    try ops.append(self.allocator, .{ .code = .statement, .arg = .{ .node = assign_stmt } });
                }

                // `var` 는 대입으로 접혔으니 이름을 **바깥 함수** var 리스트에 등록한다 (#4722).
                // 소스에 있던 선언은 사전 스캔(collectHoistedVars)이 이미 잡지만, 다른 lowering
                // 이 **만들어 낸** 선언(예: 일반 경로 for-of 의 `var _loop = function* …`)은
                // 그 스캔 이후에 생겨 빠진다 → `ReferenceError: _loop is not defined`.
                // 중복은 buildHoistedVarDecl 이 이름으로 걸러 낸다. 등록은 init visit **뒤**
                // (그 안에서 다른 상태 기계가 만들어질 수 있다 — #4716).
                // 블록 스코프 바인딩이 `x$N` 으로 바뀌었으면 바뀐 이름을 등록한다 — 원래 이름을
                // 올리면 바깥 동명 바인딩을 가린다 (#4712).
                const bnode = self.ast.getNode(binding);
                if (bnode.tag == .binding_identifier) {
                    const span_to_declare = if (self.renamedNameOf(binding)) |renamed| try self.ast.addString(renamed) else bnode.data.string_ref;
                    const producer_index = try registerGeneratorVar(self, span_to_declare, binding);
                    if (capture_binding) |expected_binding| {
                        if (binding == expected_binding) {
                            if (captured_producer_index != null)
                                std.debug.panic("generator binding producer handle was returned more than once", .{});
                            captured_producer_index = producer_index;
                        }
                    }
                }
            }
            return captured_producer_index;
        }

        /// 선언 바인딩을 **대입 좌변**으로 쓸 수 있는 노드로 바꾼다. (#4703 · #4716)
        ///
        /// 상태 기계는 `var x = init` 을 `x = init` 으로 접는다. 이때 좌변은 선언이 아니라
        /// **참조**다. 소스에서 온 이름은 스코프 분석이 이미 등록해 둬서 바인딩 노드
        /// 그대로도 우연히 해석되지만, 트랜스포머가 합성한 이름(`_loopN`, `_ret`,
        /// for-await 의 `_e` …)은 분석 이후에 생겨 해석되지 않는다 → minify 때 호이스트된
        /// `var` 선언만 리네임되고 좌변만 원래 이름으로 남아 `ReferenceError`.
        /// 구조분해 패턴은 바인딩 노드가 아니므로 그대로 둔다 — 상태 기계의 구조분해 대입은
        /// `makeDestructuringAssignStmt` 가 항상 단순 대입으로 낮춘다.
        fn bindingToAssignTarget(self: *Transformer, binding: NodeIndex) Transformer.Error!NodeIndex {
            if (binding.isNone()) return binding;
            const node = self.ast.getNode(binding);
            if (node.tag != .binding_identifier) return binding;
            const target = try self.makeIdentifierRefWithSymbol(node.data.string_ref, binding);
            if (self.getSymbolIdAt(binding)) |raw_id| {
                const symbols = if (self.semantic_editor) |*editor| editor.symbols.items else self.symbols;
                if (raw_id >= symbols.len) std.debug.panic("generator assignment binding id is out of range", .{});
                try self.trackUserWriteFromBinding(target, binding, symbols[raw_id].scope_id);
            } else if (self.semantic_edit_enabled and @backingInt(binding) >= self.parser_node_count) {
                // Lowering-created var bindings become assignment targets in
                // the state machine. Attach the wrapper identity to this exact
                // binding before creating its assignment reference.
                if (self.state_machine_depth > 0) {
                    if (self.generator_state_machine_scope.isNone())
                        std.debug.panic("generator assignment temp has no exact wrapper ScopeId", .{});
                    const symbol = (try self.declareSyntheticTempInScope(
                        binding,
                        node.span,
                        self.generator_state_machine_scope,
                    )) orelse std.debug.panic("generator assignment temp has no producer SymbolId", .{});
                    try self.trackGeneratorStateReference(target, symbol, self.current_scope, .{ .write = true });
                } else if (self.hoistedTempProducerIdForBinding(binding)) |producer_id| {
                    try self.trackHoistedTempRefByProducerIdInScope(
                        producer_id,
                        node.data.string_ref,
                        target,
                        self.current_scope,
                        .{ .write = true },
                    );
                } else {
                    try self.trackHoistedTempRef(node.data.string_ref, target, .{ .write = true });
                }
            } else {
                if (self.hoistedTempProducerIdForBinding(binding)) |producer_id| {
                    try self.trackHoistedTempRefByProducerIdInScope(
                        producer_id,
                        node.data.string_ref,
                        target,
                        self.current_scope,
                        .{ .write = true },
                    );
                } else {
                    try self.trackHoistedTempRef(node.data.string_ref, target, .{ .write = true });
                }
            }
            return target;
        }

        /// 클래스 **헤더**(extends 식 · computed 키)를 소스 순서대로 temp 에 미리 평가하고,
        /// 그 자리를 temp 참조로 바꾼 **새 클래스 노드**를 돌려준다(아직 visit 안 함). (#4723)
        ///
        /// es5 는 클래스를 `(function () { var _a = <키>; … })()` IIFE 로 낮춘다. 키 식에
        /// `yield` 가 있으면 그대로 IIFE — 새 함수 — 안으로 들어가 raw `yield` 가 남고
        /// **산출물이 파싱조차 안 된다**. 그래서 상태 기계 쪽에서 키를 먼저 꺼내 둔다.
        ///
        /// yield 가 없는 키도 **같이** temp 로 뺀다 — 일부만 빼면 `[f()]` 와 `[yield x]` 의
        /// 평가 순서가 뒤바뀐다(스펙: heritage → 멤버 키, 소스 순서).
        fn extractClassHeaderYields(self: *Transformer, class_idx: NodeIndex, ops: *std.ArrayList(Operation), next_label: *u32) Transformer.Error!NodeIndex {
            const class_node = self.ast.getNode(class_idx);
            const ce = class_node.data.extra;
            var class_slots: [8]u32 = undefined;
            for (0..8) |k| class_slots[k] = self.ast.extra_data.items[ce + k];

            // 1. extends 식
            const super_idx: NodeIndex = @fromBackingInt(@intCast(class_slots[ast_mod.ClassExtra.super]));
            if (!super_idx.isNone()) {
                class_slots[ast_mod.ClassExtra.super] = @backingInt(try evalIntoGeneratorTemp(self, super_idx, ops, next_label));
            }

            // 2. 멤버의 computed 키 (소스 순서)
            const body_idx: NodeIndex = @fromBackingInt(@intCast(class_slots[ast_mod.ClassExtra.body]));
            if (!body_idx.isNone()) {
                const body = self.ast.getNode(body_idx);
                const scratch_top = self.scratch.items.len;
                defer self.scratch.shrinkRetainingCapacity(scratch_top);
                var i: u32 = 0;
                while (i < body.data.list.len) : (i += 1) {
                    // evalIntoGeneratorTemp 가 extra_data 를 재할당할 수 있으므로 매번 다시 읽는다.
                    const member_idx: NodeIndex = @fromBackingInt(@intCast(self.ast.extra_data.items[body.data.list.start + i]));
                    try self.scratch.append(self.allocator, try rewriteMemberComputedKey(self, member_idx, ops, next_label));
                }
                const new_list = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
                const new_body = try self.ast.addNode(.{ .tag = .class_body, .span = body.span, .data = .{ .list = new_list } });
                class_slots[ast_mod.ClassExtra.body] = @backingInt(new_body);
            }

            const new_extra = try self.ast.addExtras(&class_slots);
            const copied = try self.ast.addNode(.{ .tag = class_node.tag, .span = class_node.span, .data = .{ .extra = new_extra } });
            try self.remapCopiedScopeOwner(class_idx, copied);
            // Header suspension creates a new class owner node. Carry the
            // source's exact inner self identity alongside its copied scope;
            // the outer declaration binding is a different SymbolId.
            if (self.class_self_symbol_map.get(@backingInt(class_idx))) |self_symbol| {
                try self.class_self_symbol_map.put(self.allocator, @backingInt(copied), self_symbol);
            }
            return copied;
        }

        /// 멤버의 key 가 computed 면 그 식을 temp 로 평가해 `[_t]` 로 바꾼 새 멤버를 돌려준다.
        fn rewriteMemberComputedKey(self: *Transformer, member_idx: NodeIndex, ops: *std.ArrayList(Operation), next_label: *u32) Transformer.Error!NodeIndex {
            const member = self.ast.getNode(member_idx);
            const slot_count: usize = switch (member.tag) {
                .method_definition => 6, // MethodExtra: key, params, body, flags, deco_start, deco_len
                .property_definition, .accessor_property => 5, // PropertyExtra: key, init, flags, deco_start, deco_len
                else => return member_idx,
            };
            const me = member.data.extra;
            const key_idx: NodeIndex = @fromBackingInt(@intCast(self.ast.extra_data.items[me]));
            if (key_idx.isNone() or self.ast.getNode(key_idx).tag != .computed_property_key) return member_idx;

            const key_node = self.ast.getNode(key_idx);
            const temp_ref = try evalIntoGeneratorTemp(self, key_node.data.unary.operand, ops, next_label);
            const new_key = try self.ast.addNode(.{
                .tag = .computed_property_key,
                .span = key_node.span,
                .data = .{ .unary = .{ .operand = temp_ref, .flags = key_node.data.unary.flags } },
            });

            var slots: [6]u32 = undefined;
            for (0..slot_count) |k| slots[k] = self.ast.extra_data.items[me + k];
            slots[0] = @backingInt(new_key);
            const new_extra = try self.ast.addExtras(slots[0..slot_count]);
            const copied = try self.ast.addNode(.{ .tag = member.tag, .span = member.span, .data = .{ .extra = new_extra } });
            if (member.tag == .method_definition) try self.remapCopiedScopeOwner(member_idx, copied);
            return copied;
        }

        /// 식을 (yield 추출을 거쳐) 평가해 resume 사이에 살아남는 temp 에 담고 그 참조를 돌려준다.
        fn evalIntoGeneratorTemp(self: *Transformer, expr_idx: NodeIndex, ops: *std.ArrayList(Operation), next_label: *u32) Transformer.Error!NodeIndex {
            const value = try visitExprWithYieldExtraction(self, expr_idx, ops, next_label);
            const temp_span = try es_helpers.makeTempVarSpan(self);
            const producer = try captureGeneratorTempProducer(self, temp_span, self.ast.getNode(expr_idx).span);
            const lhs = try makeGeneratorTempRefForProducer(self, producer, temp_span, .{ .write = true });
            const assign = try self.ast.addNode(.{
                .tag = .assignment_expression,
                .span = temp_span,
                .data = .{ .binary = .{ .left = lhs, .right = value, .flags = 0 } },
            });
            try ops.append(self.allocator, .{ .code = .statement, .arg = .{ .node = try es_helpers.makeExprStmt(self, assign, temp_span) } });
            return makeGeneratorTempRefForProducer(self, producer, temp_span, .{ .read = true });
        }

        /// expression body (arrow function 등)를 state machine으로 변환.
        /// expression을 implicit return으로 처리.
        /// expression 내부의 yield/await를 별도 yield operation으로 추출하고
        /// 해당 위치를 _state.sent()로 치환한 expression을 반환.
        /// 조건식(if, while, for test) 등에서 yield/await가 중첩된 경우 사용.
        /// An assignment pattern (with no `yield` of its own) the general
        /// assignment path would lower.
        fn patternNeedsLowering(self: *Transformer, left_idx: NodeIndex) bool {
            return self.needsDestructuringAssignmentLowering(left_idx) and !es2015_scan.containsYield(self, left_idx);
        }

        /// In an async generator, an `await` the state machine meets (one that
        /// a lowering created during the body visit, like `await using`'s
        /// dispose) is `yield __await(v)`, not a plain yield (#4798).
        fn asyncGenAwaitValue(self: *Transformer, node: Node, value: NodeIndex) Transformer.Error!NodeIndex {
            if (node.tag != .await_expression or !self.in_async_generator_body) return value;
            self.runtime_helpers.await_helper = true;
            const await_ref = try es_helpers.makeRuntimeHelperRef(self, "__await");
            return es_helpers.makeCallExpr(self, await_ref, &.{value}, node.span);
        }

        fn visitExprWithYieldExtraction(self: *Transformer, expr_idx: NodeIndex, ops: *std.ArrayList(Operation), next_label: *u32) Transformer.Error!NodeIndex {
            if (expr_idx.isNone()) return .none;
            const node = self.ast.getNode(expr_idx);

            // yield/await → yield operation 추출 + temp 변수에 결과 저장
            // 하나의 expression에 여러 yield가 있으면 각 결과를 temp에 저장해야 함
            if (node.tag == .yield_expression or node.tag == .await_expression) {
                const value_idx = node.data.unary.operand;
                const new_value = if (!value_idx.isNone())
                    try visitExprWithYieldExtraction(self, value_idx, ops, next_label)
                else
                    NodeIndex.none;
                try ops.append(self.allocator, .{ .code = yieldOpCodeFor(node), .arg = .{ .node = try asyncGenAwaitValue(self, node, new_value) } });
                next_label.* += 1;
                try ops.append(self.allocator, .{ .code = .nop, .arg = .{ .none = {} } });
                // temp 변수에 _state.sent() 결과 저장
                // temp_span을 node.span 대신 사용 — 번들러에서 다른 모듈의 source span과 충돌 방지
                const temp_span = try es_helpers.makeTempVarSpan(self);
                // 임시 변수를 호이스팅 리스트에 등록 — 기존엔 외부 binding (var x = await ...)
                // 이 있을 때만 hoist 됐지만, nested await 또는 for-await-of 의 cond 안 await
                // (#1901) 의 경우 외부 binding 이 없어서 temp 가 어디에도 declare 안 됐음.
                const producer = try captureGeneratorTempProducer(self, temp_span, node.span);
                const temp_ref = try makeGeneratorTempRefForProducer(self, producer, temp_span, .{ .write = true });
                const sent_call = try buildSentCall(self, temp_span);
                const assign = try self.ast.addNode(.{
                    .tag = .assignment_expression,
                    .span = temp_span,
                    .data = .{ .binary = .{ .left = temp_ref, .right = sent_call, .flags = 0 } },
                });
                const assign_stmt = try es_helpers.makeExprStmt(self, assign, temp_span);
                try ops.append(self.allocator, .{ .code = .statement, .arg = .{ .node = assign_stmt } });
                return makeGeneratorTempRefForProducer(self, producer, temp_span, .{ .read = true });
            }

            // yield를 포함하지 않으면 일반 visit
            if (!es2015_scan.containsYield(self, expr_idx)) {
                return self.visitNode(expr_idx);
            }

            // parenthesized_expression: 내부 재귀. paren 은 precedence 재유도가 처리 (#4042 PR8)
            if (node.tag == .parenthesized_expression) {
                return visitExprWithYieldExtraction(self, node.data.unary.operand, ops, next_label);
            }

            // TS/Flow 타입 wrapper 는 런타임상 noop 이므로 통과한다. 그러지 않으면 타입 스트립
            // 이후 `(await x) as T` 가 추출되지 못한 raw `(yield x)` 로 남는다.
            if (Tag.isTransparentTypeWrapper(node.tag)) {
                return visitExprWithYieldExtraction(self, node.data.unary.operand, ops, next_label);
            }

            // computed key 는 `computed_property_key` 래퍼 안에 있다. 래퍼를 유지한 채
            // 안쪽만 추출해야 `{ [_a]: 2 }` 로 나온다 (#4721).
            // 객체 리터럴 메서드/접근자: 본문은 별도 스코프지만 computed 키는 이 문맥에서
            // 평가된다 — 키만 추출하고 나머지는 평소대로 visit (#4723).
            if (node.tag == .method_definition) {
                const me = node.data.extra;
                const key_idx: NodeIndex = @fromBackingInt(@intCast(self.ast.extra_data.items[me]));
                if (!key_idx.isNone() and self.ast.getNode(key_idx).tag == .computed_property_key) {
                    const new_key = try visitExprWithYieldExtraction(self, key_idx, ops, next_label);
                    var slots: [6]u32 = undefined;
                    for (0..6) |k| slots[k] = self.ast.extra_data.items[me + k];
                    slots[0] = @backingInt(new_key);
                    const new_extra = try self.ast.addExtras(&slots);
                    return self.visitNode(try self.ast.addNode(.{ .tag = .method_definition, .span = node.span, .data = .{ .extra = new_extra } }));
                }
            }

            // 클래스 식: 헤더의 yield 를 먼저 꺼낸 뒤 평소대로 낮춘다 (#4723).
            if (node.tag == .class_expression) {
                return self.visitNode(try extractClassHeaderYields(self, expr_idx, ops, next_label));
            }

            if (node.tag == .computed_property_key) {
                const new_inner = try visitExprWithYieldExtraction(self, node.data.unary.operand, ops, next_label);
                return self.ast.addNode(.{
                    .tag = .computed_property_key,
                    .span = node.span,
                    .data = .{ .unary = .{ .operand = new_inner, .flags = node.data.unary.flags } },
                });
            }

            // logical expression: short-circuit / nullish lazy branch 보존.
            if (node.tag == .logical_expression) {
                const op_kind: token_mod.Kind = @fromBackingInt(@intCast(node.data.binary.flags));
                switch (op_kind) {
                    .amp2, .pipe2, .question2 => return lowerLogicalExprWithYieldExtraction(self, node, ops, next_label, op_kind),
                    else => {},
                }
            }

            // binary expression: 양쪽 재귀
            if (node.tag == .binary_expression) {
                const new_left = try visitExprWithYieldExtraction(self, node.data.binary.left, ops, next_label);
                const new_right = try visitExprWithYieldExtraction(self, node.data.binary.right, ops, next_label);
                return self.ast.addNode(.{
                    .tag = node.tag,
                    .span = node.span,
                    .data = .{ .binary = .{ .left = new_left, .right = new_right, .flags = node.data.binary.flags } },
                });
            }

            // conditional expression (ternary): a ? b : c
            if (node.tag == .conditional_expression) {
                return lowerConditionalExprWithYieldExtraction(self, node, ops, next_label);
            }

            // sequence expression: a(), await b(), c()
            // 앞쪽 expression은 순서 보존을 위해 statement operation으로 먼저 방출하고,
            // 마지막 expression만 원래 expression 자리의 값으로 반환한다.
            if (node.tag == .sequence_expression) {
                const list_start = node.data.list.start;
                const list_len = node.data.list.len;
                if (list_len == 0) return self.visitNode(expr_idx);

                var i_seq: u32 = 0;
                while (i_seq < list_len) : (i_seq += 1) {
                    const elem_idx: NodeIndex = @fromBackingInt(@intCast(self.ast.extra_data.items[list_start + i_seq]));
                    const is_last = i_seq + 1 == list_len;
                    const new_elem = if (es2015_scan.containsYield(self, elem_idx))
                        try visitExprWithYieldExtraction(self, elem_idx, ops, next_label)
                    else
                        try self.visitNode(elem_idx);

                    if (is_last) return new_elem;
                    if (!new_elem.isNone()) {
                        const elem_node = self.ast.getNode(elem_idx);
                        const stmt = try es_helpers.makeExprStmt(self, new_elem, elem_node.span);
                        try ops.append(self.allocator, .{ .code = .statement, .arg = .{ .node = stmt } });
                    }
                }
                return .none;
            }

            // unary/update expression: extra = [operand, operator_and_flags]
            if (node.tag == .unary_expression or node.tag == .update_expression) {
                const e = node.data.extra;
                const operand_idx: NodeIndex = self.readNodeIdx(e, 0);
                const op_flags = self.readU32(e, 1);
                const new_operand = try visitExprWithYieldExtraction(self, operand_idx, ops, next_label);
                const new_extra = try self.ast.addExtras(&.{
                    @backingInt(new_operand),
                    op_flags, // operator_and_flags
                });
                return self.ast.addNode(.{
                    .tag = node.tag,
                    .span = node.span,
                    .data = .{ .extra = new_extra },
                });
            }

            // assignment expression: left = right
            if (node.tag == .assignment_expression) {
                // `[this.#y, o.b] = [yield 1, 2]`: the pattern lowers like any other
                // assignment, with the right side whose yields became temps (#5728).
                if (patternNeedsLowering(self, node.data.binary.left)) {
                    const new_right = try visitExprWithYieldExtraction(self, node.data.binary.right, ops, next_label);
                    return es2015_destructuring.ES2015Destructuring(Transformer).lowerDestructuringAssignmentWithRight(self, node, new_right, true);
                }
                const new_left = try visitExprWithYieldExtraction(self, node.data.binary.left, ops, next_label);
                const new_right = try visitExprWithYieldExtraction(self, node.data.binary.right, ops, next_label);
                return self.ast.addNode(.{
                    .tag = .assignment_expression,
                    .span = node.span,
                    .data = .{ .binary = .{ .left = new_left, .right = new_right, .flags = node.data.binary.flags } },
                });
            }

            // extra = [child0, child1, flags] — member expression, tagged template
            if (node.tag == .static_member_expression or node.tag == .computed_member_expression or
                node.tag == .tagged_template_expression)
            {
                const e = node.data.extra;
                const child0_idx: NodeIndex = self.readNodeIdx(e, 0);
                const child1_idx: NodeIndex = self.readNodeIdx(e, 1);
                const flags = self.readU32(e, 2);
                const new_child0 = try visitExprWithYieldExtraction(self, child0_idx, ops, next_label);
                const new_child1 = try visitExprWithYieldExtraction(self, child1_idx, ops, next_label);
                const new_extra = try self.ast.addExtras(&.{
                    @backingInt(new_child0),
                    @backingInt(new_child1),
                    flags,
                });
                return self.ast.addNode(.{
                    .tag = node.tag,
                    .span = node.span,
                    .data = .{ .extra = new_extra },
                });
            }

            // call/new expression: callee + args 재귀
            if (node.tag == .call_expression or node.tag == .new_expression) {
                const e = node.data.extra;
                const callee_idx: NodeIndex = self.readNodeIdx(e, 0);
                const args_start = self.readU32(e, 1);
                const args_len = self.readU32(e, 2);
                const call_flags = self.readU32(e, 3);

                const new_callee = try visitExprWithYieldExtraction(self, callee_idx, ops, next_label);

                const scratch_top = self.scratch.items.len;
                defer self.scratch.shrinkRetainingCapacity(scratch_top);
                // visitExprWithYieldExtraction이 extra_data를 재할당할 수 있으므로 인덱스 루프 사용
                var i_arg: u32 = 0;
                while (i_arg < args_len) : (i_arg += 1) {
                    const arg_raw = self.ast.extra_data.items[args_start + i_arg];
                    const new_arg = try visitExprWithYieldExtraction(self, @fromBackingInt(@intCast(arg_raw)), ops, next_label);
                    try self.scratch.append(self.allocator, new_arg);
                }
                const new_args = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
                const new_extra = try self.ast.addExtras(&.{
                    @backingInt(new_callee),
                    new_args.start,
                    new_args.len,
                    call_flags,
                });
                return self.ast.addNode(.{
                    .tag = node.tag, // call_expression or new_expression
                    .span = node.span,
                    .data = .{ .extra = new_extra },
                });
            }

            // list 기반: array, object, sequence, template literal
            if (node.tag == .array_expression or node.tag == .object_expression or
                node.tag == .sequence_expression or node.tag == .template_literal)
            {
                // 객체 리터럴 메서드의 `super` home 배정 — 이 경로는 object_expression 방문을
                // 거치지 않고 멤버를 직접 방문하므로 여기서도 해야 한다 (#4729).
                const object_super = @import("object_super.zig");
                const home_mark = self.object_super_homes.items.len;
                defer object_super.release(self, home_mark);
                const home = if (node.tag == .object_expression) try object_super.prepareHome(self, expr_idx, false) else null;

                const scratch_top = self.scratch.items.len;
                defer self.scratch.shrinkRetainingCapacity(scratch_top);
                const list_start = node.data.list.start;
                const list_len = node.data.list.len;
                // visitExprWithYieldExtraction이 extra_data를 재할당할 수 있으므로 인덱스 루프 사용
                var i_elem: u32 = 0;
                while (i_elem < list_len) : (i_elem += 1) {
                    const raw_idx = self.ast.extra_data.items[list_start + i_elem];
                    const elem_idx: NodeIndex = @fromBackingInt(@intCast(raw_idx));
                    // An object method lowers like in any object literal (`n() {}` →
                    // `n: function () {}`); its body is its own function (#4736).
                    const new_elem = if (node.tag == .object_expression and
                        self.ast.getNode(elem_idx).tag == .method_definition and
                        !es2015_scan.containsYield(self, elem_idx))
                        try @import("es2015_object_methods.zig").ES2015ObjectMethods(Transformer).lowerObjectMember(self, elem_idx)
                    else
                        try visitExprWithYieldExtraction(self, elem_idx, ops, next_label);
                    try self.scratch.append(self.allocator, new_elem);
                }
                const new_list = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
                const rebuilt = try self.ast.addNode(.{
                    .tag = node.tag,
                    .span = node.span,
                    .data = .{ .list = new_list },
                });
                if (home) |h| return object_super.wrapWithHome(self, h, rebuilt, node.span);
                return rebuilt;
            }

            // object_property: binary (key: value)
            if (node.tag == .object_property) {
                const new_key = try visitExprWithYieldExtraction(self, node.data.binary.left, ops, next_label);
                const new_value = if (!node.data.binary.right.isNone())
                    try visitExprWithYieldExtraction(self, node.data.binary.right, ops, next_label)
                else
                    NodeIndex.none;
                return self.ast.addNode(.{
                    .tag = .object_property,
                    .span = node.span,
                    .data = .{ .binary = .{ .left = new_key, .right = new_value, .flags = node.data.binary.flags } },
                });
            }

            // spread_element: unary
            if (node.tag == .spread_element) {
                const new_operand = try visitExprWithYieldExtraction(self, node.data.unary.operand, ops, next_label);
                return self.ast.addNode(.{
                    .tag = .spread_element,
                    .span = node.span,
                    .data = .{ .unary = .{ .operand = new_operand, .flags = node.data.unary.flags } },
                });
            }

            // 그 외: visitNode fallback (yield가 남을 수 있음)
            if (std.debug.runtime_safety) {
                std.log.warn("visitExprWithYieldExtraction: unhandled tag {}", .{node.tag});
            }
            return self.visitNode(expr_idx);
        }

        // Expression-internal lazy branches need labels before their final `next_label`
        // values are allocated. Use reserved sentinel labels, then patch only the ops
        // emitted by the current expression once the real labels are known.
        const EXPR_LAZY_BRANCH_END_SENTINEL = LABEL_SENTINEL_BASE - 10_000;
        const EXPR_LAZY_COND_ELSE_SENTINEL = LABEL_SENTINEL_BASE - 10_001;
        const EXPR_LAZY_COND_END_SENTINEL = LABEL_SENTINEL_BASE - 10_002;

        fn appendAssignTempStmt(self: *Transformer, ops: *std.ArrayList(Operation), producer: HoistedStateTemp, value_idx: NodeIndex, span: Span) Transformer.Error!void {
            const temp_ref = try makeGeneratorTempRefForProducer(self, producer, producer.name_span, .{ .write = true });
            const assign = try self.ast.addNode(.{
                .tag = .assignment_expression,
                .span = span,
                .data = .{ .binary = .{ .left = temp_ref, .right = value_idx, .flags = 0 } },
            });
            const stmt = try es_helpers.makeExprStmt(self, assign, span);
            try ops.append(self.allocator, .{ .code = .statement, .arg = .{ .node = stmt } });
        }

        fn lowerLogicalExprWithYieldExtraction(self: *Transformer, node: Node, ops: *std.ArrayList(Operation), next_label: *u32, op_kind: token_mod.Kind) Transformer.Error!NodeIndex {
            const temp_span = try es_helpers.makeTempVarSpan(self);
            const producer = try captureGeneratorTempProducer(self, temp_span, node.span);
            const ops_start = ops.items.len;

            const left_value = try visitExprWithYieldExtraction(self, node.data.binary.left, ops, next_label);
            try appendAssignTempStmt(self, ops, producer, left_value, node.span);

            const temp_for_cond = try makeGeneratorTempRefForProducer(self, producer, temp_span, .{ .read = true });
            const cond = if (op_kind == .question2)
                try es_helpers.makeNeqNull(self, temp_for_cond, node.span)
            else
                temp_for_cond;
            const branch_code: OpCode = if (op_kind == .amp2) .break_when_false else .break_when_true;
            try ops.append(self.allocator, .{
                .code = branch_code,
                .arg = .{ .label_and_node = .{ .label = EXPR_LAZY_BRANCH_END_SENTINEL, .node = cond } },
            });

            const right_value = try visitExprWithYieldExtraction(self, node.data.binary.right, ops, next_label);
            try appendAssignTempStmt(self, ops, producer, right_value, node.span);

            const end_label = next_label.*;
            next_label.* += 1;
            try ops.append(self.allocator, .{ .code = .nop, .arg = .{ .none = {} } });
            fixupSentinel(ops.items[ops_start..], EXPR_LAZY_BRANCH_END_SENTINEL, end_label);

            return makeGeneratorTempRefForProducer(self, producer, temp_span, .{ .read = true });
        }

        fn lowerConditionalExprWithYieldExtraction(self: *Transformer, node: Node, ops: *std.ArrayList(Operation), next_label: *u32) Transformer.Error!NodeIndex {
            const temp_span = try es_helpers.makeTempVarSpan(self);
            const producer = try captureGeneratorTempProducer(self, temp_span, node.span);
            const ops_start = ops.items.len;

            const cond = try visitExprWithYieldExtraction(self, node.data.ternary.a, ops, next_label);
            try ops.append(self.allocator, .{
                .code = .break_when_false,
                .arg = .{ .label_and_node = .{ .label = EXPR_LAZY_COND_ELSE_SENTINEL, .node = cond } },
            });

            const then_value = try visitExprWithYieldExtraction(self, node.data.ternary.b, ops, next_label);
            try appendAssignTempStmt(self, ops, producer, then_value, node.span);
            try ops.append(self.allocator, .{ .code = .break_op, .arg = .{ .label = EXPR_LAZY_COND_END_SENTINEL } });

            const else_label = next_label.*;
            next_label.* += 1;
            try ops.append(self.allocator, .{ .code = .nop, .arg = .{ .none = {} } });

            const else_value = try visitExprWithYieldExtraction(self, node.data.ternary.c, ops, next_label);
            try appendAssignTempStmt(self, ops, producer, else_value, node.span);

            const end_label = next_label.*;
            next_label.* += 1;
            try ops.append(self.allocator, .{ .code = .nop, .arg = .{ .none = {} } });
            fixupSentinel(ops.items[ops_start..], EXPR_LAZY_COND_ELSE_SENTINEL, else_label);
            fixupSentinel(ops.items[ops_start..], EXPR_LAZY_COND_END_SENTINEL, end_label);

            return makeGeneratorTempRefForProducer(self, producer, temp_span, .{ .read = true });
        }

        fn buildExpressionBodyStateMachine(self: *Transformer, body_idx: NodeIndex, body: Node, span: Span, wrapper_scope: ScopeId) Transformer.Error!StateMachineResult {
            var ops: std.ArrayList(Operation) = .empty;
            defer ops.deinit(self.allocator);
            var next_label: u32 = 1;

            if (body.tag == .await_expression or body.tag == .yield_expression) {
                // return await/yield x → yield x + return _state.sent()
                const inner_value = body.data.unary.operand;
                const new_inner = if (!inner_value.isNone())
                    try visitExprWithYieldExtraction(self, inner_value, &ops, &next_label)
                else
                    NodeIndex.none;
                try ops.append(self.allocator, .{ .code = yieldOpCodeFor(body), .arg = .{ .node = try asyncGenAwaitValue(self, body, new_inner) } });
                next_label += 1;
                try ops.append(self.allocator, .{ .code = .nop, .arg = .{ .none = {} } });
                const sent = try buildSentCall(self, span);
                try ops.append(self.allocator, .{ .code = .return_op, .arg = .{ .node = sent } });
            } else if (es2015_scan.containsYield(self, body_idx)) {
                // async arrow expression body: `async x => f(await x)` 는 implicit return 이므로,
                // block body 의 `return f(await x)` 와 동일하게 nested await를 먼저 추출한다.
                const new_value = try visitExprWithYieldExtraction(self, body_idx, &ops, &next_label);
                try ops.append(self.allocator, .{ .code = .return_op, .arg = .{ .node = new_value } });
            } else {
                // 일반 expression: return expr
                const new_value = try self.visitNode(body_idx);
                try ops.append(self.allocator, .{ .code = .return_op, .arg = .{ .node = new_value } });
            }

            const switch_node = try buildSwitchFromOps(self, ops.items, span, wrapper_scope, .none);
            var state_temps: std.ArrayListUnmanaged(HoistedStateTemp) = .empty;
            errdefer state_temps.deinit(self.allocator);
            const var_decl_node = try buildHoistedVarDecl(self, &.{}, span, &state_temps, wrapper_scope);
            return .{ .body = switch_node, .var_decl = var_decl_node, .hoisted_temps = state_temps };
        }

        /// A generated switch changes the lexical placement of private class
        /// artifacts. Transfer only their producer-selected IDs; ordinary vars
        /// and deferred loop/state-machine protocols keep their own migration.
        fn movePrivateCaseBindingsAndReferences(self: *Transformer, root: NodeIndex, source: ScopeId, target: ScopeId) Transformer.Error!void {
            if (!self.semantic_edit_enabled) return;
            const editor = &self.semantic_editor.?;
            const Work = struct { node: NodeIndex, scope: ScopeId };
            var stack: std.ArrayList(Work) = .empty;
            defer stack.deinit(self.allocator);
            var bindings: std.ArrayList(NodeIndex) = .empty;
            defer bindings.deinit(self.allocator);
            var seen: std.AutoHashMapUnmanaged(u32, void) = .empty;
            defer seen.deinit(self.allocator);
            try stack.append(self.allocator, .{ .node = root, .scope = target });
            while (stack.pop()) |work| {
                const node = work.node;
                if (node.isNone()) continue;
                const raw = @backingInt(node);
                const entry = try seen.getOrPut(self.allocator, raw);
                if (entry.found_existing) continue;
                const ast_node = self.ast.getNode(node);
                const scope = self.outputOwnedScope(node) orelse work.scope;
                if (self.getSymbolIdAt(node)) |id| {
                    if (self.private_helper_symbol_ids.contains(id)) {
                        const symbol = editor.symbols.items[id];
                        if (ast_node.tag == .binding_identifier and symbol.scope_id == source and
                            symbol.kind != .variable_var and symbol.kind != .parameter)
                            try bindings.append(self.allocator, node);
                    }
                }
                var children = @import("../parser/ast_walk.zig").children(self.ast, ast_node);
                while (children.next()) |child| {
                    const declaration_name = ast_node.tag == .function_declaration and self.readNodeIdx(ast_node.data.extra, ast_mod.FunctionExtra.name) == child;
                    try stack.append(self.allocator, .{ .node = child, .scope = if (declaration_name) work.scope else scope });
                }
            }
            try es_helpers.relocatePrivateReferences(self, root, target);
            for (bindings.items) |binding| {
                const id = self.getSymbolIdAt(binding).?;
                try self.relocateOutputSymbolAs(id, target, binding);
            }
        }

        fn moveCaseReferences(self: *Transformer, root: NodeIndex, target: ScopeId, transfer: ?BoundGeneratorTransfer) Transformer.Error!void {
            const editor = &self.semantic_editor.?;
            const Work = struct { node: NodeIndex, scope: ScopeId };
            var stack: std.ArrayList(Work) = .empty;
            defer stack.deinit(self.allocator);
            var seen: std.AutoHashMapUnmanaged(u32, void) = .empty;
            defer seen.deinit(self.allocator);
            try stack.append(self.allocator, .{ .node = root, .scope = target });
            while (stack.pop()) |work| {
                if (work.node.isNone()) continue;
                const raw = @backingInt(work.node);
                const slot = try seen.getOrPut(self.allocator, raw);
                if (slot.found_existing) continue;
                const node = self.ast.getNode(work.node);
                const scope = self.outputOwnedScope(work.node) orelse work.scope;
                if (editor.node_scope_provenance.get(work.node)) |origin| {
                    if (transfer != null and origin.source_external != null and origin.scope != scope) {
                        var moved = origin;
                        moved.scope = scope;
                        var proof = transfer.?.proof;
                        for (transfer.?.heritages) |heritage| if (heritage.read == origin.source_node) {
                            proof.heritage = heritage;
                            break;
                        };
                        var computed: ?u32 = null;
                        for (editor.scope_history.source_computed_awaits, 0..) |key, index| {
                            if (key.leaf.node != origin.source_node or key.scope != origin.source_external.?.execution_scope) continue;
                            if (computed != null) @panic("generator key read has duplicate actual source carriers");
                            computed = @intCast(index);
                        }
                        proof.computed_await_source = computed;
                        moved.source_external = try @import("../semantic/source_external_origin.zig").transferredGenerator(self.allocator, origin.source_external.?, work.node, origin.source_node, origin.scope, scope, editor.scopes.items, editor.scope_history.epoch(), proof);
                        try editor.node_scope_provenance.put(self.allocator, work.node, moved);
                        try self.transformed_node_scope_provenance.put(self.allocator, work.node, moved);
                        self.node_scope_provenance_changed = true;
                    } else try self.relocateNodeScopeProvenance(work.node, origin.scope, scope);
                }
                if (self.generator_collected_function_roots.fetchRemove(raw)) |entry| {
                    if (self.outputScopeParent(entry.value) != work.scope)
                        try self.reparentGeneratedScope(entry.value, work.scope);
                }
                const block_owner = switch (node.tag) {
                    .block_statement, .for_statement, .for_in_statement, .for_of_statement, .while_statement, .do_while_statement, .switch_statement, .catch_clause => true,
                    else => false,
                };
                if (block_owner and scope != work.scope and editor.scopes.items[scope.toIndex()].parent != work.scope)
                    try self.reparentGeneratedScope(scope, work.scope);
                if (node.tag == .identifier_reference or node.tag == .assignment_target_identifier or node.tag == .jsx_identifier) {
                    const reference = editor.referenceForNode(work.node) catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        else => std.debug.panic("generator case lost its reference row: {s}", .{@errorName(err)}),
                    };
                    if (reference) |ref| {
                        if (!ref.flags.declare and ref.scope_id != scope)
                            editor.moveReference(work.node, scope, ref.stmt_idx, ref.scope_stmt_idx) catch |err| switch (err) {
                                error.OutOfMemory => return error.OutOfMemory,
                                else => {
                                    std.debug.panic("generator case cannot move exact reference: {s} node={d} name={s} sid={d} oldscope={d} target={d} declscope={d} targetparent={d} declkind={s} rootScope={d}", .{ @errorName(err), raw, self.ast.identifierNameText(node), @backingInt(ref.symbol_id), ref.scope_id.toIndex(), scope.toIndex(), editor.symbols.items[@backingInt(ref.symbol_id)].scope_id.toIndex(), editor.scopes.items[scope.toIndex()].parent.toIndex(), @tagName(editor.scopes.items[editor.symbols.items[@backingInt(ref.symbol_id)].scope_id.toIndex()].kind), target.toIndex() });
                                },
                            };
                        if (self.tracked_runtime_helper_ref_index.get(raw)) |index| {
                            const tracked = &self.tracked_runtime_helper_refs.items[index];
                            if (tracked.node != work.node or tracked.symbol_id != @backingInt(ref.symbol_id))
                                std.debug.panic("generator helper tracker changed its exact reference identity", .{});
                            tracked.scope = scope;
                        }
                    }
                }
                var children = @import("../parser/ast_walk.zig").children(self.ast, node);
                while (children.next()) |child| {
                    const skips = @import("transformer/semantic_edit.zig").childSkipsOutputScope(self.ast, raw, @backingInt(child));
                    try stack.append(self.allocator, .{ .node = child, .scope = if (skips) work.scope else scope });
                }
            }
        }

        /// 연산 리스트를 switch case로 변환.
        /// `ops[from]` 이후 처음 나오는 실행 op 가 **재개 라벨에 민감한지**.
        ///
        /// `__generator` 의 op 4(`yield`)·5(`yield*`)는 실행 시 `_.label++` 로 재개 위치를
        /// 잡는다. 따라서 그 op 는 자기 case 의 라벨 + 1 에서 재개돼야 한다 — 빈 case 가
        /// 앞에 붙어 폴스루하면 그 관계가 깨져 같은 yield 가 두 번 실행된다. (#4718)
        fn nextOpIsResumeSensitive(ops: []const Operation, from: usize) bool {
            // 폴스루해 들어갈 case 의 **끝까지**(다음 nop 전까지) 본다. 문장 몇 개 뒤에 yield 가
            // 와도 같은 문제다 — 빈 라벨로 들어오면 yield 후 재개 라벨이 그 case 자신이라
            // 문장까지 **통째로 다시 실행**된다(#4722 에서 발견 — #4718 은 바로 다음만 봤다).
            var i = from + 1;
            while (i < ops.len) : (i += 1) {
                switch (ops[i].code) {
                    .nop => return false, // 다음 case 가 시작 — 빈 case 가 이어진다
                    .yield_op, .yield_star => return true,
                    else => {},
                }
            }
            return false;
        }

        fn buildSwitchFromOps(self: *Transformer, ops: []const Operation, span: Span, wrapper_scope: ScopeId, reserved: NodeIndex) Transformer.Error!NodeIndex {
            const scratch_top = self.scratch.items.len;
            defer self.scratch.shrinkRetainingCapacity(scratch_top);

            var case_num: u32 = 0;
            // label = case number 직접 사용 (nop 순서대로 번호 매김)
            var current_case_stmts: std.ArrayList(NodeIndex) = .empty;
            defer current_case_stmts.deinit(self.allocator);

            for (ops, 0..) |op, op_i| {
                switch (op.code) {
                    .nop => {
                        // fall-through 방지: __generator는 label로 case를 추적하므로
                        // fall-through 시 label과 실행 위치가 불일치하여 무한루프.
                        // .return_statement 하나만 체크해도 충분: yield_op, return_op,
                        // break_op 모두 buildInstructionReturn을 거쳐 return_statement 생성.
                        if (current_case_stmts.items.len > 0) {
                            const next_case = case_num + 1;
                            const last_node = self.ast.getNode(current_case_stmts.items[current_case_stmts.items.len - 1]);
                            if (last_node.tag != .return_statement) {
                                const jump = try buildInstructionReturn(self, 3, try es_helpers.makeNumericLiteral(self, next_case), span);
                                try current_case_stmts.append(self.allocator, jump);
                            }
                        } else if (nextOpIsResumeSensitive(ops, op_i)) {
                            // **빈 case** 도 그냥 폴스루하면 안 된다 (#4718).
                            // 라벨이 겹치는 자리(예: try 영역 종료 라벨 + 라벨 스코프 종료
                            // 라벨)에 `yield` 가 오면 `case 14: case 15: return [4, v]` 가 되는데,
                            // `__generator` 의 op 4/5 는 재개 라벨을 **현재 라벨 + 1** 로 잡는다.
                            // 14 로 들어오면 재개가 15 = 같은 yield → **값이 두 번 방출된다**.
                            // 다음 op 가 재개 라벨에 민감할 때만 명시 점프를 넣어 크기 영향을 막는다.
                            const jump = try buildInstructionReturn(self, 3, try es_helpers.makeNumericLiteral(self, case_num + 1), span);
                            try current_case_stmts.append(self.allocator, jump);
                        }
                        const case_node = try buildSwitchCase(self, case_num, current_case_stmts.items, span);
                        try self.scratch.append(self.allocator, case_node);
                        current_case_stmts.clearRetainingCapacity();
                        case_num += 1;
                    },
                    .statement => {
                        if (op.arg == .node and !op.arg.node.isNone()) {
                            try current_case_stmts.append(self.allocator, op.arg.node);
                        }
                    },
                    .yield_op => {
                        // return [4, value]
                        const ret = try buildInstructionReturn(self, 4, if (op.arg == .node) op.arg.node else .none, span);
                        try current_case_stmts.append(self.allocator, ret);
                        // case 마무리 (다음 nop에서 새 case가 시작됨)
                    },
                    .return_op => {
                        // return [2, value]
                        const ret = try buildInstructionReturn(self, 2, if (op.arg == .node) op.arg.node else .none, span);
                        try current_case_stmts.append(self.allocator, ret);
                    },
                    .break_op => {
                        // return [3, label]
                        const label = if (op.arg == .label) op.arg.label else 0;
                        const label_node = try es_helpers.makeNumericLiteral(self, label);
                        const ret = try buildInstructionReturn(self, 3, label_node, span);
                        try current_case_stmts.append(self.allocator, ret);
                    },
                    .break_when_false => {
                        if (op.arg == .label_and_node) {
                            const stmt = try buildConditionalBreak(self, op.arg.label_and_node.label, op.arg.label_and_node.node, true, span);
                            try current_case_stmts.append(self.allocator, stmt);
                        }
                    },
                    .break_when_true => {
                        if (op.arg == .label_and_node) {
                            const stmt = try buildConditionalBreak(self, op.arg.label_and_node.label, op.arg.label_and_node.node, false, span);
                            try current_case_stmts.append(self.allocator, stmt);
                        }
                    },
                    .yield_star => {
                        // return [5, __values(iter)] — (#1910) raw iterable 을 iterator 로 wrap.
                        // __generator 의 op[5] 가 .next 직접 호출해서 string/Map/Set 같이
                        // [Symbol.iterator] 만 가진 iterable 은 그대로 못 씀.
                        const inner_iter = if (op.arg == .node) op.arg.node else .none;
                        const wrapped_iter = if (!inner_iter.isNone()) blk: {
                            self.runtime_helpers.values = true;
                            const values_ref = try es_helpers.makeRuntimeHelperRef(self, "__values");
                            break :blk try es_helpers.makeCallExpr(self, values_ref, &.{inner_iter}, span);
                        } else inner_iter;
                        const ret = try buildInstructionReturn(self, 5, wrapped_iter, span);
                        try current_case_stmts.append(self.allocator, ret);
                    },
                }
            }

            // 마지막 case
            if (current_case_stmts.items.len > 0) {
                const case_node = try buildSwitchCase(self, case_num, current_case_stmts.items, span);
                try self.scratch.append(self.allocator, case_node);
            }

            // switch(_state.label) { cases... }
            const state_ref = try makeGeneratorStateRef(self);
            const label_prop = try es_helpers.makePropertyName(self, "label");
            const discriminant = try es_helpers.makeStaticMember(self, state_ref, label_prop, span);

            // switch_statement: extra = [discriminant, cases_start, cases_len]
            const cases_list = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
            const switch_extra = try self.ast.addExtras(&.{
                @backingInt(discriminant),
                cases_list.start,
                cases_list.len,
            });
            const completed: Node = .{ .tag = .switch_statement, .span = span, .data = .{ .extra = switch_extra } };
            const result = if (reserved.isNone()) try self.ast.addNode(completed) else blk: {
                self.ast.nodes.items[@backingInt(reserved)] = completed;
                break :blk reserved;
            };
            if (self.semantic_edit_enabled) {
                const scope = if (reserved.isNone()) try self.addGeneratedScope(wrapper_scope, result, .switch_block) else self.outputOwnedScope(reserved) orelse std.debug.panic("reserved generator switch lost its ScopeId", .{});
                // Native lexical declarations and classes inside the cases
                // belong to this switch environment, not its future callback
                // parent. Claim it before callback assembly or finalization.
                try self.reparentGeneratedBodyScopes(wrapper_scope, scope, result);
                try movePrivateCaseBindingsAndReferences(self, result, wrapper_scope, scope);
            }
            return result;
        }

        /// block_statement이면 내부 문들을 순회, 아니면 단일 문으로 collectOperations.
        /// 상태 기계가 직접 수집하는 문장 목록에 `using` 이 있으면 try/finally 구조로 먼저
        /// 바꾼다 — 이 경로는 목록 방문(visitListNode)을 거치지 않아 dispose 가 빠졌다 (#4730).
        fn rewriteUsingForStateMachine(self: *Transformer, list: ast_mod.NodeList) Transformer.Error!@import("es2025_using.zig").UsingRewriteResult {
            if (!self.options.unsupported.using) return .{ .statements = list };
            const Using = @import("es2025_using.zig").ES2025Using(Transformer);
            if (!Using.hasUsingDeclaration(self, list.start, list.len)) return .{ .statements = list };
            return Using.rewriteUsingStatementsWithOwner(self, list.start, list.len, .body);
        }

        fn collectRewrittenUsingStatement(self: *Transformer, statement: NodeIndex, disposal_try: NodeIndex, ops: *std.ArrayList(Operation), next_label: *u32) Transformer.Error!void {
            if (!disposal_try.isNone() and statement == disposal_try) {
                const node = self.ast.getNode(statement);
                if (node.tag != .try_statement) std.debug.panic("using cleanup owner is not its generated try", .{});
                // The constructor moved the list into this exact disposal try.
                // Its declarations already have wrapper storage, so collect
                // them as assignments instead of cloning native declarations.
                return collectTryOperations(self, statement, node, ops, next_label, .using_cleanup);
            }
            return collectOperations(self, statement, ops, next_label);
        }

        const ForOf = @import("es2015_for_of.zig").ES2015ForOf(Transformer);

        /// 블록 스코프 바인딩 리네임(#4712)이 동작하는지. 식별자 리네임은 block scoping 을
        /// 낮출 때만 적용되므로, 그렇지 않은 조합에서는 예전처럼 원래 이름을 끌어올린다.
        fn stateMachineRenamesBlockScope(self: *const Transformer) bool {
            return self.options.unsupported.block_scoping;
        }

        fn isLexicalDeclaration(self: *Transformer, idx: NodeIndex) bool {
            if (idx.isNone()) return false;
            const node = self.ast.getNode(idx);
            if (node.tag == .class_declaration) return true;
            return node.tag == .variable_declaration and self.ast.hasExtra(node.data.extra, 3) and
                self.ast.variableDeclarationKind(node).isLexical();
        }

        /// 목록 직계의 let/const/class 선언 이름.
        /// 목록 직계의 let/const/class 선언이 만드는 바인딩 노드. 이름이 아니라 노드를 모아
        /// 바꾼 이름의 `var` 선언에 원래 심볼을 물려줄 수 있게 한다 (#4760).
        fn collectLexicalBindingsInList(self: *Transformer, list: ast_mod.NodeList, out: *std.ArrayList(NodeIndex)) Transformer.Error!void {
            var i: u32 = 0;
            while (i < list.len) : (i += 1) {
                const idx: NodeIndex = @fromBackingInt(@intCast(self.ast.extra_data.items[list.start + i]));
                if (!isLexicalDeclaration(self, idx)) continue;
                const node = self.ast.getNode(idx);
                if (node.tag == .class_declaration) {
                    const name = self.readNodeIdx(node.data.extra, ast_mod.ClassExtra.name);
                    if (!name.isNone()) try out.append(self.allocator, name);
                    continue;
                }
                const ds = self.readU32(node.data.extra, 1);
                const dl = self.readU32(node.data.extra, 2);
                var j: u32 = 0;
                while (j < dl) : (j += 1) {
                    const d = self.ast.getNode(@fromBackingInt(@intCast(self.ast.extra_data.items[ds + j])));
                    if (d.tag != .variable_declarator) continue;
                    try collectBindingNodes(self, self.readNodeIdx(d.data.extra, 0), out);
                }
            }
        }

        /// 패턴 안의 바인딩 식별자 노드 (`collectBindingNames` 의 노드판).
        fn collectBindingNodes(self: *Transformer, idx: NodeIndex, out: *std.ArrayList(NodeIndex)) Transformer.Error!void {
            var it = try ast_walk.bindingIdentifiers(self.allocator, self.ast, idx, .{});
            defer it.deinit();
            while (try it.next()) |leaf_idx| {
                if (self.ast.getNode(leaf_idx).tag != .binding_identifier) continue;
                try out.append(self.allocator, leaf_idx);
            }
        }

        /// 상태 기계가 수집하는 블록 스코프 바인딩을 wrapper 최상단 var 로 등록한다 (#4712).
        /// 사용자 바인딩(심볼 있음)은 **항상** `name$N` 으로 바꿔 심볼 표에 둔다 — 상태 기계는
        /// 블록마다 바인딩을 한 함수 스코프로 모으므로 같은 이름이 겹칠 수 있다(#4760 이전의 이름
        /// 스택 판정과 같은 보수적 선택). 심볼 표가 이미 정한 이름이 있으면 그 이름을 쓴다.
        /// 심볼 없는 바인딩은 변환기가 만든 임시 변수(`_d`, `_using`, `_` …)로, 만들 때 함수 안에서
        /// 고유하게 지어지므로 이름을 그대로 올린다.
        fn registerStateMachineBindings(self: *Transformer, bindings: []const NodeIndex) Transformer.Error!void {
            return registerStateMachineBindingsWithHoisting(self, bindings, false);
        }

        fn registerStateMachineBindingsWithHoisting(self: *Transformer, bindings: []const NodeIndex, force_hoist: bool) Transformer.Error!void {
            for (bindings) |binding| {
                const bi = @backingInt(binding);
                const sym: ?u32 = if (bi < self.symbol_ids.items.len) self.symbol_ids.items[bi] else null;
                const sid = sym orelse {
                    _ = try registerGeneratorVar(self, self.ast.getNode(binding).data.string_ref, binding);
                    continue;
                };
                // 블록 스코프가 네이티브인 타깃(chrome49)은 소스 바인딩을 제자리에 둔다. 다만 분석 후
                // 하강이 만든 바인딩(for-of 의 `catch (_err)`, 이름이 string table 에 있음)은 어느
                // hoist 스캔에도 없으므로 여기서 선언해야 strict 코드에서 ReferenceError 가 안 난다 (#5769).
                if (!stateMachineRenamesBlockScope(self) and !force_hoist) {
                    const name_span = self.ast.getNode(binding).data.string_ref;
                    if (name_span.start & ast_mod.Ast.STRING_TABLE_BIT != 0 and !isRegisteredGeneratorBinding(self, binding))
                        _ = try registerGeneratorVar(self, name_span, binding);
                    continue;
                }
                const symbols = if (self.semantic_editor) |*editor| editor.symbols.items else self.symbols;
                if (self.semantic_edit_enabled and self.options.defer_runtime_helper_name_resolution and
                    !self.options.emit_runtime_helper_imports and sid < symbols.len and
                    es_helpers.isStandaloneLateOutputNameSymbol(symbols[sid]))
                {
                    // The standalone exact-ID naming pass owns this symbol's
                    // final spelling. A second name$N choice here conflicts
                    // with that pass when the generated loop temp is hoisted.
                    _ = try registerGeneratorVar(self, self.ast.getNode(binding).data.string_ref, binding);
                    continue;
                }
                const new_name = self.tableRenameOf(binding) orelse blk: {
                    const raw_name = self.ast.getText(if (force_hoist) self.ast.getNode(binding).data.string_ref else self.ast.getNode(binding).span);
                    const name = if (force_hoist) try Scanner.decodeIdentifierEscapesAlloc(self.allocator, raw_name) else raw_name;
                    defer if (name.ptr != raw_name.ptr) self.allocator.free(name);
                    self.block_rename_counter += 1;
                    if (self.name_arena == null) self.name_arena = std.heap.ArenaAllocator.init(self.allocator);
                    const n = try std.fmt.allocPrint(self.name_arena.?.allocator(), "{s}${d}", .{ name, self.block_rename_counter });
                    if (self.block_rename_map == null) self.block_rename_map = .empty;
                    try self.block_rename_map.?.put(self.allocator, sid, n);
                    break :blk n;
                };
                const selected_name = if (force_hoist)
                    try es_helpers.resolveGeneratedNameAvoidingDynamicEval(self, new_name, self.generator_state_machine_scope)
                else
                    new_name;
                if (force_hoist) try self.block_rename_map.?.put(self.allocator, sid, selected_name);
                _ = try registerGeneratorVar(self, try self.ast.addString(selected_name), binding);
            }
        }

        fn directFunctionDeclaration(self: *Transformer, statement: NodeIndex) ?NodeIndex {
            var current = statement;
            var hops: usize = 0;
            while (!current.isNone() and hops < self.ast.nodes.items.len) : (hops += 1) {
                const node = self.ast.getNode(current);
                if (node.tag == .function_declaration) return current;
                if (node.tag != .labeled_statement) return null;
                current = node.data.binary.right;
            }
            return null;
        }

        pub fn ensureAnnexBVariableStorage(self: *Transformer, variable: u32) Transformer.Error!void {
            try self.ensureAnnexBVariableStorage(variable, true);
        }

        fn appendCollectedFunctionAlias(self: *Transformer, statement: NodeIndex, lexical: u32, ops: *std.ArrayList(Operation)) Transformer.Error!void {
            if (!self.semantic_edit_enabled or lexical == std.math.maxInt(u32)) return;
            const editor = &self.semantic_editor.?;
            const role = (@import("../semantic/annex_b_function.zig").forSymbol(editor.symbols.items, @fromBackingInt(lexical)) catch @panic("invalid lowered generator Annex B role")) orelse return;
            if (role.state != .lowered) @panic("generator function storage retained native Annex B affinity");
            const scope = self.generator_operation_scope;
            const span = self.ast.getNode(statement).span;
            const variable = editor.symbols.items[@backingInt(role.variable)];
            const local = editor.symbols.items[lexical];
            // Relocation already chose each known identity's physical storage
            // spelling. Publish it on the new AST edges as well: legacy graph
            // reanalysis must see V=L, not two original same-text names.
            // Both edges are synthetic: their diagnostic span is the whole
            // declaration, so even unchanged names need string-table backing.
            const variable_name = try self.ast.addString(if (variable.synthetic_name.len > 0) variable.synthetic_name else self.ast.getText(variable.name));
            const local_name = try self.ast.addString(if (local.synthetic_name.len > 0) local.synthetic_name else self.ast.getText(local.name));
            const target = try self.ast.addNode(.{ .tag = .assignment_target_identifier, .span = span, .data = .{ .string_ref = variable_name } });
            const value = try es_helpers.makeIdentifierRefFromSpan(self, local_name);
            try self.addSyntheticRefInScope(target, role.variable, scope, .{ .write = true });
            try self.addSyntheticRefInScope(value, role.lexical, scope, .{ .read = true });
            try self.trackExactOutputRead(value, lexical);
            const assignment = try es_helpers.makeAssignStmt(self, target, value, span, 0);
            try ops.append(self.allocator, .{ .code = .statement, .arg = .{ .node = assignment } });
        }

        /// Implicit V belongs to its initial function environment, even when L
        /// was collected inside a nested loop helper. Bind once at that actual
        /// live function owner; never put V in each block/callback's storage.
        pub fn appendAnnexBVariableStorage(self: *Transformer, root: NodeIndex) Transformer.Error!void {
            if (!self.semantic_edit_enabled or self.semantic_editor == null) return;
            const editor = &self.semantic_editor.?;
            var has_fdi = false;
            for (editor.symbols.items) |symbol| if (symbol.binding_instantiation.parameter_copy) {
                has_fdi = true;
                break;
            };
            if (!has_fdi and self.generator_annex_b_var_bindings.count() == 0 and self.loop_annex_b_setters.count() == 0) return;
            var owners: std.AutoHashMapUnmanaged(u32, NodeIndex) = .empty;
            defer owners.deinit(self.allocator);
            var parameter_owners: std.AutoHashMapUnmanaged(u32, ScopeId) = .empty;
            defer parameter_owners.deinit(self.allocator);
            const Declaration = struct { node: NodeIndex, declarator: NodeIndex, binding: NodeIndex, symbol: u32, scope: ScopeId };
            var declarations: std.ArrayList(Declaration) = .empty;
            defer declarations.deinit(self.allocator);
            const Work = struct { node: NodeIndex, scope: ScopeId };
            var stack: std.ArrayList(Work) = .empty;
            defer stack.deinit(self.allocator);
            try stack.append(self.allocator, .{ .node = root, .scope = self.programScope() });
            while (stack.pop()) |work| {
                const index = work.node;
                const node = self.ast.getNode(index);
                const scope = self.outputOwnedScope(index) orelse work.scope;
                switch (node.tag) {
                    .program => {
                        if (scope != self.programScope()) @panic("Annex B program storage changed owner");
                        try owners.put(self.allocator, @backingInt(scope), index);
                    },
                    .function_declaration, .function_expression, .function, .arrow_function_expression, .method_definition => {
                        const slot = try owners.getOrPut(self.allocator, @backingInt(scope));
                        if (slot.found_existing and slot.value_ptr.* != index) @panic("entry storage has ambiguous live function owner");
                        slot.value_ptr.* = index;
                        const parameters = self.readNodeIdx(node.data.extra, if (node.tag == .arrow_function_expression) 0 else 1);
                        var leaves = try ast_walk.bindingIdentifiers(self.allocator, self.ast, parameters, .{});
                        defer leaves.deinit();
                        while (try leaves.next()) |binding| if (self.getSymbolIdAt(binding)) |sid| {
                            const owner = try parameter_owners.getOrPut(self.allocator, sid);
                            if (owner.found_existing and owner.value_ptr.* != scope) @panic("FDI parameter has ambiguous function owner");
                            owner.value_ptr.* = scope;
                        };
                    },
                    .variable_declaration => if (self.ast.variableDeclarationKind(node) == .@"var") {
                        const start = self.readU32(node.data.extra, 1);
                        const count = self.readU32(node.data.extra, 2);
                        for (0..count) |i| {
                            const declarator: NodeIndex = @fromBackingInt(self.ast.extra_data.items[start + i]);
                            const pattern = self.readNodeIdx(self.ast.getNode(declarator).data.extra, 0);
                            var leaves = try ast_walk.bindingIdentifiers(self.allocator, self.ast, pattern, .{});
                            defer leaves.deinit();
                            while (try leaves.next()) |binding| if (self.getSymbolIdAt(binding)) |sid| {
                                if (sid < editor.symbols.items.len and editor.symbols.items[sid].binding_instantiation.parameter_copy)
                                    try declarations.append(self.allocator, .{ .node = index, .declarator = declarator, .binding = binding, .symbol = sid, .scope = self.nearestVarScope(scope) });
                            };
                        }
                    },
                    else => {},
                }
                var children = ast_walk.children(self.ast, node);
                while (children.next()) |child| if (!child.isNone()) {
                    const skips = @import("transformer/semantic_edit.zig").childSkipsOutputScope(self.ast, @backingInt(index), @backingInt(child));
                    try stack.append(self.allocator, .{ .node = child, .scope = if (skips) work.scope else scope });
                };
            }
            for (declarations.items) |declaration| {
                const role = (@import("../semantic/parameter_body_var.zig").forSymbol(editor.symbols.items, @fromBackingInt(declaration.symbol)) catch @panic("invalid FDI storage role")) orelse @panic("FDI declaration lost its source role");
                var owner_scope = parameter_owners.get(@backingInt(role.parameter));
                for (self.parameter_body_var_copies.items) |copy| if (copy.native_fdi_role and copy.body_var_symbol_id == declaration.symbol) {
                    if (copy.parameter_symbol_id != @backingInt(role.parameter)) @panic("FDI storage copy changed parameter identity");
                    if (owner_scope) |known| if (known != copy.function_scope) @panic("FDI parameter and copy disagree on function owner");
                    owner_scope = copy.function_scope;
                };
                const owner = owner_scope orelse @panic("FDI storage has no actual parameter function owner");
                if (declaration.scope == owner) continue;
                self.generator_function_storage_changed = true;
                try self.generator_function_storage_scopes.put(self.allocator, @backingInt(owner), {});
                const declarator = self.ast.getNode(declaration.declarator);
                if (self.readNodeIdx(declarator.data.extra, 0) != declaration.binding or !self.readNodeIdx(declarator.data.extra, 1).isNone())
                    @panic("FDI storage move requires its separate initializer operation");
                const node = self.ast.getNode(declaration.node);
                const start = self.readU32(node.data.extra, 1);
                const count = self.readU32(node.data.extra, 2);
                var kept: std.ArrayList(NodeIndex) = .empty;
                defer kept.deinit(self.allocator);
                for (0..count) |i| {
                    const item: NodeIndex = @fromBackingInt(self.ast.extra_data.items[start + i]);
                    if (item != declaration.declarator) try kept.append(self.allocator, item);
                }
                if (kept.items.len == 0) {
                    self.ast.nodes.items[@backingInt(declaration.node)] = .{ .tag = .empty_statement, .span = node.span, .data = .{ .none = 0 } };
                } else {
                    const list = try self.ast.addNodeList(kept.items);
                    self.ast.extra_data.items[node.data.extra + 1] = list.start;
                    self.ast.extra_data.items[node.data.extra + 2] = list.len;
                }
                const slot = try self.generator_annex_b_var_bindings.getOrPut(self.allocator, declaration.symbol);
                if (!slot.found_existing) slot.value_ptr.* = declaration.binding;
                try self.relocateOutputSymbolAs(declaration.symbol, owner, slot.value_ptr.*);
            }
            var bindings = self.generator_annex_b_var_bindings.iterator();
            while (bindings.next()) |entry| {
                const symbol = editor.symbols.items[entry.key_ptr.*];
                const function = owners.get(@backingInt(symbol.scope_id)) orelse @panic("entry var lost its owning function");
                const node = self.ast.getNode(function);
                const declarator = try es_helpers.makeDeclarator(self, entry.value_ptr.*, .none, node.span);
                const declaration = try es_helpers.makeVarDeclaration(self, &.{declarator}, .@"var", node.span);
                try prependAnnexBStorage(self, function, declaration);
            }
            self.generator_annex_b_var_bindings.clearRetainingCapacity();
            var setters = self.loop_annex_b_setters.iterator();
            while (setters.next()) |entry| {
                const setter = entry.value_ptr.*;
                const variable = entry.key_ptr.*;
                if (variable >= editor.symbols.items.len or @backingInt(setter.symbol) >= editor.symbols.items.len or
                    editor.symbols.items[variable].scope_id != setter.owner or
                    editor.symbols.items[@backingInt(setter.symbol)].scope_id != setter.owner or
                    self.getSymbolIdAt(setter.binding) != @as(?u32, @backingInt(setter.symbol)) or
                    self.ast.getNode(setter.value).tag != .function_expression) @panic("Annex B setter lost its actual owner or identity");
                const function_scope = self.outputOwnedScope(setter.value) orelse @panic("Annex B setter has no actual function owner");
                if (editor.scopes.items[function_scope.toIndex()].parent != setter.owner) @panic("Annex B setter moved into a foreign frame");
                const owner = owners.get(@backingInt(setter.owner)) orelse @panic("Annex B setter lost its live outer owner");
                const declarator = try es_helpers.makeDeclarator(self, setter.binding, setter.value, self.ast.getNode(owner).span);
                const declaration = try es_helpers.makeVarDeclaration(self, &.{declarator}, .@"var", self.ast.getNode(owner).span);
                try prependAnnexBStorage(self, owner, declaration);
            }
            self.loop_annex_b_setters.clearRetainingCapacity();
        }

        fn prependAnnexBStorage(self: *Transformer, owner: NodeIndex, declaration: NodeIndex) Transformer.Error!void {
            const node = self.ast.getNode(owner);
            if (node.tag == .program) {
                var statements: std.ArrayList(NodeIndex) = .empty;
                defer statements.deinit(self.allocator);
                try statements.append(self.allocator, declaration);
                for (self.ast.extra_data.items[node.data.list.start .. node.data.list.start + node.data.list.len]) |raw|
                    try statements.append(self.allocator, @fromBackingInt(raw));
                const list = try self.ast.addNodeList(statements.items);
                self.ast.nodes.items[@backingInt(owner)].data.list = list;
                self.generator_function_coordinate_program_changed = true;
            } else {
                const body_slot: u32 = if (node.tag == .arrow_function_expression) 1 else 2;
                const body = self.readNodeIdx(node.data.extra, body_slot);
                const body_node = self.ast.getNode(body);
                if (body_node.tag != .block_statement and body_node.tag != .function_body) @panic("entry var has no actual function body");
                const replacement = try self.prependStatementsToBody(body, &.{declaration});
                self.ast.extra_data.items[node.data.extra + body_slot] = @backingInt(replacement);
            }
        }

        /// Close the rewritten statement lists before the generic output
        /// validator runs. Identity and scope fields are never repaired here.
        pub fn projectFunctionStorageCoordinates(self: *Transformer, root: NodeIndex) Transformer.Error!void {
            if (!self.generator_function_storage_changed or self.semantic_editor == null) return;
            const editor = &self.semantic_editor.?;
            // A program prefix/removal can shift statement coordinates for
            // references nested anywhere under a top-level statement. Keep
            // that coordinate-reindexing scope separate from the function
            // storage producers: it must not authorize generator-cell
            // publication checks for every function in the program.
            const original_root: NodeIndex = @fromBackingInt(@as(u32, @intCast(self.parser_node_count - 1)));
            const original = self.ast.getNode(original_root);
            const output = self.ast.getNode(root);
            if (original.tag == .program and output.tag == .program and original.data.list.len != output.data.list.len)
                self.generator_function_coordinate_program_changed = true;
            // Public import/export/property spellings are not runtime reads,
            // even when their nodes carry the associated local SID.
            const value_nodes = try @import("../semantic/reference_walk.zig").collectIdentifierReferences(self.allocator, self.ast, root);
            for (value_nodes) |node| try self.generator_function_statement_value_nodes.put(self.allocator, @backingInt(node), {});
            const projection = @import("../bundler/statement_owner_projection.zig");
            const contexts = projection.collect(self.allocator, self.ast, root) catch |err| {
                if (err == error.OutOfMemory) return error.OutOfMemory;
                @panic("generator storage has ambiguous statement containment");
            };
            var classes: std.AutoHashMapUnmanaged(u32, void) = .empty;
            defer classes.deinit(self.allocator);
            var class_ids = self.class_self_symbol_map.valueIterator();
            while (class_ids.next()) |sid| try classes.put(self.allocator, sid.*, {});
            var selected: std.ArrayList(@import("../semantic/symbol.zig").Reference) = .empty;
            defer selected.deinit(self.allocator);
            var indices: std.ArrayList(usize) = .empty;
            defer indices.deinit(self.allocator);
            for (editor.references.items, 0..) |reference, index| {
                var current = reference.scope_id;
                var participates = self.generator_function_coordinate_program_changed;
                var hops: usize = 0;
                while (!current.isNone() and hops < editor.scopes.items.len) : (hops += 1) {
                    if (current.toIndex() >= editor.scopes.items.len) @panic("generator statement reference has an invalid owner");
                    if (self.generator_function_storage_scopes.contains(@backingInt(current))) {
                        participates = true;
                        break;
                    }
                    current = editor.scopes.items[current.toIndex()].parent;
                }
                if (!participates) continue;
                const node = if (reference.flags.declare) reference.declaration_node_index else reference.node_index;
                const sid = @backingInt(reference.symbol_id);
                if (sid >= editor.symbols.items.len) @panic("generator storage reference lost its exact SID");
                const symbol = editor.symbols.items[sid];
                const live_anchor = !node.isNone() and @backingInt(node) < contexts.len and contexts[@backingInt(node)] != null;
                const owned_anchorless = reference.flags.declare and node.isNone() and
                    (classes.contains(sid) or (symbol.kind == .variable_const and symbol.decl_flags.is_default_export and symbol.scope_id == self.programScope()));
                // Raw preamble and engine bindings have no AST statement. Do
                // not invent a statement owner for those existing roles.
                if (!live_anchor and !owned_anchorless) continue;
                try selected.append(self.allocator, reference);
                try indices.append(self.allocator, index);
            }
            const view = .{
                .references = selected.items,
                .symbols = editor.symbols,
                .scopes = editor.scopes.items,
                .symbol_ids = editor.symbol_ids.items,
                .scope_owner_map = editor.scope_owner_map,
                .class_self_symbol_map = self.class_self_symbol_map,
            };
            const projected = (projection.project(self.allocator, self.ast, root, &view) catch |err| {
                if (err == error.OutOfMemory) return error.OutOfMemory;
                @panic("generator storage has an invalid statement role");
            }) orelse @panic("generator storage lost an exact statement owner");
            for (projected, indices.items) |reference, index| {
                editor.references.items[index].stmt_idx = reference.stmt_idx;
                editor.references.items[index].scope_stmt_idx = reference.scope_stmt_idx;
                if (!reference.flags.declare and !reference.node_index.isNone()) {
                    const slot = try self.generator_function_coordinate_handoffs.getOrPut(self.allocator, @backingInt(reference.node_index));
                    const value: @TypeOf(slot.value_ptr.*) = .{ .symbol_id = reference.symbol_id, .scope = reference.scope_id, .stmt = reference.stmt_idx, .scope_stmt = reference.scope_stmt_idx };
                    if (slot.found_existing and !std.meta.eql(slot.value_ptr.*, value)) @panic("generator statement node has conflicting producer rows");
                    slot.value_ptr.* = value;
                }
            }
        }

        fn collectFunctionInitializers(self: *Transformer, list: NodeList, ops: *std.ArrayList(Operation)) Transformer.Error!bool {
            if (self.semantic_edit_enabled) {
                const source = self.semantic_editor.?.scopes.items[self.generator_state_machine_scope.toIndex()];
                if (source.subtree_has_direct_eval or source.subtree_has_with) return false;
            }
            const Entry = struct { node: NodeIndex, binding: NodeIndex, name: Span, symbol: ?u32, count: u32 = 1 };
            var entries: std.ArrayList(Entry) = .empty;
            defer entries.deinit(self.allocator);
            const DiscardedDeclaration = struct { binding: NodeIndex, symbol: u32 };
            var discarded_declarations: std.ArrayList(DiscardedDeclaration) = .empty;
            defer discarded_declarations.deinit(self.allocator);
            var selected: std.AutoHashMapUnmanaged(u32, usize) = .empty;
            defer selected.deinit(self.allocator);
            for (0..list.len) |index| {
                const statement: NodeIndex = @fromBackingInt(self.ast.extra_data.items[list.start + index]);
                const node = directFunctionDeclaration(self, statement) orelse continue;
                const source = self.ast.getNode(node);
                if (self.readNodeIdx(source.data.extra, ast_mod.FunctionExtra.body).isNone()) continue;
                const origin = self.readNodeIdx(source.data.extra, ast_mod.FunctionExtra.name);
                if (origin.isNone()) continue;
                const sid = self.getSymbolIdAt(origin);
                if (self.semantic_edit_enabled and sid == null) @panic("generator function declaration lost its initial binding SID");
                try self.generator_collected_function_declarations.put(self.allocator, @backingInt(statement), sid orelse std.math.maxInt(u32));
                if (sid) |id| {
                    if (selected.get(id)) |old| {
                        try discarded_declarations.append(self.allocator, .{ .binding = entries.items[old].binding, .symbol = id });
                        entries.items[old].node = node;
                        entries.items[old].binding = origin;
                        entries.items[old].count += 1;
                        continue;
                    }
                    try selected.put(self.allocator, id, entries.items.len);
                }
                const raw_name = try self.allocator.dupe(u8, self.ast.getText(self.ast.getNode(origin).data.string_ref));
                defer self.allocator.free(raw_name);
                const decoded = try @import("../lexer/scanner.zig").Scanner.decodeIdentifierEscapesAlloc(self.allocator, raw_name);
                defer if (decoded.ptr != raw_name.ptr) self.allocator.free(decoded);
                const name = try self.ast.addString(decoded);
                try entries.append(self.allocator, .{ .node = node, .binding = origin, .name = name, .symbol = sid });
            }
            if (entries.items.len != 0) {
                self.generator_function_storage_changed = true;
                if (self.semantic_edit_enabled) try self.generator_function_storage_scopes.put(self.allocator, @backingInt(self.generator_state_machine_scope), {});
            }
            // Freeze complete declaration groups before changing any L storage.
            for (entries.items) |*entry| {
                if (entry.symbol) |sid| if (self.semantic_edit_enabled) {
                    const editor = &self.semantic_editor.?;
                    const annex = @import("../semantic/annex_b_function.zig");
                    if ((annex.forDeclaration(self.ast, self.symbol_ids.items, editor.symbols.items, entry.node) catch @panic("invalid initial generator Annex B role"))) |role| {
                        _ = annex.markLowered(editor.symbols.items, role.lexical, entry.count) catch @panic("generator Annex B declaration count changed");
                        try ensureAnnexBVariableStorage(self, @backingInt(role.variable));
                    }
                    if (sid >= editor.symbols.items.len) @panic("invalid generator function SID");
                };
                if (entry.symbol) |sid| if (self.semantic_edit_enabled) {
                    // Repeated source declarations share a SID, but only the
                    // selected final declaration initializes this output slot.
                    // Consume each discarded source anchor before relocation;
                    // relocating all rows would alias them to one output anchor.
                    const editor = &self.semantic_editor.?;
                    if (entry.count > 1) {
                        var selected_rows: usize = 0;
                        for (editor.references.items) |reference| {
                            if (reference.flags.declare and reference.declaration_node_index == entry.binding) {
                                if (@backingInt(reference.symbol_id) != sid) @panic("generator selected declaration changed identity");
                                selected_rows += 1;
                            }
                        }
                        if (selected_rows != 1) @panic("generator selected function lost its exact declaration row");
                    }
                    for (discarded_declarations.items) |discarded| {
                        if (discarded.symbol != sid) continue;
                        if (discarded.binding == entry.binding or self.getSymbolIdAt(discarded.binding) != sid)
                            @panic("generator discarded function declaration changed identity");
                        _ = editor.removeDeclarationAtNode(discarded.binding, @fromBackingInt(sid)) catch
                            @panic("generator discarded function lost its exact declaration row");
                    }
                };
                try registerStateMachineBindingsWithHoisting(self, &.{entry.binding}, true);
                const producer_index = self.generator_temp_producer_identities.items.len - 1;
                const span = self.generator_temp_var_spans.items[producer_index];
                const binding = if (self.semantic_edit_enabled) try self.makeUserBinding(span, entry.binding) else entry.binding;
                if (entry.symbol) |sid| try self.relocateOutputSymbolAs(sid, self.generator_state_machine_scope, binding);
                self.generator_temp_producer_identities.items[producer_index].binding = binding;
                entry.binding = binding;
            }
            for (entries.items) |entry| {
                const visited = try self.visitNode(entry.node);
                const output = self.ast.getNode(visited);
                const e = output.data.extra;
                const expression = try self.addExtraNode(.function_expression, output.span, &.{
                    @backingInt(NodeIndex.none), @backingInt(self.readNodeIdx(e, 1)), @backingInt(self.readNodeIdx(e, 2)),
                    self.readU32(e, 3),          self.readU32(e, 4),
                });
                try self.remapCopiedScopeOwner(visited, expression);
                if (self.semantic_edit_enabled) {
                    const scope = self.outputOwnedScope(expression) orelse @panic("collected function lost its source ScopeId");
                    const params = self.readNodeIdx(self.ast.getNode(expression).data.extra, 1);
                    try self.generator_collected_function_roots.put(self.allocator, @backingInt(expression), self.outputOwnedScope(params) orelse scope);
                }
                self.runtime_helpers.keep_names = true;
                const callee = try es_helpers.makeRuntimeHelperRef(self, "__name");
                const literal = try es_helpers.buildQuotedKeyLiteral(self, entry.name);
                const value = try es_helpers.makeCallExpr(self, callee, &.{ expression, literal }, output.span);
                const target = try bindingToAssignTarget(self, entry.binding);
                const statement = try es_helpers.makeAssignStmt(self, target, value, output.span, 0);
                try ops.append(self.allocator, .{ .code = .statement, .arg = .{ .node = statement } });
            }
            return true;
        }

        fn isRegisteredGeneratorBinding(self: *Transformer, binding: NodeIndex) bool {
            const id = self.getSymbolIdAt(binding);
            for (self.generator_temp_producer_identities.items) |producer| {
                const origin = producer.source_binding;
                if (origin.isNone()) continue;
                if (origin == binding) return true;
                if (id) |symbol_id| {
                    if (self.getSymbolIdAt(origin) == symbol_id) return true;
                }
            }
            return false;
        }

        fn registerLoopHeadBindings(self: *Transformer, head: NodeIndex) Transformer.Error!void {
            if (!isLexicalDeclaration(self, head)) return;
            var bindings: std.ArrayList(NodeIndex) = .empty;
            defer bindings.deinit(self.allocator);
            try collectLexicalBindingsInList(self, .{ .start = try self.ast.addExtras(&.{@backingInt(head)}), .len = 1 }, &bindings);
            try registerStateMachineBindings(self, bindings.items);
        }

        fn collectBodyOperations(self: *Transformer, body_idx: NodeIndex, ops: *std.ArrayList(Operation), next_label: *u32) Transformer.Error!void {
            const saved_scope = self.generator_operation_scope;
            if (self.semantic_edit_enabled) {
                const raw = @backingInt(body_idx);
                const owner_scope = if (self.scope_owner_removed.contains(raw)) null else self.transformed_scope_owner_map.get(raw) orelse
                    self.scope_owner_map.get(raw) orelse
                    if (self.semantic_editor) |*editor| editor.scope_owner_map.get(raw) else null;
                if (owner_scope) |scope| self.generator_operation_scope = @fromBackingInt(@intCast(scope));
            }
            defer self.generator_operation_scope = saved_scope;
            const body_node = self.ast.getNode(body_idx);
            if (body_node.tag == .block_statement) {
                // 이 블록의 let/const/class/using 은 블록 스코프 — 고유 이름으로 바꿔 wrapper 에
                // 등록한다(호이스팅은 중첩 블록의 lexical 선언을 건너뛴다) (#4712). using 재구성
                // 뒤에는 var 가 되므로 이름은 **원래 목록**에서 모은다.
                var lexical: std.ArrayList(NodeIndex) = .empty;
                defer lexical.deinit(self.allocator);
                try collectLexicalBindingsInList(self, body_node.data.list, &lexical);
                const list = try rewriteUsingForStateMachine(self, body_node.data.list);
                const stmts_start = list.statements.start;
                const stmts_len = list.statements.len;
                try registerStateMachineBindings(self, lexical.items);
                _ = try collectFunctionInitializers(self, list.statements, ops);
                // collectOperations가 extra_data를 재할당할 수 있으므로 인덱스 루프 사용
                var i_stmt: u32 = 0;
                while (i_stmt < stmts_len) : (i_stmt += 1) {
                    const raw_idx = self.ast.extra_data.items[stmts_start + i_stmt];
                    try collectRewrittenUsingStatement(self, @fromBackingInt(@intCast(raw_idx)), list.disposal_try, ops, next_label);
                }
            } else {
                try collectOperations(self, body_idx, ops, next_label);
            }
        }

        /// 조건부 break: if (cond) return [3, label] 또는 if (!cond) return [3, label].
        /// negate=true이면 조건을 !로 반전.
        fn buildConditionalBreak(self: *Transformer, label: u32, cond: NodeIndex, negate: bool, span: Span) Transformer.Error!NodeIndex {
            const final_cond = if (negate) blk: {
                // !cond 의 paren 은 precedence 재유도가 처리 (#4042 PR8)
                break :blk try self.ast.addNode(.{
                    .tag = .unary_expression,
                    .span = span,
                    .data = .{ .extra = try self.ast.addExtras(&.{
                        @backingInt(cond),
                        @backingInt(token_mod.Kind.bang),
                    }) },
                });
            } else cond;

            const label_node = try es_helpers.makeNumericLiteral(self, label);
            const break_ret = try buildInstructionReturn(self, 3, label_node, span);
            const if_body_list = try self.ast.addNodeList(&.{break_ret});
            const if_body = try self.ast.addNode(.{
                .tag = .block_statement,
                .span = span,
                .data = .{ .list = if_body_list },
            });
            return self.ast.addNode(.{
                .tag = .if_statement,
                .span = span,
                .data = .{ .ternary = .{ .a = final_cond, .b = if_body, .c = .none } },
            });
        }

        /// switch case 노드 생성: case N: stmts...
        /// switch_case: extra = [test_expr, stmts_start, stmts_len]
        fn buildSwitchCase(self: *Transformer, case_num: u32, stmts: []const NodeIndex, span: Span) Transformer.Error!NodeIndex {
            const test_node = try es_helpers.makeNumericLiteral(self, case_num);

            const body_list = try self.ast.addNodeList(stmts);
            const case_extra = try self.ast.addExtras(&.{
                @backingInt(test_node),
                body_list.start,
                body_list.len,
            });

            return self.ast.addNode(.{
                .tag = .switch_case,
                .span = span,
                .data = .{ .extra = case_extra },
            });
        }

        /// return [instruction, value] 문 생성.
        pub fn buildInstructionReturn(self: *Transformer, instruction: u32, value: NodeIndex, span: Span) Transformer.Error!NodeIndex {
            const inst_node = try es_helpers.makeNumericLiteral(self, instruction);

            const arr_items = if (!value.isNone())
                try self.ast.addNodeList(&.{ inst_node, value })
            else
                try self.ast.addNodeList(&.{inst_node});

            const arr = try self.ast.addNode(.{
                .tag = .array_expression,
                .span = span,
                .data = .{ .list = arr_items },
            });

            return self.ast.addNode(.{
                .tag = .return_statement,
                .span = span,
                .data = .{ .unary = .{ .operand = arr, .flags = 0 } },
            });
        }

        /// _state.sent() 호출 생성.
        fn buildSentCall(self: *Transformer, span: Span) Transformer.Error!NodeIndex {
            const state_ref = try makeGeneratorStateRef(self);
            const sent_prop = try es_helpers.makePropertyName(self, "sent");
            const sent_member = try es_helpers.makeStaticMember(self, state_ref, sent_prop, span);
            return es_helpers.makeCallExpr(self, sent_member, &.{}, span);
        }

        /// _state.sent(); expression_statement 생성.
        /// yield resume 시 throw된 에러를 발생시키기 위해 필요.
        fn buildSentExprStmt(self: *Transformer, span: Span) Transformer.Error!NodeIndex {
            const sent = try buildSentCall(self, span);
            return es_helpers.makeExprStmt(self, sent, span);
        }

        fn makeTrackedGeneratorTempRef(self: *Transformer, name_span: Span, flags: @import("../semantic/symbol.zig").ReferenceFlags) Transformer.Error!NodeIndex {
            const ref = try es_helpers.makeTempVarRef(self, name_span, name_span);
            try self.trackHoistedTempRef(name_span, ref, flags);
            return ref;
        }

        /// _state identifier reference 생성.
        fn buildStateRef(self: *Transformer, _: Span) Transformer.Error!NodeIndex {
            return makeGeneratorStateRef(self);
        }

        fn makeGeneratorStateRef(self: *Transformer) Transformer.Error!NodeIndex {
            const name_span = try generatorStateNameSpan(self);
            const ref = try es_helpers.makeExactSyntheticRefFromSpan(self, name_span);
            try self.generator_state_refs.append(self.allocator, ref);
            return ref;
        }

        fn generatorStateNameSpan(self: *Transformer) Transformer.Error!Span {
            if (self.generator_state_name_span) |span| return span;
            const name = if (es_helpers.canUseLateStandaloneOutputName(self, self.generator_state_output_scope))
                try es_helpers.deferSyntheticOutputName(self, "_state")
            else
                try es_helpers.resolveSyntheticNameAvoidingDynamicEval(self, "_state", self.generator_state_output_scope);
            const span = try self.ast.addString(name);
            self.generator_state_name_span = span;
            return span;
        }

        fn makeGeneratorStateBinding(self: *Transformer) Transformer.Error!NodeIndex {
            return es_helpers.makeExactSyntheticBindingFromSpan(self, try generatorStateNameSpan(self));
        }

        const BoundGeneratorTransfer = struct { proof: @import("../semantic/generator_environment_transfer.zig").Transfer, heritages: []const @import("../semantic/generator_environment_transfer.zig").HeritageRead };
        pub fn captureGeneratorSource(self: *Transformer, owner: NodeIndex) Transformer.Error!?@import("../semantic/generator_environment_transfer.zig").Capture {
            if (!self.semantic_edit_enabled) return null;
            const source = if (self.extracted_loop_generator_sources.fetchRemove(@backingInt(owner))) |known|
                known.value
            else
                @import("../semantic/generator_environment_transfer.zig").capture(self.ast, owner, self.scope_history) orelse return null;
            return try @import("../semantic/generator_environment_transfer.zig").captureHeritages(self.allocator, self.ast, self.scope_history, source, self.symbol_ids.items, self.unresolved_reference_nodes);
        }

        fn generatorTransfer(self: *Transformer, source: ?@import("../semantic/generator_environment_transfer.zig").Capture, gen: GeneratorCall) ?BoundGeneratorTransfer {
            const before = source orelse return null;
            const editor = &self.semantic_editor.?;
            const callback_scope = self.outputOwnedScope(gen.callback) orelse return null;
            const history: @import("../semantic/scope_frame_history.zig").History = .{ .source_scopes = editor.scope_history.source_scopes, .source_owners = editor.scope_history.source_owners, .source_initializers = editor.scope_history.source_initializers, .source_computed_awaits = editor.scope_history.source_computed_awaits, .worklet_class_creators = editor.scope_history.worklet_class_creators.items, .lowered_worklet_classes = editor.scope_history.lowered_worklet_classes.items, .source_class_keys = editor.scope_history.source_class_keys, .events = editor.scope_history.events.items };
            const completed = @import("../semantic/generator_environment_transfer.zig").completed(self.ast, before.source, gen.callback, callback_scope, gen.state_param, history) orelse return null;
            return .{ .proof = completed, .heritages = before.heritages };
        }

        pub const GeneratorCall = struct {
            call: NodeIndex,
            callback: NodeIndex,
            state_param: NodeIndex,
            helper_ref: NodeIndex,
        };

        /// The async helper receives a real function wrapper. Its body contains
        /// the `__generator` call, and its child callback owns `_state`.
        pub fn bindWrappedStateMachine(self: *Transformer, source_owner: NodeIndex, wrapper: NodeIndex, gen: GeneratorCall, frame: *const StateMachineFrame, wrapper_temps: []const HoistedStateTemp, span: Span, source_boundary: ?@import("../semantic/generator_environment_transfer.zig").Capture) Transformer.Error!void {
            const parent = self.stateMachineOwnerScope(source_owner);
            if (parent.isNone()) {
                try self.bindGeneratedState(.none, .none, gen.callback, gen.state_param, frame.state_ref_start, wrapper_temps, frame.callback_temps.items, span);
                if (self.semantic_edit_enabled) try moveCaseReferences(self, gen.callback, self.outputOwnedScope(gen.callback) orelse @panic("generator callback has no actual ScopeId"), generatorTransfer(self, source_boundary, gen));
                return;
            }
            const wrapper_scope = try self.addGeneratedFunctionScope(parent, wrapper);
            try self.relocateRuntimeHelperRef(gen.helper_ref, wrapper_scope);
            try self.bindGeneratedState(wrapper_scope, parent, gen.callback, gen.state_param, frame.state_ref_start, wrapper_temps, frame.callback_temps.items, span);
            if (self.semantic_edit_enabled) try moveCaseReferences(self, gen.callback, self.outputOwnedScope(gen.callback) orelse @panic("generator callback has no actual ScopeId"), generatorTransfer(self, source_boundary, gen));
        }

        /// __generator(function(_state) { ... }) 호출 생성.
        /// es2017 결합 변환에서도 호출.
        /// __generator(body) 또는 __generator(body, genFn) 호출을 생성.
        /// genFn_idx가 .none이 아니면 프로토타입 체인 설정을 위해 두 번째 인자로 전달.
        pub fn buildGeneratorHelperCall(self: *Transformer, switch_body: NodeIndex, span: Span) Transformer.Error!GeneratorCall {
            return buildGeneratorHelperCallWithProto(self, switch_body, .none, span);
        }

        pub fn buildGeneratorHelperCallWithProto(self: *Transformer, switch_body: NodeIndex, genFn_idx: NodeIndex, span: Span) Transformer.Error!GeneratorCall {
            self.runtime_helpers.generator = true;

            // _state 파라미터
            const state_param = try makeGeneratorStateBinding(self);

            // function body: switch_body를 block으로 감싸기
            const body_list = try self.ast.addNodeList(&.{switch_body});
            const body = try self.ast.addNode(.{
                .tag = .block_statement,
                .span = span,
                .data = .{ .list = body_list },
            });

            // function(_state) { ... }
            const params = try self.ast.addNodeList(&.{state_param});
            const none = @backingInt(NodeIndex.none);
            const params_node_g = try self.ast.addFormalParameters(params, .{ .start = 0, .end = 0 });
            const func_extra = try self.ast.addExtras(&.{
                none, // anonymous
                @backingInt(params_node_g),
                @backingInt(body),
                0, // flags
                none,
            });
            const func_expr = try self.ast.addNode(.{
                .tag = .function_expression,
                .span = span,
                .data = .{ .extra = func_extra },
            });

            // __generator(this, func) 또는 __generator(this, func, genFn) — (#1909)
            // body 안 `this` 가 enclosing function 의 this 가 되도록 thisArg 첫 인자 전달.
            const gen_ref = try es_helpers.makeRuntimeHelperRef(self, "__generator");
            const this_arg = try es_helpers.makeThisExpr(self, span);
            if (!genFn_idx.isNone()) {
                return .{ .call = try es_helpers.makeCallExpr(self, gen_ref, &.{ this_arg, func_expr, genFn_idx }, span), .callback = func_expr, .state_param = state_param, .helper_ref = gen_ref };
            }
            return .{ .call = try es_helpers.makeCallExpr(self, gen_ref, &.{ this_arg, func_expr }, span), .callback = func_expr, .state_param = state_param, .helper_ref = gen_ref };
        }
    };
}

test "ES2015 generator module compiles" {
    _ = ES2015Generator;
}

fn checkGeneratorTempProducerFixture(source: []const u8, require_extracted_loop_producer: bool) !void {
    const Transformer = @import("transformer.zig").Transformer;
    const SemanticAnalyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer;
    const TransformOptions = @import("options.zig").TransformOptions;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var scanner = try Scanner.init(allocator, source);
    var parser = Parser.init(allocator, &scanner);
    parser.configureFromExtension(".mjs");
    _ = try parser.parse();
    try std.testing.expectEqual(@as(usize, 0), parser.errors.items.len);

    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    analyzer.is_module = true;
    try analyzer.analyze();
    try std.testing.expectEqual(@as(usize, 0), analyzer.errors.items.len);

    var transformer = try Transformer.init(allocator, &parser.ast, .{
        .unsupported = TransformOptions.compat.fromESTarget(.es5),
    });
    try transformer.initSymbolIds(analyzer.symbol_ids.items);
    transformer.symbols = analyzer.symbols.items;
    transformer.class_self_symbol_map = analyzer.class_self_symbol_map;
    transformer.references = analyzer.references.items;
    transformer.scopes = analyzer.scopes.items;
    transformer.scope_maps = analyzer.scope_maps.items;
    transformer.scope_owner_map = analyzer.scope_owner_map;
    transformer.node_scope_provenance = analyzer.node_scope_provenance;
    transformer.unresolved_references = &analyzer.unresolved_references;
    transformer.semantic_edit_enabled = true;

    const Generator = ES2015Generator(Transformer);
    const original_node_count = transformer.ast.nodes.items.len;
    var generator_count: usize = 0;
    var direct_producer_count: usize = 0;
    var extracted_loop_producer_count: usize = 0;
    for (transformer.ast.nodes.items[0..original_node_count], 0..) |node, raw| {
        if (node.tag != .function_declaration and node.tag != .function_expression) continue;
        const extra = node.data.extra;
        const flags = transformer.readU32(extra, ast_mod.FunctionExtra.flags);
        if (flags & ast_mod.FunctionFlags.is_generator == 0) continue;
        const owner_raw = analyzer.scope_owner_map.get(@intCast(raw)) orelse
            return error.MissingGeneratorProducerOwner;
        const owner_scope: ScopeId = @fromBackingInt(@intCast(owner_raw));
        const body = transformer.readNodeIdx(extra, ast_mod.FunctionExtra.body);
        if (body.isNone()) return error.MissingGeneratorProducerBody;
        const saved_async_generator = transformer.in_async_generator_body;
        transformer.in_async_generator_body = flags & ast_mod.FunctionFlags.is_async != 0;
        transformer.current_scope = owner_scope;

        var frame = try Generator.enterStateMachineTempsForScope(&transformer, owner_scope);
        var frame_active = true;
        defer if (frame_active) Generator.leaveStateMachineTemps(&transformer, &frame);
        var result = try Generator.buildStateMachine(&transformer, body, node.span, owner_scope);
        defer result.hoisted_temps.deinit(allocator);
        try std.testing.expect(!result.body.isNone());
        try std.testing.expectEqual(
            transformer.generator_temp_var_spans.items.len,
            transformer.generator_temp_producer_identities.items.len,
        );
        generator_count += 1;

        for (transformer.generator_temp_producer_identities.items, 0..) |identity, identity_index| {
            const producer_name = transformer.ast.getText(transformer.generator_temp_var_spans.items[identity_index]);
            if ((std.mem.startsWith(u8, producer_name, "_ret") or
                std.mem.startsWith(u8, producer_name, "__zntc_loop_ret")) and
                identity.source_binding.isNone() and identity.symbol_id != null)
            {
                const binding = identity.binding;
                if (binding.isNone()) return error.MissingLoopReturnProducerBindingHandle;
                try std.testing.expectEqual(@as(?u32, identity.symbol_id.?), transformer.getSymbolIdAt(binding));
                try std.testing.expectEqual(ast_mod.Node.Tag.binding_identifier, transformer.ast.getNode(binding).tag);
            }
            if (!identity.producer_owned) continue;
            direct_producer_count += 1;
            if (std.mem.startsWith(u8, producer_name, "_loop") or
                std.mem.startsWith(u8, producer_name, "__zntc_loop"))
            {
                extracted_loop_producer_count += 1;
                const origin = identity.source_binding;
                if (origin.isNone()) return error.MissingExtractedLoopBindingHandle;
                try std.testing.expectEqual(identity.symbol_id, transformer.getSymbolIdAt(origin));
            }
            const raw_id = identity.symbol_id orelse return error.MissingGeneratorProducerSymbolId;
            try std.testing.expectEqual(owner_scope, identity.owner_scope);
            if (identity.temp_producer_id) |producer_id| {
                try std.testing.expect(producer_id != 0);
                try std.testing.expectEqual(
                    @as(?u32, raw_id),
                    transformer.temp_symbols_by_producer_id.get(producer_id),
                );
            }
            const editor = if (transformer.semantic_editor) |*value| value else return error.MissingGeneratorProducerEditor;
            try std.testing.expect(raw_id < editor.symbols.items.len);
            const symbol = editor.symbols.items[raw_id];
            try std.testing.expectEqual(owner_scope, symbol.scope_id);
            try std.testing.expectEqual(@import("../semantic/symbol.zig").SymbolKind.variable_var, symbol.kind);

            var binding_matches: usize = 0;
            for (result.hoisted_temps.items) |temp| {
                if (temp.symbol_id != raw_id) continue;
                binding_matches += 1;
                try std.testing.expectEqual(@as(?u32, raw_id), transformer.getSymbolIdAt(temp.binding));
                try std.testing.expectEqual(identity.owner_scope, temp.owner_scope);
                if (identity.temp_producer_id != null)
                    try std.testing.expectEqual(identity.temp_producer_id, temp.temp_producer_id);
            }
            try std.testing.expectEqual(@as(usize, 1), binding_matches);

            var reads: usize = 0;
            var writes: usize = 0;
            for (transformer.generator_state_semantic_refs.items) |reference| {
                if (reference.symbol_id != raw_id) continue;
                try std.testing.expectEqual(@as(?u32, raw_id), transformer.getSymbolIdAt(reference.node));
                if (reference.flags.read) reads += 1;
                if (reference.flags.write) writes += 1;
            }
            try std.testing.expect(reads > 0 or writes > 0);
        }

        frame_active = false;
        Generator.leaveStateMachineTemps(&transformer, &frame);
        transformer.in_async_generator_body = saved_async_generator;
    }
    try std.testing.expect(generator_count > 0);
    try std.testing.expect(direct_producer_count > 0);
    if (require_extracted_loop_producer) try std.testing.expect(extracted_loop_producer_count > 0);
}

fn checkGeneratorAssignmentBindingIdentity(source: []const u8) !void {
    const Transformer = @import("transformer.zig").Transformer;
    const SemanticAnalyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer;
    const TransformOptions = @import("options.zig").TransformOptions;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var scanner = try Scanner.init(allocator, source);
    var parser = Parser.init(allocator, &scanner);
    parser.configureFromExtension(".mjs");
    _ = try parser.parse();
    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    analyzer.is_module = true;
    try analyzer.analyze();

    var transformer = try Transformer.init(allocator, &parser.ast, .{
        .unsupported = TransformOptions.compat.fromESTarget(.es5),
    });
    try transformer.initSymbolIds(analyzer.symbol_ids.items);
    transformer.symbols = analyzer.symbols.items;
    transformer.class_self_symbol_map = analyzer.class_self_symbol_map;
    transformer.references = analyzer.references.items;
    transformer.scopes = analyzer.scopes.items;
    transformer.scope_maps = analyzer.scope_maps.items;
    transformer.scope_owner_map = analyzer.scope_owner_map;
    transformer.node_scope_provenance = analyzer.node_scope_provenance;
    transformer.unresolved_references = &analyzer.unresolved_references;
    transformer.semantic_edit_enabled = true;

    var owner_scope: ?ScopeId = null;
    for (transformer.ast.nodes.items, 0..) |node, raw| {
        if (node.tag != .function_declaration) continue;
        const flags = transformer.readU32(node.data.extra, ast_mod.FunctionExtra.flags);
        if (flags & ast_mod.FunctionFlags.is_generator == 0) continue;
        const raw_scope = analyzer.scope_owner_map.get(@intCast(raw)) orelse continue;
        owner_scope = @fromBackingInt(@intCast(raw_scope));
        break;
    }
    const generator_scope = owner_scope orelse return error.MissingGeneratorAssignmentOwner;
    transformer.generator_state_machine_scope = transformer.nearestVarScope(generator_scope);
    var reference_scope = generator_scope;
    for (analyzer.scopes.items, 0..) |scope, raw_scope| {
        if (scope.parent != generator_scope or scope.kind.isVarScope()) continue;
        reference_scope = @fromBackingInt(@intCast(raw_scope));
        break;
    }
    transformer.current_scope = reference_scope;
    transformer.state_machine_depth = 1;

    const name_span = try es_helpers.makeTempVarSpan(&transformer);
    const binding = try es_helpers.makeSyntheticBinding(&transformer, name_span);
    const reference = try ES2015Generator(Transformer).bindingToAssignTarget(&transformer, binding);
    const symbol_id = transformer.getSymbolIdAt(binding) orelse return error.MissingGeneratorAssignmentSymbol;
    try std.testing.expectEqual(@as(?u32, symbol_id), transformer.getSymbolIdAt(reference));
    try std.testing.expectEqual(@as(usize, 1), transformer.generator_state_semantic_refs.items.len);
    const pending = transformer.generator_state_semantic_refs.items[0];
    try std.testing.expectEqual(symbol_id, pending.symbol_id);
    try std.testing.expectEqual(reference_scope, pending.scope);
    try std.testing.expect(pending.flags.write);
    const editor = if (transformer.semantic_editor) |*value| value else return error.MissingGeneratorAssignmentEditor;
    const raw_symbol_id: usize = @intCast(symbol_id);
    try std.testing.expect(raw_symbol_id < editor.symbols.items.len);
    try std.testing.expectEqual(transformer.generator_state_machine_scope, editor.symbols.items[raw_symbol_id].scope_id);

    _ = try ES2015Generator(Transformer).registerGeneratorVar(&transformer, name_span, binding);
    const producer_index = transformer.generator_temp_producer_identities.items.len - 1;
    const producer = transformer.generator_temp_producer_identities.items[producer_index];
    try std.testing.expectEqual(binding, producer.source_binding);
    transformer.forgetSyntheticTempSymbolLookup(name_span, transformer.generator_state_machine_scope);

    var state_temps: std.ArrayListUnmanaged(@import("transformer/lists.zig").HoistedStateTemp) = .empty;
    _ = try ES2015Generator(Transformer).buildHoistedVarDecl(
        &transformer,
        &.{},
        .EMPTY,
        &state_temps,
        transformer.generator_state_machine_scope,
    );
    var matched = false;
    for (state_temps.items) |temp| {
        if (temp.name_span.start != name_span.start or temp.name_span.end != name_span.end) continue;
        matched = true;
        try std.testing.expectEqual(@as(?u32, symbol_id), temp.symbol_id);
        try std.testing.expectEqual(@as(?u32, symbol_id), transformer.getSymbolIdAt(temp.binding));
        try std.testing.expectEqual(transformer.generator_state_machine_scope, temp.owner_scope);
    }
    try std.testing.expect(matched);
}

fn checkGeneratorHoistProducerUsesExactBindingHandle(
    source: []const u8,
    anchor: []const u8,
    prefix_count: usize,
    producer_slot: usize,
) !void {
    const Transformer = @import("transformer.zig").Transformer;
    const SemanticAnalyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer;
    const TransformOptions = @import("options.zig").TransformOptions;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var scanner = try Scanner.init(allocator, source);
    var parser = Parser.init(allocator, &scanner);
    parser.configureFromExtension(".mjs");
    _ = try parser.parse();
    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    analyzer.is_module = true;
    try analyzer.analyze();

    var transformer = try Transformer.init(allocator, &parser.ast, .{
        .unsupported = TransformOptions.compat.fromESTarget(.es5),
    });
    try transformer.initSymbolIds(analyzer.symbol_ids.items);
    transformer.symbols = analyzer.symbols.items;
    transformer.class_self_symbol_map = analyzer.class_self_symbol_map;
    transformer.references = analyzer.references.items;
    transformer.scopes = analyzer.scopes.items;
    transformer.scope_maps = analyzer.scope_maps.items;
    transformer.scope_owner_map = analyzer.scope_owner_map;
    transformer.node_scope_provenance = analyzer.node_scope_provenance;
    transformer.unresolved_references = &analyzer.unresolved_references;
    transformer.semantic_edit_enabled = true;

    var generator_scope: ?ScopeId = null;
    for (transformer.ast.nodes.items, 0..) |node, raw| {
        if (node.tag != .function_declaration) continue;
        const flags = transformer.readU32(node.data.extra, ast_mod.FunctionExtra.flags);
        if (flags & ast_mod.FunctionFlags.is_generator == 0) continue;
        const raw_scope = analyzer.scope_owner_map.get(@intCast(raw)) orelse continue;
        generator_scope = @fromBackingInt(@intCast(raw_scope));
        break;
    }
    const owner_scope = generator_scope orelse return error.MissingGeneratorHoistOwner;
    transformer.generator_state_machine_scope = transformer.nearestVarScope(owner_scope);
    transformer.current_scope = owner_scope;
    transformer.state_machine_depth = 1;

    if (std.mem.indexOf(u8, source, anchor) == null) return error.MissingGeneratorHoistAnchor;
    const full_name_span = try transformer.ast.addString(anchor);
    const raw_start = full_name_span.start & ~ast_mod.Ast.STRING_TABLE_BIT;
    const name_start = raw_start | ast_mod.Ast.STRING_TABLE_BIT;
    const producer_span = Span{ .start = name_start, .end = (raw_start + 1) | ast_mod.Ast.STRING_TABLE_BIT };
    const producer_binding = try es_helpers.makeExactSyntheticBindingFromSpan(&transformer, producer_span);
    const producer_index = try ES2015Generator(Transformer).registerGeneratorVar(&transformer, producer_span, producer_binding);
    try std.testing.expectEqual(producer_binding, transformer.generator_temp_producer_identities.items[producer_index].binding);

    var hoisted_bindings = try allocator.alloc(NodeIndex, prefix_count);
    hoisted_bindings[producer_slot] = producer_binding;
    var prefix_len: usize = 2;
    for (0..prefix_count) |slot| {
        if (slot == producer_slot) continue;
        const decoy_span = Span{ .start = name_start, .end = (raw_start + @as(u32, @intCast(prefix_len))) | ast_mod.Ast.STRING_TABLE_BIT };
        const decoy_symbol = (try transformer.reserveSyntheticTempSymbolForProducerInScope(@intCast(slot + 100), decoy_span, .EMPTY, owner_scope)).?;
        hoisted_bindings[slot] = (try transformer.createSyntheticTempBindingWithIdentity(decoy_span, owner_scope, decoy_symbol)).node;
        prefix_len += 1;
    }

    var state_temps: std.ArrayListUnmanaged(@import("transformer/lists.zig").HoistedStateTemp) = .empty;
    const hoisted_decl = try ES2015Generator(Transformer).buildHoistedVarDecl(
        &transformer,
        hoisted_bindings,
        .EMPTY,
        &state_temps,
        transformer.generator_state_machine_scope,
    );
    try std.testing.expect(!hoisted_decl.isNone());
    try std.testing.expectEqual(@as(usize, 1), transformer.generator_state_bindings.items.len);
    const state_binding = transformer.generator_state_bindings.items[0];
    try std.testing.expectEqual(producer_binding, state_binding.binding);
    try std.testing.expectEqual(transformer.generator_state_machine_scope, state_binding.owner_scope);
    try std.testing.expect(state_binding.symbol_id != null);

    transformer.generator_temp_var_spans.clearRetainingCapacity();
    transformer.generator_temp_producer_identities.clearRetainingCapacity();
    transformer.generator_state_bindings.clearRetainingCapacity();
    transformer.generated_temp_spans.clearRetainingCapacity();
    var id_binding: ?NodeIndex = null;
    for (transformer.ast.nodes.items, 0..) |node, raw| {
        if (node.tag != .binding_identifier) continue;
        if (!std.mem.eql(u8, transformer.ast.getText(node.data.string_ref), anchor)) continue;
        id_binding = @fromBackingInt(@intCast(raw));
        break;
    }
    const source_binding = id_binding orelse return error.MissingGeneratorHoistSourceBinding;
    const source_symbol_raw = transformer.getSymbolIdAt(source_binding) orelse return error.MissingGeneratorHoistSourceSymbol;
    const source_symbol: SymbolId = @fromBackingInt(@intCast(source_symbol_raw));
    const source_name_span = transformer.ast.getNode(source_binding).data.string_ref;
    try ES2015Generator(Transformer).appendGeneratorTempSpanWithIdentity(
        &transformer,
        source_name_span,
        source_symbol,
        transformer.generator_state_machine_scope,
    );
    var id_state_temps: std.ArrayListUnmanaged(@import("transformer/lists.zig").HoistedStateTemp) = .empty;
    _ = try ES2015Generator(Transformer).buildHoistedVarDecl(
        &transformer,
        &.{source_binding},
        .EMPTY,
        &id_state_temps,
        transformer.generator_state_machine_scope,
    );
    try std.testing.expectEqual(@as(usize, 1), transformer.generator_state_bindings.items.len);
    try std.testing.expectEqual(source_binding, transformer.generator_state_bindings.items[0].binding);
    try std.testing.expectEqual(@as(?u32, @backingInt(source_symbol)), transformer.generator_state_bindings.items[0].symbol_id);

    transformer.generator_temp_var_spans.clearRetainingCapacity();
    transformer.generator_temp_producer_identities.clearRetainingCapacity();
    transformer.generator_state_bindings.clearRetainingCapacity();
    transformer.generated_temp_spans.clearRetainingCapacity();
    _ = try ES2015Generator(Transformer).registerGeneratorVar(&transformer, source_name_span, source_binding);
    var source_state_temps: std.ArrayListUnmanaged(@import("transformer/lists.zig").HoistedStateTemp) = .empty;
    _ = try ES2015Generator(Transformer).buildHoistedVarDecl(
        &transformer,
        &.{source_binding},
        .EMPTY,
        &source_state_temps,
        transformer.generator_state_machine_scope,
    );
    try std.testing.expectEqual(@as(usize, 0), transformer.generator_state_bindings.items.len);
    try std.testing.expectEqual(@as(usize, 0), source_state_temps.items.len);
    try std.testing.expect(!hoisted_decl.isNone());

    transformer.generator_temp_var_spans.clearRetainingCapacity();
    transformer.generator_temp_producer_identities.clearRetainingCapacity();
    transformer.generator_state_bindings.clearRetainingCapacity();
    transformer.generated_temp_spans.clearRetainingCapacity();
    const generated_name = try std.fmt.allocPrint(allocator, "generated_{s}", .{anchor});
    const generated_name_span = try transformer.ast.addString(generated_name);
    const generated_binding = try es_helpers.makeExactSyntheticBindingFromSpan(&transformer, generated_name_span);
    const generated_symbol = try transformer.declareSyntheticTempInScope(
        generated_binding,
        .EMPTY,
        transformer.generator_state_machine_scope,
    ) orelse return error.MissingGeneratorHoistGeneratedSymbol;
    try ES2015Generator(Transformer).appendGeneratorTempSpanWithIdentity(
        &transformer,
        generated_name_span,
        generated_symbol,
        transformer.generator_state_machine_scope,
    );
    var generated_state_temps: std.ArrayListUnmanaged(@import("transformer/lists.zig").HoistedStateTemp) = .empty;
    const generated_decl = try ES2015Generator(Transformer).buildHoistedVarDecl(
        &transformer,
        &.{generated_binding},
        .EMPTY,
        &generated_state_temps,
        transformer.generator_state_machine_scope,
    );
    try std.testing.expect(!generated_decl.isNone());
    try std.testing.expectEqual(@as(usize, 1), transformer.generator_state_bindings.items.len);
    try std.testing.expectEqual(generated_binding, transformer.generator_state_bindings.items[0].binding);
    try std.testing.expectEqual(
        @as(?u32, @backingInt(generated_symbol)),
        transformer.generator_state_bindings.items[0].symbol_id,
    );
}

test "generator hoist producer association uses exact binding handles" {
    const hostile = [_]struct { anchor: []const u8, prefix_count: usize, producer_slot: usize }{
        .{ .anchor = "alphaNumericIdentifier", .prefix_count = 5, .producer_slot = 0 },
        .{ .anchor = "brightHueIdentifier", .prefix_count = 6, .producer_slot = 1 },
        .{ .anchor = "crystalGammaIdentifier", .prefix_count = 7, .producer_slot = 2 },
        .{ .anchor = "deltaHotelIdentifier", .prefix_count = 8, .producer_slot = 3 },
        .{ .anchor = "emberIndiaIdentifier", .prefix_count = 5, .producer_slot = 4 },
        .{ .anchor = "forestJulietIdentifier", .prefix_count = 6, .producer_slot = 5 },
        .{ .anchor = "gentleKiloIdentifier", .prefix_count = 7, .producer_slot = 6 },
        .{ .anchor = "harborLimaIdentifier", .prefix_count = 8, .producer_slot = 7 },
        .{ .anchor = "indigoMountainIdentifier", .prefix_count = 5, .producer_slot = 2 },
        .{ .anchor = "jasmineFlowerIdentifier", .prefix_count = 6, .producer_slot = 4 },
    };
    for (hostile) |case| {
        const source = try std.fmt.allocPrint(
            std.testing.allocator,
            "function* g() {{ var {s} = 0; yield 0; }}",
            .{case.anchor},
        );
        defer std.testing.allocator.free(source);
        try checkGeneratorHoistProducerUsesExactBindingHandle(
            source,
            case.anchor,
            case.prefix_count,
            case.producer_slot,
        );
    }
}

test "generator assignment bindings retain producer identity without span lookup" {
    const hostile_sources = [_][]const u8{
        "function* g(){ yield 0; }",
        "function* g(){ const _a = 1; yield _a; }",
        "function* g(){ let _loop = 2; yield _loop; }",
        "function* g(){ { let _a = 1; yield _a; } }",
        "function* g(){ if (true) { let _loop = 2; yield _loop; } }",
        "function* g(){ for (let i = 0; i < 3; i++) yield i; }",
        "function* g(items){ for (const item of items) yield item; }",
        "function* g(items){ for (const item in items) yield item; }",
        "function* g(){ outer: for (let i = 0; i < 3; i++) { if (i) continue outer; yield i; } }",
        "async function* g(items){ for await (const item of items) yield item; }",
    };
    for (hostile_sources) |source| try checkGeneratorAssignmentBindingIdentity(source);
}

test "#4819 deferred generator temp identity bypasses the span registry" {
    const Transformer = @import("transformer.zig").Transformer;
    const SemanticAnalyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer;
    const TransformOptions = @import("options.zig").TransformOptions;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var scanner = try Scanner.init(allocator, "function* g(){ yield 1; }");
    var parser = Parser.init(allocator, &scanner);
    parser.configureFromExtension(".mjs");
    _ = try parser.parse();
    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    try analyzer.analyze();

    var transformer = try Transformer.init(allocator, &parser.ast, .{
        .unsupported = TransformOptions.compat.fromESTarget(.es5),
    });
    try transformer.initSymbolIds(analyzer.symbol_ids.items);
    transformer.symbols = analyzer.symbols.items;
    transformer.references = analyzer.references.items;
    transformer.scopes = analyzer.scopes.items;
    transformer.scope_maps = analyzer.scope_maps.items;
    transformer.scope_owner_map = analyzer.scope_owner_map;
    transformer.node_scope_provenance = analyzer.node_scope_provenance;
    transformer.unresolved_references = &analyzer.unresolved_references;
    transformer.semantic_edit_enabled = true;

    var wrapper_scope: ?ScopeId = null;
    var declaration_span: ?Span = null;
    for (transformer.ast.nodes.items, 0..) |node, raw| {
        if (node.tag != .function_declaration) continue;
        const flags = transformer.readU32(node.data.extra, ast_mod.FunctionExtra.flags);
        if (flags & ast_mod.FunctionFlags.is_generator == 0) continue;
        const owner = analyzer.scope_owner_map.get(@intCast(raw)) orelse return error.MissingDeferredGeneratorOwner;
        wrapper_scope = @fromBackingInt(@intCast(owner));
        declaration_span = node.span;
        break;
    }
    const callback_scope = wrapper_scope orelse return error.MissingDeferredGeneratorOwner;
    const declaration = declaration_span orelse return error.MissingDeferredGeneratorDeclaration;
    const source_scope = transformer.programScope();
    const name_span = try transformer.ast.addString("_ret_direct");
    const symbol_id = (try transformer.reserveSyntheticTempSymbolInScope(name_span, declaration, source_scope)) orelse
        return error.MissingDeferredGeneratorSymbol;

    transformer.generator_state_machine_scope = callback_scope;
    transformer.state_machine_depth = 1;
    const Generator = ES2015Generator(Transformer);
    try Generator.appendGeneratorTempSpanWithDeferredIdentity(
        &transformer,
        name_span,
        symbol_id,
        source_scope,
        callback_scope,
    );

    try std.testing.expectEqual(@as(usize, 1), transformer.generator_temp_var_spans.items.len);
    try std.testing.expectEqual(name_span.start, transformer.generator_temp_var_spans.items[0].start);
    try std.testing.expectEqual(name_span.end, transformer.generator_temp_var_spans.items[0].end);
    try std.testing.expectEqual(@as(usize, 1), transformer.generator_temp_producer_identities.items.len);
    const identity = transformer.generator_temp_producer_identities.items[0];
    try std.testing.expectEqual(@as(?u32, @backingInt(symbol_id)), identity.symbol_id);
    try std.testing.expectEqual(callback_scope, identity.owner_scope);
    try std.testing.expect(identity.producer_owned);
}

test "#4819 generator yield and branch temps keep producer IDs through hoisting" {
    const hostile_sources = [_][]const u8{
        "function* g(){ yield (yield 1) || 2; }",
        "function* g(){ yield (yield 1) && 2; }",
        "function* g(){ yield (yield 1) ?? 2; }",
        "function* g(){ yield (yield 1) ? 2 : 3; }",
        "function* g(){ yield ((yield 1) || (yield 2)); }",
        "function* g(){ try { yield (yield 1) ? (yield 2) : (yield 3); } catch ({ message }) { yield message; } }",
        "async function* g(){ yield await Promise.resolve((await Promise.resolve(1)) ?? 2); }",
        "function* g(){ let _a = 7; yield g2() ? (yield _a) : (yield 3); } function* g2(){ yield 1; }",
        "function* outer(){ yield (yield 1) ?? 2; function* inner(){ yield (yield 3) ? 4 : 5; } yield inner; }",
        "function* g(){ yield (yield 1) || (yield 2); eval(''); }",
    };
    for (hostile_sources) |source| try checkGeneratorTempProducerFixture(source, false);
}

test "#4819 extracted generator loop bindings carry producer IDs through hoisting" {
    const hostile_sources = [_][]const u8{
        "function* g(){ for(let i=0;i<3;i++){ yield (()=>i)(); } }",
        "function* g(){ outer: for(let i=0;i<3;i++){ yield (()=>i)(); if(i) break outer; continue outer; } }",
        "function* g(){ for(let i=0;i<3;i++){ yield (()=>i)(); if(i) return i; } }",
        "function* g(items){ for(let i of items){ yield (()=>i)(); if(i) break; } }",
        "function* g(items){ for(let i in items){ yield (()=>i)(); if(i) continue; } }",
        "function* g(){ outer: for(let i=0;i<3;i++){ for(let j=0;j<2;j++){ yield (()=>i+j)(); if(j) break outer; } } }",
        "function* g(){ for(let i=0;i<3;i++){ yield (()=>i)(); try { if(i) break; } finally { yield i; } } }",
        "function* g(){ for(let i=0;i<3;i++){ yield (()=>i)(); switch(i){ case 1: break; default: if(i) continue; } } }",
        "async function* g(items){ for await(let i of items){ yield (()=>i)(); if(i) break; } }",
        "async function* g(items){ outer: for await(let i of items){ yield (()=>i)(); if(i) break outer; } }",
    };
    for (hostile_sources) |source| try checkGeneratorTempProducerFixture(source, true);
}

fn checkGeneratorVarProducerHandleSelection() !void {
    const Transformer = @import("transformer.zig").Transformer;
    const SemanticAnalyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer;
    const TransformOptions = @import("options.zig").TransformOptions;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var scanner = try Scanner.init(allocator, "function* g(){ var first = 1, middle = 2, last = 3; var same = 4, other = 5, same = 6; yield 0; }");
    var parser = Parser.init(allocator, &scanner);
    parser.configureFromExtension(".mjs");
    _ = try parser.parse();
    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    analyzer.is_module = true;
    try analyzer.analyze();

    var transformer = try Transformer.init(allocator, &parser.ast, .{
        .unsupported = TransformOptions.compat.fromESTarget(.es5),
    });
    try transformer.initSymbolIds(analyzer.symbol_ids.items);
    transformer.symbols = analyzer.symbols.items;
    transformer.class_self_symbol_map = analyzer.class_self_symbol_map;
    transformer.references = analyzer.references.items;
    transformer.scopes = analyzer.scopes.items;
    transformer.scope_maps = analyzer.scope_maps.items;
    transformer.scope_owner_map = analyzer.scope_owner_map;
    transformer.node_scope_provenance = analyzer.node_scope_provenance;
    transformer.unresolved_references = &analyzer.unresolved_references;
    transformer.semantic_edit_enabled = true;

    var generator_scope: ?ScopeId = null;
    for (transformer.ast.nodes.items, 0..) |node, raw| {
        if (node.tag != .function_declaration) continue;
        const flags = transformer.readU32(node.data.extra, ast_mod.FunctionExtra.flags);
        if (flags & ast_mod.FunctionFlags.is_generator == 0) continue;
        const owner_raw = analyzer.scope_owner_map.get(@intCast(raw)) orelse continue;
        generator_scope = @fromBackingInt(@intCast(owner_raw));
        break;
    }
    const owner_scope = generator_scope orelse return error.MissingGeneratorProducerHandleOwner;
    transformer.current_scope = owner_scope;
    transformer.generator_state_machine_scope = transformer.nearestVarScope(owner_scope);
    transformer.state_machine_depth = 1;

    var ops: std.ArrayList(Operation) = .empty;
    defer ops.deinit(allocator);
    var next_label: u32 = 1;
    var declarations_seen: usize = 0;
    for (transformer.ast.nodes.items) |node| {
        if (node.tag != .variable_declaration) continue;
        const list_start = transformer.readU32(node.data.extra, 1);
        const list_len = transformer.readU32(node.data.extra, 2);
        if (list_len != 3) continue;
        var bindings: [3]NodeIndex = undefined;
        for (0..3) |index| {
            const decl = transformer.ast.getNode(@fromBackingInt(@intCast(transformer.ast.extra_data.items[list_start + index])));
            if (decl.tag != .variable_declarator) return error.UnexpectedGeneratorProducerDeclarator;
            bindings[index] = transformer.readNodeIdx(decl.data.extra, 0);
        }
        const first_name = transformer.ast.getText(transformer.ast.getNode(bindings[0]).span);
        const target_binding: NodeIndex = if (std.mem.eql(u8, first_name, "first")) blk: {
            if (!std.mem.eql(u8, transformer.ast.getText(transformer.ast.getNode(bindings[1]).span), "middle"))
                return error.MissingMiddleGeneratorProducerBinding;
            break :blk bindings[1];
        } else if (std.mem.eql(u8, first_name, "same")) blk: {
            if (!std.mem.eql(u8, transformer.ast.getText(transformer.ast.getNode(bindings[2]).span), "same"))
                return error.MissingRepeatedGeneratorProducerBinding;
            break :blk bindings[2];
        } else continue;

        const expected_index: usize = if (declarations_seen == 0) 1 else 5;
        const producer_index = (try ES2015Generator(Transformer).collectVarDeclWithYield(
            &transformer,
            node,
            &ops,
            &next_label,
            target_binding,
        )) orelse return error.MissingGeneratorProducerHandle;
        try std.testing.expectEqual(expected_index, producer_index);
        try std.testing.expectEqual(target_binding, transformer.generator_temp_producer_identities.items[producer_index].source_binding);
        try std.testing.expectEqual(transformer.generator_temp_var_spans.items.len, transformer.generator_temp_producer_identities.items.len);
        declarations_seen += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), declarations_seen);
    const repeated_id = transformer.getSymbolIdAt(transformer.generator_temp_producer_identities.items[3].source_binding) orelse
        return error.MissingFirstRepeatedGeneratorSymbol;
    try std.testing.expectEqual(
        @as(?u32, repeated_id),
        transformer.getSymbolIdAt(transformer.generator_temp_producer_identities.items[5].source_binding),
    );
}

test "generator var producer handle returns the exact binding record" {
    try checkGeneratorVarProducerHandleSelection();
}

test "#4819 extracted generator loop producer handles survive hostile nesting" {
    const hostile_sources = [_][]const u8{
        "function* g(){ for(let index=0;index<3;index++){ var before=index, after=index+1; yield (()=>index)(); } }",
        "function* g(){ outer: for(let i=0;i<2;i++){ var before=i; for(let j=0;j<2;j++){ var after=j; yield (()=>i+j)(); if(j) continue outer; } } }",
        "function* g(items){ for(let item of items){ var first=item, second=item+1; yield (()=>item)(); } }",
        "function* g(items){ for(let key in items){ var first=key, second=key+1; yield (()=>key)(); } }",
        "function* g(){ for(let i=0;i<3;i++){ var before=i, after=i+1; yield (()=>i)(); if(i===2) break; } }",
        "function* g(){ for(let i=0;i<3;i++){ var before=i, after=i+1; yield (()=>i)(); if(i===1) continue; } }",
        "function* g(){ for(let i=0;i<3;i++){ var first=i, second=i+1; try { yield (()=>i)(); } finally { if(i===2) break; } } }",
        "function* g(){ outer: for(let i=0;i<3;i++){ var first=i, second=i+1; switch(i){ case 1: continue outer; default: yield (()=>i)(); } } }",
        "function* g(){ for(let i=0;i<2;i++){ var before=i, after=i+1; function* inner(){ yield i; } yield inner; } }",
        "async function* g(items){ for await(let item of items){ var before=item, after=item; yield (()=>item)(); if(item) break; } }",
    };
    for (hostile_sources) |source| try checkGeneratorTempProducerFixture(source, true);
}

test "#4819 generator state temp producers attach their SymbolIds immediately" {
    const Transformer = @import("transformer.zig").Transformer;
    const SemanticAnalyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer;
    const TransformOptions = @import("options.zig").TransformOptions;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var scanner = try Scanner.init(allocator, "var origin = 1; 1;");
    var parser = Parser.init(allocator, &scanner);
    _ = try parser.parse();
    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    try analyzer.analyze();

    var transformer = try Transformer.init(allocator, &parser.ast, .{
        .unsupported = TransformOptions.compat.fromESTarget(.es5),
    });
    try transformer.initSymbolIds(analyzer.symbol_ids.items);
    transformer.symbols = analyzer.symbols.items;
    transformer.class_self_symbol_map = analyzer.class_self_symbol_map;
    transformer.references = analyzer.references.items;
    transformer.scopes = analyzer.scopes.items;
    transformer.scope_maps = analyzer.scope_maps.items;
    transformer.scope_owner_map = analyzer.scope_owner_map;
    transformer.node_scope_provenance = analyzer.node_scope_provenance;
    transformer.unresolved_references = &analyzer.unresolved_references;
    transformer.semantic_edit_enabled = true;
    transformer.current_scope = transformer.programScope();
    transformer.generator_state_machine_scope = transformer.programScope();
    transformer.state_machine_depth = 1;

    var expression: NodeIndex = .none;
    for (transformer.ast.nodes.items, 0..) |node, raw| {
        if (node.tag != .numeric_literal) continue;
        expression = @fromBackingInt(@intCast(raw));
        break;
    }
    if (expression.isNone()) return error.MissingGeneratorTempExpression;
    var operations: std.ArrayList(Operation) = .empty;
    var next_label: u32 = 1;
    const temp_ref = try ES2015Generator(Transformer).evalIntoGeneratorTemp(
        &transformer,
        expression,
        &operations,
        &next_label,
    );
    try std.testing.expectEqual(@as(usize, 1), operations.items.len);
    try std.testing.expectEqual(@as(usize, 2), transformer.generator_state_semantic_refs.items.len);
    try std.testing.expectEqual(@as(usize, 0), transformer.pending_temp_ref_chains.count());
    try std.testing.expectEqual(@as(usize, 0), transformer.pending_temp_refs.items.len);

    const temp_span = transformer.ast.getNode(temp_ref).data.string_ref;
    const producer_identity = transformer.generator_temp_producer_identities.items[0];
    const raw_id = producer_identity.symbol_id orelse return error.MissingGeneratorTempSymbol;
    const temp_producer_id = producer_identity.temp_producer_id orelse return error.MissingGeneratorTempProducerId;
    const counter_index = transformer.temp_var_counter - 1;
    try std.testing.expectEqual(temp_producer_id, transformer.temp_producer_id_by_counter.get(counter_index).?);
    try std.testing.expectEqual(@as(?u32, raw_id), transformer.temp_symbol_ids_by_counter.get(counter_index));
    try std.testing.expectEqual(@as(?u32, raw_id), transformer.temp_symbols_by_producer_id.get(temp_producer_id));
    try std.testing.expectEqual(temp_span.start, transformer.generator_temp_var_spans.items[0].start);
    try std.testing.expectEqual(transformer.programScope(), producer_identity.owner_scope);
    var reads: usize = 0;
    var writes: usize = 0;
    for (transformer.generator_state_semantic_refs.items) |pending| {
        try std.testing.expectEqual(raw_id, pending.symbol_id);
        try std.testing.expectEqual(@as(?u32, raw_id), transformer.getSymbolIdAt(pending.node));
        try std.testing.expectEqual(transformer.programScope(), pending.scope);
        if (pending.flags.read) reads += 1;
        if (pending.flags.write) writes += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), reads);
    try std.testing.expectEqual(@as(usize, 1), writes);

    const extracted_temp = try es_helpers.makeTempVarSpan(&transformer);
    const extracted_producer = try ES2015Generator(Transformer).captureGeneratorTempProducer(
        &transformer,
        extracted_temp,
        extracted_temp,
    );
    const extracted_raw_id = extracted_producer.symbol_id orelse return error.MissingExtractedGeneratorTempSymbol;
    try std.testing.expect(extracted_raw_id != raw_id);
    const extracted_write = try ES2015Generator(Transformer).makeGeneratorTempRefForProducer(
        &transformer,
        extracted_producer,
        extracted_temp,
        .{ .write = true },
    );
    const extracted_read = try ES2015Generator(Transformer).makeGeneratorTempRefForProducer(
        &transformer,
        extracted_producer,
        extracted_temp,
        .{ .read = true },
    );
    try std.testing.expectEqual(@as(?u32, extracted_raw_id), transformer.getSymbolIdAt(extracted_write));
    try std.testing.expectEqual(@as(?u32, extracted_raw_id), transformer.getSymbolIdAt(extracted_read));
    try std.testing.expectEqual(@as(usize, 4), transformer.generator_state_semantic_refs.items.len);
    try std.testing.expectEqual(@as(usize, 0), transformer.pending_temp_ref_chains.count());
    try std.testing.expectEqual(@as(usize, 0), transformer.pending_temp_refs.items.len);

    const generated_binding_span = try es_helpers.makeTempVarSpan(&transformer);
    const generated_binding = try es_helpers.makeSyntheticBinding(&transformer, generated_binding_span);
    const assignment_ref = try ES2015Generator(Transformer).bindingToAssignTarget(&transformer, generated_binding);
    const assignment_id = transformer.getSymbolIdAt(generated_binding) orelse return error.MissingAssignmentTempSymbol;
    try std.testing.expectEqual(@as(?u32, assignment_id), transformer.getSymbolIdAt(assignment_ref));
    _ = try ES2015Generator(Transformer).registerGeneratorVar(&transformer, generated_binding_span, generated_binding);
    const origin_identity = transformer.generator_temp_producer_identities.items[
        transformer.generator_temp_producer_identities.items.len - 1
    ];
    try std.testing.expectEqual(generated_binding, origin_identity.source_binding);
    try std.testing.expectEqual(@as(usize, 5), transformer.generator_state_semantic_refs.items.len);
    try std.testing.expectEqual(@as(usize, 0), transformer.pending_temp_ref_chains.count());
    try std.testing.expectEqual(@as(usize, 0), transformer.pending_temp_refs.items.len);

    var state_temps: std.ArrayListUnmanaged(@import("transformer/lists.zig").HoistedStateTemp) = .empty;
    _ = try ES2015Generator(Transformer).buildHoistedVarDecl(
        &transformer,
        &.{},
        .EMPTY,
        &state_temps,
        transformer.programScope(),
    );
    var hoisted_binding: ?NodeIndex = null;
    for (state_temps.items) |temp| {
        if (temp.name_span.start != generated_binding_span.start) continue;
        hoisted_binding = temp.binding;
        try std.testing.expectEqual(@as(?u32, assignment_id), temp.symbol_id);
        break;
    }
    var captured_temp_hoisted = false;
    for (state_temps.items) |temp| {
        if (temp.temp_producer_id != temp_producer_id) continue;
        captured_temp_hoisted = true;
        try std.testing.expectEqual(@as(?u32, raw_id), temp.symbol_id);
        try std.testing.expectEqual(transformer.programScope(), temp.owner_scope);
        try std.testing.expectEqual(@as(?u32, raw_id), transformer.getSymbolIdAt(temp.binding));
    }
    try std.testing.expect(captured_temp_hoisted);
    const exact_binding = hoisted_binding orelse return error.MissingAssignmentTempBinding;
    try std.testing.expectEqual(@as(?u32, assignment_id), transformer.getSymbolIdAt(exact_binding));

    var source_binding: NodeIndex = .none;
    for (transformer.ast.nodes.items, 0..) |node, raw| {
        if (node.tag != .binding_identifier) continue;
        if (!std.mem.eql(u8, transformer.ast.getText(node.data.string_ref), "origin")) continue;
        source_binding = @fromBackingInt(@intCast(raw));
        break;
    }
    if (source_binding.isNone()) return error.MissingSourceGeneratorVarBinding;
    const source_symbol_id = transformer.getSymbolIdAt(source_binding) orelse
        return error.MissingSourceGeneratorVarSymbol;
    const source_temp_span = try transformer.ast.addString("origin");
    _ = try ES2015Generator(Transformer).registerGeneratorVar(&transformer, source_temp_span, source_binding);
    state_temps.clearRetainingCapacity();
    _ = try ES2015Generator(Transformer).buildHoistedVarDecl(
        &transformer,
        &.{},
        .EMPTY,
        &state_temps,
        transformer.programScope(),
    );
    var source_hoisted_binding: ?NodeIndex = null;
    for (state_temps.items) |temp| {
        if (temp.name_span.start != source_temp_span.start) continue;
        source_hoisted_binding = temp.binding;
        try std.testing.expectEqual(@as(?u32, source_symbol_id), temp.symbol_id);
        break;
    }
    const exact_source_binding = source_hoisted_binding orelse return error.MissingSourceGeneratorVarHoist;
    try std.testing.expectEqual(@as(?u32, source_symbol_id), transformer.getSymbolIdAt(exact_source_binding));
}

test "#4819 generator temp producer bypasses a stale span identity in another owner scope" {
    const Transformer = @import("transformer.zig").Transformer;
    const SemanticAnalyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer;
    const TransformOptions = @import("options.zig").TransformOptions;
    const SymbolKind = @import("../semantic/symbol.zig").SymbolKind;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var scanner = try Scanner.init(allocator, "function* g(){ yield 1; }");
    var parser = Parser.init(allocator, &scanner);
    parser.configureFromExtension(".mjs");
    _ = try parser.parse();
    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    analyzer.is_module = true;
    try analyzer.analyze();

    var transformer = try Transformer.init(allocator, &parser.ast, .{
        .unsupported = TransformOptions.compat.fromESTarget(.es5),
    });
    try transformer.initSymbolIds(analyzer.symbol_ids.items);
    transformer.symbols = analyzer.symbols.items;
    transformer.class_self_symbol_map = analyzer.class_self_symbol_map;
    transformer.references = analyzer.references.items;
    transformer.scopes = analyzer.scopes.items;
    transformer.scope_maps = analyzer.scope_maps.items;
    transformer.scope_owner_map = analyzer.scope_owner_map;
    transformer.node_scope_provenance = analyzer.node_scope_provenance;
    transformer.unresolved_references = &analyzer.unresolved_references;
    transformer.semantic_edit_enabled = true;

    var generator_scope: ?ScopeId = null;
    var declaration_span: Span = .EMPTY;
    for (transformer.ast.nodes.items, 0..) |node, raw| {
        if (node.tag != .function_declaration) continue;
        const flags = transformer.readU32(node.data.extra, ast_mod.FunctionExtra.flags);
        if (flags & ast_mod.FunctionFlags.is_generator == 0) continue;
        const scope_raw = analyzer.scope_owner_map.get(@intCast(raw)) orelse continue;
        generator_scope = @fromBackingInt(@intCast(scope_raw));
        declaration_span = node.span;
        break;
    }
    const source_scope = generator_scope orelse return error.MissingGeneratorProducerSourceScope;
    const owner_scope = transformer.nearestVarScope(source_scope);
    const decoy_scope = transformer.programScope();
    if (owner_scope == decoy_scope) return error.GeneratorProducerOwnerMatchesDecoyScope;
    transformer.current_scope = source_scope;
    transformer.generator_state_machine_scope = owner_scope;
    transformer.state_machine_depth = 1;

    const name_span = try es_helpers.makeTempVarSpan(&transformer);
    const counter_index = transformer.temp_var_counter - 1;
    const temp_producer_id = transformer.temp_producer_id_by_counter.get(counter_index) orelse
        return error.MissingGeneratorAllocatorProducerId;
    const decoy_symbol = (try transformer.reserveSyntheticTempSymbolInScope(
        name_span,
        declaration_span,
        decoy_scope,
    )) orelse return error.MissingDecoyTempSymbol;
    const stale_owner_key = (@as(u64, @backingInt(owner_scope)) << 32) | name_span.start;
    try transformer.synthetic_temp_symbol_ids.put(allocator, stale_owner_key, @backingInt(decoy_symbol));

    const producer = try ES2015Generator(Transformer).captureGeneratorTempProducer(
        &transformer,
        name_span,
        declaration_span,
    );
    const symbol_id = producer.symbol_id orelse return error.MissingExactGeneratorTempSymbol;
    const raw_symbol_id = symbol_id;
    const producer_identity = transformer.generator_temp_producer_identities.items[0];
    try std.testing.expectEqual(temp_producer_id, producer_identity.temp_producer_id.?);
    try std.testing.expectEqual(@as(?u32, raw_symbol_id), producer_identity.symbol_id);
    try std.testing.expectEqual(owner_scope, producer_identity.owner_scope);
    try std.testing.expect(producer_identity.producer_owned);
    try std.testing.expect(raw_symbol_id != @backingInt(decoy_symbol));
    const editor = if (transformer.semantic_editor) |*value| value else return error.MissingGeneratorProducerEditor;
    try std.testing.expectEqual(owner_scope, editor.symbols.items[raw_symbol_id].scope_id);
    try std.testing.expectEqual(SymbolKind.variable_var, editor.symbols.items[raw_symbol_id].kind);
    try std.testing.expectEqual(temp_producer_id, producer.temp_producer_id.?);
    try std.testing.expectEqual(temp_producer_id, transformer.temp_producer_id_by_counter.get(counter_index).?);
    try std.testing.expectEqual(@as(?u32, raw_symbol_id), transformer.temp_symbol_ids_by_counter.get(counter_index));
    try std.testing.expectEqual(@as(?u32, raw_symbol_id), transformer.temp_symbols_by_producer_id.get(temp_producer_id));

    const write_ref = try ES2015Generator(Transformer).makeGeneratorTempRefForProducer(
        &transformer,
        producer,
        name_span,
        .{ .write = true },
    );
    const read_ref = try ES2015Generator(Transformer).makeGeneratorTempRefForProducer(
        &transformer,
        producer,
        name_span,
        .{ .read = true },
    );
    try std.testing.expectEqual(@as(?u32, raw_symbol_id), transformer.getSymbolIdAt(write_ref));
    try std.testing.expectEqual(@as(?u32, raw_symbol_id), transformer.getSymbolIdAt(read_ref));

    var state_temps: std.ArrayListUnmanaged(@import("transformer/lists.zig").HoistedStateTemp) = .empty;
    defer state_temps.deinit(allocator);
    _ = try ES2015Generator(Transformer).buildHoistedVarDecl(
        &transformer,
        &.{},
        declaration_span,
        &state_temps,
        owner_scope,
    );
    try std.testing.expectEqual(@as(usize, 1), state_temps.items.len);
    const hoisted = state_temps.items[0];
    try std.testing.expectEqual(temp_producer_id, hoisted.temp_producer_id.?);
    try std.testing.expectEqual(@as(?u32, raw_symbol_id), hoisted.symbol_id);
    try std.testing.expectEqual(owner_scope, hoisted.owner_scope);
    try std.testing.expectEqual(@as(?u32, raw_symbol_id), transformer.getSymbolIdAt(hoisted.binding));
    try std.testing.expectEqual(@as(usize, 2), transformer.generator_state_semantic_refs.items.len);
    for (transformer.generator_state_semantic_refs.items) |reference| {
        try std.testing.expectEqual(raw_symbol_id, reference.symbol_id);
        try std.testing.expectEqual(source_scope, reference.scope);
        try std.testing.expectEqual(@as(?u32, raw_symbol_id), transformer.getSymbolIdAt(reference.node));
    }
}

fn checkGeneratorDestructuringProducerIdentity(source: []const u8, expected_temp_count: usize) !void {
    const Transformer = @import("transformer.zig").Transformer;
    const SemanticAnalyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer;
    const TransformOptions = @import("options.zig").TransformOptions;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var scanner = try Scanner.init(allocator, source);
    var parser = Parser.init(allocator, &scanner);
    _ = try parser.parse();
    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    try analyzer.analyze();

    var transformer = try Transformer.init(allocator, &parser.ast, .{
        .unsupported = TransformOptions.compat.fromESTarget(.es2015),
    });
    try transformer.initSymbolIds(analyzer.symbol_ids.items);
    transformer.symbols = analyzer.symbols.items;
    transformer.class_self_symbol_map = analyzer.class_self_symbol_map;
    transformer.references = analyzer.references.items;
    transformer.scopes = analyzer.scopes.items;
    transformer.scope_maps = analyzer.scope_maps.items;
    transformer.scope_owner_map = analyzer.scope_owner_map;
    transformer.node_scope_provenance = analyzer.node_scope_provenance;
    transformer.unresolved_references = &analyzer.unresolved_references;
    transformer.semantic_edit_enabled = true;

    var output_scope: ?ScopeId = null;
    var pattern: NodeIndex = .none;
    var largest_pattern_span: u32 = 0;
    var rhs: NodeIndex = .none;
    for (transformer.ast.nodes.items, 0..) |node, raw| {
        if (node.tag == .function_declaration and output_scope == null) {
            if (analyzer.scope_owner_map.get(@intCast(raw))) |scope_raw|
                output_scope = @fromBackingInt(@intCast(scope_raw));
        }
        if (node.tag == .object_pattern or node.tag == .array_pattern) {
            const width = node.span.end - node.span.start;
            if (width > largest_pattern_span) {
                pattern = @fromBackingInt(@intCast(raw));
                largest_pattern_span = width;
            }
        }
        if (node.tag == .numeric_literal and rhs.isNone()) rhs = @fromBackingInt(@intCast(raw));
    }
    const owner = output_scope orelse return error.MissingGeneratorDestructuringOwner;
    if (pattern.isNone()) return error.MissingGeneratorDestructuringPattern;
    if (rhs.isNone()) return error.MissingGeneratorDestructuringRhs;
    const pattern_node = transformer.ast.getNode(pattern);
    const saved_counter = transformer.temp_var_counter;
    transformer.current_scope = owner;
    transformer.generator_state_machine_scope = owner;
    transformer.state_machine_depth = 1;

    const statement = try ES2015Generator(Transformer).makeDestructuringAssignStmt(
        &transformer,
        pattern,
        rhs,
        pattern_node.span,
        owner,
    );
    try std.testing.expectEqual(expected_temp_count, transformer.temp_symbol_ids_by_counter.count());
    var producer_slots_without_pending_refs = transformer.temp_symbol_ids_by_counter.iterator();
    while (producer_slots_without_pending_refs.next()) |entry| {
        const name_span = transformer.temp_span_by_counter.get(entry.key_ptr.*) orelse
            return error.MissingGeneratorDestructuringTempSpan;
        try std.testing.expect(!transformer.pending_temp_ref_chains.contains(transformer.currentPendingTempRefKey(name_span)));
    }
    const reachable = try ast_walk.collectReachableNodeIndicesFrom(allocator, transformer.ast, statement);
    const editor = &transformer.semantic_editor.?;
    var identities = transformer.temp_symbol_ids_by_counter.iterator();
    var identity_count: usize = 0;
    while (identities.next()) |entry| {
        const name_span = transformer.temp_span_by_counter.get(entry.key_ptr.*) orelse
            return error.MissingGeneratorDestructuringTempSpan;
        const id = entry.value_ptr.*;
        if (id >= editor.symbols.items.len) return error.InvalidGeneratorDestructuringSymbolId;
        const symbol = editor.symbols.items[id];
        try std.testing.expectEqual(owner, symbol.scope_id);
        try std.testing.expectEqual(name_span.start, symbol.name.start);
        try std.testing.expectEqual(name_span.end, symbol.name.end);

        var reference_count: usize = 0;
        for (reachable) |raw| {
            if (raw >= transformer.symbol_ids.items.len or transformer.symbol_ids.items[raw] != id) continue;
            const node: NodeIndex = @fromBackingInt(@intCast(raw));
            switch (transformer.ast.getNode(node).tag) {
                .identifier_reference, .assignment_target_identifier => {},
                else => continue,
            }
            const reference = (try editor.referenceForNode(node)) orelse
                return error.MissingGeneratorDestructuringProducerReference;
            try std.testing.expectEqual(id, @backingInt(reference.symbol_id));
            try std.testing.expectEqual(owner, reference.scope_id);
            reference_count += 1;
        }
        try std.testing.expect(reference_count > 0);
        try std.testing.expectEqual(symbol.reference_count, reference_count);
        identity_count += 1;
    }
    try std.testing.expectEqual(expected_temp_count, identity_count);

    const body_list = try transformer.ast.addNodeList(&.{statement});
    const body = try transformer.ast.addNode(.{
        .tag = .block_statement,
        .span = pattern_node.span,
        .data = .{ .list = body_list },
    });
    var callback_temps: std.ArrayListUnmanaged(@import("transformer/lists.zig").HoistedStateTemp) = .empty;
    const hoisted_body = try transformer.hoistStateMachineTempsAndRestore(body, saved_counter, pattern_node.span, &callback_temps);
    var carried_count: usize = 0;
    for (callback_temps.items) |temp| {
        var expected_id: ?u32 = null;
        var producer_slots = transformer.temp_symbol_ids_by_counter.iterator();
        while (producer_slots.next()) |entry| {
            const producer_span = transformer.temp_span_by_counter.get(entry.key_ptr.*) orelse continue;
            if (producer_span.start != temp.name_span.start or producer_span.end != temp.name_span.end) continue;
            expected_id = entry.value_ptr.*;
        }
        const producer_id = expected_id orelse continue;
        const hoisted_id = temp.symbol_id orelse return error.MissingHoistedProducerSymbolId;
        try std.testing.expectEqual(producer_id, hoisted_id);
        carried_count += 1;
    }
    try std.testing.expectEqual(expected_temp_count, carried_count);

    const generated = try ES2015Generator(Transformer).buildGeneratorHelperCallWithProto(
        &transformer,
        hoisted_body,
        .none,
        pattern_node.span,
    );
    try transformer.bindGeneratedState(
        owner,
        owner,
        generated.callback,
        generated.state_param,
        transformer.generator_state_refs.items.len,
        &.{},
        callback_temps.items,
        pattern_node.span,
    );
    producer_slots_without_pending_refs = transformer.temp_symbol_ids_by_counter.iterator();
    while (producer_slots_without_pending_refs.next()) |entry| {
        const name_span = transformer.temp_span_by_counter.get(entry.key_ptr.*) orelse continue;
        try std.testing.expect(!transformer.pending_temp_ref_chains.contains(transformer.currentPendingTempRefKey(name_span)));
    }
    const callback_scope = transformer.outputOwnedScope(generated.callback) orelse
        return error.MissingGeneratorDestructuringCallbackScope;
    var finalized_identities: usize = 0;
    var finalized_slots = transformer.temp_symbol_ids_by_counter.iterator();
    while (finalized_slots.next()) |entry| {
        const name_span = transformer.temp_span_by_counter.get(entry.key_ptr.*) orelse continue;
        const id = entry.value_ptr.*;
        const symbol = editor.symbols.items[id];
        try std.testing.expectEqual(callback_scope, symbol.scope_id);
        var binding_found = false;
        for (callback_temps.items) |temp| {
            if (temp.name_span.start != name_span.start or temp.name_span.end != name_span.end) continue;
            try std.testing.expectEqual(@as(?u32, id), transformer.getSymbolIdAt(temp.binding));
            binding_found = true;
        }
        try std.testing.expect(binding_found);
        var finalized_references: usize = 0;
        for (editor.references.items) |reference| {
            if (@backingInt(reference.symbol_id) != id) continue;
            try std.testing.expectEqual(callback_scope, reference.scope_id);
            finalized_references += 1;
        }
        try std.testing.expect(finalized_references > 0);
        finalized_identities += 1;
    }
    try std.testing.expectEqual(expected_temp_count, finalized_identities);
}

test "#4819 state-machine destructuring assignment carries exact producer IDs through hoisting" {
    const fixtures = [_]struct { source: []const u8, temps: usize }{
        .{ .source = "function* f(key, output, rest) { let { [key()]: output, ...rest } = 1; }", .temps = 2 },
        .{ .source = "function* f(key, output) { let { [key]: output } = 1; }", .temps = 2 },
        .{ .source = "function* f(output) { let [output] = 1; }", .temps = 1 },
        .{ .source = "function* f(output) { let [, output] = 1; }", .temps = 1 },
        .{ .source = "function* f(output) { let { item: { value: output } } = 1; }", .temps = 1 },
        .{ .source = "function* f(key, output) { let { [key()]: output } = 1; }", .temps = 2 },
        .{ .source = "function* f(key, output, rest) { let { [key()]: output, ...rest } = 1; }", .temps = 2 },
        .{ .source = "function* f(output) { let { output } = 1; }", .temps = 1 },
        .{ .source = "function* f(output) { let { value: output } = 1; }", .temps = 1 },
        .{ .source = "function* f(key, first, second) { let { [key()]: first, ['other']: second } = 1; }", .temps = 3 },
    };
    for (fixtures) |fixture| try checkGeneratorDestructuringProducerIdentity(fixture.source, fixture.temps);
}

test "#4819 class-header generator temps carry producer IDs across hostile sources" {
    const Transformer = @import("transformer.zig").Transformer;
    const SemanticAnalyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer;
    const TransformOptions = @import("options.zig").TransformOptions;
    const sources = [_][]const u8{
        "const _a = 0; function* g() { class C extends (yield Base) {} }",
        "function* g(_a) { class C { [yield _a]() {} } }",
        "const _b = 1; function* g() { class C extends (yield (Base + 3)) {} }",
        "function* outer() { function inner(_a) { return _a; } class C extends (yield Base) {} }",
        "function* g() { class C { [yield (flag ? A : B)]() {} } }",
        "function* g() { try { class C extends (yield Base) {} } catch (_a) { yield 10; } }",
        "async function* g() { class C extends (yield await Promise.resolve(Base)) {} }",
        "function* g() { class C extends (yield Base) { [yield key]() {} } }",
        "function* g() { class C { [yield first]() {} [yield second]() {} } }",
        "function* g() { class A extends (yield BaseA) {} class B { [yield keyB]() {} } }",
    };

    for (sources) |source| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        var scanner = try Scanner.init(allocator, source);
        var parser = Parser.init(allocator, &scanner);
        _ = try parser.parse();
        try std.testing.expectEqual(@as(usize, 0), parser.errors.items.len);
        var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
        try analyzer.analyze();
        try std.testing.expectEqual(@as(usize, 0), analyzer.errors.items.len);

        var transformer = try Transformer.init(allocator, &parser.ast, .{
            .unsupported = TransformOptions.compat.fromESTarget(.es5),
        });
        try transformer.initSymbolIds(analyzer.symbol_ids.items);
        transformer.symbols = analyzer.symbols.items;
        transformer.class_self_symbol_map = analyzer.class_self_symbol_map;
        transformer.references = analyzer.references.items;
        transformer.scopes = analyzer.scopes.items;
        transformer.scope_maps = analyzer.scope_maps.items;
        transformer.scope_owner_map = analyzer.scope_owner_map;
        transformer.node_scope_provenance = analyzer.node_scope_provenance;
        transformer.unresolved_references = &analyzer.unresolved_references;
        transformer.semantic_edit_enabled = true;
        const generator_scope = transformer.programScope();
        var reference_scope: ?@import("../semantic/scope.zig").ScopeId = null;
        for (transformer.ast.nodes.items, 0..) |node, raw| {
            if (node.tag != .function_declaration) continue;
            const owner_raw = analyzer.scope_owner_map.get(@intCast(raw)) orelse continue;
            reference_scope = @fromBackingInt(@intCast(owner_raw));
            break;
        }
        transformer.current_scope = reference_scope orelse return error.MissingGeneratorReferenceScope;
        transformer.generator_state_machine_scope = generator_scope;
        transformer.state_machine_depth = 1;
        transformer.in_async_generator_body = std.mem.startsWith(u8, source, "async function*");
        try std.testing.expect(transformer.current_scope != generator_scope);

        var operations: std.ArrayList(Operation) = .empty;
        var next_label: u32 = 1;
        var first_class: NodeIndex = .none;
        var class_count: usize = 0;
        const original_node_count = transformer.ast.nodes.items.len;
        for (transformer.ast.nodes.items[0..original_node_count], 0..) |node, raw| {
            if (node.tag != .class_declaration) continue;
            const class_idx: NodeIndex = @fromBackingInt(@intCast(raw));
            if (first_class.isNone()) first_class = class_idx;
            const expected_self = transformer.class_self_symbol_map.get(@backingInt(class_idx)) orelse return error.MissingSourceClassSelf;
            const expected_scope = transformer.outputOwnedScope(class_idx) orelse return error.MissingSourceClassScope;
            const copied = try ES2015Generator(Transformer).extractClassHeaderYields(
                &transformer,
                class_idx,
                &operations,
                &next_label,
            );
            try std.testing.expectEqual(@as(?u32, expected_self), transformer.class_self_symbol_map.get(@backingInt(copied)));
            try std.testing.expectEqual(@as(?u32, expected_self), transformer.class_self_symbol_map.get(@backingInt(class_idx)));
            try std.testing.expectEqual(node.tag, transformer.ast.getNode(copied).tag);
            const copied_extra = transformer.ast.getNode(copied).data.extra;
            try std.testing.expectEqual(transformer.readNodeIdx(node.data.extra, ast_mod.ClassExtra.name), transformer.readNodeIdx(copied_extra, ast_mod.ClassExtra.name));
            if (!transformer.readNodeIdx(node.data.extra, ast_mod.ClassExtra.super).isNone())
                try std.testing.expect(!transformer.readNodeIdx(copied_extra, ast_mod.ClassExtra.super).isNone());
            try std.testing.expectEqual(expected_scope, transformer.outputOwnedScope(copied).?);
            try std.testing.expectEqual(@backingInt(class_idx), transformer.scope_owner_origins.get(@backingInt(copied)).?);
            class_count += 1;
        }
        if (first_class.isNone()) return error.MissingGeneratorClassHeader;
        try std.testing.expect(class_count > 0);
        try std.testing.expect(next_label > 1);
        var temp_count: usize = 0;
        for (transformer.generator_temp_producer_identities.items) |identity| {
            if (identity.symbol_id != null) temp_count += 1;
        }
        try std.testing.expect(temp_count > 0);
        try std.testing.expectEqual(temp_count * 2, transformer.generator_state_semantic_refs.items.len);

        for (transformer.generator_state_semantic_refs.items) |reference| {
            try std.testing.expectEqual(@as(?u32, reference.symbol_id), transformer.getSymbolIdAt(reference.node));
            try std.testing.expectEqual(transformer.current_scope, reference.scope);
            var reads: usize = 0;
            var writes: usize = 0;
            for (transformer.generator_state_semantic_refs.items) |same_symbol| {
                if (same_symbol.symbol_id != reference.symbol_id) continue;
                if (same_symbol.flags.read) reads += 1;
                if (same_symbol.flags.write) writes += 1;
            }
            try std.testing.expectEqual(@as(usize, 1), reads);
            try std.testing.expectEqual(@as(usize, 1), writes);
        }

        // No registry entry is created for this second producer. Exact
        // reference registration must work from the producer handle alone.
        const direct_span = try es_helpers.makeTempVarSpan(&transformer);
        const direct_producer = try ES2015Generator(Transformer).captureGeneratorTempProducer(
            &transformer,
            direct_span,
            transformer.ast.getNode(first_class).span,
        );
        const direct_raw_id = direct_producer.symbol_id orelse return error.MissingDirectProducerSymbolId;
        const direct_id: @import("../semantic/symbol.zig").SymbolId = @fromBackingInt(@intCast(direct_raw_id));
        const direct_ref = try ES2015Generator(Transformer).makeGeneratorTempRefForProducer(
            &transformer,
            direct_producer,
            direct_span,
            .{ .read = true },
        );
        try std.testing.expectEqual(direct_raw_id, transformer.generator_temp_producer_identities.items[
            transformer.generator_temp_producer_identities.items.len - 1
        ].symbol_id.?);
        try std.testing.expectEqual(@as(?u32, @backingInt(direct_id)), transformer.getSymbolIdAt(direct_ref));
        const direct_record = transformer.generator_state_semantic_refs.items[
            transformer.generator_state_semantic_refs.items.len - 1
        ];
        try std.testing.expectEqual(@backingInt(direct_id), direct_record.symbol_id);
        try std.testing.expectEqual(transformer.current_scope, direct_record.scope);
        try std.testing.expect(direct_record.flags.read);
        try std.testing.expect(!direct_record.flags.write);

        const symbols = if (transformer.semantic_editor) |*editor| editor.symbols.items else unreachable;
        const raw_direct_id: usize = @intCast(@backingInt(direct_id));
        try std.testing.expect(raw_direct_id < symbols.len);
        try std.testing.expectEqual(@import("../semantic/symbol.zig").SymbolKind.variable_var, symbols[raw_direct_id].kind);
        try std.testing.expectEqual(transformer.generator_state_machine_scope, symbols[raw_direct_id].scope_id);
    }
}

test "generator state name handoff survives nested cache invalidation" {
    const Mock = struct {
        pub const Error = std.mem.Allocator.Error;
        allocator: std.mem.Allocator,
        ast: *ast_mod.Ast,
        symbols: []const @import("../semantic/symbol.zig").Symbol = &.{},
        unresolved_references: ?*const std.StringHashMapUnmanaged(void) = null,
        user_symbol_names: ?std.StringHashMapUnmanaged(void) = null,
        options: @import("options.zig").TransformOptions = .{},
        semantic_edit_enabled: bool = false,
        current_scope: ScopeId = .none,
        semantic_editor: ?@import("../semantic/editor.zig").SemanticEditor = null,
        scopes: []const @import("../semantic/scope.zig").Scope = &.{},
        generator_state_output_scope: ScopeId = .none,
        synthetic_names: std.StringHashMapUnmanaged([]const u8) = .empty,
        scoped_synthetic_names: std.StringHashMapUnmanaged([]const u8) = .empty,
        synthetic_taken: std.StringHashMapUnmanaged(void) = .empty,
        late_output_name_bases: std.StringHashMapUnmanaged([]const u8) = .empty,
        name_arena: ?std.heap.ArenaAllocator = null,
        synthetic_idents: ?std.AutoHashMapUnmanaged(u32, void) = null,
        generator_state_name_span: ?Span = null,
        generator_temp_var_spans: std.ArrayList(Span) = .empty,
        generator_temp_producer_identities: std.ArrayListUnmanaged(@import("transformer.zig").GeneratorTempProducerIdentity) = .empty,
        generator_state_bindings: std.ArrayListUnmanaged(@import("transformer/lists.zig").HoistedStateTemp) = .empty,
        generator_state_refs: std.ArrayList(NodeIndex) = .empty,
        state_machine_depth: u32 = 0,
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var scanner = try Scanner.init(allocator, "_state;");
    var parser = Parser.init(allocator, &scanner);
    _ = try parser.parse();

    var mock = Mock{ .allocator = allocator, .ast = &parser.ast };
    const Generator = ES2015Generator(Mock);

    var outer_frame = try Generator.enterStateMachineTemps(&mock);
    var outer_active = true;
    defer {
        if (outer_active) Generator.leaveStateMachineTemps(&mock, &outer_frame);
    }
    const outer_ref = try Generator.makeGeneratorStateRef(&mock);
    const outer_ref_span = mock.ast.getNode(outer_ref).data.string_ref;
    try std.testing.expectEqualStrings("_state2", mock.ast.getText(outer_ref_span));

    // Force a later name lookup to choose a different spelling. The outer
    // machine must keep the exact span already attached to its references.
    try std.testing.expect(mock.synthetic_names.remove("_state"));

    var inner_frame = try Generator.enterStateMachineTemps(&mock);
    var inner_active = true;
    defer {
        if (inner_active) Generator.leaveStateMachineTemps(&mock, &inner_frame);
    }
    const inner_ref = try Generator.makeGeneratorStateRef(&mock);
    const inner_ref_span = mock.ast.getNode(inner_ref).data.string_ref;
    const inner_binding = try Generator.makeGeneratorStateBinding(&mock);
    const inner_binding_span = mock.ast.getNode(inner_binding).data.string_ref;
    try std.testing.expectEqualStrings("_state3", mock.ast.getText(inner_ref_span));
    try std.testing.expectEqualStrings(mock.ast.getText(inner_ref_span), mock.ast.getText(inner_binding_span));

    Generator.leaveStateMachineTemps(&mock, &inner_frame);
    inner_active = false;

    const outer_binding = try Generator.makeGeneratorStateBinding(&mock);
    const outer_binding_span = mock.ast.getNode(outer_binding).data.string_ref;
    try std.testing.expectEqualStrings("_state2", mock.ast.getText(outer_binding_span));
    try std.testing.expectEqualStrings(mock.ast.getText(outer_ref_span), mock.ast.getText(outer_binding_span));

    Generator.leaveStateMachineTemps(&mock, &outer_frame);
    outer_active = false;
    try std.testing.expectEqual(@as(usize, 0), mock.generator_state_refs.items.len);
    try std.testing.expectEqual(@as(u32, 0), mock.state_machine_depth);
}

test "generator deferred loop return handoff requires one exact binding node" {
    const Mock = struct {
        pub const Error = std.mem.Allocator.Error;
        generator_state_bindings: std.ArrayListUnmanaged(@import("transformer/lists.zig").HoistedStateTemp) = .empty,
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var mock = Mock{};
    defer mock.generator_state_bindings.deinit(allocator);
    const Generator = ES2015Generator(Mock);
    const binding: NodeIndex = @fromBackingInt(17);
    const decoy: NodeIndex = @fromBackingInt(18);
    const name_span: Span = .{ .start = 30, .end = 34 };
    const wrong_start_span: Span = .{ .start = 31, .end = 34 };
    const wrong_end_span: Span = .{ .start = 30, .end = 35 };
    try mock.generator_state_bindings.append(allocator, .{
        .binding = binding,
        .name_span = name_span,
        .callback_local = true,
    });

    try std.testing.expect(Generator.hasExactCallbackLocalGeneratorTempBinding(&mock, binding, name_span));
    try std.testing.expect(!Generator.hasExactCallbackLocalGeneratorTempBinding(&mock, decoy, name_span));
    try std.testing.expect(!Generator.hasExactCallbackLocalGeneratorTempBinding(&mock, binding, wrong_start_span));
    try std.testing.expect(!Generator.hasExactCallbackLocalGeneratorTempBinding(&mock, binding, wrong_end_span));

    mock.generator_state_bindings.items[0].callback_local = false;
    try std.testing.expect(!Generator.hasExactCallbackLocalGeneratorTempBinding(&mock, binding, name_span));
    mock.generator_state_bindings.items[0].callback_local = true;
    try mock.generator_state_bindings.append(allocator, .{
        .binding = binding,
        .name_span = name_span,
        .callback_local = true,
    });
    try std.testing.expect(!Generator.hasExactCallbackLocalGeneratorTempBinding(&mock, binding, name_span));
}

fn checkUsingCleanupStateStorage(source: []const u8, ordinary_try: bool) !void {
    const Transformer = @import("transformer.zig").Transformer;
    const SemanticAnalyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer;
    const TransformOptions = @import("options.zig").TransformOptions;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var scanner = try Scanner.init(alloc, source);
    var parser = Parser.init(alloc, &scanner);
    parser.configureFromExtension(".mjs");
    _ = try parser.parse();
    try std.testing.expectEqual(@as(usize, 0), parser.errors.items.len);
    var analyzer = SemanticAnalyzer.init(alloc, &parser.ast);
    analyzer.is_module = true;
    try analyzer.analyze();
    try std.testing.expectEqual(@as(usize, 0), analyzer.errors.items.len);
    var function: NodeIndex = .none;
    for (parser.ast.nodes.items, 0..) |node, raw| {
        if (node.tag != .function_declaration) continue;
        if (function.isNone() or node.span.end - node.span.start > parser.ast.getNode(function).span.end - parser.ast.getNode(function).span.start)
            function = @fromBackingInt(@intCast(raw));
    }
    try std.testing.expect(!function.isNone());
    const scope: @import("../semantic/scope.zig").ScopeId = @fromBackingInt(analyzer.scope_owner_map.get(@backingInt(function)).?);
    var state_ids: std.ArrayList(u32) = .empty;
    for (parser.ast.nodes.items) |node| {
        if (node.tag != .variable_declaration) continue;
        const start = parser.ast.extra_data.items[node.data.extra + 1];
        const len = parser.ast.extra_data.items[node.data.extra + 2];
        for (parser.ast.extra_data.items[start..][0..len]) |raw| {
            const declarator = parser.ast.getNode(@fromBackingInt(@intCast(raw)));
            const binding = parser.ast.extra_data.items[declarator.data.extra];
            if (parser.ast.nodes.items[binding].tag != .binding_identifier) continue;
            const sid = analyzer.symbol_ids.items[binding] orelse return error.MissingSourceUsingIdentity;
            var owner = analyzer.symbols.items[sid].scope_id;
            while (!owner.isNone() and !analyzer.scopes.items[owner.toIndex()].kind.isVarScope())
                owner = analyzer.scopes.items[owner.toIndex()].parent;
            if (owner != scope) continue;
            if (std.mem.indexOfScalar(u32, state_ids.items, sid) == null) try state_ids.append(alloc, sid);
        }
    }
    if (!ordinary_try) try std.testing.expect(state_ids.items.len > 0);
    var transformer = try Transformer.init(alloc, &parser.ast, .{ .unsupported = TransformOptions.compat.fromESTarget(.es5) });
    try transformer.initSymbolIds(analyzer.symbol_ids.items);
    transformer.symbols = analyzer.symbols.items;
    transformer.references = analyzer.references.items;
    transformer.scopes = analyzer.scopes.items;
    transformer.scope_maps = analyzer.scope_maps.items;
    transformer.scope_owner_map = analyzer.scope_owner_map;
    transformer.node_scope_provenance = analyzer.node_scope_provenance;
    transformer.class_self_symbol_map = analyzer.class_self_symbol_map;
    transformer.unresolved_references = &analyzer.unresolved_references;
    transformer.semantic_edit_enabled = true;
    transformer.current_scope = scope;
    transformer.generator_state_output_scope = scope;
    transformer.state_machine_depth = 1;
    const body = transformer.readNodeIdx(parser.ast.getNode(function).data.extra, ast_mod.FunctionExtra.body);
    const built = try ES2015Generator(Transformer).buildStateMachine(&transformer, body, parser.ast.getNode(body).span, scope);
    const callback_nodes = try ast_walk.collectReachableNodeIndicesFrom(alloc, transformer.ast, built.body);
    const wrapper_nodes = if (built.var_decl.isNone()) &.{} else try ast_walk.collectReachableNodeIndicesFrom(alloc, transformer.ast, built.var_decl);
    var native_tries: usize = 0;
    for (callback_nodes) |raw| if (transformer.ast.nodes.items[raw].tag == .try_statement) {
        native_tries += 1;
    };
    try std.testing.expectEqual(@as(usize, if (ordinary_try) 1 else 0), native_tries);
    for (state_ids.items) |sid| {
        var wrapper_bindings: usize = 0;
        var callback_bindings: usize = 0;
        var assignments: usize = 0;
        for (wrapper_nodes) |raw| {
            if (transformer.ast.nodes.items[raw].tag == .binding_identifier and transformer.getSymbolIdAt(@fromBackingInt(raw)) == sid) wrapper_bindings += 1;
        }
        for (callback_nodes) |raw| {
            const node = transformer.ast.nodes.items[raw];
            if (node.tag == .assignment_expression and transformer.getSymbolIdAt(node.data.binary.left) == sid) assignments += 1;
            if (transformer.getSymbolIdAt(@fromBackingInt(raw)) == sid and node.tag == .binding_identifier) callback_bindings += 1;
        }
        try std.testing.expectEqual(@as(usize, 1), wrapper_bindings);
        try std.testing.expectEqual(@as(usize, 0), callback_bindings);
        try std.testing.expect(assignments > 0);
        var exact_handoff = false;
        for (built.hoisted_temps.items) |temp| {
            if (temp.symbol_id != sid) continue;
            try std.testing.expectEqual(scope, temp.owner_scope);
            try std.testing.expectEqual(@as(?u32, sid), transformer.getSymbolIdAt(temp.binding));
            exact_handoff = true;
        }
        if (!exact_handoff) {
            try std.testing.expectEqual(scope, transformer.semantic_editor.?.symbols.items[sid].scope_id);
        }
    }
}

test "#4819 generated using cleanup has one state storage identity before output repair" {
    const sources = [_][]const u8{
        "function* run() { { using first = make(); use(first); } yield 0; }",
        "function* run() { { using first = make(), second = make(); use(first, second); } yield 0; }",
        "function* run() { { using first = make(); using second = make(); use(first, second); } yield 0; }",
        "function* run() { { using first = make(); { using second = make(); use(first, second); } } yield 0; }",
        "function* run() { { using first = make(); keep(() => first); } yield 0; }",
        "function* run() { { using first = make(); const copy = first; use(copy); } yield 0; }",
        "async function run() { { using first = make(); var shared = first; } await null; use(shared); }",
        "async function run() { { using first = await make(); use(first); } await null; }",
        "async function run() { { using first = make(); await null; use(first); } }",
        "function* run() { using first = make(); use(first); }",
        "function* run() { { using first = make(); return first; } }",
        "async function run() { { await using first = make(); use(first); } }",
        "function* run() { { using first = make(); throw first; } }",
    };
    for (sources) |source| try checkUsingCleanupStateStorage(source, false);
    try checkUsingCleanupStateStorage("function* run() { try { work(); } finally { done(); } yield 0; }", true);
}

test "native generator var writes retain their wrapper SID and exact producer scope before callback assembly" {
    const Analyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer;
    const Transformer = @import("transformer.zig").Transformer;
    const Options = @import("transformer.zig").TransformOptions;
    const walk = @import("../parser/ast_walk.zig");
    const Fixture = struct { body: []const u8, native_write: bool = true, is_module: bool = true };
    const bodies = [_]Fixture{
        .{ .body = "if(true) var shared=42;yield 0;return shared;" },
        .{ .body = "for(var value of [42]){var shared=value;}yield 0;return[value,shared];" },
        .{ .body = "for(var i=0;i<2;i++){var shared=40+i;}yield 0;return[shared,i];" },
        .{ .body = "var i=0;while(i++<1){var shared=42;}yield 0;return shared;" },
        .{ .body = "var i=0;do{var shared=42;}while(i++<0);yield 0;return shared;" },
        .{ .body = "switch(1){case 1:var shared=42;break;}yield 0;return shared;" },
        .{ .body = "try{var shared=40;throw 2;}catch(e){shared+=e;var caught=7;}finally{var cleanup=9;}yield 0;return[shared,caught,cleanup];" },
        .{ .body = "if(true){var {x:shared,...rest}={x:42,y:7};}yield 0;return[shared,rest.y];" },
        .{ .body = "for(var {value:shared} of [{value:42}]){}yield 0;return shared;" },
        .{ .body = "if(true){var shared=42;function inner(){var shared=9;return shared;}class Box{static get(){var shared=7;return shared;}}var fn=inner;var klass=Box;}yield 0;return[shared,fn(),klass.get()];" },
        .{ .body = "var shared=42;if(true){var shared;}yield 0;return shared;", .native_write = false },
        .{ .body = "if(true){let local=9;var get=()=>local;var shared=42;}yield 0;return[get(),shared];" },
        .{ .body = "const host={shared:1};with(host){var shared=42;}yield 0;return [shared,host.shared];", .is_module = false },
        .{ .body = "const host={shared:1};if(true){with(host){var shared=42;}}yield 0;return [shared,host.shared];", .is_module = false },
        .{ .body = "var shared=7;const host={shared:1};with(host){var shared=42;}yield 0;return [shared,host.shared];", .is_module = false },
        .{ .body = "const host={shared:1};with(host){var shared=42;var get=()=>shared;}yield 0;return [shared,get(),host.shared];", .is_module = false },
    };
    for (bodies) |fixture| {
        const body_source = fixture.body;
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const source = try std.fmt.allocPrint(a, "function* f(){{{s}}}", .{body_source});
        var scanner = try Scanner.init(a, source);
        var parser = Parser.init(a, &scanner);
        parser.is_module = fixture.is_module;
        scanner.is_module = fixture.is_module;
        _ = try parser.parse();
        try std.testing.expectEqual(@as(usize, 0), parser.errors.items.len);
        var analyzer = Analyzer.init(a, &parser.ast);
        analyzer.is_module = fixture.is_module;
        analyzer.enable_exact_declaration_anchors = true;
        try analyzer.analyze();
        var function: NodeIndex = .none;
        for (parser.ast.nodes.items, 0..) |node, raw| {
            if (node.tag == .function_declaration and parser.ast.extra_data.items[node.data.extra + ast_mod.FunctionExtra.flags] & ast_mod.FunctionFlags.is_generator != 0) {
                function = @fromBackingInt(@as(u32, @intCast(raw)));
                break;
            }
        }
        try std.testing.expect(!function.isNone());
        const wrapper_scope: ScopeId = @fromBackingInt(analyzer.scope_owner_map.get(@backingInt(function)).?);
        const expected_sid: u32 = @intCast(analyzer.scope_maps.items[wrapper_scope.toIndex()].get("shared").?);
        // The final source redeclaration is the native-region declaration in
        // the controls with an earlier wrapper initializer. Match its source
        // span only to select this test's producer-created write references.
        var native_binding_start: u32 = 0;
        for (parser.ast.nodes.items, 0..) |source_node, raw| {
            if (source_node.tag == .binding_identifier and analyzer.symbol_ids.items[raw] == expected_sid)
                native_binding_start = @max(native_binding_start, source_node.data.string_ref.start);
        }

        var transformer = try Transformer.init(a, &parser.ast, .{ .unsupported = Options.compat.fromESTarget(.es5) });
        try transformer.initSymbolIds(analyzer.symbol_ids.items);
        transformer.symbols = analyzer.symbols.items;
        transformer.references = analyzer.references.items;
        transformer.scopes = analyzer.scopes.items;
        transformer.scope_maps = analyzer.scope_maps.items;
        transformer.scope_owner_map = analyzer.scope_owner_map;
        transformer.node_scope_provenance = analyzer.node_scope_provenance;
        transformer.class_self_symbol_map = analyzer.class_self_symbol_map;
        transformer.unresolved_references = &analyzer.unresolved_references;
        transformer.semantic_edit_enabled = true;
        transformer.current_scope = wrapper_scope;
        const Generator = ES2015Generator(Transformer);
        var frame = try Generator.enterStateMachineTempsForScope(&transformer, wrapper_scope);
        defer Generator.leaveStateMachineTemps(&transformer, &frame);
        const node = parser.ast.getNode(function);
        const result = try Generator.buildStateMachine(&transformer, transformer.readNodeIdx(node.data.extra, ast_mod.FunctionExtra.body), node.span, wrapper_scope);
        try std.testing.expect(!result.body.isNone() and !result.var_decl.isNone());
        const editor = &transformer.semantic_editor.?;
        try std.testing.expectEqual(wrapper_scope, editor.symbols.items[expected_sid].scope_id);
        if (!fixture.is_module) try std.testing.expect(editor.scopes.items[wrapper_scope.toIndex()].subtree_has_with);
        var wrapper_bindings: usize = 0;
        var stack: std.ArrayList(NodeIndex) = .empty;
        try stack.append(a, result.var_decl);
        while (stack.pop()) |index| {
            const output = transformer.ast.getNode(index);
            if (output.tag == .binding_identifier and transformer.getSymbolIdAt(index) == expected_sid) wrapper_bindings += 1;
            var children = walk.children(transformer.ast, output);
            while (children.next()) |child| if (!child.isNone()) try stack.append(a, child);
        }
        try std.testing.expectEqual(@as(usize, 1), wrapper_bindings);
        const Work = struct { node: NodeIndex, scope: ScopeId };
        var pending: std.ArrayList(Work) = .empty;
        try pending.append(a, .{ .node = result.body, .scope = wrapper_scope });
        var writes: usize = 0;
        while (pending.pop()) |item| {
            const output = transformer.ast.getNode(item.node);
            const scope = transformer.outputOwnedScope(item.node) orelse item.scope;
            if (transformer.getSymbolIdAt(item.node) == expected_sid) {
                try std.testing.expect(output.tag != .binding_identifier);
                if (@backingInt(item.node) >= transformer.parser_node_count and output.span.start == native_binding_start) {
                    const reference = try editor.referenceForNode(item.node) orelse return error.MissingNativeVarReference;
                    if (reference.flags.write) {
                        if (scope != reference.scope_id) std.debug.print("native scope fixture={s} node={d} expected={d} actual={d}\n", .{ body_source, @backingInt(item.node), @backingInt(scope), @backingInt(reference.scope_id) });
                        try std.testing.expectEqual(scope, reference.scope_id);
                        try std.testing.expect(scope != wrapper_scope);
                        try std.testing.expectEqual(expected_sid, @backingInt(reference.symbol_id));
                        writes += 1;
                    }
                }
            }
            var children = walk.children(transformer.ast, output);
            while (children.next()) |child| if (!child.isNone()) try pending.append(a, .{ .node = child, .scope = scope });
        }
        if (fixture.native_write) try std.testing.expect(writes > 0) else try std.testing.expectEqual(@as(usize, 0), writes);
    }
}

test "native generator var header store follows forced extra data relocation" {
    const Moving = struct {
        parent: std.mem.Allocator,
        fn alloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, address: usize) ?[*]u8 {
            const self: *@This() = @ptrCast(@alignCast(context));
            return self.parent.rawAlloc(len, alignment, address);
        }
        fn allocator(self: *@This()) std.mem.Allocator {
            return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = std.mem.Allocator.noResize, .remap = std.mem.Allocator.noRemap, .free = std.mem.Allocator.noFree } };
        }
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var moving: Moving = .{ .parent = arena.allocator() };
    const a = moving.allocator();
    const source = "function* run(){for(var first=1,shared=42;first<2;first++){}yield 0;return shared;}";
    var scanner = try Scanner.init(a, source);
    var parser = Parser.init(a, &scanner);
    parser.is_module = true;
    scanner.is_module = true;
    _ = try parser.parse();
    const Analyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer;
    var analyzer = Analyzer.init(a, &parser.ast);
    analyzer.is_module = true;
    try analyzer.analyze();
    const Transformer = @import("transformer.zig").Transformer;
    var transformer = try Transformer.init(a, &parser.ast, .{});
    try transformer.initSymbolIds(analyzer.symbol_ids.items);
    transformer.symbols = analyzer.symbols.items;
    transformer.scopes = analyzer.scopes.items;
    transformer.scope_maps = analyzer.scope_maps.items;
    transformer.scope_owner_map = analyzer.scope_owner_map;
    transformer.node_scope_provenance = analyzer.node_scope_provenance;
    transformer.references = analyzer.references.items;
    transformer.unresolved_references = &analyzer.unresolved_references;
    transformer.semantic_edit_enabled = true;
    var loop: NodeIndex = .none;
    var wrapper_scope: ScopeId = .none;
    for (parser.ast.nodes.items, 0..) |node, raw| {
        if (node.tag == .for_statement) loop = @fromBackingInt(@as(u32, @intCast(raw)));
        if (node.tag == .function_declaration) wrapper_scope = @fromBackingInt(analyzer.scope_owner_map.get(@intCast(raw)).?);
    }
    try std.testing.expect(!loop.isNone() and !wrapper_scope.isNone());
    transformer.current_scope = wrapper_scope;
    transformer.generator_state_machine_scope = wrapper_scope;
    transformer.generator_native_var_scope = wrapper_scope;
    const use_scope = transformer.outputOwnedScope(loop) orelse wrapper_scope;
    const slot = transformer.ast.getNode(loop).data.extra;
    const old_head = transformer.readNodeIdx(slot, 0);
    const ids = [_]u32{ @intCast(analyzer.scope_maps.items[wrapper_scope.toIndex()].get("first").?), @intCast(analyzer.scope_maps.items[wrapper_scope.toIndex()].get("shared").?) };
    try transformer.ast.extra_data.shrinkAndFreePrecise(a, transformer.ast.extra_data.items.len);
    const before = transformer.ast.extra_data.items.ptr;
    _ = try ES2015Generator(Transformer).rewriteNativeStateVars(&transformer, loop, wrapper_scope);
    try std.testing.expect(before != transformer.ast.extra_data.items.ptr);
    const head = transformer.readNodeIdx(slot, 0);
    try std.testing.expect(head != old_head);
    const sequence = transformer.ast.getNode(head);
    try std.testing.expectEqual(Tag.sequence_expression, sequence.tag);
    try std.testing.expectEqual(@as(u32, 2), sequence.data.list.len);
    const editor = &transformer.semantic_editor.?;
    for (ids, 0..) |id, i| {
        const assignment = transformer.ast.getNode(@fromBackingInt(transformer.ast.extra_data.items[sequence.data.list.start + i]));
        const lhs = assignment.data.binary.left;
        try std.testing.expectEqual(@as(?u32, id), transformer.getSymbolIdAt(lhs));
        const reference = try editor.referenceForNode(lhs) orelse return error.MissingRelocatedHeaderReference;
        try std.testing.expect(reference.flags.write and !reference.flags.read);
        try std.testing.expectEqual(use_scope, reference.scope_id);
        try std.testing.expectEqual(wrapper_scope, editor.symbols.items[id].scope_id);
    }
}
