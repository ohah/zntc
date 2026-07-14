//! purity.zig 유닛 테스트.
//!
//! 핵심 검증:
//!   - 빌트인 pure 생성자 화이트리스트(`new Set()` 등)는 unresolved_globals 컨텍스트에서
//!     순수로 판정되어야 한다.
//!   - 로컬 바인딩으로 shadowed된 이름(`const Set = ...; new Set()`)은 unresolved에
//!     등록되지 않으므로 불순으로 남아야 한다.
//!   - null 컨텍스트에서는 기존 동작(모든 call/new 불순)이 유지되어야 한다 (#1567).

const std = @import("std");
const purity = @import("purity.zig");
const Ast = @import("../parser/ast.zig").Ast;
const Node = @import("../parser/ast.zig").Node;
const NodeIndex = @import("../parser/ast.zig").NodeIndex;
const NodeTag = @import("../parser/ast.zig").Node.Tag;
const Scanner = @import("../lexer/scanner.zig").Scanner;
const Parser = @import("../parser/parser.zig").Parser;
const SemanticAnalyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer;

const TestCtx = struct {
    arena: std.heap.ArenaAllocator,
    ast: Ast,
    root: NodeIndex,
    analyzer: SemanticAnalyzer,

    fn deinit(self: *TestCtx) void {
        self.arena.deinit();
    }
};

fn setup(allocator: std.mem.Allocator, source: []const u8) !TestCtx {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();

    var scanner = try Scanner.init(a, source);
    scanner.is_module = true;
    var parser = Parser.init(a, &scanner);
    parser.is_module = true;
    const root = try parser.parse();

    var analyzer = SemanticAnalyzer.init(a, &parser.ast);
    analyzer.is_module = true;
    try analyzer.analyze();

    return .{
        .arena = arena,
        .ast = parser.ast,
        .root = root,
        .analyzer = analyzer,
    };
}

fn topLevelStmt(ctx: *const TestCtx, stmt_idx: usize) Node {
    const root_ni = @intFromEnum(ctx.root);
    const root_node = ctx.ast.nodes.items[root_ni];
    const stmts = root_node.data.list;
    const raw_stmt: u32 = ctx.ast.extra_data.items[stmts.start + stmt_idx];
    return ctx.ast.nodes.items[raw_stmt];
}

/// program의 `stmt_idx`번째 top-level statement가 variable_declaration일 때
/// 그 첫 declarator의 initializer NodeIndex를 반환한다.
fn initOfDecl(ctx: *const TestCtx, stmt_idx: usize) NodeIndex {
    const stmt = topLevelStmt(ctx, stmt_idx);
    // variable_declaration: [kind(0), list_start(1), list_len(2)]
    const list_start = ctx.ast.extra_data.items[stmt.data.extra + 1];
    const raw_decl: u32 = ctx.ast.extra_data.items[list_start];
    const decl = ctx.ast.nodes.items[raw_decl];
    // variable_declarator extra: [pattern(0), type_ann(1), init(2)]
    return @enumFromInt(ctx.ast.extra_data.items[decl.data.extra + 2]);
}

test "pure builtin: new Set() with unresolved globals is pure" {
    const alloc = std.testing.allocator;
    var ctx = try setup(alloc, "const s = new Set();");
    defer ctx.deinit();

    const init = initOfDecl(&ctx, 0);
    // context 없음 → 기존 동작 유지: call/new는 @__PURE__ 없으면 불순.
    try std.testing.expect(!purity.isExprPure(&ctx.ast, init, null));
    // 컨텍스트 전달 시 순수로 승격.
    try std.testing.expect(purity.isExprPure(&ctx.ast, init, &ctx.analyzer.unresolved_references));
}

test "class expression: pure body is removable (#1665)" {
    const alloc = std.testing.allocator;
    var ctx = try setup(alloc,
        \\const C = class {
        \\  value() { return 1; }
        \\  static tag = "pure";
        \\};
    );
    defer ctx.deinit();

    const init = initOfDecl(&ctx, 0);
    try std.testing.expect(purity.isExprPure(&ctx.ast, init, &ctx.analyzer.unresolved_references));
}

test "class expression: impure static members are preserved (#1665)" {
    const alloc = std.testing.allocator;
    var ctx = try setup(alloc,
        \\const C = class {
        \\  static tag = init();
        \\};
    );
    defer ctx.deinit();

    const init = initOfDecl(&ctx, 0);
    try std.testing.expect(!purity.isExprPure(&ctx.ast, init, &ctx.analyzer.unresolved_references));
}

test "pure builtin: whitelist covers Map/WeakMap/WeakSet/Array/Object/Date/Error" {
    // `new Symbol()` 은 ECMAScript 명세상 TypeError throw → pure 아님 (아래 별도 테스트).
    const alloc = std.testing.allocator;
    const src =
        \\const a = new Map();
        \\const b = new WeakMap();
        \\const c = new WeakSet();
        \\const e = new Array(4);
        \\const f = new Object();
        \\const g = new Date();
        \\const h = new Error("x");
    ;
    var ctx = try setup(alloc, src);
    defer ctx.deinit();

    const globals = &ctx.analyzer.unresolved_references;
    for (0..7) |i| {
        const init = initOfDecl(&ctx, i);
        try std.testing.expect(purity.isExprPure(&ctx.ast, init, globals));
    }
}

test "pure builtin: RegExp is NOT whitelisted (invalid pattern throws)" {
    const alloc = std.testing.allocator;
    var ctx = try setup(alloc, "const r = new RegExp(\"x\");");
    defer ctx.deinit();

    const init = initOfDecl(&ctx, 0);
    try std.testing.expect(!purity.isExprPure(&ctx.ast, init, &ctx.analyzer.unresolved_references));
}

test "pure builtin: shadowed Set is impure" {
    const alloc = std.testing.allocator;
    // 로컬 `Set` 선언이 있으면 unresolved_references에 `Set`이 없으므로
    // 화이트리스트 판정이 실패해야 한다.
    const src =
        \\const Set = globalThis.X;
        \\const s = new Set();
    ;
    var ctx = try setup(alloc, src);
    defer ctx.deinit();

    const init = initOfDecl(&ctx, 1);
    try std.testing.expect(!purity.isExprPure(&ctx.ast, init, &ctx.analyzer.unresolved_references));
}

