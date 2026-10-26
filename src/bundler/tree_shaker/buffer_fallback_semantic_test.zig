const std = @import("std");
const ast_mod = @import("../../parser/ast.zig");
const NodeIndex = ast_mod.NodeIndex;
const ScopeId = @import("../../semantic/scope.zig").ScopeId;
const Module = @import("../module.zig").Module;
const patterns = @import("cjs_patterns.zig");
const prepass = @import("../graph/transform_prepass.zig");
const Symbol = @import("../../semantic/symbol.zig").Symbol;
const Reference = @import("../../semantic/symbol.zig").Reference;
const Scope = @import("../../semantic/scope.zig").Scope;
const prefix = "var buffer=require('buffer');var B=buffer.Buffer;";
const condition = "B.from&&B.alloc&&B.allocUnsafe&&B.allocUnsafeSlow";

const Fixture = struct {
    module: Module,
    function: NodeIndex,
    binding: NodeIndex,
    read: NodeIndex,
    sid: u32,
    function_scope: u32,

    fn init(a: std.mem.Allocator, input: []const u8) !Fixture {
        var scanner = try @import("../../lexer/scanner.zig").Scanner.init(a, input);
        var parser = @import("../../parser/parser.zig").Parser.init(a, &scanner);
        parser.configureFromExtension(".cjs");
        _ = try parser.parse();
        try std.testing.expectEqual(@as(usize, 0), parser.errors.items.len);
        var analyzer = @import("../../semantic/analyzer.zig").SemanticAnalyzer.init(a, &parser.ast);
        analyzer.is_module = false;
        analyzer.is_strict_mode = false;
        analyzer.enable_stmt_info = true;
        analyzer.enable_exact_declaration_anchors = true;
        try analyzer.analyze();
        const wrapper_scope: ScopeId = @fromBackingInt(@as(u32, @intCast(analyzer.scopes.items.len)));
        try analyzer.scopes.append(a, .{ .parent = @fromBackingInt(0), .kind = .function, .is_strict = false, .symbol_count = 2 });
        try analyzer.scope_maps.append(a, .empty);
        const symbol_mod = @import("../../semantic/symbol.zig");
        const exports_id = try symbol_mod.extendSymbol(a, &analyzer.symbols, .parameter, .cjs_wrapper_exports_parameter, "exports", .EMPTY);
        const module_id = try symbol_mod.extendSymbol(a, &analyzer.symbols, .parameter, .cjs_wrapper_module_parameter, "module", .EMPTY);
        for ([_]@TypeOf(exports_id){ exports_id, module_id }) |id| {
            analyzer.symbols.items[@backingInt(id)].scope_id = wrapper_scope;
            analyzer.symbols.items[@backingInt(id)].origin_scope = wrapper_scope;
        }
        // Same graph-finalization contract as the existing retained Buffer
        // regression: only unresolved host reads acquire these typed handles.
        for (parser.ast.nodes.items, 0..) |node, raw| {
            if ((node.tag != .identifier_reference and node.tag != .assignment_target_identifier) or analyzer.symbol_ids.items[raw] != null) continue;
            const text = parser.ast.getText(node.data.string_ref);
            const id = if (std.mem.eql(u8, text, "exports")) exports_id else if (std.mem.eql(u8, text, "module")) module_id else continue;
            analyzer.symbol_ids.items[raw] = @backingInt(id);
            analyzer.symbols.items[@backingInt(id)].reference_count += 1;
        }
        var module = Module.init(@fromBackingInt(0), "test.cjs");
        module.source = input;
        module.ast = parser.ast;
        module.wrap_kind = .cjs;
        module.exports_kind = .commonjs;
        module.semantic = .{ .symbols = analyzer.symbols, .scopes = analyzer.scopes.items, .scope_maps = analyzer.scope_maps.items, .scope_owner_map = analyzer.scope_owner_map, .symbol_ids = analyzer.symbol_ids.items, .exported_names = analyzer.exported_names, .unresolved_references = analyzer.unresolved_references, .references = analyzer.references.items };
        module.cjs_wrapper_exports_parameter_symbol = exports_id;
        module.cjs_wrapper_module_parameter_symbol = module_id;
        var function: NodeIndex = .none;
        var binding: NodeIndex = .none;
        for (parser.ast.nodes.items, 0..) |node, raw| {
            if (node.tag != .function_declaration) continue;
            const name = parser.ast.readExtraNode(node.data.extra, ast_mod.FunctionExtra.name);
            const sid = analyzer.symbol_ids.items[@backingInt(name)] orelse continue;
            if (analyzer.symbols.items[sid].scope_id != @as(ScopeId, @fromBackingInt(0))) continue;
            function = @fromBackingInt(@as(u32, @intCast(raw)));
            binding = name;
            break;
        }
        const sid = analyzer.symbol_ids.items[@backingInt(binding)].?;
        var read: NodeIndex = .none;
        for (analyzer.references.items) |row| {
            if (@backingInt(row.symbol_id) == sid and row.flags.read) {
                read = row.node_index;
                break;
            }
        }
        return .{ .module = module, .function = function, .binding = binding, .read = read, .sid = sid, .function_scope = analyzer.scope_owner_map.get(@backingInt(function)).? };
    }

    fn fold(self: *Fixture, a: std.mem.Allocator, removed: *std.ArrayListUnmanaged(NodeIndex)) !bool {
        var needs = false;
        const folded = try patterns.foldNodeBufferCapabilityIfsForModule(a, &self.module, &self.module.ast.?, removed, &needs);
        if (folded) try std.testing.expect(!needs);
        return folded;
    }
};

