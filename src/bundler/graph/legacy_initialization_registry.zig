//! Private, helper-owned initialization state across emitted module boundaries.
//! Source modules keep their public ESM namespace shape and their own flag SID.
const std = @import("std");
const ast = @import("../../parser/ast.zig");
const NodeIndex = ast.NodeIndex;
const SymbolId = @import("../../semantic/symbol.zig").SymbolId;
const ScopeId = @import("../../semantic/scope.zig").ScopeId;
const SymbolID = @import("../symbol.zig").SymbolID;
const Builder = @import("../runtime_callsite_builder.zig").Builder;
const Graph = @import("../graph.zig").ModuleGraph;
const Module = @import("../module.zig").Module;
const Token = @import("../../lexer/token.zig").Kind;

pub const Receipt = struct {
    assignment: NodeIndex,
    original: NodeIndex,
    target: NodeIndex,
    flag: SymbolId,
    helper: NodeIndex,
    helper_local: SymbolId,
    scope: ScopeId,
    key: Key,
    module: *const Module,
    owner: @import("../codegen_output_domain.zig").Owner,
    index: @import("../types.zig").ModuleIndex,
};

pub const Factory = struct { identity: SymbolID, local: SymbolId, scope: ScopeId, owner: @import("../module.zig").SemanticOwnerToken };
pub const Key = struct { node: NodeIndex, logical: NodeIndex, path: NodeIndex, url: NodeIndex, mode: NodeIndex, factory: ?Factory = null };

pub fn usesRegistry(graph: anytype, provider: *const Module) bool {
    return graph.preserve_modules or (graph.code_splitting and provider.wrap_kind == .esm);
}

pub fn makeKey(builder: *Builder, provider: *const Module, identity: SymbolID, scope: ScopeId, root: NodeIndex) !Key {
    const factory_mode = !builder.graph.preserve_modules and builder.graph.code_splitting and provider.wrap_kind == .esm;
    if (!factory_mode) try @import("legacy_module_identity.zig").ensure(builder, root);
    const a = builder.allocator;
    const tree = builder.ast;
    const logical = try literal(a, tree, try @import("../lexical_initialization_plan.zig").registryKey(a, provider, identity));
    const path = try literal(a, tree, "");
    var factory: ?Factory = null;
    const url = if (factory_mode) actual_factory: {
        const target = try provider.esmInitSymbol();
        const owner = (provider.semantic orelse return error.InvalidLexicalInitializationRegistry).owner_token;
        // esm_init is an output-owned, scope-less binding. Even its defining
        // Source module reads it through a real typed import-local bridge;
        // that self bridge introduces no Source dependency or export.
        const local = try builder.importedWithOwner(target, .esm_init, owner, "__exact_target", provider != builder.module);
        factory = .{ .identity = target, .local = local, .scope = scope, .owner = owner };
        break :actual_factory try builder.reference(local, scope);
    } else (try @import("legacy_module_identity.zig").capture(builder, scope)).node;
    const mode = try literal(a, tree, if (factory_mode) "factory" else "");
    const node = try tree.addNode(.{ .tag = .array_expression, .span = .EMPTY, .data = .{ .list = try tree.addNodeList(&.{ logical, path, url, mode }) } });
    return .{ .node = node, .logical = logical, .path = path, .url = url, .mode = mode, .factory = factory };
}

pub fn literal(a: std.mem.Allocator, tree: *ast.Ast, text: []const u8) !NodeIndex {
    var quoted: std.ArrayList(u8) = .empty;
    try @import("../linker/preamble_writer.zig").appendJsStringLiteral(a, &quoted, text);
    const span = try tree.addString(quoted.items);
    return tree.addNode(.{ .tag = .string_literal, .span = span, .data = .{ .string_ref = span } });
}

pub fn operation(builder: *Builder, helper: NodeIndex, key: NodeIndex, value: NodeIndex, write: bool) !NodeIndex {
    const zero_span = try builder.ast.addString("0");
    const zero = try builder.ast.addNode(.{ .tag = .numeric_literal, .span = zero_span, .data = .{ .none = 0 } });
    const op_span = try builder.ast.addString(if (write) "1" else "0");
    const op = try builder.ast.addNode(.{ .tag = .numeric_literal, .span = op_span, .data = .{ .none = 0 } });
    return builder.call(helper, &.{ key, value, zero, zero, op });
}

