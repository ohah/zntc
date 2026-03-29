//! ZTS Bundler — Chunk / ChunkGraph
//!
//! Code splitting의 기본 자료구조: BitSet, Chunk, ChunkGraph.
//!
//! 각 진입점(entry point)마다 하나의 비트를 할당하고,
//! 모듈이 어떤 진입점들에서 도달 가능한지를 BitSet으로 추적한다.
//! 동일한 BitSet을 가진 모듈들은 같은 Chunk로 묶인다.
//!
//! 설계:
//!   - esbuild/Rolldown 방식: 진입점 비트 마스크로 청크 분할
//!   - BitSet: 값 타입, HashMap 키로 사용 가능 (hash/eql 구현)
//!   - ChunkGraph: 청크 목록 + 모듈→청크 매핑
//!
//! 참고:
//!   - references/esbuild/pkg/api/api_impl.go (computeChunks)
//!   - references/rolldown/crates/rolldown/src/chunk_graph/

const std = @import("std");
const types = @import("types.zig");
const ModuleIndex = types.ModuleIndex;
pub const ChunkIndex = types.ChunkIndex;
const Module = @import("module.zig").Module;
const TreeShaker = @import("tree_shaker.zig").TreeShaker;
const Linker = @import("linker.zig").Linker;

// ============================================================
// BitSet — 진입점 비트 마스크
// ============================================================

/// 고정 크기 비트 집합. 진입점 도달 가능성을 추적하는 데 사용.
/// `[]u8` 기반 — `std.DynamicBitSet`(`[]usize`)와 달리 hash/eql이 바이트 단위로 동작하여
/// 엔디안/패딩 영향 없이 HashMap 키로 안전하게 사용 가능.
pub const BitSet = struct {
    entries: []u8,

    /// max_bits 크기의 빈 BitSet을 생성한다.
    pub fn init(allocator: std.mem.Allocator, max_bits: u32) !BitSet {
        const byte_count = (max_bits + 7) / 8;
        const entries = try allocator.alloc(u8, byte_count);
        @memset(entries, 0);
        return .{ .entries = entries };
    }

    /// 메모리를 해제한다.
    pub fn deinit(self: *BitSet, allocator: std.mem.Allocator) void {
        allocator.free(self.entries);
        self.entries = &.{};
    }

    /// 독립적인 복사본을 만든다.
    pub fn clone(self: BitSet, allocator: std.mem.Allocator) !BitSet {
        return .{ .entries = try allocator.dupe(u8, self.entries) };
    }

    /// 특정 비트가 설정되어 있는지 확인한다.
    pub fn hasBit(self: BitSet, bit: u32) bool {
        const byte_idx = bit / 8;
        if (byte_idx >= self.entries.len) return false;
        return (self.entries[byte_idx] & (@as(u8, 1) << @intCast(bit % 8))) != 0;
    }

    /// 특정 비트를 설정한다.
    pub fn setBit(self: *BitSet, bit: u32) void {
        const byte_idx = bit / 8;
        if (byte_idx >= self.entries.len) return;
        self.entries[byte_idx] |= @as(u8, 1) << @intCast(bit % 8);
    }

    /// 특정 비트를 해제한다.
    pub fn clearBit(self: *BitSet, bit: u32) void {
        const byte_idx = bit / 8;
        if (byte_idx >= self.entries.len) return;
        self.entries[byte_idx] &= ~(@as(u8, 1) << @intCast(bit % 8));
    }

    /// 설정된 비트의 개수를 반환한다.
    pub fn bitCount(self: BitSet) u32 {
        var count: u32 = 0;
        for (self.entries) |byte| {
            count += @popCount(byte);
        }
        return count;
    }

    /// 설정된 비트가 하나도 없는지 확인한다.
    pub fn isEmpty(self: BitSet) bool {
        for (self.entries) |byte| {
            if (byte != 0) return false;
        }
        return true;
    }

    /// other의 비트를 self에 합집합(OR)한다.
    pub fn setUnion(self: *BitSet, other: BitSet) void {
        const len = @min(self.entries.len, other.entries.len);
        for (self.entries[0..len], other.entries[0..len]) |*a, b| {
            a.* |= b;
        }
    }

    /// 두 BitSet이 동일한지 비교한다. 같은 max_bits로 생성된 BitSet끼리 비교해야 정확.
    pub fn eql(self: BitSet, other: BitSet) bool {
        return std.mem.eql(u8, self.entries, other.entries);
    }

    /// 해시값을 계산한다 (HashMap 키로 사용).
    pub fn hash(self: BitSet) u64 {
        return std.hash.Wyhash.hash(0, self.entries);
    }
};

