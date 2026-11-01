//! CJS AST pattern helpers used by tree shaking.

const std = @import("std");
const types = @import("../types.zig");
const ModuleIndex = types.ModuleIndex;
const Module = @import("../module.zig").Module;
const ModuleSemanticData = @import("../module.zig").ModuleSemanticData;
const StmtInfos = @import("../stmt_info.zig").ModuleStmtInfos;
const ast_mod = @import("../../parser/ast.zig");
const Ast = ast_mod.Ast;
const Node = ast_mod.Node;
const NodeIndex = ast_mod.NodeIndex;
const Scope = @import("../../semantic/scope.zig").Scope;
const ScopeId = @import("../../semantic/scope.zig").ScopeId;
const SymbolKind = @import("../../semantic/symbol.zig").SymbolKind;
const ast_walk = @import("../../parser/ast_walk.zig");
const Kind = @import("../../lexer/token.zig").Kind;
const Span = @import("../../lexer/token.zig").Span;

// A source-level capability fact is useful only before compiler-input effects
// can mutate or escape the actual Node constructor/module value. This does not
// assert immutability against host preload code outside the input program.
const BufferPrefixResult = enum { clear, target, unknown };

fn sourceBindingIsExact(module: *const Module, ast: *const Ast, binding: NodeIndex, kind: SymbolKind, scope: u32) ?u32 {
    const sem = &(module.semantic orelse return null);
    if (binding.isNone() or @backingInt(binding) >= ast.nodes.items.len or @backingInt(binding) >= sem.symbol_ids.len or ast.getNode(binding).tag != .binding_identifier) return null;
    const id = sem.symbol_ids[@backingInt(binding)] orelse return null;
    if (id >= sem.symbols.items.len or scope >= sem.scopes.len or scope >= sem.scope_maps.len) return null;
    const symbol = sem.symbols.items[id];
    if (symbol.kind != kind or symbol.scope_id.toIndex() != scope or symbol.synthetic_kind != null or symbol.isExported() or symbol.write_count != 0 or
        symbol.synthetic_name.len != 0 or symbol.synthetic_owner_id != null or symbol.output_name_hint.len != 0 or
        !std.meta.eql(symbol.decl_flags, kind.declFlags())) return null;
    var declarations: usize = 0;
    for (sem.references) |row| {
        if (@backingInt(row.symbol_id) != id or !row.flags.declare) continue;
        if (!std.meta.eql(row.flags, @as(@import("../../semantic/symbol.zig").ReferenceFlags, .{ .declare = true })) or
            !row.node_index.isNone() or row.declaration_node_index != binding or row.scope_id != symbol.scope_id) return null;
        declarations += 1;
    }
    if (declarations != 1) return null;
    const name = ast.getText(ast.getNode(binding).span);
    var mapped = false;
    var entries = sem.scope_maps[scope].iterator();
    while (entries.next()) |entry| {
        if (entry.value_ptr.* != id) continue;
        if (!std.mem.eql(u8, name, entry.key_ptr.*) and !@import("../../lexer/scanner.zig").Scanner.identifierValueEquals(name, entry.key_ptr.*)) return null;
        mapped = true;
    }
    return if (mapped) id else null;
}

fn plainCopyParameter(ast: *const Ast, parameter: NodeIndex) ?NodeIndex {
    if (parameter.isNone() or @backingInt(parameter) >= ast.nodes.items.len) return null;
    const node = ast.getNode(parameter);
    if (node.tag == .binding_identifier) return parameter;
    if (node.tag != .formal_parameter or !ast.hasExtra(node.data.extra, ast_mod.FormalParameterExtra.deco_len) or
        !ast.readExtraNode(node.data.extra, ast_mod.FormalParameterExtra.default).isNone() or
        !ast.readExtraNode(node.data.extra, ast_mod.FormalParameterExtra.type_ann).isNone() or
        ast.readExtra(node.data.extra, ast_mod.FormalParameterExtra.flags) != 0 or
        ast.readExtra(node.data.extra, ast_mod.FormalParameterExtra.deco_len) != 0) return null;
    return ast.readExtraNode(node.data.extra, ast_mod.FormalParameterExtra.pattern);
}

/// Prove only non-escape writes into a fresh local function/host exports
/// object. The call is never deleted; its actual execution is preserved.
fn exactNonEscapingBufferCopyCall(module: *const Module, ast: *const Ast, call: Node, use_scope: u32, expected_destination: ?u32) bool {
    const sem = &(module.semantic orelse return false);
    if (call.tag != .call_expression or !ast.hasExtra(call.data.extra, 3) or
        ast.readExtra(call.data.extra, 3) & ~@as(u32, ast_mod.CallFlags.is_pure) != 0 or ast.readExtra(call.data.extra, 2) != 2) return false;
    const start = ast.readExtra(call.data.extra, 1);
    if (start > ast.extra_data.items.len or 2 > ast.extra_data.items.len - start) return false;
    const source: NodeIndex = @fromBackingInt(ast.extra_data.items[start]);
    const destination: NodeIndex = @fromBackingInt(ast.extra_data.items[start + 1]);
    const callee = ast.readExtraNode(call.data.extra, 0);
    if (!exactDeadBufferRead(module, ast, callee, use_scope, false) or
        !exactDeadBufferRead(module, ast, source, use_scope, false) or
        !exactDeadBufferRead(module, ast, destination, use_scope, true)) return false;
    const source_id = sem.symbol_ids[@backingInt(source)].?;
    const destination_id = sem.symbol_ids[@backingInt(destination)].?;
    const callee_id = sem.symbol_ids[@backingInt(callee)].?;
    if (expected_destination) |id| if (id != destination_id) return false;
    if (!exactNodeBufferObjectBinding(module, ast, source_id) and exactNodeBufferConstructorObject(module, ast, source_id) == null) return false;
    const program_scope = sem.scope_owner_map.get(@intCast(ast.nodes.items.len - 1)) orelse return false;
    const root = programNode(ast) orelse return false;
    var function: ?NodeIndex = null;
    var destination_function = false;
    for (ast.extra_data.items[root.data.list.start..][0..root.data.list.len]) |raw| {
        const node = ast.nodes.items[raw];
        if (node.tag != .function_declaration or !ast.hasExtra(node.data.extra, ast_mod.FunctionExtra.flags)) continue;
        const binding = ast.readExtraNode(node.data.extra, ast_mod.FunctionExtra.name);
        const id = sourceBindingIsExact(module, ast, binding, .function_decl, program_scope) orelse continue;
        if (id == destination_id) destination_function = true;
        if (id != callee_id) continue;
        if (function != null or ast.readExtra(node.data.extra, ast_mod.FunctionExtra.flags) & (ast_mod.FunctionFlags.is_async | ast_mod.FunctionFlags.is_generator) != 0) return false;
        function = @fromBackingInt(raw);
    }
    if (!destination_function and !exactBufferWrapperRoot(module, ast, destination)) return false;
    const owner = function orelse return false;
    const fn_scope = sem.scope_owner_map.get(@backingInt(owner)) orelse return false;
    if (fn_scope >= sem.scopes.len or sem.scopes[fn_scope].kind != .function or sem.scopes[fn_scope].parent.toIndex() != program_scope or sem.scopes[fn_scope].blocksMangling()) return false;
    const node = ast.getNode(owner);
    const params = ast.functionParamsList(node);
    if (params.len != 2 or params.start > ast.extra_data.items.len or params.len > ast.extra_data.items.len - params.start) return false;
    const first = plainCopyParameter(ast, @fromBackingInt(ast.extra_data.items[params.start])) orelse return false;
    const second = plainCopyParameter(ast, @fromBackingInt(ast.extra_data.items[params.start + 1])) orelse return false;
    const src = sourceBindingIsExact(module, ast, first, .parameter, fn_scope) orelse return false;
    const dst = sourceBindingIsExact(module, ast, second, .parameter, fn_scope) orelse return false;
    if (src == dst) return false;
    const body = ast.functionBodyBlock(node) orelse return false;
    const loop_index = singleBlockStatement(ast, body) orelse return false;
    const loop = ast.getNode(loop_index);
    if (loop.tag != .for_in_statement) return false;
    const loop_scope = sem.scope_owner_map.get(@backingInt(loop_index)) orelse return false;
    if (loop_scope >= sem.scopes.len or sem.scopes[loop_scope].kind != .block or sem.scopes[loop_scope].parent.toIndex() != fn_scope or sem.scopes[loop_scope].blocksMangling()) return false;
    const head = ast.getNode(loop.data.ternary.a);
    if (head.tag != .variable_declaration or !ast.hasExtra(head.data.extra, 2) or ast.readExtra(head.data.extra, 0) != @backingInt(ast_mod.VariableDeclarationKind.@"var") or ast.readExtra(head.data.extra, 2) != 1) return false;
    const declarations = ast.readExtra(head.data.extra, 1);
    if (declarations >= ast.extra_data.items.len) return false;
    const declaration = ast.nodes.items[ast.extra_data.items[declarations]];
    if (declaration.tag != .variable_declarator or !ast.hasExtra(declaration.data.extra, 2) or !ast.readExtraNode(declaration.data.extra, 2).isNone()) return false;
    const key_binding = ast.readExtraNode(declaration.data.extra, 0);
    const key = sourceBindingIsExact(module, ast, key_binding, .variable_var, fn_scope) orelse return false;
    if (key == src or key == dst or sem.symbols.items[key].origin_scope.toIndex() != loop_scope) return false;
    if (!exactBufferValueRead(module, loop.data.ternary.b, src, loop_scope)) return false;
    var statement_index = loop.data.ternary.c;
    var statement_scope = loop_scope;
    if (ast.getNode(statement_index).tag == .block_statement) {
        statement_scope = sem.scope_owner_map.get(@backingInt(statement_index)) orelse return false;
        if (statement_scope >= sem.scopes.len or sem.scopes[statement_scope].parent.toIndex() != loop_scope or sem.scopes[statement_scope].kind != .block) return false;
        statement_index = singleBlockStatement(ast, statement_index) orelse return false;
    }
    const statement = ast.getNode(statement_index);
    if (statement.tag != .expression_statement) return false;
    const assignment = ast.getNode(statement.data.unary.operand);
    if (assignment.tag != .assignment_expression or assignment.data.binary.flags != @backingInt(Kind.eq)) return false;
    const left = ast.getNode(assignment.data.binary.left);
    const right = ast.getNode(assignment.data.binary.right);
    if (left.tag != .computed_member_expression or right.tag != .computed_member_expression or !ast.hasExtra(left.data.extra, 2) or !ast.hasExtra(right.data.extra, 2) or ast.readExtra(left.data.extra, 2) != 0 or ast.readExtra(right.data.extra, 2) != 0) return false;
    const dst_read = ast.readExtraNode(left.data.extra, 0);
    const key_left = ast.readExtraNode(left.data.extra, 1);
    const src_read = ast.readExtraNode(right.data.extra, 0);
    const key_right = ast.readExtraNode(right.data.extra, 1);
    if (!exactBufferValueRead(module, dst_read, dst, statement_scope) or !exactBufferValueRead(module, key_left, key, statement_scope) or
        !exactBufferValueRead(module, src_read, src, statement_scope) or !exactBufferValueRead(module, key_right, key, statement_scope)) return false;
    for ([_]struct { id: u32, count: u32 }{ .{ .id = src, .count = 2 }, .{ .id = dst, .count = 1 }, .{ .id = key, .count = 2 } }) |expected| {
        if (sem.symbols.items[expected.id].reference_count != expected.count or sem.symbols.items[expected.id].write_count != 0) return false;
    }
    return true;
}

fn inertBufferPrefixExpression(module: *const Module, ast: *const Ast, index: NodeIndex) bool {
    if (index.isNone()) return true;
    if (@backingInt(index) >= ast.nodes.items.len) return false;
    const sem = &(module.semantic orelse return false);
    const node = ast.getNode(index);
    return switch (node.tag) {
        .numeric_literal, .string_literal, .boolean_literal, .null_literal, .bigint_literal, .regexp_literal, .function_expression, .arrow_function_expression => true,
        .identifier_reference => blk: {
            if (@backingInt(index) >= sem.symbol_ids.len) break :blk false;
            const id = sem.symbol_ids[@backingInt(index)] orelse break :blk false;
            if (id >= sem.symbols.items.len) break :blk false;
            // Do not manufacture an alias proof for a value stored elsewhere.
            break :blk !exactNodeBufferObjectBinding(module, ast, id) and exactNodeBufferConstructorObject(module, ast, id) == null;
        },
        .parenthesized_expression => inertBufferPrefixExpression(module, ast, node.data.unary.operand),
        .array_expression, .object_expression => node.data.list.len == 0,
        else => false,
    };
}

fn knownBufferPrototypeCreation(module: *const Module, ast: *const Ast, index: NodeIndex) bool {
    const sem = &(module.semantic orelse return false);
    const node = ast.getNode(index);
    if (node.tag != .call_expression or !ast.hasExtra(node.data.extra, 3) or ast.readExtra(node.data.extra, 2) != 1 or ast.readExtra(node.data.extra, 3) & ~@as(u32, ast_mod.CallFlags.is_pure) != 0) return false;
    const callee = staticMemberParts(ast, ast.readExtraNode(node.data.extra, 0)) orelse return false;
    if (!@import("../../lexer/scanner.zig").Scanner.identifierValueEquals(ast.identifierNameText(ast.getNode(callee.property)), "create") or ast.getNode(callee.object).tag != .identifier_reference or
        @backingInt(callee.object) >= sem.symbol_ids.len or sem.symbol_ids[@backingInt(callee.object)] != null or
        !sem.unresolved_references.contains("Object") or !@import("../../lexer/scanner.zig").Scanner.identifierValueEquals(ast.identifierNameText(ast.getNode(callee.object)), "Object")) return false;
    const start = ast.readExtra(node.data.extra, 1);
    if (start >= ast.extra_data.items.len) return false;
    const prototype = staticMemberParts(ast, @fromBackingInt(ast.extra_data.items[start])) orelse return false;
    if (!@import("../../lexer/scanner.zig").Scanner.identifierValueEquals(ast.identifierNameText(ast.getNode(prototype.property)), "prototype") or @backingInt(prototype.object) >= sem.symbol_ids.len) return false;
    const id = sem.symbol_ids[@backingInt(prototype.object)] orelse return false;
    return exactNodeBufferConstructorObject(module, ast, id) != null;
}

