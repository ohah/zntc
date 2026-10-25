//! Ordered single-output CJS imports with actual references and storage.
const std = @import("std");
const ast_mod = @import("../parser/ast.zig");
const NodeIndex = ast_mod.NodeIndex;
const ScopeId = @import("../semantic/scope.zig").ScopeId;
const Builder = @import("runtime_callsite_builder.zig").Builder;
const SymbolID = @import("symbol.zig").SymbolID;
const scanner = @import("binding_scanner.zig");
const walk = @import("../parser/ast_walk.zig");
const parser = @import("../parser/module.zig");

const MaterializedStorage = struct { statement: NodeIndex, binding: NodeIndex };

fn materializeStorage(builder: *Builder, sid: u32, initializer: NodeIndex) !MaterializedStorage {
    if (sid >= builder.editor.symbols.items.len) return error.InvalidCallsiteBinding;
    const symbol = &builder.editor.symbols.items[sid];
    if (symbol.kind != .import_binding or symbol.scope_id.isNone() or symbol.scope_id.toIndex() != 0) return error.InvalidCallsiteBinding;
    const name = builder.module.symbolName(@fromBackingInt(sid)) orelse return error.InvalidCallsiteBinding;
    // Validate this already selected binding; never choose a replacement SID.
    if (builder.editor.scope_maps.items[0].get(name) != @as(?usize, sid)) return error.InvalidCallsiteBinding;
    const binding = try builder.ast.addNode(.{ .tag = .binding_identifier, .span = symbol.name, .data = .{ .string_ref = symbol.name } });
    try builder.editor.attachExistingBinding(binding, @fromBackingInt(sid));
    symbol.kind = .variable_var;
    symbol.decl_flags.is_import = false;
    symbol.decl_flags.block_scoped = false;
    symbol.decl_flags.is_const = false;
    symbol.decl_flags.function_scoped = true;
    const declarator = try builder.ast.addNode(.{ .tag = .variable_declarator, .span = symbol.name, .data = .{ .extra = try builder.ast.addExtras(&.{ @backingInt(binding), @backingInt(NodeIndex.none), @backingInt(initializer) }) } });
    const list = try builder.ast.addNodeList(&.{declarator});
    const statement = try builder.ast.addNode(.{ .tag = .variable_declaration, .span = .EMPTY, .data = .{ .extra = try builder.ast.addExtras(&.{ @backingInt(ast_mod.VariableDeclarationKind.@"var"), list.start, list.len }) } });
    return .{ .statement = statement, .binding = binding };
}

