//! Producer-owned module initialization state, independent of publication names.
const std = @import("std");
const ast = @import("../parser/ast.zig");
const helpers = @import("es_helpers.zig");
const NodeIndex = ast.NodeIndex;
const SymbolId = @import("../semantic/symbol.zig").SymbolId;

// TS `export = Foo` publishes a CommonJS value snapshot. Its analyzer export
// bit does not create a live ESM binding. On that source-only path inspect the
// actual ESM declarations/specifiers, preserving any genuinely mixed live edge.
fn hasLiveEsmExport(self: anytype, sid: u32) !bool {
    if (!self.ast.has_ts_export_equals) return true;
    const root = self.ast.getNode(@fromBackingInt(self.parser_node_count - 1));
    if (root.tag != .program) @panic("module initialization lost its exact source export layout");
    for (0..root.data.list.len) |offset| {
        const index = self.ast.readExtraNode(root.data.list.start, @intCast(offset));
        const statement = self.ast.getNode(index);
        var declaration: NodeIndex = .none;
        if (statement.tag == .export_default_declaration) {
            if (self.getSymbolIdAt(index) == sid) return true;
            declaration = statement.data.unary.operand;
        } else if (statement.tag == .export_named_declaration) {
            if (!self.ast.hasExtra(statement.data.extra, 4)) @panic("module initialization lost its exact source export layout");
            declaration = self.ast.readExtraNode(statement.data.extra, 0);
            if (self.ast.readExtraNode(statement.data.extra, 3).isNone()) {
                const start = self.ast.readExtra(statement.data.extra, 1);
                const length = self.ast.readExtra(statement.data.extra, 2);
                for (0..length) |slot| {
                    const specifier = self.ast.getNode(self.ast.readExtraNode(start, @intCast(slot)));
                    if (specifier.tag == .export_specifier and self.getSymbolIdAt(specifier.data.binary.left) == sid) return true;
                }
            }
        } else continue;
        if (declaration.isNone()) continue;
        const child = self.ast.getNode(declaration);
        if (child.tag == .class_declaration or child.tag == .function_declaration) {
            const name = self.ast.readExtraNode(child.data.extra, 0);
            if (!name.isNone() and self.getSymbolIdAt(name) == sid) return true;
        } else if (child.tag == .variable_declaration) {
            const start = self.ast.readExtra(child.data.extra, 1);
            const length = self.ast.readExtra(child.data.extra, 2);
            for (0..length) |slot| {
                const item = self.ast.getNode(self.ast.readExtraNode(start, @intCast(slot)));
                const binding = self.ast.readExtraNode(item.data.extra, 0);
                var leaves = try @import("../parser/ast_walk.zig").bindingIdentifiers(self.allocator, self.ast, binding, .{});
                defer leaves.deinit();
                while (try leaves.next()) |leaf| if (self.getSymbolIdAt(leaf) == sid) return true;
            }
        }
    }
    return false;
}

