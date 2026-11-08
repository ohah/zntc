//! Native public ESM cells are compiler-owned bindings with their own first
//! analysis. Source module SymbolIds never enter this program's name domain.
const std = @import("std");
const ast = @import("../parser/ast.zig");
const NodeIndex = ast.NodeIndex;
const Output = @import("compiler_output_program.zig");
const ScopeId = @import("../semantic/scope.zig").ScopeId;
const SymbolId = @import("../semantic/symbol.zig").SymbolId;
pub const Binding = struct {
    owner: @import("codegen_output_domain.zig").Owner,
    declaration: NodeIndex,
    binding: NodeIndex,
    initializer: NodeIndex,
    anchor: usize,
    symbol: SymbolId,
    scope: ScopeId,
    name: []const u8,
};
const Export = struct { statement: NodeIndex, specifier: NodeIndex, local: NodeIndex, public: NodeIndex, public_span: @import("../lexer/token.zig").Span, public_value: []const u8 };
pub const Program = struct {
    allocator: std.mem.Allocator,
    output: *Output.Program,
    source: []const u8,
    source_hash: u64,
    root_scope: ScopeId,
    ready: Binding,
    cells: []const Binding,
    statements: []const NodeIndex,
    public_keys: []const []const u8,
    exports: []const Export,

    pub fn create(allocator: std.mem.Allocator, keys: []const []const u8, foreign_names: []const []const u8) !*Program {
        var source: std.ArrayList(u8) = .empty;
        defer source.deinit(allocator);
        try source.appendSlice(allocator, "let ready=false;");
        for (keys, 0..) |_, i| {
            const declaration = try std.fmt.allocPrint(allocator, "let cell{d};", .{i});
            defer allocator.free(declaration);
            try source.appendSlice(allocator, declaration);
        }
        for (keys, 0..) |key, i| {
            const quoted = try std.json.Stringify.valueAlloc(allocator, key, .{});
            defer allocator.free(quoted);
            const declaration = try std.fmt.allocPrint(allocator, "export{{cell{d} as {s}}};", .{ i, quoted });
            defer allocator.free(declaration);
            try source.appendSlice(allocator, declaration);
        }
        try source.appendSlice(allocator, "module.exports={};");
        const output = try Output.Program.createModule(allocator, source.items);
        errdefer output.destroy();
        const a = output.arena.allocator();
        const self = try allocator.create(Program);
        errdefer allocator.destroy(self);
        const root_node = output.ast.getNode(output.root);
        if (root_node.tag != .program or root_node.data.list.len != keys.len * 2 + 2) return error.InvalidNativeModulePublicationProgram;
        const scope_raw = output.analysis.scope_owner_map.get(@backingInt(output.root)) orelse return error.InvalidNativeModulePublicationProgram;
        const statements = try a.alloc(NodeIndex, keys.len * 2 + 1);
        for (statements, 0..) |*statement, i| statement.* = @fromBackingInt(output.ast.extra_data.items[root_node.data.list.start + i]);
        var names: @import("../transformer/es_helpers.zig").PrivateNameAllocator = .{ .allocator = a };
        for (foreign_names) |name| try names.reserved.put(a, try @import("../lexer/scanner.zig").Scanner.decodeIdentifierEscapesAlloc(a, name), {});
        var globals = output.analysis.unresolved_references.keyIterator();
        while (globals.next()) |name| try names.reserved.put(a, name.*, {});
        var anchors: std.AutoHashMapUnmanaged(u32, usize) = .empty;
        for (output.analysis.references.items, 0..) |reference, i| {
            if (!reference.flags.declare or !reference.node_index.isNone() or reference.declaration_node_index.isNone()) continue;
            const key = @backingInt(reference.declaration_node_index);
            const entry = try anchors.getOrPut(a, key);
            if (entry.found_existing) return error.InvalidNativeModulePublicationProgram;
            entry.value_ptr.* = i;
        }
        const bindings = try a.alloc(Binding, keys.len + 1);
        for (bindings, 0..) |*binding, i| {
            const declaration = statements[i];
            const node = output.ast.getNode(declaration);
            if (node.tag != .variable_declaration or output.ast.variableDeclarationKind(node) != .let or !output.ast.hasExtra(node.data.extra, 2)) return error.InvalidNativeModulePublicationProgram;
            const extra = output.ast.extra_data.items[node.data.extra..][0..3];
            if (extra[2] != 1) return error.InvalidNativeModulePublicationProgram;
            const declarator = output.ast.nodes.items[output.ast.extra_data.items[extra[1]]];
            if (declarator.tag != .variable_declarator) return error.InvalidNativeModulePublicationProgram;
            const identifier = output.ast.readExtraNode(declarator.data.extra, 0);
            if (output.ast.getNode(identifier).tag != .binding_identifier) return error.InvalidNativeModulePublicationProgram;
            const sid = output.analysis.symbol_ids.items[@backingInt(identifier)] orelse return error.InvalidNativeModulePublicationProgram;
            const symbol = output.analysis.symbols.items[sid];
            if (symbol.kind != .variable_let or @backingInt(symbol.scope_id) != scope_raw or symbol.origin_scope != symbol.scope_id) return error.InvalidNativeModulePublicationProgram;
            const preferred = try std.fmt.allocPrint(a, "__zntcPublication{d}", .{i});
            const name = try names.makeUniqueName(preferred);
            try output.names.put(a, sid, name);
            binding.* = .{ .owner = output.owner, .declaration = declaration, .binding = identifier, .initializer = output.ast.readExtraNode(declarator.data.extra, 2), .anchor = anchors.get(@backingInt(identifier)) orelse return error.InvalidNativeModulePublicationProgram, .symbol = @fromBackingInt(sid), .scope = symbol.scope_id, .name = name };
        }
        const public_keys = try a.alloc([]const u8, keys.len);
        for (keys, 0..) |key, i| public_keys[i] = try a.dupe(u8, key);
        const exports = try a.alloc(Export, keys.len);
        for (exports, 0..) |*exported, i| {
            const statement = statements[keys.len + 1 + i];
            const node = output.ast.getNode(statement);
            if (node.tag != .export_named_declaration) return error.InvalidNativeModulePublicationProgram;
            const extra = @import("../parser/module.zig").readExportNamedExtras(&output.ast, node.data.extra);
            if (!extra.decl.isNone() or !extra.source.isNone() or extra.specs_len != 1) return error.InvalidNativeModulePublicationProgram;
            const specifier: NodeIndex = @fromBackingInt(output.ast.extra_data.items[extra.specs_start]);
            const spec = output.ast.getNode(specifier);
            if (spec.tag != .export_specifier) return error.InvalidNativeModulePublicationProgram;
            const public = output.ast.getNode(spec.data.binary.right);
            if (public.tag != .string_literal) return error.InvalidNativeModulePublicationProgram;
            exported.* = .{ .statement = statement, .specifier = specifier, .local = spec.data.binary.left, .public = spec.data.binary.right, .public_span = public.data.string_ref, .public_value = try @import("../string_escape.zig").decodeJsStringLiteral(a, output.ast.getText(public.data.string_ref)) };
        }
        self.* = .{ .allocator = allocator, .output = output, .source = output.ast.source, .source_hash = std.hash.Wyhash.hash(0, output.ast.source), .root_scope = @fromBackingInt(scope_raw), .ready = bindings[0], .cells = bindings[1..], .statements = statements, .public_keys = public_keys, .exports = exports };
        try self.validate();
        return self;
    }
    pub fn destroy(self: *Program) void {
        const allocator = self.allocator;
        self.output.destroy();
        allocator.destroy(self);
    }
    fn validateBinding(self: *const Program, binding: Binding) !void {
        const tree = &self.output.ast;
        const sid = @backingInt(binding.symbol);
        if (binding.owner != self.output.owner or binding.scope != self.root_scope or binding.declaration.isNone() or binding.binding.isNone() or @backingInt(binding.declaration) >= tree.nodes.items.len or @backingInt(binding.binding) >= tree.nodes.items.len or @backingInt(binding.binding) >= self.output.analysis.symbol_ids.items.len or sid >= self.output.analysis.symbols.items.len) return error.InvalidNativeModulePublicationProgram;
        const declaration = tree.getNode(binding.declaration);
        if (declaration.tag != .variable_declaration or tree.variableDeclarationKind(declaration) != .let or !tree.hasExtra(declaration.data.extra, 2)) return error.InvalidNativeModulePublicationProgram;
        const extra = tree.extra_data.items[declaration.data.extra..][0..3];
        if (extra[2] != 1) return error.InvalidNativeModulePublicationProgram;
        const declarator = tree.nodes.items[tree.extra_data.items[extra[1]]];
        if (declarator.tag != .variable_declarator or tree.readExtraNode(declarator.data.extra, 0) != binding.binding or tree.readExtraNode(declarator.data.extra, 2) != binding.initializer or tree.getNode(binding.binding).tag != .binding_identifier or self.output.analysis.symbol_ids.items[@backingInt(binding.binding)] != sid) return error.InvalidNativeModulePublicationProgram;
        const symbol = self.output.analysis.symbols.items[sid];
        if (symbol.kind != .variable_let or symbol.scope_id != binding.scope or symbol.origin_scope != symbol.scope_id or !std.mem.eql(u8, self.output.names.get(sid) orelse return error.InvalidNativeModulePublicationProgram, binding.name)) return error.InvalidNativeModulePublicationProgram;
        if (binding.anchor >= self.output.analysis.references.items.len) return error.InvalidNativeModulePublicationProgram;
        const anchor = self.output.analysis.references.items[binding.anchor];
        if (anchor.symbol_id != binding.symbol or anchor.scope_id != binding.scope or !anchor.flags.declare or !anchor.node_index.isNone() or anchor.declaration_node_index != binding.binding) return error.InvalidNativeModulePublicationProgram;
    }
    pub fn validate(self: *const Program) !void {
        if (self.output.root.isNone() or @backingInt(self.output.root) >= self.output.ast.nodes.items.len or self.root_scope.isNone() or @backingInt(self.root_scope) >= self.output.analysis.scopes.items.len) return error.InvalidNativeModulePublicationProgram;
        try self.output.validate();
        if (self.source.ptr != self.output.ast.source.ptr or self.source.len != self.output.ast.source.len or std.hash.Wyhash.hash(0, self.output.ast.source) != self.source_hash or self.cells.len != self.public_keys.len or self.statements.len != self.cells.len * 2 + 1 or self.output.analysis.scope_owner_map.get(@backingInt(self.output.root)) != @as(?u32, @backingInt(self.root_scope))) return error.InvalidNativeModulePublicationProgram;
        const scope = self.output.analysis.scopes.items[@backingInt(self.root_scope)];
        if (scope.kind != .module or !scope.is_strict or !scope.parent.isNone()) return error.InvalidNativeModulePublicationProgram;
        try self.validateBinding(self.ready);
        if (self.ready.initializer.isNone()) return error.InvalidNativeModulePublicationProgram;
        const initial_ready = self.output.ast.getNode(self.ready.initializer);
        if (initial_ready.tag != .boolean_literal or !std.mem.eql(u8, self.output.ast.getText(initial_ready.span), "false")) return error.InvalidNativeModulePublicationProgram;
        if (self.statements[0] != self.ready.declaration) return error.InvalidNativeModulePublicationProgram;
        for (self.cells, 0..) |cell, i| {
            try self.validateBinding(cell);
            if (!cell.initializer.isNone()) return error.InvalidNativeModulePublicationProgram;
            if (self.statements[i + 1] != cell.declaration) return error.InvalidNativeModulePublicationProgram;
        }
        if (self.exports.len != self.cells.len) return error.InvalidNativeModulePublicationProgram;
        for (self.exports, self.cells, self.public_keys, 0..) |exported, cell, key, i| {
            if (self.statements[self.cells.len + 1 + i] != exported.statement) return error.InvalidNativeModulePublicationProgram;
            const node = self.output.ast.getNode(exported.statement);
            if (node.tag != .export_named_declaration) return error.InvalidNativeModulePublicationProgram;
            const extra = @import("../parser/module.zig").readExportNamedExtras(&self.output.ast, node.data.extra);
            if (!extra.decl.isNone() or !extra.source.isNone() or extra.specs_len != 1 or self.output.ast.extra_data.items[extra.specs_start] != @backingInt(exported.specifier)) return error.InvalidNativeModulePublicationProgram;
            const spec = self.output.ast.getNode(exported.specifier);
            if (spec.tag != .export_specifier or spec.data.binary.left != exported.local or spec.data.binary.right != exported.public or self.output.analysis.symbol_ids.items[@backingInt(exported.local)] != @as(?u32, @backingInt(cell.symbol))) return error.InvalidNativeModulePublicationProgram;
            const public = self.output.ast.getNode(exported.public);
            if (public.tag != .string_literal or !std.meta.eql(public.data.string_ref, exported.public_span)) return error.InvalidNativeModulePublicationProgram;
            if (!std.mem.eql(u8, exported.public_value, key)) return error.InvalidNativeModulePublicationProgram;
        }
        const root = self.output.ast.getNode(self.output.root);
        if (root.tag != .program or root.data.list.len != self.statements.len + 1) return error.InvalidNativeModulePublicationProgram;
        for (self.statements, 0..) |statement, i| if (self.output.ast.extra_data.items[root.data.list.start + i] != @backingInt(statement)) return error.InvalidNativeModulePublicationProgram;
    }
    pub fn emitHeader(self: *const Program, a: std.mem.Allocator, minify: bool) ![]const u8 {
        try self.validate();
        var codegen = @import("../codegen/codegen.zig").Codegen.initWithOptions(a, &self.output.ast, .{
            .module_format = .esm,
            .minify_whitespace = minify,
            .semantic_symbol_ids = self.output.analysis.symbol_ids.items,
            .semantic_symbols = self.output.analysis.symbols.items,
            .semantic_symbol_name_overrides = &self.output.names,
            .generated_iife_scope_owner_map = &self.output.analysis.scope_owner_map,
        });
        defer codegen.deinit();
        const raw = try a.alloc(u32, self.statements.len);
        defer a.free(raw);
        for (self.statements, 0..) |statement, i| raw[i] = @backingInt(statement);
        return a.dupe(u8, try codegen.generateStatements(self.output.root, raw));
    }
    pub fn emitPublish(self: *const Program, a: std.mem.Allocator, values: []const []const u8) ![]const u8 {
        try self.validate();
        if (values.len != self.cells.len) return error.InvalidNativeModulePublicationProgram;
        var result: std.ArrayList(u8) = .empty;
        errdefer result.deinit(a);
        for (self.cells, values) |cell, value| {
            try result.appendSlice(a, cell.name);
            try result.append(a, '=');
            try result.appendSlice(a, value);
            try result.append(a, ';');
        }
        try result.appendSlice(a, self.ready.name);
        try result.appendSlice(a, "=true;\n");
        return result.toOwnedSlice(a);
    }
};

