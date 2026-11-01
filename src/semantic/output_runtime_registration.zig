//! Installed graph domains for output-runtime birth witnesses. Registration is
//! one graph handoff; transactional edits prepare their next domain before
//! publication. Queries never scan the other modules or reconstruct ownership.
const std = @import("std");
const mod = @import("../bundler/module.zig");
const Ast = @import("../parser/ast.zig").Ast;
const Graph = @import("../bundler/graph.zig").ModuleGraph;
const Owner = mod.SemanticOwnerToken;
const Module = mod.Module;

pub const Backing = struct {
    kind: enum { nodes, extras, strings, symbols, ids, scopes, scope_maps, references },
    address: usize,
    len: usize,
};
const Key = struct { kind: @TypeOf(@as(Backing, undefined).kind), address: usize };

pub const Domain = struct {
    module: *const Module,
    owner: Owner,
    ast: ?*const Ast,
    semantic: ?*const mod.ModuleSemanticData,
    backings: [8]Backing,

    fn read(module: *const Module, installed: *const Module) Domain {
        const ast = if (module.ast) |*value| value else null;
        const sem = if (module.semantic) |*value| value else null;
        return .{ .module = installed, .owner = if (sem) |value| value.owner_token else .unassigned, .ast = if (installed.ast) |*value| value else null, .semantic = if (installed.semantic) |*value| value else null, .backings = .{
            backing(.nodes, if (ast) |value| @intFromPtr(value.nodes.items.ptr) else 0, if (ast) |value| value.nodes.items.len else 0),
            backing(.extras, if (ast) |value| @intFromPtr(value.extra_data.items.ptr) else 0, if (ast) |value| value.extra_data.items.len else 0),
            backing(.strings, if (ast) |value| @intFromPtr(value.string_table.items.ptr) else 0, if (ast) |value| value.string_table.items.len else 0),
            backing(.symbols, if (sem) |value| @intFromPtr(value.symbols.items.ptr) else 0, if (sem) |value| value.symbols.items.len else 0),
            backing(.ids, if (sem) |value| @intFromPtr(value.symbol_ids.ptr) else 0, if (sem) |value| value.symbol_ids.len else 0),
            backing(.scopes, if (sem) |value| @intFromPtr(value.scopes.ptr) else 0, if (sem) |value| value.scopes.len else 0),
            backing(.scope_maps, if (sem) |value| @intFromPtr(value.scope_maps.ptr) else 0, if (sem) |value| value.scope_maps.len else 0),
            backing(.references, if (sem) |value| @intFromPtr(value.references.ptr) else 0, if (sem) |value| value.references.len else 0),
        } };
    }

    pub fn matches(self: Domain, module: *const Module) bool {
        return self.module == module and std.meta.eql(self, read(module, module));
    }
};

fn backing(kind: @TypeOf(@as(Backing, undefined).kind), address: usize, len: usize) Backing {
    return .{ .kind = kind, .address = if (len == 0) 0 else address, .len = len };
}

pub const Registry = struct {
    domains: std.ArrayList(Domain) = .empty,
    owners: std.AutoHashMapUnmanaged(Owner, *const Module) = .empty,
    backings: std.AutoHashMapUnmanaged(Key, *const Module) = .empty,
    epoch: u64 = 0,

    pub fn deinit(self: *Registry, a: std.mem.Allocator) void {
        self.domains.deinit(a);
        self.owners.deinit(a);
        self.backings.deinit(a);
        self.* = .{};
    }

    pub fn clear(self: *Registry) void {
        self.domains.clearRetainingCapacity();
        self.owners.clearRetainingCapacity();
        self.backings.clearRetainingCapacity();
        self.epoch +%= 1;
    }

    pub fn lookup(self: *const Registry, module: *const Module) ?Domain {
        const index = module.index.toUsize();
        if (self.epoch == 0 or index >= self.domains.items.len) return null;
        const domain = self.domains.items[index];
        if (domain.owner == .unassigned or self.owners.get(domain.owner) != module or !domain.matches(module)) return null;
        return domain;
    }
};

