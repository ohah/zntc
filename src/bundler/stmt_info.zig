//! ZNTC Bundler — Statement Info (rolldown 방식)
//!
//! 각 top-level statement가 선언하는 심볼과 참조하는 심볼을 추적한다.
//! semantic analyzer의 symbol_ids (node_index → symbol_index) 매핑을 재활용.
//!
//! tree_shaker: import binding liveness 판정 (도달성 기반)
//! statement_shaker: 미사용 statement 제거 (skip_nodes)
//! emitter: used_names 정제

const std = @import("std");
const ast_mod = @import("../parser/ast.zig");
const Ast = ast_mod.Ast;
const Node = ast_mod.Node;
const NodeIndex = ast_mod.NodeIndex;
const Span = @import("../lexer/token.zig").Span;
const TokenKind = @import("../lexer/token.zig").Kind;
const Symbol = @import("../semantic/symbol.zig").Symbol;
const Reference = @import("../semantic/symbol.zig").Reference;
const scope_mod = @import("../semantic/scope.zig");
const ScopeId = scope_mod.ScopeId;
const Scope = scope_mod.Scope;
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

pub const CjsExportFact = struct {
    pub const Kind = enum {
        assignment,
        object_property,
        define_property_value,
        define_property_getter,

        /// stmt 자체가 단일 export 라 BFS seed 시 stmt 전체를 enqueue 하면 충분한지.
        /// `assignment` (`exports.foo = rhs`) 만 그렇고, 나머지는 같은 stmt 안에 여러 export
        /// 가 공존할 수 있어 호출자가 rhs symbol 만 시드한다.
        pub fn seedsWholeStatement(self: Kind) bool {
            return self == .assignment;
        }
    };

    /// 디코드된 owned UTF-8. `ModuleStmtInfos.deinit` 가 해제. ESM importer 의 binding
    /// name (디코드된 identifier) 과 직접 비교 가능 — `\xHH`/`\uHHHH` 등 escape 가
    /// 들어간 raw key 도 정확히 매칭된다.
    export_name: []u8,
    statement_index: u32,
    export_assignment_node: u32,
    property_node: ?u32 = null,
    rhs_symbol: ?u32 = null,
    helper_symbol: ?u32 = null,
    target_symbol: ?u32 = null,
    kind: Kind = .assignment,
    is_safe_to_prune: bool = true,
};

pub const ModuleStmtInfos = struct {
    stmts: []StmtInfo,
    /// 정적으로 증명된 CJS named export. 형태별 분기는 `CjsExportFact.Kind` 참고.
    cjs_export_facts: []const CjsExportFact = &.{},
    /// symbol_index → stmt_index (선언 역매핑). 없으면 null.
    symbol_to_stmt: []const ?u32,
    /// symbol_index → [side-effect stmt indices that reference this symbol].
    /// tree_shaker.enqueue()에서 O(1) 조회용.
    sym_to_side_effect_stmts: []const []const u32,
    /// symbol_index → [all stmt indices that reference this symbol].
    /// tree_shaker.isImportLiveInModule()에서 O(1) 조회용.
    sym_to_referencing_stmts: []const []const u32,
    /// symbol_index → [stmt indices that WRITE to this symbol but do not declare it].
    /// `var _a; ... _a = AST;` 같은 TS-emit 패턴에서 비선언 할당이 read 와 함께 살아남도록
    /// computeReachable BFS 가 추가 엣지로 사용. 선언 stmt 자체는 별도 경로(`symbol_to_stmt`)
    /// 로 처리되므로 여기서는 제외.
    sym_to_writer_stmts: []const []const u32,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *ModuleStmtInfos) void {
        for (self.stmts) |stmt| {
            self.allocator.free(stmt.declared_symbols);
            self.allocator.free(stmt.referenced_symbols);
        }
        self.allocator.free(self.stmts);
        freeFactNames(self.allocator, self.cjs_export_facts);
        if (self.cjs_export_facts.len > 0) self.allocator.free(self.cjs_export_facts);
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
        for (self.sym_to_writer_stmts) |s| {
            if (s.len > 0) self.allocator.free(s);
        }
        self.allocator.free(self.sym_to_writer_stmts);
    }

    pub fn cjsExportFactByName(self: *const ModuleStmtInfos, export_name: []const u8) ?CjsExportFact {
        var found: ?CjsExportFact = null;
        for (self.cjs_export_facts) |fact| {
            if (!fact.is_safe_to_prune) continue;
            if (!std.mem.eql(u8, fact.export_name, export_name)) continue;
            if (found != null) return null;
            found = fact;
        }
        return found;
    }

    /// symbol_index가 선언된 statement 인덱스 반환.
    pub fn declaredStmtBySymbol(self: *const ModuleStmtInfos, sym_idx: u32) ?u32 {
        if (sym_idx >= self.symbol_to_stmt.len) return null;
        return self.symbol_to_stmt[sym_idx];
    }

    /// symbol 을 read 하는 statement 인덱스들. 미등록 symbol 이면 빈 슬라이스.
    pub fn referencingStmts(self: *const ModuleStmtInfos, sym_idx: u32) []const u32 {
        if (sym_idx >= self.sym_to_referencing_stmts.len) return &.{};
        return self.sym_to_referencing_stmts[sym_idx];
    }

    /// symbol 을 비선언 write 하는 statement 인덱스들. 미등록 symbol 이면 빈 슬라이스.
    pub fn writerStmts(self: *const ModuleStmtInfos, sym_idx: u32) []const u32 {
        if (sym_idx >= self.sym_to_writer_stmts.len) return &.{};
        return self.sym_to_writer_stmts[sym_idx];
    }

    /// symbol 을 reference 하는 side-effectful statement 인덱스들. 미등록이면 빈 슬라이스.
    pub fn sideEffectStmts(self: *const ModuleStmtInfos, sym_idx: u32) []const u32 {
        if (sym_idx >= self.sym_to_side_effect_stmts.len) return &.{};
        return self.sym_to_side_effect_stmts[sym_idx];
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
                try seedStmt(allocator, &reachable_stmts, &queue, @intCast(i));
            }
        }

        // seed: used exports가 선언된 statements + 같은 심볼의 writer statements
        for (used_export_sym_indices) |sym_idx| {
            try self.seedSymbolLiveStmts(allocator, &reachable_stmts, &queue, sym_idx);
        }

        // BFS: referenced_symbols → (declarer, writers) → dependent statements.
        // writer 엣지가 없으면 `_a = AST` 같은 비선언 할당이 read 만 도달해도 누락된다.
        var head: u32 = 0;
        while (head < queue.items.len) : (head += 1) {
            const stmt_idx = queue.items[head];
            for (self.stmts[stmt_idx].referenced_symbols) |ref_sym| {
                try self.seedSymbolLiveStmts(allocator, &reachable_stmts, &queue, ref_sym);
            }
        }

        return reachable_stmts;
    }

    fn seedSymbolLiveStmts(
        self: *const ModuleStmtInfos,
        allocator: std.mem.Allocator,
        reachable: *std.DynamicBitSet,
        queue: *std.ArrayListUnmanaged(u32),
        sym_idx: u32,
    ) !void {
        if (self.declaredStmtBySymbol(sym_idx)) |stmt_idx| {
            try seedStmt(allocator, reachable, queue, stmt_idx);
        }
        for (self.writerStmts(sym_idx)) |writer_stmt| {
            try seedStmt(allocator, reachable, queue, writer_stmt);
        }
    }
};

fn seedStmt(
    allocator: std.mem.Allocator,
    reachable: *std.DynamicBitSet,
    queue: *std.ArrayListUnmanaged(u32),
    stmt_idx: u32,
) !void {
    if (reachable.isSet(stmt_idx)) return;
    reachable.set(stmt_idx);
    try queue.append(allocator, stmt_idx);
}

const CjsExportCandidate = struct {
    /// owned UTF-8. fact 로 transferred 되거나 candidate 가 reject 시 caller 가 free.
    export_name: []u8,
    export_assignment_node: u32,
    rhs_node: NodeIndex,
    property_node: ?u32 = null,
    helper_node: NodeIndex = .none,
    target_node: NodeIndex = .none,
    kind: CjsExportFact.Kind = .assignment,
};

/// fact 들의 owned `export_name` 을 일괄 해제. `ModuleStmtInfos.deinit` 와 빌더의
/// errdefer 가 공유.
fn freeFactNames(allocator: std.mem.Allocator, facts: []const CjsExportFact) void {
    for (facts) |f| allocator.free(f.export_name);
}

/// 빌더 errdefer 용 — append 된 fact 들의 owned name 해제 + buffer deinit.
fn deinitCjsExportFactsBuf(
    allocator: std.mem.Allocator,
    buf: *std.ArrayListUnmanaged(CjsExportFact),
) void {
    freeFactNames(allocator, buf.items);
    buf.deinit(allocator);
}

fn rhsSymbolFor(symbol_ids: ?[]const ?u32, rhs_node: NodeIndex) ?u32 {
    const sids = symbol_ids orelse return null;
    if (rhs_node.isNone()) return null;
    const idx = @intFromEnum(rhs_node);
    if (idx >= sids.len) return null;
    return sids[idx];
}

fn staticMemberParts(ast: *const Ast, idx: NodeIndex) ?struct { object: NodeIndex, property: NodeIndex } {
    if (idx.isNone() or @intFromEnum(idx) >= ast.nodes.items.len) return null;
    const node = ast.nodes.items[@intFromEnum(idx)];
    if (node.tag != .static_member_expression) return null;
    const e = node.data.extra;
    if (!ast.hasExtra(e, 1)) return null;
    const obj_idx = ast.readExtraNode(e, 0);
    const prop_idx = ast.readExtraNode(e, 1);
    if (obj_idx.isNone() or prop_idx.isNone()) return null;
    if (@intFromEnum(obj_idx) >= ast.nodes.items.len or @intFromEnum(prop_idx) >= ast.nodes.items.len) return null;
    return .{ .object = obj_idx, .property = prop_idx };
}

/// top-level `BASE.PROP = RHS;` (단순 `=` 대입, LHS 정적 멤버, BASE 단일
/// identifier) 의 base/property identifier / rhs 노드. 아니면 null.
/// `gatedMemberAugmentObjectNode` 가 RHS 순수성·글로벌 검사를 덧붙이는
/// 공통 구조 추출 코어 (#3359 중복 제거).
fn memberAssignTargetParts(
    ast: *const Ast,
    stmt_node: Node,
) ?struct { base: NodeIndex, property: NodeIndex, rhs: NodeIndex } {
    if (stmt_node.tag != .expression_statement) return null;
    const expr_idx = stmt_node.data.unary.operand;
    if (expr_idx.isNone() or @intFromEnum(expr_idx) >= ast.nodes.items.len) return null;
    const expr = ast.nodes.items[@intFromEnum(expr_idx)];
    if (expr.tag != .assignment_expression) return null;
    // `=` (단순 대입) 만. `+=` 등 compound 는 read+write 라 dead 여도 단순
    // drop 이 안전하지 않아 제외 (operator 는 binary.flags 에 토큰 Kind).
    const op: TokenKind = @enumFromInt(expr.data.binary.flags);
    if (op != .eq) return null;
    const parts = staticMemberParts(ast, expr.data.binary.left) orelse return null;
    const obj = ast.nodes.items[@intFromEnum(parts.object)];
    if (obj.tag != .identifier_reference) return null;
    return .{ .base = parts.object, .property = parts.property, .rhs = expr.data.binary.right };
}

