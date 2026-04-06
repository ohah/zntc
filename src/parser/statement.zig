//! Statement 파싱
//!
//! 프로그램 최상위 파싱과 모든 statement 타입(block, if, for, while, switch,
//! try/catch, variable declaration, labeled statement 등)을 파싱하는 함수들.
//! oxc의 js/statement.rs에 대응.
//!
//! 참고:
//! - references/oxc/crates/oxc_parser/src/js/statement.rs

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

/// 소스 전체를 파싱하여 AST를 반환한다.
pub fn parse(self: *Parser) !NodeIndex {
    try self.advance(); // 첫 토큰 로드

    // Flow pragma 감지: 첫 토큰 스캔 시 파일 상단 주석이 처리되므로
    // 이 시점에서 scanner.has_flow_pragma가 설정되어 있다.
    self.applyFlowPragma();

    // module 모드면 항상 strict (D054)
    if (self.is_module) {
        self.is_strict_mode = true;
    }

    // hashbang (#! ...) 건너뛰기
    if (self.current() == .hashbang_comment) {
        try self.advance();
    }

    var stmts: std.ArrayList(NodeIndex) = .empty;
    defer stmts.deinit(self.allocator);

    // directive prologue 감지: 프로그램 시작 부분의 "use strict"
    var in_directive_prologue = true;

    while (self.current() != .eof) {
        const loop_guard_pos = self.scanner.token.span.start;

        if (in_directive_prologue) {
            if (self.isUseStrictDirective()) {
                self.is_strict_mode = true;
                self.strict_from_directive = true;
            } else if (self.current() != .string_literal) {
                // directive prologue는 문자열 expression statement가 연속되는 동안 유효
                in_directive_prologue = false;
            }
        }

        const stmt = try parseStatement(self);
        if (!stmt.isNone()) {
            try stmts.append(self.allocator, stmt);
        }

        if (try self.ensureLoopProgress(loop_guard_pos)) break;
    }

    // Unambiguous 모드 해결: import/export 유무로 module/script 확정 (oxc 방식)
    try self.resolveModuleKind();

    const list = try self.ast.addNodeList(stmts.items);
    return try self.ast.addNode(.{
        .tag = .program,
        .span = .{ .start = 0, .end = @intCast(self.scanner.source.len) },
        .data = .{ .list = list },
    });
}

/// statement position에서 lexical/function declaration 금지를 체크한 뒤 parseStatement 호출.
/// is_loop_body: true면 for/while/do-while/with body (function도 항상 금지)
///               false면 if/else/labeled body (function은 Annex B로 non-strict 허용)
pub fn parseStatementChecked(self: *Parser, comptime is_loop_body: bool) ParseError2!NodeIndex {
    switch (self.current()) {
        .kw_const => {
            // TS const enum은 완전히 지워지므로 label 위치 허용
            if (!self.is_ts or try self.peekNextKind() != .kw_enum) {
                try self.addError(self.currentSpan(), "Lexical declaration is not allowed in statement position");
            }
        },
        .kw_let => {
            if (self.is_strict_mode) {
                try self.addError(self.currentSpan(), "Lexical declaration is not allowed in statement position");
            } else if (try isLetDeclarationStart(self)) {
                // sloppy mode에서도 `let`이 LexicalDeclaration으로 해석되면 에러
                // isLetDeclarationStart: 줄바꿈 없이 identifier/[/{, 또는 줄바꿈 있어도 [
                try self.addError(self.currentSpan(), "Lexical declaration is not allowed in statement position");
            }
        },
        .kw_class => {
            // class declaration은 statement position에서 항상 금지 (Annex B에 class 예외 없음)
            try self.addError(self.currentSpan(), "Class declaration is not allowed in statement position");
        },
        .kw_function => {
            if (try self.peekNextKind() == .star) {
                // generator는 항상 금지
                try self.addError(self.currentSpan(), "Generator declaration is not allowed in statement position");
            } else if (is_loop_body) {
                // loop/with body에서 function은 항상 금지 (ECMAScript 13.7.4, Annex B 미적용)
                try self.addError(self.currentSpan(), "Function declaration is not allowed in statement position");
            } else if (self.is_strict_mode) {
                // if/else/labeled body에서는 strict mode에서만 금지
                try self.addError(self.currentSpan(), "Function declaration is not allowed in statement position in strict mode");
            }
        },
        .kw_async => {
            const peek = try self.peekNext();
            if (peek.kind == .kw_function and !peek.has_newline_before) {
                try self.addError(self.currentSpan(), "Async function declaration is not allowed in statement position");
            }
        },
        .kw_export => {
            try self.addError(self.currentSpan(), "'export' is not allowed in statement position");
        },
        .kw_import => {
            // import()와 import.meta는 expression이므로 제외
            const peek = try self.peekNextKind();
            if (peek != .l_paren and peek != .dot) {
                try self.addError(self.currentSpan(), "'import' is not allowed in statement position");
            }
        },
        else => {},
    }
    return parseStatement(self);
}

