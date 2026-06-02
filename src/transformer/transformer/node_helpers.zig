const std = @import("std");
const ast_mod = @import("../../parser/ast.zig");
const token_mod = @import("../../lexer/token.zig");
const es_helpers = @import("../es_helpers.zig");
const es2015_class = @import("../es2015_class.zig");
const es2020 = @import("../es2020.zig");

const Node = ast_mod.Node;
const Tag = Node.Tag;
const NodeIndex = ast_mod.NodeIndex;
const Span = token_mod.Span;
const Error = std.mem.Allocator.Error;

/// 리프/불변 노드를 identity 로 반환한다 - 새 NodeIndex 를 할당하지 않음.
/// 통합 AST 에서는 parser/transformer 가 같은 배열을 공유하므로 old_idx 그대로
/// 유효하며, Symbol 의 NodeIndex 필드(`single_read_node` 등)가 stale 되지 않는다.
/// 내용이 변하는 리프(unicode escape lowering 등)는 여전히 `self.ast.addNode`
/// 로 새 노드를 만들어야 한다 - 이 함수는 "값 그대로 복제" 경로 전용.
pub fn copyNodeDirect(self: anytype, idx: NodeIndex) Error!NodeIndex {
    _ = self;
    return idx;
}

/// ES2015 block scoping 격리: outer scope 와 충돌하는 inner `let`/`const` 가
/// `block_rename_stack` 에 등록되어 있으면 `name$N` 으로 치환된 새 노드 반환.
/// identifier_reference / binding_identifier / assignment_target_identifier 가 공유.
/// 호출 후 새 노드의 symbol_id 를 반드시 전파 - 누락 시 linker rename 미적용으로
/// 정의/사용 비대칭 (`acc = acc$1 + n` 같은 strict-mode ReferenceError) 발생.
pub fn tryRenameIdentifierLike(
    self: anytype,
    idx: NodeIndex,
    comptime tag: Tag,
) Error!?NodeIndex {
    if (!self.options.unsupported.block_scoping) return null;
    if (self.block_rename_stack.items.len == 0) return null;
    const node = self.ast.getNode(idx);
    const text = self.ast.getText(node.data.string_ref);
    const new_name = self.lookupBlockRename(text) orelse return null;
    const new_span = try self.ast.addString(new_name);
    const new_idx = try self.ast.addNode(.{
        .tag = tag,
        .span = new_span,
        .data = .{ .string_ref = new_span },
    });
    self.propagateSymbolId(idx, new_idx);
    return new_idx;
}

/// 클래스 이름 노드에서 Span 추출. 익명 클래스(none)면 null 반환.
/// ES2022 static block의 this -> 클래스 이름 치환에 사용.
pub fn getClassNameSpan(self: anytype, name_idx: NodeIndex) ?Span {
    if (name_idx.isNone()) return null;
    return self.ast.getNode(name_idx).data.string_ref;
}

/// symbol_ids를 target_idx까지 null로 확장.
fn ensureSymbolIds(self: anytype, target_idx: usize) void {
    if (self.symbol_ids.items.len <= target_idx) {
        const needed = target_idx + 1 - self.symbol_ids.items.len;
        self.symbol_ids.appendNTimes(self.allocator, null, needed) catch return;
    }
}

/// 파서 노드 -> 트랜스포머 노드로 symbol_id 전파.
/// 통합 AST에서는 old_idx와 new_idx가 같은 배열의 인덱스.
pub fn propagateSymbolId(self: anytype, old_idx: NodeIndex, new_idx: NodeIndex) void {
    if (self.symbol_ids.items.len == 0) return; // 전파 비활성
    if (new_idx.isNone()) return;

    const old_i = @intFromEnum(old_idx);
    const new_i = @intFromEnum(new_idx);

    ensureSymbolIds(self, new_i);

    if (old_i < self.symbol_ids.items.len) {
        // ts_as_expression 등 wrapper 노드가 내부 노드와 같은 new_idx를 반환하면
        // wrapper의 null symbol_id가 내부 노드의 유효한 symbol_id를 덮어쓸 수 있음.
        // 이미 유효한 symbol_id가 설정되어 있으면 null로 덮어쓰지 않음.
        if (self.symbol_ids.items[old_i] != null or self.symbol_ids.items[new_i] == null) {
            self.symbol_ids.items[new_i] = self.symbol_ids.items[old_i];
        }
    }
}

