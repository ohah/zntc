//! Checked GetValue for legacy imported lexical cells before final naming.
//! Source import declarations and PutValue targets keep their original roles.
const std = @import("std");
const Ast = @import("../../parser/ast.zig");
const NodeIndex = Ast.NodeIndex;
const SymbolID = @import("../symbol.zig").SymbolID;
const SymbolId = @import("../../semantic/symbol.zig").SymbolId;
const ScopeId = @import("../../semantic/scope.zig").ScopeId;
const Reference = @import("../../semantic/symbol.zig").Reference;
const Builder = @import("../runtime_callsite_builder.zig").Builder;
const ReadPlan = @import("../lexical_initialization_plan.zig").ReadPlan;

pub const GuardedInitializer = struct { call: NodeIndex, target: SymbolID, local: SymbolId };
pub const GuardedProjection = struct {
    expression: NodeIndex,
    source_value: NodeIndex,
    guard_local: ?SymbolId,
    initializers: []const GuardedInitializer,
};

pub const Receipt = struct {
    plan: ReadPlan,
    export_index: u32,
    guard: NodeIndex,
    value: NodeIndex,
    flag: NodeIndex,
    helper: NodeIndex,
    failure: NodeIndex,
    source_local: SymbolId,
    flag_local: SymbolId,
    helper_local: SymbolId,
    scope: ScopeId,
    registry_key: ?@import("legacy_initialization_registry.zig").Key = null,
    registry_helper: NodeIndex = .none,
    guarded_projection: ?GuardedProjection = null,
};

