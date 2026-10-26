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
    try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(before), std.mem.sliceAsBytes(foreign.nodes.items));
    try std.testing.expect(try f.fold(a, &removed));
}
