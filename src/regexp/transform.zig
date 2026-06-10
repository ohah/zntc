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
const cps = @import("codepoint_set.zig");
const iu_fold = @import("iu_case_fold.zig");
const group_name = @import("group_name.zig");

const NodeIndex = ast.NodeIndex;
const Node = ast.Node;
const UNNAMED = std.math.maxInt(u32);
const UESC = @intFromEnum(ast.CharacterKind.unicode_escape);

/// ECMAScript `\s` 집합 (WhiteSpace + LineTerminator). 전부 BMP.
const WS_RANGES = [_][2]u32{
    .{ 0x09, 0x0D },     .{ 0x20, 0x20 },     .{ 0xA0, 0xA0 },     .{ 0x1680, 0x1680 },
    .{ 0x2000, 0x200A }, .{ 0x2028, 0x2029 }, .{ 0x202F, 0x202F }, .{ 0x205F, 0x205F },
    .{ 0x3000, 0x3000 }, .{ 0xFEFF, 0xFEFF },
};

pub const Options = struct {
    /// `.` (character class 밖) → `[\s\S]`
    dotall: bool = false,
    /// `(?<name>…)` → `(…)`, `\k<name>` → `\N` (positional)
    strip_named: bool = false,
    /// astral `\u{XXXXX}` (cp>0xFFFF) → surrogate pair 2 노드
    unicode_brace: bool = false,
    /// `i` flag 활성 여부. negated class 의 정확 다운레벨은 case-fold 와
    /// 얽히므로(#3511), `i`+`u` negated 는 보수적으로 게이트(미변환).
    ignore_case: bool = false,
};

pub const NamedGroup = struct {
    name: []const u8, // 입력 source 슬라이스
    index: u32, // 1-based capture index
};