const sources = [_][]const u8{
    prefix ++ "if(" ++ condition ++ "){module.exports=buffer}else{exports.Buffer=SafeBuffer}function SafeBuffer(){return 1}",
    "function SafeBuffer(){return 1}" ++ prefix ++ "if(" ++ condition ++ "){module.exports=buffer}else{exports.Buffer=SafeBuffer}",
    prefix ++ "if(" ++ condition ++ "){module.exports=buffer}else{exports.Buffer=SafeBuffer}function SafeBuffer(size){let x=size;return x}",
    prefix ++ "if(" ++ condition ++ "){exports.Buffer=B}else{exports.Buffer=SafeBuffer}function SafeBuffer(){return 1}",
    prefix ++ "if(" ++ condition ++ "){module.exports=buffer}else exports.Buffer=SafeBuffer;function SafeBuffer(){return 1}",
    prefix ++ "if(" ++ condition ++ "){module.exports=buffer}else{exports.Buffer=SafeBuffer;exports.Other=SafeBuffer}function SafeBuffer(){return 1}",
    prefix ++ "if(" ++ condition ++ "){module.exports=buffer}else{exports.Buffer=SafeBuffer}function SafeBuffer(){return 1}SafeBuffer.value=1;",
    prefix ++ "if(" ++ condition ++ "){module.exports=buffer}else{exports.Buffer=SafeBuffer}function SafeBuffer(){return 1}console.log(SafeBuffer());",
    prefix ++ "if(" ++ condition ++ "){module.exports=buffer}else{exports.Buffer=SafeBuffer}function SafeBuffer(){return 1}function other(){const SafeBuffer=2;return SafeBuffer}",
    prefix ++ "if(" ++ condition ++ "){module.exports=buffer}else{exports.Buffer=SafeBuffer}if(" ++ condition ++ "){exports.Buffer=B}else{exports.Buffer=SafeBuffer}function SafeBuffer(){return 1}",
};

