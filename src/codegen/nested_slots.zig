//! ZNTC Nested-Scope Slot Assignment — esbuild `renamer.go` 1:1 이식
//!
//! RFC #3391 / 트래킹 이슈 #3392, PR-1.
//!
//! 미니파이 격차의 유일·진짜 레버: 현 mangler 의 flat per-module 처리를
//! esbuild 의 재귀 nested-scope-slot walk 로 교체하기 위한 *인프라*.
//!
//! 이 PR(PR-1)에서는 slot 할당 알고리즘만 구현하고 mangler 파이프라인에
//! **연결하지 않는다** — `mangle()` 은 이 모듈을 호출하지 않으므로 번들
//! 동작은 완전히 무변경. 이름 발급(`AssignNamesByFrequency`)·Phase A 통합·
//! flag 게이트는 PR-2/PR-3 에서 추가한다.
//!
//! ## esbuild 알고리즘 (internal/renamer/renamer.go)
//!
//! `AssignNestedScopeSlots(moduleScope, symbols)`:
//!   1. module(top-level) 멤버를 일시적으로 "valid" 마킹 → nested scope 에서
//!      slot 을 안 받게 (호이스팅된 `var` 가 top-level 심볼이 되는 것 보호).
//!   2. moduleScope 의 각 자식에 대해 빈 SlotCounts 로 helper 재귀 →
//!      자식 subtree 마다 독립된 slot 공간 (형제 subtree 는 동시 live 불가).
//!   3. top-level 멤버 마킹 원복 (top-level 은 nested slot 없음).
//!
//! `assignNestedScopeSlotsHelper(scope, symbols, slot)`:
//!   - 이 scope 멤버를 inner-index 순으로 정렬 (결정성).
//!   - 아직 미할당이고 `must_not_be_renamed` 가 아니면
//!     `slot[ns]` 부여 후 `slot[ns] += 1`.
//!   - 자식 scope 들에 *부모 카운트를 복사*해 전달 → 형제는 같은 slot 재사용,
//!     자식은 부모 카운트 *이후*부터 시작 → closure-capture 된 outer 이름과
//!     **구성적으로 충돌 불가** (이게 flat-mangle 이 못 주던 안전성, #2956
//!     subtree-liveness 와 동치).
//!   - `UnionMax` 로 형제 간 최대 slot 수 집계.
//!
//! ## ZNTC ↔ esbuild 매핑
//!
//! | esbuild | ZNTC |
//! |---|---|
//! | `moduleScope.Children` (포인터) | parent-only `scopes` → `buildChildrenList` 역산 |
//! | `scope.Members` (map ref→symbol) | `scope_maps[scope_id]` (name→symbol_idx) |
//! | `scope.Generated` | 없음 — ZNTC 합성 심볼은 `scope_id=none`, 어느 scope_map 에도 없어 자연 제외 (helper 가 방문 안 함) |
//! | `scope.Label` | 없음 — ZNTC 는 label 을 심볼로 모델링 안 함 (label namespace 미사용) |
//! | `Symbol.NestedScopeSlot` (`ast.Index32`) | `Symbol.nested_scope_slot: ?u32` (null=invalid) |
//! | `Symbol.SlotNamespace()` | `slotNamespace()` (mangler.shouldSkip 재사용, 단일 소스) |
//!
//! 호출 불변식: `scope_maps.len == scopes.len`, `scopes[0]` = module(top-level)
//! scope. 방어적 경계 가드가 있으나, 위반 시 tail scope 의 slot 이 조용히
//! 누락되므로 PR-2 연결 시 caller 가 보장해야 한다.

const std = @import("std");
const Scope = @import("../semantic/scope.zig").Scope;
const ScopeId = @import("../semantic/scope.zig").ScopeId;
const symbol_mod = @import("../semantic/symbol.zig");
const Symbol = symbol_mod.Symbol;
const SlotNamespace = symbol_mod.SlotNamespace;
const mangler = @import("mangler.zig");

/// namespace 별 slot 카운터 (esbuild `ast.SlotCounts` = `[3]uint32`).
/// `SlotNamespace.must_not_be_renamed` (=3) 은 sentinel 이라 인덱싱 전에 걸러진다.
pub const SlotCounts = struct {
    counts: [SlotNamespace.indexable_count]u32 = .{ 0, 0, 0 },

    pub fn get(self: SlotCounts, ns: SlotNamespace) u32 {
        return self.counts[@intFromEnum(ns)];
    }

    fn incr(self: *SlotCounts, ns: SlotNamespace) void {
        self.counts[@intFromEnum(ns)] += 1;
    }

    /// element-wise max (esbuild `SlotCounts.UnionMax`).
    fn unionMax(self: *SlotCounts, other: SlotCounts) void {
        inline for (0..SlotNamespace.indexable_count) |i| {
            if (other.counts[i] > self.counts[i]) self.counts[i] = other.counts[i];
        }
    }
};

