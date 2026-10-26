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
        if (capture.frame.class_symbol_id != frame.class_symbol_id or capture.frame.class_self_symbol_id != frame.class_self_symbol_id or capture.frame.output_scope != frame.output_scope)
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

/// Brand checks must read the class value selected by the mapping producer,
/// even when a nested same-named class or an arrow parameter is active.
pub fn makeClassBindingReference(self: anytype, binding: NodeIndex) !?NodeIndex {
    if (binding.isNone()) return null;
    var index = self.static_class_contexts.items.len;
    while (index > 0) {
        index -= 1;
        const frame = self.static_class_contexts.items[index];
        if (frame.class_binding == binding)
            return try makeReferenceWithFlags(self, frame, .{ .read = true });
    }
    return null;
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
            // This is a new immutable binding's use, not a copy of the source
            // class-self use. Preserve both identities at the actual creator.
            const reference = (self.semantic_editor.?.referenceForNode(ref) catch @panic("static class replacement has invalid Reference index")) orelse
                @panic("static class replacement has no immediate Reference");
            const raw = @backingInt(ref);
            if (raw < self.parser_node_count or @backingInt(reference.symbol_id) == source_id)
                @panic("static class replacement did not create a fresh identity");
            try self.static_class_reference_origins.put(self.allocator, raw, .{
                .source = source,
                .source_symbol_id = source_id,
                .class_value_symbol_id = frame.class_symbol_id orelse @panic("static class replacement lost its class-value SID"),
                .class_binding = frame.class_binding,
                .reference = reference,
            });
            try self.reference_origin_map.put(self.allocator, raw, raw);
            return ref;
        }
    }
    return null;
}

/// The anonymous legacy-decorator creator reserves a distinct outer export
/// slot after static blocks have already selected their immutable snapshot.
/// Transfer that pending capture to this exact class-value carrier, preserving
/// the snapshot symbol and every read that already points to it.
pub fn handoffAnonymousExportValue(self: anytype, source_class: NodeIndex, pending_binding: NodeIndex, actual_binding: NodeIndex, output_scope: ScopeId) !bool {
    const pending_key = @backingInt(pending_binding);
    const source = self.ast.getNode(source_class);
    if ((source.tag != .class_declaration and source.tag != .class_expression) or
        !self.ast.readExtraNode(source.data.extra, ast_mod.ClassExtra.name).isNone() or
        self.lowered_anonymous_class_export_bindings.get(@backingInt(source_class)) != @backingInt(actual_binding) or
        actual_binding == pending_binding or self.ast.getNode(actual_binding).tag != .binding_identifier)
        return error.InvalidClassValueCaptureHandoff;
    if (self.semantic_edit_enabled and !pending_binding.isNone()) {
        if (self.class_self_symbol_map.get(@backingInt(source_class))) |known_self| {
            if (self.getSymbolIdAt(pending_binding) != known_self) return error.InvalidClassValueCaptureHandoff;
        }
    }
    var capture = self.static_class_captures.get(pending_key) orelse return false;
    if (capture.frame.class_binding != pending_binding or capture.frame.output_scope != output_scope)
        return error.InvalidClassValueCaptureHandoff;
    const actual_key = @backingInt(actual_binding);
    if (self.static_class_captures.contains(actual_key) or self.completed_static_class_captures.contains(actual_key))
        return error.InvalidClassValueCaptureHandoff;
    const actual_id = self.getSymbolIdAt(actual_binding);
    if (self.semantic_edit_enabled) {
        const editor = &self.semantic_editor.?;
        const source_self = self.class_self_symbol_map.get(@backingInt(source_class)) orelse return error.InvalidClassValueCaptureHandoff;
        const class_scope = self.outputOwnedScope(source_class) orelse return error.InvalidClassValueCaptureHandoff;
        if (source_self >= editor.symbols.items.len or capture.frame.class_self_symbol_id != source_self or
            self.getSymbolIdAt(pending_binding) != capture.frame.class_symbol_id or
            actual_id == null or actual_id.? >= editor.symbols.items.len or
            editor.symbols.items[actual_id.?].scope_id != output_scope or
            editor.symbols.items[actual_id.?].kind != .variable_let or
            @backingInt(actual_binding) >= editor.symbol_ids.items.len or
            editor.symbol_ids.items[@backingInt(actual_binding)] != actual_id or
            editor.symbols.items[source_self].scope_id != class_scope or
            capture.symbol_id == null or capture.symbol_id.? >= editor.symbols.items.len or
            self.getSymbolIdAt(capture.binding) != capture.symbol_id or
            editor.symbols.items[capture.symbol_id.?].scope_id != output_scope)
            return error.InvalidClassValueCaptureHandoff;
        var proofs = self.static_class_reference_origins.iterator();
        while (proofs.next()) |entry| {
            const proof = entry.value_ptr.*;
            if (proof.class_binding != pending_binding) continue;
            if (proof.source_symbol_id != source_self or proof.class_value_symbol_id != capture.frame.class_symbol_id or
                @backingInt(proof.reference.symbol_id) != capture.symbol_id or
                !validOwnReferenceOrigin(self, @fromBackingInt(entry.key_ptr.*))) return error.InvalidClassValueCaptureHandoff;
        }
    }
    if (actual_id == null) {
        var existing_proofs = self.static_class_reference_origins.valueIterator();
        while (existing_proofs.next()) |proof|
            if (proof.class_binding == pending_binding) return error.InvalidClassValueCaptureHandoff;
    }
    // Validate every link before mutating either registry. Capacity is reserved
    // before removal so allocation failure cannot orphan the pending snapshot.
    try self.static_class_captures.ensureUnusedCapacity(self.allocator, 1);
    capture.frame.class_binding = actual_binding;
    capture.frame.class_name = self.ast.getNode(actual_binding).data.string_ref;
    capture.frame.class_symbol_id = actual_id;
    _ = self.static_class_captures.remove(pending_key);
    self.static_class_captures.putAssumeCapacity(actual_key, capture);
    var proofs = self.static_class_reference_origins.valueIterator();
    while (proofs.next()) |proof| {
        if (proof.class_binding != pending_binding) continue;
        proof.class_binding = actual_binding;
        proof.class_value_symbol_id = actual_id.?;
    }
    return true;
}

