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
/// TLA 래퍼 안으로 들어가는 최상위 문장들이 **선언하는 이름**을 모은다 (#4598).
///
/// export 초기화식이 이 중 하나를 참조하면, 그 export 만 분해해야 한다. 무조건 분해하면
/// 래퍼 로컬을 안 건드리는 export(`export const VERSION = "1.0"`)까지 지연돼 import 시점에
/// 읽는 소비자가 `undefined` 를 본다 — 2차 시도가 이걸로 폐기됐다.
fn collectWrappedDeclNames(
    self: anytype,
    list: anytype,
    out: *std.ArrayListUnmanaged(Span),
) !void {
    var i: u32 = 0;
    while (i < list.len) : (i += 1) {
        const child: NodeIndex = @enumFromInt(self.ast.extra_data.items[list.start + i]);
        const n = self.ast.getNode(child);
        if (n.tag == .import_declaration or n.tag == .ts_import_equals_declaration) continue;
        if (isModuleDeclaration(n.tag)) continue; // 래퍼 밖에 남는다
        switch (n.tag) {
            .variable_declaration => {
                const ve = n.data.extra;
                if (ve + 2 >= self.ast.extra_data.items.len) continue;
                const ds = self.ast.extra_data.items[ve + 1];
                const dl = self.ast.extra_data.items[ve + 2];
                var di: u32 = 0;
                while (di < dl) : (di += 1) {
                    const dtor = self.ast.getNode(@as(NodeIndex, @enumFromInt(self.ast.extra_data.items[ds + di])));
                    if (dtor.tag != .variable_declarator) continue;
                    const b = self.ast.getNode(@as(NodeIndex, @enumFromInt(self.ast.extra_data.items[dtor.data.extra])));
                    if (b.tag == .binding_identifier) try out.append(self.allocator, b.span);
                }
            },
            .function_declaration, .class_declaration => {
                const name_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[n.data.extra]);
                if (!name_idx.isNone()) try out.append(self.allocator, self.ast.getNode(name_idx).span);
            },
            else => {},
        }
    }
}

/// `root` 하위에 `names` 중 하나와 같은 이름의 식별자가 등장하는지 (#4598).
///
/// ⚠️ 스코프를 보지 않는 **보수적 근사**다 — 안쪽 스코프가 같은 이름을 가려도 "참조함" 으로
/// 친다. 과다 판정은 분해를 더 하는 쪽(= 원래 고치려던 방향)이라 안전하고, 과소 판정이라야
/// 위험한데 이름 일치 검사는 과소가 될 수 없다.
const RefCtx = struct {
    ast: *const ast_mod.Ast,
    names: []const Span,
    hit: bool = false,
};

fn refVisit(c: *RefCtx, idx: NodeIndex, node: Node) ast_walk.WalkAction {
    _ = idx;
    switch (node.tag) {
        .identifier_reference, .jsx_identifier, .binding_identifier => {
            const t = c.ast.getSourceText(node.span);
            for (c.names) |nm| {
                if (std.mem.eql(u8, t, c.ast.getText(nm))) {
                    c.hit = true;
                    return .stop;
                }
            }
        },
        else => {},
    }
    return .descend;
}

fn referencesAnyName(self: anytype, root: NodeIndex, names: []const Span) bool {
    if (names.len == 0) return false;
    var c = RefCtx{ .ast = self.ast, .names = names };
    // 실패 시 보수적으로 "참조함" — 분해를 더 하는 쪽이 안전한 방향이다.
    ast_walk.walkPreorderIterative(self.allocator, self.ast, root, &c, refVisit) catch return true;
    return c.hit;
}

