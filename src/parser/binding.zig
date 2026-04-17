//! Binding Pattern 파싱
//!
//! 바인딩 패턴(destructuring), 식별자, 기본값을 파싱하는 함수들.\n//! oxc의 js/binding.rs에 대응.
//!
//! 참고: references/oxc/crates/oxc_parser/src/js/binding.rs

const std = @import("std");
const ast_mod = @import("ast.zig");
const Node = ast_mod.Node;
const Tag = Node.Tag;
const NodeIndex = ast_mod.NodeIndex;
const NodeList = ast_mod.NodeList;
const token_mod = @import("../lexer/token.zig");
const Kind = token_mod.Kind;
const Span = token_mod.Span;
const Parser = @import("parser.zig").Parser;
const ParseError2 = @import("parser.zig").ParseError2;

pub fn parseBindingPattern(self: *Parser) ParseError2!NodeIndex {
    // TS parameter decorator: @dec x, @dec(() => 0) x
    // 데코레이터 표현식은 클래스의 외부 스코프에서 평가되므로,
    // @dec(await x)에서 await이 유효하려면 외부 async 컨텍스트를 복원해야 한다.
    // decorator를 수집하여 formal_parameter extra에 저장한다.
    var decorators = ast_mod.NodeList{ .start = 0, .len = 0 };
    var deco_start_pos: u32 = 0;
    if (self.current() == .at) {
        deco_start_pos = self.currentSpan().start;
        const saved_async = self.ctx.in_async;
        const saved_formal = self.in_formal_parameters;
        self.ctx.in_async = self.class_scope_async;
        self.in_formal_parameters = false;
        const deco_scratch_top = self.saveScratch();
        while (self.current() == .at) {
            const dec = try self.parseDecorator();
            try self.scratch.append(self.allocator, dec);
        }
        decorators = try self.ast.addNodeList(self.scratch.items[deco_scratch_top..]);
        self.restoreScratch(deco_scratch_top);
        self.ctx.in_async = saved_async;
        self.in_formal_parameters = saved_formal;
    }

    // TS parameter property: public x, private x, protected x, readonly x, override x
    // flags 비트: 0x01=public, 0x02=private, 0x04=protected, 0x08=readonly, 0x10=override
    // readonly와 override는 contextual keyword (identifier로 토큰화됨)
    const is_readonly = self.isContextual("readonly");
    const is_override = self.isContextual("override");
    if (self.current() == .kw_public or self.current() == .kw_private or
        self.current() == .kw_protected or is_readonly or is_override)
    {
        const modifier_span = self.currentSpan();
        const next = try self.peekNextKind();
        // modifier 뒤에 식별자가 오면 parameter property
        // readonly/override는 identifier로 토큰화되므로 next == .identifier에 포함됨
        if (next == .identifier or next == .l_bracket or next == .l_curly) {
            var modifier_flags: u32 = if (is_readonly)
                0x08
            else if (is_override)
                0x10
            else switch (self.current()) {
                .kw_public => 0x01,
                .kw_private => 0x02,
                .kw_protected => 0x04,
                else => 0,
            };
            try self.advance(); // skip first modifier

            // 두 번째 modifier: public readonly x, override readonly x
            if (self.isContextual("readonly")) {
                modifier_flags |= 0x08;
                try self.advance();
            } else if (self.isContextual("override")) {
                modifier_flags |= 0x10;
                try self.advance();
            }

            const inner = try parseBindingPattern(self);
            // formal_parameter: extra = [pattern, type_ann, default, flags, deco_start, deco_len]
            // type_ann과 default는 inner에 이미 포함 (binding_identifier + tryWrapDefaultValue)
            const none = @intFromEnum(NodeIndex.none);
            const span_start = if (deco_start_pos != 0) deco_start_pos else modifier_span.start;
            const extra_start = try self.ast.addExtras(&.{
                @intFromEnum(inner), none,             none,
                modifier_flags,      decorators.start, decorators.len,
            });
            return try self.ast.addNode(.{
                .tag = .formal_parameter,
                .span = .{ .start = span_start, .end = self.currentSpan().start },
                .data = .{ .extra = extra_start },
            });
        }
    }

    // decorator만 있고 modifier가 없는 경우: formal_parameter로 감싸서 decorator 보존
    if (decorators.len > 0) {
        const inner = try parseBindingPatternInner(self);
        const none = @intFromEnum(NodeIndex.none);
        const extra_start = try self.ast.addExtras(&.{
            @intFromEnum(inner), none,             none,
            0,                   decorators.start, decorators.len,
        });
        return try self.ast.addNode(.{
            .tag = .formal_parameter,
            .span = .{ .start = deco_start_pos, .end = self.currentSpan().start },
            .data = .{ .extra = extra_start },
        });
    }

    return parseBindingPatternInner(self);
}

