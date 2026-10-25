//! Guarded lazy-import reads retain source identities and their actual scope.
const std = @import("std");
const ast_mod = @import("../parser/ast.zig");
const NodeIndex = ast_mod.NodeIndex;
const ScopeId = @import("../semantic/scope.zig").ScopeId;
const SymbolId = @import("../semantic/symbol.zig").SymbolId;
const Reference = @import("../semantic/symbol.zig").Reference;
const ModuleIndex = @import("types.zig").ModuleIndex;
const Module = @import("module.zig").Module;
const SymbolID = @import("symbol.zig").SymbolID;
const Binding = @import("binding_scanner.zig").ImportBinding;
const Builder = @import("runtime_callsite_builder.zig").Builder;
const walk = @import("../parser/ast_walk.zig");

const Initializers = struct { direct: SymbolID, value: SymbolID };
const Call = struct { node: NodeIndex, callee: NodeIndex, symbol: SymbolId, scope: ScopeId, direct_call: bool, shorthand_property: ?NodeIndex };
const Plan = struct { binding: usize, calls: []const Call, targets: Initializers };

fn targetsFor(graph: anytype, linker: anytype, module: *const Module, binding: Binding, sid: u32) !?Initializers {
    if (binding.kind != .named or binding.importsDefault() or binding.is_helper or binding.source_type_only == true or binding.callsite_target != null or binding.guarded_lazy_calls_lowered) return null;
    if (binding.import_record_index >= module.import_records.len) return error.InvalidGuardedImportBinding;
    const record = module.import_records[binding.import_record_index];
    if (record.kind != .static_import or record.resolved.isNone() or record.resolved == module.index or @import("linker.zig").isMetroNonInlinedRequireSpecifier(record.specifier)) return null;
    const direct = graph.getModule(record.resolved) orelse return error.InvalidGuardedImportBinding;
    if (direct.wrap_kind != .esm or !direct.shouldGuard(true) or direct.isUserDeclaredSideEffectful() or (linker.tree_shaker_active and !direct.is_included)) return null;
    const canonical = linker.getResolvedBinding(module.index.toU32(), binding.local_span) orelse return null;
    if (canonical.canonical.synthetic_member != null or !binding.symbol.isValid() or binding.symbol.semanticIndex() == null or binding.symbol.moduleIndex() != canonical.canonical.module_index) return null;
    const value = graph.getModule(binding.symbol.moduleIndex()) orelse return error.InvalidGuardedImportBinding;
    if (value.wrap_kind != .esm or !value.shouldGuard(true) or value.isUserDeclaredSideEffectful() or (linker.tree_shaker_active and !value.is_included)) return null;
    const value_semantic = value.semantic orelse return error.InvalidGuardedImportBinding;
    const value_sid = binding.symbol.semanticIndex().?;
    if (value_sid >= value_semantic.symbols.items.len or value_semantic.symbols.items[value_sid].synthetic_kind != null) return null;
    // Exporting a namespace binding has eager initialization semantics.
    for (value.import_bindings) |other| {
        if (other.kind == .namespace and other.local_symbol.semanticIndex() == value_sid) return null;
    }
    const ast = &module.ast.?;
    const sem = module.semantic.?;
    // Source local exports retain the metadata producer's eager policy. Use
    // exact local anchors, never a spelling lookup to select an identity.
    for (module.export_bindings) |exported| {
        if (exported.kind != .local) continue;
        const anchor = exported.local_symbol_node orelse continue;
        if (!anchor.isNone() and @backingInt(anchor) < ast.nodes.items.len and @backingInt(anchor) < sem.symbol_ids.len and sem.symbol_ids[@backingInt(anchor)] == sid) return null;
    }
    return .{ .direct = try direct.esmInitSymbol(), .value = try value.esmInitSymbol() };
}

const EagerHelper = struct { record: usize, target: SymbolID, bindings: []const usize };

