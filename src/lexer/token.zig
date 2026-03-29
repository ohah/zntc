//! ZTS Token Definitions
//!
//! ECMAScript / TypeScript / JSX / Flow 토큰 종류를 정의한다.
//! oxc의 Kind enum을 참고하여 설계 (D034).
//!
//! 설계 원칙:
//! - u8 repr (256 이내)
//! - 키워드를 개별 토큰으로 (파서에서 문자열 비교 불필요)
//! - 숫자를 세분화 (Decimal/Float/Hex/Octal/Binary/BigInt)
//! - 키워드 범위를 연속 배치하여 range check 최적화
//! - comptime assertion으로 range 순서 보장
//!
//! 참고: references/oxc/crates/oxc_parser/src/lexer/kind.rs

const std = @import("std");

/// 소스 코드의 위치를 나타내는 span.
/// start와 end는 소스 코드의 byte offset이다.
/// line/column은 별도 line offset 테이블에서 lazy 계산한다 (D015).
/// extern struct: AST Node.Data의 extern union 안에서 사용하기 위해 C ABI 호환.
pub const Span = extern struct {
    start: u32,
    end: u32,

    pub const EMPTY = Span{ .start = 0, .end = 0 };

    pub fn len(self: Span) u32 {
        std.debug.assert(self.end >= self.start);
        return self.end - self.start;
    }

    /// 두 span을 합친다. 호출자는 self가 other보다 앞에 있음을 보장해야 한다.
    pub fn merge(self: Span, other: Span) Span {
        std.debug.assert(other.end >= self.start);
        return .{
            .start = self.start,
            .end = other.end,
        };
    }
};

/// 렉서가 생성하는 토큰 하나.
/// 토큰 종류(kind) + 소스 위치(span) + 메타데이터.
pub const Token = struct {
    kind: Kind = .eof,
    span: Span = Span.EMPTY,

    /// 이 토큰 직전에 줄바꿈이 있었는지 (ASI 판정에 필요)
    has_newline_before: bool = false,

    /// 이 토큰 직전에 @__PURE__ / #__PURE__ 주석이 있었는지 (D025)
    has_pure_comment_before: bool = false,

    /// 이 토큰 직전에 @__NO_SIDE_EFFECTS__ 주석이 있었는지 (D025)
    has_no_side_effects_comment: bool = false,

    /// 이 토큰이 유니코드 이스케이프를 포함하는지 (oxc 방식).
    /// escaped keyword 감지에 사용: advance()에서 escaped && is_keyword → 에러.
    has_escape: bool = false,

    /// 템플릿 리터럴에 잘못된 이스케이프 시퀀스가 포함되었는지.
    /// tagged template에서는 허용되지만 (cooked가 undefined),
    /// untagged template에서는 파서가 SyntaxError를 보고해야 한다.
    has_invalid_escape: bool = false,

    /// legacy octal 리터럴/이스케이프가 포함되었는지.
    /// strict mode에서는 SyntaxError (ECMAScript 12.8.3.1).
    /// - 숫자: 0으로 시작하는 octal (00, 07, 08, 09 등)
    /// - 문자열: \0 뒤에 숫자, \1~\9 octal escape
    has_legacy_octal: bool = false,
};

