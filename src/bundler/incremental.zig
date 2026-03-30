//! 증분 빌드 — dev server용
//!
//! 전체 재번들 대신 변경된 모듈만 재파싱+재변환+재emit하여 HMR 속도를 개선한다.
//!
//! 전략:
//!   1. 첫 번들: 전체 빌드, 결과(모듈별 코드)를 캐싱
//!   2. 파일 변경: 해당 모듈만 재빌드, 나머지는 캐시 사용
//!   3. 새 import 추가 시: 전체 재빌드 폴백 (그래프 구조 변경)

const std = @import("std");
const Bundler = @import("bundler.zig").Bundler;
const BundleResult = @import("bundler.zig").BundleResult;
const BundleOptions = @import("bundler.zig").BundleOptions;

/// 절대 경로가 모듈 ID(상대 경로)와 일치하는지 suffix 비교.
/// 경로 구분자를 체크하여 false positive 방지.
pub fn pathMatchesModuleId(abs_path: []const u8, module_id: []const u8) bool {
    return std.mem.eql(u8, abs_path, module_id) or
        (std.mem.endsWith(u8, abs_path, module_id) and
            abs_path.len > module_id.len and abs_path[abs_path.len - module_id.len - 1] == '/');
}

/// JSON 문자열 값 내부의 특수 문자를 이스케이프한다.
fn writeJsonEscaped(writer: anytype, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => try writer.writeByte(c),
        }
    }
}

/// BundleResult의 에러 진단을 JSON 문자열로 변환한다.
fn buildErrorJson(allocator: std.mem.Allocator, result: *const BundleResult) ?[]const u8 {
    const diags = result.getDiagnostics();
    var msg: std.ArrayList(u8) = .empty;
    defer msg.deinit(allocator);
    const w = msg.writer(allocator);

    w.print("{{\"type\":\"error\",\"errors\":[", .{}) catch return null;
    for (diags, 0..) |d, i| {
        if (i > 0) w.print(",", .{}) catch {};
        w.print("{{\"file\":\"", .{}) catch return null;
        writeJsonEscaped(w, d.file_path) catch return null;
        w.print("\",\"message\":\"", .{}) catch return null;
        writeJsonEscaped(w, d.message) catch return null;
        w.print("\"}}", .{}) catch return null;
    }
    w.print("]}}", .{}) catch return null;
    return allocator.dupe(u8, msg.items) catch null;
}

/// 증분 dev 번들러. 모듈별 코드를 캐싱하여 변경 시 부분 재빌드.
pub const IncrementalBundler = struct {
    allocator: std.mem.Allocator,
    options: BundleOptions,

    /// 캐시된 모듈별 dev code (module_id → __zts_register code)
    module_cache: std.StringHashMap(CachedModule),
    /// 마지막 번들의 모듈 경로 목록
    last_paths: ?[]const []const u8 = null,
    /// 전체 재빌드가 필요한지 (첫 빌드 또는 그래프 변경)
    needs_full_rebuild: bool = true,

    const CachedModule = struct {
        id: []const u8,
        code: []const u8,
    };

    pub fn init(allocator: std.mem.Allocator, options: BundleOptions) IncrementalBundler {
        return .{
            .allocator = allocator,
            .options = options,
            .module_cache = std.StringHashMap(CachedModule).init(allocator),
        };
    }

    pub fn deinit(self: *IncrementalBundler) void {
        self.clearCache();
        self.module_cache.deinit();
    }

    fn clearCache(self: *IncrementalBundler) void {
        var it = self.module_cache.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.value_ptr.id);
            self.allocator.free(entry.value_ptr.code);
        }
        self.module_cache.clearRetainingCapacity();

        if (self.last_paths) |paths| {
            for (paths) |p| self.allocator.free(p);
            self.allocator.free(paths);
        }
        self.last_paths = null;
    }

    /// 증분 번들. changed_paths가 주어지면 해당 모듈만 재빌드 시도.
    /// 그래프 변경(새 import 추가 등)이 감지되면 자동으로 전체 재빌드 폴백.
    pub fn rebuild(self: *IncrementalBundler, changed_paths: []const []const u8) !RebuildResult {
        if (self.needs_full_rebuild) {
            return self.doBuild(changed_paths, true);
        }
        return self.doBuild(changed_paths, false);
    }

    fn doBuild(self: *IncrementalBundler, changed_paths: []const []const u8, is_first: bool) !RebuildResult {
        var bundler = Bundler.init(self.allocator, self.options);
        defer bundler.deinit();

        var result = bundler.bundle() catch return .fatal;

        if (result.hasErrors()) {
            const err_json = buildErrorJson(self.allocator, &result) orelse {
                result.deinit(self.allocator);
                return .fatal;
            };
            result.deinit(self.allocator);
            return .{ .build_error = err_json };
        }

        // 모듈 수 변경 → 그래프 구조 변경
        const old_path_count = if (self.last_paths) |lp| lp.len else 0;
        const new_path_count = if (result.module_paths) |np| np.len else 0;
        const graph_changed = is_first or new_path_count != old_path_count;

        // 변경된 모듈 코드만 수집 (캐시 대비 diff)
        var actually_changed: std.ArrayList(BundleResult.ModuleDevCode) = .empty;
        defer actually_changed.deinit(self.allocator);

        if (!is_first) {
            if (result.module_dev_codes) |new_codes| {
                // 최대 크기를 사전 확보 → appendAssumeCapacity는 OOM 불가
                try actually_changed.ensureTotalCapacity(self.allocator, new_codes.len);

                for (new_codes) |nc| {
                    const cached = self.module_cache.get(nc.id);
                    const code_changed = if (cached) |c| !std.mem.eql(u8, c.code, nc.code) else true;

                    if (code_changed) {
                        var is_changed_file = graph_changed or cached == null;
                        if (!is_changed_file) {
                            for (changed_paths) |cp| {
                                if (pathMatchesModuleId(cp, nc.id)) {
                                    is_changed_file = true;
                                    break;
                                }
                            }
                        }
                        if (is_changed_file) {
                            actually_changed.appendAssumeCapacity(nc);
                        }
                    }
                }
            }
        }

        self.updateCache(&result);
        if (is_first) self.needs_full_rebuild = false;
        result.deinit(self.allocator);

        return .{
            .success = .{
                .paths = self.last_paths orelse &.{},
                .changed_modules = try actually_changed.toOwnedSlice(self.allocator),
                .graph_changed = graph_changed,
            },
        };
    }

    fn updateCache(self: *IncrementalBundler, result: *const BundleResult) void {
        self.clearCache();

        if (result.module_paths) |paths| {
            const copied = self.allocator.alloc([]const u8, paths.len) catch {
                self.needs_full_rebuild = true;
                return;
            };
            for (paths, 0..) |p, i| {
                copied[i] = self.allocator.dupe(u8, p) catch "";
            }
            self.last_paths = copied;
        }

        if (result.module_dev_codes) |codes| {
            for (codes) |c| {
                const id = self.allocator.dupe(u8, c.id) catch continue;
                const code = self.allocator.dupe(u8, c.code) catch {
                    self.allocator.free(id);
                    continue;
                };
                self.module_cache.put(id, .{ .id = id, .code = code }) catch {
                    self.allocator.free(id);
                    self.allocator.free(code);
                };
            }
        }
    }

    pub const RebuildSuccess = struct {
        paths: []const []const u8,
        changed_modules: []const BundleResult.ModuleDevCode,
        graph_changed: bool,
    };

    pub const RebuildResult = union(enum) {
        success: RebuildSuccess,
        build_error: []const u8,
        fatal,
    };
};