pub fn lower(graph: *Graph) !bool {
    if ((!graph.preserve_modules and !graph.code_splitting) or graph.lexical_tdz_builtin == null) return false;
    const known = graph.lexical_tdz_builtin.?;
    const helper = try @import("../lexical_initialization_builtin.zig").exact(graph);
    const provider = graph.getModule(known.module_index) orelse return error.InvalidLexicalInitializationRegistry;
    const exported = provider.export_bindings[known.export_index];
    var changed = false;
    for (0..graph.moduleCount()) |index| {
        const module = graph.moduleAtMut(@import("../types.zig").ModuleIndex.fromUsize(index)) orelse continue;
        if (module.legacy_lexical_writes.len != 0) {
            try validate(graph, module);
            continue;
        }
        if (!usesRegistry(graph, module)) continue;
        const tree = if (module.ast) |*value| value else continue;
        const semantic = if (module.semantic) |*value| value else continue;
        const a = module.parse_arena.?.allocator();
        var flags: std.AutoHashMapUnmanaged(SymbolId, void) = .empty;
        for (module.export_bindings) |binding| {
            const plan = (try @import("../lexical_initialization_plan.zig").ReadPlan.fromExport(module, binding)) orelse continue;
            const flag = SymbolID.fromRef(plan.initialized) orelse return error.InvalidLexicalInitializationRegistry;
            try flags.put(a, flag.inner, {});
        }
        if (flags.count() == 0) continue;
        const reachable = try @import("../../parser/ast_walk.zig").collectReachableNodeIndices(a, tree);
        const Pending = struct { node: NodeIndex, target: NodeIndex, flag: SymbolId, scope: ScopeId };
        var pending: std.ArrayList(Pending) = .empty;
        var writes: std.AutoHashMapUnmanaged(NodeIndex, @import("../../semantic/symbol.zig").Reference) = .empty;
        for (semantic.references) |reference| {
            if (reference.symbol_id.isNone() or !flags.contains(reference.symbol_id) or !reference.flags.write or reference.flags.declare) continue;
            const slot = try writes.getOrPut(a, reference.node_index);
            if (slot.found_existing or reference.flags.read) return error.InvalidLexicalInitializationRegistry;
            slot.value_ptr.* = reference;
        }
        for (reachable) |raw| {
            const node: NodeIndex = @fromBackingInt(raw);
            const data = tree.getNode(node);
            if (data.tag != .assignment_expression or (data.data.binary.flags != 0 and data.data.binary.flags != @backingInt(Token.eq))) continue;
            const target = data.data.binary.left;
            const reference = writes.get(target) orelse continue;
            if (target.isNone() or @backingInt(target) >= semantic.symbol_ids.len or semantic.symbol_ids[@backingInt(target)] != @backingInt(reference.symbol_id)) return error.InvalidLexicalInitializationRegistry;
            try pending.append(a, .{ .node = node, .target = target, .flag = reference.symbol_id, .scope = reference.scope_id });
        }
        if (pending.items.len == 0) continue;
        const root = tree.transformed_root orelse @as(NodeIndex, @fromBackingInt(@as(u32, @intCast(tree.nodes.items.len - 1))));
        var editor = try semantic.beginEdit(a, tree);
        defer editor.deinit();
        var builder: Builder = .{ .allocator = a, .ast = tree, .editor = &editor, .module = module, .graph = graph };
        const local = try builder.importedWithOwner(helper, .tdz_helper, known.owner_token, exported.exported_name, true);
        var receipts: std.ArrayList(Receipt) = .empty;
        for (pending.items) |write| {
            const original = try tree.addNode(tree.getNode(write.node));
            if (editor.node_scope_provenance.contains(write.node)) try editor.copyNodeScopeProvenance(write.node, original);
            const identity = SymbolID.make(module.index, @backingInt(write.flag));
            const key = try makeKey(&builder, module, identity, write.scope, root);
            const helper_read = try builder.reference(local, write.scope);
            const call = try operation(&builder, helper_read, key.node, original, true);
            tree.nodes.items[@backingInt(write.node)] = tree.getNode(call);
            try receipts.append(a, .{ .assignment = write.node, .original = original, .target = write.target, .flag = write.flag, .helper = helper_read, .helper_local = local, .scope = write.scope, .key = key, .module = module, .owner = module.codegen_output_owner, .index = module.index });
        }
        var statements: std.ArrayList(NodeIndex) = .empty;
        try @import("legacy_module_identity.zig").appendPrefix(&builder, root, &statements);
        try statements.appendSlice(a, builder.declarations.items);
        const next = try tree.addNode(.{ .tag = .program, .span = tree.getNode(root).span, .data = .{ .list = try tree.addNodeList(statements.items) } });
        try editor.remapScopeOwner(root, next);
        try @import("../strict_function_context.zig").remapProgram(&semantic.strict_output_context, root, next);
        tree.transformed_root = next;
        try builder.validate();
        semantic.applyEdit(try editor.finish());
        if (module.transform_cache) |*cache| cache.symbol_ids = semantic.symbol_ids;
        module.legacy_lexical_writes = receipts.items;
        try validate(graph, module);
        changed = true;
    }
    return changed;
}

