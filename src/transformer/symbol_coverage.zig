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
const SymbolId = @import("../semantic/symbol.zig").SymbolId;
const SymbolKind = @import("../semantic/symbol.zig").SymbolKind;
const Reference = @import("../semantic/symbol.zig").Reference;
const Scope = @import("../semantic/scope.zig").Scope;
const ScopeId = @import("../semantic/scope.zig").ScopeId;
const ScopeKind = @import("../semantic/scope.zig").ScopeKind;
const Span = @import("../lexer/token.zig").Span;
const module_parser = @import("../parser/module.zig");
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
                if (local != spec.data.binary.right) ctx.markName(spec.data.binary.right);
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
        if (sid >= ctx.symbols.len or !std.mem.eql(u8, baseName(exactSymbolName(ctx.ast, &ctx.symbols[sid])), baseName(name))) {
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
    for (symbols) |*sym| try names.put(allocator, baseName(exactSymbolName(ast, sym)), {});

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

/// Exact post-transform semantic identity audit. This deliberately includes
/// synthetic identifiers; spelling and `synthetic_idents` are not evidence of
/// which binding a node denotes.
pub const ExactReport = struct {
    generated_bindings: usize = 0,
    generated_references: usize = 0,
    external_references: usize = 0,
    missing_binding: usize = 0,
    invalid_reference_node: usize = 0,
    unreachable_reference: usize = 0,
    ambiguous_ast_parent: usize = 0,
    cyclic_ast_edges: usize = 0,
    invalid_ast_root: usize = 0,
    invalid_ast_edge: usize = 0,
    invalid_ast_layout: usize = 0,
    shadowed_external_reference: usize = 0,
    invalid_id: usize = 0,
    missing_reference: usize = 0,
    duplicate_reference: usize = 0,
    identity_mismatch: usize = 0,
    binding_scope_mismatch: usize = 0,
    binding_scope_unknown: usize = 0,
    invalid_scope: usize = 0,
    reference_scope_mismatch: usize = 0,
    reference_statement_mismatch: usize = 0,
    reference_scope_statement_alias: usize = 0,
    reference_node_use_alias: usize = 0,
    declaration_scope_mismatch: usize = 0,
    scope_map_mismatch: usize = 0,
    scope_owner_mismatch: usize = 0,
    scope_owner_parent_mismatch: usize = 0,
    duplicate_scope_owner: usize = 0,
    namespace_iife_params: usize = 0,
    namespace_iife_param_mismatch: usize = 0,
    enum_iife_params: usize = 0,
    enum_iife_param_mismatch: usize = 0,
    helper_symbol_mismatch: usize = 0,
    scope_resolution_mismatch: usize = 0,
    invisible_reference: usize = 0,
    unclassified_reference: usize = 0,
    reference_count_mismatch: usize = 0,
    write_count_mismatch: usize = 0,
    legacy_debt_fingerprint: u64 = 0xcbf29ce484222325,
    first_missing_binding: ?ExactFinding = null,
    first_missing_reference: ?ExactFinding = null,
    first_unclassified_reference: ?ExactFinding = null,
    first_scope_owner_mismatch: ?ScopeOwnerFinding = null,
    first_scope_owner_parent_mismatch: ?ScopeOwnerFinding = null,
    first_duplicate_scope_owner: ?ScopeOwnerFinding = null,
    first_scope_map_mismatch: ?ScopeMapFinding = null,
    first_ambiguous_ast_parent: ?AstParentFinding = null,
    first_invalid_ast_root: ?u32 = null,
    first_invalid_ast_edge: ?AstEdgeFinding = null,
    first_invalid_ast_layout: ?AstLayoutFinding = null,
    first_reference_statement_mismatch: ?ReferenceStatementFinding = null,
    first_reference_scope_statement_alias: ?ReferenceScopeStatementAliasFinding = null,
    first_reference_node_use_alias: ?ReferenceNodeUseAliasFinding = null,
    first_shadowed_external_reference: ?ExactFinding = null,

    fn isObservationField(comptime name: []const u8) bool {
        return std.mem.eql(u8, name, "generated_bindings") or
            std.mem.eql(u8, name, "generated_references") or
            std.mem.eql(u8, name, "external_references") or
            std.mem.eql(u8, name, "namespace_iife_params") or
            std.mem.eql(u8, name, "enum_iife_params") or
            std.mem.eql(u8, name, "legacy_debt_fingerprint");
    }

    fn isDiagnosticField(comptime name: []const u8) bool {
        @setEvalBranchQuota(4000);
        return std.mem.eql(u8, name, "first_missing_binding") or
            std.mem.eql(u8, name, "first_missing_reference") or
            std.mem.eql(u8, name, "first_unclassified_reference") or
            std.mem.eql(u8, name, "first_scope_owner_mismatch") or
            std.mem.eql(u8, name, "first_scope_owner_parent_mismatch") or
            std.mem.eql(u8, name, "first_duplicate_scope_owner") or
            std.mem.eql(u8, name, "first_scope_map_mismatch") or
            std.mem.eql(u8, name, "first_ambiguous_ast_parent") or
            std.mem.eql(u8, name, "first_invalid_ast_root") or
            std.mem.eql(u8, name, "first_invalid_ast_edge") or
            std.mem.eql(u8, name, "first_invalid_ast_layout") or
            std.mem.eql(u8, name, "first_reference_statement_mismatch") or
            std.mem.eql(u8, name, "first_reference_scope_statement_alias") or
            std.mem.eql(u8, name, "first_reference_node_use_alias") or
            std.mem.eql(u8, name, "first_shadowed_external_reference");
    }

    pub const SchemaCounts = struct {
        invariant_counters: usize = 0,
        observation_fields: usize = 0,
        diagnostic_fields: usize = 0,
    };

    /// Expose the complete report classification so the integration gate can
    /// prove its explicit zero-counter list still covers the emitted schema.
    /// A new field changes one of these counts and requires an intentional
    /// update to the independent fixture-gate expectations.
    pub fn schemaCounts() SchemaCounts {
        var counts: SchemaCounts = .{};
        inline for (std.meta.fields(ExactReport)) |field| {
            if (comptime isObservationField(field.name)) {
                counts.observation_fields += 1;
            } else if (comptime isDiagnosticField(field.name)) {
                counts.diagnostic_fields += 1;
            } else {
                if (comptime field.type != usize) @compileError("unclassified ExactReport field");
                counts.invariant_counters += 1;
            }
        }
        return counts;
    }

    /// Observations are allowed to be nonzero. Every other numeric field is
    /// an invariant counter and fails closed by default, so adding a new
    /// counter cannot silently leave the aggregate exact-coverage gate green.
    pub fn isClean(self: ExactReport) bool {
        inline for (std.meta.fields(ExactReport)) |field| {
            if (comptime isObservationField(field.name)) continue;
            if (comptime isDiagnosticField(field.name)) {
                if (@field(self, field.name) != null) return false;
                continue;
            }
            if (comptime field.type != usize) @compileError("unclassified ExactReport field; classify it as an observation, diagnostic, or usize invariant counter");
            if (@field(self, field.name) != 0) return false;
        }
        return true;
    }
};

pub const ExactFinding = struct {
    name: []const u8,
    tag: Node.Tag,
    node_index: u32,
    span_start: u32,
};

pub const ScopeOwnerFinding = struct {
    node_index: u32,
    tag: Node.Tag,
    issue: []const u8,
    scope_id: ?u32 = null,
    expected_kind: ?ScopeKind = null,
    actual_kind: ?ScopeKind = null,
    expected_parent_scope_id: ?u32 = null,
    actual_parent_scope_id: ?u32 = null,
    first_owner_node_index: ?u32 = null,
};

pub const ScopeMapFinding = struct {
    issue: []const u8,
    scope_id: ?u32 = null,
    symbol_id: ?u32 = null,
    name: ?[]const u8 = null,
};

pub const AstParentFinding = struct {
    node_index: u32,
    first_parent: ?u32,
    additional_parent: u32,
};

pub const ReferenceStatementFinding = struct {
    node_index: u32,
    reference_stmt_idx: ?u32,
    expected_stmt_idx: ?u32,
    first_parent: ?u32 = null,
    additional_parent: ?u32 = null,
};

pub const ReferenceScopeStatementAliasFinding = struct {
    node_index: u32,
    first_parent: u32,
    additional_parent: u32,
    first_owner: u32,
    additional_owner: u32,
    first_statement_index: u32,
    additional_statement_index: u32,
};

pub const ReferenceNodeUseAliasFinding = struct {
    node_index: u32,
    name: []const u8,
    tag: Node.Tag,
    span_start: u32,
    first_parent: u32,
    first_parent_tag: Node.Tag,
    additional_parent: u32,
    additional_parent_tag: Node.Tag,
    additional_uses: usize,
};

pub const AstEdgeFinding = struct {
    parent_node_index: u32,
    parent_tag: Node.Tag,
    child_node_index: u32,
};

pub const AstLayoutIssue = enum {
    list_range,
    extra_child_slot,
    extra_list_descriptor,
    extra_list_range,
};

pub const AstLayoutFinding = struct {
    node_index: u32,
    tag: Node.Tag,
    issue: AstLayoutIssue,
    data_index: ?usize = null,
};

fn invalidExactAstLayout(ast: *const Ast, node_index: u32) ?AstLayoutFinding {
    const node = ast.nodes.items[node_index];
    const extras = ast.extra_data.items;
    switch (Node.Tag.dataKind(node.tag)) {
        .leaf, .unary, .binary, .ternary => return null,
        .list => {
            const start: usize = node.data.list.start;
            const len: usize = node.data.list.len;
            if (start > extras.len or len > extras.len - start) return .{
                .node_index = node_index,
                .tag = node.tag,
                .issue = .list_range,
                .data_index = start,
            };
        },
        .extra => {
            const base: usize = node.data.extra;
            for (Node.Tag.extraChildOffsets(node.tag)) |offset| {
                const relative_index: usize = offset;
                if (base > extras.len or relative_index >= extras.len - base) return .{
                    .node_index = node_index,
                    .tag = node.tag,
                    .issue = .extra_child_slot,
                    .data_index = base,
                };
            }
            for (Node.Tag.extraListOffsets(node.tag)) |offsets| {
                const start_offset: usize = offsets[0];
                const len_offset: usize = offsets[1];
                if (base > extras.len or start_offset >= extras.len - base or len_offset >= extras.len - base) return .{
                    .node_index = node_index,
                    .tag = node.tag,
                    .issue = .extra_list_descriptor,
                    .data_index = base,
                };
                const start_index = base + start_offset;
                const len_index = base + len_offset;
                const start: usize = extras[start_index];
                const len: usize = extras[len_index];
                if (start > extras.len or len > extras.len - start) return .{
                    .node_index = node_index,
                    .tag = node.tag,
                    .issue = .extra_list_range,
                    .data_index = start,
                };
            }
        },
    }
    return null;
}

fn recordScopeOwnerMismatch(
    report: *ExactReport,
    node_index: u32,
    tag: Node.Tag,
    issue: []const u8,
    scope_id: ?u32,
    expected_kind: ?ScopeKind,
    actual_kind: ?ScopeKind,
) void {
    report.scope_owner_mismatch += 1;
    if (report.first_scope_owner_mismatch == null) report.first_scope_owner_mismatch = .{
        .node_index = node_index,
        .tag = tag,
        .issue = issue,
        .scope_id = scope_id,
        .expected_kind = expected_kind,
        .actual_kind = actual_kind,
    };
}

fn recordScopeOwnerParentMismatch(
    report: *ExactReport,
    node_index: u32,
    tag: Node.Tag,
    scope_id: u32,
    expected_parent_scope_id: ?u32,
    actual_parent_scope_id: ?u32,
) void {
    report.scope_owner_mismatch += 1;
    report.scope_owner_parent_mismatch += 1;
    if (report.first_scope_owner_parent_mismatch == null) report.first_scope_owner_parent_mismatch = .{
        .node_index = node_index,
        .tag = tag,
        .issue = "owner-parent-scope",
        .scope_id = scope_id,
        .expected_parent_scope_id = expected_parent_scope_id,
        .actual_parent_scope_id = actual_parent_scope_id,
    };
    if (report.first_scope_owner_mismatch == null) report.first_scope_owner_mismatch = .{
        .node_index = node_index,
        .tag = tag,
        .issue = "owner-parent-scope",
        .scope_id = scope_id,
        .expected_parent_scope_id = expected_parent_scope_id,
        .actual_parent_scope_id = actual_parent_scope_id,
    };
}

fn recordDuplicateScopeOwner(
    report: *ExactReport,
    node_index: u32,
    tag: Node.Tag,
    scope_id: u32,
    first_owner_node_index: u32,
) void {
    report.duplicate_scope_owner += 1;
    if (report.first_duplicate_scope_owner == null) report.first_duplicate_scope_owner = .{
        .node_index = node_index,
        .tag = tag,
        .issue = "duplicate-reachable-scope-owner",
        .scope_id = scope_id,
        .first_owner_node_index = first_owner_node_index,
    };
}

/// A named function expression has an intentional, ownerless block scope for
/// its self-binding between the surrounding scope and the function scope.
/// The analyzer enters both scopes while the function-expression node is the
/// current owner, so the owner map retains only the inner function scope.
fn isFunctionExpressionNameScope(
    ast: *const Ast,
    owner_node: u32,
    actual_parent: ScopeId,
    expected_parent: ScopeId,
    symbol_ids: []const ?u32,
    symbols: []const Symbol,
    scopes: []const Scope,
    scope_maps: []const std.StringHashMapUnmanaged(usize),
) bool {
    if (owner_node >= ast.nodes.items.len or ast.nodes.items[owner_node].tag != .function_expression or
        !exactValidScope(scopes, actual_parent) or !exactValidScope(scopes, expected_parent) or
        actual_parent.toIndex() >= scope_maps.len) return false;
    const extra = ast.nodes.items[owner_node].data.extra;
    if (extra >= ast.extra_data.items.len) return false;
    const name_node: NodeIndex = @enumFromInt(ast.extra_data.items[extra]);
    if (name_node.isNone() or @intFromEnum(name_node) >= ast.nodes.items.len or
        @intFromEnum(name_node) >= symbol_ids.len) return false;
    const name = ast.getNode(name_node);
    if (name.tag != .binding_identifier) return false;
    const symbol_id = symbol_ids[@intFromEnum(name_node)] orelse return false;
    if (symbol_id >= symbols.len) return false;
    const symbol = symbols[symbol_id];
    if (symbol.scope_id != actual_parent or !symbol.kind.isFunctionLike() or
        scopes[actual_parent.toIndex()].kind != .block or
        scopes[actual_parent.toIndex()].parent != expected_parent) return false;
    return scope_maps[actual_parent.toIndex()].get(exactSymbolName(ast, &symbol)) == @as(?usize, symbol_id);
}

fn ownerParentMatchesAst(
    ast: *const Ast,
    symbol_ids: []const ?u32,
    symbols: []const Symbol,
    scopes: []const Scope,
    scope_maps: []const std.StringHashMapUnmanaged(usize),
    scope_owner_map: *const std.AutoHashMapUnmanaged(u32, u32),
    owner_node: u32,
    owner_scope: u32,
    expected_parent_scope: u32,
    pre_transform_scope_count: ?usize,
) bool {
    var parent = scopes[owner_scope].parent;
    var hops: usize = 0;
    while (!parent.isNone() and hops < scopes.len) : (hops += 1) {
        if (!exactValidScope(scopes, parent)) return false;
        const parent_id = parent.toIndex();
        if (parent_id == expected_parent_scope) return true;

        // Lowering can retain analyzer-owned lexical scopes after their AST
        // owners move or disappear. Those source scopes can remain between a
        // generated owner and its nearest emitted AST parent. Permit only
        // source scopes with an owner in the final owner map, and keep walking
        // until the exact emitted parent is reached. Appended transform scopes
        // never act as bridges, so a sibling generated scope remains invalid.
        // Named function expressions are handled separately because their
        // self-name scope is intentionally ownerless.
        if (isFunctionExpressionNameScope(
            ast,
            owner_node,
            parent,
            @enumFromInt(expected_parent_scope),
            symbol_ids,
            symbols,
            scopes,
            scope_maps,
        )) {
            parent = scopes[parent_id].parent;
            continue;
        }
        if (pre_transform_scope_count) |source_scope_count| {
            if (parent_id < source_scope_count and scopeOwnerNode(scope_owner_map, parent_id) != null) {
                parent = scopes[parent_id].parent;
                continue;
            }
        }
        return false;
    }
    return false;
}

fn recordScopeMapMismatch(
    report: *ExactReport,
    issue: []const u8,
    scope_id: ?u32,
    symbol_id: ?u32,
    name: ?[]const u8,
) void {
    report.scope_map_mismatch += 1;
    if (report.first_scope_map_mismatch == null) report.first_scope_map_mismatch = .{
        .issue = issue,
        .scope_id = scope_id,
        .symbol_id = symbol_id,
        .name = name,
    };
}

fn hashDebtPart(hash: *u64, bytes: []const u8) void {
    for (bytes) |byte| {
        hash.* ^= byte;
        hash.* *%= 0x100000001b3;
    }
    hash.* ^= 0xff;
    hash.* *%= 0x100000001b3;
}

fn recordLegacyDebt(report: *ExactReport, issue: []const u8, finding: ExactFinding) void {
    hashDebtPart(&report.legacy_debt_fingerprint, issue);
    hashDebtPart(&report.legacy_debt_fingerprint, finding.name);
    hashDebtPart(&report.legacy_debt_fingerprint, @tagName(finding.tag));
    var index = finding.node_index;
    for (0..4) |_| {
        hashDebtPart(&report.legacy_debt_fingerprint, &.{@truncate(index)});
        index >>= 8;
    }
}

const IndexedReference = struct {
    symbol_id: u32,
    scope_id: ScopeId,
    count: usize = 1,
};

const ExternalReferenceClassification = enum {
    external,
    shadowed,
    unknown_scope,
};

fn exactValidScope(scopes: []const Scope, id: ScopeId) bool {
    return !id.isNone() and id.toIndex() < scopes.len;
}

fn markScopeAndAncestors(
    allocator: std.mem.Allocator,
    marked: *std.AutoHashMapUnmanaged(u32, void),
    scopes: []const Scope,
    start: u32,
) std.mem.Allocator.Error!void {
    var current = start;
    var hops: usize = 0;
    while (hops <= scopes.len) : (hops += 1) {
        if (current >= scopes.len) return;
        try marked.put(allocator, current, {});
        const parent = scopes[current].parent;
        if (parent.isNone()) return;
        current = parent.toIndex();
    }
}

fn spanKey(span: Span) u64 {
    return (@as(u64, span.start) << 32) | span.end;
}

fn exactSymbolName(ast: *const Ast, symbol: *const Symbol) []const u8 {
    if (symbol.synthetic_kind == .enum_iife_parameter) return ast.getText(symbol.name);
    return if (symbol.synthetic_name.len > 0) symbol.synthetic_name else ast.getText(symbol.name);
}

fn collectBindingPatternNodes(
    allocator: std.mem.Allocator,
    ast: *const Ast,
    root: NodeIndex,
    bindings: *std.AutoHashMapUnmanaged(u32, void),
) std.mem.Allocator.Error!void {
    if (root.isNone() or @intFromEnum(root) >= ast.nodes.items.len) return;
    var walker = try ast_walk.bindingIdentifiers(allocator, ast, root, .{ .cover_grammar_assignment = true });
    defer walker.deinit();
    while (try walker.next()) |idx| {
        const tag = ast.getNode(idx).tag;
        if (tag == .binding_identifier or tag == .identifier_reference or tag == .assignment_target_identifier)
            try bindings.put(allocator, @intFromEnum(idx), {});
    }
}

fn collectDeclarationNodes(
    allocator: std.mem.Allocator,
    ast: *const Ast,
    reachable: *const std.AutoHashMapUnmanaged(u32, void),
) std.mem.Allocator.Error!std.AutoHashMapUnmanaged(u32, void) {
    var bindings: std.AutoHashMapUnmanaged(u32, void) = .empty;
    errdefer bindings.deinit(allocator);
    var nodes = reachable.iterator();
    while (nodes.next()) |entry| {
        const raw = entry.key_ptr.*;
        const node = ast.nodes.items[raw];
        switch (node.tag) {
            .function_declaration, .function_expression, .function => {
                if (ast.hasExtra(node.data.extra, 0)) {
                    const name: NodeIndex = @enumFromInt(ast.extra_data.items[node.data.extra]);
                    if (!name.isNone()) try bindings.put(allocator, @intFromEnum(name), {});
                }
                if (ast.hasExtra(node.data.extra, 1)) {
                    const params: NodeIndex = @enumFromInt(ast.extra_data.items[node.data.extra + 1]);
                    try collectBindingPatternNodes(allocator, ast, params, &bindings);
                }
            },
            .arrow_function_expression, .method_definition => {
                const slot: u32 = if (node.tag == .arrow_function_expression) 0 else 1;
                if (ast.hasExtra(node.data.extra, slot)) {
                    const params: NodeIndex = @enumFromInt(ast.extra_data.items[node.data.extra + slot]);
                    try collectBindingPatternNodes(allocator, ast, params, &bindings);
                }
            },
            .class_declaration, .class_expression => {
                if (ast.hasExtra(node.data.extra, 0)) {
                    const name: NodeIndex = @enumFromInt(ast.extra_data.items[node.data.extra]);
                    if (!name.isNone()) try bindings.put(allocator, @intFromEnum(name), {});
                }
            },
            .catch_clause => try collectBindingPatternNodes(allocator, ast, node.data.binary.left, &bindings),
            .variable_declarator => {
                if (ast.hasExtra(node.data.extra, 1)) {
                    const pattern: NodeIndex = @enumFromInt(ast.extra_data.items[node.data.extra]);
                    try collectBindingPatternNodes(allocator, ast, pattern, &bindings);
                }
            },
            .import_declaration => {
                const extra = node.data.extra;
                if (extra + 1 >= ast.extra_data.items.len) continue;
                const specs_start = ast.extra_data.items[extra];
                const specs_len = ast.extra_data.items[extra + 1];
                if (specs_start + specs_len > ast.extra_data.items.len) continue;
                for (ast.extra_data.items[specs_start .. specs_start + specs_len]) |raw_spec| {
                    const spec_idx: NodeIndex = @enumFromInt(raw_spec);
                    if (spec_idx.isNone() or @intFromEnum(spec_idx) >= ast.nodes.items.len) continue;
                    const spec = ast.getNode(spec_idx);
                    switch (spec.tag) {
                        .import_default_specifier, .import_namespace_specifier => try bindings.put(allocator, @intFromEnum(spec_idx), {}),
                        .import_specifier => try collectBindingPatternNodes(allocator, ast, spec.data.binary.right, &bindings),
                        else => {},
                    }
                }
            },
            else => {},
        }
    }
    return bindings;
}

fn exactVisibleFrom(scopes: []const Scope, symbols: []const Symbol, symbol_id: SymbolId, use_scope: ScopeId) bool {
    const sid = @intFromEnum(symbol_id);
    if (sid >= symbols.len or !exactValidScope(scopes, use_scope)) return false;
    const declared_scope = symbols[sid].scope_id;
    if (!exactValidScope(scopes, declared_scope)) return false;
    var current = use_scope;
    var hops: usize = 0;
    while (hops < scopes.len) : (hops += 1) {
        if (current == declared_scope) return true;
        current = scopes[current.toIndex()].parent;
        if (current.isNone() or !exactValidScope(scopes, current)) return false;
    }
    return false;
}

fn resolveInScopes(
    scopes: []const Scope,
    scope_maps: []const std.StringHashMapUnmanaged(usize),
    name: []const u8,
    use_scope: ScopeId,
) ?u32 {
    if (!exactValidScope(scopes, use_scope)) return null;
    const normalized = baseName(name);
    var current = use_scope;
    var hops: usize = 0;
    while (exactValidScope(scopes, current) and hops < scopes.len) : (hops += 1) {
        if (current.toIndex() < scope_maps.len) {
            const map = scope_maps[current.toIndex()];
            if (map.get(name)) |sid| return @intCast(sid);
            if (!std.mem.eql(u8, name, normalized)) {
                if (map.get(normalized)) |sid| return @intCast(sid);
            }
        }
        current = scopes[current.toIndex()].parent;
    }
    return null;
}

fn namespaceMemberForOwner(ctx: *const ExactCtx, owner_id: u32, name: []const u8) ?u32 {
    const owners = ctx.namespace_member_owners orelse return null;
    var entries = owners.iterator();
    while (entries.next()) |entry| {
        if (entry.value_ptr.* != owner_id or entry.key_ptr.* >= ctx.symbols.len) continue;
        const symbol_name = exactSymbolName(ctx.ast, &ctx.symbols[entry.key_ptr.*]);
        if (std.mem.eql(u8, symbol_name, name)) return entry.key_ptr.*;
    }
    return null;
}

fn hasNamespaceMemberNamed(ctx: *const ExactCtx, name: []const u8) bool {
    const owners = ctx.namespace_member_owners orelse return false;
    var entries = owners.keyIterator();
    while (entries.next()) |member_id| {
        if (member_id.* < ctx.symbols.len and
            std.mem.eql(u8, exactSymbolName(ctx.ast, &ctx.symbols[member_id.*]), name)) return true;
    }
    return false;
}

/// Resolve like SemanticAnalyzer.visitIdentifier: a namespace member proxy is
/// considered after lexical bindings in its namespace IIFE scope and before
/// moving to the parent scope. Proxies intentionally do not live in scope_maps.
fn resolveInExactScopes(ctx: *const ExactCtx, name: []const u8, use_scope: ScopeId) ?u32 {
    if (!exactValidScope(ctx.scopes, use_scope)) return null;
    const normalized = baseName(name);
    var current = use_scope;
    var hops: usize = 0;
    while (exactValidScope(ctx.scopes, current) and hops < ctx.scopes.len) : (hops += 1) {
        const scope_index = current.toIndex();
        if (scope_index < ctx.scope_maps.len) {
            const map = ctx.scope_maps[scope_index];
            if (map.get(name)) |sid| return @intCast(sid);
            if (!std.mem.eql(u8, name, normalized)) {
                if (map.get(normalized)) |sid| return @intCast(sid);
            }
        }
        if (ctx.namespace_scope_owners) |namespace_owners| {
            if (namespace_owners.get(scope_index)) |owner_id| {
                if (namespaceMemberForOwner(ctx, owner_id, name)) |sid| return sid;
            }
        }
        current = ctx.scopes[scope_index].parent;
    }
    return null;
}

fn resolveInAnyScope(
    scope_maps: []const std.StringHashMapUnmanaged(usize),
    helper_scope_map: *const std.StringHashMapUnmanaged(usize),
    name: []const u8,
) bool {
    const normalized = baseName(name);
    for (scope_maps) |map| {
        if (map.get(name) != null) return true;
        if (!std.mem.eql(u8, name, normalized) and map.get(normalized) != null) return true;
    }
    return helper_scope_map.get(name) != null or
        (!std.mem.eql(u8, name, normalized) and helper_scope_map.get(normalized) != null);
}

fn exactExecutionUnit(scopes: []const Scope, start: ScopeId) ?u32 {
    var current = start;
    var hops: usize = 0;
    while (!current.isNone() and hops < scopes.len) : (hops += 1) {
        if (!exactValidScope(scopes, current)) return null;
        const scope = scopes[current.toIndex()];
        switch (scope.kind) {
            .global, .module, .function, .class_body => return current.toIndex(),
            .block, .switch_block, .catch_clause => {},
        }
        current = scope.parent;
    }
    return null;
}

fn hasExactExternalEvidence(
    ast: *const Ast,
    node: u32,
    parser_node_count: u32,
    unresolved_nodes: *const std.AutoHashMapUnmanaged(u32, void),
    explicit_global_nodes: *const std.AutoHashMapUnmanaged(u32, void),
    origins: *const std.AutoHashMapUnmanaged(u32, u32),
) bool {
    if (explicit_global_nodes.contains(node)) return true;
    const origin = origins.get(node) orelse node;
    const has_evidence = explicit_global_nodes.contains(origin) or
        (origin < parser_node_count and unresolved_nodes.contains(origin));
    if (!has_evidence) return false;
    if (origin == node) return true;
    if (origin >= ast.nodes.items.len or node >= ast.nodes.items.len) return false;
    const origin_node = ast.nodes.items[origin];
    const generated_node = ast.nodes.items[node];
    if (origin_node.tag != .identifier_reference or generated_node.tag != .identifier_reference) return false;
    return std.mem.eql(u8, ast.getText(origin_node.data.string_ref), ast.getText(generated_node.data.string_ref));
}

fn containsExtraListNode(ast: *const Ast, start: u32, len: u32, child: u32) bool {
    if (start > ast.extra_data.items.len or len > ast.extra_data.items.len - start) return false;
    for (ast.extra_data.items[start .. start + len]) |raw| {
        if (raw == child) return true;
    }
    return false;
}

/// Some scope-owner nodes are entered only after selected child expressions are
/// evaluated. Ignore that owner while walking from those children to their AST
/// ancestors so the expected scope mirrors the analyzer's evaluation order.
fn childSkipsScopeOwner(ast: *const Ast, parent_raw: u32, child_raw: u32) bool {
    if (parent_raw >= ast.nodes.items.len) return false;
    const parent = ast.nodes.items[parent_raw];
    switch (parent.tag) {
        .ts_enum_declaration => {
            const extra = parent.data.extra;
            return extra < ast.extra_data.items.len and ast.extra_data.items[extra] == child_raw;
        },
        .function_declaration => {
            const extra = parent.data.extra;
            return extra < ast.extra_data.items.len and ast.extra_data.items[extra] == child_raw;
        },
        .ts_module_declaration => return @intFromEnum(parent.data.binary.left) == child_raw,
        .switch_statement => {
            const extra = parent.data.extra;
            return extra < ast.extra_data.items.len and ast.extra_data.items[extra] == child_raw;
        },
        .method_definition => {
            const extra = parent.data.extra;
            if (extra + ast_mod.MethodExtra.deco_len >= ast.extra_data.items.len) return false;
            if (ast.extra_data.items[extra + ast_mod.MethodExtra.key] == child_raw) return true;
            return containsExtraListNode(
                ast,
                ast.extra_data.items[extra + ast_mod.MethodExtra.deco_start],
                ast.extra_data.items[extra + ast_mod.MethodExtra.deco_len],
                child_raw,
            );
        },
        .class_declaration => {
            const extra = parent.data.extra;
            if (extra < ast.extra_data.items.len and ast.extra_data.items[extra] == child_raw) return true;
            if (extra + ast_mod.ClassExtra.deco_len >= ast.extra_data.items.len) return false;
            return containsExtraListNode(
                ast,
                ast.extra_data.items[extra + ast_mod.ClassExtra.deco_start],
                ast.extra_data.items[extra + ast_mod.ClassExtra.deco_len],
                child_raw,
            );
        },
        .class_expression => {
            const extra = parent.data.extra;
            if (extra + ast_mod.ClassExtra.deco_len >= ast.extra_data.items.len) return false;
            return containsExtraListNode(
                ast,
                ast.extra_data.items[extra + ast_mod.ClassExtra.deco_start],
                ast.extra_data.items[extra + ast_mod.ClassExtra.deco_len],
                child_raw,
            );
        },
        else => return false,
    }
}

fn functionExpressionNameScope(
    ast: *const Ast,
    scope_owner_map: *const std.AutoHashMapUnmanaged(u32, u32),
    scopes: []const Scope,
    parent_raw: u32,
    child_raw: u32,
) ?u32 {
    if (parent_raw >= ast.nodes.items.len or ast.nodes.items[parent_raw].tag != .function_expression) return null;
    const extra = ast.nodes.items[parent_raw].data.extra;
    if (extra >= ast.extra_data.items.len or ast.extra_data.items[extra] != child_raw) return null;
    const function_scope = scope_owner_map.get(parent_raw) orelse return null;
    if (function_scope >= scopes.len) return null;
    const name_scope = scopes[function_scope].parent;
    if (name_scope.isNone() or name_scope.toIndex() >= scopes.len) return null;
    return name_scope.toIndex();
}

const ExpectedScopeOwner = struct { node: u32, scope: u32 };

fn expectedReferenceScopeFromParent(
    ast: *const Ast,
    root: NodeIndex,
    parent_by_node: *const std.AutoHashMapUnmanaged(u32, u32),
    scope_owner_map: *const std.AutoHashMapUnmanaged(u32, u32),
    node: u32,
    initial_parent: u32,
) ?ExpectedScopeOwner {
    var child = node;
    var parent: ?u32 = initial_parent;
    var hops: usize = 0;
    while (hops <= ast.nodes.items.len) : (hops += 1) {
        const parent_raw = parent orelse return if (scope_owner_map.get(child)) |scope|
            .{ .node = child, .scope = scope }
        else
            null;
        if (!childSkipsScopeOwner(ast, parent_raw, child)) {
            if (scope_owner_map.get(parent_raw)) |scope| return .{ .node = parent_raw, .scope = scope };
        }
        child = parent_raw;
        if (child == @intFromEnum(root)) return if (scope_owner_map.get(child)) |scope|
            .{ .node = child, .scope = scope }
        else
            null;
        parent = parent_by_node.get(child);
    }
    return null;
}

fn expectedReferenceScope(
    ast: *const Ast,
    root: NodeIndex,
    parent_by_node: *const std.AutoHashMapUnmanaged(u32, u32),
    scope_owner_map: *const std.AutoHashMapUnmanaged(u32, u32),
    node: u32,
) ?ExpectedScopeOwner {
    const parent = parent_by_node.get(node) orelse return if (scope_owner_map.get(node)) |scope|
        .{ .node = node, .scope = scope }
    else
        null;
    return expectedReferenceScopeFromParent(ast, root, parent_by_node, scope_owner_map, node, parent);
}

fn topLevelStatementIndex(
    ast: *const Ast,
    root: NodeIndex,
    parent_by_node: *const std.AutoHashMapUnmanaged(u32, u32),
    node: u32,
    initial_parent: ?u32,
) ?u32 {
    if (root.isNone() or @intFromEnum(root) >= ast.nodes.items.len or
        ast.nodes.items[@intFromEnum(root)].tag != .program) return null;
    const root_raw = @intFromEnum(root);
    const child_parent = initial_parent orelse parent_by_node.get(node) orelse return null;
    var child = node;
    var parent = child_parent;
    var hops: usize = 0;
    while (parent != root_raw) : (hops += 1) {
        if (hops > ast.nodes.items.len) return null;
        child = parent;
        parent = parent_by_node.get(child) orelse return null;
    }
    const list = ast.nodes.items[root_raw].data.list;
    const extra = ast.extra_data.items;
    if (list.start > extra.len or list.len > extra.len - list.start) return null;
    for (extra[list.start .. list.start + list.len], 0..) |child_raw, index| {
        if (child_raw == child) return @intCast(index);
    }
    return null;
}

const StatementListPosition = struct {
    owner_node_index: u32,
    statement_index: u32,
};

fn scopeStatementPosition(
    ast: *const Ast,
    root: NodeIndex,
    parent_by_node: *const std.AutoHashMapUnmanaged(u32, u32),
    node: u32,
    initial_parent: ?u32,
) ?StatementListPosition {
    if (root.isNone() or @intFromEnum(root) >= ast.nodes.items.len or node >= ast.nodes.items.len) return null;
    const root_raw = @intFromEnum(root);
    var child = node;
    var parent = initial_parent orelse parent_by_node.get(child) orelse return null;
    var hops: usize = 0;
    while (hops <= ast.nodes.items.len) : (hops += 1) {
        if (parent >= ast.nodes.items.len) return null;
        const parent_node = ast.nodes.items[parent];
        if (parent_node.tag == .program or parent_node.tag == .block_statement) {
            const list = parent_node.data.list;
            const extra = ast.extra_data.items;
            if (list.start > extra.len or list.len > extra.len - list.start) return null;
            for (extra[list.start .. list.start + list.len], 0..) |child_raw, index| {
                if (child_raw == child) return .{
                    .owner_node_index = parent,
                    .statement_index = @intCast(index),
                };
            }
            return null;
        }
        child = parent;
        if (child == root_raw) return null;
        parent = parent_by_node.get(child) orelse return null;
    }
    return null;
}

fn recordReferenceStatementMismatch(
    report: *ExactReport,
    node_index: u32,
    reference_stmt_idx: ?u32,
    expected_stmt_idx: ?u32,
    first_parent: ?u32,
    additional_parent: ?u32,
) void {
    report.reference_statement_mismatch += 1;
    if (report.first_reference_statement_mismatch == null) report.first_reference_statement_mismatch = .{
        .node_index = node_index,
        .reference_stmt_idx = reference_stmt_idx,
        .expected_stmt_idx = expected_stmt_idx,
        .first_parent = first_parent,
        .additional_parent = additional_parent,
    };
}

fn recordReferenceScopeStatementAlias(
    report: *ExactReport,
    node_index: u32,
    parents: anytype,
) void {
    report.reference_scope_statement_alias += 1;
    if (report.first_reference_scope_statement_alias == null) report.first_reference_scope_statement_alias = .{
        .node_index = node_index,
        .first_parent = parents.first_parent,
        .additional_parent = parents.additional_parent,
        .first_owner = parents.first_owner,
        .additional_owner = parents.additional_owner,
        .first_statement_index = parents.first_stmt_idx,
        .additional_statement_index = parents.additional_stmt_idx,
    };
}

fn isExactReferenceNodeTag(tag: Node.Tag) bool {
    return switch (tag) {
        .identifier_reference, .assignment_target_identifier, .jsx_identifier => true,
        else => false,
    };
}

fn isAliasedImportExportNamePair(parent: Node, child: NodeIndex) bool {
    if (parent.tag != .import_specifier and parent.tag != .export_specifier) return false;
    return parent.data.binary.left == child and parent.data.binary.right == child;
}

fn scopeOwnerNode(scope_owner_map: *const std.AutoHashMapUnmanaged(u32, u32), scope: u32) ?u32 {
    var it = scope_owner_map.iterator();
    while (it.next()) |entry| if (entry.value_ptr.* == scope) return entry.key_ptr.*;
    return null;
}

fn scopeOwnerKindMatches(tag: Node.Tag, kind: ScopeKind) bool {
    return switch (tag) {
        .program => kind == .global or kind == .module,
        // Function and catch bodies reuse their owner block node for the
        // enclosing execution scope in the source analyzer.
        .block_statement => kind == .block or kind == .function or kind == .catch_clause,
        // A lowered for-await loop reuses its lexical loop scope on the
        // generated while node (remapCopiedScopeOwner in semantic_edit.zig).
        .for_statement, .for_in_statement, .for_of_statement, .for_await_of_statement, .while_statement => kind == .block,
        .switch_statement => kind == .switch_block,
        .catch_clause => kind == .catch_clause or kind == .block,
        .class_declaration, .class_expression => kind == .class_body,
        .function_declaration, .function_expression, .function, .arrow_function_expression, .method_definition => kind == .function,
        // Namespace and enum lowering attach their generated IIFE scope to
        // the surviving declaration node instead of a generated function node.
        .ts_module_declaration, .ts_enum_declaration, .flow_component_wrapper => kind == .function,
        else => false,
    };
}

fn isNamespaceBodyBlock(
    ast: *const Ast,
    parent_by_node: *const std.AutoHashMapUnmanaged(u32, u32),
    block_raw: u32,
) bool {
    const parent_raw = parent_by_node.get(block_raw) orelse return false;
    if (parent_raw >= ast.nodes.items.len) return false;
    const parent = ast.nodes.items[parent_raw];
    return parent.tag == .ts_module_declaration and @intFromEnum(parent.data.binary.right) == block_raw;
}

fn isFlowComponentImplementationFunction(
    ast: *const Ast,
    parent_by_node: *const std.AutoHashMapUnmanaged(u32, u32),
    function_raw: u32,
) bool {
    const parent_raw = parent_by_node.get(function_raw) orelse return false;
    if (parent_raw >= ast.nodes.items.len) return false;
    const parent = ast.nodes.items[parent_raw];
    if (parent.tag != .flow_component_wrapper or parent.data.extra >= ast.extra_data.items.len) return false;
    return ast.extra_data.items[parent.data.extra] == function_raw;
}

fn exactVisit(ctx: *ExactCtx, idx: NodeIndex, node: Node) ast_walk.WalkAction {
    switch (node.tag) {
        .static_member_expression => {
            ctx.markName(@enumFromInt(ctx.ast.extra_data.items[node.data.extra + 1]));
            return .descend;
        },
        .jsx_attribute => {
            ctx.markName(node.data.binary.left);
            return .descend;
        },
        .jsx_namespaced_name => {
            ctx.markName(node.data.binary.left);
            ctx.markName(node.data.binary.right);
            return .descend;
        },
        .jsx_member_expression => {
            ctx.markJsxMember(idx);
            return .descend;
        },
        .jsx_identifier => {
            const raw = @intFromEnum(idx);
            if (ctx.jsx_variable_roots.contains(raw)) {
                ctx.checkIdentifier(idx);
                return .descend;
            }
            const name = ctx.ast.getText(node.data.string_ref);
            if (name.len > 0 and !std.ascii.isLower(name[0])) ctx.checkIdentifier(idx);
            return .descend;
        },
        .object_property, .binding_property => {
            const key = node.data.binary.left;
            const value = node.data.binary.right;
            if (!value.isNone() and value != key) ctx.markName(key);
            return .descend;
        },
        .assignment_target_property_property => {
            if (node.data.binary.left != node.data.binary.right) ctx.markName(node.data.binary.left);
            return .descend;
        },
        .import_specifier => {
            // The imported side is a label; an unaliased specifier reuses the
            // local node and is classified as a declaration below.
            if (node.data.binary.left != node.data.binary.right) ctx.markName(node.data.binary.left);
            return .descend;
        },
        .method_definition, .property_definition, .accessor_property => {
            ctx.markName(@enumFromInt(ctx.ast.extra_data.items[node.data.extra]));
            return .descend;
        },
        .ts_enum_member, .flow_enum_member => {
            ctx.markName(node.data.binary.left);
            return .descend;
        },
        .export_named_declaration => {
            // Names in a sourced re-export are both module labels, not local
            // references. Source-less exports still resolve the local side.
            const extra = node.data.extra;
            if (extra + 3 < ctx.ast.extra_data.items.len and
                ctx.ast.extra_data.items[extra + 3] != @intFromEnum(NodeIndex.none))
            {
                const start = ctx.ast.extra_data.items[extra + 1];
                const len = ctx.ast.extra_data.items[extra + 2];
                if (start <= ctx.ast.extra_data.items.len and len <= ctx.ast.extra_data.items.len - start) {
                    for (ctx.ast.extra_data.items[start .. start + len]) |raw_spec| {
                        const spec = ctx.ast.getNode(@enumFromInt(raw_spec));
                        if (spec.tag != .export_specifier) continue;
                        ctx.markName(spec.data.binary.left);
                        ctx.markName(spec.data.binary.right);
                    }
                }
            }
            return .descend;
        },
        .export_specifier => {
            // The exported name is a property label. When no alias is written,
            // the parser may reuse the same node for both sides; preserve that
            // node as the local binding reference in that case.
            if (node.data.binary.left != node.data.binary.right) ctx.markName(node.data.binary.right);
            return .descend;
        },
        .labeled_statement => {
            // Labels use identifier nodes in the same namespace as variable
            // references but do not denote SymbolIds.
            ctx.markName(node.data.binary.left);
            return .descend;
        },
        .break_statement, .continue_statement => {
            // Labels occupy the same AST identifier tag as variable reads, but
            // are resolved in the label namespace and never carry a SymbolId.
            ctx.markName(node.data.unary.operand);
            return .descend;
        },
        .identifier_reference, .binding_identifier, .assignment_target_identifier => ctx.checkIdentifier(idx),
        else => {},
    }
    return .descend;
}

const ExactCtx = struct {
    allocator: std.mem.Allocator,
    ast: *const Ast,
    root: NodeIndex,
    parser_node_count: u32,
    parent_by_node: *const std.AutoHashMapUnmanaged(u32, u32),
    scope_owner_map: *const std.AutoHashMapUnmanaged(u32, u32),
    symbol_ids: []const ?u32,
    declaration_nodes: *const std.AutoHashMapUnmanaged(u32, void),
    symbols: []const Symbol,
    scopes: []const Scope,
    scope_maps: []const std.StringHashMapUnmanaged(usize),
    namespace_member_owners: ?*const std.AutoHashMapUnmanaged(u32, u32) = null,
    namespace_scope_owners: ?*const std.AutoHashMapUnmanaged(u32, u32) = null,
    references_by_node: *const std.AutoHashMapUnmanaged(u32, IndexedReference),
    helper_reference_nodes: *const std.AutoHashMapUnmanaged(u32, void),
    helper_scope_map: *const std.StringHashMapUnmanaged(usize),
    dynamic_eval_units: *const std.AutoHashMapUnmanaged(u32, void),
    with_body_roots: *const std.AutoHashMapUnmanaged(u32, void),
    declaration_counts: []const usize,
    unresolved_nodes: *const std.AutoHashMapUnmanaged(u32, void),
    explicit_global_nodes: *const std.AutoHashMapUnmanaged(u32, void),
    origins: *const std.AutoHashMapUnmanaged(u32, u32),
    reachable_nodes: *const std.AutoHashMapUnmanaged(u32, void),
    report: *ExactReport,
    name_positions: std.AutoHashMapUnmanaged(u32, void) = .empty,
    jsx_variable_roots: std.AutoHashMapUnmanaged(u32, void) = .empty,
    oom: bool = false,

    fn isWithinWithBody(ctx: *const ExactCtx, node: u32) bool {
        var current = node;
        var hops: usize = 0;
        while (hops <= ctx.ast.nodes.items.len) : (hops += 1) {
            if (ctx.with_body_roots.contains(current)) return true;
            if (current == @intFromEnum(ctx.root)) return false;
            current = ctx.parent_by_node.get(current) orelse return false;
        }
        return false;
    }

    fn isDirectEvalCallee(ctx: *const ExactCtx, node: u32) bool {
        const parent = ctx.parent_by_node.get(node) orelse return false;
        if (parent >= ctx.ast.nodes.items.len) return false;
        const call = ctx.ast.nodes.items[parent];
        return call.tag == .call_expression and call.data.extra < ctx.ast.extra_data.items.len and
            ctx.ast.extra_data.items[call.data.extra] == node;
    }

    fn hasDynamicNameEnvironment(ctx: *const ExactCtx, node: u32, scope: ?u32) bool {
        if (ctx.isWithinWithBody(node)) return true;
        if (scope) |scope_id| {
            const unit = exactExecutionUnit(ctx.scopes, @enumFromInt(scope_id)) orelse
                return ctx.dynamic_eval_units.count() > 0;
            return ctx.dynamic_eval_units.contains(unit);
        }
        // A broken or absent owner path cannot establish whether an eval shares
        // this reference's execution environment; preserve the uncertainty.
        return ctx.dynamic_eval_units.count() > 0;
    }

    fn markName(ctx: *ExactCtx, idx: NodeIndex) void {
        if (idx.isNone() or ctx.ast.getNode(idx).tag == .computed_property_key) return;
        ctx.name_positions.put(ctx.allocator, @intFromEnum(idx), {}) catch {
            ctx.oom = true;
        };
    }

    fn markJsxMember(ctx: *ExactCtx, idx: NodeIndex) void {
        var current = idx;
        while (!current.isNone()) {
            const member = ctx.ast.getNode(current);
            if (member.tag != .jsx_member_expression) break;
            ctx.markName(member.data.binary.right);
            current = member.data.binary.left;
        }
        if (!current.isNone() and ctx.ast.getNode(current).tag == .jsx_identifier) {
            ctx.jsx_variable_roots.put(ctx.allocator, @intFromEnum(current), {}) catch {
                ctx.oom = true;
            };
        }
    }

    fn classifyExternalReference(ctx: *const ExactCtx, node: u32, name: []const u8) ExternalReferenceClassification {
        const expected = expectedReferenceScope(
            ctx.ast,
            ctx.root,
            ctx.parent_by_node,
            ctx.scope_owner_map,
            node,
        ) orelse {
            // A copied unresolved name remains external only when no lexical
            // or isolated helper binding anywhere could shadow it. Dynamic
            // eval/with scopes make that proof impossible, so keep it visible
            // as unclassified instead of guessing.
            if (ctx.hasDynamicNameEnvironment(node, null) or
                resolveInAnyScope(ctx.scope_maps, ctx.helper_scope_map, name) or
                hasNamespaceMemberNamed(ctx, name)) return .unknown_scope;
            return .external;
        };
        // The `eval` reference that triggers direct eval is resolved before
        // the eval environment exists. Keep an unresolved intrinsic eval
        // external while still treating other references in that execution
        // unit as dynamic.
        if (!ctx.isDirectEvalCallee(node) and ctx.hasDynamicNameEnvironment(node, expected.scope)) return .unknown_scope;
        if (resolveInExactScopes(ctx, name, @enumFromInt(expected.scope))) |symbol_id| {
            if (!ctx.isErasedTypeOnlyImportBinding(name, symbol_id)) return .shadowed;
        }
        if (ctx.helper_scope_map.get(name) != null) return .shadowed;
        return .external;
    }

    /// TypeScript metadata intentionally emits a guarded reference for an
    /// `import type`, even though the import binding itself is erased. Such a
    /// reference is external in the output lexical environment, so the stale
    /// source scope-map entry must not make it look shadowed.
    fn isErasedTypeOnlyImportBinding(ctx: *const ExactCtx, name: []const u8, symbol_id: u32) bool {
        if (symbol_id >= ctx.symbols.len or ctx.symbols[symbol_id].kind != .import_binding or
            hasReachableBindingForSymbol(ctx, symbol_id)) return false;

        for (ctx.ast.nodes.items) |node| {
            if (node.tag != .import_declaration) continue;
            const import_start = node.data.extra;
            if (import_start > ctx.ast.extra_data.items.len or
                ctx.ast.extra_data.items.len - import_start < 6) continue;
            const import = module_parser.readImportDeclExtras(ctx.ast, import_start);
            if (import.specs_start > ctx.ast.extra_data.items.len or
                import.specs_len > ctx.ast.extra_data.items.len - import.specs_start) continue;
            var i: u32 = 0;
            while (i < import.specs_len) : (i += 1) {
                const spec_idx: NodeIndex = @enumFromInt(ctx.ast.extra_data.items[import.specs_start + i]);
                if (spec_idx.isNone() or @intFromEnum(spec_idx) >= ctx.ast.nodes.items.len) continue;
                const spec = ctx.ast.getNode(spec_idx);
                const local_idx = switch (spec.tag) {
                    .import_default_specifier, .import_namespace_specifier => spec_idx,
                    .import_specifier => spec.data.binary.right,
                    else => continue,
                };
                if (local_idx.isNone() or @intFromEnum(local_idx) >= ctx.ast.nodes.items.len or
                    @intFromEnum(local_idx) >= ctx.symbol_ids.len or
                    ctx.symbol_ids[@intFromEnum(local_idx)] != symbol_id) continue;
                const local_name = ctx.ast.getText(ctx.ast.getNode(local_idx).span);
                if (!std.mem.eql(u8, local_name, name)) continue;
                const inline_type_only = spec.tag == .import_specifier and
                    (spec.data.binary.flags & module_parser.SPEC_FLAG_TYPE_ONLY) != 0;
                if (import.is_type_only or inline_type_only) return true;
            }
        }
        return false;
    }

    fn isEnumObjectBase(ctx: *const ExactCtx, node_raw: u32) bool {
        var child = node_raw;
        var hops: usize = 0;
        while (ctx.parent_by_node.get(child)) |parent_raw| : (hops += 1) {
            if (hops >= ctx.ast.nodes.items.len or parent_raw >= ctx.ast.nodes.items.len) return false;
            const parent = ctx.ast.nodes.items[parent_raw];
            if (ast_mod.Node.Tag.isTransparentTypeWrapper(parent.tag) and
                parent.data.unary.operand == @as(NodeIndex, @enumFromInt(child)))
            {
                child = parent_raw;
                continue;
            }
            if (parent.tag == .static_member_expression) {
                return ctx.ast.readExtraNode(parent.data.extra, 0) == @as(NodeIndex, @enumFromInt(child));
            }
            return false;
        }
        return false;
    }

    fn isEnumMemberReference(ctx: *ExactCtx, node_raw: u32, name: []const u8, symbol_id: u32, use_scope: ScopeId) bool {
        if (symbol_id >= ctx.symbols.len) return false;
        const symbol = ctx.symbols[symbol_id];
        if (symbol.synthetic_kind != .enum_iife_member or !std.mem.eql(u8, symbol.synthetic_name, name)) return false;
        const owner_id = symbol.synthetic_owner_id orelse return false;
        const parameter_raw = @intFromEnum(owner_id);
        if (parameter_raw >= ctx.symbols.len or ctx.symbols[parameter_raw].synthetic_kind != .enum_iife_parameter or
            ctx.symbols[parameter_raw].scope_id != symbol.scope_id) return false;
        if (isEnumObjectBase(ctx, node_raw)) return false;
        if (!exactVisibleFrom(ctx.scopes, ctx.symbols, @enumFromInt(symbol_id), use_scope)) return false;

        var enum_raw: ?u32 = null;
        var current_member: ?u32 = null;
        var current = node_raw;
        var hops: usize = 0;
        while (ctx.parent_by_node.get(current)) |parent| : (hops += 1) {
            if (hops >= ctx.ast.nodes.items.len or parent >= ctx.ast.nodes.items.len) return false;
            const ancestor = ctx.ast.nodes.items[parent];
            if (ancestor.tag == .ts_enum_member and current_member == null) current_member = parent;
            if (ancestor.tag == .ts_enum_declaration) {
                enum_raw = parent;
                break;
            }
            current = parent;
        }
        const owner_raw = enum_raw orelse return false;
        const member_raw = current_member orelse return false;
        if (ctx.scope_owner_map.get(owner_raw) != @as(?u32, @intCast(@intFromEnum(symbol.scope_id)))) return false;

        const declaration = ctx.ast.nodes.items[owner_raw];
        const extra = declaration.data.extra;
        if (extra + 2 >= ctx.ast.extra_data.items.len) return false;
        const members_start = ctx.ast.extra_data.items[extra + 1];
        const members_len = ctx.ast.extra_data.items[extra + 2];
        if (members_start > ctx.ast.extra_data.items.len or members_len > ctx.ast.extra_data.items.len - members_start) return false;

        var current_position: ?u32 = null;
        var target_position: ?u32 = null;
        for (ctx.ast.extra_data.items[members_start .. members_start + members_len], 0..) |raw_member, position| {
            const listed_member: NodeIndex = @enumFromInt(raw_member);
            if (raw_member == member_raw) current_position = @intCast(position);
            if (listed_member.isNone() or @intFromEnum(listed_member) >= ctx.ast.nodes.items.len) continue;
            const member_node = ctx.ast.getNode(listed_member);
            if (member_node.tag != .ts_enum_member or member_node.data.binary.left.isNone()) continue;
            const key = ctx.ast.getNode(member_node.data.binary.left);
            if (key.span.start != symbol.name.start or key.span.end != symbol.name.end) continue;
            const matches_name = switch (key.tag) {
                .identifier_reference, .binding_identifier => std.mem.eql(u8, ctx.ast.identifierNameText(key), name),
                .string_literal => blk: {
                    const stripped = Ast.stripStringQuotes(ctx.ast.getText(key.span));
                    if (std.mem.indexOfScalar(u8, stripped, '\\') == null) break :blk std.mem.eql(u8, stripped, name);
                    const decoded = (ctx.ast.staticKeyName(ctx.allocator, member_node.data.binary.left) catch {
                        ctx.oom = true;
                        return false;
                    }) orelse break :blk false;
                    defer ctx.allocator.free(decoded);
                    break :blk std.mem.eql(u8, decoded, name);
                },
                else => false,
            };
            if (matches_name) target_position = @intCast(position);
        }
        const use_position = current_position orelse return false;
        const declaration_position = target_position orelse return false;
        if (declaration_position >= use_position) return false;

        // Initializer-local bindings win over a virtual member. The generated
        // enum-object parameter shares the source enum name, so permit that one
        // binding in the owner scope; object-base references were rejected above.
        var scope = use_scope;
        var scope_hops: usize = 0;
        while (scope_hops <= ctx.scopes.len) : (scope_hops += 1) {
            if (!exactValidScope(ctx.scopes, scope)) return false;
            if (scope.toIndex() < ctx.scope_maps.len) {
                if (ctx.scope_maps[scope.toIndex()].get(name)) |mapped| {
                    const is_owner_enum_parameter = scope == symbol.scope_id and mapped < ctx.symbols.len and
                        ctx.symbols[mapped].synthetic_kind == .enum_iife_parameter;
                    if (!is_owner_enum_parameter) return false;
                }
            }
            if (scope == symbol.scope_id) return true;
            scope = ctx.scopes[scope.toIndex()].parent;
        }
        return false;
    }

    fn checkIdentifier(ctx: *ExactCtx, idx: NodeIndex) void {
        const raw = @intFromEnum(idx);
        if (ctx.name_positions.contains(raw)) return;
        const node = ctx.ast.getNode(idx);
        if (!ctx.reachable_nodes.contains(raw)) std.debug.print(
            "zntc: symbol-identity-traversal-mismatch node={d} name={s} root={d}\n",
            .{ raw, ctx.ast.getText(node.data.string_ref), @intFromEnum(ctx.root) },
        );
        const name = ctx.ast.getText(node.data.string_ref);
        const generated = raw >= ctx.parser_node_count;
        const finding: ExactFinding = .{
            .name = name,
            .tag = node.tag,
            .node_index = raw,
            .span_start = node.span.start,
        };
        const is_binding = node.tag == .binding_identifier or
            ctx.declaration_nodes.contains(raw);
        if (generated) {
            if (is_binding) {
                ctx.report.generated_bindings += 1;
            } else {
                ctx.report.generated_references += 1;
            }
        }
        const maybe_id = if (raw < ctx.symbol_ids.len) ctx.symbol_ids[raw] else null;
        if (maybe_id == null) {
            if (is_binding) {
                ctx.report.missing_binding += 1;
                if (generated) {
                    recordLegacyDebt(ctx.report, "missing_binding", finding);
                    std.debug.print("zntc: symbol-debt-node kind=missing_binding node={d} name={s} tag={s} span={d}\n", .{ raw, name, @tagName(node.tag), node.span.start });
                }
                if (ctx.report.first_missing_binding == null) ctx.report.first_missing_binding = finding;
            } else {
                const external_evidence = hasExactExternalEvidence(
                    ctx.ast,
                    raw,
                    ctx.parser_node_count,
                    ctx.unresolved_nodes,
                    ctx.explicit_global_nodes,
                    ctx.origins,
                );
                const external_classification = if (external_evidence)
                    ctx.classifyExternalReference(raw, name)
                else
                    .unknown_scope;
                switch (external_classification) {
                    .external => ctx.report.external_references += 1,
                    .shadowed => {
                        ctx.report.shadowed_external_reference += 1;
                        if (ctx.report.first_shadowed_external_reference == null)
                            ctx.report.first_shadowed_external_reference = finding;
                        std.debug.print(
                            "zntc: symbol-shadowed-external node={d} name={s}\n",
                            .{ raw, name },
                        );
                    },
                    .unknown_scope => {
                        ctx.report.unclassified_reference += 1;
                        if (generated) {
                            recordLegacyDebt(ctx.report, "unclassified_reference", finding);
                            std.debug.print("zntc: symbol-debt-node kind=unclassified_reference node={d} name={s} tag={s} span={d}\n", .{ raw, name, @tagName(node.tag), node.span.start });
                        }
                        if (ctx.report.first_unclassified_reference == null) ctx.report.first_unclassified_reference = finding;
                    },
                }
            }
            return;
        }
        const raw_id = maybe_id.?;
        if (raw_id >= ctx.symbols.len) {
            ctx.report.invalid_id += 1;
            return;
        }
        const id: SymbolId = @enumFromInt(raw_id);
        const symbol = ctx.symbols[raw_id];
        if (!exactValidScope(ctx.scopes, symbol.scope_id)) {
            ctx.report.invalid_scope += 1;
        }
        if (is_binding) {
            const symbol_name = exactSymbolName(ctx.ast, &symbol);
            if (!std.mem.eql(u8, baseName(name), baseName(symbol_name))) ctx.report.identity_mismatch += 1;
            if (node.tag == .binding_identifier) {
                const expected_scope = expectedBindingScope(ctx, raw, symbol.kind);
                if (expected_scope) |expected| {
                    const lexical_scope = expectedReferenceScope(
                        ctx.ast,
                        ctx.root,
                        ctx.parent_by_node,
                        ctx.scope_owner_map,
                        raw,
                    );
                    const resolved = resolveInScopes(ctx.scopes, ctx.scope_maps, symbol_name, @enumFromInt(expected));
                    const relocated = symbol.synthetic_name.len > 0 or symbol.kind == .variable_var or
                        outputBindingIsVar(ctx, raw);
                    const owner_binding = if (expected < ctx.scope_maps.len)
                        ctx.scope_maps[expected].get(symbol_name)
                    else
                        null;
                    const lexical_binding = if (lexical_scope) |lexical|
                        if (lexical.scope < ctx.scope_maps.len) ctx.scope_maps[lexical.scope].get(symbol_name) else null
                    else
                        null;
                    const lexical_binding_matches = lexical_binding != null and lexical_binding.? == raw_id;
                    const shadowed_lexical_owner = lexical_binding != null and lexical_binding.? != raw_id;
                    const shadowed_storage_owner = owner_binding != null and owner_binding.? != raw_id and
                        !lexical_binding_matches;
                    const symbol_keeps_lexical_scope = if (lexical_scope) |lexical|
                        symbol.scope_id.toIndex() == lexical.scope
                    else
                        false;
                    const retained_source_scope = !hasReachableScopeOwner(ctx, @intFromEnum(symbol.scope_id)) and
                        (resolved == null or resolved.? == raw_id);
                    if (shadowed_lexical_owner or shadowed_storage_owner or
                        (symbol.scope_id.toIndex() != expected and
                            (!relocated and !symbol_keeps_lexical_scope) and
                            !retained_source_scope and !isRetainedCatchBinding(ctx, raw, raw_id, symbol.scope_id)))
                    {
                        ctx.report.binding_scope_mismatch += 1;
                    }
                } else {
                    ctx.report.binding_scope_unknown += 1;
                }
            }
            if (symbol.scope_id.toIndex() < ctx.scope_maps.len) {
                const mapped = ctx.scope_maps[symbol.scope_id.toIndex()].get(symbol_name);
                const isolated_helper_binding = symbol.kind == .import_binding and
                    ctx.helper_scope_map.get(symbol_name) == raw_id and
                    if (mapped) |mapped_id|
                        mapped_id != raw_id and mapped_id < ctx.symbols.len and
                            ctx.symbols[mapped_id].scope_id == symbol.scope_id and
                            std.mem.eql(u8, exactSymbolName(ctx.ast, &ctx.symbols[mapped_id]), symbol_name)
                    else
                        false;
                if ((mapped == null or mapped.? != raw_id) and !isolated_helper_binding) recordScopeMapMismatch(
                    ctx.report,
                    "binding-not-in-scope-map",
                    @intFromEnum(symbol.scope_id),
                    raw_id,
                    symbol_name,
                );
            } else {
                recordScopeMapMismatch(ctx.report, "binding-scope-map-out-of-range", @intFromEnum(symbol.scope_id), raw_id, symbol_name);
            }
            if (symbol.synthetic_name.len > 0 and
                (raw_id >= ctx.declaration_counts.len or ctx.declaration_counts[raw_id] == 0))
            {
                ctx.report.missing_reference += 1;
                recordLegacyDebt(ctx.report, "missing_reference", finding);
                std.debug.print("zntc: symbol-debt-node kind=missing_reference node={d} name={s} tag={s} span={d}\n", .{ raw, name, @tagName(node.tag), node.span.start });
                if (ctx.report.first_missing_reference == null) ctx.report.first_missing_reference = finding;
            }
            return;
        }

        const indexed = ctx.references_by_node.get(raw) orelse {
            ctx.report.missing_reference += 1;
            if (generated) recordLegacyDebt(ctx.report, "missing_reference", finding);
            const origin = ctx.origins.get(raw) orelse std.math.maxInt(u32);
            if (origin < ctx.ast.nodes.items.len and ctx.ast.nodes.items[origin].tag == .identifier_reference) {
                const origin_node = ctx.ast.getNode(@enumFromInt(origin));
                std.debug.print("zntc: symbol-debt-node kind=missing_reference node={d} name={s} tag={s} span={d} id={d} origin={d}:{s}@{d}\n", .{ raw, name, @tagName(node.tag), node.span.start, raw_id, origin, ctx.ast.getText(origin_node.data.string_ref), origin_node.span.start });
            } else {
                std.debug.print("zntc: symbol-debt-node kind=missing_reference node={d} name={s} tag={s} span={d} id={d} origin={d}\n", .{ raw, name, @tagName(node.tag), node.span.start, raw_id, origin });
            }
            if (ctx.report.first_missing_reference == null) ctx.report.first_missing_reference = finding;
            return;
        };
        if (indexed.count != 1) ctx.report.duplicate_reference += indexed.count - 1;
        if (indexed.symbol_id != raw_id) ctx.report.identity_mismatch += 1;
        if (!exactValidScope(ctx.scopes, indexed.scope_id)) {
            ctx.report.invalid_scope += 1;
        } else if (!exactVisibleFrom(ctx.scopes, ctx.symbols, id, indexed.scope_id)) {
            ctx.report.invisible_reference += 1;
        }
        if (expectedReferenceScope(ctx.ast, ctx.root, ctx.parent_by_node, ctx.scope_owner_map, raw)) |expected_scope| {
            if (@intFromEnum(indexed.scope_id) != expected_scope.scope) {
                const retained_source_scope = !ctx.helper_reference_nodes.contains(raw) and
                    isRetainedSourceScopeReference(ctx, raw, id, indexed.scope_id);
                if (!retained_source_scope) {
                    ctx.report.reference_scope_mismatch += 1;
                    const actual_owner = scopeOwnerNode(ctx.scope_owner_map, @intFromEnum(indexed.scope_id));
                    const actual_owner_tag = if (actual_owner) |owner|
                        if (owner < ctx.ast.nodes.items.len) @tagName(ctx.ast.nodes.items[owner].tag) else "out-of-range"
                    else
                        "none";
                    const indexed_id = indexed.symbol_id;
                    const indexed_symbol_scope = if (indexed_id < ctx.symbols.len)
                        @intFromEnum(ctx.symbols[indexed_id].scope_id)
                    else
                        std.math.maxInt(u32);
                    const indexed_symbol_kind = if (indexed_id < ctx.symbols.len)
                        @tagName(ctx.symbols[indexed_id].kind)
                    else
                        "out-of-range";
                    std.debug.print(
                        "zntc: symbol-reference-scope node={d}:{s} name={s} symbol={d}@{d}:{s} actual={d} owner={s}@{d} expected={d} owner={s}@{d}\n",
                        .{
                            raw,
                            @tagName(node.tag),
                            name,
                            indexed_id,
                            indexed_symbol_scope,
                            indexed_symbol_kind,
                            @intFromEnum(indexed.scope_id),
                            actual_owner_tag,
                            actual_owner orelse std.math.maxInt(u32),
                            expected_scope.scope,
                            @tagName(ctx.ast.nodes.items[expected_scope.node].tag),
                            expected_scope.node,
                        },
                    );
                }
            }
        }
        const expected: ?u32 = if (ctx.helper_reference_nodes.contains(raw)) blk: {
            if (ctx.helper_scope_map.get(name)) |sid| break :blk @intCast(sid);
            break :blk null;
        } else if (isEnumMemberReference(ctx, raw, name, raw_id, indexed.scope_id)) raw_id else resolveInExactScopes(ctx, name, indexed.scope_id);
        if (expected) |expected_id| {
            if (expected_id != raw_id) {
                ctx.report.scope_resolution_mismatch += 1;
                const expected_scope = if (expected_id < ctx.symbols.len) @intFromEnum(ctx.symbols[expected_id].scope_id) else std.math.maxInt(u32);
                const actual_scope = @intFromEnum(ctx.symbols[raw_id].scope_id);
                const expected_kind = if (expected_id < ctx.symbols.len) @tagName(ctx.symbols[expected_id].kind) else "invalid";
                std.debug.print(
                    "zntc: symbol-identity-resolution node={d} name={s} actual={d}@{d}:{s} expected={d}@{d}:{s} ref_scope={d}\n",
                    .{ raw, name, raw_id, actual_scope, @tagName(ctx.symbols[raw_id].kind), expected_id, expected_scope, expected_kind, @intFromEnum(indexed.scope_id) },
                );
                for (ctx.symbol_ids, 0..) |binding_id, binding_node| {
                    if (binding_id == null or (binding_id.? != raw_id and binding_id.? != expected_id)) continue;
                    if (binding_node >= ctx.ast.nodes.items.len or ctx.ast.nodes.items[binding_node].tag != .binding_identifier) continue;
                    const binding = ctx.ast.getNode(@enumFromInt(@as(u32, @intCast(binding_node))));
                    const binding_name = ctx.ast.getText(binding.data.string_ref);
                    std.debug.print(
                        "  identity-binding id={d} node={d} name={s} span={d} tag={s}\n",
                        .{ binding_id.?, binding_node, binding_name, binding.span.start, @tagName(ctx.ast.nodes.items[binding_node].tag) },
                    );
                }
            }
        } else {
            ctx.report.scope_resolution_mismatch += 1;
        }
        if (ctx.origins.get(raw)) |origin| {
            if (origin < ctx.parser_node_count and origin < ctx.symbol_ids.len) {
                if (ctx.symbol_ids[origin]) |origin_id| {
                    if (origin_id != raw_id) ctx.report.identity_mismatch += 1;
                }
            }
        }
    }
};

fn outputBindingIsVar(ctx: *const ExactCtx, node: u32) bool {
    var child = node;
    var parent = ctx.parent_by_node.get(child);
    var hops: usize = 0;
    while (parent) |raw| : (hops += 1) {
        if (hops >= ctx.ast.nodes.items.len or raw >= ctx.ast.nodes.items.len) return false;
        const ancestor = ctx.ast.nodes.items[raw];
        if (ancestor.tag == .variable_declaration)
            return ctx.ast.variableDeclarationKind(ancestor) == .@"var";
        switch (ancestor.tag) {
            .function_declaration,
            .function_expression,
            .function,
            .arrow_function_expression,
            .class_declaration,
            .class_expression,
            .catch_clause,
            => return false,
            else => {},
        }
        child = raw;
        parent = ctx.parent_by_node.get(child);
    }
    return false;
}

fn expectedBindingScope(ctx: *const ExactCtx, node: u32, kind: @import("../semantic/symbol.zig").SymbolKind) ?u32 {
    if (node >= ctx.ast.nodes.items.len) return null;
    const binding_name = ctx.ast.nodes.items[node];
    if (binding_name.tag != .binding_identifier) return null;
    // A named function expression's self-binding lives in the synthetic block
    // scope immediately surrounding its function scope.
    var child = node;
    var parent = ctx.parent_by_node.get(child);
    var hops: usize = 0;
    while (parent) |raw| : (hops += 1) {
        if (hops >= ctx.ast.nodes.items.len or raw >= ctx.ast.nodes.items.len) return null;
        const ancestor = ctx.ast.nodes.items[raw];
        if (ancestor.tag == .function_expression and ancestor.data.extra < ctx.ast.extra_data.items.len and
            ctx.ast.extra_data.items[ancestor.data.extra] == child)
        {
            const function_scope = ctx.scope_owner_map.get(raw) orelse return null;
            if (function_scope >= ctx.scopes.len) return null;
            const name_scope = ctx.scopes[function_scope].parent;
            return if (exactValidScope(ctx.scopes, name_scope)) name_scope.toIndex() else null;
        }
        child = raw;
        parent = ctx.parent_by_node.get(child);
    }

    const lexical = expectedReferenceScope(
        ctx.ast,
        ctx.root,
        ctx.parent_by_node,
        ctx.scope_owner_map,
        node,
    ) orelse return null;
    if (kind == .variable_var or outputBindingIsVar(ctx, node))
        return nearestVarScope(lexical.scope, ctx.scopes);
    return lexical.scope;
}

fn isRetainedCatchBinding(ctx: *const ExactCtx, node: u32, symbol_id: u32, scope: ScopeId) bool {
    if (symbol_id >= ctx.symbols.len or ctx.symbols[symbol_id].kind != .catch_binding) return false;
    return !hasReachableScopeOwner(ctx, @intFromEnum(scope)) and
        hasReachableBindingForSymbol(ctx, symbol_id) and
        node < ctx.symbol_ids.len and ctx.symbol_ids[node] == symbol_id;
}

/// Validate exact generated-node identities against the post-edit semantic graph.
/// Name equality is used only as an additional corruption check; it never binds a node.
pub fn checkExact(
    allocator: std.mem.Allocator,
    ast: *const Ast,
    root: NodeIndex,
    parser_node_count: u32,
    symbol_ids: []const ?u32,
    symbols: []const Symbol,
    scopes: []const Scope,
    scope_maps: []const std.StringHashMapUnmanaged(usize),
    scope_owner_map: *const std.AutoHashMapUnmanaged(u32, u32),
    references: []const Reference,
    helper_reference_nodes: []const u32,
    helper_scope_map: *const std.StringHashMapUnmanaged(usize),
    unresolved_nodes: *const std.AutoHashMapUnmanaged(u32, void),
    explicit_global_nodes: *const std.AutoHashMapUnmanaged(u32, void),
    origins: *const std.AutoHashMapUnmanaged(u32, u32),
) std.mem.Allocator.Error!ExactReport {
    return checkExactImpl(
        allocator,
        ast,
        root,
        parser_node_count,
        symbol_ids,
        symbols,
        scopes,
        scope_maps,
        scope_owner_map,
        references,
        helper_reference_nodes,
        helper_scope_map,
        unresolved_nodes,
        explicit_global_nodes,
        origins,
        null,
        null,
        null,
    );
}

/// Exact audit for a graph edited in-place by the transformer. Scopes below
/// `pre_transform_scope_count` came from source analysis and may remain after
/// their source AST owner is lowered away; every appended transform scope must
/// still have a reachable owner in the emitted AST.
pub fn checkExactWithScopeBoundary(
    allocator: std.mem.Allocator,
    ast: *const Ast,
    root: NodeIndex,
    parser_node_count: u32,
    symbol_ids: []const ?u32,
    symbols: []const Symbol,
    scopes: []const Scope,
    scope_maps: []const std.StringHashMapUnmanaged(usize),
    scope_owner_map: *const std.AutoHashMapUnmanaged(u32, u32),
    references: []const Reference,
    helper_reference_nodes: []const u32,
    helper_scope_map: *const std.StringHashMapUnmanaged(usize),
    unresolved_nodes: *const std.AutoHashMapUnmanaged(u32, void),
    explicit_global_nodes: *const std.AutoHashMapUnmanaged(u32, void),
    origins: *const std.AutoHashMapUnmanaged(u32, u32),
    pre_transform_scope_count: usize,
) std.mem.Allocator.Error!ExactReport {
    return checkExactImpl(
        allocator,
        ast,
        root,
        parser_node_count,
        symbol_ids,
        symbols,
        scopes,
        scope_maps,
        scope_owner_map,
        references,
        helper_reference_nodes,
        helper_scope_map,
        unresolved_nodes,
        explicit_global_nodes,
        origins,
        null,
        null,
        pre_transform_scope_count,
    );
}

/// `pre_transform_scope_count` is valid only when the caller retained the
/// source ScopeId space; a full reanalysis builds a new scope index space.
pub fn checkExactWithNamespaceMetadata(
    allocator: std.mem.Allocator,
    ast: *const Ast,
    root: NodeIndex,
    parser_node_count: u32,
    symbol_ids: []const ?u32,
    symbols: []const Symbol,
    scopes: []const Scope,
    scope_maps: []const std.StringHashMapUnmanaged(usize),
    scope_owner_map: *const std.AutoHashMapUnmanaged(u32, u32),
    references: []const Reference,
    helper_reference_nodes: []const u32,
    helper_scope_map: *const std.StringHashMapUnmanaged(usize),
    unresolved_nodes: *const std.AutoHashMapUnmanaged(u32, void),
    explicit_global_nodes: *const std.AutoHashMapUnmanaged(u32, void),
    origins: *const std.AutoHashMapUnmanaged(u32, u32),
    namespace_member_owners: *const std.AutoHashMapUnmanaged(u32, u32),
    namespace_declaration_owners: *const std.AutoHashMapUnmanaged(u32, u32),
    pre_transform_scope_count: ?usize,
) std.mem.Allocator.Error!ExactReport {
    return checkExactImpl(
        allocator,
        ast,
        root,
        parser_node_count,
        symbol_ids,
        symbols,
        scopes,
        scope_maps,
        scope_owner_map,
        references,
        helper_reference_nodes,
        helper_scope_map,
        unresolved_nodes,
        explicit_global_nodes,
        origins,
        namespace_member_owners,
        namespace_declaration_owners,
        pre_transform_scope_count,
    );
}

fn checkExactImpl(
    allocator: std.mem.Allocator,
    ast: *const Ast,
    root: NodeIndex,
    parser_node_count: u32,
    symbol_ids: []const ?u32,
    symbols: []const Symbol,
    scopes: []const Scope,
    scope_maps: []const std.StringHashMapUnmanaged(usize),
    scope_owner_map: *const std.AutoHashMapUnmanaged(u32, u32),
    references: []const Reference,
    helper_reference_nodes: []const u32,
    helper_scope_map: *const std.StringHashMapUnmanaged(usize),
    unresolved_nodes: *const std.AutoHashMapUnmanaged(u32, void),
    explicit_global_nodes: *const std.AutoHashMapUnmanaged(u32, void),
    origins: *const std.AutoHashMapUnmanaged(u32, u32),
    namespace_member_owners: ?*const std.AutoHashMapUnmanaged(u32, u32),
    namespace_declaration_owners: ?*const std.AutoHashMapUnmanaged(u32, u32),
    pre_transform_scope_count: ?usize,
) std.mem.Allocator.Error!ExactReport {
    const VisitState = enum { visiting, visited };
    const VisitFrame = struct {
        node_index: NodeIndex,
        exit: bool = false,
    };
    const AliasedStatementParents = struct {
        first_parent: u32,
        additional_parent: u32,
        first_stmt_idx: u32,
        additional_stmt_idx: u32,
    };
    const AliasedScopeStatementParents = struct {
        first_parent: u32,
        additional_parent: u32,
        first_owner: u32,
        additional_owner: u32,
        first_stmt_idx: u32,
        additional_stmt_idx: u32,
    };
    const ReferenceNodeUseEdges = struct {
        first_parent: u32,
        additional_parent: u32,
        count: usize = 1,
    };

    var report: ExactReport = .{};
    var reachable_nodes: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer reachable_nodes.deinit(allocator);
    var parent_by_node: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer parent_by_node.deinit(allocator);
    var aliased_statement_parents: std.AutoHashMapUnmanaged(u32, AliasedStatementParents) = .empty;
    defer aliased_statement_parents.deinit(allocator);
    var aliased_scope_statement_parents: std.AutoHashMapUnmanaged(u32, AliasedScopeStatementParents) = .empty;
    defer aliased_scope_statement_parents.deinit(allocator);
    var reference_node_use_edges: std.AutoHashMapUnmanaged(u32, ReferenceNodeUseEdges) = .empty;
    defer reference_node_use_edges.deinit(allocator);
    var aliased_specifier_edges: std.AutoHashMapUnmanaged(u64, void) = .empty;
    defer aliased_specifier_edges.deinit(allocator);
    var visit_states: std.AutoHashMapUnmanaged(u32, VisitState) = .empty;
    defer visit_states.deinit(allocator);
    var reachable_stack: std.ArrayList(VisitFrame) = .empty;
    defer reachable_stack.deinit(allocator);
    var reachable_node_order: std.ArrayList(u32) = .empty;
    defer reachable_node_order.deinit(allocator);
    if (root.isNone() or @intFromEnum(root) >= ast.nodes.items.len) {
        report.invalid_ast_root += 1;
        report.first_invalid_ast_root = @intFromEnum(root);
        return report;
    }
    try reachable_stack.append(allocator, .{ .node_index = root });
    while (reachable_stack.pop()) |frame| {
        const node_idx = frame.node_index;
        if (node_idx.isNone() or @intFromEnum(node_idx) >= ast.nodes.items.len) continue;
        const raw = @intFromEnum(node_idx);
        if (frame.exit) {
            try visit_states.put(allocator, raw, .visited);
            continue;
        }
        if (visit_states.get(raw)) |state| {
            if (state == .visiting) report.cyclic_ast_edges += 1;
            continue;
        }
        try visit_states.put(allocator, raw, .visiting);
        try reachable_nodes.put(allocator, raw, {});
        try reachable_node_order.append(allocator, raw);
        try reachable_stack.append(allocator, .{ .node_index = node_idx, .exit = true });
        if (invalidExactAstLayout(ast, raw)) |finding| {
            report.invalid_ast_layout += 1;
            if (report.first_invalid_ast_layout == null) report.first_invalid_ast_layout = finding;
            continue;
        }
        var children = ast_walk.children(ast, ast.getNode(node_idx));
        while (children.next()) |child| {
            if (child.isNone()) continue;
            const child_raw = @intFromEnum(child);
            if (child_raw >= ast.nodes.items.len) {
                report.invalid_ast_edge += 1;
                if (report.first_invalid_ast_edge == null) report.first_invalid_ast_edge = .{
                    .parent_node_index = raw,
                    .parent_tag = ast.nodes.items[raw].tag,
                    .child_node_index = child_raw,
                };
                continue;
            }
            if (isExactReferenceNodeTag(ast.nodes.items[child_raw].tag)) {
                const parent_node = ast.nodes.items[raw];
                var count_as_use_edge = true;
                if (isAliasedImportExportNamePair(parent_node, child)) {
                    // Shorthand import/export specifiers can intentionally use
                    // one AST node for both the local identifier and the
                    // external name. Count that pair as one lexical use.
                    const pair_key = (@as(u64, raw) << 32) | child_raw;
                    const pair_gop = try aliased_specifier_edges.getOrPut(allocator, pair_key);
                    count_as_use_edge = !pair_gop.found_existing;
                }
                if (count_as_use_edge) {
                    const use_gop = try reference_node_use_edges.getOrPut(allocator, child_raw);
                    if (use_gop.found_existing) {
                        use_gop.value_ptr.count += 1;
                        if (use_gop.value_ptr.count == 2) use_gop.value_ptr.additional_parent = raw;
                    } else {
                        use_gop.value_ptr.* = .{
                            .first_parent = raw,
                            .additional_parent = raw,
                        };
                    }
                }
            }
            if (child_raw == @intFromEnum(root)) {
                report.ambiguous_ast_parent += 1;
                if (report.first_ambiguous_ast_parent == null) report.first_ambiguous_ast_parent = .{
                    .node_index = child_raw,
                    .first_parent = null,
                    .additional_parent = raw,
                };
            } else {
                const parent_gop = try parent_by_node.getOrPut(allocator, child_raw);
                if (parent_gop.found_existing) {
                    if (parent_gop.value_ptr.* != raw) {
                        const first_scope_position = scopeStatementPosition(
                            ast,
                            root,
                            &parent_by_node,
                            child_raw,
                            parent_gop.value_ptr.*,
                        );
                        const additional_scope_position = scopeStatementPosition(
                            ast,
                            root,
                            &parent_by_node,
                            child_raw,
                            raw,
                        );
                        if (first_scope_position) |first_position| {
                            if (additional_scope_position) |additional_position| {
                                if ((first_position.owner_node_index != additional_position.owner_node_index or
                                    first_position.statement_index != additional_position.statement_index) and
                                    !aliased_scope_statement_parents.contains(child_raw))
                                {
                                    try aliased_scope_statement_parents.put(allocator, child_raw, .{
                                        .first_parent = parent_gop.value_ptr.*,
                                        .additional_parent = raw,
                                        .first_owner = first_position.owner_node_index,
                                        .additional_owner = additional_position.owner_node_index,
                                        .first_stmt_idx = first_position.statement_index,
                                        .additional_stmt_idx = additional_position.statement_index,
                                    });
                                }
                            }
                        }
                        const first_stmt_idx = topLevelStatementIndex(
                            ast,
                            root,
                            &parent_by_node,
                            child_raw,
                            parent_gop.value_ptr.*,
                        );
                        const additional_stmt_idx = topLevelStatementIndex(
                            ast,
                            root,
                            &parent_by_node,
                            child_raw,
                            raw,
                        );
                        if (first_stmt_idx) |first_index| {
                            if (additional_stmt_idx) |additional_index| {
                                if (first_index != additional_index and
                                    !aliased_statement_parents.contains(child_raw))
                                {
                                    try aliased_statement_parents.put(allocator, child_raw, .{
                                        .first_parent = parent_gop.value_ptr.*,
                                        .additional_parent = raw,
                                        .first_stmt_idx = first_index,
                                        .additional_stmt_idx = additional_index,
                                    });
                                }
                            }
                        }
                    }
                    if (parent_gop.value_ptr.* != raw) {
                        const first_scope = expectedReferenceScopeFromParent(
                            ast,
                            root,
                            &parent_by_node,
                            scope_owner_map,
                            child_raw,
                            parent_gop.value_ptr.*,
                        );
                        const additional_scope = expectedReferenceScopeFromParent(
                            ast,
                            root,
                            &parent_by_node,
                            scope_owner_map,
                            child_raw,
                            raw,
                        );
                        // AST nodes can legitimately be aliased by more
                        // than one structural parent inside one lexical
                        // scope. Only a conflicting or unprovable scope
                        // path is ambiguous for identifier identity.
                        if (first_scope == null or additional_scope == null or
                            first_scope.?.scope != additional_scope.?.scope)
                        {
                            report.ambiguous_ast_parent += 1;
                            if (report.first_ambiguous_ast_parent == null) report.first_ambiguous_ast_parent = .{
                                .node_index = child_raw,
                                .first_parent = parent_gop.value_ptr.*,
                                .additional_parent = raw,
                            };
                        }
                    }
                } else parent_gop.value_ptr.* = raw;
            }
            try reachable_stack.append(allocator, .{ .node_index = child });
        }
    }
    // A ScopeId represents one lexical boundary. Check the reverse mapping
    // for reachable, kind-compatible owners: stale owners left behind by
    // lowering are allowed, but two live owners cannot share that identity.
    var first_owner_by_scope: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer first_owner_by_scope.deinit(allocator);
    for (reachable_node_order.items) |raw| {
        const scope_id = scope_owner_map.get(raw) orelse continue;
        if (scope_id >= scopes.len) continue;
        const tag = ast.nodes.items[raw].tag;
        if (!scopeOwnerKindMatches(tag, scopes[scope_id].kind)) continue;
        const first_owner = try first_owner_by_scope.getOrPut(allocator, scope_id);
        if (first_owner.found_existing) {
            if (first_owner.value_ptr.* != raw) {
                recordDuplicateScopeOwner(&report, raw, tag, scope_id, first_owner.value_ptr.*);
            }
        } else {
            first_owner.value_ptr.* = raw;
        }
    }
    // Rebuild namespace IIFE-scope ownership from the transformed reachable
    // declarations. The analyzer keeps this map while resolving references,
    // but ModuleSemanticData stores the declaration-to-proxy relation instead.
    // Deriving it here keeps erased namespaces out and lets exact validation
    // resolve merged namespace members through their canonical proxy owner.
    var namespace_scope_owners: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer namespace_scope_owners.deinit(allocator);
    if (namespace_declaration_owners) |declaration_owners| {
        var namespace_nodes = reachable_nodes.iterator();
        while (namespace_nodes.next()) |entry| {
            const raw = entry.key_ptr.*;
            const declaration = ast.nodes.items[raw];
            if (declaration.tag != .ts_module_declaration or declaration.data.binary.flags == 1) continue;
            const scope_id = scope_owner_map.get(raw) orelse continue;
            const name_idx = declaration.data.binary.left;
            if (name_idx.isNone() or @intFromEnum(name_idx) >= symbol_ids.len) continue;
            const declaration_id = symbol_ids[@intFromEnum(name_idx)] orelse continue;
            if (declaration_id >= symbols.len) continue;
            const owner_id = declaration_owners.get(declaration_id) orelse declaration_id;
            if (scope_id >= scopes.len or owner_id >= symbols.len) {
                recordScopeMapMismatch(&report, "namespace-scope-owner-out-of-range", scope_id, owner_id, null);
                continue;
            }
            const owner = try namespace_scope_owners.getOrPut(allocator, scope_id);
            if (owner.found_existing and owner.value_ptr.* != owner_id) {
                recordScopeMapMismatch(&report, "namespace-scope-owner-conflict", scope_id, owner_id, exactSymbolName(ast, &symbols[owner_id]));
            } else {
                owner.value_ptr.* = owner_id;
            }
        }
    }
    var dynamic_eval_units: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer dynamic_eval_units.deinit(allocator);
    var with_body_roots: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer with_body_roots.deinit(allocator);
    var reachable_dynamic_scan = reachable_nodes.iterator();
    while (reachable_dynamic_scan.next()) |entry| {
        const raw = entry.key_ptr.*;
        const node = ast.nodes.items[raw];
        if (node.tag == .with_statement and !node.data.binary.right.isNone()) {
            try with_body_roots.put(allocator, @intFromEnum(node.data.binary.right), {});
        }
        if (node.tag != .call_expression or node.data.extra + 2 >= ast.extra_data.items.len) continue;
        const callee: NodeIndex = @enumFromInt(ast.extra_data.items[node.data.extra]);
        if (callee.isNone() or @intFromEnum(callee) >= ast.nodes.items.len) continue;
        const callee_node = ast.getNode(callee);
        if (callee_node.tag != .identifier_reference or
            !std.mem.eql(u8, ast.getText(callee_node.data.string_ref), "eval")) continue;
        const eval_scope = expectedReferenceScope(ast, root, &parent_by_node, scope_owner_map, @intFromEnum(callee)) orelse continue;
        if (exactExecutionUnit(scopes, @enumFromInt(eval_scope.scope))) |unit|
            try dynamic_eval_units.put(allocator, unit, {});
    }
    var declaration_nodes = try collectDeclarationNodes(allocator, ast, &reachable_nodes);
    defer declaration_nodes.deinit(allocator);
    var references_by_node: std.AutoHashMapUnmanaged(u32, IndexedReference) = .empty;
    defer references_by_node.deinit(allocator);
    var helper_refs: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer helper_refs.deinit(allocator);
    for (helper_reference_nodes) |node| try helper_refs.put(allocator, node, {});
    // Runtime helper markers include both local call/import nodes and, for
    // defensive coverage, import_specifier.left (the imported export name).
    // The export-name slot is not a local binding unless it aliases the local
    // slot itself; every reachable local/call node must resolve through the
    // exact helper map entry and carry that SymbolId.
    for (helper_reference_nodes) |raw| {
        if (raw >= ast.nodes.items.len) {
            report.helper_symbol_mismatch += 1;
            continue;
        }
        if (!reachable_nodes.contains(raw)) continue;
        if (parent_by_node.get(raw)) |parent_raw| {
            if (parent_raw < ast.nodes.items.len) {
                const parent = ast.nodes.items[parent_raw];
                if (parent.tag == .import_specifier) {
                    const is_imported_slot = @intFromEnum(parent.data.binary.left) == raw;
                    const is_local_slot = @intFromEnum(parent.data.binary.right) == raw;
                    if (is_imported_slot and !is_local_slot) continue;
                    if (!is_imported_slot and !is_local_slot) {
                        report.helper_symbol_mismatch += 1;
                        continue;
                    }
                }
            }
        }
        const node = ast.nodes.items[raw];
        if (node.tag != .identifier_reference and node.tag != .jsx_identifier) {
            report.helper_symbol_mismatch += 1;
            continue;
        }
        if (raw >= symbol_ids.len or symbol_ids[raw] == null or symbol_ids[raw].? >= symbols.len) {
            report.helper_symbol_mismatch += 1;
            continue;
        }
        const sid = symbol_ids[raw].?;
        const name = ast.getText(node.data.string_ref);
        const helper_id = helper_scope_map.get(name) orelse {
            report.helper_symbol_mismatch += 1;
            continue;
        };
        const symbol = symbols[sid];
        if (helper_id != sid or symbol.kind != .import_binding or
            !std.mem.eql(u8, exactSymbolName(ast, &symbol), name))
        {
            report.helper_symbol_mismatch += 1;
        }
    }
    var declaration_counts = try allocator.alloc(usize, symbols.len);
    defer allocator.free(declaration_counts);
    var value_counts = try allocator.alloc(usize, symbols.len);
    defer allocator.free(value_counts);
    var write_counts = try allocator.alloc(usize, symbols.len);
    defer allocator.free(write_counts);
    @memset(declaration_counts, 0);
    @memset(value_counts, 0);
    @memset(write_counts, 0);

    if (scope_maps.len != scopes.len) recordScopeMapMismatch(&report, "scope-map-count", null, null, null);
    for (scopes, 0..) |scope, scope_i| {
        if (scope_i == 0) {
            if (!scope.parent.isNone()) report.invalid_scope += 1;
        } else if (!exactValidScope(scopes, scope.parent) or scope.parent.toIndex() == scope_i) {
            report.invalid_scope += 1;
        }
        var ancestor: ScopeId = @enumFromInt(@as(u32, @intCast(scope_i)));
        var hops: usize = 0;
        while (!ancestor.isNone() and hops <= scopes.len) : (hops += 1) {
            if (!exactValidScope(scopes, ancestor)) {
                report.invalid_scope += 1;
                break;
            }
            ancestor = scopes[ancestor.toIndex()].parent;
        }
        if (!ancestor.isNone()) report.invalid_scope += 1;
        if (scope_i >= scope_maps.len) continue;
        var bindings = scope_maps[scope_i].iterator();
        while (bindings.next()) |entry| {
            if (entry.value_ptr.* >= symbols.len) {
                recordScopeMapMismatch(&report, "entry-symbol-out-of-range", @intCast(scope_i), @intCast(entry.value_ptr.*), entry.key_ptr.*);
                continue;
            }
            const mapped_symbol = symbols[entry.value_ptr.*];
            const mapped_scope: ScopeId = @enumFromInt(@as(u32, @intCast(scope_i)));
            if (!std.mem.eql(u8, entry.key_ptr.*, exactSymbolName(ast, &mapped_symbol)) or
                mapped_symbol.scope_id != mapped_scope)
            {
                recordScopeMapMismatch(&report, "entry-name-or-owner", @intCast(scope_i), @intCast(entry.value_ptr.*), entry.key_ptr.*);
            }
        }
    }
    for (symbols) |symbol| {
        if (!exactValidScope(scopes, symbol.scope_id)) report.invalid_scope += 1;
    }

    if (pre_transform_scope_count) |source_scope_count| {
        if (source_scope_count > scopes.len) {
            recordScopeOwnerMismatch(&report, @intFromEnum(root), ast.getNode(root).tag, "source-scope-count-out-of-range", null, null, null);
        } else {
            var reachable_scope_owners: std.AutoHashMapUnmanaged(u32, void) = .empty;
            defer reachable_scope_owners.deinit(allocator);
            var live_scope_ids: std.AutoHashMapUnmanaged(u32, void) = .empty;
            defer live_scope_ids.deinit(allocator);
            for (symbols) |symbol| try markScopeAndAncestors(allocator, &live_scope_ids, scopes, @intFromEnum(symbol.scope_id));
            for (references) |reference| try markScopeAndAncestors(allocator, &live_scope_ids, scopes, @intFromEnum(reference.scope_id));
            for (scope_maps, 0..) |scope_map, scope_index| {
                if (scope_map.count() > 0) try markScopeAndAncestors(allocator, &live_scope_ids, scopes, @intCast(scope_index));
            }
            var reachable_owner_iter = reachable_nodes.iterator();
            while (reachable_owner_iter.next()) |entry| {
                if (scope_owner_map.get(entry.key_ptr.*)) |scope| {
                    if (scope < scopes.len and scopeOwnerKindMatches(ast.nodes.items[entry.key_ptr.*].tag, scopes[scope].kind)) {
                        try reachable_scope_owners.put(allocator, scope, {});
                    }
                }
            }
            for (source_scope_count..scopes.len) |scope_index| {
                const scope_id: u32 = @intCast(scope_index);
                // Empty dead scopes left by a lowering are inert: no symbol,
                // reference, or descendant scope depends on them. Gate every
                // semantically live transform scope and its ancestor chain.
                if (!live_scope_ids.contains(scope_id) or reachable_scope_owners.contains(scope_id)) continue;
                const mapped_owner = scopeOwnerNode(scope_owner_map, scope_id);
                const owner_node = if (mapped_owner) |raw|
                    if (raw < ast.nodes.items.len) ast.nodes.items[raw].tag else .program
                else
                    .program;
                recordScopeOwnerMismatch(
                    &report,
                    mapped_owner orelse std.math.maxInt(u32),
                    owner_node,
                    "generated-scope-owner-unreachable",
                    scope_id,
                    null,
                    scopes[scope_index].kind,
                );
            }
        }
    }
    var namespace_owners_iter = namespace_scope_owners.iterator();
    while (namespace_owners_iter.next()) |entry| {
        const namespace_scope = entry.key_ptr.*;
        const owner_id = entry.value_ptr.*;
        if (namespace_scope >= scopes.len or owner_id >= symbols.len) {
            recordScopeMapMismatch(&report, "namespace-scope-owner-out-of-range", namespace_scope, owner_id, null);
            continue;
        }
        var has_declaration = false;
        var nodes = reachable_nodes.iterator();
        while (nodes.next()) |node_entry| {
            const raw = node_entry.key_ptr.*;
            if (raw >= ast.nodes.items.len or ast.nodes.items[raw].tag != .ts_module_declaration or
                ast.nodes.items[raw].data.binary.flags == 1) continue;
            if (scope_owner_map.get(raw) == namespace_scope) {
                has_declaration = true;
                break;
            }
        }
        if (!has_declaration) {
            recordScopeMapMismatch(&report, "namespace-scope-owner-unreachable", namespace_scope, owner_id, exactSymbolName(ast, &symbols[owner_id]));
        }
    }
    if (namespace_member_owners) |member_owners| {
        var members = member_owners.iterator();
        while (members.next()) |entry| {
            const member_id = entry.key_ptr.*;
            const owner_id = entry.value_ptr.*;
            if (member_id >= symbols.len or owner_id >= symbols.len) {
                recordScopeMapMismatch(&report, "namespace-member-owner-out-of-range", null, member_id, null);
                continue;
            }
            var owner_has_scope = false;
            var owner_scopes = namespace_scope_owners.iterator();
            while (owner_scopes.next()) |owner_scope| {
                if (owner_scope.key_ptr.* < scopes.len and owner_scope.value_ptr.* == owner_id) {
                    owner_has_scope = true;
                    break;
                }
            }
            if (!owner_has_scope) {
                recordScopeMapMismatch(&report, "namespace-member-owner-unreachable", null, member_id, exactSymbolName(ast, &symbols[member_id]));
            }
            var member_in_lexical_map = false;
            for (scope_maps) |map| {
                var bindings = map.iterator();
                while (bindings.next()) |binding| {
                    if (binding.value_ptr.* == member_id) {
                        member_in_lexical_map = true;
                        break;
                    }
                }
                if (member_in_lexical_map) break;
            }
            if (member_in_lexical_map) {
                recordScopeMapMismatch(&report, "namespace-member-in-lexical-map", @intFromEnum(symbols[member_id].scope_id), member_id, exactSymbolName(ast, &symbols[member_id]));
            }
        }
    }
    // Validate both directions: a scope-map entry must point to a same-named
    // symbol in that scope, and every symbol must be reachable through its
    // scope map or the isolated runtime-helper map.
    for (symbols, 0..) |symbol, sid| {
        if (!exactValidScope(scopes, symbol.scope_id)) continue;
        // Expression `export default` has a synthetic reachability facade
        // without an emitted local binding when no using transform runs.
        // Its scope-map alias is optional because a user `_default` may own
        // that lexical name.
        if (symbol.decl_flags.is_default_export and std.mem.eql(u8, symbol.synthetic_name, "_default")) continue;
        // Enum members are semantic properties of the generated IIFE object,
        // not lexical bindings, so they intentionally have no scope-map entry.
        if (symbol.synthetic_kind == .enum_iife_member) continue;
        if (namespace_member_owners) |member_owners| {
            if (sid <= std.math.maxInt(u32) and member_owners.contains(@intCast(sid))) continue;
        }
        const name = exactSymbolName(ast, &symbol);
        const normal = if (symbol.scope_id.toIndex() < scope_maps.len)
            scope_maps[symbol.scope_id.toIndex()].get(name)
        else
            null;
        const helper = helper_scope_map.get(name);
        if ((normal == null or normal.? != sid) and (helper == null or helper.? != sid))
            recordScopeMapMismatch(&report, "symbol-not-in-either-map", @intFromEnum(symbol.scope_id), @intCast(sid), name);
    }
    var reachable_iter = reachable_nodes.iterator();
    while (reachable_iter.next()) |reachable_entry| {
        const raw = reachable_entry.key_ptr.*;
        const tag = ast.nodes.items[raw].tag;
        const is_generated = raw >= parser_node_count;
        const expected_kind: ?ScopeKind = switch (tag) {
            .program => null, // global vs module depends on parser mode
            .block_statement, .for_statement, .for_in_statement, .for_of_statement, .for_await_of_statement => .block,
            .switch_statement => .switch_block,
            // The source analyzer enters catch and body-block scopes on the
            // same owner node; the latter may be the recorded owner.
            .catch_clause => null,
            .class_declaration, .class_expression => .class_body,
            .function_declaration, .function_expression, .function, .arrow_function_expression, .method_definition, .flow_component_wrapper => .function,
            else => continue,
        };
        if (tag == .block_statement) {
            const parent_raw = parent_by_node.get(raw);
            // Namespace analysis enters the namespace's function scope, then
            // visits this block's statement list directly. The block is a
            // syntax container, not a second lexical ScopeId owner.
            if (isNamespaceBodyBlock(ast, &parent_by_node, raw)) continue;
            const is_function_body = if (parent_raw) |parent| blk: {
                const parent_node = ast.nodes.items[parent];
                break :blk ast.functionBodyBlock(parent_node) != null and
                    @intFromEnum(ast.functionBodyBlock(parent_node).?) == raw;
            } else false;
            const is_aliased_catch_body = if (parent_raw) |parent| blk: {
                const parent_node = ast.nodes.items[parent];
                if (parent_node.tag != .catch_clause or scope_owner_map.get(parent) == null) break :blk false;
                const parent_scope = scope_owner_map.get(parent).?;
                break :blk parent_scope < scopes.len and scopes[parent_scope].kind == .block;
            } else false;
            if (is_function_body or is_aliased_catch_body) continue;
        }
        // Flow component analysis enters the function scope on the wrapper,
        // then visits the synthetic implementation declaration's body in
        // that scope. The inner declaration does not own a second scope.
        if (tag == .function_declaration and
            isFlowComponentImplementationFunction(ast, &parent_by_node, raw)) continue;
        const raw_scope = scope_owner_map.get(raw) orelse {
            // Rebuilt Programs and generated blocks/loops may be structural
            // wrappers with no fresh semantic scope. Class, switch, catch, and
            // function nodes always establish a semantic boundary.
            if (is_generated and (tag == .program or tag == .block_statement or tag == .for_statement or
                tag == .for_in_statement or tag == .for_of_statement or tag == .for_await_of_statement)) continue;
            recordScopeOwnerMismatch(&report, raw, tag, "missing-owner", null, expected_kind, null);
            continue;
        };
        if (raw_scope >= scopes.len) {
            recordScopeOwnerMismatch(&report, raw, tag, "owner-out-of-range", raw_scope, expected_kind, null);
            continue;
        }
        const actual_kind = scopes[raw_scope].kind;
        if (expected_kind) |expected| {
            if (actual_kind != expected) recordScopeOwnerMismatch(&report, raw, tag, "owner-kind", raw_scope, expected, actual_kind);
        } else switch (tag) {
            .program => {
                if (actual_kind != .global and actual_kind != .module)
                    recordScopeOwnerMismatch(&report, raw, tag, "program-owner-kind", raw_scope, null, actual_kind);
            },
            .catch_clause => {
                if (actual_kind != .catch_clause and actual_kind != .block)
                    recordScopeOwnerMismatch(&report, raw, tag, "catch-owner-kind", raw_scope, null, actual_kind);
            },
            else => unreachable,
        }
    }
    // The owner kind and each scope's internal parent chain can both be valid
    // while a source owner is attached to an unrelated scope subtree. Check
    // this only against the original analyzed AST: lowering can move source
    // owners into wrappers while preserving their lexical ScopeIds, so the
    // emitted AST ancestry is not a reliable parent oracle after transformation.
    var reachable_scope_nodes = reachable_nodes.iterator();
    while (reachable_scope_nodes.next()) |entry| {
        const raw = entry.key_ptr.*;
        const scope_raw = scope_owner_map.get(raw) orelse continue;
        // Source scopes are checked against the original AST before lowering;
        // their emitted owners may have moved under generated wrappers. A
        // transform-created scope has no such source owner, so validate its
        // parent against the final emitted AST here as well.
        if (pre_transform_scope_count) |source_scope_count| {
            if (scope_raw < source_scope_count) continue;
        }
        if (scope_raw >= scopes.len) continue;
        const owner_scope = scopes[scope_raw];
        if (raw == @intFromEnum(root)) {
            // A non-Program root can be a fragment nested inside an implicit
            // outer scope, so only a Program owner is required to be parentless.
            if (ast.nodes.items[raw].tag == .program and !owner_scope.parent.isNone())
                recordScopeOwnerParentMismatch(
                    &report,
                    raw,
                    ast.nodes.items[raw].tag,
                    scope_raw,
                    null,
                    if (exactValidScope(scopes, owner_scope.parent)) @intFromEnum(owner_scope.parent) else null,
                );
            continue;
        }
        const expected_parent = expectedReferenceScope(ast, root, &parent_by_node, scope_owner_map, raw) orelse {
            recordScopeOwnerParentMismatch(
                &report,
                raw,
                ast.nodes.items[raw].tag,
                scope_raw,
                null,
                if (exactValidScope(scopes, owner_scope.parent)) @intFromEnum(owner_scope.parent) else null,
            );
            continue;
        };
        if (ownerParentMatchesAst(
            ast,
            symbol_ids,
            symbols,
            scopes,
            scope_maps,
            scope_owner_map,
            raw,
            scope_raw,
            expected_parent.scope,
            pre_transform_scope_count,
        )) continue;
        recordScopeOwnerParentMismatch(
            &report,
            raw,
            ast.nodes.items[raw].tag,
            scope_raw,
            expected_parent.scope,
            if (exactValidScope(scopes, owner_scope.parent)) @intFromEnum(owner_scope.parent) else null,
        );
    }

    var owners = scope_owner_map.iterator();
    while (owners.next()) |entry| {
        if (entry.key_ptr.* >= ast.nodes.items.len or entry.value_ptr.* >= scopes.len) {
            recordScopeOwnerMismatch(&report, entry.key_ptr.*, .program, "map-entry-out-of-range", entry.value_ptr.*, null, null);
        } else if (reachable_nodes.contains(entry.key_ptr.*) and
            !scopeOwnerKindMatches(ast.nodes.items[entry.key_ptr.*].tag, scopes[entry.value_ptr.*].kind))
        {
            recordScopeOwnerMismatch(
                &report,
                entry.key_ptr.*,
                ast.nodes.items[entry.key_ptr.*].tag,
                "owner-node-kind",
                entry.value_ptr.*,
                null,
                scopes[entry.value_ptr.*].kind,
            );
        }
    }

    // Namespace codegen emits an IIFE parameter that has no AST binding node.
    // Require its identity to exist in the namespace declaration's function
    // scope, and keep it distinct from the source namespace-object binding.
    var matched_namespace_params: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer matched_namespace_params.deinit(allocator);
    var namespace_nodes = reachable_nodes.iterator();
    while (namespace_nodes.next()) |entry| {
        const raw = entry.key_ptr.*;
        const declaration = ast.nodes.items[raw];
        if (declaration.tag != .ts_module_declaration or declaration.data.binary.flags == 1) continue;
        const scope_raw = scope_owner_map.get(raw) orelse {
            report.namespace_iife_param_mismatch += 1;
            continue;
        };
        if (scope_raw >= scopes.len or scopes[scope_raw].kind != .function) {
            report.namespace_iife_param_mismatch += 1;
            continue;
        }
        var parameter_id: ?u32 = null;
        var parameter_count: usize = 0;
        for (symbols, 0..) |symbol, sid| {
            if (symbol.synthetic_kind != .namespace_iife_parameter or @intFromEnum(symbol.scope_id) != scope_raw) continue;
            parameter_id = @intCast(sid);
            parameter_count += 1;
        }
        if (parameter_count != 1 or parameter_id == null) {
            report.namespace_iife_param_mismatch += 1;
            continue;
        }
        const sid = parameter_id.?;
        report.namespace_iife_params += 1;
        const parameter = symbols[sid];
        if (parameter.kind != .parameter or !parameter.decl_flags.is_parameter or parameter.synthetic_name.len == 0 or
            scope_raw >= scope_maps.len or scope_maps[scope_raw].get(parameter.synthetic_name) != @as(?usize, @intCast(sid)))
        {
            report.namespace_iife_param_mismatch += 1;
        }
        const source_name = declaration.data.binary.left;
        if (source_name.isNone() or @intFromEnum(source_name) >= ast.nodes.items.len or @intFromEnum(source_name) >= symbol_ids.len or
            symbol_ids[@intFromEnum(source_name)] == null or symbol_ids[@intFromEnum(source_name)].? == sid)
        {
            report.namespace_iife_param_mismatch += 1;
        }
        try matched_namespace_params.put(allocator, sid, {});
    }
    for (symbols, 0..) |symbol, sid| {
        if (symbol.synthetic_kind != .namespace_iife_parameter or sid > std.math.maxInt(u32)) continue;
        const id: u32 = @intCast(sid);
        if (matched_namespace_params.contains(id)) continue;
        var owner_is_reachable = false;
        var reachable_owner_scan = reachable_nodes.iterator();
        while (reachable_owner_scan.next()) |reachable| {
            if (scope_owner_map.get(reachable.key_ptr.*) == @as(?u32, @intFromEnum(symbol.scope_id))) {
                owner_is_reachable = true;
                break;
            }
        }
        if (owner_is_reachable) report.namespace_iife_param_mismatch += 1;
    }

    // Enum codegen emits a parameter for every non-const, non-ambient runtime
    // enum. Its initializer references must resolve through this exact function
    // scope; a textual match with the outer enum name is not identity evidence.
    var matched_enum_params: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer matched_enum_params.deinit(allocator);
    var enum_nodes = reachable_nodes.iterator();
    while (enum_nodes.next()) |entry| {
        const raw = entry.key_ptr.*;
        const declaration = ast.nodes.items[raw];
        if (declaration.tag != .ts_enum_declaration) continue;
        const enum_extra = declaration.data.extra;
        if (enum_extra + 3 >= ast.extra_data.items.len or ast.extra_data.items[enum_extra + 3] != 0) continue;
        const scope_raw = scope_owner_map.get(raw) orelse {
            report.enum_iife_param_mismatch += 1;
            continue;
        };
        if (scope_raw >= scopes.len or scopes[scope_raw].kind != .function) {
            report.enum_iife_param_mismatch += 1;
            continue;
        }
        var parameter_id: ?u32 = null;
        var parameter_count: usize = 0;
        for (symbols, 0..) |symbol, sid| {
            if (symbol.synthetic_kind != .enum_iife_parameter or @intFromEnum(symbol.scope_id) != scope_raw) continue;
            parameter_id = @intCast(sid);
            parameter_count += 1;
        }
        if (parameter_count != 1 or parameter_id == null) {
            report.enum_iife_param_mismatch += 1;
            continue;
        }
        const sid = parameter_id.?;
        report.enum_iife_params += 1;
        const parameter = symbols[sid];
        const name_idx: NodeIndex = @enumFromInt(ast.extra_data.items[enum_extra]);
        const source_name = if (!name_idx.isNone() and @intFromEnum(name_idx) < ast.nodes.items.len)
            ast.getText(ast.getNode(name_idx).span)
        else
            "";
        if (parameter.kind != .parameter or !parameter.decl_flags.is_parameter or parameter.synthetic_name.len == 0 or
            source_name.len == 0 or scope_raw >= scope_maps.len or
            scope_maps[scope_raw].get(source_name) != @as(?usize, @intCast(sid)))
        {
            report.enum_iife_param_mismatch += 1;
        }
        if (name_idx.isNone() or @intFromEnum(name_idx) >= ast.nodes.items.len or @intFromEnum(name_idx) >= symbol_ids.len or
            symbol_ids[@intFromEnum(name_idx)] == null or symbol_ids[@intFromEnum(name_idx)].? == sid)
        {
            report.enum_iife_param_mismatch += 1;
        }
        try matched_enum_params.put(allocator, sid, {});
    }
    for (symbols, 0..) |symbol, sid| {
        if (symbol.synthetic_kind != .enum_iife_parameter or sid > std.math.maxInt(u32)) continue;
        const id: u32 = @intCast(sid);
        if (matched_enum_params.contains(id)) continue;
        var owner_is_reachable = false;
        var reachable_owner_scan = reachable_nodes.iterator();
        while (reachable_owner_scan.next()) |reachable| {
            const owner_idx = reachable.key_ptr.*;
            if (ast.nodes.items[owner_idx].tag == .ts_enum_declaration and
                scope_owner_map.get(owner_idx) == @as(?u32, @intCast(@intFromEnum(symbol.scope_id))))
            {
                owner_is_reachable = true;
                break;
            }
        }
        if (owner_is_reachable) report.enum_iife_param_mismatch += 1;
    }

    for (references) |reference| {
        const sid = @intFromEnum(reference.symbol_id);
        if (sid >= symbols.len) {
            report.invalid_id += 1;
            continue;
        }
        if (reference.flags.declare) {
            declaration_counts[sid] += 1;
            // A declaration row records the target storage scope, unlike a
            // value reference which records the scope where the read/write
            // occurs. Visibility from a descendant scope is not enough to
            // prove that declaration ownership is correct.
            if (reference.scope_id != symbols[sid].scope_id) report.declaration_scope_mismatch += 1;
        } else if (!reference.flags.type_context and !reference.flags.value_as_type and
            (reference.flags.read or reference.flags.write))
        {
            value_counts[sid] += 1;
            if (reference.flags.write) write_counts[sid] += 1;
        }
        if (!exactValidScope(scopes, reference.scope_id)) {
            report.invalid_scope += 1;
        } else if (!exactVisibleFrom(scopes, symbols, reference.symbol_id, reference.scope_id)) {
            report.invisible_reference += 1;
        }
        if (reference.node_index.isNone()) {
            if (!reference.flags.declare) report.invalid_reference_node += 1;
            continue;
        }
        const key = @intFromEnum(reference.node_index);
        if (key >= ast.nodes.items.len or reference.flags.declare) {
            report.invalid_reference_node += 1;
            continue;
        }
        if (!reachable_nodes.contains(key)) {
            report.unreachable_reference += 1;
            continue;
        }
        switch (ast.nodes.items[key].tag) {
            .identifier_reference, .assignment_target_identifier, .jsx_identifier => {},
            else => {
                report.invalid_reference_node += 1;
                continue;
            },
        }
        if (ast.nodes.items[@intFromEnum(root)].tag == .program and
            reference.stmt_idx != Reference.NO_STMT)
        {
            const expected_stmt_idx = topLevelStatementIndex(ast, root, &parent_by_node, key, null);
            if (expected_stmt_idx == null or expected_stmt_idx.? != reference.stmt_idx) {
                recordReferenceStatementMismatch(
                    &report,
                    key,
                    reference.stmt_idx,
                    expected_stmt_idx,
                    parent_by_node.get(key),
                    null,
                );
            }
        }
        if (references_by_node.getPtr(key)) |existing| {
            existing.count += 1;
            if (existing.symbol_id != sid) report.identity_mismatch += 1;
        } else {
            try references_by_node.put(allocator, key, .{
                .symbol_id = sid,
                .scope_id = reference.scope_id,
            });
        }
    }
    if (ast.nodes.items[@intFromEnum(root)].tag == .program) {
        var aliased_nodes = aliased_statement_parents.iterator();
        while (aliased_nodes.next()) |entry| {
            const node = entry.key_ptr.*;
            if (!references_by_node.contains(node)) continue;
            const parents = entry.value_ptr.*;
            recordReferenceStatementMismatch(
                &report,
                node,
                null,
                parents.first_stmt_idx,
                parents.first_parent,
                parents.additional_parent,
            );
        }
    }
    var aliased_scope_nodes = aliased_scope_statement_parents.iterator();
    while (aliased_scope_nodes.next()) |entry| {
        const node = entry.key_ptr.*;
        if (!references_by_node.contains(node)) continue;
        const parents = entry.value_ptr.*;
        recordReferenceScopeStatementAlias(&report, node, parents);
    }
    var aliased_reference_uses = reference_node_use_edges.iterator();
    while (aliased_reference_uses.next()) |entry| {
        const node = entry.key_ptr.*;
        if (entry.value_ptr.count <= 1 or !references_by_node.contains(node)) continue;
        report.reference_node_use_alias += entry.value_ptr.count - 1;
        if (report.first_reference_node_use_alias == null) {
            report.first_reference_node_use_alias = .{
                .node_index = node,
                .name = ast.getText(ast.nodes.items[node].span),
                .tag = ast.nodes.items[node].tag,
                .span_start = ast.nodes.items[node].span.start,
                .first_parent = entry.value_ptr.first_parent,
                .first_parent_tag = ast.nodes.items[entry.value_ptr.first_parent].tag,
                .additional_parent = entry.value_ptr.additional_parent,
                .additional_parent_tag = ast.nodes.items[entry.value_ptr.additional_parent].tag,
                .additional_uses = entry.value_ptr.count - 1,
            };
        }
    }
    for (symbols, 0..) |symbol, sid| {
        if (symbol.reference_count != value_counts[sid]) report.reference_count_mismatch += 1;
        if (symbol.write_count != write_counts[sid]) report.write_count_mismatch += 1;
    }
    var helper_scopes = helper_scope_map.iterator();
    while (helper_scopes.next()) |entry| {
        if (entry.value_ptr.* >= symbols.len) {
            recordScopeMapMismatch(&report, "helper-entry-symbol-out-of-range", null, @intCast(entry.value_ptr.*), entry.key_ptr.*);
            continue;
        }
        const symbol = symbols[entry.value_ptr.*];
        if (symbol.kind != .import_binding or !std.mem.eql(u8, entry.key_ptr.*, exactSymbolName(ast, &symbol))) {
            recordScopeMapMismatch(&report, "helper-entry-kind-or-name", @intFromEnum(symbol.scope_id), @intCast(entry.value_ptr.*), entry.key_ptr.*);
        }
    }

    var ctx: ExactCtx = .{
        .allocator = allocator,
        .ast = ast,
        .root = root,
        .parser_node_count = parser_node_count,
        .parent_by_node = &parent_by_node,
        .scope_owner_map = scope_owner_map,
        .symbol_ids = symbol_ids,
        .declaration_nodes = &declaration_nodes,
        .symbols = symbols,
        .scopes = scopes,
        .scope_maps = scope_maps,
        .namespace_member_owners = namespace_member_owners,
        .namespace_scope_owners = &namespace_scope_owners,
        .dynamic_eval_units = &dynamic_eval_units,
        .with_body_roots = &with_body_roots,
        .references_by_node = &references_by_node,
        .helper_reference_nodes = &helper_refs,
        .helper_scope_map = helper_scope_map,
        .declaration_counts = declaration_counts,
        .unresolved_nodes = unresolved_nodes,
        .explicit_global_nodes = explicit_global_nodes,
        .origins = origins,
        .reachable_nodes = &reachable_nodes,
        .report = &report,
    };
    defer ctx.name_positions.deinit(allocator);
    defer ctx.jsx_variable_roots.deinit(allocator);
    // The generic walker assumes an AST tree and has no visited set. A cyclic
    // graph has already failed the exact report, so stop before that walk can
    // loop forever or grow its stack without bound.
    if (report.cyclic_ast_edges == 0 and report.invalid_ast_root == 0 and
        report.invalid_ast_edge == 0 and report.invalid_ast_layout == 0)
        try ast_walk.walkPreorderIterative(allocator, ast, root, &ctx, exactVisit);
    if (ctx.oom) return error.OutOfMemory;
    return report;
}

/// Count reachable back edges without invoking a tree-only walker. The
/// synthetic coverage audit uses this preflight before its identifier walkers
/// so debug diagnostics also fail closed on malformed cyclic ASTs.
fn countCyclicAstEdges(
    allocator: std.mem.Allocator,
    ast: *const Ast,
    root: NodeIndex,
) std.mem.Allocator.Error!usize {
    const VisitState = enum { visiting, visited };
    const VisitFrame = struct {
        node_index: NodeIndex,
        exit: bool = false,
    };

    var states: std.AutoHashMapUnmanaged(u32, VisitState) = .empty;
    defer states.deinit(allocator);
    var stack: std.ArrayList(VisitFrame) = .empty;
    defer stack.deinit(allocator);
    try stack.append(allocator, .{ .node_index = root });

    var cyclic_edges: usize = 0;
    while (stack.pop()) |frame| {
        const node_index = frame.node_index;
        if (node_index.isNone() or @intFromEnum(node_index) >= ast.nodes.items.len) continue;
        const raw = @intFromEnum(node_index);
        if (frame.exit) {
            try states.put(allocator, raw, .visited);
            continue;
        }
        if (states.get(raw)) |state| {
            if (state == .visiting) cyclic_edges += 1;
            continue;
        }

        try states.put(allocator, raw, .visiting);
        try stack.append(allocator, .{ .node_index = node_index, .exit = true });
        var children = ast_walk.children(ast, ast.getNode(node_index));
        while (children.next()) |child| {
            if (!child.isNone() and @intFromEnum(child) < ast.nodes.items.len)
                try stack.append(allocator, .{ .node_index = child });
        }
    }
    return cyclic_edges;
}

/// Some lowerings retain the source lexical ScopeId for a user binding even
/// after its source owner node is removed (for example an extracted generator
/// loop argument). Accept that reference scope only when it remains visible
/// for the same source symbol and no reachable output AST node owns it.
fn isRetainedSourceScopeReference(ctx: *const ExactCtx, node: u32, symbol_id: SymbolId, use_scope: ScopeId) bool {
    const raw_id = @intFromEnum(symbol_id);
    if (raw_id >= ctx.symbols.len or !exactValidScope(ctx.scopes, use_scope)) return false;
    const symbol = ctx.symbols[raw_id];
    if (symbol.synthetic_kind != null or symbol.synthetic_name.len > 0) {
        // A generator state machine can replace a generated catch clause with
        // `binding = _state.sent()` and hoist that binding into its wrapper.
        // Keep the exact catch SymbolId only when the catch owner disappeared
        // from the output tree and a binding with that ID still exists there.
        if (symbol.kind != .catch_binding or
            hasReachableScopeOwner(ctx, @intFromEnum(symbol.scope_id)) or
            !hasReachableBindingForSymbol(ctx, raw_id)) return false;
    }
    if (!exactVisibleFrom(ctx.scopes, ctx.symbols, symbol_id, use_scope)) return false;
    var child = node;
    var hops: usize = 0;
    while (ctx.parent_by_node.get(child)) |parent| : (hops += 1) {
        if (hops >= ctx.ast.nodes.items.len or parent >= ctx.ast.nodes.items.len) return false;
        if (!childSkipsScopeOwner(ctx.ast, parent, child)) {
            if (ctx.scope_owner_map.get(parent)) |scope| {
                if (scope == @intFromEnum(use_scope)) return false;
            }
        }
        child = parent;
        if (child == @intFromEnum(ctx.root)) {
            if (ctx.scope_owner_map.get(child)) |scope| {
                if (scope == @intFromEnum(use_scope)) return false;
            }
            break;
        }
    }
    return true;
}

fn hasReachableScopeOwner(ctx: *const ExactCtx, scope: u32) bool {
    var nodes = ctx.reachable_nodes.iterator();
    while (nodes.next()) |entry| {
        if (ctx.scope_owner_map.get(entry.key_ptr.*)) |owner_scope| {
            if (owner_scope == scope) return true;
        }
    }
    return false;
}

fn hasReachableBindingForSymbol(ctx: *const ExactCtx, symbol_id: u32) bool {
    for (ctx.symbol_ids, 0..) |maybe_id, raw| {
        if (maybe_id == null or maybe_id.? != symbol_id or raw >= ctx.ast.nodes.items.len) continue;
        const node = @as(u32, @intCast(raw));
        if (ctx.reachable_nodes.contains(node) and ctx.ast.nodes.items[raw].tag == .binding_identifier) return true;
    }
    return false;
}

/// Compare the mutable SymbolIds used by minification/codegen with a fresh
/// semantic resolution of the final reachable AST. The pre-minify reference
/// table only preserves a transform-owned lexical reference when reanalysis
/// cannot see the generated scope; it never maps a rewritten alias reference.
pub const PostMinifyReport = struct {
    bindings_checked: usize = 0,
    references_checked: usize = 0,
    external_references: usize = 0,
    helper_references: usize = 0,
    preserved_transform_references: usize = 0,
    missing_binding_id: usize = 0,
    missing_reference_id: usize = 0,
    dangling_reference_id: usize = 0,
    wrong_reference_target: usize = 0,

    fn isObservationField(comptime name: []const u8) bool {
        return std.mem.eql(u8, name, "bindings_checked") or
            std.mem.eql(u8, name, "references_checked") or
            std.mem.eql(u8, name, "external_references") or
            std.mem.eql(u8, name, "helper_references") or
            std.mem.eql(u8, name, "preserved_transform_references");
    }

    /// The checked counts are observations. Every other numeric field is an
    /// invariant counter and participates automatically so a new failure
    /// counter cannot be omitted from the post-minify gate.
    pub fn isClean(self: PostMinifyReport) bool {
        inline for (std.meta.fields(PostMinifyReport)) |field| {
            if (comptime isObservationField(field.name)) continue;
            if (comptime field.type != usize) @compileError("unclassified PostMinifyReport field; classify it as an observation or usize invariant counter");
            if (@field(self, field.name) != 0) return false;
        }
        return true;
    }
};

pub fn checkPostMinify(
    allocator: std.mem.Allocator,
    ast: *const Ast,
    root: NodeIndex,
    actual_symbol_ids: []const ?u32,
    resolved_symbol_ids: []const ?u32,
    actual_symbols: []const Symbol,
    resolved_symbols: []const Symbol,
    pre_minify_references: []const Reference,
    helper_ref_nodes: []const u32,
    helper_scope_map: *const std.StringHashMapUnmanaged(usize),
    explicit_global_reference_nodes: *const std.AutoHashMapUnmanaged(u32, void),
    actual_class_self_symbols: *const std.AutoHashMapUnmanaged(u32, u32),
    resolved_class_self_symbols: *const std.AutoHashMapUnmanaged(u32, u32),
) !PostMinifyReport {
    const reachable = try ast_walk.collectReachableNodeIndicesFrom(allocator, ast, root);
    defer allocator.free(reachable);
    const reference_nodes = try reference_walk.collectIdentifierReferences(allocator, ast, root);
    defer allocator.free(reference_nodes);
    var reachable_set: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer reachable_set.deinit(allocator);
    for (reachable) |raw| try reachable_set.put(allocator, raw, {});
    var declaration_nodes = try collectDeclarationNodes(allocator, ast, &reachable_set);
    defer declaration_nodes.deinit(allocator);

    // One source/transform SymbolId can correspond to one or more surviving
    // output bindings after lowering. Keep the full relation so cloned scopes
    // remain valid while still rejecting a reference that resolves elsewhere.
    var binding_pairs: std.AutoHashMapUnmanaged(u64, void) = .empty;
    defer binding_pairs.deinit(allocator);
    var bound_actual_ids: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer bound_actual_ids.deinit(allocator);
    var helper_nodes: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer helper_nodes.deinit(allocator);
    for (helper_ref_nodes) |raw| try helper_nodes.put(allocator, raw, {});
    var pre_reference_ids: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer pre_reference_ids.deinit(allocator);
    for (pre_minify_references) |reference| {
        if (!reference.node_index.isNone()) try pre_reference_ids.put(allocator, @intFromEnum(reference.node_index), @intFromEnum(reference.symbol_id));
    }
    var report: PostMinifyReport = .{};

    for (reachable) |raw| {
        if (raw >= ast.nodes.items.len) continue;
        if (ast.nodes.items[raw].tag != .binding_identifier and !declaration_nodes.contains(raw)) continue;
        report.bindings_checked += 1;
        const actual = if (raw < actual_symbol_ids.len) actual_symbol_ids[raw] else null;
        const resolved = if (raw < resolved_symbol_ids.len) resolved_symbol_ids[raw] else null;
        if (actual == null or resolved == null) {
            report.missing_binding_id += 1;
            continue;
        }
        try bound_actual_ids.put(allocator, actual.?, {});
        try binding_pairs.put(allocator, (@as(u64, actual.?) << 32) | resolved.?, {});
    }

    // Named classes have a separate inner self-binding used by references in
    // the class body. It is attached to the class owner, not an AST binding node.
    for (reachable) |owner| {
        if (owner >= ast.nodes.items.len) continue;
        switch (ast.nodes.items[owner].tag) {
            .class_declaration, .class_expression => {},
            else => continue,
        }
        const resolved = resolved_class_self_symbols.get(owner) orelse continue;
        const owner_key = spanKey(ast.nodes.items[owner].span);
        var actual: ?u32 = null;
        var actual_it = actual_class_self_symbols.iterator();
        while (actual_it.next()) |entry| {
            if (entry.key_ptr.* >= ast.nodes.items.len) continue;
            const actual_owner = ast.nodes.items[entry.key_ptr.*];
            if (actual_owner.tag != .class_declaration and actual_owner.tag != .class_expression) continue;
            if (spanKey(actual_owner.span) != owner_key) continue;
            actual = entry.value_ptr.*;
            break;
        }
        const actual_id = actual orelse continue;
        report.bindings_checked += 1;
        try bound_actual_ids.put(allocator, actual_id, {});
        try binding_pairs.put(allocator, (@as(u64, actual_id) << 32) | resolved, {});
    }

    // Namespace and enum emitters synthesize an IIFE parameter in codegen;
    // its semantic SymbolId has no binding node in the transformed AST.
    for (actual_symbols, 0..) |actual_symbol, actual_raw| {
        const kind = actual_symbol.synthetic_kind orelse continue;
        if (kind != .namespace_iife_parameter and kind != .enum_iife_parameter) continue;
        if (actual_raw > std.math.maxInt(u32)) continue;
        for (resolved_symbols, 0..) |resolved_symbol, resolved_raw| {
            if (resolved_raw > std.math.maxInt(u32) or resolved_symbol.synthetic_kind != kind) continue;
            if (actual_symbol.declaration_span.start != resolved_symbol.declaration_span.start or
                actual_symbol.declaration_span.end != resolved_symbol.declaration_span.end or
                !std.mem.eql(u8, actual_symbol.synthetic_name, resolved_symbol.synthetic_name)) continue;
            const actual_id: u32 = @intCast(actual_raw);
            const resolved_id: u32 = @intCast(resolved_raw);
            try bound_actual_ids.put(allocator, actual_id, {});
            try binding_pairs.put(allocator, (@as(u64, actual_id) << 32) | resolved_id, {});
            break;
        }
    }

    // Some TypeScript namespace exports and transformed declarations have a
    // semantic declaration row but no identifier binding node in the output
    // AST. Match those rows by their declaration span, kind, and effective
    // name. This does not rescue erased aliases: the fresh analysis has no row
    // at the removed declaration span.
    for (actual_symbols, 0..) |actual_symbol, actual_raw| {
        if (actual_raw > std.math.maxInt(u32) or bound_actual_ids.contains(@intCast(actual_raw))) continue;
        const actual_name = if (actual_symbol.synthetic_name.len > 0)
            actual_symbol.synthetic_name
        else
            ast.getText(actual_symbol.name);
        const actual_id: u32 = @intCast(actual_raw);
        for (resolved_symbols, 0..) |resolved_symbol, resolved_raw| {
            if (resolved_raw > std.math.maxInt(u32) or actual_symbol.kind != resolved_symbol.kind or
                actual_symbol.synthetic_kind != resolved_symbol.synthetic_kind or
                actual_symbol.declaration_span.start != resolved_symbol.declaration_span.start or
                actual_symbol.declaration_span.end != resolved_symbol.declaration_span.end) continue;
            const resolved_name = if (resolved_symbol.synthetic_name.len > 0)
                resolved_symbol.synthetic_name
            else
                ast.getText(resolved_symbol.name);
            if (!std.mem.eql(u8, actual_name, resolved_name)) continue;
            const resolved_id: u32 = @intCast(resolved_raw);
            try bound_actual_ids.put(allocator, actual_id, {});
            try binding_pairs.put(allocator, (@as(u64, actual_id) << 32) | resolved_id, {});
        }
    }

    // Reachable identifier-shaped nodes are not all runtime references: after
    // ES5 shorthand lowering, the copied static property key still carries
    // source SymbolId lineage, but fresh semantic analysis correctly ignores
    // that key position. Use the shared edge-aware reference walk so the audit
    // compares only actual references.
    for (reference_nodes) |reference_node| {
        const raw = @intFromEnum(reference_node);
        if (raw >= ast.nodes.items.len) continue;
        if (ast.nodes.items[raw].tag == .binding_identifier or declaration_nodes.contains(raw)) continue;
        report.references_checked += 1;
        const actual = if (raw < actual_symbol_ids.len) actual_symbol_ids[raw] else null;
        const resolved = if (raw < resolved_symbol_ids.len) resolved_symbol_ids[raw] else null;
        const name = ast.getText(ast.nodes.items[raw].data.string_ref);
        const expected_helper = helper_scope_map.get(name);
        const mapped_helper = actual != null and expected_helper != null and
            actual.? == @as(u32, @intCast(expected_helper.?));
        if (helper_nodes.contains(raw) or mapped_helper) {
            report.helper_references += 1;
            if (actual == null or expected_helper == null) {
                report.missing_reference_id += 1;
            } else {
                const helper_id: u32 = @intCast(expected_helper.?);
                if (actual.? != helper_id) report.wrong_reference_target += 1;

                // A generated helper reference can share its final spelling
                // with a source binding. The helper marker proves the
                // transform-side target, but only the fresh resolution tells
                // us which binding the emitted identifier actually reaches.
                // When output resolution found a lexical binding, require the
                // exact helper-to-output binding pair just like other refs;
                // otherwise a shadowing source local could make this gate
                // report clean while runtime resolves the wrong symbol.
                if (resolved) |resolved_id| {
                    const pair = (@as(u64, helper_id) << 32) | resolved_id;
                    if (!binding_pairs.contains(pair)) report.wrong_reference_target += 1;
                }
            }
            continue;
        }
        if (explicit_global_reference_nodes.contains(raw) and actual == null) {
            report.external_references += 1;
            continue;
        }
        if (actual == null and resolved == null) continue; // unresolved external/global
        if (actual == null or resolved == null) {
            if (actual) |actual_id| {
                if (resolved == null and pre_reference_ids.get(raw) == actual_id and actual_id < actual_symbols.len) {
                    const actual_symbol = actual_symbols[actual_id];
                    const expected_name = if (actual_symbol.synthetic_name.len > 0)
                        actual_symbol.synthetic_name
                    else
                        ast.getText(actual_symbol.name);
                    const current_name = ast.getText(ast.nodes.items[raw].data.string_ref);
                    if (std.mem.eql(u8, baseName(expected_name), baseName(current_name))) {
                        report.preserved_transform_references += 1;
                        continue;
                    }
                }
            }
            report.missing_reference_id += 1;
            if (report.missing_reference_id <= 8) std.debug.print("zntc: post-minify-symbol-detail kind=missing-reference node={d} name={s} actual={d} resolved={d}\n", .{ raw, ast.getText(ast.nodes.items[raw].data.string_ref), actual orelse std.math.maxInt(u32), resolved orelse std.math.maxInt(u32) });
            continue;
        }
        if (!bound_actual_ids.contains(actual.?)) {
            report.dangling_reference_id += 1;
            if (report.dangling_reference_id <= 8) {
                std.debug.print("zntc: post-minify-symbol-detail kind=dangling-reference node={d} name={s} actual={d} resolved={d}\n", .{ raw, ast.getText(ast.nodes.items[raw].data.string_ref), actual.?, resolved.? });
            }
            continue;
        }
        const pair = (@as(u64, actual.?) << 32) | resolved.?;
        if (!binding_pairs.contains(pair)) {
            report.wrong_reference_target += 1;
            if (report.wrong_reference_target <= 8) std.debug.print("zntc: post-minify-symbol-detail kind=wrong-reference-target node={d} name={s} actual={d} resolved={d}\n", .{ raw, ast.getText(ast.nodes.items[raw].data.string_ref), actual.?, resolved.? });
        }
    }
    return report;
}

pub fn printPostMinify(file_path: []const u8, report: PostMinifyReport) void {
    std.debug.print(
        "zntc: symbol-identity-post-minify {s}: bindings={d} references={d} external={d} helpers={d} preserved_transform_refs={d} missing_binding_id={d} missing_reference_id={d} dangling_reference_id={d} wrong_reference_target={d} clean={d}\n",
        .{
            file_path,
            report.bindings_checked,
            report.references_checked,
            report.external_references,
            report.helper_references,
            report.preserved_transform_references,
            report.missing_binding_id,
            report.missing_reference_id,
            report.dangling_reference_id,
            report.wrong_reference_target,
            @intFromBool(report.isClean()),
        },
    );
}

pub fn printExact(file_path: []const u8, report: ExactReport) void {
    printExactNamed("symbol-identity", file_path, report);
}

pub fn printExactPrepass(file_path: []const u8, report: ExactReport, retained_graph: bool) void {
    const graph = if (retained_graph) "retained" else "reanalyzed";
    std.debug.print("zntc: symbol-identity-prepass-mode {s}: semantic_graph={s}\n", .{ file_path, graph });
    printExactNamed("symbol-identity-prepass", file_path, report);
}

fn printExactNamed(name: []const u8, file_path: []const u8, report: ExactReport) void {
    const schema = ExactReport.schemaCounts();
    var ast_structure_buffer: [320]u8 = undefined;
    const ast_structure_counts = std.fmt.bufPrint(
        &ast_structure_buffer,
        "ambiguous_ast_parent={d} cyclic_ast_edges={d} invalid_ast_root={d} invalid_ast_edge={d} invalid_ast_layout={d} invariant_counter_count={d} observation_field_count={d} diagnostic_field_count={d}",
        .{
            report.ambiguous_ast_parent,
            report.cyclic_ast_edges,
            report.invalid_ast_root,
            report.invalid_ast_edge,
            report.invalid_ast_layout,
            schema.invariant_counters,
            schema.observation_fields,
            schema.diagnostic_fields,
        },
    ) catch unreachable;
    var secondary_counts_buffer: [512]u8 = undefined;
    const secondary_counts = std.fmt.bufPrint(
        &secondary_counts_buffer,
        "namespace_iife_params={d} namespace_iife_param_mismatch={d} enum_iife_params={d} enum_iife_param_mismatch={d} helper_symbol_mismatch={d} scope_resolution_mismatch={d} invisible_reference={d} unclassified_reference={d} reference_statement_mismatch={d} reference_scope_statement_alias={d} reference_node_use_alias={d} declaration_scope_mismatch={d} reference_count_mismatch={d} write_count_mismatch={d}",
        .{
            report.namespace_iife_params,
            report.namespace_iife_param_mismatch,
            report.enum_iife_params,
            report.enum_iife_param_mismatch,
            report.helper_symbol_mismatch,
            report.scope_resolution_mismatch,
            report.invisible_reference,
            report.unclassified_reference,
            report.reference_statement_mismatch,
            report.reference_scope_statement_alias,
            report.reference_node_use_alias,
            report.declaration_scope_mismatch,
            report.reference_count_mismatch,
            report.write_count_mismatch,
        },
    ) catch unreachable;
    std.debug.print(
        "zntc: {s} {s}: generated_bindings={d} generated_references={d} external={d} missing_binding={d} invalid_reference_node={d} unreachable_reference={d} {s} shadowed_external_reference={d} invalid_id={d} missing_reference={d} duplicate_reference={d} identity_mismatch={d} binding_scope_mismatch={d} binding_scope_unknown={d} invalid_scope={d} reference_scope_mismatch={d} scope_map_mismatch={d} scope_owner_mismatch={d} scope_owner_parent_mismatch={d} duplicate_scope_owner={d} {s} clean={d} legacy_debt_fingerprint={x}\n",
        .{
            name,
            file_path,
            report.generated_bindings,
            report.generated_references,
            report.external_references,
            report.missing_binding,
            report.invalid_reference_node,
            report.unreachable_reference,
            ast_structure_counts,
            report.shadowed_external_reference,
            report.invalid_id,
            report.missing_reference,
            report.duplicate_reference,
            report.identity_mismatch,
            report.binding_scope_mismatch,
            report.binding_scope_unknown,
            report.invalid_scope,
            report.reference_scope_mismatch,
            report.scope_map_mismatch,
            report.scope_owner_mismatch,
            report.scope_owner_parent_mismatch,
            report.duplicate_scope_owner,
            secondary_counts,
            @intFromBool(report.isClean()),
            report.legacy_debt_fingerprint,
        },
    );
    if (report.first_missing_binding) |finding| printExactFinding(file_path, "missing_binding", finding);
    if (report.first_missing_reference) |finding| printExactFinding(file_path, "missing_reference", finding);
    if (report.first_unclassified_reference) |finding| printExactFinding(file_path, "unclassified_reference", finding);
    if (report.first_shadowed_external_reference) |finding| printExactFinding(file_path, "shadowed_external_reference", finding);
    printExactDiagnostics(file_path, report);
}

/// Report scope ownership against the original analyzed AST, before lowering
/// can move lexical owners into wrappers that preserve their source ScopeIds.
pub fn printSourceScopeOwnerAudit(file_path: []const u8, report: ExactReport) void {
    std.debug.print(
        "zntc: symbol-source-scope-owner {s}: scope_owner_mismatch={d} scope_owner_parent_mismatch={d} duplicate_scope_owner={d}\n",
        .{ file_path, report.scope_owner_mismatch, report.scope_owner_parent_mismatch, report.duplicate_scope_owner },
    );
    if (report.first_scope_owner_mismatch) |finding| printScopeOwnerMismatch(file_path, finding);
    if (report.first_duplicate_scope_owner) |finding| printDuplicateScopeOwner(file_path, finding);
}

fn printExactFinding(file_path: []const u8, issue: []const u8, finding: ExactFinding) void {
    std.debug.print(
        "zntc: symbol-identity-detail {s}: {s} {s}({s}) node={d} span={d}\n",
        .{ file_path, issue, finding.name, @tagName(finding.tag), finding.node_index, finding.span_start },
    );
}

fn optionalScopeKindName(kind: ?ScopeKind) []const u8 {
    return if (kind) |value| @tagName(value) else "none";
}

fn optionalIndexText(buffer: []u8, value: ?u32) []const u8 {
    return if (value) |index| std.fmt.bufPrint(buffer, "{d}", .{index}) catch "format-error" else "none";
}

fn printExactDiagnostics(file_path: []const u8, report: ExactReport) void {
    if (report.first_ambiguous_ast_parent) |finding| {
        var first_parent_buffer: [16]u8 = undefined;
        std.debug.print(
            "zntc: symbol-identity-detail {s}: ambiguous_ast_parent node={d} first_parent={s} additional_parent={d}\n",
            .{
                file_path,
                finding.node_index,
                optionalIndexText(&first_parent_buffer, finding.first_parent),
                finding.additional_parent,
            },
        );
    }
    if (report.first_invalid_ast_edge) |finding| {
        std.debug.print(
            "zntc: symbol-identity-detail {s}: invalid_ast_edge parent={d}:{s} child={d}\n",
            .{ file_path, finding.parent_node_index, @tagName(finding.parent_tag), finding.child_node_index },
        );
    }
    if (report.first_invalid_ast_root) |finding| {
        std.debug.print("zntc: symbol-identity-detail {s}: invalid_ast_root root={d}\n", .{ file_path, finding });
    }
    if (report.first_invalid_ast_layout) |finding| {
        var data_index_buffer: [24]u8 = undefined;
        std.debug.print(
            "zntc: symbol-identity-detail {s}: invalid_ast_layout node={d}:{s} issue={s} data_index={s}\n",
            .{
                file_path,
                finding.node_index,
                @tagName(finding.tag),
                @tagName(finding.issue),
                optionalIndexText(&data_index_buffer, if (finding.data_index) |index| @intCast(index) else null),
            },
        );
    }
    if (report.first_scope_owner_mismatch) |finding| {
        printScopeOwnerMismatch(file_path, finding);
    }
    if (report.first_reference_statement_mismatch) |finding| {
        var actual_buffer: [16]u8 = undefined;
        var expected_buffer: [16]u8 = undefined;
        var first_parent_buffer: [16]u8 = undefined;
        var additional_parent_buffer: [16]u8 = undefined;
        std.debug.print(
            "zntc: symbol-identity-detail {s}: reference_statement_mismatch node={d} stmt_idx={s} expected_stmt_idx={s} first_parent={s} additional_parent={s}\n",
            .{
                file_path,
                finding.node_index,
                optionalIndexText(&actual_buffer, finding.reference_stmt_idx),
                optionalIndexText(&expected_buffer, finding.expected_stmt_idx),
                optionalIndexText(&first_parent_buffer, finding.first_parent),
                optionalIndexText(&additional_parent_buffer, finding.additional_parent),
            },
        );
    }
    if (report.first_reference_scope_statement_alias) |finding| {
        std.debug.print(
            "zntc: symbol-identity-detail {s}: reference_scope_statement_alias node={d} first_parent={d} additional_parent={d} first_statement_list_owner={d} additional_statement_list_owner={d} first_statement_index={d} additional_statement_index={d}\n",
            .{
                file_path,
                finding.node_index,
                finding.first_parent,
                finding.additional_parent,
                finding.first_owner,
                finding.additional_owner,
                finding.first_statement_index,
                finding.additional_statement_index,
            },
        );
    }
    if (report.first_reference_node_use_alias) |finding| {
        std.debug.print(
            "zntc: symbol-identity-detail {s}: reference_node_use_alias node={d}:{s}({s}@{d}) first_parent={d}:{s} additional_parent={d}:{s} additional_uses={d}\n",
            .{
                file_path,
                finding.node_index,
                @tagName(finding.tag),
                finding.name,
                finding.span_start,
                finding.first_parent,
                @tagName(finding.first_parent_tag),
                finding.additional_parent,
                @tagName(finding.additional_parent_tag),
                finding.additional_uses,
            },
        );
    }
    if (report.first_duplicate_scope_owner) |finding| {
        printDuplicateScopeOwner(file_path, finding);
    }
    if (report.first_scope_map_mismatch) |finding| {
        var scope_buffer: [16]u8 = undefined;
        var symbol_buffer: [16]u8 = undefined;
        std.debug.print(
            "zntc: symbol-identity-detail {s}: scope_map issue={s} scope={s} symbol={s} name={s}\n",
            .{
                file_path,
                finding.issue,
                optionalIndexText(&scope_buffer, finding.scope_id),
                optionalIndexText(&symbol_buffer, finding.symbol_id),
                finding.name orelse "none",
            },
        );
    }
}

fn printDuplicateScopeOwner(file_path: []const u8, finding: ScopeOwnerFinding) void {
    var scope_buffer: [16]u8 = undefined;
    var first_owner_buffer: [16]u8 = undefined;
    std.debug.print(
        "zntc: symbol-identity-detail {s}: duplicate_scope_owner node={d}:{s} scope={s} first_owner={s}\n",
        .{
            file_path,
            finding.node_index,
            @tagName(finding.tag),
            optionalIndexText(&scope_buffer, finding.scope_id),
            optionalIndexText(&first_owner_buffer, finding.first_owner_node_index),
        },
    );
}

fn printScopeOwnerMismatch(file_path: []const u8, finding: ScopeOwnerFinding) void {
    var scope_buffer: [16]u8 = undefined;
    var expected_parent_buffer: [16]u8 = undefined;
    var actual_parent_buffer: [16]u8 = undefined;
    std.debug.print(
        "zntc: symbol-identity-detail {s}: scope_owner issue={s} node={d} tag={s} scope={s} expected={s} actual={s} expected_parent={s} actual_parent={s}\n",
        .{
            file_path,
            finding.issue,
            finding.node_index,
            @tagName(finding.tag),
            optionalIndexText(&scope_buffer, finding.scope_id),
            optionalScopeKindName(finding.expected_kind),
            optionalScopeKindName(finding.actual_kind),
            optionalIndexText(&expected_parent_buffer, finding.expected_parent_scope_id),
            optionalIndexText(&actual_parent_buffer, finding.actual_parent_scope_id),
        },
    );
}

/// Diagnostic inventory of emitted identifiers. An unbound generated read may
/// be a new global, so only bindings are definite missing-symbol findings.
/// This never infers or assigns a SymbolId from identifier text.
pub const StrictStatus = enum {
    bound,
    external,
    missing_binding,
    unclassified,
    invalid_id,
    name_mismatch,
    missing_reference,
    identity_mismatch,
    invalid_scope,
    scope_unknown,
    scope_ambiguous,
    scope_mismatch,
    invisible_reference,
    duplicate_reference,
};
pub const StrictFinding = struct {
    node: u32,
    name: []const u8,
    tag: Node.Tag,
    status: StrictStatus,
    marked_synthetic: bool,
    symbol_id: ?u32 = null,
    reference_symbol_id: ?u32 = null,
    expected_scope_id: ?u32 = null,
    symbol_scope_id: ?u32 = null,
    symbol_origin_scope_id: ?u32 = null,
    reference_scope_id: ?u32 = null,
};
/// Node-index provenance used to prove that a generated unbound reference is
/// intentionally external. A name-only unresolved-global set is not enough:
/// another generated identifier with the same spelling may need a SymbolId.
pub const StrictExternalEvidence = struct {
    unresolved_reference_nodes: *const std.AutoHashMapUnmanaged(u32, void),
    explicit_global_reference_nodes: *const std.AutoHashMapUnmanaged(u32, void),
    reference_origin_map: *const std.AutoHashMapUnmanaged(u32, u32),
};

pub const OrphanSyntheticSymbol = struct {
    symbol_id: u32,
    name: []const u8,
    kind: SymbolKind,
    scope_id: ScopeId,
};
pub const StrictReport = struct {
    counts: [std.meta.fields(StrictStatus).len]usize = @splat(0),
    marked_synthetic: usize = 0,
    orphan_symbols: usize = 0,
    cyclic_ast_edges: usize = 0,
    findings: std.ArrayList(StrictFinding) = .empty,
    orphan_symbol_findings: std.ArrayList(OrphanSyntheticSymbol) = .empty,

    pub fn deinit(self: *StrictReport, allocator: std.mem.Allocator) void {
        self.findings.deinit(allocator);
        self.orphan_symbol_findings.deinit(allocator);
    }

    /// Keep aggregate counters and emitted diagnostic details tied together.
    /// The checker updates both while walking the AST; a drift here would let
    /// a zeroed counter hide a failing finding (or hide a dropped finding).
    pub fn isConsistent(self: *const StrictReport) bool {
        var observed_counts: [std.meta.fields(StrictStatus).len]usize = @splat(0);
        var observed_marked_synthetic: usize = 0;
        for (self.findings.items) |finding| {
            observed_counts[@intFromEnum(finding.status)] += 1;
            if (finding.marked_synthetic) observed_marked_synthetic += 1;
        }
        for (observed_counts, self.counts) |observed, reported| {
            if (observed != reported) return false;
        }
        return self.cyclic_ast_edges == 0 and
            observed_marked_synthetic == self.marked_synthetic and
            self.orphan_symbols == self.orphan_symbol_findings.items.len;
    }

    /// True only when every generated runtime identifier has exact SymbolId
    /// and ScopeId evidence, or exact node-index evidence that an unbound
    /// reference remains external.
    pub fn hasCompleteExactCoverage(self: *const StrictReport) bool {
        if (!self.isConsistent()) return false;
        if (self.orphan_symbols != 0) return false;
        for (self.counts, 0..) |count, status| {
            if (status != @intFromEnum(StrictStatus.bound) and
                status != @intFromEnum(StrictStatus.external) and count != 0) return false;
        }
        return true;
    }

    /// Identity completeness is gated separately from raw emitted-scope traces.
    /// Lowering can make a binding's raw AST trace disagree with its semantic
    /// scope; ExactReport owns those transform-aware binding ScopeId
    /// invariants. A reference scope mismatch has no such exception: it means
    /// the reference was recorded under a different output owner and fails
    /// closed. Unknown/new statuses still fail closed.
    pub fn hasCompleteSymbolIdentity(self: *const StrictReport) bool {
        if (!self.isConsistent()) return false;
        if (self.orphan_symbols != 0) return false;
        for (self.findings.items) |finding| {
            if (finding.status == .scope_mismatch and finding.tag != .binding_identifier) return false;
        }
        for (self.counts, 0..) |count, status| {
            if (status != @intFromEnum(StrictStatus.bound) and
                status != @intFromEnum(StrictStatus.external) and
                status != @intFromEnum(StrictStatus.scope_mismatch) and count != 0) return false;
        }
        return true;
    }
};

const StrictCtx = struct {
    allocator: std.mem.Allocator,
    ast: *const Ast,
    parser_node_count: u32,
    symbol_ids: []const ?u32,
    symbols: []const Symbol,
    scopes: []const Scope,
    node_scopes: *const std.AutoHashMapUnmanaged(u32, ScopeTrace),
    parent_traces: *const std.AutoHashMapUnmanaged(u32, ParentTrace),
    references: *const std.AutoHashMapUnmanaged(u32, ReferenceEvidence),
    synthetic: ?*const std.AutoHashMapUnmanaged(u32, void),
    external_evidence: ?StrictExternalEvidence,
    reachable_binding_symbols: *std.AutoHashMapUnmanaged(u32, void),
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
        const trace = self.node_scopes.get(raw);
        const reference = self.references.get(raw);
        const status = self.classify(raw, node, name, sid, trace, reference);
        self.report.counts[@intFromEnum(status)] += 1;
        if (marked) self.report.marked_synthetic += 1;
        self.report.findings.append(self.allocator, .{
            .node = raw,
            .name = name,
            .tag = node.tag,
            .status = status,
            .marked_synthetic = marked,
            .symbol_id = sid,
            .reference_symbol_id = if (reference) |e| @intFromEnum(e.reference.symbol_id) else null,
            .expected_scope_id = if (trace) |s| s.scope_id else null,
            .symbol_scope_id = if (sid) |id| if (id < self.symbols.len) @intFromEnum(self.symbols[id].scope_id) else null else null,
            .symbol_origin_scope_id = if (sid) |id| if (id < self.symbols.len) @intFromEnum(self.symbols[id].origin_scope) else null else null,
            .reference_scope_id = if (reference) |e| @intFromEnum(e.reference.scope_id) else null,
        }) catch {
            self.oom = true;
        };
    }

    fn classify(
        self: *const StrictCtx,
        raw: u32,
        node: Node,
        name: []const u8,
        sid: ?u32,
        trace: ?ScopeTrace,
        reference: ?ReferenceEvidence,
    ) StrictStatus {
        const id = sid orelse {
            if (node.tag == .binding_identifier) return .missing_binding;
            if (self.external_evidence) |evidence| {
                if (hasExactExternalEvidence(
                    self.ast,
                    raw,
                    self.parser_node_count,
                    evidence.unresolved_reference_nodes,
                    evidence.explicit_global_reference_nodes,
                    evidence.reference_origin_map,
                )) return .external;
            }
            // No exact source/global provenance: spelling alone cannot prove
            // that this generated reference intentionally denotes a global.
            return .unclassified;
        };
        if (id >= self.symbols.len) return .invalid_id;
        const symbol = self.symbols[id];
        const symbol_name = if (symbol.synthetic_name.len > 0)
            symbol.synthetic_name
        else
            self.ast.getText(symbol.name);
        if (!std.mem.eql(u8, baseName(name), baseName(symbol_name))) return .name_mismatch;

        if (node.tag == .binding_identifier) {
            if (!validScope(symbol.scope_id, self.scopes) or !validScope(symbol.origin_scope, self.scopes)) return .invalid_scope;
            const expected = trace orelse return .scope_unknown;
            if (expected.ambiguous) return .scope_ambiguous;
            if (self.parent_traces.get(raw)) |parents| {
                if (parents.ambiguous) return .scope_ambiguous;
            }
            if (!expected.valid) return .invalid_scope;
            const lexical_scope = expected.scope_id orelse return .scope_unknown;
            if (!validScope(@enumFromInt(lexical_scope), self.scopes)) return .invalid_scope;
            // Lowering a lexical `let`/`const` declaration to emitted `var`
            // syntax does not change that source binding's semantic scope.
            // The transformer keeps those SymbolIds in their lexical scopes
            // and renames colliding output names separately. Resource helpers
            // are the exception: their synthetic `_using` bindings are
            // deliberately stored in the nearest var scope.
            const is_output_var = symbol.kind == .variable_var or
                (symbol.kind == .variable_const and std.mem.startsWith(u8, symbol.synthetic_name, "_using"));
            const declaration_scope = if (is_output_var)
                nearestVarScope(lexical_scope, self.scopes) orelse return .invalid_scope
            else
                lexical_scope;
            if (@intFromEnum(symbol.scope_id) != declaration_scope) return .scope_mismatch;
            // scope_id is the binding's current output storage scope.
            // origin_scope is source provenance and may name a detached
            // source scope after lowering moves the binding into generated
            // output. It must remain valid, but is not the output AST scope.
            return .bound;
        }

        const evidence = reference orelse return .missing_reference;
        if (evidence.count != 1) return .duplicate_reference;
        if (@intFromEnum(evidence.reference.symbol_id) != id) return .identity_mismatch;
        if (!validScope(evidence.reference.scope_id, self.scopes) or !validScope(symbol.scope_id, self.scopes)) return .invalid_scope;
        const expected = trace orelse return .scope_unknown;
        if (expected.ambiguous) return .scope_ambiguous;
        if (!expected.valid) return .invalid_scope;
        const expected_scope = expected.scope_id orelse return .scope_unknown;
        if (@intFromEnum(evidence.reference.scope_id) != expected_scope) return .scope_mismatch;
        if (!visibleFrom(symbol.scope_id, evidence.reference.scope_id, self.scopes)) return .invisible_reference;
        return .bound;
    }
};

