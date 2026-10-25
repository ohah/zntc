//! ModuleExportName output syntax -> property StringValue. Never a symbol lookup.
const std = @import("std");
const unicode = @import("../string_escape.zig");

pub const Key = struct {
    text: []const u8,
    owned: bool = false,

    pub fn deinit(self: Key, allocator: std.mem.Allocator) void {
        if (self.owned) allocator.free(self.text);
    }
};

pub const Error = std.mem.Allocator.Error || error{InvalidPublicExportName};

fn appendCodepoint(out: *std.ArrayList(u8), allocator: std.mem.Allocator, cp: u32) Error!void {
    if (cp > 0x10ffff or (cp >= 0xd800 and cp <= 0xdfff)) return error.InvalidPublicExportName;
    var bytes: [4]u8 = undefined;
    const len = std.unicode.utf8Encode(@intCast(cp), &bytes) catch return error.InvalidPublicExportName;
    try out.appendSlice(allocator, bytes[0..len]);
}

/// Identifiers already carry StringValue and are borrowed. A quoted alias is
/// decoded once from its original syntax. In particular, `"\\u0069"` denotes
/// literal backslash-u text, whereas `"\u0069"` denotes `i`.
pub fn fromSyntax(allocator: std.mem.Allocator, syntax: []const u8) Error!Key {
    if (syntax.len == 0 or (syntax[0] != '"' and syntax[0] != '\'')) return .{ .text = syntax };
    if (syntax.len < 2 or syntax[syntax.len - 1] != syntax[0]) return error.InvalidPublicExportName;
    const body = syntax[1 .. syntax.len - 1];
    if (std.mem.indexOfScalar(u8, body, '\\') == null) return .{ .text = body };
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < body.len) {
        if (body[i] != '\\') {
            try out.append(allocator, body[i]);
            i += 1;
            continue;
        }
        if (i + 1 >= body.len) return error.InvalidPublicExportName;
        const escaped = body[i + 1];
        switch (escaped) {
            'b', 'f', 'n', 'r', 't', 'v' => {
                try out.append(allocator, switch (escaped) {
                    'b' => 8,
                    'f' => 12,
                    'n' => 10,
                    'r' => 13,
                    't' => 9,
                    'v' => 11,
                    else => unreachable,
                });
                i += 2;
            },
            '0' => {
                if (i + 2 < body.len and std.ascii.isDigit(body[i + 2])) return error.InvalidPublicExportName;
                try out.append(allocator, 0);
                i += 2;
            },
            '1'...'9' => return error.InvalidPublicExportName,
            '\n' => i += 2,
            '\r' => {
                i += 2;
                if (i < body.len and body[i] == '\n') i += 1;
            },
            'x' => {
                if (i + 4 > body.len) return error.InvalidPublicExportName;
                const hi = std.fmt.charToDigit(body[i + 2], 16) catch return error.InvalidPublicExportName;
                const lo = std.fmt.charToDigit(body[i + 3], 16) catch return error.InvalidPublicExportName;
                try appendCodepoint(&out, allocator, @as(u32, hi) * 16 + lo);
                i += 4;
            },
            'u' => {
                var cp = unicode.decodeUnicodeHexEscape(body, &i) orelse return error.InvalidPublicExportName;
                if (cp >= 0xd800 and cp <= 0xdbff) {
                    const low = unicode.decodeUnicodeHexEscape(body, &i) orelse return error.InvalidPublicExportName;
                    if (low < 0xdc00 or low > 0xdfff) return error.InvalidPublicExportName;
                    cp = 0x10000 + (cp - 0xd800) * 0x400 + low - 0xdc00;
                }
                try appendCodepoint(&out, allocator, cp);
            },
            else => {
                if (std.mem.startsWith(u8, body[i + 1 ..], "\xe2\x80\xa8") or std.mem.startsWith(u8, body[i + 1 ..], "\xe2\x80\xa9")) {
                    i += 4;
                    continue;
                }
                try out.append(allocator, escaped);
                i += 2;
            },
        }
    }
    return .{ .text = try out.toOwnedSlice(allocator), .owned = true };
}
