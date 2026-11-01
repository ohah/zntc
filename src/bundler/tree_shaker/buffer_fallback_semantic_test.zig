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

test {
    _ = @import("../graph/finalize.zig");
}

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
        // This fixture is explicitly the Node host realm with no resolver
        // overrides. Capture literal anchors through the real AST scanner.
        const imports = try @import("../import_scanner.zig").extractImportsWithCjsDetectionAndDefines(a, &module.ast.?, &.{});
        module.import_records = imports.records;
        for (module.import_records) |*record| {
            if (record.kind == .require and
                (std.mem.eql(u8, record.specifier, "buffer") or std.mem.eql(u8, record.specifier, "node:buffer"))) record.is_external = true;
        }
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

const DirectVarAlternateNodes = struct {
    if_index: NodeIndex,
    alternate: NodeIndex,
    declarator: NodeIndex,
    binding: NodeIndex,
    initializer: NodeIndex,
};

fn findDirectVarAlternate(ast: *const ast_mod.Ast) ?DirectVarAlternateNodes {
    if (ast.nodes.items.len == 0) return null;
    const root: NodeIndex = ast.transformed_root orelse @fromBackingInt(
        @as(u32, @intCast(ast.nodes.items.len - 1)),
    );
    if (root.isNone() or @backingInt(root) >= ast.nodes.items.len) return null;
    const program = ast.getNode(root);
    if (program.tag != .program or program.data.list.start > ast.extra_data.items.len or
        program.data.list.len > ast.extra_data.items.len - program.data.list.start) return null;
    for (ast.extra_data.items[program.data.list.start..][0..program.data.list.len]) |raw| {
        if (raw >= ast.nodes.items.len) return null;
        const statement = ast.nodes.items[raw];
        if (statement.tag != .if_statement or statement.data.ternary.c.isNone() or
            @backingInt(statement.data.ternary.c) >= ast.nodes.items.len) continue;
        const alternate = statement.data.ternary.c;
        const declaration = ast.nodes.items[@backingInt(alternate)];
        if (declaration.tag != .variable_declaration or !ast.hasExtra(declaration.data.extra, 2)) continue;
        const start = ast.readExtra(declaration.data.extra, 1);
        const len = ast.readExtra(declaration.data.extra, 2);
        if (len != 1 or start >= ast.extra_data.items.len or len > ast.extra_data.items.len - start) continue;
        const declarator: NodeIndex = @fromBackingInt(@intCast(ast.extra_data.items[start]));
        if (@backingInt(declarator) >= ast.nodes.items.len or
            ast.getNode(declarator).tag != .variable_declarator or
            !ast.hasExtra(ast.getNode(declarator).data.extra, 2)) continue;
        const declaration_node = ast.getNode(declarator);
        const binding = ast.readExtraNode(declaration_node.data.extra, 0);
        const initializer = ast.readExtraNode(declaration_node.data.extra, 2);
        if (binding.isNone() or initializer.isNone() or
            !std.mem.eql(u8, ast.getText(ast.getNode(binding).span), "fallback")) continue;
        return .{
            .if_index = @fromBackingInt(@intCast(raw)),
            .alternate = alternate,
            .declarator = declarator,
            .binding = binding,
            .initializer = initializer,
        };
    }
    return null;
}

const direct_var_alternate_source = prefix ++ "if(" ++ condition ++ "){module.exports=buffer}else var fallback=SafeBuffer;function SafeBuffer(){return 1}module.exports=fallback;";
const async_fallback_source = prefix ++ "if(" ++ condition ++ "){module.exports=buffer}else{exports.Buffer=SafeBuffer}async function SafeBuffer(){return 1}module.exports=buffer;";

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

test "Buffer direct var alternate keeps the hoisted binding and removes one exact read" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f = try Fixture.init(a, direct_var_alternate_source);
    const nodes = findDirectVarAlternate(&f.module.ast.?) orelse return error.MissingVarAlternate;
    const fallback_sid = f.module.semantic.?.symbol_ids[@backingInt(nodes.binding)] orelse return error.MissingFallbackSymbol;
    try std.testing.expectEqual(nodes.initializer, f.read);
    const old_fallback_reads = f.module.semantic.?.symbols.items[f.sid].reference_count;
    var removed: std.ArrayListUnmanaged(NodeIndex) = .empty;
    try std.testing.expect(try f.fold(a, &removed));
    try std.testing.expectEqual(@as(usize, 1), removed.items.len);
    try std.testing.expectEqual(nodes.initializer, removed.items[0]);
    try std.testing.expectEqual(nodes.alternate, f.module.ast.?.getNode(nodes.if_index).data.ternary.c);
    try std.testing.expect(f.module.ast.?.readExtraNode(
        f.module.ast.?.getNode(nodes.declarator).data.extra,
        2,
    ).isNone());

    const context = .{
        .allocator = a,
        .defines = &[_]@import("../../parser/scan_results.zig").DefineEntry{},
        .wrapper_symbols_registered = false,
        .wrap_kinds_finalized = true,
        .transform_options_base = .{ .minify_syntax = false },
    };
    try std.testing.expect(try prepass.resyncLegacyBufferGraphForTest(
        &context,
        &f.module,
        a,
        removed.items,
    ));
    const semantic = &f.module.semantic.?;
    try std.testing.expectEqual(@as(?u32, fallback_sid), semantic.symbol_ids[@backingInt(nodes.binding)]);
    try std.testing.expect(semantic.symbol_ids[@backingInt(nodes.initializer)] == null);
    try std.testing.expect(semantic.symbols.items[f.sid].reference_count < old_fallback_reads);
    var fallback_declarations: usize = 0;
    for (semantic.references) |row| {
        if (row.flags.declare and row.declaration_node_index == nodes.binding) {
            try std.testing.expectEqual(fallback_sid, @backingInt(row.symbol_id));
            fallback_declarations += 1;
        }
        try std.testing.expect(row.node_index != nodes.initializer);
    }
    try std.testing.expectEqual(@as(usize, 1), fallback_declarations);
}

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
        const plan = (try patterns.prepareLegacyNodeBufferCapabilityPlanForTest(a, &f.module)) orelse {
            std.debug.print("Buffer fallback case={d} failed its pre-write proof\n", .{index});
            return error.MissingBufferPlan;
        };
        const folded = (try plan.cloneLegacyFoldForTest(&f.module, a)).?;
        try removed.appendSlice(a, folded.removed_nodes);
        const context = .{ .allocator = a, .defines = &[_]@import("../../parser/scan_results.zig").DefineEntry{}, .wrapper_symbols_registered = false, .wrap_kinds_finalized = true, .transform_options_base = .{ .minify_syntax = false } };
        var prepared = (try prepass.prepareLegacyBufferFoldForTest(&context, &f.module, a, &plan)) orelse return error.MissingBufferPreparation;
        defer prepared.discard();
        try std.testing.expect(prepared.publish(&f.module));
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

test "async Buffer fallback declaration also stays on the retained graph" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f = try Fixture.init(a, async_fallback_source);
    try std.testing.expect(patterns.nodeBufferCapabilityValuesAreStable(&f.module));
    var removed: std.ArrayListUnmanaged(NodeIndex) = .empty;
    try std.testing.expect(try f.fold(a, &removed));
    const context = .{
        .allocator = a,
        .defines = &[_]@import("../../parser/scan_results.zig").DefineEntry{},
        .wrapper_symbols_registered = false,
        .wrap_kinds_finalized = true,
        .transform_options_base = .{ .minify_syntax = false },
    };
    try std.testing.expect(try prepass.resyncLegacyBufferGraphForTest(
        &context,
        &f.module,
        a,
        removed.items,
    ));
}

const VarAlternateMutation = enum {
    non_cjs_module,
    missing_root_owner,
    lexical_declaration,
    multiple_declarators,
    destructuring_binding,
    missing_initializer,
    call_initializer,
    binding_sid_missing,
    binding_sid_wrong,
    binding_declaration_missing,
    initializer_sid_missing,
    initializer_sid_wrong,
    initializer_row_wrong_sid,
    initializer_flags,
    initializer_duplicate,
    initializer_wrong_scope,
    initializer_symbol_scope_wrong,
    initializer_provenance,
    initializer_helper_cache,
    initializer_class_self_owner,
    initializer_scope_owner,
    initializer_tla_owner,
};