/// Reanimated/react-native-worklets Babel plugin 이 worklet 함수에 부착하는
/// 메타데이터 프로퍼티. ZNTC native worklet 변환 (`transformer/worklet.zig`) 은
/// 앞 3 개 (`__workletHash`, `__closure`, `__initData`) 만 emit 하고, 나머지는
/// 외부 Babel plugin 산출물을 인식해 base symbol augmentation 으로 함께 tree-shake
/// 하기 위해 reserve 한 이름들이다. `__bundleData` 는 react-native-worklets 의
/// bundle worklet (worklet body 가 별도 번들로 빌드되는 모드) 출력.
fn isWorkletMetadataProperty(name: []const u8) bool {
    return std.mem.eql(u8, name, "__workletHash") or
        std.mem.eql(u8, name, "__closure") or
        std.mem.eql(u8, name, "__initData") or
        std.mem.eql(u8, name, "__stackDetails") or
        std.mem.eql(u8, name, "__pluginVersion") or
        std.mem.eql(u8, name, "__bundleData");
}

fn workletMetadataObjectNode(
    ast: *const Ast,
    stmt_node: Node,
    unresolved_globals: ?*const purity.GlobalRefSet,
) ?NodeIndex {
    const m = memberAssignTargetParts(ast, stmt_node) orelse return null;
    const obj = ast.nodes.items[@intFromEnum(m.base)];

    if (unresolved_globals) |globals| {
        if (globals.contains(ast.getText(obj.span))) return null;
    }

    const prop = ast.nodes.items[@intFromEnum(m.property)];
    if (prop.tag != .identifier_reference) return null;
    if (!isWorkletMetadataProperty(ast.getText(prop.span))) return null;
    return m.base;
}

fn isModuleExportsLhs(ast: *const Ast, lhs: NodeIndex) bool {
    const parts = staticMemberParts(ast, lhs) orelse return false;
    const obj = ast.nodes.items[@intFromEnum(parts.object)];
    const prop = ast.nodes.items[@intFromEnum(parts.property)];
    if (obj.tag != .identifier_reference) return false;
    return std.mem.eql(u8, ast.getText(obj.span), "module") and
        std.mem.eql(u8, ast.getText(prop.span), "exports");
}

/// `exports.foo` / `module.exports.foo` 의 prop NodeIndex 반환. 호출자가
/// `ast.staticKeyName` 으로 owned 이름을 만들도록 한다.
fn cjsExportNamePropFromLhs(ast: *const Ast, lhs: NodeIndex) ?NodeIndex {
    const outer = staticMemberParts(ast, lhs) orelse return null;
    const prop = ast.nodes.items[@intFromEnum(outer.property)];
    if (prop.tag != .identifier_reference and prop.tag != .private_identifier) return null;

    const obj = ast.nodes.items[@intFromEnum(outer.object)];
    if (obj.tag == .identifier_reference and std.mem.eql(u8, ast.getText(obj.span), "exports")) {
        return outer.property;
    }
    if (obj.tag == .static_member_expression and isModuleExportsLhs(ast, outer.object)) {
        return outer.property;
    }
    return null;
}

/// CJS object-shape export 의 value 위치에서 의존성 시드로 쓸 노드를 반환.
/// identifier 는 그대로, `ns.member` 같은 정적 멤버는 base object (`ns`) 를 시드한다.
/// tree_shaker 가 `rhs_symbol → declaring stmt` 로 dependency 를 살릴 수 없는
/// 리터럴/동적 멤버/optional chain 등은 보수적으로 거부한다.
fn cjsObjectPropertyValueSeedNode(ast: *const Ast, value: NodeIndex, unresolved_globals: ?*const purity.GlobalRefSet) ?NodeIndex {
    if (value.isNone() or @intFromEnum(value) >= ast.nodes.items.len) return null;
    if (!purity.isExprPure(ast, value, unresolved_globals)) return null;
    return definePropertyDescriptorValueSeedNode(ast, value);
}

fn cjsExportCandidateForStmt(alloc: std.mem.Allocator, ast: *const Ast, stmt_node: Node) !?CjsExportCandidate {
    if (stmt_node.tag != .expression_statement) return null;
    const expr_idx = stmt_node.data.unary.operand;
    if (expr_idx.isNone() or @intFromEnum(expr_idx) >= ast.nodes.items.len) return null;
    const expr = ast.nodes.items[@intFromEnum(expr_idx)];
    if (expr.tag != .assignment_expression) return null;

    if (isModuleExportsLhs(ast, expr.data.binary.left)) {
        const rhs_idx = expr.data.binary.right;
        if (!rhs_idx.isNone() and @intFromEnum(rhs_idx) < ast.nodes.items.len) {
            const rhs = ast.nodes.items[@intFromEnum(rhs_idx)];
            // `module.exports = { ... }` has its own object-shape extractor so named
            // imports can prune individual properties. Treating the whole object as
            // default here would hide that more precise path.
            if (rhs.tag != .object_expression) {
                return .{
                    .export_name = try alloc.dupe(u8, "default"),
                    .export_assignment_node = @intFromEnum(expr_idx),
                    .rhs_node = rhs_idx,
                };
            }
        }
    }

    const prop_idx = cjsExportNamePropFromLhs(ast, expr.data.binary.left) orelse return null;
    const export_name = (try ast.staticKeyName(alloc, prop_idx)) orelse return null;
    return .{
        .export_name = export_name,
        .export_assignment_node = @intFromEnum(expr_idx),
        .rhs_node = expr.data.binary.right,
    };
}

fn isObjectDefinePropertyCallee(ast: *const Ast, callee_idx: NodeIndex) bool {
    const outer = staticMemberParts(ast, callee_idx) orelse return false;
    const object = ast.nodes.items[@intFromEnum(outer.object)];
    const property = ast.nodes.items[@intFromEnum(outer.property)];
    if (object.tag != .identifier_reference) return false;
    return std.mem.eql(u8, ast.getText(object.span), "Object") and
        std.mem.eql(u8, ast.getText(property.span), "defineProperty");
}

fn isGlobalObjectDefinePropertyCallee(
    ast: *const Ast,
    callee_idx: NodeIndex,
    unresolved_globals: ?*const purity.GlobalRefSet,
) bool {
    if (!isObjectDefinePropertyCallee(ast, callee_idx)) return false;
    const globals = unresolved_globals orelse return false;
    return globals.contains("Object");
}

fn isCjsExportObjectExpr(ast: *const Ast, idx: NodeIndex) bool {
    if (idx.isNone() or @intFromEnum(idx) >= ast.nodes.items.len) return false;
    const node = ast.nodes.items[@intFromEnum(idx)];
    if (node.tag == .identifier_reference) {
        return std.mem.eql(u8, ast.getText(node.span), "exports");
    }
    return isModuleExportsLhs(ast, idx);
}

/// string_literal 의 escape 가 풀린 형태로 비교 안 하므로 raw 와 source-after-decode
/// 가 다른 경우는 reject — 잘못된 export 매칭을 막는 보수적 가드.
pub fn plainStringLiteralValue(ast: *const Ast, idx: NodeIndex) ?[]const u8 {
    if (idx.isNone() or @intFromEnum(idx) >= ast.nodes.items.len) return null;
    const n = ast.nodes.items[@intFromEnum(idx)];
    if (n.tag != .string_literal) return null;
    const raw = ast.getText(n.span);
    if (std.mem.indexOfScalar(u8, raw, '\\') != null) return null;
    return Ast.stripStringQuotes(raw);
}

/// object_property 의 key 노드에서 정적 이름을 추출 (escape-bearing string 은 reject).
/// 인식: `identifier_reference` (`{ x: ... }`), `string_literal` (`{ "x": ... }`).
/// 미인식: `computed_property_key`, `numeric_literal`, escape 포함 문자열.
pub fn plainObjectKeyName(ast: *const Ast, key_idx: NodeIndex) ?[]const u8 {
    if (key_idx.isNone() or @intFromEnum(key_idx) >= ast.nodes.items.len) return null;
    const key = ast.nodes.items[@intFromEnum(key_idx)];
    return switch (key.tag) {
        .identifier_reference => ast.getText(key.data.string_ref),
        .string_literal => plainStringLiteralValue(ast, key_idx),
        else => null,
    };
}

fn isBooleanLiteral(ast: *const Ast, idx: NodeIndex, expected: []const u8) bool {
    if (idx.isNone() or @intFromEnum(idx) >= ast.nodes.items.len) return false;
    const node = ast.nodes.items[@intFromEnum(idx)];
    return node.tag == .boolean_literal and std.mem.eql(u8, ast.getText(node.span), expected);
}

fn isIdentifierReference(ast: *const Ast, idx: NodeIndex) bool {
    if (idx.isNone() or @intFromEnum(idx) >= ast.nodes.items.len) return false;
    return ast.nodes.items[@intFromEnum(idx)].tag == .identifier_reference;
}

fn identifierReferenceText(ast: *const Ast, idx: NodeIndex) ?[]const u8 {
    if (!isIdentifierReference(ast, idx)) return null;
    return ast.getText(ast.nodes.items[@intFromEnum(idx)].span);
}

/// defineProperty descriptor 의 `value` 위치에서 의존성 시드로 쓸 노드를 반환.
/// `liveNs.value` 같은 정적 멤버는 base object (`liveNs`) 를 시드로 돌려 tree_shaker
/// 가 `rhs_symbol → declaring stmt` 로 base 의 declaring statement 를 살리게 한다.
/// optional chain / 비-식별자 base / 동적 property 는 보수적으로 거부.
fn definePropertyDescriptorValueSeedNode(ast: *const Ast, value_idx: NodeIndex) ?NodeIndex {
    if (isIdentifierReference(ast, value_idx)) return value_idx;

    const parts = staticMemberParts(ast, value_idx) orelse return null;
    const value = ast.nodes.items[@intFromEnum(value_idx)];
    if (!ast.hasExtra(value.data.extra, 2)) return null;
    if ((ast.readExtra(value.data.extra, 2) & ast_mod.MemberFlags.optional_chain) != 0) return null;
    if (!isIdentifierReference(ast, parts.object)) return null;
    const property = ast.nodes.items[@intFromEnum(parts.property)];
    if (property.tag != .identifier_reference and property.tag != .private_identifier) return null;
    return parts.object;
}