test "pure builtin: impure arg makes the whole call impure" {
    const alloc = std.testing.allocator;
    const src = "const s = new Set([sideEffect()]);";
    var ctx = try setup(alloc, src);
    defer ctx.deinit();

    const init = initOfDecl(&ctx, 0);
    try std.testing.expect(!purity.isExprPure(&ctx.ast, init, &ctx.analyzer.unresolved_references));
}

test "pure builtin: pure array arg keeps call pure" {
    const alloc = std.testing.allocator;
    const src = "const s = new Set([1, 2, 3]);";
    var ctx = try setup(alloc, src);
    defer ctx.deinit();

    const init = initOfDecl(&ctx, 0);
    try std.testing.expect(purity.isExprPure(&ctx.ast, init, &ctx.analyzer.unresolved_references));
}

test "pure builtin: stmt-level classification for `const s = new Set();`" {
    const alloc = std.testing.allocator;
    var ctx = try setup(alloc, "const s = new Set();");
    defer ctx.deinit();

    const root_ni = @intFromEnum(ctx.root);
    const root_node = ctx.ast.nodes.items[root_ni];
    const stmts = root_node.data.list;
    const raw_stmt: u32 = ctx.ast.extra_data.items[stmts.start];
    const stmt_node = ctx.ast.nodes.items[raw_stmt];

    // null 컨텍스트에서는 side-effectful로 남아야 기존 동작 유지
    try std.testing.expect(purity.stmtHasSideEffects(&ctx.ast, stmt_node, null));
    // 컨텍스트 전달 시 순수 statement로 판정
    try std.testing.expect(!purity.stmtHasSideEffects(&ctx.ast, stmt_node, &ctx.analyzer.unresolved_references));
}

test "assignment statement: module-local assignment target identifier is removable when RHS is pure" {
    const alloc = std.testing.allocator;
    const src =
        \\let Local;
        \\Local = 1;
        \\if (typeof HTMLElement === 'function') {
        \\  Local = class extends HTMLElement {};
        \\}
    ;
    var ctx = try setup(alloc, src);
    defer ctx.deinit();

    const globals = &ctx.analyzer.unresolved_references;
    try std.testing.expect(!purity.stmtHasSideEffects(&ctx.ast, topLevelStmt(&ctx, 1), globals));
    try std.testing.expect(!purity.stmtHasSideEffects(&ctx.ast, topLevelStmt(&ctx, 2), globals));
}

test "assignment statement: global, member, computed, and destructuring LHS stay side-effectful" {
    const alloc = std.testing.allocator;
    const src =
        \\x = 1;
        \\obj.x = 1;
        \\obj[key] = 1;
        \\[x] = [1];
    ;
    var ctx = try setup(alloc, src);
    defer ctx.deinit();

    const globals = &ctx.analyzer.unresolved_references;
    for (0..4) |i| {
        try std.testing.expect(purity.stmtHasSideEffects(&ctx.ast, topLevelStmt(&ctx, i), globals));
    }
}

test "pure builtin: call without `new` also pure (Symbol(), Array(3))" {
    const alloc = std.testing.allocator;
    const src =
        \\const a = Symbol();
        \\const b = Array(3);
    ;
    var ctx = try setup(alloc, src);
    defer ctx.deinit();

    const g = &ctx.analyzer.unresolved_references;
    try std.testing.expect(purity.isExprPure(&ctx.ast, initOfDecl(&ctx, 0), g));
    try std.testing.expect(purity.isExprPure(&ctx.ast, initOfDecl(&ctx, 1), g));
}

test "pure builtin: spread arg blocks pure classification" {
    const alloc = std.testing.allocator;
    const src = "const s = new Set(...xs);";
    var ctx = try setup(alloc, src);
    defer ctx.deinit();

    const init = initOfDecl(&ctx, 0);
    try std.testing.expect(!purity.isExprPure(&ctx.ast, init, &ctx.analyzer.unresolved_references));
}

test "object literal: pure computed key and pure value are pure" {
    const alloc = std.testing.allocator;
    const src =
        \\const key = Symbol();
        \\const value = 1;
        \\const obj = { [key]: value };
    ;
    var ctx = try setup(alloc, src);
    defer ctx.deinit();

    try expectPure(&ctx, 2, true);
}

test "object literal: impure computed key is impure" {
    const alloc = std.testing.allocator;
    const src =
        \\const obj = { [sideEffect()]: 1 };
    ;
    var ctx = try setup(alloc, src);
    defer ctx.deinit();

    try expectPure(&ctx, 0, false);
}

test "object literal: impure value with pure computed key is impure" {
    const alloc = std.testing.allocator;
    const src =
        \\const key = Symbol();
        \\const obj = { [key]: sideEffect() };
    ;
    var ctx = try setup(alloc, src);
    defer ctx.deinit();

    try expectPure(&ctx, 1, false);
}

test "object literal: spread element is impure" {
    const alloc = std.testing.allocator;
    const src =
        \\const obj = { ...source };
    ;
    var ctx = try setup(alloc, src);
    defer ctx.deinit();

    try expectPure(&ctx, 0, false);
}

test "object literal: method with impure computed key is impure" {
    const alloc = std.testing.allocator;
    const src =
        \\const obj = { [sideEffect()]() { return 1; } };
    ;
    var ctx = try setup(alloc, src);
    defer ctx.deinit();

    try expectPure(&ctx, 0, false);
}

// ================================================================
// Collection constructor — oxc-style strict rule (#1567 Phase A refinement)
// ================================================================
//
// `new Set()/Map()/WeakSet()/WeakMap()` 의 인자는 iterator protocol 발동 가능성
// 때문에 아래 형태만 pure:
//   - 무인자 / null / 전역 undefined / ArrayExpression (각 원소 재귀 pure)
// Map/WeakMap 은 ArrayExpression 의 각 outer 원소가 또 ArrayExpression ([k,v]) 이어야.

fn expectPure(ctx: *const TestCtx, stmt_idx: usize, pure: bool) !void {
    const init = initOfDecl(ctx, stmt_idx);
    try std.testing.expectEqual(pure, purity.isExprPure(&ctx.ast, init, &ctx.analyzer.unresolved_references));
}

test "collection: no args — pure" {
    const alloc = std.testing.allocator;
    const src =
        \\const a = new Set();
        \\const b = new Map();
        \\const c = new WeakSet();
        \\const d = new WeakMap();
    ;
    var ctx = try setup(alloc, src);
    defer ctx.deinit();
    try expectPure(&ctx, 0, true);
    try expectPure(&ctx, 1, true);
    try expectPure(&ctx, 2, true);
    try expectPure(&ctx, 3, true);
}

