//! Applied selective-class authority, distinct from positions-only publication.
//! The source preflight proposes one owner; only the completed factory producer
//! can certify that owner's output. No target capability is changed here.
const std = @import("std");
const ast_mod = @import("../parser/ast.zig");
const NodeIndex = ast_mod.NodeIndex;
const ScopeId = @import("../semantic/scope.zig").ScopeId;
const Plan = @import("deferred_super_class_lowering.zig").Plan;
const ModuleSemanticData = @import("../bundler/module.zig").ModuleSemanticData;
const SemanticOwnerToken = @import("../bundler/module.zig").SemanticOwnerToken;
const TransformOptions = @import("transformer.zig").TransformOptions;
const Helpers = @import("runtime_helper_bits.zig").RuntimeHelpers;
const GeneratedSuperCall = @import("transformer.zig").Transformer.GeneratedSuperCall;

pub const Applied = struct {
    source: Plan,
    owner_token: SemanticOwnerToken,
    factory: NodeIndex,
    factory_scope: ScopeId,
    constructor: NodeIndex,
    constructor_scope: ScopeId,
    binding: NodeIndex,
    symbol: u32,
    constructor_binding: NodeIndex,
    constructor_symbol: u32,
    super_binding: NodeIndex,
    super_symbol: u32,
    super_assignment: NodeIndex,
    super_call: GeneratedSuperCall,
};

pub fn record(self: anytype, plan: Plan, factory: NodeIndex, factory_scope: ScopeId, constructor: NodeIndex, constructor_scope: ScopeId, source_constructor: NodeIndex, binding: NodeIndex, constructor_binding: NodeIndex, super_binding: NodeIndex) std.mem.Allocator.Error!void {
    const requested = self.selective_class_candidate orelse return;
    if (!samePlan(requested.plan, plan)) return;
    if (requested.owner_token == .unassigned or self.semantic_source_ast != requested.source_ast)
        @panic("selective class application has no exact source owner");
    if (!self.semantic_edit_enabled or source_constructor != plan.constructor_node or plan.constructor_scope != constructor_scope or
        self.outputOwnedScope(factory) != factory_scope or self.outputOwnedScope(constructor) != constructor_scope)
        @panic("invalid selective class owner");
    if (@backingInt(binding) >= self.symbol_ids.items.len) @panic("invalid selective class binding");
    const symbol = self.symbol_ids.items[@backingInt(binding)] orelse @panic("invalid selective class binding");
    const constructor_symbol = self.getSymbolIdAt(constructor_binding) orelse @panic("selective constructor binding has no SymbolId");
    const super_symbol = self.getSymbolIdAt(super_binding) orelse @panic("selective heritage parameter has no SymbolId");
    const factory_nodes = try @import("../parser/ast_walk.zig").collectReachableNodeIndicesFrom(self.allocator, self.ast, factory);
    defer self.allocator.free(factory_nodes);
    var factory_live: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer factory_live.deinit(self.allocator);
    for (factory_nodes) |raw| try factory_live.put(self.allocator, raw, {});
    var selected: ?struct { assignment: NodeIndex, call: GeneratedSuperCall } = null;
    var calls = self.generated_super_call_assignments.iterator();
    while (calls.next()) |entry| {
        const call = entry.value_ptr.*;
        if (call.source_call != plan.first_super_call or !factory_live.contains(entry.key_ptr.*)) continue;
        if (selected != null or call.native or call.constructor_scope != constructor_scope or
            !scopeWithin(self.semantic_editor.?.scopes.items, call.use_scope, plan.arrow_scope)) return;
        const assignment: NodeIndex = @fromBackingInt(entry.key_ptr.*);
        @import("transformer/declarations.zig").validateLoweredSuperSite(self, assignment, call, .{
            .frame = call.constructor_frame,
            .scope = constructor_scope,
            .target = call.target_symbol,
        }, call.use_scope) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return,
        };
        selected = .{ .assignment = assignment, .call = call };
    }
    const site = selected orelse return;
    for (self.selective_class_applications.items) |previous| {
        if (previous.source.class_node == plan.class_node) @panic("duplicate selective class application");
    }
    try self.selective_class_applications.append(self.allocator, .{
        .source = plan,
        .owner_token = requested.owner_token,
        .factory = factory,
        .factory_scope = factory_scope,
        .constructor = constructor,
        .constructor_scope = constructor_scope,
        .binding = binding,
        .symbol = symbol,
        .constructor_binding = constructor_binding,
        .constructor_symbol = constructor_symbol,
        .super_binding = super_binding,
        .super_symbol = super_symbol,
        .super_assignment = site.assignment,
        .super_call = site.call,
    });
}

