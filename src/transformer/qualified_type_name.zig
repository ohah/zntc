const std = @import("std");
const Scanner = @import("../lexer/scanner.zig").Scanner;
const Kind = @import("../lexer/token.zig").Kind;
const ast_mod = @import("../parser/ast.zig");

pub const QualifiedPath = struct {
    /// Canonical identifier spelling for each component, owned by the caller allocator.
    parts: [][]const u8,

    pub fn deinit(self: QualifiedPath, allocator: std.mem.Allocator) void {
        for (self.parts) |part| allocator.free(part);
        allocator.free(self.parts);
    }
};

/// Return the spelling of a TypeScript type reference's qualified name,
/// excluding generic arguments. The parser stores the name's source bounds in
/// the first two extra-data slots.
pub fn typeReferenceName(ast: *const ast_mod.Ast, node: ast_mod.Node) ?[]const u8 {
    if (node.tag != .ts_type_reference) return null;
    const start = node.data.extra;
    if (start > ast.extra_data.items.len or ast.extra_data.items.len - start < 2) return null;
    const name_start: usize = @intCast(ast.extra_data.items[start]);
    const name_end: usize = @intCast(ast.extra_data.items[start + 1]);
    if (name_start > name_end or name_end > ast.source.len) return null;
    return ast.source[name_start..name_end];
}

/// Parse a TypeScript qualified type path using the source lexer, then retain
/// canonical component names for the generated lexical reference and property
/// nodes. Lexer token spans keep comments and spacing out of emitted names.
pub fn parseQualifiedPath(allocator: std.mem.Allocator, name: []const u8) std.mem.Allocator.Error!?QualifiedPath {
    var scanner = Scanner.init(allocator, name) catch return error.OutOfMemory;
    defer scanner.deinit();

    var parts: std.ArrayListUnmanaged([]const u8) = .empty;
    var returned = false;
    defer if (!returned) {
        for (parts.items) |part| allocator.free(part);
        parts.deinit(allocator);
    };

    scanner.next() catch return error.OutOfMemory;
    while (true) {
        if (!isIdentifierName(scanner.token.kind)) return null;
        const span = scanner.token.span;
        if (span.start >= span.end or span.end > name.len) return null;
        const raw = name[span.start..span.end];
        const decoded = Scanner.decodeIdentifierEscapesAlloc(allocator, raw) catch return error.OutOfMemory;
        const canonical = if (decoded.ptr == raw.ptr)
            allocator.dupe(u8, decoded) catch {
                return error.OutOfMemory;
            }
        else
            decoded;
        parts.append(allocator, canonical) catch {
            allocator.free(canonical);
            return error.OutOfMemory;
        };

        scanner.next() catch return error.OutOfMemory;
        if (scanner.token.kind == .eof) break;
        if (scanner.token.kind != .dot) return null;
        scanner.next() catch return error.OutOfMemory;
    }

    if (parts.items.len < 2) return null;
    const owned_parts = parts.toOwnedSlice(allocator) catch return error.OutOfMemory;
    returned = true;
    return .{ .parts = owned_parts };
}

/// True when the source is exactly a qualified identifier path, with ordinary
/// JavaScript trivia/comments accepted between tokens.
pub fn isSimpleQualifiedPath(allocator: std.mem.Allocator, name: []const u8) std.mem.Allocator.Error!bool {
    var path = (try parseQualifiedPath(allocator, name)) orelse return false;
    defer path.deinit(allocator);
    return true;
}

fn isIdentifierName(kind: Kind) bool {
    return kind == .identifier or kind.isKeyword();
}

test "qualified TypeScript paths preserve Unicode escapes and token boundaries" {
    const allocator = std.testing.allocator;
    const cases = [_]struct {
        source: []const u8,
        expected: ?[]const []const u8,
    }{
        .{ .source = "Types.Local", .expected = &.{ "Types", "Local" } },
        .{ .source = "Outer.Inner.Local", .expected = &.{ "Outer", "Inner", "Local" } },
        .{ .source = "Types . Local", .expected = &.{ "Types", "Local" } },
        .{ .source = "Types.default", .expected = &.{ "Types", "default" } },
        .{ .source = "Types /* comment */ . Local", .expected = &.{ "Types", "Local" } },
        .{ .source = "Types.\n// line comment\nLocal", .expected = &.{ "Types", "Local" } },
        .{ .source = "命名 . 型", .expected = &.{ "命名", "型" } },
        .{ .source = "\\u547d\\u540d.Local", .expected = &.{ "命名", "Local" } },
        .{ .source = "Types.\\u578b", .expected = &.{ "Types", "型" } },
        .{ .source = "Types.Local<string>", .expected = null },
        .{ .source = "Types...Local", .expected = null },
        .{ .source = "Types.Local.", .expected = null },
        .{ .source = "Types.", .expected = null },
        .{ .source = "Local", .expected = null },
    };
    for (cases) |case| {
        var parsed = try parseQualifiedPath(allocator, case.source);
        if (case.expected) |expected| {
            try std.testing.expect(parsed != null);
            defer parsed.?.deinit(allocator);
            try std.testing.expectEqual(expected.len, parsed.?.parts.len);
            for (expected, parsed.?.parts) |want, got| try std.testing.expectEqualStrings(want, got);
        } else {
            try std.testing.expect(parsed == null);
        }
    }
}