pub fn parseStatement(self: *Parser) ParseError2!NodeIndex {
    return switch (self.current()) {
        .l_curly => parseBlockStatement(self),
        .semicolon => parseEmptyStatement(self),
        .kw_var => parseVariableDeclaration(self),
        // ECMAScript: sloppy mode에서 `let`은 LexicalDeclaration으로 취급되려면
        // 뒤에 줄바꿈 없이 BindingIdentifier, `[`, `{`가 와야 한다.
        // 그렇지 않으면 식별자로 취급하여 expression statement로 파싱한다.
        .kw_let => if (self.is_strict_mode or try isLetDeclarationStart(self))
            parseVariableDeclaration(self)
        else
            parseExpressionStatement(self),
        .kw_const => if (try self.peekNextKind() == .kw_enum)
            self.parseConstEnum()
        else
            parseVariableDeclaration(self),
        // using declaration (TC39 Stage 3: Explicit Resource Management)
        // `using x = getResource()` — parsed like const
        .kw_using => if (try isUsingDeclarationStart(self))
            parseVariableDeclaration(self)
        else
            parseExpressionOrLabeledStatement(self),
        // await using declaration: `await using x = getResource()`
        .kw_await => if (try isAwaitUsingDeclarationStart(self))
            parseAwaitUsingDeclaration(self)
        else
            parseExpressionOrLabeledStatement(self),
        .kw_return => parseReturnStatement(self),
        .kw_if => parseIfStatement(self),
        .kw_while => parseWhileStatement(self),
        .kw_do => parseDoWhileStatement(self),
        .kw_for => parseForStatement(self),
        .kw_switch => parseSwitchStatement(self),
        .kw_break => parseSimpleStatement(self, .break_statement),
        .kw_continue => parseSimpleStatement(self, .continue_statement),
        .kw_throw => parseThrowStatement(self),
        .kw_try => parseTryStatement(self),
        .kw_debugger => parseSimpleStatement(self, .debugger_statement),
        .kw_async => self.parseAsyncStatement(),
        .kw_function => self.parseFunctionDeclaration(),
        .kw_class => self.parseClassDeclaration(),
        .kw_import => blk: {
            const next = try self.peekNextKind();
            break :blk if (next == .l_paren or next == .dot)
                parseExpressionStatement(self)
            else
                self.parseImportDeclaration();
        },
        .kw_export => self.parseExportDeclaration(),
        // Decorator: @expr class Foo {}
        .at => self.parseDecoratedStatement(),
        // TypeScript contextual keyword declarations
        // type, namespace, module, declare, abstract는 identifier로 토큰화되므로
        // 문자열 비교로 판별한다.
        .identifier => blk: {
            const text = self.tokenText();
            if (std.mem.eql(u8, text, "type")) {
                // type Foo = ... → TS type alias declaration
                // type = 1, type.x, type() → expression statement (변수로 사용)
                // type\nFoo = {} → 'type' expression statement + 'Foo = {}' (ASI)
                // esbuild: !p.lexer.HasNewlineBefore && p.lexer.Token == TIdentifier
                const next = try self.peekNext();
                if (!next.has_newline_before and
                    (next.kind == .identifier or next.kind == .l_curly or next.kind == .string_literal))
                {
                    if (self.is_flow) {
                        break :blk self.parseFlowTypeAliasDeclaration();
                    }
                    break :blk self.parseTsTypeAliasDeclaration();
                }
            } else if (self.is_flow and std.mem.eql(u8, text, "opaque")) {
                // opaque type Foo = Type; (Flow 전용)
                const next_opaque = try self.peekNext();
                if (!next_opaque.has_newline_before and next_opaque.kind == .identifier) {
                    break :blk self.parseFlowOpaqueType();
                }
            } else if (!self.is_flow and (std.mem.eql(u8, text, "namespace") or std.mem.eql(u8, text, "module"))) {
                // namespace/module — TS 전용 (Flow에서는 일반 식별자)
                const next_ns = try self.peekNext();
                if (!next_ns.has_newline_before and
                    (next_ns.kind == .identifier or next_ns.kind == .l_curly or next_ns.kind == .string_literal))
                {
                    break :blk self.parseTsModuleDeclaration();
                }
            } else if (std.mem.eql(u8, text, "declare")) {
                const next_decl = try self.peekNext();
                if (!next_decl.has_newline_before and switch (next_decl.kind) {
                    .semicolon,
                    .l_paren,
                    .l_bracket,
                    .eq,
                    .dot,
                    .question_dot,
                    .plus,
                    .minus,
                    .star,
                    .slash,
                    .pipe,
                    .amp,
                    .comma,
                    .plus_eq,
                    .minus_eq,
                    .star_eq,
                    .slash_eq,
                    .eof,
                    .r_curly,
                    => false,
                    else => true,
                }) {
                    if (self.is_flow) {
                        break :blk self.parseFlowDeclareStatement();
                    }
                    break :blk self.parseTsDeclareStatement();
                }
            } else if (self.is_flow and (std.mem.eql(u8, text, "component") or std.mem.eql(u8, text, "hook"))) {
                // Flow Component/Hook Syntax: component Foo(...) { } / hook useFoo(...) { }
                const next_comp = try self.peekNext();
                if (!next_comp.has_newline_before and next_comp.kind == .identifier) {
                    break :blk self.parseFlowComponentDeclaration();
                }
            } else if (!self.is_flow and std.mem.eql(u8, text, "abstract")) {
                // abstract — TS 전용 (Flow에서는 일반 식별자)
                const next = try self.peekNext();
                if (next.kind == .kw_class and !next.has_newline_before) {
                    break :blk self.parseTsAbstractClass();
                }
            } else if (std.mem.eql(u8, text, "global")) {
                // global { } inside namespace/module — global augmentation
                const next = try self.peekNextKind();
                if (next == .l_curly) {
                    try self.advance(); // skip 'global'
                    _ = try self.parseTsNamespaceBlock();
                    break :blk NodeIndex.none;
                }
            }
            // 위 조건에 매치되지 않으면 expression 또는 labeled statement로 파싱
            break :blk parseExpressionOrLabeledStatement(self);
        },
        .kw_interface => blk_iface: {
            // interface\nFoo {} → 'interface' expression statement + 'Foo' + '{}' (ASI)
            // interface Foo {} → TS interface declaration
            // esbuild: !p.lexer.HasNewlineBefore
            const next_iface = try self.peekNext();
            if (next_iface.has_newline_before) {
                break :blk_iface parseExpressionOrLabeledStatement(self);
            }
            if (self.is_flow) {
                break :blk_iface self.parseFlowInterfaceDeclaration();
            }
            break :blk_iface self.parseTsInterfaceDeclaration();
        },
        .kw_enum => self.parseTsEnumDeclaration(),
        .kw_with => parseWithStatement(self),
        else => parseExpressionOrLabeledStatement(self),
    };
}

