//! A body var merged with an actual outer formal is a write to that cell,
//! not a declaration in the generated async body function.
const std = @import("std");
const ast = @import("../parser/ast.zig");
const walk = @import("../parser/ast_walk.zig");
const helpers = @import("es_helpers.zig");
const ScopeId = @import("../semantic/scope.zig").ScopeId;
const NodeIndex = ast.NodeIndex;

fn hasBodyCellDeclaration(self: anytype, body: NodeIndex, source_scope: ScopeId, parameters: *const std.AutoHashMapUnmanaged(u32, void)) !bool {
    var stack: std.ArrayList(NodeIndex) = .empty;
    defer stack.deinit(self.allocator);
    try stack.append(self.allocator, body);
    while (stack.pop()) |index| {
        if (index.isNone()) continue;
        const node = self.ast.getNode(index);
        switch (node.tag) {
            .function_declaration, .function_expression, .function, .arrow_function_expression, .method_definition, .class_declaration, .class_expression => continue,
            .variable_declaration => {
                if (self.ast.variableDeclarationKind(node) != .@"var") continue;
                const start = self.ast.extra_data.items[node.data.extra + 1];
                const count = self.ast.extra_data.items[node.data.extra + 2];
                for (0..count) |i| {
                    const item = self.ast.getNode(@fromBackingInt(self.ast.extra_data.items[start + i]));
                    var bindings = try walk.bindingIdentifiers(self.allocator, self.ast, self.ast.readExtraNode(item.data.extra, 0), .{});
                    defer bindings.deinit();
                    while (try bindings.next()) |binding| {
                        const id = self.getSymbolIdAt(binding) orelse continue;
                        const symbols = if (self.semantic_editor) |*editor| editor.symbols.items else self.symbols;
                        if (id >= symbols.len) @panic("async body declaration has invalid SID");
                        if (symbols[id].scope_id != source_scope) continue;
                        if (parameters.contains(id)) return true;
                        const role = (@import("../semantic/parameter_body_var.zig").forSymbol(symbols, @fromBackingInt(id)) catch @panic("async body declaration has invalid FDI role")) orelse continue;
                        if (parameters.contains(@backingInt(role.parameter))) return true;
                    }
                }
                continue;
            },
            else => {},
        }
        var children = walk.children(self.ast, node);
        while (children.next()) |child| try stack.append(self.allocator, child);
    }
    return false;
}