fn singleReturnIdentifierFromFunctionBody(ast: *const Ast, body_idx: NodeIndex) ?NodeIndex {
    if (body_idx.isNone() or @intFromEnum(body_idx) >= ast.nodes.items.len) return null;
    const body = ast.nodes.items[@intFromEnum(body_idx)];
    if (body.tag != .block_statement) return null;

    const list = body.data.list;
    if (list.start + list.len > ast.extra_data.items.len) return null;
    if (list.len != 1) return null;

    const stmt_idx: NodeIndex = @enumFromInt(ast.extra_data.items[list.start]);
    if (stmt_idx.isNone() or @intFromEnum(stmt_idx) >= ast.nodes.items.len) return null;
    const stmt = ast.nodes.items[@intFromEnum(stmt_idx)];
    if (stmt.tag != .return_statement) return null;

    const ret = stmt.data.unary.operand;
    return if (isIdentifierReference(ast, ret)) ret else null;
}

fn zeroParamFunctionReturnIdentifier(ast: *const Ast, fn_idx: NodeIndex) ?NodeIndex {
    if (fn_idx.isNone() or @intFromEnum(fn_idx) >= ast.nodes.items.len) return null;
    const fn_node = ast.nodes.items[@intFromEnum(fn_idx)];

    const flags_slot: u32 = switch (fn_node.tag) {
        .function_expression => 3,
        .arrow_function_expression => 2,
        else => return null,
    };
    if (!ast.hasExtra(fn_node.data.extra, flags_slot)) return null;

    const flags = ast.readExtra(fn_node.data.extra, flags_slot);
    switch (fn_node.tag) {
        .function_expression => if ((flags & (ast_mod.FunctionFlags.is_async | ast_mod.FunctionFlags.is_generator)) != 0) return null,
        .arrow_function_expression => if ((flags & ast_mod.ArrowFlags.is_async) != 0) return null,
        else => unreachable,
    }
    if (ast.functionParamsList(fn_node).len != 0) return null;

    const body_idx = ast.functionBodyBlock(fn_node) orelse return null;
    if (fn_node.tag == .arrow_function_expression and isIdentifierReference(ast, body_idx)) {
        return body_idx;
    }
    return singleReturnIdentifierFromFunctionBody(ast, body_idx);
}

fn methodReturnIdentifier(ast: *const Ast, method_idx: NodeIndex) ?NodeIndex {
    if (method_idx.isNone() or @intFromEnum(method_idx) >= ast.nodes.items.len) return null;
    const method = ast.nodes.items[@intFromEnum(method_idx)];
    if (method.tag != .method_definition) return null;
    if (!ast.hasExtra(method.data.extra, ast_mod.MethodExtra.flags)) return null;

    const flags = ast.readExtra(method.data.extra, ast_mod.MethodExtra.flags);
    if ((flags & (ast_mod.MethodFlags.is_async | ast_mod.MethodFlags.is_generator | ast_mod.MethodFlags.is_setter)) != 0) return null;
    if (ast.functionParamsList(method).len != 0) return null;

    const body_idx = ast.readExtraNode(method.data.extra, ast_mod.MethodExtra.body);
    return singleReturnIdentifierFromFunctionBody(ast, body_idx);
}

const DefinePropertyDescriptorExport = struct {
    rhs_node: NodeIndex,
    kind: CjsExportFact.Kind,
};

fn definePropertyDescriptorExportNode(
    ast: *const Ast,
    descriptor_idx: NodeIndex,
    unresolved_globals: ?*const purity.GlobalRefSet,
) ?DefinePropertyDescriptorExport {
    if (descriptor_idx.isNone() or @intFromEnum(descriptor_idx) >= ast.nodes.items.len) return null;
    const descriptor = ast.nodes.items[@intFromEnum(descriptor_idx)];
    if (descriptor.tag != .object_expression) return null;

    const list = descriptor.data.list;
    if (list.start + list.len > ast.extra_data.items.len) return null;
    const indices = ast.extra_data.items[list.start .. list.start + list.len];
    if (indices.len == 0) return null;

    // descriptor 의 정적 키만 허용한다. spread/computed/duplicate/accessor 혼합은
    // defineProperty semantics 보존을 위해 fact 대상에서 제외한다.
    var seen: [5][]const u8 = undefined;
    var seen_len: usize = 0;
    var result: ?DefinePropertyDescriptorExport = null;

    for (indices) |raw_prop| {
        const prop_idx: NodeIndex = @enumFromInt(raw_prop);
        if (prop_idx.isNone() or @intFromEnum(prop_idx) >= ast.nodes.items.len) return null;
        const prop = ast.nodes.items[@intFromEnum(prop_idx)];

        const key_idx = switch (prop.tag) {
            .object_property => prop.data.binary.left,
            .method_definition => ast.readExtraNode(prop.data.extra, ast_mod.MethodExtra.key),
            else => return null,
        };
        const name = plainObjectKeyName(ast, key_idx) orelse return null;
        if (seen_len >= seen.len) return null;
        for (seen[0..seen_len]) |prev| {
            if (std.mem.eql(u8, prev, name)) return null;
        }
        seen[seen_len] = name;
        seen_len += 1;

        if (std.mem.eql(u8, name, "set")) return null;

        if (prop.tag == .method_definition) {
            if (!std.mem.eql(u8, name, "get")) return null;
            if (result != null) return null;
            const returned = methodReturnIdentifier(ast, prop_idx) orelse return null;
            result = .{ .rhs_node = returned, .kind = .define_property_getter };
            continue;
        }

        const prop_value = Ast.objectPropertyValue(prop);
        if (prop_value.isNone() or @intFromEnum(prop_value) >= ast.nodes.items.len) return null;

        if (std.mem.eql(u8, name, "value")) {
            if (result != null) return null;
            if (!purity.isExprPure(ast, prop_value, unresolved_globals)) return null;
            const seed_node = definePropertyDescriptorValueSeedNode(ast, prop_value) orelse return null;
            result = .{ .rhs_node = seed_node, .kind = .define_property_value };
        } else if (std.mem.eql(u8, name, "get")) {
            if (result != null) return null;
            const returned = zeroParamFunctionReturnIdentifier(ast, prop_value) orelse return null;
            result = .{ .rhs_node = returned, .kind = .define_property_getter };
        } else {
            if (!purity.isExprPure(ast, prop_value, unresolved_globals)) return null;
        }
    }

    return result;
}

fn cjsDefinePropertyExportCandidateForStmt(
    alloc: std.mem.Allocator,
    ast: *const Ast,
    stmt_node: Node,
    unresolved_globals: ?*const purity.GlobalRefSet,
) !?CjsExportCandidate {
    if (stmt_node.tag != .expression_statement) return null;
    const expr_idx = stmt_node.data.unary.operand;
    if (expr_idx.isNone() or @intFromEnum(expr_idx) >= ast.nodes.items.len) return null;
    const expr = ast.nodes.items[@intFromEnum(expr_idx)];
    if (expr.tag != .call_expression) return null;

    const e = expr.data.extra;
    if (!ast.hasExtra(e, 2)) return null;
    const callee_idx = ast.readExtraNode(e, 0);
    const args_start = ast.readExtra(e, 1);
    const args_len = ast.readExtra(e, 2);
    if (args_len != 3) return null;
    if (args_start + args_len > ast.extra_data.items.len) return null;
    if (!isObjectDefinePropertyCallee(ast, callee_idx)) return null;

    const target_idx: NodeIndex = @enumFromInt(ast.extra_data.items[args_start]);
    const export_name_idx: NodeIndex = @enumFromInt(ast.extra_data.items[args_start + 1]);
    const descriptor_idx: NodeIndex = @enumFromInt(ast.extra_data.items[args_start + 2]);
    if (!isCjsExportObjectExpr(ast, target_idx)) return null;

    const export_name = (try ast.staticKeyName(alloc, export_name_idx)) orelse return null;
    var name_transferred = false;
    defer if (!name_transferred) alloc.free(export_name);

    if (std.mem.eql(u8, export_name, "__esModule")) return null;

    const descriptor_export = definePropertyDescriptorExportNode(ast, descriptor_idx, unresolved_globals) orelse return null;

    name_transferred = true;
    return .{
        .export_name = export_name,
        .export_assignment_node = @intFromEnum(expr_idx),
        .rhs_node = descriptor_export.rhs_node,
        .kind = descriptor_export.kind,
    };
}

fn cjsModuleExportsAssignedObjectName(ast: *const Ast, stmt_node: Node) ?[]const u8 {
    if (stmt_node.tag != .expression_statement) return null;
    const expr_idx = stmt_node.data.unary.operand;
    if (expr_idx.isNone() or @intFromEnum(expr_idx) >= ast.nodes.items.len) return null;
    const expr = ast.nodes.items[@intFromEnum(expr_idx)];
    if (expr.tag != .assignment_expression) return null;
    if (!isModuleExportsLhs(ast, expr.data.binary.left)) return null;

    const rhs_idx = expr.data.binary.right;
    if (identifierReferenceText(ast, rhs_idx)) |name| return name;
    if (rhs_idx.isNone() or @intFromEnum(rhs_idx) >= ast.nodes.items.len) return null;
    const rhs = ast.nodes.items[@intFromEnum(rhs_idx)];
    if (rhs.tag != .call_expression) return null;
    if (!ast.hasExtra(rhs.data.extra, 2)) return null;
    const callee_idx = ast.readExtraNode(rhs.data.extra, 0);
    if (!std.mem.eql(u8, identifierReferenceText(ast, callee_idx) orelse return null, "__toCommonJS")) return null;
    const args_start = ast.readExtra(rhs.data.extra, 1);
    const args_len = ast.readExtra(rhs.data.extra, 2);
    if (args_len != 1 or args_start + args_len > ast.extra_data.items.len) return null;
    const arg_idx: NodeIndex = @enumFromInt(ast.extra_data.items[args_start]);
    return identifierReferenceText(ast, arg_idx);
}

fn collectCjsExportObjectNames(
    allocator: std.mem.Allocator,
    ast: *const Ast,
    stmt_raw_indices: []const u32,
) !std.StringHashMapUnmanaged(void) {
    var names: std.StringHashMapUnmanaged(void) = .{};
    errdefer names.deinit(allocator);

    for (stmt_raw_indices) |raw_idx| {
        const idx: NodeIndex = @enumFromInt(raw_idx);
        if (idx.isNone() or @intFromEnum(idx) >= ast.nodes.items.len) continue;
        const stmt_node = ast.nodes.items[@intFromEnum(idx)];
        const name = cjsModuleExportsAssignedObjectName(ast, stmt_node) orelse continue;
        try names.put(allocator, name, {});
    }

    return names;
}

fn isCjsExportHelperTarget(
    ast: *const Ast,
    target_idx: NodeIndex,
    export_object_names: ?*const std.StringHashMapUnmanaged(void),
) bool {
    if (isCjsExportObjectExpr(ast, target_idx)) return true;
    const name = identifierReferenceText(ast, target_idx) orelse return false;
    const names = export_object_names orelse return false;
    return names.contains(name);
}