test "Buffer direct var alternate rejects malformed exact evidence before any write" {
    inline for (std.meta.tags(VarAlternateMutation)) |mutation| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var f = try Fixture.init(a, direct_var_alternate_source);
        const nodes = findDirectVarAlternate(&f.module.ast.?) orelse return error.MissingVarAlternate;
        const ast = &f.module.ast.?;
        const semantic = &f.module.semantic.?;
        const declaration = ast.getNode(nodes.alternate);
        const declarator = ast.getNode(nodes.declarator);
        const root_scope_owner: NodeIndex = ast.transformed_root orelse @fromBackingInt(
            @as(u32, @intCast(ast.nodes.items.len - 1)),
        );
        const root_scope_id = semantic.scope_owner_map.get(@backingInt(root_scope_owner)).?;
        const wrapper = f.module.cjs_wrapper_exports_parameter_symbol.?;
        var declaration_row: ?usize = null;
        var initializer_row: ?usize = null;
        for (semantic.references, 0..) |row, index| {
            if (row.flags.declare and row.declaration_node_index == nodes.binding) declaration_row = index;
            if (row.node_index == nodes.initializer) initializer_row = index;
        }
        switch (mutation) {
            .non_cjs_module => f.module.wrap_kind = .esm,
            .missing_root_owner => _ = semantic.scope_owner_map.remove(@backingInt(root_scope_owner)),
            .lexical_declaration => ast.extra_data.items[declaration.data.extra] = @backingInt(ast_mod.VariableDeclarationKind.let),
            .multiple_declarators => ast.extra_data.items[declaration.data.extra + 2] = 2,
            .destructuring_binding => @constCast(ast.nodes.items)[@backingInt(nodes.binding)].tag = .object_pattern,
            .missing_initializer => ast.extra_data.items[declarator.data.extra + 2] = @backingInt(NodeIndex.none),
            .call_initializer => @constCast(ast.nodes.items)[@backingInt(nodes.initializer)].tag = .call_expression,
            .binding_sid_missing => @constCast(semantic.symbol_ids)[@backingInt(nodes.binding)] = null,
            .binding_sid_wrong => @constCast(semantic.symbol_ids)[@backingInt(nodes.binding)] = f.sid,
            .binding_declaration_missing => @constCast(semantic.references)[declaration_row.?].flags.declare = false,
            .initializer_sid_missing => @constCast(semantic.symbol_ids)[@backingInt(nodes.initializer)] = null,
            .initializer_sid_wrong => @constCast(semantic.symbol_ids)[@backingInt(nodes.initializer)] = @backingInt(wrapper),
            .initializer_row_wrong_sid => @constCast(semantic.references)[initializer_row.?].symbol_id = wrapper,
            .initializer_flags => @constCast(semantic.references)[initializer_row.?].flags.write = true,
            .initializer_duplicate => {
                const rows = try a.alloc(Reference, semantic.references.len + 1);
                @memcpy(rows[0..semantic.references.len], semantic.references);
                rows[semantic.references.len] = semantic.references[initializer_row.?];
                semantic.references = rows;
            },
            .initializer_wrong_scope => @constCast(semantic.references)[initializer_row.?].scope_id = @fromBackingInt(f.function_scope),
            .initializer_symbol_scope_wrong => {
                const initializer_id = semantic.symbol_ids[@backingInt(nodes.initializer)].?;
                semantic.symbols.items[initializer_id].scope_id = @fromBackingInt(f.function_scope);
            },
            .initializer_provenance => try semantic.node_scope_provenance.put(a, nodes.initializer, .{
                .scope = semantic.symbols.items[f.sid].scope_id,
                .source_node = nodes.initializer,
            }),
            .initializer_helper_cache => f.module.transform_cache = .{
                .runtime_helpers = .{},
                .symbol_ids = semantic.symbol_ids,
                .helper_ref_nodes = &.{@backingInt(nodes.initializer)},
            },
            .initializer_class_self_owner => try semantic.class_self_symbol_map.put(
                a,
                @backingInt(nodes.initializer),
                f.sid,
            ),
            .initializer_scope_owner => try semantic.scope_owner_map.put(
                a,
                @backingInt(nodes.initializer),
                root_scope_id,
            ),
            .initializer_tla_owner => f.module.tla_iife_stmt = @backingInt(nodes.initializer),
        }

        const before_nodes = try a.dupe(ast_mod.Node, ast.nodes.items);
        const before_extra = try a.dupe(u32, ast.extra_data.items);
        const before_symbols = try a.dupe(Symbol, semantic.symbols.items);
        const before_references = try a.dupe(Reference, semantic.references);
        const before_scopes = try a.dupe(Scope, semantic.scopes);
        const before_ids = try a.dupe(?u32, semantic.symbol_ids);
        const before_owner_map = try semantic.scope_owner_map.clone(a);
        const before_provenance_count = semantic.node_scope_provenance.count();
        const before_class_self_count = semantic.class_self_symbol_map.count();
        var removed: std.ArrayListUnmanaged(NodeIndex) = .empty;
        var needs = false;
        const accepted = try patterns.foldNodeBufferCapabilityIfsForModule(
            a,
            &f.module,
            ast,
            &removed,
            &needs,
        );
        if (accepted) std.debug.print("Buffer var alternate admitted hostile {s}\n", .{@tagName(mutation)});
        try std.testing.expect(!accepted);
        try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(before_nodes), std.mem.sliceAsBytes(ast.nodes.items));
        try std.testing.expectEqualSlices(u32, before_extra, ast.extra_data.items);
        try std.testing.expectEqualDeep(before_symbols, semantic.symbols.items);
        try std.testing.expectEqualDeep(before_references, semantic.references);
        try std.testing.expectEqualDeep(before_scopes, semantic.scopes);
        try std.testing.expectEqualDeep(before_ids, semantic.symbol_ids);
        try std.testing.expectEqual(before_owner_map.count(), semantic.scope_owner_map.count());
        try std.testing.expectEqual(before_provenance_count, semantic.node_scope_provenance.count());
        try std.testing.expectEqual(before_class_self_count, semantic.class_self_symbol_map.count());
        var owners = before_owner_map.iterator();
        while (owners.next()) |entry| {
            try std.testing.expectEqual(@as(?u32, entry.value_ptr.*), semantic.scope_owner_map.get(entry.key_ptr.*));
        }
    }
}