/// Preserve the existing eager order: this slice owns helper-only eager
/// records; every other eager dependency must already be a deferred named read.
/// Mixed eager work stays with its current producer until the ordered phase owns it.
fn eagerHelpers(graph: anytype, linker: anytype, module: *const Module, a: std.mem.Allocator) ![]const EagerHelper {
    var result: std.ArrayList(EagerHelper) = .empty;
    for (module.import_records, 0..) |record, record_index| {
        if (!record.kind.isEagerEvalDependency() or record.callsite_lowered) continue;
        if (record.resolved.isNone() or record.kind != .static_import) return &.{};
        const target = graph.getModule(record.resolved) orelse return error.InvalidGuardedImportBinding;
        if (linker.tree_shaker_active and !target.is_included) continue;
        var helpers: std.ArrayList(usize) = .empty;
        var ordinary: usize = 0;
        for (module.import_bindings, 0..) |binding, index| {
            if (binding.import_record_index != record_index) continue;
            if (binding.is_helper) {
                if (binding.kind != .named or binding.importsDefault() or target.wrap_kind != .esm or !target.shouldGuard(true) or
                    !binding.symbol.isValid() or binding.symbol.semanticIndex() == null or binding.symbol.moduleIndex() != target.index) return &.{};
                try helpers.append(a, index);
            } else {
                const local = @import("binding_scanner.zig").resolveImportLocalSymbol(binding, .{ .module_index = module.index, .ast = &module.ast.?, .symbol_ids = module.semantic.?.symbol_ids, .symbols = module.semantic.?.symbols.items });
                const sid = local.semanticIndex() orelse return &.{};
                if (try targetsFor(graph, linker, module, binding, sid) == null) return &.{};
                ordinary += 1;
            }
        }
        if (helpers.items.len == 0 and ordinary == 0) return &.{};
        if (helpers.items.len != 0) {
            if (ordinary != 0) return &.{};
            try result.append(a, .{ .record = record_index, .target = try target.esmInitSymbol(), .bindings = helpers.items });
        }
    }
    return result.items;
}

fn projectStatementOwners(editor: anytype, root: NodeIndex, class_self_symbols: anytype, a: std.mem.Allocator) !void {
    var wanted: std.AutoHashMapUnmanaged(NodeIndex, void) = .empty;
    for (editor.references.items) |reference| {
        const anchor = if (!reference.node_index.isNone()) reference.node_index else reference.declaration_node_index;
        if (!anchor.isNone()) try wanted.put(a, anchor, {});
    }
    // Native class-self declarations have no leaf anchor. The initial typed
    // role selects the SID; its existing ScopeId selects the current class owner.
    var class_self_ids: std.AutoHashMapUnmanaged(u32, void) = .empty;
    var self_symbols = class_self_symbols.valueIterator();
    while (self_symbols.next()) |sid| try class_self_ids.put(a, sid.*, {});
    var scope_owners = editor.scope_owner_map.iterator();
    while (scope_owners.next()) |entry| {
        const node: NodeIndex = @fromBackingInt(entry.key_ptr.*);
        if (entry.key_ptr.* >= editor.ast.nodes.items.len) continue;
        const tag = editor.ast.getNode(node).tag;
        if (tag == .class_declaration or tag == .class_expression) try wanted.put(a, node, {});
    }
    // Anonymous default exports already carry their facade SID on the export
    // declaration itself, although their declaration Reference has no leaf.
    for (editor.ast.nodes.items, 0..) |node, raw| {
        if (node.tag == .export_default_declaration) try wanted.put(a, @fromBackingInt(@as(u32, @intCast(raw))), {});
    }
    var owners: std.AutoHashMapUnmanaged(NodeIndex, u32) = .empty;
    const list = editor.ast.getNode(root).data.list;
    var statements = editor.ast.iterateExtraList(list);
    var index: u32 = 0;
    while (statements.next()) |statement| : (index += 1) {
        for (try walk.collectReachableNodeIndicesFrom(a, editor.ast, statement)) |raw| {
            const node: NodeIndex = @fromBackingInt(raw);
            if (!wanted.contains(node)) continue;
            const found = try owners.getOrPut(a, node);
            if (found.found_existing and found.value_ptr.* != index) return error.AmbiguousGuardedStatementOwner;
            found.value_ptr.* = index;
        }
    }
    const OwnerContext = struct { node: NodeIndex, statement: u32 };
    var class_contexts: std.AutoHashMapUnmanaged(u32, OwnerContext) = .empty;
    scope_owners = editor.scope_owner_map.iterator();
    while (scope_owners.next()) |entry| {
        const node: NodeIndex = @fromBackingInt(entry.key_ptr.*);
        const statement = owners.get(node) orelse continue;
        const tag = editor.ast.getNode(node).tag;
        if (tag != .class_declaration and tag != .class_expression) continue;
        const slot = try class_contexts.getOrPut(a, entry.value_ptr.*);
        if (slot.found_existing and slot.value_ptr.node != node) return error.AmbiguousGuardedClassOwner;
        slot.value_ptr.* = .{ .node = node, .statement = statement };
    }
    var default_contexts: std.AutoHashMapUnmanaged(u32, OwnerContext) = .empty;
    var live_anchors = owners.iterator();
    while (live_anchors.next()) |entry| {
        const node = entry.key_ptr.*;
        const sid = (@import("default_facade_identity.zig").symbolAt(editor.ast, node, editor.symbol_ids.items, editor.symbols.items) catch
            return error.InvalidGuardedDefaultFacade) orelse continue;
        const slot = try default_contexts.getOrPut(a, sid);
        if (slot.found_existing and slot.value_ptr.node != node) return error.AmbiguousGuardedDefaultFacade;
        slot.value_ptr.* = .{ .node = node, .statement = entry.value_ptr.* };
    }
    for (editor.references.items) |*reference| {
        const anchor = if (!reference.node_index.isNone()) reference.node_index else reference.declaration_node_index;
        reference.stmt_idx = owners.get(anchor) orelse Reference.NO_STMT;
        if (anchor.isNone() and reference.flags.declare) {
            if (default_contexts.get(@backingInt(reference.symbol_id))) |context| {
                if (reference.scope_id.toIndex() != 0) return error.InvalidGuardedDefaultFacade;
                reference.stmt_idx = context.statement;
            }
        }
        if (anchor.isNone() and reference.flags.declare and class_self_ids.contains(@backingInt(reference.symbol_id))) {
            const symbol = editor.symbols.items[@backingInt(reference.symbol_id)];
            const scope = symbol.scope_id;
            if (symbol.kind != .class_decl or scope.isNone() or scope.toIndex() >= editor.scopes.items.len or
                scope != reference.scope_id or editor.scopes.items[scope.toIndex()].kind != .class_body) return error.InvalidGuardedClassSelf;
            if (class_contexts.get(@backingInt(scope))) |context| {
                reference.stmt_idx = context.statement;
                // Only the program statement list changes. Existing nested
                // statement lists retain their original per-scope coordinates.
                if (editor.scopes.items[scope.toIndex()].parent.toIndex() == 0) reference.scope_stmt_idx = context.statement;
            }
        }
        if (reference.scope_id.toIndex() == 0) reference.scope_stmt_idx = reference.stmt_idx;
    }
}