/// BitSet을 HashMap 키로 사용하기 위한 컨텍스트.
pub const BitSetContext = struct {
    pub fn hash(_: BitSetContext, key: BitSet) u64 {
        return key.hash();
    }
    pub fn eql(_: BitSetContext, a: BitSet, b: BitSet) bool {
        return a.eql(b);
    }
};

// ============================================================
// ChunkKind — 청크 종류
// ============================================================

/// 청크의 종류: 진입점(entry_point) 또는 공통 모듈(common).
pub const ChunkKind = union(enum) {
    /// 진입점에서 생성된 청크
    entry_point: struct {
        /// 이 진입점의 비트 인덱스 (BitSet에서의 위치)
        bit: u32,
        /// 진입점 모듈의 인덱스
        module: ModuleIndex,
        /// 동적 import로 생성된 진입점인지 여부
        is_dynamic: bool,
    },
    /// 여러 진입점이 공유하는 공통 청크
    common,
};

// ============================================================
// Chunk — 단일 청크
// ============================================================

/// 번들 출력의 단위. 하나의 JS 파일로 출력된다.
/// 동일한 BitSet(진입점 집합)을 가진 모듈들이 하나의 Chunk에 묶인다.
pub const Chunk = struct {
    /// 청크 그래프에서의 인덱스
    index: ChunkIndex,
    /// 청크 종류 (진입점 / 공통)
    kind: ChunkKind,
    /// 어떤 진입점들에서 도달 가능한지 (비트 마스크)
    bits: BitSet,
    /// 이 청크에 포함된 모듈 목록
    modules: std.ArrayListUnmanaged(ModuleIndex),
    /// 출력 파일명 (stem, 예: "index"). 빌림 — deinit에서 해제하지 않음.
    name: ?[]const u8,
    /// 최종 출력 경로 (예: "dist/index-abc123.js"). 빌림 — deinit에서 해제하지 않음.
    filename: ?[]const u8,
    /// 실행 순서 (exec_index 기준 정렬에 사용)
    exec_order: u32,

    // Cross-chunk linking
    /// 이 청크가 import하는 다른 청크 목록
    cross_chunk_imports: std.ArrayListUnmanaged(ChunkIndex),
    /// 이 청크가 동적 import하는 다른 청크 목록
    cross_chunk_dynamic_imports: std.ArrayListUnmanaged(ChunkIndex),

    /// 심볼 수준 크로스 청크 import: source_chunk_index → 가져올 심볼 이름 목록.
    /// computeCrossChunkLinks에서 linker가 있을 때만 채워진다.
    imports_from: std.AutoHashMapUnmanaged(u32, std.ArrayListUnmanaged([]const u8)),
    /// 이 청크에서 다른 청크로 내보내는 심볼 이름 집합.
    /// 공통 청크에서 export 문을 생성할 때 사용.
    exports_to: std.StringHashMapUnmanaged(void),

    /// 기본값으로 Chunk를 생성한다.
    pub fn init(index: ChunkIndex, kind: ChunkKind, bits: BitSet) Chunk {
        return .{
            .index = index,
            .kind = kind,
            .bits = bits,
            .modules = .empty,
            .name = null,
            .filename = null,
            .exec_order = std.math.maxInt(u32),
            .cross_chunk_imports = .empty,
            .cross_chunk_dynamic_imports = .empty,
            .imports_from = .empty,
            .exports_to = .empty,
        };
    }

    /// 메모리를 해제한다.
    pub fn deinit(self: *Chunk, allocator: std.mem.Allocator) void {
        self.bits.deinit(allocator);
        self.modules.deinit(allocator);
        self.cross_chunk_imports.deinit(allocator);
        self.cross_chunk_dynamic_imports.deinit(allocator);
        // imports_from: 각 값(ArrayListUnmanaged)도 해제
        var it = self.imports_from.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit(allocator);
        }
        self.imports_from.deinit(allocator);
        self.exports_to.deinit(allocator);
    }

    /// 청크에 모듈을 추가한다.
    pub fn addModule(self: *Chunk, allocator: std.mem.Allocator, module_idx: ModuleIndex) !void {
        try self.modules.append(allocator, module_idx);
    }

    /// 진입점 청크인지 확인한다.
    pub fn isEntryPoint(self: Chunk) bool {
        return self.kind == .entry_point;
    }
};

