//! The ESM split/PM ABI has no waiter for a lowered module initializer.
//! Diagnose only a live, owned initializer with remaining suspension work.
//! Native ESM TLA, single-output ESM and non-ESM readiness keep their contracts.
const std = @import("std");
const ast_mod = @import("../parser/ast.zig");
const ast_walk = @import("../parser/ast_walk.zig");
const Module = @import("module.zig").Module;
const ModuleGraph = @import("graph.zig").ModuleGraph;
const TreeShaker = @import("tree_shaker.zig").TreeShaker;
const EmitOptions = @import("emitter.zig").EmitOptions;
const ScopeId = @import("../semantic/scope.zig").ScopeId;
const NodeIndex = ast_mod.NodeIndex;

pub fn diagnose(graph: *ModuleGraph, options: *const EmitOptions, shaker: ?*const TreeShaker) !bool {
    if (options.format != .esm or !options.unsupported.top_level_await or
        !(options.code_splitting or options.preserve_modules)) return false;
    var blocked = false;
    var modules = graph.modulesIterator();
    while (modules.next()) |module| {
        if (shaker) |s| if (!s.isIncluded(module.index.toU32())) continue;
        if (module.is_external or module.is_disabled or !module.module_type.isJavaScriptLike()) continue;
        const span = try activeInitializer(graph.allocator, module, shaker, false) orelse continue;
        try graph.addOwnedDiagnostic(.{
            .code = .top_level_await_target,
            .severity = .@"error",
            .file_path = module.path,
            .span = span,
            .step = .transform,
            .message = "The configured ESM split output cannot await this lowered top-level module initializer",
            .suggestion = "Use a target with native top-level await, a single ESM output, or a supported non-ESM readiness output.",
        });
        blocked = true;
    }
    return blocked;
}

/// The exact lowering-owned initializer may retain native resource syntax even
/// though its implicit Await is no longer at module scope in the current AST.
pub fn activeNativeResourceInitializer(a: std.mem.Allocator, module: *const Module, shaker: ?*const TreeShaker) !?@import("../lexer/token.zig").Span {
    return activeInitializer(a, module, shaker, true);
}

fn activeInitializer(a: std.mem.Allocator, module: *const Module, shaker: ?*const TreeShaker, native_resources_only: bool) !?@import("../lexer/token.zig").Span {
    const raw = module.tla_iife_stmt orelse return null;
    const promise = module.tla_promise_reference orelse return error.MissingTlaPromiseIdentity;
    const tree = &(module.ast orelse return error.MissingTlaPromiseIdentity);
    const semantic = &(module.semantic orelse return error.MissingTlaPromiseIdentity);
    if (raw >= tree.nodes.items.len or promise.binding_node_index >= tree.nodes.items.len or
        tree.getNode(@fromBackingInt(promise.binding_node_index)).tag != .binding_identifier or
        !module.matchesTlaPromiseReference(promise.binding_node_index)) return error.MissingTlaPromiseIdentity;
    const root = tree.transformed_root orelse return error.MissingTlaPromiseIdentity;
    const program = tree.getNode(root);
    if (program.tag != .program) return error.MissingTlaPromiseIdentity;
    var selected = false;
    var items = tree.iterateExtraList(program.data.list);
    while (items.next()) |node| {
        if (@backingInt(node) != raw) continue;
        if (selected) return error.MissingTlaPromiseIdentity;
        if (shaker) |s| {
            if (s.graph.getModule(module.index) != module) return error.MissingTlaPromiseIdentity;
            // Linker-owned imports can change the physical program list after
            // shaking. Only the retained statement's exact node and declared
            // promise SID select an ordinal in the reachability domain.
            if (s.getModuleStmtInfos(module.index.toU32())) |infos| {
                var ordinal: ?u32 = null;
                for (infos.stmts, 0..) |statement, index| {
                    if (statement.node_idx != raw) continue;
                    if (ordinal != null or std.mem.indexOfScalar(u32, statement.declared_symbols, @backingInt(promise.symbol_id)) == null)
                        return error.MissingTlaPromiseIdentity;
                    ordinal = @intCast(index);
                }
                const actual = ordinal orelse return error.MissingTlaPromiseIdentity;
                const module_raw = module.index.toU32();
                if (module_raw >= s.reachable_stmts.len) return error.MissingTlaPromiseIdentity;
                if (s.reachable_stmts[module_raw]) |bits| {
                    if (bits.unmanaged.bit_length != infos.stmts.len or actual >= bits.unmanaged.bit_length)
                        return error.MissingTlaPromiseIdentity;
                }
                if (!s.isStmtReachable(module_raw, actual)) return null;
            }
        }
        selected = true;
    }
    // A removed label/statement must not become an unsupported-target error
    // merely because an old lowering index remains in metadata.
    if (!selected) return null;
    const statement = tree.getNode(@fromBackingInt(raw));
    if (statement.tag != .variable_declaration or !tree.hasExtra(statement.data.extra, 2)) return error.MissingTlaPromiseIdentity;
    const start = tree.extra_data.items[statement.data.extra + 1];
    const len = tree.extra_data.items[statement.data.extra + 2];
    if (len != 1 or start >= tree.extra_data.items.len) return error.MissingTlaPromiseIdentity;
    const declarator: NodeIndex = @fromBackingInt(tree.extra_data.items[start]);
    if (declarator.isNone() or @backingInt(declarator) >= tree.nodes.items.len) return error.MissingTlaPromiseIdentity;
    const decl = tree.getNode(declarator);
    if (decl.tag != .variable_declarator or !tree.hasExtra(decl.data.extra, 2) or
        @backingInt(tree.readExtraNode(decl.data.extra, 0)) != promise.binding_node_index) return error.MissingTlaPromiseIdentity;
    // variable_declarator = [binding, type_annotation, initializer].
    const init = tree.readExtraNode(decl.data.extra, 2);
    if (init.isNone()) return error.MissingTlaPromiseIdentity;
    var resource_span: ?@import("../lexer/token.zig").Span = null;
    if (!try hasSuspension(a, tree, semantic, init, native_resources_only, &resource_span)) return null;
    if (native_resources_only) {
        const span = resource_span orelse return error.MissingTlaPromiseIdentity;
        if (span.end > module.source.len) return error.MissingTlaPromiseIdentity;
        return span;
    }
    return statement.span;
}

