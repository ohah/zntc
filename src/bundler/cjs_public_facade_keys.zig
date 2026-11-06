//! Original-parser CommonJS *lexical* public namespace keys. This is not a
//! semantic exports table: Node's CJS lexer deliberately also sees shadowed
//! `exports`/`module` spellings. No source binding or SymbolId is reconstructed.
const std = @import("std");
const ast_mod = @import("../parser/ast.zig");
const Ast = ast_mod.Ast;
const NodeIndex = ast_mod.NodeIndex;
const Node = ast_mod.Node;
const Span = @import("../lexer/token.zig").Span;
const Module = @import("module.zig").Module;
const Kind = @import("../lexer/token.zig").Kind;

pub const Role = enum { assignment, descriptor, object_literal };
pub const Datum = struct {
    node: NodeIndex,
    tag: Node.Tag,
    span: Span,
    syntax: []const u8,
};
pub const Key = struct {
    value: []const u8,
    role: Role,
    value_hash: u64,
    owner: Datum,
    key: Datum,
};
pub const Reexport = struct {
    source_node: NodeIndex,
    call: Datum,
    literal: Datum,
    specifier: []const u8,
    specifier_hash: u64,
    role: enum { direct, star },
};

pub const Registry = struct {
    // The parse arena travels with a PersistentModuleStore module. A disk
    // decoder creates a fresh registry from its original parse view instead.
    owner: @import("codegen_output_domain.zig").Owner,
    source: []const u8,
    path: []const u8,
    parse_arena: ?*std.heap.ArenaAllocator,
    parser_node_count: usize,
    direct_keys: []const Key,
    reexports: []const Reexport,

    pub fn validate(self: *const Registry, module: *const Module) !void {
        if (self.owner == .unassigned or self.owner != module.codegen_output_owner or self.source.ptr != module.source.ptr or self.source.len != module.source.len or
            self.parse_arena != module.parse_arena or !std.mem.eql(u8, self.path, module.path))
            return error.InvalidCjsPublicFacadeKeys;
        for (self.direct_keys) |key| {
            if (std.hash.Wyhash.hash(0, key.value) != key.value_hash) return error.InvalidCjsPublicFacadeKeys;
            try self.validateDatum(key.owner);
            try self.validateDatum(key.key);
            switch (key.role) {
                .assignment => if (key.owner.tag != .assignment_expression) return error.InvalidCjsPublicFacadeKeys,
                .descriptor => if (key.owner.tag != .call_expression) return error.InvalidCjsPublicFacadeKeys,
                .object_literal => if (key.owner.tag != .object_property) return error.InvalidCjsPublicFacadeKeys,
            }
        }
        for (self.reexports) |edge| {
            if (std.hash.Wyhash.hash(0, edge.specifier) != edge.specifier_hash) return error.InvalidCjsPublicFacadeKeys;
            try self.validateDatum(edge.call);
            try self.validateDatum(edge.literal);
            if (edge.call.tag != .call_expression or edge.literal.tag != .string_literal or
                edge.source_node != edge.literal.node) return error.InvalidCjsPublicFacadeKeys;
            var matches: usize = 0;
            for (module.import_records) |record| {
                if (record.source_node == edge.source_node and record.kind == .require and
                    std.mem.eql(u8, record.specifier, edge.specifier)) matches += 1;
            }
            if (matches != 1) return error.InvalidCjsPublicFacadeKeys;
        }
    }

    fn validateDatum(self: *const Registry, proof: Datum) !void {
        if (proof.node.isNone() or @backingInt(proof.node) >= self.parser_node_count or
            proof.span.start > proof.span.end or proof.span.end > self.source.len or
            !std.mem.eql(u8, proof.syntax, self.source[proof.span.start..proof.span.end]))
            return error.InvalidCjsPublicFacadeKeys;
    }
};