pub fn prepare(self: anytype, binding: NodeIndex) !?NodeIndex {
    if (!self.options.emit_runtime_helper_imports or !self.options.unsupported.block_scoping) return null;
    const sid = self.getSymbolIdAt(binding) orelse return null;
    const symbols = if (self.semantic_editor) |*value| value.symbols.items else self.symbols;
    if (sid >= symbols.len) @panic("module initialization source lost its SymbolId");
    const source = symbols[sid];
    if (source.scope_id != self.programScope() or !source.isExported()) return null;
    if (!try hasLiveEsmExport(self, sid)) return null;
    if (source.kind != .variable_let and source.kind != .variable_const and source.kind != .class_decl) return null;
    if (source.lexical_initialization.state != .native or !source.lexical_initialization.flag.isNone())
        @panic("module initialization source was prepared twice");
    const name = try helpers.makeTempVarSpan(self);
    const flag_binding = try helpers.makeExactSyntheticBindingFromSpan(self, name);
    const flag = (try self.declareSyntheticInScope(flag_binding, self.ast.getNode(binding).span, .variable_var, source.scope_id)) orelse
        @panic("module initialization flag has no direct SymbolId");
    helpers.markScopedLateSyntheticSymbol(self, flag, source.scope_id, .lexical_initialization_flag, "__initialized");
    // The exact producer creates the editor through declareSynthetic when no
    // prior local TDZ demand needed it. Do not require an unrelated edit.
    const editor = if (self.semantic_editor) |*value| value else @panic("module initialization flag lost its created editor");
    // declareSynthetic may grow the symbol array. Reacquire both rows now.
    editor.symbols.items[@backingInt(flag)].synthetic_owner_id = @as(SymbolId, @fromBackingInt(sid));
    editor.symbols.items[sid].lexical_initialization = .{ .state = .lowered_module, .flag = flag };
    editor.symbols.items[sid].binding_instantiation.lexical_initialization = true;
    editor.symbols.items[sid].const_kind = .none;
    return flag_binding;
}

/// Class declarations are not variable-declaration leaves. Select only their
/// actual source name node; source export flags and owner prove admission.
pub fn prepareClasses(self: anytype, plan: anytype) !void {
    if (!self.options.unsupported.class) return;
    const root: NodeIndex = @fromBackingInt(self.parser_node_count - 1);
    const program = self.ast.getNode(root);
    if (program.tag != .program) return;
    for (0..program.data.list.len) |offset| {
        var statement = self.ast.getNode(self.ast.readExtraNode(program.data.list.start, @intCast(offset)));
        if (statement.tag == .export_named_declaration) {
            const child = self.ast.readExtraNode(statement.data.extra, 0);
            if (child.isNone()) continue;
            statement = self.ast.getNode(child);
        } else if (statement.tag == .export_default_declaration) {
            statement = self.ast.getNode(statement.data.unary.operand);
        }
        if (statement.tag != .class_declaration) continue;
        const binding = self.ast.readExtraNode(statement.data.extra, 0);
        if (binding.isNone()) continue;
        const source = self.getSymbolIdAt(binding) orelse continue;
        if (try prepare(self, binding)) |flag| {
            try plan.module_flags.put(plan.arena.allocator(), source, flag);
            self.runtime_helpers.tdz = true;
        }
    }
}

/// Default expression/anonymous declaration facades own the export node SID,
/// not an invented binding leaf. Materialize that exact source row later.
pub fn prepareFacades(self: anytype, plan: anytype) !void {
    const root: NodeIndex = @fromBackingInt(self.parser_node_count - 1);
    const program = self.ast.getNode(root);
    if (program.tag != .program) return;
    for (0..program.data.list.len) |offset| {
        const source = self.ast.readExtraNode(program.data.list.start, @intCast(offset));
        const declaration = self.ast.getNode(source);
        if (declaration.tag != .export_default_declaration) continue;
        // Hoistable default functions are initialized during instantiation.
        if (self.ast.getNode(declaration.data.unary.operand).tag == .function_declaration) {
            if (self.legacy_default_name_instantiation and self.options.emit_runtime_helper_imports and
                self.ast.readExtraNode(self.ast.getNode(declaration.data.unary.operand).data.extra, ast.FunctionExtra.name).isNone())
                self.runtime_helpers.keep_names = true;
            continue;
        }
        const symbols = if (self.semantic_editor) |*editor| editor.symbols.items else self.symbols;
        const sid = (@import("../bundler/default_facade_identity.zig").symbolAt(self.ast, source, self.symbol_ids.items, symbols) catch
            @panic("module initialization default facade lost its exact source role")) orelse continue;
        if (@import("parameter_environment.zig").functionRoot(self, declaration.data.unary.operand)) |function| {
            // The new physical facade assignment must not infer its private
            // staging name for the original anonymous default function value.
            try self.parameter_inferred_names.put(self.allocator, function, try self.ast.addString("default"));
        }
        if (try prepare(self, source)) |flag| {
            try plan.module_flags.put(plan.arena.allocator(), sid, flag);
            self.runtime_helpers.tdz = true;
        }
    }
}

