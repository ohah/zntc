//! First analysis and one local naming domain for an independent output file.
//! This never analyzes or copies a user module's AST.
const std = @import("std");
const ast_mod = @import("../parser/ast.zig");
const Analyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer;
const Codegen = @import("../codegen/codegen.zig").Codegen;
const Owner = @import("codegen_output_domain.zig");
const NodeIndex = ast_mod.NodeIndex;
const SymbolId = @import("../semantic/symbol.zig").SymbolId;
const ScopeId = @import("../semantic/scope.zig").ScopeId;

pub const Local = struct {
    owner: Owner.Owner,
    binding: NodeIndex,
    symbol: SymbolId,
    scope: ScopeId,
    function_owner: NodeIndex,
    final_name: []const u8,
};

pub const Function = struct { owner: Owner.Owner, node: NodeIndex, scope: ScopeId };
const Literal = struct { owner: Owner.Owner, node: NodeIndex, span: @import("../lexer/token.zig").Span, role: enum { native_helper_path, provider_path }, quoted: []const u8 };

pub const Program = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    owner: Owner.Owner,
    ast: ast_mod.Ast,
    root: NodeIndex,
    analysis: Analyzer,
    locals: []Local,
    functions: []Function,
    names: std.AutoHashMapUnmanaged(u32, []const u8),
    literals: std.AutoHashMapUnmanaged(u32, []const u8),
    literal_roles: []Literal,

    pub fn create(allocator: std.mem.Allocator, source: []const u8) !*Program {
        const self = try allocator.create(Program);
        errdefer allocator.destroy(self);
        self.* = .{ .allocator = allocator, .arena = .init(allocator), .owner = Owner.newOwner(), .ast = undefined, .root = .none, .analysis = undefined, .locals = &.{}, .functions = &.{}, .names = .empty, .literals = .empty, .literal_roles = &.{} };
        errdefer self.arena.deinit();
        if (self.owner == .unassigned) return error.InvalidCompilerOutputProgram;
        const a = self.arena.allocator();
        const bytes = try a.dupe(u8, source);
        var scanner = try @import("../lexer/scanner.zig").Scanner.init(a, bytes);
        var parser = @import("../parser/parser.zig").Parser.init(a, &scanner);
        self.root = try parser.parse();
        if (parser.errors.items.len != 0) return error.InvalidCompilerOutputProgram;
        self.ast = parser.ast;
        self.analysis = Analyzer.init(a, &self.ast);
        self.analysis.enable_exact_declaration_anchors = true;
        self.analysis.collect_unresolved_reference_nodes = true;
        self.analysis.enable_source_external_origins = true;
        try self.analysis.analyze();
        if (self.analysis.errors.items.len != 0) return error.InvalidCompilerOutputProgram;
        // Reserve actual analyzed binding and unresolved-read StringValues
        // once across this independent program. Reservation never selects a
        // SymbolId; the function's physical parameter edge below does that.
        var reservations: @import("../transformer/es_helpers.zig").PrivateNameAllocator = .{ .allocator = a };
        for (self.analysis.scope_maps.items) |map| {
            var keys = map.keyIterator();
            while (keys.next()) |name| try reservations.reserved.put(a, try @import("../lexer/scanner.zig").Scanner.decodeIdentifierEscapesAlloc(a, name.*), {});
        }
        var globals = self.analysis.unresolved_references.keyIterator();
        while (globals.next()) |name| try reservations.reserved.put(a, try @import("../lexer/scanner.zig").Scanner.decodeIdentifierEscapesAlloc(a, name.*), {});
        var locals: std.ArrayListUnmanaged(Local) = .empty;
        var functions: std.ArrayListUnmanaged(Function) = .empty;
        // Parameters are selected from actual function child edges, before any
        // output name is chosen. No preferred spelling selects a SymbolId.
        for (self.ast.nodes.items, 0..) |node, raw| {
            if (node.tag != .function_expression) continue;
            const function_owner: NodeIndex = @fromBackingInt(@intCast(raw));
            const scope_raw = self.analysis.scope_owner_map.get(@intCast(raw)) orelse return error.InvalidCompilerOutputProgram;
            try functions.append(a, .{ .owner = self.owner, .node = function_owner, .scope = @fromBackingInt(scope_raw) });
            var params = self.ast.iterateExtraList(self.ast.functionParamsList(node));
            while (params.next()) |binding| {
                if (self.ast.getNode(binding).tag != .binding_identifier) return error.InvalidCompilerOutputProgram;
                const sid = self.analysis.symbol_ids.items[@backingInt(binding)] orelse return error.InvalidCompilerOutputProgram;
                const symbol = self.analysis.symbols.items[sid];
                if (symbol.kind != .parameter or @backingInt(symbol.scope_id) != scope_raw) return error.InvalidCompilerOutputProgram;
                const preferred = try std.fmt.allocPrint(a, "__zntcArtifact{d}", .{sid});
                const name = if (self.analysis.scopes.items[scope_raw].blocksMangling())
                    try @import("../lexer/scanner.zig").Scanner.decodeIdentifierEscapesAlloc(a, self.ast.identifierNameText(self.ast.getNode(binding)))
                else
                    try reservations.makeUniqueName(preferred);
                try self.names.put(a, sid, name);
                try locals.append(a, .{ .owner = self.owner, .binding = binding, .symbol = @fromBackingInt(sid), .scope = symbol.scope_id, .function_owner = function_owner, .final_name = name });
            }
        }
        self.locals = locals.items;
        self.functions = functions.items;
        try self.validate();
        return self;
    }

    pub fn validate(self: *const Program) !void {
        if (self.owner == .unassigned or self.root.isNone() or self.ast.getNode(self.root).tag != .program) return error.InvalidCompilerOutputProgram;
        for (self.literal_roles) |literal| {
            if (literal.owner != self.owner or @backingInt(literal.node) >= self.ast.nodes.items.len) return error.InvalidCompilerOutputProgram;
            const node = self.ast.getNode(literal.node);
            if (node.tag != .string_literal or !std.meta.eql(node.data.string_ref, literal.span)) return error.InvalidCompilerOutputProgram;
            const selected = self.literals.get(@backingInt(literal.node)) orelse return error.InvalidCompilerOutputProgram;
            if (selected.ptr != literal.quoted.ptr or !std.mem.eql(u8, selected, literal.quoted)) return error.InvalidCompilerOutputProgram;
        }
        for (self.functions) |function| {
            const raw = @backingInt(function.node);
            if (function.owner != self.owner or raw >= self.ast.nodes.items.len or
                self.ast.getNode(function.node).tag != .function_expression or function.scope.isNone() or
                @backingInt(function.scope) >= self.analysis.scopes.items.len or
                self.analysis.scope_owner_map.get(raw) != @as(?u32, @backingInt(function.scope))) return error.InvalidCompilerOutputProgram;
        }
        for (self.locals) |local| {
            const raw = @backingInt(local.binding);
            const sid = @backingInt(local.symbol);
            if (local.owner != self.owner or raw >= self.ast.nodes.items.len or raw >= self.analysis.symbol_ids.items.len or sid >= self.analysis.symbols.items.len or
                self.ast.getNode(local.binding).tag != .binding_identifier or self.analysis.symbol_ids.items[raw] != sid or
                self.analysis.symbols.items[sid].kind != .parameter or self.analysis.symbols.items[sid].scope_id != local.scope or
                self.analysis.scope_owner_map.get(@backingInt(local.function_owner)) != @as(?u32, @backingInt(local.scope))) return error.InvalidCompilerOutputProgram;
            if (self.analysis.scopes.items[@backingInt(local.scope)].blocksMangling() and
                !@import("../lexer/scanner.zig").Scanner.identifierNamesEqual(local.final_name, self.ast.identifierNameText(self.ast.getNode(local.binding)))) return error.InvalidCompilerOutputProgram;
            const selected = self.names.get(sid) orelse return error.InvalidCompilerOutputProgram;
            if (selected.ptr != local.final_name.ptr or !std.mem.eql(u8, selected, local.final_name)) return error.InvalidCompilerOutputProgram;
            var params = self.ast.iterateExtraList(self.ast.functionParamsList(self.ast.getNode(local.function_owner)));
            var found: usize = 0;
            while (params.next()) |binding| if (binding == local.binding) {
                found += 1;
            };
            if (found != 1) return error.InvalidCompilerOutputProgram;
        }
    }

    pub fn hostExportValue(self: *const Program) !NodeIndex {
        try self.validate();
        var statements = self.ast.iterateExtraList(self.ast.getNode(self.root).data.list);
        const statement = statements.next() orelse return error.InvalidCompilerOutputProgram;
        if (statements.next() != null or self.ast.getNode(statement).tag != .expression_statement) return error.InvalidCompilerOutputProgram;
        const assignment = self.ast.getNode(self.ast.getNode(statement).data.unary.operand);
        if (assignment.tag != .assignment_expression) return error.InvalidCompilerOutputProgram;
        const target = self.ast.getNode(assignment.data.binary.left);
        if (target.tag != .static_member_expression or target.data.extra > self.ast.extra_data.items.len or
            3 > self.ast.extra_data.items.len - target.data.extra or self.ast.readExtra(target.data.extra, 2) != 0) return error.InvalidCompilerOutputProgram;
        const host_node = self.ast.readExtraNode(target.data.extra, 0);
        const host = self.ast.getNode(host_node);
        const key = self.ast.getNode(self.ast.readExtraNode(target.data.extra, 1));
        if (host.tag != .identifier_reference or !std.mem.eql(u8, self.ast.identifierNameText(host), "module") or
            !std.mem.eql(u8, self.ast.identifierNameText(key), "exports") or
            self.analysis.symbol_ids.items[@backingInt(host_node)] != null) return error.InvalidCompilerOutputProgram;
        return assignment.data.binary.right;
    }

    pub fn bindLiteral(self: *Program, role: @FieldType(Literal, "role"), node: NodeIndex, quoted: []const u8) !void {
        if (@backingInt(node) >= self.ast.nodes.items.len or self.ast.getNode(node).tag != .string_literal or
            self.literals.contains(@backingInt(node))) return error.InvalidCompilerOutputProgram;
        for (self.literal_roles) |known| if (known.role == role) return error.InvalidCompilerOutputProgram;
        const a = self.arena.allocator();
        const owned = try a.dupe(u8, quoted);
        var roles: std.ArrayListUnmanaged(Literal) = .fromOwnedSlice(self.literal_roles);
        try roles.append(a, .{ .owner = self.owner, .node = node, .span = self.ast.getNode(node).data.string_ref, .role = role, .quoted = owned });
        try self.literals.put(a, @backingInt(node), owned);
        self.literal_roles = roles.items;
    }

    pub fn emitValue(self: *Program, allocator: std.mem.Allocator) ![]const u8 {
        const value = try self.hostExportValue();
        var codegen = Codegen.initWithOptions(self.arena.allocator(), &self.ast, .{
            .semantic_symbol_ids = self.analysis.symbol_ids.items,
            .semantic_symbols = self.analysis.symbols.items,
            .semantic_scope_maps = self.analysis.scope_maps.items,
            .semantic_symbol_name_overrides = &self.names,
            .compiler_literal_overrides = &self.literals,
        });
        defer codegen.deinit();
        try codegen.emitExpr(value, .comma, .{});
        return allocator.dupe(u8, codegen.buf.items);
    }

    pub fn emit(self: *Program, allocator: std.mem.Allocator) ![]const u8 {
        try self.validate();
        var codegen = Codegen.initWithOptions(self.arena.allocator(), &self.ast, .{
            .semantic_symbol_ids = self.analysis.symbol_ids.items,
            .semantic_symbols = self.analysis.symbols.items,
            .semantic_scope_maps = self.analysis.scope_maps.items,
            .semantic_symbol_name_overrides = &self.names,
            .compiler_literal_overrides = &self.literals,
        });
        defer codegen.deinit();
        return allocator.dupe(u8, try codegen.generate(self.root));
    }

    pub fn destroy(self: *Program) void {
        const allocator = self.allocator;
        self.arena.deinit();
        allocator.destroy(self);
    }
};

