//! ZTS Identifier Mangler — Liveness-based Slot Reuse (oxc 방식)
//!
//! 스코프 분석 + liveness BitSet를 기반으로 로컬 변수 이름을 짧은 이름으로 교체한다.
//! 번들 크기를 ~70% 절감하는 핵심 최적화.
//!
//! 알고리즘 (oxc/esbuild 기반, 그래프 컬러링):
//!   1. parent 배열에서 children 역산 (O(n), 2-pass)
//!   2. references로 per-symbol liveness BitSet 계산
//!   3. DFS로 scope tree 순회, alive하지 않은 slot 재사용 (그래프 컬러링)
//!   4. 빈도순 이름 할당 (Base54, 고빈도 심볼이 짧은 이름)
//!
//! 규칙:
//!   - export된 심볼은 mangling 하지 않음
//!   - import 바인딩은 mangling 하지 않음 (번들러가 처리)
//!   - 예약어/글로벌 이름은 건너뜀
//!   - 함수 파라미터도 mangling 대상
//!
//! 참고:
//!   - oxc: crates/oxc_mangler/src/lib.rs (liveness + graph coloring)
//!   - esbuild: internal/renamer/renamer.go (DFS slot assignment)

const std = @import("std");
const Scope = @import("../semantic/scope.zig").Scope;
const ScopeId = @import("../semantic/scope.zig").ScopeId;
const Symbol = @import("../semantic/symbol.zig").Symbol;
const Reference = @import("../semantic/symbol.zig").Reference;

pub const ManglerResult = struct {
    /// symbol_id -> 새 이름. codegen의 linking_metadata.renames에 주입.
    renames: std.AutoHashMap(u32, []const u8),
    allocator: std.mem.Allocator,
    /// 이 호출의 측정값. `--mangle-report` 경로 외엔 무시됨. #1760 property harness.
    stats: ManglerStats = .{},

    pub fn deinit(self: *ManglerResult) void {
        var it = self.renames.valueIterator();
        while (it.next()) |v| self.allocator.free(v.*);
        self.renames.deinit();
    }

    /// renames의 소유권을 이전하고, 이 결과를 안전하게 해제 가능한 상태로 만든다.
    /// 호출 후 renames의 값 문자열은 호출자가 해제 책임을 진다.
    pub fn takeRenames(self: *ManglerResult) std.AutoHashMap(u32, []const u8) {
        const taken = self.renames;
        self.renames = std.AutoHashMap(u32, []const u8).init(self.allocator);
        return taken;
    }
};

/// Mangler 호출 1회의 측정값. Unified mangler 로 마이그레이션 전/후의
/// property 검증 (번들 크기 ± 1%, 이름 길이 총합 등) 에 사용.
pub const ManglerStats = struct {
    /// Phase 3 에서 생성된 고유 slot 수 (= 고유 base54 이름 수).
    slot_count: usize = 0,
    /// Phase 4 에서 할당된 slot 이름 길이의 합.
    slot_name_length_sum: usize = 0,
    /// Phase 4 종료 시점의 base54 name_counter 값 (예약어 스킵 포함 소비).
    name_counter_final: u32 = 0,
    /// Phase 3 종료 시점의 reserved_names set 크기.
    reserved_size: usize = 0,
    /// Phase 5 후 renames 에 기록된 심볼 수 (원본과 동일하면 skip 되므로 slot_count 와 다를 수 있음).
    renamed_symbol_count: usize = 0,
};

/// mangle() 입력 데이터.
pub const MangleInput = struct {
    scopes: []const Scope,
    symbols: []const Symbol,
    scope_maps: []const std.StringHashMap(usize),
    /// Mangler 는 (symbol_id, scope_id) 만 소비. node_index/kind 필드는
    /// dead store / property mangle 등 다른 consumer 용.
    references: []const Reference,
    source: []const u8,
    /// 번들 모드에서 mangling 제외할 symbol indices (null이면 없음)
    skip_symbols: ?std.DynamicBitSet = null,
    /// #1760 unified 경로: Phase A 가 소비한 counter 를 Phase B 가 이어받도록.
    /// default=0 이면 기존 동작 그대로.
    starting_name_counter: u32 = 0,
    /// #1760 unified 경로: 외부에서 누적된 reserved set. mangle 시작 시
    /// 내부 reserved_names 에 복사된다. borrowed — caller 소유 유지.
    external_reserved: ?*const std.StringHashMap(void) = null,
};

