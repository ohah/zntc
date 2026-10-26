//! Applied selective-class authority, distinct from positions-only publication.
//! The source preflight proposes one owner; only the completed factory producer
//! can certify that owner's output. No target capability is changed here.
const std = @import("std");
const ast_mod = @import("../parser/ast.zig");
const NodeIndex = ast_mod.NodeIndex;
const ScopeId = @import("../semantic/scope.zig").ScopeId;
const Plan = @import("deferred_super_class_lowering.zig").Plan;
const ModuleSemanticData = @import("../bundler/module.zig").ModuleSemanticData;
const TransformOptions = @import("transformer.zig").TransformOptions;
const Helpers = @import("runtime_helper_bits.zig").RuntimeHelpers;

pub const Applied = struct {
    source: Plan,
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
};

pub fn record(self: anytype, plan: Plan, factory: NodeIndex, factory_scope: ScopeId, constructor: NodeIndex, constructor_scope: ScopeId, binding: NodeIndex, constructor_binding: NodeIndex, super_binding: NodeIndex) std.mem.Allocator.Error!void {
    const requested = self.selective_class_candidate orelse return;
    if (!samePlan(requested.plan, plan)) return;
    if (!self.semantic_edit_enabled or plan.constructor_scope != constructor_scope or
        self.outputOwnedScope(factory) != factory_scope or self.outputOwnedScope(constructor) != constructor_scope)
        @panic("invalid selective class owner");
    if (@backingInt(binding) >= self.symbol_ids.items.len) @panic("invalid selective class binding");
    const symbol = self.symbol_ids.items[@backingInt(binding)] orelse @panic("invalid selective class binding");
    const constructor_symbol = self.getSymbolIdAt(constructor_binding) orelse @panic("selective constructor binding has no SymbolId");
    const super_symbol = self.getSymbolIdAt(super_binding) orelse @panic("selective heritage parameter has no SymbolId");
    for (self.selective_class_applications.items) |previous| {
        if (previous.source.class_node == plan.class_node) @panic("duplicate selective class application");
    }
    try self.selective_class_applications.append(self.allocator, .{
        .source = plan,
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
pub const Source = struct { plan: Plan, binding: NodeIndex, symbol: u32, constructor_symbol: u32 };

pub fn sourcePlan(allocator: std.mem.Allocator, ast: *const ast_mod.Ast, sem: *const ModuleSemanticData, options: TransformOptions) !?Source {
    if (options.unsupported.class or !options.unsupported.arrow or options.minify_syntax or ast.has_decorator or ast.has_jsx or
        sem.scopes.len == 0 or sem.scopes[0].blocksMangling() or sem.class_self_symbol_map.count() == 0) return null;
    const nodes = try @import("../parser/ast_walk.zig").collectReachableNodeIndices(allocator, ast);
    defer allocator.free(nodes);
    var view: SourceView = .{ .allocator = allocator, .ast = ast, .options = options, .owners = &sem.scope_owner_map };
    var selected: ?Plan = null;
    for (nodes) |raw| {
        const node = ast.nodes.items[raw];
        switch (node.tag) {
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
                if (try @import("deferred_super_class_lowering.zig").selectInScopes(&view, @fromBackingInt(@intCast(raw)), node, sem.scopes)) |plan| {
                    if (selected != null or body.data.list.len != 1) return null;
                    const parameters = ast.getNode(ast.readExtraNode(ast.getNode(plan.constructor_node).data.extra, ast_mod.MethodExtra.params));
                    if (parameters.data.list.len != 0) return null;
                    selected = plan;
                } else if (body.data.list.len != 0) return null;
            },
            else => {},
        }
    }
    const plan = selected orelse return null;
    const binding = ast.readExtraNode(ast.getNode(plan.class_node).data.extra, ast_mod.ClassExtra.name);
    if (binding.isNone() or @backingInt(binding) >= sem.symbol_ids.len) return null;
    return .{ .plan = plan, .binding = binding, .symbol = sem.symbol_ids[@backingInt(binding)] orelse return null, .constructor_symbol = sem.class_self_symbol_map.get(@backingInt(plan.class_node)) orelse return null };
}

fn samePlan(a: Plan, b: Plan) bool {
    return std.meta.eql(a, b);
}

/// Validate exact final import anchors/provider specifiers for already-known
/// helper IDs. Export spelling validates a role; it never selects a binding.
fn helperImports(self: anytype, sem: *const ModuleSemanticData, live: *const std.AutoHashMapUnmanaged(u32, void), factory_live: *const std.AutoHashMapUnmanaged(u32, void)) !bool {
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
        for (sem.references) |reference| {
            if (@backingInt(reference.symbol_id) != sid or reference.node_index.isNone()) continue;
            if (!reference.flags.read or reference.flags.write or !factory_live.contains(@backingInt(reference.node_index))) return false;
            used = true;
        }
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
    if (applied.symbol != expected.symbol or applied.binding != expected.binding or !samePlan(applied.source, expected.plan) or applied.constructor_scope != expected.plan.constructor_scope or
        self.outputOwnedScope(applied.factory) != applied.factory_scope or self.outputOwnedScope(applied.constructor) != applied.constructor_scope or
        @backingInt(applied.binding) >= sem.symbol_ids.len or sem.symbol_ids[@backingInt(applied.binding)] != applied.symbol or applied.symbol >= sem.symbols.items.len) return error.InvalidSelectiveSourceOrBinding;
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
    if (!factory_live.contains(@backingInt(applied.constructor)) or !try helperImports(self, sem, &live, &factory_live)) return error.InvalidSelectiveHelperEdges;
    var demand: Helpers = .{};
    demand.extends = self.runtime_helpers.extends;
    demand.call_super = self.runtime_helpers.call_super;
    demand.derived_constructor = self.runtime_helpers.derived_constructor;
    if (!demand.extends or !demand.call_super or !demand.derived_constructor) return error.InvalidSelectiveHelperDemands;
    return demand;
}