const Mutation = enum { read_sid, read_row_sid, read_flags, read_type_context, read_scope, declaration_sid, declaration_flags, declaration_missing, declaration_duplicate, declaration_scope, function_scope_kind, function_scope_parent, function_owner_missing, function_ast_flags, symbol_kind, symbol_role, symbol_scope, symbol_writes, symbol_count, wrapper_missing, wrapper_role, direct_eval };

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
            .function_ast_flags => @constCast(f.module.ast.?.extra_data.items)[
                f.module.ast.?.getNode(f.function).data.extra + ast_mod.FunctionExtra.flags
            ] = ast_mod.FunctionFlags.is_async,
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
        if (mutation == .function_ast_flags) {
            @constCast(f.module.ast.?.extra_data.items)[
                f.module.ast.?.getNode(f.function).data.extra + ast_mod.FunctionExtra.flags
            ] = 0;
        }
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
        for (0..10) |mutation| {
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
                // Four additional guards from peer ff9bb5c11. These are
                // eight new poison inputs across two actual read classes;
                // the original six cases remain the original cohort.
                6 => rows[index].flags.read = false,
                7 => {
                    rows[index].flags.read = false;
                    rows[index].flags.write = true;
                },
                8 => rows[index].declaration_node_index = target,
                9 => rows[index].flags.value_as_type = true,
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

test "Buffer capability value proof rejects dynamic missing and stale program scopes without edits" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f = try Fixture.init(a, sources[0]);
    try std.testing.expect(patterns.nodeBufferCapabilityValuesAreStable(&f.module));
    const sem = &f.module.semantic.?;
    const root = f.module.ast.?.transformed_root orelse @as(NodeIndex, @fromBackingInt(@as(u32, @intCast(f.module.ast.?.nodes.items.len - 1))));
    const scope_before = sem.scopes[0];
    const root_owner = sem.scope_owner_map.get(@backingInt(root)).?;
    const node_count = f.module.ast.?.nodes.items.len;
    const reference_count = sem.references.len;
    const symbol_count = sem.symbols.items.len;
    for (0..6) |mutation| {
        const semantic_before = f.module.semantic;
        switch (mutation) {
            0 => @constCast(sem.scopes)[0].subtree_has_direct_eval = true,
            1 => @constCast(sem.scopes)[0].subtree_has_with = true,
            2 => @constCast(sem.scopes)[0].kind = .function,
            3 => _ = sem.scope_owner_map.remove(@backingInt(root)),
            4 => try sem.scope_owner_map.put(a, @backingInt(root), f.function_scope),
            5 => f.module.semantic = null,
            else => unreachable,
        }
        try std.testing.expect(!patterns.nodeBufferCapabilityValuesAreStable(&f.module));
        if (mutation == 5) f.module.semantic = semantic_before;
        @constCast(f.module.semantic.?.scopes)[0] = scope_before;
        try f.module.semantic.?.scope_owner_map.put(a, @backingInt(root), root_owner);
        try std.testing.expectEqual(node_count, f.module.ast.?.nodes.items.len);
        try std.testing.expectEqual(reference_count, f.module.semantic.?.references.len);
        try std.testing.expectEqual(symbol_count, f.module.semantic.?.symbols.items.len);
        try std.testing.expect(patterns.nodeBufferCapabilityValuesAreStable(&f.module));
    }
    const scopes_before = sem.scopes;
    sem.scopes = &.{};
    try std.testing.expect(!patterns.nodeBufferCapabilityValuesAreStable(&f.module));
    sem.scopes = scopes_before;
    try std.testing.expect(patterns.nodeBufferCapabilityValuesAreStable(&f.module));
}

const dynamic_value_prefix = "var buffer=require('buffer');var B=buffer.Buffer;var events=[];";
const dynamic_value_branch = "if(B.from&&B.alloc&&B.allocUnsafe&&B.allocUnsafeSlow){module.exports=buffer}else{exports.Buffer=SafeBuffer}";
const dynamic_value_fallback = "function SafeBuffer(){}SafeBuffer.from=function(value){var receiver=this;return{toString:function(){return 'DYNAMIC_FALLBACK:'+value+':'+events.join(',')+':'+(receiver===SafeBuffer)}}};";
const DynamicValueCase = struct {
    source: []const u8,
    code: []const u8,
    unknown_argument: bool = false,
    no_fold: bool = true,
    with_boundary: bool = false,
    expect_fold: bool = false,
};
const dynamic_value_cases = [_]DynamicValueCase{
    .{ .source = dynamic_value_prefix ++ "eval(process.argv[2]);" ++ dynamic_value_branch ++ dynamic_value_fallback, .code = "B={from:0,alloc:0,allocUnsafe:0,allocUnsafeSlow:0}" },
    .{ .source = dynamic_value_prefix ++ "eval(process.argv[2]);" ++ dynamic_value_branch ++ dynamic_value_fallback, .code = "B={from:0,alloc:0,allocUnsafe:0,allocUnsafeSlow:0}", .unknown_argument = true },
    .{ .source = dynamic_value_prefix ++ "eval(process.argv[2]);" ++ dynamic_value_branch ++ dynamic_value_fallback, .code = "B={get from(){events.push('from');return 0},get alloc(){events.push('alloc');return 0}}" },
    .{ .source = dynamic_value_prefix ++ "eval(process.argv[2]);" ++ dynamic_value_branch ++ dynamic_value_fallback, .code = "B={from:function(){events.push('never-call')},alloc:0,allocUnsafe:0,allocUnsafeSlow:0}" },
    .{ .source = dynamic_value_prefix ++ "eval(process.argv[2]);" ++ dynamic_value_branch ++ dynamic_value_fallback, .code = "buffer={get Buffer(){console.log('getter');return{label:'changed',from:function(value){var receiver=this;return{toString:function(){return receiver.label+':'+value}}}}}}" },
    .{ .source = dynamic_value_prefix ++ "eval('void B');" ++ dynamic_value_branch ++ dynamic_value_fallback, .code = "" },
    .{ .source = dynamic_value_prefix ++ "var from=B.from;eval(process.argv[2]);module.exports={Buffer:{from:function(value,encoding){return from(value,encoding)}}};", .code = "from=function(value){return{toString:function(){return 'changed:'+value}}}", .unknown_argument = true, .no_fold = false },
    .{ .source = dynamic_value_prefix ++ "with({B:{from:0,alloc:0,allocUnsafe:0,allocUnsafeSlow:0}}){" ++ dynamic_value_branch ++ "}" ++ dynamic_value_fallback, .code = "", .with_boundary = true },
    .{ .source = dynamic_value_prefix ++ "with({}){" ++ dynamic_value_branch ++ "}" ++ dynamic_value_fallback, .code = "", .with_boundary = true },
    .{ .source = dynamic_value_prefix ++ "function change(){eval(process.argv[2])}change();" ++ dynamic_value_branch ++ dynamic_value_fallback, .code = "B={from:0,alloc:0,allocUnsafe:0,allocUnsafeSlow:0}" },
    .{ .source = dynamic_value_prefix ++ "B={from:0,alloc:0,allocUnsafe:0,allocUnsafeSlow:0};" ++ dynamic_value_branch ++ dynamic_value_fallback, .code = "change" },
    .{ .source = dynamic_value_prefix ++ "if(process.argv[2])B={from:0,alloc:0,allocUnsafe:0,allocUnsafeSlow:0};" ++ dynamic_value_branch ++ dynamic_value_fallback, .code = "change" },
    .{ .source = dynamic_value_prefix ++ "function change(){B={from:0,alloc:0,allocUnsafe:0,allocUnsafeSlow:0}}change();" ++ dynamic_value_branch ++ dynamic_value_fallback, .code = "change" },
    .{ .source = dynamic_value_prefix ++ "B=make();function make(){return{from:0,alloc:0,allocUnsafe:0,allocUnsafeSlow:0}}" ++ dynamic_value_branch ++ dynamic_value_fallback, .code = "change" },
    .{ .source = dynamic_value_prefix ++ "buffer={Buffer:{from:0,alloc:0,allocUnsafe:0,allocUnsafeSlow:0}};B=buffer.Buffer;" ++ dynamic_value_branch ++ dynamic_value_fallback, .code = "change" },
    .{ .source = dynamic_value_prefix ++ "B=buffer.Buffer;B={from:0,alloc:0,allocUnsafe:0,allocUnsafeSlow:0};" ++ dynamic_value_branch ++ dynamic_value_fallback, .code = "change" },
    .{ .source = dynamic_value_prefix ++ "if(process.argv[2]){var B={from:0,alloc:0,allocUnsafe:0,allocUnsafeSlow:0}}" ++ dynamic_value_branch ++ dynamic_value_fallback, .code = "change" },
    .{ .source = dynamic_value_prefix ++ "if(process.argv[2]){var buffer={Buffer:{from:function(value){return{toString:function(){return 'changed:'+value}}}}}}" ++ dynamic_value_branch ++ dynamic_value_fallback, .code = "change", .no_fold = false },
    .{ .source = dynamic_value_prefix ++ "if(process.argv[2]){var {B}={B:{from:0,alloc:0,allocUnsafe:0,allocUnsafeSlow:0}}}" ++ dynamic_value_branch ++ dynamic_value_fallback, .code = "change" },
    .{ .source = dynamic_value_prefix ++ "if(process.argv[2]){var [B]=[{from:0,alloc:0,allocUnsafe:0,allocUnsafeSlow:0}]}" ++ dynamic_value_branch ++ dynamic_value_fallback, .code = "change" },
    .{ .source = prefix ++ "if(" ++ condition ++ "){exports.Buffer=B}else{exports.Buffer=SafeBuffer}function SafeBuffer(){return 'DYNAMIC_FALLBACK:'}SafeBuffer.from='DYNAMIC_FALLBACK:';", .code = "", .no_fold = false },
};

