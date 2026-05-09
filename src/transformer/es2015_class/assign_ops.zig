//! Shared assignment operator helpers for ES2015 class lowering.

const token_mod = @import("../../lexer/token.zig");

/// compound assignment(+=, -=, *=, ... >>>=)을 base binary op으로 매핑.
/// 순수 대입(=) / 논리 대입(??=, ||=, &&=)은 null — 논리 대입은 별도 경로에서 처리.
pub fn compoundAssignBaseOp(op_flags: u16) ?u16 {
    const op: token_mod.Kind = @enumFromInt(op_flags);
    return switch (op) {
        .plus_eq => @intFromEnum(token_mod.Kind.plus),
        .minus_eq => @intFromEnum(token_mod.Kind.minus),
        .star_eq => @intFromEnum(token_mod.Kind.star),
        .slash_eq => @intFromEnum(token_mod.Kind.slash),
        .percent_eq => @intFromEnum(token_mod.Kind.percent),
        .star2_eq => @intFromEnum(token_mod.Kind.star2),
        .amp_eq => @intFromEnum(token_mod.Kind.amp),
        .pipe_eq => @intFromEnum(token_mod.Kind.pipe),
        .caret_eq => @intFromEnum(token_mod.Kind.caret),
        .shift_left_eq => @intFromEnum(token_mod.Kind.shift_left),
        .shift_right_eq => @intFromEnum(token_mod.Kind.shift_right),
        .shift_right3_eq => @intFromEnum(token_mod.Kind.shift_right3),
        else => null,
    };
}
