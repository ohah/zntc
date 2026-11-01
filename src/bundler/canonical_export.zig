//! Output-name authority captured from the actual export-map producer.
//! Public keys select records; they never recover a lexical SymbolId.
const std = @import("std");
const Module = @import("module.zig").Module;
const Binding = @import("binding_scanner.zig").ExportBinding;
const Linker = @import("linker.zig").Linker;
const symbols = @import("symbol.zig");
const source = @import("cross_chunk_export.zig");
const ast_mod = @import("../parser/ast.zig");
const parser_module = @import("../parser/module.zig");
const SemanticOwnerToken = @import("module.zig").SemanticOwnerToken;
pub const Error = source.Error;

pub const Receipt = struct {
    owner: *const Module,
    binding: *const Binding,
    before: Binding,
    owner_token: SemanticOwnerToken,
    role: union(enum) {
        local: source.Provider,
        alias: struct { table: *const symbols.AliasTable, backing: []const symbols.Alias, id: symbols.AliasId, name: []const u8, external: bool },
        namespace: void,
        cjs_member: symbols.SymbolID,
        graphless: void,
    },

    pub fn capture(l: *const Linker, owner: *const Module, binding: *const Binding) Error!Receipt {
        if (l.getModule(owner.index.toU32()) != owner or !source.registered(owner, binding)) return error.InvalidCrossChunkExport;
        const token = if (owner.semantic) |sem| sem.owner_token else .unassigned;
        const role: @FieldType(Receipt, "role") = role: {
            if (owner.ast == null and owner.semantic == null) break :role .graphless;
            if (token == .unassigned) return error.InvalidCrossChunkExport;
            if (owner.wrap_kind == .cjs) {
                const sid = owner.require_symbol orelse return error.InvalidCrossChunkExport;
                if (owner.getRequireName(null) == null) return error.InvalidCrossChunkExport;
                break :role .{ .cjs_member = symbols.SymbolID.make(owner.index, @backingInt(sid)) };
            }
            if (binding.kind == .local or binding.hasSyntheticDefault(owner.semanticSymbols()))
                break :role .{ .local = try source.Provider.captureLocal(l, owner, binding) };
            if (binding.kind == .re_export_namespace) {
                try validateNamespace(l.allocator, owner, binding.*);
                break :role .namespace;
            }
            if (binding.kind != .re_export) return error.InvalidCrossChunkExport;
            try validateAlias(l.allocator, owner, binding.*);
            const id = switch (binding.symbol) {
                .alias => |known| if (known.module == owner.index and !known.symbol.isNone()) known.symbol else return error.InvalidCrossChunkExport,
                else => return error.InvalidCrossChunkExport,
            };
            const table = if (owner.alias_table) |*value| value else return error.InvalidCrossChunkExport;
            if (@backingInt(id) >= table.aliases.items.len or !std.mem.eql(u8, table.getName(id), binding.exported_name)) return error.InvalidCrossChunkExport;
            var owners: usize = 0;
            for (owner.export_bindings) |candidate| if (candidate.symbol.eql(binding.symbol)) {
                owners += 1;
            };
            if (owners != 1) return error.InvalidCrossChunkExport;
            const record = owner.import_records[binding.import_record_index.?];
            break :role .{ .alias = .{ .table = table, .backing = table.aliases.items, .id = id, .name = table.getName(id), .external = record.is_external } };
        };
        return .{ .owner = owner, .binding = binding, .before = binding.*, .owner_token = token, .role = role };
    }

    pub fn localName(self: Receipt, l: *const Linker) Error!?[]const u8 {
        if (l.getModule(self.owner.index.toU32()) != self.owner or !source.registered(self.owner, self.binding) or
            !std.meta.eql(self.before, self.binding.*)) return error.InvalidCrossChunkExport;
        if (self.owner.semantic) |sem| {
            if (sem.owner_token != self.owner_token or self.owner_token == .unassigned) return error.InvalidCrossChunkExport;
        } else if (self.owner_token != .unassigned) return error.InvalidCrossChunkExport;
        return switch (self.role) {
            .local => |known| try known.bindingName(l),
            .alias => |known| alias: {
                const table = if (self.owner.alias_table) |*value| value else return error.InvalidCrossChunkExport;
                if (table != known.table or table.aliases.items.ptr != known.backing.ptr or table.aliases.items.len != known.backing.len or
                    @backingInt(known.id) >= table.aliases.items.len or !std.mem.eql(u8, table.getName(known.id), known.name)) return error.InvalidCrossChunkExport;
                // canonical_name/ref_count are the alias model's live fields.
                if (table.hasCanonicalName(known.id)) break :alias table.getCanonicalName(known.id);
                // An external forwarding key has no source lexical SID.
                break :alias if (known.external) self.before.local_name else null;
            },
            .namespace => self.before.local_name,
            .cjs_member => |known| cjs: {
                const sid = self.owner.require_symbol orelse return error.InvalidCrossChunkExport;
                if (known.module != self.owner.index or @backingInt(known.inner) != @backingInt(sid) or self.owner.getRequireName(null) == null) return error.InvalidCrossChunkExport;
                break :cjs if (std.mem.eql(u8, self.before.exported_name, "default")) "_default" else self.before.exported_name;
            },
            .graphless => if (self.owner.ast == null and self.owner.semantic == null) self.before.local_name else return error.InvalidCrossChunkExport,
        };
    }
};

