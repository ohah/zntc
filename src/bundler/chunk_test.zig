const std = @import("std");
const chunk_mod = @import("chunk.zig");
const BitSet = chunk_mod.BitSet;
const BitSetContext = chunk_mod.BitSetContext;
const Chunk = chunk_mod.Chunk;
const ChunkGraph = chunk_mod.ChunkGraph;
const ChunkKind = chunk_mod.ChunkKind;
const ChunkIndex = chunk_mod.ChunkIndex;
const types = @import("types.zig");
const ModuleIndex = types.ModuleIndex;
const Module = @import("module.zig").Module;
const ModuleGraph = @import("graph.zig").ModuleGraph;
const resolve_cache_mod = @import("resolve_cache.zig");

/// 테스트 전용: `[]Module` 를 graph 의 `SegmentedList` 에 append 해서
/// owning `ModuleGraph` 를 만든다.
///
/// Ownership model (#1779 PR #3 이후):
///   - `init` 이 caller 의 `modules` slice 를 **복사** 해 graph 에 소유권 이동.
///   - `deinit` 이 graph 내부 복사본 전체를 해제 (module + aux 필드).
///   - **caller 는 자기 로컬 modules[i] 의 `deinit` 을 호출하면 안 된다**
///     (그 Module 의 `dependencies`/`importers` ArrayList backing 은 graph 의
///     복사본과 공유돼 이중 free 가 발생함). 테스트 본체에서 `defer for (&modules)
///     |*m| m.deinit(alloc);` 패턴을 제거해야 함.
///
/// ArrayList 시절의 `.items = modules, .capacity = 0` non-owning hack 은
/// SegmentedList 로 교체되며 사용 불가. append 시점 기준으로 module 은 heap chunk
/// 에 복사되며, 기존 *Module 포인터는 append 이후에도 계속 유효 (SegmentedList 의
/// 핵심 불변식).
const TestGraph = struct {
    graph: ModuleGraph,
    cache: *resolve_cache_mod.ResolveCache,

    fn init(alloc: std.mem.Allocator, modules: []Module) !TestGraph {
        const cache_ptr = try alloc.create(resolve_cache_mod.ResolveCache);
        cache_ptr.* = resolve_cache_mod.ResolveCache.init(alloc, .{});
        var graph = ModuleGraph.init(alloc, cache_ptr);
        for (modules) |m| try graph.modules.append(alloc, m);
        return .{ .graph = graph, .cache = cache_ptr };
    }

    fn deinit(self: *TestGraph, alloc: std.mem.Allocator) void {
        // graph 소유: 복사본 module 들 + segment chunk + aux 필드.
        var it = self.graph.modules.iterator(0);
        while (it.next()) |m| m.deinit(alloc);
        self.graph.modules.deinit(alloc);
        self.graph.path_to_module.deinit();
        self.graph.diagnostics.deinit(alloc);
        self.graph.worker_entries.deinit(alloc);
        var pi_it = self.graph.pkg_info_cache.valueIterator();
        while (pi_it.next()) |info| info.side_effects.deinit(alloc);
        self.graph.pkg_info_cache.deinit(alloc);
        self.cache.deinit();
        alloc.destroy(self.cache);
    }
};

test "BitSet: init and isEmpty" {
    var bs = try BitSet.init(std.testing.allocator, 16);
    defer bs.deinit(std.testing.allocator);
    try std.testing.expect(bs.isEmpty());
}

test "BitSet: setBit and hasBit" {
    var bs = try BitSet.init(std.testing.allocator, 16);
    defer bs.deinit(std.testing.allocator);

    try std.testing.expect(!bs.hasBit(0));
    bs.setBit(0);
    try std.testing.expect(bs.hasBit(0));
    try std.testing.expect(!bs.hasBit(1));

    bs.setBit(5);
    try std.testing.expect(bs.hasBit(5));
    try std.testing.expect(!bs.isEmpty());
}

test "BitSet: clearBit" {
    var bs = try BitSet.init(std.testing.allocator, 16);
    defer bs.deinit(std.testing.allocator);

    bs.setBit(3);
    try std.testing.expect(bs.hasBit(3));
    bs.clearBit(3);
    try std.testing.expect(!bs.hasBit(3));
    try std.testing.expect(bs.isEmpty());
}

test "BitSet: multi-byte boundary (bit 7, 8)" {
    var bs = try BitSet.init(std.testing.allocator, 16);
    defer bs.deinit(std.testing.allocator);

    bs.setBit(7); // 첫 번째 바이트의 마지막 비트
    bs.setBit(8); // 두 번째 바이트의 첫 번째 비트
    try std.testing.expect(bs.hasBit(7));
    try std.testing.expect(bs.hasBit(8));
    try std.testing.expect(!bs.hasBit(6));
    try std.testing.expect(!bs.hasBit(9));
}

test "BitSet: bit 15 and 16 cross byte" {
    var bs = try BitSet.init(std.testing.allocator, 24);
    defer bs.deinit(std.testing.allocator);

    bs.setBit(15); // 두 번째 바이트의 마지막 비트
    bs.setBit(16); // 세 번째 바이트의 첫 번째 비트
    try std.testing.expect(bs.hasBit(15));
    try std.testing.expect(bs.hasBit(16));
    try std.testing.expect(!bs.hasBit(14));
    try std.testing.expect(!bs.hasBit(17));
}

test "BitSet: bitCount" {
    var bs = try BitSet.init(std.testing.allocator, 8);
    defer bs.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 0), bs.bitCount());
    bs.setBit(0);
    try std.testing.expectEqual(@as(u32, 1), bs.bitCount());
    bs.setBit(3);
    bs.setBit(7);
    try std.testing.expectEqual(@as(u32, 3), bs.bitCount());
}

