//! Declaration and function visitor helpers for Transformer.

const std = @import("std");
const ast_mod = @import("../../parser/ast.zig");
const Node = ast_mod.Node;
const NodeIndex = ast_mod.NodeIndex;
const NodeList = ast_mod.NodeList;
const token_mod = @import("../../lexer/token.zig");
const Span = token_mod.Span;
const es2015_block_scoping = @import("../es2015_block_scoping.zig");
const es2015_destructuring = @import("../es2015_destructuring.zig");
const es_helpers = @import("../es_helpers.zig");
const emotion_mod = @import("emotion.zig");
const styled_components_mod = @import("styled_components.zig");
const transformer_mod = @import("../transformer.zig");
const Transformer = transformer_mod.Transformer;
const Error = Transformer.Error;
const SymbolKind = @import("../../semantic/symbol.zig").SymbolKind;
const SymbolId = @import("../../semantic/symbol.zig").SymbolId;
const ReferenceFlags = @import("../../semantic/symbol.zig").ReferenceFlags;

/// variable_declaration: extra_data = [kind_flags, list.start, list.len]
/// binding이 destructuring pattern (object/array)인지 판별.
inline fn isBindingPattern(self: *const Transformer, idx: NodeIndex) bool {
    if (idx.isNone()) return false;
    const tag = self.ast.getNode(idx).tag;
    return tag == .object_pattern or tag == .array_pattern;
}

fn postProcessVariableDeclaratorInit(
    self: *Transformer,
    new_name: NodeIndex,
    new_init: NodeIndex,
) Error!NodeIndex {
    var init = new_init;

    // styled-components: tag 를 `.withConfig({displayName})` 로 wrap. fast-path 로 1) 옵션,
    // 2) binding 감지, 3) init.tag == tagged_template_expression 을 사전 거른 뒤에만
    // 본 helper 호출. var_name 은 block-scoping rename 후 안전하도록 new_name 에서 읽음.
    if (!new_name.isNone() and styled_components_mod.shouldAttemptWrap(self, init)) {
        const new_name_node = self.ast.getNode(new_name);
        if (new_name_node.tag == .binding_identifier or new_name_node.tag == .identifier_reference) {
            const var_name = self.ast.getText(new_name_node.data.string_ref);
            init = try styled_components_mod.wrapStyledTagInExpr(self, init, var_name);
        }
    }
    // emotion autoLabel: const X = css`...` → css`label:X;...`
    if (self.options.emotion and !new_name.isNone() and !init.isNone()) {
        const new_name_node = self.ast.getNode(new_name);
        if (new_name_node.tag == .binding_identifier or new_name_node.tag == .identifier_reference) {
            const var_name = self.ast.getText(new_name_node.data.string_ref);
            init = try emotion_mod.maybeTransformEmotionTemplate(self, init, var_name);
        }
    }
    // styled-components named helper minify: const X = css`...` / keyframes`...` 등.
    // helper 는 컴포넌트가 아니라 CSS 조각이라 displayName/componentId 는 안 붙임.
    if (self.options.styled_components and !init.isNone()) {
        init = try styled_components_mod.maybeMinifyHelperTemplate(self, init);
    }
    // React Fast Refresh: `const Foo = () => ...` / `const Foo = function() {...}` 등록
    // (function declaration 은 visitFunction 단계에서 자체 이름으로 등록됨).
    if (!new_name.isNone() and !init.isNone()) {
        const name_node = self.ast.getNode(new_name);
        if (name_node.tag == .binding_identifier) {
            const binding_text = self.ast.getText(name_node.data.string_ref);
            try self.maybeRegisterRefreshComponentByBinding(init, new_name, binding_text);
        }
    }

    return init;
}

pub fn visitVariableDeclaration(self: *Transformer, node: Node) Error!NodeIndex {
    // ES2015: destructuring pattern → 개별 declarator로 분해
    // ES2018: object rest (...rest) → __rest 호출 (target < es2018)
    if (self.options.unsupported.destructuring) {
        if (es2015_destructuring.ES2015Destructuring(Transformer).hasDestructuring(self, node)) {
            return es2015_destructuring.ES2015Destructuring(Transformer).lowerDestructuringDeclaration(self, node);
        }
    } else if (self.options.unsupported.object_spread) {
        if (es2015_destructuring.ES2015Destructuring(Transformer).hasObjectRest(self, node)) {
            return es2015_destructuring.ES2015Destructuring(Transformer).lowerDestructuringDeclaration(self, node);
        }
    }
    const e = node.data.extra;
    const orig_kind = self.ast.variableDeclarationKind(node);
    const saved_in_const = self.in_const_declaration;
    self.in_const_declaration = orig_kind == .@"const";
    defer self.in_const_declaration = saved_in_const;

    // `const re = /.../` 추적 — String.replace 의 named group 매핑 lookup 용 (#1473).
    // const 만 추적: let/var 는 재할당 가능해 추적 결과를 신뢰할 수 없음.
    if (self.options.unsupported.regex_named_groups and orig_kind == .@"const") {
        self.collectConstRegexDeclarators(self.readU32(e, 1), self.readU32(e, 2)) catch {};
    }
    const kind = if (self.options.unsupported.block_scoping)
        es2015_block_scoping.lowerKind(orig_kind)
    else
        orig_kind;

    // let/const → var 변환 시: 초기화 없는 declarator에 = void 0 추가.
    // let은 블록 스코프로 매 반복 새 바인딩이지만, var는 hoisted되어 이전 값 유지.
    // Metro(Babel)와 동일하게 명시적 undefined 초기화로 의미론 보존.
    //
    // 단, for-in/for-of/for-await-of 헤더의 left는 매 반복 루프가 바인딩에 쓰므로
    // `= void 0`이 불필요하고, 오히려 `for (var k = void 0 in obj)` 는 Annex B
    // legacy 구문(for-in 전용, 비-strict)이라 codegen이 `k = void 0;` 로 hoist해
    // 선언 전에 토해내 strict mode ReferenceError를 유발 (#1386).
    const needs_void_init = self.options.unsupported.block_scoping and
        orig_kind.isLexical() and
        !self.in_for_in_of_header;

    const list_start = self.readU32(e, 1);
    const list_len = self.readU32(e, 2);

    if (needs_void_init) {
        const scratch_top = self.scratch.items.len;
        defer self.scratch.shrinkRetainingCapacity(scratch_top);

        var i_loop: u32 = 0;
        while (i_loop < list_len) : (i_loop += 1) {
            const raw_idx = self.ast.extra_data.items[list_start + i_loop];
            const decl = self.ast.getNode(@fromBackingInt(@intCast(raw_idx)));
            if (decl.tag != .variable_declarator) {
                const new_node = try self.visitNode(@fromBackingInt(@intCast(raw_idx)));
                if (!new_node.isNone()) try self.scratch.append(self.allocator, new_node);
                continue;
            }
            const de = decl.data.extra;
            const name_idx = self.readNodeIdx(de, 0);
            const init_idx = self.readNodeIdx(de, 2);
            const new_name = try self.visitNode(name_idx);

            if (init_idx.isNone()) {
                // let x; → var x = void 0;
                // 단 destructuring pattern (`let {x}`, `let [x]`)은 init 추가 금지 —
                // for-of/for-in의 left에서 매 반복 iter value를 받으며, `{x} = void 0` 같은
                // statement는 block_statement로 잘못 파싱되어 syntax error (#1302).
                const is_destructuring = isBindingPattern(self, new_name);
                const none = @backingInt(NodeIndex.none);
                const init_node: u32 = if (is_destructuring)
                    none
                else
                    @backingInt(try es_helpers.makeVoidZero(self, node.span));
                const new_decl = try self.addExtraNode(.variable_declarator, decl.span, &.{ @backingInt(new_name), none, init_node });
                try self.scratch.append(self.allocator, new_decl);
            } else {
                // es5 경로(let/const → var)도 익명 클래스 이름 추론을 지킨다 (#4723).
                var new_init = try self.visitNode(try nameAnonymousConstClass(self, name_idx, init_idx));
                new_init = try postProcessVariableDeclaratorInit(self, new_name, new_init);
                const none = @backingInt(NodeIndex.none);
                const new_decl = try self.addExtraNode(.variable_declarator, decl.span, &.{ @backingInt(new_name), none, @backingInt(new_init) });
                try self.scratch.append(self.allocator, new_decl);
            }
        }

        const new_list = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
        return self.addExtraNode(.variable_declaration, node.span, &.{ @backingInt(kind), new_list.start, new_list.len });
    }

    const new_list = try self.visitExtraList(.{ .start = list_start, .len = list_len });
    return self.addExtraNode(.variable_declaration, node.span, &.{ @backingInt(kind), new_list.start, new_list.len });
}

