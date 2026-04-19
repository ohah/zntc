//! ZTS Bundler — Statement-Level Tree-Shaking
//!
//! 모듈 내 top-level statement 단위로 미사용 코드를 제거한다.
//! tree_shaker가 결정한 used exports를 기반으로, 각 statement의
//! 선언/참조 심볼을 분석하여 도달 불가능한 statement를 skip_nodes에 추가한다.
//!
//! esbuild의 Part 시스템, rolldown의 StmtInfo와 유사한 역할.
//! 단, ZTS에서는 별도 모듈로 분리하여 tree_shaker(모듈 단위)와
//! 역할을 명확히 구분한다.

const std = @import("std");
const Ast = @import("../parser/ast.zig").Ast;
const Node = @import("../parser/ast.zig").Node;
const NodeIndex = @import("../parser/ast.zig").NodeIndex;
const Span = @import("../lexer/token.zig").Span;
const purity = @import("purity.zig");

const StmtInfo = struct {
    node_idx: u32,
    span: Span,
    is_reachable: bool = false,
    has_side_effects: bool = true,
};

/// top-level statement 단위로 미사용 코드를 식별하여 skip_nodes에 추가한다.
///
/// used_export_names: tree_shaker가 결정한 이 모듈의 사용된 export local names.
/// skip_nodes: linker가 생성한 bitset — 여기에 미사용 statement 노드를 추가한다.
pub fn markUnusedStatements(
    allocator: std.mem.Allocator,
    ast: *const Ast,
    root: NodeIndex,
    used_export_names: []const []const u8,
    skip_nodes: *std.DynamicBitSet,
    unresolved_globals: ?*const purity.GlobalRefSet,
) !void {
    const root_ni = @intFromEnum(root);
    if (root_ni >= ast.nodes.items.len) return;
    const root_node = ast.nodes.items[root_ni];
    if (root_node.tag != .program) return;

    const list = root_node.data.list;
    if (list.len == 0) return;
    if (list.start + list.len > ast.extra_data.items.len) return;
    const stmt_raw_indices = ast.extra_data.items[list.start .. list.start + list.len];

    var stmts = try allocator.alloc(StmtInfo, stmt_raw_indices.len);
    defer allocator.free(stmts);

    var name_to_stmt: std.StringHashMapUnmanaged(u32) = .{};
    defer name_to_stmt.deinit(allocator);

    var removable_count: u32 = 0;

    for (stmt_raw_indices, 0..) |raw_idx, i| {
        const idx: NodeIndex = @enumFromInt(raw_idx);
        const ni = @intFromEnum(idx);
        if (ni >= ast.nodes.items.len) {
            stmts[i] = .{ .node_idx = @intCast(ni), .span = .{ .start = 0, .end = 0 } };
            continue;
        }
        const node = ast.nodes.items[ni];

        stmts[i] = .{
            .node_idx = @intCast(ni),
            .span = node.span,
            .has_side_effects = true,
        };

        // 선언 이름 추출 + side effects 판정
        try extractDeclaredNames(ast, node, @intCast(i), &name_to_stmt, allocator);
        stmts[i].has_side_effects = hasSideEffects(ast, node, unresolved_globals);
        if (!stmts[i].has_side_effects) removable_count += 1;
    }

    if (removable_count == 0) return;

    // statements가 소스 순서(span.start)로 정렬되어 있는지 검증 (binary search 전제)
    if (std.debug.runtime_safety) {
        for (1..stmts.len) |i| {
            std.debug.assert(stmts[i].span.start >= stmts[i - 1].span.start);
        }
    }

    // 각 statement의 참조 이름 수집 (span containment 기반)
    var stmt_refs = try allocator.alloc(std.StringHashMapUnmanaged(void), stmts.len);
    defer {
        for (stmt_refs) |*s| s.deinit(allocator);
        allocator.free(stmt_refs);
    }
    for (stmt_refs) |*s| s.* = .{};

    collectReferences(allocator, ast, stmts, stmt_refs, &name_to_stmt) catch return;

    var queue: std.ArrayListUnmanaged(u32) = .empty;
    defer queue.deinit(allocator);

    // seed: side-effectful statements + used exports
    for (stmts, 0..) |*stmt, i| {
        if (stmt.has_side_effects) {
            stmt.is_reachable = true;
            try queue.append(allocator, @intCast(i));
        }
    }

    for (used_export_names) |name| {
        if (name_to_stmt.get(name)) |si| {
            if (!stmts[si].is_reachable) {
                stmts[si].is_reachable = true;
                try queue.append(allocator, si);
            }
        }
    }

    var head: u32 = 0;
    while (head < queue.items.len) : (head += 1) {
        const si = queue.items[head];
        var ref_it = stmt_refs[si].keyIterator();
        while (ref_it.next()) |ref_name| {
            if (name_to_stmt.get(ref_name.*)) |dep_si| {
                if (!stmts[dep_si].is_reachable) {
                    stmts[dep_si].is_reachable = true;
                    try queue.append(allocator, dep_si);
                }
            }
        }
    }

    for (stmts) |stmt| {
        if (!stmt.is_reachable and stmt.node_idx < skip_nodes.capacity()) {
            skip_nodes.set(stmt.node_idx);
        }
    }
}

