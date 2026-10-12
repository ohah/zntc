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
const Scanner = @import("../lexer/scanner.zig").Scanner;

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

/// Dynamic lookup in a parameter expression is distinct from a body `eval`:
/// the analyzer propagates body flags to the parameter scope's ancestors.
pub fn parameterListHasDynamicLookup(self: anytype, params: ast_mod.NodeList) std.mem.Allocator.Error!bool {
    for (self.ast.extra_data.items[params.start .. params.start + params.len]) |raw_param| {
        if (try nodeHasDynamicLookup(self, @enumFromInt(raw_param))) return true;
    }
    return false;
}

/// Find dynamic lookup without relying on the optional semantic graph. This is
/// also used to fail closed in semantic-less transformer entry points, where a
/// moved parameter initializer cannot be isolated from body `var` bindings.
pub fn nodeHasDynamicLookup(self: anytype, root: ast_mod.NodeIndex) std.mem.Allocator.Error!bool {
    if (root.isNone() or @intFromEnum(root) >= self.ast.nodes.items.len) return false;
    const reachable = try ast_walk.collectReachableNodeIndicesFrom(self.allocator, self.ast, root);
    defer self.allocator.free(reachable);
    for (reachable) |raw| {
        if (raw >= self.ast.nodes.items.len) continue;
        const node = self.ast.nodes.items[raw];
        if (node.tag == .with_statement) return true;
        if (node.tag != .call_expression) continue;
        var callee_idx = self.ast.readExtraNode(node.data.extra, 0);
        while (!callee_idx.isNone() and @intFromEnum(callee_idx) < self.ast.nodes.items.len) {
            const callee = self.ast.getNode(callee_idx);
            if (callee.tag == .parenthesized_expression) {
                callee_idx = callee.data.unary.operand;
                continue;
            }
            if (callee.tag != .identifier_reference) break;
            const raw_name = self.ast.identifierNameText(callee);
            if (std.mem.eql(u8, raw_name, "eval")) return true;
            if (std.mem.indexOfScalar(u8, raw_name, '\\') != null) {
                var decode_buffer: [64]u8 = undefined;
                const decoded_name = Scanner.decodeIdentifierEscapesInto(raw_name, &decode_buffer) orelse break;
                if (std.mem.eql(u8, decoded_name, "eval")) return true;
            }
            break;
        }
    }
    return false;
}

