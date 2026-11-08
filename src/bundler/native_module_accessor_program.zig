//! Compiler-owned descriptor shell. User getter/setter bodies stay in their own name domain.
const std = @import("std");
const ast = @import("../parser/ast.zig");
const Output = @import("compiler_output_program.zig");
const Owner = @import("codegen_output_domain.zig").Owner;
const Set = @import("../codegen/compiler_statement_insertions.zig");
const NodeIndex = ast.NodeIndex;
const Error = error{InvalidNativeModuleAccessorProgram};
const template = "module.exports=({__proto__:null,get:function(){;\"GET\";},set:function(value){;\"SET\";},enumerable:true,configurable:false});";

pub const Program = struct {
    allocator: std.mem.Allocator,
    program: *Output.Program,
    owner: Owner,
    domain: *const ast.Ast,
    source_bytes: []const u8,
    source_hash: u64,
    object: NodeIndex,
    properties: [5]NodeIndex,
    property_snapshots: [5]ast.Node,
    key_snapshots: [5]ast.Node,
    functions: [2]Output.Function,
    value: Output.Local,
    entries: [2]Set.Entry,
    bodies: [2][]const u8,
    insertions: Set.Set,
    reserved: []const []const u8,

    pub fn create(allocator: std.mem.Allocator, foreign_final_names: []const []const u8) !*Program {
        const output = try Output.Program.create(allocator, template);
        errdefer output.destroy();
        const self = try allocator.create(Program);
        errdefer allocator.destroy(self);
        const a = output.arena.allocator();
        const object = unwrap(&output.ast, try output.hostExportValue());
        const object_node = output.ast.getNode(object);
        if (object_node.tag != .object_expression or object_node.data.list.len != 5 or output.functions.len != 2 or output.locals.len != 1) return error.InvalidNativeModuleAccessorProgram;
        var properties: [5]NodeIndex = undefined;
        var snapshots: [5]ast.Node = undefined;
        var keys: [5]ast.Node = undefined;
        for (&properties, &snapshots, 0..) |*property, *snapshot, i| {
            property.* = @fromBackingInt(output.ast.extra_data.items[object_node.data.list.start + i]);
            snapshot.* = output.ast.getNode(property.*);
            if (snapshot.tag != .object_property) return error.InvalidNativeModuleAccessorProgram;
            keys[i] = output.ast.getNode(snapshot.data.binary.left);
        }
        var functions: [2]Output.Function = undefined;
        var entries: [2]Set.Entry = undefined;
        for (&functions, &entries, 0..) |*function, *entry, i| {
            const fn_index = snapshots[i + 1].data.binary.right;
            var selected: ?Output.Function = null;
            for (output.functions) |candidate| if (candidate.node == fn_index) {
                selected = candidate;
            };
            function.* = selected orelse return error.InvalidNativeModuleAccessorProgram;
            const fn_node = output.ast.getNode(fn_index);
            const body = output.ast.getNode(output.ast.readExtraNode(fn_node.data.extra, ast.FunctionExtra.body));
            if (body.tag != .block_statement or body.data.list.len != 2) return error.InvalidNativeModuleAccessorProgram;
            if (output.ast.getNode(@fromBackingInt(output.ast.extra_data.items[body.data.list.start])).tag != .empty_statement) return error.InvalidNativeModuleAccessorProgram;
            const statement: NodeIndex = @fromBackingInt(output.ast.extra_data.items[body.data.list.start + 1]);
            const statement_node = output.ast.getNode(statement);
            const expression = statement_node.data.unary.operand;
            const expression_node = output.ast.getNode(expression);
            if (statement_node.tag != .expression_statement or expression_node.tag != .string_literal) return error.InvalidNativeModuleAccessorProgram;
            entry.* = .{ .owner = output.owner, .statement = statement, .expression = expression, .statement_snapshot = statement_node, .expression_snapshot = expression_node, .bytes = "" };
        }
        const params = output.ast.functionParamsList(output.ast.getNode(functions[1].node));
        if (params.len != 1 or output.locals[0].function_owner != functions[1].node or output.ast.extra_data.items[params.start] != @backingInt(output.locals[0].binding)) return error.InvalidNativeModuleAccessorProgram;
        var reservations: @import("../transformer/es_helpers.zig").PrivateNameAllocator = .{ .allocator = a };
        const Scanner = @import("../lexer/scanner.zig").Scanner;
        const reserved = try a.alloc([]const u8, foreign_final_names.len);
        for (foreign_final_names, 0..) |name, i| {
            reserved[i] = try Scanner.decodeIdentifierEscapesAlloc(a, name);
            try reservations.reserved.put(a, reserved[i], {});
        }
        for (output.analysis.scope_maps.items) |map| {
            var own_keys = map.keyIterator();
            while (own_keys.next()) |key| try reservations.reserved.put(a, try Scanner.decodeIdentifierEscapesAlloc(a, key.*), {});
        }
        var globals = output.analysis.unresolved_references.keyIterator();
        while (globals.next()) |key| try reservations.reserved.put(a, try Scanner.decodeIdentifierEscapesAlloc(a, key.*), {});
        output.locals[0].final_name = try reservations.makeUniqueName("__zntcAccessorValue");
        try output.names.put(a, @backingInt(output.locals[0].symbol), output.locals[0].final_name);
        self.* = .{ .allocator = allocator, .program = output, .owner = output.owner, .domain = &output.ast, .source_bytes = output.ast.source, .source_hash = std.hash.Wyhash.hash(0, output.ast.source), .object = object, .properties = properties, .property_snapshots = snapshots, .key_snapshots = keys, .functions = functions, .value = output.locals[0], .entries = entries, .bodies = .{ entries[0].bytes, entries[1].bytes }, .insertions = .{ .owner = output.owner, .domain = &output.ast, .entries = &.{} }, .reserved = reserved };
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
        if (index.isNone() or @backingInt(index) >= self.domain.nodes.items.len) return error.InvalidNativeModuleAccessorProgram;
        return self.domain.getNode(index);
    }
    pub fn validate(self: *const Program) Error!void {
        if (self.owner == .unassigned or self.owner != self.program.owner or self.domain != &self.program.ast or self.domain.source.ptr != self.source_bytes.ptr or self.domain.source.len != self.source_bytes.len or std.hash.Wyhash.hash(0, self.domain.source) != self.source_hash or self.program.locals.len != 1 or self.program.functions.len != 2) return error.InvalidNativeModuleAccessorProgram;
        if (self.value.scope.isNone() or @backingInt(self.value.scope) >= self.program.analysis.scopes.items.len) return error.InvalidNativeModuleAccessorProgram;
        // Validate generic descriptors only after their mutable scope ranges are safe.
        for (self.program.locals) |descriptor| if (descriptor.scope.isNone() or @backingInt(descriptor.scope) >= self.program.analysis.scopes.items.len) return error.InvalidNativeModuleAccessorProgram;
        self.program.validate() catch return error.InvalidNativeModuleAccessorProgram;
        if (unwrap(self.domain, self.program.hostExportValue() catch return error.InvalidNativeModuleAccessorProgram) != self.object) return error.InvalidNativeModuleAccessorProgram;
        const object = try self.node(self.object);
        if (object.tag != .object_expression or object.data.list.len != 5 or object.data.list.start > self.domain.extra_data.items.len or object.data.list.len > self.domain.extra_data.items.len - object.data.list.start) return error.InvalidNativeModuleAccessorProgram;
        for (self.properties, self.property_snapshots, 0..) |property, snapshot, i| {
            if (self.domain.extra_data.items[object.data.list.start + i] != @backingInt(property)) return error.InvalidNativeModuleAccessorProgram;
            const actual = try self.node(property);
            if (actual.tag != .object_property or snapshot.tag != actual.tag or !std.meta.eql(actual.span, snapshot.span) or !std.meta.eql(actual.data.binary, snapshot.data.binary)) return error.InvalidNativeModuleAccessorProgram;
            const key = try self.node(actual.data.binary.left);
            if (key.tag != self.key_snapshots[i].tag or !std.meta.eql(key.span, self.key_snapshots[i].span) or !std.meta.eql(key.data.string_ref, self.key_snapshots[i].data.string_ref)) return error.InvalidNativeModuleAccessorProgram;
            if (i == 0 or i >= 3) {
                const literal = try self.node(actual.data.binary.right);
                const expected = if (i == 0) "null" else if (i == 3) "true" else "false";
                if (literal.tag != (if (i == 0) @as(ast.Node.Tag, .null_literal) else .boolean_literal) or !std.mem.eql(u8, self.domain.getText(literal.span), expected)) return error.InvalidNativeModuleAccessorProgram;
            }
        }
        const root_scope = self.program.analysis.scope_owner_map.get(@backingInt(self.program.root)) orelse return error.InvalidNativeModuleAccessorProgram;
        if (root_scope >= self.program.analysis.scopes.items.len) return error.InvalidNativeModuleAccessorProgram;
        for (self.functions, 0..) |function, i| {
            if (function.owner != self.owner or function.node != self.property_snapshots[i + 1].data.binary.right or function.scope.isNone() or @backingInt(function.scope) >= self.program.analysis.scopes.items.len or self.program.analysis.scope_owner_map.get(@backingInt(function.node)) != @as(?u32, @backingInt(function.scope))) return error.InvalidNativeModuleAccessorProgram;
            var matched: usize = 0;
            for (self.program.functions) |candidate| if (std.meta.eql(function, candidate)) {
                matched += 1;
            };
            if (matched != 1) return error.InvalidNativeModuleAccessorProgram;
            const fn_node = try self.node(function.node);
            if (fn_node.tag != .function_expression or !self.domain.hasExtra(fn_node.data.extra, ast.FunctionExtra.flags) or self.domain.readExtra(fn_node.data.extra, ast.FunctionExtra.flags) != 0) return error.InvalidNativeModuleAccessorProgram;
            const frame = self.program.analysis.scopes.items[@backingInt(function.scope)];
            if (frame.kind != .function or @backingInt(frame.parent) != root_scope or frame.blocksMangling() or frame.is_strict != self.program.analysis.scopes.items[root_scope].is_strict) return error.InvalidNativeModuleAccessorProgram;
            const params = self.domain.functionParamsList(fn_node);
            if (params.len != i or params.start > self.domain.extra_data.items.len or params.len > self.domain.extra_data.items.len - params.start) return error.InvalidNativeModuleAccessorProgram;
            if (i == 1 and self.domain.extra_data.items[params.start] != @backingInt(self.value.binding)) return error.InvalidNativeModuleAccessorProgram;
            const body = try self.node(self.domain.readExtraNode(fn_node.data.extra, ast.FunctionExtra.body));
            if (body.tag != .block_statement or body.data.list.len != 2 or body.data.list.start >= self.domain.extra_data.items.len or 2 > self.domain.extra_data.items.len - body.data.list.start or self.domain.extra_data.items[body.data.list.start + 1] != @backingInt(self.entries[i].statement)) return error.InvalidNativeModuleAccessorProgram;
            if ((try self.node(@fromBackingInt(self.domain.extra_data.items[body.data.list.start]))).tag != .empty_statement) return error.InvalidNativeModuleAccessorProgram;
        }
        const descriptor = self.value;
        const sid = @backingInt(descriptor.symbol);
        const raw = @backingInt(descriptor.binding);
        if (descriptor.owner != self.owner or descriptor.function_owner != self.functions[1].node or descriptor.scope != self.functions[1].scope or !sameLocal(descriptor, self.program.locals[0]) or sid >= self.program.analysis.symbols.items.len or raw >= self.program.analysis.symbol_ids.items.len or self.program.analysis.symbol_ids.items[raw] != sid or (try self.node(descriptor.binding)).tag != .binding_identifier) return error.InvalidNativeModuleAccessorProgram;
        const symbol = self.program.analysis.symbols.items[sid];
        if (symbol.kind != .parameter or symbol.scope_id != descriptor.scope or symbol.origin_scope != descriptor.scope) return error.InvalidNativeModuleAccessorProgram;
        const selected = self.program.names.get(sid) orelse return error.InvalidNativeModuleAccessorProgram;
        if (selected.ptr != descriptor.final_name.ptr or !std.mem.eql(u8, selected, descriptor.final_name)) return error.InvalidNativeModuleAccessorProgram;
        for (self.reserved) |name| if (std.mem.eql(u8, name, descriptor.final_name)) return error.InvalidNativeModuleAccessorProgram;
        var anchors: usize = 0;
        for (self.program.analysis.references.items) |reference| if (reference.symbol_id == descriptor.symbol and reference.scope_id == descriptor.scope and reference.declaration_node_index == descriptor.binding and reference.node_index.isNone() and std.meta.eql(reference.flags, @as(@import("../semantic/symbol.zig").ReferenceFlags, .{ .declare = true }))) {
            anchors += 1;
        };
        if (anchors != 1 or self.functions[0].node == self.functions[1].node or self.functions[0].scope == self.functions[1].scope) return error.InvalidNativeModuleAccessorProgram;
        if (self.insertions.owner != self.owner or self.insertions.domain != self.domain or self.insertions.entries.ptr != @as([*]const Set.Entry, @ptrCast(&self.entries)) or self.insertions.entries.len != 2) return error.InvalidNativeModuleAccessorProgram;
        for (self.entries, self.bodies) |entry, body| if (entry.bytes.ptr != body.ptr or !std.mem.eql(u8, entry.bytes, body)) return error.InvalidNativeModuleAccessorProgram;
        self.insertions.validate(self.domain, self.owner) catch return error.InvalidNativeModuleAccessorProgram;
    }
    pub fn setterValueLocal(self: *const Program) Error!Output.Local {
        try self.validate();
        return self.value;
    }
    pub fn emitDescriptor(self: *Program, allocator: std.mem.Allocator, getter_body: []const u8, setter_body: []const u8, minify: bool) ![]const u8 {
        try self.validate();
        for ([_][]const u8{ getter_body, setter_body }, 0..) |body, i| {
            const bytes = try std.fmt.allocPrint(self.program.arena.allocator(), "{s}\n", .{body});
            self.bodies[i] = bytes;
            self.entries[i].bytes = bytes;
        }
        try self.validate();
        var codegen = @import("../codegen/codegen.zig").Codegen.initWithOptions(self.program.arena.allocator(), self.domain, .{ .semantic_symbol_ids = self.program.analysis.symbol_ids.items, .semantic_symbols = self.program.analysis.symbols.items, .semantic_scope_maps = self.program.analysis.scope_maps.items, .semantic_symbol_name_overrides = &self.program.names, .compiler_statement_insertions = &self.insertions, .minify_whitespace = minify });
        try codegen.emitExpr(try self.program.hostExportValue(), .comma, .{});
        return allocator.dupe(u8, codegen.buf.items);
    }
};
fn sameLocal(a: Output.Local, b: Output.Local) bool {
    return a.owner == b.owner and a.binding == b.binding and a.symbol == b.symbol and a.scope == b.scope and a.function_owner == b.function_owner and a.final_name.ptr == b.final_name.ptr and std.mem.eql(u8, a.final_name, b.final_name);
}
fn unwrap(domain: *const ast.Ast, index: NodeIndex) NodeIndex {
    var current = index;
    while (domain.getNode(current).tag == .parenthesized_expression) current = domain.getNode(current).data.unary.operand;
    return current;
}