pub fn lower(graph: *@import("graph.zig").ModuleGraph, linker: *@import("linker.zig").Linker) !void {
    // This phase shares the existing single-output provider admission gate.
    if (graph.interop_ast_provider == null or linker.inline_requires) return;
    for (0..graph.moduleCount()) |module_index| {
        const module = graph.moduleAtMut(@import("types.zig").ModuleIndex.fromUsize(module_index)) orelse continue;
        if (!module.is_included or module.wrap_kind != .esm) continue;
        const ast = if (module.ast) |*value| value else continue;
        const sem = if (module.semantic) |*value| value else continue;
        const a = module.parse_arena.?.allocator();
        const root = ast.transformed_root orelse @as(NodeIndex, @fromBackingInt(@as(u32, @intCast(ast.nodes.items.len - 1))));
        const live = try walk.collectReachableNodeIndices(a, ast);
        var live_set: std.AutoHashMapUnmanaged(NodeIndex, void) = .empty;
        var forbidden: std.AutoHashMapUnmanaged(NodeIndex, void) = .empty;
        for (live) |raw| {
            try live_set.put(a, @fromBackingInt(raw), {});
            const node = ast.nodes.items[raw];
            // Shorthand keys and export clauses need separate producer lowering.
            if (node.tag == .object_property or node.tag == .export_specifier) {
                var children = walk.children(ast, node);
                while (children.next()) |child| try forbidden.put(a, child, {});
            }
        }
        var by_sid: std.AutoHashMapUnmanaged(u32, usize) = .empty;
        var compiler_declarations: std.AutoHashMapUnmanaged(NodeIndex, void) = .empty;
        for (module.import_bindings, 0..) |binding, index| {
            if (binding.callsite_target) |target| {
                try compiler_declarations.put(a, target.declaration, {});
                continue;
            }
            const local = scanner.resolveImportLocalSymbol(binding, .{ .module_index = module.index, .ast = ast, .symbol_ids = sem.symbol_ids, .symbols = sem.symbols.items });
            if (local.semanticIndex()) |sid| try by_sid.put(a, sid, index);
        }
        var references_by_sid: std.AutoHashMapUnmanaged(u32, std.ArrayList(@import("../semantic/symbol.zig").Reference)) = .empty;
        for (sem.references) |reference| {
            if (!reference.isValueUse() or !live_set.contains(reference.node_index)) continue;
            const entry = try references_by_sid.getOrPut(a, @backingInt(reference.symbol_id));
            if (!entry.found_existing) entry.value_ptr.* = .empty;
            try entry.value_ptr.append(a, reference);
        }
        var by_source: std.AutoHashMapUnmanaged(NodeIndex, usize) = .empty;
        for (module.import_records, 0..) |record, index| {
            if (record.source_node.isNone()) continue;
            const raw = @backingInt(record.source_node);
            if (raw >= ast.nodes.items.len or ast.nodes.items[raw].tag != .string_literal) return error.InvalidCallsiteBinding;
            const entry = try by_source.getOrPut(a, record.source_node);
            if (entry.found_existing) return error.InvalidCallsiteBinding;
            entry.value_ptr.* = index;
        }
        const Plan = struct { declaration: NodeIndex, record: usize, symbols: []const u32 };
        var plans: std.ArrayList(Plan) = .empty;
        var statements = ast.iterateExtraList(ast.getNode(root).data.list);
        while (statements.next()) |statement| {
            const node = ast.getNode(statement);
            if (node.tag != .import_declaration or compiler_declarations.contains(statement)) continue;
            const decl = parser.readImportDeclExtras(ast, node.data.extra);
            if (decl.is_type_only or decl.phase != .none or decl.attrs_len != 0) continue;
            var symbols: std.ArrayList(u32) = .empty;
            var record_index: ?usize = if (decl.specs_len == 0) by_source.get(decl.source) orelse return error.InvalidCallsiteBinding else null;
            var supported = true;
            for (0..decl.specs_len) |offset| {
                const spec = ast.getNode(ast.readExtraNode(decl.specs_start, @intCast(offset)));
                const local_node = switch (spec.tag) {
                    .import_specifier => node: {
                        if (spec.data.binary.flags & parser.SPEC_FLAG_TYPE_ONLY != 0) {
                            supported = false;
                            break;
                        }
                        break :node if (!spec.data.binary.right.isNone()) spec.data.binary.right else spec.data.binary.left;
                    },
                    .import_default_specifier, .import_namespace_specifier => ast.readExtraNode(decl.specs_start, @intCast(offset)),
                    else => {
                        supported = false;
                        break;
                    },
                };
                if (@backingInt(local_node) >= sem.symbol_ids.len) return error.InvalidCallsiteBinding;
                const sid = sem.symbol_ids[@backingInt(local_node)] orelse return error.InvalidCallsiteBinding;
                const binding_index = by_sid.get(sid) orelse return error.InvalidCallsiteBinding;
                const binding = module.import_bindings[binding_index];
                if (binding.is_helper) {
                    supported = false;
                    break;
                }
                if (record_index) |previous| {
                    if (previous != binding.import_record_index) return error.InvalidCallsiteBinding;
                } else record_index = binding.import_record_index;
                for (if (references_by_sid.get(sid)) |rows| rows.items else &.{}) |reference| {
                    if (reference.flags.write or ((!binding.importsDefault() and binding.kind != .namespace) and forbidden.contains(reference.node_index)) or ast.getNode(reference.node_index).tag != .identifier_reference) {
                        supported = false;
                        break;
                    }
                }
                if (!supported) break;
                try symbols.append(a, sid);
            }
            if (!supported) {
                continue;
            }
            const ri = record_index orelse continue;
            if (ri >= module.import_records.len) return error.InvalidCallsiteBinding;
            const record = module.import_records[ri];
            if (record.source_node != decl.source) return error.InvalidCallsiteBinding;
            if (record.callsite_lowered or record.ts_elided or record.resolved.isNone()) continue;
            const target = graph.getModule(record.resolved) orelse continue;
            if (target.wrap_kind != .cjs or !target.is_included) continue;
            // Metro packages preserve their existing non-inlined require policy.
            if (@import("linker.zig").isMetroNonInlinedRequireSpecifier(record.specifier)) continue;
            try plans.append(a, .{ .declaration = statement, .record = ri, .symbols = symbols.items });
        }
        if (plans.items.len == 0) continue;
        // Raw preambles and retained bare declarations have different placement
        // contracts. Until all user eager edges share an ordered AST producer,
        // keep mixed modules on their existing path instead of moving one
        // dependency ahead of another (notably bare B before named A).
        const Ownership = struct { bindings: usize = 0, compiler: usize = 0 };
        const ownership = try a.alloc(Ownership, module.import_records.len);
        @memset(ownership, .{});
        for (module.import_bindings) |binding| {
            if (binding.import_record_index >= ownership.len) return error.InvalidCallsiteBinding;
            const row = &ownership[binding.import_record_index];
            row.bindings += 1;
            if (binding.callsite_target != null or binding.is_helper) row.compiler += 1;
        }
        var planned_records = try std.DynamicBitSet.initEmpty(a, module.import_records.len);
        for (plans.items) |plan| planned_records.set(plan.record);
        var mixed_raw_dependencies = false;
        for (module.import_records, 0..) |record, index| {
            if (!record.kind.isEagerEvalDependency() or record.ts_elided or record.callsite_lowered or planned_records.isSet(index)) continue;
            const row = ownership[index];
            if (row.bindings > 0 and row.bindings == row.compiler) continue;
            if (!record.resolved.isNone()) {
                const target = graph.getModule(record.resolved) orelse return error.InvalidCallsiteTarget;
                if (!target.is_included) continue;
            }
            mixed_raw_dependencies = true;
            break;
        }
        if (mixed_raw_dependencies) continue;
        var editor = try sem.beginEdit(a, ast);
        defer editor.deinit();
        var builder: Builder = .{ .allocator = a, .ast = ast, .editor = &editor, .module = module, .graph = graph };
        var removed: std.ArrayList(NodeIndex) = .empty;
        var replacement_statements: std.ArrayList(NodeIndex) = .empty;
        var removed_declarations: std.AutoHashMapUnmanaged(NodeIndex, void) = .empty;
        // sem.references is the stable input snapshot; editor appends new rows.
        for (plans.items) |plan| {
            const target = graph.getModule(module.import_records[plan.record].resolved) orelse return error.InvalidCallsiteTarget;
            const require_sid = target.require_symbol orelse return error.InvalidCallsiteTarget;
            const alias = try builder.imported(SymbolID.make(target.index, @backingInt(require_sid)), .require);
            const root_scope: ScopeId = @fromBackingInt(@as(u32, 0));
            var has_storage = false;
            for (plan.symbols) |sid| {
                const binding = module.import_bindings[by_sid.get(sid).?];
                if (binding.importsDefault() or binding.kind == .namespace) has_storage = true;
            }
            if (!has_storage) {
                const init = try builder.call(try builder.reference(alias, root_scope), &.{});
                try replacement_statements.append(a, try ast.addNode(.{ .tag = .expression_statement, .span = .EMPTY, .data = .{ .unary = .{ .operand = init, .flags = 0 } } }));
            }
            for (plan.symbols) |sid| {
                const binding = module.import_bindings[by_sid.get(sid).?];
                if (binding.importsDefault() or binding.kind == .namespace) {
                    var value = try builder.call(try builder.reference(alias, root_scope), &.{});
                    if (binding.kind == .namespace or !module.canUseDirectCjsDefaultImport(target)) {
                        const provider = graph.interop_ast_provider orelse return error.InvalidCallsiteTarget;
                        const slots = try @import("runtime_interop_ast.zig").resolveBindings(graph);
                        const helper = slots[7] orelse return error.InvalidCallsiteTarget;
                        const to_esm = try builder.use(SymbolID.make(provider.module_index, @backingInt(helper.symbol_id)), root_scope, .to_esm);
                        const one_span = try ast.addString("1");
                        const one = try ast.addNode(.{ .tag = .numeric_literal, .span = one_span, .data = .{ .string_ref = one_span } });
                        value = try builder.call(to_esm, if (module.def_format.isNodeEsm()) &.{ value, one } else &.{value});
                        if (binding.importsDefault()) {
                            const property_span = try ast.addString("\"default\"");
                            const property = try ast.addNode(.{ .tag = .string_literal, .span = property_span, .data = .{ .string_ref = property_span } });
                            value = try ast.addNode(.{ .tag = .computed_member_expression, .span = .EMPTY, .data = .{ .extra = try ast.addExtras(&.{ @backingInt(value), @backingInt(property), 0 }) } });
                        }
                    }
                    const storage = try materializeStorage(&builder, sid, value);
                    const stored_binding = &module.import_bindings[by_sid.get(sid).?];
                    stored_binding.local_role = .materialized_var;
                    stored_binding.local_symbol_node = storage.binding;
                    stored_binding.local_symbol = @import("symbol.zig").SymbolRef.makeSemantic(module.index, sid);
                    try replacement_statements.append(a, storage.statement);
                    continue;
                }
                for (if (references_by_sid.get(sid)) |rows| rows.items else &.{}) |reference| {
                    const require_call = try builder.call(try builder.reference(alias, reference.scope_id), &.{});
                    const property_span = try ast.addString(try std.json.Stringify.valueAlloc(a, binding.imported_name, .{}));
                    const property = try ast.addNode(.{ .tag = .string_literal, .span = property_span, .data = .{ .string_ref = property_span } });
                    const member = try ast.addNode(.{ .tag = .computed_member_expression, .span = .EMPTY, .data = .{ .extra = try ast.addExtras(&.{ @backingInt(require_call), @backingInt(property), 0 }) } });
                    const zero_span = try ast.addString("0");
                    const zero = try ast.addNode(.{ .tag = .numeric_literal, .span = zero_span, .data = .{ .string_ref = zero_span } });
                    const sequence = try ast.addNode(.{ .tag = .sequence_expression, .span = ast.getNode(reference.node_index).span, .data = .{ .list = try ast.addNodeList(&.{ zero, member }) } });
                    try removed.append(a, reference.node_index);
                    ast.nodes.items[@backingInt(reference.node_index)] = ast.getNode(sequence);
                }
            }
            module.import_records[plan.record].callsite_lowered = true;
            try removed_declarations.put(a, plan.declaration, {});
        }
        try editor.removeReferences(removed.items);
        const initializers = replacement_statements.items;
        replacement_statements = .empty;
        var initializers_inserted = false;
        statements = ast.iterateExtraList(ast.getNode(root).data.list);
        while (statements.next()) |statement| {
            // Preserve the source directive prologue as real directives in the
            // generated wrapper, rather than demoting it to string expressions.
            if (!initializers_inserted and ast.getNode(statement).tag != .directive) {
                try replacement_statements.appendSlice(a, initializers);
                initializers_inserted = true;
            }
            if (!removed_declarations.contains(statement)) try replacement_statements.append(a, statement);
        }
        if (!initializers_inserted) try replacement_statements.appendSlice(a, initializers);
        try replacement_statements.appendSlice(a, builder.declarations.items);
        const new_root = try ast.addNode(.{ .tag = .program, .span = ast.getNode(root).span, .data = .{ .list = try ast.addNodeList(replacement_statements.items) } });
        try editor.remapScopeOwner(root, new_root);
        ast.transformed_root = new_root;
        try builder.validate();
        sem.applyEdit(try editor.finish());
        if (module.transform_cache) |*cache| cache.symbol_ids = sem.symbol_ids;
    }
}

