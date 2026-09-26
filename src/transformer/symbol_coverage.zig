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
const reference_walk = @import("../semantic/reference_walk.zig");

pub const Finding = struct { name: []const u8, tag: Node.Tag };

pub const Report = struct {
    /// 새로 만든 사용자 식별자 노드 수
    new_user_idents: usize = 0,
    /// 그중 심볼 ID 가 없는 노드
    missing: std.ArrayList(Finding) = .empty,
    /// 새 노드인데 **다른 변수의** 심볼을 가진 것 — 심볼 이름과 텍스트(리네임 접미사 제외)가
    /// 다르다. 빠진 심볼보다 위험하다: 심볼 기준 리네임이 엉뚱한 변수를 따라간다 (#4763).
    wrong: std.ArrayList(Finding) = .empty,

    pub fn deinit(self: *Report, allocator: std.mem.Allocator) void {
        self.missing.deinit(allocator);
        self.wrong.deinit(allocator);
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
    /// 합성 생성 함수가 만든 노드 — 사용자 이름을 빌려 써도 사용자 식별자가 아니다.
    synthetic: ?*const std.AutoHashMapUnmanaged(u32, void),
    names: *const std.StringHashMapUnmanaged(void),
    symbols: []const Symbol,
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
        // 공용 순회는 export 지정자 목록으로 내려가지 않는다 — 로컬 export(`export { a as b }`)의
        // 로컬 쪽은 변수 참조라 직접 본다. 내보내는 이름(`b`)은 변수가 아니다.
        .export_named_declaration => {
            const e = node.data.extra;
            const source = ctx.ast.extra_data.items[e + 3];
            if (source != @intFromEnum(NodeIndex.none)) return .descend;
            const specs_start = ctx.ast.extra_data.items[e + 1];
            const specs_len = ctx.ast.extra_data.items[e + 2];
            for (ctx.ast.extra_data.items[specs_start .. specs_start + specs_len]) |raw| {
                const spec = ctx.ast.getNode(@enumFromInt(raw));
                if (spec.tag != .export_specifier) continue;
                const local = spec.data.binary.left;
                if (local.isNone()) continue;
                _ = checkIdentifier(ctx, local, ctx.ast.getNode(local));
            }
            return .descend;
        },
        else => return .descend,
    }
    return checkIdentifier(ctx, idx, node);
}

