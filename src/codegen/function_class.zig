//! Codegen helpers for template literals, functions, and classes.

const std = @import("std");
const ast_mod = @import("../parser/ast.zig");
const Node = ast_mod.Node;
const NodeIndex = ast_mod.NodeIndex;
const debug_metadata = @import("debug_metadata.zig");
const statement_emit = @import("statements.zig");
const call_emit = @import("calls.zig");

fn emitNestedExecutionBody(self: anytype, body: NodeIndex) !void {
    const saved_for_init = self.in_for_init;
    const saved_skip_var_init = self.skip_var_init;
    self.in_for_init = false;
    self.skip_var_init = false;
    defer {
        self.in_for_init = saved_for_init;
        self.skip_var_init = saved_skip_var_init;
    }
    try self.emitNode(body);
}

/// keepNames: name 노드가 rename되었으면 (original_name, new_name) 쌍을 수집.
/// emitter가 코드젠 완료 후 __name(newName, "originalName") 호출을 append.
fn collectKeepNameEntry(self: anytype, name_idx: NodeIndex) void {
    const meta = self.options.linking_metadata orelse return;
    const sym_id = self.resolveSymbolId(name_idx, meta) orelse return;
    const new_name = meta.renames.get(sym_id) orelse return;
    const name_node = self.ast.getNode(name_idx);
    const original_name = self.ast.getText(name_node.data.string_ref);
    if (std.mem.eql(u8, new_name, original_name)) return;
    // OOM 시 append 실패 → __name() 미삽입. arena 할당이므로 현실적으로 발생하지 않음.
    self.keep_names_entries.append(self.allocator, .{
        .new_name = new_name,
        .original_name = original_name,
    }) catch return;
}

/// template literal을 child node 단위로 emit.
/// rename/mangling이 적용되려면 expression을 개별 emitNode로 처리해야 한다.
pub fn emitTemplateLiteral(self: anytype, node: Node) !void {
    try self.addSourceMapping(node.span);
    // raw-span shorthand (#2957): emotion / styled_components 의 transformer 가
    // `.data = .{ .list = .{ .start = 0, .len = 0 } }` 로 만든 template literal.
    // 이 경우만 raw span path 로 출력. parser-created template literal 은 list.start
    // 가 우연히 0 이어도 list.len > 0 이라 이 분기를 피한다 (이전엔 `data.none == 0`
    // 으로 검사해 list.start = 0 인 정상 template literal 의 expression 이 mangle
    // 되지 않고 source span 그대로 출력 — `${code}` 같은 매개변수 reference 가
    // 깨지는 회귀).
    if (node.data.list.len == 0) {
        try self.writeNodeSpan(node);
        return;
    }
    const items = self.ast.extra_data.items[node.data.list.start .. node.data.list.start + node.data.list.len];
    for (items) |item_idx| {
        const child: NodeIndex = @enumFromInt(item_idx);
        const child_node = self.ast.nodes.items[@intFromEnum(child)];
        if (child_node.tag == .template_element) {
            try self.writeNodeSpan(child_node);
        } else {
            // `${}` substitution 은 괄호 안 → .lowest (esbuild ETemplate part = LLowest)
            try self.emitExpr(child, .lowest, .{});
        }
    }
}

pub fn emitTaggedTemplate(self: anytype, node: Node) !void {
    try self.addSourceMapping(node.span);
    const e = node.data.extra;
    const extras = self.ast.extra_data.items;
    if (e + 1 >= extras.len) return;
    // flags 슬롯 (extras[e+2]) 의 `is_pure` bit 가 켜져 있으면 `/* @__PURE__ */`
    // annotation emit. minifier (Terser/esbuild/rolldown) 가 미사용 tagged template
    // 호출을 dead-code elimination 가능 (styled-components `pure` 옵션 등).
    if (e + 2 < extras.len) {
        const TaggedTemplateFlags = ast_mod.TaggedTemplateFlags;
        const flags = extras[e + 2];
        const is_pure = (flags & TaggedTemplateFlags.is_pure) != 0;
        if (is_pure and !self.options.minify_whitespace) try self.write("/* @__PURE__ */ ");
    }
    // tag 는 .postfix (esbuild ETemplate tag = LPostfix). 단 tag 가 optional chain 이면
    // ECMAScript 상 tagged template tag 로 불가(`a?.b`x`` = SyntaxError) → 괄호로 감싼다
    // (esbuild `IsOptionalChain(tag)` 분기). 투명 paren 이 사라져도 체인이 끊긴 채 보존된다.
    const tag: NodeIndex = @enumFromInt(extras[e]);
    if (call_emit.isOptionalChainExpr(self, tag)) {
        try self.writeByte('(');
        try self.emitExpr(tag, .lowest, .{});
        try self.writeByte(')');
    } else {
        try self.emitExpr(tag, .postfix, .{});
    }
    try self.emitNode(@enumFromInt(extras[e + 1]));
}