pub fn facadeValue(self: anytype, source: NodeIndex, value: NodeIndex) !NodeIndex {
    const plan = self.lexical_tdz_plan orelse return value;
    const sid = self.getSymbolIdAt(source) orelse return value;
    if (!plan.module_flags.contains(sid)) return value;
    const scope = self.programScope();
    const span = self.ast.getNode(source).span;
    const selected = try helpers.resolveDistinctScopedSyntheticOutputName(self, "_default", scope);
    const binding_span = try self.ast.addString(selected.name);
    const binding = try helpers.makeExactSyntheticBindingFromSpan(self, binding_span);
    // This is the initial facade's physical declaration, not a new source SID.
    try self.materializeDefaultExportFacade(source, binding, scope);
    const initialized = try initializedValue(self, binding, value);
    const declaration = try helpers.makeDeclarator(self, binding, initialized, span);
    try self.pending_nodes.append(self.allocator, try helpers.makeVarDeclaration(self, &.{declaration}, .@"var", span));
    const read = try self.makeIdentifierRefWithSymbolAt(binding_span, span, binding);
    try self.trackUserReadFromBinding(read, binding, scope);
    return read;
}

pub fn exportDefault(self: anytype, source: NodeIndex, original: ast.Node, value: NodeIndex) !NodeIndex {
    const sid = self.getSymbolIdAt(source);
    const materialized = if (self.lexical_tdz_plan) |plan| if (sid) |id| plan.module_flags.contains(id) else false else false;
    if (!materialized) return self.ast.addNode(.{
        .tag = original.tag,
        .span = original.span,
        .data = .{ .unary = .{ .operand = value, .flags = original.data.unary.flags } },
    });
    const read = try facadeValue(self, source, value);
    // Materialized facades are physical locals. Publish an exact alias instead
    // of asking the scanner to invent a second anonymous default facade.
    const specifier = try self.ast.addNode(.{
        .tag = .export_specifier,
        .span = original.span,
        .data = .{ .binary = .{ .left = read, .right = try helpers.makePropertyName(self, "default"), .flags = 0 } },
    });
    const specs = try self.ast.addNodeList(&.{specifier});
    const none = @backingInt(NodeIndex.none);
    return self.addExtraNode(.export_named_declaration, original.span, &.{ none, specs.start, specs.len, none, 0, 0 });
}

/// The generated inner write performs InitializeBinding before publication is
/// marked ready. User PutValue never calls this producer. Anonymous-value name
/// inference has already run on ordinary scalar initializers before this hook.
/// Select only actual pattern leaves already owned by this module plan.
pub fn declarationNeedsPatternInitialization(self: anytype, declaration: NodeIndex) !bool {
    const plan = self.lexical_tdz_plan orelse return false;
    if (declaration.isNone()) return false;
    const node = self.ast.getNode(declaration);
    if (node.tag != .variable_declaration) return false;
    const start = self.ast.readExtra(node.data.extra, 1);
    const length = self.ast.readExtra(node.data.extra, 2);
    for (0..length) |index| {
        const declarator = self.ast.getNode(self.ast.readExtraNode(start, @intCast(index)));
        const binding = self.ast.readExtraNode(declarator.data.extra, 0);
        const tag = self.ast.getNode(binding).tag;
        if (tag != .array_pattern and tag != .object_pattern) continue;
        var leaves = try @import("../parser/ast_walk.zig").bindingIdentifiers(self.allocator, self.ast, binding, .{});
        defer leaves.deinit();
        while (try leaves.next()) |leaf| {
            const sid = self.getSymbolIdAt(leaf) orelse continue;
            if (plan.module_flags.contains(sid)) return true;
        }
    }
    return false;
}