test "static named callsites replace raw imports with exact scoped references" {
    const Bundler = @import("bundler.zig").Bundler;
    const helpers = @import("test_helpers.zig");
    const bodies = [_][]const u8{
        "export function run(){return call()}",
        "export function run(require){return call()}",
        "export function run(__import_callsite_0){return call()}",
        "export function run(){return ()=>call()}",
        "export function run(){return [call(),value]}",
        "export function run(value=call()){return value}",
        "export class Run{read(){return call()}}",
        "export function run(){return call?.()}",
        "export function run(){return typeof call}",
        "export function run(){return [call,call()]}",
    };
    for (bodies, 0..) |body, context| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try helpers.writeFile(tmp.dir, "entry.mjs", if (context == 0) "import('./consumer.mjs').then(m=>console.log(globalThis.effects,m.run()));" else "import('./consumer.mjs').then(m=>console.log(m));");
        const consumer_source = try std.fmt.allocPrint(std.testing.allocator, "import {{call,value}} from './dep.cjs';{s}", .{body});
        defer std.testing.allocator.free(consumer_source);
        try helpers.writeFile(tmp.dir, "consumer.mjs", consumer_source);
        try helpers.writeFile(tmp.dir, "dep.cjs", "globalThis.effects=(globalThis.effects||0)+1;exports.call=function(){'use strict';return this===undefined};exports.value=42;");
        const entry = try helpers.absPath(&tmp, "entry.mjs");
        defer std.testing.allocator.free(entry);
        const options: @import("bundler.zig").BundleOptions = .{ .entry_points = &.{entry}, .inline_dynamic_imports = true, .unsupported = if (context >= 5) @import("../transformer/compat.zig").fromESTarget(.es5) else .{} };
        var cache = Bundler.initResolveCacheFromOptions(std.testing.allocator, options);
        defer cache.deinit();
        var graph = @import("graph.zig").ModuleGraph.init(std.testing.allocator, &cache);
        defer graph.deinit();
        var bundler = Bundler.initWithGraph(std.testing.allocator, options, &cache, &graph);
        defer bundler.deinit();
        const result = try bundler.bundle(std.testing.io);
        defer result.deinit(std.testing.allocator);
        try std.testing.expect(!result.hasErrors());
        if (context == 0) {
            const execution = try std.process.run(std.testing.allocator, std.testing.io, .{ .argv = &.{ "node", "-e", result.output }, .stdout_limit = .limited(16384), .stderr_limit = .limited(16384) });
            defer std.testing.allocator.free(execution.stdout);
            defer std.testing.allocator.free(execution.stderr);
            try std.testing.expectEqualStrings("1 true\n", execution.stdout);
        }
        var found = false;
        var modules = graph.modulesIterator();
        while (modules.next()) |module| {
            if (!std.mem.endsWith(u8, module.path, "/consumer.mjs")) continue;
            found = true;
            const sem = module.semantic.?;
            var actual_references: usize = 0;
            var aliases: std.AutoHashMapUnmanaged(u32, void) = .empty;
            defer aliases.deinit(std.testing.allocator);
            var declarations: std.AutoHashMapUnmanaged(NodeIndex, void) = .empty;
            defer declarations.deinit(std.testing.allocator);
            for (module.import_bindings) |binding| {
                const target = binding.callsite_target orelse continue;
                if (target.role != .require) continue;
                try aliases.put(std.testing.allocator, binding.local_symbol.semanticIndex().?, {});
                try declarations.put(std.testing.allocator, target.declaration, {});
            }
            const Work = struct { node: NodeIndex, scope: ScopeId };
            var work: std.ArrayList(Work) = .empty;
            defer work.deinit(std.testing.allocator);
            try work.append(std.testing.allocator, .{ .node = module.ast.?.transformed_root.?, .scope = @fromBackingInt(@as(u32, 0)) });
            while (work.pop()) |item| {
                const ast = &module.ast.?;
                const node = ast.getNode(item.node);
                const scope: ScopeId = if (sem.scope_owner_map.get(@backingInt(item.node))) |raw_scope| @fromBackingInt(raw_scope) else item.scope;
                if (node.tag == .import_declaration and !declarations.contains(item.node)) {
                    const decl = parser.readImportDeclExtras(ast, node.data.extra);
                    try std.testing.expect(std.mem.indexOf(u8, ast.getText(ast.getNode(decl.source).span), "dep.cjs") == null);
                }
                if (node.tag == .identifier_reference and @backingInt(item.node) < sem.symbol_ids.len) {
                    if (sem.symbol_ids[@backingInt(item.node)]) |sid| {
                        if (aliases.contains(sid)) {
                            var seen = false;
                            for (sem.references) |reference| {
                                if (reference.node_index != item.node) continue;
                                seen = true;
                                try std.testing.expectEqual(scope, reference.scope_id);
                            }
                            try std.testing.expect(seen);
                        }
                    }
                }
                var children = walk.children(ast, node);
                while (children.next()) |child| {
                    if (!child.isNone()) try work.append(std.testing.allocator, .{ .node = child, .scope = scope });
                }
            }

            for (module.import_bindings) |binding| {
                if (binding.callsite_target) |target| {
                    if (target.role != .require) continue;
                    try @import("runtime_callsite_targets.zig").validateTargetRole(&graph, target);
                    const local = binding.local_symbol.semanticIndex().?;
                    for (sem.references) |reference| {
                        if (@backingInt(reference.symbol_id) != local or !reference.isValueUse()) continue;
                        actual_references += 1;
                        try std.testing.expect(!reference.scope_id.isNone());
                        try std.testing.expectEqual(@as(?u32, local), sem.symbol_ids[@backingInt(reference.node_index)]);
                    }
                } else {
                    const record = module.import_records[binding.import_record_index];
                    const target = graph.getModule(record.resolved) orelse continue;
                    if (!std.mem.endsWith(u8, target.path, "/dep.cjs")) continue;
                    try std.testing.expect(record.callsite_lowered);
                    const local = binding.local_symbol.semanticIndex() orelse continue;
                    for (sem.references) |reference| try std.testing.expect(@backingInt(reference.symbol_id) != local or !reference.isValueUse());
                }
            }
            try std.testing.expect(actual_references >= 2);
        }
        try std.testing.expect(found);
    }
}

