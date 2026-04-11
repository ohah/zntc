//! 문자열 이스케이프 유틸리티 — JSON/JS 문자열 리터럴 공통
//!
//! 사용:
//!   const escaped = try escapeToOwned(alloc, input);
//!   defer alloc.free(escaped);
//!
//!   var buf: std.ArrayList(u8) = .empty;
//!   try appendEscaped(&buf, alloc, input);

const std = @import("std");

/// buf에 이스케이프된 문자열을 append한다 (따옴표 미포함).
/// JSON/JS 문자열 리터럴 내부에 사용.
pub fn appendEscaped(buf: *std.ArrayList(u8), alloc: std.mem.Allocator, input: []const u8) !void {
    for (input) |c| {
        switch (c) {
            '"' => try buf.appendSlice(alloc, "\\\""),
            '\\' => try buf.appendSlice(alloc, "\\\\"),
            '\n' => try buf.appendSlice(alloc, "\\n"),
            '\r' => try buf.appendSlice(alloc, "\\r"),
            '\t' => try buf.appendSlice(alloc, "\\t"),
            else => try buf.append(alloc, c),
        }
    }
}

/// 이스케이프된 문자열을 새로 할당하여 반환한다 (따옴표 미포함).
/// caller가 free해야 한다.
pub fn escapeToOwned(alloc: std.mem.Allocator, input: []const u8) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    try appendEscaped(&buf, alloc, input);
    return buf.toOwnedSlice(alloc);
}
