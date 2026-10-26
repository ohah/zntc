//! Strict constructor body declarations keep function storage while their
//! values are created at entry to the new lexical body block.
const std = @import("std");
const ast = @import("../parser/ast.zig");
const ScopeId = @import("../semantic/scope.zig").ScopeId;
const helpers = @import("es_helpers.zig");

pub const Plan = struct {
    storage_declarations: ast.NodeList,
    entry_initializers: ast.NodeList,
    remaining_body: ast.NodeList,
};

/// Call after the body scope producer has reparented the original function
/// values to try_scope, and before visiting any of the original statements.
/// The actual simple formal list is supplied explicitly: a function may reuse
/// its parameter's SID, whose original declaration anchor must remain intact.
pub fn prepare(self: anytype, body: ast.NodeIndex, formals: ast.NodeIndex, constructor_scope: ScopeId, try_scope: ScopeId) !Plan {
    if (!self.semantic_edit_enabled) @panic("constructor function cells require the retained semantic graph");
    const node = self.ast.getNode(body);
    if (node.tag != .block_statement or self.outputOwnedScope(body) != try_scope)
        @panic("constructor function cells require the actual lexical body owner");
    const Entry = struct { source: ast.NodeIndex, id: u32, source_name: @import("../lexer/token.zig").Span };
    var entries: std.ArrayList(Entry) = .empty;
    defer entries.deinit(self.allocator);
    var selected: std.AutoHashMapUnmanaged(u32, usize) = .empty;
    defer selected.deinit(self.allocator);
    var formal_ids: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer formal_ids.deinit(self.allocator);
    if (!formals.isNone()) {
        const params = self.ast.getNode(formals);
        if (params.tag != .formal_parameters) @panic("constructor cells require actual simple formals");
        for (0..params.data.list.len) |i| {
            const binding = self.ast.readExtraNode(params.data.list.start, @intCast(i));
            if (self.ast.getNode(binding).tag != .binding_identifier) @panic("constructor cells do not lower non-simple parameters");
            try formal_ids.put(self.allocator, self.getSymbolIdAt(binding) orelse @panic("formal has no exact SID"), {});
        }
    }
    var remaining: std.ArrayList(ast.NodeIndex) = .empty;
    defer remaining.deinit(self.allocator);
    var removed: std.ArrayList(ast.NodeIndex) = .empty;
    defer removed.deinit(self.allocator);
    for (0..node.data.list.len) |i| {
        const statement = self.ast.readExtraNode(node.data.list.start, @intCast(i));
        const declaration = self.ast.getNode(statement);
        if (declaration.tag != .function_declaration or self.ast.readExtraNode(declaration.data.extra, ast.FunctionExtra.body).isNone()) {
            try remaining.append(self.allocator, statement);
            continue;
        }
        const binding = self.ast.readExtraNode(declaration.data.extra, ast.FunctionExtra.name);
        const id = self.getSymbolIdAt(binding) orelse @panic("body function has no exact source SID");
        if (self.semantic_editor.?.symbols.items[id].scope_id != constructor_scope)
            @panic("body function cell does not own constructor storage");
        try removed.append(self.allocator, binding);
        if (selected.get(id)) |index| {
            entries.items[index].source = statement;
        } else {
            const spelling = try self.allocator.dupe(u8, self.ast.getText(self.ast.getNode(binding).data.string_ref));
            defer self.allocator.free(spelling);
            const decoded = try @import("../lexer/scanner.zig").Scanner.decodeIdentifierEscapesAlloc(self.allocator, spelling);
            defer if (decoded.ptr != spelling.ptr) self.allocator.free(decoded);
            const name = try self.ast.addString(decoded);
            try selected.put(self.allocator, id, entries.items.len);
            try entries.append(self.allocator, .{ .source = statement, .id = id, .source_name = name });
        }
    }
    // Freeze the actual anchored-row intersection before mutating any rows.
    var discard_anchors: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer discard_anchors.deinit(self.allocator);
    for (self.semantic_editor.?.references.items) |reference| {
        if (!reference.flags.declare or reference.declaration_node_index.isNone()) continue;
        for (removed.items) |binding| {
            if (reference.declaration_node_index == binding) try discard_anchors.put(self.allocator, @backingInt(binding), {});
        }
    }
    // Remove only discarded declaration nodes, never a shared formal anchor.
    for (removed.items) |binding| {
        const id = self.getSymbolIdAt(binding) orelse @panic("discarded function binding lost its exact SID");
        // Source analysis can merge a declaration into an existing formal or
        // declaration group without recording a row for every name node. Only
        // actual anchored rows have a declaration lifecycle to discard.
        if (discard_anchors.contains(@backingInt(binding))) {
            _ = self.semantic_editor.?.removeDeclarationAtNode(binding, @fromBackingInt(id)) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => std.debug.panic("constructor function declaration discard failed: {s}", .{@errorName(err)}),
            };
        }
        try self.removeSemanticReference(binding);
    }
    var storage: std.ArrayList(ast.NodeIndex) = .empty;
    defer storage.deinit(self.allocator);
    var initializers: std.ArrayList(ast.NodeIndex) = .empty;
    defer initializers.deinit(self.allocator);
    const saved_scope = self.current_scope;
    self.current_scope = try_scope;
    defer self.current_scope = saved_scope;
    for (entries.items) |entry| {
        const source = self.ast.getNode(entry.source);
        const symbol = self.semantic_editor.?.symbols.items[entry.id];
        if (!formal_ids.contains(entry.id)) {
            // Canonical text is separate from diagnostic/source coordinates.
            const text = try self.ast.addString(if (symbol.synthetic_name.len != 0) symbol.synthetic_name else self.ast.getText(symbol.name));
            const binding = try helpers.makeExactSyntheticBindingFromSpan(self, text);
            self.semantic_editor.?.attachVarRedeclaration(binding, @fromBackingInt(entry.id), constructor_scope) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => std.debug.panic("constructor function storage declaration failed: {s}", .{@errorName(err)}),
            };
            // Do not reanchor an existing source var's declaration row.
            const raw = @backingInt(binding);
            if (self.symbol_ids.items.len <= raw) try self.symbol_ids.appendNTimes(self.allocator, null, raw + 1 - self.symbol_ids.items.len);
            self.symbol_ids.items[raw] = entry.id;
            const declarator = try helpers.makeDeclarator(self, binding, .none, source.span);
            try storage.append(self.allocator, try helpers.makeVarDeclaration(self, &.{declarator}, .@"var", source.span));
        }
        // Copy the complete payload (including async/generator flags), removing
        // only the name. Recursion remains a read of the mutable outer cell.
        const extras = try self.allocator.dupe(u32, self.ast.extra_data.items[source.data.extra..][0..5]);
        defer self.allocator.free(extras);
        extras[ast.FunctionExtra.name] = @backingInt(ast.NodeIndex.none);
        const expression = try self.ast.addNode(.{ .tag = .function_expression, .span = source.span, .data = .{ .extra = try self.ast.addExtras(extras) } });
        try self.remapCopiedScopeOwner(entry.source, expression);
        self.runtime_helpers.keep_names = true;
        const callee = try helpers.makeRuntimeHelperRef(self, "__name");
        try @import("native_constructor_guard.zig").recordReference(self, callee, @fromBackingInt(self.getSymbolIdAt(callee) orelse @panic("constructor function name helper has no SID")), try_scope, .{ .read = true });
        const name = try helpers.buildQuotedKeyLiteral(self, entry.source_name);
        const value = try helpers.makeCallExpr(self, callee, &.{ expression, name }, source.span);
        const target = try self.makeSyntheticRefForSymbol(@fromBackingInt(entry.id), try_scope, .{ .write = true });
        self.ast.nodes.items[@backingInt(target)].tag = .assignment_target_identifier;
        try @import("native_constructor_guard.zig").recordReference(self, target, @fromBackingInt(entry.id), try_scope, .{ .write = true });
        try initializers.append(self.allocator, try helpers.makeAssignStmt(self, target, value, source.span, 0));
    }
    return .{
        .storage_declarations = try self.ast.addNodeList(storage.items),
        .entry_initializers = try self.ast.addNodeList(initializers.items),
        .remaining_body = try self.ast.addNodeList(remaining.items),
    };
}

