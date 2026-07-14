//! Dead-store pruning helpers used by bundler emission.
//!
//! ## 이 패스가 기대는 가정과 그 한계 (#4503)
//!
//! 이 패스는 "같은 statement list 안의 두 store 사이에 read 가 없으면 앞 store 는 죽었다"
//! 로 판정한다. 이때 "사이" 는 `Reference` 배열의 위치(`ref_pos`, 즉 **소스 순서**)로
//! 재는데, 소스 순서가 실행 순서와 같은 것은 **한 함수의 한 활성화(activation) 안에서
//! straight-line 으로 흐를 때뿐**이다. 아래 세 경우엔 그 가정이 깨져서 살아 있는 store 를
//! 지우는 무성 오컴파일이 났다:
//!
//!   1. **클로저 읽기** (#4503) — `buf = t; flush(); buf = "";` 에서 `flush` 가 `buf` 를
//!      클로저로 읽으면, 그 read 의 소스 위치는 두 store 밖(보통 앞)이라 `hasReadBetween`
//!      이 못 본다. 실제로는 사이의 `flush()` 호출 때 읽힌다.
//!      → `readEscapesExecUnit`: read 가 write 와 **다른 실행 단위**(함수/클래스 본문)에
//!      하나라도 있으면 제거 금지.
//!
//!   2. **재진입(re-entrancy)** — read 와 write 가 *같은* 함수 안에 있어도, 그 변수가 함수
//!      **밖** 에 선언돼 있으면 호출이 겹칠 때 바인딩 하나를 공유한다. 두 store 사이의 호출이
//!      그 함수를 다시 부르거나(재귀), `await`/`yield` 로 다른 호출과 인터리빙되면 *다른
//!      활성화* 가 앞 store 의 값을 읽는다 — 소스 순서에는 전혀 나타나지 않는 read다.
//!      → `storeIsProtected` 의 "선언 실행 단위 == write 실행 단위" 조건.
//!
//!   3. **abrupt completion** — `x = 1; if (c) break lbl; x = 2;` 처럼 사이에서 흐름이
//!      끊기면 뒤 store 가 실행되지 않아 앞 store 의 값이 살아남는다.
//!      → `windowBreaksFlow`: 사이 statement 가 바깥 흐름을 끊으면(밖으로 나가는
//!      return/break/continue/throw) 제거 금지.
//!
//!   4. **mapped `arguments` aliasing** (#4514) — 비엄격(sloppy) 함수의 **파라미터** 는
//!      `arguments` 객체와 양방향 aliasing 이다 (ECMA-262 CreateMappedArgumentsObject).
//!      `arguments[0]` 읽기는 참조 배열에 파라미터의 read 로 잡히지 않으므로 두 store
//!      사이의 `arguments` 접근이 앞 store 의 값을 관측할 수 있다.
//!      → `storeIsProtected` 의 파라미터 차단.
//!
//! ## store 를 **지워도 되는가** — 값이 아니라 *평가 부수효과* (#4514)
//!
//! 위 1~4 는 "그 값을 읽는 코드가 있는가"(liveness) 다. 그것과 **별개** 로, 지우려는 store 의
//! RHS/초기화자가 **평가만으로 관측 가능한 효과** 를 낼 수 있으면 값이 죽었어도 지우면 안 된다:
//!   - `x = obj.p` — `p` 가 getter/Proxy trap 이면 호출이 사라진다
//!   - `x = a.b.c` — `a.b` 가 nullish 면 던져야 할 TypeError 가 사라진다
//!   - `x = undeclaredGlobal` — 던져야 할 ReferenceError 가 사라진다
//! 이 패스는 예전에 tree-shaking 용 `purity.isExprPure` 를 썼는데, 그건 member access 와
//! 미해결 식별자를 pure 로 친다 (esbuild 동일 — "선언을 안 만들어도 되는가" 기준).
//! → 지금은 문 자리 DCE 와 같은 엄격 술어 `purity.isRemovableAtStmtPos` 를 쓴다.
//!
//! 판정이 불확실하면 **항상 "유지"**(보수적). 크기 몇 바이트보다 정확성이 우선이다.
//! 반대로 *진짜* dead store — 함수 지역변수를 그 함수 안에서 덮어쓰는, DSE 수익의 대부분 —
//! 는 모든 가드를 통과하므로 계속 제거된다.

const std = @import("std");
const Module = @import("../module.zig").Module;
const ast_mod = @import("../../parser/ast.zig");
const Ast = ast_mod.Ast;
const NodeIndex = ast_mod.NodeIndex;
const ast_walk = @import("../../parser/ast_walk.zig");
const purity = @import("../purity.zig");
const TokenKind = @import("../../lexer/token.zig").Kind;
const semantic_symbol = @import("../../semantic/symbol.zig");
const Reference = semantic_symbol.Reference;
const Symbol = semantic_symbol.Symbol;
const scope_mod = @import("../../semantic/scope.zig");
const Scope = scope_mod.Scope;

const AssignmentInfo = struct {
    stmt_idx: u32,
    lhs_idx: u32,
    sym_idx: u32,
};

const RefKey = struct {
    symbol_id: u32,
    scope_id: u32,
};

const RefEvent = struct {
    ref_pos: u32,
    node_idx: u32,
    stmt_idx: u32,
    symbol_id: u32,
    scope_id: u32,
    flags: semantic_symbol.ReferenceFlags,

    fn isRead(self: RefEvent) bool {
        return self.flags.read;
    }

    fn isPureWrite(self: RefEvent) bool {
        return self.flags.write and !self.flags.read;
    }
};

