//! React Fast Refresh — 컴포넌트/Hook 시그니처 등록 주입
//!
//! $RefreshReg$(component, "name") + $RefreshSig$(hookSig) 호출을
//! 프로그램 끝에 삽입한다.

const std = @import("std");
const ast_mod = @import("../../parser/ast.zig");
const Node = ast_mod.Node;
const Tag = Node.Tag;
const NodeIndex = ast_mod.NodeIndex;
const NodeList = ast_mod.NodeList;
const Ast = ast_mod.Ast;
const token_mod = @import("../../lexer/token.zig");
const Span = token_mod.Span;
const transformer_mod = @import("../transformer.zig");
const Transformer = transformer_mod.Transformer;
const Error = Transformer.Error;
const RefreshRegistration = Transformer.RefreshRegistration;
const RefreshSignature = Transformer.RefreshSignature;

// ================================================================
// React Fast Refresh — 컴포넌트 등록 주입
// ================================================================

/// 함수 이름이 React 컴포넌트 명명 규칙(PascalCase)인지 확인.
pub fn isComponentName(name: []const u8) bool {
    if (name.len == 0) return false;
    return name[0] >= 'A' and name[0] <= 'Z';
}

/// Vite core `JS_TYPES_RE` (`/\.(?:j|t)sx?$|\.mjs$/`) 매칭 확장자 — plugin-react 기본 filter.
const refresh_target_extensions = [_][]const u8{ ".js", ".jsx", ".ts", ".tsx", ".mjs" };

/// 파일 경로가 `@vitejs/plugin-react` 기본 filter 와 호환되는지 — `.[jt]sx?` 또는
/// `.mjs` 확장자 + `node_modules` 제외. plugin-react 의 default `include`/`exclude` 정확 일치.
fn isRefreshTargetPath(path: []const u8) bool {
    if (path.len == 0) return true; // path 정보 없으면 보수적으로 허용 (transpile direct API 등)
    if (std.mem.indexOf(u8, path, "/node_modules/") != null) return false;
    const last_dot = std.mem.lastIndexOfScalar(u8, path, '.') orelse return false;
    const ext = path[last_dot..];
    for (refresh_target_extensions) |target| {
        if (std.mem.eql(u8, ext, target)) return true;
    }
    return false;
}

/// `Transformer.refresh_enabled_cached` 의 init 값 계산. `lifecycle.finishInit` 에서 호출.
pub fn computeRefreshEnabled(opts: @import("../transformer.zig").TransformOptions) bool {
    if (!opts.react_refresh) return false;
    return isRefreshTargetPath(opts.jsx_filename);
}

/// react-refresh transform 활성화 여부 — init 시 계산한 캐시 값 read. hot path 안전.
pub inline fn refreshEnabled(self: *const Transformer) bool {
    return self.refresh_enabled_cached;
}

/// 함수 노드에서 이름 텍스트를 추출한다.
/// function_declaration의 extra[0]이 binding_identifier.
/// ast의 extra_data에서 읽음 (visitFunction이 이미 노드를 생성했으므로).
pub fn getFunctionName(self: *Transformer, func_node: Node) ?[]const u8 {
    const e = func_node.data.extra;
    if (e >= self.ast.extra_data.items.len) return null;
    const name_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[e]);
    if (name_idx.isNone()) return null;
    const name_node = self.ast.getNode(name_idx);
    if (name_node.tag != .binding_identifier and name_node.tag != .identifier_reference) return null;
    return self.ast.getText(name_node.data.string_ref);
}

/// 변환된 함수 노드가 React 컴포넌트이면 등록 정보를 수집한다.
/// visitFunction에서 호출.
pub fn maybeRegisterRefreshComponent(self: *Transformer, new_func_idx: NodeIndex) Error!void {
    if (!refreshEnabled(self)) return;
    if (self.plugins.refresh.suppress_registration) return;

    const func_node = self.ast.getNode(new_func_idx);
    // function_expression의 이름은 함수 내부 스코프에서만 접근 가능하므로
    // 외부에서 $RefreshReg$에 등록하면 ReferenceError 발생
    if (func_node.tag == .function_expression) return;
    const name = self.getFunctionName(func_node) orelse return;
    if (!isComponentName(name)) return;

    try appendRefreshRegistration(self, name);
}

