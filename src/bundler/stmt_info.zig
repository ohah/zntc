//! ZTS Bundler — Statement Info (rolldown 방식)
//!
//! 각 top-level statement가 선언하는 심볼과 참조하는 심볼을 추적한다.
//! semantic analyzer의 symbol_ids (node_index → symbol_index) 매핑을 재활용.
//!
//! tree_shaker: import binding liveness 판정 (도달성 기반)
//! statement_shaker: 미사용 statement 제거 (skip_nodes)
//! emitter: used_names 정제

const std = @import("std");
const Ast = @import("../parser/ast.zig").Ast;
const Node = @import("../parser/ast.zig").Node;
const NodeIndex = @import("../parser/ast.zig").NodeIndex;
const Span = @import("../lexer/token.zig").Span;
const Symbol = @import("../semantic/symbol.zig").Symbol;
const ScopeId = @import("../semantic/scope.zig").ScopeId;
const purity = @import("purity.zig");

pub const StmtInfo = struct {
    node_idx: u32,
    span: Span,
    has_side_effects: bool,
    /// 이 statement가 선언하는 top-level 심볼 인덱스들
    declared_symbols: []const u32,
    /// 이 statement가 참조하는 심볼 인덱스들 (자체 declared에 없는 것만)
    referenced_symbols: []const u32,
};

pub const ModuleStmtInfos = struct {
    stmts: []StmtInfo,
    /// symbol_index → stmt_index (선언 역매핑). 없으면 null.
    symbol_to_stmt: []const ?u32,
    /// symbol_index → [side-effect stmt indices that reference this symbol].
    /// tree_shaker.enqueue()에서 O(1) 조회용.
    sym_to_side_effect_stmts: []const []const u32,
    /// symbol_index → [all stmt indices that reference this symbol].
    /// tree_shaker.isImportLiveInModule()에서 O(1) 조회용.
    sym_to_referencing_stmts: []const []const u32,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *ModuleStmtInfos) void {
        for (self.stmts) |stmt| {
            self.allocator.free(stmt.declared_symbols);
            self.allocator.free(stmt.referenced_symbols);
        }
        self.allocator.free(self.stmts);
        self.allocator.free(self.symbol_to_stmt);
        // 역인덱스 해제
        for (self.sym_to_side_effect_stmts) |s| {
            if (s.len > 0) self.allocator.free(s);
        }
        self.allocator.free(self.sym_to_side_effect_stmts);
        for (self.sym_to_referencing_stmts) |s| {
            if (s.len > 0) self.allocator.free(s);
        }
        self.allocator.free(self.sym_to_referencing_stmts);
    }

    /// symbol_index가 선언된 statement 인덱스 반환.
    pub fn declaredStmtBySymbol(self: *const ModuleStmtInfos, sym_idx: u32) ?u32 {
        if (sym_idx >= self.symbol_to_stmt.len) return null;
        return self.symbol_to_stmt[sym_idx];
    }

    /// used exports에서 도달 가능한 심볼 set을 BFS로 계산.
    /// 반환: symbol_index → reachable 여부를 나타내는 bitset.
    pub fn computeReachable(
        self: *const ModuleStmtInfos,
        allocator: std.mem.Allocator,
        used_export_sym_indices: []const u32,
    ) !std.DynamicBitSet {
        var reachable_stmts = try std.DynamicBitSet.initEmpty(allocator, self.stmts.len);
        errdefer reachable_stmts.deinit();

        var queue: std.ArrayListUnmanaged(u32) = .empty;
        defer queue.deinit(allocator);

        // seed: side-effectful statements
        for (self.stmts, 0..) |stmt, i| {
            if (stmt.has_side_effects) {
                reachable_stmts.set(i);
                try queue.append(allocator, @intCast(i));
            }
        }

        // seed: used exports가 선언된 statements
        for (used_export_sym_indices) |sym_idx| {
            if (self.declaredStmtBySymbol(sym_idx)) |stmt_idx| {
                if (!reachable_stmts.isSet(stmt_idx)) {
                    reachable_stmts.set(stmt_idx);
                    try queue.append(allocator, stmt_idx);
                }
            }
        }

        // BFS: referenced_symbols → symbol_to_stmt → dependent statements
        var head: u32 = 0;
        while (head < queue.items.len) : (head += 1) {
            const stmt_idx = queue.items[head];
            for (self.stmts[stmt_idx].referenced_symbols) |ref_sym| {
                if (self.declaredStmtBySymbol(ref_sym)) |dep_stmt| {
                    if (!reachable_stmts.isSet(dep_stmt)) {
                        reachable_stmts.set(dep_stmt);
                        try queue.append(allocator, dep_stmt);
                    }
                }
            }
        }

        return reachable_stmts;
    }
};

