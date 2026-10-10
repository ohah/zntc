//! Static renames for parameter initializers that are moved into an ES5 body.
//!
//! Parameter expressions run before the body's var/function environment exists.
//! Keep distinct source SymbolIds distinct after lowering: a body binding must not
//! intercept an outer read/write, and a body function must not be overwritten by
//! the initialization of a same-named destructuring/default/rest parameter.
//!
//! Shared parameter/body-var identities are split before block renaming when a
//! parameter initializer actually references the parameter. Dynamic eval/with
//! still require an explicit parameter/body scope model.

const std = @import("std");
const ast_mod = @import("../parser/ast.zig");
const ast_walk = @import("../parser/ast_walk.zig");
const ScopeId = @import("../semantic/scope.zig").ScopeId;
const Scope = @import("../semantic/scope.zig").Scope;
const Symbol = @import("../semantic/symbol.zig").Symbol;
const Table = @import("block_rename_table.zig").Table;
const es_helpers = @import("es_helpers.zig");

fn symbolsOf(self: anytype) []const Symbol {
    if (self.semantic_editor) |*editor| return editor.symbols.items;
    return self.symbols;
}

fn scopesOf(self: anytype) []const Scope {
    if (self.semantic_editor) |*editor| return editor.scopes.items;
    return self.scopes;
}

fn scopeMapsOf(self: anytype) []const std.StringHashMapUnmanaged(usize) {
    if (self.semantic_editor) |*editor| return editor.scope_maps.items;
    return self.scope_maps;
}

fn scopeOwnersOf(self: anytype) *const std.AutoHashMapUnmanaged(u32, u32) {
    if (self.semantic_editor) |*editor| return &editor.scope_owner_map;
    return &self.scope_owner_map;
}

fn functionParamsNode(self: anytype, function_raw: u32) ?u32 {
    if (function_raw >= self.ast.nodes.items.len) return null;
    const function = self.ast.nodes.items[function_raw];
    const slot: u32 = switch (function.tag) {
        .arrow_function_expression => 0,
        .function_declaration, .function_expression, .function, .method_definition => 1,
        else => return null,
    };
    if (!self.ast.hasExtra(function.data.extra, slot)) return null;
    const raw = self.ast.extra_data.items[function.data.extra + slot];
    if (raw == @intFromEnum(ast_mod.NodeIndex.none) or raw >= self.ast.nodes.items.len) return null;
    return raw;
}