fn collectCjsExportHelperCandidates(
    allocator: std.mem.Allocator,
    ast: *const Ast,
    stmt_node: Node,
    export_object_names: ?*const std.StringHashMapUnmanaged(void),
) !?[]CjsExportCandidate {
    if (stmt_node.tag != .expression_statement) return null;
    const expr_idx = stmt_node.data.unary.operand;
    if (expr_idx.isNone() or @intFromEnum(expr_idx) >= ast.nodes.items.len) return null;
    const expr = ast.nodes.items[@intFromEnum(expr_idx)];
    if (expr.tag != .call_expression) return null;

    const e = expr.data.extra;
    if (!ast.hasExtra(e, 2)) return null;
    const callee_idx = ast.readExtraNode(e, 0);
    if (!std.mem.eql(u8, identifierReferenceText(ast, callee_idx) orelse return null, "__export")) return null;

    const args_start = ast.readExtra(e, 1);
    const args_len = ast.readExtra(e, 2);
    if (args_len != 2 or args_start + args_len > ast.extra_data.items.len) return null;

    const target_idx: NodeIndex = @enumFromInt(ast.extra_data.items[args_start]);
    const defs_idx: NodeIndex = @enumFromInt(ast.extra_data.items[args_start + 1]);
    if (!isCjsExportHelperTarget(ast, target_idx, export_object_names)) return null;
    if (defs_idx.isNone() or @intFromEnum(defs_idx) >= ast.nodes.items.len) return null;
    const defs = ast.nodes.items[@intFromEnum(defs_idx)];
    if (defs.tag != .object_expression) return null;

    const list = defs.data.list;
    if (list.start + list.len > ast.extra_data.items.len) return null;
    const indices = ast.extra_data.items[list.start .. list.start + list.len];
    if (indices.len == 0) return null;

    var out: std.ArrayListUnmanaged(CjsExportCandidate) = .empty;
    var success = false;
    defer if (!success) {
        for (out.items) |c| allocator.free(c.export_name);
        out.deinit(allocator);
    };
    var seen: std.StringHashMapUnmanaged(void) = .{};
    defer seen.deinit(allocator);

    for (indices) |raw_prop| {
        const prop_idx: NodeIndex = @enumFromInt(raw_prop);
        if (prop_idx.isNone() or @intFromEnum(prop_idx) >= ast.nodes.items.len) return null;
        const prop = ast.nodes.items[@intFromEnum(prop_idx)];
        if (prop.tag != .object_property) return null;

        const name = (try ast.staticKeyName(allocator, prop.data.binary.left)) orelse return null;
        var name_transferred = false;
        defer if (!name_transferred) allocator.free(name);

        if (std.mem.eql(u8, name, "__proto__")) return null;
        const entry = try seen.getOrPut(allocator, name);
        if (entry.found_existing) return null;

        const returned = zeroParamFunctionReturnIdentifier(ast, Ast.objectPropertyValue(prop)) orelse return null;
        try out.append(allocator, .{
            .export_name = name,
            .export_assignment_node = @intFromEnum(expr_idx),
            .property_node = @intFromEnum(prop_idx),
            .rhs_node = returned,
            .helper_node = callee_idx,
            .target_node = target_idx,
            .kind = .define_property_getter,
        });
        name_transferred = true;
    }

    const slice = try out.toOwnedSlice(allocator);
    success = true;
    return slice;
}

fn isSafeEsModuleDefinePropertyDescriptor(ast: *const Ast, descriptor_idx: NodeIndex) bool {
    if (descriptor_idx.isNone() or @intFromEnum(descriptor_idx) >= ast.nodes.items.len) return false;
    const descriptor = ast.nodes.items[@intFromEnum(descriptor_idx)];
    if (descriptor.tag != .object_expression) return false;

    const list = descriptor.data.list;
    if (list.start + list.len > ast.extra_data.items.len) return false;

    var seen: [4][]const u8 = undefined;
    var seen_len: usize = 0;
    var has_value_true = false;

    for (ast.extra_data.items[list.start .. list.start + list.len]) |raw_prop| {
        const prop_idx: NodeIndex = @enumFromInt(raw_prop);
        if (prop_idx.isNone() or @intFromEnum(prop_idx) >= ast.nodes.items.len) return false;
        const prop = ast.nodes.items[@intFromEnum(prop_idx)];
        if (prop.tag != .object_property) return false;

        const name = plainObjectKeyName(ast, prop.data.binary.left) orelse return false;
        if (seen_len >= seen.len) return false;
        for (seen[0..seen_len]) |prev| {
            if (std.mem.eql(u8, prev, name)) return false;
        }
        seen[seen_len] = name;
        seen_len += 1;

        const value = Ast.objectPropertyValue(prop);
        if (std.mem.eql(u8, name, "value")) {
            if (!isBooleanLiteral(ast, value, "true")) return false;
            has_value_true = true;
        } else if (std.mem.eql(u8, name, "enumerable") or
            std.mem.eql(u8, name, "configurable") or
            std.mem.eql(u8, name, "writable"))
        {
            if (!isBooleanLiteral(ast, value, "true") and !isBooleanLiteral(ast, value, "false")) return false;
        } else {
            return false;
        }
    }

    return has_value_true;
}

fn isSafeCjsEsModuleMarkerStmt(
    alloc: std.mem.Allocator,
    ast: *const Ast,
    stmt_node: Node,
    unresolved_globals: ?*const purity.GlobalRefSet,
) !bool {
    if (stmt_node.tag != .expression_statement) return false;
    const expr_idx = stmt_node.data.unary.operand;
    if (expr_idx.isNone() or @intFromEnum(expr_idx) >= ast.nodes.items.len) return false;
    const expr = ast.nodes.items[@intFromEnum(expr_idx)];
    if (expr.tag != .call_expression) return false;

    const e = expr.data.extra;
    if (!ast.hasExtra(e, 2)) return false;
    const callee_idx = ast.readExtraNode(e, 0);
    const args_start = ast.readExtra(e, 1);
    const args_len = ast.readExtra(e, 2);
    if (args_len != 3) return false;
    if (args_start + args_len > ast.extra_data.items.len) return false;
    if (!isGlobalObjectDefinePropertyCallee(ast, callee_idx, unresolved_globals)) return false;

    const target_idx: NodeIndex = @enumFromInt(ast.extra_data.items[args_start]);
    const export_name_idx: NodeIndex = @enumFromInt(ast.extra_data.items[args_start + 1]);
    const descriptor_idx: NodeIndex = @enumFromInt(ast.extra_data.items[args_start + 2]);
    if (!isCjsExportObjectExpr(ast, target_idx)) return false;

    const export_name = (try ast.staticKeyName(alloc, export_name_idx)) orelse return false;
    defer alloc.free(export_name);
    if (!std.mem.eql(u8, export_name, "__esModule")) return false;

    return isSafeEsModuleDefinePropertyDescriptor(ast, descriptor_idx);
}

/// lazy getter body 가 정확히 `{ return require(...) }` 또는 `{ return require(...).X }`
/// 패턴인지 — 외부 stmt 의 var 를 reference 하지 않음을 보장. RN core lazy getter
/// (#2683) 만 cover, 외부 var 의존 패턴 reject. body 가 외부 reference 갖는 경우
/// `module.exports = {...}` stmt 가 cjs_shape_extracted=true 로 마킹되면서
/// 외부 declaration stmt 가 BFS 에서 도달 못 해 strip 회귀하는 영역.
fn isLazyGetterBodyRequireOnly(ast: *const Ast, body_idx: NodeIndex) bool {
    if (body_idx.isNone() or @intFromEnum(body_idx) >= ast.nodes.items.len) return false;
    const body = ast.nodes.items[@intFromEnum(body_idx)];
    if (body.tag != .block_statement) return false;
    const list = body.data.list;
    if (list.len != 1) return false;
    if (list.start + 1 > ast.extra_data.items.len) return false;
    const stmt_idx: NodeIndex = @enumFromInt(ast.extra_data.items[list.start]);
    if (stmt_idx.isNone() or @intFromEnum(stmt_idx) >= ast.nodes.items.len) return false;
    const stmt = ast.nodes.items[@intFromEnum(stmt_idx)];
    if (stmt.tag != .return_statement) return false;
    const arg_idx = stmt.data.unary.operand;
    if (arg_idx.isNone() or @intFromEnum(arg_idx) >= ast.nodes.items.len) return false;
    const arg = ast.nodes.items[@intFromEnum(arg_idx)];
    // `require('./x')` 또는 `require('./x').default` (member access of require call) 만 허용.
    // static_member_expression layout: `extra: [object, property, flags]`.
    const call_idx: NodeIndex = switch (arg.tag) {
        .call_expression => arg_idx,
        .static_member_expression => blk: {
            const obj_idx = ast.readExtraNode(arg.data.extra, 0);
            if (obj_idx.isNone() or @intFromEnum(obj_idx) >= ast.nodes.items.len) return false;
            if (ast.nodes.items[@intFromEnum(obj_idx)].tag != .call_expression) return false;
            break :blk obj_idx;
        },
        else => return false,
    };
    const call = ast.nodes.items[@intFromEnum(call_idx)];
    // call_expression layout: `extra: [callee, args_start, args_len]`.
    const callee_idx: NodeIndex = @enumFromInt(ast.extra_data.items[call.data.extra]);
    if (callee_idx.isNone() or @intFromEnum(callee_idx) >= ast.nodes.items.len) return false;
    const callee = ast.nodes.items[@intFromEnum(callee_idx)];
    if (callee.tag != .identifier_reference) return false;
    return std.mem.eql(u8, ast.getText(callee.span), "require");
}

