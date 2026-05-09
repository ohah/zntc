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