test "static named callsites trust exact anchors across ten poisoned source states" {
    const Bundler = @import("bundler.zig").Bundler;
    const helpers = @import("test_helpers.zig");
    for (0..10) |corruption| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try helpers.writeFile(tmp.dir, "entry.mjs", "import('./consumer.mjs').then(m=>console.log(m.run()));");
        try helpers.writeFile(tmp.dir, "consumer.mjs", "import {call,value} from './dep.cjs';export function run(){return [call(),value]}");
        try helpers.writeFile(tmp.dir, "dep.cjs", "exports.call=function(){'use strict';return this===undefined};exports.value=42;");
        const entry = try helpers.absPath(&tmp, "entry.mjs");
        defer std.testing.allocator.free(entry);
        // Preserve the source AST until this test invokes the producer directly.
        const options: @import("bundler.zig").BundleOptions = .{ .entry_points = &.{entry}, .inline_dynamic_imports = true, .platform = .react_native };
        var cache = Bundler.initResolveCacheFromOptions(std.testing.allocator, options);
        defer cache.deinit();
        var graph = @import("graph.zig").ModuleGraph.init(std.testing.allocator, &cache);
        defer graph.deinit();
        var bundler = Bundler.initWithGraph(std.testing.allocator, options, &cache, &graph);
        defer bundler.deinit();
        const result = try bundler.bundle(std.testing.io);
        defer result.deinit(std.testing.allocator);
        try std.testing.expect(!result.hasErrors());
        var candidate: ?*@import("module.zig").Module = null;
        var modules = graph.modulesIterator();
        while (modules.next()) |module| {
            if (std.mem.endsWith(u8, module.path, "/consumer.mjs")) candidate = graph.moduleAtMut(module.index);
        }
        const module = candidate orelse return error.MissingStaticConsumer;
        const a = module.parse_arena.?.allocator();
        const sem = &module.semantic.?;
        var binding = &module.import_bindings[0];
        const call_sid = scanner.resolveImportLocalSymbol(binding.*, .{ .module_index = module.index, .ast = &module.ast.?, .symbol_ids = sem.symbol_ids, .symbols = sem.symbols.items }).semanticIndex().?;
        const value_sid = module.import_bindings[1].local_symbol.semanticIndex().?;
        switch (corruption) {
            0 => try @constCast(sem.scope_maps)[0].put(a, "call", value_sid),
            1 => binding.local_symbol_node = null,
            2 => binding.local_symbol_node = @fromBackingInt(@as(u32, @intCast(module.ast.?.nodes.items.len))),
            3 => @constCast(sem.symbol_ids)[@backingInt(binding.local_symbol_node.?)] = null,
            4 => binding.local_symbol = @import("symbol.zig").SymbolRef.makeSemantic(module.index, value_sid),
            5 => binding.local_name = "unrelated_decoy",
            6 => binding.import_record_index = @intCast(module.import_records.len),
            7 => {
                _ = @constCast(sem.scope_maps)[0].remove("call");
            },
            8 => binding.local_symbol = .invalid,
            9 => try @constCast(sem.scope_maps)[0].put(a, "__import_callsite_0", value_sid),
            else => unreachable,
        }
        var linker = @import("linker.zig").Linker.init(std.testing.allocator, &graph, .esm);
        defer linker.deinit();
        if (corruption == 1 or corruption == 2 or corruption == 3 or corruption == 6) {
            try std.testing.expectError(error.InvalidCallsiteBinding, lower(&graph, &linker));
        } else {
            try lower(&graph, &linker);
            try std.testing.expect(module.import_records[0].callsite_lowered);
            for (module.semantic.?.references) |reference| try std.testing.expect(@backingInt(reference.symbol_id) != call_sid or !reference.isValueUse());
        }
    }
}

