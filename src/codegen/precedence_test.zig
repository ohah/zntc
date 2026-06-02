//! precedence.zig 단위 검증 — Level 순서/매핑이 esbuild `OpTable` 과 1:1 인지.
//! (PR1: 인프라만. 호출처는 후속 emitExpr 전환 PR 에서 생긴다.)

const std = @import("std");
const p = @import("precedence.zig");
const Level = p.Level;
const Kind = @import("../lexer/token.zig").Kind;

test "precedence: Level enum 순서가 esbuild L 과 동일 (lowest=0 .. member=22)" {
    const order = [_]Level{
        .lowest,      .comma,          .spread,             .yield,
        .assign,      .conditional,    .nullish_coalescing, .logical_or,
        .logical_and, .bitwise_or,     .bitwise_xor,        .bitwise_and,
        .equals,      .compare,        .shift,              .add,
        .multiply,    .exponentiation, .prefix,             .postfix,
        .new,         .call,           .member,
    };
    try std.testing.expectEqual(@as(usize, 23), order.len);
    for (order, 0..) |lvl, i| {
        try std.testing.expectEqual(@as(u8, @intCast(i)), @intFromEnum(lvl));
    }
}

test "precedence: binaryOpLevel 가 esbuild OpTable 과 1:1" {
    const cases = [_]struct { Kind, Level }{
        .{ .star2, .exponentiation },
        .{ .star, .multiply },
        .{ .slash, .multiply },
        .{ .percent, .multiply },
        .{ .plus, .add },
        .{ .minus, .add },
        .{ .shift_left, .shift },
        .{ .shift_right, .shift },
        .{ .shift_right3, .shift },
        .{ .l_angle, .compare },
        .{ .r_angle, .compare },
        .{ .lt_eq, .compare },
        .{ .gt_eq, .compare },
        .{ .kw_in, .compare },
        .{ .kw_instanceof, .compare },
        .{ .eq2, .equals },
        .{ .neq, .equals },
        .{ .eq3, .equals },
        .{ .neq2, .equals },
        .{ .amp, .bitwise_and },
        .{ .caret, .bitwise_xor },
        .{ .pipe, .bitwise_or },
        .{ .amp2, .logical_and },
        .{ .pipe2, .logical_or },
        .{ .question2, .nullish_coalescing },
    };
    for (cases) |c| {
        try std.testing.expectEqual(@as(?Level, c[1]), p.binaryOpLevel(c[0]));
    }
}

test "precedence: 비-이항 Kind 는 null" {
    try std.testing.expectEqual(@as(?Level, null), p.binaryOpLevel(.identifier));
    try std.testing.expectEqual(@as(?Level, null), p.binaryOpLevel(.kw_function));
}

test "precedence: 이항 상대 순서 (** > * > + > << > < > == > & > ^ > | > && > || > ??)" {
    const gt = struct {
        fn f(a: Kind, b: Kind) bool {
            return @intFromEnum(p.binaryOpLevel(a).?) > @intFromEnum(p.binaryOpLevel(b).?);
        }
    }.f;
    try std.testing.expect(gt(.star2, .star)); // ** > *
    try std.testing.expect(gt(.star, .plus)); // * > +
    try std.testing.expect(gt(.plus, .shift_left)); // + > <<
    try std.testing.expect(gt(.shift_left, .l_angle)); // << > <
    try std.testing.expect(gt(.l_angle, .eq2)); // < > ==
    try std.testing.expect(gt(.eq2, .amp)); // == > &
    try std.testing.expect(gt(.amp, .caret)); // & > ^
    try std.testing.expect(gt(.caret, .pipe)); // ^ > |
    try std.testing.expect(gt(.pipe, .amp2)); // | > &&
    try std.testing.expect(gt(.amp2, .pipe2)); // && > ||
    try std.testing.expect(gt(.pipe2, .question2)); // || > ??
}

test "precedence: 결합성 — 이항은 좌결합, ** 만 우결합" {
    try std.testing.expect(p.isLeftAssociative(.plus));
    try std.testing.expect(p.isLeftAssociative(.star));
    try std.testing.expect(p.isLeftAssociative(.pipe2));
    try std.testing.expect(!p.isLeftAssociative(.star2)); // ** 는 우결합
    try std.testing.expect(!p.isLeftAssociative(.identifier)); // 비-이항

    try std.testing.expect(p.isRightAssociative(.star2));
    try std.testing.expect(!p.isRightAssociative(.plus));
    try std.testing.expect(!p.isRightAssociative(.identifier));
}

test "precedence: lower/gte" {
    try std.testing.expectEqual(Level.lowest, Level.lowest.lower()); // 0 에서 멈춤(underflow 방지)
    try std.testing.expectEqual(Level.comma, Level.spread.lower());
    try std.testing.expectEqual(Level.multiply, Level.exponentiation.lower());

    try std.testing.expect(Level.member.gte(Level.lowest));
    try std.testing.expect(Level.multiply.gte(Level.multiply)); // 같으면 true (>=)
    try std.testing.expect(!Level.add.gte(Level.multiply));
}