/// The analyzer intentionally unifies a simple parameter with a body `var`.
/// For a non-simple parameter list that is lowered to ES5, however, parameter
/// initializers and the body have separate environments. Split only identities
/// that are actually referenced from the parameter list, then keep the body
/// `var` on the source identity and give the parameter side a fresh SID.
pub fn splitMergedParameterBodyVars(self: anytype) std.mem.Allocator.Error!Table {
    var split_parameters: Table = .empty;
    errdefer split_parameters.deinit(self.allocator);
    if (!self.options.unsupported.default_params or !self.semantic_edit_enabled or self.scopes.len == 0) return split_parameters;

    const Self = @TypeOf(self.*);
    const Params = @import("es2015_params.zig").ES2015Params(Self);
    const source_symbols = symbolsOf(self);
    const scopes = scopesOf(self);
    var reserved: std.StringHashMapUnmanaged(void) = .empty;
    defer reserved.deinit(self.allocator);
    for (source_symbols) |symbol| try reserveIdentifier(self, &reserved, self.ast.getText(symbol.name));
    if (self.unresolved_references) |unresolved| {
        var names = unresolved.keyIterator();
        while (names.next()) |name| try reserveIdentifier(self, &reserved, name.*);
    }
    for (self.ast.nodes.items) |node| switch (node.tag) {
        .binding_identifier, .identifier_reference, .assignment_target_identifier, .jsx_identifier => try reserveIdentifier(self, &reserved, self.ast.identifierNameText(node)),
        else => {},
    };

    const semantic_edit = @import("transformer/semantic_edit.zig");
    // Splitting appends synthetic binding nodes to the AST. Iterate stable
    // indices and reload each node so a nodes.items reallocation cannot leave
    // this traversal holding a stale slice pointer.
    const original_node_count = self.ast.nodes.items.len;
    for (0..original_node_count) |function_raw| {
        const function = self.ast.nodes.items[function_raw];
        const params = self.ast.functionParamsList(function);
        if (params.len == 0 or !Params.hasDefaultOrRest(self, params)) continue;
        const scope_raw = self.scope_owner_map.get(@intCast(function_raw)) orelse continue;
        if (scope_raw >= scopes.len) continue;
        const function_scope: ScopeId = @enumFromInt(scope_raw);
        const scope = scopes[scope_raw];
        if (scope.kind != .function or scope.blocksMangling()) continue;
        const body = self.ast.functionBodyBlock(function) orelse continue;

        var body_vars: std.AutoHashMapUnmanaged(u32, @import("../lexer/token.zig").Span) = .empty;
        defer body_vars.deinit(self.allocator);
        const body_nodes = try @import("../parser/ast_walk.zig").collectReachableNodeIndicesFrom(self.allocator, self.ast, body);
        defer self.allocator.free(body_nodes);
        for (body_nodes) |raw| {
            if (raw >= self.ast.nodes.items.len) continue;
            const declaration = self.ast.nodes.items[raw];
            if (declaration.tag != .variable_declaration or self.ast.variableDeclarationKind(declaration) != .@"var") continue;
            const extra = declaration.data.extra;
            if (extra + 2 >= self.ast.extra_data.items.len) continue;
            const start = self.ast.extra_data.items[extra + 1];
            const len = self.ast.extra_data.items[extra + 2];
            if (start > self.ast.extra_data.items.len or len > self.ast.extra_data.items.len - start) continue;
            for (self.ast.extra_data.items[start .. start + len]) |raw_declarator| {
                const declarator: @import("../parser/ast.zig").NodeIndex = @enumFromInt(raw_declarator);
                if (declarator.isNone() or @intFromEnum(declarator) >= self.ast.nodes.items.len) continue;
                const declarator_node = self.ast.getNode(declarator);
                if (declarator_node.tag != .variable_declarator or declarator_node.data.extra >= self.ast.extra_data.items.len) continue;
                const pattern: @import("../parser/ast.zig").NodeIndex = @enumFromInt(self.ast.extra_data.items[declarator_node.data.extra]);
                if (pattern.isNone()) continue;
                var bindings = try @import("../parser/ast_walk.zig").bindingIdentifiers(self.allocator, self.ast, pattern, .{});
                defer bindings.deinit();
                while (try bindings.next()) |binding| {
                    const id = self.getSymbolIdAt(binding) orelse continue;
                    const symbols = symbolsOf(self);
                    if (id >= symbols.len or symbols[id].scope_id != function_scope) continue;
                    if (symbols[id].kind != .parameter and symbols[id].kind != .variable_var) continue;
                    const entry = try body_vars.getOrPut(self.allocator, id);
                    if (!entry.found_existing) entry.value_ptr.* = self.ast.getNode(binding).span;
                }
            }
        }
        if (body_vars.count() == 0) continue;

        var parameter_refs: std.ArrayList(@import("../parser/ast.zig").NodeIndex) = .empty;
        defer parameter_refs.deinit(self.allocator);
        var referenced_shared_ids: std.AutoHashMapUnmanaged(u32, void) = .empty;
        defer referenced_shared_ids.deinit(self.allocator);
        for (self.ast.extra_data.items[params.start .. params.start + params.len]) |raw_param| {
            const param: @import("../parser/ast.zig").NodeIndex = @enumFromInt(raw_param);
            const refs = try @import("../semantic/reference_walk.zig").collectIdentifierReferences(self.allocator, self.ast, param);
            defer self.allocator.free(refs);
            for (refs) |reference| {
                try parameter_refs.append(self.allocator, reference);
                const id = self.getSymbolIdAt(reference) orelse continue;
                if (body_vars.contains(id)) try referenced_shared_ids.put(self.allocator, id, {});
            }
        }

        var split_by_source: std.AutoHashMapUnmanaged(u32, u32) = .empty;
        defer split_by_source.deinit(self.allocator);
        for (self.ast.extra_data.items[params.start .. params.start + params.len]) |raw_param| {
            const param: @import("../parser/ast.zig").NodeIndex = @enumFromInt(raw_param);
            var bindings = try @import("../parser/ast_walk.zig").bindingIdentifiers(self.allocator, self.ast, param, .{});
            defer bindings.deinit();
            while (try bindings.next()) |binding| {
                const source_id = self.getSymbolIdAt(binding) orelse continue;
                if (!referenced_shared_ids.contains(source_id) or split_by_source.contains(source_id)) continue;
                const body_var_span = body_vars.get(source_id) orelse continue;
                const alias_name = try freshParameterAlias(self, &reserved);
                const alias_span = try self.ast.addString(alias_name);
                const maybe_parameter_id = try semantic_edit.splitParameterBodyVarBinding(
                    self,
                    binding,
                    source_id,
                    alias_span,
                    body_var_span,
                );
                const parameter_id = maybe_parameter_id orelse continue;
                try split_by_source.put(self.allocator, source_id, @intFromEnum(parameter_id));
                try split_parameters.put(self.allocator, @intFromEnum(parameter_id), {});
                try self.parameter_body_var_copies.append(self.allocator, .{
                    .function_scope = function_scope,
                    .body_var_symbol_id = source_id,
                    .parameter_symbol_id = @intFromEnum(parameter_id),
                    .source_span = body_var_span,
                });
            }
        }

        var split_iter = split_by_source.iterator();
        while (split_iter.next()) |entry| {
            const source_id = entry.key_ptr.*;
            const parameter_id: @import("../semantic/symbol.zig").SymbolId = @enumFromInt(entry.value_ptr.*);
            for (parameter_refs.items) |reference| {
                if (self.getSymbolIdAt(reference) != source_id) continue;
                try semantic_edit.rebindParameterBodyVarReference(self, reference, parameter_id);
            }
        }
    }
    return split_parameters;
}