test "Buffer fallback functions retain exact declaration identity at ten actual fold callers" {
    for (sources, 0..) |input, index| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var f = try Fixture.init(a, input);
        const old_scope = f.module.semantic.?.symbols.items[f.sid].scope_id;
        const old_function_scope = f.function_scope;
        const old_count = f.module.semantic.?.symbols.items[f.sid].reference_count;
        var removed: std.ArrayListUnmanaged(NodeIndex) = .empty;
        const folded = try f.fold(a, &removed);
        if (!folded) std.debug.print("Buffer fallback case={d} failed its pre-write proof\n", .{index});
        try std.testing.expect(folded);
        const context = .{ .allocator = a, .defines = &[_]@import("../../parser/scan_results.zig").DefineEntry{}, .wrapper_symbols_registered = false, .wrap_kinds_finalized = true, .transform_options_base = .{ .minify_syntax = false } };
        try std.testing.expect(try prepass.resyncAfterNodeBufferCapabilityFoldRetainingGraph(&context, &f.module, a, removed.items));
        const sem = &f.module.semantic.?;
        try std.testing.expectEqual(@as(?u32, f.sid), sem.symbol_ids[@backingInt(f.binding)]);
        try std.testing.expectEqual(old_scope, sem.symbols.items[f.sid].scope_id);
        try std.testing.expectEqual(@as(?u32, old_function_scope), sem.scope_owner_map.get(@backingInt(f.function)));
        var removed_reads: u32 = 0;
        for (removed.items) |node| {
            if (node == f.read) removed_reads += 1;
            try std.testing.expect(node != f.binding and node != f.function);
            for (sem.references) |row| try std.testing.expect(row.node_index != node);
        }
        try std.testing.expect(removed_reads > 0);
        try std.testing.expect(sem.symbols.items[f.sid].reference_count < old_count);
        var declarations: usize = 0;
        for (sem.references) |row| if (@backingInt(row.symbol_id) == f.sid and row.flags.declare) {
            declarations += 1;
        };
        try std.testing.expectEqual(@as(usize, 1), declarations);
    }
}

const Mutation = enum { read_sid, read_row_sid, read_flags, read_type_context, read_scope, declaration_sid, declaration_flags, declaration_missing, declaration_duplicate, declaration_scope, function_scope_kind, function_scope_parent, function_owner_missing, symbol_kind, symbol_role, symbol_scope, symbol_writes, symbol_count, wrapper_missing, wrapper_role, direct_eval };

