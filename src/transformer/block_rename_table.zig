//! 심볼 기준 블록 스코핑 리네임 표 (#4760 4단계).
//!
//! es5 로 낮추면 블록 안 `let`/`const`/`class` 가 가장 가까운 함수 스코프의 `var` 가 된다.
//! 그때 같은 이름의 다른 바인딩과 겹치면 새 이름이 필요하다. 지금은 방문 중에 이름 문자열
//! 스택으로 판정하는데, "이 식별자가 그 변수인가"를 이름으로 추측해 놓치는 경우가 있다
//! (#4758 함수 본문 var, #4764 switch let). 여기서는 분석기의 스코프·심볼·참조로 **변환 전에**
//! 어떤 심볼을 바꿀지 정한다.
//!
//! 규칙 — 블록 스코프(`block`·`switch_block`)의 let/const/class 심볼 S 를 함수 F 로 끌어올릴 때
//! (1) S 의 블록과 F 사이 스코프(`catch (x)` 등)나 F 자신에 같은 이름 바인딩이 있거나
//! (2) 먼저 F 로 끌어올린 다른 블록 바인딩과 이름이 같고 둘 중 하나가 클로저에 잡히거나
//!     (형제 블록끼리는 수명이 겹치지 않아 한 `var` 로 합쳐도 되지만, 클로저가 잡은 쪽은
//!     블록이 끝난 뒤에도 살아 있어 다른 블록의 대입을 보게 된다)
//! (3) F 안(중첩 함수 포함)의 참조가 F **바깥**의 같은 이름 바인딩을 가리키거나
//! (4) 같은 이름의 전역(선언 없는 참조)이 있으면
//! S 를 바꾼다 — `var` 로 끌어올리면 그 참조들이 S 를 보게 된다. 아니면 S 의 이름을 F 의
//! "끌어올린 이름"으로 등록한다. 전역 참조는 분석기가 이름만 모으므로 (4)는 보수적이다.

const std = @import("std");
const scope_mod = @import("../semantic/scope.zig");
const symbol_mod = @import("../semantic/symbol.zig");
const Scope = scope_mod.Scope;
const ScopeId = scope_mod.ScopeId;
const Symbol = symbol_mod.Symbol;

pub const Input = struct {
    scopes: []const Scope,
    symbols: []const Symbol,
    scope_maps: []const std.StringHashMapUnmanaged(usize),
    references: []const symbol_mod.Reference,
    unresolved: *const std.StringHashMapUnmanaged(void),
    /// 심볼 이름 텍스트 (`ast.getText(sym.name)`).
    ctx: *const anyopaque,
    nameOf: *const fn (ctx: *const anyopaque, sym: Symbol) []const u8,
};

/// 바꿔야 하는 심볼 번호 집합.
pub const Table = std.AutoHashMapUnmanaged(u32, void);

const NameSets = std.AutoHashMapUnmanaged(u32, std.StringHashMapUnmanaged(void));

fn isHoistedLexical(sym: Symbol) bool {
    return switch (sym.kind) {
        .variable_let, .variable_const, .class_decl => true,
        else => false,
    };
}

fn nearestVarScope(scopes: []const Scope, start: ScopeId) ScopeId {
    var s = start;
    while (!s.isNone()) {
        const sc = scopes[s.toIndex()];
        if (sc.kind.isVarScope()) return s;
        s = sc.parent;
    }
    return .none;
}