fn bufferPrefixStatement(module: *const Module, ast: *const Ast, index: NodeIndex, target: NodeIndex, scope: u32, constructors: *const std.StringHashMapUnmanaged(void), fuel: *usize) BufferPrefixResult {
    if (index == target) return .target;
    if (index.isNone()) return .clear;
    if (@backingInt(index) >= ast.nodes.items.len or fuel.* == 0) return .unknown;
    fuel.* -= 1;
    const sem = &(module.semantic orelse return .unknown);
    const node = ast.getNode(index);
    switch (node.tag) {
        .program, .block_statement => {
            const list = node.data.list;
            if (list.start > ast.extra_data.items.len or list.len > ast.extra_data.items.len - list.start) return .unknown;
            const actual_scope = sem.scope_owner_map.get(@backingInt(index)) orelse scope;
            for (ast.extra_data.items[list.start..][0..list.len]) |raw| {
                const result = bufferPrefixStatement(module, ast, @fromBackingInt(raw), target, actual_scope, constructors, fuel);
                if (result != .clear) return result;
            }
            return .clear;
        },
        .function_declaration, .empty_statement => return .clear,
        .variable_declaration => {
            if (!ast.hasExtra(node.data.extra, 2)) return .unknown;
            const start = ast.readExtra(node.data.extra, 1);
            const len = ast.readExtra(node.data.extra, 2);
            if (start > ast.extra_data.items.len or len > ast.extra_data.items.len - start) return .unknown;
            for (ast.extra_data.items[start..][0..len]) |raw| {
                const declaration = ast.nodes.items[raw];
                if (declaration.tag != .variable_declarator or !ast.hasExtra(declaration.data.extra, 2)) return .unknown;
                const binding = ast.readExtraNode(declaration.data.extra, 0);
                const initializer = ast.readExtraNode(declaration.data.extra, 2);
                if (binding.isNone() or @backingInt(binding) >= sem.symbol_ids.len or ast.getNode(binding).tag != .binding_identifier) return .unknown;
                const id = sem.symbol_ids[@backingInt(binding)] orelse return .unknown;
                if (exactNodeBufferObjectBinding(module, ast, id) or exactNodeBufferConstructorObject(module, ast, id) != null) continue;
                if (!inertBufferPrefixExpression(module, ast, initializer)) return .unknown;
            }
            return .clear;
        },
        .if_statement => {
            var capabilities: BufferCapabilitySet = .{};
            if (!collectNodeBufferCapabilityCondition(ast, node.data.ternary.a, constructors, &capabilities) or !capabilities.hasAll()) return .unknown;
            // Earlier proved Node-capability branches execute only their kept
            // side. A later branch cannot inherit effects from their dead side.
            return bufferPrefixStatement(module, ast, node.data.ternary.b, target, scope, constructors, fuel);
        },
        .expression_statement => {
            const expression = ast.getNode(node.data.unary.operand);
            if (expression.tag == .call_expression) return if (exactNonEscapingBufferCopyCall(module, ast, expression, scope, null)) .clear else .unknown;
            if (expression.tag == .assignment_expression and expression.data.binary.flags == @backingInt(Kind.eq)) {
                if (isModuleExportsLhs(ast, expression.data.binary.left) and exactBufferWrapperRoot(module, ast, expression.data.binary.left)) {
                    const rhs = expression.data.binary.right;
                    if (@backingInt(rhs) < sem.symbol_ids.len) if (sem.symbol_ids[@backingInt(rhs)]) |id| {
                        if (exactNodeBufferObjectBinding(module, ast, id) or exactNodeBufferConstructorObject(module, ast, id) != null) return .clear;
                    };
                }
                const parts = staticMemberParts(ast, expression.data.binary.left) orelse return .unknown;
                const object = ast.getNode(parts.object);
                if (object.tag != .identifier_reference or @backingInt(parts.object) >= sem.symbol_ids.len) return .unknown;
                const id = sem.symbol_ids[@backingInt(parts.object)] orelse return .unknown;
                // A prior kept branch may publish the already-known Buffer
                // constructor on the actual exports parameter. This does not
                // mutate the constructor's capability properties.
                if (module.cjs_wrapper_exports_parameter_symbol) |exports_id| {
                    const rhs = expression.data.binary.right;
                    if (id == @backingInt(exports_id) and id < sem.symbols.items.len and
                        sem.symbols.items[id].synthetic_kind == .cjs_wrapper_exports_parameter and
                        sem.symbols.items[id].write_count == 0 and
                        @import("../../lexer/scanner.zig").Scanner.identifierValueEquals(ast.identifierNameText(ast.getNode(parts.property)), "Buffer") and
                        !rhs.isNone() and @backingInt(rhs) < sem.symbol_ids.len)
                    {
                        if (sem.symbol_ids[@backingInt(rhs)]) |rhs_id| {
                            if (exactNodeBufferConstructorObject(module, ast, rhs_id) != null and
                                exactBufferValueRead(module, rhs, rhs_id, scope)) return .clear;
                        }
                    }
                }
                if (id >= sem.symbols.items.len or sem.symbols.items[id].kind != .function_decl or sem.symbols.items[id].write_count != 0 or sem.symbols.items[id].isExported() or
                    @import("../../lexer/scanner.zig").Scanner.identifierValueEquals(ast.identifierNameText(ast.getNode(parts.property)), "__proto__")) return .unknown;
                return if (inertBufferPrefixExpression(module, ast, expression.data.binary.right) or knownBufferPrototypeCreation(module, ast, expression.data.binary.right)) .clear else .unknown;
            }
            return if (inertBufferPrefixExpression(module, ast, node.data.unary.operand)) .clear else .unknown;
        },
        .export_named_declaration => {
            if (!ast.hasExtra(node.data.extra, 3) or !ast.readExtraNode(node.data.extra, 3).isNone()) return .unknown;
            const declaration = ast.readExtraNode(node.data.extra, 0);
            return if (declaration.isNone()) .clear else bufferPrefixStatement(module, ast, declaration, target, scope, constructors, fuel);
        },
        else => return .unknown,
    }
}

fn bufferPrefixIsStable(module: *const Module, ast: *const Ast, target: NodeIndex, constructors: *const std.StringHashMapUnmanaged(void)) bool {
    const root = ast.transformed_root orelse @as(NodeIndex, @fromBackingInt(@as(u32, @intCast(ast.nodes.items.len - 1))));
    const sem = &(module.semantic orelse return false);
    const scope = sem.scope_owner_map.get(@backingInt(root)) orelse return false;
    var fuel = ast.nodes.items.len + 1;
    return bufferPrefixStatement(module, ast, root, target, scope, constructors, &fuel) == .target;
}

/// Declaration liveness in a dynamic root does not prove that a source-local
/// Buffer alias still has its initializer value. This guards the production
/// optimization before either retained or legacy AST editing may begin.
pub fn nodeBufferCapabilityValuesAreStable(module: *const Module) bool {
    const ast = if (module.ast) |*value| value else return false;
    const semantic = if (module.semantic) |*value| value else return false;
    if (ast.nodes.items.len == 0 or semantic.scopes.len == 0) return false;
    const root = ast.transformed_root orelse @as(NodeIndex, @fromBackingInt(@as(u32, @intCast(ast.nodes.items.len - 1))));
    if (root.isNone() or @backingInt(root) >= ast.nodes.items.len or ast.getNode(root).tag != .program) return false;
    const scope = semantic.scope_owner_map.get(@backingInt(root)) orelse return false;
    if (scope != 0 or scope >= semantic.scopes.len) return false;
    const program_scope = semantic.scopes[scope];
    if (program_scope.kind != .global and program_scope.kind != .module) return false;
    if (program_scope.blocksMangling()) return false;

    const allocator = ast.allocator;
    var buffer_names: std.StringHashMapUnmanaged(void) = .empty;
    defer buffer_names.deinit(allocator);
    collectNodeBufferModuleObjectNames(allocator, ast, &buffer_names) catch return false;
    var constructor_names: std.StringHashMapUnmanaged(void) = .empty;
    defer constructor_names.deinit(allocator);
    collectNodeBufferCtorNames(allocator, ast, &buffer_names, &constructor_names) catch return false;
    if (constructor_names.count() == 0) return true;

    // Source var reinitializers share their original binding SID but need not
    // increment write_count. Count actual live initializer edges independently.
    var initializer_counts: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer initializer_counts.deinit(allocator);
    var pending: std.ArrayList(NodeIndex) = .empty;
    defer pending.deinit(allocator);
    var live: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer live.deinit(allocator);
    pending.append(allocator, root) catch return false;
    while (pending.pop()) |current| {
        if (current.isNone()) continue;
        const raw = @backingInt(current);
        if (raw >= ast.nodes.items.len) return false;
        const entry = live.getOrPut(allocator, raw) catch return false;
        if (entry.found_existing) continue;
        const node = ast.getNode(current);
        if (node.tag == .variable_declarator) {
            const binding = ast.readExtraNode(node.data.extra, 0);
            const initializer = ast.readExtraNode(node.data.extra, 2);
            if (!initializer.isNone() and !binding.isNone()) {
                var bindings = ast_walk.bindingIdentifiers(allocator, ast, binding, .{}) catch return false;
                defer bindings.deinit();
                while (bindings.next() catch return false) |leaf| {
                    if (@backingInt(leaf) >= semantic.symbol_ids.len) return false;
                    if (semantic.symbol_ids[@backingInt(leaf)]) |id| {
                        const count = initializer_counts.getOrPut(allocator, id) catch return false;
                        if (!count.found_existing) count.value_ptr.* = 0;
                        count.value_ptr.* += 1;
                    }
                }
            }
        }
        var children = ast_walk.children(ast, node);
        while (children.next()) |child| pending.append(allocator, child) catch return false;
    }

    // Conditions contain only &&, parentheses and plain member reads. Their
    // base references all execute in the if statement's actual lexical scope.
    // Discover that scope from live AST owner edges, never from a row being
    // validated or a name lookup. The visited map also rejects scope ambiguity.
    const Work = struct { node: NodeIndex, scope: u32 };
    var stack: std.ArrayList(Work) = .empty;
    defer stack.deinit(allocator);
    var visited: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer visited.deinit(allocator);
    stack.append(allocator, .{ .node = root, .scope = scope }) catch return false;
    while (stack.pop()) |work| {
        if (work.node.isNone()) continue;
        const raw = @backingInt(work.node);
        if (raw >= ast.nodes.items.len) return false;
        const node = ast.getNode(work.node);
        const actual_scope = semantic.scope_owner_map.get(raw) orelse work.scope;
        if (actual_scope >= semantic.scopes.len) return false;
        if (actual_scope != work.scope) {
            const expected_kind: ?@TypeOf(program_scope.kind) = switch (node.tag) {
                .block_statement => .block,
                .switch_statement => .switch_block,
                .catch_clause => .catch_clause,
                else => null,
            };
            if (expected_kind) |kind| {
                if (semantic.scopes[actual_scope].kind != kind or
                    @backingInt(semantic.scopes[actual_scope].parent) != work.scope) return false;
            }
        }
        const seen = visited.getOrPut(allocator, raw) catch return false;
        if (seen.found_existing) {
            if (seen.value_ptr.* != actual_scope) return false;
            continue;
        }
        seen.value_ptr.* = actual_scope;
        if (node.tag == .if_statement) {
            var capabilities: BufferCapabilitySet = .{};
            if (collectNodeBufferCapabilityCondition(ast, node.data.ternary.a, &constructor_names, &capabilities) and capabilities.hasAll()) {
                if (!capabilityConditionValuesAreStable(module, ast, node.data.ternary.a, actual_scope, &initializer_counts) or
                    !bufferPrefixIsStable(module, ast, work.node, &constructor_names)) return false;
            }
        }
        var children = ast_walk.children(ast, node);
        while (children.next()) |child| stack.append(allocator, .{ .node = child, .scope = actual_scope }) catch return false;
    }
    return true;
}

fn capabilityConditionValuesAreStable(module: *const Module, ast: *const Ast, condition: NodeIndex, scope: u32, initializer_counts: *const std.AutoHashMapUnmanaged(u32, u32)) bool {
    const semantic = if (module.semantic) |*value| value else return false;
    if (condition.isNone() or @backingInt(condition) >= ast.nodes.items.len) return false;
    const node = ast.getNode(condition);
    return switch (node.tag) {
        .parenthesized_expression => capabilityConditionValuesAreStable(module, ast, node.data.unary.operand, scope, initializer_counts),
        .logical_expression => node.data.binary.flags == @backingInt(Kind.amp2) and
            capabilityConditionValuesAreStable(module, ast, node.data.binary.left, scope, initializer_counts) and
            capabilityConditionValuesAreStable(module, ast, node.data.binary.right, scope, initializer_counts),
        .static_member_expression => blk: {
            const parts = staticMemberParts(ast, condition) orelse break :blk false;
            if (parts.object.isNone() or @backingInt(parts.object) >= ast.nodes.items.len or
                ast.getNode(parts.object).tag != .identifier_reference or @backingInt(parts.object) >= semantic.symbol_ids.len) break :blk false;
            const id = semantic.symbol_ids[@backingInt(parts.object)] orelse break :blk false;
            if (!exactBufferValueRead(module, parts.object, id, scope)) break :blk false;
            const object = exactNodeBufferConstructorObject(module, ast, id) orelse break :blk false;
            break :blk initializer_counts.get(id) == 1 and initializer_counts.get(object) == 1;
        },
        else => false,
    };
}

pub fn foldNodeBufferCapabilityIfs(allocator: std.mem.Allocator, ast: *Ast) bool {
    var buffer_names: std.StringHashMapUnmanaged(void) = .empty;
    defer buffer_names.deinit(allocator);
    collectNodeBufferModuleObjectNames(allocator, ast, &buffer_names) catch return false;
    if (buffer_names.count() == 0) return false;

    var buffer_ctor_names: std.StringHashMapUnmanaged(void) = .empty;
    defer buffer_ctor_names.deinit(allocator);
    collectNodeBufferCtorNames(allocator, ast, &buffer_names, &buffer_ctor_names) catch return false;
    if (buffer_ctor_names.count() == 0) return false;

    var dead_fallback_names: std.StringHashMapUnmanaged(void) = .empty;
    defer dead_fallback_names.deinit(allocator);

    var changed = false;
    for (ast.nodes.items, 0..) |node, i| {
        if (node.tag != .if_statement) continue;
        var caps: BufferCapabilitySet = .{};
        if (!collectNodeBufferCapabilityCondition(ast, node.data.ternary.a, &buffer_ctor_names, &caps)) continue;
        if (!caps.hasAll()) continue;
        collectDeadAlternateCjsExportIdentifiers(allocator, ast, node.data.ternary.c, &dead_fallback_names) catch {};
        const kept = singleBlockStatement(ast, node.data.ternary.b) orelse node.data.ternary.b;
        const kept_ni = @backingInt(kept);
        if (kept_ni >= ast.nodes.items.len) continue;
        ast.nodes.items[i] = ast.nodes.items[kept_ni];
        changed = true;
    }
    if (changed and dead_fallback_names.count() > 0) {
        removeDeadFallbackSetupStatements(ast, &dead_fallback_names, &buffer_ctor_names);
    }
    return changed;
}

/// Remove the dead alternate from supported branch shapes and return the
/// complete pre-edit node set that becomes unreachable. Keep the if and
/// consequent nodes in place so their graph identities and the surrounding
/// module's CJS statement shape remain stable. A direct `var` consequent does
/// not create a lexical scope, so its binding stays in the same function or
/// module scope. Lexical declarations and other statement shapes still use
/// full reanalysis.
pub fn foldNodeBufferCapabilityIfsRetainingGraph(
    allocator: std.mem.Allocator,
    ast: *Ast,
    removed_nodes: *std.ArrayListUnmanaged(NodeIndex),
    semantic: ?*const ModuleSemanticData,
    needs_semantic_reanalysis: *bool,
) !bool {
    return foldNodeBufferCapabilityIfsWithContext(allocator, ast, removed_nodes, needs_semantic_reanalysis, null, semantic, null, null, false);
}

/// The module owns the actual AST and semantic tables. Only this typed path
/// may retain a fallback function declaration after removing its export read.
pub fn foldNodeBufferCapabilityIfsForModule(
    allocator: std.mem.Allocator,
    module: *const Module,
    ast: *Ast,
    removed_nodes: *std.ArrayListUnmanaged(NodeIndex),
    needs_semantic_reanalysis: *bool,
) !bool {
    if (module.ast == null or module.semantic == null or &module.ast.? != ast) return false;
    return foldNodeBufferCapabilityIfsWithContext(allocator, ast, removed_nodes, needs_semantic_reanalysis, module, if (module.semantic) |*sem| sem else null, null, null, false);
}

/// Producer-owned relation consumed by named-export reachability. It is held
/// only for one TreeShaker lifetime and never persisted in module/cache data.
pub const FoldedNodeBufferExport = struct {
    kind: enum { module_object, buffer_constructor },
    ast_owner: *const Ast,
    statement: NodeIndex,
    kept: NodeIndex,
    assignment: NodeIndex,
    module_reference: NodeIndex,
    module_symbol: u32,
    object_reference: NodeIndex,
    object_symbol: u32,
    buffer_object_symbol: u32,
};

pub fn foldNodeBufferCapabilityIfsForModuleWithExports(
    allocator: std.mem.Allocator,
    module: *const Module,
    ast: *Ast,
    removed_nodes: *std.ArrayListUnmanaged(NodeIndex),
    needs_semantic_reanalysis: *bool,
    exports: *std.ArrayListUnmanaged(FoldedNodeBufferExport),
) !bool {
    exports.clearRetainingCapacity();
    if (module.ast == null or module.semantic == null or &module.ast.? != ast) return false;
    return foldNodeBufferCapabilityIfsWithContext(allocator, ast, removed_nodes, needs_semantic_reanalysis, module, if (module.semantic) |*sem| sem else null, exports, null, false);
}

