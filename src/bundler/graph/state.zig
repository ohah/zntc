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
    names: std.StringHashMapUnmanaged(void) = .{},

    pub fn deinit(self: *RequestedExports, allocator: std.mem.Allocator) void {
        self.names.deinit(allocator);
    }
};

pub const ModuleList = @import("../module_list.zig").StableSegmentedList(module_mod.Module);
pub const ModulesIterator = ModuleList.ConstIterator;
