const std = @import("std");
const flags_mod = @import("flags.zig");
const validate = flags_mod.validate;
const parse = flags_mod.parse;

test "valid flags" {
    try std.testing.expect(validate("") == null);
    try std.testing.expect(validate("g") == null);
    try std.testing.expect(validate("gi") == null);
    try std.testing.expect(validate("gimsuy") == null);
    try std.testing.expect(validate("dgimsvy") == null);
}

test "duplicate flags" {
    try std.testing.expect(validate("gg") != null);
    try std.testing.expect(validate("gig") != null);
    try std.testing.expect(validate("ii") != null);
}

test "invalid flags" {
    try std.testing.expect(validate("x") != null);
    try std.testing.expect(validate("a") != null);
    try std.testing.expect(validate("gi2") != null);
}

test "u and v conflict" {
    try std.testing.expect(validate("uv") != null);
    try std.testing.expect(validate("vu") != null);
    try std.testing.expect(validate("guv") != null);
}

test "parse flags" {
    const f = parse("gi");
    try std.testing.expect(f.g);
    try std.testing.expect(f.i);
    try std.testing.expect(!f.m);
    try std.testing.expect(!f.u);
}