/// 변수 binding 기반 컴포넌트 등록 — `const Foo = () => ...` / `const Foo = function() {...}`
/// 처럼 함수 자체에 이름이 없는 케이스. `visitVariableDeclarator` post-visit 에서 호출.
/// `Foo` 가 PascalCase 이고 init 이 arrow/function 표현이면 등록.
pub fn maybeRegisterRefreshComponentByBinding(
    self: *Transformer,
    init_idx: NodeIndex,
    binding_name: []const u8,
) Error!void {
    if (!refreshEnabled(self)) return;
    if (self.plugins.refresh.suppress_registration) return;
    if (init_idx.isNone()) return;
    if (!isComponentName(binding_name)) return;

    const init_tag = self.ast.getNode(init_idx).tag;
    const is_target = init_tag == .arrow_function_expression or
        init_tag == .function_expression or
        init_tag == .function;
    if (!is_target) return;

    try appendRefreshRegistration(self, binding_name);
}

fn appendRefreshRegistration(self: *Transformer, name: []const u8) Error!void {
    const handle_span = try self.makeRefreshHandle();
    try self.plugins.refresh.registrations.append(self.allocator, .{
        .handle_span = handle_span,
        .name = name,
    });
}

/// _c, _c2, _c3, ... 핸들 변수명 생성
pub fn makeRefreshHandle(self: *Transformer) Error!Span {
    const idx = self.plugins.refresh.registrations.items.len;
    if (idx == 0) {
        return self.ast.addString("_c");
    }
    var buf: [16]u8 = undefined;
    const len = std.fmt.bufPrint(&buf, "_c{d}", .{idx + 1}) catch return error.OutOfMemory;
    return self.ast.addString(len);
}

/// 프로그램 끝에 var _c, _c2; $RefreshReg$(_c, "Name"); ... 를 추가한다.
pub fn appendRefreshRegistrations(self: *Transformer, root: NodeIndex) Error!NodeIndex {
    const prog = self.ast.getNode(root);
    if (prog.tag != .program) return root;

    const old_list = prog.data.list;
    const old_stmts = self.ast.extra_data.items[old_list.start .. old_list.start + old_list.len];

    const scratch_top = self.scratch.items.len;
    defer self.scratch.shrinkRetainingCapacity(scratch_top);

    // 기존 문장 복사
    for (old_stmts) |raw_idx| {
        try self.scratch.append(self.allocator, @enumFromInt(raw_idx));
    }

    // _c = App; _c2 = Helper; 할당문 (함수 선언 뒤에 실행)
    for (self.plugins.refresh.registrations.items) |reg| {
        const assign_stmt = try self.buildRefreshAssignment(reg);
        try self.scratch.append(self.allocator, assign_stmt);
    }

    // var _c, _c2, ...; 선언
    const var_decl = try self.buildRefreshVarDeclaration();
    try self.scratch.append(self.allocator, var_decl);

    // $RefreshSig$ — opt-in (`react_refresh_hook_signatures`) 시에만 emit. default
    // 는 Metro 정책 (registration only) 으로 RN HMR 영향 없음.
    if (self.options.react_refresh_hook_signatures and self.plugins.refresh.signatures.items.len > 0) {
        const refresh_sig_span = try self.ast.addString("$RefreshSig$");
        for (self.plugins.refresh.signatures.items) |sig| {
            const sig_decl = try self.buildRefreshSigDeclaration(sig, refresh_sig_span);
            try self.scratch.append(self.allocator, sig_decl);
            const sig_call = try self.buildRefreshSigCall(sig);
            try self.scratch.append(self.allocator, sig_call);
        }
    }

    // $RefreshReg$(_c, "ComponentName"); 호출들
    const refresh_reg_span = try self.ast.addString("$RefreshReg$");
    for (self.plugins.refresh.registrations.items) |reg| {
        const reg_stmt = try self.buildRefreshRegCall(reg, refresh_reg_span);
        try self.scratch.append(self.allocator, reg_stmt);
    }

    const new_list = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
    return self.ast.addNode(.{
        .tag = .program,
        .span = prog.span,
        .data = .{ .list = new_list },
    });
}

