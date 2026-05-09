//! TypeScript object type member parsing helpers.

const ast_mod = @import("../ast.zig");
const NodeIndex = ast_mod.NodeIndex;
const token_mod = @import("../../lexer/token.zig");
const Kind = token_mod.Kind;
const Span = token_mod.Span;
const parser_mod = @import("../parser.zig");
const Parser = parser_mod.Parser;
const ParseError2 = parser_mod.ParseError2;

pub fn parseObjectType(self: *Parser) ParseError2!NodeIndex {
    const start = self.currentSpan().start;
    try self.advance(); // skip {

    const scratch_top = self.saveScratch();
    while (self.current() != .r_curly and self.current() != .eof) {
        const loop_guard_pos = self.scanner.token.span.start;
        const member = try parseTypeMember(self);
        try self.scratch.append(self.allocator, member);
        // ; 또는 , 로 구분. 줄바꿈만으로도 다음 멤버를 시작할 수 있음
        // (콜/컨스트럭트 시그니처 등 separator 없이 newline으로 구분되는 경우)
        if (!try self.eat(.semicolon) and !try self.eat(.comma)) {
            if (self.current() != .r_curly and !self.scanner.token.has_newline_before) break;
        }

        if (try self.ensureLoopProgress(loop_guard_pos)) break;
    }

    const end = self.currentSpan().end;
    try self.expect(.r_curly);

    const members = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
    self.restoreScratch(scratch_top);

    return try self.ast.addNode(.{
        .tag = .ts_type_literal,
        .span = .{ .start = start, .end = end },
        .data = .{ .list = members },
    });
}

