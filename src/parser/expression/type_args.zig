//! TypeScript expression type-argument disambiguation helpers.

const std = @import("std");
const token_mod = @import("../../lexer/token.zig");
const Kind = token_mod.Kind;
const Parser = @import("../parser.zig").Parser;

/// TypeScript의 canFollowTypeArgumentsInExpression 대응 (esbuild tsCanFollowTypeArgumentsInExpression).
/// `f<Type>` 다음에 올 수 있는 토큰인지 판별한다.
/// esbuild 3단계 로직:
/// 1. 호출/템플릿 토큰 -> true (확실히 type args)
/// 2. `<`, `>`, `+`, `-` (및 `>`로 시작하는 복합 토큰) -> false (확실히 비교)
/// 3. newline_before || isBinaryOperator || !isStartOfExpression -> true
pub fn canFollowTypeArgumentsInExpression(self: *const Parser) bool {
    const kind = self.current();
    return switch (kind) {
        // 호출, 멤버 접근, tagged template - 확실히 type args 뒤에 올 수 있음
        .l_paren, .dot, .question_dot => true,
        .no_substitution_template, .template_head => true,

        // `<` 뒤에 또 `<`는 의미 없고, `>`는 re-scan된 `>>`와 모호하므로 불허.
        // `+`, `-`는 이 컨텍스트에서 단항 연산자이므로 불허.
        // `>`로 시작하는 복합 토큰(>=, >>, >>>, >>=, >>>=)도 불허 (esbuild 동일).
        .l_angle,
        .r_angle,
        .plus,
        .minus,
        .gt_eq,
        .shift_right,
        .shift_right_eq,
        .shift_right3,
        .shift_right3_eq,
        => false,

        // 그 외: newline || binary operator || not start of expression -> true
        else => self.scanner.token.has_newline_before or
            tsIsBinaryOperator(self, kind) or
            !tsIsStartOfExpression(self, kind),
    };
}

/// TypeScript 컴파일러의 isBinaryOperator 대응.
/// 현재 토큰이 이항 연산자인지 판별한다.
fn tsIsBinaryOperator(self: *const Parser, kind: Kind) bool {
    if (kind == .kw_in) return self.ctx.allow_in;
    if (getBinaryPrecedence(kind) > 0) return true;
    if (kind == .identifier) {
        const text = self.tokenText();
        return std.mem.eql(u8, text, "as") or std.mem.eql(u8, text, "satisfies");
    }
    return false;
}

/// TypeScript 컴파일러의 isStartOfExpression 대응.
/// 현재 토큰이 expression의 시작이 될 수 있는지 판별한다.
fn tsIsStartOfExpression(self: *const Parser, kind: Kind) bool {
    if (tsIsStartOfLeftHandSideExpression(kind)) return true;
    return switch (kind) {
        .plus, .minus, .tilde, .bang => true,
        .kw_delete, .kw_typeof, .kw_void => true,
        .plus2, .minus2 => true,
        .l_angle => true,
        .private_identifier => true,
        .at => true,
        .kw_await, .kw_yield => true,
        else => tsIsBinaryOperator(self, kind),
    };
}

/// TypeScript 컴파일러의 isStartOfLeftHandSideExpression 대응.
fn tsIsStartOfLeftHandSideExpression(kind: Kind) bool {
    return switch (kind) {
        .kw_this, .kw_super => true,
        .kw_null, .kw_true, .kw_false => true,
        .string_literal,
        .no_substitution_template,
        .template_head,
        => true,
        .l_paren, .l_bracket, .l_curly => true,
        .kw_function, .kw_class, .kw_new => true,
        .slash, .slash_eq => true, // regex
        .identifier => true,
        .kw_import => true,
        else => kind.isNumericLiteral(), // decimal, float, hex, bigint 등
    };
}

/// Binary expression precedence used by the expression parser.
pub fn getBinaryPrecedence(kind: Kind) u8 {
    return switch (kind) {
        .pipe2 => 1, // ||
        .question2 => 1, // ??
        .amp2 => 2, // &&
        .pipe => 3, // |
        .caret => 4, // ^
        .amp => 5, // &
        .eq2, .neq, .eq3, .neq2 => 6, // == != === !==
        .l_angle, .r_angle, .lt_eq, .gt_eq, .kw_instanceof, .kw_in => 7, // < > <= >= instanceof in
        .shift_left, .shift_right, .shift_right3 => 8, // << >> >>>
        .plus, .minus => 9, // + -
        .star, .slash, .percent => 10, // * / %
        .star2 => 11, // ** (우결합)
        else => 0, // 이항 연산자 아님
    };
}
