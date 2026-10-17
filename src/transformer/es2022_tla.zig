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
//! - 첫 await 뒤의 최상위 선언은 바인딩만 래퍼 앞(`var x;`)으로 빼고 래퍼 안에서
//!   소스 순서대로 대입한다(webpack async module 과 같은 모양, #5575). 래퍼 밖의
//!   함수·export·뒤 모듈이 같은 바인딩을 본다. 래퍼에 남는 이름(중첩 `var`, 지역
//!   바인딩)을 읽지 않는 함수 선언은 래퍼 앞으로 끌어올린다 — 네이티브처럼 await 앞
//!   코드가 호출할 수 있다.
//! - 번들이 래퍼 promise 를 기다리면(`tla_module_awaited`, 단일 파일 ESM 출력) 첫
//!   await 뒤의 export 선언·`export default <식>` 도 래퍼 안에서 순서대로 초기화한다.
//!   기다릴 수단이 없는 출력(cjs/iife)은 export 를 래퍼 뒤에 둔다 — importer 가 바로
//!   값을 읽는다.
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
const ScopeId = @import("../semantic/scope.zig").ScopeId;

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

const NameSet = std.StringHashMapUnmanaged(void);

/// 이름 수집용 walk 컨텍스트. `opaque_names` 는 이름만으로 판정할 수 없는 경우
/// (escape 된 식별자, direct eval) — 그런 래퍼는 함수를 끌어올리지 않는다.
const NameCollectCtx = struct {
    ast: *const ast_mod.Ast,
    allocator: std.mem.Allocator,
    names: *NameSet,
    tag: Tag,
    opaque_names: bool = false,
    oom: bool = false,
};

fn nameCollectVisit(ctx: *NameCollectCtx, idx: NodeIndex, node: Node) ast_walk.WalkAction {
    _ = idx;
    const matches = switch (ctx.tag) {
        .binding_identifier => node.tag == .binding_identifier,
        else => node.tag == .identifier_reference or node.tag == .assignment_target_identifier or node.tag == .jsx_identifier,
    };
    if (!matches) return .descend;
    const name = ctx.ast.identifierNameText(node);
    if (std.mem.indexOfScalar(u8, name, '\\') != null or std.mem.eql(u8, name, "eval")) {
        ctx.opaque_names = true;
        return .stop;
    }
    ctx.names.put(ctx.allocator, name, {}) catch {
        ctx.oom = true;
        return .stop;
    };
    return .descend;
}

/// `root` 서브트리의 `tag`(binding 또는 reference) 식별자 이름을 `names` 에 모은다.
/// 이름만으로 판정할 수 없으면 false.
fn collectNames(ast: *const ast_mod.Ast, allocator: std.mem.Allocator, root: NodeIndex, tag: Tag, names: *NameSet) std.mem.Allocator.Error!bool {
    var ctx = NameCollectCtx{ .ast = ast, .allocator = allocator, .names = names, .tag = tag };
    try ast_walk.walkPreorderIterative(ast.allocator, ast, root, &ctx, nameCollectVisit);
    if (ctx.oom) return error.OutOfMemory;
    return !ctx.opaque_names;
}

/// Names a top-level statement declares in the program scope: the bindings of
/// a variable declaration's declarators and a class declaration's name.
fn collectTopLevelDeclaredNames(ast: *const ast_mod.Ast, allocator: std.mem.Allocator, stmt: NodeIndex, names: *NameSet) std.mem.Allocator.Error!bool {
    const node = ast.getNode(stmt);
    switch (node.tag) {
        .variable_declaration => {
            const e = node.data.extra;
            const start = ast.extra_data.items[e + 1];
            const len = ast.extra_data.items[e + 2];
            var i: u32 = 0;
            while (i < len) : (i += 1) {
                const declarator = ast.getNode(@fromBackingInt(@intCast(ast.extra_data.items[start + i])));
                const binding: NodeIndex = @fromBackingInt(@intCast(ast.extra_data.items[declarator.data.extra]));
                if (!binding.isNone() and !try collectNames(ast, allocator, binding, .binding_identifier, names)) return false;
            }
            return true;
        },
        .class_declaration => {
            const name = ast.readExtraNode(node.data.extra, ast_mod.ClassExtra.name);
            if (!name.isNone()) try names.put(allocator, ast.identifierNameText(ast.getNode(name)), {});
            return true;
        },
        else => return true,
    }
}