/// Keep public exports on the exact Source leaves while the ready statements
/// perform each InitializeBinding and its private publication in order.
pub fn lowerExportedPattern(self: anytype, declaration: NodeIndex, span: @import("../lexer/token.zig").Span) !NodeIndex {
    const node = self.ast.getNode(declaration);
    const start = self.ast.readExtra(node.data.extra, 1);
    const length = self.ast.readExtra(node.data.extra, 2);
    var specifiers: std.ArrayList(NodeIndex) = .empty;
    defer specifiers.deinit(self.allocator);
    for (0..length) |index| {
        const declarator = self.ast.getNode(self.ast.readExtraNode(start, @intCast(index)));
        const binding = self.ast.readExtraNode(declarator.data.extra, 0);
        var leaves = try @import("../parser/ast_walk.zig").bindingIdentifiers(self.allocator, self.ast, binding, .{});
        defer leaves.deinit();
        while (try leaves.next()) |leaf| {
            const original = self.ast.getNode(leaf);
            const local = try self.makeIdentifierRefWithSymbolAt(original.data.string_ref, original.span, leaf);
            try self.trackUserReadFromBinding(local, leaf, self.current_scope);
            const exported = try helpers.makePropertyNameFromSpan(self, original.data.string_ref);
            try specifiers.append(self.allocator, try self.ast.addNode(.{ .tag = .export_specifier, .span = span, .data = .{ .binary = .{ .left = local, .right = exported, .flags = 0 } } }));
        }
    }
    const specs = try self.ast.addNodeList(specifiers.items);
    const exports = try self.addExtraNode(.export_named_declaration, span, &.{ @backingInt(NodeIndex.none), specs.start, specs.len, @backingInt(NodeIndex.none), 0, 0 });
    const ready = try @import("es2015_destructuring.zig").ES2015Destructuring(@TypeOf(self.*)).lowerDestructuringDeclarationStatementAt(self, declaration);
    try self.trailing_nodes.append(self.allocator, exports);
    return ready;
}

pub fn initializedValue(self: anytype, binding: NodeIndex, rhs: NodeIndex) !NodeIndex {
    const plan = self.lexical_tdz_plan orelse return rhs;
    const sid = self.getSymbolIdAt(binding) orelse return rhs;
    const flag_binding = plan.module_flags.get(sid) orelse return rhs;
    if (plan.module_initialized_values.get(@backingInt(rhs))) |owner| {
        if (owner != sid) @panic("module initialization result crossed source bindings");
        return rhs;
    }
    const editor = if (self.semantic_editor) |*value| value else @panic("module initialization lost its editor");
    const role = editor.symbols.items[sid].lexical_initialization;
    if (role.state != .lowered_module or self.getSymbolIdAt(flag_binding) != @backingInt(role.flag))
        @panic("module initialization changed its exact private flag");
    const span = self.ast.getNode(binding).span;
    const original = self.ast.getNode(binding);
    const name = if (self.tableRenameOf(binding)) |selected| try self.ast.addString(selected) else original.data.string_ref;
    const target = try self.makeIdentifierRefWithSymbolAt(name, span, binding);
    try self.trackUserWriteFromBinding(target, binding, self.current_scope);
    const value = if (rhs.isNone()) try helpers.makeVoidZero(self, span) else rhs;
    const initialize = try helpers.makeAssignExpr(self, target, value, span, 0);
    const flag = try self.makeIdentifierRefWithSymbolAt(self.ast.getNode(flag_binding).data.string_ref, span, flag_binding);
    try self.trackUserWriteFromBinding(flag, flag_binding, self.current_scope);
    const publish = try helpers.makeAssignExpr(self, flag, try helpers.makeBoolLiteral(self, true), span, 0);
    const read = try self.makeIdentifierRefWithSymbolAt(name, span, binding);
    try self.trackUserReadFromBinding(read, binding, self.current_scope);
    const result = try self.ast.addNode(.{ .tag = .sequence_expression, .span = span, .data = .{ .list = try self.ast.addNodeList(&.{ initialize, publish, read }) } });
    try plan.module_initialized_values.put(plan.arena.allocator(), @backingInt(result), sid);
    return result;
}

