//! ES2022 Top-level await 다운레벨링
//!
//! --target < es2022 (top_level_await unsupported) 일 때 활성화.
//!
//! 모듈 최상단 `await expr` 은 ES2022부터 지원. 미지원 타겟에서 `await` 가
//! `(yield expr)` 로 다운레벨링되지만, 감싸는 async function이 없으면 bare yield
//! 로 leak되어 SyntaxError. (#1384)
//!
//! 변환:
//!   await foo();
//!   console.log(x);
//! →
//!   (async () => {
//!     await foo();
//!     console.log(x);
//!   })();
//!
//! 그 후 `async_await` 도 unsupported면 이 async arrow 는 기존
//! es2017 lowering 경로로 `__async(function*(){...})` 로 변환된다.
//!
//! 범위:
//! - import_declaration / export_* 는 그대로 둔다 (ESM wrap 불가).
//! - export + TLA 조합 (예: `export const x = await foo()`) 은 복잡하므로
//!   이 구현에서는 wrap 을 건너뛴다 (단독 번들 entry 에서는 거의 없음).
//!
//! 참고:
//! - esbuild: internal/js_parser/js_parser.go — LowerAllStaticFields & TLA handling.
//!   esbuild도 TLA 미지원 타겟에선 `(async () => { ... })()` 로 감싼다.
//! - oxc: 미구현 (TLA 는 ES2022 이상 타겟에서만 사용한다는 전제).

const std = @import("std");
const ast_mod = @import("../parser/ast.zig");
const ast_walk = @import("../parser/ast_walk.zig");
const es_helpers = @import("es_helpers.zig");
const Node = ast_mod.Node;
const NodeIndex = ast_mod.NodeIndex;
const Tag = Node.Tag;
const token_mod = @import("../lexer/token.zig");
const Span = token_mod.Span;

/// statement가 import/export 인지 판별 (program 최상단만 허용되는 모듈 선언).
fn isModuleDeclaration(tag: Tag) bool {
    return switch (tag) {
        .import_declaration,
        .export_named_declaration,
        .export_default_declaration,
        .export_all_declaration,
        .ts_import_equals_declaration,
        .ts_export_assignment,
        .ts_namespace_export_declaration,
        => true,
        else => false,
    };
}

/// 서브트리(statement)에 top-level await (함수 경계를 넘지 않는 await) 가 있는지 검사.
fn hasTopLevelAwait(ast: *const ast_mod.Ast, idx: NodeIndex) bool {
    if (idx.isNone()) return false;
    const node = ast.getNode(idx);

    // 함수/메서드 경계를 만나면 await 는 해당 함수 소속 — 더 내려가지 않음.
    switch (node.tag) {
        .function_declaration,
        .function_expression,
        .function,
        .arrow_function_expression,
        .method_definition,
        .class_declaration,
        .class_expression,
        => return false,
        .await_expression => return true,
        else => {},
    }

    // 자식 재귀 — 공통 ChildIterator (ast_walk) 로 predicate 탐색.
    var it = ast_walk.children(ast, node);
    while (it.next()) |child| {
        if (hasTopLevelAwait(ast, child)) return true;
    }
    return false;
}