pub fn emitFunction(self: anytype, node: Node) !void {
    try self.addSourceMapping(node.span);
    const e = node.data.extra;
    // function_expression은 ret_type 없이 4 slots, function_declaration/function은 5 slots.
    // 공통 [name(0), params(1), body(2), flags(3)]만 읽는다.
    const extras = self.ast.extra_data.items[e .. e + 4];
    const name: NodeIndex = @enumFromInt(extras[0]);
    const params_list = self.ast.functionParamsList(node);
    const params_start = params_list.start;
    const params_len = params_list.len;
    const body: NodeIndex = @enumFromInt(extras[2]);
    const flags = extras[3];

    // function map: contextual name 소비 후 진입. saved_pending 은 owned 를 보관하다가
    // 종료 시 ownership 복원만 한다 (free 책임은 set 한 caller scope 에 있다).
    const saved_pending = self.pending_fn_name;
    self.pending_fn_name = null;
    defer self.pending_fn_name = saved_pending;
    if (self.fn_map_builder != null) {
        const fn_name: []const u8 = if (!name.isNone())
            self.ast.getText(self.ast.getNode(name).data.string_ref)
        else
            saved_pending orelse "<anonymous>";
        try debug_metadata.fnMapEnter(self, fn_name);
    }
    defer if (self.fn_map_builder != null) {
        debug_metadata.fnMapExit(self) catch {}; // defer는 오류 전파 불가 — OOM 시 상위 emit이 이미 실패했으므로 무시
    };

    // strict execution order: function declaration → 할당식으로 변환.
    // `function foo() {...}` → `foo = function() {...};`
    // var foo; 선언은 esm_wrap에서 hoisted_var_names로 이미 top-level에 배치됨.
    const convert_fn_to_assign = self.options.esm_var_assign_only and
        node.tag == .function_declaration and !name.isNone() and
        self.indent_level == 0;

    if (convert_fn_to_assign) {
        try self.emitNode(name);
        try self.write(" = ");
    }

    if (flags & ast_mod.FunctionFlags.is_async != 0) try self.write("async ");
    try self.write("function");
    if (flags & ast_mod.FunctionFlags.is_generator != 0) try self.writeByte('*');
    if (!name.isNone() and !convert_fn_to_assign) {
        try self.writeByte(' ');
        try self.emitNode(name);
    }
    try self.writeByte('(');
    try self.emitNodeList(params_start, params_len, ",");
    try self.writeByte(')');
    try emitNestedExecutionBody(self, body);

    // #1751: assignment 로 변환된 form 은 expression statement 라서 `;` 종결 필요.
    // 다음 statement 가 directive ("use strict") 처럼 ASI 로 구분 안 되는 경우
    // 문법 오류 유발. function declaration 원형은 `}` 로 충분하지만 변환형은 아님.
    if (convert_fn_to_assign) try self.writeByte(';');

    // keepNames: function_declaration에서 이름이 rename된 경우 entry 수집
    if (self.options.keep_names and node.tag == .function_declaration and !name.isNone()) {
        collectKeepNameEntry(self, name);
    }
}

