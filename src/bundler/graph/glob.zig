//! import.meta.glob expansion helpers for ModuleGraph.

const std = @import("std");
const fs = @import("../fs.zig");
const types = @import("../types.zig");
const Span = @import("../../lexer/token.zig").Span;

/// import.meta.glob 패턴을 파일 시스템에서 확장한다.
/// 패턴: "./dir/*.ext" — prefix(./dir/) + *와 suffix(.ext)로 분리하여 디렉토리 탐색.
/// 상대 경로 배열을 반환한다 (예: ["./pages/Home.tsx", "./pages/About.tsx"]).
fn expandGlob(allocator: std.mem.Allocator, io: std.Io, source_dir: []const u8, pattern: []const u8) ![]const []const u8 {
    const star_pos = std.mem.indexOf(u8, pattern, "*") orelse return &.{};
    const prefix = pattern[0..star_pos];
    const suffix = pattern[star_pos + 1 ..];

    const glob_dir_rel = if (prefix.len > 0 and prefix[prefix.len - 1] == '/')
        prefix[0 .. prefix.len - 1]
    else if (std.fs.path.dirname(prefix)) |d| d else ".";

    const glob_dir_abs = try std.fs.path.resolve(allocator, &.{ source_dir, glob_dir_rel });
    defer allocator.free(glob_dir_abs);

    const entries = fs.listDir(io, allocator, glob_dir_abs) catch return &.{};
    defer {
        for (entries) |e| allocator.free(e.name);
        allocator.free(entries);
    }

    var results: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (results.items) |r| allocator.free(r);
        results.deinit(allocator);
    }

    const file_prefix = if (prefix.len > 0 and prefix[prefix.len - 1] == '/')
        ""
    else
        std.fs.path.basename(prefix);

    for (entries) |entry| {
        if (entry.kind != .file and entry.kind != .symlink) continue;
        const name = entry.name;
        if (file_prefix.len > 0 and !std.mem.startsWith(u8, name, file_prefix)) continue;
        if (suffix.len > 0 and !std.mem.endsWith(u8, name, suffix)) continue;

        const rel_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ glob_dir_rel, name });
        try results.append(allocator, rel_path);
    }

    std.mem.sortUnstable([]const u8, results.items, {}, struct {
        fn cmp(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.cmp);

    return try results.toOwnedSlice(allocator);
}

/// import_records 배열에서 glob 레코드를 찾아 expandGlob으로 파일 매칭을 수행한다.
/// scanWorker와 resolveModuleImports 양쪽에서 호출되는 공통 헬퍼.
pub fn expandGlobRecords(allocator: std.mem.Allocator, io: std.Io, records: []types.ImportRecord, source_dir: []const u8) void {
    for (records) |*record| {
        if (record.kind == .glob) {
            record.glob_matches = expandGlob(allocator, io, source_dir, record.specifier) catch &.{};
        }
    }
}

const test_helpers = @import("../test_helpers.zig");
const writeFile = test_helpers.writeFile;
const absPath = test_helpers.absPath;

fn freeGlobMatches(allocator: std.mem.Allocator, matches: []const []const u8) void {
    for (matches) |match| allocator.free(match);
    allocator.free(matches);
}

test "expandGlob: 파일명 prefix와 suffix를 적용하고 결과를 정렬한다" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "src/pages/PageB.tsx", "");
    try writeFile(tmp.dir, "src/pages/PageA.tsx", "");
    try writeFile(tmp.dir, "src/pages/Other.tsx", "");
    try writeFile(tmp.dir, "src/pages/PageC.css", "");

    const source_dir = try absPath(&tmp, "src");
    defer std.testing.allocator.free(source_dir);

    const matches = try expandGlob(std.testing.allocator, source_dir, "./pages/Page*.tsx");
    defer freeGlobMatches(std.testing.allocator, matches);

    try std.testing.expectEqual(@as(usize, 2), matches.len);
    try std.testing.expectEqualStrings("./pages/PageA.tsx", matches[0]);
    try std.testing.expectEqualStrings("./pages/PageB.tsx", matches[1]);
}

test "expandGlobRecords: glob 레코드에만 매칭 결과를 채운다" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "app/mods/a.ts", "");
    try writeFile(tmp.dir, "app/mods/b.ts", "");

    const source_dir = try absPath(&tmp, "app");
    defer std.testing.allocator.free(source_dir);

    var records = [_]types.ImportRecord{
        .{ .specifier = "./mods/*.ts", .kind = .glob, .span = Span.EMPTY },
        .{ .specifier = "./side-effect", .kind = .side_effect, .span = Span.EMPTY },
    };

    expandGlobRecords(std.testing.allocator, &records, source_dir);
    defer if (records[0].glob_matches) |matches| freeGlobMatches(std.testing.allocator, matches);

    try std.testing.expect(records[0].glob_matches != null);
    const matches = records[0].glob_matches.?;
    try std.testing.expectEqual(@as(usize, 2), matches.len);
    try std.testing.expectEqualStrings("./mods/a.ts", matches[0]);
    try std.testing.expectEqualStrings("./mods/b.ts", matches[1]);
    try std.testing.expect(records[1].glob_matches == null);
}