test "native module accessor program rejects eleven foreign owner scope and slot poisons" {
    const a = std.testing.allocator;
    const shell = try Program.create(a, &.{ "__zntcAccessorValue", "\\u005f_zntcAccessorValue2" });
    defer shell.destroy();
    const foreign = try Program.create(a, &.{});
    defer foreign.destroy();
    const original = shell.*;
    const scope = @backingInt(shell.functions[1].scope);
    const frame = shell.program.analysis.scopes.items[scope];
    const reference = blk: {
        for (shell.program.analysis.references.items, 0..) |ref, i| if (ref.declaration_node_index == shell.value.binding and ref.flags.declare) break :blk i;
        return error.MissingFixtureAnchor;
    };
    const anchor = shell.program.analysis.references.items[reference];
    const poisons = [_]enum { owner, domain, source, getter_owner, setter_scope_kind, parameter_sid, scope_parent, declaration_anchor, duplicate_slot, foreign_expression, parameter_owner }{ .owner, .domain, .source, .getter_owner, .setter_scope_kind, .parameter_sid, .scope_parent, .declaration_anchor, .duplicate_slot, .foreign_expression, .parameter_owner };
    for (poisons) |poison| {
        switch (poison) {
            .owner => shell.owner = .unassigned,
            .domain => shell.domain = foreign.domain,
            .source => shell.source_bytes = "foreign",
            .getter_owner => shell.functions[0].owner = foreign.owner,
            .setter_scope_kind => shell.program.analysis.scopes.items[scope].kind = .block,
            .parameter_sid => shell.value.symbol = .none,
            .scope_parent => shell.program.analysis.scopes.items[scope].parent = shell.functions[0].scope,
            .declaration_anchor => shell.program.analysis.references.items[reference].flags.declare = false,
            .duplicate_slot => shell.entries[1] = shell.entries[0],
            .foreign_expression => shell.entries[0].expression = foreign.entries[0].expression,
            .parameter_owner => shell.value.function_owner = shell.functions[0].node,
        }
        // Separate identical source parses can have the same raw NodeIndex;
        // make the foreign expression unmistakably foreign to this slot.
        if (poison == .foreign_expression) shell.entries[0].expression = shell.value.binding;
        try std.testing.expectError(error.InvalidNativeModuleAccessorProgram, shell.validate());
        shell.* = original;
        shell.program.analysis.scopes.items[scope] = frame;
        shell.program.analysis.references.items[reference] = anchor;
        try shell.validate();
    }
}

