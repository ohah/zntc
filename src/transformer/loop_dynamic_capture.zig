//! Source-only demand check before loop lexical environments are lowered.
const std = @import("std");
const ast = @import("../parser/ast.zig");
const walk = @import("../parser/ast_walk.zig");
const ScopeId = @import("../semantic/scope.zig").ScopeId;
const Scanner = @import("../lexer/scanner.zig").Scanner;

fn functionFlags(self: anytype, node: ast.Node) u32 {
    return switch (node.tag) {
        .function_declaration, .function_expression => self.ast.readExtra(node.data.extra, ast.FunctionExtra.flags),
        .arrow_function_expression => self.ast.readExtra(node.data.extra, 2) & ast.ArrowFlags.is_async,
        .method_definition => ast.methodFlagsToFunctionFlags(self.ast.readExtra(node.data.extra, 3)),
        else => 0,
    };
}
fn functionStateMachine(self: anytype, node: ast.Node) bool {
    const flags = functionFlags(self, node);
    return self.options.unsupported.generator and
        ((flags & ast.FunctionFlags.is_generator) != 0 or
            ((flags & ast.FunctionFlags.is_async) != 0 and self.options.unsupported.async_await));
}

fn isFunction(tag: ast.Node.Tag) bool {
    return switch (tag) {
        .function_declaration, .function_expression, .arrow_function_expression, .method_definition, .function => true,
        else => false,
    };
}
fn isLoop(tag: ast.Node.Tag) bool {
    return switch (tag) {
        .for_statement, .for_in_statement, .for_of_statement, .for_await_of_statement, .while_statement, .do_while_statement => true,
        else => false,
    };
}

fn symbolName(self: anytype, span: @import("../lexer/token.zig").Span) ?[]const u8 {
    const bit = ast.Ast.STRING_TABLE_BIT;
    if ((span.start & bit) != (span.end & bit)) return null;
    const start = span.start & ~bit;
    const end = span.end & ~bit;
    const backing = if ((span.start & bit) != 0) self.ast.string_table.items else self.ast.source;
    if (start > end or end > backing.len) return null;
    return backing[start..end];
}

const Lookup = union(enum) { found: u32, absent, unproven };
// Initial source lookup only: stale rows never authorize a safe/shadowed result.
fn firstSourceBinding(self: anytype, name: []const u8, start: ScopeId) Lookup {
    if (start.isNone()) return .unproven;
    var scope = start;
    var hops: usize = 0;
    while (!scope.isNone() and hops < self.scopes.len) : (hops += 1) {
        const index = scope.toIndex();
        if (index >= self.scopes.len or index >= self.scope_maps.len) return .unproven;
        if (self.scope_maps[index].get(name)) |id| {
            if (id >= self.symbols.len) return .unproven;
            const symbol = self.symbols[id];
            if (symbol.scope_id != scope) return .unproven;
            const raw = symbolName(self, symbol.name) orelse return .unproven;
            var buffer: [256]u8 = undefined;
            const actual = Scanner.decodeIdentifierEscapesInto(raw, &buffer) orelse raw;
            if (!std.mem.eql(u8, name, actual)) return .unproven;
            return .{ .found = std.math.cast(u32, id) orelse return .unproven };
        }
        scope = self.scopes[index].parent;
    }
    return if (scope.isNone()) .absent else .unproven;
}

const EvalText = struct { value: ?[]const u8 = null, owned: bool = false };
fn evalText(self: anytype, node: ast.Node) !EvalText {
    if (self.ast.readExtra(node.data.extra, 2) == 0) return .{ .value = "" };
    const first = self.ast.getNode(unwrap(self, self.ast.readExtraNode(self.ast.readExtra(node.data.extra, 1), 0)));
    switch (first.tag) {
        // Direct literal values are never ToString-coerced by eval.
        .numeric_literal, .boolean_literal, .null_literal, .bigint_literal, .regexp_literal, .object_expression, .array_expression, .function_expression, .arrow_function_expression, .class_expression => return .{ .value = "" },
        .string_literal, .template_literal => {
            if (first.tag == .template_literal and first.data.list.len != 0) return .{};
            const value = @import("../string_escape.zig").decodeJsStringLiteral(self.allocator, self.ast.getText(first.span)) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return .{},
            };
            return .{ .value = value, .owned = true };
        },
        else => return .{},
    }
}

