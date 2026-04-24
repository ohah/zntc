//! TypeScript 파싱
//!
//! TS 타입 어노테이션, 선언(interface, type alias, enum, namespace),
//! decorator, 제네릭 파라미터를 파싱하는 함수들.
//! oxc의 ts/types.rs + ts/statement.rs에 대응.
//!
//! 참고:
//! - references/oxc/crates/oxc_parser/src/ts/types.rs
//! - references/oxc/crates/oxc_parser/src/ts/statement.rs

const std = @import("std");
const ast_mod = @import("ast.zig");
const Node = ast_mod.Node;
const Tag = Node.Tag;
const NodeIndex = ast_mod.NodeIndex;
const Kind = @import("../lexer/token.zig").Kind;

/// TS 키워드 타입 이름 → AST Tag 매핑 (parsePrimaryType에서 사용)
const ts_type_keywords = std.StaticStringMap(Tag).initComptime(.{
    .{ "any", .ts_any_keyword },
    .{ "string", .ts_string_keyword },
    .{ "number", .ts_number_keyword },
    .{ "boolean", .ts_boolean_keyword },
    .{ "bigint", .ts_bigint_keyword },
    .{ "symbol", .ts_symbol_keyword },
    .{ "object", .ts_object_keyword },
    .{ "never", .ts_never_keyword },
    .{ "unknown", .ts_unknown_keyword },
    .{ "undefined", .ts_undefined_keyword },
});
const Parser = @import("parser.zig").Parser;
const ParseError2 = @import("parser.zig").ParseError2;

// ================================================================
// TypeScript Declarations
// ================================================================

/// type Foo = Type;
pub fn parseTsTypeAliasDeclaration(self: *Parser) ParseError2!NodeIndex {
    const start = self.currentSpan().start;
    try self.advance(); // skip 'type'

    const name = try self.parseSimpleIdentifier();

    // 제네릭 파라미터: type Foo<T> = ...
    var type_params = NodeIndex.none;
    if (self.isAtOpeningAngleBracket()) {
        type_params = try parseTsTypeParameterDeclaration(self);
    }

    try self.expect(.eq);
    const ty = try parseType(self);
    _ = try self.eat(.semicolon);

    const extra_start = try self.ast.addExtra(@intFromEnum(name));
    _ = try self.ast.addExtra(@intFromEnum(type_params));
    _ = try self.ast.addExtra(@intFromEnum(ty));

    return try self.ast.addNode(.{
        .tag = .ts_type_alias_declaration,
        .span = .{ .start = start, .end = self.currentSpan().start },
        .data = .{ .extra = extra_start },
    });
}

/// interface Foo { ... }
/// interface Foo extends Bar, Baz { ... }
/// extra = [name, type_params, extends_start, extends_len, body]
pub fn parseTsInterfaceDeclaration(self: *Parser) ParseError2!NodeIndex {
    const start = self.currentSpan().start;
    try self.advance(); // skip 'interface'

    const name = try self.parseSimpleIdentifier();

    // 제네릭 파라미터
    var type_params = NodeIndex.none;
    if (self.isAtOpeningAngleBracket()) {
        type_params = try parseTsTypeParameterDeclaration(self);
    }

    // extends (콤마 구분 리스트: interface Foo extends Bar, Baz)
    // NodeList(start, len)로 저장하여 다중 extends를 지원한다.
    // extends 없으면 extends_list.len = 0.
    const scratch_top = self.saveScratch();
    if (try self.eat(.kw_extends)) {
        const first = try parseType(self);
        try self.scratch.append(self.allocator, first);
        while (try self.eat(.comma)) {
            const next = try parseType(self);
            try self.scratch.append(self.allocator, next);
        }
    }
    const extends_list = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
    self.restoreScratch(scratch_top);

    // interface body
    const body = try parseObjectType(self);

    const extra_start = try self.ast.addExtras(&.{
        @intFromEnum(name),
        @intFromEnum(type_params),
        extends_list.start,
        extends_list.len,
        @intFromEnum(body),
    });

    return try self.ast.addNode(.{
        .tag = .ts_interface_declaration,
        .span = .{ .start = start, .end = self.currentSpan().start },
        .data = .{ .extra = extra_start },
    });
}

/// const enum Foo { A, B, C }
/// const enum은 일반 enum과 동일하게 파싱하되, flags=1로 표시.
pub fn parseConstEnum(self: *Parser) ParseError2!NodeIndex {
    try self.advance(); // skip 'const'
    return parseTsEnumDeclarationWithFlags(self, 1);
}

/// enum Foo { A, B, C }
pub fn parseTsEnumDeclaration(self: *Parser) ParseError2!NodeIndex {
    return parseTsEnumDeclarationWithFlags(self, 0);
}

/// enum 파싱. flags: 0=일반 enum, 1=const enum.
/// extra = [name, members_start, members_len, flags]
fn parseTsEnumDeclarationWithFlags(self: *Parser, flags: u32) ParseError2!NodeIndex {
    const start = self.currentSpan().start;
    try self.advance(); // skip 'enum'

    const name = try self.parseSimpleIdentifier();
    try self.expect(.l_curly);

    const scratch_top = self.saveScratch();
    while (self.current() != .r_curly and self.current() != .eof) {
        const loop_guard_pos = self.scanner.token.span.start;
        const member = try parseTsEnumMember(self);
        try self.scratch.append(self.allocator, member);
        // TS enum 멤버는 ',' 또는 ';'로 구분 가능 (TypeScript 스펙)
        if (!try self.eat(.comma) and !try self.eat(.semicolon)) break;

        if (try self.ensureLoopProgress(loop_guard_pos)) break;
    }

    const end = self.currentSpan().end;
    try self.expect(.r_curly);

    const members = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
    self.restoreScratch(scratch_top);

    const extra_start = try self.ast.addExtras(&.{
        @intFromEnum(name), members.start, members.len, flags,
    });

    return try self.ast.addNode(.{
        .tag = .ts_enum_declaration,
        .span = .{ .start = start, .end = end },
        .data = .{ .extra = extra_start },
    });
}

fn parseTsEnumMember(self: *Parser) ParseError2!NodeIndex {
    const start = self.currentSpan().start;
    const name = try self.parsePropertyKey();

    var init_val = NodeIndex.none;
    if (try self.eat(.eq)) {
        // enum 초기값에서 await/yield는 다른 멤버를 참조하는 식별자로 취급한다.
        // 예: enum X { await = 1, y = await } → y의 초기값은 await 멤버 참조
        // in_async/in_generator를 끄고 in_enum_initializer를 켜서
        // module-level top-level await도 식별자로 파싱되도록 한다.
        const saved_ctx = self.ctx;
        const saved_in_enum = self.in_enum_initializer;
        self.ctx.in_async = false;
        self.ctx.in_generator = false;
        self.in_enum_initializer = true;
        init_val = try self.parseAssignmentExpression();
        self.ctx = saved_ctx;
        self.in_enum_initializer = saved_in_enum;
    }

    return try self.ast.addNode(.{
        .tag = .ts_enum_member,
        .span = .{ .start = start, .end = self.currentSpan().start },
        .data = .{ .binary = .{ .left = name, .right = init_val, .flags = 0 } },
    });
}

/// namespace Foo { ... } / module "name" { ... }
pub fn parseTsModuleDeclaration(self: *Parser) ParseError2!NodeIndex {
    const start = self.currentSpan().start;
    try self.advance(); // skip 'namespace' or 'module'
    return parseTsModuleBody(self, start);
}

