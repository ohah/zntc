//! Producer-owned snapshots for static initializers moved outside their class.
const std = @import("std");
const ast_mod = @import("../parser/ast.zig");
const NodeIndex = ast_mod.NodeIndex;
const Span = @import("../lexer/token.zig").Span;
const ScopeId = @import("../semantic/scope.zig").ScopeId;
const es_helpers = @import("es_helpers.zig");

pub const Frame = struct {
    class_binding: NodeIndex,
    class_name: Span,
    class_symbol_id: ?u32,
    class_self_symbol_id: ?u32,
    output_scope: ScopeId,
};

pub const Capture = struct {
    frame: Frame,
    binding: NodeIndex,
    name: Span,
    symbol_id: ?u32,
};

pub fn pushContext(self: anytype, name: ?Span) !void {
    const class_name = name orelse return;
    const binding = self.current_class_name_node;
    if (binding.isNone()) return;
    const binding_name = self.ast.getNode(binding).data.string_ref;
    if (!std.mem.eql(u8, self.ast.getText(binding_name), self.ast.getText(class_name))) return;
    const output_id = if (self.options.unsupported.class)
        self.current_class_self_symbol_id
    else
        self.getSymbolIdAt(binding);
    var output_scope: ScopeId = .none;
    if (self.semantic_edit_enabled) {
        const self_id = self.current_class_self_symbol_id orelse
            std.debug.panic("static class context has no source self SymbolId", .{});
        const symbols = if (self.semantic_editor) |*editor| editor.symbols.items else self.symbols;
        const scopes = if (self.semantic_editor) |*editor| editor.scopes.items else self.scopes;
        if (self_id >= symbols.len or output_id == null or output_id.? >= symbols.len)
            std.debug.panic("static class context has invalid producer identity", .{});
        const self_scope = symbols[self_id].scope_id;
        if (self_scope.isNone() or self_scope.toIndex() >= scopes.len)
            std.debug.panic("static class context has no source self owner", .{});
        output_scope = if (scopes[self_scope.toIndex()].kind == .class_body)
            scopes[self_scope.toIndex()].parent
        else
            self_scope;
        if (output_scope.isNone()) std.debug.panic("static class capture has no planned output scope", .{});
    }
    try self.static_class_contexts.append(self.allocator, .{
        .class_binding = binding,
        .class_name = class_name,
        .class_symbol_id = output_id,
        .class_self_symbol_id = self.current_class_self_symbol_id,
        .output_scope = output_scope,
    });
}

fn ensureCapture(self: anytype, frame: Frame) !Capture {
    if (self.static_class_captures.get(@backingInt(frame.class_binding))) |capture| {
        if (capture.frame.class_symbol_id != frame.class_symbol_id or capture.frame.output_scope != frame.output_scope)
            std.debug.panic("static class capture changed its producer identity", .{});
        return capture;
    }
    // Distinct producers must have distinct staging spellings before final
    // output naming, including captures first encountered in nested classes.
    if (self.name_arena == null) self.name_arena = std.heap.ArenaAllocator.init(self.allocator);
    const staging = try std.fmt.allocPrint(self.name_arena.?.allocator(), "_classThis{d}", .{@backingInt(frame.class_binding)});
    const output_name = try es_helpers.resolveScopedSyntheticOutputNameWithGraph(self, staging, frame.output_scope);
    const name = try self.ast.addString(output_name.name);
    const binding = try es_helpers.makeExactSyntheticBindingFromSpan(self, name);
    const symbol = if (self.semantic_edit_enabled)
        try self.declareSyntheticInScope(binding, self.ast.getNode(frame.class_binding).span, if (self.options.unsupported.class) .variable_var else .variable_const, frame.output_scope)
    else
        null;
    if (output_name.late) es_helpers.markStandaloneLateSyntheticSymbol(self, symbol orelse
        std.debug.panic("late static class capture has no SymbolId", .{}), .standalone_generated_binding);
    const capture: Capture = .{ .frame = frame, .binding = binding, .name = name, .symbol_id = if (symbol) |id| @backingInt(id) else null };
    try self.static_class_captures.put(self.allocator, @backingInt(frame.class_binding), capture);
    return capture;
}

