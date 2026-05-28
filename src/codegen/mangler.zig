//! ZNTC Identifier Mangler — esbuild 식 scope-nesting slot 할당
//!
//! 스코프 트리를 따라 로컬 변수 이름을 짧은 이름으로 교체한다. 번들 크기를 ~70% 절감하는 핵심 최적화.
//!
//! 알고리즘 (esbuild renamer.go / oxc 기반, O(N)):
//!   1. parent 배열에서 children 역산 (O(n), 2-pass)
//!   2~3. scope tree DFS — 자식 scope 가 부모의 현재 slot 카운트를 상속해 시작. 형제는 같은 slot
//!        번호를 구성적으로 재사용(동시 live 불가 → 충돌 0), 자식 binding 은 부모 slot 이후만 받아
//!        closure-shadow 불가. liveness BitSet/graph-coloring first-fit 스캔 없음 → 선형.
//!   4. 빈도순 이름 할당 (Base54, 고빈도 심볼이 짧은 이름)
//!
//! 규칙:
//!   - export된 심볼은 mangling 하지 않음
//!   - import 바인딩은 mangling 하지 않음 (번들러가 처리)
//!   - 예약어/글로벌 이름은 건너뜀
//!   - 함수 파라미터도 mangling 대상
//!
//! 참고:
//!   - esbuild: internal/renamer/renamer.go (assignNestedScopeSlots)
//!   - oxc: crates/oxc_mangler/src/lib.rs

const std = @import("std");
const Scope = @import("../semantic/scope.zig").Scope;
const ScopeId = @import("../semantic/scope.zig").ScopeId;
const Symbol = @import("../semantic/symbol.zig").Symbol;
const SymbolKind = @import("../semantic/symbol.zig").SymbolKind;
const Reference = @import("../semantic/symbol.zig").Reference;
const Span = @import("../lexer/token.zig").Span;

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
    /// Phase 4 base54 발급 루프에서 reserved/global 충돌로 skip 된 1글자 후보 수.
    /// 총 skip 수는 `name_counter_final - starting_name_counter - slot_count` 로 derivable
    /// 이지만, 1-char skip 은 카운터 분포를 모르면 알 수 없어 별도 측정.
    reserved_skips_1char: usize = 0,
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
    /// 모든 모듈에 공유되는 reserved (runtime helper 등). 매 모듈마다 복제하면
    /// N×G 알로케이션 — caller 가 한 번만 build 후 borrow 로 share. lookup 시
    /// internal/external_reserved 와 함께 검사하므로 internal copy 안 함.
    /// `external_reserved` 가 *per-module* (예: Phase A 의 이 모듈 mangled 이름)
    /// 라면 본 필드는 *전 모듈 공통* (예: runtime helper 이름) 으로 분리된다.
    external_reserved_global: ?*const std.StringHashMap(void) = null,
};