/// statement에서 선언된 top-level 이름을 추출하여 name_to_stmt에 등록한다.
fn extractDeclaredNames(
    ast: *const Ast,
    node: Node,
    stmt_idx: u32,
    name_to_stmt: *std.StringHashMapUnmanaged(u32),
    allocator: std.mem.Allocator,
) !void {
    switch (node.tag) {
        .function_declaration => {
            if (getFunctionName(ast, node)) |name| {
                try name_to_stmt.put(allocator, name, stmt_idx);
            }
        },
        .class_declaration => {
            if (getClassName(ast, node)) |name| {
                try name_to_stmt.put(allocator, name, stmt_idx);
            }
        },
        .variable_declaration => {
            try extractVarDeclNames(ast, node, stmt_idx, name_to_stmt, allocator);
        },
        .export_named_declaration => {
            // export function f() {} / export const x = 1
            const e = node.data.extra;
            if (e + 3 < ast.extra_data.items.len) {
                const decl_idx: NodeIndex = @enumFromInt(ast.extra_data.items[e]);
                if (!decl_idx.isNone() and @intFromEnum(decl_idx) < ast.nodes.items.len) {
                    const inner = ast.nodes.items[@intFromEnum(decl_idx)];
                    try extractDeclaredNames(ast, inner, stmt_idx, name_to_stmt, allocator);
                }
            }
        },
        .export_default_declaration => {
            try name_to_stmt.put(allocator, "default", stmt_idx);
            // inner declaration의 이름도 등록 (export default function foo() {})
            const inner_idx = node.data.unary.operand;
            if (!inner_idx.isNone() and @intFromEnum(inner_idx) < ast.nodes.items.len) {
                const inner = ast.nodes.items[@intFromEnum(inner_idx)];
                try extractDeclaredNames(ast, inner, stmt_idx, name_to_stmt, allocator);
            }
        },
        else => {},
    }
}

/// function declaration에서 이름 추출. extra[0] = name_idx
fn getFunctionName(ast: *const Ast, node: Node) ?[]const u8 {
    const e = node.data.extra;
    if (e >= ast.extra_data.items.len) return null;
    const name_idx: NodeIndex = @enumFromInt(ast.extra_data.items[e]);
    if (name_idx.isNone()) return null;
    const ni = @intFromEnum(name_idx);
    if (ni >= ast.nodes.items.len) return null;
    const name_node = ast.nodes.items[ni];
    return ast.getText(name_node.span);
}

/// class declaration에서 이름 추출. extra[0] = name_idx
fn getClassName(ast: *const Ast, node: Node) ?[]const u8 {
    return getFunctionName(ast, node); // 같은 레이아웃
}