pub fn validateOperation(tree: *const ast.Ast, call_index: NodeIndex, helper: NodeIndex, key: NodeIndex, value: ?NodeIndex, write: bool) !void {
    if (call_index.isNone() or @backingInt(call_index) >= tree.nodes.items.len) return error.InvalidLexicalInitializationRegistry;
    const call = tree.getNode(call_index);
    if (call.tag != .call_expression or !tree.hasExtra(call.data.extra, 3) or tree.readExtraNode(call.data.extra, 0) != helper or tree.readExtra(call.data.extra, 2) != 5) return error.InvalidLexicalInitializationRegistry;
    const start = tree.readExtra(call.data.extra, 1);
    if (start > tree.extra_data.items.len or tree.extra_data.items.len - start < 5 or tree.extra_data.items[start] != @backingInt(key)) return error.InvalidLexicalInitializationRegistry;
    if (value) |expected| if (tree.extra_data.items[start + 1] != @backingInt(expected)) return error.InvalidLexicalInitializationRegistry;
    if (!write) {
        const read_value: NodeIndex = @fromBackingInt(tree.extra_data.items[start + 1]);
        if (@backingInt(read_value) >= tree.nodes.items.len or tree.getNode(read_value).tag != .numeric_literal or !std.mem.eql(u8, tree.getText(tree.getNode(read_value).span), "0")) return error.InvalidLexicalInitializationRegistry;
    }
    for ([_]usize{ 2, 3, 4 }) |offset| {
        const node_index: NodeIndex = @fromBackingInt(tree.extra_data.items[start + offset]);
        if (@backingInt(node_index) >= tree.nodes.items.len) return error.InvalidLexicalInitializationRegistry;
        const number = tree.getNode(node_index);
        if (number.tag != .numeric_literal or !std.mem.eql(u8, tree.getText(number.span), if (offset == 4 and write) "1" else "0")) return error.InvalidLexicalInitializationRegistry;
    }
}

