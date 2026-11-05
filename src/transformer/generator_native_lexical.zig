//! Actual state-producer preconditions for unsupported native lexical storage.
//! These do not predict execution from source offsets or select a SID by name.
const std = @import("std");
const ast = @import("../parser/ast.zig");
const walk = @import("../parser/ast_walk.zig");
const NodeIndex = ast.NodeIndex;
const ScopeId = @import("../semantic/scope.zig").ScopeId;
pub const Reason = enum { across_resume, cell_collision };
pub const Finding = struct {
    reason: Reason,
    span: @import("../lexer/token.zig").Span,
    binding: NodeIndex,
    symbol: u32,
    owner: ScopeId,
    target_owner: ScopeId = .none,
    conflicting_symbol: ?u32 = null,
};
fn enabled(self: anytype) bool {
    return self.semantic_edit_enabled and self.options.unsupported.generator and !self.options.unsupported.block_scoping;
}
fn nativeSource(self: anytype, id: u32) bool {
    if (id >= self.symbols.len) return false;
    return switch (self.symbols[id].kind) {
        .variable_let, .variable_const, .class_decl, .catch_binding => self.symbols[id].synthetic_kind == null,
        else => false,
    };
}
fn exactScopeSpelling(self: anytype, scope: ScopeId, name: []const u8) !?usize {
    const map = &self.semantic_editor.?.scope_maps.items[scope.toIndex()];
    const raw = map.get(name);
    const cooked = try @import("../lexer/scanner.zig").Scanner.decodeIdentifierEscapesAlloc(self.allocator, name);
    defer if (cooked.ptr != name.ptr) self.allocator.free(cooked);
    const decoded = map.get(cooked);
    if (raw != null and decoded != null and raw.? != decoded.?) return null;
    return raw orelse decoded;
}
pub fn storageCollision(self: anytype, binding: NodeIndex, id: u32, target: ScopeId) !?Finding {
    if (!enabled(self) or !nativeSource(self, id) or self.getSymbolIdAt(binding) != id) return null;
    const editor = &self.semantic_editor.?;
    if (target.isNone() or target.toIndex() >= editor.scope_maps.items.len or id >= editor.symbols.items.len) return null;
    const node = self.ast.getNode(binding);
    if (node.tag != .binding_identifier) return null;
    const source = editor.symbols.items[id].scope_id;
    if (source.isNone() or source.toIndex() >= editor.scope_maps.items.len) return null;
    const symbol = editor.symbols.items[id];
    const source_name = if (symbol.synthetic_name.len > 0) symbol.synthetic_name else self.ast.getText(symbol.name);
    if ((try exactScopeSpelling(self, source, source_name)) != @as(?usize, id)) return null;
    const output_name = self.ast.identifierNameText(node);
    const conflicting = (try exactScopeSpelling(self, target, output_name)) orelse return null;
    if (conflicting == id or conflicting >= editor.symbols.items.len or editor.symbols.items[conflicting].scope_id != target) return null;
    const conflicting_id = std.math.cast(u32, conflicting) orelse return null;
    const other = editor.symbols.items[conflicting];
    const other_name = if (other.synthetic_name.len > 0) other.synthetic_name else self.ast.getText(other.name);
    if (!@import("../lexer/scanner.zig").Scanner.identifierNamesEqual(output_name, other_name)) return null;
    var source_declaration = false;
    var target_declaration = false;
    for (editor.references.items) |row| {
        if (row.flags.declare and @backingInt(row.symbol_id) == conflicting and row.scope_id == target and !row.declaration_node_index.isNone()) {
            const anchor = @backingInt(row.declaration_node_index);
            if (anchor < editor.symbol_ids.items.len and editor.symbol_ids.items[anchor] == @as(?u32, conflicting_id) and anchor < self.ast.nodes.items.len and
                self.ast.nodes.items[anchor].tag == .binding_identifier and
                @import("../lexer/scanner.zig").Scanner.identifierNamesEqual(output_name, self.ast.identifierNameText(self.ast.nodes.items[anchor]))) target_declaration = true;
        }
        if (!row.flags.declare or @backingInt(row.symbol_id) != id or row.scope_id != source or row.declaration_node_index.isNone()) continue;
        const raw = @backingInt(row.declaration_node_index);
        if (raw < editor.symbol_ids.items.len and editor.symbol_ids.items[raw] == id) source_declaration = true;
    }
    if (!source_declaration or !target_declaration) return null;
    return .{ .reason = .cell_collision, .span = self.symbols[id].name, .binding = binding, .symbol = id, .owner = source, .target_owner = target, .conflicting_symbol = conflicting_id };
}
fn function(tag: ast.Node.Tag) bool {
    return switch (tag) {
        .function_declaration, .function_expression, .function, .arrow_function_expression, .method_definition => true,
        else => false,
    };
}
/// Class declarations retained directly in different generated state cases are
/// distinct callback activations. A source span comparison cannot prove this.
pub fn classCases(self: anytype, root: NodeIndex) !?Finding {
    if (!enabled(self) or self.options.unsupported.class) return null;
    const Work = struct { node: NodeIndex, state_case: NodeIndex = .none, nested_function: bool = false };
    const Init = struct { binding: NodeIndex, state_case: NodeIndex };
    const Use = struct { node: NodeIndex, id: u32, state_case: NodeIndex };
    var initializers: std.AutoHashMapUnmanaged(u32, Init) = .empty;
    defer initializers.deinit(self.allocator);
    var uses: std.ArrayList(Use) = .empty;
    defer uses.deinit(self.allocator);
    var stack: std.ArrayList(Work) = .empty;
    defer stack.deinit(self.allocator);
    try stack.append(self.allocator, .{ .node = root });
    while (stack.pop()) |work| {
        if (work.node.isNone()) continue;
        const node = self.ast.getNode(work.node);
        const state_case = if (node.tag == .switch_case and work.state_case.isNone()) work.node else work.state_case;
        if (!work.nested_function and node.tag == .class_declaration) {
            const binding = self.ast.readExtraNode(node.data.extra, ast.ClassExtra.name);
            if (self.getSymbolIdAt(binding)) |id| if (nativeSource(self, id) and self.symbols[id].kind == .class_decl)
                try initializers.put(self.allocator, id, .{ .binding = binding, .state_case = state_case });
        }
        if (node.tag == .identifier_reference or node.tag == .assignment_target_identifier) {
            if (self.getSymbolIdAt(work.node)) |id|
                try uses.append(self.allocator, .{ .node = work.node, .id = id, .state_case = state_case });
        }
        var children = walk.children(self.ast, node);
        while (children.next()) |child| try stack.append(self.allocator, .{ .node = child, .state_case = state_case, .nested_function = work.nested_function or function(node.tag) });
    }
    if (initializers.count() == 0) return null;
    // Index only the selected class identities once. A per-leaf full-reference
    // scan would make large suspension-free callback bodies quadratic.
    var active: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer active.deinit(self.allocator);
    const references = if (self.semantic_editor) |*editor| editor.references.items else self.references;
    for (references) |row| {
        const id = @backingInt(row.symbol_id);
        if (!initializers.contains(id) or row.node_index.isNone() or row.flags.declare or (!row.flags.read and !row.flags.write)) continue;
        const entry = try active.getOrPut(self.allocator, @backingInt(row.node_index));
        if (entry.found_existing) return null; // Duplicate/foreign rows remain an exact-graph error.
        entry.value_ptr.* = id;
    }
    for (uses.items) |use| {
        const init = initializers.get(use.id) orelse continue;
        if (active.get(@backingInt(use.node)) != @as(?u32, use.id)) continue;
        if (init.state_case.isNone() or use.state_case.isNone() or init.state_case == use.state_case) continue;
        return .{ .reason = .across_resume, .span = self.symbols[use.id].name, .binding = init.binding, .symbol = use.id, .owner = self.symbols[use.id].scope_id };
    }
    return null;
}
/// The retained declaration still executes as a native class in one callback
/// case. Publish its outer cell in that actual switch lexical environment;
/// the class's immutable inner self and source origin remain untouched.
pub fn publishSameCaseClasses(self: anytype, root: NodeIndex, target: ScopeId) !void {
    if (!enabled(self) or self.options.unsupported.class) return;
    const editor = &self.semantic_editor.?;
    if (self.ast.getNode(root).tag != .switch_statement or self.outputOwnedScope(root) != target or
        target.isNone() or target.toIndex() >= editor.scopes.items.len or editor.scopes.items[target.toIndex()].kind != .switch_block)
        @panic("retained class has no actual state switch owner");
    const Work = struct { node: NodeIndex, scope: ScopeId, nested_function: bool = false };
    var stack: std.ArrayList(Work) = .empty;
    defer stack.deinit(self.allocator);
    var selected: std.AutoHashMapUnmanaged(u32, NodeIndex) = .empty;
    defer selected.deinit(self.allocator);
    try stack.append(self.allocator, .{ .node = root, .scope = target });
    while (stack.pop()) |work| {
        if (work.node.isNone()) continue;
        const node = self.ast.getNode(work.node);
        const scope = self.outputOwnedScope(work.node) orelse work.scope;
        // A class owns its inner environment, but its declaration name belongs
        // to the containing lexical scope. Retained nested blocks keep theirs.
        if (!work.nested_function and node.tag == .class_declaration and work.scope == target) {
            const binding = self.ast.readExtraNode(node.data.extra, ast.ClassExtra.name);
            const id = self.getSymbolIdAt(binding) orelse @panic("retained class declaration lost its outer SID");
            if (!nativeSource(self, id) or self.symbols[id].kind != .class_decl or id >= editor.symbols.items.len or
                editor.symbols.items[id].kind != .class_decl or self.ast.getNode(binding).tag != .binding_identifier)
                @panic("retained class declaration changed its source role");
            const raw = @backingInt(work.node);
            const origin = self.scope_owner_origins.get(raw) orelse if (raw < self.parser_node_count) raw else @panic("retained class has no exact source owner");
            const inner = self.class_self_symbol_map.get(raw) orelse blk: {
                // Ordinary class copies keep the canonical source self entry.
                // The remap producer must independently connect this output
                // node, its declaration identity and the same class scope.
                if (self.scope_owner_remaps.get(origin) != @as(?u32, raw)) @panic("retained class copy lost its exact owner edge");
                const source = self.ast.getNode(@fromBackingInt(origin));
                if (source.tag != .class_declaration or self.getSymbolIdAt(self.ast.readExtraNode(source.data.extra, ast.ClassExtra.name)) != id or
                    self.outputOwnedScope(@fromBackingInt(origin)) != self.outputOwnedScope(work.node))
                    @panic("retained class copy changed its source declaration");
                break :blk self.class_self_symbol_map.get(origin) orelse @panic("retained source class has no inner self producer");
            };
            const class_scope = self.outputOwnedScope(work.node) orelse @panic("retained class has no actual class environment");
            if (inner == id or inner >= editor.symbols.items.len or editor.symbols.items[inner].scope_id != class_scope or
                class_scope.toIndex() >= editor.scopes.items.len or editor.scopes.items[class_scope.toIndex()].kind != .class_body)
                @panic("retained class inner self changed identity");
            const entry = try selected.getOrPut(self.allocator, id);
            if (entry.found_existing and entry.value_ptr.* != binding) @panic("retained class has multiple output declarations");
            entry.value_ptr.* = binding;
        }
        var children = walk.children(self.ast, node);
        while (children.next()) |child| {
            const outer = @import("transformer/semantic_edit.zig").childSkipsOutputScope(self.ast, @backingInt(work.node), @backingInt(child));
            try stack.append(self.allocator, .{ .node = child, .scope = if (outer) work.scope else scope, .nested_function = work.nested_function or function(node.tag) });
        }
    }
    if (selected.count() == 0) return;
    const Declaration = struct { binding: NodeIndex, scope: ScopeId, count: usize };
    var anchors: std.AutoHashMapUnmanaged(u32, Declaration) = .empty;
    defer anchors.deinit(self.allocator);
    for (editor.references.items) |row| {
        const id = @backingInt(row.symbol_id);
        if (!row.flags.declare or !selected.contains(id)) continue;
        const entry = try anchors.getOrPut(self.allocator, id);
        if (entry.found_existing) entry.value_ptr.count += 1 else entry.value_ptr.* = .{ .binding = row.declaration_node_index, .scope = row.scope_id, .count = 1 };
    }
    var declarations = selected.iterator();
    while (declarations.next()) |entry| {
        const id = entry.key_ptr.*;
        const binding = entry.value_ptr.*;
        const declaration = anchors.get(id) orelse @panic("retained class declaration has no source anchor");
        if (declaration.count != 1 or declaration.binding != binding or declaration.scope != editor.symbols.items[id].scope_id)
            @panic("retained class outer declaration has a foreign or duplicate anchor");
        if (try storageCollision(self, binding, id, target)) |finding| {
            self.unsupported_generator_native_lexical = finding;
            return;
        }
        editor.moveSymbolToScope(@fromBackingInt(id), target) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            std.debug.panic("retained class outer cell publication failed: {s}", .{@errorName(err)});
        };
    }
}