test "collection: null arg — pure" {
    const alloc = std.testing.allocator;
    const src =
        \\const a = new Set(null);
        \\const b = new Map(null);
        \\const c = new WeakSet(null);
        \\const d = new WeakMap(null);
    ;
    var ctx = try setup(alloc, src);
    defer ctx.deinit();
    try expectPure(&ctx, 0, true);
    try expectPure(&ctx, 1, true);
    try expectPure(&ctx, 2, true);
    try expectPure(&ctx, 3, true);
}

test "collection: global undefined arg — pure" {
    const alloc = std.testing.allocator;
    // top-level 에서 undefined 는 unresolved global. Set 도 unresolved global.
    const src = "const a = new Set(undefined);";
    var ctx = try setup(alloc, src);
    defer ctx.deinit();
    try expectPure(&ctx, 0, true);
}

test "collection: shadowed undefined arg — NOT pure" {
    const alloc = std.testing.allocator;
    // undefined 를 local 로 shadow → unresolved 에서 빠짐 → pure 판정 불가.
    const src =
        \\const undefined = 1;
        \\const a = new Set(undefined);
    ;
    var ctx = try setup(alloc, src);
    defer ctx.deinit();
    try expectPure(&ctx, 1, false);
}

test "collection: empty array arg — pure" {
    const alloc = std.testing.allocator;
    const src =
        \\const a = new Set([]);
        \\const b = new Map([]);
    ;
    var ctx = try setup(alloc, src);
    defer ctx.deinit();
    try expectPure(&ctx, 0, true);
    try expectPure(&ctx, 1, true);
}

test "collection: array of literals — Set/WeakSet pure" {
    const alloc = std.testing.allocator;
    const src =
        \\const a = new Set([1, 2, 3]);
        \\const b = new Set(["x", true, null]);
        \\const c = new WeakSet([{}, [], 42]);
    ;
    var ctx = try setup(alloc, src);
    defer ctx.deinit();
    try expectPure(&ctx, 0, true);
    try expectPure(&ctx, 1, true);
    try expectPure(&ctx, 2, true);
}

test "collection: Map with pair-of-literals — pure" {
    const alloc = std.testing.allocator;
    const src =
        \\const a = new Map([["a", 1]]);
        \\const b = new Map([["a", 1], ["b", 2]]);
        \\const c = new WeakMap([[{}, 1]]);
    ;
    var ctx = try setup(alloc, src);
    defer ctx.deinit();
    try expectPure(&ctx, 0, true);
    try expectPure(&ctx, 1, true);
    try expectPure(&ctx, 2, true);
}

test "collection: Map with non-array element — NOT pure" {
    const alloc = std.testing.allocator;
    const src = "const a = new Map([1, 2]);"; // outer array 원소가 ArrayExpression 아님
    var ctx = try setup(alloc, src);
    defer ctx.deinit();
    try expectPure(&ctx, 0, false);
}

test "collection: identifier arg — NOT pure (iterator protocol risk)" {
    const alloc = std.testing.allocator;
    // 현재 구현의 **이전 permissive 버그** 시나리오. Symbol.iterator getter side-effect
    // 가능성 때문에 보수적 impure.
    const src =
        \\const a = new Set(someIter);
        \\const b = new Map(m);
    ;
    var ctx = try setup(alloc, src);
    defer ctx.deinit();
    try expectPure(&ctx, 0, false);
    try expectPure(&ctx, 1, false);
}

test "collection: call result arg — NOT pure" {
    const alloc = std.testing.allocator;
    const src = "const a = new Set(getIter());";
    var ctx = try setup(alloc, src);
    defer ctx.deinit();
    try expectPure(&ctx, 0, false);
}

test "collection: member access arg — NOT pure" {
    const alloc = std.testing.allocator;
    const src = "const a = new Set(obj.items);";
    var ctx = try setup(alloc, src);
    defer ctx.deinit();
    try expectPure(&ctx, 0, false);
}

test "collection: object literal arg — NOT pure" {
    const alloc = std.testing.allocator;
    const src = "const a = new Set({});";
    var ctx = try setup(alloc, src);
    defer ctx.deinit();
    try expectPure(&ctx, 0, false);
}

test "collection: array with spread element — NOT pure" {
    const alloc = std.testing.allocator;
    const src = "const a = new Set([1, ...xs, 3]);";
    var ctx = try setup(alloc, src);
    defer ctx.deinit();
    try expectPure(&ctx, 0, false);
}

test "collection: array with impure element — NOT pure" {
    const alloc = std.testing.allocator;
    const src = "const a = new Set([1, fetch()]);";
    var ctx = try setup(alloc, src);
    defer ctx.deinit();
    try expectPure(&ctx, 0, false);
}

test "collection: multiple args — NOT pure (spec: 1 arg)" {
    const alloc = std.testing.allocator;
    const src = "const a = new Set(1, 2);"; // 실제로는 2번째 무시되지만 보수적 skip
    var ctx = try setup(alloc, src);
    defer ctx.deinit();
    try expectPure(&ctx, 0, false);
}

test "collection: call form Set() — NOT pure (TypeError throws)" {
    const alloc = std.testing.allocator;
    const src =
        \\const a = Set();
        \\const b = Map();
        \\const c = WeakSet();
        \\const d = WeakMap();
    ;
    var ctx = try setup(alloc, src);
    defer ctx.deinit();
    try expectPure(&ctx, 0, false);
    try expectPure(&ctx, 1, false);
    try expectPure(&ctx, 2, false);
    try expectPure(&ctx, 3, false);
}

test "collection: Map with nested impure inner — NOT pure" {
    const alloc = std.testing.allocator;
    // [[foo(), 1]] — outer 는 array, inner 도 array — ArrayExpression 조건은 만족.
    // 하지만 재귀 pure 체크에서 foo() 가 impure → 전체 impure.
    const src = "const a = new Map([[foo(), 1]]);";
    var ctx = try setup(alloc, src);
    defer ctx.deinit();
    try expectPure(&ctx, 0, false);
}

test "collection: nested literal containers — pure" {
    const alloc = std.testing.allocator;
    // Set([[1,2], [3,4]]) — 각 원소는 array literal, 재귀 pure. Set 규칙 상 OK.
    const src = "const a = new Set([[1, 2], [3, 4]]);";
    var ctx = try setup(alloc, src);
    defer ctx.deinit();
    try expectPure(&ctx, 0, true);
}

