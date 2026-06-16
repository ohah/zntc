// semantic_codec_test.zig — #4438 PR2 semantic 직렬화 round-trip + fail-safe.

const std = @import("std");
const testing = std.testing;
const codec = @import("semantic_codec.zig");
const ModuleSemanticData = @import("module.zig").ModuleSemanticData;
const Symbol = @import("../semantic/symbol.zig").Symbol;
const Scope = @import("../semantic/scope.zig").Scope;
const Reference = @import("../semantic/symbol.zig").Reference;
const Scanner = @import("../lexer/scanner.zig").Scanner;
const Parser = @import("../parser/parser.zig").Parser;
const SemanticAnalyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer;

test "semantic_codec: analyzer round-trip — relocatable 필드 보존" {
    const alloc = testing.allocator;
    const source = "const a = 1; function f(x) { let y = x + a; return y; } class C { m() {} } let z = f(2);";

    var scanner = try Scanner.init(alloc, source);
    defer scanner.deinit();
    var parser = Parser.init(alloc, &scanner);
    defer parser.deinit();
    _ = try parser.parse();
    var ana = SemanticAnalyzer.init(alloc, &parser.ast);
    defer ana.deinit();
    try ana.analyze();

    try testing.expect(ana.symbols.items.len > 0); // 비어있으면 검증 무의미

    const sem = ModuleSemanticData{
        .symbols = ana.symbols,
        .scopes = ana.scopes.items,
        .scope_maps = &.{},
        .exported_names = .empty,
        .symbol_ids = ana.symbol_ids.items,
        .unresolved_references = .empty,
        .references = ana.references.items,
        .numeric_const_texts = .empty,
        .helper_scope_map = .empty,
    };

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try codec.serialize(&sem, &buf, alloc);

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const sem2 = try codec.deserialize(buf.items, arena.allocator());

    try testing.expectEqual(sem.symbols.items.len, sem2.symbols.items.len);
    try testing.expectEqual(sem.scopes.len, sem2.scopes.len);
    try testing.expectEqual(sem.symbol_ids.len, sem2.symbol_ids.len);
    try testing.expectEqual(sem.references.len, sem2.references.len);

    // relocatable 슬라이스는 byte 동일
    try testing.expectEqualSlices(Scope, sem.scopes, sem2.scopes);
    try testing.expectEqualSlices(?u32, sem.symbol_ids, sem2.symbol_ids);
    try testing.expectEqualSlices(Reference, sem.references, sem2.references);

    // Symbol: synthetic_name(슬라이스)은 content 비교, 나머지는 memcpy 동일
    for (sem.symbols.items, sem2.symbols.items) |s1, s2| {
        try testing.expectEqual(s1.name, s2.name);
        try testing.expectEqual(s1.scope_id, s2.scope_id);
        try testing.expectEqual(s1.kind, s2.kind);
        try testing.expectEqual(s1.declaration_span, s2.declaration_span);
        try testing.expectEqualStrings(s1.synthetic_name, s2.synthetic_name);
    }
}

test "semantic_codec: synthetic_name 보존 (합성 심볼)" {
    const alloc = testing.allocator;

    var symbols: std.ArrayList(Symbol) = .empty;
    defer symbols.deinit(alloc);
    try symbols.append(alloc, std.mem.zeroInit(Symbol, .{ .synthetic_name = @as([]const u8, "") }));
    try symbols.append(alloc, std.mem.zeroInit(Symbol, .{ .synthetic_name = @as([]const u8, "__syn_helper") }));

    const sem = ModuleSemanticData{
        .symbols = symbols,
        .scopes = &.{},
        .scope_maps = &.{},
        .exported_names = .empty,
        .symbol_ids = &.{},
        .unresolved_references = .empty,
        .references = &.{},
        .numeric_const_texts = .empty,
        .helper_scope_map = .empty,
    };

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try codec.serialize(&sem, &buf, alloc);

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const sem2 = try codec.deserialize(buf.items, arena.allocator());

    try testing.expectEqual(@as(usize, 2), sem2.symbols.items.len);
    try testing.expectEqualStrings("", sem2.symbols.items[0].synthetic_name);
    try testing.expectEqualStrings("__syn_helper", sem2.symbols.items[1].synthetic_name);
}

test "semantic_codec: 변조/버전/매직/truncated 거부 (fail-safe)" {
    const alloc = testing.allocator;

    var symbols: std.ArrayList(Symbol) = .empty;
    defer symbols.deinit(alloc);
    try symbols.append(alloc, std.mem.zeroInit(Symbol, .{ .synthetic_name = @as([]const u8, "") }));

    const sem = ModuleSemanticData{
        .symbols = symbols,
        .scopes = &.{},
        .scope_maps = &.{},
        .exported_names = .empty,
        .symbol_ids = &.{},
        .unresolved_references = .empty,
        .references = &.{},
        .numeric_const_texts = .empty,
        .helper_scope_map = .empty,
    };

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try codec.serialize(&sem, &buf, alloc);

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    // 정상은 성공
    _ = try codec.deserialize(buf.items, arena.allocator());

    inline for (.{
        .{ 0, @as(u8, 0xFF), error.BadMagic },
        .{ 4, @as(u8, 0xEE), error.UnsupportedVersion },
    }) |tc| {
        const dup = try alloc.dupe(u8, buf.items);
        defer alloc.free(dup);
        dup[tc[0]] ^= tc[1];
        try testing.expectError(tc[2], codec.deserialize(dup, arena.allocator()));
    }
    // checksum (payload 변조)
    {
        const dup = try alloc.dupe(u8, buf.items);
        defer alloc.free(dup);
        dup[dup.len - 1] ^= 0xFF;
        try testing.expectError(error.ChecksumMismatch, codec.deserialize(dup, arena.allocator()));
    }
    // truncated
    try testing.expectError(error.Truncated, codec.deserialize(buf.items[0..8], arena.allocator()));
}
