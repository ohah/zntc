//! Exact graph construction for single-output import() lowering.
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

/// Validate an already selected typed foreign role. Neither its spelling nor
/// another same-kind row can replace a missing producer-owned identity.
pub fn validateTargetRole(graph: anytype, target: anytype) !void {
    const module = graph.getModule(target.symbol.module) orelse return error.InvalidCallsiteTarget;
    const expected: SymbolID = switch (target.role) {
        .schedule => try @import("runtime_dynamic_import_ast.zig").exactBinding(graph),
        .to_esm => blk: {
            const provider = graph.interop_ast_provider orelse return error.InvalidCallsiteTarget;
            const bindings = try @import("runtime_interop_ast.zig").resolveBindings(graph);
            break :blk SymbolID.make(provider.module_index, @backingInt(bindings[7].?.symbol_id));
        },
        .require => blk: {
            if (module.wrap_kind != .cjs) return error.InvalidCallsiteTarget;
            const id = module.require_symbol orelse return error.InvalidCallsiteTarget;
            const sem = module.semantic orelse return error.InvalidCallsiteTarget;
            if (@backingInt(id) >= sem.symbols.items.len or sem.symbols.items[@backingInt(id)].synthetic_kind != .cjs_require) return error.InvalidCallsiteTarget;
            break :blk SymbolID.make(module.index, @backingInt(id));
        },
        .esm_init => try module.esmInitSymbol(),
        .esm_namespace => try module.esmNamespaceSymbol(),
    };
    if (expected.module != target.symbol.module or expected.inner != target.symbol.inner) return error.InvalidCallsiteTarget;
}