/// variable_declarator: extra_data = [name, type_ann, init]
pub fn visitVariableDeclarator(self: *Transformer, node: Node) Error!NodeIndex {
    const e = node.data.extra;
    const new_name = try self.visitNode(self.readNodeIdx(e, 0));
    const init_idx = try nameAnonymousConstClass(self, self.readNodeIdx(e, 0), self.readNodeIdx(e, 2));
    var new_init = try self.visitNode(init_idx);
    new_init = try postProcessVariableDeclaratorInit(self, new_name, new_init);
    const none = @backingInt(NodeIndex.none);
    return self.addExtraNode(.variable_declarator, node.span, &.{ @backingInt(new_name), none, @backingInt(new_init) });
}

/// function/function_declaration/function_expression/arrow_function_expression
/// extra_data = [name, params_start, params_len, body, flags, return_type]
///
/// parameter property 변환:
///   constructor(public x: number) {} →
///   constructor(x) { this.x = x; }
pub fn visitFunction(self: *Transformer, node: Node, source_idx: NodeIndex) Error!NodeIndex {
    const e = node.data.extra;

    // TS function overload signature: body가 없으면 제거
    // function foo(): void;  ← overload signature (body 없음)
    // function foo(x: number): void;  ← overload signature
    // function foo(x?: number) {}  ← 구현체 (body 있음)
    if (self.readNodeIdx(e, 2).isNone()) return NodeIndex.none;

    const saved_extracted_body = self.in_extracted_fn_body;
    self.in_extracted_fn_body = false;
    defer self.in_extracted_fn_body = saved_extracted_body;

    // 함수 경계 — 바깥 함수의 라벨은 여기서 보이지 않는다 (#4722).
    try self.label_scope.append(self.allocator, null);
    defer _ = self.label_scope.pop();

    // 일반 함수는 자체 this 바인딩을 가지므로 depth 증가.
    // static block 안에서 function() { this.x } 의 this는 치환하면 안 됨.
    const in_static_block = self.static_block_class_name != null;
    if (in_static_block) self.this_depth += 1;
    defer if (in_static_block) {
        self.this_depth -= 1;
    };

    // ES2015 arrow this/arguments 캡처: 일반 함수는 자체 this/arguments 바인딩을 가짐.
    const capture_frame = es_helpers.pushCaptureFrame(self);
    const saved_native_parameter_list_retained = self.native_parameter_list_retained_for_dynamic_lookup;
    self.native_parameter_list_retained_for_dynamic_lookup = false;
    defer self.native_parameter_list_retained_for_dynamic_lookup = saved_native_parameter_list_retained;
    const saved_arrow_depth = self.arrow_this_depth;
    const saved_needs_this = self.needs_this_var;
    const saved_needs_args = self.needs_arguments_var;
    const saved_super_alias = self.super_call_this_alias;
    self.arrow_this_depth = 0;
    self.needs_this_var = false;
    self.needs_arguments_var = false;
    self.super_call_this_alias = false;

    // ES2015 new.target: 일반 함수 → function_named 컨텍스트
    const saved_new_target_ctx = self.new_target_ctx;
    if (self.options.unsupported.new_target) {
        const name_idx = self.readNodeIdx(e, 0);
        if (!name_idx.isNone()) {
            self.new_target_ctx = .{ .function_named = .{ .span = self.ast.getNode(name_idx).span, .node = name_idx } };
        } else {
            // 익명 함수: new.target → void 0 (이름 없으므로 instanceof 불가)
            self.new_target_ctx = .method;
        }
    }
    defer self.new_target_ctx = saved_new_target_ctx;

    // 임시 변수 카운터 저장 (함수 스코프 내 사용된 임시 변수 호이스팅용)
    const saved_temp_counter = self.temp_var_counter;

    const new_name = try self.visitNode(self.readNodeIdx(e, 0));

    // 파라미터 방문 + parameter property 수집
    const params_idx_old = self.readNodeIdx(e, 1);
    var params_span = node.span;
    var params_list_old = NodeList{ .start = 0, .len = 0 };
    if (!params_idx_old.isNone()) {
        const pnode = self.ast.getNode(params_idx_old);
        if (pnode.tag == .formal_parameters) {
            params_list_old = pnode.data.list;
            params_span = pnode.span;
        }
    }
    if (self.options.unsupported.arrow and self.options.unsupported.default_params and params_list_old.len > 0) {
        const Params = @import("../es2015_params.zig").ES2015Params(Transformer);
        if (Params.hasDefaultOrRest(self, params_list_old)) {
            const parameter_environment = @import("../parameter_environment.zig");
            const function_scope = self.outputOwnedScope(source_idx) orelse self.current_scope;
            const params_have_dynamic_lookup = try parameter_environment.parameterListHasDynamicLookup(self, params_list_old);
            const body_has_dynamic_lookup = try parameter_environment.functionBodyHasDynamicLookup(
                self,
                function_scope,
                self.readNodeIdx(e, 2),
            );
            self.native_parameter_list_retained_for_dynamic_lookup =
                params_have_dynamic_lookup or body_has_dynamic_lookup;
        }
    }
    const scratch_top = self.scratch.items.len;
    defer self.scratch.shrinkRetainingCapacity(scratch_top);

    const param_capture_use_start = self.lexical_capture_uses.items.len;
    var pp = blk: {
        const saved_parameter_scope = self.current_scope;
        defer self.current_scope = saved_parameter_scope;
        if (!params_idx_old.isNone()) {
            if (self.outputOwnedScope(params_idx_old)) |parameter_scope| self.current_scope = parameter_scope;
        }
        break :blk try self.visitParamsCollectProperties(params_list_old);
    };
    defer pp.prop_names.deinit(self.allocator);
    // Native parameter initializers cannot see the body's `var`s: temps they
    // allocate stay with the enclosing function, as an arrow's do (#5552).
    const body_temp_start = if (!self.options.unsupported.default_params or self.native_parameter_list_retained_for_dynamic_lookup)
        self.temp_var_counter
    else
        saved_temp_counter;
    const param_needs_this = self.needs_this_var;
    const param_needs_arguments = self.needs_arguments_var;
    const param_needs_new_target = self.hasLexicalCaptureSince(param_capture_use_start, capture_frame.active_frame, .new_target_value);

    // 바디 방문
    const old_body_idx = self.readNodeIdx(e, 2);
    var new_body = try self.visitBodyWorkletAware(old_body_idx);

    // parameter property가 있으면 바디 앞에 this.x = x 문 삽입
    if (pp.prop_names.items.len > 0 and !new_body.isNone()) {
        new_body = try self.insertParameterPropertyAssignments(new_body, pp.prop_names.items);
    }

    // ES2015 arrow this/arguments 캡처: 이 함수 안의 arrow가 this/arguments를 사용했으면
    // var _this = this; / var _arguments = arguments; 를 바디 앞에 삽입.
    const needs_new_target_capture = self.hasLexicalCapture(capture_frame.active_frame, .new_target_value);
    if ((self.options.unsupported.arrow or @import("../live_arguments.zig").ownerCell(self) != null) and !new_body.isNone() and
        (self.needs_this_var or self.needs_arguments_var or needs_new_target_capture))
    {
        var capture_stmts: [3]NodeIndex = undefined;
        var capture_count: usize = 0;

        if (self.needs_this_var) {
            const this_init = try self.ast.addNode(.{
                .tag = .this_expression,
                .span = node.span,
                .data = .{ .none = 0 },
            });
            capture_stmts[capture_count] = try self.buildVarDecl("_this", this_init, node.span);
            try self.bindLexicalCapture(capture_stmts[capture_count], .this_value);
            capture_count += 1;
        }
        if (self.needs_arguments_var) {
            capture_stmts[capture_count] = try es_helpers.makeArgumentsCaptureDeclaration(self, node.span);
            capture_count += 1;
        }
        if (needs_new_target_capture) {
            capture_stmts[capture_count] = try es_helpers.buildNewTargetCapture(self, node.span);
            capture_count += 1;
        }

        try es_helpers.recordParameterCaptures(self, capture_stmts[0..capture_count], param_needs_this, param_needs_arguments, param_needs_new_target);

        new_body = try self.prependStatementsToBody(new_body, capture_stmts[0..capture_count]);
    }

    // 임시 변수 호이스팅: 이 함수 안에서 사용된 _a, _b, ... 선언을 body 앞에 삽입
    if (self.temp_var_counter > body_temp_start and !new_body.isNone()) {
        new_body = if (self.semantic_edit_enabled)
            try self.hoistTempVarsInOriginalFunction(new_body, body_temp_start, node.span)
        else
            try self.hoistTempVars(new_body, body_temp_start, node.span);
    }
    // 함수 스코프 종료 — outer scope 의 hoistTempVars 가 같은 _a 를 다시 hoist 하지 않도록
    // 카운터 복원 (#1960). 다음 함수 / outer 에서 동일 이름을 안전하게 재사용 가능.
    self.temp_var_counter = body_temp_start;

    // arrow 캡처 상태 복원
    self.arrow_this_depth = saved_arrow_depth;
    self.needs_this_var = saved_needs_this;
    self.needs_arguments_var = saved_needs_args;
    self.super_call_this_alias = saved_super_alias;
    es_helpers.popCaptureFrame(self, capture_frame);

    // React Fast Refresh — hook signature opt-in. default off 면 visitFunction
    // hot path 영향 0 (옵션 read + early-return). opt-in 시 babel-plugin-react-refresh
    // 동등 emit. `findHookCallsInNodeDepth` 가 depth=50 + node tag whitelist +
    // bounds check 로 stale 인덱스 방어.
    if (self.refreshEnabled() and self.options.react_refresh_hook_signatures) {
        const fn_name_for_sig: ?[]const u8 = blk: {
            if (new_name.isNone()) break :blk null;
            const name_node = self.ast.getNode(new_name);
            if (name_node.tag != .binding_identifier and name_node.tag != .identifier_reference) break :blk null;
            break :blk self.ast.getText(name_node.data.string_ref);
        };
        try self.maybeRegisterRefreshSignature(fn_name_for_sig, new_name, old_body_idx, &new_body);
    }

    const none = @backingInt(NodeIndex.none);
    const new_params_node = try self.ast.addFormalParameters(pp.new_params, params_span);
    if (self.semantic_edit_enabled) try self.remapCopiedScopeOwner(params_idx_old, new_params_node);
    const result = try self.addExtraNode(node.tag, node.span, &.{
        @backingInt(new_name), @backingInt(new_params_node),
        @backingInt(new_body), self.readU32(e, 3),
        none,
    });

    try @import("../native_noop_graph.zig").recordFunctionFormals(self, source_idx, result, params_idx_old, new_params_node);

    try @import("../worklet_class_clone.zig").transferFactoryFunctionOwner(self, source_idx, result);

    // Plugin dispatch: onFunction (AST 훅)
    const is_auto_worklet = self.plugins.worklet.auto_next;
    const plugin_insertion_scope = self.functionListInsertionScope(source_idx);
    if (try self.dispatchFunctionPlugins(result, .{
        .node_idx = result,
        .node_tag = node.tag,
        .name = self.getFunctionName(self.ast.getNode(result)),
        .body_idx = new_body,
        .params = pp.new_params,
        .original_params = params_list_old,
        .original_body_idx = old_body_idx,
        .flags = self.readU32(e, 3),
        .source_path = self.options.jsx_filename,
        .is_auto_worklet = is_auto_worklet,
    }, plugin_insertion_scope)) |replacement| {
        return replacement;
    }

    // React Fast Refresh: PascalCase 함수 → 컴포넌트 등록
    try self.maybeRegisterRefreshComponent(result);

    return result;
}