fn independent(text: []const u8) bool {
    for (text, 0..) |c, index| {
        if (std.mem.indexOfScalar(u8, "0123456789.+-*/%() \t\r\n", c) == null) return false;
        // Preserve the existing strict/sloppy legacy-octal distinction.
        if (c == '0' and index + 1 < text.len and std.ascii.isDigit(text[index + 1]) and
            (index == 0 or (!std.ascii.isDigit(text[index - 1]) and text[index - 1] != '.'))) return false;
    }
    return true;
}

fn unwrap(self: anytype, source: ast.NodeIndex) ast.NodeIndex {
    var index = source;
    while (!index.isNone()) {
        const node = self.ast.getNode(index);
        if (node.tag != .parenthesized_expression and !ast.Node.Tag.isTransparentTypeWrapper(node.tag)) break;
        index = node.data.unary.operand;
    }
    return index;
}

fn noWrites(self: anytype, id: u32) bool {
    for (self.references) |reference| {
        if (@backingInt(reference.symbol_id) == id and reference.flags.write and !reference.flags.declare) return false;
    }
    return true;
}

// Exact source list order, not spans: the initializer statement has completed
// before the call's containing statement, in the same activation/block.
fn initializedBefore(self: anytype, declarator: ast.NodeIndex, call: ast.NodeIndex, parents: []const ast.NodeIndex) bool {
    const declaration = parents[@backingInt(declarator)];
    if (declaration.isNone() or self.ast.getNode(declaration).tag != .variable_declaration) return false;
    const list = parents[@backingInt(declaration)];
    if (list.isNone()) return false;
    const node = self.ast.getNode(list);
    if (node.tag != .block_statement and node.tag != .program) return false;
    var statement = call;
    var hops: usize = 0;
    while (hops < parents.len) : (hops += 1) {
        const parent = parents[@backingInt(statement)];
        if (parent.isNone()) return false;
        if (parent == list) break;
        const tag = self.ast.getNode(parent).tag;
        if (isFunction(tag) or tag == .with_statement or tag == .class_body or tag == .static_block) return false;
        statement = parent;
    }
    if (hops == parents.len or statement == declaration) return false;
    var children = walk.children(self.ast, node);
    var initialized = false;
    while (children.next()) |child| {
        if (child == declaration) initialized = true;
        if (child == statement) return initialized;
    }
    return false;
}

fn knownInitializer(self: anytype, id: u32, call: ast.NodeIndex, parents: []const ast.NodeIndex, require_const: bool) ?ast.NodeIndex {
    if (id >= self.symbols.len or !noWrites(self, id)) return null;
    if (require_const and self.symbols[id].kind != .variable_const) return null;
    var found: ?ast.NodeIndex = null;
    for (self.ast.nodes.items[0..self.parser_node_count], 0..) |node, raw| {
        if (node.tag != .variable_declarator) continue;
        const binding = self.ast.readExtraNode(node.data.extra, 0);
        if (binding.isNone() or self.ast.getNode(binding).tag != .binding_identifier or self.getSymbolIdAt(binding) != id) continue;
        const initializer = self.ast.readExtraNode(node.data.extra, 2);
        if (initializer.isNone() or found != null or !initializedBefore(self, @fromBackingInt(@intCast(raw)), call, parents)) return null;
        found = unwrap(self, initializer);
    }
    return found;
}

fn sourceIdentifierId(self: anytype, index: ast.NodeIndex, scope: ScopeId) ?u32 {
    const node = self.ast.getNode(index);
    if (node.tag != .identifier_reference) return null;
    const id = self.getSymbolIdAt(index) orelse return null;
    const raw = self.ast.identifierNameText(node);
    var buffer: [256]u8 = undefined;
    const name = Scanner.decodeIdentifierEscapesInto(raw, &buffer) orelse raw;
    return switch (firstSourceBinding(self, name, scope)) {
        .found => |actual| if (actual == id) id else null,
        else => null,
    };
}