pub fn functionBodyHasDynamicLookup(self: anytype, function_scope: ScopeId, body: ast_mod.NodeIndex) std.mem.Allocator.Error!bool {
    const scopes = scopesOf(self);
    if (!function_scope.isNone() and function_scope.toIndex() < scopes.len) {
        const scope = scopes[function_scope.toIndex()];
        if (scope.subtree_has_direct_eval or scope.subtree_has_with) return true;
    }
    return nodeHasDynamicLookup(self, body);
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
    if ((!self.options.unsupported.default_params and !self.options.unsupported.object_spread) or
        !self.semantic_edit_enabled or self.scopes.len == 0) return split_parameters;

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
        if (scope.kind != .function) continue;

        const body_dynamic_lookup = scope.subtree_has_direct_eval or scope.subtree_has_with;
        const parameter_dynamic_lookup = try parameterListHasDynamicLookup(self, params);
        const raw_flags = if (function.data.extra + ast_mod.FunctionExtra.flags < self.ast.extra_data.items.len)
            self.ast.extra_data.items[function.data.extra + ast_mod.FunctionExtra.flags]
        else
            0;
        const function_flags = if (function.tag == .method_definition)
            ast_mod.methodFlagsToFunctionFlags(raw_flags)
        else
            raw_flags;
        const can_wrap_dynamic_body = !self.options.unsupported.arrow and
            ((function_flags & ast_mod.FunctionFlags.is_async) == 0 or !self.options.unsupported.async_await) and
            (function_flags & ast_mod.FunctionFlags.is_generator) == 0;
        // The body wrapper gives body vars their own dynamic-eval environment.
        // Only split shared parameter/body identities when parameter expressions
        // themselves are statically nameable and that wrapper will be emitted.
        const split_dynamic_body_vars = body_dynamic_lookup and !parameter_dynamic_lookup and can_wrap_dynamic_body;
        if (scope.blocksMangling() and !split_dynamic_body_vars) continue;
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
        if (split_dynamic_body_vars) {
            var body_var_ids = body_vars.keyIterator();
            while (body_var_ids.next()) |id| try referenced_shared_ids.put(self.allocator, id.*, {});
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

        // A parameter expression gives the parameters their own environment, so a
        // same-named body `var` is a separate binding that starts with the
        // parameter's value (FunctionDeclarationInstantiation). Lowering moves
        // both into one ES5 function scope, so copy that value explicitly (#5452).
        {
            const current_symbols = symbolsOf(self);
            const current_scope_maps = scopeMapsOf(self);
            for (self.ast.extra_data.items[params.start .. params.start + params.len]) |raw_param| {
                const param: @import("../parser/ast.zig").NodeIndex = @enumFromInt(raw_param);
                var bindings = try @import("../parser/ast_walk.zig").bindingIdentifiers(self.allocator, self.ast, param, .{});
                defer bindings.deinit();
                while (try bindings.next()) |binding| {
                    const parameter_raw = self.getSymbolIdAt(binding) orelse continue;
                    if (parameter_raw >= current_symbols.len or scope_raw >= current_scope_maps.len) continue;
                    const parameter = current_symbols[parameter_raw];
                    if (parameter.kind != .parameter) continue;
                    const name = self.ast.getText(parameter.name);
                    const body_raw = current_scope_maps[scope_raw].get(name) orelse continue;
                    if (body_raw >= current_symbols.len) continue;
                    const body_id: u32 = @intCast(body_raw);
                    const body_var_span = body_vars.get(body_id) orelse continue;
                    if (body_id == parameter_raw or
                        current_symbols[body_raw].scope_id != function_scope) continue;

                    try split_parameters.put(self.allocator, parameter_raw, {});
                    const already_copied = for (self.parameter_body_var_copies.items) |copy| {
                        if (copy.function_scope == function_scope and copy.body_var_symbol_id == body_id and
                            copy.parameter_symbol_id == parameter_raw) break true;
                    } else false;
                    if (!already_copied) {
                        try self.parameter_body_var_copies.append(self.allocator, .{
                            .function_scope = function_scope,
                            .body_var_symbol_id = body_id,
                            .parameter_symbol_id = parameter_raw,
                            .source_span = body_var_span,
                        });
                    }
                }
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
    const lower_defaults = self.options.unsupported.default_params;
    const lower_object_rest_only = !lower_defaults and self.options.unsupported.object_spread;
    if (!lower_defaults and !lower_object_rest_only) return result;
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
        const parameter_dynamic_lookup = lower_object_rest_only and
            (scopes[parameter_scope_raw].subtree_has_direct_eval or scopes[parameter_scope_raw].subtree_has_with);
        if (scopes[parameter_scope_raw].blocksMangling() and !parameter_dynamic_lookup) continue;
        const first_affected_param = if (lower_object_rest_only)
            (try params_mod.firstObjectRestParamIndex(self, params)) orelse continue
        else
            0;
        if (parameter_dynamic_lookup) {
            // Defaults moved after object-rest execute in the output body. A
            // direct eval or with nested in the original parameter environment
            // can dynamically look up any body binding; isolate that original
            // environment by aliasing every body-owned name before moving it.
            // If the body itself has dynamic lookup, the function-scope guard
            // above keeps us on the existing conservative path.
            var body_symbols = scope_maps[scope_raw].valueIterator();
            while (body_symbols.next()) |raw_id| {
                if (raw_id.* >= symbols.len or symbols[raw_id.*].scope_id != scope_id) continue;
                const kind = symbols[raw_id.*].kind;
                if (kind == .parameter or kind == .variable_var or kind == .variable_let or
                    kind == .variable_const or kind == .class_decl or kind.isFunctionLike())
                {
                    try result.put(self.allocator, @intCast(raw_id.*), {});
                }
            }
        }
        const affected_params = self.ast.extra_data.items[params.start + first_affected_param .. params.start + params.len];
        for (affected_params) |param| {
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
    const symbols = symbolsOf(self);
    for (self.ast.nodes.items) |node| {
        const pair: [2]ast_mod.NodeIndex = switch (node.tag) {
            .variable_declarator, .formal_parameter => .{
                @enumFromInt(self.ast.extra_data.items[node.data.extra]),
                @enumFromInt(self.ast.extra_data.items[node.data.extra + 2]),
            },
            .assignment_pattern, .assignment_target_with_default => .{ node.data.binary.left, node.data.binary.right },
            // `({ x = () => {} } = o)`: right is the default only in shorthand form.
            .assignment_target_property_identifier => if (node.data.binary.flags & 0x01 != 0)
                .{ node.data.binary.left, node.data.binary.right }
            else
                continue,
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
        const renamed_anonymous = renames.contains(id) or
            (if (self.block_rename_map) |*map| map.contains(id) else false);
        // ES5 lowers a default to `x === void 0 ? value : x`, which is not a
        // NamedEvaluation position.
        const lowered_default = switch (node.tag) {
            .formal_parameter => self.options.unsupported.default_params,
            .assignment_pattern, .assignment_target_with_default, .assignment_target_property_identifier => self.options.unsupported.default_params or self.options.unsupported.destructuring,
            else => false,
        };
        // Unlike an inferred `const` class name, assigning a name to a
        // `var`/`let` class expression's inner class binding changes reads
        // after the outer variable is reassigned. Preserve only the public
        // Function.name value for these downleveled expressions; class
        // lowering consumes this hint before static elements run.
        const downleveled_anonymous_class = value.tag == .class_expression and
            self.options.unsupported.class and id < symbols.len and
            symbols[id].kind != @import("../semantic/symbol.zig").SymbolKind.variable_const;
        if (anonymous and (renamed_anonymous or lowered_default or downleveled_anonymous_class)) {
            // Class static initialization must see NamedEvaluation first.
            // Its lowering consumes this exact class node inside the IIFE.
            const root = if (value.tag == .class_expression and self.options.unsupported.class) value_root else pair[1];
            if (id < symbols.len) try self.parameter_inferred_names.put(self.allocator, @intFromEnum(root), symbols[id].name);
        }
    }
}

/// Class lowering may bind an anonymous class to a generated name; record the
/// name NamedEvaluation gives each anonymous class instead (#5519).
pub fn collectClassInferredNames(self: anytype) std.mem.Allocator.Error!void {
    const u = self.options.unsupported;
    const lowers_classes = u.class or u.class_field or u.class_static_block or u.class_private_method or
        u.class_private_field or !self.options.use_define_for_class_fields;
    if (!lowers_classes) return;
    const nodes_len = self.ast.nodes.items.len;
    var i: usize = 0;
    while (i < nodes_len) : (i += 1) {
        const node = self.ast.nodes.items[i];
        const name: ?@import("../lexer/token.zig").Span, const value: ast_mod.NodeIndex = switch (node.tag) {
            .variable_declarator, .formal_parameter => .{
                bindingName(self, self.ast.readExtraNode(node.data.extra, 0)),
                self.ast.readExtraNode(node.data.extra, 2),
            },
            .assignment_pattern, .assignment_target_with_default => .{ bindingName(self, node.data.binary.left), node.data.binary.right },
            .assignment_target_property_identifier => if (node.data.binary.flags & 0x01 != 0)
                .{ bindingName(self, node.data.binary.left), node.data.binary.right }
            else
                continue,
            .assignment_expression => blk: {
                const op: @import("../lexer/token.zig").Kind = @enumFromInt(node.data.binary.flags);
                if (node.data.binary.flags != 0 and op != .eq and op != .question2_eq and op != .amp2_eq and op != .pipe2_eq) continue;
                break :blk .{ bindingName(self, node.data.binary.left), node.data.binary.right };
            },
            // `{ k: class {} }` and `static k = class {}` take the key; `__proto__:` sets the prototype.
            .object_property => .{ try keyName(self, node.data.binary.left, true), node.data.binary.right },
            .property_definition => .{
                try keyName(self, self.ast.readExtraNode(node.data.extra, ast_mod.PropertyExtra.key), false),
                self.ast.readExtraNode(node.data.extra, ast_mod.PropertyExtra.init),
            },
            .export_default_declaration => .{ try self.ast.addString("default"), node.data.unary.operand },
            else => continue,
        };
        // A lowered field becomes `__publicField(C, "k", value)` / `this.k = value`
        // (or a descriptor `value:`), outside NamedEvaluation (#5519).
        if (node.tag == .property_definition) if (name) |n| if (functionRoot(self, value)) |fn_raw| {
            const slot = try self.parameter_inferred_names.getOrPut(self.allocator, fn_raw);
            if (!slot.found_existing) slot.value_ptr.* = n;
        };
        const class_raw = anonymousClassRoot(self, value) orelse continue;
        if (name) |n| try self.class_inferred_names.put(self.allocator, class_raw, n);
    }
    // Every other anonymous class has no name.
    i = 0;
    while (i < nodes_len) : (i += 1) {
        if (self.ast.nodes.items[i].tag != .class_expression) continue;
        const class_raw = anonymousClassRoot(self, @enumFromInt(i)) orelse continue;
        const entry = try self.class_inferred_names.getOrPut(self.allocator, class_raw);
        if (!entry.found_existing) entry.value_ptr.* = .{ .start = 0, .end = 0 };
    }
    // ES5 lowering of a class without static elements yields a named
    // function expression; visitNode names that value (preserveInferredName).
    if (u.class) {
        var it = self.class_inferred_names.iterator();
        while (it.next()) |entry| {
            if (self.ast.nodes.items[entry.key_ptr.*].tag != .class_expression) continue;
            const slot = try self.parameter_inferred_names.getOrPut(self.allocator, entry.key_ptr.*);
            if (!slot.found_existing) slot.value_ptr.* = entry.value_ptr.*;
        }
    }
}

/// An anonymous function or arrow (through parentheses).
fn functionRoot(self: anytype, value: ast_mod.NodeIndex) ?u32 {
    var current = value;
    while (!current.isNone() and @intFromEnum(current) < self.ast.nodes.items.len) {
        const node = self.ast.getNode(current);
        switch (node.tag) {
            .parenthesized_expression => current = node.data.unary.operand,
            .arrow_function_expression => return @intFromEnum(current),
            .function_expression => return if (self.ast.readExtraNode(node.data.extra, ast_mod.FunctionExtra.name).isNone()) @intFromEnum(current) else null,
            else => return null,
        }
    }
    return null;
}

fn anonymousClassRoot(self: anytype, value: ast_mod.NodeIndex) ?u32 {
    var current = value;
    while (!current.isNone() and @intFromEnum(current) < self.ast.nodes.items.len) {
        const node = self.ast.getNode(current);
        if (node.tag == .parenthesized_expression or ast_mod.Node.Tag.isTransparentTypeWrapper(node.tag)) {
            current = node.data.unary.operand;
            continue;
        }
        if (node.tag != .class_expression and node.tag != .class_declaration) return null;
        if (!self.ast.readExtraNode(node.data.extra, ast_mod.ClassExtra.name).isNone()) return null;
        return @intFromEnum(current);
    }
    return null;
}

fn bindingName(self: anytype, binding: ast_mod.NodeIndex) ?@import("../lexer/token.zig").Span {
    if (binding.isNone()) return null;
    const node = self.ast.getNode(binding);
    return switch (node.tag) {
        .binding_identifier, .assignment_target_identifier, .identifier_reference => node.data.string_ref,
        else => null,
    };
}

fn keyName(self: anytype, key: ast_mod.NodeIndex, object_literal: bool) std.mem.Allocator.Error!?@import("../lexer/token.zig").Span {
    if (key.isNone()) return null;
    // A numeric key names the class with its canonical ToString form.
    var literal = key;
    if (self.ast.getNode(literal).tag == .computed_property_key) literal = self.ast.getNode(literal).data.unary.operand;
    if (!literal.isNone()) {
        const node = self.ast.getNode(literal);
        var buf: [64]u8 = undefined;
        const canonical: ?[]const u8 = switch (node.tag) {
            .numeric_literal => if (ast_mod.parseNumericText(self.ast.getText(node.span))) |value| jsNumberString(&buf, value) else null,
            .bigint_literal => bigintString(&buf, self.ast.getText(node.span)),
            else => null,
        };
        if (canonical) |text| return try self.ast.addString(text);
        if (node.tag == .numeric_literal or node.tag == .bigint_literal) return null;
    }
    const text = try self.ast.staticKeyName(self.allocator, key) orelse return null;
    defer self.allocator.free(text);
    if (object_literal and self.ast.getNode(key).tag != .computed_property_key and std.mem.eql(u8, text, "__proto__")) return null;
    return try self.ast.addString(text);
}

/// Number::toString for a property key (finite values; NaN/Infinity keys
/// cannot come from a numeric literal).
fn jsNumberString(buf: []u8, value: f64) ?[]const u8 {
    if (!std.math.isFinite(value)) return null;
    if (value == 0) return "0";
    const magnitude = @abs(value);
    if (magnitude >= 1e21 or magnitude < 1e-6) {
        // `{e}` prints `1e21` / `1.5e-7`; JS writes `1e+21`.
        var tmp: [64]u8 = undefined;
        const raw = std.fmt.bufPrint(&tmp, "{e}", .{value}) catch return null;
        const e = std.mem.indexOfScalar(u8, raw, 'e') orelse return null;
        const sign: []const u8 = if (e + 1 < raw.len and raw[e + 1] == '-') "" else "+";
        return std.fmt.bufPrint(buf, "{s}e{s}{s}", .{ raw[0..e], sign, raw[e + 1 ..] }) catch null;
    }
    return std.fmt.bufPrint(buf, "{d}", .{value}) catch null;
}

/// BigInt::toString of a `123n` / `0x10n` literal.
fn bigintString(buf: []u8, text: []const u8) ?[]const u8 {
    if (text.len < 2 or text[text.len - 1] != 'n') return null;
    var digits = text[0 .. text.len - 1];
    var radix: u8 = 10;
    if (digits.len > 2 and digits[0] == '0') switch (digits[1] | 0x20) {
        'x' => radix = 16,
        'o' => radix = 8,
        'b' => radix = 2,
        else => {},
    };
    if (radix != 10) digits = digits[2..];
    var clean: [64]u8 = undefined;
    var len: usize = 0;
    for (digits) |c| {
        if (c == '_') continue;
        if (len == clean.len) return null;
        clean[len] = c;
        len += 1;
    }
    const value = std.fmt.parseInt(u128, clean[0..len], radix) catch return null;
    return std.fmt.bufPrint(buf, "{d}", .{value}) catch null;
}

/// The inferred name of an anonymous class lowered under a generated binding,
/// consumed so no outer wrapper names the class again.
pub fn takeAnonymousClassName(self: anytype, source: ast_mod.NodeIndex) ?@import("../lexer/token.zig").Span {
    const raw = @intFromEnum(source);
    const key = if (self.class_inferred_names.contains(raw)) raw else self.scope_owner_origins.get(raw) orelse return null;
    const name = self.class_inferred_names.get(key) orelse return null;
    _ = self.class_inferred_names.remove(key);
    _ = self.parameter_inferred_names.remove(key);
    return name;
}

/// An anonymous class bound to a generated name keeps static blocks in its
/// body: restore its name at the top of the first one, which runs before the
/// others. The name then is not restored again after the declaration.
pub fn nameInFirstStaticBlock(self: anytype, source: ast_mod.NodeIndex, members: []const ast_mod.NodeIndex) std.mem.Allocator.Error!void {
    for (members) |member_idx| {
        const member = self.ast.getNode(member_idx);
        if (member.tag != .static_block) continue;
        const block_idx = member.data.unary.operand;
        if (block_idx.isNone()) return;
        const scope: ScopeId = if (!self.semantic_edit_enabled)
            self.current_scope
        else
            self.outputOwnedScope(member_idx) orelse self.outputOwnedScope(block_idx) orelse return;
        const name = takeAnonymousClassName(self, source) orelse return;
        const span = member.span;
        const this_ref = try es_helpers.makeThisExpr(self, span);
        const statement = try classNameStatement(self, this_ref, name, scope, span);
        const old = self.ast.getNode(block_idx).data.list;
        var statements: std.ArrayList(ast_mod.NodeIndex) = .empty;
        defer statements.deinit(self.allocator);
        try statements.append(self.allocator, statement);
        for (self.ast.extra_data.items[old.start .. old.start + old.len]) |raw| try statements.append(self.allocator, @enumFromInt(raw));
        self.ast.nodes.items[@intFromEnum(block_idx)].data.list = try self.ast.addNodeList(statements.items);
        return;
    }
}

/// ES5 class lowering defines a method as `{ value: function () {} }` (or an
/// accessor as `{ get: function () {} }`), which names it "value"/"get".
/// Name it after the source member (`prefix` is "get "/"set " for accessors).
/// Runtime computed keys are not known statically and stay unnamed (#5527).
pub fn nameLoweredMember(self: anytype, func: ast_mod.NodeIndex, member: ast_mod.NodeIndex, prefix: []const u8, scope: ScopeId, span: @import("../lexer/token.zig").Span) std.mem.Allocator.Error!ast_mod.NodeIndex {
    if (func.isNone() or member.isNone()) return func;
    const key = self.ast.readExtraNode(self.ast.getNode(member).data.extra, ast_mod.MethodExtra.key);
    const key_name = (try keyName(self, key, false)) orelse return func;
    const name = if (prefix.len == 0) key_name else blk: {
        const joined = try std.mem.concat(self.allocator, u8, &.{ prefix, self.ast.getText(key_name) });
        defer self.allocator.free(joined);
        break :blk try self.ast.addString(joined);
    };
    const saved_scope = self.current_scope;
    self.current_scope = scope;
    defer self.current_scope = saved_scope;
    return nameValue(self, func, name, span);
}

/// An object literal lowered to `_a.k = function () {}` assignments loses the
/// property's NamedEvaluation; name an anonymous function or arrow value after
/// its static key. (Anonymous classes are named by class lowering.)
pub fn nameLoweredProperty(self: anytype, value: ast_mod.NodeIndex, key: ast_mod.NodeIndex, source_value: ast_mod.NodeIndex, span: @import("../lexer/token.zig").Span) std.mem.Allocator.Error!ast_mod.NodeIndex {
    if (value.isNone() or functionRoot(self, source_value) == null) return value;
    const name = (try keyName(self, key, true)) orelse return value;
    return nameValue(self, value, name, span);
}

/// `__name(<class ref>, "<name>");` evaluated in `scope`.
pub fn classNameStatement(self: anytype, ref: ast_mod.NodeIndex, name: @import("../lexer/token.zig").Span, scope: ScopeId, span: @import("../lexer/token.zig").Span) std.mem.Allocator.Error!ast_mod.NodeIndex {
    const saved_scope = self.current_scope;
    self.current_scope = scope;
    defer self.current_scope = saved_scope;
    return es_helpers.makeExprStmt(self, try nameValue(self, ref, name, span), span);
}

/// A helper call preserves the inferred name without introducing a named
/// function-expression binding (which would intercept recursive outer reads).
/// Unlike an object-literal naming wrapper this also handles `__proto__` and
/// functions/classes that lowered to a capture-factory call or class IIFE.
pub fn preserveInferredName(self: anytype, source: ast_mod.NodeIndex, output: ast_mod.NodeIndex) std.mem.Allocator.Error!ast_mod.NodeIndex {
    if (output.isNone()) return output;
    const name = self.parameter_inferred_names.get(@intFromEnum(source)) orelse return output;
    // A lowered class that became `function f() {}` already has the name.
    const out = self.ast.getNode(output);
    if (out.tag == .function_expression or out.tag == .class_expression) {
        const out_name = self.ast.readExtraNode(out.data.extra, 0);
        if (!out_name.isNone() and std.mem.eql(u8, self.ast.getText(self.ast.getNode(out_name).data.string_ref), self.ast.getText(name))) return output;
    }
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
    const key = if (self.parameter_inferred_names.contains(raw)) raw else self.scope_owner_origins.get(raw);
    const hinted = if (key) |k| self.parameter_inferred_names.get(k) else null;
    if (key) |k| _ = self.parameter_inferred_names.remove(k);
    const anonymous = takeAnonymousClassName(self, source);
    const name = hinted orelse anonymous orelse return null;
    // A generated binding that already spells the name needs no call.
    if (std.mem.eql(u8, self.ast.getText(self.ast.getNode(binding).data.string_ref), self.ast.getText(name))) return null;
    const saved_scope = self.current_scope;
    self.current_scope = scope;
    defer self.current_scope = saved_scope;
    const ref = try self.makeUserRefNamed(self.ast.getText(self.ast.getNode(binding).data.string_ref), binding);
    const span = self.ast.getNode(source).span;
    const statement = try es_helpers.makeExprStmt(self, try nameValue(self, ref, name, span), span);
    self.ast.extra_data.items[self.ast.getNode(constructor).data.extra + ast_mod.FunctionExtra.flags] |= ast_mod.FunctionFlags.name_preserved;
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
    // Only function-body-level declarations are initialized on entry. A block
    // function exists once its block (or switch body) is entered, so its
    // `__name` call goes at the top of that block instead (#5454). A switch
    // body can be entered at any case, so every case gets the call.
    var body_level: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer body_level.deinit(self.allocator);
    var container_of: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer container_of.deinit(self.allocator);
    var switch_of: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer switch_of.deinit(self.allocator);
    var by_container: std.AutoHashMapUnmanaged(u32, std.ArrayList(ast_mod.NodeIndex)) = .empty;
    defer {
        var lists = by_container.valueIterator();
        while (lists.next()) |list| list.deinit(self.allocator);
        by_container.deinit(self.allocator);
    }
    for (reachable) |raw| {
        const container = self.ast.getNode(@enumFromInt(raw));
        const statements = switch (container.tag) {
            .block_statement => self.ast.extra_data.items[container.data.list.start .. container.data.list.start + container.data.list.len],
            .switch_case => blk: {
                const extras = self.ast.extra_data.items[container.data.extra .. container.data.extra + 3];
                break :blk self.ast.extra_data.items[extras[1] .. extras[1] + extras[2]];
            },
            .switch_statement => {
                const extras = self.ast.extra_data.items[container.data.extra .. container.data.extra + 3];
                for (self.ast.extra_data.items[extras[1] .. extras[1] + extras[2]]) |case| try switch_of.put(self.allocator, case, raw);
                continue;
            },
            else => continue,
        };
        for (statements) |stmt| try container_of.put(self.allocator, stmt, raw);
    }
    for (reachable) |raw| {
        const function = self.ast.getNode(@enumFromInt(raw));
        switch (function.tag) {
            .function_declaration, .function_expression, .function, .arrow_function_expression, .method_definition => {},
            else => continue,
        }
        const body = self.ast.functionBodyBlock(function) orelse continue;
        const body_node = self.ast.getNode(body);
        if (body_node.tag != .block_statement and body_node.tag != .function_body) continue;
        const list = body_node.data.list;
        for (self.ast.extra_data.items[list.start .. list.start + list.len]) |stmt| try body_level.put(self.allocator, stmt, {});
    }
    if (self.ast.nodes.items.len > 0) {
        const program = self.ast.getNode(root);
        if (program.tag == .program) {
            const list = program.data.list;
            for (self.ast.extra_data.items[list.start .. list.start + list.len]) |stmt| try body_level.put(self.allocator, stmt, {});
        }
    }
    for (reachable) |raw| {
        const declaration = self.ast.getNode(@enumFromInt(raw));
        if (declaration.tag != .function_declaration) continue;
        const block_container: ?u32 = if (body_level.contains(raw)) null else container_of.get(raw) orelse continue;
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
        const span: @import("../lexer/token.zig").Span = .{ .start = declaration.span.start, .end = declaration.span.start };
        if (block_container) |container| {
            var targets: std.ArrayList(u32) = .empty;
            defer targets.deinit(self.allocator);
            if (switch_of.get(container)) |switch_raw| {
                const extra = self.ast.getNode(@enumFromInt(switch_raw)).data.extra;
                const start = self.ast.extra_data.items[extra + 1];
                try targets.appendSlice(self.allocator, self.ast.extra_data.items[start .. start + self.ast.extra_data.items[extra + 2]]);
            } else try targets.append(self.allocator, container);
            for (targets.items) |target| {
                const call = try nameValue(self, try self.makeUserRefNamed(alias, binding), symbols[id].name, span);
                const entry = try by_container.getOrPut(self.allocator, target);
                if (!entry.found_existing) entry.value_ptr.* = .empty;
                try entry.value_ptr.append(self.allocator, try es_helpers.makeExprStmt(self, call, span));
            }
            continue;
        }
        const call = try nameValue(self, try self.makeUserRefNamed(alias, binding), symbols[id].name, span);
        const entry = try by_scope.getOrPut(self.allocator, @intFromEnum(scope));
        if (!entry.found_existing) entry.value_ptr.* = .empty;
        try entry.value_ptr.append(self.allocator, try es_helpers.makeExprStmt(self, call, span));
    }
    var containers = by_container.iterator();
    while (containers.next()) |entry| {
        const container_raw = entry.key_ptr.*;
        const container = self.ast.getNode(@enumFromInt(container_raw));
        const old_list: ast_mod.NodeList = switch (container.tag) {
            .block_statement => container.data.list,
            .switch_case => .{
                .start = self.ast.extra_data.items[container.data.extra + 1],
                .len = self.ast.extra_data.items[container.data.extra + 2],
            },
            else => continue,
        };
        var statements: std.ArrayList(ast_mod.NodeIndex) = .empty;
        defer statements.deinit(self.allocator);
        try statements.appendSlice(self.allocator, entry.value_ptr.items);
        for (self.ast.extra_data.items[old_list.start .. old_list.start + old_list.len]) |stmt| try statements.append(self.allocator, @enumFromInt(stmt));
        const new_list = try self.ast.addNodeList(statements.items);
        switch (container.tag) {
            .block_statement => self.ast.nodes.items[container_raw].data.list = new_list,
            .switch_case => {
                self.ast.extra_data.items[container.data.extra + 1] = new_list.start;
                self.ast.extra_data.items[container.data.extra + 2] = new_list.len;
            },
            else => unreachable,
        }
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