/// 파라미터 목록을 방문하면서 parameter property (public x 등)를 감지.
/// modifier를 제거하고 this.x = x 삽입용 이름을 수집한다.
/// caller 는 반환된 result.prop_names 를 `deinit(self.allocator)` 해야 함.
pub const ParamPropertyResult = struct {
    new_params: NodeList,
    prop_names: std.ArrayList(NodeIndex),
};

pub fn visitParamsCollectProperties(self: *Transformer, vp: NodeList) Error!ParamPropertyResult {
    const scratch_top = self.scratch.items.len;
    defer self.scratch.shrinkRetainingCapacity(scratch_top);

    var result = ParamPropertyResult{
        .new_params = NodeList{ .start = 0, .len = 0 },
        .prop_names = .empty,
    };
    errdefer result.prop_names.deinit(self.allocator);

    // visitNode가 AST를 변형하므로 인덱스 루프 사용
    var i_loop: u32 = 0;
    while (i_loop < vp.len) : (i_loop += 1) {
        const raw_idx = self.ast.extra_data.items[vp.start + i_loop];
        const param_idx: NodeIndex = @fromBackingInt(@intCast(raw_idx));
        if (param_idx.isNone()) continue;
        const param_node = self.ast.getNode(param_idx);
        // formal_parameter: extra = [pattern, type_ann, default, flags, deco_start, deco_len]
        // flags != 0 → parameter property (public/private/protected/readonly/override)
        if (param_node.tag == .formal_parameter and self.ast.extra_data.items[param_node.data.extra + ast_mod.FormalParameterExtra.flags] != 0) {
            const inner = try self.visitNode(@fromBackingInt(@intCast(self.ast.extra_data.items[param_node.data.extra + ast_mod.FormalParameterExtra.pattern])));
            try self.scratch.append(self.allocator, inner);
            if (parameterPropertyBindingName(self, inner)) |binding| {
                try result.prop_names.append(self.allocator, binding);
            }
        } else {
            const new_param = try self.visitParameterNode(@fromBackingInt(@intCast(raw_idx)));
            if (!new_param.isNone()) {
                try self.scratch.append(self.allocator, new_param);
            }
        }
    }

    result.new_params = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
    return result;
}

fn parameterPropertyBindingName(self: *Transformer, idx: NodeIndex) ?NodeIndex {
    if (idx.isNone()) return null;
    const node = self.ast.getNode(idx);
    return switch (node.tag) {
        .binding_identifier => idx,
        .assignment_pattern => parameterPropertyBindingName(self, node.data.binary.left),
        .formal_parameter => parameterPropertyBindingName(self, self.readNodeIdx(node.data.extra, ast_mod.FormalParameterExtra.pattern)),
        else => null,
    };
}

