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
const SyntheticKind = @import("../semantic/symbol.zig").SyntheticKind;
const Reference = @import("../semantic/symbol.zig").Reference;
const Scope = @import("../semantic/scope.zig").Scope;
const ScopeId = @import("../semantic/scope.zig").ScopeId;
const ScopeKind = @import("../semantic/scope.zig").ScopeKind;
const Span = @import("../lexer/token.zig").Span;
const Scanner = @import("../lexer/scanner.zig").Scanner;
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
        ctx.name_positions.put(ctx.allocator, @backingInt(idx), {}) catch {
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
            ctx.markName(@fromBackingInt(@intCast(ctx.ast.extra_data.items[node.data.extra + 1])));
            return .descend;
        },
        .object_property, .binding_property => {
            const k = node.data.binary.left;
            const v = node.data.binary.right;
            if (!v.isNone() and v != k) ctx.markName(k);
            return .descend;
        },
        .method_definition, .property_definition, .accessor_property => {
            ctx.markName(@fromBackingInt(@intCast(ctx.ast.extra_data.items[node.data.extra])));
            return .descend;
        },
        // 공용 순회는 export 지정자 목록으로 내려가지 않는다 — 로컬 export(`export { a as b }`)의
        // 로컬 쪽은 변수 참조라 직접 본다. 내보내는 이름(`b`)은 변수가 아니다.
        .export_named_declaration => {
            const e = node.data.extra;
            const source = ctx.ast.extra_data.items[e + 3];
            if (source != @backingInt(NodeIndex.none)) return .descend;
            const specs_start = ctx.ast.extra_data.items[e + 1];
            const specs_len = ctx.ast.extra_data.items[e + 2];
            for (ctx.ast.extra_data.items[specs_start .. specs_start + specs_len]) |raw| {
                const spec = ctx.ast.getNode(@fromBackingInt(@intCast(raw)));
                if (spec.tag != .export_specifier) continue;
                const local = spec.data.binary.left;
                if (local.isNone()) continue;
                if (local != spec.data.binary.right) ctx.markName(spec.data.binary.right);
                _ = checkIdentifier(ctx, local, ctx.ast.getNode(local));
            }
            return .descend;
        },
        .export_all_declaration => {
            const extra = node.data.extra;
            if (extra <= ctx.ast.extra_data.items.len and
                ctx.ast.extra_data.items.len - extra >= 4)
            {
                const exported_name: NodeIndex = @fromBackingInt(
                    @intCast(ctx.ast.extra_data.items[extra]),
                );
                if (!exported_name.isNone() and @backingInt(exported_name) < ctx.ast.nodes.items.len)
                    ctx.markName(exported_name);
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
    const i = @backingInt(idx);
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
    /// Live transform-created scopes whose AST owner is reachable and valid.
    generated_scope_owners_checked: usize = 0,
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
    declaration_identity_mismatch: usize = 0,
    declaration_anchor_mismatch: usize = 0,
    declaration_anchors_checked: usize = 0,
    scope_map_mismatch: usize = 0,
    scope_owner_mismatch: usize = 0,
    scope_owner_parent_mismatch: usize = 0,
    duplicate_scope_owner: usize = 0,
    scope_strictness_mismatch: usize = 0,
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
    first_declaration_anchor_mismatch: ?ExactFinding = null,
    first_unclassified_reference: ?ExactFinding = null,
    first_scope_owner_mismatch: ?ScopeOwnerFinding = null,
    first_scope_owner_parent_mismatch: ?ScopeOwnerFinding = null,
    first_duplicate_scope_owner: ?ScopeOwnerFinding = null,
    first_scope_strictness_mismatch: ?ScopeStrictnessFinding = null,
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
            std.mem.eql(u8, name, "generated_scope_owners_checked") or
            std.mem.eql(u8, name, "external_references") or
            std.mem.eql(u8, name, "declaration_anchors_checked") or
            std.mem.eql(u8, name, "namespace_iife_params") or
            std.mem.eql(u8, name, "enum_iife_params") or
            std.mem.eql(u8, name, "legacy_debt_fingerprint");
    }

    fn isDiagnosticField(comptime name: []const u8) bool {
        @setEvalBranchQuota(4000);
        return std.mem.eql(u8, name, "first_missing_binding") or
            std.mem.eql(u8, name, "first_missing_reference") or
            std.mem.eql(u8, name, "first_declaration_anchor_mismatch") or
            std.mem.eql(u8, name, "first_unclassified_reference") or
            std.mem.eql(u8, name, "first_scope_owner_mismatch") or
            std.mem.eql(u8, name, "first_scope_owner_parent_mismatch") or
            std.mem.eql(u8, name, "first_duplicate_scope_owner") or
            std.mem.eql(u8, name, "first_scope_strictness_mismatch") or
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
        const info = @typeInfo(ExactReport).@"struct";
        inline for (info.field_names, info.field_types) |name, field_type| {
            if (comptime isObservationField(name)) {
                if (comptime std.mem.eql(u8, name, "legacy_debt_fingerprint")) {
                    if (comptime field_type != u64) @compileError("ExactReport legacy fingerprint must remain u64");
                } else if (comptime field_type != usize) {
                    @compileError("ExactReport observation fields must remain usize except the legacy fingerprint");
                }
                counts.observation_fields += 1;
            } else if (comptime isDiagnosticField(name)) {
                if (comptime @typeInfo(field_type) != .optional)
                    @compileError("ExactReport diagnostic fields must remain optional findings");
                counts.diagnostic_fields += 1;
            } else {
                if (comptime field_type != usize) @compileError("unclassified ExactReport field");
                counts.invariant_counters += 1;
            }
        }
        return counts;
    }

    /// Stable schema signature pinned independently by the integration gate.
    /// Counts alone cannot detect one diagnostic field replacing another.
    pub fn schemaFingerprint() u64 {
        var hash: u64 = 0xcbf29ce484222325;
        feedSchemaFingerprint(&hash, "zntc.ExactReport/v1\x00");
        const info = @typeInfo(ExactReport).@"struct";
        inline for (info.field_names) |name| {
            const category = if (comptime isObservationField(name))
                "observation"
            else if (comptime isDiagnosticField(name))
                "diagnostic"
            else
                "invariant";
            feedSchemaFingerprint(&hash, name);
            feedSchemaFingerprint(&hash, "\x00");
            feedSchemaFingerprint(&hash, category);
            feedSchemaFingerprint(&hash, "\n");
        }
        return hash;
    }

    /// Observations are allowed to be nonzero. Every other numeric field is
    /// an invariant counter and fails closed by default, so adding a new
    /// counter cannot silently leave the aggregate exact-coverage gate green.
    pub fn isClean(self: ExactReport) bool {
        const info = @typeInfo(ExactReport).@"struct";
        inline for (info.field_names, info.field_types) |name, field_type| {
            if (comptime isObservationField(name)) continue;
            if (comptime isDiagnosticField(name)) {
                if (@field(self, name) != null) return false;
                continue;
            }
            if (comptime field_type != usize) @compileError("unclassified ExactReport field; classify it as an observation, diagnostic, or usize invariant counter");
            if (@field(self, name) != 0) return false;
        }
        return true;
    }
};

fn feedSchemaFingerprint(hash: *u64, bytes: []const u8) void {
    for (bytes) |byte| {
        hash.* ^= byte;
        hash.* *%= 0x100000001b3;
    }
}

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