/// Liveness 기반 mangling.
pub fn mangle(allocator: std.mem.Allocator, input: MangleInput) !ManglerResult {
    const scopes = input.scopes;
    const symbols = input.symbols;
    const scope_maps = input.scope_maps;
    const references = input.references;
    const source = input.source;
    const skip_symbols = input.skip_symbols;

    const scope_count = scopes.len;
    const symbol_count = symbols.len;

    if (scope_count == 0 or symbol_count == 0) {
        return .{
            .renames = std.AutoHashMap(u32, []const u8).init(allocator),
            .allocator = allocator,
        };
    }

    // ================================================================
    // Phase 1: children 역산 (parent 배열 -> children adjacency list)
    // ================================================================
    const children = try buildChildrenList(allocator, scopes);
    defer allocator.free(children.offsets);
    defer allocator.free(children.list);

    // ================================================================
    // Phase 2: per-symbol liveness BitSet 계산
    // ================================================================
    // 각 symbol이 어느 scope에서 alive한지 추적.
    // alive = 선언 scope에서 참조 scope까지의 ancestor 경로 전체.
    //
    // 벌크 할당: symbol_count개의 mask 배열을 단일 버퍼로 할당하여
    // 개별 DynamicBitSet.initEmpty 대신 O(1) 할당.
    const MaskInt = std.DynamicBitSetUnmanaged.MaskInt;
    const masks_per_symbol = (scope_count + @bitSizeOf(MaskInt) - 1) / @bitSizeOf(MaskInt);
    const all_masks = try allocator.alloc(MaskInt, symbol_count * masks_per_symbol);
    defer allocator.free(all_masks);
    @memset(all_masks, 0);

    var symbol_liveness = try allocator.alloc(std.DynamicBitSet, symbol_count);
    defer allocator.free(symbol_liveness);
    for (symbol_liveness, 0..) |*bs, i| {
        const start = i * masks_per_symbol;
        bs.* = .{
            .unmanaged = .{
                .masks = @ptrCast(all_masks[start..].ptr),
                .bit_length = scope_count,
            },
            .allocator = allocator,
        };
    }

    // 선언 scope 자체를 alive로 표시
    for (symbols, 0..) |sym, i| {
        if (!sym.scope_id.isNone() and sym.scope_id.toIndex() < scope_count) {
            symbol_liveness[i].set(sym.scope_id.toIndex());
        }
    }

    // references: 참조 scope에서 선언 scope까지 ancestor 경로를 모두 set
    for (references) |r| {
        const sym_idx: u32 = @intFromEnum(r.symbol_id);
        if (sym_idx >= symbol_count) continue;
        const decl_scope = symbols[sym_idx].scope_id;
        if (decl_scope.isNone()) continue;
        markAncestorPath(&symbol_liveness[sym_idx], scopes, r.scope_id, decl_scope);
    }

    // ================================================================
    // Phase 3: Slot 할당 (DFS + 그래프 컬러링)
    // ================================================================
    const Slot = struct {
        liveness: std.DynamicBitSet,
        total_refs: u32,
    };

    var slots: std.ArrayListUnmanaged(Slot) = .empty;
    defer {
        for (slots.items) |*s| s.liveness.deinit();
        slots.deinit(allocator);
    }

    // symbol_idx -> slot_id (null이면 미할당)
    var symbol_to_slot = try allocator.alloc(?u32, symbol_count);
    defer allocator.free(symbol_to_slot);
    @memset(symbol_to_slot, null);

    // scope별 bindings를 symbol_idx 기준으로 정렬하기 위한 임시 버퍼
    var binding_buf: std.ArrayListUnmanaged(SymBinding) = .empty;
    defer binding_buf.deinit(allocator);

    // mangling에서 제외된 심볼의 원본 이름은 그대로 출력에 남거나(shouldSkip,
    // blocksMangling) 번들러가 별도로 canonicalize하므로(skip_symbols), base54가
    // 해당 이름을 다른 slot에 재할당하면 동일 스코프 중복 선언(#1609: 9-param
    // pipe의 1글자 param) 또는 shadowing 오염으로 이어진다. 이들 이름을 Phase 4
    // 이름 할당에서 reserved로 취급한다.
    var reserved_names = std.StringHashMap(void).init(allocator);
    defer reserved_names.deinit();

    // #1760: Phase A 에서 누적된 예약어를 Phase B 가 물려받음.
    if (input.external_reserved) |ext| {
        var it = ext.keyIterator();
        while (it.next()) |k| try reserved_names.put(k.*, {});
    }

    // DFS로 scope tree 순회
    var dfs_stack: std.ArrayListUnmanaged(u32) = .empty;
    defer dfs_stack.deinit(allocator);
    try dfs_stack.append(allocator, 0); // root scope

    while (dfs_stack.items.len > 0) {
        const scope_idx = dfs_stack.pop().?;

        // 이 scope의 bindings 수집 (결정론적 순서를 위해 symbol_idx 정렬)
        binding_buf.items.len = 0;
        if (scope_idx < scope_maps.len) {
            var sit = scope_maps[@intCast(scope_idx)].iterator();
            while (sit.next()) |entry| {
                const sym_idx: u32 = @intCast(entry.value_ptr.*);
                if (sym_idx >= symbol_count) continue;

                const sym = symbols[sym_idx];
                const name = entry.key_ptr.*;

                // skip 판정 — 아래 세 경로는 원본 이름이 출력에 살아남으므로 reserved.
                // #1757: 원본 이름과 `canonical_name` (top-level mangler rename 결과)
                // 둘 다 등록해 nested mangler 독립 base54 counter 가 같은 이름 배정 방지.
                if (shouldSkip(sym, name)) {
                    try reserveNameFor(&reserved_names, sym, name);
                    continue;
                }
                // direct eval / with 스코프의 바인딩은 mangling 차단 (#1258)
                if (!sym.scope_id.isNone()) {
                    const s_idx = sym.scope_id.toIndex();
                    if (s_idx < scopes.len and scopes[s_idx].blocksMangling()) {
                        try reserveNameFor(&reserved_names, sym, name);
                        continue;
                    }
                }
                if (skip_symbols) |ss| {
                    if (sym_idx < ss.capacity() and ss.isSet(sym_idx)) {
                        try reserveNameFor(&reserved_names, sym, name);
                        continue;
                    }
                }

                try binding_buf.append(allocator, .{ .sym_idx = sym_idx, .name = name });
            }
        }

        // 결정론적 순서: symbol_idx 오름차순
        std.mem.sortUnstable(SymBinding, binding_buf.items, {}, struct {
            fn cmp(_: void, a: SymBinding, b: SymBinding) bool {
                return a.sym_idx < b.sym_idx;
            }
        }.cmp);

        // 각 binding에 slot 할당
        for (binding_buf.items) |binding| {
            const sym_idx = binding.sym_idx;
            if (symbol_to_slot[sym_idx] != null) continue; // 이미 할당됨 (var 호이스팅 등)

            // 기존 slot 중 재사용 가능한 것 찾기:
            // slot의 liveness가 이 symbol의 liveness와 겹치지 않으면 재사용 가능
            var reused_slot: ?u32 = null;
            for (slots.items, 0..) |*slot, slot_idx| {
                // slot.liveness와 symbol_liveness[sym_idx]가 교집합이 없으면 재사용 가능
                if (!bitsetIntersects(slot.liveness, symbol_liveness[sym_idx])) {
                    reused_slot = @intCast(slot_idx);
                    break;
                }
            }

            if (reused_slot) |slot_id| {
                symbol_to_slot[sym_idx] = slot_id;
                // slot의 liveness 확장 (합집합)
                slots.items[slot_id].liveness.setUnion(symbol_liveness[sym_idx]);
                slots.items[slot_id].total_refs += symbols[sym_idx].reference_count;
            } else {
                // 새 slot 생성
                const new_slot_id: u32 = @intCast(slots.items.len);
                var new_liveness = try std.DynamicBitSet.initEmpty(allocator, scope_count);
                new_liveness.setUnion(symbol_liveness[sym_idx]);
                try slots.append(allocator, .{
                    .liveness = new_liveness,
                    .total_refs = symbols[sym_idx].reference_count,
                });
                symbol_to_slot[sym_idx] = new_slot_id;
            }
        }

        // children을 DFS stack에 push (역순으로 넣어서 작은 인덱스부터 처리)
        const start = children.offsets[scope_idx];
        const end = if (scope_idx + 1 < children.offsets.len) children.offsets[scope_idx + 1] else @as(u32, @intCast(children.list.len));
        var ci = end;
        while (ci > start) {
            ci -= 1;
            try dfs_stack.append(allocator, children.list[ci]);
        }
    }

    // ================================================================
    // Phase 4: 빈도순 이름 할당 (Base54)
    // ================================================================
    const slot_count = slots.items.len;
    if (slot_count == 0) {
        return .{
            .renames = std.AutoHashMap(u32, []const u8).init(allocator),
            .allocator = allocator,
        };
    }

    // slot 정렬: total_refs 내림차순, 동률이면 slot_id 오름차순
    const sorted_slots = try allocator.alloc(SlotSortEntry, slot_count);
    defer allocator.free(sorted_slots);
    for (sorted_slots, 0..) |*entry, i| {
        entry.* = .{
            .slot_id = @intCast(i),
            .total_refs = slots.items[i].total_refs,
        };
    }
    std.mem.sortUnstable(SlotSortEntry, sorted_slots, {}, struct {
        fn cmp(_: void, a: SlotSortEntry, b: SlotSortEntry) bool {
            if (a.total_refs != b.total_refs) return a.total_refs > b.total_refs;
            return a.slot_id < b.slot_id;
        }
    }.cmp);

    // slot_id -> base54 이름 할당
    var slot_names = try allocator.alloc(?[]const u8, slot_count);
    defer {
        // slot_names 자체만 해제 (이름 문자열은 renames가 소유)
        allocator.free(slot_names);
    }
    @memset(slot_names, null);

    var name_counter: u32 = input.starting_name_counter;
    var name_buf: [8]u8 = undefined;
    var slot_name_length_sum: usize = 0;
    for (sorted_slots) |entry| {
        // 예약어/글로벌 + mangling 제외 심볼의 원본 이름은 건너뜀 (#1609)
        var name = base54(name_counter, &name_buf);
        name_counter += 1;
        while (isReservedOrGlobal(name) or reserved_names.contains(name)) {
            name = base54(name_counter, &name_buf);
            name_counter += 1;
        }
        slot_names[entry.slot_id] = try allocator.dupe(u8, name);
        slot_name_length_sum += name.len;
    }

    // ================================================================
    // Phase 5: renames 맵 생성
    // ================================================================
    var renames = std.AutoHashMap(u32, []const u8).init(allocator);
    errdefer {
        var it = renames.valueIterator();
        while (it.next()) |v| allocator.free(v.*);
        renames.deinit();
    }

    for (symbol_to_slot, 0..) |maybe_slot, sym_idx| {
        const slot_id = maybe_slot orelse continue;
        const new_name = slot_names[slot_id] orelse continue;
        const sym = symbols[sym_idx];
        // Bundler 합성 심볼(#1338)은 source AST에 식별자 참조가 없고 span이 (0,0).
        // rename은 parser AST의 identifier 노드를 바꾸는 것이라 무의미 — skip.
        if (sym.isSynthetic()) continue;
        // string_table-backed span (Ast.STRING_TABLE_BIT). parser/transformer 가
        // `addString` 으로 합성한 identifier 가 semantic 에서 const/let declaration
        // 으로 재분석될 때 발생 (#1751). 이런 심볼의 이름은 source 에 존재하지 않고
        // string_table 에만 있으므로 원본 텍스트 비교가 의미 없고 slice 는 OOB.
        // 현재 mangler 는 `source: []const u8` 만 받아서 string_table 접근 불가 —
        // 합성 이름은 rename 대상에서 제외한다 (mangle 해도 renames 맵이 span-offset
        // 기반 codegen 과 맞물리지 않아 효과도 없음).
        if (sym.name.start & 0x80000000 != 0) continue;
        const orig_name = source[sym.name.start..sym.name.end];

        if (std.mem.eql(u8, orig_name, new_name)) continue;

        // 이미 이름이 할당된 slot에서 왔으므로 dupe 필요 (여러 symbol이 같은 slot 공유)
        try renames.put(@intCast(sym_idx), try allocator.dupe(u8, new_name));
    }

    // slot_names에서 renames로 복사되지 않은 이름 해제
    for (slot_names) |maybe_name| {
        if (maybe_name) |name_str| {
            // renames에 들어간 이름인지 확인하지 않고, 항상 원본을 해제.
            // renames에는 dupe된 복사본이 들어가므로 원본 해제가 안전.
            allocator.free(name_str);
        }
    }

    return .{
        .renames = renames,
        .allocator = allocator,
        .stats = .{
            .slot_count = slot_count,
            .slot_name_length_sum = slot_name_length_sum,
            .name_counter_final = name_counter,
            .reserved_size = reserved_names.count(),
            .renamed_symbol_count = renames.count(),
        },
    };
}

