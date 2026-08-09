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
        .await_expression => {
            ctx.found = true;
            return .stop;
        },
        else => return .descend,
    }
}

fn hasTopLevelAwait(ast: *const ast_mod.Ast, idx: NodeIndex) std.mem.Allocator.Error!bool {
    // 반복 순회(#4123): top-level 깊은 좌결합 체인에서 재귀 시 스택 오버플로우. OOM 은
    // 호출자(lowerProgram=Error!)로 전파한다 — true/false 어느 기본값도 안전하지 않으므로
    // (false=미지원 타깃에 unwrapped await / true=불필요 IIFE wrap) 추측 대신 에러 전파.
    var c = TopLevelAwaitCtx{ .found = false };
    try ast_walk.walkPreorderIterative(ast.allocator, ast, idx, &c, topLevelAwaitVisit);
    return c.found;
}

/// program 의 top-level 에 TLA 가 있으면 async IIFE 로 wrap.
/// `self` 는 Transformer. options.unsupported.top_level_await 가 true 일 때만 호출.
///
/// 반환: wrap 된 program 노드 index (TLA 가 없으면 null — caller 가 기본 visit 수행).
/// `export const X = init;` 을 **`export var X;`(래퍼 밖) + `X = init;`(래퍼 안)** 으로 분해한다 (#4598).
///
/// TLA 래퍼는 최상위 문장을 `(async () => {…})()` 안으로 넣는데, export 선언은 ESM 상 최상위에만
/// 올 수 있어 밖에 남는다. 그러면 **선언은 안 / 사용은 밖** 으로 스코프가 갈려
/// `ReferenceError` 가 난다 (#4598 재현). 바인딩만 밖으로 올리고 초기화는 원래 자리(래퍼 안)에
/// 남기면, ESM live binding 으로 밖에서도 보인다 — rspack 이 export 를 getter 로 선등록하는 것의
/// ESM 등가 형태다.
///
/// ⚠️ **참조 분석을 하지 않는다.** "이 export 가 래퍼 로컬을 참조하는가" 로 좁히려 했다가 계속
/// 경계를 놓쳤다(`export default`·`export {X}`·중첩 블록). 전부 균일하게 분해하면 그 판정이
/// 필요 없다.
///
/// 반환: 밖에 둘 `export var …;` 노드. 분해할 수 없으면(구조분해 바인딩 등) null —
/// 호출자가 종전대로 pass-through 한다.
/// `export function f(){}` / `export class C{}` 를 `export var f;`(밖) + `f = function f(){…};` 로
/// 분해한다 (#4598 2단계).
///
/// ⚠️ **리네임하지 않는다.** 선언을 named function expression 대입으로 바꾸면 안쪽 바인딩이
/// 사라져 섀도잉이 없어지고, 자기참조는 named FE 의 이름이 처리한다. 스코프 인식 리네임 패스
/// 라는 큰 위험을 통째로 없앤다. (상호재귀·재대입·`f.name` 까지 원본과 등가임을 실측 확인)
///
/// ⚠️ 함수는 대입을 래퍼 본문 **맨 위**에 둔다 — 선언 호이스팅과 등가다(`typeof f` 가 선언
/// 앞에서 `"function"`, 초기화 전 호출은 TDZ `ReferenceError` 로 원본과 일치). 클래스는 원래
/// TDZ 라 원위치에 둔다.
/// `export default expr` 를 `var _t;`(밖) + `_t = expr;`(안) + `export { _t as default };`(밖)
/// 으로 분해한다 (#4598).
///
/// ⚠️ `export default _t;` 로는 안 된다 — `export default <expr>` 는 평가 시점의 **값 스냅샷**을
/// 내보내므로 래퍼가 대입하기 전의 `undefined` 가 고정된다. live binding 을 얻으려면
/// `export { _t as default }` 형태여야 한다.
/// specifier-only export(`const X = …; export { X };`)의 **선언 쪽**을 분해한다 (#4598).
///
/// export 절은 최상위(래퍼 밖)에 남는데 선언은 래퍼 안으로 들어가 바인딩이 끊긴다.
/// 게다가 const-bake 가 래퍼 안에서 참조를 못 봐(export 절이 밖) 선언을 통째로 elide 한다 —
/// 그러면 `export { X }` 가 존재하지 않는 이름을 가리킨다.
///
/// 여기서는 **선언 문장 자체**를 `X = init;` 로 바꾸고 `var X;` 를 밖으로 올린다.
/// 반환: 래퍼 안에 넣을 대입문. 대상이 아니면 null.
fn splitLocalDeclForExport(
    comptime Transformer: type,
    self: *Transformer,
    decl_node: Node,
    exported_names: []const Span,
    extra_outer: *std.ArrayListUnmanaged(NodeIndex),
    out_assigns: *std.ArrayListUnmanaged(NodeIndex),
) Transformer.Error!bool {
    if (decl_node.tag != .variable_declaration) return false;
    const ve = decl_node.data.extra;
    if (ve + 2 >= self.ast.extra_data.items.len) return false;
    const decls_start = self.ast.extra_data.items[ve + 1];
    const decls_len = self.ast.extra_data.items[ve + 2];
    if (decls_len == 0) return false;

    // 이 선언의 바인딩이 **전부** export 대상이어야 통째로 전환한다. 섞여 있으면
    // 부분 전환이 되어 순서/의미가 복잡해지므로 건드리지 않는다.
    var di: u32 = 0;
    while (di < decls_len) : (di += 1) {
        const dtor = self.ast.getNode(@enumFromInt(self.ast.extra_data.items[decls_start + di]));
        if (dtor.tag != .variable_declarator) return false;
        const binding = self.ast.getNode(@as(NodeIndex, @enumFromInt(self.ast.extra_data.items[dtor.data.extra])));
        if (binding.tag != .binding_identifier) return false;
        const name = self.ast.getText(binding.span);
        var found = false;
        for (exported_names) |en| {
            if (std.mem.eql(u8, name, self.ast.getText(en))) {
                found = true;
                break;
            }
        }
        if (!found) return false;
    }

    const scratch_top = self.scratch.items.len;
    defer self.scratch.shrinkRetainingCapacity(scratch_top);

    di = 0;
    while (di < decls_len) : (di += 1) {
        const dtor_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[decls_start + di]);
        const dtor = self.ast.getNode(dtor_idx);
        const de = dtor.data.extra;
        const binding_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[de]);
        const init_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[de + 2]);
        const binding = self.ast.getNode(binding_idx);

        const bare_binding = try es_helpers.makeBindingIdentifier(self, binding.span);
        const bare_dtor = try es_helpers.makeDeclarator(self, bare_binding, NodeIndex.none, dtor.span);
        try self.scratch.append(self.allocator, bare_dtor);

        if (!init_idx.isNone()) {
            const target = try es_helpers.makeIdentifierRefFromSpan(self, binding.span);
            const visited_init = try self.visitNode(init_idx);
            if (visited_init.isNone()) return false;
            const assign = try es_helpers.makeAssignExpr(self, target, visited_init, dtor.span, 0);
            try out_assigns.append(self.allocator, try es_helpers.makeExprStmt(self, assign, dtor.span));
        }
    }

    const var_stmt = try es_helpers.makeVarDeclaration(
        self,
        self.scratch.items[scratch_top..],
        .@"var",
        decl_node.span,
    );
    try extra_outer.append(self.allocator, var_stmt);
    return true;
}