/// 심볼별 "read 가 일어난 실행 단위" 요약 (`scope_mod.enclosingExecUnit` 기준).
///
/// write 와 *다른* 실행 단위에서 읽히는지만 알면 되므로, 첫 단위 하나 + "무조건 차단" 플래그로
/// 충분하다 (판정 O(1)).
const ReadUnits = struct {
    /// 처음 만난 read 의 실행 단위. read 가 하나도 없으면 `null` (→ 진짜 dead store).
    unit: ?u32 = null,
    /// 어떤 write 와 비교하든 무조건 차단:
    ///   - 서로 다른 실행 단위 두 곳 이상에서 read (둘 중 하나는 반드시 write 와 어긋난다), 또는
    ///   - 실행 단위를 못 구한 read 가 있음 (스코프 체인 이상 → 보수적으로 차단).
    blocked: bool = false,
};

const DeadStoreRefIndex = struct {
    const EventList = std.ArrayListUnmanaged(RefEvent);

    by_key: std.AutoHashMapUnmanaged(RefKey, EventList) = .empty,
    all_events: std.ArrayListUnmanaged(RefEvent) = .empty,
    declare_events: std.ArrayListUnmanaged(RefEvent) = .empty,
    /// symbol id → read 실행 단위 요약. 길이 == symbols.len.
    read_units: []ReadUnits = &.{},
    /// `read_units` 를 만들 때 쓴 스코프 트리. 질의 때 다른 slice 를 넘겨 단위가 어긋나는 일이
    /// 없도록 인덱스가 직접 들고 있는다.
    scopes: []const Scope = &.{},

    fn init(
        allocator: std.mem.Allocator,
        references: []const Reference,
        scopes: []const Scope,
        symbol_count: usize,
    ) !DeadStoreRefIndex {
        var index: DeadStoreRefIndex = .{ .scopes = scopes };
        errdefer index.deinit(allocator);

        index.read_units = try allocator.alloc(ReadUnits, symbol_count);
        @memset(index.read_units, .{});

        for (references, 0..) |ref, ref_pos| {
            const symbol_id: u32 = @intFromEnum(ref.symbol_id);
            const scope_id: u32 = @intFromEnum(ref.scope_id);

            // read 실행 단위 집계는 `scope_stmt_idx` 유무와 무관하게 **모든 참조** 를 본다.
            // stmt 인덱스가 없는 read 도 클로저 read 일 수 있으므로 놓치면 안 된다 (#4503).
            if (ref.flags.read and ref.isValueUse() and symbol_id < index.read_units.len) {
                const ru = &index.read_units[symbol_id];
                if (scope_mod.enclosingExecUnit(scopes, ref.scope_id)) |unit| {
                    if (ru.unit) |first| {
                        if (first != unit) ru.blocked = true;
                    } else {
                        ru.unit = unit;
                    }
                } else {
                    ru.blocked = true;
                }
            }

            if (ref.scope_stmt_idx == Reference.NO_STMT) continue;

            const event: RefEvent = .{
                .ref_pos = @intCast(ref_pos),
                .node_idx = @intFromEnum(ref.node_index),
                .stmt_idx = ref.scope_stmt_idx,
                .symbol_id = symbol_id,
                .scope_id = scope_id,
                .flags = ref.flags,
            };

            if (ref.flags.declare) {
                try index.declare_events.append(allocator, event);
                continue;
            }
            if (!ref.isValueUse()) continue;
            if (ref.node_index.isNone()) continue;

            try index.all_events.append(allocator, event);
            const key: RefKey = .{ .symbol_id = symbol_id, .scope_id = scope_id };
            const gop = try index.by_key.getOrPut(allocator, key);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(allocator, event);
        }

        return index;
    }

    fn deinit(self: *DeadStoreRefIndex, allocator: std.mem.Allocator) void {
        var it = self.by_key.valueIterator();
        while (it.next()) |events| {
            events.deinit(allocator);
        }
        self.by_key.deinit(allocator);
        self.all_events.deinit(allocator);
        self.declare_events.deinit(allocator);
        allocator.free(self.read_units);
        self.read_units = &.{};
    }

    /// `write_unit` 밖에서 이 심볼을 읽는 곳이 하나라도 있는가? (#4503 핵심 가드)
    ///
    /// true 면 그 read 는 두 store 사이의 **임의 호출 시점** 에 일어날 수 있어 `ref_pos` 기반
    /// "사이에 read 없음" 판정이 무효다 → dead store 제거 금지.
    /// 판정 불가(심볼 범위 밖)도 보수적으로 true.
    fn readEscapesExecUnit(self: *const DeadStoreRefIndex, symbol_id: u32, write_unit: u32) bool {
        if (symbol_id >= self.read_units.len) return true;
        const ru = self.read_units[symbol_id];
        if (ru.blocked) return true;
        const read_unit = ru.unit orelse return false; // read 자체가 없음 — 진짜 dead.
        return read_unit != write_unit;
    }

    fn findWriteForNode(self: *const DeadStoreRefIndex, symbol_id: u32, node_idx: u32) ?RefEvent {
        for (self.all_events.items) |event| {
            if (event.symbol_id == symbol_id and event.node_idx == node_idx and event.isPureWrite()) return event;
        }
        return null;
    }

    fn findUniquePureWriteInStmt(self: *const DeadStoreRefIndex, symbol_id: u32, stmt_idx: u32) ?RefEvent {
        var found: ?RefEvent = null;
        for (self.all_events.items) |event| {
            if (event.symbol_id != symbol_id) continue;
            if (event.stmt_idx != stmt_idx) continue;
            if (!event.isPureWrite()) continue;
            if (found != null) return null;
            found = event;
        }
        return found;
    }

    fn findWriteForAssignment(self: *const DeadStoreRefIndex, symbol_id: u32, node_idx: u32, stmt_idx: u32) ?RefEvent {
        return self.findWriteForNode(symbol_id, node_idx) orelse self.findUniquePureWriteInStmt(symbol_id, stmt_idx);
    }

    fn findDeclare(self: *const DeadStoreRefIndex, symbol_id: u32, scope_id: u32, stmt_idx: u32) ?RefEvent {
        for (self.declare_events.items) |event| {
            if (event.symbol_id == symbol_id and event.scope_id == scope_id and event.stmt_idx == stmt_idx) return event;
        }
        return null;
    }

    fn firstSameScopeEventAfter(self: *const DeadStoreRefIndex, event: RefEvent) ?RefEvent {
        const events = self.by_key.get(.{ .symbol_id = event.symbol_id, .scope_id = event.scope_id }) orelse return null;
        for (events.items) |candidate| {
            if (candidate.ref_pos <= event.ref_pos) continue;
            if (candidate.stmt_idx < event.stmt_idx) continue;
            return candidate;
        }
        return null;
    }

    /// `start_event` 다음에 같은 symbol 을 덮어쓰는 pure write event 를 반환한다.
    /// 사이에 read 가 있거나 같은 statement 안에서 read 가 같이 있으면 보존을 위해 null.
    /// closure 등 다른 scope 의 read 도 보존해야 하므로 read 검사는 모든 scope 를 본다.
    fn findOverwriteAfter(self: *const DeadStoreRefIndex, start_event: RefEvent) ?RefEvent {
        const next_event = self.firstSameScopeEventAfter(start_event) orelse return null;
        if (!next_event.isPureWrite()) return null;
        if (self.hasReadBetween(start_event.symbol_id, start_event.ref_pos, next_event.ref_pos)) return null;
        if (self.hasReadInStmt(start_event.symbol_id, next_event.stmt_idx, next_event.ref_pos)) return null;
        return next_event;
    }

    fn hasReadBetween(self: *const DeadStoreRefIndex, symbol_id: u32, start_ref_pos: u32, end_ref_pos: u32) bool {
        for (self.all_events.items) |event| {
            if (event.symbol_id != symbol_id) continue;
            if (event.ref_pos <= start_ref_pos or event.ref_pos >= end_ref_pos) continue;
            if (event.isRead()) return true;
        }
        return false;
    }

    fn hasReadInStmt(self: *const DeadStoreRefIndex, symbol_id: u32, stmt_idx: u32, except_ref_pos: u32) bool {
        for (self.all_events.items) |event| {
            if (event.symbol_id != symbol_id) continue;
            if (event.stmt_idx != stmt_idx) continue;
            if (event.ref_pos == except_ref_pos) continue;
            if (event.isRead()) return true;
        }
        return false;
    }
};