fn reserveIdentifier(self: anytype, reserved: *std.StringHashMapUnmanaged(void), name: []const u8) std.mem.Allocator.Error!void {
    const canonical = try canonicalIdentifier(self.allocator, name);
    try reserved.put(self.allocator, canonical, {});
}

fn freshParameterAlias(self: anytype, reserved: *std.StringHashMapUnmanaged(void)) std.mem.Allocator.Error![]const u8 {
    var suffix: usize = 0;
    while (true) : (suffix += 1) {
        const candidate = try std.fmt.allocPrint(self.allocator, "__zntc_param_env_{d}", .{suffix});
        const canonical = try canonicalIdentifier(self.allocator, candidate);
        if (reserved.contains(canonical)) continue;
        try reserved.put(self.allocator, canonical, {});
        return candidate;
    }
}

fn canonicalIdentifier(allocator: std.mem.Allocator, name: []const u8) std.mem.Allocator.Error![]const u8 {
    if (std.mem.indexOfScalar(u8, name, '\\') == null) return name;
    var decoded: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < name.len) {
        const cp = @import("cooked_name.zig").nextCookedCp(name, &i) orelse return name;
        var bytes: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(cp, &bytes) catch return name;
        try decoded.appendSlice(allocator, bytes[0..len]);
    }
    return decoded.toOwnedSlice(allocator);
}