/// _c = ComponentName; 할당문 생성
pub fn buildRefreshAssignment(self: *Transformer, reg: RefreshRegistration) Error!NodeIndex {
    const zero_span = Span{ .start = 0, .end = 0 };

    const handle_ref = try self.ast.addNode(.{
        .tag = .identifier_reference,
        .span = reg.handle_span,
        .data = .{ .string_ref = reg.handle_span },
    });
    const comp_ref = try self.ast.addNode(.{
        .tag = .identifier_reference,
        .span = zero_span,
        .data = .{ .string_ref = try self.ast.addString(reg.name) },
    });
    const assign = try self.ast.addNode(.{
        .tag = .assignment_expression,
        .span = zero_span,
        .data = .{ .binary = .{ .left = handle_ref, .right = comp_ref, .flags = 0 } },
    });
    return self.ast.addNode(.{
        .tag = .expression_statement,
        .span = zero_span,
        .data = .{ .unary = .{ .operand = assign, .flags = 0 } },
    });
}

/// var _c, _c2, ...; 선언 노드 생성
pub fn buildRefreshVarDeclaration(self: *Transformer) Error!NodeIndex {
    const scratch_top = self.scratch.items.len;
    defer self.scratch.shrinkRetainingCapacity(scratch_top);
    const none = @intFromEnum(NodeIndex.none);

    for (self.plugins.refresh.registrations.items) |reg| {
        const binding = try self.ast.addNode(.{
            .tag = .binding_identifier,
            .span = reg.handle_span,
            .data = .{ .string_ref = reg.handle_span },
        });

        // variable_declarator: extra = [name, type_ann(none), init(none)]
        const declarator = try self.addExtraNode(.variable_declarator, reg.handle_span, &.{
            @intFromEnum(binding),
            none, // type annotation
            none, // initializer
        });
        try self.scratch.append(self.allocator, declarator);
    }

    const decl_list = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
    return self.addExtraNode(.variable_declaration, .{ .start = 0, .end = 0 }, &.{
        0, // var
        decl_list.start,
        decl_list.len,
    });
}

/// $RefreshReg$(_c, "ComponentName"); 호출문 생성
pub fn buildRefreshRegCall(self: *Transformer, reg: RefreshRegistration, refresh_reg_span: Span) Error!NodeIndex {
    const zero_span = Span{ .start = 0, .end = 0 };

    const callee = try self.ast.addNode(.{
        .tag = .identifier_reference,
        .span = refresh_reg_span,
        .data = .{ .string_ref = refresh_reg_span },
    });

    const handle_ref = try self.ast.addNode(.{
        .tag = .identifier_reference,
        .span = reg.handle_span,
        .data = .{ .string_ref = reg.handle_span },
    });

    // "ComponentName" 문자열 리터럴 (따옴표 포함)
    var quoted_buf: [256]u8 = undefined;
    const quoted = std.fmt.bufPrint(&quoted_buf, "\"{s}\"", .{reg.name}) catch return error.OutOfMemory;
    const quoted_span = try self.ast.addString(quoted);
    const name_str = try self.ast.addNode(.{
        .tag = .string_literal,
        .span = quoted_span,
        .data = .{ .string_ref = quoted_span },
    });

    const args = try self.ast.addNodeList(&.{ handle_ref, name_str });
    const call = try self.addExtraNode(.call_expression, zero_span, &.{
        @intFromEnum(callee),
        args.start,
        args.len,
        0,
    });

    return self.ast.addNode(.{
        .tag = .expression_statement,
        .span = zero_span,
        .data = .{ .unary = .{ .operand = call, .flags = 0 } },
    });
}

/// var _s = $RefreshSig$(); 선언 생성
pub fn buildRefreshSigDeclaration(self: *Transformer, sig: RefreshSignature, refresh_sig_span: Span) Error!NodeIndex {
    const zero_span = Span{ .start = 0, .end = 0 };
    const none = @intFromEnum(NodeIndex.none);

    // $RefreshSig$() 호출
    const callee = try self.ast.addNode(.{
        .tag = .identifier_reference,
        .span = refresh_sig_span,
        .data = .{ .string_ref = refresh_sig_span },
    });
    const empty_args = try self.ast.addNodeList(&.{});
    const init_call = try self.addExtraNode(.call_expression, zero_span, &.{
        @intFromEnum(callee),
        empty_args.start,
        empty_args.len,
        0,
    });

    // var _s = $RefreshSig$();
    const binding = try self.ast.addNode(.{
        .tag = .binding_identifier,
        .span = sig.handle_span,
        .data = .{ .string_ref = sig.handle_span },
    });
    const declarator = try self.addExtraNode(.variable_declarator, sig.handle_span, &.{
        @intFromEnum(binding),
        none, // type annotation
        @intFromEnum(init_call),
    });

    const decl_list = try self.ast.addNodeList(&.{declarator});
    return self.addExtraNode(.variable_declaration, zero_span, &.{
        0, // var
        decl_list.start,
        decl_list.len,
    });
}