const original_control = "class P{};class D extends P{constructor(f){function f(){return x}function ordinary(){return ordinary}function ordinary(){return x}async function a(){return x}function* g(){yield x}async function* ag(){yield x}let x=7;super();console.log(f(),ordinary(),g().next().value,f.name,ordinary.name,a.name,g.name,ag.name);a().then(console.log);ag().next().then(v=>console.log(v.value));}}new D(1);";

fn runControl(source: []const u8, storage_count: u32, entry_count: u32, remaining_count: u32, expected_anchors: usize) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var scanner = try @import("../lexer/scanner.zig").Scanner.init(allocator, source);
    var parser = @import("../parser/parser.zig").Parser.init(allocator, &scanner);
    parser.configureFromExtension(".cjs");
    const root = try parser.parse();
    var analyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer.init(allocator, &parser.ast);
    analyzer.enable_stmt_info = true;
    analyzer.enable_exact_declaration_anchors = true;
    try analyzer.analyze();
    try std.testing.expectEqual(@as(usize, 0), analyzer.errors.items.len);
    const Transformer = @import("transformer.zig").Transformer;
    var t = try Transformer.init(allocator, &parser.ast, .{});
    try t.initSymbolIds(analyzer.symbol_ids.items);
    t.symbols = analyzer.symbols.items;
    t.references = analyzer.references.items;
    t.scopes = analyzer.scopes.items;
    t.scope_maps = analyzer.scope_maps.items;
    t.scope_owner_map = analyzer.scope_owner_map;
    t.class_self_symbol_map = analyzer.class_self_symbol_map;
    t.node_scope_provenance = analyzer.node_scope_provenance;
    t.unresolved_references = &analyzer.unresolved_references;
    t.semantic_edit_enabled = true;
    var constructor: ast.NodeIndex = .none;
    for (t.ast.nodes.items, 0..) |n, i| if (n.tag == .method_definition) {
        constructor = @fromBackingInt(@as(u32, @intCast(i)));
        break;
    };
    const ctor = t.ast.getNode(constructor);
    const scope: ScopeId = @fromBackingInt(analyzer.scope_owner_map.get(@backingInt(constructor)).?);
    const body = t.ast.readExtraNode(ctor.data.extra, ast.MethodExtra.body);
    const params = t.ast.readExtraNode(ctor.data.extra, ast.MethodExtra.params);
    const formal = t.ast.readExtraNode(t.ast.getNode(params).data.list.start, 0);
    const formal_id = t.getSymbolIdAt(formal).?;
    var source_function_flags: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    for (t.ast.nodes.items, 0..) |n, raw| {
        if (n.tag != .function_declaration) continue;
        const own = analyzer.scope_owner_map.get(@intCast(raw)) orelse continue;
        try source_function_flags.put(allocator, own, t.ast.extra_data.items[n.data.extra + ast.FunctionExtra.flags]);
    }
    var source_formal_anchor = false;
    for (analyzer.references.items) |reference| {
        if (reference.flags.declare and @backingInt(reference.symbol_id) == formal_id and reference.declaration_node_index == formal) source_formal_anchor = true;
    }
    try std.testing.expect(source_formal_anchor);
    var removed_names: std.AutoHashMapUnmanaged(u32, void) = .empty;
    const source_body = t.ast.getNode(body).data.list;
    for (0..source_body.len) |i| {
        const statement = t.ast.getNode(t.ast.readExtraNode(source_body.start, @intCast(i)));
        if (statement.tag != .function_declaration) continue;
        const name = t.ast.readExtraNode(statement.data.extra, ast.FunctionExtra.name);
        try removed_names.put(allocator, @backingInt(name), {});
    }
    const source_references = try allocator.dupe(@import("../semantic/symbol.zig").Reference, analyzer.references.items);
    const source_symbols = try allocator.dupe(@import("../semantic/symbol.zig").Symbol, analyzer.symbols.items);
    if (expected_anchors == 0) {
        // The function-var case has no independent function-name row. Its
        // canonical source var must have a real row which survives unchanged.
        var source_var_anchors: usize = 0;
        for (0..source_body.len) |i| {
            const declaration = t.ast.getNode(t.ast.readExtraNode(source_body.start, @intCast(i)));
            if (declaration.tag != .variable_declaration or t.ast.extra_data.items[declaration.data.extra] != @backingInt(ast.VariableDeclarationKind.@"var")) continue;
            const start = t.ast.extra_data.items[declaration.data.extra + 1];
            const len = t.ast.extra_data.items[declaration.data.extra + 2];
            for (0..len) |j| {
                const declarator = t.ast.getNode(t.ast.readExtraNode(start, @intCast(j)));
                const binding = t.ast.readExtraNode(declarator.data.extra, 0);
                for (source_references) |reference| {
                    if (reference.flags.declare and reference.declaration_node_index == binding) source_var_anchors += 1;
                }
            }
        }
        try std.testing.expect(source_var_anchors > 0);
    }
    var anchored_removed: usize = 0;
    for (source_references) |reference| {
        if (reference.flags.declare and !reference.declaration_node_index.isNone() and removed_names.contains(@backingInt(reference.declaration_node_index))) anchored_removed += 1;
        if (reference.flags.declare and std.mem.indexOf(u8, source, "function read(){return 7}var read=9") != null)
            std.debug.print("function-first source declaration: {any}\n", .{reference});
    }
    try std.testing.expectEqual(expected_anchors, anchored_removed);
    std.debug.print("constructor FDI source names={d} anchored-declarations={d}\n", .{ removed_names.count(), anchored_removed });
    const try_scope = try t.addGeneratedScope(scope, body, .block);
    try @import("transformer/semantic_edit.zig").reparentGeneratedBodyScopes(&t, scope, try_scope, body);
    const before_invalid_removal = t.semantic_editor.?.references.items.len;
    try std.testing.expectError(error.InvalidNode, t.semantic_editor.?.removeDeclarationAtNode(body, @fromBackingInt(formal_id)));
    const wrong_id: u32 = if (formal_id == 0) 1 else 0;
    try std.testing.expectError(error.InvalidSymbol, t.semantic_editor.?.removeDeclarationAtNode(formal, @fromBackingInt(wrong_id)));
    try std.testing.expectEqual(before_invalid_removal, t.semantic_editor.?.references.items.len);
    try std.testing.expectEqual(formal_id, t.semantic_editor.?.symbol_ids.items[@backingInt(formal)].?);
    // A duplicate declaration selection must fail before changing either row.
    var duplicate: ?@import("../semantic/symbol.zig").Reference = null;
    for (t.semantic_editor.?.references.items) |reference| {
        if (reference.flags.declare and reference.declaration_node_index == formal) duplicate = reference;
    }
    try t.semantic_editor.?.references.append(allocator, duplicate.?);
    try std.testing.expectError(error.DuplicateBinding, t.semantic_editor.?.removeDeclarationAtNode(formal, @fromBackingInt(formal_id)));
    try std.testing.expectEqual(before_invalid_removal + 1, t.semantic_editor.?.references.items.len);
    try std.testing.expectEqual(duplicate.?, t.semantic_editor.?.references.items[t.semantic_editor.?.references.items.len - 1]);
    _ = t.semantic_editor.?.references.pop();
    const unanchored = try helpers.makeExactSyntheticBinding(&t, "f");
    const unanchored_raw = @backingInt(unanchored);
    if (t.semantic_editor.?.symbol_ids.items.len <= unanchored_raw)
        try t.semantic_editor.?.symbol_ids.appendNTimes(allocator, null, unanchored_raw + 1 - t.semantic_editor.?.symbol_ids.items.len);
    t.semantic_editor.?.symbol_ids.items[unanchored_raw] = formal_id;
    try std.testing.expectError(error.ReferenceNotFound, t.semantic_editor.?.removeDeclarationAtNode(unanchored, @fromBackingInt(formal_id)));
    try std.testing.expectEqual(formal_id, t.semantic_editor.?.symbol_ids.items[unanchored_raw].?);
    try std.testing.expectEqual(before_invalid_removal, t.semantic_editor.?.references.items.len);
    const plan = try prepare(&t, body, params, scope, try_scope);
    for (t.semantic_editor.?.references.items) |reference| {
        if (reference.flags.declare and !reference.declaration_node_index.isNone())
            try std.testing.expect(!removed_names.contains(@backingInt(reference.declaration_node_index)));
    }
    var matched_rows = try std.DynamicBitSet.initEmpty(allocator, t.semantic_editor.?.references.items.len);
    for (source_references) |previous| {
        if (!previous.flags.declare or previous.declaration_node_index.isNone() or removed_names.contains(@backingInt(previous.declaration_node_index))) continue;
        var found = false;
        for (t.semantic_editor.?.references.items, 0..) |current, index| {
            if (!matched_rows.isSet(index) and std.meta.eql(previous, current)) {
                matched_rows.set(index);
                found = true;
                break;
            }
        }
        try std.testing.expect(found);
    }
    for (source_symbols, t.semantic_editor.?.symbols.items[0..source_symbols.len]) |previous, current| {
        try std.testing.expectEqual(previous.kind, current.kind);
        try std.testing.expectEqual(previous.decl_flags, current.decl_flags);
    }
    for (t.semantic_editor.?.references.items) |reference| {
        if (reference.node_index.isNone()) continue;
        const indexed = (try t.semantic_editor.?.referenceForNode(reference.node_index)).?;
        try std.testing.expectEqual(reference, indexed);
    }
    try std.testing.expectEqual(storage_count, plan.storage_declarations.len);
    try std.testing.expectEqual(entry_count, plan.entry_initializers.len);
    try std.testing.expectEqual(remaining_count, plan.remaining_body.len);
    try std.testing.expectEqual(formal_id, t.getSymbolIdAt(formal).?);
    var formal_anchor = false;
    for (t.semantic_editor.?.references.items) |reference| {
        if (reference.flags.declare and @backingInt(reference.symbol_id) == formal_id and reference.declaration_node_index == formal) formal_anchor = true;
    }
    try std.testing.expect(formal_anchor);
    var values: usize = 0;
    for (t.ast.nodes.items, 0..) |n, i| {
        if (i < t.parser_node_count or n.tag != .function_expression) continue;
        try std.testing.expect(t.ast.readExtraNode(n.data.extra, ast.FunctionExtra.name).isNone());
        const own = t.outputOwnedScope(@fromBackingInt(@as(u32, @intCast(i)))).?;
        try std.testing.expectEqual(try_scope, t.semantic_editor.?.scopes.items[own.toIndex()].parent);
        try std.testing.expectEqual(source_function_flags.get(@backingInt(own)).?, t.ast.extra_data.items[n.data.extra + ast.FunctionExtra.flags]);
        values += 1;
    }
    try std.testing.expectEqual(@as(usize, entry_count), values);
    // Exercise the prepared AST directly, without the constructor bridge or
    // generic output walker. This is a function-cell native comparison only.
    var inner: std.ArrayList(ast.NodeIndex) = .empty;
    for (0..plan.entry_initializers.len) |i| try inner.append(allocator, t.ast.readExtraNode(plan.entry_initializers.start, @intCast(i)));
    for (0..plan.remaining_body.len) |i| try inner.append(allocator, t.ast.readExtraNode(plan.remaining_body.start, @intCast(i)));
    t.ast.nodes.items[@backingInt(body)].data.list = try t.ast.addNodeList(inner.items);
    var outer: std.ArrayList(ast.NodeIndex) = .empty;
    for (0..plan.storage_declarations.len) |i| try outer.append(allocator, t.ast.readExtraNode(plan.storage_declarations.start, @intCast(i)));
    try outer.append(allocator, body);
    const outer_body = try t.ast.addNode(.{ .tag = .block_statement, .span = ctor.span, .data = .{ .list = try t.ast.addNodeList(outer.items) } });
    t.ast.extra_data.items[ctor.data.extra + ast.MethodExtra.body] = @backingInt(outer_body);
    var codegen = @import("../codegen/codegen.zig").Codegen.init(allocator, t.ast);
    const output = try codegen.generate(root);
    const executable = try std.fmt.allocPrint(allocator, "function __name(value,name){{Object.defineProperty(value,'name',{{value:name,configurable:true}});return value;}}\n{s}", .{output});
    const native = try std.process.run(allocator, std.testing.io, .{ .argv = &.{ "node", "-e", source } });
    const actual = try std.process.run(allocator, std.testing.io, .{ .argv = &.{ "node", "-e", executable } });
    try std.testing.expectEqual(@as(u8, 0), native.term.exited);
    try std.testing.expectEqual(@as(u8, 0), actual.term.exited);
    try std.testing.expectEqualStrings(native.stdout, actual.stdout);
}