fn hasSuspension(a: std.mem.Allocator, tree: *const ast_mod.Ast, semantic: *const @import("module.zig").ModuleSemanticData, init: NodeIndex, native_resources_only: bool, resource_span: *?@import("../lexer/token.zig").Span) !bool {
    const Work = struct { node: NodeIndex, state: ?u32 = null, native_generator: bool = false, state_switch: bool = false };
    var stack: std.ArrayList(Work) = .empty;
    defer stack.deinit(a);
    var visited: std.AutoHashMapUnmanaged(NodeIndex, void) = .empty;
    defer visited.deinit(a);
    try stack.append(a, .{ .node = init });
    while (stack.pop()) |work| {
        if (work.node.isNone()) continue;
        const raw = @backingInt(work.node);
        if (raw >= tree.nodes.items.len) return error.MissingTlaPromiseIdentity;
        const slot = try visited.getOrPut(a, work.node);
        if (slot.found_existing) continue;
        const node = tree.getNode(work.node);
        var state = work.state;
        var native_generator = work.native_generator;
        var state_switch = work.state_switch;
        switch (node.tag) {
            // A declaration only creates a function; it does not evaluate its body.
            .function_declaration => continue,
            .function_expression, .arrow_function_expression => {
                const scope_raw = semantic.scope_owner_map.get(raw) orelse return error.MissingTlaPromiseIdentity;
                // Source nested async/generator functions do not suspend module
                // evaluation. Copied source owners keep their original ScopeId.
                if (scope_raw < semantic.scope_history.source_scopes.len) continue;
                if (scope_raw >= semantic.scopes.len or semantic.scopes[scope_raw].kind != .function) return error.MissingTlaPromiseIdentity;
                const flags_slot: u32 = if (node.tag == .arrow_function_expression) ast_mod.ArrowExtra.flags else ast_mod.FunctionExtra.flags;
                if (!tree.hasExtra(node.data.extra, flags_slot)) return error.MissingTlaPromiseIdentity;
                native_generator = tree.extra_data.items[node.data.extra + flags_slot] & ast_mod.FunctionFlags.is_generator != 0;
                state = generatedStateParameter(tree, semantic, node, @fromBackingInt(scope_raw));
                state_switch = false;
            },
            .await_expression, .for_await_of_statement => if (!native_resources_only) return true,
            .variable_declaration => if (tree.hasExtra(node.data.extra, 2) and
                tree.variableDeclarationKind(node) == .await_using)
            {
                if (node.span.start & ast_mod.Ast.STRING_TABLE_BIT != 0 or node.span.end < node.span.start) return error.MissingTlaPromiseIdentity;
                resource_span.* = node.span;
                return true;
            },
            .yield_expression => if (!native_resources_only and native_generator) return true,
            .switch_statement => if (state) |sid| {
                if (stateSwitch(tree, semantic, node, sid)) state_switch = true;
            },
            .return_statement => if (!native_resources_only and state_switch and suspensionReturn(tree, node)) return true,
            else => {},
        }
        var children = ast_walk.children(tree, node);
        while (children.next()) |child| try stack.append(a, .{ .node = child, .state = state, .native_generator = native_generator, .state_switch = state_switch });
    }
    return false;
}