pub fn appendDeclarations(self: anytype, source_body: NodeIndex, output: *std.ArrayList(NodeIndex)) !void {
    const plan = self.lexical_tdz_plan orelse return;
    if (@backingInt(source_body) != self.parser_node_count - 1 or plan.module_flags.count() == 0) return;
    var declarations: std.ArrayList(NodeIndex) = .empty;
    defer declarations.deinit(self.allocator);
    var flags = plan.module_flags.valueIterator();
    while (flags.next()) |binding| {
        try declarations.append(self.allocator, try helpers.makeDeclarator(self, binding.*, .none, self.ast.getNode(binding.*).span));
    }
    try output.append(self.allocator, try helpers.makeVarDeclaration(self, declarations.items, .@"var", self.ast.getNode(source_body).span));
    // A real imported-helper read owns this state marker before naming and
    // tree shaking. Only literal true means InitializeBinding completed;
    // undefined before execution and this helper sentinel both mean TDZ.
    var markers = plan.module_flags.valueIterator();
    while (markers.next()) |binding| {
        const span = self.ast.getNode(binding.*).span;
        const target = try self.makeIdentifierRefWithSymbolAt(self.ast.getNode(binding.*).data.string_ref, span, binding.*);
        try self.trackUserWriteFromBinding(target, binding.*, self.programScope());
        const marker = try helpers.makeAssignExpr(self, target, try helpers.makeRuntimeHelperRef(self, "__tdz"), span, 0);
        try output.append(self.allocator, try helpers.makeExprStmt(self, marker, span));
    }
}

