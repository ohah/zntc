//! ZNTC Bundler — Binding Scanner
//!
//! AST에서 import/export의 바인딩 상세를 추출한다.
//! import_scanner.zig는 specifier 경로만 추출하지만,
//! 이 모듈은 "어떤 이름이 어떤 이름으로 바인딩되는지"를 추출한다.
//!
//! 예:
//!   import { foo as bar } from './dep'
//!   → ImportBinding { kind=.named, local_name="bar", imported_name="foo" }
//!
//!   export const x = 1;
//!   → ExportBinding { exported_name="x", local_name="x", kind=.local }

const std = @import("std");
const Ast = @import("../parser/ast.zig").Ast;
const Node = @import("../parser/ast.zig").Node;
const NodeIndex = @import("../parser/ast.zig").NodeIndex;
const ast_walk = @import("../parser/ast_walk.zig");
const Span = @import("../lexer/token.zig").Span;
const preamble_writer = @import("linker/preamble_writer.zig");
const types = @import("types.zig");
const module_parser = @import("../parser/module.zig");
const Scanner = @import("../lexer/scanner.zig").Scanner;
const ModuleIndex = types.ModuleIndex;
const symbol_mod = @import("symbol.zig");
const AliasTable = symbol_mod.AliasTable;
const semantic_symbol = @import("../semantic/symbol.zig");
const ScopeId = @import("../semantic/scope.zig").ScopeId;
const SemanticSymbol = semantic_symbol.Symbol;

pub const CallsiteRole = enum { schedule, to_esm, require, esm_init, esm_namespace, entry_guard, namespace_export_value };
pub const CallsiteTarget = struct {
    role: CallsiteRole,
    symbol: symbol_mod.SymbolID,
    owner: @import("module.zig").SemanticOwnerToken,
    declaration: NodeIndex,
};

pub const ImportBinding = struct {
    /// Compiler-created import whose use is represented by real callsite AST.
    /// The foreign identity is captured at creation, never recovered by name.
    callsite_target: ?CallsiteTarget = null,
    /// Original value identity remains; actual source AST owns lazy init calls.
    guarded_lazy_calls_lowered: bool = false,
    /// A real program-prologue AST owns this original import initialization.
    guarded_eager_init_lowered: bool = false,

    /// The producer may materialize an imported value as real local storage.
    /// Its exact current declaration anchor keeps the same source SymbolId.
    local_role: enum { import_binding, materialized_var, materialized_const } = .import_binding,
    kind: Kind,
    /// 이 모듈에서 사용하는 로컬 이름 (e.g. "bar" in `import { foo as bar }`)
    local_name: []const u8,
    /// 상대 모듈에서 export된 이름 (e.g. "foo", "default", "*")
    imported_name: []const u8,
    /// 로컬 바인딩의 소스 위치 (linker의 rename 키로 사용)
    local_span: Span,
    /// 어떤 import 문에서 왔는지 (ImportRecord 인덱스)
    import_record_index: u32,
    /// namespace import에서 실제 접근된 프로퍼티 목록 (v.object → "object")
    /// null = 전체 사용 (동적 접근, namespace 탈출 등 fallback)
    namespace_used_properties: ?[]const []const u8 = null,
    /// `namespace_used_properties[i]`가 접근된 top-level statement 인덱스 목록.
    /// `module.prebuilt_stmt_info.stmts` 인덱스 기준. 길이는 `namespace_used_properties`와 같다.
    /// null = 정보 없음 (fallback: 전체 seed). BFS가 dead-scope access를 걸러내는 근거.
    namespace_used_property_stmts: ?[]const []const u32 = null,
    /// #1328 Phase 2: source 모듈의 export 심볼 참조. invalid = 미해결.
    /// Phase 3에서 linker가 cross-module resolve로 채움. 문자열 이름 기반
    /// resolve 경로(`findExportBinding(imported_name)`)는 re-export 등을 위해
    /// 영구 병존 — 제거 대상 아님.
    symbol: symbol_mod.SymbolRef = symbol_mod.SymbolRef.invalid,
    /// #1328 Phase 4c-3b: 현재 모듈의 로컬 바인딩 심볼 (semantic scope).
    /// import preamble/rename 경로에서 "현재 모듈 기준" canonical 조회에 사용.
    /// `symbol`은 source 모듈 쪽을 가리키므로 local 경로에는 쓸 수 없다.
    /// linker.populateImportSymbols가 exact local_symbol_node의 SID로 채운다.
    /// invalid = exact semantic anchor가 없거나 유효하지 않은 경우.
    local_symbol: symbol_mod.SymbolRef = symbol_mod.SymbolRef.invalid,
    /// Exact current declaration of this consumer local. Source imports start
    /// at the parser binding; materialization explicitly hands off to its real
    /// storage binding node while retaining the same SymbolId.
    local_symbol_node: ?NodeIndex = null,
    /// Actual import declaration owner, captured alongside the local anchor.
    /// Retained clones/rewrites hand this carrier forward without AST scans.
    local_declaration_node: ?NodeIndex = null,
    /// #3068: helper marker (runtime helper / JSX runtime) 가 적용된 binding.
    /// semantic ID map이 없는 저수준 caller의 호환 lookup은 이 marker로
    /// helper_scope_map을 선택한다. 분석된 경로는 marker/이름 대신 exact node를 쓴다.
    is_helper: bool = false,
    /// TypeScript only: the binding is used as a type alone **in the source**,
    /// so the import is elided. Judged at parse time, before transforms can
    /// inline its value uses away (#5571). null = not computed (fall back to
    /// the current references).
    source_type_only: ?bool = null,

    pub const Kind = enum {
        default,
        named,
        namespace,
    };

    /// `import x from './m'` (kind=.default) 또는 `import { default as X }`
    /// (kind=.named, imported_name="default") 어느 쪽이든 source의 default를
    /// import하는 케이스 통칭.
    pub fn importsDefault(self: ImportBinding) bool {
        // (#4510) `import { "default" as X }` 도 default import 다 — 이름에 따옴표가
        // 붙어 저장되므로 bare 비교로는 못 잡는다. 판정은 preamble_writer 단일 소스.
        return self.kind == .default or
            (self.kind == .named and preamble_writer.isDefaultExportName(self.imported_name));
    }
};