/// A source witness is captured only from the actual installed AST/semantic
/// pair. A clone cannot enter this selector by sharing numeric node/SymbolIds.
/// The owned node/extra snapshots also make late publication reject edits to
/// the original AST while preparation is in progress.
pub const BufferCapabilityPlan = struct {
    module_owner: *const Module,
    ast_owner: *const Ast,
    nodes: []const Node,
    extra: []const u32,
    nodes_backing: []const Node,
    extra_backing: []const u32,
    strings_backing: []const u8,
    strings_snapshot: []const u8,
    transformed_root: ?NodeIndex,
    transform_boundary: ?u32,
    source_bytes: []const u8,
    ids_snapshot: []const ?u32,
    symbols_snapshot: []const @import("../../semantic/symbol.zig").Symbol,
    references_snapshot: []const @import("../../semantic/symbol.zig").Reference,
    scopes_snapshot: []const Scope,
    scopes_backing: []const Scope,
    scope_maps_snapshot: []const std.StringHashMapUnmanaged(usize),
    scope_owners_snapshot: std.AutoHashMapUnmanaged(u32, u32),
    import_records_backing: []const types.ImportRecord,
    import_records_snapshot: []const types.ImportRecord,
    symbol_ids: []const ?u32,
    symbols: []const @import("../../semantic/symbol.zig").Symbol,
    references: []const @import("../../semantic/symbol.zig").Reference,
    branches: []const BufferCapabilityFoldBranch,
    setup_statements: []const NodeIndex,
    removed_nodes: []const NodeIndex,
    retirements: []const @import("../../semantic/editor.zig").KnownUnreachableFunction,
    exports: []const FoldedNodeBufferExport,

    pub fn isCurrent(self: *const BufferCapabilityPlan, module: *const Module) bool {
        if (module != self.module_owner or module.ast == null or module.semantic == null or &module.ast.? != self.ast_owner) return false;
        const ast = &module.ast.?;
        const sem = &module.semantic.?;
        if (module.import_records.ptr != self.import_records_backing.ptr or module.import_records.len != self.import_records_snapshot.len) return false;
        for (module.import_records, self.import_records_snapshot) |current, captured| if (!std.meta.eql(current, captured)) return false;
        if (sem.scopes.ptr != self.scopes_backing.ptr or sem.scopes.len != self.scopes_backing.len or
            !std.mem.eql(u8, std.mem.sliceAsBytes(sem.scopes), std.mem.sliceAsBytes(self.scopes_snapshot)) or
            sem.scope_maps.len != self.scope_maps_snapshot.len or sem.scope_owner_map.count() != self.scope_owners_snapshot.count()) return false;
        var owners = self.scope_owners_snapshot.iterator();
        while (owners.next()) |entry| if (sem.scope_owner_map.get(entry.key_ptr.*) != entry.value_ptr.*) return false;
        for (sem.scope_maps, self.scope_maps_snapshot) |actual, expected| {
            if (actual.count() != expected.count()) return false;
            var entries = expected.iterator();
            while (entries.next()) |entry| if (actual.get(entry.key_ptr.*) != entry.value_ptr.*) return false;
        }
        return ast.nodes.items.ptr == self.nodes_backing.ptr and ast.nodes.items.len == self.nodes_backing.len and
            ast.extra_data.items.ptr == self.extra_backing.ptr and ast.extra_data.items.len == self.extra_backing.len and
            ast.string_table.items.ptr == self.strings_backing.ptr and ast.string_table.items.len == self.strings_backing.len and
            std.mem.eql(u8, ast.string_table.items, self.strings_snapshot) and
            ast.transformed_root == self.transformed_root and ast.transform_boundary == self.transform_boundary and
            ast.source.ptr == self.source_bytes.ptr and ast.source.len == self.source_bytes.len and
            std.mem.eql(?u32, sem.symbol_ids, self.ids_snapshot) and
            std.mem.eql(u8, std.mem.sliceAsBytes(sem.symbols.items), std.mem.sliceAsBytes(self.symbols_snapshot)) and
            std.mem.eql(u8, std.mem.sliceAsBytes(sem.references), std.mem.sliceAsBytes(self.references_snapshot)) and
            sem.symbol_ids.ptr == self.symbol_ids.ptr and sem.symbol_ids.len == self.symbol_ids.len and
            sem.symbols.items.ptr == self.symbols.ptr and sem.symbols.items.len == self.symbols.len and
            sem.references.ptr == self.references.ptr and sem.references.len == self.references.len and
            std.mem.eql(u8, std.mem.sliceAsBytes(ast.nodes.items), std.mem.sliceAsBytes(self.nodes)) and
            std.mem.eql(u32, ast.extra_data.items, self.extra);
    }

    /// Preserve the pre-transaction test contract: the selected alternate and
    /// setup edges disappear, while condition reads remain on the same graph.
    pub fn cloneLegacyFoldForTest(self: *const BufferCapabilityPlan, module: *const Module, allocator: std.mem.Allocator) !?struct { ast: Ast, removed_nodes: []const NodeIndex } {
        if (!@import("builtin").is_test) @compileError("legacy Buffer fold adapter is test-only");
        if (!self.isCurrent(module)) return null;
        var candidate = try Ast.cloneForTransformer(self.ast_owner, allocator);
        var removed: std.ArrayListUnmanaged(NodeIndex) = .empty;
        var seen = try std.DynamicBitSet.initEmpty(allocator, candidate.nodes.items.len);
        for (self.branches) |branch| try appendSubtreeNodes(allocator, self.ast_owner, branch.retained_var_initializer orelse branch.alternate, &seen, &removed);
        for (self.setup_statements) |setup| try appendSubtreeNodes(allocator, self.ast_owner, setup, &seen, &removed);
        applyBufferCapabilityEdits(&candidate, self.branches, self.setup_statements);
        return .{ .ast = candidate, .removed_nodes = removed.items };
    }

    pub fn cloneForPublication(self: *const BufferCapabilityPlan, module: *const Module, allocator: std.mem.Allocator) !?Ast {
        if (!self.isCurrent(module)) return null;
        var candidate = try Ast.cloneForTransformer(self.ast_owner, allocator);
        // The existing Node capability proof establishes a true condition.
        // Keep the if/consequent owner slots stable while retiring the now
        // unnecessary condition reads together with the dead alternate.
        const true_span = try candidate.addString("true");
        applyBufferCapabilityEdits(&candidate, self.branches, self.setup_statements);
        for (self.branches) |branch| {
            const condition = candidate.getNode(branch.if_index).data.ternary.a;
            candidate.nodes.items[@backingInt(condition)] = .{ .tag = .boolean_literal, .span = true_span, .data = .{ .none = 0 } };
        }
        return candidate;
    }
};

pub fn prepareNodeBufferCapabilityPlan(allocator: std.mem.Allocator, module: *const Module) !?BufferCapabilityPlan {
    const ast = if (module.ast) |*value| value else return null;
    const sem = if (module.semantic) |*value| value else return null;
    // A winning builtin-source receipt belongs to its closed provider, not to
    // this optional user-module value optimization.
    if (module.runtime_helper_source != null or module.runtime_helper_cache_source != null) return null;
    if (!nodeBufferCapabilityValuesAreStable(module)) return null;
    var removed: std.ArrayListUnmanaged(NodeIndex) = .empty;
    defer removed.deinit(allocator);
    var exports: std.ArrayListUnmanaged(FoldedNodeBufferExport) = .empty;
    defer exports.deinit(allocator);
    var needs = false;
    var plan: ?BufferCapabilityPlan = null;
    _ = try foldNodeBufferCapabilityIfsWithContext(allocator, @constCast(ast), &removed, &needs, module, sem, &exports, &plan, false);
    if (plan) |value| {
        for (value.branches) |branch| {
            const condition = ast.getNode(branch.if_index).data.ternary.a;
            if (!capabilityConditionHasBuiltinOrigins(module, ast, condition)) return null;
        }
    }
    return plan;
}

pub fn prepareLegacyNodeBufferCapabilityPlanForTest(allocator: std.mem.Allocator, module: *const Module) !?BufferCapabilityPlan {
    if (!@import("builtin").is_test) @compileError("legacy Buffer selector is test-only");
    const ast = if (module.ast) |*value| value else return null;
    const sem = if (module.semantic) |*value| value else return null;
    var removed: std.ArrayListUnmanaged(NodeIndex) = .empty;
    var needs = false;
    var plan: ?BufferCapabilityPlan = null;
    _ = try foldNodeBufferCapabilityIfsWithContext(allocator, @constCast(ast), &removed, &needs, module, sem, null, &plan, true);
    return plan;
}

fn foldNodeBufferCapabilityIfsWithContext(
    allocator: std.mem.Allocator,
    ast: *Ast,
    removed_nodes: *std.ArrayListUnmanaged(NodeIndex),
    needs_semantic_reanalysis: *bool,
    module: ?*const Module,
    semantic: ?*const ModuleSemanticData,
    folded_exports: ?*std.ArrayListUnmanaged(FoldedNodeBufferExport),
    prepared_plan: ?*?BufferCapabilityPlan,
    comptime legacy_test_selection: bool,
) !bool {
    removed_nodes.clearRetainingCapacity();
    needs_semantic_reanalysis.* = false;

    var buffer_names: std.StringHashMapUnmanaged(void) = .empty;
    defer buffer_names.deinit(allocator);
    try collectNodeBufferModuleObjectNames(allocator, ast, &buffer_names);
    if (buffer_names.count() == 0) return false;

    var buffer_ctor_names: std.StringHashMapUnmanaged(void) = .empty;
    defer buffer_ctor_names.deinit(allocator);
    try collectNodeBufferCtorNames(allocator, ast, &buffer_names, &buffer_ctor_names);
    if (buffer_ctor_names.count() == 0) return false;

    // The arena retains old pre-minify if/block copies. Only the current
    // program may authorize a semantic edit or provide an export fact.
    var reachable: ?std.DynamicBitSet = null;
    defer if (reachable) |*mask| mask.deinit();
    if (module != null or semantic != null) {
        _ = programNode(ast) orelse return false;
        const root = ast.transformed_root orelse @as(NodeIndex, @fromBackingInt(@as(u32, @intCast(ast.nodes.items.len - 1))));
        const nodes = try ast_walk.collectReachableNodeIndicesFrom(allocator, ast, root);
        defer allocator.free(nodes);
        var mask = try std.DynamicBitSet.initEmpty(allocator, ast.nodes.items.len);
        for (nodes) |raw| mask.set(raw);
        reachable = mask;
    }

    var branches: std.ArrayListUnmanaged(BufferCapabilityFoldBranch) = .empty;
    defer branches.deinit(allocator);
    var dead_fallback_names: std.StringHashMapUnmanaged(void) = .empty;
    defer dead_fallback_names.deinit(allocator);

    for (ast.nodes.items, 0..) |node, i| {
        if (node.tag != .if_statement) continue;
        if (reachable) |mask| if (!mask.isSet(i)) continue;
        var caps: BufferCapabilitySet = .{};
        if (!collectNodeBufferCapabilityCondition(ast, node.data.ternary.a, &buffer_ctor_names, &caps)) continue;
        if (!caps.hasAll()) continue;

        const kept = node.data.ternary.b;
        if (kept.isNone() or @backingInt(kept) >= ast.nodes.items.len) return false;
        const kept_node = ast.nodes.items[@backingInt(kept)];
        const kept_variable_kind: ?u32 = if (kept_node.tag == .variable_declaration) blk: {
            const kind_index = kept_node.data.extra;
            if (kind_index >= ast.extra_data.items.len) return false;
            break :blk ast.extra_data.items[kind_index];
        } else null;
        if (!isRetainableNodeBufferCapabilityBranch(kept_node.tag, kept_variable_kind)) return false;
        const alternate = node.data.ternary.c;
        var retained_var_initializer: ?NodeIndex = null;
        if (!alternate.isNone()) {
            if (@backingInt(alternate) >= ast.nodes.items.len) return false;
            const alternate_tag = ast.nodes.items[@backingInt(alternate)].tag;
            if (alternate_tag == .expression_statement or alternate_tag == .block_statement) {
                try collectDeadAlternateCjsExportIdentifiers(allocator, ast, alternate, &dead_fallback_names);
            } else if (alternate_tag == .variable_declaration and module != null) {
                retained_var_initializer = exactSimpleVarAlternateInitializer(
                    module.?,
                    ast,
                    @fromBackingInt(@intCast(i)),
                    alternate,
                ) orelse return false;
            } else return false;
        }
        try branches.append(allocator, .{
            .if_index = @fromBackingInt(@intCast(i)),
            .kept = kept,
            .alternate = alternate,
            .retained_var_initializer = retained_var_initializer,
        });
    }
    if (branches.items.len == 0) return false;
    // The retained graph edit removes the alternate's exact reference edges.
    // The TreeShaker separately seeds every top-level declaration and writer
    // in a dynamic root, so direct eval/with can still observe fallback
    // functions without forcing a semantic rebuild. Missing root scope data
    // cannot prove that the retained graph is complete and remains fail-closed.
    needs_semantic_reanalysis.* = if (semantic) |sem| sem.scopes.len == 0 else true;
    const requires_function_consumer = hasTopLevelDeadFallbackFunction(ast, &dead_fallback_names);

    var seen = try std.DynamicBitSet.initEmpty(allocator, ast.nodes.items.len);
    defer seen.deinit();
    for (branches.items) |branch| {
        try appendSubtreeNodes(
            allocator,
            ast,
            branch.retained_var_initializer orelse branch.alternate,
            &seen,
            removed_nodes,
        );
    }

    if (prepared_plan != null and !legacy_test_selection) {
        for (branches.items) |branch| {
            try appendSubtreeNodes(allocator, ast, ast.getNode(branch.if_index).data.ternary.a, &seen, removed_nodes);
        }
    }

    var setup_statements: std.ArrayListUnmanaged(NodeIndex) = .empty;
    defer setup_statements.deinit(allocator);
    if (dead_fallback_names.count() > 0) {
        const root = programNode(ast) orelse return false;
        const list = root.data.list;
        if (list.start + list.len > ast.extra_data.items.len) return false;
        for (ast.extra_data.items[list.start .. list.start + list.len]) |raw_stmt| {
            const stmt_idx: NodeIndex = @fromBackingInt(@intCast(raw_stmt));
            if (stmt_idx.isNone() or @backingInt(stmt_idx) >= ast.nodes.items.len) continue;
            const stmt = ast.nodes.items[@backingInt(stmt_idx)];
            // A live setup call may have arbitrary effects. Transactional
            // folding never removes it, even when its arguments name fallback
            // storage. Only the unreachable alternate's calls can disappear.
            if (prepared_plan != null and !legacy_test_selection and stmt.tag == .expression_statement) {
                const expression = stmt.data.unary.operand;
                if (!expression.isNone() and @backingInt(expression) < ast.nodes.items.len and
                    ast.getNode(expression).tag == .call_expression) continue;
            }
            if (!isDeadFallbackSetupStatement(ast, stmt, &dead_fallback_names, &buffer_ctor_names)) continue;
            try setup_statements.append(allocator, stmt_idx);
            try appendSubtreeNodes(allocator, ast, stmt_idx, &seen, removed_nodes);
        }
    }

    if (requires_function_consumer) {
        if (module) |owner| {
            // No declaration is removed. Exact alternate reads determine the
            // surviving function identity; the retained graph updater removes
            // those reads and rebuilds statement liveness from its new counts.
            if (!try fallbackFunctionGraphIsStable(allocator, owner, ast, branches.items, setup_statements.items, &dead_fallback_names, prepared_plan != null and !legacy_test_selection, &buffer_ctor_names, &seen)) return false;
            needs_semantic_reanalysis.* = false;
        }
    }

    if (folded_exports) |out| {
        if (module) |owner| {
            for (branches.items) |branch| {
                if (foldedBufferExportAt(owner, ast, branch.if_index, branch.kept)) |fact| {
                    try out.append(allocator, fact);
                } else if (requires_function_consumer) return false;
            }
        }
    }

    if (prepared_plan) |out| {
        if (needs_semantic_reanalysis.*) return false;
        const owner = module orelse return false;
        const sem = semantic orelse return false;
        var retirements: std.ArrayListUnmanaged(@import("../../semantic/editor.zig").KnownUnreachableFunction) = .empty;
        defer retirements.deinit(allocator);
        for (removed_nodes.items) |index| {
            const item = ast.getNode(index);
            if (item.tag != .function_expression and item.tag != .function_declaration and item.tag != .arrow_function_expression) continue;
            const parameter_slot: u32 = if (item.tag == .arrow_function_expression) 0 else ast_mod.FunctionExtra.params;
            if (!ast.hasExtra(item.data.extra, parameter_slot + 1)) return false;
            const scope = sem.scope_owner_map.get(@backingInt(index)) orelse return false;
            try retirements.append(allocator, .{ .owner = index, .scope = @fromBackingInt(scope), .params = ast.readExtraNode(item.data.extra, parameter_slot), .body = ast.readExtraNode(item.data.extra, parameter_slot + 1), .body_scope = if (sem.scope_owner_map.get(@backingInt(ast.readExtraNode(item.data.extra, parameter_slot + 1)))) |value| @fromBackingInt(value) else .none });
        }
        const scope_maps_snapshot = try allocator.alloc(std.StringHashMapUnmanaged(usize), sem.scope_maps.len);
        for (sem.scope_maps, scope_maps_snapshot) |map, *snapshot| snapshot.* = try map.clone(allocator);
        out.* = .{
            .module_owner = owner,
            .ast_owner = ast,
            .nodes = try allocator.dupe(Node, ast.nodes.items),
            .extra = try allocator.dupe(u32, ast.extra_data.items),
            .nodes_backing = ast.nodes.items,
            .extra_backing = ast.extra_data.items,
            .strings_backing = ast.string_table.items,
            .strings_snapshot = try allocator.dupe(u8, ast.string_table.items),
            .transformed_root = ast.transformed_root,
            .transform_boundary = ast.transform_boundary,
            .source_bytes = ast.source,
            .ids_snapshot = try allocator.dupe(?u32, sem.symbol_ids),
            .symbols_snapshot = try allocator.dupe(@import("../../semantic/symbol.zig").Symbol, sem.symbols.items),
            .references_snapshot = try allocator.dupe(@import("../../semantic/symbol.zig").Reference, sem.references),
            .scopes_snapshot = try allocator.dupe(Scope, sem.scopes),
            .scopes_backing = sem.scopes,
            .scope_maps_snapshot = scope_maps_snapshot,
            .scope_owners_snapshot = try sem.scope_owner_map.clone(allocator),
            .import_records_backing = owner.import_records,
            .import_records_snapshot = try allocator.dupe(types.ImportRecord, owner.import_records),
            .symbol_ids = sem.symbol_ids,
            .symbols = sem.symbols.items,
            .references = sem.references,
            .branches = try allocator.dupe(BufferCapabilityFoldBranch, branches.items),
            .setup_statements = try allocator.dupe(NodeIndex, setup_statements.items),
            .removed_nodes = try allocator.dupe(NodeIndex, removed_nodes.items),
            .retirements = try allocator.dupe(@import("../../semantic/editor.zig").KnownUnreachableFunction, retirements.items),
            .exports = if (folded_exports) |facts| try allocator.dupe(FoldedNodeBufferExport, facts.items) else &.{},
        };
        return true;
    }
    applyBufferCapabilityEdits(ast, branches.items, setup_statements.items);
    return true;
}