fn splitExportDefault(
    comptime Transformer: type,
    self: *Transformer,
    export_node: Node,
    assigns: *std.ArrayListUnmanaged(NodeIndex),
    extra_outer: *std.ArrayListUnmanaged(NodeIndex),
) Transformer.Error!?NodeIndex {
    const expr_idx = export_node.data.unary.operand;
    if (expr_idx.isNone()) return null;
    const expr_node = self.ast.getNode(expr_idx);
    // 함수/클래스 선언형 default 는 이름 유무·호이스팅이 달라 별도 축이다 — 건드리지 않는다.
    switch (expr_node.tag) {
        .function_declaration, .class_declaration => return null,
        else => {},
    }

    const visited = try self.visitNode(expr_idx);
    if (visited.isNone()) return null;

    const tmp_span = try es_helpers.makeTempVarSpan(self);

    // 안: `_t = expr;`
    const target = try es_helpers.makeIdentifierRefFromSpan(self, tmp_span);
    const assign = try es_helpers.makeAssignExpr(self, target, visited, export_node.span, 0);
    try assigns.append(self.allocator, try es_helpers.makeExprStmt(self, assign, export_node.span));

    // 밖(앞): `var _t;`
    const bare_binding = try es_helpers.makeBindingIdentifier(self, tmp_span);
    const bare_dtor = try es_helpers.makeDeclarator(self, bare_binding, NodeIndex.none, export_node.span);
    const var_stmt = try es_helpers.makeVarDeclaration(self, &.{bare_dtor}, .@"var", export_node.span);
    try extra_outer.append(self.allocator, var_stmt);

    // 밖(뒤): `export { _t as default };`
    const local_ref = try es_helpers.makeIdentifierRefFromSpan(self, tmp_span);
    const exported_ref = try es_helpers.makeIdentifierRef(self, "default");
    const spec = try self.ast.addNode(.{
        .tag = .export_specifier,
        .span = export_node.span,
        .data = .{ .binary = .{ .left = local_ref, .right = exported_ref, .flags = 0 } },
    });
    const spec_list = try self.ast.addNodeList(&.{spec});
    const new_extra = try self.ast.addExtras(&.{
        @intFromEnum(NodeIndex.none), spec_list.start, spec_list.len,
        @intFromEnum(NodeIndex.none), 0,               0,
    });
    return try self.ast.addNode(.{
        .tag = .export_named_declaration,
        .span = export_node.span,
        .data = .{ .extra = new_extra },
    });
}