test "legacy lexical TDZ module initialization flags retain ten exact source ownership checks" {
    _ = &@import("../bundler/emitter/legacy_lexical_getter.zig").expression;
    const source = "export const first=41,second=42;export let empty;export const[left=first,right=second]=[];export function keep(){let local=1;return local}";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var scanner = try @import("../lexer/scanner.zig").Scanner.init(a, source);
    var parser = @import("../parser/parser.zig").Parser.init(a, &scanner);
    parser.configureFromExtension(".mjs");
    _ = try parser.parse();
    var analyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer.init(a, &parser.ast);
    analyzer.is_module = true;
    analyzer.enable_exact_declaration_anchors = true;
    try analyzer.analyze();
    const source_symbols = analyzer.symbols.items.len;
    const Transformer = @import("transformer.zig").Transformer;
    var transformer = try Transformer.init(a, &parser.ast, .{
        .unsupported = @import("compat.zig").fromESTarget(.es5),
        .emit_runtime_helper_imports = true,
    });
    try transformer.initSymbolIds(analyzer.symbol_ids.items);
    transformer.symbols = analyzer.symbols.items;
    transformer.class_self_symbol_map = analyzer.class_self_symbol_map;
    transformer.references = analyzer.references.items;
    transformer.scopes = analyzer.scopes.items;
    transformer.scope_maps = analyzer.scope_maps.items;
    transformer.scope_owner_map = analyzer.scope_owner_map;
    transformer.node_scope_provenance = analyzer.node_scope_provenance;
    transformer.unresolved_references = &analyzer.unresolved_references;
    transformer.semantic_edit_enabled = true;
    const root = try transformer.transform();
    const edited = (try transformer.finishSemanticEdit()).?;
    const valid = @import("../semantic/lexical_initialization.zig").validate;
    try std.testing.expect(valid(edited.symbols.items, edited.scopes));
    var owners: std.ArrayList(u32) = .empty;
    for (edited.symbols.items, 0..) |symbol, raw| {
        if (symbol.lexical_initialization.state != .lowered_module) continue;
        try owners.append(a, @intCast(raw));
        try std.testing.expect(@backingInt(symbol.lexical_initialization.flag) >= source_symbols);
    }
    try std.testing.expectEqual(@as(usize, 5), owners.items.len);
    const live = try @import("../parser/ast_walk.zig").collectReachableNodeIndicesFrom(a, transformer.ast, root);
    for (owners.items) |owner| {
        const flag = @backingInt(edited.symbols.items[owner].lexical_initialization.flag);
        var physical: usize = 0;
        for (live) |raw| {
            if (transformer.ast.nodes.items[raw].tag == .binding_identifier and raw < edited.symbol_ids.len and edited.symbol_ids[raw] == flag)
                physical += 1;
        }
        try std.testing.expectEqual(@as(usize, 1), physical);
    }
    const owner = owners.items[0];
    const other = owners.items[1];
    const flag = @backingInt(edited.symbols.items[owner].lexical_initialization.flag);
    var foreign_scope = @import("../semantic/scope.zig").ScopeId.none;
    for (edited.scopes, 0..) |scope, raw| {
        if (scope.kind == .function) {
            foreign_scope = @fromBackingInt(@as(u32, @intCast(raw)));
            break;
        }
    }
    try std.testing.expect(!foreign_scope.isNone());
    const sem: @import("../bundler/module.zig").ModuleSemanticData = .{
        .symbols = edited.symbols,
        .scopes = edited.scopes,
        .scope_maps = edited.scope_maps,
        .scope_owner_map = edited.scope_owner_map,
        .node_scope_provenance = edited.node_scope_provenance,
        .source_owned_retirements = edited.source_owned_retirements,
        .scope_history = edited.scope_history,
        .symbol_ids = edited.symbol_ids,
        .references = edited.references,
        .helper_scope_map = edited.helper_scope_map,
        .exported_names = analyzer.exported_names,
        .unresolved_references = analyzer.unresolved_references,
    };
    const codec = @import("../bundler/semantic_codec.zig");
    var encoded: std.ArrayList(u8) = .empty;
    try codec.serialize(&sem, &encoded, a);
    var fresh = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer fresh.deinit();
    try std.testing.expectEqual(@as(u32, 54), codec.FORMAT_VERSION);
    const previous_format = try a.dupe(u8, encoded.items);
    std.mem.writeInt(u32, previous_format[4..8], 53, .little);
    try std.testing.expectError(error.UnsupportedVersion, codec.deserialize(previous_format, a));
    const restored = try codec.deserialize(encoded.items, fresh.allocator());
    try std.testing.expect(valid(restored.symbols.items, restored.scopes));
    try std.testing.expectEqual(@import("../bundler/module.zig").SemanticOwnerToken.unassigned, restored.owner_token);
    for (edited.symbols.items, restored.symbols.items) |before, after| {
        try std.testing.expectEqualDeep(before.lexical_initialization, after.lexical_initialization);
        try std.testing.expectEqual(before.binding_instantiation.lexical_initialization, after.binding_instantiation.lexical_initialization);
        try std.testing.expectEqual(before.synthetic_owner_id, after.synthetic_owner_id);
    }
    var wire: [9]u8 = undefined;
    wire[0] = @bitCast(edited.symbols.items[owner].binding_instantiation);
    std.mem.writeInt(u32, wire[1..5], flag, .little);
    std.mem.writeInt(u32, wire[5..9], 1, .little);
    const wire_start = std.mem.indexOf(u8, encoded.items, &wire) orelse return error.MissingModuleInitializationWireRole;
    try std.testing.expectEqual(wire_start, std.mem.lastIndexOf(u8, encoded.items, &wire).?);
    for (0..3) |attack| {
        const corrupt = try a.dupe(u8, encoded.items);
        switch (attack) {
            0 => std.mem.writeInt(u32, corrupt[wire_start + 1 ..][0..4], std.math.maxInt(u32), .little),
            1 => std.mem.writeInt(u32, corrupt[wire_start + 5 ..][0..4], 2, .little),
            2 => corrupt[wire_start] &= ~@as(u8, 8),
            else => unreachable,
        }
        std.mem.writeInt(u64, corrupt[8..16], @import("../util/wyhash.zig").hashU64(corrupt[16..]), .little);
        try std.testing.expectError(error.Truncated, codec.deserialize(corrupt, a));
    }
    const original = try a.dupe(@import("../semantic/symbol.zig").Symbol, edited.symbols.items);
    for (0..10) |attack| {
        const changed = try a.dupe(@import("../semantic/symbol.zig").Symbol, original);
        switch (attack) {
            0 => changed[owner].lexical_initialization.flag = .none,
            1 => changed[owner].lexical_initialization.state = .native,
            2 => changed[owner].binding_instantiation.lexical_initialization = false,
            3 => changed[flag].synthetic_kind = .standalone_temp_binding,
            4 => changed[flag].kind = .parameter,
            5 => changed[flag].synthetic_owner_id = @fromBackingInt(other),
            6 => changed[flag].scope_id = foreign_scope,
            7 => changed[owner].lexical_initialization.flag = original[other].lexical_initialization.flag,
            8 => changed[flag].synthetic_owner_id = null,
            9 => changed[flag].decl_flags.is_exported = true,
            else => unreachable,
        }
        try std.testing.expect(!valid(changed, edited.scopes));
        try std.testing.expect(valid(original, edited.scopes));
    }
}

