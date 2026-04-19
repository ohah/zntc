//! `Linker.analyzeNamespaceAccess` 유닛 테스트 (#1603 Phase 1a).
//!
//! `import * as X` 형태 namespace 심볼에 대해 AST 수준 멤버 접근 정밀도 분석을 검증.
//! - member-only 패턴에서 접근된 prop 집합이 정확히 추출되는지
//! - 값 전달 / spread / computed access / 재export 등은 opaque로 판정되는지

const std = @import("std");
const Scanner = @import("../lexer/scanner.zig").Scanner;
const Parser = @import("../parser/parser.zig").Parser;
const SemanticAnalyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer;
const Linker = @import("linker.zig").Linker;
const NamespaceAccess = Linker.NamespaceAccess;

/// 소스를 파싱 + semantic 돌린 뒤, `import * as <ns_name>` 의 심볼 id를 찾아
/// `analyzeNamespaceAccess` 결과를 반환한다.
const Harness = struct {
    scanner: Scanner,
    parser: Parser,
    analyzer: SemanticAnalyzer,
    access: NamespaceAccess,

    fn deinit(self: *Harness, allocator: std.mem.Allocator) void {
        self.access.deinit(allocator);
        self.analyzer.deinit();
        self.parser.deinit();
        self.scanner.deinit();
    }
};

fn runAccess(allocator: std.mem.Allocator, source: []const u8, ns_name: []const u8) !Harness {
    var scanner = try Scanner.init(allocator, source);
    errdefer scanner.deinit();
    var parser = Parser.init(allocator, &scanner);
    errdefer parser.deinit();
    _ = try parser.parse();

    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    errdefer analyzer.deinit();
    try analyzer.analyze();

    // import_namespace_specifier는 그 자체가 binding 노드 (data = .{ .string_ref = span }).
    // span text가 ns_name과 일치하는 specifier의 symbol_ids를 찾는다.
    var ns_sym_id: ?u32 = null;
    const ast = &parser.ast;
    for (ast.nodes.items, 0..) |node, i| {
        if (node.tag != .import_namespace_specifier) continue;
        const text = ast.getText(node.span);
        if (!std.mem.eql(u8, text, ns_name)) continue;
        if (i < analyzer.symbol_ids.items.len) {
            if (analyzer.symbol_ids.items[i]) |sid| {
                ns_sym_id = sid;
                break;
            }
        }
    }
    // 찾지 못했으면 analyzer의 symbol 테이블에서 이름으로 검색 (fallback)
    if (ns_sym_id == null) {
        for (analyzer.symbols.items, 0..) |sym, idx| {
            if (std.mem.eql(u8, sym.nameText(source), ns_name)) {
                ns_sym_id = @intCast(idx);
                break;
            }
        }
    }
    const sid = ns_sym_id orelse return error.NamespaceSymbolNotFound;

    const access = try Linker.analyzeNamespaceAccess(allocator, ast, analyzer.symbol_ids.items, sid);
    return .{
        .scanner = scanner,
        .parser = parser,
        .analyzer = analyzer,
        .access = access,
    };
}

fn expectMembers(access: *const NamespaceAccess, expected: []const []const u8) !void {
    try std.testing.expectEqual(NamespaceAccess.Kind.member_only, access.kind);
    try std.testing.expectEqual(expected.len, access.members.count());
    for (expected) |name| {
        try std.testing.expect(access.members.contains(name));
    }
}

test "analyzeNamespaceAccess: 단일 member 접근" {
    var h = try runAccess(std.testing.allocator,
        \\import * as X from './mod';
        \\X.foo();
    , "X");
    defer h.deinit(std.testing.allocator);
    try expectMembers(&h.access, &.{"foo"});
}

test "analyzeNamespaceAccess: 여러 member 접근 + 중복 제거" {
    var h = try runAccess(std.testing.allocator,
        \\import * as X from './mod';
        \\X.foo();
        \\X.bar;
        \\X.foo(1, 2);
        \\const v = X.baz;
    , "X");
    defer h.deinit(std.testing.allocator);
    try expectMembers(&h.access, &.{ "foo", "bar", "baz" });
}

test "analyzeNamespaceAccess: 사용 없으면 빈 member_only" {
    var h = try runAccess(std.testing.allocator,
        \\import * as X from './mod';
        \\const unrelated = 1;
    , "X");
    defer h.deinit(std.testing.allocator);
    try std.testing.expectEqual(NamespaceAccess.Kind.member_only, h.access.kind);
    try std.testing.expectEqual(@as(usize, 0), h.access.members.count());
}

test "analyzeNamespaceAccess: 값으로 전달 → opaque" {
    var h = try runAccess(std.testing.allocator,
        \\import * as X from './mod';
        \\console.log(X);
    , "X");
    defer h.deinit(std.testing.allocator);
    try std.testing.expectEqual(NamespaceAccess.Kind.@"opaque", h.access.kind);
    try std.testing.expectEqual(@as(usize, 0), h.access.members.count());
}

test "analyzeNamespaceAccess: spread → opaque" {
    var h = try runAccess(std.testing.allocator,
        \\import * as X from './mod';
        \\const merged = { ...X };
    , "X");
    defer h.deinit(std.testing.allocator);
    try std.testing.expectEqual(NamespaceAccess.Kind.@"opaque", h.access.kind);
}

test "analyzeNamespaceAccess: computed access (X[key]) → opaque" {
    var h = try runAccess(std.testing.allocator,
        \\import * as X from './mod';
        \\const key = 'foo';
        \\const v = X[key];
    , "X");
    defer h.deinit(std.testing.allocator);
    try std.testing.expectEqual(NamespaceAccess.Kind.@"opaque", h.access.kind);
}

test "analyzeNamespaceAccess: 재-alias 후 사용 → opaque" {
    var h = try runAccess(std.testing.allocator,
        \\import * as X from './mod';
        \\const alias = X;
        \\alias.foo();
    , "X");
    defer h.deinit(std.testing.allocator);
    try std.testing.expectEqual(NamespaceAccess.Kind.@"opaque", h.access.kind);
}

test "analyzeNamespaceAccess: member 접근 + 값 전달 혼합 → opaque" {
    var h = try runAccess(std.testing.allocator,
        \\import * as X from './mod';
        \\X.foo();
        \\console.log(X);
    , "X");
    defer h.deinit(std.testing.allocator);
    try std.testing.expectEqual(NamespaceAccess.Kind.@"opaque", h.access.kind);
}

test "analyzeNamespaceAccess: chained member (X.a.b) — 바깥 X.a만 기록" {
    // `X.a.b()`는 `X.a`로 접근 후 그 결과의 `.b` 호출 — X에 대해선 'a'만 접근.
    var h = try runAccess(std.testing.allocator,
        \\import * as X from './mod';
        \\X.a.b();
    , "X");
    defer h.deinit(std.testing.allocator);
    try expectMembers(&h.access, &.{"a"});
}

test "analyzeNamespaceAccess: 표현식 내 member 접근" {
    var h = try runAccess(std.testing.allocator,
        \\import * as X from './mod';
        \\const arr = [X.a, X.b, X.c];
        \\const result = X.a + X.b;
    , "X");
    defer h.deinit(std.testing.allocator);
    try expectMembers(&h.access, &.{ "a", "b", "c" });
}