pub fn lower(graph: *@import("../graph.zig").ModuleGraph, linker: *@import("../linker.zig").Linker) !bool {
    if (graph.lexical_tdz_builtin == null) return false;
    const helper = try @import("../lexical_initialization_builtin.zig").exact(graph);
    var changed_any = try @import("legacy_initialization_registry.zig").lower(graph);
    for (0..graph.moduleCount()) |index| {
        const module = graph.moduleAtMut(@import("../types.zig").ModuleIndex.fromUsize(index)) orelse continue;
        if (module.legacy_lexical_reads.len != 0) {
            try validate(graph, module);
            continue;
        }
        const tree = if (module.ast) |*value| value else continue;
        const semantic = if (module.semantic) |*value| value else continue;
        const a = module.parse_arena.?.allocator();
        const ImportPlan = struct { local: u32, plan: ReadPlan, export_index: u32 };
        var imports: std.ArrayList(ImportPlan) = .empty;
        var wanted: std.AutoHashMapUnmanaged(u32, void) = .empty;
        // Ordinary modules with no checked provider edge do no AST walk or
        // editor copy. Selection remains exact import-local and export IDs.
        for (module.import_bindings) |binding| {
            if ((binding.kind != .named and !binding.importsDefault()) or binding.is_helper or binding.callsite_target != null or binding.source_type_only == true) continue;
            const resolved = linker.getResolvedBinding(module.index.toU32(), binding.local_span) orelse continue;
            if (resolved.canonical.synthetic_member != null) continue;
            const provider = graph.getModule(resolved.canonical.module_index) orelse return error.InvalidLexicalInitializationRead;
            const exported = provider.findExportBinding(resolved.canonical.export_name) orelse continue;
            const plan = (try ReadPlan.fromExport(provider, exported.*)) orelse continue;
            const local = try module.checkedSourceImportLocalSymbol(binding);
            const sid = local.semanticIndex() orelse return error.InvalidLexicalInitializationRead;
            const export_index = (@intFromPtr(exported) - @intFromPtr(provider.export_bindings.ptr)) / @sizeOf(@import("../module.zig").ExportBinding);
            try imports.append(a, .{ .local = sid, .plan = plan, .export_index = @intCast(export_index) });
            try wanted.put(a, sid, {});
        }
        if (imports.items.len == 0) continue;
        const root = tree.transformed_root orelse @as(NodeIndex, @fromBackingInt(@as(u32, @intCast(tree.nodes.items.len - 1))));
        const live = try @import("../../parser/ast_walk.zig").collectReachableNodeIndices(a, tree);
        var live_set: std.AutoHashMapUnmanaged(NodeIndex, void) = .empty;
        var forbidden: std.AutoHashMapUnmanaged(NodeIndex, void) = .empty;
        var shorthand: std.AutoHashMapUnmanaged(NodeIndex, NodeIndex) = .empty;
        for (live) |raw| {
            const node: NodeIndex = @fromBackingInt(raw);
            try live_set.put(a, node, {});
            const data = tree.getNode(node);
            if (data.tag == .export_specifier) {
                try forbidden.put(a, data.data.binary.left, {});
                try forbidden.put(a, data.data.binary.right, {});
            }
            if (data.tag == .object_property and data.data.binary.right.isNone() and !data.data.binary.left.isNone())
                try shorthand.put(a, data.data.binary.left, node);
        }
        var by_symbol: std.AutoHashMapUnmanaged(u32, std.ArrayList(Reference)) = .empty;
        for (semantic.references) |reference| {
            if (!reference.isValueUse() or !reference.flags.read or reference.flags.write or
                reference.symbol_id.isNone() or !wanted.contains(@backingInt(reference.symbol_id)) or reference.node_index.isNone() or !live_set.contains(reference.node_index) or
                forbidden.contains(reference.node_index) or tree.getNode(reference.node_index).tag != .identifier_reference) continue;
            const entry = try by_symbol.getOrPut(a, @backingInt(reference.symbol_id));
            if (!entry.found_existing) entry.value_ptr.* = .empty;
            try entry.value_ptr.append(a, reference);
        }
        var editor = try semantic.beginEdit(a, tree);
        defer editor.deinit();
        var builder: Builder = .{ .allocator = a, .ast = tree, .editor = &editor, .module = module, .graph = graph };
        var receipts: std.ArrayList(Receipt) = .empty;
        var flag_locals: std.AutoHashMapUnmanaged(SymbolID, SymbolId) = .empty;
        var helper_local: ?SymbolId = null;
        for (imports.items) |selected| {
            const sid = selected.local;
            const plan = selected.plan;
            const export_index = selected.export_index;
            const reads = by_symbol.get(sid) orelse continue;
            const flag_target = SymbolID.fromRef(plan.initialized) orelse return error.InvalidLexicalInitializationRead;
            const helper_id = helper_local orelse created: {
                const known = graph.lexical_tdz_builtin orelse return error.InvalidLexicalInitializationBuiltin;
                const owner = graph.getModule(known.module_index) orelse return error.InvalidLexicalInitializationBuiltin;
                if (known.export_index >= owner.export_bindings.len or
                    owner.exportBindingLocalNodeSemanticIndex(owner.export_bindings[known.export_index]) != @backingInt(helper.inner))
                    return error.InvalidLexicalInitializationBuiltin;
                const next = try builder.importedWithOwner(helper, .tdz_helper, known.owner_token, owner.export_bindings[known.export_index].exported_name, true);
                helper_local = next;
                break :created next;
            };
            const registry = @import("legacy_initialization_registry.zig");
            const private_registry = registry.usesRegistry(graph, plan.module);
            const flag_local = if (private_registry) helper_id else if (flag_locals.get(flag_target)) |existing| existing else created: {
                const next = try builder.imported(flag_target, .lexical_initialization_flag);
                try flag_locals.put(a, flag_target, next);
                break :created next;
            };
            // The throwing read belongs to this actual source import binding.
            // Preserve its diagnostic name without recovering any SID by text.
            const raw_name = semantic.symbols.items[sid].nameText(tree.source);
            const name = try @import("../../lexer/scanner.zig").Scanner.decodeIdentifierEscapesAlloc(a, raw_name);
            for (reads.items) |reference| {
                const original = tree.getNode(reference.node_index);
                const value = try tree.addNode(original);
                try editor.cloneReferenceAtSameLocation(reference.node_index, value);
                if (editor.node_scope_provenance.contains(reference.node_index)) try editor.copyNodeScopeProvenance(reference.node_index, value);
                try editor.removeReference(reference.node_index);
                const registry_key: ?registry.Key = if (private_registry) try registry.makeKey(&builder, selected.plan.module, flag_target, reference.scope_id, root) else null;
                const flag_read = try builder.reference(flag_local, reference.scope_id);
                const flag = if (private_registry) registry_read: {
                    const span = try tree.addString("0");
                    const zero = try tree.addNode(.{ .tag = .numeric_literal, .span = span, .data = .{ .none = 0 } });
                    break :registry_read try registry.operation(&builder, flag_read, registry_key.?.node, zero, false);
                } else flag_read;
                const helper_read = try builder.reference(helper_id, reference.scope_id);
                const literal = try stringLiteral(a, tree, name);
                const failure = try builder.call(helper_read, &.{literal});
                const true_span = try tree.addString("true");
                const ready = try tree.addNode(.{ .tag = .boolean_literal, .span = true_span, .data = .{ .none = 1 } });
                const check = try tree.addNode(.{ .tag = .binary_expression, .span = original.span, .data = .{ .binary = .{ .left = flag, .right = ready, .flags = @backingInt(@import("../../lexer/token.zig").Kind.eq3) } } });
                if (shorthand.get(reference.node_index)) |property_node| {
                    const key = if (@import("../../lexer/scanner.zig").Scanner.identifierValueEquals(tree.identifierNameText(original), "__proto__")) computed: {
                        const text = try stringLiteral(a, tree, "__proto__");
                        break :computed try tree.addNode(.{ .tag = .computed_property_key, .span = original.span, .data = .{ .unary = .{ .operand = text, .flags = 0 } } });
                    } else try tree.addNode(original);
                    var property = tree.getNode(property_node);
                    property.data.binary.left = key;
                    property.data.binary.right = reference.node_index;
                    tree.nodes.items[@backingInt(property_node)] = property;
                }
                tree.nodes.items[@backingInt(reference.node_index)] = .{ .tag = .conditional_expression, .span = original.span, .data = .{ .ternary = .{ .a = check, .b = value, .c = failure } } };
                try receipts.append(a, .{ .plan = plan, .export_index = @intCast(export_index), .guard = reference.node_index, .value = value, .flag = flag, .helper = helper_read, .failure = failure, .source_local = @fromBackingInt(sid), .flag_local = flag_local, .helper_local = helper_id, .scope = reference.scope_id, .registry_key = registry_key, .registry_helper = if (private_registry) flag_read else .none });
            }
        }
        if (receipts.items.len == 0) continue;
        var statements: std.ArrayList(NodeIndex) = .empty;
        try @import("legacy_module_identity.zig").appendPrefix(&builder, root, &statements);
        try statements.appendSlice(a, builder.declarations.items);
        const next_root = try tree.addNode(.{ .tag = .program, .span = tree.getNode(root).span, .data = .{ .list = try tree.addNodeList(statements.items) } });
        try editor.remapScopeOwner(root, next_root);
        try @import("../strict_function_context.zig").remapProgram(&semantic.strict_output_context, root, next_root);
        tree.transformed_root = next_root;
        try builder.validate();
        semantic.applyEdit(try editor.finish());
        if (module.transform_cache) |*cache| cache.symbol_ids = semantic.symbol_ids;
        module.legacy_lexical_reads = receipts.items;
        try validate(graph, module);
        changed_any = true;
    }
    return changed_any;
}

