//! ZNTC AST 공통 순회 유틸 — 자식 노드 iterator.
//!
//! `Node.Tag` 의 `dataKind` / `extraChildOffsets` / `extraListOffsets` 메타데이터를
//! 기반으로 **모든 레이아웃 (leaf / unary / binary / ternary / list / extra)** 의 자식
//! NodeIndex 를 순회한다. 이전에는 동일 5-arm switch 가 minify / transformer 하위 5 곳에
//! copy 되어 있었다 (#1646).
//!
//! 설계:
//!   - **iterator 패턴** — callback/return type 에 대해 중립. caller 가 `void` / `!void` /
//!     predicate short-circuit 모두 원하는 방식으로 제어.
//!   - **직계 자식만** — 재귀는 caller 가 처리 (호출자마다 재귀 조건 다름).
//!   - **bounds-safe** — out-of-range extra 참조는 skip (조용히 넘어감, caller 에서 별도
//!     추가 guard 가능, e.g. `parser_node_count` 필터).

const std = @import("std");
const ast_mod = @import("ast.zig");
const Ast = ast_mod.Ast;
const Node = ast_mod.Node;
const NodeIndex = ast_mod.NodeIndex;

/// node 의 직계 자식 NodeIndex 를 순회하는 iterator.
///
/// 사용 예:
/// ```zig
/// var it = ast_walk.children(ast, node);
/// while (it.next()) |child_idx| {
///     // 재귀나 predicate 는 caller 가 결정
/// }
/// ```
pub const ChildIterator = struct {
    ast: *const Ast,
    tag: Node.Tag,
    data: Node.Data,
    /// kind 별 의미 다름:
    ///   - binary/ternary: 0,1,2 번째 자식
    ///   - list: list 항목 인덱스 (0..list.len)
    ///   - extra: 0..child_offsets.len 은 child_offsets 인덱스,
    ///            그 이후는 child_offsets.len + list_offsets 인덱스
    cursor: u32 = 0,
    /// extra 의 list_offsets 처리 중인 리스트 상태.
    list_pos: u32 = 0,
    list_end: u32 = 0,
    in_list: bool = false,

    pub fn next(self: *ChildIterator) ?NodeIndex {
        switch (Node.Tag.dataKind(self.tag)) {
            .leaf => return null,
            .unary => {
                if (self.cursor != 0) return null;
                self.cursor = 1;
                return self.data.unary.operand;
            },
            .binary => switch (self.cursor) {
                0 => {
                    self.cursor = 1;
                    return self.data.binary.left;
                },
                1 => {
                    self.cursor = 2;
                    return self.data.binary.right;
                },
                else => return null,
            },
            .ternary => switch (self.cursor) {
                0 => {
                    self.cursor = 1;
                    return self.data.ternary.a;
                },
                1 => {
                    self.cursor = 2;
                    return self.data.ternary.b;
                },
                2 => {
                    self.cursor = 3;
                    return self.data.ternary.c;
                },
                else => return null,
            },
            .list => {
                const list = self.data.list;
                if (self.cursor >= list.len) return null;
                const extras = self.ast.extra_data.items;
                const pos = list.start + self.cursor;
                self.cursor += 1;
                if (pos >= extras.len) return null;
                return @enumFromInt(extras[pos]);
            },
            .extra => return self.nextExtraChild(),
        }
    }

    fn nextExtraChild(self: *ChildIterator) ?NodeIndex {
        const extras = self.ast.extra_data.items;
        const base = self.data.extra;
        const child_offs = Node.Tag.extraChildOffsets(self.tag);
        const list_offs = Node.Tag.extraListOffsets(self.tag);

        // 1단계: child_offsets (직접 NodeIndex 필드)
        while (self.cursor < child_offs.len) {
            const off = child_offs[self.cursor];
            self.cursor += 1;
            const idx = base + off;
            if (idx >= extras.len) continue;
            return @enumFromInt(extras[idx]);
        }

        // 2단계: list_offsets (간접 NodeIndex 리스트)
        while (true) {
            if (self.in_list) {
                if (self.list_pos < self.list_end) {
                    const raw = extras[self.list_pos];
                    self.list_pos += 1;
                    return @enumFromInt(raw);
                }
                self.in_list = false;
            }

            const list_idx = self.cursor - child_offs.len;
            if (list_idx >= list_offs.len) return null;
            const lo = list_offs[list_idx];
            self.cursor += 1;

            const start_idx = base + lo[0];
            const len_idx = base + lo[1];
            // start_idx/len_idx 둘 다 명시적 체크. 모든 현재 layout 에서 lo[0] < lo[1] 이라
            // 사실상 len_idx 체크만으로 충분하지만, 미래 layout 변경에 대한 방어.
            if (start_idx >= extras.len or len_idx >= extras.len) continue;
            const start = extras[start_idx];
            const len = extras[len_idx];
            const end = start + len;
            if (end > extras.len) continue;
            self.list_pos = start;
            self.list_end = end;
            self.in_list = true;
        }
    }
};

