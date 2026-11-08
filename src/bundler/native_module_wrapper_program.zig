//! Independently parsed/analyzed compiler shell for one native module body.
//! User statements remain bytes emitted in their own AST/name domain.
const std = @import("std");
const ast = @import("../parser/ast.zig");
const Output = @import("compiler_output_program.zig");
const Owner = @import("codegen_output_domain.zig").Owner;
const ScopeId = @import("../semantic/scope.zig").ScopeId;
const SymbolId = @import("../semantic/symbol.zig").SymbolId;
const Insertions = @import("../codegen/compiler_statement_insertions.zig");
const Codegen = @import("../codegen/codegen.zig").Codegen;
const NodeIndex = ast.NodeIndex;
const Error = error{InvalidNativeModuleWrapperProgram};

const template = "module.exports=(function*(environment,stack,error,failed){\"use strict\";stack=[];failed=false;try{\"BODY\";}catch(caught){failed=true;error=caught;}finally{yield*environment[1](stack,failed,error);}});";
pub const Role = enum(u2) { environment, stack, error_value, failed };
pub const CatchLocal = struct { local: Output.Local, clause: NodeIndex };

pub const Program = struct {
    allocator: std.mem.Allocator,
    program: *Output.Program,
    owner: Owner,
    domain: *const ast.Ast,
    source_bytes: []const u8,
    source_hash: u64,
    function: Output.Function,
    parameters: [4]Output.Local,
    caught: CatchLocal,
    try_node: NodeIndex,
    try_body: NodeIndex,
    entries: [1]Insertions.Entry,
    insertions: Insertions.Set,
    body_bytes: []const u8 = "",
    reserved_foreign: []const []const u8,

    pub fn create(allocator: std.mem.Allocator, foreign_final_names: []const []const u8) !*Program {
        const output = try Output.Program.create(allocator, template);
        errdefer output.destroy();
        const self = try allocator.create(Program);
        errdefer allocator.destroy(self);
        const a = output.arena.allocator();
        const value = unwrap(&output.ast, try output.hostExportValue());
        if (output.functions.len != 1 or output.locals.len != 4 or output.functions[0].node != value)
            return error.InvalidNativeModuleWrapperProgram;
        const function = output.functions[0];
        const fn_node = output.ast.getNode(value);
        if (fn_node.tag != .function_expression) return error.InvalidNativeModuleWrapperProgram;
        const body = output.ast.readExtraNode(fn_node.data.extra, ast.FunctionExtra.body);
        const body_node = output.ast.getNode(body);
        if (body_node.tag != .block_statement or body_node.data.list.len != 4) return error.InvalidNativeModuleWrapperProgram;
        const try_index: NodeIndex = @fromBackingInt(output.ast.extra_data.items[body_node.data.list.start + 3]);
        const try_node = output.ast.getNode(try_index);
        if (try_node.tag != .try_statement) return error.InvalidNativeModuleWrapperProgram;
        const catch_owner = try_node.data.ternary.b;
        const catch_node = output.ast.getNode(catch_owner);
        if (catch_node.tag != .catch_clause) return error.InvalidNativeModuleWrapperProgram;
        const catch_binding = catch_node.data.binary.left;
        const catch_sid = output.analysis.symbol_ids.items[@backingInt(catch_binding)] orelse return error.InvalidNativeModuleWrapperProgram;
        const catch_scope_raw = output.analysis.scope_owner_map.get(@backingInt(catch_owner)) orelse return error.InvalidNativeModuleWrapperProgram;
        var caught: CatchLocal = .{ .clause = catch_owner, .local = .{
            .owner = output.owner,
            .binding = catch_binding,
            .symbol = @fromBackingInt(catch_sid),
            .scope = @fromBackingInt(catch_scope_raw),
            .function_owner = function.node,
            .final_name = "",
        } };
        var reservations: @import("../transformer/es_helpers.zig").PrivateNameAllocator = .{ .allocator = a };
        const Scanner = @import("../lexer/scanner.zig").Scanner;
        const foreign_owned = try a.alloc([]const u8, foreign_final_names.len);
        for (foreign_final_names, 0..) |name, i| {
            const decoded = try Scanner.decodeIdentifierEscapesAlloc(a, name);
            foreign_owned[i] = decoded;
            try reservations.reserved.put(a, decoded, {});
        }
        for (output.analysis.scope_maps.items) |map| {
            var keys = map.keyIterator();
            while (keys.next()) |name| try reservations.reserved.put(a, try Scanner.decodeIdentifierEscapesAlloc(a, name.*), {});
        }
        var globals = output.analysis.unresolved_references.keyIterator();
        while (globals.next()) |name| try reservations.reserved.put(a, try Scanner.decodeIdentifierEscapesAlloc(a, name.*), {});
        // A preferred name only allocates spelling. Physical parameter edges
        // and their first-analysis SymbolIds selected the roles above.
        const preferred = [_][]const u8{ "__zntcModuleEnvironment", "__zntcModuleStack", "__zntcModuleError", "__zntcModuleFailed" };
        for (output.locals, 0..) |*descriptor, i| {
            const chosen = try reservations.makeUniqueName(preferred[i]);
            descriptor.final_name = chosen;
            try output.names.put(a, @backingInt(descriptor.symbol), chosen);
        }
        caught.local.final_name = try reservations.makeUniqueName("__zntcModuleCaught");
        try output.names.put(a, catch_sid, caught.local.final_name);
        const try_body = try_node.data.ternary.a;
        const try_body_node = output.ast.getNode(try_body);
        if (try_body_node.tag != .block_statement or try_body_node.data.list.len != 1) return error.InvalidNativeModuleWrapperProgram;
        const statement: NodeIndex = @fromBackingInt(output.ast.extra_data.items[try_body_node.data.list.start]);
        const statement_node = output.ast.getNode(statement);
        if (statement_node.tag != .expression_statement) return error.InvalidNativeModuleWrapperProgram;
        const expression = statement_node.data.unary.operand;
        const expression_node = output.ast.getNode(expression);
        if (expression_node.tag != .string_literal) return error.InvalidNativeModuleWrapperProgram;
        self.* = .{
            .source_bytes = output.ast.source,
            .source_hash = std.hash.Wyhash.hash(0, output.ast.source),
            .allocator = allocator,
            .program = output,
            .owner = output.owner,
            .domain = &output.ast,
            .function = function,
            .parameters = output.locals[0..4].*,
            .caught = caught,
            .try_node = try_index,
            .try_body = try_body,
            .reserved_foreign = foreign_owned,
            .entries = .{.{ .owner = output.owner, .statement = statement, .expression = expression, .statement_snapshot = statement_node, .expression_snapshot = expression_node, .bytes = "" }},
            .insertions = .{ .owner = output.owner, .domain = &output.ast, .entries = &.{} },
        };
        self.insertions.entries = &self.entries;
        self.body_bytes = self.entries[0].bytes;
        try self.validate();
        return self;
    }

    pub fn destroy(self: *Program) void {
        const allocator = self.allocator;
        self.program.destroy();
        allocator.destroy(self);
    }

    fn node(self: *const Program, index: NodeIndex) Error!ast.Node {
        if (index.isNone() or @backingInt(index) >= self.domain.nodes.items.len) return error.InvalidNativeModuleWrapperProgram;
        return self.domain.getNode(index);
    }

    fn sameLocal(a: Output.Local, b: Output.Local) bool {
        return a.owner == b.owner and a.binding == b.binding and a.symbol == b.symbol and a.scope == b.scope and
            a.function_owner == b.function_owner and a.final_name.ptr == b.final_name.ptr and std.mem.eql(u8, a.final_name, b.final_name);
    }

    fn validateBinding(self: *const Program, descriptor: Output.Local, kind: @import("../semantic/symbol.zig").SymbolKind) Error!void {
        const raw = @backingInt(descriptor.binding);
        const sid = @backingInt(descriptor.symbol);
        if (descriptor.owner != self.owner or descriptor.function_owner != self.function.node or descriptor.scope.isNone() or
            @backingInt(descriptor.scope) >= self.program.analysis.scopes.items.len or raw >= self.program.analysis.symbol_ids.items.len or
            sid >= self.program.analysis.symbols.items.len or (try self.node(descriptor.binding)).tag != .binding_identifier or
            self.program.analysis.symbol_ids.items[raw] != sid) return error.InvalidNativeModuleWrapperProgram;
        const symbol = self.program.analysis.symbols.items[sid];
        if (symbol.kind != kind or symbol.scope_id != descriptor.scope or symbol.origin_scope != descriptor.scope)
            return error.InvalidNativeModuleWrapperProgram;
        for (self.reserved_foreign) |reserved| if (std.mem.eql(u8, descriptor.final_name, reserved)) return error.InvalidNativeModuleWrapperProgram;
        const selected = self.program.names.get(sid) orelse return error.InvalidNativeModuleWrapperProgram;
        if (selected.ptr != descriptor.final_name.ptr or !std.mem.eql(u8, selected, descriptor.final_name)) return error.InvalidNativeModuleWrapperProgram;
        var anchors: usize = 0;
        for (self.program.analysis.references.items) |reference| {
            if (reference.symbol_id == descriptor.symbol and reference.scope_id == descriptor.scope and
                reference.declaration_node_index == descriptor.binding and reference.node_index.isNone() and
                std.meta.eql(reference.flags, @as(@import("../semantic/symbol.zig").ReferenceFlags, .{ .declare = true }))) anchors += 1;
        }
        if (anchors != 1) return error.InvalidNativeModuleWrapperProgram;
    }

    pub fn validate(self: *const Program) Error!void {
        if (self.owner == .unassigned or self.owner != self.program.owner or self.domain != &self.program.ast or
            self.function.owner != self.owner or self.program.locals.len != 4 or self.program.functions.len != 1)
            return error.InvalidNativeModuleWrapperProgram;
        if (self.domain.source.ptr != self.source_bytes.ptr or self.domain.source.len != self.source_bytes.len or std.hash.Wyhash.hash(0, self.domain.source) != self.source_hash) return error.InvalidNativeModuleWrapperProgram;
        // Keep generic validation safe even if a caller corrupts a descriptor.
        for (self.program.locals) |descriptor| if (descriptor.scope.isNone() or @backingInt(descriptor.scope) >= self.program.analysis.scopes.items.len)
            return error.InvalidNativeModuleWrapperProgram;
        self.program.validate() catch return error.InvalidNativeModuleWrapperProgram;
        const value = unwrap(self.domain, self.program.hostExportValue() catch return error.InvalidNativeModuleWrapperProgram);
        if (value != self.function.node or !std.meta.eql(self.program.functions[0], self.function)) return error.InvalidNativeModuleWrapperProgram;
        const function_node = try self.node(value);
        if (function_node.tag != .function_expression or !self.domain.hasExtra(function_node.data.extra, ast.FunctionExtra.flags)) return error.InvalidNativeModuleWrapperProgram;
        const flags = self.domain.readExtra(function_node.data.extra, ast.FunctionExtra.flags);
        if (flags & ast.FunctionFlags.is_generator == 0 or flags & ast.FunctionFlags.is_async != 0 or
            self.function.scope.isNone() or @backingInt(self.function.scope) >= self.program.analysis.scopes.items.len)
            return error.InvalidNativeModuleWrapperProgram;
        const frame = self.program.analysis.scopes.items[@backingInt(self.function.scope)];
        if (frame.kind != .function or !frame.is_strict or frame.blocksMangling()) return error.InvalidNativeModuleWrapperProgram;
        const params = self.domain.functionParamsList(function_node);
        if (params.len != 4 or params.start > self.domain.extra_data.items.len or params.len > self.domain.extra_data.items.len - params.start)
            return error.InvalidNativeModuleWrapperProgram;
        for (self.parameters, 0..) |descriptor, i| {
            try self.validateBinding(descriptor, .parameter);
            if (descriptor.scope != self.function.scope or self.domain.extra_data.items[params.start + i] != @backingInt(descriptor.binding) or
                !sameLocal(descriptor, self.program.locals[i])) return error.InvalidNativeModuleWrapperProgram;
            for (self.parameters[0..i]) |prior| if (std.mem.eql(u8, prior.final_name, descriptor.final_name)) return error.InvalidNativeModuleWrapperProgram;
        }
        const body_index = self.domain.readExtraNode(function_node.data.extra, ast.FunctionExtra.body);
        const body = try self.node(body_index);
        if (body.tag != .block_statement or body.data.list.len != 4 or body.data.list.start > self.domain.extra_data.items.len or
            body.data.list.len > self.domain.extra_data.items.len - body.data.list.start or
            self.domain.extra_data.items[body.data.list.start + 3] != @backingInt(self.try_node)) return error.InvalidNativeModuleWrapperProgram;
        const try_statement = try self.node(self.try_node);
        if (try_statement.tag != .try_statement or try_statement.data.ternary.a != self.try_body or
            try_statement.data.ternary.b != self.caught.clause or try_statement.data.ternary.c.isNone()) return error.InvalidNativeModuleWrapperProgram;
        const clause = try self.node(self.caught.clause);
        if (clause.tag != .catch_clause or clause.data.binary.left != self.caught.local.binding) return error.InvalidNativeModuleWrapperProgram;
        try self.validateBinding(self.caught.local, .catch_binding);
        const catch_scope = self.caught.local.scope;
        if (self.program.analysis.scope_owner_map.get(@backingInt(self.caught.clause)) != @as(?u32, @backingInt(catch_scope))) return error.InvalidNativeModuleWrapperProgram;
        const catch_frame = self.program.analysis.scopes.items[@backingInt(catch_scope)];
        if (catch_frame.kind != .catch_clause or catch_frame.parent != self.function.scope or !catch_frame.is_strict or catch_frame.blocksMangling())
            return error.InvalidNativeModuleWrapperProgram;
        if (std.mem.eql(u8, self.caught.local.final_name, self.parameters[0].final_name) or
            std.mem.eql(u8, self.caught.local.final_name, self.parameters[1].final_name) or
            std.mem.eql(u8, self.caught.local.final_name, self.parameters[2].final_name) or
            std.mem.eql(u8, self.caught.local.final_name, self.parameters[3].final_name)) return error.InvalidNativeModuleWrapperProgram;
        const try_body = try self.node(self.try_body);
        if (try_body.tag != .block_statement or try_body.data.list.len != 1 or try_body.data.list.start >= self.domain.extra_data.items.len or
            self.domain.extra_data.items[try_body.data.list.start] != @backingInt(self.entries[0].statement)) return error.InvalidNativeModuleWrapperProgram;
        if (self.insertions.owner != self.owner or self.insertions.domain != self.domain or self.insertions.entries.ptr != @as([*]const Insertions.Entry, @ptrCast(&self.entries)) or
            self.insertions.entries.len != 1 or self.entries[0].bytes.ptr != self.body_bytes.ptr or
            !std.mem.eql(u8, self.entries[0].bytes, self.body_bytes)) return error.InvalidNativeModuleWrapperProgram;
        self.insertions.validate(self.domain, self.owner) catch return error.InvalidNativeModuleWrapperProgram;
    }

    pub fn local(self: *const Program, role: Role) Error!Output.Local {
        try self.validate();
        return self.parameters[@backingInt(role)];
    }
    pub fn environmentLocal(self: *const Program) Error!Output.Local {
        return self.local(.environment);
    }
    pub fn stackLocal(self: *const Program) Error!Output.Local {
        return self.local(.stack);
    }

    pub fn emitValue(self: *Program, allocator: std.mem.Allocator, body: []const u8, minify: bool) ![]const u8 {
        return self.emitValueInternal(allocator, body, minify, null);
    }

    pub fn emitValueTracked(self: *Program, allocator: std.mem.Allocator, body: []const u8, minify: bool, emitted_at: *?@import("../codegen/compiler_statement_insertions.zig").Emission) ![]const u8 {
        emitted_at.* = null;
        const result = try self.emitValueInternal(allocator, body, minify, emitted_at);
        errdefer allocator.free(result);
        const site = emitted_at.* orelse return error.InvalidNativeModuleWrapperProgram;
        if (site.owner != self.owner or site.domain != self.domain or site.statement != self.entries[0].statement) return error.InvalidNativeModuleWrapperProgram;
        return result;
    }

    fn emitValueInternal(self: *Program, allocator: std.mem.Allocator, body: []const u8, minify: bool, emitted_at: ?*?@import("../codegen/compiler_statement_insertions.zig").Emission) ![]const u8 {
        try self.validate();
        self.entries[0].emitted_at = emitted_at;
        defer self.entries[0].emitted_at = null;
        // Terminate a possible trailing source line comment before shell braces.
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
        return allocator.dupe(u8, codegen.buf.items);
    }
};