/// namespace body (재귀: A.B.C 중첩 처리). keyword는 이미 소비된 상태.
/// `declare module "*.css" { ... }` 처럼 문자열 리터럴 모듈 이름도 지원.
fn parseTsModuleBody(self: *Parser, start: u32) ParseError2!NodeIndex {
    // declare module "name" { ... } — 문자열 리터럴 모듈 이름 (ambient module declaration)
    // declare module "name"; — body 없는 shorthand (세미콜론 또는 ASI)
    if (self.current() == .string_literal) {
        const str_node = try self.ast.addNode(.{
            .tag = .string_literal,
            .span = self.currentSpan(),
            .data = .{ .none = 0 },
        });
        try self.advance();
        // body 없는 shorthand: declare module 'X'; 또는 ASI
        if (self.current() == .semicolon or self.current() == .eof or
            (self.scanner.token.has_newline_before and self.current() != .l_curly))
        {
            _ = try self.eat(.semicolon);
            return try self.ast.addNode(.{
                .tag = .ts_module_declaration,
                .span = .{ .start = start, .end = self.currentSpan().start },
                .data = .{ .binary = .{ .left = str_node, .right = NodeIndex.none, .flags = 1 } },
            });
        }
        // 문자열 모듈 이름은 flags=1로 표시하여 ambient임을 알림
        const body = try parseNamespaceBodyInContext(self);
        return try self.ast.addNode(.{
            .tag = .ts_module_declaration,
            .span = .{ .start = start, .end = self.currentSpan().start },
            .data = .{ .binary = .{ .left = str_node, .right = body, .flags = 1 } },
        });
    }
    const name = try self.parseSimpleIdentifier();

    // 중첩: namespace A.B.C { }
    if (try self.eat(.dot)) {
        const inner = try parseTsModuleBody(self, start);
        return try self.ast.addNode(.{
            .tag = .ts_module_declaration,
            .span = .{ .start = start, .end = self.currentSpan().start },
            .data = .{ .binary = .{ .left = name, .right = inner, .flags = 0 } },
        });
    }

    // namespace body에서는 export/import 허용 (모듈과 동일한 컨텍스트)
    // in_namespace: await를 식별자로 사용 가능 (IIFE 변환 대상)
    // is_top_level: export/import 허용
    const body = try parseNamespaceBodyInContext(self);

    return try self.ast.addNode(.{
        .tag = .ts_module_declaration,
        .span = .{ .start = start, .end = self.currentSpan().start },
        .data = .{ .binary = .{ .left = name, .right = body, .flags = 0 } },
    });
}

/// namespace body 블록 파싱 — parseBlockStatement와 동일하되 is_top_level을 유지
pub fn parseNamespaceBlock(self: *Parser) ParseError2!NodeIndex {
    const block_start = self.currentSpan().start;
    try self.expect(.l_curly);

    const scratch_top = self.saveScratch();
    while (self.current() != .r_curly and self.current() != .eof) {
        const loop_guard_pos = self.scanner.token.span.start;
        const stmt = try self.parseStatement();
        if (!stmt.isNone()) try self.scratch.append(self.allocator, stmt);
        if (try self.ensureLoopProgress(loop_guard_pos)) break;
    }

    const end = self.currentSpan().end;
    try self.expect(.r_curly);

    const node_list = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
    self.restoreScratch(scratch_top);
    return try self.ast.addNode(.{
        .tag = .block_statement,
        .span = .{ .start = block_start, .end = end },
        .data = .{ .list = node_list },
    });
}

/// namespace/ambient module body를 파싱하면서 in_namespace + is_top_level 컨텍스트를 설정.
/// body 안에서 export/import 허용, await를 식별자로 사용 가능 (IIFE 변환 대상).
fn parseNamespaceBodyInContext(self: *Parser) ParseError2!NodeIndex {
    const saved_namespace = self.in_namespace;
    const saved_ctx = self.ctx;
    defer self.in_namespace = saved_namespace;
    defer self.ctx = saved_ctx;
    self.in_namespace = true;
    self.ctx.is_top_level = true;
    return parseNamespaceBlock(self);
}

/// declare var/let/const/function/class/...
pub fn parseTsDeclareStatement(self: *Parser) ParseError2!NodeIndex {
    try self.advance(); // skip 'declare'
    // declare global { ... } — 글로벌 augmentation (타입 전용, 완전 제거)
    if (self.current() == .identifier and self.isContextual("global")) {
        try self.advance(); // skip 'global'
        _ = try parseNamespaceBlock(self);
        return NodeIndex.none;
    }
    // declare 뒤의 선언은 ambient context — 런타임 코드 없음
    const saved = self.ctx;
    self.ctx.in_ambient = true;
    const stmt = try self.parseStatement();
    self.ctx = saved;
    // namespace 내부의 declare는 이름을 보존해야 함 (export declare const L1)
    // → codegen이 ns.L1 참조 치환에 사용. 본체는 출력하지 않되 이름만 ns_export_map에 등록.
    if (self.in_namespace) return stmt;
    return NodeIndex.none;
}

/// abstract class Foo { }
pub fn parseTsAbstractClass(self: *Parser) ParseError2!NodeIndex {
    try self.advance(); // skip 'abstract'
    return self.parseClassDeclaration();
}

/// @decorator 파싱 후 class/export 문을 파싱
pub fn parseDecoratedStatement(self: *Parser) ParseError2!NodeIndex {
    // 데코레이터 수집
    const scratch_top = self.saveScratch();
    while (self.current() == .at) {
        const dec = try parseDecorator(self);
        try self.scratch.append(self.allocator, dec);
    }
    const decorators = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
    self.restoreScratch(scratch_top);
    // 데코레이터 뒤에 올 수 있는 것: class, export, abstract, declare
    if (self.current() == .kw_class) {
        return self.parseClassWithDecorators(.class_declaration, decorators);
    } else if (self.current() == .kw_export) {
        return @import("module.zig").parseExportDeclarationWithDecorators(self, decorators);
    } else if (self.isContextual("abstract")) {
        return parseTsAbstractClass(self);
    } else if (self.isContextual("declare")) {
        // @dec declare class Foo {} — declare는 스트리핑되므로 NodeIndex.none 반환
        return self.parseTsDeclareStatement();
    } else {
        try self.addErrorCode(self.currentSpan(), "Class or export expected after decorator", .class_or_export_after_decorator);
        return self.parseExpressionStatement();
    }
}

/// @expr — 단일 데코레이터 파싱
pub fn parseDecorator(self: *Parser) ParseError2!NodeIndex {
    const start = self.currentSpan().start;
    try self.advance(); // skip @
    // decorator expression에서 computed member access ([) 금지
    // @dec ["method"]()에서 ["method"]은 다음 멤버의 computed key이지 dec의 member access가 아님
    const saved_in_decorator = self.ctx.in_decorator;
    defer self.ctx.in_decorator = saved_in_decorator;
    self.ctx.in_decorator = true;
    const expr = try self.parseCallExpression();

    // TS decorator with type arguments: @x<Type> property
    // parseCallExpression의 speculative parse는 `<Type>` 뒤에 `(`이 올 때만 성공하므로
    // decorator에서는 `<Type>` 뒤에 식별자가 올 수 있으므로 여기서 별도 처리
    if (self.isAtOpeningAngleBracket()) {
        const saved_scanner = self.saveState();
        const saved_nodes_len = self.ast.nodes.items.len;
        const saved_extra_len = self.ast.extra_data.items.len;
        const saved_scratch = self.saveScratch();
        const saved_errors_len = self.errors.items.len;

        const type_args_ok = ta_blk: {
            _ = self.parseTypeArguments() catch {
                break :ta_blk false;
            };
            break :ta_blk true;
        };

        // 타입 인자 노드는 스트리핑 — AST에서 제거
        self.ast.nodes.items.len = saved_nodes_len;
        self.ast.extra_data.items.len = saved_extra_len;
        self.restoreScratch(saved_scratch);
        self.rollbackErrors(saved_errors_len);
        if (!type_args_ok) {
            // 파싱 실패 시 상태 복원
            self.restoreState(saved_scanner);
        }
        // 성공 시 scanner는 type args 이후를 가리킴 (expr은 type args 없이 유지)
    }

    return try self.ast.addNode(.{
        .tag = .decorator,
        .span = .{ .start = start, .end = self.currentSpan().start },
        .data = .{ .unary = .{ .operand = expr, .flags = 0 } },
    });
}

// ================================================================
// TypeScript Type Parameters
// ================================================================

/// <T, U extends V = W>
pub fn parseTsTypeParameterDeclaration(self: *Parser) ParseError2!NodeIndex {
    const start = self.currentSpan().start;
    try self.expectOpeningAngleBracket();

    const scratch_top = self.saveScratch();
    while (!self.isAtClosingAngleBracket() and self.current() != .eof) {
        const loop_guard_pos = self.scanner.token.span.start;
        const param = try parseTsTypeParameter(self);
        try self.scratch.append(self.allocator, param);
        if (!try self.eat(.comma)) break;

        if (try self.ensureLoopProgress(loop_guard_pos)) break;
    }
    try self.expectClosingAngleBracket();

    const params = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
    self.restoreScratch(scratch_top);

    return try self.ast.addNode(.{
        .tag = .ts_type_parameter_declaration,
        .span = .{ .start = start, .end = self.currentSpan().start },
        .data = .{ .list = params },
    });
}