const ScopeTrace = struct {
    scope_id: ?u32 = null,
    valid: bool = true,
    ambiguous: bool = false,
};

const ParentTrace = struct {
    parent: u32,
    ambiguous: bool = false,
};

const ReferenceEvidence = struct {
    reference: Reference,
    count: u8 = 1,
};

const ParentVisit = struct {
    node: NodeIndex,
    parent: ?u32 = null,
};

fn collectParentTraces(
    allocator: std.mem.Allocator,
    ast: *const Ast,
    root: NodeIndex,
) std.mem.Allocator.Error!std.AutoHashMapUnmanaged(u32, ParentTrace) {
    var traces: std.AutoHashMapUnmanaged(u32, ParentTrace) = .empty;
    errdefer traces.deinit(allocator);
    var visited: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer visited.deinit(allocator);
    var stack: std.ArrayList(ParentVisit) = .empty;
    defer stack.deinit(allocator);
    var children: std.ArrayList(NodeIndex) = .empty;
    defer children.deinit(allocator);
    try stack.append(allocator, .{ .node = root });
    while (stack.pop()) |parent_visit| {
        if (parent_visit.node.isNone() or @as(usize, @intFromEnum(parent_visit.node)) >= ast.nodes.items.len) continue;
        const raw = @intFromEnum(parent_visit.node);
        if (parent_visit.parent) |parent| {
            const gop = try traces.getOrPut(allocator, raw);
            if (gop.found_existing) {
                if (gop.value_ptr.parent != parent) gop.value_ptr.ambiguous = true;
            } else {
                gop.value_ptr.* = .{ .parent = parent };
            }
        }
        const visited_result = try visited.getOrPut(allocator, raw);
        if (visited_result.found_existing) continue;
        try ast_walk.collectChildrenInto(ast, ast.getNode(parent_visit.node), &children, allocator);
        for (children.items) |child| try stack.append(allocator, .{ .node = child, .parent = raw });
    }
    return traces;
}