test "BitSet: bitCount multi-byte" {
    var bs = try BitSet.init(std.testing.allocator, 24);
    defer bs.deinit(std.testing.allocator);

    bs.setBit(0);
    bs.setBit(8);
    bs.setBit(16);
    bs.setBit(23);
    try std.testing.expectEqual(@as(u32, 4), bs.bitCount());
}

test "BitSet: setUnion" {
    var a = try BitSet.init(std.testing.allocator, 16);
    defer a.deinit(std.testing.allocator);
    var b = try BitSet.init(std.testing.allocator, 16);
    defer b.deinit(std.testing.allocator);

    a.setBit(0);
    a.setBit(2);
    b.setBit(1);
    b.setBit(2);
    a.setUnion(b);

    try std.testing.expect(a.hasBit(0));
    try std.testing.expect(a.hasBit(1));
    try std.testing.expect(a.hasBit(2));
    try std.testing.expectEqual(@as(u32, 3), a.bitCount());
}

test "BitSet: eql same bits" {
    var a = try BitSet.init(std.testing.allocator, 16);
    defer a.deinit(std.testing.allocator);
    var b = try BitSet.init(std.testing.allocator, 16);
    defer b.deinit(std.testing.allocator);

    a.setBit(3);
    a.setBit(10);
    b.setBit(3);
    b.setBit(10);
    try std.testing.expect(a.eql(b));
}

test "BitSet: eql different bits" {
    var a = try BitSet.init(std.testing.allocator, 16);
    defer a.deinit(std.testing.allocator);
    var b = try BitSet.init(std.testing.allocator, 16);
    defer b.deinit(std.testing.allocator);

    a.setBit(3);
    b.setBit(4);
    try std.testing.expect(!a.eql(b));
}

test "BitSet: eql different lengths" {
    var a = try BitSet.init(std.testing.allocator, 8);
    defer a.deinit(std.testing.allocator);
    var b = try BitSet.init(std.testing.allocator, 16);
    defer b.deinit(std.testing.allocator);

    // 바이트 길이가 다르면 false
    try std.testing.expect(!a.eql(b));
}

test "BitSet: hash same bits same hash" {
    var a = try BitSet.init(std.testing.allocator, 16);
    defer a.deinit(std.testing.allocator);
    var b = try BitSet.init(std.testing.allocator, 16);
    defer b.deinit(std.testing.allocator);

    a.setBit(5);
    a.setBit(12);
    b.setBit(5);
    b.setBit(12);
    try std.testing.expectEqual(a.hash(), b.hash());
}

test "BitSet: hash different bits different hash" {
    var a = try BitSet.init(std.testing.allocator, 16);
    defer a.deinit(std.testing.allocator);
    var b = try BitSet.init(std.testing.allocator, 16);
    defer b.deinit(std.testing.allocator);

    a.setBit(0);
    b.setBit(1);
    // 해시 충돌 가능성은 있지만, 이 경우는 다를 것
    try std.testing.expect(a.hash() != b.hash());
}

test "BitSet: clone is independent" {
    var original = try BitSet.init(std.testing.allocator, 16);
    defer original.deinit(std.testing.allocator);
    original.setBit(3);

    var cloned = try original.clone(std.testing.allocator);
    defer cloned.deinit(std.testing.allocator);

    // 복사본은 동일한 비트를 가짐
    try std.testing.expect(cloned.hasBit(3));

    // 원본을 수정해도 복사본은 영향 없음
    original.setBit(7);
    try std.testing.expect(!cloned.hasBit(7));

    // 복사본을 수정해도 원본은 영향 없음
    cloned.clearBit(3);
    try std.testing.expect(original.hasBit(3));
}

test "BitSet: out of range setBit is no-op" {
    var bs = try BitSet.init(std.testing.allocator, 8);
    defer bs.deinit(std.testing.allocator);

    // 범위 밖 setBit은 무시됨 (패닉 없음)
    bs.setBit(100);
    try std.testing.expect(bs.isEmpty());
}

test "BitSet: out of range hasBit returns false" {
    var bs = try BitSet.init(std.testing.allocator, 8);
    defer bs.deinit(std.testing.allocator);

    // 범위 밖 hasBit은 false 반환
    try std.testing.expect(!bs.hasBit(100));
}

// ============================================================
// Tests — ChunkGraph
// ============================================================

test "ChunkGraph: init and deinit" {
    var cg = try ChunkGraph.init(std.testing.allocator, 10);
    defer cg.deinit();

    try std.testing.expectEqual(@as(usize, 0), cg.chunkCount());
    try std.testing.expectEqual(@as(usize, 10), cg.module_to_chunk.len);
}

test "ChunkGraph: addChunk returns sequential indices" {
    var cg = try ChunkGraph.init(std.testing.allocator, 4);
    defer cg.deinit();

    var bits0 = try BitSet.init(std.testing.allocator, 4);
    bits0.setBit(0);
    const idx0 = try cg.addChunk(Chunk.init(.none, .common, bits0));

    var bits1 = try BitSet.init(std.testing.allocator, 4);
    bits1.setBit(1);
    const idx1 = try cg.addChunk(Chunk.init(.none, .common, bits1));

    try std.testing.expectEqual(@as(u32, 0), @intFromEnum(idx0));
    try std.testing.expectEqual(@as(u32, 1), @intFromEnum(idx1));
}