pub fn parseBlockStatement(self: *Parser) ParseError2!NodeIndex {
    const start = self.currentSpan().start;
    try self.expect(.l_curly);

    // 블록 안에서는 top-level이 아님 (import/export 금지)
    const block_saved = self.ctx;
    self.ctx.is_top_level = false;

    var stmts: std.ArrayList(NodeIndex) = .empty;
    defer stmts.deinit(self.allocator);

    while (self.current() != .r_curly and self.current() != .eof) {
        const loop_guard_pos = self.scanner.token.span.start;

        const stmt = try parseStatement(self);
        if (!stmt.isNone()) try stmts.append(self.allocator, stmt);

        if (try self.ensureLoopProgress(loop_guard_pos)) break;
    }

    self.ctx = block_saved;

    const end = self.currentSpan().end;
    try self.expect(.r_curly);

    const list = try self.ast.addNodeList(stmts.items);
    return try self.ast.addNode(.{
        .tag = .block_statement,
        .span = .{ .start = start, .end = end },
        .data = .{ .list = list },
    });
}

fn parseEmptyStatement(self: *Parser) ParseError2!NodeIndex {
    const span = self.currentSpan();
    try self.advance(); // skip ;
    return try self.ast.addNode(.{
        .tag = .empty_statement,
        .span = span,
        .data = .{ .none = 0 },
    });
}

pub fn parseExpressionStatement(self: *Parser) ParseError2!NodeIndex {
    const start = self.currentSpan().start;
    self.has_cover_init_name = false;
    const expr = try self.parseExpression();
    // CoverInitializedName ({ x = 1 }) 이 destructuring으로 소비되지 않았으면 에러
    if (self.has_cover_init_name) {
        try self.addError(.{ .start = start, .end = self.currentSpan().start }, "Invalid shorthand property initializer");
        self.has_cover_init_name = false;
    }
    const end = self.currentSpan().end;
    try self.expectSemicolon(); // ASI 규칙 적용: 개행/}/EOF 있으면 삽입, 아니면 에러
    return try self.ast.addNode(.{
        .tag = .expression_statement,
        .span = .{ .start = start, .end = end },
        .data = .{ .unary = .{ .operand = expr, .flags = 0 } },
    });
}

/// expression statement 또는 labeled statement를 파싱한다.
/// ECMAScript: sloppy mode에서 `let`이 LexicalDeclaration의 시작인지 판별한다.
/// `let` 뒤에 줄바꿈 없이 BindingIdentifier, `[`, `{`가 오면 LexicalDeclaration이다.
/// 그 외에는 `let`을 식별자로 취급한다 (expression statement).
fn isLetDeclarationStart(self: *Parser) ParseError2!bool {
    const next = try self.peekNext();
    if (next.has_newline_before) {
        // `let` 뒤에 줄바꿈이 있으면, 일반적으로 ASI가 적용되어 `let`은 식별자.
        // 예외 1: `let [` → ExpressionStatement lookahead 제한으로 항상 LexicalDeclaration.
        // 예외 2: `let\nlet`, `let\nyield`(generator), `let\nawait`(async) →
        //         spec 5.3에 의해 ASI 전에 production 매칭 → LexicalDeclaration으로 해석.
        //         static semantics에서 에러 보고 (let은 binding 불가 등).
        if (next.kind == .l_bracket) return true;
        if (next.kind == .kw_let) return true;
        if (next.kind == .kw_yield and self.ctx.in_generator) return true;
        if (next.kind == .kw_await and self.ctx.in_async) return true;
        return false;
    }
    // 줄바꿈 없이 바로 오는 경우: identifier, [, {, escaped_strict_reserved → LexicalDeclaration
    return next.kind == .identifier or next.kind == .l_bracket or next.kind == .l_curly or
        next.kind == .escaped_strict_reserved or
        (next.kind.isKeyword() and !next.kind.isReservedKeyword() and !next.kind.isLiteralKeyword());
}

/// `using` 뒤에 줄바꿈 없이 identifier가 오면 UsingDeclaration으로 해석한다.
fn isUsingDeclarationStart(self: *Parser) ParseError2!bool {
    const next = try self.peekNext();
    if (next.has_newline_before) return false;
    return next.kind == .identifier or
        (next.kind.isKeyword() and !next.kind.isReservedKeyword() and !next.kind.isLiteralKeyword());
}

/// `await` + `using` + identifier (줄바꿈 없이) → AwaitUsingDeclaration
/// module top-level에서도 await using이 허용된다 (top-level await).
fn isAwaitUsingDeclarationStart(self: *Parser) ParseError2!bool {
    // await은 async 함수 내부 또는 module top-level(함수 밖)에서만 유효
    const is_await_context = self.ctx.in_async or
        (self.is_module and !self.in_namespace and !self.ctx.in_function);
    if (!is_await_context) return false;
    const next = try self.peekNext();
    if (next.has_newline_before or next.kind != .kw_using) return false;
    // await using 뒤에 identifier가 와야 함 — 더 앞은 볼 수 없으므로 true 반환
    return true;
}

/// `await using x = expr;` 선언을 파싱한다.
fn parseAwaitUsingDeclaration(self: *Parser) ParseError2!NodeIndex {
    try self.advance(); // skip 'await'
    self.is_await_using = true; // parseVariableDeclaration에서 kind_flags=4로 설정
    defer self.is_await_using = false;
    return parseVariableDeclaration(self); // 'using'부터 parseVariableDeclaration 진행
}