const ScopePath = struct {
    scope_id: ?u32 = null,
    valid: bool = true,
};

const ScopeVisit = struct {
    node: NodeIndex,
    incoming: ScopePath,
};

const ScopeVisitKey = struct {
    node: u32,
    scope_id: ?u32,
    valid: bool,
};

fn validScope(scope: ScopeId, scopes: []const Scope) bool {
    return !scope.isNone() and @as(usize, scope.toIndex()) < scopes.len;
}

fn nearestVarScope(start: u32, scopes: []const Scope) ?u32 {
    var current: ScopeId = @enumFromInt(start);
    var hops: usize = 0;
    while (!current.isNone() and hops < scopes.len) : (hops += 1) {
        const index = current.toIndex();
        if (@as(usize, index) >= scopes.len) return null;
        if (scopes[index].kind.isVarScope()) return index;
        current = scopes[index].parent;
    }
    return null;
}

fn visibleFrom(binding: ScopeId, reference: ScopeId, scopes: []const Scope) bool {
    if (!validScope(binding, scopes) or !validScope(reference, scopes)) return false;
    var current = reference;
    var hops: usize = 0;
    while (hops < scopes.len) : (hops += 1) {
        if (current == binding) return true;
        const index = current.toIndex();
        if (@as(usize, index) >= scopes.len) return false;
        current = scopes[index].parent;
        if (current.isNone()) return false;
    }
    return false;
}