/// 유닛 테스트용 스코프 트리: 0=module, 1=module 안의 function.
const test_scopes = [_]Scope{
    .{ .parent = .none, .kind = .module, .is_strict = true },
    .{ .parent = @enumFromInt(0), .kind = .function, .is_strict = true },
};

test "DeadStoreRefIndex matches transformed assignment by unique same-statement write" {
    const allocator = std.testing.allocator;
    const old_lhs_node: NodeIndex = @enumFromInt(10);
    const transformed_lhs_node: u32 = 200;
    const references = [_]Reference{
        .{
            .node_index = old_lhs_node,
            .scope_id = @enumFromInt(1),
            .symbol_id = @enumFromInt(2),
            .stmt_idx = 0,
            .scope_stmt_idx = 3,
            .flags = .{ .write = true },
        },
    };

    var index = try DeadStoreRefIndex.init(allocator, &references, &test_scopes, 4);
    defer index.deinit(allocator);

    try std.testing.expect(index.findWriteForNode(2, transformed_lhs_node) == null);
    const event = index.findWriteForAssignment(2, transformed_lhs_node, 3) orelse return error.MissingWriteEvent;
    try std.testing.expectEqual(@as(u32, @intFromEnum(old_lhs_node)), event.node_idx);
    try std.testing.expectEqual(@as(u32, 3), event.stmt_idx);
}

test "DeadStoreRefIndex does not guess when same-statement writes are ambiguous" {
    const allocator = std.testing.allocator;
    const references = [_]Reference{
        .{
            .node_index = @enumFromInt(10),
            .scope_id = @enumFromInt(1),
            .symbol_id = @enumFromInt(2),
            .stmt_idx = 0,
            .scope_stmt_idx = 3,
            .flags = .{ .write = true },
        },
        .{
            .node_index = @enumFromInt(11),
            .scope_id = @enumFromInt(1),
            .symbol_id = @enumFromInt(2),
            .stmt_idx = 0,
            .scope_stmt_idx = 3,
            .flags = .{ .write = true },
        },
    };

    var index = try DeadStoreRefIndex.init(allocator, &references, &test_scopes, 4);
    defer index.deinit(allocator);

    try std.testing.expect(index.findWriteForAssignment(2, 200, 3) == null);
}

test "readEscapesExecUnit: 다른 함수(클로저)의 read 는 write 를 살린다 (#4503)" {
    const allocator = std.testing.allocator;
    // 심볼 2 를 module scope(0) 에서 write, function scope(1) 안에서 read.
    const references = [_]Reference{
        .{
            .node_index = @enumFromInt(10),
            .scope_id = @enumFromInt(1), // 클로저 안
            .symbol_id = @enumFromInt(2),
            .scope_stmt_idx = 0,
            .flags = .{ .read = true },
        },
        .{
            .node_index = @enumFromInt(11),
            .scope_id = @enumFromInt(0), // module 최상위 write
            .symbol_id = @enumFromInt(2),
            .scope_stmt_idx = 1,
            .flags = .{ .write = true },
        },
    };

    var index = try DeadStoreRefIndex.init(allocator, &references, &test_scopes, 4);
    defer index.deinit(allocator);

    // write 는 module(0), read 는 function(1) → 실행 단위가 달라 제거 금지.
    try std.testing.expect(index.readEscapesExecUnit(2, 0));
    // 같은 실행 단위(function) 안의 write 라면 read 위치와 일치 → 기존 ref_pos 분석 유효.
    try std.testing.expect(!index.readEscapesExecUnit(2, 1));
    // read 가 아예 없는 심볼(3) 은 여전히 dead store 제거 대상.
    try std.testing.expect(!index.readEscapesExecUnit(3, 0));
    // 심볼 범위 밖은 보수적으로 차단.
    try std.testing.expect(index.readEscapesExecUnit(99, 0));
}