/// `identifier:` 패턴이면 labeled statement, 아니면 expression statement.
fn parseExpressionOrLabeledStatement(self: *Parser) ParseError2!NodeIndex {
    // identifier/keyword: statement — labeled statement 판별
    // kw_await/kw_yield도 조건부로 식별자/label 사용 가능 (non-async/non-generator)
    if (self.current() == .identifier or self.current() == .escaped_keyword or
        self.current() == .escaped_strict_reserved or
        self.current() == .kw_await or self.current() == .kw_yield or
        (self.current().isKeyword() and !self.current().isReservedKeyword() and !self.current().isLiteralKeyword()))
    {
        const peek = try self.peekNext();
        if (peek.kind == .colon) {
            // yield/await를 label로 사용하면 generator/async에서 에러
            _ = try self.checkYieldAwaitUse(self.currentSpan(), "label");
            if (self.current() == .escaped_keyword) {
                // escaped `await` is only reserved in module/async context
                const esc_text = self.resolveIdentifierText(self.currentSpan());
                const is_escaped_await = std.mem.eql(u8, esc_text, "await");
                if (is_escaped_await) {
                    if (self.ctx.in_async) {
                        try self.addError(self.currentSpan(), "Escaped reserved word cannot be used as label");
                    } else if (self.is_module and !self.in_namespace) {
                        try self.addModuleError(self.currentSpan(), "Escaped reserved word cannot be used as label");
                    }
                } else {
                    try self.addError(self.currentSpan(), "Escaped reserved word cannot be used as label");
                }
            } else if (self.current() == .escaped_strict_reserved and self.is_strict_mode) {
                try self.addStrictModuleError(self.currentSpan(), "Escaped reserved word cannot be used as label in strict mode");
            } else if (self.is_strict_mode and self.current().isStrictModeReserved()) {
                try self.addStrictModuleError(self.currentSpan(), "Reserved word in strict mode cannot be used as label");
            }
            return parseLabeledStatement(self);
        }
    }
    return parseExpressionStatement(self);
}

/// labeled statement: label: statement
fn parseLabeledStatement(self: *Parser) ParseError2!NodeIndex {
    const start = self.currentSpan().start;
    // label
    const label = try self.ast.addNode(.{
        .tag = .identifier_reference,
        .span = self.currentSpan(),
        .data = .{ .string_ref = self.currentSpan() },
    });
    try self.advance(); // skip label
    try self.advance(); // skip ':'
    // ECMAScript 13.6.1 IsLabelledFunction: if/with body 안에서 label: function은 금지
    if (self.in_labelled_fn_check and self.current() == .kw_function) {
        if (try self.peekNextKind() != .star) {
            try self.addError(self.currentSpan(), "Function declaration is not allowed in statement position");
        }
    }
    const body = try parseStatementChecked(self, false);
    return try self.ast.addNode(.{
        .tag = .labeled_statement,
        .span = .{ .start = start, .end = self.currentSpan().start },
        .data = .{ .binary = .{ .left = label, .right = body, .flags = 0 } },
    });
}

/// with statement: with (expr) statement
/// strict mode에서는 SyntaxError (D054)
fn parseWithStatement(self: *Parser) ParseError2!NodeIndex {
    if (self.is_strict_mode) {
        try self.addStrictModuleError(self.currentSpan(), "'with' is not allowed in strict mode");
    }
    const start = self.currentSpan().start;
    try self.advance(); // skip 'with'
    try self.expect(.l_paren);
    const obj = try self.parseExpression();
    try self.expect(.r_paren);
    // with body에서 function declaration은 항상 금지 (Annex B에 with 예외 없음)
    // IsLabelledFunction(Statement) 체크도 필요
    const saved_labelled = self.in_labelled_fn_check;
    self.in_labelled_fn_check = true;
    const body = try parseStatementChecked(self, true);
    self.in_labelled_fn_check = saved_labelled;
    return try self.ast.addNode(.{
        .tag = .with_statement,
        .span = .{ .start = start, .end = self.currentSpan().start },
        .data = .{ .binary = .{ .left = obj, .right = body, .flags = 0 } },
    });
}

fn parseVariableDeclaration(self: *Parser) ParseError2!NodeIndex {
    const start = self.currentSpan().start;
    const kind_flags: u32 = switch (self.current()) {
        .kw_var => 0,
        .kw_let => 1,
        .kw_const => 2,
        .kw_using => if (self.is_await_using) @as(u32, 4) else @as(u32, 3), // 3=using, 4=await using
        else => 0,
    };
    try self.advance(); // skip var/let/const/using

    // let/const 선언에서 바인딩 이름 'let'은 금지 (ECMAScript 14.3.1.1)
    // 'let let = 1' → SyntaxError (non-strict에서도)
    if (kind_flags != 0 and self.current() == .kw_let) {
        try self.addError(self.currentSpan(), "'let' is not allowed as variable name in lexical declaration");
    }

    const scratch_top = self.saveScratch();
    while (true) {
        const decl = try parseVariableDeclarator(self);
        // const without initializer → SyntaxError (ECMAScript 14.3.1)
        // for-in/for-of에서는 const 이니셜라이저 불필요 (for (const x of ...))
        // TS declare에서도 불필요 (declare const x: number)
        if (kind_flags == 2 and !decl.isNone() and !self.for_loop_init and !self.ctx.in_ambient) {
            const decl_node = self.ast.getNode(decl);
            if (decl_node.tag == .variable_declarator) {
                const init_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[decl_node.data.extra + 2]);
                if (init_idx.isNone()) {
                    try self.addError(decl_node.span, "Const declarations must be initialized");
                }
            }
        }
        try self.scratch.append(self.allocator, decl);
        if (!try self.eat(.comma)) break;
    }

    const end = self.currentSpan().end;
    // for 초기화절에서는 세미콜론을 for 루프 파서가 처리한다.
    // 일반 문맥에서는 ASI 규칙으로 세미콜론을 처리한다.
    if (self.for_loop_init) {
        // for(var x = 0; ...) — 세미콜론은 parseForStatement에서 expect
    } else {
        try self.expectSemicolon();
    }

    const list = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
    self.restoreScratch(scratch_top);
    // extra_data: [kind_flags, list.start, list.len]
    const extra_start = try self.ast.addExtra(kind_flags);
    _ = try self.ast.addExtra(list.start);
    _ = try self.ast.addExtra(list.len);

    return try self.ast.addNode(.{
        .tag = .variable_declaration,
        .span = .{ .start = start, .end = end },
        .data = .{ .extra = extra_start },
    });
}

