// disk_module_store_test.zig — #4438 디스크 모듈 store/load round-trip + miss + 손상 fail-safe.
//
// 실제 parse+semantic 을 만들어 디스크에 저장하고, 새 arena 로 복원해 동등성을 검증한다.

const std = @import("std");
const testing = std.testing;
const DiskModuleStore = @import("disk_module_store.zig").DiskModuleStore;
const ModuleSemanticData = @import("module.zig").ModuleSemanticData;
const Scope = @import("../semantic/scope.zig").Scope;
const Reference = @import("../semantic/symbol.zig").Reference;
const Scanner = @import("../lexer/scanner.zig").Scanner;
const Parser = @import("../parser/parser.zig").Parser;
const SemanticAnalyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer;

const KEY: u64 = 0xC0FFEE_1234_5678;
const SRC = "const a = 1; export function f(x) { let y = x + a; return y; } const b = f(2);";

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

fn analyze(alloc: std.mem.Allocator, fx: *Fixture, source: []const u8) !void {
    fx.scanner = try Scanner.init(alloc, source);
    fx.parser = Parser.init(alloc, &fx.scanner);
    fx.parser.configureForBundler(".mjs");
    _ = try fx.parser.parse();
    fx.analyzer = SemanticAnalyzer.init(alloc, &fx.parser.ast);
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

fn openStore(tmp: *std.testing.TmpDir) !DiskModuleStore {
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);
    return DiskModuleStore.init(testing.allocator, root);
}

test "disk_module_store: store→load round-trip (새 arena 복원)" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try openStore(&tmp);
    defer store.deinit();

    var fx: Fixture = undefined;
    try analyze(alloc, &fx, SRC);
    defer fx.deinit();

    try store.store(testing.io, alloc, KEY, &fx.parser.ast, &fx.sem);

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const m = (try store.load(testing.io, alloc, arena.allocator(), KEY)).?;

    // source + AST + semantic 동등성.
    try testing.expectEqualStrings(SRC, m.ast.source);
    try testing.expectEqual(fx.parser.ast.nodes.items.len, m.ast.nodes.items.len);
    try testing.expectEqual(fx.sem.symbols.items.len, m.semantic.symbols.items.len);
    try testing.expectEqualSlices(Scope, fx.sem.scopes, m.semantic.scopes);
    try testing.expectEqualSlices(Reference, fx.sem.references, m.semantic.references);
    try testing.expect(m.semantic.exported_names.contains("f"));

    // symbol name(Span)이 복원된 source 기준으로 resolve 되는지.
    for (fx.sem.symbols.items, m.semantic.symbols.items) |s1, s2| {
        try testing.expectEqualStrings(s1.nameText(fx.parser.ast.source), s2.nameText(m.ast.source));
    }
}

test "disk_module_store: miss 는 null" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try openStore(&tmp);
    defer store.deinit();

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    try testing.expect((try store.load(testing.io, alloc, arena.allocator(), KEY)) == null);
}

test "disk_module_store: 손상 캐시는 miss 로 degrade (fail-safe)" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", alloc);
    defer alloc.free(root);
    var store = try DiskModuleStore.init(alloc, root);
    defer store.deinit();

    var fx: Fixture = undefined;
    try analyze(alloc, &fx, SRC);
    defer fx.deinit();
    try store.store(testing.io, alloc, KEY, &fx.parser.ast, &fx.sem);

    // 캐시 파일(root/<ab>/<cdef…>)을 짧은 garbage 로 덮어써 손상 → load 는 hard error 가 아니라
    // null(재파싱). codec 의 magic/checksum/truncated 검증이 잘못된 캐시를 거른다.
    var hex: [16]u8 = undefined;
    _ = std.fmt.bufPrint(&hex, "{x:0>16}", .{KEY}) catch unreachable;
    const path = try std.fs.path.join(alloc, &.{ root, hex[0..2], hex[2..16] });
    defer alloc.free(path);
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = path, .data = "xx" }); // < HEADER_LEN

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    try testing.expect((try store.load(testing.io, alloc, arena.allocator(), KEY)) == null);
}