/// The eager source call owns evaluation; namespace value uses retain the
/// original import SID and refer to the provider's exact namespace storage.
pub fn eagerNamespaceSymbol(graph: anytype, module: anytype, binding: ImportBinding) error{MissingWrapperSymbol}!?symbol_mod.SymbolID {
    if (!binding.guarded_eager_init_lowered or binding.kind != .namespace) return null;
    if (binding.import_record_index >= module.import_records.len) return error.MissingWrapperSymbol;
    const target = module.import_records[binding.import_record_index].resolved;
    if (target.isNone() or target == module.index) return error.MissingWrapperSymbol;
    const owner = graph.getModule(target) orelse return error.MissingWrapperSymbol;
    const namespace = owner.esmNamespaceSymbol() catch return error.MissingWrapperSymbol;
    const semantic = owner.semantic orelse return error.MissingWrapperSymbol;
    if (semantic.symbols.items[@backingInt(namespace.inner)].kind != .variable_var) return error.MissingWrapperSymbol;
    return namespace;
}

pub fn eagerNamespaceForExport(graph: anytype, module: anytype, exported: ExportBinding) error{MissingWrapperSymbol}!?symbol_mod.SymbolID {
    if (exported.has_default_export_facade) return null;
    const anchor = exported.local_symbol_node orelse return null;
    const ast = module.ast orelse return null;
    const semantic = module.semantic orelse return null;
    if (anchor.isNone() or @backingInt(anchor) >= ast.nodes.items.len or @backingInt(anchor) >= semantic.symbol_ids.len or ast.getNode(anchor).tag != .identifier_reference) return null;
    const sid = semantic.symbol_ids[@backingInt(anchor)] orelse return null;
    for (module.import_bindings) |binding| {
        const local = resolveImportLocalSymbol(binding, .{ .module_index = module.index, .ast = &ast, .symbol_ids = semantic.symbol_ids, .symbols = semantic.symbols.items });
        if (local.semanticIndex() != @as(?u32, sid)) continue;
        return eagerNamespaceSymbol(graph, module, binding);
    }
    return null;
}

pub const ImportLocalSymbolContext = struct {
    module_index: ModuleIndex,
    ast: ?*const Ast = null,
    /// Non-null means this is an analyzed path, even when the map is empty.
    /// Missing/malformed exact anchors must not fall through to a name lookup.
    symbol_ids: ?[]const ?u32 = null,
    symbols: []const SemanticSymbol = &.{},
    /// Explicit compatibility inputs for callers without a semantic ID map.
    module_scope: ?std.StringHashMapUnmanaged(usize) = null,
    helper_scope: ?std.StringHashMapUnmanaged(usize) = null,
};

/// Resolve the current-side import binding from its scanner-owned AST anchor.
/// The node map is authoritative; spelling is never used to repair an analyzed
/// graph. Low-level callers can explicitly omit the ID map and provide scopes.
pub fn resolveImportLocalSymbol(binding: ImportBinding, context: ImportLocalSymbolContext) symbol_mod.SymbolRef {
    if (context.symbol_ids) |ids| {
        const ast = context.ast orelse return symbol_mod.SymbolRef.invalid;
        const node = binding.local_symbol_node orelse return symbol_mod.SymbolRef.invalid;
        if (node.isNone()) return symbol_mod.SymbolRef.invalid;
        const raw = @backingInt(node);
        if (raw >= ast.nodes.items.len or raw >= ids.len) return symbol_mod.SymbolRef.invalid;
        switch (ast.nodes.items[raw].tag) {
            .identifier_reference, .binding_identifier, .import_default_specifier, .import_namespace_specifier => {},
            else => return symbol_mod.SymbolRef.invalid,
        }
        const sid = ids[raw] orelse return symbol_mod.SymbolRef.invalid;
        const expected_kind: semantic_symbol.SymbolKind = switch (binding.local_role) {
            .import_binding => .import_binding,
            .materialized_var => .variable_var,
            .materialized_const => .variable_const,
        };
        if (sid >= context.symbols.len or context.symbols[sid].kind != expected_kind) return symbol_mod.SymbolRef.invalid;
        if (binding.local_role != .import_binding and (ast.nodes.items[raw].tag != .binding_identifier or context.symbols[sid].scope_id.isNone())) return symbol_mod.SymbolRef.invalid;
        return symbol_mod.SymbolRef.makeSemantic(context.module_index, sid);
    }

    if (binding.local_role != .import_binding) return symbol_mod.SymbolRef.invalid;
    const scope = if (binding.is_helper) context.helper_scope else context.module_scope;
    const symbol_index = (scope orelse return symbol_mod.SymbolRef.invalid).get(binding.local_name) orelse
        return symbol_mod.SymbolRef.invalid;
    return symbol_mod.SymbolRef.makeSemantic(context.module_index, symbol_index);
}