// ============================================================
// Liveness 헬퍼
// ============================================================

/// ref_scope에서 decl_scope까지 ancestor 경로의 모든 scope를 liveness에 set.
fn markAncestorPath(
    liveness: *std.DynamicBitSet,
    scopes: []const Scope,
    ref_scope: ScopeId,
    decl_scope: ScopeId,
) void {
    var cur = ref_scope;
    while (!cur.isNone()) {
        const idx = cur.toIndex();
        if (idx >= scopes.len) break;
        liveness.set(idx);
        if (cur.toIndex() == decl_scope.toIndex()) break;
        cur = scopes[idx].parent;
    }
}

/// 두 BitSet이 교집합을 가지는지 검사 (하나라도 겹치면 true).
/// std.DynamicBitSet에는 non-destructive 교집합 검사가 없으므로 직접 구현.
fn bitsetIntersects(a: std.DynamicBitSet, b: std.DynamicBitSet) bool {
    const MaskInt = std.DynamicBitSetUnmanaged.MaskInt;
    const bits_per_mask = @bitSizeOf(MaskInt);
    const na = (a.unmanaged.bit_length + bits_per_mask - 1) / bits_per_mask;
    const nb = (b.unmanaged.bit_length + bits_per_mask - 1) / bits_per_mask;
    const len = @min(na, nb);
    for (a.unmanaged.masks[0..len], b.unmanaged.masks[0..len]) |ma, mb| {
        if (ma & mb != 0) return true;
    }
    return false;
}

