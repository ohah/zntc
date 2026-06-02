//! Operator precedence levels for the code generator's parenthesization model.
//!
//! esbuild `internal/js_ast/js_ast.go` 의 `L` enum / `OpTable` 과 **동일한 상대
//! 순서**를 따른다 (oxc `oxc_syntax::precedence::Precedence` 도 같은 값을 복제).
//! 값이 클수록 더 강하게 묶인다(tighter binding). codegen 의
//! `emitExpr(node, level, flags)` 가 부모→자식으로 "이 위치에서 괄호 없이
//! 허용되는 최소 결합 강도" 를 내려보내고, 자식은 `자기 level <= 부모가 요구한
//! level` 이면(= `level.gte(entry)`) 괄호로 감싼다. 결합성은 자식에 내려보내는
//! level 을 ±1(`entry.lower()`) 로 인코딩한다.
//!
//! 주의 — parser 의 `expression/type_args.zig:getBinaryPrecedence` 와 **별개
//! 도메인**이다. 그쪽은 Pratt 파싱 전용(이항 11단계, `||`/`??` 를 동일 레벨 1
//! 로 둠)이고, 여기 Level 은 단항/postfix/new/call/member 까지 포함하는 23단계
//! 이며 `??` 와 `||`/`&&` 를 분리한다(ECMAScript 가 괄호 없는 혼용을 금지하므로
//! codegen 은 둘을 구분해야 한다). 두 표를 통합하면 양쪽 제약이 섞여 버그를
//! 유발하므로 통합하지 않는다. 이 파일은 PR1 시점에는 호출처가 없는 인프라이며,
//! emitExpr 전환(후속 PR)에서 사용된다.

const Kind = @import("../lexer/token.zig").Kind;

/// 연산자/표현식 결합 강도. esbuild `L` 과 동일 순서이므로 `@intFromEnum` 정수
/// 비교로 강도를 잰다 (값이 클수록 더 강하게 묶임).
pub const Level = enum(u8) {
    lowest = 0,
    comma,
    spread,
    yield,
    assign,
    conditional,
    nullish_coalescing,
    logical_or,
    logical_and,
    bitwise_or,
    bitwise_xor,
    bitwise_and,
    equals,
    compare,
    shift,
    add,
    multiply,
    exponentiation,
    prefix,
    postfix,
    new,
    call,
    member,

    /// 한 단계 약하게(괄호를 더 잘 침). 결합성 인코딩에서
    /// `leftLevel`/`rightLevel = entry.lower()` 로 쓴다. `lowest` 는 0 에서
    /// 멈춰 underflow 를 막는다(0 아래로 내려갈 일은 없다).
    pub fn lower(self: Level) Level {
        const v = @intFromEnum(self);
        return @enumFromInt(if (v == 0) 0 else v - 1);
    }

    /// `self >= other` (자기 결합 강도가 부모가 요구한 최소 강도 이상인가).
    /// codegen 의 `wrap := level >= entry.Level` 한 줄에 대응한다.
    pub fn gte(self: Level, other: Level) bool {
        return @intFromEnum(self) >= @intFromEnum(other);
    }
};

/// `binary_expression` / `logical_expression` 의 연산자 Kind → Level.
/// 이항/논리 연산자가 아니면 null (assignment 는 별도 노드, comma 는 sequence
/// 노드로 따로 처리). esbuild `OpTable` 의 `BinOp*` 항목과 1:1.
pub fn binaryOpLevel(op: Kind) ?Level {
    return switch (op) {
        .star2 => .exponentiation, // **  (우결합)
        .star, .slash, .percent => .multiply, // * / %
        .plus, .minus => .add, // + -
        .shift_left, .shift_right, .shift_right3 => .shift, // << >> >>>
        .l_angle, .r_angle, .lt_eq, .gt_eq, .kw_in, .kw_instanceof => .compare, // < <= > >= in instanceof
        .eq2, .neq, .eq3, .neq2 => .equals, // == != === !==
        .amp => .bitwise_and, // &
        .caret => .bitwise_xor, // ^
        .pipe => .bitwise_or, // |
        .amp2 => .logical_and, // &&
        .pipe2 => .logical_or, // ||
        .question2 => .nullish_coalescing, // ??
        else => null,
    };
}

/// 이항 연산자가 좌결합인지. `**`(우결합)와 비-이항만 false.
/// esbuild `IsLeftAssociative`: `BinOpAdd <= op < BinOpComma && op != BinOpPow`.
pub fn isLeftAssociative(op: Kind) bool {
    return binaryOpLevel(op) != null and op != .star2;
}

/// 이항 연산자가 우결합인지. esbuild `IsRightAssociative`:
/// `op >= BinOpAssign || op == BinOpPow`. zntc 에서 assignment 는 별도 노드
/// (`assignment_expression`)라 binary 연산자 Kind 에는 들어오지 않으므로
/// 여기서는 `**` 만 해당한다.
pub fn isRightAssociative(op: Kind) bool {
    return op == .star2;
}