const Builder = struct {
    allocator: std.mem.Allocator,
    ast: *Ast,
    editor: *Editor,
    module: *Module,
    graph: *@import("graph.zig").ModuleGraph,
    declarations: std.ArrayList(NodeIndex) = .empty,
    next_name: u32 = 0,
    references: std.ArrayList(struct { node: NodeIndex, symbol: SymbolId, scope: ScopeId }) = .empty,
    callbacks: std.ArrayList(struct { node: NodeIndex, scope: ScopeId, parent: ScopeId, call_node: NodeIndex, callee: NodeIndex }) = .empty,

    fn validate(self: *Builder) !void {
        for (self.references.items) |expected| {
            const raw = @backingInt(expected.node);
            if (raw >= self.editor.symbol_ids.items.len or self.editor.symbol_ids.items[raw] != @backingInt(expected.symbol)) return error.InvalidCallsiteReference;
            const actual_reference = try self.editor.referenceForNode(expected.node) orelse return error.InvalidCallsiteReference;
            if (actual_reference.flags.declare or !actual_reference.flags.read or actual_reference.symbol_id != expected.symbol or actual_reference.scope_id != expected.scope) return error.InvalidCallsiteReference;
            if (self.editor.symbols.items[@backingInt(expected.symbol)].kind != .import_binding) return error.InvalidCallsiteReference;
        }
        for (self.callbacks.items) |expected| {
            const provenance = self.editor.node_scope_provenance.get(expected.call_node) orelse return error.InvalidCallsiteScope;
            if (provenance.scope != expected.parent or self.ast.getNode(expected.node).tag != .function_expression) return error.InvalidCallsiteScope;
            if (expected.scope.isNone() or expected.scope.toIndex() >= self.editor.scopes.items.len) return error.InvalidCallsiteScope;
            if (self.editor.scope_owner_map.get(@backingInt(expected.node)) != @as(?u32, @backingInt(expected.scope))) return error.InvalidCallsiteScope;
            const scope = self.editor.scopes.items[expected.scope.toIndex()];
            if (scope.kind != .function or scope.parent != expected.parent) return error.InvalidCallsiteScope;
            const actual = self.ast.getNode(expected.call_node);
            if (actual.tag != .call_expression or self.ast.readExtraNode(actual.data.extra, 0) != expected.callee) return error.InvalidCallsiteReference;
        }
        for (self.module.import_bindings) |binding| {
            const target = binding.callsite_target orelse continue;
            const foreign = self.graph.getModule(target.symbol.module) orelse return error.InvalidCallsiteTarget;
            const foreign_sem = foreign.semantic orelse return error.InvalidCallsiteTarget;
            if (target.owner == .unassigned or target.owner != foreign_sem.owner_token or @backingInt(target.symbol.inner) >= foreign_sem.symbols.items.len) return error.InvalidCallsiteTarget;
            try validateTargetRole(self.graph, target);
            const local = @import("binding_scanner.zig").resolveImportLocalSymbol(binding, .{ .module_index = self.module.index, .ast = self.ast, .symbol_ids = self.editor.symbol_ids.items, .symbols = self.editor.symbols.items });
            if (!local.isValid() or !local.eql(binding.local_symbol) or !binding.symbol.eql(target.symbol.toRef())) return error.InvalidCallsiteBinding;
            const local_raw = local.semanticIndex().?;
            const row = self.editor.symbols.items[local_raw];
            if (row.scope_id.isNone() or row.scope_id.toIndex() >= self.editor.scope_maps.items.len or self.editor.scope_maps.items[row.scope_id.toIndex()].get(self.ast.getText(row.name)) != @as(?usize, local_raw)) return error.InvalidCallsiteBinding;
        }
    }

    fn reference(self: *Builder, id: SymbolId, scope: ScopeId) !NodeIndex {
        const name = self.editor.symbols.items[@backingInt(id)].name;
        const node = try self.ast.addNode(.{ .tag = .identifier_reference, .span = name, .data = .{ .string_ref = name } });
        try self.editor.addReference(node, id, scope, .{ .read = true }, Reference.NO_STMT, Reference.NO_STMT);
        try self.references.append(self.allocator, .{ .node = node, .symbol = id, .scope = scope });
        return node;
    }

    fn imported(self: *Builder, target: SymbolID, role: @import("binding_scanner.zig").CallsiteRole) !SymbolId {
        const foreign = self.graph.moduleAtMut(target.module) orelse return error.InvalidCallsiteTarget;
        const foreign_sem = if (foreign.semantic) |*value| value else return error.InvalidCallsiteTarget;
        if (@backingInt(target.inner) >= foreign_sem.symbols.items.len) return error.InvalidCallsiteTarget;
        const owner = foreign_sem.captureOwnerToken();
        const root_scope: ScopeId = @fromBackingInt(@as(u32, 0));
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
        const record_index: u32 = @intCast(self.module.import_records.len);
        const records = try self.allocator.alloc(@import("types.zig").ImportRecord, self.module.import_records.len + 1);
        @memcpy(records[0..self.module.import_records.len], self.module.import_records);
        records[self.module.import_records.len] = .{ .specifier = foreign.path, .kind = .static_import, .span = source_span, .resolved = target.module };
        self.module.import_records = records;
        const bindings = try self.allocator.alloc(@import("binding_scanner.zig").ImportBinding, self.module.import_bindings.len + 1);
        @memcpy(bindings[0..self.module.import_bindings.len], self.module.import_bindings);
        bindings[self.module.import_bindings.len] = .{
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
        };
        self.module.import_bindings = bindings;
        try self.graph.linkDependency(self.module.index, target.module);
        return sid;
    }

    fn call(self: *Builder, callee: NodeIndex, args: []const NodeIndex) !NodeIndex {
        const list = try self.ast.addNodeList(args);
        const extra = try self.ast.addExtras(&.{ @backingInt(callee), list.start, list.len, 0 });
        return self.ast.addNode(.{ .tag = .call_expression, .span = .EMPTY, .data = .{ .extra = extra } });
    }

    fn use(self: *Builder, target: SymbolID, scope: ScopeId, role: @import("binding_scanner.zig").CallsiteRole) !NodeIndex {
        return self.reference(try self.imported(target, role), scope);
    }
};

/// Exact current source expressions after AST pruning. A detached import record
/// cannot activate a provider merely because its former span has no statement.
pub fn collectLiveDynamicOrigins(allocator: std.mem.Allocator, module: *const Module) !std.AutoHashMapUnmanaged(NodeIndex, void) {
    var result: std.AutoHashMapUnmanaged(NodeIndex, void) = .empty;
    errdefer result.deinit(allocator);
    const ast = if (module.ast) |*value| value else return result;
    const sem = module.semantic orelse return result;
    const live = try @import("../parser/ast_walk.zig").collectReachableNodeIndices(allocator, ast);
    defer allocator.free(live);
    for (live) |raw| {
        if (ast.nodes.items[raw].tag != .import_expression) continue;
        const provenance = sem.node_scope_provenance.get(@fromBackingInt(raw)) orelse return error.MissingImportCallsiteProvenance;
        try result.put(allocator, provenance.source_node, {});
    }
    return result;
}

