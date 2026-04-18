const std = @import("std");
const stmt_info = @import("stmt_info.zig");
const ModuleStmtInfos = stmt_info.ModuleStmtInfos;
const build = stmt_info.build;
const Scanner = @import("../lexer/scanner.zig").Scanner;
const Parser = @import("../parser/parser.zig").Parser;
const SemanticAnalyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer;

// ============================================================
// Tests
// ============================================================

fn buildTestInfos(allocator: std.mem.Allocator, source: []const u8) !struct {
    infos: ModuleStmtInfos,
    arena: std.heap.ArenaAllocator,
} {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const arena_alloc = arena.allocator();

    var scanner = try Scanner.init(arena_alloc, source);
    scanner.is_module = true;
    var parser = Parser.init(arena_alloc, &scanner);
    parser.is_module = true;
    _ = try parser.parse();

    var analyzer = SemanticAnalyzer.init(arena_alloc, &parser.ast);
    analyzer.is_module = true;
    try analyzer.analyze();

    const infos = (try build(
        allocator,
        &parser.ast,
        analyzer.symbols.items,
        analyzer.symbol_ids.items,
    )) orelse return error.NullResult;

    return .{ .infos = infos, .arena = arena };
}

test "stmt_info: function declarations" {
    const alloc = std.testing.allocator;
    var r = try buildTestInfos(alloc,
        \\function a() { return b(); }
        \\function b() { return 1; }
        \\function c() { return 2; }
    );
    defer r.infos.deinit();
    defer r.arena.deinit();

    // 3개 함수 선언 → 3개 StmtInfo
    try std.testing.expectEqual(@as(usize, 3), r.infos.stmts.len);
    // 각 statement는 1개 심볼 선언
    try std.testing.expectEqual(@as(usize, 1), r.infos.stmts[0].declared_symbols.len);
    try std.testing.expectEqual(@as(usize, 1), r.infos.stmts[1].declared_symbols.len);
    // a()는 b()를 참조
    try std.testing.expect(r.infos.stmts[0].referenced_symbols.len >= 1);
    // 함수 선언은 side-effect-free
    try std.testing.expect(!r.infos.stmts[0].has_side_effects);
}

test "stmt_info: import binding tracked" {
    const alloc = std.testing.allocator;
    var r = try buildTestInfos(alloc,
        \\import { x } from './mod';
        \\const y = x + 1;
    );
    defer r.infos.deinit();
    defer r.arena.deinit();

    // 2개 문
    try std.testing.expectEqual(@as(usize, 2), r.infos.stmts.len);
    // import → side-effect-free
    try std.testing.expect(!r.infos.stmts[0].has_side_effects);
    // import는 1개 심볼(x) 선언
    try std.testing.expect(r.infos.stmts[0].declared_symbols.len >= 1);
    // const y = x + 1 → x를 참조
    try std.testing.expect(r.infos.stmts[1].referenced_symbols.len >= 1);
}

test "stmt_info: import 선언 stmt 자신은 local 심볼을 referenced로 보고하지 않음 (#1558 Phase 5)" {
    // isImportLiveInModule이 entry import 자체를 "foo 참조"로 오해하지 않아야.
    // import stmt 자신이 foo를 참조한다고 보면 foo는 다른 곳에서 사용 안 돼도
    // always-live로 판정 → 불필요한 모듈 포함.
    const alloc = std.testing.allocator;
    var r = try buildTestInfos(alloc,
        \\import { foo } from './lib';
        \\console.log('no foo usage');
    );
    defer r.infos.deinit();
    defer r.arena.deinit();

    try std.testing.expectEqual(@as(usize, 2), r.infos.stmts.len);

    // import stmt는 foo를 declare하고, referenced_symbols에는 포함하지 않아야.
    const import_stmt = r.infos.stmts[0];
    try std.testing.expect(import_stmt.declared_symbols.len >= 1);
    const foo_sym = import_stmt.declared_symbols[0];

    // import stmt의 referenced_symbols에 foo가 없어야.
    for (import_stmt.referenced_symbols) |ref| {
        try std.testing.expect(ref != foo_sym);
    }
    // sym_to_referencing_stmts[foo]에 import stmt(index 0)가 없어야.
    if (foo_sym < r.infos.sym_to_referencing_stmts.len) {
        for (r.infos.sym_to_referencing_stmts[foo_sym]) |si| {
            try std.testing.expect(si != 0);
        }
    }
}