fn safeKnownValueCall(self: anytype, node: ast.Node, scope: ScopeId, parents: []const ast.NodeIndex) bool {
    // Locate the actual call node from its unique callee parent chain.
    var callee = self.ast.readExtraNode(node.data.extra, 0);
    const call = parents[@backingInt(callee)];
    if (call.isNone() or self.ast.getNode(call).tag != .call_expression) return false;
    callee = unwrap(self, callee);
    if (sourceIdentifierId(self, callee, scope)) |id| {
        var owner = self.symbols[id].scope_id;
        var local_function = false;
        var hops: usize = 0;
        while (!owner.isNone() and hops < self.scopes.len) : (hops += 1) {
            if (owner.toIndex() >= self.scopes.len) break;
            const frame = self.scopes[owner.toIndex()];
            if (frame.kind == .function) {
                // A with getter can invoke the builtin and assign through
                // opaque eval text, escaping the explicit-reference census.
                local_function = !frame.subtree_has_with;
                break;
            }
            owner = frame.parent;
        }
        const kind = self.symbols[id].kind;
        if (local_function and (kind == .variable_let or kind == .variable_const)) if (knownInitializer(self, id, call, parents, false)) |initializer| {
            const tag = self.ast.getNode(initializer).tag;
            if (tag == .function_expression or tag == .arrow_function_expression) return true;
        };
    }
    if (self.ast.readExtra(node.data.extra, 2) == 0) return false;
    const first = unwrap(self, self.ast.readExtraNode(self.ast.readExtra(node.data.extra, 1), 0));
    const id = sourceIdentifierId(self, first, scope) orelse return false;
    const initializer = knownInitializer(self, id, call, parents, true) orelse return false;
    return switch (self.ast.getNode(initializer).tag) {
        .object_expression, .array_expression, .function_expression, .arrow_function_expression, .class_expression, .numeric_literal, .boolean_literal, .null_literal, .bigint_literal, .regexp_literal => true,
        else => false,
    };
}

fn safeImmediateHeaderRead(self: anytype, loop: ast.NodeIndex, eval_call: ast.NodeIndex, id: u32, text: []const u8, parents: []const ast.NodeIndex, allow_escaping: bool) bool {
    var text_buffer: [256]u8 = undefined;
    const cooked = Scanner.decodeIdentifierEscapesInto(text, &text_buffer) orelse return false;
    if (std.mem.eql(u8, cooked, "arguments") or std.mem.eql(u8, cooked, "eval") or
        std.mem.eql(u8, cooked, "this") or std.mem.eql(u8, cooked, "new.target")) return false;
    const symbol = self.symbols[id];
    const raw = symbolName(self, symbol.name) orelse return false;
    var buffer: [256]u8 = undefined;
    const name = Scanner.decodeIdentifierEscapesInto(raw, &buffer) orelse raw;
    if (!std.mem.eql(u8, cooked, name)) return false;
    const loop_node = self.ast.getNode(loop);
    if (loop_node.tag != .for_statement) return false;
    const head = self.ast.readExtraNode(loop_node.data.extra, 0);
    if (head.isNone()) return false;
    const declaration = self.ast.getNode(head);
    if (declaration.tag != .variable_declaration or !self.ast.variableDeclarationKind(declaration).isLexical() or self.ast.readExtra(declaration.data.extra, 2) != 1) return false;
    const declarator = self.ast.readExtraNode(self.ast.readExtra(declaration.data.extra, 1), 0);
    const binding = self.ast.readExtraNode(self.ast.getNode(declarator).data.extra, 0);
    if (self.ast.getNode(binding).tag != .binding_identifier or self.getSymbolIdAt(binding) != id or self.ast.readExtraNode(self.ast.getNode(declarator).data.extra, 2).isNone()) return false;
    var function = parents[@backingInt(eval_call)];
    if (function.isNone()) return false;
    // A direct expression body, or a sole return statement, cannot store an
    // escaping callback or defer the eval beyond this synchronous invocation.
    if (self.ast.getNode(function).tag == .return_statement) {
        const block = parents[@backingInt(function)];
        if (block.isNone() or self.ast.getNode(block).tag != .block_statement or self.ast.getNode(block).data.list.len != 1) return false;
        function = parents[@backingInt(block)];
    }
    if (function.isNone()) return false;
    const fn_node = self.ast.getNode(function);
    if (fn_node.tag != .arrow_function_expression and fn_node.tag != .function_expression) return false;
    const flags = if (fn_node.tag == .arrow_function_expression)
        self.ast.readExtra(fn_node.data.extra, ast.ArrowExtra.flags) & ast.ArrowFlags.is_async
    else
        self.ast.readExtra(fn_node.data.extra, ast.FunctionExtra.flags);
    if ((flags & (ast.FunctionFlags.is_async | ast.FunctionFlags.is_generator)) != 0 or self.ast.functionParamsList(fn_node).len != 0) return false;
    var callee = function;
    var parent = parents[@backingInt(callee)];
    while (!parent.isNone() and self.ast.getNode(parent).tag == .parenthesized_expression) {
        callee = parent;
        parent = parents[@backingInt(parent)];
    }
    const immediate = if (!parent.isNone()) blk: {
        const call = self.ast.getNode(parent);
        break :blk call.tag == .call_expression and self.ast.readExtraNode(call.data.extra, 0) == callee and
            (self.ast.readExtra(call.data.extra, 3) & ast.CallFlags.optional_chain) == 0;
    } else false;
    // Main's ordinary capture producer now extracts direct eval inside an
    // actual closure. Admit only this readonly source role, never opaque code
    // that can mutate a copied parameter or expose generated names.
    if (!immediate and (!allow_escaping or !self.scopes[symbol.scope_id.toIndex()].blocksMangling())) return false;
    const body = self.ast.readExtraNode(loop_node.data.extra, 3);
    var cursor = if (immediate) parent else function;
    var hops: usize = 0;
    while (hops < parents.len) : (hops += 1) {
        if (cursor == body) return true;
        cursor = parents[@backingInt(cursor)];
        if (cursor.isNone()) return false;
        const tag = self.ast.getNode(cursor).tag;
        if (isFunction(tag) or isLoop(tag) or tag == .class_body or tag == .static_block) return false;
    }
    return false;
}

