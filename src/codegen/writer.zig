//! Shared output helpers for codegen emitters.

const std = @import("std");
const ast_mod = @import("../parser/ast.zig");
const Span = @import("../lexer/token.zig").Span;
const Ast = ast_mod.Ast;
const ConstValue = @import("../semantic/symbol.zig").ConstValue;

pub fn write(self: anytype, s: []const u8) !void {
    try self.buf.appendSlice(self.allocator, s);
    for (s) |c| {
        if (c == '\n') {
            self.gen_line += 1;
            self.gen_col = 0;
        } else {
            self.gen_col += 1;
        }
    }
}

pub fn writeByte(self: anytype, b: u8) !void {
    try self.buf.append(self.allocator, b);
    if (b == '\n') {
        self.gen_line += 1;
        self.gen_col = 0;
    } else {
        self.gen_col += 1;
    }
}

pub fn trimTrailingSemicolonBeforeMinifyBoundary(self: anytype) void {
    if (!self.options.minify_whitespace) return;
    if (!self.options.minify_syntax) return;
    if (self.buf.items.len == 0) return;
    if (self.buf.items[self.buf.items.len - 1] != ';') return;
    _ = self.buf.pop();
    if (self.gen_col > 0) self.gen_col -= 1;
}

pub fn writeNewline(self: anytype) !void {
    if (self.options.minify_whitespace) return;
    try self.write(self.options.newline);
}

pub fn writeIndent(self: anytype) !void {
    if (self.options.minify_whitespace) return;
    var i: u32 = 0;
    while (i < self.indent_level) : (i += 1) {
        switch (self.options.indent_char) {
            .tab => try self.writeByte('\t'),
            .space => {
                var j: u8 = 0;
                while (j < self.options.indent_width) : (j += 1) {
                    try self.writeByte(' ');
                }
            },
        }
    }
}

pub fn writeSpace(self: anytype) !void {
    if (!self.options.minify_whitespace) try self.writeByte(' ');
}

pub fn writeConstValue(self: anytype, cv: ConstValue) !void {
    switch (cv.kind) {
        .true_ => try self.write("true"),
        .false_ => try self.write("false"),
        .null_ => try self.write("null"),
        .undefined_ => try self.write("void 0"),
        .number => try self.write(cv.number_text),
        .none => {},
    }
}

pub fn writeSpan(self: anytype, span: Span) !void {
    const text = self.ast.getText(span);
    if (self.options.ascii_only) {
        try self.writeAsciiOnly(text);
    } else {
        try self.write(text);
    }
}

pub fn writeAsciiOnly(self: anytype, text: []const u8) !void {
    var i: usize = 0;
    while (i < text.len) {
        const b = text[i];
        if (b < 0x80) {
            try self.writeByte(b);
            i += 1;
        } else {
            const cp_len = std.unicode.utf8ByteSequenceLength(b) catch 1;
            if (i + cp_len <= text.len) {
                const cp = std.unicode.utf8Decode(text[i..][0..cp_len]) catch {
                    try self.writeByte(b);
                    i += 1;
                    continue;
                };
                if (cp <= 0xFFFF) {
                    var hex_buf: [6]u8 = undefined;
                    _ = std.fmt.bufPrint(&hex_buf, "\\u{x:0>4}", .{cp}) catch unreachable;
                    try self.buf.appendSlice(self.allocator, &hex_buf);
                } else {
                    const adjusted = cp - 0x10000;
                    const high: u16 = @intCast((adjusted >> 10) + 0xD800);
                    const low: u16 = @intCast((adjusted & 0x3FF) + 0xDC00);
                    var hex_buf: [12]u8 = undefined;
                    _ = std.fmt.bufPrint(&hex_buf, "\\u{x:0>4}\\u{x:0>4}", .{ high, low }) catch unreachable;
                    try self.buf.appendSlice(self.allocator, &hex_buf);
                }
                if (cp <= 0xFFFF) {
                    self.gen_col += 6;
                } else {
                    self.gen_col += 12;
                }
                i += cp_len;
            } else {
                try self.writeByte(b);
                i += 1;
            }
        }
    }
}

pub fn writeNodeSpan(self: anytype, node: ast_mod.Node) !void {
    try self.writeSpan(node.span);
}