/// node 의 직계 자식 NodeIndex 를 순회하는 iterator 를 만든다.
pub fn children(ast: *const Ast, node: Node) ChildIterator {
    return .{
        .ast = ast,
        .tag = node.tag,
        .data = node.data,
    };
}

/// 바인딩 패턴 트리에서 leaf identifier 노드를 순회하는 iterator.
///
/// 방문 대상 (caller 가 tag 로 필터링):
///   - `binding_identifier` (정통 binding context)
///   - `identifier_reference`, `assignment_target_identifier` (cover-grammar 후 변환)
///
/// 자동 descend tags:
///   - 패턴 wrapper: `formal_parameter`, `formal_parameters`, `assignment_pattern`,
///     `assignment_target_with_default`, `binding_property`,
///     `assignment_target_property_identifier`, `assignment_target_property_property`
///   - 컨테이너: `array_pattern`, `object_pattern`, `array_assignment_target`, `object_assignment_target`
///   - rest: `rest_element`, `binding_rest_element`, `assignment_target_rest`, `spread_element`
///   - opt-in: `assignment_expression` (cover-grammar arrow param `(Foo = Bar()) =>`)
///
/// 이전에는 동일 패턴 walker 가 transformer / semantic / transpile 6 곳에 copy 되어
/// 있었다. 호출 측의 출력 타입이 다 달라서 (Span list / 이름 list / StringHashMap /
/// fixed buf) iterator 패턴으로 두고 wrapping 만 caller 가 결정.
pub const BindingIdentifierWalker = struct {
    pub const Options = struct {
        /// `(Foo = Bar()) =>` 같이 cover-grammar 로 패턴 자리에 남은 assignment_expression
        /// 의 LHS 를 binding 으로 본다. 일반 expression 컨텍스트의 `Foo = expr` 와 충돌하지
        /// 않게 caller 가 binding context 진입점에서만 켠다.
        cover_grammar_assignment: bool = false,
    };

    ast: *const Ast,
    allocator: std.mem.Allocator,
    options: Options,
    /// caller 가 만들어 주입한 stack. 첫 append 까지 alloc 안 함. 한도 없이 dynamic.
    /// caller 는 walker 사용 후 `stack.deinit(allocator)` 호출 책임.
    stack: std.ArrayList(NodeIndex),

    pub fn deinit(self: *BindingIdentifierWalker) void {
        self.stack.deinit(self.allocator);
    }

    pub fn next(self: *BindingIdentifierWalker) error{OutOfMemory}!?NodeIndex {
        while (self.stack.items.len > 0) {
            const idx = self.stack.pop().?;
            if (idx.isNone()) continue;
            const raw: u32 = @intFromEnum(idx);
            if (raw >= self.ast.nodes.items.len) continue;
            const node = self.ast.nodes.items[raw];
            switch (node.tag) {
                .binding_identifier,
                .identifier_reference,
                .assignment_target_identifier,
                => return idx,
                .formal_parameter => {
                    if (node.data.extra >= self.ast.extra_data.items.len) continue;
                    try self.push(@enumFromInt(self.ast.extra_data.items[node.data.extra]));
                },
                .formal_parameters,
                .array_pattern,
                .object_pattern,
                .array_assignment_target,
                .object_assignment_target,
                => try self.pushList(node.data.list),
                .assignment_pattern,
                .assignment_target_with_default,
                => try self.push(node.data.binary.left),
                .assignment_expression => {
                    if (self.options.cover_grammar_assignment) try self.push(node.data.binary.left);
                },
                .rest_element,
                .binding_rest_element,
                .assignment_target_rest,
                .spread_element,
                => try self.push(node.data.unary.operand),
                .binding_property,
                .assignment_target_property_identifier,
                .assignment_target_property_property,
                => {
                    const value = node.data.binary.right;
                    try self.push(if (value.isNone()) node.data.binary.left else value);
                },
                else => {},
            }
        }
        return null;
    }

    fn push(self: *BindingIdentifierWalker, idx: NodeIndex) error{OutOfMemory}!void {
        if (idx.isNone()) return;
        try self.stack.append(self.allocator, idx);
    }

    fn pushList(self: *BindingIdentifierWalker, list: ast_mod.NodeList) error{OutOfMemory}!void {
        if (list.start + list.len > self.ast.extra_data.items.len) return;
        // 역순으로 push 해서 다음 next() 호출이 list[0] 부터 보도록 한다.
        var i: u32 = list.len;
        while (i > 0) {
            i -= 1;
            const raw = self.ast.extra_data.items[list.start + i];
            try self.push(@enumFromInt(raw));
        }
    }
};