/// variable declaration에서 declarator 이름들을 추출.
/// extra = [kind_flags, list_start, list_len]
fn extractVarDeclNames(
    ast: *const Ast,
    node: Node,
    stmt_idx: u32,
    name_to_stmt: *std.StringHashMapUnmanaged(u32),
    allocator: std.mem.Allocator,
) !void {
    const e = node.data.extra;
    if (e + 2 >= ast.extra_data.items.len) return;
    const list_start = ast.extra_data.items[e + 1];
    const list_len = ast.extra_data.items[e + 2];
    if (list_len == 0) return;

    var i: u32 = 0;
    while (i < list_len) : (i += 1) {
        const idx = list_start + i;
        if (idx >= ast.extra_data.items.len) break;
        const decl_idx: NodeIndex = @enumFromInt(ast.extra_data.items[idx]);
        if (decl_idx.isNone()) continue;
        const decl_ni = @intFromEnum(decl_idx);
        if (decl_ni >= ast.nodes.items.len) continue;
        const decl_node = ast.nodes.items[decl_ni];
        if (decl_node.tag != .variable_declarator) continue;

        // variable_declarator: extra [name, type_ann, init_expr]
        const de = decl_node.data.extra;
        if (de >= ast.extra_data.items.len) continue;
        const name_idx: NodeIndex = @enumFromInt(ast.extra_data.items[de]);
        if (name_idx.isNone()) continue;
        const name_ni = @intFromEnum(name_idx);
        if (name_ni >= ast.nodes.items.len) continue;
        const name_node = ast.nodes.items[name_ni];
        switch (name_node.tag) {
            .object_pattern => try extractObjectPatternNames(ast, name_node, stmt_idx, name_to_stmt, allocator),
            .array_pattern => try extractArrayPatternNames(ast, name_node, stmt_idx, name_to_stmt, allocator),
            else => {
                const name = ast.getText(name_node.span);
                if (name.len > 0) {
                    try name_to_stmt.put(allocator, name, stmt_idx);
                }
            },
        }
    }
}

/// object pattern ({ a, b: c, ...rest }) 에서 바인딩 이름을 추출.
fn extractObjectPatternNames(
    ast: *const Ast,
    pattern: Node,
    stmt_idx: u32,
    name_to_stmt: *std.StringHashMapUnmanaged(u32),
    allocator: std.mem.Allocator,
) std.mem.Allocator.Error!void {
    const list = pattern.data.list;
    if (list.len == 0) return;
    if (list.start + list.len > ast.extra_data.items.len) return;
    const indices = ast.extra_data.items[list.start .. list.start + list.len];
    for (indices) |raw_idx| {
        const prop_idx: NodeIndex = @enumFromInt(raw_idx);
        if (prop_idx.isNone() or @intFromEnum(prop_idx) >= ast.nodes.items.len) continue;
        const prop = ast.nodes.items[@intFromEnum(prop_idx)];
        if (prop.tag == .binding_property) {
            // shorthand { X } → left == right, rename { X: Y } → right=value
            const val_idx = prop.data.binary.right;
            if (!val_idx.isNone() and @intFromEnum(val_idx) < ast.nodes.items.len) {
                const val = ast.nodes.items[@intFromEnum(val_idx)];
                if (val.tag == .object_pattern) {
                    try extractObjectPatternNames(ast, val, stmt_idx, name_to_stmt, allocator);
                } else if (val.tag == .array_pattern) {
                    try extractArrayPatternNames(ast, val, stmt_idx, name_to_stmt, allocator);
                } else if (val.tag == .assignment_pattern) {
                    // { a = 1 } → assignment_pattern { left=binding, right=default }
                    const binding_idx = val.data.binary.left;
                    if (!binding_idx.isNone() and @intFromEnum(binding_idx) < ast.nodes.items.len) {
                        const binding = ast.nodes.items[@intFromEnum(binding_idx)];
                        const name = ast.getText(binding.span);
                        if (name.len > 0) try name_to_stmt.put(allocator, name, stmt_idx);
                    }
                } else {
                    const name = ast.getText(val.span);
                    if (name.len > 0) try name_to_stmt.put(allocator, name, stmt_idx);
                }
            }
        } else if (prop.tag == .rest_element) {
            const arg = prop.data.unary.operand;
            if (!arg.isNone() and @intFromEnum(arg) < ast.nodes.items.len) {
                const name = ast.getText(ast.nodes.items[@intFromEnum(arg)].span);
                if (name.len > 0) try name_to_stmt.put(allocator, name, stmt_idx);
            }
        }
    }
}