test "Buffer dynamic local aliases keep both runtime branches and their original values" {
    const helpers = @import("../test_helpers.zig");
    const profile = @import("../../profile.zig");
    for (dynamic_value_cases, 0..) |case, index| {
        for ([_]bool{ false, true }) |minify| {
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            const entry_source = if (case.unknown_argument)
                "var API=require('./lib.cjs').Buffer;console.log(API.from(process.argv[3],'hex').toString());"
            else
                "var API=require('./lib.cjs').Buffer;console.log(API.from('61','hex').toString());";
            try helpers.writeFile(tmp.dir, "entry.cjs", entry_source);
            try helpers.writeFile(tmp.dir, "lib.cjs", case.source);
            const entry = try helpers.absPath(&tmp, "entry.cjs");
            defer std.testing.allocator.free(entry);
            const native = try std.process.run(a, std.testing.io, .{ .argv = &.{ "node", entry, case.code, "62" } });
            try std.testing.expect(native.term == .exited and native.term.exited == 0);
            profile.resetForTest();
            defer profile.resetForTest();
            profile.setIoForTest(std.testing.io);
            profile.addFromCsv("graph.resync.semantic");
            var bundler = @import("../bundler.zig").Bundler.init(std.testing.allocator, .{
                .entry_points = &.{entry},
                .platform = .node,
                .format = .cjs,
                .minify_syntax = minify,
                .minify_identifiers = minify,
                .minify_whitespace = minify,
            });
            defer bundler.deinit();
            const result = try bundler.bundle(std.testing.io);
            defer result.deinit(std.testing.allocator);
            try std.testing.expect(!result.hasErrors());
            // Dynamic lookup keeps its veto without replacing the source graph.
            const expected_resyncs: u32 = 0;
            if (expected_resyncs != profile.count(.graph_resync_semantic))
                std.debug.print("Buffer dynamic profile case={d} min={any} expected={d} actual={d}\n", .{ index, minify, expected_resyncs, profile.count(.graph_resync_semantic) });
            try std.testing.expectEqual(expected_resyncs, profile.count(.graph_resync_semantic));
            if (case.no_fold) try std.testing.expect(std.mem.indexOf(u8, result.output, "DYNAMIC_FALLBACK:") != null);
            if (case.expect_fold) try std.testing.expect(std.mem.indexOf(u8, result.output, "DYNAMIC_FALLBACK:") == null);
            try helpers.writeFile(tmp.dir, "out.cjs", result.output);
            const out = try helpers.absPath(&tmp, "out.cjs");
            defer std.testing.allocator.free(out);
            const actual = try std.process.run(a, std.testing.io, .{ .argv = &.{ "node", out, case.code, "62" } });
            if (actual.term != .exited or actual.term.exited != 0 or !std.mem.eql(u8, native.stdout, actual.stdout))
                std.debug.print("Buffer dynamic value case={d} min={any} native:{s} actual:{s} stderr:{s} code:{s}\n", .{ index, minify, native.stdout, actual.stdout, actual.stderr, result.output });
            try std.testing.expect(actual.term == .exited and actual.term.exited == 0);
            try std.testing.expectEqualStrings(native.stdout, actual.stdout);
        }
    }
}

test "Buffer capability value proof validates enclosing block owner kind and parent" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f = try Fixture.init(a, prefix ++ "{if(" ++ condition ++ "){module.exports=buffer}else{exports.Buffer=SafeBuffer}}function SafeBuffer(){return 1}");
    const sem = &f.module.semantic.?;
    const ast = &f.module.ast.?;
    var block: ?u32 = null;
    for (ast.nodes.items, 0..) |node, raw| {
        if (node.tag != .block_statement) continue;
        const id = sem.scope_owner_map.get(@intCast(raw)) orelse continue;
        if (sem.scopes[id].kind == .block and @backingInt(sem.scopes[id].parent) == 0) {
            block = id;
            break;
        }
    }
    const id = block.?;
    const before = sem.scopes[id];
    try std.testing.expect(patterns.nodeBufferCapabilityValuesAreStable(&f.module));
    @constCast(sem.scopes)[id].kind = .function;
    try std.testing.expect(!patterns.nodeBufferCapabilityValuesAreStable(&f.module));
    @constCast(sem.scopes)[id] = before;
    @constCast(sem.scopes)[id].parent = @fromBackingInt(f.function_scope);
    try std.testing.expect(!patterns.nodeBufferCapabilityValuesAreStable(&f.module));
    @constCast(sem.scopes)[id] = before;
    try std.testing.expect(patterns.nodeBufferCapabilityValuesAreStable(&f.module));
}

test "Buffer nested eval marks the program while its outer alias has zero static writes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f = try Fixture.init(a, dynamic_value_prefix ++ "function change(){eval(process.argv[2])}change();" ++ dynamic_value_branch ++ dynamic_value_fallback);
    const sem = &f.module.semantic.?;
    try std.testing.expect(sem.scopes[0].subtree_has_direct_eval);
    const ast = &f.module.ast.?;
    const root = ast.transformed_root orelse @as(NodeIndex, @fromBackingInt(@as(u32, @intCast(ast.nodes.items.len - 1))));
    var statements = ast.iterateExtraList(ast.getNode(root).data.list);
    _ = statements.next().?;
    const second = ast.getNode(statements.next().?);
    var declarations = ast.iterateExtraList(second.data.list);
    const declaration = ast.getNode(declarations.next().?);
    const binding = ast.readExtraNode(declaration.data.extra, 0);
    const id = sem.symbol_ids[@backingInt(binding)].?;
    try std.testing.expectEqual(@as(u32, 0), sem.symbols.items[id].write_count);
    try std.testing.expect(!patterns.nodeBufferCapabilityValuesAreStable(&f.module));
}

test "Buffer transaction failed preparation preserves original semantic publication" {
    var failures: usize = 0;
    for (0..128) |fail_index| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var f = try Fixture.init(a, sources[0]);
        var removed: std.ArrayListUnmanaged(NodeIndex) = .empty;
        try std.testing.expect(try f.fold(a, &removed));
        const before = f.module.semantic.?;
        var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = fail_index });
        const context = .{ .allocator = a, .defines = &[_]@import("../../parser/scan_results.zig").DefineEntry{}, .wrapper_symbols_registered = false, .wrap_kinds_finalized = true, .transform_options_base = .{ .minify_syntax = false } };
        _ = prepass.resyncLegacyBufferGraphForTest(&context, &f.module, failing.allocator(), removed.items) catch {
            failures += 1;
            try std.testing.expectEqual(@intFromPtr(before.symbol_ids.ptr), @intFromPtr(f.module.semantic.?.symbol_ids.ptr));
            try std.testing.expectEqual(@intFromPtr(before.references.ptr), @intFromPtr(f.module.semantic.?.references.ptr));
            continue;
        };
    }
    try std.testing.expect(failures > 0);
}

test "Buffer statement info preparation cleans only initialized rows on OOM" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f = try Fixture.init(a, sources[0]);
    const sem = f.module.semantic.?;
    var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = 1 });
    try std.testing.expectError(error.OutOfMemory, @import("../stmt_info.zig").buildFromSemantic(failing.allocator(), &f.module.ast.?, sem.symbols.items, sem.scopes, sem.symbol_ids, sem.references, &sem.unresolved_references, false, false));
}

