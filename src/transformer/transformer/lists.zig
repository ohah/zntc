//! List traversal, block-scoping rename, and temp-var hoist helpers for Transformer.

const std = @import("std");
const ast_mod = @import("../../parser/ast.zig");
const Node = ast_mod.Node;
const NodeIndex = ast_mod.NodeIndex;
const NodeList = ast_mod.NodeList;
const VariableDeclarationKind = ast_mod.VariableDeclarationKind;
const token_mod = @import("../../lexer/token.zig");
const Span = token_mod.Span;
const es2015_block_scoping = @import("../es2015_block_scoping.zig");
const es2025_using = @import("../es2025_using.zig");
const es_helpers = @import("../es_helpers.zig");
const transformer_mod = @import("../transformer.zig");
const Transformer = transformer_mod.Transformer;
const Error = Transformer.Error;

/// 리스트 노드: 각 자식을 방문, .none이 아닌 것만 새 리스트로 수집.
pub fn visitListNode(self: *Transformer, idx: NodeIndex) Error!NodeIndex {
    const node = self.ast.getNode(idx);
    // ES2015 block scoping 격리: block_statement 진입 시 리네이밍 처리
    if (self.options.unsupported.block_scoping and node.tag == .block_statement) {
        return visitBlockWithScoping(self, node);
    }
    // ES2025: using/await using → try-finally 래핑
    if (self.options.unsupported.using) {
        const Using = es2025_using.ES2025Using(Transformer);
        if (Using.hasUsingDeclaration(self, node.data.list.start, node.data.list.len)) {
            const new_list = try Using.lowerUsingInStatements(self, node.data.list.start, node.data.list.len, if (node.tag == .program) .program else .body);
            return self.ast.addNode(.{
                .tag = node.tag,
                .span = node.span,
                .data = .{ .list = new_list },
            });
        }
    }
    const new_list = try visitExtraList(self, node.data.list);
    // visitExtraList 가 identity (원본 list 그대로) 반환 → 부모도 identity.
    if (new_list.start == node.data.list.start and new_list.len == node.data.list.len) {
        return idx;
    }
    return self.ast.addNode(.{
        .tag = node.tag,
        .span = node.span,
        .data = .{ .list = new_list },
    });
}

/// es5 블록 방문. 블록 안 let/const 의 새 이름은 심볼 표(`block_rename_map`)로 이미 정해져
/// 식별자 방문이 적용한다 (#4760).
fn visitBlockWithScoping(self: *Transformer, node: Node) Error!NodeIndex {
    const list_start = node.data.list.start;
    const list_len = node.data.list.len;

    // es5 에선 블록(함수 본문 포함)이 이 경로로 빠진다 — using 낮추기도 여기서 해야 한다.
    // 예전엔 visitListNode 의 using 분기에 닿지 못해 dispose 없이 var 가 됐다 (#4730).
    const Using = es2025_using.ES2025Using(Transformer);
    const new_list = if (self.options.unsupported.using and Using.hasUsingDeclaration(self, list_start, list_len))
        try Using.lowerUsingInStatements(self, list_start, list_len, .body)
    else
        try visitExtraList(self, .{ .start = list_start, .len = list_len });

    return self.ast.addNode(.{
        .tag = .block_statement,
        .span = node.span,
        .data = .{ .list = new_list },
    });
}