test "ChunkGraph: assignModuleToChunk and getModuleChunk" {
    var cg = try ChunkGraph.init(std.testing.allocator, 4);
    defer cg.deinit();

    const mod0: ModuleIndex = @enumFromInt(0);
    const mod2: ModuleIndex = @enumFromInt(2);
    const chunk0: ChunkIndex = @enumFromInt(0);
    const chunk1: ChunkIndex = @enumFromInt(1);

    cg.assignModuleToChunk(mod0, chunk0);
    cg.assignModuleToChunk(mod2, chunk1);

    try std.testing.expectEqual(chunk0, cg.getModuleChunk(mod0));
    try std.testing.expectEqual(chunk1, cg.getModuleChunk(mod2));
}

test "ChunkGraph: unassigned module returns ChunkIndex.none" {
    var cg = try ChunkGraph.init(std.testing.allocator, 4);
    defer cg.deinit();

    const mod0: ModuleIndex = @enumFromInt(0);
    try std.testing.expect(cg.getModuleChunk(mod0).isNone());

    // 범위 밖 모듈도 .none 반환
    const mod_oob: ModuleIndex = @enumFromInt(100);
    try std.testing.expect(cg.getModuleChunk(mod_oob).isNone());
}

test "ChunkGraph: chunkCount" {
    var cg = try ChunkGraph.init(std.testing.allocator, 2);
    defer cg.deinit();

    try std.testing.expectEqual(@as(usize, 0), cg.chunkCount());

    var bits = try BitSet.init(std.testing.allocator, 2);
    bits.setBit(0);
    _ = try cg.addChunk(Chunk.init(.none, .common, bits));
    try std.testing.expectEqual(@as(usize, 1), cg.chunkCount());

    var bits2 = try BitSet.init(std.testing.allocator, 2);
    bits2.setBit(1);
    _ = try cg.addChunk(Chunk.init(.none, .common, bits2));
    try std.testing.expectEqual(@as(usize, 2), cg.chunkCount());
}

test "ChunkGraph: getChunk retrieves correct chunk" {
    var cg = try ChunkGraph.init(std.testing.allocator, 4);
    defer cg.deinit();

    const mod0: ModuleIndex = @enumFromInt(0);
    var bits0 = try BitSet.init(std.testing.allocator, 4);
    bits0.setBit(0);
    const idx0 = try cg.addChunk(Chunk.init(.none, .{ .entry_point = .{
        .bit = 0,
        .module = mod0,
        .is_dynamic = false,
    } }, bits0));

    var bits1 = try BitSet.init(std.testing.allocator, 4);
    bits1.setBit(1);
    const idx1 = try cg.addChunk(Chunk.init(.none, .common, bits1));

    const chunk0 = cg.getChunk(idx0);
    try std.testing.expect(chunk0.isEntryPoint());

    const chunk1 = cg.getChunk(idx1);
    try std.testing.expect(!chunk1.isEntryPoint());
}

test "Chunk: init sets defaults" {
    var bits = try BitSet.init(std.testing.allocator, 8);
    defer bits.deinit(std.testing.allocator);

    const chunk = Chunk.init(.none, .common, bits);
    try std.testing.expect(chunk.name == null);
    try std.testing.expect(chunk.filename == null);
    try std.testing.expectEqual(std.math.maxInt(u32), chunk.exec_order);
    try std.testing.expectEqual(@as(usize, 0), chunk.modules.items.len);
    try std.testing.expectEqual(@as(usize, 0), chunk.cross_chunk_imports.items.len);
    try std.testing.expectEqual(@as(usize, 0), chunk.cross_chunk_dynamic_imports.items.len);
}

test "Chunk: addModule" {
    const bits = try BitSet.init(std.testing.allocator, 8);
    var chunk = Chunk.init(.none, .common, bits);
    defer chunk.deinit(std.testing.allocator);

    const mod0: ModuleIndex = @enumFromInt(0);
    const mod5: ModuleIndex = @enumFromInt(5);

    try chunk.addModule(std.testing.allocator, mod0);
    try chunk.addModule(std.testing.allocator, mod5);

    try std.testing.expectEqual(@as(usize, 2), chunk.modules.items.len);
    try std.testing.expectEqual(mod0, chunk.modules.items[0]);
    try std.testing.expectEqual(mod5, chunk.modules.items[1]);
}

test "Chunk: isEntryPoint" {
    const mod0: ModuleIndex = @enumFromInt(0);

    const bits_entry = try BitSet.init(std.testing.allocator, 8);
    var entry = Chunk.init(.none, .{ .entry_point = .{
        .bit = 0,
        .module = mod0,
        .is_dynamic = false,
    } }, bits_entry);
    defer entry.deinit(std.testing.allocator);
    try std.testing.expect(entry.isEntryPoint());

    const bits_common = try BitSet.init(std.testing.allocator, 8);
    var common = Chunk.init(.none, .common, bits_common);
    defer common.deinit(std.testing.allocator);
    try std.testing.expect(!common.isEntryPoint());
}

test "ChunkKind: entry_point vs common" {
    const mod0: ModuleIndex = @enumFromInt(0);

    const ep: ChunkKind = .{ .entry_point = .{
        .bit = 2,
        .module = mod0,
        .is_dynamic = true,
    } };

    switch (ep) {
        .entry_point => |info| {
            try std.testing.expectEqual(@as(u32, 2), info.bit);
            try std.testing.expectEqual(mod0, info.module);
            try std.testing.expect(info.is_dynamic);
        },
        .common, .manual => unreachable,
    }

    const cm: ChunkKind = .common;
    try std.testing.expect(cm == .common);
}

// ============================================================
// Tests — generateChunks
// ============================================================

