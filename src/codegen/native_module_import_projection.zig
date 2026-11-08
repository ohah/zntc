//! Exact source-import uses projected into a checked provider namespace.
//! Provider selection belongs to the linker; no name resolves a source identity here.
const std = @import("std");
const ast = @import("../parser/ast.zig");
const SourceView = @import("native_module_using.zig").SourceView;
const NodeIndex = ast.NodeIndex;
pub const Error = error{InvalidNativeModuleImportProjection};
pub const Entry = struct { binding: NodeIndex, symbol: u32, namespace_name: []const u8, property: ?[]const u8, binding_reader: ?[]const u8 = null };
const Selected = struct { entry: Entry, quoted_key: ?[]const u8, source_name: []const u8, declaration: NodeIndex, specifier: NodeIndex, anchor: ?usize = null };
const Use = struct { entry: usize, write: bool, span: @import("../lexer/token.zig").Span, tag: ast.Node.Tag, read_reference: ?usize = null, write_reference: ?usize = null };

pub const Context = struct {
    domain: *const ast.Ast,
    root: NodeIndex,
    view: SourceView,
    entries: []const Selected,
    uses: std.AutoHashMapUnmanaged(u32, Use),
    entry_by_sid: std.AutoHashMapUnmanaged(u32, usize),
    source: []const u8,
    source_hash: u64,
    reference_count: usize,

    pub fn create(a: std.mem.Allocator, domain: *const ast.Ast, root: NodeIndex, view: SourceView, entries: []const Entry) !Context {
        if (view.domain != domain or root.isNone() or @backingInt(root) >= domain.nodes.items.len or domain.getNode(root).tag != .program) return error.InvalidNativeModuleImportProjection;
        const selected = try a.alloc(Selected, entries.len);
        var by_sid: std.AutoHashMapUnmanaged(u32, usize) = .empty;
        for (entries, 0..) |entry, i| {
            if (entry.namespace_name.len == 0 or entry.binding.isNone() or @backingInt(entry.binding) >= domain.nodes.items.len or @backingInt(entry.binding) >= view.symbol_ids.len or view.symbol_ids[@backingInt(entry.binding)] != entry.symbol or entry.symbol >= view.symbols.len) return error.InvalidNativeModuleImportProjection;
            if (entry.binding_reader) |reader| if (reader.len == 0 or entry.property == null) return error.InvalidNativeModuleImportProjection;
            const anchor = try importAnchor(domain, root, entry.binding);
            if (anchor.namespace != (entry.property == null) or by_sid.contains(entry.symbol)) return error.InvalidNativeModuleImportProjection;
            try by_sid.put(a, entry.symbol, i);
            var quoted_key: ?[]const u8 = null;
            if (entry.property) |key| {
                const value = try canonicalKey(a, key);
                const source_key = try canonicalKey(a, anchor.key orelse return error.InvalidNativeModuleImportProjection);
                if (!std.mem.eql(u8, value, source_key)) return error.InvalidNativeModuleImportProjection;
                quoted_key = try std.json.Stringify.valueAlloc(a, value, .{});
            }
            selected[i] = .{ .entry = entry, .quoted_key = quoted_key, .source_name = try @import("../lexer/scanner.zig").Scanner.decodeIdentifierEscapesAlloc(a, domain.identifierNameText(domain.getNode(entry.binding))), .declaration = anchor.declaration, .specifier = anchor.specifier };
        }
        var uses: std.AutoHashMapUnmanaged(u32, Use) = .empty;
        for (view.references, 0..) |reference, reference_index| {
            const import_index = by_sid.get(@backingInt(reference.symbol_id)) orelse continue;
            if (reference.flags.declare and reference.declaration_node_index == selected[import_index].entry.binding and reference.node_index.isNone()) {
                if (selected[import_index].anchor != null) return error.InvalidNativeModuleImportProjection;
                selected[import_index].anchor = reference_index;
            }
            if (!reference.isValueUse() or reference.node_index.isNone()) continue;
            const i = import_index;
            const raw = @backingInt(reference.node_index);
            if (raw >= domain.nodes.items.len or raw >= view.symbol_ids.len or view.symbol_ids[raw] != selected[i].entry.symbol or reference.node_index == selected[i].entry.binding) return error.InvalidNativeModuleImportProjection;
            const node = domain.getNode(reference.node_index);
            if (node.tag != .identifier_reference and node.tag != .assignment_target_identifier) return error.InvalidNativeModuleImportProjection;
            const result = try uses.getOrPut(a, raw);
            if (!result.found_existing) result.value_ptr.* = .{ .entry = i, .write = reference.flags.write, .span = node.span, .tag = node.tag } else {
                if (result.value_ptr.entry != i) return error.InvalidNativeModuleImportProjection;
                result.value_ptr.write = result.value_ptr.write or reference.flags.write;
            }
            if (reference.flags.read) result.value_ptr.read_reference = reference_index;
            if (reference.flags.write) result.value_ptr.write_reference = reference_index;
        }
        const self: Context = .{ .domain = domain, .root = root, .view = view, .entries = selected, .uses = uses, .entry_by_sid = by_sid, .source = domain.source, .source_hash = std.hash.Wyhash.hash(0, domain.source), .reference_count = view.references.len };
        try self.validate();
        return self;
    }
    pub fn validate(self: *const Context) Error!void {
        if (self.reference_count != self.view.references.len or self.domain != self.view.domain or self.source.ptr != self.domain.source.ptr or self.source.len != self.domain.source.len or self.source_hash != std.hash.Wyhash.hash(0, self.domain.source)) return error.InvalidNativeModuleImportProjection;
        for (self.entries, 0..) |selected, i| {
            if (self.entry_by_sid.get(selected.entry.symbol) != i) return error.InvalidNativeModuleImportProjection;
            try self.validateEntry(selected);
            const actual = try importAnchor(self.domain, self.root, selected.entry.binding);
            if (actual.declaration != selected.declaration or actual.specifier != selected.specifier or actual.namespace != (selected.entry.property == null)) return error.InvalidNativeModuleImportProjection;
        }
        var uses = self.uses.iterator();
        while (uses.next()) |item| {
            const use = item.value_ptr.*;
            if (use.entry >= self.entries.len or item.key_ptr.* >= self.domain.nodes.items.len or item.key_ptr.* >= self.view.symbol_ids.len or self.view.symbol_ids[item.key_ptr.*] != self.entries[use.entry].entry.symbol) return error.InvalidNativeModuleImportProjection;
            const node = self.domain.nodes.items[item.key_ptr.*];
            if (node.tag != use.tag or !std.meta.eql(node.span, use.span)) return error.InvalidNativeModuleImportProjection;
            try self.validateUse(item.key_ptr.*, use);
        }
    }
    fn validateEntry(self: *const Context, selected: Selected) Error!void {
        const entry = selected.entry;
        if (entry.binding.isNone() or @backingInt(entry.binding) >= self.domain.nodes.items.len or @backingInt(entry.binding) >= self.view.symbol_ids.len or self.view.symbol_ids[@backingInt(entry.binding)] != entry.symbol or entry.symbol >= self.view.symbols.len or entry.namespace_name.len == 0) return error.InvalidNativeModuleImportProjection;
        if (entry.binding_reader) |reader| if (reader.len == 0 or entry.property == null) return error.InvalidNativeModuleImportProjection;
        const symbol = self.view.symbols[entry.symbol];
        const scope = self.view.scope_owner_map.get(@backingInt(self.root)) orelse return error.InvalidNativeModuleImportProjection;
        if (symbol.kind != .import_binding or !symbol.decl_flags.is_import or @backingInt(symbol.scope_id) != scope or symbol.origin_scope != symbol.scope_id or scope >= self.view.scopes.len) return error.InvalidNativeModuleImportProjection;
        const anchor = selected.anchor orelse return error.InvalidNativeModuleImportProjection;
        if (anchor >= self.view.references.len) return error.InvalidNativeModuleImportProjection;
        const reference = self.view.references[anchor];
        if (reference.declaration_node_index != entry.binding or @backingInt(reference.symbol_id) != entry.symbol or !reference.node_index.isNone() or !reference.flags.declare or reference.scope_id != symbol.scope_id) return error.InvalidNativeModuleImportProjection;
    }
    /// Local import re-exports use the same selected provider access as reads.
    pub fn readExpressionForSymbol(self: *const Context, allocator: std.mem.Allocator, symbol: u32) !?[]const u8 {
        const index = self.entry_by_sid.get(symbol) orelse return null;
        if (index >= self.entries.len) return error.InvalidNativeModuleImportProjection;
        const selected = self.entries[index];
        if (selected.entry.symbol != symbol) return error.InvalidNativeModuleImportProjection;
        try self.validateEntry(selected);
        if (selected.entry.binding_reader) |reader| return try std.fmt.allocPrint(allocator, "(0,{s})()", .{reader});
        return if (selected.quoted_key) |key|
            try std.fmt.allocPrint(allocator, "(0,{s}[{s}])", .{ selected.entry.namespace_name, key })
        else
            try std.fmt.allocPrint(allocator, "(0,{s})", .{selected.entry.namespace_name});
    }
    fn validateUse(self: *const Context, raw: u32, use: Use) Error!void {
        if (self.reference_count != self.view.references.len or use.entry >= self.entries.len) return error.InvalidNativeModuleImportProjection;
        var read = false;
        var write = false;
        for ([_]?usize{ use.read_reference, use.write_reference }) |maybe| if (maybe) |index| {
            if (index >= self.view.references.len) return error.InvalidNativeModuleImportProjection;
            const reference = self.view.references[index];
            if (!reference.isValueUse() or @backingInt(reference.node_index) != raw or @backingInt(reference.symbol_id) != self.entries[use.entry].entry.symbol) return error.InvalidNativeModuleImportProjection;
            read = read or reference.flags.read;
            write = write or reference.flags.write;
        };
        if ((!read and !write) or write != use.write) return error.InvalidNativeModuleImportProjection;
    }
    fn get(self: *const Context, domain: *const ast.Ast, index: NodeIndex, sid: ?u32) Error!?Use {
        if (domain != self.domain or self.view.domain != domain) return error.InvalidNativeModuleImportProjection;
        if (index.isNone()) return null;
        const use = self.uses.get(@backingInt(index)) orelse return null;
        if (use.entry >= self.entries.len or sid != self.entries[use.entry].entry.symbol or @backingInt(index) >= domain.nodes.items.len) return error.InvalidNativeModuleImportProjection;
        const node = domain.getNode(index);
        if (node.tag != use.tag or !std.meta.eql(node.span, use.span)) return error.InvalidNativeModuleImportProjection;
        try self.validateEntry(self.entries[use.entry]);
        try self.validateUse(@backingInt(index), use);
        return use;
    }
};
const Anchor = struct { declaration: NodeIndex, specifier: NodeIndex, namespace: bool, key: ?[]const u8 };
fn canonicalKey(a: std.mem.Allocator, key: []const u8) ![]const u8 {
    if (@import("../bundler/linker/preamble_writer.zig").isQuotedName(key)) return @import("../string_escape.zig").decodeJsStringLiteral(a, key) catch return error.InvalidNativeModuleImportProjection;
    return @import("../lexer/scanner.zig").Scanner.decodeIdentifierEscapesAlloc(a, key);
}
fn importAnchor(domain: *const ast.Ast, root: NodeIndex, binding: NodeIndex) Error!Anchor {
    if (root.isNone() or @backingInt(root) >= domain.nodes.items.len) return error.InvalidNativeModuleImportProjection;
    const program = domain.getNode(root);
    if (program.tag != .program) return error.InvalidNativeModuleImportProjection;
    var statements = domain.iterateExtraList(program.data.list);
    while (statements.next()) |statement| {
        const node = domain.getNode(statement);
        if (node.tag != .import_declaration) continue;
        const extra = @import("../parser/module.zig").readImportDeclExtras(domain, node.data.extra);
        var specs = domain.iterateExtraList(.{ .start = extra.specs_start, .len = extra.specs_len });
        while (specs.next()) |specifier| {
            const spec = domain.getNode(specifier);
            const local = switch (spec.tag) {
                .import_default_specifier, .import_namespace_specifier => specifier,
                .import_specifier => if (spec.data.binary.right.isNone()) spec.data.binary.left else spec.data.binary.right,
                else => continue,
            };
            if (local == binding) return .{ .declaration = statement, .specifier = specifier, .namespace = spec.tag == .import_namespace_specifier, .key = if (spec.tag == .import_namespace_specifier) null else if (spec.tag == .import_default_specifier) "default" else domain.getText(domain.getNode(spec.data.binary.left).span) };
        }
    }
    return error.InvalidNativeModuleImportProjection;
}