/// 바인딩 패턴 (포함 cover-grammar 결과) 의 leaf identifier 를 순회하는 iterator.
/// caller 는 반환된 walker 를 `defer w.deinit()` 해야 함.
pub fn bindingIdentifiers(
    allocator: std.mem.Allocator,
    ast: *const Ast,
    idx: NodeIndex,
    options: BindingIdentifierWalker.Options,
) error{OutOfMemory}!BindingIdentifierWalker {
    var w: BindingIdentifierWalker = .{
        .ast = ast,
        .allocator = allocator,
        .options = options,
        .stack = .empty,
    };
    errdefer w.stack.deinit(allocator);
    if (!idx.isNone() and @intFromEnum(idx) < ast.nodes.items.len) {
        try w.stack.append(allocator, idx);
    }
    return w;
}

/// `root` 서브트리에 raw `#x` private syntax (`private_field_expression` /
/// `private_identifier`) 가 남아 있는지 검사. transformer 가 lowering 했어야 할 노드가
/// codegen 까지 도달했는지 검증하는 debug invariant 용도 — 정상 코드 경로에서는 항상 false.
const RawPrivateCtx = struct { found: bool };

fn rawPrivateVisit(ctx: *RawPrivateCtx, idx: NodeIndex, node: Node) WalkAction {
    _ = idx;
    switch (node.tag) {
        .private_field_expression, .private_identifier => {
            ctx.found = true;
            return .stop;
        },
        else => return .descend,
    }
}

pub fn hasRawPrivateSyntax(ast: *const Ast, root: NodeIndex) bool {
    // 반복 순회(#4123): 깊은 좌결합 체인에서 재귀 시 스택 오버플로우. 이건 Debug/ReleaseSafe
    // 전용 invariant(`assert(!hasRawPrivateSyntax(...))`) — OOM 시 false 반환(검사 skip, false
    // panic 회피; ReleaseFast 에선 assert 자체가 compiled out).
    var c = RawPrivateCtx{ .found = false };
    walkPreorderIterative(ast.allocator, ast, root, &c, rawPrivateVisit) catch return false;
    return c.found;
}

/// AST 루트(마지막 program 노드)에서 도달 가능한 노드 인덱스를 pre-order로 수집한다.
/// transformer는 새 노드를 append하면서 이전 노드를 orphan으로 남길 수 있으므로,
/// post-transform 분석은 `ast.nodes.items` 전체 순회 대신 이 결과를 사용해야 한다.
pub fn collectReachableNodeIndices(allocator: std.mem.Allocator, ast: *const Ast) ![]u32 {
    if (ast.nodes.items.len == 0) return &.{};

    var visited = try allocator.alloc(bool, ast.nodes.items.len);
    defer allocator.free(visited);
    @memset(visited, false);

    var result: std.ArrayList(u32) = .empty;
    errdefer result.deinit(allocator);

    var stack: std.ArrayList(NodeIndex) = .empty;
    defer stack.deinit(allocator);
    const root_idx = ast.transformed_root orelse
        @as(NodeIndex, @enumFromInt(@as(u32, @intCast(ast.nodes.items.len - 1))));
    try stack.append(allocator, root_idx);

    var child_buf: std.ArrayList(NodeIndex) = .empty;
    defer child_buf.deinit(allocator);

    while (stack.pop()) |idx| {
        if (idx.isNone()) continue;
        const ni: u32 = @intFromEnum(idx);
        if (ni >= ast.nodes.items.len) continue;
        if (visited[ni]) continue;
        visited[ni] = true;

        try result.append(allocator, ni);

        child_buf.clearRetainingCapacity();
        var it = children(ast, ast.nodes.items[ni]);
        while (it.next()) |child_idx| {
            if (child_idx.isNone()) continue;
            if (@intFromEnum(child_idx) >= ast.nodes.items.len) continue;
            try child_buf.append(allocator, child_idx);
        }

        var i = child_buf.items.len;
        while (i > 0) {
            i -= 1;
            try stack.append(allocator, child_buf.items[i]);
        }
    }

    return result.toOwnedSlice(allocator);
}