pub fn lower(graph: *@import("graph.zig").ModuleGraph, linker: *@import("linker.zig").Linker, shaker: ?*@import("tree_shaker.zig").TreeShaker) !void {
    const provider = graph.dynamic_import_ast_provider orelse return;
    const schedule = try @import("runtime_dynamic_import_ast.zig").exactBinding(graph);
    const count = graph.moduleCount();
    for (0..count) |raw_module| {
        const module = graph.moduleAtMut(@import("types.zig").ModuleIndex.fromUsize(raw_module)) orelse continue;
        if (module.index == provider.module_index) continue;
        if (shaker) |s| if (!s.isIncluded(@intCast(raw_module))) continue;
        if (!module.module_type.isJavaScriptLike()) continue;
        const ast = if (module.ast) |*value| value else continue;
        const sem = if (module.semantic) |*value| value else continue;
        const a = module.parse_arena.?.allocator();
        var by_source: std.AutoHashMapUnmanaged(NodeIndex, usize) = .empty;
        var all_sources: std.AutoHashMapUnmanaged(NodeIndex, void) = .empty;
        for (module.import_records) |record| {
            if (record.kind == .dynamic_import and !record.call_node.isNone()) try all_sources.put(a, record.call_node, {});
        }
        for (module.import_records, 0..) |record, index| {
            if (record.kind != .dynamic_import or record.resolved.isNone() or record.callsite_lowered) continue;
            const target = graph.getModule(record.resolved) orelse continue;
            if (!target.wrap_kind.isWrapped()) continue;
            if (shaker) |s| if (!try s.isImportRecordLive(@intCast(raw_module), @intCast(index))) continue;
            if (record.call_node.isNone()) return error.MissingImportCallsiteAnchor;
            try by_source.put(a, record.call_node, index);
        }
        if (by_source.count() == 0) continue;
        const old_root = ast.transformed_root orelse @as(NodeIndex, @fromBackingInt(@as(u32, @intCast(ast.nodes.items.len - 1))));
        var editor = try sem.beginEdit(a, ast);
        defer editor.deinit();
        var builder: Builder = .{ .allocator = a, .ast = ast, .editor = &editor, .module = module, .graph = graph };
        const live = try @import("../parser/ast_walk.zig").collectReachableNodeIndices(a, ast);
        var lowered = false;
        for (live) |raw| {
            const call_node: NodeIndex = @fromBackingInt(raw);
            if (ast.getNode(call_node).tag != .import_expression) continue;
            const provenance = editor.node_scope_provenance.get(call_node) orelse return error.MissingImportCallsiteProvenance;
            if (!all_sources.contains(provenance.source_node)) return error.MissingImportCallsiteAnchor;
            const record_index = by_source.get(provenance.source_node) orelse continue;
            if (provenance.with_environment or !ast.getNode(call_node).data.binary.right.isNone()) {
                continue;
            }
            const record = module.import_records[record_index];
            const target = graph.getModule(record.resolved) orelse return error.InvalidCallsiteTarget;
            const original = ast.getNode(call_node);
            // All lexical owners and references are created before publishing
            // this expression as a call; no second semantic analysis follows.
            const body = try ast.addNode(.{ .tag = .block_statement, .span = original.span, .data = .{ .list = try ast.addNodeList(&.{}) } });
            const params = try ast.addFormalParameters(try ast.addNodeList(&.{}), original.span);
            const none = @backingInt(NodeIndex.none);
            const function_extra = try ast.addExtras(&.{ none, @backingInt(params), @backingInt(body), 0, none });
            const callback = try ast.addNode(.{ .tag = .function_expression, .span = original.span, .data = .{ .extra = function_extra } });
            const callback_scope = try editor.addScope(provenance.scope, callback, .function, false);
            const value = if (target.wrap_kind == .cjs) cjs: {
                const require_sid = target.require_symbol orelse return error.InvalidCallsiteTarget;
                const require_call = try builder.call(try builder.use(SymbolID.make(target.index, @backingInt(require_sid)), callback_scope, .require), &.{});
                const interop = (try @import("runtime_interop_ast.zig").resolveBindings(graph))[7].?;
                const to_esm = try builder.use(SymbolID.make(graph.interop_ast_provider.?.module_index, @backingInt(interop.symbol_id)), callback_scope, .to_esm);
                if (linker.cjsInteropIsNodeForCallsite(target)) {
                    const one_span = try ast.addString("1");
                    const one = try ast.addNode(.{ .tag = .numeric_literal, .span = one_span, .data = .{ .string_ref = one_span } });
                    break :cjs try builder.call(to_esm, &.{ require_call, one });
                }
                break :cjs try builder.call(to_esm, &.{require_call});
            } else esm: {
                const init = try builder.call(try builder.use(try target.esmInitSymbol(), callback_scope, .esm_init), &.{});
                const exports = try builder.use(try target.esmNamespaceSymbol(), callback_scope, .esm_namespace);
                break :esm try ast.addNode(.{ .tag = .sequence_expression, .span = original.span, .data = .{ .list = try ast.addNodeList(&.{ init, exports }) } });
            };
            const ret = try ast.addNode(.{ .tag = .return_statement, .span = original.span, .data = .{ .unary = .{ .operand = value, .flags = 0 } } });
            if (editor.scopes.items[callback_scope.toIndex()].is_strict) {
                const directive_span = try ast.addString("\"use strict\"");
                const directive = try ast.addNode(.{ .tag = .directive, .span = directive_span, .data = .{ .none = 0 } });
                ast.nodes.items[@backingInt(body)].data.list = try ast.addNodeList(&.{ directive, ret });
            } else ast.nodes.items[@backingInt(body)].data.list = try ast.addNodeList(&.{ret});
            const schedule_ref = try builder.use(schedule, provenance.scope, .schedule);
            const replacement = try builder.call(schedule_ref, &.{callback});
            try builder.callbacks.append(a, .{ .node = callback, .scope = callback_scope, .parent = provenance.scope, .call_node = call_node, .callee = schedule_ref });
            ast.nodes.items[raw] = ast.getNode(replacement);
            module.import_records[record_index].callsite_lowered = true;
            lowered = true;
        }
        // Statement pruning legitimately leaves detached import records. Only
        // actual reachable expression nodes can demand generated callsites.
        if (!lowered) continue;
        var statements: std.ArrayList(NodeIndex) = .empty;
        var original_statements = ast.iterateExtraList(ast.getNode(old_root).data.list);
        while (original_statements.next()) |statement| try statements.append(a, statement);
        try statements.appendSlice(a, builder.declarations.items);
        const root = try ast.addNode(.{ .tag = .program, .span = ast.getNode(old_root).span, .data = .{ .list = try ast.addNodeList(statements.items) } });
        try editor.remapScopeOwner(old_root, root);
        ast.transformed_root = root;
        try builder.validate();
        sem.applyEdit(try editor.finish());
        if (module.transform_cache) |*cache| cache.symbol_ids = sem.symbol_ids;
        try @import("runtime_dynamic_import_ast.zig").activate(graph, shaker);
    }
}

