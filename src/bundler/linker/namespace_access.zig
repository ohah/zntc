//! Namespace import access analysis used by linker metadata.

const std = @import("std");
const Span = @import("../../lexer/token.zig").Span;
const Ast = @import("../../parser/ast.zig").Ast;
const stmt_info_mod = @import("../stmt_info.zig");

/// namespace 식별자가 member access 이외의 위치에서 사용되는지 판별.
/// `ns.prop`만 사용되면 false (직접 치환 가능), `console.log(ns)` 등이면 true (객체 필요).
pub fn isNamespaceUsedAsValue(allocator: std.mem.Allocator, ast: *const Ast, symbol_ids: []const ?u32, ns_sym_id: u32) bool {
    const node_count = ast.nodes.items.len;
    if (node_count == 0) return false;

    var safe = std.DynamicBitSet.initEmpty(allocator, node_count) catch return true;
    defer safe.deinit();

    for (ast.nodes.items) |node| {
        if (node.tag == .static_member_expression or node.tag == .private_field_expression) {
            const e = node.data.extra;
            if (ast.hasExtra(e, 2)) {
                const obj_idx = ast.readExtra(e, 0);
                if (obj_idx < node_count) safe.set(obj_idx);
            }
        }
    }

    for (symbol_ids, 0..) |maybe_sid, node_i| {
        if (maybe_sid) |sid| {
            if (sid == ns_sym_id) {
                if (node_i < node_count) {
                    const tag = ast.nodes.items[node_i].tag;
                    if (tag == .import_namespace_specifier or tag == .import_default_specifier or
                        tag == .import_specifier or tag == .binding_identifier) continue;
                }
                if (node_i >= node_count or !safe.isSet(node_i)) return true;
            }
        }
    }
    return false;
}

/// namespace 심볼에 대한 AST 수준의 멤버 접근 정밀도 분석 결과 (#1603 Phase 1).
pub const NamespaceAccess = struct {
    kind: Kind,
    /// property → 해당 `ns.prop` 접근이 발생한 top-level stmt 인덱스 목록.
    /// stmt_spans가 전달된 경우에만 채워지며, 없으면 빈 리스트.
    members: std.StringHashMapUnmanaged(std.ArrayListUnmanaged(u32)) = .{},

    pub const Kind = enum { member_only, @"opaque" };

    pub fn deinit(self: *NamespaceAccess, allocator: std.mem.Allocator) void {
        var it = self.members.valueIterator();
        while (it.next()) |list| list.deinit(allocator);
        self.members.deinit(allocator);
    }
};

