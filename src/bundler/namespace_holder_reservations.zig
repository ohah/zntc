//! Emission-owned namespace holder allocation. Keys never borrow canonical names.
const std = @import("std");
const SpinLock = @import("../util/spin_lock.zig").SpinLock;

pub const NamespaceHolderReservations = struct {
    const NameRole = enum { input, derived };

    allocator: std.mem.Allocator,
    names: std.StringHashMapUnmanaged(NameRole) = .empty,
    mutex: SpinLock = .{},

    pub fn init(allocator: std.mem.Allocator) NamespaceHolderReservations {
        return .{ .allocator = allocator };
    }

    /// Caller joins all module-emission workers before destroying this owner.
    pub fn deinit(self: *NamespaceHolderReservations) void {
        var keys = self.names.keyIterator();
        while (keys.next()) |key| self.allocator.free(key.*);
        self.names.deinit(self.allocator);
    }

    pub fn reserve(self: *NamespaceHolderReservations, name: []const u8) !void {
        try self.reserveAs(name, .input);
    }

    pub fn reserveDerived(self: *NamespaceHolderReservations, name: []const u8) !void {
        try self.reserveAs(name, .derived);
    }

    fn reserveAs(self: *NamespaceHolderReservations, name: []const u8, role: NameRole) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.names.getPtr(name)) |existing| {
            if (role == .input) existing.* = .input;
            return;
        }
        const owned = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned);
        try self.names.put(self.allocator, owned, role);
    }

    /// Snapshot actual selected names, including unified nested Phase B output.
    /// Source names reserve allocation only; no identity is recovered by text.
    pub fn seed(self: *NamespaceHolderReservations, linker: anytype) !void {
        var selected = linker.rename_table.map.valueIterator();
        while (selected.next()) |name| try self.reserve(name.*);
        if (linker.unified_result) |*result| {
            var nested = result.renames.valueIterator();
            while (nested.next()) |name| try self.reserve(name.*);
        }
        var imports = linker.consumer_import_local.valueIterator();
        while (imports.next()) |targets| {
            var values = targets.valueIterator();
            while (values.next()) |target| {
                if (target.role == .binding) try self.reserve(target.text);
            }
        }
        {
            const mutable = @constCast(linker);
            mutable.ns_cache_mutex.lock();
            defer mutable.ns_cache_mutex.unlock();
            var shared = linker.ns_shared_var_names.keyIterator();
            while (shared.next()) |name| try self.reserveDerived(name.*);
        }
        var globals = linker.reserved_globals.keyIterator();
        while (globals.next()) |name| try self.reserve(name.*);
        var eval_arena = std.heap.ArenaAllocator.init(self.allocator);
        defer eval_arena.deinit();
        var modules = linker.graph.modulesIterator();
        while (modules.next()) |module| {
            if (module.semantic) |sem| {
                for (sem.scope_maps) |scope| {
                    var names = scope.keyIterator();
                    while (names.next()) |name| try self.reserve(name.*);
                }
                var unresolved = sem.unresolved_references.keyIterator();
                while (unresolved.next()) |name| try self.reserve(name.*);
                if (module.ast) |*ast| {
                    const EvalSource = struct {
                        allocator: std.mem.Allocator,
                        ast: *const @import("../parser/ast.zig").Ast,
                        scopes: []const @import("../semantic/scope.zig").Scope,
                        semantic_editor: ?@import("../semantic/editor.zig").SemanticEditor = null,
                    };
                    var source: EvalSource = .{ .allocator = eval_arena.allocator(), .ast = ast, .scopes = sem.scopes };
                    var eval_names: std.StringHashMapUnmanaged(void) = .empty;
                    defer eval_names.deinit(self.allocator);
                    try @import("../transformer/es_helpers.zig").collectDynamicEvalReservedNames(&source, &eval_names, self.allocator);
                    var names = eval_names.keyIterator();
                    while (names.next()) |name| try self.reserve(name.*);
                }
            }
            for ([_]?[]const u8{ module.getInitName(null), module.getExportsName(null), module.getRequireName(null) }) |name| {
                if (name) |value| try self.reserve(value);
            }
        }
    }

    pub fn contains(self: *NamespaceHolderReservations, name: []const u8) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.names.contains(name);
    }

    /// Cache invalidation only. Capture before workers allocate any holder.
    /// Commutative key folding makes hash-map insertion order irrelevant.
    pub fn initialFingerprint(self: *NamespaceHolderReservations) u64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        var digest: u64 = 0;
        var input_count: u64 = 0;
        var entries = self.names.iterator();
        while (entries.next()) |entry| {
            if (entry.value_ptr.* != .input) continue;
            input_count += 1;
            digest ^= std.hash.Wyhash.hash(0x4e53484f4c444552, entry.key_ptr.*);
        }
        return std.hash.Wyhash.hash(input_count, std.mem.asBytes(&digest));
    }

    /// Atomically reserves a fresh holder, returning a separate caller-owned name.
    /// A same-target cache hit must reuse its prior allocation instead of calling this.
    pub fn allocate(self: *NamespaceHolderReservations, caller_allocator: std.mem.Allocator, importer: []const u8, target: []const u8) ![]const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        const owner = try ownerBase(caller_allocator, importer, target);
        defer caller_allocator.free(owner);
        var suffix: u32 = 1;
        while (true) : (suffix += 1) {
            const candidate = if (suffix == 1)
                try caller_allocator.dupe(u8, owner)
            else
                try std.fmt.allocPrint(caller_allocator, "{s}_{d}", .{ owner, suffix });
            errdefer caller_allocator.free(candidate);
            if (self.names.contains(candidate)) {
                caller_allocator.free(candidate);
                continue;
            }
            const reserved = try self.allocator.dupe(u8, candidate);
            errdefer self.allocator.free(reserved);
            try self.names.put(self.allocator, reserved, .derived);
            return candidate;
        }
    }
};