/// Emit exactly once, after the class value exists and before static effects.
pub fn takeDeclaration(self: anytype, class_binding: NodeIndex, span: Span) !?NodeIndex {
    if (class_binding.isNone()) return null;
    const entry = self.static_class_captures.fetchRemove(@backingInt(class_binding)) orelse return null;
    const capture = entry.value;
    // Keep the exact consumed creator record without keeping an active capture
    // alive or weakening finishSemanticEdit's active-lifecycle guard.
    try self.completed_static_class_captures.put(self.allocator, @backingInt(class_binding), capture);
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
        try self.ast.preserve_lexical_declaration_indices.append(self.allocator, @backingInt(declaration));
    return declaration;
}

/// A moved initializer loses the class-field evaluation environment. In
/// particular, direct eval can read lexical `this` without any AST this node.
/// Numeric literal arithmetic does not observe that environment.
pub fn isDirectEvalCall(self: anytype, node: ast_mod.Node) bool {
    if (node.tag != .call_expression) return false;
    const e = node.data.extra;
    const extras = self.ast.extra_data.items;
    if (e > extras.len or extras.len - e < 4) return false;
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
    return !callee.isNone();
}

fn unsafeEvalCall(self: anytype, node: ast_mod.Node, ordinary_function: bool) bool {
    if (!isDirectEvalCall(self, node)) return false;
    const e = node.data.extra;
    const extras = self.ast.extra_data.items;
    if (extras[e + 2] == 0) return false;
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

/// An extracted ordinary private function owns this/arguments. Its strict
/// factory preserves those bindings, while opaque eval can still mutate the
/// source immutable class-self alias or inspect an erased private environment.
pub fn unsafePrivateFactoryEval(self: anytype, node: ast_mod.Node, source_scope: ScopeId, class_self_id: u32, parameter_initializer: bool) bool {
    if (!isDirectEvalCall(self, node)) return false;
    const e = node.data.extra;
    if (self.ast.extra_data.items[e + 2] == 0) return false;
    const argument = self.ast.getNode(self.ast.readExtraNode(self.ast.extra_data.items[e + 1], 0));
    if (argument.tag != .string_literal) return true;
    const decoded = @import("../string_escape.zig").decodeJsStringLiteral(self.allocator, self.ast.getText(argument.span)) catch return true;
    defer self.allocator.free(decoded);
    const text = std.mem.trim(u8, decoded, " \t\r\n");
    if (std.mem.eql(u8, text, "this") or std.mem.eql(u8, text, "arguments")) return false;
    if (unsafeEvalCall(self, node, true)) return true;
    if (text.len == 0 or !(std.ascii.isAlphabetic(text[0]) or text[0] == '_' or text[0] == '$')) return false;
    // A bare name is safe only from the original lexical graph, not from the
    // new factory's spelling lookup. Reject lexical TDZ and unknown globals:
    // the factory parameter could otherwise introduce a previously absent name.
    var scope = source_scope;
    while (!scope.isNone() and scope.toIndex() < self.scopes.len) : (scope = self.scopes[scope.toIndex()].parent) {
        if (self.scope_maps[scope.toIndex()].get(text)) |raw_id| {
            if (raw_id == class_self_id) return false;
            if (raw_id >= self.symbols.len) return true;
            return switch (self.symbols[raw_id].kind) {
                .variable_var => false,
                .parameter => parameter_initializer,
                .function_decl => !self.scopes[scope.toIndex()].kind.isVarScope(),
                else => true,
            };
        }
    }
    return true;
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

/// Only the exact tuple published by the identity-changing producer may keep
/// its own generated origin when the generic source visitor returns it.
pub fn validOwnReferenceOrigin(self: anytype, node: NodeIndex) bool {
    const raw = @backingInt(node);
    if (raw < self.parser_node_count or self.reference_origin_map.get(raw) != raw) return false;
    const expected = self.static_class_reference_origins.get(raw) orelse return false;
    const capture = self.static_class_captures.get(@backingInt(expected.class_binding)) orelse
        self.completed_static_class_captures.get(@backingInt(expected.class_binding)) orelse return false;
    if (capture.frame.class_binding != expected.class_binding or
        capture.symbol_id != @backingInt(expected.reference.symbol_id) or
        capture.frame.class_self_symbol_id != expected.source_symbol_id or
        capture.frame.class_symbol_id != expected.class_value_symbol_id) return false;
    if (self.getSymbolIdAt(expected.source) != expected.source_symbol_id) return false;
    if (self.getSymbolIdAt(node) != @backingInt(expected.reference.symbol_id)) return false;
    if (expected.source_symbol_id == @backingInt(expected.reference.symbol_id)) return false;
    const editor = if (self.semantic_editor) |*value| value else return false;
    const actual = (editor.referenceForNode(node) catch return false) orelse return false;
    return actual.node_index == node and !actual.flags.declare and
        actual.symbol_id == expected.reference.symbol_id and
        actual.scope_id == expected.reference.scope_id and
        @as(u8, @bitCast(actual.flags)) == @as(u8, @bitCast(expected.reference.flags)) and
        actual.stmt_idx == expected.reference.stmt_idx and
        actual.scope_stmt_idx == expected.reference.scope_stmt_idx;
}
