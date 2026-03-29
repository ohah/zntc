const std = @import("std");
const symbol_mod = @import("symbol.zig");
const SymbolKind = symbol_mod.SymbolKind;

test "SymbolKind.isBlockScoped" {
    try std.testing.expect(SymbolKind.variable_let.isBlockScoped());
    try std.testing.expect(SymbolKind.variable_const.isBlockScoped());
    try std.testing.expect(SymbolKind.class_decl.isBlockScoped());
    try std.testing.expect(SymbolKind.generator_decl.isBlockScoped());
    try std.testing.expect(SymbolKind.async_function_decl.isBlockScoped());
    try std.testing.expect(SymbolKind.async_generator_decl.isBlockScoped());
    try std.testing.expect(!SymbolKind.variable_var.isBlockScoped());
    try std.testing.expect(!SymbolKind.function_decl.isBlockScoped());
    try std.testing.expect(!SymbolKind.parameter.isBlockScoped());
}

test "SymbolKind.allowsRedeclaration" {
    try std.testing.expect(SymbolKind.variable_var.allowsRedeclaration());
    try std.testing.expect(SymbolKind.function_decl.allowsRedeclaration());
    try std.testing.expect(!SymbolKind.variable_let.allowsRedeclaration());
    try std.testing.expect(!SymbolKind.variable_const.allowsRedeclaration());
    try std.testing.expect(!SymbolKind.import_binding.allowsRedeclaration());
}

test "SymbolKind.isFunctionLike" {
    try std.testing.expect(SymbolKind.function_decl.isFunctionLike());
    try std.testing.expect(SymbolKind.generator_decl.isFunctionLike());
    try std.testing.expect(SymbolKind.async_function_decl.isFunctionLike());
    try std.testing.expect(SymbolKind.async_generator_decl.isFunctionLike());
    try std.testing.expect(!SymbolKind.variable_var.isFunctionLike());
    try std.testing.expect(!SymbolKind.variable_let.isFunctionLike());
    try std.testing.expect(!SymbolKind.class_decl.isFunctionLike());
}

test "DeclFlags.intersects" {
    const var_flags = SymbolKind.variable_var.declFlags();
    const let_flags = SymbolKind.variable_let.declFlags();
    const fn_flags = SymbolKind.function_decl.declFlags();

    // var와 let은 공존 불가: let의 excludes에 function_scoped가 포함
    try std.testing.expect(var_flags.intersects(let_flags.excludes()));
    // var와 function은 공존 가능: var의 excludes에 function_scoped/is_function이 제외
    try std.testing.expect(!fn_flags.intersects(var_flags.excludes()));
    // let과 let은 공존 불가
    try std.testing.expect(let_flags.intersects(let_flags.excludes()));
}

test "DeclFlags.excludes - var" {
    const var_excludes = SymbolKind.variable_var.declFlags().excludes();
    // var는 let/const/class와 충돌
    try std.testing.expect(var_excludes.block_scoped);
    try std.testing.expect(var_excludes.is_class);
    // var는 다른 var/function과 충돌하지 않음
    try std.testing.expect(!var_excludes.function_scoped);
    try std.testing.expect(!var_excludes.is_function);
}

test "DeclFlags.excludes - import" {
    const import_excludes = SymbolKind.import_binding.declFlags().excludes();
    // import는 모든 것과 충돌
    try std.testing.expect(import_excludes.function_scoped);
    try std.testing.expect(import_excludes.block_scoped);
    try std.testing.expect(import_excludes.is_function);
    try std.testing.expect(import_excludes.is_import);
}