/// TS 4.7+ 타입 파라미터 modifier flags (variance + const).
/// `<const T>`, `<in T>`, `<out T>`, `<in out T>`, `<const in out T>` 등.
pub const TsTypeParamModifier = packed struct(u8) {
    const_: bool = false,
    in: bool = false,
    out: bool = false,
    _pad: u5 = 0,

    pub const NONE: TsTypeParamModifier = .{};

    pub fn toU32(self: TsTypeParamModifier) u32 {
        return @as(u8, @bitCast(self));
    }

    pub fn fromU32(v: u32) TsTypeParamModifier {
        return @bitCast(@as(u8, @truncate(v)));
    }
};

fn parseTsTypeParameter(self: *Parser) ParseError2!NodeIndex {
    const start = self.currentSpan().start;

    // <in out>에서 out은 수정자가 아닌 이름 — 다음 토큰으로 구분 (oxc parse_ts_type_parameter).
    var modifiers: TsTypeParamModifier = .{};
    while (true) {
        if (self.current() == .kw_const or self.current() == .kw_in) {
            const peek = try self.peekNextKind();
            if (peek == .r_angle or peek == .comma or peek == .kw_extends or peek == .eq) break;
            if (self.current() == .kw_const) modifiers.const_ = true else modifiers.in = true;
            try self.advance();
        } else if (self.current() == .identifier) {
            const text = self.tokenText();
            const is_const = std.mem.eql(u8, text, "const");
            const is_in = std.mem.eql(u8, text, "in");
            const is_out = std.mem.eql(u8, text, "out");
            if (is_const or is_in or is_out) {
                const peek = try self.peekNextKind();
                if (peek == .r_angle or peek == .comma or peek == .kw_extends or peek == .eq) break;
                if (is_const) modifiers.const_ = true;
                if (is_in) modifiers.in = true;
                if (is_out) modifiers.out = true;
                try self.advance();
            } else break;
        } else break;
    }

    const name = try self.parseSimpleIdentifier();

    var constraint = NodeIndex.none;
    if (try self.eat(.kw_extends)) constraint = try parseType(self);

    var default_type = NodeIndex.none;
    if (try self.eat(.eq)) default_type = try parseType(self);

    const extra_start = try self.ast.addExtras(&.{
        @intFromEnum(name),
        @intFromEnum(constraint),
        @intFromEnum(default_type),
        modifiers.toU32(),
    });

    return try self.ast.addNode(.{
        .tag = .ts_type_parameter,
        .span = .{ .start = start, .end = self.currentSpan().start },
        .data = .{ .extra = extra_start },
    });
}

// ================================================================
// TypeScript Type 파싱
// ================================================================

/// `: Type` 어노테이션이 있으면 파싱하고 노드 반환. 없으면 none.
pub fn tryParseTypeAnnotation(self: *Parser) ParseError2!NodeIndex {
    if (self.current() != .colon) return NodeIndex.none;
    // 타입 어노테이션이 아닌 colon인 경우 구분 필요:
    // object literal `{ key: value }`, ternary `? : `, switch `case:` 등
    // 여기서는 binding pattern/variable declarator 컨텍스트에서만 호출되므로 안전
    try self.advance(); // skip ':'
    return parseType(self);
}

/// 리턴 타입 어노테이션 (`: Type`). 함수 선언에서 사용.
/// 타입 프레디케이트도 여기서 감지: x is Type, asserts x is Type, asserts x, this is Type
/// oxc parse_type_or_type_predicate 대응
pub fn tryParseReturnType(self: *Parser) ParseError2!NodeIndex {
    if (self.current() != .colon) return NodeIndex.none;
    try self.advance();
    return parseTypeOrTypePredicate(self);
}

/// 타입 또는 타입 프레디케이트를 파싱
/// oxc parse_type_or_type_predicate (L1287-1306)
fn parseTypeOrTypePredicate(self: *Parser) ParseError2!NodeIndex {
    const start = self.currentSpan().start;

    // asserts 프레디케이트: asserts x, asserts x is Type, asserts this is Type
    if (self.current() == .identifier and self.isContextual("asserts")) {
        const next = try self.peekNextKind();
        if (next == .identifier or next == .kw_this) {
            try self.advance(); // skip 'asserts'
            const param_name = try parsePredicateSubject(self);
            // 선택적 is Type
            var type_ann = NodeIndex.none;
            if (self.current() == .identifier and self.isContextual("is")) {
                try self.advance(); // skip 'is'
                type_ann = try parseType(self);
            }
            return try self.ast.addNode(.{
                .tag = .ts_type_predicate,
                .span = .{ .start = start, .end = self.currentSpan().start },
                .data = .{ .binary = .{ .left = param_name, .right = type_ann, .flags = 1 } }, // flags=1: asserts
            });
        }
    }

    // x is Type 또는 this is Type 판별
    // saveState/restoreState로 speculative 파싱 — 'is' 확인 후 commit 또는 rollback
    if (self.current() == .identifier or self.current() == .kw_this) {
        const next = try self.peekNextKind();
        if (next == .identifier) {
            const saved = self.saveState();
            const err_count = self.errors.items.len;
            const param_node = try parsePredicateSubject(self);
            // 줄바꿈이 is 앞에 있으면 type predicate가 아님
            // (예: { foo(): Foo \n is: Bar } — is는 프로퍼티 이름)
            if (self.current() == .identifier and self.isContextual("is") and !self.scanner.token.has_newline_before) {
                try self.advance();
                const ty = try parseType(self);
                return try self.ast.addNode(.{
                    .tag = .ts_type_predicate,
                    .span = .{ .start = start, .end = self.currentSpan().start },
                    .data = .{ .binary = .{ .left = param_node, .right = ty, .flags = 0 } },
                });
            }
            // 'is'가 아니면 일반 타입 — 상태 복원 후 parseType에 위임
            self.restoreState(saved);
            self.rollbackErrors(err_count);
        }
    }

    return parseType(self);
}

/// asserts/is 프레디케이트의 subject 파싱: this 또는 identifier
fn parsePredicateSubject(self: *Parser) ParseError2!NodeIndex {
    if (self.current() == .kw_this) {
        const this_span = self.currentSpan();
        try self.advance();
        return try self.ast.addNode(.{
            .tag = .ts_this_type,
            .span = this_span,
            .data = .{ .none = 0 },
        });
    }
    const id_span = self.currentSpan();
    try self.advance();
    return try self.ast.addNode(.{
        .tag = .identifier_reference,
        .span = id_span,
        .data = .{ .none = 0 },
    });
}

/// TS 타입을 파싱한다. 조건부 > 유니온 > 인터섹션 > postfix > primary 우선순위.
/// oxc의 parse_ts_type와 동일한 구조.
/// 함수 타입/컨스트럭터 타입은 유니온보다 먼저 감지 (oxc parse_function_or_constructor_type)
pub fn parseType(self: *Parser) ParseError2!NodeIndex {
    // 컨스트럭터 타입: new (x: T) => R, abstract new (x: T) => R
    if (self.current() == .kw_new) {
        const next = try self.peekNextKind();
        if (next == .l_paren or next == .l_angle) {
            return parseFunctionOrConstructorType(self, false);
        }
    }
    // abstract new (x: T) => R
    if (self.current() == .identifier and self.isContextual("abstract")) {
        const next = try self.peekNextKind();
        if (next == .kw_new) {
            return parseFunctionOrConstructorType(self, true);
        }
    }

    const left = try parseUnionType(self);

    // 조건부 타입: T extends U ? X : Y (oxc parse_ts_type L21-41)
    // disallow_conditional_types 컨텍스트에서는 중첩 방지
    // 조건부 타입: T extends U ? X : Y
    // disallow_conditional_types 컨텍스트에서는 중첩 방지
    // 줄바꿈 전 extends는 object type에서 프로퍼티 이름일 수 있음
    // (예: { y: T \n extends: number } — 한 줄이면 conditional, 줄바꿈이면 프로퍼티)
    if (!self.ctx.disallow_conditional_types and
        self.current() == .kw_extends and
        !self.scanner.token.has_newline_before)
    {
        const start = self.ast.getNode(left).span.start;
        try self.advance(); // skip 'extends'
        // extends 절 내부에서는 조건부 타입 비허용 (oxc: context_add DisallowConditionalTypes)
        const saved = self.ctx;
        self.ctx.disallow_conditional_types = true;
        const extends_type = try parseType(self);
        self.ctx = saved;
        try self.expect(.question);
        // true/false 타입에서는 조건부 타입 허용 (oxc: context_remove DisallowConditionalTypes)
        const true_type = try parseType(self);
        try self.expect(.colon);
        const false_type = try parseType(self);
        const extra = try self.ast.addExtras(&.{
            @intFromEnum(left),
            @intFromEnum(extends_type),
            @intFromEnum(true_type),
            @intFromEnum(false_type),
        });
        return try self.ast.addNode(.{
            .tag = .ts_conditional_type,
            .span = .{ .start = start, .end = self.currentSpan().start },
            .data = .{ .extra = extra },
        });
    }

    return left;
}

