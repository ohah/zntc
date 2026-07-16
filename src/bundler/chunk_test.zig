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
const ExportBinding = @import("module.zig").ExportBinding;
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
        self.graph.path_to_module.deinit(alloc);
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

/// 테스트용 Module을 생성한다. JS 타입, exec_index = index.
fn makeTestModule(alloc: std.mem.Allocator, index: u32, path: []const u8) Module {
    var m = Module.init(@enumFromInt(index), path);
    m.module_type = .js;
    m.exec_index = index;
    m.state = .ready;
    // ArrayList 필드는 .empty으로 초기화됨 — append 시 allocator를 전달
    _ = alloc;
    return m;
}

// ============================================================
// Tests — crossChunkExportShakenDecision (#4495)
// ============================================================

/// 크로스-청크 export 목록에서 뺄지 말지의 결정표.
///
/// `tree_shaker_active=true` + `is_included=false` = 모듈 자체가 emit 안 됨 →
/// `isLocalBindingAlive` 가 dead 판정하는 가장 단순한 경로. 나머지 축(래핑 /
/// star 소스 / 청크 entry+non-minify / export kind)은 전부 **유지(false)** 쪽으로
/// 보수 폴백해야 한다 — 잘못 빼면 소비자가 미바인딩(ReferenceError) 된다.
fn shakenDecisionModule(dead: bool) Module {
    var m = Module.init(@enumFromInt(0), "barrel.ts");
    m.module_type = .js;
    m.state = .ready;
    m.tree_shaker_active = true;
    m.is_included = !dead;
    return m;
}

test "crossChunkExportShakenDecision: 선언이 DCE 된 .local export 는 목록에서 제외 (#4495)" {
    var m = shakenDecisionModule(true);
    var ebs = [_]ExportBinding{
        .{ .exported_name = "extra", .local_name = "extra", .local_span = .{ .start = 0, .end = 0 }, .kind = .local },
    };
    m.export_bindings = &ebs;

    try std.testing.expect(chunk_mod.crossChunkExportShakenDecision(&m, "extra", false, true, false));
    // 살아있는 선언(모듈이 emit 됨) → 유지.
    var alive = shakenDecisionModule(false);
    alive.export_bindings = &ebs;
    try std.testing.expect(!chunk_mod.crossChunkExportShakenDecision(&alive, "extra", false, true, false));
}

test "crossChunkExportShakenDecision: emitter 가 statement DCE 를 건너뛰는 모듈은 보수적 유지 (#4495)" {
    var ebs = [_]ExportBinding{
        .{ .exported_name = "extra", .local_name = "extra", .local_span = .{ .start = 0, .end = 0 }, .kind = .local },
    };

    // tree-shaker 비활성(dev / --no-tree-shaking) → 판정 불가 → 유지.
    var no_shaker = shakenDecisionModule(true);
    no_shaker.export_bindings = &ebs;
    no_shaker.tree_shaker_active = false;
    try std.testing.expect(!chunk_mod.crossChunkExportShakenDecision(&no_shaker, "extra", false, true, false));

    // 래핑 모듈(__esm / __commonJS) → emitter statement-shake 게이트 제외 → 유지.
    for ([_]types.WrapKind{ .esm, .cjs }) |wk| {
        var wrapped = shakenDecisionModule(true);
        wrapped.export_bindings = &ebs;
        wrapped.wrap_kind = wk;
        try std.testing.expect(!chunk_mod.crossChunkExportShakenDecision(&wrapped, "extra", false, true, false));
    }

    // `export * from "./this"` 소스 → emitter 가 all_used 로 DCE 자체를 끔 → 유지.
    var star = shakenDecisionModule(true);
    star.export_bindings = &ebs;
    try std.testing.expect(!chunk_mod.crossChunkExportShakenDecision(&star, "extra", false, true, true));

    // 청크 entry 모듈 + minify_syntax=false → statement-shake 안 돎(선언 그대로 emit) → 유지.
    var entry = shakenDecisionModule(true);
    entry.export_bindings = &ebs;
    try std.testing.expect(!chunk_mod.crossChunkExportShakenDecision(&entry, "extra", true, false, false));
    // 같은 entry 라도 minify_syntax=true 면 shake 가 돌아 선언이 사라진다 → 제외.
    try std.testing.expect(chunk_mod.crossChunkExportShakenDecision(&entry, "extra", true, true, false));
}