pub const ExportBinding = struct {
    /// 외부에 노출되는 이름 (e.g. "x", "default", "b" in `export { a as b }`)
    exported_name: []const u8,
    /// Borrowed original string-literal syntax, recorded only by the export producer.
    has_public_key_literal: bool = false,
    public_key_binding_value: ?[]const u8 = null,
    public_key_literal: ?[]const u8 = null,
    public_key_origin: ?struct {
        ast: *const Ast,
        specifier: NodeIndex,
        literal: NodeIndex,
    } = null,
    /// 모듈 내부 이름 (e.g. "x", "a")
    local_name: []const u8,
    local_span: Span,
    /// Exact local binding/reference node used to carry this export's analyzer
    /// SymbolId. Name-based scope lookup remains only for low-level callers
    /// without a semantic ID map.
    local_symbol_node: ?NodeIndex = null,
    source_declaration_node: ?NodeIndex = null,
    source_export_node: ?NodeIndex = null,
    source_specifier_node: ?NodeIndex = null,
    kind: Kind,
    /// re-export 시 소스 모듈의 ImportRecord 인덱스
    import_record_index: ?u32 = null,
    /// #1328 Phase 2: 이 export가 가리키는 심볼.
    ///   - .local: 현재 모듈의 심볼 (semantic 선언 또는 bundler 합성 `_default`)
    ///   - .re_export: 현재 모듈 AliasTable의 AliasId 또는 명시 default bridge SID.
    /// Remote/public keys select export records. They do not recover a source
    /// lexical SID; canonical output consumers validate the producer carrier.
    /// Invalid remains possible in explicit graphless/output-owned roles.
    symbol: symbol_mod.SymbolRef = symbol_mod.SymbolRef.invalid,
    /// `export default` source node. Anonymous expression defaults receive an
    /// analyzer facade SymbolId on this exact node; name lookup is ambiguous
    /// when the module also declares a source binding named `_default`.
    default_export_node: ?NodeIndex = null,
    /// Whether the source default declaration needs the analyzer's `_default`
    /// facade. Keep this separate from `local_name`, which can also be a real
    /// source binding named `_default`.
    has_default_export_facade: bool = false,

    /// (#4587 target a) 이 `.local` export 의 선언이 destructuring pattern
    /// (`export let { A } = obj`) 안에 있는지 — scan 시 declarator 구조에서 기록한다.
    /// `exportBindingIsCjsStorage` 가 storage 대상에서 pattern 을 제외하는 데 쓴다
    /// (`renames[sid]="exports.A"` 를 pattern 안 식별자에 적용하면 `let {A: exports.A}`
    /// = SyntaxError). scan 시점 기록이라 byte-span AST 재스캔이 불필요·정확.
    declared_via_pattern: bool = false,

    /// (#4587 target a) 이 `.local` export 의 declarator 초기값이 함수/화살표/클래스
    /// 표현식인지 — scan 시 기록. `exportBindingIsCjsStorage` 가 storage 에서 제외하는 데
    /// 쓴다: `export let f = () => 0` 를 `exports.f = () => 0` 로 낮추면 NamedEvaluation
    /// 이 member target 이라 안 걸려 `f.name` 이 유실된다. 제외 시 현행 로컬 유지(무손실).
    init_is_fn_or_class: bool = false,

    pub const Kind = enum {
        /// 현재 모듈에서 직접 선언/할당된 export.
        local,
        /// source에서 명시적으로 가져온 named re-export (예: `export { x } from`).
        re_export,
        /// `export * from './m'` — 모든 export 합치기 (alias 없음).
        re_export_star,
        /// `export * as ns from './m'` — namespace 객체로 노출.
        re_export_namespace,

        /// `re_export_star`/`re_export_namespace` 통칭 (구 `re_export_all`).
        pub fn isReExportAll(self: Kind) bool {
            return self == .re_export_star or self == .re_export_namespace;
        }

        /// `.re_export` + `.re_export_*` 모두 포함 — 임의의 cross-module re-export.
        pub fn isAnyReExport(self: Kind) bool {
            return self == .re_export or self == .re_export_star or self == .re_export_namespace;
        }
    };

    /// `export { default } from './m'` 같이 default → default 직진 named re-export
    /// 인지. wrapper-barrel pattern (lodash-es lodash.js → lodash.default.js) detection
    /// 의 한 부분. `default as X` 같이 alias 가 들어가는 케이스는 false.
    pub fn isDefaultDirectReExport(self: ExportBinding) bool {
        return self.kind == .re_export and
            std.mem.eql(u8, self.exported_name, "default") and
            std.mem.eql(u8, self.local_name, "default");
    }

    /// Default가 이름 있는 source 식별자를 읽는 경우인지 확인한다.
    /// `export default lib`은 값 snapshot용 synthetic facade를 가지지만, 그 값이
    /// object이면 member-use 분석에 source 식별자도 필요하다. 실제 `_default`
    /// 로컬도 대상일 수 있으므로 이름 sentinel 대신 exact source node를 본다.
    /// `isDefaultDirectReExport`(re-export 형) 와 상보적.
    pub fn isNamedLocalDefault(self: ExportBinding) bool {
        return self.kind == .local and
            std.mem.eql(u8, self.exported_name, "default") and
            self.local_symbol_node != null;
    }

    /// 이 export 때문에 현재 모듈에 `_default` 합성 변수가 생기는지 확인.
    /// #1338 Phase 4e-2d-a: synthetic_default는 항상 semantic 공간에 등록됨.
    pub fn hasSyntheticDefault(
        self: ExportBinding,
        symbols: []const SemanticSymbol,
    ) bool {
        return switch (self.symbol) {
            .alias => false,
            .semantic => |s| blk: {
                if (s.symbol.isNone()) break :blk false;
                const idx: u32 = @backingInt(s.symbol);
                if (idx >= symbols.len) break :blk false;
                const sk = symbols[idx].synthetic_kind orelse break :blk false;
                break :blk sk == .default_export;
            },
        };
    }
};

fn stableIdentifierText(allocator: std.mem.Allocator, ast: *const Ast, node: Node) ![]const u8 {
    const name_span = switch (node.tag) {
        .binding_identifier, .identifier_reference, .assignment_target_identifier, .jsx_identifier, .import_default_specifier, .import_namespace_specifier => ast.identifierNameSpan(node),
        else => node.span,
    };
    const raw = try ast.getTextStable(allocator, name_span);
    return switch (node.tag) {
        .binding_identifier, .identifier_reference, .assignment_target_identifier, .jsx_identifier, .import_default_specifier, .import_namespace_specifier => try Scanner.decodeIdentifierEscapesAlloc(allocator, raw),
        .string_literal => try module_parser.moduleExportName(allocator, raw),
        else => raw,
    };
}