/// `this.x = x;` 형태의 expression_statement 노드들을 만들어 반환한다.
/// ES5 다운레벨링에서 derived class 는 super() 뒤에 _this 별칭으로 emit,
/// base class 는 body 앞에 prepend — caller 가 결정한다.
/// 결과 slice 는 transformer 의 NodeList 풀에 등록되므로 즉시 소비할 것.
pub fn buildParameterPropertyStatements(self: *Transformer, prop_names: []const NodeIndex) Error!NodeList {
    const scratch_top = self.scratch.items.len;
    defer self.scratch.shrinkRetainingCapacity(scratch_top);
    for (prop_names) |name_idx| {
        const name_node = self.ast.getNode(name_idx);
        const this_node = try self.ast.addNode(.{
            .tag = .this_expression,
            .span = name_node.span,
            .data = .{ .none = 0 },
        });
        const key = try es_helpers.makePropertyName(self, self.ast.getText(name_node.data.string_ref));
        const value = if (self.semantic_edit_enabled) blk: {
            const id = self.getSymbolIdAt(name_idx) orelse @panic("parameter property lost its source binding SID");
            const symbols = if (self.semantic_editor) |*editor| editor.symbols.items else self.symbols;
            break :blk try es_helpers.makeTempRefFromIdentity(self, .{ .span = name_node.data.string_ref, .symbol_id = @fromBackingInt(id), .owner_scope = symbols[id].scope_id, .reference_scope = self.current_scope }, name_node.span, .{ .read = true });
        } else try es_helpers.makeIdentifierRefFromSpan(self, name_node.data.string_ref);
        const member_extra = try self.ast.addExtras(&.{ @backingInt(this_node), @backingInt(key), 0 });
        const member = try self.ast.addNode(.{
            .tag = .static_member_expression,
            .span = name_node.span,
            .data = .{ .extra = member_extra },
        });
        const assign = try self.ast.addNode(.{
            .tag = .assignment_expression,
            .span = name_node.span,
            .data = .{ .binary = .{ .left = member, .right = value, .flags = 0 } },
        });
        const stmt = try self.ast.addNode(.{
            .tag = .expression_statement,
            .span = name_node.span,
            .data = .{ .unary = .{ .operand = assign, .flags = 0 } },
        });
        try self.scratch.append(self.allocator, stmt);
    }
    return try self.ast.addNodeList(self.scratch.items[scratch_top..]);
}

/// derived class constructor 의 super() 직후에 this.x = x; 문들을 삽입한다.
/// (kept-class 경로 — visitMethodDefinition. ES5 lowering 은 postProcessDerivedConstructorBody 사용).
pub fn insertParameterPropertyAssignmentsAfterSuper(self: *Transformer, body_idx: NodeIndex, prop_names: []const NodeIndex) Error!NodeIndex {
    // `buildParameterPropertyStatements` 가 생성한 statement 인덱스를
    // `extra_data` (stable offset) 에 보관한다. 여기서 곧바로 `self.scratch` 로
    // 복사해 그 슬라이스를 `insertStatementsAfterSuper` 에 넘기면, 그 함수가
    // 다시 `self.scratch.append` 로 scratch 를 키우다 realloc 이 일어나는 순간
    // 넘긴 슬라이스(= 옛 backing buffer 포인터)가 무효화돼 freed 메모리
    // (0xAAAAAAAA) 를 읽는다 (#D23). 따라서 scratch 와 aliasing 되지 않는
    // 별도 힙 버퍼로 복사해 전달한다. extra_data 자체는 stable 하므로
    // 그 슬라이스를 직접 dup 해서 쓰는 것으로 충분하다.
    const pp_list = try self.buildParameterPropertyStatements(prop_names);
    const pp_raw = self.ast.extra_data.items[pp_list.start .. pp_list.start + pp_list.len];
    const stmts = try self.allocator.alloc(NodeIndex, pp_raw.len);
    defer self.allocator.free(stmts);
    for (pp_raw, 0..) |raw_idx, i| stmts[i] = @fromBackingInt(@intCast(raw_idx));
    return self.insertStatementsAfterSuper(body_idx, stmts);
}

/// block_statement 바디 앞에 this.x = x; 문들을 삽입한다 (base class ctor 용).
/// derived class 는 super() 호출 이전에 박으면 super() 후 새 인스턴스에 손실되므로 사용 금지 —
/// `buildParameterPropertyStatements` + `postProcessDerivedConstructorBody` 경로를 사용하라.
pub fn insertParameterPropertyAssignments(self: *Transformer, body_idx: NodeIndex, prop_names: []const NodeIndex) Error!NodeIndex {
    const body = self.ast.getNode(body_idx);
    if (body.tag != .block_statement) return body_idx;

    const old_list = body.data.list;
    const scratch_top = self.scratch.items.len;
    defer self.scratch.shrinkRetainingCapacity(scratch_top);

    const pp_list = try self.buildParameterPropertyStatements(prop_names);
    const pp_stmts = self.ast.extra_data.items[pp_list.start .. pp_list.start + pp_list.len];
    for (pp_stmts) |raw_idx| try self.scratch.append(self.allocator, @fromBackingInt(@intCast(raw_idx)));

    const old_stmts = self.ast.extra_data.items[old_list.start .. old_list.start + old_list.len];
    for (old_stmts) |raw_idx| try self.scratch.append(self.allocator, @fromBackingInt(@intCast(raw_idx)));

    const new_list = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
    return self.ast.addNode(.{
        .tag = .block_statement,
        .span = body.span,
        .data = .{ .list = new_list },
    });
}

/// block_statement / program / function_body 앞에 문들을 삽입한다.
/// body의 첫 super() 호출 이후 위치에 stmts 삽입 — derived class constructor 전용 (#1495).
/// super_call이 없으면 body 앞에 prepend (fallback). body가 block이 아니면 block으로 감싼 뒤 처리.
const ScopeId = @import("../../semantic/scope.zig").ScopeId;

fn isNativeSuperCall(self: *const Transformer, index: NodeIndex) bool {
    if (index.isNone()) return false;
    const node = self.ast.getNode(index);
    return node.tag == .call_expression and
        self.ast.getNode(self.ast.readExtraNode(node.data.extra, 0)).tag == .super_expression;
}

fn hasDeferredNativeSuper(self: *Transformer, root: NodeIndex) Error!bool {
    var stack: std.ArrayList(NodeIndex) = .empty;
    defer stack.deinit(self.allocator);
    try stack.append(self.allocator, root);
    while (stack.pop()) |index| {
        if (index.isNone()) continue;
        const node = self.ast.getNode(index);
        if (node.tag == .class_declaration or node.tag == .class_expression or node.tag == .method_definition) continue;
        if (isNativeSuperCall(self, index)) return true;
        var children = @import("../../parser/ast_walk.zig").children(self.ast, node);
        while (children.next()) |child| try stack.append(self.allocator, child);
    }
    return false;
}

/// Move this already-created initializer fragment at its actual execution
/// site. Existing IDs and flags remain authoritative across the handoff.
fn placeNativeInitializer(self: *Transformer, statement: NodeIndex, from: ScopeId, to: ScopeId) Error!void {
    if (!self.semantic_edit_enabled or from == to) return;
    const editor = &self.semantic_editor.?;
    const Saved = struct { node: NodeIndex, origin: @import("../native_constructor_guard.zig").ReferenceOrigin };
    var origins: std.ArrayList(Saved) = .empty;
    defer origins.deinit(self.allocator);
    var stack: std.ArrayList(NodeIndex) = .empty;
    defer stack.deinit(self.allocator);
    try stack.append(self.allocator, statement);
    while (stack.pop()) |index| {
        if (index.isNone()) continue;
        const raw = @backingInt(index);
        if (self.native_constructor_reference_origins.get(raw)) |origin| {
            const row = (editor.referenceForNode(index) catch @panic("initializer reference index is invalid")) orelse @panic("initializer origin lost its reference");
            if (row.symbol_id != origin.symbol_id or row.scope_id != origin.scope or !std.meta.eql(row.flags, origin.flags))
                @panic("initializer placement changed its creation identity");
            try origins.append(self.allocator, .{ .node = index, .origin = origin });
        }
        if (self.exact_output_ref_scope_ids.getPtr(raw)) |scope| {
            if (scope.* == @backingInt(from)) scope.* = @backingInt(to);
        }
        var children = @import("../../parser/ast_walk.zig").children(self.ast, self.ast.getNode(index));
        while (children.next()) |child| try stack.append(self.allocator, child);
    }
    try @import("../class_strict_context.zig").moveSourceReferences(self, statement, from, from, to);
    try self.reparentGeneratedBodyScopes(from, to, statement);
    for (origins.items) |saved| {
        const expected = if (saved.origin.scope == from) to else saved.origin.scope;
        const row = (editor.referenceForNode(saved.node) catch @panic("initializer moved reference index is invalid")) orelse @panic("initializer placement dropped its reference");
        if (row.symbol_id != saved.origin.symbol_id or row.scope_id != expected or !std.meta.eql(row.flags, saved.origin.flags))
            @panic("initializer placement lost its exact identity");
        try @import("../native_constructor_guard.zig").recordReference(self, saved.node, saved.origin.symbol_id, expected, saved.origin.flags);
    }
}

