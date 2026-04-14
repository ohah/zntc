//! Bundler Symbol Table — cross-module linking layer.
//!
//! Semantic은 단일 모듈의 선언/스코프 분석을 담당한다. 이 파일은 그 위에
//! cross-module linking(import/export 체인, 합성 심볼)을 얹는 bundler-local
//! 테이블이다. 역할 분리는 issue #1328의 "Semantic 공존 모델" 참조.
//!
//! 규약(R1):
//!   consumer는 반드시 getter/setter 함수만 사용. 내부 필드
//!   (`symbols`, `by_name` 등) 직접 접근 금지. 내부 레이아웃(AoS/SoA)
//!   을 무손실로 교체하기 위한 캡슐화.

const std = @import("std");
const Span = @import("../lexer/token.zig").Span;
const types = @import("types.zig");
const semantic_symbol = @import("../semantic/symbol.zig");

pub const ModuleIndex = types.ModuleIndex;
pub const SemanticSymbolId = semantic_symbol.SymbolId;

/// Bundler 합성 심볼 id. 모듈-로컬 고유.
/// semantic의 SymbolId와는 별개 공간 — `SymbolRef`를 통해 통합 참조.
pub const SymbolId = enum(u32) {
    none = std.math.maxInt(u32),
    _,

    pub fn isNone(self: SymbolId) bool {
        return self == .none;
    }
};

/// Cross-module 심볼 참조. semantic/bundler 두 공간을 구분.
/// issue #1328 "Semantic 공존 모델 — SymbolRef 옵션 1(union)".
pub const SymbolRef = union(enum) {
    /// semantic이 소유한 선언 심볼 (var/let/const/function/class/import/parameter/catch)
    semantic: struct { module: ModuleIndex, symbol: SemanticSymbolId },
    /// bundler가 만든 합성 심볼 (_default$N, exports_X, init_X, __ns_X)
    bundler: struct { module: ModuleIndex, symbol: SymbolId },

    pub const invalid: SymbolRef = .{ .bundler = .{ .module = .none, .symbol = .none } };

    pub fn isValid(self: SymbolRef) bool {
        return switch (self) {
            .semantic => |s| !s.module.isNone() and !s.symbol.isNone(),
            .bundler => |b| !b.module.isNone() and !b.symbol.isNone(),
        };
    }

    pub fn moduleIndex(self: SymbolRef) ModuleIndex {
        return switch (self) {
            .semantic => |s| s.module,
            .bundler => |b| b.module,
        };
    }

    pub fn eql(a: SymbolRef, b: SymbolRef) bool {
        return switch (a) {
            .semantic => |sa| switch (b) {
                .semantic => |sb| sa.module == sb.module and sa.symbol == sb.symbol,
                .bundler => false,
            },
            .bundler => |ba| switch (b) {
                .bundler => |bb| ba.module == bb.module and ba.symbol == bb.symbol,
                .semantic => false,
            },
        };
    }
};

/// 합성 심볼 종류.
pub const SymbolKind = enum(u8) {
    /// `export default ...` 합성 변수 (`_default`, `_default$N`)
    synthetic_default,
    /// CJS 래퍼의 `exports_<module>` 객체
    synthetic_exports,
    /// ESM 래퍼의 `init_<module>` 함수
    synthetic_init,
    /// `import * as X` namespace 객체
    synthetic_namespace,
    /// Re-export alias (`export { X } from './m'`, barrel 등).
    /// 자기 자신은 값을 갖지 않고 `points_to`로 target export를 가리킴.
    re_export_alias,
    /// Resolve 실패한 외부 import (node builtin 등)
    unresolved_external,
};