fn checkLoop(self: anytype, loop: ast.NodeIndex, state_machine: bool, scopes: []const ScopeId, parents: []const ast.NodeIndex, allow_escaping: bool) !bool {
    var selected: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer selected.deinit(self.allocator);
    const BindingWork = struct { node: ast.NodeIndex, lexical: bool = false };
    var stack: std.ArrayList(BindingWork) = .empty;
    defer stack.deinit(self.allocator);
    var unknown_binding = false;
    try stack.append(self.allocator, .{ .node = loop });
    while (stack.pop()) |work| {
        const idx = work.node;
        const node = self.ast.getNode(idx);
        if (idx != loop and (isFunction(node.tag) or isLoop(node.tag))) continue;
        if (node.tag == .binding_identifier and work.lexical) {
            if (self.getSymbolIdAt(idx)) |sid| {
                if (sid < self.symbols.len and !self.symbols[sid].scope_id.isNone() and
                    self.symbols[sid].scope_id.toIndex() < self.scopes.len and symbolName(self, self.symbols[sid].name) != null)
                {
                    const symbol = self.symbols[sid];
                    const raw_name = symbolName(self, symbol.name).?;
                    var buffer: [256]u8 = undefined;
                    const name = Scanner.decodeIdentifierEscapesInto(raw_name, &buffer) orelse raw_name;
                    const binding_name = self.ast.identifierNameText(node);
                    if (!Scanner.identifierNamesEqual(binding_name, raw_name)) {
                        unknown_binding = true;
                    } else switch (firstSourceBinding(self, name, symbol.scope_id)) {
                        .found => |actual| {
                            if (actual == sid) try selected.put(self.allocator, sid, {}) else unknown_binding = true;
                        },
                        else => unknown_binding = true,
                    }
                } else unknown_binding = true;
            } else unknown_binding = true;
        }
        if (node.tag == .class_declaration or node.tag == .class_expression) {
            const name = self.ast.readExtraNode(node.data.extra, ast.ClassExtra.name);
            if (node.tag == .class_declaration and !name.isNone()) try stack.append(self.allocator, .{ .node = name, .lexical = true });
            continue;
        }
        if (node.tag == .ts_enum_declaration) {
            // Parser EnumExtra flags: bit0 const, bit1 ambient; only runtime storage
            // while an erased const enum has its own retirement contract.
            if ((self.ast.readExtra(node.data.extra, ast.EnumExtra.flags) & 3) == 0) {
                const name = self.ast.readExtraNode(node.data.extra, ast.EnumExtra.name);
                if (!name.isNone()) try stack.append(self.allocator, .{ .node = name, .lexical = true });
            }
            continue;
        }
        const lexical = if (node.tag == .variable_declaration) self.ast.variableDeclarationKind(node).isLexical() else work.lexical;
        var children = walk.children(self.ast, node);
        while (children.next()) |child| if (!child.isNone()) {
            const catch_binding = state_machine and node.tag == .catch_clause and node.data.binary.left == child;
            try stack.append(self.allocator, .{ .node = child, .lexical = lexical or catch_binding });
        };
    }
    if (selected.count() == 0 and !unknown_binding) return false;
    const reachable = try walk.collectReachableNodeIndicesFrom(self.allocator, self.ast, loop);
    defer self.allocator.free(reachable);
    for (reachable) |raw| {
        const node = self.ast.nodes.items[raw];
        if (!@import("static_class_capture.zig").isDirectEvalCall(self, node)) continue;
        var callee = self.ast.readExtraNode(node.data.extra, 0);
        while (true) {
            const current = self.ast.getNode(callee);
            if (current.tag != .parenthesized_expression and !ast.Node.Tag.isTransparentTypeWrapper(current.tag)) break;
            callee = current.data.unary.operand;
        }
        var scope = scopes[raw];
        if (self.node_scope_provenance.get(callee)) |origin| {
            scope = if (origin.source_external) |external| external.source_scope else origin.scope;
        } else for (self.references) |reference| {
            if (reference.node_index == callee) {
                scope = reference.scope_id;
                break;
            }
        }
        if (safeKnownValueCall(self, node, scope, parents)) continue;
        const text = try evalText(self, node);
        defer if (text.owned) self.allocator.free(text.value.?);
        const trimmed = if (text.value) |known| std.mem.trim(u8, known, " \t\r\n") else null;
        if (trimmed) |known| if (independent(known)) continue;
        if (unknown_binding or scope.isNone() or self.scopes.len == 0 or self.scope_maps.len == 0) {
            self.unsupported_loop_dynamic_scope_span = node.span;
            return true;
        }
        var ids = selected.keyIterator();
        while (ids.next()) |id| {
            const symbol = self.symbols[id.*];
            const raw_name = symbolName(self, symbol.name).?;
            var buffer: [256]u8 = undefined;
            const name = Scanner.decodeIdentifierEscapesInto(raw_name, &buffer) orelse raw_name;
            // A statically known bare identifier can only observe its own first
            // source binding. Opaque source may observe any visible selected SID.
            if (trimmed) |known| {
                var scanner = try Scanner.init(self.allocator, known);
                defer scanner.deinit();
                try scanner.next();
                if (scanner.token.kind == .identifier and scanner.token.span.end == known.len) {
                    var decoded: [256]u8 = undefined;
                    const eval_name = Scanner.decodeIdentifierEscapesInto(known, &decoded) orelse known;
                    if (!std.mem.eql(u8, name, eval_name)) continue;
                }
            }
            switch (firstSourceBinding(self, name, scope)) {
                .found => |actual| if (actual != id.*) continue,
                .absent => continue,
                .unproven => {
                    self.unsupported_loop_dynamic_scope_span = node.span;
                    return true;
                },
            }
            // The selected declaration's exact source owner must be an ancestor.
            var owner = scope;
            var hops: usize = 0;
            while (!owner.isNone() and hops < self.scopes.len) : (hops += 1) {
                if (owner == symbol.scope_id) {
                    if (trimmed) |known| if (safeImmediateHeaderRead(self, loop, @fromBackingInt(@intCast(raw)), id.*, known, parents, allow_escaping)) break;
                    self.unsupported_loop_dynamic_scope_span = node.span;
                    return true;
                }
                if (owner.toIndex() >= self.scopes.len) break;
                owner = self.scopes[owner.toIndex()].parent;
            }
        }
    }
    return false;
}