/// 테스트용 Module을 생성한다. javascript 타입, exec_index = index.
fn makeTestModule(alloc: std.mem.Allocator, index: u32, path: []const u8) Module {
    var m = Module.init(@enumFromInt(index), path);
    m.module_type = .javascript;
    m.exec_index = index;
    m.state = .ready;
    // ArrayList 필드는 .empty으로 초기화됨 — append 시 allocator를 전달
    _ = alloc;
    return m;
}

test "generateChunks: single entry, no dynamic imports" {
    // 구조: entry(a.ts) → b.ts → c.ts
    // 기대: 모든 모듈이 하나의 엔트리 청크에 포함
    const alloc = std.testing.allocator;

    var modules: [3]Module = .{
        makeTestModule(alloc, 0, "a.ts"),
        makeTestModule(alloc, 1, "b.ts"),
        makeTestModule(alloc, 2, "c.ts"),
    };

    // a → b → c
    try modules[0].dependencies.append(alloc, @enumFromInt(1));
    try modules[1].dependencies.append(alloc, @enumFromInt(2));

    var tg = try TestGraph.init(alloc, &modules);
    defer tg.deinit(alloc);
    var cg = try chunk_mod.generateChunks(alloc, &tg.graph, &.{"a.ts"}, null, &.{});
    defer cg.deinit();

    // 엔트리 청크 1개
    try std.testing.expectEqual(@as(usize, 1), cg.chunkCount());

    // 모든 모듈이 청크 0에 할당
    const chunk0: ChunkIndex = @enumFromInt(0);
    try std.testing.expectEqual(chunk0, cg.getModuleChunk(@enumFromInt(0)));
    try std.testing.expectEqual(chunk0, cg.getModuleChunk(@enumFromInt(1)));
    try std.testing.expectEqual(chunk0, cg.getModuleChunk(@enumFromInt(2)));

    // 청크가 엔트리 타입
    try std.testing.expect(cg.getChunk(chunk0).isEntryPoint());

    // 청크 이름 = 진입점 파일의 stem
    try std.testing.expectEqualStrings("a", cg.getChunk(chunk0).name.?);
}

test "generateChunks: dynamic import creates separate chunk" {
    // 구조: entry(index.ts) -static→ utils.ts
    //       entry(index.ts) -dynamic→ lazy.ts
    // 기대: index+utils → 청크0, lazy → 청크1
    const alloc = std.testing.allocator;

    var modules: [3]Module = .{
        makeTestModule(alloc, 0, "index.ts"),
        makeTestModule(alloc, 1, "utils.ts"),
        makeTestModule(alloc, 2, "lazy.ts"),
    };

    // index → utils (static), index → lazy (dynamic)
    try modules[0].dependencies.append(alloc, @enumFromInt(1));
    try modules[0].dynamic_imports.append(alloc, @enumFromInt(2));

    var tg = try TestGraph.init(alloc, &modules);
    defer tg.deinit(alloc);
    var cg = try chunk_mod.generateChunks(alloc, &tg.graph, &.{"index.ts"}, null, &.{});
    defer cg.deinit();

    // 엔트리 청크 1개 + dynamic 청크 1개 = 2개
    try std.testing.expectEqual(@as(usize, 2), cg.chunkCount());

    // index, utils → 청크 0 (유저 엔트리)
    const chunk0: ChunkIndex = @enumFromInt(0);
    try std.testing.expectEqual(chunk0, cg.getModuleChunk(@enumFromInt(0)));
    try std.testing.expectEqual(chunk0, cg.getModuleChunk(@enumFromInt(1)));

    // lazy → 청크 1 (dynamic 엔트리)
    const chunk1: ChunkIndex = @enumFromInt(1);
    try std.testing.expectEqual(chunk1, cg.getModuleChunk(@enumFromInt(2)));

    // 청크 1은 dynamic 엔트리
    const lazy_chunk = cg.getChunk(chunk1);
    switch (lazy_chunk.kind) {
        .entry_point => |info| try std.testing.expect(info.is_dynamic),
        .common, .manual => return error.TestUnexpectedResult,
    }
}

test "generateChunks: shared module creates common chunk" {
    // 구조: entry A(a.ts) → shared.ts
    //       entry B(b.ts) → shared.ts
    // 기대: a → 청크0, b → 청크1, shared → 공통 청크2
    const alloc = std.testing.allocator;

    var modules: [3]Module = .{
        makeTestModule(alloc, 0, "a.ts"),
        makeTestModule(alloc, 1, "b.ts"),
        makeTestModule(alloc, 2, "shared.ts"),
    };

    // a → shared, b → shared
    try modules[0].dependencies.append(alloc, @enumFromInt(2));
    try modules[1].dependencies.append(alloc, @enumFromInt(2));

    var tg = try TestGraph.init(alloc, &modules);
    defer tg.deinit(alloc);
    var cg = try chunk_mod.generateChunks(alloc, &tg.graph, &.{ "a.ts", "b.ts" }, null, &.{});
    defer cg.deinit();

    // 엔트리 2개 + 공통 1개 = 3개
    try std.testing.expectEqual(@as(usize, 3), cg.chunkCount());

    // a → 청크0, b → 청크1
    const chunk0: ChunkIndex = @enumFromInt(0);
    const chunk1: ChunkIndex = @enumFromInt(1);
    try std.testing.expectEqual(chunk0, cg.getModuleChunk(@enumFromInt(0)));
    try std.testing.expectEqual(chunk1, cg.getModuleChunk(@enumFromInt(1)));

    // shared → 청크2 (공통 청크)
    const shared_chunk_idx = cg.getModuleChunk(@enumFromInt(2));
    try std.testing.expect(!shared_chunk_idx.isNone());
    try std.testing.expect(!cg.getChunk(shared_chunk_idx).isEntryPoint());
}