/// top-level 심볼을 nested walk 동안 "할당됨" 으로 일시 마킹하는 sentinel
/// (esbuild `ast.MakeIndex32(1)` 대응). validity 모델은 `!= null` — 이 값은
/// non-null 이기만 하면 되고 실제 slot 번호와 절대 겹치지 않으면 된다
/// (`maxInt` 라 실제 slot 발급 범위와 분리). walk 종료 시 null 로 원복.
pub const TOPLEVEL_SENTINEL: u32 = std.math.maxInt(u32);

/// esbuild `Symbol.SlotNamespace()` 대응. mangler 의 skip 판정을 **단일 소스로
/// 재사용** — exported / import / class-expr-name / `arguments` / 이미 1글자
/// 인 심볼은 rename 금지(`must_not_be_renamed`), 나머지는 `default`.
/// (ZNTC 는 label·private 필드를 심볼로 모델링하지 않아 그 둘은 미등장.)
pub fn slotNamespace(sym: Symbol, name: []const u8) SlotNamespace {
    if (mangler.shouldSkip(sym, name)) return .must_not_be_renamed;
    return .default;
}

/// walk 전반에 불변인 컨텍스트. 재귀 프레임마다 슬라이스 4개를 복사하지
/// 않도록 한 번 묶어 포인터로 전달 (esbuild 는 receiver/closure 로 공유).
const Ctx = struct {
    symbols: []Symbol,
    scope_maps: []const std.StringHashMap(usize),
    children: mangler.ChildrenList,
    /// 정규 심볼의 이름은 source span 에 있으므로 `nameText` 에 원본이 필요.
    source: []const u8,
    scratch_allocator: std.mem.Allocator,
};

/// module(top-level=scope 0) 멤버 전체의 `nested_scope_slot` 을 `value` 로 설정.
/// 마킹(`TOPLEVEL_SENTINEL`) 과 원복(`null`) 양쪽에서 쓰는 단일 경로.
fn setModuleSymbolSlots(ctx: *const Ctx, value: ?u32) void {
    if (ctx.scope_maps.len == 0) return;
    var it = ctx.scope_maps[0].valueIterator();
    while (it.next()) |sym_idx| {
        if (sym_idx.* < ctx.symbols.len) {
            ctx.symbols[sym_idx.*].nested_scope_slot = value;
        }
    }
}

/// esbuild `AssignNestedScopeSlots`. `symbols` 를 in-place mutate
/// (`slot_namespace`/`nested_scope_slot` 채움). 반환값 = 모듈 전체에서 필요한
/// namespace 별 nested slot 수.
///
/// `source` = 모듈 원본 (정규 심볼 이름 추출용). 전제: `scopes[0]` = module scope.
pub fn assignNestedScopeSlots(
    allocator: std.mem.Allocator,
    scopes: []const Scope,
    symbols: []Symbol,
    scope_maps: []const std.StringHashMap(usize),
    source: []const u8,
) !SlotCounts {
    var result: SlotCounts = .{};
    if (scopes.len == 0) return result;

    const children = try mangler.buildChildrenList(allocator, scopes);
    defer allocator.free(children.offsets);
    defer allocator.free(children.list);

    const ctx: Ctx = .{
        .symbols = symbols,
        .scope_maps = scope_maps,
        .children = children,
        .source = source,
        .scratch_allocator = allocator,
    };

    // 1. top-level(module scope=0) 멤버를 일시 valid 마킹 → nested scope 에서
    //    slot 안 받음 (nested 에서 선언됐지만 module 로 호이스팅된 `var` 가
    //    실제로는 top-level 심볼인 경우 보호; esbuild 와 동일).
    setModuleSymbolSlots(&ctx, TOPLEVEL_SENTINEL);

    // 2. module scope 의 각 자식 subtree 에 *빈* SlotCounts 로 진입 — 자식
    //    subtree 끼리는 동시 live 불가하므로 각자 0 부터 독립 numbering.
    {
        const start = children.offsets[0];
        const end = children.offsets[1];
        var ci = start;
        while (ci < end) : (ci += 1) {
            result.unionMax(try assignNestedScopeSlotsHelper(&ctx, children.list[ci], .{}));
        }
    }

    // 3. top-level 마킹 원복 — top-level 심볼은 nested slot 을 가지지 않는다.
    setModuleSymbolSlots(&ctx, null);

    return result;
}