fn unwrap(domain: *const ast.Ast, input: NodeIndex) NodeIndex {
    var current = input;
    var remaining = domain.nodes.items.len;
    while (!current.isNone() and @backingInt(current) < domain.nodes.items.len and remaining != 0) : (remaining -= 1) {
        const node = domain.getNode(current);
        if (node.tag != .parenthesized_expression) break;
        current = node.data.unary.operand;
    }
    return current;
}

test "native module wrapper program rejects eleven foreign role and slot poisons" {
    const a = std.testing.allocator;
    const wrapper = try Program.create(a, &.{});
    defer wrapper.destroy();
    const foreign = try Program.create(a, &.{});
    defer foreign.destroy();
    const Poison = enum { owner, domain, parameter_owner, symbol, binding, parameter_scope, catch_scope, catch_owner, parameter_order, slot_statement, slot_snapshot };
    inline for (std.meta.tags(Poison)) |poison| {
        const saved_owner = wrapper.owner;
        const saved_domain = wrapper.domain;
        const saved_parameters = wrapper.parameters;
        const saved_caught = wrapper.caught;
        const saved_entry = wrapper.entries[0];
        const params = wrapper.domain.functionParamsList(wrapper.domain.getNode(wrapper.function.node));
        const saved_first = wrapper.program.ast.extra_data.items[params.start];
        const saved_second = wrapper.program.ast.extra_data.items[params.start + 1];
        switch (poison) {
            .owner => wrapper.owner = .unassigned,
            .domain => wrapper.domain = foreign.domain,
            .parameter_owner => wrapper.parameters[0].owner = foreign.owner,
            .symbol => wrapper.parameters[0].symbol = wrapper.parameters[1].symbol,
            .binding => wrapper.parameters[1].binding = wrapper.parameters[0].binding,
            .parameter_scope => wrapper.parameters[0].scope = wrapper.caught.local.scope,
            .catch_scope => wrapper.caught.local.scope = wrapper.function.scope,
            .catch_owner => wrapper.caught.clause = wrapper.try_node,
            .parameter_order => {
                wrapper.program.ast.extra_data.items[params.start] = saved_second;
                wrapper.program.ast.extra_data.items[params.start + 1] = saved_first;
            },
            .slot_statement => wrapper.entries[0].statement = wrapper.try_body,
            .slot_snapshot => wrapper.entries[0].expression_snapshot.span.end += 1,
        }
        try std.testing.expectError(error.InvalidNativeModuleWrapperProgram, wrapper.validate());
        wrapper.owner = saved_owner;
        wrapper.domain = saved_domain;
        wrapper.parameters = saved_parameters;
        wrapper.caught = saved_caught;
        wrapper.entries[0] = saved_entry;
        wrapper.program.ast.extra_data.items[params.start] = saved_first;
        wrapper.program.ast.extra_data.items[params.start + 1] = saved_second;
        try wrapper.validate();
    }
}