pub fn invisibleClass(self: anytype, read: NodeIndex, target: ScopeId) ?Finding {
    if (!enabled(self) or self.options.unsupported.class) return null;
    const id = self.getSymbolIdAt(read) orelse return null;
    if (!nativeSource(self, id) or self.symbols[id].kind != .class_decl) return null;
    const editor = &self.semantic_editor.?;
    if (id >= editor.symbols.items.len) return null;
    const owner = editor.symbols.items[id].scope_id;
    var cursor = target;
    var hops: usize = 0;
    while (!cursor.isNone() and cursor.toIndex() < editor.scopes.items.len and hops < editor.scopes.items.len) : (hops += 1) {
        if (cursor == owner) return null;
        cursor = editor.scopes.items[cursor.toIndex()].parent;
    }
    for (editor.references.items) |row| {
        if (row.flags.declare and @backingInt(row.symbol_id) == id and !row.declaration_node_index.isNone())
            return .{ .reason = .across_resume, .span = self.symbols[id].name, .binding = row.declaration_node_index, .symbol = id, .owner = owner, .target_owner = target };
    }
    return null;
}

test "native lexical state machine class check uses actual state cases and excludes nested function declarations" {
    const Case = struct { source: []const u8, rejected: bool };
    const cases = [_]Case{
        .{ .source = "function f(s){switch(s){case 0:class C{}return 4;case 1:use(C)}}", .rejected = true },
        .{ .source = "function f(s){switch(s){case 0:class C{}if(flag){return 4}else{use(C)}}}", .rejected = false },
        .{ .source = "function f(s){switch(s){case 0:function sibling(){class C{}return C}return 4;case 1:use(sibling)}}", .rejected = false },
        .{ .source = "function f(s){switch(s){case 0:class C{}use(C);return 4;case 1:use(42)}}", .rejected = false },
    };
    for (cases) |case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var scanner = try @import("../lexer/scanner.zig").Scanner.init(a, case.source);
        var parser = @import("../parser/parser.zig").Parser.init(a, &scanner);
        _ = try parser.parse();
        try std.testing.expectEqual(@as(usize, 0), parser.errors.items.len);
        var analyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer.init(a, &parser.ast);
        try analyzer.analyze();
        var t = try @import("transformer.zig").Transformer.init(a, &parser.ast, .{});
        try t.initSymbolIds(analyzer.symbol_ids.items);
        t.symbols = analyzer.symbols.items;
        t.references = analyzer.references.items;
        t.semantic_edit_enabled = true;
        t.options.unsupported.generator = true;
        var root: NodeIndex = .none;
        for (parser.ast.nodes.items, 0..) |node, raw| if (node.tag == .switch_statement) {
            root = @fromBackingInt(@intCast(raw));
            break;
        };
        const finding = try classCases(&t, root);
        try std.testing.expectEqual(case.rejected, finding != null);
        if (finding) |actual| try std.testing.expectEqual(@as(?u32, actual.symbol), t.getSymbolIdAt(actual.binding));
    }
}