test "generateChunks: diamond dependency" {
    // 구조: A(a.ts) → B(b.ts) → D(d.ts)
    //       A(a.ts) → C(c.ts) → D(d.ts)
    //       두 엔트리: A, C
    // 기대: A,B → 청크0 (A 엔트리에서만 도달), C → 청크1,
    //       D → 공통 청크 (A와 C 둘 다에서 도달)
    const alloc = std.testing.allocator;

    var modules: [4]Module = .{
        makeTestModule(alloc, 0, "a.ts"),
        makeTestModule(alloc, 1, "b.ts"),
        makeTestModule(alloc, 2, "c.ts"),
        makeTestModule(alloc, 3, "d.ts"),
    };

    // A → B, A → C, B → D, C → D
    try modules[0].dependencies.append(alloc, @enumFromInt(1));
    try modules[0].dependencies.append(alloc, @enumFromInt(2));
    try modules[1].dependencies.append(alloc, @enumFromInt(3));
    try modules[2].dependencies.append(alloc, @enumFromInt(3));

    var tg = try TestGraph.init(alloc, &modules);
    defer tg.deinit(alloc);
    var cg = try chunk_mod.generateChunks(alloc, &tg.graph, &.{ "a.ts", "c.ts" }, null, &.{});
    defer cg.deinit();

    // D가 양쪽 엔트리에서 도달 가능 → 공통 청크 생성
    const d_chunk_idx = cg.getModuleChunk(@enumFromInt(3));
    try std.testing.expect(!d_chunk_idx.isNone());
    try std.testing.expect(!cg.getChunk(d_chunk_idx).isEntryPoint());

    // C는 엔트리 청크1에 할당 (C가 두 번째 엔트리이므로 bit 1)
    // A 엔트리(bit 0)에서도 C에 도달하므로, C의 BitSet = {0,1}
    // 이는 D와 동일한 BitSet → 같은 공통 청크에 묶임
    const c_chunk_idx = cg.getModuleChunk(@enumFromInt(2));
    try std.testing.expect(!c_chunk_idx.isNone());

    // B는 A에서만 도달 → A 엔트리 청크에 묶임
    const b_chunk_idx = cg.getModuleChunk(@enumFromInt(1));
    const a_chunk_idx = cg.getModuleChunk(@enumFromInt(0));
    try std.testing.expectEqual(a_chunk_idx, b_chunk_idx);
}

test "generateChunks: no modules" {
    // 빈 모듈 배열 → 빈 ChunkGraph (청크 0개)
    const alloc = std.testing.allocator;
    var empty_modules: [0]Module = .{};

    var tg = try TestGraph.init(alloc, &empty_modules);
    defer tg.deinit(alloc);

    var cg = try chunk_mod.generateChunks(alloc, &tg.graph, &.{"entry.ts"}, null, &.{});
    defer cg.deinit();

    try std.testing.expectEqual(@as(usize, 0), cg.chunkCount());
}

test "generateChunks: circular dependency stays in same chunk" {
    // 구조: entry(a.ts) → b.ts → c.ts → b.ts (순환)
    // 기대: 모두 같은 엔트리 청크 (순환이 BitSet에 영향 없음)
    const alloc = std.testing.allocator;

    var modules: [3]Module = .{
        makeTestModule(alloc, 0, "a.ts"),
        makeTestModule(alloc, 1, "b.ts"),
        makeTestModule(alloc, 2, "c.ts"),
    };

    var tg = try TestGraph.init(alloc, &modules);
    defer tg.deinit(alloc);

    // a → b, b → c, c → b (순환)
    try tg.graph.linkDependency(@enumFromInt(0), @enumFromInt(1));
    try tg.graph.linkDependency(@enumFromInt(1), @enumFromInt(2));
    try tg.graph.linkDependency(@enumFromInt(2), @enumFromInt(1));

    var cg = try chunk_mod.generateChunks(alloc, &tg.graph, &.{"a.ts"}, null, &.{});
    defer cg.deinit();

    // 1 엔트리 청크, 모든 모듈 포함
    try std.testing.expectEqual(@as(usize, 1), cg.chunkCount());
    for (0..3) |i| {
        try std.testing.expect(!cg.getModuleChunk(@enumFromInt(@as(u32, @intCast(i)))).isNone());
    }
}

test "generateChunks: static + dynamic import same module" {
    // 구조: entry(a.ts) → static b.ts, a.ts → dynamic b.ts
    // 기대: b.ts는 static import 경로로 엔트리 청크에 포함 (dynamic 엔트리도 생성되지만 b가 이미 엔트리 청크에 있음)
    const alloc = std.testing.allocator;

    var modules: [2]Module = .{
        makeTestModule(alloc, 0, "a.ts"),
        makeTestModule(alloc, 1, "b.ts"),
    };

    var tg = try TestGraph.init(alloc, &modules);
    defer tg.deinit(alloc);

    try tg.graph.linkDependency(@enumFromInt(0), @enumFromInt(1));
    try tg.graph.modules.at(0).addDynamicImport(alloc, @enumFromInt(1));

    var cg = try chunk_mod.generateChunks(alloc, &tg.graph, &.{"a.ts"}, null, &.{});
    defer cg.deinit();

    // b.ts는 엔트리 청크에 포함 (static이 우선)
    const b_chunk = cg.getModuleChunk(@enumFromInt(1));
    try std.testing.expect(!b_chunk.isNone());
}

