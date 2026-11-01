//! Actual object-accessor demand for the existing out-of-scope descriptor provider.
const std = @import("std");
const builtin = @import("object_builtin_reference.zig");
const helpers = @import("es_helpers.zig");
const Transformer = @import("transformer.zig").Transformer;
const NodeIndex = @import("../parser/ast.zig").NodeIndex;

pub fn makePinnedEvalCallee(self: *Transformer, context: builtin.Context) builtin.Error!?NodeIndex {
    try builtin.validate(self, context);
    if (context.operation != .accessor_define_property) return error.InvalidNode;
    // A with object can intercept an ordinary helper read. The provider also
    // requires a real graph import; an inline preamble is not that authority.
    if (self.with_statement_depth != 0 or !self.options.emit_runtime_helper_imports) return null;
    var cursor = switch (context.use_scope) {
        .output => |scope| scope,
        .deferred_until_reanalysis => return null,
    };
    const scopes = if (self.semantic_editor) |*editor| editor.scopes.items else return error.InvalidNode;
    var has_eval = false;
    var hops: usize = 0;
    while (!cursor.isNone()) : (hops += 1) {
        if (hops >= scopes.len or cursor.toIndex() >= scopes.len) return error.InvalidNode;
        const frame = scopes[cursor.toIndex()];
        has_eval = has_eval or frame.subtree_has_direct_eval;
        cursor = frame.parent;
    }
    if (!has_eval or !try sourceHasOnlyObjectLookups(self)) return null;
    const reference = try helpers.makeRuntimeHelperRef(self, "__classDefineProperty");
    self.class_define_property_used = true;
    return reference;
}

/// Reuse the existing dynamic-native object boundary only for an actual
/// computed accessor that needs lowering. No generated helper can be named
/// safely through the surrounding with environment.
pub const NativeReason = enum { with_scope, opaque_eval };

/// A deliberately closed source proof: every direct eval in the immutable
/// parser domain must be precisely the literal lookup `Object`. Scanning the
/// full source domain is conservative; unrelated opaque eval cannot grant a
/// generated helper binding authority.
fn sourceHasOnlyObjectLookups(self: *Transformer) builtin.Error!bool {
    const source = self.semantic_source_ast orelse return error.InvalidNode;
    if (self.parser_node_count > source.nodes.items.len) return error.InvalidNode;
    const view = struct { ast: @TypeOf(source) }{ .ast = source };
    var found = false;
    for (source.nodes.items[0..self.parser_node_count]) |node| {
        if (!@import("static_class_capture.zig").isDirectEvalCall(view, node)) continue;
        found = true;
        const e = node.data.extra;
        if (source.extra_data.items[e + 2] != 1) return false;
        const args = source.extra_data.items[e + 1];
        if (args >= source.extra_data.items.len) return error.InvalidNode;
        const raw = source.extra_data.items[args];
        if (raw >= self.parser_node_count) return error.InvalidNode;
        const argument = source.nodes.items[raw];
        if (argument.tag != .string_literal) return false;
        const decoded = @import("../string_escape.zig").decodeJsStringLiteral(self.allocator, source.getText(argument.span)) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return false,
        };
        defer self.allocator.free(decoded);
        if (!std.mem.eql(u8, std.mem.trim(u8, decoded, " \t\r\n"), "Object")) return false;
    }
    return found;
}

pub fn retainsNativeAccessor(self: *Transformer, object: NodeIndex) builtin.Error!?NativeReason {
    if (!self.options.unsupported.object_extensions or object.isNone() or @backingInt(object) >= self.parser_node_count) return null;
    const ast = @import("../parser/ast.zig");
    const node = self.ast.getNode(object);
    if (node.tag != .object_expression or node.data.list.start > self.ast.extra_data.items.len or node.data.list.len > self.ast.extra_data.items.len - node.data.list.start) return error.InvalidNode;
    for (self.ast.extra_data.items[node.data.list.start..][0..node.data.list.len]) |raw| {
        if (raw >= self.ast.nodes.items.len) return error.InvalidNode;
        const member = self.ast.nodes.items[raw];
        if (member.tag != .method_definition or !self.ast.hasExtra(member.data.extra, ast.MethodExtra.flags)) continue;
        const flags = self.ast.readExtra(member.data.extra, ast.MethodExtra.flags);
        if (flags & (ast.MethodFlags.is_getter | ast.MethodFlags.is_setter) == 0) continue;
        const key = self.ast.readExtraNode(member.data.extra, ast.MethodExtra.key);
        if (key.isNone() or @backingInt(key) >= self.ast.nodes.items.len or self.ast.getNode(key).tag != .computed_property_key) continue;
        const context = try builtin.captureAccessor(self, object, @fromBackingInt(raw));
        if (self.with_statement_depth != 0) return .with_scope;
        // At object entry, the output visitor can still be between frames.
        // Dynamic-name authority comes from the actual immutable member owner,
        // never from a guessed output scope or a subtree-name lookup.
        var cursor = context.source_owner_scope orelse return null;
        var hops: usize = 0;
        var has_eval = false;
        while (!cursor.isNone()) : (hops += 1) {
            if (hops >= context.source_scopes.len or cursor.toIndex() >= context.source_scopes.len) return error.InvalidNode;
            const frame = context.source_scopes[cursor.toIndex()];
            has_eval = has_eval or frame.subtree_has_direct_eval;
            cursor = frame.parent;
        }
        if (has_eval and !try sourceHasOnlyObjectLookups(self)) return .opaque_eval;
    }
    return null;
}
