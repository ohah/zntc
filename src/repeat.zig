//! Small compile-time helpers for fixed byte sequences.

/// Repeat a compile-time byte sequence without allocating.
pub fn bytes(comptime pattern: []const u8, comptime count: usize) [pattern.len * count]u8 {
    var result: [pattern.len * count]u8 = undefined;
    if (result.len != 0) {
        @memcpy(result[0..pattern.len], pattern);
        var written = pattern.len;
        while (written < result.len) {
            const copy_len = @min(written, result.len - written);
            @memcpy(result[written..][0..copy_len], result[0..copy_len]);
            written += copy_len;
        }
    }
    return result;
}