test "readEscapesExecUnit: scope_stmt_idx 없는 read 도 집계된다 (#4503)" {
    const allocator = std.testing.allocator;
    // NO_STMT read 는 event 인덱스에서 제외되지만 실행 단위 집계에는 반드시 포함돼야 한다.
    const references = [_]Reference{
        .{
            .node_index = @enumFromInt(10),
            .scope_id = @enumFromInt(1),
            .symbol_id = @enumFromInt(2),
            .scope_stmt_idx = Reference.NO_STMT,
            .flags = .{ .read = true },
        },
    };

    var index = try DeadStoreRefIndex.init(allocator, &references, &test_scopes, 4);
    defer index.deinit(allocator);

    try std.testing.expect(index.readEscapesExecUnit(2, 0));
}

test "readEscapesExecUnit: type-only read 는 실행 단위 집계에서 제외" {
    const allocator = std.testing.allocator;
    const references = [_]Reference{
        .{
            .node_index = @enumFromInt(10),
            .scope_id = @enumFromInt(1),
            .symbol_id = @enumFromInt(2),
            .scope_stmt_idx = 0,
            .flags = .{ .read = true, .type_context = true },
        },
    };

    var index = try DeadStoreRefIndex.init(allocator, &references, &test_scopes, 4);
    defer index.deinit(allocator);

    // TS 타입 문맥 참조는 런타임 read 가 아니므로 dead store 제거를 막지 않는다.
    try std.testing.expect(!index.readEscapesExecUnit(2, 0));
}

test "enclosingExecUnit: block/catch 스코프는 부모 함수로 올라간다" {
    const scopes = [_]Scope{
        .{ .parent = .none, .kind = .module, .is_strict = true },
        .{ .parent = @enumFromInt(0), .kind = .function, .is_strict = true },
        .{ .parent = @enumFromInt(1), .kind = .block, .is_strict = true },
        .{ .parent = @enumFromInt(2), .kind = .catch_clause, .is_strict = true },
        .{ .parent = @enumFromInt(1), .kind = .class_body, .is_strict = true },
    };
    try std.testing.expectEqual(@as(?u32, 0), scope_mod.enclosingExecUnit(&scopes, @enumFromInt(0)));
    try std.testing.expectEqual(@as(?u32, 1), scope_mod.enclosingExecUnit(&scopes, @enumFromInt(1)));
    try std.testing.expectEqual(@as(?u32, 1), scope_mod.enclosingExecUnit(&scopes, @enumFromInt(2))); // block → function
    try std.testing.expectEqual(@as(?u32, 1), scope_mod.enclosingExecUnit(&scopes, @enumFromInt(3))); // catch → block → function
    try std.testing.expectEqual(@as(?u32, 4), scope_mod.enclosingExecUnit(&scopes, @enumFromInt(4))); // class body 는 자체 경계
    try std.testing.expectEqual(@as(?u32, null), scope_mod.enclosingExecUnit(&scopes, @enumFromInt(99))); // 범위 밖
}