fn collectScopeTraces(
    allocator: std.mem.Allocator,
    ast: *const Ast,
    root: NodeIndex,
    scopes: []const Scope,
    scope_owner_map: *const std.AutoHashMapUnmanaged(u32, u32),
) std.mem.Allocator.Error!std.AutoHashMapUnmanaged(u32, ScopeTrace) {
    var traces: std.AutoHashMapUnmanaged(u32, ScopeTrace) = .empty;
    errdefer traces.deinit(allocator);
    var visited: std.AutoHashMapUnmanaged(ScopeVisitKey, void) = .empty;
    defer visited.deinit(allocator);
    var stack: std.ArrayList(ScopeVisit) = .empty;
    defer stack.deinit(allocator);
    var children: std.ArrayList(NodeIndex) = .empty;
    defer children.deinit(allocator);
    var root_scope: ?u32 = null;
    var multiple_root_scopes = false;
    for (scopes, 0..) |scope, index| {
        if (!scope.parent.isNone()) continue;
        if (root_scope != null) multiple_root_scopes = true else root_scope = @intCast(index);
    }
    const initial_scope: ScopePath = if (multiple_root_scopes)
        .{ .valid = false }
    else if (root_scope) |scope|
        .{ .scope_id = scope }
    else
        .{ .valid = false };
    try stack.append(allocator, .{ .node = root, .incoming = initial_scope });
    while (stack.pop()) |scope_visit| {
        if (scope_visit.node.isNone() or @as(usize, @intFromEnum(scope_visit.node)) >= ast.nodes.items.len) continue;
        const raw = @intFromEnum(scope_visit.node);
        var effective = scope_visit.incoming;
        if (scope_owner_map.get(raw)) |owner_scope| {
            if (@as(usize, owner_scope) >= scopes.len) {
                effective = .{ .valid = false };
            } else {
                effective = .{ .scope_id = owner_scope, .valid = true };
            }
        }
        const key: ScopeVisitKey = .{ .node = raw, .scope_id = effective.scope_id, .valid = effective.valid };
        const visit_result = try visited.getOrPut(allocator, key);
        if (visit_result.found_existing) continue;
        if (traces.getPtr(raw)) |trace| {
            if (trace.scope_id != effective.scope_id or trace.valid != effective.valid) trace.ambiguous = true;
        } else {
            try traces.put(allocator, raw, .{ .scope_id = effective.scope_id, .valid = effective.valid });
        }
        const parent = ast.getNode(scope_visit.node);
        try ast_walk.collectChildrenInto(ast, parent, &children, allocator);
        var index = children.items.len;
        while (index > 0) {
            index -= 1;
            const child = children.items[index];
            // Some owner nodes enter their body scope after evaluating
            // selected children: switch discriminants, method keys and
            // decorators, and declaration names all belong to the enclosing
            // scope. Keep strict traces aligned with the analyzer's order.
            const child_scope = if (functionExpressionNameScope(
                ast,
                scope_owner_map,
                scopes,
                raw,
                @intFromEnum(child),
            )) |name_scope|
                ScopePath{ .scope_id = name_scope, .valid = true }
            else if (childSkipsScopeOwner(ast, raw, @intFromEnum(child)))
                scope_visit.incoming
            else
                effective;
            try stack.append(allocator, .{ .node = child, .incoming = child_scope });
        }
    }
    return traces;
}