// ============================================================
// Children 역산 (parent -> children adjacency list)
// ============================================================

const ChildrenList = struct {
    /// offsets[scope_id] = children_list 내 시작 인덱스. 길이 = scope_count + 1.
    offsets: []u32,
    /// flat children 배열.
    list: []u32,
};

fn buildChildrenList(allocator: std.mem.Allocator, scopes: []const Scope) !ChildrenList {
    const n = scopes.len;

    // Pass 1: 각 scope의 children 수 카운트
    var counts = try allocator.alloc(u32, n);
    defer allocator.free(counts);
    @memset(counts, 0);
    for (scopes[1..]) |s| {
        if (!s.parent.isNone() and s.parent.toIndex() < n) {
            counts[s.parent.toIndex()] += 1;
        }
    }

    // Pass 2: prefix sum -> offsets
    var offsets = try allocator.alloc(u32, n + 1);
    offsets[0] = 0;
    for (0..n) |i| {
        offsets[i + 1] = offsets[i] + counts[i];
    }
    const total_children = offsets[n];

    // Pass 3: 채우기
    var list = try allocator.alloc(u32, total_children);
    // counts를 write pointer로 재사용
    @memset(counts, 0);
    for (scopes[1..], 1..) |s, i| {
        if (!s.parent.isNone() and s.parent.toIndex() < n) {
            const pi = s.parent.toIndex();
            list[offsets[pi] + counts[pi]] = @intCast(i);
            counts[pi] += 1;
        }
    }

    return .{ .offsets = offsets, .list = list };
}

