//! ChunkEmitCache — chunk-level emit byte stream cache for incremental rebuild.
//!
//! RFC_EMIT_INCREMENTAL (PR-C). Key = (chunk_id, modules_hash). Value = emit bytes.
//! 변경 모듈이 속한 chunk 만 dirty marking → 다른 chunk 의 emit 자체 skip.
//!
//! **Sub-PR-C.1 — API skeleton 만 (호출자 없음, 영향 0).** Sub-PR-C.2 가 emitter wire-up.
//!
//! 사용 패턴 (예시):
//! ```
//! const key = ChunkEmitCache.Key{
//!     .chunk_id = chunk.id_hash,
//!     .modules_hash = ChunkEmitCache.computeModulesHash(chunk.module_infos),
//! };
//! if (cache.tryHit(key)) |hit| {
//!     // chunk 전체 emit skip — hit.bytes 그대로 사용
//! } else {
//!     // 기존 emit path → 결과 byte stream 을 cache.put(key, bytes, sourcemap_bytes)
//! }
//! ```
//!
//! ownership: put 시 bytes / sourcemap_bytes 를 cache allocator 로 dupe — caller 메모리는
//! 그대로 유지 가능. tryHit 의 반환 Entry 는 cache 내부 메모리 borrow (다음 cache 변경
//! 또는 deinit 까지만 유효).
//!
//! compiled_cache.zig 와 분리 이유: compiled_cache 는 *모듈 단위* emit 결과 (per-module
//! emit_module_pass 의 cache 키), chunk_emit_cache 는 *chunk 단위* concat 결과. 두 cache
//! 가 같이 활용되어야 emit_concat + emit_module_pass 둘 다 short-circuit 가능.

const std = @import("std");

pub const ChunkEmitCache = struct {
    /// cache lookup key. chunk 의 안정 식별자 + 그 chunk 에 포함된 모듈들의 결합 hash.
    /// 같은 chunk_id 라도 modules_hash 가 다르면 별도 entry — 모듈 변경 시 자동 invalidate.
    pub const Key = struct {
        /// chunk 의 안정 식별자 (e.g. chunk name hash, entry idx 등 — caller 정의).
        chunk_id: u64,
        /// 이 chunk 에 포함된 모든 모듈의 path + input_hash 의 결합 hash.
        /// `computeModulesHash` 로 계산.
        modules_hash: u64,
    };

    pub const Entry = struct {
        /// chunk 의 emit byte stream. cache allocator 가 owner.
        bytes: []const u8,
        /// chunk 의 sourcemap byte stream (sourcemap 없으면 empty). cache allocator 가 owner.
        sourcemap_bytes: []const u8 = "",
    };

    /// caller 가 모듈 list → modules_hash 계산할 때 사용.
    pub const ModuleEmitInfo = struct {
        /// 모듈의 path (graph 의 module.path 와 동일 의미). hash 안정성 보장 위해 absolute.
        path: []const u8,
        /// 모듈의 input_hash (compiled_cache.computeInputHash 와 동일 값 사용 권장).
        input_hash: u64,
    };

    allocator: std.mem.Allocator,
    entries: std.AutoHashMapUnmanaged(Key, Entry) = .empty,
    /// cache hit / miss 카운터 (debug_log.compiled_cache 와 같은 라인). takeStats 가 reset.
    hits: u64 = 0,
    misses: u64 = 0,

    pub fn init(allocator: std.mem.Allocator) ChunkEmitCache {
        return .{
            .allocator = allocator,
            .entries = .empty,
        };
    }

    pub fn deinit(self: *ChunkEmitCache) void {
        self.freeAllEntries();
        self.entries.deinit(self.allocator);
    }

    fn freeAllEntries(self: *ChunkEmitCache) void {
        var it = self.entries.valueIterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.bytes);
            if (entry.sourcemap_bytes.len > 0) self.allocator.free(entry.sourcemap_bytes);
        }
    }

    /// 모든 entry 해제 + capacity 유지 (다음 빌드 재사용).
    pub fn clear(self: *ChunkEmitCache) void {
        self.freeAllEntries();
        self.entries.clearRetainingCapacity();
    }

    /// cache lookup. hit 시 entry 반환 + `hits` 증가. miss 시 null + `misses` 증가.
    /// 반환된 Entry 는 cache 내부 메모리 borrow — 다음 cache 변경 또는 deinit 까지만 유효.
    pub fn tryHit(self: *ChunkEmitCache, key: Key) ?Entry {
        if (self.entries.get(key)) |entry| {
            self.hits += 1;
            return entry;
        }
        self.misses += 1;
        return null;
    }

    /// cache 에 entry 저장. bytes / sourcemap_bytes 를 cache allocator 로 dupe — caller
    /// 메모리는 그대로 유지 가능. 같은 key 가 이미 있으면 이전 entry free 후 교체.
    /// sourcemap_bytes 가 empty (len=0) 면 dupe skip.
    pub fn put(
        self: *ChunkEmitCache,
        key: Key,
        bytes: []const u8,
        sourcemap_bytes: []const u8,
    ) !void {
        const bytes_dup = try self.allocator.dupe(u8, bytes);
        errdefer self.allocator.free(bytes_dup);
        const sm_dup: []const u8 = if (sourcemap_bytes.len > 0)
            try self.allocator.dupe(u8, sourcemap_bytes)
        else
            "";
        errdefer if (sm_dup.len > 0) self.allocator.free(sm_dup);

        const gop = try self.entries.getOrPut(self.allocator, key);
        if (gop.found_existing) {
            self.allocator.free(gop.value_ptr.bytes);
            if (gop.value_ptr.sourcemap_bytes.len > 0) {
                self.allocator.free(gop.value_ptr.sourcemap_bytes);
            }
        }
        gop.value_ptr.* = .{ .bytes = bytes_dup, .sourcemap_bytes = sm_dup };
    }

    /// 특정 entry 무효화. graph 의 모듈 추가/삭제 등 chunk membership 변경 감지 시 사용.
    pub fn invalidate(self: *ChunkEmitCache, key: Key) void {
        if (self.entries.fetchRemove(key)) |kv| {
            self.allocator.free(kv.value.bytes);
            if (kv.value.sourcemap_bytes.len > 0) self.allocator.free(kv.value.sourcemap_bytes);
        }
    }

    pub const Stats = struct { hits: u64, misses: u64, entries: u32 };

    pub fn takeStats(self: *ChunkEmitCache) Stats {
        const s: Stats = .{
            .hits = self.hits,
            .misses = self.misses,
            .entries = self.entries.count(),
        };
        self.hits = 0;
        self.misses = 0;
        return s;
    }

    /// modules list 의 path + input_hash 로 combined hash 계산. caller 가 chunk_id 와
    /// 함께 Key 구성에 사용. 순서 sensitive — 같은 modules 라도 *순서가 다르면* 다른 hash.
    /// chunk 의 모듈 list 가 deterministic 순서 (exec_index 등) 인 것이 전제.
    pub fn computeModulesHash(modules: []const ModuleEmitInfo) u64 {
        var hasher = std.hash.Wyhash.init(0);
        for (modules) |m| {
            hasher.update(m.path);
            hasher.update(std.mem.asBytes(&m.input_hash));
        }
        return hasher.final();
    }
};

