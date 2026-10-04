//! Static renames for parameter initializers that are moved into an ES5 body.
//!
//! Parameter expressions run before the body's var/function environment exists.
//! Keep distinct source SymbolIds distinct after lowering: a body binding must not
//! intercept an outer read/write, and a body function must not be overwritten by
//! the initialization of a same-named destructuring/default/rest parameter.
//!
//! This does not split a parameter and body var that the analyzer represents by
//! one SymbolId, or model dynamic eval/with environments. Those require an
//! explicit parameter/body scope model rather than a spelling-based repair.

const std = @import("std");
const ast_mod = @import("../parser/ast.zig");
const ast_walk = @import("../parser/ast_walk.zig");
const ScopeId = @import("../semantic/scope.zig").ScopeId;
const Table = @import("block_rename_table.zig").Table;
const es_helpers = @import("es_helpers.zig");

pub fn collectRenames(self: anytype) std.mem.Allocator.Error!Table {
    var result: Table = .empty;
    errdefer result.deinit(self.allocator);
    if (!self.options.unsupported.default_params) return result;
    const params_mod = @import("es2015_params.zig").ES2015Params(@TypeOf(self.*));
    for (self.ast.nodes.items, 0..) |node, raw| {
        const params = self.ast.functionParamsList(node);
        if (params.len == 0 or !params_mod.hasDefaultOrRest(self, params)) continue;
        const scope_raw = self.scope_owner_map.get(@intCast(raw)) orelse continue;
        const scope = self.scopes[scope_raw];
        if (scope.kind != .function or scope.blocksMangling()) continue;
        const scope_id: ScopeId = @enumFromInt(scope_raw);
        for (self.ast.extra_data.items[params.start .. params.start + params.len]) |param| {
            var bindings = try ast_walk.bindingIdentifiers(self.allocator, self.ast, @enumFromInt(param), .{});
            defer bindings.deinit();
            while (try bindings.next()) |binding| {
                const parameter_id = self.getSymbolIdAt(binding) orelse continue;
                const parameter = self.symbols[parameter_id];
                if (parameter.kind != .parameter or parameter.scope_id != scope_id) continue;
                const name = self.ast.getText(parameter.name);
                if (self.scope_maps[scope_raw].get(name)) |body_id| {
                    if (body_id != parameter_id and self.symbols[body_id].kind.isFunctionLike())
                        try result.put(self.allocator, parameter_id, {});
                }
            }
            // Use the existing edge-aware walker: static property names,
            // labels and binding keys also carry identifier tags but do not
            // read a binding. Debug-only unresolved-node sets are insufficient
            // for production standalone and bundler transforms.
            const refs = try @import("../semantic/reference_walk.zig").collectIdentifierReferences(self.allocator, self.ast, @enumFromInt(param));
            defer self.allocator.free(refs);
            for (refs) |ref| {
                const sid = self.getSymbolIdAt(ref);
                const name = self.ast.getText(self.ast.getNode(ref).data.string_ref);
                const is_outer = if (sid) |id|
                    isAncestor(self.scopes, self.symbols[id].scope_id, scope.parent)
                else if (self.unresolved_references) |unresolved|
                    unresolved.contains(name)
                else
                    false;
                if (!is_outer) continue;
                if (self.scope_maps[scope_raw].get(name)) |body_id| {
                    const kind = self.symbols[body_id].kind;
                    if (kind == .variable_var or kind == .variable_let or kind == .variable_const or kind == .class_decl) {
                        try result.put(self.allocator, @intCast(body_id), {});
                    } else if (self.symbols[body_id].kind.isFunctionLike()) {
                        // Repeated declarations can leave historical symbols
                        // with no AST binding. Rename only identities attached
                        // to actual function names, never those orphan records.
                        for (self.ast.nodes.items) |declaration| {
                            if (declaration.tag != .function_declaration) continue;
                            const binding = self.ast.readExtraNode(declaration.data.extra, 0);
                            const id = self.getSymbolIdAt(binding) orelse continue;
                            const symbol = self.symbols[id];
                            if (symbol.scope_id == scope_id and symbol.kind.isFunctionLike() and
                                std.mem.eql(u8, self.ast.getText(symbol.name), name))
                                try result.put(self.allocator, @intCast(id), {});
                        }
                    }
                }
            }
        }
    }
    return result;
}

