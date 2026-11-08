//! Source writes retain their native lexical cell while a private accessor
//! publishes its value to the compiler-owned public ESM binding.
const std = @import("std");
const ast = @import("../parser/ast.zig");
const NodeIndex = ast.NodeIndex;
const View = @import("native_module_using.zig").SourceView;
const Wrapper = @import("../bundler/native_module_wrapper_program.zig").Program;
pub const Error = error{InvalidNativeModuleStorageProjection};
pub const Entry = struct { binding: NodeIndex, symbol: u32, slot: u32 };
const Selected = struct { entry: Entry, anchor: usize, source_name: []const u8 };
const Use = struct { selected: usize, reference: usize, tag: ast.Node.Tag, span: @import("../lexer/token.zig").Span };
pub const Context = struct {
    domain: *const ast.Ast,
    view: View,
    root: NodeIndex,
    wrapper: *const Wrapper,
    environment: @import("../bundler/compiler_output_program.zig").Local,
    entries: []const Selected,
    uses: std.AutoHashMapUnmanaged(u32, Use),
    reference_count: usize,

    pub fn create(a: std.mem.Allocator, tree: *const ast.Ast, root: NodeIndex, view: View, wrapper: *const Wrapper, entries: []const Entry) !Context {
        if (view.domain != tree or root.isNone() or @backingInt(root) >= tree.nodes.items.len or tree.getNode(root).tag != .program) return error.InvalidNativeModuleStorageProjection;
        try wrapper.validate();
        const scope = view.scope_owner_map.get(@backingInt(root)) orelse return error.InvalidNativeModuleStorageProjection;
        const selected = try a.alloc(Selected, entries.len);
        var by_sid: std.AutoHashMapUnmanaged(u32, usize) = .empty;
        var slots: std.AutoHashMapUnmanaged(u32, void) = .empty;
        for (entries, 0..) |entry, i| {
            if (entry.binding.isNone() or @backingInt(entry.binding) >= tree.nodes.items.len or @backingInt(entry.binding) >= view.symbol_ids.len or view.symbol_ids[@backingInt(entry.binding)] != entry.symbol or entry.symbol >= view.symbols.len or tree.getNode(entry.binding).tag != .binding_identifier or by_sid.contains(entry.symbol) or slots.contains(entry.slot)) return error.InvalidNativeModuleStorageProjection;
            const symbol = view.symbols[entry.symbol];
            if (scope >= view.scopes.len or @backingInt(symbol.scope_id) != scope or symbol.kind == .import_binding or symbol.decl_flags.is_import) return error.InvalidNativeModuleStorageProjection;
            if (symbol.origin_scope != symbol.scope_id) {
                // A module var may be physically declared inside a block.
                // Authenticate its actual ancestor path to the module cell;
                // crossing a nested function's var scope is never valid.
                if (symbol.kind != .variable_var) return error.InvalidNativeModuleStorageProjection;
                var origin = symbol.origin_scope;
                var remaining = view.scopes.len;
                while (origin != symbol.scope_id) {
                    if (remaining == 0 or @backingInt(origin) >= view.scopes.len) return error.InvalidNativeModuleStorageProjection;
                    remaining -= 1;
                    const source_scope = view.scopes[@backingInt(origin)];
                    if (source_scope.kind.isVarScope()) return error.InvalidNativeModuleStorageProjection;
                    origin = source_scope.parent;
                }
            }
            var anchor: ?usize = null;
            for (view.references, 0..) |reference, ri| {
                if (@backingInt(reference.symbol_id) == entry.symbol and reference.flags.declare and reference.node_index.isNone() and reference.declaration_node_index == entry.binding and reference.scope_id == symbol.scope_id) {
                    if (anchor != null) return error.InvalidNativeModuleStorageProjection;
                    anchor = ri;
                }
            }
            selected[i] = .{ .entry = entry, .anchor = anchor orelse return error.InvalidNativeModuleStorageProjection, .source_name = try @import("../lexer/scanner.zig").Scanner.decodeIdentifierEscapesAlloc(a, tree.identifierNameText(tree.getNode(entry.binding))) };
            try by_sid.put(a, entry.symbol, i);
            try slots.put(a, entry.slot, {});
        }
        var uses: std.AutoHashMapUnmanaged(u32, Use) = .empty;
        for (view.references, 0..) |reference, ri| {
            if (!reference.flags.write or reference.node_index.isNone() or !reference.isValueUse()) continue;
            const si = by_sid.get(@backingInt(reference.symbol_id)) orelse continue;
            const raw = @backingInt(reference.node_index);
            if (raw >= tree.nodes.items.len or raw >= view.symbol_ids.len or view.symbol_ids[raw] != selected[si].entry.symbol) return error.InvalidNativeModuleStorageProjection;
            const node = tree.nodes.items[raw];
            if (node.tag != .identifier_reference and node.tag != .assignment_target_identifier) return error.InvalidNativeModuleStorageProjection;
            if (uses.contains(raw)) return error.InvalidNativeModuleStorageProjection;
            try uses.put(a, raw, .{ .selected = si, .reference = ri, .tag = node.tag, .span = node.span });
        }
        return .{ .domain = tree, .view = view, .root = root, .wrapper = wrapper, .environment = try wrapper.environmentLocal(), .entries = selected, .uses = uses, .reference_count = view.references.len };
    }
    fn get(self: *const Context, tree: *const ast.Ast, index: NodeIndex, sid: ?u32) Error!?Use {
        if (tree != self.domain or self.view.domain != tree or self.view.references.len != self.reference_count) return error.InvalidNativeModuleStorageProjection;
        const use = self.uses.get(@backingInt(index)) orelse return null;
        if (use.selected >= self.entries.len or use.reference >= self.view.references.len or @backingInt(index) >= tree.nodes.items.len or @backingInt(index) >= self.view.symbol_ids.len) return error.InvalidNativeModuleStorageProjection;
        const selected = self.entries[use.selected];
        const reference = self.view.references[use.reference];
        const node = tree.getNode(index);
        if (sid != selected.entry.symbol or self.view.symbol_ids[@backingInt(index)] != sid or reference.node_index != index or @backingInt(reference.symbol_id) != selected.entry.symbol or !reference.flags.write or reference.flags.declare or node.tag != use.tag or !std.meta.eql(node.span, use.span)) return error.InvalidNativeModuleStorageProjection;
        const environment = self.wrapper.environmentLocal() catch return error.InvalidNativeModuleStorageProjection;
        if (!std.meta.eql(environment, self.environment)) return error.InvalidNativeModuleStorageProjection;
        return use;
    }
};
pub fn has(self: anytype, index: NodeIndex) bool {
    const context = self.options.native_module_storage_projection orelse return false;
    return context.domain == self.ast and !index.isNone() and context.uses.contains(@backingInt(index));
}
pub fn emit(self: anytype, index: NodeIndex) @import("codegen.zig").Codegen.Error!bool {
    const context = self.options.native_module_storage_projection orelse return false;
    const use = try context.get(self.ast, index, self.sourceSymbolId(index)) orelse return false;
    try self.write(context.environment.final_name);
    try self.write("[2][");
    const slot = try std.fmt.allocPrint(self.allocator, "{d}", .{context.entries[use.selected].entry.slot});
    defer self.allocator.free(slot);
    try self.write(slot);
    try self.writeByte(']');
    return true;
}
pub fn emitNamedValue(self: anytype, target: NodeIndex, value: NodeIndex, level: @import("precedence.zig").Level, flags: @import("precedence.zig").ExprFlags) @import("codegen.zig").Codegen.Error!bool {
    const context = self.options.native_module_storage_projection orelse return false;
    var index = target;
    var remaining = self.ast.nodes.items.len;
    while (!index.isNone() and remaining != 0) : (remaining -= 1) {
        const node = self.ast.getNode(index);
        if (!node.tag.isTransparentWrapper()) break;
        index = node.data.unary.operand;
    }
    const use = try context.get(self.ast, index, self.sourceSymbolId(index)) orelse return false;
    if (!self.ast.isAnonymousFunctionDefinition(value)) return false;
    const quoted = try std.json.Stringify.valueAlloc(self.allocator, context.entries[use.selected].source_name, .{});
    defer self.allocator.free(quoted);
    try self.write("({[");
    try self.write(quoted);
    try self.write("]:");
    try self.emitExpr(value, level, flags);
    try self.write("})[");
    try self.write(quoted);
    try self.writeByte(']');
    return true;
}
