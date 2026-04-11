//! Built-in AST 플러그인 프리셋
//!
//! 플랫폼/옵션에 따라 내장 플러그인을 수집한다.
//! 새 내장 플러그인 추가 시 이 파일만 수정하면 된다.

const std = @import("std");
const Plugin = @import("../../bundler/plugin.zig").Plugin;
const worklet_plugin = @import("worklet_plugin.zig");

/// 내장 플러그인 수집 옵션.
pub const BuiltinOptions = struct {
    worklet: bool = false,
};

/// 옵션에 따라 내장 플러그인 배열을 반환한다.
/// 반환된 슬라이스는 alloc 소유 (arena 권장).
pub fn collect(
    options: BuiltinOptions,
    base_plugins: []const Plugin,
    alloc: std.mem.Allocator,
) ![]const Plugin {
    var count: usize = 0;
    if (options.worklet) count += 1;
    // 향후: if (options.nativewind) count += 1;
    // 향후: if (options.styled_components) count += 1;

    if (count == 0) return base_plugins;

    const merged = try alloc.alloc(Plugin, base_plugins.len + count);
    @memcpy(merged[0..base_plugins.len], base_plugins);

    var i = base_plugins.len;
    if (options.worklet) {
        merged[i] = worklet_plugin.plugin();
        i += 1;
    }

    return merged[0..i];
}
