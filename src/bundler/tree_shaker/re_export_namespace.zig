//! Re-export namespace usage accumulator.

const std = @import("std");

pub const ConsumerUsage = struct {
    opaque_all: bool = false,
    entries: std.StringHashMapUnmanaged(Entry) = .empty,

    pub const Entry = struct {
        is_opaque: bool = false,
        props: std.StringHashMapUnmanaged(void) = .empty,
    };

    pub fn deinit(self: *ConsumerUsage, allocator: std.mem.Allocator) void {
        var vit = self.entries.valueIterator();
        while (vit.next()) |entry| entry.props.deinit(allocator);
        self.entries.deinit(allocator);
    }

    pub fn getOrPutEntry(
        self: *ConsumerUsage,
        allocator: std.mem.Allocator,
        name: []const u8,
    ) std.mem.Allocator.Error!*Entry {
        const gop = try self.entries.getOrPut(allocator, name);
        if (!gop.found_existing) gop.value_ptr.* = .{};
        return gop.value_ptr;
    }

    pub fn markOpaque(
        self: *ConsumerUsage,
        allocator: std.mem.Allocator,
        name: []const u8,
    ) std.mem.Allocator.Error!void {
        const entry = try self.getOrPutEntry(allocator, name);
        entry.is_opaque = true;
    }

    pub fn addProps(
        self: *ConsumerUsage,
        allocator: std.mem.Allocator,
        name: []const u8,
        props: []const []const u8,
    ) std.mem.Allocator.Error!void {
        const entry = try self.getOrPutEntry(allocator, name);
        if (entry.is_opaque) return;
        for (props) |prop| try entry.props.put(allocator, prop, {});
    }
};