/// 한 모듈에 대한 dead-store 패스의 공용 컨텍스트. 인자 8개를 함수마다 실어나르지 않도록 묶었다.
const Pass = struct {
    /// AST walk 스택 전용 (emitter 의 arena).
    allocator: std.mem.Allocator,
    ast: *Ast,
    symbol_ids: []const ?u32,
    symbols: []const Symbol,
    scopes: []const Scope,
    ref_index: *const DeadStoreRefIndex,
    unresolved_globals: ?*const purity.GlobalRefSet,
    skip_nodes: *std.DynamicBitSet,
    module: *const Module,

    /// 지우려는 store 의 RHS/초기화자가 **평가 부수효과 없이 통째로 삭제 가능한지** 판정할 때
    /// 쓰는 컨텍스트 (#4514). 문 자리 DCE(`minify/unused_expr.zig`) 와 **같은 술어** 를 쓴다.
    fn removalCtx(self: *const Pass) purity.StmtRemovalCtx {
        return .{
            .symbol_ids = self.symbol_ids,
            .symbols = self.symbols,
            .unresolved_globals = self.unresolved_globals,
        };
    }

    /// 이 심볼의 store 를 **절대 지우면 안 되는** 사유가 있는가 (심볼 단위 가드).
    ///
    /// `write_scope_id` 는 지우려는 store 가 있는 스코프. 판정 불가는 전부 "보호"(true).
    fn storeIsProtected(self: *const Pass, sym_idx: u32, write_scope_id: u32) bool {
        if (sym_idx >= self.symbols.len) return true;
        const sym = self.symbols[sym_idx];

        const write_unit = scope_mod.enclosingExecUnit(self.scopes, @enumFromInt(write_scope_id)) orelse return true;

        // (1) #4503 — 클로저/다른 함수에서의 read. 그 read 는 두 store 사이의 임의 호출 시점에
        //     일어날 수 있어 소스 순서(ref_pos) 기반 "사이에 read 없음" 판정이 무효다.
        if (self.ref_index.readEscapesExecUnit(sym_idx, write_unit)) return true;

        // (2) **재진입(re-entrancy)** — write 하는 실행 단위 *밖* 에 선언된 변수는 그 함수의
        //     호출이 겹쳐도 같은 바인딩 하나를 공유한다. 그래서 두 store 사이의 호출이
        //       - 그 함수 자신을 다시 부르거나 (재귀),
        //       - await/yield 지점에서 다른 호출과 인터리빙되거나,
        //       - 예외로 밖으로 빠져나가
        //     앞 store 의 값을 관측할 수 있다. 이 read 들은 write 와 *같은* 실행 단위에 있어서
        //     (1) 이 못 잡는다 — 소스 순서로는 보이지 않는 다른 *활성화(activation)* 의 read다.
        //
        //     반대로 write 와 같은 실행 단위에 선언된 진짜 지역변수는 호출마다 새 바인딩이라
        //     다른 활성화가 앞 store 의 값을 볼 수 없다 → DSE 의 주 수익 구간은 그대로 유지된다.
        const decl_unit = scope_mod.enclosingExecUnit(self.scopes, sym.scope_id) orelse return true;
        if (decl_unit != write_unit) return true;

        // (3) 다른 모듈이 import 해 읽을 수 있는 심볼 (live binding) — 모듈 안 참조만으로는
        //     관측 여부를 알 수 없다.
        if (isExportedSymbol(self.module, sym_idx)) return true;

        // (4) direct eval / with 가 있는 스코프의 바인딩은 이름으로 동적 조회될 수 있다
        //     (참조 배열에 안 잡힘). mangler 와 같은 기준으로 차단.
        const decl_scope = @intFromEnum(sym.scope_id);
        if (decl_scope >= self.scopes.len) return true;
        if (self.scopes[decl_scope].blocksMangling()) return true;

        // (5) **mapped `arguments`** (#4514) — 비엄격 함수의 파라미터는 `arguments` 객체와
        //     양방향 aliasing 이라 `arguments[0]` 읽기가 파라미터의 read 로 잡히지 않는다.
        //     `function f(a){ a = 1; use(arguments[0]); a = 2; }` 에서 `a = 1` 을 지우면
        //     `arguments[0]` 이 원래 인자값을 보게 된다.
        //
        //     엄격성은 **입력 파싱 기준**(ESM = strict)이지만 출력은 `--format=iife/cjs` 에서
        //     "use strict" 없이 나갈 수 있어 런타임에는 sloppy 다 — 즉 `scopes[].is_strict` 로
        //     걸러도 안전하지 않다. 파라미터를 두 번 연속 덮어쓰는(사이에 read 없는) 코드는
        //     실전에 거의 없어 DSE 수익 손실이 사실상 0 이므로, 파라미터는 무조건 보호한다.
        if (sym.decl_flags.is_parameter) return true;

        return false;
    }

    /// 두 store `stmts[from]` / `stmts[to]` **사이** 의 statement 들이 바깥 흐름을 끊는가.
    ///
    /// 끊는 경로가 있으면 뒤 store 가 실행되지 않고 앞 store 의 값이 살아남는다
    /// (`x = 1; if (c) break lbl; x = 2;` → break 시 x 는 1). 소스 순서 분석으로는 그 경로를
    /// 볼 수 없으므로 보수적으로 제거를 포기한다.
    fn windowBreaksFlow(self: *const Pass, stmts: []const u32, from: usize, to: usize) bool {
        if (to <= from + 1) return false; // 사이가 비었음 — 끊길 여지 없음.
        var i = from + 1;
        while (i < to) : (i += 1) {
            if (self.stmtBreaksFlow(stmts[i])) return true;
        }
        return false;
    }

    /// statement 하나가 **자기를 담고 있는 statement list 의 흐름** 을 끊을 수 있는가.
    ///
    /// 끊는 것:
    ///   - `return` / `throw`
    ///   - 바깥으로 나가는 `break` / `continue`
    /// 끊지 **않는** 것 (여기서 걸러야 진짜 dead store 를 계속 지울 수 있다):
    ///   - 함수/메서드/클래스 본문 안의 return/throw — 그 함수만 끊는다.
    ///   - 이 statement 안에 **완전히 포함된** loop/switch 에 묶이는 라벨 없는 break/continue
    ///     (`for (…) { if (v) break; }` 의 break, `switch (v) { case 1: …; break; }` 의 break).
    /// 라벨 있는 break/continue 는 바깥 라벨을 타깃할 수 있으므로 보수적으로 "끊는다" 로 본다.
    ///
    /// OOM 은 "끊는다"(보수적)로 취급.
    fn stmtBreaksFlow(self: *const Pass, root: u32) bool {
        const ast = self.ast;
        // 인덱스가 이상하면 "끊는다"(=제거 포기). 이 파일의 다른 모든 불확실 경로(OOM, 스코프
        // 체인 이상)와 같은 방향 — 모르면 보수적으로 유지한다.
        if (root >= ast.nodes.items.len) return true;

        // 빠른 경로: 표현식/선언 statement 안에는 return/break/continue/throw **statement** 가
        // 올 수 없다 (중첩 함수 본문 안에만 올 수 있고 그건 경계 밖). 창 안 statement 의 대부분이
        // 여기 해당 — AST walk 자체를 건너뛴다.
        switch (ast.nodes.items[root].tag) {
            .expression_statement, .variable_declaration, .empty_statement, .debugger_statement => return false,
            else => {},
        }

        // loop/switch 중첩 깊이를 프레임에 실어 나른다 (라벨 없는 break/continue 의 결속 대상 판정).
        const Frame = struct { idx: u32, loop_depth: u16, switch_depth: u16 };
        var stack: std.ArrayListUnmanaged(Frame) = .empty;
        defer stack.deinit(self.allocator);
        var child_buf: std.ArrayListUnmanaged(NodeIndex) = .empty;
        defer child_buf.deinit(self.allocator);
        stack.append(self.allocator, .{ .idx = root, .loop_depth = 0, .switch_depth = 0 }) catch return true;

        while (stack.pop()) |frame| {
            if (frame.idx >= ast.nodes.items.len) continue;
            const node = ast.nodes.items[frame.idx];
            var loop_depth = frame.loop_depth;
            var switch_depth = frame.switch_depth;

            switch (node.tag) {
                .return_statement, .throw_statement => return true,
                .break_statement => {
                    // `data.unary.operand` = 라벨 (없으면 none) — parser 의 parseSimpleStatement.
                    if (!node.data.unary.operand.isNone()) return true; // 라벨 → 바깥 타깃 가능.
                    if (loop_depth == 0 and switch_depth == 0) return true; // 바깥 흐름을 끊는다.
                    continue; // 창 안 loop/switch 에 묶임 — 뒤 store 는 여전히 실행된다.
                },
                .continue_statement => {
                    if (!node.data.unary.operand.isNone()) return true;
                    if (loop_depth == 0) return true;
                    continue;
                },
                // 함수/메서드/클래스 경계 — 안쪽 return/throw/break 는 바깥 흐름과 무관.
                // (tag 목록은 es2022_tla 의 경계 집합과 동일하게 유지한다.)
                .function_declaration,
                .function_expression,
                .function,
                .arrow_function_expression,
                .method_definition,
                .accessor_property,
                .class_declaration,
                .class_expression,
                => continue,
                .while_statement,
                .do_while_statement,
                .for_statement,
                .for_in_statement,
                .for_of_statement,
                .for_await_of_statement,
                => loop_depth += 1,
                .switch_statement => switch_depth += 1,
                else => {},
            }

            child_buf.clearRetainingCapacity();
            var it = ast_walk.children(ast, node);
            while (it.next()) |c| child_buf.append(self.allocator, c) catch return true;
            for (child_buf.items) |c| {
                if (c.isNone()) continue;
                stack.append(self.allocator, .{
                    .idx = @intFromEnum(c),
                    .loop_depth = loop_depth,
                    .switch_depth = switch_depth,
                }) catch return true;
            }
        }
        return false;
    }
};