/// Every physical super site owns its initializer AST and owned bindings.
/// Additional sites are cloned before moving the original fragment.
const SuperSite = struct { node: NodeIndex, scope: ScopeId, constructor_scope: ScopeId, alias: NodeIndex };

pub const LoweredConstructorOwner = struct {
    frame: u32,
    scope: ScopeId,
    target: ?SymbolId,
};
pub const LoweredSiteError = std.mem.Allocator.Error || error{ InvalidScope, InvalidSymbol, InvalidNode };

/// Non-owning access to an actual graph. Finished certificates use its const
/// slices; creators retain the editor's indexed uniqueness checks.
pub const LoweredSiteGraph = struct {
    symbols: []const @import("../../semantic/symbol.zig").Symbol,
    scopes: []const @import("../../semantic/scope.zig").Scope,
    symbol_ids: []const ?u32,
    references: []const @import("../../semantic/symbol.zig").Reference,
    editor: ?*@import("../../semantic/editor.zig").SemanticEditor = null,

    fn getSymbolIdAt(self: *const @This(), node: NodeIndex) ?u32 {
        if (node.isNone() or @backingInt(node) >= self.symbol_ids.len) return null;
        return self.symbol_ids[@backingInt(node)];
    }

    fn referenceForNode(self: *const @This(), node: NodeIndex) LoweredSiteError!?@import("../../semantic/symbol.zig").Reference {
        if (self.editor) |editor| return editor.referenceForNode(node) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidNode,
        };
        if (node.isNone()) return error.InvalidNode;
        var found: ?@import("../../semantic/symbol.zig").Reference = null;
        for (self.references) |row| {
            if (row.node_index != node) continue;
            if (found != null) return error.InvalidNode;
            found = row;
        }
        return found;
    }
};

const LoweredSiteNodes = struct { node: Node, result_assignment: Node, call: Node, check: Node };

fn validateLoweredSuperSyntax(ast: *const ast_mod.Ast, index: NodeIndex, marker: Transformer.GeneratedSuperCall, owner: LoweredConstructorOwner, use_scope: ScopeId) LoweredSiteError!LoweredSiteNodes {
    if (marker.native or index.isNone() or @backingInt(index) >= ast.nodes.items.len) return error.InvalidNode;
    if (marker.constructor_frame != owner.frame or marker.constructor_scope != owner.scope or marker.use_scope != use_scope) return error.InvalidScope;
    if (marker.target_symbol != owner.target or !std.meta.eql(marker.flags, ReferenceFlags{ .write = true })) return error.InvalidSymbol;
    const node = ast.getNode(index);
    if (node.tag != .assignment_expression or node.data.binary.right.isNone() or
        marker.result_assignment.isNone() or @backingInt(marker.result_assignment) >= ast.nodes.items.len) return error.InvalidNode;
    const result_assignment = ast.getNode(marker.result_assignment);
    if (result_assignment.tag != .assignment_expression or result_assignment.data.binary.right.isNone()) return error.InvalidNode;
    const call = ast.getNode(result_assignment.data.binary.right);
    if (call.tag != .call_expression) return error.InvalidNode;
    if (marker.evaluation_sequence.isNone() or @backingInt(marker.evaluation_sequence) >= ast.nodes.items.len) return error.InvalidNode;
    const evaluation = ast.getNode(marker.evaluation_sequence);
    if (evaluation.tag != .sequence_expression or evaluation.data.list.len != 3 or
        ast.readExtraNode(evaluation.data.list.start, 0) != marker.result_assignment) return error.InvalidNode;
    const binding_site = ast.readExtraNode(evaluation.data.list.start, 2);
    if (binding_site != index) {
        const placed = ast.getNode(binding_site);
        if (placed.tag != .sequence_expression or placed.data.list.len < 3 or
            ast.readExtraNode(placed.data.list.start, 0) != index) return error.InvalidNode;
    }
    const check = ast.getNode(ast.readExtraNode(evaluation.data.list.start, 1));
    if (check.tag != .call_expression or ast.readExtra(check.data.extra, 2) != 1) return error.InvalidNode;
    return .{ .node = node, .result_assignment = result_assignment, .call = call, .check = check };
}

fn validateLoweredSuperSemantics(ast: *const ast_mod.Ast, marker: Transformer.GeneratedSuperCall, owner: LoweredConstructorOwner, use_scope: ScopeId, nodes: LoweredSiteNodes, graph: LoweredSiteGraph) LoweredSiteError!void {
    const node = nodes.node;
    const result_assignment = nodes.result_assignment;
    const call = nodes.call;
    const check = nodes.check;
    if (marker.pending_result_producer_id != 0) return error.InvalidSymbol;
    if (owner.scope.isNone() or use_scope.isNone() or owner.scope.toIndex() >= graph.scopes.len or use_scope.toIndex() >= graph.scopes.len or graph.scopes[owner.scope.toIndex()].kind != .function) return error.InvalidScope;
    const target = graph.getSymbolIdAt(node.data.binary.left) orelse return error.InvalidSymbol;
    if (target >= graph.symbols.len or graph.symbols[target].scope_id != owner.scope or graph.symbols[target].kind != .variable_var) return error.InvalidSymbol;
    const result_id = marker.result_symbol orelse return error.InvalidSymbol;
    if (@backingInt(result_id) >= graph.symbols.len or marker.result_scope.isNone() or
        marker.result_scope.toIndex() >= graph.scopes.len or
        graph.scopes[marker.result_scope.toIndex()].kind != .function or
        graph.symbols[@backingInt(result_id)].scope_id != marker.result_scope or
        graph.symbols[@backingInt(result_id)].kind != .variable_var) return error.InvalidSymbol;
    if (graph.getSymbolIdAt(result_assignment.data.binary.left) != @backingInt(result_id) or
        graph.getSymbolIdAt(node.data.binary.right) != @backingInt(result_id)) return error.InvalidSymbol;
    for ([_]struct { node: NodeIndex, flags: ReferenceFlags }{
        .{ .node = result_assignment.data.binary.left, .flags = .{ .write = true } },
        .{ .node = node.data.binary.right, .flags = .{ .read = true } },
    }) |use| {
        const result_row = (graph.referenceForNode(use.node) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidNode,
        }) orelse return error.InvalidNode;
        if (result_row.scope_id != use_scope) return error.InvalidScope;
        if (result_row.symbol_id != result_id or !std.meta.eql(result_row.flags, use.flags)) return error.InvalidSymbol;
    }
    const callee = ast.readExtraNode(call.data.extra, 0);
    const callee_id = graph.getSymbolIdAt(callee) orelse return error.InvalidSymbol;
    if (marker.target_symbol != @as(SymbolId, @fromBackingInt(target)) or marker.callee_symbol != @as(SymbolId, @fromBackingInt(callee_id))) return error.InvalidSymbol;
    const row = (graph.referenceForNode(node.data.binary.left) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidNode,
    }) orelse return error.InvalidNode;
    if (row.scope_id != use_scope) return error.InvalidScope;
    if (row.symbol_id != marker.target_symbol.? or !std.meta.eql(row.flags, marker.flags)) return error.InvalidSymbol;
    const call_row = (graph.referenceForNode(callee) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidNode,
    }) orelse return error.InvalidNode;
    if (call_row.scope_id != use_scope) return error.InvalidScope;
    if (call_row.symbol_id != marker.callee_symbol.? or !call_row.flags.read) return error.InvalidSymbol;
    const check_callee = ast.readExtraNode(check.data.extra, 0);
    const live_this = ast.readExtraNode(ast.readExtra(check.data.extra, 1), 0);
    for ([_]struct { node: NodeIndex, id: ?SymbolId }{
        .{ .node = check_callee, .id = marker.check_symbol },
        .{ .node = live_this, .id = marker.target_symbol },
    }) |use| {
        const expected = use.id orelse return error.InvalidSymbol;
        if (graph.getSymbolIdAt(use.node) != @backingInt(expected)) return error.InvalidSymbol;
        const check_row = (graph.referenceForNode(use.node) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidNode,
        }) orelse return error.InvalidNode;
        if (check_row.scope_id != use_scope) return error.InvalidScope;
        if (check_row.symbol_id != expected or !std.meta.eql(check_row.flags, ReferenceFlags{ .read = true })) return error.InvalidSymbol;
    }
}