test "collection: elision in array — pure (빈 슬롯 skip)" {
    const alloc = std.testing.allocator;
    const src = "const a = new Set([1, , 3]);";
    var ctx = try setup(alloc, src);
    defer ctx.deinit();
    try expectPure(&ctx, 0, true);
}

// ================================================================
// Symbol — dotcall_only
// ================================================================

test "Symbol: call form — pure" {
    const alloc = std.testing.allocator;
    const src =
        \\const a = Symbol();
        \\const b = Symbol("desc");
    ;
    var ctx = try setup(alloc, src);
    defer ctx.deinit();
    try expectPure(&ctx, 0, true);
    try expectPure(&ctx, 1, true);
}

test "Symbol: new form — NOT pure (TypeError throws)" {
    const alloc = std.testing.allocator;
    const src = "const a = new Symbol();";
    var ctx = try setup(alloc, src);
    defer ctx.deinit();
    try expectPure(&ctx, 0, false);
}

// ================================================================
// Error constructors — 하위 타입 모두 커버
// ================================================================

test "Error: Error + all subtypes pure" {
    const alloc = std.testing.allocator;
    const src =
        \\const a = new Error("x");
        \\const b = new EvalError("x");
        \\const c = new RangeError("x");
        \\const d = new ReferenceError("x");
        \\const e = new SyntaxError("x");
        \\const f = new TypeError("x");
        \\const g = new URIError("x");
    ;
    var ctx = try setup(alloc, src);
    defer ctx.deinit();
    for (0..7) |i| try expectPure(&ctx, i, true);
}

test "Error: call form also pure (Error() 동등)" {
    const alloc = std.testing.allocator;
    const src = "const a = Error(\"x\");";
    var ctx = try setup(alloc, src);
    defer ctx.deinit();
    try expectPure(&ctx, 0, true);
}

test "Error: CustomError — NOT pure (whitelist 외)" {
    const alloc = std.testing.allocator;
    const src = "const a = new CustomError();";
    var ctx = try setup(alloc, src);
    defer ctx.deinit();
    try expectPure(&ctx, 0, false);
}

test "Error: 인자가 impure — 보존" {
    const alloc = std.testing.allocator;
    const src = "const a = new Error(getMsg());";
    var ctx = try setup(alloc, src);
    defer ctx.deinit();
    try expectPure(&ctx, 0, false);
}

test "Error: Symbol() 인자 — NOT pure (ToString(Symbol) throws TypeError)" {
    // ECMA-262 §20.5.1: Error constructor 가 ToString(msg) 호출. Symbol 이면 TypeError.
    // Symbol() 자체는 whitelist 상 pure 지만, Error msg 로는 static-proof 불가 → impure.
    const alloc = std.testing.allocator;
    const src = "const a = new Error(Symbol());";
    var ctx = try setup(alloc, src);
    defer ctx.deinit();
    try expectPure(&ctx, 0, false);
}

test "Error: identifier arg — NOT pure (Symbol 여부 불명)" {
    const alloc = std.testing.allocator;
    const src = "const a = new Error(maybeSymbol);";
    var ctx = try setup(alloc, src);
    defer ctx.deinit();
    try expectPure(&ctx, 0, false);
}

test "Error: member access arg — NOT pure (Symbol 여부 불명)" {
    const alloc = std.testing.allocator;
    const src = "const a = new Error(obj.msg);";
    var ctx = try setup(alloc, src);
    defer ctx.deinit();
    try expectPure(&ctx, 0, false);
}

test "Error: call result arg — NOT pure (Symbol 여부 불명)" {
    const alloc = std.testing.allocator;
    const src = "const a = new TypeError(makeMsg());";
    var ctx = try setup(alloc, src);
    defer ctx.deinit();
    try expectPure(&ctx, 0, false);
}

test "Error: string literal arg — pure (non-Symbol 보장)" {
    const alloc = std.testing.allocator;
    const src = "const a = new TypeError(\"fail\");";
    var ctx = try setup(alloc, src);
    defer ctx.deinit();
    try expectPure(&ctx, 0, true);
}

test "Error: template literal arg — currently 보존 (isNodePureDepth 미지원)" {
    // template_literal 은 canBeSymbol 상으로 non-Symbol (항상 string) 이지만
    // 일반 isNodePureDepth 경로가 template_literal 을 처리하지 않아 보수적 impure.
    // 별도 PR 에서 isNodePureDepth 에 template_literal 추가 시 pure 가능.
    const alloc = std.testing.allocator;
    const src = "const a = new RangeError(`value: ${1}`);";
    var ctx = try setup(alloc, src);
    defer ctx.deinit();
    try expectPure(&ctx, 0, false);
}

test "Error: numeric literal arg — pure" {
    const alloc = std.testing.allocator;
    const src = "const a = new SyntaxError(42);";
    var ctx = try setup(alloc, src);
    defer ctx.deinit();
    try expectPure(&ctx, 0, true);
}

test "Error: null/undefined arg — pure" {
    const alloc = std.testing.allocator;
    const src =
        \\const a = new Error(null);
        \\const b = new TypeError(undefined);
    ;
    var ctx = try setup(alloc, src);
    defer ctx.deinit();
    try expectPure(&ctx, 0, true);
    try expectPure(&ctx, 1, true);
}

test "Error: 2+ args — NOT pure (보수적)" {
    const alloc = std.testing.allocator;
    const src = "const a = new Error(\"msg\", { cause: e });";
    var ctx = try setup(alloc, src);
    defer ctx.deinit();
    try expectPure(&ctx, 0, false);
}

// ================================================================
// Object / Boolean — unconditional (new + call 모두 pure)
// ================================================================

test "Object/Boolean: new + call 모두 pure" {
    const alloc = std.testing.allocator;
    const src =
        \\const a = new Object();
        \\const b = new Object({ x: 1 });
        \\const c = new Boolean();
        \\const d = new Boolean(true);
        \\const e = Object();
        \\const f = Object(42);
        \\const g = Boolean();
        \\const h = Boolean(0);
    ;
    var ctx = try setup(alloc, src);
    defer ctx.deinit();
    for (0..8) |i| try expectPure(&ctx, i, true);
}

test "Object/Boolean: impure arg — 보존" {
    const alloc = std.testing.allocator;
    const src =
        \\const a = Object(fetch());
        \\const b = Boolean(sideEffect());
    ;
    var ctx = try setup(alloc, src);
    defer ctx.deinit();
    try expectPure(&ctx, 0, false);
    try expectPure(&ctx, 1, false);
}