/// esbuild `assignNestedScopeSlotsHelper`. `slot_in` 은 부모가 자신의 멤버를
/// 배정한 *이후*의 카운트를 값으로 복사받는다 → 형제는 같은 번호 재사용,
/// 자식은 부모 카운트 이후부터.
fn assignNestedScopeSlotsHelper(ctx: *const Ctx, scope_idx: u32, slot_in: SlotCounts) !SlotCounts {
    var slot = slot_in;

    // 결정성: 멤버를 symbol inner-index 오름차순으로 (esbuild `sort.Ints`).
    if (scope_idx < ctx.scope_maps.len) {
        var members: std.ArrayList(u32) = .empty;
        defer members.deinit(ctx.scratch_allocator);

        var it = ctx.scope_maps[scope_idx].valueIterator();
        while (it.next()) |sym_idx| {
            if (sym_idx.* < ctx.symbols.len) {
                try members.append(ctx.scratch_allocator, @intCast(sym_idx.*));
            }
        }
        std.mem.sortUnstable(u32, members.items, {}, std.sort.asc(u32));

        for (members.items) |sym_idx| {
            const sym = &ctx.symbols[sym_idx];
            const ns = slotNamespace(sym.*, sym.nameText(ctx.source));
            sym.slot_namespace = ns;
            // 이미 valid (top-level 마킹 또는 이미 배정) 면 건너뜀 — 부모
            // scope 의 slot 을 그대로 쓴다 (esbuild `!IsValid()` 가드).
            if (ns != .must_not_be_renamed and sym.nested_scope_slot == null) {
                sym.nested_scope_slot = slot.get(ns);
                slot.incr(ns);
            }
        }
    }

    // 자식 scope 들: 각자 부모 카운트(`slot`)의 *복사본*을 받는다.
    var slot_counts = slot;
    if (scope_idx + 1 < ctx.children.offsets.len) {
        const start = ctx.children.offsets[scope_idx];
        const end = ctx.children.offsets[scope_idx + 1];
        var ci = start;
        while (ci < end) : (ci += 1) {
            slot_counts.unionMax(try assignNestedScopeSlotsHelper(ctx, ctx.children.list[ci], slot));
        }
    }
    return slot_counts;
}

// ============================================================
// 유닛 테스트 — esbuild renamer.go fixture 1:1 slot 동치
// ============================================================
//
// 테스트 심볼은 `synthetic_name` 을 채운다 → `nameText` 가 source 슬라이싱
// 없이 그 이름을 반환하므로 정규 심볼처럼 분류(renamable). exported 심볼은
// is_exported 로 must_not_be_renamed 강제. (정규 심볼의 실 source-span
// nameText 경로는 PR-2 파이프라인 연결 시 통합 테스트로 커버.)

const testing = std.testing;
const Span = @import("../lexer/token.zig").Span;

const TestSym = struct { name: []const u8, scope: u32, exported: bool = false };

/// scopes(parent 배열) + per-scope 심볼 목록으로 테스트 입력을 구성하고
/// assignNestedScopeSlots 를 돌린 뒤, 심볼별 nested_scope_slot 을 반환.
fn runFixture(
    allocator: std.mem.Allocator,
    parents: []const u32, // parents[i] = scope i 의 부모 (0xFFFFFFFF = none)
    syms: []const TestSym,
    out_slots: []?u32,
) !SlotCounts {
    var scopes = try allocator.alloc(Scope, parents.len);
    defer allocator.free(scopes);
    for (parents, 0..) |p, i| {
        scopes[i] = .{
            .parent = if (p == 0xFFFFFFFF) ScopeId.none else @enumFromInt(p),
            .kind = if (i == 0) .module else .block,
            .is_strict = true,
        };
    }

    var symbols = try allocator.alloc(Symbol, syms.len);
    defer allocator.free(symbols);
    for (syms, 0..) |s, i| {
        symbols[i] = .{
            .name = Span{ .start = 0, .end = 0 },
            .scope_id = @enumFromInt(s.scope),
            .kind = .variable_let,
            .declaration_span = Span{ .start = 0, .end = 0 },
            .synthetic_name = s.name, // nameText 가 이걸 반환 → 정상 분류
        };
        symbols[i].decl_flags.is_exported = s.exported;
    }

    var scope_maps = try allocator.alloc(std.StringHashMap(usize), parents.len);
    defer {
        for (scope_maps) |*m| m.deinit();
        allocator.free(scope_maps);
    }
    for (scope_maps) |*m| m.* = std.StringHashMap(usize).init(allocator);
    for (syms, 0..) |s, i| {
        try scope_maps[s.scope].put(s.name, i);
    }

    // synthetic_name 이 채워져 있어 source 는 미사용 — "" 안전.
    const counts = try assignNestedScopeSlots(allocator, scopes, symbols, scope_maps, "");
    for (symbols, 0..) |sym, i| out_slots[i] = sym.nested_scope_slot;
    return counts;
}

