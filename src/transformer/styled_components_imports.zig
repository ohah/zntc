//! Auto-injected styled-components import for the css prop transform.
//!
//! Keep this as an AST import so codegen and semantic editing see one declaration.
//! Its local specifier and generated css-prop references share a helper SymbolId.

const std = @import("std");
const ast_mod = @import("../parser/ast.zig");
const NodeIndex = ast_mod.NodeIndex;
const Span = @import("../lexer/token.zig").Span;

pub fn appendStyledComponentsImport(
    self: anytype,
    local_name: []const u8,
    span: Span,
    out: *std.ArrayList(NodeIndex),
) !void {
    const anchor: Span = .{ .start = span.start, .end = span.start };
    const local_span = try self.ast.addString(local_name);
    const local = try self.ast.addNode(.{
        .tag = .import_default_specifier,
        .span = local_span,
        .data = .{ .string_ref = local_span },
    });
    // The local name is represented by the specifier node itself. Mark it so
    // semantic import collection does not create a second, ordinary binding.
    try self.markRuntimeHelperRef(local);

    const quoted = try self.ast.addString("\"styled-components\"");
    const source = try self.ast.addNode(.{
        .tag = .string_literal,
        .span = quoted,
        .data = .{ .string_ref = quoted },
    });
    const specs_start = try self.ast.addExtras(&.{@intFromEnum(local)});
    const extra_start = try self.ast.addExtras(&.{
        specs_start,
        1,
        @intFromEnum(source),
        @intFromEnum(@import("../parser/module.zig").ImportPhase.none),
        0,
        0,
    });
    const declaration = try self.ast.addNode(.{
        .tag = .import_declaration,
        .span = anchor,
        .data = .{ .extra = extra_start },
    });

    try self.bindRuntimeHelperImport(local, local_name, anchor);
    try out.append(self.allocator, declaration);
}