test "stmt_info: reachability BFS" {
    const alloc = std.testing.allocator;
    var r = try buildTestInfos(alloc,
        \\import { x } from './mod';
        \\function used() { return x; }
        \\function unused() { return 1; }
    );
    defer r.infos.deinit();
    defer r.arena.deinit();

    // used의 심볼 index 가져오기
    const used_sym = r.infos.stmts[1].declared_symbols[0];

    var reachable = try r.infos.computeReachable(alloc, &.{used_sym});
    defer reachable.deinit();

    // stmt 0 (import) → side-effect-free, x만 선언
    // stmt 1 (used) → seed, x 참조 → stmt 0 도달
    // stmt 2 (unused) → 미도달
    try std.testing.expect(reachable.isSet(0)); // import (used가 x 참조)
    try std.testing.expect(reachable.isSet(1)); // used (seed)
    try std.testing.expect(!reachable.isSet(2)); // unused (미도달)
}

test "stmt_info: unused import not reachable" {
    const alloc = std.testing.allocator;
    var r = try buildTestInfos(alloc,
        \\import { x } from './a';
        \\import { y } from './b';
        \\function used() { return x; }
    );
    defer r.infos.deinit();
    defer r.arena.deinit();

    const used_sym = r.infos.stmts[2].declared_symbols[0];

    var reachable = try r.infos.computeReachable(alloc, &.{used_sym});
    defer reachable.deinit();

    // used → x 참조 → import x 도달
    // import y → 미참조 → 미도달
    try std.testing.expect(reachable.isSet(0)); // import x
    try std.testing.expect(!reachable.isSet(1)); // import y (unused)
    try std.testing.expect(reachable.isSet(2)); // used
}

test "stmt_info: arrow function body references tracked" {
    // arktype flatMorph 패턴: import 심볼이 arrow function body에서 참조됨
    const alloc = std.testing.allocator;
    var r = try buildTestInfos(alloc,
        \\import { x } from './mod';
        \\export const fn1 = (a) => x + a;
        \\export const fn2 = () => 1;
    );
    defer r.infos.deinit();
    defer r.arena.deinit();

    // fn1은 x를 참조해야 함
    const fn1_stmt = r.infos.stmts[1];
    var has_x_ref = false;
    for (fn1_stmt.referenced_symbols) |sym| {
        // x의 심볼 인덱스와 매칭되는지
        if (r.infos.stmts[0].declared_symbols.len > 0) {
            if (sym == r.infos.stmts[0].declared_symbols[0]) {
                has_x_ref = true;
            }
        }
    }
    try std.testing.expect(has_x_ref); // fn1은 x를 참조

    // fn1을 seed로 BFS → import x도 reachable
    const fn1_sym = fn1_stmt.declared_symbols[0];
    var reachable = try r.infos.computeReachable(alloc, &.{fn1_sym});
    defer reachable.deinit();

    try std.testing.expect(reachable.isSet(0)); // import x (fn1이 참조)
    try std.testing.expect(reachable.isSet(1)); // fn1 (seed)
    try std.testing.expect(!reachable.isSet(2)); // fn2 (미도달)
}

test "stmt_info: multi-statement module with arrow closures (arktype pattern)" {
    // arktype records.js 패턴: 22개 statement, import가 arrow body에서 참조
    const alloc = std.testing.allocator;
    var r = try buildTestInfos(alloc,
        \\import { noSuggest } from './errors';
        \\import { flatMorph } from './flatMorph';
        \\export const entriesOf = Object.entries;
        \\export const fromEntries = (entries) => Object.fromEntries(entries);
        \\export const keysOf = (o) => Object.keys(o);
        \\export const isKeyOf = (k, o) => k in o;
        \\export const hasKey = (o, k) => k in o;
        \\export const hasDefinedKey = (o, k) => o[k] !== undefined;
        \\export const splitByKeys = (o, leftKeys) => {
        \\    const l = {};
        \\    const r = {};
        \\    let k;
        \\    for (k in o) {
        \\        if (k in leftKeys) l[k] = o[k];
        \\        else r[k] = o[k];
        \\    }
        \\    return [l, r];
        \\};
        \\export const invert = (t) => flatMorph(t, (k, v) => [v, k]);
    );
    defer r.infos.deinit();
    defer r.arena.deinit();

    // "invert" statement가 flatMorph를 참조하는지 확인
    // flatMorph는 stmt 1 (import)에서 선언
    const flatMorph_sym = r.infos.stmts[1].declared_symbols[0];

    // invert는 마지막 statement
    const last_stmt = r.infos.stmts[r.infos.stmts.len - 1];
    var has_ref = false;
    for (last_stmt.referenced_symbols) |sym| {
        if (sym == flatMorph_sym) has_ref = true;
    }
    try std.testing.expect(has_ref); // invert는 flatMorph를 참조해야 함

    // invert를 seed로 BFS → flatMorph import도 reachable
    if (last_stmt.declared_symbols.len > 0) {
        var reachable = try r.infos.computeReachable(alloc, &.{last_stmt.declared_symbols[0]});
        defer reachable.deinit();
        try std.testing.expect(reachable.isSet(1)); // flatMorph import reachable
    }
}