/// NamedEvaluation uses the source binding spelling, not its emitted alias.
/// Record the exact RHS roots before visiting; this also covers destructuring
/// defaults and logical assignments whose visitors lower the parent directly.
pub fn collectInferredNames(self: anytype, renames: *const Table) std.mem.Allocator.Error!void {
    if (renames.count() == 0) return;
    for (self.ast.nodes.items) |node| {
        const pair: [2]ast_mod.NodeIndex = switch (node.tag) {
            .variable_declarator, .formal_parameter => .{
                @enumFromInt(self.ast.extra_data.items[node.data.extra]),
                @enumFromInt(self.ast.extra_data.items[node.data.extra + 2]),
            },
            .assignment_pattern => .{ node.data.binary.left, node.data.binary.right },
            .assignment_expression => blk: {
                const op: @import("../lexer/token.zig").Kind = @enumFromInt(node.data.binary.flags);
                if (op != .eq and op != .question2_eq and op != .amp2_eq and op != .pipe2_eq) continue;
                break :blk .{ node.data.binary.left, node.data.binary.right };
            },
            else => continue,
        };
        if (pair[0].isNone() or pair[1].isNone()) continue;
        const binding = self.ast.getNode(pair[0]);
        if (binding.tag != .binding_identifier and binding.tag != .assignment_target_identifier and binding.tag != .identifier_reference) continue;
        const id = self.getSymbolIdAt(pair[0]) orelse continue;
        if (!renames.contains(id)) continue;
        var value_root = pair[1];
        var value = self.ast.getNode(value_root);
        while (value.tag == .parenthesized_expression or ast_mod.Node.Tag.isTransparentTypeWrapper(value.tag)) {
            value_root = value.data.unary.operand;
            value = self.ast.getNode(value.data.unary.operand);
        }
        const anonymous = switch (value.tag) {
            .arrow_function_expression => true,
            .function, .function_expression => self.ast.readExtraNode(value.data.extra, 0).isNone(),
            .class_expression => self.ast.readExtraNode(value.data.extra, ast_mod.ClassExtra.name).isNone(),
            else => false,
        };
        if (anonymous) {
            // Class static initialization must see NamedEvaluation first.
            // Its lowering consumes this exact class node inside the IIFE.
            const root = if (value.tag == .class_expression and self.options.unsupported.class) value_root else pair[1];
            try self.parameter_inferred_names.put(self.allocator, @intFromEnum(root), self.symbols[id].name);
        }
    }
}

/// A helper call preserves the inferred name without introducing a named
/// function-expression binding (which would intercept recursive outer reads).
/// Unlike an object-literal naming wrapper this also handles `__proto__` and
/// functions/classes that lowered to a capture-factory call or class IIFE.
pub fn preserveInferredName(self: anytype, source: ast_mod.NodeIndex, output: ast_mod.NodeIndex) std.mem.Allocator.Error!ast_mod.NodeIndex {
    if (output.isNone()) return output;
    const name = self.parameter_inferred_names.get(@intFromEnum(source)) orelse return output;
    return nameValue(self, output, name, self.ast.getNode(source).span);
}

fn nameValue(self: anytype, value: ast_mod.NodeIndex, name: @import("../lexer/token.zig").Span, span: @import("../lexer/token.zig").Span) std.mem.Allocator.Error!ast_mod.NodeIndex {
    self.runtime_helpers.keep_names = true;
    const callee = try es_helpers.makeRuntimeHelperRef(self, "__name");
    const string = try es_helpers.buildQuotedKeyLiteral(self, name);
    return es_helpers.makeCallExpr(self, callee, &.{ value, string }, span);
}