/// decorator/modifier 처리 후의 순수 바인딩 패턴 파싱.
/// parseBindingPattern에서 decorator가 있을 때 내부 패턴을 파싱하기 위해 분리.
fn parseBindingPatternInner(self: *Parser) ParseError2!NodeIndex {
    // 함수 파라미터의 rest binding: ...pattern.
    // ESTree와 동일하게 binding 컨텍스트는 RestElement(=rest_element)로 emit한다 —
    // SpreadElement는 표현식 컨텍스트(call args, array/object spread) 전용.
    if (self.current() == .dot3) {
        const rest_start = self.currentSpan().start;
        try self.advance(); // skip '...'
        const pattern = try parseBindingPattern(self);
        try self.checkBindingRestInit(pattern);
        return try self.ast.addNode(.{
            .tag = .rest_element,
            .span = .{ .start = rest_start, .end = self.currentSpan().start },
            .data = .{ .unary = .{ .operand = pattern, .flags = 0 } },
        });
    }

    // contextual keyword (get/set/number/string 등)도 binding 위치에서 식별자로 유효
    if (self.current() == .identifier or
        (self.current().isKeyword() and !self.current().isReservedKeyword()))
    {
        const span = self.currentSpan();
        if (self.current() == .identifier) try self.checkStrictBinding(span);
        try self.checkIdentifierKeywordUse(span);
        try self.advance();
        const node = try self.ast.addNode(.{
            .tag = .binding_identifier,
            .span = span,
            .data = .{ .string_ref = span },
        });
        _ = try self.eat(.question);
        _ = try self.tryParseTypeAnnotation();
        return tryWrapDefaultValue(self, node);
    }

    switch (self.current()) {
        .l_bracket => {
            const pat = try parseArrayPattern(self);
            _ = try self.eat(.question);
            _ = try self.tryParseTypeAnnotation();
            return tryWrapDefaultValue(self, pat);
        },
        .l_curly => {
            const pat = try parseObjectPattern(self);
            _ = try self.eat(.question);
            _ = try self.tryParseTypeAnnotation();
            return tryWrapDefaultValue(self, pat);
        },
        .escaped_keyword => {
            // escaped await (aw\u0061it)은 script mode에서 식별자로 사용 가능.
            // ECMAScript 12.1.1: await는 Module goal에서만 Syntax Error.
            // 다른 reserved keyword의 escaped 형태는 항상 사용 불가.
            const is_escaped_await = self.isEscapedKeyword("await");
            if (!is_escaped_await or (self.is_module and !self.in_namespace) or self.ctx.in_async) {
                try self.addErrorCode(self.currentSpan(), "Escaped reserved word cannot be used as identifier", .escaped_reserved_word);
            }
            const span = self.currentSpan();
            try self.advance();
            return try self.ast.addNode(.{
                .tag = .binding_identifier,
                .span = span,
                .data = .{ .string_ref = span },
            });
        },
        .escaped_strict_reserved => {
            if (self.is_strict_mode) {
                try self.addErrorCode(self.currentSpan(), "Escaped reserved word cannot be used as identifier in strict mode", .escaped_reserved_word_strict);
            }
            _ = try self.checkYieldAwaitUse(self.currentSpan(), "identifier");
            const span = self.currentSpan();
            try self.advance();
            const node = try self.ast.addNode(.{
                .tag = .binding_identifier,
                .span = span,
                .data = .{ .string_ref = span },
            });
            _ = try self.eat(.question);
            _ = try self.tryParseTypeAnnotation();
            return tryWrapDefaultValue(self, node);
        },
        else => {
            // contextual 키워드는 바인딩 이름으로 사용 가능 (let, yield, async 등)
            // 단, reserved keyword / yield in generator / await in async 는 불가
            if (self.current().isKeyword()) {
                try self.checkKeywordBinding();
                const span = self.currentSpan();
                try self.advance();
                const node2 = try self.ast.addNode(.{
                    .tag = .binding_identifier,
                    .span = span,
                    .data = .{ .string_ref = span },
                });
                return tryWrapDefaultValue(self, node2);
            }
            try self.addErrorCode(self.currentSpan(), "Binding pattern expected", .binding_pattern_expected);
            return NodeIndex.none;
        },
    }
}