/// 타입 리터럴 / 인터페이스 멤버 파싱 (oxc parse_ts_type_signature 대응)
/// 7가지 시그니처 지원:
/// 1. 콜 시그니처: (): Type, <T>(): Type
/// 2. 컨스트럭트 시그니처: new(): Type, new<T>(): Type
/// 3. 인덱스 시그니처: [key: string]: Type
/// 4. getter 시그니처: get x(): Type
/// 5. setter 시그니처: set x(v: Type)
/// 6. 메서드 시그니처: foo(): Type, foo<T>(x: U): V
/// 7. 프로퍼티 시그니처: key: Type, readonly key?: Type
fn parseTypeMember(self: *Parser) ParseError2!NodeIndex {
    const start = self.currentSpan().start;

    // 1. 콜 시그니처: ( 또는 < 로 시작
    if (self.current() == .l_paren or self.isAtOpeningAngleBracket()) {
        return parseSignatureMember(self, start, false);
    }

    // 2. 컨스트럭트 시그니처: new ( 또는 new <
    //    named construct signature: new bar<T>(): R (esbuild 호환)
    if (self.current() == .kw_new) {
        const next = try self.peekNextKind();
        if (next == .l_paren or next == .l_angle) {
            try self.advance(); // skip 'new'
            return parseSignatureMember(self, start, true);
        }
        // new identifier( 또는 new identifier< → named construct signature
        // `new` 뒤에 이름이 오는 패턴. new를 건너뛰고 이름 + 시그니처로 파싱.
        if (next == .identifier or next == .escaped_keyword) {
            try self.advance(); // skip 'new'
            const key = try self.parsePropertyKey();
            _ = try self.eat(.question); // optional
            var type_params = NodeIndex.none;
            if (self.isAtOpeningAngleBracket()) {
                type_params = try self.parseTsTypeParameterDeclaration();
            }
            try self.expect(.l_paren);
            const params = try parseTypeMemberParamList(self);
            const return_type = try self.tryParseReturnType();
            const extra = try self.ast.addExtras(&.{
                @intFromEnum(key),
                @intFromEnum(type_params),
                params.start,
                params.len,
                @intFromEnum(return_type),
            });
            return try self.ast.addNode(.{
                .tag = .ts_method_signature,
                .span = .{ .start = start, .end = self.currentSpan().start },
                .data = .{ .extra = extra },
            });
        }
    }

    // static 수정자 (interface에서 static accessor x 등)
    // static은 kw_static 토큰이므로 별도 체크 필요
    if (self.current() == .kw_static or (self.current() == .identifier and self.isContextual("static"))) {
        const next = try self.peekNextKind();
        if (isFollowedByTypeMemberName(next) or next == .kw_accessor) {
            try self.advance(); // skip 'static'
        }
    }

    // readonly/accessor 수정자 (프로퍼티/인덱스 시그니처에서만 유효)
    var is_readonly = false;
    if ((self.current() == .identifier and self.isContextual("readonly")) or
        self.current() == .kw_accessor)
    {
        const next = try self.peekNextKind();
        if (isFollowedByTypeMemberName(next)) {
            is_readonly = true;
            try self.advance(); // skip 'readonly'/'accessor'
        }
    }

    // 3. 인덱스 시그니처: [key: string]: Type
    if (self.current() == .l_bracket) {
        if (try isIndexSignature(self)) {
            return parseIndexSignature(self, start, is_readonly);
        }
    }

    // 4. getter 시그니처: get x(): Type
    if (self.current() == .identifier and self.isContextual("get")) {
        const next = try self.peekNextKind();
        if (isFollowedByTypeMemberName(next)) {
            try self.advance(); // skip 'get'
            _ = try self.parsePropertyKey();
            // 파라미터 파싱 (getter는 파라미터 없어야 함)
            try self.expect(.l_paren);
            try self.expect(.r_paren);
            _ = try self.tryParseReturnType();
            return try self.ast.addEmptyExtraNode(
                .ts_getter_signature,
                .{ .start = start, .end = self.currentSpan().start },
            );
        }
    }

    // 5. setter 시그니처: set x(v: Type)
    if (self.current() == .identifier and self.isContextual("set")) {
        const next = try self.peekNextKind();
        if (isFollowedByTypeMemberName(next)) {
            try self.advance(); // skip 'set'
            _ = try self.parsePropertyKey();
            // 파라미터 파싱 (setter는 파라미터 1개)
            try self.expect(.l_paren);
            _ = try parseTypeMemberParam(self);
            try self.expect(.r_paren);
            _ = try self.tryParseReturnType();
            return try self.ast.addEmptyExtraNode(
                .ts_setter_signature,
                .{ .start = start, .end = self.currentSpan().start },
            );
        }
    }

    // 6/7. 프로퍼티 이름 파싱 후 메서드 vs 프로퍼티 분기
    const key = try self.parsePropertyKey();
    const is_optional = try self.eat(.question);

    // 6. 메서드 시그니처: 이름 뒤에 ( 또는 < 가 오면 메서드
    if (self.current() == .l_paren or self.isAtOpeningAngleBracket()) {
        // 제네릭 파라미터
        var type_params = NodeIndex.none;
        if (self.isAtOpeningAngleBracket()) {
            type_params = try self.parseTsTypeParameterDeclaration();
        }
        try self.expect(.l_paren);
        const params = try parseTypeMemberParamList(self);
        const return_type = try self.tryParseReturnType();

        const extra = try self.ast.addExtras(&.{
            @intFromEnum(key),
            @intFromEnum(type_params),
            params.start,
            params.len,
            @intFromEnum(return_type),
        });
        return try self.ast.addNode(.{
            .tag = .ts_method_signature,
            .span = .{ .start = start, .end = self.currentSpan().start },
            .data = .{ .extra = extra },
        });
    }

    // 7. 프로퍼티 시그니처: `key: Type` / `key?: Type` / `readonly key: Type` 등.
    //
    // extra layout: [key, type_ann, flags]
    //   key       — property key NodeIndex (binding_identifier / string_literal / ...)
    //   type_ann  — type annotation NodeIndex. `:` 없는 경우 (interface 의 `foo;`) 는 .none
    //   flags     — `PropertySignatureFlags.toU32()` 로 직렬화된 비트필드
    //
    // transformer 는 ts_property_signature 를 통째로 strip 하므로 child_offsets 는 비워둠
    // (`ast.zig` 참고). codegen plugin 은 manual indexing 으로 extras 를 읽어 view config
    // 를 빌드한다 (#2348 § 4 PR #3b).
    var type_ann: NodeIndex = NodeIndex.none;
    if (try self.eat(.colon)) {
        type_ann = try self.parseType();
    }

    const flags: PropertySignatureFlags = .{
        .optional = is_optional,
        .readonly = is_readonly,
    };

    const extra = try self.ast.addExtras(&.{
        @intFromEnum(key),
        @intFromEnum(type_ann),
        flags.toU32(),
    });
    return try self.ast.addNode(.{
        .tag = .ts_property_signature,
        .span = .{ .start = start, .end = self.currentSpan().start },
        .data = .{ .extra = extra },
    });
}