test "Buffer fallback function preflight rejects hostile tuples before any AST or graph write" {
    inline for (std.meta.tags(Mutation)) |mutation| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var f = try Fixture.init(a, sources[0]);
        const sem = &f.module.semantic.?;
        const original_symbols = try a.dupe(Symbol, sem.symbols.items);
        const original_refs = try a.dupe(Reference, sem.references);
        const original_scopes = try a.dupe(Scope, sem.scopes);
        const original_ids = try a.dupe(?u32, sem.symbol_ids);
        const original_owners = try sem.scope_owner_map.clone(a);
        const wrapper = f.module.cjs_wrapper_exports_parameter_symbol;
        const mutable_refs = @constCast(sem.references);
        var read: usize = 0;
        var declaration: usize = 0;
        for (sem.references, 0..) |row, index| {
            if (@backingInt(row.symbol_id) != f.sid) continue;
            if (row.flags.declare) declaration = index else if (row.node_index == f.read) {
                read = index;
            }
        }
        switch (mutation) {
            .read_sid => @constCast(sem.symbol_ids)[@backingInt(f.read)] = @backingInt(wrapper.?),
            .read_row_sid => mutable_refs[read].symbol_id = wrapper.?,
            .read_flags => mutable_refs[read].flags.write = true,
            .read_type_context => mutable_refs[read].flags.type_context = true,
            // The actual function is a valid sibling environment which can
            // see this global SID, but it is not this alternate read's scope.
            .read_scope => mutable_refs[read].scope_id = @fromBackingInt(f.function_scope),
            .declaration_sid => @constCast(sem.symbol_ids)[@backingInt(f.binding)] = @backingInt(wrapper.?),
            .declaration_flags => mutable_refs[declaration].flags.write = true,
            .declaration_missing => mutable_refs[declaration].flags.declare = false,
            .declaration_duplicate => {
                const rows = try a.alloc(Reference, sem.references.len + 1);
                @memcpy(rows[0..sem.references.len], sem.references);
                rows[sem.references.len] = sem.references[declaration];
                sem.references = rows;
            },
            .declaration_scope => mutable_refs[declaration].scope_id = @fromBackingInt(f.function_scope),
            .function_scope_kind => @constCast(sem.scopes)[f.function_scope].kind = .block,
            .function_scope_parent => @constCast(sem.scopes)[f.function_scope].parent = @fromBackingInt(f.function_scope),
            .function_owner_missing => {
                _ = sem.scope_owner_map.remove(@backingInt(f.function));
            },
            .symbol_kind => sem.symbols.items[f.sid].kind = .variable_var,
            .symbol_role => sem.symbols.items[f.sid].synthetic_kind = .implicit_arguments,
            .symbol_scope => sem.symbols.items[f.sid].scope_id = @fromBackingInt(f.function_scope),
            .symbol_writes => sem.symbols.items[f.sid].write_count += 1,
            .symbol_count => sem.symbols.items[f.sid].reference_count += 1,
            .wrapper_missing => f.module.cjs_wrapper_exports_parameter_symbol = null,
            .wrapper_role => sem.symbols.items[@backingInt(wrapper.?)].synthetic_kind = .cjs_wrapper_module_parameter,
            .direct_eval => @constCast(sem.scopes)[0].subtree_has_direct_eval = true,
        }
        const before_nodes = try a.dupe(ast_mod.Node, f.module.ast.?.nodes.items);
        const before_extra = try a.dupe(u32, f.module.ast.?.extra_data.items);
        const before_symbols = try a.dupe(Symbol, sem.symbols.items);
        const before_refs = try a.dupe(Reference, sem.references);
        const before_scopes = try a.dupe(Scope, sem.scopes);
        const before_ids = try a.dupe(?u32, sem.symbol_ids);
        const before_owners = try sem.scope_owner_map.clone(a);
        const before_maps = try a.alloc(std.StringHashMapUnmanaged(usize), sem.scope_maps.len);
        for (before_maps, sem.scope_maps) |*copy, map| copy.* = try map.clone(a);
        var removed: std.ArrayListUnmanaged(NodeIndex) = .empty;
        var needs = false;
        const accepted = try patterns.foldNodeBufferCapabilityIfsForModule(a, &f.module, &f.module.ast.?, &removed, &needs);
        if (accepted) std.debug.print("Buffer hostile admitted {s}\n", .{@tagName(mutation)});
        try std.testing.expect(!accepted);
        try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(before_nodes), std.mem.sliceAsBytes(f.module.ast.?.nodes.items));
        try std.testing.expectEqualSlices(u32, before_extra, f.module.ast.?.extra_data.items);
        try std.testing.expectEqualDeep(before_symbols, sem.symbols.items);
        try std.testing.expectEqualDeep(before_refs, sem.references);
        try std.testing.expectEqualDeep(before_scopes, sem.scopes);
        try std.testing.expectEqualDeep(before_ids, sem.symbol_ids);
        try std.testing.expectEqual(before_owners.count(), sem.scope_owner_map.count());
        for (before_maps, sem.scope_maps) |before, after| {
            try std.testing.expectEqual(before.count(), after.count());
            var entries = before.iterator();
            while (entries.next()) |entry| try std.testing.expectEqual(@as(?usize, entry.value_ptr.*), after.get(entry.key_ptr.*));
        }
        var owners = before_owners.iterator();
        while (owners.next()) |entry| try std.testing.expectEqual(@as(?u32, entry.value_ptr.*), sem.scope_owner_map.get(entry.key_ptr.*));
        @memcpy(sem.symbols.items, original_symbols);
        sem.references = original_refs;
        @memcpy(@constCast(sem.scopes), original_scopes);
        @memcpy(@constCast(sem.symbol_ids), original_ids);
        sem.scope_owner_map = original_owners;
        f.module.cjs_wrapper_exports_parameter_symbol = wrapper;
        removed.clearRetainingCapacity();
        try std.testing.expect(try f.fold(a, &removed));
    }
}