/// arrow_function_expression: extra = [params, body, flags]
pub fn emitArrow(self: anytype, node: Node) !void {
    try self.addSourceMapping(node.span);
    const e = node.data.extra;
    const extras = self.ast.extra_data.items;
    if (e + 2 >= extras.len) return;
    const params: NodeIndex = @enumFromInt(extras[e]);
    const body: NodeIndex = @enumFromInt(extras[e + 1]);
    const flags = extras[e + 2];

    // function map: 화살표 함수는 항상 익명 — contextual name 사용
    const saved_pending = self.pending_fn_name;
    self.pending_fn_name = null;
    defer self.pending_fn_name = saved_pending;
    if (self.fn_map_builder != null) {
        try debug_metadata.fnMapEnter(self, saved_pending orelse "<anonymous>");
    }
    defer if (self.fn_map_builder != null) {
        debug_metadata.fnMapExit(self) catch {}; // defer는 오류 전파 불가 — OOM 시 상위 emit이 이미 실패했으므로 무시
    };

    if (flags & ast_mod.ArrowFlags.is_async != 0) try self.write("async ");

    // params 출력 — #1283 이후 항상 formal_parameters 노드. 괄호는 codegen이 부착.
    // #3096: minify 시 단일 plain identifier 파라미터는 괄호 생략 (`x => ...`).
    if (params.isNone()) {
        try self.write("()");
    } else if (self.options.minify_whitespace and arrowParamsOmittable(self, params)) {
        try self.emitNode(params);
    } else {
        try self.writeByte('(');
        try self.emitNode(params);
        try self.writeByte(')');
    }
    try self.writeSpace();
    try self.write("=>");
    // block body는 emitBlock이 { 앞 공백을 관리, non-block은 여기서 추가
    const is_block_body = !body.isNone() and self.ast.getNode(body).tag == .block_statement;
    if (!is_block_body) try self.writeSpace();

    // arrow expression body: leftmost token 이 `{`(object literal)이면 block body 로
    // 오파싱되는 것을 막아야 한다 (`x => ({obj})`). arrow_expr_start 를 body 출력 직전
    // 위치로 마킹하면, leftmost object literal 이 그 위치에서 EObject wrap(exprNeedsParens)
    // 으로 괄호를 친다 — member/binary/conditional left-chain 을 타고 내려간 object 도
    // 그 사이 아무것도 안 써서 자동 커버 (esbuild EArrow: `p.arrowExprStart = len(p.js)`).
    // body level = .comma (esbuild EArrow body = LComma).
    const saved_for_init = self.in_for_init;
    const saved_skip_var_init = self.skip_var_init;
    self.in_for_init = false;
    self.skip_var_init = false;
    defer {
        self.in_for_init = saved_for_init;
        self.skip_var_init = saved_skip_var_init;
    }
    if (is_block_body or body.isNone()) {
        try self.emitNode(body);
    } else {
        self.arrow_expr_start = self.buf.items.len;
        try self.emitExpr(body, .comma, .{});
    }
}

/// 파라미터 노드가 단순 식별자 1개(이름만 출력) 인지 — `binding_identifier` 또는
/// 파서 cover-grammar 변환 산물인 `assignment_target_identifier`. destructuring / rest /
/// default 패턴은 여기 해당 안 함.
fn isPlainIdentifierParam(tag: ast_mod.Node.Tag) bool {
    return tag == .binding_identifier or tag == .assignment_target_identifier;
}

/// arrow 파라미터를 괄호 없이 출력해도 되는지 — 정확히 1개의 plain identifier 파라미터
/// (default / rest / destructuring 없음)일 때만. `emitFormalParam` / 식별자 emit 이 그
/// 경우 이름만 출력하므로 `x => ...` 가 valid arrow 가 된다.
fn arrowParamsOmittable(self: anytype, params_idx: NodeIndex) bool {
    const pnode = self.ast.getNode(params_idx);
    if (pnode.tag != .formal_parameters) return false;
    const list = pnode.data.list;
    if (list.len != 1 or list.start >= self.ast.extra_data.items.len) return false;
    const elem = self.ast.getNode(@enumFromInt(self.ast.extra_data.items[list.start]));
    if (isPlainIdentifierParam(elem.tag)) return true;
    if (elem.tag != .formal_parameter) return false;
    const FP = ast_mod.FormalParameterExtra;
    if (!self.ast.hasExtra(elem.data.extra, FP.default)) return false;
    if (!self.ast.readExtraNode(elem.data.extra, FP.default).isNone()) return false; // (x = 1) => — 괄호 필수
    return isPlainIdentifierParam(self.ast.getNode(self.ast.readExtraNode(elem.data.extra, FP.pattern)).tag);
}

// (expressionStartsWithBrace 제거: arrow expression body 의 `{` 모호성은 이제
//  arrow_expr_start 마킹 + EObject wrap(precedence)이 처리한다 — #4042 PR7.)

