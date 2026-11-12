//! Complete dependency-first emit fingerprints. DFS state never escapes this
//! producer: cyclic modules share a digest of their entire SCC and its already
//! completed outgoing dependencies. ModuleGraph.cycle_group is not an SCC map.
const std = @import("std");
const Linker = @import("../linker.zig").Linker;
const Graph = @import("../graph.zig").ModuleGraph;
const ModuleIndex = @import("../types.zig").ModuleIndex;
const ImportKind = @import("../types.zig").ImportKind;

const Edge = struct { target: u32, kind: ImportKind };
const Frame = struct { node: u32, next: usize };

pub fn compute(linker: *const Linker, allocator: std.mem.Allocator) ![]u64 {
    const graph = linker.graph;
    const count = graph.moduleCount();
    const result = try allocator.alloc(u64, count);
    errdefer allocator.free(result);
    if (count == 0) return result;
    try @import("shared_namespace.zig").prepareFingerprintInputs(@constCast(linker));

    const local = try allocator.alloc(u64, count);
    defer allocator.free(local);
    const offsets = try allocator.alloc(usize, count + 1);
    defer allocator.free(offsets);
    var edges: std.ArrayList(Edge) = .empty;
    defer edges.deinit(allocator);
    // Preserve the old fold's record/context target order and multiplicity.
    for (0..count) |index| {
        offsets[index] = edges.items.len;
        const module = graph.getModule(ModuleIndex.fromUsize(index)) orelse {
            local[index] = 0;
            continue;
        };
        local[index] = linker.emitFingerprint(module);
        for (module.import_records) |record| {
            if (record.is_external) continue;
            if (record.kind == .require_context) {
                for (record.context_resolved_paths) |path| {
                    const target = graph.path_to_module.get(path orelse continue) orelse continue;
                    try appendEdge(allocator, &edges, count, target, record.kind);
                }
            } else if (!record.resolved.isNone()) {
                try appendEdge(allocator, &edges, count, record.resolved, record.kind);
            }
        }
    }
    offsets[count] = edges.items.len;

    const unseen = std.math.maxInt(usize);
    const discovery = try allocator.alloc(usize, count);
    defer allocator.free(discovery);
    @memset(discovery, unseen);
    const low = try allocator.alloc(usize, count);
    defer allocator.free(low);
    const on_stack = try allocator.alloc(bool, count);
    defer allocator.free(on_stack);
    @memset(on_stack, false);
    const component = try allocator.alloc(usize, count);
    defer allocator.free(component);
    const sizes = try allocator.alloc(usize, count);
    defer allocator.free(sizes);
    @memset(sizes, 0);
    var stack: std.ArrayList(u32) = .empty;
    defer stack.deinit(allocator);
    var frames: std.ArrayList(Frame) = .empty;
    defer frames.deinit(allocator);
    try stack.ensureTotalCapacity(allocator, count);
    try frames.ensureTotalCapacity(allocator, count);
    var next_discovery: usize = 0;
    var component_count: usize = 0;
    // Iterative Tarjan: dependencies finish before consumers, with no native
    // recursion or depth-dependent truncation even on a long linear graph.
    for (0..count) |root| {
        if (discovery[root] != unseen) continue;
        discovery[root] = next_discovery;
        low[root] = next_discovery;
        next_discovery += 1;
        on_stack[root] = true;
        stack.appendAssumeCapacity(@intCast(root));
        frames.appendAssumeCapacity(.{ .node = @intCast(root), .next = offsets[root] });
        while (frames.items.len != 0) {
            const frame_index = frames.items.len - 1;
            const node = frames.items[frame_index].node;
            const next = frames.items[frame_index].next;
            if (next < offsets[node + 1]) {
                frames.items[frame_index].next += 1;
                const target = edges.items[next].target;
                if (discovery[target] == unseen) {
                    discovery[target] = next_discovery;
                    low[target] = next_discovery;
                    next_discovery += 1;
                    on_stack[target] = true;
                    stack.appendAssumeCapacity(target);
                    frames.appendAssumeCapacity(.{ .node = target, .next = offsets[target] });
                } else if (on_stack[target]) {
                    low[node] = @min(low[node], discovery[target]);
                }
                continue;
            }
            if (low[node] == discovery[node]) {
                while (true) {
                    const member = stack.pop().?;
                    on_stack[member] = false;
                    component[member] = component_count;
                    sizes[component_count] += 1;
                    if (member == node) break;
                }
                component_count += 1;
            }
            _ = frames.pop();
            if (frames.items.len != 0) {
                const parent = frames.items[frames.items.len - 1].node;
                low[parent] = @min(low[parent], low[node]);
            }
        }
    }

    const member_offsets = try allocator.alloc(usize, component_count + 1);
    defer allocator.free(member_offsets);
    member_offsets[0] = 0;
    for (0..component_count) |index| member_offsets[index + 1] = member_offsets[index] + sizes[index];
    const cursor = try allocator.dupe(usize, member_offsets[0..component_count]);
    defer allocator.free(cursor);
    const members = try allocator.alloc(u32, count);
    defer allocator.free(members);
    for (0..count) |index| {
        const group = component[index];
        members[cursor[group]] = @intCast(index);
        cursor[group] += 1;
    }

    for (0..component_count) |group| {
        const group_members = members[member_offsets[group]..member_offsets[group + 1]];
        const single = group_members[0];
        var cyclic = group_members.len != 1;
        if (!cyclic) for (edges.items[offsets[single]..offsets[single + 1]]) |edge| {
            if (edge.target == single) cyclic = true;
        };
        if (!cyclic) {
            // Exact compatibility for every acyclic node, including repeated
            // dependencies and require.context expansion order.
            var value = local[single];
            for (edges.items[offsets[single]..offsets[single + 1]]) |edge| {
                if (component[edge.target] >= group) return error.InvalidEmitFingerprintCondensation;
                value = value *% 31 +% result[edge.target];
            }
            result[single] = value;
            continue;
        }
        // Module paths are graph-owned identities. Sort only cyclic members,
        // retaining linear work on acyclic graphs and stable SCC digests when
        // entry traversal/ModuleIndex assignment changes.
        std.mem.sort(u32, group_members, graph, pathLessThan);
        var hash = std.hash.Wyhash.init(0x454d495453434331);
        addNumber(&hash, group_members.len);
        for (group_members) |member| {
            addPath(&hash, modulePath(graph, member));
            addNumber(&hash, local[member]);
            addNumber(&hash, offsets[member + 1] - offsets[member]);
            for (edges.items[offsets[member]..offsets[member + 1]]) |edge| {
                addNumber(&hash, @backingInt(edge.kind));
                addPath(&hash, modulePath(graph, edge.target));
                if (component[edge.target] == group) {
                    addNumber(&hash, 0);
                } else {
                    if (component[edge.target] >= group) return error.InvalidEmitFingerprintCondensation;
                    addNumber(&hash, 1);
                    addNumber(&hash, result[edge.target]);
                }
            }
        }
        const digest = hash.final();
        // No member is published until the full component digest is complete.
        for (group_members) |member| result[member] = digest;
    }
    return result;
}

fn appendEdge(allocator: std.mem.Allocator, edges: *std.ArrayList(Edge), count: usize, target: ModuleIndex, kind: ImportKind) !void {
    if (target.toU32() >= count) return error.InvalidEmitFingerprintTarget;
    try edges.append(allocator, .{ .target = target.toU32(), .kind = kind });
}

fn modulePath(graph: *const Graph, index: u32) []const u8 {
    return if (graph.getModule(ModuleIndex.fromUsize(index))) |module| module.path else "";
}

fn pathLessThan(graph: *Graph, left: u32, right: u32) bool {
    return std.mem.lessThan(u8, modulePath(graph, left), modulePath(graph, right));
}

fn addNumber(hash: *std.hash.Wyhash, number: u64) void {
    hash.update(std.mem.asBytes(&number));
}

fn addPath(hash: *std.hash.Wyhash, path: []const u8) void {
    addNumber(hash, path.len);
    hash.update(path);
}
