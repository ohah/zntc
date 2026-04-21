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
const NodeIndex = @import("../parser/ast.zig").NodeIndex;
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

/// program의 `stmt_idx`번째 top-level statement가 불러지는 variable_declaration일 때
/// 그 첫 declarator의 initializer NodeIndex를 반환한다.
fn initOfDecl(ctx: *const TestCtx, stmt_idx: usize) NodeIndex {
    const root_ni = @intFromEnum(ctx.root);
    const root_node = ctx.ast.nodes.items[root_ni];
    const stmts = root_node.data.list;
    const raw_stmt: u32 = ctx.ast.extra_data.items[stmts.start + stmt_idx];
    const stmt = ctx.ast.nodes.items[raw_stmt];
    // variable_declaration: [kind(0), list_start(1), list_len(2)]
    const de = stmt.data.extra;
    const list_start = ctx.ast.extra_data.items[de + 1];
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