fn splitExportedFnOrClass(
    comptime Transformer: type,
    self: *Transformer,
    export_node: Node,
    hoisted: *std.ArrayListUnmanaged(NodeIndex),
    assigns: *std.ArrayListUnmanaged(NodeIndex),
) Transformer.Error!?NodeIndex {
    const e = export_node.data.extra;
    if (e + 5 >= self.ast.extra_data.items.len) return null;
    const decl_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[e]);
    const specs_start = self.ast.extra_data.items[e + 1];
    const specs_len = self.ast.extra_data.items[e + 2];
    const source_raw = self.ast.extra_data.items[e + 3];
    // ⚠️ `export_named_declaration` 은 **6슬롯**이다 (attrs_start/attrs_len 포함).
    // 4슬롯만 쓰면 `readExportNamedExtras` 가 인접 extra_data 를 attrs 로 읽는다.
    const attrs_start = self.ast.extra_data.items[e + 4];
    const attrs_len = self.ast.extra_data.items[e + 5];
    if (!@as(NodeIndex, @enumFromInt(source_raw)).isNone()) return null;
    if (decl_idx.isNone()) return null;

    const decl = self.ast.getNode(decl_idx);
    const is_fn = decl.tag == .function_declaration;
    const is_class = decl.tag == .class_declaration;
    if (!is_fn and !is_class) return null;

    // extras[0] = 이름. 익명(`export default function(){}`)은 여기 오지 않는다.
    const name_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[decl.data.extra]);
    if (name_idx.isNone()) return null;
    const name_span = self.ast.getNode(name_idx).span;

    // 선언 → 표현식: 같은 extras 를 공유하고 tag 만 바꾼다 (codegen 이 같은 emit 경로).
    const visited_decl = try self.visitNode(decl_idx);
    if (visited_decl.isNone()) return null;
    const vd = self.ast.getNode(visited_decl);
    const expr = try self.ast.addNode(.{
        .tag = if (is_fn) .function_expression else .class_expression,
        .span = vd.span,
        .data = vd.data,
    });

    const target = try es_helpers.makeIdentifierRefFromSpan(self, name_span);
    const assign = try es_helpers.makeAssignExpr(self, target, expr, decl.span, 0);
    const stmt = try es_helpers.makeExprStmt(self, assign, decl.span);
    if (is_fn) try hoisted.append(self.allocator, stmt) else try assigns.append(self.allocator, stmt);

    const bare_binding = try es_helpers.makeBindingIdentifier(self, name_span);
    const bare_dtor = try es_helpers.makeDeclarator(self, bare_binding, NodeIndex.none, decl.span);
    const new_decl = try es_helpers.makeVarDeclaration(self, &.{bare_dtor}, .@"var", decl.span);
    const new_extra = try self.ast.addExtras(&.{
        @intFromEnum(new_decl), specs_start, specs_len, source_raw, attrs_start, attrs_len,
    });
    return try self.ast.addNode(.{
        .tag = .export_named_declaration,
        .span = export_node.span,
        .data = .{ .extra = new_extra },
    });
}

