//! Object Literal 파싱
//!
//! 객체 리터럴, 프로퍼티, 메서드를 파싱하는 함수들.\n//! oxc의 js/object.rs에 대응.
//!
//! 참고: references/oxc/crates/oxc_parser/src/js/object.rs

const std = @import("std");
const ast_mod = @import("ast.zig");
const Node = ast_mod.Node;
const Tag = Node.Tag;
const NodeIndex = ast_mod.NodeIndex;
const token_mod = @import("../lexer/token.zig");
const Kind = token_mod.Kind;
const Span = token_mod.Span;
const Parser = @import("parser.zig").Parser;
const ParseError2 = @import("parser.zig").ParseError2;

pub fn parseObjectExpression(self: *Parser) ParseError2!NodeIndex {
    const start = self.currentSpan().start;
    try self.advance(); // skip {

    var props: std.ArrayList(NodeIndex) = .empty;
    defer props.deinit(self.allocator);

    while (self.current() != .r_curly and self.current() != .eof) {
        const loop_guard_pos = self.scanner.token.span.start;
        const prop = try parseObjectProperty(self);
        try props.append(self.allocator, prop);
        if (!try self.eat(.comma)) break;

        if (try self.ensureLoopProgress(loop_guard_pos)) break;
    }

    const end = self.currentSpan().end;

    // 객체 리터럴은 표현식이므로, 닫는 `}` 뒤의 `/`는 division이어야 한다.
    // prev_token_kind를 `.r_paren`으로 설정하면 scanSlash()가 division으로 판별한다.
    // 예: `{valueOf: fn} / 1` — object literal 뒤 division
    self.scanner.prev_token_kind = .r_paren;
    try self.expect(.r_curly);

    const list = try self.ast.addNodeList(props.items);
    return try self.ast.addNode(.{
        .tag = .object_expression,
        .span = .{ .start = start, .end = end },
        .data = .{ .list = list },
    });
}

pub fn parseObjectProperty(self: *Parser) ParseError2!NodeIndex {
    const start = self.currentSpan().start;

    // spread: ...expr
    if (self.current() == .dot3) {
        try self.advance();
        const expr = try self.parseAssignmentExpression();
        return try self.ast.addNode(.{
            .tag = .spread_element,
            .span = .{ .start = start, .end = self.currentSpan().start },
            .data = .{ .unary = .{ .operand = expr, .flags = 0 } },
        });
    }

    // get/set 메서드 shorthand: { get prop() {}, set prop(v) {} }
    if (self.current() == .kw_get or self.current() == .kw_set) {
        const peek = try self.peekNextKind();
        if (peek != .colon and peek != .l_paren and peek != .comma and peek != .r_curly) {
            const method_flags: u16 = if (self.current() == .kw_get) 0x02 else 0x04;
            try self.advance(); // skip get/set
            const key = try self.parsePropertyKey();
            return parseObjectMethodBody(self, start, key, method_flags);
        }
    }

    // async 메서드 shorthand: { async foo() {} }
    // 주의: { async() {} }는 'async'라는 이름의 일반 메서드 (async 수식어가 아님).
    if (self.current() == .kw_async) {
        const peek = try self.peekNext();
        if (peek.kind != .colon and peek.kind != .comma and
            peek.kind != .r_curly and peek.kind != .l_paren and !peek.has_newline_before)
        {
            var method_flags: u16 = 0x08; // async
            try self.advance(); // skip 'async'
            // async generator: { async *foo() {} }
            if (try self.eat(.star)) method_flags |= 0x10;
            const key = try self.parsePropertyKey();
            return parseObjectMethodBody(self, start, key, method_flags);
        }
    }

    // generator 메서드: { *foo() {} }
    if (self.current() == .star) {
        try self.advance(); // skip '*'
        const key = try self.parsePropertyKey();
        return parseObjectMethodBody(self, start, key, 0x10); // generator
    }

    // 키: identifier, string, number, 또는 computed [expr]
    const key = try self.parsePropertyKey();

    // object literal에서 private identifier는 키로 사용 불가
    if (!key.isNone() and self.ast.getNode(key).tag == .private_identifier) {
        try self.addErrorCode(self.ast.getNode(key).span, "Private identifier is not allowed as object property key", .private_object_key);
    }

    // 메서드 shorthand: { foo() {} } 또는 { foo<T>() {} }
    if (self.current() == .l_paren or self.isAtOpeningAngleBracket()) {
        return parseObjectMethodBody(self, start, key, 0);
    }

    // key: value
    var value = NodeIndex.none;
    var prop_flags: u16 = 0;
    if (try self.eat(.colon)) {
        value = try self.parseAssignmentExpression();
    } else if (try self.eat(.eq)) {
        // shorthand with default: { x = 1 }  (destructuring default)
        // CoverInitializedName — destructuring 변환에서 소비되지 않으면 에러
        value = try self.parseAssignmentExpression();
        prop_flags = Parser.shorthand_with_default;
        self.has_cover_init_name = true;
    } else {
        // shorthand: { x } — key가 identifier shorthand로 사용 가능한지 검증
        if (!key.isNone()) {
            const key_node = self.ast.getNode(key);
            switch (key_node.tag) {
                .identifier_reference => {
                    const key_text = self.resolveIdentifierText(key_node.span);
                    if (token_mod.keywords.get(key_text)) |kw| {
                        // await/yield は contextual keyword — 特定のコンテキストでのみ reserved
                        const is_context_reserved = if (kw == .kw_await)
                            // await은 module 또는 async context에서만 reserved
                            false // kw_await 전용 체크는 아래에서 별도 처리
                        else
                            kw.isReservedKeyword() or kw.isLiteralKeyword();
                        if (is_context_reserved) {
                            try self.addErrorCode(key_node.span, "Reserved word cannot be used as shorthand property", .reserved_shorthand);
                        } else if (self.is_strict_mode and kw.isStrictModeReserved()) {
                            try self.addErrorCode(key_node.span, "Reserved word in strict mode cannot be used as shorthand property", .reserved_shorthand_strict);
                        } else if (kw == .kw_yield and self.ctx.in_generator) {
                            try self.addErrorCode(key_node.span, "'yield' cannot be used as shorthand property in generator", .yield_shorthand_generator);
                        } else if (kw == .kw_await and (self.ctx.in_async or (self.is_module and !self.in_namespace))) {
                            try self.addErrorCode(key_node.span, "'await' cannot be used as shorthand property in async/module", .await_shorthand_async);
                        }
                    }
                },
                // non-identifier keys (numeric, bigint, string, computed) 는 shorthand 불가
                .numeric_literal, .bigint_literal, .string_literal, .computed_property_key => {
                    try self.addErrorCode(key_node.span, "Expected ':' after property key", .property_colon_expected);
                },
                else => {},
            }
        }
    }

    return try self.ast.addNode(.{
        .tag = .object_property,
        .span = .{ .start = start, .end = self.currentSpan().start },
        .data = .{ .binary = .{ .left = key, .right = value, .flags = prop_flags } },
    });
}