/// Statement metadata may change; SymbolId/ScopeId and source read identities do not.
fn refreshStatementInfo(module: *Module, shaker: ?*@import("tree_shaker.zig").TreeShaker, newly_live: []const NodeIndex) !void {
    const a = module.parse_arena.?.allocator();
    const ast = &module.ast.?;
    const sem = &module.semantic.?;
    const rebuilt = try @import("stmt_info.zig").buildFromSemantic(a, ast, sem.symbols.items, sem.scopes, sem.references, &sem.unresolved_references, false, false) orelse return;
    module.prebuilt_stmt_info = rebuilt;
    const s = shaker orelse return;
    const index = module.index.toU32();
    if (index >= s.module_stmt_infos.len or index >= s.reachable_stmts.len) return error.InvalidGuardedStatementState;
    const old = s.module_stmt_infos[index] orelse return; // Preserve opaque wrapped-module policy.
    var alive: std.AutoHashMapUnmanaged(u32, void) = .empty;
    if (s.reachable_stmts[index]) |reachable| {
        for (old.stmts, 0..) |statement, i| if (i < reachable.capacity() and reachable.isSet(i)) try alive.put(a, statement.node_idx, {});
    }
    for (newly_live) |statement| try alive.put(a, @backingInt(statement), {});
    var replacement = try std.DynamicBitSet.initEmpty(s.allocator, rebuilt.stmts.len);
    errdefer replacement.deinit();
    for (rebuilt.stmts, 0..) |statement, i| if (alive.contains(statement.node_idx)) replacement.set(i);
    if (s.prebuilt_mask) |*mask| {
        if (!mask.isSet(index)) {
            var owned = old;
            owned.deinit();
        }
        mask.set(index);
    } else return error.InvalidGuardedStatementState;
    if (s.reachable_stmts[index]) |*previous| previous.deinit();
    s.reachable_stmts[index] = replacement;
    s.module_stmt_infos[index] = rebuilt;
    module.reachable_stmts = &s.reachable_stmts[index].?;
    module.symbol_to_stmt = rebuilt.symbol_to_stmt;
}