fn expectHostileRejection(graph: *@import("graph.zig").ModuleGraph, module: *Module, corruption: usize) !void {
    const ast = if (module.ast) |*value| value else return error.MissingCallsiteAst;
    const sem = if (module.semantic) |*value| value else return error.MissingCallsiteSemantic;
    const a = module.parse_arena.?.allocator();
    var editor = try sem.beginEdit(a, ast);
    var builder: Builder = .{ .allocator = a, .ast = ast, .editor = &editor, .module = module, .graph = graph };
    for (sem.references) |reference_row| {
        if (reference_row.flags.declare or reference_row.node_index.isNone()) continue;
        for (module.import_bindings) |binding| {
            if (binding.callsite_target == null or binding.local_symbol.semanticIndex() != @backingInt(reference_row.symbol_id)) continue;
            try builder.references.append(a, .{ .node = reference_row.node_index, .symbol = reference_row.symbol_id, .scope = reference_row.scope_id });
            break;
        }
    }
    var contexts = sem.node_scope_provenance.iterator();
    while (contexts.next()) |entry| {
        const call = ast.getNode(entry.key_ptr.*);
        if (call.tag != .call_expression) continue;
        const start = ast.readExtra(call.data.extra, 1);
        const callback: NodeIndex = @fromBackingInt(ast.extra_data.items[start]);
        const scope = editor.scope_owner_map.get(@backingInt(callback)) orelse return error.MissingCallsiteScope;
        try builder.callbacks.append(a, .{ .node = callback, .scope = @fromBackingInt(scope), .parent = entry.value_ptr.scope, .call_node = entry.key_ptr.*, .callee = ast.readExtraNode(call.data.extra, 0) });
    }
    try std.testing.expect(builder.references.items.len >= 3 and builder.callbacks.items.len > 0);
    try builder.validate();
    const callback = builder.callbacks.items[0];
    const reference_node = builder.references.items[0].node;
    const expected_error = switch (corruption) {
        0 => blk: {
            _ = editor.node_scope_provenance.remove(callback.call_node);
            break :blk error.InvalidCallsiteScope;
        },
        1 => blk: {
            editor.node_scope_provenance.getPtr(callback.call_node).?.scope = callback.scope;
            break :blk error.InvalidCallsiteScope;
        },
        2 => blk: {
            editor.scopes.items[callback.scope.toIndex()].parent = .none;
            break :blk error.InvalidCallsiteScope;
        },
        3 => blk: {
            _ = editor.scope_owner_map.remove(@backingInt(callback.node));
            break :blk error.InvalidCallsiteScope;
        },
        4 => blk: {
            editor.symbol_ids.items[@backingInt(reference_node)] = @backingInt(builder.references.items[1].symbol);
            break :blk error.InvalidCallsiteReference;
        },
        5 => blk: {
            for (editor.references.items) |*reference_row| if (reference_row.node_index == reference_node) {
                reference_row.scope_id = .none;
                break;
            };
            break :blk error.InvalidCallsiteReference;
        },
        6, 7, 8 => blk: {
            for (module.import_bindings) |*binding| {
                if (binding.callsite_target) |*target| {
                    if (corruption == 6) target.owner = .unassigned else if (corruption == 7) target.symbol.inner = .none else binding.local_symbol_node = null;
                    break;
                }
            }
            break :blk if (corruption == 8) error.InvalidCallsiteBinding else error.InvalidCallsiteTarget;
        },
        9 => blk: {
            ast.nodes.items[@backingInt(callback.node)].tag = .identifier_reference;
            break :blk error.InvalidCallsiteScope;
        },
        else => unreachable,
    };
    try std.testing.expectError(expected_error, builder.validate());
}