// ============================================================
// Base54 이름 생성 (oxc 호환 문자 순서)
// ============================================================

/// Base54 문자열. gzip 최적화를 위해 빈도 높은 문자가 앞에 배치.
/// oxc: crates/oxc_mangler/src/base54.rs
const BASE54_CHARS = "etnriaoscludfpmhg_vybxSCwTEDOkAjMNPFILRzBVHUWGKqJYXZQ$0123456789";

/// 숫자 n을 Base54 식별자로 인코딩.
/// 첫 글자: 54개 (숫자 제외, JS IdentifierStart)
/// 후속 글자: 64개 (숫자 포함, JS IdentifierPart)
pub fn base54(n: u32, buf: *[8]u8) []const u8 {
    const FIRST_BASE: u32 = 54;
    const REST_BASE: u32 = 64;

    var num = n;
    var len: usize = 0;

    // 첫 글자
    buf[len] = BASE54_CHARS[num % FIRST_BASE];
    len += 1;
    num /= FIRST_BASE;

    // 나머지 글자
    while (num > 0) {
        num -= 1;
        buf[len] = BASE54_CHARS[num % REST_BASE];
        len += 1;
        num /= REST_BASE;
    }

    return buf[0..len];
}

// ============================================================
// 내부 타입
// ============================================================