// ============================================================
// ChunkGraph — 청크 그래프
// ============================================================

/// 모든 청크와 모듈→청크 매핑을 관리한다.
/// code splitting 알고리즘의 결과를 저장하는 자료구조.
pub const ChunkGraph = struct {
    allocator: std.mem.Allocator,
    /// 모든 청크 목록
    chunks: std.ArrayListUnmanaged(Chunk),
    /// 모듈 인덱스 → 청크 인덱스 매핑 (고정 크기 배열)
    module_to_chunk: []ChunkIndex,

    /// module_count 크기의 빈 ChunkGraph를 생성한다.
    pub fn init(allocator: std.mem.Allocator, module_count: usize) !ChunkGraph {
        const module_to_chunk = try allocator.alloc(ChunkIndex, module_count);
        @memset(module_to_chunk, .none);
        return .{
            .allocator = allocator,
            .chunks = .empty,
            .module_to_chunk = module_to_chunk,
        };
    }

    /// 메모리를 해제한다.
    pub fn deinit(self: *ChunkGraph) void {
        for (self.chunks.items) |*chunk| {
            chunk.deinit(self.allocator);
        }
        self.chunks.deinit(self.allocator);
        self.allocator.free(self.module_to_chunk);
    }

    /// 청크를 추가하고 할당된 ChunkIndex를 반환한다.
    pub fn addChunk(self: *ChunkGraph, chunk: Chunk) !ChunkIndex {
        const idx: ChunkIndex = @enumFromInt(@as(u32, @intCast(self.chunks.items.len)));
        var c = chunk;
        c.index = idx;
        try self.chunks.append(self.allocator, c);
        return idx;
    }

    /// 읽기 전용으로 청크를 가져온다.
    pub fn getChunk(self: *const ChunkGraph, idx: ChunkIndex) *const Chunk {
        return &self.chunks.items[@intFromEnum(idx)];
    }

    /// 수정 가능한 청크를 가져온다.
    pub fn getChunkMut(self: *ChunkGraph, idx: ChunkIndex) *Chunk {
        return &self.chunks.items[@intFromEnum(idx)];
    }

    /// 모듈을 청크에 할당한다.
    pub fn assignModuleToChunk(self: *ChunkGraph, module_idx: ModuleIndex, chunk_idx: ChunkIndex) void {
        const mi = @intFromEnum(module_idx);
        if (mi < self.module_to_chunk.len) {
            self.module_to_chunk[mi] = chunk_idx;
        }
    }

    /// 모듈이 속한 청크의 인덱스를 반환한다.
    pub fn getModuleChunk(self: *const ChunkGraph, module_idx: ModuleIndex) ChunkIndex {
        const mi = @intFromEnum(module_idx);
        if (mi >= self.module_to_chunk.len) return .none;
        return self.module_to_chunk[mi];
    }

    /// 총 청크 수를 반환한다.
    pub fn chunkCount(self: *const ChunkGraph) usize {
        return self.chunks.items.len;
    }
};

// ============================================================
// generateChunks — 모듈 그래프에서 청크 생성
// ============================================================