// ============================================================
// Unit tests
// ============================================================

test "ChunkEmitCache: init/deinit 메모리 leak 없음" {
    var cache = ChunkEmitCache.init(std.testing.allocator);
    defer cache.deinit();
    try std.testing.expectEqual(@as(u32, 0), cache.entries.count());
    try std.testing.expectEqual(@as(u64, 0), cache.hits);
    try std.testing.expectEqual(@as(u64, 0), cache.misses);
}

test "ChunkEmitCache: put 후 tryHit hit + hits counter ++" {
    var cache = ChunkEmitCache.init(std.testing.allocator);
    defer cache.deinit();

    const key = ChunkEmitCache.Key{ .chunk_id = 1, .modules_hash = 100 };
    try cache.put(key, "(function(){console.log(1)})();", "");

    const hit = cache.tryHit(key);
    try std.testing.expect(hit != null);
    try std.testing.expectEqualStrings("(function(){console.log(1)})();", hit.?.bytes);
    try std.testing.expectEqual(@as(u64, 1), cache.hits);
    try std.testing.expectEqual(@as(u64, 0), cache.misses);
}

test "ChunkEmitCache: 다른 key tryHit → null + misses ++" {
    var cache = ChunkEmitCache.init(std.testing.allocator);
    defer cache.deinit();

    const key1 = ChunkEmitCache.Key{ .chunk_id = 1, .modules_hash = 100 };
    try cache.put(key1, "first", "");

    const key2 = ChunkEmitCache.Key{ .chunk_id = 2, .modules_hash = 100 };
    const hit = cache.tryHit(key2);
    try std.testing.expect(hit == null);
    try std.testing.expectEqual(@as(u64, 0), cache.hits);
    try std.testing.expectEqual(@as(u64, 1), cache.misses);
}

test "ChunkEmitCache: 같은 chunk_id 라도 modules_hash 다르면 miss (자동 invalidate)" {
    var cache = ChunkEmitCache.init(std.testing.allocator);
    defer cache.deinit();

    const key_v1 = ChunkEmitCache.Key{ .chunk_id = 1, .modules_hash = 100 };
    try cache.put(key_v1, "v1", "");

    // chunk_id 는 같지만 modules_hash 가 변경 (모듈 hash 갱신) → miss
    const key_v2 = ChunkEmitCache.Key{ .chunk_id = 1, .modules_hash = 200 };
    try std.testing.expect(cache.tryHit(key_v2) == null);
    try std.testing.expectEqual(@as(u64, 1), cache.misses);
}

