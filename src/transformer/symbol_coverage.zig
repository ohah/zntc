//! 디버그: 트랜스포머가 **새로 만든** 사용자 식별자 노드의 심볼 ID 누락을 찾는다 (#4760).
//!
//! 심볼 기준 블록 스코핑(`symbol_ids` → 코드 생성 `renames`)은 출력 식별자가 모두 제 심볼을
//! 가리켜야 동작한다. 트랜스포머가 사용자 식별자를 새 노드로 다시 만들며 `propagateSymbolId`
//! 를 빠뜨리면 그 노드만 옛 이름으로 나간다(#4703·#4712 의 minify 결함이 이 경우).
//!
//! 판정:
//! - 파서 노드(`< parser_node_count`)는 분석기가 준 심볼을 그대로 가지므로 보지 않는다
//!   (거기서 심볼이 없으면 전역 등 미해결 참조다).
//! - 새 노드 중 이름(리네임 접미사 `$N` 제외)이 모듈에 선언된 심볼 이름과 같으면 "사용자
//!   식별자"로 보고, 심볼 ID 가 없으면 누락이다. 합성 임시 변수(`_a`·`_step` …)는 사용자
//!   이름과 겹치지 않게 만들어지므로 대상이 아니다.
//!
//! `ZNTC_DEBUG_SYMBOL_COVERAGE=1` 일 때만 변환 경로에서 돈다.

const std = @import("std");
const ast_mod = @import("../parser/ast.zig");
const ast_walk = @import("../parser/ast_walk.zig");
const Ast = ast_mod.Ast;
const Node = ast_mod.Node;
const NodeIndex = ast_mod.NodeIndex;
const Symbol = @import("../semantic/symbol.zig").Symbol;

pub const Finding = struct { name: []const u8, tag: Node.Tag };

pub const Report = struct {
    /// 새로 만든 사용자 식별자 노드 수
    new_user_idents: usize = 0,
    /// 그중 심볼 ID 가 없는 노드
    missing: std.ArrayList(Finding) = .empty,

    pub fn deinit(self: *Report, allocator: std.mem.Allocator) void {
        self.missing.deinit(allocator);
    }
};

/// `x$12` → `x`. 접미사가 없으면 그대로.
fn baseName(name: []const u8) []const u8 {
    const dollar = std.mem.lastIndexOfScalar(u8, name, '$') orelse return name;
    if (dollar == 0 or dollar + 1 == name.len) return name;
    for (name[dollar + 1 ..]) |c| {
        if (c < '0' or c > '9') return name;
    }
    return name[0..dollar];
}

const Ctx = struct {
    allocator: std.mem.Allocator,
    ast: *const Ast,
    parser_node_count: u32,
    symbol_ids: []const ?u32,
    names: *const std.StringHashMapUnmanaged(void),
    report: *Report,
    /// 속성·키 자리의 식별자 — 변수가 아니라 이름이므로 세지 않는다.
    name_positions: std.AutoHashMapUnmanaged(u32, void) = .empty,
    oom: bool = false,

    fn markName(ctx: *Ctx, idx: NodeIndex) void {
        if (idx.isNone()) return;
        if (ctx.ast.getNode(idx).tag == .computed_property_key) return;
        ctx.name_positions.put(ctx.allocator, @intFromEnum(idx), {}) catch {
            ctx.oom = true;
        };
    }
};

fn visit(ctx: *Ctx, idx: NodeIndex, node: Node) ast_walk.WalkAction {
    switch (node.tag) {
        .identifier_reference, .binding_identifier, .assignment_target_identifier => {},
        // `o.x` 의 x, `{ k: v }`·`{ k: pattern }` 의 k, 메서드·필드 이름은 변수가 아니다.
        // 축약형(`{ x }`)은 키가 곧 값 참조라 센다.
        .static_member_expression => {
            ctx.markName(@enumFromInt(ctx.ast.extra_data.items[node.data.extra + 1]));
            return .descend;
        },
        .object_property, .binding_property => {
            const k = node.data.binary.left;
            const v = node.data.binary.right;
            if (!v.isNone() and v != k) ctx.markName(k);
            return .descend;
        },
        .method_definition, .property_definition, .accessor_property => {
            ctx.markName(@enumFromInt(ctx.ast.extra_data.items[node.data.extra]));
            return .descend;
        },
        else => return .descend,
    }
    const i = @intFromEnum(idx);
    if (i < ctx.parser_node_count) return .descend;
    if (ctx.name_positions.contains(i)) return .descend;
    const name = ctx.ast.getText(node.data.string_ref);
    if (!ctx.names.contains(baseName(name))) return .descend;
    ctx.report.new_user_idents += 1;
    const has = i < ctx.symbol_ids.len and ctx.symbol_ids[i] != null;
    if (!has) ctx.report.missing.append(ctx.allocator, .{ .name = name, .tag = node.tag }) catch {
        ctx.oom = true;
    };
    return .descend;
}

pub fn check(
    allocator: std.mem.Allocator,
    ast: *const Ast,
    root: NodeIndex,
    parser_node_count: u32,
    symbol_ids: []const ?u32,
    symbols: []const Symbol,
) std.mem.Allocator.Error!Report {
    var names: std.StringHashMapUnmanaged(void) = .empty;
    defer names.deinit(allocator);
    for (symbols) |sym| try names.put(allocator, ast.getText(sym.name), {});

    var report: Report = .{};
    errdefer report.deinit(allocator);
    var ctx: Ctx = .{
        .allocator = allocator,
        .ast = ast,
        .parser_node_count = parser_node_count,
        .symbol_ids = symbol_ids,
        .names = &names,
        .report = &report,
    };
    defer ctx.name_positions.deinit(allocator);
    try ast_walk.walkPreorderIterative(allocator, ast, root, &ctx, visit);
    if (ctx.oom) return error.OutOfMemory;
    return report;
}

/// stderr 한 줄 요약 + 누락 목록(이름·태그별 개수).
pub fn print(allocator: std.mem.Allocator, file_path: []const u8, report: *const Report) void {
    var counts: std.StringArrayHashMapUnmanaged(usize) = .empty;
    defer {
        for (counts.keys()) |k| allocator.free(k);
        counts.deinit(allocator);
    }
    for (report.missing.items) |f| {
        const key = std.fmt.allocPrint(allocator, "{s}({s})", .{ f.name, @tagName(f.tag) }) catch return;
        const gop = counts.getOrPut(allocator, key) catch return;
        if (gop.found_existing) {
            allocator.free(key);
            gop.value_ptr.* += 1;
        } else gop.value_ptr.* = 1;
    }
    std.debug.print("zntc: symbol-coverage {s}: new_user_idents={d} missing={d}\n", .{ file_path, report.new_user_idents, report.missing.items.len });
    for (counts.keys(), counts.values()) |k, v| std.debug.print("  missing {s} x{d}\n", .{ k, v });
}

test "baseName strips rename suffix" {
    try std.testing.expectEqualStrings("x", baseName("x$12"));
    try std.testing.expectEqualStrings("x$", baseName("x$"));
    try std.testing.expectEqualStrings("$x", baseName("$x"));
    try std.testing.expectEqualStrings("a$b", baseName("a$b"));
}
