// cache_key_test.zig — #4438 무효화 키 결정성/민감도 + 보수↔정밀 차등 테스트.
//
// 실제 parse+semantic 을 옵션/모드 매트릭스로 돌려 키가 결과를 올바르게 추적하는지,
// 그리고 보수(전체 옵션)와 정밀(선별) 두 전략의 trade-off 를 구체적으로 검증한다.

const std = @import("std");
const testing = std.testing;
const cache_key = @import("cache_key.zig");
const module_codec = @import("module_codec.zig");
const ModuleSemanticData = @import("module.zig").ModuleSemanticData;
const wyhash = @import("../util/wyhash.zig");
const Scanner = @import("../lexer/scanner.zig").Scanner;
const Parser = @import("../parser/parser.zig").Parser;
const SemanticAnalyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer;

const BUILD_ID: u64 = 0xABCD_1234; // 테스트 고정 compiler_build_id

// import/export 가 없어 .mjs/.ts/.tsx/.cjs 모두에서 유효하게 파싱되는 source.
const SRC = "const a = 1; function f(x) { let y = x + a; return y; } const b = f(2);";

const Parsed = struct {
    bytes: []u8, // module_codec 직렬화 결과 (caller free)
    flags: cache_key.ParseFlags,
};

/// 주어진 확장자로 parse+semantic 을 돌려 module_codec 직렬화 바이트 + ParseFlags 반환.
/// 실제 graph 파이프라인(parse_module.zig)과 동일하게 모드 플래그를 전파한다.
fn parseAndSerialize(alloc: std.mem.Allocator, ext: []const u8, source: []const u8) !Parsed {
    var scanner = try Scanner.init(alloc, source);
    defer scanner.deinit();
    var parser = Parser.init(alloc, &scanner);
    defer parser.deinit();
    parser.configureForBundler(ext);
    _ = try parser.parse();

    var ana = SemanticAnalyzer.init(alloc, &parser.ast);
    defer ana.deinit();
    ana.is_strict_mode = parser.is_strict_mode;
    ana.is_module = parser.is_module;
    ana.is_ts = parser.source_mode == .ts;
    ana.is_flow = parser.is_flow;
    ana.enable_stmt_info = true;
    try ana.analyze();

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
    errdefer buf.deinit(alloc);
    try module_codec.serialize(&parser.ast, &sem, &buf, alloc);

    return .{
        .bytes = try buf.toOwnedSlice(alloc),
        .flags = .{
            .is_ts = parser.source_mode == .ts,
            .is_jsx = parser.is_jsx,
            .is_module = parser.is_module,
            .is_flow = parser.is_flow,
            .is_strict = parser.is_strict_mode,
        },
    };
}

fn keyFor(flags: cache_key.ParseFlags, opts: *const cache_key.SelectiveOptions) u64 {
    return cache_key.compute(wyhash.hashU64(SRC), flags, cache_key.hashSelective(opts), BUILD_ID);
}

test "cache_key: compute 결정성 + 입력별 민감도" {
    const sh = wyhash.hashU64(SRC);
    const flags = cache_key.ParseFlags{ .is_ts = true, .is_module = true };
    const base = cache_key.compute(sh, flags, 0x1111, BUILD_ID);

    try testing.expectEqual(base, cache_key.compute(sh, flags, 0x1111, BUILD_ID)); // 결정적
    try testing.expect(base != cache_key.compute(sh +% 1, flags, 0x1111, BUILD_ID)); // source
    try testing.expect(base != cache_key.compute(sh, .{ .is_jsx = true, .is_ts = true, .is_module = true }, 0x1111, BUILD_ID)); // flags
    try testing.expect(base != cache_key.compute(sh, flags, 0x2222, BUILD_ID)); // options
    try testing.expect(base != cache_key.compute(sh, flags, 0x1111, BUILD_ID +% 1)); // build id
}

test "cache_key: is_ambient 가 키에 반영 (#4438 .d.ts↔.ts 충돌 가드)" {
    const sh = wyhash.hashU64(SRC);
    // byte-identical source + 동일 나머지 플래그라도 ambient 여부가 다르면 키가 달라야
    // 한다(.d.ts ambient AST 가 byte-identical .ts non-ambient 에 stale 재사용되는 것 방지).
    const non_ambient = cache_key.ParseFlags{ .is_ts = true, .is_module = true };
    const ambient = cache_key.ParseFlags{ .is_ts = true, .is_module = true, .is_ambient = true };
    try testing.expect(cache_key.compute(sh, non_ambient, 0x1111, BUILD_ID) !=
        cache_key.compute(sh, ambient, 0x1111, BUILD_ID));
}

test "cache_key: parseFlagsFromParser 가 ambient 상태를 캡처 (#4438 wiring)" {
    const alloc = testing.allocator;
    // .d.ts → configureAmbientFromPath 가 ctx.in_ambient=true → ParseFlags.is_ambient=true.
    var scanner = try Scanner.init(alloc, SRC);
    defer scanner.deinit();
    var parser = Parser.init(alloc, &scanner);
    defer parser.deinit();
    parser.configureForBundler(".ts");
    parser.configureAmbientFromPath("foo.d.ts");
    try testing.expect(cache_key.parseFlagsFromParser(&parser).is_ambient);

    // .ts → ambient 아님.
    var scanner2 = try Scanner.init(alloc, SRC);
    defer scanner2.deinit();
    var parser2 = Parser.init(alloc, &scanner2);
    defer parser2.deinit();
    parser2.configureForBundler(".ts");
    parser2.configureAmbientFromPath("foo.ts");
    try testing.expect(!cache_key.parseFlagsFromParser(&parser2).is_ambient);
}