pub fn collectRenames(self: anytype) std.mem.Allocator.Error!Table {
    var result: Table = .empty;
    errdefer result.deinit(self.allocator);
    if (!self.options.unsupported.default_params) return result;
    const params_mod = @import("es2015_params.zig").ES2015Params(@TypeOf(self.*));
    const symbols = symbolsOf(self);
    const scopes = scopesOf(self);
    const scope_maps = scopeMapsOf(self);
    const scope_owners = scopeOwnersOf(self);
    for (self.ast.nodes.items, 0..) |node, raw| {
        const params = self.ast.functionParamsList(node);
        if (params.len == 0 or !params_mod.hasDefaultOrRest(self, params)) continue;
        const scope_raw = scope_owners.get(@intCast(raw)) orelse continue;
        if (scope_raw >= scopes.len or scope_raw >= scope_maps.len) continue;
        const scope = scopes[scope_raw];
        if (scope.kind != .function or scope.blocksMangling()) continue;
        const scope_id: ScopeId = @enumFromInt(scope_raw);
        const parameter_scope_raw = if (functionParamsNode(self, @intCast(raw))) |params_raw|
            scope_owners.get(params_raw) orelse scope_raw
        else
            scope_raw;
        if (parameter_scope_raw >= scopes.len or parameter_scope_raw >= scope_maps.len) continue;
        const parameter_scope: ScopeId = @enumFromInt(parameter_scope_raw);
        if (scopes[parameter_scope_raw].blocksMangling()) continue;
        for (self.ast.extra_data.items[params.start .. params.start + params.len]) |param| {
            var bindings = try ast_walk.bindingIdentifiers(self.allocator, self.ast, @enumFromInt(param), .{});
            defer bindings.deinit();
            while (try bindings.next()) |binding| {
                const parameter_id = self.getSymbolIdAt(binding) orelse continue;
                if (parameter_id >= symbols.len) continue;
                const parameter = symbols[parameter_id];
                if (parameter.kind != .parameter or parameter.scope_id != parameter_scope) continue;
                const name = self.ast.getText(parameter.name);
                if (scope_maps[scope_raw].get(name)) |body_id| {
                    if (body_id < symbols.len and body_id != parameter_id and symbols[body_id].kind.isFunctionLike())
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
                    id < symbols.len and isAncestor(scopes, symbols[id].scope_id, scope.parent)
                else if (self.unresolved_references) |unresolved|
                    unresolved.contains(name)
                else
                    false;
                if (!is_outer) continue;
                if (scope_maps[scope_raw].get(name)) |body_id| {
                    if (body_id >= symbols.len) continue;
                    const kind = symbols[body_id].kind;
                    if (kind == .variable_var or kind == .variable_let or kind == .variable_const or kind == .class_decl) {
                        try result.put(self.allocator, @intCast(body_id), {});
                    } else if (symbols[body_id].kind.isFunctionLike()) {
                        // Repeated declarations can leave historical symbols
                        // with no AST binding. Rename only identities attached
                        // to actual function names, never those orphan records.
                        for (self.ast.nodes.items) |declaration| {
                            if (declaration.tag != .function_declaration) continue;
                            const binding = self.ast.readExtraNode(declaration.data.extra, 0);
                            const id = self.getSymbolIdAt(binding) orelse continue;
                            if (id >= symbols.len) continue;
                            const symbol = symbols[id];
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
    const symbols = symbolsOf(self);
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
            if (id < symbols.len) try self.parameter_inferred_names.put(self.allocator, @intFromEnum(root), symbols[id].name);
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
    const symbols = symbolsOf(self);
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
        if (id >= symbols.len or !symbols[id].kind.isFunctionLike()) continue;
        self.ast.extra_data.items[declaration.data.extra + ast_mod.FunctionExtra.flags] |= ast_mod.FunctionFlags.name_preserved;
        if (named.contains(id)) continue;
        try named.put(self.allocator, id, {});
        const scope = symbols[id].scope_id;
        const saved_scope = self.current_scope;
        self.current_scope = scope;
        defer self.current_scope = saved_scope;
        const ref = try self.makeUserRefNamed(alias, binding);
        const span: @import("../lexer/token.zig").Span = .{ .start = declaration.span.start, .end = declaration.span.start };
        const call = try nameValue(self, ref, symbols[id].name, span);
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