/// AST에서 import 바인딩 상세를 추출한다.
/// import_record_map: import source span → ImportRecord 인덱스 매핑
/// `helper_ref_nodes` 가 non-null 이면 import_specifier 의 local_node idx 가 그 slice 에
/// 있을 때 해당 binding 에 `is_helper=true` 를 set 한다. 이 marker는 semantic-less
/// caller의 격리된 helper scope 선택에 쓰인다. 분석된 import의 local_symbol은 사용자와
/// 같은 철자를 쓰더라도 local_symbol_node의 exact SID로만 결정한다 (#3068).
///
/// `helper_ref_nodes` 는 ascending sorted 여야 한다 (binary search 전제). transformer 의
/// `markRuntimeHelperRef` 가 새 NodeIndex 만 단조 증가로 append → `ownedHelperRefNodes` 가
/// 그 invariant 를 보존하며 sort 한다 (analyzer.zig 의 `isHelperRefNode` 도 동일 가정).
pub fn extractImportBindings(
    allocator: std.mem.Allocator,
    ast: *const Ast,
    import_records: []const types.ImportRecord,
    helper_ref_nodes: ?[]const u32,
) ![]ImportBinding {
    var bindings: std.ArrayList(ImportBinding) = .empty;
    errdefer bindings.deinit(allocator);

    // Actual import source leaf → import_record index; copied literals may share spans.
    var source_to_record: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer source_to_record.deinit(allocator);
    for (import_records, 0..) |rec, i| {
        const key = @backingInt(rec.source_node);
        try source_to_record.put(allocator, key, @intCast(i));
    }

    const reachable = try ast_walk.collectReachableNodeIndices(allocator, ast);
    defer allocator.free(reachable);

    for (reachable) |ni| {
        const node = ast.nodes.items[ni];
        if (node.tag != .import_declaration) continue;

        const e = node.data.extra;
        if (e + 2 >= ast.extra_data.items.len) continue;

        const extras = ast.extra_data.items[e .. e + 3];
        const specs_start = extras[0];
        const specs_len = extras[1];
        const source_idx: NodeIndex = @fromBackingInt(@intCast(extras[2]));
        if (source_idx.isNone()) continue;

        const rec_idx = source_to_record.get(@backingInt(source_idx)) orelse continue;

        if (specs_len == 0) continue; // side-effect import

        const spec_indices = ast.extra_data.items[specs_start .. specs_start + specs_len];
        for (spec_indices) |raw_idx| {
            const spec: NodeIndex = @fromBackingInt(@intCast(raw_idx));
            if (spec.isNone()) continue;
            if (@backingInt(spec) >= ast.nodes.items.len) continue;

            const spec_node = ast.getNode(spec);
            switch (spec_node.tag) {
                .import_default_specifier => {
                    const name = try stableIdentifierText(allocator, ast, spec_node);
                    try bindings.append(allocator, .{
                        .kind = .default,
                        .local_name = name,
                        .imported_name = "default",
                        .local_span = spec_node.span,
                        .import_record_index = rec_idx,
                        .local_symbol_node = spec,
                        .local_declaration_node = @fromBackingInt(ni),
                    });
                },
                .import_namespace_specifier => {
                    const name = try stableIdentifierText(allocator, ast, spec_node);
                    try bindings.append(allocator, .{
                        .kind = .namespace,
                        .local_name = name,
                        .imported_name = "*",
                        .local_span = spec_node.span,
                        .import_record_index = rec_idx,
                        .local_symbol_node = spec,
                        .local_declaration_node = @fromBackingInt(ni),
                    });
                },
                .import_specifier => {
                    // binary { left=imported, right=local, flags }
                    // SPEC_FLAG_TYPE_ONLY → inline type import (import { type X }) → 런타임 바인딩 불필요
                    if ((spec_node.data.binary.flags & module_parser.SPEC_FLAG_TYPE_ONLY) != 0) continue;
                    const imported_idx = spec_node.data.binary.left;
                    const local_idx = spec_node.data.binary.right;
                    if (imported_idx.isNone()) continue;

                    const imported_node = ast.getNode(imported_idx);
                    const imported_name = try stableIdentifierText(allocator, ast, imported_node);

                    const local_node_idx = if (!local_idx.isNone() and @backingInt(local_idx) != @backingInt(imported_idx))
                        local_idx
                    else
                        imported_idx;
                    const local_node = ast.getNode(local_node_idx);
                    const local_name = try stableIdentifierText(allocator, ast, local_node);

                    const is_helper = if (helper_ref_nodes) |refs|
                        std.sort.binarySearch(u32, refs, @backingInt(local_node_idx), struct {
                            fn cmp(needle: u32, item: u32) std.math.Order {
                                return std.math.order(needle, item);
                            }
                        }.cmp) != null
                    else
                        false;

                    try bindings.append(allocator, .{
                        .kind = .named,
                        .local_name = local_name,
                        .imported_name = imported_name,
                        .local_span = local_node.span,
                        .import_record_index = rec_idx,
                        .is_helper = is_helper,
                        .local_symbol_node = local_node_idx,
                        .local_declaration_node = @fromBackingInt(ni),
                    });
                },
                else => {},
            }
        }
    }

    return bindings.toOwnedSlice(allocator);
}