// ================================================================
// Array / Date / String — either (new + call 모두 pure)
// ================================================================

test "Array/Date/String: new + call 모두 pure" {
    const alloc = std.testing.allocator;
    const src =
        \\const a = new Array();
        \\const b = new Array(5);
        \\const c = new Array(1, 2, 3);
        \\const d = Array();
        \\const e = Array(5);
        \\const f = new Date();
        \\const g = new Date(2024, 0, 1);
        \\const h = Date();
        \\const i = new String();
        \\const j = new String("x");
        \\const k = String();
        \\const l = String(42);
    ;
    var ctx = try setup(alloc, src);
    defer ctx.deinit();
    for (0..12) |i| try expectPure(&ctx, i, true);
}

test "Array/Date/String: impure arg — 보존" {
    const alloc = std.testing.allocator;
    const src =
        \\const a = new Array(getLen());
        \\const b = Date(getTime());
        \\const c = String(compute());
    ;
    var ctx = try setup(alloc, src);
    defer ctx.deinit();
    try expectPure(&ctx, 0, false);
    try expectPure(&ctx, 1, false);
    try expectPure(&ctx, 2, false);
}

// ================================================================
// Whitelist 외 — 항상 impure
// ================================================================

test "excluded: RegExp — NOT pure (invalid pattern SyntaxError)" {
    const alloc = std.testing.allocator;
    const src = "const a = new RegExp(\"[\");";
    var ctx = try setup(alloc, src);
    defer ctx.deinit();
    try expectPure(&ctx, 0, false);
}

test "excluded: BigInt — NOT pure (invalid value TypeError)" {
    const alloc = std.testing.allocator;
    const src = "const a = BigInt(1.5);";
    var ctx = try setup(alloc, src);
    defer ctx.deinit();
    try expectPure(&ctx, 0, false);
}

test "excluded: Number — NOT pure (Symbol TypeError)" {
    const alloc = std.testing.allocator;
    const src = "const a = Number(x);";
    var ctx = try setup(alloc, src);
    defer ctx.deinit();
    try expectPure(&ctx, 0, false);
}

test "excluded: Proxy — NOT pure (handler 임의 코드)" {
    const alloc = std.testing.allocator;
    const src = "const a = new Proxy({}, {});";
    var ctx = try setup(alloc, src);
    defer ctx.deinit();
    try expectPure(&ctx, 0, false);
}

test "excluded: WeakRef — NOT pure (target mutable)" {
    const alloc = std.testing.allocator;
    const src = "const a = new WeakRef(obj);";
    var ctx = try setup(alloc, src);
    defer ctx.deinit();
    try expectPure(&ctx, 0, false);
}

test "excluded: TypedArray — NOT pure (iteration side-effect)" {
    const alloc = std.testing.allocator;
    const src =
        \\const a = new Int8Array(4);
        \\const b = new Uint8Array(4);
        \\const c = new Float32Array(4);
    ;
    var ctx = try setup(alloc, src);
    defer ctx.deinit();
    try expectPure(&ctx, 0, false);
    try expectPure(&ctx, 1, false);
    try expectPure(&ctx, 2, false);
}

test "excluded: Function (eval) — NOT pure" {
    const alloc = std.testing.allocator;
    const src = "const a = new Function(\"return 1\");";
    var ctx = try setup(alloc, src);
    defer ctx.deinit();
    try expectPure(&ctx, 0, false);
}

test "excluded: user class — NOT pure (whitelist 외)" {
    const alloc = std.testing.allocator;
    const src = "const a = new MyClass();";
    var ctx = try setup(alloc, src);
    defer ctx.deinit();
    try expectPure(&ctx, 0, false);
}

// ================================================================
// Global binding 검증 (shadow 시나리오 확장)
// ================================================================

test "shadow: function param named Set — NOT pure" {
    // 함수 안의 `new Set()` 이지만 param 으로 Set 이 있으면 shadow.
    // 여기선 위 initOfDecl 헬퍼가 top-level 전용이라, 함수 body 안 구조는
    // 직접 테스트하기 복잡 — 대신 top-level 재선언으로 equivalent 검증.
    const alloc = std.testing.allocator;
    const src =
        \\function Set() { return {}; }
        \\const s = new Set();
    ;
    var ctx = try setup(alloc, src);
    defer ctx.deinit();
    try expectPure(&ctx, 1, false);
}

test "shadow: import of Set — NOT pure" {
    const alloc = std.testing.allocator;
    const src =
        \\import { Set } from "./my-set";
        \\const s = new Set();
    ;
    var ctx = try setup(alloc, src);
    defer ctx.deinit();
    try expectPure(&ctx, 1, false);
}

test "shadow: class Set {} — NOT pure" {
    const alloc = std.testing.allocator;
    const src =
        \\class Set { constructor() {} }
        \\const s = new Set();
    ;
    var ctx = try setup(alloc, src);
    defer ctx.deinit();
    try expectPure(&ctx, 1, false);
}

// ================================================================
// @__PURE__ override
// ================================================================

test "pure annotation: /*#__PURE__*/ myFunc() 은 whitelist 무관하게 pure" {
    const alloc = std.testing.allocator;
    const src = "const a = /*#__PURE__*/ myCustomFn();";
    var ctx = try setup(alloc, src);
    defer ctx.deinit();
    try expectPure(&ctx, 0, true);
}

test "user pure hints: exact member and namespace wildcard mark calls pure" {
    const alloc = std.testing.allocator;
    const src =
        \\const a = React.createElement("div");
        \\const b = PropTypes.string.isRequired();
        \\const c = React.cloneElement(node);
        \\const d = React["createElement"]("div");
        \\const e = React.createElement?.("div");
    ;
    var ctx = try setup(alloc, src);
    defer ctx.deinit();

    purity.markUserPureCalls(&ctx.ast, &.{ "React.createElement", "PropTypes.*" });

    try std.testing.expect(purity.isExprPure(&ctx.ast, initOfDecl(&ctx, 0), null));
    try std.testing.expect(purity.isExprPure(&ctx.ast, initOfDecl(&ctx, 1), null));
    try std.testing.expect(!purity.isExprPure(&ctx.ast, initOfDecl(&ctx, 2), null));
    try std.testing.expect(!purity.isExprPure(&ctx.ast, initOfDecl(&ctx, 3), null));
    try std.testing.expect(!purity.isExprPure(&ctx.ast, initOfDecl(&ctx, 4), null));
}