fn stringLiteral(a: std.mem.Allocator, tree: *Ast.Ast, value: []const u8) !NodeIndex {
    var quoted: std.ArrayList(u8) = .empty;
    try @import("../linker/preamble_writer.zig").appendJsStringLiteral(a, &quoted, value);
    const span = try tree.addString(quoted.items);
    return tree.addNode(.{ .tag = .string_literal, .span = span, .data = .{ .string_ref = span } });
}

fn validateInitializerImport(graph: anytype, module: *const @import("../module.zig").Module, local: SymbolId, expected: SymbolID, role: @import("../binding_scanner.zig").CallsiteRole) !void {
    var matches: usize = 0;
    for (module.import_bindings) |binding| {
        const target = binding.callsite_target orelse continue;
        const identity = module.checkedImportBindingIdentity(binding) catch return error.InvalidLexicalInitializationRead;
        if (identity.symbol.semanticIndex() != @as(?u32, @backingInt(local))) continue;
        const owner = graph.getModule(expected.module) orelse return error.InvalidLexicalInitializationRead;
        if (identity.symbol.moduleIndex() != module.index or target.role != role or !target.symbol.eql(expected) or
            owner.semantic == null or target.owner == .unassigned or target.owner != owner.semantic.?.owner_token)
            return error.InvalidLexicalInitializationRead;
        try @import("../runtime_callsite_targets.zig").validateTargetRole(graph, target);
        matches += 1;
    }
    if (matches != 1) return error.InvalidLexicalInitializationRead;
}