test "static named callsites retain source order at mixed raw dependency boundary" {
    const Bundler = @import("bundler.zig").Bundler;
    const helpers = @import("test_helpers.zig");
    const import_b = [_][]const u8{ "import './b.cjs';", "import other from './b.cjs';", "import * as other from './b.cjs';" };
    for (import_b, 0..) |b_import, kind| for ([_]bool{ false, true }) |a_first| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try helpers.writeFile(tmp.dir, "entry.mjs", "globalThis.events=[];import('./consumer.mjs').then(m=>{const result=m.run();console.log(globalThis.events.join(','),result);});");
        const import_a = "import {value} from './a.cjs';";
        const consumer_source = try std.fmt.allocPrint(std.testing.allocator, "{s}{s}export function run(){{return value;}}", .{ if (a_first) import_a else b_import, if (a_first) b_import else import_a });
        defer std.testing.allocator.free(consumer_source);
        try helpers.writeFile(tmp.dir, "consumer.mjs", consumer_source);
        try helpers.writeFile(tmp.dir, "a.cjs", "globalThis.events.push('A');exports.value=42;");
        try helpers.writeFile(tmp.dir, "b.cjs", "globalThis.events.push('B');exports.other=43;");
        const entry = try helpers.absPath(&tmp, "entry.mjs");
        defer std.testing.allocator.free(entry);
        const options: @import("bundler.zig").BundleOptions = .{ .entry_points = &.{entry}, .inline_dynamic_imports = true, .minify_identifiers = a_first, .minify_syntax = a_first, .minify_whitespace = a_first };
        var cache = Bundler.initResolveCacheFromOptions(std.testing.allocator, options);
        defer cache.deinit();
        var graph = @import("graph.zig").ModuleGraph.init(std.testing.allocator, &cache);
        defer graph.deinit();
        var bundler = Bundler.initWithGraph(std.testing.allocator, options, &cache, &graph);
        defer bundler.deinit();
        const result = try bundler.bundle(std.testing.io);
        defer result.deinit(std.testing.allocator);
        try std.testing.expect(!result.hasErrors());
        // The previously correct bare-B then named-A case must remain correct.
        // Other raw mixed ordering/value behavior remains an explicit debt.
        if (kind == 0 and !a_first) {
            const execution = try std.process.run(std.testing.allocator, std.testing.io, .{ .argv = &.{ "node", "-e", result.output }, .stdout_limit = .limited(16384), .stderr_limit = .limited(16384) });
            defer std.testing.allocator.free(execution.stdout);
            defer std.testing.allocator.free(execution.stderr);
            try std.testing.expectEqualStrings("B,A 42\n", execution.stdout);
        }
        var modules = graph.modulesIterator();
        while (modules.next()) |module| {
            if (!std.mem.endsWith(u8, module.path, "/consumer.mjs")) continue;
            var actual_calls: usize = 0;
            for (module.import_bindings) |binding| {
                if (binding.callsite_target != null) actual_calls += 1;
            }
            try std.testing.expect(actual_calls >= 2);
        }
    };
}