fn applyBufferCapabilityEdits(ast: *Ast, branches: []const BufferCapabilityFoldBranch, setup_statements: []const NodeIndex) void {
    for (branches) |branch| {
        if (branch.retained_var_initializer) |_| {
            const alternate = ast.nodes.items[@backingInt(branch.alternate)];
            const declaration_list_start = ast.extra_data.items[alternate.data.extra + 1];
            const declaration_raw = ast.extra_data.items[declaration_list_start];
            const declarator = ast.nodes.items[declaration_raw];
            ast.extra_data.items[declarator.data.extra + 2] = @backingInt(NodeIndex.none);
        } else {
            ast.nodes.items[@backingInt(branch.if_index)].data.ternary.c = .none;
        }
    }
    for (setup_statements) |stmt_idx| {
        const stmt = ast.nodes.items[@backingInt(stmt_idx)];
        ast.nodes.items[@backingInt(stmt_idx)] = .{
            .tag = .empty_statement,
            .span = stmt.span,
            .data = .{ .none = 0 },
        };
    }
}

// Classify fallback declarations before requiring the exact function consumer.
fn hasTopLevelDeadFallbackFunction(
    ast: *const Ast,
    dead_names: *const std.StringHashMapUnmanaged(void),
) bool {
    if (dead_names.count() == 0) return false;
    const root = programNode(ast) orelse return true;
    const list = root.data.list;
    const extra_len = ast.extra_data.items.len;
    if (list.start > extra_len or list.len > extra_len - list.start) return true;
    for (ast.extra_data.items[list.start .. list.start + list.len]) |raw_stmt| {
        const stmt_idx: NodeIndex = @fromBackingInt(@intCast(raw_stmt));
        if (stmt_idx.isNone() or @backingInt(stmt_idx) >= ast.nodes.items.len) return true;
        const stmt = ast.nodes.items[@backingInt(stmt_idx)];
        if (stmt.tag != .function_declaration) continue;
        const extra_base: usize = stmt.data.extra;
        const name_offset: usize = ast_mod.FunctionExtra.name;
        if (extra_base > extra_len or name_offset >= extra_len - extra_base) return true;
        const name_idx: NodeIndex = @fromBackingInt(@intCast(ast.extra_data.items[extra_base + name_offset]));
        if (name_idx.isNone() or @backingInt(name_idx) >= ast.nodes.items.len) return true;
        const name = ast.nodes.items[@backingInt(name_idx)];
        if (name.tag != .binding_identifier) return true;
        if (dead_names.contains(ast.getText(name.span))) return true;
    }
    return false;
}

fn isRetainableNodeBufferCapabilityBranch(tag: Node.Tag, variable_kind: ?u32) bool {
    return switch (tag) {
        .expression_statement, .block_statement => true,
        .variable_declaration => variable_kind != null and
            variable_kind.? == @backingInt(ast_mod.VariableDeclarationKind.@"var"),
        else => false,
    };
}

test "retained Node Buffer capability branch accepts only var declarations" {
    const var_kind: u32 = @backingInt(ast_mod.VariableDeclarationKind.@"var");
    try std.testing.expect(isRetainableNodeBufferCapabilityBranch(.expression_statement, null));
    try std.testing.expect(isRetainableNodeBufferCapabilityBranch(.block_statement, null));
    try std.testing.expect(isRetainableNodeBufferCapabilityBranch(.variable_declaration, var_kind));
    try std.testing.expect(!isRetainableNodeBufferCapabilityBranch(.variable_declaration, null));
    try std.testing.expect(!isRetainableNodeBufferCapabilityBranch(
        .variable_declaration,
        @backingInt(ast_mod.VariableDeclarationKind.let),
    ));
    try std.testing.expect(!isRetainableNodeBufferCapabilityBranch(
        .variable_declaration,
        @backingInt(ast_mod.VariableDeclarationKind.@"const"),
    ));
    try std.testing.expect(!isRetainableNodeBufferCapabilityBranch(
        .variable_declaration,
        @backingInt(ast_mod.VariableDeclarationKind.using),
    ));
    try std.testing.expect(!isRetainableNodeBufferCapabilityBranch(
        .variable_declaration,
        @backingInt(ast_mod.VariableDeclarationKind.await_using),
    ));
    try std.testing.expect(!isRetainableNodeBufferCapabilityBranch(.if_statement, null));
}

test "retained Node Buffer fold defers missing semantic scope data to full analysis" {
    const sources = [_][]const u8{
        \\var buffer = require("buffer"); var B = buffer.Buffer;
        \\if (B.from && B.alloc && B.allocUnsafe && B.allocUnsafeSlow) { module.exports = buffer; }
        \\else { exports.Buffer = SafeBuffer; }
        \\function SafeBuffer() { return 1; }
        ,
        \\var buffer = require("buffer"); var B = buffer.Buffer;
        \\if (B.from && B.alloc && B.allocUnsafe && B.allocUnsafeSlow) { module.exports = buffer; }
        \\else { exports.Buffer = SafeBuffer; }
        \\function unrelated() { return 1; }
        ,
        \\var buffer = require("buffer"); var B = buffer.Buffer;
        \\if (B.from && B.alloc && B.allocUnsafe && B.allocUnsafeSlow) { module.exports = buffer; }
        \\else { exports.Buffer = SafeBuffer; }
        \\function outer() { function SafeBuffer() { return 1; } }
        ,
        \\var buffer = require("buffer"); var B = buffer.Buffer;
        \\if (B.from && B.alloc && B.allocUnsafe && B.allocUnsafeSlow) { module.exports = buffer; }
        \\else { exports.Buffer = SafeBuffer; }
        \\async function SafeBuffer() { return 1; }
        ,
        \\var buffer = require("buffer"); var B = buffer.Buffer;
        \\if (B.from && B.alloc && B.allocUnsafe && B.allocUnsafeSlow) { module.exports = buffer; }
        \\else { exports.Buffer = SafeBuffer; }
        \\function* SafeBuffer() { return 1; }
        ,
        \\var buffer = require("buffer"); var B = buffer.Buffer;
        \\if (B.from && B.alloc && B.allocUnsafe && B.allocUnsafeSlow) { module.exports = buffer; }
        \\else { exports.Buffer = SafeBuffer; }
        \\function SafeBuffer(value) { return eval("value"); }
        ,
        \\var buffer = require("buffer"); var B = buffer.Buffer;
        \\if (B.from && B.alloc && B.allocUnsafe && B.allocUnsafeSlow) { module.exports = buffer; }
        \\else { exports.Buffer = SafeBuffer; }
        \\function SafeBuffer() { return 1; }
        \\function SafeBuffer(value) { return value; }
        ,
        \\var buffer = require("buffer"); var B = buffer.Buffer;
        \\if (B.from && B.alloc && B.allocUnsafe && B.allocUnsafeSlow) { module.exports = buffer; }
        \\else { exports.Buffer = Other; exports.Slow = SafeBuffer; }
        \\function Other() { return 1; }
        \\function SafeBuffer() { return 2; }
        ,
        \\var buffer = require("buffer"); var B = buffer.Buffer;
        \\if (B.from && B.alloc && B.allocUnsafe && B.allocUnsafeSlow) { module.exports = buffer; }
        \\else { exports.Buffer = SafeBuffer; }
        \\function SafeBuffer() { return 1; }
        \\function unrelated() { return 2; }
        ,
        \\function SafeBuffer() { return 1; }
        \\var buffer = require("buffer"); var B = buffer.Buffer;
        \\if (B.from && B.alloc && B.allocUnsafe && B.allocUnsafeSlow) { module.exports = buffer; }
        \\else { exports.Buffer = SafeBuffer; }
    };
    for (sources) |source| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        var scanner = try @import("../../lexer/scanner.zig").Scanner.init(allocator, source);
        scanner.is_module = false;
        var parser = @import("../../parser/parser.zig").Parser.init(allocator, &scanner);
        parser.configureFromExtension(".cjs");
        parser.is_module = false;
        _ = try parser.parse();
        var removed_nodes: std.ArrayListUnmanaged(NodeIndex) = .empty;
        var needs_semantic_reanalysis = false;
        try std.testing.expect(try foldNodeBufferCapabilityIfsRetainingGraph(
            allocator,
            &parser.ast,
            &removed_nodes,
            null,
            &needs_semantic_reanalysis,
        ));
        try std.testing.expect(removed_nodes.items.len > 0);
        try std.testing.expect(needs_semantic_reanalysis);
    }
}

fn exactTopLevelVarInitializer(module: *const Module, ast: *const Ast, id: u32) ?NodeIndex {
    const sem = &(module.semantic orelse return null);
    if (id >= sem.symbols.items.len or sem.scopes.len == 0) return null;
    const symbol = sem.symbols.items[id];
    if (symbol.kind != .variable_var or symbol.synthetic_kind != null or symbol.write_count != 0) return null;
    const program_scope = sem.scope_owner_map.get(@intCast(ast.nodes.items.len - 1)) orelse return null;
    if (program_scope >= sem.scopes.len) return null;
    if (symbol.scope_id.toIndex() != program_scope) {
        const wrapper = sem.scopes[program_scope].parent;
        if (wrapper.isNone() or symbol.scope_id != wrapper or wrapper.toIndex() >= sem.scopes.len or
            sem.scopes[wrapper.toIndex()].kind != .function or !sem.scopes[wrapper.toIndex()].parent.isNone()) return null;
    }
    const program = programNode(ast) orelse return null;
    const list = program.data.list;
    if (list.start > ast.extra_data.items.len or list.len > ast.extra_data.items.len - list.start) return null;
    var found: ?NodeIndex = null;
    for (ast.extra_data.items[list.start..][0..list.len]) |raw| {
        if (raw >= ast.nodes.items.len) return null;
        const statement = ast.nodes.items[raw];
        if (statement.tag != .variable_declaration) continue;
        const extra = statement.data.extra;
        if (!ast.hasExtra(extra, 2)) return null;
        const start = ast.readExtra(extra, 1);
        const len = ast.readExtra(extra, 2);
        if (start > ast.extra_data.items.len or len > ast.extra_data.items.len - start) return null;
        for (ast.extra_data.items[start..][0..len]) |decl_raw| {
            if (decl_raw >= ast.nodes.items.len) return null;
            const declaration = ast.nodes.items[decl_raw];
            if (declaration.tag != .variable_declarator or !ast.hasExtra(declaration.data.extra, 2)) return null;
            const binding = ast.readExtraNode(declaration.data.extra, 0);
            if (binding.isNone() or @backingInt(binding) >= sem.symbol_ids.len) return null;
            if (sem.symbol_ids[@backingInt(binding)] != id) continue;
            const initializer = ast.readExtraNode(declaration.data.extra, 2);
            if (found != null or initializer.isNone() or @backingInt(initializer) >= ast.nodes.items.len) return null;
            found = initializer;
        }
    }
    return found;
}

fn exactNodeBufferObjectBinding(module: *const Module, ast: *const Ast, id: u32) bool {
    const sem = &(module.semantic orelse return false);
    const initializer = exactTopLevelVarInitializer(module, ast, id) orelse return false;
    if (!isRequireBufferCall(ast, initializer)) return false;
    const callee = ast.readExtraNode(ast.getNode(initializer).data.extra, 0);
    // This is the unresolved CommonJS host read, not a local `require`.
    return @backingInt(callee) < sem.symbol_ids.len and sem.symbol_ids[@backingInt(callee)] == null and sem.unresolved_references.contains("require");
}

/// The spelling of a require argument does not prove the emitted dependency.
/// Its actual source literal must own one resolved external builtin record.
pub fn nodeBufferObjectImportIsBuiltin(module: *const Module, ast: *const Ast, id: u32) bool {
    if (module.ast == null or &module.ast.? != ast or !exactNodeBufferObjectBinding(module, ast, id)) return false;
    const sem = &(module.semantic orelse return false);
    const initializer = exactTopLevelVarInitializer(module, ast, id) orelse return false;
    const call = ast.getNode(initializer);
    if (!ast.hasExtra(call.data.extra, 3) or ast.readExtra(call.data.extra, 3) & ~@as(u32, ast_mod.CallFlags.is_pure) != 0) return false;
    const callee = ast.readExtraNode(call.data.extra, 0);
    for (sem.references) |row| if (row.node_index == callee) return false;
    const root = ast.transformed_root orelse @as(NodeIndex, @fromBackingInt(@as(u32, @intCast(ast.nodes.items.len - 1))));
    var scope: ScopeId = @fromBackingInt(sem.scope_owner_map.get(@backingInt(root)) orelse return false);
    var fuel = sem.scopes.len + 1;
    while (!scope.isNone() and fuel > 0) : (fuel -= 1) {
        if (scope.toIndex() >= sem.scopes.len or scope.toIndex() >= sem.scope_maps.len or
            sem.scope_maps[scope.toIndex()].contains("require")) return false;
        scope = sem.scopes[scope.toIndex()].parent;
    }
    if (!scope.isNone()) return false;
    const start = ast.readExtra(call.data.extra, 1);
    const literal: NodeIndex = @fromBackingInt(ast.extra_data.items[start]);
    const literal_node = ast.getNode(literal);
    const spelling = Ast.stripStringQuotes(ast.getText(literal_node.span));
    var count: usize = 0;
    for (module.import_records) |record| {
        if (record.source_node != literal) continue;
        count += 1;
        if (record.kind != .require or !std.meta.eql(record.span, literal_node.span) or !std.mem.eql(u8, record.specifier, spelling) or
            !record.is_external or !record.resolved.isNone() or record.resolve_failed or record.mapped_target_missing or record.is_lazy_resolved or
            record.callsite_lowered or record.ts_elided or record.is_optional or
            (!std.mem.eql(u8, record.externalName(), "buffer") and !std.mem.eql(u8, record.externalName(), "node:buffer"))) return false;
    }
    return count == 1;
}