test "Buffer fallback function preflight rejects a foreign AST with identical numeric handles" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f = try Fixture.init(a, sources[0]);
    var foreign = try ast_mod.Ast.cloneForTransformer(&f.module.ast.?, a);
    const before = try a.dupe(ast_mod.Node, foreign.nodes.items);
    var removed: std.ArrayListUnmanaged(NodeIndex) = .empty;
    var needs = false;
    try std.testing.expect(!try patterns.foldNodeBufferCapabilityIfsForModule(a, &f.module, &foreign, &removed, &needs));
    var facts: std.ArrayListUnmanaged(patterns.FoldedNodeBufferExport) = .empty;
    const before_symbols = try a.dupe(Symbol, f.module.semantic.?.symbols.items);
    const before_references = try a.dupe(Reference, f.module.semantic.?.references);
    const before_ids = try a.dupe(?u32, f.module.semantic.?.symbol_ids);
    // Exercise the actual production API too, not only its compatibility
    // wrapper. Identical numeric nodes/SIDs cannot authorize a foreign AST.
    try std.testing.expect(!try patterns.foldNodeBufferCapabilityIfsForModuleWithExports(a, &f.module, &foreign, &removed, &needs, &facts));
    try std.testing.expectEqual(@as(usize, 0), facts.items.len);
    try std.testing.expectEqualDeep(before_symbols, f.module.semantic.?.symbols.items);
    try std.testing.expectEqualDeep(before_references, f.module.semantic.?.references);
    try std.testing.expectEqualDeep(before_ids, f.module.semantic.?.symbol_ids);
    try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(before), std.mem.sliceAsBytes(foreign.nodes.items));
    try std.testing.expect(try f.fold(a, &removed));
}

test "Buffer folded export facts preserve the actual kept assignment for named reachability" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f = try Fixture.init(a, sources[0]);
    var removed: std.ArrayListUnmanaged(NodeIndex) = .empty;
    var facts: std.ArrayListUnmanaged(patterns.FoldedNodeBufferExport) = .empty;
    var needs = false;
    try std.testing.expect(try patterns.foldNodeBufferCapabilityIfsForModuleWithExports(a, &f.module, &f.module.ast.?, &removed, &needs, &facts));
    try std.testing.expect(!needs);
    try std.testing.expectEqual(@as(usize, 1), facts.items.len);
    const fact = facts.items[0];
    const current_ast = &f.module.ast.?;
    try std.testing.expectEqual(fact.kept, current_ast.getNode(fact.statement).data.ternary.b);
    const kept_node = current_ast.getNode(fact.kept);
    try std.testing.expectEqual(@as(u32, 1), kept_node.data.list.len);
    const actual_statement: NodeIndex = @fromBackingInt(current_ast.extra_data.items[kept_node.data.list.start]);
    try std.testing.expectEqual(fact.assignment, current_ast.getNode(actual_statement).data.unary.operand);
    try std.testing.expectEqual(fact.object_reference, current_ast.getNode(fact.assignment).data.binary.right);
    try std.testing.expect(patterns.foldedNodeBufferExportIsCurrent(&f.module, current_ast, fact.statement, fact));
    var wrong = fact;
    wrong.object_symbol = f.sid;
    try std.testing.expect(!patterns.foldedNodeBufferExportIsCurrent(&f.module, current_ast, fact.statement, wrong));
    wrong = fact;
    wrong.module_symbol = f.sid;
    try std.testing.expect(!patterns.foldedNodeBufferExportIsCurrent(&f.module, current_ast, fact.statement, wrong));
    wrong = fact;
    wrong.assignment = f.function;
    try std.testing.expect(!patterns.foldedNodeBufferExportIsCurrent(&f.module, current_ast, fact.statement, wrong));
    wrong = fact;
    wrong.kept = f.function;
    try std.testing.expect(!patterns.foldedNodeBufferExportIsCurrent(&f.module, current_ast, fact.statement, wrong));
    var foreign = try ast_mod.Ast.cloneForTransformer(current_ast, a);
    try std.testing.expect(!patterns.foldedNodeBufferExportIsCurrent(&f.module, &foreign, fact.statement, fact));
    const original = current_ast.nodes.items[@backingInt(fact.statement)];
    current_ast.nodes.items[@backingInt(fact.statement)].data.ternary.c = fact.kept;
    try std.testing.expect(!patterns.foldedNodeBufferExportIsCurrent(&f.module, current_ast, fact.statement, fact));
    current_ast.nodes.items[@backingInt(fact.statement)] = original;
    try std.testing.expect(patterns.foldedNodeBufferExportIsCurrent(&f.module, current_ast, fact.statement, fact));
}