const SourceView = struct {
    allocator: std.mem.Allocator,
    ast: *const ast_mod.Ast,
    options: TransformOptions,
    semantic_edit_enabled: bool = true,
    owners: *const std.AutoHashMapUnmanaged(u32, u32),
    pub fn outputOwnedScope(self: *const @This(), node: NodeIndex) ?ScopeId {
        return if (self.owners.get(@backingInt(node))) |scope| @fromBackingInt(@intCast(scope)) else null;
    }
};

/// A deliberately small source family. The existing syntax/plugin/define
/// preflight still applies independently; this does not certify arbitrary AST.
pub const Source = struct {
    plan: Plan,
    binding: NodeIndex,
    symbol: u32,
    constructor_symbol: u32,
    source_ast: *const ast_mod.Ast,
    // Source-only preflight leaves this unassigned. Only actual enrollment
    // captures the current semantic owner; codec never persists that token.
    owner_token: SemanticOwnerToken = .unassigned,
};

pub fn sourcePlan(allocator: std.mem.Allocator, ast: *const ast_mod.Ast, sem: *const ModuleSemanticData, options: TransformOptions) !?Source {
    if (!options.unsupported.arrow or options.minify_syntax or ast.has_decorator or ast.has_jsx or
        sem.scopes.len == 0 or sem.scopes[0].blocksMangling() or sem.class_self_symbol_map.count() == 0) return null;
    const nodes = try @import("../parser/ast_walk.zig").collectReachableNodeIndices(allocator, ast);
    defer allocator.free(nodes);
    var view: SourceView = .{ .allocator = allocator, .ast = ast, .options = options, .owners = &sem.scope_owner_map };
    var selected: ?Plan = null;
    var super_expressions: usize = 0;
    for (nodes) |raw| {
        const node = ast.nodes.items[raw];
        switch (node.tag) {
            .super_expression => super_expressions += 1,
            .arrow_function_expression => {
                const parameters = ast.getNode(ast.readExtraNode(node.data.extra, ast_mod.ArrowExtra.params));
                if (parameters.tag != .formal_parameters or parameters.data.list.len != 0 or
                    ast.readExtra(node.data.extra, ast_mod.ArrowExtra.flags) & ast_mod.ArrowFlags.is_async != 0) return null;
            },
            .property_definition,
            .private_identifier,
            .static_block,
            .class_expression,
            .with_statement,
            .await_expression,
            .yield_expression,
            .import_expression,
            => return null,
            .variable_declaration => if (ast.variableDeclarationKind(node) != .@"var") {
                return null;
            },
            .class_declaration => {
                const body = ast.getNode(ast.readExtraNode(node.data.extra, ast_mod.ClassExtra.body));
                if (body.tag != .class_body) return null;
                // The only lowered member may be the exact constructor. An
                // empty native base class remains on the existing native path.
                if (try @import("deferred_super_class_lowering.zig").inspectConstructor(&view, @fromBackingInt(@intCast(raw)), node, sem.scopes)) |plan| {
                    if (selected != null or body.data.list.len != 1) return null;
                    const parameters = ast.getNode(ast.readExtraNode(ast.getNode(plan.constructor_node).data.extra, ast_mod.MethodExtra.params));
                    if (parameters.data.list.len != 0) return null;
                    selected = plan;
                } else if (options.unsupported.class or body.data.list.len != 0) return null;
            },
            else => {},
        }
    }
    const plan = selected orelse return null;
    if (super_expressions != 1) return null;
    const binding = ast.readExtraNode(ast.getNode(plan.class_node).data.extra, ast_mod.ClassExtra.name);
    if (binding.isNone() or @backingInt(binding) >= sem.symbol_ids.len) return null;
    const symbol = sem.symbol_ids[@backingInt(binding)] orelse return null;
    const constructor_symbol = sem.class_self_symbol_map.get(@backingInt(plan.class_node)) orelse return null;
    if (symbol >= sem.symbols.items.len or constructor_symbol >= sem.symbols.items.len or symbol == constructor_symbol or
        sem.symbols.items[symbol].kind != .class_decl or sem.symbols.items[constructor_symbol].kind != .class_decl or
        sem.symbols.items[constructor_symbol].scope_id != plan.class_scope or
        sem.symbols.items[symbol].scope_id != sem.scopes[plan.class_scope.toIndex()].parent) return null;
    return .{ .plan = plan, .source_ast = ast, .binding = binding, .symbol = symbol, .constructor_symbol = constructor_symbol };
}

