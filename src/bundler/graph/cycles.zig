//! Cycle detection and execution-order DFS helpers for ModuleGraph.

const std = @import("std");
const ModuleIndex = @import("../types.zig").ModuleIndex;
const Span = @import("../../lexer/token.zig").Span;

/// Phase 2: 반복 DFS 후위 순서 순회. exec_index 부여 + 순환 감지 (D065, D076).
/// 재귀 대신 명시적 스택 사용 — 깊은 모듈 체인에서도 스택 오버플로 없음.
pub fn dfs(self: anytype, start_idx: ModuleIndex, visited: *std.DynamicBitSet, in_stack: *std.DynamicBitSet) !void {
    const DfsEntry = struct {
        idx: u32,
        post: bool, // true = 후처리 (exec_index 부여), false = 전처리 (의존성 push)
    };

    var stack: std.ArrayList(DfsEntry) = .empty;
    defer stack.deinit(self.allocator);

    const start = @intFromEnum(start_idx);
    if (start >= self.modules.count()) return;
    if (visited.isSet(start)) return;

    try stack.append(self.allocator, .{ .idx = start, .post = false });

    while (stack.items.len > 0) {
        const entry = stack.pop() orelse break;

        if (entry.post) {
            in_stack.unset(entry.idx);
            visited.set(entry.idx);
            self.modules.at(entry.idx).exec_index = self.exec_counter;
            self.exec_counter += 1;
            continue;
        }

        if (visited.isSet(entry.idx)) continue;

        if (in_stack.isSet(entry.idx)) {
            self.cycle_counter += 1;
            const entry_mod = self.modules.at(entry.idx);
            entry_mod.cycle_group = self.cycle_counter;
            var k = stack.items.len;
            while (k > 0) {
                k -= 1;
                const e = stack.items[k];
                if (!e.post) continue;
                self.modules.at(e.idx).cycle_group = self.cycle_counter;
                if (e.idx == entry.idx) break;
            }
            self.addDiag(
                .circular_dependency,
                .warning,
                entry_mod.path,
                Span.EMPTY,
                .link,
                "Circular dependency detected",
                null,
            );
            continue;
        }

        in_stack.set(entry.idx);
        try stack.append(self.allocator, .{ .idx = entry.idx, .post = true });

        const deps = self.modules.at(entry.idx).dependencies.items;
        var j: usize = deps.len;
        while (j > 0) {
            j -= 1;
            const dep = @intFromEnum(deps[j]);
            if (dep < self.modules.count() and !visited.isSet(dep)) {
                try stack.append(self.allocator, .{ .idx = dep, .post = false });
            }
        }
    }
}

/// dynamic edge 도 따라가는 별도 cycle marking pass (#2211).
/// 기본 dfs 는 `dependencies` 만 follow 해서 exec_index/TLA 전파 분석 정확성을
/// 유지. 그러나 dynamic target 이 다른 모듈과 *static cycle* 이면 cycle 멤버
/// marking 이 필요 — `dependencies + dynamic_imports` 양쪽 따라가는 별도 dfs 로
/// cycle_group 만 부여한다 (exec_index 는 건드리지 않음).
pub fn markViaDynamic(self: anytype, entry_indices: []const ModuleIndex) !void {
    const count = self.modules.count();
    if (count == 0) return;

    var visited = try std.DynamicBitSet.initEmpty(self.allocator, count);
    defer visited.deinit();
    var in_stack = try std.DynamicBitSet.initEmpty(self.allocator, count);
    defer in_stack.deinit();

    const DfsEntry = struct { idx: u32, post: bool };
    var stack: std.ArrayList(DfsEntry) = .empty;
    defer stack.deinit(self.allocator);

    for (entry_indices) |entry_idx| {
        const start = @intFromEnum(entry_idx);
        if (start >= count) continue;
        if (visited.isSet(start)) continue;
        try stack.append(self.allocator, .{ .idx = start, .post = false });

        while (stack.items.len > 0) {
            const entry = stack.pop() orelse break;

            if (entry.post) {
                in_stack.unset(entry.idx);
                visited.set(entry.idx);
                continue;
            }

            if (visited.isSet(entry.idx)) continue;

            if (in_stack.isSet(entry.idx)) {
                self.cycle_counter += 1;
                var k = stack.items.len;
                while (k > 0) {
                    k -= 1;
                    const e = stack.items[k];
                    if (!e.post) continue;
                    if (self.modules.at(e.idx).cycle_group == 0) {
                        self.modules.at(e.idx).cycle_group = self.cycle_counter;
                    }
                    if (e.idx == entry.idx) break;
                }
                if (self.modules.at(entry.idx).cycle_group == 0) {
                    self.modules.at(entry.idx).cycle_group = self.cycle_counter;
                }
                continue;
            }

            in_stack.set(entry.idx);
            try stack.append(self.allocator, .{ .idx = entry.idx, .post = true });

            const cur_mod = self.modules.at(entry.idx);
            const dep_groups = [_][]const ModuleIndex{ cur_mod.dependencies.items, cur_mod.dynamic_imports.items };
            for (dep_groups) |group| {
                var j: usize = group.len;
                while (j > 0) {
                    j -= 1;
                    const dep = @intFromEnum(group[j]);
                    if (dep < count and !visited.isSet(dep)) {
                        try stack.append(self.allocator, .{ .idx = dep, .post = false });
                    }
                }
            }
        }
    }
}
