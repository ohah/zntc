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
    const old_operand = node.data.unary.operand;
    const new_operand = try self.visitNode(old_operand);
    // 자식 unchanged -> 부모도 identity. ast.addNode 호출 제거.
    if (new_operand == old_operand) return idx;
    return self.ast.addNode(.{
        .tag = node.tag,
        .span = node.span,
        .data = .{ .unary = .{ .operand = new_operand, .flags = node.data.unary.flags } },
    });
}

/// 이항 노드: left, right를 재귀 방문 후 복사.
pub fn visitBinaryNode(self: anytype, idx: NodeIndex) Error!NodeIndex {
    const node = self.ast.getNode(idx);
    const old_left = node.data.binary.left;
    const old_right = node.data.binary.right;
    const new_left = try self.visitNode(old_left);
    const new_right = try self.visitNode(old_right);
    if (new_left == old_left and new_right == old_right) return idx;
    return self.ast.addNode(.{
        .tag = node.tag,
        .span = node.span,
        .data = .{ .binary = .{
            .left = new_left,
            .right = new_right,
            .flags = node.data.binary.flags,
        } },
    });
}

/// unary/update expression: extra = [operand, operator_and_flags]
pub fn visitUnaryExtra(self: anytype, node: Node) Error!NodeIndex {
    const Transformer = @TypeOf(self.*);
    const e = node.data.extra;
    if (e + 1 >= self.ast.extra_data.items.len) return NodeIndex.none;

    const operand_idx = self.readNodeIdx(e, 0);
    const op_flags = self.readU32(e, 1);

    // private field update: this.#x++ -> _x.set(this, _x.get(this) + 1)
    if (node.tag == .update_expression and (self.options.unsupported.class or self.options.unsupported.class_private_field)) {
        const operand = self.ast.getNode(operand_idx);
        if (self.needsSuperLowering()) {
            if (es2015_class.ES2015Class(Transformer).lowerSuperPropertyUpdate(self, operand, op_flags, node.span)) |result| {
                return try result;
            }
        }
        if (operand.tag == .private_field_expression) {
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
