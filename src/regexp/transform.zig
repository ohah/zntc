//! regexp AST transform 패스 (#1475 PR2 정공법).
//!
//! parse → **이 패스가 새 AST 를 재빌드** → dumb printer 직렬화.
//! (babel regjsparser→AST transform→regjsgen, oxc AST→transform→Display 와 동형.
//!  printer 는 변환을 모른다 — serializer 와 transform 의 관심사 분리.)
//!
//! 입력 AST 는 불변(소유권은 호출자). 출력 Result.ast 는 새 노드/extra 배열을
//! 소유한다. name 슬라이스는 입력 source 를 가리키므로 Result 사용 동안
//! 입력 AST 의 source 가 살아 있어야 한다.

const std = @import("std");
const ast = @import("ast.zig");

const NodeIndex = ast.NodeIndex;
const Node = ast.Node;
const UNNAMED = std.math.maxInt(u32);

pub const Options = struct {
    /// `.` (character class 밖) → `[\s\S]`
    dotall: bool = false,
    /// `(?<name>…)` → `(…)`, `\k<name>` → `\N` (positional)
    strip_named: bool = false,
    /// astral `\u{XXXXX}` (cp>0xFFFF) → surrogate pair 2 노드
    unicode_brace: bool = false,
};

pub const NamedGroup = struct {
    name: []const u8, // 입력 source 슬라이스
    index: u32, // 1-based capture index
};

pub const Result = struct {
    ast: ast.RegExpAst,
    named_groups: []NamedGroup,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Result) void {
        self.ast.deinit();
        self.allocator.free(self.named_groups);
    }
};

pub const TransformError = error{OutOfMemory};

/// 입력 AST 의 capture group 을 source(=opening paren) 순서로 세어
/// named group 의 (name, 1-based index) 를 수집한다.
fn collectNamed(
    in: ast.RegExpAst,
    idx: NodeIndex,
    ctr: *u32,
    out: *std.ArrayList(NamedGroup),
    a: std.mem.Allocator,
) TransformError!void {
    if (idx == .none) return;
    const n = in.getNode(idx);
    switch (n.tag) {
        .capturing_group => {
            ctr.* += 1;
            if (n.data[0] != UNNAMED) {
                try out.append(a, .{ .name = in.source[n.data[0]..n.data[1]], .index = ctr.* });
            }
            try collectNamed(in, @enumFromInt(n.data[2]), ctr, out, a);
        },
        .ignore_group => try collectNamed(in, @enumFromInt(n.data[2]), ctr, out, a),
        .lookaround_assertion => try collectNamed(in, @enumFromInt(n.data[1]), ctr, out, a),
        .quantifier => try collectNamed(in, n.getQuantifierBody(), ctr, out, a),
        .disjunction, .alternative => {
            for (in.getNodeList(n.getNodeList())) |c| {
                try collectNamed(in, @enumFromInt(c), ctr, out, a);
            }
        },
        // character class 내부엔 capturing group 이 올 수 없음.
        else => {},
    }
}

const Builder = struct {
    nodes: std.ArrayList(Node) = .empty,
    extra: std.ArrayList(u32) = .empty,
    a: std.mem.Allocator,

    fn add(self: *Builder, n: Node) TransformError!NodeIndex {
        try self.nodes.append(self.a, n);
        return @enumFromInt(@as(u32, @intCast(self.nodes.items.len - 1)));
    }

    fn addList(self: *Builder, ids: []const u32) TransformError!ast.NodeList {
        const start: u32 = @intCast(self.extra.items.len);
        try self.extra.appendSlice(self.a, ids);
        return .{ .start = start, .len = @intCast(ids.len) };
    }

    fn deinitErr(self: *Builder) void {
        self.nodes.deinit(self.a);
        self.extra.deinit(self.a);
    }
};

