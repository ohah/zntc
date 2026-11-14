//! Independent first-analysis shell for a synchronous module environment.
//! The Source body stays emitted bytes from its original AST/name domain.
const std = @import("std");
const ast = @import("../parser/ast.zig");
const Output = @import("compiler_output_program.zig");
const Owner = @import("codegen_output_domain.zig").Owner;
const Insertions = @import("../codegen/compiler_statement_insertions.zig");
const Codegen = @import("../codegen/codegen.zig").Codegen;
const NodeIndex = ast.NodeIndex;
const Error = error{InvalidSynchronousModuleWrapperProgram};
const template = "module.exports=(function*(environment){\"use strict\";;\"BODY\";});";

pub const Program = struct {
    allocator: std.mem.Allocator,
    program: *Output.Program,
    owner: Owner,
    domain: *const ast.Ast,
    source_bytes: []const u8,
    source_hash: u64,
    function: Output.Function,
    environment: Output.Local,
    body: NodeIndex,
    directive: NodeIndex,
    directive_snapshot: ast.Node,
    separator: NodeIndex,
    separator_snapshot: ast.Node,
    entries: [1]Insertions.Entry,
    insertions: Insertions.Set,
    reserved_foreign: []const []const u8,
    body_bytes: []const u8 = "",

    /// The caller supplies whole-Source, unresolved and selected Phase B names.
    /// Those names exclude spellings only; the actual parameter edge selects SID.
    pub fn create(allocator: std.mem.Allocator, foreign_final_names: []const []const u8) !*Program {
        const output = try Output.Program.create(allocator, template);
        errdefer output.destroy();
        const self = try allocator.create(Program);
        errdefer allocator.destroy(self);
        const a = output.arena.allocator();
        const value = unwrap(&output.ast, try output.hostExportValue());
        if (output.functions.len != 1 or output.locals.len != 1 or output.functions[0].node != value)
            return error.InvalidSynchronousModuleWrapperProgram;
        const function = output.functions[0];
        const fn_node = output.ast.getNode(value);
        if (fn_node.tag != .function_expression) return error.InvalidSynchronousModuleWrapperProgram;
        const body = output.ast.readExtraNode(fn_node.data.extra, ast.FunctionExtra.body);
        const block = output.ast.getNode(body);
        if (block.tag != .block_statement or block.data.list.len != 3) return error.InvalidSynchronousModuleWrapperProgram;
        const directive: NodeIndex = @fromBackingInt(output.ast.extra_data.items[block.data.list.start]);
        const directive_node = output.ast.getNode(directive);
        if (directive_node.tag != .directive) return error.InvalidSynchronousModuleWrapperProgram;
        const separator: NodeIndex = @fromBackingInt(output.ast.extra_data.items[block.data.list.start + 1]);
        const separator_node = output.ast.getNode(separator);
        if (separator_node.tag != .empty_statement) return error.InvalidSynchronousModuleWrapperProgram;
        const statement: NodeIndex = @fromBackingInt(output.ast.extra_data.items[block.data.list.start + 2]);
        const statement_node = output.ast.getNode(statement);
        if (statement_node.tag != .expression_statement) return error.InvalidSynchronousModuleWrapperProgram;
        const expression = statement_node.data.unary.operand;
        const expression_node = output.ast.getNode(expression);
        if (expression_node.tag != .string_literal) return error.InvalidSynchronousModuleWrapperProgram;
        var reservations: @import("../transformer/es_helpers.zig").PrivateNameAllocator = .{ .allocator = a };
        const Scanner = @import("../lexer/scanner.zig").Scanner;
        const foreign = try a.alloc([]const u8, foreign_final_names.len);
        for (foreign_final_names, 0..) |name, i| {
            foreign[i] = try Scanner.decodeIdentifierEscapesAlloc(a, name);
            try reservations.reserved.put(a, foreign[i], {});
        }
        for (output.analysis.scope_maps.items) |map| {
            var keys = map.keyIterator();
            while (keys.next()) |name| try reservations.reserved.put(a, try Scanner.decodeIdentifierEscapesAlloc(a, name.*), {});
        }
        var globals = output.analysis.unresolved_references.keyIterator();
        while (globals.next()) |name| try reservations.reserved.put(a, try Scanner.decodeIdentifierEscapesAlloc(a, name.*), {});
        output.locals[0].final_name = try reservations.makeUniqueName("__zntcModuleEnvironment");
        try output.names.put(a, @backingInt(output.locals[0].symbol), output.locals[0].final_name);
        self.* = .{
            .allocator = allocator,
            .program = output,
            .owner = output.owner,
            .domain = &output.ast,
            .source_bytes = output.ast.source,
            .source_hash = std.hash.Wyhash.hash(0, output.ast.source),
            .function = function,
            .environment = output.locals[0],
            .body = body,
            .directive = directive,
            .directive_snapshot = directive_node,
            .separator = separator,
            .separator_snapshot = separator_node,
            .reserved_foreign = foreign,
            .entries = .{.{ .owner = output.owner, .statement = statement, .expression = expression, .statement_snapshot = statement_node, .expression_snapshot = expression_node, .bytes = "" }},
            .insertions = .{ .owner = output.owner, .domain = &output.ast, .entries = &.{} },
        };
        self.insertions.entries = &self.entries;
        try self.validate();
        return self;
    }

    pub fn destroy(self: *Program) void {
        const allocator = self.allocator;
        self.program.destroy();
        allocator.destroy(self);
    }

    fn node(self: *const Program, index: NodeIndex) Error!ast.Node {
        if (index.isNone() or @backingInt(index) >= self.domain.nodes.items.len) return error.InvalidSynchronousModuleWrapperProgram;
        return self.domain.getNode(index);
    }

    pub fn validate(self: *const Program) Error!void {
        if (self.owner == .unassigned or self.owner != self.program.owner or self.domain != &self.program.ast or
            self.function.owner != self.owner or self.program.functions.len != 1 or self.program.locals.len != 1 or
            self.domain.source.ptr != self.source_bytes.ptr or self.domain.source.len != self.source_bytes.len or
            std.hash.Wyhash.hash(0, self.domain.source) != self.source_hash) return error.InvalidSynchronousModuleWrapperProgram;
        const local = self.environment;
        const raw = @backingInt(local.binding);
        const sid = @backingInt(local.symbol);
        if (local.owner != self.owner or local.function_owner != self.function.node or local.scope.isNone() or
            @backingInt(local.scope) >= self.program.analysis.scopes.items.len or raw >= self.program.analysis.symbol_ids.items.len or
            sid >= self.program.analysis.symbols.items.len or (try self.node(local.binding)).tag != .binding_identifier or
            self.program.analysis.symbol_ids.items[raw] != sid) return error.InvalidSynchronousModuleWrapperProgram;
        const symbol = self.program.analysis.symbols.items[sid];
        const actual = self.program.locals[0];
        if (symbol.kind != .parameter or symbol.scope_id != local.scope or symbol.origin_scope != local.scope or
            actual.owner != local.owner or actual.binding != local.binding or actual.symbol != local.symbol or
            actual.scope != local.scope or actual.function_owner != local.function_owner or
            actual.final_name.ptr != local.final_name.ptr or !std.mem.eql(u8, actual.final_name, local.final_name)) return error.InvalidSynchronousModuleWrapperProgram;
        for (self.reserved_foreign) |name| if (std.mem.eql(u8, name, local.final_name)) return error.InvalidSynchronousModuleWrapperProgram;
        self.program.validate() catch return error.InvalidSynchronousModuleWrapperProgram;
        const value = unwrap(self.domain, self.program.hostExportValue() catch return error.InvalidSynchronousModuleWrapperProgram);
        if (value != self.function.node or !std.meta.eql(self.function, self.program.functions[0])) return error.InvalidSynchronousModuleWrapperProgram;
        const function_node = try self.node(value);
        if (function_node.tag != .function_expression or !self.domain.hasExtra(function_node.data.extra, ast.FunctionExtra.flags)) return error.InvalidSynchronousModuleWrapperProgram;
        const flags = self.domain.readExtra(function_node.data.extra, ast.FunctionExtra.flags);
        if (flags & ast.FunctionFlags.is_generator == 0 or flags & ast.FunctionFlags.is_async != 0 or local.scope != self.function.scope)
            return error.InvalidSynchronousModuleWrapperProgram;
        const frame = self.program.analysis.scopes.items[@backingInt(local.scope)];
        if (frame.kind != .function or !frame.is_strict or frame.blocksMangling()) return error.InvalidSynchronousModuleWrapperProgram;
        const params = self.domain.functionParamsList(function_node);
        if (params.len != 1 or params.start >= self.domain.extra_data.items.len or self.domain.extra_data.items[params.start] != raw)
            return error.InvalidSynchronousModuleWrapperProgram;
        var anchors: usize = 0;
        for (self.program.analysis.references.items) |reference| {
            if (reference.symbol_id == local.symbol and reference.scope_id == local.scope and reference.declaration_node_index == local.binding and
                reference.node_index.isNone() and std.meta.eql(reference.flags, @as(@import("../semantic/symbol.zig").ReferenceFlags, .{ .declare = true }))) anchors += 1;
        }
        if (anchors != 1 or self.domain.readExtraNode(function_node.data.extra, ast.FunctionExtra.body) != self.body) return error.InvalidSynchronousModuleWrapperProgram;
        const block = try self.node(self.body);
        if (block.tag != .block_statement or block.data.list.len != 3 or block.data.list.start > self.domain.extra_data.items.len or
            block.data.list.len > self.domain.extra_data.items.len - block.data.list.start or
            self.domain.extra_data.items[block.data.list.start] != @backingInt(self.directive) or
            self.domain.extra_data.items[block.data.list.start + 1] != @backingInt(self.separator) or
            self.domain.extra_data.items[block.data.list.start + 2] != @backingInt(self.entries[0].statement)) return error.InvalidSynchronousModuleWrapperProgram;
        const directive = try self.node(self.directive);
        const separator = try self.node(self.separator);
        if (directive.tag != .directive or self.directive_snapshot.tag != .directive or
            directive.span.start != self.directive_snapshot.span.start or directive.span.end != self.directive_snapshot.span.end or
            separator.tag != .empty_statement or self.separator_snapshot.tag != .empty_statement or
            separator.span.start != self.separator_snapshot.span.start or separator.span.end != self.separator_snapshot.span.end)
            return error.InvalidSynchronousModuleWrapperProgram;
        if (self.insertions.owner != self.owner or self.insertions.domain != self.domain or self.insertions.entries.len != 1 or
            self.insertions.entries.ptr != @as([*]const Insertions.Entry, @ptrCast(&self.entries)) or
            self.entries[0].bytes.ptr != self.body_bytes.ptr or !std.mem.eql(u8, self.entries[0].bytes, self.body_bytes)) return error.InvalidSynchronousModuleWrapperProgram;
        self.insertions.validate(self.domain, self.owner) catch return error.InvalidSynchronousModuleWrapperProgram;
    }

    pub fn environmentLocal(self: *const Program) Error!Output.Local {
        try self.validate();
        return self.environment;
    }

    pub fn emitValueTracked(self: *Program, allocator: std.mem.Allocator, body: []const u8, minify: bool, emitted_at: *?Insertions.Emission) ![]const u8 {
        emitted_at.* = null;
        try self.validate();
        self.entries[0].emitted_at = emitted_at;
        defer self.entries[0].emitted_at = null;
        const bytes = try std.fmt.allocPrint(self.program.arena.allocator(), "{s}\n", .{body});
        self.body_bytes = bytes;
        self.entries[0].bytes = bytes;
        try self.validate();
        var codegen = Codegen.initWithOptions(self.program.arena.allocator(), self.domain, .{
            .semantic_symbol_ids = self.program.analysis.symbol_ids.items,
            .semantic_symbols = self.program.analysis.symbols.items,
            .semantic_scope_maps = self.program.analysis.scope_maps.items,
            .semantic_symbol_name_overrides = &self.program.names,
            .compiler_statement_insertions = &self.insertions,
            .minify_whitespace = minify,
        });
        try codegen.emitExpr(try self.program.hostExportValue(), .comma, .{});
        const result = try allocator.dupe(u8, codegen.buf.items);
        errdefer allocator.free(result);
        const site = emitted_at.* orelse return error.InvalidSynchronousModuleWrapperProgram;
        if (site.owner != self.owner or site.domain != self.domain or site.statement != self.entries[0].statement) return error.InvalidSynchronousModuleWrapperProgram;
        return result;
    }
};

fn unwrap(domain: *const ast.Ast, input: NodeIndex) NodeIndex {
    var current = input;
    var remaining = domain.nodes.items.len;
    while (!current.isNone() and @backingInt(current) < domain.nodes.items.len and remaining != 0) : (remaining -= 1) {
        const item = domain.getNode(current);
        if (item.tag != .parenthesized_expression) break;
        current = item.data.unary.operand;
    }
    return current;
}