/// array pattern ([a, b, ...rest]) 에서 바인딩 이름을 추출.
fn extractArrayPatternNames(
    ast: *const Ast,
    pattern: Node,
    stmt_idx: u32,
    name_to_stmt: *std.StringHashMapUnmanaged(u32),
    allocator: std.mem.Allocator,
) std.mem.Allocator.Error!void {
    const list = pattern.data.list;
    if (list.len == 0) return;
    if (list.start + list.len > ast.extra_data.items.len) return;
    const indices = ast.extra_data.items[list.start .. list.start + list.len];
    for (indices) |raw_idx| {
        const elem_idx: NodeIndex = @enumFromInt(raw_idx);
        if (elem_idx.isNone() or @intFromEnum(elem_idx) >= ast.nodes.items.len) continue;
        const elem = ast.nodes.items[@intFromEnum(elem_idx)];
        if (elem.tag == .object_pattern) {
            try extractObjectPatternNames(ast, elem, stmt_idx, name_to_stmt, allocator);
        } else if (elem.tag == .array_pattern) {
            try extractArrayPatternNames(ast, elem, stmt_idx, name_to_stmt, allocator);
        } else if (elem.tag == .rest_element) {
            const arg = elem.data.unary.operand;
            if (!arg.isNone() and @intFromEnum(arg) < ast.nodes.items.len) {
                const name = ast.getText(ast.nodes.items[@intFromEnum(arg)].span);
                if (name.len > 0) try name_to_stmt.put(allocator, name, stmt_idx);
            }
        } else if (elem.tag == .assignment_pattern) {
            // [a = 1] → assignment_pattern { left=binding, right=default }
            const binding_idx = elem.data.binary.left;
            if (!binding_idx.isNone() and @intFromEnum(binding_idx) < ast.nodes.items.len) {
                const binding = ast.nodes.items[@intFromEnum(binding_idx)];
                const name = ast.getText(binding.span);
                if (name.len > 0) try name_to_stmt.put(allocator, name, stmt_idx);
            }
        } else {
            const name = ast.getText(elem.span);
            if (name.len > 0) try name_to_stmt.put(allocator, name, stmt_idx);
        }
    }
}

/// statement가 side effects를 가지는지 보수적으로 판정한다.
/// import/export 문은 linker skip_nodes와 충돌 방지를 위해 항상 side-effectful로 처리.
fn hasSideEffects(ast: *const Ast, node: Node, unresolved_globals: ?*const purity.GlobalRefSet) bool {
    // import는 linker가 skip_nodes로 관리하므로 side-effectful 유지
    if (node.tag == .import_declaration) return true;
    return purity.stmtHasSideEffects(ast, node, unresolved_globals);
}

/// 모든 AST 노드를 순회하면서 identifier_reference를 찾고,
/// span containment로 소속 top-level statement을 결정하여 참조 기록.
fn collectReferences(
    allocator: std.mem.Allocator,
    ast: *const Ast,
    stmts: []const StmtInfo,
    stmt_refs: []std.StringHashMapUnmanaged(void),
    name_to_stmt: *const std.StringHashMapUnmanaged(u32),
) !void {
    if (stmts.len == 0) return;

    for (ast.nodes.items) |node| {
        // identifier_reference + assignment_target_identifier 모두 추적
        // (++x, x = ..., [x] = ... 등에서 x는 assignment_target_identifier)
        const is_ref = switch (node.tag) {
            .identifier_reference, .assignment_target_identifier => true,
            else => false,
        };
        if (!is_ref) continue;

        const name = ast.getText(node.span);
        if (!name_to_stmt.contains(name)) continue;

        const containing_idx = findContainingStmt(stmts, node.span.start) orelse continue;

        try stmt_refs[containing_idx].put(allocator, name, {});
    }
}

/// binary search로 주어진 위치를 포함하는 top-level statement를 찾는다.
fn findContainingStmt(stmts: []const StmtInfo, pos: u32) ?usize {
    if (stmts.len == 0) return null;

    // span.start 기준으로 정렬되어 있다고 가정 (AST 순서)
    var lo: usize = 0;
    var hi: usize = stmts.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (stmts[mid].span.end <= pos) {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    if (lo < stmts.len and stmts[lo].span.start <= pos and pos < stmts[lo].span.end) {
        return lo;
    }
    return null;
}