test "cache_key: hashSelective 가 모든 필드를 반영 (reflection 완전성)" {
    const base = cache_key.SelectiveOptions{};
    const base_h = cache_key.hashSelective(&base);
    // 모든 필드를 하나씩 변형 → 해시가 바뀌어야(어떤 필드도 무시되지 않음).
    inline for (@typeInfo(cache_key.SelectiveOptions).@"struct".fields) |f| {
        var o = base;
        switch (@typeInfo(f.type)) {
            .bool => @field(o, f.name) = !@field(base, f.name),
            .int => @field(o, f.name) = @field(base, f.name) +% 1,
            else => unreachable, // SelectiveOptions 는 단순 타입만(컴파일 가드)
        }
        try testing.expect(cache_key.hashSelective(&o) != base_h);
    }
}

test "차등: parser flags 가 결과를 바꾸면 키도 바뀐다 (민감도)" {
    const alloc = testing.allocator;
    const opts = cache_key.SelectiveOptions{};

    // 결정성: 같은 (ext, source) 두 번 → byte 동일 + 키 동일.
    const m1 = try parseAndSerialize(alloc, ".mjs", SRC);
    defer alloc.free(m1.bytes);
    const m2 = try parseAndSerialize(alloc, ".mjs", SRC);
    defer alloc.free(m2.bytes);
    try testing.expectEqualSlices(u8, m1.bytes, m2.bytes);
    try testing.expectEqual(keyFor(m1.flags, &opts), keyFor(m2.flags, &opts));

    // 모드별 ParseFlags 가 달라 키가 pairwise 구분되는지.
    const ts = try parseAndSerialize(alloc, ".ts", SRC);
    defer alloc.free(ts.bytes);
    const tsx = try parseAndSerialize(alloc, ".tsx", SRC);
    defer alloc.free(tsx.bytes);
    const cjs = try parseAndSerialize(alloc, ".cjs", SRC);
    defer alloc.free(cjs.bytes);

    const keys = [_]u64{
        keyFor(m1.flags, &opts), // .mjs : module, !ts, !jsx
        keyFor(ts.flags, &opts), // .ts  : module, ts, !jsx
        keyFor(tsx.flags, &opts), // .tsx : module, ts, jsx
        keyFor(cjs.flags, &opts), // .cjs : !module
    };
    for (keys, 0..) |ka, i| {
        for (keys[i + 1 ..]) |kb| try testing.expect(ka != kb); // 모든 모드 키 구별
    }

    // 모드 플래그가 실제로 다른지(테스트 전제 보장).
    try testing.expect(ts.flags.is_ts and !m1.flags.is_ts);
    try testing.expect(tsx.flags.is_jsx and !ts.flags.is_jsx);
    try testing.expect(!cjs.flags.is_module and m1.flags.is_module);
}

test "차등: 보수↔정밀 trade-off — compute 의 options_hash 메커니즘" {
    const alloc = testing.allocator;

    // 주의(범위 정직화): 이 테스트는 키 조립 **메커니즘**만 검증한다 — `parseAndSerialize` 는
    // 옵션을 입력으로 받지 않으므로, emit-only 옵션이 실제 parse 출력을 바꾸는지/안 바꾸는지는
    // 여기서 입증하지 못한다(pre-transform 에서는 parse 가 옵션을 안 읽어 구조상 자명, post-
    // transform 안전성은 graph 통합의 ON==OFF byte-identical 동등성 테스트의 몫). 아래 byte
    // 동등성은 "옵션 무관"이 아니라 동일 입력의 **결정성**이다.
    const m = try parseAndSerialize(alloc, ".mjs", SRC);
    defer alloc.free(m.bytes);
    const m_again = try parseAndSerialize(alloc, ".mjs", SRC);
    defer alloc.free(m_again.bytes);
    try testing.expectEqualSlices(u8, m.bytes, m_again.bytes); // 결정성

    const sh = wyhash.hashU64(SRC);

    // 정밀: 같은 SelectiveOptions → 같은 options_hash → 같은 키(emit-only 차이는 키에 안 들어옴).
    const sel = cache_key.SelectiveOptions{ .jsx_transform = true, .define_hash = 0xDEF };
    const sel_a = cache_key.compute(sh, m.flags, cache_key.hashSelective(&sel), BUILD_ID);
    const sel_b = cache_key.compute(sh, m.flags, cache_key.hashSelective(&sel), BUILD_ID);
    try testing.expectEqual(sel_a, sel_b);

    // 보수: options_hash 가 달라지면 키도 달라짐(compute 의 options_hash 민감도). 실제 보수 해시
    // (hashEmitOptions)는 graph PR 이 주입하며, 여기선 stand-in 상수로 민감도만 검증한다.
    try testing.expect(cache_key.compute(sh, m.flags, 0xE1770_0A, BUILD_ID) !=
        cache_key.compute(sh, m.flags, 0xE1770_0B, BUILD_ID));

    // 정밀: parse-영향 옵션이 실제로 다르면 키도 달라야(SelectiveOptions 필드가 키에 반영됨).
    const sel2 = cache_key.SelectiveOptions{ .jsx_transform = true, .define_hash = 0xFED };
    try testing.expect(sel_a != cache_key.compute(sh, m.flags, cache_key.hashSelective(&sel2), BUILD_ID));
}