fn capabilityConditionHasBuiltinOrigins(module: *const Module, ast: *const Ast, condition: NodeIndex) bool {
    if (condition.isNone() or @backingInt(condition) >= ast.nodes.items.len) return false;
    const node = ast.getNode(condition);
    return switch (node.tag) {
        .parenthesized_expression => capabilityConditionHasBuiltinOrigins(module, ast, node.data.unary.operand),
        .logical_expression => node.data.binary.flags == @backingInt(Kind.amp2) and
            capabilityConditionHasBuiltinOrigins(module, ast, node.data.binary.left) and capabilityConditionHasBuiltinOrigins(module, ast, node.data.binary.right),
        .static_member_expression => blk: {
            const parts = staticMemberParts(ast, condition) orelse break :blk false;
            const sem = &(module.semantic orelse break :blk false);
            if (parts.object.isNone() or @backingInt(parts.object) >= sem.symbol_ids.len) break :blk false;
            const ctor = sem.symbol_ids[@backingInt(parts.object)] orelse break :blk false;
            const object = exactNodeBufferConstructorObject(module, ast, ctor) orelse break :blk false;
            break :blk nodeBufferObjectImportIsBuiltin(module, ast, object);
        },
        else => false,
    };
}

fn exactBufferValueRead(module: *const Module, node: NodeIndex, id: u32, scope: u32) bool {
    const sem = &(module.semantic orelse return false);
    if (node.isNone() or @backingInt(node) >= sem.symbol_ids.len or sem.symbol_ids[@backingInt(node)] != id or
        scope >= sem.scopes.len) return false;
    var count: usize = 0;
    for (sem.references) |row| {
        if (row.node_index != node) continue;
        if (@backingInt(row.symbol_id) != id or row.scope_id.toIndex() != scope or
            !row.declaration_node_index.isNone() or
            !std.meta.eql(row.flags, @as(@import("../../semantic/symbol.zig").ReferenceFlags, .{ .read = true }))) return false;
        count += 1;
    }
    return count == 1;
}

fn exactNodeBufferConstructorObject(module: *const Module, ast: *const Ast, id: u32) ?u32 {
    const sem = &(module.semantic orelse return null);
    const initializer = exactTopLevelVarInitializer(module, ast, id) orelse return null;
    const parts = staticMemberParts(ast, initializer) orelse return null;
    const property = ast.getNode(parts.property);
    if (property.tag != .identifier_reference or !std.mem.eql(u8, ast.identifierNameText(property), "Buffer")) return null;
    if (@backingInt(parts.object) >= sem.symbol_ids.len or ast.getNode(parts.object).tag != .identifier_reference) return null;
    const object = sem.symbol_ids[@backingInt(parts.object)] orelse return null;
    const scope = sem.scope_owner_map.get(@intCast(ast.nodes.items.len - 1)) orelse return null;
    if (!exactBufferValueRead(module, parts.object, object, scope)) return null;
    return if (exactNodeBufferObjectBinding(module, ast, object)) object else null;
}

fn foldedBufferExportAt(module: *const Module, ast: *const Ast, statement: NodeIndex, kept: NodeIndex) ?FoldedNodeBufferExport {
    const sem = &(module.semantic orelse return null);
    if (statement.isNone() or @backingInt(statement) >= ast.nodes.items.len) return null;
    const branch = ast.getNode(statement);
    if (branch.tag != .if_statement or branch.data.ternary.b != kept) return null;
    const assignment_statement = singleBlockStatement(ast, kept) orelse kept;
    if (assignment_statement.isNone() or @backingInt(assignment_statement) >= ast.nodes.items.len) return null;
    const node = ast.getNode(assignment_statement);
    if (node.tag != .expression_statement) return null;
    const expression = node.data.unary.operand;
    if (expression.isNone() or @backingInt(expression) >= ast.nodes.items.len) return null;
    const assignment = ast.getNode(expression);
    if (assignment.tag != .assignment_expression or !exactBufferWrapperRoot(module, ast, assignment.data.binary.left)) return null;
    const module_object_export = isModuleExportsLhs(ast, assignment.data.binary.left);
    if (!module_object_export) {
        if (!isCjsNamedExportLhs(ast, assignment.data.binary.left)) return null;
        const parts = staticMemberParts(ast, assignment.data.binary.left) orelse return null;
        const property = ast.getNode(parts.property);
        if (property.tag != .identifier_reference or !std.mem.eql(u8, ast.identifierNameText(property), "Buffer")) return null;
    }
    const module_reference = memberRootNode(ast, assignment.data.binary.left) orelse return null;
    if (@backingInt(module_reference) >= sem.symbol_ids.len) return null;
    const module_symbol = sem.symbol_ids[@backingInt(module_reference)] orelse return null;
    if (module_object_export) {
        const expected_module = module.cjs_wrapper_module_parameter_symbol orelse return null;
        if (module_symbol != @backingInt(expected_module)) return null;
    }
    const object = assignment.data.binary.right;
    if (object.isNone() or @backingInt(object) >= ast.nodes.items.len or @backingInt(object) >= sem.symbol_ids.len or
        ast.getNode(object).tag != .identifier_reference) return null;
    const object_symbol = sem.symbol_ids[@backingInt(object)] orelse return null;
    const program_scope = sem.scope_owner_map.get(@intCast(ast.nodes.items.len - 1)) orelse return null;
    if (program_scope >= sem.scopes.len) return null;
    const use_scope = if (ast.getNode(kept).tag == .block_statement) blk: {
        const scope = sem.scope_owner_map.get(@backingInt(kept)) orelse return null;
        if (scope >= sem.scopes.len or sem.scopes[scope].kind != .block or
            sem.scopes[scope].parent.toIndex() != program_scope) return null;
        break :blk scope;
    } else program_scope;
    if (!exactBufferValueRead(module, object, object_symbol, use_scope)) return null;
    const buffer_object = if (module_object_export) blk: {
        if (!exactNodeBufferObjectBinding(module, ast, object_symbol)) return null;
        break :blk object_symbol;
    } else exactNodeBufferConstructorObject(module, ast, object_symbol) orelse return null;
    return .{ .kind = if (module_object_export) .module_object else .buffer_constructor, .ast_owner = ast, .statement = statement, .kept = kept, .assignment = expression, .module_reference = module_reference, .module_symbol = module_symbol, .object_reference = object, .object_symbol = object_symbol, .buffer_object_symbol = buffer_object };
}

pub fn foldedNodeBufferExportIsCurrent(module: *const Module, ast: *const Ast, statement: NodeIndex, fact: FoldedNodeBufferExport) bool {
    if (fact.ast_owner != ast or fact.statement != statement or statement.isNone() or @backingInt(statement) >= ast.nodes.items.len) return false;
    const node = ast.getNode(statement);
    if (node.tag != .if_statement or !node.data.ternary.c.isNone() or node.data.ternary.b != fact.kept) return false;
    const current = foldedBufferExportAt(module, ast, statement, fact.kept) orelse return false;
    return current.kind == fact.kind and current.buffer_object_symbol == fact.buffer_object_symbol and
        current.assignment == fact.assignment and current.module_reference == fact.module_reference and
        current.module_symbol == fact.module_symbol and current.object_reference == fact.object_reference and current.object_symbol == fact.object_symbol;
}

fn memberRootNode(ast: *const Ast, start: NodeIndex) ?NodeIndex {
    var current = start;
    var fuel = ast.nodes.items.len;
    while (fuel > 0) : (fuel -= 1) {
        if (current.isNone() or @backingInt(current) >= ast.nodes.items.len) return null;
        const node = ast.getNode(current);
        if (node.tag == .identifier_reference or node.tag == .assignment_target_identifier) return current;
        if (node.tag != .static_member_expression) return null;
        current = (staticMemberParts(ast, current) orelse return null).object;
    }
    return null;
}

fn exactBufferWrapperRoot(module: *const Module, ast: *const Ast, lhs: NodeIndex) bool {
    const sem = &(module.semantic orelse return false);
    const root = memberRootNode(ast, lhs) orelse return false;
    const raw = @backingInt(root);
    if (raw >= sem.symbol_ids.len) return false;
    const id = sem.symbol_ids[raw] orelse return false;
    if (id >= sem.symbols.items.len) return false;
    const symbol = sem.symbols.items[id];
    if (symbol.kind != .parameter) return false;
    if (module.cjs_wrapper_exports_parameter_symbol) |expected| {
        if (@backingInt(expected) == id and symbol.synthetic_kind == .cjs_wrapper_exports_parameter) return true;
    }
    if (module.cjs_wrapper_module_parameter_symbol) |expected| {
        if (@backingInt(expected) == id and symbol.synthetic_kind == .cjs_wrapper_module_parameter) return true;
    }
    return false;
}

/// The whole call is in the proven-unreachable alternate. No claim about
/// callee purity is needed: only exact erased reference edges are consumed.
/// Functions/closures, member calls, spreads and optional calls stay unproved.
fn exactDeadBufferCallReads(module: *const Module, ast: *const Ast, call: Node, scope: u32) bool {
    if (!ast.hasExtra(call.data.extra, 3) or ast.readExtra(call.data.extra, 3) & ~@as(u32, ast_mod.CallFlags.is_pure) != 0) return false;
    const sem = &(module.semantic orelse return false);
    const start = ast.readExtra(call.data.extra, 1);
    const len = ast.readExtra(call.data.extra, 2);
    if (start > ast.extra_data.items.len or len > ast.extra_data.items.len - start) return false;
    const callee = ast.readExtraNode(call.data.extra, 0);
    if (!exactDeadBufferRead(module, ast, callee, scope, false)) return false;
    for (ast.extra_data.items[start..][0..len]) |raw| {
        if (!exactDeadBufferRead(module, ast, @fromBackingInt(raw), scope, true)) return false;
    }
    _ = sem;
    return true;
}

fn exactDeadBufferRead(module: *const Module, ast: *const Ast, node: NodeIndex, scope: u32, allow_wrapper: bool) bool {
    const sem = &(module.semantic orelse return false);
    if (node.isNone() or @backingInt(node) >= ast.nodes.items.len or @backingInt(node) >= sem.symbol_ids.len or
        ast.getNode(node).tag != .identifier_reference) return false;
    const id = sem.symbol_ids[@backingInt(node)] orelse return false;
    if (id >= sem.symbols.items.len) return false;
    if (allow_wrapper and exactBufferWrapperRoot(module, ast, node)) return true;
    if (!exactBufferValueRead(module, node, id, scope)) return false;
    var current: @import("../../semantic/scope.zig").ScopeId = @fromBackingInt(scope);
    var fuel = sem.scopes.len;
    while (!current.isNone() and current.toIndex() < sem.scopes.len and fuel > 0) : (fuel -= 1) {
        if (current == sem.symbols.items[id].scope_id) return true;
        current = sem.scopes[current.toIndex()].parent;
    }
    return false;
}

fn collectExactFallbackReadIds(
    allocator: std.mem.Allocator,
    module: *const Module,
    ast: *const Ast,
    statement: NodeIndex,
    expected_scope: u32,
    ids: *std.AutoHashMapUnmanaged(u32, void),
    allow_dead_calls: bool,
) !bool {
    if (statement.isNone() or @backingInt(statement) >= ast.nodes.items.len) return false;
    const node = ast.getNode(statement);
    if (node.tag == .block_statement) {
        const list = node.data.list;
        if (list.start > ast.extra_data.items.len or list.len > ast.extra_data.items.len - list.start) return false;
        const sem = &module.semantic.?;
        const block_scope = sem.scope_owner_map.get(@backingInt(statement)) orelse return false;
        if (block_scope >= sem.scopes.len or sem.scopes[block_scope].kind != .block or
            sem.scopes[block_scope].parent != @as(@import("../../semantic/scope.zig").ScopeId, @fromBackingInt(expected_scope))) return false;
        for (ast.extra_data.items[list.start..][0..list.len]) |raw| {
            if (!try collectExactFallbackReadIds(allocator, module, ast, @fromBackingInt(raw), block_scope, ids, allow_dead_calls)) return false;
        }
        return true;
    }
    if (node.tag != .expression_statement) return false;
    const expression = node.data.unary.operand;
    if (expression.isNone() or @backingInt(expression) >= ast.nodes.items.len) return false;
    const assignment = ast.getNode(expression);
    if (allow_dead_calls and assignment.tag == .call_expression)
        return exactDeadBufferCallReads(module, ast, assignment, expected_scope);
    if (assignment.tag != .assignment_expression or !isCjsNamedExportLhs(ast, assignment.data.binary.left) or
        !exactBufferWrapperRoot(module, ast, assignment.data.binary.left)) return false;
    const value = assignment.data.binary.right;
    if (value.isNone() or @backingInt(value) >= ast.nodes.items.len or ast.getNode(value).tag != .identifier_reference) return false;
    const sem = &module.semantic.?;
    if (@backingInt(value) >= sem.symbol_ids.len) return false;
    const id = sem.symbol_ids[@backingInt(value)] orelse return false;
    if (id >= sem.symbols.items.len) return false;
    var reads: usize = 0;
    for (sem.references) |row| {
        if (row.node_index != value) continue;
        if (@backingInt(row.symbol_id) != id or !std.meta.eql(row.flags, @as(@import("../../semantic/symbol.zig").ReferenceFlags, .{ .read = true })) or
            row.scope_id.isNone() or row.scope_id.toIndex() >= sem.scopes.len or row.scope_id.toIndex() != expected_scope) return false;
        var scope = row.scope_id;
        var visible = false;
        var fuel = sem.scopes.len;
        while (!scope.isNone() and scope.toIndex() < sem.scopes.len and fuel > 0) : (fuel -= 1) {
            if (scope == sem.symbols.items[id].scope_id) {
                visible = true;
                break;
            }
            scope = sem.scopes[scope.toIndex()].parent;
        }
        if (!visible) return false;
        reads += 1;
    }
    if (reads != 1) return false;
    try ids.put(allocator, id, {});
    return true;
}

