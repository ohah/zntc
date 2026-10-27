//! Validate selected lexical spellings without choosing or changing their name.
const std = @import("std");
const unicode = @import("../../lexer/unicode.zig");
const escapes = @import("../../string_escape.zig");
const Scanner = @import("../../lexer/scanner.zig").Scanner;

pub fn isIdentifierName(text: []const u8) bool {
    if (text.len == 0) return false;
    var offset: usize = 0;
    var first = true;
    while (offset < text.len) {
        const cp: u21 = if (text[offset] == '\\') blk: {
            const value = escapes.decodeUnicodeHexEscape(text, &offset) orelse return false;
            if (value > 0x10ffff or (value >= 0xd800 and value <= 0xdfff)) return false;
            break :blk @intCast(value);
        } else blk: {
            const len = std.unicode.utf8ByteSequenceLength(text[offset]) catch return false;
            if (len > text.len - offset) return false;
            const value = std.unicode.utf8Decode(text[offset..][0..len]) catch return false;
            offset += len;
            break :blk value;
        };
        if (first) {
            if (!unicode.isIdentifierStart(cp)) return false;
            first = false;
        } else if (!unicode.isIdentifierContinue(cp)) return false;
    }
    return true;
}

pub fn isBindingName(allocator: std.mem.Allocator, text: []const u8, comptime is_reserved: anytype) !bool {
    if (!isIdentifierName(text) or is_reserved(text)) return false;
    if (std.mem.indexOfScalar(u8, text, '\\') == null) return true;
    const value = try Scanner.decodeIdentifierEscapesAlloc(allocator, text);
    defer if (value.ptr != text.ptr) allocator.free(value);
    return !is_reserved(value);
}