fn parseVariableDeclarator(self: *Parser) ParseError2!NodeIndex {
    const start = self.currentSpan().start;

    // 바인딩 패턴 (identifier, [array], {object} destructuring)
    // 주의: parseBindingPattern이 아닌 parseBindingName을 사용.
    // parseBindingPattern은 `=`를 default value로 소비하지만,
    // variable declarator에서 `=`는 initializer이므로 여기서 소비하면 안 됨.
    const name = try self.parseBindingName();

    // TS definite assignment assertion: let x!: Type (simple identifier만, destructuring 제외)
    // 줄바꿈 후 !는 ASI 경계이므로 definite assignment가 아님 (예: var a\n!b)
    if (self.current() == .bang and !self.scanner.token.has_newline_before and !name.isNone() and self.ast.getNode(name).tag == .binding_identifier) {
        _ = try self.eat(.bang);
    }

    // TS 타입 어노테이션 (: Type)
    const type_ann = try self.tryParseTypeAnnotation();

    // 이니셜라이저:
    // - 일반 변수 선언: Initializer[+In] — `in`이 연산자로 동작해야 하므로 allow_in=true 복원
    // - for 초기화절: allow_in=false 유지 — `in`이 for-in 키워드로 남아야 함
    //   예: `for (var x = 0 in {})` — Annex B.3.5 허용 (BindingIdentifier)
    //   예: `for (var {a} = 0 in {})` — 항상 SyntaxError (BindingPattern)
    //   두 경우 모두 `in`을 소비하지 않아야 for-in으로 올바르게 파싱됨
    var init_expr = NodeIndex.none;
    if (try self.eat(.eq)) {
        if (self.for_loop_init) {
            // for 초기화절: allow_in=false 유지하여 `in`을 for-in 키워드로 보존
            init_expr = try self.parseAssignmentExpression();
        } else {
            // 일반 문맥: allow_in=true로 복원 (ECMAScript: Initializer[+In])
            const init_saved = self.enterAllowInContext(true);
            init_expr = try self.parseAssignmentExpression();
            self.restoreContext(init_saved);
        }
    }

    // name, type_ann, init_expr → extra_data
    const extra_start = try self.ast.addExtra(@intFromEnum(name));
    _ = try self.ast.addExtra(@intFromEnum(type_ann));
    _ = try self.ast.addExtra(@intFromEnum(init_expr));

    return try self.ast.addNode(.{
        .tag = .variable_declarator,
        .span = .{ .start = start, .end = self.currentSpan().start },
        .data = .{ .extra = extra_start },
    });
}

fn parseReturnStatement(self: *Parser) ParseError2!NodeIndex {
    if (!self.ctx.in_function) {
        try self.addModuleError(self.currentSpan(), "'return' outside of function");
    }
    const start = self.currentSpan().start;
    try self.advance(); // skip 'return'

    var arg = NodeIndex.none;
    if (self.current() != .semicolon and self.current() != .eof and
        self.current() != .r_curly and !self.scanner.token.has_newline_before)
    {
        arg = try self.parseExpression();
    }

    const end = self.currentSpan().end;
    _ = try self.eat(.semicolon);

    return try self.ast.addNode(.{
        .tag = .return_statement,
        .span = .{ .start = start, .end = end },
        .data = .{ .unary = .{ .operand = arg, .flags = 0 } },
    });
}

fn parseIfStatement(self: *Parser) ParseError2!NodeIndex {
    const start = self.currentSpan().start;
    try self.advance(); // skip 'if'
    try self.expect(.l_paren);
    const test_expr = try self.parseExpression();
    try self.expect(.r_paren);
    // ECMAScript 13.6.1: IsLabelledFunction(Statement) → SyntaxError
    const saved_labelled = self.in_labelled_fn_check;
    self.in_labelled_fn_check = true;
    const consequent = try parseStatementChecked(self, false);

    var alternate = NodeIndex.none;
    if (try self.eat(.kw_else)) {
        alternate = try parseStatementChecked(self, false);
    }
    self.in_labelled_fn_check = saved_labelled;

    return try self.ast.addNode(.{
        .tag = .if_statement,
        .span = .{ .start = start, .end = self.currentSpan().start },
        .data = .{ .ternary = .{ .a = test_expr, .b = consequent, .c = alternate } },
    });
}

fn parseWhileStatement(self: *Parser) ParseError2!NodeIndex {
    const start = self.currentSpan().start;
    try self.advance(); // skip 'while'
    try self.expect(.l_paren);
    const test_expr = try self.parseExpression();
    try self.expect(.r_paren);
    const body = try self.parseLoopBody();

    return try self.ast.addNode(.{
        .tag = .while_statement,
        .span = .{ .start = start, .end = self.currentSpan().start },
        .data = .{ .binary = .{ .left = test_expr, .right = body, .flags = 0 } },
    });
}

