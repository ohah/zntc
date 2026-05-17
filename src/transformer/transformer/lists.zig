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
    // program/function_body: 함수 스코프의 var 이름 수집
    if (self.options.unsupported.block_scoping and (node.tag == .program or node.tag == .function_body)) {
        collectTopLevelVarNames(self, node.data.list.start, node.data.list.len);
    }
    // ES2025: using/await using → try-finally 래핑
    if (self.options.unsupported.using) {
        const Using = es2025_using.ES2025Using(Transformer);
        if (Using.hasUsingDeclaration(self, node.data.list.start, node.data.list.len)) {
            const new_list = try Using.lowerUsingInStatements(self, node.data.list.start, node.data.list.len);
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

/// block_statement를 방문하면서 내부 let/const 리네이밍을 적용한다.
fn visitBlockWithScoping(self: *Transformer, node: Node) Error!NodeIndex {
    const list_start = node.data.list.start;
    const list_len = node.data.list.len;

    const saved_scope_len = self.scope_var_names.items.len;
    const renames_added = try pushBlockRenames(self, list_start, list_len);
    const new_list = try visitExtraList(self, .{ .start = list_start, .len = list_len });

    // 블록 퇴장: rename 맵 + scope_var_names 모두 복원
    if (renames_added > 0) {
        const saved_rename_len = self.block_rename_stack.items.len - renames_added;
        for (self.block_rename_stack.items[saved_rename_len..]) |entry| {
            self.allocator.free(entry.new_name);
        }
        self.block_rename_stack.shrinkRetainingCapacity(saved_rename_len);
    }
    self.scope_var_names.shrinkRetainingCapacity(saved_scope_len);

    return self.ast.addNode(.{
        .tag = .block_statement,
        .span = node.span,
        .data = .{ .list = new_list },
    });
}

/// program/function_body의 top-level 선언에서 var/let/const 이름을 scope_var_names에 수집.
fn collectTopLevelVarNames(self: *Transformer, list_start: u32, list_len: u32) void {
    var i: u32 = 0;
    while (i < list_len) : (i += 1) {
        const raw = self.ast.extra_data.items[list_start + i];
        const stmt = self.ast.getNode(@enumFromInt(raw));
        if (stmt.tag != .variable_declaration) continue;

        const ve = stmt.data.extra;
        const decl_start = self.readU32(ve, 1);
        const decl_len = self.readU32(ve, 2);

        var j: u32 = 0;
        while (j < decl_len) : (j += 1) {
            const decl_raw = self.ast.extra_data.items[decl_start + j];
            const decl = self.ast.getNode(@enumFromInt(decl_raw));
            if (decl.tag != .variable_declarator) continue;

            const name_idx = self.readNodeIdx(decl.data.extra, 0);
            if (name_idx.isNone()) continue;

            const BlockScoping = es2015_block_scoping.ES2015BlockScoping(Transformer);
            var names: std.ArrayList([]const u8) = .empty;
            defer names.deinit(self.allocator);
            BlockScoping.collectBindingNames(self, name_idx, &names) catch continue;

            for (names.items) |name| {
                if (!isNameInScope(self, name)) {
                    self.scope_var_names.append(self.allocator, name) catch {};
                }
            }
        }
    }
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

/// block_rename_stack에서 이름 조회. 스택 뒤(가장 안쪽 블록)부터 검색.
pub fn lookupBlockRename(self: *const Transformer, name: []const u8) ?[]const u8 {
    var i = self.block_rename_stack.items.len;
    while (i > 0) {
        i -= 1;
        const entry = self.block_rename_stack.items[i];
        if (std.mem.eql(u8, entry.old_name, name)) return entry.new_name;
    }
    return null;
}

/// 현재 함수 스코프의 var 이름 목록에 해당 이름이 있는지 확인.
fn isNameInScope(self: *const Transformer, name: []const u8) bool {
    for (self.scope_var_names.items) |n| {
        if (std.mem.eql(u8, n, name)) return true;
    }
    return false;
}

/// block_statement 진입 시: 내부 let/const 선언을 스캔하여 외부 스코프와
/// 충돌하는 이름을 찾고 리네이밍 맵을 push한다.
/// 반환값: push한 rename entry 수 (퇴장 시 pop할 양).
fn pushBlockRenames(self: *Transformer, list_start: u32, list_len: u32) Error!u32 {
    var renames_added: u32 = 0;

    var i: u32 = 0;
    while (i < list_len) : (i += 1) {
        const raw = self.ast.extra_data.items[list_start + i];
        const stmt = self.ast.getNode(@enumFromInt(raw));
        if (stmt.tag != .variable_declaration) continue;

        const ve = stmt.data.extra;
        if (!self.ast.variableDeclarationKind(stmt).isLexical()) continue;

        const decl_start = self.readU32(ve, 1);
        const decl_len = self.readU32(ve, 2);

        var j: u32 = 0;
        while (j < decl_len) : (j += 1) {
            const decl_raw = self.ast.extra_data.items[decl_start + j];
            const decl = self.ast.getNode(@enumFromInt(decl_raw));
            if (decl.tag != .variable_declarator) continue;

            const name_idx = self.readNodeIdx(decl.data.extra, 0);
            if (name_idx.isNone()) continue;

            // binding pattern에서 모든 이름 수집 (destructuring 지원)
            const BlockScoping = es2015_block_scoping.ES2015BlockScoping(Transformer);
            var names: std.ArrayList([]const u8) = .empty;
            defer names.deinit(self.allocator);
            BlockScoping.collectBindingNames(self, name_idx, &names) catch continue;

            for (names.items) |name| {
                if (isNameInScope(self, name)) {
                    self.block_rename_counter += 1;
                    const new_name = std.fmt.allocPrint(self.allocator, "{s}${d}", .{ name, self.block_rename_counter }) catch return Error.OutOfMemory;
                    self.block_rename_stack.append(self.allocator, .{ .old_name = name, .new_name = new_name }) catch return Error.OutOfMemory;
                    renames_added += 1;
                } else {
                    self.scope_var_names.append(self.allocator, name) catch return Error.OutOfMemory;
                }
            }
        }
    }

    return renames_added;
}

/// var <name> = <init_value>; 문 생성 (범용 헬퍼).
/// prefix + 카운터로 고유 이름을 생성한다. (예: _loop, _loop2, _loop3, ...)
/// 호출부에서 전용 카운터 포인터를 전달하여 다른 기능과 충돌 방지.
pub fn buildUniqueName(self: *Transformer, prefix: []const u8, counter: *u32) Error![]const u8 {
    counter.* += 1;
    if (counter.* == 1) return prefix;
    return std.fmt.allocPrint(self.allocator, "{s}{d}", .{ prefix, counter.* }) catch return Error.OutOfMemory;
}

pub fn buildVarDecl(self: *Transformer, name: []const u8, init_value: NodeIndex, span: Span) Error!NodeIndex {
    const name_span = try self.ast.addString(name);
    const binding = try self.ast.addNode(.{
        .tag = .binding_identifier,
        .span = name_span,
        .data = .{ .string_ref = name_span },
    });

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

/// 임시 변수 호이스팅: saved_counter..current counter 범위의 var _a, _b, ... 선언을 body 앞에 삽입.
/// body 의 top-level var 선언에 이미 같은 이름이 있으면 skip — `lowerDestructuringDeclaration`
/// 처럼 declaration 형태로 직접 emit 하는 패스가 있어 mergeAdjacentDecls 가 `var _a, _a = init, ...`
/// 같은 어색한 출력을 만드는 회귀 방지 (#1960).
pub fn hoistTempVars(self: *Transformer, body_idx: NodeIndex, saved_counter: u32, span: Span) Error!NodeIndex {
    return hoistTempVarsSkippingSpans(self, body_idx, saved_counter, span, &.{});
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
        var buf: [16]u8 = undefined;
        const name = es_helpers.tempVarName(i, &buf);
        if (tempNameInSpans(self, name, skip_spans)) continue;
        if (has_block and bodyHasTopLevelVarBinding(self, body_node, name)) continue;
        const name_span = try self.ast.addString(name);
        const binding = try self.ast.addNode(.{
            .tag = .binding_identifier,
            .span = name_span,
            .data = .{ .string_ref = name_span },
        });
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

fn tempNameInSpans(self: *const Transformer, name: []const u8, spans: []const Span) bool {
    for (spans) |sp| {
        if (std.mem.eql(u8, self.ast.getText(sp), name)) return true;
    }
    return false;
}

/// body (block_statement / program / function_body) 의 top-level var declaration 에서
/// `name` 과 같은 binding identifier 가 있는지 검사. nested block 은 보지 않음 — var 는
/// function-scoped 라 top-level 만 봐도 충분.
fn bodyHasTopLevelVarBinding(self: *const Transformer, body: Node, name: []const u8) bool {
    const list = body.data.list;
    const stmts = self.ast.extra_data.items[list.start .. list.start + list.len];
    for (stmts) |raw_idx| {
        const stmt = self.ast.getNode(@enumFromInt(raw_idx));
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
