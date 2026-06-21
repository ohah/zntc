// semantic_codec_test.zig — #4438 PR2 semantic 직렬화 round-trip + fail-safe.

const std = @import("std");
const testing = std.testing;
const codec = @import("semantic_codec.zig");
const ModuleSemanticData = @import("module.zig").ModuleSemanticData;
const Symbol = @import("../semantic/symbol.zig").Symbol;
const Scope = @import("../semantic/scope.zig").Scope;
const Reference = @import("../semantic/symbol.zig").Reference;
const Span = @import("../lexer/token.zig").Span;
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

    try testing.expect(ana.scope_maps.items.len > 0); // 맵 round-trip 검증 의미 보장

    const sem = ModuleSemanticData{
        .symbols = ana.symbols,
        .scopes = ana.scopes.items,
        .scope_maps = ana.scope_maps.items,
        .exported_names = ana.exported_names,
        .symbol_ids = ana.symbol_ids.items,
        .unresolved_references = ana.unresolved_references,
        .references = ana.references.items,
        .numeric_const_texts = ana.numeric_const_texts,
        .helper_scope_map = ana.helper_scope_map,
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

    // scope_maps: 실 analyzer 출력 — 맵 개수 + 각 키→심볼인덱스 동일
    try testing.expectEqual(sem.scope_maps.len, sem2.scope_maps.len);
    for (sem.scope_maps, sem2.scope_maps) |*m1, *m2| {
        try testing.expectEqual(m1.count(), m2.count());
        var it = m1.iterator();
        while (it.next()) |e| {
            try testing.expectEqual(e.value_ptr.*, m2.get(e.key_ptr.*).?);
        }
    }
    try testing.expectEqual(sem.unresolved_references.count(), sem2.unresolved_references.count());
    try testing.expectEqual(sem.numeric_const_texts.count(), sem2.numeric_const_texts.count());
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

test "semantic_codec: HashMap 5개 round-trip (값 타입별)" {
    const alloc = testing.allocator;

    // scope_maps: 2개 스코프(StringHashMap usize). 빈 맵도 1개 섞어 경계 확인.
    var sm0: std.StringHashMapUnmanaged(usize) = .empty;
    var sm1: std.StringHashMapUnmanaged(usize) = .empty;
    defer sm0.deinit(alloc);
    defer sm1.deinit(alloc);
    try sm0.put(alloc, "a", 0);
    try sm0.put(alloc, "f", 1);
    try sm1.put(alloc, "x", 2);
    var scope_maps = [_]std.StringHashMapUnmanaged(usize){ sm0, sm1, .empty };

    var exported: std.StringHashMapUnmanaged(Span) = .empty;
    defer exported.deinit(alloc);
    try exported.put(alloc, "f", .{ .start = 9, .end = 10 });

    var unres: std.StringHashMapUnmanaged(void) = .empty;
    defer unres.deinit(alloc);
    try unres.put(alloc, "globalThis", {});

    var nums: std.AutoHashMapUnmanaged(u32, []const u8) = .empty;
    defer nums.deinit(alloc);
    try nums.put(alloc, 0, "1");
    try nums.put(alloc, 2, "42");

    var helper: std.StringHashMapUnmanaged(usize) = .empty;
    defer helper.deinit(alloc);
    try helper.put(alloc, "_jsx", 3);

    const sem = ModuleSemanticData{
        .symbols = .empty,
        .scopes = &.{},
        .scope_maps = &scope_maps,
        .exported_names = exported,
        .symbol_ids = &.{},
        .unresolved_references = unres,
        .references = &.{},
        .numeric_const_texts = nums,
        .helper_scope_map = helper,
    };

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try codec.serialize(&sem, &buf, alloc);

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const sem2 = try codec.deserialize(buf.items, arena.allocator());

    try testing.expectEqual(@as(usize, 3), sem2.scope_maps.len);
    try testing.expectEqual(@as(?usize, 0), sem2.scope_maps[0].get("a"));
    try testing.expectEqual(@as(?usize, 1), sem2.scope_maps[0].get("f"));
    try testing.expectEqual(@as(?usize, 2), sem2.scope_maps[1].get("x"));
    try testing.expectEqual(@as(u32, 0), sem2.scope_maps[2].count());

    const exp = sem2.exported_names.get("f").?;
    try testing.expectEqual(@as(u32, 9), exp.start);
    try testing.expectEqual(@as(u32, 10), exp.end);

    try testing.expect(sem2.unresolved_references.contains("globalThis"));
    try testing.expectEqual(@as(u32, 1), sem2.unresolved_references.count());

    try testing.expectEqualStrings("1", sem2.numeric_const_texts.get(0).?);
    try testing.expectEqualStrings("42", sem2.numeric_const_texts.get(2).?);

    try testing.expectEqual(@as(?usize, 3), sem2.helper_scope_map.get("_jsx"));
}

// #4438 회귀 가드: Symbol/Scope/Reference 의 struct 꼬리 padding(미초기화)이 직렬화에 새지
// 않아야 한다(결정성). 통째 memcpy 는 poison 을 stream 에 섞어 같은 의미도 byte 가 달라졌다.
// 정반대 poison(0xAA/0x55)으로 raw 를 채우고 의미 필드만 동일 세팅 → byte-identical 이어야.
test "semantic_codec: struct padding poison 이 직렬화에 새지 않는다 (#4438 결정성)" {
    const alloc = testing.allocator;

    const build = struct {
        fn f(a: std.mem.Allocator, poison: u8) !struct {
            sem: ModuleSemanticData,
            symbols: std.ArrayList(Symbol),
            scopes: []Scope,
            refs: []Reference,
            ids: []?u32,
        } {
            var symbols: std.ArrayList(Symbol) = .empty;
            var s: Symbol = undefined;
            @memset(std.mem.asBytes(&s), poison);
            s.synthetic_name = ""; // 슬라이스는 명시 세팅(poison ptr 미사용)
            s.name = .{ .start = 1, .end = 2 };
            s.scope_id = @enumFromInt(0);
            s.origin_scope = @enumFromInt(0);
            s.kind = .variable_const;
            s.decl_flags = .{ .block_scoped = true, .is_const = true };
            s.declaration_span = .{ .start = 1, .end = 2 };
            s.reference_count = 5;
            s.write_count = 0;
            s.const_kind = .number;
            s.synthetic_kind = null;
            try symbols.append(a, s);

            const scopes = try a.alloc(Scope, 1);
            @memset(std.mem.asBytes(&scopes[0]), poison);
            scopes[0].parent = @enumFromInt(std.math.maxInt(u32));
            scopes[0].kind = .global;
            scopes[0].is_strict = true;
            scopes[0].subtree_has_direct_eval = false;
            scopes[0].subtree_has_with = false;
            scopes[0].symbol_count = 1;

            const refs = try a.alloc(Reference, 1);
            @memset(std.mem.asBytes(&refs[0]), poison);
            refs[0].node_index = @enumFromInt(3);
            refs[0].scope_id = @enumFromInt(0);
            refs[0].symbol_id = @enumFromInt(0);
            refs[0].stmt_idx = 0;
            refs[0].scope_stmt_idx = 0;
            refs[0].flags = .{ .read = true };

            const ids = try a.alloc(?u32, 2);
            ids[0] = 0;
            ids[1] = null;

            return .{
                .sem = .{
                    .symbols = symbols,
                    .scopes = scopes,
                    .scope_maps = &.{},
                    .exported_names = .empty,
                    .symbol_ids = ids,
                    .unresolved_references = .empty,
                    .references = refs,
                    .numeric_const_texts = .empty,
                    .helper_scope_map = .empty,
                },
                .symbols = symbols,
                .scopes = scopes,
                .refs = refs,
                .ids = ids,
            };
        }
    }.f;

    var r1 = try build(alloc, 0xAA);
    defer {
        r1.symbols.deinit(alloc);
        alloc.free(r1.scopes);
        alloc.free(r1.refs);
        alloc.free(r1.ids);
    }
    var r2 = try build(alloc, 0x55);
    defer {
        r2.symbols.deinit(alloc);
        alloc.free(r2.scopes);
        alloc.free(r2.refs);
        alloc.free(r2.ids);
    }

    var b1: std.ArrayList(u8) = .empty;
    defer b1.deinit(alloc);
    var b2: std.ArrayList(u8) = .empty;
    defer b2.deinit(alloc);
    try codec.serialize(&r1.sem, &b1, alloc);
    try codec.serialize(&r2.sem, &b2, alloc);

    try testing.expectEqualSlices(u8, b1.items, b2.items);

    // round-trip 의미 복원.
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const rt = try codec.deserialize(b1.items, arena.allocator());
    try testing.expectEqual(@as(usize, 1), rt.symbols.items.len);
    try testing.expectEqual(@as(u32, 5), rt.symbols.items[0].reference_count);
    try testing.expectEqual(@as(?u32, 0), rt.symbol_ids[0]);
    try testing.expectEqual(@as(?u32, null), rt.symbol_ids[1]);
    try testing.expect(rt.references[0].flags.read);
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
