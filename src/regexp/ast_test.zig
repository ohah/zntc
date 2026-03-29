const std = @import("std");
const ast = @import("ast.zig");
const Node = ast.Node;
const Tag = ast.Tag;
const NodeIndex = ast.NodeIndex;

test "Node is 24 bytes" {
    try std.testing.expectEqual(24, @sizeOf(Node));
}

test "Tag fits in u8" {
    try std.testing.expectEqual(1, @sizeOf(Tag));
}

test "NodeIndex is u32" {
    try std.testing.expectEqual(4, @sizeOf(NodeIndex));
}
