//! Bundler Alias Table — cross-module re-export chain layer.
//!
//! Semantic은 단일 모듈의 선언/스코프 분석 + bundler 합성 심볼(_default,
//! init_X, exports_X)을 담당한다 (#1338 Phase 4e-2b/2c). 이 파일은 그 위에
//! cross-module re-export chain(`export { X } from './m'`)의 alias만 별도로
//! 관리한다. Alias는 "선언"이 아니라 "다른 모듈 심볼로의 redirect"라
//! semantic 공간에 얹지 않는다 (RFC #1338 결정).
//!
//! 규약(R1):
//!   consumer는 반드시 getter/setter 함수만 사용. 내부 필드(`aliases`)
//!   직접 접근 금지. 내부 레이아웃(AoS/SoA)을 무손실로 교체하기 위한 캡슐화.

const std = @import("std");
const Span = @import("../lexer/token.zig").Span;
const types = @import("types.zig");
const semantic_symbol = @import("../semantic/symbol.zig");

pub const ModuleIndex = types.ModuleIndex;
pub const SemanticSymbolId = semantic_symbol.SymbolId;

/// Bundler alias id. 모듈-로컬 고유.
pub const AliasId = enum(u32) {
    none = std.math.maxInt(u32),
    _,

    pub fn isNone(self: AliasId) bool {
        return self == .none;
    }
};

/// Cross-module 심볼 참조. semantic 선언/합성 vs re-export alias 공간을 구분.
pub const SymbolRef = union(enum) {
    /// semantic이 소유한 선언/합성 심볼
    semantic: struct { module: ModuleIndex, symbol: SemanticSymbolId },
    /// Cross-module re-export alias (값 없는 redirect)
    alias: struct { module: ModuleIndex, symbol: AliasId },

    pub const invalid: SymbolRef = .{ .alias = .{ .module = .none, .symbol = .none } };

    /// `.semantic` 변형 생성. `sym_idx`는 usize/u32 모두 허용 (intCast).
    pub fn makeSemantic(module: ModuleIndex, sym_idx: anytype) SymbolRef {
        return .{ .semantic = .{
            .module = module,
            .symbol = @enumFromInt(@as(u32, @intCast(sym_idx))),
        } };
    }

    pub fn isValid(self: SymbolRef) bool {
        return switch (self) {
            .semantic => |s| !s.module.isNone() and !s.symbol.isNone(),
            .alias => |a| !a.module.isNone() and !a.symbol.isNone(),
        };
    }

    pub fn moduleIndex(self: SymbolRef) ModuleIndex {
        return switch (self) {
            .semantic => |s| s.module,
            .alias => |a| a.module,
        };
    }

    /// `.semantic`이면 SymbolId를 u32로 반환. `.alias`나 invalid면 null.
    /// `if (ref == .semantic) @intFromEnum(ref.semantic.symbol)` 반복 패턴 단축.
    pub fn semanticIndex(self: SymbolRef) ?u32 {
        return switch (self) {
            .semantic => |s| if (s.symbol.isNone()) null else @intFromEnum(s.symbol),
            .alias => null,
        };
    }

    pub fn eql(x: SymbolRef, y: SymbolRef) bool {
        return switch (x) {
            .semantic => |xs| switch (y) {
                .semantic => |ys| xs.module == ys.module and xs.symbol == ys.symbol,
                .alias => false,
            },
            .alias => |xa| switch (y) {
                .alias => |ya| xa.module == ya.module and xa.symbol == ya.symbol,
                .semantic => false,
            },
        };
    }
};

