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
const SYM = @intFromEnum(ast.CharacterKind.symbol);

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
    /// ES2025 inline modifier 그룹 `(?i:…)`/`(?s:…)` 다운레벨 (#4210). 켜지면
    /// enabling i/s 영역을 fold/dot 재작성으로 baked-in 한 뒤 modifier 비트를
    /// strip 한다. disabling(`-i`/`-s`)·`m`·전역 /i on·u/astral 은 보수적 bail
    /// (그룹 보존 → kept_modifier → 호출자가 진단).
    lower_modifiers: bool = false,
    /// regex 가 `u`/`v` 플래그를 가졌는가 (#4210). i-fold 는 non-u(ASCII) 전용이라
    /// /u 영역에선 bail — 파서가 unicode_brace 를 끈 재변환에도 정확히 게이트.
    global_u: bool = false,
    /// 타겟이 lookbehind `(?<=…)`(ES2018)를 지원하는가 (#4210 PR3). m-modifier 의
    /// `^` 앵커 재작성이 lookbehind 를 출력하므로, false 면 m-lowering bail(보존).
    lookbehind_ok: bool = false,
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
    /// lower_modifiers 요청 시, 다운레벨 못해 출력에 보존된 modifier 그룹이 있는가
    /// (#4210). 호출자(lower→transpile/prepass)가 loud 진단을 띄운다.
    kept_modifier: bool,
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
    /// 영역별 effective s/i (#4211/#4225 → #4210). null=상속(global flag),
    /// true=(?s:)/(?i:) 으로 켜짐, false=(?-s:)/(?-i:) 으로 꺼짐. enclosing
    /// modifier group 진입 시 save/restore.
    ///   - 비-lowering 경로: `mod_s != false` ⟺ 옛 `mod_s_off_depth==0`,
    ///     `mod_i != null` ⟺ 옛 `mod_i_depth>0` (동작 보존).
    ///   - lowering 경로(#4210): effective 값으로 dot 재작성 / fold 확장.
    mod_s: ?bool = null,
    mod_i: ?bool = null,
    /// 영역별 effective m (#4210 PR3). `(?m:)` 영역의 `^`/`$` 는 multiline 앵커 →
    /// lookbehind/lookahead 로 재작성.
    mod_m: ?bool = null,
    /// 현재 i-enabling 영역에서 fold 못한 atom(비-ASCII/negated/복잡 class)을 만났는가
    /// (#4210 PR2b). 영역별 save/restore — true 면 ignore_group 이 i 비트를 보존(bail).
    i_fold_incomplete: bool = false,
    /// 다운레벨 못해 출력에 보존된 modifier 그룹이 있는가 (#4210). transpile/prepass 가
    /// transform 후 이 값으로 진단을 띄운다 (source-scan 보다 정확 — escape/flag/내용
    /// 의존 bail 을 정확 반영).
    kept_modifier: bool = false,

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

    // ── #4210 PR2b: ES2025 `(?i:…)` non-u ASCII case-fold ──

    /// ASCII 글자 c1·c2(대/소) → 리터럴 `[c1c2]` (.symbol 이라 글자는 escape 불필요).
    fn makeAsciiFoldClass(self: *T, c1: u32, c2: u32, span: ast.Span) TransformError!NodeIndex {
        const x = try self.b.add(.{ .tag = .character, .span = span, .data = .{ c1, SYM, 0 } });
        const y = try self.b.add(.{ .tag = .character, .span = span, .data = .{ c2, SYM, 0 } });
        const l = try self.b.addList(&.{ @intFromEnum(x), @intFromEnum(y) });
        return self.b.add(.{ .tag = .character_class, .span = span, .data = .{ 0, l.start, l.len } });
    }

    /// non-u ASCII case-fold: set 의 ASCII 글자에 대/소 swap 을 추가. set 에 비-ASCII
    /// (>=0x80) 멤버가 있으면 false(= fold 불가, 호출자 bail). Kelvin(U+212A)·ſ(U+017F)
    /// 같은 u-전용 special fold 는 포함하지 않음 — non-u Canonicalize 는 toUpperCase
    /// 기반이라 이들이 ASCII 로 collapse 되지 않는다(over-fold 미스컴파일 방지).
    fn asciiFoldExpand(self: *T, set: *cps.CodePointSet) TransformError!bool {
        var extra: std.ArrayList(u32) = .empty;
        defer extra.deinit(self.b.a);
        for (set.items()) |r| {
            if (r.max >= 0x80) return false; // 비-ASCII 멤버 → fold 불가
            var cp = r.min;
            while (true) : (cp += 1) {
                if (cp >= 'A' and cp <= 'Z') {
                    try extra.append(self.b.a, cp + 0x20);
                } else if (cp >= 'a' and cp <= 'z') {
                    try extra.append(self.b.a, cp - 0x20);
                }
                if (cp == r.max) break;
            }
        }
        for (extra.items) |e| try set.addOne(self.b.a, e);
        try set.normalize(self.b.a);
        return true;
    }

    /// BMP CodePointSet → 단일 `[…]` (범위/단일 자식, \uXXXX 표기 — 모든 특수문자 안전).
    fn buildBmpClass(self: *T, set: *cps.CodePointSet, span: ast.Span) TransformError!NodeIndex {
        var kids: std.ArrayList(u32) = .empty;
        defer kids.deinit(self.b.a);
        for (set.items()) |r| {
            try kids.append(self.b.a, @intFromEnum(try self.rangeChild(r.min, r.max, span)));
        }
        const l = try self.b.addList(kids.items);
        return self.b.add(.{ .tag = .character_class, .span = span, .data = .{ 0, l.start, l.len } });
    }

    /// i-enabling 영역에서 atom 을 fold 할 수 있는 컨텍스트인가 (#4210 PR2b).
    /// non-u(`!global_u`) + 전역 /i off(`!ignore_case`) + (?i:) 영역(mod_i==true).
    /// `!in_class`: character class 내부에선 per-char fold 금지 — class fold 가
    /// 통째로 처리(성공)하거나 bail(보존)한다. 안 막으면 fold 가 fall-through
    /// (bail) class body 안에서 글자를 `[cC]` 로 바꿔 중첩 class `[[cC]…]` 생성(#4210).
    fn inAsciiIFoldRegion(self: *T) bool {
        return self.opts.lower_modifiers and self.mod_i == true and
            !self.opts.ignore_case and !self.opts.global_u and !self.in_class;
    }

    // ── #4210 PR3: ES2025 `(?m:…)` multiline 앵커 재작성 ──

    /// m-enabling 영역의 `^`/`$` 를 재작성하는 컨텍스트인가. lookbehind 출력에
    /// 의존하므로 lookbehind 미지원 타겟(es2017↓)에선 false → m bail(보존).
    fn inMRewriteRegion(self: *T) bool {
        return self.opts.lower_modifiers and self.mod_m == true and self.opts.lookbehind_ok;
    }

    /// `[\n\r  ]` (ECMAScript LineTerminator 집합) character_class.
    fn makeNewlineClass(self: *T, span: ast.Span) TransformError!NodeIndex {
        const SE = @intFromEnum(ast.CharacterKind.single_escape);
        const nl = [_]struct { cp: u32, kind: u32 }{
            .{ .cp = 0x0A, .kind = SE }, // \n
            .{ .cp = 0x0D, .kind = SE }, // \r
            .{ .cp = 0x2028, .kind = UESC }, //
            .{ .cp = 0x2029, .kind = UESC }, //
        };
        var kids: [4]u32 = undefined;
        for (nl, 0..) |e, k| {
            kids[k] = @intFromEnum(try self.b.add(.{ .tag = .character, .span = span, .data = .{ e.cp, e.kind, 0 } }));
        }
        const l = try self.b.addList(&kids);
        return self.b.add(.{ .tag = .character_class, .span = span, .data = .{ 0, l.start, l.len } });
    }

    /// `^`(multiline) → `(?:^|(?<=[\n\r  ]))` (입력시작 OR 줄종결자 뒤).
    fn makeMLineStart(self: *T, span: ast.Span) TransformError!NodeIndex {
        const caret = try self.b.add(.{ .tag = .boundary_assertion, .span = span, .data = .{ @intFromEnum(ast.BoundaryAssertionKind.start), 0, 0 } });
        const lb = try self.makeLookaround(.lookbehind, span);
        return self.makeAltGroup(caret, lb, span);
    }

    /// `$`(multiline) → `(?:$|(?=[\n\r  ]))` (입력끝 OR 줄종결자 앞).
    fn makeMLineEnd(self: *T, span: ast.Span) TransformError!NodeIndex {
        const dollar = try self.b.add(.{ .tag = .boundary_assertion, .span = span, .data = .{ @intFromEnum(ast.BoundaryAssertionKind.end), 0, 0 } });
        const la = try self.makeLookaround(.lookahead, span);
        return self.makeAltGroup(dollar, la, span);
    }

    /// `(?<=[\n\r…])` / `(?=[\n\r…])` — body 는 파서 관례대로 disjunction 으로 감싼다.
    fn makeLookaround(self: *T, kind: ast.LookAroundAssertionKind, span: ast.Span) TransformError!NodeIndex {
        const body = try self.singleDisjunction(try self.makeNewlineClass(span), span);
        return self.b.add(.{ .tag = .lookaround_assertion, .span = span, .data = .{ @intFromEnum(kind), @intFromEnum(body), 0 } });
    }

    /// atom 하나를 `disjunction→alternative→atom` 으로 감싼다 (lookaround body 가
    /// 기대하는 파서 출력 구조). 단일 alt·단일 term 이라 인쇄는 atom 그대로.
    fn singleDisjunction(self: *T, atom: NodeIndex, span: ast.Span) TransformError!NodeIndex {
        const al = try self.b.addList(&.{@intFromEnum(atom)});
        const alt = try self.b.add(.{ .tag = .alternative, .span = span, .data = .{ al.start, al.len, 0 } });
        const dl = try self.b.addList(&.{@intFromEnum(alt)});
        return self.b.add(.{ .tag = .disjunction, .span = span, .data = .{ dl.start, dl.len, 0 } });
    }

    /// 두 atom 을 `(?:a|b)` 로 묶는다 (alternation in non-capturing group).
    fn makeAltGroup(self: *T, a: NodeIndex, b: NodeIndex, span: ast.Span) TransformError!NodeIndex {
        const a1l = try self.b.addList(&.{@intFromEnum(a)});
        const alt1 = try self.b.add(.{ .tag = .alternative, .span = span, .data = .{ a1l.start, a1l.len, 0 } });
        const a2l = try self.b.addList(&.{@intFromEnum(b)});
        const alt2 = try self.b.add(.{ .tag = .alternative, .span = span, .data = .{ a2l.start, a2l.len, 0 } });
        const dl = try self.b.addList(&.{ @intFromEnum(alt1), @intFromEnum(alt2) });
        const disj = try self.b.add(.{ .tag = .disjunction, .span = span, .data = .{ dl.start, dl.len, 0 } });
        return self.b.add(.{ .tag = .ignore_group, .span = span, .data = .{ 0, 0, @intFromEnum(disj) } });
    }

    fn isAstralUnicodeEscape(n: Node) bool {
        if (n.tag != .character) return false;
        const kind: ast.CharacterKind = @enumFromInt(n.data[1]);
        // #4237: literal astral (.symbol) 도 cp 단위 노드 — 동일 분할 대상.
        return (kind == .unicode_escape or kind == .symbol) and n.data[0] > 0xFFFF;
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
        // 이 함수는 union 의미 전용 — v-flag 의 `[a&&b]`(intersection)/`[a--b]`(subtraction)를
        // 평탄 union 으로 수집하면 교집합/차집합이 합집합으로 뒤집힌다(silent miscompile). non-union
        // 은 bail → 호출부가 원본 /u·/v 를 보존(astral_u_incomplete/i_fold_incomplete) → 오변환 0. #4307
        if (n.classKind() != .@"union") return false;
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
                // #4225: astral fast-path 도 fold 게이트 적용 (Deseret/Adlam 등
                // astral u-전용 등가) — 게이트 시 surrogate 분해 없이 보존 경로로.
                if ((self.opts.ignore_case or self.mod_i != null) and
                    iu_fold.hasEntry(cn.data[0]))
                {
                    self.astral_u_incomplete = true;
                    try ids.append(self.b.a, @intFromEnum(try self.node(child)));
                    continue;
                }
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
            .boundary_assertion => {
                // #4210 PR3: (?m:) 영역의 `^`/`$` → multiline 앵커 재작성.
                // `\b`/`\B` 는 m 무관 → 그대로.
                if (self.inMRewriteRegion()) {
                    switch (@as(ast.BoundaryAssertionKind, @enumFromInt(n.data[0]))) {
                        .start => return try self.makeMLineStart(n.span),
                        .end => return try self.makeMLineEnd(n.span),
                        else => {},
                    }
                }
                return self.b.add(n);
            },
            .character_class_escape,
            .unicode_property_escape,
            .indexed_reference,
            => return self.b.add(n),
            .character => {
                // #4237: 단일 노드 컨텍스트(quantifier body 등 — expandList 의
                // 1→2 surrogate 분할 불가 위치)의 astral 은 u-strip 시 의미가
                // 변함(`/😀+/u` 의 + 가 low surrogate 로 격하) → u 보존 게이트.
                if (self.opts.unicode_brace and n.data[0] > 0xFFFF) {
                    self.astral_u_incomplete = true;
                }
                // #4225: u-전용 fold 등가(Kelvin U+212A 등)를 가진 atom 은
                // u-strip 시 /i 의 non-unicode fold 로 등가가 소실 → u 보존 게이트
                // (#3509 "틀린 출력 0"). lower() 의 #4211 재변환이 전체 일관 보존.
                // i-유효성은 글로벌 /i 또는 (?i:) 영역(#4211 mod_i_depth) 둘 다.
                if (self.opts.unicode_brace and
                    (self.opts.ignore_case or self.mod_i != null))
                {
                    const kind: ast.CharacterKind = @enumFromInt(n.data[1]);
                    // literal(symbol) non-ASCII 는 파서가 UTF-8 byte 단위 노드라
                    // data[0] 이 코드포인트가 아님 — fold 판정 불가 → 보수 보존.
                    const fold_risk = if (kind == .symbol and n.data[0] >= 0x80)
                        true
                    else
                        iu_fold.hasEntry(n.data[0]);
                    if (fold_risk) self.astral_u_incomplete = true;
                }
                // #4210 PR2b: i-enabling 영역의 ASCII 글자 → [cC] non-u fold.
                if (self.inAsciiIFoldRegion()) {
                    const cp = n.data[0];
                    if (cp >= 'A' and cp <= 'Z') return try self.makeAsciiFoldClass(cp, cp + 0x20, n.span);
                    if (cp >= 'a' and cp <= 'z') return try self.makeAsciiFoldClass(cp, cp - 0x20, n.span);
                    // 비-ASCII atom 은 non-u fold 불가 → 영역 bail(그룹 i 비트 보존).
                    // ASCII 비-글자(숫자·기호·control)는 identity(그대로, bail 아님).
                    if (cp >= 0x80) self.i_fold_incomplete = true;
                }
                return self.b.add(n);
            },
            .dot => {
                // #4211: (?-s:) 안의 `.` 는 global /s 비적용 — 재작성 금지
                // (mod_s != false ⟺ 옛 mod_s_off_depth==0). #4210: (?s:) 영역
                // (mod_s==true) 은 lowering 시 dot 을 직접 dotall 화.
                if ((self.opts.dotall and self.mod_s != false) or
                    (self.opts.lower_modifiers and self.mod_s == true))
                    return self.makeDotAllClass(n.span);
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
                    // #4211: i-modifier 영역 안 class 는 영역별 유효 i 를 fold 확장에
                    // 반영할 수 없다 — u 보존(부분 커버리지, 틀린 출력 0, #3509 동형).
                    if (self.mod_i != null) {
                        self.astral_u_incomplete = true;
                    } else if (negative or self.opts.ignore_case or self.classHasAstral(n)) {
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
                // #4210 PR2b: non-u i-enabling 영역의 positive class → ASCII case-fold.
                // negated/비-ASCII/복잡(\p{}·class_string·\D\W\S·\s 포함) 는 bail(보존).
                if (self.inAsciiIFoldRegion()) {
                    const negative = (n.data[0] & 1) != 0;
                    if (negative) {
                        self.i_fold_incomplete = true; // negated non-u fold 미묘 → bail
                    } else {
                        var set = cps.CodePointSet{};
                        defer set.deinit(self.b.a);
                        if ((try self.collectClassSet(n, &set)) and (try self.asciiFoldExpand(&set))) {
                            return try self.buildBmpClass(&set, n.span);
                        }
                        self.i_fold_incomplete = true; // collect 실패 또는 비-ASCII → bail
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
                // modifier 비트: bit0=i, bit1=m, bit2=s (ast.zig ignore_group).
                const en = n.data[0]; // enabling
                const dis = n.data[1]; // disabling
                // in_class 와 동일한 save/restore 관용구 — 에러 경로에서도 오염 없음.
                // effective: enabling→true, disabling→false, 무관→상속(불변).
                const saved_s = self.mod_s;
                const saved_i = self.mod_i;
                const saved_m = self.mod_m;
                const saved_ifi = self.i_fold_incomplete;
                if (en & 0b100 != 0) self.mod_s = true;
                if (dis & 0b100 != 0) self.mod_s = false;
                if (en & 0b001 != 0) self.mod_i = true;
                if (dis & 0b001 != 0) self.mod_i = false;
                if (en & 0b010 != 0) self.mod_m = true;
                if (dis & 0b010 != 0) self.mod_m = false;
                self.i_fold_incomplete = false; // 이 영역의 fold-bail 만 집계
                defer {
                    self.mod_s = saved_s;
                    self.mod_i = saved_i;
                    self.mod_m = saved_m;
                    self.i_fold_incomplete = saved_ifi; // 내부 bail 은 상위로 누설 안 함
                }
                const body = try self.node(@enumFromInt(n.data[2]));
                if (!self.opts.lower_modifiers) {
                    return self.b.add(.{ .tag = .ignore_group, .span = n.span, .data = .{ en, dis, @intFromEnum(body) } });
                }
                // #4210 lowering: s-enabling 은 dot 이 body 에서 [\s\S] 로 baked-in →
                // 항상 strip. i-enabling 은 이 영역의 모든 atom 이 fold 됐을 때만
                // (비-bail, non-u, 전역 /i off) strip — bail 시 i 보존(이미 fold 된
                // atom 은 [cC] 라 i 적용이 no-op 이라 의미 동치). m-enabling 은
                // lookbehind 지원 시 `^`/`$` 가 앵커로 재작성됐으니 strip. disabling 보존.
                var kept_en = en & ~@as(u32, 0b100); // s-enabling 제거
                const i_lowered = (en & 0b001 != 0) and !self.i_fold_incomplete and
                    !self.opts.ignore_case and !self.opts.global_u;
                if (i_lowered) kept_en &= ~@as(u32, 0b001); // i-enabling 제거
                const m_lowered = (en & 0b010 != 0) and self.opts.lookbehind_ok;
                if (m_lowered) kept_en &= ~@as(u32, 0b010); // m-enabling 제거
                // 보존된 modifier 비트가 남으면 진단 신호(transpile/prepass 가 경고).
                if (kept_en != 0 or dis != 0) self.kept_modifier = true;
                return self.b.add(.{ .tag = .ignore_group, .span = n.span, .data = .{ kept_en, dis, @intFromEnum(body) } });
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
        .kept_modifier = t.kept_modifier,
        .allocator = allocator,
    };
}
