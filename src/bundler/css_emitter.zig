//! CSS 번들 Emitter
//!
//! 엔트리 JS 모듈에서 도달 가능한 CSS 모듈을 수집하고,
//! @import 규칙을 strip한 뒤 exec_index 순으로 연결하여
//! 단일 CSS 파일을 생성한다.

const std = @import("std");
const Module = @import("module.zig").Module;
const ModuleIndex = @import("types.zig").ModuleIndex;
const ModuleGraph = @import("graph.zig").ModuleGraph;
const emitter = @import("emitter.zig");
const OutputFile = emitter.OutputFile;

/// 엔트리 모듈에서 도달 가능한 CSS 모듈을 수집하여 연결된 CSS 번들을 생성한다.
/// CSS 모듈이 없으면 null을 반환한다.
pub fn emitCssBundle(
    allocator: std.mem.Allocator,
    graph: *const ModuleGraph,
    entry_idx: ModuleIndex,
    css_names: []const u8,
) ?OutputFile {
    // DFS로 엔트리에서 도달 가능한 CSS 모듈 수집
    var css_modules: std.ArrayListUnmanaged(*const Module) = .empty;
    defer css_modules.deinit(allocator);

    var visited = std.AutoHashMap(ModuleIndex, void).init(allocator);
    defer visited.deinit();

    collectCssModules(allocator, graph, entry_idx, &css_modules, &visited);

    if (css_modules.items.len == 0) return null;

    // exec_index 순으로 정렬 (CSS 출력 순서 = JS 실행 순서)
    std.mem.sort(*const Module, css_modules.items, {}, struct {
        fn lessThan(_: void, a: *const Module, b: *const Module) bool {
            return a.exec_index < b.exec_index;
        }
    }.lessThan);

    // CSS 소스 연결 (@import strip)
    var output: std.ArrayListUnmanaged(u8) = .empty;
    defer output.deinit(allocator);

    for (css_modules.items) |mod| {
        const strip_end: u32 = if (mod.css_data) |cd| cd.strip_end else 0;
        const stripped = if (strip_end > 0 and strip_end < mod.source.len) mod.source[strip_end..] else mod.source;
        // 공백만 있는 경우 건너뜀
        const trimmed = std.mem.trim(u8, stripped, " \t\n\r");
        if (trimmed.len == 0) continue;

        output.appendSlice(allocator, stripped) catch continue;
        // 모듈 간 줄바꿈 구분
        if (stripped.len > 0 and stripped[stripped.len - 1] != '\n') {
            output.append(allocator, '\n') catch {};
        }
    }

    if (output.items.len == 0) return null;

    // 출력 파일명 결정
    const entry_mod = graph.getModule(entry_idx) orelse return null;
    const entry_path = entry_mod.path;
    const css_path = applyCssNamingPattern(allocator, css_names, entry_path) catch return null;

    return .{
        .path = css_path,
        .contents = output.toOwnedSlice(allocator) catch return null,
    };
}

/// DFS로 모듈 그래프를 탐색하여 CSS 모듈을 수집한다.
fn collectCssModules(
    allocator: std.mem.Allocator,
    graph: *const ModuleGraph,
    idx: ModuleIndex,
    result: *std.ArrayListUnmanaged(*const Module),
    visited: *std.AutoHashMap(ModuleIndex, void),
) void {
    if (idx == .none) return;
    if (visited.contains(idx)) return;
    const mod = graph.getModule(idx) orelse return;
    visited.put(idx, {}) catch return;

    // 의존성 먼저 방문 (DFS)
    for (mod.dependencies.items) |dep_idx| {
        collectCssModules(allocator, graph, dep_idx, result, visited);
    }

    // CSS 모듈이면 결과에 추가
    if (mod.module_type == .css and mod.css_data != null) {
        result.append(allocator, mod) catch {};
    }
}

/// CSS 출력 파일명 패턴 적용.
/// [name] → 엔트리 파일의 basename (확장자 제거) + .css
fn applyCssNamingPattern(allocator: std.mem.Allocator, pattern: []const u8, entry_path: []const u8) ![]const u8 {
    // 엔트리 파일의 basename 추출 (확장자 제거)
    const basename = std.fs.path.basename(entry_path);
    const name = if (std.mem.lastIndexOf(u8, basename, ".")) |dot|
        basename[0..dot]
    else
        basename;

    // [name] 패턴 치환
    if (std.mem.indexOf(u8, pattern, "[name]")) |idx| {
        const before = pattern[0..idx];
        const after = pattern[idx + 6 ..]; // "[name]".len = 6
        return std.fmt.allocPrint(allocator, "{s}{s}{s}.css", .{ before, name, after });
    }

    // 패턴에 [name] 없으면 그대로 + .css
    return std.fmt.allocPrint(allocator, "{s}.css", .{pattern});
}

// ============================================================
// 테스트
// ============================================================

test "applyCssNamingPattern: default pattern" {
    const result = try applyCssNamingPattern(std.testing.allocator, "[name]", "/app/src/index.ts");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("index.css", result);
}

test "applyCssNamingPattern: custom pattern" {
    const result = try applyCssNamingPattern(std.testing.allocator, "styles/[name]", "/app/src/main.tsx");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("styles/main.css", result);
}