/// class: extra = [name, super, body, type_params, impl_start, impl_len, deco_start, deco_len]
pub fn emitClass(self: anytype, node: Node) !void {
    try self.addSourceMapping(node.span);
    const e = node.data.extra;
    const name: NodeIndex = @enumFromInt(self.ast.extra_data.items[e]);
    const super_class: NodeIndex = @enumFromInt(self.ast.extra_data.items[e + 1]);
    const body: NodeIndex = @enumFromInt(self.ast.extra_data.items[e + 2]);
    const deco_start = self.ast.extra_data.items[e + 6];
    const deco_len = self.ast.extra_data.items[e + 7];

    // function map: class도 frame (Metro는 Class를 Function처럼 처리)
    const saved_pending = self.pending_fn_name;
    self.pending_fn_name = null;
    defer self.pending_fn_name = saved_pending;
    if (self.fn_map_builder != null) {
        const class_name: []const u8 = if (!name.isNone())
            self.ast.getText(self.ast.getNode(name).data.string_ref)
        else
            saved_pending orelse "<anonymous>";
        try debug_metadata.fnMapEnter(self, class_name);
    }
    defer if (self.fn_map_builder != null) {
        debug_metadata.fnMapExit(self) catch {}; // defer는 오류 전파 불가 — OOM 시 상위 emit이 이미 실패했으므로 무시
    };

    // class는 block-scoped → __esm 콜백 밖 __export getter가 접근 불가.
    // variable_declaration과 동일하게 할당문으로 변환. (emitter가 var 선언을 밖에 배치)
    const convert_to_assign = self.options.esm_var_assign_only and
        node.tag == .class_declaration and
        !name.isNone() and
        self.indent_level == 0;

    // #2198: cycle 모듈의 top-level class declaration → `var X = class { ... }`.
    // class declaration 자체가 block-scoped 라 `var` 강등으로는 부족, class
    // expression 으로 변환해야 hoist 가능 (esbuild 호환). decorator 가 있으면
    // 출력 순서가 `var X = ` → decorator → `class` → body 라 결과는
    // `var X = @dec class {...}` — Stage 3 decorator spec 의 inline class
    // expression decorator 가 valid 라서 syntax 깨지지 않음.
    const convert_to_var_class_expr = self.options.force_var_for_cycle and
        !convert_to_assign and
        node.tag == .class_declaration and
        !name.isNone() and
        self.indent_level == 0;

    if (convert_to_assign) {
        try self.emitNode(name);
        try self.write(" = ");
    } else if (convert_to_var_class_expr) {
        try self.write("var ");
        try self.emitNode(name);
        try self.writeSpace();
        try self.writeByte('=');
        try self.writeSpace();
    }

    // decorator 출력: @log @validate class Foo {} (esbuild 호환: 공백 구분)
    if (deco_len > 0) {
        const deco_indices = self.ast.extra_data.items[deco_start .. deco_start + deco_len];
        for (deco_indices) |raw_idx| {
            try self.emitNode(@enumFromInt(raw_idx));
            try self.writeByte(' ');
        }
    }

    try self.write("class");
    // var X = class { ... } 으로 변환 시 inner name 은 emit 안 함 (anonymous expression).
    // .name 프로퍼티는 spec 의 NamedEvaluation 으로 외부 var 이름 ("X") 으로 fallback.
    if (!name.isNone() and !convert_to_var_class_expr) {
        try self.writeByte(' ');
        try self.emitNode(name);
    }
    if (!super_class.isNone()) {
        try self.write(" extends ");
        try self.emitNode(super_class);
    }
    try emitNestedExecutionBody(self, body);

    if (convert_to_assign or convert_to_var_class_expr) {
        try self.writeByte(';');
    }

    // keepNames: class_declaration에서 이름이 rename된 경우 entry 수집
    if (self.options.keep_names and node.tag == .class_declaration and !name.isNone()) {
        collectKeepNameEntry(self, name);
    }
}

pub fn emitClassBody(self: anytype, node: Node) !void {
    try statement_emit.emitBracedList(self, node);
}

// static_block: unary = { operand = body(block_statement) }
// 파서 원본 노드는 writeNodeSpan, 합성 노드(span={0,0})와 minify 모드는
// 마지막 세미콜론 트리밍을 위해 AST 기반으로 출력한다.
pub fn emitStaticBlock(self: anytype, node: Node) !void {
    const has_parser_span = node.span.start != 0 or node.span.end != 0;
    const minify = self.options.minify_whitespace and self.options.minify_syntax;
    if (has_parser_span and !minify) {
        try self.writeNodeSpan(node);
        return;
    }
    try self.write("static");
    try self.writeSpace();
    try emitNestedExecutionBody(self, node.data.unary.operand);
}