pub const Result = struct {
    ast: ast.RegExpAst,
    named_groups: []NamedGroup,
    /// unicode_brace 요청 시, astral 을 정확히 ES5 로 내리지 못한 구문
    /// (negated/\p{}/class_string 등)을 만났는가. true 면 호출자는 `u`
    /// flag 를 strip 하면 안 된다 (silent 오변환 방지 — 부분 커버리지).
    astral_u_incomplete: bool,
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
    /// 정확히 다운레벨 못한 astral 구문 발견 (lower() 가 u-strip 보류 판단).
    astral_u_incomplete: bool = false,

    /// surrogate pair 2 노드를 list 에 push (cp>0xFFFF).
    fn pushSurrogate(self: *T, span: ast.Span, cp: u32, out: *std.ArrayList(u32)) TransformError!void {
        const sp = cps.splitSurrogatePair(cp);
        const a = try self.b.add(.{ .tag = .character, .span = span, .data = .{ sp.hi, UESC, 0 } });
        const c = try self.b.add(.{ .tag = .character, .span = span, .data = .{ sp.lo, UESC, 0 } });
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

    // ── #3509: positive character class 의 astral → surrogate-alternation ──

    fn mkChar(self: *T, cp: u32, span: ast.Span) TransformError!NodeIndex {
        return self.b.add(.{ .tag = .character, .span = span, .data = .{ cp, UESC, 0 } });
    }

    /// character 노드(또는 그 인덱스)의 codepoint. character 아니면 null.
    fn charCp(self: *T, idx: NodeIndex) ?u32 {
        const cn = self.in.getNode(idx);
        return if (cn.tag == .character) cn.data[0] else null;
    }

    /// class body 에 astral(cp>0xFFFF) 멤버가 있는가 (빠른 사전 판정).
    fn classHasAstral(self: *T, n: Node) bool {
        for (self.in.getNodeList(n.getClassBody())) |cid| {
            const m = self.in.getNode(@enumFromInt(cid));
            switch (m.tag) {
                .character => if (m.data[0] > 0xFFFF) return true,
                .character_class_range => {
                    if (self.charCp(@enumFromInt(m.data[1]))) |mx| if (mx > 0xFFFF) return true;
                },
                else => {},
            }
        }
        return false;
    }

    /// class body → CodePointSet. 단순 positive(character/range/\d\w\s)만
    /// 지원. negative-escape(\D\W\S)/property/class_string/nested → false.
    fn collectClassSet(self: *T, n: Node, set: *cps.CodePointSet) TransformError!bool {
        const a = self.b.a;
        for (self.in.getNodeList(n.getClassBody())) |cid| {
            const m = self.in.getNode(@enumFromInt(cid));
            switch (m.tag) {
                .character => try set.addOne(a, m.data[0]),
                .character_class_range => {
                    const lo = self.charCp(@enumFromInt(m.data[0])) orelse return false;
                    const hi = self.charCp(@enumFromInt(m.data[1])) orelse return false;
                    try set.addRange(a, lo, hi);
                },
                .character_class_escape => {
                    switch (@as(ast.CharacterClassEscapeKind, @enumFromInt(m.data[0]))) {
                        .d => try set.addRange(a, 0x30, 0x39),
                        .w => {
                            try set.addRange(a, 0x30, 0x39);
                            try set.addRange(a, 0x41, 0x5A);
                            try set.addRange(a, 0x61, 0x7A);
                            try set.addOne(a, 0x5F);
                        },
                        .s => for (WS_RANGES) |r| try set.addRange(a, r[0], r[1]),
                        // \D \W \S = 보수(astral 포함) — slice 미지원.
                        else => return false,
                    }
                },
                // property/class_string/nested class → slice 미지원.
                else => return false,
            }
        }
        return true;
    }

    /// i+u: set 을 ECMAScript simple case-fold 등가로 확장 (#3511).
    /// regexpu `getCaseEquivalents(cp, UNICODE)` 1-pass 와 동형.
    /// cp 순회는 class span 비례 — 전범위 `[\u{0}-\u{10FFFF}]/iu` 는 ~수십ms
    /// (Unicode-bounded, attacker-unbounded 아님). cold path 이므로 허용.
    fn foldExpand(self: *T, set: *cps.CodePointSet) TransformError!void {
        var extra: std.ArrayList(u32) = .empty;
        defer extra.deinit(self.b.a);
        for (set.items()) |r| {
            var cp = r.min;
            while (true) : (cp += 1) {
                try iu_fold.appendEquivalents(cp, &extra, self.b.a);
                if (cp == r.max) break;
            }
        }
        for (extra.items) |e| try set.addOne(self.b.a, e);
        try set.normalize(self.b.a);
    }

    /// 단일 → `character`(\uX), 범위 → `character_class_range` 노드.
    /// class body 의 직접 자식으로 쓰는 형태(클래스 미포장).
    fn rangeChild(self: *T, mn: u32, mx: u32, span: ast.Span) TransformError!NodeIndex {
        if (mn == mx) return self.mkChar(mn, span);
        const a = try self.mkChar(mn, span);
        const b = try self.mkChar(mx, span);
        return self.b.add(.{ .tag = .character_class_range, .span = span, .data = .{ @intFromEnum(a), @intFromEnum(b), 0 } });
    }

    /// surrogate 조각의 standalone atom: 단일 → `\uX`, 범위 → `[\uX-\uY]`.
    fn surAtom(self: *T, mn: u32, mx: u32, span: ast.Span) TransformError!NodeIndex {
        const rc = try self.rangeChild(mn, mx, span);
        if (mn == mx) return rc; // `\uX`
        const l = try self.b.addList(&.{@intFromEnum(rc)});
        return self.b.add(.{ .tag = .character_class, .span = span, .data = .{ 0, l.start, l.len } });
    }

    /// CodePointSet → `(?:[bmp]|\uHi[\uLo-\uLo]|…)` ignore_group.
    fn buildAstralClassRewrite(self: *T, set: *cps.CodePointSet, span: ast.Span) TransformError!NodeIndex {
        try set.normalize(self.b.a);
        var alts: std.ArrayList(u32) = .empty;
        defer alts.deinit(self.b.a);

        // BMP 부분 → 단일 character_class alternative.
        var bmp_kids: std.ArrayList(u32) = .empty;
        defer bmp_kids.deinit(self.b.a);
        var pieces: std.ArrayList(cps.Piece) = .empty;
        defer pieces.deinit(self.b.a);

        for (set.items()) |r| {
            if (r.min <= 0xFFFF) {
                try bmp_kids.append(self.b.a, @intFromEnum(try self.rangeChild(r.min, @min(r.max, 0xFFFF), span)));
            }
            if (r.max >= 0x10000) {
                try cps.encodeSurrogateRange(@max(r.min, 0x10000), r.max, &pieces, self.b.a);
            }
        }
        if (bmp_kids.items.len != 0) {
            const cl = try self.b.addList(bmp_kids.items);
            const cls = try self.b.add(.{ .tag = .character_class, .span = span, .data = .{ 0, cl.start, cl.len } });
            const al = try self.b.addList(&.{@intFromEnum(cls)});
            try alts.append(self.b.a, @intFromEnum(try self.b.add(.{ .tag = .alternative, .span = span, .data = .{ al.start, al.len, 0 } })));
        }
        for (pieces.items) |p| {
            const hi = try self.surAtom(p.hi_min, p.hi_max, span);
            const lo = try self.surAtom(p.lo_min, p.lo_max, span);
            const al = try self.b.addList(&.{ @intFromEnum(hi), @intFromEnum(lo) });
            try alts.append(self.b.a, @intFromEnum(try self.b.add(.{ .tag = .alternative, .span = span, .data = .{ al.start, al.len, 0 } })));
        }

        const dl = try self.b.addList(alts.items);
        const disj = try self.b.add(.{ .tag = .disjunction, .span = span, .data = .{ dl.start, dl.len, 0 } });
        // ignore_group: enabling=0, disabling=0 → `(?:…)`
        return self.b.add(.{ .tag = .ignore_group, .span = span, .data = .{ 0, 0, @intFromEnum(disj) } });
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
                    const name = self.in.source[n.data[0]..n.data[1]];
                    var count: u32 = 0;
                    var first: u32 = 0;
                    for (self.names) |g| {
                        if (group_name.eqlCanonical(g.name, name)) {
                            if (count == 0) first = g.index;
                            count += 1;
                        }
                    }
                    if (count == 1) {
                        return self.b.add(.{ .tag = .indexed_reference, .span = n.span, .data = .{ first, 0, 0 } });
                    }
                    if (count > 1) {
                        // ES2025 duplicate named group: `\k<y>` 는 단일 `\N` 으로 표현
                        // 불가 → 모든 인덱스의 backref 연접 `(?:\1\2)` 로 내린다.
                        // 비참여 그룹 backref 는 빈 문자열 매치라 참여한 쪽 값만
                        // 남는다 — `$<y>`→`$1$2` 와 동일 트릭, regexpu 동형 (#4198).
                        // `(?:)` 래핑은 quantifier (`\k<y>+`) 안전용.
                        var refs: std.ArrayList(u32) = .empty;
                        defer refs.deinit(self.b.a);
                        for (self.names) |g| {
                            if (group_name.eqlCanonical(g.name, name)) {
                                const r = try self.b.add(.{ .tag = .indexed_reference, .span = n.span, .data = .{ g.index, 0, 0 } });
                                try refs.append(self.b.a, @intFromEnum(r));
                            }
                        }
                        const l = try self.b.addList(refs.items);
                        const seq = try self.b.add(.{ .tag = .alternative, .span = n.span, .data = .{ l.start, l.len, 0 } });
                        return self.b.add(.{ .tag = .ignore_group, .span = n.span, .data = .{ 0, 0, @intFromEnum(seq) } });
                    }
                }
                return self.b.add(n); // 못 찾으면 보존 (ad-hoc 동일)
            },
            .lookaround_assertion => {
                const body = try self.node(@enumFromInt(n.data[1]));
                return self.b.add(.{ .tag = .lookaround_assertion, .span = n.span, .data = .{ n.data[0], @intFromEnum(body), 0 } });
            },
            .character_class => {
                // u-strip 시 class 를 code-point set 으로 정확 다운레벨:
                //  - positive+astral (#3509): set → surrogate-alternation
                //  - negated (#3513): u 에선 code-point 의미 → complement
                //  - i+u (#3511): simple case-fold 등가 확장 후 재작성
                //    (positive/negated·BMP 무관 — u-전용 fold 보존). regexpu 동형.
                // positive+non-astral+non-i 는 u/non-u 동등 → 기존 경로 무변경.
                // 미지원(\p{}/class_string/\D\W\S) → incomplete → u 보존(오변환 0).
                if (self.opts.unicode_brace) {
                    const negative = (n.data[0] & 1) != 0;
                    if (negative or self.opts.ignore_case or self.classHasAstral(n)) {
                        var set = cps.CodePointSet{};
                        defer set.deinit(self.b.a);
                        if (try self.collectClassSet(n, &set)) {
                            if (self.opts.ignore_case) try self.foldExpand(&set);
                            if (negative) {
                                var comp = try set.complement(self.b.a);
                                defer comp.deinit(self.b.a);
                                return self.buildAstralClassRewrite(&comp, n.span);
                            }
                            return self.buildAstralClassRewrite(&set, n.span);
                        }
                        self.astral_u_incomplete = true;
                    }
                }
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
        .astral_u_incomplete = t.astral_u_incomplete,
        .allocator = allocator,
    };
}