/// Build-scope 심볼 식별자 — esbuild SymbolID 패턴 (RFC #3940 Sub-PR-L.2).
///
/// `(module, inner)` integer pair 로 semantic 선언/합성 심볼을 식별한다. per-build
/// `RenameTable: SymbolID → name` 의 키. 과거 `Symbol.canonical_name` (build-scope Linker 가
/// alloc → graph-scope Symbol 에 저장 = cross-build dangling) 을 대체해 rename 을 build-scope
/// 로 외부화한 정수 식별자 (RFC #3940 L.5c 에서 field 제거 완료).
///
/// **build-local 식별자 주의**: `module` 은 `ModuleIndex` 라 *단일 build 내에서만* 안정하다
/// (`graph/renumber.zig` 가 모듈 추가/삭제 시 BFS 로 index 재배정). RenameTable 은 build-scope
/// 라 build-local 키로 충분하다. cross-build 로 살아남는 graph identity (Sub-PR-L.6 graph
/// persistence) 가 필요하면 `module_id.zig` 의 path-stable id 와 조합해야 한다 (audit §5.2).
///
/// alias (`SymbolRef.alias`) 는 semantic 과 별도 공간이라 SymbolID 가 표현하지 않는다
/// (esbuild parity). alias rename 의 build-scope 외부화는 Sub-PR-L.5 에서 별도 처리.
///
/// packed struct (64 bits, 두 enum(u32)) — `std.AutoHashMap(SymbolID, …)` 키로 직접 사용 가능.
pub const SymbolID = packed struct {
    module: ModuleIndex,
    inner: SemanticSymbolId,

    /// invalid sentinel — module/inner 둘 다 none.
    pub const invalid: SymbolID = .{ .module = .none, .inner = .none };

    /// `(module, sym_idx)` 로 생성. `sym_idx` 는 usize/u32 모두 허용 (intCast).
    pub fn make(module: ModuleIndex, sym_idx: anytype) SymbolID {
        return .{
            .module = module,
            .inner = @enumFromInt(@as(u32, @intCast(sym_idx))),
        };
    }

    /// `SymbolRef` 에서 변환. `.semantic` variant 만 SymbolID 로 매핑되고,
    /// `.alias` / invalid 는 null (alias 는 SymbolID 공간 밖).
    pub fn fromRef(ref: SymbolRef) ?SymbolID {
        return switch (ref) {
            .semantic => |s| if (s.module.isNone() or s.symbol.isNone())
                null
            else
                .{ .module = s.module, .inner = s.symbol },
            .alias => null,
        };
    }

    /// `SymbolRef.semantic` 으로 환원.
    pub fn toRef(self: SymbolID) SymbolRef {
        return .{ .semantic = .{ .module = self.module, .symbol = self.inner } };
    }

    pub fn isValid(self: SymbolID) bool {
        return !self.module.isNone() and !self.inner.isNone();
    }

    pub fn eql(a: SymbolID, b: SymbolID) bool {
        return a.module == b.module and a.inner == b.inner;
    }
};