fn get(ast: *const Ast, idx: NodeIndex) ?Node {
    if (idx.isNone() or @backingInt(idx) >= ast.nodes.items.len) return null;
    return ast.getNode(idx);
}
fn ident(ast: *const Ast, idx: NodeIndex, name: []const u8) bool {
    const n = get(ast, idx) orelse return false;
    return (n.tag == .identifier_reference or n.tag == .binding_identifier) and
        std.mem.eql(u8, ast.identifierNameText(n), name);
}
fn member(ast: *const Ast, idx: NodeIndex) ?struct { object: NodeIndex, key: NodeIndex, computed: bool } {
    const n = get(ast, idx) orelse return null;
    if ((n.tag != .static_member_expression and n.tag != .computed_member_expression) or
        !ast.hasExtra(n.data.extra, 2) or ast.readExtra(n.data.extra, 2) != 0) return null;
    return .{ .object = ast.readExtraNode(n.data.extra, 0), .key = ast.readExtraNode(n.data.extra, 1), .computed = n.tag == .computed_member_expression };
}
fn staticMember(ast: *const Ast, idx: NodeIndex, object: []const u8, key: []const u8) bool {
    const m = member(ast, idx) orelse return false;
    return !m.computed and ident(ast, m.object, object) and ident(ast, m.key, key);
}
fn host(ast: *const Ast, idx: NodeIndex) bool {
    return ident(ast, idx, "exports") or staticMember(ast, idx, "module", "exports");
}
fn call(ast: *const Ast, idx: NodeIndex) ?struct { callee: NodeIndex, args: []const u32 } {
    const n = get(ast, idx) orelse return null;
    if (n.tag != .call_expression or !ast.hasExtra(n.data.extra, 3) or (ast.readExtra(n.data.extra, 3) & ast_mod.CallFlags.optional_chain) != 0) return null;
    const start = ast.readExtra(n.data.extra, 1);
    const len = ast.readExtra(n.data.extra, 2);
    if (start > ast.extra_data.items.len or len > ast.extra_data.items.len - start) return null;
    return .{ .callee = ast.readExtraNode(n.data.extra, 0), .args = ast.extra_data.items[start..][0..len] };
}
fn list(ast: *const Ast, idx: NodeIndex, tag: Node.Tag) ?[]const u32 {
    const n = get(ast, idx) orelse return null;
    if (n.tag != tag or n.data.list.start > ast.extra_data.items.len or n.data.list.len > ast.extra_data.items.len - n.data.list.start) return null;
    return ast.extra_data.items[n.data.list.start..][0..n.data.list.len];
}
fn datum(a: std.mem.Allocator, ast: *const Ast, idx: NodeIndex) !Datum {
    const n = get(ast, idx) orelse return error.InvalidCjsPublicFacadeKeys;
    if (n.span.start > n.span.end or n.span.end > ast.source.len) return error.InvalidCjsPublicFacadeKeys;
    return .{ .node = idx, .tag = n.tag, .span = n.span, .syntax = try a.dupe(u8, ast.source[n.span.start..n.span.end]) };
}
fn keyValue(a: std.mem.Allocator, ast: *const Ast, idx: NodeIndex) !?[]const u8 {
    const n = get(ast, idx) orelse return null;
    // Node's default lexer does not recognize escaped dot identifiers.
    if (n.tag == .identifier_reference or n.tag == .binding_identifier) {
        const text = ast.identifierNameText(n);
        if (std.mem.indexOfScalar(u8, text, '\\') != null) return null;
        for ([_][]const u8{ "implements", "interface", "let", "package", "private", "protected", "public", "static", "yield", "enum" }) |reserved|
            if (std.mem.eql(u8, text, reserved)) return null;
        return text;
    }
    if (n.tag != .string_literal) return null;
    return @import("../string_escape.zig").decodeJsStringLiteral(a, ast.getText(n.span)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
}
fn returnedValue(ast: *const Ast, fn_idx: NodeIndex) ?NodeIndex {
    const fn_node = get(ast, fn_idx) orelse return null;
    if (fn_node.tag != .function_expression and fn_node.tag != .method_definition) return null;
    const flag_slot = if (fn_node.tag == .method_definition) ast_mod.MethodExtra.flags else ast_mod.FunctionExtra.flags;
    if (!ast.hasExtra(fn_node.data.extra, flag_slot)) return null;
    const forbidden: u32 = if (fn_node.tag == .method_definition)
        ast_mod.MethodFlags.is_getter | ast_mod.MethodFlags.is_setter | ast_mod.MethodFlags.is_async | ast_mod.MethodFlags.is_generator
    else
        ast_mod.FunctionFlags.is_async | ast_mod.FunctionFlags.is_generator;
    if ((ast.readExtra(fn_node.data.extra, flag_slot) & forbidden) != 0) return null;
    if (ast.functionParamsList(fn_node).len != 0) return null;
    const body = ast.functionBodyBlock(fn_node) orelse return null;
    const statements = list(ast, body, .block_statement) orelse return null;
    if (statements.len != 1) return null;
    const ret = get(ast, @fromBackingInt(statements[0])) orelse return null;
    if (ret.tag != .return_statement) return null;
    return ret.data.unary.operand;
}
fn simpleGetter(ast: *const Ast, fn_idx: NodeIndex) bool {
    const value = returnedValue(ast, fn_idx) orelse return false;
    if (get(ast, value)) |n| if (n.tag == .identifier_reference) return true;
    const m = member(ast, value) orelse return false;
    const base = get(ast, m.object) orelse return false;
    if (base.tag != .identifier_reference) return false;
    const key = get(ast, m.key) orelse return false;
    return if (m.computed) key.tag == .string_literal else key.tag == .identifier_reference;
}
fn descriptorSupported(ast: *const Ast, descriptor: NodeIndex) bool {
    const props = list(ast, descriptor, .object_expression) orelse return false;
    var at: usize = 0;
    if (props.len == 0) return false;
    var p = ast.getNode(@fromBackingInt(props[at]));
    if (p.tag == .object_property and ident(ast, p.data.binary.left, "enumerable")) {
        const truth = get(ast, p.data.binary.right) orelse return false;
        if (truth.tag != .boolean_literal or !std.mem.eql(u8, ast.getText(truth.span), "true")) return false;
        at += 1;
        if (at == props.len) return false;
        p = ast.getNode(@fromBackingInt(props[at]));
    }
    if (p.tag == .object_property) {
        if (ident(ast, p.data.binary.left, "value") and !p.data.binary.right.isNone()) return true;
        return at + 1 == props.len and ident(ast, p.data.binary.left, "get") and simpleGetter(ast, p.data.binary.right);
    }
    return at + 1 == props.len and p.tag == .method_definition and
        ident(ast, ast.readExtraNode(p.data.extra, ast_mod.MethodExtra.key), "get") and simpleGetter(ast, @fromBackingInt(props[at]));
}
const Builder = struct {
    a: std.mem.Allocator,
    ast: *const Ast,
    keys: std.ArrayList(Key) = .empty,
    reexports: std.ArrayList(Reexport) = .empty,

    fn addKey(self: *Builder, owner: NodeIndex, key: NodeIndex, role: Role) !void {
        const value = try keyValue(self.a, self.ast, key) orelse return;
        try self.keys.append(self.a, .{ .value = value, .role = role, .value_hash = std.hash.Wyhash.hash(0, value), .owner = try datum(self.a, self.ast, owner), .key = try datum(self.a, self.ast, key) });
    }
    fn requireEdge(self: *Builder, idx: NodeIndex, role: @FieldType(Reexport, "role")) !bool {
        const c = call(self.ast, idx) orelse return false;
        if (!ident(self.ast, c.callee, "require") or c.args.len != 1) return false;
        const literal: NodeIndex = @fromBackingInt(c.args[0]);
        const n = get(self.ast, literal) orelse return false;
        if (n.tag != .string_literal) return false;
        const specifier = try keyValue(self.a, self.ast, literal) orelse return false;
        try self.reexports.append(self.a, .{ .source_node = literal, .call = try datum(self.a, self.ast, idx), .literal = try datum(self.a, self.ast, literal), .specifier = specifier, .specifier_hash = std.hash.Wyhash.hash(0, specifier), .role = role });
        return true;
    }
};

fn sameLexicalIdentifier(ast: *const Ast, left: NodeIndex, right: NodeIndex) bool {
    const l = get(ast, left) orelse return false;
    const r = get(ast, right) orelse return false;
    return (l.tag == .identifier_reference or l.tag == .binding_identifier) and
        (r.tag == .identifier_reference or r.tag == .binding_identifier) and
        std.mem.eql(u8, ast.identifierNameText(l), ast.identifierNameText(r));
}
fn keyedRead(ast: *const Ast, idx: NodeIndex, object: NodeIndex, key: NodeIndex) bool {
    const m = member(ast, idx) orelse return false;
    return m.computed and sameLexicalIdentifier(ast, m.object, object) and sameLexicalIdentifier(ast, m.key, key);
}
fn excludedKey(ast: *const Ast, idx: NodeIndex, key: NodeIndex, literal: []const u8) bool {
    const n = get(ast, idx) orelse return false;
    if (n.tag != .binary_expression or n.data.binary.flags != @backingInt(Kind.eq3) or
        !sameLexicalIdentifier(ast, n.data.binary.left, key)) return false;
    const r = get(ast, n.data.binary.right) orelse return false;
    return r.tag == .string_literal and std.mem.eql(u8, Ast.stripStringQuotes(ast.getText(r.span)), literal);
}
fn babelStarSource(ast: *const Ast, idx: NodeIndex) ?NodeIndex {
    const outer = call(ast, idx) orelse return null;
    if (outer.args.len != 1) return null;
    const foreach = member(ast, outer.callee) orelse return null;
    if (foreach.computed or !ident(ast, foreach.key, "forEach")) return null;
    const keys = call(ast, foreach.object) orelse return null;
    if (!staticMember(ast, keys.callee, "Object", "keys") or keys.args.len != 1) return null;
    const dependency: NodeIndex = @fromBackingInt(keys.args[0]);
    const callback = get(ast, @fromBackingInt(outer.args[0])) orelse return null;
    if (callback.tag != .function_expression) return null;
    const params = ast.functionParams(callback);
    if (params.len != 1) return null;
    const key: NodeIndex = @fromBackingInt(params[0]);
    const body = list(ast, ast.functionBodyBlock(callback) orelse return null, .block_statement) orelse return null;
    if (body.len != 2) return null;
    const guard = ast.nodes.items[body[0]];
    if (guard.tag != .if_statement or !guard.data.ternary.c.isNone()) return null;
    const either = get(ast, guard.data.ternary.a) orelse return null;
    if (either.tag != .logical_expression or either.data.binary.flags != @backingInt(Kind.pipe2) or
        !excludedKey(ast, either.data.binary.left, key, "default") or
        !excludedKey(ast, either.data.binary.right, key, "__esModule")) return null;
    const ret = get(ast, guard.data.ternary.b) orelse return null;
    if (ret.tag != .return_statement or !ret.data.unary.operand.isNone()) return null;
    const stmt = ast.nodes.items[body[1]];
    if (stmt.tag != .expression_statement) return null;
    const value_idx = stmt.data.unary.operand;
    const value = get(ast, value_idx) orelse return null;
    if (value.tag == .assignment_expression and value.data.binary.flags == @backingInt(Kind.eq)) {
        const target = member(ast, value.data.binary.left) orelse return null;
        if (target.computed and host(ast, target.object) and sameLexicalIdentifier(ast, target.key, key) and
            keyedRead(ast, value.data.binary.right, dependency, key)) return dependency;
        return null;
    }
    const define = call(ast, value_idx) orelse return null;
    if (!staticMember(ast, define.callee, "Object", "defineProperty") or define.args.len != 3 or
        !host(ast, @fromBackingInt(define.args[0])) or !sameLexicalIdentifier(ast, @fromBackingInt(define.args[1]), key)) return null;
    const props = list(ast, @fromBackingInt(define.args[2]), .object_expression) orelse return null;
    if (props.len != 2) return null;
    const enumerable = ast.nodes.items[props[0]];
    if (enumerable.tag != .object_property or !ident(ast, enumerable.data.binary.left, "enumerable")) return null;
    const truth = get(ast, enumerable.data.binary.right) orelse return null;
    if (truth.tag != .boolean_literal or !std.mem.eql(u8, ast.getText(truth.span), "true")) return null;
    const getter = ast.nodes.items[props[1]];
    const fn_idx: NodeIndex = if (getter.tag == .object_property and ident(ast, getter.data.binary.left, "get"))
        getter.data.binary.right
    else if (getter.tag == .method_definition and ident(ast, ast.readExtraNode(getter.data.extra, ast_mod.MethodExtra.key), "get"))
        @fromBackingInt(props[1])
    else
        return null;
    const returned = returnedValue(ast, fn_idx) orelse return null;
    return if (keyedRead(ast, returned, dependency, key)) dependency else null;
}

fn captureTopLevelStars(b: *Builder) !void {
    const ast = b.ast;
    const root: NodeIndex = @fromBackingInt(@as(u32, @intCast(ast.nodes.items.len - 1)));
    const statements = list(ast, root, .program) orelse return error.InvalidCjsPublicFacadeKeys;
    // This is a lexical alias table for the frozen Babel grammar, never a
    // binding/SID lookup. Its values are actual original require-call nodes.
    var aliases: std.StringHashMapUnmanaged(NodeIndex) = .empty;
    for (statements) |raw| {
        const statement = ast.nodes.items[raw];
        if (statement.tag != .variable_declaration or !ast.hasExtra(statement.data.extra, 2)) continue;
        const start = ast.readExtra(statement.data.extra, 1);
        const len = ast.readExtra(statement.data.extra, 2);
        if (start > ast.extra_data.items.len or len > ast.extra_data.items.len - start) return error.InvalidCjsPublicFacadeKeys;
        for (ast.extra_data.items[start..][0..len]) |decl_raw| {
            const decl = ast.nodes.items[decl_raw];
            if (decl.tag != .variable_declarator or !ast.hasExtra(decl.data.extra, 2)) continue;
            const name = ast.readExtraNode(decl.data.extra, 0);
            const name_node = get(ast, name) orelse continue;
            if (name_node.tag != .binding_identifier) continue;
            const init = ast.readExtraNode(decl.data.extra, 2);
            const c = call(ast, init) orelse continue;
            if (ident(ast, c.callee, "require") and c.args.len == 1) try aliases.put(b.a, ast.identifierNameText(name_node), init);
        }
    }
    for (statements) |raw| {
        const statement = ast.nodes.items[raw];
        if (statement.tag != .expression_statement) continue;
        const idx = statement.data.unary.operand;
        if (babelStarSource(ast, idx)) |dependency| {
            const n = ast.getNode(dependency);
            if (n.tag == .identifier_reference) if (aliases.get(ast.identifierNameText(n))) |require| {
                _ = try b.requireEdge(require, .star);
            };
        }
        const c = call(ast, idx) orelse continue;
        var is_star = ident(ast, c.callee, "__export") or ident(ast, c.callee, "__exportStar");
        if (member(ast, c.callee)) |m| is_star = is_star or (!m.computed and (ident(ast, m.key, "__export") or ident(ast, m.key, "__exportStar")));
        if (is_star and c.args.len >= 1) _ = try b.requireEdge(@fromBackingInt(c.args[0]), .star);
    }
}

/// Exactly one pass over original parser nodes; bounded local descriptor/list
/// inspection only. The arena owns all keys/proofs. No AST clone or reanalysis.
pub fn capture(a: std.mem.Allocator, module: *const Module, ast: *const Ast) !*const Registry {
    if (!std.mem.eql(u8, ast.source, module.source)) return error.InvalidCjsPublicFacadeKeys;
    var b: Builder = .{ .a = a, .ast = ast };
    var last_assignment: ?struct { start: u32, rhs: NodeIndex } = null;
    for (ast.nodes.items, 0..) |n, raw| {
        const idx: NodeIndex = @fromBackingInt(@as(u32, @intCast(raw)));
        if (n.tag == .assignment_expression and n.data.binary.flags == @backingInt(Kind.eq)) {
            if (member(ast, n.data.binary.left)) |m| {
                if (host(ast, m.object)) {
                    const key = ast.getNode(m.key);
                    if (!m.computed or key.tag == .string_literal) try b.addKey(idx, m.key, .assignment);
                }
            }
            if (staticMember(ast, n.data.binary.left, "module", "exports")) {
                const rhs = n.data.binary.right;
                const rn = get(ast, rhs) orelse continue;
                const direct_require = if (call(ast, rhs)) |c|
                    ident(ast, c.callee, "require") and c.args.len == 1 and
                        (if (get(ast, @fromBackingInt(c.args[0]))) |arg| arg.tag == .string_literal else false)
                else
                    false;
                if (direct_require or rn.tag == .object_expression) {
                    if (last_assignment == null or n.span.start > last_assignment.?.start)
                        last_assignment = .{ .start = n.span.start, .rhs = rhs };
                }
                if (list(ast, rhs, .object_expression)) |props| for (props) |prop_raw| {
                    const p = ast.nodes.items[prop_raw];
                    if (p.tag == .spread_element) continue;
                    if (p.tag != .object_property) break;
                    const value = get(ast, Ast.objectPropertyValue(p)) orelse break;
                    if (value.tag != .identifier_reference and value.tag != .binding_identifier) break;
                    if (try keyValue(a, ast, p.data.binary.left) == null) break;
                    try b.addKey(@fromBackingInt(prop_raw), p.data.binary.left, .object_literal);
                };
            }
        }
        if (call(ast, idx)) |c| {
            if (staticMember(ast, c.callee, "Object", "defineProperty") and c.args.len == 3 and host(ast, @fromBackingInt(c.args[0]))) {
                const key: NodeIndex = @fromBackingInt(c.args[1]);
                const kn = get(ast, key) orelse continue;
                if (kn.tag != .string_literal) continue;
                if (descriptorSupported(ast, @fromBackingInt(c.args[2]))) {
                    try b.addKey(idx, key, .descriptor);
                }
            }
        }
    }
    // Only the last lexical module.exports require/object assignment contributes
    // direct reexport edges (Node's frozen default detection contract).
    if (last_assignment) |last| {
        if (!try b.requireEdge(last.rhs, .direct)) {
            if (list(ast, last.rhs, .object_expression)) |props| for (props) |p_raw| {
                const p = ast.nodes.items[p_raw];
                if (p.tag == .spread_element) _ = try b.requireEdge(p.data.unary.operand, .direct);
            };
        }
    }
    if (ast.nodes.items.len > 0) try captureTopLevelStars(&b);
    var selected: std.ArrayList(Key) = .empty;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    for (b.keys.items) |key| {
        const entry = try seen.getOrPut(a, key.value);
        if (entry.found_existing) continue;
        try selected.append(a, key);
    }
    const registry = try a.create(Registry);
    registry.* = .{ .owner = module.codegen_output_owner, .source = module.source, .path = try a.dupe(u8, module.path), .parse_arena = module.parse_arena, .parser_node_count = ast.nodes.items.len, .direct_keys = try selected.toOwnedSlice(a), .reexports = try b.reexports.toOwnedSlice(a) };
    return registry;
}

const TestSnapshot = struct { module: Module, registry: *const Registry };
fn testSnapshot(a: std.mem.Allocator, source: []const u8) !TestSnapshot {
    var scanner = try @import("../lexer/scanner.zig").Scanner.init(a, source);
    var parser = @import("../parser/parser.zig").Parser.init(a, &scanner);
    _ = try parser.parse();
    try std.testing.expectEqual(@as(usize, 0), parser.errors.items.len);
    var module = Module.init(@fromBackingInt(@as(u32, 0)), "original.cjs");
    module.source = parser.ast.source;
    module.ast = parser.ast;
    module.import_records = (try @import("import_scanner.zig").extractImportsWithCjsDetection(a, &parser.ast)).records;
    const registry = try capture(a, &module, &parser.ast);
    module.cjs_public_facade_keys = registry;
    try registry.validate(&module);
    return .{ .module = module, .registry = registry };
}

test "CJS public facade original parser registry matches native lexical namespace keys" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sources = [_][]const u8{
        "module.exports=42;",
        "module.exports=null;",
        "module.exports=Object.freeze(function answer(){return 42});",
        "exports.answer=42;exports.update=function(){exports.answer=43};",
        "Object.defineProperty(exports,'answer',{value:42,enumerable:true,configurable:false});",
        "var answer=42;Object.defineProperty(exports,'answer',{get:function(){return answer},enumerable:true});exports.update=function(){answer=43};",
        "Object.defineProperty(exports,'__proto__',{value:42,enumerable:true});Object.defineProperty(exports,'__esModule',{value:7,enumerable:true});exports.answer=42;",
        "module.exports={answer:42,['__proto__']:42,__esModule:7};",
        "module.exports=Object.freeze({answer:42});",
        "module.exports=Object.freeze([40,2]);",
        "var value=42;module.exports={answer:value};",
        "(function(exports){exports.shadow=42})({});",
        "(function(Object){Object.defineProperty(exports,'shadow',{value:42})})(Object);",
        "module['exports'].answer=42;",
        "exports['an\\x73wer']=42;exports.\\u0061lias=43;",
        "Object['defineProperty'](exports,'answer',{value:42});",
        "var object={answer:42};Object.defineProperty(exports,'answer',{enumerable:true,get:function(){return object.answer}});",
        "var object={answer:42};Object.defineProperty(exports,'answer',{enumerable:true,get(){return object.answer}});",
        "var object={answer:42};Object.defineProperty(exports,'answer',{enumerable:true,get(){return object.answer}});if(false)Object.defineProperty(exports,'answer',{get(){return 42}});",
    };
    const script =
        "import fs from 'node:fs';import os from 'node:os';import path from 'node:path';import{pathToFileURL}from'node:url';" ++
        "const dir=fs.mkdtempSync(path.join(os.tmpdir(),'zntc-cjs-keys-'));try{const file=path.join(dir,'source.cjs');fs.writeFileSync(file,process.argv[1]);" ++
        "const ns=await import(pathToFileURL(file).href);console.log(JSON.stringify(Object.keys(ns).filter(k=>k!=='default'&&k!=='module.exports')))}finally{fs.rmSync(dir,{recursive:true,force:true})}";
    for (sources) |source| {
        errdefer std.debug.print("CJS lexical registry source={s}\n", .{source});
        const snapshot = try testSnapshot(a, source);
        const native = try std.process.run(a, std.testing.io, .{ .argv = &.{ "node", "--input-type=module", "-e", script, source } });
        try std.testing.expect(native.term == .exited and native.term.exited == 0);
        try std.testing.expectEqualStrings("", native.stderr);
        const actual = try std.json.parseFromSlice(std.json.Value, a, native.stdout, .{});
        try std.testing.expectEqual(snapshot.registry.direct_keys.len, actual.value.array.items.len);
        for (snapshot.registry.direct_keys) |key| {
            var found: usize = 0;
            for (actual.value.array.items) |value| if (std.mem.eql(u8, value.string, key.value)) {
                found += 1;
            };
            try std.testing.expectEqual(@as(usize, 1), found);
        }
    }
}