/// scope-nesting 기반 mangling.
pub fn mangle(allocator: std.mem.Allocator, input: MangleInput) !ManglerResult {
    const scopes = input.scopes;
    const symbols = input.symbols;
    const scope_maps = input.scope_maps;
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
    // Phase 2+3: slot 할당 (symbol_idx → slot_id + slot 별 ref 합)
    // ================================================================
    // symbol_idx -> slot_id (null이면 미할당)
    const symbol_to_slot = try allocator.alloc(?u32, symbol_count);
    defer allocator.free(symbol_to_slot);
    @memset(symbol_to_slot, null);

    // mangling 제외 심볼의 원본 이름(shouldSkip/blocksMangling)은 출력에 그대로 남으므로
    // base54 가 같은 이름을 다른 slot 에 재할당하면 중복 선언(#1609)/shadow 오염 → Phase 4
    // 발급에서 reserved 로 회피. #1760: Phase A 누적 예약어(external_reserved)도 seed.
    var reserved_names = std.StringHashMap(void).init(allocator);
    defer reserved_names.deinit();
    if (input.external_reserved) |ext| {
        var it = ext.keyIterator();
        while (it.next()) |k| try reserved_names.put(k.*, {});
    }

    // slot_refs[slot_id] = 그 slot 을 공유하는 심볼들의 reference_count 합 (Phase 4 빈도 naming).
    // esbuild/oxc 식 scope-nesting (O(N)): 자식 scope 가 부모 slot 카운트를 상속 → 형제는 같은
    // slot 번호를 구성적으로 재사용(동시 live 불가 → 충돌 0), 자식 binding 은 부모 slot 번호
    // 이후만 받아 closure-shadow 불가. liveness graph-coloring 과 동일 출력을 O(N²)→O(N) 으로 계산.
    var slot_refs = try assignSlotsScopeNesting(allocator, scopes, symbols, scope_maps, skip_symbols, symbol_count, children, symbol_to_slot, &reserved_names);
    defer slot_refs.deinit(allocator);

    // ================================================================
    // Phase 4: 빈도순 이름 할당 (Base54)
    // ================================================================
    const slot_count = slot_refs.items.len;
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
            .total_refs = slot_refs.items[i],
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
    var reserved_skips_1char: usize = 0;
    for (sorted_slots) |entry| {
        // 예약어/글로벌 + mangling 제외 심볼의 원본 이름은 건너뜀 (#1609).
        // K2-perf (#46): external_reserved_global 은 internal copy 하지 않고 lookup 시 직접
        // 검사 — caller 가 모듈마다 복제하지 않고 한 번만 build 후 share.
        const name = nextNonReservedBase54NameTwo(
            &name_counter,
            &name_buf,
            &reserved_names,
            input.external_reserved_global,
            &reserved_skips_1char,
        );
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
        const orig_name = sym.nameText(source);

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
            .reserved_skips_1char = reserved_skips_1char,
        },
    };
}

// ============================================================
// Slot 할당 (Phase 2+3) — 공유 binding 수집 + 두 알고리즘
// ============================================================

/// 한 scope 의 binding 을 수집해 `binding_buf` 에 채운다(sym_idx 오름차순 정렬).
/// shouldSkip/blocksMangling/skip_symbols 로 mangle 제외 심볼은 제외하고, 출력에 남는
/// 원본 이름은 `reserved_names` 에 등록. 신/구 slot 알고리즘이 공유 (동일 분류 보장).
fn collectScopeBindings(
    scope_idx: u32,
    scope_maps: []const std.StringHashMap(usize),
    symbols: []const Symbol,
    scopes: []const Scope,
    skip_symbols: ?std.DynamicBitSet,
    symbol_count: usize,
    binding_buf: *std.ArrayListUnmanaged(SymBinding),
    reserved_names: *std.StringHashMap(void),
    allocator: std.mem.Allocator,
) !void {
    binding_buf.items.len = 0;
    if (scope_idx < scope_maps.len) {
        var sit = scope_maps[@intCast(scope_idx)].iterator();
        while (sit.next()) |entry| {
            const sym_idx: u32 = @intCast(entry.value_ptr.*);
            if (sym_idx >= symbol_count) continue;

            const sym = symbols[sym_idx];
            const name = entry.key_ptr.*;

            // skip 판정 — 원본 이름이 출력에 살아남는 1글자/arguments 만 reserved.
            if (shouldSkip(sym, name)) {
                if (name.len <= 1 or std.mem.eql(u8, name, "arguments")) {
                    try reserved_names.put(name, {});
                }
                continue;
            }
            // direct eval / with 스코프 바인딩(#1258): 동적 lookup 대상이라 원본 이름 reserve.
            if (!sym.scope_id.isNone()) {
                const s_idx = sym.scope_id.toIndex();
                if (s_idx < scopes.len and scopes[s_idx].blocksMangling()) {
                    try reserved_names.put(name, {});
                    continue;
                }
            }
            // skip_symbols (번들 module-scope): nested mangler 미관리, reserve 안 함
            // (mangled name 은 external_reserved 보유, 원본 reserve 시 1-char 풀 잠식).
            if (skip_symbols) |ss| {
                if (sym_idx < ss.capacity() and ss.isSet(sym_idx)) continue;
            }

            try binding_buf.append(allocator, .{ .sym_idx = sym_idx, .name = name });
        }
    }

    // 결정론적 순서: symbol_idx 오름차순.
    std.mem.sortUnstable(SymBinding, binding_buf.items, {}, struct {
        fn cmp(_: void, a: SymBinding, b: SymBinding) bool {
            return a.sym_idx < b.sym_idx;
        }
    }.cmp);
}

