const std = @import("std");
const types = @import("../types.zig");
const module_mod = @import("../module.zig");
const graph_state = @import("state.zig");

const ModuleIndex = types.ModuleIndex;
const Module = module_mod.Module;

/// idx 검증 → modules storage 의 in-range index 반환. read/mut 양쪽 진입점에서 공유.
pub inline fn validModuleSlot(self: anytype, idx: ModuleIndex) ?usize {
    if (idx.isNone()) return null;
    const i = idx.toUsize();
    if (i >= self.modules.count()) return null;
    return i;
}

/// idx 에 해당하는 module 의 read-only 포인터. 범위 밖이면 null.
pub inline fn getModule(self: anytype, idx: ModuleIndex) ?*const Module {
    const i = validModuleSlot(self, idx) orelse return null;
    return self.modules.at(i);
}

/// 등록된 module 개수. storage 내부 구조 캡슐화 진입점.
pub inline fn moduleCount(self: anytype) usize {
    return self.modules.count();
}

/// path 와 정확히 일치하는 module 의 read-only 포인터. SegmentedList 선형 스캔이라
/// O(N) — entry/RBM 주입처럼 build 당 호출 횟수가 작은 경로에서만 사용한다.
pub fn findModuleByPath(self: anytype, path: []const u8) ?*const Module {
    var it = modulesIterator(self);
    while (it.next()) |m| {
        if (std.mem.eql(u8, m.path, path)) return m;
    }
    return null;
}

/// **Accessor 전용**. 직접 호출 금지 — `parseAccessor()` 등 phase accessor 의
/// setter 메서드를 사용하라. 외부 mutable pointer 노출은 worker race 의 root.
pub inline fn moduleAtMut(self: anytype, idx: ModuleIndex) ?*Module {
    const i = validModuleSlot(self, idx) orelse return null;
    return self.modules.at(i);
}

/// 모든 module 을 순회하는 read-only iterator. SegmentedList 의 chunk 경계를
/// 투명하게 처리하는 ConstIterator 를 그대로 노출.
pub inline fn modulesIterator(self: anytype) graph_state.ModulesIterator {
    return self.modules.constIterator(0);
}