/// 엔트리 정보. 유저 엔트리와 dynamic import 대상을 구분.
const EntryInfo = struct {
    module_idx: ModuleIndex,
    is_dynamic: bool,
};

/// 모듈 그래프에서 청크를 생성한다 (esbuild/rolldown 패턴).
///
/// Phase 1: 엔트리 초기화 — 유저 엔트리 + dynamic import 대상을 수집하고,
///          각 엔트리마다 Chunk를 생성한다.
/// Phase 2: 도달 가능성 마킹 — 각 엔트리에서 BFS로 정적 import를 따라가며
///          모듈별 BitSet에 도달 가능한 엔트리 비트를 설정한다.
/// Phase 3: 청크 할당 — 동일한 BitSet을 가진 모듈들을 같은 Chunk에 묶는다.
///          여러 엔트리에서 도달 가능한 모듈은 공통 청크(common chunk)로 분리.
///
/// shaker가 null이 아니면 tree-shaking 결과를 반영하여 미포함 모듈을 스킵한다.
pub fn generateChunks(
    allocator: std.mem.Allocator,
    modules: []const Module,
    entry_points: []const []const u8,
    shaker: ?*const TreeShaker,
) !ChunkGraph {
    // ── Phase 1: 엔트리 수집 ──
    // 유저 엔트리 (CLI 진입점) + dynamic import 대상을 모두 모은다.
    // 각각이 하나의 출력 청크가 된다.
    var entries: std.ArrayList(EntryInfo) = .empty;
    defer entries.deinit(allocator);

    // Phase 1a: 유저 엔트리 — entry_points 경로와 일치하는 모듈을 찾는다.
    for (modules, 0..) |m, i| {
        for (entry_points) |ep| {
            if (std.mem.eql(u8, m.path, ep)) {
                try entries.append(allocator, .{
                    .module_idx = @enumFromInt(@as(u32, @intCast(i))),
                    .is_dynamic = false,
                });
                break;
            }
        }
    }

    // Phase 1b: dynamic import 대상 — 이미 유저 엔트리인 모듈은 스킵.
    // dynamic import 대상은 별도의 청크 경계를 형성한다 (code splitting의 핵심).
    var dynamic_seen: std.AutoHashMap(u32, void) = .init(allocator);
    defer dynamic_seen.deinit();

    for (modules) |m| {
        for (m.dynamic_imports.items) |dyn_idx| {
            const di = @intFromEnum(dyn_idx);
            const gop = try dynamic_seen.getOrPut(di);
            if (!gop.found_existing) {
                // 이미 유저 엔트리로 등록된 모듈인지 확인
                var is_user_entry = false;
                for (entries.items) |e| {
                    if (@intFromEnum(e.module_idx) == di and !e.is_dynamic) {
                        is_user_entry = true;
                        break;
                    }
                }
                if (!is_user_entry) {
                    try entries.append(allocator, .{
                        .module_idx = dyn_idx,
                        .is_dynamic = true,
                    });
                }
            }
        }
    }

    const entry_count = entries.items.len;
    if (entry_count == 0) {
        return ChunkGraph.init(allocator, modules.len);
    }

    // ChunkGraph 생성 — 모듈→청크 매핑 배열을 module_count 크기로 할당.
    var chunk_graph = try ChunkGraph.init(allocator, modules.len);
    errdefer chunk_graph.deinit();

    // 모듈별 도달 가능성 BitSet — splitting_info[module_index]는
    // 그 모듈이 어떤 엔트리들에서 도달 가능한지를 나타낸다.
    var splitting_info = try allocator.alloc(BitSet, modules.len);
    // 안전한 초기값 — init 실패 시 defer에서 deinit 호출해도 안전
    @memset(splitting_info, .{ .entries = &.{} });
    defer {
        for (splitting_info) |*bs| bs.deinit(allocator);
        allocator.free(splitting_info);
    }
    for (splitting_info) |*bs| {
        bs.* = try BitSet.init(allocator, @intCast(entry_count));
    }

    // BitSet → ChunkIndex HashMap (Phase 3에서 O(1) 청크 lookup에 사용).
    // 주의: HashMap key의 BitSet.entries 포인터가 Chunk.bits와 동일한 메모리를 가리킴 (aliased).
    // Chunk.deinit이 []u8를 해제하므로 HashMap.deinit에서는 key를 해제하지 않음.
    // 이 HashMap은 generateChunks 내에서만 사용되고 Chunk보다 먼저 해제됨.
    var bits_to_chunk: std.HashMapUnmanaged(BitSet, ChunkIndex, BitSetContext, 80) = .empty;
    defer bits_to_chunk.deinit(allocator);

    // Phase 1c: 엔트리별 Chunk 생성
    for (entries.items, 0..) |entry, bit_idx| {
        var bits = try BitSet.init(allocator, @intCast(entry_count));
        errdefer bits.deinit(allocator);
        bits.setBit(@intCast(bit_idx));

        // 출력 파일명 = 모듈 파일명의 stem (확장자 제거)
        const name = std.fs.path.stem(std.fs.path.basename(
            modules[@intFromEnum(entry.module_idx)].path,
        ));

        var chunk = Chunk.init(.none, .{ .entry_point = .{
            .bit = @intCast(bit_idx),
            .module = entry.module_idx,
            .is_dynamic = entry.is_dynamic,
        } }, bits);
        chunk.name = name;

        const ci = try chunk_graph.addChunk(chunk);
        try bits_to_chunk.put(allocator, bits, ci);
    }

    // ── Phase 2: BFS 도달 가능성 마킹 ──
    // 각 엔트리에서 정적 import(dependencies)만 따라가며 BFS 순회.
    // dynamic import는 청크 경계이므로 따라가지 않는다.
    // 결과: splitting_info[모듈]에 도달 가능한 엔트리 비트가 설정됨.
    var queue: std.ArrayList(ModuleIndex) = .empty;
    defer queue.deinit(allocator);

    for (entries.items, 0..) |entry, bit_idx| {
        queue.clearRetainingCapacity();
        try queue.append(allocator, entry.module_idx);

        while (queue.items.len > 0) {
            const mod_idx = queue.pop() orelse break;
            const mi = @intFromEnum(mod_idx);
            if (mi >= modules.len) continue;

            // 이미 이 비트가 설정되어 있으면 스킵 (순환 참조 방지)
            if (splitting_info[mi].hasBit(@intCast(bit_idx))) continue;
            splitting_info[mi].setBit(@intCast(bit_idx));

            // 정적 의존성만 따라감 — dynamic import는 별도 엔트리이므로 BFS 경계
            for (modules[mi].dependencies.items) |dep_idx| {
                const dep_i = @intFromEnum(dep_idx);
                if (dep_i < modules.len and !splitting_info[dep_i].hasBit(@intCast(bit_idx))) {
                    try queue.append(allocator, dep_idx);
                }
            }
        }
    }

    // ── Phase 3: 모듈을 청크에 할당 ──
    // exec_index 순으로 처리하여 청크 내 모듈 순서(=ESM 실행 순서)를 보장.
    // 동일한 BitSet을 가진 모듈들은 같은 청크에 묶인다.
    // 엔트리 청크의 BitSet과 일치하지 않는 새로운 BitSet 패턴이 나오면
    // 공통 청크(common chunk)를 새로 생성한다.
    const sorted_indices = try allocator.alloc(usize, modules.len);
    defer allocator.free(sorted_indices);
    for (sorted_indices, 0..) |*idx, i| idx.* = i;
    std.mem.sort(usize, sorted_indices, modules, struct {
        fn lessThan(mods: []const Module, a: usize, b: usize) bool {
            return mods[a].exec_index < mods[b].exec_index;
        }
    }.lessThan);

    for (sorted_indices) |mi| {
        // tree-shaking: 미포함 모듈 스킵
        if (shaker) |s| {
            if (!s.isIncluded(@intCast(mi))) continue;
        }

        // JS 모듈만 청크에 할당 (JSON, CSS 등은 별도 처리)
        if (modules[mi].module_type != .javascript) continue;

        // 비트가 비어있으면 어떤 엔트리에서도 도달 불가 → 스킵
        if (splitting_info[mi].isEmpty()) continue;

        // BitSet → ChunkIndex O(1) lookup (esbuild/rolldown 패턴)
        const chunk_idx = if (bits_to_chunk.get(splitting_info[mi])) |ci| ci else blk: {
            // 새로운 BitSet 패턴 → 공통 청크 생성
            var bits = try splitting_info[mi].clone(allocator);
            errdefer bits.deinit(allocator);
            const new_chunk = Chunk.init(.none, .common, bits);
            const ci = try chunk_graph.addChunk(new_chunk);
            try bits_to_chunk.put(allocator, bits, ci);
            break :blk ci;
        };

        chunk_graph.assignModuleToChunk(
            @enumFromInt(@as(u32, @intCast(mi))),
            chunk_idx,
        );
        try chunk_graph.getChunkMut(chunk_idx).addModule(
            allocator,
            @enumFromInt(@as(u32, @intCast(mi))),
        );
    }

    // 엔트리 모듈은 반드시 자신의 엔트리 청크에 할당되어야 함.
    // Phase 3에서 공통 청크에 배정되었을 수 있으므로, 강제로 엔트리 청크로 이동.
    for (entries.items, 0..) |entry, ci| {
        const chunk_idx: ChunkIndex = @enumFromInt(@as(u32, @intCast(ci)));
        const current = chunk_graph.getModuleChunk(entry.module_idx);
        if (current.isNone()) {
            // 아직 미할당 → 엔트리 청크에 할당
            chunk_graph.assignModuleToChunk(entry.module_idx, chunk_idx);
            try chunk_graph.getChunkMut(chunk_idx).addModule(allocator, entry.module_idx);
        } else if (current != chunk_idx) {
            // 공통 청크에 잘못 배정됨 → 이전 청크에서 제거 후 엔트리 청크로 이동
            const old_chunk = chunk_graph.getChunkMut(current);
            removeModuleFromList(&old_chunk.modules, entry.module_idx);
            chunk_graph.assignModuleToChunk(entry.module_idx, chunk_idx);
            try chunk_graph.getChunkMut(chunk_idx).addModule(allocator, entry.module_idx);
        }
    }

    return chunk_graph;
}