test "CJS public facade original parser registry cache and owner guards remain exact" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source = "exports.answer=42;module.exports=require('./leaf.cjs');var leaf=require('./other.cjs');Object.keys(leaf).forEach(function(key){if(key==='default'||key==='__esModule')return;Object.defineProperty(exports,key,{enumerable:true,get:function(){return leaf[key]}})});";
    const cold = try testSnapshot(a, source);
    try std.testing.expectEqual(@as(usize, 2), cold.registry.reexports.len);
    try std.testing.expectEqual(@as(usize, 1), cold.registry.direct_keys.len);
    var persistent = cold.module;
    persistent.index = @fromBackingInt(@as(u32, 8));
    try cold.registry.validate(&persistent);
    var foreign = persistent;
    foreign.codegen_output_owner = @import("codegen_output_domain.zig").newOwner();
    try std.testing.expectError(error.InvalidCjsPublicFacadeKeys, cold.registry.validate(&foreign));
    foreign = persistent;
    foreign.source = try a.dupe(u8, source);
    try std.testing.expectError(error.InvalidCjsPublicFacadeKeys, cold.registry.validate(&foreign));
    foreign = persistent;
    foreign.parse_arena = &arena;
    try std.testing.expectError(error.InvalidCjsPublicFacadeKeys, cold.registry.validate(&foreign));
    foreign = persistent;
    foreign.path = "foreign.cjs";
    try std.testing.expectError(error.InvalidCjsPublicFacadeKeys, cold.registry.validate(&foreign));
    var poisoned = cold.registry.*;
    const keys = try a.dupe(Key, poisoned.direct_keys);
    poisoned.direct_keys = keys;
    keys[0].role = .descriptor;
    try std.testing.expectError(error.InvalidCjsPublicFacadeKeys, poisoned.validate(&persistent));
    keys[0] = cold.registry.direct_keys[0];
    keys[0].value = "foreign";
    try std.testing.expectError(error.InvalidCjsPublicFacadeKeys, poisoned.validate(&persistent));
    foreign = persistent;
    const imports = try a.dupe(@import("types.zig").ImportRecord, foreign.import_records);
    foreign.import_records = imports;
    imports[0].source_node = .none;
    try std.testing.expectError(error.InvalidCjsPublicFacadeKeys, cold.registry.validate(&foreign));
    foreign = persistent;
    const duplicate_imports = try a.alloc(@import("types.zig").ImportRecord, persistent.import_records.len + 1);
    @memcpy(duplicate_imports[0..persistent.import_records.len], persistent.import_records);
    duplicate_imports[persistent.import_records.len] = persistent.import_records[0];
    foreign.import_records = duplicate_imports;
    try std.testing.expectError(error.InvalidCjsPublicFacadeKeys, cold.registry.validate(&foreign));

    var bytes: std.ArrayList(u8) = .empty;
    try @import("../parser/ast_codec.zig").serialize(&cold.module.ast.?, &bytes, a);
    const decoded = try @import("../parser/ast_codec.zig").deserialize(bytes.items, a);
    var warm = Module.init(@fromBackingInt(@as(u32, 19)), "original.cjs");
    // A decoder's original AST source has a different backing from the load
    // producer's winning source; exact bytes authenticate that initial view.
    warm.source = try a.dupe(u8, source);
    warm.ast = decoded;
    warm.import_records = (try @import("import_scanner.zig").extractImportsWithCjsDetection(a, &decoded)).records;
    const restored = try capture(a, &warm, &decoded);
    warm.cjs_public_facade_keys = restored;
    try restored.validate(&warm);
    try std.testing.expectError(error.InvalidCjsPublicFacadeKeys, cold.registry.validate(&warm));
    try std.testing.expectEqual(cold.registry.direct_keys.len, restored.direct_keys.len);
    try std.testing.expectEqual(cold.registry.reexports.len, restored.reexports.len);
    for (cold.registry.reexports, restored.reexports) |before, after| {
        try std.testing.expectEqual(before.source_node, after.source_node);
        try std.testing.expectEqualStrings(before.specifier, after.specifier);
    }
}

fn allocationProbe(allocator: std.mem.Allocator, module: *const Module) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    _ = try capture(arena.allocator(), module, &module.ast.?);
}
test "CJS public facade original parser registry capture propagates allocation failure" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const fixture = try testSnapshot(arena.allocator(), "exports.answer=42;Object.defineProperty(exports,'other',{value:43});module.exports=require('./leaf.cjs');");
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationProbe, .{&fixture.module});
}