/// ECMAScript / TypeScript / JSX 토큰 종류.
///
/// oxc 방식으로 세분화: TS 키워드 개별 토큰, 숫자 11가지 세분화.
/// u8로 표현 가능 (256 이내).
///
/// 키워드는 연속 배치하여 range check 최적화:
///   isKeyword()          → kw_await..kw_null
///   isReservedKeyword()  → kw_await..kw_with
///   isStrictModeReserved() → kw_implements..kw_yield
pub const Kind = enum(u8) {
    // ========================================================================
    // Special
    // ========================================================================
    eof = 0,
    /// 아직 결정되지 않은 토큰 (렉서 내부 상태)
    undetermined,
    /// 구문 에러가 발생한 토큰
    syntax_error,
    /// hashbang 주석 (`#!/usr/bin/env node`)
    hashbang_comment,

    // ========================================================================
    // Identifiers
    // ========================================================================
    /// 일반 식별자
    identifier,
    /// private 식별자 (`#name`)
    private_identifier,
    /// 유니코드 이스케이프로 작성된 reserved keyword (항상 식별자로 사용 불가)
    escaped_keyword,
    /// 유니코드 이스케이프로 작성된 strict mode reserved word (strict에서만 불가)
    /// let, yield, implements, interface, package, private, protected, public, static
    escaped_strict_reserved,

    // ========================================================================
    // ECMAScript Reserved Keywords (ES2024)
    // 순서 중요: range check에 사용. comptime assertion으로 검증됨.
    // ========================================================================
    kw_await,
    kw_break,
    kw_case,
    kw_catch,
    kw_class,
    kw_const,
    kw_continue,
    kw_debugger,
    kw_default,
    kw_delete,
    kw_do,
    kw_else,
    kw_enum,
    kw_export,
    kw_extends,
    kw_finally,
    kw_for,
    kw_function,
    kw_if,
    kw_import,
    kw_in,
    kw_instanceof,
    kw_new,
    kw_return,
    kw_super,
    kw_switch,
    kw_this,
    kw_throw,
    kw_try,
    kw_typeof,
    kw_var,
    kw_void,
    kw_while,
    kw_with,

    // ========================================================================
    // ECMAScript Contextual Keywords
    // ========================================================================
    kw_async,
    kw_from,
    kw_get,
    kw_meta,
    kw_of,
    kw_set,
    kw_target,
    kw_accessor,
    kw_source,
    kw_defer,
    kw_using,
    kw_let,

    // ========================================================================
    // Strict Mode Reserved Words
    // ========================================================================
    kw_implements,
    kw_interface,
    kw_package,
    kw_private,
    kw_protected,
    kw_public,
    kw_static,
    kw_yield,

    // ========================================================================
    // Literal Keywords
    // ========================================================================
    kw_true,
    kw_false,
    kw_null,

    // ========================================================================
    // Punctuators / Operators
    // ========================================================================

    // Grouping
    l_paren, // (
    r_paren, // )
    l_bracket, // [
    r_bracket, // ]
    l_curly, // {
    r_curly, // }

    // Delimiters
    semicolon, // ;
    comma, // ,
    colon, // :
    dot, // .
    dot3, // ...

    // Comparison
    l_angle, // <
    r_angle, // >
    lt_eq, // <=
    gt_eq, // >=
    eq2, // ==
    neq, // !=
    eq3, // ===
    neq2, // !==

    // Arithmetic
    plus, // +
    minus, // -
    star, // *
    slash, // /
    percent, // %
    star2, // **

    // Increment / Decrement
    plus2, // ++
    minus2, // --

    // Bitwise
    amp, // &
    pipe, // |
    caret, // ^
    tilde, // ~
    shift_left, // <<
    shift_right, // >>
    shift_right3, // >>>

    // Logical
    amp2, // &&
    pipe2, // ||
    bang, // !

    // Nullish / Optional
    question, // ?
    question2, // ??
    question_dot, // ?.

    // Assignment (연속 배치: isAssignment() range check)
    eq, // =
    plus_eq, // +=
    minus_eq, // -=
    star_eq, // *=
    slash_eq, // /=
    percent_eq, // %=
    star2_eq, // **=
    amp_eq, // &=
    pipe_eq, // |=
    caret_eq, // ^=
    shift_left_eq, // <<=
    shift_right_eq, // >>=
    shift_right3_eq, // >>>=
    amp2_eq, // &&=
    pipe2_eq, // ||=
    question2_eq, // ??=

    // Arrow
    arrow, // =>

    // Decorator
    at, // @

    // ========================================================================
    // Numeric Literals (연속 배치: isNumericLiteral() range check)
    // ========================================================================
    decimal, // 123
    float, // 1.5, .5
    binary, // 0b1010
    octal, // 0o77
    hex, // 0xFF
    positive_exponential, // 1e10, 1e+10
    negative_exponential, // 1e-10

    // BigInt Literals (연속 배치: isBigIntLiteral() range check)
    decimal_bigint, // 123n
    binary_bigint, // 0b1010n
    octal_bigint, // 0o77n
    hex_bigint, // 0xFFn

    // ========================================================================
    // String Literals
    // ========================================================================
    string_literal,

    // ========================================================================
    // Regular Expression Literal
    // ========================================================================
    regexp_literal,

    // ========================================================================
    // Template Literals (연속 배치: isTemplateLiteral() range check)
    // ========================================================================
    no_substitution_template, // `string`  (보간 없는 완전한 템플릿)
    template_head, // `text${
    template_middle, // }text${
    template_tail, // }text`

    // ========================================================================
    // JSX (D008)
    // ========================================================================
    jsx_text, // JSX 태그 사이 텍스트 (다른 렉싱 규칙 적용)
    jsx_identifier, // JSX 식별자 (하이픈 허용: data-value)

    // ========================================================================
    // Comptime assertions — enum 순서가 range check와 일치하는지 검증.
    // 새 variant를 추가하거나 재배치하면 여기서 컴파일 에러가 난다.
    // ========================================================================
    comptime {
        // Reserved keywords: kw_await..kw_with 연속
        std.debug.assert(@intFromEnum(Kind.kw_await) < @intFromEnum(Kind.kw_with));
        std.debug.assert(@intFromEnum(Kind.kw_with) + 1 == @intFromEnum(Kind.kw_async));

        // Contextual keywords → strict mode reserved 연속
        std.debug.assert(@intFromEnum(Kind.kw_let) + 1 == @intFromEnum(Kind.kw_implements));

        // Strict mode reserved: kw_implements..kw_yield 연속
        std.debug.assert(@intFromEnum(Kind.kw_implements) < @intFromEnum(Kind.kw_yield));
        std.debug.assert(@intFromEnum(Kind.kw_yield) + 1 == @intFromEnum(Kind.kw_true));

        // Literal keywords: kw_true..kw_null 연속, 그 다음이 l_paren
        std.debug.assert(@intFromEnum(Kind.kw_null) + 1 == @intFromEnum(Kind.l_paren));

        // Full keyword range: kw_await..kw_null
        std.debug.assert(@intFromEnum(Kind.kw_await) < @intFromEnum(Kind.kw_null));

        // Assignment operators: eq..question2_eq 연속
        std.debug.assert(@intFromEnum(Kind.eq) < @intFromEnum(Kind.question2_eq));

        // Numeric literals: decimal..hex_bigint 연속
        std.debug.assert(@intFromEnum(Kind.decimal) < @intFromEnum(Kind.hex_bigint));
        std.debug.assert(@intFromEnum(Kind.decimal_bigint) < @intFromEnum(Kind.hex_bigint));

        // Template literals: no_substitution_template..template_tail 연속
        std.debug.assert(@intFromEnum(Kind.no_substitution_template) < @intFromEnum(Kind.template_tail));
    }

    // ========================================================================
    // Helper methods
    // ========================================================================

    /// 두 Kind 값 사이에 있는지 (inclusive range check).
    fn inRange(self: Kind, first: Kind, last: Kind) bool {
        const v = @intFromEnum(self);
        return v >= @intFromEnum(first) and v <= @intFromEnum(last);
    }

    /// ECMAScript reserved keyword인지 (await..with)
    pub fn isReservedKeyword(self: Kind) bool {
        return self.inRange(.kw_await, .kw_with);
    }

    /// Strict mode reserved word인지 (ECMAScript 12.1.1)
    /// implements, interface, let, package, private, protected, public, static, yield
    pub fn isStrictModeReserved(self: Kind) bool {
        return self.inRange(.kw_implements, .kw_yield) or self == .kw_let or self == .kw_static;
    }

    /// 키워드인지 (reserved + contextual + strict + literals)
    pub fn isKeyword(self: Kind) bool {
        return self.inRange(.kw_await, .kw_null);
    }

    /// Literal keyword인지 (true, false, null)
    pub fn isLiteralKeyword(self: Kind) bool {
        return self.inRange(.kw_true, .kw_null);
    }

    /// 숫자 리터럴인지 (decimal..hex_bigint)
    pub fn isNumericLiteral(self: Kind) bool {
        return self.inRange(.decimal, .hex_bigint);
    }

    /// BigInt 리터럴인지 (decimal_bigint..hex_bigint)
    pub fn isBigIntLiteral(self: Kind) bool {
        return self.inRange(.decimal_bigint, .hex_bigint);
    }

    /// 템플릿 리터럴인지
    pub fn isTemplateLiteral(self: Kind) bool {
        return self.inRange(.no_substitution_template, .template_tail);
    }

    /// 대입 연산자인지 (=, +=, -=, ...)
    pub fn isAssignment(self: Kind) bool {
        return self.inRange(.eq, .question2_eq);
    }

    /// 이 토큰 뒤에 `/`가 나오면 regex로 해석해야 하는지.
    /// false면 division으로 해석.
    ///
    /// 주의: `r_curly`는 여기서 판정할 수 없다. 블록 `}` 뒤는 regex,
    /// 표현식(함수 표현식, 객체 리터럴) `}` 뒤는 division이다.
    /// 이 모호성은 파서가 brace context를 추적하여 해결해야 한다.
    /// 현재 `r_curly`는 else → true (regex)로 처리되어 있으며,
    /// 파서가 표현식 `}`일 때 직접 division으로 오버라이드한다.
    pub fn slashIsRegex(self: Kind) bool {
        // 숫자 리터럴 뒤 → division
        if (self.isNumericLiteral()) return false;

        return switch (self) {
            // 식별자/리터럴/닫는 괄호 뒤 → division
            .identifier,
            .private_identifier,
            .escaped_keyword,
            .escaped_strict_reserved,
            .kw_this,
            .kw_true,
            .kw_false,
            .kw_null,
            .kw_super,
            .r_paren,
            .r_bracket,
            .plus2,
            .minus2,
            .string_literal,
            .regexp_literal,
            .no_substitution_template,
            .template_tail,
            // contextual keyword는 식별자처럼 사용 가능 → division
            .kw_async,
            .kw_from,
            .kw_get,
            .kw_meta,
            .kw_of,
            .kw_set,
            .kw_target,
            .kw_accessor,
            .kw_source,
            .kw_defer,
            .kw_using,
            .kw_let,
            // strict mode reserved도 non-strict에서 식별자 → division
            .kw_implements,
            .kw_interface,
            .kw_package,
            .kw_private,
            .kw_protected,
            .kw_public,
            .kw_static,
            .kw_yield,
            => false,

            // 그 외 → regex
            // 연산자, reserved keyword(return, throw 등), 여는 괄호, 세미콜론 등
            // r_curly도 여기에 포함 — 파서가 오버라이드 필요 (위 doc comment 참고)
            else => true,
        };
    }

    /// 토큰의 이름 문자열을 반환한다 (에러 메시지용).
    /// 키워드는 `kw_` 접두사 없이 반환한다 (예: .kw_break → "break").
    pub fn symbol(self: Kind) []const u8 {
        return token_names[@intFromEnum(self)];
    }
};