/// Restore the anonymous constructor's inferred name before its static
/// elements execute. Consuming the hint prevents an outer wrapper from
/// overwriting a user-defined static `name` field/getter/block afterwards.
pub fn takeClassNameStatement(self: anytype, source: ast_mod.NodeIndex, binding: ast_mod.NodeIndex, constructor: ast_mod.NodeIndex, scope: ScopeId) std.mem.Allocator.Error!?ast_mod.NodeIndex {
    const raw = @intFromEnum(source);
    const key = if (self.parameter_inferred_names.contains(raw)) raw else self.scope_owner_origins.get(raw) orelse return null;
    const name = self.parameter_inferred_names.get(key) orelse return null;
    const saved_scope = self.current_scope;
    self.current_scope = scope;
    defer self.current_scope = saved_scope;
    const ref = try self.makeUserRefNamed(self.ast.getText(self.ast.getNode(binding).data.string_ref), binding);
    const span = self.ast.getNode(source).span;
    const statement = try es_helpers.makeExprStmt(self, try nameValue(self, ref, name, span), span);
    self.ast.extra_data.items[self.ast.getNode(constructor).data.extra + ast_mod.FunctionExtra.flags] |= ast_mod.FunctionFlags.name_preserved;
    _ = self.parameter_inferred_names.remove(key);
    return statement;
}

/// A hoisted function can be read before its textual declaration, including
/// from an early return. Restore its source name at body entry. This runs
/// before Pass 2, so parameter initializers will still execute first.
pub fn prependBodyFunctionNames(self: anytype, root: ast_mod.NodeIndex) std.mem.Allocator.Error!void {
    const renames = if (self.block_rename_map) |*map| map else return;
    if (renames.count() == 0) return;
    const reachable = try ast_walk.collectReachableNodeIndicesFrom(self.allocator, self.ast, root);
    defer self.allocator.free(reachable);
    var by_scope: std.AutoHashMapUnmanaged(u32, std.ArrayList(ast_mod.NodeIndex)) = .empty;
    var named: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer named.deinit(self.allocator);
    defer {
        var lists = by_scope.valueIterator();
        while (lists.next()) |list| list.deinit(self.allocator);
        by_scope.deinit(self.allocator);
    }
    for (reachable) |raw| {
        const declaration = self.ast.getNode(@enumFromInt(raw));
        if (declaration.tag != .function_declaration) continue;
        const binding = self.ast.readExtraNode(declaration.data.extra, 0);
        const id = self.getSymbolIdAt(binding) orelse continue;
        const alias = renames.get(id) orelse continue;
        if (id >= self.symbols.len or !self.symbols[id].kind.isFunctionLike()) continue;
        self.ast.extra_data.items[declaration.data.extra + ast_mod.FunctionExtra.flags] |= ast_mod.FunctionFlags.name_preserved;
        if (named.contains(id)) continue;
        try named.put(self.allocator, id, {});
        const symbols = if (self.semantic_editor) |*editor| editor.symbols.items else self.symbols;
        const scope = symbols[id].scope_id;
        const saved_scope = self.current_scope;
        self.current_scope = scope;
        defer self.current_scope = saved_scope;
        const ref = try self.makeUserRefNamed(alias, binding);
        const span: @import("../lexer/token.zig").Span = .{ .start = declaration.span.start, .end = declaration.span.start };
        const call = try nameValue(self, ref, self.symbols[id].name, span);
        const entry = try by_scope.getOrPut(self.allocator, @intFromEnum(scope));
        if (!entry.found_existing) entry.value_ptr.* = .empty;
        try entry.value_ptr.append(self.allocator, try es_helpers.makeExprStmt(self, call, span));
    }
    for (reachable) |raw| {
        const function = self.ast.getNode(@enumFromInt(raw));
        const scope = self.outputOwnedScope(@enumFromInt(raw)) orelse continue;
        const statements = by_scope.get(@intFromEnum(scope)) orelse continue;
        const body = self.ast.functionBodyBlock(function) orelse continue;
        const body_node = self.ast.getNode(body);
        if (body_node.tag != .block_statement and body_node.tag != .function_body) continue;
        const named_body = try self.prependStatementsToBody(body, statements.items);
        const body_slot: u32 = if (function.tag == .arrow_function_expression) 1 else 2;
        self.ast.extra_data.items[function.data.extra + body_slot] = @intFromEnum(named_body);
    }
}

fn isAncestor(scopes: []const @import("../semantic/scope.zig").Scope, target: ScopeId, start: ScopeId) bool {
    var current = start;
    while (!current.isNone()) {
        if (current == target) return true;
        current = scopes[current.toIndex()].parent;
    }
    return false;
}