test "single output import callsites own exact references through ten source contexts" {
    const entries = [_][]const u8{
        "import('./dep.cjs').then(m=>console.log(m.answer));",
        "function read(Promise){return import('./dep.cjs').then(m=>console.log(m.answer,Promise));}read(5);",
        "function read(__toESM){return import('./dep.cjs').then(m=>console.log(m.answer,__toESM));}read(6);",
        "function read(require){return import('./dep.cjs').then(m=>console.log(m.answer,require));}read(7);",
        "function read(__dynamicImport){return import('./dep.cjs').then(m=>console.log(m.answer,__dynamicImport));}read(8);",
        "function read(value=import('./dep.cjs')){let body=9;return value.then(m=>console.log(m.answer,body));}read();",
        "class Read{constructor(value=import('./dep.cjs')){let body=10;value.then(m=>console.log(m.answer,body));}}new Read();",
        "function read(value=()=>import('./dep.cjs')){let body=11;return value().then(m=>console.log(m.answer,body));}read();",
        "class Read{static value=import('./dep.cjs');}Read.value.then(m=>console.log(m.answer));",
        "import('./dep.mjs').then(m=>console.log(m.answer));",
    };
    const Bundler = @import("bundler.zig").Bundler;
    const helpers = @import("test_helpers.zig");
    var missing_providers: usize = 0;
    for (entries, 0..) |entry_source, context| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try helpers.writeFile(tmp.dir, "entry.mjs", entry_source);
        try helpers.writeFile(tmp.dir, "dep.cjs", "exports.answer=42;");
        try helpers.writeFile(tmp.dir, "dep.mjs", "export const answer=43;");
        const entry = try helpers.absPath(&tmp, "entry.mjs");
        defer std.testing.allocator.free(entry);
        const options: @import("bundler.zig").BundleOptions = .{ .entry_points = &.{entry}, .inline_dynamic_imports = true, .unsupported = if (context >= 5 and context < 9) .{ .arrow = true, .class = true, .class_field = true } else .{} };
        var cache = Bundler.initResolveCacheFromOptions(std.testing.allocator, options);
        defer cache.deinit();
        var graph = @import("graph.zig").ModuleGraph.init(std.testing.allocator, &cache);
        defer graph.deinit();
        var bundler = Bundler.initWithGraph(std.testing.allocator, options, &cache, &graph);
        defer bundler.deinit();
        const result = try bundler.bundle(std.testing.io);
        defer result.deinit(std.testing.allocator);
        try std.testing.expect(!result.hasErrors());
        const provider = graph.dynamic_import_ast_provider orelse {
            missing_providers += 1;
            continue;
        };
        try std.testing.expect(provider.active);
        var callsites: usize = 0;
        var hostile_module: ?@import("types.zig").ModuleIndex = null;
        var modules = graph.modulesIterator();
        while (modules.next()) |module| {
            const sem = module.semantic orelse continue;
            const ast = module.ast orelse continue;
            for (module.import_records) |record| {
                if (record.kind != .dynamic_import or record.resolved.isNone()) continue;
                try std.testing.expect(record.callsite_lowered);
                hostile_module = module.index;
                var contexts = sem.node_scope_provenance.iterator();
                while (contexts.next()) |item| {
                    if (item.value_ptr.source_node != record.call_node) continue;
                    const call_node = item.key_ptr.*;
                    const call = ast.getNode(call_node);
                    try std.testing.expectEqual(ast_mod.Node.Tag.call_expression, call.tag);
                    const callee = ast.readExtraNode(call.data.extra, 0);
                    const local_id = sem.symbol_ids[@backingInt(callee)] orelse return error.MissingCallsiteSymbol;
                    try std.testing.expectEqual(@import("../semantic/symbol.zig").SymbolKind.import_binding, sem.symbols.items[local_id].kind);
                    var exact_reference = false;
                    for (sem.references) |reference_row| {
                        if (reference_row.node_index != callee) continue;
                        try std.testing.expectEqual(item.value_ptr.scope, reference_row.scope_id);
                        try std.testing.expectEqual(local_id, @backingInt(reference_row.symbol_id));
                        exact_reference = true;
                    }
                    try std.testing.expect(exact_reference);
                    const args_start = ast.readExtra(call.data.extra, 1);
                    const callback: NodeIndex = @fromBackingInt(ast.extra_data.items[args_start]);
                    const callback_scope = sem.scope_owner_map.get(@backingInt(callback)) orelse return error.MissingCallsiteScope;
                    try std.testing.expectEqual(item.value_ptr.scope, sem.scopes[callback_scope].parent);
                    var foreign_edge = false;
                    for (module.import_bindings) |binding| {
                        if (binding.local_symbol.semanticIndex() != local_id) continue;
                        const target = binding.callsite_target orelse return error.MissingCallsiteTarget;
                        try std.testing.expectEqual(provider.module_index, target.symbol.module);
                        try std.testing.expectEqual(provider.binding_id, target.symbol.inner);
                        try std.testing.expect(binding.symbol.eql(target.symbol.toRef()));
                        foreign_edge = true;
                    }
                    try std.testing.expect(foreign_edge);
                    callsites += 1;
                }
            }
            if (module.transform_cache) |transformed| try std.testing.expectEqual(sem.symbol_ids.len, transformed.symbol_ids.len);
        }
        try std.testing.expect(callsites > 0);
        try expectHostileRejection(&graph, graph.moduleAtMut(hostile_module.?).?, context);
    }
    if (missing_providers > 0) std.debug.print("missing actual dynamic callsite providers: {d}/10\n", .{missing_providers});
    try std.testing.expectEqual(@as(usize, 0), missing_providers);
}