/// extra_data의 노드 리스트를 방문하여 새 AST에 복사.
/// .none이 된 자식은 자동으로 제거된다.
/// scratch 버퍼를 사용하며, 중첩 호출에 안전 (save/restore 패턴).
///
/// pending_nodes 지원: 각 자식 방문 후 pending_nodes에 쌓인 노드를
/// 해당 자식 앞에 삽입한다. 이를 통해 1→N 노드 확장이 가능하다.
/// 예: enum 변환 시 visitNode가 IIFE를 반환하면서 `var Color;`을
///     pending_nodes에 push → 리스트에 `var Color;` + IIFE 순서로 삽입.
/// 리스트의 각 자식을 방문해 새 NodeList 반환.
/// 변경이 하나도 없으면 원본 `list` 를 그대로 반환한다 (identity) — extra_data
/// 재할당을 피해 메모리 성장을 억제. caller 가 start/len 동일성으로 판별 가능.
pub fn visitExtraList(self: *Transformer, list: NodeList) Error!NodeList {
    // 주의: extra_data.items 슬라이스를 캐시하면 안 됨.
    // visitNode 내부에서 ast.extra_data에 append하면 배열이 재할당되어
    // 캐시된 슬라이스가 dangling pointer가 될 수 있다.
    // 따라서 매 반복마다 start+i로 직접 인덱싱한다.

    const scratch_top = self.scratch.items.len;
    defer self.scratch.shrinkRetainingCapacity(scratch_top);

    // pending_nodes save/restore: 중첩 visitExtraList 호출에 안전.
    // 내부 리스트의 pending_nodes가 외부 리스트로 누출되지 않도록 한다.
    const pending_top = self.pending_nodes.items.len;
    defer self.pending_nodes.shrinkRetainingCapacity(pending_top);

    // trailing_nodes save/restore: 중첩 visitExtraList 호출에 안전.
    const trailing_top = self.trailing_nodes.items.len;
    defer self.trailing_nodes.shrinkRetainingCapacity(trailing_top);

    var i: u32 = 0;
    while (i < list.len) : (i += 1) {
        // 매 반복마다 extra_data에서 직접 읽기 (재할당 안전)
        const raw_idx = self.ast.extra_data.items[list.start + i];
        const new_child = try self.visitNode(@enumFromInt(raw_idx));

        // pending_nodes 드레인: visitNode가 추가한 보류 노드를 먼저 삽입
        if (self.pending_nodes.items.len > pending_top) {
            try self.scratch.appendSlice(self.allocator, self.pending_nodes.items[pending_top..]);
            self.pending_nodes.shrinkRetainingCapacity(pending_top);
        }

        if (!new_child.isNone()) {
            try self.scratch.append(self.allocator, new_child);
        }

        // trailing_nodes 드레인: visitNode가 추가한 후행 노드를 자식 뒤에 삽입
        // (예: worklet 함수 뒤의 __workletHash/__closure/__initData 프로퍼티 할당)
        if (self.trailing_nodes.items.len > trailing_top) {
            try self.scratch.appendSlice(self.allocator, self.trailing_nodes.items[trailing_top..]);
            self.trailing_nodes.shrinkRetainingCapacity(trailing_top);
        }
    }

    const scratch_slice = self.scratch.items[scratch_top..];
    // 변경 없음 감지: 자식 개수 동일 + 각 idx 가 원본과 같음 → 원본 list 그대로 반환.
    // 이 경우 extra_data 재할당이 없고 caller 도 부모 노드를 identity 로 전파 가능.
    if (scratch_slice.len == list.len) {
        var identical = true;
        for (scratch_slice, 0..) |new_idx, j| {
            if (@intFromEnum(new_idx) != self.ast.extra_data.items[list.start + j]) {
                identical = false;
                break;
            }
        }
        if (identical) return list;
    }
    return self.ast.addNodeList(scratch_slice);
}

/// 이름 조각을 **오래 들고 있어도 되는** 조각으로 바꾼다.
///
/// `ast.getText` 가 주는 조각은 원문(`source`)이나 `string_table` 을 가리킨다. 원문은 변하지
/// 않지만 `string_table` 은 `addString` 이 늘릴 때 새 버퍼로 옮겨지므로, 그 안을 가리키는 조각
/// (변환기가 만든 `_using` 이나 이미 바꾼 `x$1` 같은 이름)은 다음 `addString` 뒤에 해제된
/// 메모리가 된다. 그런 조각만 `name_arena` 에 복사한다 — 조각을 얻은 **직후**, 다른
/// `addString` 전에 불러야 한다.
pub fn stableName(self: *Transformer, name: []const u8) Error![]const u8 {
    const table = self.ast.string_table.items;
    const start = @intFromPtr(table.ptr);
    const p = @intFromPtr(name.ptr);
    if (name.len == 0 or p < start or p >= start + table.len) return name;
    if (self.name_arena == null) self.name_arena = std.heap.ArenaAllocator.init(self.allocator);
    return self.name_arena.?.allocator().dupe(u8, name) catch return Error.OutOfMemory;
}