test "ChunkEmitCache: 같은 key put 두 번 — 이전 entry 교체 (leak 없음)" {
    var cache = ChunkEmitCache.init(std.testing.allocator);
    defer cache.deinit();

    const key = ChunkEmitCache.Key{ .chunk_id = 1, .modules_hash = 100 };
    try cache.put(key, "v1", "");
    try cache.put(key, "v2_longer_content", "sm_data");

    const hit = cache.tryHit(key);
    try std.testing.expect(hit != null);
    try std.testing.expectEqualStrings("v2_longer_content", hit.?.bytes);
    try std.testing.expectEqualStrings("sm_data", hit.?.sourcemap_bytes);
    try std.testing.expectEqual(@as(u32, 1), cache.entries.count());
}

test "ChunkEmitCache: clear 후 entries 비어있음 + capacity 유지" {
    var cache = ChunkEmitCache.init(std.testing.allocator);
    defer cache.deinit();

    const key = ChunkEmitCache.Key{ .chunk_id = 1, .modules_hash = 100 };
    try cache.put(key, "data", "");
    try std.testing.expectEqual(@as(u32, 1), cache.entries.count());

    cache.clear();
    try std.testing.expectEqual(@as(u32, 0), cache.entries.count());
    try std.testing.expect(cache.tryHit(key) == null);
}

test "ChunkEmitCache: invalidate(key) — 특정 entry 만 제거" {
    var cache = ChunkEmitCache.init(std.testing.allocator);
    defer cache.deinit();

    const key1 = ChunkEmitCache.Key{ .chunk_id = 1, .modules_hash = 100 };
    const key2 = ChunkEmitCache.Key{ .chunk_id = 2, .modules_hash = 200 };
    try cache.put(key1, "v1", "");
    try cache.put(key2, "v2", "");

    cache.invalidate(key1);
    try std.testing.expect(cache.tryHit(key1) == null);
    try std.testing.expect(cache.tryHit(key2) != null);
}

test "ChunkEmitCache: takeStats — counter reset" {
    var cache = ChunkEmitCache.init(std.testing.allocator);
    defer cache.deinit();

    const key = ChunkEmitCache.Key{ .chunk_id = 1, .modules_hash = 100 };
    try cache.put(key, "data", "");
    _ = cache.tryHit(key);
    _ = cache.tryHit(.{ .chunk_id = 9, .modules_hash = 9 });

    const s1 = cache.takeStats();
    try std.testing.expectEqual(@as(u64, 1), s1.hits);
    try std.testing.expectEqual(@as(u64, 1), s1.misses);
    try std.testing.expectEqual(@as(u32, 1), s1.entries);

    // 두 번째 takeStats — counter reset 후
    const s2 = cache.takeStats();
    try std.testing.expectEqual(@as(u64, 0), s2.hits);
    try std.testing.expectEqual(@as(u64, 0), s2.misses);
    try std.testing.expectEqual(@as(u32, 1), s2.entries);
}

test "ChunkEmitCache.computeModulesHash: 같은 modules → 같은 hash, 다른 input_hash → 다른 hash" {
    const m1 = [_]ChunkEmitCache.ModuleEmitInfo{
        .{ .path = "/a.ts", .input_hash = 1 },
        .{ .path = "/b.ts", .input_hash = 2 },
    };
    const m2 = [_]ChunkEmitCache.ModuleEmitInfo{
        .{ .path = "/a.ts", .input_hash = 1 },
        .{ .path = "/b.ts", .input_hash = 2 },
    };
    const m3 = [_]ChunkEmitCache.ModuleEmitInfo{
        .{ .path = "/a.ts", .input_hash = 1 },
        .{ .path = "/b.ts", .input_hash = 999 },
    };

    try std.testing.expectEqual(
        ChunkEmitCache.computeModulesHash(&m1),
        ChunkEmitCache.computeModulesHash(&m2),
    );
    try std.testing.expect(
        ChunkEmitCache.computeModulesHash(&m1) != ChunkEmitCache.computeModulesHash(&m3),
    );
}

test "ChunkEmitCache.computeModulesHash: 순서 sensitive" {
    const m_ab = [_]ChunkEmitCache.ModuleEmitInfo{
        .{ .path = "/a.ts", .input_hash = 1 },
        .{ .path = "/b.ts", .input_hash = 2 },
    };
    const m_ba = [_]ChunkEmitCache.ModuleEmitInfo{
        .{ .path = "/b.ts", .input_hash = 2 },
        .{ .path = "/a.ts", .input_hash = 1 },
    };
    try std.testing.expect(
        ChunkEmitCache.computeModulesHash(&m_ab) != ChunkEmitCache.computeModulesHash(&m_ba),
    );
}

test "ChunkEmitCache: empty sourcemap_bytes — alloc/free skip" {
    var cache = ChunkEmitCache.init(std.testing.allocator);
    defer cache.deinit();

    const key = ChunkEmitCache.Key{ .chunk_id = 1, .modules_hash = 100 };
    try cache.put(key, "code", ""); // sourcemap empty

    const hit = cache.tryHit(key);
    try std.testing.expect(hit != null);
    try std.testing.expectEqualStrings("", hit.?.sourcemap_bytes);

    // overwrite 시 empty sm 정상 처리
    try cache.put(key, "code2", "");
    try std.testing.expectEqualStrings("code2", cache.tryHit(key).?.bytes);
}