fn parseUnionType(self: *Parser) ParseError2!NodeIndex {
    // 선행 | 허용: | A | B (oxc L247)
    if (self.current() == .pipe) try self.advance();
    const first = try parseIntersectionType(self);
    if (self.current() != .pipe) return first;

    // `A | B | C` — flat NodeList 로 저장 (layout=.list).
    const scratch_top = self.saveScratch();
    defer self.restoreScratch(scratch_top);
    try self.scratch.append(self.allocator, first);
    const start = self.ast.getNode(first).span.start;
    while (self.current() == .pipe) {
        try self.advance();
        const next = try parseIntersectionType(self);
        try self.scratch.append(self.allocator, next);
    }
    const list = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
    return try self.ast.addListNode(
        .ts_union_type,
        .{ .start = start, .end = self.currentSpan().start },
        list,
    );
}

fn parseIntersectionType(self: *Parser) ParseError2!NodeIndex {
    // 선행 & 허용: & A & B
    if (self.current() == .amp) try self.advance();
    const first = try parseTypeOperatorOrHigher(self);
    if (self.current() != .amp) return first;

    // `A & B & C` — flat NodeList 로 저장 (layout=.list).
    const scratch_top = self.saveScratch();
    defer self.restoreScratch(scratch_top);
    try self.scratch.append(self.allocator, first);
    const start = self.ast.getNode(first).span.start;
    while (self.current() == .amp) {
        try self.advance(); // skip &
        const next = try parseTypeOperatorOrHigher(self);
        try self.scratch.append(self.allocator, next);
    }
    const list = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
    return try self.ast.addListNode(
        .ts_intersection_type,
        .{ .start = start, .end = self.currentSpan().start },
        list,
    );
}

/// oxc parse_type_operator_or_higher: keyof/unique/readonly/infer → postfix
fn parseTypeOperatorOrHigher(self: *Parser) ParseError2!NodeIndex {
    if (self.current() == .identifier) {
        const text = self.tokenText();
        // keyof T
        if (std.mem.eql(u8, text, "keyof") or std.mem.eql(u8, text, "readonly")) {
            const span = self.currentSpan();
            try self.advance();
            const operand = try parseTypeOperatorOrHigher(self);
            return try self.ast.addNode(.{
                .tag = .ts_type_operator,
                .span = .{ .start = span.start, .end = self.currentSpan().start },
                .data = .{ .unary = .{ .operand = operand, .flags = 0 } },
            });
        }
        // unique symbol → type operator. TS에서 unique는 symbol과만 결합 가능.
        if (std.mem.eql(u8, text, "unique")) {
            const next = try self.peekNextKind();
            if (next == .identifier) {
                const span = self.currentSpan();
                try self.advance();
                const operand = try parseTypeOperatorOrHigher(self);
                return try self.ast.addNode(.{
                    .tag = .ts_type_operator,
                    .span = .{ .start = span.start, .end = self.currentSpan().start },
                    .data = .{ .unary = .{ .operand = operand, .flags = 0 } },
                });
            }
            // unique 단독 — type reference로 처리 (아래 fallthrough)
        }
        // infer T (extends C)?
        if (std.mem.eql(u8, text, "infer")) {
            const span = self.currentSpan();
            try self.advance(); // skip 'infer'
            // infer의 타입 파라미터 이름
            try self.advance(); // type param name
            // 선택적 constraint: infer T extends U (TS 4.7+)
            // oxc try_parse_constraint_of_infer_type 대응:
            // speculative 파싱으로 constraint 시도. extends 뒤에 타입을 파싱하되,
            // 외부가 disallow_conditional_types가 아닌데 ? 가 오면 rollback
            // (그 extends는 조건부 타입의 extends이므로 infer constraint가 아님)
            if (self.current() == .kw_extends) {
                const infer_saved = self.saveState();
                const infer_err_count = self.errors.items.len;
                try self.advance(); // skip 'extends'
                // constraint 타입: parseType with disallow_conditional_types=true
                const ctx_saved = self.ctx;
                self.ctx.disallow_conditional_types = true;
                _ = try parseType(self);
                self.ctx = ctx_saved;
                // 외부 컨텍스트가 disallow가 아닌데 ? 가 오면 → extends는 조건부 타입의 것
                if (!ctx_saved.disallow_conditional_types and self.current() == .question) {
                    self.restoreState(infer_saved);
                    self.rollbackErrors(infer_err_count);
                }
            }
            return try self.ast.addEmptyExtraNode(
                .ts_infer_type,
                .{ .start = span.start, .end = self.currentSpan().start },
            );
        }
    }

    // disallow_conditional_types 해제하여 postfix 파싱 (oxc L274-277)
    const saved = self.ctx;
    self.ctx.disallow_conditional_types = false;
    const result = try parsePostfixType(self);
    self.ctx = saved;
    return result;
}

fn parsePostfixType(self: *Parser) ParseError2!NodeIndex {
    var base = try parsePrimaryType(self);

    while (true) {
        if (self.current() == .l_bracket) {
            // "any\n['z']" — 줄바꿈 뒤 `[`는 새 statement로 해석 (ASI).
            // esbuild: "{ ['x']: string \n ['y']: string } must not become a single type"
            if (self.scanner.token.has_newline_before) break;
            const start = self.ast.getNode(base).span.start;
            if (try self.peekNextKind() == .r_bracket) {
                // 배열 타입: T[]
                try self.advance(); // [
                try self.advance(); // ]
                base = try self.ast.addEmptyExtraNode(
                    .ts_array_type,
                    .{ .start = start, .end = self.currentSpan().start },
                );
            } else {
                // 인덱스 접근 타입: T[K]
                try self.advance(); // [
                _ = try parseType(self);
                try self.expect(.r_bracket);
                base = try self.ast.addEmptyExtraNode(
                    .ts_indexed_access_type,
                    .{ .start = start, .end = self.currentSpan().start },
                );
            }
        } else if (self.current() == .bang and !self.scanner.token.has_newline_before) {
            // JSDoc-style postfix !: `number!`
            // TypeScript에서는 유효하지 않지만, esbuild와 동일하게
            // 파싱 후 무시한다 (soft error). 타입 스트리핑에서 제거됨.
            try self.advance();
        } else {
            break;
        }
    }

    return base;
}