/// Runs before any source owner/SID is moved. Returning true retains the source
/// root solely so public boundaries can report the precise unsupported demand.
pub fn preflight(self: anytype, root: ast.NodeIndex) !bool {
    if (!self.options.unsupported.block_scoping and !self.options.unsupported.generator) return false;
    if (self.scope_owner_map.get(@backingInt(root))) |owner| {
        if (owner < self.scopes.len and !self.scopes[owner].subtree_has_direct_eval) return false;
    }
    const Work = struct { node: ast.NodeIndex, scope: ScopeId, state_machine: bool, suspending: bool = false };
    const scopes = try self.allocator.alloc(ScopeId, self.ast.nodes.items.len);
    defer self.allocator.free(scopes);
    @memset(scopes, .none);
    const parents = try self.allocator.alloc(ast.NodeIndex, self.ast.nodes.items.len);
    defer self.allocator.free(parents);
    @memset(parents, .none);
    const parent_counts = try self.allocator.alloc(u8, self.ast.nodes.items.len);
    defer self.allocator.free(parent_counts);
    @memset(parent_counts, 0);
    var stack: std.ArrayList(Work) = .empty;
    defer stack.deinit(self.allocator);
    var loops: std.ArrayList(Work) = .empty;
    defer loops.deinit(self.allocator);
    try stack.append(self.allocator, .{ .node = root, .scope = if (self.scopes.len == 0) .none else self.programScope(), .state_machine = false });
    while (stack.pop()) |work| {
        const node = self.ast.getNode(work.node);
        const scope: ScopeId = if (self.scope_owner_map.get(@backingInt(work.node))) |id| @fromBackingInt(id) else work.scope;
        scopes[@backingInt(work.node)] = scope;
        const state_machine = if (node.tag == .static_block) false else if (isFunction(node.tag)) functionStateMachine(self, node) else work.state_machine;
        const suspending = if (node.tag == .static_block) false else if (isFunction(node.tag))
            (functionFlags(self, node) & (ast.FunctionFlags.is_async | ast.FunctionFlags.is_generator)) != 0
        else
            work.suspending;
        if (isLoop(node.tag) and (self.options.unsupported.block_scoping or state_machine)) try loops.append(self.allocator, .{ .node = work.node, .scope = scope, .state_machine = state_machine, .suspending = suspending });
        var children = walk.children(self.ast, node);
        while (children.next()) |child| if (!child.isNone()) {
            const raw = @backingInt(child);
            parent_counts[raw] +|= 1;
            parents[raw] = if (parent_counts[raw] == 1) work.node else .none;
            const outer = @import("transformer/semantic_edit.zig").childSkipsOutputScope(self.ast, @backingInt(work.node), @backingInt(child));
            try stack.append(self.allocator, .{ .node = child, .scope = if (outer) work.scope else scope, .state_machine = if (outer) work.state_machine else state_machine, .suspending = if (outer) work.suspending else suspending });
        };
    }
    for (loops.items) |loop| if (try checkLoop(self, loop.node, loop.state_machine, scopes, parents, self.options.unsupported.block_scoping and !loop.suspending)) return true;
    return false;
}