test "Buffer transaction actual owner plan stages AST graph metadata before commit" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const helpers = @import("../test_helpers.zig");
    try helpers.writeFile(tmp.dir, "entry.cjs", sources[0]);
    const entry = try helpers.absPath(&tmp, "entry.cjs");
    defer std.testing.allocator.free(entry);
    try helpers.writeFile(tmp.dir, "sibling.mjs", "export const sibling=1;");
    const sibling_path = try helpers.absPath(&tmp, "sibling.mjs");
    defer std.testing.allocator.free(sibling_path);
    var cache = @import("../resolve_cache.zig").ResolveCache.init(std.testing.allocator, .{ .platform = .node });
    defer cache.deinit();
    var graph = @import("../graph.zig").ModuleGraph.init(std.testing.allocator, &cache);
    defer graph.deinit();
    try graph.build(std.testing.io, &.{ entry, sibling_path });
    try graph.registerWrapperSymbols();
    var modules = graph.modulesIterator();
    var actual: ?*Module = null;
    var sibling: ?*const Module = null;
    while (modules.next()) |module| {
        if (std.mem.eql(u8, module.path, entry)) actual = @constCast(module);
        if (std.mem.eql(u8, module.path, sibling_path)) sibling = module;
    }
    const module = actual orelse return error.MissingEntry;
    const sibling_module = sibling orelse return error.MissingSibling;
    const runtime_source = (try @import("../../semantic/output_runtime_witness.zig").capture(a, &graph, module)) orelse return error.MissingRuntimeSource;
    try std.testing.expect(runtime_source.validateTarget(module));
    const coverage_mod = @import("../../semantic/output_runtime_coverage.zig");
    const coverage_proof = coverage_mod.forTarget(.{ .source = &runtime_source, .module = module }) orelse return error.MissingRuntimeCoverageProof;
    for (runtime_source.entries) |runtime_entry| try std.testing.expect(coverage_proof.hasOutputBinding(@backingInt(runtime_entry.symbol)));
    try std.testing.expect(!coverage_proof.hasOutputBinding(@intCast(module.semantic.?.symbols.items.len)));
    try std.testing.expectEqual(module.index, coverage_proof.moduleIndex().?);
    try std.testing.expectEqual(runtime_source.wrapper.?.scope, coverage_proof.wrapper().?.scope);
    const wrapper_ids = [_]@import("../../semantic/symbol.zig").SymbolId{ module.cjs_wrapper_exports_parameter_symbol.?, module.cjs_wrapper_module_parameter_symbol.? };
    for (wrapper_ids) |sid| {
        var reads: u32 = 0;
        var writes: u32 = 0;
        for (module.semantic.?.references) |reference| {
            if (reference.symbol_id != sid or reference.flags.declare) continue;
            try std.testing.expectEqual(@as(?u32, @backingInt(sid)), module.semantic.?.symbol_ids[@backingInt(reference.node_index)]);
            reads += @intFromBool(reference.flags.read);
            writes += @intFromBool(reference.flags.write);
        }
        try std.testing.expectEqual(module.semantic.?.symbols.items[@backingInt(sid)].reference_count, reads);
        try std.testing.expectEqual(module.semantic.?.symbols.items[@backingInt(sid)].write_count, writes);
    }
    // A projection is a target only. Its unregistered owner, scope or known
    // role cannot manufacture the authority captured from the installed graph.
    var foreign_module = module.*;
    const foreign_semantic = module.semantic.?;
    foreign_module.semantic = foreign_semantic;
    foreign_module.semantic.?.owner_token = .unassigned;
    try std.testing.expect(!runtime_source.validateTarget(&foreign_module));
    foreign_module = module.*;
    foreign_module.semantic.?.scopes = sibling_module.semantic.?.scopes;
    try std.testing.expect(!runtime_source.validateTarget(&foreign_module));
    foreign_module = module.*;
    var forged_domain_source = runtime_source;
    forged_domain_source.module = &foreign_module;
    forged_domain_source.ast = &foreign_module.ast.?;
    try std.testing.expect(!forged_domain_source.validateTarget(&foreign_module));
    const actual_owner = module.semantic.?.owner_token;
    module.semantic.?.owner_token = sibling_module.semantic.?.owner_token;
    var forged_owner_source = runtime_source;
    forged_owner_source.owner = module.semantic.?.owner_token;
    try std.testing.expect(!forged_owner_source.validateTarget(module));
    module.semantic.?.owner_token = actual_owner;
    try std.testing.expect(runtime_source.validateTarget(module));
    const witness_mod = @import("../../semantic/output_runtime_witness.zig");
    const poisoned_entries = try a.dupe(witness_mod.Entry, runtime_source.entries);
    var poisoned_source = runtime_source;
    poisoned_source.entries = poisoned_entries;
    const original_entry = poisoned_entries[0];
    poisoned_entries[0].before.kind = .variable_let;
    try std.testing.expect(!poisoned_source.validateTarget(module));
    poisoned_entries[0] = original_entry;
    poisoned_entries[0].role = @fromBackingInt(@as(u32, 999));
    try std.testing.expect(!poisoned_source.validateTarget(module));
    poisoned_entries[0] = original_entry;
    for (poisoned_entries, 0..) |entry_witness, entry_index| {
        if (entry_witness.role != .module_require) continue;
        const raw = @backingInt(entry_witness.symbol);
        const before = module.semantic.?.symbols.items[raw];
        module.semantic.?.symbols.items[raw].synthetic_kind = .esm_init;
        poisoned_entries[entry_index].before = module.semantic.?.symbols.items[raw];
        try std.testing.expect(!poisoned_source.validateTarget(module));
        module.semantic.?.symbols.items[raw] = before;
        poisoned_entries[entry_index] = runtime_source.entries[entry_index];
    }
    if (poisoned_entries.len > 1) {
        poisoned_entries[1] = original_entry;
        try std.testing.expect(!poisoned_source.validateTarget(module));
        poisoned_entries[1] = runtime_source.entries[1];
    }
    poisoned_source.owner = .unassigned;
    try std.testing.expect(!poisoned_source.validateTarget(module));
    const wrapper_scope = runtime_source.wrapper.?.scope;
    const scopes = @constCast(module.semantic.?.scopes);
    const original_parent = scopes[0].parent;
    scopes[0].parent = .none;
    try std.testing.expect(!runtime_source.validateTarget(module));
    scopes[0].parent = original_parent;
    const map = @constCast(&module.semantic.?.scope_maps[wrapper_scope.toIndex()]);
    const exports_map = map.get("exports").?;
    map.putAssumeCapacity("exports", @backingInt(wrapper_ids[1]));
    try std.testing.expect(!runtime_source.validateTarget(module));
    map.putAssumeCapacity("exports", exports_map);
    try std.testing.expect(runtime_source.validateTarget(module));

    const before_nodes = try a.dupe(ast_mod.Node, module.ast.?.nodes.items);
    const before_ids = module.semantic.?.symbol_ids;
    const plan = (try patterns.prepareNodeBufferCapabilityPlan(a, module)) orelse return error.MissingBufferPlan;
    try std.testing.expect(plan.isCurrent(module));
    try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(before_nodes), std.mem.sliceAsBytes(module.ast.?.nodes.items));
    // A removed-node claim cannot consume an actual retained reference.
    const staged_ast = (try plan.cloneForPublication(module, a)).?;
    const staged_live = try @import("../../parser/ast_walk.zig").collectReachableNodeIndices(a, &staged_ast);
    var retained_read: ?NodeIndex = null;
    for (module.semantic.?.references) |reference| {
        if (!reference.flags.read or reference.flags.declare) continue;
        const raw = @backingInt(reference.node_index);
        if (staged_ast.nodes.items[raw].tag != .identifier_reference) continue;
        if (std.mem.indexOfScalar(u32, staged_live, raw) == null) continue;
        retained_read = reference.node_index;
        break;
    }
    const forged_removed = try a.alloc(NodeIndex, plan.removed_nodes.len + 1);
    @memcpy(forged_removed[0..plan.removed_nodes.len], plan.removed_nodes);
    forged_removed[plan.removed_nodes.len] = retained_read orelse return error.MissingRetainedRead;
    var forged_plan = plan;
    forged_plan.removed_nodes = forged_removed;
    try std.testing.expect((try prepass.prepareNodeBufferCapabilityFold(&graph, module, a, &forged_plan)) == null);
    try std.testing.expect(plan.isCurrent(module));

    // An ordinary removed row does not grant dynamic lookup authority.
    var retired_function_nodes: std.AutoHashMapUnmanaged(u32, void) = .empty;
    for (plan.retirements) |function| {
        const nodes = try @import("../../parser/ast_walk.zig").collectReachableNodeIndicesFrom(a, &module.ast.?, function.owner);
        for (nodes) |raw| try retired_function_nodes.put(a, raw, {});
    }
    var ordinary_removed: ?NodeIndex = null;
    for (module.semantic.?.references) |reference| {
        if (reference.flags.declare or retired_function_nodes.contains(@backingInt(reference.node_index))) continue;
        if (std.mem.indexOfScalar(NodeIndex, plan.removed_nodes, reference.node_index) == null) continue;
        const context = module.semantic.?.node_scope_provenance.get(reference.node_index) orelse continue;
        if (context.source_external != null or context.external_import != null or context.with_environment) continue;
        ordinary_removed = reference.node_index;
        break;
    }
    const ordinary_node = ordinary_removed orelse return error.MissingOrdinaryRemovedRead;
    const provenance = &module.semantic.?.node_scope_provenance;
    const original_context = provenance.get(ordinary_node).?;
    var forged_context = original_context;
    forged_context.with_environment = true;
    provenance.getPtr(ordinary_node).?.* = forged_context;
    try std.testing.expect((try prepass.prepareNodeBufferCapabilityFold(&graph, module, a, &plan)) == null);
    provenance.getPtr(ordinary_node).?.* = original_context;
    var allocation_failures: usize = 0;
    var allocation_success = false;
    for (0..1024) |fail_index| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        var scratch = std.heap.ArenaAllocator.init(failing.allocator());
        defer scratch.deinit();
        var retry = prepass.prepareNodeBufferCapabilityFold(&graph, module, scratch.allocator(), &plan) catch |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            allocation_failures += 1;
            try std.testing.expect(plan.isCurrent(module));
            try std.testing.expectEqual(@intFromPtr(before_ids.ptr), @intFromPtr(module.semantic.?.symbol_ids.ptr));
            continue;
        };
        if (retry) |*candidate| candidate.discard() else return error.MissingBufferRetry;
        allocation_success = true;
        break;
    }
    try std.testing.expect(allocation_failures > 0);
    try std.testing.expect(allocation_success);
    try std.testing.expect(plan.isCurrent(module));
    try std.testing.expectEqual(@intFromPtr(before_ids.ptr), @intFromPtr(module.semantic.?.symbol_ids.ptr));
    try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(before_nodes), std.mem.sliceAsBytes(module.ast.?.nodes.items));
    var prepared = (try prepass.prepareNodeBufferCapabilityFold(&graph, module, a, &plan)) orelse return error.MissingBufferPreparation;
    defer prepared.discard();
    try std.testing.expect(plan.isCurrent(module));
    try std.testing.expectEqual(@intFromPtr(before_ids.ptr), @intFromPtr(module.semantic.?.symbol_ids.ptr));
    try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(before_nodes), std.mem.sliceAsBytes(module.ast.?.nodes.items));
    var foreign = module.*;
    try std.testing.expect(!plan.isCurrent(&foreign));
    try std.testing.expect((try plan.cloneForPublication(&foreign, a)) == null);
    try std.testing.expect(prepared.publish(module));
    try std.testing.expect(!plan.isCurrent(module));
    try std.testing.expect(module.prebuilt_stmt_info != null);
    try std.testing.expectEqual(@as(usize, 1), plan.exports.len);
    try std.testing.expect(patterns.foldedNodeBufferExportIsCurrent(module, &module.ast.?, plan.exports[0].statement, plan.exports[0]));
}