pub fn validateLoweredSuperSite(self: *Transformer, index: NodeIndex, marker: Transformer.GeneratedSuperCall, owner: LoweredConstructorOwner, use_scope: ScopeId) LoweredSiteError!void {
    const nodes = try validateLoweredSuperSyntax(self.ast, index, marker, owner, use_scope);
    if (!self.semantic_edit_enabled) return;
    const editor = if (self.semantic_editor) |*value| value else return error.InvalidNode;
    return validateLoweredSuperSemantics(self.ast, marker, owner, use_scope, nodes, .{
        .symbols = editor.symbols.items,
        .scopes = editor.scopes.items,
        .symbol_ids = self.symbol_ids.items,
        .references = editor.references.items,
        .editor = editor,
    });
}

/// Validate a completed owner's exact arrays without reconstructing or
/// temporarily reattaching a SemanticEditor after its finish boundary.
pub fn validateLoweredSuperSiteInGraph(ast: *const ast_mod.Ast, index: NodeIndex, marker: Transformer.GeneratedSuperCall, owner: LoweredConstructorOwner, use_scope: ScopeId, graph: LoweredSiteGraph) LoweredSiteError!void {
    const nodes = try validateLoweredSuperSyntax(ast, index, marker, owner, use_scope);
    return validateLoweredSuperSemantics(ast, marker, owner, use_scope, nodes, graph);
}

/// Only creator-recorded lowered calls belonging to this constructor frame
/// are candidates. Traversal supplies actual use scopes, never binding IDs.
pub fn insertLoweredSuperInitializers(self: *Transformer, body: NodeIndex, statements: []const NodeIndex) Error!NodeIndex {
    if (statements.len == 0) return body;
    const owner = self.active_derived_constructor_new_target orelse @panic("lowered initializer has no constructor handle");
    if (owner.capture_frame != self.capture_frame or owner.owner_scope != self.current_scope)
        @panic("lowered initializer lost its exact constructor frame");
    const Work = struct { node: NodeIndex, scope: ScopeId };
    var stack: std.ArrayList(Work) = .empty;
    defer stack.deinit(self.allocator);
    var sites: std.ArrayList(SuperSite) = .empty;
    defer sites.deinit(self.allocator);
    try stack.append(self.allocator, .{ .node = body, .scope = owner.owner_scope });
    while (stack.pop()) |work| {
        if (work.node.isNone()) continue;
        const node = self.ast.getNode(work.node);
        const scope = self.outputOwnedScope(work.node) orelse work.scope;
        if (self.generated_super_call_assignments.get(@backingInt(work.node))) |source_marker| {
            var marker = source_marker;
            if (!marker.native and (marker.constructor_frame == owner.capture_frame or marker.constructor_scope == owner.owner_scope)) {
                if (marker.result_symbol == null and self.semantic_edit_enabled) {
                    // A parameter initializer may have deferred its temp owner.
                    // This actual constructor assembly now owns its placement;
                    // the allocator handle, never its spelling, selects storage.
                    if (marker.constructor_frame != owner.capture_frame or marker.constructor_scope != owner.owner_scope or
                        marker.use_scope != scope or marker.pending_result_producer_id == 0 or marker.result_assignment.isNone())
                        @panic("lowered super result lost its deferred producer");
                    const result_assignment = self.ast.getNode(marker.result_assignment);
                    if (result_assignment.tag != .assignment_expression or node.tag != .assignment_expression)
                        @panic("lowered super result lost its assignment anchors");
                    const result_lhs = result_assignment.data.binary.left;
                    const name_span = self.ast.getNode(result_lhs).data.string_ref;
                    const id = try self.reserveSyntheticTempSymbolForProducerInScope(marker.pending_result_producer_id, name_span, node.span, scope) orelse
                        @panic("lowered super result has no actual owner");
                    for ([_]struct { node: NodeIndex, flags: ReferenceFlags }{
                        .{ .node = result_lhs, .flags = .{ .write = true } },
                        .{ .node = node.data.binary.right, .flags = .{ .read = true } },
                    }) |use| {
                        if (self.getSymbolIdAt(use.node)) |existing| {
                            const row = (self.semantic_editor.?.referenceForNode(use.node) catch |err| switch (err) {
                                error.OutOfMemory => return error.OutOfMemory,
                                else => @panic("lowered super temp has an invalid existing reference"),
                            }) orelse
                                @panic("lowered super temp has no existing reference");
                            if (existing != @backingInt(id) or row.symbol_id != id or row.scope_id != scope or !std.meta.eql(row.flags, use.flags))
                                @panic("lowered super temp changed its producer reference");
                        } else try self.addSyntheticRefInScope(use.node, id, scope, use.flags);
                    }
                    marker.result_symbol = id;
                    marker.pending_result_producer_id = 0;
                    marker.result_scope = self.semantic_editor.?.symbols.items[@backingInt(id)].scope_id;
                    try self.generated_super_call_assignments.put(self.allocator, @backingInt(work.node), marker);
                }
                validateLoweredSuperSite(self, work.node, marker, .{ .frame = owner.capture_frame, .scope = owner.owner_scope, .target = owner.this_symbol_id }, scope) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => std.debug.panic("lowered super changed its creator contract: {s}", .{@errorName(err)}),
                };
                try sites.append(self.allocator, .{ .node = work.node, .scope = scope, .constructor_scope = owner.owner_scope, .alias = node.data.binary.left });
            }
        }
        var children = @import("../../parser/ast_walk.zig").children(self.ast, node);
        while (children.next()) |child| {
            const incoming = if (@import("semantic_edit.zig").childSkipsOutputScope(self.ast, @backingInt(work.node), @backingInt(child))) work.scope else scope;
            try stack.append(self.allocator, .{ .node = child, .scope = incoming });
        }
    }
    return assembleSuperSites(self, body, statements, sites.items);
}