test "Buffer module fold ignores orphan pre-minify if and block copies" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f = try Fixture.init(a, sources[0]);
    const current_ast = &f.module.ast.?;
    const old_root: NodeIndex = @fromBackingInt(@as(u32, @intCast(current_ast.nodes.items.len - 1)));
    const program = current_ast.getNode(old_root);
    const program_scope = f.module.semantic.?.scope_owner_map.get(@backingInt(old_root)).?;
    var actual_if: NodeIndex = .none;
    for (current_ast.extra_data.items[program.data.list.start..][0..program.data.list.len]) |raw| {
        if (current_ast.nodes.items[raw].tag == .if_statement) {
            actual_if = @fromBackingInt(raw);
            break;
        }
    }
    const branch = current_ast.getNode(actual_if);
    const old_alternate = current_ast.getNode(branch.data.ternary.c);
    const orphan_alternate = try current_ast.addListNode(.block_statement, old_alternate.span, old_alternate.data.list);
    var orphan = branch;
    orphan.data.ternary.c = orphan_alternate;
    const orphan_if = try current_ast.addNode(orphan);
    const new_root = try current_ast.addNode(program);
    try f.module.semantic.?.scope_owner_map.put(a, @backingInt(new_root), program_scope);
    const old_ids = f.module.semantic.?.symbol_ids;
    const ids = try a.alloc(?u32, current_ast.nodes.items.len);
    @memset(ids, null);
    @memcpy(ids[0..old_ids.len], old_ids);
    f.module.semantic.?.symbol_ids = ids;
    try std.testing.expect(!f.module.semantic.?.scope_owner_map.contains(@backingInt(orphan_alternate)));
    var removed: std.ArrayListUnmanaged(NodeIndex) = .empty;
    var facts: std.ArrayListUnmanaged(patterns.FoldedNodeBufferExport) = .empty;
    var needs = false;
    try std.testing.expect(try patterns.foldNodeBufferCapabilityIfsForModuleWithExports(a, &f.module, current_ast, &removed, &needs, &facts));
    try std.testing.expect(!needs);
    try std.testing.expect(current_ast.getNode(actual_if).data.ternary.c.isNone());
    try std.testing.expectEqual(orphan_alternate, current_ast.getNode(orphan_if).data.ternary.c);
    try std.testing.expectEqual(@as(usize, 1), facts.items.len);
    try std.testing.expectEqual(actual_if, facts.items[0].statement);
    for (removed.items) |node| try std.testing.expect(node != orphan_if and node != orphan_alternate);
}