/// _s(Component, "signature"); 호출문 생성
pub fn buildRefreshSigCall(self: *Transformer, sig: RefreshSignature) Error!NodeIndex {
    const zero_span = Span{ .start = 0, .end = 0 };

    // _s 식별자
    const callee = try self.ast.addNode(.{
        .tag = .identifier_reference,
        .span = sig.handle_span,
        .data = .{ .string_ref = sig.handle_span },
    });

    // Component 식별자
    const comp_ref = try self.ast.addNode(.{
        .tag = .identifier_reference,
        .span = zero_span,
        .data = .{ .string_ref = try self.ast.addString(sig.component_name) },
    });

    // "signature" 문자열 리터럴
    var quoted_buf: [1024]u8 = undefined;
    const quoted = std.fmt.bufPrint(&quoted_buf, "\"{s}\"", .{sig.signature}) catch return error.OutOfMemory;
    const quoted_span = try self.ast.addString(quoted);
    const sig_str = try self.ast.addNode(.{
        .tag = .string_literal,
        .span = quoted_span,
        .data = .{ .string_ref = quoted_span },
    });

    // _s(Component, "signature")
    const args = try self.ast.addNodeList(&.{ comp_ref, sig_str });
    const call = try self.addExtraNode(.call_expression, zero_span, &.{
        @intFromEnum(callee),
        args.start,
        args.len,
        0,
    });

    return self.ast.addNode(.{
        .tag = .expression_statement,
        .span = zero_span,
        .data = .{ .unary = .{ .operand = call, .flags = 0 } },
    });
}

// ================================================================
// React Fast Refresh — Hook 시그니처 ($RefreshSig$)
// ================================================================

/// Hook 호출 이름이 React Hook인지 확인 (use 접두사 + 다음 문자가 대문자).
pub fn isHookCall(name: []const u8) bool {
    if (!std.mem.startsWith(u8, name, "use")) return false;
    // "use" 자체도 React 19 hook
    if (name.len == 3) return true;
    // use 다음 문자가 대문자 (useState, useEffect, useMyHook 등)
    return name[3] >= 'A' and name[3] <= 'Z';
}

/// ast에서 함수 body 내의 Hook 호출을 스캔하여 시그니처 문자열을 생성한다.
/// Hook이 없으면 null 반환.
pub fn scanHookSignature(self: *Transformer, func_body_idx: NodeIndex) Error!?[]const u8 {
    if (!refreshEnabled(self)) return null;
    if (func_body_idx.isNone()) return null;

    var sig_buf: std.ArrayList(u8) = .empty;
    defer sig_buf.deinit(self.allocator);

    // ast에서 body의 자식 문장들을 순회
    const body_node = self.ast.getNode(func_body_idx);
    if (body_node.tag != .block_statement) return null;

    const list = body_node.data.list;
    const stmts = self.ast.extra_data.items[list.start .. list.start + list.len];

    for (stmts) |raw_stmt_idx| {
        const stmt_idx: NodeIndex = @enumFromInt(raw_stmt_idx);
        // 재귀적으로 Hook 호출 검색
        try self.findHookCallsInNode(stmt_idx, &sig_buf, null);
    }

    if (sig_buf.items.len == 0) return null;
    return try self.allocator.dupe(u8, sig_buf.items);
}

/// Hook 호출을 찾아 시그니처 버퍼에 추가한다 (파서 노드 영역 기준).
/// binding_ctx: 부모 variable_declarator의 LHS 바인딩 텍스트 (null이면 없음).
pub fn findHookCallsInNode(self: *Transformer, idx: NodeIndex, sig_buf: *std.ArrayList(u8), binding_ctx: ?[]const u8) Error!void {
    // 깊이 제한 버전으로 위임 (transform 후 stale AST 인덱스 방어)
    return self.findHookCallsInNodeDepth(idx, sig_buf, binding_ctx, 0);
}