test "native module accessor program preserves lexical storage reflection and original thrown values" {
    const cases = [_]enum { lexical, constant, postfix, pollution, suppression }{ .lexical, .constant, .postfix, .pollution, .suppression };
    for (cases) |case| for ([_]bool{ false, true }) |minify| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const shell = try Program.create(std.testing.allocator, &.{ "__zntcAccessorValue", "__zntcAccessorValue2", "storage", "value", "publish" });
        defer shell.destroy();
        const parameter = try shell.setterValueLocal();
        const set = try std.fmt.allocPrint(a, "value={s};publish();// source trailing comment", .{parameter.final_name});
        const descriptor = try shell.emitDescriptor(a, if (case == .suppression) "throw failure;// source trailing comment" else "return value;// source trailing comment", set, minify);
        const function_descriptor = try shell.emitDescriptor(a, "return hoisted;", set, minify);
        const prelude = "\"use strict\";const events=[];const record=x=>events.push(x);let published=0;const publish=()=>published++;const shape=e=>e instanceof SuppressedError?[e.name,e.message,e.error,e.suppressed,Object.keys(e)]:e.name;";
        const original: []const u8 = switch (case) {
            .lexical => "try{record(value)}catch(e){record(e.name)}record(hoisted());let value=40;value=42;publish();record([value,published]);function hoisted(){return 7}",
            .constant => "const value=42;try{value=43;publish()}catch(e){record(e.name)}record([value,published]);",
            .postfix => "let value=41;const result=value++;publish();record([result,value,published]);",
            .pollution => "let value=42;record(value);",
            .suppression => "const failure=new SuppressedError('dispose','body','original');const value=42;try{throw failure}catch(e){record([e===failure,shape(e)])}",
        };
        const model_body = switch (case) {
            .lexical => try std.fmt.allocPrint(a, "try{{record(storage.value)}}catch(e){{record(e.name)}}Object.defineProperty(storage,'fn',{s});record(storage.fn());let value=40;storage.value=42;record([storage.value,published]);function hoisted(){{return 7}}", .{function_descriptor}),
            .constant => try a.dupe(u8, "const value=42;try{storage.value=43}catch(e){record(e.name)}record([storage.value,published]);"),
            .postfix => try a.dupe(u8, "let value=41;const result=storage.value++;record([result,storage.value,published]);"),
            .pollution => try a.dupe(u8, "let value=42;record(storage.value);"),
            .suppression => try a.dupe(u8, "const failure=new SuppressedError('dispose','body','original');const value=42;try{storage.value}catch(e){record([e===failure,shape(e)])}"),
        };
        const native = try std.fmt.allocPrint(a, "{s}{s}console.log(JSON.stringify(events));", .{ prelude, original });
        const model = try std.fmt.allocPrint(a, "{s}const descriptor={s};if(Object.getPrototypeOf(descriptor)!==null||descriptor.enumerable!==true||descriptor.configurable!==false)throw Error('descriptor');const storage=Object.create(null);let traps=0;Object.defineProperty(Object.prototype,'value',{{configurable:true,get(){{traps++;throw Error('polluted get')}}}});try{{Object.defineProperty(storage,'value',descriptor)}}finally{{delete Object.prototype.value}}if(traps)throw Error('prototype consulted');{s}console.log(JSON.stringify(events));", .{ prelude, descriptor, model_body });
        const expected = try std.process.run(a, std.testing.io, .{ .argv = &.{ "node", "--input-type=module", "-e", native }, .stdout_limit = .limited(16384), .stderr_limit = .limited(16384) });
        const actual = try std.process.run(a, std.testing.io, .{ .argv = &.{ "node", "--input-type=module", "-e", model }, .stdout_limit = .limited(16384), .stderr_limit = .limited(16384) });
        errdefer std.debug.print("accessor case={s} minify={}\nmodel={s}\nnative stderr={s}\nactual stderr={s}\n", .{ @tagName(case), minify, model, expected.stderr, actual.stderr });
        try std.testing.expect(expected.term == .exited and expected.term.exited == 0);
        try std.testing.expect(actual.term == .exited and actual.term.exited == 0);
        try std.testing.expectEqualStrings(expected.stdout, actual.stdout);
        try std.testing.expectEqualStrings(expected.stderr, actual.stderr);
    };
}
