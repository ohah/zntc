//! RegExp AST → 패턴 텍스트 직렬화기.
//!
//! `parser.zig` 가 빌드한 `ast.RegExpAst` 를 다시 패턴 문자열로 복원한다.
//! 노드 `data` 만으로 재구성하므로 변환 후 생성된 합성 노드도 그대로 출력된다
//! (source span 에 의존하지 않음 — 변환 시 span 은 stale).
//!
//! 출력은 oxc(`oxc_regular_expression` display.rs) canonical form 에 맞춘다:
//! hex 는 대문자, unicode_escape 는 4자리 `\uXXXX`/`\u{XXXXX}` 로 통일
//! (`\xab`→`\xAB`, `\u{41}`→`A`, `\u{1f600}`→`\u{1F600}`), `\ca`→`\cA`,
//! `a{3,3}`→`a{3}`. 따라서 라운드트립 불변식은 "바이트 동일" 이
//! 아니라 "print 멱등 + 구조 보존" 이다 (printer_test.zig 참조).
//!
//! 알려진 비-라운드트립 (AST layout 한계, printer 책임 아님):
//!   - `\p{Script=Greek}` 의 `=value` 는 parser 가 name 범위만 보존하므로
//!     `\p{Script}` 로 축약된다 (#1475 후속 PR 에서 AST 확장 시 해소).
//!   - octal escape 는 parser 가 단일 `octal` kind 만 보존(자릿수 미보존)하므로
//!     최소 자릿수로 출력 (`\07`→`\7`). 값은 동일.

const std = @import("std");
const ast = @import("ast.zig");

pub const PrintError = error{ OutOfMemory, InvalidUtf8 };

/// AST 전체를 패턴 텍스트로 직렬화한다. 반환 슬라이스 소유권은 호출자.
pub fn print(tree: ast.RegExpAst, allocator: std.mem.Allocator) PrintError![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    var p = Printer{ .tree = tree, .buf = &buf, .allocator = allocator };
    try p.node(tree.root);
    return buf.toOwnedSlice(allocator);
}

const UNBOUNDED = std.math.maxInt(u32);
const UNNAMED = std.math.maxInt(u32);