/// `analyzeNamespaceAccess` 의 ns_sym_id-독립 인덱스.
/// 같은 AST 를 여러 namespace import 로 분석할 때 공유해 AST 전체 순회를 줄인다 (#1735).
pub const NamespaceAccessIndex = struct {
    /// obj_node_idx → prop_node_idx 매핑 (static/private member expression).
    prop_by_obj: std.AutoHashMapUnmanaged(u32, u32) = .{},
    /// import declaration span 범위 — 이 안의 identifier_reference 는 선언이므로 skip.
    decl_ranges: std.ArrayListUnmanaged(DeclRange) = .empty,
    /// text-fallback 색인 (#3680 옵션 A): obj 가 identifier_reference 인 member access 를
    /// `obj_text → [IdentAccess...]` 로 색인. transformer 가 namespace local 의 symbol_id 를
    /// rebind/invalidate 해서 symbol_id 매칭이 0건이 되는 case 의 fallback 전용.
    ///
    /// 키 lifetime: `ast.getText` 결과 (source buffer 또는 string_table 슬라이스). ast 수명 동안만 유효.
    /// 즉 build → analyze 동안 ast 가 mutate (transformer 의 addString 등) 되면 invalidate. 단일 단계 사용 강제.
    accesses_by_obj_text: std.StringHashMapUnmanaged(std.ArrayListUnmanaged(IdentAccess)) = .{},

    /// escape 색인 (F1 fix): 모든 identifier_reference 의 `text → [(node_idx, span_start)...]`.
    /// text fallback 진입 시 `idents_by_text[local_name]` 의 각 node_idx 가 `prop_by_obj` 에
    /// 있으면 member-obj, 없으면 escape (value position) — opaque return 으로 over-prune 회피.
    idents_by_text: std.StringHashMapUnmanaged(std.ArrayListUnmanaged(IdentRef)) = .{},

    pub const DeclRange = struct { start: u32, end: u32 };

    pub const IdentAccess = struct {
        prop_node_idx: u32,
        obj_span_start: u32,
    };

    pub const IdentRef = struct {
        node_idx: u32,
        span_start: u32,
    };

    pub fn build(allocator: std.mem.Allocator, ast: *const Ast) std.mem.Allocator.Error!NamespaceAccessIndex {
        var self: NamespaceAccessIndex = .{};
        errdefer self.deinit(allocator);
        const node_count = ast.nodes.items.len;
        for (ast.nodes.items, 0..) |node, node_i| {
            if (node.tag == .static_member_expression or node.tag == .private_field_expression) {
                const e = node.data.extra;
                if (!ast.hasExtra(e, 2)) continue;
                const obj_idx = ast.readExtra(e, 0);
                const prop_idx = ast.readExtra(e, 1);
                if (obj_idx >= node_count or prop_idx >= node_count) continue;
                try self.prop_by_obj.put(allocator, obj_idx, prop_idx);
                // text fallback 색인: obj 가 identifier_reference 인 경우만.
                const obj_node = ast.nodes.items[obj_idx];
                if (obj_node.tag != .identifier_reference) continue;
                const obj_text = ast.getText(obj_node.span);
                if (obj_text.len == 0) continue;
                const gop = try self.accesses_by_obj_text.getOrPut(allocator, obj_text);
                if (!gop.found_existing) gop.value_ptr.* = .empty;
                try gop.value_ptr.append(allocator, .{
                    .prop_node_idx = prop_idx,
                    .obj_span_start = obj_node.span.start,
                });
            } else if (node.tag == .identifier_reference) {
                // F1 fix: escape 검사용 — 모든 identifier_reference 의 text 색인.
                const text = ast.getText(node.span);
                if (text.len == 0) continue;
                const gop = try self.idents_by_text.getOrPut(allocator, text);
                if (!gop.found_existing) gop.value_ptr.* = .empty;
                try gop.value_ptr.append(allocator, .{
                    .node_idx = @intCast(node_i),
                    .span_start = node.span.start,
                });
            } else if (node.tag == .import_declaration) {
                try self.decl_ranges.append(allocator, .{ .start = node.span.start, .end = node.span.end });
            }
        }
        return self;
    }

    pub fn deinit(self: *NamespaceAccessIndex, allocator: std.mem.Allocator) void {
        self.prop_by_obj.deinit(allocator);
        self.decl_ranges.deinit(allocator);
        var it = self.accesses_by_obj_text.valueIterator();
        while (it.next()) |list| list.deinit(allocator);
        self.accesses_by_obj_text.deinit(allocator);
        var it2 = self.idents_by_text.valueIterator();
        while (it2.next()) |list| list.deinit(allocator);
        self.idents_by_text.deinit(allocator);
    }
};

/// namespace 심볼의 모든 참조를 스캔해 member-only 접근 여부와 접근된 프로퍼티 집합을 수집.
///
/// member_only 조건:
///   - 모든 ns 참조가 `static_member_expression` / `private_field_expression`의 object 위치
///   - import specifier / binding_identifier 등 선언 위치는 제외 (참조 아님)
///
/// opaque 처리되는 경우:
///   - 값 전달(`f(ns)`), spread(`{...ns}`), 리플렉션(`Object.keys(ns)`)
///   - computed access (`ns[key]`) — key가 동적이라 정밀도 보장 불가
///
/// 주의: members의 문자열은 `ast.getText` 결과 (source 버퍼 참조). ast 수명 동안만 유효.
pub fn analyzeNamespaceAccess(
    allocator: std.mem.Allocator,
    ast: *const Ast,
    symbol_ids: []const ?u32,
    ns_sym_id: u32,
    /// top-level statement의 source span. 전달하면 각 access의 owning stmt 인덱스를
    /// `members[prop]`에 기록 (#1626 dead-scope gating). null이면 기록하지 않는다.
    stmt_spans: ?[]const Span,
) std.mem.Allocator.Error!NamespaceAccess {
    var index = try NamespaceAccessIndex.build(allocator, ast);
    defer index.deinit(allocator);
    return analyzeNamespaceAccessWithIndex(allocator, ast, symbol_ids, ns_sym_id, stmt_spans, &index, null);
}