/// 합성 심볼 레코드 (AoS 레이아웃 — 성능상 필요 시 내부 SoA로 전환 가능, R2).
pub const Symbol = struct {
    name: []const u8,
    kind: SymbolKind,
    span: Span,
    /// Re-export 체인에서 이 심볼이 가리키는 원본 (미해결/로컬은 invalid).
    /// Phase 3에서 linker가 채움.
    points_to: SymbolRef = SymbolRef.invalid,
    /// Linker renaming 후 최종 emit 이름. 빈 문자열이면 `name` 사용.
    canonical_name: []const u8 = "",
    /// Tree-shaking용 usage count. Phase 3에서 수집 시작.
    ref_count: u32 = 0,
};

/// 모듈별 합성 심볼 저장소.
///
/// R1: 외부는 getter/setter만 사용. `symbols`/`by_name` 직접 접근 금지.
pub const SymbolTable = struct {
    symbols: std.ArrayList(Symbol),
    by_name: std.StringHashMap(SymbolId),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) SymbolTable {
        return .{
            .symbols = .empty,
            .by_name = std.StringHashMap(SymbolId).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *SymbolTable) void {
        self.symbols.deinit(self.allocator);
        self.by_name.deinit();
    }

    // ── mutation ──────────────────────────────────────────────

    /// 합성 심볼을 등록하고 새 id를 반환.
    /// 같은 이름이 이미 있으면 기존 id 반환 (멱등) — bundler 합성은 모듈당 1개 전제.
    pub fn declare(
        self: *SymbolTable,
        name: []const u8,
        kind: SymbolKind,
        span: Span,
    ) !SymbolId {
        if (self.by_name.get(name)) |existing| return existing;
        const id: SymbolId = @enumFromInt(@as(u32, @intCast(self.symbols.items.len)));
        try self.symbols.append(self.allocator, .{
            .name = name,
            .kind = kind,
            .span = span,
        });
        try self.by_name.put(name, id);
        return id;
    }

    /// 이름 기반 조회 없이 익명 심볼 등록. re_export_alias처럼 같은 exported_name이
    /// 여러 개 올 수 있거나, name으로 lookup이 필요 없는 경우에 사용.
    pub fn declareAnonymous(
        self: *SymbolTable,
        name: []const u8,
        kind: SymbolKind,
        span: Span,
    ) !SymbolId {
        const id: SymbolId = @enumFromInt(@as(u32, @intCast(self.symbols.items.len)));
        try self.symbols.append(self.allocator, .{
            .name = name,
            .kind = kind,
            .span = span,
        });
        return id;
    }

    pub fn setPointsTo(self: *SymbolTable, id: SymbolId, target: SymbolRef) void {
        self.symbols.items[@intFromEnum(id)].points_to = target;
    }

    pub fn setCanonicalName(self: *SymbolTable, id: SymbolId, name: []const u8) void {
        self.symbols.items[@intFromEnum(id)].canonical_name = name;
    }

    pub fn incRefCount(self: *SymbolTable, id: SymbolId) void {
        self.symbols.items[@intFromEnum(id)].ref_count += 1;
    }

    // ── read ──────────────────────────────────────────────────

    pub fn count(self: *const SymbolTable) u32 {
        return @intCast(self.symbols.items.len);
    }

    pub fn find(self: *const SymbolTable, name: []const u8) ?SymbolId {
        return self.by_name.get(name);
    }

    pub fn getName(self: *const SymbolTable, id: SymbolId) []const u8 {
        return self.symbols.items[@intFromEnum(id)].name;
    }

    pub fn getKind(self: *const SymbolTable, id: SymbolId) SymbolKind {
        return self.symbols.items[@intFromEnum(id)].kind;
    }

    pub fn getSpan(self: *const SymbolTable, id: SymbolId) Span {
        return self.symbols.items[@intFromEnum(id)].span;
    }

    pub fn getPointsTo(self: *const SymbolTable, id: SymbolId) SymbolRef {
        return self.symbols.items[@intFromEnum(id)].points_to;
    }

    /// canonical_name이 비어있으면 원본 name 반환.
    pub fn getCanonicalName(self: *const SymbolTable, id: SymbolId) []const u8 {
        const s = &self.symbols.items[@intFromEnum(id)];
        return if (s.canonical_name.len > 0) s.canonical_name else s.name;
    }

    /// `setCanonicalName`이 호출된 적 있는지 여부. re_export_alias의 체인 resolve
    /// 완료를 판정할 때 fallback("" → name) 때문에 `getCanonicalName`만으로는 구분
    /// 불가하므로 별도 API.
    pub fn hasCanonicalName(self: *const SymbolTable, id: SymbolId) bool {
        return self.symbols.items[@intFromEnum(id)].canonical_name.len > 0;
    }

    pub fn getRefCount(self: *const SymbolTable, id: SymbolId) u32 {
        return self.symbols.items[@intFromEnum(id)].ref_count;
    }
};