/// Build-scope per-build rename table — `SymbolID → 최종 이름` (RFC #3940).
///
/// esbuild 패턴: symbol identity (integer `SymbolID`) 와 rename 결과 (string) 를 분리한다.
/// 과거 `Symbol.canonical_name` (build-scope `Linker` 가 alloc → graph-scope `Symbol` 에
/// 저장 = cross-build dangling, RFC #3933 segfault root) 을 대체한 build-scope rename store.
/// `Linker.assignSymbolCanonical` (canonical write 단일 sink) 가 여기에 기록하고, emit/facade/
/// dedup read 가 이 테이블을 조회한다. L.5c 에서 `Symbol.canonical_name` field 제거 완료 →
/// 유일 출처.
///
/// **carry-over**: AST mutation 후 semantic resync (`graph/transform_prepass.zig`) 가 symbol idx
/// 를 재배정하면 `module.pending_renames` 에 모았다가 `Linker.applyPendingRenames` 가 반영한다.
///
/// **값 string 은 borrow**: `Linker.canonical_strings` 가 value 를 소유하고 RenameTable 은 같은
/// slice 를 가리키기만 한다 (free 안 함).
///
/// **build-scope**: `Linker` lifetime. `clearCanonicalNames` (per-chunk/per-build reset) 시
/// 함께 clear.
pub const RenameTable = struct {
    map: std.AutoHashMapUnmanaged(SymbolID, []const u8) = .empty,

    pub fn deinit(self: *RenameTable, allocator: std.mem.Allocator) void {
        self.map.deinit(allocator);
    }

    /// `SymbolID → name` 등록 (덮어쓰기). `name` 은 borrow (caller/canonical_strings 소유).
    pub fn put(self: *RenameTable, allocator: std.mem.Allocator, id: SymbolID, name: []const u8) !void {
        try self.map.put(allocator, id, name);
    }

    pub fn get(self: *const RenameTable, id: SymbolID) ?[]const u8 {
        return self.map.get(id);
    }

    pub fn count(self: *const RenameTable) u32 {
        return self.map.count();
    }

    /// 모든 entry 제거 (capacity 유지). per-chunk / per-build reset.
    pub fn clear(self: *RenameTable) void {
        self.map.clearRetainingCapacity();
    }

    /// 특정 module 의 모든 entry 제거 (RFC #3940 L.5a — carry-over apply 시 mutated module 의
    /// resync-전 stale idx entry 를 비워 pending 으로 완전 재선언. iterator invalidation 회피 위해
    /// key 수집 후 제거). `scratch` 는 build-scope 임시 allocator.
    pub fn removeModule(self: *RenameTable, scratch: std.mem.Allocator, module: ModuleIndex) !void {
        var keys: std.ArrayListUnmanaged(SymbolID) = .empty;
        defer keys.deinit(scratch);
        var it = self.map.iterator();
        while (it.next()) |e| {
            if (e.key_ptr.module == module) try keys.append(scratch, e.key_ptr.*);
        }
        for (keys.items) |k| _ = self.map.remove(k);
    }
};