fn collectReferenceEvidence(
    allocator: std.mem.Allocator,
    references: []const Reference,
) std.mem.Allocator.Error!std.AutoHashMapUnmanaged(u32, ReferenceEvidence) {
    var result: std.AutoHashMapUnmanaged(u32, ReferenceEvidence) = .empty;
    errdefer result.deinit(allocator);
    for (references) |reference| {
        if (reference.node_index.isNone() or reference.flags.declare) continue;
        const raw = @intFromEnum(reference.node_index);
        if (result.getPtr(raw)) |evidence| {
            evidence.count = if (evidence.count == std.math.maxInt(u8)) evidence.count else evidence.count + 1;
        } else {
            try result.put(allocator, raw, .{ .reference = reference });
        }
    }
    return result;
}

fn strictBindingVisit(ctx: *StrictCtx, idx: NodeIndex, node: Node) ast_walk.WalkAction {
    if (reference_walk.isTypeOnly(node.tag)) return .skip_children;
    if (node.tag == .ts_module_declaration and node.data.binary.flags == 1) return .skip_children;
    if (node.tag == .binding_identifier) {
        const raw = @intFromEnum(idx);
        if (raw < ctx.symbol_ids.len) {
            if (ctx.symbol_ids[raw]) |id| {
                if (id < ctx.symbols.len) ctx.reachable_binding_symbols.put(ctx.allocator, id, {}) catch {
                    ctx.oom = true;
                };
            }
        }
        ctx.add(idx, node);
    }
    return .descend;
}