/// program 의 top-level 에 TLA 가 있으면 async IIFE 로 wrap.
/// `self` 는 Transformer. options.unsupported.top_level_await 가 true 일 때만 호출.
///
/// 반환: wrap 된 program 노드 index (TLA 가 없으면 null — caller 가 기본 visit 수행).
pub fn lowerProgram(comptime Transformer: type, self: *Transformer, node: Node) Transformer.Error!?NodeIndex {
    std.debug.assert(node.tag == .program);
    const list = node.data.list;

    // 1. wrap 대상 TLA 존재 여부 검사.
    // export 선언 안의 TLA (예: `export const x = await foo()`) 는 wrap 생략 (첫 패스).
    var has_tla = false;
    var i: u32 = 0;
    while (i < list.len) : (i += 1) {
        const child: NodeIndex = @enumFromInt(self.ast.extra_data.items[list.start + i]);
        const child_node = self.ast.getNode(child);
        if (isModuleDeclaration(child_node.tag)) continue;
        if (hasTopLevelAwait(&self.ast, child)) {
            has_tla = true;
            break;
        }
    }
    if (!has_tla) return null;

    // 2. 자식을 두 그룹으로 분리.
    //    - 그대로 유지: import/export 문
    //    - wrap 대상: 그 외 (wrap 구간은 원래 순서 보존을 위해 하나의 연속 블록으로 묶는다)
    //
    // 간단화: [모든 imports] + [wrap IIFE (나머지 전체를 감싼 async arrow)] + [export_*]
    // 중간에 import 가 섞여 있어도 ESM 는 imports hoisting 이 있어 순서 의존성이 거의 없다.
    // export 가 중간에 끼어 있으면 has_export_with_tla 로 잡혀 이 함수 상단에서 이미 return null.
    // 따라서 여기서는 import 만 별도 분리하고, 나머지는 전부 wrap.

    const scratch_top = self.scratch.items.len;
    defer self.scratch.shrinkRetainingCapacity(scratch_top);

    const imports_top = self.scratch.items.len;
    const body_start = imports_top; // imports 먼저 append
    _ = body_start;

    // imports pass-through (visit 하여 기본 변환 적용)
    i = 0;
    while (i < list.len) : (i += 1) {
        const child: NodeIndex = @enumFromInt(self.ast.extra_data.items[list.start + i]);
        const child_node = self.ast.getNode(child);
        if (child_node.tag == .import_declaration or child_node.tag == .ts_import_equals_declaration) {
            const visited = try self.visitNode(child);
            if (!visited.isNone()) try self.scratch.append(self.allocator, visited);
        }
    }
    const imports_end = self.scratch.items.len;

    // wrap target 수집 (visit 하여 기본 변환 적용)
    const body_stmts_top = self.scratch.items.len;
    i = 0;
    while (i < list.len) : (i += 1) {
        const child: NodeIndex = @enumFromInt(self.ast.extra_data.items[list.start + i]);
        const child_node = self.ast.getNode(child);
        if (child_node.tag == .import_declaration or child_node.tag == .ts_import_equals_declaration) continue;
        if (isModuleDeclaration(child_node.tag)) continue; // 아래 exports 패스에서 처리
        const visited = try self.visitNode(child);
        if (!visited.isNone()) try self.scratch.append(self.allocator, visited);
    }
    const body_stmts_end = self.scratch.items.len;

    // async arrow body block 생성
    const body_list_nodes = self.scratch.items[body_stmts_top..body_stmts_end];
    const body_list = try self.ast.addNodeList(body_list_nodes);
    const body_block = try self.ast.addNode(.{
        .tag = .block_statement,
        .span = node.span,
        .data = .{ .list = body_list },
    });

    // async arrow: () => body_block  (with is_async flag)
    const empty_params = try self.ast.addNodeList(&.{});
    const empty_params_node = try self.ast.addFormalParameters(empty_params, node.span);
    const arrow_extra = try self.ast.addExtras(&.{
        @intFromEnum(empty_params_node),
        @intFromEnum(body_block),
        ast_mod.ArrowFlags.is_async,
    });
    const arrow = try self.ast.addNode(.{
        .tag = .arrow_function_expression,
        .span = node.span,
        .data = .{ .extra = arrow_extra },
    });

    // (arrow)() — 괄호 + 호출
    const paren = try es_helpers.makeParenExpr(self, arrow, node.span);
    const call = try es_helpers.makeCallExpr(self, paren, &.{}, node.span);
    const iife_stmt = try es_helpers.makeExprStmt(self, call, node.span);

    // async/await lowering 이 이 arrow 에 적용되어야 하므로 재방문이 필요한 경우가 있지만,
    // `visitNode` 는 자식 재방문을 내부적으로 처리한다. 우리는 arrow 를 top-down dispatch 에
    // 다시 넣기 위해 expression_statement 를 visit.
    const visited_iife = try self.visitNode(iife_stmt);

    // 최종 program list: [imports...] + [visited_iife] + [exports...]
    // 현재 scratch 에는 [imports_end..body_stmts_end] 까지 wrap 대상이 있으므로
    // body_stmts_top 이후를 drop 하고 새 리스트를 구성.
    self.scratch.shrinkRetainingCapacity(imports_end);
    if (!visited_iife.isNone()) try self.scratch.append(self.allocator, visited_iife);

    // exports pass-through
    i = 0;
    while (i < list.len) : (i += 1) {
        const child: NodeIndex = @enumFromInt(self.ast.extra_data.items[list.start + i]);
        const child_node = self.ast.getNode(child);
        if (child_node.tag == .import_declaration or child_node.tag == .ts_import_equals_declaration) continue;
        if (!isModuleDeclaration(child_node.tag)) continue;
        const visited = try self.visitNode(child);
        if (!visited.isNone()) try self.scratch.append(self.allocator, visited);
    }

    const new_list = try self.ast.addNodeList(self.scratch.items[imports_top..]);
    return try self.ast.addNode(.{
        .tag = .program,
        .span = node.span,
        .data = .{ .list = new_list },
    });
}