/// HMR rename 보존 스냅샷 (perf/hmr-link-rename-reuse).
///
/// **문제**: HMR rebuild 는 매번 `Linker` 를 새로 만들고 `computeRenames`(전체 모듈
/// top-level 이름 deconflict, RN 8067 모듈에서 ~106ms)를 재계산한다. 그러나 body-only
/// 수정 (HMR 절대다수) 에서는 모든 모듈의 top-level 이름 집합이 불변이라 deconflict
/// 결과 (rename_table) 도 byte-identical 하다. → 초기 빌드의 결과를 owned 스냅샷으로
/// 보존했다가 다음 rebuild 에서 가드 통과 시 재주입하고 computeRenames 를 skip.
///
/// **소유권 (RFC #3933 dangling 클래스 회피)**: 스냅샷 안의 모든 문자열 (rename name,
/// reserved global, fingerprint path) 은 `arena` 가 dupe 해 소유한다. `Linker` 의
/// `canonical_strings` 에서 borrow 하면 Linker.deinit 후 dangling 이 되므로 **금지**.
/// `arena.deinit()` 한 번이 일괄 해제 (CLAUDE.md 메모리 규약).
///
/// **fingerprint**: 재사용 안전성 가드(G0~G4)의 비교 기준. 초기 빌드 시점의 그래프
/// 형태(모듈 수/순서/이름집합/전역참조)를 per-index 로 박제한다. rebuild 시 현재
/// 그래프와 대조해 "이름 deconflict 결과가 바뀔 수 있는 변화"가 있었는지 판정한다.
pub const PreservedRenames = struct {
    /// 스냅샷 전용 arena — 모든 owned 문자열의 backing. `deinit` 이 일괄 해제.
    arena: std.heap.ArenaAllocator,

    /// 보존된 rename_table 엔트리. `SymbolID → owned name`. inner idx 는 *초기 빌드*
    /// 의 module-local 인덱스라, 재파싱된 모듈은 idx 가 흔들릴 수 있어 inject 시
    /// 이름으로 재유도(G3)한다. 변경 안 된 모듈은 idx 가 그대로라 직접 재키잉.
    entries: []Entry,

    /// 보존된 `reserved_globals` 키 집합 (owned). inject 시 Linker.reserved_globals 복원.
    /// `computeRenames` 의 `collectReservedGlobals` 를 skip 하므로 직접 복원해야 한다.
    reserved_globals: []const []const u8,

    /// per-index fingerprint. 인덱스 = ModuleIndex 정수. 가드가 현재 그래프와 대조.
    fingerprint: []const ModuleFingerprint,

    /// 초기 빌드 모듈 수. 가드 G0 (모듈 추가/삭제) 1차 비교.
    module_count: u32,

    pub const Entry = struct {
        /// 초기 빌드 시점의 SymbolID (module, inner). inner 는 by-name 재유도 전 키.
        id: SymbolID,
        /// 초기 빌드 시점의 module-local 이름 (재유도용 lookup 키, owned).
        local_name: []const u8,
        /// 최종 rename 결과 (owned).
        canonical: []const u8,
    };

    /// 모듈 단위 fingerprint. 가드가 "이 모듈의 rename 결과에 영향을 주는 입력"이
    /// 초기 빌드와 같은지 1-pass 로 판정한다.
    pub const ModuleFingerprint = struct {
        /// 경로 해시 (G0/G1 — 모듈 동일성). path 문자열 자체는 보관 안 함(해시로 충분).
        path_hash: u64,
        /// 실행 순서 (G1 — deconflict 는 exec_index 오름차순 tie-break 라 순서 변경 = 결과 변경).
        exec_index: u32,
        /// top-level owner 이름 집합의 order-independent 해시 (G2 — body-only edit 불변).
        toplevel_name_set_hash: u64,
        /// unresolved_references 집합의 order-independent 해시 (G4 — 새 전역참조 = reserved 변화).
        unresolved_refs_hash: u64,
        /// nested-scope binding(scope_maps[1..]) 이름 집합의 order-independent 해시.
        /// G5 — `resolveNestedShadowConflicts`/`hasNestedBinding` 가 보는 shadow 입력.
        /// body edit 으로 nested binding *이름* 이 추가/변경되면 import target rename 이
        /// 달라질 수 있는데 toplevel 해시는 이를 못 잡는다(scope_maps[0] 만 봄).
        nested_name_set_hash: u64,
        /// import binding local_name 집합의 order-independent 해시 + wrap_kind.
        /// G6 — nested shadow 비교의 다른 한쪽(import local name)과 wrap synthetic
        /// landscape(ESM↔CJS wrap flip 시 init_/exports_/require_ 이름 변동) 변화 감지.
        import_locals_wrap_hash: u64,
    };

    pub fn deinit(self: *PreservedRenames) void {
        self.arena.deinit();
    }
};

/// Re-export alias 레코드.
/// `name`은 exported_name(barrel 기준). `canonical_name`은 체인 resolve 후
/// linker가 주입한 최종 참조 이름. `ref_count`는 symbol-level tree-shaking 용.
pub const Alias = struct {
    name: []const u8,
    canonical_name: []const u8 = "",
    ref_count: u32 = 0,
};