fn parseDoWhileStatement(self: *Parser) ParseError2!NodeIndex {
    const start = self.currentSpan().start;
    try self.advance(); // skip 'do'
    const body = try self.parseLoopBody();
    try self.expect(.kw_while);
    try self.expect(.l_paren);
    const test_expr = try self.parseExpression();
    try self.expect(.r_paren);
    _ = try self.eat(.semicolon);

    return try self.ast.addNode(.{
        .tag = .do_while_statement,
        .span = .{ .start = start, .end = self.currentSpan().start },
        .data = .{ .binary = .{ .left = test_expr, .right = body, .flags = 0 } },
    });
}

fn parseForStatement(self: *Parser) ParseError2!NodeIndex {
    const start = self.currentSpan().start;
    try self.advance(); // skip 'for'

    // for await (...) — async iteration
    // for-await-of: `for await (x of iterable)` — async iteration
    // await 플래그는 for-of에서 `async` 식별자 사용 허용 여부에 영향
    const is_await = try self.eat(.kw_await);

    try self.expect(.l_paren);

    // for문의 init 부분 파싱
    // for(init; ...) or for(left in/of right)
    if (self.current() == .semicolon) {
        // for(; ...) — 빈 init
        try self.advance();
        return parseForRest(self, start, NodeIndex.none);
    }

    // for 초기화절에서는 `in` 연산자를 비활성화하고 for_loop_init을 설정한다.
    // for_loop_init: const without init 체크 스킵 (for-in/for-of에서는 init 불필요)
    const for_saved = self.enterAllowInContext(false);
    const saved_for_loop_init = self.for_loop_init;
    self.for_loop_init = true;

    // ECMAScript 14.7.5: for ( [lookahead ∉ { let [ }] LeftHandSideExpression in Expression )
    // sloppy mode에서 `let`이 LexicalDeclaration의 시작이 아닌 경우 식별자로 취급.
    // 예: `for (let in x)`, `for (let of x)`, `for (let; ;)`, `for (let = 3; ;)`
    // sloppy mode에서 isLetDeclarationStart가 false이면 `let`을 식별자로 처리.
    // 예: `for (let in x)` — `let`은 식별자.
    // 특수: `for (let of [])` — `let of`를 선언이 아닌 for-of로 해석 (스펙: SyntaxError).
    //   `let` 뒤에 `of`가 오면 식별자로 취급하여 for-of LHS 검증에서 에러 보고.
    //   단, `for (let of = 1;;)` 같은 경우는 isLetDeclarationStart가 true → 선언 경로.
    //   `kw_of` 뒤에 `=`이 오면 isLetDeclarationStart가 true (keyword + not reserved).
    const is_let_as_identifier = self.current() == .kw_let and !self.is_strict_mode and
        (!try isLetDeclarationStart(self) or try self.peekNextKind() == .kw_of);

    if ((self.current() == .kw_var or self.current() == .kw_let or self.current() == .kw_const) and !is_let_as_identifier) {
        const init_expr = try parseVariableDeclaration(self);
        self.restoreContext(for_saved);
        self.for_loop_init = saved_for_loop_init;
        // parseVariableDeclaration이 세미콜론을 소비했으면 for(;;)
        // 'in' 또는 'of'가 보이면 for-in/for-of
        if (self.current() == .kw_in or self.current() == .kw_of) {
            try validateForInOfDeclaration(self, init_expr);
            if (self.current() == .kw_in) {
                return parseForIn(self, start, init_expr);
            }
            return parseForOf(self, start, init_expr, is_await);
        }
        try self.expect(.semicolon); // for 헤더의 첫 번째 세미콜론 (ASI 금지, 7.9.2)
        return parseForRest(self, start, init_expr);
    }

    // for-in/for-of의 variable declaration 검증 (ECMAScript 14.7.5.1)
    // - 단일 바인딩만 허용, initializer 금지
    // - 예외: sloppy mode의 var + for-in은 initializer 허용 (Annex B.3.5)

    // 일반 표현식 init
    const init_expr = try self.parseExpression();
    self.restoreContext(for_saved);
    self.for_loop_init = saved_for_loop_init;
    if (self.current() == .kw_in) {
        _ = try self.coverExpressionToAssignmentTarget(init_expr, true);
        return parseForIn(self, start, init_expr);
    }
    if (self.current() == .kw_of) {
        // for (async of [1]) — 'async' 키워드가 for-of의 LHS로 사용되면 에러
        // ECMAScript 14.7.5: [+Await] ForDeclaration에서 async는 금지
        // 단, for-await-of에서는 async가 LHS로 사용 가능 (async는 일반 식별자)
        // 예: `for await (async of [7])` → 유효
        const init_node = self.ast.getNode(init_expr);
        if (init_node.tag == .identifier_reference) {
            const text = self.ast.source[init_node.span.start..init_node.span.end];
            if (std.mem.eql(u8, text, "async") and !is_await) {
                try self.addError(init_node.span, "'async' is not allowed as identifier in for-of left-hand side");
            }
            // for (let of []) — 'let' 키워드가 for-of의 LHS로 사용되면 에러
            // ECMAScript 14.7.5: [lookahead ≠ let] LeftHandSideExpression of
            if (std.mem.eql(u8, text, "let")) {
                try self.addError(init_node.span, "'let' is not allowed as identifier in for-of left-hand side");
            }
        }
        _ = try self.coverExpressionToAssignmentTarget(init_expr, true);
        return parseForOf(self, start, init_expr, is_await);
    }
    try self.expect(.semicolon); // for 헤더의 첫 번째 세미콜론 (ASI 금지, 7.9.2)
    return parseForRest(self, start, init_expr);
}

