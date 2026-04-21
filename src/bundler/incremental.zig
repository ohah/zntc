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
const ResolveCache = @import("resolve_cache.zig").ResolveCache;
const module_store = @import("module_store.zig");
const CompiledModule = @import("compiled_module.zig").CompiledModule;
const CompiledOutputCache = @import("compiled_cache.zig").CompiledOutputCache;
const debug_log = @import("../debug_log.zig");

/// JSON 문자열 값 내부의 특수 문자를 이스케이프한다 (RFC 8259 준수).
fn writeJsonEscaped(writer: anytype, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => if (c < 0x20) {
                try writer.print("\\u{x:0>4}", .{@as(u16, c)});
            } else {
                try writer.writeByte(c);
            },
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
/// 파싱 캐시(PersistentModuleStore)와 resolve 캐시(ResolveCache)를 빌드 간 보존하여
/// 변경되지 않은 모듈의 재파싱을 스킵한다.
pub const IncrementalBundler = struct {
    allocator: std.mem.Allocator,
    options: BundleOptions,

    /// 캐시된 모듈별 dev code (module_id → __zts_register code)
    module_cache: std.StringHashMap(CachedModule),
    /// 마지막 번들의 모듈 경로 목록
    last_paths: ?[]const []const u8 = null,
    /// 전체 재빌드가 필요한지 (첫 빌드 또는 그래프 변경)
    needs_full_rebuild: bool = true,

    /// 모듈 파싱 캐시 (장기 보존). 변경 안 된 모듈의 AST/semantic을 빌드 간 재사용.
    persistent_store: module_store.PersistentModuleStore,
    /// resolve 캐시 (장기 보존). dir_cache 포함.
    resolve_cache: ?ResolveCache = null,
    /// Compiled output cache — 변경 안 된 모듈의 emit 결과를 빌드 간 보존.
    /// 첫 빌드 시엔 mtime 이 아직 Module 에 주입되지 않아 miss 만 발생 (B3 에서 확장).
    compiled_cache: CompiledOutputCache,

    /// 모듈 단위 dev/HMR 캐시 엔트리.
    /// `code` = `__zts_register` wrapper (HMR 경로).
    /// `compiled` / `input_hash` = compiled output cache 재사용용 (populate 는 별도 PR).
    const CachedModule = struct {
        id: []const u8,
        code: []const u8,
        compiled: ?CompiledModule = null,
        input_hash: u64 = 0,
    };

    pub fn init(allocator: std.mem.Allocator, options: BundleOptions) IncrementalBundler {
        return .{
            .allocator = allocator,
            .options = options,
            .module_cache = std.StringHashMap(CachedModule).init(allocator),
            .persistent_store = module_store.PersistentModuleStore.init(allocator),
            .compiled_cache = CompiledOutputCache.init(allocator),
        };
    }

    pub fn deinit(self: *IncrementalBundler) void {
        self.clearCache();
        self.module_cache.deinit();
        self.persistent_store.deinit();
        self.compiled_cache.deinit();
        if (self.resolve_cache) |*rc| rc.deinit();
    }

    /// 외부에서 캐시 전체 무효화 (Control API `/reset-cache` 등).
    /// 다음 rebuild()는 초기 빌드와 동일한 전체 재번들.
    pub fn reset(self: *IncrementalBundler) void {
        self.clearCache();
        self.persistent_store.deinit();
        self.persistent_store = module_store.PersistentModuleStore.init(self.allocator);
        self.compiled_cache.clear();
        self.needs_full_rebuild = true;
    }

    fn clearCache(self: *IncrementalBundler) void {
        var it = self.module_cache.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.value_ptr.id);
            self.allocator.free(entry.value_ptr.code);
            if (entry.value_ptr.compiled) |c| c.deinit(self.allocator);
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
    pub fn rebuild(self: *IncrementalBundler) !RebuildResult {
        if (self.needs_full_rebuild) {
            return self.doBuild(true);
        }
        return self.doBuild(false);
    }

    fn doBuild(self: *IncrementalBundler, is_first: bool) !RebuildResult {
        // resolve_cache 초기화 (첫 빌드 시) 또는 재사용
        if (self.resolve_cache == null) {
            self.resolve_cache = ResolveCache.init(self.allocator, .{
                .platform = self.options.platform,
                .external_patterns = self.options.external,
                .custom_conditions = self.options.conditions,
                .preserve_symlinks = self.options.preserve_symlinks,
                .alias = self.options.alias,
                .fallback = self.options.fallback,
                .block_list = self.options.block_list,
                .resolve_extensions = self.options.resolve_extensions,
                .main_fields = self.options.main_fields,
            });
        }

        // 증분 빌드: 첫 빌드가 아니면 module_store 를 전달하여 파싱 캐시 활용.
        // compiled_cache 는 매 빌드 주입 — miss 는 안전하게 폴백 (emit 경로가 cache 없을 때와 동일).
        var opts = self.options;
        opts.compiled_cache = &self.compiled_cache;
        if (!is_first) {
            opts.module_store = &self.persistent_store;
        }

        var bundler = Bundler.initWithResolveCache(self.allocator, opts, &self.resolve_cache.?);
        defer bundler.deinit(); // resolve_cache_external=true이므로 resolve_cache는 해제 안 됨

        var result = bundler.bundle() catch return .fatal;

        if (result.hasErrors()) {
            const err_json = buildErrorJson(self.allocator, &result) orelse {
                result.deinit(self.allocator);
                return .fatal;
            };
            result.deinit(self.allocator);
            return .{ .build_error = err_json };
        }

        const graph_changed = is_first or !self.pathSetsEqual(result.module_paths);

        // 그래프 구조 변경 (모듈 추가/제거) 시 compiled_cache 전체 무효화.
        // 삭제된 경로 엔트리가 stale 하게 남지 않도록 — 단순히 path 필터로 부분 정리하는
        // 최적화는 follow-up. is_first 일 때는 cache 가 비어있어 no-op.
        if (graph_changed and !is_first) self.compiled_cache.clear();

        // 변경된 모듈 코드만 수집 (캐시 대비 diff)
        var actually_changed: std.ArrayList(BundleResult.ModuleDevCode) = .empty;
        defer actually_changed.deinit(self.allocator);

        if (!is_first) {
            if (result.module_dev_codes) |new_codes| {
                try actually_changed.ensureTotalCapacity(self.allocator, new_codes.len);

                for (new_codes) |nc| {
                    const cached = self.module_cache.get(nc.id);
                    const code_changed = if (cached) |c| !std.mem.eql(u8, c.code, nc.code) else true;
                    if (!code_changed) continue;
                    // id/code/map 을 dupe — result.deinit 후에도 slice 가 유효해야 함.
                    // ownership 은 caller 에게 넘어간다 (BundleResult.ModuleDevCode.freeAll 호출 필수).
                    const id_copy = self.allocator.dupe(u8, nc.id) catch continue;
                    const code_copy = self.allocator.dupe(u8, nc.code) catch {
                        self.allocator.free(id_copy);
                        continue;
                    };
                    const map_copy: ?[]const u8 = if (nc.map) |m| self.allocator.dupe(u8, m) catch {
                        self.allocator.free(id_copy);
                        self.allocator.free(code_copy);
                        continue;
                    } else null;
                    actually_changed.appendAssumeCapacity(.{
                        .id = id_copy,
                        .code = code_copy,
                        .map = map_copy,
                    });
                }
            }
        }

        self.updateCache(&result);
        if (is_first) self.needs_full_rebuild = false;

        if (debug_log.enabled(.compiled_cache)) {
            const stats = self.compiled_cache.takeStats();
            debug_log.print(
                .compiled_cache,
                "first={} hits={d} misses={d} no_mtime_skipped={d} (entries={d})\n",
                .{ is_first, stats.hits, stats.misses, stats.skipped, self.compiled_cache.entries.count() },
            );
        }

        result.deinit(self.allocator);

        return .{
            .success = .{
                .paths = self.last_paths orelse &.{},
                .changed_modules = try actually_changed.toOwnedSlice(self.allocator),
                .graph_changed = graph_changed,
            },
        };
    }

    /// 빌드 결과의 모듈 경로 집합이 캐시와 동일한지 비교 (#951).
    /// 카운트만 비교하면 빌드 경로 차이로 false positive가 발생할 수 있다.
    fn pathSetsEqual(self: *const IncrementalBundler, new_paths_opt: ?[]const []const u8) bool {
        const old_paths = self.last_paths orelse return new_paths_opt == null;
        const new_paths = new_paths_opt orelse return false;

        if (old_paths.len != new_paths.len) return false;

        // old_paths를 해시셋에 넣고 new_paths 전부가 존재하는지 확인
        var set = std.StringHashMap(void).init(self.allocator);
        defer set.deinit();
        set.ensureTotalCapacity(@intCast(old_paths.len)) catch return false;
        for (old_paths) |p| {
            set.putAssumeCapacity(p, {});
        }
        for (new_paths) |p| {
            if (!set.contains(p)) return false;
        }
        return true;
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
        /// Ownership 은 caller 에게 이전 — 각 엔트리의 `id`/`code`/`map` 은
        /// `allocator.dupe` 복사본이므로 `BundleResult.ModuleDevCode.freeAll(_, allocator)`
        /// 로 정리해야 한다. 단순히 slice 만 free 하면 leak.
        changed_modules: []const BundleResult.ModuleDevCode,
        graph_changed: bool,
    };

    pub const RebuildResult = union(enum) {
        success: RebuildSuccess,
        build_error: []const u8,
        fatal,
    };
};

// ── writeJsonEscaped 유닛 테스트 ──

test "writeJsonEscaped: 특수문자 이스케이프" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    const w = buf.writer(std.testing.allocator);

    try writeJsonEscaped(w, "he said \"hello\"\nnew\\line\ttab");
    try std.testing.expectEqualStrings(
        "he said \\\"hello\\\"\\nnew\\\\line\\ttab",
        buf.items,
    );
}

test "writeJsonEscaped: 빈 문자열" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    const w = buf.writer(std.testing.allocator);

    try writeJsonEscaped(w, "");
    try std.testing.expectEqual(@as(usize, 0), buf.items.len);
}

test "writeJsonEscaped: 일반 텍스트" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    const w = buf.writer(std.testing.allocator);

    try writeJsonEscaped(w, "hello world 123");
    try std.testing.expectEqualStrings("hello world 123", buf.items);
}