pub fn has(self: anytype, index: NodeIndex) bool {
    if (@import("native_module_storage_projection.zig").has(self, index)) return true;
    const context = self.options.native_module_import_projection orelse return false;
    return context.domain == self.ast and !index.isNone() and context.uses.contains(@backingInt(index));
}
fn access(self: anytype, selected: Selected) !void {
    if (selected.entry.binding_reader) |reader| {
        try self.write("(0,");
        try self.write(reader);
        try self.write(")()");
        return;
    }
    try self.write(selected.entry.namespace_name);
    if (selected.quoted_key) |quoted| {
        try self.writeByte('[');
        try self.write(quoted);
        try self.writeByte(']');
    }
}
pub fn emit(self: anytype, index: NodeIndex) @import("codegen.zig").Codegen.Error!bool {
    const context = self.options.native_module_import_projection orelse return false;
    const use = try context.get(self.ast, index, self.sourceSymbolId(index)) orelse return false;
    const selected = context.entries[use.entry];
    if (use.write) {
        // A fresh compiler-only getter Reference is immutable even if an
        // exposed namespace's configurable descriptor was changed by user code.
        try self.write("({get v(){return ");
        try access(self, selected);
        try self.write("}}).v");
    } else {
        // Imported bindings are environment References, never method receivers.
        try self.write("(0,");
        try access(self, selected);
        try self.writeByte(')');
    }
    return true;
}
pub fn emitNamedValue(self: anytype, target: NodeIndex, value: NodeIndex, level: @import("precedence.zig").Level, flags: @import("precedence.zig").ExprFlags) @import("codegen.zig").Codegen.Error!bool {
    if (try @import("native_module_storage_projection.zig").emitNamedValue(self, target, value, level, flags)) return true;
    const context = self.options.native_module_import_projection orelse return false;
    var index = target;
    var remaining = self.ast.nodes.items.len;
    while (!index.isNone() and remaining != 0) : (remaining -= 1) {
        const node = self.ast.getNode(index);
        if (!node.tag.isTransparentWrapper()) break;
        index = node.data.unary.operand;
    }
    const use = try context.get(self.ast, index, self.sourceSymbolId(index)) orelse return false;
    if (!use.write or !self.ast.isAnonymousFunctionDefinition(value)) return false;
    const selected = context.entries[use.entry];
    try self.write("({[");
    try @import("keep_names.zig").writeQuoted(self, selected.source_name);
    try self.write("]:");
    try self.emitExpr(value, level, flags);
    try self.write("})[");
    try @import("keep_names.zig").writeQuoted(self, selected.source_name);
    try self.writeByte(']');
    return true;
}