/// esbuild/oxc 식 scope-nesting slot 할당 (O(N)). 자식 scope 가 부모의 현재 slot 카운트를
/// 상속받아 시작 → 형제 scope 는 같은 slot 번호를 구성적으로 재사용(동시 live 불가 → 충돌 0),
/// 자식 binding 은 부모 slot 번호 이후만 받아 closure-shadow 불가(#2956 subtree-liveness 동치).
/// liveness BitSet/graph-coloring first-fit 스캔 없음 → 대용량 단일 모듈도 선형.
/// `symbol_to_slot`/`reserved_names` 를 채우고 `slot_refs`(slot_id→ref 합)를 반환.
fn assignSlotsScopeNesting(
    allocator: std.mem.Allocator,
    scopes: []const Scope,
    symbols: []const Symbol,
    scope_maps: []const std.StringHashMap(usize),
    skip_symbols: ?std.DynamicBitSet,
    symbol_count: usize,
    children: ChildrenList,
    symbol_to_slot: []?u32,
    reserved_names: *std.StringHashMap(void),
) !std.ArrayListUnmanaged(u32) {
    var slot_refs: std.ArrayListUnmanaged(u32) = .empty;
    errdefer slot_refs.deinit(allocator);

    var binding_buf: std.ArrayListUnmanaged(SymBinding) = .empty;
    defer binding_buf.deinit(allocator);

    const Frame = struct { scope_idx: u32, start_slot: u32 };
    var stack: std.ArrayListUnmanaged(Frame) = .empty;
    defer stack.deinit(allocator);
    try stack.append(allocator, .{ .scope_idx = 0, .start_slot = 0 });

    while (stack.items.len > 0) {
        const frame = stack.pop().?;
        const scope_idx = frame.scope_idx;
        var local_slot = frame.start_slot;

        try collectScopeBindings(scope_idx, scope_maps, symbols, scopes, skip_symbols, symbol_count, &binding_buf, reserved_names, allocator);

        for (binding_buf.items) |binding| {
            const sym_idx = binding.sym_idx;
            if (symbol_to_slot[sym_idx] != null) continue; // 이미 할당됨 (var 호이스팅 등)
            const slot_id = local_slot;
            local_slot += 1;
            symbol_to_slot[sym_idx] = slot_id;
            while (slot_refs.items.len <= slot_id) try slot_refs.append(allocator, 0);
            slot_refs.items[slot_id] += symbols[sym_idx].reference_count;
        }

        // 자식은 부모의 현재 slot 카운트(local_slot)를 start 로 상속. 역순 push(결정성).
        const start = children.offsets[scope_idx];
        const end = if (scope_idx + 1 < children.offsets.len) children.offsets[scope_idx + 1] else @as(u32, @intCast(children.list.len));
        var ci = end;
        while (ci > start) {
            ci -= 1;
            try stack.append(allocator, .{ .scope_idx = children.list[ci], .start_slot = local_slot });
        }
    }

    return slot_refs;
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
    if (sym.isExported()) return true;
    if (sym.decl_flags.is_import) return true;
    // `const Foo = class Bar {}` 의 inner `Bar` (#2197). mangle 시 `.name` 프로퍼티도
    // 함께 바뀌므로 spec 준수를 위해 원본 이름 보존.
    if (sym.decl_flags.is_class_expr_name) return true;
    if (std.mem.eql(u8, name, "arguments")) return true;
    if (name.len <= 1) return true;
    return false;
}

// ============================================================
// 예약어/글로벌 체크
// ============================================================