pub fn markDeadOverwrittenAssignments(
    allocator: std.mem.Allocator,
    ast: *Ast,
    symbol_ids: []const ?u32,
    references: []const Reference,
    symbols: []const Symbol,
    scopes: []const Scope,
    unresolved_globals: ?*const purity.GlobalRefSet,
    skip_nodes: *std.DynamicBitSet,
    module: *const Module,
) !void {
    if (ast.nodes.items.len == 0) return;
    const root = ast.nodes.items[ast.nodes.items.len - 1];
    if (root.tag != .program) return;
    const list = root.data.list;
    if (list.start + list.len > ast.extra_data.items.len) return;
    const stmts = ast.extra_data.items[list.start .. list.start + list.len];

    var ref_index = try DeadStoreRefIndex.init(allocator, references, scopes, symbols.len);
    defer ref_index.deinit(allocator);

    const pass: Pass = .{
        .allocator = allocator,
        .ast = ast,
        .symbol_ids = symbol_ids,
        .symbols = symbols,
        .scopes = scopes,
        .ref_index = &ref_index,
        .unresolved_globals = unresolved_globals,
        .skip_nodes = skip_nodes,
        .module = module,
    };
    markDeadOverwrittenInStatementList(&pass, stmts);
}

pub fn markDeadOverwrittenFunctionBodiesOnly(
    allocator: std.mem.Allocator,
    ast: *Ast,
    symbol_ids: []const ?u32,
    references: []const Reference,
    symbols: []const Symbol,
    scopes: []const Scope,
    unresolved_globals: ?*const purity.GlobalRefSet,
    skip_nodes: *std.DynamicBitSet,
    module: *const Module,
) !void {
    if (ast.nodes.items.len == 0) return;
    const root = ast.nodes.items[ast.nodes.items.len - 1];
    if (root.tag != .program) return;

    var ref_index = try DeadStoreRefIndex.init(allocator, references, scopes, symbols.len);
    defer ref_index.deinit(allocator);

    const pass: Pass = .{
        .allocator = allocator,
        .ast = ast,
        .symbol_ids = symbol_ids,
        .symbols = symbols,
        .scopes = scopes,
        .ref_index = &ref_index,
        .unresolved_globals = unresolved_globals,
        .skip_nodes = skip_nodes,
        .module = module,
    };

    for (ast.nodes.items) |node| {
        if (ast.functionBodyBlock(node) == null) continue;
        markDeadOverwrittenFunctionBody(&pass, node);
    }
}

fn markDeadOverwrittenInStatementList(pass: *const Pass, stmts: []const u32) void {
    const ast = pass.ast;
    for (stmts, 0..) |raw_stmt, i| {
        if (raw_stmt >= ast.nodes.items.len) continue;
        if (raw_stmt < pass.skip_nodes.capacity() and pass.skip_nodes.isSet(raw_stmt)) continue;
        markDeadOverwrittenDeclarationInitializers(pass, raw_stmt, i, stmts);
        const current = assignmentInfoForStmt(ast, raw_stmt, pass.removalCtx(), true) orelse continue;
        const current_write = pass.ref_index.findWriteForAssignment(current.sym_idx, current.lhs_idx, @intCast(i)) orelse continue;
        if (pass.storeIsProtected(current.sym_idx, current_write.scope_id)) continue;
        const next_event = pass.ref_index.findOverwriteAfter(current_write) orelse continue;
        if (next_event.stmt_idx <= i or next_event.stmt_idx >= stmts.len) continue;
        if (pass.windowBreaksFlow(stmts, i, next_event.stmt_idx)) continue;
        const next_raw = stmts[next_event.stmt_idx];
        if (next_raw >= ast.nodes.items.len) continue;
        if (next_raw < pass.skip_nodes.capacity() and pass.skip_nodes.isSet(next_raw)) continue;
        const next_assign = assignmentInfoForStmt(ast, next_raw, pass.removalCtx(), false) orelse continue;
        if (next_assign.sym_idx != current.sym_idx) continue;
        if (pass.ref_index.findWriteForAssignment(next_assign.sym_idx, next_assign.lhs_idx, next_event.stmt_idx) == null) continue;
        if (current.stmt_idx < pass.skip_nodes.capacity()) pass.skip_nodes.set(current.stmt_idx);
    }

    for (stmts) |raw_stmt| {
        markDeadOverwrittenNestedStatementLists(pass, raw_stmt);
    }
}