/// for-in/for-of의 variable declaration을 검증한다.
/// - 단일 바인딩만 허용 (ECMAScript 14.7.5.1)
/// - initializer 금지 (for-of는 항상, for-in은 strict + let/const)
/// - Annex B.3.5: sloppy mode의 var + for-in은 initializer 허용
fn validateForInOfDeclaration(self: *Parser, init_expr: NodeIndex) ParseError2!void {
    if (init_expr.isNone()) return;
    const init_node = self.ast.getNode(init_expr);
    if (init_node.tag != .variable_declaration) return;

    const extras = self.ast.extra_data.items;
    const kind_flags = extras[init_node.data.extra];
    const list_start = extras[init_node.data.extra + 1];
    const decl_len = extras[init_node.data.extra + 2];

    if (decl_len > 1) {
        try self.addError(init_node.span, "Only a single variable declaration is allowed in a for-in/for-of statement");
    }
    if (decl_len == 0) return;

    // 첫 번째 declarator의 initializer 체크
    const first_decl: NodeIndex = @enumFromInt(extras[list_start]);
    if (first_decl.isNone()) return;
    const decl_node = self.ast.getNode(first_decl);
    if (decl_node.tag != .variable_declarator) return;

    const decl_init: NodeIndex = @enumFromInt(extras[decl_node.data.extra + 2]);
    if (decl_init.isNone()) return;

    // initializer가 있으면 에러 (예외: sloppy var + for-in + BindingIdentifier만)
    // Annex B.3.5: for (var BindingIdentifier Initializer in Expression) — 허용
    // BindingPattern (array/object destructuring)은 Annex B에서도 항상 금지
    const is_var = kind_flags == 0;
    const is_for_in = self.current() == .kw_in;
    if (is_for_in and is_var) {
        // TS 모드에서는 for-in var initializer를 허용 (esbuild 호환).
        // TS에서 `for (var x = Array<number> in y)` 같은 패턴에서 타입 인자가
        // 스트리핑되어 initializer가 남을 수 있다. codegen에서 hoisting 처리.
        if (self.is_ts) return;

        if (!self.is_strict_mode) {
            // BindingIdentifier인지 확인 — destructuring이면 허용 불가
            const binding_name: NodeIndex = @enumFromInt(extras[decl_node.data.extra]);
            if (!binding_name.isNone()) {
                const binding_node = self.ast.getNode(binding_name);
                if (binding_node.tag == .binding_identifier) return; // Annex B.3.5 허용
            }
        }
    }
    try self.addError(decl_node.span, "For-in/for-of loop variable declaration may not have an initializer");
}

/// for(init; test; update) body — 나머지 파싱
fn parseForRest(self: *Parser, start: u32, init_expr: NodeIndex) ParseError2!NodeIndex {
    var test_expr = NodeIndex.none;
    if (self.current() != .semicolon) {
        test_expr = try self.parseExpression();
    }
    try self.expect(.semicolon); // for 헤더의 두 번째 세미콜론 (ASI 금지, 7.9.2)

    var update_expr = NodeIndex.none;
    if (self.current() != .r_paren) {
        update_expr = try self.parseExpression();
    }
    try self.expect(.r_paren);
    const body = try self.parseLoopBody();

    const extra_start = try self.ast.addExtra(@intFromEnum(init_expr));
    _ = try self.ast.addExtra(@intFromEnum(test_expr));
    _ = try self.ast.addExtra(@intFromEnum(update_expr));
    _ = try self.ast.addExtra(@intFromEnum(body));

    return try self.ast.addNode(.{
        .tag = .for_statement,
        .span = .{ .start = start, .end = self.currentSpan().start },
        .data = .{ .extra = extra_start },
    });
}

/// for(left in right) body
fn parseForIn(self: *Parser, start: u32, left: NodeIndex) ParseError2!NodeIndex {
    try self.advance(); // skip 'in'
    const right = try self.parseExpression();
    try self.expect(.r_paren);
    const body = try self.parseLoopBody();

    return try self.ast.addNode(.{
        .tag = .for_in_statement,
        .span = .{ .start = start, .end = self.currentSpan().start },
        .data = .{ .ternary = .{ .a = left, .b = right, .c = body } },
    });
}

/// for(left of right) body / for await(left of right) body
fn parseForOf(self: *Parser, start: u32, left: NodeIndex, is_await: bool) ParseError2!NodeIndex {
    try self.advance(); // skip 'of'
    const right = try self.parseAssignmentExpression();
    try self.expect(.r_paren);
    const body = try self.parseLoopBody();

    return try self.ast.addNode(.{
        .tag = if (is_await) .for_await_of_statement else .for_of_statement,
        .span = .{ .start = start, .end = self.currentSpan().start },
        .data = .{ .ternary = .{ .a = left, .b = right, .c = body } },
    });
}

/// break, continue, debugger 등 키워드 + 세미콜론만으로 구성된 단순 문.
fn parseSimpleStatement(self: *Parser, tag: Tag) ParseError2!NodeIndex {
    const keyword_span = self.currentSpan();
    const start = keyword_span.start;
    try self.advance(); // skip break/continue/debugger

    // break/continue 뒤에 줄바꿈 없이 identifier가 오면 label로 소비
    var label = NodeIndex.none;
    if ((tag == .break_statement or tag == .continue_statement) and
        self.current() == .identifier and !self.scanner.token.has_newline_before)
    {
        label = try self.ast.addNode(.{
            .tag = .identifier_reference,
            .span = self.currentSpan(),
            .data = .{ .string_ref = self.currentSpan() },
        });
        try self.advance();
    }

    // continue → label 유무와 관계없이 loop 안에서만 허용
    if (tag == .continue_statement and !self.in_loop) {
        try self.addError(keyword_span, "'continue' outside of loop");
    }
    // break → label이 없을 때만 loop 또는 switch 필요
    // label이 있는 break는 labelled statement 안에서 유효 (loop/switch 불필요)
    if (tag == .break_statement and label.isNone() and !self.in_loop and !self.in_switch) {
        try self.addError(keyword_span, "'break' outside of loop or switch");
    }

    const end = self.currentSpan().end;
    _ = try self.eat(.semicolon);
    return try self.ast.addNode(.{
        .tag = tag,
        .span = .{ .start = start, .end = end },
        .data = .{ .unary = .{ .operand = label, .flags = 0 } },
    });
}