pub fn validate(graph: anytype, module: *const @import("../module.zig").Module) !void {
    const tree = if (module.ast) |*value| value else return error.InvalidLexicalInitializationRead;
    const semantic = module.semantic orelse return error.InvalidLexicalInitializationRead;
    const a = module.parse_arena.?.allocator();
    var rows: std.AutoHashMapUnmanaged(NodeIndex, Reference) = .empty;
    for (semantic.references) |reference| {
        if (reference.node_index.isNone() or reference.flags.declare) continue;
        const row = try rows.getOrPut(a, reference.node_index);
        if (row.found_existing) return error.InvalidLexicalInitializationRead;
        row.value_ptr.* = reference;
    }
    for (module.legacy_lexical_reads) |receipt| {
        const provider = graph.getModule(receipt.plan.index) orelse return error.InvalidLexicalInitializationRead;
        if (receipt.export_index >= provider.export_bindings.len) return error.InvalidLexicalInitializationRead;
        try receipt.plan.validate(provider, provider.export_bindings[receipt.export_index]);
        if (receipt.guarded_projection) |projection| {
            if (projection.expression.isNone() or @backingInt(projection.expression) >= tree.nodes.items.len)
                return error.InvalidLexicalInitializationRead;
            if (projection.guard_local) |local| {
                const target = try @import("../runtime_entry_guard_ast.zig").exactBinding(graph);
                try validateInitializerImport(graph, module, local, target, .entry_guard);
            }
            if (projection.source_value.isNone() or @backingInt(projection.source_value) >= tree.nodes.items.len or
                @backingInt(projection.source_value) >= semantic.symbol_ids.len or projection.source_value == receipt.value or
                semantic.symbol_ids[@backingInt(projection.source_value)] != null or rows.contains(projection.source_value))
                return error.InvalidLexicalInitializationRead;
            const source_value = tree.getNode(projection.source_value);
            const leaf = tree.getNode(receipt.value);
            if (source_value.tag != .identifier_reference or leaf.tag != .identifier_reference or
                source_value.data.string_ref.start != leaf.data.string_ref.start or source_value.data.string_ref.end != leaf.data.string_ref.end)
                return error.InvalidLexicalInitializationRead;
            const sequence = tree.getNode(projection.expression);
            if (sequence.tag != .sequence_expression or projection.expression == receipt.guard or
                projection.initializers.len == 0 or projection.initializers.len > 2 or
                sequence.data.list.len != projection.initializers.len + 1 or
                tree.readExtraNode(sequence.data.list.start, sequence.data.list.len - 1) != receipt.guard)
                return error.InvalidLexicalInitializationRead;
            for (projection.initializers, 0..) |initialization, index| {
                if (tree.readExtraNode(sequence.data.list.start, @intCast(index)) != initialization.call)
                    return error.InvalidLexicalInitializationRead;
                if (initialization.call.isNone() or @backingInt(initialization.call) >= tree.nodes.items.len)
                    return error.InvalidLexicalInitializationRead;
                const call_node = tree.getNode(initialization.call);
                if (call_node.tag != .call_expression or call_node.data.extra + 3 >= tree.extra_data.items.len) return error.InvalidLexicalInitializationRead;
                const callee = tree.readExtraNode(call_node.data.extra, 0);
                const args_start = tree.readExtra(call_node.data.extra, 1);
                const args_len = tree.readExtra(call_node.data.extra, 2);
                const local = projection.guard_local orelse initialization.local;
                const callee_ref = rows.get(callee) orelse return error.InvalidLexicalInitializationRead;
                if (callee_ref.symbol_id != local or callee_ref.scope_id != receipt.scope or
                    !callee_ref.flags.read or callee_ref.flags.write or callee_ref.flags.declare)
                    return error.InvalidLexicalInitializationRead;
                if (projection.guard_local != null) {
                    if (args_len != 1) return error.InvalidLexicalInitializationRead;
                    const argument = tree.readExtraNode(args_start, 0);
                    const argument_ref = rows.get(argument) orelse return error.InvalidLexicalInitializationRead;
                    if (argument_ref.symbol_id != initialization.local or argument_ref.scope_id != receipt.scope or
                        !argument_ref.flags.read or argument_ref.flags.write or argument_ref.flags.declare)
                        return error.InvalidLexicalInitializationRead;
                } else if (args_len != 0) return error.InvalidLexicalInitializationRead;
                try validateInitializerImport(graph, module, initialization.local, initialization.target, .esm_init);
            }
        }
        const guard = tree.getNode(receipt.guard);
        if (guard.tag != .conditional_expression or guard.data.ternary.b != receipt.value or guard.data.ternary.c != receipt.failure)
            return error.InvalidLexicalInitializationRead;
        const check = tree.getNode(guard.data.ternary.a);
        if (check.tag != .binary_expression or check.data.binary.left != receipt.flag or
            check.data.binary.flags != @backingInt(@import("../../lexer/token.zig").Kind.eq3)) return error.InvalidLexicalInitializationRead;
        const ready = tree.getNode(check.data.binary.right);
        if (ready.tag != .boolean_literal or ready.data.none != 1) return error.InvalidLexicalInitializationRead;
        const call = tree.getNode(receipt.failure);
        if (call.tag != .call_expression or tree.readExtraNode(call.data.extra, 0) != receipt.helper) return error.InvalidLexicalInitializationRead;
        const registry_read = receipt.registry_key != null;
        if (registry_read) {
            if (!@import("legacy_initialization_registry.zig").usesRegistry(graph, provider) or receipt.registry_helper.isNone() or receipt.flag_local != receipt.helper_local) return error.InvalidLexicalInitializationRead;
            const registry = @import("legacy_initialization_registry.zig");
            try registry.validateKey(a, tree, receipt.registry_key.?, module, provider, SymbolID.fromRef(receipt.plan.initialized) orelse return error.InvalidLexicalInitializationRead);
            try registry.validateOperation(tree, receipt.flag, receipt.registry_helper, receipt.registry_key.?.node, null, false);
        } else if (!receipt.registry_helper.isNone()) return error.InvalidLexicalInitializationRead;
        const nodes = [_]NodeIndex{ receipt.value, if (registry_read) receipt.registry_helper else receipt.flag, receipt.helper };
        const symbols = [_]SymbolId{ receipt.source_local, receipt.flag_local, receipt.helper_local };
        for (nodes, symbols) |node, symbol| {
            if (node.isNone() or @backingInt(node) >= tree.nodes.items.len or @backingInt(node) >= semantic.symbol_ids.len or
                tree.getNode(node).tag != .identifier_reference or semantic.symbol_ids[@backingInt(node)] != @backingInt(symbol))
                return error.InvalidLexicalInitializationRead;
            const reference = rows.get(node) orelse return error.InvalidLexicalInitializationRead;
            if (!reference.flags.read or reference.flags.write or reference.flags.declare or reference.scope_id != receipt.scope or reference.symbol_id != symbol)
                return error.InvalidLexicalInitializationRead;
        }
    }
}