test "native lexical state machine storage rejection requires exact competing target SID" {
    const sources = [_][]const u8{
        "let cell=1;let other=3;{let cell=2;use(cell)}",
        "let \\u0063ell=1;let other=3;{let cell=2;use(cell)}",
        "let cell=1;let other=3;{let \\u0063ell=2;use(cell)}",
        "let \\u0063ell=1;let other=3;{let \\u0063ell=2;use(cell)}",
    };
    for (sources) |source| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var scanner = try @import("../lexer/scanner.zig").Scanner.init(a, source);
        var parser = @import("../parser/parser.zig").Parser.init(a, &scanner);
        _ = try parser.parse();
        var analyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer.init(a, &parser.ast);
        analyzer.enable_exact_declaration_anchors = true;
        try analyzer.analyze();
        var t = try @import("transformer.zig").Transformer.init(a, &parser.ast, .{});
        try t.initSymbolIds(analyzer.symbol_ids.items);
        t.symbols = analyzer.symbols.items;
        t.scopes = analyzer.scopes.items;
        t.scope_maps = analyzer.scope_maps.items;
        t.scope_owner_map = analyzer.scope_owner_map;
        t.references = analyzer.references.items;
        t.semantic_edit_enabled = true;
        t.current_scope = @fromBackingInt(0);
        t.options.unsupported.generator = true;
        var bindings: std.ArrayList(NodeIndex) = .empty;
        for (parser.ast.nodes.items, 0..) |node, raw| if (node.tag == .binding_identifier) try bindings.append(a, @fromBackingInt(@intCast(raw)));
        try std.testing.expectEqual(@as(usize, 3), bindings.items.len);
        const outer = t.getSymbolIdAt(bindings.items[0]).?;
        const inner = t.getSymbolIdAt(bindings.items[2]).?;
        try std.testing.expect(outer != inner);
        const source_scope = analyzer.symbols.items[inner].scope_id;
        try t.ensureSymbolDeclarationAtNode(inner, source_scope, bindings.items[2]);
        const finding = (try storageCollision(&t, bindings.items[2], inner, @fromBackingInt(0))) orelse return error.MissingActualStorageCollision;
        try std.testing.expectEqual(@as(?u32, outer), finding.conflicting_symbol);
        try std.testing.expectEqual(source_scope, finding.owner);
        try std.testing.expect((try storageCollision(&t, bindings.items[2], inner, source_scope)) == null);
        try std.testing.expect((try storageCollision(&t, bindings.items[2], outer, @fromBackingInt(0))) == null);
        const foreign = t.getSymbolIdAt(bindings.items[1]).?;
        const editor = &t.semantic_editor.?;
        try editor.scope_maps.items[0].put(a, "cell", foreign);
        try std.testing.expect((try storageCollision(&t, bindings.items[2], inner, @fromBackingInt(0))) == null);
        try editor.scope_maps.items[0].put(a, "cell", outer);
        var target_row: ?usize = null;
        for (editor.references.items, 0..) |row, index| if (row.flags.declare and @backingInt(row.symbol_id) == outer) {
            target_row = index;
        };
        const row_index = target_row orelse return error.MissingTargetDeclaration;
        const anchor = editor.references.items[row_index].declaration_node_index;
        editor.references.items[row_index].declaration_node_index = .none;
        try std.testing.expect((try storageCollision(&t, bindings.items[2], inner, @fromBackingInt(0))) == null);
        editor.references.items[row_index].declaration_node_index = anchor;
        try std.testing.expect(t.unsupported_generator_native_lexical == null);
        t.options.unsupported.block_scoping = true;
        try std.testing.expect((try storageCollision(&t, bindings.items[2], inner, @fromBackingInt(0))) == null);
    }
}

