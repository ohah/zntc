//! Declaration 파싱
//!
//! 함수 선언/표현식, 클래스 선언/표현식, 클래스 멤버 파싱 함수들.
//! oxc의 js/function.rs + js/class.rs에 대응.
//!
//! 참고:
//! - references/oxc/crates/oxc_parser/src/js/function.rs
//! - references/oxc/crates/oxc_parser/src/js/class.rs

const std = @import("std");
const ast_mod = @import("ast.zig");
const Node = ast_mod.Node;
const Tag = Node.Tag;
const NodeIndex = ast_mod.NodeIndex;
const NodeList = ast_mod.NodeList;
const FunctionFlags = ast_mod.FunctionFlags;
const token_mod = @import("../lexer/token.zig");
const Kind = token_mod.Kind;
const Span = token_mod.Span;
const Parser = @import("parser.zig").Parser;
const ParseError2 = @import("parser.zig").ParseError2;

/// TS class member modifier (contextual keywords). parseClassMember에서 2번 사용.
const ts_class_modifiers: []const []const u8 = &.{ "readonly", "abstract", "override", "declare" };

/// 수식어 뒤에 이 토큰이 오면 수식어가 아니라 멤버 이름으로 판단.
/// 예: class C { override() {} } → 'override'는 메서드 이름.
/// 현재 토큰이 abstract/declare 수식어이면 해당 비트를 반환.
/// bit5=abstract (0x20), bit6=declare (0x40).
fn detectAbstractDeclare(self: *Parser) u16 {
    if (self.current() != .identifier) return 0;
    const text = self.scanner.source[self.scanner.token.span.start..self.scanner.token.span.end];
    if (std.mem.eql(u8, text, "abstract")) return 0x20;
    if (std.mem.eql(u8, text, "declare")) return 0x40;
    return 0;
}

fn isModifierTerminator(kind: Kind) bool {
    return kind == .l_paren or kind == .colon or kind == .eq or
        kind == .semicolon or kind == .r_curly or kind == .bang or kind == .question;
}

/// 함수 body 또는 TS 오버로드 시그니처 (세미콜론으로 끝나면 body 없음)
fn parseFunctionBodyOrOverload(self: *Parser) ParseError2!NodeIndex {
    // TS function overload: 세미콜론 또는 EOF로 body 없음
    if (self.current() == .semicolon or self.current() == .eof) {
        _ = try self.eat(.semicolon);
        return NodeIndex.none;
    }
    // ambient context (declare)에서는 body가 없어도 됨 — ASI로 처리
    // 예: `declare function fn()\n function scope() {}`
    if (self.ctx.in_ambient and self.current() != .l_curly) {
        return NodeIndex.none;
    }
    // TS function overload + ASI: 줄바꿈 뒤에 body가 아닌 것이 오면 overload
    // 예: `function fn(): void\n function fn(x: number): void {}`
    if (self.scanner.token.has_newline_before and self.current() != .l_curly) {
        return NodeIndex.none;
    }
    return self.parseFunctionBody();
}

pub fn parseFunctionDeclaration(self: *Parser) ParseError2!NodeIndex {
    return parseFunctionDeclarationWithFlags(self, 0);
}