/// `ts_property_signature.extra[2]` 의 flags 비트필드.
/// `TsTypeParamModifier` (line 422) 와 동일한 packed struct + toU32/fromU32 컨벤션.
pub const PropertySignatureFlags = packed struct(u32) {
    optional: bool = false,
    readonly: bool = false,
    _pad: u30 = 0,

    pub const NONE: PropertySignatureFlags = .{};

    pub fn toU32(self: PropertySignatureFlags) u32 {
        return @bitCast(self);
    }

    pub fn fromU32(v: u32) PropertySignatureFlags {
        return @bitCast(v);
    }
};

/// 콜/컨스트럭트 시그니처 공통 파싱
/// 콜: (): Type, <T>(): Type
/// 컨스트럭트: new(): Type, new<T>(): Type
fn parseSignatureMember(self: *Parser, start: u32, is_constructor: bool) ParseError2!NodeIndex {
    // 제네릭 파라미터
    var type_params = NodeIndex.none;
    if (self.isAtOpeningAngleBracket()) {
        type_params = try self.parseTsTypeParameterDeclaration();
    }
    try self.expect(.l_paren);
    const params = try parseTypeMemberParamList(self);
    const return_type = try self.tryParseReturnType();

    const extra = try self.ast.addExtras(&.{
        @intFromEnum(type_params),
        params.start,
        params.len,
        @intFromEnum(return_type),
    });
    return try self.ast.addNode(.{
        .tag = if (is_constructor) .ts_construct_signature else .ts_call_signature,
        .span = .{ .start = start, .end = self.currentSpan().start },
        .data = .{ .extra = extra },
    });
}

/// contextual keyword (get/set/readonly) 다음 토큰이 프로퍼티 이름인지 판별.
/// 프로퍼티 이름이 아닌 토큰 (: , ; } ? <)이면 keyword 자체가 프로퍼티 이름.
fn isFollowedByTypeMemberName(next: Kind) bool {
    return next != .l_paren and next != .colon and next != .comma and
        next != .semicolon and next != .r_curly and next != .question and
        next != .l_angle;
}

/// 타입 멤버 파라미터 리스트 파싱: (param, param, ...) → NodeList
/// l_paren은 이미 소비된 상태. r_paren은 이 함수가 소비.
pub fn parseTypeMemberParamList(self: *Parser) ParseError2!ast_mod.NodeList {
    const scratch_top = self.saveScratch();
    while (self.current() != .r_paren and self.current() != .eof) {
        const loop_guard_pos = self.scanner.token.span.start;
        const param = try parseTypeMemberParam(self);
        try self.scratch.append(self.allocator, param);
        if (!try self.eat(.comma)) break;
        if (try self.ensureLoopProgress(loop_guard_pos)) break;
    }
    const params = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
    self.restoreScratch(scratch_top);
    try self.expect(.r_paren);
    return params;
}

/// 타입 멤버의 파라미터 하나 파싱: name: Type, name?: Type, ...name: Type
pub fn parseTypeMemberParam(self: *Parser) ParseError2!NodeIndex {
    const param_start = self.currentSpan().start;

    // rest 파라미터: ...name
    var is_rest = false;
    if (try self.eat(.dot3)) {
        is_rest = true;
    }

    // this 파라미터: this: Type — this 식별자를 binding_identifier 로 보존.
    // destructuring: [a, b]: Type, {x, y}: Type — pattern NodeIndex 를 key 로 보존.
    // 일반: name: Type — parsePropertyKey 결과를 key 로 보존.
    var key: NodeIndex = NodeIndex.none;
    if (self.current() == .kw_this) {
        const this_span = self.scanner.token.span;
        try self.advance();
        key = try self.ast.addNode(.{
            .tag = .binding_identifier,
            .span = this_span,
            .data = .{ .string_ref = this_span },
        });
    } else if (self.current() == .l_bracket or self.current() == .l_curly) {
        key = try self.parseBindingName();
    } else {
        key = try self.parsePropertyKey();
    }

    const is_optional = try self.eat(.question);
    var type_ann = NodeIndex.none;
    if (try self.eat(.colon)) {
        type_ann = try self.parseType();
    }
    // 기본값: name: Type = value (인터페이스에서는 드물지만 지원)
    if (try self.eat(.eq)) {
        _ = try self.parseAssignmentExpression();
    }

    // 두 tag 의 layout:
    //   ts_rest_type          = .unary (operand = rest 대상 타입)
    //   ts_property_signature = .extra `[key, type_ann, flags]` (Flow / TS 공통 — D103)
    const member_span: Span = .{ .start = param_start, .end = self.currentSpan().start };
    if (is_rest) {
        return try self.ast.addUnaryNode(.ts_rest_type, member_span, type_ann, 0);
    }
    const flags: PropertySignatureFlags = .{
        .optional = is_optional,
        .readonly = false,
    };
    const extra = try self.ast.addExtras(&.{
        @intFromEnum(key),
        @intFromEnum(type_ann),
        flags.toU32(),
    });
    return try self.ast.addNode(.{
        .tag = .ts_property_signature,
        .span = member_span,
        .data = .{ .extra = extra },
    });
}