/// Exact canonical graph paths, not module-index numerals or lossy basename IDs.
/// Distinct owner paths occupy disjoint identifier namespaces without hash collisions.
pub fn ownerBase(a: std.mem.Allocator, importer: []const u8, target: []const u8) ![]u8 {
    const text = try a.alloc(u8, "_zntc_ns_m".len + importer.len * 2 + "_t".len + target.len * 2);
    var at: usize = 0;
    const hex = "0123456789abcdef";
    for ("_zntc_ns_m") |c| {
        text[at] = c;
        at += 1;
    }
    for (importer) |c| {
        text[at] = hex[c >> 4];
        text[at + 1] = hex[c & 15];
        at += 2;
    }
    for ("_t") |c| {
        text[at] = c;
        at += 1;
    }
    for (target) |c| {
        text[at] = hex[c >> 4];
        text[at + 1] = hex[c & 15];
        at += 2;
    }
    return text;
}

/// Shared collision fallback occupies a family disjoint from every pretty
/// `{base}_ns[_rank]` name and from every other exact target path.
pub fn sharedOwnerBase(a: std.mem.Allocator, target: []const u8) ![]u8 {
    const prefix = "_zntc_shared_p";
    const text = try a.alloc(u8, prefix.len + target.len * 2);
    @memcpy(text[0..prefix.len], prefix);
    const hex = "0123456789abcdef";
    for (target, 0..) |c, i| {
        text[prefix.len + i * 2] = hex[c >> 4];
        text[prefix.len + i * 2 + 1] = hex[c & 15];
    }
    return text;
}

test "namespace holder hygiene reservation owns source and selected names independently" {
    const a = std.testing.allocator;
    var reservations = NamespaceHolderReservations.init(a);
    defer reservations.deinit();
    const source = try a.dupe(u8, "_zntc_ns_m6d_t74");
    try reservations.reserve(source);
    @memset(source, 0xaa);
    a.free(source);
    try reservations.reserve("_zntc_ns_m6d_t74_2"); // independently selected nested output binding
    const first = try reservations.allocate(a, "m", "t");
    defer a.free(first);
    try std.testing.expectEqualStrings("_zntc_ns_m6d_t74_3", first);
    const second = try reservations.allocate(a, "m", "t");
    defer a.free(second);
    try std.testing.expectEqualStrings("_zntc_ns_m6d_t74_4", second);
    try std.testing.expect(first.ptr != second.ptr);
}