fn collectCjsObjectExportCandidates(
    allocator: std.mem.Allocator,
    ast: *const Ast,
    stmt_node: Node,
    unresolved_globals: ?*const purity.GlobalRefSet,
) !?[]CjsExportCandidate {
    if (stmt_node.tag != .expression_statement) return null;
    const expr_idx = stmt_node.data.unary.operand;
    if (expr_idx.isNone() or @intFromEnum(expr_idx) >= ast.nodes.items.len) return null;
    const expr = ast.nodes.items[@intFromEnum(expr_idx)];
    if (expr.tag != .assignment_expression) return null;
    if (!isModuleExportsLhs(ast, expr.data.binary.left)) return null;

    const rhs_idx = expr.data.binary.right;
    if (rhs_idx.isNone() or @intFromEnum(rhs_idx) >= ast.nodes.items.len) return null;
    const rhs = ast.nodes.items[@intFromEnum(rhs_idx)];
    if (rhs.tag != .object_expression) return null;

    const list = rhs.data.list;
    if (list.start + list.len > ast.extra_data.items.len) return null;
    const indices = ast.extra_data.items[list.start .. list.start + list.len];
    if (indices.len == 0) return null;

    var out: std.ArrayListUnmanaged(CjsExportCandidate) = .empty;
    var success = false;
    defer if (!success) {
        for (out.items) |c| allocator.free(c.export_name);
        out.deinit(allocator);
    };
    // `seen` 키는 `out.items[*].export_name` 을 빌려쓴다. 에러 경로에서
    // `out` 의 name 들이 해제되기 전에 `seen` 이 먼저 비워지도록 LIFO 순서를 맞춘다.
    var seen: std.StringHashMapUnmanaged(void) = .{};
    defer seen.deinit(allocator);

    for (indices) |raw_prop| {
        const prop_idx: NodeIndex = @enumFromInt(raw_prop);
        if (prop_idx.isNone() or @intFromEnum(prop_idx) >= ast.nodes.items.len) return null;
        const prop = ast.nodes.items[@intFromEnum(prop_idx)];

        // RN core `index.js` 의 lazy getter (`get DevSettings() { return require(...).default }`)
        // 인식 (#2683 PR β-1). plain getter + body 가 정확히 `{ return require(...).X? }`
        // 패턴만 — body 안 외부 var reference 가 있으면 cjs_shape_extracted=true 마킹이
        // 그 외부 stmt 를 reachable 못 따라가 strip 회귀 (#2685 hot fix).
        const is_lazy_getter = prop.tag == .method_definition and
            ast_mod.isPlainGetterFlags(ast.readExtra(prop.data.extra, ast_mod.MethodExtra.flags)) and
            isLazyGetterBodyRequireOnly(ast, ast.readExtraNode(prop.data.extra, ast_mod.MethodExtra.body));

        if (prop.tag != .object_property and !is_lazy_getter) return null;

        const key_idx: NodeIndex = if (is_lazy_getter)
            ast.readExtraNode(prop.data.extra, ast_mod.MethodExtra.key)
        else
            prop.data.binary.left;
        const name = (try ast.staticKeyName(allocator, key_idx)) orelse return null;
        var name_transferred = false;
        defer if (!name_transferred) allocator.free(name);

        // `{__proto__: X}` 는 prototype 을 설정 — named export 가 아니라 reject.
        if (std.mem.eql(u8, name, "__proto__")) return null;
        const entry = try seen.getOrPut(allocator, name);
        if (entry.found_existing) return null;

        // lazy getter 의 경우 method_definition node 자체를 seed 로 사용 — body 안 require 는
        // tree_shaker 가 record.span 과 property_node body span 매핑으로 별도 처리 (PR β-2).
        // 일반 object_property 는 기존대로 value 의 purity 검사.
        const seed_node = if (is_lazy_getter)
            prop_idx
        else
            cjsObjectPropertyValueSeedNode(ast, Ast.objectPropertyValue(prop), unresolved_globals) orelse return null;

        try out.append(allocator, .{
            .export_name = name,
            .export_assignment_node = @intFromEnum(expr_idx),
            .property_node = @intFromEnum(prop_idx),
            .rhs_node = seed_node,
            .kind = .object_property,
        });
        name_transferred = true;
    }

    const slice = try out.toOwnedSlice(allocator);
    success = true;
    return slice;
}

fn cjsExportAssignmentHasSideEffects(ast: *const Ast, candidate: CjsExportCandidate, unresolved_globals: ?*const purity.GlobalRefSet) bool {
    return !purity.isExprPure(ast, candidate.rhs_node, unresolved_globals);
}

/// `module.exports = { used, unused }` 형태에서 fact 들을 수집해 buf 에 append.
/// 두 builder (`buildFromSemantic`, `build`) 가 공유. symbol_ids 가 있으면 rhs_symbol 도 채움.
/// fact 가 1개 이상 추가됐으면 true (호출자가 stmt 의 has_side_effects=false 표시).
fn collectAndAppendCjsObjectFacts(
    allocator: std.mem.Allocator,
    ast: *const Ast,
    node: Node,
    stmt_i: u32,
    unresolved_globals: ?*const purity.GlobalRefSet,
    facts: *std.ArrayListUnmanaged(CjsExportFact),
    symbol_ids: ?[]const ?u32,
) !bool {
    const candidates = (try collectCjsObjectExportCandidates(allocator, ast, node, unresolved_globals)) orelse return false;
    defer allocator.free(candidates);

    // append 실패 시 미전이 분량의 owned name 을 cleanup. 성공 시 전체 transferred=len.
    var transferred: usize = 0;
    errdefer for (candidates[transferred..]) |c| allocator.free(c.export_name);

    try facts.ensureUnusedCapacity(allocator, candidates.len);
    for (candidates) |candidate| {
        facts.appendAssumeCapacity(.{
            .export_name = candidate.export_name,
            .statement_index = stmt_i,
            .export_assignment_node = candidate.export_assignment_node,
            .property_node = candidate.property_node,
            .rhs_symbol = rhsSymbolFor(symbol_ids, candidate.rhs_node),
            .helper_symbol = rhsSymbolFor(symbol_ids, candidate.helper_node),
            .target_symbol = rhsSymbolFor(symbol_ids, candidate.target_node),
            .kind = candidate.kind,
            .is_safe_to_prune = true,
        });
        transferred += 1;
    }
    return true;
}

fn appendCjsDefinePropertyFact(
    allocator: std.mem.Allocator,
    ast: *const Ast,
    node: Node,
    stmt_i: u32,
    unresolved_globals: ?*const purity.GlobalRefSet,
    facts: *std.ArrayListUnmanaged(CjsExportFact),
    symbol_ids: ?[]const ?u32,
) !bool {
    const candidate = (try cjsDefinePropertyExportCandidateForStmt(allocator, ast, node, unresolved_globals)) orelse return false;
    var transferred = false;
    errdefer if (!transferred) allocator.free(candidate.export_name);

    try facts.append(allocator, .{
        .export_name = candidate.export_name,
        .statement_index = stmt_i,
        .export_assignment_node = candidate.export_assignment_node,
        .property_node = candidate.property_node,
        .rhs_symbol = rhsSymbolFor(symbol_ids, candidate.rhs_node),
        .helper_symbol = rhsSymbolFor(symbol_ids, candidate.helper_node),
        .target_symbol = rhsSymbolFor(symbol_ids, candidate.target_node),
        .kind = candidate.kind,
        .is_safe_to_prune = true,
    });
    transferred = true;
    return true;
}

fn appendCjsExportHelperFacts(
    allocator: std.mem.Allocator,
    ast: *const Ast,
    node: Node,
    stmt_i: u32,
    export_object_names: ?*const std.StringHashMapUnmanaged(void),
    facts: *std.ArrayListUnmanaged(CjsExportFact),
    symbol_ids: ?[]const ?u32,
) !bool {
    const candidates = (try collectCjsExportHelperCandidates(allocator, ast, node, export_object_names)) orelse return false;
    defer allocator.free(candidates);

    var transferred: usize = 0;
    errdefer for (candidates[transferred..]) |c| allocator.free(c.export_name);

    try facts.ensureUnusedCapacity(allocator, candidates.len);
    for (candidates) |candidate| {
        facts.appendAssumeCapacity(.{
            .export_name = candidate.export_name,
            .statement_index = stmt_i,
            .export_assignment_node = candidate.export_assignment_node,
            .property_node = candidate.property_node,
            .rhs_symbol = rhsSymbolFor(symbol_ids, candidate.rhs_node),
            .helper_symbol = rhsSymbolFor(symbol_ids, candidate.helper_node),
            .target_symbol = rhsSymbolFor(symbol_ids, candidate.target_node),
            .kind = candidate.kind,
            .is_safe_to_prune = true,
        });
        transferred += 1;
    }
    return true;
}

fn invalidateConflictingCjsExportFacts(facts: []CjsExportFact, stmts: []StmtInfo) void {
    for (facts, 0..) |fact, i| {
        if (!fact.is_safe_to_prune) continue;
        var has_conflict = false;
        for (facts[i + 1 ..]) |*other| {
            if (!other.is_safe_to_prune) continue;
            if (!std.mem.eql(u8, fact.export_name, other.export_name)) continue;
            other.is_safe_to_prune = false;
            if (other.statement_index < stmts.len) {
                stmts[other.statement_index].has_side_effects = true;
            }
            has_conflict = true;
        }
        if (has_conflict) {
            facts[i].is_safe_to_prune = false;
            if (fact.statement_index < stmts.len) {
                stmts[fact.statement_index].has_side_effects = true;
            }
        }
    }
}

/// CJS module 의 함수 body 안에서 `exports` 식별자가 동적으로 access 되면
/// (예: `function init() { exports.X.push(...) }`), RHS purity 만으로는 export prune 안전성을
/// 증명할 수 없다. mime-types 패턴 — top-level `exports.X = []` 가 RHS pure 라 prune
/// 후보지만, 다른 함수 호출 시점에 `exports.X.push(...)` 로 mutate 됨.
///
/// 휴리스틱: 함수/메서드 노드 span 안에서 `exports` identifier 가 한 번이라도 발견되면
/// 모든 fact invalidate (esbuild/rolldown 의 CJS black-box 정책). top-level 의 `exports.X = ...`
/// 나 `Object.defineProperty(exports, ...)` 같은 패턴은 함수 밖이라 영향 없음.
///
/// `unresolved_globals` 가 `exports` 를 포함 안 하면 ESM 모듈이거나 user 가 `var exports = ...`
/// 한 케이스라 작업 자체가 의미 없어 즉시 종료. 함수 이름 식별자는 `binding_identifier` 라
/// 여기 outer loop 의 `identifier_reference` 검사를 거치지 않으므로 false-positive 안 일어남.
fn invalidateFactsForNestedExportsAccess(
    allocator: std.mem.Allocator,
    ast: *const Ast,
    facts: []CjsExportFact,
    stmts: []StmtInfo,
    unresolved_globals: ?*const purity.GlobalRefSet,
) void {
    if (facts.len == 0) return;
    if (unresolved_globals) |g| {
        if (!g.contains("exports")) return;
    }

    var fn_spans: std.ArrayListUnmanaged(Span) = .empty;
    defer fn_spans.deinit(allocator);
    for (ast.nodes.items) |node| {
        switch (node.tag) {
            .function_declaration,
            .function_expression,
            .arrow_function_expression,
            .function,
            .method_definition,
            => fn_spans.append(allocator, node.span) catch return,
            else => continue,
        }
    }
    if (fn_spans.items.len == 0) return;

    var has_nested = false;
    outer: for (ast.nodes.items) |node| {
        if (node.tag != .identifier_reference) continue;
        if (node.span.end - node.span.start != "exports".len) continue;
        if (!std.mem.eql(u8, ast.getText(node.span), "exports")) continue;
        for (fn_spans.items) |fs| {
            if (node.span.start >= fs.start and node.span.end <= fs.end and
                (node.span.start != fs.start or node.span.end != fs.end))
            {
                has_nested = true;
                break :outer;
            }
        }
    }

    if (!has_nested) return;
    for (facts) |*f| {
        if (!f.is_safe_to_prune) continue;
        f.is_safe_to_prune = false;
        if (f.statement_index < stmts.len) {
            stmts[f.statement_index].has_side_effects = true;
        }
    }
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

/// `ModuleStmtInfos.stmts` 의 span 으로부터 pos 를 포함하는 stmt index 를 binary search.
/// `findStmtForPos` 와 동일 알고리즘이지만 SOA span 슬라이스가 별도로 존재하지 않는 호출부용.
pub fn findStmtIndexFromInfos(infos: ModuleStmtInfos, pos: u32) ?u32 {
    if (infos.stmts.len == 0) return null;
    var lo: u32 = 0;
    var hi: u32 = @intCast(infos.stmts.len);
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const span = infos.stmts[mid].span;
        if (pos >= span.end) {
            lo = mid + 1;
        } else if (pos < span.start) {
            hi = mid;
        } else {
            return mid;
        }
    }
    return null;
}

