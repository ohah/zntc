//! JSX 파싱
//!
//! JSX element, fragment, attribute를 파싱하는 함수들.
//! oxc의 jsx/mod.rs에 대응.
//!
//! 참고: references/oxc/crates/oxc_parser/src/jsx/mod.rs

const std = @import("std");
const ast_mod = @import("ast.zig");
const Node = ast_mod.Node;
const Tag = Node.Tag;
const NodeIndex = ast_mod.NodeIndex;
const Parser = @import("parser.zig").Parser;
const ParseError2 = @import("parser.zig").ParseError2;
const Kind = @import("../lexer/token.zig").Kind;

/// JSX children 루프: <tag>...</tag> 또는 <>...</> 내부의 자식 노드들을 파싱.
/// element와 fragment에서 공유.
fn parseJSXChildren(self: *Parser) ParseError2!ast_mod.NodeList {
    const children_top = self.saveScratch();
    while (self.current() != .eof) {
        const loop_guard_pos = self.scanner.token.span.start;
        if (self.current() == .l_angle) {
            if (try self.peekNextKindJSX() == .slash) break;
            const child = try parseJSXElementAsChild(self);
            try self.scratch.append(self.allocator, child);
        } else if (self.current() == .l_curly) {
            const expr_start = self.currentSpan().start;
            try self.advance(); // skip {
            // 빈 expression container: {} — children에서 유효
            if (self.current() == .r_curly) {
                const container = try self.ast.addNode(.{
                    .tag = .jsx_expression_container,
                    .span = .{ .start = expr_start, .end = self.currentSpan().end },
                    .data = .{ .unary = .{ .operand = .none, .flags = 0 } },
                });
                try self.scratch.append(self.allocator, container);
                try self.scanner.nextJSXChild();
                continue;
            }
            // JSX spread child: {...expr} — React 16+ spread children syntax
            if (self.current() == .dot3) {
                try self.advance(); // skip ...
                const spread_expr = try self.parseAssignmentExpression();
                if (self.current() != .r_curly) {
                    try self.errors.append(self.allocator, .{
                        .span = self.currentSpan(),
                        .message = Kind.r_curly.symbol(),
                        .found = self.current().symbol(),
                    });
                }
                const spread_child = try self.ast.addNode(.{
                    .tag = .jsx_spread_child,
                    .span = .{ .start = expr_start, .end = self.currentSpan().end },
                    .data = .{ .unary = .{ .operand = spread_expr, .flags = 0 } },
                });
                try self.scratch.append(self.allocator, spread_child);
                try self.scanner.nextJSXChild();
                continue;
            }
            const expr = try self.parseExpression();
            // expect(.r_curly) 대신 수동 체크: JSX children에서는 nextJSXChild()로 스캔해야 함
            if (self.current() != .r_curly) {
                try self.errors.append(self.allocator, .{
                    .span = self.currentSpan(),
                    .message = Kind.r_curly.symbol(),
                    .found = self.current().symbol(),
                });
            }
            const container = try self.ast.addNode(.{
                .tag = .jsx_expression_container,
                .span = .{ .start = expr_start, .end = self.currentSpan().start },
                .data = .{ .unary = .{ .operand = expr, .flags = 0 } },
            });
            try self.scratch.append(self.allocator, container);
            try self.scanner.nextJSXChild();
        } else if (self.current() == .jsx_text) {
            const text_span = self.currentSpan();
            try self.scratch.append(self.allocator, try self.ast.addNode(.{
                .tag = .jsx_text,
                .span = text_span,
                .data = .{ .string_ref = text_span },
            }));
            try self.scanner.nextJSXChild();
        } else {
            break;
        }

        if (try self.ensureLoopProgress(loop_guard_pos)) break;
    }
    const children = try self.ast.addNodeList(self.scratch.items[children_top..]);
    self.restoreScratch(children_top);
    return children;
}

/// children 내부에서 호출되는 JSX element.
/// closing tag 뒤에 nextJSXChild()로 JSX children 모드를 복원한다.
fn parseJSXElementAsChild(self: *Parser) ParseError2!NodeIndex {
    return parseJSXElementImpl(self, true);
}

/// <Tag ...>children</Tag> 또는 <Tag ... /> 또는 <>...</>
pub fn parseJSXElement(self: *Parser) ParseError2!NodeIndex {
    return parseJSXElementImpl(self, false);
}

