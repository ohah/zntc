const std = @import("std");
const ast_mod = @import("../parser/ast.zig");

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

/// The metadata graph can represent a qualified path when every component is
/// a plain ASCII identifier. Other spellings stay on the established analysis
/// path until their source tokens can be preserved individually.
pub fn isSimpleQualifiedPath(name: []const u8) bool {
    var parts = std.mem.splitScalar(u8, name, '.');
    var count: usize = 0;
    while (parts.next()) |part| {
        if (part.len == 0 or !isIdentifierStart(part[0])) return false;
        for (part[1..]) |c| {
            if (!isIdentifierContinue(c)) return false;
        }
        count += 1;
    }
    return count > 1;
}

fn isIdentifierStart(c: u8) bool {
    return (c >= 'a' and c <= 'z') or
        (c >= 'A' and c <= 'Z') or c == '_' or c == '$';
}

fn isIdentifierContinue(c: u8) bool {
    return isIdentifierStart(c) or (c >= '0' and c <= '9');
}

test "qualified TypeScript paths accept only plain ASCII identifier components" {
    try std.testing.expect(isSimpleQualifiedPath("Types.Local"));
    try std.testing.expect(isSimpleQualifiedPath("Outer.Inner.Local"));
    try std.testing.expect(!isSimpleQualifiedPath("Local"));
    try std.testing.expect(!isSimpleQualifiedPath("Types . Local"));
    try std.testing.expect(!isSimpleQualifiedPath("命名.Local"));
}