fn sliceContains(comptime T: type, slice: []const T, value: T) bool {
    for (slice) |item| {
        if (item == value) return true;
    }
    return false;
}

/// statement span 배열에서 pos를 포함하는 statement를 binary search.
/// statement span은 소스 순서로 비중첩.
pub fn findStmtForPos(stmt_spans: []const Span, pos: u32) ?u32 {
    if (stmt_spans.len == 0) return null;

    var lo: u32 = 0;
    var hi: u32 = @intCast(stmt_spans.len);

    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (pos >= stmt_spans[mid].end) {
            lo = mid + 1;
        } else if (pos < stmt_spans[mid].start) {
            hi = mid;
        } else {
            return mid; // stmt_spans[mid].start <= pos < stmt_spans[mid].end
        }
    }
    return null; // 어떤 statement span에도 속하지 않음
}

/// AST + semantic data로부터 ModuleStmtInfos를 구축한다.
pub fn build(
    allocator: std.mem.Allocator,
    ast: *const Ast,
    symbols: []const Symbol,
    symbol_ids: []const ?u32,
) !?ModuleStmtInfos {
    // program 노드 (마지막 노드)
    if (ast.nodes.items.len == 0) return null;
    const root = ast.nodes.items[ast.nodes.items.len - 1];
    if (root.tag != .program) return null;

    const list = root.data.list;
    if (list.len == 0) return null;
    if (list.start + list.len > ast.extra_data.items.len) return null;
    const stmt_raw_indices = ast.extra_data.items[list.start .. list.start + list.len];

    const stmt_count = stmt_raw_indices.len;
    var stmts = try allocator.alloc(StmtInfo, stmt_count);
    errdefer {
        for (stmts) |s| {
            allocator.free(s.declared_symbols);
            allocator.free(s.referenced_symbols);
        }
        allocator.free(stmts);
    }

    // symbol_to_stmt 역매핑
    var sym_to_stmt = try allocator.alloc(?u32, symbols.len);
    errdefer allocator.free(sym_to_stmt);
    for (sym_to_stmt) |*s| s.* = null;

    // Phase 1: statement span 배열 + side-effects 판정 + 초기화
    var stmt_spans = try allocator.alloc(Span, stmt_count);
    defer allocator.free(stmt_spans);

    for (stmt_raw_indices, 0..) |raw_idx, stmt_i| {
        const idx: NodeIndex = @enumFromInt(raw_idx);
        const ni = @intFromEnum(idx);
        if (ni >= ast.nodes.items.len) {
            stmt_spans[stmt_i] = .{ .start = 0, .end = 0 };
            stmts[stmt_i] = .{
                .node_idx = @intCast(ni),
                .span = .{ .start = 0, .end = 0 },
                .has_side_effects = true,
                .declared_symbols = &.{},
                .referenced_symbols = &.{},
            };
            continue;
        }
        const node = ast.nodes.items[ni];
        stmt_spans[stmt_i] = node.span;
        const side_effects = if (node.tag == .import_declaration) false else purity.stmtHasSideEffects(ast, node);
        stmts[stmt_i] = .{
            .node_idx = @intCast(ni),
            .span = node.span,
            .has_side_effects = side_effects,
            .declared_symbols = &.{}, // Phase 2에서 채움
            .referenced_symbols = &.{}, // Phase 2에서 채움
        };
    }

    // Phase 2: 모든 AST 노드를 단일 패스로 순회하며 심볼 수집 — O(N log S)
    // per-statement 임시 버퍼 (선형 탐색으로 중복 방지 — 심볼 수가 적으므로 HashMap보다 효율적)
    var declared_bufs = try allocator.alloc(std.ArrayListUnmanaged(u32), stmt_count);
    defer {
        for (declared_bufs) |*b| b.deinit(allocator);
        allocator.free(declared_bufs);
    }
    for (declared_bufs) |*b| b.* = .empty;

    var referenced_bufs = try allocator.alloc(std.ArrayListUnmanaged(u32), stmt_count);
    defer {
        for (referenced_bufs) |*b| b.deinit(allocator);
        allocator.free(referenced_bufs);
    }
    for (referenced_bufs) |*b| b.* = .empty;

    // 단일 패스: 모든 노드 → binary search로 소속 statement 결정
    for (ast.nodes.items, 0..) |n, node_i| {
        const stmt_i = findStmtForPos(stmt_spans, n.span.start) orelse continue;
        if (node_i >= symbol_ids.len) continue;
        const sym_idx = symbol_ids[node_i] orelse continue;
        if (sym_idx >= symbols.len) continue;

        const sym = &symbols[sym_idx];
        const sym_idx_u32: u32 = @intCast(sym_idx);

        // declared: top-level scope에 선언된 심볼
        if (@intFromEnum(sym.scope_id) == 0 and
            n.span.start >= sym.declaration_span.start and
            n.span.end <= sym.declaration_span.end)
        {
            if (!sliceContains(u32, declared_bufs[stmt_i].items, sym_idx_u32)) {
                try declared_bufs[stmt_i].append(allocator, sym_idx_u32);
                if (sym_idx < sym_to_stmt.len) {
                    sym_to_stmt[sym_idx] = @intCast(stmt_i);
                }
            }
        }

        // referenced: identifier_reference + assignment_target_identifier 중 declared에 없는 것
        const is_ref = switch (n.tag) {
            .identifier_reference, .assignment_target_identifier => true,
            else => false,
        };
        if (is_ref and !sliceContains(u32, declared_bufs[stmt_i].items, sym_idx_u32)) {
            if (!sliceContains(u32, referenced_bufs[stmt_i].items, sym_idx_u32)) {
                try referenced_bufs[stmt_i].append(allocator, sym_idx_u32);
            }
        }
    }

    // Phase 2 결과를 stmts에 기록 (toOwnedSlice로 이중 할당 방지)
    for (stmts, 0..) |*stmt, stmt_i| {
        if (declared_bufs[stmt_i].items.len > 0) {
            stmt.declared_symbols = try declared_bufs[stmt_i].toOwnedSlice(allocator);
        }
        if (referenced_bufs[stmt_i].items.len > 0) {
            stmt.referenced_symbols = try referenced_bufs[stmt_i].toOwnedSlice(allocator);
        }
    }

    // Phase 3: 역인덱스 구축 — symbol → referencing stmt indices
    const sym_count = symbols.len;

    // 3a: 카운트 패스
    var ref_counts = try allocator.alloc(u32, sym_count);
    defer allocator.free(ref_counts);
    @memset(ref_counts, 0);
    var se_counts = try allocator.alloc(u32, sym_count);
    defer allocator.free(se_counts);
    @memset(se_counts, 0);

    for (stmts) |stmt| {
        for (stmt.referenced_symbols) |sym| {
            if (sym < sym_count) {
                ref_counts[sym] += 1;
                if (stmt.has_side_effects) {
                    se_counts[sym] += 1;
                }
            }
        }
    }

    // 3b: 할당
    var sym_to_ref_stmts = try allocator.alloc([]const u32, sym_count);
    errdefer allocator.free(sym_to_ref_stmts);
    var sym_to_se_stmts = try allocator.alloc([]const u32, sym_count);
    errdefer allocator.free(sym_to_se_stmts);

    // 임시 쓰기용 mutable 버퍼
    var ref_bufs = try allocator.alloc([]u32, sym_count);
    defer {
        // ref_bufs의 각 슬라이스는 sym_to_ref_stmts로 이전되므로 별도 free 불필요
        allocator.free(ref_bufs);
    }
    var se_bufs = try allocator.alloc([]u32, sym_count);
    defer allocator.free(se_bufs);

    for (0..sym_count) |sym| {
        ref_bufs[sym] = if (ref_counts[sym] > 0) try allocator.alloc(u32, ref_counts[sym]) else &.{};
        se_bufs[sym] = if (se_counts[sym] > 0) try allocator.alloc(u32, se_counts[sym]) else &.{};
    }

    // 3c: 기록 패스 (카운터 재활용)
    @memset(ref_counts, 0);
    @memset(se_counts, 0);

    for (stmts, 0..) |stmt, si| {
        for (stmt.referenced_symbols) |sym| {
            if (sym < sym_count) {
                ref_bufs[sym][ref_counts[sym]] = @intCast(si);
                ref_counts[sym] += 1;
                if (stmt.has_side_effects) {
                    se_bufs[sym][se_counts[sym]] = @intCast(si);
                    se_counts[sym] += 1;
                }
            }
        }
    }

    // 3d: const 슬라이스로 변환
    for (0..sym_count) |sym| {
        sym_to_ref_stmts[sym] = ref_bufs[sym];
        sym_to_se_stmts[sym] = se_bufs[sym];
    }

    return .{
        .stmts = stmts,
        .symbol_to_stmt = sym_to_stmt,
        .sym_to_side_effect_stmts = sym_to_se_stmts,
        .sym_to_referencing_stmts = sym_to_ref_stmts,
        .allocator = allocator,
    };
}