test "loop dynamic eval missing source identity fails closed without inventing SID" {
    const Transformer = @import("transformer.zig").Transformer;
    const Parser = @import("../parser/parser.zig").Parser;
    for ([_]struct { source: []const u8, rejects: bool }{
        .{ .source = "for(let value=0;value<3;value++){(()=>eval('value'))()}", .rejects = true },
        .{ .source = "for(let value=0;value<3;value++){(()=>eval('40+2'))()}", .rejects = false },
    }) |case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var scanner = try Scanner.init(a, case.source);
        var parser = Parser.init(a, &scanner);
        const root = try parser.parse();
        var t = try Transformer.init(a, &parser.ast, .{ .unsupported = @import("compat.zig").fromESTarget(.es5) });
        try std.testing.expectEqual(case.rejects, try preflight(&t, root));
        try std.testing.expectEqual(case.rejects, t.unsupported_loop_dynamic_scope_span != null);
    }
}

test "loop dynamic eval source lookup rejects stale map rows" {
    const Transformer = @import("transformer.zig").Transformer;
    const Parser = @import("../parser/parser.zig").Parser;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source = "for(let value=0,other=1;value<3;value++){(()=>eval('value'))()}";
    var scanner = try Scanner.init(a, source);
    var parser = Parser.init(a, &scanner);
    const root = try parser.parse();
    var analyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer.init(a, &parser.ast);
    try analyzer.analyze();
    var t = try Transformer.init(a, &parser.ast, .{ .unsupported = @import("compat.zig").fromESTarget(.es5) });
    try t.initSymbolIds(analyzer.symbol_ids.items);
    t.symbols = analyzer.symbols.items;
    t.references = analyzer.references.items;
    t.scopes = analyzer.scopes.items;
    t.scope_maps = analyzer.scope_maps.items;
    t.scope_owner_map = analyzer.scope_owner_map;
    var value_id: ?u32 = null;
    var other_id: ?u32 = null;
    for (analyzer.symbols.items, 0..) |symbol, id| {
        if (std.mem.eql(u8, parser.ast.getText(symbol.name), "value")) value_id = @intCast(id);
        if (std.mem.eql(u8, parser.ast.getText(symbol.name), "other")) other_id = @intCast(id);
    }
    const id = value_id orelse return error.MissingValue;
    const scope = analyzer.symbols.items[id].scope_id;
    try std.testing.expect(firstSourceBinding(&t, "value", scope) == .found);
    try analyzer.scope_maps.items[scope.toIndex()].put(a, "value", std.math.maxInt(u32));
    try std.testing.expect(firstSourceBinding(&t, "value", scope) == .unproven);
    try std.testing.expect(try preflight(&t, root));
    try analyzer.scope_maps.items[scope.toIndex()].put(a, "value", other_id.?);
    try std.testing.expect(firstSourceBinding(&t, "value", scope) == .unproven);
    try std.testing.expect(try preflight(&t, root));
}