/// 첫 top-level await 뒤의 함수 선언 중 래퍼 앞으로 끌어올려도 되는 것을 고른다.
///
/// 네이티브 모듈에서 함수 선언은 모듈 평가 전에 초기화되므로, await 앞 코드도 await
/// 뒤에 선언된 함수를 호출할 수 있다. 래퍼 안에 두면 앞 코드에서 보이지 않는다
/// (`ReferenceError`, #5575). 래퍼에 선언된 바인딩(변수·클래스·끌어올리지 못한 함수)을
/// 이름으로 하나라도 읽는 함수는 래퍼 밖에서 그 바인딩을 볼 수 없으므로 그대로 둔다.
/// 판정은 이름 기준이라 보수적이다 — 같은 이름의 지역 변수만 있어도 남긴다.
///
/// `hoist_bindings`: the wrapper's top-level declarations move ahead of it
/// (`WrappedBindings`), so only names left inside it — a nested `var`, a
/// local binding — keep a function in the wrapper.
fn collectHoistableFunctions(
    ast: *const ast_mod.Ast,
    allocator: std.mem.Allocator,
    list: ast_mod.NodeList,
    hoist_bindings: bool,
    out: *std.AutoHashMapUnmanaged(u32, void),
) std.mem.Allocator.Error!void {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const Candidate = struct { idx: NodeIndex, name: []const u8, refs: NameSet, hoistable: bool };
    var candidates: std.ArrayList(Candidate) = .empty;
    var blocked: NameSet = .empty;
    var started = false;
    var i: u32 = 0;
    while (i < list.len) : (i += 1) {
        const child: NodeIndex = @fromBackingInt(@intCast(ast.extra_data.items[list.start + i]));
        const child_node = ast.getNode(child);
        if (isModuleDeclaration(child_node.tag)) continue;
        if (!started) {
            if (!try hasTopLevelAwait(ast, child)) continue;
            started = true;
        }
        if (child_node.tag == .function_declaration) {
            const e = child_node.data.extra;
            const name_idx = ast.readExtraNode(e, ast_mod.FunctionExtra.name);
            const body_idx = ast.readExtraNode(e, ast_mod.FunctionExtra.body);
            if (!name_idx.isNone() and !body_idx.isNone()) {
                const name = ast.identifierNameText(ast.getNode(name_idx));
                var refs: NameSet = .empty;
                const hoistable = std.mem.indexOfScalar(u8, name, '\\') == null and
                    try collectNames(ast, arena, child, .identifier_reference, &refs);
                try candidates.append(arena, .{ .idx = child, .name = name, .refs = refs, .hoistable = hoistable });
                if (!hoistable) try blocked.put(arena, name, {});
                continue;
            }
        }
        if (!hoist_bindings) {
            if (!try collectNames(ast, arena, child, .binding_identifier, &blocked)) return;
            continue;
        }
        var local: NameSet = .empty;
        if (!try collectNames(ast, arena, child, .binding_identifier, &local)) return;
        var declared: NameSet = .empty;
        if (!try collectTopLevelDeclaredNames(ast, arena, child, &declared)) return;
        var it = local.keyIterator();
        while (it.next()) |name| {
            if (!declared.contains(name.*)) try blocked.put(arena, name.*, {});
        }
    }

    // 래퍼 안에 같은 이름의 선언이 남는 함수(`var f` + `function f`)와, 끌어올리지
    // 못한 함수를 읽는 함수도 끌어올릴 수 없다 — 고정점까지 반복.
    var changed = true;
    while (changed) {
        changed = false;
        for (candidates.items) |*c| {
            if (!c.hoistable) continue;
            if (blocked.contains(c.name)) {
                c.hoistable = false;
                changed = true;
                continue;
            }
            var it = c.refs.keyIterator();
            while (it.next()) |ref| {
                if (!blocked.contains(ref.*)) continue;
                c.hoistable = false;
                try blocked.put(arena, c.name, {});
                changed = true;
                break;
            }
        }
    }
    for (candidates.items) |c| {
        if (c.hoistable) try out.put(allocator, @backingInt(c.idx), {});
    }
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

/// #5575: like webpack's async module, a binding the async wrapper would
/// declare is declared ahead of it instead (`var x;`, or `export var x;`) and
/// the wrapper assigns it in source order. Code outside the wrapper — hoisted
/// functions, exports, the modules after this one — reads that binding, which a
/// declaration inside the wrapper hid (`export function f() { return config }`
/// threw `config is not defined`).
const WrappedBindings = struct {
    /// Binding nodes declared with `var` ahead of the wrapper.
    locals: std.ArrayList(NodeIndex) = .empty,
    /// Binding nodes declared with `export var` ahead of the wrapper.
    exported: std.ArrayList(NodeIndex) = .empty,

    fn deinit(self: *WrappedBindings, allocator: std.mem.Allocator) void {
        self.locals.deinit(allocator);
        self.exported.deinit(allocator);
    }

    fn list(self: *WrappedBindings, exported: bool) *std.ArrayList(NodeIndex) {
        return if (exported) &self.exported else &self.locals;
    }
};

/// The program scope, when the module carries the semantic data that tells a
/// source binding from a generated temp. Without it nothing is hoisted.
fn programScopeForHoist(comptime Transformer: type, self: *Transformer) ?ScopeId {
    if (self.symbols.len == 0 and self.semantic_editor == null) return null;
    if (self.parser_node_count == 0) return null;
    const raw = self.scope_owner_map.get(self.parser_node_count - 1) orelse return null;
    return @fromBackingInt(@intCast(raw));
}

fn isProgramBinding(comptime Transformer: type, self: *Transformer, binding: NodeIndex, program_scope: ScopeId) bool {
    if (binding.isNone() or self.ast.getNode(binding).tag != .binding_identifier) return false;
    const raw = self.getSymbolIdAt(binding) orelse return false;
    const symbols = if (self.semantic_editor) |*editor| editor.symbols.items else self.symbols;
    if (raw >= symbols.len) return false;
    return symbols[raw].scope_id == program_scope;
}

/// Collects every identifier a binding (pattern) declares. False when one of
/// them is not a source binding of the program scope (a lowering temp).
fn collectProgramBindings(comptime Transformer: type, self: *Transformer, idx: NodeIndex, program_scope: ScopeId, out: *std.ArrayList(NodeIndex)) Transformer.Error!bool {
    if (idx.isNone()) return true;
    const node = self.ast.getNode(idx);
    switch (node.tag) {
        .binding_identifier => {
            if (!isProgramBinding(Transformer, self, idx, program_scope)) return false;
            try out.append(self.allocator, idx);
            return true;
        },
        .object_pattern, .array_pattern => {
            const split = self.ast.nodeListSplitRest(node.data.list);
            const elements = try self.allocator.dupe(u32, split.elements);
            defer self.allocator.free(elements);
            for (elements) |raw| {
                const elem: NodeIndex = @fromBackingInt(@intCast(raw));
                if (elem.isNone()) continue;
                const elem_node = self.ast.getNode(elem);
                const target = switch (elem_node.tag) {
                    .elision => continue,
                    .binding_property => elem_node.data.binary.right,
                    else => elem,
                };
                if (!try collectProgramBindings(Transformer, self, target, program_scope, out)) return false;
            }
            if (split.rest_operand) |rest| return collectProgramBindings(Transformer, self, rest, program_scope, out);
            return true;
        },
        .assignment_pattern => return collectProgramBindings(Transformer, self, node.data.binary.left, program_scope, out),
        .rest_element, .binding_rest_element => return collectProgramBindings(Transformer, self, node.data.unary.operand, program_scope, out),
        else => return false,
    }
}

/// A write of a hoisted source binding from inside the wrapper.
fn bindingWriteTarget(comptime Transformer: type, self: *Transformer, binding: NodeIndex) Transformer.Error!NodeIndex {
    const target = try self.makeIdentifierRefWithSymbol(self.ast.getNode(binding).data.string_ref, binding);
    if (self.getSymbolIdAt(binding) != null) try self.trackUserWriteFromBinding(target, binding, self.current_scope);
    return target;
}

/// `<kind> a = 1, [b] = c, _t = d` → `a = 1;` `(_r = c, b = _r[0], _r);` with
/// `a`, `b` declared ahead of the wrapper. A generated temp keeps its
/// declaration inside the wrapper, in its place.
fn splitWrappedDeclaration(comptime Transformer: type, self: *Transformer, decl_idx: NodeIndex, exported: bool, program_scope: ScopeId, bindings: *WrappedBindings, body: *std.ArrayList(NodeIndex)) Transformer.Error!void {
    const decl = self.ast.getNode(decl_idx);
    const e = decl.data.extra;
    const kind: ast_mod.VariableDeclarationKind = @fromBackingInt(@intCast(self.ast.extra_data.items[e]));
    const list_start = self.ast.extra_data.items[e + 1];
    const list_len = self.ast.extra_data.items[e + 2];
    var kept: std.ArrayList(NodeIndex) = .empty;
    defer kept.deinit(self.allocator);
    var names: std.ArrayList(NodeIndex) = .empty;
    defer names.deinit(self.allocator);
    var i: u32 = 0;
    while (i < list_len) : (i += 1) {
        const declarator_idx: NodeIndex = @fromBackingInt(@intCast(self.ast.extra_data.items[list_start + i]));
        const declarator = self.ast.getNode(declarator_idx);
        const binding: NodeIndex = @fromBackingInt(@intCast(self.ast.extra_data.items[declarator.data.extra]));
        const init: NodeIndex = @fromBackingInt(@intCast(self.ast.extra_data.items[declarator.data.extra + 2]));
        names.clearRetainingCapacity();
        // A lowering temp (`_ref` of a lowered pattern, even in an export)
        // keeps its declaration inside the wrapper.
        if (!try collectProgramBindings(Transformer, self, binding, program_scope, &names)) {
            try kept.append(self.allocator, declarator_idx);
            continue;
        }
        if (kept.items.len > 0) {
            try body.append(self.allocator, try es_helpers.makeVarDeclaration(self, kept.items, kind, decl.span));
            kept.clearRetainingCapacity();
        }
        try bindings.list(exported).appendSlice(self.allocator, names.items);
        if (init.isNone()) continue;
        const binding_node = self.ast.getNode(binding);
        const expr = if (binding_node.tag == .binding_identifier)
            try es_helpers.makeAssignExpr(self, try bindingWriteTarget(Transformer, self, binding), init, declarator.span, 0)
        else
            try @import("es2015_destructuring.zig").ES2015Destructuring(Transformer).lowerBindingPatternAssignment(self, binding_node, init, declarator.span);
        try body.append(self.allocator, try es_helpers.makeExprStmt(self, expr, declarator.span));
    }
    if (kept.items.len > 0) try body.append(self.allocator, try es_helpers.makeVarDeclaration(self, kept.items, kind, decl.span));
}

/// `class C {}` → `C = class {}` with `C` declared ahead of the wrapper (the
/// assignment names the class). False when the class keeps its declaration.
fn splitWrappedClass(comptime Transformer: type, self: *Transformer, class_idx: NodeIndex, exported: bool, program_scope: ScopeId, bindings: *WrappedBindings, body: *std.ArrayList(NodeIndex)) Transformer.Error!bool {
    const class = self.ast.getNode(class_idx);
    var slots: [8]u32 = undefined;
    for (0..slots.len) |slot| slots[slot] = self.ast.extra_data.items[class.data.extra + slot];
    const name: NodeIndex = @fromBackingInt(@intCast(slots[ast_mod.ClassExtra.name]));
    if (!isProgramBinding(Transformer, self, name, program_scope)) return false;
    slots[ast_mod.ClassExtra.name] = @backingInt(NodeIndex.none);
    const expr_extra = try self.ast.addExtras(&slots);
    const expr = try self.ast.addNode(.{ .tag = .class_expression, .span = class.span, .data = .{ .extra = expr_extra } });
    if (self.semantic_edit_enabled) try self.remapCopiedScopeOwner(class_idx, expr);
    const assign = try es_helpers.makeAssignExpr(self, try bindingWriteTarget(Transformer, self, name), expr, class.span, 0);
    try body.append(self.allocator, try es_helpers.makeExprStmt(self, assign, class.span));
    try bindings.list(exported).append(self.allocator, name);
    return true;
}

/// Places one visited statement from after the first await: a function
/// declaration `collectHoistableFunctions` chose (`hoist_function`) and an
/// exported one ahead of the wrapper, declarations split by `splitWrapped*`,
/// export lists after the wrapper, and the rest inside it.
fn placeWrappedStatement(comptime Transformer: type, self: *Transformer, stmt: NodeIndex, hoist_function: bool, program_scope: ScopeId, bindings: *WrappedBindings, prelude: *std.ArrayList(NodeIndex), body: *std.ArrayList(NodeIndex), post: *std.ArrayList(NodeIndex)) Transformer.Error!void {
    const node = self.ast.getNode(stmt);
    switch (node.tag) {
        .function_declaration => try (if (hoist_function) prelude else body).append(self.allocator, stmt),
        .variable_declaration => try splitWrappedDeclaration(Transformer, self, stmt, false, program_scope, bindings, body),
        .class_declaration => if (!try splitWrappedClass(Transformer, self, stmt, false, program_scope, bindings, body)) try body.append(self.allocator, stmt),
        .export_named_declaration => {
            const declaration: NodeIndex = @fromBackingInt(@intCast(self.ast.extra_data.items[node.data.extra]));
            if (declaration.isNone()) return post.append(self.allocator, stmt);
            switch (self.ast.getNode(declaration).tag) {
                .variable_declaration => try splitWrappedDeclaration(Transformer, self, declaration, true, program_scope, bindings, body),
                .class_declaration => if (!try splitWrappedClass(Transformer, self, declaration, true, program_scope, bindings, body)) try post.append(self.allocator, stmt),
                else => try prelude.append(self.allocator, stmt),
            }
        },
        else => if (isModuleDeclaration(node.tag)) try post.append(self.allocator, stmt) else try body.append(self.allocator, stmt),
    }
}

/// `export default <expr>` after the first await → `_default = <expr>;` in
/// the wrapper, with `var _default;` ahead of it and
/// `export { _default as default }` after it (the `using` lowering's facade).
/// A function or class keeps its declaration: hoisted, or named `default`.
fn moveDefaultExport(comptime Transformer: type, self: *Transformer, stmt: NodeIndex, program_scope: ScopeId, bindings: *WrappedBindings, body: *std.ArrayList(NodeIndex), post: *std.ArrayList(NodeIndex)) Transformer.Error!bool {
    const node = self.ast.getNode(stmt);
    const operand = node.data.unary.operand;
    switch (self.ast.getNode(operand).tag) {
        .function_declaration, .class_declaration, .function_expression, .arrow_function_expression, .class_expression => return false,
        else => {},
    }
    var n: u32 = 1;
    const name = while (true) : (n += 1) {
        const candidate = if (n == 1) try self.allocator.dupe(u8, "_default") else try std.fmt.allocPrint(self.allocator, "_default{d}", .{n});
        if (!try es_helpers.nameAppearsInSource(self, candidate)) break candidate;
        self.allocator.free(candidate);
    };
    defer self.allocator.free(name);
    const name_span = try self.ast.addString(name);
    const binding = try es_helpers.makeSyntheticBinding(self, name_span);
    if (self.semantic_edit_enabled) {
        if (std.mem.eql(u8, name, "_default")) {
            const raw_id = self.getSymbolIdAt(stmt) orelse std.debug.panic("default export facade has no SymbolId", .{});
            try self.setGeneratedSymbolId(binding, raw_id);
            try self.ensureSymbolDeclarationAtNode(raw_id, program_scope, binding);
        } else {
            _ = try self.declareSyntheticInScope(binding, node.span, .variable_var, program_scope);
        }
    }
    const binding_span = self.ast.getNode(binding).data.string_ref;

    const pt = self.pending_nodes.items.len;
    const tt = self.trailing_nodes.items.len;
    const value = try self.visitNode(operand);
    const target = try self.makeIdentifierRefWithSymbol(binding_span, binding);
    if (self.getSymbolIdAt(binding) != null) try self.trackUserWriteFromBinding(target, binding, self.current_scope);
    const assign = try es_helpers.makeExprStmt(self, try es_helpers.makeAssignExpr(self, target, value, node.span, 0), node.span);
    try drainPendingAroundTo(Transformer, self, pt, tt, assign, body);
    try bindings.locals.append(self.allocator, binding);

    const local_ref = try self.makeIdentifierRefWithSymbol(binding_span, binding);
    if (self.getSymbolIdAt(binding) != null) try self.trackUserReadFromBinding(local_ref, binding, program_scope);
    const spec = try self.ast.addNode(.{
        .tag = .export_specifier,
        .span = node.span,
        .data = .{ .binary = .{ .left = local_ref, .right = try es_helpers.makePropertyName(self, "default"), .flags = 0 } },
    });
    const specs = try self.ast.addNodeList(&.{spec});
    const none = @backingInt(NodeIndex.none);
    try post.append(self.allocator, try self.addExtraNode(.export_named_declaration, node.span, &.{ none, specs.start, specs.len, none, 0, 0 }));
    return true;
}

/// `var a, b;` / `export var c;` for the bindings the wrapper assigns.
fn appendHoistedDeclarations(comptime Transformer: type, self: *Transformer, bindings: *WrappedBindings, span: Span, out: *std.ArrayList(NodeIndex)) Transformer.Error!void {
    for ([_]bool{ false, true }) |exported| {
        const names = bindings.list(exported).items;
        if (names.len == 0) continue;
        const declarators = try self.allocator.alloc(NodeIndex, names.len);
        defer self.allocator.free(declarators);
        for (names, declarators) |name, *declarator| declarator.* = try es_helpers.makeDeclarator(self, name, .none, span);
        const decl = try es_helpers.makeVarDeclaration(self, declarators, .@"var", span);
        if (!exported) {
            try out.append(self.allocator, decl);
            continue;
        }
        const none = @backingInt(NodeIndex.none);
        try out.append(self.allocator, try self.addExtraNode(.export_named_declaration, span, &.{ @backingInt(decl), 0, 0, none, 0, 0 }));
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
        const child: NodeIndex = @fromBackingInt(@intCast(self.ast.extra_data.items[list.start + i]));
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
        const child: NodeIndex = @fromBackingInt(@intCast(self.ast.extra_data.items[list.start + i]));
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
        @backingInt(empty_params_node),
        @backingInt(NodeIndex.none),
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
    // Function declarations after the first await that read no wrapped
    // binding move ahead of the wrapper: they are initialized before the
    // module runs, so earlier code may call them (#5575).
    var hoisted_functions: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer hoisted_functions.deinit(self.allocator);
    // #5575: with semantic data, the wrapper's bindings are declared ahead of
    // it (`WrappedBindings`); without, its declarations stay inside.
    const program_scope = programScopeForHoist(Transformer, self);
    try collectHoistableFunctions(self.ast, self.allocator, list, program_scope != null, &hoisted_functions);
    var bindings: WrappedBindings = .{};
    defer bindings.deinit(self.allocator);
    var post_exports: std.ArrayList(NodeIndex) = .empty;
    defer post_exports.deinit(self.allocator);
    var moved: std.ArrayList(NodeIndex) = .empty;
    defer moved.deinit(self.allocator);
    i = 0;
    while (i < list.len) : (i += 1) {
        const child: NodeIndex = @fromBackingInt(@intCast(self.ast.extra_data.items[list.start + i]));
        const child_node = self.ast.getNode(child);
        if (child_node.tag == .import_declaration or child_node.tag == .ts_import_equals_declaration) continue;
        if (isModuleDeclaration(child_node.tag)) {
            if (wrapper_started) {
                // When the bundle waits for the wrapper, an export declaration
                // after the first await runs inside it in source order, like
                // a native module; its binding stays outside. Otherwise it
                // keeps its place after the wrapper so importers that run
                // right away still see a value.
                const scope = program_scope orelse continue;
                if (!self.options.tla_module_awaited) continue;
                if (child_node.tag == .export_default_declaration) {
                    if (try moveDefaultExport(Transformer, self, child, scope, &bindings, &self.scratch, &post_exports))
                        try prelude_exports.put(self.allocator, @backingInt(child), {});
                    continue;
                }
                if (child_node.tag != .export_named_declaration) continue;
                if (self.ast.extra_data.items[child_node.data.extra] == @backingInt(NodeIndex.none)) continue;
                const pt = self.pending_nodes.items.len;
                const tt = self.trailing_nodes.items.len;
                const visited = try self.visitNode(child);
                moved.clearRetainingCapacity();
                try drainPendingAroundTo(Transformer, self, pt, tt, visited, &moved);
                for (moved.items) |stmt| try placeWrappedStatement(Transformer, self, stmt, true, scope, &bindings, &prelude_stmts, &self.scratch, &post_exports);
                try prelude_exports.put(self.allocator, @backingInt(child), {});
                continue;
            }
            const pt = self.pending_nodes.items.len;
            const tt = self.trailing_nodes.items.len;
            const visited = try self.visitNode(child);
            try drainPendingAroundTo(Transformer, self, pt, tt, visited, &prelude_stmts);
            try prelude_exports.put(self.allocator, @backingInt(child), {});
            continue;
        }
        const pt = self.pending_nodes.items.len;
        const tt = self.trailing_nodes.items.len;
        const visited = try self.visitNode(child);
        if (!wrapper_started and try hasTopLevelAwait(self.ast, child)) wrapper_started = true;
        if (wrapper_started) if (program_scope) |scope| {
            moved.clearRetainingCapacity();
            try drainPendingAroundTo(Transformer, self, pt, tt, visited, &moved);
            const hoist_function = hoisted_functions.contains(@backingInt(child));
            for (moved.items) |stmt| try placeWrappedStatement(Transformer, self, stmt, hoist_function, scope, &bindings, &prelude_stmts, &self.scratch, &post_exports);
            continue;
        };
        const destination = if (wrapper_started and !hoisted_functions.contains(@backingInt(child))) &self.scratch else &prelude_stmts;
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
    self.ast.extra_data.items[arrow_extra + 1] = @backingInt(body_block);
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
    if (self.semantic_edit_enabled) {
        const tla_symbol = try self.declareSyntheticVar(tla_binding, node.span);
        es_helpers.markStandaloneLateSyntheticTemp(self, tla_symbol, self.current_scope);
    }
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
    try appendHoistedDeclarations(Transformer, self, &bindings, node.span, &self.scratch);
    if (!visited_iife.isNone()) try self.scratch.append(self.allocator, visited_iife);
    try self.scratch.appendSlice(self.allocator, post_exports.items);

    // exports pass-through
    i = 0;
    while (i < list.len) : (i += 1) {
        const child: NodeIndex = @fromBackingInt(@intCast(self.ast.extra_data.items[list.start + i]));
        const child_node = self.ast.getNode(child);
        if (child_node.tag == .import_declaration or child_node.tag == .ts_import_equals_declaration) continue;
        if (!isModuleDeclaration(child_node.tag)) continue;
        if (prelude_exports.contains(@backingInt(child))) continue;
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