/// ArrayListUnmanaged에서 특정 ModuleIndex를 제거한다 (순서 유지).
fn removeModuleFromList(list: *std.ArrayListUnmanaged(ModuleIndex), target: ModuleIndex) void {
    var i: usize = 0;
    while (i < list.items.len) {
        if (list.items[i] == target) {
            _ = list.orderedRemove(i);
            return; // 중복 없으므로 첫 번째만 제거
        }
        i += 1;
    }
}

// ============================================================
// computeCrossChunkLinks — 크로스 청크 의존성 계산
// ============================================================

/// 각 청크의 크로스 청크 의존성을 계산한다.
///
/// 청크 A의 모듈이 청크 B의 모듈을 정적 import하면 A.cross_chunk_imports에 B가 추가된다.
/// 청크 A의 모듈이 청크 B의 모듈을 동적 import하면 A.cross_chunk_dynamic_imports에 B가 추가된다.
/// 같은 청크 내의 의존성은 무시하고, 중복 청크 인덱스도 제거한다.
///
/// linker가 있으면 심볼 수준 크로스 청크 바인딩도 추적한다:
///   - chunk.imports_from[source_chunk] = 해당 청크에서 가져올 심볼 이름 목록
///   - source_chunk.exports_to에 해당 심볼 이름 추가
/// linker가 null이면 청크 수준 의존성만 계산 (side-effect import).
///
/// 이 함수는 generateChunks 이후에 호출한다.
pub fn computeCrossChunkLinks(
    chunk_graph: *ChunkGraph,
    modules: []const Module,
    allocator: std.mem.Allocator,
    linker: ?*const Linker,
) !void {
    // 먼저 모든 청크의 기존 데이터를 초기화 (exports_to는 다른 청크에서 기록하므로 분리)
    for (chunk_graph.chunks.items) |*chunk| {
        chunk.cross_chunk_imports.clearAndFree(allocator);
        chunk.cross_chunk_dynamic_imports.clearAndFree(allocator);
        {
            var it = chunk.imports_from.iterator();
            while (it.next()) |entry| entry.value_ptr.deinit(allocator);
            chunk.imports_from.clearAndFree(allocator);
        }
        chunk.exports_to.clearAndFree(allocator);
    }

    for (chunk_graph.chunks.items) |*chunk| {
        // 중복 방지용 해시맵
        var seen_static: std.AutoHashMapUnmanaged(u32, void) = .empty;
        defer seen_static.deinit(allocator);
        var seen_dynamic: std.AutoHashMapUnmanaged(u32, void) = .empty;
        defer seen_dynamic.deinit(allocator);

        for (chunk.modules.items) |mod_idx| {
            const mi = @intFromEnum(mod_idx);
            // 청크에 포함된 모듈은 반드시 modules 배열 내에 있어야 함
            std.debug.assert(mi < modules.len);
            const m = &modules[mi];

            // 정적 의존성 → cross_chunk_imports
            for (m.dependencies.items) |dep_idx| {
                if (dep_idx.isNone()) continue;
                const dep_chunk = chunk_graph.getModuleChunk(dep_idx);
                if (dep_chunk.isNone()) continue;
                if (dep_chunk == chunk.index) continue; // 같은 청크 → 스킵
                const dci = @intFromEnum(dep_chunk);
                const gop = try seen_static.getOrPut(allocator, dci);
                if (!gop.found_existing) {
                    try chunk.cross_chunk_imports.append(allocator, dep_chunk);
                }
            }

            // 심볼 수준 크로스 청크 바인딩 추적 (linker가 있을 때만)
            if (linker) |lnk| {
                for (m.import_bindings) |ib| {
                    // resolved binding으로 canonical 모듈을 찾는다
                    const rb = lnk.getResolvedBinding(@intCast(mi), ib.local_span) orelse continue;
                    const canonical_mi = @intFromEnum(rb.canonical.module_index);
                    if (canonical_mi >= modules.len) continue;

                    const src_chunk_idx = chunk_graph.getModuleChunk(rb.canonical.module_index);
                    if (src_chunk_idx.isNone()) continue;
                    if (src_chunk_idx == chunk.index) continue; // 같은 청크 → 스킵

                    const src_ci = @intFromEnum(src_chunk_idx);
                    const export_name = rb.canonical.export_name;

                    // imports_from에 심볼 이름 추가 (중복 방지)
                    const ifgop = try chunk.imports_from.getOrPut(allocator, src_ci);
                    if (!ifgop.found_existing) {
                        ifgop.value_ptr.* = .empty;
                    }
                    // 이미 추가된 이름인지 확인
                    var already = false;
                    for (ifgop.value_ptr.items) |existing| {
                        if (std.mem.eql(u8, existing, export_name)) {
                            already = true;
                            break;
                        }
                    }
                    if (!already) {
                        try ifgop.value_ptr.append(allocator, export_name);
                    }

                    // 소스 청크의 exports_to에 심볼 이름 추가
                    const src_chunk = &chunk_graph.chunks.items[src_ci];
                    try src_chunk.exports_to.put(allocator, export_name, {});
                }
            }

            // 동적 의존성 → cross_chunk_dynamic_imports
            for (m.dynamic_imports.items) |dyn_idx| {
                if (dyn_idx.isNone()) continue;
                const dyn_chunk = chunk_graph.getModuleChunk(dyn_idx);
                if (dyn_chunk.isNone()) continue;
                if (dyn_chunk == chunk.index) continue; // 같은 청크 → 스킵
                const dci = @intFromEnum(dyn_chunk);
                const gop = try seen_dynamic.getOrPut(allocator, dci);
                if (!gop.found_existing) {
                    try chunk.cross_chunk_dynamic_imports.append(allocator, dyn_chunk);
                }
            }
        }
    }
}