test "generateChunks: three entries sharing a module" {
    // 구조: a.ts, b.ts, c.ts 모두 → shared.ts
    // 기대: 3개 엔트리 청크 + 1개 공통 청크 (shared.ts: BitSet = {0,1,2})
    const alloc = std.testing.allocator;

    var modules: [4]Module = .{
        makeTestModule(alloc, 0, "a.ts"),
        makeTestModule(alloc, 1, "b.ts"),
        makeTestModule(alloc, 2, "c.ts"),
        makeTestModule(alloc, 3, "shared.ts"),
    };

    var tg = try TestGraph.init(alloc, &modules);
    defer tg.deinit(alloc);

    // 3개 엔트리가 모두 dynamic import로 생성됨
    // a→shared, b→shared, c→shared (static deps)
    try tg.graph.linkDependency(@enumFromInt(0), @enumFromInt(3));
    try tg.graph.linkDependency(@enumFromInt(1), @enumFromInt(3));
    try tg.graph.linkDependency(@enumFromInt(2), @enumFromInt(3));

    var cg = try chunk_mod.generateChunks(alloc, &tg.graph, &.{ "a.ts", "b.ts", "c.ts" }, null, &.{});
    defer cg.deinit();

    // 3 엔트리 + 1 공통 = 4 청크
    try std.testing.expectEqual(@as(usize, 4), cg.chunkCount());

    // shared.ts는 공통 청크에 할당
    const shared_chunk_idx = cg.getModuleChunk(@enumFromInt(3));
    try std.testing.expect(!shared_chunk_idx.isNone());
    const shared_chunk = cg.getChunk(shared_chunk_idx);
    try std.testing.expect(shared_chunk.kind == .common);
    // 3개 엔트리에서 모두 도달 가능
    try std.testing.expectEqual(@as(u32, 3), shared_chunk.bits.bitCount());
}

test "generateChunks: entry imports another entry statically" {
    // 구조: a.ts (엔트리) → b.ts (엔트리)
    // 기대: 각 엔트리는 자신의 청크를 가짐. b.ts는 두 엔트리에서 도달 가능 → 공통 청크 또는 b 엔트리 청크에 포함
    const alloc = std.testing.allocator;

    var modules: [2]Module = .{
        makeTestModule(alloc, 0, "a.ts"),
        makeTestModule(alloc, 1, "b.ts"),
    };

    var tg = try TestGraph.init(alloc, &modules);
    defer tg.deinit(alloc);

    try tg.graph.linkDependency(@enumFromInt(0), @enumFromInt(1));

    var cg = try chunk_mod.generateChunks(alloc, &tg.graph, &.{ "a.ts", "b.ts" }, null, &.{});
    defer cg.deinit();

    // 2개 엔트리 청크 생성
    try std.testing.expect(cg.chunkCount() >= 2);
    // 두 모듈 모두 할당됨
    try std.testing.expect(!cg.getModuleChunk(@enumFromInt(0)).isNone());
    try std.testing.expect(!cg.getModuleChunk(@enumFromInt(1)).isNone());
}

test "generateChunks: deep chain with dynamic import at middle" {
    // 구조: a.ts → b.ts → dynamic c.ts → d.ts
    // 기대: a,b는 엔트리 청크, c,d는 dynamic 엔트리 청크
    const alloc = std.testing.allocator;

    var modules: [4]Module = .{
        makeTestModule(alloc, 0, "a.ts"),
        makeTestModule(alloc, 1, "b.ts"),
        makeTestModule(alloc, 2, "c.ts"),
        makeTestModule(alloc, 3, "d.ts"),
    };

    var tg = try TestGraph.init(alloc, &modules);
    defer tg.deinit(alloc);

    try tg.graph.linkDependency(@enumFromInt(0), @enumFromInt(1));
    try tg.graph.modules.at(1).addDynamicImport(alloc, @enumFromInt(2));
    try tg.graph.linkDependency(@enumFromInt(2), @enumFromInt(3));

    var cg = try chunk_mod.generateChunks(alloc, &tg.graph, &.{"a.ts"}, null, &.{});
    defer cg.deinit();

    // 2개 청크: a엔트리(a,b), c엔트리(c,d)
    try std.testing.expectEqual(@as(usize, 2), cg.chunkCount());

    // a,b는 같은 청크 (엔트리)
    const a_chunk = cg.getModuleChunk(@enumFromInt(0));
    const b_chunk = cg.getModuleChunk(@enumFromInt(1));
    try std.testing.expect(!a_chunk.isNone());
    try std.testing.expectEqual(a_chunk, b_chunk);

    // c,d는 같은 청크 (dynamic 엔트리)
    const c_chunk = cg.getModuleChunk(@enumFromInt(2));
    const d_chunk = cg.getModuleChunk(@enumFromInt(3));
    try std.testing.expect(!c_chunk.isNone());
    try std.testing.expectEqual(c_chunk, d_chunk);

    // a,b 청크와 c,d 청크는 다름
    try std.testing.expect(a_chunk != c_chunk);
}

// ============================================================
// Tests — computeCrossChunkLinks
// ============================================================