test "native module publication program keeps owned public cells live and default snapshots independent" {
    const a = std.testing.allocator;
    const program = try Program.create(a, &.{ "default", "value", "advance" }, &.{ "__zntcPublication0", "__zntcPublication1" });
    defer program.destroy();
    const header = try program.emitHeader(a, false);
    defer a.free(header);
    const advance = try std.fmt.allocPrint(a, "function(){{++{s}}}", .{program.cells[1].name});
    defer a.free(advance);
    const publication = try program.emitPublish(a, &.{ "1", "1", advance });
    defer a.free(publication);
    const source = try std.mem.concat(a, u8, &.{ header, publication });
    defer a.free(source);
    try std.testing.expect(std.mem.indexOf(u8, source, "export") != null);
    try std.testing.expect(!std.mem.eql(u8, program.ready.name, "__zntcPublication0"));
    // The actual native ESM consumer check is performed by the integration
    // harness; this contract checks first-analysis binding/output ownership.
    try program.validate();
}

test "native module publication program rejects foreign binding role and scope identities" {
    const a = std.testing.allocator;
    const program = try Program.create(a, &.{ "value", "other" }, &.{});
    defer program.destroy();
    const original = program.ready;
    program.ready = program.cells[0];
    try std.testing.expectError(error.InvalidNativeModulePublicationProgram, program.validate());
    program.ready = original;
    const names = &program.output.names;
    const old_name = names.get(@backingInt(original.symbol)).?;
    try names.put(program.output.arena.allocator(), @backingInt(original.symbol), "foreign");
    try std.testing.expectError(error.InvalidNativeModulePublicationProgram, program.validate());
    try names.put(program.output.arena.allocator(), @backingInt(original.symbol), old_name);
    const owner = program.output.analysis.scope_owner_map.fetchRemove(@backingInt(program.output.root)).?;
    try std.testing.expectError(error.InvalidNativeModulePublicationProgram, program.validate());
    try program.output.analysis.scope_owner_map.put(program.output.arena.allocator(), owner.key, owner.value);
    const exported = program.exports[0];
    const spec = program.output.ast.nodes.items[@backingInt(exported.specifier)];
    program.output.ast.nodes.items[@backingInt(exported.specifier)].data.binary.left = program.exports[1].local;
    try std.testing.expectError(error.InvalidNativeModulePublicationProgram, program.validate());
    program.output.ast.nodes.items[@backingInt(exported.specifier)] = spec;
    program.output.ast.nodes.items[@backingInt(exported.specifier)].data.binary.right = program.exports[1].public;
    try std.testing.expectError(error.InvalidNativeModulePublicationProgram, program.validate());
    program.output.ast.nodes.items[@backingInt(exported.specifier)] = spec;
    const initial = program.output.ast.nodes.items[@backingInt(program.ready.initializer)];
    program.output.ast.nodes.items[@backingInt(program.ready.initializer)].tag = .null_literal;
    try std.testing.expectError(error.InvalidNativeModulePublicationProgram, program.validate());
    program.output.ast.nodes.items[@backingInt(program.ready.initializer)] = initial;
    const root_scope = program.output.analysis.scopes.items[@backingInt(program.root_scope)];
    program.output.analysis.scopes.items[@backingInt(program.root_scope)].kind = .function;
    try std.testing.expectError(error.InvalidNativeModulePublicationProgram, program.validate());
    program.output.analysis.scopes.items[@backingInt(program.root_scope)] = root_scope;
    try program.validate();
}