// ── tests ─────────────────────────────────────────────────────

test "SymbolTable: declare + get 기본" {
    var t = SymbolTable.init(std.testing.allocator);
    defer t.deinit();

    const id = try t.declare("_default", .synthetic_default, .{ .start = 0, .end = 0 });
    try std.testing.expectEqualStrings("_default", t.getName(id));
    try std.testing.expectEqual(SymbolKind.synthetic_default, t.getKind(id));
    try std.testing.expectEqual(@as(u32, 1), t.count());
}

test "SymbolTable: declare 멱등 (같은 이름)" {
    var t = SymbolTable.init(std.testing.allocator);
    defer t.deinit();

    const a = try t.declare("init_X", .synthetic_init, .{ .start = 0, .end = 0 });
    const b = try t.declare("init_X", .synthetic_init, .{ .start = 0, .end = 0 });
    try std.testing.expectEqual(a, b);
    try std.testing.expectEqual(@as(u32, 1), t.count());
}

test "SymbolTable: find" {
    var t = SymbolTable.init(std.testing.allocator);
    defer t.deinit();

    const id = try t.declare("exports_Foo", .synthetic_exports, .{ .start = 0, .end = 0 });
    try std.testing.expectEqual(@as(?SymbolId, id), t.find("exports_Foo"));
    try std.testing.expectEqual(@as(?SymbolId, null), t.find("missing"));
}

test "SymbolTable: canonical_name fallback" {
    var t = SymbolTable.init(std.testing.allocator);
    defer t.deinit();

    const id = try t.declare("_default", .synthetic_default, .{ .start = 0, .end = 0 });
    try std.testing.expectEqualStrings("_default", t.getCanonicalName(id));
    t.setCanonicalName(id, "_default$2");
    try std.testing.expectEqualStrings("_default$2", t.getCanonicalName(id));
}

test "SymbolTable: points_to + ref_count" {
    var t = SymbolTable.init(std.testing.allocator);
    defer t.deinit();

    const id = try t.declare("_default", .synthetic_default, .{ .start = 0, .end = 0 });
    try std.testing.expect(!t.getPointsTo(id).isValid());

    const target: SymbolRef = .{ .bundler = .{
        .module = @enumFromInt(7),
        .symbol = @enumFromInt(3),
    } };
    t.setPointsTo(id, target);
    try std.testing.expect(t.getPointsTo(id).isValid());
    try std.testing.expect(t.getPointsTo(id).eql(target));

    try std.testing.expectEqual(@as(u32, 0), t.getRefCount(id));
    t.incRefCount(id);
    t.incRefCount(id);
    try std.testing.expectEqual(@as(u32, 2), t.getRefCount(id));
}

test "SymbolRef: semantic vs bundler 공간 구분" {
    const sem: SymbolRef = .{ .semantic = .{
        .module = @enumFromInt(1),
        .symbol = @enumFromInt(2),
    } };
    const bnd: SymbolRef = .{ .bundler = .{
        .module = @enumFromInt(1),
        .symbol = @enumFromInt(2),
    } };
    // 같은 숫자라도 다른 공간이면 다른 ref
    try std.testing.expect(!sem.eql(bnd));
    try std.testing.expect(sem.eql(sem));
    try std.testing.expect(!SymbolRef.invalid.isValid());
}