test "computeCrossChunkLinks: no cross-chunk deps — 모든 모듈이 같은 청크" {
    // 구조: 모듈 0,1 모두 청크 0에 속함. 0 → 1 의존성.
    // 같은 청크 내 의존성이므로 cross_chunk_imports는 비어야 한다.
    const alloc = std.testing.allocator;

    var modules: [2]Module = .{
        makeTestModule(alloc, 0, "a.ts"),
        makeTestModule(alloc, 1, "b.ts"),
    };

    var tg = try TestGraph.init(alloc, &modules);
    defer tg.deinit(alloc);

    try tg.graph.linkDependency(@enumFromInt(0), @enumFromInt(1));

    // 청크 하나에 모듈 0,1 할당
    var cg = try ChunkGraph.init(alloc, 2);
    defer cg.deinit();

    var bits = try BitSet.init(alloc, 1);
    bits.setBit(0);
    const ci = try cg.addChunk(Chunk.init(.none, .common, bits));
    cg.assignModuleToChunk(@enumFromInt(0), ci);
    cg.assignModuleToChunk(@enumFromInt(1), ci);
    try cg.getChunkMut(ci).addModule(alloc, @enumFromInt(0));
    try cg.getChunkMut(ci).addModule(alloc, @enumFromInt(1));

    try chunk_mod.computeCrossChunkLinks(&cg, &tg.graph, alloc, null);

    try std.testing.expectEqual(@as(usize, 0), cg.getChunk(ci).cross_chunk_imports.items.len);
    try std.testing.expectEqual(@as(usize, 0), cg.getChunk(ci).cross_chunk_dynamic_imports.items.len);
}

test "computeCrossChunkLinks: static cross-chunk import" {
    // 구조: 청크 A(모듈 0), 청크 B(모듈 1). 모듈 0 → 모듈 1 정적 의존.
    // 기대: A.cross_chunk_imports에 B가 포함.
    const alloc = std.testing.allocator;

    var modules: [2]Module = .{
        makeTestModule(alloc, 0, "a.ts"),
        makeTestModule(alloc, 1, "b.ts"),
    };

    var tg = try TestGraph.init(alloc, &modules);
    defer tg.deinit(alloc);

    try tg.graph.linkDependency(@enumFromInt(0), @enumFromInt(1));

    var cg = try ChunkGraph.init(alloc, 2);
    defer cg.deinit();

    // 청크 A: 모듈 0
    var bits_a = try BitSet.init(alloc, 2);
    bits_a.setBit(0);
    const chunk_a = try cg.addChunk(Chunk.init(.none, .common, bits_a));
    cg.assignModuleToChunk(@enumFromInt(0), chunk_a);
    try cg.getChunkMut(chunk_a).addModule(alloc, @enumFromInt(0));

    // 청크 B: 모듈 1
    var bits_b = try BitSet.init(alloc, 2);
    bits_b.setBit(1);
    const chunk_b = try cg.addChunk(Chunk.init(.none, .common, bits_b));
    cg.assignModuleToChunk(@enumFromInt(1), chunk_b);
    try cg.getChunkMut(chunk_b).addModule(alloc, @enumFromInt(1));

    try chunk_mod.computeCrossChunkLinks(&cg, &tg.graph, alloc, null);

    // A → B 정적 import
    const a_imports = cg.getChunk(chunk_a).cross_chunk_imports.items;
    try std.testing.expectEqual(@as(usize, 1), a_imports.len);
    try std.testing.expectEqual(chunk_b, a_imports[0]);

    // B는 A를 import하지 않음
    try std.testing.expectEqual(@as(usize, 0), cg.getChunk(chunk_b).cross_chunk_imports.items.len);
}

test "computeCrossChunkLinks: dynamic cross-chunk import" {
    // 구조: 청크 A(모듈 0), 청크 B(모듈 1). 모듈 0이 모듈 1을 동적 import.
    // 기대: A.cross_chunk_dynamic_imports에 B가 포함.
    const alloc = std.testing.allocator;

    var modules: [2]Module = .{
        makeTestModule(alloc, 0, "a.ts"),
        makeTestModule(alloc, 1, "b.ts"),
    };
    try modules[0].addDynamicImport(alloc, @enumFromInt(1));

    var tg = try TestGraph.init(alloc, &modules);
    defer tg.deinit(alloc);

    var cg = try ChunkGraph.init(alloc, 2);
    defer cg.deinit();

    var bits_a = try BitSet.init(alloc, 2);
    bits_a.setBit(0);
    const chunk_a = try cg.addChunk(Chunk.init(.none, .common, bits_a));
    cg.assignModuleToChunk(@enumFromInt(0), chunk_a);
    try cg.getChunkMut(chunk_a).addModule(alloc, @enumFromInt(0));

    var bits_b = try BitSet.init(alloc, 2);
    bits_b.setBit(1);
    const chunk_b = try cg.addChunk(Chunk.init(.none, .common, bits_b));
    cg.assignModuleToChunk(@enumFromInt(1), chunk_b);
    try cg.getChunkMut(chunk_b).addModule(alloc, @enumFromInt(1));

    try chunk_mod.computeCrossChunkLinks(&cg, &tg.graph, alloc, null);

    // A의 동적 import에 B가 있어야 함
    const a_dyn = cg.getChunk(chunk_a).cross_chunk_dynamic_imports.items;
    try std.testing.expectEqual(@as(usize, 1), a_dyn.len);
    try std.testing.expectEqual(chunk_b, a_dyn[0]);

    // A의 정적 import는 비어야 함
    try std.testing.expectEqual(@as(usize, 0), cg.getChunk(chunk_a).cross_chunk_imports.items.len);
}