fn insertNativeSuperInitializers(self: *Transformer, body: NodeIndex, statements: []const NodeIndex, derived: bool) Error!?NodeIndex {
    if (!derived) return try self.prependStatementsToBody(body, statements);
    if (statements.len == 0) return body;
    for (statements) |statement| if (self.ast.getNode(statement).tag != .expression_statement) return null;
    const constructor_scope = self.current_scope;
    const Site = SuperSite;
    const Work = struct { node: NodeIndex, scope: ScopeId };
    var stack: std.ArrayList(Work) = .empty;
    defer stack.deinit(self.allocator);
    var suppressed: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer suppressed.deinit(self.allocator);
    var sites: std.ArrayList(Site) = .empty;
    defer sites.deinit(self.allocator);
    try stack.append(self.allocator, .{ .node = body, .scope = self.current_scope });
    while (stack.pop()) |work| {
        if (work.node.isNone()) continue;
        const node = self.ast.getNode(work.node);
        switch (node.tag) {
            .class_declaration, .class_expression, .method_definition, .static_block => continue,
            .function, .function_expression, .function_declaration => {
                if (try hasDeferredNativeSuper(self, work.node)) return null;
                continue;
            },
            .arrow_function_expression => {
                // A retained arrow keeps the source constructor's lexical
                // super environment. Its own ScopeId is the actual use scope;
                // ordinary functions and nested classes remain barriers.
                if (self.options.unsupported.arrow) {
                    if (try hasDeferredNativeSuper(self, work.node)) return null;
                    continue;
                }
            },
            else => {},
        }
        const scope = self.outputOwnedScope(work.node) orelse work.scope;
        if (self.generated_super_call_assignments.contains(@backingInt(work.node)) and
            node.tag == .assignment_expression and isNativeSuperCall(self, node.data.binary.right))
        {
            try suppressed.put(self.allocator, @backingInt(node.data.binary.right), {});
            try sites.append(self.allocator, .{ .node = work.node, .scope = scope, .constructor_scope = constructor_scope, .alias = node.data.binary.left });
        } else if (isNativeSuperCall(self, work.node) and !suppressed.contains(@backingInt(work.node))) {
            try sites.append(self.allocator, .{ .node = work.node, .scope = scope, .constructor_scope = constructor_scope, .alias = .none });
        }
        var children = @import("../../parser/ast_walk.zig").children(self.ast, node);
        while (children.next()) |child| {
            const incoming = if (@import("semantic_edit.zig").childSkipsOutputScope(self.ast, @backingInt(work.node), @backingInt(child))) work.scope else scope;
            try stack.append(self.allocator, .{ .node = child, .scope = incoming });
        }
    }
    if (sites.items.len == 0) return body;
    return try assembleSuperSites(self, body, statements, sites.items);
}

fn assembleSuperSites(self: *Transformer, body: NodeIndex, statements: []const NodeIndex, sites: []const SuperSite) Error!NodeIndex {
    if (sites.len == 0) return body;
    try @import("../initializer_clone.zig").bindPendingCaptures(self, statements);
    var clones: std.ArrayList(@import("../../semantic/runtime_subtree_clone.zig").Result) = .empty;
    defer {
        for (clones.items) |*copy| copy.deinit(self.allocator);
        clones.deinit(self.allocator);
    }
    // Snapshot all additional instances before the first placement reparents
    // the source fragment's scopes or moves any original reference rows.
    for (sites[1..]) |site| {
        var copy = try @import("../initializer_clone.zig").clone(self, statements, self.current_scope, site.scope);
        errdefer copy.deinit(self.allocator);
        try clones.append(self.allocator, copy);
    }
    for (sites, 0..) |site, index| {
        if (site.constructor_scope != self.current_scope) @panic("native super initializer lost its constructor owner");
        const instance = if (index == 0) statements else clones.items[index - 1].roots;
        const original = self.ast.getNode(site.node);
        const operation = try self.ast.addNode(original);
        if (!site.alias.isNone()) {
            const owner = self.generated_super_call_assignments.get(@backingInt(site.node)).?;
            _ = self.generated_super_call_assignments.remove(@backingInt(site.node));
            try self.generated_super_call_assignments.put(self.allocator, @backingInt(operation), owner);
        }
        var expressions: std.ArrayList(NodeIndex) = .empty;
        defer expressions.deinit(self.allocator);
        try expressions.append(self.allocator, operation);
        for (instance) |statement| {
            try placeNativeInitializer(self, statement, self.current_scope, site.scope);
            try expressions.append(self.allocator, self.ast.getNode(statement).data.unary.operand);
        }
        const result = if (site.alias.isNone()) try self.ast.addNode(.{ .tag = .this_expression, .span = original.span, .data = .{ .none = 0 } }) else blk: {
            const id = self.getSymbolIdAt(site.alias) orelse @panic("native super producer alias lost its exact SID");
            const editor = &self.semantic_editor.?;
            const row = (editor.referenceForNode(site.alias) catch @panic("native super alias reference index is invalid")) orelse @panic("native super alias has no write reference");
            if (@backingInt(row.symbol_id) != id or !row.flags.write or row.scope_id != site.scope or editor.symbols.items[id].scope_id != self.current_scope)
                @panic("native super alias changed its actual constructor role");
            const read = try es_helpers.makeTempRefFromIdentity(self, .{ .span = self.ast.getNode(site.alias).data.string_ref, .symbol_id = @fromBackingInt(id), .owner_scope = self.current_scope, .reference_scope = site.scope }, original.span, .{ .read = true });
            try @import("../native_constructor_guard.zig").recordReference(self, read, @fromBackingInt(id), site.scope, .{ .read = true });
            break :blk read;
        };
        try expressions.append(self.allocator, result);
        self.ast.nodes.items[@backingInt(site.node)] = .{ .tag = .sequence_expression, .span = original.span, .data = .{ .list = try self.ast.addNodeList(expressions.items) } };
    }
    return body;
}

pub fn insertStatementsAfterSuper(self: *Transformer, body_idx: NodeIndex, stmts: []const NodeIndex) Error!NodeIndex {
    // This API is only used for derived constructors. Base constructors keep
    // their explicit prepend path at the caller.
    if (!self.options.unsupported.class) {
        if (try insertNativeSuperInitializers(self, body_idx, stmts, true)) |output| return output;
    }
    const body = self.ast.getNode(body_idx);
    if (body.tag != .block_statement and body.tag != .function_body) {
        return self.prependStatementsToBody(body_idx, stmts);
    }
    const old_list = body.data.list;
    const old_stmts_start = old_list.start;
    const old_stmts_len = old_list.len;
    const old_stmts = self.ast.extra_data.items[old_stmts_start .. old_stmts_start + old_stmts_len];

    // super() 호출이 들어있는 expression_statement 찾기.
    var super_idx: ?u32 = null;
    for (old_stmts, 0..) |raw_idx, i| {
        const stmt = self.ast.getNode(@fromBackingInt(@intCast(raw_idx)));
        if (stmt.tag != .expression_statement) continue;
        const operand = stmt.data.unary.operand;
        if (operand.isNone()) continue;
        // Native derived-this capture can already have wrapped this exact
        // super call in an assignment. Its result still establishes the
        // constructor receiver before instance initializers execute.
        var call = self.ast.getNode(operand);
        while (call.tag == .assignment_expression) {
            if (call.data.binary.right.isNone()) break;
            call = self.ast.getNode(call.data.binary.right);
        }
        if (call.tag != .call_expression) continue;
        const callee_idx: NodeIndex = @fromBackingInt(@intCast(self.ast.extra_data.items[call.data.extra]));
        const callee = self.ast.getNode(callee_idx);
        if (callee.tag == .super_expression) {
            super_idx = @intCast(i);
            break;
        }
    }

    if (super_idx == null) return self.prependStatementsToBody(body_idx, stmts);

    const scratch_top = self.scratch.items.len;
    defer self.scratch.shrinkRetainingCapacity(scratch_top);

    // [0..super_idx] + super() + stmts + [super_idx+1..]
    const cut: u32 = super_idx.? + 1;
    for (old_stmts[0..cut]) |raw_idx| try self.scratch.append(self.allocator, @fromBackingInt(@intCast(raw_idx)));
    for (stmts) |stmt| try self.scratch.append(self.allocator, stmt);
    for (old_stmts[cut..]) |raw_idx| try self.scratch.append(self.allocator, @fromBackingInt(@intCast(raw_idx)));

    const new_list = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
    return self.ast.addNode(.{
        .tag = body.tag,
        .span = body.span,
        .data = .{ .list = new_list },
    });
}