fn parseSwitchStatement(self: *Parser) ParseError2!NodeIndex {
    const start = self.currentSpan().start;
    try self.advance(); // skip 'switch'
    try self.expect(.l_paren);
    const discriminant = try self.parseExpression();
    try self.expect(.r_paren);
    try self.expect(.l_curly);

    const saved_ctx = self.ctx;
    const saved_in_switch = self.in_switch;
    self.in_switch = true;
    // switch body 안에서는 top-level이 아님 (import/export 금지)
    self.ctx.is_top_level = false;

    const scratch_top = self.saveScratch();
    var has_default = false;
    while (self.current() != .r_curly and self.current() != .eof) {
        const loop_guard_pos = self.scanner.token.span.start;

        // duplicate default 검출 (ECMAScript 14.12.1)
        const is_default = self.current() == .kw_default;
        const default_span = self.currentSpan();
        const case_node = try parseSwitchCase(self);
        if (is_default) {
            if (has_default) {
                try self.addError(default_span, "Only one default clause is allowed in a switch statement");
            }
            has_default = true;
        }
        try self.scratch.append(self.allocator, case_node);

        if (try self.ensureLoopProgress(loop_guard_pos)) break;
    }

    self.restoreContext(saved_ctx);
    self.in_switch = saved_in_switch;

    const end = self.currentSpan().end;
    try self.expect(.r_curly);

    const cases = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
    self.restoreScratch(scratch_top);
    const extra_start = try self.ast.addExtra(@intFromEnum(discriminant));
    _ = try self.ast.addExtra(cases.start);
    _ = try self.ast.addExtra(cases.len);

    return try self.ast.addNode(.{
        .tag = .switch_statement,
        .span = .{ .start = start, .end = end },
        .data = .{ .extra = extra_start },
    });
}

fn parseSwitchCase(self: *Parser) ParseError2!NodeIndex {
    const start = self.currentSpan().start;

    var test_expr = NodeIndex.none;
    if (try self.eat(.kw_case)) {
        test_expr = try self.parseExpression();
        try self.expect(.colon);
    } else if (try self.eat(.kw_default)) {
        try self.expect(.colon);
    } else {
        const err_span = self.currentSpan();
        try self.addError(err_span, "Case or default expected");
        try self.advance();
        return try self.ast.addNode(.{ .tag = .invalid, .span = err_span, .data = .{ .none = 0 } });
    }

    // case 본문: 다음 case/default/} 전까지
    const body_top = self.saveScratch();
    while (self.current() != .kw_case and self.current() != .kw_default and
        self.current() != .r_curly and self.current() != .eof)
    {
        const loop_guard_pos = self.scanner.token.span.start;

        const stmt = try parseStatement(self);
        if (!stmt.isNone()) try self.scratch.append(self.allocator, stmt);

        if (try self.ensureLoopProgress(loop_guard_pos)) break;
    }

    const body = try self.ast.addNodeList(self.scratch.items[body_top..]);
    self.restoreScratch(body_top);
    const extra_start = try self.ast.addExtra(@intFromEnum(test_expr));
    _ = try self.ast.addExtra(body.start);
    _ = try self.ast.addExtra(body.len);

    return try self.ast.addNode(.{
        .tag = .switch_case,
        .span = .{ .start = start, .end = self.currentSpan().start },
        .data = .{ .extra = extra_start },
    });
}

fn parseThrowStatement(self: *Parser) ParseError2!NodeIndex {
    const start = self.currentSpan().start;
    try self.advance(); // skip 'throw'
    // ECMAScript 14.14: throw [no LineTerminator here] Expression
    if (self.scanner.token.has_newline_before) {
        try self.addError(.{ .start = start, .end = self.currentSpan().start }, "No line break is allowed after 'throw'");
    }
    const arg = try self.parseExpression();
    const end = self.currentSpan().end;
    _ = try self.eat(.semicolon);
    return try self.ast.addNode(.{
        .tag = .throw_statement,
        .span = .{ .start = start, .end = end },
        .data = .{ .unary = .{ .operand = arg, .flags = 0 } },
    });
}

fn parseTryStatement(self: *Parser) ParseError2!NodeIndex {
    const start = self.currentSpan().start;
    try self.advance(); // skip 'try'

    const block = try parseBlockStatement(self);

    // catch 절 (선택적)
    var handler = NodeIndex.none;
    if (self.current() == .kw_catch) {
        handler = try parseCatchClause(self);
    }

    // finally 절 (선택적)
    var finalizer = NodeIndex.none;
    if (try self.eat(.kw_finally)) {
        finalizer = try parseBlockStatement(self);
    }

    // catch도 finally도 없으면 에러
    if (handler.isNone() and finalizer.isNone()) {
        try self.addError(.{ .start = start, .end = self.currentSpan().start }, "Catch or finally expected");
    }

    return try self.ast.addNode(.{
        .tag = .try_statement,
        .span = .{ .start = start, .end = self.currentSpan().start },
        .data = .{ .ternary = .{ .a = block, .b = handler, .c = finalizer } },
    });
}

fn parseCatchClause(self: *Parser) ParseError2!NodeIndex {
    const start = self.currentSpan().start;
    try self.advance(); // skip 'catch'

    // catch 파라미터 (선택적 — ES2019 optional catch binding)
    var param = NodeIndex.none;
    if (try self.eat(.l_paren)) {
        param = try self.parseBindingIdentifier();
        try self.expect(.r_paren);
    }

    const body = try parseBlockStatement(self);

    return try self.ast.addNode(.{
        .tag = .catch_clause,
        .span = .{ .start = start, .end = self.currentSpan().start },
        .data = .{ .binary = .{ .left = param, .right = body, .flags = 0 } },
    });
}