const ReverseIndex = struct {
    sym_to_referencing_stmts: []const []const u32,
    sym_to_side_effect_stmts: []const []const u32,
};

/// symbol → referencing/side-effect stmt indices 역인덱스를 구축한다.
/// build()와 buildFromSemantic() 공통으로 사용.
fn buildReverseIndex(allocator: std.mem.Allocator, stmts: []const StmtInfo, sym_count: usize) !ReverseIndex {
    // 카운트 패스
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

    // 할당
    var sym_to_ref_stmts = try allocator.alloc([]const u32, sym_count);
    errdefer allocator.free(sym_to_ref_stmts);
    var sym_to_se_stmts = try allocator.alloc([]const u32, sym_count);
    errdefer allocator.free(sym_to_se_stmts);

    var ref_bufs = try allocator.alloc([]u32, sym_count);
    defer allocator.free(ref_bufs);
    var se_bufs = try allocator.alloc([]u32, sym_count);
    defer allocator.free(se_bufs);

    for (0..sym_count) |sym| {
        ref_bufs[sym] = if (ref_counts[sym] > 0) try allocator.alloc(u32, ref_counts[sym]) else &.{};
        se_bufs[sym] = if (se_counts[sym] > 0) try allocator.alloc(u32, se_counts[sym]) else &.{};
    }

    // 기록 패스 (카운터 재활용)
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

    for (0..sym_count) |sym| {
        sym_to_ref_stmts[sym] = ref_bufs[sym];
        sym_to_se_stmts[sym] = se_bufs[sym];
    }

    return .{
        .sym_to_referencing_stmts = sym_to_ref_stmts,
        .sym_to_side_effect_stmts = sym_to_se_stmts,
    };
}

/// bucket 을 in-place sort + dedupe 하고, `exclude_sorted` (정렬된 제외 심볼 목록) 와
/// two-pointer merge 로 교집합을 제거한 slice 를 반환. 결과가 비면 null.
/// buildFromSemantic Pass 3a/3b 공통 경로. declared 이미 정렬돼 있어 O(N+M).
fn finalizeBucket(
    allocator: std.mem.Allocator,
    bucket: *std.ArrayListUnmanaged(u32),
    exclude_sorted: []const u32,
) !?[]const u32 {
    if (bucket.items.len == 0) return null;
    std.mem.sort(u32, bucket.items, {}, std.sort.asc(u32));

    var out_len: usize = 0;
    var last: ?u32 = null;
    var j: usize = 0;
    for (bucket.items) |sym| {
        if (last != null and last.? == sym) continue;
        last = sym;
        while (j < exclude_sorted.len and exclude_sorted[j] < sym) : (j += 1) {}
        if (j < exclude_sorted.len and exclude_sorted[j] == sym) continue;
        bucket.items[out_len] = sym;
        out_len += 1;
    }
    if (out_len == 0) return null;
    return try allocator.dupe(u32, bucket.items[0..out_len]);
}

/// 멤버-증강 귀속 (gated, #1577 semantic-preserving).
///
/// side-effects-free 로 user 가 선언한(`sideEffects:false`) 모듈에서 다음 형태의
/// top-level 문장:
///
///     X.member = pureRHS;            // X = 이 모듈의 top-level 로컬 바인딩
///
/// 을 ESM 의미상 무조건적 부작용으로 시드하지 않고 "심볼 X 의 augmentation" 으로
/// 귀속한다 (X 가 live 면 reachable, X 가 dead 면 stmt + cascade 제거).
///
/// 매칭 시 base object 의 심볼 인덱스 X 를 반환. 호출자는
///   (1) 해당 stmt 의 has_side_effects 를 false 로 두고
///   (2) stmt 를 X 의 writer bucket 에 추가 (X live ⇒ stmt reachable 의 X→stmt 방향)
/// 한다.
///
/// 엄격 게이트 (모두 만족 시에만 반환):
///   - 호출자 게이트: module.side_effects == false && side_effects_user_defined == true
///     (`gate` 파라미터로 전달).
///   - stmt = expression_statement → assignment_expression (`=` 단순 대입).
///   - LHS = static_member_expression, base object = 단일 identifier_reference.
///   - base 가 이 모듈 top-level (scope_id == 0) 비-import 로컬 심볼 X.
///   - RHS 가 purity.isExprPure (PURE 주석 존중).
///   - 예외: Reanimated/Babel worklet metadata (`X.__workletHash`,
///     `X.__closure` 등)는 synthetic 함수 부속 데이터라 RHS 가 class static read 를
///     포함해 일반 purity 를 통과하지 못해도 X 의 augmentation 으로 귀속한다.
/// 구조적 매칭만 수행 (심볼 해석 제외) — 매칭 시 base object 의 identifier
/// NodeIndex 를 반환. 호출자가 symbol_ids (build) 또는 references
/// (buildFromSemantic) 로 심볼을 해석하고 scope_id==0 + 비-import 를 검증한다.
fn gatedMemberAugmentObjectNode(
    ast: *const Ast,
    stmt_node: Node,
    unresolved_globals: ?*const purity.GlobalRefSet,
) ?NodeIndex {
    const m = memberAssignTargetParts(ast, stmt_node) orelse return null;
    const obj = ast.nodes.items[@intFromEnum(m.base)];

    // base 가 unresolved global (`window.x = ...`) 이면 글로벌 변이 — 제외.
    if (unresolved_globals) |globals| {
        if (globals.contains(ast.getText(obj.span))) return null;
    }

    const prop = ast.nodes.items[@intFromEnum(m.property)];
    if (prop.tag == .identifier_reference and isWorkletMetadataProperty(ast.getText(prop.span))) {
        return m.base;
    }

    // RHS 순수성 (three 의 mergeUniforms 는 /*@__PURE__*/ 주석으로 pure 판정).
    if (!purity.isExprPure(ast, m.rhs, unresolved_globals)) return null;

    return m.base;
}

/// base identifier 심볼 X 가 이 모듈 top-level (scope_id==0) 비-import 로컬인지
/// 검증해 X 의 심볼 인덱스를 반환. 아니면 null.
fn validateMemberAugmentBaseSymbol(symbols: []const Symbol, x_sym: u32) ?u32 {
    if (x_sym >= symbols.len) return null;
    const sym = &symbols[x_sym];
    if (@intFromEnum(sym.scope_id) != 0) return null;
    if (sym.decl_flags.is_import) return null;
    return x_sym;
}

fn findUniqueTopLevelLocalSymbolByName(ast: *const Ast, symbols: []const Symbol, name: []const u8) ?u32 {
    var found: ?u32 = null;
    for (symbols, 0..) |*sym, sym_idx| {
        if (@intFromEnum(sym.scope_id) != 0) continue;
        if (sym.decl_flags.is_import) continue;
        if (!std.mem.eql(u8, sym.nameText(ast.source), name)) continue;
        if (found != null) return null;
        found = @intCast(sym_idx);
    }
    return found;
}

fn memberAugmentSymbolFromObjectNode(
    ast: *const Ast,
    obj_node: NodeIndex,
    symbol_ids: []const ?u32,
    symbols: []const Symbol,
) ?u32 {
    const obj_node_i = @intFromEnum(obj_node);
    if (obj_node_i < symbol_ids.len) {
        if (symbol_ids[obj_node_i]) |x_sym| {
            return validateMemberAugmentBaseSymbol(symbols, x_sym);
        }
    }
    if (obj_node_i >= ast.nodes.items.len) return null;
    const obj = ast.nodes.items[obj_node_i];
    if (obj.tag != .identifier_reference) return null;
    return findUniqueTopLevelLocalSymbolByName(ast, symbols, ast.getText(obj.span));
}

/// `build` (symbol_ids 보유) 경로용 thin wrapper.
fn gatedMemberAugmentSymbol(
    ast: *const Ast,
    stmt_node: Node,
    symbol_ids: []const ?u32,
    symbols: []const Symbol,
    unresolved_globals: ?*const purity.GlobalRefSet,
) ?u32 {
    const obj_node = gatedMemberAugmentObjectNode(ast, stmt_node, unresolved_globals) orelse return null;
    return memberAugmentSymbolFromObjectNode(ast, obj_node, symbol_ids, symbols);
}

fn workletMetadataSymbol(
    ast: *const Ast,
    stmt_node: Node,
    symbol_ids: []const ?u32,
    symbols: []const Symbol,
    unresolved_globals: ?*const purity.GlobalRefSet,
) ?u32 {
    const obj_node = workletMetadataObjectNode(ast, stmt_node, unresolved_globals) orelse return null;
    return memberAugmentSymbolFromObjectNode(ast, obj_node, symbol_ids, symbols);
}