test "Buffer actual dependency origin records distinguish host aliases and local require" {
    for (0..5) |variant| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const helpers = @import("../test_helpers.zig");
        const source = if (variant == 3)
            "function require(){return {Buffer:{from:null}}}var buffer=require('buffer');var B=buffer.Buffer;if(B.from&&B.alloc&&B.allocUnsafe&&B.allocUnsafeSlow){module.exports=buffer}else{exports.Buffer=SafeBuffer}function SafeBuffer(){}"
        else if (variant == 4)
            "var buffer=require('node:buffer');var B=buffer.Buffer;if(B.from&&B.alloc&&B.allocUnsafe&&B.allocUnsafeSlow){module.exports=buffer}else{exports.Buffer=SafeBuffer}function SafeBuffer(){}"
        else
            "var buffer=require('buffer');var B=buffer.Buffer;if(B.from&&B.alloc&&B.allocUnsafe&&B.allocUnsafeSlow){module.exports=buffer}else{exports.Buffer=SafeBuffer}function SafeBuffer(){}";
        try helpers.writeFile(tmp.dir, "entry.cjs", source);
        try helpers.writeFile(tmp.dir, "fake.cjs", "function fake(){return fake}fake.Buffer={from:null};module.exports=fake;");
        const entry = try helpers.absPath(&tmp, "entry.cjs");
        defer std.testing.allocator.free(entry);
        const fake = try helpers.absPath(&tmp, "fake.cjs");
        defer std.testing.allocator.free(fake);
        const alias = [_]@import("../types.zig").AliasEntry{.{ .from = "buffer", .to = fake }};
        var cache = @import("../resolve_cache.zig").ResolveCache.init(std.testing.allocator, .{
            .platform = .node,
            .alias = if (variant == 1) &alias else &.{},
            .external_alias = if (variant == 2) &alias else &.{},
        });
        defer cache.deinit();
        var graph = @import("../graph.zig").ModuleGraph.init(std.testing.allocator, &cache);
        defer graph.deinit();
        try graph.build(std.testing.io, &.{entry});
        var modules = graph.modulesIterator();
        var entry_count: usize = 0;
        while (modules.next()) |module| {
            if (!std.mem.eql(u8, module.path, entry)) continue;
            entry_count += 1;
            std.debug.print("BUFFER_DEPENDENCY variant={d} records={d}\n", .{ variant, module.import_records.len });
            for (module.import_records) |record| {
                const target = graph.getModule(record.resolved);
                std.debug.print("BUFFER_DEPENDENCY_RECORD variant={d} kind={s} literal={d} call={d} external={} resolved={d} emit={s} target={s} target_external={}\n", .{
                    variant,                                  @tagName(record.kind),        @backingInt(record.source_node), @backingInt(record.call_node),
                    record.is_external,                       @backingInt(record.resolved), record.externalName(),           if (target) |m| m.path else "none",
                    if (target) |m| m.is_external else false,
                });
                try std.testing.expect(!record.source_node.isNone());
                try std.testing.expect(record.call_node.isNone());
            }
            if (module.ast) |*ast| if (module.semantic) |sem| {
                var object_count: usize = 0;
                for (ast.nodes.items, 0..) |node, raw| {
                    if (node.tag == .variable_declarator and ast.hasExtra(node.data.extra, 2)) {
                        const initializer = ast.readExtraNode(node.data.extra, 2);
                        const binding = ast.readExtraNode(node.data.extra, 0);
                        if (!initializer.isNone() and ast.getNode(initializer).tag == .call_expression) {
                            const sid = sem.symbol_ids[@backingInt(binding)].?;
                            const builtin = patterns.nodeBufferObjectImportIsBuiltin(module, ast, sid);
                            try std.testing.expectEqual(variant == 0 or variant == 1 or variant == 4, builtin);
                            object_count += 1;
                        }
                    }
                    if (node.tag != .call_expression or !ast.hasExtra(node.data.extra, 0)) continue;
                    const callee = ast.readExtraNode(node.data.extra, 0);
                    if (callee.isNone() or @backingInt(callee) >= ast.nodes.items.len or ast.getNode(callee).tag != .identifier_reference) continue;
                    if (!std.mem.eql(u8, ast.identifierNameText(ast.getNode(callee)), "require")) continue;
                    std.debug.print("BUFFER_DEPENDENCY_CALLEE variant={d} call={d} callee={d} sid={any} unresolved={}\n", .{ variant, raw, @backingInt(callee), sem.symbol_ids[@backingInt(callee)], sem.unresolved_references.contains("require") });
                }
                try std.testing.expectEqual(@as(usize, 1), object_count);
                const rescanned = try @import("../import_scanner.zig").extractImportsWithCjsDetectionAndDefines(module.parse_arena.?.allocator(), ast, &.{});
                try std.testing.expectEqual(module.import_records.len, rescanned.records.len);
                for (module.import_records, rescanned.records) |initial, refreshed| {
                    try std.testing.expectEqual(initial.source_node, refreshed.source_node);
                    try std.testing.expect(refreshed.call_node.isNone());
                }
            };
        }
        try std.testing.expectEqual(@as(usize, 1), entry_count);
    }
}