test "user pure hints: bare identifier and new expression are matched" {
    const alloc = std.testing.allocator;
    const src =
        \\const a = makeUnused("hint");
        \\const b = new MakeUnused("hint");
        \\const c = keepMe("hint");
    ;
    var ctx = try setup(alloc, src);
    defer ctx.deinit();

    purity.markUserPureCalls(&ctx.ast, &.{ "makeUnused", "MakeUnused" });

    try std.testing.expect(purity.isExprPure(&ctx.ast, initOfDecl(&ctx, 0), null));
    try std.testing.expect(purity.isExprPure(&ctx.ast, initOfDecl(&ctx, 1), null));
    try std.testing.expect(!purity.isExprPure(&ctx.ast, initOfDecl(&ctx, 2), null));
}

test "known pure call: Object.freeze with pure arg is pure" {
    const alloc = std.testing.allocator;
    const src =
        \\const a = Object.freeze({ tag: "pure" });
        \\const b = Object.freeze([1, 2, 3]);
    ;
    var ctx = try setup(alloc, src);
    defer ctx.deinit();

    try expectPure(&ctx, 0, true);
    try expectPure(&ctx, 1, true);
    try std.testing.expect(!purity.isExprPure(&ctx.ast, initOfDecl(&ctx, 0), null));
}

test "known pure call: Object.freeze is guarded by shadowing and arg purity" {
    const alloc = std.testing.allocator;
    const src =
        \\const a = Object.freeze(sideEffect());
        \\const obj = {};
        \\const c = Object.freeze(obj);
        \\const Object = { freeze(value) { console.log("shadow-freeze"); return value; } };
        \\const b = Object.freeze({ tag: "shadowed" });
    ;
    var ctx = try setup(alloc, src);
    defer ctx.deinit();

    try expectPure(&ctx, 0, false);
    try expectPure(&ctx, 2, false);
    try expectPure(&ctx, 4, false);
}

test "known pure call: Object.assign with fresh pure objects is pure" {
    const alloc = std.testing.allocator;
    const src =
        \\const a = Object.assign({}, { tag: "pure" });
        \\const b = Object.assign({ base: 1 }, ({ extra: 2 }));
        \\const c = Object.assign({}, { a: 1 }, { b: 2 });
    ;
    var ctx = try setup(alloc, src);
    defer ctx.deinit();

    try expectPure(&ctx, 0, true);
    try expectPure(&ctx, 1, true);
    try expectPure(&ctx, 2, true);
    try std.testing.expect(!purity.isExprPure(&ctx.ast, initOfDecl(&ctx, 0), null));
}

test "known pure call: Object.assign is guarded by target source and shadowing" {
    const alloc = std.testing.allocator;
    const src =
        \\const target = {};
        \\const a = Object.assign(target, { tag: "target" });
        \\const source = { tag: "source" };
        \\const b = Object.assign({}, source);
        \\const c = Object.assign({}, { get x() { console.log("getter"); return 1; } });
        \\const d = Object.assign({}, sideEffect());
        \\const Object = { assign(target, source) { console.log("shadow-assign"); return target; } };
        \\const e = Object.assign({}, { tag: "shadowed" });
        \\const f = Object.assign({}, { ...source });
        \\const g = Object.assign({}, { [sideEffect()]: 1 });
        \\const h = Object.assign({}, { method() { return 1; } });
        \\const i = Object["assign"]({}, { tag: "computed-callee" });
        \\const j = Object.assign?.({}, { tag: "optional-callee" });
    ;
    var ctx = try setup(alloc, src);
    defer ctx.deinit();

    try expectPure(&ctx, 1, false);
    try expectPure(&ctx, 3, false);
    try expectPure(&ctx, 4, false);
    try expectPure(&ctx, 5, false);
    try expectPure(&ctx, 7, false);
    try expectPure(&ctx, 8, false);
    try expectPure(&ctx, 9, false);
    try expectPure(&ctx, 10, false);
    try expectPure(&ctx, 11, false);
    try expectPure(&ctx, 12, false);
}

// ================================================================
// null unresolved_globals — 기존 동작 유지 (#1567 호환)
// ================================================================

test "null context: all builtins impure" {
    const alloc = std.testing.allocator;
    const src =
        \\const a = new Set();
        \\const b = new Map();
        \\const c = new Date();
    ;
    var ctx = try setup(alloc, src);
    defer ctx.deinit();
    for (0..3) |i| {
        const init = initOfDecl(&ctx, i);
        try std.testing.expect(!purity.isExprPure(&ctx.ast, init, null));
    }
}

// ================================================================
// isRemovableAtStmtPos — 문 자리 / dead-store 삭제용 엄격 술어 (#4514)
// ================================================================

fn removalCtx(ctx: *const TestCtx) purity.StmtRemovalCtx {
    return .{
        .symbol_ids = ctx.analyzer.symbol_ids.items,
        .symbols = ctx.analyzer.symbols.items,
        .unresolved_globals = &ctx.analyzer.unresolved_references,
    };
}

/// 소스에서 `name` 과 텍스트가 같은 **첫 번째** `identifier_reference` 노드를 찾는다.
fn firstIdentRef(ctx: *const TestCtx, name: []const u8) !NodeIndex {
    for (ctx.ast.nodes.items, 0..) |node, i| {
        if (node.tag != .identifier_reference) continue;
        if (std.mem.eql(u8, ctx.ast.getText(node.span), name)) return @enumFromInt(i);
    }
    return error.IdentNotFound;
}

/// 주어진 tag 의 첫 번째 노드.
fn firstNodeOfTag(ctx: *const TestCtx, tag: NodeTag) !NodeIndex {
    for (ctx.ast.nodes.items, 0..) |node, i| {
        if (node.tag == tag) return @enumFromInt(i);
    }
    return error.NodeNotFound;
}

test "isRemovableAtStmtPos: member access 는 삭제 불가 (getter / TypeError)" {
    const alloc = std.testing.allocator;
    // `isExprPure` 는 member 를 pure 로 보지만(tree-shaking 기준), 이미 실행이 확정된
    // 표현식을 지우는 자리에서는 getter 호출 / nullish base TypeError 가 사라진다.
    var ctx = try setup(alloc, "const a = obj.p;\nconst b = obj[k];\n");
    defer ctx.deinit();

    const static_member = try firstNodeOfTag(&ctx, .static_member_expression);
    const computed_member = try firstNodeOfTag(&ctx, .computed_member_expression);

    // 기존(완화) 술어는 pure 로 본다 — 대비 확인.
    try std.testing.expect(purity.isExprPure(&ctx.ast, static_member, &ctx.analyzer.unresolved_references));
    // 엄격 술어는 유지.
    try std.testing.expect(!purity.isRemovableAtStmtPos(&ctx.ast, static_member, removalCtx(&ctx)));
    try std.testing.expect(!purity.isRemovableAtStmtPos(&ctx.ast, computed_member, removalCtx(&ctx)));
}