pub const ScopeStrictnessFinding = struct {
    scope_id: u32,
    parent_scope_id: ?u32 = null,
    issue: []const u8,
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
    enum_prelude_kind,
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
            if (node.tag == .ts_enum_declaration) {
                const prelude = ast.readExtraNode(node.data.extra, ast_mod.EnumExtra.runtime_prelude);
                if (!prelude.isNone() and @backingInt(prelude) < ast.nodes.items.len and ast.getNode(prelude).tag != .block_statement) return .{
                    .node_index = node_index,
                    .tag = node.tag,
                    .issue = .enum_prelude_kind,
                    .data_index = base + ast_mod.EnumExtra.runtime_prelude,
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

fn recordScopeStrictnessMismatch(
    report: *ExactReport,
    scope_id: u32,
    parent_scope_id: ?u32,
    issue: []const u8,
) void {
    report.scope_strictness_mismatch += 1;
    if (report.first_scope_strictness_mismatch == null) report.first_scope_strictness_mismatch = .{
        .scope_id = scope_id,
        .parent_scope_id = parent_scope_id,
        .issue = issue,
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
    const name_node: NodeIndex = @fromBackingInt(@intCast(ast.extra_data.items[extra]));
    if (name_node.isNone() or @backingInt(name_node) >= ast.nodes.items.len or
        @backingInt(name_node) >= symbol_ids.len) return false;
    const name = ast.getNode(name_node);
    if (name.tag != .binding_identifier) return false;
    const symbol_id = symbol_ids[@backingInt(name_node)] orelse return false;
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
            @fromBackingInt(@intCast(expected_parent_scope)),
            symbol_ids,
            symbols,
            scopes,
            scope_maps,
        )) {
            parent = scopes[parent_id].parent;
            continue;
        }
        if (functionParameterNode(ast, owner_node)) |params_node| {
            if (scope_owner_map.get(params_node) == @as(?u32, parent_id)) {
                parent = scopes[parent_id].parent;
                continue;
            }
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

fn functionParameterNode(ast: *const Ast, function_raw: u32) ?u32 {
    if (function_raw >= ast.nodes.items.len) return null;
    const function = ast.nodes.items[function_raw];
    const slot: u32 = switch (function.tag) {
        .arrow_function_expression => 0,
        .function_declaration, .function_expression, .function, .method_definition => 1,
        else => return null,
    };
    if (!ast.hasExtra(function.data.extra, slot)) return null;
    const raw = ast.extra_data.items[function.data.extra + slot];
    if (raw == @backingInt(NodeIndex.none) or raw >= ast.nodes.items.len) return null;
    return raw;
}

fn parameterScopeFunctionOwner(
    ast: *const Ast,
    parent_by_node: *const std.AutoHashMapUnmanaged(u32, u32),
    params_raw: u32,
) ?u32 {
    const function_raw = parent_by_node.get(params_raw) orelse return null;
    if (functionParameterNode(ast, function_raw) == params_raw) return function_raw;
    return null;
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

fn exactScopeMapKeyMatchesSymbol(ast: *const Ast, symbol: *const Symbol, map_key: []const u8) bool {
    const source_name = exactSymbolName(ast, symbol);
    if (std.mem.eql(u8, map_key, source_name)) return true;
    if (std.mem.indexOfScalar(u8, source_name, '\\') == null) return false;

    // Semantic scope maps keep both source spelling and the decoded identifier
    // key. The exact audit must accept those two spellings for the same SymbolId.
    const decoded_name = Scanner.decodeIdentifierEscapesAlloc(ast.allocator, source_name) catch return false;
    defer if (decoded_name.ptr != source_name.ptr) ast.allocator.free(decoded_name);
    return std.mem.eql(u8, map_key, decoded_name);
}

test "exact scope-map audit accepts only source and decoded escaped names" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ast = Ast.init(allocator, "");
    defer ast.deinit();
    const raw_name = try ast.addString("\\u006cocalName");
    const symbol: Symbol = .{
        .name = raw_name,
        .scope_id = .none,
        .kind = .variable_let,
        .declaration_span = raw_name,
    };

    try std.testing.expect(exactScopeMapKeyMatchesSymbol(&ast, &symbol, "\\u006cocalName"));
    try std.testing.expect(exactScopeMapKeyMatchesSymbol(&ast, &symbol, "localName"));
    try std.testing.expect(!exactScopeMapKeyMatchesSymbol(&ast, &symbol, "otherName"));

    const long_raw_name = try allocator.alloc(u8, 6 * 300);
    for (0..300) |index| {
        @memcpy(long_raw_name[index * 6 ..][0..6], "\\u0061");
    }
    const long_name_span = try ast.addString(long_raw_name);
    const long_symbol: Symbol = .{
        .name = long_name_span,
        .scope_id = .none,
        .kind = .variable_let,
        .declaration_span = long_name_span,
    };
    const decoded_long_name = try allocator.alloc(u8, 300);
    @memset(decoded_long_name, 'a');
    try std.testing.expect(exactScopeMapKeyMatchesSymbol(&ast, &long_symbol, decoded_long_name));
}

const ExactCjsWrapperBindings = struct {
    scope_id: u32,
    exports_symbol_id: u32,
    module_symbol_id: u32,
};

/// Bundling a parsed CommonJS Program gives its original body scope a virtual
/// callback parent. Accept that one parentless function scope only when its
/// two exact parameter identities and owner shape match the linker contract.
fn exactCjsWrapperBindings(
    ast: *const Ast,
    root: NodeIndex,
    symbols: []const Symbol,
    scopes: []const Scope,
    scope_maps: []const std.StringHashMapUnmanaged(usize),
    scope_owner_map: *const std.AutoHashMapUnmanaged(u32, u32),
) ?ExactCjsWrapperBindings {
    if (root.isNone() or @backingInt(root) >= ast.nodes.items.len or ast.nodes.items[@backingInt(root)].tag != .program)
        return null;
    if (scopes.len < 2 or scope_maps.len != scopes.len or scope_maps.len == 0) return null;
    if (scope_owner_map.get(@backingInt(root)) != 0) return null;

    const wrapper_id = scopes[0].parent;
    if (!exactValidScope(scopes, wrapper_id) or wrapper_id.toIndex() == 0) return null;
    const wrapper_raw = wrapper_id.toIndex();
    const wrapper_scope = scopes[wrapper_raw];
    if (wrapper_scope.kind != .function or !wrapper_scope.parent.isNone() or wrapper_scope.symbol_count != 2)
        return null;
    if (scopeOwnerNode(scope_owner_map, wrapper_raw) != null) return null;

    const wrapper_map = scope_maps[wrapper_raw];
    if (wrapper_map.count() != 2) return null;
    const exports_id = wrapper_map.get("exports") orelse return null;
    const module_id = wrapper_map.get("module") orelse return null;
    if (exports_id == module_id or exports_id >= symbols.len or module_id >= symbols.len) return null;

    const params = .{
        .{ .id = exports_id, .name = "exports", .kind = SyntheticKind.cjs_wrapper_exports_parameter },
        .{ .id = module_id, .name = "module", .kind = SyntheticKind.cjs_wrapper_module_parameter },
    };
    inline for (params) |param| {
        const symbol = symbols[param.id];
        if (symbol.scope_id != wrapper_id or symbol.kind != .parameter or !symbol.decl_flags.is_parameter or
            symbol.synthetic_kind != param.kind or symbol.synthetic_name.len == 0 or
            !std.mem.eql(u8, exactSymbolName(ast, &symbol), param.name)) return null;
    }

    return .{
        .scope_id = wrapper_raw,
        .exports_symbol_id = @intCast(exports_id),
        .module_symbol_id = @intCast(module_id),
    };
}

/// Graph-wide runtime identities are intentionally outside a module's lexical
/// scope tree. Keep this exception to the exact output-owned synthetic kinds,
/// and reject them if they acquire any source AST or lexical-scope edge.
fn exactDetachedOutputSymbolShape(symbol: *const Symbol) bool {
    if (symbol.synthetic_name.len == 0) return false;
    const kind = symbol.synthetic_kind orelse return false;
    return switch (kind) {
        .cjs_runtime_factory => symbol.kind == .variable_var and std.mem.eql(u8, symbol.synthetic_name, "__commonJS"),
        .cjs_runtime_internal_local => switch (symbol.kind) {
            .variable_var, .function_decl, .parameter, .catch_binding => true,
            else => false,
        },
        .esm_runtime_internal_local => switch (symbol.kind) {
            .parameter => std.mem.eql(u8, symbol.synthetic_name, "fn") or std.mem.eql(u8, symbol.synthetic_name, "res"),
            .catch_binding => std.mem.eql(u8, symbol.synthetic_name, "e"),
            .function_decl => std.mem.eql(u8, symbol.synthetic_name, "__init"),
            .variable_var => std.mem.eql(u8, symbol.synthetic_name, "f"),
            else => false,
        },
        .esm_interop_runtime_internal_local => switch (symbol.kind) {
            .parameter => std.mem.eql(u8, symbol.synthetic_name, "copy_props.to") or
                std.mem.eql(u8, symbol.synthetic_name, "copy_props.from") or
                std.mem.eql(u8, symbol.synthetic_name, "copy_props.desc") or
                std.mem.eql(u8, symbol.synthetic_name, "copy_props.closure_key") or
                std.mem.eql(u8, symbol.synthetic_name, "to_esm.module") or
                std.mem.eql(u8, symbol.synthetic_name, "to_esm.node_mode") or
                std.mem.eql(u8, symbol.synthetic_name, "to_esm.target") or
                std.mem.eql(u8, symbol.synthetic_name, "export.target") or
                std.mem.eql(u8, symbol.synthetic_name, "export.all") or
                std.mem.eql(u8, symbol.synthetic_name, "to_common_js.module"),
            .variable_var => std.mem.eql(u8, symbol.synthetic_name, "copy_props.keys") or
                std.mem.eql(u8, symbol.synthetic_name, "copy_props.index") or
                std.mem.eql(u8, symbol.synthetic_name, "copy_props.key") or
                std.mem.eql(u8, symbol.synthetic_name, "export.name"),
            else => false,
        },
        .hmr_runtime_internal_local => switch (symbol.kind) {
            .variable_var => std.mem.eql(u8, symbol.synthetic_name, "hmr.global") or
                std.mem.eql(u8, symbol.synthetic_name, "hmr.modules") or
                std.mem.eql(u8, symbol.synthetic_name, "hmr.hot_callbacks") or
                std.mem.eql(u8, symbol.synthetic_name, "hmr.hot_data") or
                std.mem.eql(u8, symbol.synthetic_name, "hmr.reload") or
                std.mem.eql(u8, symbol.synthetic_name, "hmr.refresh_timer") or
                std.mem.eql(u8, symbol.synthetic_name, "hmr.original_commonjs") or
                std.mem.eql(u8, symbol.synthetic_name, "hmr.original_esm"),
            .function_decl => std.mem.eql(u8, symbol.synthetic_name, "hmr.schedule") or
                std.mem.eql(u8, symbol.synthetic_name, "hmr.resolve_refresh") or
                std.mem.eql(u8, symbol.synthetic_name, "hmr.refresh_boundary") or
                std.mem.eql(u8, symbol.synthetic_name, "hmr.enqueue_update") or
                std.mem.eql(u8, symbol.synthetic_name, "hmr.make_hot") or
                std.mem.eql(u8, symbol.synthetic_name, "hmr.apply_update"),
            else => false,
        },
        .require_shim_local => symbol.kind == .import_binding and std.mem.eql(u8, symbol.synthetic_name, "createRequire"),
        .esm_init, .cjs_require => symbol.kind == .function_decl,
        .cjs_exports, .bundler_runtime_helper => symbol.kind == .variable_var,
        else => false,
    };
}

fn exactDetachedOutputSymbolHasNoLexicalEdges(
    symbol_id: u32,
    symbol_ids: []const ?u32,
    references: []const Reference,
    scope_maps: []const std.StringHashMapUnmanaged(usize),
) bool {
    for (symbol_ids) |mapped_symbol| {
        if (mapped_symbol == symbol_id) return false;
    }
    for (references) |reference| {
        if (@backingInt(reference.symbol_id) == symbol_id) return false;
    }
    for (scope_maps) |scope_map| {
        var bindings = scope_map.valueIterator();
        while (bindings.next()) |mapped_symbol| {
            if (mapped_symbol.* == symbol_id) return false;
        }
    }
    return true;
}

fn collectBindingPatternNodes(
    allocator: std.mem.Allocator,
    ast: *const Ast,
    root: NodeIndex,
    bindings: *std.AutoHashMapUnmanaged(u32, void),
) std.mem.Allocator.Error!void {
    if (root.isNone() or @backingInt(root) >= ast.nodes.items.len) return;
    var walker = try ast_walk.bindingIdentifiers(allocator, ast, root, .{ .cover_grammar_assignment = true });
    defer walker.deinit();
    while (try walker.next()) |idx| {
        const tag = ast.getNode(idx).tag;
        if (tag == .binding_identifier or tag == .identifier_reference or tag == .assignment_target_identifier)
            try bindings.put(allocator, @backingInt(idx), {});
    }
}

fn collectFlowMatchPatternDeclarations(
    allocator: std.mem.Allocator,
    ast: *const Ast,
    root: NodeIndex,
    bindings: *std.AutoHashMapUnmanaged(u32, void),
) std.mem.Allocator.Error!void {
    if (root.isNone() or @backingInt(root) >= ast.nodes.items.len) return;
    var stack: std.ArrayList(NodeIndex) = .empty;
    defer stack.deinit(allocator);
    try stack.append(allocator, root);
    while (stack.pop()) |idx| {
        if (idx.isNone() or @backingInt(idx) >= ast.nodes.items.len) continue;
        const raw = @backingInt(idx);
        const node = ast.nodes.items[raw];
        switch (node.tag) {
            .flow_match_binding_pattern => try bindings.put(allocator, raw, {}),
            .flow_match_rest => if (node.data.none != 0) try bindings.put(allocator, raw, {}),
            .flow_match_as_pattern => {
                try stack.append(allocator, node.data.binary.left);
                if (!node.data.binary.right.isNone())
                    try bindings.put(allocator, @backingInt(node.data.binary.right), {});
            },
            .flow_match_guard_pattern => try stack.append(allocator, node.data.binary.left),
            .flow_match_object_prop => try stack.append(allocator, node.data.binary.right),
            .flow_match_instance_pattern => try stack.append(allocator, node.data.binary.right),
            .flow_match_object_pattern, .flow_match_array_pattern => {
                var children = ast_walk.children(ast, node);
                while (children.next()) |child| try stack.append(allocator, child);
            },
            // The analyzer and current lowering deliberately do not bind
            // identifiers inside OR alternatives.
            .flow_match_or_pattern => {},
            else => {},
        }
    }
}

pub fn collectDeclarationNodes(
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
                    const name: NodeIndex = @fromBackingInt(@intCast(ast.extra_data.items[node.data.extra]));
                    if (!name.isNone()) try bindings.put(allocator, @backingInt(name), {});
                }
                if (ast.hasExtra(node.data.extra, 1)) {
                    const params: NodeIndex = @fromBackingInt(@intCast(ast.extra_data.items[node.data.extra + 1]));
                    try collectBindingPatternNodes(allocator, ast, params, &bindings);
                }
            },
            .arrow_function_expression, .method_definition => {
                const slot: u32 = if (node.tag == .arrow_function_expression) 0 else 1;
                if (ast.hasExtra(node.data.extra, slot)) {
                    const params: NodeIndex = @fromBackingInt(@intCast(ast.extra_data.items[node.data.extra + slot]));
                    try collectBindingPatternNodes(allocator, ast, params, &bindings);
                }
            },
            .class_declaration, .class_expression => {
                if (ast.hasExtra(node.data.extra, 0)) {
                    const name: NodeIndex = @fromBackingInt(@intCast(ast.extra_data.items[node.data.extra]));
                    if (!name.isNone()) try bindings.put(allocator, @backingInt(name), {});
                }
            },
            .ts_enum_declaration, .flow_enum_declaration => {
                if (ast.hasExtra(node.data.extra, 0)) {
                    const name: NodeIndex = @fromBackingInt(@intCast(ast.extra_data.items[node.data.extra]));
                    if (!name.isNone() and ast.getNode(name).tag == .binding_identifier) try bindings.put(allocator, @backingInt(name), {});
                }
            },
            .ts_module_declaration => {
                const name = node.data.binary.left;
                if (!name.isNone() and @backingInt(name) < ast.nodes.items.len and
                    ast.getNode(name).tag == .binding_identifier)
                    try bindings.put(allocator, @backingInt(name), {});
            },
            .ts_import_equals_declaration => {
                const name = node.data.binary.left;
                if (!name.isNone()) try bindings.put(allocator, @backingInt(name), {});
            },
            .catch_clause => try collectBindingPatternNodes(allocator, ast, node.data.binary.left, &bindings),
            .flow_match_arm => try collectFlowMatchPatternDeclarations(allocator, ast, node.data.binary.left, &bindings),
            .variable_declarator => {
                if (ast.hasExtra(node.data.extra, 1)) {
                    const pattern: NodeIndex = @fromBackingInt(@intCast(ast.extra_data.items[node.data.extra]));
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
                    const spec_idx: NodeIndex = @fromBackingInt(@intCast(raw_spec));
                    if (spec_idx.isNone() or @backingInt(spec_idx) >= ast.nodes.items.len) continue;
                    const spec = ast.getNode(spec_idx);
                    switch (spec.tag) {
                        .import_default_specifier, .import_namespace_specifier => try bindings.put(allocator, @backingInt(spec_idx), {}),
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
    const sid = @backingInt(symbol_id);
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
    if (resolveInScopesByName(scopes, scope_maps, name, use_scope)) |symbol_id| return symbol_id;
    const normalized = baseName(name);
    if (std.mem.eql(u8, name, normalized)) return null;
    return resolveInScopesByName(scopes, scope_maps, normalized, use_scope);
}

fn resolveInScopesByName(
    scopes: []const Scope,
    scope_maps: []const std.StringHashMapUnmanaged(usize),
    name: []const u8,
    use_scope: ScopeId,
) ?u32 {
    var current = use_scope;
    var hops: usize = 0;
    while (exactValidScope(scopes, current) and hops < scopes.len) : (hops += 1) {
        if (current.toIndex() < scope_maps.len) {
            if (scope_maps[current.toIndex()].get(name)) |sid| return @intCast(sid);
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
    // semantic scope map 은 escape 로 선언된 이름을 원문과 디코딩 키 둘 다로 넣지만, 평범하게
    // 선언된 이름은 디코딩 키 하나뿐이다. escape 로 쓴 참조(`\u0078`)는 디코딩 이름으로
    // 찾아야 `let x` 에 닿는다 (#5667).
    // 스코프마다 원문·디코딩 키를 함께 봐야 안쪽 스코프가 이긴다.
    var decode_buf: [256]u8 = undefined;
    const decoded = Scanner.decodeIdentifierEscapesInto(name, &decode_buf) orelse name;
    if (resolveInExactScopesByNames(ctx, name, decoded, use_scope)) |symbol_id| return symbol_id;
    const normalized = baseName(name);
    if (std.mem.eql(u8, name, normalized)) return null;
    return resolveInExactScopesByName(ctx, normalized, use_scope);
}

fn resolveInExactScopesByName(ctx: *const ExactCtx, name: []const u8, use_scope: ScopeId) ?u32 {
    return resolveInExactScopesByNames(ctx, name, name, use_scope);
}

/// `alt_name` 은 같은 식별자의 다른 표기(escape 디코딩) — 같은 스코프에서 함께 조회한다.
fn resolveInExactScopesByNames(ctx: *const ExactCtx, name: []const u8, alt_name: []const u8, use_scope: ScopeId) ?u32 {
    var current = use_scope;
    var hops: usize = 0;
    while (exactValidScope(ctx.scopes, current) and hops < ctx.scopes.len) : (hops += 1) {
        const scope_index = current.toIndex();
        if (scope_index < ctx.scope_maps.len) {
            if (ctx.scope_maps[scope_index].get(name)) |sid| return @intCast(sid);
            if (alt_name.ptr != name.ptr) {
                if (ctx.scope_maps[scope_index].get(alt_name)) |sid| return @intCast(sid);
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
            .global, .module, .function, .class_body, .class_static_block => return current.toIndex(),
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
        .ts_module_declaration => return @backingInt(parent.data.binary.left) == child_raw,
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

/// The self-name scope of a reachable named function expression, accepted as
/// owned when it has exactly the analyzer's shape: a block scope directly
/// around the function (or parameter) scope, declaring only the function's
/// own function-like name, with no reference recorded in it directly.
fn generatedFunctionExpressionNameScope(
    ast: *const Ast,
    scope_owner_map: *const std.AutoHashMapUnmanaged(u32, u32),
    scopes: []const Scope,
    scope_maps: []const std.StringHashMapUnmanaged(usize),
    symbol_ids: []const ?u32,
    symbols: []const Symbol,
    referenced_scopes: *const std.AutoHashMapUnmanaged(u32, void),
    function_raw: u32,
) ?u32 {
    if (function_raw >= ast.nodes.items.len or ast.nodes.items[function_raw].tag != .function_expression) return null;
    const extra = ast.nodes.items[function_raw].data.extra;
    if (extra >= ast.extra_data.items.len) return null;
    const name_raw = ast.extra_data.items[extra];
    var name_scope = functionExpressionNameScope(ast, scope_owner_map, scopes, function_raw, name_raw);
    if (name_scope == null or name_scope.? >= scopes.len or name_scope.? >= scope_maps.len or
        !isFunctionExpressionNameScope(
            ast,
            function_raw,
            @fromBackingInt(@intCast(name_scope.?)),
            scopes[name_scope.?].parent,
            symbol_ids,
            symbols,
            scopes,
            scope_maps,
        ))
    {
        name_scope = functionExpressionNameScopeFromNameBinding(
            ast,
            scope_owner_map,
            scopes,
            symbol_ids,
            symbols,
            function_raw,
        );
    }
    const name_scope_id = name_scope orelse return null;
    if (name_scope_id >= scopes.len or name_scope_id >= scope_maps.len) return null;
    if (scope_maps[name_scope_id].count() != 1 or referenced_scopes.contains(name_scope_id)) return null;
    if (!isFunctionExpressionNameScope(
        ast,
        function_raw,
        @fromBackingInt(@intCast(name_scope_id)),
        scopes[name_scope_id].parent,
        symbol_ids,
        symbols,
        scopes,
        scope_maps,
    )) return null;
    return name_scope_id;
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
    var name_scope = scopes[function_scope].parent;
    if (ast.hasExtra(extra, 1)) {
        const params = ast.readExtraNode(extra, 1);
        if (!params.isNone() and scope_owner_map.get(@backingInt(params)) == @as(?u32, @backingInt(name_scope))) {
            if (name_scope.isNone() or name_scope.toIndex() >= scopes.len) return null;
            name_scope = scopes[name_scope.toIndex()].parent;
        }
    }
    if (name_scope.isNone() or name_scope.toIndex() >= scopes.len) return null;
    return name_scope.toIndex();
}

/// Parameter lowering can replace the formal-parameters container and leave
/// it intentionally ownerless. In that case, accept the self-name block only
/// when the function expression's exact name SymbolId and scope ancestry prove
/// the analyzer's named-function shape.
fn functionExpressionNameScopeFromNameBinding(
    ast: *const Ast,
    scope_owner_map: *const std.AutoHashMapUnmanaged(u32, u32),
    scopes: []const Scope,
    symbol_ids: []const ?u32,
    symbols: []const Symbol,
    function_raw: u32,
) ?u32 {
    if (function_raw >= ast.nodes.items.len or ast.nodes.items[function_raw].tag != .function_expression) return null;
    const extra = ast.nodes.items[function_raw].data.extra;
    if (extra + 1 >= ast.extra_data.items.len) return null;
    const params_raw = ast.extra_data.items[extra + 1];
    if (params_raw >= ast.nodes.items.len or ast.nodes.items[params_raw].tag != .formal_parameters or
        scope_owner_map.contains(params_raw)) return null;

    const name_raw = ast.extra_data.items[extra];
    if (name_raw >= ast.nodes.items.len or name_raw >= symbol_ids.len or
        ast.nodes.items[name_raw].tag != .binding_identifier) return null;
    const name_symbol_id = symbol_ids[name_raw] orelse return null;
    if (name_symbol_id >= symbols.len) return null;
    const name_scope = @backingInt(symbols[name_symbol_id].scope_id);
    if (name_scope == @backingInt(ScopeId.none) or name_scope >= scopes.len) return null;

    const function_scope = scope_owner_map.get(function_raw) orelse return null;
    if (function_scope >= scopes.len) return null;
    const function_parent = scopes[function_scope].parent;
    if (!exactValidScope(scopes, function_parent)) return null;
    if (name_scope == @backingInt(function_parent)) return name_scope;

    // The parameter environment is the single function scope between the
    // self-name block and the function/body scope.
    if (scopes[function_parent.toIndex()].kind == .function and
        @backingInt(scopes[function_parent.toIndex()].parent) == name_scope)
        return name_scope;
    return null;
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
        const parent_node = ast.nodes.items[parent_raw];
        const flow_match_pattern_value = parent_node.tag == .flow_match_arm and
            isFlowMatchPatternValueReference(ast, parent_by_node, scope_owner_map, node, parent_raw);
        if (!childSkipsScopeOwner(ast, parent_raw, child) and !flow_match_pattern_value) {
            if (scope_owner_map.get(parent_raw)) |scope| return .{ .node = parent_raw, .scope = scope };
        }
        child = parent_raw;
        if (child == @backingInt(root)) return if (scope_owner_map.get(child)) |scope|
            .{ .node = child, .scope = scope }
        else
            null;
        parent = parent_by_node.get(child);
    }
    return null;
}

/// Flow evaluates value expressions in a match pattern before entering the
/// arm's binding scope. Guards and the arm body run after that scope is entered.
fn isFlowMatchPatternValueReference(
    ast: *const Ast,
    parent_by_node: *const std.AutoHashMapUnmanaged(u32, u32),
    scope_owner_map: *const std.AutoHashMapUnmanaged(u32, u32),
    node: u32,
    arm_raw: u32,
) bool {
    if (node >= ast.nodes.items.len or arm_raw >= ast.nodes.items.len or
        ast.nodes.items[arm_raw].tag != .flow_match_arm) return false;

    var child = node;
    var parent = parent_by_node.get(child);
    var hops: usize = 0;
    while (parent) |raw| : (hops += 1) {
        if (hops >= ast.nodes.items.len or raw >= ast.nodes.items.len) return false;
        if (raw == arm_raw) return @backingInt(ast.nodes.items[raw].data.binary.left) == child;
        // A nested function/class scope owns its own value references. Such a
        // reference must keep that nearer owner instead of skipping the arm.
        if (scope_owner_map.contains(raw)) return false;

        const owner = ast.nodes.items[raw];
        switch (owner.tag) {
            .flow_match_guard_pattern, .flow_match_as_pattern => {
                if (@backingInt(owner.data.binary.right) == child) return false;
                if (@backingInt(owner.data.binary.left) != child) return false;
            },
            .flow_match_object_prop => {
                if (@backingInt(owner.data.binary.left) == child) {
                    if (ast.nodes.items[child].tag != .computed_property_key) return false;
                } else if (@backingInt(owner.data.binary.right) != child) {
                    return false;
                }
            },
            .flow_match_instance_pattern => {
                if (@backingInt(owner.data.binary.left) != child and
                    @backingInt(owner.data.binary.right) != child) return false;
            },
            .flow_match_or_pattern, .flow_match_object_pattern, .flow_match_array_pattern => {},
            else => {},
        }
        child = raw;
        parent = parent_by_node.get(child);
    }
    return false;
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

/// Validate expression-use provenance against real AST lexical owners. This
/// shares the same parameter/body and computed-key boundary rules as the exact
/// reference audit; expressions never become scope owners to satisfy it.
pub fn validateNodeScopeProvenance(
    allocator: std.mem.Allocator,
    ast: *const Ast,
    root: NodeIndex,
    scope_owner_map: *const std.AutoHashMapUnmanaged(u32, u32),
    provenance: *const @import("../semantic/node_scope_provenance.zig").Map,
) std.mem.Allocator.Error!bool {
    const reachable = try ast_walk.collectReachableNodeIndicesFrom(allocator, ast, root);
    defer allocator.free(reachable);
    var parents: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer parents.deinit(allocator);
    for (reachable) |raw| {
        var children = ast_walk.children(ast, ast.nodes.items[raw]);
        while (children.next()) |child| {
            if (child.isNone()) continue;
            if (@backingInt(child) >= ast.nodes.items.len) return false;
            const entry = try parents.getOrPut(allocator, @backingInt(child));
            if (entry.found_existing and entry.value_ptr.* != raw and provenance.contains(child)) return false;
            entry.value_ptr.* = raw;
        }
    }
    for (reachable) |raw| {
        const node: NodeIndex = @fromBackingInt(raw);
        const entry = provenance.get(node) orelse {
            if (ast.nodes.items[raw].tag == .import_expression) return false;
            continue;
        };
        if (entry.source_node.isNone() or @backingInt(entry.source_node) >= ast.nodes.items.len) return false;
        const expected = expectedReferenceScope(ast, root, &parents, scope_owner_map, raw) orelse return false;
        if (entry.scope.isNone() or @backingInt(entry.scope) != expected.scope) return false;
        var child = raw;
        var with_environment = false;
        var hops: usize = 0;
        while (parents.get(child)) |parent| : (hops += 1) {
            if (hops >= ast.nodes.items.len) return false;
            const ancestor = ast.nodes.items[parent];
            if (ancestor.tag == .with_statement and @backingInt(ancestor.data.binary.right) == child) with_environment = true;
            child = parent;
        }
        if (entry.with_environment != with_environment) return false;
    }
    return true;
}

fn topLevelStatementIndex(
    ast: *const Ast,
    root: NodeIndex,
    parent_by_node: *const std.AutoHashMapUnmanaged(u32, u32),
    node: u32,
    initial_parent: ?u32,
) ?u32 {
    if (root.isNone() or @backingInt(root) >= ast.nodes.items.len or
        ast.nodes.items[@backingInt(root)].tag != .program) return null;
    const root_raw = @backingInt(root);
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
    if (root.isNone() or @backingInt(root) >= ast.nodes.items.len or node >= ast.nodes.items.len) return null;
    const root_raw = @backingInt(root);
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
        .block_statement => kind == .block or kind == .function or kind == .catch_clause or kind == .class_static_block,
        // A lowered for-await loop reuses its lexical loop scope on the
        // generated while node (remapCopiedScopeOwner in semantic_edit.zig).
        .for_statement, .for_in_statement, .for_of_statement, .for_await_of_statement, .while_statement => kind == .block,
        .switch_statement => kind == .switch_block,
        .catch_clause => kind == .catch_clause or kind == .block,
        .class_declaration, .class_expression => kind == .class_body,
        .static_block => kind == .class_static_block,
        .function_declaration, .function_expression, .function, .arrow_function_expression, .method_definition, .formal_parameters, .formal_parameter, .assignment_pattern, .assignment_expression, .assignment_target_with_default, .object_pattern, .object_assignment_target, .array_pattern, .array_assignment_target, .parenthesized_expression, .sequence_expression => kind == .function,
        // Namespace and enum lowering attach their generated IIFE scope to
        // the surviving declaration node instead of a generated function node.
        .ts_module_declaration, .ts_enum_declaration => kind == .function,
        .flow_match_arm => kind == .block,
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
    return parent.tag == .ts_module_declaration and @backingInt(parent.data.binary.right) == block_raw;
}

fn statementRequiresLexicalScopeOwner(ast: *const Ast, raw: u32) bool {
    var current = raw;
    // Follow only declaration wrappers. Bound malformed cyclic ASTs without
    // imposing a nesting limit on valid chains of labeled statements.
    for (0..ast.nodes.items.len) |_| {
        if (current >= ast.nodes.items.len) return true;
        const node = ast.nodes.items[current];
        switch (node.tag) {
            .variable_declaration => {
                if (node.data.extra >= ast.extra_data.items.len) return true;
                return ast.variableDeclarationKind(node).isLexical();
            },
            .function_declaration,
            .class_declaration,
            .ts_enum_declaration,
            .flow_enum_declaration,
            .ts_module_declaration,
            .ts_import_equals_declaration,
            .import_declaration,
            => return true,
            .flow_component_wrapper => {
                // The wrapper's synthetic binding is a lexical const declaration.
                const extra: usize = node.data.extra;
                if (extra >= ast.extra_data.items.len or ast.extra_data.items.len - extra < 2) return true;
                current = ast.extra_data.items[extra + 1];
            },
            .export_named_declaration => {
                if (node.data.extra >= ast.extra_data.items.len) return true;
                current = ast.extra_data.items[node.data.extra];
            },
            .export_default_declaration => {
                current = @backingInt(node.data.unary.operand);
                if (current == @backingInt(NodeIndex.none)) return true;
            },
            .labeled_statement => {
                current = @backingInt(node.data.binary.right);
                if (current == @backingInt(NodeIndex.none)) return true;
            },
            else => return false,
        }
        if (current == @backingInt(NodeIndex.none)) return false;
    }
    return true;
}

fn statementListRequiresLexicalScopeOwner(ast: *const Ast, list: ast_mod.NodeList) bool {
    const start: usize = list.start;
    const len: usize = list.len;
    if (start > ast.extra_data.items.len or len > ast.extra_data.items.len - start) return true;
    for (ast.extra_data.items[start .. start + len]) |raw| {
        if (statementRequiresLexicalScopeOwner(ast, raw)) return true;
    }
    return false;
}

fn generatedOwnerlessScopeRequiresOwner(ast: *const Ast, raw: u32, tag: Node.Tag) bool {
    if (raw >= ast.nodes.items.len) return false;
    const node = ast.nodes.items[raw];
    return switch (tag) {
        .program, .block_statement => statementListRequiresLexicalScopeOwner(ast, node.data.list),
        .for_statement => blk: {
            const extra = node.data.extra;
            if (extra >= ast.extra_data.items.len or ast.extra_data.items.len - extra < 4) break :blk true;
            const init_raw = ast.extra_data.items[extra];
            if (init_raw == @backingInt(NodeIndex.none)) break :blk false;
            if (init_raw >= ast.nodes.items.len) break :blk true;
            break :blk statementRequiresLexicalScopeOwner(ast, init_raw);
        },
        .for_in_statement, .for_of_statement, .for_await_of_statement => blk: {
            const left = node.data.ternary.a;
            if (left.isNone()) break :blk true;
            if (@backingInt(left) >= ast.nodes.items.len) break :blk true;
            break :blk statementRequiresLexicalScopeOwner(ast, @backingInt(left));
        },
        else => false,
    };
}

fn canonicalNamespaceBodyOwner(
    ast: *const Ast,
    parents: *const std.AutoHashMapUnmanaged(u32, u32),
    owners: *const std.AutoHashMapUnmanaged(u32, u32),
    scopes: []const Scope,
    body: u32,
) ?u32 {
    if (body >= ast.nodes.items.len) return null;
    const tag = ast.nodes.items[body].tag;
    if (tag != .block_statement and tag != .ts_module_block) return null;
    const primary = parents.get(body) orelse return null;
    if (primary >= ast.nodes.items.len) return null;
    const node = ast.nodes.items[primary];
    if (node.tag != .ts_module_declaration or node.data.binary.flags != 0 or
        @backingInt(node.data.binary.right) != body) return null;
    const scope = owners.get(body) orelse return null;
    if (scope >= scopes.len or scopes[scope].kind != .function or owners.get(primary) != scope) return null;
    return primary;
}

fn staticBlockBodyOwner(ast: *const Ast, parents: *const std.AutoHashMapUnmanaged(u32, u32), block: u32) ?u32 {
    const owner = parents.get(block) orelse return null;
    if (owner >= ast.nodes.items.len or ast.nodes.items[block].tag != .block_statement) return null;
    const node = ast.nodes.items[owner];
    return if (node.tag == .static_block and @backingInt(node.data.unary.operand) == block) owner else null;
}

fn enumPreludeOwner(ast: *const Ast, parents: *const std.AutoHashMapUnmanaged(u32, u32), block: u32) ?u32 {
    const owner = parents.get(block) orelse return null;
    if (owner >= ast.nodes.items.len or ast.nodes.items[block].tag != .block_statement) return null;
    const node = ast.nodes.items[owner];
    if (node.tag != .ts_enum_declaration or node.data.extra + ast_mod.EnumExtra.runtime_prelude >= ast.extra_data.items.len) return null;
    return if (@backingInt(ast.readExtraNode(node.data.extra, ast_mod.EnumExtra.runtime_prelude)) == block) owner else null;
}

fn isFlowMatchWildcardReference(ctx: *const ExactCtx, node_raw: u32) bool {
    if (node_raw >= ctx.ast.nodes.items.len) return false;
    const node = ctx.ast.nodes.items[node_raw];
    if (node.tag != .identifier_reference or !std.mem.eql(u8, ctx.ast.getText(node.span), "_")) return false;

    var child = node_raw;
    var parent = ctx.parent_by_node.get(child);
    var hops: usize = 0;
    while (parent) |raw| : (hops += 1) {
        if (hops >= ctx.ast.nodes.items.len or raw >= ctx.ast.nodes.items.len) return false;
        const owner = ctx.ast.nodes.items[raw];
        switch (owner.tag) {
            .flow_match_arm => return @backingInt(owner.data.binary.left) == child,
            .flow_match_guard_pattern => {
                if (@backingInt(owner.data.binary.right) == child) return false;
                if (@backingInt(owner.data.binary.left) != child) return false;
            },
            .flow_match_as_pattern => {
                if (@backingInt(owner.data.binary.right) == child) return false;
                if (@backingInt(owner.data.binary.left) != child) return false;
            },
            .flow_match_object_prop => {
                if (@backingInt(owner.data.binary.left) == child) return false;
                if (@backingInt(owner.data.binary.right) != child) return false;
            },
            .flow_match_instance_pattern => {
                if (@backingInt(owner.data.binary.left) == child) return false;
                if (@backingInt(owner.data.binary.right) != child) return false;
            },
            .flow_match_object_pattern, .flow_match_array_pattern, .flow_match_or_pattern => {},
            else => return false,
        }
        child = raw;
        parent = ctx.parent_by_node.get(child);
    }
    return false;
}

fn exactVisit(ctx: *ExactCtx, idx: NodeIndex, node: Node) ast_walk.WalkAction {
    switch (node.tag) {
        .static_member_expression => {
            ctx.markName(@fromBackingInt(@intCast(ctx.ast.extra_data.items[node.data.extra + 1])));
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
            const raw = @backingInt(idx);
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
        .flow_match_object_prop => {
            // The left side is a property key; the right side is the
            // value/binding pattern that participates in semantic analysis.
            ctx.markName(node.data.binary.left);
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
            ctx.markName(@fromBackingInt(@intCast(ctx.ast.extra_data.items[node.data.extra])));
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
                ctx.ast.extra_data.items[extra + 3] != @backingInt(NodeIndex.none))
            {
                const start = ctx.ast.extra_data.items[extra + 1];
                const len = ctx.ast.extra_data.items[extra + 2];
                if (start <= ctx.ast.extra_data.items.len and len <= ctx.ast.extra_data.items.len - start) {
                    for (ctx.ast.extra_data.items[start .. start + len]) |raw_spec| {
                        const spec = ctx.ast.getNode(@fromBackingInt(@intCast(raw_spec)));
                        if (spec.tag != .export_specifier) continue;
                        ctx.markName(spec.data.binary.left);
                        ctx.markName(spec.data.binary.right);
                    }
                }
            }
            return .descend;
        },
        .export_all_declaration => {
            // `export * as ns` stores its exported namespace label in an
            // identifier node, but the name is a module label, not a lexical
            // reference and therefore has no SymbolId or Reference row.
            const extra = node.data.extra;
            if (extra <= ctx.ast.extra_data.items.len and
                ctx.ast.extra_data.items.len - extra >= 4)
            {
                const exported_name: NodeIndex = @fromBackingInt(
                    @intCast(ctx.ast.extra_data.items[extra]),
                );
                if (!exported_name.isNone() and @backingInt(exported_name) < ctx.ast.nodes.items.len)
                    ctx.markName(exported_name);
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
        .identifier_reference => if (!isFlowMatchWildcardReference(ctx, @backingInt(idx))) ctx.checkIdentifier(idx),
        .binding_identifier, .assignment_target_identifier => ctx.checkIdentifier(idx),
        .flow_match_binding_pattern => ctx.checkIdentifier(idx),
        .flow_match_rest => if (node.data.none != 0) ctx.checkIdentifier(idx),
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
            if (current == @backingInt(ctx.root)) return false;
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
            const unit = exactExecutionUnit(ctx.scopes, @fromBackingInt(@intCast(scope_id))) orelse
                return ctx.dynamic_eval_units.count() > 0;
            return ctx.dynamic_eval_units.contains(unit);
        }
        // A broken or absent owner path cannot establish whether an eval shares
        // this reference's execution environment; preserve the uncertainty.
        return ctx.dynamic_eval_units.count() > 0;
    }

    fn markName(ctx: *ExactCtx, idx: NodeIndex) void {
        if (idx.isNone() or ctx.ast.getNode(idx).tag == .computed_property_key) return;
        ctx.name_positions.put(ctx.allocator, @backingInt(idx), {}) catch {
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
            ctx.jsx_variable_roots.put(ctx.allocator, @backingInt(current), {}) catch {
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
        if (resolveInExactScopes(ctx, name, @fromBackingInt(@intCast(expected.scope)))) |symbol_id| {
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
                const spec_idx: NodeIndex = @fromBackingInt(@intCast(ctx.ast.extra_data.items[import.specs_start + i]));
                if (spec_idx.isNone() or @backingInt(spec_idx) >= ctx.ast.nodes.items.len) continue;
                const spec = ctx.ast.getNode(spec_idx);
                const local_idx = switch (spec.tag) {
                    .import_default_specifier, .import_namespace_specifier => spec_idx,
                    .import_specifier => spec.data.binary.right,
                    else => continue,
                };
                if (local_idx.isNone() or @backingInt(local_idx) >= ctx.ast.nodes.items.len or
                    @backingInt(local_idx) >= ctx.symbol_ids.len or
                    ctx.symbol_ids[@backingInt(local_idx)] != symbol_id) continue;
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
                parent.data.unary.operand == @as(NodeIndex, @fromBackingInt(@intCast(child))))
            {
                child = parent_raw;
                continue;
            }
            if (parent.tag == .static_member_expression) {
                return ctx.ast.readExtraNode(parent.data.extra, 0) == @as(NodeIndex, @fromBackingInt(@intCast(child)));
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
        const parameter_raw = @backingInt(owner_id);
        if (parameter_raw >= ctx.symbols.len or ctx.symbols[parameter_raw].synthetic_kind != .enum_iife_parameter or
            ctx.symbols[parameter_raw].scope_id != symbol.scope_id) return false;
        if (isEnumObjectBase(ctx, node_raw)) return false;
        if (!exactVisibleFrom(ctx.scopes, ctx.symbols, @fromBackingInt(@intCast(symbol_id)), use_scope)) return false;

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
        if (ctx.scope_owner_map.get(owner_raw) != @as(?u32, @intCast(@backingInt(symbol.scope_id)))) return false;

        const declaration = ctx.ast.nodes.items[owner_raw];
        const extra = declaration.data.extra;
        if (extra + 2 >= ctx.ast.extra_data.items.len) return false;
        const members_start = ctx.ast.extra_data.items[extra + 1];
        const members_len = ctx.ast.extra_data.items[extra + 2];
        if (members_start > ctx.ast.extra_data.items.len or members_len > ctx.ast.extra_data.items.len - members_start) return false;

        var current_position: ?u32 = null;
        var target_position: ?u32 = null;
        for (ctx.ast.extra_data.items[members_start .. members_start + members_len], 0..) |raw_member, position| {
            const listed_member: NodeIndex = @fromBackingInt(@intCast(raw_member));
            if (raw_member == member_raw) current_position = @intCast(position);
            if (listed_member.isNone() or @backingInt(listed_member) >= ctx.ast.nodes.items.len) continue;
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
        const raw = @backingInt(idx);
        if (ctx.name_positions.contains(raw)) return;
        const node = ctx.ast.getNode(idx);
        if (!ctx.reachable_nodes.contains(raw)) std.debug.print(
            "zntc: symbol-identity-traversal-mismatch node={d} name={s} root={d}\n",
            .{ raw, ctx.ast.getText(node.data.string_ref), @backingInt(ctx.root) },
        );
        const name = switch (node.tag) {
            .flow_match_binding_pattern, .flow_match_rest => ctx.ast.getText(node.span),
            else => ctx.ast.getText(node.data.string_ref),
        };
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
        const id: SymbolId = @fromBackingInt(@intCast(raw_id));
        const symbol = ctx.symbols[raw_id];
        if (!exactValidScope(ctx.scopes, symbol.scope_id)) {
            ctx.report.invalid_scope += 1;
        }
        if (is_binding) {
            const symbol_name = exactSymbolName(ctx.ast, &symbol);
            // `\u0078` 와 `x` 는 같은 이름 — escape 를 풀어 비교한다 (#5667).
            if (!Scanner.identifierNamesEqual(baseName(name), baseName(symbol_name))) ctx.report.identity_mismatch += 1;
            if (node.tag == .binding_identifier or isFlowMatchDeclarationNode(ctx, raw)) {
                const expected_scope = expectedBindingScope(ctx, raw, symbol.kind);
                if (expected_scope) |expected| {
                    const lexical_scope = if (node.tag == .binding_identifier)
                        expectedReferenceScope(
                            ctx.ast,
                            ctx.root,
                            ctx.parent_by_node,
                            ctx.scope_owner_map,
                            raw,
                        )
                    else
                        null;
                    const resolved = resolveInScopes(ctx.scopes, ctx.scope_maps, symbol_name, @fromBackingInt(@intCast(expected)));
                    const owner_binding = if (expected < ctx.scope_maps.len)
                        ctx.scope_maps[expected].get(symbol_name)
                    else
                        null;
                    const lexical_binding = if (lexical_scope) |lexical|
                        if (lexical.scope < ctx.scope_maps.len) ctx.scope_maps[lexical.scope].get(symbol_name) else null
                    else
                        null;
                    const lexical_binding_matches = lexical_binding != null and lexical_binding.? == raw_id;
                    const separate_parameter_environment = symbol.kind == .parameter and
                        if (nonSimpleParameterScope(ctx, raw)) |parameter_scope|
                            parameter_scope == symbol.scope_id.toIndex()
                        else
                            false;
                    const shadowed_lexical_owner = lexical_binding != null and lexical_binding.? != raw_id and
                        !separate_parameter_environment;
                    const shadowed_storage_owner = owner_binding != null and owner_binding.? != raw_id and
                        !lexical_binding_matches;
                    const symbol_keeps_lexical_scope = if (lexical_scope) |lexical|
                        symbol.scope_id.toIndex() == lexical.scope
                    else
                        false;
                    const retained_source_scope = !hasReachableScopeOwner(ctx, @backingInt(symbol.scope_id)) and
                        (resolved == null or resolved.? == raw_id);
                    const annex_b_alias = lexical_binding_matches and
                        isAnnexBBlockFunctionAlias(ctx.scopes, &symbol, expected);
                    if (shadowed_lexical_owner or shadowed_storage_owner or
                        (symbol.scope_id.toIndex() != expected and
                            !symbol_keeps_lexical_scope and !annex_b_alias and
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
                    @backingInt(symbol.scope_id),
                    raw_id,
                    symbol_name,
                );
            } else {
                recordScopeMapMismatch(ctx.report, "binding-scope-map-out-of-range", @backingInt(symbol.scope_id), raw_id, symbol_name);
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
                const origin_node = ctx.ast.getNode(@fromBackingInt(@intCast(origin)));
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
            if (@backingInt(indexed.scope_id) != expected_scope.scope) {
                const retained_source_scope = !ctx.helper_reference_nodes.contains(raw) and
                    isRetainedSourceScopeReference(
                        ctx,
                        raw,
                        name,
                        id,
                        indexed.scope_id,
                        @fromBackingInt(@intCast(expected_scope.scope)),
                    );
                if (!retained_source_scope) {
                    ctx.report.reference_scope_mismatch += 1;
                    const actual_owner = scopeOwnerNode(ctx.scope_owner_map, @backingInt(indexed.scope_id));
                    const actual_owner_tag = if (actual_owner) |owner|
                        if (owner < ctx.ast.nodes.items.len) @tagName(ctx.ast.nodes.items[owner].tag) else "out-of-range"
                    else
                        "none";
                    const indexed_id = indexed.symbol_id;
                    const indexed_symbol_scope = if (indexed_id < ctx.symbols.len)
                        @backingInt(ctx.symbols[indexed_id].scope_id)
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
                            @backingInt(indexed.scope_id),
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
        if (ctx.symbols[raw_id].synthetic_kind == .implicit_arguments) {
            const native_owner = nativeArgumentsOwnerScope(ctx.ast, raw, ctx.scope_owner_map, ctx.parent_by_node, ctx.symbols);
            if (native_owner == null or native_owner.? != @backingInt(ctx.symbols[raw_id].scope_id)) {
                ctx.report.scope_resolution_mismatch += 1;
                std.debug.print("zntc: implicit-arguments-native-owner node={d} symbol={d} symbol_scope={d} actual_owner={any}\n", .{ raw, raw_id, @backingInt(ctx.symbols[raw_id].scope_id), native_owner });
            }
        }
        const expected: ?u32 = if (ctx.helper_reference_nodes.contains(raw)) blk: {
            if (ctx.helper_scope_map.get(name)) |sid| break :blk @intCast(sid);
            break :blk null;
        } else if (isEnumMemberReference(ctx, raw, name, raw_id, indexed.scope_id)) raw_id else resolveInExactScopes(ctx, name, indexed.scope_id);
        if (expected) |expected_id| {
            if (expected_id != raw_id) {
                ctx.report.scope_resolution_mismatch += 1;
                const expected_scope = if (expected_id < ctx.symbols.len) @backingInt(ctx.symbols[expected_id].scope_id) else std.math.maxInt(u32);
                const actual_scope = @backingInt(ctx.symbols[raw_id].scope_id);
                const expected_kind = if (expected_id < ctx.symbols.len) @tagName(ctx.symbols[expected_id].kind) else "invalid";
                std.debug.print(
                    "zntc: symbol-identity-resolution node={d} name={s} actual={d}@{d}:{s} expected={d}@{d}:{s} ref_scope={d}\n",
                    .{ raw, name, raw_id, actual_scope, @tagName(ctx.symbols[raw_id].kind), expected_id, expected_scope, expected_kind, @backingInt(indexed.scope_id) },
                );
                for (ctx.symbol_ids, 0..) |binding_id, binding_node| {
                    if (binding_id == null or (binding_id.? != raw_id and binding_id.? != expected_id)) continue;
                    if (binding_node >= ctx.ast.nodes.items.len or ctx.ast.nodes.items[binding_node].tag != .binding_identifier) continue;
                    const binding = ctx.ast.getNode(@fromBackingInt(@intCast(@as(u32, @intCast(binding_node)))));
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

fn formalParametersAreNonSimple(ctx: *const ExactCtx, params: @import("../parser/ast.zig").NodeList) bool {
    if (params.start > ctx.ast.extra_data.items.len or
        params.len > ctx.ast.extra_data.items.len - params.start) return false;
    for (ctx.ast.extra_data.items[params.start .. params.start + params.len]) |param_raw| {
        if (param_raw >= ctx.ast.nodes.items.len) continue;
        const param = ctx.ast.nodes.items[param_raw];
        switch (param.tag) {
            .spread_element,
            .rest_element,
            .binding_rest_element,
            .object_pattern,
            .array_pattern,
            .assignment_pattern,
            => return true,
            .formal_parameter => {
                const extra: usize = param.data.extra;
                const extra_len = ctx.ast.extra_data.items.len;
                if (extra <= extra_len and extra_len - extra > 2 and
                    ctx.ast.extra_data.items[extra + 2] != @backingInt(NodeIndex.none)) return true;
                if (extra < extra_len) {
                    const pattern_raw = ctx.ast.extra_data.items[extra];
                    if (pattern_raw < ctx.ast.nodes.items.len) {
                        const pattern = ctx.ast.nodes.items[pattern_raw];
                        if (pattern.tag == .object_pattern or pattern.tag == .array_pattern) return true;
                    }
                }
            },
            else => {},
        }
    }
    return false;
}

test "non-simple parameter scope discovery tolerates malformed formal parameter extras" {
    const allocator = std.testing.allocator;
    var ast = Ast.init(allocator, "");
    defer ast.deinit();
    const span = try ast.addString("x");
    const parameter = try ast.addNode(.{
        .tag = .formal_parameter,
        .span = span,
        .data = .{ .extra = std.math.maxInt(u32) },
    });
    const params = try ast.addNodeList(&.{parameter});

    var empty_u32_u32: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    var empty_u32_void: std.AutoHashMapUnmanaged(u32, void) = .empty;
    var empty_u32_reference: std.AutoHashMapUnmanaged(u32, IndexedReference) = .empty;
    var empty_string_usize: std.StringHashMapUnmanaged(usize) = .empty;
    var report: ExactReport = .{};
    const ctx = ExactCtx{
        .allocator = allocator,
        .ast = &ast,
        .root = .none,
        .parser_node_count = 0,
        .parent_by_node = &empty_u32_u32,
        .scope_owner_map = &empty_u32_u32,
        .symbol_ids = &.{},
        .declaration_nodes = &empty_u32_void,
        .symbols = &.{},
        .scopes = &.{},
        .scope_maps = &.{},
        .references_by_node = &empty_u32_reference,
        .helper_reference_nodes = &empty_u32_void,
        .helper_scope_map = &empty_string_usize,
        .dynamic_eval_units = &empty_u32_void,
        .with_body_roots = &empty_u32_void,
        .declaration_counts = &.{},
        .unresolved_nodes = &empty_u32_void,
        .explicit_global_nodes = &empty_u32_void,
        .origins = &empty_u32_u32,
        .reachable_nodes = &empty_u32_void,
        .report = &report,
    };

    try std.testing.expect(!formalParametersAreNonSimple(&ctx, params));
}

fn sameFormalParameterNodes(
    ctx: *const ExactCtx,
    left: @import("../parser/ast.zig").NodeList,
    right: @import("../parser/ast.zig").NodeList,
) bool {
    if (left.len != right.len or
        left.start > ctx.ast.extra_data.items.len or left.len > ctx.ast.extra_data.items.len - left.start or
        right.start > ctx.ast.extra_data.items.len or right.len > ctx.ast.extra_data.items.len - right.start) return false;
    for (0..left.len) |index| {
        if (ctx.ast.extra_data.items[left.start + index] != ctx.ast.extra_data.items[right.start + index]) return false;
    }
    return true;
}

/// A transform may copy the formal-parameters list container while retaining
/// the original parameter nodes. Resolve its parameter environment through the
/// exact source container that owns the same NodeIndex sequence.
fn nonSimpleParameterScope(ctx: *const ExactCtx, node: u32) ?u32 {
    var parent = ctx.parent_by_node.get(node);
    var hops: usize = 0;
    while (parent) |raw| : (hops += 1) {
        if (hops >= ctx.ast.nodes.items.len or raw >= ctx.ast.nodes.items.len) return null;
        const ancestor = ctx.ast.nodes.items[raw];
        if (ancestor.tag == .formal_parameters) {
            const params = ancestor.data.list;
            if (!formalParametersAreNonSimple(ctx, params)) return null;
            if (ctx.scope_owner_map.get(raw)) |scope| return scope;

            var matching_scope: ?u32 = null;
            for (ctx.ast.nodes.items, 0..) |candidate, candidate_raw| {
                if (candidate.tag != .formal_parameters or
                    !sameFormalParameterNodes(ctx, params, candidate.data.list)) continue;
                const scope = ctx.scope_owner_map.get(@intCast(candidate_raw)) orelse continue;
                if (matching_scope) |existing| {
                    if (existing != scope) return null;
                } else {
                    matching_scope = scope;
                }
            }
            return matching_scope;
        }
        switch (ancestor.tag) {
            .function_declaration, .function_expression, .function, .arrow_function_expression, .method_definition => return null,
            else => {},
        }
        parent = ctx.parent_by_node.get(raw);
    }
    return null;
}

fn isFlowMatchDeclarationNode(ctx: *const ExactCtx, node_raw: u32) bool {
    if (node_raw >= ctx.ast.nodes.items.len or !ctx.declaration_nodes.contains(node_raw)) return false;
    const node = ctx.ast.nodes.items[node_raw];
    switch (node.tag) {
        .flow_match_binding_pattern, .flow_match_rest => return true,
        .identifier_reference => {
            const parent_raw = ctx.parent_by_node.get(node_raw) orelse return false;
            if (parent_raw >= ctx.ast.nodes.items.len) return false;
            const parent = ctx.ast.nodes.items[parent_raw];
            return parent.tag == .flow_match_as_pattern and @backingInt(parent.data.binary.right) == node_raw;
        },
        else => return false,
    }
}

fn expectedBindingScope(ctx: *const ExactCtx, node: u32, kind: @import("../semantic/symbol.zig").SymbolKind) ?u32 {
    if (node >= ctx.ast.nodes.items.len) return null;
    const binding_name = ctx.ast.nodes.items[node];
    if (binding_name.tag != .binding_identifier and !ctx.declaration_nodes.contains(node)) return null;
    if (binding_name.tag != .binding_identifier) {
        var child = node;
        var parent = ctx.parent_by_node.get(child);
        var hops: usize = 0;
        while (parent) |raw| : (hops += 1) {
            if (hops >= ctx.ast.nodes.items.len or raw >= ctx.ast.nodes.items.len) return null;
            if (ctx.ast.nodes.items[raw].tag == .flow_match_arm)
                return ctx.scope_owner_map.get(raw);
            child = raw;
            parent = ctx.parent_by_node.get(child);
        }
        return null;
    }
    if (kind == .parameter) {
        if (nonSimpleParameterScope(ctx, node)) |scope| return scope;
    }
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
    return !hasReachableScopeOwner(ctx, @backingInt(scope)) and
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
        false,
    );
}

/// Exact source audit that additionally requires one declaration row anchored
/// to every reachable declaration node with a SymbolId.
pub fn checkExactWithDeclarationAnchors(
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
        true,
    );
}

/// Exact audit for an untransformed source graph. Every semantically live
/// ScopeId must have a reachable AST owner; unlike a transformed graph, there
/// are no pre-existing source scopes whose owners may have been lowered away.
pub fn checkExactWithCompleteSourceScopeOwners(
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
        0,
        true,
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
        false,
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
        false,
    );
}

/// Exact post-transform audit used by the strict coverage gate. Callers must
/// enable analyzer declaration-anchor collection before transformation.
pub fn checkExactWithNamespaceMetadataAndDeclarationAnchors(
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
        true,
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
    require_declaration_anchors: bool,
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
    if (root.isNone() or @backingInt(root) >= ast.nodes.items.len) {
        report.invalid_ast_root += 1;
        report.first_invalid_ast_root = @backingInt(root);
        return report;
    }
    try reachable_stack.append(allocator, .{ .node_index = root });
    while (reachable_stack.pop()) |frame| {
        const node_idx = frame.node_index;
        if (node_idx.isNone() or @backingInt(node_idx) >= ast.nodes.items.len) continue;
        const raw = @backingInt(node_idx);
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
            const child_raw = @backingInt(child);
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
            if (child_raw == @backingInt(root)) {
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
        if (enumPreludeOwner(ast, &parent_by_node, raw)) |owner| {
            if (scope_owner_map.get(owner) == scope_id and scopes[scope_id].kind == .function) continue;
        }
        if (staticBlockBodyOwner(ast, &parent_by_node, raw)) |owner| {
            if (scope_owner_map.get(owner) == scope_id and scopes[scope_id].kind == .class_static_block) continue;
        }
        if (canonicalNamespaceBodyOwner(ast, &parent_by_node, scope_owner_map, scopes, raw) != null) continue;
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
            if (name_idx.isNone() or @backingInt(name_idx) >= symbol_ids.len) continue;
            const declaration_id = symbol_ids[@backingInt(name_idx)] orelse continue;
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
            try with_body_roots.put(allocator, @backingInt(node.data.binary.right), {});
        }
        if (node.tag != .call_expression or node.data.extra + 2 >= ast.extra_data.items.len) continue;
        const callee: NodeIndex = @fromBackingInt(@intCast(ast.extra_data.items[node.data.extra]));
        if (callee.isNone() or @backingInt(callee) >= ast.nodes.items.len) continue;
        const callee_node = ast.getNode(callee);
        if (callee_node.tag != .identifier_reference or
            !std.mem.eql(u8, ast.getText(callee_node.data.string_ref), "eval")) continue;
        const eval_scope = expectedReferenceScope(ast, root, &parent_by_node, scope_owner_map, @backingInt(callee)) orelse continue;
        if (exactExecutionUnit(scopes, @fromBackingInt(@intCast(eval_scope.scope)))) |unit|
            try dynamic_eval_units.put(allocator, unit, {});
    }
    var declaration_nodes = try collectDeclarationNodes(allocator, ast, &reachable_nodes);
    defer declaration_nodes.deinit(allocator);
    var declaration_anchor_counts: std.AutoHashMapUnmanaged(u32, usize) = .empty;
    defer declaration_anchor_counts.deinit(allocator);
    var declaration_anchor_symbols: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer declaration_anchor_symbols.deinit(allocator);
    var references_by_node: std.AutoHashMapUnmanaged(u32, IndexedReference) = .empty;
    defer references_by_node.deinit(allocator);
    var helper_refs: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer helper_refs.deinit(allocator);
    for (helper_reference_nodes) |node| try helper_refs.put(allocator, node, {});
    // Runtime helper markers include local call/import nodes, including a
    // default-import specifier used as its own binding node, and for defensive
    // coverage import_specifier.left (the imported export name). The export-name
    // slot is not a local binding unless it aliases the local slot itself;
    // every reachable local/call node must resolve through the exact helper
    // map entry and carry that SymbolId.
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
                    const is_imported_slot = @backingInt(parent.data.binary.left) == raw;
                    const is_local_slot = @backingInt(parent.data.binary.right) == raw;
                    if (is_imported_slot and !is_local_slot) continue;
                    if (!is_imported_slot and !is_local_slot) {
                        report.helper_symbol_mismatch += 1;
                        continue;
                    }
                }
            }
        }
        const node = ast.nodes.items[raw];
        if (node.tag != .identifier_reference and node.tag != .jsx_identifier and
            node.tag != .import_default_specifier)
        {
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
    var ast_declaration_counts = try allocator.alloc(usize, symbols.len);
    defer allocator.free(ast_declaration_counts);
    var value_counts = try allocator.alloc(usize, symbols.len);
    defer allocator.free(value_counts);
    var write_counts = try allocator.alloc(usize, symbols.len);
    defer allocator.free(write_counts);
    @memset(declaration_counts, 0);
    @memset(ast_declaration_counts, 0);
    @memset(value_counts, 0);
    @memset(write_counts, 0);

    var ast_declarations = declaration_nodes.iterator();
    while (ast_declarations.next()) |entry| {
        const raw = entry.key_ptr.*;
        if (raw >= symbol_ids.len) continue;
        const sid = symbol_ids[raw] orelse continue;
        if (sid < symbols.len) ast_declaration_counts[sid] += 1;
    }
    // Shared Annex B block-function bindings: their block declarations all
    // anchor one var-scope symbol, so its declaration rows stay unanchored.
    var annex_b_alias_symbols: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer annex_b_alias_symbols.deinit(allocator);
    for (scope_maps, 0..) |scope_map, scope_i| {
        if (scope_i >= scopes.len) break;
        var aliases = scope_map.iterator();
        while (aliases.next()) |entry| {
            if (entry.value_ptr.* >= symbols.len) continue;
            if (isAnnexBBlockFunctionAlias(scopes, &symbols[entry.value_ptr.*], @intCast(scope_i)))
                try annex_b_alias_symbols.put(allocator, @intCast(entry.value_ptr.*), {});
        }
    }

    const cjs_wrapper = exactCjsWrapperBindings(ast, root, symbols, scopes, scope_maps, scope_owner_map);
    if (scope_maps.len != scopes.len) recordScopeMapMismatch(&report, "scope-map-count", null, null, null);
    for (scopes, 0..) |scope, scope_i| {
        const inherits_parent_strictness = switch (scope.kind) {
            .block, .switch_block, .catch_clause => true,
            else => false,
        };
        const strictness_issue: ?[]const u8 = if (scope.kind == .class_body and !scope.is_strict)
            "class-body-must-be-strict"
        else if (scope.kind == .class_static_block and !scope.is_strict)
            "class-static-block-must-be-strict"
        else if (scope.kind == .module and !scope.is_strict)
            "module-must-be-strict"
        else if (!scope.parent.isNone() and exactValidScope(scopes, scope.parent) and
            scopes[scope.parent.toIndex()].is_strict and !scope.is_strict)
            "strict-parent-inheritance"
        else if (inherits_parent_strictness and !scope.parent.isNone() and
            exactValidScope(scopes, scope.parent) and
            scope.is_strict != scopes[scope.parent.toIndex()].is_strict)
            "lexical-scope-must-match-parent-strictness"
        else
            null;
        if (strictness_issue) |issue| {
            recordScopeStrictnessMismatch(
                &report,
                @intCast(scope_i),
                if (scope.parent.isNone() or !exactValidScope(scopes, scope.parent)) null else @backingInt(scope.parent),
                issue,
            );
        }
        if (scope_i == 0) {
            const is_cjs_wrapper_parent = if (cjs_wrapper) |wrapper|
                scope.parent == @as(ScopeId, @fromBackingInt(@intCast(wrapper.scope_id)))
            else
                false;
            if (!scope.parent.isNone() and !is_cjs_wrapper_parent) report.invalid_scope += 1;
        } else {
            const is_cjs_wrapper_scope = if (cjs_wrapper) |wrapper| scope_i == wrapper.scope_id else false;
            if (scope.parent.isNone()) {
                if (!is_cjs_wrapper_scope) report.invalid_scope += 1;
            } else if (!exactValidScope(scopes, scope.parent) or scope.parent.toIndex() == scope_i) {
                report.invalid_scope += 1;
            }
        }
        var ancestor: ScopeId = @fromBackingInt(@intCast(@as(u32, @intCast(scope_i))));
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
            const mapped_scope: ScopeId = @fromBackingInt(@intCast(@as(u32, @intCast(scope_i))));
            const is_cjs_root_alias = if (cjs_wrapper) |wrapper| blk: {
                if (scope_i != 0) break :blk false;
                break :blk (std.mem.eql(u8, entry.key_ptr.*, "exports") and entry.value_ptr.* == wrapper.exports_symbol_id) or
                    (std.mem.eql(u8, entry.key_ptr.*, "module") and entry.value_ptr.* == wrapper.module_symbol_id);
            } else false;
            if (!exactScopeMapKeyMatchesSymbol(ast, &mapped_symbol, entry.key_ptr.*) or
                (mapped_symbol.scope_id != mapped_scope and !is_cjs_root_alias and
                    !isAnnexBBlockFunctionAlias(scopes, &mapped_symbol, @intCast(scope_i))))
            {
                recordScopeMapMismatch(&report, "entry-name-or-owner", @intCast(scope_i), @intCast(entry.value_ptr.*), entry.key_ptr.*);
            }
        }
    }
    for (symbols, 0..) |symbol, sid| {
        if (!exactValidScope(scopes, symbol.scope_id)) {
            const id: u32 = @intCast(sid);
            const valid_detached_output = symbol.scope_id.isNone() and exactDetachedOutputSymbolShape(&symbol) and
                exactDetachedOutputSymbolHasNoLexicalEdges(id, symbol_ids, references, scope_maps);
            if (!valid_detached_output) report.invalid_scope += 1;
        }
    }

    if (pre_transform_scope_count) |source_scope_count| {
        if (source_scope_count > scopes.len) {
            recordScopeOwnerMismatch(&report, @backingInt(root), ast.getNode(root).tag, "source-scope-count-out-of-range", null, null, null);
        } else {
            var reachable_scope_owners: std.AutoHashMapUnmanaged(u32, void) = .empty;
            defer reachable_scope_owners.deinit(allocator);
            var live_scope_ids: std.AutoHashMapUnmanaged(u32, void) = .empty;
            defer live_scope_ids.deinit(allocator);
            for (symbols) |symbol| try markScopeAndAncestors(allocator, &live_scope_ids, scopes, @backingInt(symbol.scope_id));
            for (references) |reference| try markScopeAndAncestors(allocator, &live_scope_ids, scopes, @backingInt(reference.scope_id));
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
            // A named function expression's self-name scope is ownerless by
            // construction (the analyzer's own too): the function node owns
            // the function scope. Accept a generated one only in that exact
            // shape (generatedFunctionExpressionNameScope).
            var referenced_scopes: std.AutoHashMapUnmanaged(u32, void) = .empty;
            defer referenced_scopes.deinit(allocator);
            for (references) |reference| {
                // Declaration rows anchor a binding in its own scope; only an
                // evaluated read or write would sit in the self-name scope.
                if (reference.flags.declare) continue;
                try referenced_scopes.put(allocator, @backingInt(reference.scope_id), {});
            }
            var name_scope_iter = reachable_nodes.iterator();
            while (name_scope_iter.next()) |entry| {
                if (generatedFunctionExpressionNameScope(ast, scope_owner_map, scopes, scope_maps, symbol_ids, symbols, &referenced_scopes, entry.key_ptr.*)) |name_scope|
                    try reachable_scope_owners.put(allocator, name_scope, {});
            }
            for (source_scope_count..scopes.len) |scope_index| {
                const scope_id: u32 = @intCast(scope_index);
                // Empty dead scopes left by a lowering are inert: no symbol,
                // reference, or descendant scope depends on them. Gate every
                // semantically live transform scope and its ancestor chain.
                if (!live_scope_ids.contains(scope_id)) continue;
                if (reachable_scope_owners.contains(scope_id)) {
                    report.generated_scope_owners_checked += 1;
                    continue;
                }
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
                recordScopeMapMismatch(&report, "namespace-member-in-lexical-map", @backingInt(symbols[member_id].scope_id), member_id, exactSymbolName(ast, &symbols[member_id]));
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
            recordScopeMapMismatch(&report, "symbol-not-in-either-map", @backingInt(symbol.scope_id), @intCast(sid), name);
    }
    var reachable_iter = reachable_nodes.iterator();
    while (reachable_iter.next()) |reachable_entry| {
        const raw = reachable_entry.key_ptr.*;
        const tag = ast.nodes.items[raw].tag;
        const is_generated = raw >= parser_node_count;
        const expected_kind: ?ScopeKind = switch (tag) {
            .program => null, // global vs module depends on parser mode
            .block_statement, .for_statement, .for_in_statement, .for_of_statement, .for_await_of_statement, .flow_match_arm => .block,
            .switch_statement => .switch_block,
            // The source analyzer enters catch and body-block scopes on the
            // same owner node; the latter may be the recorded owner.
            .catch_clause => null,
            .class_declaration, .class_expression => .class_body,
            .static_block => .class_static_block,
            .function_declaration, .function_expression, .function, .arrow_function_expression, .method_definition => .function,
            else => continue,
        };
        if (tag == .block_statement) {
            const parent_raw = parent_by_node.get(raw);
            // Namespace analysis enters the namespace's function scope, then
            // visits this block's statement list directly. The block is a
            // syntax container, not a second lexical ScopeId owner.
            if (isNamespaceBodyBlock(ast, &parent_by_node, raw)) continue;
            if (parent_raw) |parent| {
                const owner = ast.nodes.items[parent];
                if (owner.tag == .static_block and @backingInt(owner.data.unary.operand) == raw) {
                    const primary_scope = scope_owner_map.get(parent);
                    const body_scope = scope_owner_map.get(raw);
                    if (primary_scope == null or body_scope == null or primary_scope.? != body_scope.? or
                        body_scope.? >= scopes.len or scopes[body_scope.?].kind != .class_static_block)
                        recordScopeOwnerMismatch(&report, raw, tag, "static-body-owner", body_scope, .class_static_block, if (body_scope != null and body_scope.? < scopes.len) scopes[body_scope.?].kind else null);
                    continue;
                }
            }
            if (enumPreludeOwner(ast, &parent_by_node, raw)) |owner| {
                const enum_scope = scope_owner_map.get(owner);
                const body_scope = scope_owner_map.get(raw);
                if (enum_scope == null or body_scope == null or enum_scope.? != body_scope.? or
                    body_scope.? >= scopes.len or scopes[body_scope.?].kind != .function)
                    recordScopeOwnerMismatch(&report, raw, tag, "enum-prelude-owner", body_scope, .function, if (body_scope != null and body_scope.? < scopes.len) scopes[body_scope.?].kind else null);
                continue;
            }
            const is_function_body = if (parent_raw) |parent| blk: {
                const parent_node = ast.nodes.items[parent];
                break :blk ast.functionBodyBlock(parent_node) != null and
                    @backingInt(ast.functionBodyBlock(parent_node).?) == raw;
            } else false;
            const is_aliased_catch_body = if (parent_raw) |parent| blk: {
                const parent_node = ast.nodes.items[parent];
                if (parent_node.tag != .catch_clause or scope_owner_map.get(parent) == null) break :blk false;
                const parent_scope = scope_owner_map.get(parent).?;
                break :blk parent_scope < scopes.len and scopes[parent_scope].kind == .block;
            } else false;
            if (is_function_body or is_aliased_catch_body) continue;
        }
        const raw_scope = scope_owner_map.get(raw) orelse {
            // Rebuilt Programs and generated blocks/loops may be structural
            // wrappers with no fresh semantic scope. Class, switch, catch, and
            // function nodes always establish a semantic boundary.
            if (is_generated and (tag == .program or tag == .block_statement or tag == .for_statement or
                tag == .for_in_statement or tag == .for_of_statement or tag == .for_await_of_statement))
            {
                if (generatedOwnerlessScopeRequiresOwner(ast, raw, tag)) {
                    recordScopeOwnerMismatch(
                        &report,
                        raw,
                        tag,
                        "missing-owner-for-lexical-declaration",
                        null,
                        expected_kind,
                        null,
                    );
                }
                continue;
            }
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
        if (enumPreludeOwner(ast, &parent_by_node, raw)) |owner| {
            if (scope_owner_map.get(owner) == scope_raw and owner_scope.kind == .function) continue;
        }
        if (staticBlockBodyOwner(ast, &parent_by_node, raw)) |owner| {
            if (scope_owner_map.get(owner) == scope_raw and owner_scope.kind == .class_static_block) continue;
        }
        if (raw == @backingInt(root)) {
            // A non-Program root can be a fragment nested inside an implicit
            // outer scope, so only a Program owner is required to be parentless.
            const is_cjs_wrapper_parent = if (cjs_wrapper) |wrapper|
                scope_raw == 0 and owner_scope.parent == @as(ScopeId, @fromBackingInt(@intCast(wrapper.scope_id)))
            else
                false;
            if (ast.nodes.items[raw].tag == .program and !owner_scope.parent.isNone() and !is_cjs_wrapper_parent)
                recordScopeOwnerParentMismatch(
                    &report,
                    raw,
                    ast.nodes.items[raw].tag,
                    scope_raw,
                    null,
                    if (exactValidScope(scopes, owner_scope.parent)) @backingInt(owner_scope.parent) else null,
                );
            continue;
        }
        if (parameterScopeFunctionOwner(ast, &parent_by_node, raw)) |function_raw| {
            const function_scope = scope_owner_map.get(function_raw) orelse {
                recordScopeOwnerParentMismatch(
                    &report,
                    raw,
                    ast.nodes.items[raw].tag,
                    scope_raw,
                    null,
                    if (exactValidScope(scopes, owner_scope.parent)) @backingInt(owner_scope.parent) else null,
                );
                continue;
            };
            if (function_scope >= scopes.len or
                scopes[function_scope].parent != @as(ScopeId, @fromBackingInt(@intCast(scope_raw))))
            {
                recordScopeOwnerParentMismatch(
                    &report,
                    function_raw,
                    ast.nodes.items[function_raw].tag,
                    function_scope,
                    scope_raw,
                    if (function_scope < scopes.len and exactValidScope(scopes, scopes[function_scope].parent))
                        @backingInt(scopes[function_scope].parent)
                    else
                        null,
                );
                continue;
            }
            const expected_parent = expectedReferenceScope(
                ast,
                root,
                &parent_by_node,
                scope_owner_map,
                function_raw,
            ) orelse {
                recordScopeOwnerParentMismatch(
                    &report,
                    raw,
                    ast.nodes.items[raw].tag,
                    scope_raw,
                    null,
                    if (exactValidScope(scopes, owner_scope.parent)) @backingInt(owner_scope.parent) else null,
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
                function_raw,
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
                if (exactValidScope(scopes, owner_scope.parent)) @backingInt(owner_scope.parent) else null,
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
                if (exactValidScope(scopes, owner_scope.parent)) @backingInt(owner_scope.parent) else null,
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
            if (exactValidScope(scopes, owner_scope.parent)) @backingInt(owner_scope.parent) else null,
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
            if (symbol.synthetic_kind != .namespace_iife_parameter or @backingInt(symbol.scope_id) != scope_raw) continue;
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
        if (source_name.isNone() or @backingInt(source_name) >= ast.nodes.items.len or @backingInt(source_name) >= symbol_ids.len or
            symbol_ids[@backingInt(source_name)] == null or symbol_ids[@backingInt(source_name)].? == sid)
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
            if (scope_owner_map.get(reachable.key_ptr.*) == @as(?u32, @backingInt(symbol.scope_id))) {
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
            if (symbol.synthetic_kind != .enum_iife_parameter or @backingInt(symbol.scope_id) != scope_raw) continue;
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
        const name_idx: NodeIndex = @fromBackingInt(@intCast(ast.extra_data.items[enum_extra]));
        const source_name = if (!name_idx.isNone() and @backingInt(name_idx) < ast.nodes.items.len)
            ast.getText(ast.getNode(name_idx).span)
        else
            "";
        if (parameter.kind != .parameter or !parameter.decl_flags.is_parameter or parameter.synthetic_name.len == 0 or
            source_name.len == 0 or scope_raw >= scope_maps.len or
            scope_maps[scope_raw].get(source_name) != @as(?usize, @intCast(sid)))
        {
            report.enum_iife_param_mismatch += 1;
        }
        if (name_idx.isNone() or @backingInt(name_idx) >= ast.nodes.items.len or @backingInt(name_idx) >= symbol_ids.len or
            symbol_ids[@backingInt(name_idx)] == null or symbol_ids[@backingInt(name_idx)].? == sid)
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
                scope_owner_map.get(owner_idx) == @as(?u32, @intCast(@backingInt(symbol.scope_id))))
            {
                owner_is_reachable = true;
                break;
            }
        }
        if (owner_is_reachable) report.enum_iife_param_mismatch += 1;
    }

    for (references) |reference| {
        const sid = @backingInt(reference.symbol_id);
        if (sid >= symbols.len) {
            report.invalid_id += 1;
            continue;
        }
        if (reference.flags.declare) {
            declaration_counts[sid] += 1;
            if (reference.declaration_node_index.isNone()) {
                if (ast_declaration_counts[sid] > 0 and !annex_b_alias_symbols.contains(@intCast(sid))) {
                    report.declaration_identity_mismatch += 1;
                }
            } else {
                const declaration_raw = @backingInt(reference.declaration_node_index);
                if (declaration_raw >= ast.nodes.items.len or
                    !reachable_nodes.contains(declaration_raw) or
                    !declaration_nodes.contains(declaration_raw) or
                    declaration_raw >= symbol_ids.len or symbol_ids[declaration_raw] != sid)
                {
                    report.declaration_identity_mismatch += 1;
                }
                if (declaration_raw < symbol_ids.len and symbol_ids[declaration_raw] == sid and
                    declaration_nodes.contains(declaration_raw))
                {
                    try declaration_anchor_symbols.put(allocator, sid, {});
                    const anchor_count = try declaration_anchor_counts.getOrPut(allocator, declaration_raw);
                    if (anchor_count.found_existing) {
                        anchor_count.value_ptr.* += 1;
                    } else {
                        anchor_count.value_ptr.* = 1;
                    }
                }
            }
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
        const key = @backingInt(reference.node_index);
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
        if (ast.nodes.items[@backingInt(root)].tag == .program and
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
    if (require_declaration_anchors) {
        var checked_declaration_symbols: std.AutoHashMapUnmanaged(u32, void) = .empty;
        defer checked_declaration_symbols.deinit(allocator);
        var declaration_iter = declaration_nodes.iterator();
        while (declaration_iter.next()) |entry| {
            const raw = entry.key_ptr.*;
            if (raw >= symbol_ids.len) continue;
            const maybe_id = symbol_ids[raw] orelse continue;
            if (maybe_id >= symbols.len) continue;
            const checked = try checked_declaration_symbols.getOrPut(allocator, maybe_id);
            if (checked.found_existing) continue;
            report.declaration_anchors_checked += 1;
            if (!declaration_anchor_symbols.contains(maybe_id) and !annex_b_alias_symbols.contains(maybe_id)) {
                report.declaration_anchor_mismatch += 1;
                if (report.first_declaration_anchor_mismatch == null) {
                    const node = ast.nodes.items[raw];
                    report.first_declaration_anchor_mismatch = .{
                        .name = ast.getText(node.data.string_ref),
                        .tag = node.tag,
                        .node_index = raw,
                        .span_start = node.span.start,
                    };
                }
            }
        }
        var anchors = declaration_anchor_counts.iterator();
        while (anchors.next()) |entry| {
            if (entry.value_ptr.* > 1) report.declaration_anchor_mismatch += 1;
        }
    }
    if (ast.nodes.items[@backingInt(root)].tag == .program) {
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
    try accountNativeAnnexBAssignments(allocator, ast, &reachable_nodes, symbol_ids, symbols, scopes, value_counts, write_counts, &report);
    for (symbols, 0..) |symbol, sid| {
        if (symbol.reference_count != value_counts[sid]) {
            report.reference_count_mismatch += 1;
        }
        if (symbol.write_count != write_counts[sid]) {
            report.write_count_mismatch += 1;
        }
    }
    var helper_scopes = helper_scope_map.iterator();
    while (helper_scopes.next()) |entry| {
        if (entry.value_ptr.* >= symbols.len) {
            recordScopeMapMismatch(&report, "helper-entry-symbol-out-of-range", null, @intCast(entry.value_ptr.*), entry.key_ptr.*);
            continue;
        }
        const symbol = symbols[entry.value_ptr.*];
        if (symbol.kind != .import_binding or !std.mem.eql(u8, entry.key_ptr.*, exactSymbolName(ast, &symbol))) {
            recordScopeMapMismatch(&report, "helper-entry-kind-or-name", @backingInt(symbol.scope_id), @intCast(entry.value_ptr.*), entry.key_ptr.*);
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
        if (node_index.isNone() or @backingInt(node_index) >= ast.nodes.items.len) continue;
        const raw = @backingInt(node_index);
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
            if (!child.isNone() and @backingInt(child) < ast.nodes.items.len)
                try stack.append(allocator, .{ .node_index = child });
        }
    }
    return cyclic_edges;
}

/// Some lowerings retain the source lexical ScopeId for a user binding even
/// after its source owner node is removed (for example an extracted generator
/// loop argument). Accept that reference scope only when it remains visible
/// for the same source symbol and no reachable output AST node owns it.
fn isRetainedSourceScopeReference(
    ctx: *ExactCtx,
    node: u32,
    name: []const u8,
    symbol_id: SymbolId,
    use_scope: ScopeId,
    output_scope: ScopeId,
) bool {
    const raw_id = @backingInt(symbol_id);
    if (raw_id >= ctx.symbols.len or !exactValidScope(ctx.scopes, use_scope) or
        !exactValidScope(ctx.scopes, output_scope)) return false;
    // Historical scope evidence is valid only after its actual AST owner
    // disappears, not when another live branch still owns that ScopeId.
    if (hasReachableScopeOwner(ctx, @backingInt(use_scope))) return false;
    const symbol = ctx.symbols[raw_id];
    if (symbol.synthetic_kind != null or symbol.synthetic_name.len > 0) {
        // A generator state machine can replace a generated catch clause with
        // `binding = _state.sent()` and hoist that binding into its wrapper.
        // Keep the exact catch SymbolId only when the catch owner disappeared
        // from the output tree and a binding with that ID still exists there.
        if (symbol.kind != .catch_binding or
            hasReachableScopeOwner(ctx, @backingInt(symbol.scope_id)) or
            !hasReachableBindingForSymbol(ctx, raw_id)) return false;
    }
    if (!exactVisibleFrom(ctx.scopes, ctx.symbols, symbol_id, use_scope)) return false;
    // A retained source ScopeId is historical evidence for the moved binding,
    // not evidence that the emitted reference still resolves to it. Confirm
    // lexical lookup from the actual output AST scope too, or a same-name
    // binding introduced below the removed source owner can silently capture
    // this reference while the stale source scope continues to resolve cleanly.
    const output_resolution = resolveInExactScopes(ctx, name, output_scope);
    if (output_resolution != raw_id and
        !ctx.isEnumMemberReference(node, name, raw_id, output_scope)) return false;
    var child = node;
    var hops: usize = 0;
    while (ctx.parent_by_node.get(child)) |parent| : (hops += 1) {
        if (hops >= ctx.ast.nodes.items.len or parent >= ctx.ast.nodes.items.len) return false;
        if (!childSkipsScopeOwner(ctx.ast, parent, child)) {
            if (ctx.scope_owner_map.get(parent)) |scope| {
                if (scope == @backingInt(use_scope)) return false;
            }
        }
        child = parent;
        if (child == @backingInt(ctx.root)) {
            if (ctx.scope_owner_map.get(child)) |scope| {
                if (scope == @backingInt(use_scope)) return false;
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
    invalid_binding_id: usize = 0,
    invalid_reference_id: usize = 0,
    missing_binding_id: usize = 0,
    missing_reference_id: usize = 0,
    dangling_reference_id: usize = 0,
    wrong_reference_target: usize = 0,
    shadowed_external_reference: usize = 0,
    unproven_external_reference: usize = 0,

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
        const info = @typeInfo(PostMinifyReport).@"struct";
        inline for (info.field_names, info.field_types) |name, field_type| {
            if (comptime isObservationField(name)) continue;
            if (comptime field_type != usize) @compileError("unclassified PostMinifyReport field; classify it as an observation or usize invariant counter");
            if (@field(self, name) != 0) return false;
        }
        return true;
    }
};

/// Scope and owner evidence belongs to one semantic graph over this exact AST.
pub const PostMinifyNativeOwners = struct {
    scopes: []const Scope,
    scope_owner_map: *const std.AutoHashMapUnmanaged(u32, u32),
};

const PostMinifyNativeOwnerPair = struct {
    actual: PostMinifyNativeOwners,
    resolved: PostMinifyNativeOwners,
};

/// Select only the native binding supplied by this graph's current AST frame.
/// The map key is the actual function, parameter-environment or IIFE node;
/// numeric ScopeIds and SymbolIds are never compared between graphs.
fn collectPostMinifyNativeBindings(
    allocator: std.mem.Allocator,
    ast: *const Ast,
    reachable: []const u32,
    symbol_ids: []const ?u32,
    symbols: []const Symbol,
    graph: PostMinifyNativeOwners,
) !std.AutoHashMapUnmanaged(u32, u32) {
    var result: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    errdefer result.deinit(allocator);
    var engines: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer engines.deinit(allocator);
    var invalid_scopes: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer invalid_scopes.deinit(allocator);
    for (symbols, 0..) |symbol, sid| {
        if (symbol.synthetic_kind != .implicit_arguments) continue;
        const scope = @backingInt(symbol.scope_id);
        if (scope >= graph.scopes.len) continue;
        if ((symbol.kind != .parameter and symbol.kind != .variable_var) or graph.scopes[scope].kind != .function or
            sid > std.math.maxInt(u32))
        {
            try invalid_scopes.put(allocator, scope, {});
            continue;
        }
        const engine = try engines.getOrPut(allocator, scope);
        if (engine.found_existing) try invalid_scopes.put(allocator, scope, {});
        engine.value_ptr.* = @intCast(sid);
    }
    var parameter_frames: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer parameter_frames.deinit(allocator);
    var ambiguous_parameters: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer ambiguous_parameters.deinit(allocator);
    for (reachable) |raw| {
        if (raw >= ast.nodes.items.len) continue;
        const node = ast.nodes.items[raw];
        if (node.tag == .binding_identifier and raw < symbol_ids.len) {
            if (symbol_ids[raw]) |sid| {
                if (sid < symbols.len and symbols[sid].kind == .parameter and
                    symbols[sid].synthetic_kind == .implicit_arguments)
                    try invalid_scopes.put(allocator, @backingInt(symbols[sid].scope_id), {});
            }
        }
        switch (node.tag) {
            .function_declaration, .function_expression, .function, .method_definition => {},
            else => continue,
        }
        if (!ast.hasExtra(node.data.extra, 1)) continue;
        const params = ast.readExtraNode(node.data.extra, 1);
        if (params.isNone()) continue;
        const entry = try parameter_frames.getOrPut(allocator, @backingInt(params));
        if (entry.found_existing and entry.value_ptr.* != raw)
            try ambiguous_parameters.put(allocator, @backingInt(params), {});
        entry.value_ptr.* = raw;
    }
    const Frame = struct { node: u32, carrier: u32 };
    var scope_frames: std.AutoHashMapUnmanaged(u32, Frame) = .empty;
    defer scope_frames.deinit(allocator);
    for (reachable) |raw| {
        if (raw >= ast.nodes.items.len) continue;
        const node = ast.nodes.items[raw];
        const body_scope = graph.scope_owner_map.get(raw) orelse continue;
        if (body_scope >= graph.scopes.len or graph.scopes[body_scope].kind != .function) continue;
        var scope = body_scope;
        var carrier = raw;
        switch (node.tag) {
            .function_declaration, .function_expression, .function, .method_definition => {
                if (!ast.hasExtra(node.data.extra, 1)) continue;
                const params = ast.readExtraNode(node.data.extra, 1);
                if (!params.isNone()) {
                    if (@backingInt(params) >= ast.nodes.items.len or ast.getNode(params).tag != .formal_parameters or
                        ambiguous_parameters.contains(@backingInt(params))) continue;
                    if (graph.scope_owner_map.get(@backingInt(params))) |parameter_scope| {
                        if (parameter_scope >= graph.scopes.len or parameter_scope == body_scope or
                            graph.scopes[parameter_scope].kind != .function or
                            @backingInt(graph.scopes[body_scope].parent) != parameter_scope) continue;
                        scope = parameter_scope;
                        carrier = @backingInt(params);
                    }
                }
            },
            .ts_enum_declaration, .ts_module_declaration => {
                if (node.tag == .ts_module_declaration and node.data.binary.flags != 0) continue;
                if (node.tag == .ts_enum_declaration and
                    (!ast.hasExtra(node.data.extra, 3) or ast.readExtra(node.data.extra, 3) & 2 != 0)) continue;
                const role: SyntheticKind = if (node.tag == .ts_enum_declaration) .enum_iife_parameter else .namespace_iife_parameter;
                var parameters: usize = 0;
                var invalid = false;
                for (symbols) |symbol| {
                    if (symbol.synthetic_kind != role or @backingInt(symbol.scope_id) != scope) continue;
                    parameters += 1;
                    if (symbol.kind != .parameter) invalid = true;
                }
                if (invalid or parameters != 1) continue;
            },
            else => continue,
        }
        const frame = try scope_frames.getOrPut(allocator, scope);
        if (frame.found_existing and frame.value_ptr.node != raw)
            try invalid_scopes.put(allocator, scope, {});
        frame.value_ptr.* = .{ .node = raw, .carrier = carrier };
    }
    var frames = scope_frames.iterator();
    while (frames.next()) |entry| {
        const scope = entry.key_ptr.*;
        if (invalid_scopes.contains(scope)) continue;
        const engine = engines.get(scope) orelse continue;
        try result.put(allocator, entry.value_ptr.carrier, engine);
    }
    return result;
}

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
    unresolved_reference_nodes: *const std.AutoHashMapUnmanaged(u32, void),
    explicit_global_reference_nodes: *const std.AutoHashMapUnmanaged(u32, void),
    actual_class_self_symbols: *const std.AutoHashMapUnmanaged(u32, u32),
    resolved_class_self_symbols: *const std.AutoHashMapUnmanaged(u32, u32),
) !PostMinifyReport {
    return checkPostMinifyImpl(
        allocator,
        ast,
        root,
        actual_symbol_ids,
        resolved_symbol_ids,
        actual_symbols,
        resolved_symbols,
        pre_minify_references,
        helper_ref_nodes,
        helper_scope_map,
        unresolved_reference_nodes,
        explicit_global_reference_nodes,
        actual_class_self_symbols,
        resolved_class_self_symbols,
        null,
    );
}

pub fn checkPostMinifyWithNativeOwners(
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
    unresolved_reference_nodes: *const std.AutoHashMapUnmanaged(u32, void),
    explicit_global_reference_nodes: *const std.AutoHashMapUnmanaged(u32, void),
    actual_class_self_symbols: *const std.AutoHashMapUnmanaged(u32, u32),
    resolved_class_self_symbols: *const std.AutoHashMapUnmanaged(u32, u32),
    actual_native_owners: PostMinifyNativeOwners,
    resolved_native_owners: PostMinifyNativeOwners,
) !PostMinifyReport {
    return checkPostMinifyImpl(
        allocator,
        ast,
        root,
        actual_symbol_ids,
        resolved_symbol_ids,
        actual_symbols,
        resolved_symbols,
        pre_minify_references,
        helper_ref_nodes,
        helper_scope_map,
        unresolved_reference_nodes,
        explicit_global_reference_nodes,
        actual_class_self_symbols,
        resolved_class_self_symbols,
        .{ .actual = actual_native_owners, .resolved = resolved_native_owners },
    );
}

fn checkPostMinifyImpl(
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
    unresolved_reference_nodes: *const std.AutoHashMapUnmanaged(u32, void),
    explicit_global_reference_nodes: *const std.AutoHashMapUnmanaged(u32, void),
    actual_class_self_symbols: *const std.AutoHashMapUnmanaged(u32, u32),
    resolved_class_self_symbols: *const std.AutoHashMapUnmanaged(u32, u32),
    native_owners: ?PostMinifyNativeOwnerPair,
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
        if (!reference.node_index.isNone()) try pre_reference_ids.put(allocator, @backingInt(reference.node_index), @backingInt(reference.symbol_id));
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
        if (actual.? >= actual_symbols.len or resolved.? >= resolved_symbols.len) {
            report.invalid_binding_id += 1;
            continue;
        }
        try bound_actual_ids.put(allocator, actual.?, {});
        try binding_pairs.put(allocator, (@as(u64, actual.?) << 32) | resolved.?, {});
    }

    // Named classes have a separate inner self-binding used by references in
    // the class body. It is attached to the class owner, not an AST binding node.
    for (reachable) |owner| {
        if (owner >= ast.nodes.items.len) continue;
        const owner_node = ast.nodes.items[owner];
        switch (owner_node.tag) {
            .class_declaration, .class_expression => {},
            else => continue,
        }
        const has_name = ast.hasExtra(owner_node.data.extra, ast_mod.ClassExtra.name) and
            !(@as(NodeIndex, @fromBackingInt(@intCast(ast.extra_data.items[owner_node.data.extra + ast_mod.ClassExtra.name])))).isNone();
        const owner_key = spanKey(owner_node.span);
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
        const resolved = resolved_class_self_symbols.get(owner);
        if ((actual != null and actual.? >= actual_symbols.len) or
            (resolved != null and resolved.? >= resolved_symbols.len))
        {
            report.invalid_binding_id += 1;
            continue;
        }
        if (actual == null or resolved == null) {
            // Named classes have an inner immutable self-binding even though
            // the class name AST node represents the declaration binding.
            // Without both owner maps, the generic span/name matcher below
            // can pair that inner binding with the outer declaration and hide
            // a reference that resolves to the wrong one.
            // Some transforms deliberately move the class-self identity to a
            // concrete wrapper binding and make the emitted class anonymous.
            // Accept that only when the AST binding pass above already proved
            // an exact actual-to-resolved pair; span/name fallback is not proof.
            const relocated_to_output_binding = if (actual) |actual_id|
                bound_actual_ids.contains(actual_id)
            else
                false;
            if (!relocated_to_output_binding and (has_name or actual != null or resolved != null))
                report.missing_binding_id += 1;
            continue;
        }
        const actual_id = actual.?;
        if (actual_id >= actual_symbols.len or resolved.? >= resolved_symbols.len) {
            report.invalid_binding_id += 1;
            continue;
        }
        report.bindings_checked += 1;
        try bound_actual_ids.put(allocator, actual_id, {});
        try binding_pairs.put(allocator, (@as(u64, actual_id) << 32) | resolved.?, {});
    }

    if (native_owners) |owners| {
        var actual_native = try collectPostMinifyNativeBindings(allocator, ast, reachable, actual_symbol_ids, actual_symbols, owners.actual);
        defer actual_native.deinit(allocator);
        var resolved_native = try collectPostMinifyNativeBindings(allocator, ast, reachable, resolved_symbol_ids, resolved_symbols, owners.resolved);
        defer resolved_native.deinit(allocator);
        var native = actual_native.iterator();
        while (native.next()) |entry| {
            const resolved = resolved_native.get(entry.key_ptr.*) orelse continue;
            const actual = entry.value_ptr.*;
            // A source var may share native arguments storage. Its real AST
            // declaration pair already owns the binding and takes precedence.
            if (bound_actual_ids.contains(actual)) continue;
            report.bindings_checked += 1;
            try bound_actual_ids.put(allocator, actual, {});
            try binding_pairs.put(allocator, (@as(u64, actual) << 32) | resolved, {});
        }
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
        if (actual_symbol.synthetic_kind == .implicit_arguments) continue;
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
        const raw = @backingInt(reference_node);
        if (raw >= ast.nodes.items.len) continue;
        if (ast.nodes.items[raw].tag == .binding_identifier or declaration_nodes.contains(raw)) continue;
        report.references_checked += 1;
        const actual = if (raw < actual_symbol_ids.len) actual_symbol_ids[raw] else null;
        const resolved = if (raw < resolved_symbol_ids.len) resolved_symbol_ids[raw] else null;
        const name = ast.getText(ast.nodes.items[raw].data.string_ref);
        if ((actual != null and actual.? >= actual_symbols.len) or
            (resolved != null and resolved.? >= resolved_symbols.len))
        {
            report.invalid_reference_id += 1;
            continue;
        }
        const expected_helper = helper_scope_map.get(name);
        if (expected_helper != null and expected_helper.? >= actual_symbols.len) {
            report.invalid_reference_id += 1;
            continue;
        }
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
        if (explicit_global_reference_nodes.contains(raw)) {
            if (actual != null or resolved != null) {
                report.shadowed_external_reference += 1;
                continue;
            }
            report.external_references += 1;
            continue;
        }
        if (actual == null and resolved == null) {
            if (unresolved_reference_nodes.contains(raw)) {
                report.external_references += 1;
            } else {
                report.unproven_external_reference += 1;
            }
            continue;
        }
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

const NativePostMutation = enum {
    none,
    foreign_reference,
    same_number_foreign_reference,
    missing_actual_owner,
    missing_resolved_owner,
    different_parameter_carrier,
    wrong_scope,
    wrong_scope_kind,
    wrong_kind,
    wrong_role,
    explicit_formal_engine,
    duplicate_actual_engine,
    duplicate_resolved_engine,
    wrong_iife_parameter_kind,
    duplicate_iife_parameter,
    wrong_iife_parameter_role,
};

fn checkNativePostPair(source: []const u8, typescript: bool, mutation: NativePostMutation) !void {
    return checkNativePostPairMode(source, typescript, false, mutation);
}

fn checkNativePostPairMode(source: []const u8, typescript: bool, sloppy: bool, mutation: NativePostMutation) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var scanner = try Scanner.init(a, source);
    var parser = @import("../parser/parser.zig").Parser.init(a, &scanner);
    parser.configureFromExtension(if (typescript) ".ts" else if (sloppy) ".cjs" else ".mjs");
    const root = try parser.parse();
    try std.testing.expectEqual(@as(usize, 0), parser.errors.items.len);
    const Analyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer;
    var actual = Analyzer.init(a, &parser.ast);
    actual.is_module = !sloppy;
    actual.is_ts = typescript;
    actual.enable_stmt_info = true;
    actual.collect_unresolved_reference_nodes = true;
    try actual.analyze();
    var resolved = Analyzer.init(a, &parser.ast);
    resolved.is_module = !sloppy;
    resolved.is_ts = typescript;
    resolved.collect_unresolved_reference_nodes = true;
    try resolved.analyze();
    try std.testing.expectEqual(@as(usize, 0), actual.errors.items.len);
    try std.testing.expectEqual(@as(usize, 0), resolved.errors.items.len);
    var actual_symbols: std.ArrayList(Symbol) = .empty;
    try actual_symbols.appendSlice(a, actual.symbols.items);
    const actual_ids = try a.dupe(?u32, actual.symbol_ids.items);
    const actual_scopes = try a.dupe(Scope, actual.scopes.items);
    var actual_owners = try actual.scope_owner_map.clone(a);
    var resolved_owners = try resolved.scope_owner_map.clone(a);
    // Give the independently analyzed graph a different SID numbering. Only
    // the columns consumed by this oracle are projected; owner ScopeIds stay
    // local to that graph, and no numeric equality is identity evidence.
    var resolved_symbols: std.ArrayList(Symbol) = .empty;
    for (0..resolved.symbols.items.len) |i|
        try resolved_symbols.append(a, resolved.symbols.items[resolved.symbols.items.len - 1 - i]);
    const resolved_ids = try a.dupe(?u32, resolved.symbol_ids.items);
    for (resolved_ids) |*id| if (id.*) |old| {
        id.* = @intCast(resolved.symbols.items.len - 1 - old);
    };
    var resolved_classes = try resolved.class_self_symbol_map.clone(a);
    var class_ids = resolved_classes.valueIterator();
    while (class_ids.next()) |id| id.* = @intCast(resolved.symbols.items.len - 1 - id.*);

    var selected: ?u32 = null;
    var foreign: ?u32 = null;
    for (actual_symbols.items, 0..) |symbol, sid| {
        if (symbol.synthetic_kind != .implicit_arguments) continue;
        if (selected == null) selected = @intCast(sid) else if (foreign == null) foreign = @intCast(sid);
    }
    const engine = selected orelse return error.MissingNativeEngine;
    const scope = @backingInt(actual_symbols.items[engine].scope_id);
    var engine_read: ?u32 = null;
    for (actual_ids, 0..) |id, raw| {
        if (id == engine and parser.ast.nodes.items[raw].tag == .identifier_reference) {
            engine_read = @intCast(raw);
            break;
        }
    }
    const read = engine_read orelse return error.MissingNativeEngineRead;
    var carrier: ?u32 = null;
    var owner_iter = actual_owners.iterator();
    while (owner_iter.next()) |entry| {
        if (entry.value_ptr.* == scope) carrier = entry.key_ptr.*;
    }
    const owner = carrier orelse return error.MissingNativeEngineOwner;
    switch (mutation) {
        .none => {},
        .foreign_reference => actual_ids[read] = foreign orelse return error.MissingForeignEngine,
        .same_number_foreign_reference => {
            const decoy = foreign orelse return error.MissingForeignEngine;
            const expected = resolved_ids[read].?;
            std.mem.swap(Symbol, &resolved_symbols.items[expected], &resolved_symbols.items[decoy]);
            for (resolved_ids) |*id| {
                if (id.* == expected) id.* = decoy else if (id.* == decoy) id.* = expected;
            }
            var classes = resolved_classes.valueIterator();
            while (classes.next()) |id| {
                if (id.* == expected) id.* = decoy else if (id.* == decoy) id.* = expected;
            }
            actual_ids[read] = decoy;
            try std.testing.expectEqual(actual_ids[read], resolved_ids[read]);
        },
        .missing_actual_owner => _ = actual_owners.remove(owner),
        .missing_resolved_owner => _ = resolved_owners.remove(owner),
        .different_parameter_carrier => {
            try std.testing.expectEqual(Node.Tag.formal_parameters, parser.ast.nodes.items[owner].tag);
            var body_scope: ?u32 = null;
            for (actual_scopes, 0..) |candidate, sid| {
                if (@backingInt(candidate.parent) == scope and candidate.kind == .function) {
                    body_scope = @intCast(sid);
                    break;
                }
            }
            _ = actual_owners.remove(owner);
            actual_symbols.items[engine].scope_id = @fromBackingInt(body_scope orelse return error.MissingNativeBodyScope);
        },
        .wrong_scope => actual_symbols.items[engine].scope_id = @fromBackingInt(@as(u32, 0)),
        .wrong_scope_kind => actual_scopes[scope].kind = .block,
        .wrong_kind => actual_symbols.items[engine].kind = .variable_let,
        .wrong_role => actual_symbols.items[engine].synthetic_kind = null,
        .explicit_formal_engine => {
            var formal: ?u32 = null;
            for (actual_ids, 0..) |id, raw| {
                const sid = id orelse continue;
                if (parser.ast.nodes.items[raw].tag == .binding_identifier and
                    actual_symbols.items[sid].kind == .parameter and
                    @backingInt(actual_symbols.items[sid].scope_id) == scope and sid != engine)
                {
                    formal = sid;
                    break;
                }
            }
            const forged = formal orelse return error.MissingExplicitFormal;
            actual_symbols.items[engine].synthetic_kind = null;
            actual_symbols.items[forged].synthetic_kind = .implicit_arguments;
            actual_ids[read] = forged;
        },
        .duplicate_actual_engine => try actual_symbols.append(a, actual_symbols.items[engine]),
        .duplicate_resolved_engine => try resolved_symbols.append(a, resolved_symbols.items[resolved_ids[read].?]),
        .wrong_iife_parameter_kind, .duplicate_iife_parameter, .wrong_iife_parameter_role => {
            var parameter: ?usize = null;
            for (actual_symbols.items, 0..) |symbol, sid| {
                if (@backingInt(symbol.scope_id) == scope and
                    (symbol.synthetic_kind == .namespace_iife_parameter or symbol.synthetic_kind == .enum_iife_parameter)) parameter = sid;
            }
            const sid = parameter orelse return error.MissingIifeParameter;
            switch (mutation) {
                .wrong_iife_parameter_kind => actual_symbols.items[sid].kind = .variable_var,
                .duplicate_iife_parameter => try actual_symbols.append(a, actual_symbols.items[sid]),
                .wrong_iife_parameter_role => actual_symbols.items[sid].synthetic_kind = .bundler_runtime_helper,
                else => unreachable,
            }
        },
    }
    const report = try checkPostMinifyWithNativeOwners(
        a,
        &parser.ast,
        root,
        actual_ids,
        resolved_ids,
        actual_symbols.items,
        resolved_symbols.items,
        actual.references.items,
        &.{},
        &actual.helper_scope_map,
        &resolved.unresolved_reference_nodes,
        &std.AutoHashMapUnmanaged(u32, void).empty,
        &actual.class_self_symbol_map,
        &resolved_classes,
        .{ .scopes = actual_scopes, .scope_owner_map = &actual_owners },
        .{ .scopes = resolved.scopes.items, .scope_owner_map = &resolved_owners },
    );
    if (mutation == .none) {
        try std.testing.expect(report.isClean());
        const conservative = try checkPostMinify(
            a,
            &parser.ast,
            root,
            actual_ids,
            resolved_ids,
            actual_symbols.items,
            resolved_symbols.items,
            actual.references.items,
            &.{},
            &actual.helper_scope_map,
            &resolved.unresolved_reference_nodes,
            &std.AutoHashMapUnmanaged(u32, void).empty,
            &actual.class_self_symbol_map,
            &resolved_classes,
        );
        if (actual_symbols.items[engine].kind == .variable_var) {
            try std.testing.expect(conservative.isClean());
            try std.testing.expectEqual(conservative.bindings_checked, report.bindings_checked);
        } else try std.testing.expect(conservative.dangling_reference_id > 0);
    } else {
        try std.testing.expect(!report.isClean());
        if (mutation == .foreign_reference or mutation == .same_number_foreign_reference or mutation == .explicit_formal_engine)
            try std.testing.expect(report.wrong_reference_target > 0);
    }
}

test "post-minify native arguments pairs ten current AST owner forms with independently numbered SIDs" {
    const sources = [_]struct { source: []const u8, ts: bool = false }{
        .{ .source = "function read(value){return arguments[0]}" },
        .{ .source = "function read(value=1){return arguments[0]}" },
        .{ .source = "function read(...values){return arguments.length+values.length}" },
        .{ .source = "function read({value}){return arguments[0]+value}" },
        .{ .source = "const object={read(value=1){return arguments[0]}}" },
        .{ .source = "class Read{read(value=1){return arguments[0]}}" },
        .{ .source = "function read(value){return(()=>arguments[0])()}" },
        .{ .source = "async function* read(value=1){yield arguments[0]}" },
        .{ .source = "namespace N{export const value=arguments.length}", .ts = true },
        .{ .source = "enum E{A=arguments.length}", .ts = true },
    };
    for (sources) |source| try checkNativePostPair(source.source, source.ts, .none);
}

test "post-minify native arguments rejects foreign owners numeric decoys and forged engine roles" {
    for (std.meta.tags(NativePostMutation)) |mutation| {
        if (mutation == .none) continue;
        const iife = mutation == .wrong_iife_parameter_kind or mutation == .duplicate_iife_parameter or mutation == .wrong_iife_parameter_role;
        try checkNativePostPair(if (iife)
            "namespace N{export const value=arguments.length}"
        else
            "function left(value=1){return arguments[0]}function right(value=2){return arguments[0]}", iife, mutation);
    }
}

test "post-minify native arguments source var keeps its existing AST binding authority" {
    // A source var called arguments is valid in this sloppy CJS function;
    // strict ESM rejects that source binding before this oracle can run.
    try checkNativePostPairMode("function read(value){var arguments;return arguments[0]}", false, true, .none);
}

pub fn printPostMinify(file_path: []const u8, report: PostMinifyReport) void {
    std.debug.print(
        "zntc: symbol-identity-post-minify {s}: bindings={d} references={d} external={d} helpers={d} preserved_transform_refs={d} invalid_binding_id={d} invalid_reference_id={d} missing_binding_id={d} missing_reference_id={d} dangling_reference_id={d} wrong_reference_target={d} shadowed_external_reference={d} unproven_external_reference={d} clean={d}\n",
        .{
            file_path,
            report.bindings_checked,
            report.references_checked,
            report.external_references,
            report.helper_references,
            report.preserved_transform_references,
            report.invalid_binding_id,
            report.invalid_reference_id,
            report.missing_binding_id,
            report.missing_reference_id,
            report.dangling_reference_id,
            report.wrong_reference_target,
            report.shadowed_external_reference,
            report.unproven_external_reference,
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
        "namespace_iife_params={d} namespace_iife_param_mismatch={d} enum_iife_params={d} enum_iife_param_mismatch={d} helper_symbol_mismatch={d} scope_resolution_mismatch={d} invisible_reference={d} unclassified_reference={d} reference_statement_mismatch={d} reference_scope_statement_alias={d} reference_node_use_alias={d} declaration_scope_mismatch={d} declaration_identity_mismatch={d} declaration_anchor_mismatch={d} reference_count_mismatch={d} write_count_mismatch={d}",
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
            report.declaration_identity_mismatch,
            report.declaration_anchor_mismatch,
            report.reference_count_mismatch,
            report.write_count_mismatch,
        },
    ) catch unreachable;
    std.debug.print(
        "zntc: {s} {s}: generated_bindings={d} generated_references={d} generated_scope_owners_checked={d} external={d} declaration_anchors_checked={d} missing_binding={d} invalid_reference_node={d} unreachable_reference={d} {s} shadowed_external_reference={d} invalid_id={d} missing_reference={d} duplicate_reference={d} identity_mismatch={d} binding_scope_mismatch={d} binding_scope_unknown={d} invalid_scope={d} reference_scope_mismatch={d} scope_map_mismatch={d} scope_owner_mismatch={d} scope_owner_parent_mismatch={d} duplicate_scope_owner={d} scope_strictness_mismatch={d} {s} clean={d} legacy_debt_fingerprint={x} schema_fingerprint={x}\n",
        .{
            name,
            file_path,
            report.generated_bindings,
            report.generated_references,
            report.generated_scope_owners_checked,
            report.external_references,
            report.declaration_anchors_checked,
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
            report.scope_strictness_mismatch,
            secondary_counts,
            @intFromBool(report.isClean()),
            report.legacy_debt_fingerprint,
            ExactReport.schemaFingerprint(),
        },
    );
    if (report.first_missing_binding) |finding| printExactFinding(file_path, "missing_binding", finding);
    if (report.first_missing_reference) |finding| printExactFinding(file_path, "missing_reference", finding);
    if (report.first_declaration_anchor_mismatch) |finding| printExactFinding(file_path, "declaration_anchor_mismatch", finding);
    if (report.first_unclassified_reference) |finding| printExactFinding(file_path, "unclassified_reference", finding);
    if (report.first_shadowed_external_reference) |finding| printExactFinding(file_path, "shadowed_external_reference", finding);
    printExactDiagnostics(file_path, report);
}

/// Report scope ownership against the original analyzed AST, before lowering
/// can move lexical owners into wrappers that preserve their source ScopeIds.
pub fn printSourceScopeOwnerAudit(file_path: []const u8, report: ExactReport) void {
    std.debug.print(
        "zntc: symbol-source-scope-owner {s}: scope_owner_mismatch={d} scope_owner_parent_mismatch={d} duplicate_scope_owner={d}\n",
        .{
            file_path,
            report.scope_owner_mismatch,
            report.scope_owner_parent_mismatch,
            report.duplicate_scope_owner,
        },
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
    if (report.first_scope_strictness_mismatch) |finding| {
        var parent_buffer: [16]u8 = undefined;
        std.debug.print(
            "zntc: symbol-identity-detail {s}: scope_strictness_mismatch scope={d} parent={s} issue={s}\n",
            .{
                file_path,
                finding.scope_id,
                optionalIndexText(&parent_buffer, finding.parent_scope_id),
                finding.issue,
            },
        );
    }
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

const strict_status_count = @typeInfo(StrictStatus).@"enum".field_names.len;

const StrictStatusPolicy = enum {
    accepted_bound,
    accepted_external,
    binding_scope_delegated,
    must_be_zero,
};

fn strictStatusPolicy(status: StrictStatus) StrictStatusPolicy {
    return switch (status) {
        .bound => .accepted_bound,
        .external => .accepted_external,
        .scope_mismatch => .binding_scope_delegated,
        .missing_binding,
        .unclassified,
        .invalid_id,
        .name_mismatch,
        .missing_reference,
        .identity_mismatch,
        .invalid_scope,
        .scope_unknown,
        .scope_ambiguous,
        .invisible_reference,
        .duplicate_reference,
        => .must_be_zero,
    };
}

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
    counts: [strict_status_count]usize = @splat(0),
    marked_synthetic: usize = 0,
    orphan_symbols: usize = 0,
    cyclic_ast_edges: usize = 0,
    findings: std.ArrayList(StrictFinding) = .empty,
    orphan_symbol_findings: std.ArrayList(OrphanSyntheticSymbol) = .empty,

    pub fn statusCount() usize {
        return strict_status_count;
    }

    /// Pin the enum-backed counter schema independently of the hand-written
    /// diagnostic line. Adding or renaming a status must update the fixture
    /// gate instead of silently leaving the new counter unreported.
    pub fn statusSchemaFingerprint() u64 {
        var hash: u64 = 0xcbf29ce484222325;
        feedSchemaFingerprint(&hash, "zntc.StrictStatus/v2\x00");
        inline for (std.meta.tags(StrictStatus)) |status| {
            feedSchemaFingerprint(&hash, @tagName(status));
            feedSchemaFingerprint(&hash, "\x00");
            feedSchemaFingerprint(&hash, @tagName(strictStatusPolicy(status)));
            feedSchemaFingerprint(&hash, "\n");
        }
        return hash;
    }

    pub fn deinit(self: *StrictReport, allocator: std.mem.Allocator) void {
        self.findings.deinit(allocator);
        self.orphan_symbol_findings.deinit(allocator);
    }

    /// Keep aggregate counters and emitted diagnostic details tied together.
    /// The checker updates both while walking the AST; a drift here would let
    /// a zeroed counter hide a failing finding (or hide a dropped finding).
    pub fn isConsistent(self: *const StrictReport) bool {
        var observed_counts: [strict_status_count]usize = @splat(0);
        var observed_marked_synthetic: usize = 0;
        for (self.findings.items) |finding| {
            observed_counts[@backingInt(finding.status)] += 1;
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
            switch (strictStatusPolicy(@fromBackingInt(@intCast(status)))) {
                .accepted_bound, .accepted_external => {},
                .binding_scope_delegated, .must_be_zero => if (count != 0) return false,
            }
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
            switch (strictStatusPolicy(@fromBackingInt(@intCast(status)))) {
                .accepted_bound, .accepted_external, .binding_scope_delegated => {},
                .must_be_zero => if (count != 0) return false,
            }
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
    scope_owner_map: *const std.AutoHashMapUnmanaged(u32, u32),
    references: *const std.AutoHashMapUnmanaged(u32, ReferenceEvidence),
    synthetic: ?*const std.AutoHashMapUnmanaged(u32, void),
    external_evidence: ?StrictExternalEvidence,
    reachable_binding_symbols: *std.AutoHashMapUnmanaged(u32, void),
    report: *StrictReport,
    seen: std.AutoHashMapUnmanaged(u32, void) = .empty,
    oom: bool = false,

    fn add(self: *StrictCtx, idx: NodeIndex, node: Node) void {
        const raw = @backingInt(idx);
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
        self.report.counts[@backingInt(status)] += 1;
        if (marked) self.report.marked_synthetic += 1;
        self.report.findings.append(self.allocator, .{
            .node = raw,
            .name = name,
            .tag = node.tag,
            .status = status,
            .marked_synthetic = marked,
            .symbol_id = sid,
            .reference_symbol_id = if (reference) |e| @backingInt(e.reference.symbol_id) else null,
            .expected_scope_id = if (trace) |s| s.scope_id else null,
            .symbol_scope_id = if (sid) |id| if (id < self.symbols.len) @backingInt(self.symbols[id].scope_id) else null else null,
            .symbol_origin_scope_id = if (sid) |id| if (id < self.symbols.len) @backingInt(self.symbols[id].origin_scope) else null else null,
            .reference_scope_id = if (reference) |e| @backingInt(e.reference.scope_id) else null,
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
            if (!validScope(@fromBackingInt(@intCast(lexical_scope)), self.scopes)) return .invalid_scope;
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
            if (@backingInt(symbol.scope_id) != declaration_scope) return .scope_mismatch;
            // scope_id is the binding's current output storage scope.
            // origin_scope is source provenance and may name a detached
            // source scope after lowering moves the binding into generated
            // output. It must remain valid, but is not the output AST scope.
            return .bound;
        }

        const evidence = reference orelse return .missing_reference;
        if (evidence.count != 1) return .duplicate_reference;
        if (@backingInt(evidence.reference.symbol_id) != id) return .identity_mismatch;
        if (!validScope(evidence.reference.scope_id, self.scopes) or !validScope(symbol.scope_id, self.scopes)) return .invalid_scope;
        const expected = trace orelse return .scope_unknown;
        if (expected.ambiguous) return .scope_ambiguous;
        if (!expected.valid) return .invalid_scope;
        const expected_scope = expected.scope_id orelse return .scope_unknown;
        if (@backingInt(evidence.reference.scope_id) != expected_scope) return .scope_mismatch;
        if (!visibleFrom(symbol.scope_id, evidence.reference.scope_id, self.scopes)) return .invisible_reference;
        if (symbol.synthetic_kind == .implicit_arguments) {
            const native_owner = nativeArgumentsOwnerScope(self.ast, raw, self.scope_owner_map, self.parent_traces, self.symbols) orelse return .scope_unknown;
            if (native_owner != @backingInt(symbol.scope_id)) return .invisible_reference;
        }
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
        if (parent_visit.node.isNone() or @as(usize, @backingInt(parent_visit.node)) >= ast.nodes.items.len) continue;
        const raw = @backingInt(parent_visit.node);
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

/// Sloppy Annex B (B.3.3): a function declared in a block is also assigned to
/// the enclosing function's var binding each time the block runs. The analyzer
/// models that as one binding — the block's scope map aliases the var-scope
/// function symbol — and output keeps that single shared identity (#5773), as
/// esbuild and SWC do. Such a block entry/declaration is not a scope mismatch.
fn isAnnexBBlockFunctionAlias(scopes: []const Scope, symbol: *const Symbol, block_scope: u32) bool {
    // A same-named `var` and its block functions are one binding as well (#5803).
    if (!(symbol.kind.isFunctionLike() or symbol.kind == .variable_var)) return false;
    if (!validScope(symbol.scope_id, scopes) or block_scope >= scopes.len) return false;
    if (!scopes[symbol.scope_id.toIndex()].kind.isVarScope()) return false;
    const block = scopes[block_scope];
    if (block.kind.isVarScope() or block.is_strict) return false;
    return nearestVarScope(block_scope, scopes) == @as(?u32, symbol.scope_id.toIndex());
}

// Native Annex B declarations execute V=L at each actual declaration. The
// analyzer records those operations in symbol counts without identifier rows.
fn accountNativeAnnexBAssignments(
    allocator: std.mem.Allocator,
    ast: *const Ast,
    reachable_nodes: *const std.AutoHashMapUnmanaged(u32, void),
    symbol_ids: []const ?u32,
    symbols: []const Symbol,
    scopes: []const Scope,
    value_counts: []usize,
    write_counts: []usize,
    report: *ExactReport,
) !void {
    var has_roles = false;
    for (symbols) |symbol| {
        if (symbol.binding_instantiation.annex_b or !symbol.annex_b_alias.variable.isNone() or symbol.annex_b_alias.source_assignment_count != 0) {
            has_roles = true;
            break;
        }
    }
    if (!has_roles) return;
    const annex = @import("../semantic/annex_b_function.zig");
    const observed = try allocator.alloc(usize, symbols.len);
    defer allocator.free(observed);
    @memset(observed, 0);
    var declarations = reachable_nodes.iterator();
    while (declarations.next()) |entry| {
        const index: NodeIndex = @fromBackingInt(entry.key_ptr.*);
        const declaration = ast.getNode(index);
        if (declaration.tag != .function_declaration) continue;
        if (ast.readExtraNode(declaration.data.extra, ast_mod.FunctionExtra.name).isNone()) continue;
        const role = (annex.forDeclaration(ast, symbol_ids, symbols, index) catch {
            report.declaration_identity_mismatch += 1;
            continue;
        }) orelse continue;
        if (role.state != .native) continue;
        const lexical = @backingInt(role.lexical);
        const variable = @backingInt(role.variable);
        const lexical_scope = symbols[lexical].scope_id;
        const variable_scope = symbols[variable].scope_id;
        if (!exactValidScope(scopes, lexical_scope) or !exactValidScope(scopes, variable_scope) or
            scopes[lexical_scope.toIndex()].is_strict or
            nearestVarScope(lexical_scope.toIndex(), scopes) != variable_scope.toIndex())
        {
            report.declaration_scope_mismatch += 1;
            continue;
        }
        // The pair is selected only by its typed source role. Spelling equality
        // checks that role's consistency; it never selects a replacement SID.
        const lexical_name = try Scanner.decodeIdentifierEscapesAlloc(allocator, exactSymbolName(ast, &symbols[lexical]));
        defer if (lexical_name.ptr != exactSymbolName(ast, &symbols[lexical]).ptr) allocator.free(lexical_name);
        const variable_name = try Scanner.decodeIdentifierEscapesAlloc(allocator, exactSymbolName(ast, &symbols[variable]));
        defer if (variable_name.ptr != exactSymbolName(ast, &symbols[variable]).ptr) allocator.free(variable_name);
        if (!std.mem.eql(u8, lexical_name, variable_name)) {
            report.declaration_identity_mismatch += 1;
            continue;
        }
        observed[lexical] += 1;
        value_counts[lexical] += 1;
        value_counts[variable] += 1;
        write_counts[variable] += 1;
    }
    for (symbols, 0..) |symbol, sid| {
        const alias = symbol.annex_b_alias;
        if (alias.variable.isNone() or alias.state != .native) continue;
        if (observed[sid] != alias.source_assignment_count) report.declaration_identity_mismatch += 1;
    }
}

fn nearestVarScope(start: u32, scopes: []const Scope) ?u32 {
    var current: ScopeId = @fromBackingInt(@intCast(start));
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
        if (scope_visit.node.isNone() or @as(usize, @backingInt(scope_visit.node)) >= ast.nodes.items.len) continue;
        const raw = @backingInt(scope_visit.node);
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
                @backingInt(child),
            )) |name_scope|
                ScopePath{ .scope_id = name_scope, .valid = true }
            else if (childSkipsScopeOwner(ast, raw, @backingInt(child)))
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
        const raw = @backingInt(reference.node_index);
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
        const raw = @backingInt(idx);
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

/// Enum/namespace IIFEs are emitted by their TypeScript creators. Their one
/// real IIFE parameter role independently witnesses the ordinary native frame.
fn nativeArgumentsFrameScope(
    ast: *const Ast,
    raw: u32,
    owners: *const std.AutoHashMapUnmanaged(u32, u32),
    symbols: []const Symbol,
) ?u32 {
    if (raw >= ast.nodes.items.len) return null;
    const node = ast.nodes.items[raw];
    const body_scope = owners.get(raw) orelse return null;
    switch (node.tag) {
        .function_declaration, .function_expression, .function, .method_definition => {
            if (!ast.hasExtra(node.data.extra, 1)) return null;
            const params = ast.readExtraNode(node.data.extra, 1);
            return if (!params.isNone()) owners.get(@backingInt(params)) orelse body_scope else body_scope;
        },
        .ts_enum_declaration, .ts_module_declaration => {
            const required: SyntheticKind = if (node.tag == .ts_enum_declaration) .enum_iife_parameter else .namespace_iife_parameter;
            var parameter: ?*const Symbol = null;
            for (symbols) |*symbol| {
                if (symbol.synthetic_kind != required or @backingInt(symbol.scope_id) != body_scope) continue;
                if (parameter != null or symbol.kind != .parameter) return null;
                parameter = symbol;
            }
            const actual = parameter orelse return null;
            const name = if (actual.synthetic_name.len > 0) actual.synthetic_name else ast.getText(actual.name);
            if (@import("../lexer/scanner.zig").Scanner.identifierNamesEqual(name, "arguments")) return null;
            return body_scope;
        },
        else => return null,
    }
}

/// Select native arguments storage from actual AST evaluation boundaries.
/// Arrows inherit it; method keys/decorators evaluate outside the method.
fn nativeArgumentsOwnerScope(
    ast: *const Ast,
    raw: u32,
    owners: *const std.AutoHashMapUnmanaged(u32, u32),
    parents: anytype,
    symbols: []const Symbol,
) ?u32 {
    var child = raw;
    var decorator = false;
    var hops: usize = 0;
    while (hops <= ast.nodes.items.len) : (hops += 1) {
        const entry = parents.get(child) orelse return null;
        const parent: u32 = if (@TypeOf(entry) == u32) entry else blk: {
            if (entry.ambiguous) return null;
            break :blk entry.parent;
        };
        if (parent >= ast.nodes.items.len) return null;
        const node = ast.nodes.items[parent];
        if (node.tag == .decorator) decorator = true;
        if (node.tag == .static_block) return null;
        if (node.tag == .property_definition or node.tag == .accessor_property) {
            if (!ast.hasExtra(node.data.extra, ast_mod.PropertyExtra.init)) return null;
            if (child == @backingInt(ast.readExtraNode(node.data.extra, ast_mod.PropertyExtra.init))) return null;
            decorator = false;
        }
        switch (node.tag) {
            .ts_enum_declaration, .ts_module_declaration => return nativeArgumentsFrameScope(ast, parent, owners, symbols),
            .function_declaration, .function_expression, .function, .method_definition => {
                if (!ast.hasExtra(node.data.extra, 2)) return null;
                const params = ast.readExtraNode(node.data.extra, 1);
                if (node.tag == .method_definition) {
                    const body = ast.readExtraNode(node.data.extra, 2);
                    if (decorator or (child != @backingInt(params) and child != @backingInt(body))) {
                        decorator = false;
                        child = parent;
                        continue;
                    }
                }
                return nativeArgumentsFrameScope(ast, parent, owners, symbols);
            },
            else => {},
        }
        child = parent;
    }
    return null;
}

/// Native ordinary functions supply this binding without an AST formal.
/// Validate its actual function/parameter owner instead of accepting a marker
/// alone; an arrow or a sibling/global scope cannot supply native arguments.
fn hasNativeArgumentsOwner(
    ast: *const Ast,
    symbol: *const Symbol,
    scopes: []const Scope,
    scope_owner_map: *const std.AutoHashMapUnmanaged(u32, u32),
    reachable: *const std.AutoHashMapUnmanaged(u32, ScopeTrace),
    symbols: []const Symbol,
) bool {
    if (symbol.synthetic_kind != .implicit_arguments or
        (symbol.kind != .parameter and symbol.kind != .variable_var) or
        symbol.scope_id.isNone() or symbol.scope_id.toIndex() >= scopes.len or
        scopes[symbol.scope_id.toIndex()].kind != .function or
        !exactScopeMapKeyMatchesSymbol(ast, symbol, "arguments")) return false;
    var nodes = reachable.keyIterator();
    while (nodes.next()) |raw| {
        const arguments_scope = nativeArgumentsFrameScope(ast, raw.*, scope_owner_map, symbols) orelse continue;
        if (arguments_scope == @backingInt(symbol.scope_id)) return true;
    }
    return false;
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
        .scope_owner_map = scope_owner_map,
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
        if (hasNativeArgumentsOwner(ast, &symbol, scopes, scope_owner_map, &node_scopes, symbols)) continue;
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
    var buffer: [16 * 1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    const report_written = blk: {
        writer.print("zntc: synthetic-coverage {s}:", .{file_path}) catch break :blk false;
        inline for (std.meta.tags(StrictStatus)) |status| {
            writer.print(" {s}={d}", .{ @tagName(status), report.counts[@backingInt(status)] }) catch break :blk false;
        }
        writer.print(
            " orphan_symbols={d} cyclic_ast_edges={d} marked_synthetic={d} consistent={d} symbol_identity_complete={d} strict_status_count={d} strict_status_fingerprint={x}\n",
            .{ report.orphan_symbols, report.cyclic_ast_edges, report.marked_synthetic, @intFromBool(report.isConsistent()), @intFromBool(report.hasCompleteSymbolIdentity()), StrictReport.statusCount(), StrictReport.statusSchemaFingerprint() },
        ) catch break :blk false;
        break :blk true;
    };
    if (report_written) {
        std.debug.print("{s}", .{writer.buffered()});
    } else {
        // Incomplete report output must fail the integration schema gate.
        std.debug.print("zntc: synthetic-coverage {s}: report_format_overflow=1\n", .{file_path});
    }
    for (report.orphan_symbol_findings.items[0..@min(report.orphan_symbol_findings.items.len, 8)]) |finding| {
        std.debug.print("  synthetic-coverage orphan_symbol id={d} name={s} kind={s} scope={d}\n", .{
            finding.symbol_id,
            finding.name,
            @tagName(finding.kind),
            @backingInt(finding.scope_id),
        });
    }
    var printed: [strict_status_count]usize = @splat(0);
    for (report.findings.items) |finding| {
        if (finding.status == .bound or finding.status == .external) continue;
        const group = @backingInt(finding.status);
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

test "strict status schema pins the complete SymbolId and ScopeId counter set" {
    try std.testing.expectEqual(@as(usize, 14), StrictReport.statusCount());
    try std.testing.expectEqual(@as(u64, 0x37fd7382c204a61b), StrictReport.statusSchemaFingerprint());
}

test "exact coverage is not clean when a generated binding scope is unknown" {
    var report: ExactReport = .{};
    try std.testing.expect(report.isClean());
    report.binding_scope_unknown = 1;
    try std.testing.expect(!report.isClean());
}

test "exact coverage cleanliness fails closed for every invariant counter" {
    const exact_info = @typeInfo(ExactReport).@"struct";
    inline for (exact_info.field_names) |name| {
        if (comptime ExactReport.isObservationField(name) or ExactReport.isDiagnosticField(name)) continue;
        var report: ExactReport = .{};
        @field(report, name) = 1;
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
        .{ .first_declaration_anchor_mismatch = finding },
        .{ .first_unclassified_reference = finding },
        .{ .first_scope_owner_mismatch = .{ .node_index = 1, .tag = .block_statement, .issue = "test" } },
        .{ .first_scope_owner_parent_mismatch = .{ .node_index = 1, .tag = .block_statement, .issue = "test" } },
        .{ .first_duplicate_scope_owner = .{ .node_index = 2, .tag = .block_statement, .issue = "test", .first_owner_node_index = 1 } },
        .{ .first_scope_strictness_mismatch = .{ .scope_id = 2, .parent_scope_id = 1, .issue = "test" } },
        .{ .first_scope_map_mismatch = .{ .issue = "test" } },
        .{ .first_ambiguous_ast_parent = .{ .node_index = 1, .first_parent = 2, .additional_parent = 3 } },
        .{ .first_invalid_ast_root = 9 },
        .{ .first_invalid_ast_edge = .{ .parent_node_index = 1, .parent_tag = .program, .child_node_index = 9 } },
        .{ .first_invalid_ast_layout = .{ .node_index = 1, .tag = .program, .issue = .list_range, .data_index = 9 } },
        .{ .first_reference_statement_mismatch = .{ .node_index = 1, .reference_stmt_idx = 2, .expected_stmt_idx = 3 } },
        .{ .first_reference_scope_statement_alias = .{
            .node_index = 1,
            .first_parent = 2,
            .additional_parent = 3,
            .first_owner = 4,
            .additional_owner = 5,
            .first_statement_index = 6,
            .additional_statement_index = 7,
        } },
        .{ .first_reference_node_use_alias = .{
            .node_index = 1,
            .name = "x",
            .tag = .identifier_reference,
            .span_start = 0,
            .first_parent = 2,
            .first_parent_tag = .call_expression,
            .additional_parent = 3,
            .additional_parent_tag = .binary_expression,
            .additional_uses = 1,
        } },
        .{ .first_shadowed_external_reference = finding },
    };
    try std.testing.expectEqual(@as(usize, reports.len), ExactReport.schemaCounts().diagnostic_fields);
    for (reports) |report| try std.testing.expect(!report.isClean());
}

test "post-minify coverage cleanliness includes every invariant counter" {
    const post_info = @typeInfo(PostMinifyReport).@"struct";
    inline for (post_info.field_names) |name| {
        if (comptime PostMinifyReport.isObservationField(name)) continue;
        var report: PostMinifyReport = .{};
        @field(report, name) = 1;
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
    const helper_refs = [_]u32{@backingInt(helper_ref)};
    var scope_owner_map: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer scope_owner_map.deinit(allocator);
    try scope_owner_map.put(allocator, @backingInt(root), 0);
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

    const global_scope: ScopeId = @fromBackingInt(@intCast(0));
    const block_scope: ScopeId = @fromBackingInt(@intCast(1));
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
        .symbol_id = @fromBackingInt(@intCast(0)),
        .flags = .{ .read = true },
    }};
    const helper_refs = [_]u32{@backingInt(helper_ref)};
    var scope_owner_map: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer scope_owner_map.deinit(allocator);
    try scope_owner_map.put(allocator, @backingInt(root), @backingInt(global_scope));
    try scope_owner_map.put(allocator, @backingInt(block), @backingInt(block_scope));
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

fn makePostMinifyTestSymbolTable(comptime count: usize, span: Span) [count]Symbol {
    const filler: Symbol = .{
        .name = span,
        .scope_id = @fromBackingInt(@intCast(0)),
        .kind = .variable_const,
        .declaration_span = span,
    };
    return @splat(filler);
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

    const outer_scope: ScopeId = @fromBackingInt(@intCast(0));
    const inner_scope: ScopeId = @fromBackingInt(@intCast(1));
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
        .{ .node_index = ref_node, .scope_id = inner_scope, .symbol_id = @fromBackingInt(@intCast(0)), .flags = .{ .read = true } },
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
        .{ .parent = @fromBackingInt(@intCast(0)), .kind = .block, .is_strict = false },
    };
    var outer_names: std.StringHashMapUnmanaged(usize) = .empty;
    defer outer_names.deinit(allocator);
    var inner_names: std.StringHashMapUnmanaged(usize) = .empty;
    defer inner_names.deinit(allocator);
    try outer_names.put(allocator, "x", 0);
    try inner_names.put(allocator, "x", 1);
    const scope_maps = [_]std.StringHashMapUnmanaged(usize){ outer_names, inner_names };
    const symbols = [_]Symbol{
        .{ .name = name, .scope_id = @fromBackingInt(@intCast(0)), .kind = .variable_let, .declaration_span = name },
        .{ .name = name, .scope_id = @fromBackingInt(@intCast(1)), .kind = .variable_let, .declaration_span = name },
    };
    var symbol_ids = [_]?u32{ null, null, null, null };
    symbol_ids[@backingInt(outer_binding)] = 0;
    // Adversarial corruption: the inner declaration uses the outer identity.
    symbol_ids[@backingInt(inner_binding)] = 0;
    const references = [_]Reference{
        .{ .node_index = .none, .scope_id = @fromBackingInt(@intCast(0)), .symbol_id = @fromBackingInt(@intCast(0)), .flags = .{ .declare = true } },
        .{ .node_index = .none, .scope_id = @fromBackingInt(@intCast(1)), .symbol_id = @fromBackingInt(@intCast(1)), .flags = .{ .declare = true } },
    };
    var scope_owner_map: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer scope_owner_map.deinit(allocator);
    try scope_owner_map.put(allocator, @backingInt(root), 0);
    try scope_owner_map.put(allocator, @backingInt(inner), 1);
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
        .{ .name = source_name, .scope_id = @fromBackingInt(@intCast(0)), .kind = .variable_let, .declaration_span = source_name, .synthetic_name = "_err3$4" },
        .{ .name = source_name, .scope_id = @fromBackingInt(@intCast(0)), .kind = .variable_let, .declaration_span = source_name, .synthetic_name = "_err3$6" },
    };
    const symbol_ids = [_]?u32{ 0, 1, null };
    const references = [_]Reference{
        .{ .node_index = .none, .scope_id = @fromBackingInt(@intCast(0)), .symbol_id = @fromBackingInt(@intCast(0)), .flags = .{ .declare = true } },
        .{ .node_index = .none, .scope_id = @fromBackingInt(@intCast(0)), .symbol_id = @fromBackingInt(@intCast(1)), .flags = .{ .declare = true } },
    };
    var scope_owner_map: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer scope_owner_map.deinit(allocator);
    try scope_owner_map.put(allocator, @backingInt(root), 0);
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
    const scope: ScopeId = @fromBackingInt(@intCast(0));
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
        .{ .node_index = .none, .scope_id = scope, .symbol_id = @fromBackingInt(@intCast(0)), .flags = .{ .read = true } },
        .{ .node_index = root, .scope_id = scope, .symbol_id = @fromBackingInt(@intCast(0)), .flags = .{ .read = true } },
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
    const scope: ScopeId = @fromBackingInt(@intCast(0));
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
        .{ .node_index = ref, .scope_id = scope, .symbol_id = @fromBackingInt(@intCast(0)), .flags = .{ .read = true } },
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
    const scope: ScopeId = @fromBackingInt(@intCast(0));
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
        .{ .node_index = orphan, .scope_id = scope, .symbol_id = @fromBackingInt(@intCast(0)), .flags = .{ .read = true } },
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
        .{ .parent = @fromBackingInt(@intCast(0)), .kind = .block, .is_strict = false },
        .{ .parent = @fromBackingInt(@intCast(1)), .kind = .block, .is_strict = false },
        .{ .parent = @fromBackingInt(@intCast(1)), .kind = .block, .is_strict = false },
    };
    var root_names: std.StringHashMapUnmanaged(usize) = .empty;
    defer root_names.deinit(allocator);
    try root_names.put(allocator, "x", 0);
    const scope_maps = [_]std.StringHashMapUnmanaged(usize){ .empty, root_names, .empty, .empty };
    const symbols = [_]Symbol{
        .{ .name = name, .scope_id = @fromBackingInt(@intCast(1)), .kind = .variable_let, .declaration_span = name, .reference_count = 1 },
    };
    const symbol_ids = [_]?u32{ 0, 0, null, null, null };
    const references = [_]Reference{
        .{ .node_index = .none, .scope_id = @fromBackingInt(@intCast(1)), .symbol_id = @fromBackingInt(@intCast(0)), .flags = .{ .declare = true } },
        .{ .node_index = shared_ref, .scope_id = @fromBackingInt(@intCast(3)), .symbol_id = @fromBackingInt(@intCast(0)), .flags = .{ .read = true } },
    };
    var scope_owner_map: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer scope_owner_map.deinit(allocator);
    try scope_owner_map.put(allocator, @backingInt(root), 1);
    try scope_owner_map.put(allocator, @backingInt(left), 2);
    try scope_owner_map.put(allocator, @backingInt(right), 3);
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
        .{ .name = name, .scope_id = @fromBackingInt(@intCast(0)), .kind = .variable_let, .declaration_span = name, .reference_count = 2 },
    };
    const symbol_ids = [_]?u32{ 0, 0, 0, null, null, null, null };
    var references = [_]Reference{
        .{ .node_index = .none, .scope_id = @fromBackingInt(@intCast(0)), .symbol_id = @fromBackingInt(@intCast(0)), .flags = .{ .declare = true } },
        .{ .node_index = shared_ref, .scope_id = @fromBackingInt(@intCast(0)), .symbol_id = @fromBackingInt(@intCast(0)), .flags = .{ .read = true } },
        .{ .node_index = unshared_ref, .scope_id = @fromBackingInt(@intCast(0)), .symbol_id = @fromBackingInt(@intCast(0)), .flags = .{ .read = true }, .stmt_idx = 3 },
        .{ .node_index = unshared_ref, .scope_id = @fromBackingInt(@intCast(0)), .symbol_id = @fromBackingInt(@intCast(0)), .flags = .{ .read = true }, .stmt_idx = 99 },
    };
    var scope_owner_map: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer scope_owner_map.deinit(allocator);
    try scope_owner_map.put(allocator, @backingInt(root), 0);
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
        .{ .parent = @fromBackingInt(@intCast(0)), .kind = .block, .is_strict = false },
    };
    var global_names: std.StringHashMapUnmanaged(usize) = .empty;
    defer global_names.deinit(allocator);
    try global_names.put(allocator, "x", 0);
    const scope_maps = [_]std.StringHashMapUnmanaged(usize){ global_names, .empty };
    const symbols = [_]Symbol{
        .{ .name = name, .scope_id = @fromBackingInt(@intCast(0)), .kind = .variable_let, .declaration_span = name, .reference_count = 1 },
    };
    const symbol_ids = [_]?u32{ 0, 0, null, null, null, null, null };
    var references = [_]Reference{
        .{ .node_index = .none, .scope_id = @fromBackingInt(@intCast(0)), .symbol_id = @fromBackingInt(@intCast(0)), .flags = .{ .declare = true }, .stmt_idx = 0, .scope_stmt_idx = 0 },
        .{ .node_index = reference_node, .scope_id = @fromBackingInt(@intCast(1)), .symbol_id = @fromBackingInt(@intCast(0)), .flags = .{ .read = true }, .stmt_idx = 1, .scope_stmt_idx = 1 },
    };
    var scope_owner_map: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer scope_owner_map.deinit(allocator);
    try scope_owner_map.put(allocator, @backingInt(root), 0);
    try scope_owner_map.put(allocator, @backingInt(block), 1);
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

    ast.nodes.items[@backingInt(first_statement)].data.unary.operand = reference_node;
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
        .{ .name = name, .scope_id = @fromBackingInt(@intCast(0)), .kind = .variable_let, .declaration_span = name, .reference_count = 1 },
    };
    const symbol_ids = [_]?u32{ 0, 0, null, null, null };
    const references = [_]Reference{
        .{ .node_index = .none, .scope_id = @fromBackingInt(@intCast(0)), .symbol_id = @fromBackingInt(@intCast(0)), .flags = .{ .declare = true }, .stmt_idx = 0 },
        .{ .node_index = reference_node, .scope_id = @fromBackingInt(@intCast(0)), .symbol_id = @fromBackingInt(@intCast(0)), .flags = .{ .read = true }, .stmt_idx = 1 },
    };
    var scope_owner_map: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer scope_owner_map.deinit(allocator);
    try scope_owner_map.put(allocator, @backingInt(root), 0);
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
        .{ .parent = @fromBackingInt(@intCast(0)), .kind = .block, .is_strict = false },
    };
    var local_names: std.StringHashMapUnmanaged(usize) = .empty;
    defer local_names.deinit(allocator);
    try local_names.put(allocator, "Object", 0);
    const scope_maps = [_]std.StringHashMapUnmanaged(usize){ .empty, local_names };
    const symbols = [_]Symbol{
        .{ .name = name, .scope_id = @fromBackingInt(@intCast(1)), .kind = .variable_let, .declaration_span = name },
    };
    const symbol_ids = [_]?u32{ null, 0, null, null };
    const references = [_]Reference{
        .{ .node_index = .none, .scope_id = @fromBackingInt(@intCast(1)), .symbol_id = @fromBackingInt(@intCast(0)), .flags = .{ .declare = true } },
    };
    var scope_owner_map: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer scope_owner_map.deinit(allocator);
    try scope_owner_map.put(allocator, @backingInt(root), 1);
    var unresolved: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer unresolved.deinit(allocator);
    try unresolved.put(allocator, @backingInt(source_global), {});
    const explicit_globals: std.AutoHashMapUnmanaged(u32, void) = .empty;
    var origins: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer origins.deinit(allocator);
    try origins.put(allocator, @backingInt(copied_global), @backingInt(source_global));

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
    try owners.put(allocator, @backingInt(root), 0);
    var unresolved: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer unresolved.deinit(allocator);
    try unresolved.put(allocator, @backingInt(external_ref), {});
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

test "exact identity audit treats an export-all namespace label as a module name" {
    const Parser = @import("../parser/parser.zig").Parser;
    const SemanticAnalyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var scanner = try Scanner.init(allocator, "export * as ns from './dep';");
    defer scanner.deinit();
    var parser = Parser.init(allocator, &scanner);
    parser.configureFromExtension(".ts");
    defer parser.deinit();
    const root = try parser.parse();
    try std.testing.expectEqual(@as(usize, 0), parser.errors.items.len);

    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    defer analyzer.deinit();
    analyzer.is_module = parser.is_module;
    analyzer.is_ts = true;
    analyzer.collect_unresolved_reference_nodes = true;
    try analyzer.analyze();
    try std.testing.expectEqual(@as(usize, 0), analyzer.errors.items.len);

    const empty_nodes: std.AutoHashMapUnmanaged(u32, void) = .empty;
    const empty_origins: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    const report = try checkExact(
        allocator,
        &parser.ast,
        root,
        @intCast(parser.ast.nodes.items.len),
        analyzer.symbol_ids.items,
        analyzer.symbols.items,
        analyzer.scopes.items,
        analyzer.scope_maps.items,
        &analyzer.scope_owner_map,
        analyzer.references.items,
        &.{},
        &analyzer.helper_scope_map,
        &analyzer.unresolved_reference_nodes,
        &empty_nodes,
        &empty_origins,
    );
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
    const parser_node_count = @backingInt(copied_ref);
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
    try scope_owner_map.put(allocator, @backingInt(root), 0);
    var unresolved: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer unresolved.deinit(allocator);
    try unresolved.put(allocator, @backingInt(source_ref), {});
    const explicit_globals: std.AutoHashMapUnmanaged(u32, void) = .empty;
    var origins: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer origins.deinit(allocator);
    try origins.put(allocator, @backingInt(copied_ref), @backingInt(source_ref));

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
    try std.testing.expectEqual(@backingInt(copied_ref), report.first_unclassified_reference.?.node_index);
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
    const eval_extra = try ast.addExtras(&.{ @backingInt(eval_ref), eval_args.start, eval_args.len, 0 });
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
    try scope_owner_map.put(allocator, @backingInt(root), 0);
    var unresolved: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer unresolved.deinit(allocator);
    try unresolved.put(allocator, @backingInt(source_ref), {});
    try unresolved.put(allocator, @backingInt(eval_ref), {});
    const explicit_globals: std.AutoHashMapUnmanaged(u32, void) = .empty;
    var origins: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer origins.deinit(allocator);
    try origins.put(allocator, @backingInt(copied_ref), @backingInt(source_ref));

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
    try unresolved.put(allocator, @backingInt(external_ref), {});
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
        .{ .parent = @fromBackingInt(@intCast(0)), .kind = .function, .is_strict = false },
    };
    const scope_maps = [_]std.StringHashMapUnmanaged(usize){ .empty, nested_names };
    const symbols = [_]Symbol{
        .{ .name = name, .scope_id = @fromBackingInt(@intCast(1)), .kind = .variable_let, .declaration_span = name },
    };
    const symbol_ids = [_]?u32{null};
    const scope_owner_map: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    var unresolved: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer unresolved.deinit(allocator);
    try unresolved.put(allocator, @backingInt(external_ref), {});
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
        .{ .parent = @fromBackingInt(@intCast(0)), .kind = .block, .is_strict = false },
        .{ .parent = @fromBackingInt(@intCast(1)), .kind = .block, .is_strict = false },
    };
    var outer_names: std.StringHashMapUnmanaged(usize) = .empty;
    defer outer_names.deinit(allocator);
    try outer_names.put(allocator, "x", 0);
    const scope_maps = [_]std.StringHashMapUnmanaged(usize){ .empty, outer_names, .empty };
    const symbols = [_]Symbol{
        .{ .name = name, .scope_id = @fromBackingInt(@intCast(1)), .kind = .variable_let, .declaration_span = name, .reference_count = 1 },
    };
    const symbol_ids = [_]?u32{ 0, null, null };
    // x는 outer_scope에서 보이고 여기서 이름 조회도 성공하지만, 실제
    // 참조 노드는 inner block 안에 있으므로 ScopeId는 2여야 한다.
    const references = [_]Reference{
        .{ .node_index = ref_node, .scope_id = @fromBackingInt(@intCast(1)), .symbol_id = @fromBackingInt(@intCast(0)), .flags = .{ .read = true } },
    };
    var scope_owner_map: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer scope_owner_map.deinit(allocator);
    try scope_owner_map.put(allocator, @backingInt(root), 1);
    try scope_owner_map.put(allocator, @backingInt(inner), 2);
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

test "exact identity audit preserves a relocated source binding after its source scope owner is lowered away" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ast = Ast.init(allocator, "");
    defer ast.deinit();
    const name = try ast.addString("x");
    const binding = try makeTestIdentifierNode(&ast, .binding_identifier, name);
    const ref_node = try makeTestIdentifierNode(&ast, .identifier_reference, name);
    const none = @backingInt(NodeIndex.none);
    const declarator_extra = try ast.addExtras(&.{ @backingInt(binding), none, none });
    const declarator = try ast.addNode(.{ .tag = .variable_declarator, .span = name, .data = .{ .extra = declarator_extra } });
    const declarators = try ast.addNodeList(&.{declarator});
    const declaration_extra = try ast.addExtras(&.{
        @backingInt(ast_mod.VariableDeclarationKind.@"var"),
        declarators.start,
        declarators.len,
    });
    const declaration = try ast.addNode(.{ .tag = .variable_declaration, .span = name, .data = .{ .extra = declaration_extra } });
    const root = try ast.addListNode(.block_statement, name, try ast.addNodeList(&.{ declaration, ref_node }));
    const scopes = [_]Scope{
        .{ .parent = .none, .kind = .global, .is_strict = false },
        .{ .parent = @fromBackingInt(@intCast(0)), .kind = .block, .is_strict = false },
        .{ .parent = @fromBackingInt(@intCast(0)), .kind = .block, .is_strict = false },
    };
    var output_names: std.StringHashMapUnmanaged(usize) = .empty;
    defer output_names.deinit(allocator);
    try output_names.put(allocator, "x", 0);
    const scope_maps = [_]std.StringHashMapUnmanaged(usize){ output_names, .empty, .empty };
    const symbols = [_]Symbol{
        .{ .name = name, .scope_id = @fromBackingInt(@intCast(0)), .origin_scope = @fromBackingInt(@intCast(1)), .kind = .variable_let, .declaration_span = name, .reference_count = 1 },
    };
    var symbol_ids = try allocator.alloc(?u32, ast.nodes.items.len);
    @memset(symbol_ids, null);
    symbol_ids[@backingInt(binding)] = 0;
    symbol_ids[@backingInt(ref_node)] = 0;
    const references = [_]Reference{
        .{ .node_index = .none, .declaration_node_index = binding, .scope_id = @fromBackingInt(@intCast(0)), .symbol_id = @fromBackingInt(@intCast(0)), .flags = .{ .declare = true } },
        .{ .node_index = ref_node, .scope_id = @fromBackingInt(@intCast(1)), .symbol_id = @fromBackingInt(@intCast(0)), .flags = .{ .read = true } },
    };
    var scope_owner_map: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer scope_owner_map.deinit(allocator);
    try scope_owner_map.put(allocator, @backingInt(root), 2);
    const unresolved: std.AutoHashMapUnmanaged(u32, void) = .empty;
    const explicit_globals: std.AutoHashMapUnmanaged(u32, void) = .empty;
    const origins: std.AutoHashMapUnmanaged(u32, u32) = .empty;

    const report = try checkExact(
        allocator,
        &ast,
        root,
        @intCast(ast.nodes.items.len),
        symbol_ids,
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
    try std.testing.expect(report.isClean());
}

test "exact identity audit rejects retained source scope when output binding shadows it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ast = Ast.init(allocator, "");
    defer ast.deinit();
    const name = try ast.addString("x");
    const relocated_binding = try makeTestIdentifierNode(&ast, .binding_identifier, name);
    const shadow_binding = try makeTestIdentifierNode(&ast, .binding_identifier, name);
    const reference = try makeTestIdentifierNode(&ast, .identifier_reference, name);
    const none = @backingInt(NodeIndex.none);

    const relocated_declarator_extra = try ast.addExtras(&.{ @backingInt(relocated_binding), none, none });
    const relocated_declarator = try ast.addNode(.{
        .tag = .variable_declarator,
        .span = name,
        .data = .{ .extra = relocated_declarator_extra },
    });
    const relocated_declarators = try ast.addNodeList(&.{relocated_declarator});
    const relocated_declaration_extra = try ast.addExtras(&.{
        @backingInt(ast_mod.VariableDeclarationKind.@"var"),
        relocated_declarators.start,
        relocated_declarators.len,
    });
    const relocated_declaration = try ast.addNode(.{
        .tag = .variable_declaration,
        .span = name,
        .data = .{ .extra = relocated_declaration_extra },
    });

    const shadow_declarator_extra = try ast.addExtras(&.{ @backingInt(shadow_binding), none, none });
    const shadow_declarator = try ast.addNode(.{
        .tag = .variable_declarator,
        .span = name,
        .data = .{ .extra = shadow_declarator_extra },
    });
    const shadow_declarators = try ast.addNodeList(&.{shadow_declarator});
    const shadow_declaration_extra = try ast.addExtras(&.{
        @backingInt(ast_mod.VariableDeclarationKind.let),
        shadow_declarators.start,
        shadow_declarators.len,
    });
    const shadow_declaration = try ast.addNode(.{
        .tag = .variable_declaration,
        .span = name,
        .data = .{ .extra = shadow_declaration_extra },
    });
    const inner = try ast.addListNode(.block_statement, name, try ast.addNodeList(&.{ shadow_declaration, reference }));
    const root = try ast.addListNode(.block_statement, name, try ast.addNodeList(&.{ relocated_declaration, inner }));

    const scopes = [_]Scope{
        .{ .parent = .none, .kind = .global, .is_strict = false },
        .{ .parent = @fromBackingInt(@intCast(0)), .kind = .block, .is_strict = false },
        .{ .parent = @fromBackingInt(@intCast(0)), .kind = .block, .is_strict = false },
        .{ .parent = @fromBackingInt(@intCast(2)), .kind = .block, .is_strict = false },
    };
    var output_names: std.StringHashMapUnmanaged(usize) = .empty;
    defer output_names.deinit(allocator);
    try output_names.put(allocator, "x", 0);
    var shadow_names: std.StringHashMapUnmanaged(usize) = .empty;
    defer shadow_names.deinit(allocator);
    try shadow_names.put(allocator, "x", 1);
    const scope_maps = [_]std.StringHashMapUnmanaged(usize){ output_names, .empty, .empty, shadow_names };
    const symbols = [_]Symbol{
        .{ .name = name, .scope_id = @fromBackingInt(@intCast(0)), .origin_scope = @fromBackingInt(@intCast(1)), .kind = .variable_let, .declaration_span = name, .reference_count = 1 },
        .{ .name = name, .scope_id = @fromBackingInt(@intCast(3)), .kind = .variable_let, .declaration_span = name },
    };
    var symbol_ids = try allocator.alloc(?u32, ast.nodes.items.len);
    @memset(symbol_ids, null);
    symbol_ids[@backingInt(relocated_binding)] = 0;
    symbol_ids[@backingInt(shadow_binding)] = 1;
    symbol_ids[@backingInt(reference)] = 0;
    const references = [_]Reference{
        .{ .node_index = .none, .declaration_node_index = relocated_binding, .scope_id = @fromBackingInt(@intCast(0)), .symbol_id = @fromBackingInt(@intCast(0)), .flags = .{ .declare = true } },
        .{ .node_index = .none, .declaration_node_index = shadow_binding, .scope_id = @fromBackingInt(@intCast(3)), .symbol_id = @fromBackingInt(@intCast(1)), .flags = .{ .declare = true } },
        .{ .node_index = reference, .scope_id = @fromBackingInt(@intCast(1)), .symbol_id = @fromBackingInt(@intCast(0)), .flags = .{ .read = true } },
    };
    var scope_owner_map: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer scope_owner_map.deinit(allocator);
    try scope_owner_map.put(allocator, @backingInt(root), 2);
    try scope_owner_map.put(allocator, @backingInt(inner), 3);
    const unresolved: std.AutoHashMapUnmanaged(u32, void) = .empty;
    const explicit_globals: std.AutoHashMapUnmanaged(u32, void) = .empty;
    const origins: std.AutoHashMapUnmanaged(u32, u32) = .empty;

    const report = try checkExact(
        allocator,
        &ast,
        root,
        @intCast(ast.nodes.items.len),
        symbol_ids,
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
    try std.testing.expect(!report.isClean());
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
    const none = @backingInt(NodeIndex.none);
    const declarator_extra = try ast.addExtras(&.{ @backingInt(binding), none, none });
    const declarator = try ast.addNode(.{ .tag = .variable_declarator, .span = name, .data = .{ .extra = declarator_extra } });
    const declarators = try ast.addNodeList(&.{declarator});
    const declaration_extra = try ast.addExtras(&.{
        @backingInt(ast_mod.VariableDeclarationKind.@"var"),
        declarators.start,
        declarators.len,
    });
    const declaration = try ast.addNode(.{ .tag = .variable_declaration, .span = name, .data = .{ .extra = declaration_extra } });
    const body = try ast.addNode(.{ .tag = .block_statement, .span = name, .data = .{ .list = try ast.addNodeList(&.{ declaration, ref }) } });
    const dead_catch = try ast.addNode(.{ .tag = .catch_clause, .span = name, .data = .{ .binary = .{ .left = .none, .right = .none, .flags = 0 } } });
    const scopes = [_]Scope{
        .{ .parent = .none, .kind = .global, .is_strict = false },
        .{ .parent = @fromBackingInt(@intCast(0)), .kind = .catch_clause, .is_strict = false },
        .{ .parent = @fromBackingInt(@intCast(1)), .kind = .block, .is_strict = false },
    };
    var catch_names: std.StringHashMapUnmanaged(usize) = .empty;
    defer catch_names.deinit(allocator);
    try catch_names.put(allocator, "_caught", 0);
    const scope_maps = [_]std.StringHashMapUnmanaged(usize){ .empty, catch_names, .empty };
    const symbols = [_]Symbol{
        .{ .name = name, .scope_id = @fromBackingInt(@intCast(1)), .kind = .catch_binding, .declaration_span = name, .reference_count = 1, .synthetic_name = "_caught" },
    };
    const symbol_ids = [_]?u32{ 0, 0, null, null, null };
    const references = [_]Reference{
        .{ .node_index = .none, .declaration_node_index = binding, .scope_id = @fromBackingInt(@intCast(1)), .symbol_id = @fromBackingInt(@intCast(0)), .flags = .{ .declare = true } },
        .{ .node_index = ref, .scope_id = @fromBackingInt(@intCast(1)), .symbol_id = @fromBackingInt(@intCast(0)), .flags = .{ .read = true } },
    };
    var scope_owner_map: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer scope_owner_map.deinit(allocator);
    try scope_owner_map.put(allocator, @backingInt(body), 2);
    try scope_owner_map.put(allocator, @backingInt(dead_catch), 1);
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
        .{ .parent = @fromBackingInt(@intCast(0)), .kind = .catch_clause, .is_strict = false },
        .{ .parent = @fromBackingInt(@intCast(1)), .kind = .block, .is_strict = false },
    };
    var catch_names: std.StringHashMapUnmanaged(usize) = .empty;
    defer catch_names.deinit(allocator);
    try catch_names.put(allocator, "_caught", 0);
    const scope_maps = [_]std.StringHashMapUnmanaged(usize){ .empty, catch_names, .empty };
    const symbols = [_]Symbol{
        .{ .name = name, .scope_id = @fromBackingInt(@intCast(1)), .kind = .catch_binding, .declaration_span = name, .reference_count = 1, .synthetic_name = "_caught" },
    };
    const symbol_ids = [_]?u32{ 0, 0, null, null };
    const references = [_]Reference{
        .{ .node_index = .none, .scope_id = @fromBackingInt(@intCast(1)), .symbol_id = @fromBackingInt(@intCast(0)), .flags = .{ .declare = true } },
        .{ .node_index = ref, .scope_id = @fromBackingInt(@intCast(1)), .symbol_id = @fromBackingInt(@intCast(0)), .flags = .{ .read = true } },
    };
    var scope_owner_map: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer scope_owner_map.deinit(allocator);
    try scope_owner_map.put(allocator, @backingInt(catch_clause), 1);
    try scope_owner_map.put(allocator, @backingInt(body), 2);
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
    const switch_extra = try ast.addExtras(&.{ @backingInt(discriminant), no_cases.start, no_cases.len });
    const switch_node = try ast.addNode(.{
        .tag = .switch_statement,
        .span = span,
        .data = .{ .extra = switch_extra },
    });
    const class_extra = try ast.addExtras(&.{
        @backingInt(NodeIndex.none),
        @backingInt(NodeIndex.none),
        @backingInt(NodeIndex.none),
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
        .{ .parent = @fromBackingInt(@intCast(0)), .kind = .block, .is_strict = false },
    };
    const scope_maps = [_]std.StringHashMapUnmanaged(usize){ .empty, .empty };
    var scope_owner_map: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer scope_owner_map.deinit(allocator);
    try scope_owner_map.put(allocator, @backingInt(root), 1);
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
        .{ .parent = @fromBackingInt(@intCast(0)), .kind = .block, .is_strict = false },
    };
    var generated_scope_map: std.StringHashMapUnmanaged(usize) = .empty;
    try generated_scope_map.put(allocator, ast.getText(generated_name), 0);
    const scope_maps = [_]std.StringHashMapUnmanaged(usize){ .empty, generated_scope_map };
    const symbols = [_]Symbol{
        .{ .name = generated_name, .scope_id = @fromBackingInt(@intCast(1)), .kind = .variable_let, .declaration_span = generated_name },
    };
    var scope_owner_map: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer scope_owner_map.deinit(allocator);
    try scope_owner_map.put(allocator, @backingInt(root), 0);
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
    try scope_owner_map.put(allocator, @backingInt(stale_owner), 1);
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
    try scope_owner_map.put(allocator, @backingInt(statement), 1);
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

test "exact identity audit rejects ownerless generated scopes that require lexical bindings" {
    const Case = struct {
        source: []const u8,
        owner_tag: Node.Tag,
        binding_name: []const u8,
    };
    const cases = [_]Case{
        .{ .source = "{ let value = 1; }", .owner_tag = .block_statement, .binding_name = "value" },
        .{ .source = "{ const value = 1; }", .owner_tag = .block_statement, .binding_name = "value" },
        .{ .source = "{ function value() {} }", .owner_tag = .block_statement, .binding_name = "value" },
        .{ .source = "{ class value {} }", .owner_tag = .block_statement, .binding_name = "value" },
        .{ .source = "{ a: b: c: d: e: f: g: h: i: j: function value() {} }", .owner_tag = .block_statement, .binding_name = "value" },
        .{ .source = "for (let value = 0;;) {}", .owner_tag = .for_statement, .binding_name = "value" },
        .{ .source = "for (let value of []) {}", .owner_tag = .for_of_statement, .binding_name = "value" },
        .{ .source = "for (const value in {}) {}", .owner_tag = .for_in_statement, .binding_name = "value" },
    };
    for (cases) |case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        var scanner = try Scanner.init(allocator, case.source);
        var parser = @import("../parser/parser.zig").Parser.init(allocator, &scanner);
        parser.configureFromExtension(".js");
        const root = try parser.parse();
        const Analyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer;
        var sem = Analyzer.init(allocator, &parser.ast);
        try sem.analyze();
        try std.testing.expectEqual(@as(usize, 0), sem.errors.items.len);

        var owner_node: ?u32 = null;
        var owner_scope: ?u32 = null;
        var owners = sem.scope_owner_map.iterator();
        while (owners.next()) |entry| {
            if (entry.key_ptr.* >= parser.ast.nodes.items.len or entry.value_ptr.* >= sem.scope_maps.items.len) continue;
            if (parser.ast.nodes.items[entry.key_ptr.*].tag != case.owner_tag) continue;
            if (sem.scope_maps.items[entry.value_ptr.*].get(case.binding_name) == null) continue;
            owner_node = entry.key_ptr.*;
            owner_scope = entry.value_ptr.*;
            break;
        }
        const owner = owner_node orelse return error.MissingLexicalScopeOwner;
        const scope = owner_scope orelse return error.MissingLexicalScope;
        const parent_scope = sem.scopes.items[scope].parent.toIndex();
        const owner_map = &sem.scope_maps.items[scope];
        const binding_symbol = owner_map.get(case.binding_name) orelse return error.MissingLexicalSymbol;

        // Simulate a graph corruption where the AST retains a lexical owner
        // but the binding and any reads are incorrectly attached to its parent.
        _ = owner_map.remove(case.binding_name);
        try sem.scope_maps.items[parent_scope].put(allocator, case.binding_name, binding_symbol);
        sem.symbols.items[binding_symbol].scope_id = @fromBackingInt(parent_scope);
        sem.symbols.items[binding_symbol].origin_scope = @fromBackingInt(parent_scope);
        for (sem.references.items) |*reference| {
            if (@backingInt(reference.symbol_id) == binding_symbol) {
                reference.scope_id = @fromBackingInt(parent_scope);
            }
        }
        _ = sem.scope_owner_map.remove(owner);

        const empty_nodes: std.AutoHashMapUnmanaged(u32, void) = .empty;
        const empty_origins: std.AutoHashMapUnmanaged(u32, u32) = .empty;
        const report = try checkExactWithScopeBoundary(
            allocator,
            &parser.ast,
            root,
            0,
            sem.symbol_ids.items,
            sem.symbols.items,
            sem.scopes.items,
            sem.scope_maps.items,
            &sem.scope_owner_map,
            sem.references.items,
            &.{},
            &.{},
            &empty_nodes,
            &empty_nodes,
            &empty_origins,
            sem.scopes.items.len,
        );
        try std.testing.expectEqual(@as(usize, 1), report.scope_owner_mismatch);
        try std.testing.expectEqualStrings(
            "missing-owner-for-lexical-declaration",
            report.first_scope_owner_mismatch.?.issue,
        );
        try std.testing.expect(!report.isClean());
    }
}

test "exact identity audit permits ownerless generated wrappers without lexical bindings" {
    const cases = [_]struct { source: []const u8, owner_tag: Node.Tag }{
        .{ .source = "{ var value = 1; }", .owner_tag = .block_statement },
        .{ .source = "{}", .owner_tag = .block_statement },
        .{ .source = "for (;;) {}", .owner_tag = .for_statement },
    };
    for (cases) |case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        var scanner = try Scanner.init(allocator, case.source);
        var parser = @import("../parser/parser.zig").Parser.init(allocator, &scanner);
        parser.configureFromExtension(".js");
        const root = try parser.parse();
        const Analyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer;
        var sem = Analyzer.init(allocator, &parser.ast);
        try sem.analyze();
        try std.testing.expectEqual(@as(usize, 0), sem.errors.items.len);

        var owner: ?u32 = null;
        var owners = sem.scope_owner_map.iterator();
        while (owners.next()) |entry| {
            if (entry.key_ptr.* < parser.ast.nodes.items.len and
                parser.ast.nodes.items[entry.key_ptr.*].tag == case.owner_tag)
            {
                owner = entry.key_ptr.*;
                break;
            }
        }
        _ = sem.scope_owner_map.remove(owner orelse return error.MissingStructuralOwner);

        const empty_nodes: std.AutoHashMapUnmanaged(u32, void) = .empty;
        const empty_origins: std.AutoHashMapUnmanaged(u32, u32) = .empty;
        const report = try checkExactWithScopeBoundary(
            allocator,
            &parser.ast,
            root,
            0,
            sem.symbol_ids.items,
            sem.symbols.items,
            sem.scopes.items,
            sem.scope_maps.items,
            &sem.scope_owner_map,
            sem.references.items,
            &.{},
            &.{},
            &empty_nodes,
            &empty_nodes,
            &empty_origins,
            sem.scopes.items.len,
        );
        try std.testing.expectEqual(@as(usize, 0), report.scope_owner_mismatch);
        try std.testing.expect(report.isClean());
    }
}

test "generated lexical-scope detection fails closed on malformed declaration wrappers" {
    var ast = Ast.init(std.testing.allocator, "");
    defer ast.deinit();

    const malformed_wrapper = try ast.addNode(.{
        .tag = .flow_component_wrapper,
        .span = .EMPTY,
        .data = .{ .extra = std.math.maxInt(u32) },
    });
    try std.testing.expect(statementRequiresLexicalScopeOwner(&ast, @backingInt(malformed_wrapper)));

    const malformed_block = try ast.addNode(.{
        .tag = .block_statement,
        .span = .EMPTY,
        .data = .{ .list = .{ .start = std.math.maxInt(u32), .len = 1 } },
    });
    try std.testing.expect(generatedOwnerlessScopeRequiresOwner(&ast, @backingInt(malformed_block), .block_statement));
}

test "exact identity audit rejects over-strict lexical scopes at ten nesting depths" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const nested_block_counts = [_]usize{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 };
    for (nested_block_counts) |block_count| {
        var ast = Ast.init(allocator, "");
        const empty_statement = try ast.addNode(.{
            .tag = .empty_statement,
            .span = .EMPTY,
            .data = .{ .none = 0 },
        });
        const block_nodes = try allocator.alloc(NodeIndex, block_count);
        var child = empty_statement;
        var block_index = block_count;
        while (block_index > 0) {
            block_index -= 1;
            const list = try ast.addNodeList(&.{child});
            block_nodes[block_index] = try ast.addNode(.{
                .tag = .block_statement,
                .span = .EMPTY,
                .data = .{ .list = list },
            });
            child = block_nodes[block_index];
        }
        const root_list = try ast.addNodeList(&.{child});
        const root = try ast.addNode(.{
            .tag = .program,
            .span = .EMPTY,
            .data = .{ .list = root_list },
        });

        const scopes = try allocator.alloc(Scope, block_count + 1);
        scopes[0] = .{ .parent = .none, .kind = .global, .is_strict = false };
        for (block_nodes, 0..) |_, index| {
            scopes[index + 1] = .{
                .parent = @fromBackingInt(@intCast(index)),
                .kind = .block,
                .is_strict = false,
            };
        }
        const scope_maps = try allocator.alloc(std.StringHashMapUnmanaged(usize), scopes.len);
        for (scope_maps) |*scope_map| scope_map.* = .empty;
        const symbol_ids = try allocator.alloc(?u32, ast.nodes.items.len);
        @memset(symbol_ids, null);
        var scope_owner_map: std.AutoHashMapUnmanaged(u32, u32) = .empty;
        try scope_owner_map.put(allocator, @backingInt(root), 0);
        for (block_nodes, 0..) |block, index| {
            try scope_owner_map.put(allocator, @backingInt(block), @intCast(index + 1));
        }
        const unresolved: std.AutoHashMapUnmanaged(u32, void) = .empty;
        const explicit_globals: std.AutoHashMapUnmanaged(u32, void) = .empty;
        const origins: std.AutoHashMapUnmanaged(u32, u32) = .empty;

        const correct = try checkExactWithScopeBoundary(
            allocator,
            &ast,
            root,
            @intCast(ast.nodes.items.len),
            symbol_ids,
            &.{},
            scopes,
            scope_maps,
            &scope_owner_map,
            &.{},
            &.{},
            &.{},
            &unresolved,
            &explicit_globals,
            &origins,
            scopes.len - 1,
        );
        try std.testing.expectEqual(@as(usize, 0), correct.scope_strictness_mismatch);

        scopes[block_count].is_strict = true;
        const hostile = try checkExactWithScopeBoundary(
            allocator,
            &ast,
            root,
            @intCast(ast.nodes.items.len),
            symbol_ids,
            &.{},
            scopes,
            scope_maps,
            &scope_owner_map,
            &.{},
            &.{},
            &.{},
            &unresolved,
            &explicit_globals,
            &origins,
            scopes.len - 1,
        );
        try std.testing.expectEqual(@as(usize, 1), hostile.scope_strictness_mismatch);
        const finding = hostile.first_scope_strictness_mismatch.?;
        try std.testing.expectEqual(@as(u32, @intCast(block_count)), finding.scope_id);
        try std.testing.expectEqual(@as(?u32, @intCast(block_count - 1)), finding.parent_scope_id);
        try std.testing.expectEqualStrings(
            "lexical-scope-must-match-parent-strictness",
            finding.issue,
        );
    }

    for ([_]ScopeKind{ .switch_block, .catch_clause }) |kind| {
        var ast = Ast.init(allocator, "");
        const root_list = try ast.addNodeList(&.{});
        const root = try ast.addNode(.{
            .tag = .program,
            .span = .EMPTY,
            .data = .{ .list = root_list },
        });
        const scopes = [_]Scope{
            .{ .parent = .none, .kind = .global, .is_strict = false },
            .{ .parent = @fromBackingInt(@intCast(0)), .kind = kind, .is_strict = false },
        };
        const scope_maps = [_]std.StringHashMapUnmanaged(usize){ .empty, .empty };
        var scope_owner_map: std.AutoHashMapUnmanaged(u32, u32) = .empty;
        try scope_owner_map.put(allocator, @backingInt(root), 0);
        const unresolved: std.AutoHashMapUnmanaged(u32, void) = .empty;
        const explicit_globals: std.AutoHashMapUnmanaged(u32, void) = .empty;
        const origins: std.AutoHashMapUnmanaged(u32, u32) = .empty;
        var hostile_scopes = scopes;
        hostile_scopes[1].is_strict = true;
        const hostile = try checkExactWithScopeBoundary(
            allocator,
            &ast,
            root,
            @intCast(ast.nodes.items.len),
            &.{},
            &.{},
            &hostile_scopes,
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
        try std.testing.expectEqual(@as(usize, 1), hostile.scope_strictness_mismatch);
        const finding = hostile.first_scope_strictness_mismatch.?;
        try std.testing.expectEqual(@as(u32, 1), finding.scope_id);
        try std.testing.expectEqual(@as(?u32, 0), finding.parent_scope_id);
        try std.testing.expectEqualStrings(
            "lexical-scope-must-match-parent-strictness",
            finding.issue,
        );
    }
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
        .{ .parent = @fromBackingInt(@intCast(0)), .kind = .block, .is_strict = false },
    };
    const scope_maps = [_]std.StringHashMapUnmanaged(usize){ .{}, .{} };
    var scope_owner_map: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer scope_owner_map.deinit(allocator);
    try scope_owner_map.put(allocator, @backingInt(root), 1);
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
    try unresolved.put(allocator, @backingInt(source_global), {});
    var explicit_globals: std.AutoHashMapUnmanaged(u32, void) = .empty;
    try explicit_globals.put(allocator, @backingInt(explicit_global), {});
    var origins: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    try origins.put(allocator, @backingInt(copied_global), @backingInt(source_global));
    try origins.put(allocator, @backingInt(different_global), @backingInt(source_global));
    var scope_owner_map: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer scope_owner_map.deinit(allocator);
    try scope_owner_map.put(allocator, @backingInt(root), 0);
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

test "post-minify audit rejects IDs outside their symbol tables" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var ast = Ast.init(allocator, "");
    defer ast.deinit();

    const name = try ast.addString("value");
    const binding = try makeTestIdentifierNode(&ast, .binding_identifier, name);
    const reference = try makeTestIdentifierNode(&ast, .identifier_reference, name);
    const root = try ast.addNode(.{
        .tag = .block_statement,
        .span = name,
        .data = .{ .list = try ast.addNodeList(&.{ binding, reference }) },
    });
    const actual = [_]?u32{ 7, 7, null };
    const resolved = [_]?u32{ 2, 2, null };
    const helper_scope_map: std.StringHashMapUnmanaged(usize) = .empty;
    const empty_markers: std.AutoHashMapUnmanaged(u32, void) = .empty;
    const empty_class_symbols: std.AutoHashMapUnmanaged(u32, u32) = .empty;

    const report = try checkPostMinify(
        allocator,
        &ast,
        root,
        &actual,
        &resolved,
        &.{},
        &.{},
        &.{},
        &.{},
        &helper_scope_map,
        &empty_markers,
        &empty_markers,
        &empty_class_symbols,
        &empty_class_symbols,
    );
    try std.testing.expectEqual(@as(usize, 1), report.invalid_binding_id);
    try std.testing.expectEqual(@as(usize, 1), report.invalid_reference_id);
    try std.testing.expect(!report.isClean());
}

test "post-minify audit rejects out-of-range class-self and helper IDs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var ast = Ast.init(allocator, "");
    defer ast.deinit();

    const name = try ast.addString("value");
    const reference = try makeTestIdentifierNode(&ast, .identifier_reference, name);
    const body = try ast.addNode(.{
        .tag = .class_body,
        .span = name,
        .data = .{ .list = try ast.addNodeList(&.{}) },
    });
    const class_extra = try ast.addExtras(&.{
        @backingInt(NodeIndex.none),
        @backingInt(NodeIndex.none),
        @backingInt(body),
        @backingInt(NodeIndex.none),
        0,
        0,
        0,
        0,
    });
    const class = try ast.addNode(.{
        .tag = .class_expression,
        .span = name,
        .data = .{ .extra = class_extra },
    });
    const root = try ast.addNode(.{
        .tag = .block_statement,
        .span = name,
        .data = .{ .list = try ast.addNodeList(&.{ reference, class }) },
    });

    const actual = [_]?u32{ null, null, null, null };
    const resolved = actual;
    var helper_scope_map: std.StringHashMapUnmanaged(usize) = .empty;
    defer helper_scope_map.deinit(allocator);
    try helper_scope_map.put(allocator, "value", 7);
    var actual_class_self: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer actual_class_self.deinit(allocator);
    try actual_class_self.put(allocator, @backingInt(class), 7);
    var resolved_class_self: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer resolved_class_self.deinit(allocator);
    try resolved_class_self.put(allocator, @backingInt(class), 2);
    const empty_markers: std.AutoHashMapUnmanaged(u32, void) = .empty;

    const report = try checkPostMinify(
        allocator,
        &ast,
        root,
        &actual,
        &resolved,
        &.{},
        &.{},
        &.{},
        &.{},
        &helper_scope_map,
        &empty_markers,
        &empty_markers,
        &actual_class_self,
        &resolved_class_self,
    );
    try std.testing.expectEqual(@as(usize, 1), report.invalid_binding_id);
    try std.testing.expectEqual(@as(usize, 1), report.invalid_reference_id);
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
    actual[@backingInt(binding)] = 7;
    actual[@backingInt(reference)] = 7;
    resolved[@backingInt(binding)] = 2;
    resolved[@backingInt(reference)] = 2;

    const actual_symbols = makePostMinifyTestSymbolTable(8, try ast.addString("__actual_filler"));
    const resolved_symbols = makePostMinifyTestSymbolTable(3, try ast.addString("__resolved_filler"));
    const empty_helper_scope_map: std.StringHashMapUnmanaged(usize) = .empty;
    const empty_markers: std.AutoHashMapUnmanaged(u32, void) = .empty;
    const empty_class_symbols: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    const report = try checkPostMinify(allocator, &ast, root, &actual, &resolved, &actual_symbols, &resolved_symbols, &.{}, &.{}, &empty_helper_scope_map, &empty_markers, &empty_markers, &empty_class_symbols, &empty_class_symbols);
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

    const actual_symbols = makePostMinifyTestSymbolTable(8, try ast.addString("__actual_filler"));
    const resolved_symbols = makePostMinifyTestSymbolTable(4, try ast.addString("__resolved_filler"));
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
        &actual_symbols,
        &resolved_symbols,
        &.{},
        &.{},
        &empty_helper_scope_map,
        &empty_markers,
        &empty_markers,
        &empty_class_symbols,
        &empty_class_symbols,
    );
    try std.testing.expect(report.isClean());
    try std.testing.expectEqual(@as(usize, 1), report.references_checked);

    actual[@backingInt(value)] = null;
    report = try checkPostMinify(
        allocator,
        &ast,
        root,
        &actual,
        &resolved,
        &actual_symbols,
        &resolved_symbols,
        &.{},
        &.{},
        &empty_helper_scope_map,
        &empty_markers,
        &empty_markers,
        &empty_class_symbols,
        &empty_class_symbols,
    );
    try std.testing.expectEqual(@as(usize, 1), report.missing_reference_id);
    try std.testing.expect(!report.isClean());

    // A bad value identity must still fail; skipping the static key must not
    // make the real property-value reference invisible to the gate.
    actual[@backingInt(value)] = 7;
    resolved[@backingInt(value)] = 3;
    report = try checkPostMinify(
        allocator,
        &ast,
        root,
        &actual,
        &resolved,
        &actual_symbols,
        &resolved_symbols,
        &.{},
        &.{},
        &empty_helper_scope_map,
        &empty_markers,
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
    actual[@backingInt(binding)] = 7;
    actual[@backingInt(reference)] = 9;
    resolved[@backingInt(binding)] = 2;
    resolved[@backingInt(reference)] = 2;

    const actual_symbols = makePostMinifyTestSymbolTable(10, try ast.addString("__actual_filler"));
    const resolved_symbols = makePostMinifyTestSymbolTable(3, try ast.addString("__resolved_filler"));
    const empty_helper_scope_map: std.StringHashMapUnmanaged(usize) = .empty;
    const empty_markers: std.AutoHashMapUnmanaged(u32, void) = .empty;
    const empty_class_symbols: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    const report = try checkPostMinify(allocator, &ast, root, &actual, &resolved, &actual_symbols, &resolved_symbols, &.{}, &.{}, &empty_helper_scope_map, &empty_markers, &empty_markers, &empty_class_symbols, &empty_class_symbols);
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
    actual[@backingInt(outer)] = 3;
    actual[@backingInt(inner)] = 4;
    actual[@backingInt(reference)] = 3;
    resolved[@backingInt(outer)] = 10;
    resolved[@backingInt(inner)] = 11;
    resolved[@backingInt(reference)] = 11;

    const actual_symbols = makePostMinifyTestSymbolTable(5, try ast.addString("__actual_filler"));
    const resolved_symbols = makePostMinifyTestSymbolTable(12, try ast.addString("__resolved_filler"));
    const empty_helper_scope_map: std.StringHashMapUnmanaged(usize) = .empty;
    const empty_markers: std.AutoHashMapUnmanaged(u32, void) = .empty;
    const empty_class_symbols: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    const report = try checkPostMinify(allocator, &ast, root, &actual, &resolved, &actual_symbols, &resolved_symbols, &.{}, &.{}, &empty_helper_scope_map, &empty_markers, &empty_markers, &empty_class_symbols, &empty_class_symbols);
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
        .{ .name = name, .scope_id = @fromBackingInt(@intCast(0)), .kind = .import_binding, .declaration_span = name },
        .{ .name = name, .scope_id = @fromBackingInt(@intCast(0)), .kind = .variable_let, .declaration_span = name },
    };
    var helper_scope_map: std.StringHashMapUnmanaged(usize) = .empty;
    defer helper_scope_map.deinit(allocator);
    try helper_scope_map.put(allocator, "helper", 0);
    const helper_nodes = [_]u32{@backingInt(helper_reference)};
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
        &empty_markers,
        &empty_class_symbols,
        &empty_class_symbols,
    );
    try std.testing.expectEqual(@as(usize, 1), inferred_helper_report.wrong_reference_target);
    try std.testing.expect(!inferred_helper_report.isClean());
}

test "post-minify audit requires exact class self mapping before fallback" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var ast = Ast.init(allocator, "");
    defer ast.deinit();

    const name = try ast.addString("C");
    const outer_binding = try makeTestIdentifierNode(&ast, .binding_identifier, name);
    const self_reference = try makeTestIdentifierNode(&ast, .identifier_reference, name);
    const body = try ast.addNode(.{
        .tag = .class_body,
        .span = name,
        .data = .{ .list = try ast.addNodeList(&.{self_reference}) },
    });
    const class_extra = try ast.addExtras(&.{
        @backingInt(outer_binding),
        @backingInt(NodeIndex.none),
        @backingInt(body),
        @backingInt(NodeIndex.none),
        0,
        0,
        0,
        0,
    });
    const class = try ast.addNode(.{
        .tag = .class_declaration,
        .span = name,
        .data = .{ .extra = class_extra },
    });
    const root = try ast.addNode(.{
        .tag = .program,
        .span = name,
        .data = .{ .list = try ast.addNodeList(&.{class}) },
    });

    const outer_symbol: Symbol = .{
        .name = name,
        .scope_id = @fromBackingInt(@intCast(0)),
        .kind = .class_decl,
        .declaration_span = name,
    };
    const inner_symbol = outer_symbol;
    const actual_symbols = [_]Symbol{ outer_symbol, inner_symbol };
    var resolved_symbols: [12]Symbol = undefined;
    const filler: Symbol = .{
        .name = name,
        .scope_id = @fromBackingInt(@intCast(0)),
        .kind = .variable_const,
        .declaration_span = name,
    };
    for (&resolved_symbols) |*symbol| symbol.* = filler;
    resolved_symbols[10] = outer_symbol;
    resolved_symbols[11] = inner_symbol;

    // The class self map is missing from the freshly resolved graph. Generic
    // declaration matching sees identical class name/span/kind for the outer
    // declaration and inner self-binding, so it must not make either mapping
    // ambiguous and accept a self reference resolved to the outer binding.
    const actual = [_]?u32{ 0, 1, null, null, null };
    const resolved = [_]?u32{ 10, 10, null, null, null };
    var actual_class_self: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer actual_class_self.deinit(allocator);
    try actual_class_self.put(allocator, @backingInt(class), 1);
    var resolved_class_self: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer resolved_class_self.deinit(allocator);
    try resolved_class_self.put(allocator, @backingInt(class), 11);
    const helper_scope_map: std.StringHashMapUnmanaged(usize) = .empty;
    const empty_markers: std.AutoHashMapUnmanaged(u32, void) = .empty;

    const wrong_target_report = try checkPostMinify(
        allocator,
        &ast,
        root,
        &actual,
        &resolved,
        &actual_symbols,
        &resolved_symbols,
        &.{},
        &.{},
        &helper_scope_map,
        &empty_markers,
        &empty_markers,
        &actual_class_self,
        &resolved_class_self,
    );
    try std.testing.expectEqual(@as(usize, 1), wrong_target_report.wrong_reference_target);
    try std.testing.expect(!wrong_target_report.isClean());

    // If the inner self owner mapping itself is absent, the generic
    // declaration matcher must not infer it from the duplicate outer-class
    // spelling/span and allow the wrong target above to pass.
    const missing_resolved_class_self: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    const report = try checkPostMinify(
        allocator,
        &ast,
        root,
        &actual,
        &resolved,
        &actual_symbols,
        &resolved_symbols,
        &.{},
        &.{},
        &helper_scope_map,
        &empty_markers,
        &empty_markers,
        &actual_class_self,
        &missing_resolved_class_self,
    );
    try std.testing.expectEqual(@as(usize, 1), report.missing_binding_id);
    try std.testing.expect(!report.isClean());
}

test "post-minify audit accepts class self relocated to an exact wrapper binding" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var ast = Ast.init(allocator, "");
    defer ast.deinit();

    const name = try ast.addString("C");
    const wrapper_binding = try makeTestIdentifierNode(&ast, .binding_identifier, name);
    const self_reference = try makeTestIdentifierNode(&ast, .identifier_reference, name);
    const body = try ast.addNode(.{
        .tag = .class_body,
        .span = name,
        .data = .{ .list = try ast.addNodeList(&.{self_reference}) },
    });
    const class_extra = try ast.addExtras(&.{
        @backingInt(NodeIndex.none),
        @backingInt(NodeIndex.none),
        @backingInt(body),
        @backingInt(NodeIndex.none),
        0,
        0,
        0,
        0,
    });
    const class = try ast.addNode(.{
        .tag = .class_expression,
        .span = name,
        .data = .{ .extra = class_extra },
    });
    const root = try ast.addNode(.{
        .tag = .block_statement,
        .span = name,
        .data = .{ .list = try ast.addNodeList(&.{ wrapper_binding, class }) },
    });

    const actual = [_]?u32{ 1, 1, null, null, null };
    const resolved = [_]?u32{ 10, 10, null, null, null };
    const actual_symbols = makePostMinifyTestSymbolTable(2, name);
    const resolved_symbols = makePostMinifyTestSymbolTable(11, name);
    var actual_class_self: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer actual_class_self.deinit(allocator);
    try actual_class_self.put(allocator, @backingInt(class), 1);
    const missing_resolved_class_self: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    const helper_scope_map: std.StringHashMapUnmanaged(usize) = .empty;
    const empty_markers: std.AutoHashMapUnmanaged(u32, void) = .empty;

    const report = try checkPostMinify(
        allocator,
        &ast,
        root,
        &actual,
        &resolved,
        &actual_symbols,
        &resolved_symbols,
        &.{},
        &.{},
        &helper_scope_map,
        &empty_markers,
        &empty_markers,
        &actual_class_self,
        &missing_resolved_class_self,
    );
    try std.testing.expect(report.isClean());

    // Without the direct wrapper binding, the same missing owner map must
    // remain an error; the span/name fallback is insufficient evidence.
    var missing_wrapper_binding = actual;
    missing_wrapper_binding[@backingInt(wrapper_binding)] = null;
    var missing_wrapper_resolution = resolved;
    missing_wrapper_resolution[@backingInt(wrapper_binding)] = null;
    const unproven_report = try checkPostMinify(
        allocator,
        &ast,
        root,
        &missing_wrapper_binding,
        &missing_wrapper_resolution,
        &actual_symbols,
        &resolved_symbols,
        &.{},
        &.{},
        &helper_scope_map,
        &empty_markers,
        &empty_markers,
        &actual_class_self,
        &missing_resolved_class_self,
    );
    try std.testing.expect(unproven_report.missing_binding_id > 0);
    try std.testing.expect(!unproven_report.isClean());
}

test "post-minify audit rejects shadowed globals and requires external provenance" {
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
    actual[@backingInt(binding)] = 7;
    actual[@backingInt(reference)] = 7;
    resolved[@backingInt(binding)] = 2;
    resolved[@backingInt(reference)] = 2;
    const actual_symbols = makePostMinifyTestSymbolTable(8, try ast.addString("__actual_filler"));
    const resolved_symbols = makePostMinifyTestSymbolTable(3, try ast.addString("__resolved_filler"));
    const empty_helper_scope_map: std.StringHashMapUnmanaged(usize) = .empty;
    const empty_class_symbols: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    var unresolved_references: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer unresolved_references.deinit(allocator);
    var explicit_globals: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer explicit_globals.deinit(allocator);
    var report = try checkPostMinify(
        allocator,
        &ast,
        root,
        &actual,
        &resolved,
        &actual_symbols,
        &resolved_symbols,
        &.{},
        &.{},
        &empty_helper_scope_map,
        &unresolved_references,
        &explicit_globals,
        &empty_class_symbols,
        &empty_class_symbols,
    );
    try std.testing.expect(report.isClean());
    try std.testing.expectEqual(@as(usize, 0), report.external_references);

    // A global marker cannot override fresh lexical resolution. If the final
    // spelling resolves to the same-named local binding, emitted code would
    // read that local instead of the intended global.
    try explicit_globals.put(allocator, @backingInt(reference), {});
    actual[@backingInt(reference)] = null;
    report = try checkPostMinify(
        allocator,
        &ast,
        root,
        &actual,
        &resolved,
        &actual_symbols,
        &resolved_symbols,
        &.{},
        &.{},
        &empty_helper_scope_map,
        &unresolved_references,
        &explicit_globals,
        &empty_class_symbols,
        &empty_class_symbols,
    );
    try std.testing.expectEqual(@as(usize, 1), report.shadowed_external_reference);
    try std.testing.expect(!report.isClean());

    // After the emitted local is renamed away, the same identifier is truly
    // unresolved. The fresh analyzer's exact unresolved-node set proves that
    // it is an external reference.
    const global_name = try ast.addString("GlobalName");
    ast.nodes.items[@backingInt(reference)].data.string_ref = global_name;
    resolved[@backingInt(reference)] = null;
    try unresolved_references.put(allocator, @backingInt(reference), {});
    report = try checkPostMinify(
        allocator,
        &ast,
        root,
        &actual,
        &resolved,
        &actual_symbols,
        &resolved_symbols,
        &.{},
        &.{},
        &empty_helper_scope_map,
        &unresolved_references,
        &explicit_globals,
        &empty_class_symbols,
        &empty_class_symbols,
    );
    try std.testing.expect(report.isClean());
    try std.testing.expectEqual(@as(usize, 1), report.external_references);

    // If both forms of external evidence disappear, null IDs cannot silently
    // turn an unclassified identifier into a proven global.
    _ = explicit_globals.remove(@backingInt(reference));
    _ = unresolved_references.remove(@backingInt(reference));
    report = try checkPostMinify(
        allocator,
        &ast,
        root,
        &actual,
        &resolved,
        &actual_symbols,
        &resolved_symbols,
        &.{},
        &.{},
        &empty_helper_scope_map,
        &unresolved_references,
        &explicit_globals,
        &empty_class_symbols,
        &empty_class_symbols,
    );
    try std.testing.expectEqual(@as(usize, 1), report.unproven_external_reference);
    try std.testing.expect(!report.isClean());
}

test "exact identity audit admits only canonical namespace body aliases" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var scanner = try Scanner.init(a, "namespace N { { let local = 1; } } namespace M {}");
    var parser = @import("../parser/parser.zig").Parser.init(a, &scanner);
    parser.configureFromExtension(".ts");
    const root = try parser.parse();
    const Analyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer;
    var sem = Analyzer.init(a, &parser.ast);
    sem.is_ts = true;
    sem.collect_unresolved_reference_nodes = true;
    try sem.analyze();
    try std.testing.expectEqual(@as(usize, 0), sem.errors.items.len);
    var primary: ?u32 = null;
    var sibling: ?u32 = null;
    for (parser.ast.nodes.items, 0..) |node, raw| {
        if (node.tag != .ts_module_declaration) continue;
        if (primary == null) primary = @intCast(raw) else sibling = @intCast(raw);
    }
    const p = primary.?;
    const body = @backingInt(parser.ast.nodes.items[p].data.binary.right);
    const scope = sem.scope_owner_map.get(p).?;
    const sibling_scope = sem.scope_owner_map.get(sibling.?).?;
    try std.testing.expect(scope != sibling_scope);
    const body_node = parser.ast.nodes.items[body];
    const nested = parser.ast.extra_data.items[body_node.data.list.start];
    var parents: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    try parents.put(a, body, p);
    try parents.put(a, nested, body);
    try sem.scope_owner_map.put(a, body, scope);
    try std.testing.expectEqual(p, canonicalNamespaceBodyOwner(&parser.ast, &parents, &sem.scope_owner_map, sem.scopes.items, body).?);
    const empty_nodes: std.AutoHashMapUnmanaged(u32, void) = .empty;
    const origins: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    const canonical = try checkExact(a, &parser.ast, root, @intCast(parser.ast.nodes.items.len), sem.symbol_ids.items, sem.symbols.items, sem.scopes.items, sem.scope_maps.items, &sem.scope_owner_map, sem.references.items, &.{}, &.{}, &empty_nodes, &empty_nodes, &origins);
    try std.testing.expectEqual(@as(usize, 0), canonical.duplicate_scope_owner);
    // A live nested lexical block sharing the same number is still a second
    // owner, not the canonical namespace body edge.
    const nested_scope = sem.scope_owner_map.get(nested).?;
    try sem.scope_owner_map.put(a, nested, scope);
    try std.testing.expect(canonicalNamespaceBodyOwner(&parser.ast, &parents, &sem.scope_owner_map, sem.scopes.items, nested) == null);
    const duplicate = try checkExact(a, &parser.ast, root, @intCast(parser.ast.nodes.items.len), sem.symbol_ids.items, sem.symbols.items, sem.scopes.items, sem.scope_maps.items, &sem.scope_owner_map, sem.references.items, &.{}, &.{}, &empty_nodes, &empty_nodes, &origins);
    try std.testing.expectEqual(@as(usize, 1), duplicate.duplicate_scope_owner);
    try sem.scope_owner_map.put(a, nested, nested_scope);
    try sem.scope_owner_map.put(a, body, sibling_scope);
    try std.testing.expect(canonicalNamespaceBodyOwner(&parser.ast, &parents, &sem.scope_owner_map, sem.scopes.items, body) == null);
    try sem.scope_owner_map.put(a, body, scope);
    _ = sem.scope_owner_map.remove(p);
    try std.testing.expect(canonicalNamespaceBodyOwner(&parser.ast, &parents, &sem.scope_owner_map, sem.scopes.items, body) == null);
    try sem.scope_owner_map.put(a, p, scope);
    const original = parser.ast.nodes.items[p];
    parser.ast.nodes.items[p].data.binary.flags = 1;
    try std.testing.expect(canonicalNamespaceBodyOwner(&parser.ast, &parents, &sem.scope_owner_map, sem.scopes.items, body) == null);
    parser.ast.nodes.items[p] = original;
    try parents.put(a, body, sibling.?);
    try std.testing.expect(canonicalNamespaceBodyOwner(&parser.ast, &parents, &sem.scope_owner_map, sem.scopes.items, body) == null);
    try parents.put(a, body, p);
    const original_body = parser.ast.nodes.items[body];
    parser.ast.nodes.items[body].tag = .empty_statement;
    try std.testing.expect(canonicalNamespaceBodyOwner(&parser.ast, &parents, &sem.scope_owner_map, sem.scopes.items, body) == null);
    parser.ast.nodes.items[body] = original_body;
    _ = sem.scope_owner_map.remove(body);
    try std.testing.expect(canonicalNamespaceBodyOwner(&parser.ast, &parents, &sem.scope_owner_map, sem.scopes.items, body) == null);
    try sem.scope_owner_map.put(a, body, @intCast(sem.scopes.items.len));
    try sem.scope_owner_map.put(a, p, @intCast(sem.scopes.items.len));
    try std.testing.expect(canonicalNamespaceBodyOwner(&parser.ast, &parents, &sem.scope_owner_map, sem.scopes.items, body) == null);
    try sem.scope_owner_map.put(a, body, scope);
    try sem.scope_owner_map.put(a, p, scope);
    const scopes = try a.dupe(Scope, sem.scopes.items);
    scopes[scope].kind = .block;
    try std.testing.expect(canonicalNamespaceBodyOwner(&parser.ast, &parents, &sem.scope_owner_map, scopes, body) == null);
}