fn parsePrimaryType(self: *Parser) ParseError2!NodeIndex {
    const span = self.currentSpan();

    // TS 키워드 타입 (contextual keywords — 렉서에서 .identifier로 토큰화됨)
    // 단, 키워드 뒤에 '.'이 오면 qualified type name (예: any.z) → typeReference로 처리
    if (self.current() == .identifier) {
        const ts_keyword_tag = ts_type_keywords.get(self.tokenText());
        if (ts_keyword_tag) |tag| {
            try self.advance();
            // 키워드 뒤에 '.'이 오면 any.z 같은 qualified 타입 → typeReference로 파싱
            if (self.current() == .dot) {
                var name_end = span.end;
                while (try self.eat(.dot)) {
                    name_end = self.currentSpan().end;
                    try self.advance(); // 멤버 이름
                }
                var type_args = NodeIndex.none;
                if (self.isAtOpeningAngleBracket() and !self.scanner.token.has_newline_before) {
                    type_args = try parseTypeArguments(self);
                }
                const extra_start = try self.ast.addExtra(span.start);
                _ = try self.ast.addExtra(name_end);
                _ = try self.ast.addExtra(@intFromEnum(type_args));
                return try self.ast.addNode(.{
                    .tag = .ts_type_reference,
                    .span = .{ .start = span.start, .end = self.currentSpan().start },
                    .data = .{ .extra = extra_start },
                });
            }
            return try self.ast.addNode(.{
                .tag = tag,
                .span = span,
                .data = .{ .none = 0 },
            });
        }
    }

    switch (self.current()) {
        // void
        .kw_void => {
            try self.advance();
            return try self.ast.addNode(.{
                .tag = .ts_void_keyword,
                .span = span,
                .data = .{ .none = 0 },
            });
        },
        // null
        .kw_null => {
            try self.advance();
            return try self.ast.addNode(.{
                .tag = .ts_null_keyword,
                .span = span,
                .data = .{ .none = 0 },
            });
        },
        // this
        .kw_this => {
            try self.advance();
            return try self.ast.addNode(.{
                .tag = .ts_this_type,
                .span = span,
                .data = .{ .none = 0 },
            });
        },
        // 리터럴 타입 (true, false, 숫자, 문자열)
        .kw_true, .kw_false => {
            try self.advance();
            return try self.ast.addNode(.{
                .tag = .ts_literal_type,
                .span = span,
                .data = .{ .none = 0 },
            });
        },
        .decimal,
        .float,
        .hex,
        .string_literal,
        .decimal_bigint,
        .hex_bigint,
        .octal_bigint,
        .binary_bigint,
        => {
            try self.advance();
            return try self.ast.addNode(.{
                .tag = .ts_literal_type,
                .span = span,
                .data = .{ .string_ref = span },
            });
        },
        // 타입 참조: Foo, Foo.Bar, Foo<T>
        .identifier => return parseTypeReference(self),
        // 괄호 타입: (Type) 또는 함수 타입: (a: T) => R
        .l_paren => return parseParenOrFunctionType(self),
        // 객체 타입 리터럴 또는 매핑 타입
        // 매핑 타입: { [K in T]: V }, { readonly [K in T]?: V }
        // oxc: lookahead(is_start_of_mapped_type)
        .l_curly => {
            if (try isMappedType(self)) {
                return try parseMappedType(self);
            }
            return parseObjectType(self);
        },
        // 제네릭 함수 타입: <T>(x: T) => R
        .l_angle => {
            const type_params = try parseTsTypeParameterDeclaration(self);
            try self.expect(.l_paren);
            const params = try parseTypeMemberParamList(self);
            try self.expect(.arrow);
            const return_type = try parseTypeOrTypePredicate(self);
            const extra = try self.ast.addExtras(&.{
                @intFromEnum(type_params),
                params.start,
                params.len,
                @intFromEnum(return_type),
            });
            return try self.ast.addNode(.{
                .tag = .ts_function_type,
                .span = .{ .start = span.start, .end = self.currentSpan().start },
                .data = .{ .extra = extra },
            });
        },
        // 튜플 타입: [T, U]
        .l_bracket => return parseTupleType(self),
        // typeof T
        .kw_typeof => {
            try self.advance();
            // typeof import("module") → import type (oxc L434-436)
            if (self.current() == .kw_import) {
                return try parseImportType(self, span.start);
            }
            _ = try parseTypeReference(self);
            return try self.ast.addEmptyExtraNode(
                .ts_type_query,
                .{ .start = span.start, .end = self.currentSpan().start },
            );
        },
        // import("module").Type
        .kw_import => return try parseImportType(self, span.start),
        // 음수 리터럴 타입: -1, -2n (oxc L406-418)
        .minus => {
            try self.advance(); // skip -
            if (self.current() == .decimal or self.current() == .float or self.current() == .hex or
                self.current() == .decimal_bigint or self.current() == .hex_bigint or
                self.current() == .octal_bigint or self.current() == .binary_bigint)
            {
                try self.advance();
                return try self.ast.addNode(.{
                    .tag = .ts_literal_type,
                    .span = .{ .start = span.start, .end = self.currentSpan().start },
                    .data = .{ .string_ref = span },
                });
            }
            // 아닌 경우 타입 참조로 폴백
            return try self.ast.addNode(.{ .tag = .invalid, .span = span, .data = .{ .none = 0 } });
        },
        // 템플릿 리터럴 타입: `prefix${T}suffix`
        .template_head, .no_substitution_template => {
            return try parseTemplateLiteralType(self);
        },
        else => {
            // 다른 TS 키워드가 타입 위치에 온 경우 타입 참조로 처리
            if (self.current().isKeyword()) {
                return parseTypeReference(self);
            }
            try self.addErrorCode(span, "Type expected", .ts_type_expected);
            try self.advance();
            return try self.ast.addNode(.{ .tag = .invalid, .span = span, .data = .{ .none = 0 } });
        },
    }
}

fn parseTypeReference(self: *Parser) ParseError2!NodeIndex {
    const start = self.currentSpan().start;
    const name_span = self.currentSpan();
    try self.advance(); // type name

    // Foo.Bar 형태
    var name_end = name_span.end;
    while (try self.eat(.dot)) {
        name_end = self.currentSpan().end;
        try self.advance(); // Bar
    }

    // 제네릭: Foo<T, U> — << (shift_left) 도 중첩 제네릭 시작
    // 줄바꿈 후 <는 제네릭이 아닌 다음 멤버의 시작일 수 있음
    // 예: { <A>(): c.d \n <E>(): g.h } — \n 뒤의 <는 새 콜 시그니처
    var type_args = NodeIndex.none;
    if (self.isAtOpeningAngleBracket() and !self.scanner.token.has_newline_before) {
        type_args = try parseTypeArguments(self);
    }

    const extra_start = try self.ast.addExtra(name_span.start);
    _ = try self.ast.addExtra(name_end);
    _ = try self.ast.addExtra(@intFromEnum(type_args));

    return try self.ast.addNode(.{
        .tag = .ts_type_reference,
        .span = .{ .start = start, .end = self.currentSpan().start },
        .data = .{ .extra = extra_start },
    });
}

pub fn parseTypeArguments(self: *Parser) ParseError2!NodeIndex {
    return parseTypeArgumentsImpl(self, false);
}

/// 식 컨텍스트에서의 타입 인자 파싱 (speculative).
/// 최외곽 닫는 `>`가 정확히 `.r_angle`일 때만 성공한다.
/// `>=`, `>>` 등 복합 토큰이면 실패(에러)로 처리되어 backtrack된다.
/// esbuild의 isParseTypeArgumentsInExpression 플래그에 대응.
pub fn parseTypeArgumentsInExpression(self: *Parser) ParseError2!NodeIndex {
    return parseTypeArgumentsImpl(self, true);
}

fn parseTypeArgumentsImpl(self: *Parser, strict_close: bool) ParseError2!NodeIndex {
    const start = self.currentSpan().start;
    try self.expectOpeningAngleBracket();

    const scratch_top = self.saveScratch();
    while (!self.isAtClosingAngleBracket() and self.current() != .eof) {
        const loop_guard_pos = self.scanner.token.span.start;
        const ty = try parseType(self);
        try self.scratch.append(self.allocator, ty);
        if (!try self.eat(.comma)) break;

        if (try self.ensureLoopProgress(loop_guard_pos)) break;
    }

    // strict_close: 식 컨텍스트에서는 정확히 `>` 토큰만 허용.
    // `>=`나 `>>`는 비교/시프트 연산자이므로 타입 인자가 아니다.
    // 내부 중첩 타입 인자(예: Array<Array<number>>)는 내부 parseType에서
    // 일반 expectClosingAngleBracket으로 `>>`를 분할 처리하므로, 여기서
    // 최외곽만 strict로 검사하면 된다.
    if (strict_close) {
        try self.expect(.r_angle);
    } else {
        try self.expectClosingAngleBracket();
    }

    const types = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
    self.restoreScratch(scratch_top);

    return try self.ast.addNode(.{
        .tag = .ts_type_parameter_instantiation,
        .span = .{ .start = start, .end = self.currentSpan().start },
        .data = .{ .list = types },
    });
}

/// 컨스트럭터 타입: new (x: T) => R, abstract new (x: T) => R
/// oxc parse_function_or_constructor_type 대응
fn parseFunctionOrConstructorType(self: *Parser, is_abstract: bool) ParseError2!NodeIndex {
    const start = self.currentSpan().start;
    if (is_abstract) try self.advance(); // skip 'abstract'
    try self.advance(); // skip 'new'

    // 제네릭 파라미터
    var type_params = NodeIndex.none;
    if (self.isAtOpeningAngleBracket()) {
        type_params = try parseTsTypeParameterDeclaration(self);
    }
    try self.expect(.l_paren);
    const params = try parseTypeMemberParamList(self);
    try self.expect(.arrow);
    const return_type = try parseTypeOrTypePredicate(self);

    const extra = try self.ast.addExtras(&.{
        @intFromEnum(type_params),
        params.start,
        params.len,
        @intFromEnum(return_type),
    });
    return try self.ast.addNode(.{
        .tag = .ts_constructor_type,
        .span = .{ .start = start, .end = self.currentSpan().start },
        .data = .{ .extra = extra },
    });
}