test "native lexical state machine same-case class publication preserves inner self and source origin" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var scanner = try @import("../lexer/scanner.zig").Scanner.init(a, "{class Cell{}};");
    var parser = @import("../parser/parser.zig").Parser.init(a, &scanner);
    _ = try parser.parse();
    var analyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer.init(a, &parser.ast);
    analyzer.enable_exact_declaration_anchors = true;
    try analyzer.analyze();
    var class: NodeIndex = .none;
    for (parser.ast.nodes.items, 0..) |node, raw| if (node.tag == .class_declaration) {
        class = @fromBackingInt(@intCast(raw));
        break;
    };
    const binding = parser.ast.readExtraNode(parser.ast.getNode(class).data.extra, ast.ClassExtra.name);
    const id = analyzer.symbol_ids.items[@backingInt(binding)].?;
    const inner = analyzer.class_self_symbol_map.get(@backingInt(class)).?;
    const original = analyzer.symbols.items[id];
    const original_inner = analyzer.symbols.items[inner];
    var t = try @import("transformer.zig").Transformer.init(a, &parser.ast, .{});
    try t.initSymbolIds(analyzer.symbol_ids.items);
    t.symbols = analyzer.symbols.items;
    t.scopes = analyzer.scopes.items;
    t.scope_maps = analyzer.scope_maps.items;
    t.scope_owner_map = analyzer.scope_owner_map;
    t.references = analyzer.references.items;
    t.class_self_symbol_map = analyzer.class_self_symbol_map;
    t.semantic_edit_enabled = true;
    t.current_scope = @fromBackingInt(0);
    t.options.unsupported.generator = true;
    const source_class = class;
    class = try t.ast.addNode(t.ast.getNode(source_class));
    try t.remapCopiedScopeOwner(source_class, class);
    try std.testing.expect(t.class_self_symbol_map.get(@backingInt(class)) == null);
    const statements = try t.ast.addNodeList(&.{class});
    const case_extra = try t.ast.addExtras(&.{ @backingInt(NodeIndex.none), statements.start, statements.len });
    const case_node = try t.ast.addNode(.{ .tag = .switch_case, .span = .EMPTY, .data = .{ .extra = case_extra } });
    const cases = try t.ast.addNodeList(&.{case_node});
    const switch_extra = try t.ast.addExtras(&.{ @backingInt(NodeIndex.none), cases.start, cases.len });
    const output = try t.ast.addNode(.{ .tag = .switch_statement, .span = .EMPTY, .data = .{ .extra = switch_extra } });
    const target = try t.addGeneratedScope(@fromBackingInt(0), output, .switch_block);
    try publishSameCaseClasses(&t, output, target);
    const editor = &t.semantic_editor.?;
    try std.testing.expectEqual(target, editor.symbols.items[id].scope_id);
    try std.testing.expectEqual(original.origin_scope, editor.symbols.items[id].origin_scope);
    try std.testing.expectEqual(original.kind, editor.symbols.items[id].kind);
    try std.testing.expectEqual(original_inner.scope_id, editor.symbols.items[inner].scope_id);
    try std.testing.expectEqual(original_inner.origin_scope, editor.symbols.items[inner].origin_scope);
    try std.testing.expectEqual(@as(?u32, inner), t.class_self_symbol_map.get(@backingInt(source_class)));
    try std.testing.expectEqual(@as(?u32, @backingInt(source_class)), t.scope_owner_origins.get(@backingInt(class)));
    var rows: usize = 0;
    for (editor.references.items) |row| if (row.flags.declare and @backingInt(row.symbol_id) == id) {
        try std.testing.expectEqual(binding, row.declaration_node_index);
        try std.testing.expectEqual(target, row.scope_id);
        rows += 1;
    };
    try std.testing.expectEqual(@as(usize, 1), rows);
}

