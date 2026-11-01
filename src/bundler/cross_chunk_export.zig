//! The public export selects a producer carrier; lexical names never select SIDs.
const std = @import("std");
const ast_mod = @import("../parser/ast.zig");
const Ast = ast_mod.Ast;
const NodeIndex = ast_mod.NodeIndex;
const Module = @import("module.zig").Module;
const ExportBinding = @import("binding_scanner.zig").ExportBinding;
const SymbolRef = @import("symbol.zig").SymbolRef;
const Span = @import("../lexer/token.zig").Span;
const parser_module = @import("../parser/module.zig");
const Linker = @import("linker.zig").Linker;
const SymbolID = @import("symbol.zig").SymbolID;
const Symbol = @import("../semantic/symbol.zig").Symbol;
const SemanticOwnerToken = @import("module.zig").SemanticOwnerToken;

pub const Error = @import("module.zig").WrapperNameError || error{ InvalidCrossChunkExport, InvalidCrossChunkLocalName };

const output = @import("codegen_output_domain.zig");
pub const Hint = union(enum) { ordinary_export, shared_namespace: output.Ref };

/// Captured by the cross-chunk edge producer, before any output-name lookup.
/// Namespace storage remains its existing output-owned cache contract (N5).
/// It is deliberately not represented by an invented source SymbolId.
pub const Provider = struct {
    pub const KnownBinding = struct {
        binding: *const ExportBinding,
        original: ExportBinding,
        symbol: Symbol,
        anchor: ?NodeIndex,
    };
    const KnownNamespace = struct { reference: output.Ref, symbol: output.Symbol };
    const Role = union(enum) {
        semantic: KnownBinding,
        entry_guard: KnownBinding,
        cjs_member: SymbolID,
        shared_namespace: KnownNamespace,
        namespace_projection: struct { binding: *const ExportBinding, original: ExportBinding, target: *const Module, storage: KnownNamespace },
        graphless,
    };
    owner: *const Module,
    public_name: []const u8,
    owner_token: SemanticOwnerToken,
    role: Role,

    fn make(owner: *const Module, name: []const u8, role: Role) Error!Provider {
        const token = if (owner.semantic) |sem| sem.owner_token else .unassigned;
        if (owner.semantic != null and token == .unassigned) return error.InvalidCrossChunkExport;
        return .{ .owner = owner, .public_name = name, .owner_token = token, .role = role };
    }

    fn knownBinding(owner: *const Module, binding: *const ExportBinding) Error!KnownBinding {
        const sid = owner.exportBindingSemanticIndex(binding.*) orelse return error.InvalidCrossChunkExport;
        const sem = owner.semantic orelse return error.InvalidCrossChunkExport;
        return .{
            .binding = binding,
            .original = binding.*,
            .symbol = sem.symbols.items[sid],
            .anchor = if (binding.has_default_export_facade) binding.default_export_node else binding.local_symbol_node,
        };
    }

    fn validateKnown(self: Provider, known: KnownBinding) Error!void {
        if (!registered(self.owner, known.binding) or !std.meta.eql(known.binding.*, known.original) or
            !std.mem.eql(u8, known.original.exported_name, self.public_name)) return error.InvalidCrossChunkExport;
        const sem = self.owner.semantic orelse return error.InvalidCrossChunkExport;
        const sid = self.owner.exportBindingSemanticIndex(known.original) orelse return error.InvalidCrossChunkExport;
        const actual = sem.symbols.items[sid];
        var expected = known.symbol;
        // Exact edits may change use counts while preserving the same binding.
        expected.reference_count = actual.reference_count;
        expected.write_count = actual.write_count;
        if (!std.meta.eql(expected, actual)) return error.InvalidCrossChunkExport;
        if (known.anchor) |anchor| {
            if (!attached(sem.symbol_ids, anchor, sid)) return error.InvalidCrossChunkExport;
            // Export erasure may replace the wrapper payload during emission.
            // Its producer receipt still owns the same SID and declaration.
            if (!known.original.has_default_export_facade) {
                const ast = if (self.owner.ast) |*value| value else return error.InvalidCrossChunkExport;
                const node = nodeAt(ast, anchor) orelse return error.InvalidCrossChunkExport;
                if (node.tag != .binding_identifier and node.tag != .identifier_reference) return error.InvalidCrossChunkExport;
                const span = if (node.data.string_ref.start & Ast.STRING_TABLE_BIT != 0) node.data.string_ref else node.span;
                const source_name = self.owner.symbolName(@fromBackingInt(sid)) orelse return error.InvalidCrossChunkExport;
                if (!validSpan(ast, span) or !@import("../lexer/scanner.zig").Scanner.identifierNamesEqual(ast.identifierNameText(node), source_name)) return error.InvalidCrossChunkExport;
            }
        }
    }

    pub fn capture(l: *const Linker, module_index: u32, name: []const u8, hint: Hint) Error!Provider {
        const owner = l.getModule(module_index) orelse return error.InvalidCrossChunkExport;
        if (hint == .shared_namespace) {
            const reference = hint.shared_namespace;
            if (reference.module != owner.index) return error.InvalidCrossChunkExport;
            const known = try captureNamespace(l, reference);
            const initial_name = l.sharedNamespaceInitialName(reference) orelse return error.InvalidCrossChunkExport;
            const alias = l.getSharedNamespaceGlobalName(reference);
            if (!std.mem.eql(u8, name, initial_name) and (alias == null or !std.mem.eql(u8, name, alias.?))) return error.InvalidCrossChunkExport;
            return make(owner, name, .{ .shared_namespace = known });
        }
        if (owner.semantic == null and owner.ast == null) {
            return make(owner, name, .graphless);
        }
        if (owner.wrap_kind == .cjs) {
            const sid = owner.require_symbol orelse return error.InvalidCrossChunkExport;
            const sem = owner.semantic orelse return error.InvalidCrossChunkExport;
            if (@backingInt(sid) >= sem.symbols.items.len or
                sem.symbols.items[@backingInt(sid)].synthetic_kind != .cjs_require or
                owner.getRequireName(null) == null) return error.InvalidCrossChunkExport;
            return make(owner, name, .{ .cjs_member = SymbolID.make(owner.index, @backingInt(sid)) });
        }
        const binding = owner.findExportBinding(name) orelse return error.InvalidCrossChunkExport;
        if (l.graph.entry_guard_ast_provider) |guard| if (guard.module_index == owner.index) {
            const exact = @import("runtime_entry_guard_ast.zig").exactBinding(l.graph) catch return error.InvalidCrossChunkExport;
            if (!binding.symbol.eql(SymbolRef.makeSemantic(exact.module, @backingInt(exact.inner)))) return error.InvalidCrossChunkExport;
            return make(owner, name, .{ .entry_guard = try knownBinding(owner, binding) });
        };
        if (@import("chunk.zig").nsReExportTarget(l.graph, owner.index, name)) |target| {
            if (binding.kind == .local) _ = try checkedSymbol(l.allocator, owner, binding);
            const target_owner = l.graph.getModule(target) orelse return error.InvalidCrossChunkExport;
            _ = try l.ensureSharedNsVar(target);
            const output_ref = l.sharedNamespaceOutputRef(target) orelse return error.InvalidCrossChunkExport;
            return make(owner, name, .{ .namespace_projection = .{
                .binding = binding,
                .original = binding.*,
                .target = target_owner,
                .storage = try captureNamespace(l, output_ref),
            } });
        }
        _ = try checkedSymbol(l.allocator, owner, binding);
        return make(owner, name, .{ .semantic = try knownBinding(owner, binding) });
    }

    pub fn validate(self: Provider, l: *const Linker) Error!void {
        if (l.getModule(self.owner.index.toU32()) != self.owner) return error.InvalidCrossChunkExport;
        if (self.owner.semantic) |sem| {
            if (self.owner_token == .unassigned or sem.owner_token != self.owner_token) return error.InvalidCrossChunkExport;
        } else if (self.owner_token != .unassigned) return error.InvalidCrossChunkExport;
        switch (self.role) {
            .semantic, .entry_guard => |known| try self.validateKnown(known),
            .cjs_member => |known| {
                const sid = self.owner.require_symbol orelse return error.InvalidCrossChunkExport;
                const sem = self.owner.semantic orelse return error.InvalidCrossChunkExport;
                if (self.owner.wrap_kind != .cjs or known.module != self.owner.index or
                    @backingInt(known.inner) != @backingInt(sid) or @backingInt(sid) >= sem.symbols.items.len or
                    sem.symbols.items[@backingInt(sid)].synthetic_kind != .cjs_require or
                    self.owner.getRequireName(null) == null) return error.InvalidCrossChunkExport;
            },
            .shared_namespace => |known| {
                if (known.reference.module != self.owner.index) return error.InvalidCrossChunkExport;
                try validateNamespace(l, known);
            },
            .namespace_projection => |known| {
                if (!registered(self.owner, known.binding) or !std.meta.eql(known.binding.*, known.original) or !std.mem.eql(u8, self.public_name, known.original.exported_name) or
                    l.getModule(known.target.index.toU32()) != known.target or
                    @import("chunk.zig").nsReExportTarget(l.graph, self.owner.index, self.public_name) != known.target.index) return error.InvalidCrossChunkExport;
                if (known.original.kind == .local) _ = try checkedSymbol(l.allocator, self.owner, known.binding);
                if (known.storage.reference.module != known.target.index) return error.InvalidCrossChunkExport;
                try validateNamespace(l, known.storage);
            },
            .graphless => if (self.owner.semantic != null or self.owner.ast != null) return error.InvalidCrossChunkExport,
        }
    }

    fn captureNamespace(l: *const Linker, reference: output.Ref) Error!KnownNamespace {
        const actual = l.sharedNamespaceOutputRef(reference.module) orelse return error.InvalidCrossChunkExport;
        if (!std.meta.eql(actual, reference)) return error.InvalidCrossChunkExport;
        return .{ .reference = reference, .symbol = l.sharedNamespaceOutputSymbol(reference) orelse return error.InvalidCrossChunkExport };
    }

    fn validateNamespace(l: *const Linker, known: KnownNamespace) Error!void {
        const actual = try captureNamespace(l, known.reference);
        if (actual.symbol.role != known.symbol.role or actual.symbol.abi != known.symbol.abi or
            !std.mem.eql(u8, actual.symbol.logical_name, known.symbol.logical_name)) return error.InvalidCrossChunkExport;
    }

    /// Only the holder declaration itself participates in holder-name allocation;
    /// namespace projections retain their separate public export-key contracts.
    pub fn namespaceOutputRef(self: Provider, l: *const Linker) Error!?output.Ref {
        if (self.role != .shared_namespace) return null;
        try self.validate(l);
        return self.role.shared_namespace.reference;
    }

    pub fn localName(self: Provider, l: *const Linker) Error!?[]const u8 {
        try self.validate(l);
        const name: ?[]const u8 = switch (self.role) {
            .semantic, .entry_guard => |known| blk: {
                const sid = known.original.symbol.semanticIndex() orelse return error.InvalidCrossChunkExport;
                break :blk l.getCanonicalByRef(known.original.symbol) orelse
                    self.owner.symbolName(@fromBackingInt(sid)) orelse return error.InvalidCrossChunkExport;
            },
            .shared_namespace => |known| l.sharedNamespaceEmittedName(known.reference) orelse return error.InvalidCrossChunkExport,
            .namespace_projection => |known| l.sharedNamespaceEmittedName(known.storage.reference) orelse return error.InvalidCrossChunkExport,
            .cjs_member => null,
            .graphless => self.public_name,
        };
        if (name) |text| if (self.role == .semantic or self.role == .entry_guard) {
            const decoded = try @import("../lexer/scanner.zig").Scanner.decodeIdentifierEscapesAlloc(l.allocator, text);
            defer if (decoded.ptr != text.ptr) l.allocator.free(decoded);
            if (!@import("linker/identifier_name.zig").isIdentifierName(decoded) or Linker.isReservedName(decoded)) return error.InvalidCrossChunkLocalName;
        };
        return name;
    }
};