pub fn validateKey(a: std.mem.Allocator, tree: *const ast.Ast, key: Key, consumer: *const Module, provider: *const Module, identity: SymbolID) !void {
    for ([_]NodeIndex{ key.node, key.logical, key.path, key.url, key.mode }) |node| if (node.isNone() or @backingInt(node) >= tree.nodes.items.len) return error.InvalidLexicalInitializationRegistry;
    const array = tree.getNode(key.node);
    if (array.tag != .array_expression or array.data.list.len != 4 or array.data.list.start > tree.extra_data.items.len or tree.extra_data.items.len - array.data.list.start < 4 or
        !std.mem.eql(u32, tree.extra_data.items[array.data.list.start..][0..4], &.{ @backingInt(key.logical), @backingInt(key.path), @backingInt(key.url), @backingInt(key.mode) })) return error.InvalidLexicalInitializationRegistry;
    const path = tree.getNode(key.path);
    if (path.tag != .string_literal or !std.mem.eql(u8, tree.getText(path.data.string_ref), "\"\"")) return error.InvalidLexicalInitializationRegistry;
    const mode = tree.getNode(key.mode);
    if (mode.tag != .string_literal or !std.mem.eql(u8, tree.getText(mode.span), if (key.factory != null) "\"factory\"" else "\"\"")) return error.InvalidLexicalInitializationRegistry;
    if (key.factory) |factory| {
        const target = try provider.esmInitSymbol();
        const semantic = consumer.semantic orelse return error.InvalidLexicalInitializationRegistry;
        const owner = provider.semantic orelse return error.InvalidLexicalInitializationRegistry;
        if (!target.eql(factory.identity) or factory.owner == .unassigned or factory.owner != owner.owner_token or
            tree.getNode(key.url).tag != .identifier_reference or @backingInt(key.url) >= semantic.symbol_ids.len or
            semantic.symbol_ids[@backingInt(key.url)] != @backingInt(factory.local)) return error.InvalidLexicalInitializationRegistry;
        var references: usize = 0;
        for (semantic.references) |reference| if (reference.node_index == key.url) {
            if (reference.symbol_id != factory.local or reference.scope_id != factory.scope or !reference.flags.read or reference.flags.write or reference.flags.declare)
                return error.InvalidLexicalInitializationRegistry;
            references += 1;
        };
        if (references != 1) return error.InvalidLexicalInitializationRegistry;
        var imports: usize = 0;
        for (consumer.import_bindings) |binding| {
            const callsite = binding.callsite_target orelse continue;
            const local = consumer.checkedImportBindingIdentity(binding) catch return error.InvalidLexicalInitializationRegistry;
            if (local.symbol.semanticIndex() != @as(?u32, @backingInt(factory.local))) continue;
            if (local.symbol.moduleIndex() != consumer.index or callsite.role != .esm_init or
                !callsite.symbol.eql(target) or callsite.owner != owner.owner_token or binding.local_role != .import_binding)
                return error.InvalidLexicalInitializationRegistry;
            imports += 1;
        }
        if (imports != 1) return error.InvalidLexicalInitializationRegistry;
    } else {
        try @import("legacy_module_identity.zig").validate(consumer);
        var actual_capture = false;
        for (consumer.legacy_module_identity.?.captures.items) |capture| if (capture.node == key.url) {
            actual_capture = true;
        };
        if (!actual_capture) return error.InvalidLexicalInitializationRegistry;
    }
    if (tree.getNode(key.logical).tag != .string_literal) return error.InvalidLexicalInitializationRegistry;
    const text = try @import("../lexical_initialization_plan.zig").registryKey(a, provider, identity);
    var quoted: std.ArrayList(u8) = .empty;
    try @import("../linker/preamble_writer.zig").appendJsStringLiteral(a, &quoted, text);
    if (!std.mem.eql(u8, tree.getText(tree.getNode(key.logical).data.string_ref), quoted.items)) return error.InvalidLexicalInitializationRegistry;
}