test "crossChunkExportShakenDecision: .local 이 아닌 export / 미등록 이름은 유지 (#4495)" {
    // re-export 는 canonical 선언이 이 모듈에 없다 → 로컬 선언 유무로 판정 불가.
    var re = shakenDecisionModule(true);
    var re_ebs = [_]ExportBinding{
        .{ .exported_name = "extra", .local_name = "extra", .local_span = .{ .start = 0, .end = 0 }, .kind = .re_export },
    };
    re.export_bindings = &re_ebs;
    try std.testing.expect(!chunk_mod.crossChunkExportShakenDecision(&re, "extra", false, true, false));

    // 합성 namespace 변수(`X_ns`) 처럼 export_bindings 에 없는 이름 → 유지.
    var ns = shakenDecisionModule(true);
    try std.testing.expect(!chunk_mod.crossChunkExportShakenDecision(&ns, "barrel_ns", false, true, false));
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
    var cg = try chunk_mod.generateChunks(alloc, &tg.graph, &.{"a.ts"}, .{});
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
    var cg = try chunk_mod.generateChunks(alloc, &tg.graph, &.{"index.ts"}, .{});
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
    var cg = try chunk_mod.generateChunks(alloc, &tg.graph, &.{ "a.ts", "b.ts" }, .{});
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
    var cg = try chunk_mod.generateChunks(alloc, &tg.graph, &.{ "a.ts", "c.ts" }, .{});
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

    var cg = try chunk_mod.generateChunks(alloc, &tg.graph, &.{"entry.ts"}, .{});
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

    var cg = try chunk_mod.generateChunks(alloc, &tg.graph, &.{"a.ts"}, .{});
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

    var cg = try chunk_mod.generateChunks(alloc, &tg.graph, &.{"a.ts"}, .{});
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

    var cg = try chunk_mod.generateChunks(alloc, &tg.graph, &.{ "a.ts", "b.ts", "c.ts" }, .{});
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

    var cg = try chunk_mod.generateChunks(alloc, &tg.graph, &.{ "a.ts", "b.ts" }, .{});
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

    var cg = try chunk_mod.generateChunks(alloc, &tg.graph, &.{"a.ts"}, .{});
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

test "deconflictGlobalName: 동명 → \\$N 유니크화 + 예약어 회피 (#4101 전역 네이밍 코어)" {
    const alloc = std.testing.allocator;
    var used: std.StringHashMapUnmanaged(void) = .empty;
    defer used.deinit(alloc);

    // 첫 'v' → 'v'.
    const n1 = try chunk_mod.deconflictGlobalName(alloc, &used, "v");
    defer alloc.free(n1);
    try std.testing.expectEqualStrings("v", n1);
    try used.put(alloc, n1, {});

    // 둘째 'v' → 'v$1' (충돌 회피).
    const n2 = try chunk_mod.deconflictGlobalName(alloc, &used, "v");
    defer alloc.free(n2);
    try std.testing.expectEqualStrings("v$1", n2);
    try used.put(alloc, n2, {});

    // 셋째 'v' → 'v$2'.
    const n3 = try chunk_mod.deconflictGlobalName(alloc, &used, "v");
    defer alloc.free(n3);
    try std.testing.expectEqualStrings("v$2", n3);

    // 예약어는 그대로 못 씀 → suffix.
    const nd = try chunk_mod.deconflictGlobalName(alloc, &used, "default");
    defer alloc.free(nd);
    try std.testing.expect(!std.mem.eql(u8, nd, "default"));
    try std.testing.expectEqualStrings("default$1", nd);

    // 충돌 없는 이름은 그대로.
    const nf = try chunk_mod.deconflictGlobalName(alloc, &used, "foo");
    defer alloc.free(nf);
    try std.testing.expectEqualStrings("foo", nf);
}

test "sanitizeGlobalNameHead: ns 키/비-식별자 멤버명 → 유효 식별자 head (#4510)" {
    const alloc = std.testing.allocator;

    // namespace 키("*") → `ns` (공개명은 `ns$<모듈태그>` 가 된다).
    const ns = try chunk_mod.sanitizeGlobalNameHead(alloc, "*");
    defer alloc.free(ns);
    try std.testing.expectEqualStrings("ns", ns);

    // 평범한 멤버명은 그대로(기존 공개명과 바이트 동일 — 회귀 방지).
    const plain = try chunk_mod.sanitizeGlobalNameHead(alloc, "named");
    defer alloc.free(plain);
    try std.testing.expectEqualStrings("named", plain);

    const def = try chunk_mod.sanitizeGlobalNameHead(alloc, "default");
    defer alloc.free(def);
    try std.testing.expectEqualStrings("default", def);

    // 비-식별자 멤버명은 binding_scanner 가 **따옴표까지** 담아 둔 원문이 들어온다.
    // 따옴표를 벗기고 식별자 문자만 남긴다.
    const dq = try chunk_mod.sanitizeGlobalNameHead(alloc, "\"foo-bar\"");
    defer alloc.free(dq);
    try std.testing.expectEqualStrings("foo_bar", dq);

    const sq = try chunk_mod.sanitizeGlobalNameHead(alloc, "'a.b c'");
    defer alloc.free(sq);
    try std.testing.expectEqualStrings("a_b_c", sq);

    // 숫자로 시작하는 이름은 식별자가 될 수 없으므로 첫 글자를 `_` 로.
    const num = try chunk_mod.sanitizeGlobalNameHead(alloc, "\"0abc\"");
    defer alloc.free(num);
    try std.testing.expectEqualStrings("_abc", num);

    // 전부 비-식별자 문자 → 빈 문자열 방지.
    const empty = try chunk_mod.sanitizeGlobalNameHead(alloc, "\"\"");
    defer alloc.free(empty);
    try std.testing.expectEqualStrings("_", empty);
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

    var cg = try chunk_mod.generateChunks(alloc, &tg.graph, &.{ "a.ts", "c.ts" }, .{});
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

test "generateChunks: inline_dynamic_imports=false — dynamic target 은 별도 chunk" {
    const alloc = std.testing.allocator;
    var modules: [2]Module = .{
        makeTestModule(alloc, 0, "entry.ts"),
        makeTestModule(alloc, 1, "lazy.ts"),
    };
    var tg = try TestGraph.init(alloc, &modules);
    defer tg.deinit(alloc);

    try tg.graph.linkDynamicImport(@enumFromInt(0), @enumFromInt(1));

    var cg = try chunk_mod.generateChunks(alloc, &tg.graph, &.{"entry.ts"}, .{});
    defer cg.deinit();

    // 기본 정책 — lazy 는 entry 와 다른 chunk 에 배정
    const entry_chunk = cg.getModuleChunk(@enumFromInt(0));
    const lazy_chunk = cg.getModuleChunk(@enumFromInt(1));
    try std.testing.expect(!entry_chunk.isNone());
    try std.testing.expect(!lazy_chunk.isNone());
    try std.testing.expect(entry_chunk != lazy_chunk);
}

test "generateChunks: inline_dynamic_imports=true — dynamic target 이 entry chunk 에 흡수" {
    const alloc = std.testing.allocator;
    var modules: [2]Module = .{
        makeTestModule(alloc, 0, "entry.ts"),
        makeTestModule(alloc, 1, "lazy.ts"),
    };
    var tg = try TestGraph.init(alloc, &modules);
    defer tg.deinit(alloc);

    try tg.graph.linkDynamicImport(@enumFromInt(0), @enumFromInt(1));

    var cg = try chunk_mod.generateChunks(alloc, &tg.graph, &.{"entry.ts"}, .{ .inline_dynamic_imports = true });
    defer cg.deinit();

    // inline 정책 — lazy 가 entry chunk 로 흡수. 전체 청크 1개.
    try std.testing.expectEqual(@as(usize, 1), cg.chunks.items.len);
    const entry_chunk = cg.getModuleChunk(@enumFromInt(0));
    const lazy_chunk = cg.getModuleChunk(@enumFromInt(1));
    try std.testing.expect(entry_chunk == lazy_chunk);
}

test "generateChunks: inline_dynamic_imports + manual_chunks — manual seed 의 dynamic dep 도 manual chunk 로" {
    // Phase 2.5 manual BFS 가 inline 모드에서 dynamic edge 를 따라가야 한다 (/simplify 후속).
    const alloc = std.testing.allocator;
    var modules: [3]Module = .{
        makeTestModule(alloc, 0, "entry.ts"),
        makeTestModule(alloc, 1, "vendor-root.ts"),
        makeTestModule(alloc, 2, "vendor-lazy.ts"),
    };
    var tg = try TestGraph.init(alloc, &modules);
    defer tg.deinit(alloc);

    // entry → vendor-root (static), vendor-root → vendor-lazy (dynamic)
    try tg.graph.linkDependency(@enumFromInt(0), @enumFromInt(1));
    try tg.graph.linkDynamicImport(@enumFromInt(1), @enumFromInt(2));

    const manual_entries = [_]types.ManualChunkEntry{.{ .name = "vendor", .patterns = &.{"vendor-"} }};
    var cg = try chunk_mod.generateChunks(alloc, &tg.graph, &.{"entry.ts"}, .{
        .manual_chunks = &manual_entries,
        .inline_dynamic_imports = true,
    });
    defer cg.deinit();

    // vendor-root 은 manual 매칭, vendor-lazy 는 vendor-root 의 dynamic dep.
    // inline + manual BFS 확장으로 vendor-lazy 도 vendor chunk 로.
    const vendor_chunk = cg.getModuleChunk(@enumFromInt(1));
    try std.testing.expect(!vendor_chunk.isNone());
    try std.testing.expect(cg.getModuleChunk(@enumFromInt(2)) == vendor_chunk);
}

test "generateChunks: inline_dynamic_imports — dynamic target 의 transitive static dep 도 흡수" {
    const alloc = std.testing.allocator;
    var modules: [3]Module = .{
        makeTestModule(alloc, 0, "entry.ts"),
        makeTestModule(alloc, 1, "lazy.ts"),
        makeTestModule(alloc, 2, "util.ts"),
    };
    var tg = try TestGraph.init(alloc, &modules);
    defer tg.deinit(alloc);

    // entry → lazy (dynamic) → util (static)
    try tg.graph.linkDynamicImport(@enumFromInt(0), @enumFromInt(1));
    try tg.graph.linkDependency(@enumFromInt(1), @enumFromInt(2));

    var cg = try chunk_mod.generateChunks(alloc, &tg.graph, &.{"entry.ts"}, .{ .inline_dynamic_imports = true });
    defer cg.deinit();

    try std.testing.expectEqual(@as(usize, 1), cg.chunks.items.len);
    const entry_chunk = cg.getModuleChunk(@enumFromInt(0));
    try std.testing.expect(cg.getModuleChunk(@enumFromInt(1)) == entry_chunk);
    try std.testing.expect(cg.getModuleChunk(@enumFromInt(2)) == entry_chunk);
}

test "generateChunks: external phantom 은 chunk 배정 받지 않음" {
    const alloc = std.testing.allocator;

    var modules: [2]Module = .{
        makeTestModule(alloc, 0, "entry.ts"),
        makeTestModule(alloc, 1, "react"),
    };
    var tg = try TestGraph.init(alloc, &modules);
    defer tg.deinit(alloc);

    // module 1 을 external 로 표시 + entry → react static link
    tg.graph.modules.at(1).is_external = true;
    try tg.graph.linkDependency(@enumFromInt(0), @enumFromInt(1));

    var cg = try chunk_mod.generateChunks(alloc, &tg.graph, &.{"entry.ts"}, .{});
    defer cg.deinit();

    // entry chunk 1개. external phantom 은 어느 chunk 에도 안 들어감.
    try std.testing.expectEqual(@as(usize, 1), cg.chunks.items.len);
    const entry_chunk = cg.getModuleChunk(@enumFromInt(0));
    try std.testing.expect(!entry_chunk.isNone());
    const react_chunk = cg.getModuleChunk(@enumFromInt(1));
    try std.testing.expect(react_chunk.isNone());
}

test "generateChunks: external 가 manual pattern 매칭돼도 manual chunk 안 만들어짐" {
    // Phase 1d 에서 phantom 의 path = "vendor-react" 가 manual pattern "vendor-" 매칭해도
    // is_external 가드로 seeds 에 안 들어가야. 빈 manual chunk 회피.
    const alloc = std.testing.allocator;

    var modules: [2]Module = .{
        makeTestModule(alloc, 0, "entry.ts"),
        makeTestModule(alloc, 1, "vendor-react"),
    };
    var tg = try TestGraph.init(alloc, &modules);
    defer tg.deinit(alloc);

    tg.graph.modules.at(1).is_external = true;
    try tg.graph.linkDependency(@enumFromInt(0), @enumFromInt(1));

    const manual_entries = [_]types.ManualChunkEntry{.{ .name = "vendor", .patterns = &.{"vendor-"} }};
    var cg = try chunk_mod.generateChunks(alloc, &tg.graph, &.{"entry.ts"}, .{ .manual_chunks = &manual_entries });
    defer cg.deinit();

    // entry chunk 만. vendor manual chunk 는 매칭 모듈 0 이라 생성 안 됨.
    try std.testing.expectEqual(@as(usize, 1), cg.chunks.items.len);
}

test "generateChunks: (#4553) manualChunks 매칭돼도 user entry 는 자기 entry_point 청크 유지" {
    // Option A: user entry 는 manual 청크로 relocate 되지 않는다(rollup/esbuild 불변식). 패턴이
    // entry 와 non-entry 를 모두 매칭해도, entry 는 자기 entry_point 청크에 남고 non-entry(lib)만
    // manual 청크로 간다. (entry-in-manual 이면 entry 실행 인프라가 흩어져 깨지던 #4542/#4548 계열
    // 화수분의 근원 제거.)
    const alloc = std.testing.allocator;

    var modules: [2]Module = .{
        makeTestModule(alloc, 0, "entry.ts"),
        makeTestModule(alloc, 1, "lib.ts"),
    };
    var tg = try TestGraph.init(alloc, &modules);
    defer tg.deinit(alloc);

    try tg.graph.linkDependency(@enumFromInt(0), @enumFromInt(1)); // entry → lib (static)

    // 패턴이 entry 와 lib 를 **모두** 매칭.
    const manual_entries = [_]types.ManualChunkEntry{.{ .name = "grp", .patterns = &.{ "entry", "lib" } }};
    var cg = try chunk_mod.generateChunks(alloc, &tg.graph, &.{"entry.ts"}, .{ .manual_chunks = &manual_entries });
    defer cg.deinit();

    const entry_ci = cg.getModuleChunk(@enumFromInt(0));
    const lib_ci = cg.getModuleChunk(@enumFromInt(1));
    try std.testing.expect(!entry_ci.isNone());
    try std.testing.expect(!lib_ci.isNone());
    try std.testing.expect(entry_ci != lib_ci); // 서로 다른 청크
    // 핵심: entry 는 relocate 안 됨(자기 entry_point 청크), lib 만 manual.
    try std.testing.expect(cg.getChunk(entry_ci).kind == .entry_point);
    try std.testing.expect(cg.getChunk(lib_ci).kind == .manual);
}

test "generateChunks: (#4553 code-review) 중복 이름 record 는 crash 없이 한 청크로 병합" {
    // 두 pattern group 을 같은 청크명으로 지정하는 건 합법. `ManualChunkEntry.lookup` 이 raw record
    // index 를 반환하는데 ensureNameSlot 이 이름을 한 slot 으로 dedupe → raw index(=1)로
    // manual_seeds/effective_names(len=1)를 인덱싱하면 OOB panic 이었다(pre-existing). name→slot
    // 매핑으로 수정. react·lodash 둘 다 'vendor' 한 청크로.
    const alloc = std.testing.allocator;

    var modules: [3]Module = .{
        makeTestModule(alloc, 0, "entry.ts"),
        makeTestModule(alloc, 1, "react.ts"),
        makeTestModule(alloc, 2, "lodash.ts"),
    };
    var tg = try TestGraph.init(alloc, &modules);
    defer tg.deinit(alloc);

    try tg.graph.linkDependency(@enumFromInt(0), @enumFromInt(1));
    try tg.graph.linkDependency(@enumFromInt(0), @enumFromInt(2));

    // 같은 이름 'vendor' 를 두 record 로 — dedupe 되어 slot 1개.
    const manual_entries = [_]types.ManualChunkEntry{
        .{ .name = "vendor", .patterns = &.{"react"} },
        .{ .name = "vendor", .patterns = &.{"lodash"} },
    };
    var cg = try chunk_mod.generateChunks(alloc, &tg.graph, &.{"entry.ts"}, .{ .manual_chunks = &manual_entries });
    defer cg.deinit();

    // crash 없이: react·lodash 는 같은 'vendor' manual 청크로 병합.
    const react_ci = cg.getModuleChunk(@enumFromInt(1));
    const lodash_ci = cg.getModuleChunk(@enumFromInt(2));
    try std.testing.expect(!react_ci.isNone());
    try std.testing.expect(react_ci == lodash_ci); // 두 record 가 한 청크로
    try std.testing.expect(cg.getChunk(react_ci).kind == .manual);
}

// ============================================================
// (#4494) 직접 CJS import 의 cross-chunk 심볼 등록
// ============================================================

const linker_mod = @import("linker.zig");
const Linker = linker_mod.Linker;
const test_helpers = @import("test_helpers.zig");

// 다른 청크의 CJS 모듈을 **직접** import(`import d from './lib.cjs'`)하면 cross-chunk
// 심볼로 등록돼야 한다. CJS 는 정적 export 가 없어 `resolveExportChain` 이 null →
// resolved binding 이 없고, 예전엔 그대로 skip 돼 심볼이 등록되지 않았다. 그 결과
// 소비자 청크가 provider 청크에만 있는 `require_X()` 썽크를 참조 = ReferenceError (#4494).
test "computeCrossChunkLinks: 직접 CJS import 도 cross-chunk 심볼로 등록 (#4494)" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // lib.cjs 는 a/b 양쪽에서 도달 → common 청크. a 는 그 CJS 를 직접 import(cross-chunk).
    try test_helpers.writeFile(tmp.dir, "lib.cjs", "module.exports = { tag: 1 };");
    try test_helpers.writeFile(tmp.dir, "shared.ts", "import d from './lib.cjs';\nexport const s = d.tag;");
    try test_helpers.writeFile(tmp.dir, "a.ts", "import d from './lib.cjs';\nimport { s } from './shared';\nconsole.log(d.tag, s);");
    try test_helpers.writeFile(tmp.dir, "b.ts", "import { s } from './shared';\nconsole.log(s);");

    const ep_a = try test_helpers.absPath(&tmp, "a.ts");
    defer alloc.free(ep_a);
    const ep_b = try test_helpers.absPath(&tmp, "b.ts");
    defer alloc.free(ep_b);

    var cache = resolve_cache_mod.ResolveCache.init(alloc, .{});
    defer cache.deinit();
    const graph = try alloc.create(ModuleGraph);
    defer alloc.destroy(graph);
    graph.* = ModuleGraph.init(alloc, &cache);
    defer graph.deinit();
    try graph.build(std.testing.io, &.{ ep_a, ep_b });

    var linker = Linker.init(alloc, graph, .esm);
    defer linker.deinit();
    try linker.link();

    var cg = try chunk_mod.generateChunks(alloc, graph, &.{ ep_a, ep_b }, .{});
    defer cg.deinit();
    try chunk_mod.computeCrossChunkLinks(&cg, graph, alloc, &linker);

    // lib.cjs / a.ts 의 모듈 인덱스를 path 로 찾는다.
    var cjs_mi: ?u32 = null;
    var a_mi: ?u32 = null;
    for (0..graph.moduleCount()) |i| {
        const m = graph.getModule(ModuleIndex.fromUsize(@intCast(i))) orelse continue;
        if (std.mem.endsWith(u8, m.path, "lib.cjs")) cjs_mi = @intCast(i);
        if (std.mem.endsWith(u8, m.path, "a.ts")) a_mi = @intCast(i);
    }
    try std.testing.expect(cjs_mi != null);
    try std.testing.expect(a_mi != null);
    // CJS 로 래핑됐는지 (전제 확인)
    try std.testing.expect(graph.getModule(ModuleIndex.fromUsize(cjs_mi.?)).?.wrap_kind == .cjs);

    const a_chunk = cg.getModuleChunk(ModuleIndex.fromUsize(a_mi.?));
    const cjs_chunk = cg.getModuleChunk(ModuleIndex.fromUsize(cjs_mi.?));
    try std.testing.expect(!a_chunk.isNone() and !cjs_chunk.isNone());
    // lib.cjs 가 a 와 같은 청크면 이 테스트의 전제(cross-chunk)가 성립하지 않는다.
    try std.testing.expect(a_chunk != cjs_chunk);

    // a 청크가 lib.cjs 청크에서 "default" 를 가져온다 (canonical = lib.cjs).
    const syms = cg.getChunk(a_chunk).imports_from.get(@intFromEnum(cjs_chunk));
    try std.testing.expect(syms != null);
    var found = false;
    for (syms.?.items) |sym| {
        if (std.mem.eql(u8, sym.name, "default") and sym.canonical_module == cjs_mi.?) found = true;
    }
    try std.testing.expect(found);
    // provider 청크는 그 이름을 노출한다.
    try std.testing.expect(cg.getChunk(cjs_chunk).exports_to.contains("default"));
}