test "isRemovableAtStmtPos: 미해결 전역 읽기는 삭제 불가 (ReferenceError)" {
    const alloc = std.testing.allocator;
    var ctx = try setup(alloc, "function f() { let z = undeclaredGlobal; z = 2; return z; }\n");
    defer ctx.deinit();

    const ident = try firstIdentRef(&ctx, "undeclaredGlobal");
    try std.testing.expect(purity.isExprPure(&ctx.ast, ident, &ctx.analyzer.unresolved_references));
    try std.testing.expect(!purity.isRemovableAtStmtPos(&ctx.ast, ident, removalCtx(&ctx)));
}

test "isRemovableAtStmtPos: var / 파라미터 읽기는 삭제 가능 (DSE 수익 보존)" {
    const alloc = std.testing.allocator;
    // TDZ 가 없는 바인딩(var / 파라미터 / catch / function 선언)은 계속 제거 대상이다.
    var ctx = try setup(alloc, "function f(p) { var loc = 1; let a = loc; a = p; a = 2; return a + loc; }\n");
    defer ctx.deinit();

    try std.testing.expect(purity.isRemovableAtStmtPos(&ctx.ast, try firstIdentRef(&ctx, "loc"), removalCtx(&ctx)));
    try std.testing.expect(purity.isRemovableAtStmtPos(&ctx.ast, try firstIdentRef(&ctx, "p"), removalCtx(&ctx)));
}

test "isRemovableAtStmtPos: block-scoped(let/const/class) 읽기는 TDZ 때문에 삭제 불가" {
    const alloc = std.testing.allocator;
    // TDZ 는 **시간** 개념이라 소스 위치 비교로 못 잡는다 — hoisting 된 함수가 선언 실행 전에
    // 불리면 선언보다 텍스트상 뒤에 있는 읽기도 TDZ 다. 참조 노드의 실행 단위를 이 술어가
    // 알 수 없으므로 block-scoped 선언 읽기는 통째로 유지한다.
    var ctx = try setup(alloc, "function f() { const loc = 1; let a = loc; a = 2; return a + loc; }\n");
    defer ctx.deinit();

    try std.testing.expect(!purity.isRemovableAtStmtPos(&ctx.ast, try firstIdentRef(&ctx, "loc"), removalCtx(&ctx)));
}

test "isRemovableAtStmtPos: top-level 바인딩 / import 는 삭제 불가 (live binding)" {
    const alloc = std.testing.allocator;
    var ctx = try setup(alloc,
        \\import { imported } from "./m";
        \\var top = 1;
        \\function f() { let a = top; a = imported; a = 2; return a; }
    );
    defer ctx.deinit();

    try std.testing.expect(!purity.isRemovableAtStmtPos(&ctx.ast, try firstIdentRef(&ctx, "top"), removalCtx(&ctx)));
    try std.testing.expect(!purity.isRemovableAtStmtPos(&ctx.ast, try firstIdentRef(&ctx, "imported"), removalCtx(&ctx)));
}

test "isRemovableAtStmtPos: hoisted function 선언 읽기는 삭제 가능" {
    const alloc = std.testing.allocator;
    // function 선언은 hoisting 으로 초기화까지 끝나 TDZ 가 없다. (이 코드베이스는
    // generator/async 선언에도 block_scoped 를 세우므로 명시 제외가 필요하다.)
    var ctx = try setup(alloc, "function f() { let a = g; a = 2; function* g() {} return a; }\n");
    defer ctx.deinit();

    try std.testing.expect(purity.isRemovableAtStmtPos(&ctx.ast, try firstIdentRef(&ctx, "g"), removalCtx(&ctx)));
}

test "isRemovableAtStmtPos: 리터럴 / 논리 / 삼항 / 함수식은 삭제 가능" {
    const alloc = std.testing.allocator;
    var ctx = try setup(alloc,
        \\function f() {
        \\  var loc = 1;
        \\  let a = !loc;
        \\  a = loc ? 1 : 2;
        \\  a = loc && 1;
        \\  a = () => loc;
        \\  a = 3;
        \\  return a;
        \\}
    );
    defer ctx.deinit();

    const c = removalCtx(&ctx);
    try std.testing.expect(purity.isRemovableAtStmtPos(&ctx.ast, try firstNodeOfTag(&ctx, .unary_expression), c));
    try std.testing.expect(purity.isRemovableAtStmtPos(&ctx.ast, try firstNodeOfTag(&ctx, .conditional_expression), c));
    try std.testing.expect(purity.isRemovableAtStmtPos(&ctx.ast, try firstNodeOfTag(&ctx, .logical_expression), c));
    try std.testing.expect(purity.isRemovableAtStmtPos(&ctx.ast, try firstNodeOfTag(&ctx, .arrow_function_expression), c));
}

test "isRemovableAtStmtPos: 객체 / 배열 리터럴은 삭제 가능 (DSE 수익 보존)" {
    const alloc = std.testing.allocator;
    var ctx = try setup(alloc, "function f(c) { let x = { a: 1, m() {} }; x = c; let y = [1, 2]; y = c; return [x, y]; }\n");
    defer ctx.deinit();

    const c = removalCtx(&ctx);
    try std.testing.expect(purity.isRemovableAtStmtPos(&ctx.ast, try firstNodeOfTag(&ctx, .object_expression), c));
    try std.testing.expect(purity.isRemovableAtStmtPos(&ctx.ast, try firstNodeOfTag(&ctx, .array_expression), c));
}