fn markDeadOverwrittenNestedStatementLists(pass: *const Pass, node_idx: u32) void {
    const ast = pass.ast;
    if (node_idx >= ast.nodes.items.len) return;
    const node = ast.nodes.items[node_idx];

    if (node.tag == .block_statement) {
        const list = node.data.list;
        if (list.start + list.len <= ast.extra_data.items.len) {
            const stmts = ast.extra_data.items[list.start .. list.start + list.len];
            markDeadOverwrittenInStatementList(pass, stmts);
        }
    }

    // innerGraph (ROADMAP): control-flow 구문의 *블록 본문 내부* straight-line dead store 도
    // 분석한다. **분기 경계는 넘지 않는다** — 각 블록 본문에 기존(증명된) 분석을 그대로 적용할
    // 뿐, cross-branch liveness 는 시도하지 않는다(예: `if(c) x=1; x=2;` 의 x=1 은 건드리지
    // 않음). 자식 본문 노드로 재귀하면 그 노드가 block_statement 일 때 위 분기가 처리한다.
    //
    // **try/catch/finally 는 의도적으로 제외**한다(code-review: silent miscompile). try 영역 안에서는
    // 두 write 사이의 throw 가능 statement(call 등)가 암묵 분기라, 첫 write 가 catch/finally/after-try
    // 에서 관측될 수 있다(예: `try{ x=A; mayThrow(); x=B; }catch{ use(x) }` 에서 throw 시 x=A 가
    // live). hasReadBetween 은 *read* 만 보고 throw 가능성을 모른다. try 영역은 오직 try_statement
    // 재귀로만 도달하므로(그 안의 if/while 도 마찬가지) try 를 재귀 대상에서 빼면 try 영역 전체가
    // 분석에서 제외돼 변경 전 soundness 와 동일해진다. try 밖 control-flow 는 핸들러가 없어 안전.
    var bodies: [2]u32 = undefined;
    var nb: usize = 0;
    switch (node.tag) {
        .if_statement => {
            if (!node.data.ternary.b.isNone()) {
                bodies[nb] = @intFromEnum(node.data.ternary.b);
                nb += 1;
            }
            if (!node.data.ternary.c.isNone()) {
                bodies[nb] = @intFromEnum(node.data.ternary.c);
                nb += 1;
            }
        },
        .while_statement, .do_while_statement, .labeled_statement => {
            if (!node.data.binary.right.isNone()) {
                bodies[nb] = @intFromEnum(node.data.binary.right);
                nb += 1;
            }
        },
        .for_in_statement, .for_of_statement, .for_await_of_statement => {
            if (!node.data.ternary.c.isNone()) {
                bodies[nb] = @intFromEnum(node.data.ternary.c);
                nb += 1;
            }
        },
        .for_statement => {
            // extra: [init, test, update, body] — body 는 extra+3 (analyzer predeclare 와 동일).
            const ex = node.data.extra;
            if (ex + 3 < ast.extra_data.items.len) {
                bodies[nb] = ast.extra_data.items[ex + 3];
                nb += 1;
            }
        },
        // **switch 본문은 의도적으로 미분석**이다 (#4514). 예전엔 `.switch_case` arm 이
        // 있었지만 `.switch_statement` 로 내려가는 재귀가 없어 **도달 불가능한 죽은 코드**였다
        // (switch_case 는 statement list 의 원소가 아니라 switch_statement 의 자식이다).
        // 즉 지금까지 switch case 안에서는 DSE 가 한 번도 돌지 않았다 — 버그가 아니라
        // **놓친 최적화**다. 여기서 되살리지 않는 이유:
        //   - 이 PR 은 purity 오판(무성 오컴파일) 수정이 목적이라, 한 번도 실행된 적 없는
        //     영역에 DSE 를 새로 켜면 size 측정과 회귀 원인 추적이 뒤섞인다.
        //   - 켜려면 case 진입점이 여러 개(fallthrough / 직접 진입)라는 점을 별도로 검증해야
        //     한다. 별도 PR 로 다룬다.
        else => {},
    }
    for (bodies[0..nb]) |child| {
        markDeadOverwrittenNestedStatementLists(pass, child);
    }

    markDeadOverwrittenFunctionBody(pass, node);
}

fn markDeadOverwrittenFunctionBody(pass: *const Pass, node: ast_mod.Node) void {
    const ast = pass.ast;
    if (ast.functionBodyBlock(node)) |body_idx| {
        if (@intFromEnum(body_idx) < ast.nodes.items.len) {
            const body = ast.nodes.items[@intFromEnum(body_idx)];
            if (body.tag == .block_statement) {
                const list = body.data.list;
                if (list.start + list.len <= ast.extra_data.items.len) {
                    const stmts = ast.extra_data.items[list.start .. list.start + list.len];
                    markDeadOverwrittenInStatementList(pass, stmts);
                }
            }
        }
    }
}