/// `walkPreorderIterative` 의 노드별 콜백 반환값.
pub const WalkAction = enum {
    /// 이 노드의 자식들을 마저 방문(일반 pre-order 하강).
    descend,
    /// 이 노드의 서브트리를 건너뜀(prune — 자식 push 안 함). 재귀판의 early `return` 대응.
    skip_children,
    /// 순회 전체를 즉시 종료. predicate short-circuit(첫 매치에서 멈춤) 대응.
    stop,
};

/// `root` 서브트리를 pre-order(자식 좌→우)로 **반복** 순회한다. 재귀 대신 명시 스택을 써서
/// 깊은 좌결합 체인(`a+b+c+…` 수천 항, #4123)에서도 스택 오버플로우가 없다.
/// `visit(ctx, idx, node)` 가 각 노드에서 호출돼 `WalkAction` 을 반환:
///   - `.descend` → 자식 방문, `.skip_children` → 서브트리 prune, `.stop` → 전체 종료.
/// 방문 순서와 prune 의미는 `var it = children(...); while(it.next())|c| recurse(c)` 재귀판과
/// 동일하다(스택에 자식을 역순 push → 좌→우 pop). `allocator` 는 스택 전용(보통
/// `ast.allocator`=parse_arena; 함수 종료 시 deinit). OOM 시 `error.OutOfMemory` 전파 —
/// 무한루프/부분상태 없음(호출자가 catch 로 보수적 처리 가능).
pub fn walkPreorderIterative(
    allocator: std.mem.Allocator,
    ast: *const Ast,
    root: NodeIndex,
    ctx: anytype,
    comptime visit: fn (@TypeOf(ctx), NodeIndex, Node) WalkAction,
) std.mem.Allocator.Error!void {
    var stack: std.ArrayList(NodeIndex) = .empty;
    defer stack.deinit(allocator);
    try stack.append(allocator, root);

    var child_buf: std.ArrayList(NodeIndex) = .empty;
    defer child_buf.deinit(allocator);

    while (stack.pop()) |idx| {
        if (idx.isNone() or @intFromEnum(idx) >= ast.nodes.items.len) continue;
        const node = ast.nodes.items[@intFromEnum(idx)];
        switch (visit(ctx, idx, node)) {
            .stop => return,
            .skip_children => continue,
            .descend => {},
        }
        // 자식을 좌→우 pop 하도록 역순으로 push.
        child_buf.clearRetainingCapacity();
        var it = children(ast, node);
        while (it.next()) |c| try child_buf.append(allocator, c);
        var i = child_buf.items.len;
        while (i > 0) {
            i -= 1;
            try stack.append(allocator, child_buf.items[i]);
        }
    }
}

/// `node` 의 직계 자식을 `children` iterator 순서(좌→우) 그대로 `out` 에 수집한다(`out` 은 먼저
/// 비워짐). 반복 순회(#4123) 변환의 **sanctioned 공용 진입점** — 직접 `children()` 재귀가
/// 재유입되지 않도록 트리 순회 호출을 한 곳에 모은다(durability audit 의 iterative_safe 단일
/// 호출처). worklist(LIFO 스택)에 넣을 땐 호출자가 역순으로 push 해 소스 순서를 보존한다
/// (NodeIndex 스택이든 {idx,post} 같은 frame 스택이든 호출자가 wrapping 을 결정). `out` 은
/// none NodeIndex 도 그대로 담으므로(필터링 안 함), 호출자가 pop 시 `isNone` 가드를 둔다 —
/// `walkPreorderIterative`/`children` 의 의미와 일치.
pub fn collectChildrenInto(
    ast: *const Ast,
    node: Node,
    out: *std.ArrayList(NodeIndex),
    allocator: std.mem.Allocator,
) std.mem.Allocator.Error!void {
    out.clearRetainingCapacity();
    var it = children(ast, node);
    while (it.next()) |c| try out.append(allocator, c);
}