pub fn findHookCallsInNodeDepth(self: *Transformer, idx: NodeIndex, sig_buf: *std.ArrayList(u8), binding_ctx: ?[]const u8, depth: u32) Error!void {
    if (idx.isNone()) return;
    if (@intFromEnum(idx) >= self.ast.nodes.items.len) return;
    // 깊이 제한: 함수 body는 보통 수십 단계. 50 이상이면 stale 인덱스 순환.
    if (depth > 50) return;
    const node = self.ast.getNode(idx);
    // 알려진 탐색 대상만 처리 — 그 외 노드는 즉시 반환 (stale 인덱스 방어)
    switch (node.tag) {
        .call_expression, .expression_statement, .variable_declaration, .variable_declarator, .block_statement => {},
        .function_declaration, .function_expression, .arrow_function_expression => return,
        else => return,
    }

    // call_expression에서 Hook 호출 감지
    if (node.tag == .call_expression) {
        const e = node.data.extra;
        if (self.ast.hasExtra(e, 1)) {
            const callee_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[e]);
            if (!callee_idx.isNone() and @intFromEnum(callee_idx) < self.ast.nodes.items.len) {
                const callee = self.ast.getNode(callee_idx);
                var hook_name: ?[]const u8 = null;

                if (callee.tag == .identifier_reference) {
                    const name = self.ast.getText(callee.data.string_ref);
                    if (isHookCall(name)) hook_name = name;
                } else if (callee.tag == .static_member_expression) {
                    const me = callee.data.binary;
                    if (!me.right.isNone() and @intFromEnum(me.right) < self.ast.nodes.items.len) {
                        const prop = self.ast.getNode(me.right);
                        if (prop.tag == .identifier_reference) {
                            const name = self.ast.getText(prop.data.string_ref);
                            if (isHookCall(name)) hook_name = name;
                        }
                    }
                }

                if (hook_name) |name| {
                    if (sig_buf.items.len > 0) {
                        try sig_buf.appendSlice(self.allocator, "\\n");
                    }
                    try sig_buf.appendSlice(self.allocator, name);
                    try sig_buf.append(self.allocator, '{');
                    // 바인딩 패턴 포함: useState{[foo, setFoo](0)}
                    if (binding_ctx) |b| {
                        try sig_buf.appendSlice(self.allocator, b);
                    }
                    // 첫 번째 인자 포함 (useState/useReducer의 초기값)
                    if (self.ast.hasExtra(e, 3)) {
                        const args_start = self.ast.extra_data.items[e + 1];
                        const args_len = self.ast.extra_data.items[e + 2];
                        if (args_len > 0 and args_start < self.ast.extra_data.items.len) {
                            const first_arg_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[args_start]);
                            if (!first_arg_idx.isNone() and @intFromEnum(first_arg_idx) < self.ast.nodes.items.len) {
                                const first_arg = self.ast.getNode(first_arg_idx);
                                if (first_arg.span.start < first_arg.span.end and
                                    first_arg.span.start & Ast.STRING_TABLE_BIT == 0)
                                {
                                    try sig_buf.append(self.allocator, '(');
                                    try sig_buf.appendSlice(self.allocator, self.ast.getText(first_arg.span));
                                    try sig_buf.append(self.allocator, ')');
                                }
                            }
                        }
                    }
                    try sig_buf.append(self.allocator, '}');
                }
            }
        }
        return;
    }

    // expression_statement → 내부 expression 탐색
    if (node.tag == .expression_statement) {
        try self.findHookCallsInNodeDepth(node.data.unary.operand, sig_buf, null, depth + 1);
        return;
    }

    // variable_declaration → declarator들 탐색
    if (node.tag == .variable_declaration) {
        const e = node.data.extra;
        if (self.ast.hasExtra(e, 3)) {
            const list_start = self.ast.extra_data.items[e + 1];
            const list_len = self.ast.extra_data.items[e + 2];
            if (list_start + list_len <= self.ast.extra_data.items.len) {
                const items = self.ast.extra_data.items[list_start .. list_start + list_len];
                for (items) |raw| {
                    try self.findHookCallsInNodeDepth(@enumFromInt(raw), sig_buf, null, depth + 1);
                }
            }
        }
        return;
    }

    // variable_declarator → LHS 바인딩 추출 + init 탐색
    if (node.tag == .variable_declarator) {
        const e = node.data.extra;
        if (self.ast.hasExtra(e, 3)) {
            // LHS 바인딩 텍스트 추출 (binding_identifier 또는 array/object pattern)
            const lhs_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[e]);
            var lhs_text: ?[]const u8 = null;
            if (!lhs_idx.isNone() and @intFromEnum(lhs_idx) < self.ast.nodes.items.len) {
                const lhs = self.ast.getNode(lhs_idx);
                if (lhs.span.start < lhs.span.end and lhs.span.start & Ast.STRING_TABLE_BIT == 0) {
                    lhs_text = self.ast.getText(lhs.span);
                }
            }

            const init_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[e + 2]);
            try self.findHookCallsInNodeDepth(init_idx, sig_buf, lhs_text, depth + 1);
        }
        return;
    }

    // block_statement → 자식 문장들 탐색
    if (node.tag == .block_statement) {
        const l = node.data.list;
        if (l.len > 0 and l.start + l.len <= self.ast.extra_data.items.len) {
            const items = self.ast.extra_data.items[l.start .. l.start + l.len];
            for (items) |raw| {
                try self.findHookCallsInNodeDepth(@enumFromInt(raw), sig_buf, null, depth + 1);
            }
        }
    }
}

