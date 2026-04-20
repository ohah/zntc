//! ZTS AST 공통 순회 유틸 — 자식 노드 iterator.
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
