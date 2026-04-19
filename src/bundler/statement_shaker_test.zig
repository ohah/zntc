const std = @import("std");
const statement_shaker = @import("statement_shaker.zig");
const purity = @import("purity.zig");
const markUnusedStatements = statement_shaker.markUnusedStatements;
const Ast = @import("../parser/ast.zig").Ast;
const Node = @import("../parser/ast.zig").Node;
const NodeIndex = @import("../parser/ast.zig").NodeIndex;
const Span = @import("../lexer/token.zig").Span;
const Scanner = @import("../lexer/scanner.zig").Scanner;
const Parser = @import("../parser/parser.zig").Parser;

/// 유닛 테스트는 semantic analyzer 컨텍스트 없이 shaker 동작만 검증한다.
/// 빌트인 pure 생성자 판정은 purity_test.zig가 담당.
const no_globals: ?*const purity.GlobalRefSet = null;

fn parseAndGetRoot(allocator: std.mem.Allocator, source: []const u8) !struct {
    ast: Ast,
    root: NodeIndex,
    arena: std.heap.ArenaAllocator,
} {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const arena_alloc = arena.allocator();

    var scanner = try Scanner.init(arena_alloc, source);
    var parser = Parser.init(arena_alloc, &scanner);
    parser.is_module = true;
    scanner.is_module = true;
    const root = try parser.parse();

    return .{
        .ast = parser.ast,
        .root = root,
        .arena = arena,
    };
}

test "statement shaker: unused function removed" {
    const alloc = std.testing.allocator;
    var r = try parseAndGetRoot(alloc,
        \\function used() { return helper(); }
        \\function helper() { return 1; }
        \\function unused() { return 2; }
    );
    defer r.arena.deinit();

    var skip_nodes = try std.DynamicBitSet.initEmpty(alloc, r.ast.nodes.items.len);
    defer skip_nodes.deinit();

    const used_names: [1][]const u8 = .{"used"};
    try markUnusedStatements(alloc, &r.ast, r.root, &used_names, &skip_nodes, no_globals);

    // "unused" 함수의 statement node가 skip_nodes에 포함되어야 함
    // "used"와 "helper"는 포함되지 않아야 함
    var skipped: u32 = 0;
    var it = skip_nodes.iterator(.{});
    while (it.next()) |_| skipped += 1;
    try std.testing.expect(skipped >= 1); // unused가 최소 1개 스킵됨
}

test "statement shaker: transitive dependency preserved" {
    const alloc = std.testing.allocator;
    var r = try parseAndGetRoot(alloc,
        \\function a() { return b(); }
        \\function b() { return c(); }
        \\function c() { return 42; }
        \\function d() { return 99; }
    );
    defer r.arena.deinit();

    var skip_nodes = try std.DynamicBitSet.initEmpty(alloc, r.ast.nodes.items.len);
    defer skip_nodes.deinit();

    const used_names: [1][]const u8 = .{"a"};
    try markUnusedStatements(alloc, &r.ast, r.root, &used_names, &skip_nodes, no_globals);

    // a → b → c는 보존, d만 제거
    var skipped: u32 = 0;
    var it = skip_nodes.iterator(.{});
    while (it.next()) |_| skipped += 1;
    try std.testing.expect(skipped >= 1); // d가 스킵됨
}

test "statement shaker: side-effectful statement always included" {
    const alloc = std.testing.allocator;
    var r = try parseAndGetRoot(alloc,
        \\function used() { return 1; }
        \\function unused() { return 2; }
        \\console.log("init");
    );
    defer r.arena.deinit();

    var skip_nodes = try std.DynamicBitSet.initEmpty(alloc, r.ast.nodes.items.len);
    defer skip_nodes.deinit();

    const used_names: [1][]const u8 = .{"used"};
    try markUnusedStatements(alloc, &r.ast, r.root, &used_names, &skip_nodes, no_globals);

    // console.log는 side effect → 항상 포함
    // unused만 제거
    var skipped: u32 = 0;
    var it = skip_nodes.iterator(.{});
    while (it.next()) |_| skipped += 1;
    try std.testing.expect(skipped >= 1);
}

