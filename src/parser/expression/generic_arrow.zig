//! TS/TSX generic arrow disambiguation and parsing helpers.

const ast_mod = @import("../ast.zig");
const NodeIndex = ast_mod.NodeIndex;
const parser_mod = @import("../parser.zig");
const Parser = parser_mod.Parser;
const ParseError2 = parser_mod.ParseError2;

/// TSX 모드에서 `<`가 제네릭 arrow function인지 JSX인지 구별 (oxc arrow.rs:166-197).
/// trailing comma(<T,>), constraint(<T extends X>), default(<T = X>) → 제네릭 arrow.
/// 그 외 (`<T>` 등) → JSX. 현재 토큰이 `<`인 상태에서 호출.
pub fn isTsxGenericArrow(self: *Parser) ParseError2!bool {
    const saved = self.saveState();
    defer self.restoreState(saved);
    try self.advance(); // skip <
    return try checkTsxGenericArrowTypeParam(self);
}

/// async <T>() => body 형태에서의 TSX 제네릭 arrow 감지.
/// 현재 토큰이 `async`인 상태에서 호출.
pub fn isTsxGenericArrowAfterAsync(self: *Parser) ParseError2!bool {
    const saved = self.saveState();
    defer self.restoreState(saved);
    try self.advance(); // skip async
    if (self.current() != .l_angle) return false;
    try self.advance(); // skip <
    return try checkTsxGenericArrowTypeParam(self);
}

/// `<` 다음 위치에서 generic arrow function의 type parameter 패턴을 확인.
/// `[const] Ident (,|=|extends|:)` 또는 Flow에서 `Ident > (` (단일 무제약 param).
fn checkTsxGenericArrowTypeParam(self: *Parser) ParseError2!bool {
    if (self.current() == .kw_const) try self.advance();
    if (self.current() != .identifier and !self.current().isKeyword()) return false;
    try self.advance();
    const kind = self.current();
    if (kind == .comma or kind == .eq or kind == .kw_extends) return true;
    if (self.is_flow and kind == .colon) return true;
    // Flow: <T>(...) => body — `>` 뒤에 `(` 가 오면 generic arrow로 판별.
    // TSX에서는 <T> 가 JSX element일 수 있으므로, Flow 모드에서만 허용.
    if (self.is_flow and kind == .r_angle) {
        const after = try self.peekNextKind();
        return after == .l_paren;
    }
    return false;
}

/// TS 제네릭 arrow function 파싱 시도: <T>() => body, <const T>() => body
/// 현재 토큰이 < 인 상태에서 호출.
/// 성공하면 arrow_function_expression 노드를 반환, 실패하면 null.
/// saveState/restoreState를 사용하여 실패 시 복구.
pub fn tryParseGenericArrow(self: *Parser, is_async: bool) ParseError2!?NodeIndex {
    const start = self.currentSpan().start;
    const saved = self.saveState();
    const err_count = self.errors.items.len;

    // 제네릭 타입 파라미터 파싱 시도 — 에러 발생 또는 에러 추가 시 rollback
    const saved_nodes_len = self.ast.nodes.items.len;
    const saved_extra_len: u32 = @intCast(self.ast.extra_data.items.len);
    const type_param_failed = blk: {
        _ = self.parseTsTypeParameterDeclaration() catch break :blk true;
        // expect()는 에러를 추가하되 계속 진행하므로, 에러 수 증가로 실패 감지
        break :blk self.errors.items.len > err_count;
    };
    if (type_param_failed or self.current() != .l_paren) {
        self.ast.nodes.items.len = saved_nodes_len;
        self.ast.extra_data.shrinkRetainingCapacity(saved_extra_len);
        self.restoreState(saved);
        self.rollbackErrors(err_count);
        return null;
    }

    // 파라미터 리스트 파싱 (parseTypedArrowParams와 동일 패턴)
    try self.advance(); // skip (
    self.in_formal_parameters = true;
    const scratch_top = self.saveScratch();

    while (self.current() != .r_paren and self.current() != .eof) {
        const loop_guard_pos = self.scanner.token.span.start;
        const param = try self.parseBindingIdentifier();
        try self.scratch.append(self.allocator, param);
        if (!try self.eat(.comma)) break;
        if (try self.ensureLoopProgress(loop_guard_pos)) break;
    }
    self.in_formal_parameters = false;

    if (self.current() != .r_paren) {
        self.restoreScratch(scratch_top);
        self.restoreState(saved);
        self.rollbackErrors(err_count);
        return null;
    }
    try self.advance(); // skip )

    // 선택적 리턴 타입: <T>(): R => body
    // Flow: return type에서 `=>` 를 function type arrow로 해석하지 않도록 플래그 설정
    const saved_flow_flag = self.flow_in_return_type;
    self.flow_in_return_type = true;
    defer self.flow_in_return_type = saved_flow_flag;
    _ = try self.tryParseReturnType();

    // => 가 와야 arrow function
    if (self.current() != .arrow or self.scanner.token.has_newline_before) {
        self.restoreScratch(scratch_top);
        self.restoreState(saved);
        self.rollbackErrors(err_count);
        return null;
    }

    // arrow function은 항상 UniqueFormalParameters — 중복 파라미터 이름 금지.
    try self.checkDuplicateArrowFormalParams(scratch_top);

    // 파라미터 노드 리스트 생성
    const params = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
    self.restoreScratch(scratch_top);
    const params_node = try self.ast.addNode(.{
        .tag = .formal_parameters,
        .span = .{ .start = start, .end = self.currentSpan().start },
        .data = .{ .list = params },
    });

    try self.advance(); // skip =>
    const body = try self.parseArrowBody(is_async, params_node);
    const flags: u32 = if (is_async) 0x01 else 0;
    const ae = try self.ast.addExtras(&.{ @intFromEnum(params_node), @intFromEnum(body), flags });
    return try self.ast.addNode(.{
        .tag = .arrow_function_expression,
        .span = .{ .start = start, .end = self.currentSpan().start },
        .data = .{ .extra = ae },
    });
}