/// 하위 호환: 식별자만 필요한 곳에서 호출
pub fn parseBindingIdentifier(self: *Parser) ParseError2!NodeIndex {
    return parseBindingPattern(self);
}

/// `= expr` 이 있으면 assignment_pattern으로 감싼다. 없으면 원본 반환.
/// 기본값 표현식에서는 `in` 연산자가 항상 허용된다 (ECMAScript: Initializer[+In]).
pub fn tryWrapDefaultValue(self: *Parser, node: NodeIndex) ParseError2!NodeIndex {
    if (try self.eat(.eq)) {
        const def_saved = self.enterAllowInContext(true);
        const default_val = try self.parseAssignmentExpression();
        self.restoreContext(def_saved);
        return try self.ast.addNode(.{
            .tag = .assignment_pattern,
            .span = .{ .start = self.ast.getNode(node).span.start, .end = self.currentSpan().start },
            .data = .{ .binary = .{ .left = node, .right = default_val, .flags = 0 } },
        });
    }
    return node;
}

/// 바인딩 이름만 파싱한다 (identifier, [array], {object}).
/// `?`, 타입 어노테이션, default value `=`를 소비하지 않는다.
/// variable declarator에서 사용 — `=`는 initializer이므로 여기서 소비하면 안 됨.
pub fn parseBindingName(self: *Parser) ParseError2!NodeIndex {
    switch (self.current()) {
        .identifier => {
            const span = self.currentSpan();
            try self.checkStrictBinding(span);
            try self.advance();
            return try self.ast.addNode(.{
                .tag = .binding_identifier,
                .span = span,
                .data = .{ .string_ref = span },
            });
        },
        .l_bracket => return parseArrayPattern(self),
        .l_curly => return parseObjectPattern(self),
        .escaped_keyword => {
            // escaped await (aw\u0061it)은 script mode에서 식별자로 사용 가능.
            // ECMAScript 12.1.1: await는 Module goal에서만 Syntax Error.
            // 다른 reserved keyword의 escaped 형태는 항상 사용 불가.
            const is_escaped_await = self.isEscapedKeyword("await");
            if (!is_escaped_await or (self.is_module and !self.in_namespace) or self.ctx.in_async) {
                try self.addErrorCode(self.currentSpan(), "Escaped reserved word cannot be used as identifier", .escaped_reserved_word);
            }
            const span = self.currentSpan();
            try self.advance();
            return try self.ast.addNode(.{
                .tag = .binding_identifier,
                .span = span,
                .data = .{ .string_ref = span },
            });
        },
        .escaped_strict_reserved => {
            if (self.is_strict_mode) {
                try self.addErrorCode(self.currentSpan(), "Escaped reserved word cannot be used as identifier in strict mode", .escaped_reserved_word_strict);
            }
            _ = try self.checkYieldAwaitUse(self.currentSpan(), "identifier");
            const span = self.currentSpan();
            try self.advance();
            return try self.ast.addNode(.{
                .tag = .binding_identifier,
                .span = span,
                .data = .{ .string_ref = span },
            });
        },
        else => {
            if (self.current().isKeyword()) {
                try self.checkKeywordBinding();
                const span = self.currentSpan();
                try self.advance();
                return try self.ast.addNode(.{
                    .tag = .binding_identifier,
                    .span = span,
                    .data = .{ .string_ref = span },
                });
            }
            try self.addErrorCode(self.currentSpan(), "Binding pattern expected", .binding_pattern_expected);
            return NodeIndex.none;
        },
    }
}