pub fn checkStrict(
    allocator: std.mem.Allocator,
    ast: *const Ast,
    root: NodeIndex,
    parser_node_count: u32,
    symbol_ids: []const ?u32,
    symbols: []const Symbol,
    scopes: []const Scope,
    scope_owner_map: *const std.AutoHashMapUnmanaged(u32, u32),
    references: []const Reference,
    synthetic: ?*const std.AutoHashMapUnmanaged(u32, void),
    // Kept as a diagnostic hint input for callers; name-only global sets are
    // intentionally not sufficient to classify a generated reference.
    _unresolved_globals: *const std.StringHashMapUnmanaged(void),
) std.mem.Allocator.Error!StrictReport {
    // Kept for caller compatibility; its name-only entries are not exact
    // evidence for a particular generated reference NodeIndex.
    _ = _unresolved_globals;
    return checkStrictImpl(
        allocator,
        ast,
        root,
        parser_node_count,
        symbol_ids,
        symbols,
        scopes,
        scope_owner_map,
        references,
        synthetic,
        null,
    );
}

pub fn checkStrictWithExactExternalEvidence(
    allocator: std.mem.Allocator,
    ast: *const Ast,
    root: NodeIndex,
    parser_node_count: u32,
    symbol_ids: []const ?u32,
    symbols: []const Symbol,
    scopes: []const Scope,
    scope_owner_map: *const std.AutoHashMapUnmanaged(u32, u32),
    references: []const Reference,
    synthetic: ?*const std.AutoHashMapUnmanaged(u32, void),
    external_evidence: StrictExternalEvidence,
) std.mem.Allocator.Error!StrictReport {
    return checkStrictImpl(
        allocator,
        ast,
        root,
        parser_node_count,
        symbol_ids,
        symbols,
        scopes,
        scope_owner_map,
        references,
        synthetic,
        external_evidence,
    );
}

fn checkStrictImpl(
    allocator: std.mem.Allocator,
    ast: *const Ast,
    root: NodeIndex,
    parser_node_count: u32,
    symbol_ids: []const ?u32,
    symbols: []const Symbol,
    scopes: []const Scope,
    scope_owner_map: *const std.AutoHashMapUnmanaged(u32, u32),
    references: []const Reference,
    synthetic: ?*const std.AutoHashMapUnmanaged(u32, void),
    external_evidence: ?StrictExternalEvidence,
) std.mem.Allocator.Error!StrictReport {
    var report: StrictReport = .{};
    errdefer report.deinit(allocator);
    report.cyclic_ast_edges = try countCyclicAstEdges(allocator, ast, root);
    var node_scopes = try collectScopeTraces(allocator, ast, root, scopes, scope_owner_map);
    defer node_scopes.deinit(allocator);
    var parent_traces = try collectParentTraces(allocator, ast, root);
    defer parent_traces.deinit(allocator);
    var reference_evidence = try collectReferenceEvidence(allocator, references);
    defer reference_evidence.deinit(allocator);
    var reachable_binding_symbols: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer reachable_binding_symbols.deinit(allocator);
    var ctx: StrictCtx = .{
        .allocator = allocator,
        .ast = ast,
        .parser_node_count = parser_node_count,
        .symbol_ids = symbol_ids,
        .symbols = symbols,
        .scopes = scopes,
        .node_scopes = &node_scopes,
        .parent_traces = &parent_traces,
        .references = &reference_evidence,
        .synthetic = synthetic,
        .external_evidence = external_evidence,
        .reachable_binding_symbols = &reachable_binding_symbols,
        .report = &report,
    };
    defer ctx.seen.deinit(allocator);
    if (report.cyclic_ast_edges == 0) {
        try ast_walk.walkPreorderIterative(allocator, ast, root, &ctx, strictBindingVisit);
        const refs = try reference_walk.collectIdentifierReferences(allocator, ast, root);
        defer allocator.free(refs);
        for (refs) |idx| ctx.add(idx, ast.getNode(idx));
    }
    if (ctx.oom) return error.OutOfMemory;

    // Identifier coverage alone misses generated Symbol rows whose owner
    // node was discarded before output. Count these independently: such rows
    // can still poison scope maps and later name allocation even though every
    // reachable identifier has exact identity.
    for (symbols, 0..) |symbol, raw_id| {
        const has_generated_name_provenance = symbol.synthetic_name.len > 0 or
            symbol.synthetic_kind != null or
            symbol.name.start & Ast.STRING_TABLE_BIT != 0;
        if (!has_generated_name_provenance or raw_id > std.math.maxInt(u32)) continue;
        // Virtual namespace/enum IIFE parameters have no emitted AST binding
        // node; checkExact validates them against reachable owner scopes.
        if (symbol.synthetic_kind == .namespace_iife_parameter or symbol.synthetic_kind == .enum_iife_parameter or
            symbol.synthetic_kind == .enum_iife_member or symbol.synthetic_kind == .runtime_helper_preamble) continue;
        // Expression `export default` keeps a synthetic reachability facade
        // even when it has no emitted local binding.
        if (symbol.decl_flags.is_default_export and std.mem.eql(u8, exactSymbolName(ast, &symbol), "_default")) continue;
        const id: u32 = @intCast(raw_id);
        if (reachable_binding_symbols.contains(id)) continue;
        report.orphan_symbols += 1;
        try report.orphan_symbol_findings.append(allocator, .{
            .symbol_id = id,
            .name = symbol.synthetic_name,
            .kind = symbol.kind,
            .scope_id = symbol.scope_id,
        });
    }
    return report;
}

pub fn printStrict(file_path: []const u8, report: *const StrictReport) void {
    std.debug.print(
        "zntc: synthetic-coverage {s}: bound={d} external={d} missing_binding={d} unclassified={d} invalid_id={d} name_mismatch={d} missing_reference={d} identity_mismatch={d} invalid_scope={d} scope_unknown={d} scope_ambiguous={d} scope_mismatch={d} invisible_reference={d} duplicate_reference={d} orphan_symbols={d} cyclic_ast_edges={d} marked_synthetic={d} consistent={d} symbol_identity_complete={d}\n",
        .{ file_path, report.counts[@intFromEnum(StrictStatus.bound)], report.counts[@intFromEnum(StrictStatus.external)], report.counts[@intFromEnum(StrictStatus.missing_binding)], report.counts[@intFromEnum(StrictStatus.unclassified)], report.counts[@intFromEnum(StrictStatus.invalid_id)], report.counts[@intFromEnum(StrictStatus.name_mismatch)], report.counts[@intFromEnum(StrictStatus.missing_reference)], report.counts[@intFromEnum(StrictStatus.identity_mismatch)], report.counts[@intFromEnum(StrictStatus.invalid_scope)], report.counts[@intFromEnum(StrictStatus.scope_unknown)], report.counts[@intFromEnum(StrictStatus.scope_ambiguous)], report.counts[@intFromEnum(StrictStatus.scope_mismatch)], report.counts[@intFromEnum(StrictStatus.invisible_reference)], report.counts[@intFromEnum(StrictStatus.duplicate_reference)], report.orphan_symbols, report.cyclic_ast_edges, report.marked_synthetic, @intFromBool(report.isConsistent()), @intFromBool(report.hasCompleteSymbolIdentity()) },
    );
    for (report.orphan_symbol_findings.items[0..@min(report.orphan_symbol_findings.items.len, 8)]) |finding| {
        std.debug.print("  synthetic-coverage orphan_symbol id={d} name={s} kind={s} scope={d}\n", .{
            finding.symbol_id,
            finding.name,
            @tagName(finding.kind),
            @intFromEnum(finding.scope_id),
        });
    }
    var printed: [std.meta.fields(StrictStatus).len]usize = @splat(0);
    for (report.findings.items) |finding| {
        if (finding.status == .bound or finding.status == .external) continue;
        const group = @intFromEnum(finding.status);
        if (printed[group] == 8) continue;
        std.debug.print("  synthetic-coverage {s} node={d} {s}({s}) marked={any} sid={any} ref_sid={any} scope={any} symbol_scope={any} origin_scope={any} ref_scope={any}\n", .{
            @tagName(finding.status),   finding.node,                finding.name,              @tagName(finding.tag),   finding.marked_synthetic,
            finding.symbol_id,          finding.reference_symbol_id, finding.expected_scope_id, finding.symbol_scope_id, finding.symbol_origin_scope_id,
            finding.reference_scope_id,
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

test "exact coverage is not clean when a generated binding scope is unknown" {
    var report: ExactReport = .{};
    try std.testing.expect(report.isClean());
    report.binding_scope_unknown = 1;
    try std.testing.expect(!report.isClean());
}

test "exact coverage cleanliness fails closed for every invariant counter" {
    inline for (std.meta.fields(ExactReport)) |field| {
        if (comptime ExactReport.isObservationField(field.name) or ExactReport.isDiagnosticField(field.name)) continue;
        var report: ExactReport = .{};
        @field(report, field.name) = 1;
        try std.testing.expect(!report.isClean());
    }

    const observations: ExactReport = .{
        .generated_bindings = 1,
        .generated_references = 1,
        .external_references = 1,
        .namespace_iife_params = 1,
        .enum_iife_params = 1,
        .legacy_debt_fingerprint = 0x1234,
    };
    try std.testing.expect(observations.isClean());
}

test "exact coverage diagnostic findings cannot disagree with a clean report" {
    const identifier_reference_tag: Node.Tag = .identifier_reference;
    const finding: ExactFinding = .{
        .name = "x",
        .tag = identifier_reference_tag,
        .node_index = 1,
        .span_start = 0,
    };
    const reports = [_]ExactReport{
        .{ .first_missing_binding = finding },
        .{ .first_missing_reference = finding },
        .{ .first_unclassified_reference = finding },
        .{ .first_scope_owner_mismatch = .{ .node_index = 1, .tag = .block_statement, .issue = "test" } },
        .{ .first_duplicate_scope_owner = .{ .node_index = 2, .tag = .block_statement, .issue = "test", .first_owner_node_index = 1 } },
        .{ .first_scope_map_mismatch = .{ .issue = "test" } },
        .{ .first_ambiguous_ast_parent = .{ .node_index = 1, .first_parent = 2, .additional_parent = 3 } },
        .{ .first_invalid_ast_root = 9 },
        .{ .first_invalid_ast_edge = .{ .parent_node_index = 1, .parent_tag = .program, .child_node_index = 9 } },
        .{ .first_invalid_ast_layout = .{ .node_index = 1, .tag = .program, .issue = .list_range, .data_index = 9 } },
        .{ .first_shadowed_external_reference = finding },
    };
    for (reports) |report| try std.testing.expect(!report.isClean());
}

test "post-minify coverage cleanliness includes every invariant counter" {
    inline for (std.meta.fields(PostMinifyReport)) |field| {
        if (comptime PostMinifyReport.isObservationField(field.name)) continue;
        var report: PostMinifyReport = .{};
        @field(report, field.name) = 1;
        try std.testing.expect(!report.isClean());
    }

    const observations: PostMinifyReport = .{
        .bindings_checked = 1,
        .references_checked = 1,
        .external_references = 1,
        .helper_references = 1,
        .preserved_transform_references = 1,
    };
    try std.testing.expect(observations.isClean());
}

test "exact helper coverage rejects an unbound generated helper reference" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ast = Ast.init(allocator, "");
    defer ast.deinit();
    const name = try ast.addString("__helper");
    const helper_ref = try makeTestIdentifierNode(&ast, .identifier_reference, name);
    const root = try ast.addNode(.{
        .tag = .block_statement,
        .span = .EMPTY,
        .data = .{ .list = try ast.addNodeList(&.{helper_ref}) },
    });
    const scopes = [_]Scope{
        .{ .parent = .none, .kind = .block, .is_strict = false },
    };
    const scope_maps = [_]std.StringHashMapUnmanaged(usize){.empty};
    const symbol_ids = [_]?u32{null};
    const helper_refs = [_]u32{@intFromEnum(helper_ref)};
    var scope_owner_map: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer scope_owner_map.deinit(allocator);
    try scope_owner_map.put(allocator, @intFromEnum(root), 0);
    const helper_scope_map: std.StringHashMapUnmanaged(usize) = .empty;
    const unresolved: std.AutoHashMapUnmanaged(u32, void) = .empty;
    const explicit_globals: std.AutoHashMapUnmanaged(u32, void) = .empty;
    const origins: std.AutoHashMapUnmanaged(u32, u32) = .empty;

    const report = try checkExact(
        allocator,
        &ast,
        root,
        0,
        &symbol_ids,
        &.{},
        &scopes,
        &scope_maps,
        &scope_owner_map,
        &.{},
        &helper_refs,
        &helper_scope_map,
        &unresolved,
        &explicit_globals,
        &origins,
    );
    try std.testing.expectEqual(@as(usize, 1), report.helper_symbol_mismatch);
    try std.testing.expect(!report.isClean());
}

test "exact helper coverage rejects an ancestor scope on a nested helper reference" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ast = Ast.init(allocator, "");
    defer ast.deinit();
    const name = try ast.addString("__helper");
    const helper_ref = try makeTestIdentifierNode(&ast, .identifier_reference, name);
    const block = try ast.addNode(.{
        .tag = .block_statement,
        .span = name,
        .data = .{ .list = try ast.addNodeList(&.{helper_ref}) },
    });
    const root = try ast.addNode(.{
        .tag = .program,
        .span = name,
        .data = .{ .list = try ast.addNodeList(&.{block}) },
    });

    const global_scope: ScopeId = @enumFromInt(0);
    const block_scope: ScopeId = @enumFromInt(1);
    const scopes = [_]Scope{
        .{ .parent = .none, .kind = .global, .is_strict = false },
        .{ .parent = global_scope, .kind = .block, .is_strict = false },
    };
    var global_scope_map: std.StringHashMapUnmanaged(usize) = .empty;
    defer global_scope_map.deinit(allocator);
    try global_scope_map.put(allocator, "__helper", 0);
    const scope_maps = [_]std.StringHashMapUnmanaged(usize){ global_scope_map, .empty };
    const symbols = [_]Symbol{.{
        .name = name,
        .scope_id = global_scope,
        .kind = .import_binding,
        .declaration_span = name,
        .reference_count = 1,
    }};
    const symbol_ids = [_]?u32{0};
    // The helper is visible from the block, so storing its use at the
    // ancestor scope passes visibility and helper identity checks. Its exact
    // use scope must still be the block that owns the reference node.
    var references = [_]Reference{.{
        .node_index = helper_ref,
        .scope_id = block_scope,
        .symbol_id = @enumFromInt(0),
        .flags = .{ .read = true },
    }};
    const helper_refs = [_]u32{@intFromEnum(helper_ref)};
    var scope_owner_map: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer scope_owner_map.deinit(allocator);
    try scope_owner_map.put(allocator, @intFromEnum(root), @intFromEnum(global_scope));
    try scope_owner_map.put(allocator, @intFromEnum(block), @intFromEnum(block_scope));
    var helper_scope_map: std.StringHashMapUnmanaged(usize) = .empty;
    defer helper_scope_map.deinit(allocator);
    try helper_scope_map.put(allocator, "__helper", 0);
    const unresolved: std.AutoHashMapUnmanaged(u32, void) = .empty;
    const explicit_globals: std.AutoHashMapUnmanaged(u32, void) = .empty;
    const origins: std.AutoHashMapUnmanaged(u32, u32) = .empty;

    const valid = try checkExact(
        allocator,
        &ast,
        root,
        0,
        &symbol_ids,
        &symbols,
        &scopes,
        &scope_maps,
        &scope_owner_map,
        &references,
        &helper_refs,
        &helper_scope_map,
        &unresolved,
        &explicit_globals,
        &origins,
    );
    try std.testing.expect(valid.isClean());

    references[0].scope_id = global_scope;
    const report = try checkExact(
        allocator,
        &ast,
        root,
        0,
        &symbol_ids,
        &symbols,
        &scopes,
        &scope_maps,
        &scope_owner_map,
        &references,
        &helper_refs,
        &helper_scope_map,
        &unresolved,
        &explicit_globals,
        &origins,
    );
    try std.testing.expectEqual(@as(usize, 1), report.reference_scope_mismatch);
    try std.testing.expectEqual(@as(usize, 0), report.invisible_reference);
    try std.testing.expectEqual(@as(usize, 0), report.helper_symbol_mismatch);
    try std.testing.expect(!report.isClean());
}

/// Inline white-box tests need raw identifier AST nodes; production transforms
/// must use the classified symbol-aware constructors.
fn makeTestIdentifierNode(ast: *Ast, tag: Node.Tag, span: Span) !NodeIndex {
    return ast.addNode(.{ .tag = tag, .span = span, .data = .{ .string_ref = span } });
}

test "exact identity audit catches a same-name reference bound to the wrong scope" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ast = Ast.init(allocator, "");
    defer ast.deinit();
    const name = try ast.addString("x");
    const ref_node = try makeTestIdentifierNode(&ast, .identifier_reference, name);
    const list = try ast.addNodeList(&.{ref_node});
    const root = try ast.addNode(.{
        .tag = .block_statement,
        .span = name,
        .data = .{ .list = list },
    });

    const outer_scope: ScopeId = @enumFromInt(0);
    const inner_scope: ScopeId = @enumFromInt(1);
    const scopes = [_]Scope{
        .{ .parent = .none, .kind = .global, .is_strict = false },
        .{ .parent = outer_scope, .kind = .block, .is_strict = false },
    };
    var outer_names: std.StringHashMapUnmanaged(usize) = .empty;
    defer outer_names.deinit(allocator);
    var inner_names: std.StringHashMapUnmanaged(usize) = .empty;
    defer inner_names.deinit(allocator);
    try outer_names.put(allocator, "x", 0);
    try inner_names.put(allocator, "x", 1);
    const scope_maps = [_]std.StringHashMapUnmanaged(usize){ outer_names, inner_names };
    const symbols = [_]Symbol{
        .{ .name = name, .scope_id = outer_scope, .kind = .variable_let, .declaration_span = name, .reference_count = 1 },
        .{ .name = name, .scope_id = inner_scope, .kind = .variable_let, .declaration_span = name },
    };
    const symbol_ids = [_]?u32{ 0, null };
    const references = [_]Reference{
        .{ .node_index = ref_node, .scope_id = inner_scope, .symbol_id = @enumFromInt(0), .flags = .{ .read = true } },
    };
    const scope_owner_map: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    const unresolved: std.AutoHashMapUnmanaged(u32, void) = .empty;
    const explicit_globals: std.AutoHashMapUnmanaged(u32, void) = .empty;
    const origins: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    const helper_refs: []const u32 = &.{};
    const helper_scopes: std.StringHashMapUnmanaged(usize) = .empty;

    const report = try checkExact(
        allocator,
        &ast,
        root,
        0,
        &symbol_ids,
        &symbols,
        &scopes,
        &scope_maps,
        &scope_owner_map,
        &references,
        helper_refs,
        &helper_scopes,
        &unresolved,
        &explicit_globals,
        &origins,
    );
    try std.testing.expectEqual(@as(usize, 1), report.scope_resolution_mismatch);
    try std.testing.expectEqual(@as(usize, 0), report.invalid_reference_node);
    try std.testing.expectEqual(@as(usize, 0), report.identity_mismatch);
    try std.testing.expect(!report.isClean());
}

test "exact identity audit rejects a shadowed binding carrying the outer SymbolId" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ast = Ast.init(allocator, "");
    defer ast.deinit();
    const name = try ast.addString("x");
    const outer_binding = try makeTestIdentifierNode(&ast, .binding_identifier, name);
    const inner_binding = try makeTestIdentifierNode(&ast, .binding_identifier, name);
    const inner = try ast.addListNode(.block_statement, name, try ast.addNodeList(&.{inner_binding}));
    const root = try ast.addListNode(.program, name, try ast.addNodeList(&.{ outer_binding, inner }));

    const scopes = [_]Scope{
        .{ .parent = .none, .kind = .global, .is_strict = false },
        .{ .parent = @enumFromInt(0), .kind = .block, .is_strict = false },
    };
    var outer_names: std.StringHashMapUnmanaged(usize) = .empty;
    defer outer_names.deinit(allocator);
    var inner_names: std.StringHashMapUnmanaged(usize) = .empty;
    defer inner_names.deinit(allocator);
    try outer_names.put(allocator, "x", 0);
    try inner_names.put(allocator, "x", 1);
    const scope_maps = [_]std.StringHashMapUnmanaged(usize){ outer_names, inner_names };
    const symbols = [_]Symbol{
        .{ .name = name, .scope_id = @enumFromInt(0), .kind = .variable_let, .declaration_span = name },
        .{ .name = name, .scope_id = @enumFromInt(1), .kind = .variable_let, .declaration_span = name },
    };
    var symbol_ids = [_]?u32{ null, null, null, null };
    symbol_ids[@intFromEnum(outer_binding)] = 0;
    // Adversarial corruption: the inner declaration uses the outer identity.
    symbol_ids[@intFromEnum(inner_binding)] = 0;
    const references = [_]Reference{
        .{ .node_index = .none, .scope_id = @enumFromInt(0), .symbol_id = @enumFromInt(0), .flags = .{ .declare = true } },
        .{ .node_index = .none, .scope_id = @enumFromInt(1), .symbol_id = @enumFromInt(1), .flags = .{ .declare = true } },
    };
    var scope_owner_map: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer scope_owner_map.deinit(allocator);
    try scope_owner_map.put(allocator, @intFromEnum(root), 0);
    try scope_owner_map.put(allocator, @intFromEnum(inner), 1);
    const unresolved: std.AutoHashMapUnmanaged(u32, void) = .empty;
    const explicit_globals: std.AutoHashMapUnmanaged(u32, void) = .empty;
    const origins: std.AutoHashMapUnmanaged(u32, u32) = .empty;

    const report = try checkExact(
        allocator,
        &ast,
        root,
        0,
        &symbol_ids,
        &symbols,
        &scopes,
        &scope_maps,
        &scope_owner_map,
        &references,
        &.{},
        &.{},
        &unresolved,
        &explicit_globals,
        &origins,
    );
    try std.testing.expectEqual(@as(usize, 1), report.binding_scope_mismatch);
    try std.testing.expect(!report.isClean());
}

test "exact identity audit resolves relocated symbols by their emitted scope-map names" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ast = Ast.init(allocator, "");
    defer ast.deinit();
    const source_name = try ast.addString("_err3");
    const left_name = try ast.addString("_err3$4");
    const right_name = try ast.addString("_err3$6");
    const left_binding = try makeTestIdentifierNode(&ast, .binding_identifier, left_name);
    const right_binding = try makeTestIdentifierNode(&ast, .binding_identifier, right_name);
    const root = try ast.addListNode(.program, source_name, try ast.addNodeList(&.{ left_binding, right_binding }));
    const scopes = [_]Scope{.{ .parent = .none, .kind = .global, .is_strict = false }};
    var output_names: std.StringHashMapUnmanaged(usize) = .empty;
    defer output_names.deinit(allocator);
    try output_names.put(allocator, "_err3$4", 0);
    try output_names.put(allocator, "_err3$6", 1);
    const scope_maps = [_]std.StringHashMapUnmanaged(usize){output_names};
    const symbols = [_]Symbol{
        .{ .name = source_name, .scope_id = @enumFromInt(0), .kind = .variable_let, .declaration_span = source_name, .synthetic_name = "_err3$4" },
        .{ .name = source_name, .scope_id = @enumFromInt(0), .kind = .variable_let, .declaration_span = source_name, .synthetic_name = "_err3$6" },
    };
    const symbol_ids = [_]?u32{ 0, 1, null };
    const references = [_]Reference{
        .{ .node_index = .none, .scope_id = @enumFromInt(0), .symbol_id = @enumFromInt(0), .flags = .{ .declare = true } },
        .{ .node_index = .none, .scope_id = @enumFromInt(0), .symbol_id = @enumFromInt(1), .flags = .{ .declare = true } },
    };
    var scope_owner_map: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer scope_owner_map.deinit(allocator);
    try scope_owner_map.put(allocator, @intFromEnum(root), 0);
    const unresolved: std.AutoHashMapUnmanaged(u32, void) = .empty;
    const explicit_globals: std.AutoHashMapUnmanaged(u32, void) = .empty;
    const origins: std.AutoHashMapUnmanaged(u32, u32) = .empty;

    const report = try checkExact(
        allocator,
        &ast,
        root,
        0,
        &symbol_ids,
        &symbols,
        &scopes,
        &scope_maps,
        &scope_owner_map,
        &references,
        &.{},
        &.{},
        &unresolved,
        &explicit_globals,
        &origins,
    );
    try std.testing.expectEqual(@as(usize, 0), report.scope_map_mismatch);
    try std.testing.expectEqual(@as(usize, 0), report.identity_mismatch);
    try std.testing.expect(report.isClean());
}

test "exact identity audit rejects non-declaration references without an AST node" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ast = Ast.init(allocator, "");
    defer ast.deinit();
    const name = try ast.addString("x");
    const binding = try makeTestIdentifierNode(&ast, .binding_identifier, name);
    const list = try ast.addNodeList(&.{binding});
    const root = try ast.addNode(.{
        .tag = .block_statement,
        .span = name,
        .data = .{ .list = list },
    });
    const scope: ScopeId = @enumFromInt(0);
    var names: std.StringHashMapUnmanaged(usize) = .empty;
    defer names.deinit(allocator);
    try names.put(allocator, "x", 0);
    const scopes = [_]Scope{.{ .parent = .none, .kind = .global, .is_strict = false }};
    const scope_maps = [_]std.StringHashMapUnmanaged(usize){names};
    const symbols = [_]Symbol{
        .{ .name = name, .scope_id = scope, .kind = .variable_let, .declaration_span = name, .reference_count = 2 },
    };
    const symbol_ids = [_]?u32{ 0, null };
    const references = [_]Reference{
        .{ .node_index = .none, .scope_id = scope, .symbol_id = @enumFromInt(0), .flags = .{ .read = true } },
        .{ .node_index = root, .scope_id = scope, .symbol_id = @enumFromInt(0), .flags = .{ .read = true } },
    };
    const scope_owner_map: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    const unresolved: std.AutoHashMapUnmanaged(u32, void) = .empty;
    const explicit_globals: std.AutoHashMapUnmanaged(u32, void) = .empty;
    const origins: std.AutoHashMapUnmanaged(u32, u32) = .empty;

    const report = try checkExact(
        allocator,
        &ast,
        root,
        0,
        &symbol_ids,
        &symbols,
        &scopes,
        &scope_maps,
        &scope_owner_map,
        &references,
        &.{},
        &.{},
        &unresolved,
        &explicit_globals,
        &origins,
    );
    try std.testing.expectEqual(@as(usize, 2), report.invalid_reference_node);
    try std.testing.expect(!report.isClean());
}

test "exact identity audit checks parser-owned SymbolIds against their references" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ast = Ast.init(allocator, "");
    defer ast.deinit();
    const x_name = try ast.addString("x");
    const y_name = try ast.addString("y");
    const binding = try makeTestIdentifierNode(&ast, .binding_identifier, x_name);
    const ref = try makeTestIdentifierNode(&ast, .identifier_reference, x_name);
    const list = try ast.addNodeList(&.{ binding, ref });
    const root = try ast.addListNode(.array_expression, x_name, list);
    const scope: ScopeId = @enumFromInt(0);
    var names: std.StringHashMapUnmanaged(usize) = .empty;
    defer names.deinit(allocator);
    try names.put(allocator, "x", 0);
    try names.put(allocator, "y", 1);
    const scopes = [_]Scope{.{ .parent = .none, .kind = .global, .is_strict = false }};
    const scope_maps = [_]std.StringHashMapUnmanaged(usize){names};
    const symbols = [_]Symbol{
        .{ .name = x_name, .scope_id = scope, .kind = .variable_let, .declaration_span = x_name, .reference_count = 1 },
        .{ .name = y_name, .scope_id = scope, .kind = .variable_let, .declaration_span = y_name },
    };
    const symbol_ids = [_]?u32{ 0, 1, null };
    const references = [_]Reference{
        .{ .node_index = ref, .scope_id = scope, .symbol_id = @enumFromInt(0), .flags = .{ .read = true } },
    };
    const scope_owner_map: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    const unresolved: std.AutoHashMapUnmanaged(u32, void) = .empty;
    const explicit_globals: std.AutoHashMapUnmanaged(u32, void) = .empty;
    const origins: std.AutoHashMapUnmanaged(u32, u32) = .empty;

    const report = try checkExact(
        allocator,
        &ast,
        root,
        2,
        &symbol_ids,
        &symbols,
        &scopes,
        &scope_maps,
        &scope_owner_map,
        &references,
        &.{},
        &.{},
        &unresolved,
        &explicit_globals,
        &origins,
    );
    try std.testing.expectEqual(@as(usize, 1), report.identity_mismatch);
    try std.testing.expectEqual(@as(usize, 1), report.scope_resolution_mismatch);
    try std.testing.expect(!report.isClean());
}