/// 두 builder (buildFromSemantic / build) 의 per-stmt Phase 1 본체.
/// stmt 노드에서 cjs_export_facts 를 추가하고 side_effects 를 결정해 StmtInfo
/// 슬롯을 만든다. `symbol_ids` 가 있으면 rhs_symbol 도 채움 (build), null 이면
/// 비워둠 (buildFromSemantic). symbol bucket 채우기는 caller 가 처리.
fn buildStmtInfoSlot(
    allocator: std.mem.Allocator,
    ast: *const Ast,
    ni: u32,
    stmt_i: u32,
    collect_cjs_exports: bool,
    unresolved_globals: ?*const purity.GlobalRefSet,
    cjs_export_object_names: ?*const std.StringHashMapUnmanaged(void),
    cjs_export_facts_buf: *std.ArrayListUnmanaged(CjsExportFact),
    symbol_ids: ?[]const ?u32,
) !StmtInfo {
    if (ni >= ast.nodes.items.len) {
        return .{
            .node_idx = ni,
            .span = .{ .start = 0, .end = 0 },
            .has_side_effects = true,
            .declared_symbols = &.{},
            .referenced_symbols = &.{},
        };
    }
    const node = ast.nodes.items[ni];
    const cjs_export_candidate = if (collect_cjs_exports)
        try cjsExportCandidateForStmt(allocator, ast, node)
    else
        null;
    var candidate_transferred = false;
    errdefer if (cjs_export_candidate) |c| if (!candidate_transferred)
        allocator.free(c.export_name);

    var cjs_shape_extracted = false;
    if (cjs_export_candidate) |candidate| {
        try cjs_export_facts_buf.append(allocator, .{
            .export_name = candidate.export_name,
            .statement_index = stmt_i,
            .export_assignment_node = candidate.export_assignment_node,
            .property_node = candidate.property_node,
            .rhs_symbol = rhsSymbolFor(symbol_ids, candidate.rhs_node),
            .helper_symbol = rhsSymbolFor(symbol_ids, candidate.helper_node),
            .target_symbol = rhsSymbolFor(symbol_ids, candidate.target_node),
            .kind = candidate.kind,
            .is_safe_to_prune = !cjsExportAssignmentHasSideEffects(ast, candidate, unresolved_globals),
        });
        candidate_transferred = true;
    } else if (collect_cjs_exports) {
        cjs_shape_extracted =
            try appendCjsDefinePropertyFact(allocator, ast, node, stmt_i, unresolved_globals, cjs_export_facts_buf, symbol_ids) or
            try appendCjsExportHelperFacts(allocator, ast, node, stmt_i, cjs_export_object_names, cjs_export_facts_buf, symbol_ids) or
            try isSafeCjsEsModuleMarkerStmt(allocator, ast, node, unresolved_globals) or
            try collectAndAppendCjsObjectFacts(allocator, ast, node, stmt_i, unresolved_globals, cjs_export_facts_buf, symbol_ids);
    }
    const side_effects = if (node.tag == .import_declaration)
        false
    else if (cjs_export_candidate) |candidate|
        cjsExportAssignmentHasSideEffects(ast, candidate, unresolved_globals)
    else if (cjs_shape_extracted)
        false
    else
        purity.stmtHasSideEffects(ast, node, unresolved_globals);
    return .{
        .node_idx = ni,
        .span = node.span,
        .has_side_effects = side_effects,
        .declared_symbols = &.{},
        .referenced_symbols = &.{},
    };
}

fn scopeIsFunctionOrClassBody(sc: Scope) bool {
    return sc.kind == .function or sc.kind == .class_body;
}

/// Semantic Analyzer 의 `references` 배열로부터 ModuleStmtInfos 를 구축한다.
/// declare/read/write 플래그로 stmt 단위 선언·참조 bucket 을 분배 (analyzer 는 중간 캐시를 유지하지 않음).
pub fn buildFromSemantic(
    allocator: std.mem.Allocator,
    ast: *const Ast,
    symbols: []const Symbol,
    scopes: []const Scope,
    references: []const Reference,
    unresolved_globals: ?*const purity.GlobalRefSet,
    collect_cjs_exports: bool,
    /// member-augment 귀속 게이트. `build` 의 동명 파라미터와 동일 의미 —
    /// 호출자가 Module.memberAugmentGate() 로 판정해 전달. ESM 프리빌드
    /// 경로(transform_prepass)가 이 함수를 쓰므로 실제 효과는 여기서 발생한다.
    gate_member_augment: bool,
) !?ModuleStmtInfos {
    // program 노드 (마지막 노드)에서 top-level statement 인덱스 추출
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

    var sym_to_stmt = try allocator.alloc(?u32, symbols.len);
    errdefer allocator.free(sym_to_stmt);
    for (sym_to_stmt) |*s| s.* = null;

    var cjs_export_facts_buf: std.ArrayListUnmanaged(CjsExportFact) = .empty;
    errdefer deinitCjsExportFactsBuf(allocator, &cjs_export_facts_buf);
    var cjs_export_object_names = if (collect_cjs_exports)
        try collectCjsExportObjectNames(allocator, ast, stmt_raw_indices)
    else
        std.StringHashMapUnmanaged(void){};
    defer cjs_export_object_names.deinit(allocator);

    // 게이트 통과한 member-augment 문장: object identifier NodeIndex → stmt_idx.
    // references 패스에서 이 노드의 symbol_id 를 해석해 writer bucket 에 귀속.
    var member_augment_obj_to_stmt: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer member_augment_obj_to_stmt.deinit(allocator);

    // Pass 1: span + side-effect 결정. declared/referenced 는 빈 상태로 초기화.
    for (stmt_raw_indices, 0..) |raw_idx, stmt_i| {
        const idx: NodeIndex = @enumFromInt(raw_idx);
        const ni = @intFromEnum(idx);
        stmts[stmt_i] = try buildStmtInfoSlot(
            allocator,
            ast,
            @intCast(ni),
            @intCast(stmt_i),
            collect_cjs_exports,
            unresolved_globals,
            if (collect_cjs_exports) &cjs_export_object_names else null,
            &cjs_export_facts_buf,
            null,
        );

        if (stmts[stmt_i].has_side_effects and ni < ast.nodes.items.len) {
            const stmt_node = ast.nodes.items[ni];
            const augment_obj_node =
                workletMetadataObjectNode(ast, stmt_node, unresolved_globals) orelse
                if (gate_member_augment)
                    gatedMemberAugmentObjectNode(ast, stmt_node, unresolved_globals)
                else
                    null;

            if (augment_obj_node) |obj_node| {
                // has_side_effects 해제는 base 가 top-level 로컬임을 references
                // 패스에서 확정한 뒤에 한다 (조건부). 우선 후보로만 등록.
                try member_augment_obj_to_stmt.put(allocator, @intFromEnum(obj_node), @intCast(stmt_i));
            }
        }
    }

    // Pass 2: references → declared/referenced per-stmt bucket 분배.
    var declared_buckets = try allocator.alloc(std.ArrayListUnmanaged(u32), stmt_count);
    defer {
        for (declared_buckets) |*b| b.deinit(allocator);
        allocator.free(declared_buckets);
    }
    for (declared_buckets) |*b| b.* = .empty;

    var referenced_buckets = try allocator.alloc(std.ArrayListUnmanaged(u32), stmt_count);
    defer {
        for (referenced_buckets) |*b| b.deinit(allocator);
        allocator.free(referenced_buckets);
    }
    for (referenced_buckets) |*b| b.* = .empty;

    // symbol → [stmts that write to it without declaring it]. computeReachable 가 read 가
    // 살아 있을 때 writer stmt 도 enqueue 하기 위한 역인덱스. 같은 stmt 가 declare+write 인
    // 경우는 Pass 3a 이후 finalize 단계에서 declared 를 exclude 해 제거한다.
    var writer_buckets = try allocator.alloc(std.ArrayListUnmanaged(u32), symbols.len);
    defer {
        for (writer_buckets) |*b| b.deinit(allocator);
        allocator.free(writer_buckets);
    }
    for (writer_buckets) |*b| b.* = .empty;

    for (references) |r| {
        if (r.stmt_idx == Reference.NO_STMT) continue;
        if (r.stmt_idx >= stmt_count) continue;
        const sym_u32: u32 = @intFromEnum(r.symbol_id);
        if (sym_u32 >= symbols.len) continue;

        // member-augment 귀속: 이 ref 가 게이트 통과 stmt 의 base object
        // identifier 면 X = sym_u32 가 top-level 로컬인지 확정. 맞으면
        // stmt 의 has_side_effects 를 해제하고 X 의 writer bucket 에 등록한다.
        if (member_augment_obj_to_stmt.fetchRemove(@intFromEnum(r.node_index))) |kv| {
            const aug_stmt = kv.value;
            if (validateMemberAugmentBaseSymbol(symbols, sym_u32)) |x_sym| {
                stmts[aug_stmt].has_side_effects = false;
                try writer_buckets[x_sym].append(allocator, aug_stmt);
            }
        }

        if (r.flags.declare) {
            // #1669: analyzer 가 모든 scope 선언에 declare ref 를 남기므로 top-level (scope_id==0)
            // 만 bucket 분배. 함수/블록 내부 declare ref 는 `scope_stmt_idx` 와 함께 references
            // 배열에 남아 optimizer pass (single-use inline 등) 가 직접 소비.
            if (@intFromEnum(r.scope_id) != 0) continue;
            try declared_buckets[r.stmt_idx].append(allocator, sym_u32);
        } else {
            try referenced_buckets[r.stmt_idx].append(allocator, sym_u32);
            // 함수/클래스 body 안의 write 는 함수가 호출될 때만 실행되므로 call graph
            // (referenced_symbols → declarer 엣지) 가 처리. 여기서 writer 엣지를 만들면
            // enclosing 함수 declaration 이 false-positive 로 live 가 되어 dead 함수 body 의
            // transitive import 까지 cascade 보존됨.
            if (r.flags.write and !scope_mod.anyAncestor(scopes, r.scope_id, scopeIsFunctionOrClassBody)) {
                try writer_buckets[sym_u32].append(allocator, r.stmt_idx);
            }
        }
    }

    // Transformer/plugin generated nodes can be appended after the first semantic
    // pass. A later resync normally records references for them, but generated
    // string-table identifiers are still allowed to miss the reference pass in
    // older plugin paths. Resolve remaining member-augment candidates by name,
    // but only when the name maps to one unique top-level local binding.
    var remaining_augment_it = member_augment_obj_to_stmt.iterator();
    while (remaining_augment_it.next()) |entry| {
        const obj_idx: NodeIndex = @enumFromInt(entry.key_ptr.*);
        if (@intFromEnum(obj_idx) >= ast.nodes.items.len) continue;
        const obj = ast.nodes.items[@intFromEnum(obj_idx)];
        if (obj.tag != .identifier_reference) continue;
        const x_sym = findUniqueTopLevelLocalSymbolByName(ast, symbols, ast.getText(obj.span)) orelse continue;
        const aug_stmt = entry.value_ptr.*;
        stmts[aug_stmt].has_side_effects = false;
        try writer_buckets[x_sym].append(allocator, aug_stmt);
    }

    // Pass 3a: declared bucket → sort + dedupe → stmts[i].declared_symbols + sym_to_stmt 역매핑.
    for (0..stmt_count) |stmt_i| {
        const bucket = &declared_buckets[stmt_i];
        const declared_slice = (try finalizeBucket(allocator, bucket, &[_]u32{})) orelse continue;
        stmts[stmt_i].declared_symbols = declared_slice;
        for (declared_slice) |sym_idx| {
            if (sym_idx < sym_to_stmt.len) {
                sym_to_stmt[sym_idx] = @intCast(stmt_i);
            }
        }
    }

    // Pass 3b: referenced bucket → sort + dedupe + (같은 stmt 의 declared 제외) → stmts[i].referenced_symbols.
    for (0..stmt_count) |stmt_i| {
        const bucket = &referenced_buckets[stmt_i];
        const slice = (try finalizeBucket(allocator, bucket, stmts[stmt_i].declared_symbols)) orelse continue;
        stmts[stmt_i].referenced_symbols = slice;
    }

    invalidateConflictingCjsExportFacts(cjs_export_facts_buf.items, stmts);
    invalidateFactsForNestedExportsAccess(allocator, ast, cjs_export_facts_buf.items, stmts, unresolved_globals);

    const sym_to_writer_stmts = try finalizeWriterBuckets(allocator, writer_buckets, sym_to_stmt);

    // 역인덱스 구축 (buildReverseIndex 재사용)
    const reverse = try buildReverseIndex(allocator, stmts, symbols.len);

    const cjs_export_facts = try cjs_export_facts_buf.toOwnedSlice(allocator);

    return .{
        .stmts = stmts,
        .cjs_export_facts = cjs_export_facts,
        .symbol_to_stmt = sym_to_stmt,
        .sym_to_side_effect_stmts = reverse.sym_to_side_effect_stmts,
        .sym_to_referencing_stmts = reverse.sym_to_referencing_stmts,
        .sym_to_writer_stmts = sym_to_writer_stmts,
        .allocator = allocator,
    };
}