/// The exceptional old path is needed only for a function referenced by the
/// erased fallback export. Prove that actual edge before changing the AST.
/// Its declaration, body, local scopes and all other uses remain untouched.
fn fallbackFunctionGraphIsStable(
    allocator: std.mem.Allocator,
    module: *const Module,
    ast: *const Ast,
    branches: []const BufferCapabilityFoldBranch,
    setup_statements: []const NodeIndex,
    dead_names: *const std.StringHashMapUnmanaged(void),
    allow_dead_calls: bool,
    constructors: *const std.StringHashMapUnmanaged(void),
    removed_nodes: *const std.DynamicBitSet,
) !bool {
    const sem = &(module.semantic orelse return false);
    if (module.wrap_kind != .cjs or sem.scopes.len == 0) return false;
    for (sem.scopes) |scope| if (scope.subtree_has_direct_eval) return false;
    // A with environment may redirect a source read without a static SID.
    for (ast.nodes.items) |node| if (node.tag == .with_statement) return false;
    var selected: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer selected.deinit(allocator);
    const program_scope = sem.scope_owner_map.get(@intCast(ast.nodes.items.len - 1)) orelse return false;
    if (program_scope >= sem.scopes.len or (sem.scopes[program_scope].kind != .global and sem.scopes[program_scope].kind != .module)) return false;
    for (branches) |branch| {
        if (branch.alternate.isNone()) continue;
        if (!try collectExactFallbackReadIds(allocator, module, ast, branch.alternate, program_scope, &selected, allow_dead_calls)) return false;
    }
    if (selected.count() == 0) return false;
    var declarations: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer declarations.deinit(allocator);
    var function_declaration_counts: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer function_declaration_counts.deinit(allocator);
    const root = programNode(ast) orelse return false;
    const list = root.data.list;
    if (list.start > ast.extra_data.items.len or list.len > ast.extra_data.items.len - list.start) return false;
    for (ast.extra_data.items[list.start..][0..list.len]) |raw| {
        const node = ast.nodes.items[raw];
        if (node.tag != .function_declaration) continue;
        const binding = ast.readExtraNode(node.data.extra, ast_mod.FunctionExtra.name);
        if (binding.isNone() or @backingInt(binding) >= sem.symbol_ids.len or ast.getNode(binding).tag != .binding_identifier) return false;
        const id = sem.symbol_ids[@backingInt(binding)] orelse return false;
        // Legacy spelling detection can request a conservative boundary, but
        // only the actual alternate read SID may authorize this declaration.
        if (!selected.contains(id)) {
            if (dead_names.contains(ast.getText(ast.getNode(binding).span))) return false;
            continue;
        }
        if (id >= sem.symbols.items.len) return false;
        const symbol = sem.symbols.items[id];
        if (!functionDeclarationKindMatches(ast, node, symbol.kind) or symbol.synthetic_kind != null or symbol.isExported() or
            symbol.decl_flags.is_annex_b_function or symbol.scope_id.toIndex() != program_scope or symbol.write_count != 0) return false;
        const function_scope = sem.scope_owner_map.get(raw) orelse return false;
        if (function_scope >= sem.scopes.len or sem.scopes[function_scope].kind != .function or
            sem.scopes[function_scope].parent != symbol.scope_id) return false;
        const first_declaration_for_symbol = !declarations.contains(id);
        var anchored: usize = 0;
        var reads: usize = 0;
        for (sem.references) |row| {
            if (@backingInt(row.symbol_id) != id) continue;
            if (row.flags.declare) {
                const declaration_node: NodeIndex = @fromBackingInt(@intCast(raw));
                const belongs_to_this_declaration = row.node_index == binding or
                    row.declaration_node_index == binding or row.declaration_node_index == declaration_node;
                if (!belongs_to_this_declaration) continue;
                if (!std.meta.eql(row.flags, @as(@import("../../semantic/symbol.zig").ReferenceFlags, .{ .declare = true })) or
                    row.scope_id != symbol.scope_id) return false;
                anchored += 1;
            } else if (first_declaration_for_symbol) {
                if (!std.meta.eql(row.flags, @as(@import("../../semantic/symbol.zig").ReferenceFlags, .{ .read = true })) or row.node_index.isNone() or @backingInt(row.node_index) >= sem.symbol_ids.len or
                    sem.symbol_ids[@backingInt(row.node_index)] != id) return false;
                reads += 1;
            }
        }
        if (anchored != 1) return false;
        if (first_declaration_for_symbol) {
            if (reads != symbol.reference_count) return false;
            try declarations.put(allocator, id, {});
        }
        const declaration_count = try function_declaration_counts.getOrPut(allocator, id);
        if (!declaration_count.found_existing) declaration_count.value_ptr.* = 0;
        if (declaration_count.value_ptr.* == std.math.maxInt(u32)) return false;
        declaration_count.value_ptr.* += 1;
    }
    if (declarations.count() != selected.count()) return false;
    var selected_ids = selected.keyIterator();
    while (selected_ids.next()) |selected_id| {
        const expected_declarations = function_declaration_counts.get(selected_id.*) orelse return false;
        var actual_declarations: u32 = 0;
        for (sem.references) |row| {
            if (@backingInt(row.symbol_id) != selected_id.* or !row.flags.declare) continue;
            if (actual_declarations == std.math.maxInt(u32)) return false;
            actual_declarations += 1;
        }
        if (actual_declarations != expected_declarations) return false;
    }
    for (setup_statements) |statement| {
        const node = ast.getNode(statement);
        if (node.tag != .expression_statement) return false;
        const expression = ast.getNode(node.data.unary.operand);
        // Copy-call setup is an explicit boundary until its argument and
        // callee side effects have an equally exact contract.
        if (expression.tag != .assignment_expression) return false;
        const root_node = memberRootNode(ast, expression.data.binary.left) orelse return false;
        if (@backingInt(root_node) >= sem.symbol_ids.len) return false;
        const id = sem.symbol_ids[@backingInt(root_node)] orelse return false;
        if (!declarations.contains(id)) return false;
        if (allow_dead_calls) {
            if (expression.data.binary.flags != @backingInt(Kind.eq) or
                !bufferPrefixIsStable(module, ast, statement, constructors) or
                (!inertBufferPrefixExpression(module, ast, expression.data.binary.right) and
                    !knownBufferPrototypeCreation(module, ast, expression.data.binary.right))) return false;
            const property = staticMemberParts(ast, expression.data.binary.left) orelse return false;
            if (@import("../../lexer/scanner.zig").Scanner.identifierValueEquals(ast.identifierNameText(ast.getNode(property.property)), "__proto__")) return false;
        }
    }
    if (allow_dead_calls) {
        // Every surviving read of fallback storage must be a proven non-escape
        // copy destination. In particular unknown live callees/aliases cannot
        // make elided member writes observable later.
        const reachable_nodes = try ast_walk.collectReachableNodeIndices(allocator, ast);
        defer allocator.free(reachable_nodes);
        const parents = try allocator.alloc(?NodeIndex, ast.nodes.items.len);
        defer allocator.free(parents);
        @memset(parents, null);
        var ambiguous = try std.DynamicBitSet.initEmpty(allocator, ast.nodes.items.len);
        defer ambiguous.deinit();
        for (reachable_nodes) |raw| {
            var children = ast_walk.children(ast, ast.nodes.items[raw]);
            while (children.next()) |child| {
                if (child.isNone()) continue;
                const index = @backingInt(child);
                if (index >= parents.len) return false;
                if (parents[index] != null) ambiguous.set(index);
                parents[index] = @fromBackingInt(raw);
            }
        }
        for (sem.references) |reference| {
            if (reference.flags.declare or !declarations.contains(@backingInt(reference.symbol_id))) continue;
            if (reference.node_index.isNone()) return false;
            const raw = @backingInt(reference.node_index);
            if (raw >= removed_nodes.capacity()) return false;
            if (removed_nodes.isSet(raw)) continue;
            if (ambiguous.isSet(raw)) return false;
            const parent = parents[raw] orelse return false;
            if (!exactNonEscapingBufferCopyCall(module, ast, ast.getNode(parent), reference.scope_id.toIndex(), @backingInt(reference.symbol_id))) return false;
        }
    }
    return true;
}

fn functionDeclarationKindMatches(ast: *const Ast, node: Node, symbol_kind: SymbolKind) bool {
    if (node.tag != .function_declaration or !ast.hasExtra(node.data.extra, ast_mod.FunctionExtra.flags)) return false;
    const flags = ast.readExtra(node.data.extra, ast_mod.FunctionExtra.flags);
    const expected_kind: SymbolKind = if (flags & ast_mod.FunctionFlags.is_async != 0 and flags & ast_mod.FunctionFlags.is_generator != 0)
        .async_generator_decl
    else if (flags & ast_mod.FunctionFlags.is_async != 0)
        .async_function_decl
    else if (flags & ast_mod.FunctionFlags.is_generator != 0)
        .generator_decl
    else
        .function_decl;
    return symbol_kind == expected_kind;
}

test "retained Node Buffer fold keeps the graph when fallback function reads are removed" {
    const cases = [_]struct {
        source: []const u8,
        has_direct_eval: bool,
        expected_reanalysis: bool,
    }{
        .{
            .source =
            \\var buffer = require("buffer"); var B = buffer.Buffer;
            \\if (B.from && B.alloc && B.allocUnsafe && B.allocUnsafeSlow) { module.exports = buffer; }
            \\else { exports.Buffer = SafeBuffer; }
            \\function SafeBuffer() { return 1; }
            ,
            .has_direct_eval = false,
            .expected_reanalysis = false,
        },
        .{
            .source =
            \\var buffer = require("buffer"); var B = buffer.Buffer;
            \\if (B.from && B.alloc && B.allocUnsafe && B.allocUnsafeSlow) { module.exports = buffer; }
            \\else { exports.Buffer = Missing; }
            \\function unrelated() { return 1; }
            \\eval("unrelated");
            ,
            .has_direct_eval = true,
            .expected_reanalysis = false,
        },
    };
    for (cases) |case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        var scanner = try @import("../../lexer/scanner.zig").Scanner.init(allocator, case.source);
        scanner.is_module = false;
        var parser = @import("../../parser/parser.zig").Parser.init(allocator, &scanner);
        parser.configureFromExtension(".cjs");
        parser.is_module = false;
        _ = try parser.parse();

        const root_scope: Scope = .{
            .parent = .none,
            .kind = .global,
            .is_strict = false,
            .subtree_has_direct_eval = case.has_direct_eval,
        };
        const scopes = [_]Scope{root_scope};
        const semantic: ModuleSemanticData = .{
            .symbols = .empty,
            .scopes = &scopes,
            .scope_maps = &.{},
            .exported_names = .empty,
            .symbol_ids = &.{},
            .unresolved_references = .empty,
        };
        var removed_nodes: std.ArrayListUnmanaged(NodeIndex) = .empty;
        var needs_semantic_reanalysis = false;
        try std.testing.expect(try foldNodeBufferCapabilityIfsRetainingGraph(
            allocator,
            &parser.ast,
            &removed_nodes,
            &semantic,
            &needs_semantic_reanalysis,
        ));
        try std.testing.expectEqual(case.expected_reanalysis, needs_semantic_reanalysis);
    }
}

test "retained Node Buffer fold fails closed when semantic scope data is unavailable" {
    const source =
        \\var buffer = require("buffer"); var B = buffer.Buffer;
        \\if (B.from && B.alloc && B.allocUnsafe && B.allocUnsafeSlow) { module.exports = buffer; }
        \\else { exports.Buffer = SafeBuffer; }
        \\var SafeBuffer = function() { return 1; };
        \\function unrelated() { return 2; }
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var scanner = try @import("../../lexer/scanner.zig").Scanner.init(allocator, source);
    scanner.is_module = false;
    var parser = @import("../../parser/parser.zig").Parser.init(allocator, &scanner);
    parser.configureFromExtension(".cjs");
    parser.is_module = false;
    _ = try parser.parse();
    var removed_nodes: std.ArrayListUnmanaged(NodeIndex) = .empty;
    var needs_semantic_reanalysis = false;
    try std.testing.expect(try foldNodeBufferCapabilityIfsRetainingGraph(
        allocator,
        &parser.ast,
        &removed_nodes,
        null,
        &needs_semantic_reanalysis,
    ));
    try std.testing.expect(needs_semantic_reanalysis);

    const empty_semantic: ModuleSemanticData = .{
        .symbols = .empty,
        .scopes = &.{},
        .scope_maps = &.{},
        .exported_names = .empty,
        .symbol_ids = &.{},
        .unresolved_references = .empty,
    };
    var empty_scope_scanner = try @import("../../lexer/scanner.zig").Scanner.init(allocator, source);
    empty_scope_scanner.is_module = false;
    var empty_scope_parser = @import("../../parser/parser.zig").Parser.init(allocator, &empty_scope_scanner);
    empty_scope_parser.configureFromExtension(".cjs");
    empty_scope_parser.is_module = false;
    _ = try empty_scope_parser.parse();
    var empty_scope_removed_nodes: std.ArrayListUnmanaged(NodeIndex) = .empty;
    var empty_scope_needs_semantic_reanalysis = false;
    try std.testing.expect(try foldNodeBufferCapabilityIfsRetainingGraph(
        allocator,
        &empty_scope_parser.ast,
        &empty_scope_removed_nodes,
        &empty_semantic,
        &empty_scope_needs_semantic_reanalysis,
    ));
    try std.testing.expect(empty_scope_needs_semantic_reanalysis);
}

const BufferCapabilityFoldBranch = struct {
    if_index: NodeIndex,
    kept: NodeIndex,
    alternate: NodeIndex,
    /// Preserve the hoisted var declaration while removing its dead branch
    /// initializer. Other shapes remove the full alternate subtree.
    retained_var_initializer: ?NodeIndex = null,
};

/// Keep one direct else-var alternate on the same graph. Clearing its
/// initializer preserves the var binding's hoisted declaration and removes
/// only the exact identifier edge from the dead assignment.
fn exactSimpleVarAlternateInitializer(
    module: *const Module,
    ast: *const Ast,
    if_index: NodeIndex,
    alternate: NodeIndex,
) ?NodeIndex {
    if (module.wrap_kind != .cjs or module.ast == null or &module.ast.? != ast) return null;
    const semantic = &(module.semantic orelse return null);
    if (semantic.scopes.len == 0 or alternate.isNone() or @backingInt(alternate) >= ast.nodes.items.len) return null;
    if (ast.nodes.items.len == 0) return null;
    const root: NodeIndex = ast.transformed_root orelse @fromBackingInt(
        @as(u32, @intCast(ast.nodes.items.len - 1)),
    );
    if (root.isNone() or @backingInt(root) >= ast.nodes.items.len) return null;
    const root_node = ast.getNode(root);
    const root_scope = semantic.scope_owner_map.get(@backingInt(root)) orelse return null;
    if (root_scope >= semantic.scopes.len or
        (semantic.scopes[root_scope].kind != .global and semantic.scopes[root_scope].kind != .module) or
        root_node.tag != .program or root_node.data.list.start > ast.extra_data.items.len or
        root_node.data.list.len > ast.extra_data.items.len - root_node.data.list.start) return null;
    var top_level_if_count: usize = 0;
    for (ast.extra_data.items[root_node.data.list.start..][0..root_node.data.list.len]) |raw| {
        if (raw == @backingInt(if_index)) top_level_if_count += 1;
    }
    if (top_level_if_count != 1) return null;
    const declaration = ast.nodes.items[@backingInt(alternate)];
    if (declaration.tag != .variable_declaration or !ast.hasExtra(declaration.data.extra, 2) or
        ast.readExtra(declaration.data.extra, 0) != @backingInt(ast_mod.VariableDeclarationKind.@"var")) return null;
    const list_start = ast.readExtra(declaration.data.extra, 1);
    const list_len = ast.readExtra(declaration.data.extra, 2);
    if (list_len != 1 or list_start >= ast.extra_data.items.len or list_len > ast.extra_data.items.len - list_start) return null;
    const declarator_raw = ast.extra_data.items[list_start];
    if (declarator_raw >= ast.nodes.items.len) return null;
    const declarator = ast.nodes.items[declarator_raw];
    if (declarator.tag != .variable_declarator or !ast.hasExtra(declarator.data.extra, 2)) return null;
    const binding = ast.readExtraNode(declarator.data.extra, 0);
    const initializer = ast.readExtraNode(declarator.data.extra, 2);
    if (binding.isNone() or @backingInt(binding) >= semantic.symbol_ids.len or
        ast.getNode(binding).tag != .binding_identifier or initializer.isNone() or
        @backingInt(initializer) >= semantic.symbol_ids.len or
        ast.getNode(initializer).tag != .identifier_reference or
        semantic.node_scope_provenance.contains(initializer)) return null;
    const initializer_raw = @backingInt(initializer);
    if (semantic.class_self_symbol_map.contains(initializer_raw) or
        semantic.namespace_member_owners.contains(initializer_raw) or
        semantic.namespace_declaration_owners.contains(initializer_raw) or
        semantic.scope_owner_map.contains(initializer_raw)) return null;

    if (module.transform_cache) |cache| {
        for (cache.helper_ref_nodes) |raw| if (raw == initializer_raw) return null;
        for (cache.explicit_global_ref_nodes) |raw| if (raw == initializer_raw) return null;
        for (cache.opaque_define_scope_owner_nodes) |raw| if (raw == initializer_raw) return null;
        for (cache.preserved_class_name_nodes) |raw| if (raw == initializer_raw) return null;
        for (cache.worklet_factory_local_bindings) |binding_row| {
            if (binding_row.node_index == initializer_raw) return null;
        }
        for (cache.post_graph_output_bindings) |binding_row| {
            if (binding_row.node_index == initializer_raw) return null;
        }
        var temp_bindings = cache.destructuring_temp_bindings.keyIterator();
        while (temp_bindings.next()) |raw| if (raw.* == initializer_raw) return null;
    }
    if (module.tla_iife_stmt) |raw| if (raw == initializer_raw) return null;
    if (module.tla_promise_reference) |promise_ref| {
        if (promise_ref.binding_node_index == initializer_raw) return null;
    }

    const binding_id = semantic.symbol_ids[@backingInt(binding)] orelse return null;
    if (binding_id >= semantic.symbols.items.len) return null;
    const binding_symbol = semantic.symbols.items[binding_id];
    if (binding_symbol.kind != .variable_var or binding_symbol.synthetic_kind != null or
        binding_symbol.scope_id.toIndex() != root_scope) return null;
    var declaration_rows: usize = 0;
    for (semantic.references) |row| {
        if (!row.flags.declare or row.declaration_node_index != binding) continue;
        if (@backingInt(row.symbol_id) != binding_id or
            !std.meta.eql(row.flags, @as(@import("../../semantic/symbol.zig").ReferenceFlags, .{ .declare = true })) or
            row.scope_id != binding_symbol.scope_id) return null;
        declaration_rows += 1;
    }
    if (declaration_rows != 1) return null;

    const initializer_id = semantic.symbol_ids[@backingInt(initializer)] orelse return null;
    if (initializer_id >= semantic.symbols.items.len) return null;
    const initializer_symbol = semantic.symbols.items[initializer_id];
    if (initializer_symbol.scope_id.toIndex() != root_scope or
        initializer_symbol.reference_count == std.math.maxInt(u32)) return null;
    var observed_initializer_edges: u32 = 0;
    for (semantic.references) |row| {
        if (@backingInt(row.symbol_id) != initializer_id or row.flags.declare) continue;
        if (observed_initializer_edges == std.math.maxInt(u32)) return null;
        observed_initializer_edges += 1;
    }
    if (observed_initializer_edges != initializer_symbol.reference_count) return null;
    var initializer_rows: usize = 0;
    for (semantic.references) |row| {
        if (row.node_index != initializer) continue;
        if (@backingInt(row.symbol_id) != initializer_id or
            !std.meta.eql(row.flags, @as(@import("../../semantic/symbol.zig").ReferenceFlags, .{ .read = true })) or
            !row.declaration_node_index.isNone() or @backingInt(row.scope_id) != root_scope) return null;
        initializer_rows += 1;
    }
    if (initializer_rows != 1) return null;
    return initializer;
}