fn markDeadOverwrittenDeclarationInitializers(
    pass: *const Pass,
    stmt_idx: u32,
    stmt_pos: usize,
    stmts: []const u32,
) void {
    const ast = pass.ast;
    if (stmt_idx >= ast.nodes.items.len) return;
    const stmt = ast.nodes.items[stmt_idx];
    if (stmt.tag != .variable_declaration) return;

    const kind = ast.variableDeclarationKind(stmt);
    if (kind == .@"const" or kind.isUsing()) return;

    const e = stmt.data.extra;
    if (e + 2 >= ast.extra_data.items.len) return;
    const list_start = ast.extra_data.items[e + 1];
    const list_len = ast.extra_data.items[e + 2];
    if (list_len != 1 or list_start >= ast.extra_data.items.len) return;

    const decl_idx = ast.extra_data.items[list_start];
    if (decl_idx >= ast.nodes.items.len) return;
    const decl = ast.nodes.items[decl_idx];
    if (decl.tag != .variable_declarator) return;

    const de = decl.data.extra;
    if (de + 2 >= ast.extra_data.items.len) return;
    const name_idx: NodeIndex = @enumFromInt(ast.extra_data.items[de]);
    const init_idx: NodeIndex = @enumFromInt(ast.extra_data.items[de + 2]);
    if (name_idx.isNone() or init_idx.isNone()) return;
    const name_ni = @intFromEnum(name_idx);
    if (name_ni >= ast.nodes.items.len or name_ni >= pass.symbol_ids.len) return;
    const name = ast.nodes.items[name_ni];
    if (name.tag != .binding_identifier) return;
    const sym_idx: u32 = @intCast(pass.symbol_ids[name_ni] orelse return);
    if (sym_idx >= pass.symbols.len) return;
    // 초기화자도 store 다 — 평가만으로 관측 가능한 효과(getter / TypeError /
    // ReferenceError)가 있으면 지우면 안 된다 (#4514).
    if (!purity.isRemovableAtStmtPos(ast, init_idx, pass.removalCtx())) return;

    const decl_scope = @intFromEnum(pass.symbols[sym_idx].scope_id);
    // 초기화자도 store 다 — 뒤의 재대입 사이에서 클로저가 읽을 수 있으면 지우면 안 된다 (#4503).
    if (pass.storeIsProtected(sym_idx, decl_scope)) return;
    const declare_event = pass.ref_index.findDeclare(sym_idx, decl_scope, @intCast(stmt_pos)) orelse return;
    const next_event = pass.ref_index.findOverwriteAfter(declare_event) orelse return;
    if (next_event.stmt_idx <= stmt_pos or next_event.stmt_idx >= stmts.len) return;
    if (pass.windowBreaksFlow(stmts, stmt_pos, next_event.stmt_idx)) return;

    const next_raw = stmts[next_event.stmt_idx];
    if (next_raw >= ast.nodes.items.len) return;
    const next_assign = assignmentInfoForStmt(ast, next_raw, pass.removalCtx(), false) orelse return;
    if (next_assign.sym_idx != sym_idx) return;
    if (pass.ref_index.findWriteForAssignment(next_assign.sym_idx, next_assign.lhs_idx, next_event.stmt_idx) == null) return;
    ast.extra_data.items[de + 2] = @intFromEnum(NodeIndex.none);
}

fn isExportedSymbol(module: *const Module, sym_idx: u32) bool {
    for (module.export_bindings) |binding| {
        if (binding.symbol.semanticIndex()) |export_sym| {
            if (export_sym == sym_idx) return true;
        }
    }
    return false;
}

/// `require_removable_rhs` — 이 statement 를 **지울 후보** 로 볼 때만 true. RHS 평가가
/// 관측 가능한 효과(getter / TypeError / ReferenceError)를 낼 수 있으면 후보에서 제외한다
/// (#4514). 뒤에 오는 *덮어쓰는* store 를 식별할 때는 지우지 않으므로 false 로 부른다.
fn assignmentInfoForStmt(
    ast: *const Ast,
    stmt_idx: u32,
    removal_ctx: purity.StmtRemovalCtx,
    require_removable_rhs: bool,
) ?AssignmentInfo {
    if (stmt_idx >= ast.nodes.items.len) return null;
    const stmt = ast.nodes.items[stmt_idx];
    if (stmt.tag != .expression_statement) return null;
    const expr_idx = stmt.data.unary.operand;
    if (expr_idx.isNone() or @intFromEnum(expr_idx) >= ast.nodes.items.len) return null;
    const expr = ast.nodes.items[@intFromEnum(expr_idx)];
    if (expr.tag != .assignment_expression) return null;

    const op: TokenKind = @enumFromInt(expr.data.binary.flags);
    if (op != .eq) return null;

    const lhs_idx = expr.data.binary.left;
    if (lhs_idx.isNone() or @intFromEnum(lhs_idx) >= ast.nodes.items.len) return null;
    const lhs = ast.nodes.items[@intFromEnum(lhs_idx)];
    if (lhs.tag != .assignment_target_identifier and lhs.tag != .identifier_reference) return null;
    const lhs_ni = @intFromEnum(lhs_idx);
    if (lhs_ni >= removal_ctx.symbol_ids.len) return null;
    const sym_idx: u32 = @intCast(removal_ctx.symbol_ids[lhs_ni] orelse return null);

    const rhs_idx = expr.data.binary.right;
    if (require_removable_rhs and !purity.isRemovableAtStmtPos(ast, rhs_idx, removal_ctx)) return null;

    return .{
        .stmt_idx = stmt_idx,
        .lhs_idx = @intCast(lhs_ni),
        .sym_idx = sym_idx,
    };
}