/// _s / _s2 핸들 변수명 생성
pub fn makeSigHandle(self: *Transformer) Error!Span {
    const idx = self.plugins.refresh.signatures.items.len;
    if (idx == 0) {
        return self.ast.addString("_s");
    }
    var buf: [16]u8 = undefined;
    const name = std.fmt.bufPrint(&buf, "_s{d}", .{idx + 1}) catch return error.OutOfMemory;
    return self.ast.addString(name);
}

/// Hook 시그니처가 있는 컴포넌트를 등록하고, body에 _s() 호출을 삽입한다.
/// `react_refresh` + `react_refresh_hook_signatures` 둘 다 활성일 때만 동작.
/// 후자가 default false 라 기본 빌드 (RN 포함) 는 영향 없음.
pub fn maybeRegisterRefreshSignature(
    self: *Transformer,
    func_name: ?[]const u8,
    old_body_idx: NodeIndex,
    new_body: *NodeIndex,
) Error!void {
    if (!refreshEnabled(self)) return;
    if (!self.options.react_refresh_hook_signatures) return;
    const name = func_name orelse return;
    if (!isComponentName(name)) return;

    const signature = try self.scanHookSignature(old_body_idx) orelse return;

    const handle_span = try self.makeSigHandle();
    try self.plugins.refresh.signatures.append(self.allocator, .{
        .handle_span = handle_span,
        .component_name = name,
        .signature = signature,
    });

    // body 시작에 _s(); 호출 삽입
    new_body.* = try self.insertSigCallAtBodyStart(new_body.*, handle_span);
}

/// 블록 body 시작에 _s(); 호출문을 삽입한다.
pub fn insertSigCallAtBodyStart(self: *Transformer, body_idx: NodeIndex, handle_span: Span) Error!NodeIndex {
    const body = self.ast.getNode(body_idx);
    if (body.tag != .block_statement) return body_idx;

    const old_list = body.data.list;
    const old_stmts_start = old_list.start;
    const old_stmts_len = old_list.len;

    const scratch_top = self.scratch.items.len;
    defer self.scratch.shrinkRetainingCapacity(scratch_top);

    // _s() 호출문
    const zero_span = Span{ .start = 0, .end = 0 };
    const callee = try self.ast.addNode(.{
        .tag = .identifier_reference,
        .span = handle_span,
        .data = .{ .string_ref = handle_span },
    });
    const empty_args = try self.ast.addNodeList(&.{});
    const call = try self.addExtraNode(.call_expression, zero_span, &.{
        @intFromEnum(callee),
        empty_args.start,
        empty_args.len,
        0,
    });
    const call_stmt = try self.ast.addNode(.{
        .tag = .expression_statement,
        .span = zero_span,
        .data = .{ .unary = .{ .operand = call, .flags = 0 } },
    });

    // [_s(), ...기존 문장들] — AST 변형 후이므로 인덱스로 접근
    try self.scratch.append(self.allocator, call_stmt);
    {
        var i_s: u32 = 0;
        while (i_s < old_stmts_len) : (i_s += 1) {
            const raw_idx = self.ast.extra_data.items[old_stmts_start + i_s];
            try self.scratch.append(self.allocator, @enumFromInt(raw_idx));
        }
    }

    const new_list = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
    return self.ast.addNode(.{
        .tag = .block_statement,
        .span = body.span,
        .data = .{ .list = new_list },
    });
}