test "exact identity audit rejects references to nodes removed from the final AST" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ast = Ast.init(allocator, "");
    defer ast.deinit();
    const x_name = try ast.addString("x");
    const orphan = try makeTestIdentifierNode(&ast, .identifier_reference, x_name);
    const zero = try ast.addString("0");
    const root = try ast.addNode(.{ .tag = .numeric_literal, .span = zero, .data = .{ .none = 0 } });
    const scope: ScopeId = @enumFromInt(0);
    var names: std.StringHashMapUnmanaged(usize) = .empty;
    defer names.deinit(allocator);
    try names.put(allocator, "x", 0);
    const scopes = [_]Scope{.{ .parent = .none, .kind = .global, .is_strict = false }};
    const scope_maps = [_]std.StringHashMapUnmanaged(usize){names};
    const symbols = [_]Symbol{
        .{ .name = x_name, .scope_id = scope, .kind = .variable_let, .declaration_span = x_name, .reference_count = 1 },
    };
    const symbol_ids = [_]?u32{ 0, null };
    const references = [_]Reference{
        .{ .node_index = orphan, .scope_id = scope, .symbol_id = @enumFromInt(0), .flags = .{ .read = true } },
    };
    const scope_owner_map: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    const unresolved: std.AutoHashMapUnmanaged(u32, void) = .empty;
    const explicit_globals: std.AutoHashMapUnmanaged(u32, void) = .empty;
    const origins: std.AutoHashMapUnmanaged(u32, u32) = .empty;

    const report = try checkExact(
        allocator,
        &ast,
        root,
        0,
        &symbol_ids,
        &symbols,
        &scopes,
        &scope_maps,
        &scope_owner_map,
        &references,
        &.{},
        &.{},
        &unresolved,
        &explicit_globals,
        &origins,
    );
    try std.testing.expectEqual(@as(usize, 1), report.unreachable_reference);
    try std.testing.expect(!report.isClean());
}

test "exact identity audit rejects an identifier node shared by different lexical parents" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ast = Ast.init(allocator, "");
    defer ast.deinit();
    const name = try ast.addString("x");
    const binding = try makeTestIdentifierNode(&ast, .binding_identifier, name);
    const shared_ref = try makeTestIdentifierNode(&ast, .identifier_reference, name);
    const left = try ast.addNode(.{
        .tag = .block_statement,
        .span = name,
        .data = .{ .list = try ast.addNodeList(&.{shared_ref}) },
    });
    const right = try ast.addNode(.{
        .tag = .block_statement,
        .span = name,
        .data = .{ .list = try ast.addNodeList(&.{shared_ref}) },
    });
    const root = try ast.addNode(.{
        .tag = .block_statement,
        .span = name,
        .data = .{ .list = try ast.addNodeList(&.{ binding, left, right }) },
    });
    const scopes = [_]Scope{
        .{ .parent = .none, .kind = .global, .is_strict = false },
        .{ .parent = @enumFromInt(0), .kind = .block, .is_strict = false },
        .{ .parent = @enumFromInt(1), .kind = .block, .is_strict = false },
        .{ .parent = @enumFromInt(1), .kind = .block, .is_strict = false },
    };
    var root_names: std.StringHashMapUnmanaged(usize) = .empty;
    defer root_names.deinit(allocator);
    try root_names.put(allocator, "x", 0);
    const scope_maps = [_]std.StringHashMapUnmanaged(usize){ .empty, root_names, .empty, .empty };
    const symbols = [_]Symbol{
        .{ .name = name, .scope_id = @enumFromInt(1), .kind = .variable_let, .declaration_span = name, .reference_count = 1 },
    };
    const symbol_ids = [_]?u32{ 0, 0, null, null, null };
    const references = [_]Reference{
        .{ .node_index = .none, .scope_id = @enumFromInt(1), .symbol_id = @enumFromInt(0), .flags = .{ .declare = true } },
        .{ .node_index = shared_ref, .scope_id = @enumFromInt(3), .symbol_id = @enumFromInt(0), .flags = .{ .read = true } },
    };
    var scope_owner_map: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer scope_owner_map.deinit(allocator);
    try scope_owner_map.put(allocator, @intFromEnum(root), 1);
    try scope_owner_map.put(allocator, @intFromEnum(left), 2);
    try scope_owner_map.put(allocator, @intFromEnum(right), 3);
    const unresolved: std.AutoHashMapUnmanaged(u32, void) = .empty;
    const explicit_globals: std.AutoHashMapUnmanaged(u32, void) = .empty;
    const origins: std.AutoHashMapUnmanaged(u32, u32) = .empty;

    const report = try checkExact(
        allocator,
        &ast,
        root,
        0,
        &symbol_ids,
        &symbols,
        &scopes,
        &scope_maps,
        &scope_owner_map,
        &references,
        &.{},
        &.{},
        &unresolved,
        &explicit_globals,
        &origins,
    );
    try std.testing.expectEqual(@as(usize, 1), report.ambiguous_ast_parent);
    try std.testing.expectEqual(@as(usize, 0), report.reference_scope_mismatch);
    try std.testing.expect(!report.isClean());
}

test "exact identity audit rejects a shared reference node across top-level statements" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ast = Ast.init(allocator, "");
    defer ast.deinit();
    const name = try ast.addString("x");
    const binding = try makeTestIdentifierNode(&ast, .binding_identifier, name);
    const shared_ref = try makeTestIdentifierNode(&ast, .identifier_reference, name);
    const unshared_ref = try makeTestIdentifierNode(&ast, .identifier_reference, name);
    const left_parent = try ast.addNode(.{
        .tag = .expression_statement,
        .span = name,
        .data = .{ .unary = .{ .operand = shared_ref, .flags = 0 } },
    });
    const right_parent = try ast.addNode(.{
        .tag = .expression_statement,
        .span = name,
        .data = .{ .unary = .{ .operand = shared_ref, .flags = 0 } },
    });
    const unshared_parent = try ast.addNode(.{
        .tag = .expression_statement,
        .span = name,
        .data = .{ .unary = .{ .operand = unshared_ref, .flags = 0 } },
    });
    const root = try ast.addNode(.{
        .tag = .program,
        .span = name,
        .data = .{ .list = try ast.addNodeList(&.{ binding, left_parent, right_parent, unshared_parent }) },
    });
    const scopes = [_]Scope{
        .{ .parent = .none, .kind = .global, .is_strict = false },
    };
    var local_names: std.StringHashMapUnmanaged(usize) = .empty;
    defer local_names.deinit(allocator);
    try local_names.put(allocator, "x", 0);
    const scope_maps = [_]std.StringHashMapUnmanaged(usize){local_names};
    var symbols = [_]Symbol{
        .{ .name = name, .scope_id = @enumFromInt(0), .kind = .variable_let, .declaration_span = name, .reference_count = 2 },
    };
    const symbol_ids = [_]?u32{ 0, 0, 0, null, null, null, null };
    var references = [_]Reference{
        .{ .node_index = .none, .scope_id = @enumFromInt(0), .symbol_id = @enumFromInt(0), .flags = .{ .declare = true } },
        .{ .node_index = shared_ref, .scope_id = @enumFromInt(0), .symbol_id = @enumFromInt(0), .flags = .{ .read = true } },
        .{ .node_index = unshared_ref, .scope_id = @enumFromInt(0), .symbol_id = @enumFromInt(0), .flags = .{ .read = true }, .stmt_idx = 3 },
        .{ .node_index = unshared_ref, .scope_id = @enumFromInt(0), .symbol_id = @enumFromInt(0), .flags = .{ .read = true }, .stmt_idx = 99 },
    };
    var scope_owner_map: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer scope_owner_map.deinit(allocator);
    try scope_owner_map.put(allocator, @intFromEnum(root), 0);
    const unresolved: std.AutoHashMapUnmanaged(u32, void) = .empty;
    const explicit_globals: std.AutoHashMapUnmanaged(u32, void) = .empty;
    const origins: std.AutoHashMapUnmanaged(u32, u32) = .empty;

    const report = try checkExact(
        allocator,
        &ast,
        root,
        @intCast(ast.nodes.items.len),
        &symbol_ids,
        &symbols,
        &scopes,
        &scope_maps,
        &scope_owner_map,
        references[0..3],
        &.{},
        &.{},
        &unresolved,
        &explicit_globals,
        &origins,
    );
    try std.testing.expectEqual(@as(usize, 0), report.ambiguous_ast_parent);
    try std.testing.expectEqual(@as(usize, 1), report.reference_statement_mismatch);
    try std.testing.expect(!report.isClean());

    // The second metadata row for one node is checked too; validation must
    // not stop after the first row keyed by that NodeIndex.
    symbols[0].reference_count = 3;
    const duplicate_stmt = try checkExact(
        allocator,
        &ast,
        root,
        @intCast(ast.nodes.items.len),
        &symbol_ids,
        &symbols,
        &scopes,
        &scope_maps,
        &scope_owner_map,
        &references,
        &.{},
        &.{},
        &unresolved,
        &explicit_globals,
        &origins,
    );
    try std.testing.expectEqual(@as(usize, 2), duplicate_stmt.reference_statement_mismatch);

    // A single reference row with a wrong statement index is also rejected.
    references[1].stmt_idx = 99;
    const wrong_stmt = try checkExact(
        allocator,
        &ast,
        root,
        @intCast(ast.nodes.items.len),
        &symbol_ids,
        &symbols,
        &scopes,
        &scope_maps,
        &scope_owner_map,
        &references,
        &.{},
        &.{},
        &unresolved,
        &explicit_globals,
        &origins,
    );
    try std.testing.expect(wrong_stmt.reference_statement_mismatch > 0);
}

test "exact identity audit rejects a reference node shared by block statements" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ast = Ast.init(allocator, "");
    defer ast.deinit();
    const name = try ast.addString("x");
    const binding = try makeTestIdentifierNode(&ast, .binding_identifier, name);
    const reference_node = try makeTestIdentifierNode(&ast, .identifier_reference, name);
    const first_value = try ast.addNode(.{
        .tag = .boolean_literal,
        .span = name,
        .data = .{ .none = 0 },
    });
    const first_statement = try ast.addNode(.{
        .tag = .expression_statement,
        .span = name,
        .data = .{ .unary = .{ .operand = first_value, .flags = 0 } },
    });
    const second_statement = try ast.addNode(.{
        .tag = .expression_statement,
        .span = name,
        .data = .{ .unary = .{ .operand = reference_node, .flags = 0 } },
    });
    const block = try ast.addListNode(.block_statement, name, try ast.addNodeList(&.{ first_statement, second_statement }));
    const root = try ast.addListNode(.program, name, try ast.addNodeList(&.{ binding, block }));
    const scopes = [_]Scope{
        .{ .parent = .none, .kind = .global, .is_strict = false },
        .{ .parent = @enumFromInt(0), .kind = .block, .is_strict = false },
    };
    var global_names: std.StringHashMapUnmanaged(usize) = .empty;
    defer global_names.deinit(allocator);
    try global_names.put(allocator, "x", 0);
    const scope_maps = [_]std.StringHashMapUnmanaged(usize){ global_names, .empty };
    const symbols = [_]Symbol{
        .{ .name = name, .scope_id = @enumFromInt(0), .kind = .variable_let, .declaration_span = name, .reference_count = 1 },
    };
    const symbol_ids = [_]?u32{ 0, 0, null, null, null, null, null };
    var references = [_]Reference{
        .{ .node_index = .none, .scope_id = @enumFromInt(0), .symbol_id = @enumFromInt(0), .flags = .{ .declare = true }, .stmt_idx = 0, .scope_stmt_idx = 0 },
        .{ .node_index = reference_node, .scope_id = @enumFromInt(1), .symbol_id = @enumFromInt(0), .flags = .{ .read = true }, .stmt_idx = 1, .scope_stmt_idx = 1 },
    };
    var scope_owner_map: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer scope_owner_map.deinit(allocator);
    try scope_owner_map.put(allocator, @intFromEnum(root), 0);
    try scope_owner_map.put(allocator, @intFromEnum(block), 1);
    const unresolved: std.AutoHashMapUnmanaged(u32, void) = .empty;
    const explicit_globals: std.AutoHashMapUnmanaged(u32, void) = .empty;
    const origins: std.AutoHashMapUnmanaged(u32, u32) = .empty;

    const clean = try checkExact(
        allocator,
        &ast,
        root,
        @intCast(ast.nodes.items.len),
        &symbol_ids,
        &symbols,
        &scopes,
        &scope_maps,
        &scope_owner_map,
        &references,
        &.{},
        &.{},
        &unresolved,
        &explicit_globals,
        &origins,
    );
    try std.testing.expectEqual(@as(usize, 0), clean.reference_scope_statement_alias);

    ast.nodes.items[@intFromEnum(first_statement)].data.unary.operand = reference_node;
    const aliased = try checkExact(
        allocator,
        &ast,
        root,
        @intCast(ast.nodes.items.len),
        &symbol_ids,
        &symbols,
        &scopes,
        &scope_maps,
        &scope_owner_map,
        &references,
        &.{},
        &.{},
        &unresolved,
        &explicit_globals,
        &origins,
    );
    try std.testing.expect(aliased.reference_scope_statement_alias > 0);
    try std.testing.expect(!aliased.isClean());
}

test "exact identity audit rejects one reference node used twice in one statement" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ast = Ast.init(allocator, "");
    defer ast.deinit();
    const name = try ast.addString("x");
    const binding = try makeTestIdentifierNode(&ast, .binding_identifier, name);
    const reference_node = try makeTestIdentifierNode(&ast, .identifier_reference, name);
    const binary = try ast.addNode(.{
        .tag = .binary_expression,
        .span = name,
        .data = .{ .binary = .{ .left = reference_node, .right = reference_node, .flags = 0 } },
    });
    const statement = try ast.addNode(.{
        .tag = .expression_statement,
        .span = name,
        .data = .{ .unary = .{ .operand = binary, .flags = 0 } },
    });
    const root = try ast.addListNode(.program, name, try ast.addNodeList(&.{ binding, statement }));
    const scopes = [_]Scope{
        .{ .parent = .none, .kind = .global, .is_strict = false },
    };
    var global_names: std.StringHashMapUnmanaged(usize) = .empty;
    defer global_names.deinit(allocator);
    try global_names.put(allocator, "x", 0);
    const scope_maps = [_]std.StringHashMapUnmanaged(usize){global_names};
    const symbols = [_]Symbol{
        .{ .name = name, .scope_id = @enumFromInt(0), .kind = .variable_let, .declaration_span = name, .reference_count = 1 },
    };
    const symbol_ids = [_]?u32{ 0, 0, null, null, null };
    const references = [_]Reference{
        .{ .node_index = .none, .scope_id = @enumFromInt(0), .symbol_id = @enumFromInt(0), .flags = .{ .declare = true }, .stmt_idx = 0 },
        .{ .node_index = reference_node, .scope_id = @enumFromInt(0), .symbol_id = @enumFromInt(0), .flags = .{ .read = true }, .stmt_idx = 1 },
    };
    var scope_owner_map: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer scope_owner_map.deinit(allocator);
    try scope_owner_map.put(allocator, @intFromEnum(root), 0);
    const unresolved: std.AutoHashMapUnmanaged(u32, void) = .empty;
    const explicit_globals: std.AutoHashMapUnmanaged(u32, void) = .empty;
    const origins: std.AutoHashMapUnmanaged(u32, u32) = .empty;

    const report = try checkExact(
        allocator,
        &ast,
        root,
        @intCast(ast.nodes.items.len),
        &symbol_ids,
        &symbols,
        &scopes,
        &scope_maps,
        &scope_owner_map,
        &references,
        &.{},
        &.{},
        &unresolved,
        &explicit_globals,
        &origins,
    );
    try std.testing.expectEqual(@as(usize, 1), report.reference_node_use_alias);
    try std.testing.expect(!report.isClean());
}

test "exact identity audit rejects a copied external reference shadowed in its output scope" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ast = Ast.init(allocator, "");
    defer ast.deinit();
    const name = try ast.addString("Object");
    const source_global = try makeTestIdentifierNode(&ast, .identifier_reference, name);
    const binding = try makeTestIdentifierNode(&ast, .binding_identifier, name);
    const copied_global = try makeTestIdentifierNode(&ast, .identifier_reference, name);
    const root = try ast.addNode(.{
        .tag = .block_statement,
        .span = name,
        .data = .{ .list = try ast.addNodeList(&.{ binding, copied_global }) },
    });
    const scopes = [_]Scope{
        .{ .parent = .none, .kind = .global, .is_strict = false },
        .{ .parent = @enumFromInt(0), .kind = .block, .is_strict = false },
    };
    var local_names: std.StringHashMapUnmanaged(usize) = .empty;
    defer local_names.deinit(allocator);
    try local_names.put(allocator, "Object", 0);
    const scope_maps = [_]std.StringHashMapUnmanaged(usize){ .empty, local_names };
    const symbols = [_]Symbol{
        .{ .name = name, .scope_id = @enumFromInt(1), .kind = .variable_let, .declaration_span = name },
    };
    const symbol_ids = [_]?u32{ null, 0, null, null };
    const references = [_]Reference{
        .{ .node_index = .none, .scope_id = @enumFromInt(1), .symbol_id = @enumFromInt(0), .flags = .{ .declare = true } },
    };
    var scope_owner_map: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer scope_owner_map.deinit(allocator);
    try scope_owner_map.put(allocator, @intFromEnum(root), 1);
    var unresolved: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer unresolved.deinit(allocator);
    try unresolved.put(allocator, @intFromEnum(source_global), {});
    const explicit_globals: std.AutoHashMapUnmanaged(u32, void) = .empty;
    var origins: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer origins.deinit(allocator);
    try origins.put(allocator, @intFromEnum(copied_global), @intFromEnum(source_global));

    const report = try checkExact(
        allocator,
        &ast,
        root,
        1,
        &symbol_ids,
        &symbols,
        &scopes,
        &scope_maps,
        &scope_owner_map,
        &references,
        &.{},
        &.{},
        &unresolved,
        &explicit_globals,
        &origins,
    );
    try std.testing.expectEqual(@as(usize, 0), report.external_references);
    try std.testing.expectEqual(@as(usize, 1), report.shadowed_external_reference);
    try std.testing.expect(!report.isClean());
}

test "exact identity audit accepts a provenance-backed external at a known ordinary scope" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ast = Ast.init(allocator, "");
    defer ast.deinit();
    const name = try ast.addString("Object");
    const external_ref = try makeTestIdentifierNode(&ast, .identifier_reference, name);
    const root = try ast.addListNode(.program, name, try ast.addNodeList(&.{external_ref}));
    const scopes = [_]Scope{.{ .parent = .none, .kind = .global, .is_strict = false }};
    const scope_maps = [_]std.StringHashMapUnmanaged(usize){.empty};
    var owners: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer owners.deinit(allocator);
    try owners.put(allocator, @intFromEnum(root), 0);
    var unresolved: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer unresolved.deinit(allocator);
    try unresolved.put(allocator, @intFromEnum(external_ref), {});
    const explicit_globals: std.AutoHashMapUnmanaged(u32, void) = .empty;
    const origins: std.AutoHashMapUnmanaged(u32, u32) = .empty;

    const report = try checkExact(
        allocator,
        &ast,
        root,
        @intCast(ast.nodes.items.len),
        &.{},
        &.{},
        &scopes,
        &scope_maps,
        &owners,
        &.{},
        &.{},
        &.{},
        &unresolved,
        &explicit_globals,
        &origins,
    );
    try std.testing.expectEqual(@as(usize, 1), report.external_references);
    try std.testing.expectEqual(@as(usize, 0), report.unclassified_reference);
    try std.testing.expect(report.isClean());
}

test "exact identity audit keeps a copied external unclassified inside with at a known scope" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ast = Ast.init(allocator, "");
    defer ast.deinit();
    const name = try ast.addString("Object");
    const source_ref = try makeTestIdentifierNode(&ast, .identifier_reference, name);
    const copied_ref = try makeTestIdentifierNode(&ast, .identifier_reference, name);
    const parser_node_count = @intFromEnum(copied_ref);
    const object_span = try ast.addString("'scope'");
    const object = try ast.addNode(.{
        .tag = .string_literal,
        .span = object_span,
        .data = .{ .string_ref = object_span },
    });
    const body_statement = try ast.addNode(.{
        .tag = .expression_statement,
        .span = name,
        .data = .{ .unary = .{ .operand = copied_ref, .flags = 0 } },
    });
    const body = try ast.addListNode(.block_statement, name, try ast.addNodeList(&.{body_statement}));
    const with_statement = try ast.addNode(.{
        .tag = .with_statement,
        .span = name,
        .data = .{ .binary = .{ .left = object, .right = body, .flags = 0 } },
    });
    const root = try ast.addListNode(.program, name, try ast.addNodeList(&.{with_statement}));
    const scopes = [_]Scope{.{
        .parent = .none,
        .kind = .global,
        .is_strict = false,
        .subtree_has_with = true,
    }};
    const scope_maps = [_]std.StringHashMapUnmanaged(usize){.empty};
    var scope_owner_map: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer scope_owner_map.deinit(allocator);
    try scope_owner_map.put(allocator, @intFromEnum(root), 0);
    var unresolved: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer unresolved.deinit(allocator);
    try unresolved.put(allocator, @intFromEnum(source_ref), {});
    const explicit_globals: std.AutoHashMapUnmanaged(u32, void) = .empty;
    var origins: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer origins.deinit(allocator);
    try origins.put(allocator, @intFromEnum(copied_ref), @intFromEnum(source_ref));

    const report = try checkExact(
        allocator,
        &ast,
        root,
        parser_node_count,
        &.{},
        &.{},
        &scopes,
        &scope_maps,
        &scope_owner_map,
        &.{},
        &.{},
        &.{},
        &unresolved,
        &explicit_globals,
        &origins,
    );
    try std.testing.expectEqual(@as(usize, 0), report.external_references);
    try std.testing.expectEqual(@as(usize, 1), report.unclassified_reference);
    try std.testing.expectEqual(@intFromEnum(copied_ref), report.first_unclassified_reference.?.node_index);
}

test "exact identity audit keeps a copied external unclassified after direct eval" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ast = Ast.init(allocator, "");
    defer ast.deinit();
    const object_name = try ast.addString("Object");
    const source_ref = try makeTestIdentifierNode(&ast, .identifier_reference, object_name);
    const eval_name = try ast.addString("eval");
    const eval_ref = try makeTestIdentifierNode(&ast, .identifier_reference, eval_name);
    const eval_arg_span = try ast.addString("'var Object = 1'");
    const eval_arg = try ast.addNode(.{
        .tag = .string_literal,
        .span = eval_arg_span,
        .data = .{ .string_ref = eval_arg_span },
    });
    const eval_args = try ast.addNodeList(&.{eval_arg});
    const eval_extra = try ast.addExtras(&.{ @intFromEnum(eval_ref), eval_args.start, eval_args.len, 0 });
    const eval_call = try ast.addExtraNode(.call_expression, eval_name, eval_extra);
    const eval_statement = try ast.addNode(.{
        .tag = .expression_statement,
        .span = eval_name,
        .data = .{ .unary = .{ .operand = eval_call, .flags = 0 } },
    });
    const parser_node_count: u32 = @intCast(ast.nodes.items.len);
    const copied_ref = try makeTestIdentifierNode(&ast, .identifier_reference, object_name);
    const object_statement = try ast.addNode(.{
        .tag = .expression_statement,
        .span = object_name,
        .data = .{ .unary = .{ .operand = copied_ref, .flags = 0 } },
    });
    const root = try ast.addListNode(.program, object_name, try ast.addNodeList(&.{ eval_statement, object_statement }));
    const scopes = [_]Scope{.{
        .parent = .none,
        .kind = .global,
        .is_strict = false,
        .subtree_has_direct_eval = true,
    }};
    const scope_maps = [_]std.StringHashMapUnmanaged(usize){.empty};
    var scope_owner_map: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer scope_owner_map.deinit(allocator);
    try scope_owner_map.put(allocator, @intFromEnum(root), 0);
    var unresolved: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer unresolved.deinit(allocator);
    try unresolved.put(allocator, @intFromEnum(source_ref), {});
    try unresolved.put(allocator, @intFromEnum(eval_ref), {});
    const explicit_globals: std.AutoHashMapUnmanaged(u32, void) = .empty;
    var origins: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer origins.deinit(allocator);
    try origins.put(allocator, @intFromEnum(copied_ref), @intFromEnum(source_ref));

    const report = try checkExact(
        allocator,
        &ast,
        root,
        parser_node_count,
        &.{},
        &.{},
        &scopes,
        &scope_maps,
        &scope_owner_map,
        &.{},
        &.{},
        &.{},
        &unresolved,
        &explicit_globals,
        &origins,
    );
    try std.testing.expectEqual(@as(usize, 1), report.external_references);
    try std.testing.expectEqual(@as(usize, 1), report.unclassified_reference);
    try std.testing.expectEqual(@as(usize, 1), report.generated_references);
}

test "exact identity audit accepts an unresolved external when its scope path is absent but no binding can shadow it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ast = Ast.init(allocator, "");
    defer ast.deinit();
    const name = try ast.addString("Object");
    const external_ref = try makeTestIdentifierNode(&ast, .identifier_reference, name);
    const scopes = [_]Scope{.{ .parent = .none, .kind = .global, .is_strict = false }};
    const scope_maps = [_]std.StringHashMapUnmanaged(usize){.empty};
    const scope_owner_map: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    var unresolved: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer unresolved.deinit(allocator);
    try unresolved.put(allocator, @intFromEnum(external_ref), {});
    const explicit_globals: std.AutoHashMapUnmanaged(u32, void) = .empty;
    const origins: std.AutoHashMapUnmanaged(u32, u32) = .empty;

    const report = try checkExact(
        allocator,
        &ast,
        external_ref,
        @intCast(ast.nodes.items.len),
        &.{null},
        &.{},
        &scopes,
        &scope_maps,
        &scope_owner_map,
        &.{},
        &.{},
        &.{},
        &unresolved,
        &explicit_globals,
        &origins,
    );
    try std.testing.expectEqual(@as(usize, 1), report.external_references);
    try std.testing.expectEqual(@as(usize, 0), report.unclassified_reference);
    try std.testing.expect(report.isClean());
}

test "exact identity audit keeps an unknown-scope external unclassified if any lexical binding can shadow it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ast = Ast.init(allocator, "");
    defer ast.deinit();
    const name = try ast.addString("Object");
    const external_ref = try makeTestIdentifierNode(&ast, .identifier_reference, name);
    var nested_names: std.StringHashMapUnmanaged(usize) = .empty;
    defer nested_names.deinit(allocator);
    try nested_names.put(allocator, "Object", 0);
    const scopes = [_]Scope{
        .{ .parent = .none, .kind = .global, .is_strict = false },
        .{ .parent = @enumFromInt(0), .kind = .function, .is_strict = false },
    };
    const scope_maps = [_]std.StringHashMapUnmanaged(usize){ .empty, nested_names };
    const symbols = [_]Symbol{
        .{ .name = name, .scope_id = @enumFromInt(1), .kind = .variable_let, .declaration_span = name },
    };
    const symbol_ids = [_]?u32{null};
    const scope_owner_map: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    var unresolved: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer unresolved.deinit(allocator);
    try unresolved.put(allocator, @intFromEnum(external_ref), {});
    const explicit_globals: std.AutoHashMapUnmanaged(u32, void) = .empty;
    const origins: std.AutoHashMapUnmanaged(u32, u32) = .empty;

    const report = try checkExact(
        allocator,
        &ast,
        external_ref,
        @intCast(ast.nodes.items.len),
        &symbol_ids,
        &symbols,
        &scopes,
        &scope_maps,
        &scope_owner_map,
        &.{},
        &.{},
        &.{},
        &unresolved,
        &explicit_globals,
        &origins,
    );
    try std.testing.expectEqual(@as(usize, 0), report.external_references);
    try std.testing.expectEqual(@as(usize, 1), report.unclassified_reference);
    try std.testing.expect(!report.isClean());
}

test "exact identity audit rejects a visible but non-innermost reference scope" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ast = Ast.init(allocator, "");
    defer ast.deinit();
    const name = try ast.addString("x");
    const ref_node = try makeTestIdentifierNode(&ast, .identifier_reference, name);
    const inner_list = try ast.addNodeList(&.{ref_node});
    const inner = try ast.addNode(.{
        .tag = .block_statement,
        .span = name,
        .data = .{ .list = inner_list },
    });
    const outer_list = try ast.addNodeList(&.{inner});
    const root = try ast.addNode(.{
        .tag = .block_statement,
        .span = name,
        .data = .{ .list = outer_list },
    });
    const scopes = [_]Scope{
        .{ .parent = .none, .kind = .global, .is_strict = false },
        .{ .parent = @enumFromInt(0), .kind = .block, .is_strict = false },
        .{ .parent = @enumFromInt(1), .kind = .block, .is_strict = false },
    };
    var outer_names: std.StringHashMapUnmanaged(usize) = .empty;
    defer outer_names.deinit(allocator);
    try outer_names.put(allocator, "x", 0);
    const scope_maps = [_]std.StringHashMapUnmanaged(usize){ .empty, outer_names, .empty };
    const symbols = [_]Symbol{
        .{ .name = name, .scope_id = @enumFromInt(1), .kind = .variable_let, .declaration_span = name, .reference_count = 1 },
    };
    const symbol_ids = [_]?u32{ 0, null, null };
    // x는 outer_scope에서 보이고 여기서 이름 조회도 성공하지만, 실제
    // 참조 노드는 inner block 안에 있으므로 ScopeId는 2여야 한다.
    const references = [_]Reference{
        .{ .node_index = ref_node, .scope_id = @enumFromInt(1), .symbol_id = @enumFromInt(0), .flags = .{ .read = true } },
    };
    var scope_owner_map: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer scope_owner_map.deinit(allocator);
    try scope_owner_map.put(allocator, @intFromEnum(root), 1);
    try scope_owner_map.put(allocator, @intFromEnum(inner), 2);
    const unresolved: std.AutoHashMapUnmanaged(u32, void) = .empty;
    const explicit_globals: std.AutoHashMapUnmanaged(u32, void) = .empty;
    const origins: std.AutoHashMapUnmanaged(u32, u32) = .empty;

    const report = try checkExact(
        allocator,
        &ast,
        root,
        0,
        &symbol_ids,
        &symbols,
        &scopes,
        &scope_maps,
        &scope_owner_map,
        &references,
        &.{},
        &.{},
        &unresolved,
        &explicit_globals,
        &origins,
    );
    try std.testing.expectEqual(@as(usize, 1), report.reference_scope_mismatch);
    try std.testing.expectEqual(@as(usize, 0), report.invisible_reference);
    try std.testing.expect(!report.isClean());
}