test "computeCrossChunkLinks: deduplication — 여러 모듈이 같은 청크를 import" {
    // 구조: 청크 A(모듈 0, 모듈 1), 청크 B(모듈 2).
    //       모듈 0 → 모듈 2, 모듈 1 → 모듈 2.
    // 기대: A.cross_chunk_imports에 B가 한 번만 포함.
    const alloc = std.testing.allocator;

    var modules: [3]Module = .{
        makeTestModule(alloc, 0, "a.ts"),
        makeTestModule(alloc, 1, "b.ts"),
        makeTestModule(alloc, 2, "c.ts"),
    };

    var tg = try TestGraph.init(alloc, &modules);
    defer tg.deinit(alloc);

    try tg.graph.linkDependency(@enumFromInt(0), @enumFromInt(2));
    try tg.graph.linkDependency(@enumFromInt(1), @enumFromInt(2));

    var cg = try ChunkGraph.init(alloc, 3);
    defer cg.deinit();

    // 청크 A: 모듈 0, 1
    var bits_a = try BitSet.init(alloc, 2);
    bits_a.setBit(0);
    const chunk_a = try cg.addChunk(Chunk.init(.none, .common, bits_a));
    cg.assignModuleToChunk(@enumFromInt(0), chunk_a);
    cg.assignModuleToChunk(@enumFromInt(1), chunk_a);
    try cg.getChunkMut(chunk_a).addModule(alloc, @enumFromInt(0));
    try cg.getChunkMut(chunk_a).addModule(alloc, @enumFromInt(1));

    // 청크 B: 모듈 2
    var bits_b = try BitSet.init(alloc, 2);
    bits_b.setBit(1);
    const chunk_b = try cg.addChunk(Chunk.init(.none, .common, bits_b));
    cg.assignModuleToChunk(@enumFromInt(2), chunk_b);
    try cg.getChunkMut(chunk_b).addModule(alloc, @enumFromInt(2));

    try chunk_mod.computeCrossChunkLinks(&cg, &tg.graph, alloc, null);

    // B가 정확히 1번만 나와야 함 (중복 제거)
    const a_imports = cg.getChunk(chunk_a).cross_chunk_imports.items;
    try std.testing.expectEqual(@as(usize, 1), a_imports.len);
    try std.testing.expectEqual(chunk_b, a_imports[0]);
}

test "computeCrossChunkLinks: bidirectional — A↔B 상호 의존" {
    // 구조: 청크 A(모듈 0), 청크 B(모듈 1). 모듈 0 → 모듈 1, 모듈 1 → 모듈 0.
    // 기대: A.cross_chunk_imports에 B, B.cross_chunk_imports에 A.
    const alloc = std.testing.allocator;

    var modules: [2]Module = .{
        makeTestModule(alloc, 0, "a.ts"),
        makeTestModule(alloc, 1, "b.ts"),
    };

    var tg = try TestGraph.init(alloc, &modules);
    defer tg.deinit(alloc);

    try tg.graph.linkDependency(@enumFromInt(0), @enumFromInt(1));
    try tg.graph.linkDependency(@enumFromInt(1), @enumFromInt(0));

    var cg = try ChunkGraph.init(alloc, 2);
    defer cg.deinit();

    var bits_a = try BitSet.init(alloc, 2);
    bits_a.setBit(0);
    const chunk_a = try cg.addChunk(Chunk.init(.none, .common, bits_a));
    cg.assignModuleToChunk(@enumFromInt(0), chunk_a);
    try cg.getChunkMut(chunk_a).addModule(alloc, @enumFromInt(0));

    var bits_b = try BitSet.init(alloc, 2);
    bits_b.setBit(1);
    const chunk_b = try cg.addChunk(Chunk.init(.none, .common, bits_b));
    cg.assignModuleToChunk(@enumFromInt(1), chunk_b);
    try cg.getChunkMut(chunk_b).addModule(alloc, @enumFromInt(1));

    try chunk_mod.computeCrossChunkLinks(&cg, &tg.graph, alloc, null);

    // A → B
    const a_imports = cg.getChunk(chunk_a).cross_chunk_imports.items;
    try std.testing.expectEqual(@as(usize, 1), a_imports.len);
    try std.testing.expectEqual(chunk_b, a_imports[0]);

    // B → A
    const b_imports = cg.getChunk(chunk_b).cross_chunk_imports.items;
    try std.testing.expectEqual(@as(usize, 1), b_imports.len);
    try std.testing.expectEqual(chunk_a, b_imports[0]);
}

test "generateChunks: entry module reassignment removes from old chunk" {
    // 엔트리 C가 다른 엔트리 A에서 static import → C의 BitSet이 공통 패턴과 일치
    // → Phase 3에서 공통 청크에 배정 → 후처리에서 엔트리 청크로 이동
    // → 이전 청크의 modules에서 제거되어야 함
    const alloc = std.testing.allocator;

    var modules: [3]Module = .{
        makeTestModule(alloc, 0, "a.ts"), // 엔트리 0
        makeTestModule(alloc, 1, "b.ts"), // 공유 모듈
        makeTestModule(alloc, 2, "c.ts"), // 엔트리 1 + A가 static import
    };

    var tg = try TestGraph.init(alloc, &modules);
    defer tg.deinit(alloc);

    // a → b (static), a → c (static), c → b (static)
    try tg.graph.linkDependency(@enumFromInt(0), @enumFromInt(1));
    try tg.graph.linkDependency(@enumFromInt(0), @enumFromInt(2));
    try tg.graph.linkDependency(@enumFromInt(2), @enumFromInt(1));

    var cg = try chunk_mod.generateChunks(alloc, &tg.graph, &.{ "a.ts", "c.ts" }, null, &.{});
    defer cg.deinit();

    // c.ts는 엔트리 청크에 있어야 함 (공통 청크 아님)
    const c_chunk = cg.getModuleChunk(@enumFromInt(2));
    try std.testing.expect(!c_chunk.isNone());

    // c.ts가 하나의 청크에만 존재하는지 확인 (중복 방지)
    var count: u32 = 0;
    for (cg.chunks.items) |chunk| {
        for (chunk.modules.items) |mod_idx| {
            if (@intFromEnum(mod_idx) == 2) count += 1;
        }
    }
    try std.testing.expectEqual(@as(u32, 1), count);
}