test "legacy lexical TDZ named module classes publish their actual completed outer binding" {
    const source = "export class First{};export default class Second{}";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var scanner = try @import("../lexer/scanner.zig").Scanner.init(a, source);
    var parser = @import("../parser/parser.zig").Parser.init(a, &scanner);
    parser.configureFromExtension(".mjs");
    _ = try parser.parse();
    var analyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer.init(a, &parser.ast);
    analyzer.is_module = true;
    analyzer.enable_exact_declaration_anchors = true;
    try analyzer.analyze();
    const Transformer = @import("transformer.zig").Transformer;
    var transformer = try Transformer.init(a, &parser.ast, .{
        .unsupported = @import("compat.zig").fromESTarget(.es5),
        .emit_runtime_helper_imports = true,
    });
    try transformer.initSymbolIds(analyzer.symbol_ids.items);
    transformer.symbols = analyzer.symbols.items;
    transformer.class_self_symbol_map = analyzer.class_self_symbol_map;
    transformer.references = analyzer.references.items;
    transformer.scopes = analyzer.scopes.items;
    transformer.scope_maps = analyzer.scope_maps.items;
    transformer.scope_owner_map = analyzer.scope_owner_map;
    transformer.node_scope_provenance = analyzer.node_scope_provenance;
    transformer.unresolved_references = &analyzer.unresolved_references;
    transformer.semantic_edit_enabled = true;
    const root = try transformer.transform();
    const edited = (try transformer.finishSemanticEdit()).?;
    _ = root;
    try std.testing.expect(@import("../semantic/lexical_initialization.zig").validate(edited.symbols.items, edited.scopes));
    var classes: usize = 0;
    for (edited.symbols.items) |symbol| {
        if (symbol.lexical_initialization.state != .lowered_module) continue;
        try std.testing.expectEqual(@import("../semantic/symbol.zig").SymbolKind.class_decl, symbol.kind);
        classes += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), classes);
}