pub fn checkedSymbol(a: std.mem.Allocator, owner: *const Module, binding: *const ExportBinding) Error!SymbolRef {
    if (!registered(owner, binding)) return error.InvalidCrossChunkExport;
    const ast = if (owner.ast) |*value| value else return error.InvalidCrossChunkExport;
    const sem = owner.semantic orelse return error.InvalidCrossChunkExport;
    const sid = owner.exportBindingSemanticIndex(binding.*) orelse return error.InvalidCrossChunkExport;
    if (sem.symbols.items[sid].kind == .import_binding) {
        var matches: usize = 0;
        for (owner.import_bindings) |imported| {
            if (!imported.local_symbol.eql(binding.symbol)) continue;
            _ = owner.checkedImportBindingLocalName(imported) catch return error.InvalidCrossChunkExport;
            matches += 1;
        }
        if (matches != 1) return error.InvalidCrossChunkExport;
    }
    const source = binding.source_export_node orelse return error.InvalidCrossChunkExport;
    const statement = nodeAt(ast, source) orelse return error.InvalidCrossChunkExport;
    if (statement.tag == .export_default_declaration) {
        if (binding.kind != .local or binding.default_export_node != source or
            !std.mem.eql(u8, binding.exported_name, "default") or
            parser_module.defaultExportNeedsFacade(ast, statement.data.unary.operand, statement.data.unary.flags) != binding.has_default_export_facade) return error.InvalidCrossChunkExport;
        const anchor = if (binding.has_default_export_facade) source else binding.local_symbol_node orelse return error.InvalidCrossChunkExport;
        const anchor_node = nodeAt(ast, anchor) orelse return error.InvalidCrossChunkExport;
        // Class lowering can publish the live named declaration separately
        // and leave this exact reference in its original default wrapper.
        // The parser's named-declaration flag distinguishes it from a snapshot.
        const lowered_named_reference = !binding.has_default_export_facade and
            statement.data.unary.flags & parser_module.EXPORT_DEFAULT_NAMED_DECLARATION != 0 and
            anchor == statement.data.unary.operand and
            anchor_node.tag == .identifier_reference and
            sem.symbols.items[sid].decl_flags.is_exported and sem.symbols.items[sid].decl_flags.is_default_export;
        if (!binding.has_default_export_facade and !lowered_named_reference and
            !try declarationContains(a, ast, statement.data.unary.operand, anchor)) return error.InvalidCrossChunkExport;
        if (!attached(sem.symbol_ids, anchor, sid)) return error.InvalidCrossChunkExport;
        return binding.symbol;
    }
    if (statement.tag != .export_named_declaration or !ast.hasExtra(statement.data.extra, 4)) return error.InvalidCrossChunkExport;
    const extra = statement.data.extra;
    const declaration = ast.readExtraNode(extra, 0);
    const source_node = ast.readExtraNode(extra, 3);
    if (binding.source_declaration_node) |known| {
        if (binding.kind != .local or known != declaration or !source_node.isNone() or binding.source_specifier_node != null) return error.InvalidCrossChunkExport;
        const anchor = binding.local_symbol_node orelse return error.InvalidCrossChunkExport;
        if (!attached(sem.symbol_ids, anchor, sid) or !try declarationContains(a, ast, known, anchor) or
            !try keyMatches(a, ast, anchor, binding.exported_name)) return error.InvalidCrossChunkExport;
        return binding.symbol;
    }
    const known_specifier = binding.source_specifier_node orelse return error.InvalidCrossChunkExport;
    const specifier = nodeAt(ast, known_specifier) orelse return error.InvalidCrossChunkExport;
    const start = ast.extra_data.items[extra + 1];
    const len = ast.extra_data.items[extra + 2];
    if (!declaration.isNone() or start > ast.extra_data.items.len or len > ast.extra_data.items.len - start or
        specifier.tag != .export_specifier or specifier.data.binary.flags & parser_module.SPEC_FLAG_TYPE_ONLY != 0) return error.InvalidCrossChunkExport;
    var matches: usize = 0;
    for (ast.extra_data.items[start..][0..len]) |raw| if (raw == @backingInt(known_specifier)) {
        matches += 1;
    };
    if (matches != 1) return error.InvalidCrossChunkExport;
    const public_node = if (specifier.data.binary.right.isNone()) specifier.data.binary.left else specifier.data.binary.right;
    if (!try keyMatches(a, ast, public_node, binding.exported_name)) return error.InvalidCrossChunkExport;
    if (binding.kind == .local) {
        const anchor = binding.local_symbol_node orelse return error.InvalidCrossChunkExport;
        if (!source_node.isNone() or anchor != specifier.data.binary.left or !attached(sem.symbol_ids, anchor, sid)) return error.InvalidCrossChunkExport;
    } else {
        // This exact source re-export births a compiler-owned default bridge.
        // Its runtime SID is registered once; no source node is invented for it.
        if (binding.kind != .re_export or !binding.hasSyntheticDefault(sem.symbols.items) or
            !std.mem.eql(u8, binding.exported_name, "default")) return error.InvalidCrossChunkExport;
        const record_index = binding.import_record_index orelse return error.InvalidCrossChunkExport;
        if (record_index >= owner.import_records.len or source_node.isNone() or
            owner.import_records[record_index].source_node != source_node) return error.InvalidCrossChunkExport;
        const source_literal = nodeAt(ast, source_node) orelse return error.InvalidCrossChunkExport;
        if (source_literal.tag != .string_literal) return error.InvalidCrossChunkExport;
    }
    return binding.symbol;
}