test "single output import callsites conservatively reparse owner bound cache consumers" {
    const Bundler = @import("bundler.zig").Bundler;
    const helpers = @import("test_helpers.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try helpers.writeFile(tmp.dir, "entry.mjs", "function read(Promise){return import('./dep.cjs').then(m=>console.log(m.answer,Promise));}read(6);");
    try helpers.writeFile(tmp.dir, "dep.cjs", "exports.answer=42;");
    const entry = try helpers.absPath(&tmp, "entry.mjs");
    defer std.testing.allocator.free(entry);
    var store = @import("module_store.zig").PersistentModuleStore.init(std.testing.allocator);
    defer store.deinit();
    const options: @import("bundler.zig").BundleOptions = .{ .entry_points = &.{entry}, .module_store = &store, .inline_dynamic_imports = true };
    var cache = Bundler.initResolveCacheFromOptions(std.testing.allocator, options);
    defer cache.deinit();
    var graph = @import("graph.zig").ModuleGraph.init(std.testing.allocator, &cache);
    defer graph.deinit();
    var bundler = Bundler.initWithGraph(std.testing.allocator, options, &cache, &graph);
    defer bundler.deinit();
    var previous_output: ?[]u8 = null;
    defer if (previous_output) |value| std.testing.allocator.free(value);
    var previous_owner: @import("module.zig").SemanticOwnerToken = .unassigned;
    for (0..3) |round| {
        const result = try bundler.bundle(std.testing.io);
        defer result.deinit(std.testing.allocator);
        try std.testing.expect(!result.hasErrors());
        // The consumer deliberately misses; its old process-local foreign
        // provider handles must never be repaired from their printed names.
        try std.testing.expectEqual(@as(usize, if (round == 0) 2 else 1), result.reparsed_modules.?);
        const provider = graph.dynamic_import_ast_provider orelse return error.MissingDynamicImportAstProvider;
        try std.testing.expect(provider.active and provider.owner != .unassigned and provider.owner != previous_owner);
        previous_owner = provider.owner;
        try std.testing.expect(!store.modules.contains(entry));
        try std.testing.expect(!store.modules.contains("\x00zntc:runtime/dynamic-import-callsite"));
        if (previous_output) |expected| try std.testing.expectEqualStrings(expected, result.output) else previous_output = try std.testing.allocator.dupe(u8, result.output);
    }
}

test "single output import callsites retain explicit native boundaries without gating sibling eval" {
    const sources = [_][]const u8{
        "var result; with ({__dynamicImport:0}) { result=import('./dep.cjs'); } result.then(m=>console.log(m.answer));",
        "var result; with (Object.create({__dynamicImport:0})) { result=import('./dep.cjs'); } result.then(m=>console.log(m.answer));",
        "var result; with (new Proxy({__dynamicImport:0},{has(t,k){return k==='__dynamicImport';}})) { result=import('./dep.cjs'); } result.then(m=>console.log(m.answer));",
        "var result; with ({__dynamicImport:0,[Symbol.unscopables]:{__dynamicImport:true}}) { result=import('./dep.cjs'); } result.then(m=>console.log(m.answer));",
        "with ({__dynamicImport:0}) {} import('./dep.cjs').then(m=>console.log(m.answer));",
        "function read(Promise){eval('Promise');return import('./dep.cjs').then(m=>console.log(m.answer,Promise));}read(6);",
        "let reads=0;const options={get with(){reads++;return {}}};import('./dep.cjs',options).then(m=>console.log(m.answer,reads));",
        "var result;with((result=import('./dep.cjs'),{})){}result.then(m=>console.log(m.answer));",
    };
    const Bundler = @import("bundler.zig").Bundler;
    const helpers = @import("test_helpers.zig");
    for (sources, 0..) |source, context| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try helpers.writeFile(tmp.dir, "entry.js", source);
        try helpers.writeFile(tmp.dir, "dep.cjs", "exports.answer=42;");
        const entry = try helpers.absPath(&tmp, "entry.js");
        defer std.testing.allocator.free(entry);
        const options: @import("bundler.zig").BundleOptions = .{ .entry_points = &.{entry}, .inline_dynamic_imports = true };
        var cache = Bundler.initResolveCacheFromOptions(std.testing.allocator, options);
        defer cache.deinit();
        var graph = @import("graph.zig").ModuleGraph.init(std.testing.allocator, &cache);
        defer graph.deinit();
        var bundler = Bundler.initWithGraph(std.testing.allocator, options, &cache, &graph);
        defer bundler.deinit();
        const result = try bundler.bundle(std.testing.io);
        defer result.deinit(std.testing.allocator);
        try std.testing.expect(!result.hasErrors());
        const provider = graph.dynamic_import_ast_provider orelse return error.MissingDynamicImportAstProvider;
        try std.testing.expectEqual((context == 4 or context == 5 or context == 7), provider.active);
        var seen = false;
        var lowered_records: usize = 0;
        var modules = graph.modulesIterator();
        while (modules.next()) |module| for (module.import_records) |record| {
            if (record.kind != .dynamic_import or record.resolved.isNone()) continue;
            if (record.callsite_lowered) lowered_records += 1;
            seen = true;
        };
        try std.testing.expect(seen);
        // Speculative parser records can be detached even when their former
        // source span matches a live site. Only exact current sites lower.
        try std.testing.expectEqual((context == 4 or context == 5 or context == 7), lowered_records > 0);
    }
}