fn makeReferenceWithFlags(self: anytype, frame: Frame, flags: @import("../semantic/symbol.zig").ReferenceFlags) !NodeIndex {
    const capture = try ensureCapture(self, frame);
    const ref = try es_helpers.makeExactSyntheticRefFromSpan(self, capture.name);
    if (capture.symbol_id) |id| {
        try self.addSyntheticRefInScope(ref, @fromBackingInt(@intCast(id)), self.current_scope, flags);
        try self.trackExactOutputReference(ref, id);
    }
    return ref;
}

pub fn makeThisReference(self: anytype) !?NodeIndex {
    if (self.static_class_contexts.items.len == 0) return null;
    return try makeReferenceWithFlags(self, self.static_class_contexts.items[self.static_class_contexts.items.len - 1], .{ .read = true });
}

pub fn makeClassSelfReference(self: anytype, source: NodeIndex) !?NodeIndex {
    if (!self.semantic_edit_enabled) return null;
    const source_id = self.getSymbolIdAt(source) orelse return null;
    var i = self.static_class_contexts.items.len;
    while (i > 0) {
        i -= 1;
        const frame = self.static_class_contexts.items[i];
        if (frame.class_self_symbol_id == source_id) {
            var flags: @import("../semantic/symbol.zig").ReferenceFlags = .{ .read = true };
            if (self.ast.getNode(source).tag == .assignment_target_identifier) {
                flags = .{ .write = true };
                for (self.references) |reference| {
                    if (reference.node_index == source) {
                        flags = reference.flags;
                        break;
                    }
                }
            }
            const ref = try makeReferenceWithFlags(self, frame, flags);
            if (self.ast.getNode(source).tag == .assignment_target_identifier)
                self.ast.nodes.items[@backingInt(ref)].tag = .assignment_target_identifier;
            return ref;
        }
    }
    return null;
}

/// Emit exactly once, after the class value exists and before static effects.
pub fn takeDeclaration(self: anytype, class_binding: NodeIndex, span: Span) !?NodeIndex {
    if (class_binding.isNone()) return null;
    const entry = self.static_class_captures.fetchRemove(@backingInt(class_binding)) orelse return null;
    const capture = entry.value;
    const value = try es_helpers.makeIdentifierRefFromSpan(self, capture.frame.class_name);
    if (capture.frame.class_symbol_id) |id| {
        if (self.semantic_edit_enabled) {
            try self.addSyntheticRefInScope(value, @fromBackingInt(@intCast(id)), capture.frame.output_scope, .{ .read = true });
            try self.trackExactOutputReference(value, id);
        } else {
            // Legacy callers may carry source SymbolIds without a scope graph.
            // Keep that source identity without creating a semantic editor.
            const raw = @backingInt(value);
            if (self.symbol_ids.items.len <= raw)
                try self.symbol_ids.appendNTimes(self.allocator, null, raw + 1 - self.symbol_ids.items.len);
            self.symbol_ids.items[raw] = id;
        }
    }
    const declarator = try es_helpers.makeDeclarator(self, capture.binding, value, span);
    const declaration = try es_helpers.makeVarDeclaration(self, &.{declarator}, if (self.options.unsupported.class) .@"var" else .@"const", span);
    if (!self.options.unsupported.class)
        try self.ast.preserve_const_declaration_indices.append(self.allocator, @backingInt(declaration));
    return declaration;
}