/// AST 내에서 노드 간 symbol_id 복사.
/// 노드 복제 시 symbol_id가 누락되지 않도록 사용.
pub fn copySymbolId(self: anytype, src_idx: NodeIndex, dst_idx: NodeIndex) void {
    if (self.symbol_ids.items.len == 0) return;
    if (src_idx.isNone() or dst_idx.isNone()) return;

    const src_i = @intFromEnum(src_idx);
    const dst_i = @intFromEnum(dst_idx);

    ensureSymbolIds(self, dst_i);

    if (src_i < self.symbol_ids.items.len) {
        if (self.symbol_ids.items[src_i]) |sid| {
            self.symbol_ids.items[dst_i] = sid;
        }
    }
}

/// span + old_idx로 identifier_reference 생성 + symbol_id 전파.
/// ES5 class lowering, decorator 등에서 renamed 이름이 반영되도록 사용.
pub fn makeIdentifierRefWithSymbol(self: anytype, name_span: Span, old_idx: NodeIndex) Error!NodeIndex {
    const ref = try es_helpers.makeIdentifierRefFromSpan(self, name_span);
    self.propagateSymbolId(old_idx, ref);
    return ref;
}

/// JSX -> `React.createElement` 변환처럼 transformer 가 *원본 AST 에 없는*
/// 식별자 노드를 만들 때, 그 이름으로 root scope (module/global) 의 binding
/// 을 lookup 하여 symbol_id 를 attach 한다 (#2196).
pub fn attachRootScopeSymbolByName(self: anytype, node_idx: NodeIndex, name: []const u8) void {
    if (self.symbols.len == 0) return;
    if (self.symbol_ids.items.len == 0) return;
    if (node_idx.isNone()) return;

    for (self.symbols, 0..) |sym, i| {
        if (sym.scope_id.isNone()) continue;
        if (sym.scope_id.toIndex() != 0) continue;
        const sym_name = sym.nameText(self.ast.source);
        if (std.mem.eql(u8, sym_name, name)) {
            const ni = @intFromEnum(node_idx);
            ensureSymbolIds(self, ni);
            if (ni < self.symbol_ids.items.len) {
                self.symbol_ids.items[ni] = @intCast(i);
            }
            return;
        }
    }
}

/// 단항 노드: operand를 재귀 방문 후 복사.
pub fn visitUnaryNode(self: anytype, idx: NodeIndex) Error!NodeIndex {
    const node = self.ast.getNode(idx);
    var old_operand = node.data.unary.operand;

    // statement context(`this.#x++;`)는 postfix 반환값이 폐기되므로 prefix 와
    // 의미 동일. private-field 다운레벨이 활성일 때 postfix→prefix 정규화하면
    // `(_t=get(),set(_t+1),_t)` 3-part 시퀀스 대신 compact `set(get()+1)` 로
    // lowering (lru-cache@es2021 등 private-heavy es2021 size 회수, 의미 보존).
    if (node.tag == .expression_statement and
        (self.options.unsupported.class or self.options.unsupported.class_private_field))
    {
        const opn = self.ast.getNode(old_operand);
        if (opn.tag == .update_expression) {
            const ue = opn.data.extra;
            if (ue + 1 < self.ast.extra_data.items.len) {
                const inner_idx = readNodeIdx(self, ue, 0);
                const op_flags = readU32(self, ue, 1);
                if ((op_flags & ast_mod.UnaryFlags.postfix) != 0 and
                    self.ast.getNode(inner_idx).tag == .private_field_expression)
                {
                    old_operand = try addExtraNode(self, .update_expression, opn.span, &.{
                        @intFromEnum(inner_idx),
                        op_flags & ~ast_mod.UnaryFlags.postfix,
                    });
                }
            }
        }
    }

    const new_operand = try self.visitNode(old_operand);
    // 자식 unchanged -> 부모도 identity. 단 위에서 operand 를 재작성했으면
    // (old_operand != 원본) 반드시 새 노드로 재구성 (early-return 시 원본 operand 유지 버그).
    if (new_operand == old_operand and old_operand == node.data.unary.operand) return idx;
    return self.ast.addNode(.{
        .tag = node.tag,
        .span = node.span,
        .data = .{ .unary = .{ .operand = new_operand, .flags = node.data.unary.flags } },
    });
}