pub fn normalize(self: anytype, owner: NodeIndex, body: NodeIndex) !void {
    if (!self.semantic_edit_enabled or body.isNone()) return;
    const source_scope = self.originalFunctionScope(owner);
    if (source_scope.isNone()) return;
    const source = self.ast.getNode(owner);
    const params = self.ast.functionParamsList(source);
    const Formal = struct { id: u32, scope: ScopeId, anchored: bool = false };
    var actual_formals: std.AutoHashMapUnmanaged(u32, Formal) = .empty;
    defer actual_formals.deinit(self.allocator);
    for (0..params.len) |i| {
        const parameter: NodeIndex = @fromBackingInt(self.ast.extra_data.items[params.start + i]);
        var bindings = try walk.bindingIdentifiers(self.allocator, self.ast, parameter, .{});
        defer bindings.deinit();
        while (try bindings.next()) |binding| {
            const id = self.getSymbolIdAt(binding) orelse continue;
            const symbols = if (self.semantic_editor) |*editor| editor.symbols.items else self.symbols;
            if (id >= symbols.len) @panic("async formal has an invalid SID");
            const symbol = symbols[id];
            if (symbol.kind != .parameter) continue;
            const ids = if (self.semantic_editor) |*editor| editor.symbol_ids.items else self.symbol_ids.items;
            if (ids[@backingInt(binding)] != id) @panic("async formal SID changed");
            try actual_formals.put(self.allocator, @backingInt(binding), .{ .id = id, .scope = symbol.scope_id });
        }
    }
    if (actual_formals.count() == 0) return;
    // This producer only owns body declarations which share an actual formal
    // cell or carry its exact FDI copy role. Unrelated async bodies retain
    // their existing later binding/anchor producers without opening an Editor.
    var parameters: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer parameters.deinit(self.allocator);
    var candidates = actual_formals.valueIterator();
    while (candidates.next()) |formal| try parameters.put(self.allocator, formal.id, {});
    if (!try hasBodyCellDeclaration(self, body, source_scope, &parameters)) return;
    // Check all physical formal anchors in one pass, before opening or editing
    // a body. The selected node/SID/scope tuple remains the authority.
    const references = if (self.semantic_editor) |*editor| editor.references.items else self.references;
    for (references) |row| {
        if (!row.flags.declare or row.declaration_node_index.isNone()) continue;
        const formal = actual_formals.getPtr(@backingInt(row.declaration_node_index)) orelse continue;
        if (@backingInt(row.symbol_id) != formal.id or row.scope_id != formal.scope) @panic("async formal declaration changed");
        formal.anchored = true;
    }
    var formals: std.AutoHashMapUnmanaged(u32, NodeIndex) = .empty;
    defer formals.deinit(self.allocator);
    var entries = actual_formals.iterator();
    while (entries.next()) |entry| {
        const formal = entry.value_ptr.*;
        if (!formal.anchored) @panic("async formal lost its declaration anchor");
        const binding: NodeIndex = @fromBackingInt(entry.key_ptr.*);
        // One existing, independently checked source row opens the Editor.
        // Later formals are already present in the imported reference array.
        if (self.semantic_editor == null) try self.ensureSymbolDeclarationAtNode(formal.id, formal.scope, binding);
        if (formal.scope == source_scope) try formals.put(self.allocator, formal.id, binding);
    }
    var copies: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer copies.deinit(self.allocator);
    const Work = struct { node: NodeIndex, scope: ScopeId, expression: bool = false, iteration: bool = false, parent: NodeIndex = .none };
    var stack: std.ArrayList(Work) = .empty;
    defer stack.deinit(self.allocator);
    var hoisted: std.ArrayList(NodeIndex) = .empty;
    defer hoisted.deinit(self.allocator);
    try stack.append(self.allocator, .{ .node = body, .scope = source_scope });
    while (stack.pop()) |work| {
        if (work.node.isNone()) continue;
        const node = self.ast.getNode(work.node);
        const scope = self.outputOwnedScope(work.node) orelse work.scope;
        switch (node.tag) {
            .function_declaration, .function_expression, .function, .arrow_function_expression, .method_definition, .class_declaration, .class_expression => continue,
            .variable_declaration => {
                if (self.ast.variableDeclarationKind(node) != .@"var") continue;
                const start = self.ast.extra_data.items[node.data.extra + 1];
                const count = self.ast.extra_data.items[node.data.extra + 2];
                var merged = false;
                var simple = true;
                for (0..count) |i| {
                    const item = self.ast.getNode(@fromBackingInt(self.ast.extra_data.items[start + i]));
                    const binding = self.ast.readExtraNode(item.data.extra, 0);
                    if (self.ast.getNode(binding).tag != .binding_identifier) simple = false;
                    var leaves = try walk.bindingIdentifiers(self.allocator, self.ast, binding, .{});
                    defer leaves.deinit();
                    while (try leaves.next()) |leaf| {
                        if (self.getSymbolIdAt(leaf)) |id| {
                            // Only actual declaration leaves can demand an FDI
                            // copy role; unrelated module symbols are not scanned.
                            if (!formals.contains(id) and !copies.contains(id)) {
                                const symbols = self.semantic_editor.?.symbols.items;
                                if (id >= symbols.len) @panic("async body var has an invalid SID");
                                if (symbols[id].scope_id == source_scope) {
                                    const role = (@import("../semantic/parameter_body_var.zig").forSymbol(symbols, @fromBackingInt(id)) catch @panic("async body var has an invalid initial copy role"));
                                    if (role) |copy| if (parameters.contains(@backingInt(copy.parameter))) try copies.put(self.allocator, id, {});
                                }
                            }
                            merged = merged or formals.contains(id) or copies.contains(id);
                        }
                    }
                }
                if (!merged) continue;
                if (!simple) {
                    // Use the existing pattern producer, which gives every
                    // scalar/temp its actual binding and evaluates the RHS once.
                    if (work.iteration) continue;
                    const saved_scope = self.current_scope;
                    self.current_scope = scope;
                    const flattened = @import("es2015_destructuring.zig").ES2015Destructuring(@TypeOf(self.*)).lowerDestructuringDeclaration(self, node) catch |err| {
                        self.current_scope = saved_scope;
                        return err;
                    };
                    self.current_scope = saved_scope;
                    const flat = self.ast.getNode(flattened);
                    const flat_start = self.ast.extra_data.items[flat.data.extra + 1];
                    const flat_count = self.ast.extra_data.items[flat.data.extra + 2];
                    // Binding visitation can reanchor a merged declaration to
                    // its body copy. Preserve the already-proven outer formal
                    // as the sole declaration of this cell before removing it.
                    for (0..flat_count) |i| {
                        const item = self.ast.getNode(@fromBackingInt(self.ast.extra_data.items[flat_start + i]));
                        const binding = self.ast.readExtraNode(item.data.extra, 0);
                        const id = self.getSymbolIdAt(binding) orelse continue;
                        const formal = formals.get(id) orelse continue;
                        if (binding == formal) continue;
                        const editor = &self.semantic_editor.?;
                        var moved = false;
                        for (editor.references.items) |row| {
                            if (row.flags.declare and row.declaration_node_index == binding) {
                                if (@backingInt(row.symbol_id) != id or row.scope_id != source_scope) @panic("pattern producer changed its merged formal cell");
                                moved = true;
                            }
                        }
                        if (moved) _ = editor.reanchorDeclarationFromNode(self.ast, binding, formal, @fromBackingInt(id)) catch |err| switch (err) {
                            error.OutOfMemory => return error.OutOfMemory,
                            else => @panic("pattern producer cannot restore its actual formal declaration"),
                        };
                    }
                    self.ast.nodes.items[@backingInt(work.node)] = flat;
                    try stack.append(self.allocator, work);
                    continue;
                }
                var expressions: std.ArrayList(NodeIndex) = .empty;
                defer expressions.deinit(self.allocator);
                for (0..count) |i| {
                    const item = self.ast.getNode(@fromBackingInt(self.ast.extra_data.items[start + i]));
                    const binding = self.ast.readExtraNode(item.data.extra, 0);
                    const initializer = self.ast.readExtraNode(item.data.extra, 2);
                    const id = self.getSymbolIdAt(binding) orelse @panic("async var lost its source SID");
                    if (formals.contains(id)) {
                        const editor = &self.semantic_editor.?;
                        if (editor.symbol_ids.items[@backingInt(binding)] != id or editor.symbols.items[id].kind != .parameter or editor.symbols.items[id].scope_id != source_scope)
                            @panic("async merged var changed its formal cell");
                        var anchored = false;
                        for (editor.references.items) |row| {
                            if (!row.flags.declare or row.declaration_node_index != binding) continue;
                            if (@backingInt(row.symbol_id) != id) @panic("async merged declaration changed SID");
                            anchored = true;
                        }
                        if (anchored) _ = editor.removeDeclarationAtNode(binding, @fromBackingInt(id)) catch |err| switch (err) {
                            error.OutOfMemory => return error.OutOfMemory,
                            else => @panic("async merged declaration cannot consume its exact anchor"),
                        };
                    } else {
                        try hoisted.append(self.allocator, try helpers.makeVarDeclaration(self, &.{try helpers.makeDeclarator(self, binding, .none, item.span)}, .@"var", node.span));
                    }
                    if (work.iteration and count != 1) @panic("async iteration var has multiple declarators");
                    if (work.iteration or !initializer.isNone()) {
                        const target = try self.makeIdentifierRefWithSymbol(self.ast.getNode(binding).data.string_ref, binding);
                        try self.trackUserWriteFromBinding(target, binding, scope);
                        try expressions.append(self.allocator, if (work.iteration) target else try helpers.makeAssignExpr(self, target, initializer, item.span, 0));
                    }
                }
                const expression = if (expressions.items.len == 0) try helpers.makeVoidZero(self, node.span) else if (expressions.items.len == 1) expressions.items[0] else try self.ast.addNode(.{ .tag = .sequence_expression, .span = node.span, .data = .{ .list = try self.ast.addNodeList(expressions.items) } });
                const replacement = if (work.expression or work.iteration) expression else try helpers.makeExprStmt(self, expression, node.span);
                if (work.iteration) {
                    // Replace the selected loop edge, keeping the parser-owned
                    // declaration node and its SID array slot untouched.
                    if (work.parent.isNone() or self.ast.getNode(work.parent).data.ternary.a != work.node)
                        @panic("async iteration declaration lost its actual parent edge");
                    self.ast.nodes.items[@backingInt(work.parent)].data.ternary.a = expression;
                } else self.ast.nodes.items[@backingInt(work.node)] = self.ast.getNode(replacement);
                continue;
            },
            else => {},
        }
        var children = walk.children(self.ast, node);
        while (children.next()) |child| {
            const expression = switch (node.tag) {
                .for_statement => child == self.ast.readExtraNode(node.data.extra, 0),
                else => false,
            };
            try stack.append(self.allocator, .{ .node = child, .scope = scope, .parent = work.node, .expression = expression, .iteration = switch (node.tag) {
                .for_in_statement, .for_of_statement, .for_await_of_statement => child == node.data.ternary.a,
                else => false,
            } });
        }
    }
    if (hoisted.items.len != 0) {
        const body_node = self.ast.getNode(body);
        if (body_node.tag != .function_body and body_node.tag != .block_statement) @panic("async body has no statement list");
        const list = body_node.data.list;
        var statements: std.ArrayList(NodeIndex) = .empty;
        defer statements.deinit(self.allocator);
        var prefix: usize = 0;
        while (prefix < list.len) : (prefix += 1) {
            const stmt = self.ast.getNode(@fromBackingInt(self.ast.extra_data.items[list.start + prefix]));
            if (stmt.tag != .directive and (stmt.tag != .expression_statement or self.ast.getNode(stmt.data.unary.operand).tag != .string_literal)) break;
            try statements.append(self.allocator, @fromBackingInt(self.ast.extra_data.items[list.start + prefix]));
        }
        try statements.appendSlice(self.allocator, hoisted.items);
        for (prefix..list.len) |i| try statements.append(self.allocator, @fromBackingInt(self.ast.extra_data.items[list.start + i]));
        self.ast.nodes.items[@backingInt(body)].data.list = try self.ast.addNodeList(statements.items);
    }
}

