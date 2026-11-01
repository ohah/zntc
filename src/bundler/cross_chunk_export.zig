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
        default_source: ?DefaultFunctionSource = null,
        default_role: ?struct { pointer: *const @import("strict_function_context.zig").Role, before: @import("strict_function_context.zig").Role } = null,
    };
    pub const DefaultFunctionSource = struct {
        binding: ExportBinding,
        symbol: Symbol,
        wrapper: struct { tag: ast_mod.Node.Tag, span: Span, operand: NodeIndex, flags: u16 },
        declaration: NodeIndex,
        function_before: struct { tag: ast_mod.Node.Tag, span: Span, extra: u32 },
        name: NodeIndex,
        parameters: NodeIndex,
        body: NodeIndex,
        flags: u32,
        scope: @import("../semantic/scope.zig").ScopeId,
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
            .default_source = try captureDefaultFunctionSource(owner, binding, sid),
        };
    }

    fn captureDefaultFunctionSource(owner: *const Module, binding: *const ExportBinding, sid: u32) Error!?DefaultFunctionSource {
        if (binding.default_export_node == null) return null;
        const ast = if (owner.ast) |*value| value else return error.InvalidCrossChunkExport;
        const sem = owner.semantic orelse return error.InvalidCrossChunkExport;
        const wrapper = nodeAt(ast, binding.default_export_node orelse return error.InvalidCrossChunkExport) orelse return error.InvalidCrossChunkExport;
        if (wrapper.tag != .export_default_declaration) return error.InvalidCrossChunkExport;
        const declaration = wrapper.data.unary.operand;
        const function = nodeAt(ast, declaration) orelse return error.InvalidCrossChunkExport;
        if (function.tag != .function_declaration) return null;
        if (!ast.hasExtra(function.data.extra, ast_mod.FunctionExtra.flags)) return error.InvalidCrossChunkExport;
        const name = ast.readExtraNode(function.data.extra, ast_mod.FunctionExtra.name);
        if (binding.has_default_export_facade) {
            if (!name.isNone() or wrapper.data.unary.flags != 0) return error.InvalidCrossChunkExport;
        } else if (name.isNone() or binding.local_symbol_node != name or wrapper.data.unary.flags != parser_module.EXPORT_DEFAULT_NAMED_DECLARATION) return error.InvalidCrossChunkExport;
        const scope_raw = sem.scope_owner_map.get(@backingInt(declaration)) orelse return error.InvalidCrossChunkExport;
        if (scope_raw >= sem.scopes.len) return error.InvalidCrossChunkExport;
        return .{ .binding = binding.*, .symbol = sem.symbols.items[sid], .wrapper = .{ .tag = wrapper.tag, .span = wrapper.span, .operand = wrapper.data.unary.operand, .flags = wrapper.data.unary.flags }, .declaration = declaration, .function_before = .{ .tag = function.tag, .span = function.span, .extra = function.data.extra }, .name = name, .parameters = ast.readExtraNode(function.data.extra, ast_mod.FunctionExtra.params), .body = ast.readExtraNode(function.data.extra, ast_mod.FunctionExtra.body), .flags = ast.readExtra(function.data.extra, ast_mod.FunctionExtra.flags), .scope = @fromBackingInt(@as(u32, @intCast(scope_raw))) };
    }

    fn ownsStrictRole(sem: anytype, role: *const @import("strict_function_context.zig").Role) bool {
        const roles = sem.strict_output_context.functions;
        const base = @intFromPtr(roles.ptr);
        const address = @intFromPtr(role);
        const width = @sizeOf(@import("strict_function_context.zig").Role);
        return roles.len != 0 and address >= base and (address - base) % width == 0 and (address - base) / width < roles.len;
    }

    fn validateDefaultBridge(self: Provider, source: DefaultFunctionSource, after: ExportBinding, role: *const @import("strict_function_context.zig").Role) Error!void {
        const sem = self.owner.semantic orelse return error.InvalidCrossChunkExport;
        const ast = if (self.owner.ast) |*value| value else return error.InvalidCrossChunkExport;
        const sid = source.binding.symbol.semanticIndex() orelse return error.InvalidCrossChunkExport;
        const anonymous = source.binding.has_default_export_facade;
        const name_role: @import("strict_function_context.zig").NameRole = if (anonymous) .anonymous_default else .binding;
        const flags: u16 = if (anonymous) 0 else parser_module.EXPORT_DEFAULT_NAMED_DECLARATION;
        if (!ownsStrictRole(sem, role) or source.binding.symbol.moduleIndex() != self.owner.index or sid >= sem.symbols.items.len or
            @backingInt(role.symbol) != sid or role.name_role != name_role or role.kind != .factory or
            role.declaration != source.declaration or role.source_scope != source.scope or source.wrapper.tag != .export_default_declaration or
            source.wrapper.operand != source.declaration or source.wrapper.flags != flags or source.function_before.tag != .function_declaration or
            source.binding.source_export_node != source.binding.default_export_node or
            (anonymous and !source.name.isNone()) or (!anonymous and (source.name.isNone() or role.binding != source.name or source.binding.local_symbol_node != source.name))) return error.InvalidCrossChunkExport;
        const returned = nodeAt(ast, role.returned_function) orelse return error.InvalidCrossChunkExport;
        if (returned.tag != .function_expression or !std.meta.eql(returned.span, source.function_before.span) or
            !ast.hasExtra(returned.data.extra, ast_mod.FunctionExtra.flags) or
            ast.readExtraNode(returned.data.extra, ast_mod.FunctionExtra.params) != source.parameters or
            ast.readExtraNode(returned.data.extra, ast_mod.FunctionExtra.body) != source.body or
            ast.readExtra(returned.data.extra, ast_mod.FunctionExtra.flags) != source.flags) return error.InvalidCrossChunkExport;
        const wrapper_index = source.binding.default_export_node orelse return error.InvalidCrossChunkExport;
        const wrapper = nodeAt(ast, wrapper_index) orelse return error.InvalidCrossChunkExport;
        if (wrapper.tag != .export_named_declaration or !std.meta.eql(wrapper.span, source.wrapper.span) or
            !ast.hasExtra(wrapper.data.extra, 3) or !ast.readExtraNode(wrapper.data.extra, 0).isNone() or
            !ast.readExtraNode(wrapper.data.extra, 3).isNone()) return error.InvalidCrossChunkExport;
        const start = ast.readExtra(wrapper.data.extra, 1);
        const length = ast.readExtra(wrapper.data.extra, 2);
        if (length != 1 or start >= ast.extra_data.items.len) return error.InvalidCrossChunkExport;
        const specifier_index: NodeIndex = @fromBackingInt(ast.extra_data.items[start]);
        const specifier = nodeAt(ast, specifier_index) orelse return error.InvalidCrossChunkExport;
        const reference_index = after.local_symbol_node orelse return error.InvalidCrossChunkExport;
        const reference = nodeAt(ast, reference_index) orelse return error.InvalidCrossChunkExport;
        const binding = nodeAt(ast, role.binding) orelse return error.InvalidCrossChunkExport;
        const actual = sem.symbols.items[sid];
        const logical_name = if (actual.synthetic_name.len > 0) actual.synthetic_name else ast.getText(actual.name);
        if (specifier.tag != .export_specifier or specifier.data.binary.left != reference_index or
            after.source_specifier_node != specifier_index or after.source_export_node != wrapper_index or
            reference.tag != .identifier_reference or binding.tag != .binding_identifier or
            !attached(sem.symbol_ids, reference_index, sid) or !attached(sem.symbol_ids, role.binding, sid) or
            !std.meta.eql(binding.data.string_ref, actual.name) or !std.meta.eql(reference.data.string_ref, actual.name) or
            !std.mem.eql(u8, ast.identifierNameText(binding), logical_name) or
            !std.mem.eql(u8, after.local_name, logical_name)) return error.InvalidCrossChunkExport;
        const key = nodeAt(ast, specifier.data.binary.right) orelse return error.InvalidCrossChunkExport;
        if (key.tag != .identifier_reference or !@import("../lexer/scanner.zig").Scanner.identifierValueEquals(ast.identifierNameText(key), "default")) return error.InvalidCrossChunkExport;
        var expected_binding = source.binding;
        expected_binding.local_symbol_node = reference_index;
        expected_binding.local_span = binding.span;
        // rewriteDefaultAlias owns a distinct dupe of the same logical name.
        // Preserve its actual backing after the explicit value check above.
        expected_binding.local_name = after.local_name;
        expected_binding.default_export_node = null;
        expected_binding.has_default_export_facade = false;
        expected_binding.source_specifier_node = specifier_index;
        if (!std.meta.eql(expected_binding, after)) return error.InvalidCrossChunkExport;
        var expected_symbol = source.symbol;
        if (anonymous) {
            expected_symbol.name = actual.name;
            expected_symbol.synthetic_name = actual.synthetic_name;
        }
        expected_symbol.reference_count = actual.reference_count;
        expected_symbol.write_count = actual.write_count;
        expected_symbol.binding_instantiation.strict_output_function = true;
        if (!std.meta.eql(expected_symbol, actual)) return error.InvalidCrossChunkExport;
    }

    /// Preparation retains the original facade witness. Publication is owned
    /// by Linker's no-fail batch, after every role and allocation succeeds.
    pub fn prepareStrictOutputFunction(self: Provider, l: *const Linker, role: *const @import("strict_function_context.zig").Role, allocator: std.mem.Allocator) Error!Provider {
        const previous = switch (self.role) {
            .semantic, .entry_guard => |known| known,
            else => return error.InvalidCrossChunkExport,
        };
        const default_rewrite = previous.default_source != null and !std.meta.eql(previous.original, previous.binding.*);
        if (role.name_role != .anonymous_default and !default_rewrite) {
            try self.validateStrictOutputFunction(l, role, allocator);
            var result = self;
            switch (result.role) {
                .semantic, .entry_guard => |*known| known.symbol.binding_instantiation.strict_output_function = true,
                else => return error.InvalidCrossChunkExport,
            }
            return result;
        }
        const known = switch (self.role) {
            .semantic => |value| value,
            else => return error.InvalidCrossChunkExport,
        };
        if (l.getModule(self.owner.index.toU32()) != self.owner or !registered(self.owner, known.binding)) return error.InvalidCrossChunkExport;
        const sem = self.owner.semantic orelse return error.InvalidCrossChunkExport;
        const ast = if (self.owner.ast) |*value| value else return error.InvalidCrossChunkExport;
        if (sem.owner_token != self.owner_token) return error.InvalidCrossChunkExport;
        @import("strict_function_context.zig").validate(ast, sem, role.*, allocator) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return error.InvalidCrossChunkExport;
        };
        const source = known.default_source orelse {
            // A later link may start from the already materialized, registered
            // output graph. Its source receipt is the current exact specifier;
            // this path does not invent a lost facade or alter any snapshot.
            try self.validateKnown(known);
            const sid = known.original.symbol.semanticIndex() orelse return error.InvalidCrossChunkExport;
            const anchor = known.anchor orelse return error.InvalidCrossChunkExport;
            const specifier = nodeAt(ast, known.original.source_specifier_node orelse return error.InvalidCrossChunkExport) orelse return error.InvalidCrossChunkExport;
            if (!ownsStrictRole(sem, role) or @backingInt(role.symbol) != sid or !known.symbol.binding_instantiation.strict_output_function or
                role.kind != .factory or specifier.tag != .export_specifier or specifier.data.binary.left != anchor or
                !attached(sem.symbol_ids, role.binding, sid) or !attached(sem.symbol_ids, anchor, sid)) return error.InvalidCrossChunkExport;
            return self;
        };
        try self.validateDefaultBridge(source, known.binding.*, role);
        var result = self;
        switch (result.role) {
            .semantic => |*next| {
                next.original = known.binding.*;
                next.symbol = sem.symbols.items[@backingInt(role.symbol)];
                next.anchor = known.binding.local_symbol_node;
                next.default_role = .{ .pointer = role, .before = role.* };
            },
            else => return error.InvalidCrossChunkExport,
        }
        return result;
    }

    fn validateKnown(self: Provider, known: KnownBinding) Error!void {
        if (!registered(self.owner, known.binding) or !std.meta.eql(known.binding.*, known.original) or
            !std.mem.eql(u8, known.original.exported_name, self.public_name)) return error.InvalidCrossChunkExport;
        const sem = self.owner.semantic orelse return error.InvalidCrossChunkExport;
        if (known.default_role) |published| {
            if (!ownsStrictRole(sem, published.pointer) or !std.meta.eql(published.before, published.pointer.*)) return error.InvalidCrossChunkExport;
            try self.validateDefaultBridge(known.default_source orelse return error.InvalidCrossChunkExport, known.original, published.pointer);
        }
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

    /// Consume the strict-output producer's actual role before output queries.
    /// Only its registered binding-instantiation bit can change this receipt.
    pub fn validateStrictOutputFunction(self: *const Provider, l: *const Linker, role: *const @import("strict_function_context.zig").Role, allocator: std.mem.Allocator) Error!void {
        const known = switch (self.role) {
            .semantic, .entry_guard => |value| value,
            else => return error.InvalidCrossChunkExport,
        };
        if (l.getModule(self.owner.index.toU32()) != self.owner or !registered(self.owner, known.binding) or
            !std.meta.eql(known.binding.*, known.original)) return error.InvalidCrossChunkExport;
        const sem = self.owner.semantic orelse return error.InvalidCrossChunkExport;
        const ast = if (self.owner.ast) |*value| value else return error.InvalidCrossChunkExport;
        if (!ownsStrictRole(sem, role)) return error.InvalidCrossChunkExport;
        const sid = self.owner.exportBindingSemanticIndex(known.original) orelse return error.InvalidCrossChunkExport;
        if (sem.owner_token != self.owner_token or @backingInt(role.symbol) != sid) return error.InvalidCrossChunkExport;
        const anchor = known.anchor orelse return error.InvalidCrossChunkExport;
        if (anchor != role.binding) {
            // `export { fn as alias }` owns a reference, while the registered
            // strict role owns the declaration binding. Both are actual edges
            // of the same source SID; an equal spelling is never sufficient.
            const specifier = nodeAt(ast, known.original.source_specifier_node orelse return error.InvalidCrossChunkExport) orelse return error.InvalidCrossChunkExport;
            const reference = nodeAt(ast, anchor) orelse return error.InvalidCrossChunkExport;
            if (specifier.tag != .export_specifier or specifier.data.binary.left != anchor or
                reference.tag != .identifier_reference or !attached(sem.symbol_ids, anchor, sid)) return error.InvalidCrossChunkExport;
        }
        @import("strict_function_context.zig").validate(ast, sem, role.*, allocator) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return error.InvalidCrossChunkExport;
        };
        const actual = sem.symbols.items[sid];
        if (!actual.binding_instantiation.strict_output_function) return error.InvalidCrossChunkExport;
        var expected = known.symbol;
        expected.reference_count = actual.reference_count;
        expected.write_count = actual.write_count;
        expected.binding_instantiation.strict_output_function = true;
        if (!std.meta.eql(expected, actual)) return error.InvalidCrossChunkExport;
    }

    /// Local output-name consumers do not request namespace storage or CJS
    /// properties. Capture their exact source binding before wrapper retagging.
    pub fn captureLocal(l: *const Linker, owner: *const Module, binding: *const ExportBinding) Error!Provider {
        if (!registered(owner, binding) or l.getModule(owner.index.toU32()) != owner) return error.InvalidCrossChunkExport;
        if (owner.semantic == null and owner.ast == null) return make(owner, binding.exported_name, .graphless);
        if (l.graph.entry_guard_ast_provider) |guard| if (guard.module_index == owner.index)
            return capture(l, owner.index.toU32(), binding.exported_name, .ordinary_export);
        if (binding.kind != .local and !binding.hasSyntheticDefault(owner.semanticSymbols())) return error.InvalidCrossChunkExport;
        // Registered compiler AST providers own declarations without an ES
        // source export wrapper. Validate their real birth tuples, not names.
        if (l.graph.interop_ast_provider) |provider| if (provider.module_index == owner.index) {
            const actual = @import("runtime_interop_ast.zig").resolveBindings(l.graph) catch return error.InvalidCrossChunkExport;
            var matches: usize = 0;
            for (actual) |maybe| if (maybe) |known| {
                if (binding.local_symbol_node == known.node and binding.symbol.eql(SymbolRef.makeSemantic(owner.index, @backingInt(known.symbol_id)))) matches += 1;
            };
            if (matches != 1) return error.InvalidCrossChunkExport;
            return make(owner, binding.exported_name, .{ .semantic = try knownBinding(owner, binding) });
        };
        if (l.graph.dynamic_import_ast_provider) |provider| if (provider.module_index == owner.index) {
            const actual = @import("runtime_dynamic_import_ast.zig").exactBinding(l.graph) catch return error.InvalidCrossChunkExport;
            if (!binding.symbol.eql(SymbolRef.makeSemantic(actual.module, @backingInt(actual.inner)))) return error.InvalidCrossChunkExport;
            return make(owner, binding.exported_name, .{ .semantic = try knownBinding(owner, binding) });
        };
        _ = try checkedSymbol(l.allocator, owner, binding);
        return make(owner, binding.exported_name, .{ .semantic = try knownBinding(owner, binding) });
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

    /// Borrow the existing identity's output datum without allocating a new
    /// spelling. Syntax-bearing consumers additionally use localName below.
    pub fn bindingName(self: Provider, l: *const Linker) Error!?[]const u8 {
        try self.validate(l);
        return switch (self.role) {
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
    }

    pub fn localName(self: Provider, l: *const Linker) Error!?[]const u8 {
        const name = try self.bindingName(l);
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
            const actual = owner.checkedSourceImportLocalSymbol(imported) catch continue;
            if (!actual.eql(binding.symbol)) continue;
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
        if (record_index >= owner.import_records.len) return error.InvalidCrossChunkExport;
        if (source_node.isNone()) {
            // Normalized `import X; export { X as default }` births a default
            // bridge from the actual source import reference, not a from-node.
            const raw = @backingInt(specifier.data.binary.left);
            if (raw >= sem.symbol_ids.len) return error.InvalidCrossChunkExport;
            const source_sid = sem.symbol_ids[raw] orelse return error.InvalidCrossChunkExport;
            var imports: usize = 0;
            for (owner.import_bindings) |imported| {
                if (imported.import_record_index != record_index) continue;
                const actual = owner.checkedSourceImportLocalSymbol(imported) catch continue;
                if (actual.semanticIndex() == @as(?u32, source_sid)) imports += 1;
            }
            if (imports != 1) return error.InvalidCrossChunkExport;
        } else {
            if (owner.import_records[record_index].source_node != source_node) return error.InvalidCrossChunkExport;
            const source_literal = nodeAt(ast, source_node) orelse return error.InvalidCrossChunkExport;
            if (source_literal.tag != .string_literal) return error.InvalidCrossChunkExport;
        }
    }
    return binding.symbol;
}

pub fn registered(owner: *const Module, binding: *const ExportBinding) bool {
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
        .ts_module_declaration => return node.data.binary.left == anchor,
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

pub fn keyMatches(a: std.mem.Allocator, ast: *const Ast, index: NodeIndex, expected: []const u8) Error!bool {
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