/// 모듈별 re-export alias 저장소.
pub const AliasTable = struct {
    aliases: std.ArrayList(Alias),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) AliasTable {
        return .{ .aliases = .empty, .allocator = allocator };
    }

    pub fn deinit(self: *AliasTable) void {
        self.aliases.deinit(self.allocator);
    }

    /// Alias 등록. 같은 exported_name이 여러 export 문에서 나올 수 있으므로 항상 new id.
    pub fn declare(self: *AliasTable, name: []const u8) !AliasId {
        const id: AliasId = @enumFromInt(@as(u32, @intCast(self.aliases.items.len)));
        try self.aliases.append(self.allocator, .{ .name = name });
        return id;
    }

    pub fn setCanonicalName(self: *AliasTable, id: AliasId, name: []const u8) void {
        self.aliases.items[@intFromEnum(id)].canonical_name = name;
    }

    pub fn incRefCount(self: *AliasTable, id: AliasId) void {
        self.aliases.items[@intFromEnum(id)].ref_count += 1;
    }

    pub fn count(self: *const AliasTable) u32 {
        return @intCast(self.aliases.items.len);
    }

    pub fn getName(self: *const AliasTable, id: AliasId) []const u8 {
        return self.aliases.items[@intFromEnum(id)].name;
    }

    /// canonical_name이 비어있으면 원본 name 반환.
    pub fn getCanonicalName(self: *const AliasTable, id: AliasId) []const u8 {
        const a = &self.aliases.items[@intFromEnum(id)];
        return if (a.canonical_name.len > 0) a.canonical_name else a.name;
    }

    /// `setCanonicalName`이 호출된 적 있는지 — 체인 resolve 완료 판정.
    pub fn hasCanonicalName(self: *const AliasTable, id: AliasId) bool {
        return self.aliases.items[@intFromEnum(id)].canonical_name.len > 0;
    }

    pub fn getRefCount(self: *const AliasTable, id: AliasId) u32 {
        return self.aliases.items[@intFromEnum(id)].ref_count;
    }
};

// ── tests ─────────────────────────────────────────────────────

test "AliasTable: declare + get 기본" {
    var t = AliasTable.init(std.testing.allocator);
    defer t.deinit();

    const id = try t.declare("Foo");
    try std.testing.expectEqualStrings("Foo", t.getName(id));
    try std.testing.expectEqual(@as(u32, 1), t.count());
}

test "AliasTable: canonical_name fallback" {
    var t = AliasTable.init(std.testing.allocator);
    defer t.deinit();

    const id = try t.declare("Foo");
    try std.testing.expectEqualStrings("Foo", t.getCanonicalName(id));
    try std.testing.expect(!t.hasCanonicalName(id));
    t.setCanonicalName(id, "Foo$2");
    try std.testing.expectEqualStrings("Foo$2", t.getCanonicalName(id));
    try std.testing.expect(t.hasCanonicalName(id));
}

test "AliasTable: ref_count" {
    var t = AliasTable.init(std.testing.allocator);
    defer t.deinit();

    const id = try t.declare("Foo");
    try std.testing.expectEqual(@as(u32, 0), t.getRefCount(id));
    t.incRefCount(id);
    t.incRefCount(id);
    try std.testing.expectEqual(@as(u32, 2), t.getRefCount(id));
}

test "SymbolRef: semantic vs alias 공간 구분" {
    const sem: SymbolRef = .{ .semantic = .{
        .module = @enumFromInt(1),
        .symbol = @enumFromInt(2),
    } };
    const bnd: SymbolRef = .{ .alias = .{
        .module = @enumFromInt(1),
        .symbol = @enumFromInt(2),
    } };
    try std.testing.expect(!sem.eql(bnd));
    try std.testing.expect(sem.eql(sem));
    try std.testing.expect(!SymbolRef.invalid.isValid());
}

test "SymbolID: make + toRef roundtrip" {
    const id = SymbolID.make(@as(ModuleIndex, @enumFromInt(3)), 7);
    try std.testing.expectEqual(@as(ModuleIndex, @enumFromInt(3)), id.module);
    try std.testing.expectEqual(@as(SemanticSymbolId, @enumFromInt(7)), id.inner);
    try std.testing.expect(id.isValid());

    const ref = id.toRef();
    const back = SymbolID.fromRef(ref).?;
    try std.testing.expect(id.eql(back));
}

