//! Output declarations owned by a real Module, outside source-analysis tables.
//! No AST node, lexical ScopeId, or source SymbolId is fabricated for a preamble.
const std = @import("std");
const ModuleIndex = @import("types.zig").ModuleIndex;

pub const Owner = enum(u64) { unassigned = 0, _ };
var owner_sequence: std.atomic.Value(u64) = .init(1);

/// The actual Module constructor calls this independently of semantic analysis.
pub fn newOwner() Owner {
    var current = owner_sequence.load(.monotonic);
    while (current != 0 and current != std.math.maxInt(u64)) {
        if (owner_sequence.cmpxchgWeak(current, current + 1, .monotonic, .monotonic)) |actual| {
            current = actual;
        } else return @fromBackingInt(@intCast(current));
    }
    return .unassigned;
}

pub const SymbolId = enum(u32) {
    none = std.math.maxInt(u32),
    _,
    pub fn toIndex(self: SymbolId) usize {
        return @backingInt(self);
    }
};

pub const Ref = struct {
    module: ModuleIndex,
    owner: Owner,
    symbol: SymbolId,
};

pub const Symbol = struct {
    role: enum(u32) { namespace_holder, _ },
    /// Stable preferred spelling. It never selects an identity.
    logical_name: []const u8,
    /// The existing writer emits one `var` in its defining module's chunk.
    abi: enum(u32) { namespace_var_in_owner_chunk_preamble, _ },
};

pub const Domain = struct {
    allocator: std.mem.Allocator,
    owner: Owner,
    symbols: std.ArrayList(Symbol) = .empty,
    namespace_holder: SymbolId = .none,

    pub fn createNamespace(allocator: std.mem.Allocator, owner: Owner, logical_name: []const u8) !*Domain {
        if (owner == .unassigned or logical_name.len == 0) return error.InvalidOutputBinding;
        const domain = try allocator.create(Domain);
        errdefer allocator.destroy(domain);
        domain.* = .{ .allocator = allocator, .owner = owner };
        errdefer domain.symbols.deinit(allocator);
        const name = try allocator.dupe(u8, logical_name);
        errdefer allocator.free(name);
        try domain.symbols.append(allocator, .{ .role = .namespace_holder, .logical_name = name, .abi = .namespace_var_in_owner_chunk_preamble });
        domain.namespace_holder = @fromBackingInt(@intCast(domain.symbols.items.len - 1));
        return domain;
    }

    pub fn destroy(self: *Domain) void {
        const allocator = self.allocator;
        for (self.symbols.items) |symbol| allocator.free(symbol.logical_name);
        self.symbols.deinit(allocator);
        allocator.destroy(self);
    }

    pub fn validNamespace(self: *const Domain) bool {
        if (self.owner == .unassigned or self.symbols.items.len != 1 or self.namespace_holder == .none or
            self.namespace_holder.toIndex() >= self.symbols.items.len) return false;
        const symbol = self.symbols.items[self.namespace_holder.toIndex()];
        return symbol.role == .namespace_holder and symbol.logical_name.len != 0 and symbol.abi == .namespace_var_in_owner_chunk_preamble;
    }

    pub fn namespaceRef(self: *const Domain, module: ModuleIndex) ?Ref {
        if (!self.validNamespace()) return null;
        return .{ .module = module, .owner = self.owner, .symbol = self.namespace_holder };
    }
};

const Module = @import("module.zig").Module;
const Graph = @import("graph.zig").ModuleGraph;

const Registration = struct {
    module: *const Module,
    owner: Owner,
    domain: ?*const Domain,
    /// Constructor-owned immutable table backing; row equality is insufficient.
    source_symbols: []const Symbol = &.{},
    namespace_holder: SymbolId = .none,
    symbol: ?Symbol = null,
    emitted_name: ?[]const u8 = null,

    fn capture(a: std.mem.Allocator, module: *const Module, domain: ?*const Domain) !Registration {
        var result: Registration = .{ .module = module, .owner = module.codegen_output_owner, .domain = domain };
        if (result.owner == .unassigned) return error.InvalidOutputBinding;
        if (domain) |value| {
            if (value.owner != result.owner or !value.validNamespace()) return error.InvalidOutputBinding;
            result.source_symbols = value.symbols.items;
            result.namespace_holder = value.namespace_holder;
            result.symbol = value.symbols.items[value.namespace_holder.toIndex()];
            result.symbol.?.logical_name = try a.dupe(u8, result.symbol.?.logical_name);
        }
        return result;
    }

    fn deinit(self: Registration, a: std.mem.Allocator) void {
        if (self.symbol) |symbol| a.free(symbol.logical_name);
        if (self.emitted_name) |name| a.free(name);
    }

    fn matches(self: Registration) bool {
        if (self.module.codegen_output_owner != self.owner or self.module.codegen_output_domain != self.domain) return false;
        return self.matchesDomain();
    }

    fn matchesDomain(self: Registration) bool {
        const domain = self.domain orelse return self.symbol == null and self.namespace_holder == .none;
        if (domain.symbols.items.ptr != self.source_symbols.ptr or domain.symbols.items.len != self.source_symbols.len or
            !domain.validNamespace() or domain.owner != self.owner or domain.namespace_holder != self.namespace_holder) return false;
        const before = self.symbol orelse return false;
        const actual = domain.symbols.items[self.namespace_holder.toIndex()];
        return before.role == actual.role and before.abi == actual.abi and std.mem.eql(u8, before.logical_name, actual.logical_name);
    }
};