/// var <name> = <init_value>; 문 생성 (범용 헬퍼).
/// prefix + 카운터로 고유 이름을 생성한다. (예: _loop, _loop2, _loop3, ...)
/// 호출부에서 전용 카운터 포인터를 전달하여 다른 기능과 충돌 방지.
pub fn buildUniqueName(self: *Transformer, prefix_in: []const u8, counter: *u32) Error![]const u8 {
    // 접두사를 먼저 사용자 이름과 비껴 둔다(`_loop` → 사용자에게 `_loop` 가 있으면 `_loop2`) —
    // 번호는 그 뒤에 붙여 서로 다른 합성 변수가 같은 이름을 받지 않게 한다.
    // 돌려주는 이름은 transformer 수명의 `name_arena` 소유라 호출자가 해제하지 않는다.
    const prefix = try es_helpers.resolveSyntheticName(self, prefix_in);
    counter.* += 1;
    if (counter.* == 1) return prefix;
    if (self.name_arena == null) self.name_arena = std.heap.ArenaAllocator.init(self.allocator);
    return std.fmt.allocPrint(self.name_arena.?.allocator(), "{s}{d}", .{ prefix, counter.* }) catch return Error.OutOfMemory;
}

pub fn buildVarDecl(self: *Transformer, name: []const u8, init_value: NodeIndex, span: Span) Error!NodeIndex {
    const name_span = try self.ast.addString(name);
    const binding = try es_helpers.makeSyntheticBinding(self, name_span);

    const none = @intFromEnum(NodeIndex.none);
    const declarator = try self.addExtraNode(.variable_declarator, span, &.{
        @intFromEnum(binding), none, @intFromEnum(init_value),
    });

    const decl_list = try self.ast.addNodeList(&.{declarator});
    return self.addExtraNode(.variable_declaration, span, &.{
        @intFromEnum(VariableDeclarationKind.@"var"),
        decl_list.start,
        decl_list.len,
    });
}

/// state-machine lowering 후 callback-local temp(`_a..`)의 `var` 선언을
/// `sm_body` 에 지역 hoist 하고 temp counter 를 `saved_counter` 로 복원한다.
/// 4개 state-machine lowering 경로(es2017 async/arrow, es2015 generator,
/// es5 class-async)의 공통 불변식 — 누락 시 temp counter 가 outer 로 누수돼
/// scope-hoist 번들 모듈에서 미선언 참조(`ReferenceError`)를 유발한다.
/// caller 가 none-body 정책(early return / fall-through)을 호출 전에 결정하므로
/// 이 helper 는 항상 non-none `sm_body` 로 호출된다.
pub const HoistedStateTemp = struct {
    binding: NodeIndex,
    name_span: Span,
};

pub fn hoistStateMachineTempsAndRestore(self: *Transformer, sm_body: NodeIndex, saved_counter: u32, span: Span, bindings: *std.ArrayListUnmanaged(HoistedStateTemp)) Error!NodeIndex {
    std.debug.assert(!sm_body.isNone());
    var body = sm_body;
    if (self.temp_var_counter > saved_counter) {
        body = try hoistTempVarsWithScope(self, body, saved_counter, span, self.generator_temp_var_spans.items, null, bindings);
    }
    self.temp_var_counter = saved_counter;
    return body;
}

/// 임시 변수 호이스팅: saved_counter..current counter 범위의 var _a, _b, ... 선언을 body 앞에 삽입.
/// body 의 top-level var 선언에 이미 같은 이름이 있으면 skip — `lowerDestructuringDeclaration`
/// 처럼 declaration 형태로 직접 emit 하는 패스가 있어 mergeAdjacentDecls 가 `var _a, _a = init, ...`
/// 같은 어색한 출력을 만드는 회귀 방지 (#1960).
pub fn hoistTempVars(self: *Transformer, body_idx: NodeIndex, saved_counter: u32, span: Span) Error!NodeIndex {
    return hoistTempVarsWithScope(self, body_idx, saved_counter, span, &.{}, null, null);
}

/// Hoist into a generated function whose scope is registered after its body
/// has been visited. Return exact binding nodes for that later registration.
pub fn hoistTempVarsRecording(self: *Transformer, body_idx: NodeIndex, saved_counter: u32, span: Span, bindings: *std.ArrayListUnmanaged(HoistedStateTemp)) Error!NodeIndex {
    return hoistTempVarsWithScope(self, body_idx, saved_counter, span, &.{}, null, bindings);
}

/// 원본 함수 또는 명시적으로 등록한 합성 함수의 var scope에 temp를 연결한다.
/// 등록한 합성 함수의 scope는 원본 배열 대신 SemanticEditor에만 있을 수 있다.
pub fn hoistTempVarsInOriginalFunction(self: *Transformer, body_idx: NodeIndex, saved_counter: u32, span: Span) Error!NodeIndex {
    const scopes = if (self.semantic_editor) |*editor| editor.scopes.items else self.scopes;
    const scope = if (self.semantic_edit_enabled and !self.current_scope.isNone() and
        scopes[self.current_scope.toIndex()].kind == .function)
        self.current_scope
    else
        null;
    return hoistTempVarsWithScope(self, body_idx, saved_counter, span, &.{}, scope, null);
}

