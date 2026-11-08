//! Entry publication connects exact source export identities to independently
//! analyzed native ESM cells. It never reuses a source SID in the output domain.
const std = @import("std");
const Module = @import("module.zig").Module;
const Linker = @import("linker.zig").Linker;
const ModuleIndex = @import("types.zig").ModuleIndex;
const Artifact = @import("native_module_publication_program.zig").Program;
const Storage = @import("../codegen/native_module_storage_projection.zig");
const View = @import("../codegen/native_module_using.zig").SourceView;
const NodeIndex = @import("../parser/ast.zig").NodeIndex;
pub const Cell = struct {
    source_index: ModuleIndex,
    source_owner: @import("module.zig").SemanticOwnerToken,
    output_owner: @import("codegen_output_domain.zig").Owner,
    export_index: usize,
    symbol: ?u32,
    binding: ?NodeIndex,
    namespace: []const u8,
    key: []const u8,
    value: []const u8,
};
pub const Plan = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    graph: *const @import("graph.zig").ModuleGraph,
    entry: *const Module,
    artifact: *Artifact,
    cells: []const Cell,

    pub fn create(allocator: std.mem.Allocator, linker: *const Linker, entry: *const Module) !*Plan {
        const self = try allocator.create(Plan);
        errdefer allocator.destroy(self);
        self.* = .{ .allocator = allocator, .arena = .init(allocator), .graph = linker.graph, .entry = entry, .artifact = undefined, .cells = &.{} };
        errdefer self.arena.deinit();
        const a = self.arena.allocator();
        var keys: std.ArrayList([]const u8) = .empty;
        var cells: std.ArrayList(Cell) = .empty;
        var foreign_names: std.ArrayList([]const u8) = .empty;
        var modules = linker.graph.modulesIterator();
        while (modules.next()) |module| {
            if (module.semantic) |semantic| for (semantic.symbols.items) |symbol| {
                try foreign_names.append(a, symbol.nameText(module.source));
                if (symbol.output_name_hint.len > 0) try foreign_names.append(a, symbol.output_name_hint);
            };
        }
        var final_names = linker.rename_table.map.valueIterator();
        while (final_names.next()) |name| try foreign_names.append(a, name.*);
        for (entry.export_bindings) |exported| {
            if (exported.kind == .re_export_star or exported.kind == .re_export_namespace) return error.InvalidNativeModulePublicationPlan;
            var canonical = linker.resolveExportChain(entry.index, exported.exported_name, 0) orelse return error.InvalidNativeModulePublicationPlan;
            var remaining = linker.graph.moduleCount() + 1;
            var provider: *const Module = undefined;
            var source_binding: *const @import("binding_scanner.zig").ExportBinding = undefined;
            while (true) {
                if (remaining == 0 or canonical.synthetic_member != null) return error.InvalidNativeModulePublicationPlan;
                remaining -= 1;
                provider = linker.graph.getModule(canonical.module_index) orelse return error.InvalidNativeModulePublicationPlan;
                if (!@import("native_async_module_plan.zig").contains(linker.graph, provider)) return error.InvalidNativeModulePublicationPlan;
                source_binding = provider.findExportBinding(canonical.export_name) orelse return error.InvalidNativeModulePublicationPlan;
                const sid = provider.exportBindingSemanticIndex(source_binding.*);
                const semantic = provider.semantic orelse return error.InvalidNativeModulePublicationPlan;
                if (sid) |id| {
                    if (id >= semantic.symbols.items.len) return error.InvalidNativeModulePublicationPlan;
                    if (semantic.symbols.items[id].kind == .import_binding) {
                        var next: ?@import("linker.zig").SymbolRef = null;
                        for (provider.import_bindings) |binding| {
                            const local = try provider.checkedImportBindingSourceSymbol(binding);
                            if (local.semanticIndex() != sid) continue;
                            const resolved = linker.getResolvedBinding(provider.index.toU32(), binding.local_span) orelse return error.InvalidNativeModulePublicationPlan;
                            next = resolved.canonical;
                            break;
                        }
                        canonical = next orelse return error.InvalidNativeModulePublicationPlan;
                        continue;
                    }
                }
                break;
            }
            const semantic = provider.semantic orelse return error.InvalidNativeModulePublicationPlan;
            if (semantic.owner_token == .unassigned or provider.codegen_output_owner == .unassigned) return error.InvalidNativeModulePublicationPlan;
            var export_index: ?usize = null;
            for (provider.export_bindings, 0..) |*binding, i| if (binding == source_binding) {
                export_index = i;
            };
            const namespace = try provider.allocExportsName(a, &linker.rename_table);
            const member = try @import("linker/preamble_writer.zig").allocMemberAccess(a, canonical.export_name);
            try cells.append(a, .{ .source_index = provider.index, .source_owner = semantic.owner_token, .output_owner = provider.codegen_output_owner, .export_index = export_index orelse return error.InvalidNativeModulePublicationPlan, .symbol = provider.exportBindingSemanticIndex(source_binding.*), .binding = source_binding.local_symbol_node, .namespace = namespace, .key = try a.dupe(u8, canonical.export_name), .value = try std.fmt.allocPrint(a, "(0,{s}{s})", .{ namespace, member }) });
            const public_key = if (@import("linker/preamble_writer.zig").isQuotedName(exported.exported_name))
                try @import("../string_escape.zig").decodeJsStringLiteral(a, exported.exported_name)
            else
                try @import("../lexer/scanner.zig").Scanner.decodeIdentifierEscapesAlloc(a, exported.exported_name);
            try keys.append(a, public_key);
        }
        self.artifact = try Artifact.create(allocator, keys.items, foreign_names.items);
        errdefer self.artifact.destroy();
        self.cells = cells.items;
        try self.validate();
        return self;
    }
    pub fn destroy(self: *Plan) void {
        const allocator = self.allocator;
        self.artifact.destroy();
        self.arena.deinit();
        allocator.destroy(self);
    }
    pub fn validate(self: *const Plan) !void {
        try self.artifact.validate();
        if (self.graph.getModule(self.entry.index) != self.entry or self.cells.len != self.artifact.cells.len) return error.InvalidNativeModulePublicationPlan;
        for (self.cells) |cell| try self.validateCell(cell);
    }
    fn validateCell(self: *const Plan, cell: Cell) !void {
        const module = self.graph.getModule(cell.source_index) orelse return error.InvalidNativeModulePublicationPlan;
        const semantic = module.semantic orelse return error.InvalidNativeModulePublicationPlan;
        if (semantic.owner_token != cell.source_owner or module.codegen_output_owner != cell.output_owner or cell.export_index >= module.export_bindings.len) return error.InvalidNativeModulePublicationPlan;
        const binding = module.export_bindings[cell.export_index];
        if (module.exportBindingSemanticIndex(binding) != cell.symbol or binding.local_symbol_node != cell.binding or !std.mem.eql(u8, binding.exported_name, cell.key)) return error.InvalidNativeModulePublicationPlan;
    }

    pub fn storageEntries(self: *const Plan, a: std.mem.Allocator, module: *const Module, view: View) ![]const Storage.Entry {
        // The whole immutable artifact is validated before parallel emission.
        // Every consumed source cell is still checked against its live owner.
        if (self.graph.getModule(module.index) != module) return error.InvalidNativeModulePublicationPlan;
        var entries: std.ArrayList(Storage.Entry) = .empty;
        var seen: std.AutoHashMapUnmanaged(u32, void) = .empty;
        var written: std.AutoHashMapUnmanaged(u32, void) = .empty;
        for (view.references) |reference| if (reference.flags.write and !reference.node_index.isNone() and reference.isValueUse()) {
            try written.put(a, @backingInt(reference.symbol_id), {});
        };
        for (self.cells) |cell| {
            if (cell.source_index != module.index) continue;
            try self.validateCell(cell);
            const sid = cell.symbol orelse continue;
            if (!written.contains(sid) or seen.contains(sid)) continue;
            try seen.put(a, sid, {});
            // A local export specifier carries a value-use anchor, not the
            // declaration binding. Resolve the actual declaration by its SID
            // in this source view before selecting a storage write target.
            var declaration: ?NodeIndex = null;
            for (view.references) |reference| {
                if (@backingInt(reference.symbol_id) != sid or !reference.flags.declare or !reference.node_index.isNone() or reference.declaration_node_index.isNone()) continue;
                // Several var declarations may initialize the same native
                // module cell. The storage plan needs one physical binding
                // witness, not a globally unique declaration for the SID.
                if (declaration == null) declaration = reference.declaration_node_index;
            }
            try entries.append(a, .{ .symbol = sid, .binding = declaration orelse return error.InvalidNativeModulePublicationPlan, .slot = @intCast(entries.items.len) });
        }
        return entries.items;
    }
    pub fn setterBody(self: *const Plan, a: std.mem.Allocator, module: *const Module, sid: u32, local: []const u8, value: []const u8) ![]const u8 {
        if (self.graph.getModule(module.index) != module) return error.InvalidNativeModulePublicationPlan;
        var output: std.ArrayList(u8) = .empty;
        try output.appendSlice(a, local);
        try output.append(a, '=');
        try output.appendSlice(a, value);
        try output.appendSlice(a, ";if(");
        try output.appendSlice(a, self.artifact.ready.name);
        try output.appendSlice(a, "){");
        for (self.cells, self.artifact.cells) |cell, target| {
            if (cell.source_index != module.index or cell.symbol != sid) continue;
            try self.validateCell(cell);
            try output.appendSlice(a, target.name);
            try output.append(a, '=');
            try output.appendSlice(a, local);
            try output.append(a, ';');
        }
        try output.append(a, '}');
        return output.items;
    }
    pub fn fingerprint(self: *const Plan) u64 {
        var hash = std.hash.Wyhash.init(0x4e41544956455055);
        hash.update(self.artifact.ready.name);
        for (self.cells, self.artifact.cells, self.artifact.public_keys) |cell, output, key| {
            const module = self.graph.getModule(cell.source_index) orelse @panic("publication cache source disappeared");
            const parts = [_][]const u8{ module.path, cell.key, cell.value, output.name, key };
            for (parts) |part| {
                const length: u64 = part.len;
                hash.update(std.mem.asBytes(&length));
                hash.update(part);
            }
            const sid: u32 = cell.symbol orelse std.math.maxInt(u32);
            const binding: u32 = if (cell.binding) |node| @backingInt(node) else std.math.maxInt(u32);
            hash.update(std.mem.asBytes(&sid));
            hash.update(std.mem.asBytes(&binding));
        }
        return hash.final();
    }
    pub fn emitPublish(self: *const Plan, a: std.mem.Allocator) ![]const u8 {
        try self.validate();
        const values = try a.alloc([]const u8, self.cells.len);
        defer a.free(values);
        for (self.cells, 0..) |cell, i| values[i] = cell.value;
        return self.artifact.emitPublish(a, values);
    }
};