test "legacy lexical TDZ default facades retain source identity during actual materialization" {
    for ([_][]const u8{
        "export default 42",
        "const _default=1;export default _default",
        "export default class {}",
        "export default (function(){return 42})",
    }) |source| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var scanner = try @import("../lexer/scanner.zig").Scanner.init(a, source);
        var parser = @import("../parser/parser.zig").Parser.init(a, &scanner);
        parser.configureFromExtension(".mjs");
        _ = try parser.parse();
        var analyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer.init(a, &parser.ast);
        analyzer.is_module = true;
        analyzer.enable_exact_declaration_anchors = true;
        try analyzer.analyze();
        const Transformer = @import("transformer.zig").Transformer;
        var transformer = try Transformer.init(a, &parser.ast, .{
            .unsupported = @import("compat.zig").fromESTarget(.es5),
            .emit_runtime_helper_imports = true,
        });
        try transformer.initSymbolIds(analyzer.symbol_ids.items);
        transformer.symbols = analyzer.symbols.items;
        transformer.class_self_symbol_map = analyzer.class_self_symbol_map;
        transformer.references = analyzer.references.items;
        transformer.scopes = analyzer.scopes.items;
        transformer.scope_maps = analyzer.scope_maps.items;
        transformer.scope_owner_map = analyzer.scope_owner_map;
        transformer.node_scope_provenance = analyzer.node_scope_provenance;
        transformer.unresolved_references = &analyzer.unresolved_references;
        transformer.semantic_edit_enabled = true;
        const root = try transformer.transform();
        const edited = (try transformer.finishSemanticEdit()).?;
        _ = root;
        try std.testing.expect(@import("../semantic/lexical_initialization.zig").validate(edited.symbols.items, edited.scopes));
        var facades: usize = 0;
        for (edited.symbols.items) |symbol| {
            if (symbol.lexical_initialization.state != .lowered_module or !symbol.decl_flags.is_default_export) continue;
            try std.testing.expectEqual(@import("../semantic/symbol.zig").SymbolKind.variable_const, symbol.kind);
            facades += 1;
        }
        try std.testing.expectEqual(@as(usize, 1), facades);
    }
}

test "legacy lexical TDZ TS export equals class snapshot keeps its actual CommonJS owner" {
    const Bundler = @import("../bundler/bundler.zig").Bundler;
    const helpers_test = @import("../bundler/test_helpers.zig");
    for ([_]bool{ false, true }) |minify| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        // Exact valid source of the public Core regression.
        try helpers_test.writeFile(tmp.dir, "app.ts", "class Foo { greet() { return 'hi'; } }\nexport = Foo;");
        const entry = try helpers_test.absPath(&tmp, "app.ts");
        defer std.testing.allocator.free(entry);
        var bundler = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry}, .platform = .node, .format = .cjs, .unsupported = @import("compat.zig").fromESTarget(.es5), .minify_identifiers = minify, .minify_syntax = minify, .minify_whitespace = minify });
        defer bundler.deinit();
        const output = try bundler.bundle(std.testing.io);
        defer output.deinit(std.testing.allocator);
        try std.testing.expect(!output.hasErrors());
        // A single-file BundleResult uses output; outputs is the split/PM arm.
        try std.testing.expect(std.mem.indexOf(u8, output.output, "module.exports") != null);
        try std.testing.expect(std.mem.indexOf(u8, output.output, "class Foo") == null);
        try helpers_test.writeFile(tmp.dir, "output.cjs", output.output);
        try helpers_test.writeFile(tmp.dir, "driver.cjs", "const Foo=require('./output.cjs');console.log(new Foo().greet());");
        const driver = try helpers_test.absPath(&tmp, "driver.cjs");
        defer std.testing.allocator.free(driver);
        const observed = try std.process.run(std.testing.allocator, std.testing.io, .{ .argv = &.{ "node", driver } });
        defer std.testing.allocator.free(observed.stdout);
        defer std.testing.allocator.free(observed.stderr);
        try std.testing.expect(observed.term == .exited and observed.term.exited == 0);
        try std.testing.expectEqualStrings("hi\n", observed.stdout);
    }
}