/// AST에서 export 바인딩 상세를 추출한다.
/// import_bindings가 주어지면 barrel re-export 패턴을 자동 감지한다.
/// (Rolldown 방식: export symbol이 import binding에 있으면 .re_export로 분류)
pub fn extractExportBindings(
    allocator: std.mem.Allocator,
    ast: *const Ast,
    import_records: []const types.ImportRecord,
    import_bindings: []const ImportBinding,
) ![]ExportBinding {
    var bindings: std.ArrayList(ExportBinding) = .empty;
    errdefer bindings.deinit(allocator);

    // Actual re-export source leaf → import_record index; copied literals may share spans.
    var source_to_record: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer source_to_record.deinit(allocator);
    for (import_records, 0..) |rec, i| {
        const key = @backingInt(rec.source_node);
        try source_to_record.put(allocator, key, @intCast(i));
    }

    // import local_name → ImportBinding 매핑 (barrel re-export O(1) 조회)
    var import_by_name: std.StringHashMapUnmanaged(ImportBinding) = .empty;
    defer import_by_name.deinit(allocator);
    for (import_bindings) |ib| {
        try import_by_name.put(allocator, ib.local_name, ib);
    }

    const reachable = try ast_walk.collectReachableNodeIndices(allocator, ast);
    defer allocator.free(reachable);
    var top_level = try ast_walk.topLevelStatementMask(ast);
    defer top_level.deinit();

    for (reachable) |ni| {
        const node = ast.nodes.items[ni];
        if (!top_level.isSet(ni)) continue;
        switch (node.tag) {
            .export_named_declaration => {
                const e = node.data.extra;
                if (e + 3 >= ast.extra_data.items.len) continue;

                const extras = ast.extra_data.items[e .. e + 4];
                const decl_idx: NodeIndex = @fromBackingInt(@intCast(extras[0]));
                const specs_start = extras[1];
                const specs_len = extras[2];
                const source_idx: NodeIndex = @fromBackingInt(@intCast(extras[3]));

                // export const x = 1; / export function f() {}
                if (!decl_idx.isNone()) {
                    const decl_node = ast.getNode(decl_idx);
                    // variable_declaration은 여러 declarator를 가질 수 있음 (export const x=1, y=2)
                    const names = try extractDeclExportNames(allocator, ast, decl_node);
                    defer allocator.free(names);
                    for (names) |name_info| {
                        // destructuring은 local export로 유지.
                        // export const { X } = importedDefault → 코드가 번들에 포함되어야 함
                        // (esbuild 동일: ESM 래퍼 코드를 유지하고 CJS preamble 생성)
                        try bindings.append(allocator, .{
                            .exported_name = name_info.name,
                            .local_name = name_info.name,
                            .local_span = name_info.span,
                            .local_symbol_node = name_info.node_index,
                            .source_declaration_node = decl_idx,
                            .source_export_node = @fromBackingInt(ni),
                            .kind = .local,
                            .declared_via_pattern = name_info.via_pattern,
                            .init_is_fn_or_class = name_info.init_fn_class,
                        });
                    }
                    continue;
                }

                // export { a, b } 또는 export { a } from './dep'
                const has_source = !source_idx.isNone();
                const rec_idx: ?u32 = if (has_source) blk: {
                    break :blk source_to_record.get(@backingInt(source_idx));
                } else null;

                if (specs_len > 0) {
                    const spec_indices = ast.extra_data.items[specs_start .. specs_start + specs_len];
                    for (spec_indices) |raw_idx| {
                        const spec: NodeIndex = @fromBackingInt(@intCast(raw_idx));
                        if (spec.isNone()) continue;
                        if (@backingInt(spec) >= ast.nodes.items.len) continue;
                        const spec_node = ast.getNode(spec);
                        if (spec_node.tag != .export_specifier) continue;
                        if ((spec_node.data.binary.flags & module_parser.SPEC_FLAG_TYPE_ONLY) != 0) continue;

                        // binary { left=local, right=exported }
                        const local_idx = spec_node.data.binary.left;
                        const exported_idx = spec_node.data.binary.right;
                        if (local_idx.isNone()) continue;

                        const local_node = ast.getNode(local_idx);
                        const local_name = try stableIdentifierText(allocator, ast, local_node);

                        const exported_node = if (!exported_idx.isNone() and @backingInt(exported_idx) != @backingInt(local_idx))
                            ast.getNode(exported_idx)
                        else
                            local_node;
                        const exported_name = try stableIdentifierText(allocator, ast, exported_node);

                        // Rolldown 방식: from 절이 없어도 local_name이 import binding이면
                        // barrel re-export로 분류 (import { X } from './a'; export { X })
                        var kind: ExportBinding.Kind = if (has_source) .re_export else .local;
                        var final_rec_idx: ?u32 = rec_idx;
                        var final_local_name = local_name;
                        // Rolldown 방식: namespace가 아닌 named import만 .re_export로 분류.
                        // namespace barrel re-export(import * as z; export { z })는
                        // .local 유지 — linker가 namespace 객체를 별도 생성.
                        if (!has_source) {
                            if (import_by_name.get(local_name)) |ib| {
                                if (ib.kind != .namespace) {
                                    kind = .re_export;
                                    final_rec_idx = ib.import_record_index;
                                    final_local_name = ib.imported_name;
                                }
                            }
                        }

                        try bindings.append(allocator, .{
                            .exported_name = exported_name,
                            .has_public_key_literal = exported_node.tag == .string_literal,
                            .public_key_binding_value = if (exported_node.tag == .string_literal and kind == .local) local_name else null,
                            .public_key_literal = if (exported_node.tag == .string_literal) ast.getText(exported_node.span) else null,
                            .public_key_origin = if (exported_node.tag == .string_literal) .{ .ast = ast, .specifier = spec, .literal = exported_idx } else null,
                            .local_name = final_local_name,
                            .local_span = local_node.span,
                            .local_symbol_node = if (!has_source) local_idx else null,
                            .source_specifier_node = spec,
                            .source_export_node = @fromBackingInt(ni),
                            .kind = kind,
                            .import_record_index = final_rec_idx,
                        });
                    }
                }
            },
            .export_default_declaration => {
                // Named declarations reuse their declaration binding. Expressions
                // get a separate default facade; identifier expressions retain their
                // source node only for value/member-use analysis.
                const inner_idx = node.data.unary.operand;
                const has_default_export_facade = module_parser.defaultExportNeedsFacade(ast, inner_idx, node.data.unary.flags);
                var local_name: []const u8 = "_default";
                var local_symbol_node: ?NodeIndex = null;
                if (!inner_idx.isNone()) {
                    const inner = ast.getNode(inner_idx);
                    if (inner.tag == .function_declaration or inner.tag == .class_declaration) {
                        const e = inner.data.extra;
                        if (e < ast.extra_data.items.len) {
                            const name_idx: NodeIndex = @fromBackingInt(@intCast(ast.extra_data.items[e]));
                            if (!name_idx.isNone()) {
                                const name_node = ast.getNode(name_idx);
                                local_name = try stableIdentifierText(allocator, ast, name_node);
                                local_symbol_node = name_idx;
                            }
                        }
                    } else if (inner.tag == .identifier_reference) {
                        // The source value is still useful to scope-aware member analysis,
                        // but the default export itself is a snapshot facade.
                        const name = try stableIdentifierText(allocator, ast, inner);
                        if (name.len > 0) {
                            local_name = name;
                            local_symbol_node = inner_idx;
                        }
                    }
                }
                // Only declaration defaults can be re-exported by name here.
                // Identifier expressions (including imported identifiers) evaluate
                // once and must remain local facade exports.
                var kind: ExportBinding.Kind = .local;
                var final_rec_idx: ?u32 = null;
                var final_local_name = local_name;
                if (!has_default_export_facade) if (import_by_name.get(local_name)) |ib| {
                    if (ib.kind != .namespace) {
                        kind = .re_export;
                        final_rec_idx = ib.import_record_index;
                        final_local_name = ib.imported_name;
                    }
                };
                try bindings.append(allocator, .{
                    .exported_name = "default",
                    .local_name = final_local_name,
                    .local_span = node.span,
                    .local_symbol_node = if (kind == .local) local_symbol_node else null,
                    .kind = kind,
                    .import_record_index = final_rec_idx,
                    .default_export_node = @fromBackingInt(@intCast(ni)),
                    .source_export_node = @fromBackingInt(ni),
                    .has_default_export_facade = has_default_export_facade,
                });
            },
            .export_all_declaration => {
                const x = module_parser.readExportAllExtras(ast, node.data.extra);
                const exported_name_idx = x.exported_name;
                const source_idx = x.source;
                if (source_idx.isNone()) continue;
                const rec_idx = source_to_record.get(@backingInt(source_idx));

                if (!exported_name_idx.isNone()) {
                    // export * as ns from './mod' — namespace re-export
                    // exported_name = "ns", local_name = "ns" (preamble에서 var ns = {...} 생성)
                    const name_node = ast.getNode(exported_name_idx);
                    const name_text = try stableIdentifierText(allocator, ast, name_node);
                    try bindings.append(allocator, .{
                        .exported_name = name_text,
                        .local_name = name_text,
                        .local_span = node.span,
                        .kind = .re_export_namespace,
                        .source_export_node = @fromBackingInt(ni),
                        .import_record_index = rec_idx,
                    });
                } else {
                    // export * from './mod' — 일반 re-export all
                    try bindings.append(allocator, .{
                        .exported_name = "*",
                        .local_name = "*",
                        .local_span = node.span,
                        .kind = .re_export_star,
                        .import_record_index = rec_idx,
                    });
                }
            },
            else => {},
        }
    }

    return bindings.toOwnedSlice(allocator);
}