fn registered(owner: *const Module, binding: *const ExportBinding) bool {
    if (owner.export_bindings.len == 0) return false;
    const begin = @intFromPtr(owner.export_bindings.ptr);
    const address = @intFromPtr(binding);
    return address >= begin and (address - begin) % @sizeOf(ExportBinding) == 0 and
        (address - begin) / @sizeOf(ExportBinding) < owner.export_bindings.len;
}

fn nodeAt(ast: *const Ast, index: NodeIndex) ?ast_mod.Node {
    if (index.isNone() or @backingInt(index) >= ast.nodes.items.len) return null;
    return ast.getNode(index);
}

fn attached(ids: []const ?u32, index: NodeIndex, sid: u32) bool {
    return !index.isNone() and @backingInt(index) < ids.len and ids[@backingInt(index)] == sid;
}

fn declarationContains(a: std.mem.Allocator, ast: *const Ast, declaration: NodeIndex, anchor: NodeIndex) Error!bool {
    const node = nodeAt(ast, declaration) orelse return false;
    switch (node.tag) {
        .function_declaration, .class_declaration => return ast.hasExtra(node.data.extra, 1) and ast.readExtraNode(node.data.extra, 0) == anchor,
        .variable_declaration => {
            if (!ast.hasExtra(node.data.extra, 3)) return false;
            const start = ast.extra_data.items[node.data.extra + 1];
            const len = ast.extra_data.items[node.data.extra + 2];
            if (start > ast.extra_data.items.len or len > ast.extra_data.items.len - start) return false;
            var matches: usize = 0;
            for (ast.extra_data.items[start..][0..len]) |raw| {
                const item = nodeAt(ast, @fromBackingInt(raw)) orelse return false;
                if (item.tag != .variable_declarator or !ast.hasExtra(item.data.extra, 1)) return false;
                var walker = try @import("../parser/ast_walk.zig").bindingIdentifiers(a, ast, ast.readExtraNode(item.data.extra, 0), .{});
                defer walker.deinit();
                while (try walker.next()) |binding| if (binding == anchor) {
                    matches += 1;
                };
            }
            return matches == 1;
        },
        else => return false,
    }
}