/// 단순 식별자 이름만 파싱한다 (타입 어노테이션/기본값 없이).
/// type alias, interface, enum 등 선언 이름에 사용.
pub fn parseSimpleIdentifier(self: *Parser) ParseError2!NodeIndex {
    const span = self.currentSpan();
    if (self.current() == .identifier or self.current() == .escaped_keyword or
        self.current() == .escaped_strict_reserved or self.current().isKeyword())
    {
        if (self.current() == .escaped_keyword) {
            try self.addErrorCode(span, "Escaped reserved word cannot be used as identifier", .escaped_reserved_word);
        } else if (self.current() == .escaped_strict_reserved and self.is_strict_mode) {
            try self.addErrorCode(span, "Escaped reserved word cannot be used as identifier in strict mode", .escaped_reserved_word_strict);
        } else {
            try self.checkKeywordBinding();
        }
        try self.advance();
        return try self.ast.addNode(.{
            .tag = .binding_identifier,
            .span = span,
            .data = .{ .string_ref = span },
        });
    }
    try self.addErrorCode(span, "Identifier expected", .identifier_expected);
    return NodeIndex.none;
}

pub fn parseArrayPattern(self: *Parser) ParseError2!NodeIndex {
    const start = self.currentSpan().start;
    try self.advance(); // skip [

    const scratch_top = self.saveScratch();
    while (self.current() != .r_bracket and self.current() != .eof) {
        const loop_guard_pos = self.scanner.token.span.start;
        if (self.current() == .comma) {
            // elision (빈 슬롯) — placeholder 노드 추가
            const hole_span = self.currentSpan();
            try self.scratch.append(self.allocator, try self.ast.addNode(.{
                .tag = .elision,
                .span = hole_span,
                .data = .{ .none = 0 },
            }));
            try self.advance();
            continue;
        }
        if (self.current() == .dot3) {
            // rest element: ...pattern
            const rest_start = self.currentSpan().start;
            try self.advance(); // skip ...
            const rest_arg = try parseBindingPattern(self);
            try self.checkBindingRestInit(rest_arg);
            const rest = try self.ast.addNode(.{
                .tag = .rest_element,
                .span = .{ .start = rest_start, .end = self.currentSpan().start },
                .data = .{ .unary = .{ .operand = rest_arg, .flags = 0 } },
            });
            try self.scratch.append(self.allocator, rest);
            break; // rest는 항상 마지막
        }
        const elem_raw = try parseBindingName(self);
        // default value: pattern = expr (배열/객체 패턴 뒤의 = default)
        var elem = try tryWrapDefaultValue(self, elem_raw);
        // TS: optional (?) + type annotation — 배열 패턴 요소에도 가능
        _ = try self.eat(.question);
        _ = try self.tryParseTypeAnnotation();
        if (!elem.isNone()) try self.scratch.append(self.allocator, elem);
        if (!try self.eat(.comma)) break;

        if (try self.ensureLoopProgress(loop_guard_pos)) break;
    }

    const end = self.currentSpan().end;
    try self.expect(.r_bracket);

    const elements = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
    self.restoreScratch(scratch_top);

    return try self.ast.addNode(.{
        .tag = .array_pattern,
        .span = .{ .start = start, .end = end },
        .data = .{ .list = elements },
    });
}