/// 키워드 문자열 → Kind 매핑 테이블.
/// 렉서가 식별자를 스캔한 후, 이 테이블에서 키워드인지 확인한다.
pub const keywords = std.StaticStringMap(Kind).initComptime(.{
    // ECMAScript Reserved Keywords
    .{ "await", .kw_await },
    .{ "break", .kw_break },
    .{ "case", .kw_case },
    .{ "catch", .kw_catch },
    .{ "class", .kw_class },
    .{ "const", .kw_const },
    .{ "continue", .kw_continue },
    .{ "debugger", .kw_debugger },
    .{ "default", .kw_default },
    .{ "delete", .kw_delete },
    .{ "do", .kw_do },
    .{ "else", .kw_else },
    .{ "enum", .kw_enum },
    .{ "export", .kw_export },
    .{ "extends", .kw_extends },
    .{ "finally", .kw_finally },
    .{ "for", .kw_for },
    .{ "function", .kw_function },
    .{ "if", .kw_if },
    .{ "import", .kw_import },
    .{ "in", .kw_in },
    .{ "instanceof", .kw_instanceof },
    .{ "new", .kw_new },
    .{ "return", .kw_return },
    .{ "super", .kw_super },
    .{ "switch", .kw_switch },
    .{ "this", .kw_this },
    .{ "throw", .kw_throw },
    .{ "try", .kw_try },
    .{ "typeof", .kw_typeof },
    .{ "var", .kw_var },
    .{ "void", .kw_void },
    .{ "while", .kw_while },
    .{ "with", .kw_with },

    // Contextual Keywords
    .{ "async", .kw_async },
    .{ "from", .kw_from },
    .{ "get", .kw_get },
    .{ "meta", .kw_meta },
    .{ "of", .kw_of },
    .{ "set", .kw_set },
    .{ "target", .kw_target },
    .{ "accessor", .kw_accessor },
    .{ "source", .kw_source },
    .{ "defer", .kw_defer },
    .{ "using", .kw_using },
    .{ "let", .kw_let },

    // Strict Mode Reserved
    .{ "implements", .kw_implements },
    .{ "interface", .kw_interface },
    .{ "package", .kw_package },
    .{ "private", .kw_private },
    .{ "protected", .kw_protected },
    .{ "public", .kw_public },
    .{ "static", .kw_static },
    .{ "yield", .kw_yield },

    // Literal Keywords
    .{ "true", .kw_true },
    .{ "false", .kw_false },
    .{ "null", .kw_null },
});