test "native module wrapper program keeps foreign names lexical TDZ hoisting and disposal" {
    const a = std.testing.allocator;
    const foreign_names = [_][]const u8{ "__zntcModuleEnvironment", "__zntcModuleEnvironment2", "__zntcModuleStack", "__zntcModuleError", "__zntcModuleFailed", "__zntcModuleCaught", "\\u005f_zntcModuleStack2" };
    const cases = [_]enum { lexical, suppression, synchronous }{ .lexical, .suppression, .synchronous };
    for (cases) |case| for ([_]bool{ false, true }) |minify| {
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const scratch = arena.allocator();
        const wrapper = try Program.create(a, &foreign_names);
        defer wrapper.destroy();
        const environment = try wrapper.environmentLocal();
        const stack = try wrapper.stackLocal();
        for (foreign_names[0..6]) |name| {
            try std.testing.expect(!std.mem.eql(u8, environment.final_name, name));
            try std.testing.expect(!std.mem.eql(u8, stack.final_name, name));
        }
        const acquire_expr = @import("native_async_disposal_runtime.zig").ACQUIRE_EXPRESSION;
        const dispose_expr = @import("native_async_disposal_runtime.zig").DISPOSE_GENERATOR_EXPRESSION;
        const factory_expr = @import("native_async_module_runtime.zig").FACTORY_EXPRESSION;
        const prelude = "const events=[];const record=x=>events.push(x);const shape=e=>e instanceof SuppressedError?[e.name,e.message,shape(e.error),shape(e.suppressed),Object.keys(e)]:e;";
        const original_body: []const u8 = switch (case) {
            .lexical => "function read(){return value}try{read()}catch(e){record(e.name)}await using resource={async[Symbol.asyncDispose](){record('dispose:start');await 0;record('dispose:end')}};const value=42;record(read());",
            .suppression => "await using resource={async[Symbol.asyncDispose](){record('dispose');await 0;throw 'dispose'}};throw 'body';",
            .synchronous => "using resource={[Symbol.dispose](){record('dispose')}};record('body');",
        };
        const native = try std.fmt.allocPrint(scratch, "{s}async function run(){{{s}}}try{{await run()}}catch(e){{record(shape(e))}}console.log(JSON.stringify(events));", .{ prelude, original_body });
        const expected = try std.process.run(scratch, std.testing.io, .{ .argv = &.{ "node", "--input-type=module", "-e", native }, .stdout_limit = .limited(16384), .stderr_limit = .limited(16384) });
        try std.testing.expect(expected.term == .exited and expected.term.exited == 0);
        const body = switch (case) {
            .lexical => try std.fmt.allocPrint(
                scratch,
                "yield{{namespace:{{read,get value(){{return value}}}},hasTLA:true}};const __zntcModuleEnvironment='user';const __zntcModuleStack='user';const \\u005f_zntcModuleStack2='escaped-user';function read(){{return value}}try{{read()}}catch(e){{record(e.name)}}const resource={s}[0]({s},{{async[Symbol.asyncDispose](){{record('dispose:start');await 0;record('dispose:end')}}}},true);const value=42;record(read());// trailing source comment",
                .{ environment.final_name, stack.final_name },
            ),
            .suppression => try std.fmt.allocPrint(
                scratch,
                "yield{{namespace:{{}},hasTLA:true}};const resource={s}[0]({s},{{async[Symbol.asyncDispose](){{record('dispose');await 0;throw 'dispose'}}}},true);throw 'body';",
                .{ environment.final_name, stack.final_name },
            ),
            .synchronous => try std.fmt.allocPrint(
                scratch,
                "yield{{namespace:{{}},hasTLA:false}};const resource={s}[0]({s},{{[Symbol.dispose](){{record('dispose')}}}},false);record('body');",
                .{ environment.final_name, stack.final_name },
            ),
        };
        const printed = try wrapper.emitValue(scratch, body, minify);
        const checks: []const u8 = if (case == .lexical)
            "try{init.namespace.read();throw 'missing TDZ'}catch(e){if(!(e instanceof ReferenceError))throw e}"
        else
            "";
        const model = try std.fmt.allocPrint(
            scratch,
            "{s}const factory={s};const acquire={s};const dispose={s};const init=factory({s},()=>[],[acquire,dispose]);{s}try{{await init()}}catch(e){{record(shape(e))}}console.log(JSON.stringify(events));",
            .{ prelude, factory_expr, acquire_expr, dispose_expr, printed, checks },
        );
        const actual = try std.process.run(scratch, std.testing.io, .{ .argv = &.{ "node", "--input-type=module", "-e", model }, .stdout_limit = .limited(16384), .stderr_limit = .limited(16384) });
        errdefer std.debug.print("wrapper case={s} minify={} code={s}\nactual stderr={s}\n", .{ @tagName(case), minify, printed, actual.stderr });
        try std.testing.expect(actual.term == .exited and actual.term.exited == 0);
        try std.testing.expectEqualStrings(expected.stdout, actual.stdout);
        try std.testing.expectEqualStrings(expected.stderr, actual.stderr);
    };
}

test "native module wrapper program reports the actual statement hole output position" {
    const a = std.testing.allocator;
    const wrapper = try Program.create(a, &.{});
    defer wrapper.destroy();
    const body = "yield {namespace:{},hasTLA:false};\nvoid 'BODY';void '🙂';";
    for ([_]bool{ false, true }) |minify| {
        var site: ?@import("../codegen/compiler_statement_insertions.zig").Emission = null;
        const output = try wrapper.emitValueTracked(a, body, minify, &site);
        defer a.free(output);
        const actual = site orelse return error.MissingStatementEmission;
        try std.testing.expect(actual.owner == wrapper.owner and actual.domain == wrapper.domain and actual.statement == wrapper.entries[0].statement);
        try std.testing.expect(actual.byte_offset < output.len);
        try std.testing.expect(std.mem.startsWith(u8, output[actual.byte_offset..], body));
        const prefix = output[0..actual.byte_offset];
        try std.testing.expectEqual(@as(u32, @intCast(std.mem.count(u8, prefix, "\n"))), actual.line);
        try std.testing.expectEqual(@import("../codegen/writer.zig").trailingColumn(prefix), actual.column);
    }
}