test "loop dynamic eval class expression self is not an extracted loop cell" {
    const Transformer = @import("transformer.zig").Transformer;
    const Parser = @import("../parser/parser.zig").Parser;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source = "function* run(){for(let index=0;index<2;index++){yield index;const holder=class Inner{read(){return eval('Inner')===Inner}};new holder().read()}}";
    var scanner = try Scanner.init(a, source);
    var parser = Parser.init(a, &scanner);
    const root = try parser.parse();
    var analyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer.init(a, &parser.ast);
    analyzer.enable_source_external_origins = true;
    analyzer.collect_unresolved_reference_nodes = true;
    try analyzer.analyze();
    var unsupported = @import("compat.zig").fromESTarget(.es2015);
    unsupported.generator = true;
    try std.testing.expect(!unsupported.class and !unsupported.block_scoping);
    var t = try Transformer.init(a, &parser.ast, .{ .unsupported = unsupported });
    try t.initSymbolIds(analyzer.symbol_ids.items);
    t.symbols = analyzer.symbols.items;
    t.references = analyzer.references.items;
    t.scopes = analyzer.scopes.items;
    t.scope_maps = analyzer.scope_maps.items;
    t.scope_owner_map = analyzer.scope_owner_map;
    t.node_scope_provenance = analyzer.node_scope_provenance;
    t.class_self_symbol_map = analyzer.class_self_symbol_map;
    try std.testing.expect(!try preflight(&t, root));
    try std.testing.expect(t.unsupported_loop_dynamic_scope_span == null);
}

test "loop dynamic eval selects runtime enum storage but not erased const enum" {
    const Transformer = @import("transformer.zig").Transformer;
    const Parser = @import("../parser/parser.zig").Parser;
    for ([_]struct { source: []const u8, rejects: bool }{
        .{ .source = "for(var index=0;index<2;index++){enum Entry{Value=42}(()=>eval('Entry.Value'))()}", .rejects = true },
        .{ .source = "for(var index=0;index<2;index++){const enum Entry{Value=42}(()=>eval('Entry.Value'))()}", .rejects = false },
    }) |case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var scanner = try Scanner.init(a, case.source);
        var parser = Parser.init(a, &scanner);
        parser.configureFromExtension(".ts");
        const root = try parser.parse();
        try std.testing.expectEqual(@as(usize, 0), parser.errors.items.len);
        var analyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer.init(a, &parser.ast);
        analyzer.enable_source_external_origins = true;
        analyzer.collect_unresolved_reference_nodes = true;
        try analyzer.analyze();
        var t = try Transformer.init(a, &parser.ast, .{ .unsupported = @import("compat.zig").fromESTarget(.es5) });
        try t.initSymbolIds(analyzer.symbol_ids.items);
        t.symbols = analyzer.symbols.items;
        t.references = analyzer.references.items;
        t.scopes = analyzer.scopes.items;
        t.scope_maps = analyzer.scope_maps.items;
        t.scope_owner_map = analyzer.scope_owner_map;
        t.node_scope_provenance = analyzer.node_scope_provenance;
        try std.testing.expectEqual(case.rejects, try preflight(&t, root));
        try std.testing.expectEqual(case.rejects, t.unsupported_loop_dynamic_scope_span != null);
    }
}