/// Add facade classification from the exact analyzer node identity. The
/// parser's syntax-only scan cannot tell a lexical identifier from a global
/// reference, while the analyzer records the synthetic facade on the export
/// declaration node itself.
pub fn markDefaultExportFacadesFromSemantic(
    bindings: []ExportBinding,
    symbol_ids: []const ?u32,
    symbols: []const SemanticSymbol,
) void {
    for (bindings) |*binding| {
        if (binding.kind != .local or !std.mem.eql(u8, binding.exported_name, "default")) continue;
        const export_node = binding.default_export_node orelse continue;
        const node_index = @backingInt(export_node);
        if (node_index >= symbol_ids.len) continue;
        const symbol_index = symbol_ids[node_index] orelse continue;
        if (symbol_index >= symbols.len) continue;
        const symbol = symbols[symbol_index];
        if (symbol.decl_flags.is_default_export and std.mem.eql(u8, symbol.synthetic_name, "_default")) {
            binding.has_default_export_facade = true;
        }
    }
}

const NameInfo = struct {
    name: []const u8,
    span: Span,
    node_index: NodeIndex,
    /// (#4587) declarator 이름이 destructuring pattern 안인지.
    via_pattern: bool = false,
    /// (#4587) declarator 초기값이 함수/화살표/클래스 표현식인지.
    init_fn_class: bool = false,
};

/// (#4587) declarator 초기값 노드 tag 가 NamedEvaluation 대상(함수/화살표/클래스 표현식)인지.
fn initTagIsFnOrClass(tag: Node.Tag) bool {
    return switch (tag) {
        .function_expression, .function, .arrow_function_expression, .class_expression => true,
        else => false,
    };
}

/// export 선언에서 이름들을 추출. export const x, y / export function f / export class C
fn extractDeclExportNames(allocator: std.mem.Allocator, ast: *const Ast, decl: Node) ![]NameInfo {
    var names: std.ArrayList(NameInfo) = .empty;
    errdefer names.deinit(allocator);

    switch (decl.tag) {
        .variable_declaration => {
            // extra [kind_flags, list.start, list.len]
            const e = decl.data.extra;
            if (e + 2 >= ast.extra_data.items.len) return names.toOwnedSlice(allocator);
            const list_start = ast.extra_data.items[e + 1];
            const list_len = ast.extra_data.items[e + 2];
            if (list_len == 0) return names.toOwnedSlice(allocator);

            // 모든 declarator 순회
            var i: u32 = 0;
            while (i < list_len) : (i += 1) {
                const idx = list_start + i;
                if (idx >= ast.extra_data.items.len) break;
                const decl_idx: NodeIndex = @fromBackingInt(@intCast(ast.extra_data.items[idx]));
                if (decl_idx.isNone()) continue;
                if (@backingInt(decl_idx) >= ast.nodes.items.len) continue;
                const decl_node = ast.getNode(decl_idx);
                if (decl_node.tag != .variable_declarator) continue;
                // variable_declarator: extra [name, type_ann, init_expr]
                const de = decl_node.data.extra;
                if (de >= ast.extra_data.items.len) continue;
                const name_idx: NodeIndex = @fromBackingInt(@intCast(ast.extra_data.items[de]));
                if (name_idx.isNone()) continue;
                if (@backingInt(name_idx) >= ast.nodes.items.len) continue;

                // (#4587) declarator shape 를 scan 시 기록: pattern 여부·init 이 fn/class 표현식인지.
                const name_node = ast.getNode(name_idx);
                const via_pattern = name_node.tag == .object_pattern or name_node.tag == .array_pattern;
                var init_fn_class = false;
                if (!via_pattern and de + 2 < ast.extra_data.items.len) {
                    const init_idx: NodeIndex = @fromBackingInt(@intCast(ast.extra_data.items[de + 2]));
                    if (!init_idx.isNone() and @backingInt(init_idx) < ast.nodes.items.len) {
                        init_fn_class = initTagIsFnOrClass(ast.getNode(init_idx).tag);
                    }
                }

                try extractBindingPatternNames(&names, allocator, ast, name_idx, via_pattern, init_fn_class);
            }
        },
        // 모두 extra[0] 이 이름 노드 (function: [name, ...], class: [name, ...],
        // enum: [name, members_start, members_len, flags]).
        .function_declaration, .class_declaration, .ts_enum_declaration => {
            const e = decl.data.extra;
            if (e >= ast.extra_data.items.len) return names.toOwnedSlice(allocator);
            const name_idx: NodeIndex = @fromBackingInt(@intCast(ast.extra_data.items[e]));
            if (name_idx.isNone()) return names.toOwnedSlice(allocator);
            const name_node = ast.getNode(name_idx);
            try names.append(allocator, .{
                .name = try stableIdentifierText(allocator, ast, name_node),
                .span = name_node.span,
                .node_index = name_idx,
            });
        },
        .ts_module_declaration => {
            const name_idx = decl.data.binary.left;
            if (!name_idx.isNone()) {
                const name_node = ast.getNode(name_idx);
                try names.append(allocator, .{
                    .name = try stableIdentifierText(allocator, ast, name_node),
                    .span = name_node.span,
                    .node_index = name_idx,
                });
            }
        },
        else => {},
    }

    return names.toOwnedSlice(allocator);
}