// ================================================================
// Tests — path filter (Vite plugin-react 기본 include/exclude 호환)
// ================================================================

test "isRefreshTargetPath: include extensions" {
    try std.testing.expect(isRefreshTargetPath("/src/App.tsx"));
    try std.testing.expect(isRefreshTargetPath("/src/App.ts"));
    try std.testing.expect(isRefreshTargetPath("/src/App.jsx"));
    try std.testing.expect(isRefreshTargetPath("/src/App.js"));
    try std.testing.expect(isRefreshTargetPath("/src/App.mjs"));
}

test "isRefreshTargetPath: exclude non-JS extensions" {
    try std.testing.expect(!isRefreshTargetPath("/src/App.css"));
    try std.testing.expect(!isRefreshTargetPath("/src/App.vue"));
    try std.testing.expect(!isRefreshTargetPath("/src/App.svelte"));
    try std.testing.expect(!isRefreshTargetPath("/src/App.zig"));
    try std.testing.expect(!isRefreshTargetPath("/src/App.json"));
    try std.testing.expect(!isRefreshTargetPath("/src/App.cjs"));
    try std.testing.expect(!isRefreshTargetPath("/src/App.cts"));
    try std.testing.expect(!isRefreshTargetPath("/src/Makefile"));
}

test "isRefreshTargetPath: exclude /node_modules/ regardless of extension" {
    try std.testing.expect(!isRefreshTargetPath("/project/node_modules/react/index.tsx"));
    try std.testing.expect(!isRefreshTargetPath("/project/node_modules/foo/bar/Baz.tsx"));
    try std.testing.expect(!isRefreshTargetPath("/a/node_modules/.pnpm/x/dist/y.jsx"));
    // node_modules 가 path 의 일부지만 segment 경계가 아닌 경우 — `/foo_node_modules_bar/`
    // 같은 fake match 는 거의 안 일어나지만 Vite 동작 (substring 검사) 그대로 유지.
}

test "isRefreshTargetPath: empty path → conservative allow" {
    // jsx_filename 이 비어있는 transpile direct API 경로는 보수적으로 허용.
    try std.testing.expect(isRefreshTargetPath(""));
}

test "isRefreshTargetPath: no extension" {
    try std.testing.expect(!isRefreshTargetPath("/src/script"));
}

test "computeRefreshEnabled: react_refresh=false short-circuits filter" {
    const TransformOptions = @import("../transformer.zig").TransformOptions;
    const opts: TransformOptions = .{ .react_refresh = false, .jsx_filename = "/src/App.tsx" };
    try std.testing.expect(!computeRefreshEnabled(opts));
}

test "computeRefreshEnabled: react_refresh=true + matching path" {
    const TransformOptions = @import("../transformer.zig").TransformOptions;
    const opts: TransformOptions = .{ .react_refresh = true, .jsx_filename = "/src/App.tsx" };
    try std.testing.expect(computeRefreshEnabled(opts));
}

test "computeRefreshEnabled: react_refresh=true + non-matching path → false" {
    const TransformOptions = @import("../transformer.zig").TransformOptions;
    const opts: TransformOptions = .{ .react_refresh = true, .jsx_filename = "/src/App.css" };
    try std.testing.expect(!computeRefreshEnabled(opts));
}

test "computeRefreshEnabled: react_refresh=true + node_modules → false" {
    const TransformOptions = @import("../transformer.zig").TransformOptions;
    const opts: TransformOptions = .{
        .react_refresh = true,
        .jsx_filename = "/project/node_modules/react/index.tsx",
    };
    try std.testing.expect(!computeRefreshEnabled(opts));
}