pub fn validate(graph: anytype, module: *const Module) !void {
    const tree = if (module.ast) |*value| value else return error.InvalidLexicalInitializationRegistry;
    const sem = module.semantic orelse return error.InvalidLexicalInitializationRegistry;
    if (graph.getModule(module.index) != module) return error.InvalidLexicalInitializationRegistry;
    for (module.legacy_lexical_writes) |receipt| {
        if (receipt.module != module or receipt.owner == .unassigned or receipt.owner != module.codegen_output_owner or receipt.index != module.index) return error.InvalidLexicalInitializationRegistry;
        if (receipt.flag.isNone() or @backingInt(receipt.flag) >= sem.symbols.items.len or receipt.original.isNone() or @backingInt(receipt.original) >= tree.nodes.items.len) return error.InvalidLexicalInitializationRegistry;
        const flag = sem.symbols.items[@backingInt(receipt.flag)];
        const source = flag.synthetic_owner_id orelse return error.InvalidLexicalInitializationRegistry;
        if (flag.synthetic_kind != .lexical_initialization_flag or !@import("../../semantic/lexical_initialization.zig").validatePair(sem.symbols.items, sem.scopes, @backingInt(source)) or sem.symbols.items[@backingInt(source)].lexical_initialization.flag != receipt.flag) return error.InvalidLexicalInitializationRegistry;
        const original = tree.getNode(receipt.original);
        if (original.tag != .assignment_expression or (original.data.binary.flags != 0 and original.data.binary.flags != @backingInt(Token.eq)) or original.data.binary.left != receipt.target or @backingInt(receipt.target) >= sem.symbol_ids.len or sem.symbol_ids[@backingInt(receipt.target)] != @backingInt(receipt.flag)) return error.InvalidLexicalInitializationRegistry;
        var target_count: usize = 0;
        var helper_count: usize = 0;
        for (sem.references) |reference| {
            if (reference.node_index == receipt.target) {
                if (reference.symbol_id != receipt.flag or reference.scope_id != receipt.scope or !reference.flags.write or reference.flags.read or reference.flags.declare) return error.InvalidLexicalInitializationRegistry;
                target_count += 1;
            }
            if (reference.node_index == receipt.helper) {
                if (reference.symbol_id != receipt.helper_local or reference.scope_id != receipt.scope or !reference.flags.read or reference.flags.write or reference.flags.declare) return error.InvalidLexicalInitializationRegistry;
                helper_count += 1;
            }
        }
        if (target_count != 1 or helper_count != 1 or @backingInt(receipt.helper) >= sem.symbol_ids.len or sem.symbol_ids[@backingInt(receipt.helper)] != @backingInt(receipt.helper_local)) return error.InvalidLexicalInitializationRegistry;
        var helpers: usize = 0;
        for (module.import_bindings) |binding| {
            const target = binding.callsite_target orelse continue;
            if (binding.local_symbol.semanticIndex() != @as(?u32, @backingInt(receipt.helper_local))) continue;
            if (target.role != .tdz_helper) return error.InvalidLexicalInitializationRegistry;
            try @import("../runtime_callsite_targets.zig").validateTargetRole(graph, target);
            helpers += 1;
        }
        if (helpers != 1) return error.InvalidLexicalInitializationRegistry;
        try validateKey(module.parse_arena.?.allocator(), tree, receipt.key, module, module, SymbolID.make(module.index, @backingInt(receipt.flag)));
        try validateOperation(tree, receipt.assignment, receipt.helper, receipt.key.node, receipt.original, true);
    }
}