pub fn parseObjectPattern(self: *Parser) ParseError2!NodeIndex {
    const start = self.currentSpan().start;
    try self.advance(); // skip {

    const scratch_top = self.saveScratch();
    while (self.current() != .r_curly and self.current() != .eof) {
        const loop_guard_pos = self.scanner.token.span.start;
        if (self.current() == .dot3) {
            // rest element: ...pattern
            const rest_start = self.currentSpan().start;
            try self.advance(); // skip ...
            const rest_arg = try parseBindingPattern(self);
            try self.checkBindingRestInit(rest_arg);
            const rest = try self.ast.addNode(.{
                .tag = .rest_element,
                .span = .{ .start = rest_start, .end = self.currentSpan().start },
                .data = .{ .unary = .{ .operand = rest_arg, .flags = 0 } },
            });
            try self.scratch.append(self.allocator, rest);
            break;
        }

        const prop = try parseBindingProperty(self);
        if (!prop.isNone()) try self.scratch.append(self.allocator, prop);
        if (!try self.eat(.comma)) break;

        if (try self.ensureLoopProgress(loop_guard_pos)) break;
    }

    const end = self.currentSpan().end;
    try self.expect(.r_curly);

    const props = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
    self.restoreScratch(scratch_top);

    return try self.ast.addNode(.{
        .tag = .object_pattern,
        .span = .{ .start = start, .end = end },
        .data = .{ .list = props },
    });
}

pub fn parseBindingProperty(self: *Parser) ParseError2!NodeIndex {
    const start = self.currentSpan().start;

    // shorthand: { x } = { x: x } 또는 { x = defaultVal }
    // 컨텍스트에 따라 식별자로 사용 가능한 키워드도 shorthand로 처리:
    // - contextual keyword (get/set/type/target/from 등): 항상 식별자 가능
    // - await: async 함수 밖에서 식별자 가능 (ECMAScript 12.1.1)
    // - yield: generator 밖에서 식별자 가능
    const is_shorthand_eligible = self.current() == .identifier or
        (self.current().isKeyword() and !self.current().isReservedKeyword() and
            self.current() != .kw_yield) or
        (self.current() == .kw_await and !self.ctx.in_async and (!self.is_module or self.in_namespace or self.ctx.in_function)) or
        (self.current() == .kw_yield and !self.ctx.in_generator and !self.is_strict_mode);
    if (is_shorthand_eligible) {
        const id_span = self.currentSpan();
        const next = try self.peekNextKind();
        if (next == .comma or next == .r_curly or next == .eq) {
            // shorthand property
            try self.checkIdentifierKeywordUse(id_span);
            try self.advance();
            const key = try self.ast.addNode(.{
                .tag = .binding_identifier,
                .span = id_span,
                .data = .{ .string_ref = id_span },
            });
            const value = try tryWrapDefaultValue(self, key);
            return try self.ast.addNode(.{
                .tag = .binding_property,
                .span = .{ .start = start, .end = self.currentSpan().start },
                .data = .{ .binary = .{ .left = key, .right = value, .flags = 0 } },
            });
        }
    }

    // key: pattern = default
    const key = try self.parsePropertyKey();
    // private name (#x) 은 object destructuring pattern에서 사용 불가
    // ECMAScript: ObjectAssignmentPattern의 PropertyName은 PrivateName을 포함하지 않음
    if (!key.isNone() and self.ast.getNode(key).tag == .private_identifier) {
        try self.addErrorCode(self.ast.getNode(key).span, "Private name is not allowed in destructuring pattern", .private_in_destructuring);
    }
    try self.expect(.colon);
    const value_raw = try parseBindingPattern(self);
    // { x: pattern = defaultValue } 형태
    const value = try tryWrapDefaultValue(self, value_raw);

    return try self.ast.addNode(.{
        .tag = .binding_property,
        .span = .{ .start = start, .end = self.currentSpan().start },
        .data = .{ .binary = .{ .left = key, .right = value, .flags = 0 } },
    });
}
