// module_codec_test.zig — #4438 PR4 결합 codec round-trip + fail-safe.
//
// source+AST+semantic 를 한 스트림으로 묶어 같은 arena 에 복원하는 경로를 검증한다.

const std = @import("std");
const testing = std.testing;
const codec = @import("module_codec.zig");
const ast_codec = @import("../parser/ast_codec.zig");
const semantic_codec = @import("semantic_codec.zig");
const ModuleSemanticData = @import("module.zig").ModuleSemanticData;
const Scope = @import("../semantic/scope.zig").Scope;
const Reference = @import("../semantic/symbol.zig").Reference;
const Scanner = @import("../lexer/scanner.zig").Scanner;
const Parser = @import("../parser/parser.zig").Parser;
const SemanticAnalyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer;

const Fixture = struct {
    scanner: Scanner,
    parser: Parser,
    analyzer: SemanticAnalyzer,
    sem: ModuleSemanticData,

    fn deinit(self: *Fixture) void {
        self.analyzer.deinit();
        self.parser.deinit();
        self.scanner.deinit();
    }
};

/// 실제 parse+semantic 을 돌려 직렬화 입력(ast + ModuleSemanticData)을 만든다.
fn analyze(alloc: std.mem.Allocator, fx: *Fixture, source: []const u8) !void {
    fx.scanner = try Scanner.init(alloc, source);
    fx.parser = Parser.init(alloc, &fx.scanner);
    fx.parser.configureForBundler(".mjs"); // 확정 module 모드 — export 추적 활성
    _ = try fx.parser.parse();
    fx.analyzer = SemanticAnalyzer.init(alloc, &fx.parser.ast);
    // 실제 graph 파이프라인(parse_module.zig)과 동일하게 모드 플래그 전파 —
    // is_module 이 꺼져 있으면 export 가 exported_names 에 등록되지 않는다.
    fx.analyzer.is_strict_mode = fx.parser.is_strict_mode;
    fx.analyzer.is_module = fx.parser.is_module;
    fx.analyzer.is_ts = fx.parser.source_mode == .ts;
    fx.analyzer.is_flow = fx.parser.is_flow;
    fx.analyzer.enable_stmt_info = true;
    try fx.analyzer.analyze();
    fx.sem = .{
        .symbols = fx.analyzer.symbols,
        .scopes = fx.analyzer.scopes.items,
        .scope_maps = fx.analyzer.scope_maps.items,
        .exported_names = fx.analyzer.exported_names,
        .symbol_ids = fx.analyzer.symbol_ids.items,
        .unresolved_references = fx.analyzer.unresolved_references,
        .references = fx.analyzer.references.items,
        .numeric_const_texts = fx.analyzer.numeric_const_texts,
        .helper_scope_map = fx.analyzer.helper_scope_map,
    };
}

test "module_codec: source+AST+semantic 결합 round-trip" {
    const alloc = testing.allocator;
    const source = "const a = 1; export function f(x) { let y = x + a; return y; } let z = f(2);";

    var fx: Fixture = undefined;
    try analyze(alloc, &fx, source);
    defer fx.deinit();

    try testing.expect(fx.parser.ast.nodes.items.len > 0);
    try testing.expect(fx.sem.symbols.items.len > 0);
    try testing.expect(fx.sem.scope_maps.len > 0);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try codec.serialize(&fx.parser.ast, &fx.sem, &buf, alloc);

    // 같은 arena 에 ast(source 포함)+semantic 복원 → arena.deinit 일괄 해제.
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const m = try codec.deserialize(buf.items, arena.allocator());

    // source 는 ast.source 로 접근 — 내용 동일(베이스 포인터는 새 arena).
    try testing.expectEqualStrings(source, m.ast.source);

    // AST relocatable 슬라이스 byte 동일.
    try testing.expectEqual(fx.parser.ast.nodes.items.len, m.ast.nodes.items.len);
    try testing.expectEqual(fx.parser.ast.extra_data.items.len, m.ast.extra_data.items.len);
    try testing.expectEqualSlices(u8, fx.parser.ast.string_table.items, m.ast.string_table.items);
    try testing.expectEqual(fx.parser.ast.has_jsx, m.ast.has_jsx);

    // semantic 슬라이스 동일.
    try testing.expectEqual(fx.sem.symbols.items.len, m.semantic.symbols.items.len);
    try testing.expectEqualSlices(Scope, fx.sem.scopes, m.semantic.scopes);
    try testing.expectEqualSlices(?u32, fx.sem.symbol_ids, m.semantic.symbol_ids);
    try testing.expectEqualSlices(Reference, fx.sem.references, m.semantic.references);

    // scope_maps: 맵 개수 + 각 키→심볼인덱스 동일.
    try testing.expectEqual(fx.sem.scope_maps.len, m.semantic.scope_maps.len);
    for (fx.sem.scope_maps, m.semantic.scope_maps) |*m1, *m2| {
        try testing.expectEqual(m1.count(), m2.count());
        var it = m1.iterator();
        while (it.next()) |e| try testing.expectEqual(e.value_ptr.*, m2.get(e.key_ptr.*).?);
    }

    // export 가 있는 source 라 exported_names 비어있지 않음 — 결합 경로에서 비-empty 맵 검증.
    try testing.expect(fx.sem.exported_names.count() > 0);
    try testing.expectEqual(fx.sem.exported_names.count(), m.semantic.exported_names.count());
    try testing.expect(m.semantic.exported_names.contains("f"));

    // symbol name(Span)이 복원된 source 기준으로 여전히 resolve 되는지 — 결합의 핵심 불변식.
    for (fx.sem.symbols.items, m.semantic.symbols.items) |s1, s2| {
        try testing.expectEqualStrings(
            s1.nameText(fx.parser.ast.source),
            s2.nameText(m.ast.source),
        );
    }
}

test "module_codec: 결합 매직/버전/truncated 거부 (fail-safe)" {
    const alloc = testing.allocator;
    const source = "let q = 42;";

    var fx: Fixture = undefined;
    try analyze(alloc, &fx, source);
    defer fx.deinit();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try codec.serialize(&fx.parser.ast, &fx.sem, &buf, alloc);

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    // 정상은 성공.
    _ = try codec.deserialize(buf.items, arena.allocator());

    // 결합 magic / version 변조.
    inline for (.{
        .{ 0, @as(u8, 0xFF), codec.Error.BadMagic },
        .{ 4, @as(u8, 0xEE), codec.Error.UnsupportedVersion },
    }) |tc| {
        const dup = try alloc.dupe(u8, buf.items);
        defer alloc.free(dup);
        dup[tc[0]] ^= tc[1];
        try testing.expectError(tc[2], codec.deserialize(dup, arena.allocator()));
    }

    // 헤더만 남기고 잘라낸 경우 — ast_block 길이 읽기에서 Truncated.
    try testing.expectError(codec.Error.Truncated, codec.deserialize(buf.items[0..8], arena.allocator()));

    // 하위(ast) 블록 내부 변조 → ast_codec checksum 실패가 결합 레이어로 전파.
    // ast_block 은 header(8) + len(4) 다음에 시작하므로 그 안쪽 1바이트를 뒤집는다.
    {
        const dup = try alloc.dupe(u8, buf.items);
        defer alloc.free(dup);
        dup[dup.len - 1] ^= 0xFF; // 마지막 = sem_block 끝(payload) → semantic_codec checksum 실패
        try testing.expectError(codec.Error.ChecksumMismatch, codec.deserialize(dup, arena.allocator()));
    }
}