test "legacy lexical TDZ PM registry isolates real module URLs and rejects ten write receipts" {
    const Bundler = @import("../bundler.zig").Bundler;
    const helpers = @import("../test_helpers.zig");
    for ([_]bool{ false, true }) |minify| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try helpers.writeFile(tmp.dir, "package.json", "{\"type\":\"module\"}");
        try helpers.writeFile(tmp.dir, "entry-a.mjs", "import{early,read}from'./reader-a.mjs';export let value=42;console.log(JSON.stringify(['a',early,read()]));");
        try helpers.writeFile(tmp.dir, "reader-a.mjs", "import{value}from'./entry-a.mjs';export const early=42;export function read(){return value}");
        try helpers.writeFile(tmp.dir, "entry-b.mjs", "import{early,read}from'./reader-b.mjs';export let value=42;console.log(JSON.stringify(['b',early,read()]));");
        try helpers.writeFile(tmp.dir, "reader-b.mjs", "import{value}from'./entry-b.mjs';export const early=(()=>{try{return value}catch(e){return e.name}})();export function read(){return value}");
        try helpers.writeFile(tmp.dir, "native-driver.mjs", "await import('./entry-a.mjs');await import('./entry-b.mjs');");
        const native_path = try helpers.absPath(&tmp, "native-driver.mjs");
        defer std.testing.allocator.free(native_path);
        const native = try std.process.run(std.testing.allocator, std.testing.io, .{ .argv = &.{ "node", native_path } });
        defer std.testing.allocator.free(native.stdout);
        defer std.testing.allocator.free(native.stderr);
        try std.testing.expect(native.term == .exited and native.term.exited == 0);
        try std.testing.expectEqualStrings("[\"a\",42,42]\n[\"b\",\"ReferenceError\",42]\n", native.stdout);
        for ([_][]const u8{ "entry-a.mjs", "entry-b.mjs" }) |name| {
            const entry = try helpers.absPath(&tmp, name);
            defer std.testing.allocator.free(entry);
            const options: @import("../bundler.zig").BundleOptions = .{ .entry_points = &.{entry}, .platform = .node, .format = .esm, .preserve_modules = true, .unsupported = @import("../../transformer/compat.zig").fromESTarget(.es5), .minify_identifiers = minify, .minify_syntax = minify, .minify_whitespace = minify };
            var cache = Bundler.initResolveCacheFromOptions(std.testing.allocator, options);
            defer cache.deinit();
            var graph = Graph.init(std.testing.allocator, &cache);
            defer graph.deinit();
            var bundler = Bundler.initWithGraph(std.testing.allocator, options, &cache, &graph);
            defer bundler.deinit();
            const output = try bundler.bundle(std.testing.io);
            defer output.deinit(std.testing.allocator);
            try std.testing.expect(!output.hasErrors());
            for (output.outputs orelse return error.TestUnexpectedResult) |file| try helpers.writeFile(tmp.dir, std.fs.path.basename(file.path), file.contents);
            const module = graph.moduleAtMut(graph.path_to_module.get(entry).?).?;
            try std.testing.expect(module.legacy_lexical_writes.len >= 2);
            try validate(&graph, module);
            const original = module.legacy_lexical_writes;
            const altered = try module.parse_arena.?.allocator().dupe(Receipt, original);
            const foreign = graph.getModule(graph.lexical_tdz_builtin.?.module_index).?;
            for (0..10) |attack| {
                @memcpy(altered, original);
                switch (attack) {
                    0 => altered[0].module = foreign,
                    1 => altered[0].owner = .unassigned,
                    2 => altered[0].index = .none,
                    3 => altered[0].flag = .none,
                    4 => altered[0].assignment = original[0].target,
                    5 => altered[0].original = original[0].helper,
                    6 => altered[0].target = original[0].helper,
                    7 => altered[0].helper_local = original[0].flag,
                    8 => altered[0].scope = .none,
                    9 => altered[0].key.node = .none,
                    else => unreachable,
                }
                module.legacy_lexical_writes = altered;
                try std.testing.expectError(error.InvalidLexicalInitializationRegistry, validate(&graph, module));
                module.legacy_lexical_writes = original;
                try validate(&graph, module);
            }
        }
        try helpers.writeFile(tmp.dir, "driver.mjs", "await import('./entry-a.js');await import('./entry-b.js');");
        const driver = try helpers.absPath(&tmp, "driver.mjs");
        defer std.testing.allocator.free(driver);
        const observed = try std.process.run(std.testing.allocator, std.testing.io, .{ .argv = &.{ "node", driver } });
        defer std.testing.allocator.free(observed.stdout);
        defer std.testing.allocator.free(observed.stderr);
        if (observed.term != .exited or observed.term.exited != 0 or !std.mem.eql(u8, observed.stdout, native.stdout))
            std.debug.print("registry module identity minify={} native={s} actual={s} stderr={s}\n", .{ minify, native.stdout, observed.stdout, observed.stderr });
        try std.testing.expect(observed.term == .exited and observed.term.exited == 0);
        try std.testing.expectEqualStrings(native.stdout, observed.stdout);
    }
}

test "legacy lexical TDZ registry captures URL href and invocation before source mutation" {
    const Bundler = @import("../bundler.zig").Bundler;
    const helpers = @import("../test_helpers.zig");
    for ([_]@import("../types.zig").Format{ .esm, .cjs }) |format| for ([_]bool{ false, true }) |minify| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try helpers.writeFile(tmp.dir, "package.json", if (format == .esm) "{\"type\":\"module\"}" else "{\"type\":\"commonjs\"}");
        try helpers.writeFile(tmp.dir, "entry.mjs", "import{value}from'./dep.mjs';const originalCall=Function.prototype.call;let values;Function.prototype.call=function(){throw Error('poison-call')};try{values=[value,value]}finally{Function.prototype.call=originalCall}console.log(JSON.stringify(values));");
        try helpers.writeFile(tmp.dir, "dep.mjs", "const getter=Object.getOwnPropertyDescriptor(URL.prototype,'href').get;getter.call=function(){throw Error('own-call')};Object.defineProperty(URL.prototype,'href',{get(){throw Error('poison-href')},configurable:true});export let value=42;");
        const entry = try helpers.absPath(&tmp, "entry.mjs");
        defer std.testing.allocator.free(entry);
        const native = try std.process.run(std.testing.allocator, std.testing.io, .{ .argv = &.{ "node", entry } });
        defer std.testing.allocator.free(native.stdout);
        defer std.testing.allocator.free(native.stderr);
        try std.testing.expect(native.term == .exited and native.term.exited == 0);
        try std.testing.expectEqualStrings("[42,42]\n", native.stdout);
        var bundler = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry}, .platform = .node, .format = format, .preserve_modules = true, .unsupported = @import("../../transformer/compat.zig").fromESTarget(.es5), .minify_identifiers = minify, .minify_syntax = minify, .minify_whitespace = minify });
        defer bundler.deinit();
        const output = try bundler.bundle(std.testing.io);
        defer output.deinit(std.testing.allocator);
        try std.testing.expect(!output.hasErrors());
        for (output.outputs orelse return error.TestUnexpectedResult) |file| try helpers.writeFile(tmp.dir, std.fs.path.basename(file.path), file.contents);
        const path = try helpers.absPath(&tmp, "entry.js");
        defer std.testing.allocator.free(path);
        const observed = try std.process.run(std.testing.allocator, std.testing.io, .{ .argv = &.{ "node", path } });
        defer std.testing.allocator.free(observed.stdout);
        defer std.testing.allocator.free(observed.stderr);
        if (observed.term != .exited or observed.term.exited != 0 or !std.mem.eql(u8, observed.stdout, native.stdout))
            std.debug.print("registry intrinsic capture format={s} minify={} native={s} actual={s} stderr={s}\n", .{ @tagName(format), minify, native.stdout, observed.stdout, observed.stderr });
        try std.testing.expect(observed.term == .exited and observed.term.exited == 0);
        try std.testing.expectEqualStrings(native.stdout, observed.stdout);
    };
}

