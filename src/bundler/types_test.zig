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
    try std.testing.expectEqual(ModuleType.ts, ModuleType.fromExtension(".ts"));
    try std.testing.expectEqual(ModuleType.tsx, ModuleType.fromExtension(".tsx"));
    try std.testing.expectEqual(ModuleType.js, ModuleType.fromExtension(".js"));
    try std.testing.expectEqual(ModuleType.jsx, ModuleType.fromExtension(".jsx"));
    try std.testing.expectEqual(ModuleType.js, ModuleType.fromExtension(".mjs"));
    try std.testing.expectEqual(ModuleType.ts, ModuleType.fromExtension(".mts"));
    try std.testing.expectEqual(ModuleType.js, ModuleType.fromExtension(".cjs"));
    try std.testing.expectEqual(ModuleType.ts, ModuleType.fromExtension(".cts"));
    try std.testing.expectEqual(ModuleType.json, ModuleType.fromExtension(".json"));
    try std.testing.expectEqual(ModuleType.css, ModuleType.fromExtension(".css"));
    try std.testing.expectEqual(ModuleType.unknown, ModuleType.fromExtension(".png"));
    try std.testing.expectEqual(ModuleType.unknown, ModuleType.fromExtension(".wasm"));
}

test "ParsedLoader: JS-family loader strings carry module type" {
    inline for (.{
        .{ "js", ModuleType.js },
        .{ "jsx", ModuleType.jsx },
        .{ "ts", ModuleType.ts },
        .{ "tsx", ModuleType.tsx },
    }) |case| {
        const parsed = types.ParsedLoader.fromString(case[0]) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(types.Loader.javascript, parsed.loader);
        try std.testing.expectEqual(case[1], parsed.module_type.?);
    }
}

test "ImportRecord: default resolved is none" {
    const record = ImportRecord{
        .specifier = "./foo",
        .kind = .static_import,
        .span = Span.EMPTY,
    };
    try std.testing.expect(record.resolved.isNone());
}

test "ModuleKey: 긴 이름은 heap으로 spill되어 makeModuleKey와 동일한 키를 만든다" {
    const allocator = std.testing.allocator;

    // 4091바이트(= 4096 - 5)를 초과하는 이름은 기존 고정 스택 버퍼를 넘긴다.
    // (이전 구현은 ReleaseFast에서 assert가 소거되어 stack-smashing이 발생했다.)
    const long_name = try allocator.alloc(u8, 5000);
    defer allocator.free(long_name);
    @memset(long_name, 'a');

    var mk = types.ModuleKey{};
    defer mk.deinit(allocator);
    const key = try mk.make(allocator, 7, long_name);

    // 긴 이름이므로 heap으로 spill되어야 한다 (스택 버퍼 오버플로 방지).
    try std.testing.expect(mk.spill != null);

    // heap 버전(makeModuleKey)과 바이트가 정확히 같아야 map 조회가 일치한다.
    const heap_key = try types.makeModuleKey(allocator, 7, long_name);
    defer allocator.free(heap_key);
    try std.testing.expectEqualSlices(u8, heap_key, key);
}

test "ModuleKey: 짧은 이름은 할당 없이 스택 버퍼를 쓴다" {
    const allocator = std.testing.allocator;

    var mk = types.ModuleKey{};
    defer mk.deinit(allocator);
    const key = try mk.make(allocator, 3, "foo");

    // 버퍼에 맞으므로 spill이 없어야 한다 (일반 경로 = 무할당).
    try std.testing.expect(mk.spill == null);

    const heap_key = try types.makeModuleKey(allocator, 3, "foo");
    defer allocator.free(heap_key);
    try std.testing.expectEqualSlices(u8, heap_key, key);
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