test "statement shaker: empty used_exports skips nothing with side effects" {
    const alloc = std.testing.allocator;
    var r = try parseAndGetRoot(alloc,
        \\console.log("side effect");
    );
    defer r.arena.deinit();

    var skip_nodes = try std.DynamicBitSet.initEmpty(alloc, r.ast.nodes.items.len);
    defer skip_nodes.deinit();

    try markUnusedStatements(alloc, &r.ast, r.root, &.{}, &skip_nodes, no_globals);

    // side-effectful statement → 스킵 안 됨
    var skipped: u32 = 0;
    var it = skip_nodes.iterator(.{});
    while (it.next()) |_| skipped += 1;
    try std.testing.expectEqual(@as(u32, 0), skipped);
}

// --- 디버깅 중 발견된 엣지 케이스 ---

test "statement shaker: let without initializer is side-effect-free" {
    // nanostores 패턴: let store; (초기값 없는 변수 선언)
    const alloc = std.testing.allocator;
    var r = try parseAndGetRoot(alloc,
        \\let store;
        \\function used() { store = 1; return store; }
        \\function unused() { return 2; }
    );
    defer r.arena.deinit();

    var skip = try std.DynamicBitSet.initEmpty(alloc, r.ast.nodes.items.len);
    defer skip.deinit();

    const names: [1][]const u8 = .{"used"};
    try markUnusedStatements(alloc, &r.ast, r.root, &names, &skip, no_globals);

    // "let store"는 side-effect-free지만 "used"가 참조 → 보존
    // "unused"만 제거
    var skipped: u32 = 0;
    var it = skip.iterator(.{});
    while (it.next()) |_| skipped += 1;
    try std.testing.expectEqual(@as(u32, 1), skipped);
}

test "statement shaker: const with literal initializer is side-effect-free" {
    // valibot 패턴: const REGEX = /pattern/;
    const alloc = std.testing.allocator;
    var r = try parseAndGetRoot(alloc,
        \\const REGEX = /test/;
        \\function used() { return 1; }
        \\function unused() { return REGEX; }
    );
    defer r.arena.deinit();

    var skip = try std.DynamicBitSet.initEmpty(alloc, r.ast.nodes.items.len);
    defer skip.deinit();

    const names: [1][]const u8 = .{"used"};
    try markUnusedStatements(alloc, &r.ast, r.root, &names, &skip, no_globals);

    // REGEX: 미참조 → 제거, unused: 미참조 → 제거
    var skipped: u32 = 0;
    var it = skip.iterator(.{});
    while (it.next()) |_| skipped += 1;
    try std.testing.expect(skipped >= 2);
}

test "statement shaker: assignment_target_identifier tracked (++x pattern)" {
    // minimatch 패턴: let ID = 0; class AST { id = ++ID; }
    const alloc = std.testing.allocator;
    var r = try parseAndGetRoot(alloc,
        \\let ID = 0;
        \\function make() { return ++ID; }
        \\function unused() { return 99; }
    );
    defer r.arena.deinit();

    var skip = try std.DynamicBitSet.initEmpty(alloc, r.ast.nodes.items.len);
    defer skip.deinit();

    const names: [1][]const u8 = .{"make"};
    try markUnusedStatements(alloc, &r.ast, r.root, &names, &skip, no_globals);

    // make → ++ID → ID 보존. unused만 제거.
    var skipped: u32 = 0;
    var it = skip.iterator(.{});
    while (it.next()) |_| skipped += 1;
    try std.testing.expectEqual(@as(u32, 1), skipped);
}

test "statement shaker: export default function removed when unused" {
    // export default function은 side-effect-free → "default" 미사용 시 제거
    const alloc = std.testing.allocator;
    var r = try parseAndGetRoot(alloc,
        \\export default function config() { return {}; }
        \\function unused() { return 2; }
    );
    defer r.arena.deinit();

    var skip = try std.DynamicBitSet.initEmpty(alloc, r.ast.nodes.items.len);
    defer skip.deinit();

    // used_exports 비어있음 → export default + unused 모두 제거
    try markUnusedStatements(alloc, &r.ast, r.root, &.{}, &skip, no_globals);

    var skipped: u32 = 0;
    var it = skip.iterator(.{});
    while (it.next()) |_| skipped += 1;
    try std.testing.expectEqual(@as(u32, 2), skipped);
}

test "statement shaker: export default preserved when used" {
    // "default"가 used_exports에 있으면 보존
    const alloc = std.testing.allocator;
    var r = try parseAndGetRoot(alloc,
        \\export default function config() { return {}; }
        \\function unused() { return 2; }
    );
    defer r.arena.deinit();

    var skip = try std.DynamicBitSet.initEmpty(alloc, r.ast.nodes.items.len);
    defer skip.deinit();

    const names: [1][]const u8 = .{"default"};
    try markUnusedStatements(alloc, &r.ast, r.root, &names, &skip, no_globals);

    // export default config → 보존, unused만 제거
    var skipped: u32 = 0;
    var it = skip.iterator(.{});
    while (it.next()) |_| skipped += 1;
    try std.testing.expectEqual(@as(u32, 1), skipped);
}