test "Buffer registered domain COW publication rejects foreign data and rolls back OOM" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const helpers = @import("../test_helpers.zig");
    try helpers.writeFile(tmp.dir, "entry.cjs", sources[0]);
    const entry = try helpers.absPath(&tmp, "entry.cjs");
    defer std.testing.allocator.free(entry);
    var cache = @import("../resolve_cache.zig").ResolveCache.init(std.testing.allocator, .{ .platform = .node });
    defer cache.deinit();
    var graph = @import("../graph.zig").ModuleGraph.init(std.testing.allocator, &cache);
    defer graph.deinit();
    try graph.build(std.testing.io, &.{entry});
    const module = @constCast(graph.getModule(@fromBackingInt(@as(u32, 0))).?);
    const registration = @import("../../semantic/output_runtime_registration.zig");
    var warmup_publications: usize = 0;
    while (graph.output_runtime_registry.backings.available >= 8 and warmup_publications < 8) : (warmup_publications += 1) {
        var warm_candidate = module.*;
        warm_candidate.ast = try ast_mod.Ast.cloneForTransformer(&module.ast.?, a);
        var warm_editor = try module.semantic.?.beginEdit(a, &warm_candidate.ast.?);
        warm_candidate.semantic.?.applyEdit(try warm_editor.finish());
        if (warm_candidate.transform_cache) |*cached| cached.symbol_ids = warm_candidate.semantic.?.symbol_ids;
        const warm_prepared = (try registration.preparePublication(a, &graph, module, &warm_candidate)) orelse return error.MissingWarmDomain;
        try std.testing.expect(warm_prepared.isCurrent());
        module.* = warm_candidate;
        warm_prepared.publishAssumePrepared();
    }
    try std.testing.expect(graph.output_runtime_registry.backings.available < 8);
    const before = graph.output_runtime_registry.lookup(module) orelse return error.MissingRuntimeDomain;
    const original_ids = module.semantic.?.symbol_ids;
    const original_nodes = module.ast.?.nodes.items;
    const original_owner = module.semantic.?.owner_token;
    var candidate = module.*;
    candidate.ast = try ast_mod.Ast.cloneForTransformer(&module.ast.?, a);
    var editor = try module.semantic.?.beginEdit(a, &candidate.ast.?);
    candidate.semantic.?.applyEdit(try editor.finish());
    if (candidate.transform_cache) |*cached| cached.symbol_ids = candidate.semantic.?.symbol_ids;
    var foreign = candidate;
    foreign.semantic.?.owner_token = .unassigned;
    try std.testing.expect((try registration.preparePublication(a, &graph, module, &foreign)) == null);
    try std.testing.expect(std.meta.eql(before, graph.output_runtime_registry.lookup(module).?));

    // Natural preceding COW publications use the existing spare capacity.
    // Fault the next real growth, not an assumed allocation at the first call.
    const old_backing_count = graph.output_runtime_registry.backings.count();
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const real_allocator = graph.allocator;
    graph.allocator = failing.allocator();
    const failed = registration.preparePublication(a, &graph, module, &candidate);
    graph.allocator = real_allocator;
    try std.testing.expectError(error.OutOfMemory, failed);
    try std.testing.expect(failing.has_induced_failure);
    try std.testing.expectEqual(old_backing_count, graph.output_runtime_registry.backings.count());
    try std.testing.expect(std.meta.eql(before, graph.output_runtime_registry.lookup(module).?));
    try std.testing.expectEqual(@intFromPtr(original_ids.ptr), @intFromPtr(module.semantic.?.symbol_ids.ptr));
    try std.testing.expectEqual(@intFromPtr(original_nodes.ptr), @intFromPtr(module.ast.?.nodes.items.ptr));
    try std.testing.expectEqual(original_owner, module.semantic.?.owner_token);

    const prepared = (try registration.preparePublication(a, &graph, module, &candidate)) orelse return error.MissingPreparedDomain;
    try std.testing.expect(prepared.isCurrent());
    try std.testing.expect(std.meta.eql(before, graph.output_runtime_registry.lookup(module).?));
    module.* = candidate;
    prepared.publishAssumePrepared();
    const after = graph.output_runtime_registry.lookup(module) orelse return error.MissingPublishedDomain;
    try std.testing.expect(after.matches(module));
    try std.testing.expect(!std.meta.eql(before, after));
    try std.testing.expectEqual(original_owner, after.owner);
    try std.testing.expect(!prepared.isCurrent());
    std.debug.print("BUFFER_REGISTERED_DOMAIN warmup_publications={d} real_capacity_oom=1 source_unchanged=1 retry_publish=1\n", .{warmup_publications});
}

test "Buffer production source plan rejects missing scopes without editing installed data" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const helpers = @import("../test_helpers.zig");
    try helpers.writeFile(tmp.dir, "entry.cjs", sources[0]);
    const entry = try helpers.absPath(&tmp, "entry.cjs");
    defer std.testing.allocator.free(entry);
    var cache = @import("../resolve_cache.zig").ResolveCache.init(std.testing.allocator, .{ .platform = .node });
    defer cache.deinit();
    var graph = @import("../graph.zig").ModuleGraph.init(std.testing.allocator, &cache);
    defer graph.deinit();
    try graph.build(std.testing.io, &.{entry});
    const module = @constCast(graph.getModule(@fromBackingInt(@as(u32, 0))).?);
    try std.testing.expect((try patterns.prepareNodeBufferCapabilityPlan(a, module)) != null);
    const nodes = try a.dupe(ast_mod.Node, module.ast.?.nodes.items);
    const extras = try a.dupe(u32, module.ast.?.extra_data.items);
    const ids = try a.dupe(?u32, module.semantic.?.symbol_ids);
    const rows = try a.dupe(Reference, module.semantic.?.references);
    const scope_before = module.semantic.?.scopes;
    module.semantic.?.scopes = &.{};
    try std.testing.expect((try patterns.prepareNodeBufferCapabilityPlan(a, module)) == null);
    try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(nodes), std.mem.sliceAsBytes(module.ast.?.nodes.items));
    try std.testing.expectEqualSlices(u32, extras, module.ast.?.extra_data.items);
    try std.testing.expectEqualSlices(?u32, ids, module.semantic.?.symbol_ids);
    try std.testing.expectEqualSlices(Reference, rows, module.semantic.?.references);
    try std.testing.expectEqual(@as(usize, 0), module.semantic.?.scopes.len);
    module.semantic.?.scopes = scope_before;
    try std.testing.expect((try patterns.prepareNodeBufferCapabilityPlan(a, module)) != null);
}