/// writer_buckets 를 stmts[].declared_symbols 의 declarer 와 중복 제거하여 final slice 로
/// 변환한다. 같은 stmt 가 declare 한 심볼은 별도 경로(`symbol_to_stmt`)로 처리되므로 writer
/// 엣지에서 제외해야 BFS 가 중복 enqueue 하지 않는다.
fn finalizeWriterBuckets(
    allocator: std.mem.Allocator,
    writer_buckets: []std.ArrayListUnmanaged(u32),
    sym_to_stmt: []const ?u32,
) ![]const []const u32 {
    const result = try allocator.alloc([]const u32, writer_buckets.len);
    errdefer allocator.free(result);
    for (result) |*r| r.* = &.{};

    for (writer_buckets, 0..) |*bucket, sym| {
        if (bucket.items.len == 0) continue;
        std.mem.sort(u32, bucket.items, {}, std.sort.asc(u32));
        const declarer: ?u32 = if (sym < sym_to_stmt.len) sym_to_stmt[sym] else null;
        var out_len: usize = 0;
        var last: ?u32 = null;
        for (bucket.items) |stmt_idx| {
            if (declarer) |d| if (d == stmt_idx) continue;
            if (last != null and last.? == stmt_idx) continue;
            last = stmt_idx;
            bucket.items[out_len] = stmt_idx;
            out_len += 1;
        }
        if (out_len > 0) {
            result[sym] = try allocator.dupe(u32, bucket.items[0..out_len]);
        }
    }
    return result;
}

/// AST + semantic data로부터 ModuleStmtInfos를 구축한다.
pub fn build(
    allocator: std.mem.Allocator,
    ast: *const Ast,
    symbols: []const Symbol,
    symbol_ids: []const ?u32,
    unresolved_globals: ?*const purity.GlobalRefSet,
    collect_cjs_exports: bool,
    /// member-augment 귀속 게이트. 호출자가 Module.memberAugmentGate()
    /// (side_effects==false && side_effects_user_defined==true && minify_syntax)
    /// 로 판정해 전달. true 이면 top-level `X.member = pureRHS`
    /// (X = 이 모듈 top-level 로컬) 를 무조건 side-effect 시드 대신
    /// X 의 augmentation 으로 귀속한다.
    gate_member_augment: bool,
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

    var cjs_export_facts_buf: std.ArrayListUnmanaged(CjsExportFact) = .empty;
    errdefer deinitCjsExportFactsBuf(allocator, &cjs_export_facts_buf);
    var cjs_export_object_names = if (collect_cjs_exports)
        try collectCjsExportObjectNames(allocator, ast, stmt_raw_indices)
    else
        std.StringHashMapUnmanaged(void){};
    defer cjs_export_object_names.deinit(allocator);

    // Phase 1: statement span 배열 + side-effects 판정 + 초기화
    var stmt_spans = try allocator.alloc(Span, stmt_count);
    defer allocator.free(stmt_spans);

    // 게이트 통과한 member-augment 문장 → 귀속 대상 심볼 X. Phase 2 의
    // writer_bufs 채우기 직전에 X 의 writer bucket 에 추가한다 (X live ⇒
    // stmt reachable, X dead ⇒ stmt + cascade drop). (stmt_i, x_sym) 쌍.
    var member_augment_pairs: std.ArrayListUnmanaged([2]u32) = .empty;
    defer member_augment_pairs.deinit(allocator);

    for (stmt_raw_indices, 0..) |raw_idx, stmt_i| {
        const idx: NodeIndex = @enumFromInt(raw_idx);
        const ni = @intFromEnum(idx);
        stmts[stmt_i] = try buildStmtInfoSlot(
            allocator,
            ast,
            @intCast(ni),
            @intCast(stmt_i),
            collect_cjs_exports,
            unresolved_globals,
            if (collect_cjs_exports) &cjs_export_object_names else null,
            &cjs_export_facts_buf,
            symbol_ids,
        );
        stmt_spans[stmt_i] = stmts[stmt_i].span;

        // member-augment 귀속: 게이트 ON + has_side_effects 로 분류된
        // top-level `X.member = pureRHS` 만 대상. CJS export fact 로 이미
        // 안전 처리된 stmt (has_side_effects=false) 는 건드리지 않는다.
        if (stmts[stmt_i].has_side_effects and ni < ast.nodes.items.len) {
            const stmt_node = ast.nodes.items[ni];
            const x_sym =
                workletMetadataSymbol(ast, stmt_node, symbol_ids, symbols, unresolved_globals) orelse
                if (gate_member_augment)
                    gatedMemberAugmentSymbol(ast, stmt_node, symbol_ids, symbols, unresolved_globals)
                else
                    null;

            if (x_sym) |sym| {
                stmts[stmt_i].has_side_effects = false;
                try member_augment_pairs.append(allocator, .{ @intCast(stmt_i), sym });
            }
        }
    }

    // Phase 2: 모든 AST 노드를 단일 패스로 순회하며 심볼 수집 — O(N log S)
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

    // symbol → [stmt indices that contain `assignment_target_identifier` for that symbol].
    // 선언과 같은 stmt 인 경우는 finalize 단계에서 제거.
    var writer_bufs = try allocator.alloc(std.ArrayListUnmanaged(u32), symbols.len);
    defer {
        for (writer_bufs) |*b| b.deinit(allocator);
        allocator.free(writer_bufs);
    }
    for (writer_bufs) |*b| b.* = .empty;

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
            if (std.mem.indexOfScalar(u32, declared_bufs[stmt_i].items, sym_idx_u32) == null) {
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
        if (is_ref and std.mem.indexOfScalar(u32, declared_bufs[stmt_i].items, sym_idx_u32) == null) {
            if (std.mem.indexOfScalar(u32, referenced_bufs[stmt_i].items, sym_idx_u32) == null) {
                try referenced_bufs[stmt_i].append(allocator, sym_idx_u32);
            }
        }

        if (n.tag == .assignment_target_identifier) {
            const stmt_i_u32: u32 = @intCast(stmt_i);
            if (std.mem.indexOfScalar(u32, writer_bufs[sym_idx].items, stmt_i_u32) == null) {
                try writer_bufs[sym_idx].append(allocator, stmt_i_u32);
            }
        }
    }

    for (stmts, 0..) |*stmt, stmt_i| {
        if (declared_bufs[stmt_i].items.len > 0) {
            stmt.declared_symbols = try declared_bufs[stmt_i].toOwnedSlice(allocator);
        }
        if (referenced_bufs[stmt_i].items.len > 0) {
            stmt.referenced_symbols = try referenced_bufs[stmt_i].toOwnedSlice(allocator);
        }
    }

    // member-augment 귀속: 게이트 통과한 `X.member = pureRHS` 를 X 의 writer
    // bucket 에 등록 → tree_shaker 가 X 가 live 가 되면 enqueueSymbolLiveStatements
    // / referenced_symbols→writerStmts 경로로 이 stmt 를 reachable 시킨다.
    // X 가 끝까지 dead 면 stmt 는 has_side_effects=false 라 seed 되지 않고
    // RHS cascade (three 의 ShaderChunk/GLSL) 까지 함께 제거된다.
    for (member_augment_pairs.items) |pair| {
        const stmt_i_u32 = pair[0];
        const x_sym = pair[1];
        if (x_sym >= writer_bufs.len) continue;
        if (std.mem.indexOfScalar(u32, writer_bufs[x_sym].items, stmt_i_u32) == null) {
            try writer_bufs[x_sym].append(allocator, stmt_i_u32);
        }
    }

    invalidateConflictingCjsExportFacts(cjs_export_facts_buf.items, stmts);
    invalidateFactsForNestedExportsAccess(allocator, ast, cjs_export_facts_buf.items, stmts, unresolved_globals);

    const sym_to_writer_stmts = try finalizeWriterBuckets(allocator, writer_bufs, sym_to_stmt);

    // Phase 3: 역인덱스 구축
    const reverse = try buildReverseIndex(allocator, stmts, symbols.len);

    const cjs_export_facts = try cjs_export_facts_buf.toOwnedSlice(allocator);

    return .{
        .stmts = stmts,
        .cjs_export_facts = cjs_export_facts,
        .symbol_to_stmt = sym_to_stmt,
        .sym_to_side_effect_stmts = reverse.sym_to_side_effect_stmts,
        .sym_to_referencing_stmts = reverse.sym_to_referencing_stmts,
        .sym_to_writer_stmts = sym_to_writer_stmts,
        .allocator = allocator,
    };
}

test "findStmtIndexFromInfos maps pos to containing top-level statement" {
    var stmts = [_]StmtInfo{
        .{
            .node_idx = 0,
            .span = .{ .start = 0, .end = 10 },
            .has_side_effects = false,
            .declared_symbols = &.{},
            .referenced_symbols = &.{},
        },
        .{
            .node_idx = 1,
            .span = .{ .start = 20, .end = 40 },
            .has_side_effects = false,
            .declared_symbols = &.{},
            .referenced_symbols = &.{},
        },
        .{
            .node_idx = 2,
            .span = .{ .start = 50, .end = 70 },
            .has_side_effects = false,
            .declared_symbols = &.{},
            .referenced_symbols = &.{},
        },
    };
    const infos = ModuleStmtInfos{
        .stmts = &stmts,
        .symbol_to_stmt = &.{},
        .sym_to_side_effect_stmts = &.{},
        .sym_to_referencing_stmts = &.{},
        .sym_to_writer_stmts = &.{},
        .allocator = std.testing.allocator,
    };

    try std.testing.expectEqual(@as(?u32, 0), findStmtIndexFromInfos(infos, 0));
    try std.testing.expectEqual(@as(?u32, 0), findStmtIndexFromInfos(infos, 9));
    try std.testing.expectEqual(@as(?u32, 1), findStmtIndexFromInfos(infos, 20));
    try std.testing.expectEqual(@as(?u32, 1), findStmtIndexFromInfos(infos, 39));
    try std.testing.expectEqual(@as(?u32, 2), findStmtIndexFromInfos(infos, 50));
    try std.testing.expectEqual(@as(?u32, null), findStmtIndexFromInfos(infos, 10));
    try std.testing.expectEqual(@as(?u32, null), findStmtIndexFromInfos(infos, 45));
    try std.testing.expectEqual(@as(?u32, null), findStmtIndexFromInfos(infos, 70));
}