test "public entry independent program binds exact local roles and one cold warm name table" {
    const a = std.testing.allocator;
    const source = "module.exports=(function(implementation){return implementation['default'];})(require('./body.js'));";
    const cold = try Program.create(a, source);
    defer cold.destroy();
    const warm = try Program.create(a, source);
    defer warm.destroy();
    try std.testing.expect(cold.owner != warm.owner);
    try std.testing.expectEqual(@as(usize, 1), cold.locals.len);
    const first = try cold.emit(a);
    defer a.free(first);
    const second = try warm.emit(a);
    defer a.free(second);
    try std.testing.expectEqualStrings(first, second);
    const valid = cold.locals[0];
    const poison = &cold.locals[0];
    poison.owner = warm.owner;
    try std.testing.expectError(error.InvalidCompilerOutputProgram, cold.validate());
    poison.* = valid;
    poison.symbol = .none;
    try std.testing.expectError(error.InvalidCompilerOutputProgram, cold.validate());
    poison.* = valid;
    poison.scope = .none;
    try std.testing.expectError(error.InvalidCompilerOutputProgram, cold.validate());
    poison.* = valid;
    poison.binding = cold.root;
    try std.testing.expectError(error.InvalidCompilerOutputProgram, cold.validate());
    poison.* = valid;
    poison.function_owner = cold.root;
    try std.testing.expectError(error.InvalidCompilerOutputProgram, cold.validate());
    poison.* = valid;
    poison.final_name = "foreign";
    try std.testing.expectError(error.InvalidCompilerOutputProgram, cold.validate());
    poison.* = valid;
    try cold.validate();
}