pub fn isReservedOrGlobal(name: []const u8) bool {
    // Legacy CJS wrap alias path 의 단축 이름 (`e`, `m`). Bundler 기본 경로는
    // Node/Metro 호환성을 위해 `(exports, module)` 을 유지하지만, 별도 alias 경로가
    // 켜질 때 mangler 가 같은 이름을 부여하지 않도록 보존한다.
    if (name.len == 1 and (name[0] == 'e' or name[0] == 'm')) return true;
    // JS 예약어 + 리터럴 + 글로벌 (길이 2~6만 체크 — 1글자는 'e'/'m' 외엔 충돌 없고
    // 7글자+는 base54에서 도달 어려움)
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

/// `nextBase54Name` + 외부 reserved set 충돌까지 함께 skip. skip 시 1글자 후보였던
/// 횟수만 `skips_1char` 에 누적 (총 skip 수는 counter 차로 derivable).
pub fn nextNonReservedBase54Name(
    counter: *u32,
    buf: *[8]u8,
    reserved: *const std.StringHashMap(void),
    skips_1char: *usize,
) []const u8 {
    return nextNonReservedBase54NameTwo(counter, buf, reserved, null, skips_1char);
}

/// `nextNonReservedBase54Name` 의 2-set variant — 추가 reserved set (전 모듈 공유) 도 함께
/// 검사. caller 가 global set 을 모듈마다 복제하지 않고 한 번만 build 후 share 하는 hot-path
/// 용 (#1760 K2-perf). 한쪽이 null 이면 1-set 와 동등.
pub fn nextNonReservedBase54NameTwo(
    counter: *u32,
    buf: *[8]u8,
    reserved_a: *const std.StringHashMap(void),
    reserved_b: ?*const std.StringHashMap(void),
    skips_1char: *usize,
) []const u8 {
    var name = nextBase54Name(counter, buf);
    while (reserved_a.contains(name) or (reserved_b != null and reserved_b.?.contains(name))) {
        if (name.len == 1) skips_1char.* += 1;
        name = nextBase54Name(counter, buf);
    }
    return name;
}

test "mangle: string_table 기반 생성 심볼도 rename 결과에 포함" {
    const allocator = std.testing.allocator;

    const scopes = [_]Scope{
        .{ .parent = .none, .kind = .global, .is_strict = false, .symbol_count = 0 },
        .{ .parent = @enumFromInt(0), .kind = .function, .is_strict = false, .symbol_count = 1 },
    };

    const string_table_bit: u32 = 0x80000000;
    const symbols = [_]Symbol{
        .{
            .name = .{ .start = string_table_bit, .end = string_table_bit + 5 },
            .scope_id = @enumFromInt(1),
            .origin_scope = @enumFromInt(1),
            .kind = .variable_var,
            .decl_flags = SymbolKind.variable_var.declFlags(),
            .declaration_span = Span{ .start = string_table_bit, .end = string_table_bit + 5 },
            .reference_count = 2,
            .synthetic_name = "_this",
        },
    };

    var empty_scope = std.StringHashMap(usize).init(allocator);
    defer empty_scope.deinit();
    var function_scope = std.StringHashMap(usize).init(allocator);
    defer function_scope.deinit();
    try function_scope.put("_this", 0);

    const scope_maps = [_]std.StringHashMap(usize){ empty_scope, function_scope };
    const refs = [_]Reference{
        .{
            .node_index = @enumFromInt(0),
            .scope_id = @enumFromInt(1),
            .symbol_id = @enumFromInt(0),
            .flags = .{ .read = true },
        },
    };

    var result = try mangle(allocator, .{
        .scopes = &scopes,
        .symbols = &symbols,
        .scope_maps = &scope_maps,
        .references = &refs,
        .source = "",
    });
    defer result.deinit();

    // base54 첫 이름 'e' 는 legacy CJS wrap alias 용으로 reserved (다음 후보 't').
    try std.testing.expectEqualStrings("t", result.renames.get(0).?);
}

test "mangle: scope-nesting 형제 scope 가 같은 slot 재사용 (충돌 0)" {
    const allocator = std.testing.allocator;

    // scope tree: 0(root) → 1(func), 2(func) — 형제.
    const scopes = [_]Scope{
        .{ .parent = .none, .kind = .global, .is_strict = false, .symbol_count = 0 },
        .{ .parent = @enumFromInt(0), .kind = .function, .is_strict = false, .symbol_count = 1 },
        .{ .parent = @enumFromInt(0), .kind = .function, .is_strict = false, .symbol_count = 1 },
    };
    const symbols = [_]Symbol{
        .{
            .name = .{ .start = 0, .end = 0 },
            .scope_id = @enumFromInt(1),
            .origin_scope = @enumFromInt(1),
            .kind = .variable_var,
            .decl_flags = SymbolKind.variable_var.declFlags(),
            .declaration_span = Span{ .start = 0, .end = 0 },
            .reference_count = 5,
            .synthetic_name = "alpha",
        },
        .{
            .name = .{ .start = 0, .end = 0 },
            .scope_id = @enumFromInt(2),
            .origin_scope = @enumFromInt(2),
            .kind = .variable_var,
            .decl_flags = SymbolKind.variable_var.declFlags(),
            .declaration_span = Span{ .start = 0, .end = 0 },
            .reference_count = 3,
            .synthetic_name = "beta",
        },
    };
    var s_root = std.StringHashMap(usize).init(allocator);
    defer s_root.deinit();
    var s1 = std.StringHashMap(usize).init(allocator);
    defer s1.deinit();
    try s1.put("alpha", 0);
    var s2 = std.StringHashMap(usize).init(allocator);
    defer s2.deinit();
    try s2.put("beta", 1);
    const scope_maps = [_]std.StringHashMap(usize){ s_root, s1, s2 };

    var result = try mangle(allocator, .{
        .scopes = &scopes,
        .symbols = &symbols,
        .scope_maps = &scope_maps,
        .references = &.{},
        .source = "",
    });
    defer result.deinit();

    // 형제 scope 의 두 binding 은 동시 live 불가 → 같은 slot → 같은 mangled 이름.
    const a = result.renames.get(0) orelse return error.NoRename0;
    const b = result.renames.get(1) orelse return error.NoRename1;
    try std.testing.expectEqualStrings(a, b);
}

test "mangle: scope-nesting 자식 binding 은 부모 slot 을 안 받음 (shadow 방지 #2956)" {
    const allocator = std.testing.allocator;

    // scope tree: 0(root) → 1(func) → 2(block). outer=scope1, inner=scope2(자식).
    const scopes = [_]Scope{
        .{ .parent = .none, .kind = .global, .is_strict = false, .symbol_count = 0 },
        .{ .parent = @enumFromInt(0), .kind = .function, .is_strict = false, .symbol_count = 1 },
        .{ .parent = @enumFromInt(1), .kind = .block, .is_strict = false, .symbol_count = 1 },
    };
    const symbols = [_]Symbol{
        .{
            .name = .{ .start = 0, .end = 0 },
            .scope_id = @enumFromInt(1),
            .origin_scope = @enumFromInt(1),
            .kind = .variable_var,
            .decl_flags = SymbolKind.variable_var.declFlags(),
            .declaration_span = Span{ .start = 0, .end = 0 },
            .reference_count = 5,
            .synthetic_name = "outer",
        },
        .{
            .name = .{ .start = 0, .end = 0 },
            .scope_id = @enumFromInt(2),
            .origin_scope = @enumFromInt(2),
            .kind = .variable_let,
            .decl_flags = SymbolKind.variable_let.declFlags(),
            .declaration_span = Span{ .start = 0, .end = 0 },
            .reference_count = 3,
            .synthetic_name = "inner",
        },
    };
    var s_root = std.StringHashMap(usize).init(allocator);
    defer s_root.deinit();
    var s1 = std.StringHashMap(usize).init(allocator);
    defer s1.deinit();
    try s1.put("outer", 0);
    var s2 = std.StringHashMap(usize).init(allocator);
    defer s2.deinit();
    try s2.put("inner", 1);
    const scope_maps = [_]std.StringHashMap(usize){ s_root, s1, s2 };

    var result = try mangle(allocator, .{
        .scopes = &scopes,
        .symbols = &symbols,
        .scope_maps = &scope_maps,
        .references = &.{},
        .source = "",
    });
    defer result.deinit();

    // 자식 scope 의 inner 가 부모 outer 와 다른 slot → 다른 이름 (shadow 시 ReferenceError 방지).
    const o = result.renames.get(0) orelse return error.NoRenameOuter;
    const i = result.renames.get(1) orelse return error.NoRenameInner;
    try std.testing.expect(!std.mem.eql(u8, o, i));
}
