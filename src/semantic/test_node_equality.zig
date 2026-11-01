//! Test-only structural equality for provenance containing tagged AST payloads.
const std = @import("std");
const Node = @import("../parser/ast.zig").Node;

pub fn expectEqualDeep(expected: anytype, actual: @TypeOf(expected)) error{TestExpectedEqual}!void {
    const T = @TypeOf(expected);
    if (T == Node) {
        // Keep every Node header field, including future additions. Only the
        // untagged Data field needs its parser-defined active layout selected.
        inline for (@typeInfo(Node).@"struct".field_names) |field| {
            if (comptime !std.mem.eql(u8, field, "data"))
                try expectEqualDeep(@field(expected, field), @field(actual, field));
        }
        switch (expected.tag.dataKind()) {
            .extra => try expectEqualDeep(expected.data.extra, actual.data.extra),
            .list => try expectEqualDeep(expected.data.list, actual.data.list),
            .ternary => try expectEqualDeep(expected.data.ternary, actual.data.ternary),
            .unary => {
                try expectEqualDeep(expected.data.unary.operand, actual.data.unary.operand);
                try expectEqualDeep(expected.data.unary.flags, actual.data.unary.flags);
            },
            .binary => {
                try expectEqualDeep(expected.data.binary.left, actual.data.binary.left);
                try expectEqualDeep(expected.data.binary.right, actual.data.binary.right);
                try expectEqualDeep(expected.data.binary.flags, actual.data.binary.flags);
            },
            .leaf => {
                // The parser's leaf-width table distinguishes string/number
                // storage from none-only payloads; never inspect union padding.
                if (Node.Tag.dataWidth(expected.tag) == 8)
                    try expectEqualDeep(expected.data.string_ref, actual.data.string_ref)
                else
                    try expectEqualDeep(expected.data.none, actual.data.none);
            },
        }
        return;
    }
    switch (@typeInfo(T)) {
        .@"struct" => |info| inline for (info.field_names) |field| {
            try expectEqualDeep(@field(expected, field), @field(actual, field));
        },
        .optional => {
            try std.testing.expectEqual(expected != null, actual != null);
            if (expected) |value| try expectEqualDeep(value, actual.?);
        },
        .array => |info| inline for (0..info.len) |i| {
            try expectEqualDeep(expected[i], actual[i]);
        },
        .vector => |info| inline for (0..info.len) |i| {
            try expectEqualDeep(expected[i], actual[i]);
        },
        .pointer => |info| switch (info.size) {
            .slice => {
                try std.testing.expectEqual(expected.len, actual.len);
                for (expected, actual) |left, right| try expectEqualDeep(left, right);
            },
            .one => switch (@typeInfo(info.child)) {
                .@"fn", .@"opaque" => try std.testing.expectEqual(expected, actual),
                else => try expectEqualDeep(expected.*, actual.*),
            },
            .many, .c => try std.testing.expectEqual(expected, actual),
        },
        .@"union" => |info| {
            if (info.tag_type == null) @compileError("test equality requires an enclosing active tag for " ++ @typeName(T));
            try std.testing.expectEqual(std.meta.activeTag(expected), std.meta.activeTag(actual));
            switch (expected) {
                inline else => |value, tag| try expectEqualDeep(value, @field(actual, @tagName(tag))),
            }
        },
        .error_union => {
            if (expected) |value| {
                if (actual) |other| try expectEqualDeep(value, other) else |_| return error.TestExpectedEqual;
            } else |wanted| {
                if (actual) |_| return error.TestExpectedEqual else |found| try expectEqualDeep(wanted, found);
            }
        },
        else => try std.testing.expectEqualDeep(expected, actual),
    }
}