fn allocationProbe(a: std.mem.Allocator) !void {
    const program = try Program.create(a, "module.exports=require('./body.js').then(function(namespace){return namespace['default'];});");
    defer program.destroy();
    const code = try program.emit(a);
    defer a.free(code);
    try std.testing.expect(program.locals.len == 1);
}

test "public entry independent program first analysis and emission allocation failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationProbe, .{});
}

test "independent compiler output names reserve actual globals bindings and dynamic scopes" {
    const a = std.testing.allocator;
    var fixture_arena = std.heap.ArenaAllocator.init(a);
    defer fixture_arena.deinit();
    const fixtures = fixture_arena.allocator();
    const probe = try Program.create(a, "module.exports=function(x){return x};");
    defer probe.destroy();
    const sid = probe.locals[0].symbol;
    const preferred = try std.fmt.allocPrint(a, "__zntcArtifact{d}", .{@backingInt(sid)});
    defer a.free(preferred);
    const escaped = try std.fmt.allocPrint(a, "__zntcArtif\\u0061ct{d}", .{@backingInt(sid)});
    defer a.free(escaped);
    const cases = [_]struct { source: []const u8, dynamic: bool = false, expected: []const u8 }{
        .{ .source = try std.fmt.allocPrint(fixtures, "module.exports=function(x){{return[x,{s}]}};", .{preferred}), .expected = "[42,9]\n" },
        .{ .source = try std.fmt.allocPrint(fixtures, "module.exports=function(x){{var {s}=9;return[x,{s}]}};", .{ preferred, preferred }), .expected = "[42,9]\n" },
        .{ .source = try std.fmt.allocPrint(fixtures, "module.exports=function(x){{return[x,{s}]}};", .{escaped}), .expected = "[42,9]\n" },
        .{ .source = try std.fmt.allocPrint(fixtures, "module.exports=function(x){{var {s}=9;return[x,{s}]}};", .{ escaped, escaped }), .expected = "[42,9]\n" },
        .{ .source = try fixtures.dupe(u8, "module.exports=function(x){return[eval('x'),x]};"), .dynamic = true, .expected = "[42,42]\n" },
        .{ .source = try fixtures.dupe(u8, "module.exports=function(x){with({value:9}){return[x,value]}};"), .dynamic = true, .expected = "[42,9]\n" },
    };
    const prefix = try std.fmt.allocPrint(a, "globalThis[{f}]=9;", .{std.json.fmt(preferred, .{})});
    defer a.free(prefix);
    for (cases) |case| {
        const cold = try Program.create(a, case.source);
        defer cold.destroy();
        const warm = try Program.create(a, case.source);
        defer warm.destroy();
        try std.testing.expect(cold.owner != warm.owner);
        try std.testing.expectEqual(sid, cold.locals[0].symbol);
        if (case.dynamic) {
            try std.testing.expectEqualStrings("x", cold.locals[0].final_name);
            const saved = cold.locals[0];
            const original_name = cold.names.get(@backingInt(saved.symbol)).?;
            cold.locals[0].final_name = "foreign_dynamic_parameter";
            try cold.names.put(cold.arena.allocator(), @backingInt(saved.symbol), cold.locals[0].final_name);
            try std.testing.expectError(error.InvalidCompilerOutputProgram, cold.validate());
            cold.locals[0] = saved;
            try cold.names.put(cold.arena.allocator(), @backingInt(saved.symbol), original_name);
            try cold.validate();
        } else try std.testing.expect(!std.mem.eql(u8, preferred, cold.locals[0].final_name));
        const first = try cold.emit(a);
        defer a.free(first);
        const second = try warm.emit(a);
        defer a.free(second);
        try std.testing.expectEqualStrings(first, second);
        const observe = "console.log(JSON.stringify(module.exports(42)));";
        const native_source = try std.fmt.allocPrint(a, "{s}{s}{s}", .{ prefix, case.source, observe });
        defer a.free(native_source);
        const actual_source = try std.fmt.allocPrint(a, "{s}{s}{s}", .{ prefix, first, observe });
        defer a.free(actual_source);
        const native = try std.process.run(a, std.testing.io, .{ .argv = &.{ "node", "-e", native_source } });
        defer a.free(native.stdout);
        defer a.free(native.stderr);
        const actual = try std.process.run(a, std.testing.io, .{ .argv = &.{ "node", "-e", actual_source } });
        defer a.free(actual.stdout);
        defer a.free(actual.stderr);
        if (actual.term != .exited or actual.term.exited != 0 or !std.mem.eql(u8, native.stdout, actual.stdout))
            std.debug.print("independent compiler name source={s} emitted={s} native={s} actual={s} stderr={s}\n", .{ case.source, first, native.stdout, actual.stdout, actual.stderr });
        try std.testing.expect(native.term == .exited and native.term.exited == 0);
        try std.testing.expectEqualStrings(case.expected, native.stdout);
        try std.testing.expect(actual.term == .exited and actual.term.exited == 0);
        try std.testing.expectEqualStrings(native.stdout, actual.stdout);
        try std.testing.expectEqualStrings(native.stderr, actual.stderr);
    }
}
