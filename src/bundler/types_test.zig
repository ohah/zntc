const std = @import("std");
const types = @import("types.zig");
const ModuleIndex = types.ModuleIndex;
const ModuleType = types.ModuleType;
const ImportRecord = types.ImportRecord;
const BundlerDiagnostic = types.BundlerDiagnostic;
const Span = @import("../lexer/token.zig").Span;

// ============================================================
// Tests
// ============================================================

test "ModuleIndex: none sentinel" {
    try std.testing.expect(ModuleIndex.none.isNone());
    const idx: ModuleIndex = @enumFromInt(0);
    try std.testing.expect(!idx.isNone());
}

test "ModuleIndex: size is 4 bytes" {
    try std.testing.expectEqual(@as(usize, 4), @sizeOf(ModuleIndex));
}

test "ModuleType: fromExtension" {
    try std.testing.expectEqual(ModuleType.javascript, ModuleType.fromExtension(".ts"));
    try std.testing.expectEqual(ModuleType.javascript, ModuleType.fromExtension(".tsx"));
    try std.testing.expectEqual(ModuleType.javascript, ModuleType.fromExtension(".js"));
    try std.testing.expectEqual(ModuleType.javascript, ModuleType.fromExtension(".jsx"));
    try std.testing.expectEqual(ModuleType.javascript, ModuleType.fromExtension(".mjs"));
    try std.testing.expectEqual(ModuleType.javascript, ModuleType.fromExtension(".mts"));
    try std.testing.expectEqual(ModuleType.javascript, ModuleType.fromExtension(".cjs"));
    try std.testing.expectEqual(ModuleType.javascript, ModuleType.fromExtension(".cts"));
    try std.testing.expectEqual(ModuleType.json, ModuleType.fromExtension(".json"));
    try std.testing.expectEqual(ModuleType.css, ModuleType.fromExtension(".css"));
    try std.testing.expectEqual(ModuleType.unknown, ModuleType.fromExtension(".png"));
    try std.testing.expectEqual(ModuleType.unknown, ModuleType.fromExtension(".wasm"));
}

test "ImportRecord: default resolved is none" {
    const record = ImportRecord{
        .specifier = "./foo",
        .kind = .static_import,
        .span = Span.EMPTY,
    };
    try std.testing.expect(record.resolved.isNone());
}

test "BundlerDiagnostic: default suggestion is null" {
    const diag = BundlerDiagnostic{
        .code = .unresolved_import,
        .severity = .@"error",
        .message = "Module not found",
        .file_path = "src/index.ts",
        .span = Span.EMPTY,
        .step = .resolve,
    };
    try std.testing.expect(diag.suggestion == null);
}