/// Linker-local registration is separate from source semantic registration.
/// All existing modules are captured once; later graph additions are appended.
pub const Registry = struct {
    graph: ?*const Graph = null,
    registered_count: usize = 0,
    rows: std.AutoHashMapUnmanaged(u32, Registration) = .empty,
    owners: std.AutoHashMapUnmanaged(Owner, *const Module) = .empty,

    pub fn deinit(self: *Registry, a: std.mem.Allocator) void {
        var entries = self.rows.valueIterator();
        while (entries.next()) |entry| entry.deinit(a);
        self.rows.deinit(a);
        self.owners.deinit(a);
        self.* = .{};
    }

    pub fn ensure(self: *Registry, a: std.mem.Allocator, graph: *const Graph) !void {
        if (self.graph) |bound| if (bound != graph) return error.InvalidOutputBinding;
        const count = graph.modules.count();
        if (count < self.registered_count) return error.InvalidOutputBinding;
        const additional = count - self.registered_count;
        if (additional == 0) return;
        const entries = try a.alloc(Registration, additional);
        defer a.free(entries);
        var initialized: usize = 0;
        errdefer for (entries[0..initialized]) |entry| entry.deinit(a);
        var seen: std.AutoHashMapUnmanaged(Owner, void) = .empty;
        defer seen.deinit(a);
        for (entries, self.registered_count..) |*entry, raw| {
            const index: ModuleIndex = @fromBackingInt(@intCast(raw));
            const module = graph.getModule(index) orelse return error.InvalidOutputBinding;
            if (module.index != index or self.owners.contains(module.codegen_output_owner) or seen.contains(module.codegen_output_owner)) return error.InvalidOutputBinding;
            try seen.put(a, module.codegen_output_owner, {});
            entry.* = try Registration.capture(a, module, module.codegen_output_domain);
            initialized += 1;
        }
        try self.rows.ensureUnusedCapacity(a, @intCast(additional));
        try self.owners.ensureUnusedCapacity(a, @intCast(additional));
        // Ownership and membership were checked before publishing any row.
        for (entries) |entry| {
            self.rows.putAssumeCapacity(entry.module.index.toU32(), entry);
            self.owners.putAssumeCapacity(entry.owner, entry.module);
        }
        self.graph = graph;
        self.registered_count = count;
    }

    pub fn validates(self: *const Registry, reference: Ref) bool {
        const graph = self.graph orelse return false;
        const row = self.rows.get(reference.module.toU32()) orelse return false;
        return graph.getModule(reference.module) == row.module and self.owners.get(reference.owner) == row.module and
            reference.owner == row.owner and reference.symbol != .none and reference.symbol == row.namespace_holder and row.matches();
    }

    pub fn symbolFor(self: *const Registry, reference: Ref) ?Symbol {
        if (!self.validates(reference)) return null;
        return (self.rows.get(reference.module.toU32()) orelse return null).symbol;
    }

    pub fn emittedName(self: *const Registry, reference: Ref) ?[]const u8 {
        if (!self.validates(reference)) return null;
        return (self.rows.get(reference.module.toU32()) orelse return null).emitted_name;
    }

    pub fn prepareNamespace(self: *Registry, a: std.mem.Allocator, graph: *const Graph, module: *const Module, candidate: *const Domain, emitted_name: []const u8) !Prepared {
        try self.ensure(a, graph);
        const before = self.rows.get(module.index.toU32()) orelse return error.InvalidOutputBinding;
        if (graph.getModule(module.index) != module or before.module != module or !before.matches() or before.emitted_name != null or
            self.owners.get(module.codegen_output_owner) != module or candidate.owner != module.codegen_output_owner) return error.InvalidOutputBinding;
        var after: Registration = undefined;
        if (before.domain) |existing| {
            if (existing != candidate) return error.InvalidOutputBinding;
            after = before;
        } else after = try Registration.capture(a, module, candidate);
        after.emitted_name = emitted_name;
        return .{ .registry = self, .before = before, .after = after, .owns_symbol_copy = before.domain == null };
    }
};

pub const Prepared = struct {
    registry: *Registry,
    before: Registration,
    after: Registration,
    published: bool = false,
    owns_symbol_copy: bool,

    pub fn deinit(self: *Prepared, a: std.mem.Allocator) void {
        if (!self.published and self.owns_symbol_copy) if (self.after.symbol) |symbol| a.free(symbol.logical_name);
    }

    pub fn isCurrent(self: Prepared) bool {
        const graph = self.registry.graph orelse return false;
        const current = self.registry.rows.get(self.before.module.index.toU32()) orelse return false;
        return graph.getModule(self.before.module.index) == self.before.module and current.module == self.before.module and
            current.owner == self.before.owner and current.domain == self.before.domain and current.emitted_name == null and current.matches() and
            self.after.module == self.before.module and self.after.owner == self.before.owner and self.after.matchesDomain();
    }

    /// The actual module has just installed the staged domain; no allocation.
    pub fn publish(self: *Prepared) void {
        self.registry.rows.putAssumeCapacity(self.after.module.index.toU32(), self.after);
        self.published = true;
    }
};
