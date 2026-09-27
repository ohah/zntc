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
const Reference = @import("../semantic/symbol.zig").Reference;
const Scope = @import("../semantic/scope.zig").Scope;
const ScopeId = @import("../semantic/scope.zig").ScopeId;
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
pub const StrictStatus = enum {
    bound,
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
pub const StrictReport = struct {
    counts: [std.meta.fields(StrictStatus).len]usize = @splat(0),
    marked_synthetic: usize = 0,
    findings: std.ArrayList(StrictFinding) = .empty,

    pub fn deinit(self: *StrictReport, allocator: std.mem.Allocator) void {
        self.findings.deinit(allocator);
    }

    /// True only when every generated runtime identifier has exact SymbolId
    /// and ScopeId evidence. Unbound references remain unclassified: spelling
    /// alone cannot prove that they refer to a global.
    pub fn hasCompleteExactCoverage(self: *const StrictReport) bool {
        for (self.counts, 0..) |count, status| {
            if (status != @intFromEnum(StrictStatus.bound) and count != 0) return false;
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
    references: *const std.AutoHashMapUnmanaged(u32, ReferenceEvidence),
    synthetic: ?*const std.AutoHashMapUnmanaged(u32, void),
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
        const status = self.classify(node, name, sid, trace, reference);
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
        node: Node,
        name: []const u8,
        sid: ?u32,
        trace: ?ScopeTrace,
        reference: ?ReferenceEvidence,
    ) StrictStatus {
        const id = sid orelse {
            if (node.tag == .binding_identifier) return .missing_binding;
            // The analyzer currently records unresolved globals by spelling,
            // not by NodeIndex. A same-named local reference therefore cannot
            // be proven global from this table alone.
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
            if (!expected.valid) return .invalid_scope;
            const lexical_scope = expected.scope_id orelse return .scope_unknown;
            if (!validScope(@enumFromInt(lexical_scope), self.scopes)) return .invalid_scope;
            const declaration_scope = if (symbol.kind == .variable_var)
                nearestVarScope(lexical_scope, self.scopes) orelse return .invalid_scope
            else
                lexical_scope;
            // Both fields must identify the exact binding scope. For `var`,
            // the semantic declaration is normalized to its nearest var scope;
            // other bindings stay at their lexical owner. Checking only
            // origin_scope lets a valid but unrelated storage scope pass.
            return if (@intFromEnum(symbol.scope_id) == declaration_scope and
                @intFromEnum(symbol.origin_scope) == declaration_scope) .bound else .scope_mismatch;
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

const ReferenceEvidence = struct {
    reference: Reference,
    count: u8 = 1,
};

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
            // FunctionDeclaration/ClassDeclaration names are bound in the
            // enclosing lexical scope, although their node also owns the
            // function/class body scope. Other children inherit that scope.
            const child_scope = if (isOuterDeclarationName(ast, parent, child)) scope_visit.incoming else effective;
            try stack.append(allocator, .{ .node = child, .incoming = child_scope });
        }
    }
    return traces;
}

fn isOuterDeclarationName(ast: *const Ast, parent: Node, child: NodeIndex) bool {
    const offset: ?u32 = switch (parent.tag) {
        .function_declaration => ast_mod.FunctionExtra.name,
        .class_declaration => ast_mod.ClassExtra.name,
        else => null,
    };
    const name_offset = offset orelse return false;
    const slot = parent.data.extra + name_offset;
    if (@as(usize, slot) >= ast.extra_data.items.len) return false;
    const raw = ast.extra_data.items[slot];
    return raw != @intFromEnum(NodeIndex.none) and raw == @intFromEnum(child);
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
    var report: StrictReport = .{};
    errdefer report.deinit(allocator);
    var node_scopes = try collectScopeTraces(allocator, ast, root, scopes, scope_owner_map);
    defer node_scopes.deinit(allocator);
    var reference_evidence = try collectReferenceEvidence(allocator, references);
    defer reference_evidence.deinit(allocator);
    var ctx: StrictCtx = .{
        .allocator = allocator,
        .ast = ast,
        .parser_node_count = parser_node_count,
        .symbol_ids = symbol_ids,
        .symbols = symbols,
        .scopes = scopes,
        .node_scopes = &node_scopes,
        .references = &reference_evidence,
        .synthetic = synthetic,
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
        "zntc: synthetic-coverage {s}: bound={d} missing_binding={d} unclassified={d} invalid_id={d} name_mismatch={d} missing_reference={d} identity_mismatch={d} invalid_scope={d} scope_unknown={d} scope_ambiguous={d} scope_mismatch={d} invisible_reference={d} duplicate_reference={d} marked_synthetic={d}\n",
        .{ file_path, report.counts[@intFromEnum(StrictStatus.bound)], report.counts[@intFromEnum(StrictStatus.missing_binding)], report.counts[@intFromEnum(StrictStatus.unclassified)], report.counts[@intFromEnum(StrictStatus.invalid_id)], report.counts[@intFromEnum(StrictStatus.name_mismatch)], report.counts[@intFromEnum(StrictStatus.missing_reference)], report.counts[@intFromEnum(StrictStatus.identity_mismatch)], report.counts[@intFromEnum(StrictStatus.invalid_scope)], report.counts[@intFromEnum(StrictStatus.scope_unknown)], report.counts[@intFromEnum(StrictStatus.scope_ambiguous)], report.counts[@intFromEnum(StrictStatus.scope_mismatch)], report.counts[@intFromEnum(StrictStatus.invisible_reference)], report.counts[@intFromEnum(StrictStatus.duplicate_reference)], report.marked_synthetic },
    );
    var printed: [std.meta.fields(StrictStatus).len]usize = @splat(0);
    for (report.findings.items) |finding| {
        if (finding.status == .bound) continue;
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