/// left 노드가 lowering 없이 visitBinaryNode 로 직행하는 "일반" 좌결합 스파인 노드인지.
/// node_dispatch.zig:276-305 의 per-node 다운레벨링 트리거(`**`→Math.pow, `??`→삼항,
/// `#x in`)를 제외 — 그 노드들은 평탄화로 건너뛰면 안 되고 visitNode 로 재-dispatch 되어
/// lowering 돼야 하므로 스파인 경계가 된다. (#4123 좌 스파인 평탄화용.)
fn binarySpineContinues(self: anytype, idx: NodeIndex) bool {
    if (idx.isNone() or @intFromEnum(idx) >= self.ast.nodes.items.len) return false;
    const n = self.ast.getNode(idx);
    if (n.tag != .binary_expression and n.tag != .logical_expression) return false;
    const op: token_mod.Kind = @enumFromInt(n.data.binary.flags);
    if (n.tag == .binary_expression and op == .star2 and self.options.unsupported.exponentiation) return false;
    if (n.tag == .logical_expression and op == .question2 and self.options.unsupported.nullish_coalescing) return false;
    if (n.tag == .binary_expression and op == .kw_in and
        (self.current_private_fields.len > 0 or self.current_private_methods.len > 0)) return false;
    return true;
}

/// 이항 노드: left, right를 방문 후 복사. 좌결합 체인(a+b+c+…)은 좌 스파인이 N-deep 라
/// 순수 재귀면 스택 오버플로우(#4123) → 좌 스파인을 명시 스택으로 평탄화해 반복 처리한다.
/// 방문 순서(최좌단 leaf → 각 right bottom-up = 소스순)와 "자식 불변 시 idx 재사용" 동작은
/// 재귀판과 동일 → 출력 byte-identical.
pub fn visitBinaryNode(self: anytype, idx: NodeIndex) Error!NodeIndex {
    const node = self.ast.getNode(idx);
    const root_left = node.data.binary.left;

    // 빠른 경로(depth 1, 대부분의 `a OP b`): 좌 자식이 스파인 노드가 아니면 기존 재귀형(할당 0).
    if (!binarySpineContinues(self, root_left)) {
        const old_right = node.data.binary.right;
        const new_left = try self.visitNode(root_left);
        const new_right = try self.visitNode(old_right);
        if (new_left == root_left and new_right == old_right) return idx;
        return self.ast.addNode(.{ .tag = node.tag, .span = node.span, .data = .{ .binary = .{
            .left = new_left,
            .right = new_right,
            .flags = node.data.binary.flags,
        } } });
    }

    // 느린 경로: 좌 스파인 평탄화. 체인당 1회만 할당(노드당 아님).
    var spine: std.ArrayListUnmanaged(NodeIndex) = .empty;
    defer spine.deinit(self.allocator);
    var cur = idx;
    while (true) {
        try spine.append(self.allocator, cur);
        const left = self.ast.getNode(cur).data.binary.left;
        if (binarySpineContinues(self, left)) cur = left else break;
    }
    // 최좌단 leaf(최하단 스파인 노드의 left)는 정식 dispatch 로 방문(여기서 lowering 가능).
    var acc = try self.visitNode(self.ast.getNode(spine.items[spine.items.len - 1]).data.binary.left);
    // bottom→top: 각 스파인 노드의 right 방문 후 재조립(자식 불변이면 원본 idx 재사용).
    // (재조립된 중간 스파인 노드는 visitNode 를 거치지 않아 propagateSymbolId 가 호출되지
    //  않지만, binary/logical 연산자 노드는 symbol_id 를 갖지 않으므로 무해. leaf/right 는
    //  여전히 visitNode 로 방문돼 정상 전파된다.)
    var i = spine.items.len;
    while (i > 0) : (i -= 1) {
        const sidx = spine.items[i - 1];
        const n = self.ast.getNode(sidx);
        const old_right = n.data.binary.right;
        const new_right = try self.visitNode(old_right);
        if (acc == n.data.binary.left and new_right == old_right) {
            acc = sidx;
        } else {
            acc = try self.ast.addNode(.{ .tag = n.tag, .span = n.span, .data = .{ .binary = .{
                .left = acc,
                .right = new_right,
                .flags = n.data.binary.flags,
            } } });
        }
    }
    return acc;
}