test "isRemovableAtStmtPos: 객체 spread / computed key / 배열 spread 는 삭제 불가" {
    const alloc = std.testing.allocator;
    // spread 는 iterator/Proxy trap, computed key 는 ToPropertyKey → toString 호출.
    var ctx = try setup(alloc, "function f(c) { let x = { ...c }; x = 1; return x; }\n");
    defer ctx.deinit();
    try std.testing.expect(!purity.isRemovableAtStmtPos(&ctx.ast, try firstNodeOfTag(&ctx, .object_expression), removalCtx(&ctx)));

    var ctx2 = try setup(alloc, "function f(c) { let x = { [c]: 1 }; x = 1; return x; }\n");
    defer ctx2.deinit();
    try std.testing.expect(!purity.isRemovableAtStmtPos(&ctx2.ast, try firstNodeOfTag(&ctx2, .object_expression), removalCtx(&ctx2)));

    var ctx3 = try setup(alloc, "function f(c) { let x = [...c]; x = 1; return x; }\n");
    defer ctx3.deinit();
    try std.testing.expect(!purity.isRemovableAtStmtPos(&ctx3.ast, try firstNodeOfTag(&ctx3, .array_expression), removalCtx(&ctx3)));
}

test "isRemovableAtStmtPos: 산술 / 관계 / in / instanceof 이항은 삭제 불가 (ToPrimitive)" {
    const alloc = std.testing.allocator;
    // `+` 는 ToPrimitive → 사용자 valueOf/toString 호출. `in`/`instanceof` 는 TypeError 가능.
    // 변환이 전혀 없는 `===` / `!==` 만 삭제 가능.
    const cases = [_][]const u8{
        "function f(p, q) { let a = p + q; a = 1; return a; }",
        "function f(p, q) { let a = p < q; a = 1; return a; }",
        "function f(p, q) { let a = p == q; a = 1; return a; }",
        "function f(p, q) { let a = p in q; a = 1; return a; }",
        "function f(p, q) { let a = p instanceof q; a = 1; return a; }",
    };
    for (cases) |src| {
        var ctx = try setup(alloc, src);
        defer ctx.deinit();
        try std.testing.expect(!purity.isRemovableAtStmtPos(&ctx.ast, try firstNodeOfTag(&ctx, .binary_expression), removalCtx(&ctx)));
    }

    var ok = try setup(alloc, "function f(p, q) { let a = p === q; a = 1; return a; }");
    defer ok.deinit();
    try std.testing.expect(purity.isRemovableAtStmtPos(&ok.ast, try firstNodeOfTag(&ok, .binary_expression), removalCtx(&ok)));
}

test "isRemovableAtStmtPos: 단항 -/+/~/delete 는 삭제 불가, !/void/typeof 는 가능 (ToNumeric)" {
    const alloc = std.testing.allocator;
    const blocked = [_][]const u8{
        "function f(p) { let a = -p; a = 1; return a; }",
        "function f(p) { let a = +p; a = 1; return a; }",
        "function f(p) { let a = ~p; a = 1; return a; }",
        "function f(p) { let a = delete p.x; a = 1; return a; }",
    };
    for (blocked) |src| {
        var ctx = try setup(alloc, src);
        defer ctx.deinit();
        try std.testing.expect(!purity.isRemovableAtStmtPos(&ctx.ast, try firstNodeOfTag(&ctx, .unary_expression), removalCtx(&ctx)));
    }

    const allowed = [_][]const u8{
        "function f(p) { let a = !p; a = 1; return a; }",
        "function f(p) { let a = void p; a = 1; return a; }",
        "function f(p) { let a = typeof p; a = 1; return a; }",
    };
    for (allowed) |src| {
        var ctx = try setup(alloc, src);
        defer ctx.deinit();
        try std.testing.expect(purity.isRemovableAtStmtPos(&ctx.ast, try firstNodeOfTag(&ctx, .unary_expression), removalCtx(&ctx)));
    }
}

test "isRemovableAtStmtPos: 치환 있는 template literal 은 삭제 불가 (ToString)" {
    const alloc = std.testing.allocator;
    var ctx = try setup(alloc, "function f(p) { let a = `t${p}`; a = 1; return a; }\n");
    defer ctx.deinit();
    try std.testing.expect(!purity.isRemovableAtStmtPos(&ctx.ast, try firstNodeOfTag(&ctx, .template_literal), removalCtx(&ctx)));

    // 치환 없는 template 은 그냥 문자열 리터럴 — 삭제 가능.
    var ctx2 = try setup(alloc, "function f() { let a = `static`; a = 1; return a; }\n");
    defer ctx2.deinit();
    try std.testing.expect(purity.isRemovableAtStmtPos(&ctx2.ast, try firstNodeOfTag(&ctx2, .template_literal), removalCtx(&ctx2)));
}

test "isRemovableAtStmtPos: 자식에 member 가 하나라도 있으면 삭제 불가" {
    const alloc = std.testing.allocator;
    // `===` 자체는 변환이 없지만 피연산자 `obj.p` 평가에서 getter 가 돈다.
    var ctx = try setup(alloc, "function f(p) { let a = p === obj.p; a = 2; return a; }\n");
    defer ctx.deinit();

    try std.testing.expect(!purity.isRemovableAtStmtPos(&ctx.ast, try firstNodeOfTag(&ctx, .binary_expression), removalCtx(&ctx)));
}

test "isRemovableAtStmtPos: 빌트인 pure call 은 인자까지 엄격 검사한다" {
    const alloc = std.testing.allocator;
    // 무인자 `new Set()` 은 삭제 가능.
    var ctx = try setup(alloc, "function f() { let a = new Set(); a = 2; return a; }\n");
    defer ctx.deinit();
    try std.testing.expect(purity.isRemovableAtStmtPos(&ctx.ast, try firstNodeOfTag(&ctx, .new_expression), removalCtx(&ctx)));

    // `String(obj.p)` 는 pure 로 판정되지만 **인자** 평가에서 getter 가 돈다 → 유지.
    var ctx2 = try setup(alloc, "function f() { let a = String(obj.p); a = 2; return a; }\n");
    defer ctx2.deinit();
    try std.testing.expect(purity.isExprPure(&ctx2.ast, try firstNodeOfTag(&ctx2, .call_expression), &ctx2.analyzer.unresolved_references));
    try std.testing.expect(!purity.isRemovableAtStmtPos(&ctx2.ast, try firstNodeOfTag(&ctx2, .call_expression), removalCtx(&ctx2)));

    // 일반 call 은 애초에 pure 가 아니다.
    var ctx3 = try setup(alloc, "function f() { let a = sideEffect(); a = 2; return a; }\n");
    defer ctx3.deinit();
    try std.testing.expect(!purity.isRemovableAtStmtPos(&ctx3.ast, try firstNodeOfTag(&ctx3, .call_expression), removalCtx(&ctx3)));
}