test "statement shaker: export specifier-only is side-effect-free" {
    // valibot 패턴: 함수 선언 후 마지막에 export { ... }
    const alloc = std.testing.allocator;
    var r = try parseAndGetRoot(alloc,
        \\function object() { return 1; }
        \\function unused() { return 2; }
        \\export { object, unused };
    );
    defer r.arena.deinit();

    var skip = try std.DynamicBitSet.initEmpty(alloc, r.ast.nodes.items.len);
    defer skip.deinit();

    const names: [1][]const u8 = .{"object"};
    try markUnusedStatements(alloc, &r.ast, r.root, &names, &skip, no_globals);

    // export { ... } → side-effect-free (linker가 skip_nodes로 처리)
    // unused → 미참조 → 제거
    // export 문 자체도 제거 가능
    var skipped: u32 = 0;
    var it = skip.iterator(.{});
    while (it.next()) |_| skipped += 1;
    try std.testing.expect(skipped >= 1); // unused + export 문
}

test "statement shaker: class extends identifier is removable" {
    // esbuild/rolldown 동일: extends가 순수 식별자이면 side-effect 없음 → 미사용 시 제거
    const alloc = std.testing.allocator;
    var r = try parseAndGetRoot(alloc,
        \\class Derived extends Base {}
        \\function unused() { return 1; }
    );
    defer r.arena.deinit();

    var skip = try std.DynamicBitSet.initEmpty(alloc, r.ast.nodes.items.len);
    defer skip.deinit();

    try markUnusedStatements(alloc, &r.ast, r.root, &.{}, &skip, no_globals);

    // class extends identifier → 순수 → Derived + unused 모두 제거
    var skipped: u32 = 0;
    var it = skip.iterator(.{});
    while (it.next()) |_| skipped += 1;
    try std.testing.expectEqual(@as(u32, 2), skipped);
}

test "statement shaker: class without extends is removable" {
    const alloc = std.testing.allocator;
    var r = try parseAndGetRoot(alloc,
        \\class Used { foo() { return 1; } }
        \\class Unused { bar() { return 2; } }
    );
    defer r.arena.deinit();

    var skip = try std.DynamicBitSet.initEmpty(alloc, r.ast.nodes.items.len);
    defer skip.deinit();

    const names: [1][]const u8 = .{"Used"};
    try markUnusedStatements(alloc, &r.ast, r.root, &names, &skip, no_globals);

    // Unused class (no extends) → 미사용 → 제거
    var skipped: u32 = 0;
    var it = skip.iterator(.{});
    while (it.next()) |_| skipped += 1;
    try std.testing.expect(skipped >= 1);
}

test "statement shaker: var with call initializer is side-effectful" {
    // var x = someFunction(); → side-effectful (함수 호출)
    const alloc = std.testing.allocator;
    var r = try parseAndGetRoot(alloc,
        \\var x = init();
        \\function unused() { return 1; }
    );
    defer r.arena.deinit();

    var skip = try std.DynamicBitSet.initEmpty(alloc, r.ast.nodes.items.len);
    defer skip.deinit();

    try markUnusedStatements(alloc, &r.ast, r.root, &.{}, &skip, no_globals);

    // var x = init() → side-effectful → 보존
    // unused만 제거
    var skipped: u32 = 0;
    var it = skip.iterator(.{});
    while (it.next()) |_| skipped += 1;
    try std.testing.expectEqual(@as(u32, 1), skipped);
}

test "statement shaker: export function declaration" {
    // export function foo() {} → inner function은 side-effect-free
    const alloc = std.testing.allocator;
    var r = try parseAndGetRoot(alloc,
        \\export function used() { return 1; }
        \\export function unused() { return 2; }
    );
    defer r.arena.deinit();

    var skip = try std.DynamicBitSet.initEmpty(alloc, r.ast.nodes.items.len);
    defer skip.deinit();

    const names: [1][]const u8 = .{"used"};
    try markUnusedStatements(alloc, &r.ast, r.root, &names, &skip, no_globals);

    // export function unused → 미사용 → 제거
    var skipped: u32 = 0;
    var it = skip.iterator(.{});
    while (it.next()) |_| skipped += 1;
    try std.testing.expect(skipped >= 1);
}