/// unary/update expression: extra = [operand, operator_and_flags]
pub fn visitUnaryExtra(self: anytype, node: Node) Error!NodeIndex {
    const Transformer = @TypeOf(self.*);
    const e = node.data.extra;
    if (e + 1 >= self.ast.extra_data.items.len) return NodeIndex.none;

    const operand_idx = self.readNodeIdx(e, 0);
    const op_flags = self.readU32(e, 1);

    // private field update: this.#x++ -> _x.set(this, _x.get(this) + 1)
    // super property update: super.x++ -> __superSet 기반 lowering
    // (#3680-F4) needsSuperLowering 케이스도 outer 가드에 포함 — 추출된 standalone fn body
    // 안에서 `super.x++` 가 그대로 leak 되면 raw `super` SyntaxError 또는 invalid LHS `(__superGet(...))++`
    // 가 emit 된다. 두 lowering 은 독립적으로 가드한다 (super 와 private field 는 서로 다른 operand).
    if (node.tag == .update_expression) {
        const operand = self.ast.getNode(operand_idx);
        if (self.needsSuperLowering()) {
            if (es2015_class.ES2015Class(Transformer).lowerSuperPropertyUpdate(self, operand, op_flags, node.span)) |result| {
                return try result;
            }
        }
        if ((self.options.unsupported.class or self.options.unsupported.class_private_field) and
            operand.tag == .private_field_expression)
        {
            if (es2015_class.ES2015Class(Transformer).lowerPrivateFieldUpdate(self, operand, op_flags, node.span)) |result| {
                return try result;
            }
        }
    }

    // `delete obj?.a?.b` lowering: 일반 optional chain lowering 결과인
    // `delete (cond ? void 0 : _a.b)` 는 ConditionalExpression이라 Reference가 아니어서 실제 삭제 안 됨.
    // -> `cond ? true : delete _a.b` 형태로 별도 lowering.
    if (node.tag == .unary_expression and self.options.unsupported.optional_chaining and
        (op_flags & 0xff) == @intFromEnum(token_mod.Kind.kw_delete))
    {
        const operand = self.ast.getNode(operand_idx);
        if (es2020.ES2020(Transformer).findOptionalChainBase(self, operand)) |base_idx| {
            return es2020.ES2020(Transformer).lowerOptionalChainCtx(self, operand, base_idx, .delete);
        }
    }

    const new_operand = try self.visitNode(operand_idx);
    const new_extra = try self.ast.addExtras(&.{ @intFromEnum(new_operand), op_flags });
    return self.ast.addNode(.{ .tag = node.tag, .span = node.span, .data = .{ .extra = new_extra } });
}

/// member expression: extra = [object, property, flags]
pub fn visitMemberExpression(self: anytype, node: Node) Error!NodeIndex {
    const e = node.data.extra;
    if (e + 2 >= self.ast.extra_data.items.len) return NodeIndex.none;

    // const enum 인라인: `EnumName.Member` -> literal
    if (try self.tryInlineConstEnumMember(node)) |inlined| return inlined;

    const left_idx = self.readNodeIdx(e, 0);
    const right_idx = self.readNodeIdx(e, 1);
    const flags = self.readU32(e, 2);
    const new_left = try self.visitNode(left_idx);
    // computed member의 property만 expression이다. dot/private member의 property는
    // lexical reference가 아니라 property key라 block-scoping rename 대상이 아니다.
    const new_right = if (node.tag == .computed_member_expression)
        try self.visitNode(right_idx)
    else
        right_idx;
    const new_extra = try self.ast.addExtras(&.{ @intFromEnum(new_left), @intFromEnum(new_right), flags });
    return self.ast.addNode(.{ .tag = node.tag, .span = node.span, .data = .{ .extra = new_extra } });
}

/// 삼항 노드: a, b, c를 재귀 방문 후 복사.
pub fn visitTernaryNode(self: anytype, node: Node) Error!NodeIndex {
    const new_a = try self.visitNode(node.data.ternary.a);
    const new_b = try self.visitNode(node.data.ternary.b);
    const new_c = try self.visitNode(node.data.ternary.c);
    return self.ast.addNode(.{
        .tag = node.tag,
        .span = node.span,
        .data = .{ .ternary = .{ .a = new_a, .b = new_b, .c = new_c } },
    });
}

/// 노드의 symbol_id 조회 (없으면 null).
pub fn getSymbolIdAt(self: anytype, idx: NodeIndex) ?u32 {
    if (idx.isNone()) return null;
    const i = @intFromEnum(idx);
    if (i >= self.symbol_ids.items.len) return null;
    return self.symbol_ids.items[i];
}

/// extra 인덱스로 NodeIndex 읽기.
pub fn readNodeIdx(self: anytype, extra_start: u32, offset: u32) NodeIndex {
    return @enumFromInt(self.ast.extra_data.items[extra_start + offset]);
}

/// extra 인덱스로 u32 읽기.
pub fn readU32(self: anytype, extra_start: u32, offset: u32) u32 {
    return self.ast.extra_data.items[extra_start + offset];
}

/// 노드를 extra_data로 만들어 새 AST에 추가.
pub fn addExtraNode(self: anytype, tag: Tag, span: Span, extras: []const u32) Error!NodeIndex {
    const new_extra = try self.ast.addExtras(extras);
    return self.ast.addNode(.{ .tag = tag, .span = span, .data = .{ .extra = new_extra } });
}