fn keyMatches(a: std.mem.Allocator, ast: *const Ast, index: NodeIndex, expected: []const u8) Error!bool {
    const node = nodeAt(ast, index) orelse return false;
    if (node.tag == .identifier_reference or node.tag == .binding_identifier) {
        const span = if (node.data.string_ref.start & Ast.STRING_TABLE_BIT != 0) node.data.string_ref else node.span;
        if (!validSpan(ast, span)) return false;
        return @import("../lexer/scanner.zig").Scanner.identifierValueEquals(ast.identifierNameText(node), expected);
    }
    if (node.tag != .string_literal or !validSpan(ast, node.span)) return false;
    var scratch = std.heap.ArenaAllocator.init(a);
    defer scratch.deinit();
    return std.mem.eql(u8, try parser_module.moduleExportName(scratch.allocator(), ast.getText(node.span)), expected);
}

fn validSpan(ast: *const Ast, span: Span) bool {
    const table = span.start & Ast.STRING_TABLE_BIT != 0;
    if ((span.end & Ast.STRING_TABLE_BIT != 0) != table) return false;
    const start = span.start & ~Ast.STRING_TABLE_BIT;
    const end = span.end & ~Ast.STRING_TABLE_BIT;
    return start <= end and end <= (if (table) ast.string_table.items.len else ast.source.len);
}