/// 괄호 타입 또는 함수 타입 파싱
/// (Type) → 괄호 타입
/// () => R, (a: T) => R, (a: T, b: U) => R → 함수 타입
/// oxc: is_start_of_function_type_or_constructor_type + parse_function_or_constructor_type
fn parseParenOrFunctionType(self: *Parser) ParseError2!NodeIndex {
    const start = self.currentSpan().start;

    // esbuild 방식: 먼저 함수 타입 파라미터로 파싱 시도 (backtracking).
    // `(params) => ReturnType` 패턴이면 함수 타입, 아니면 괄호 타입 `(Type)`.
    // 이 방식은 `(y: any): (() => {}) => {}` 같은 모호한 경우를 올바르게 처리한다.
    // - `(() => {})`: `(` 뒤에 `()` → 함수 파라미터가 아님 → 괄호 타입으로 폴백
    // - `(y) => {}`: `(` 뒤에 `y)` → `y`는 유효한 파라미터 → 함수 타입
    if (try tryParseFunctionTypeWithBacktracking(self, start)) |fn_type| {
        return fn_type;
    }

    // 함수 타입 아님 — 괄호 타입 (Type)으로 파싱
    try self.advance(); // skip (

    // 빈 괄호
    if (self.current() == .r_paren) {
        try self.advance();
        // 빈 괄호 + => → 함수 타입 () => R (tryParse에서 이미 처리되므로 여기 안 옴)
        if (self.current() == .arrow) {
            try self.advance();
            _ = try parseTypeOrTypePredicate(self);
            return try self.ast.addEmptyExtraNode(
                .ts_function_type,
                .{ .start = start, .end = self.currentSpan().start },
            );
        }
        return try self.ast.addNode(.{ .tag = .ts_void_keyword, .span = .{ .start = start, .end = self.currentSpan().start }, .data = .{ .none = 0 } });
    }

    const inner = try parseType(self);

    // 콤마가 오면 다중 파라미터 — 함수 타입 (이미 tryParse에서 처리되어야 하지만 폴백)
    if (self.current() == .comma) {
        const scratch_top = self.saveScratch();
        try self.scratch.append(self.allocator, inner);
        while (try self.eat(.comma)) {
            if (self.current() == .r_paren) break;
            if (self.current() == .dot3 or isFunctionTypeParam(self)) {
                const param = try parseTypeMemberParam(self);
                try self.scratch.append(self.allocator, param);
                if (self.current() != .comma) break;
                continue;
            }
            const param = try parseType(self);
            try self.scratch.append(self.allocator, param);
        }
        const params = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
        self.restoreScratch(scratch_top);
        try self.expect(.r_paren);
        if (self.current() == .arrow) {
            try self.advance();
            const return_type = try parseTypeOrTypePredicate(self);
            const extra = try self.ast.addExtras(&.{
                @intFromEnum(NodeIndex.none),
                params.start,
                params.len,
                @intFromEnum(return_type),
            });
            return try self.ast.addNode(.{
                .tag = .ts_function_type,
                .span = .{ .start = start, .end = self.currentSpan().start },
                .data = .{ .extra = extra },
            });
        }
        return try self.ast.addEmptyExtraNode(
            .ts_parenthesized_type,
            .{ .start = start, .end = self.currentSpan().start },
        );
    }

    if (self.current() == .r_paren) {
        try self.advance();
    } else {
        try self.expect(.r_paren);
    }

    // 괄호 타입: (Type)
    // 참고: (Type) => R 은 tryParseFunctionTypeWithBacktracking에서 처리됨.
    // 여기서는 => 를 소비하지 않는다.
    return try self.ast.addEmptyExtraNode(
        .ts_parenthesized_type,
        .{ .start = start, .end = self.currentSpan().start },
    );
}

/// 함수 타입 파라미터로 파싱을 시도한다 (backtracking).
/// `(` 뒤의 내용이 함수 파라미터로 유효하고, `)` 뒤에 `=>`가 오면 함수 타입.
/// 실패 시 null 반환, 상태 완전 복원.
fn tryParseFunctionTypeWithBacktracking(self: *Parser, start: u32) ParseError2!?NodeIndex {
    const saved = self.saveState();
    const nodes_before = self.ast.nodes.items.len;
    const extras_before = self.ast.extra_data.items.len;
    const errors_before = self.errors.items.len;

    try self.advance(); // skip (

    // 빈 괄호: () => R
    if (self.current() == .r_paren) {
        try self.advance();
        if (self.current() == .arrow) {
            try self.advance();
            _ = try parseTypeOrTypePredicate(self);
            return try self.ast.addEmptyExtraNode(
                .ts_function_type,
                .{ .start = start, .end = self.currentSpan().start },
            );
        }
        // () 뒤에 => 없음 — 복원
        self.ast.nodes.items.len = nodes_before;
        self.ast.extra_data.items.len = extras_before;
        self.rollbackErrors(errors_before);
        self.restoreState(saved);
        return null;
    }

    // rest parameter → 확정 함수 타입
    if (self.current() == .dot3) {
        const result = try parseFunctionTypeParams(self, start);
        return result;
    }

    // 함수 타입 파라미터 패턴 (identifier:, identifier?, this:, [...], {...})
    // identifier:/identifier? 와 this:/this? 는 모호성 없이 함수 타입 파라미터 확정.
    // [...] 과 {...} 는 괄호 타입 내부의 튜플/오브젝트 타입일 수도 있으므로
    // backtracking으로 시도해야 한다.
    // 예: ({y: z}) — 괄호로 감싼 오브젝트 타입 (함수 파라미터가 아님)
    //     ({y}: T) => R — destructuring 함수 파라미터
    if (self.current() == .l_bracket or self.current() == .l_curly) {
        // 모호한 경우: backtracking으로 함수 타입 시도.
        // parseFunctionTypeParams 내부의 expect(.arrow)가 에러를 추가하고 계속
        // 진행하므로, 에러 카운트로 성공/실패를 판단한다.
        const inner_saved = self.saveState();
        const inner_nodes = self.ast.nodes.items.len;
        const inner_extras = self.ast.extra_data.items.len;
        const inner_errors = self.errors.items.len;
        const result = try parseFunctionTypeParams(self, start);
        if (self.errors.items.len > inner_errors) {
            // 에러 발생 — 함수 타입이 아님, 복원하여 괄호 타입으로 폴백
            self.ast.nodes.items.len = inner_nodes;
            self.ast.extra_data.items.len = inner_extras;
            self.rollbackErrors(inner_errors);
            self.restoreState(inner_saved);
            // 외부 saved로도 복원
            self.ast.nodes.items.len = nodes_before;
            self.ast.extra_data.items.len = extras_before;
            self.rollbackErrors(errors_before);
            self.restoreState(saved);
            return null;
        }
        return result;
    } else if (isFunctionTypeParam(self)) {
        // identifier:/identifier? 또는 this:/this? — 모호성 없음, 함수 타입 확정
        const result = try parseFunctionTypeParams(self, start);
        return result;
    }

    // 단일 식별자 + ) + => 패턴: `(x) => R` — 파라미터 이름이 타입 참조처럼 보임
    // esbuild: trySkipTypeScriptArrowArgsWithBacktracking에서
    // skipTypeScriptFnArgs가 `x)` 를 파라미터로 파싱하고 => 를 기대
    if (self.current() == .identifier or self.current().isKeyword()) {
        try self.advance(); // skip identifier

        // identifier 뒤에 바로 ) 가 오면 단일 무타입 파라미터
        if (self.current() == .r_paren) {
            try self.advance(); // skip )
            if (self.current() == .arrow) {
                // 함수 타입 확정: (x) => R
                try self.advance(); // skip =>
                _ = try parseTypeOrTypePredicate(self);
                return try self.ast.addEmptyExtraNode(
                    .ts_function_type,
                    .{ .start = start, .end = self.currentSpan().start },
                );
            }
        }

        // identifier 뒤에 , 가 오면 다중 파라미터 함수 타입일 수 있음
        // 이 경우는 기존 로직으로 폴백
    }

    // 파라미터로 파싱 실패 — 복원
    self.ast.nodes.items.len = nodes_before;
    self.ast.extra_data.items.len = extras_before;
    self.rollbackErrors(errors_before);
    self.restoreState(saved);
    return null;
}

