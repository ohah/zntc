//! Module-level purity and evaluation-effect policy for tree shaking.

const ast_mod = @import("../../parser/ast.zig");
const Ast = ast_mod.Ast;
const Node = ast_mod.Node;
const NodeIndex = ast_mod.NodeIndex;
const Module = @import("../module.zig").Module;
const purity = @import("../purity.zig");

/// 모듈을 evaluation 의존으로 끌어와야 하는 부수효과가 있는지.
/// `.cjs` wrap 은 정적 분석 불가 — 항상 evaluation 의존. `.esm` wrap 은 _emit shape_
/// (lazy init / circular dep) 일 뿐 semantic side-effect 가 아니지만, 기존 RN/Metro
/// 호환 동작은 `.esm` 을 보수 처리해 왔다 (#2398). 본 함수는 _user 가 명시적으로_
/// `sideEffects: false` 를 선언한 모듈에만 그 신호를 신뢰 — 나머지는 conservative
/// 유지로 RN core 같은 미선언 케이스의 회귀 방지.
pub inline fn hasEvaluationEffect(mod: *const Module) bool {
    if (mod.side_effects) return true;
    if (mod.wrap_kind == .cjs) return true;
    if (mod.exports_kind == .esm_with_dynamic_fallback) return true;
    if (mod.wrap_kind == .esm and !mod.side_effects_user_defined) return true;
    return false;
}

/// 모듈의 top-level 문장이 모두 순수한지 판별.
/// 순수: import/export 선언, 함수/클래스 선언, 변수 선언(초기값이 순수), @__PURE__ call.
/// 불순: 일반 call expression, assignment to global, etc.
pub fn isModulePure(ast: *const Ast, unresolved_globals: ?*const purity.GlobalRefSet) bool {
    if (ast.nodes.items.len == 0) return false;
    const root = ast.nodes.items[ast.nodes.items.len - 1];
    if (root.tag != .program) return false;
    const stmts = root.data.list;
    if (stmts.len == 0) return false;
    if (stmts.start + stmts.len > ast.extra_data.items.len) return false;

    const stmt_indices = ast.extra_data.items[stmts.start .. stmts.start + stmts.len];
    for (stmt_indices) |raw| {
        const idx: NodeIndex = @enumFromInt(raw);
        if (idx.isNone() or @intFromEnum(idx) >= ast.nodes.items.len) continue;
        const stmt = ast.nodes.items[@intFromEnum(idx)];
        if (!isStatementPure(ast, stmt, unresolved_globals)) return false;
    }
    return true;
}

fn isStatementPure(ast: *const Ast, stmt: Node, unresolved_globals: ?*const purity.GlobalRefSet) bool {
    return switch (stmt.tag) {
        .import_declaration,
        .export_all_declaration,
        => true,

        .export_named_declaration => {
            if (!ast.hasExtra(stmt.data.extra, 0)) return true;
            const decl_idx = ast.readExtraNode(stmt.data.extra, 0);
            if (decl_idx.isNone()) return true;
            if (@intFromEnum(decl_idx) >= ast.nodes.items.len) return true;
            const decl = ast.nodes.items[@intFromEnum(decl_idx)];
            return isStatementPure(ast, decl, unresolved_globals);
        },

        .export_default_declaration => {
            const inner_idx = stmt.data.unary.operand;
            if (inner_idx.isNone() or @intFromEnum(inner_idx) >= ast.nodes.items.len) return false;
            const inner = ast.nodes.items[@intFromEnum(inner_idx)];
            return switch (inner.tag) {
                .function_declaration => true,
                .class_declaration => !purity.classHasSideEffects(ast, inner, unresolved_globals),
                else => purity.isExprPure(ast, inner_idx, unresolved_globals),
            };
        },

        .function_declaration => true,
        .class_declaration => !purity.classHasSideEffects(ast, stmt, unresolved_globals),

        .ts_interface_declaration,
        .ts_type_alias_declaration,
        => true,

        .ts_enum_declaration,
        .ts_module_declaration,
        => false,

        .variable_declaration => purity.isVarDeclPure(ast, stmt, unresolved_globals),
        .expression_statement,
        .if_statement,
        => !purity.stmtHasSideEffects(ast, stmt, unresolved_globals),

        .empty_statement => true,

        else => false,
    };
}