/// JSX element/fragment closing tag 이후 스캐너 모드 복원.
/// as_child이면 부모 children 모드(nextJSXChild), 아니면 일반 모드(next).
inline fn advanceAfterJSXClose(self: *Parser, as_child: bool) !void {
    if (as_child) {
        try self.scanner.nextJSXChild();
    } else {
        try self.scanner.next();
    }
}

fn parseJSXElementImpl(self: *Parser, as_child: bool) ParseError2!NodeIndex {
    self.ast.has_jsx = true;
    const start = self.currentSpan().start;
    try self.scanner.nextInsideJSXElement(); // '<' 이후 JSX 모드

    // Fragment: <>
    if (self.current() == .r_angle) {
        try self.scanner.nextJSXChild(); // '>' 이후 children 모드
        return parseJSXFragment(self, start, as_child);
    }

    // Opening tag: <TagName
    const tag_name = try parseJSXTagName(self);

    // TS JSX type arguments: <Foo<T> ... /> or <Foo<<T>(x:T)=>T> ... />
    // 태그 이름 뒤에 '<'가 오면 type arguments로 파싱하여 스트리핑.
    // type args 파싱은 일반 scanner 모드를 쓰므로, 끝난 후 JSX 모드로 재스캔.
    if (self.is_ts and self.current() == .l_angle) {
        _ = try self.parseTypeArguments();
        // type args 닫는 > 이후 토큰이 일반 모드로 스캔됨 → JSX 모드로 재스캔
        try self.scanner.nextInsideJSXElement();
    }

    // Attributes
    const scratch_top = self.saveScratch();
    while (self.current() != .r_angle and self.current() != .slash and self.current() != .eof) {
        const loop_guard_pos = self.scanner.token.span.start;
        const attr = try parseJSXAttribute(self);
        try self.scratch.append(self.allocator, attr);

        if (try self.ensureLoopProgress(loop_guard_pos)) break;
    }
    const attrs = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
    self.restoreScratch(scratch_top);

    // Self-closing: />
    if (self.current() == .slash) {
        try self.scanner.nextInsideJSXElement(); // skip /
        try advanceAfterJSXClose(self, as_child);

        // 항상 5 fields: [tag, attrs_start, attrs_len, children_start, children_len]
        // self-closing은 children_len=0으로 통일하여 transformer에서 heuristic 불필요
        const extra_start = try self.ast.addExtra(@intFromEnum(tag_name));
        _ = try self.ast.addExtra(attrs.start);
        _ = try self.ast.addExtra(attrs.len);
        _ = try self.ast.addExtra(0); // children_start (unused)
        _ = try self.ast.addExtra(0); // children_len = 0

        return try self.ast.addNode(.{
            .tag = .jsx_element,
            .span = .{ .start = start, .end = self.currentSpan().start },
            .data = .{ .extra = extra_start },
        });
    }

    // > children </tag>
    try self.scanner.nextJSXChild(); // '>' 이후 children 모드

    const children = try parseJSXChildren(self);

    // Closing tag: </TagName> or </a.b.c>
    try self.scanner.nextInsideJSXElement(); // skip <
    try self.scanner.nextInsideJSXElement(); // skip /
    // skip tag name — member expression (a.b.c) 포함
    if (self.current() == .jsx_identifier or self.current() == .identifier or self.current().isKeyword()) {
        try self.scanner.nextInsideJSXElement();
        // member expression: .identifier 반복
        while (self.current() == .dot) {
            try self.scanner.nextInsideJSXElement(); // skip .
            if (self.current() == .jsx_identifier or self.current() == .identifier or self.current().isKeyword()) {
                try self.scanner.nextInsideJSXElement(); // skip member name
            }
        }
    }
    try advanceAfterJSXClose(self, as_child);

    const extra_start = try self.ast.addExtra(@intFromEnum(tag_name));
    _ = try self.ast.addExtra(attrs.start);
    _ = try self.ast.addExtra(attrs.len);
    _ = try self.ast.addExtra(children.start);
    _ = try self.ast.addExtra(children.len);

    return try self.ast.addNode(.{
        .tag = .jsx_element,
        .span = .{ .start = start, .end = self.currentSpan().start },
        .data = .{ .extra = extra_start },
    });
}