const SymBinding = struct {
    sym_idx: u32,
    name: []const u8,
};

const SlotSortEntry = struct {
    slot_id: u32,
    total_refs: u32,
};

// ============================================================
// mangling 제외 판정
// ============================================================

fn shouldSkip(sym: Symbol, name: []const u8) bool {
    if (sym.decl_flags.is_exported or sym.decl_flags.is_default_export) return true;
    if (sym.decl_flags.is_import) return true;
    if (std.mem.eql(u8, name, "arguments")) return true;
    if (name.len <= 1) return true;
    return false;
}

/// Phase 3 의 세 skip 경로 공용: 원본 이름 + `canonical_name` (top-level mangler
/// rename 결과) 둘 다 reserved 로 등록. `StringHashMap.put` 은 idempotent.
fn reserveNameFor(reserved: *std.StringHashMap(void), sym: Symbol, name: []const u8) !void {
    try reserved.put(name, {});
    if (sym.hasCanonicalName()) try reserved.put(sym.canonical_name, {});
}

// ============================================================
// 예약어/글로벌 체크
// ============================================================

pub fn isReservedOrGlobal(name: []const u8) bool {
    // JS 예약어 + 리터럴 + 글로벌 (길이 2~6만 체크 — 1글자는 충돌 없고 7글자+는 base54에서 도달 어려움)
    const reserved = [_][]const u8{
        // 2글자
        "do",     "if",     "in",     "of",
        // 3글자
        "for",    "let",    "new",    "try",
        "var",    "NaN",
        // 4글자
           "case",   "else",
        "enum",   "null",   "this",   "true",
        "void",   "with",
        // 5글자
          "await",  "break",
        "catch",  "class",  "const",  "false",
        "super",  "throw",  "while",  "yield",
        // 6글자
        "delete", "export", "import", "return",
        "switch", "typeof",
    };
    for (reserved) |r| {
        if (std.mem.eql(u8, name, r)) return true;
    }
    // #1618 / #1621: bundler runtime helper 축약 이름 — base54 가 사용자 심볼에
    //                동일 이름을 배정해 preamble 정의를 덮어쓰는 것을 방지.
    //                #1752: `runtime_helper_names.PAIRS` 공용 모듈 — 단일 소스 + mangler
    //                가 bundler 를 import 하지 않도록 레이어 역전 회피.
    const names = @import("../runtime_helper_names.zig");
    for (names.ALL_SHORT_NAMES) |s| {
        if (std.mem.eql(u8, name, s)) return true;
    }
    return false;
}

// ============================================================
// 번들 모드 전용: Base54 이름 생성 (예약어 자동 스킵)
// ============================================================

/// Base54 이름을 하나 생성 (외부에서 카운터 관리). 예약어는 자동 스킵.
pub fn nextBase54Name(counter: *u32, buf: *[8]u8) []const u8 {
    var name = base54(counter.*, buf);
    counter.* += 1;
    while (isReservedOrGlobal(name)) {
        name = base54(counter.*, buf);
        counter.* += 1;
    }
    return name;
}