// Late synthetic-name permission is optional. The producer's actual parameter
// leaf/SID/owner and its state-switch use remain authoritative without that marker.
fn generatedStateParameter(tree: *const ast_mod.Ast, semantic: *const @import("module.zig").ModuleSemanticData, function: ast_mod.Node, scope: ScopeId) ?u32 {
    const params = tree.functionParamsList(function);
    if (params.len != 1 or params.start >= tree.extra_data.items.len) return null;
    var leaf: NodeIndex = @fromBackingInt(tree.extra_data.items[params.start]);
    if (leaf.isNone() or @backingInt(leaf) >= tree.nodes.items.len) return null;
    if (tree.getNode(leaf).tag == .formal_parameter) {
        const parameter = tree.getNode(leaf);
        if (!tree.hasExtra(parameter.data.extra, 0)) return null;
        leaf = tree.readExtraNode(parameter.data.extra, 0);
    }
    if (leaf.isNone() or @backingInt(leaf) >= tree.nodes.items.len or
        @backingInt(leaf) >= semantic.symbol_ids.len or tree.getNode(leaf).tag != .binding_identifier) return null;
    const sid = semantic.symbol_ids[@backingInt(leaf)] orelse return null;
    if (sid >= semantic.symbols.items.len or semantic.symbols.items[sid].scope_id != scope or semantic.symbols.items[sid].kind != .parameter) return null;
    // SemanticEditor.declare keeps value node_index=.none for declaration
    // rows; the physical binding is declaration_node_index (Reference's exact
    // anchor contract), not a read/write row on the parameter leaf.
    var declarations: usize = 0;
    for (semantic.references) |reference| if (reference.declaration_node_index == leaf and reference.node_index.isNone() and
        @backingInt(reference.symbol_id) == sid and reference.scope_id == scope and
        reference.flags.declare and !reference.flags.read and !reference.flags.write)
    {
        declarations += 1;
    };
    return if (declarations == 1) sid else null;
}

fn stateSwitch(tree: *const ast_mod.Ast, semantic: *const @import("module.zig").ModuleSemanticData, node: ast_mod.Node, sid: u32) bool {
    if (!tree.hasExtra(node.data.extra, 0)) return false;
    const discriminant = tree.readExtraNode(node.data.extra, 0);
    if (discriminant.isNone() or @backingInt(discriminant) >= tree.nodes.items.len) return false;
    const member = tree.getNode(discriminant);
    // static_member_expression.extra = [object, property, flags].
    if (member.tag != .static_member_expression or !tree.hasExtra(member.data.extra, 2)) return false;
    const object = tree.readExtraNode(member.data.extra, 0);
    const property = tree.readExtraNode(member.data.extra, 1);
    if (object.isNone() or property.isNone() or @backingInt(object) >= semantic.symbol_ids.len or @backingInt(property) >= tree.nodes.items.len or
        semantic.symbol_ids[@backingInt(object)] != sid) return false;
    const key = tree.getNode(property);
    // This is the state-machine protocol's property key, never a lexical SID
    // lookup or a generated variable spelling used to repair missing identity.
    return key.tag == .identifier_reference and std.mem.eql(u8, tree.getText(key.data.string_ref), "label");
}

fn suspensionReturn(tree: *const ast_mod.Ast, node: ast_mod.Node) bool {
    const value = node.data.unary.operand;
    if (value.isNone() or @backingInt(value) >= tree.nodes.items.len) return false;
    const array = tree.getNode(value);
    if (array.tag != .array_expression or array.data.list.len < 2 or array.data.list.start >= tree.extra_data.items.len) return false;
    const opcode: NodeIndex = @fromBackingInt(tree.extra_data.items[array.data.list.start]);
    if (opcode.isNone() or @backingInt(opcode) >= tree.nodes.items.len) return false;
    const literal = tree.getNode(opcode);
    if (literal.tag != .numeric_literal) return false;
    const text = tree.getText(literal.span);
    return std.mem.eql(u8, text, "4") or std.mem.eql(u8, text, "5");
}
