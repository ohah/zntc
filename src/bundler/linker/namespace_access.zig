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

    pub const DeclRange = struct { start: u32, end: u32 };

    pub fn build(allocator: std.mem.Allocator, ast: *const Ast) std.mem.Allocator.Error!NamespaceAccessIndex {
        var self: NamespaceAccessIndex = .{};
        errdefer self.deinit(allocator);
        const node_count = ast.nodes.items.len;
        for (ast.nodes.items) |node| {
            switch (node.tag) {
                .static_member_expression, .private_field_expression => {
                    const e = node.data.extra;
                    if (!ast.hasExtra(e, 2)) continue;
                    const obj_idx = ast.readExtra(e, 0);
                    const prop_idx = ast.readExtra(e, 1);
                    if (obj_idx < node_count and prop_idx < node_count) {
                        try self.prop_by_obj.put(allocator, obj_idx, prop_idx);
                    }
                },
                .import_declaration => {
                    try self.decl_ranges.append(allocator, .{ .start = node.span.start, .end = node.span.end });
                },
                else => {},
            }
        }
        return self;
    }

    pub fn deinit(self: *NamespaceAccessIndex, allocator: std.mem.Allocator) void {
        self.prop_by_obj.deinit(allocator);
        self.decl_ranges.deinit(allocator);
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
    return analyzeNamespaceAccessWithIndex(allocator, ast, symbol_ids, ns_sym_id, stmt_spans, &index);
}

/// `analyzeNamespaceAccess` 의 ns_sym_id-의존 후반부만 분리.
/// 호출자가 `NamespaceAccessIndex` 를 한 번 구축해 여러 namespace 심볼에 재사용 (#1735).
pub fn analyzeNamespaceAccessWithIndex(
    allocator: std.mem.Allocator,
    ast: *const Ast,
    symbol_ids: []const ?u32,
    ns_sym_id: u32,
    stmt_spans: ?[]const Span,
    index: *const NamespaceAccessIndex,
) std.mem.Allocator.Error!NamespaceAccess {
    const node_count = ast.nodes.items.len;
    var access: NamespaceAccess = .{ .kind = .member_only };
    errdefer access.deinit(allocator);
    if (node_count == 0) return access;

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

        var in_decl = false;
        for (index.decl_ranges.items) |r| {
            if (node.span.start >= r.start and node.span.end <= r.end) {
                in_decl = true;
                break;
            }
        }
        if (in_decl) continue;

        if (index.prop_by_obj.get(@intCast(node_i))) |prop_node_idx| {
            const prop_node = ast.nodes.items[prop_node_idx];
            const name = ast.getText(prop_node.span);
            if (name.len == 0) continue;

            const gop = try access.members.getOrPut(allocator, name);
            if (!gop.found_existing) gop.value_ptr.* = .empty;

            if (stmt_spans) |spans| {
                if (stmt_info_mod.findStmtForPos(spans, node.span.start)) |stmt_idx| {
                    const list = gop.value_ptr;
                    var exists = false;
                    for (list.items) |existing| {
                        if (existing == stmt_idx) {
                            exists = true;
                            break;
                        }
                    }
                    if (!exists) try list.append(allocator, stmt_idx);
                }
            }
        } else {
            access.deinit(allocator);
            access.members = .{};
            access.kind = .@"opaque";
            return access;
        }
    }

    return access;
}