pub fn prependStatementsToBody(self: *Transformer, body_idx: NodeIndex, stmts: []const NodeIndex) Error!NodeIndex {
    const body = self.ast.getNode(body_idx);
    if (body.tag != .block_statement and body.tag != .program and body.tag != .function_body) {
        // 단일 문(non-block)이면 블록으로 감싸서 prepend
        const scratch_top = self.scratch.items.len;
        defer self.scratch.shrinkRetainingCapacity(scratch_top);
        for (stmts) |stmt| {
            try self.scratch.append(self.allocator, stmt);
        }
        try self.scratch.append(self.allocator, body_idx);
        const new_list = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
        return self.ast.addNode(.{
            .tag = .block_statement,
            .span = body.span,
            .data = .{ .list = new_list },
        });
    }

    const old_list = body.data.list;
    const scratch_top = self.scratch.items.len;
    defer self.scratch.shrinkRetainingCapacity(scratch_top);

    for (stmts) |stmt| {
        try self.scratch.append(self.allocator, stmt);
    }

    const old_stmts = self.ast.extra_data.items[old_list.start .. old_list.start + old_list.len];
    for (old_stmts) |raw_idx| {
        try self.scratch.append(self.allocator, @fromBackingInt(@intCast(raw_idx)));
    }

    const new_list = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
    return self.ast.addNode(.{
        .tag = body.tag,
        .span = body.span,
        .data = .{ .list = new_list },
    });
}

/// Append hoisted storage declarations without shifting existing statement
/// coordinates. `var` bindings are function-scoped regardless of their
/// textual position in the body.
pub fn appendStatementsToBody(self: *Transformer, body_idx: NodeIndex, stmts: []const NodeIndex) Error!NodeIndex {
    const body = self.ast.getNode(body_idx);
    if (body.tag != .block_statement and body.tag != .program and body.tag != .function_body) {
        const scratch_top = self.scratch.items.len;
        defer self.scratch.shrinkRetainingCapacity(scratch_top);
        try self.scratch.append(self.allocator, body_idx);
        for (stmts) |stmt| try self.scratch.append(self.allocator, stmt);
        const new_list = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
        return self.ast.addNode(.{ .tag = .block_statement, .span = body.span, .data = .{ .list = new_list } });
    }

    const old_list = body.data.list;
    const scratch_top = self.scratch.items.len;
    defer self.scratch.shrinkRetainingCapacity(scratch_top);
    const old_stmts = self.ast.extra_data.items[old_list.start .. old_list.start + old_list.len];
    for (old_stmts) |raw_idx| try self.scratch.append(self.allocator, @fromBackingInt(@intCast(raw_idx)));
    for (stmts) |stmt| try self.scratch.append(self.allocator, stmt);
    const new_list = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
    return self.ast.addNode(.{ .tag = body.tag, .span = body.span, .data = .{ .list = new_list } });
}

/// ES2015 new.target 변환.
/// constructor: this.constructor
/// method: void 0
/// function_named(Fn): this instanceof Fn ? this.constructor : void 0
pub fn lowerNewTarget(self: *Transformer, span: Span) Error!NodeIndex {
    return switch (self.new_target_ctx) {
        .constructor => es_helpers.makeThisDotConstructor(self, span),
        .method, .none, .field_initializer => es_helpers.makeVoidZero(self, span),
        .function_named => |named| {
            // (this instanceof Fn ? this.constructor : void 0)
            const this1 = try es_helpers.makeThisExpr(self, span);
            const fn_ref = try self.makeIdentifierRefWithSymbol(named.span, named.node);
            try self.trackUserReadFromBinding(fn_ref, named.node, self.current_scope);
            const instanceof = try self.ast.addNode(.{
                .tag = .binary_expression,
                .span = span,
                .data = .{ .binary = .{
                    .left = this1,
                    .right = fn_ref,
                    .flags = @backingInt(token_mod.Kind.kw_instanceof),
                } },
            });

            const this_ctor = try es_helpers.makeThisDotConstructor(self, span);

            const void_zero = try es_helpers.makeVoidZero(self, span);

            // conditional → parenthesized (우선순위 보호)
            const cond = try self.ast.addNode(.{
                .tag = .conditional_expression,
                .span = span,
                .data = .{ .ternary = .{
                    .a = instanceof,
                    .b = this_ctor,
                    .c = void_zero,
                } },
            });
            return self.ast.addNode(.{
                .tag = .parenthesized_expression,
                .span = span,
                .data = .{ .unary = .{ .operand = cond, .flags = 0 } },
            });
        },
    };
}

/// `const X = class {…}` 의 익명 클래스에 `X` 라는 이름을 붙인 사본을 돌려준다 (#4723).
///
/// 클래스를 낮추면(static field 를 밖으로 빼며 IIFE·temp 이름을 쓰거나, computed 키를
/// `(_a = k, class {…})` 쉼표 식으로 감싸면) **이름 추론이 깨져** `X.name` 이 `"_a"` 나
/// `""` 가 된다. `const` 는 재할당이 불가능해 클래스 안의 `X` 가 바깥 `X` 와 항상 같은
/// 값이므로 이름을 붙여도 의미가 같다(let/var 는 재할당될 수 있어 붙이지 않는다).
/// 클래스를 낮추는 타겟에서만 적용해 그 외 타겟의 출력은 바꾸지 않는다.
fn nameAnonymousConstClass(self: *Transformer, binding_idx: NodeIndex, init_idx: NodeIndex) Error!NodeIndex {
    if (!self.in_const_declaration or init_idx.isNone() or binding_idx.isNone()) return init_idx;
    const u = self.options.unsupported;
    if (!(u.class or u.class_field or u.class_static_block)) return init_idx;
    const init = self.ast.getNode(init_idx);
    if (init.tag != .class_expression) return init_idx;
    if (!self.readNodeIdx(init.data.extra, ast_mod.ClassExtra.name).isNone()) return init_idx;
    const binding = self.ast.getNode(binding_idx);
    if (binding.tag != .binding_identifier) return init_idx;

    var slots: [8]u32 = undefined;
    for (0..8) |k| slots[k] = self.ast.extra_data.items[init.data.extra + k];
    // 클래스 식의 이름은 바깥 `X` 와 **다른** 바인딩(클래스 안쪽 스코프)이라 바깥 심볼을 물려주지
    // 않는다 — 물려주면 두 바인딩이 한 심볼을 나눠 가져 mangler 가 안쪽 이름을 따로 줄이지 못한다.
    const name_span = try self.ast.addString(self.ast.getText(binding.data.string_ref));
    const synthetic_name = try es_helpers.makeSyntheticBinding(self, name_span);
    slots[ast_mod.ClassExtra.name] = @backingInt(synthetic_name);
    const new_extra = try self.ast.addExtras(&slots);
    const named = try self.ast.addNode(.{ .tag = .class_expression, .span = init.span, .data = .{ .extra = new_extra } });
    try self.remapCopiedScopeOwner(init_idx, named);
    if (self.semantic_edit_enabled) {
        const class_scope = self.outputOwnedScope(named) orelse
            std.debug.panic("inferred class name has no class scope", .{});
        const id = (try self.declareSyntheticInScope(
            synthetic_name,
            name_span,
            .class_decl,
            class_scope,
        )) orelse std.debug.panic("inferred class name did not receive a SymbolId", .{});
        // This name is visible to static initializers before any post-class
        // naming helper can run. Preserve it on the producer's exact SID.
        self.semantic_editor.?.symbols.items[@backingInt(id)].decl_flags.preserve_class_name = true;
        try self.class_self_symbol_map.put(self.allocator, @backingInt(named), @backingInt(id));
    }
    return named;
}