test "namespace holder hygiene reservation separates allocators and deterministic owners" {
    const caller = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(caller);
    defer arena.deinit();
    var first = NamespaceHolderReservations.init(arena.allocator());
    defer first.deinit();
    var reverse = NamespaceHolderReservations.init(arena.allocator());
    defer reverse.deinit();
    try first.reserve("_zntc_ns_m6d_t74");
    try reverse.reserve("_zntc_ns_m6d_t74");
    const a = try first.allocate(caller, "m", "t");
    defer caller.free(a);
    const b = try first.allocate(caller, "n", "t");
    defer caller.free(b);
    const rb = try reverse.allocate(caller, "n", "t");
    defer caller.free(rb);
    const ra = try reverse.allocate(caller, "m", "t");
    defer caller.free(ra);
    try std.testing.expectEqualStrings(a, ra);
    try std.testing.expectEqualStrings(b, rb);
    try std.testing.expectEqualStrings("_zntc_ns_m6d_t74_2", a);
    try std.testing.expectEqualStrings("_zntc_ns_m6e_t74", b);
    try std.testing.expect(a.ptr != ra.ptr);
}

test "namespace holder hygiene reservation allocation failure retains owned keys" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(a: std.mem.Allocator) !void {
            var reservations = NamespaceHolderReservations.init(a);
            defer reservations.deinit();
            try reservations.reserve("_zntc_ns_m6d_t74");
            const name = try reservations.allocate(a, "m", "t");
            defer a.free(name);
            try std.testing.expectEqualStrings("_zntc_ns_m6d_t74_2", name);
        }
    }.run, .{});
}

test "namespace holder hygiene reservation fingerprint freezes cache authority before allocation" {
    const a = std.testing.allocator;
    var left = NamespaceHolderReservations.init(a);
    defer left.deinit();
    var right = NamespaceHolderReservations.init(a);
    defer right.deinit();
    try left.reserve("source");
    try left.reserve("selected");
    try right.reserve("selected");
    try right.reserve("source");
    const immutable = left.initialFingerprint();
    try std.testing.expectEqual(immutable, right.initialFingerprint());
    const generated = try left.allocate(a, "/source/a.mjs", "/source/dep.mjs");
    defer a.free(generated);
    try std.testing.expectEqual(immutable, left.initialFingerprint());
    try right.reserve("new_source_binding");
    try std.testing.expect(immutable != right.initialFingerprint());
}

test "namespace holder hygiene exact path owner families stay disjoint" {
    const a = std.testing.allocator;
    const baseline = try ownerBase(a, "/a/entry.mjs", "/x/dep.mjs");
    defer a.free(baseline);
    const owners = [_][2][]const u8{
        .{ "/b/entry.mjs", "/x/dep.mjs" },
        .{ "/a/entry.mjs", "/y/dep.mjs" },
        .{ "/a/entry.mjs", "/x/dep.js" },
        .{ "/a/entry.mjs", "/x/dep.mts" },
        .{ "/π/entry.mjs", "/😀/dep.mjs" },
    };
    for (owners) |owner| {
        const other = try ownerBase(a, owner[0], owner[1]);
        defer a.free(other);
        try std.testing.expect(!std.mem.eql(u8, baseline, other));
    }
    const first = try sharedOwnerBase(a, "/a/dep.mjs");
    defer a.free(first);
    const second = try sharedOwnerBase(a, "/b/dep.mjs");
    defer a.free(second);
    try std.testing.expect(!std.mem.eql(u8, first, second));
    try std.testing.expect(std.mem.indexOf(u8, first, "_ns") == null);
    try std.testing.expect(std.mem.indexOf(u8, first, "_t") == null);
}

test "namespace holder hygiene input provenance dominates a same-spelled derived name" {
    const a = std.testing.allocator;
    var derived_first = NamespaceHolderReservations.init(a);
    defer derived_first.deinit();
    var input_first = NamespaceHolderReservations.init(a);
    defer input_first.deinit();
    const empty = derived_first.initialFingerprint();
    try derived_first.reserveDerived("dep_ns");
    try std.testing.expectEqual(empty, derived_first.initialFingerprint());
    try derived_first.reserve("dep_ns");
    const promoted = derived_first.initialFingerprint();
    try std.testing.expect(promoted != empty);
    try input_first.reserve("dep_ns");
    try input_first.reserveDerived("dep_ns");
    try std.testing.expectEqual(promoted, input_first.initialFingerprint());
    try std.testing.expectEqual(@as(usize, 1), derived_first.names.count());
    try std.testing.expectEqual(@as(usize, 1), input_first.names.count());
}
