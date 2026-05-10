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

/// variable_declaration: extra_data = [kind_flags, list.start, list.len]
/// binding이 destructuring pattern (object/array)인지 판별.
inline fn isBindingPattern(self: *const Transformer, idx: NodeIndex) bool {
    if (idx.isNone()) return false;
    const tag = self.ast.getNode(idx).tag;
    return tag == .object_pattern or tag == .array_pattern;
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
            const decl = self.ast.getNode(@enumFromInt(raw_idx));
            if (decl.tag != .variable_declarator) {
                const new_node = try self.visitNode(@enumFromInt(raw_idx));
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
                const none = @intFromEnum(NodeIndex.none);
                const init_node: u32 = if (is_destructuring)
                    none
                else
                    @intFromEnum(try es_helpers.makeVoidZero(self, node.span));
                const new_decl = try self.addExtraNode(.variable_declarator, decl.span, &.{ @intFromEnum(new_name), none, init_node });
                try self.scratch.append(self.allocator, new_decl);
            } else {
                const new_init = try self.visitNode(init_idx);
                const none = @intFromEnum(NodeIndex.none);
                const new_decl = try self.addExtraNode(.variable_declarator, decl.span, &.{ @intFromEnum(new_name), none, @intFromEnum(new_init) });
                try self.scratch.append(self.allocator, new_decl);
            }
        }

        const new_list = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
        return self.addExtraNode(.variable_declaration, node.span, &.{ @intFromEnum(kind), new_list.start, new_list.len });
    }

    const new_list = try self.visitExtraList(.{ .start = list_start, .len = list_len });
    return self.addExtraNode(.variable_declaration, node.span, &.{ @intFromEnum(kind), new_list.start, new_list.len });
}

/// variable_declarator: extra_data = [name, type_ann, init]
pub fn visitVariableDeclarator(self: *Transformer, node: Node) Error!NodeIndex {
    const e = node.data.extra;
    const new_name = try self.visitNode(self.readNodeIdx(e, 0));
    var new_init = try self.visitNode(self.readNodeIdx(e, 2));
    // styled-components: tag 를 `.withConfig({displayName})` 로 wrap. fast-path 로 1) 옵션,
    // 2) binding 감지, 3) init.tag == tagged_template_expression 을 사전 거른 뒤에만
    // 본 helper 호출. var_name 은 block-scoping rename 후 안전하도록 new_name 에서 읽음.
    if (!new_name.isNone() and styled_components_mod.shouldAttemptWrap(self, new_init)) {
        const new_name_node = self.ast.getNode(new_name);
        if (new_name_node.tag == .binding_identifier or new_name_node.tag == .identifier_reference) {
            const var_name = self.ast.getText(new_name_node.data.string_ref);
            new_init = try styled_components_mod.wrapStyledTagInExpr(self, new_init, var_name);
        }
    }
    // emotion autoLabel: const X = css`...` → css`label:X;...`
    if (self.options.emotion and !new_name.isNone() and !new_init.isNone()) {
        const new_name_node = self.ast.getNode(new_name);
        if (new_name_node.tag == .binding_identifier or new_name_node.tag == .identifier_reference) {
            const var_name = self.ast.getText(new_name_node.data.string_ref);
            new_init = try emotion_mod.maybeTransformEmotionTemplate(self, new_init, var_name);
        }
    }
    // styled-components named helper minify: const X = css`...` / keyframes`...` 등.
    // helper 는 컴포넌트가 아니라 CSS 조각이라 displayName/componentId 는 안 붙임.
    if (self.options.styled_components and !new_init.isNone()) {
        new_init = try styled_components_mod.maybeMinifyHelperTemplate(self, new_init);
    }
    // React Fast Refresh: `const Foo = () => ...` / `const Foo = function() {...}` 등록
    // (function declaration 은 visitFunction 단계에서 자체 이름으로 등록됨).
    if (!new_name.isNone() and !new_init.isNone()) {
        const name_node = self.ast.getNode(new_name);
        if (name_node.tag == .binding_identifier) {
            const binding_text = self.ast.getText(name_node.data.string_ref);
            try self.maybeRegisterRefreshComponentByBinding(new_init, binding_text);
        }
    }
    const none = @intFromEnum(NodeIndex.none);
    return self.addExtraNode(.variable_declarator, node.span, &.{ @intFromEnum(new_name), none, @intFromEnum(new_init) });
}