test "static named callsites keep compiler binding edges out of eager initialization" {
    const Bundler = @import("bundler.zig").Bundler;
    const helpers = @import("test_helpers.zig");
    for ([_]bool{ false, true }) |esm| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try helpers.writeFile(tmp.dir, "entry.mjs", "import('./consumer.mjs').then(m=>m.run());");
        try helpers.writeFile(tmp.dir, "consumer.mjs", if (esm) "export function run(){console.log('run');return import('./dep.mjs').then(m=>console.log(m.value));}" else "export function run(){console.log('run');return import('./dep.cjs').then(m=>console.log(m.value));}");
        try helpers.writeFile(tmp.dir, "dep.cjs", "console.log('dep');exports.value=42;");
        try helpers.writeFile(tmp.dir, "dep.mjs", "console.log('dep');export const value=42;");
        const entry = try helpers.absPath(&tmp, "entry.mjs");
        defer std.testing.allocator.free(entry);
        const options: @import("bundler.zig").BundleOptions = .{ .entry_points = &.{entry}, .inline_dynamic_imports = true, .strict_execution_order = true };
        var bundler = Bundler.init(std.testing.allocator, options);
        defer bundler.deinit();
        const result = try bundler.bundle(std.testing.io);
        defer result.deinit(std.testing.allocator);
        try std.testing.expect(!result.hasErrors());
        const execution = try std.process.run(std.testing.allocator, std.testing.io, .{ .argv = &.{ "node", "-e", result.output }, .stdout_limit = .limited(16384), .stderr_limit = .limited(16384) });
        defer std.testing.allocator.free(execution.stdout);
        defer std.testing.allocator.free(execution.stderr);
        try std.testing.expectEqualStrings("run\ndep\n42\n", execution.stdout);
    }
}