/// identifier/property/key 이름 emit 전용 (#4243). lower_unicode_brace 시
/// `\u{...}` brace escape(ES2015)를 es5 호환 `\uXXXX`(surrogate pair 포함)로
/// 다운레벨. 그 외엔 writeSpan 과 동일(ascii_only 등 동작 보존). identifier
/// 위치는 모두 이 함수로 funnel → 소스/합성/디스트럭처링/클래스필드 일괄 처리.
pub fn writeIdentifierSpan(self: anytype, span: Span) !void {
    if (self.options.lower_unicode_brace) {
        const unicode_escape_lower = @import("../transformer/unicode_escape_lower.zig");
        const text = self.ast.getText(span);
        if (unicode_escape_lower.containsBraceEscape(text)) {
            // `\u{...}` brace escape(ES2015) → raw UTF-8 codepoint. identifier 는
            // string 과 달리 surrogate-pair escape(`𠀀`)가 es5 에서도
            // invalid 이므로 raw 디코드가 정답(BMP/astral 모두 valid ES5 IdName).
            // 비-brace 바이트는 그대로 — `\uHHHH` 4-digit 는 es5 valid 라 보존.
            var out: std.ArrayList(u8) = .empty;
            defer out.deinit(self.allocator);
            var i: usize = 0;
            while (i < text.len) {
                // escaped backslash(`\\`)는 원자 복사 — 둘째 `\` 가 escape 시작으로
                // 오인돼 `\\u{..}` 가 잘못 디코드되는 것 방지(containsBraceEscape 와
                // 일관). identifier span 엔 현재 도달 불가하나 방어적.
                if (text[i] == '\\' and i + 1 < text.len and text[i + 1] == '\\') {
                    try out.appendSlice(self.allocator, text[i .. i + 2]);
                    i += 2;
                    continue;
                }
                if (text[i] == '\\' and i + 2 < text.len and text[i + 1] == 'u' and text[i + 2] == '{') {
                    if (unicode_escape_lower.parseBraceHex(text, i + 2)) |r| {
                        var buf: [4]u8 = undefined;
                        if (std.unicode.utf8Encode(@intCast(r.cp), &buf)) |n| {
                            try out.appendSlice(self.allocator, buf[0..n]);
                            i = r.end;
                            continue;
                        } else |_| {}
                    }
                }
                try out.append(self.allocator, text[i]);
                i += 1;
            }
            // 한계(극단 edge): ascii_only + astral(>U+FFFF) identifier 는
            // writeAsciiOnly 가 surrogate-pair escape(`𠀀`)로 재escape →
            // identifier 로는 어떤 엔진도 invalid. 단 es5 에서 astral identifier 의
            // 유효한 ASCII 표현 자체가 없으므로(brace=ES2015, surrogate escape 불가)
            // 표현 불가 케이스. BMP+ascii_only 는 정상(`é`).
            if (self.options.ascii_only) {
                try self.writeAsciiOnly(out.items);
            } else {
                try self.write(out.items);
            }
            return;
        }
    }
    try self.writeSpan(span);
}

pub fn writeStringLiteral(self: anytype, span: Span) !void {
    const text = self.ast.getText(span);
    if (text.len < 2) {
        try self.write(text);
        return;
    }

    const src_quote = text[0];
    const target_quote: u8 = switch (self.options.quote_style) {
        .double => '"',
        .single => '\'',
        .preserve => src_quote,
    };

    if (src_quote == target_quote) {
        try self.writeSpan(span);
        return;
    }

    try self.writeByte(target_quote);
    const content = text[1 .. text.len - 1];
    var flush_start: usize = 0;
    var i: usize = 0;
    while (i < content.len) {
        const c = content[i];
        if (c == '\\' and i + 1 < content.len) {
            if (content[i + 1] == src_quote) {
                try self.write(content[flush_start..i]);
                try self.writeByte(src_quote);
                i += 2;
                flush_start = i;
            } else if (content[i + 1] == target_quote) {
                i += 2;
            } else {
                i += 2;
            }
        } else if (c == target_quote) {
            try self.write(content[flush_start..i]);
            try self.writeByte('\\');
            try self.writeByte(c);
            i += 1;
            flush_start = i;
        } else if (c >= 0x80 and self.options.ascii_only) {
            try self.write(content[flush_start..i]);
            const cp_len = std.unicode.utf8ByteSequenceLength(c) catch 1;
            const end = @min(i + cp_len, content.len);
            try self.writeAsciiOnly(content[i..end]);
            i = end;
            flush_start = i;
        } else {
            i += 1;
        }
    }
    try self.write(content[flush_start..content.len]);
    try self.writeByte(target_quote);
}
