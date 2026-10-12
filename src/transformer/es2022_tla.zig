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
//! - import_declaration / export_* 는 래퍼 밖에 둔다. 첫 top-level await 보다 앞의
//!   export 선언은 래퍼 앞(원래 순서), 뒤의 것은 래퍼 뒤에 놓인다 (#5570).
//! - export 선언 안의 await (`export const x = await foo()`) 는 낮출 수 없다 — 번들은
//!   analyzer 가 ZNTC0001 로 거부한다 (#5564).
//! - 번들이 모듈을 async `__esm` factory 로 평가하면(`tla_export_decl_deferrable`)
//!   이 변환을 하지 않는다: await 가 factory 안에 그대로 남는다 (#5570).
//!
//! 참고:
//! - esbuild: internal/js_parser/js_parser.go — LowerAllStaticFields & TLA handling.
//!   esbuild도 TLA 미지원 타겟에선 `(async () => { ... })()` 로 감싼다.
//! - oxc: 미구현 (TLA 는 ES2022 이상 타겟에서만 사용한다는 전제).

const std = @import("std");

/// #4598: TLA IIFE 의 promise 를 담는 변수명. emitter 가 `return <이 이름>;` 으로 돌려준다.
pub const TLA_PROMISE_VAR = "__zntc_tla";
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
const TopLevelAwaitCtx = struct { found: bool };

fn topLevelAwaitVisit(ctx: *TopLevelAwaitCtx, idx: NodeIndex, node: Node) ast_walk.WalkAction {
    _ = idx;
    switch (node.tag) {
        // 함수/메서드/클래스 경계 → 그 안의 await 는 top-level 아님. prune.
        .function_declaration,
        .function_expression,
        .function,
        .arrow_function_expression,
        .method_definition,
        .class_declaration,
        .class_expression,
        => return .skip_children,
        // `for await (… of …)` 도 top-level await 다 — 다운레벨 시 내부에 `await` 를
        // 남기므로 감지 대상이다. 놓치면 변환만 건너뛰고 청크 factory 는 async 가 아닌
        // 상태가 돼 네이티브 await 가 누출된다 (#4598).
        .for_await_of_statement => {
            ctx.found = true;
            return .stop;
        },
        .await_expression => {
            ctx.found = true;
            return .stop;
        },
        else => return .descend,
    }
}

pub fn hasTopLevelAwait(ast: *const ast_mod.Ast, idx: NodeIndex) std.mem.Allocator.Error!bool {
    // 반복 순회(#4123): top-level 깊은 좌결합 체인에서 재귀 시 스택 오버플로우. OOM 은
    // 호출자(lowerProgram=Error!)로 전파한다 — true/false 어느 기본값도 안전하지 않으므로
    // (false=미지원 타깃에 unwrapped await / true=불필요 IIFE wrap) 추측 대신 에러 전파.
    var c = TopLevelAwaitCtx{ .found = false };
    try ast_walk.walkPreorderIterative(ast.allocator, ast, idx, &c, topLevelAwaitVisit);
    return c.found;
}

/// `visitNode` 가 쌓은 `pending_nodes`(앞) / `trailing_nodes`(뒤) 를 scratch 로 옮긴다.
///
/// ⚠️ `lowerProgram` 은 `visitExtraList` 를 안 쓰고 직접 리스트를 조립하므로 이 배수를
///    스스로 해야 한다. 빠뜨리면 데코레이터/다운레벨 class 의 호이스팅된 선언이 통째로
///    사라져 `Export 'C' is not defined` 가 된다(폐기된 시도가 정확히 그랬다).
fn drainPendingAround(
    comptime Transformer: type,
    self: *Transformer,
    pending_top: usize,
    trailing_top: usize,
    visited: NodeIndex,
) Transformer.Error!void {
    return drainPendingAroundTo(Transformer, self, pending_top, trailing_top, visited, &self.scratch);
}

fn drainPendingAroundTo(
    comptime Transformer: type,
    self: *Transformer,
    pending_top: usize,
    trailing_top: usize,
    visited: NodeIndex,
    destination: *std.ArrayList(NodeIndex),
) Transformer.Error!void {
    if (self.pending_nodes.items.len > pending_top) {
        try destination.appendSlice(self.allocator, self.pending_nodes.items[pending_top..]);
        self.pending_nodes.shrinkRetainingCapacity(pending_top);
    }
    if (!visited.isNone()) try destination.append(self.allocator, visited);
    if (self.trailing_nodes.items.len > trailing_top) {
        try destination.appendSlice(self.allocator, self.trailing_nodes.items[trailing_top..]);
        self.trailing_nodes.shrinkRetainingCapacity(trailing_top);
    }
}

