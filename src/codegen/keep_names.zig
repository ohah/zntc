//! --keep-names: restore the source `.name` of functions and classes whose
//! output binding was renamed (linker deconfliction or mangling).
//!
//! Each name is restored where the value is created, not at the end of the
//! module (#5512), so code that runs earlier never sees the renamed spelling:
//! - function declarations: `__name(f, "f")` at the top of the enclosing
//!   statement list, matching their hoisting (esbuild places it after the
//!   declaration, so earlier reads see the renamed spelling);
//! - classes: `static { __name(this, "C"); }` as the first element, so static
//!   initializers already see the name; without static blocks, `__name(C, "C")`
//!   after a declaration or `__name(class {}, "C")` around an expression;
//! - function expressions and anonymous functions bound to a renamed binding
//!   (declarator, assignment, default value): `__name(function () {}, "x")`.

const std = @import("std");
const ast_mod = @import("../parser/ast.zig");
const rt = @import("../bundler/runtime_helpers.zig");
const NodeIndex = ast_mod.NodeIndex;
const Level = @import("precedence.zig").Level;
const ExprFlags = @import("precedence.zig").ExprFlags;

pub fn helperName(self: anytype) []const u8 {
    if (self.options.keep_names_helper_name) |name| return name;
    return if (self.options.minify_whitespace) rt.NAMES.NAME_MIN else "__name";
}

/// The source spelling of a binding whose output spelling differs from it.
pub fn renamedOriginal(self: anytype, name_idx: NodeIndex) ?[]const u8 {
    if (!self.options.keep_names or name_idx.isNone()) return null;
    const node = self.ast.getNode(name_idx);
    switch (node.tag) {
        .binding_identifier, .identifier_reference, .assignment_target_identifier => {},
        else => return null,
    }
    const original = self.ast.getText(node.data.string_ref);
    const sid = self.sourceSymbolId(name_idx) orelse return null;
    const output = self.finalSymbolName(sid) orelse return null;
    if (std.mem.eql(u8, output, original)) return null;
    return original;
}

/// The renamed binding a function or class expression would take its name
/// from, when `value` is an anonymous function definition.
pub fn hintFor(self: anytype, binding: NodeIndex, value: NodeIndex) ?[]const u8 {
    if (!self.options.keep_names or value.isNone()) return null;
    if (!self.ast.isAnonymousFunctionDefinition(value)) return null;
    return renamedOriginal(self, binding);
}

/// `export default function () {}` is named "default" (bundles bind it to a
/// generated variable).
pub fn defaultExportHint(self: anytype, value: NodeIndex) ?[]const u8 {
    if (!self.options.keep_names or value.isNone()) return null;
    return if (self.ast.isAnonymousFunctionDefinition(value)) "default" else null;
}

/// Emit `value` with `.name` restored to `hint` (null: emit as is).
pub fn emitNamedValue(self: anytype, value: NodeIndex, hint: ?[]const u8, level: Level, flags: ExprFlags) !void {
    const saved = self.keep_name_hint;
    self.keep_name_hint = hint;
    defer self.keep_name_hint = saved;
    try self.emitExpr(value, level, flags);
}

pub fn isFunctionDeclaration(self: anytype, raw: u32) ?NodeIndex {
    var idx: NodeIndex = @fromBackingInt(@intCast(raw));
    if (idx.isNone()) return null;
    var node = self.ast.getNode(idx);
    switch (node.tag) {
        .export_named_declaration => {
            idx = @import("../parser/module.zig").readExportNamedExtras(self.ast, node.data.extra).decl;
            if (idx.isNone()) return null;
            node = self.ast.getNode(idx);
        },
        .export_default_declaration => {
            idx = node.data.unary.operand;
            if (idx.isNone()) return null;
            node = self.ast.getNode(idx);
        },
        else => {},
    }
    if (node.tag != .function_declaration) return null;
    return idx;
}

/// A function declaration whose name must be restored by a hoisted call,
/// and its source name.
pub fn hoistedFunctionName(self: anytype, raw: u32) ?struct { name: NodeIndex, original: []const u8 } {
    if (!self.options.keep_names) return null;
    const decl = isFunctionDeclaration(self, raw) orelse return null;
    const node = self.ast.getNode(decl);
    const flags = self.ast.extra_data.items[node.data.extra + ast_mod.FunctionExtra.flags];
    if (flags & ast_mod.FunctionFlags.name_preserved != 0) return null;
    // `esm_var_assign_only` turns a top-level declaration into an assignment
    // that runs in place; emitFunction names that value instead.
    if (convertsToAssignment(self, node)) return null;
    const name = self.ast.readExtraNode(node.data.extra, ast_mod.FunctionExtra.name);
    const original = renamedOriginal(self, name) orelse return null;
    return .{ .name = name, .original = original };
}

pub fn convertsToAssignment(self: anytype, node: ast_mod.Node) bool {
    return self.options.esm_var_assign_only and node.tag == .function_declaration and
        !self.ast.readExtraNode(node.data.extra, ast_mod.FunctionExtra.name).isNone() and
        self.indent_level == 0 and self.namespace_body_depth == 0;
}

/// A static `name` member defines the class's own `name` (esbuild skips
/// these too); restoring the inferred name would overwrite it.
pub fn classHasStaticName(self: anytype, body: NodeIndex) bool {
    if (body.isNone()) return false;
    const list = self.ast.getNode(body).data.list;
    for (self.ast.extra_data.items[list.start .. list.start + list.len]) |raw| {
        const member = self.ast.getNode(@fromBackingInt(@intCast(raw)));
        const key, const is_static = switch (member.tag) {
            .method_definition => .{
                self.ast.readExtraNode(member.data.extra, ast_mod.MethodExtra.key),
                self.ast.readExtra(member.data.extra, ast_mod.MethodExtra.flags) & ast_mod.MethodFlags.is_static != 0,
            },
            .property_definition, .accessor_property => .{
                self.ast.readExtraNode(member.data.extra, ast_mod.PropertyExtra.key),
                self.ast.readExtra(member.data.extra, ast_mod.PropertyExtra.flags) & ast_mod.PropertyFlags.is_static != 0,
            },
            else => continue,
        };
        if (!is_static) continue;
        const name = self.ast.staticKeyName(self.allocator, key) catch return true;
        defer if (name) |n| self.allocator.free(n);
        if (name) |n| if (std.mem.eql(u8, n, "name")) return true;
    }
    return false;
}

/// `__name(<target>, "original");`
pub fn emitNameStatement(self: anytype, target: NodeIndex, original: []const u8) !void {
    try self.write(helperName(self));
    try self.writeByte('(');
    try self.emitNode(target);
    try self.writeByte(',');
    try self.writeSpace();
    // Source IdentifierName escapes must also honor the target inside the
    // reflected string (in particular ES5 brace escapes and ascii_only).
    try self.writeByte('"');
    try self.writeIdentifierText(original);
    try self.writeByte('"');
    try self.write(");");
    self.keep_names_used = true;
}

/// `static { __name(this, "original"); }` as a class's first element.
pub fn emitStaticNameBlock(self: anytype, original: []const u8) !void {
    try self.write("static");
    try self.writeSpace();
    try self.writeByte('{');
    try self.writeSpace();
    try self.write(helperName(self));
    try self.write("(this,");
    try self.writeSpace();
    try writeQuoted(self, original);
    try self.write(");");
    try self.writeSpace();
    try self.writeByte('}');
    self.keep_names_used = true;
}

pub fn writeQuoted(self: anytype, original: []const u8) !void {
    try self.writeByte('"');
    try self.write(original);
    try self.writeByte('"');
}