/// ( 이후 현재 토큰이 함수 타입 파라미터 시작인지 판별
/// identifier/this 다음에 : 또는 ? 가 오면 함수 타입 파라미터
fn isFunctionTypeParam(self: *Parser) bool {
    // identifier/this 다음에 : 또는 ? → 확정 함수 파라미터
    if (self.current() == .identifier or self.current() == .kw_this) {
        const next = self.peekNextKind() catch return false;
        return next == .colon or next == .question;
    }
    // destructuring 패턴: [...] 또는 {...} → 함수 파라미터
    if (self.current() == .l_bracket or self.current() == .l_curly) return true;
    return false;
}

/// 함수 타입 파라미터 리스트를 파싱하여 함수 타입 노드 생성
/// ( 는 이미 소비된 상태, start는 ( 의 위치
fn parseFunctionTypeParams(self: *Parser, start: u32) ParseError2!NodeIndex {
    const params = try parseTypeMemberParamList(self);
    try self.expect(.arrow);
    const return_type = try parseTypeOrTypePredicate(self);

    const extra = try self.ast.addExtras(&.{
        @intFromEnum(NodeIndex.none), // no type params (제네릭은 parsePrimaryType에서 < 감지)
        params.start,
        params.len,
        @intFromEnum(return_type),
    });
    return try self.ast.addNode(.{
        .tag = .ts_function_type,
        .span = .{ .start = start, .end = self.currentSpan().start },
        .data = .{ .extra = extra },
    });
}

fn parseObjectType(self: *Parser) ParseError2!NodeIndex {
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
                type_params = try parseTsTypeParameterDeclaration(self);
            }
            try self.expect(.l_paren);
            const params = try parseTypeMemberParamList(self);
            const return_type = try tryParseReturnType(self);
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
            _ = try tryParseReturnType(self);
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
            _ = try tryParseReturnType(self);
            return try self.ast.addEmptyExtraNode(
                .ts_setter_signature,
                .{ .start = start, .end = self.currentSpan().start },
            );
        }
    }

    // 6/7. 프로퍼티 이름 파싱 후 메서드 vs 프로퍼티 분기
    const key = try self.parsePropertyKey();
    _ = try self.eat(.question); // optional

    // 6. 메서드 시그니처: 이름 뒤에 ( 또는 < 가 오면 메서드
    if (self.current() == .l_paren or self.isAtOpeningAngleBracket()) {
        // 제네릭 파라미터
        var type_params = NodeIndex.none;
        if (self.isAtOpeningAngleBracket()) {
            type_params = try parseTsTypeParameterDeclaration(self);
        }
        try self.expect(.l_paren);
        const params = try parseTypeMemberParamList(self);
        const return_type = try tryParseReturnType(self);

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

    // 7. 프로퍼티 시그니처: key: Type
    if (try self.eat(.colon)) {
        _ = try parseType(self);
        return try self.ast.addEmptyExtraNode(
            .ts_property_signature,
            .{ .start = start, .end = self.currentSpan().start },
        );
    }

    // 타입 어노테이션 없는 프로퍼티 (예: interface에서 `foo;` 또는 `foo?;`)
    return try self.ast.addEmptyExtraNode(
        .ts_property_signature,
        .{ .start = start, .end = self.currentSpan().start },
    );
}