test "SymbolID: fromRef — semantic 만 매핑, alias/invalid 는 null" {
    const sem: SymbolRef = .{ .semantic = .{ .module = @enumFromInt(1), .symbol = @enumFromInt(2) } };
    const got = SymbolID.fromRef(sem).?;
    try std.testing.expectEqual(@as(ModuleIndex, @enumFromInt(1)), got.module);
    try std.testing.expectEqual(@as(SemanticSymbolId, @enumFromInt(2)), got.inner);

    const alias: SymbolRef = .{ .alias = .{ .module = @enumFromInt(1), .symbol = @enumFromInt(2) } };
    try std.testing.expectEqual(@as(?SymbolID, null), SymbolID.fromRef(alias));

    // semantic 이지만 none sentinel → invalid → null
    const none_mod: SymbolRef = .{ .semantic = .{ .module = .none, .symbol = @enumFromInt(2) } };
    try std.testing.expectEqual(@as(?SymbolID, null), SymbolID.fromRef(none_mod));
    const none_sym: SymbolRef = .{ .semantic = .{ .module = @enumFromInt(1), .symbol = .none } };
    try std.testing.expectEqual(@as(?SymbolID, null), SymbolID.fromRef(none_sym));
}

test "SymbolID: isValid + invalid sentinel" {
    try std.testing.expect(!SymbolID.invalid.isValid());
    try std.testing.expect(SymbolID.make(@as(ModuleIndex, @enumFromInt(0)), 0).isValid());
}

test "SymbolID: AutoHashMap 키로 사용 (RenameTable 기반)" {
    var map = std.AutoHashMap(SymbolID, []const u8).init(std.testing.allocator);
    defer map.deinit();

    const a = SymbolID.make(@as(ModuleIndex, @enumFromInt(1)), 10);
    const b = SymbolID.make(@as(ModuleIndex, @enumFromInt(1)), 11);
    const c = SymbolID.make(@as(ModuleIndex, @enumFromInt(2)), 10);

    try map.put(a, "a$1");
    try map.put(b, "b$2");
    try map.put(c, "c$3");

    try std.testing.expectEqualStrings("a$1", map.get(a).?);
    try std.testing.expectEqualStrings("b$2", map.get(b).?);
    try std.testing.expectEqualStrings("c$3", map.get(c).?);
    // 같은 module 다른 inner, 다른 module 같은 inner 모두 구분
    try std.testing.expectEqual(@as(u32, 3), map.count());
    // 동일 키 재조회 (eql 동작)
    try std.testing.expectEqualStrings("a$1", map.get(SymbolID.make(@as(ModuleIndex, @enumFromInt(1)), 10)).?);
}

test "RenameTable: put/get/count/clear + 덮어쓰기" {
    var rt: RenameTable = .{};
    defer rt.deinit(std.testing.allocator);

    const a = SymbolID.make(@as(ModuleIndex, @enumFromInt(0)), 1);
    const b = SymbolID.make(@as(ModuleIndex, @enumFromInt(0)), 2);

    try std.testing.expectEqual(@as(?[]const u8, null), rt.get(a));
    try rt.put(std.testing.allocator, a, "a$1");
    try rt.put(std.testing.allocator, b, "b$1");
    try std.testing.expectEqual(@as(u32, 2), rt.count());
    try std.testing.expectEqualStrings("a$1", rt.get(a).?);
    try std.testing.expectEqualStrings("b$1", rt.get(b).?);

    // 같은 SymbolID 재할당 → 덮어쓰기 (assignSymbolCanonical 의 had_prior 경로 모사)
    try rt.put(std.testing.allocator, a, "a$2");
    try std.testing.expectEqual(@as(u32, 2), rt.count());
    try std.testing.expectEqualStrings("a$2", rt.get(a).?);

    rt.clear();
    try std.testing.expectEqual(@as(u32, 0), rt.count());
    try std.testing.expectEqual(@as(?[]const u8, null), rt.get(a));
    // clear 후 재사용 가능 (capacity 유지)
    try rt.put(std.testing.allocator, b, "b$2");
    try std.testing.expectEqualStrings("b$2", rt.get(b).?);
}