test "Buffer runtime coverage proof consumes actual registered binding roles only" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const helpers = @import("../test_helpers.zig");
    try helpers.writeFile(tmp.dir, "entry.cjs", sources[0]);
    const entry = try helpers.absPath(&tmp, "entry.cjs");
    defer std.testing.allocator.free(entry);
    var cache = @import("../resolve_cache.zig").ResolveCache.init(std.testing.allocator, .{ .platform = .node });
    defer cache.deinit();
    var graph = @import("../graph.zig").ModuleGraph.init(std.testing.allocator, &cache);
    defer graph.deinit();
    try graph.build(std.testing.io, &.{entry});
    const module = @constCast(graph.getModule(@fromBackingInt(@as(u32, 0))).?);
    const source = (try @import("../../semantic/output_runtime_witness.zig").capture(a, &graph, module)) orelse return error.MissingRuntimeSource;
    const coverage = @import("../../semantic/output_runtime_coverage.zig");
    const proof = coverage.forTarget(.{ .source = &source, .module = module }) orelse return error.MissingRuntimeCoverageProof;
    for (source.entries) |item| try std.testing.expect(proof.hasOutputBinding(@backingInt(item.symbol)));
    try std.testing.expect(!proof.hasOutputBinding(@intCast(module.semantic.?.symbols.items.len)));
    try std.testing.expectEqual(module.index, proof.moduleIndex().?);
    try std.testing.expectEqual(source.wrapper.?.scope, proof.wrapper().?.scope);
    const frames = @import("../../semantic/scope_frame_history.zig");
    const wrapper = proof.wrapper().?;
    const frame_index = try frames.validateAndIndex(a, &module.ast.?, module.semantic.?.scopes, &module.semantic.?.scope_owner_map, &module.semantic.?.scope_history, .{
        .module_index = @backingInt(proof.moduleIndex().?),
        .wrapper_scope = wrapper.scope,
        .program_scope = @fromBackingInt(@as(u32, 0)),
    });
    try std.testing.expect(frame_index.valid);
    try std.testing.expect(module.semantic.?.scope_history.events.len >= 2);
    const no_permission = try frames.validateAndIndex(a, &module.ast.?, module.semantic.?.scopes, &module.semantic.?.scope_owner_map, &module.semantic.?.scope_history, null);
    try std.testing.expect(!no_permission.valid);
    var foreign_context = proof.context;
    foreign_context.references = try a.dupe(Reference, foreign_context.references);
    try std.testing.expect(coverage.prepare(proof.target, foreign_context) == null);
    var forged = proof;
    forged.context = foreign_context;
    try std.testing.expect(!forged.hasOutputBinding(@backingInt(source.entries[0].symbol)));
    try std.testing.expect(forged.wrapper() == null);
    const before = module.semantic.?.symbols.items[@backingInt(source.entries[0].symbol)];
    module.semantic.?.symbols.items[@backingInt(source.entries[0].symbol)].synthetic_kind = null;
    try std.testing.expect(!proof.hasOutputBinding(@backingInt(source.entries[0].symbol)));
    module.semantic.?.symbols.items[@backingInt(source.entries[0].symbol)] = before;
    try std.testing.expect(proof.hasOutputBinding(@backingInt(source.entries[0].symbol)));
}

test "Buffer CJS actual initial external origins become same leaf callback references" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const helpers = @import("../test_helpers.zig");
    const source = "exports.answer=7;module.exports=exports;function f(){module.exports=9}exports++;module=exports;";
    try helpers.writeFile(tmp.dir, "entry.cjs", source);
    const path = try helpers.absPath(&tmp, "entry.cjs");
    defer std.testing.allocator.free(path);
    var cache = @import("../resolve_cache.zig").ResolveCache.init(std.testing.allocator, .{ .platform = .node });
    defer cache.deinit();
    var graph = @import("../graph.zig").ModuleGraph.init(std.testing.allocator, &cache);
    defer graph.deinit();
    const index = try graph.addModule(std.testing.io, path);
    const module = @constCast(graph.getModule(index).?);
    module.parse_arena = @import("../module.zig").createParseArena(std.testing.allocator) orelse return error.OutOfMemory;
    const a = module.parse_arena.?.allocator();
    var scanner = try @import("../../lexer/scanner.zig").Scanner.init(a, source);
    var parser = @import("../../parser/parser.zig").Parser.init(a, &scanner);
    parser.configureFromExtension(".cjs");
    _ = try parser.parse();
    try std.testing.expectEqual(@as(usize, 0), parser.errors.items.len);
    var analyzer = @import("../../semantic/analyzer.zig").SemanticAnalyzer.init(a, &parser.ast);
    analyzer.is_module = false;
    analyzer.enable_source_external_origins = true;
    analyzer.collect_unresolved_reference_nodes = true;
    analyzer.enable_exact_declaration_anchors = true;
    try analyzer.analyze();
    module.ast = parser.ast;
    module.wrap_kind = .cjs;
    module.semantic = .{
        .symbols = analyzer.symbols,
        .scopes = analyzer.scopes.items,
        .scope_maps = analyzer.scope_maps.items,
        .scope_owner_map = analyzer.scope_owner_map,
        .symbol_ids = analyzer.symbol_ids.items,
        .references = analyzer.references.items,
        .exported_names = analyzer.exported_names,
        .unresolved_references = analyzer.unresolved_references,
        .node_scope_provenance = analyzer.node_scope_provenance,
        .source_owned_retirements = analyzer.source_owned_retirements,
        .scope_history = analyzer.scope_history,
    };
    const before = module.semantic.?;
    const contexts = (try @import("../../semantic/output_runtime_witness.zig").captureReferenceContexts(a, &module.ast.?, @fromBackingInt(@as(u32, @intCast(module.ast.?.nodes.items.len - 1))), before.scopes, &before.scope_owner_map)) orelse return error.MissingReferenceContexts;
    var count: usize = 0;
    var origins = before.node_scope_provenance.iterator();
    while (origins.next()) |item| {
        if (item.value_ptr.source_external == null) continue;
        count += 1;
        try std.testing.expectEqual(@as(?u32, null), before.symbol_ids[@backingInt(item.key_ptr.*)]);
    }
    try std.testing.expect(count > 1);
    // The structural reference walk is independent of origin-map publication.
    try std.testing.expectEqual(contexts.len, count);
    try graph.registerWrapperSymbols();
    const after = &module.semantic.?;
    var consumed: usize = 0;
    origins = before.node_scope_provenance.iterator();
    while (origins.next()) |item| {
        const origin = item.value_ptr.source_external orelse continue;
        const node = item.key_ptr.*;
        const name = module.ast.?.getText(origin.name);
        const sid = if (std.mem.eql(u8, name, "module")) module.cjs_wrapper_module_parameter_symbol.? else if (std.mem.eql(u8, name, "exports")) module.cjs_wrapper_exports_parameter_symbol.? else return error.UnexpectedExternalName;
        try std.testing.expectEqual(@as(?u32, @backingInt(sid)), after.symbol_ids[@backingInt(node)]);
        try std.testing.expect(after.node_scope_provenance.get(node).?.source_external == null);
        try std.testing.expect(before.node_scope_provenance.get(node).?.source_external != null);
        var actual_rows: usize = 0;
        for (after.references) |row| {
            if (row.node_index != node) continue;
            actual_rows += 1;
            try std.testing.expectEqual(sid, row.symbol_id);
            var actual_contexts: usize = 0;
            for (contexts) |context| {
                if (context.node != node) continue;
                actual_contexts += 1;
                try std.testing.expectEqual(context.scope, row.scope_id);
                try std.testing.expectEqualDeep(context.flags, row.flags);
                try std.testing.expectEqual(context.stmt_idx, row.stmt_idx);
                try std.testing.expectEqual(context.scope_stmt_idx, row.scope_stmt_idx);
            }
            try std.testing.expectEqual(@as(usize, 1), actual_contexts);
        }
        try std.testing.expectEqual(@as(usize, 1), actual_rows);
        consumed += 1;
    }
    try std.testing.expectEqual(count, consumed);
    const runtime = (try @import("../../semantic/output_runtime_witness.zig").capture(a, &graph, module)) orelse return error.MissingRuntimeSource;
    const proof = @import("../../semantic/output_runtime_coverage.zig").forTarget(.{ .source = &runtime, .module = module }) orelse return error.MissingRuntimeCoverageProof;
    const wrapper = proof.wrapper().?;
    const program_scope: ScopeId = @fromBackingInt(after.scope_owner_map.get(@backingInt(wrapper.program)).?);
    const history = @import("../../semantic/scope_frame_history.zig");
    const checked = try history.validateAndIndex(a, &module.ast.?, after.scopes, &after.scope_owner_map, &after.scope_history, .{ .module_index = @backingInt(index), .program_scope = program_scope, .wrapper_scope = wrapper.scope });
    try std.testing.expect(checked.valid);
    const rejected = try history.validateAndIndex(a, &module.ast.?, after.scopes, &after.scope_owner_map, &after.scope_history, .{ .module_index = @backingInt(index) + 1, .program_scope = program_scope, .wrapper_scope = wrapper.scope });
    try std.testing.expect(!rejected.valid);
}