/// declaration binding pattern의 BoundNames를 export 이름으로 추출한다.
/// `export const [a, b] = ...` → ["a", "b"]
/// `export const { key: local } = ...` → ["local"]
fn extractBindingPatternNames(
    names: *std.ArrayList(NameInfo),
    allocator: std.mem.Allocator,
    ast: *const Ast,
    pattern_idx: NodeIndex,
    via_pattern: bool,
    init_fn_class: bool,
) !void {
    var w = try ast_walk.bindingIdentifiers(allocator, ast, pattern_idx, .{});
    defer w.deinit();
    while (try w.next()) |name_idx| {
        const name_node = ast.getNode(name_idx);
        try names.append(allocator, .{
            .name = try stableIdentifierText(allocator, ast, name_node),
            .span = name_node.span,
            .node_index = name_idx,
            .via_pattern = via_pattern,
            .init_fn_class = init_fn_class,
        });
    }
}

/// namespace import의 실제 프로퍼티 접근을 수집한다.
/// `import * as v from 'mod'; v.object(); v.parse();`
/// → v의 namespace_used_properties = ["object", "parse"]
///
/// namespace가 member access 외의 방식으로 사용되면 (함수 인자, 대입 등)
/// fallback으로 null (전체 사용)을 유지한다.
/// 통합 namespace access 분석 (#3680 PR #3736).
/// 옛 collectNamespaceAccesses 의 text-based 로직을 `linker/namespace_access.zig` 의
/// `analyzeNamespaceAccessTextOnly` 로 위임 — 두 path 가 동일 분석기 사용.
/// 결과 매핑:
///   - opaque (escape / computed access) → `namespace_used_properties = null`
///   - member_only with props → `namespace_used_properties = [props...]`
///   - member_only empty → `namespace_used_properties = &.{}`
pub fn collectNamespaceAccesses(
    allocator: std.mem.Allocator,
    ast: *const Ast,
    bindings: []ImportBinding,
) !void {
    var index = try collectNamespaceAccessesAndBuildIndex(allocator, ast, bindings, &.{}, .{});
    index.deinit(allocator);
}