fn checkIdentifier(ctx: *Ctx, idx: NodeIndex, node: Node) ast_walk.WalkAction {
    switch (node.tag) {
        .identifier_reference, .binding_identifier, .assignment_target_identifier => {},
        else => return .descend,
    }
    const i = @intFromEnum(idx);
    if (i < ctx.parser_node_count) return .descend;
    if (ctx.synthetic) |set| {
        if (set.contains(i)) return .descend;
    }
    if (ctx.name_positions.contains(i)) return .descend;
    const name = ctx.ast.getText(node.data.string_ref);
    const sym = if (i < ctx.symbol_ids.len) ctx.symbol_ids[i] else null;
    if (sym) |sid| {
        if (sid >= ctx.symbols.len or !std.mem.eql(u8, ctx.ast.getText(ctx.symbols[sid].name), baseName(name))) {
            ctx.report.wrong.append(ctx.allocator, .{ .name = name, .tag = node.tag }) catch {
                ctx.oom = true;
            };
        }
    }
    if (!ctx.names.contains(baseName(name))) return .descend;
    ctx.report.new_user_idents += 1;
    if (sym == null) ctx.report.missing.append(ctx.allocator, .{ .name = name, .tag = node.tag }) catch {
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
    synthetic: ?*const std.AutoHashMapUnmanaged(u32, void),
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
        .synthetic = synthetic,
        .names = &names,
        .symbols = symbols,
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
    std.debug.print("zntc: symbol-coverage {s}: new_user_idents={d} missing={d} wrong={d}\n", .{ file_path, report.new_user_idents, report.missing.items.len, report.wrong.items.len });
    for (report.wrong.items) |f| std.debug.print("  wrong {s}({s})\n", .{ f.name, @tagName(f.tag) });
    for (counts.keys(), counts.values()) |k, v| std.debug.print("  missing {s} x{d}\n", .{ k, v });
}

/// Diagnostic inventory of emitted identifiers. An unbound generated read may
/// be a new global, so only bindings are definite missing-symbol findings.
/// This never infers or assigns a SymbolId from identifier text.
pub const StrictStatus = enum { bound, missing_binding, known_global, unclassified, invalid_id };
pub const StrictFinding = struct {
    node: u32,
    name: []const u8,
    tag: Node.Tag,
    status: StrictStatus,
    marked_synthetic: bool,
};
pub const StrictReport = struct {
    counts: [std.meta.fields(StrictStatus).len]usize = @splat(0),
    marked_synthetic: usize = 0,
    findings: std.ArrayList(StrictFinding) = .empty,

    pub fn deinit(self: *StrictReport, allocator: std.mem.Allocator) void {
        self.findings.deinit(allocator);
    }
};

const StrictCtx = struct {
    allocator: std.mem.Allocator,
    ast: *const Ast,
    parser_node_count: u32,
    symbol_ids: []const ?u32,
    symbol_count: usize,
    synthetic: ?*const std.AutoHashMapUnmanaged(u32, void),
    unresolved_globals: *const std.StringHashMapUnmanaged(void),
    report: *StrictReport,
    seen: std.AutoHashMapUnmanaged(u32, void) = .empty,
    oom: bool = false,

    fn add(self: *StrictCtx, idx: NodeIndex, node: Node) void {
        const raw = @intFromEnum(idx);
        if (raw < self.parser_node_count or self.seen.contains(raw)) return;
        self.seen.put(self.allocator, raw, {}) catch {
            self.oom = true;
            return;
        };
        const name = self.ast.getText(node.data.string_ref);
        const sid = if (raw < self.symbol_ids.len) self.symbol_ids[raw] else null;
        const marked = if (self.synthetic) |set| set.contains(raw) else false;
        const status: StrictStatus = if (sid) |id|
            if (id < self.symbol_count) .bound else .invalid_id
        else if (node.tag == .binding_identifier)
            .missing_binding
        else if (!marked and self.unresolved_globals.contains(name))
            .known_global
        else
            .unclassified;
        self.report.counts[@intFromEnum(status)] += 1;
        if (marked) self.report.marked_synthetic += 1;
        self.report.findings.append(self.allocator, .{
            .node = raw,
            .name = name,
            .tag = node.tag,
            .status = status,
            .marked_synthetic = marked,
        }) catch {
            self.oom = true;
        };
    }
};

fn strictBindingVisit(ctx: *StrictCtx, idx: NodeIndex, node: Node) ast_walk.WalkAction {
    if (reference_walk.isTypeOnly(node.tag)) return .skip_children;
    if (node.tag == .ts_module_declaration and node.data.binary.flags == 1) return .skip_children;
    if (node.tag == .binding_identifier) ctx.add(idx, node);
    return .descend;
}

pub fn checkStrict(
    allocator: std.mem.Allocator,
    ast: *const Ast,
    root: NodeIndex,
    parser_node_count: u32,
    symbol_ids: []const ?u32,
    symbols: []const Symbol,
    synthetic: ?*const std.AutoHashMapUnmanaged(u32, void),
    unresolved_globals: *const std.StringHashMapUnmanaged(void),
) std.mem.Allocator.Error!StrictReport {
    var report: StrictReport = .{};
    errdefer report.deinit(allocator);
    var ctx: StrictCtx = .{
        .allocator = allocator,
        .ast = ast,
        .parser_node_count = parser_node_count,
        .symbol_ids = symbol_ids,
        .symbol_count = symbols.len,
        .synthetic = synthetic,
        .unresolved_globals = unresolved_globals,
        .report = &report,
    };
    defer ctx.seen.deinit(allocator);
    try ast_walk.walkPreorderIterative(allocator, ast, root, &ctx, strictBindingVisit);
    const refs = try reference_walk.collectIdentifierReferences(allocator, ast, root);
    defer allocator.free(refs);
    for (refs) |idx| ctx.add(idx, ast.getNode(idx));
    if (ctx.oom) return error.OutOfMemory;
    return report;
}

pub fn printStrict(file_path: []const u8, report: *const StrictReport) void {
    std.debug.print(
        "zntc: synthetic-coverage {s}: bound={d} missing_binding={d} known_global={d} unclassified={d} invalid_id={d} marked_synthetic={d}\n",
        .{ file_path, report.counts[@intFromEnum(StrictStatus.bound)], report.counts[@intFromEnum(StrictStatus.missing_binding)], report.counts[@intFromEnum(StrictStatus.known_global)], report.counts[@intFromEnum(StrictStatus.unclassified)], report.counts[@intFromEnum(StrictStatus.invalid_id)], report.marked_synthetic },
    );
    var printed: [std.meta.fields(StrictStatus).len]usize = @splat(0);
    for (report.findings.items) |finding| {
        if (finding.status == .bound or finding.status == .known_global) continue;
        const group = @intFromEnum(finding.status);
        if (printed[group] == 8) continue;
        std.debug.print("  synthetic-coverage {s} node={d} {s}({s}) marked={any}\n", .{
            @tagName(finding.status), finding.node, finding.name, @tagName(finding.tag), finding.marked_synthetic,
        });
        printed[group] += 1;
    }
}

test "baseName strips rename suffix" {
    try std.testing.expectEqualStrings("x", baseName("x$12"));
    try std.testing.expectEqualStrings("x$", baseName("x$"));
    try std.testing.expectEqualStrings("$x", baseName("$x"));
    try std.testing.expectEqualStrings("a$b", baseName("a$b"));
}

test "strict inventory separates missing generated storage from unresolved reads" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var ast = Ast.init(allocator, "");
    defer ast.deinit();
    const storage = try ast.addString("_x");
    const global = try ast.addString("Object");
    const property = try ast.addString("value");
    const binding = try ast.addNode(.{ .tag = .binding_identifier, .span = storage, .data = .{ .string_ref = storage } });
    const local_read = try ast.addNode(.{ .tag = .identifier_reference, .span = storage, .data = .{ .string_ref = storage } });
    const global_read = try ast.addNode(.{ .tag = .identifier_reference, .span = global, .data = .{ .string_ref = global } });
    const static_key = try ast.addNode(.{ .tag = .identifier_reference, .span = property, .data = .{ .string_ref = property } });
    const member_extra = try ast.addExtras(&.{ @intFromEnum(local_read), @intFromEnum(static_key), 0 });
    const member = try ast.addExtraNode(.static_member_expression, storage, member_extra);
    const list = try ast.addNodeList(&.{ binding, member, global_read });
    const root = try ast.addNode(.{ .tag = .program, .span = storage, .data = .{ .list = list } });
    var marked: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer marked.deinit(allocator);
    try marked.put(allocator, @intFromEnum(binding), {});
    var unresolved: std.StringHashMapUnmanaged(void) = .empty;
    defer unresolved.deinit(allocator);
    try unresolved.put(allocator, "Object", {});
    var report = try checkStrict(allocator, &ast, root, 0, &.{}, &.{}, &marked, &unresolved);
    defer report.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), report.counts[@intFromEnum(StrictStatus.missing_binding)]);
    try std.testing.expectEqual(@as(usize, 1), report.counts[@intFromEnum(StrictStatus.unclassified)]);
    try std.testing.expectEqual(@as(usize, 1), report.counts[@intFromEnum(StrictStatus.known_global)]);
    try std.testing.expectEqual(@as(usize, 1), report.marked_synthetic);
    try std.testing.expectEqual(@intFromEnum(binding), report.findings.items[0].node);
}
