//! RegExp AST 노드 타입.
//!
//! ECMAScript 정규식 패턴의 AST를 표현한다.
//! oxc의 oxc_regular_expression/src/ast.rs를 참고하여 설계.
//!
//! 설계:
//!   - flat 노드 배열 + extra_data (메인 파서와 동일 패턴)
//!   - Node 24바이트 고정 (tag + span + data[3])
//!   - NodeIndex로 노드 참조 (포인터 대신 인덱스)
//!   - extra_data에 가변 길이 자식 리스트 저장

const std = @import("std");

/// 렉서/파서와 동일한 Span 타입을 재사용한다.
pub const Span = @import("../lexer/token.zig").Span;

/// 노드 배열의 인덱스. 포인터 대신 인덱스를 사용하여
/// use-after-free를 방지하고 메모리 효율성을 높인다.
pub const NodeIndex = enum(u32) {
    /// 유효하지 않은 참조. 에러 시 또는 optional 값 없음에 사용.
    none = std.math.maxInt(u32),
    _,
};

/// extra_data 배열에 저장된 가변 길이 자식 리스트의 위치.
/// disjunction의 alternative 목록, alternative의 term 목록 등에 사용.
pub const NodeList = struct {
    /// extra_data 배열에서의 시작 인덱스.
    start: u32,
    /// 자식 노드 개수.
    len: u32,
};

/// AST 노드 종류. oxc의 regexp AST를 참고하여 설계.
/// 각 태그별 data[3] 필드의 해석은 아래 주석 참조.
pub const Tag = enum(u8) {
    // ── 구조 ──────────────────────────────────────────

    /// Alternative들의 `|` 분기.
    /// data: [list_start, list_len, _]
    disjunction,

    /// Term들의 시퀀스 (하나의 alternative).
    /// data: [list_start, list_len, _]
    alternative,

    // ── assertions ────────────────────────────────────

    /// 간단한 경계 assertion: `^`, `$`, `\b`, `\B`.
    /// data: [BoundaryAssertionKind, _, _]
    boundary_assertion,

    /// Lookaround assertion: `(?=...)`, `(?!...)`, `(?<=...)`, `(?<!...)`.
    /// data: [LookAroundAssertionKind, body(NodeIndex→disjunction), _]
    lookaround_assertion,

    // ── atoms ─────────────────────────────────────────

    /// 단일 문자 (리터럴, 이스케이프 등).
    /// data: [codepoint(u32), CharacterKind, _]
    character,

    /// `.` (any character except line terminator, or all with s-flag).
    /// data: 사용 안 함
    dot,

    /// Character class escape: `\d`, `\D`, `\w`, `\W`, `\s`, `\S`.
    /// data: [CharacterClassEscapeKind, _, _]
    character_class_escape,

    /// Unicode property escape: `\p{...}`, `\P{...}`.
    /// data: [name_start, name_end, flags]
    ///   flags: bit 0 = negative
    unicode_property_escape,

    /// Character class: `[...]`, `[^...]`.
    /// data: [flags, list_start, list_len]
    ///   flags: bit 0 = negative, bits 1-2 = CharacterClassContentsKind
    character_class,

    // ── character class contents ──────────────────────

    /// 문자 범위: `a-z`, `0-9`.
    /// data: [min(NodeIndex→character), max(NodeIndex→character), _]
    character_class_range,

    /// `\q{abc|def}` (v-flag 전용).
    /// data: [list_start, list_len, _]
    class_string_disjunction,

    /// `\q{}` 내의 단일 문자열.
    /// data: [list_start, list_len, _]
    class_string,

    // ── groups ────────────────────────────────────────

    /// Capturing group: `(...)` 또는 `(?<name>...)`.
    /// data: [name_start(0xFFFFFFFF=unnamed), name_end, body(NodeIndex→disjunction)]
    capturing_group,

    /// Non-capturing group: `(?:...)` 또는 modifier group `(?ims-ims:...)`.
    /// data: [enabling_modifiers, disabling_modifiers, body(NodeIndex→disjunction)]
    ///   modifiers: bit 0 = i, bit 1 = m, bit 2 = s
    ignore_group,

    // ── quantifiers ──────────────────────────────────

    /// Quantifier: `*`, `+`, `?`, `{n,m}`.
    /// data: [min, max(0xFFFFFFFF=unbounded), body_and_greedy]
    ///   body_and_greedy: bits 0-30 = body(NodeIndex), bit 31 = greedy
    quantifier,

    // ── references ───────────────────────────────────

    /// 번호 역참조: `\1`, `\2` 등.
    /// data: [index, _, _]
    indexed_reference,

    /// 이름 역참조: `\k<name>`.
    /// data: [name_start, name_end, _]
    named_reference,
};

/// Boundary assertion 종류.
pub const BoundaryAssertionKind = enum(u8) {
    /// `^` (줄/입력 시작)
    start,
    /// `$` (줄/입력 끝)
    end,
    /// `\b` (단어 경계)
    boundary,
    /// `\B` (비단어 경계)
    negative_boundary,
};

