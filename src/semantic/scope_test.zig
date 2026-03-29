const std = @import("std");
const scope_mod = @import("scope.zig");
const ScopeKind = scope_mod.ScopeKind;
const ScopeId = scope_mod.ScopeId;

test "ScopeKind.isVarScope" {
    try std.testing.expect(ScopeKind.global.isVarScope());
    try std.testing.expect(ScopeKind.function.isVarScope());
    try std.testing.expect(ScopeKind.module.isVarScope());
    try std.testing.expect(!ScopeKind.block.isVarScope());
    try std.testing.expect(!ScopeKind.catch_clause.isVarScope());
    try std.testing.expect(!ScopeKind.class_body.isVarScope());
}

test "ScopeId.none" {
    const id = ScopeId.none;
    try std.testing.expect(id.isNone());

    const valid: ScopeId = @enumFromInt(0);
    try std.testing.expect(!valid.isNone());
}