pub fn lower(graph: *@import("graph.zig").ModuleGraph, linker: *@import("linker.zig").Linker, shaker: ?*@import("tree_shaker.zig").TreeShaker) !void {
    if (!linker.inline_requires or !linker.entry_error_guard or graph.entry_guard_ast_provider == null) return;
    const guard = try @import("runtime_entry_guard_ast.zig").exactBinding(graph);
    const count = graph.moduleCount();
    var activated = false;
    for (0..count) |raw| {
        const module = graph.moduleAtMut(ModuleIndex.fromUsize(raw)) orelse continue;
        if (module.wrap_kind != .esm) continue;
        if (shaker) |s| if (!s.isIncluded(@intCast(raw))) continue;
        const ast = if (module.ast) |*value| value else continue;
        const sem = if (module.semantic) |*value| value else continue;
        const a = module.parse_arena.?.allocator();
        const root = ast.transformed_root orelse @as(NodeIndex, @fromBackingInt(@as(u32, @intCast(ast.nodes.items.len - 1))));
        const live = try walk.collectReachableNodeIndices(a, ast);
        var live_set: std.AutoHashMapUnmanaged(NodeIndex, void) = .empty;
        var call_by_callee: std.AutoHashMapUnmanaged(NodeIndex, NodeIndex) = .empty;
        var shorthand_by_value: std.AutoHashMapUnmanaged(NodeIndex, NodeIndex) = .empty;
        for (live) |node_raw| {
            const node: NodeIndex = @fromBackingInt(node_raw);
            try live_set.put(a, node, {});
            const data = ast.getNode(node);
            if (data.tag == .object_property and data.data.binary.right.isNone() and !data.data.binary.left.isNone()) {
                const value = data.data.binary.left;
                if (ast.getNode(value).tag == .identifier_reference) try shorthand_by_value.put(a, value, node);
            }
            if (data.tag == .call_expression) {
                const callee = ast.readExtraNode(data.data.extra, 0);
                if (!callee.isNone() and ast.getNode(callee).tag == .identifier_reference) try call_by_callee.put(a, callee, node);
            }
        }
        var plans: std.ArrayList(Plan) = .empty;
        for (module.import_bindings, 0..) |binding, index| {
            const local = @import("binding_scanner.zig").resolveImportLocalSymbol(binding, .{ .module_index = module.index, .ast = ast, .symbol_ids = sem.symbol_ids, .symbols = sem.symbols.items });
            const sid = local.semanticIndex() orelse continue;
            const targets = try targetsFor(graph, linker, module, binding, sid) orelse continue;
            var calls: std.ArrayList(Call) = .empty;
            var supported = true;
            for (sem.references) |reference| {
                if (@backingInt(reference.symbol_id) != sid or !reference.isValueUse() or !live_set.contains(reference.node_index)) continue;
                if (ast.getNode(reference.node_index).tag != .identifier_reference) {
                    supported = false;
                    break;
                }
                const call = call_by_callee.get(reference.node_index);
                if (!reference.flags.read or reference.flags.write) {
                    supported = false;
                    break;
                }
                try calls.append(a, .{ .node = call orelse reference.node_index, .callee = reference.node_index, .symbol = reference.symbol_id, .scope = reference.scope_id, .direct_call = call != null, .shorthand_property = shorthand_by_value.get(reference.node_index) });
            }
            if (supported and calls.items.len != 0) try plans.append(a, .{ .binding = index, .calls = calls.items, .targets = targets });
        }
        const eager = try eagerHelpers(graph, linker, module, a);
        if (plans.items.len == 0 and eager.len == 0) continue;
        var editor = try sem.beginEdit(a, ast);
        defer editor.deinit();
        var builder: Builder = .{ .allocator = a, .module = module, .graph = graph, .ast = ast, .editor = &editor };
        const guard_local = try builder.imported(guard, .entry_guard);
        var initializer_locals: std.AutoHashMapUnmanaged(SymbolID, SymbolId) = .empty;
        var prologue: std.ArrayList(NodeIndex) = .empty;
        var initialized: std.AutoHashMapUnmanaged(SymbolID, void) = .empty;
        for (eager) |owned| {
            for (owned.bindings) |binding_index| module.import_bindings[binding_index].guarded_eager_init_lowered = true;
            if (initialized.contains(owned.target)) continue;
            try initialized.put(a, owned.target, {});
            const local = try builder.imported(owned.target, .esm_init);
            try initializer_locals.put(a, owned.target, local);
            const scope: ScopeId = @fromBackingInt(@as(u32, 0));
            const call = try builder.call(try builder.reference(guard_local, scope), &.{try builder.reference(local, scope)});
            try editor.recordNodeScopeProvenance(call, scope);
            const statement = try ast.addNode(.{ .tag = .expression_statement, .span = .EMPTY, .data = .{ .unary = .{ .operand = call, .flags = 0 } } });
            try prologue.append(a, statement);
        }
        for (plans.items) |plan| {
            for (plan.calls) |call| {
                const reference = try editor.referenceForNode(call.callee) orelse return error.InvalidGuardedImportReference;
                if (reference.scope_id != call.scope or reference.symbol_id != call.symbol) return error.InvalidGuardedImportReference;
                const original = ast.getNode(call.node);
                const clone = try ast.addNode(original);
                if (!call.direct_call) {
                    // The expression replaces this leaf, so explicitly move its
                    // original semantic read to the copied identifier first.
                    try editor.cloneReferenceAtSameLocation(call.callee, clone);
                    try editor.removeReference(call.callee);
                    if (call.shorthand_property) |property_node| {
                        const key = try ast.addNode(original);
                        var property = ast.getNode(property_node);
                        property.data.binary.left = key;
                        property.data.binary.right = call.node;
                        ast.nodes.items[@backingInt(property_node)] = property;
                    }
                }
                var sequence: std.ArrayList(NodeIndex) = .empty;
                const targets = [_]SymbolID{ plan.targets.direct, plan.targets.value };
                for (targets, 0..) |target, i| {
                    if (i == 1 and target.eql(targets[0])) continue;
                    const local = if (initializer_locals.get(target)) |existing| existing else blk: {
                        const created = try builder.imported(target, .esm_init);
                        try initializer_locals.put(a, target, created);
                        break :blk created;
                    };
                    const callee = try builder.reference(guard_local, call.scope);
                    const argument = try builder.reference(local, call.scope);
                    try editor.moveReference(callee, call.scope, reference.stmt_idx, reference.scope_stmt_idx);
                    try editor.moveReference(argument, call.scope, reference.stmt_idx, reference.scope_stmt_idx);
                    const guarded = try builder.call(callee, &.{argument});
                    try editor.recordNodeScopeProvenance(guarded, call.scope);
                    try sequence.append(a, guarded);
                }
                try editor.recordNodeScopeProvenance(clone, call.scope);
                try sequence.append(a, clone);
                const list = try ast.addNodeList(sequence.items);
                ast.nodes.items[@backingInt(call.node)] = .{ .tag = .sequence_expression, .span = original.span, .data = .{ .list = list } };
                try editor.recordNodeScopeProvenance(call.node, call.scope);
            }
            module.import_bindings[plan.binding].guarded_lazy_calls_lowered = true;
        }
        var statements: std.ArrayList(NodeIndex) = .empty;
        var original_statements = ast.iterateExtraList(ast.getNode(root).data.list);
        var prologue_inserted = false;
        while (original_statements.next()) |statement| {
            if (!prologue_inserted and ast.getNode(statement).tag != .directive) {
                try statements.appendSlice(a, prologue.items);
                prologue_inserted = true;
            }
            try statements.append(a, statement);
        }
        if (!prologue_inserted) try statements.appendSlice(a, prologue.items);
        try statements.appendSlice(a, builder.declarations.items);
        const replacement = try ast.addNode(.{ .tag = .program, .span = ast.getNode(root).span, .data = .{ .list = try ast.addNodeList(statements.items) } });
        try editor.remapScopeOwner(root, replacement);
        ast.transformed_root = replacement;
        try projectStatementOwners(&editor, replacement, &sem.class_self_symbol_map, a);
        try builder.validate();
        sem.applyEdit(try editor.finish());
        var added: std.ArrayList(NodeIndex) = .empty;
        try added.appendSlice(a, prologue.items);
        try added.appendSlice(a, builder.declarations.items);
        try refreshStatementInfo(module, shaker, added.items);
        if (module.transform_cache) |*cache| cache.symbol_ids = sem.symbol_ids;
        activated = true;
    }
    if (activated) try @import("runtime_entry_guard_ast.zig").activate(graph, shaker);
}