fn samePlan(a: Plan, b: Plan) bool {
    return std.meta.eql(a, b);
}

fn scopeWithin(scopes: []const @import("../semantic/scope.zig").Scope, child: ScopeId, parent: ScopeId) bool {
    var current = child;
    var remaining = scopes.len;
    while (!current.isNone() and remaining > 0) : (remaining -= 1) {
        if (current.toIndex() >= scopes.len) return false;
        if (current == parent) return true;
        current = scopes[current.toIndex()].parent;
    }
    return false;
}

/// Validate exact final import anchors/provider specifiers for already-known
/// helper IDs. Export spelling validates a role; it never selects a binding.
fn helperImports(self: anytype, sem: *const ModuleSemanticData, live: *const std.AutoHashMapUnmanaged(u32, void), factory_live: *const std.AutoHashMapUnmanaged(u32, void), factory_scope: ScopeId) !bool {
    var has_extends = false;
    var has_call_super = false;
    var has_derived = false;
    var imports = self.runtime_helper_import_bindings.iterator();
    while (imports.next()) |entry| {
        const sid = entry.key_ptr.*;
        const local = entry.value_ptr.*;
        if (sid >= sem.symbols.items.len or local >= sem.symbol_ids.len or sem.symbol_ids[local] != sid or !live.contains(local)) return false;
        const symbol = sem.symbols.items[sid];
        if (symbol.kind != .import_binding or
            (symbol.synthetic_kind != null and symbol.synthetic_kind != .runtime_helper_import) or
            symbol.scope_id != self.programScope()) return false;
        var role: ?[]const u8 = null;
        var roles = self.runtime_helper_symbol_ids.iterator();
        while (roles.next()) |candidate| {
            if (@backingInt(candidate.value_ptr.*) == sid) {
                if (role != null) return false;
                role = candidate.key_ptr.*;
            }
        }
        const base = role orelse return false;
        const allowed = [_][]const u8{ "__extends", "__callSuper", "__classCallCheck", "__assertThisInitialized", "__assertThisUninitialized", "__possibleConstructorReturn", "__nativeCtorThis", "__name" };
        var permitted = false;
        for (allowed) |name| permitted = permitted or std.mem.eql(u8, base, name);
        if (!permitted) return false;
        const expected = (try @import("../runtime_helper_modules.zig").idForBase(self.allocator, base)) orelse return false;
        defer self.allocator.free(expected);
        var matches: usize = 0;
        var used = false;
        var declarations: usize = 0;
        for (sem.references) |reference| {
            if (@backingInt(reference.symbol_id) != sid) continue;
            if (reference.flags.declare) {
                if (!reference.node_index.isNone() or reference.declaration_node_index != @as(NodeIndex, @fromBackingInt(@intCast(local))) or
                    reference.scope_id != symbol.scope_id or !std.meta.eql(reference.flags, @as(@import("../semantic/symbol.zig").ReferenceFlags, .{ .declare = true }))) return false;
                declarations += 1;
                continue;
            }
            if (reference.node_index.isNone() or !std.meta.eql(reference.flags, @as(@import("../semantic/symbol.zig").ReferenceFlags, .{ .read = true })) or
                !factory_live.contains(@backingInt(reference.node_index)) or !scopeWithin(sem.scopes, reference.scope_id, factory_scope)) return false;
            used = true;
        }
        if (declarations != 1) return false;
        // Grouped derived-constructor imports may include unused siblings.
        // They still need an exact declaration/provider edge below.
        for (self.ast.nodes.items, 0..) |node, raw| {
            if (node.tag != .import_declaration or !live.contains(@intCast(raw))) continue;
            const extra = node.data.extra;
            const start = self.ast.extra_data.items[extra];
            const len = self.ast.extra_data.items[extra + 1];
            for (0..len) |offset| {
                const spec = self.ast.getNode(self.ast.readExtraNode(start, @intCast(offset)));
                if (spec.tag != .import_specifier or @backingInt(spec.data.binary.right) != local) continue;
                if (!std.mem.eql(u8, self.ast.identifierNameText(self.ast.getNode(spec.data.binary.left)), base)) return false;
                const source = self.ast.getNode(self.ast.readExtraNode(extra, 2));
                if (source.tag != .string_literal) return false;
                const text = self.ast.getText(source.data.string_ref);
                if (text.len < 2 or !std.mem.eql(u8, text[1 .. text.len - 1], expected)) return false;
                matches += 1;
            }
        }
        if (matches != 1) return false;
        if (used and std.mem.eql(u8, base, "__extends")) has_extends = true;
        if (used and std.mem.eql(u8, base, "__callSuper")) has_call_super = true;
        if (used and (std.mem.eql(u8, base, "__assertThisInitialized") or
            std.mem.eql(u8, base, "__assertThisUninitialized") or
            std.mem.eql(u8, base, "__possibleConstructorReturn"))) has_derived = true;
    }
    return has_extends and has_call_super and has_derived;
}