test "statement shaker: no removable statements → early return" {
    // 모든 statement가 side-effectful → skip 없음
    const alloc = std.testing.allocator;
    var r = try parseAndGetRoot(alloc,
        \\console.log("a");
        \\console.log("b");
    );
    defer r.arena.deinit();

    var skip = try std.DynamicBitSet.initEmpty(alloc, r.ast.nodes.items.len);
    defer skip.deinit();

    try markUnusedStatements(alloc, &r.ast, r.root, &.{}, &skip, no_globals);

    var skipped: u32 = 0;
    var it = skip.iterator(.{});
    while (it.next()) |_| skipped += 1;
    try std.testing.expectEqual(@as(u32, 0), skipped);
}

test "statement shaker: identifier_reference initializer is side-effect-free" {
    // const x = someExistingVar → side-effect-free (identifier reference)
    const alloc = std.testing.allocator;
    var r = try parseAndGetRoot(alloc,
        \\const x = globalVal;
        \\function unused() { return 1; }
    );
    defer r.arena.deinit();

    var skip = try std.DynamicBitSet.initEmpty(alloc, r.ast.nodes.items.len);
    defer skip.deinit();

    try markUnusedStatements(alloc, &r.ast, r.root, &.{}, &skip, no_globals);

    // const x = globalVal → side-effect-free (identifier) → x 미사용 → 제거
    // unused도 미사용 → 제거
    var skipped: u32 = 0;
    var it = skip.iterator(.{});
    while (it.next()) |_| skipped += 1;
    try std.testing.expect(skipped >= 2);
}

test "statement shaker: tslib pattern — export default object removes unused" {
    // tslib 핵심 패턴: export default { __extends, __awaiter, ... }
    // "default" 미사용 시 export default 객체 제거 → 미참조 함수도 제거
    const alloc = std.testing.allocator;
    var r = try parseAndGetRoot(alloc,
        \\function __extends() { return 1; }
        \\function __awaiter() { return 2; }
        \\function __rest() { return 3; }
        \\export default { __extends, __awaiter, __rest };
    );
    defer r.arena.deinit();

    var skip = try std.DynamicBitSet.initEmpty(alloc, r.ast.nodes.items.len);
    defer skip.deinit();

    // __awaiter만 사용 → __extends, __rest, export default 제거
    const names: [1][]const u8 = .{"__awaiter"};
    try markUnusedStatements(alloc, &r.ast, r.root, &names, &skip, no_globals);

    var skipped: u32 = 0;
    var it = skip.iterator(.{});
    while (it.next()) |_| skipped += 1;
    // __extends(1) + __rest(1) + export default(1) = 3개 제거
    try std.testing.expectEqual(@as(u32, 3), skipped);
}

test "statement shaker: conditional init is side-effect-free" {
    // tslib 패턴: var __createBinding = Object.create ? (function(){}) : (function(){})
    const alloc = std.testing.allocator;
    var r = try parseAndGetRoot(alloc,
        \\var __createBinding = Object.create ? function(o) {} : function(o) {};
        \\function used() { return 1; }
    );
    defer r.arena.deinit();

    var skip = try std.DynamicBitSet.initEmpty(alloc, r.ast.nodes.items.len);
    defer skip.deinit();

    const names: [1][]const u8 = .{"used"};
    try markUnusedStatements(alloc, &r.ast, r.root, &names, &skip, no_globals);

    // __createBinding: ternary(member, fn, fn) → side-effect-free → 미사용 → 제거
    var skipped: u32 = 0;
    var it = skip.iterator(.{});
    while (it.next()) |_| skipped += 1;
    try std.testing.expectEqual(@as(u32, 1), skipped);
}

test "statement shaker: typeof binary is side-effect-free" {
    // tslib 패턴: var _Sup = typeof SuppressedError === "function" ? SuppressedError : function() {}
    const alloc = std.testing.allocator;
    var r = try parseAndGetRoot(alloc,
        \\var _Sup = typeof SuppressedError === "function" ? SuppressedError : function() {};
        \\function used() { return 1; }
    );
    defer r.arena.deinit();

    var skip = try std.DynamicBitSet.initEmpty(alloc, r.ast.nodes.items.len);
    defer skip.deinit();

    const names: [1][]const u8 = .{"used"};
    try markUnusedStatements(alloc, &r.ast, r.root, &names, &skip, no_globals);

    // typeof ... === "function" ? ... : ... → side-effect-free → 미사용 → 제거
    var skipped: u32 = 0;
    var it = skip.iterator(.{});
    while (it.next()) |_| skipped += 1;
    try std.testing.expectEqual(@as(u32, 1), skipped);
}