test "guarded lazy source calls preserve original callee identity and actual nested scope" {
    const Bundler = @import("bundler.zig").Bundler;
    const helpers = @import("test_helpers.zig");
    for ([_][]const u8{
        "function run(__zntc_guarded){const offset=1;return value()+offset-1;}globalThis.actual=run(null);",
        "class Box{run(__zntc_guarded){const offset=1;return value()+offset-1;}}globalThis.actual=new Box().run(null);",
        "function* run(__zntc_guarded){yield value();}globalThis.actual=run(null).next().value;",
        "const Box=class Inner{static self(){return Inner;}run(){return value();}};globalThis.actual=new Box().run();",
        "export default function(){return value();}globalThis.actual=42;",
        "export default (globalThis.load=function(){return value();});globalThis.actual=globalThis.load();",
        "function* source(){yield 0;}export default (globalThis.load=function(){return value()+source().next().value;});globalThis.actual=globalThis.load();",
        "class Box{static self(){return Box;}run(){return value();}}globalThis.actual=new Box().run();",
        "function* source(){yield 0;}class Box{static self(){return Box;}run(){return value()+source().next().value;}}globalThis.actual=new Box().run();",
        "function* source(){yield 0;}function run(){const Box=class Inner{static self(){return Inner;}run(){return value()+source().next().value;}};return new Box().run();}globalThis.actual=run();",
        "function run(__zntc_guarded){for(let n=0;n<1;n++){const call=()=>{let offset=1;return value()+offset-1;};return call();}}globalThis.actual=run(null);",
    }) |body| for ([_]bool{ true, false }) |tree_shaking| for ([_]bool{ false, true }) |native_classes| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const source = try std.fmt.allocPrint(std.testing.allocator, "import {{value}} from './dep.mjs';{s}", .{body});
        defer std.testing.allocator.free(source);
        try helpers.writeFile(tmp.dir, "entry.mjs", source);
        try helpers.writeFile(tmp.dir, "second.mjs", "import {value} from './dep.mjs';globalThis.second=value;");
        try helpers.writeFile(tmp.dir, "dep.mjs", "export function value(){return 42;}");
        const entry = try helpers.absPath(&tmp, "entry.mjs");
        defer std.testing.allocator.free(entry);
        const second = try helpers.absPath(&tmp, "second.mjs");
        defer std.testing.allocator.free(second);
        const options: @import("bundler.zig").BundleOptions = .{ .entry_points = &.{ entry, second }, .platform = .react_native, .rn_version_matrix = if (native_classes) .{ .generator = true } else null, .code_splitting = true, .entry_error_guard = true, .strict_execution_order = true, .tree_shaking = tree_shaking, .minify_whitespace = true };
        var cache = Bundler.initResolveCacheFromOptions(std.testing.allocator, options);
        defer cache.deinit();
        var graph = @import("graph.zig").ModuleGraph.init(std.testing.allocator, &cache);
        defer graph.deinit();
        var bundler = Bundler.initWithGraph(std.testing.allocator, options, &cache, &graph);
        defer bundler.deinit();
        const output = try bundler.bundle(std.testing.io);
        defer output.deinit(std.testing.allocator);
        try std.testing.expect(!output.hasErrors());
        const module = graph.getModule(graph.path_to_module.get(entry).?).?;
        const sem = module.semantic.?;
        const ast = &module.ast.?;
        var original: ?Binding = null;
        for (module.import_bindings) |binding| {
            if (binding.callsite_target != null or binding.is_helper) continue;
            try std.testing.expect(original == null);
            original = binding;
        }
        const original_binding = original orelse return error.MissingOriginalImport;
        try std.testing.expect(original_binding.guarded_lazy_calls_lowered);
        const original_sid = original_binding.local_symbol.semanticIndex().?;
        var use_scope: ScopeId = .none;
        var value_node: NodeIndex = .none;
        var original_scope_stmt = Reference.NO_STMT;
        for (sem.references) |reference| {
            if (@backingInt(reference.symbol_id) == original_sid and reference.isValueUse()) {
                try std.testing.expect(use_scope.isNone());
                use_scope = reference.scope_id;
                original_scope_stmt = reference.scope_stmt_idx;
                value_node = reference.node_index;
            }
        }
        try std.testing.expect(!use_scope.isNone() and use_scope.toIndex() != 0);
        try std.testing.expect(original_scope_stmt != Reference.NO_STMT);
        try std.testing.expectEqual(@as(?u32, original_sid), sem.symbol_ids[@backingInt(value_node)]);
        var generated_reads: usize = 0;
        for (module.import_bindings) |binding| {
            const target = binding.callsite_target orelse continue;
            try @import("runtime_callsite_targets.zig").validateTargetRole(&graph, target);
            for (sem.references) |reference| {
                if (!reference.isValueUse() or binding.local_symbol.semanticIndex() != @backingInt(reference.symbol_id)) continue;
                if (reference.scope_id == use_scope) {
                    try std.testing.expectEqual(original_scope_stmt, reference.scope_stmt_idx);
                    generated_reads += 1;
                } else try std.testing.expectEqual(@as(usize, 0), reference.scope_id.toIndex());
            }
        }
        try std.testing.expect(generated_reads >= 2);
        const current_root = ast.transformed_root.?;
        const current_list = ast.getNode(current_root).data.list;
        try std.testing.expectEqual(current_list.len, @as(u32, @intCast(module.prebuilt_stmt_info.?.stmts.len)));
        var top_statements = ast.iterateExtraList(current_list);
        var top_index: u32 = 0;
        while (top_statements.next()) |statement| : (top_index += 1) {
            for (try walk.collectReachableNodeIndicesFrom(module.parse_arena.?.allocator(), ast, statement)) |raw| {
                for (sem.references) |reference| {
                    const anchor = if (!reference.node_index.isNone()) reference.node_index else reference.declaration_node_index;
                    if (!anchor.isNone() and @backingInt(anchor) == raw) try std.testing.expectEqual(top_index, reference.stmt_idx);
                    if (!reference.flags.declare or !anchor.isNone()) continue;
                    const symbol = sem.symbols.items[@backingInt(reference.symbol_id)];
                    if (ast.nodes.items[raw].tag == .export_default_declaration and symbol.decl_flags.is_default_export and sem.symbol_ids[raw] == @as(?u32, @backingInt(reference.symbol_id))) {
                        try std.testing.expectEqual(top_index, reference.stmt_idx);
                        try std.testing.expectEqual(top_index, reference.scope_stmt_idx);
                        continue;
                    }
                    const scope = symbol.scope_id;
                    const owner_scope = sem.scope_owner_map.get(raw) orelse continue;
                    const tag = ast.nodes.items[raw].tag;
                    if (owner_scope != scope.toIndex() or (tag != .class_declaration and tag != .class_expression)) continue;
                    var known_self = false;
                    var self_symbols = sem.class_self_symbol_map.valueIterator();
                    while (self_symbols.next()) |sid| if (sid.* == @backingInt(reference.symbol_id)) {
                        known_self = true;
                    };
                    if (!known_self) continue;
                    try std.testing.expectEqual(top_index, reference.stmt_idx);
                    if (sem.scopes[scope.toIndex()].parent.toIndex() == 0) try std.testing.expectEqual(top_index, reference.scope_stmt_idx);
                }
            }
        }
        var actual_calls: usize = 0;
        for (try walk.collectReachableNodeIndices(module.parse_arena.?.allocator(), ast)) |raw| {
            const node = ast.nodes.items[raw];
            if (node.tag == .call_expression and ast.readExtraNode(node.data.extra, 0) == value_node) actual_calls += 1;
        }
        try std.testing.expectEqual(@as(usize, 1), actual_calls);
        try helpers.writeFile(tmp.dir, "package.json", "{\"type\":\"module\"}");
        for (output.outputs.?) |file| try helpers.writeFile(tmp.dir, std.fs.path.basename(file.path), file.contents);
        const emitted = try helpers.absPath(&tmp, "entry.js");
        defer std.testing.allocator.free(emitted);
        const script = try std.fmt.allocPrint(std.testing.allocator, "await import('file://{s}');console.log(globalThis.actual);", .{emitted});
        defer std.testing.allocator.free(script);
        const execution = try std.process.run(std.testing.allocator, std.testing.io, .{ .argv = &.{ "node", "--input-type=module", "-e", script }, .stdout_limit = .limited(16384), .stderr_limit = .limited(16384) });
        defer std.testing.allocator.free(execution.stdout);
        defer std.testing.allocator.free(execution.stderr);
        try std.testing.expectEqualStrings("42\n", execution.stdout);
    };
}

