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