fn appendSingleNode(
    allocator: std.mem.Allocator,
    node_index: NodeIndex,
    seen: *std.DynamicBitSet,
    out: *std.ArrayListUnmanaged(NodeIndex),
    node_count: usize,
) !void {
    if (node_index.isNone()) return error.InvalidRemovedNode;
    const raw = @backingInt(node_index);
    if (raw >= node_count) return error.InvalidRemovedNode;
    if (seen.isSet(raw)) return;
    seen.set(raw);
    try out.append(allocator, node_index);
}

fn appendSubtreeNodes(
    allocator: std.mem.Allocator,
    ast: *const Ast,
    root: NodeIndex,
    seen: *std.DynamicBitSet,
    out: *std.ArrayListUnmanaged(NodeIndex),
) !void {
    if (root.isNone()) return;
    var stack: std.ArrayListUnmanaged(NodeIndex) = .empty;
    defer stack.deinit(allocator);
    try stack.append(allocator, root);
    while (stack.pop()) |idx| {
        if (idx.isNone()) continue;
        const raw = @backingInt(idx);
        if (raw >= ast.nodes.items.len) return error.InvalidRemovedNode;
        if (seen.isSet(raw)) continue;
        seen.set(raw);
        try out.append(allocator, idx);
        var children = ast_walk.children(ast, ast.nodes.items[raw]);
        while (children.next()) |child| try stack.append(allocator, child);
    }
}

const BufferCapabilitySet = struct {
    from: bool = false,
    alloc: bool = false,
    alloc_unsafe: bool = false,
    alloc_unsafe_slow: bool = false,

    fn add(self: *BufferCapabilitySet, name: []const u8) bool {
        if (std.mem.eql(u8, name, "from")) {
            self.from = true;
            return true;
        }
        if (std.mem.eql(u8, name, "alloc")) {
            self.alloc = true;
            return true;
        }
        if (std.mem.eql(u8, name, "allocUnsafe")) {
            self.alloc_unsafe = true;
            return true;
        }
        if (std.mem.eql(u8, name, "allocUnsafeSlow")) {
            self.alloc_unsafe_slow = true;
            return true;
        }
        return false;
    }

    fn hasAll(self: BufferCapabilitySet) bool {
        return self.from and self.alloc and self.alloc_unsafe and self.alloc_unsafe_slow;
    }
};

fn collectNodeBufferCapabilityCondition(
    ast: *const Ast,
    idx: NodeIndex,
    ctor_names: *const std.StringHashMapUnmanaged(void),
    caps: *BufferCapabilitySet,
) bool {
    if (idx.isNone() or @backingInt(idx) >= ast.nodes.items.len) return false;
    const node = ast.nodes.items[@backingInt(idx)];
    switch (node.tag) {
        .parenthesized_expression => return collectNodeBufferCapabilityCondition(ast, node.data.unary.operand, ctor_names, caps),
        .logical_expression => {
            if (@as(Kind, @fromBackingInt(@intCast(node.data.binary.flags))) != .amp2) return false;
            return collectNodeBufferCapabilityCondition(ast, node.data.binary.left, ctor_names, caps) and
                collectNodeBufferCapabilityCondition(ast, node.data.binary.right, ctor_names, caps);
        },
        .static_member_expression => {
            const parts = staticMemberParts(ast, idx) orelse return false;
            const obj = ast.nodes.items[@backingInt(parts.object)];
            if (obj.tag != .identifier_reference) return false;
            if (!ctor_names.contains(ast.getText(obj.span))) return false;
            const prop = ast.nodes.items[@backingInt(parts.property)];
            if (prop.tag != .identifier_reference and prop.tag != .private_identifier) return false;
            return caps.add(ast.getText(prop.span));
        },
        else => return false,
    }
}

fn singleBlockStatement(ast: *const Ast, idx: NodeIndex) ?NodeIndex {
    if (idx.isNone() or @backingInt(idx) >= ast.nodes.items.len) return null;
    const node = ast.nodes.items[@backingInt(idx)];
    if (node.tag != .block_statement) return null;
    const list = node.data.list;
    if (list.len != 1) return null;
    if (list.start >= ast.extra_data.items.len) return null;
    return @fromBackingInt(@intCast(ast.extra_data.items[list.start]));
}

fn collectDeadAlternateCjsExportIdentifiers(
    allocator: std.mem.Allocator,
    ast: *const Ast,
    idx: NodeIndex,
    out: *std.StringHashMapUnmanaged(void),
) std.mem.Allocator.Error!void {
    if (idx.isNone() or @backingInt(idx) >= ast.nodes.items.len) return;
    const node = ast.nodes.items[@backingInt(idx)];
    if (node.tag == .block_statement) {
        const list = node.data.list;
        if (list.start + list.len > ast.extra_data.items.len) return;
        for (ast.extra_data.items[list.start .. list.start + list.len]) |raw| {
            try collectDeadAlternateCjsExportIdentifiers(allocator, ast, @fromBackingInt(@intCast(raw)), out);
        }
        return;
    }
    if (node.tag != .expression_statement) return;
    const expr_idx = node.data.unary.operand;
    if (expr_idx.isNone() or @backingInt(expr_idx) >= ast.nodes.items.len) return;
    const expr = ast.nodes.items[@backingInt(expr_idx)];
    if (expr.tag != .assignment_expression) return;
    if (!isCjsNamedExportLhs(ast, expr.data.binary.left)) return;
    const rhs_idx = expr.data.binary.right;
    if (rhs_idx.isNone() or @backingInt(rhs_idx) >= ast.nodes.items.len) return;
    const rhs = ast.nodes.items[@backingInt(rhs_idx)];
    if (rhs.tag != .identifier_reference) return;
    try out.put(allocator, ast.getText(rhs.span), {});
}

fn removeDeadFallbackSetupStatements(
    ast: *Ast,
    dead_names: *const std.StringHashMapUnmanaged(void),
    buffer_ctor_names: *const std.StringHashMapUnmanaged(void),
) void {
    const root = programNode(ast) orelse return;
    const list = root.data.list;
    if (list.start + list.len > ast.extra_data.items.len) return;
    for (ast.extra_data.items[list.start .. list.start + list.len]) |raw_stmt| {
        const stmt_idx: NodeIndex = @fromBackingInt(@intCast(raw_stmt));
        if (stmt_idx.isNone() or @backingInt(stmt_idx) >= ast.nodes.items.len) continue;
        const stmt = ast.nodes.items[@backingInt(stmt_idx)];
        if (!isDeadFallbackSetupStatement(ast, stmt, dead_names, buffer_ctor_names)) continue;
        ast.nodes.items[@backingInt(stmt_idx)] = .{
            .tag = .empty_statement,
            .span = stmt.span,
            .data = .{ .none = 0 },
        };
    }
}

fn isDeadFallbackSetupStatement(
    ast: *const Ast,
    stmt: Node,
    dead_names: *const std.StringHashMapUnmanaged(void),
    buffer_ctor_names: *const std.StringHashMapUnmanaged(void),
) bool {
    if (stmt.tag != .expression_statement) return false;
    const expr_idx = stmt.data.unary.operand;
    if (expr_idx.isNone() or @backingInt(expr_idx) >= ast.nodes.items.len) return false;
    const expr = ast.nodes.items[@backingInt(expr_idx)];
    if (expr.tag == .assignment_expression) {
        const root = staticMemberRootIdentifier(ast, expr.data.binary.left) orelse return false;
        return dead_names.contains(root);
    }
    if (expr.tag == .call_expression) {
        return isDeadFallbackCopyCall(ast, expr, dead_names, buffer_ctor_names);
    }
    return false;
}

fn isDeadFallbackCopyCall(
    ast: *const Ast,
    call: Node,
    dead_names: *const std.StringHashMapUnmanaged(void),
    buffer_ctor_names: *const std.StringHashMapUnmanaged(void),
) bool {
    const e = call.data.extra;
    if (!ast.hasExtra(e, 2)) return false;
    const args_start = ast.readExtra(e, 1);
    const args_len = ast.readExtra(e, 2);
    if (args_len != 2 or args_start + args_len > ast.extra_data.items.len) return false;
    const first_idx: NodeIndex = @fromBackingInt(@intCast(ast.extra_data.items[args_start]));
    const second_idx: NodeIndex = @fromBackingInt(@intCast(ast.extra_data.items[args_start + 1]));
    if (first_idx.isNone() or second_idx.isNone()) return false;
    if (@backingInt(first_idx) >= ast.nodes.items.len or @backingInt(second_idx) >= ast.nodes.items.len) return false;
    const first = ast.nodes.items[@backingInt(first_idx)];
    const second = ast.nodes.items[@backingInt(second_idx)];
    if (first.tag != .identifier_reference or second.tag != .identifier_reference) return false;
    return buffer_ctor_names.contains(ast.getText(first.span)) and dead_names.contains(ast.getText(second.span));
}

fn staticMemberRootIdentifier(ast: *const Ast, idx: NodeIndex) ?[]const u8 {
    var current = idx;
    while (true) {
        const parts = staticMemberParts(ast, current) orelse return null;
        const obj = ast.nodes.items[@backingInt(parts.object)];
        if (obj.tag == .identifier_reference) return ast.getText(obj.span);
        current = parts.object;
    }
}

pub fn collectNodeBufferModuleObjectNames(
    allocator: std.mem.Allocator,
    ast: *const Ast,
    out: *std.StringHashMapUnmanaged(void),
) std.mem.Allocator.Error!void {
    const root = programNode(ast) orelse return;
    const list = root.data.list;
    if (list.start + list.len > ast.extra_data.items.len) return;
    for (ast.extra_data.items[list.start .. list.start + list.len]) |raw_stmt| {
        const stmt_idx: NodeIndex = @fromBackingInt(@intCast(raw_stmt));
        try collectVarNamesMatchingInit(allocator, ast, stmt_idx, out, isRequireBufferCall);
    }
}

pub fn collectNodeBufferCtorNames(
    allocator: std.mem.Allocator,
    ast: *const Ast,
    buffer_names: *const std.StringHashMapUnmanaged(void),
    out: *std.StringHashMapUnmanaged(void),
) std.mem.Allocator.Error!void {
    const root = programNode(ast) orelse return;
    const list = root.data.list;
    if (list.start + list.len > ast.extra_data.items.len) return;
    for (ast.extra_data.items[list.start .. list.start + list.len]) |raw_stmt| {
        const stmt_idx: NodeIndex = @fromBackingInt(@intCast(raw_stmt));
        if (stmt_idx.isNone() or @backingInt(stmt_idx) >= ast.nodes.items.len) continue;
        const stmt = ast.nodes.items[@backingInt(stmt_idx)];
        if (stmt.tag != .variable_declaration) continue;
        const e = stmt.data.extra;
        if (!ast.hasExtra(e, 2)) continue;
        const start = ast.readExtra(e, 1);
        const len = ast.readExtra(e, 2);
        if (start + len > ast.extra_data.items.len) continue;
        for (ast.extra_data.items[start .. start + len]) |raw_decl| {
            const decl_idx: NodeIndex = @fromBackingInt(@intCast(raw_decl));
            if (decl_idx.isNone() or @backingInt(decl_idx) >= ast.nodes.items.len) continue;
            const decl = ast.nodes.items[@backingInt(decl_idx)];
            if (decl.tag != .variable_declarator) continue;
            const de = decl.data.extra;
            if (!ast.hasExtra(de, 2)) continue;
            const name_idx: NodeIndex = @fromBackingInt(@intCast(ast.readExtra(de, 0)));
            const init_idx: NodeIndex = @fromBackingInt(@intCast(ast.readExtra(de, 2)));
            if (name_idx.isNone() or @backingInt(name_idx) >= ast.nodes.items.len) continue;
            if (!isNodeBufferCtorRead(ast, init_idx, buffer_names)) continue;
            const name = ast.nodes.items[@backingInt(name_idx)];
            if (name.tag == .identifier_reference or name.tag == .binding_identifier or name.tag == .assignment_target_identifier) {
                try out.put(allocator, ast.getText(name.span), {});
            }
        }
    }
}

fn collectVarNamesMatchingInit(
    allocator: std.mem.Allocator,
    ast: *const Ast,
    stmt_idx: NodeIndex,
    out: *std.StringHashMapUnmanaged(void),
    comptime predicate: fn (*const Ast, NodeIndex) bool,
) std.mem.Allocator.Error!void {
    if (stmt_idx.isNone() or @backingInt(stmt_idx) >= ast.nodes.items.len) return;
    const stmt = ast.nodes.items[@backingInt(stmt_idx)];
    if (stmt.tag != .variable_declaration) return;
    const e = stmt.data.extra;
    if (!ast.hasExtra(e, 2)) return;
    const start = ast.readExtra(e, 1);
    const len = ast.readExtra(e, 2);
    if (start + len > ast.extra_data.items.len) return;
    for (ast.extra_data.items[start .. start + len]) |raw_decl| {
        const decl_idx: NodeIndex = @fromBackingInt(@intCast(raw_decl));
        if (decl_idx.isNone() or @backingInt(decl_idx) >= ast.nodes.items.len) continue;
        const decl = ast.nodes.items[@backingInt(decl_idx)];
        if (decl.tag != .variable_declarator) continue;
        const de = decl.data.extra;
        if (!ast.hasExtra(de, 2)) continue;
        const name_idx: NodeIndex = @fromBackingInt(@intCast(ast.readExtra(de, 0)));
        const init_idx: NodeIndex = @fromBackingInt(@intCast(ast.readExtra(de, 2)));
        if (!predicate(ast, init_idx)) continue;
        if (name_idx.isNone() or @backingInt(name_idx) >= ast.nodes.items.len) continue;
        const name = ast.nodes.items[@backingInt(name_idx)];
        if (name.tag == .identifier_reference or name.tag == .binding_identifier or name.tag == .assignment_target_identifier) {
            try out.put(allocator, ast.getText(name.span), {});
        }
    }
}

fn programNode(ast: *const Ast) ?Node {
    if (ast.nodes.items.len == 0) return null;
    const root = ast.nodes.items[ast.nodes.items.len - 1];
    if (root.tag != .program) return null;
    return root;
}

fn isRequireBufferCall(ast: *const Ast, idx: NodeIndex) bool {
    if (idx.isNone() or @backingInt(idx) >= ast.nodes.items.len) return false;
    const node = ast.nodes.items[@backingInt(idx)];
    if (node.tag != .call_expression) return false;
    const e = node.data.extra;
    if (!ast.hasExtra(e, 2)) return false;
    const callee_idx: NodeIndex = @fromBackingInt(@intCast(ast.readExtra(e, 0)));
    if (callee_idx.isNone() or @backingInt(callee_idx) >= ast.nodes.items.len) return false;
    const callee = ast.nodes.items[@backingInt(callee_idx)];
    if (callee.tag != .identifier_reference or !std.mem.eql(u8, ast.getText(callee.span), "require")) return false;
    const args_start = ast.readExtra(e, 1);
    const args_len = ast.readExtra(e, 2);
    if (args_len != 1 or args_start >= ast.extra_data.items.len) return false;
    const arg_idx: NodeIndex = @fromBackingInt(@intCast(ast.extra_data.items[args_start]));
    if (arg_idx.isNone() or @backingInt(arg_idx) >= ast.nodes.items.len) return false;
    const arg = ast.nodes.items[@backingInt(arg_idx)];
    if (arg.tag != .string_literal) return false;
    const spec = ast_mod.Ast.stripStringQuotes(ast.getText(arg.span));
    return std.mem.eql(u8, spec, "buffer") or std.mem.eql(u8, spec, "node:buffer");
}