/// Lookaround assertion 종류.
pub const LookAroundAssertionKind = enum(u8) {
    /// `(?=...)` (앞쪽 긍정)
    lookahead,
    /// `(?!...)` (앞쪽 부정)
    negative_lookahead,
    /// `(?<=...)` (뒤쪽 긍정)
    lookbehind,
    /// `(?<!...)` (뒤쪽 부정)
    negative_lookbehind,
};

/// 문자의 표현 방식. 소스에서 어떤 이스케이프/리터럴로 표현되었는지 구분.
pub const CharacterKind = enum(u8) {
    /// 리터럴 문자 (`a`, `b`, `1` 등)
    symbol,
    /// 단일 이스케이프 (`\f`, `\n`, `\r`, `\t`, `\v`)
    single_escape,
    /// 컨트롤 문자 (`\cX`)
    control_letter,
    /// null 문자 (`\0`)
    null_char,
    /// legacy octal (`\0nn`, non-unicode mode)
    octal,
    /// 16진수 이스케이프 (`\xHH`)
    hexadecimal_escape,
    /// 유니코드 이스케이프 (`\uHHHH`, `\u{HHHHH}`)
    unicode_escape,
    /// identity escape (`\/`, `\\` 등)
    identifier,
};

/// Character class escape 종류.
pub const CharacterClassEscapeKind = enum(u8) {
    d,
    negative_d,
    s,
    negative_s,
    w,
    negative_w,
};

/// Character class 내용물의 결합 종류.
pub const CharacterClassContentsKind = enum(u8) {
    /// 기본 합집합 (non-v-flag, `[abc]`)
    @"union",
    /// 교집합 (v-flag, `[a&&b]`)
    intersection,
    /// 차집합 (v-flag, `[a--b]`)
    subtraction,
};

/// RegExp AST 노드. 24바이트 고정 크기.
///
/// 모든 노드는 flat 배열에 저장되며, 자식 참조는 NodeIndex(인덱스)로 한다.
/// 가변 길이 자식 리스트는 extra_data 배열을 통해 간접 참조.
pub const Node = struct {
    tag: Tag,
    span: Span,
    data: [3]u32 = .{ 0, 0, 0 },

    /// disjunction, alternative 등의 자식 리스트를 가져온다.
    /// data[0]=list_start, data[1]=list_len으로 해석.
    pub fn getNodeList(self: Node) NodeList {
        return .{ .start = self.data[0], .len = self.data[1] };
    }

    /// character_class의 자식 리스트를 가져온다.
    /// data[1]=list_start, data[2]=list_len으로 해석.
    pub fn getClassBody(self: Node) NodeList {
        return .{ .start = self.data[1], .len = self.data[2] };
    }

    /// quantifier의 body NodeIndex를 가져온다.
    /// data[2]의 bits 0-30.
    pub fn getQuantifierBody(self: Node) NodeIndex {
        return @enumFromInt(self.data[2] & 0x7FFFFFFF);
    }

    /// quantifier의 greedy 여부를 가져온다.
    /// data[2]의 bit 31.
    pub fn isGreedy(self: Node) bool {
        return (self.data[2] & 0x80000000) != 0;
    }
};

/// 패턴 AST 전체. 파서가 빌드하여 반환.
///
/// 소유권(ownership)은 호출자에게 있다.
/// 사용 후 반드시 deinit()을 호출하여 메모리를 해제해야 한다.
pub const RegExpAst = struct {
    /// 모든 노드의 flat 배열. (소유권 있음)
    nodes: []const Node,
    /// 가변 길이 자식 리스트 데이터. (소유권 있음)
    extra_data: []const u32,
    /// 루트 노드 인덱스 (항상 disjunction).
    root: NodeIndex,
    /// 원본 패턴 텍스트 (zero-copy 참조, 소유권 없음).
    source: []const u8,
    /// 메모리 해제용 allocator.
    allocator: std.mem.Allocator,

    /// 메모리를 해제한다.
    pub fn deinit(self: *RegExpAst) void {
        self.allocator.free(self.nodes);
        self.allocator.free(self.extra_data);
    }

    /// 노드 인덱스로 노드를 가져온다.
    pub fn getNode(self: RegExpAst, index: NodeIndex) Node {
        return self.nodes[@intFromEnum(index)];
    }

    /// NodeList의 자식 NodeIndex 배열을 가져온다.
    pub fn getNodeList(self: RegExpAst, list: NodeList) []const u32 {
        return self.extra_data[list.start..][0..list.len];
    }

    /// 총 노드 수를 반환한다.
    pub fn nodeCount(self: RegExpAst) usize {
        return self.nodes.len;
    }
};

// ── 컴파일 타임 검증 ──────────────────────────────────

comptime {
    // Node가 24바이트인지 검증.
    // 캐시 효율과 메모리 예측 가능성을 위해 고정 크기를 보장한다.
    // tag(u8, 1) + padding(3) + span(u32*2, 8) + data(u32*3, 12) = 24
    if (@sizeOf(Node) != 24) {
        @compileError(std.fmt.comptimePrint(
            "RegExp Node must be 24 bytes, got {}",
            .{@sizeOf(Node)},
        ));
    }
}