test "statement shaker: export default class extends identifier is removable" {
    // esbuild/rolldown 동일: extends가 순수 식별자이면 side-effect 없음
    const alloc = std.testing.allocator;
    var r = try parseAndGetRoot(alloc,
        \\export default class extends Base {}
        \\function unused() { return 1; }
    );
    defer r.arena.deinit();

    var skip = try std.DynamicBitSet.initEmpty(alloc, r.ast.nodes.items.len);
    defer skip.deinit();

    try markUnusedStatements(alloc, &r.ast, r.root, &.{}, &skip, no_globals);

    // export default class extends Base → 순수 식별자 → 미사용 시 제거 가능
    // 둘 다 제거
    var skipped: u32 = 0;
    var it = skip.iterator(.{});
    while (it.next()) |_| skipped += 1;
    try std.testing.expectEqual(@as(u32, 2), skipped);
}

test "statement shaker: class extends call expression is side-effectful" {
    // extends fn() → side-effect (함수 호출) → 보존
    const alloc = std.testing.allocator;
    var r = try parseAndGetRoot(alloc,
        \\class X extends getBase() {}
        \\function unused() { return 1; }
    );
    defer r.arena.deinit();

    var skip = try std.DynamicBitSet.initEmpty(alloc, r.ast.nodes.items.len);
    defer skip.deinit();

    try markUnusedStatements(alloc, &r.ast, r.root, &.{}, &skip, no_globals);

    // extends getBase() → 불순 → X 보존, unused만 제거
    var skipped: u32 = 0;
    var it = skip.iterator(.{});
    while (it.next()) |_| skipped += 1;
    try std.testing.expectEqual(@as(u32, 1), skipped);
}

test "statement shaker: class extends member expression is removable" {
    // extends a.b → member expression은 순수 (esbuild 동일) → 미사용 시 제거
    const alloc = std.testing.allocator;
    var r = try parseAndGetRoot(alloc,
        \\class X extends ns.Base {}
        \\function unused() { return 1; }
    );
    defer r.arena.deinit();

    var skip = try std.DynamicBitSet.initEmpty(alloc, r.ast.nodes.items.len);
    defer skip.deinit();

    try markUnusedStatements(alloc, &r.ast, r.root, &.{}, &skip, no_globals);

    // extends ns.Base → 순수 member expression → X + unused 모두 제거
    var skipped: u32 = 0;
    var it = skip.iterator(.{});
    while (it.next()) |_| skipped += 1;
    try std.testing.expectEqual(@as(u32, 2), skipped);
}

test "statement shaker: class inheritance chain — unused children removable" {
    // three.js 패턴: Object3D → Light → AmbientLight 상속 체인.
    // AmbientLight가 미사용이면 extends가 있어도 제거되어야 함.
    const alloc = std.testing.allocator;
    var r = try parseAndGetRoot(alloc,
        \\class Base {}
        \\class Child extends Base {}
        \\class Unused extends Base {}
        \\class GrandChild extends Child {}
    );
    defer r.arena.deinit();

    var skip = try std.DynamicBitSet.initEmpty(alloc, r.ast.nodes.items.len);
    defer skip.deinit();

    const names: [1][]const u8 = .{"Child"};
    try markUnusedStatements(alloc, &r.ast, r.root, &names, &skip, no_globals);

    // Child → used, Base → Child의 의존. Unused, GrandChild → 미사용 → 제거
    var skipped: u32 = 0;
    var it = skip.iterator(.{});
    while (it.next()) |_| skipped += 1;
    try std.testing.expectEqual(@as(u32, 2), skipped);
}

test "statement shaker: used class with extends preserves parent" {
    // 사용되는 클래스의 extends 대상(부모)은 의존성으로 보존되어야 함
    const alloc = std.testing.allocator;
    var r = try parseAndGetRoot(alloc,
        \\class Parent {}
        \\class Used extends Parent {}
        \\class Unused extends Parent {}
    );
    defer r.arena.deinit();

    var skip = try std.DynamicBitSet.initEmpty(alloc, r.ast.nodes.items.len);
    defer skip.deinit();

    const names: [1][]const u8 = .{"Used"};
    try markUnusedStatements(alloc, &r.ast, r.root, &names, &skip, no_globals);

    // Parent → Used의 의존으로 보존, Used → used, Unused → 미사용 → 제거
    var skipped: u32 = 0;
    var it = skip.iterator(.{});
    while (it.next()) |_| skipped += 1;
    try std.testing.expectEqual(@as(u32, 1), skipped);
}

