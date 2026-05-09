//! package.json sideEffects helpers for ModuleGraph.

const std = @import("std");
const Module = @import("../module.zig").Module;
const pkg_json = @import("../package_json.zig");
const matchGlob = @import("../resolve_cache.zig").matchGlob;

/// package.json sideEffects 값을 모듈에 적용.
/// `.all`/`.patterns` 케이스는 tree-shaker가 auto-purity로 덮어쓰지 못하도록 user_defined lock 설정.
/// `.unknown` (필드 없음)은 기본 동작(conservative: side_effects=true 유지) 그대로.
pub fn applyCached(module: *Module, pkg_dir_path: []const u8, se: pkg_json.PackageJson.SideEffects) void {
    switch (se) {
        .all => |val| {
            module.side_effects = val;
            module.side_effects_user_defined = true;
        },
        .patterns => |patterns| {
            module.side_effects = matchPatterns(module.path, pkg_dir_path, patterns);
            module.side_effects_user_defined = true;
        },
        .unknown => {},
    }
}

/// sideEffects 글롭 패턴 매칭.
/// 모듈의 패키지 내 상대 경로를 각 패턴과 비교하여,
/// 하나라도 매칭되면 side_effects=true (해당 파일은 제거하면 안 됨).
/// 아무 패턴도 매칭되지 않으면 side_effects=false (순수 모듈, 제거 가능).
pub fn matchPatterns(module_path: []const u8, pkg_dir_path: []const u8, patterns: []const []const u8) bool {
    // 패키지 디렉토리 기준 상대 경로 추출: /abs/node_modules/pkg/src/foo.js -> src/foo.js
    const relative = if (module_path.len > pkg_dir_path.len + 1)
        module_path[pkg_dir_path.len + 1 ..] // +1 for separator
    else
        module_path;

    // Windows 경로 정규화: \ -> / (패턴은 항상 / 사용)
    var rel_buf: [4096]u8 = undefined;
    const rel_normalized = normalizeSep(relative, &rel_buf);
    const base = std.fs.path.basename(rel_normalized);

    for (patterns) |pattern| {
        // "./" 접두사 제거: "./src/polyfill.js" -> "src/polyfill.js"
        const normalized = if (std.mem.startsWith(u8, pattern, "./"))
            pattern[2..]
        else
            pattern;

        if (matchGlob(normalized, rel_normalized)) return true;
        // basename 폴백: "*.css"는 "src/style.css"도 매칭해야 함
        if (base.len != rel_normalized.len) {
            if (matchGlob(normalized, base)) return true;
        }
    }
    return false;
}

/// 경로의 \ 구분자를 /로 정규화 (Windows 호환).
fn normalizeSep(path: []const u8, buf: *[4096]u8) []const u8 {
    if (comptime @import("builtin").os.tag == .windows) {
        const len = @min(path.len, buf.len);
        for (path[0..len], 0..) |c, i| {
            buf[i] = if (c == '\\') '/' else c;
        }
        return buf[0..len];
    }
    return path;
}