test "legacy lexical TDZ registry resolves emitted module paths when global URL is absent" {
    const Bundler = @import("../bundler.zig").Bundler;
    const helpers = @import("../test_helpers.zig");
    for ([_]@import("../resolve_cache.zig").Platform{ .node, .neutral }) |platform| for ([_]bool{ false, true }) |minify| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try helpers.writeFile(tmp.dir, "package.json", "{\"type\":\"module\"}");
        try helpers.writeFile(tmp.dir, "entry.mjs", "import{value}from'./dep 한.mjs';console.log(value);");
        try helpers.writeFile(tmp.dir, "dep 한.mjs", "export let value=42;");
        try helpers.writeFile(tmp.dir, "native.mjs", "globalThis.URL=undefined;await import('./entry.mjs');");
        const entry = try helpers.absPath(&tmp, "entry.mjs");
        defer std.testing.allocator.free(entry);
        const native_path = try helpers.absPath(&tmp, "native.mjs");
        defer std.testing.allocator.free(native_path);
        const native = try std.process.run(std.testing.allocator, std.testing.io, .{ .argv = &.{ "node", native_path } });
        defer std.testing.allocator.free(native.stdout);
        defer std.testing.allocator.free(native.stderr);
        try std.testing.expect(native.term == .exited and native.term.exited == 0);
        try std.testing.expectEqualStrings("42\n", native.stdout);
        var bundler = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry}, .platform = platform, .format = .esm, .preserve_modules = true, .unsupported = @import("../../transformer/compat.zig").fromESTarget(.es5), .minify_identifiers = minify, .minify_syntax = minify, .minify_whitespace = minify });
        defer bundler.deinit();
        const output = try bundler.bundle(std.testing.io);
        defer output.deinit(std.testing.allocator);
        try std.testing.expect(!output.hasErrors());
        for (output.outputs orelse return error.TestUnexpectedResult) |file| try helpers.writeFile(tmp.dir, std.fs.path.basename(file.path), file.contents);
        try helpers.writeFile(tmp.dir, "driver.mjs", "globalThis.URL=undefined;await import('./entry.js');");
        const path = try helpers.absPath(&tmp, "driver.mjs");
        defer std.testing.allocator.free(path);
        const observed = try std.process.run(std.testing.allocator, std.testing.io, .{ .argv = &.{ "node", path } });
        defer std.testing.allocator.free(observed.stdout);
        defer std.testing.allocator.free(observed.stderr);
        if (observed.term != .exited or observed.term.exited != 0 or !std.mem.eql(u8, observed.stdout, native.stdout))
            std.debug.print("registry intrinsic capture format={s} minify={} native={s} actual={s} stderr={s}\n", .{ @tagName(platform), minify, native.stdout, observed.stdout, observed.stderr });
        try std.testing.expect(observed.term == .exited and observed.term.exited == 0);
        try std.testing.expectEqualStrings(native.stdout, observed.stdout);
    };
}