/// An arrow's body owns temps allocated while visiting that body. Its
/// parameters were visited before saved_counter and keep their existing
/// allocation policy. Wrap an expression body only if it needs a declaration.
pub fn hoistArrowBodyTemps(self: *Transformer, body_idx: NodeIndex, saved_counter: u32, span: Span) Error!NodeIndex {
    if (self.temp_var_counter == saved_counter) return body_idx;
    std.debug.assert(!body_idx.isNone() and self.temp_var_counter > saved_counter);
    var body = body_idx;
    const node = self.ast.getNode(body);
    if (node.tag != .block_statement and node.tag != .function_body) {
        const ret = try self.ast.addNode(.{
            .tag = .return_statement,
            .span = span,
            .data = .{ .unary = .{ .operand = body, .flags = 0 } },
        });
        const list = try self.ast.addNodeList(&.{ret});
        body = try self.ast.addNode(.{ .tag = .block_statement, .span = span, .data = .{ .list = list } });
    }
    body = try self.hoistTempVarsInOriginalFunction(body, saved_counter, span);
    self.temp_var_counter = saved_counter;
    return body;
}

/// Parameter initializers run in the source function, even when its body is
/// moved into a generated callback. Body-local temp hoisting has already
/// restored the counter to the value after parameter visitation at this point.
pub fn hoistParameterTempsAndRestore(self: *Transformer, body_idx: NodeIndex, before_params: u32, after_params: u32, span: Span) Error!NodeIndex {
    if (after_params == before_params) return body_idx;
    // Visit of a generated inner function can leave later body/state temps in
    // the counter. Restrict this hoist to the exact parameter allocation range.
    std.debug.assert(!body_idx.isNone() and self.temp_var_counter >= after_params and after_params > before_params);
    const later_counter = self.temp_var_counter;
    self.temp_var_counter = after_params;
    errdefer self.temp_var_counter = later_counter;
    const body = try self.hoistTempVarsInOriginalFunction(body_idx, before_params, span);
    if (body != body_idx) {
        // This exact declaration is needed while evaluating a lowered default.
        // Pass 2 must keep it before default checks, and native defaults must
        // be lowered because their separate parameter environment cannot see
        // a body var binding.
        const list = self.ast.getNode(body).data.list;
        const declaration = self.ast.extra_data.items[list.start];
        try self.parameter_capture_statements.put(self.allocator, declaration, {});
    }
    if (later_counter > after_params) {
        // Those later allocations still need their existing body owner. The
        // enclosing hoist may inspect the whole counter range, so remove only
        // the parameter slots already declared and bound above.
        for (before_params..after_params) |i| _ = self.temp_span_by_counter.remove(@intCast(i));
        self.temp_var_counter = later_counter;
    } else {
        self.temp_var_counter = before_params;
    }
    return body;
}

/// 임시 변수 호이스팅: saved_counter..current counter 범위의 var _a, _b, ... 선언을 body 앞에 삽입.
/// `skip_spans`에 들어있는 synthetic temp 이름은 선언하지 않는다.
///
/// generator state machine은 두 종류의 temp를 동시에 만든다.
/// - generator_temp_var_spans: for-await/yield extraction처럼 resume 사이에 값이 유지돼야 하는
///   state temp. wrapper function top에만 선언해야 한다.
/// - temp_var_counter-only: optional chaining/nullish/destructuring lowering처럼 callback 한 번의
///   평가 안에서만 쓰이는 expression temp. __generator callback 안에 선언해야 한다.
///
/// 이 helper는 state-machine callback-local hoist가 state temp를 다시 선언해 shadowing하지
/// 않도록 skip 목록을 받는다.
pub fn hoistTempVarsSkippingSpans(self: *Transformer, body_idx: NodeIndex, saved_counter: u32, span: Span, skip_spans: []const Span) Error!NodeIndex {
    return hoistTempVarsWithScope(self, body_idx, saved_counter, span, skip_spans, null, null);
}

