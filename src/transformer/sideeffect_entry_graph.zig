//! Authority for binding-free, zero-specifier source imports. Not a native-syntax waiver.
const std = @import("std");
const ast = @import("../parser/ast.zig");
const walk = @import("../parser/ast_walk.zig");
const module = @import("../bundler/module.zig");
const types = @import("../bundler/types.zig");
const scope = @import("../semantic/scope.zig");
const Options = @import("transformer.zig").TransformOptions;
const N = ast.NodeIndex;
const ImportRecord = types.ImportRecord;
const Meta = struct {
    typescript: bool,
    jsx: bool,
    jsx_key: bool,
    decorator: bool,
    flow_enum: bool,
    fn capture(t: *const ast.Ast) Meta {
        return .{ .typescript = t.is_typescript, .jsx = t.has_jsx, .jsx_key = t.has_jsx_key_after_spread, .decorator = t.has_decorator, .flow_enum = t.has_flow_enum_declaration };
    }
};
pub const Import = struct { declaration: N, literal: N, slot: usize, fields: [6]u32 };
pub const Copy = struct { source: N, output: N, source_domain: *const ast.Ast, output_domain: *const ast.Ast, owner: module.SemanticOwnerToken };
pub const ImportEvent = struct { source: N, output: N, literal: N, fields: [6]u32 };
/// A local phase-execution witness, never semantic authority or cache data.
pub const MetadataSeal = struct {
    source_view: *const ast.Ast,
    input_domain: *const ast.Ast,
    output_domain: *const ast.Ast,
    module_pointer: *const module.Module,
    module_index: types.ModuleIndex,
    root: N,
    owner: module.SemanticOwnerToken,
};
const Facts = struct {
    exports_kind: @FieldType(module.Module, "exports_kind"),
    wrap_kind: @FieldType(module.Module, "wrap_kind"),
    side_effects: bool,
    side_effects_user_defined: bool,
    cjs: bool,
    esmodule: bool,
    context_dependency: bool,
    fn capture(m: *const module.Module) Facts {
        return .{ .exports_kind = m.exports_kind, .wrap_kind = m.wrap_kind, .side_effects = m.side_effects, .side_effects_user_defined = m.side_effects_user_defined, .cjs = m.has_cjs_export_signal, .esmodule = m.has_esmodule_marker, .context_dependency = m.is_context_dep };
    }
};
pub const Source = struct {
    module_pointer: *const module.Module,
    module_index: types.ModuleIndex,
    // The actual payload address is authority; this immutable header is only a
    // read view. Its backing belongs to parse_arena, which outlives stage two.
    input_domain: *const ast.Ast,
    view: *const ast.Ast,
    output: ?*const ast.Ast = null,
    owner: module.SemanticOwnerToken = .unassigned,
    root: N,
    metadata: Meta,
    source_scope: scope.Scope,
    facts: Facts,
    nodes: []const u32 = &.{},
    node_mask: []const bool = &.{},
    record_slots: []const ?usize = &.{},
    imports: []const Import = &.{},
    records: []const ImportRecord = &.{},
    dependencies: []const types.ModuleIndex = &.{},
    unresolved: []const []const u8 = &.{},
    pub fn deinit(self: Source, a: std.mem.Allocator) void {
        for (self.records) |record| freeRecord(a, record);
        for (self.unresolved) |name| a.free(name);
        a.free(self.unresolved);
        a.free(self.dependencies);
        a.free(self.records);
        a.free(self.imports);
        a.free(self.nodes);
        a.free(self.node_mask);
        a.free(self.record_slots);
        // Do not deinit view: its arrays are borrowed source allocations.
        a.destroy(self.view);
    }
};
fn fields(t: *const ast.Ast, node: N) ?[6]u32 {
    if (node.isNone() or @backingInt(node) >= t.nodes.items.len) return null;
    const n = t.getNode(node);
    if (n.tag != .import_declaration or !t.hasExtra(n.data.extra, 5)) return null;
    return t.extra_data.items[n.data.extra..][0..6].*;
}
fn allowed(tag: ast.Node.Tag) bool {
    return switch (tag) {
        .program,
        .import_declaration,
        .identifier_reference,
        .static_member_expression,
        .computed_member_expression,
        .binary_expression,
        .assignment_expression,
        .expression_statement,
        .call_expression,
        .numeric_literal,
        .string_literal,
        .null_literal,
        .boolean_literal,
        .empty_statement,
        .parenthesized_expression,
        => true,
        else => false,
    };
}
fn ownedRecord(a: std.mem.Allocator, value: ImportRecord) !ImportRecord {
    var out = value;
    inline for (@typeInfo(ImportRecord).@"struct".field_names) |field_name| {
        const T = @FieldType(ImportRecord, field_name);
        if (T == []const u8) @field(out, field_name) = &.{} else if (T == ?[]const u8) @field(out, field_name) = null;
    }
    errdefer freeRecord(a, out);
    // All slice-valued metadata is owned payload, never a record selector.
    inline for (@typeInfo(ImportRecord).@"struct".field_names) |field_name| {
        const T = @FieldType(ImportRecord, field_name);
        if (T == []const u8) {
            @field(out, field_name) = try a.dupe(u8, @field(value, field_name));
        } else if (T == ?[]const u8) {
            @field(out, field_name) = if (@field(value, field_name)) |bytes| try a.dupe(u8, bytes) else null;
        } else if (T == ?[]const []const u8) {
            if (@field(value, field_name) != null) return error.InvalidEntryRecord;
        } else if (T == []const ?[]const u8) {
            if (@field(value, field_name).len != 0) return error.InvalidEntryRecord;
        }
    }
    return out;
}
fn freeRecord(a: std.mem.Allocator, value: ImportRecord) void {
    inline for (@typeInfo(ImportRecord).@"struct".field_names) |field_name| {
        const T = @FieldType(ImportRecord, field_name);
        if (T == []const u8) {
            a.free(@field(value, field_name));
        } else if (T == ?[]const u8) {
            if (@field(value, field_name)) |bytes| a.free(bytes);
        }
    }
}
fn payloadEqual(comptime T: type, left: T, right: T) bool {
    switch (@typeInfo(T)) {
        .optional => |info| {
            if (left) |l| return if (right) |r| payloadEqual(info.child, l, r) else false;
            return right == null;
        },
        .pointer => |info| {
            if (info.size != .slice) return left == right;
            if (left.len != right.len) return false;
            for (left, right) |l, r| if (!payloadEqual(info.child, l, r)) return false;
            return true;
        },
        else => return std.meta.eql(left, right),
    }
}
fn sameRecord(left: ImportRecord, right: ImportRecord, actual_literal: N) bool {
    inline for (@typeInfo(ImportRecord).@"struct".field_names) |field_name| {
        if (comptime std.mem.eql(u8, field_name, "source_node")) {
            if (right.source_node != actual_literal) return false;
        } else if (!payloadEqual(@FieldType(ImportRecord, field_name), @field(left, field_name), @field(right, field_name))) return false;
    }
    return true;
}
pub fn forModule(a: std.mem.Allocator, m: *const module.Module, opts: Options) !?Source {
    if (m.ast == null or m.semantic == null or m.module_type != .js or m.exports_kind != .esm or m.has_cjs_export_signal or m.has_esmodule_marker or
        m.is_context_dep or m.context_expansion_deps.len != 0 or m.import_records.len == 0 or m.import_bindings.len != 0 or m.export_bindings.len != 0 or m.dynamic_imports.items.len != 0 or
        opts.minify_syntax or !opts.strip_types or opts.react_refresh or opts.emotion or opts.styled_components or
        opts.define.len != 0 or opts.drop_console or opts.drop_debugger or opts.drop_labels.len != 0 or
        opts.module_specifier_map.len != 0) return null;
    const tree = &m.ast.?;
    const sem = &m.semantic.?;
    if (tree.nodes.items.len == 0 or tree.is_typescript or tree.has_jsx or tree.has_decorator or tree.has_flow_enum_declaration or
        opts.unsupportedGraphPrePassFeatureUsed(tree) or sem.symbols.items.len != 0 or sem.references.len != 0 or
        sem.scopes.len != 1 or sem.scopes[0].blocksMangling() or sem.scopes[0].parent != .none or
        (sem.scopes[0].kind != .module and sem.scopes[0].kind != .global)) return null;
    for (sem.symbol_ids) |id| if (id != null) return null;
    const root: N = tree.transformed_root orelse @fromBackingInt(@as(u32, @intCast(tree.nodes.items.len - 1)));
    if (root.isNone() or @backingInt(root) >= tree.nodes.items.len or tree.getNode(root).tag != .program or sem.scope_owner_map.count() != 1 or sem.scope_owner_map.get(@backingInt(root)) != 0) return null;
    const view = try a.create(ast.Ast);
    view.* = tree.*;
    var out: Source = .{ .module_pointer = m, .module_index = m.index, .input_domain = tree, .view = view, .root = root, .metadata = Meta.capture(tree), .source_scope = sem.scopes[0], .facts = Facts.capture(m) };
    var transferred = false;
    defer if (!transferred) out.deinit(a);
    out.nodes = try walk.collectReachableNodeIndicesFrom(a, tree, root);
    const mask = try a.alloc(bool, tree.nodes.items.len);
    @memset(mask, false);
    out.node_mask = mask;
    for (out.nodes) |raw| {
        if (raw >= tree.nodes.items.len or !allowed(tree.nodes.items[raw].tag)) return null;
        mask[raw] = true;
    }
    const record_slots = try a.alloc(?usize, tree.nodes.items.len);
    @memset(record_slots, null);
    out.record_slots = record_slots;
    // Exactly one source literal identity per source record, in source order.
    for (m.import_records, 0..) |item, index| {
        if (item.source_node.isNone() or @backingInt(item.source_node) >= record_slots.len or item.kind != .side_effect) return null;
        const raw = @backingInt(item.source_node);
        if (record_slots[raw] != null) return null;
        record_slots[raw] = index;
    }
    var imports: std.ArrayListUnmanaged(Import) = .empty;
    defer imports.deinit(a);
    const program = tree.getNode(root);
    if (program.data.list.start > tree.extra_data.items.len or program.data.list.len > tree.extra_data.items.len - program.data.list.start) return null;
    for (tree.extra_data.items[program.data.list.start..][0..program.data.list.len]) |raw| {
        const node: N = @fromBackingInt(raw);
        if (tree.getNode(node).tag != .import_declaration) continue;
        const f = fields(tree, node) orelse return null;
        const x = @import("../parser/module.zig").readImportDeclExtras(tree, tree.getNode(node).data.extra);
        if (x.is_type_only or x.specs_len != 0 or x.phase != .none or x.attrs_len != 0) return null;
        if (x.source.isNone() or @backingInt(x.source) >= record_slots.len) return null;
        const index = record_slots[@backingInt(x.source)] orelse return null;
        if (index != imports.items.len) return null;
        try imports.append(a, .{ .declaration = node, .literal = x.source, .slot = index, .fields = f });
    }
    if (imports.items.len != m.import_records.len) return null;
    out.imports = try imports.toOwnedSlice(a);
    var records: std.ArrayListUnmanaged(ImportRecord) = .empty;
    errdefer {
        for (records.items) |record| freeRecord(a, record);
        records.deinit(a);
    }
    for (m.import_records) |record| {
        const owned = try ownedRecord(a, record);
        records.append(a, owned) catch |err| {
            freeRecord(a, owned);
            return err;
        };
    }
    out.records = try records.toOwnedSlice(a);
    out.dependencies = try a.dupe(types.ModuleIndex, m.dependencies.items);
    var names: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (names.items) |name| a.free(name);
        names.deinit(a);
    }
    var iter = sem.unresolved_references.keyIterator();
    while (iter.next()) |name| {
        const owned = try a.dupe(u8, name.*);
        names.append(a, owned) catch |err| {
            a.free(owned);
            return err;
        };
    }
    out.unresolved = try names.toOwnedSlice(a);
    transferred = true;
    return out;
}
pub fn preparedMatches(source: *const Source, m: *const module.Module) bool {
    return source.module_pointer == m and source.module_index == m.index and m.ast != null and m.semantic != null and
        source.input_domain == &m.ast.? and source.output == null and source.owner == .unassigned and
        std.meta.eql(source.metadata, Meta.capture(&m.ast.?)) and m.ast.?.nodes.items.ptr == source.view.nodes.items.ptr and
        m.ast.?.extra_data.items.ptr == source.view.extra_data.items.ptr and m.import_records.len == source.records.len;
}
pub fn activate(source: Source, self: anytype, m: *module.Module) ?Source {
    if (!preparedMatches(&source, m) or self.semantic_source_ast != source.input_domain) return null;
    var installed = source;
    installed.output = self.ast;
    installed.owner = m.semantic.?.captureOwnerToken();
    return installed;
}
pub fn recordVisit(self: anytype, input: N, output: N) !void {
    const source = self.entry_graph_source orelse return;
    if (input.isNone() or @backingInt(input) >= source.node_mask.len or !source.node_mask[@backingInt(input)]) return;
    const slot = try self.entry_graph_copy_index.getOrPut(self.allocator, @backingInt(input));
    if (slot.found_existing) {
        self.entry_graph_invalid = true;
        return;
    }
    errdefer _ = self.entry_graph_copy_index.remove(@backingInt(input));
    slot.value_ptr.* = self.entry_graph_copies.items.len;
    try self.entry_graph_copies.append(self.allocator, .{ .source = input, .output = output, .source_domain = source.input_domain, .output_domain = self.ast, .owner = source.owner });
}
pub fn recordImport(self: anytype, input: N, output: N) !void {
    const source = self.entry_graph_source orelse return;
    const next = self.entry_graph_imports.items.len;
    if (next >= source.imports.len or source.imports[next].declaration != input) {
        self.entry_graph_invalid = true;
        return;
    }
    const f = fields(self.ast, output) orelse {
        self.entry_graph_invalid = true;
        return;
    };
    try self.entry_graph_imports.append(self.allocator, .{ .source = input, .output = output, .literal = @fromBackingInt(f[2]), .fields = f });
}

