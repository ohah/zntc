const std = @import("std");
const types = @import("../types.zig");
const module_mod = @import("../module.zig");
const pkg_json = @import("../package_json.zig");

pub const PkgInfo = struct {
    is_module: bool,
    side_effects: pkg_json.PackageJson.SideEffects,
};

pub const WorkerEntry = struct {
    /// Resolved absolute worker file path.
    resolved_path: []const u8,
    /// Module index that references the worker.
    source_module: types.ModuleIndex,
    /// Import record index inside the source module.
    record_index: u32,
};

pub const RequestedExports = struct {
    all: bool = false,
    /// PR-Z2: flat array (≈10 평균 names) — HashMap 의 keyIterator bucket scan 보다 빠름.
    /// M7 측정에서 caller copy 가 entry 의 91% (5.4ms). flat array iter 는 contiguous
    /// memcpy + cache locality 로 ~50% 절감 가설.
    names: std.ArrayListUnmanaged([]const u8) = .empty,

    pub fn deinit(self: *RequestedExports, allocator: std.mem.Allocator) void {
        self.names.deinit(allocator);
    }

    /// O(N) linear scan — N 평균 ~10. HashMap.contains 보다 cache locality 이득.
    pub fn contains(self: *const RequestedExports, name: []const u8) bool {
        for (self.names.items) |n| {
            if (std.mem.eql(u8, n, name)) return true;
        }
        return false;
    }
};

pub const ModuleList = @import("../module_list.zig").StableSegmentedList(module_mod.Module);
pub const ModulesIterator = ModuleList.ConstIterator;