pub fn emitMethodDef(self: anytype, node: Node) !void {
    try self.addSourceMapping(node.span);
    const e = node.data.extra;
    const extras = self.ast.extra_data.items[e .. e + 6];
    const key: NodeIndex = @enumFromInt(extras[ast_mod.MethodExtra.key]);
    const params_list = self.ast.functionParamsList(node);
    const params_start = params_list.start;
    const params_len = params_list.len;
    const body: NodeIndex = @enumFromInt(extras[ast_mod.MethodExtra.body]);
    const flags = extras[ast_mod.MethodExtra.flags];
    const deco_start = extras[ast_mod.MethodExtra.deco_start];
    const deco_len = extras[ast_mod.MethodExtra.deco_len];

    // function map: ClassName#method / ClassName.method / get__name / set__name
    if (self.fn_map_builder != null) {
        const method_name = try debug_metadata.resolveMethodName(self, key, flags);
        defer self.allocator.free(method_name);
        try debug_metadata.fnMapEnter(self, method_name);
    }
    defer if (self.fn_map_builder != null) {
        debug_metadata.fnMapExit(self) catch {}; // defer는 오류 전파 불가 — OOM 시 상위 emit이 이미 실패했으므로 무시
    };

    try emitMemberDecorators(self, deco_start, deco_len);

    if (flags & ast_mod.MethodFlags.is_static != 0) try self.write("static ");
    if (flags & ast_mod.MethodFlags.is_async != 0) try self.write("async ");
    if (flags & ast_mod.MethodFlags.is_getter != 0) {
        try self.write("get ");
    } else if (flags & ast_mod.MethodFlags.is_setter != 0) {
        try self.write("set ");
    }
    if (flags & ast_mod.MethodFlags.is_generator != 0) try self.writeByte('*');

    try self.emitNode(key);
    try self.writeByte('(');
    try self.emitNodeList(params_start, params_len, ",");
    try self.writeByte(')');
    try emitNestedExecutionBody(self, body);
}

pub fn emitPropertyDef(self: anytype, node: Node) !void {
    try self.addSourceMapping(node.span);
    const e = node.data.extra;
    const extras = self.ast.extra_data.items[e .. e + 5];
    const key: NodeIndex = @enumFromInt(extras[ast_mod.PropertyExtra.key]);
    const value: NodeIndex = @enumFromInt(extras[ast_mod.PropertyExtra.init]);
    const flags = extras[ast_mod.PropertyExtra.flags];
    const deco_start = extras[ast_mod.PropertyExtra.deco_start];
    const deco_len = extras[ast_mod.PropertyExtra.deco_len];

    try emitMemberDecorators(self, deco_start, deco_len);

    if (flags & ast_mod.PropertyFlags.is_static != 0) try self.write("static ");
    try self.emitNode(key);
    if (!value.isNone()) {
        try self.writeSpace();
        try self.writeByte('=');
        try self.writeSpace();
        // contextual name: class property = function-like → key 이름 사용
        if (self.fn_map_builder != null and self.isFunctionLike(value)) {
            const saved = self.pending_fn_name;
            self.pending_fn_name = try self.ast.staticKeyName(self.allocator, key);
            defer {
                if (self.pending_fn_name) |s| self.allocator.free(s);
                self.pending_fn_name = saved;
            }
            try self.emitNode(value);
        } else {
            try self.emitNode(value);
        }
    }
    try self.writeByte(';');
}

pub fn emitDecorator(self: anytype, node: Node) !void {
    try self.addSourceMapping(node.span);
    try self.writeByte('@');
    try self.emitNode(node.data.unary.operand);
}

/// decorator 리스트 출력 (member decorator 공용 헬퍼).
/// deco_len > 0이면 각 decorator를 출력 후 줄바꿈 + 들여쓰기.
fn emitMemberDecorators(self: anytype, deco_start: u32, deco_len: u32) !void {
    if (deco_len == 0) return;
    const deco_indices = self.ast.extra_data.items[deco_start .. deco_start + deco_len];
    for (deco_indices) |raw_idx| {
        try self.emitNode(@enumFromInt(raw_idx));
        try self.writeByte('\n');
        try self.writeIndent();
    }
}

pub fn emitAccessorProp(self: anytype, node: Node) !void {
    try self.addSourceMapping(node.span);
    const e = node.data.extra;
    const extras = self.ast.extra_data.items[e .. e + 5];
    const key: NodeIndex = @enumFromInt(extras[ast_mod.PropertyExtra.key]);
    const value: NodeIndex = @enumFromInt(extras[ast_mod.PropertyExtra.init]);
    const flags = extras[ast_mod.PropertyExtra.flags];
    const deco_start = extras[ast_mod.PropertyExtra.deco_start];
    const deco_len = extras[ast_mod.PropertyExtra.deco_len];

    try emitMemberDecorators(self, deco_start, deco_len);

    if (flags & ast_mod.PropertyFlags.is_static != 0) try self.write("static ");
    try self.write("accessor ");
    try self.emitNode(key);
    if (!value.isNone()) {
        try self.writeSpace();
        try self.writeByte('=');
        try self.writeSpace();
        try self.emitNode(value);
    }
    try self.writeByte(';');
}