test "legacy lexical TDZ registry captures source module identity before body and hoisted meta mutation" {
    const Bundler = @import("../bundler.zig").Bundler;
    const helpers = @import("../test_helpers.zig");
    for ([_]bool{ false, true }) |early| for ([_]bool{ false, true }) |minify| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try helpers.writeFile(tmp.dir, "package.json", "{\"type\":\"module\"}");
        try helpers.writeFile(tmp.dir, "entry.mjs", "import{events,advance}from'./lib.mjs';import{read}from'./peer.mjs';const first=read();advance();console.log(JSON.stringify([events,first,read()]));");
        try helpers.writeFile(tmp.dir, "lib.mjs", if (early) "import'./early.mjs';import{read}from'./peer.mjs';export const events=[];try{read()}catch(e){events.push(e.name)}export function expose(){return import.meta}export let value=41;value++;export function advance(){value++}" else "import{read}from'./peer.mjs';export const events=[];try{read()}catch(e){events.push(e.name)}import.meta.url='file:///changed.mjs';export let value=41;value++;export function advance(){value++}");
        try helpers.writeFile(tmp.dir, "peer.mjs", "import{value}from'./lib.mjs';export function read(){return value}");
        try helpers.writeFile(tmp.dir, "early.mjs", "import{expose}from'./lib.mjs';expose().url='file:///early-changed.mjs';");
        try helpers.writeFile(tmp.dir, "native.mjs", "await import('./entry.mjs');");
        const entry = try helpers.absPath(&tmp, "entry.mjs");
        defer std.testing.allocator.free(entry);
        const native_path = try helpers.absPath(&tmp, "native.mjs");
        defer std.testing.allocator.free(native_path);
        const native = try std.process.run(std.testing.allocator, std.testing.io, .{ .argv = &.{ "node", native_path } });
        defer std.testing.allocator.free(native.stdout);
        defer std.testing.allocator.free(native.stderr);
        try std.testing.expect(native.term == .exited and native.term.exited == 0);
        try std.testing.expectEqualStrings("[[\"ReferenceError\"],42,43]\n", native.stdout);
        var bundler = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry}, .platform = .node, .format = .esm, .preserve_modules = true, .unsupported = @import("../../transformer/compat.zig").fromESTarget(.es5), .minify_identifiers = minify, .minify_syntax = minify, .minify_whitespace = minify });
        defer bundler.deinit();
        const output = try bundler.bundle(std.testing.io);
        defer output.deinit(std.testing.allocator);
        try std.testing.expect(!output.hasErrors());
        for (output.outputs orelse return error.TestUnexpectedResult) |file| try helpers.writeFile(tmp.dir, std.fs.path.basename(file.path), file.contents);
        try helpers.writeFile(tmp.dir, "driver.mjs", "await import('./entry.js');");
        const path = try helpers.absPath(&tmp, "driver.mjs");
        defer std.testing.allocator.free(path);
        const observed = try std.process.run(std.testing.allocator, std.testing.io, .{ .argv = &.{ "node", path } });
        defer std.testing.allocator.free(observed.stdout);
        defer std.testing.allocator.free(observed.stderr);
        if (observed.term != .exited or observed.term.exited != 0 or !std.mem.eql(u8, observed.stdout, native.stdout))
            std.debug.print("registry intrinsic capture format={s} minify={} native={s} actual={s} stderr={s}\n", .{ if (early) "early" else "body", minify, native.stdout, observed.stdout, observed.stderr });
        try std.testing.expect(observed.term == .exited and observed.term.exited == 0);
        try std.testing.expectEqualStrings(native.stdout, observed.stdout);
    };
}

pub fn collectMetaNodes(graph: anytype, module: *const Module, a: std.mem.Allocator, out: *std.AutoHashMapUnmanaged(u32, void)) !void {
    if (module.legacy_lexical_writes.len != 0) try validate(graph, module);
    if (module.legacy_lexical_reads.len != 0) try @import("legacy_lexical_reads.zig").validate(graph, module);
    if (module.legacy_module_identity) |identity| {
        try @import("legacy_module_identity.zig").validate(module);
        for (identity.captures.items) |capture| try out.put(a, @backingInt(capture.meta), {});
    }
}