test "static named callsites initialize after the source directive prologue" {
    const Bundler = @import("bundler.zig").Bundler;
    const helpers = @import("test_helpers.zig");
    for ([_][]const u8{ "\"use strict\";", "\"use custom\";\"use strict\";" }) |prologue| for ([_]bool{ false, true }) |minify| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try helpers.writeFile(tmp.dir, "entry.mjs", "import('./consumer.mjs').then(m=>console.log(JSON.stringify(m.run())));");
        const source = try std.fmt.allocPrint(std.testing.allocator, "{s}import {{value}} from './dep.cjs';let mode;try{{eval('leaked_static_directive=1');mode='sloppy'}}catch{{mode='strict'}}export function run(){{return [mode,value]}}", .{prologue});
        defer std.testing.allocator.free(source);
        try helpers.writeFile(tmp.dir, "consumer.mjs", source);
        try helpers.writeFile(tmp.dir, "dep.cjs", "exports.value=42;");
        const entry = try helpers.absPath(&tmp, "entry.mjs");
        defer std.testing.allocator.free(entry);
        const options: @import("bundler.zig").BundleOptions = .{ .entry_points = &.{entry}, .inline_dynamic_imports = true, .minify_identifiers = minify, .minify_syntax = minify, .minify_whitespace = minify };
        var cache = Bundler.initResolveCacheFromOptions(std.testing.allocator, options);
        defer cache.deinit();
        var graph = @import("graph.zig").ModuleGraph.init(std.testing.allocator, &cache);
        defer graph.deinit();
        var bundler = Bundler.initWithGraph(std.testing.allocator, options, &cache, &graph);
        defer bundler.deinit();
        const result = try bundler.bundle(std.testing.io);
        defer result.deinit(std.testing.allocator);
        try std.testing.expect(!result.hasErrors());
        const execution = try std.process.run(std.testing.allocator, std.testing.io, .{ .argv = &.{ "node", "-e", result.output }, .stdout_limit = .limited(16384), .stderr_limit = .limited(16384) });
        defer std.testing.allocator.free(execution.stdout);
        defer std.testing.allocator.free(execution.stderr);
        try std.testing.expectEqualStrings("[\"strict\",42]\n", execution.stdout);
        var modules = graph.modulesIterator();
        while (modules.next()) |module| {
            if (!std.mem.endsWith(u8, module.path, "/consumer.mjs")) continue;
            const ast = &module.ast.?;
            var statements = ast.iterateExtraList(ast.getNode(ast.transformed_root.?).data.list);
            if (std.mem.indexOf(u8, prologue, "use custom") != null) {
                const custom = ast.getNode(statements.next().?);
                try std.testing.expectEqual(ast_mod.Node.Tag.directive, custom.tag);
                try std.testing.expectEqualStrings("\"use custom\"", ast.getText(custom.span));
            }
            const strict = ast.getNode(statements.next().?);
            try std.testing.expectEqual(ast_mod.Node.Tag.directive, strict.tag);
            try std.testing.expectEqualStrings("\"use strict\"", ast.getText(strict.span));
            const initializer = ast.getNode(statements.next().?);
            try std.testing.expectEqual(ast_mod.Node.Tag.expression_statement, initializer.tag);
            try std.testing.expectEqual(ast_mod.Node.Tag.call_expression, ast.getNode(initializer.data.unary.operand).tag);
        }
    };
}
