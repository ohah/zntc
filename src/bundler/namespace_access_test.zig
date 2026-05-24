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

    const access = try Linker.analyzeNamespaceAccess(allocator, ast, analyzer.symbol_ids.items, sid, null);
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

// #1616: 함수 파라미터/로컬 변수가 namespace 이름을 shadow해도 namespace의 opaque
// 판정을 유발하지 않아야 한다 (scope-aware). Effect 라이브러리의
// `export const sort = dual(2, (self, O) => ... O)` 같은 짧은 alias 패턴이
// 텍스트 매칭 기반 `binding_scanner.collectNamespaceAccesses`에서 false-positive escape로
// 전체 모듈을 포함시켰던 것을 해소하기 위함.
test "analyzeNamespaceAccess: 함수 파라미터 shadowing — namespace 탈출 아님" {
    var h = try runAccess(std.testing.allocator,
        \\import * as X from './mod';
        \\X.foo();
        \\export const fn = (X) => X.bar();
    , "X");
    defer h.deinit(std.testing.allocator);
    // semantic.symbol_ids가 파라미터 X와 namespace X를 다른 심볼로 분리하므로
    // 내부 `X.bar()`는 ns_sym_id 참조로 카운트되지 않음 → top-level `X.foo()`만 수집.
    try expectMembers(&h.access, &.{"foo"});
}

test "analyzeNamespaceAccess: 함수 내부 로컬 변수 shadowing" {
    var h = try runAccess(std.testing.allocator,
        \\import * as X from './mod';
        \\X.foo();
        \\function inner() {
        \\  const X = 42;
        \\  return X + 1;
        \\}
    , "X");
    defer h.deinit(std.testing.allocator);
    try expectMembers(&h.access, &.{"foo"});
}

// ============================================================
// Default-import member 분석 (PR-1 contract).
// `populateNamespaceAccesses` 가 ESM wrapper-barrel default binding 을
// 이 symbol-aware 분석으로 라우팅한다 — wrapper-barrel 정밀 lazy 의
// 입력(소비자 사용 prop / escape 시 opaque)을 제공.
// ============================================================

test "analyzeNamespaceAccess: default import member-only" {
    var h = try runAccess(std.testing.allocator,
        \\import _ from './mod';
        \\_.foo();
        \\_.bar;
    , "_");
    defer h.deinit(std.testing.allocator);
    try expectMembers(&h.access, &.{ "foo", "bar" });
}

test "analyzeNamespaceAccess: default import 값 전달 → opaque" {
    var h = try runAccess(std.testing.allocator,
        \\import _ from './mod';
        \\function sink(o) { return o.bar(); }
        \\_.foo();
        \\sink(_);
    , "_");
    defer h.deinit(std.testing.allocator);
    try std.testing.expectEqual(NamespaceAccess.Kind.@"opaque", h.access.kind);
}

test "analyzeNamespaceAccess: default import computed access → opaque" {
    var h = try runAccess(std.testing.allocator,
        \\import _ from './mod';
        \\const k = globalThis.x ? 'bar' : 'baz';
        \\_.foo();
        \\_[k]();
    , "_");
    defer h.deinit(std.testing.allocator);
    try std.testing.expectEqual(NamespaceAccess.Kind.@"opaque", h.access.kind);
}

// ============================================================
// 옵션 A — text fallback (#3680, effect-ts `counter$4 is not defined` 회귀 방지).
// `analyzeNamespaceAccessWithIndex` 에 `ns_local_name` 을 전달하면
// transformer 가 namespace local 의 `symbol_id` 를 rebind/invalidate 한 경우에도
// text 매칭 fallback 으로 member access 를 정확히 추적.
// ============================================================

fn runAccessWithFallback(
    allocator: std.mem.Allocator,
    source: []const u8,
    ns_name: []const u8,
    /// true 면 ns_sym_id 를 일부러 잘못된 값(존재하지 않는 id) 으로 호출 — symbol_id 매칭은 0 건이지만
    /// text fallback 이 정상 동작하는지 검증.
    use_invalid_sym: bool,
) !struct {
    scanner: Scanner,
    parser: Parser,
    analyzer: SemanticAnalyzer,
    access: NamespaceAccess,

    fn deinit(self: *@This(), a: std.mem.Allocator) void {
        self.access.deinit(a);
        self.analyzer.deinit();
        self.parser.deinit();
        self.scanner.deinit();
    }
} {
    const namespace_access_mod = @import("linker/namespace_access.zig");
    var scanner = try Scanner.init(allocator, source);
    errdefer scanner.deinit();
    var parser = Parser.init(allocator, &scanner);
    errdefer parser.deinit();
    _ = try parser.parse();
    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    errdefer analyzer.deinit();
    try analyzer.analyze();

    var ns_sym_id: u32 = std.math.maxInt(u32);
    if (!use_invalid_sym) {
        const ast = &parser.ast;
        for (ast.nodes.items, 0..) |node, i| {
            if (node.tag != .import_namespace_specifier) continue;
            if (!std.mem.eql(u8, ast.getText(node.span), ns_name)) continue;
            if (i < analyzer.symbol_ids.items.len) {
                if (analyzer.symbol_ids.items[i]) |sid| {
                    ns_sym_id = sid;
                    break;
                }
            }
        }
    }

    var index = try namespace_access_mod.NamespaceAccessIndex.build(allocator, &parser.ast);
    defer index.deinit(allocator);
    const access = try namespace_access_mod.analyzeNamespaceAccessWithIndex(
        allocator,
        &parser.ast,
        analyzer.symbol_ids.items,
        ns_sym_id,
        null,
        &index,
        ns_name,
    );
    return .{ .scanner = scanner, .parser = parser, .analyzer = analyzer, .access = access };
}