/// A demand mask is returned only after the applied owner and each helper's
/// exact import edge passed validation. It is not a global capability boolean.
pub fn validate(self: anytype, sem: *const ModuleSemanticData, expected: Source) !?Helpers {
    if (self.selective_class_applications.items.len != 1) return error.InvalidSelectiveApplicationCount;
    const applied = self.selective_class_applications.items[0];
    if (expected.owner_token == .unassigned or sem.owner_token != expected.owner_token or
        applied.owner_token != expected.owner_token or self.semantic_source_ast != expected.source_ast)
        return error.InvalidSelectiveSemanticOwner;
    const anchors = [_]NodeIndex{ applied.factory, applied.constructor, applied.binding, applied.constructor_binding, applied.super_binding };
    for (anchors) |anchor| {
        if (anchor.isNone() or @backingInt(anchor) >= self.ast.nodes.items.len) return error.InvalidSelectiveAnchor;
    }
    if (applied.factory_scope.isNone() or applied.constructor_scope.isNone() or
        applied.factory_scope.toIndex() >= sem.scopes.len or applied.constructor_scope.toIndex() >= sem.scopes.len or
        sem.scopes[applied.factory_scope.toIndex()].kind != .function or sem.scopes[applied.constructor_scope.toIndex()].kind != .function)
        return error.InvalidSelectiveScope;
    if (applied.symbol != expected.symbol or applied.binding != expected.binding or !samePlan(applied.source, expected.plan) or applied.constructor_scope != expected.plan.constructor_scope or
        self.outputOwnedScope(applied.factory) != applied.factory_scope or self.outputOwnedScope(applied.constructor) != applied.constructor_scope or
        @backingInt(applied.binding) >= sem.symbol_ids.len or sem.symbol_ids[@backingInt(applied.binding)] != applied.symbol or applied.symbol >= sem.symbols.items.len) return error.InvalidSelectiveSourceOrBinding;
    if (expected.plan.class_scope.isNone() or expected.plan.class_scope.toIndex() >= sem.scopes.len or
        expected.plan.arrow_scope.isNone() or expected.plan.arrow_scope.toIndex() >= sem.scopes.len)
        return error.InvalidSelectiveSourceScope;
    const class_environment = sem.scopes[expected.plan.class_scope.toIndex()];
    if (class_environment.kind != .class_body or !class_environment.is_strict or class_environment.parent != applied.factory_scope or
        sem.scopes[applied.constructor_scope.toIndex()].parent != expected.plan.class_scope or
        !sem.scopes[applied.factory_scope.toIndex()].is_strict or !sem.scopes[applied.constructor_scope.toIndex()].is_strict or
        sem.scopes[expected.plan.arrow_scope.toIndex()].kind != .function or
        !scopeWithin(sem.scopes, expected.plan.arrow_scope, applied.constructor_scope) or
        sem.scopes[applied.factory_scope.toIndex()].parent != sem.symbols.items[applied.symbol].scope_id)
        return error.InvalidSelectiveClassEnvironment;
    const factory = self.ast.getNode(applied.factory);
    const constructor = self.ast.getNode(applied.constructor);
    if (factory.tag != .function_expression or constructor.tag != .function_declaration or applied.factory_scope == applied.constructor_scope) return error.InvalidSelectiveFactoryShape;
    if (applied.constructor_symbol != expected.constructor_symbol or applied.constructor_symbol >= sem.symbols.items.len or applied.super_symbol >= sem.symbols.items.len or
        @backingInt(applied.constructor_binding) >= sem.symbol_ids.len or sem.symbol_ids[@backingInt(applied.constructor_binding)] != applied.constructor_symbol or
        @backingInt(applied.super_binding) >= sem.symbol_ids.len or sem.symbol_ids[@backingInt(applied.super_binding)] != applied.super_symbol or
        self.ast.readExtraNode(constructor.data.extra, 0) != applied.constructor_binding or
        sem.symbols.items[applied.constructor_symbol].scope_id != applied.factory_scope or
        sem.symbols.items[applied.super_symbol].kind != .parameter or sem.symbols.items[applied.super_symbol].scope_id != applied.factory_scope)
        return error.InvalidSelectiveFactoryBindings;
    const parameters = self.ast.getNode(self.ast.readExtraNode(factory.data.extra, 1));
    if (parameters.tag != .formal_parameters or parameters.data.list.len != 1 or self.ast.readExtraNode(parameters.data.list.start, 0) != applied.super_binding)
        return error.InvalidSelectiveHeritageParameter;
    const nodes = try @import("../parser/ast_walk.zig").collectReachableNodeIndices(self.allocator, self.ast);
    defer self.allocator.free(nodes);
    var live: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer live.deinit(self.allocator);
    for (nodes) |raw| try live.put(self.allocator, raw, {});
    if (!live.contains(@backingInt(applied.factory)) or !live.contains(@backingInt(applied.constructor)) or !live.contains(@backingInt(applied.binding))) return error.InvalidSelectiveReachability;
    const factory_nodes = try @import("../parser/ast_walk.zig").collectReachableNodeIndicesFrom(self.allocator, self.ast, applied.factory);
    defer self.allocator.free(factory_nodes);
    var factory_live: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer factory_live.deinit(self.allocator);
    for (factory_nodes) |raw| try factory_live.put(self.allocator, raw, {});
    const actual_call = self.generated_super_call_assignments.get(@backingInt(applied.super_assignment)) orelse return error.InvalidSelectiveSuperSource;
    if (!std.meta.eql(actual_call, applied.super_call) or actual_call.source_call != expected.plan.first_super_call or
        actual_call.constructor_scope != applied.constructor_scope or !factory_live.contains(@backingInt(applied.super_assignment)) or
        !scopeWithin(sem.scopes, actual_call.use_scope, expected.plan.arrow_scope)) return error.InvalidSelectiveSuperSource;
    @import("transformer/declarations.zig").validateLoweredSuperSiteInGraph(self.ast, applied.super_assignment, actual_call, .{
        .frame = applied.super_call.constructor_frame,
        .scope = applied.constructor_scope,
        .target = applied.super_call.target_symbol,
    }, applied.super_call.use_scope, .{
        .symbols = sem.symbols.items,
        .scopes = sem.scopes,
        .symbol_ids = sem.symbol_ids,
        .references = sem.references,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidSelectiveSuperSource,
    };
    if (actual_call.callee_symbol != self.runtime_helper_symbol_ids.get("__callSuper")) return error.InvalidSelectiveSuperHelper;
    if (!factory_live.contains(@backingInt(applied.constructor)) or !try helperImports(self, sem, &live, &factory_live, applied.factory_scope)) return error.InvalidSelectiveHelperEdges;
    var demand: Helpers = .{};
    demand.extends = self.runtime_helpers.extends;
    demand.call_super = self.runtime_helpers.call_super;
    demand.derived_constructor = self.runtime_helpers.derived_constructor;
    if (!demand.extends or !demand.call_super or !demand.derived_constructor) return error.InvalidSelectiveHelperDemands;
    return demand;
}