/// program 의 top-level 에 TLA 가 있으면 async IIFE 로 wrap.
/// `self` 는 Transformer. options.unsupported.top_level_await 가 true 일 때만 호출.
///
/// 반환: wrap 된 program 노드 index (TLA 가 없으면 null — caller 가 기본 visit 수행).
pub fn lowerProgram(comptime Transformer: type, self: *Transformer, node: Node) Transformer.Error!?NodeIndex {
    std.debug.assert(node.tag == .program);
    // ⚠️ 멱등성: 같은 program 에 두 번 적용되면 async IIFE 가 **두 개** 방출돼
    // side-effect 가 2회 실행된다(유닛 테스트가 잡음). 플래그는 **AST** 에 둬야 한다 —
    // prepass/emit 이 각각 새 Transformer 를 만들기 때문.
    if (self.ast.tla_lowered) return null;
    // ESM output with native async functions evaluates a top-level-await
    // module inside an async `__esm` factory: the awaits stay where they are,
    // and that factory hoists top-level bindings and keeps statement order.
    // An inner async IIFE would split the module in two — exports outside it
    // could not see its locals (`export function f() { return config }`) and
    // ran out of order or in TDZ (#5570).
    if (self.options.tla_export_decl_deferrable) return null;
    const list = node.data.list;

    // 1. wrap 대상 TLA 존재 여부 검사. Export declarations stay outside the
    // wrapper: an await in one is rejected by the analyzer when bundling
    // (#5564), and transpile reports ZNTC0001.
    var has_tla = false;
    var i: u32 = 0;
    while (i < list.len) : (i += 1) {
        const child: NodeIndex = @enumFromInt(self.ast.extra_data.items[list.start + i]);
        if (isModuleDeclaration(self.ast.getNode(child).tag)) continue;
        if (try hasTopLevelAwait(self.ast, child)) {
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
            const pt = self.pending_nodes.items.len;
            const tt = self.trailing_nodes.items.len;
            const visited = try self.visitNode(child);
            try drainPendingAround(Transformer, self, pt, tt, visited);
        }
    }
    const imports_end = self.scratch.items.len;

    // Allocate the synthetic async boundary before visiting its body. Temps
    // and helper references created by that visit then carry this exact
    // lexical scope. Imports and exports are visited outside this boundary.
    const empty_params = try self.ast.addNodeList(&.{});
    const empty_params_node = try self.ast.addFormalParameters(empty_params, node.span);
    const arrow_extra = try self.ast.addExtras(&.{
        @intFromEnum(empty_params_node),
        @intFromEnum(NodeIndex.none),
        ast_mod.ArrowFlags.is_async,
    });
    const arrow = try self.ast.addNode(.{
        .tag = .arrow_function_expression,
        .span = node.span,
        .data = .{ .extra = arrow_extra },
    });
    const outer_scope = self.current_scope;
    const arrow_scope = if (self.semantic_edit_enabled)
        try self.addGeneratedFunctionScope(self.programScope(), arrow)
    else
        outer_scope;
    self.current_scope = arrow_scope;
    defer self.current_scope = outer_scope;

    // wrap target 수집 (visit 하여 기본 변환 적용)
    var prelude_stmts: std.ArrayList(NodeIndex) = .empty;
    defer prelude_stmts.deinit(self.allocator);
    const body_stmts_top = self.scratch.items.len;
    var wrapper_started = false;
    // Export declarations before the first top-level await keep their place
    // ahead of the wrapper: code before that await may read them (#5570).
    var prelude_exports: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer prelude_exports.deinit(self.allocator);
    i = 0;
    while (i < list.len) : (i += 1) {
        const child: NodeIndex = @enumFromInt(self.ast.extra_data.items[list.start + i]);
        const child_node = self.ast.getNode(child);
        if (child_node.tag == .import_declaration or child_node.tag == .ts_import_equals_declaration) continue;
        if (isModuleDeclaration(child_node.tag)) {
            if (wrapper_started) continue;
            const pt = self.pending_nodes.items.len;
            const tt = self.trailing_nodes.items.len;
            const visited = try self.visitNode(child);
            try drainPendingAroundTo(Transformer, self, pt, tt, visited, &prelude_stmts);
            try prelude_exports.put(self.allocator, @intFromEnum(child), {});
            continue;
        }
        const pt = self.pending_nodes.items.len;
        const tt = self.trailing_nodes.items.len;
        const visited = try self.visitNode(child);
        if (!wrapper_started and try hasTopLevelAwait(self.ast, child)) wrapper_started = true;
        const destination = if (wrapper_started) &self.scratch else &prelude_stmts;
        try drainPendingAroundTo(Transformer, self, pt, tt, visited, destination);
    }
    const body_stmts_end = self.scratch.items.len;
    self.current_scope = outer_scope;

    // async arrow body block 생성
    const body_list_nodes = self.scratch.items[body_stmts_top..body_stmts_end];
    const body_list = try self.ast.addNodeList(body_list_nodes);
    const body_block = try self.ast.addNode(.{
        .tag = .block_statement,
        .span = node.span,
        .data = .{ .list = body_list },
    });

    // Fill the pre-registered async arrow once the visited body is available.
    self.ast.extra_data.items[arrow_extra + 1] = @intFromEnum(body_block);
    // Scopes of the moved statements (a user arrow, a block) now nest inside
    // the wrapper; left under the program scope, an arrow's parameter
    // initializer lost the wrapped declarations it reads (#5562).
    if (self.semantic_edit_enabled) try self.reparentGeneratedBodyScopes(self.programScope(), arrow_scope, body_block);

    // (arrow)() — 호출 (arrow 는 call-target 위치에서 codegen 이 자동 wrap)
    const call = try es_helpers.makeCallExpr(self, arrow, &.{}, node.span);
    // #4598: 표현식 문장이 아니라 **변수 선언**으로 만든다 — `var __zntc_tla = (…)();`.
    // emitter 가 `__esm` factory 끝에 `return __zntc_tla;` 만 덧붙이면 `init_X()` 가
    // 초기화 완료 promise 를 돌려준다. 문장을 쪼개 재조립하는 방식은 codegen 이 내부
    // 버퍼에 **누적**해서 IIFE 가 두 번 방출됐다(유닛 테스트가 잡음).
    // ⚠️ 이름을 직접 발명하면 안 된다. 사용자가 같은 이름을 쓰면 값을 덮어쓰고,
    //    접미사를 붙여 피해도 이번엔 리네이머가 사용자 심볼을 건드려 참조가 끊긴다
    //    (적대적 검증이 둘 다 잡음). 기존 임시변수 기계는 `collidesWithUserSymbol`
    //    (#4220) 로 충돌 회피가 이미 들어가 있고 리네이머와도 정합적이다.
    const tla_name = try es_helpers.makeTempVarSpan(self);
    const tla_binding = try es_helpers.makeSyntheticBinding(self, tla_name);
    // The wrapper result is a real module-local variable. Give it identity
    // before visiting the declaration so later transforms and name assignment
    // do not need to recover it from the generated temp's spelling.
    if (self.semantic_edit_enabled) _ = try self.declareSyntheticVar(tla_binding, node.span);
    const tla_declarator = try es_helpers.makeDeclarator(self, tla_binding, call, node.span);
    const iife_stmt = try es_helpers.makeVarDeclaration(self, &.{tla_declarator}, .@"var", node.span);

    // async/await lowering 이 이 arrow 에 적용되어야 하므로 재방문이 필요한 경우가 있지만,
    // `visitNode` 는 자식 재방문을 내부적으로 처리한다. 우리는 arrow 를 top-down dispatch 에
    // 다시 넣기 위해 expression_statement 를 visit.
    const iife_pt = self.pending_nodes.items.len;
    const iife_tt = self.trailing_nodes.items.len;
    const visited_iife = try self.visitNode(iife_stmt);
    // ⚠️ 여기서 배수하지 않으면 아래 exports 패스의 배수가 이 pending 을 주워 담아
    //    **IIFE 가 두 번** 방출된다 → side-effect 2회 실행(유닛 테스트가 잡음).
    self.pending_nodes.shrinkRetainingCapacity(iife_pt);
    self.trailing_nodes.shrinkRetainingCapacity(iife_tt);
    // #4598: emitter 가 `__esm` factory 안에서 이 문장을 `return <expr>;` 로 방출한다.
    if (!visited_iife.isNone()) {
        self.tla_iife_stmt = visited_iife;
        self.ast.tla_lowered = true;
    }

    // 최종 program list: [imports...] + [visited_iife] + [exports...]
    // 현재 scratch 에는 [imports_end..body_stmts_end] 까지 wrap 대상이 있으므로
    // body_stmts_top 이후를 drop 하고 새 리스트를 구성.
    self.scratch.shrinkRetainingCapacity(imports_end);
    try self.scratch.appendSlice(self.allocator, prelude_stmts.items);
    if (!visited_iife.isNone()) try self.scratch.append(self.allocator, visited_iife);

    // exports pass-through
    i = 0;
    while (i < list.len) : (i += 1) {
        const child: NodeIndex = @enumFromInt(self.ast.extra_data.items[list.start + i]);
        const child_node = self.ast.getNode(child);
        if (child_node.tag == .import_declaration or child_node.tag == .ts_import_equals_declaration) continue;
        if (!isModuleDeclaration(child_node.tag)) continue;
        if (prelude_exports.contains(@intFromEnum(child))) continue;
        const pt = self.pending_nodes.items.len;
        const tt = self.trailing_nodes.items.len;
        const visited = try self.visitNode(child);
        try drainPendingAround(Transformer, self, pt, tt, visited);
    }

    const new_list = try self.ast.addNodeList(self.scratch.items[imports_top..]);
    return try self.ast.addNode(.{
        .tag = .program,
        .span = node.span,
        .data = .{ .list = new_list },
    });
}