/// 콜/컨스트럭트 시그니처 공통 파싱
/// 콜: (): Type, <T>(): Type
/// 컨스트럭트: new(): Type, new<T>(): Type
fn parseSignatureMember(self: *Parser, start: u32, is_constructor: bool) ParseError2!NodeIndex {
    // 제네릭 파라미터
    var type_params = NodeIndex.none;
    if (self.isAtOpeningAngleBracket()) {
        type_params = try parseTsTypeParameterDeclaration(self);
    }
    try self.expect(.l_paren);
    const params = try parseTypeMemberParamList(self);
    const return_type = try tryParseReturnType(self);

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
fn parseTypeMemberParamList(self: *Parser) ParseError2!ast_mod.NodeList {
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
fn parseTypeMemberParam(self: *Parser) ParseError2!NodeIndex {
    const param_start = self.currentSpan().start;

    // rest 파라미터: ...name
    var is_rest = false;
    if (try self.eat(.dot3)) {
        is_rest = true;
    }

    // this 파라미터: this: Type
    // destructuring: [a, b]: Type, {x, y}: Type
    const name = if (self.current() == .kw_this) blk: {
        const this_span = self.currentSpan();
        try self.advance();
        break :blk try self.ast.addNode(.{
            .tag = .this_expression,
            .span = this_span,
            .data = .{ .none = 0 },
        });
    } else if (self.current() == .l_bracket or self.current() == .l_curly)
        try self.parseBindingName()
    else
        try self.parsePropertyKey();

    _ = try self.eat(.question); // optional
    var type_ann = NodeIndex.none;
    if (try self.eat(.colon)) {
        type_ann = try parseType(self);
    }
    // 기본값: name: Type = value (인터페이스에서는 드물지만 지원)
    if (try self.eat(.eq)) {
        _ = try self.parseAssignmentExpression();
    }

    const tag: Tag = if (is_rest) .ts_rest_type else .ts_property_signature;
    return try self.ast.addNode(.{
        .tag = tag,
        .span = .{ .start = param_start, .end = self.currentSpan().start },
        .data = .{ .binary = .{ .left = name, .right = type_ann, .flags = 0 } },
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
        _ = try parseType(self);
    }
    try self.expect(.r_bracket);

    // : ValueType
    var value_type = NodeIndex.none;
    if (try self.eat(.colon)) {
        value_type = try parseType(self);
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

/// 튜플 타입: [T, U], [name: T, ...rest: U[]], [T?, U?]
/// oxc parse_tuple_type + parse_tuple_element_name_or_tuple_element_type
fn parseTupleType(self: *Parser) ParseError2!NodeIndex {
    const start = self.currentSpan().start;
    try self.advance(); // skip [

    const scratch_top = self.saveScratch();
    while (self.current() != .r_bracket and self.current() != .eof) {
        const loop_guard_pos = self.scanner.token.span.start;
        const elem = try parseTupleElement(self);
        try self.scratch.append(self.allocator, elem);
        if (!try self.eat(.comma)) break;

        if (try self.ensureLoopProgress(loop_guard_pos)) break;
    }

    const end = self.currentSpan().end;
    try self.expect(.r_bracket);

    const types = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
    self.restoreScratch(scratch_top);

    return try self.ast.addNode(.{
        .tag = .ts_tuple_type,
        .span = .{ .start = start, .end = end },
        .data = .{ .list = types },
    });
}

/// 튜플 요소: T, T?, ...T, name: T, name?: T, ...name: T
fn parseTupleElement(self: *Parser) ParseError2!NodeIndex {
    const elem_start = self.currentSpan().start;

    // rest 요소: ...T 또는 ...name: T
    if (self.current() == .dot3) {
        try self.advance(); // skip ...
        const inner = try parseTupleElementInner(self);
        return try self.ast.addNode(.{
            .tag = .ts_rest_type,
            .span = .{ .start = elem_start, .end = self.currentSpan().start },
            .data = .{ .unary = .{ .operand = inner, .flags = 0 } },
        });
    }

    return try parseTupleElementInner(self);
}

/// 라벨드 여부 판별 + 선택적(?) 처리
fn parseTupleElementInner(self: *Parser) ParseError2!NodeIndex {
    // 라벨드 튜플: name: T, name?: T, false: T, true: T, null: T 등
    // 키워드도 라벨 이름으로 허용 (TS 스펙)
    // lookahead: identifier/keyword 다음에 : 또는 ?: 가 오는지
    // name: T → 라벨드 튜플, name?: T → 선택적 라벨드 튜플
    // name? 다음에 : 가 아니면 → 일반 optional type (예: number?)
    if (self.current() == .identifier or self.current().isKeyword()) {
        const next = try self.peekNextKind();
        const is_labeled = next == .colon or (next == .question and blk: {
            // name? 다음이 : 인지 확인 (name?: T vs number?)
            const saved = self.saveState();
            const err_count = self.errors.items.len;
            self.advance() catch break :blk false; // skip name
            self.advance() catch break :blk false; // skip ?
            const after_question = self.current();
            self.restoreState(saved);
            self.rollbackErrors(err_count);
            break :blk after_question == .colon;
        });
        if (is_labeled) {
            const name_span = self.currentSpan();
            try self.advance(); // skip name
            _ = try self.eat(.question);
            try self.expect(.colon);
            _ = try parseType(self);
            return try self.ast.addEmptyExtraNode(
                .ts_named_tuple_member,
                .{ .start = name_span.start, .end = self.currentSpan().start },
            );
        }
    }

    // 일반 요소
    const ty = try parseType(self);

    // 선택적: T?
    if (self.current() == .question) {
        const ty_span = self.ast.getNode(ty).span;
        try self.advance(); // skip ?
        return try self.ast.addNode(.{
            .tag = .ts_optional_type,
            .span = .{ .start = ty_span.start, .end = self.currentSpan().start },
            .data = .{ .unary = .{ .operand = ty, .flags = 0 } },
        });
    }

    return ty;
}

/// 매핑 타입 여부 판별: { [K in T]: V } 또는 { readonly [K in T]?: V }
/// { 다음에 [, +, -, readonly 중 하나가 오고 ... in ... 패턴이면 매핑 타입.
/// 매핑 타입 여부 판별: { [K in T]: V } 또는 { readonly [K in T]?: V }
/// oxc is_start_of_mapped_type 대응 — checkpoint/rewind 패턴
fn isMappedType(self: *Parser) ParseError2!bool {
    if (self.current() != .l_curly) return false;
    const state = self.saveState();
    const err_count = self.errors.items.len;
    defer {
        self.restoreState(state);
        // lookahead 중 추가된 에러 되돌리기
        self.rollbackErrors(err_count);
    }

    try self.advance(); // skip {

    // { + 또는 { - → +readonly/-readonly 수정자 → 매핑 타입 확정
    if (self.current() == .plus or self.current() == .minus) return true;

    // { readonly → readonly 다음에 [ 이면 매핑 타입
    if (self.current() == .identifier and self.isContextual("readonly")) {
        try self.advance(); // skip 'readonly'
        // readonly 다음에 [ 이면 매핑 타입 (인덱스 시그니처는 readonly 뒤에 [ 사용 안 함)
        if (self.current() == .l_bracket) {
            try self.advance(); // skip [
            // [identifier in → 매핑 타입
            if (self.current() == .identifier) {
                try self.advance();
                return self.current() == .kw_in;
            }
            return false;
        }
        return false;
    }

    // { [ → [ 뒤에 identifier in 패턴이면 매핑 타입
    if (self.current() == .l_bracket) {
        try self.advance(); // skip [
        if (self.current() == .identifier) {
            try self.advance();
            return self.current() == .kw_in;
        }
        return false;
    }

    return false;
}

/// 매핑 타입: { [K in T]: V }, { readonly [K in T]+?: V }, { -readonly [K in T]-?: V }
fn parseMappedType(self: *Parser) ParseError2!NodeIndex {
    const start = self.currentSpan().start;
    try self.advance(); // skip {

    // 선택적 readonly 수정자: readonly, +readonly, -readonly
    if (self.current() == .plus or self.current() == .minus) {
        try self.advance(); // skip +/-
        if (self.current() == .identifier and self.isContextual("readonly")) {
            try self.advance();
        }
    } else if (self.current() == .identifier and self.isContextual("readonly")) {
        try self.advance();
    }

    try self.expect(.l_bracket);
    // K in T
    const param_span = self.currentSpan();
    try self.advance(); // type parameter name
    // expect 'in'
    if (self.current() == .kw_in) {
        try self.advance();
    } else {
        try self.addErrorCode(self.currentSpan(), "Expected 'in' in mapped type", .ts_mapped_type_in);
    }
    _ = try parseType(self); // constraint
    // 선택적 as 절: [K in T as NewKey]
    var name_type = NodeIndex.none;
    if (self.current() == .identifier and self.isContextual("as")) {
        try self.advance(); // skip 'as'
        name_type = try parseType(self);
    }
    try self.expect(.r_bracket);

    // 선택적 ? 수정자: ?, +?, -?
    if (self.current() == .plus or self.current() == .minus) {
        try self.advance();
        _ = try self.eat(.question);
    } else {
        _ = try self.eat(.question);
    }

    // : ValueType
    var value_type = NodeIndex.none;
    if (try self.eat(.colon)) {
        value_type = try parseType(self);
    }

    _ = try self.eat(.semicolon);
    try self.expect(.r_curly);

    const type_param_node = try self.ast.addEmptyExtraNode(.ts_type_parameter, param_span);
    const extra = try self.ast.addExtras(&.{
        @intFromEnum(type_param_node),
        @intFromEnum(value_type),
        @intFromEnum(name_type),
    });

    return try self.ast.addNode(.{
        .tag = .ts_mapped_type,
        .span = .{ .start = start, .end = self.currentSpan().start },
        .data = .{ .extra = extra },
    });
}

/// import("module").Type — import type (oxc parse_ts_import_type)
/// import("module", { assert: { type: "json" } }).Type — import attributes (TS 5.3+)
fn parseImportType(self: *Parser, start: u32) ParseError2!NodeIndex {
    try self.advance(); // skip 'import'
    try self.expect(.l_paren);
    _ = try parseType(self); // module specifier
    // import attributes: import("module", { assert: { ... } })
    // 2번째 인자는 옵션 객체. 타입 스트리핑에서 제거되므로 파싱만 하고 버린다.
    if (try self.eat(.comma)) {
        _ = try parseType(self);
    }
    try self.expect(.r_paren);
    // 선택적 .member 접근
    var result = try self.ast.addEmptyExtraNode(
        .ts_import_type,
        .{ .start = start, .end = self.currentSpan().start },
    );
    // .Foo.Bar 체인
    while (self.current() == .dot) {
        try self.advance(); // skip .
        const member_span = self.currentSpan();
        try self.advance(); // member name
        result = try self.ast.addNode(.{
            .tag = .ts_qualified_name,
            .span = .{ .start = start, .end = member_span.end },
            .data = .{ .binary = .{ .left = result, .right = try self.ast.addNode(.{
                .tag = .identifier_reference,
                .span = member_span,
                .data = .{ .none = 0 },
            }), .flags = 0 } },
        });
    }
    // 선택적 제네릭: import("module").Foo<T>
    if (self.isAtOpeningAngleBracket()) {
        _ = try self.parseTypeArguments();
    }
    return result;
}

/// 템플릿 리터럴 타입: `prefix${T}suffix`
fn parseTemplateLiteralType(self: *Parser) ParseError2!NodeIndex {
    const start = self.currentSpan().start;
    // no_substitution_template: 보간 없는 템플릿
    if (self.current() == .no_substitution_template) {
        try self.advance();
        return try self.ast.addNode(.{
            .tag = .ts_literal_type,
            .span = .{ .start = start, .end = self.currentSpan().start },
            .data = .{ .none = 0 },
        });
    }
    // template_head + 타입 보간 + template_middle/tail
    // 기존 expression 템플릿 파서와 동일한 패턴 사용
    const scratch_top = self.saveScratch();
    try self.scratch.append(self.allocator, try self.ast.addNode(.{
        .tag = .template_element,
        .span = self.currentSpan(),
        .data = .{ .none = 0 },
    }));
    try self.advance(); // skip template_head

    while (true) {
        const ty = try parseType(self);
        try self.scratch.append(self.allocator, ty);

        if (self.current() == .template_middle) {
            try self.scratch.append(self.allocator, try self.ast.addNode(.{
                .tag = .template_element,
                .span = self.currentSpan(),
                .data = .{ .none = 0 },
            }));
            try self.advance();
        } else if (self.current() == .template_tail) {
            try self.scratch.append(self.allocator, try self.ast.addNode(.{
                .tag = .template_element,
                .span = self.currentSpan(),
                .data = .{ .none = 0 },
            }));
            try self.advance();
            break;
        } else {
            break;
        }
    }

    _ = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
    self.restoreScratch(scratch_top);
    return try self.ast.addEmptyExtraNode(
        .ts_template_literal_type,
        .{ .start = start, .end = self.currentSpan().start },
    );
}