test "Buffer constructor export facts follow actual initializer object identity" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f = try Fixture.init(a, sources[3]);
    var removed: std.ArrayListUnmanaged(NodeIndex) = .empty;
    var facts: std.ArrayListUnmanaged(patterns.FoldedNodeBufferExport) = .empty;
    var needs = false;
    try std.testing.expect(try patterns.foldNodeBufferCapabilityIfsForModuleWithExports(a, &f.module, &f.module.ast.?, &removed, &needs, &facts));
    try std.testing.expectEqual(@as(usize, 1), facts.items.len);
    const fact = facts.items[0];
    try std.testing.expectEqual(.buffer_constructor, fact.kind);
    const current_ast = &f.module.ast.?;
    const sem = &f.module.semantic.?;
    try std.testing.expectEqual(@as(?u32, fact.object_symbol), sem.symbol_ids[@backingInt(current_ast.getNode(fact.assignment).data.binary.right)]);
    var initializer: NodeIndex = .none;
    for (current_ast.nodes.items) |node| {
        if (node.tag != .variable_declarator) continue;
        const binding = current_ast.readExtraNode(node.data.extra, 0);
        if (sem.symbol_ids[@backingInt(binding)] != fact.object_symbol) continue;
        initializer = current_ast.readExtraNode(node.data.extra, 2);
    }
    try std.testing.expectEqual(.static_member_expression, current_ast.getNode(initializer).tag);
    const dependency = current_ast.readExtraNode(current_ast.getNode(initializer).data.extra, 0);
    try std.testing.expectEqual(@as(?u32, fact.buffer_object_symbol), sem.symbol_ids[@backingInt(dependency)]);
    try std.testing.expect(fact.object_symbol != fact.buffer_object_symbol);
    try std.testing.expect(patterns.foldedNodeBufferExportIsCurrent(&f.module, current_ast, fact.statement, fact));
    var wrong = fact;
    wrong.kind = .module_object;
    try std.testing.expect(!patterns.foldedNodeBufferExportIsCurrent(&f.module, current_ast, fact.statement, wrong));
    wrong = fact;
    wrong.buffer_object_symbol = f.sid;
    try std.testing.expect(!patterns.foldedNodeBufferExportIsCurrent(&f.module, current_ast, fact.statement, wrong));
    const old = sem.symbol_ids[@backingInt(dependency)];
    @constCast(sem.symbol_ids)[@backingInt(dependency)] = fact.object_symbol;
    try std.testing.expect(!patterns.foldedNodeBufferExportIsCurrent(&f.module, current_ast, fact.statement, fact));
    @constCast(sem.symbol_ids)[@backingInt(dependency)] = old;
    try std.testing.expect(patterns.foldedNodeBufferExportIsCurrent(&f.module, current_ast, fact.statement, fact));
}

test "Buffer named constructor export prunes the actual dead fallback declaration" {
    for ([_]bool{ false, true }) |minify| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const helpers = @import("../test_helpers.zig");
        try helpers.writeFile(tmp.dir, "entry.js", "import { Buffer } from './lib.js'; console.log(Buffer.alloc(4).length);");
        try helpers.writeFile(tmp.dir, "lib.js", prefix ++ "if(" ++ condition ++ "){exports.Buffer=B}else{exports.Buffer=SafeBuffer}function SafeBuffer(){return 'BUFFER_CTOR_FALLBACK_MARKER'}SafeBuffer.from='BUFFER_CTOR_SETUP_MARKER';");
        const entry = try helpers.absPath(&tmp, "entry.js");
        defer std.testing.allocator.free(entry);
        var b = @import("../bundler.zig").Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry}, .platform = .node, .minify_syntax = minify });
        defer b.deinit();
        const result = try b.bundle(std.testing.io);
        defer result.deinit(std.testing.allocator);
        try std.testing.expect(!result.hasErrors());
        try std.testing.expect(std.mem.indexOf(u8, result.output, "BUFFER_CTOR_FALLBACK_MARKER") == null);
        try std.testing.expect(std.mem.indexOf(u8, result.output, "BUFFER_CTOR_SETUP_MARKER") == null);
    }
}