/// function/function_declaration/function_expression/arrow_function_expression
/// extra_data = [name, params_start, params_len, body, flags, return_type]
///
/// parameter property 변환:
///   constructor(public x: number) {} →
///   constructor(x) { this.x = x; }
pub fn visitFunction(self: *Transformer, node: Node) Error!NodeIndex {
    const e = node.data.extra;

    // TS function overload signature: body가 없으면 제거
    // function foo(): void;  ← overload signature (body 없음)
    // function foo(x: number): void;  ← overload signature
    // function foo(x?: number) {}  ← 구현체 (body 있음)
    if (self.readNodeIdx(e, 2).isNone()) return NodeIndex.none;

    // 일반 함수는 자체 this 바인딩을 가지므로 depth 증가.
    // static block 안에서 function() { this.x } 의 this는 치환하면 안 됨.
    const in_static_block = self.static_block_class_name != null;
    if (in_static_block) self.this_depth += 1;
    defer if (in_static_block) {
        self.this_depth -= 1;
    };

    // ES2015 arrow this/arguments 캡처: 일반 함수는 자체 this/arguments 바인딩을 가짐.
    const saved_arrow_depth = self.arrow_this_depth;
    const saved_needs_this = self.needs_this_var;
    const saved_needs_args = self.needs_arguments_var;
    const saved_super_alias = self.super_call_this_alias;
    self.arrow_this_depth = 0;
    self.needs_this_var = false;
    self.needs_arguments_var = false;
    self.super_call_this_alias = false;

    // ES2015 block scoping: 함수는 새 var 스코프. save/restore.
    const saved_scope_len = self.scope_var_names.items.len;
    const saved_rename_len = self.block_rename_stack.items.len;
    defer {
        self.scope_var_names.shrinkRetainingCapacity(saved_scope_len);
        // 함수 내부에서 추가된 rename 해제
        for (self.block_rename_stack.items[saved_rename_len..]) |entry| self.allocator.free(entry.new_name);
        self.block_rename_stack.shrinkRetainingCapacity(saved_rename_len);
    }

    // ES2015 new.target: 일반 함수 → function_named 컨텍스트
    const saved_new_target_ctx = self.new_target_ctx;
    if (self.options.unsupported.new_target) {
        const name_idx = self.readNodeIdx(e, 0);
        if (!name_idx.isNone()) {
            self.new_target_ctx = .{ .function_named = self.ast.getNode(name_idx).span };
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
    const scratch_top = self.scratch.items.len;
    defer self.scratch.shrinkRetainingCapacity(scratch_top);

    var pp = try self.visitParamsCollectProperties(params_list_old);
    defer pp.prop_names.deinit(self.allocator);

    // 바디 방문
    const old_body_idx = self.readNodeIdx(e, 2);
    var new_body = try self.visitBodyWorkletAware(old_body_idx);

    // parameter property가 있으면 바디 앞에 this.x = x 문 삽입
    if (pp.prop_names.items.len > 0 and !new_body.isNone()) {
        new_body = try self.insertParameterPropertyAssignments(new_body, pp.prop_names.items);
    }

    // ES2015 arrow this/arguments 캡처: 이 함수 안의 arrow가 this/arguments를 사용했으면
    // var _this = this; / var _arguments = arguments; 를 바디 앞에 삽입.
    if (self.options.unsupported.arrow and !new_body.isNone() and
        (self.needs_this_var or self.needs_arguments_var))
    {
        var capture_stmts: [2]NodeIndex = undefined;
        var capture_count: usize = 0;

        if (self.needs_this_var) {
            const this_init = try self.ast.addNode(.{
                .tag = .this_expression,
                .span = node.span,
                .data = .{ .none = 0 },
            });
            capture_stmts[capture_count] = try self.buildVarDecl("_this", this_init, node.span);
            capture_count += 1;
        }
        if (self.needs_arguments_var) {
            const args_span = try self.ast.addString("arguments");
            const args_init = try self.ast.addNode(.{
                .tag = .identifier_reference,
                .span = args_span,
                .data = .{ .string_ref = args_span },
            });
            capture_stmts[capture_count] = try self.buildVarDecl("_arguments", args_init, node.span);
            capture_count += 1;
        }

        new_body = try self.prependStatementsToBody(new_body, capture_stmts[0..capture_count]);
    }

    // 임시 변수 호이스팅: 이 함수 안에서 사용된 _a, _b, ... 선언을 body 앞에 삽입
    if (self.temp_var_counter > saved_temp_counter and !new_body.isNone()) {
        new_body = try self.hoistTempVars(new_body, saved_temp_counter, node.span);
    }
    // 함수 스코프 종료 — outer scope 의 hoistTempVars 가 같은 _a 를 다시 hoist 하지 않도록
    // 카운터 복원 (#1960). 다음 함수 / outer 에서 동일 이름을 안전하게 재사용 가능.
    self.temp_var_counter = saved_temp_counter;

    // arrow 캡처 상태 복원
    self.arrow_this_depth = saved_arrow_depth;
    self.needs_this_var = saved_needs_this;
    self.needs_arguments_var = saved_needs_args;
    self.super_call_this_alias = saved_super_alias;

    // React Fast Refresh — hook signature opt-in. default off 면 visitFunction
    // hot path 영향 0 (옵션 read + early-return). opt-in 시 babel-plugin-react-refresh
    // 동등 emit. `findHookCallsInNodeDepth` 가 depth=50 + node tag whitelist +
    // bounds check 로 stale 인덱스 방어.
    if (self.options.react_refresh and self.options.react_refresh_hook_signatures) {
        const fn_name_for_sig: ?[]const u8 = blk: {
            if (new_name.isNone()) break :blk null;
            const name_node = self.ast.getNode(new_name);
            if (name_node.tag != .binding_identifier and name_node.tag != .identifier_reference) break :blk null;
            break :blk self.ast.getText(name_node.data.string_ref);
        };
        try self.maybeRegisterRefreshSignature(fn_name_for_sig, old_body_idx, &new_body);
    }

    const none = @intFromEnum(NodeIndex.none);
    const new_params_node = try self.ast.addFormalParameters(pp.new_params, params_span);
    const result = try self.addExtraNode(node.tag, node.span, &.{
        @intFromEnum(new_name), @intFromEnum(new_params_node),
        @intFromEnum(new_body), self.readU32(e, 3),
        none,
    });

    // Plugin dispatch: onFunction (AST 훅)
    const is_auto_worklet = self.plugins.worklet.auto_next;
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
    })) |replacement| {
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
        const param_idx: NodeIndex = @enumFromInt(raw_idx);
        if (param_idx.isNone()) continue;
        const param_node = self.ast.getNode(param_idx);
        // formal_parameter: extra = [pattern, type_ann, default, flags, deco_start, deco_len]
        // flags != 0 → parameter property (public/private/protected/readonly/override)
        if (param_node.tag == .formal_parameter and self.ast.extra_data.items[param_node.data.extra + 3] != 0) {
            const inner = try self.visitNode(@enumFromInt(self.ast.extra_data.items[param_node.data.extra]));
            try self.scratch.append(self.allocator, inner);
            try result.prop_names.append(self.allocator, inner);
        } else {
            const new_param = try self.visitNode(@enumFromInt(raw_idx));
            if (!new_param.isNone()) {
                try self.scratch.append(self.allocator, new_param);
            }
        }
    }

    result.new_params = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
    return result;
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
        const member_extra = try self.ast.addExtras(&.{ @intFromEnum(this_node), @intFromEnum(name_idx), 0 });
        const member = try self.ast.addNode(.{
            .tag = .static_member_expression,
            .span = name_node.span,
            .data = .{ .extra = member_extra },
        });
        const assign = try self.ast.addNode(.{
            .tag = .assignment_expression,
            .span = name_node.span,
            .data = .{ .binary = .{ .left = member, .right = name_idx, .flags = 0 } },
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
    const pp_list = try self.buildParameterPropertyStatements(prop_names);
    const scratch_top = self.scratch.items.len;
    defer self.scratch.shrinkRetainingCapacity(scratch_top);
    for (self.ast.extra_data.items[pp_list.start .. pp_list.start + pp_list.len]) |raw_idx| {
        try self.scratch.append(self.allocator, @enumFromInt(raw_idx));
    }
    return self.insertStatementsAfterSuper(body_idx, self.scratch.items[scratch_top..]);
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
    for (pp_stmts) |raw_idx| try self.scratch.append(self.allocator, @enumFromInt(raw_idx));

    const old_stmts = self.ast.extra_data.items[old_list.start .. old_list.start + old_list.len];
    for (old_stmts) |raw_idx| try self.scratch.append(self.allocator, @enumFromInt(raw_idx));

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
pub fn insertStatementsAfterSuper(self: *Transformer, body_idx: NodeIndex, stmts: []const NodeIndex) Error!NodeIndex {
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
        const stmt = self.ast.getNode(@enumFromInt(raw_idx));
        if (stmt.tag != .expression_statement) continue;
        const operand = stmt.data.unary.operand;
        if (operand.isNone()) continue;
        const call = self.ast.getNode(operand);
        if (call.tag != .call_expression) continue;
        const callee_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[call.data.extra]);
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
    for (old_stmts[0..cut]) |raw_idx| try self.scratch.append(self.allocator, @enumFromInt(raw_idx));
    for (stmts) |stmt| try self.scratch.append(self.allocator, stmt);
    for (old_stmts[cut..]) |raw_idx| try self.scratch.append(self.allocator, @enumFromInt(raw_idx));

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
        try self.scratch.append(self.allocator, @enumFromInt(raw_idx));
    }

    const new_list = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
    return self.ast.addNode(.{
        .tag = body.tag,
        .span = body.span,
        .data = .{ .list = new_list },
    });
}

/// ES2015 new.target 변환.
/// constructor: this.constructor
/// method: void 0
/// function_named(Fn): this instanceof Fn ? this.constructor : void 0
pub fn lowerNewTarget(self: *Transformer, span: Span) Error!NodeIndex {
    return switch (self.new_target_ctx) {
        .constructor => es_helpers.makeThisDotConstructor(self, span),
        .method, .none => es_helpers.makeVoidZero(self, span),
        .function_named => |fn_span| {
            // (this instanceof Fn ? this.constructor : void 0)
            const this1 = try es_helpers.makeThisExpr(self, span);
            const fn_ref = try es_helpers.makeIdentifierRefFromSpan(self, fn_span);
            const instanceof = try self.ast.addNode(.{
                .tag = .binary_expression,
                .span = span,
                .data = .{ .binary = .{
                    .left = this1,
                    .right = fn_ref,
                    .flags = @intFromEnum(token_mod.Kind.kw_instanceof),
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