/// `analyzeNamespaceAccess` 의 ns_sym_id-의존 후반부만 분리.
/// 호출자가 `NamespaceAccessIndex` 를 한 번 구축해 여러 namespace 심볼에 재사용 (#1735).
///
/// `ns_local_name` 이 주어지면 (#3680 옵션 A) text fallback 활성화:
/// transformer 가 namespace local 의 symbol_id 를 rebind/invalidate 해 *symbol_id 매칭 0건* 인 경우만
/// text 매칭으로 보강. **symbol_id 매칭이 1건이라도 있으면 fallback skip** — symbol_id 가 정확하다고
/// 신뢰. 이렇게 게이팅 하지 않으면 function param / block-scope 의 같은 이름 binding 도 잡혀
/// shadow false-positive (counter$4 fix 후 #1603 wrapper-barrel lazy 정밀성 회귀).
///
/// 즉 fallback 은 "정상 case (symbol matched > 0) 는 영향 없음, rebind case 만 회복" 의 narrow recovery.
pub fn analyzeNamespaceAccessWithIndex(
    allocator: std.mem.Allocator,
    ast: *const Ast,
    symbol_ids: []const ?u32,
    ns_sym_id: u32,
    stmt_spans: ?[]const Span,
    index: *const NamespaceAccessIndex,
    ns_local_name: ?[]const u8,
) std.mem.Allocator.Error!NamespaceAccess {
    const node_count = ast.nodes.items.len;
    var access: NamespaceAccess = .{ .kind = .member_only };
    errdefer access.deinit(allocator);
    if (node_count == 0) return access;

    // symbol_id 매칭 — symbol_ids 가 정확하면 가장 정확. transformer rebind 시 누락 가능.
    var symbol_matched: usize = 0;
    for (symbol_ids, 0..) |maybe_sid, node_i| {
        const sid = maybe_sid orelse continue;
        if (sid != ns_sym_id) continue;
        if (node_i >= node_count) {
            access.deinit(allocator);
            access.members = .{};
            access.kind = .@"opaque";
            return access;
        }

        const node = ast.nodes.items[node_i];
        const tag = node.tag;
        if (tag == .import_namespace_specifier or tag == .import_default_specifier or
            tag == .import_specifier or tag == .binding_identifier) continue;

        if (isInDecl(node.span.start, node.span.end, index.decl_ranges.items)) continue;

        symbol_matched += 1;
        if (index.prop_by_obj.get(@intCast(node_i))) |prop_node_idx| {
            try recordAccess(allocator, &access, ast, prop_node_idx, node.span.start, stmt_spans);
        } else {
            access.deinit(allocator);
            access.members = .{};
            access.kind = .@"opaque";
            return access;
        }
    }

    // text fallback (#3680 옵션 A): **symbol matched = 0 일 때만** 활성화.
    // symbol_id 가 1건이라도 잡았다면 그게 정확 — fallback 으로 shadow 까지 끌어오는 대신 신뢰.
    if (symbol_matched == 0) {
        if (ns_local_name) |local_name| {
            if (local_name.len > 0) {
                // F1 fix: escape 검사 — `idents_by_text[local]` 의 어떤 identifier_reference 가
                // `prop_by_obj` 에 없으면 (member-obj 아닌 value-position 사용) opaque 로 처리.
                // 예: `import * as M from 'x'; const ref = M; ref.foo()` — `M` 이 const init 의
                // RHS 로 escape. 안 잡으면 over-prune 으로 dangling.
                if (index.idents_by_text.get(local_name)) |refs| {
                    for (refs.items) |ir| {
                        // decl range 안의 identifier (import specifier 자체 등) 는 skip.
                        if (isInDecl(ir.span_start, ir.span_start + 1, index.decl_ranges.items)) continue;
                        if (!index.prop_by_obj.contains(ir.node_idx)) {
                            // escape detected — over-prune 방지 위해 opaque.
                            access.deinit(allocator);
                            access.members = .{};
                            access.kind = .@"opaque";
                            return access;
                        }
                    }
                }

                if (index.accesses_by_obj_text.get(local_name)) |list| {
                    for (list.items) |ia| {
                        // decl range 의 identifier (import specifier 자체) 는 skip.
                        if (isInDecl(ia.obj_span_start, ia.obj_span_start + 1, index.decl_ranges.items)) continue;
                        try recordAccess(allocator, &access, ast, ia.prop_node_idx, ia.obj_span_start, stmt_spans);
                    }
                }
            }
        }
    }

    return access;
}

/// `[start, end)` 가 `decl_ranges` 중 하나의 `[r.start, r.end)` 안에 완전히 포함되는지.
/// span 은 half-open `[start, end)` 컨벤션 — 두 path (symbol_id + text fallback) 의 비교 통일.
fn isInDecl(start: u32, end: u32, decl_ranges: []const NamespaceAccessIndex.DeclRange) bool {
    for (decl_ranges) |r| {
        if (start >= r.start and end <= r.end) return true;
    }
    return false;
}

fn recordAccess(
    allocator: std.mem.Allocator,
    access: *NamespaceAccess,
    ast: *const Ast,
    prop_node_idx: u32,
    obj_span_start: u32,
    stmt_spans: ?[]const Span,
) std.mem.Allocator.Error!void {
    const prop_node = ast.nodes.items[prop_node_idx];
    const name = ast.getText(prop_node.span);
    if (name.len == 0) return;

    const gop = try access.members.getOrPut(allocator, name);
    if (!gop.found_existing) gop.value_ptr.* = .empty;

    if (stmt_spans) |spans| {
        if (stmt_info_mod.findStmtForPos(spans, obj_span_start)) |stmt_idx| {
            const list = gop.value_ptr;
            for (list.items) |existing| if (existing == stmt_idx) return;
            try list.append(allocator, stmt_idx);
        }
    }
}