/// `export const/let/var X = init;` 을 `export var X;`(밖) + `X = init;`(래퍼 안 원위치) 로
/// 분해한다 (#4598).
///
/// ⚠️ **호출 조건이 좁다** — 2차 시도가 무조건 분해해서 폐기됐다:
///   1. ESM 출력에서만 (CJS 는 `exports.X` 스냅샷이라 분해가 무효 → 크래시가 조용한 오답이 됨)
///   2. `const/let/var` 만 (function 은 모듈 instantiation 호이스팅, class/named FE 는
///      자기바인딩 불변성 때문에 이 방식으로 못 옮긴다)
///   3. **초기화식이 래퍼 안 바인딩을 참조할 때만** (아니면 import 시점 읽기가 깨진다)
///
/// 반환: 밖에 둘 `export var …;`. 분해 대상이 아니면 null.
fn splitExportedVarDecl(
    comptime Transformer: type,
    self: *Transformer,
    export_node: Node,
    wrapped_names: []const Span,
    assigns: *std.ArrayListUnmanaged(NodeIndex),
) Transformer.Error!?NodeIndex {
    const e = export_node.data.extra;
    if (e + 5 >= self.ast.extra_data.items.len) return null;
    const decl_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[e]);
    const specs_start = self.ast.extra_data.items[e + 1];
    const specs_len = self.ast.extra_data.items[e + 2];
    const source_raw = self.ast.extra_data.items[e + 3];
    // ⚠️ 6슬롯이다 — attrs 를 빠뜨리면 `readExportNamedExtras` 가 인접 extra_data 를 읽는다.
    const attrs_start = self.ast.extra_data.items[e + 4];
    const attrs_len = self.ast.extra_data.items[e + 5];
    if (!@as(NodeIndex, @enumFromInt(source_raw)).isNone()) return null;
    if (decl_idx.isNone()) return null;

    const decl_node = self.ast.getNode(decl_idx);
    if (decl_node.tag != .variable_declaration) return null;
    const ve = decl_node.data.extra;
    if (ve + 2 >= self.ast.extra_data.items.len) return null;
    // `using` / `await using` 은 `var` 로 강등하면 dispose 가 사라진다 — 건드리지 않는다.
    const kind: ast_mod.VariableDeclarationKind = @enumFromInt(self.ast.extra_data.items[ve]);
    switch (kind) {
        .@"var", .let, .@"const" => {},
        else => return null,
    }
    const decls_start = self.ast.extra_data.items[ve + 1];
    const decls_len = self.ast.extra_data.items[ve + 2];

    // 전 declarator 사전 검사 — 하나라도 부적격이면 **아무것도 하지 않고** 빠진다.
    // (2차 시도는 append 후에 bail 해서 고아 대입이 앞 범위로 흘렀다.)
    var any_ref = false;
    var di: u32 = 0;
    while (di < decls_len) : (di += 1) {
        const dtor = self.ast.getNode(@as(NodeIndex, @enumFromInt(self.ast.extra_data.items[decls_start + di])));
        if (dtor.tag != .variable_declarator) return null;
        const de = dtor.data.extra;
        if (de + 2 >= self.ast.extra_data.items.len) return null;
        const b = self.ast.getNode(@as(NodeIndex, @enumFromInt(self.ast.extra_data.items[de])));
        if (b.tag != .binding_identifier) return null; // 구조분해 제외
        const init_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[de + 2]);
        if (!init_idx.isNone() and referencesAnyName(self, init_idx, wrapped_names)) any_ref = true;
    }
    if (!any_ref) return null; // 래퍼 로컬을 안 건드리면 그대로 둔다

    const scratch_top = self.scratch.items.len;
    defer self.scratch.shrinkRetainingCapacity(scratch_top);
    const assigns_top = assigns.items.len;
    errdefer assigns.shrinkRetainingCapacity(assigns_top);

    di = 0;
    while (di < decls_len) : (di += 1) {
        const dtor_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[decls_start + di]);
        const dtor = self.ast.getNode(dtor_idx);
        const de = dtor.data.extra;
        const binding = self.ast.getNode(@as(NodeIndex, @enumFromInt(self.ast.extra_data.items[de])));
        const init_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[de + 2]);

        const bare_binding = try es_helpers.makeBindingIdentifier(self, binding.span);
        try self.scratch.append(self.allocator, try es_helpers.makeDeclarator(self, bare_binding, NodeIndex.none, dtor.span));

        if (!init_idx.isNone()) {
            const target = try es_helpers.makeIdentifierRefFromSpan(self, binding.span);
            const visited_init = try self.visitNode(init_idx);
            if (visited_init.isNone()) return null;
            const assign = try es_helpers.makeAssignExpr(self, target, visited_init, dtor.span, 0);
            try assigns.append(self.allocator, try es_helpers.makeExprStmt(self, assign, dtor.span));
        }
    }

    const new_decl = try es_helpers.makeVarDeclaration(self, self.scratch.items[scratch_top..], .@"var", decl_node.span);
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

    // #4598: export 분해 준비. **ESM 출력에서만** 한다 — CJS/UMD/IIFE 는 선언 시점에
    // `exports.X` 로 스냅샷하므로 래퍼 안 대입이 도달하지 않아, 시끄러운 `ReferenceError` 가
    // 조용한 `undefined` 로 바뀐다.
    var wrapped_names: std.ArrayListUnmanaged(Span) = .empty;
    defer wrapped_names.deinit(self.allocator);
    var split_src: std.ArrayListUnmanaged(NodeIndex) = .empty;
    defer split_src.deinit(self.allocator);
    var split_export: std.ArrayListUnmanaged(NodeIndex) = .empty;
    defer split_export.deinit(self.allocator);
    var split_off: std.ArrayListUnmanaged(u32) = .empty;
    defer split_off.deinit(self.allocator);
    var split_assigns: std.ArrayListUnmanaged(NodeIndex) = .empty;
    defer split_assigns.deinit(self.allocator);
    if (self.options.output_is_esm) {
        try collectWrappedDeclNames(self, list, &wrapped_names);
        var ei: u32 = 0;
        while (ei < list.len) : (ei += 1) {
            const child: NodeIndex = @enumFromInt(self.ast.extra_data.items[list.start + ei]);
            const cn = self.ast.getNode(child);
            if (cn.tag != .export_named_declaration) continue;
            const before: u32 = @intCast(split_assigns.items.len);
            const split = try splitExportedVarDecl(Transformer, self, cn, wrapped_names.items, &split_assigns) orelse continue;
            try split_src.append(self.allocator, child);
            try split_export.append(self.allocator, split);
            try split_off.append(self.allocator, before);
        }
        try split_off.append(self.allocator, @intCast(split_assigns.items.len));
    }

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
        if (isModuleDeclaration(child_node.tag)) {
            // 분해된 export 라면 **원래 자리에** 대입문을 넣는다 (끝에 몰면 앞에서 읽는 코드가
            // `undefined` 를 본다).
            for (split_src.items, 0..) |sc, si| {
                if (sc != child) continue;
                for (split_assigns.items[split_off.items[si]..split_off.items[si + 1]]) |a| {
                    try self.scratch.append(self.allocator, a);
                }
                break;
            }
            continue;
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
    if (!visited_iife.isNone()) try self.scratch.append(self.allocator, visited_iife);

    // exports pass-through
    i = 0;
    while (i < list.len) : (i += 1) {
        const child: NodeIndex = @enumFromInt(self.ast.extra_data.items[list.start + i]);
        const child_node = self.ast.getNode(child);
        if (child_node.tag == .import_declaration or child_node.tag == .ts_import_equals_declaration) continue;
        if (!isModuleDeclaration(child_node.tag)) continue;
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