/// Called by the actual graph/linked-graph handoff before value transactions.
/// All allocation and duplicate checks precede assigning any new owner token.
pub fn refresh(graph: *Graph) !void {
    if (!graph.wrapper_symbols_registered) return error.UnregisteredRuntimeGraph;
    const a = graph.allocator;
    var next: Registry = .{ .epoch = graph.output_runtime_registry.epoch +% 1 };
    if (next.epoch == 0) next.epoch = 1;
    errdefer next.deinit(a);
    const count = graph.moduleCount();
    try next.domains.ensureTotalCapacity(a, count);
    try next.owners.ensureUnusedCapacity(a, @intCast(count));
    const backing_count = std.math.mul(usize, count, 8) catch return error.OutOfMemory;
    try next.backings.ensureUnusedCapacity(a, @intCast(backing_count));
    var modules = graph.modulesIterator();
    while (modules.next()) |module| {
        const domain = Domain.read(module, module);
        if (module.index.toUsize() != next.domains.items.len) return error.InvalidRuntimeModuleDomain;
        next.domains.appendAssumeCapacity(domain);
        if (domain.owner != .unassigned) {
            if (next.owners.contains(domain.owner)) return error.DuplicateRuntimeOwner;
            next.owners.putAssumeCapacity(domain.owner, module);
        }
        for (domain.backings) |item| {
            if (item.len == 0) continue;
            const key: Key = .{ .kind = item.kind, .address = item.address };
            if (next.backings.get(key)) |owner| {
                if (owner != module) return error.ForeignRuntimeBacking;
            } else next.backings.putAssumeCapacity(key, module);
        }
    }
    // No fallible work remains. Only this actual registration producer may
    // assign an unassigned module's owner; source capture remains readonly.
    for (next.domains.items) |*domain| {
        if (domain.owner != .unassigned or domain.module.semantic == null) continue;
        const semantic = &@constCast(domain.module).semantic.?;
        while (true) {
            const owner = semantic.captureOwnerToken();
            if (owner == .unassigned) break;
            if (!next.owners.contains(owner)) {
                domain.owner = owner;
                next.owners.putAssumeCapacity(owner, domain.module);
                break;
            }
            semantic.owner_token = .unassigned;
        }
    }
    graph.output_runtime_registry.deinit(a);
    graph.output_runtime_registry = next;
}

pub fn canUseCandidateBackings(graph: *const Graph, source: *const Module, candidate: *const Module) bool {
    if (source.index != candidate.index) return false;
    const before = graph.output_runtime_registry.lookup(source) orelse return false;
    const after = Domain.read(candidate, source);
    if (after.owner != before.owner) return false;
    for (after.backings) |item| {
        if (item.len == 0) continue;
        if (graph.output_runtime_registry.backings.get(.{ .kind = item.kind, .address = item.address })) |owner| {
            if (owner != source) return false;
        }
    }
    return true;
}

pub const Prepared = struct {
    graph: *Graph,
    before: Domain,
    after: Domain,
    epoch: u64,

    pub fn isCurrent(self: *const Prepared) bool {
        if (self.graph.output_runtime_registry.epoch != self.epoch) return false;
        const current = self.graph.output_runtime_registry.lookup(self.before.module) orelse return false;
        return std.meta.eql(current, self.before);
    }

    /// Caller has checked isCurrent before replacing the actual Module. The
    /// recorded domain uses its installed header, never the staging address.
    pub fn publishAssumePrepared(self: Prepared) void {
        const registry = &self.graph.output_runtime_registry;
        registry.domains.items[self.before.module.index.toUsize()] = self.after;
        for (self.after.backings) |item| {
            if (item.len == 0) continue;
            registry.backings.putAssumeCapacity(.{ .kind = item.kind, .address = item.address }, self.before.module);
        }
    }
};

/// The source domain must already be registered. A candidate does not create
/// authority. Previously registered foreign backings are rejected in O(1).
/// Reservation may grow capacity, but no map entry or source domain is changed.
pub fn preparePublication(a: std.mem.Allocator, graph: *Graph, source: *const Module, candidate: *const Module) !?Prepared {
    _ = a; // All registry storage has the graph allocator/lifetime.
    if (graph.getModule(source.index) != source or source.index != candidate.index) return null;
    const before = graph.output_runtime_registry.lookup(source) orelse return null;
    const after = Domain.read(candidate, source);
    if (after.owner != before.owner) return null;
    for (after.backings) |item| {
        if (item.len == 0) continue;
        if (graph.output_runtime_registry.backings.get(.{ .kind = item.kind, .address = item.address })) |owner| {
            if (owner != source) return null;
        }
    }
    try graph.output_runtime_registry.backings.ensureUnusedCapacity(graph.allocator, 8);
    return .{ .graph = graph, .before = before, .after = after, .epoch = graph.output_runtime_registry.epoch };
}