/// PR #3738 (C6 perf): `collectNamespaceAccesses` 와 동일 분석 + index 반환.
/// `extra_interest_locals` 가 주어지면 (linker 의 named/cjs/esm 같이) 그 local 들도 색인 →
/// linker 가 같은 index 를 share 가능.
/// `opts.reachable_only` 가 false 면 모든 nodes 색인 (linker 호환).
///
/// caller 가 index ownership — `defer index.deinit(allocator)` 또는 module 에 store.
pub fn collectNamespaceAccessesAndBuildIndex(
    allocator: std.mem.Allocator,
    ast: *const Ast,
    bindings: []ImportBinding,
    extra_interest_locals: []const []const u8,
    opts: struct { reachable_only: bool = true },
) !@import("linker/namespace_access.zig").NamespaceAccessIndex {
    const ns_module = @import("linker/namespace_access.zig");

    var has_any_interest = extra_interest_locals.len > 0;
    if (!has_any_interest) {
        for (bindings) |ib| {
            if (ib.kind == .namespace) {
                has_any_interest = true;
                break;
            }
        }
    }
    // 빈 index 반환 — caller 가 deinit (no-op).
    if (!has_any_interest) return .{};

    // interest set — namespace local + extra (linker 의 named/cjs/esm).
    var interest: std.StringHashMapUnmanaged(void) = .empty;
    defer interest.deinit(allocator);
    for (bindings) |ib| {
        if (ib.kind == .namespace and ib.local_name.len > 0) {
            try interest.put(allocator, ib.local_name, {});
        }
    }
    for (extra_interest_locals) |name| {
        if (name.len > 0) try interest.put(allocator, name, {});
    }

    var index = try ns_module.NamespaceAccessIndex.buildOpt(allocator, ast, opts.reachable_only, &interest);
    errdefer index.deinit(allocator);

    for (bindings) |*ib| {
        if (ib.kind != .namespace) continue;
        var access = try ns_module.analyzeNamespaceAccessTextOnly(allocator, ast, &index, ib.local_name, null);
        defer access.deinit(allocator);

        if (access.kind == .@"opaque") {
            ib.namespace_used_properties = null;
            continue;
        }
        const count = access.members.count();
        if (count == 0) {
            ib.namespace_used_properties = &.{};
            continue;
        }
        const props = try allocator.alloc([]const u8, count);
        var i: usize = 0;
        var it = access.members.iterator();
        while (it.next()) |entry| : (i += 1) {
            props[i] = entry.key_ptr.*;
        }
        // C4 fix (#3736): 결정성 — HashMap iter 순서 → sort 로 stable.
        std.mem.sort([]const u8, props, {}, struct {
            fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.lessThan);
        ib.namespace_used_properties = props;
    }
    return index;
}

/// 모든 ExportBinding의 `symbol` 필드를 채운다. 세 경로:
///   1. `_default = <expr>` 패턴 → semantic 합성 심볼(`default_export`) 등록
///   2. `.re_export` → AliasTable에 alias 등록
///   3. `.local` → semantic ID map이 있으면 exact local AST node의 SID, 없으면 저수준 호환용 scope lookup
/// Cross-module re-export 체인 resolve는 linker가 `populateReExportAliases`에서 수행.
pub fn populateSyntheticSymbols(
    table: *AliasTable,
    module_index: ModuleIndex,
    export_bindings: []ExportBinding,
    sem_symbols: *std.ArrayList(SemanticSymbol),
    arena: std.mem.Allocator,
    /// 모듈 top-level scope (scope_maps[0]). 일반 .local export의 eb.symbol을
    /// scope_maps에서 lookup해 미리 채우는 데 사용. null이면 skip — linker가
    /// 후속 패스에서 fallback 처리.
    module_scope: ?std.StringHashMapUnmanaged(usize),
    /// Analyzer's exact node-to-SymbolId map. When present, facade exports must
    /// reuse the SymbolId assigned to their `export default` node.
    symbol_ids: ?[]const ?u32,
) !void {
    try populateSyntheticSymbolsWithOwnerScope(
        table,
        module_index,
        export_bindings,
        sem_symbols,
        arena,
        module_scope,
        symbol_ids,
        null,
    );
}

/// As populateSyntheticSymbols, while assigning the module owner scope to
/// bundler-created default re-export bridges that have no source AST binding.
/// Analyzer-owned default facades already carry their exact scope; this checks
/// that it agrees with the output owner.
pub fn populateSyntheticSymbolsWithOwnerScope(
    table: *AliasTable,
    module_index: ModuleIndex,
    export_bindings: []ExportBinding,
    sem_symbols: *std.ArrayList(SemanticSymbol),
    arena: std.mem.Allocator,
    module_scope: ?std.StringHashMapUnmanaged(usize),
    symbol_ids: ?[]const ?u32,
    owner_scope_id: ?ScopeId,
) !void {
    for (export_bindings) |*eb| {
        // Anonymous `export default <expr>` has an analyzer-owned facade node.
        // Default re-exports also materialize a bundler-local `_default` bridge,
        // but have no source facade node. Do not infer either from the spelling
        // alone: `_default` may be a real local binding.
        const is_default_export = std.mem.eql(u8, eb.exported_name, "default");
        const has_analyzer_facade = eb.kind == .local and eb.has_default_export_facade;
        // A re-export is a redirect to its actual provider, not a declaration
        // in this source semantic graph. Its existing alias is resolved below.
        if (is_default_export and has_analyzer_facade) {
            if (has_analyzer_facade) {
                if (symbol_ids) |ids| {
                    const node_idx = eb.default_export_node orelse return error.MissingDefaultExportFacadeNode;
                    const node_id = @backingInt(node_idx);
                    if (node_id >= ids.len) return error.MissingDefaultExportFacadeSymbol;
                    const raw_symbol_id = ids[node_id] orelse return error.MissingDefaultExportFacadeSymbol;
                    if (raw_symbol_id >= sem_symbols.items.len) return error.InvalidDefaultExportFacadeSymbol;

                    const facade = &sem_symbols.items[raw_symbol_id];
                    if (!std.mem.eql(u8, facade.synthetic_name, "_default"))
                        return error.InvalidDefaultExportFacadeSymbol;
                    try assignDefaultExportOwnerScope(facade, owner_scope_id);
                    facade.synthetic_kind = .default_export;
                    facade.synthetic_name = "_default";
                    eb.symbol = .{
                        .semantic = .{
                            .module = module_index,
                            .symbol = @fromBackingInt(@intCast(raw_symbol_id)),
                        },
                    };
                    continue;
                }
            }

            // Unanalyzed low-level source defaults have no exact map. Reuse
            // only an already marked source facade. Production expression
            // defaults take the exact AST-owned branch above.
            if (module_scope) |scope| {
                if (scope.get("_default")) |existing_idx| {
                    if (existing_idx < sem_symbols.items.len and
                        std.mem.eql(u8, sem_symbols.items[existing_idx].synthetic_name, "_default"))
                    {
                        const facade = &sem_symbols.items[existing_idx];
                        try assignDefaultExportOwnerScope(facade, owner_scope_id);
                        facade.synthetic_kind = .default_export;
                        facade.synthetic_name = "_default";
                        const sym_id: semantic_symbol.SymbolId = @fromBackingInt(@intCast(@as(u32, @intCast(existing_idx))));
                        eb.symbol = .{ .semantic = .{ .module = module_index, .symbol = sym_id } };
                        continue;
                    }
                }
            }
            const sem_id = try semantic_symbol.extendSymbol(
                arena,
                sem_symbols,
                .variable_var,
                .default_export,
                "_default",
                eb.local_span,
            );
            try assignDefaultExportOwnerScope(&sem_symbols.items[@backingInt(sem_id)], owner_scope_id);
            eb.symbol = .{ .semantic = .{ .module = module_index, .symbol = sem_id } };
        } else if (eb.kind == .re_export) {
            // re_export_alias는 bundler 전용 — linker가 post-link 단계에서
            // resolveExportChain 결과를 canonical_name으로 저장한다.
            const id = try table.declare(eb.exported_name);
            eb.symbol = .{ .alias = .{ .module = module_index, .symbol = id } };
        } else if (eb.kind == .local) {
            // 일반 .local export: 분석된 경로는 scanner가 보유한 정확한
            // binding/reference node의 SymbolId를 사용한다. scope의 이름 조회는
            // semantic ID map이 없는 저수준 호출에서만 호환 경로로 남긴다.
            if (symbol_ids) |ids| {
                const node_idx = eb.local_symbol_node orelse return error.MissingLocalExportSymbolNode;
                const raw_node_idx = @backingInt(node_idx);
                if (raw_node_idx >= ids.len) return error.MissingLocalExportSymbol;
                const raw_symbol_id = ids[raw_node_idx] orelse {
                    // Unresolved global expressions such as `export default globalThis`
                    // legitimately have no local SID. A scope entry, however, proves
                    // this source name was expected to resolve and must not fall back.
                    if (module_scope) |scope| {
                        if (scope.get(eb.local_name) != null) return error.MissingLocalExportSymbol;
                    }
                    continue;
                };
                if (raw_symbol_id >= sem_symbols.items.len) return error.InvalidLocalExportSymbol;
                eb.symbol = .{
                    .semantic = .{
                        .module = module_index,
                        .symbol = @fromBackingInt(@intCast(raw_symbol_id)),
                    },
                };
                continue;
            }

            const scope = module_scope orelse continue;
            const sym_idx = scope.get(eb.local_name) orelse continue;
            eb.symbol = symbol_mod.SymbolRef.makeSemantic(module_index, sym_idx);
        }
    }
}

fn assignDefaultExportOwnerScope(symbol: *SemanticSymbol, owner_scope_id: ?ScopeId) !void {
    const owner = owner_scope_id orelse return;
    if (symbol.scope_id.isNone()) {
        symbol.scope_id = owner;
    } else if (symbol.scope_id != owner) {
        return error.DefaultExportFacadeOwnerScopeMismatch;
    }
}