/// Index signature 파라미터 앞에 올 수 있는 modifier 토큰 (error recovery 용).
/// 정상 문법에선 index signature 에 modifier 불허지만 `[public k: T]: V` 같은
/// malformed 입력을 index signature 로 파싱해야 의미 있는 에러 메시지가 나온다.
/// TS 공식 parser 의 isModifierKind 상응.
fn isIndexSignatureModifier(kind: Kind) bool {
    return switch (kind) {
        .kw_public, .kw_private, .kw_protected, .kw_static => true,
        else => false,
    };
}

/// 인덱스 시그니처 여부 판별. TS 공식 `isUnambiguouslyIndexSignature` (parser.ts) 이식.
/// Computed property key (`[identRef]?: T`) 와 구분하기 위해 2~3-step lookahead.
/// 매핑 타입 `[K in T]` 은 이 함수 호출 전에 isMappedType 에서 먼저 걸러진다. (#1767)
///
/// 허용 패턴:
///   [...            [] (error recovery)
///   [modifier id    (error recovery — [public id, [private id, [protected id, [static id)
///   [id:   [id,     (정상 + error recovery)
///   [id?:  [id?,  [id?]  (optional index param error recovery)
fn isIndexSignature(self: *Parser) ParseError2!bool {
    const saved = self.saveState();
    defer self.restoreState(saved);

    try self.advance(); // skip [

    // [...rest] 또는 [] (error recovery)
    if (self.current() == .dot3 or self.current() == .r_bracket) return true;

    // [public id / [private id / [protected id / [static id (error recovery)
    if (isIndexSignatureModifier(self.current())) {
        try self.advance();
        return self.current() == .identifier;
    }

    // identifier/this 가 아니면 computed key 경로로 폴백
    if (self.current() != .identifier and self.current() != .kw_this) return false;

    try self.advance(); // skip identifier/this

    // [id: 또는 [id,
    if (self.current() == .colon or self.current() == .comma) return true;

    // [id? 뒤에 :, ,, ] 가 오면 optional index parameter (error recovery)
    if (self.current() != .question) return false;

    try self.advance(); // skip ?
    return self.current() == .colon or self.current() == .comma or self.current() == .r_bracket;
}

/// 인덱스 시그니처 파싱: `[key: string]: Type`.
/// Error recovery 로 `[public k: T]`, `[k?: T]`, `[k?]` 같은 malformed 입력도
/// 수용하여 의미 있는 semantic 에러 경로로 흘려보낸다. (#1767)
pub fn parseIndexSignature(self: *Parser, start: u32, is_readonly: bool) ParseError2!NodeIndex {
    try self.advance(); // skip [

    // Error recovery — index sig parameter 앞 modifier 에러 후 skip ([public k: T] 등)
    if (isIndexSignatureModifier(self.current())) {
        try self.addErrorCode(self.currentSpan(), "Modifiers cannot appear on index signature parameters", .ts_index_sig_modifier);
        try self.advance();
    }

    // 파라미터: key: Type
    const param_start = self.currentSpan().start;
    _ = try self.parsePropertyKey();

    // Error recovery — optional marker 에러 후 skip ([k?: T], [k?])
    if (self.current() == .question) {
        try self.addErrorCode(self.currentSpan(), "An index signature parameter cannot have a question mark", .ts_index_sig_optional);
        try self.advance();
    }
    if (try self.eat(.colon)) {
        _ = try self.parseType();
    }
    try self.expect(.r_bracket);

    // : ValueType
    var value_type = NodeIndex.none;
    if (try self.eat(.colon)) {
        value_type = try self.parseType();
    }

    const prop_sig = try self.ast.addEmptyExtraNode(
        .ts_property_signature,
        .{ .start = param_start, .end = self.currentSpan().start },
    );
    const extra = try self.ast.addExtras(&.{
        @intFromEnum(prop_sig),
        @intFromEnum(value_type),
        @as(u32, if (is_readonly) 1 else 0),
    });

    return try self.ast.addNode(.{
        .tag = .ts_index_signature,
        .span = .{ .start = start, .end = self.currentSpan().start },
        .data = .{ .extra = extra },
    });
}
