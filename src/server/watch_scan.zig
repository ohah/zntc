//! watchFolders 루트를 재귀 스캔하는 공통 walker.
//!
//! CLI watch(mtime 폴링)와 NAPI watch(TrackedFileSet) 두 구현이 같은 필터링 규칙을
//! 쓰기 위해 여기로 추출. 저장소 타입이 달라 실제 "어디에 저장할지"는 visitor 콜백에
//! 위임한다.

const std = @import("std");
const matchGlob = @import("../bundler/resolve_cache.zig").matchGlob;

pub const Filter = struct {
    /// 지정되면 최소 하나와 매칭되어야 통과. 비어있으면 모두 통과.
    include: []const []const u8 = &.{},
    /// 하나라도 매칭되면 제외.
    exclude: []const []const u8 = &.{},
};

/// 경로 세그먼트가 node_modules/.git인 경우 true. 부분문자열 아닌 '/' 경계 매칭.
pub fn hasSkippedSegment(rel: []const u8) bool {
    var it = std.mem.splitScalar(u8, rel, '/');
    while (it.next()) |seg| {
        if (std.mem.eql(u8, seg, "node_modules")) return true;
        if (std.mem.eql(u8, seg, ".git")) return true;
    }
    return false;
}

pub fn passesFilter(rel: []const u8, filter: Filter) bool {
    if (filter.include.len > 0) {
        var any = false;
        for (filter.include) |pat| if (matchGlob(pat, rel)) {
            any = true;
            break;
        };
        if (!any) return false;
    }
    for (filter.exclude) |pat| if (matchGlob(pat, rel)) return false;
    return true;
}

/// `root` 아래 파일을 재귀 스캔, 필터 통과한 것마다 `visit(ctx, full_path)` 호출.
/// visitor는 `true` 반환 시 `full_path` 메모리 소유권을 가져간다 (walker는 free 안 함).
/// `false` 반환 시 walker가 즉시 free — transient view로만 사용할 때 유용.
pub fn scanRoot(
    allocator: std.mem.Allocator,
    root: []const u8,
    filter: Filter,
    context: anytype,
    comptime visit: fn (ctx: @TypeOf(context), full_path: []const u8) bool,
) !void {
    var dir = try std.fs.cwd().openDir(root, .{ .iterate = true });
    defer dir.close();

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        if (hasSkippedSegment(entry.path)) continue;
        if (!passesFilter(entry.path, filter)) continue;

        const full_path = try std.fs.path.join(allocator, &.{ root, entry.path });
        const taken = visit(context, full_path);
        if (!taken) allocator.free(full_path);
    }
}

test "hasSkippedSegment: '/' 경계 매칭" {
    const t = std.testing;
    try t.expect(hasSkippedSegment("a/node_modules/b.js"));
    try t.expect(hasSkippedSegment("node_modules/x.js"));
    try t.expect(hasSkippedSegment(".git/HEAD"));
    try t.expect(!hasSkippedSegment("my_node_modules_doc.txt"));
    try t.expect(!hasSkippedSegment("src/.gitignore"));
}

test "passesFilter: include/exclude 조합" {
    const t = std.testing;
    const f1: Filter = .{};
    try t.expect(passesFilter("a.ts", f1));

    const f2: Filter = .{ .include = &.{"*.ts"} };
    try t.expect(passesFilter("a.ts", f2));
    try t.expect(!passesFilter("a.js", f2));

    const f3: Filter = .{ .exclude = &.{"*.test.ts"} };
    try t.expect(passesFilter("a.ts", f3));
    try t.expect(!passesFilter("a.test.ts", f3));
}