test "native lexical state machine class publication preserves retained independent block scopes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var scanner = try @import("../lexer/scanner.zig").Scanner.init(a, "{class Cell{}}{class Cell{}}");
    var parser = @import("../parser/parser.zig").Parser.init(a, &scanner);
    const source_root = try parser.parse();
    var analyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer.init(a, &parser.ast);
    analyzer.enable_exact_declaration_anchors = true;
    try analyzer.analyze();
    var t = try @import("transformer.zig").Transformer.init(a, &parser.ast, .{});
    try t.initSymbolIds(analyzer.symbol_ids.items);
    t.symbols = analyzer.symbols.items;
    t.scopes = analyzer.scopes.items;
    t.scope_maps = analyzer.scope_maps.items;
    t.scope_owner_map = analyzer.scope_owner_map;
    t.references = analyzer.references.items;
    t.class_self_symbol_map = analyzer.class_self_symbol_map;
    t.semantic_edit_enabled = true;
    t.current_scope = @fromBackingInt(0);
    t.options.unsupported.generator = true;
    const statements = t.ast.getNode(source_root).data.list;
    const case_extra = try t.ast.addExtras(&.{ @backingInt(NodeIndex.none), statements.start, statements.len });
    const case_node = try t.ast.addNode(.{ .tag = .switch_case, .span = .EMPTY, .data = .{ .extra = case_extra } });
    const cases = try t.ast.addNodeList(&.{case_node});
    const switch_extra = try t.ast.addExtras(&.{ @backingInt(NodeIndex.none), cases.start, cases.len });
    const output = try t.ast.addNode(.{ .tag = .switch_statement, .span = .EMPTY, .data = .{ .extra = switch_extra } });
    const target = try t.addGeneratedScope(@fromBackingInt(0), output, .switch_block);
    try t.reparentGeneratedBodyScopes(@fromBackingInt(0), target, output);
    try publishSameCaseClasses(&t, output, target);
    const editor = &t.semantic_editor.?;
    for (analyzer.symbols.items, 0..) |original, id| {
        try std.testing.expectEqual(original.scope_id, editor.symbols.items[id].scope_id);
        try std.testing.expectEqual(original.origin_scope, editor.symbols.items[id].origin_scope);
    }
    try std.testing.expectEqual(@as(u16, 0), editor.scopes.items[target.toIndex()].symbol_count);
    try std.testing.expect(t.unsupported_generator_native_lexical == null);
}