fn parseFunctionDeclarationWithFlags(self: *Parser, extra_flags: u32) ParseError2!NodeIndex {
    const start = self.currentSpan().start;
    // @__NO_SIDE_EFFECTS__ 주석이 function 키워드 직전에 있으면 캡처
    const had_no_side_effects = self.scanner.token.has_no_side_effects_comment;
    try self.advance(); // skip 'function'

    // generator: function* name()
    var flags = extra_flags;
    if (had_no_side_effects) flags |= FunctionFlags.no_side_effects;
    if (try self.eat(.star)) {
        flags |= FunctionFlags.is_generator;
    }

    const is_async = (flags & FunctionFlags.is_async) != 0;
    const is_generator = (flags & FunctionFlags.is_generator) != 0;

    // ECMAScript 14.1: 함수 선언의 BindingIdentifier는 외부 context([?Yield, ?Await])에서 파싱.
    // enterFunctionContext 이전에 이름을 파싱해야 올바른 yield/await 검증이 된다.
    // 예: function* foo() { function yield() {} } — "yield"는 외부(generator) context에서 에러.
    const name = try self.parseBindingIdentifier();

    const saved_ctx = self.enterFunctionContext(is_async, is_generator);

    // TS 제네릭 타입 파라미터: function foo<T>() {}
    if (self.current() == .l_angle) {
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

    // TS 리턴 타입 어노테이션
    const return_type = try self.tryParseReturnType();

    self.has_simple_params = self.checkSimpleParams(scratch_top);
    try self.checkDuplicateParams(scratch_top);
    const body = try parseFunctionBodyOrOverload(self);

    // retroactive strict mode checks: "use strict" directive가 있으면
    // 함수 이름과 파라미터를 소급 검증 (ECMAScript 14.1.2)
    if (self.is_strict_mode and !saved_ctx.is_strict_mode) {
        try self.checkStrictFunctionName(name);
        try self.checkStrictParamNames(scratch_top);
    }

    self.restoreFunctionContext(saved_ctx);

    const param_list = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
    self.restoreScratch(scratch_top);
    const extra_start = try self.ast.addExtra(@intFromEnum(name));
    _ = try self.ast.addExtra(param_list.start);
    _ = try self.ast.addExtra(param_list.len);
    _ = try self.ast.addExtra(@intFromEnum(body));
    _ = try self.ast.addExtra(flags);
    _ = try self.ast.addExtra(@intFromEnum(return_type));

    return try self.ast.addNode(.{
        .tag = .function_declaration,
        .span = .{ .start = start, .end = self.currentSpan().start },
        .data = .{ .extra = extra_start },
    });
}

/// async function / async arrow를 파싱한다.
/// async 뒤에 function이 오면 async function declaration,
/// 그 외는 expression statement로 처리.
pub fn parseAsyncStatement(self: *Parser) ParseError2!NodeIndex {
    const peek = try self.peekNext();
    // async [no LineTerminator here] function → async function declaration
    if (peek.kind == .kw_function and !peek.has_newline_before) {
        // @__NO_SIDE_EFFECTS__: async 소비 후 function 토큰에 전파
        const had_no_side_effects = self.scanner.token.has_no_side_effects_comment;
        try self.advance(); // skip 'async'
        if (had_no_side_effects) self.scanner.token.has_no_side_effects_comment = true;
        return parseFunctionDeclarationWithFlags(self, FunctionFlags.is_async);
    }
    // async 뒤에 줄바꿈이 있거나 function이 아니면 → expression statement
    return self.parseExpressionStatement();
}

/// export default function / function* — 이름이 선택적 (없으면 anonymous)
/// ECMAScript: HoistableDeclaration[+Default] → function (Params) { Body }
pub fn parseFunctionDeclarationDefaultExport(self: *Parser) ParseError2!NodeIndex {
    return parseFunctionDeclarationWithFlagsOptionalName(self, 0);
}

/// export default async function / async function* — 이름이 선택적
pub fn parseAsyncFunctionDeclarationDefaultExport(self: *Parser) ParseError2!NodeIndex {
    // @__NO_SIDE_EFFECTS__: async 소비 후 function 토큰에 전파
    const had_no_side_effects = self.scanner.token.has_no_side_effects_comment;
    try self.advance(); // skip 'async'
    if (had_no_side_effects) self.scanner.token.has_no_side_effects_comment = true;
    return parseFunctionDeclarationWithFlagsOptionalName(self, FunctionFlags.is_async);
}

/// parseFunctionDeclarationWithFlags와 동일하지만 이름이 선택적.
/// export default에서만 사용.
fn parseFunctionDeclarationWithFlagsOptionalName(self: *Parser, extra_flags: u32) ParseError2!NodeIndex {
    const start = self.currentSpan().start;
    const had_no_side_effects = self.scanner.token.has_no_side_effects_comment;
    try self.advance(); // skip 'function'

    var flags = extra_flags;
    if (had_no_side_effects) flags |= FunctionFlags.no_side_effects;
    if (try self.eat(.star)) {
        flags |= FunctionFlags.is_generator;
    }

    const is_async = (flags & FunctionFlags.is_async) != 0;
    const is_generator = (flags & FunctionFlags.is_generator) != 0;

    // 이름은 선택적: identifier 또는 contextual keyword(defer, of, set 등)가 있으면 파싱
    const name = if (self.current() == .identifier or
        self.current() == .kw_yield or self.current() == .kw_await or
        self.current() == .escaped_keyword or self.current() == .escaped_strict_reserved or
        (self.current().isKeyword() and !self.current().isReservedKeyword()))
        try self.parseBindingIdentifier()
    else
        NodeIndex.none;

    const saved_ctx = self.enterFunctionContext(is_async, is_generator);

    // TS 제네릭 타입 파라미터: function foo<T>() {}
    if (self.current() == .l_angle) {
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

    const return_type = try self.tryParseReturnType();

    self.has_simple_params = self.checkSimpleParams(scratch_top);
    try self.checkDuplicateParams(scratch_top);
    const body = try parseFunctionBodyOrOverload(self);

    // retroactive strict mode checks
    if (self.is_strict_mode and !saved_ctx.is_strict_mode) {
        try self.checkStrictFunctionName(name);
        try self.checkStrictParamNames(scratch_top);
    }

    self.restoreFunctionContext(saved_ctx);

    const param_list = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
    self.restoreScratch(scratch_top);
    const extra_start = try self.ast.addExtra(@intFromEnum(name));
    _ = try self.ast.addExtra(param_list.start);
    _ = try self.ast.addExtra(param_list.len);
    _ = try self.ast.addExtra(@intFromEnum(body));
    _ = try self.ast.addExtra(flags);
    _ = try self.ast.addExtra(@intFromEnum(return_type));

    return try self.ast.addNode(.{
        .tag = .function_declaration,
        .span = .{ .start = start, .end = self.currentSpan().start },
        .data = .{ .extra = extra_start },
    });
}

pub fn parseFunctionExpression(self: *Parser) ParseError2!NodeIndex {
    return parseFunctionExpressionWithFlags(self, 0);
}

pub fn parseFunctionExpressionWithFlags(self: *Parser, extra_flags: u32) ParseError2!NodeIndex {
    const start = self.currentSpan().start;
    const had_no_side_effects = self.scanner.token.has_no_side_effects_comment;
    try self.advance(); // skip 'function'

    // generator: function* () {}
    var flags: u32 = extra_flags;
    if (had_no_side_effects) flags |= FunctionFlags.no_side_effects;
    if (try self.eat(.star)) {
        flags |= FunctionFlags.is_generator;
    }

    const is_async = (flags & FunctionFlags.is_async) != 0;
    const is_generator = (flags & FunctionFlags.is_generator) != 0;

    // 함수 컨텍스트 진입 — 이름/파라미터/본문 모두 이 컨텍스트에서 파싱
    const saved_ctx = self.enterFunctionContext(is_async, is_generator);

    var name = NodeIndex.none;
    // 함수 표현식의 이름: identifier + contextual keyword (get, set, async, from, of 등)
    // ECMAScript에서 reserved keyword만 함수 이름으로 사용 불가
    if (self.current() == .identifier or self.current() == .kw_yield or self.current() == .kw_await or
        (self.current().isKeyword() and !self.current().isReservedKeyword()))
    {
        name = try self.parseBindingIdentifier();
    }

    // TS 제네릭 타입 파라미터: (function<T>() {})
    if (self.current() == .l_angle) {
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

    // TS 리턴 타입 어노테이션
    _ = try self.tryParseReturnType();
    self.has_simple_params = self.checkSimpleParams(scratch_top);
    try self.checkDuplicateParams(scratch_top);
    const body = try self.parseFunctionBodyExpr();

    // retroactive strict mode checks
    if (self.is_strict_mode and !saved_ctx.is_strict_mode) {
        try self.checkStrictFunctionName(name);
        try self.checkStrictParamNames(scratch_top);
    }

    self.restoreFunctionContext(saved_ctx);

    const param_list = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
    self.restoreScratch(scratch_top);
    const extra_start = try self.ast.addExtra(@intFromEnum(name));
    _ = try self.ast.addExtra(param_list.start);
    _ = try self.ast.addExtra(param_list.len);
    _ = try self.ast.addExtra(@intFromEnum(body));
    _ = try self.ast.addExtra(flags);

    return try self.ast.addNode(.{
        .tag = .function_expression,
        .span = .{ .start = start, .end = self.currentSpan().start },
        .data = .{ .extra = extra_start },
    });
}

pub fn parseClassDeclaration(self: *Parser) ParseError2!NodeIndex {
    return parseClassWithDecorators(self, .class_declaration, .{ .start = 0, .len = 0 });
}

pub fn parseClassExpression(self: *Parser) ParseError2!NodeIndex {
    return parseClassWithDecorators(self, .class_expression, .{ .start = 0, .len = 0 });
}

/// class 선언/표현식을 파싱한다.
/// extra = [name, super_class, body, type_params, implements_start, implements_len, deco_start, deco_len]
pub fn parseClassWithDecorators(self: *Parser, tag: Tag, decorators: NodeList) ParseError2!NodeIndex {
    const start = self.currentSpan().start;
    try self.advance(); // skip 'class'

    // ECMAScript 10.2.1: "All parts of a ClassDeclaration or a ClassExpression
    // are strict mode code." — 클래스 이름, extends, 본문 모두 strict mode.
    // 이를 통해 yield/let/static 등 strict mode reserved word가 클래스 이름으로
    // 사용되는 것을 금지하고, 본문 내 yield/await 사용도 올바르게 검증한다.
    const saved_strict_mode = self.is_strict_mode;
    self.is_strict_mode = true;

    // 클래스 이름 (선언은 필수, 표현식은 선택)
    // kw_yield/kw_await는 컨텍스트에 따라 식별자로 사용 가능
    var name = NodeIndex.none;
    if (self.current() == .identifier or
        (self.current() == .kw_yield and !self.ctx.in_generator) or
        (self.current() == .kw_await and !self.ctx.in_async and (!self.is_module or self.in_namespace)) or
        self.current() == .escaped_keyword or self.current() == .escaped_strict_reserved)
    {
        name = try self.parseBindingIdentifier();
    }

    // TS 제네릭 파라미터: class Foo<T> { }
    var type_params = NodeIndex.none;
    if (self.current() == .l_angle) {
        type_params = try self.parseTsTypeParameterDeclaration();
    }

    // extends 절 (선택)
    // ECMAScript: ClassHeritage : extends LeftHandSideExpression
    // LeftHandSideExpression은 CallExpression | NewExpression | OptionalExpression이지
    // ArrowFunctionExpression이나 AssignmentExpression은 아니다.
    // parseCallExpression을 사용하여 arrow function이 heritage에서 파싱되지 않도록 한다.
    // 예: `class extends () => {} {}` → SyntaxError (arrow의 {}가 class body와 충돌)
    var super_class = NodeIndex.none;
    if (try self.eat(.kw_extends)) {
        super_class = try self.parseCallExpression();
        // TS 제네릭 인수: class Foo extends Bar<T> {}
        // parseCallExpression은 TS 타입 인수를 소비하지 않으므로 여기서 스킵
        if (self.current() == .l_angle) {
            _ = try self.parseTypeArguments();
        }
    }

    // TS implements 절 (선택): class Foo implements Bar, Baz
    if (try self.eat(.kw_implements)) {
        _ = try self.parseType();
        while (try self.eat(.comma)) {
            _ = try self.parseType();
        }
    }

    // 클래스 본문 — extends 있으면 has_super_class 설정 (super() 허용 판단)
    // 중첩 class에서 외부 has_super_class를 상속하지 않도록 명시적 설정
    const saved_has_super_class = self.has_super_class;
    self.has_super_class = !super_class.isNone();
    const body = try parseClassBody(self);
    self.has_super_class = saved_has_super_class;

    // strict mode 복원 — 클래스 외부의 strict 상태로 되돌림
    self.is_strict_mode = saved_strict_mode;

    const none = @intFromEnum(NodeIndex.none);
    const extra_start = try self.ast.addExtras(&.{
        @intFromEnum(name),
        @intFromEnum(super_class),
        @intFromEnum(body),
        @intFromEnum(type_params),
        0,                0, // implements (스트리핑 대상이므로 빈 리스트)
        decorators.start, decorators.len,
    });
    _ = none;

    return try self.ast.addNode(.{
        .tag = tag,
        .span = .{ .start = start, .end = self.currentSpan().start },
        .data = .{ .extra = extra_start },
    });
}

fn parseClassBody(self: *Parser) ParseError2!NodeIndex {
    const start = self.currentSpan().start;
    try self.expect(.l_curly);

    // class body 안에서는 in_class=true (super 허용 등)
    const saved_in_class = self.in_class;
    const saved_class_scope_async = self.class_scope_async;
    self.in_class = true;
    // 클래스 외부 스코프의 async 컨텍스트를 저장 (파라미터 데코레이터에서 사용)
    self.class_scope_async = self.ctx.in_async;

    const scratch_top = self.saveScratch();
    while (self.current() != .r_curly and self.current() != .eof) {
        const loop_guard_pos = self.scanner.token.span.start;
        // 세미콜론 스킵 (클래스 본문에서 허용)
        if (self.current() == .semicolon) {
            try self.advance();
            continue;
        }
        const member = try parseClassMember(self);
        if (!member.isNone()) try self.scratch.append(self.allocator, member);

        if (try self.ensureLoopProgress(loop_guard_pos)) break;
    }

    self.in_class = saved_in_class;
    self.class_scope_async = saved_class_scope_async;

    const end = self.currentSpan().end;
    try self.expect(.r_curly);

    const members = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
    self.restoreScratch(scratch_top);

    return try self.ast.addNode(.{
        .tag = .class_body,
        .span = .{ .start = start, .end = end },
        .data = .{ .list = members },
    });
}

fn parseClassMember(self: *Parser) ParseError2!NodeIndex {
    const start = self.currentSpan().start;

    // 데코레이터 (class member 앞) — scratch에 수집 후 멤버 노드의 extra_data에 연결
    const deco_scratch_top = self.saveScratch();
    while (self.current() == .at) {
        const dec = try self.parseDecorator();
        try self.scratch.append(self.allocator, dec);
    }
    const decorators = try self.ast.addNodeList(self.scratch.items[deco_scratch_top..]);
    self.restoreScratch(deco_scratch_top);

    // TS 접근 제어자 (public/private/protected) + readonly + abstract + override + declare
    // 주의: 수식어 뒤에 (, :, =, ;, }, ! 가 오면 수식어가 아니라 멤버 이름이다.
    // 예: class C { override() {} } → 'override'는 메서드 이름
    // abstract/declare 플래그: 트랜스포머에서 해당 멤버를 완전히 제거하기 위해 저장.
    // bit5=abstract (0x20), bit6=declare (0x40)
    var flags: u16 = 0;
    while (self.current() == .kw_public or self.current() == .kw_private or
        self.current() == .kw_protected or
        self.isContextualAny(ts_class_modifiers))
    {
        const next = try self.peekNext();
        if (isModifierTerminator(next.kind)) break;
        // abstract/declare 뒤에 줄바꿈이 있으면 수식어가 아니라 멤버 이름 (ASI)
        // 예: class A { abstract\nfoo(): void {} } → abstract는 필드 이름
        // esbuild: !p.lexer.HasNewlineBefore
        if (next.has_newline_before and detectAbstractDeclare(self) != 0) break;
        flags |= detectAbstractDeclare(self);
        try self.advance(); // skip modifier (스트리핑 대상이므로 AST에 저장 불필요)
    }

    // static 키워드 (선택)
    // static은 멤버 이름으로도 사용 가능: class C { static() {} }
    // static 뒤에 {, (, = 가 오면 이름으로 취급
    if (self.current() == .kw_static) {
        const next = try self.peekNextKind();
        if (next == .l_curly) {
            // static { } — static block
            // static initializer는 자체 arguments 바인딩이 없음.
            // new.target은 허용 (undefined로 평가, ECMAScript 15.7.15)
            try self.advance(); // skip 'static'
            const saved_in_static = self.in_static_initializer;
            const saved_new_target = self.allow_new_target;
            const saved_in_function = self.ctx.in_function;
            const saved_in_loop = self.in_loop;
            const saved_in_switch = self.in_switch;
            const saved_in_generator = self.ctx.in_generator;
            const saved_in_async = self.ctx.in_async;
            const saved_super_property = self.allow_super_property;
            self.in_static_initializer = true;
            self.allow_new_target = true;
            self.allow_super_property = true; // static block에서 super.prop 허용 (ECMAScript 15.7.14)
            // static block은 독립 실행 컨텍스트: return/break/continue/yield 금지
            // +Await: await은 binding identifier로 사용 불가 (ECMAScript 15.7.12)
            self.ctx.in_function = false;
            self.in_loop = false;
            self.in_switch = false;
            self.ctx.in_generator = false;
            self.ctx.in_async = true;
            const body = try self.parseBlockStatement();
            self.in_static_initializer = saved_in_static;
            self.allow_new_target = saved_new_target;
            self.ctx.in_function = saved_in_function;
            self.in_loop = saved_in_loop;
            self.in_switch = saved_in_switch;
            self.ctx.in_generator = saved_in_generator;
            self.ctx.in_async = saved_in_async;
            self.allow_super_property = saved_super_property;
            return try self.ast.addNode(.{
                .tag = .static_block,
                .span = .{ .start = start, .end = self.currentSpan().start },
                .data = .{ .unary = .{ .operand = body, .flags = 0 } },
            });
        }
        // static 뒤에 (, =, ;, } 가 오거나 줄바꿈이 있으면 static은 메서드/프로퍼티 이름
        // 예: class C { static } — "static"이라는 이름의 필드
        // 예: class C { static = 1 } — "static"이라는 이름의 필드 (초기화)
        // 예: class C { static\n } — ASI로 "static" 필드
        if (next != .l_paren and next != .eq and next != .semicolon and
            next != .r_curly and next != .eof and
            !(try self.peekNext()).has_newline_before)
        {
            flags |= 0x01; // static modifier
            try self.advance();
        }
    }

    // Flow: class body variance — static +prop 또는 static -prop, 또는 +prop / -prop (non-static)
    // Flow에서 `+`는 covariant(read-only), `-`는 contravariant(write-only) 프로퍼티를 의미한다.
    // static 키워드 소비 후, 프로퍼티 키 파싱 전에 variance marker를 건너뛴다.
    if (self.is_flow and (self.current() == .plus or self.current() == .minus)) {
        try self.advance(); // skip variance marker
    }

    // static 뒤의 TS modifier도 소비 (static readonly x 등)
    // 주의: 첫 번째 루프와 동일하게 멤버 이름으로 사용되는 경우를 처리
    while (self.current() == .kw_public or self.current() == .kw_private or
        self.current() == .kw_protected or
        self.isContextualAny(ts_class_modifiers))
    {
        const next2 = try self.peekNext();
        if (isModifierTerminator(next2.kind)) break;
        // abstract/declare 뒤에 줄바꿈이 있으면 수식어가 아니라 멤버 이름 (ASI)
        if (next2.has_newline_before and detectAbstractDeclare(self) != 0) break;
        flags |= detectAbstractDeclare(self);
        try self.advance();
    }

    // accessor (선택): TC39 Decorators proposal — `accessor x = 1`
    // accessor는 modifier이므로 get/set보다 먼저 파싱.
    // `accessor get(){}` → "get"이라는 이름의 accessor field (get은 메서드 이름).
    // `accessor()`, `accessor;`, `accessor =` 는 "accessor"라는 이름의 일반 멤버.
    // `accessor\n a = 42` → "accessor"라는 필드 + "a"라는 필드 (줄바꿈 = ASI).
    var is_accessor = false;
    if (self.current() == .kw_accessor) {
        const next = try self.peekNext();
        if (!next.has_newline_before and
            next.kind != .l_paren and next.kind != .eq and next.kind != .semicolon and
            next.kind != .r_curly and next.kind != .eof)
        {
            is_accessor = true;
            try self.advance(); // skip 'accessor'
        }
    }

    // get/set (선택)
    // get/set 다음에 ;, =, }, EOF, ( 가 오면 프로퍼티 이름이지 getter/setter가 아님.
    // 예: class C { get; } — "get"이라는 이름의 필드
    // 예: class C { get = 1; } — "get"이라는 이름의 필드 (초기화)
    // 예: class C { get foo() {} } — getter 선언
    // get/set: 다음 토큰이 줄바꿈 없이 프로퍼티 이름이면 accessor, 아니면 필드 이름
    // 예: class A { get\n*x() {} } → get은 필드 (ASI), *x는 generator
    const accessor_flag: ?u16 = if (self.current() == .kw_get)
        0x02
    else if (self.current() == .kw_set)
        0x04
    else
        null;
    if (accessor_flag) |flag| {
        const next_tok = try self.peekNext();
        // get/set 뒤 다음 토큰이 accessor 대상이 될 수 있는지 판별.
        // class body에서 get\nx()는 accessor (줄바꿈 있어도). 단, get\n*x()는 ASI.
        // TypeScript PR#60225: newline은 * 앞에서만 ASI 유발
        const is_accessor_target = next_tok.kind != .l_paren and
            next_tok.kind != .semicolon and next_tok.kind != .eq and
            next_tok.kind != .r_curly and next_tok.kind != .eof;
        const newline_blocks = next_tok.has_newline_before and
            (next_tok.kind == .star or next_tok.kind == .kw_async);
        if (is_accessor_target and !newline_blocks) {
            flags |= flag;
            try self.advance();
        }
    }

    // async (선택): async [no LineTerminator here] MethodName
    // 스펙: async와 다음 토큰(*/PropertyName) 사이에 줄바꿈이 없어야 함
    if (self.current() == .kw_async and try self.peekNextKind() != .l_paren and
        !(try self.peekNext()).has_newline_before)
    {
        flags |= 0x08; // async flag
        try self.advance();
    }

    // generator (선택): *method() {}
    if (try self.eat(.star)) {
        flags |= 0x10; // generator flag
    }

    // TS 인덱스 시그니처: [key: string]: any — class body에서만 유효, 타입 스트리핑 대상
    // 클래스에서는 computed property [expr]와 구분해야 하므로, [identifier :] 패턴을 엄격히 확인.
    // 타입 리터럴의 isIndexSignature()는 identifier 뒤를 확인하지 않아 여기서는 사용 불가.
    if (self.current() == .l_bracket) {
        const saved = self.saveState();
        try self.advance(); // skip [
        if (self.current() == .identifier or self.current() == .kw_this) {
            try self.advance(); // skip identifier
            if (self.current() == .colon) {
                // [identifier : 패턴 확인 → 인덱스 시그니처
                self.restoreState(saved);
                // parseIndexSignature가 [ 부터 파싱
                const idx_sig = try self.parseIndexSignature(start, false);
                _ = idx_sig;
                // 세미콜론 소비 (optional)
                _ = try self.eat(.semicolon);
                // index signature는 TS 전용이므로 스트리핑 — 빈 노드 반환
                return NodeIndex.none;
            }
        }
        // 인덱스 시그니처가 아님 → 원래 위치로 복구
        self.restoreState(saved);
    }

    // 키
    const key = try self.parsePropertyKey();

    // TS optional class field: foo?: Type (프로퍼티 이름 뒤의 ?)
    // TS definite assignment: foo!: Type (프로퍼티 이름 뒤의 !)
    _ = try self.eat(.question); // optional marker (스트리핑 대상)
    if (self.current() == .bang and !self.scanner.token.has_newline_before) {
        // ! 뒤에 : 이면 definite assignment assertion, 아니면 non-null 표현식
        const next = try self.peekNextKind();
        if (next == .colon or next == .semicolon or next == .eq or next == .r_curly) {
            try self.advance(); // skip !
        }
    }

    // 제네릭 파라미터: method<T>()
    if (self.current() == .l_angle) {
        _ = try self.parseTsTypeParameterDeclaration();
    }

    // 메서드 (파라미터 리스트가 있으면)
    if (self.current() == .l_paren) {
        // 메서드 파라미터는 자체 arguments 바인딩을 가지므로
        // static initializer/class field의 arguments 제한이 적용되지 않는다.
        const saved_in_static_init = self.in_static_initializer;
        const saved_in_class_field_for_params = self.in_class_field;
        const saved_in_async_for_params = self.ctx.in_async;
        const saved_in_generator_for_params = self.ctx.in_generator;
        const saved_super_prop_for_params = self.allow_super_property;
        self.in_static_initializer = false;
        self.in_class_field = false;
        // 메서드의 파라미터에서 async/generator 컨텍스트 설정
        // 非async/非generator 메서드에서는 await/yield를 식별자로 사용 가능
        self.ctx.in_async = (flags & 0x08) != 0;
        self.ctx.in_generator = (flags & 0x10) != 0;
        // class 메서드의 파라미터에서 super.prop 허용 (ECMAScript 15.7.5)
        self.allow_super_property = true;
        try self.expect(.l_paren);
        self.in_formal_parameters = true;
        try self.trySkipThisParameter();
        const param_top = self.saveScratch();
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

        // TS 리턴 타입 어노테이션: (): Type
        _ = try self.tryParseReturnType();

        // static method 'prototype' 금지 (ECMAScript 15.7.1)
        // private method '#constructor' 금지
        if (!key.isNone()) {
            const mk = self.ast.getNode(key);
            const method_name = if (mk.tag == .identifier_reference)
                self.ast.source[mk.span.start..mk.span.end]
            else if (mk.tag == .string_literal and mk.span.end > mk.span.start + 2)
                self.ast.source[mk.span.start + 1 .. mk.span.end - 1]
            else
                @as([]const u8, "");
            if ((flags & 0x01) != 0 and std.mem.eql(u8, method_name, "prototype")) {
                try self.addError(mk.span, "Static class method cannot be named 'prototype'");
            }
            // constructor는 일반 method만 가능 — getter/setter/generator/async 금지
            if ((flags & 0x01) == 0 and std.mem.eql(u8, method_name, "constructor")) {
                // flags: 0x02=getter, 0x04=setter, 0x08=async, 0x10=generator
                if ((flags & 0x1E) != 0) {
                    try self.addError(mk.span, "Class constructor cannot be a getter, setter, generator, or async");
                }
            }
            // private name '#constructor' 금지
            if (mk.tag == .private_identifier) {
                const pn = self.ast.source[mk.span.start..mk.span.end];
                if (std.mem.eql(u8, pn, "#constructor")) {
                    try self.addError(mk.span, "Class member cannot be named '#constructor'");
                }
            }
        }

        // 바디: abstract 메서드는 바디 없음 (세미콜론으로 끝남)
        // 메서드도 함수이므로 컨텍스트 설정
        var body = NodeIndex.none;
        if (self.current() == .l_curly) {
            // 메서드의 async/generator 플래그는 함수와 비트 위치가 다름 (0x08/0x10)
            const saved_ctx = self.enterFunctionContext((flags & 0x08) != 0, (flags & 0x10) != 0);
            // class 메서드는 super.prop 허용 (ECMAScript 12.3.7)
            self.allow_super_property = true;
            // constructor에서는 super() 호출도 허용
            if (!key.isNone() and (flags & 0x01) == 0) { // non-static
                const mk = self.ast.getNode(key);
                const kt = if (mk.tag == .identifier_reference)
                    self.ast.source[mk.span.start..mk.span.end]
                else if (mk.tag == .string_literal and mk.span.end > mk.span.start + 2)
                    self.ast.source[mk.span.start + 1 .. mk.span.end - 1]
                else
                    @as([]const u8, "");
                if (std.mem.eql(u8, kt, "constructor")) {
                    // extends가 있는 class의 constructor에서만 super() 허용
                    if (self.has_super_class) {
                        self.allow_super_call = true;
                    }
                }
            }
            self.has_simple_params = self.checkSimpleParams(param_top);
            try self.checkDuplicateParams(param_top);
            body = try self.parseFunctionBodyExpr();
            self.restoreFunctionContext(saved_ctx);
        } else {
            _ = try self.eat(.semicolon);
        }
        // 파라미터 전에 변경한 플래그 복원 (if/else 양쪽 공통)
        // restoreFunctionContext는 enterFunctionContext 시점의 (이미 false인) 값을
        // 복원하므로, 여기서 원래 값으로 다시 복원해야 한다.
        self.in_static_initializer = saved_in_static_init;
        self.in_class_field = saved_in_class_field_for_params;
        self.ctx.in_async = saved_in_async_for_params;
        self.ctx.in_generator = saved_in_generator_for_params;
        self.allow_super_property = saved_super_prop_for_params;
        const param_list = try self.ast.addNodeList(self.scratch.items[param_top..]);
        self.restoreScratch(param_top);

        // method_definition: extra = [key, params_start, params_len, body, flags, deco_start, deco_len]
        const extra_start = try self.ast.addExtras(&.{
            @intFromEnum(key),
            param_list.start,
            param_list.len,
            @intFromEnum(body),
            flags,
            decorators.start,
            decorators.len,
        });

        return try self.ast.addNode(.{
            .tag = .method_definition,
            .span = .{ .start = start, .end = self.currentSpan().start },
            .data = .{ .extra = extra_start },
        });
    }

    // class field 이름 검증 (ECMAScript 15.7.1)
    if (!key.isNone()) {
        const key_node = self.ast.getNode(key);
        // identifier 또는 string literal 키에서 이름 추출
        const key_text = if (key_node.tag == .identifier_reference)
            self.ast.source[key_node.span.start..key_node.span.end]
        else if (key_node.tag == .string_literal and key_node.span.end > key_node.span.start + 2)
            self.ast.source[key_node.span.start + 1 .. key_node.span.end - 1] // 따옴표 제거
        else
            @as([]const u8, "");

        if (key_text.len > 0) {
            // class field 이름 'constructor' 금지 — static/non-static 모두 (ECMAScript 15.7.1)
            if (std.mem.eql(u8, key_text, "constructor")) {
                try self.addError(key_node.span, "Class field cannot be named 'constructor'");
            }
            if ((flags & 0x01) != 0 and std.mem.eql(u8, key_text, "prototype")) {
                try self.addError(key_node.span, "Static class field cannot be named 'prototype'");
            }
        }
        // private field '#constructor' 금지
        if (key_node.tag == .private_identifier) {
            const pn = self.ast.source[key_node.span.start..key_node.span.end];
            if (std.mem.eql(u8, pn, "#constructor")) {
                try self.addError(key_node.span, "Class member cannot be named '#constructor'");
            }
        }
    }

    // TS 타입 어노테이션: value: Type
    _ = try self.tryParseTypeAnnotation();

    // 프로퍼티 (= 이니셜라이저) — class field에서 arguments 사용 금지
    // ECMAScript: Initializer[+In, ~Yield, ~Await] — yield/await는 키워드가 아닌 식별자로 취급
    var init_val = NodeIndex.none;
    if (try self.eat(.eq)) {
        const saved_in_class_field = self.in_class_field;
        const saved_new_target = self.allow_new_target;
        const saved_super_property = self.allow_super_property;
        const saved_in_async = self.ctx.in_async;
        const saved_in_generator = self.ctx.in_generator;
        self.in_class_field = true;
        self.allow_new_target = true; // class field에서 new.target 허용 (ECMAScript 15.7.15)
        self.allow_super_property = true; // class field에서 super.prop 허용 (ECMAScript 15.7.5)
        self.ctx.in_async = false; // class field: ~Await (await는 식별자)
        self.ctx.in_generator = false; // class field: ~Yield (yield는 식별자)
        init_val = try self.parseAssignmentExpression();
        self.in_class_field = saved_in_class_field;
        self.allow_new_target = saved_new_target;
        self.allow_super_property = saved_super_property;
        self.ctx.in_async = saved_in_async;
        self.ctx.in_generator = saved_in_generator;
    }
    // class field 끝에서 ASI 규칙 적용: 같은 줄에 다른 멤버가 오면 에러
    try self.expectSemicolon();

    // property_definition / accessor_property:
    // extra = [key, init_val, flags, deco_start, deco_len]
    const prop_extra_start = try self.ast.addExtras(&.{
        @intFromEnum(key),
        @intFromEnum(init_val),
        flags,
        decorators.start,
        decorators.len,
    });
    return try self.ast.addNode(.{
        .tag = if (is_accessor) .accessor_property else .property_definition,
        .span = .{ .start = start, .end = self.currentSpan().start },
        .data = .{ .extra = prop_extra_start },
    });
}