const Printer = struct {
    tree: ast.RegExpAst,
    buf: *std.ArrayList(u8),
    allocator: std.mem.Allocator,

    fn w(self: *Printer, s: []const u8) PrintError!void {
        try self.buf.appendSlice(self.allocator, s);
    }

    fn wb(self: *Printer, b: u8) PrintError!void {
        try self.buf.append(self.allocator, b);
    }

    /// codepoint 를 UTF-8 로 인코딩해 append.
    fn wCp(self: *Printer, cp: u32) PrintError!void {
        if (cp > 0x10FFFF or (cp >= 0xD800 and cp <= 0xDFFF)) return PrintError.InvalidUtf8;
        var tmp: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(@intCast(cp), &tmp) catch return PrintError.InvalidUtf8;
        try self.w(tmp[0..n]);
    }

    /// comptime 포맷 스펙으로 정수를 직렬화 (codegen/writer.zig 의 hex emit 관례와 동일).
    /// u32 최대 10자리(10진)/8자리(16진)/11자리(8진) → [12]u8 로 충분.
    fn fmtInt(self: *Printer, comptime spec: []const u8, v: u32) PrintError!void {
        var tmp: [12]u8 = undefined;
        const s = std.fmt.bufPrint(&tmp, spec, .{v}) catch unreachable;
        try self.w(s);
    }

    /// modifier 비트 (i=1, m=2, s=4) → 문자.
    fn modifiers(self: *Printer, bits: u32) PrintError!void {
        if (bits & 1 != 0) try self.wb('i');
        if (bits & 2 != 0) try self.wb('m');
        if (bits & 4 != 0) try self.wb('s');
    }

    fn childList(self: *Printer, list: ast.NodeList, sep: []const u8) PrintError!void {
        const ids = self.tree.getNodeList(list);
        for (ids, 0..) |child, i| {
            if (i != 0 and sep.len != 0) try self.w(sep);
            try self.node(@enumFromInt(child));
        }
    }

    fn node(self: *Printer, idx: ast.NodeIndex) PrintError!void {
        if (idx == .none) return;
        const n = self.tree.getNode(idx);
        switch (n.tag) {
            .disjunction => try self.childList(n.getNodeList(), "|"),
            .alternative => try self.childList(n.getNodeList(), ""),

            .boundary_assertion => switch (@as(ast.BoundaryAssertionKind, @enumFromInt(n.data[0]))) {
                .start => try self.wb('^'),
                .end => try self.wb('$'),
                .boundary => try self.w("\\b"),
                .negative_boundary => try self.w("\\B"),
            },

            .lookaround_assertion => {
                try self.w(switch (@as(ast.LookAroundAssertionKind, @enumFromInt(n.data[0]))) {
                    .lookahead => "(?=",
                    .negative_lookahead => "(?!",
                    .lookbehind => "(?<=",
                    .negative_lookbehind => "(?<!",
                });
                try self.node(@enumFromInt(n.data[1]));
                try self.wb(')');
            },

            .character => try self.character(n),
            .dot => try self.wb('.'),

            .character_class_escape => {
                try self.wb('\\');
                try self.wb(switch (@as(ast.CharacterClassEscapeKind, @enumFromInt(n.data[0]))) {
                    .d => 'd',
                    .negative_d => 'D',
                    .s => 's',
                    .negative_s => 'S',
                    .w => 'w',
                    .negative_w => 'W',
                });
            },

            .unicode_property_escape => {
                try self.w(if (n.data[2] != 0) "\\P{" else "\\p{");
                try self.w(self.tree.source[n.data[0]..n.data[1]]);
                try self.wb('}');
            },

            .character_class => {
                const negative = (n.data[0] & 1) != 0;
                const kind: ast.CharacterClassContentsKind = @enumFromInt((n.data[0] >> 1) & 0x3);
                try self.wb('[');
                if (negative) try self.wb('^');
                try self.childList(n.getClassBody(), switch (kind) {
                    .@"union" => "",
                    .intersection => "&&",
                    .subtraction => "--",
                });
                try self.wb(']');
            },

            .character_class_range => {
                try self.node(@enumFromInt(n.data[0]));
                try self.wb('-');
                try self.node(@enumFromInt(n.data[1]));
            },

            .class_string_disjunction => {
                try self.w("\\q{");
                try self.childList(n.getNodeList(), "|");
                try self.wb('}');
            },
            .class_string => try self.childList(n.getNodeList(), ""),

            .capturing_group => {
                if (n.data[0] == UNNAMED) {
                    try self.wb('(');
                } else {
                    try self.w("(?<");
                    try self.w(self.tree.source[n.data[0]..n.data[1]]);
                    try self.wb('>');
                }
                try self.node(@enumFromInt(n.data[2]));
                try self.wb(')');
            },

            .ignore_group => {
                const enabling = n.data[0];
                const disabling = n.data[1];
                if (enabling == 0 and disabling == 0) {
                    try self.w("(?:");
                } else {
                    try self.w("(?");
                    try self.modifiers(enabling);
                    if (disabling != 0) {
                        try self.wb('-');
                        try self.modifiers(disabling);
                    }
                    try self.wb(':');
                }
                try self.node(@enumFromInt(n.data[2]));
                try self.wb(')');
            },

            .quantifier => {
                try self.node(n.getQuantifierBody());
                const min = n.data[0];
                const max = n.data[1];
                if (min == 0 and max == UNBOUNDED) {
                    try self.wb('*');
                } else if (min == 1 and max == UNBOUNDED) {
                    try self.wb('+');
                } else if (min == 0 and max == 1) {
                    try self.wb('?');
                } else {
                    try self.wb('{');
                    try self.fmtInt("{d}", min);
                    if (max == UNBOUNDED) {
                        try self.wb(',');
                    } else if (max != min) {
                        try self.wb(',');
                        try self.fmtInt("{d}", max);
                    }
                    try self.wb('}');
                }
                if (!n.isGreedy()) try self.wb('?');
            },

            .indexed_reference => {
                try self.wb('\\');
                try self.fmtInt("{d}", n.data[0]);
            },
            .named_reference => {
                try self.w("\\k<");
                try self.w(self.tree.source[n.data[0]..n.data[1]]);
                try self.wb('>');
            },
        }
    }

    fn character(self: *Printer, n: ast.Node) PrintError!void {
        const cp = n.data[0];
        switch (@as(ast.CharacterKind, @enumFromInt(n.data[1]))) {
            .symbol => try self.wCp(cp),
            .single_escape => {
                try self.wb('\\');
                try self.wb(switch (cp) {
                    0x08 => @as(u8, 'b'), // class 내 `[\b]` = backspace
                    0x0C => 'f',
                    0x0A => 'n',
                    0x0D => 'r',
                    0x09 => 't',
                    0x0B => 'v',
                    // 알려진 single escape 가 아니면 identity 로 폴백.
                    else => {
                        try self.wCp(cp);
                        return;
                    },
                });
            },
            .control_letter => {
                try self.w("\\c");
                // parser 가 ctrl & 0x1F 로 저장 → letter 복원: | 0x40 ('A'..'Z').
                try self.wb(@intCast((cp & 0x1F) | 0x40));
            },
            .null_char => try self.w("\\0"),
            .octal => {
                try self.wb('\\');
                try self.fmtInt("{o}", cp);
            },
            // hex 는 대문자 (oxc display.rs `\x{cp:02X}` / `\u{cp:04X}` 관례.
            // ZNTC 기존 ad-hoc regex_lower 출력도 대문자라 바이트 동일 — #1475 R2 제거).
            .hexadecimal_escape => {
                try self.w("\\x");
                try self.fmtInt("{X:0>2}", cp);
            },
            .unicode_escape => {
                // oxc: hex=`{cp:04X}`; len≤4 → `\uXXXX`, else `\u{XXXXX}`.
                if (cp <= 0xFFFF) {
                    try self.w("\\u");
                    try self.fmtInt("{X:0>4}", cp);
                } else {
                    try self.w("\\u{");
                    try self.fmtInt("{X:0>4}", cp);
                    try self.wb('}');
                }
            },
            .identifier => {
                try self.wb('\\');
                try self.wCp(cp);
            },
        }
    }
};