test "옵션 A: symbol_id 매칭 정상 + text fallback union (중복 제거)" {
    var h = try runAccessWithFallback(std.testing.allocator,
        \\import * as M from './mod';
        \\M.counter();
        \\M.tagged();
    , "M", false);
    defer h.deinit(std.testing.allocator);
    try expectMembers(&h.access, &.{ "counter", "tagged" });
}

test "옵션 A: symbol_id rebind 시뮬레이션 (invalid sid) — text fallback 만으로 access 복원" {
    var h = try runAccessWithFallback(std.testing.allocator,
        \\import * as M from './mod';
        \\M.counter();
        \\M.histogram();
        \\M.tagged();
    , "M", true);
    defer h.deinit(std.testing.allocator);
    // symbol_id 매칭 0 건 — text fallback 으로 3 개 prop 잡힘.
    try expectMembers(&h.access, &.{ "counter", "histogram", "tagged" });
}

test "옵션 A: symbol matched > 0 면 fallback skip — function param shadow false-positive 방지" {
    // 가장 critical 한 게이팅 검증: symbol_id 매칭이 정확하므로 fallback skip,
    // 함수 파라미터 M 의 inner access (shadow) 는 namespace prop 으로 안 잡힘.
    var h = try runAccessWithFallback(std.testing.allocator,
        \\import * as M from './mod';
        \\M.foo();
        \\export const fn = (M) => M.shadow_only();
    , "M", false);
    defer h.deinit(std.testing.allocator);
    // 정확히 foo 만. shadow_only 가 들어가면 wrapper-barrel lazy 가 회귀.
    try expectMembers(&h.access, &.{"foo"});
}

test "옵션 A: symbol matched > 0 면 fallback skip — block-scope const shadow 방지" {
    var h = try runAccessWithFallback(std.testing.allocator,
        \\import * as M from './mod';
        \\M.counter();
        \\{ const M = { y: 1 }; M.y; }
    , "M", false);
    defer h.deinit(std.testing.allocator);
    try expectMembers(&h.access, &.{"counter"});
}

test "옵션 A: symbol matched = 0 (rebind 시뮬레이션) 일 때만 fallback 활성화" {
    // use_invalid_sym=true → symbol_id 매칭 0건 → fallback 작동.
    var h = try runAccessWithFallback(std.testing.allocator,
        \\import * as M from './mod';
        \\M.counter();
        \\M.histogram();
    , "M", true);
    defer h.deinit(std.testing.allocator);
    try expectMembers(&h.access, &.{ "counter", "histogram" });
}

// F1 fix (PR #3735): text fallback escape 검출 — value-position 사용 시 opaque.
// 옵션 B 의 회귀 case: symbol_matched=0 + escape 동시 발생 시 옛 코드는 member_only 로
// over-prune. 새 코드는 escape 감지해서 opaque 반환 → 모든 export 살림.
test "F1: text fallback escape detection — namespace 가 const init 의 RHS 로 escape 하면 opaque" {
    var h = try runAccessWithFallback(std.testing.allocator,
        \\import * as M from './mod';
        \\const ref = M;
        \\export const x = M.a;
    , "M", true);
    defer h.deinit(std.testing.allocator);
    // escape 감지 → opaque (members 무관)
    try std.testing.expectEqual(NamespaceAccess.Kind.@"opaque", h.access.kind);
}

test "F1: text fallback escape detection — namespace 가 function call argument 로 escape 하면 opaque" {
    var h = try runAccessWithFallback(std.testing.allocator,
        \\import * as M from './mod';
        \\sink(M);
        \\M.x();
    , "M", true);
    defer h.deinit(std.testing.allocator);
    try std.testing.expectEqual(NamespaceAccess.Kind.@"opaque", h.access.kind);
}

test "F1: text fallback escape detection — member-obj only 면 escape 아님 (정상 member_only)" {
    var h = try runAccessWithFallback(std.testing.allocator,
        \\import * as M from './mod';
        \\M.a();
        \\M.b();
    , "M", true);
    defer h.deinit(std.testing.allocator);
    try expectMembers(&h.access, &.{ "a", "b" });
}