/// The async producer has assembled this exact inner function/body. Move its
/// direct source rows before any statement-coordinate producer seals them.
pub fn moveBodyReferences(self: anytype, source_owner: NodeIndex, generated_owner: NodeIndex, body: NodeIndex) !void {
    if (!self.semantic_edit_enabled) return;
    const source_scope = self.originalFunctionScope(source_owner);
    const target_scope = self.outputOwnedScope(generated_owner) orelse @panic("async body lost its generated owner");
    const function = self.ast.getNode(generated_owner);
    if (function.tag != .function_expression or self.ast.readExtraNode(function.data.extra, ast.FunctionExtra.body) != body)
        @panic("async body reference handoff has a foreign function edge");
    const Work = struct { node: NodeIndex, scope: ScopeId, parent: NodeIndex = .none };
    var stack: std.ArrayList(Work) = .empty;
    defer stack.deinit(self.allocator);
    try stack.append(self.allocator, .{ .node = body, .scope = target_scope });
    while (stack.pop()) |work| {
        if (work.node.isNone()) continue;
        const node = self.ast.getNode(work.node);
        switch (node.tag) {
            .function_declaration, .function_expression, .arrow_function_expression, .class_declaration, .class_expression => continue,
            else => {},
        }
        var scope = self.outputOwnedScope(work.node) orelse work.scope;
        // Assembly can introduce an actual block before the final binder.
        // Give that owner its scope now, before publishing moved read rows.
        if (node.tag == .block_statement and work.node != body and self.outputOwnedScope(work.node) == null) {
            const function_body = !work.parent.isNone() and switch (self.ast.getNode(work.parent).tag) {
                .function_declaration, .function_expression, .function, .arrow_function_expression, .method_definition => true,
                else => false,
            };
            if (!function_body) scope = try self.addGeneratedScope(work.scope, work.node, .block);
        }
        const editor = &self.semantic_editor.?;
        const row = editor.referenceForNode(work.node) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => @panic("async body reference handoff has invalid source rows"),
        };
        if (row) |source| {
            if (!source.flags.declare and source.scope_id == source_scope and scope != source_scope) {
                if (self.getSymbolIdAt(work.node) != @backingInt(source.symbol_id)) @panic("async body reference changed its exact SID");
                editor.moveReference(work.node, scope, source.stmt_idx, source.scope_stmt_idx) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => @panic("async body reference cannot move from its actual source scope"),
                };
            }
        }
        var children = walk.children(self.ast, node);
        while (children.next()) |child| try stack.append(self.allocator, .{ .node = child, .scope = scope, .parent = work.node });
    }
}