fn hoistTempVarsWithScope(self: *Transformer, body_idx: NodeIndex, saved_counter: u32, span: Span, skip_spans: []const Span, function_scope: ?@import("../../semantic/scope.zig").ScopeId, state_bindings: ?*std.ArrayListUnmanaged(HoistedStateTemp)) Error!NodeIndex {
    const count = self.temp_var_counter - saved_counter;
    if (count == 0) return body_idx;

    const body_node = self.ast.getNode(body_idx);
    const has_block = body_node.tag == .block_statement or
        body_node.tag == .program or
        body_node.tag == .function_body;

    // var _a, _b, ... (초기값 없이 선언만)
    const scratch_top = self.scratch.items.len;
    defer self.scratch.shrinkRetainingCapacity(scratch_top);

    var i: u32 = saved_counter;
    while (i < self.temp_var_counter) : (i += 1) {
        // makeTempVarSpan이 충돌로 건너뛴 슬롯에는 할당 기록이 없다.
        // 이름을 재생성하면 다른 함수의 같은 이름을 이 선언에 잘못 묶게 된다.
        const name_span = self.temp_span_by_counter.get(i) orelse continue;
        const name = self.ast.getText(name_span);
        if (tempSpanInSpans(name_span, skip_spans)) continue;
        if (has_block and bodyHasTopLevelVarBinding(self, body_node, name)) continue;
        const binding = try es_helpers.makeSyntheticBinding(self, name_span);
        if (state_bindings) |bindings| try bindings.append(self.allocator, .{ .binding = binding, .name_span = name_span });
        if (body_node.tag == .program and self.semantic_edit_enabled) {
            try self.bindHoistedTemp(binding, name_span, span, .none);
        } else if (function_scope) |scope_id| {
            try self.bindHoistedTemp(binding, name_span, span, scope_id);
        }
        const none = @intFromEnum(NodeIndex.none);
        const declarator = try self.addExtraNode(.variable_declarator, span, &.{
            @intFromEnum(binding), none, none,
        });
        try self.scratch.append(self.allocator, declarator);
    }

    if (self.scratch.items.len == scratch_top) return body_idx;

    const decl_list = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
    const var_decl = try self.addExtraNode(.variable_declaration, span, &.{
        @intFromEnum(VariableDeclarationKind.@"var"),
        decl_list.start,
        decl_list.len,
    });

    return self.prependStatementsToBody(body_idx, &.{var_decl});
}

fn tempSpanInSpans(target: Span, spans: []const Span) bool {
    for (spans) |sp| {
        if (sp.start == target.start and sp.end == target.end) return true;
    }
    return false;
}

/// body (block_statement / program / function_body) 의 top-level 변수 선언(`export` 안 포함)에서
/// `name` 과 같은 binding identifier 가 있는지 검사. nested block 은 보지 않음 — 거기 `let`/`const`
/// 는 스코프가 달라 끌어올린 `var` 와 충돌하지 않는다. 같은 스코프의 `export const _a = …` 를
/// 놓치면 `var _a;` 와 겹쳐 SyntaxError (#4790).
fn bodyHasTopLevelVarBinding(self: *const Transformer, body: Node, name: []const u8) bool {
    const list = body.data.list;
    const stmts = self.ast.extra_data.items[list.start .. list.start + list.len];
    for (stmts) |raw_idx| {
        var stmt = self.ast.getNode(@enumFromInt(raw_idx));
        if (stmt.tag == .export_named_declaration) {
            const decl_idx = self.readNodeIdx(stmt.data.extra, 0); // ExportNamedExtras.decl
            if (decl_idx.isNone()) continue;
            stmt = self.ast.getNode(decl_idx);
        }
        if (stmt.tag != .variable_declaration) continue;
        const e = stmt.data.extra;
        if (e + 2 >= self.ast.extra_data.items.len) continue;
        const dl_start = self.ast.extra_data.items[e + 1];
        const dl_len = self.ast.extra_data.items[e + 2];
        var di: u32 = 0;
        while (di < dl_len) : (di += 1) {
            const draw_idx = self.ast.extra_data.items[dl_start + di];
            const decl = self.ast.getNode(@enumFromInt(draw_idx));
            if (decl.tag != .variable_declarator) continue;
            const binding_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[decl.data.extra]);
            if (binding_idx.isNone()) continue;
            const binding = self.ast.getNode(binding_idx);
            if (binding.tag != .binding_identifier) continue;
            if (std.mem.eql(u8, self.ast.getText(binding.span), name)) return true;
        }
    }
    return false;
}