fn parseJSXFragment(self: *Parser, start: u32, as_child: bool) ParseError2!NodeIndex {
    const children = try parseJSXChildren(self);

    // </>
    try self.scanner.nextInsideJSXElement(); // <
    try self.scanner.nextInsideJSXElement(); // /
    try advanceAfterJSXClose(self, as_child);

    return try self.ast.addNode(.{
        .tag = .jsx_fragment,
        .span = .{ .start = start, .end = self.currentSpan().start },
        .data = .{ .list = children },
    });
}

fn parseJSXTagName(self: *Parser) ParseError2!NodeIndex {
    const span = self.currentSpan();
    // JSX 태그 이름: identifier, jsx_identifier, 키워드 모두 허용
    // 예: <div>, <const>, <in>, <return> 등 — JSX에서는 JS 예약어 제한 없음
    if (self.current() == .jsx_identifier or self.current() == .identifier or self.current().isKeyword()) {
        try self.scanner.nextInsideJSXElement();
        var result = try self.ast.addNode(.{
            .tag = .jsx_identifier,
            .span = span,
            .data = .{ .string_ref = span },
        });
        // JSX member expression: <Foo.Bar.Baz>
        while (self.current() == .dot) {
            try self.scanner.nextInsideJSXElement(); // skip '.'
            const member_span = self.currentSpan();
            if (self.current() == .jsx_identifier or self.current() == .identifier or self.current().isKeyword()) {
                try self.scanner.nextInsideJSXElement();
                const member = try self.ast.addNode(.{
                    .tag = .jsx_identifier,
                    .span = member_span,
                    .data = .{ .string_ref = member_span },
                });
                result = try self.ast.addNode(.{
                    .tag = .jsx_member_expression,
                    .span = .{ .start = span.start, .end = member_span.end },
                    .data = .{ .binary = .{ .left = result, .right = member, .flags = 0 } },
                });
            } else break;
        }
        return result;
    }
    try self.addErrorCode(span, "JSX tag name expected", .jsx_tag_expected);
    return NodeIndex.none;
}

fn parseJSXAttribute(self: *Parser) ParseError2!NodeIndex {
    const start = self.currentSpan().start;

    // spread attribute: {...expr}
    if (self.current() == .l_curly) {
        try self.advance();
        if (self.current() == .dot3) {
            try self.advance();
            const expr = try self.parseAssignmentExpression();
            // r_curly 뒤 scanner.next()는 `/>`의 `/`를 정규식으로 오스캔
            if (self.current() != .r_curly) {
                try self.errors.append(self.allocator, .{
                    .span = self.currentSpan(),
                    .message = Kind.r_curly.symbol(),
                    .found = self.current().symbol(),
                });
            }
            try self.scanner.nextInsideJSXElement();
            return try self.ast.addNode(.{
                .tag = .jsx_spread_attribute,
                .span = .{ .start = start, .end = self.currentSpan().start },
                .data = .{ .unary = .{ .operand = expr, .flags = 0 } },
            });
        }
        try self.addErrorCode(self.currentSpan(), "Spread expected", .jsx_spread_expected);
        return NodeIndex.none;
    }

    // name="value" or name={expr}
    const name_span = self.currentSpan();
    try self.scanner.nextInsideJSXElement(); // skip attribute name

    const name = try self.ast.addNode(.{
        .tag = .jsx_identifier,
        .span = name_span,
        .data = .{ .string_ref = name_span },
    });

    var value = NodeIndex.none;
    if (self.current() == .eq) {
        try self.scanner.nextInsideJSXElement(); // skip =
        if (self.current() == .string_literal) {
            const val_span = self.currentSpan();
            try self.scanner.nextInsideJSXElement();
            value = try self.ast.addNode(.{
                .tag = .string_literal,
                .span = val_span,
                .data = .{ .string_ref = val_span },
            });
        } else if (self.current() == .l_curly) {
            try self.advance();
            value = try self.parseAssignmentExpression();
            // r_curly 뒤 scanner.next()는 `/>`의 `/`를 정규식으로 오스캔
            // (r_curly.slashIsRegex() == true) — JSX 모드로 스캔해야 함
            if (self.current() != .r_curly) {
                try self.errors.append(self.allocator, .{
                    .span = self.currentSpan(),
                    .message = Kind.r_curly.symbol(),
                    .found = self.current().symbol(),
                });
            }
            try self.scanner.nextInsideJSXElement();
        }
    }

    return try self.ast.addNode(.{
        .tag = .jsx_attribute,
        .span = .{ .start = start, .end = self.currentSpan().start },
        .data = .{ .binary = .{ .left = name, .right = value, .flags = 0 } },
    });
}
