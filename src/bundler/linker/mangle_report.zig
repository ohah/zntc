const std = @import("std");
const spin = @import("../../util/spin_lock.zig");

const ManglerStats = @import("../../codegen/mangler.zig").ManglerStats;

/// `--mangle-report` 전용 측정 수집기 (#1760 property harness).
///
/// Bundler 가 생성해 `Linker.mangle_report` 에 꽂으면 `computeMangling` 과
/// `buildMetadataForAst` 내부 nested mangler 가 호출마다 통계를 append.
/// Unified mangler 마이그레이션 전/후의 수치 비교 baseline.
///
/// `buildMetadataForAst` 는 emitter 가 병렬 호출하므로 `recordNested` 는 mutex 보호.
pub const MangleReportCollector = struct {
    allocator: std.mem.Allocator,
    mutex: spin.SpinLock = .{},

    top_level: ManglerStats = .{},
    /// top-level 충돌 방지 pool 크기 (scope_maps 이름 + canonical_strings 합집합).
    top_level_reserved_pool: usize = 0,

    nested: std.ArrayListUnmanaged(NestedEntry) = .empty,
    /// Bundle emit 후 채움.
    bundle_size_bytes: usize = 0,

    pub const NestedEntry = struct {
        /// linker 생명주기 내 유효 (module.path 차용).
        module_path: []const u8,
        stats: ManglerStats,
    };

    pub fn init(allocator: std.mem.Allocator) MangleReportCollector {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *MangleReportCollector) void {
        self.nested.deinit(self.allocator);
    }

    pub fn recordNested(
        self: *MangleReportCollector,
        module_path: []const u8,
        stats: ManglerStats,
    ) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.nested.append(self.allocator, .{ .module_path = module_path, .stats = stats });
    }

    pub fn writeJson(self: *const MangleReportCollector, writer: anytype) !void {
        var totals: ManglerStats = .{
            .slot_count = self.top_level.slot_count,
            .slot_name_length_sum = self.top_level.slot_name_length_sum,
            .renamed_symbol_count = self.top_level.renamed_symbol_count,
        };
        try writer.writeAll("{\n  \"top_level\": ");
        try writeStatsJson(writer, self.top_level);
        try writer.print(",\n  \"top_level_reserved_pool\": {d},\n  \"nested\": [", .{self.top_level_reserved_pool});
        for (self.nested.items, 0..) |entry, i| {
            try writer.writeAll(if (i == 0) "\n    " else ",\n    ");
            try writer.writeAll("{\"module_path\": ");
            try writeJsonString(writer, entry.module_path);
            try writer.writeAll(", \"stats\": ");
            try writeStatsJson(writer, entry.stats);
            try writer.writeAll("}");
            totals.slot_count += entry.stats.slot_count;
            totals.slot_name_length_sum += entry.stats.slot_name_length_sum;
            totals.renamed_symbol_count += entry.stats.renamed_symbol_count;
        }
        try writer.writeAll(if (self.nested.items.len == 0) "]" else "\n  ]");
        try writer.print(",\n  \"bundle_size_bytes\": {d},\n  \"totals\": ", .{self.bundle_size_bytes});
        try writeStatsJson(writer, totals);
        try writer.writeAll("\n}\n");
    }

    fn writeStatsJson(writer: anytype, s: ManglerStats) !void {
        try writer.print(
            "{{\"slot_count\": {d}, \"slot_name_length_sum\": {d}, \"name_counter_final\": {d}, \"reserved_size\": {d}, \"renamed_symbol_count\": {d}}}",
            .{ s.slot_count, s.slot_name_length_sum, s.name_counter_final, s.reserved_size, s.renamed_symbol_count },
        );
    }

    fn writeJsonString(writer: anytype, s: []const u8) !void {
        try writer.writeByte('"');
        for (s) |c| switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => try writer.writeByte(c),
        };
        try writer.writeByte('"');
    }
};