test "Buffer export fact preflight validates kept and constructor dependency read tuples atomically" {
    for ([_]bool{ false, true }) |dependency_read| {
        for (0..6) |mutation| {
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            var f = try Fixture.init(a, sources[3]);
            const current_ast = &f.module.ast.?;
            const sem = &f.module.semantic.?;
            var target: NodeIndex = .none;
            // Select the kept export's actual RHS by its structural edge.
            for (current_ast.nodes.items) |node| {
                if (node.tag != .if_statement) continue;
                const kept = current_ast.getNode(node.data.ternary.b);
                const raw = current_ast.extra_data.items[kept.data.list.start];
                const assignment = current_ast.getNode(current_ast.getNode(@fromBackingInt(raw)).data.unary.operand);
                target = assignment.data.binary.right;
                break;
            }
            if (dependency_read) {
                const value_id = sem.symbol_ids[@backingInt(target)].?;
                for (current_ast.nodes.items) |node| {
                    if (node.tag != .variable_declarator) continue;
                    const binding = current_ast.readExtraNode(node.data.extra, 0);
                    if (sem.symbol_ids[@backingInt(binding)] != value_id) continue;
                    const initializer = current_ast.readExtraNode(node.data.extra, 2);
                    target = current_ast.readExtraNode(current_ast.getNode(initializer).data.extra, 0);
                }
            }
            var index: usize = 0;
            for (sem.references, 0..) |row, i| if (row.node_index == target) {
                index = i;
                break;
            };
            const original = try a.dupe(Reference, sem.references);
            const rows = @constCast(sem.references);
            switch (mutation) {
                0 => rows[index].scope_id = @fromBackingInt(f.function_scope),
                1 => rows[index].flags.write = true,
                2 => rows[index].flags.type_context = true,
                3 => rows[index].symbol_id = @fromBackingInt(f.sid),
                4 => rows[index].node_index = .none,
                5 => {
                    const duplicate = try a.alloc(Reference, rows.len + 1);
                    @memcpy(duplicate[0..rows.len], rows);
                    duplicate[rows.len] = rows[index];
                    sem.references = duplicate;
                },
                else => unreachable,
            }
            const malformed = try a.dupe(Reference, sem.references);
            const before = try a.dupe(ast_mod.Node, current_ast.nodes.items);
            var removed: std.ArrayListUnmanaged(NodeIndex) = .empty;
            var facts: std.ArrayListUnmanaged(patterns.FoldedNodeBufferExport) = .empty;
            var needs = false;
            try std.testing.expect(!try patterns.foldNodeBufferCapabilityIfsForModuleWithExports(a, &f.module, current_ast, &removed, &needs, &facts));
            try std.testing.expectEqualDeep(malformed, sem.references);
            try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(before), std.mem.sliceAsBytes(current_ast.nodes.items));
            sem.references = original;
            try std.testing.expect(try patterns.foldNodeBufferCapabilityIfsForModuleWithExports(a, &f.module, current_ast, &removed, &needs, &facts));
            try std.testing.expectEqual(@as(usize, 1), facts.items.len);
        }
    }
}

test "Buffer folded export facts are reset before a new TreeShaker analysis run" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f = try Fixture.init(a, sources[0]);
    var removed: std.ArrayListUnmanaged(NodeIndex) = .empty;
    var facts: std.ArrayListUnmanaged(patterns.FoldedNodeBufferExport) = .empty;
    var needs = false;
    try std.testing.expect(try patterns.foldNodeBufferCapabilityIfsForModuleWithExports(a, &f.module, &f.module.ast.?, &removed, &needs, &facts));
    var cache = @import("../resolve_cache.zig").ResolveCache.init(std.testing.allocator, .{});
    defer cache.deinit();
    var graph = @import("../graph.zig").ModuleGraph.init(std.testing.allocator, &cache);
    defer graph.deinit();
    var linker = @import("../linker.zig").Linker.init(std.testing.allocator, &graph, .esm);
    defer linker.deinit();
    try linker.link();
    linker.populateImportSymbols();
    var shaker = try @import("../tree_shaker.zig").TreeShaker.init(std.testing.allocator, &graph, &linker);
    defer shaker.deinit();
    try shaker.node_buffer_folded_exports.put(std.testing.allocator, 0, facts.items[0]);
    try std.testing.expectEqual(@as(usize, 1), shaker.node_buffer_folded_exports.count());
    try shaker.analyze(&.{});
    try std.testing.expectEqual(@as(usize, 0), shaker.node_buffer_folded_exports.count());
}