test "statement shaker: side-effect on class symbol preserved" {
    // Base.DEFAULT_UP = ... (side-effect) — Base가 used이면 보존되어야 함
    const alloc = std.testing.allocator;
    var r = try parseAndGetRoot(alloc,
        \\class Base {}
        \\Base.DEFAULT_UP = 123;
        \\class Unused extends Base {}
    );
    defer r.arena.deinit();

    var skip = try std.DynamicBitSet.initEmpty(alloc, r.ast.nodes.items.len);
    defer skip.deinit();

    const names: [1][]const u8 = .{"Base"};
    try markUnusedStatements(alloc, &r.ast, r.root, &names, &skip, no_globals);

    // Base → used, Base.DEFAULT_UP → side-effect → 보존, Unused → 미사용 → 제거
    var skipped: u32 = 0;
    var it = skip.iterator(.{});
    while (it.next()) |_| skipped += 1;
    try std.testing.expectEqual(@as(u32, 1), skipped);
}

test "statement shaker: class with static block is side-effectful" {
    const alloc = std.testing.allocator;
    var r = try parseAndGetRoot(alloc,
        \\class X { static { console.log("effect"); } }
        \\function unused() { return 1; }
    );
    defer r.arena.deinit();

    var skip = try std.DynamicBitSet.initEmpty(alloc, r.ast.nodes.items.len);
    defer skip.deinit();

    try markUnusedStatements(alloc, &r.ast, r.root, &.{}, &skip, no_globals);

    // static block → side-effect → X 보존, unused만 제거
    var skipped: u32 = 0;
    var it = skip.iterator(.{});
    while (it.next()) |_| skipped += 1;
    try std.testing.expectEqual(@as(u32, 1), skipped);
}

test "statement shaker: class with computed key call is side-effectful" {
    const alloc = std.testing.allocator;
    var r = try parseAndGetRoot(alloc,
        \\function key() { return "foo"; }
        \\class X { static [key()] = 1; }
        \\function unused() { return 1; }
    );
    defer r.arena.deinit();

    var skip = try std.DynamicBitSet.initEmpty(alloc, r.ast.nodes.items.len);
    defer skip.deinit();

    try markUnusedStatements(alloc, &r.ast, r.root, &.{}, &skip, no_globals);

    // computed key fn() → side-effect → X와 key 보존, unused만 제거
    var skipped: u32 = 0;
    var it = skip.iterator(.{});
    while (it.next()) |_| skipped += 1;
    try std.testing.expectEqual(@as(u32, 1), skipped);
}

test "statement shaker: class with impure static field is side-effectful" {
    const alloc = std.testing.allocator;
    var r = try parseAndGetRoot(alloc,
        \\class X { static foo = init(); }
        \\function unused() { return 1; }
    );
    defer r.arena.deinit();

    var skip = try std.DynamicBitSet.initEmpty(alloc, r.ast.nodes.items.len);
    defer skip.deinit();

    try markUnusedStatements(alloc, &r.ast, r.root, &.{}, &skip, no_globals);

    // static foo = init() → side-effect → X 보존, unused만 제거
    var skipped: u32 = 0;
    var it = skip.iterator(.{});
    while (it.next()) |_| skipped += 1;
    try std.testing.expectEqual(@as(u32, 1), skipped);
}

test "statement shaker: class with pure static field is removable" {
    const alloc = std.testing.allocator;
    var r = try parseAndGetRoot(alloc,
        \\class X { static foo = 42; }
        \\function unused() { return 1; }
    );
    defer r.arena.deinit();

    var skip = try std.DynamicBitSet.initEmpty(alloc, r.ast.nodes.items.len);
    defer skip.deinit();

    try markUnusedStatements(alloc, &r.ast, r.root, &.{}, &skip, no_globals);

    // static foo = 42 → 순수 리터럴 → X + unused 모두 제거
    var skipped: u32 = 0;
    var it = skip.iterator(.{});
    while (it.next()) |_| skipped += 1;
    try std.testing.expectEqual(@as(u32, 2), skipped);
}

test "statement shaker module compiles" {
    _ = @import("statement_shaker.zig");
}