fn isNodeBufferCtorRead(
    ast: *const Ast,
    idx: NodeIndex,
    buffer_names: *const std.StringHashMapUnmanaged(void),
) bool {
    const parts = staticMemberParts(ast, idx) orelse return false;
    const obj = ast.nodes.items[@backingInt(parts.object)];
    const prop = ast.nodes.items[@backingInt(parts.property)];
    if (obj.tag != .identifier_reference) return false;
    if (prop.tag != .identifier_reference and prop.tag != .private_identifier) return false;
    return buffer_names.contains(ast.getText(obj.span)) and std.mem.eql(u8, ast.getText(prop.span), "Buffer");
}

pub fn isModuleExportsAssignedNodeBufferObject(
    ast: *const Ast,
    stmt_index: NodeIndex,
    buffer_names: *const std.StringHashMapUnmanaged(void),
    buffer_ctor_names: *const std.StringHashMapUnmanaged(void),
) bool {
    if (stmt_index.isNone() or @backingInt(stmt_index) >= ast.nodes.items.len) return false;
    const stmt = ast.nodes.items[@backingInt(stmt_index)];
    if (stmt.tag == .block_statement) {
        const inner = singleBlockStatement(ast, stmt_index) orelse return false;
        return isModuleExportsAssignedNodeBufferObject(ast, inner, buffer_names, buffer_ctor_names);
    }
    if (stmt.tag == .if_statement) {
        const branch = stmt.data.ternary;
        if (!branch.c.isNone()) return false;
        var capabilities: BufferCapabilitySet = .{};
        if (!collectNodeBufferCapabilityCondition(ast, branch.a, buffer_ctor_names, &capabilities) or
            !capabilities.hasAll()) return false;
        return isModuleExportsAssignedNodeBufferObject(ast, branch.b, buffer_names, buffer_ctor_names);
    }
    if (stmt.tag != .expression_statement) return false;
    const expr_idx = stmt.data.unary.operand;
    if (expr_idx.isNone() or @backingInt(expr_idx) >= ast.nodes.items.len) return false;
    const expr = ast.nodes.items[@backingInt(expr_idx)];
    if (expr.tag != .assignment_expression) return false;
    const op: Kind = @fromBackingInt(@intCast(expr.data.binary.flags));
    if (op != .eq) return false;
    if (!isModuleExportsLhs(ast, expr.data.binary.left)) return false;
    const rhs_idx = expr.data.binary.right;
    if (rhs_idx.isNone() or @backingInt(rhs_idx) >= ast.nodes.items.len) return false;
    const rhs = ast.nodes.items[@backingInt(rhs_idx)];
    return rhs.tag == .identifier_reference and buffer_names.contains(ast.getText(rhs.span));
}

test "Node Buffer module.exports detection follows only a folded capability branch" {
    const folded_source =
        \\var buffer = require("buffer"); var B = buffer.Buffer;
        \\if (B.from && B.alloc && B.allocUnsafe && B.allocUnsafeSlow) {
        \\  module.exports = buffer;
        \\} else { exports.Buffer = SafeBuffer; }
        \\function SafeBuffer() { return 1; }
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var scanner = try @import("../../lexer/scanner.zig").Scanner.init(allocator, folded_source);
    scanner.is_module = false;
    var parser = @import("../../parser/parser.zig").Parser.init(allocator, &scanner);
    parser.configureFromExtension(".cjs");
    parser.is_module = false;
    _ = try parser.parse();

    var buffer_names: std.StringHashMapUnmanaged(void) = .empty;
    defer buffer_names.deinit(allocator);
    try collectNodeBufferModuleObjectNames(allocator, &parser.ast, &buffer_names);
    var buffer_ctor_names: std.StringHashMapUnmanaged(void) = .empty;
    defer buffer_ctor_names.deinit(allocator);
    try collectNodeBufferCtorNames(allocator, &parser.ast, &buffer_names, &buffer_ctor_names);

    var if_index: ?NodeIndex = null;
    for (parser.ast.nodes.items, 0..) |node, raw| {
        if (node.tag == .if_statement) {
            if_index = @fromBackingInt(@intCast(raw));
            break;
        }
    }
    const branch_index = if_index orelse return error.MissingCapabilityBranch;
    try std.testing.expect(!isModuleExportsAssignedNodeBufferObject(
        &parser.ast,
        branch_index,
        &buffer_names,
        &buffer_ctor_names,
    ));

    var removed_nodes: std.ArrayListUnmanaged(NodeIndex) = .empty;
    var needs_semantic_reanalysis = false;
    try std.testing.expect(try foldNodeBufferCapabilityIfsRetainingGraph(
        allocator,
        &parser.ast,
        &removed_nodes,
        null,
        &needs_semantic_reanalysis,
    ));
    try std.testing.expect(isModuleExportsAssignedNodeBufferObject(
        &parser.ast,
        branch_index,
        &buffer_names,
        &buffer_ctor_names,
    ));

    const rejected_cases = [_][]const u8{
        \\var buffer = require("buffer"); var B = buffer.Buffer;
        \\if (someRuntimeCondition) { module.exports = buffer; }
        ,
        \\var buffer = require("buffer"); var B = buffer.Buffer;
        \\if (B.from) { module.exports = buffer; }
        ,
        \\var buffer = require("buffer"); var B = buffer.Buffer; var other = {};
        \\if (B.from && B.alloc && B.allocUnsafe && B.allocUnsafeSlow) { module.exports = other; }
        ,
        \\var buffer = require("buffer"); var B = buffer.Buffer;
        \\if (B.from && B.alloc && B.allocUnsafe && B.allocUnsafeSlow) { exports.Buffer = buffer; }
        ,
        \\var buffer = require("buffer"); var B = buffer.Buffer;
        \\if (B.from && B.alloc && B.allocUnsafe && B.allocUnsafeSlow) { module.exports.Buffer = buffer; }
        ,
        \\var buffer = require("buffer"); var B = buffer.Buffer;
        \\if (B.from && B.alloc && B.allocUnsafe && B.allocUnsafeSlow) { module.exports += buffer; }
        ,
        \\var buffer = require("buffer"); var B = buffer.Buffer;
        \\if (B.from && B.alloc && B.allocUnsafe && B.allocUnsafeSlow) {
        \\  if (someRuntimeCondition) { module.exports = buffer; }
        \\}
        ,
        \\var buffer = require("buffer"); var B = buffer.Buffer;
        \\if (B.from && B.alloc && B.allocUnsafe && B.allocUnsafeSlow) {
        \\  globalThis.sideEffect = true;
        \\  module.exports = buffer;
        \\}
        ,
        \\var buffer = require("buffer"); var B = buffer.Buffer;
        \\if (B.from && B.alloc && B.allocUnsafe) { module.exports = buffer; }
        ,
        \\var buffer = require("buffer"); var alias = buffer; var B = alias.Buffer;
        \\if (B.from && B.alloc && B.allocUnsafe && B.allocUnsafeSlow) { module.exports = buffer; }
        ,
    };
    try std.testing.expectEqual(@as(usize, 10), rejected_cases.len);
    for (rejected_cases) |source| {
        var case_scanner = try @import("../../lexer/scanner.zig").Scanner.init(allocator, source);
        case_scanner.is_module = false;
        var case_parser = @import("../../parser/parser.zig").Parser.init(allocator, &case_scanner);
        case_parser.configureFromExtension(".cjs");
        case_parser.is_module = false;
        _ = try case_parser.parse();

        var case_buffer_names: std.StringHashMapUnmanaged(void) = .empty;
        defer case_buffer_names.deinit(allocator);
        try collectNodeBufferModuleObjectNames(allocator, &case_parser.ast, &case_buffer_names);
        var case_ctor_names: std.StringHashMapUnmanaged(void) = .empty;
        defer case_ctor_names.deinit(allocator);
        try collectNodeBufferCtorNames(allocator, &case_parser.ast, &case_buffer_names, &case_ctor_names);

        var case_if_index: ?NodeIndex = null;
        const case_program = programNode(&case_parser.ast) orelse return error.MissingRejectedProgram;
        const case_statements = case_program.data.list;
        if (case_statements.start > case_parser.ast.extra_data.items.len or
            case_statements.len > case_parser.ast.extra_data.items.len - case_statements.start)
            return error.InvalidRejectedProgram;
        for (case_parser.ast.extra_data.items[case_statements.start .. case_statements.start + case_statements.len]) |raw_stmt| {
            const stmt_index: NodeIndex = @fromBackingInt(@intCast(raw_stmt));
            if (stmt_index.isNone() or @backingInt(stmt_index) >= case_parser.ast.nodes.items.len) continue;
            if (case_parser.ast.nodes.items[@backingInt(stmt_index)].tag != .if_statement) continue;
            case_if_index = stmt_index;
            break;
        }
        try std.testing.expect(!isModuleExportsAssignedNodeBufferObject(
            &case_parser.ast,
            case_if_index orelse return error.MissingRejectedBranch,
            &case_buffer_names,
            &case_ctor_names,
        ));
    }

    const direct_export_source =
        \\var buffer = require("buffer");
        \\module.exports = buffer;
        \\function unusedFallback() { return 1; }
    ;
    var direct_scanner = try @import("../../lexer/scanner.zig").Scanner.init(allocator, direct_export_source);
    direct_scanner.is_module = false;
    var direct_parser = @import("../../parser/parser.zig").Parser.init(allocator, &direct_scanner);
    direct_parser.configureFromExtension(".cjs");
    direct_parser.is_module = false;
    _ = try direct_parser.parse();
    var direct_buffer_names: std.StringHashMapUnmanaged(void) = .empty;
    defer direct_buffer_names.deinit(allocator);
    try collectNodeBufferModuleObjectNames(allocator, &direct_parser.ast, &direct_buffer_names);
    var direct_ctor_names: std.StringHashMapUnmanaged(void) = .empty;
    defer direct_ctor_names.deinit(allocator);
    try collectNodeBufferCtorNames(allocator, &direct_parser.ast, &direct_buffer_names, &direct_ctor_names);
    var direct_export_found = false;
    for (direct_parser.ast.nodes.items, 0..) |_, raw| {
        if (isModuleExportsAssignedNodeBufferObject(
            &direct_parser.ast,
            @fromBackingInt(@intCast(raw)),
            &direct_buffer_names,
            &direct_ctor_names,
        )) {
            direct_export_found = true;
            break;
        }
    }
    try std.testing.expect(direct_export_found);
}

fn isModuleExportsLhs(ast: *const Ast, idx: NodeIndex) bool {
    const parts = staticMemberParts(ast, idx) orelse return false;
    const obj = ast.nodes.items[@backingInt(parts.object)];
    const prop = ast.nodes.items[@backingInt(parts.property)];
    return obj.tag == .identifier_reference and
        prop.tag == .identifier_reference and
        std.mem.eql(u8, ast.getText(obj.span), "module") and
        std.mem.eql(u8, ast.getText(prop.span), "exports");
}

fn isCjsNamedExportLhs(ast: *const Ast, idx: NodeIndex) bool {
    const outer = staticMemberParts(ast, idx) orelse return false;
    const prop = ast.nodes.items[@backingInt(outer.property)];
    if (prop.tag != .identifier_reference and prop.tag != .private_identifier) return false;
    const obj = ast.nodes.items[@backingInt(outer.object)];
    if (obj.tag == .identifier_reference and std.mem.eql(u8, ast.getText(obj.span), "exports")) {
        return true;
    }
    if (obj.tag != .static_member_expression) return false;
    const inner = staticMemberParts(ast, outer.object) orelse return false;
    const inner_obj = ast.nodes.items[@backingInt(inner.object)];
    const inner_prop = ast.nodes.items[@backingInt(inner.property)];
    return inner_obj.tag == .identifier_reference and
        inner_prop.tag == .identifier_reference and
        std.mem.eql(u8, ast.getText(inner_obj.span), "module") and
        std.mem.eql(u8, ast.getText(inner_prop.span), "exports");
}

fn moduleExportsRequireSpanAt(ast: *const Ast, idx: NodeIndex) ?Span {
    if (idx.isNone() or @backingInt(idx) >= ast.nodes.items.len) return null;
    const stmt = ast.nodes.items[@backingInt(idx)];
    if (stmt.tag == .block_statement) {
        const inner = singleBlockStatement(ast, idx) orelse return null;
        return moduleExportsRequireSpanAt(ast, inner);
    }
    if (stmt.tag == .if_statement) {
        const t = stmt.data.ternary;
        if (moduleExportsRequireSpanAt(ast, t.b)) |span| return span;
        if (!t.c.isNone()) return moduleExportsRequireSpanAt(ast, t.c);
        return null;
    }
    if (stmt.tag != .expression_statement) return null;
    const expr_idx = stmt.data.unary.operand;
    if (expr_idx.isNone() or @backingInt(expr_idx) >= ast.nodes.items.len) return null;
    const expr = ast.nodes.items[@backingInt(expr_idx)];
    if (expr.tag != .assignment_expression) return null;
    const op: Kind = @fromBackingInt(@intCast(expr.data.binary.flags));
    if (op != .eq) return null;
    if (!isModuleExportsLhs(ast, expr.data.binary.left)) return null;

    const rhs_idx = expr.data.binary.right;
    if (rhs_idx.isNone() or @backingInt(rhs_idx) >= ast.nodes.items.len) return null;
    const rhs = ast.nodes.items[@backingInt(rhs_idx)];
    if (rhs.tag != .call_expression) return null;
    const e = rhs.data.extra;
    if (!ast.hasExtra(e, 2)) return null;

    const callee_idx = ast.readExtraNode(e, 0);
    if (callee_idx.isNone() or @backingInt(callee_idx) >= ast.nodes.items.len) return null;
    const callee = ast.nodes.items[@backingInt(callee_idx)];
    if (callee.tag != .identifier_reference or !std.mem.eql(u8, ast.getText(callee.span), "require")) return null;

    const args_start = ast.readExtra(e, 1);
    const args_len = ast.readExtra(e, 2);
    if (args_len != 1 or args_start >= ast.extra_data.items.len) return null;
    const arg_idx: NodeIndex = @fromBackingInt(@intCast(ast.extra_data.items[args_start]));
    if (arg_idx.isNone() or @backingInt(arg_idx) >= ast.nodes.items.len) return null;
    const arg = ast.nodes.items[@backingInt(arg_idx)];
    if (arg.tag != .string_literal) return null;
    return arg.span;
}

pub fn moduleExportsRequireTargetAt(m: *const Module, ast: *const Ast, idx: NodeIndex) ?ModuleIndex {
    const span = moduleExportsRequireSpanAt(ast, idx) orelse return null;
    for (m.import_records) |rec| {
        if (rec.kind != .require) continue;
        if (rec.resolved.isNone()) continue;
        if (rec.span.start == span.start and rec.span.end == span.end) return rec.resolved;
    }
    return null;
}

pub fn moduleExportsRequireProxyMatches(
    m: *const Module,
    infos: StmtInfos,
    stmt_idx: u32,
    target: ModuleIndex,
) bool {
    if (stmt_idx >= infos.stmts.len) return false;
    const ast = &(m.ast orelse return false);
    const stmt_ni = infos.stmts[stmt_idx].node_idx;
    if (stmt_ni >= ast.nodes.items.len) return false;
    const proxy_target = moduleExportsRequireTargetAt(m, ast, @fromBackingInt(@intCast(stmt_ni))) orelse return false;
    return @backingInt(proxy_target) == @backingInt(target);
}

fn staticMemberParts(ast: *const Ast, idx: NodeIndex) ?struct { object: NodeIndex, property: NodeIndex } {
    if (idx.isNone() or @backingInt(idx) >= ast.nodes.items.len) return null;
    const node = ast.nodes.items[@backingInt(idx)];
    if (node.tag != .static_member_expression) return null;
    const e = node.data.extra;
    if (!ast.hasExtra(e, 1)) return null;
    const obj_idx: NodeIndex = @fromBackingInt(@intCast(ast.readExtra(e, 0)));
    const prop_idx: NodeIndex = @fromBackingInt(@intCast(ast.readExtra(e, 1)));
    if (obj_idx.isNone() or prop_idx.isNone()) return null;
    if (@backingInt(obj_idx) >= ast.nodes.items.len or @backingInt(prop_idx) >= ast.nodes.items.len) return null;
    return .{ .object = obj_idx, .property = prop_idx };
}