test "형제 scope 는 같은 slot 재사용" {
    const a = testing.allocator;
    // 0:module → 1:childA(a), 2:childB(b)
    var slots: [2]?u32 = undefined;
    const counts = try runFixture(a, &.{ 0xFFFFFFFF, 0, 0 }, &.{
        .{ .name = "aa", .scope = 1 },
        .{ .name = "bb", .scope = 2 },
    }, &slots);
    try testing.expectEqual(@as(?u32, 0), slots[0]); // a → slot 0
    try testing.expectEqual(@as(?u32, 0), slots[1]); // b → slot 0 (형제 재사용)
    try testing.expectEqual(@as(u32, 1), counts.get(.default));
}

test "자식 scope 는 부모 카운트 이후부터 (closure 충돌 불가)" {
    const a = testing.allocator;
    // 0:module → 1:fn(x) → 2:block(y)
    var slots: [2]?u32 = undefined;
    const counts = try runFixture(a, &.{ 0xFFFFFFFF, 0, 1 }, &.{
        .{ .name = "xx", .scope = 1 },
        .{ .name = "yy", .scope = 2 },
    }, &slots);
    try testing.expectEqual(@as(?u32, 0), slots[0]); // x → slot 0
    try testing.expectEqual(@as(?u32, 1), slots[1]); // y → slot 1 (부모 이후)
    try testing.expectEqual(@as(u32, 2), counts.get(.default));
}

test "깊은 nesting + depth-2 형제 재사용" {
    const a = testing.allocator;
    // 0:module → 1:fn(p) → {2:b1(x), 3:b2(yy)}
    var slots: [3]?u32 = undefined;
    const counts = try runFixture(a, &.{ 0xFFFFFFFF, 0, 1, 1 }, &.{
        .{ .name = "pp", .scope = 1 },
        .{ .name = "xx", .scope = 2 },
        .{ .name = "yy", .scope = 3 },
    }, &slots);
    try testing.expectEqual(@as(?u32, 0), slots[0]); // p → 0
    try testing.expectEqual(@as(?u32, 1), slots[1]); // x → 1
    try testing.expectEqual(@as(?u32, 1), slots[2]); // y → 1 (b1/b2 형제 재사용)
    try testing.expectEqual(@as(u32, 2), counts.get(.default));
}

test "top-level 심볼은 nested slot 을 받지 않는다" {
    const a = testing.allocator;
    // module(m) → 1:fn(local). m 은 top-level → 항상 null.
    var slots: [2]?u32 = undefined;
    _ = try runFixture(a, &.{ 0xFFFFFFFF, 0 }, &.{
        .{ .name = "mm", .scope = 0 },
        .{ .name = "local", .scope = 1 },
    }, &slots);
    try testing.expectEqual(@as(?u32, null), slots[0]); // top-level → null
    try testing.expectEqual(@as(?u32, 0), slots[1]); // nested local → 0
}

test "must_not_be_renamed(exported) 는 slot 을 소비하지 않는다" {
    const a = testing.allocator;
    // 0:module → 1:fn{ exp(exported), v }
    var slots: [2]?u32 = undefined;
    const counts = try runFixture(a, &.{ 0xFFFFFFFF, 0 }, &.{
        .{ .name = "exp", .scope = 1, .exported = true },
        .{ .name = "vv", .scope = 1 },
    }, &slots);
    try testing.expectEqual(@as(?u32, null), slots[0]); // exported → 미할당
    try testing.expectEqual(@as(?u32, 0), slots[1]); // v → slot 0 (exp 가 0 안 먹음)
    try testing.expectEqual(@as(u32, 1), counts.get(.default));
}

test "빈 입력 / module-only 안전" {
    const a = testing.allocator;
    var slots: [1]?u32 = undefined;
    const counts = try runFixture(a, &.{0xFFFFFFFF}, &.{
        .{ .name = "only", .scope = 0 },
    }, &slots);
    try testing.expectEqual(@as(?u32, null), slots[0]);
    try testing.expectEqual(@as(u32, 0), counts.get(.default));
}