pub fn build(allocator: std.mem.Allocator, in: Input) std.mem.Allocator.Error!Table {
    var table: Table = .empty;
    errdefer table.deinit(allocator);

    // (3) 함수 F → F 안에서 F 바깥 바인딩을 가리키는 참조의 이름들.
    var outside_refs: NameSets = .empty;
    defer deinitSets(allocator, &outside_refs);
    for (in.references) |ref| {
        if (ref.symbol_id.isNone()) continue;
        const sym_i = @intFromEnum(ref.symbol_id);
        if (sym_i >= in.symbols.len) continue;
        const decl_scope = in.symbols[sym_i].scope_id;
        const name = in.nameOf(in.ctx, in.symbols[sym_i]);
        // 참조 스코프에서 선언 스코프까지 올라가며, 그 사이의 함수들은 이 이름을 바깥에서 본다.
        var s = ref.scope_id;
        while (!s.isNone() and s != decl_scope) {
            const sc = in.scopes[s.toIndex()];
            if (sc.kind.isVarScope()) {
                const gop = try outside_refs.getOrPut(allocator, s.toIndex());
                if (!gop.found_existing) gop.value_ptr.* = .empty;
                try gop.value_ptr.put(allocator, name, {});
            }
            s = sc.parent;
        }
    }

    // 클로저에 잡힌 심볼 — 선언과 다른 함수 스코프에서 참조된다.
    var captured = try std.DynamicBitSet.initEmpty(allocator, in.symbols.len);
    defer captured.deinit();
    for (in.references) |ref| {
        if (ref.symbol_id.isNone()) continue;
        const sym_i = @intFromEnum(ref.symbol_id);
        if (sym_i >= in.symbols.len) continue;
        if (nearestVarScope(in.scopes, ref.scope_id) != nearestVarScope(in.scopes, in.symbols[sym_i].scope_id)) captured.set(sym_i);
    }

    // (2) 함수 F → 이미 F 로 끌어올린 블록 바인딩 이름 → 그 바인딩이 클로저에 잡혔는지.
    var hoisted: std.AutoHashMapUnmanaged(u32, std.StringHashMapUnmanaged(bool)) = .empty;
    defer {
        var hit = hoisted.valueIterator();
        while (hit.next()) |set| set.deinit(allocator);
        hoisted.deinit(allocator);
    }
    // 스코프 배열은 생성 순서 = 소스 순서라, 바깥 블록이 안쪽보다 먼저 처리된다.
    for (in.scopes, 0..) |sc, si| {
        if (sc.kind != .block and sc.kind != .switch_block) continue;
        if (si >= in.scope_maps.len) continue;
        const var_scope = nearestVarScope(in.scopes, sc.parent);
        if (var_scope.isNone()) continue;
        const gop = try hoisted.getOrPut(allocator, var_scope.toIndex());
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        const outside = outside_refs.getPtr(var_scope.toIndex());
        // 같은 스코프 안 순서는 해시 순서 — 한 블록 안 이름끼리는 겹칠 수 없어 결과가 같다.
        var it = in.scope_maps[si].iterator();
        while (it.next()) |entry| {
            const name = entry.key_ptr.*;
            const sym_idx: u32 = @intCast(entry.value_ptr.*);
            if (sym_idx >= in.symbols.len or !isHoistedLexical(in.symbols[sym_idx])) continue;
            const is_captured = captured.isSet(sym_idx);
            const sibling_conflict = if (gop.value_ptr.get(name)) |earlier_captured| earlier_captured or is_captured else false;
            const conflict = boundBetween(in, sc.parent, var_scope, name) or
                sibling_conflict or
                (outside != null and outside.?.contains(name)) or
                in.unresolved.contains(name);
            if (conflict) {
                try table.put(allocator, sym_idx, {});
            } else {
                const hg = try gop.value_ptr.getOrPut(allocator, name);
                hg.value_ptr.* = if (hg.found_existing) hg.value_ptr.* or is_captured else is_captured;
            }
        }
    }
    return table;
}

fn deinitSets(allocator: std.mem.Allocator, m: *NameSets) void {
    var it = m.valueIterator();
    while (it.next()) |set| set.deinit(allocator);
    m.deinit(allocator);
}

/// (1) `from` 부터 `until`(포함)까지 올라가며 `name` 바인딩이 있는지.
fn boundBetween(in: Input, from: ScopeId, until: ScopeId, name: []const u8) bool {
    var s = from;
    while (!s.isNone()) {
        const i = s.toIndex();
        if (i < in.scope_maps.len and in.scope_maps[i].contains(name)) return true;
        if (s == until) return false;
        s = in.scopes[i].parent;
    }
    return false;
}