fn splitExportedVarDecl(
    comptime Transformer: type,
    self: *Transformer,
    export_node: Node,
    assigns: *std.ArrayListUnmanaged(NodeIndex),
) Transformer.Error!?NodeIndex {
    const e = export_node.data.extra;
    if (e + 5 >= self.ast.extra_data.items.len) return null;
    const decl_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[e]);
    const specs_start = self.ast.extra_data.items[e + 1];
    const specs_len = self.ast.extra_data.items[e + 2];
    const source_raw = self.ast.extra_data.items[e + 3];
    // ⚠️ `export_named_declaration` 은 **6슬롯**이다 (attrs_start/attrs_len 포함).
    // 4슬롯만 쓰면 `readExportNamedExtras` 가 인접 extra_data 를 attrs 로 읽는다.
    const attrs_start = self.ast.extra_data.items[e + 4];
    const attrs_len = self.ast.extra_data.items[e + 5];
    // `export { x } from '…'` 은 대상이 다른 모듈이라 분해 대상이 아니다.
    if (!@as(NodeIndex, @enumFromInt(source_raw)).isNone()) return null;
    if (decl_idx.isNone()) return null;

    const decl_node = self.ast.getNode(decl_idx);
    if (decl_node.tag != .variable_declaration) return null;

    const ve = decl_node.data.extra;
    if (ve + 2 >= self.ast.extra_data.items.len) return null;
    const decls_start = self.ast.extra_data.items[ve + 1];
    const decls_len = self.ast.extra_data.items[ve + 2];

    const scratch_top = self.scratch.items.len;
    defer self.scratch.shrinkRetainingCapacity(scratch_top);

    var di: u32 = 0;
    while (di < decls_len) : (di += 1) {
        const dtor_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[decls_start + di]);
        const dtor = self.ast.getNode(dtor_idx);
        if (dtor.tag != .variable_declarator) return null;
        const de = dtor.data.extra;
        if (de + 2 >= self.ast.extra_data.items.len) return null;
        const binding_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[de]);
        const init_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[de + 2]);
        const binding = self.ast.getNode(binding_idx);
        // 구조분해(`export const { a } = o`)는 바인딩이 단순 식별자가 아니라 분해 규칙이
        // 달라진다 — 종전 동작을 유지하고 여기서 빠진다.
        if (binding.tag != .binding_identifier) return null;

        // 밖: `var X;` (init 제거)
        const bare_binding = try es_helpers.makeBindingIdentifier(self, binding.span);
        const bare_dtor = try es_helpers.makeDeclarator(self, bare_binding, NodeIndex.none, dtor.span);
        try self.scratch.append(self.allocator, bare_dtor);

        // 안: `X = init;` (init 이 없으면 대입도 없다 — `export let x;`)
        if (!init_idx.isNone()) {
            const target = try es_helpers.makeIdentifierRefFromSpan(self, binding.span);
            const visited_init = try self.visitNode(init_idx);
            if (visited_init.isNone()) return null;
            const assign = try es_helpers.makeAssignExpr(self, target, visited_init, dtor.span, 0);
            try assigns.append(self.allocator, try es_helpers.makeExprStmt(self, assign, dtor.span));
        }
    }

    // `var` 로 강등한다 — 래퍼 안 대입이 TDZ 에 걸리지 않아야 한다.
    const new_decl = try es_helpers.makeVarDeclaration(
        self,
        self.scratch.items[scratch_top..],
        .@"var",
        decl_node.span,
    );
    const new_extra = try self.ast.addExtras(&.{
        @intFromEnum(new_decl), specs_start, specs_len, source_raw, attrs_start, attrs_len,
    });
    return try self.ast.addNode(.{
        .tag = .export_named_declaration,
        .span = export_node.span,
        .data = .{ .extra = new_extra },
    });
}

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
            const visited = try self.visitNode(child);
            if (!visited.isNone()) try self.scratch.append(self.allocator, visited);
        }
    }
    const imports_end = self.scratch.items.len;

    // #4598: export 선언을 미리 분해해 둔다 — `export var X;`(밖) + `X = init;`(안).
    // ⚠️ 대입문은 **원래 문장 순서 그대로** 래퍼 본문에 끼워 넣어야 한다. 끝에 몰아넣으면
    // 그 export 를 앞에서 읽는 코드가 `undefined` 를 본다 (실측으로 잡음).
    var split_src: std.ArrayListUnmanaged(NodeIndex) = .empty;
    defer split_src.deinit(self.allocator);
    var split_export: std.ArrayListUnmanaged(NodeIndex) = .empty;
    defer split_export.deinit(self.allocator);
    var split_assign_off: std.ArrayListUnmanaged(u32) = .empty;
    defer split_assign_off.deinit(self.allocator);
    var split_assigns: std.ArrayListUnmanaged(NodeIndex) = .empty;
    defer split_assigns.deinit(self.allocator);
    // 함수 선언 대입은 래퍼 본문 **맨 위**로 (호이스팅 등가).
    var hoisted_assigns: std.ArrayListUnmanaged(NodeIndex) = .empty;
    defer hoisted_assigns.deinit(self.allocator);
    // `export default` 분해가 만드는 추가 최상위 문장(`var _t;`) — IIFE **앞**에 둔다.
    var extra_outer: std.ArrayListUnmanaged(NodeIndex) = .empty;
    defer extra_outer.deinit(self.allocator);
    {
        var ei: u32 = 0;
        while (ei < list.len) : (ei += 1) {
            const child: NodeIndex = @enumFromInt(self.ast.extra_data.items[list.start + ei]);
            const child_node = self.ast.getNode(child);
            if (child_node.tag == .export_default_declaration) {
                const before_d: u32 = @intCast(split_assigns.items.len);
                const sd = try splitExportDefault(Transformer, self, child_node, &split_assigns, &extra_outer) orelse continue;
                try split_src.append(self.allocator, child);
                try split_export.append(self.allocator, sd);
                try split_assign_off.append(self.allocator, before_d);
                continue;
            }
            if (child_node.tag != .export_named_declaration) continue;
            const before: u32 = @intCast(split_assigns.items.len);
            const split = (try splitExportedVarDecl(Transformer, self, child_node, &split_assigns)) orelse
                (try splitExportedFnOrClass(Transformer, self, child_node, &hoisted_assigns, &split_assigns)) orelse
                continue;
            try split_src.append(self.allocator, child);
            try split_export.append(self.allocator, split);
            try split_assign_off.append(self.allocator, before);
        }
        try split_assign_off.append(self.allocator, @intCast(split_assigns.items.len));
    }

    // specifier-only export(`export { X };`)의 로컬 이름 수집 — 그 선언은 래퍼 안으로
    // 들어가므로 바인딩을 밖으로 올려야 한다 (#4598).
    var exported_locals: std.ArrayListUnmanaged(Span) = .empty;
    defer exported_locals.deinit(self.allocator);
    {
        var ei: u32 = 0;
        while (ei < list.len) : (ei += 1) {
            const child: NodeIndex = @enumFromInt(self.ast.extra_data.items[list.start + ei]);
            const child_node = self.ast.getNode(child);
            if (child_node.tag != .export_named_declaration) continue;
            const e = child_node.data.extra;
            if (e + 5 >= self.ast.extra_data.items.len) continue;
            const decl_i: NodeIndex = @enumFromInt(self.ast.extra_data.items[e]);
            const src_i: NodeIndex = @enumFromInt(self.ast.extra_data.items[e + 3]);
            if (!decl_i.isNone() or !src_i.isNone()) continue; // 선언형/re-export 는 별도 경로
            const ss = self.ast.extra_data.items[e + 1];
            const sl = self.ast.extra_data.items[e + 2];
            var si: u32 = 0;
            while (si < sl) : (si += 1) {
                const spec_i: NodeIndex = @enumFromInt(self.ast.extra_data.items[ss + si]);
                if (spec_i.isNone()) continue;
                const spec = self.ast.getNode(spec_i);
                if (spec.tag != .export_specifier) continue;
                const local_i = spec.data.binary.left;
                if (local_i.isNone()) continue;
                try exported_locals.append(self.allocator, self.ast.getNode(local_i).span);
            }
        }
    }

    // wrap target 수집 (visit 하여 기본 변환 적용)
    const body_stmts_top = self.scratch.items.len;
    // 함수 대입을 먼저 — 선언 호이스팅과 등가가 되도록 본문 맨 위에 둔다.
    for (hoisted_assigns.items) |h| try self.scratch.append(self.allocator, h);
    i = 0;
    while (i < list.len) : (i += 1) {
        const child: NodeIndex = @enumFromInt(self.ast.extra_data.items[list.start + i]);
        const child_node = self.ast.getNode(child);
        if (child_node.tag == .import_declaration or child_node.tag == .ts_import_equals_declaration) continue;
        if (isModuleDeclaration(child_node.tag)) {
            // 분해된 export 라면 **이 자리에** 대입문을 넣는다.
            for (split_src.items, 0..) |sc, si| {
                if (sc != child) continue;
                const from = split_assign_off.items[si];
                const to = split_assign_off.items[si + 1];
                for (split_assigns.items[from..to]) |a| try self.scratch.append(self.allocator, a);
                break;
            }
            continue;
        }
        if (exported_locals.items.len > 0) {
            var local_assigns: std.ArrayListUnmanaged(NodeIndex) = .empty;
            defer local_assigns.deinit(self.allocator);
            if (try splitLocalDeclForExport(
                Transformer,
                self,
                child_node,
                exported_locals.items,
                &extra_outer,
                &local_assigns,
            )) {
                for (local_assigns.items) |a| try self.scratch.append(self.allocator, a);
                continue;
            }
        }
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

    // (arrow)() — 호출 (arrow 는 call-target 위치에서 codegen 이 자동 wrap)
    const call = try es_helpers.makeCallExpr(self, arrow, &.{}, node.span);
    const iife_stmt = try es_helpers.makeExprStmt(self, call, node.span);

    // async/await lowering 이 이 arrow 에 적용되어야 하므로 재방문이 필요한 경우가 있지만,
    // `visitNode` 는 자식 재방문을 내부적으로 처리한다. 우리는 arrow 를 top-down dispatch 에
    // 다시 넣기 위해 expression_statement 를 visit.
    const visited_iife = try self.visitNode(iife_stmt);

    // 최종 program list: [imports...] + [visited_iife] + [exports...]
    // 현재 scratch 에는 [imports_end..body_stmts_end] 까지 wrap 대상이 있으므로
    // body_stmts_top 이후를 drop 하고 새 리스트를 구성.
    self.scratch.shrinkRetainingCapacity(imports_end);
    // `var _t;` 는 IIFE **앞** — 래퍼 안 대입이 이 바인딩에 닿아야 한다.
    for (extra_outer.items) |o| try self.scratch.append(self.allocator, o);
    if (!visited_iife.isNone()) try self.scratch.append(self.allocator, visited_iife);

    // exports pass-through
    i = 0;
    while (i < list.len) : (i += 1) {
        const child: NodeIndex = @enumFromInt(self.ast.extra_data.items[list.start + i]);
        const child_node = self.ast.getNode(child);
        if (child_node.tag == .import_declaration or child_node.tag == .ts_import_equals_declaration) continue;
        if (!isModuleDeclaration(child_node.tag)) continue;
        // 분해된 export 는 원본 대신 `export var X;` 를 내보낸다 (초기화는 래퍼 안).
        var replaced = false;
        for (split_src.items, 0..) |sc, si| {
            if (sc != child) continue;
            try self.scratch.append(self.allocator, split_export.items[si]);
            replaced = true;
            break;
        }
        if (replaced) continue;
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