test "native constructor function cells exact storage and eleven generated AST native controls" {
    const Case = struct { body: []const u8, storage: u32 = 1, entries: u32 = 1, remaining: u32, anchors: usize = 1 };
    try runControl(original_control, 4, 5, 5, 5);
    const cases = [_]Case{
        .{ .body = "super();console.log(read());function read(){return 7}", .remaining = 2 },
        .{ .body = "function f(){return 7}super();console.log(f(),f.name)", .storage = 0, .remaining = 2 },
        .{ .body = "try{read()}catch(e){console.log(e.name)}let x=7;function read(){return x}super();console.log(read())", .remaining = 4 },
        .{ .body = "function read(){return read}const old=read;read=9;super();console.log(old())", .remaining = 4 },
        .{ .body = "console.log(read());function read(){return 1}function read(){return 2}super();", .remaining = 2 },
        .{ .body = "var read=9;function read(){return 7}super();console.log(read)", .remaining = 3, .anchors = 0 },
        .{ .body = "function read(){return 7}var read=9;super();console.log(read)", .remaining = 3 },
        .{ .body = "function \\u0066oo(){return 7}super();console.log(foo.name,foo())", .remaining = 2 },
        .{ .body = "function read(){return 7}super();{function read(){return 9}console.log(read())}console.log(read())", .remaining = 3 },
        .{ .body = "const events=[];function task(){events.push('call')}events.push('before');super();task();console.log(events.join(','))", .remaining = 5 },
    };
    for (cases) |case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const source = try std.fmt.allocPrint(arena.allocator(), "class P{{}};class D extends P{{constructor(f){{{s}}}}}new D(1);", .{case.body});
        try runControl(source, case.storage, case.entries, case.remaining, case.anchors);
    }
}