/// A moved initializer loses the class-field evaluation environment. In
/// particular, direct eval can read lexical `this` without any AST this node.
/// Numeric literal arithmetic does not observe that environment.
fn unsafeEvalCall(self: anytype, node: ast_mod.Node, ordinary_function: bool) bool {
    if (node.tag != .call_expression) return false;
    const e = node.data.extra;
    const extras = self.ast.extra_data.items;
    if (e > extras.len or extras.len - e < 4) return true;
    if ((extras[e + 3] & ast_mod.CallFlags.optional_chain) != 0) return false;
    var callee = self.ast.readExtraNode(e, 0);
    while (!callee.isNone()) {
        const n = self.ast.getNode(callee);
        if (n.tag == .parenthesized_expression or ast_mod.Node.Tag.isTransparentTypeWrapper(n.tag)) {
            callee = n.data.unary.operand;
            continue;
        }
        if (n.tag != .identifier_reference) return false;
        const raw = self.ast.identifierNameText(n);
        var buffer: [64]u8 = undefined;
        const name = @import("../lexer/scanner.zig").Scanner.decodeIdentifierEscapesInto(raw, &buffer) orelse raw;
        if (!std.mem.eql(u8, name, "eval")) return false;
        // A lexical binding named eval can still contain the builtin and
        // perform direct eval. Symbol ownership cannot prove its call indirect.
        break;
    }
    if (callee.isNone() or extras[e + 2] == 0) return false;
    const argument = self.ast.getNode(self.ast.readExtraNode(extras[e + 1], 0));
    if (argument.tag != .string_literal) return true;
    _ = ordinary_function;
    const decoded = @import("../string_escape.zig").decodeJsStringLiteral(self.allocator, self.ast.getText(argument.span)) catch return true;
    defer self.allocator.free(decoded);
    const text = std.mem.trim(u8, decoded, " \t\r\n");
    // Only bounded expressions that cannot observe the class environment or
    // inherited strictness are safe to move. Ordinary functions created in a
    // field also inherit class strictness, even though they own this/arguments.
    var arithmetic = true;
    for (text, 0..) |c, index| {
        if (std.mem.indexOfScalar(u8, "0123456789.+-*/%() \t\r\n", c) == null) arithmetic = false;
        // Legacy leading-zero integer literals throw only in strict eval.
        if (c == '0' and index + 1 < text.len and std.ascii.isDigit(text[index + 1]) and
            (index == 0 or (!std.ascii.isDigit(text[index - 1]) and text[index - 1] != '.'))) return true;
    }
    if (arithmetic) return false;
    if (text.len == 0 or !(std.ascii.isAlphabetic(text[0]) or text[0] == '_' or text[0] == '$')) return true;
    for (text[1..]) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '$')) return true;
    var scanner = @import("../lexer/scanner.zig").Scanner.init(self.allocator, text) catch return true;
    defer scanner.deinit();
    scanner.next() catch return true;
    if (scanner.token.kind != .identifier or std.mem.eql(u8, text, "arguments") or std.mem.eql(u8, text, "eval")) return true;
    for (self.static_class_contexts.items) |frame| {
        const raw_name = self.ast.getText(frame.class_name);
        var name_buffer: [256]u8 = undefined;
        const class_name = @import("../lexer/scanner.zig").Scanner.decodeIdentifierEscapesInto(raw_name, &name_buffer) orelse raw_name;
        if (std.mem.eql(u8, text, class_name)) return true;
    }
    return false;
}

pub fn noteDynamicEval(self: anytype, node: ast_mod.Node) void {
    if (self.static_block_class_name == null) return;
    if (self.this_depth > 0 and self.static_class_contexts.items.len > 0 and
        self.current_class_name_node != self.static_class_contexts.items[self.static_class_contexts.items.len - 1].class_binding) return;
    if (unsafeEvalCall(self, node, self.this_depth > 0))
        self.used_unsupported_static_initializer_dynamic_scope = true;
}

/// Check before an arrow guard can retain its unvisited source body. Ordinary
/// functions still inherit the field's strictness; nested classes own their
/// native class environment and are handled in their own initializer frames.
pub fn noteArrowDynamicEval(self: anytype, root: NodeIndex) !void {
    if (self.static_block_class_name == null or self.this_depth != 0) return;
    const Entry = struct { node: NodeIndex, ordinary: bool };
    var stack: std.ArrayList(Entry) = .empty;
    defer stack.deinit(self.allocator);
    try stack.append(self.allocator, .{ .node = root, .ordinary = false });
    while (stack.pop()) |entry| {
        const idx = entry.node;
        if (idx.isNone()) continue;
        const node = self.ast.getNode(idx);
        var ordinary = entry.ordinary;
        if (idx != root) switch (node.tag) {
            .method_definition, .class_declaration, .class_expression => continue,
            .function, .function_expression, .function_declaration => ordinary = true,
            else => {},
        };
        if (unsafeEvalCall(self, node, ordinary)) self.used_unsupported_static_initializer_dynamic_scope = true;
        var children = @import("../parser/ast_walk.zig").children(self.ast, node);
        while (children.next()) |child| try stack.append(self.allocator, .{ .node = child, .ordinary = ordinary });
    }
}