/// 각 토큰 종류의 표시 이름 (에러 메시지, 디버깅용).
/// Kind enum의 u8 값으로 인덱싱.
/// 키워드는 `kw_` 접두사를 제거하여 반환 (예: `kw_break` → `"break"`).
const token_names = blk: {
    const enum_fields = @typeInfo(Kind).@"enum".fields;
    var names: [enum_fields.len][]const u8 = undefined;
    for (enum_fields) |field| {
        names[field.value] = switch (@as(Kind, @enumFromInt(field.value))) {
            .eof => "<eof>",
            .undetermined => "<undetermined>",
            .syntax_error => "<syntax error>",
            .hashbang_comment => "#!",
            .identifier => "<identifier>",
            .private_identifier => "<private identifier>",
            .escaped_keyword => "<escaped keyword>",
            .escaped_strict_reserved => "<escaped strict reserved>",
            // Punctuators
            .l_paren => "(",
            .r_paren => ")",
            .l_bracket => "[",
            .r_bracket => "]",
            .l_curly => "{",
            .r_curly => "}",
            .semicolon => ";",
            .comma => ",",
            .colon => ":",
            .dot => ".",
            .dot3 => "...",
            .l_angle => "<",
            .r_angle => ">",
            .lt_eq => "<=",
            .gt_eq => ">=",
            .eq2 => "==",
            .neq => "!=",
            .eq3 => "===",
            .neq2 => "!==",
            .plus => "+",
            .minus => "-",
            .star => "*",
            .slash => "/",
            .percent => "%",
            .star2 => "**",
            .plus2 => "++",
            .minus2 => "--",
            .amp => "&",
            .pipe => "|",
            .caret => "^",
            .tilde => "~",
            .shift_left => "<<",
            .shift_right => ">>",
            .shift_right3 => ">>>",
            .amp2 => "&&",
            .pipe2 => "||",
            .bang => "!",
            .question => "?",
            .question2 => "??",
            .question_dot => "?.",
            .eq => "=",
            .plus_eq => "+=",
            .minus_eq => "-=",
            .star_eq => "*=",
            .slash_eq => "/=",
            .percent_eq => "%=",
            .star2_eq => "**=",
            .amp_eq => "&=",
            .pipe_eq => "|=",
            .caret_eq => "^=",
            .shift_left_eq => "<<=",
            .shift_right_eq => ">>=",
            .shift_right3_eq => ">>>=",
            .amp2_eq => "&&=",
            .pipe2_eq => "||=",
            .question2_eq => "??=",
            .arrow => "=>",
            .at => "@",
            // Literals
            .decimal => "<decimal>",
            .float => "<float>",
            .binary => "<binary>",
            .octal => "<octal>",
            .hex => "<hex>",
            .positive_exponential => "<exponential>",
            .negative_exponential => "<exponential>",
            .decimal_bigint => "<bigint>",
            .binary_bigint => "<bigint>",
            .octal_bigint => "<bigint>",
            .hex_bigint => "<bigint>",
            .string_literal => "<string>",
            .regexp_literal => "<regexp>",
            .no_substitution_template => "<template>",
            .template_head => "<template head>",
            .template_middle => "<template middle>",
            .template_tail => "<template tail>",
            // JSX
            .jsx_text => "<jsx text>",
            .jsx_identifier => "<jsx identifier>",
            // Keywords — kw_ 접두사를 제거하여 실제 키워드 문자열 반환
            else => blk2: {
                const name = field.name;
                if (name.len > 3 and name[0] == 'k' and name[1] == 'w' and name[2] == '_') {
                    break :blk2 name[3..];
                }
                break :blk2 name;
            },
        };
    }
    break :blk names;
};
