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

test "pure builtin: whitelist covers Map/WeakMap/WeakSet/Symbol/Array/Object/Date/Error" {
    const alloc = std.testing.allocator;
    const src =
        \\const a = new Map();
        \\const b = new WeakMap();
        \\const c = new WeakSet();
        \\const d = new Symbol();
        \\const e = new Array(4);
        \\const f = new Object();
        \\const g = new Date();
        \\const h = new Error("x");
    ;
    var ctx = try setup(alloc, src);
    defer ctx.deinit();

    const globals = &ctx.analyzer.unresolved_references;
    for (0..8) |i| {
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