fn node(tree: *const ast_mod.Ast, index: ast_mod.NodeIndex) ?ast_mod.Node {
    if (index.isNone() or @backingInt(index) >= tree.nodes.items.len) return null;
    return tree.getNode(index);
}

fn validateNamespace(a: std.mem.Allocator, owner: *const Module, binding: Binding) Error!void {
    const tree = if (owner.ast) |*value| value else return error.InvalidCrossChunkExport;
    const statement = node(tree, binding.source_export_node orelse return error.InvalidCrossChunkExport) orelse return error.InvalidCrossChunkExport;
    if (statement.tag != .export_all_declaration or !tree.hasExtra(statement.data.extra, 4)) return error.InvalidCrossChunkExport;
    const extra = parser_module.readExportAllExtras(tree, statement.data.extra);
    const record = binding.import_record_index orelse return error.InvalidCrossChunkExport;
    if (record >= owner.import_records.len or owner.import_records[record].source_node != extra.source or
        !try source.keyMatches(a, tree, extra.exported_name, binding.exported_name)) return error.InvalidCrossChunkExport;
}

fn validateAlias(a: std.mem.Allocator, owner: *const Module, binding: Binding) Error!void {
    const tree = if (owner.ast) |*value| value else return error.InvalidCrossChunkExport;
    const statement = node(tree, binding.source_export_node orelse return error.InvalidCrossChunkExport) orelse return error.InvalidCrossChunkExport;
    if (statement.tag != .export_named_declaration or !tree.hasExtra(statement.data.extra, 4)) return error.InvalidCrossChunkExport;
    const specifier_index = binding.source_specifier_node orelse return error.InvalidCrossChunkExport;
    const specifier = node(tree, specifier_index) orelse return error.InvalidCrossChunkExport;
    const extra = statement.data.extra;
    const start = tree.extra_data.items[extra + 1];
    const len = tree.extra_data.items[extra + 2];
    if (!tree.readExtraNode(extra, 0).isNone() or start > tree.extra_data.items.len or len > tree.extra_data.items.len - start or
        specifier.tag != .export_specifier or specifier.data.binary.flags & parser_module.SPEC_FLAG_TYPE_ONLY != 0) return error.InvalidCrossChunkExport;
    var matches: usize = 0;
    for (tree.extra_data.items[start..][0..len]) |raw| if (raw == @backingInt(specifier_index)) {
        matches += 1;
    };
    const key = if (specifier.data.binary.right.isNone()) specifier.data.binary.left else specifier.data.binary.right;
    if (matches != 1 or !try source.keyMatches(a, tree, key, binding.exported_name)) return error.InvalidCrossChunkExport;
    const record = binding.import_record_index orelse return error.InvalidCrossChunkExport;
    if (record >= owner.import_records.len) return error.InvalidCrossChunkExport;
    const from = tree.readExtraNode(extra, 3);
    if (!from.isNone()) {
        if (owner.import_records[record].source_node != from) return error.InvalidCrossChunkExport;
        return;
    }
    // Import-then-export aliases consume the real source reference SID and
    // original import carrier; the public exported spelling is not a selector.
    const semantic = owner.semantic orelse return error.InvalidCrossChunkExport;
    const raw = @backingInt(specifier.data.binary.left);
    if (raw >= semantic.symbol_ids.len) return error.InvalidCrossChunkExport;
    const sid = semantic.symbol_ids[raw] orelse return error.InvalidCrossChunkExport;
    var imports: usize = 0;
    for (owner.import_bindings) |binding_import| {
        if (binding_import.import_record_index != record) continue;
        const actual = @import("binding_scanner.zig").resolveImportLocalSymbol(binding_import, .{ .module_index = owner.index, .ast = tree, .symbol_ids = semantic.symbol_ids, .symbols = semantic.symbols.items });
        if (actual.semanticIndex() != @as(?u32, sid)) continue;
        _ = owner.checkedSourceImportLocalSymbol(binding_import) catch return error.InvalidCrossChunkExport;
        imports += 1;
    }
    if (imports != 1) return error.InvalidCrossChunkExport;
}

/// Match the actual exported source reference to the scanner-owned import
/// binding. Neither the local spelling nor the public export key selects a SID.
pub fn sameImportedSourceLocal(owner: *const Module, exported: Binding, imported: @import("binding_scanner.zig").ImportBinding) bool {
    const tree = if (owner.ast) |*value| value else return false;
    const semantic = owner.semantic orelse return false;
    const anchor = exported.local_symbol_node orelse return false;
    if (anchor.isNone() or @backingInt(anchor) >= semantic.symbol_ids.len) return false;
    const sid = semantic.symbol_ids[@backingInt(anchor)] orelse return false;
    const actual = @import("binding_scanner.zig").resolveImportLocalSymbol(imported, .{ .module_index = owner.index, .ast = tree, .symbol_ids = semantic.symbol_ids, .symbols = semantic.symbols.items });
    if (actual.semanticIndex() != @as(?u32, sid)) return false;
    _ = owner.checkedSourceImportLocalSymbol(imported) catch return false;
    return true;
}