test "single output import callsites preserve real clone creation origins" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var scanner = try @import("../lexer/scanner.zig").Scanner.init(a, "import('./dep.cjs');");
    var parser = @import("../parser/parser.zig").Parser.init(a, &scanner);
    const original_root = try parser.parse();
    var analyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer.init(a, &parser.ast);
    try analyzer.analyze();
    var keys = analyzer.node_scope_provenance.keyIterator();
    const original = keys.next().?.*;
    const provenance = analyzer.node_scope_provenance.get(original).?;
    var transformer = try @import("../transformer/transformer.zig").Transformer.init(a, &parser.ast, .{});
    transformer.symbols = analyzer.symbols.items;
    transformer.scopes = analyzer.scopes.items;
    transformer.scope_maps = analyzer.scope_maps.items;
    transformer.scope_owner_map = analyzer.scope_owner_map;
    transformer.node_scope_provenance = analyzer.node_scope_provenance;
    transformer.references = analyzer.references.items;
    transformer.semantic_edit_enabled = true;
    try transformer.initSymbolIds(analyzer.symbol_ids.items);
    const cloned = try @import("../transformer/es_helpers.zig").cloneNode(&transformer, original);
    try std.testing.expect(cloned != original);
    try std.testing.expectEqualDeep(provenance, transformer.transformed_node_scope_provenance.get(cloned).?);
    const ast = transformer.ast;
    const statement = try ast.addNode(.{ .tag = .expression_statement, .span = ast.getNode(original).span, .data = .{ .unary = .{ .operand = cloned, .flags = 0 } } });
    const root = try ast.addNode(.{ .tag = .program, .span = ast.getNode(original_root).span, .data = .{ .list = try ast.addNodeList(&.{statement}) } });
    try transformer.remapCopiedScopeOwner(original_root, root);
    ast.transformed_root = root;
    try transformer.bindOutputScopesAndReferences(root, provenance.scope);
    const edited = (try transformer.finishSemanticEdit()).?;
    try std.testing.expectEqualDeep(provenance, edited.node_scope_provenance.get(cloned).?);
    try std.testing.expect(!edited.node_scope_provenance.contains(original));
    try std.testing.expect(edited.symbol_ids[@backingInt(cloned)] == null);
    var fresh = @import("../semantic/analyzer.zig").SemanticAnalyzer.init(a, ast);
    try fresh.analyze();
    const fresh_scope = fresh.node_scope_provenance.get(cloned).?.scope;
    try @import("../semantic/node_scope_provenance.zig").preserveSourceOrigins(ast, &fresh.node_scope_provenance, &edited.node_scope_provenance);
    try std.testing.expectEqual(original, fresh.node_scope_provenance.get(cloned).?.source_node);
    try std.testing.expectEqual(fresh_scope, fresh.node_scope_provenance.get(cloned).?.scope);
}