fn payloadSame(a: *const ast.Ast, x: ast.Node, b: *const ast.Ast, y: ast.Node) bool {
    if (x.tag != y.tag or !std.meta.eql(x.span, y.span)) return false;
    switch (ast.Node.Tag.dataKind(x.tag)) {
        .leaf => return std.mem.eql(u8, std.mem.asBytes(&x.data)[0..ast.Node.Tag.dataWidth(x.tag)], std.mem.asBytes(&y.data)[0..ast.Node.Tag.dataWidth(y.tag)]),
        .unary => return x.data.unary.flags == y.data.unary.flags,
        .binary => return x.data.binary.flags == y.data.binary.flags,
        .ternary => return true,
        .list => return x.data.list.len == y.data.list.len,
        .extra => {
            const len = ast.Node.Tag.runtimeExtraWords(x.tag) orelse return false;
            if (!a.hasExtra(x.data.extra, len - 1) or !b.hasExtra(y.data.extra, len - 1)) return false;
            for (0..len) |i| {
                if (std.mem.indexOfScalar(u8, ast.Node.Tag.extraChildOffsets(x.tag), @intCast(i)) != null) continue;
                var list_start = false;
                for (ast.Node.Tag.extraListOffsets(x.tag)) |offset| if (offset[0] == i) {
                    list_start = true;
                };
                if (!list_start and a.extra_data.items[x.data.extra + i] != b.extra_data.items[y.data.extra + i]) return false;
            }
            return true;
        },
    }
}
fn sameStorage(left: anytype, right: @TypeOf(left)) bool {
    return left.ptr == right.ptr and left.len == right.len;
}
pub fn requirementSatisfied(self: anytype, prepared: ?*const Source) bool {
    const expected = prepared orelse return true;
    const installed = self.entry_graph_source orelse return false;
    return installed.module_pointer == expected.module_pointer and installed.module_index == expected.module_index and
        installed.input_domain == expected.input_domain and installed.view == expected.view and installed.root == expected.root and
        installed.output == self.ast and installed.input_domain == self.semantic_source_ast and installed.owner != .unassigned and
        std.meta.eql(installed.metadata, expected.metadata) and std.meta.eql(installed.facts, expected.facts) and
        std.meta.eql(installed.source_scope, expected.source_scope) and
        sameStorage(installed.nodes, expected.nodes) and sameStorage(installed.node_mask, expected.node_mask) and
        sameStorage(installed.record_slots, expected.record_slots) and
        sameStorage(installed.imports, expected.imports) and sameStorage(installed.records, expected.records) and
        sameStorage(installed.dependencies, expected.dependencies) and sameStorage(installed.unresolved, expected.unresolved);
}
fn mapped(self: anytype, input: N) ?N {
    const index = self.entry_graph_copy_index.get(@backingInt(input)) orelse return null;
    if (index >= self.entry_graph_copies.items.len or self.entry_graph_copies.items[index].source != input) return null;
    return self.entry_graph_copies.items[index].output;
}
fn domainValid(self: anytype, source: Source) bool {
    const m = source.module_pointer;
    return m.index == source.module_index and m.semantic != null and m.semantic.?.owner_token == source.owner and
        source.output == self.ast and source.input_domain == self.semantic_source_ast and source.input_domain != self.ast and
        std.meta.eql(source.metadata, Meta.capture(source.view)) and std.meta.eql(source.metadata, Meta.capture(self.ast));
}
const Pair = struct { input: N, output: N };
fn shape(self: anytype, source: Source, root: N) !bool {
    if (self.entry_graph_invalid or self.entry_graph_copies.items.len != self.entry_graph_copy_index.count() or mapped(self, source.root) != root) return false;
    for (self.entry_graph_copies.items, 0..) |copy, index| {
        if (self.entry_graph_copy_index.get(@backingInt(copy.source)) != index or
            copy.source_domain != source.input_domain or copy.output_domain != self.ast or copy.owner != source.owner) return false;
    }
    var todo: std.ArrayListUnmanaged(Pair) = .empty;
    defer todo.deinit(self.allocator);
    var seen: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer seen.deinit(self.allocator);
    try todo.append(self.allocator, .{ .input = source.root, .output = root });
    while (todo.pop()) |pair| {
        if (pair.input.isNone() or pair.output.isNone()) {
            if (pair.input != pair.output) return false;
            continue;
        }
        if (@backingInt(pair.input) >= source.view.nodes.items.len or @backingInt(pair.output) >= self.ast.nodes.items.len) return false;
        if (seen.get(@backingInt(pair.input))) |old| {
            if (old != @backingInt(pair.output)) return false;
            continue;
        }
        try seen.put(self.allocator, @backingInt(pair.input), @backingInt(pair.output));
        if (mapped(self, pair.input)) |known| {
            if (known != pair.output) return false;
        } else if (pair.input != pair.output) return false;
        const input = source.view.getNode(pair.input);
        const output = self.ast.getNode(pair.output);
        if (!payloadSame(source.view, input, self.ast, output)) return false;
        var left = walk.children(source.view, input);
        var right = walk.children(self.ast, output);
        while (left.next()) |child| try todo.append(self.allocator, .{ .input = child, .output = right.next() orelse return false });
        if (right.next() != null) return false;
    }
    if (seen.count() != source.nodes.len) return false;
    for (self.entry_graph_copies.items) |copy| if (seen.get(@backingInt(copy.source)) != @backingInt(copy.output)) return false;
    if (self.entry_graph_imports.items.len != source.imports.len) return false;
    var indexed: usize = 0;
    for (source.record_slots, 0..) |slot, raw| if (slot) |index| {
        if (index >= source.records.len or @backingInt(source.records[index].source_node) != raw) return false;
        indexed += 1;
    };
    if (indexed != source.imports.len or source.records.len != source.imports.len) return false;
    // Events come from the actual import creator, not the general copy hook.
    for (source.imports, self.entry_graph_imports.items) |expected, event| {
        if (expected.literal.isNone() or @backingInt(expected.literal) >= source.record_slots.len or
            source.record_slots[@backingInt(expected.literal)] != expected.slot or
            expected.declaration != event.source or mapped(self, expected.declaration) != event.output or
            (mapped(self, expected.literal) orelse expected.literal) != event.literal) return false;
        const actual = fields(self.ast, event.output) orelse return false;
        if (!std.meta.eql(actual, event.fields) or actual[1] != 0 or actual[3] != expected.fields[3] or
            actual[4] != expected.fields[4] or actual[5] != expected.fields[5]) return false;
    }
    return true;
}
fn emptyIdentity(source: Source, sem: *const module.ModuleSemanticData) bool {
    if (sem.symbols.items.len != 0 or sem.references.len != 0 or sem.scopes.len != 1 or
        !std.meta.eql(source.source_scope, sem.scopes[0]) or sem.unresolved_references.count() != source.unresolved.len) return false;
    for (sem.symbol_ids) |id| if (id != null) return false;
    for (source.unresolved) |name| if (!sem.unresolved_references.contains(name)) return false;
    return true;
}
pub fn beforeBinder(self: anytype, root: N) !bool {
    const source = self.entry_graph_source orelse return false;
    if (!domainValid(self, source)) return false;
    const refs = if (self.semantic_editor) |*e| e.references.items else self.references;
    const syms = if (self.semantic_editor) |*e| e.symbols.items else self.symbols;
    const scopes = if (self.semantic_editor) |*e| e.scopes.items else self.scopes;
    if (refs.len != 0 or syms.len != 0 or scopes.len != 1 or !std.meta.eql(source.source_scope, scopes[0])) return false;
    for (self.symbol_ids.items) |id| if (id != null) return false;
    if (self.outputOwnedScope(root)) |owner| {
        if (@backingInt(owner) != 0) return false;
    } else return false;
    return shape(self, source, root);
}
pub fn complete(self: anytype, sem: *const module.ModuleSemanticData, root: N) !bool {
    const source = self.entry_graph_source orelse return false;
    if (!self.entry_graph_before_binder or self.entry_graph_before_binder_root != root or !domainValid(self, source) or
        !emptyIdentity(source, sem) or sem.scope_owner_map.count() != 1 or sem.scope_owner_map.get(@backingInt(root)) != 0) return false;
    return shape(self, source, root);
}
/// This is the second proof, at the successful metadata-rescan boundary only.
/// Resolution/discovery may legitimately change these records later.
pub fn afterMetadata(self: anytype, m: *const module.Module, root: N) !bool {
    const source = self.entry_graph_source orelse return false;
    if (source.module_pointer != m or m.index != source.module_index or m.ast == null or m.semantic == null or
        m.ast.?.nodes.items.ptr != self.ast.nodes.items.ptr or m.ast.?.nodes.items.len != self.ast.nodes.items.len or
        m.ast.?.extra_data.items.ptr != self.ast.extra_data.items.ptr or m.ast.?.extra_data.items.len != self.ast.extra_data.items.len or
        m.ast.?.transformed_root != root or !std.meta.eql(source.facts, Facts.capture(m)) or
        m.is_context_dep or m.context_expansion_deps.len != 0 or m.import_bindings.len != 0 or m.export_bindings.len != 0 or m.dynamic_imports.items.len != 0 or m.import_records.len != source.records.len or
        !payloadEqual([]const types.ModuleIndex, source.dependencies, m.dependencies.items) or
        !try complete(self, &m.semantic.?, root)) return false;
    for (source.records, self.entry_graph_imports.items, m.import_records) |original, event, actual| {
        if (!sameRecord(original, actual, event.literal)) return false;
    }
    return true;
}

/// Validate first. A rejected publication leaves the prior seal and graph intact.
pub fn publishMetadataCompletion(self: anytype, m: *const module.Module, root: N) !bool {
    if (!try afterMetadata(self, m, root)) return false;
    const source = self.entry_graph_source orelse return false;
    self.entry_graph_metadata_seal = .{
        .source_view = source.view,
        .input_domain = source.input_domain,
        .output_domain = self.ast,
        .module_pointer = m,
        .module_index = m.index,
        .root = root,
        .owner = source.owner,
    };
    return true;
}
/// A stale seal cannot authorize changed metadata or a foreign current domain.
pub fn metadataRequirementSatisfied(self: anytype, m: *const module.Module, root: N) !bool {
    const source = self.entry_graph_source orelse return false;
    const seal = self.entry_graph_metadata_seal orelse return false;
    if (seal.source_view != source.view or seal.input_domain != source.input_domain or
        seal.output_domain != self.ast or seal.module_pointer != m or seal.module_index != m.index or
        seal.root != root or seal.owner != source.owner) return false;
    return afterMetadata(self, m, root);
}
