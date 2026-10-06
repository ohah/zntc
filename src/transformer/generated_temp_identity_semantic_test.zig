const std = @import("std");
const ast_mod = @import("../parser/ast.zig");
const Span = @import("../lexer/token.zig").Span;
const SemanticEditor = @import("../semantic/editor.zig").SemanticEditor;
const bindGeneratedTempByIdentity = @import("transformer/semantic_edit.zig").bindGeneratedTempByIdentity;

test "#4819 generated temp binding rejects same-spelled different allocation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var ast = ast_mod.Ast.init(allocator, "");
    defer ast.deinit();
    var editor = try SemanticEditor.init(allocator, &ast, &.{}, &.{}, &.{}, .empty, &.{}, &.{}, .empty);
    defer editor.deinit();
    const callback_scope = try editor.addScope(.none, .none, .function, false);

    const decoy_span = try ast.addUniqueString("_callbackTemp");
    const decoy_binding = try ast.addNode(.{
        .tag = .binding_identifier,
        .span = decoy_span,
        .data = .{ .string_ref = decoy_span },
    });
    const decoy_id = try editor.declare(
        decoy_binding,
        decoy_span,
        Span.EMPTY,
        callback_scope,
        .variable_var,
        0,
        0,
    );

    // Same spelling does not make a second allocation the decoy's symbol.
    const allocation_span = try ast.addUniqueString("_callbackTemp");
    const different_binding = try ast.addNode(.{
        .tag = .binding_identifier,
        .span = allocation_span,
        .data = .{ .string_ref = allocation_span },
    });
    try std.testing.expectError(
        error.DuplicateBinding,
        bindGeneratedTempByIdentity(
            &editor,
            different_binding,
            allocation_span,
            Span.EMPTY,
            callback_scope,
            callback_scope,
            null,
        ),
    );
    try std.testing.expectError(
        error.InvalidSymbol,
        bindGeneratedTempByIdentity(
            &editor,
            different_binding,
            allocation_span,
            Span.EMPTY,
            callback_scope,
            callback_scope,
            @intFromEnum(decoy_id),
        ),
    );
    try std.testing.expectEqual(@as(?u32, null), editor.symbol_ids.items[@intFromEnum(different_binding)]);

    // A later alias can share the symbol only when its exact allocation span
    // and the explicitly supplied SymbolId agree.
    const exact_alias = try ast.addNode(.{
        .tag = .binding_identifier,
        .span = decoy_span,
        .data = .{ .string_ref = decoy_span },
    });
    try std.testing.expectEqual(
        decoy_id,
        try bindGeneratedTempByIdentity(
            &editor,
            exact_alias,
            decoy_span,
            Span.EMPTY,
            callback_scope,
            callback_scope,
            @intFromEnum(decoy_id),
        ),
    );
    try std.testing.expectEqual(@as(?u32, @intFromEnum(decoy_id)), editor.symbol_ids.items[@intFromEnum(exact_alias)]);
}
