//! Arena-backed construction of local runtime imports and actual references.
const std = @import("std");
const ast_mod = @import("../parser/ast.zig");
const NodeIndex = ast_mod.NodeIndex;
const Ast = ast_mod.Ast;
const ScopeId = @import("../semantic/scope.zig").ScopeId;
const SymbolId = @import("../semantic/symbol.zig").SymbolId;
const Reference = @import("../semantic/symbol.zig").Reference;
const Editor = @import("../semantic/editor.zig").SemanticEditor;
const SymbolID = @import("symbol.zig").SymbolID;
const Module = @import("module.zig").Module;

pub const Builder = struct {
    allocator: std.mem.Allocator,
    ast: *Ast,
    editor: *Editor,
    module: *Module,
    graph: *@import("graph.zig").ModuleGraph,
    declarations: std.ArrayList(NodeIndex) = .empty,
    next_name: u32 = 0,
    records: std.ArrayList(@import("types.zig").ImportRecord) = .empty,
    bindings: std.ArrayList(@import("binding_scanner.zig").ImportBinding) = .empty,
    storage_initialized: bool = false,
    references: std.ArrayList(struct { node: NodeIndex, symbol: SymbolId, scope: ScopeId, kind: @import("../semantic/symbol.zig").SymbolKind = .import_binding }) = .empty,

    // The module arena owns these arrays. Keep amortized capacity across alias
    // creation, and publish a complete record/binding pair only after success.
    fn reserveImportSlot(self: *Builder) !void {
        if (!self.storage_initialized) {
            self.records = .fromOwnedSlice(self.module.import_records);
            self.bindings = .fromOwnedSlice(self.module.import_bindings);
            self.storage_initialized = true;
        }
        try self.records.ensureUnusedCapacity(self.allocator, 1);
        self.module.import_records = self.records.items;
        try self.bindings.ensureUnusedCapacity(self.allocator, 1);
        self.module.import_bindings = self.bindings.items;
    }

    pub fn validate(self: *Builder) !void {
        for (self.references.items) |expected| {
            const raw = @backingInt(expected.node);
            if (raw >= self.ast.nodes.items.len or raw >= self.editor.symbol_ids.items.len or
                expected.symbol.isNone() or @backingInt(expected.symbol) >= self.editor.symbols.items.len or
                expected.scope.isNone() or expected.scope.toIndex() >= self.editor.scopes.items.len or
                self.editor.symbol_ids.items[raw] != @backingInt(expected.symbol)) return error.InvalidCallsiteReference;
            const actual_reference = try self.editor.referenceForNode(expected.node) orelse return error.InvalidCallsiteReference;
            if (actual_reference.flags.declare or !actual_reference.flags.read or actual_reference.symbol_id != expected.symbol or actual_reference.scope_id != expected.scope) return error.InvalidCallsiteReference;
            if (self.editor.symbols.items[@backingInt(expected.symbol)].kind != expected.kind) return error.InvalidCallsiteReference;
        }
        for (self.module.import_bindings) |binding| {
            const target = binding.callsite_target orelse continue;
            const foreign = self.graph.getModule(target.symbol.module) orelse return error.InvalidCallsiteTarget;
            const foreign_sem = foreign.semantic orelse return error.InvalidCallsiteTarget;
            if (target.owner == .unassigned or target.owner != foreign_sem.owner_token or @backingInt(target.symbol.inner) >= foreign_sem.symbols.items.len) return error.InvalidCallsiteTarget;
            try @import("runtime_callsite_targets.zig").validateTargetRole(self.graph, target);
            const local = @import("binding_scanner.zig").resolveImportLocalSymbol(binding, .{ .module_index = self.module.index, .ast = self.ast, .symbol_ids = self.editor.symbol_ids.items, .symbols = self.editor.symbols.items });
            if (!local.isValid() or !local.eql(binding.local_symbol) or !binding.symbol.eql(target.symbol.toRef())) return error.InvalidCallsiteBinding;
            const local_raw = local.semanticIndex().?;
            const row = self.editor.symbols.items[local_raw];
            if (row.scope_id.isNone() or row.scope_id.toIndex() >= self.editor.scope_maps.items.len or self.editor.scope_maps.items[row.scope_id.toIndex()].get(self.ast.getText(row.name)) != @as(?usize, local_raw)) return error.InvalidCallsiteBinding;
        }
    }

    pub fn reference(self: *Builder, id: SymbolId, scope: ScopeId) !NodeIndex {
        if (id.isNone() or @backingInt(id) >= self.editor.symbols.items.len) return error.InvalidCallsiteReference;
        const symbol = self.editor.symbols.items[@backingInt(id)];
        const name = symbol.name;
        const node = try self.ast.addNode(.{ .tag = .identifier_reference, .span = name, .data = .{ .string_ref = name } });
        try self.editor.addReference(node, id, scope, .{ .read = true }, Reference.NO_STMT, Reference.NO_STMT);
        try self.references.append(self.allocator, .{ .node = node, .symbol = id, .scope = scope, .kind = symbol.kind });
        return node;
    }

    pub fn imported(self: *Builder, target: SymbolID, role: @import("binding_scanner.zig").CallsiteRole) !SymbolId {
        const foreign = self.graph.moduleAtMut(target.module) orelse return error.InvalidCallsiteTarget;
        const foreign_sem = if (foreign.semantic) |*value| value else return error.InvalidCallsiteTarget;
        if (@backingInt(target.inner) >= foreign_sem.symbols.items.len) return error.InvalidCallsiteTarget;
        const owner = foreign_sem.captureOwnerToken();
        try self.reserveImportSlot();
        const root_scope: ScopeId = @fromBackingInt(@as(u32, 0));
        if (self.editor.scopes.items.len == 0 or self.editor.scope_maps.items.len == 0) return error.InvalidCallsiteScope;
        var sequence = self.next_name;
        var name: []const u8 = undefined;
        while (true) : (sequence += 1) {
            name = try std.fmt.allocPrint(self.allocator, "__import_callsite_{d}", .{sequence});
            if (!self.editor.scope_maps.items[root_scope.toIndex()].contains(name)) break;
        }
        self.next_name = sequence + 1;
        const span = try self.ast.addString(name);
        const binding = try self.ast.addNode(.{ .tag = .binding_identifier, .span = span, .data = .{ .string_ref = span } });
        const sid = try self.editor.declare(binding, span, span, root_scope, .import_binding, Reference.NO_STMT, Reference.NO_STMT);
        const exported_span = try self.ast.addString("__exact_target");
        const exported = try self.ast.addNode(.{ .tag = .identifier_reference, .span = exported_span, .data = .{ .string_ref = exported_span } });
        const specifier = try self.ast.addNode(.{ .tag = .import_specifier, .span = span, .data = .{ .binary = .{ .left = exported, .right = binding, .flags = 0 } } });
        const specs = try self.ast.addNodeList(&.{specifier});
        const source_span = try self.ast.addString(try std.json.Stringify.valueAlloc(self.allocator, foreign.path, .{}));
        const source = try self.ast.addNode(.{ .tag = .string_literal, .span = source_span, .data = .{ .string_ref = source_span } });
        const extra = try self.ast.addExtras(&.{ specs.start, specs.len, @backingInt(source), 0, 0, 0 });
        const declaration = try self.ast.addNode(.{ .tag = .import_declaration, .span = span, .data = .{ .extra = extra } });
        try self.declarations.append(self.allocator, declaration);
        const record_index: u32 = @intCast(self.records.items.len);
        self.records.appendAssumeCapacity(.{ .specifier = foreign.path, .kind = .static_import, .span = source_span, .resolved = target.module });
        self.bindings.appendAssumeCapacity(.{
            .kind = .named,
            .local_name = name,
            .imported_name = "__exact_target",
            .local_span = span,
            .import_record_index = record_index,
            .local_symbol_node = binding,
            .local_symbol = @import("symbol.zig").SymbolRef.makeSemantic(self.module.index, @backingInt(sid)),
            .symbol = target.toRef(),
            .source_type_only = false,
            .callsite_target = .{ .role = role, .symbol = target, .owner = owner, .declaration = declaration },
        });
        self.module.import_records = self.records.items;
        self.module.import_bindings = self.bindings.items;
        try self.graph.linkDependency(self.module.index, target.module);
        return sid;
    }

    pub fn call(self: *Builder, callee: NodeIndex, args: []const NodeIndex) !NodeIndex {
        const list = try self.ast.addNodeList(args);
        const extra = try self.ast.addExtras(&.{ @backingInt(callee), list.start, list.len, 0 });
        return self.ast.addNode(.{ .tag = .call_expression, .span = .EMPTY, .data = .{ .extra = extra } });
    }

    pub fn use(self: *Builder, target: SymbolID, scope: ScopeId, role: @import("binding_scanner.zig").CallsiteRole) !NodeIndex {
        return self.reference(try self.imported(target, role), scope);
    }
};