test "guarded lazy source calls preserve late reporter and argument evaluation order" {
    const Bundler = @import("bundler.zig").Bundler;
    const helpers = @import("test_helpers.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try helpers.writeFile(tmp.dir, "package.json", "{\"type\":\"module\"}");
    try helpers.writeFile(tmp.dir, "entry.mjs", "import{value}from'./dep.mjs';globalThis.load=function(){return value((events.push('argument'),1));};");
    try helpers.writeFile(tmp.dir, "second.mjs", "import{value}from'./dep.mjs';globalThis.second=value;");
    try helpers.writeFile(tmp.dir, "dep.mjs", "throw new Error('dependency');export function value(){return 42;}");
    const entry = try helpers.absPath(&tmp, "entry.mjs");
    defer std.testing.allocator.free(entry);
    const second = try helpers.absPath(&tmp, "second.mjs");
    defer std.testing.allocator.free(second);
    const options: @import("bundler.zig").BundleOptions = .{ .entry_points = &.{ entry, second }, .platform = .react_native, .code_splitting = true, .entry_error_guard = true, .strict_execution_order = true };
    var cache = Bundler.initResolveCacheFromOptions(std.testing.allocator, options);
    defer cache.deinit();
    var graph = @import("graph.zig").ModuleGraph.init(std.testing.allocator, &cache);
    defer graph.deinit();
    var bundler = Bundler.initWithGraph(std.testing.allocator, options, &cache, &graph);
    defer bundler.deinit();
    const output = try bundler.bundle(std.testing.io);
    defer output.deinit(std.testing.allocator);
    try std.testing.expect(!output.hasErrors());
    for (output.outputs.?) |file| try helpers.writeFile(tmp.dir, std.fs.path.basename(file.path), file.contents);
    const emitted = try helpers.absPath(&tmp, "entry.js");
    defer std.testing.allocator.free(emitted);
    const script = try std.fmt.allocPrint(std.testing.allocator, "globalThis.events=[];globalThis.ErrorUtils={{reportFatalError(e){{events.push(e.message)}}}};await import('file://{s}');events.push(globalThis.load());console.log(JSON.stringify(events));", .{emitted});
    defer std.testing.allocator.free(script);
    const execution = try std.process.run(std.testing.allocator, std.testing.io, .{ .argv = &.{ "node", "--input-type=module", "-e", script }, .stdout_limit = .limited(16384), .stderr_limit = .limited(16384) });
    defer std.testing.allocator.free(execution.stdout);
    defer std.testing.allocator.free(execution.stderr);
    try std.testing.expectEqualStrings("[\"dependency\",\"argument\",42]\n", execution.stdout);
}

test "guarded imported value reads keep exact local identity scope and receivers" {
    const Bundler = @import("bundler.zig").Bundler;
    const helpers = @import("test_helpers.zig");
    const Case = struct { body: []const u8, dependency: []const u8 = "export function value(){return 42;}", expected: []const u8 = "42\n", reads: usize = 1 };
    for ([_]Case{
        .{ .body = "function run(__zntc_guarded){return value;}globalThis.actual=run(null)();" },
        .{ .body = "function run(__zntc_guarded){return typeof value;}globalThis.actual=run(null);", .expected = "function\n" },
        .{ .body = "function run(__zntc_guarded){return {value};}globalThis.actual=run(null).value();", .dependency = "globalThis.__guardValueReady=true;export function value(){return globalThis.__guardValueReady?42:-1;}" },
        .{ .body = "function run(__zntc_guarded){return [value];}globalThis.actual=run(null)[0]();" },
        .{ .body = "function run(__zntc_guarded){return [...value];}globalThis.actual=run(null)[0];", .dependency = "export const value=[42];" },
        .{ .body = "function run(__zntc_guarded){return new value() instanceof value;}globalThis.actual=run(null);", .expected = "true\n", .reads = 2 },
        .{ .body = "function run(__zntc_guarded){return value`text`;}globalThis.actual=run(null);" },
        .{ .body = "function run(__zntc_guarded){return value.call(undefined);}globalThis.actual=run(null);" },
        .{ .body = "function run(__zntc_guarded){return value?.();}globalThis.actual=run(null);" },
        .{ .body = "function run(__zntc_guarded){return value.run();}globalThis.actual=run(null);", .dependency = "export const value={run(){return this===value;}};", .expected = "true\n" },
    }) |case| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const source = try std.fmt.allocPrint(std.testing.allocator, "import{{value}}from'./dep.mjs';{s}", .{case.body});
        defer std.testing.allocator.free(source);
        try helpers.writeFile(tmp.dir, "entry.mjs", source);
        try helpers.writeFile(tmp.dir, "second.mjs", "import{value}from'./dep.mjs';globalThis.second=value;");
        try helpers.writeFile(tmp.dir, "dep.mjs", case.dependency);
        const entry = try helpers.absPath(&tmp, "entry.mjs");
        defer std.testing.allocator.free(entry);
        const second = try helpers.absPath(&tmp, "second.mjs");
        defer std.testing.allocator.free(second);
        const options: @import("bundler.zig").BundleOptions = .{ .entry_points = &.{ entry, second }, .platform = .react_native, .code_splitting = true, .entry_error_guard = true, .strict_execution_order = true, .minify_whitespace = true };
        var cache = Bundler.initResolveCacheFromOptions(std.testing.allocator, options);
        defer cache.deinit();
        var graph = @import("graph.zig").ModuleGraph.init(std.testing.allocator, &cache);
        defer graph.deinit();
        var bundler = Bundler.initWithGraph(std.testing.allocator, options, &cache, &graph);
        defer bundler.deinit();
        const output = try bundler.bundle(std.testing.io);
        defer output.deinit(std.testing.allocator);
        try std.testing.expect(!output.hasErrors());
        const module = graph.getModule(graph.path_to_module.get(entry).?).?;
        const sem = &module.semantic.?;
        const ast = &module.ast.?;
        var original: ?Binding = null;
        for (module.import_bindings) |binding| {
            if (binding.callsite_target != null or binding.is_helper) continue;
            try std.testing.expect(original == null);
            original = binding;
        }
        const binding = original orelse return error.MissingOriginalImport;
        try std.testing.expect(binding.guarded_lazy_calls_lowered);
        const local = @import("binding_scanner.zig").resolveImportLocalSymbol(binding, .{ .module_index = module.index, .ast = ast, .symbol_ids = sem.symbol_ids, .symbols = sem.symbols.items });
        const sid = local.semanticIndex().?;
        try std.testing.expectEqual(binding.local_symbol.semanticIndex().?, sid);
        var reads: usize = 0;
        for (sem.references) |reference| {
            if (@backingInt(reference.symbol_id) != sid or !reference.isValueUse()) continue;
            reads += 1;
            try std.testing.expect(reference.flags.read and !reference.flags.write);
            try std.testing.expect(reference.scope_id.toIndex() != 0);
            try std.testing.expectEqual(ast_mod.Node.Tag.identifier_reference, ast.getNode(reference.node_index).tag);
            try std.testing.expectEqual(@as(?u32, sid), sem.symbol_ids[@backingInt(reference.node_index)]);
            try std.testing.expect(reference.stmt_idx != Reference.NO_STMT and reference.scope_stmt_idx != Reference.NO_STMT);
        }
        try std.testing.expectEqual(case.reads, reads);
        try helpers.writeFile(tmp.dir, "package.json", "{\"type\":\"module\"}");
        for (output.outputs.?) |file| try helpers.writeFile(tmp.dir, std.fs.path.basename(file.path), file.contents);
        const emitted = try helpers.absPath(&tmp, "entry.js");
        defer std.testing.allocator.free(emitted);
        const script = try std.fmt.allocPrint(std.testing.allocator, "await import('file://{s}');console.log(globalThis.actual);", .{emitted});
        defer std.testing.allocator.free(script);
        const execution = try std.process.run(std.testing.allocator, std.testing.io, .{ .argv = &.{ "node", "--input-type=module", "-e", script }, .stdout_limit = .limited(16384), .stderr_limit = .limited(16384) });
        defer std.testing.allocator.free(execution.stdout);
        defer std.testing.allocator.free(execution.stderr);
        try std.testing.expectEqualStrings(case.expected, execution.stdout);
    }
}