/// 객체 리터럴 메서드의 파라미터와 본문을 파싱한다.
pub fn parseObjectMethodBody(self: *Parser, start: u32, key: NodeIndex, flags: u16) ParseError2!NodeIndex {
    // 메서드 컨텍스트 진입 — 파라미터/본문 모두 이 컨텍스트에서 파싱
    const saved_ctx = self.enterFunctionContext(
        (flags & ast_mod.MethodFlags.is_async) != 0,
        (flags & ast_mod.MethodFlags.is_generator) != 0,
    );
    // ECMAScript 12.3.7: 객체 리터럴 메서드에서도 super.prop 허용
    self.allow_super_property = true;

    // TS 제네릭 파라미터: { foo<T>() {} }
    if (self.isAtOpeningAngleBracket()) {
        _ = try self.parseTsTypeParameterDeclaration();
    }

    try self.expect(.l_paren);
    self.in_formal_parameters = true;
    try self.trySkipThisParameter();
    const scratch_top = self.saveScratch();
    while (self.current() != .r_paren and self.current() != .eof) {
        const loop_guard_pos = self.scanner.token.span.start;
        const param = try self.parseBindingIdentifier();
        try self.scratch.append(self.allocator, param);
        try self.checkRestParameterLast(param);
        if (!try self.eat(.comma)) break;

        if (try self.ensureLoopProgress(loop_guard_pos)) break;
    }
    try self.expect(.r_paren);
    self.in_formal_parameters = false;

    // TS 리턴 타입
    _ = try self.tryParseReturnType();
    self.has_simple_params = self.checkSimpleParams(scratch_top);
    try self.checkDuplicateParams(scratch_top);
    const body = try self.parseFunctionBodyExpr();

    // retroactive strict mode checks for object methods
    if (self.is_strict_mode and !saved_ctx.is_strict_mode) {
        try self.checkStrictParamNames(scratch_top);
    }

    self.restoreFunctionContext(saved_ctx);

    const param_list = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
    self.restoreScratch(scratch_top);
    const params_node = try self.wrapAsFormalParametersFromList(param_list, .{ .start = 0, .end = 0 });

    // method_definition: extra = [key(0), params(1), body(2), flags(3), deco_start(4), deco_len(5)]
    // 클래스 메서드와 동일한 6개 필드 (객체 메서드는 decorator 없으므로 0, 0)
    const extra_start = try self.ast.addExtra(@intFromEnum(key));
    _ = try self.ast.addExtra(@intFromEnum(params_node));
    _ = try self.ast.addExtra(@intFromEnum(body));
    _ = try self.ast.addExtra(flags);
    _ = try self.ast.addExtra(0); // deco_start (no decorators)
    _ = try self.ast.addExtra(0); // deco_len  (no decorators)

    return try self.ast.addNode(.{
        .tag = .method_definition,
        .span = .{ .start = start, .end = self.currentSpan().start },
        .data = .{ .extra = extra_start },
    });
}