test "exact identity audit preserves visible source scopes whose owner was lowered away" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ast = Ast.init(allocator, "");
    defer ast.deinit();
    const name = try ast.addString("x");
    const ref_node = try makeTestIdentifierNode(&ast, .identifier_reference, name);
    const list = try ast.addNodeList(&.{ref_node});
    const root = try ast.addNode(.{
        .tag = .block_statement,
        .span = name,
        .data = .{ .list = list },
    });
    const scopes = [_]Scope{
        .{ .parent = .none, .kind = .global, .is_strict = false },
        .{ .parent = @enumFromInt(0), .kind = .block, .is_strict = false },
        .{ .parent = @enumFromInt(0), .kind = .block, .is_strict = false },
    };
    var source_names: std.StringHashMapUnmanaged(usize) = .empty;
    defer source_names.deinit(allocator);
    try source_names.put(allocator, "x", 0);
    const scope_maps = [_]std.StringHashMapUnmanaged(usize){ .empty, source_names, .empty };
    const symbols = [_]Symbol{
        .{ .name = name, .scope_id = @enumFromInt(1), .kind = .variable_let, .declaration_span = name, .reference_count = 1 },
    };
    const symbol_ids = [_]?u32{ 0, null };
    const references = [_]Reference{
        .{ .node_index = ref_node, .scope_id = @enumFromInt(1), .symbol_id = @enumFromInt(0), .flags = .{ .read = true } },
    };
    var scope_owner_map: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer scope_owner_map.deinit(allocator);
    try scope_owner_map.put(allocator, @intFromEnum(root), 2);
    const unresolved: std.AutoHashMapUnmanaged(u32, void) = .empty;
    const explicit_globals: std.AutoHashMapUnmanaged(u32, void) = .empty;
    const origins: std.AutoHashMapUnmanaged(u32, u32) = .empty;

    const report = try checkExact(
        allocator,
        &ast,
        root,
        0,
        &symbol_ids,
        &symbols,
        &scopes,
        &scope_maps,
        &scope_owner_map,
        &references,
        &.{},
        &.{},
        &unresolved,
        &explicit_globals,
        &origins,
    );
    try std.testing.expectEqual(@as(usize, 0), report.reference_scope_mismatch);
    try std.testing.expectEqual(@as(usize, 0), report.scope_resolution_mismatch);
    try std.testing.expectEqual(@as(usize, 0), report.invisible_reference);
}

test "exact identity audit preserves generated catch symbols after state-machine lowering" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ast = Ast.init(allocator, "");
    defer ast.deinit();
    const name = try ast.addString("_caught");
    const binding = try makeTestIdentifierNode(&ast, .binding_identifier, name);
    const ref = try makeTestIdentifierNode(&ast, .identifier_reference, name);
    const none = @intFromEnum(NodeIndex.none);
    const declarator_extra = try ast.addExtras(&.{ @intFromEnum(binding), none, none });
    const declarator = try ast.addNode(.{ .tag = .variable_declarator, .span = name, .data = .{ .extra = declarator_extra } });
    const declarators = try ast.addNodeList(&.{declarator});
    const declaration_extra = try ast.addExtras(&.{
        @intFromEnum(ast_mod.VariableDeclarationKind.@"var"),
        declarators.start,
        declarators.len,
    });
    const declaration = try ast.addNode(.{ .tag = .variable_declaration, .span = name, .data = .{ .extra = declaration_extra } });
    const body = try ast.addNode(.{ .tag = .block_statement, .span = name, .data = .{ .list = try ast.addNodeList(&.{ declaration, ref }) } });
    const dead_catch = try ast.addNode(.{ .tag = .catch_clause, .span = name, .data = .{ .binary = .{ .left = .none, .right = .none, .flags = 0 } } });
    const scopes = [_]Scope{
        .{ .parent = .none, .kind = .global, .is_strict = false },
        .{ .parent = @enumFromInt(0), .kind = .catch_clause, .is_strict = false },
        .{ .parent = @enumFromInt(0), .kind = .block, .is_strict = false },
    };
    var catch_names: std.StringHashMapUnmanaged(usize) = .empty;
    defer catch_names.deinit(allocator);
    try catch_names.put(allocator, "_caught", 0);
    const scope_maps = [_]std.StringHashMapUnmanaged(usize){ .empty, catch_names, .empty };
    const symbols = [_]Symbol{
        .{ .name = name, .scope_id = @enumFromInt(1), .kind = .catch_binding, .declaration_span = name, .reference_count = 1, .synthetic_name = "_caught" },
    };
    const symbol_ids = [_]?u32{ 0, 0, null, null, null };
    const references = [_]Reference{
        .{ .node_index = .none, .scope_id = @enumFromInt(1), .symbol_id = @enumFromInt(0), .flags = .{ .declare = true } },
        .{ .node_index = ref, .scope_id = @enumFromInt(1), .symbol_id = @enumFromInt(0), .flags = .{ .read = true } },
    };
    var scope_owner_map: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer scope_owner_map.deinit(allocator);
    try scope_owner_map.put(allocator, @intFromEnum(body), 2);
    try scope_owner_map.put(allocator, @intFromEnum(dead_catch), 1);
    const unresolved: std.AutoHashMapUnmanaged(u32, void) = .empty;
    const explicit_globals: std.AutoHashMapUnmanaged(u32, void) = .empty;
    const origins: std.AutoHashMapUnmanaged(u32, u32) = .empty;

    const report = try checkExact(
        allocator,
        &ast,
        body,
        0,
        &symbol_ids,
        &symbols,
        &scopes,
        &scope_maps,
        &scope_owner_map,
        &references,
        &.{},
        &.{},
        &unresolved,
        &explicit_globals,
        &origins,
    );
    try std.testing.expectEqual(@as(usize, 0), report.reference_scope_mismatch);
    try std.testing.expectEqual(@as(usize, 0), report.missing_binding);
    try std.testing.expectEqual(@as(usize, 0), report.missing_reference);
}

test "exact identity audit rejects generated catch symbols while their owner remains" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ast = Ast.init(allocator, "");
    defer ast.deinit();
    const name = try ast.addString("_caught");
    const binding = try makeTestIdentifierNode(&ast, .binding_identifier, name);
    const ref = try makeTestIdentifierNode(&ast, .identifier_reference, name);
    const body = try ast.addNode(.{ .tag = .block_statement, .span = name, .data = .{ .list = try ast.addNodeList(&.{ref}) } });
    const catch_clause = try ast.addNode(.{ .tag = .catch_clause, .span = name, .data = .{ .binary = .{ .left = binding, .right = body, .flags = 0 } } });
    const root = try ast.addListNode(.array_expression, name, try ast.addNodeList(&.{catch_clause}));
    const scopes = [_]Scope{
        .{ .parent = .none, .kind = .global, .is_strict = false },
        .{ .parent = @enumFromInt(0), .kind = .catch_clause, .is_strict = false },
        .{ .parent = @enumFromInt(1), .kind = .block, .is_strict = false },
    };
    var catch_names: std.StringHashMapUnmanaged(usize) = .empty;
    defer catch_names.deinit(allocator);
    try catch_names.put(allocator, "_caught", 0);
    const scope_maps = [_]std.StringHashMapUnmanaged(usize){ .empty, catch_names, .empty };
    const symbols = [_]Symbol{
        .{ .name = name, .scope_id = @enumFromInt(1), .kind = .catch_binding, .declaration_span = name, .reference_count = 1, .synthetic_name = "_caught" },
    };
    const symbol_ids = [_]?u32{ 0, 0, null, null };
    const references = [_]Reference{
        .{ .node_index = .none, .scope_id = @enumFromInt(1), .symbol_id = @enumFromInt(0), .flags = .{ .declare = true } },
        .{ .node_index = ref, .scope_id = @enumFromInt(1), .symbol_id = @enumFromInt(0), .flags = .{ .read = true } },
    };
    var scope_owner_map: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer scope_owner_map.deinit(allocator);
    try scope_owner_map.put(allocator, @intFromEnum(catch_clause), 1);
    try scope_owner_map.put(allocator, @intFromEnum(body), 2);
    const unresolved: std.AutoHashMapUnmanaged(u32, void) = .empty;
    const explicit_globals: std.AutoHashMapUnmanaged(u32, void) = .empty;
    const origins: std.AutoHashMapUnmanaged(u32, u32) = .empty;

    const report = try checkExact(
        allocator,
        &ast,
        root,
        0,
        &symbol_ids,
        &symbols,
        &scopes,
        &scope_maps,
        &scope_owner_map,
        &references,
        &.{},
        &.{},
        &unresolved,
        &explicit_globals,
        &origins,
    );
    try std.testing.expectEqual(@as(usize, 1), report.reference_scope_mismatch);
    try std.testing.expectEqual(@as(usize, 0), report.invisible_reference);
}

test "exact identity audit requires generated class and switch scopes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ast = Ast.init(allocator, "");
    defer ast.deinit();
    const span = try ast.addString("x");
    const discriminant = try ast.addNode(.{ .tag = .numeric_literal, .span = span, .data = .{ .none = 0 } });
    const no_cases = try ast.addNodeList(&.{});
    const switch_extra = try ast.addExtras(&.{ @intFromEnum(discriminant), no_cases.start, no_cases.len });
    const switch_node = try ast.addNode(.{
        .tag = .switch_statement,
        .span = span,
        .data = .{ .extra = switch_extra },
    });
    const class_extra = try ast.addExtras(&.{
        @intFromEnum(NodeIndex.none),
        @intFromEnum(NodeIndex.none),
        @intFromEnum(NodeIndex.none),
    });
    const class_node = try ast.addNode(.{
        .tag = .class_expression,
        .span = span,
        .data = .{ .extra = class_extra },
    });
    const list = try ast.addNodeList(&.{ switch_node, class_node });
    const root = try ast.addNode(.{
        .tag = .block_statement,
        .span = span,
        .data = .{ .list = list },
    });
    const scopes = [_]Scope{
        .{ .parent = .none, .kind = .global, .is_strict = false },
        .{ .parent = @enumFromInt(0), .kind = .block, .is_strict = false },
    };
    const scope_maps = [_]std.StringHashMapUnmanaged(usize){ .empty, .empty };
    var scope_owner_map: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer scope_owner_map.deinit(allocator);
    try scope_owner_map.put(allocator, @intFromEnum(root), 1);
    const unresolved: std.AutoHashMapUnmanaged(u32, void) = .empty;
    const explicit_globals: std.AutoHashMapUnmanaged(u32, void) = .empty;
    const origins: std.AutoHashMapUnmanaged(u32, u32) = .empty;

    const report = try checkExact(
        allocator,
        &ast,
        root,
        0,
        &.{},
        &.{},
        &scopes,
        &scope_maps,
        &scope_owner_map,
        &.{},
        &.{},
        &.{},
        &unresolved,
        &explicit_globals,
        &origins,
    );
    try std.testing.expectEqual(@as(usize, 2), report.scope_owner_mismatch);
    try std.testing.expect(!report.isClean());
}

test "exact identity audit rejects appended scopes without a reachable AST owner" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ast = Ast.init(allocator, "");
    defer ast.deinit();
    const empty_list = try ast.addNodeList(&.{});
    const statement = try ast.addNode(.{
        .tag = .empty_statement,
        .span = .EMPTY,
        .data = .{ .none = 0 },
    });
    const root_list = try ast.addNodeList(&.{statement});
    const root = try ast.addNode(.{
        .tag = .block_statement,
        .span = .EMPTY,
        .data = .{ .list = root_list },
    });
    const stale_owner = try ast.addNode(.{
        .tag = .block_statement,
        .span = .EMPTY,
        .data = .{ .list = empty_list },
    });
    const generated_name = try ast.addString("generated");
    const scopes = [_]Scope{
        .{ .parent = .none, .kind = .block, .is_strict = false },
        .{ .parent = @enumFromInt(0), .kind = .block, .is_strict = false },
    };
    var generated_scope_map: std.StringHashMapUnmanaged(usize) = .empty;
    try generated_scope_map.put(allocator, ast.getText(generated_name), 0);
    const scope_maps = [_]std.StringHashMapUnmanaged(usize){ .empty, generated_scope_map };
    const symbols = [_]Symbol{
        .{ .name = generated_name, .scope_id = @enumFromInt(1), .kind = .variable_let, .declaration_span = generated_name },
    };
    var scope_owner_map: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer scope_owner_map.deinit(allocator);
    try scope_owner_map.put(allocator, @intFromEnum(root), 0);
    const unresolved: std.AutoHashMapUnmanaged(u32, void) = .empty;
    const explicit_globals: std.AutoHashMapUnmanaged(u32, void) = .empty;
    const origins: std.AutoHashMapUnmanaged(u32, u32) = .empty;

    const missing_owner = try checkExactWithScopeBoundary(
        allocator,
        &ast,
        root,
        3,
        &.{},
        &symbols,
        &scopes,
        &scope_maps,
        &scope_owner_map,
        &.{},
        &.{},
        &.{},
        &unresolved,
        &explicit_globals,
        &origins,
        1,
    );
    try std.testing.expectEqual(@as(usize, 1), missing_owner.scope_owner_mismatch);
    try std.testing.expectEqualStrings("generated-scope-owner-unreachable", missing_owner.first_scope_owner_mismatch.?.issue);
    try std.testing.expect(!missing_owner.isClean());

    // A stale mapping to an AST node removed from the root is not ownership
    // evidence for a transform-created scope.
    try scope_owner_map.put(allocator, @intFromEnum(stale_owner), 1);
    const stale_mapping = try checkExactWithScopeBoundary(
        allocator,
        &ast,
        root,
        3,
        &.{},
        &symbols,
        &scopes,
        &scope_maps,
        &scope_owner_map,
        &.{},
        &.{},
        &.{},
        &unresolved,
        &explicit_globals,
        &origins,
        1,
    );
    try std.testing.expectEqual(@as(usize, 1), stale_mapping.scope_owner_mismatch);
    try std.testing.expect(!stale_mapping.isClean());

    // A reachable non-scope AST node is not a valid owner either.
    try scope_owner_map.put(allocator, @intFromEnum(statement), 1);
    const wrong_owner_kind = try checkExactWithScopeBoundary(
        allocator,
        &ast,
        root,
        3,
        &.{},
        &symbols,
        &scopes,
        &scope_maps,
        &scope_owner_map,
        &.{},
        &.{},
        &.{},
        &unresolved,
        &explicit_globals,
        &origins,
        1,
    );
    try std.testing.expect(wrong_owner_kind.scope_owner_mismatch >= 1);
    try std.testing.expect(!wrong_owner_kind.isClean());
}

test "exact identity audit excludes statement labels from variable references" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ast = Ast.init(allocator, "");
    defer ast.deinit();
    const label_span = try ast.addString("outer");
    const label = try makeTestIdentifierNode(&ast, .identifier_reference, label_span);
    const break_node = try ast.addNode(.{
        .tag = .break_statement,
        .span = label_span,
        .data = .{ .unary = .{ .operand = label, .flags = 0 } },
    });
    const continue_label = try makeTestIdentifierNode(&ast, .identifier_reference, label_span);
    const continue_node = try ast.addNode(.{
        .tag = .continue_statement,
        .span = label_span,
        .data = .{ .unary = .{ .operand = continue_label, .flags = 0 } },
    });
    const labeled_name = try makeTestIdentifierNode(&ast, .identifier_reference, label_span);
    const empty_statement = try ast.addNode(.{
        .tag = .empty_statement,
        .span = label_span,
        .data = .{ .none = 0 },
    });
    const labeled_statement = try ast.addNode(.{
        .tag = .labeled_statement,
        .span = label_span,
        .data = .{ .binary = .{ .left = labeled_name, .right = empty_statement, .flags = 0 } },
    });
    const list = try ast.addNodeList(&.{ break_node, continue_node, labeled_statement });
    const root = try ast.addNode(.{
        .tag = .block_statement,
        .span = label_span,
        .data = .{ .list = list },
    });
    const scopes = [_]Scope{
        .{ .parent = .none, .kind = .global, .is_strict = false },
        .{ .parent = @enumFromInt(0), .kind = .block, .is_strict = false },
    };
    const scope_maps = [_]std.StringHashMapUnmanaged(usize){ .{}, .{} };
    var scope_owner_map: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer scope_owner_map.deinit(allocator);
    try scope_owner_map.put(allocator, @intFromEnum(root), 1);
    const unresolved: std.AutoHashMapUnmanaged(u32, void) = .empty;
    const explicit_globals: std.AutoHashMapUnmanaged(u32, void) = .empty;
    const origins: std.AutoHashMapUnmanaged(u32, u32) = .empty;

    const report = try checkExact(
        allocator,
        &ast,
        root,
        0,
        &.{},
        &.{},
        &scopes,
        &scope_maps,
        &scope_owner_map,
        &.{},
        &.{},
        &.{},
        &unresolved,
        &explicit_globals,
        &origins,
    );
    try std.testing.expectEqual(@as(usize, 0), report.missing_binding);
    try std.testing.expectEqual(@as(usize, 0), report.unclassified_reference);
    try std.testing.expect(report.isClean());
}

test "exact identity audit checks JSX component roots and skips intrinsic, property, and attribute names" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ast = Ast.init(allocator, "");
    defer ast.deinit();
    const lower_root_name = try ast.addString("component");
    const lower_root = try makeTestIdentifierNode(&ast, .jsx_identifier, lower_root_name);
    const member_name = try ast.addString("Panel");
    const member = try makeTestIdentifierNode(&ast, .jsx_identifier, member_name);
    const member_expr = try ast.addNode(.{
        .tag = .jsx_member_expression,
        .span = lower_root_name,
        .data = .{ .binary = .{ .left = lower_root, .right = member, .flags = 0 } },
    });
    const intrinsic_name = try ast.addString("div");
    const intrinsic = try makeTestIdentifierNode(&ast, .jsx_identifier, intrinsic_name);
    const attribute_name = try ast.addString("Component");
    const attribute = try makeTestIdentifierNode(&ast, .jsx_identifier, attribute_name);
    const attribute_node = try ast.addNode(.{
        .tag = .jsx_attribute,
        .span = attribute_name,
        .data = .{ .binary = .{ .left = attribute, .right = .none, .flags = 0 } },
    });
    const list = try ast.addNodeList(&.{ member_expr, intrinsic, attribute_node });
    const root = try ast.addNode(.{
        .tag = .block_statement,
        .span = lower_root_name,
        .data = .{ .list = list },
    });
    const scopes = [_]Scope{.{ .parent = .none, .kind = .global, .is_strict = false }};
    const scope_maps = [_]std.StringHashMapUnmanaged(usize){.empty};
    const symbols: []const Symbol = &.{};
    const references: []const Reference = &.{};
    const scope_owner_map: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    const unresolved: std.AutoHashMapUnmanaged(u32, void) = .empty;
    const explicit_globals: std.AutoHashMapUnmanaged(u32, void) = .empty;
    const origins: std.AutoHashMapUnmanaged(u32, u32) = .empty;

    const report = try checkExact(
        allocator,
        &ast,
        root,
        0,
        &.{},
        symbols,
        &scopes,
        &scope_maps,
        &scope_owner_map,
        references,
        &.{},
        &.{},
        &unresolved,
        &explicit_globals,
        &origins,
    );
    try std.testing.expectEqual(@as(usize, 1), report.generated_references);
    try std.testing.expectEqual(@as(usize, 1), report.unclassified_reference);
}

test "exact identity audit requires node provenance for external references and IDs for bindings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ast = Ast.init(allocator, "");
    defer ast.deinit();
    const global_name = try ast.addString("Object");
    const source_global = try makeTestIdentifierNode(&ast, .identifier_reference, global_name);
    const copied_global = try makeTestIdentifierNode(&ast, .identifier_reference, global_name);
    const explicit_global = try makeTestIdentifierNode(&ast, .identifier_reference, global_name);
    const unproven_global = try makeTestIdentifierNode(&ast, .identifier_reference, global_name);
    const synthetic_name = try ast.addString("_temp");
    const unbound_binding = try makeTestIdentifierNode(&ast, .binding_identifier, synthetic_name);
    const different_global_name = try ast.addString("DifferentGlobal");
    const different_global = try makeTestIdentifierNode(&ast, .identifier_reference, different_global_name);
    const list = try ast.addNodeList(&.{ source_global, copied_global, explicit_global, unproven_global, unbound_binding, different_global });
    const root = try ast.addNode(.{
        .tag = .block_statement,
        .span = global_name,
        .data = .{ .list = list },
    });
    const symbols: []const Symbol = &.{};
    const symbol_ids = [_]?u32{ null, null, null, null, null, null };
    const scopes = [_]Scope{.{ .parent = .none, .kind = .block, .is_strict = false }};
    const scope_maps = [_]std.StringHashMapUnmanaged(usize){.empty};
    const references: []const Reference = &.{};
    var unresolved: std.AutoHashMapUnmanaged(u32, void) = .empty;
    try unresolved.put(allocator, @intFromEnum(source_global), {});
    var explicit_globals: std.AutoHashMapUnmanaged(u32, void) = .empty;
    try explicit_globals.put(allocator, @intFromEnum(explicit_global), {});
    var origins: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    try origins.put(allocator, @intFromEnum(copied_global), @intFromEnum(source_global));
    try origins.put(allocator, @intFromEnum(different_global), @intFromEnum(source_global));
    var scope_owner_map: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer scope_owner_map.deinit(allocator);
    try scope_owner_map.put(allocator, @intFromEnum(root), 0);
    const helper_refs: []const u32 = &.{};
    const helper_scopes: std.StringHashMapUnmanaged(usize) = .empty;

    const report = try checkExact(
        allocator,
        &ast,
        root,
        1,
        &symbol_ids,
        symbols,
        &scopes,
        &scope_maps,
        &scope_owner_map,
        references,
        helper_refs,
        &helper_scopes,
        &unresolved,
        &explicit_globals,
        &origins,
    );
    try std.testing.expectEqual(@as(usize, 3), report.external_references);
    try std.testing.expectEqual(@as(usize, 2), report.unclassified_reference);
    try std.testing.expectEqual(@as(usize, 1), report.missing_binding);
    try std.testing.expect(!report.isClean());
}

test "post-minify audit accepts an alias read rebound to a surviving binding" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var ast = Ast.init(allocator, "");
    defer ast.deinit();

    const name = try ast.addString("parameter");
    const binding = try makeTestIdentifierNode(&ast, .binding_identifier, name);
    const reference = try makeTestIdentifierNode(&ast, .identifier_reference, name);
    const list = try ast.addNodeList(&.{ binding, reference });
    const root = try ast.addNode(.{ .tag = .block_statement, .span = name, .data = .{ .list = list } });
    var actual = [_]?u32{ 7, 7, null };
    var resolved = [_]?u32{ 2, 2, null };
    actual[@intFromEnum(binding)] = 7;
    actual[@intFromEnum(reference)] = 7;
    resolved[@intFromEnum(binding)] = 2;
    resolved[@intFromEnum(reference)] = 2;

    const empty_helper_scope_map: std.StringHashMapUnmanaged(usize) = .empty;
    const empty_markers: std.AutoHashMapUnmanaged(u32, void) = .empty;
    const empty_class_symbols: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    const report = try checkPostMinify(allocator, &ast, root, &actual, &resolved, &.{}, &.{}, &.{}, &.{}, &empty_helper_scope_map, &empty_markers, &empty_class_symbols, &empty_class_symbols);
    try std.testing.expect(report.isClean());
    try std.testing.expectEqual(@as(usize, 1), report.bindings_checked);
    try std.testing.expectEqual(@as(usize, 1), report.references_checked);
}

test "post-minify audit ignores symbol-bearing static keys but checks property values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var ast = Ast.init(allocator, "");
    defer ast.deinit();

    const name = try ast.addString("value");
    const binding = try makeTestIdentifierNode(&ast, .binding_identifier, name);
    const key = try makeTestIdentifierNode(&ast, .identifier_reference, name);
    const value = try makeTestIdentifierNode(&ast, .identifier_reference, name);
    const property = try ast.addNode(.{
        .tag = .object_property,
        .span = name,
        .data = .{ .binary = .{ .left = key, .right = value, .flags = 0 } },
    });
    const properties = try ast.addNodeList(&.{property});
    const object = try ast.addNode(.{
        .tag = .object_expression,
        .span = name,
        .data = .{ .list = properties },
    });
    const statements = try ast.addNodeList(&.{ binding, object });
    const root = try ast.addNode(.{
        .tag = .block_statement,
        .span = name,
        .data = .{ .list = statements },
    });

    var actual = [_]?u32{ 7, 7, 7, null, null, null };
    var resolved = [_]?u32{ 2, null, 2, null, null, null };
    const empty_helper_scope_map: std.StringHashMapUnmanaged(usize) = .empty;
    const empty_markers: std.AutoHashMapUnmanaged(u32, void) = .empty;
    const empty_class_symbols: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    var report = try checkPostMinify(
        allocator,
        &ast,
        root,
        &actual,
        &resolved,
        &.{},
        &.{},
        &.{},
        &.{},
        &empty_helper_scope_map,
        &empty_markers,
        &empty_class_symbols,
        &empty_class_symbols,
    );
    try std.testing.expect(report.isClean());
    try std.testing.expectEqual(@as(usize, 1), report.references_checked);

    actual[@intFromEnum(value)] = null;
    report = try checkPostMinify(
        allocator,
        &ast,
        root,
        &actual,
        &resolved,
        &.{},
        &.{},
        &.{},
        &.{},
        &empty_helper_scope_map,
        &empty_markers,
        &empty_class_symbols,
        &empty_class_symbols,
    );
    try std.testing.expectEqual(@as(usize, 1), report.missing_reference_id);
    try std.testing.expect(!report.isClean());

    // A bad value identity must still fail; skipping the static key must not
    // make the real property-value reference invisible to the gate.
    actual[@intFromEnum(value)] = 7;
    resolved[@intFromEnum(value)] = 3;
    report = try checkPostMinify(
        allocator,
        &ast,
        root,
        &actual,
        &resolved,
        &.{},
        &.{},
        &.{},
        &.{},
        &empty_helper_scope_map,
        &empty_markers,
        &empty_class_symbols,
        &empty_class_symbols,
    );
    try std.testing.expectEqual(@as(usize, 1), report.wrong_reference_target);
    try std.testing.expect(!report.isClean());
}

test "post-minify audit rejects a reference to an erased alias symbol" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var ast = Ast.init(allocator, "");
    defer ast.deinit();

    const name = try ast.addString("parameter");
    const binding = try makeTestIdentifierNode(&ast, .binding_identifier, name);
    const reference = try makeTestIdentifierNode(&ast, .identifier_reference, name);
    const list = try ast.addNodeList(&.{ binding, reference });
    const root = try ast.addNode(.{ .tag = .block_statement, .span = name, .data = .{ .list = list } });
    var actual = [_]?u32{ 7, 9, null };
    var resolved = [_]?u32{ 2, 2, null };
    actual[@intFromEnum(binding)] = 7;
    actual[@intFromEnum(reference)] = 9;
    resolved[@intFromEnum(binding)] = 2;
    resolved[@intFromEnum(reference)] = 2;

    const empty_helper_scope_map: std.StringHashMapUnmanaged(usize) = .empty;
    const empty_markers: std.AutoHashMapUnmanaged(u32, void) = .empty;
    const empty_class_symbols: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    const report = try checkPostMinify(allocator, &ast, root, &actual, &resolved, &.{}, &.{}, &.{}, &.{}, &empty_helper_scope_map, &empty_markers, &empty_class_symbols, &empty_class_symbols);
    try std.testing.expectEqual(@as(usize, 1), report.dangling_reference_id);
    try std.testing.expect(!report.isClean());
}

test "post-minify audit rejects a reference mapped to the wrong shadowed binding" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var ast = Ast.init(allocator, "");
    defer ast.deinit();

    const name = try ast.addString("x");
    const outer = try makeTestIdentifierNode(&ast, .binding_identifier, name);
    const inner = try makeTestIdentifierNode(&ast, .binding_identifier, name);
    const reference = try makeTestIdentifierNode(&ast, .identifier_reference, name);
    const list = try ast.addNodeList(&.{ outer, inner, reference });
    const root = try ast.addNode(.{ .tag = .block_statement, .span = name, .data = .{ .list = list } });
    var actual = [_]?u32{ 3, 4, 3, null };
    var resolved = [_]?u32{ 10, 11, 11, null };
    actual[@intFromEnum(outer)] = 3;
    actual[@intFromEnum(inner)] = 4;
    actual[@intFromEnum(reference)] = 3;
    resolved[@intFromEnum(outer)] = 10;
    resolved[@intFromEnum(inner)] = 11;
    resolved[@intFromEnum(reference)] = 11;

    const empty_helper_scope_map: std.StringHashMapUnmanaged(usize) = .empty;
    const empty_markers: std.AutoHashMapUnmanaged(u32, void) = .empty;
    const empty_class_symbols: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    const report = try checkPostMinify(allocator, &ast, root, &actual, &resolved, &.{}, &.{}, &.{}, &.{}, &empty_helper_scope_map, &empty_markers, &empty_class_symbols, &empty_class_symbols);
    try std.testing.expectEqual(@as(usize, 1), report.wrong_reference_target);
    try std.testing.expect(!report.isClean());
}

test "post-minify audit rejects a helper reference shadowed by a source binding" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var ast = Ast.init(allocator, "");
    defer ast.deinit();

    const name = try ast.addString("helper");
    const local_binding = try makeTestIdentifierNode(&ast, .binding_identifier, name);
    const helper_reference = try makeTestIdentifierNode(&ast, .identifier_reference, name);
    const root = try ast.addNode(.{
        .tag = .block_statement,
        .span = name,
        .data = .{ .list = try ast.addNodeList(&.{ local_binding, helper_reference }) },
    });

    // The transform graph says this reference targets the injected helper
    // (SID 0), while a fresh resolution of the emitted spelling targets the
    // same-name source binding (SID 1). The helper fast path must not hide the
    // changed lexical target.
    const actual = [_]?u32{ 1, 0, null };
    const resolved = [_]?u32{ 1, 1, null };
    const symbols = [_]Symbol{
        .{ .name = name, .scope_id = @enumFromInt(0), .kind = .import_binding, .declaration_span = name },
        .{ .name = name, .scope_id = @enumFromInt(0), .kind = .variable_let, .declaration_span = name },
    };
    var helper_scope_map: std.StringHashMapUnmanaged(usize) = .empty;
    defer helper_scope_map.deinit(allocator);
    try helper_scope_map.put(allocator, "helper", 0);
    const helper_nodes = [_]u32{@intFromEnum(helper_reference)};
    const empty_markers: std.AutoHashMapUnmanaged(u32, void) = .empty;
    const empty_class_symbols: std.AutoHashMapUnmanaged(u32, u32) = .empty;

    const report = try checkPostMinify(
        allocator,
        &ast,
        root,
        &actual,
        &resolved,
        &symbols,
        &symbols,
        &.{},
        &helper_nodes,
        &helper_scope_map,
        &empty_markers,
        &empty_class_symbols,
        &empty_class_symbols,
    );
    try std.testing.expectEqual(@as(usize, 1), report.wrong_reference_target);
    try std.testing.expect(!report.isClean());

    // The name-to-SID helper mapping also classifies an unmarked reference as
    // a helper. It must receive the same output-resolution check.
    const inferred_helper_report = try checkPostMinify(
        allocator,
        &ast,
        root,
        &actual,
        &resolved,
        &symbols,
        &symbols,
        &.{},
        &.{},
        &helper_scope_map,
        &empty_markers,
        &empty_class_symbols,
        &empty_class_symbols,
    );
    try std.testing.expectEqual(@as(usize, 1), inferred_helper_report.wrong_reference_target);
    try std.testing.expect(!inferred_helper_report.isClean());
}

test "post-minify audit distinguishes lexical reads from explicit globals" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var ast = Ast.init(allocator, "");
    defer ast.deinit();

    const name = try ast.addString("LocalName");
    const binding = try makeTestIdentifierNode(&ast, .binding_identifier, name);
    const reference = try makeTestIdentifierNode(&ast, .identifier_reference, name);
    const list = try ast.addNodeList(&.{ binding, reference });
    const root = try ast.addNode(.{ .tag = .block_statement, .span = name, .data = .{ .list = list } });
    var actual = [_]?u32{ 7, 7, null };
    var resolved = [_]?u32{ 2, 2, null };
    actual[@intFromEnum(binding)] = 7;
    actual[@intFromEnum(reference)] = 7;
    resolved[@intFromEnum(binding)] = 2;
    resolved[@intFromEnum(reference)] = 2;
    var explicit_globals: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer explicit_globals.deinit(allocator);
    try explicit_globals.put(allocator, @intFromEnum(reference), {});

    const empty_helper_scope_map: std.StringHashMapUnmanaged(usize) = .empty;
    const empty_class_symbols: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    var report = try checkPostMinify(
        allocator,
        &ast,
        root,
        &actual,
        &resolved,
        &.{},
        &.{},
        &.{},
        &.{},
        &empty_helper_scope_map,
        &explicit_globals,
        &empty_class_symbols,
        &empty_class_symbols,
    );
    try std.testing.expect(report.isClean());
    try std.testing.expectEqual(@as(usize, 0), report.external_references);

    // The same provenance marker can describe a true generated global when no
    // SymbolId was attached; it must remain external even if analysis finds a
    // same-named source binding before the mangler renames that binding away.
    actual[@intFromEnum(reference)] = null;
    report = try checkPostMinify(
        allocator,
        &ast,
        root,
        &actual,
        &resolved,
        &.{},
        &.{},
        &.{},
        &.{},
        &empty_helper_scope_map,
        &explicit_globals,
        &empty_class_symbols,
        &empty_class_symbols,
    );
    try std.testing.expect(report.isClean());
    try std.testing.expectEqual(@as(usize, 1), report.external_references);
}