const T = struct {
    in: ast.RegExpAst,
    b: *Builder,
    opts: Options,
    names: []const NamedGroup,
    /// character class 내부 여부. 파서는 class 안 `\k<n>` 도 named_reference
    /// 노드로 내지만 ECMAScript 상 backreference 가 아니므로(ad-hoc 도
    /// `!in_class` 에서만 치환) strip_named 을 적용하지 않는다.
    in_class: bool = false,

    fn resolveIndex(self: *T, name: []const u8) ?u32 {
        for (self.names) |g| {
            if (std.mem.eql(u8, g.name, name)) return g.index;
        }
        return null;
    }

    /// surrogate pair 2 노드를 list 에 push (cp>0xFFFF).
    fn pushSurrogate(self: *T, span: ast.Span, cp: u32, out: *std.ArrayList(u32)) TransformError!void {
        // 표준 UTF-16 surrogate 분해 (ECMA-262). regexp 는 transformer 레이어에
        // 의존하면 안 되므로 동일 공식이 unicode_escape_lower 와 독립 존재.
        const v = cp - 0x10000;
        const hi: u32 = 0xD800 | (v >> 10);
        const lo: u32 = 0xDC00 | (v & 0x3FF);
        const uk = @intFromEnum(ast.CharacterKind.unicode_escape);
        const a = try self.b.add(.{ .tag = .character, .span = span, .data = .{ hi, uk, 0 } });
        const c = try self.b.add(.{ .tag = .character, .span = span, .data = .{ lo, uk, 0 } });
        try out.append(self.b.a, @intFromEnum(a));
        try out.append(self.b.a, @intFromEnum(c));
    }

    fn makeDotAllClass(self: *T, span: ast.Span) TransformError!NodeIndex {
        const sk = @intFromEnum(ast.CharacterClassEscapeKind.s);
        const nsk = @intFromEnum(ast.CharacterClassEscapeKind.negative_s);
        const e_s = try self.b.add(.{ .tag = .character_class_escape, .span = span, .data = .{ sk, 0, 0 } });
        const e_ns = try self.b.add(.{ .tag = .character_class_escape, .span = span, .data = .{ nsk, 0, 0 } });
        const list = try self.b.addList(&.{ @intFromEnum(e_s), @intFromEnum(e_ns) });
        // character_class data: [flags, list_start, list_len], flags bit0=neg, bits1-2=kind(union=0)
        return self.b.add(.{ .tag = .character_class, .span = span, .data = .{ 0, list.start, list.len } });
    }

    fn isAstralUnicodeEscape(n: Node) bool {
        if (n.tag != .character) return false;
        const kind: ast.CharacterKind = @enumFromInt(n.data[1]);
        return kind == .unicode_escape and n.data[0] > 0xFFFF;
    }

    /// list 컨텍스트(alternative term / class atom / class_string char): 자식이
    /// 1→N 으로 확장될 수 있음 (astral→surrogate 2개).
    fn expandList(self: *T, list: ast.NodeList) TransformError!ast.NodeList {
        var ids: std.ArrayList(u32) = .empty;
        defer ids.deinit(self.b.a);
        for (self.in.getNodeList(list)) |cid| {
            const child: NodeIndex = @enumFromInt(cid);
            const cn = self.in.getNode(child);
            if (self.opts.unicode_brace and isAstralUnicodeEscape(cn)) {
                try self.pushSurrogate(cn.span, cn.data[0], &ids);
            } else {
                try ids.append(self.b.a, @intFromEnum(try self.node(child)));
            }
        }
        return self.b.addList(ids.items);
    }

    /// 정확히 1 노드를 내는 컨텍스트(group/quantifier/lookaround body, range
    /// endpoint). astral→surrogate split 은 단일 컨텍스트에서 불가하므로
    /// 발생 시 그대로 둔다 (range endpoint 의 astral — 테스트 없음, ES5
    /// 다운레벨 불가의 본질적 한계. ad-hoc 도 깨진 출력이었음).
    fn node(self: *T, idx: NodeIndex) TransformError!NodeIndex {
        if (idx == .none) return .none;
        const n = self.in.getNode(idx);
        switch (n.tag) {
            .disjunction => {
                var ids: std.ArrayList(u32) = .empty;
                defer ids.deinit(self.b.a);
                for (self.in.getNodeList(n.getNodeList())) |c| {
                    try ids.append(self.b.a, @intFromEnum(try self.node(@enumFromInt(c))));
                }
                const l = try self.b.addList(ids.items);
                return self.b.add(.{ .tag = .disjunction, .span = n.span, .data = .{ l.start, l.len, 0 } });
            },
            .alternative => {
                const l = try self.expandList(n.getNodeList());
                return self.b.add(.{ .tag = .alternative, .span = n.span, .data = .{ l.start, l.len, 0 } });
            },
            .boundary_assertion,
            .character,
            .character_class_escape,
            .unicode_property_escape,
            .indexed_reference,
            => return self.b.add(n),
            .dot => {
                if (self.opts.dotall) return self.makeDotAllClass(n.span);
                return self.b.add(n);
            },
            .named_reference => {
                if (self.opts.strip_named and !self.in_class) {
                    if (self.resolveIndex(self.in.source[n.data[0]..n.data[1]])) |gi| {
                        return self.b.add(.{ .tag = .indexed_reference, .span = n.span, .data = .{ gi, 0, 0 } });
                    }
                }
                return self.b.add(n); // 못 찾으면 보존 (ad-hoc 동일)
            },
            .lookaround_assertion => {
                const body = try self.node(@enumFromInt(n.data[1]));
                return self.b.add(.{ .tag = .lookaround_assertion, .span = n.span, .data = .{ n.data[0], @intFromEnum(body), 0 } });
            },
            .character_class => {
                const saved = self.in_class;
                self.in_class = true;
                const l = try self.expandList(n.getClassBody());
                self.in_class = saved;
                return self.b.add(.{ .tag = .character_class, .span = n.span, .data = .{ n.data[0], l.start, l.len } });
            },
            .character_class_range => {
                const mn = try self.node(@enumFromInt(n.data[0]));
                const mx = try self.node(@enumFromInt(n.data[1]));
                return self.b.add(.{ .tag = .character_class_range, .span = n.span, .data = .{ @intFromEnum(mn), @intFromEnum(mx), 0 } });
            },
            .class_string_disjunction => {
                var ids: std.ArrayList(u32) = .empty;
                defer ids.deinit(self.b.a);
                for (self.in.getNodeList(n.getNodeList())) |c| {
                    try ids.append(self.b.a, @intFromEnum(try self.node(@enumFromInt(c))));
                }
                const l = try self.b.addList(ids.items);
                return self.b.add(.{ .tag = .class_string_disjunction, .span = n.span, .data = .{ l.start, l.len, 0 } });
            },
            .class_string => {
                const l = try self.expandList(n.getNodeList());
                return self.b.add(.{ .tag = .class_string, .span = n.span, .data = .{ l.start, l.len, 0 } });
            },
            .capturing_group => {
                const body = try self.node(@enumFromInt(n.data[2]));
                const name0: u32 = if (self.opts.strip_named) UNNAMED else n.data[0];
                const name1: u32 = if (self.opts.strip_named) 0 else n.data[1];
                return self.b.add(.{ .tag = .capturing_group, .span = n.span, .data = .{ name0, name1, @intFromEnum(body) } });
            },
            .ignore_group => {
                const body = try self.node(@enumFromInt(n.data[2]));
                return self.b.add(.{ .tag = .ignore_group, .span = n.span, .data = .{ n.data[0], n.data[1], @intFromEnum(body) } });
            },
            .quantifier => {
                const body = try self.node(n.getQuantifierBody());
                const greedy: u32 = if (n.isGreedy()) 0x80000000 else 0;
                const packed_body = (@intFromEnum(body) & 0x7FFFFFFF) | greedy;
                return self.b.add(.{ .tag = .quantifier, .span = n.span, .data = .{ n.data[0], n.data[1], packed_body } });
            },
        }
    }
};

pub fn transform(in: ast.RegExpAst, opts: Options, allocator: std.mem.Allocator) TransformError!Result {
    var ng: std.ArrayList(NamedGroup) = .empty;
    errdefer ng.deinit(allocator);
    var ctr: u32 = 0;
    try collectNamed(in, in.root, &ctr, &ng, allocator);

    var b = Builder{ .a = allocator };
    errdefer b.deinitErr();
    var t = T{ .in = in, .b = &b, .opts = opts, .names = ng.items };
    const new_root = try t.node(in.root);

    const nodes = try b.nodes.toOwnedSlice(allocator);
    errdefer allocator.free(nodes);
    const extra = try b.extra.toOwnedSlice(allocator);
    errdefer allocator.free(extra);
    const named = try ng.toOwnedSlice(allocator);

    return .{
        .ast = .{
            .nodes = nodes,
            .extra_data = extra,
            .root = new_root,
            .source = in.source,
            .allocator = allocator,
        },
        .named_groups = named,
        .allocator = allocator,
    };
}
