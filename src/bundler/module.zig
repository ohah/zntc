//! ZNTC Bundler — Module
//!
//! 모듈 그래프의 노드. 하나의 JS/TS/JSON/CSS 파일에 대응.
//!
//! 설계:
//!   - D070: ModuleIndex = enum(u32)
//!   - D073: ModuleType enum
//!   - D078: 양방향 인접 리스트 (dependencies + importers)
//!   - D079: ImportRecord 배열로 import 정보 보유

const std = @import("std");
const types = @import("types.zig");
const ModuleIndex = types.ModuleIndex;
const ModuleType = types.ModuleType;
const ImportRecord = types.ImportRecord;
const Ast = @import("../parser/ast.zig").Ast;
const Span = @import("../lexer/token.zig").Span;
const semantic_symbol = @import("../semantic/symbol.zig");
const Symbol = semantic_symbol.Symbol;
const Reference = semantic_symbol.Reference;
const SemanticSymbolId = semantic_symbol.SymbolId;
const Scope = @import("../semantic/scope.zig").Scope;
const SemanticScopeId = @import("../semantic/scope.zig").ScopeId;
const RnAssetMetadata = @import("graph/assets.zig").RnAssetMetadata;
const binding_scanner = @import("binding_scanner.zig");
pub const ImportBinding = binding_scanner.ImportBinding;
pub const ExportBinding = binding_scanner.ExportBinding;

pub const WrapperNameError = std.mem.Allocator.Error || error{MissingWrapperSymbol};

/// Symbol identities for lexical bindings in the raw CJS runtime helper body.
/// `callback_parameter`/`module_parameter` are captured by the returned require
/// function; `catch_parameter` belongs to its catch clause; `require_function`
/// is the optional named function expression used by non-minified templates.
pub const CjsRuntimeInternalSymbolIds = struct {
    callback_parameter: SemanticSymbolId,
    module_parameter: SemanticSymbolId,
    catch_parameter: SemanticSymbolId,
    require_function: SemanticSymbolId,
};

/// Symbol identities for lexical bindings in the raw ESM runtime helper body.
pub const EsmRuntimeInternalSymbolIds = struct {
    factory_parameter: SemanticSymbolId,
    result_parameter: SemanticSymbolId,
    catch_parameter: SemanticSymbolId,
    init_function: SemanticSymbolId,
    factory_local: SemanticSymbolId,
};

/// Output-owned runtime identities are part of the semantic snapshot. Module
/// fields may be rebuilt, but cached graph ownership must not depend on names.
pub const RuntimeIdentitySnapshot = struct {
    cjs_factory: ?SemanticSymbolId = null,
    cjs_internal: ?CjsRuntimeInternalSymbolIds = null,
    esm_factory: ?SemanticSymbolId = null,
    esm_internal: ?EsmRuntimeInternalSymbolIds = null,
    to_binary: ?SemanticSymbolId = null,
    interop_helpers: ?EsmInteropRuntimeHelperSymbolIds = null,
    interop_internal: ?EsmInteropRuntimeInternalSymbolIds = null,
    hmr_internal: ?HmrRuntimeInternalSymbolIds = null,
};

/// Symbol identities for graph-wide bindings in the raw ESM interop preamble.
pub const EsmInteropRuntimeHelperSymbolIds = struct {
    create: SemanticSymbolId,
    get_proto_of: SemanticSymbolId,
    def_prop: SemanticSymbolId,
    get_own_prop_names: SemanticSymbolId,
    get_own_prop_desc: SemanticSymbolId,
    has_own: SemanticSymbolId,
    copy_props: SemanticSymbolId,
    to_esm: SemanticSymbolId,
    export_helper: SemanticSymbolId,
    to_common_js: SemanticSymbolId,
};

/// Symbol identities for lexical bindings in raw ESM interop helper templates.
pub const EsmInteropRuntimeInternalSymbolIds = struct {
    copy_props_to: SemanticSymbolId,
    copy_props_from: SemanticSymbolId,
    copy_props_desc: SemanticSymbolId,
    copy_props_keys: SemanticSymbolId,
    copy_props_index: SemanticSymbolId,
    copy_props_key: SemanticSymbolId,
    copy_props_closure_key: SemanticSymbolId,
    to_esm_module: SemanticSymbolId,
    to_esm_node_mode: SemanticSymbolId,
    to_esm_target: SemanticSymbolId,
    export_target: SemanticSymbolId,
    export_all: SemanticSymbolId,
    export_name: SemanticSymbolId,
    to_common_js_module: SemanticSymbolId,
};

pub const EsmInteropInternalRow = struct {
    identity: []const u8,
    kind: semantic_symbol.SymbolKind,
};

// These labels identify semantic bindings, not emitted spellings. Some
// helpers intentionally reuse names such as `mod` and `target`, so each
// lexical binding needs a distinct role validation label.
pub const ESM_INTEROP_INTERNAL_ROWS = [_]EsmInteropInternalRow{
    .{ .identity = "copy_props.to", .kind = .parameter },
    .{ .identity = "copy_props.from", .kind = .parameter },
    .{ .identity = "copy_props.desc", .kind = .parameter },
    .{ .identity = "copy_props.keys", .kind = .variable_var },
    .{ .identity = "copy_props.index", .kind = .variable_var },
    .{ .identity = "copy_props.key", .kind = .variable_var },
    .{ .identity = "copy_props.closure_key", .kind = .parameter },
    .{ .identity = "to_esm.module", .kind = .parameter },
    .{ .identity = "to_esm.node_mode", .kind = .parameter },
    .{ .identity = "to_esm.target", .kind = .parameter },
    .{ .identity = "export.target", .kind = .parameter },
    .{ .identity = "export.all", .kind = .parameter },
    .{ .identity = "export.name", .kind = .variable_var },
    .{ .identity = "to_common_js.module", .kind = .parameter },
};

pub fn hasEsmInteropHelperRows(symbols: []const Symbol) bool {
    const names = @import("../runtime_helper_names.zig");
    for (symbols) |symbol| {
        if (symbol.synthetic_kind != .bundler_runtime_helper) continue;
        inline for (names.ESM_INTEROP_RUNTIME_HELPERS) |helper| {
            if (std.mem.eql(u8, symbol.synthetic_name, names.esmInteropRuntimeHelperBaseName(helper))) return true;
        }
    }
    return false;
}

pub fn hasEsmInteropInternalRows(symbols: []const Symbol) bool {
    for (symbols) |symbol| if (symbol.synthetic_kind == .esm_interop_runtime_internal_local) return true;
    return false;
}

pub fn validEsmInteropHelperIds(ids: EsmInteropRuntimeHelperSymbolIds, symbols: []const Symbol) bool {
    const names = @import("../runtime_helper_names.zig");
    var seen: [names.ESM_INTEROP_RUNTIME_HELPERS.len]SemanticSymbolId = undefined;
    inline for (names.ESM_INTEROP_RUNTIME_HELPERS, 0..) |helper, index| {
        const id = @field(ids, @tagName(helper));
        const raw = @backingInt(id);
        if (id.isNone() or raw >= symbols.len) return false;
        const symbol = symbols[raw];
        if (symbol.synthetic_kind != .bundler_runtime_helper or symbol.kind != .variable_var or
            !std.mem.eql(u8, symbol.synthetic_name, names.esmInteropRuntimeHelperBaseName(helper))) return false;
        for (seen[0..index]) |previous| if (previous == id) return false;
        seen[index] = id;
    }
    return true;
}

pub fn validEsmInteropInternalIds(ids: EsmInteropRuntimeInternalSymbolIds, symbols: []const Symbol) bool {
    const fields = @typeInfo(EsmInteropRuntimeInternalSymbolIds).@"struct".field_names;
    comptime std.debug.assert(fields.len == ESM_INTEROP_INTERNAL_ROWS.len);
    var seen: [fields.len]SemanticSymbolId = undefined;
    inline for (fields, ESM_INTEROP_INTERNAL_ROWS, 0..) |field, row, index| {
        const id = @field(ids, field);
        const raw = @backingInt(id);
        if (id.isNone() or raw >= symbols.len) return false;
        const symbol = symbols[raw];
        if (symbol.synthetic_kind != .esm_interop_runtime_internal_local or symbol.kind != row.kind or
            !std.mem.eql(u8, symbol.synthetic_name, row.identity)) return false;
        for (seen[0..index]) |previous| if (previous == id) return false;
        seen[index] = id;
    }
    return true;
}

/// Exact identities for top-level lexical bindings in the raw HMR runtime
/// preamble. They share the bundle scope with generated HMR callsites.
pub const HmrRuntimeInternalSymbolIds = struct {
    global: SemanticSymbolId,
    modules: SemanticSymbolId,
    hot_callbacks: SemanticSymbolId,
    hot_data: SemanticSymbolId,
    schedule: SemanticSymbolId,
    reload: SemanticSymbolId,
    resolve_refresh: SemanticSymbolId,
    refresh_boundary: SemanticSymbolId,
    refresh_timer: SemanticSymbolId,
    enqueue_update: SemanticSymbolId,
    make_hot: SemanticSymbolId,
    original_commonjs: SemanticSymbolId,
    original_esm: SemanticSymbolId,
    apply_update: SemanticSymbolId,
};
pub const HmrRuntimeInternalRow = struct {
    field_name: []const u8,
    identity: []const u8,
    emitted_name: []const u8,
    kind: semantic_symbol.SymbolKind,
};

pub const HMR_RUNTIME_INTERNAL_ROWS = [_]HmrRuntimeInternalRow{
    .{ .field_name = "global", .identity = "hmr.global", .emitted_name = "__zntc_g", .kind = .variable_var },
    .{ .field_name = "modules", .identity = "hmr.modules", .emitted_name = "__zntc_modules", .kind = .variable_var },
    .{ .field_name = "hot_callbacks", .identity = "hmr.hot_callbacks", .emitted_name = "__zntc_hot_cbs", .kind = .variable_var },
    .{ .field_name = "hot_data", .identity = "hmr.hot_data", .emitted_name = "__zntc_hot_data", .kind = .variable_var },
    .{ .field_name = "schedule", .identity = "hmr.schedule", .emitted_name = "__zntc_schedule", .kind = .function_decl },
    .{ .field_name = "reload", .identity = "hmr.reload", .emitted_name = "__zntc_reload", .kind = .variable_var },
    .{ .field_name = "resolve_refresh", .identity = "hmr.resolve_refresh", .emitted_name = "__zntc_resolveRefresh", .kind = .function_decl },
    .{ .field_name = "refresh_boundary", .identity = "hmr.refresh_boundary", .emitted_name = "__zntc_isReactRefreshBoundary", .kind = .function_decl },
    .{ .field_name = "refresh_timer", .identity = "hmr.refresh_timer", .emitted_name = "__zntc_refreshTimer", .kind = .variable_var },
    .{ .field_name = "enqueue_update", .identity = "hmr.enqueue_update", .emitted_name = "__zntc_enqueueUpdate", .kind = .function_decl },
    .{ .field_name = "make_hot", .identity = "hmr.make_hot", .emitted_name = "__zntc_make_hot", .kind = .function_decl },
    .{ .field_name = "original_commonjs", .identity = "hmr.original_commonjs", .emitted_name = "__zntc_orig_commonJS", .kind = .variable_var },
    .{ .field_name = "original_esm", .identity = "hmr.original_esm", .emitted_name = "__zntc_orig_esm", .kind = .variable_var },
    .{ .field_name = "apply_update", .identity = "hmr.apply_update", .emitted_name = "__zntc_apply_update", .kind = .function_decl },
};

pub fn hasHmrRuntimeRows(symbols: []const Symbol) bool {
    for (symbols) |symbol| {
        if (symbol.synthetic_kind == .hmr_runtime_internal_local or std.mem.startsWith(u8, symbol.synthetic_name, "hmr.")) return true;
    }
    return false;
}

pub fn validHmrRuntimeIds(ids: HmrRuntimeInternalSymbolIds, symbols: []const Symbol) bool {
    comptime std.debug.assert(@typeInfo(HmrRuntimeInternalSymbolIds).@"struct".field_names.len == HMR_RUNTIME_INTERNAL_ROWS.len);
    var seen: [HMR_RUNTIME_INTERNAL_ROWS.len]SemanticSymbolId = undefined;
    inline for (HMR_RUNTIME_INTERNAL_ROWS, 0..) |row, index| {
        const id = @field(ids, row.field_name);
        const raw = @backingInt(id);
        if (id.isNone() or raw >= symbols.len) return false;
        const symbol = symbols[raw];
        if (symbol.synthetic_kind != .hmr_runtime_internal_local or symbol.kind != row.kind or
            !std.mem.eql(u8, symbol.synthetic_name, row.identity)) return false;
        for (seen[0..index]) |previous| if (previous == id) return false;
        seen[index] = id;
    }
    return true;
}

const stmt_info_mod = @import("stmt_info.zig");
const symbol_mod = @import("symbol.zig");
pub const AliasTable = symbol_mod.AliasTable;
const RenameTable = symbol_mod.RenameTable;
const SymbolID = symbol_mod.SymbolID;
const RuntimeHelpers = @import("../transformer/runtime_helper_bits.zig").RuntimeHelpers;

pub const DISABLED_MODULE_PREFIX = "(disabled):";
pub const OPTIONAL_MISSING_MODULE_PREFIX = "(optional-missing):";

/// 증분 빌드용 path 기반 resolve cache.
///
/// `ImportRecord.resolved` 는 빌드마다 새로 배정되는 ModuleIndex라 다음 rebuild에서
/// 직접 재사용할 수 없다. 대신 resolve 결과를 path/specifier 기반으로 보존했다가
/// cache-hit 모듈에서 graph edge를 다시 구성한다.
/// PR #3749 Phase 3: path slice 의 *lifetime invariant* 를 type system 으로 강제.
/// 각 variant 는 *path 의 ownership* 명시:
///   - interned: `ResolveCache.path_pool` 소유 — borrow, free 금지 (cache.deinit 시 reclaim).
///   - specifier: `Module.parse_arena` 소유 — borrow, free 금지 (module.deinit 시 destroyParseArena).
///   - owned: caller (graph allocator) alloc — free 필수.
///
/// (#3759 sweep) `.plugin` variant 제거: PR #3761 후 `internResolvedModule` 가 plugin
/// 경로의 path 도 path_pool 로 intern → caller 는 `.interned` 로 wrap. production 에서
/// `.plugin` set 위치 0.
pub const PathRef = union(enum) {
    interned: []const u8,
    specifier: []const u8,
    owned: []const u8,

    /// variant 무관 byte slice 접근.
    pub inline fn bytes(self: PathRef) []const u8 {
        return switch (self) {
            inline else => |s| s,
        };
    }

    /// variant 별 free. owned 만 실제 free, 나머지 no-op.
    pub fn deinit(self: PathRef, allocator: std.mem.Allocator) void {
        switch (self) {
            .owned => |s| allocator.free(s),
            else => {},
        }
    }
};

pub const CachedResolvedDep = struct {
    record_index: ?u32 = null,
    kind: types.ImportKind,
    target: Target,
    path: PathRef,
    resolve_dir: ?PathRef = null,
    target_is_module_field: bool = false,
    is_context_dep: bool = false,

    pub const Target = enum {
        file,
        disabled,
        optional_missing,
        external,
        worker,
        virtual,
    };
};

/// Process-local ownership identity. Never serialize this token: an on-disk
/// semantic graph owns new allocations even when all symbol names match.
pub const SemanticOwnerToken = enum(u64) { unassigned = 0, _ };
var semantic_owner_sequence = std.atomic.Value(u64).init(1);

fn nextSemanticOwnerToken(sequence: *std.atomic.Value(u64)) SemanticOwnerToken {
    var next = sequence.load(.monotonic);
    while (next != 0 and next != std.math.maxInt(u64)) {
        if (sequence.cmpxchgWeak(next, next + 1, .monotonic, .monotonic)) |actual| {
            next = actual;
        } else return @fromBackingInt(@intCast(next));
    }
    // Saturate forever instead of wrapping into zero or reusing an old token.
    return .unassigned;
}

/// Semantic analyzer 결과 또는 AST 없는 그래프 생성 심볼의 저장소.
/// 모든 backing 데이터는 parse_arena가 소유하며 linker가 import→export 연결 + 이름 충돌 해결에 사용.
pub const ModuleSemanticData = struct {
    const SemanticEditor = @import("../semantic/editor.zig").SemanticEditor;
    /// Assigned lazily when capturing a rename snapshot. New analyzer/codec
    /// structs remain unassigned; physical moves and exact SID edits retain it.
    owner_token: SemanticOwnerToken = .unassigned,

    /// Semantic 심볼 배열. parse_arena가 backing 메모리를 소유.
    /// #1328 Phase 4e-2 / RFC #1338: ArrayList로 보관하여 bundler가
    /// `extendSymbol`로 합성 심볼을 post-semantic 단계에 추가할 수 있게 한다.
    /// 읽기는 `.items` 사용.
    symbols: std.ArrayList(Symbol),
    scopes: []const Scope,
    /// 스코프별 이름→심볼 인덱스 조회. scope_maps[scope_id].get("x") → symbol index.
    scope_maps: []const std.StringHashMapUnmanaged(usize),
    scope_owner_map: std.AutoHashMapUnmanaged(u32, u32) = .empty,
    /// Expression use scopes, independent of AST nodes that own scopes.
    node_scope_provenance: @import("../semantic/node_scope_provenance.zig").Map = .empty,
    class_self_symbol_map: std.AutoHashMapUnmanaged(u32, u32) = .empty,
    source_owned_retirements: @import("../semantic/source_owned_retirement.zig").Map = .empty,
    scope_history: @import("../semantic/scope_frame_history.zig").History = .{},
    namespace_member_owners: std.AutoHashMapUnmanaged(u32, u32) = .empty,
    namespace_declaration_owners: std.AutoHashMapUnmanaged(u32, u32) = .empty,
    /// export된 이름 목록. exported_names.get("x") → Span.
    exported_names: std.StringHashMapUnmanaged(Span),
    /// 노드 인덱스 → 심볼 인덱스 매핑. 식별자 노드만 유효값.
    symbol_ids: []const ?u32,
    /// 미해결 참조 (unresolved references). 스코프 체인에서 선언을 찾지 못한 이름.
    /// 번들러 linker가 scope hoisting 시 이 이름들을 예약하여 shadowing 방지.
    unresolved_references: std.StringHashMapUnmanaged(void),
    /// per-reference 배열. 현재 consumer: mangler liveness.
    references: []const Reference = &.{},
    /// `Symbol.const_kind == .number` 인 심볼의 원본 numeric_literal 텍스트 사이드테이블 (#2505).
    /// Symbol 에 16B slice 를 박지 않으려고 분리 — 보통 numeric const 는 전체 심볼의 극소수.
    /// parse_arena 가 backing — value slice 는 source 또는 string_table 참조.
    numeric_const_texts: std.AutoHashMapUnmanaged(u32, []const u8) = .empty,
    /// #3068: helper marker (runtime helper / JSX runtime) 가 적용된 import_specifier 의
    /// local 식별자 binding 을 격리 보관. linker 의 `populateImportSymbols` 가
    /// `ImportBinding.is_helper=true` 인 binding 의 local_symbol 을 이 맵에서 찾도록 해
    /// 사용자가 같은 이름의 식별자를 선언해도 충돌이 일어나지 않게 한다.
    helper_scope_map: std.StringHashMapUnmanaged(usize) = .empty,
    /// Allocated only for a module that owns output runtime bindings; the
    /// parse arena owns this record together with its symbols and scopes.
    runtime_identities: ?*RuntimeIdentitySnapshot = null,

    /// Exact AST/SID/Scope roles for strict ESM functions emitted outside their initializer.
    strict_output_context: @import("strict_function_context.zig").OutputContext = .{},

    pub fn ensureRuntimeIdentities(self: *ModuleSemanticData, allocator: std.mem.Allocator) std.mem.Allocator.Error!*RuntimeIdentitySnapshot {
        if (self.runtime_identities) |identities| return identities;
        const identities = try allocator.create(RuntimeIdentitySnapshot);
        identities.* = .{};
        self.runtime_identities = identities;
        return identities;
    }

    pub fn captureOwnerToken(self: *ModuleSemanticData) SemanticOwnerToken {
        if (self.owner_token == .unassigned)
            self.owner_token = nextSemanticOwnerToken(&semantic_owner_sequence);
        return self.owner_token;
    }

    /// AST 변경 전에 의미 정보를 가변 소유자로 복사한다. allocator는 parse_arena여야 한다.
    pub fn beginEdit(self: *const ModuleSemanticData, allocator: std.mem.Allocator, ast: *Ast) @import("../semantic/editor.zig").Error!SemanticEditor {
        var editor = try SemanticEditor.init(
            allocator,
            ast,
            self.symbols.items,
            self.scopes,
            self.scope_maps,
            self.scope_owner_map,
            self.references,
            self.symbol_ids,
            self.helper_scope_map,
        );
        errdefer editor.deinit();
        try editor.importScopeHistory(self.scope_history);
        try editor.importNodeScopeProvenance(self.node_scope_provenance);
        try editor.importSourceOwnedRetirements(self.source_owned_retirements);
        return editor;
    }

    /// 변환이 끝난 뒤 동일 SymbolId를 유지한 배열을 모듈에 돌려준다.
    pub fn applyEdit(self: *ModuleSemanticData, result: SemanticEditor.Result) void {
        self.symbols = result.symbols;
        self.source_owned_retirements = result.source_owned_retirements;
        self.scope_history = result.scope_history;
        self.scopes = result.scopes;
        self.scope_maps = result.scope_maps;
        self.scope_owner_map = result.scope_owner_map;
        self.node_scope_provenance = result.node_scope_provenance;
        self.helper_scope_map = result.helper_scope_map;
        self.references = result.references;
        self.symbol_ids = result.symbol_ids;
    }

    /// 심볼 id에 해당하는 이름을 반환. `Symbol.nameText` 래퍼.
    pub fn symbolName(self: *const ModuleSemanticData, id: u32, source: []const u8) []const u8 {
        if (id >= self.symbols.items.len) return "";
        return self.symbols.items[id].nameText(source);
    }

    /// `sym_id` 가 numeric const 면 원본 텍스트를, 아니면 빈 슬라이스를 반환.
    pub fn numericConstText(self: *const ModuleSemanticData, sym_id: u32) []const u8 {
        return self.numeric_const_texts.get(sym_id) orelse "";
    }
};

/// graph parseModule 의 transformer pre-pass 결과 캐시 (#1961).
///
/// emitter 가 transformer 를 같은 ast 에 다시 호출하지 않고 (transformer 의 invariants
/// 위반) 이 캐시 값을 그대로 사용. parse_arena 가 backing — symbol_ids slice 도 그 안.
/// transformed root 는 `ast.transformed_root` 가 보유 — emitter 의 transformer.transform()
/// 이 cache hit 분기로 그 root 를 그대로 반환하므로 별도 캐시 불필요.
pub const WorkletFactoryLocalBinding = struct {
    /// Exact generated function-name binding node. Reanalysis restores producer
    /// metadata through this node's fresh SymbolId rather than by name lookup.
    node_index: u32,
    output_name_hint: []const u8,
};

/// Exact generated bindings whose linker-selected names must survive
/// post-transform semantic reanalysis.
pub const PostGraphOutputBinding = struct {
    node_index: u32,
    output_name_hint: []const u8,
    synthetic_kind: semantic_symbol.SyntheticKind,
    binding_kind: semantic_symbol.SymbolKind,
};

/// Exact runtime-helper import local whose final spelling is assigned after
/// linker scope collection and must survive semantic reanalysis by NodeIndex.
pub const RuntimeHelperImportOutputBinding = struct {
    node_index: u32,
    output_name_hint: []const u8,
};

/// One actual disk-loader installation of a current winning builtin source.
/// Borrowed from this Module's parse arena; never serialized or reconstructed
/// from a virtual path. Stack addresses of the decoder result are not retained.
pub const RuntimeHelperCacheSource = struct {
    module_domain: *const Module,
    ast_domain: *const Ast,
    semantic_domain: *const ModuleSemanticData,
    arena_domain: *const std.heap.ArenaAllocator,
    constructor: @import("../runtime_helper_source_origin.zig").Origin,
    winning_source: []const u8,
    decoded_source: []const u8,
    decoded_hash: u64,
    owner: SemanticOwnerToken,
    root: @import("../parser/ast.zig").NodeIndex,
    cache_key: u64,
    nodes: []const @import("../parser/ast.zig").Node,
    extras: []const u32,
    strings: []const u8,
    symbols: []const Symbol,
    scopes: []const Scope,
    scope_maps: []const std.StringHashMapUnmanaged(usize),
    references: []const Reference,
    symbol_ids: []const ?u32,
    scope_owners: std.AutoHashMapUnmanaged(u32, u32),
};

pub const TransformCache = struct {
    /// transformer 가 set 한 RuntimeHelpers 비트맵.
    /// emitter 의 chunk-level helper preamble 결정에 사용.
    runtime_helpers: RuntimeHelpers,
    /// transformer 가 만든 symbol_ids slice. parser 영역 + transformer 영역 매핑 포함.
    /// emitter 의 minify/linker buildMetadataForAst override_syms 에 사용.
    symbol_ids: []const ?u32,
    /// #2869 transformer 가 emit 한 runtime helper identifier_reference 노드 인덱스
    /// (sorted, ascending). resync 의 SemanticAnalyzer 가 binary search 로 helper-aware
    /// binding 분기에 사용. 비어있으면 helper-aware path 비활성 (기존 동작 유지).
    helper_ref_nodes: []const u32 = &.{},
    /// Generated references marked as explicit globals (sorted, ascending).
    /// Resync must keep them external even when a source scope declares the same name.
    explicit_global_ref_nodes: []const u32 = &.{},
    cjs_export_assignment_references: []const @import("../transformer/cjs_export_assignment.zig").ModuleReference = &.{},
    /// Scope owner nodes whose name lookup was marked dynamic because opaque
    /// define text cannot represent its lexical references in the AST.
    /// Full semantic resync reapplies the dynamic-name flags by these owners.
    opaque_define_scope_owner_nodes: []const u32 = &.{},
    /// Destructuring-produced local temp binding nodes (exact NodeIndex).
    destructuring_temp_bindings: std.AutoHashMapUnmanaged(u32, void) = .empty,
    /// Exact emitted binding nodes whose source SymbolId preserved a class
    /// constructor name. Post-transform analysis must restore that flag.
    preserved_class_name_nodes: []const u32 = &.{},
    /// Exact Reanimated class-factory bindings whose linker naming metadata
    /// must survive post-transform semantic reanalysis.
    worklet_factory_local_bindings: []const WorkletFactoryLocalBinding = &.{},
    /// Exact generated bindings whose deferred output-name hints must be
    /// restored by binding NodeIndex after reanalysis.
    post_graph_output_bindings: []const PostGraphOutputBinding = &.{},
    /// Exact generated JSX/runtime import locals whose deferred output names
    /// must be restored by NodeIndex after semantic reanalysis.
    runtime_helper_import_output_bindings: []const RuntimeHelperImportOutputBinding = &.{},
    /// #3267 N-step4 follow-up: prepass minify 의 cascade ref decrement 결과
    /// (`MinifyCtx.ref_deltas` snapshot, length == sem.symbols.len). emitter 의 minify
    /// 가 fresh ctx 에 hydrate 하여 prepass 에서 fold 된 dead branch 안 ref 감산
    /// 결과를 인계받고, 그 cascade 로 만들어진 dead binding 을 emitter 의 dead-store
    /// pass 가 elide 한다. 비어있으면 hydrate 비활성 (기존 동작 유지).
    ref_deltas: []const u32 = &.{},
};

/// `Module.parse_arena` 용 ArenaAllocator 를 heap 에 생성. 실패 시 null.
/// 정리는 `destroyParseArena` 로.
pub fn createParseArena(allocator: std.mem.Allocator) ?*std.heap.ArenaAllocator {
    const ptr = allocator.create(std.heap.ArenaAllocator) catch return null;
    ptr.* = std.heap.ArenaAllocator.init(allocator);
    return ptr;
}

/// `createParseArena` 의 짝. arena 데이터 free 후 ptr 자체 free.
pub fn destroyParseArena(allocator: std.mem.Allocator, arena: *std.heap.ArenaAllocator) void {
    arena.deinit();
    allocator.destroy(arena);
}

/// #4598: `await init_X()` 를 낼 수 있는가 — **이 질문의 유일한 답변자**.
///
/// 예전엔 같은 판정이 5곳(`appendEsmInitCall` · `appendWrappedInitCall` ·
/// `buildRequireRewrites` · lazy ESM import · default re-export)에 **서로 다른 조건**으로
/// 흩어져 있었다. 그래서 어떤 곳은 non-async 문맥에 `await` 를 넣어 번들을 파싱 불가로
/// 만들고, 어떤 곳은 async 인데 `await` 를 빼먹어 **조용한 `undefined`** 를 만들었다.
/// 새 호출부가 생기면 반드시 이 함수를 쓸 것 — 조건을 손으로 다시 적지 말 것.
///
/// 두 축을 모두 만족해야 한다:
///   ① **target 이 기다릴 대상을 준다** — 초기화 완료 promise 를 돌려주는 `__esm` 래퍼.
///      `__commonJS` 는 factory 반환값을 버리므로 promise 를 못 흘린다.
///   ② **importer 가 그 await 를 담을 수 있다** — 자기 factory 가 async 인 `__esm` 래퍼.
///      async 문법이 없는 타겟(es5)은 factory 를 async 로 못 만든다.
pub fn isAwaitableInit(
    target: *const Module,
    importer: *const Module,
    unsupported: @import("../transformer/transformer.zig").TransformOptions.compat.UnsupportedFeatures,
) bool {
    // ① target 이 기다릴 대상(초기화 완료 promise)을 주는가.
    //    `__commonJS` 는 factory 반환값을 버려 promise 를 못 흘린다.
    if (target.wrap_kind != .esm) return false;
    if (!(target.uses_top_level_await or target.in_async_cone)) return false;

    // ② importer 가 그 await 를 담을 수 있는가.
    //
    // ⚠️ **네이티브 TLA 를 쓰는 타겟(es2022+)에서는 importer 를 따지면 안 된다.** 거기선
    //    모듈 최상위 await 가 합법이라 scope-hoist importer 도 그냥 쓸 수 있다. importer
    //    조건을 걸었더니 es2022 에서 `await init_X()` 가 사라져 값이 `undefined` 가 됐다
    //    (리뷰 실측: main `41` → `undefined`). 다운레벨 타겟에서만 문맥을 따진다.
    if (!unsupported.top_level_await) return true;

    // 다운레벨: async 문법이 없으면 factory 를 async 로 못 만든다.
    if (unsupported.async_await) return false;
    if (importer.wrap_kind != .esm) return false;
    if (!(importer.uses_top_level_await or importer.in_async_cone)) return false;
    return true;
}

pub const Module = struct {
    /// Exact identity for a TLA promise variable consumed by references that the
    /// bundler emits after AST code generation (`await <promise>` or
    /// `return <promise>`). Keep the binding node, SymbolId, and ScopeId together
    /// so the emitter never has to recover the target from generated text.
    pub const TlaPromiseReference = struct {
        binding_node_index: u32,
        symbol_id: SemanticSymbolId,
        scope_id: SemanticScopeId,
    };

    index: ModuleIndex,
    /// Registered code-generation identity; independent of source semantic data.
    codegen_output_owner: @import("codegen_output_domain.zig").Owner = .unassigned,
    codegen_output_domain: ?*@import("codegen_output_domain.zig").Domain = null,
    /// 절대 파일 경로. graph의 path_to_module 키와 동일한 메모리를 참조 (빌림).
    path: []const u8,
    /// dependency lookup 시작 디렉토리. null 이면 dirname(path)를 사용한다.
    /// preserve_symlinks=true 에서는 보통 null 로 두어 logical dirname 이 1차 기준이
    /// 되게 한다. realpath sibling lookup 은 resolver fallback 에서 처리한다.
    resolve_dir: ?[]const u8 = null,
    /// dev mode 모듈 ID. bundler에서 한 번 계산 (path의 서브슬라이스, 할당 없음).
    dev_id: []const u8 = "",
    /// 소스 코드. parse_arena에서 할당 (Module.arena가 소유).
    source: []const u8,
    /// Borrowed from this module's actual winning builtin load constructor.
    runtime_helper_source: ?@import("../runtime_helper_source_origin.zig").Origin = null,
    runtime_helper_cache_source: ?RuntimeHelperCacheSource = null,
    /// Arena-owned proof from this Module's actual decoded source installation.
    /// Never serialized or transferred to another Module owner.
    self_namespace_source_receipt: ?*const @import("self_namespace_ast.zig").RestoredSourceReceipt = null,
    /// JS plugin load/transform 이 반환한 Source Map V3 JSON chain.
    /// 순서는 transform 실행 순서이며 parse_arena 가 backing 을 소유한다.
    plugin_source_maps: []const []const u8 = &.{},
    /// JS plugin 이 load hook 의 `{ meta }` 로 부여한 모듈 메타데이터 (JSON 문자열).
    /// Rollup `ModuleInfo.meta` 호환. `getModuleInfo`(manualChunks / this.getModuleInfo)로 노출.
    /// (resolveId/transform meta merge 는 follow-up — 현재 load hook 만.)
    /// null = plugin 이 meta 미설정. parse_arena 가 backing 을 소유 (#1880 PR2).
    plugin_meta: ?[]const u8 = null,
    /// Rollup `syntheticNamedExports` (#3664 P2). null = 비활성. 그 외 = fallback 대상 export 이름
    /// — `syntheticNamedExports:true` 는 `"default"`, `syntheticNamedExports:'name'` 은 `"name"`.
    /// 정적으로 export 안 된 named import 를 이 export 의 member 로 해석(CJS fallback 과 동형이되
    /// 대상이 namespace 가 아니라 default/named export value). parse_arena 가 backing 소유.
    synthetic_named_exports: ?[]const u8 = null,
    /// 파싱된 AST. nodes/extra_data/string_table 의 backing 은 `parse_arena` 가 소유.
    ///
    /// ### Ownership 규약 (D1 디버그 인프라 — RFC #1672)
    /// - 소유자: `parse_arena`. `Module.deinit` / `graph.deinit` 시 arena 를 해제하면
    ///   ast 도 함께 free. 별도로 `ast.deinit()` 호출 금지.
    /// - 변이 경로: 현재는 `cloneForTransformer` 로 별도 allocator 에 복제된 AST 위에서
    ///   transformer 가 mutation. main 의 `Module.ast` 는 parse 직후 상태 유지.
    /// - D1 이 in-place 로 전환하면 transformer 가 이 `ast` 에 직접 append. 그때는
    ///   `transform_boundary` 로 parser 영역을 표시, `assertInvariants` 로 검증.
    /// - 재진입: code splitting 의 shared module 은 같은 `ast` 에 여러 chunk 경로로
    ///   접근할 수 있음. D1 완료 후 `transformed_root` cache 로 멱등 보장 예정.
    ast: ?Ast,
    /// import_scanner가 추출한 레코드. graph allocator에서 할당 (소스 텍스트를 참조).
    import_records: []ImportRecord,
    /// require.context matches 기반 추가 deps. `import_records` 와 분리되어 있어
    /// `import_bindings.import_record_index` / `scan_result.records` 같은 index-based
    /// 참조가 영향 받지 않음. parse_arena 소유.
    context_expansion_deps: []ImportRecord = &.{},
    /// 증분 cache-hit 모듈에서 resolver 재실행 없이 graph edge를 replay하기 위한
    /// path 기반 resolve 결과.
    ///
    /// ### Ownership 규약
    /// - 빌드 중: graph allocator 가 list backing + 각 `dep.path` 문자열을 소유.
    /// - putModule 시점에 store 로 shallow-copy 이전 (graph 쪽 view 는 `.empty` 로 비움).
    /// - cache-hit 시점에 store → graph 로 다시 이전 (store 쪽 view 는 `.empty` 로 비움).
    /// - graph.deinit / store.freeCachedModule 어느 쪽이든 한 번만 free 되도록 한 쪽 view
    ///   를 항상 `.empty` 로 유지해야 double-free 가 발생하지 않는다.
    resolved_deps: std.ArrayListUnmanaged(CachedResolvedDep) = .empty,
    /// 이 모듈이 다른 모듈의 require.context match 로 등록된 경우 true. tree-shaker 가
    /// static import 없어도 root 취급해 번들에서 제거 안 함 — runtime require 대상이므로
    /// 모든 export 가 사용 가능해야.
    is_context_dep: bool = false,
    /// 모듈별 Arena — Scanner/Parser/AST/Semantic 메모리를 소유. graph.deinit에서 해제.
    ///
    /// 포인터로 보관 — graph ↔ store 사이의 transfer 가 Module struct copy 로 일어나는데,
    /// `?ArenaAllocator` (value) 면 두 위치가 같은 buffer_list 를 가리키고 그 후 nullify
    /// 패턴으로 ownership 을 표현해도 어느 한쪽이 dangling 노드를 통해 다음 alloc 에서
    /// panic 한다 (#2694). ptr 으로 두면 struct copy 가 ptr 만 복사 — 두 위치가 같은
    /// 객체 참조하고 nullify 한 쪽이 ownership 박탈을 명확히 표현한다.
    parse_arena: ?*std.heap.ArenaAllocator,
    /// Semantic analyzer 결과 또는 AST-less 그래프 생성 심볼 저장소. parse_arena가 소유.
    semantic: ?ModuleSemanticData,
    /// Semantic Analyzer에서 사전 구축한 StmtInfo. parse_arena가 소유.
    /// tree_shaker가 AST를 다시 순회하지 않고 이 데이터를 사용한다.
    prebuilt_stmt_info: ?stmt_info_mod.ModuleStmtInfos = null,
    /// Scanner의 line offset 테이블. parse_arena가 소유. 소스맵 생성에 사용.
    /// line_offsets[i] = i번째 줄의 시작 byte offset.
    line_offsets: []const u32 = &.{},
    /// legal comment 텍스트 목록 (parse_arena 소유). eof/linked/external 모드에서 사용.
    legal_comments: []const []const u8 = &.{},
    /// import 바인딩 상세. graph allocator 소유 (소스 텍스트 참조).
    import_bindings: []ImportBinding = &.{},
    /// TypeScript: names this module exports only as types (`export interface
    /// T`, `export type U`) — judged on the source, since stripping types
    /// drops them from the transformed semantic. An import or re-export that
    /// resolves to one is a type and is elided, as tsc/esbuild do (#5583).
    ts_type_export_names: std.StringHashMapUnmanaged(void) = .empty,
    /// export 바인딩 상세. graph allocator 소유 (소스 텍스트 참조).
    export_bindings: []ExportBinding = &.{},
    /// `export_bindings.exported_name` 의 평탄 slice 프리컴퓨트 (ModuleInfo 노출용 #1883).
    /// graph allocator 소유. 이름 자체는 source/AST text 의 borrow 라 별도 free 불필요.
    exported_names: []const []const u8 = &.{},
    /// exported_name → export_bindings 의 idx. PR-Y1 (#3592 follow-up) — warm rebuild 의
    /// `requestedExportsForReExportRecord` 가 cross-product O(N×M) loop 라 47ms warm 의
    /// 66% 차지 (M4 측정). HashMap 으로 O(1) lookup.
    ///
    /// ECMAScript spec: 같은 exported_name 의 중복 export 는 parse-time syntax error 라
    /// **non-star eb 의 exported_name 은 unique 보장** → caller fallback 불필요. re_export_star
    /// (exported_name="") 는 *어떤* name 도 export 가능해 별도 path 로 처리 (caller).
    ///
    /// graph allocator 소유. PR-Y1 = populate 만 + caller 미사용 (dormant). PR-Y2 = caller 적용.
    export_index_by_name: ?std.StringHashMapUnmanaged(u32) = null,
    /// Bundler-local 합성 심볼 테이블 (cross-module linking용). #1328 Phase 1.
    /// graph allocator 소유. null = 미초기화 (asset/disabled 모듈 등).
    alias_table: ?AliasTable = null,

    /// graph parseModule 단계의 transformer pre-pass 결과 캐시 (#1961).
    /// null = pre-pass 미실행 (legacy 경로 또는 비-JS 모듈). emitter 는 set 이면
    /// transformer 재실행 안 하고 캐시된 root/helpers/symbol_ids 사용.
    transform_cache: ?TransformCache = null,

    /// PR #3738 (C6 perf): transform_prepass 의 binding_scanner 가 build 한
    /// `NamespaceAccessIndex` 를 linker 가 share — 모듈당 build 1회 절약.
    /// parse_arena 소유 — module deinit 시 자동 free.
    /// null = transform_prepass 미실행 또는 namespace import 없음 → linker 가 자체 build.
    namespace_access_index: ?@import("linker/namespace_access.zig").NamespaceAccessIndex = null,

    /// (#4544) tree-shake 가 이 모듈의 AST 에 **cross-module const** 값을 리터럴로 bake 했는지.
    /// baked 리터럴은 provider 의 `export const N` 값에 의존하는 **graph-derived** 산출물이라,
    /// 소비자 자기 mtime 키로 module_store 에 캐시하면 provider 변경 시 stale 해진다(#4535 2번째 층).
    /// true 인 모듈은 `transferModulesToStore` 가 캐시에서 제외(+기존 엔트리 evict) → 다음 warm 빌드가
    /// clean reparse 후 현재 provider 값으로 fresh 재-materialize. build-scope 플래그(store round-trip
    /// 안 함): cache-miss 재파스마다 false 로 초기화되고, cross-module bake 발생 시에만 set.
    const_baked: bool = false,

    /// (#4557 B-precise) `const_baked` 모듈이 bake 한 값이 의존하는 **provider 모듈 경로**(diskPath,
    /// query strip) 집합. const-materialize 가 소비자에 인라인한 cross-module const 의 re-export 체인
    /// 전체(소비자→직접 import 대상→중간 barrel→canonical origin)를 기록한다([1]). warm(증분) 빌드가
    /// 이 집합으로 **provider 가 실제 바뀔 때만** baked 소비자를 evict(전이 fixpoint) — provider
    /// 불변이면 캐시 hit(reparse 0). crude-b(#4544)의 무조건 evict 를 대체.
    ///
    /// **diskPath 도메인([2])**: changed_files/dirty 와 매칭하려면 query 없는 diskPath 여야 한다.
    ///
    /// **빈 채로 남으면 = crude-b 폴백([3])**: `const_baked=true` 인데 이 집합이 비면(다단 체인 미추적/
    /// dupe OOM/parse_arena 없음) provider 를 정밀히 모른다는 뜻 → `transferModulesToStore` 가 그 모듈을
    /// 캐시에서 제외(무조건 evict)해 다음 warm 이 clean reparse 하게 강제한다(staleness 원천 차단).
    ///
    /// **소유권**: `parse_arena` 에서 alloc (materialize 시 dupe). arena.deinit 가 일괄 해제하므로
    /// 개별 free 금지(#1287). module_store 로 round-trip 시엔 CachedModule.const_providers 가 store
    /// allocator 로 별도 dupe/free 해 보관(import_specifiers 미러). 이 build-scope 필드는 cache-miss
    /// 재파스마다 `&.{}` 로 초기화되고 bake 발생 시에만 채워진다.
    const_providers: []const []const u8 = &.{},

    /// 래핑 모듈의 `init_<path>` 함수 SymbolId. owner는 parsed semantic 또는 AST-less shell.
    /// null = exact wrapper identity 미등록 (allocInitName은 MissingWrapperSymbol로 실패).
    init_symbol: ?SemanticSymbolId = null,
    /// 래핑 모듈의 `exports_<path>` 객체 SymbolId.
    exports_symbol: ?SemanticSymbolId = null,
    /// CJS 래퍼의 `require_<path>` 함수 SymbolId.
    require_symbol: ?SemanticSymbolId = null,
    /// `__commonJS` 콜백의 암묵적 `exports`/`module` 매개변수 identity.
    /// 최상위 var/function 재선언은 해당 원본 SID를 공유하고, 그 외에는
    /// graph finalize가 module scope에 합성 매개변수 SID를 등록한다.
    cjs_wrapper_exports_parameter_symbol: ?SemanticSymbolId = null,
    cjs_wrapper_module_parameter_symbol: ?SemanticSymbolId = null,
    /// Synthetic identity for the graph-level `__commonJS`/`$cj` runtime
    /// factory preamble. The linker keeps this ID as the shared output binding
    /// across wrapper callsites, chunks, tree shaking, and cached graph rebuilds.
    cjs_runtime_factory_symbol: ?SemanticSymbolId = null,
    /// Synthetic identity for the graph-level binary asset helper preamble.
    /// The semantic-less asset callsite and helper declaration use its linker name.
    to_binary_runtime_symbol: ?SemanticSymbolId = null,
    /// Synthetic identity for the graph-level `__esm` runtime factory preamble.
    /// Wrapped ESM callsites and the raw helper declaration share its linker name.
    esm_runtime_factory_symbol: ?SemanticSymbolId = null,
    /// Exact identities for lexical locals in the raw CJS runtime helper body.
    cjs_runtime_internal_symbols: ?CjsRuntimeInternalSymbolIds = null,
    /// Exact identities for lexical locals in the raw ESM runtime helper body.
    esm_runtime_internal_symbols: ?EsmRuntimeInternalSymbolIds = null,
    /// Exact producer identities for bindings in the raw ESM interop preamble.
    esm_interop_runtime_helper_symbols: ?EsmInteropRuntimeHelperSymbolIds = null,
    /// Exact identities for lexical locals in raw ESM interop helper bodies.
    esm_interop_runtime_internal_symbols: ?EsmInteropRuntimeInternalSymbolIds = null,
    /// Exact identities for top-level locals in raw HMR runtime preambles.
    hmr_runtime_internal_symbols: ?HmrRuntimeInternalSymbolIds = null,
    /// Exact identity for the generated `createRequire` import local emitted
    /// in this module's output unit. The semantic row is detached from source
    /// AST scopes and is recovered by its typed synthetic kind after rebuilds.
    require_shim_local_symbol: ?SemanticSymbolId = null,

    /// Historical fresh-analysis comparison lives only in native test
    /// oracles. Production has no pending rename/SID correspondence state.
    legacy_rename_oracle: if (@import("builtin").is_test) struct {
        renames: RenameTable = .{},
        capture_seen: bool = false,
    } else struct {} = .{},

    /// 내가 import하는 모듈들 (순방향)
    dependencies: std.ArrayList(ModuleIndex),
    /// 나를 import하는 모듈들 (역방향, D078 HMR용)
    importers: std.ArrayList(ModuleIndex),
    /// 동적 import (별도 관리, code splitting용)
    dynamic_imports: std.ArrayList(ModuleIndex),
    /// 나를 dynamic import 하는 모듈들 (역방향). `ModuleGraph.linkDynamicImport` 가 채움.
    dynamic_importers: std.ArrayList(ModuleIndex),

    /// `this.emitFile({ type:'chunk', implicitlyLoadedAfterOneOf })` (Rollup #3606, #3664):
    /// 이 모듈이 implicitly 로드되기 전에 이들 중 하나가 먼저 로드돼 있다고 plugin 이 보장한 모듈들.
    /// injectEmittedChunks 가 채우고 getModuleInfo 가 보고(manualChunks meta). 데이터만 —
    /// 청크 중복제거 최적화는 follow-up.
    implicitly_loaded_after_one_of: std.ArrayList(ModuleIndex) = .empty,
    /// 위의 역방향 — 이 모듈이 먼저 로드된 뒤 implicitly 로드되는 모듈들.
    implicitly_loaded_before: std.ArrayList(ModuleIndex) = .empty,

    module_type: ModuleType,
    /// 모듈의 로딩 방식 (file/dataurl/text/binary/copy 등).
    /// addModule에서 확장자 또는 --loader 옵션으로 결정.
    loader: types.Loader = .none,
    /// loader 가 `--loader:.ext=…` 로 **명시** 지정된 것인가 (확장자 기본 테이블
    /// 추론이면 false). `--asset-inline-limit` 이 명시 지정을 존중하도록 하는
    /// 근거 — 자세한 건 types.ParsedLoader.explicit 참고 (#4466).
    loader_explicit: bool = false,
    /// 모듈의 export 방식 (CJS/ESM 판별)
    exports_kind: types.ExportsKind = .none,
    /// 모듈 래핑 방식 (CJS → __commonJS 팩토리 함수)
    wrap_kind: types.WrapKind = .none,
    /// scanner가 `module.exports`/`exports.*` 런타임 export 신호를 본 경우.
    /// export-star fallback은 빈 type barrel이 임의 이름을 claim하지 않도록 이 값으로 제한한다.
    has_cjs_export_signal: bool = false,
    /// scanner가 `exports.__esModule` / `module.exports.__esModule` / defineProperty marker 를 본 경우.
    /// CJS default interop 과 default-import property pruning 은 이 marker 를 존중해야 한다.
    has_esmodule_marker: bool = false,
    /// CJS default import를 `__toESM(require_x()).default` 대신 `require_x()`로 낮출 수 있는지.
    /// 직접 `module.exports = ...` shape이고 `__esModule`/exports member 신호가 없을 때만 true.
    can_skip_cjs_default_interop: bool = false,
    /// 모듈 정의 형식 (확장자/package.json 기반, Rolldown ModuleDefFormat)
    def_format: types.ModuleDefFormat = .unknown,
    /// Top-Level Await 사용 여부. TLA 모듈을 static import하는 모듈도 전이적으로 true.
    uses_top_level_await: bool = false,
    /// 이 모듈 *자신의* body 가 top-level await 를 쓰는지 — parse 가 설정하는 base 값
    /// (`uses_top_level_await` 의 transitive 전파 *전* 상태). `propagateTopLevelAwait` 가
    /// 매 빌드 시작 시 `uses_top_level_await = self_uses_top_level_await` 로 base 를 깐 뒤
    /// 전파한다. HMR 위상 보존(Phase B) 에서 unchanged 모듈은 reparse 되지 않아 직전 빌드의
    /// transitive true 가 stale 로 남는데(set-only 전파라 demote 없음), 이 base reset 이
    /// 그 stale 을 지운다. fresh full 빌드에선 `uses==self` 라 no-op.
    self_uses_top_level_await: bool = false,
    side_effects: bool,
    /// side_effects가 package.json `sideEffects` 필드에 의해 결정됐음을 표시.
    /// true면 tree-shaker의 auto-purity 분석이 이 값을 덮어쓸 수 없다.
    /// Rolldown `DeterminedSideEffects::UserDefined` 포팅.
    side_effects_user_defined: bool = false,
    /// `import x; export default x;` body mutation pattern (lodash-es lodash.default.js).
    /// `requested_exports.computeBarrelFlags` 가 export_bindings 순회로 한 번 결정해
    /// 캐시. graph link 결정 (`shouldLinkResolvedRecordForModule`) + tree_shaker 시드 게이트
    /// + tree_shaker default→default re-export propagation 세 hot-path 호출처가 공유.
    is_wrapper_barrel: bool = false,
    /// `.local` export binding (`export class`/`export const x = …`/`export function`) 보유 —
    /// 순수 re-export barrel 이 아니므로 `isLazyBarrelCandidate` 에서 제외 (body 가 import 참조).
    /// `is_wrapper_barrel` 과 같은 패스에서 채워지는 hot-path 캐시.
    has_local_export: bool = false,
    /// `export default <named-local>` (예: `var lib={}; ...; export default lib`,
    /// lodash-es lodash.default.js) — default export 가 합성 `_default` 표현식이
    /// 아니라 이름 있는 로컬 바인딩. wrapper-barrel mutation 정밀 lazy 의
    /// 소비자 `_.foo` 접근 분석 게이트 (linker `isEsmWrapperDefaultBinding`).
    /// `is_wrapper_barrel`(=`export {default} from` 형) 과 다른 패턴이라 별도 캐시.
    default_export_named_local: bool = false,
    /// platform=browser에서 Node 빌트인 모듈을 빈 CJS로 대체 (esbuild "(disabled)" 방식).
    /// AST가 없고, emitter가 빈 __commonJS wrapper를 출력한다.
    is_disabled: bool = false,
    /// try/catch 안의 optional unresolved dependency. Graph 상으론 disabled 모듈처럼 AST가
    /// 없지만, require 되는 순간 Node/Metro처럼 MODULE_NOT_FOUND 를 던져 catch 로 넘어가야 한다.
    disabled_throw_on_require: bool = false,
    /// `external` 패턴 매칭으로 번들에 포함되지 않는 모듈. graph 에는 phantom 으로 등록되어
    /// `meta.getModuleInfo` / `info.importedIds` 등 graph traversal API 의 1급 노드로 보이지만
    /// chunk 배정 / emit / tree-shake 에선 제외. AST 없음, source 없음, path = original specifier.
    is_external: bool = false,
    /// Lazy compilation(PR-3a) 의 미파싱 동적 청크 seed. 동적 `import()` 타겟이
    /// static 으로 도달되지 않아 미파싱으로 남은 모듈 — state=.ready, ast=null 이지만
    /// is_external 과 달리 "나중에 첫 GET 시 parse" 대상이다(PR-3b). chunk emit 은
    /// 이 모듈 코드를 stub 으로 둔다(미파싱이라 본문 없음).
    is_lazy_seed: bool = false,
    /// tree-shake 결과 — 번들에 포함된 모듈인지 (Rollup `info.isIncluded` 호환).
    /// `TreeShaker.analyze` 가 finalize 후 set. 기본 false 라 tree-shaking 비활성 시
    /// 의미 없음 — chunk gen 단계에서도 `m.side_effects or entry_set.isSet` 으로 항상 alive 처리.
    is_included: bool = false,
    /// counter$4 fix: tree_shaker.analyze 가 finalize 시점에 mirror — true 면 tree-shaker 가
    /// active 라 `is_included`/`reachable_stmts` 가 의미 있다. false 면 tree_shaking=false /
    /// dev_mode → 두 field 의 default 가 false/null 이라 잘못 dead 판정하면 안 됨 (fallback alive).
    tree_shaker_active: bool = false,
    /// 이 모듈의 statement-level reachability bitset. tree_shaker 가 mirror 한 borrowed
    /// 참조 — owner 는 `TreeShaker.reachable_stmts`. tree_shaker.deinit 후엔 dangling
    /// 이므로 mangle / link 단계에서만 사용. null 이면 tree-shake 미수행 / 정보 없음.
    /// `is_included=true` 라도 모듈 내부 statement 의 70~90%가 dead 인 UMD 라이브러리
    /// (three.module.js 등) 에서 mangle candidate 필터링에 사용.
    reachable_stmts: ?*const std.DynamicBitSet = null,
    /// symbol_index → declaration stmt_index 역매핑. tree_shaker 가 mirror 한 borrowed.
    /// `reachable_stmts` 와 짝. 둘 다 null 또는 둘 다 set.
    symbol_to_stmt: ?[]const ?u32 = null,
    /// package.json "module" 필드를 통해 resolve된 파일.
    /// .js 확장자라도 ESM으로 파싱해야 함.
    is_module_field: bool = false,
    /// 엔트리 포인트 여부. graph.build()에서 설정.
    /// esbuild의 entryPointKind과 동일 — 정렬 순서나 exec_index와 무관하게
    /// 엔트리를 100% 정확히 식별한다.
    is_entry_point: bool = false,
    /// 이 모듈의 top-level await 를 **청크 레벨 async factory 에 위임**했는지 (#4598).
    ///
    /// ⚠️ `uses_top_level_await` 를 재활용하면 안 된다. 그 플래그는 `appendModuleCall`
    /// (`await init_X()`)·`ZNTC0002` 경고 등 여러 경로가 읽어서, 값을 넓히면 의도치 않은
    /// 곳이 함께 바뀐다(4차 시도가 이걸로 회귀했다). 위임 사실만 담는 전용 필드로 둔다.
    tla_delegated_to_chunk: bool = false,

    /// #4598: 이 모듈이 **async cone** 안에 있는지 — top-level await 를 쓰는 모듈이거나,
    /// 그런 모듈을 **static import 또는 require 로** 소비하는 모듈.
    ///
    /// ⚠️ `uses_top_level_await` 와 별개 필드다. 그 플래그는 `appendModuleCall`
    /// (`await init_X()`) 등 여러 방출 경로가 읽어서, 전파 범위를 넓히면 의도치 않은 곳이
    /// 함께 바뀐다(#4598 4차 시도가 이걸로 회귀). cone 은 **판정 전용**이다.
    ///
    /// `uses_top_level_await` 와 달리 **require 엣지도 탄다** — CJS 모듈이 TLA 모듈을
    /// 동기 소비하는 위상을 잡아내야 하기 때문이다(Node 도 `ERR_REQUIRE_ASYNC_MODULE` 로 거부).
    in_async_cone: bool = false,

    /// #4598: `lowerProgram` 이 만든 async IIFE statement 의 AST 인덱스.
    /// `__esm` factory 방출 시 이 문장만 `return <expr>;` 로 바꿔 `init_X()` 가
    /// 초기화 완료 promise 를 돌려주게 한다. null 이면 해당 없음.
    tla_iife_stmt: ?u32 = null,
    /// Exact binding identity for emitter-added references to the TLA promise.
    /// This is populated from the transformed AST and semantic graph together
    /// with `tla_iife_stmt`.
    tla_promise_reference: ?TlaPromiseReference = null,
    /// Module Federation 연합 경계 모듈 (#3318 P1-1). `mf.exposes` 타겟 ∪
    /// `mf.shared` ∪ shared 전방-의존 폐포. P1-1 은 **표시·안정 ID 계산만**
    /// (분석) — 스코프 호이스팅 소거 제외 *enforcement*·container/manifest
    /// emit 은 P1-2+ 가 이 플래그/ID 를 소비. mf 미지정 시 항상 false →
    /// 비-MF 빌드 영향 0(구성상 회귀 없음).
    is_federation_boundary: bool = false,
    /// 경계 모듈의 안정 ID(`module_id.zig`, relative-path). is_federation_
    /// boundary=true 일 때만 set. graph allocator 소유. (#3318 P1-1)
    federation_id: ?[]const u8 = null,
    /// `mf.exposes` 타깃(shared-폐포 제외). P1-3: expose 모듈을 동적-import
    /// 타깃과 동일하게 자기 lazy 청크로 분리 → reg_id=federation_id 가 되어
    /// container.get 이 `__zntc_load_chunk().then(()=>__zntc_require(id))`
    /// (동적 wrapper) 재사용. boundary ⊇ expose (shared 는 expose 아님).
    is_federation_expose: bool = false,
    /// plugin `this.emitFile({ type: 'chunk' })` 로 별도 chunk 로 분리 요청된 모듈 (#1880 PR7-2b).
    /// build_flow 가 emit_store.chunks 의 id 를 graph 에서 찾아 set → chunk.zig 가 federation
    /// expose 와 동형으로 dynamic entry 로 분리. is_federation_expose 와 같은 lazy-chunk 경로.
    is_emitted_chunk_entry: bool = false,
    /// DFS 후위 순서 = ESM 실행 순서 (D058, D076).
    /// maxInt = 미방문 (DFS에서 할당되지 않음).
    ///
    /// #4520 이후로는 `import()` 로만 닿는 모듈에도 (정적 모듈을 모두 매긴 뒤에)
    /// 번호가 부여된다 — 그 서브그래프 안에서도 "의존성 먼저" 위상 순서를 지켜야
    /// 하기 때문. 따라서 **maxInt 여부를 "동적 도달 전용" 판별에 쓰면 안 된다**.
    /// 그 판별은 `only_dynamically_reached` 를 볼 것.
    exec_index: u32,
    /// 정적 import 체인(entry / emit chunk entry 기점)으로는 닿지 않고 `import()`
    /// 로만 도달하는 모듈 (#4520). finalizeGraph 의 정적 루트 DFS 가 끝난 시점에
    /// 미방문인 모듈이 여기 해당한다.
    ///
    /// 용도: 동적 로딩은 비동기라 TLA 가 동기 실행을 막지 않는다 — 비-ESM 출력의
    /// TLA 경고를 이 모듈들에 대해 억제. 예전엔 `exec_index == maxInt` 로 대신
    /// 판별했으나, #4520 이 그 모듈들에도 exec_index 를 부여하면서 명시 플래그로 분리.
    only_dynamically_reached: bool = false,
    /// 순환 참조 그룹 ID. 0 = 순환 없음 (D065)
    cycle_group: u32,
    state: State,
    /// 파일 mtime (나노초). graph.build / store 히트 경로에서 설정.
    /// 0 = 미확인 (가상 모듈, plugin 소스 등). compiled output cache key 구성에 사용.
    mtime: i128 = 0,
    /// #4438 디스크 캐시 무효화 키(parse 시 계산, parser flags 가 살아있을 때 캡처). 0 = 미설정
    /// (디스크 캐시 비활성 또는 가상 모듈). graph 의 디스크 store/load 가 이 키로 디스크를 조회.
    disk_cache_key: u64 = 0,
    /// file/copy 로더의 asset 출력 정보. null이면 asset이 아님.
    asset_data: ?AssetData = null,
    /// 이 asset 은 data URL 로 인라인하면 안 된다 (#4466).
    ///
    /// CSS 가 `url(./sprite.svg#icon)` / `url(./f.eot?#iefix)` 처럼 **suffix 를 달아**
    /// 참조하면, 인라인된 data URL 뒤에는 그 suffix 를 붙일 자리가 없다. 반드시
    /// 파일로 방출해야 `./sprite-a1b2c3d4.svg#icon` 이 성립한다. resolve 시점에
    /// prepareCssUrlAsset 이 세운다.
    asset_no_inline: bool = false,
    /// data URL 로 인라인된 asset 의 URL 원문 (`data:image/png;base64,…`).
    /// `.dataurl` 로더이거나, `--asset-inline-limit` 이하 크기라 자동 인라인된
    /// 경우에 설정된다. parse_arena 소유.
    ///
    /// 인라인된 asset 은 별도 파일을 만들지 않으므로 `asset_data` 가 null 이다.
    /// css_emitter 는 `asset_data` 가 있으면 파일 URL 을, 없고 이 값이 있으면
    /// data URL 을 `url()` 에 써넣는다 (#4466).
    asset_dataurl: []const u8 = "",
    /// RN AssetRegistry metadata (이미지 모듈만, asset_registry 활성 시). parse_arena 소유 —
    /// finalize 의 collectRnAssetMetadata 가 graph 단위 list 로 borrow 재수집하고, reparse/store
    /// 가 arena 라이프사이클로 자동 정합한다(위상 보존 경로에서 unchanged 모듈 metadata 보존).
    rn_asset_metadata: ?RnAssetMetadata = null,
    /// CSS 번들링 메타데이터. null이면 CSS 모듈이 아님.
    css_data: ?CssData = null,

    /// file/copy 로더용 asset 메타데이터. parse_arena 소유.
    /// emitter가 asset 파일을 출력 디렉토리에 복사할 때 사용.
    pub const AssetData = struct {
        /// 원본 파일 내용 (바이너리). parse_arena 할당.
        raw_content: []const u8,
        /// content hash (16진수 8자리)
        content_hash: [8]u8,
        /// 출력 파일명 (예: "logo-a1b2c3d4.png"). parse_arena 할당.
        output_name: []const u8,
        /// 원본 확장자 (dot 포함, 예: ".png")
        ext: []const u8,
        /// RN scale variants — 항상 오름차순. @2x/@3x 파일 발견 시 [1,2,3].
        /// Metro AssetRegistry의 `scales` 필드에 직렬화.
        scales: []const u32 = &.{1},
        /// scale > 1 variant 파일들. 각 항목이 별개 OutputFile로 emit되어
        /// RN 네이티브가 `logo@2x.png` 등의 이름으로 로드 가능하다.
        scale_variants: []const ScaleVariant = &.{},
        /// asset 파싱 시점의 원본 loader(.file/.copy). asset_registry 모드는 emit 후 loader 를
        /// .javascript 로 전환하므로, HMR 위상 보존 reparse 가 이 값으로 원본 loader 를 복원해
        /// parseAssetModule 재실행을 유도한다(없으면 바이너리를 raw JS 로 오파싱).
        original_loader: types.Loader = .file,
    };

    pub const ScaleVariant = struct {
        /// 변형 배율 (2, 3, ...). 1은 base asset이므로 여기 포함되지 않는다.
        scale: u32,
        /// 출력 파일명 (예: "logo@2x-a1b2c3d4.png"). parse_arena 할당.
        output_name: []const u8,
        /// 원본 파일 내용.
        raw_content: []const u8,
    };

    /// CSS 번들링 메타데이터. parseCssModule에서 설정.
    pub const CssData = struct {
        /// @import 규칙 개수. import_records 앞쪽 import_count 개가 `@import`,
        /// 그 뒤 url_count 개가 `.css_url` (본문 자산 참조).
        import_count: u32,
        /// 본문 `url()` / `image-set()` 자산 참조 개수 (#4466).
        url_count: u32 = 0,
        /// 마지막 @import 규칙 끝의 byte offset. emit 시 이 위치 이후부터 출력.
        strip_end: u32 = 0,
        /// 파일 상단 `@charset` / bare `@layer` 선언. strip_end 가 통째로
        /// 잘라 silent drop 되던 것을 emitter 가 본문 앞에 보존 emit 하도록
        /// 캡처 (#3747). parse_arena 소유 슬라이스, 모듈 수명 내 유효.
        prefix_decls: []const @import("css_scanner.zig").CssPrefixDecl = &.{},
    };

    pub const State = enum {
        /// 슬롯만 예약됨, 아직 파싱 안 됨
        reserved,
        /// 파싱 중
        parsing,
        /// 파싱 완료, AST/semantic 저장됨 (import 추출 전)
        parsed,
        /// import 추출 완료, 사용 가능
        ready,
    };

    /// Check that an emitter-side TLA reference still points at the binding
    /// and scope captured when the lowering created the promise variable.
    pub fn matchesTlaPromiseReference(self: *const Module, binding_node_index: u32) bool {
        const reference = self.tla_promise_reference orelse return false;
        if (reference.binding_node_index != binding_node_index) return false;
        const semantic = self.semantic orelse return false;
        const binding_index: usize = @intCast(binding_node_index);
        const symbol_index: usize = @backingInt(reference.symbol_id);
        if (binding_index >= semantic.symbol_ids.len or symbol_index >= semantic.symbols.items.len) return false;
        if (semantic.symbol_ids[binding_index] != @as(u32, @intCast(symbol_index))) return false;
        return semantic.symbols.items[symbol_index].scope_id == reference.scope_id;
    }

    /// 등록된 합성 심볼의 출력 이름을 반환. 링커/망글러가 canonical_name 을
    /// 주입한 경우 릴리즈/압축 출력에서는 그 이름을 우선 사용한다.
    /// 미등록이면 null.
    /// 반환 slice는 parse_arena가 소유 — 모듈 수명 내 유효.
    /// RFC #3940: rename 출처는 build-scope `rename_table` (Module 은 graph-scope 라 Linker
    /// 직접 참조 불가 → caller 가 `rt` 전달). `rt == null` 은 rename 이 아직/원래 없는 컨텍스트
    /// (finalize: mangle 전 / cjs_wrap: semantic 없음) — synthetic_name fallback. rename_table 이
    /// 단일 출처 (구 `Symbol.canonical_name` field 는 L.5c 에서 제거).
    fn syntheticName(self: *const Module, maybe_id: ?SemanticSymbolId, rt: ?*const RenameTable) ?[]const u8 {
        const id = maybe_id orelse return null;
        const sem = self.semantic orelse return null;
        const idx: u32 = @backingInt(id);
        if (idx >= sem.symbols.items.len) return null;
        if (rt) |t| {
            if (t.get(SymbolID.make(self.index, idx))) |n| if (n.len > 0) return n;
        }
        const name = sem.symbols.items[idx].synthetic_name;
        return if (name.len > 0) name else null;
    }

    pub const EsmRecordWrapperUse = enum { none, init_only, init_and_namespace };

    /// Binding-less record lowerers: bare imports evaluate, require also reads namespace.
    /// Binding/re-export/dynamic paths retain their own structured value-use planning.
    pub fn esmRecordWrapperUse(kind: types.ImportKind) EsmRecordWrapperUse {
        return switch (kind) {
            .side_effect => .init_only,
            .require => .init_and_namespace,
            .static_import, .dynamic_import, .re_export, .worker, .glob, .require_context, .css_url, .css_import => .none,
        };
    }

    /// A wrapper getter reads its binding's direct source namespace. The caller
    /// visits export bindings once, separately from ordinary import records.
    pub fn esmReExportWrapperSource(self: *const Module, binding: ExportBinding) ?ModuleIndex {
        if (self.wrap_kind != .esm) return null;
        const record_index = binding.import_record_index orelse return null;
        if (record_index >= self.import_records.len) return null;
        const source = self.import_records[record_index].resolved;
        return if (source.isNone()) null else source;
    }

    /// Graph-owned identity for a generated lexical ESM initialization call.
    pub fn esmInitSymbol(self: *const Module) !SymbolID {
        if (self.wrap_kind != .esm) return error.InvalidEsmInitOwner;
        const id = self.init_symbol orelse return error.MissingWrapperSymbol;
        const sem = self.semantic orelse return error.MissingWrapperSymbol;
        const raw = @backingInt(id);
        if (raw >= sem.symbols.items.len or sem.symbols.items[raw].synthetic_kind != .esm_init)
            return error.InvalidEsmInitOwner;
        return .{ .module = self.index, .inner = id };
    }

    pub fn esmNamespaceSymbol(self: *const Module) !SymbolID {
        if (self.wrap_kind != .esm) return error.InvalidEsmInitOwner;
        const id = self.exports_symbol orelse return error.MissingWrapperSymbol;
        const sem = self.semantic orelse return error.MissingWrapperSymbol;
        const raw = @backingInt(id);
        if (raw >= sem.symbols.items.len or sem.symbols.items[raw].synthetic_kind != .cjs_exports)
            return error.InvalidEsmInitOwner;
        return .{ .module = self.index, .inner = id };
    }

    pub fn esmWrapperName(self: *const Module, identity: SymbolID, rt: ?*const RenameTable) ![]const u8 {
        if (identity.module != self.index) return error.InvalidEsmInitOwner;
        if ((try self.esmInitSymbol()).eql(identity))
            return self.getInitName(rt) orelse error.MissingWrapperSymbol;
        if ((try self.esmNamespaceSymbol()).eql(identity))
            return self.getExportsName(rt) orelse error.MissingWrapperSymbol;
        return error.InvalidEsmInitOwner;
    }

    pub fn getInitName(self: *const Module, rt: ?*const RenameTable) ?[]const u8 {
        return self.syntheticName(self.init_symbol, rt);
    }

    /// 이 모듈이 ESM 순환 그룹의 일원인지. 0 = 순환 없음 (D065).
    pub fn isInCycle(self: *const Module) bool {
        return self.cycle_group != 0;
    }

    /// 모듈이 *user-declared pure* — package.json `"sideEffects": false` 가 명시되어
    /// "drop 가능" 신호를 준 경우. tree-shaker / module-level dead store 등 정밀 DCE
    /// 게이트가 공유. rolldown 의 `DeterminedSideEffects::UserDefined(false)` 와 동일.
    pub inline fn isUserDeclaredPure(self: *const Module) bool {
        return self.side_effects_user_defined and !self.side_effects;
    }

    /// 모듈이 *user-declared side-effectful* — package.json `sideEffects` 배열에
    /// 명시돼 top-level 실행 순서가 의미 있는 경우. inlineRequires lazy 대상에서
    /// 제외하는 게이트가 공유.
    pub inline fn isUserDeclaredSideEffectful(self: *const Module) bool {
        return self.side_effects and self.side_effects_user_defined;
    }

    /// member-augment 귀속 게이트: user-declared pure 모듈이고 크기 최적화
    /// (minify_syntax) 일 때만 top-level `X.member = pureRHS` 를 X 의
    /// augmentation 으로 귀속한다 (dev/non-minify 회귀 방지).
    pub inline fn memberAugmentGate(self: *const Module, minify_syntax: bool) bool {
        return self.isUserDeclaredPure() and minify_syntax;
    }

    /// `entry_error_guard` 활성 시 이 모듈의 init 호출을 `__zntc_guarded(...)` 로 wrap 할지 결정.
    /// TLA (`uses_top_level_await`) 인 ESM 모듈은 await 가 lambda 안에 못 들어가므로 wrap 안 함.
    /// `wrap_kind == .none` (래핑 없음) 도 호출할 init 함수 자체가 없어 wrap 무의미.
    pub fn shouldGuard(self: *const Module, error_guard: bool) bool {
        if (!error_guard) return false;
        if (!self.wrap_kind.isWrapped()) return false;
        if (self.wrap_kind == .esm and self.uses_top_level_await) return false;
        return true;
    }

    pub fn getExportsName(self: *const Module, rt: ?*const RenameTable) ?[]const u8 {
        return self.syntheticName(self.exports_symbol, rt);
    }

    pub fn getRequireName(self: *const Module, rt: ?*const RenameTable) ?[]const u8 {
        return self.syntheticName(self.require_symbol, rt);
    }

    /// 등록된 exact wrapper SymbolId의 이름만 반환한다. 심볼이 빠진 상태에서
    /// 경로 문자열로 이름을 추측하면 rename graph 밖의 참조가 생기므로 실패한다.
    pub fn allocInitName(self: *const Module, allocator: std.mem.Allocator, rt: ?*const RenameTable) WrapperNameError![]const u8 {
        if (self.getInitName(rt)) |n| return allocator.dupe(u8, n);
        return error.MissingWrapperSymbol;
    }

    pub fn allocExportsName(self: *const Module, allocator: std.mem.Allocator, rt: ?*const RenameTable) WrapperNameError![]const u8 {
        if (self.getExportsName(rt)) |n| return allocator.dupe(u8, n);
        return error.MissingWrapperSymbol;
    }

    pub fn allocRequireName(self: *const Module, allocator: std.mem.Allocator, rt: ?*const RenameTable) WrapperNameError![]const u8 {
        if (self.getRequireName(rt)) |n| return allocator.dupe(u8, n);
        return error.MissingWrapperSymbol;
    }

    /// Semantic 심볼 배열 slice. semantic이 없으면 빈 slice.
    /// `hasSyntheticDefault` 등 semantic-aware predicate 호출 시 편의.
    pub fn semanticSymbols(self: *const Module) []const Symbol {
        const sem = self.semantic orelse return &.{};
        return sem.symbols.items;
    }

    /// 이 모듈의 sym_idx binding 의 declaration stmt 가 emit 될 stmt 인지.
    /// `tree_shaker.reachable_stmts` 정보가 없거나 sym→stmt 매핑이 없으면 conservative
    /// 하게 true (가드 noop). mangle / namespace getter 가 dead binding 을 candidate
    /// 또는 dangling getter 로 만들지 않도록 일관 호출. tree_shaker.deinit 후엔
    /// borrowed pointer 가 dangling — caller 가 lifetime 관리.
    pub fn isStatementAliveBySym(self: *const Module, sym_idx: usize) bool {
        const s2s = self.symbol_to_stmt orelse return true;
        // counter$4 진짜 root cause: tree-shaker BFS 가 module 별 reachable_stmts 를 lazy-init
        // (seed 된 module 만). seed 안 된 module 은 reachable_stmts=null — *그 module 의 어떤
        // stmt 도 reachable 표시 안 됐다는 의미*.
        // tree_shaker_active=true 케이스: rs=null 이면 module 자체가 BFS 에서 unreached →
        //   진짜 dead. fallback true 는 false positive (namespace getter dangling 원인).
        // tree_shaker_active=false 케이스 (tree_shaking=false / dev_mode): 모든 module 의 rs=null
        //   이지만 *모두 alive*. fallback true 가 정답.
        const rs = self.reachable_stmts orelse {
            if (self.tree_shaker_active) return false; // active + unreached = dead
            return true; // inactive — fallback alive
        };
        if (sym_idx >= s2s.len) return true;
        const stmt_idx = s2s[sym_idx] orelse return true;
        return stmt_idx >= rs.capacity() or rs.isSet(stmt_idx);
    }

    /// ExportBinding의 exact semantic SymbolRef가 선언한 statement가 출력되는지 검사한다.
    /// export spelling이나 linker final name으로 scope_maps를 재검색하지 않는다.
    /// ID/map이 없거나 모듈 소유권이 다르면 보수적으로 살아 있다고 처리한다.
    pub fn isExportBindingAlive(self: *const Module, binding: ExportBinding) bool {
        if (binding.kind != .local) return true;
        return self.isBindingAliveBySymbol(binding.symbol);
    }

    /// Exact semantic SymbolRef가 선언한 statement가 출력되는지 검사한다.
    /// Missing/foreign IDs and incomplete semantic maps remain conservative.
    pub fn isBindingAliveBySymbol(self: *const Module, binding_symbol: symbol_mod.SymbolRef) bool {
        // counter$4 진짜 fix: tree_shaker_active && !is_included 면 module 자체가 emit 안 됨 →
        // 모든 binding dead. 이전엔 stmt-level reachable 만 봤지만 module 전체 drop 케이스
        // (effect-ts 의 `internal/metric.js` 가 namespace 합성 후 module 자체 drop) 에서
        // false negative — namespace getter 가 dangling.
        if (self.tree_shaker_active and !self.is_included) return false;
        if (binding_symbol.moduleIndex() != self.index) return true;
        const sem = self.semantic orelse return true;
        const sym_idx = binding_symbol.semanticIndex() orelse return true;
        if (sym_idx >= sem.symbols.items.len) return true;
        return self.isStatementAliveBySym(sym_idx);
    }

    /// exported_name으로 ExportBinding을 찾는다. #1338 Phase 4c-1 Export Registry.
    /// 선형 스캔 — 일반적으로 모듈당 export 수가 < 20 수준이라 충분히 빠름.
    /// 성능 프로파일에서 병목이 되면 내부적으로 HashMap 구축 가능 (R1 캡슐화).
    pub fn findExportBinding(self: *const Module, exported_name: []const u8) ?*const ExportBinding {
        for (self.export_bindings) |*eb| {
            if (std.mem.eql(u8, eb.exported_name, exported_name)) return eb;
        }
        return null;
    }

    /// Resolve a real local export to the semantic index already recorded by the
    /// export scanner. The exported spelling is the public lookup key; local names
    /// and scope maps must not be used to reconstruct the binding identity.
    pub fn findLocalExportSemanticIndex(self: *const Module, exported_name: []const u8) ?u32 {
        const eb = self.findExportBinding(exported_name) orelse return null;
        if (eb.kind != .local) return null;
        return self.exportBindingSemanticIndex(eb.*);
    }

    /// SymbolId → 이름. semantic Symbol.nameText 호출의 short-cut.
    /// 인덱스 범위 밖이거나 semantic 없으면 null.
    pub fn symbolName(self: *const Module, id: SemanticSymbolId) ?[]const u8 {
        const sem = self.semantic orelse return null;
        const idx: u32 = @backingInt(id);
        if (idx >= sem.symbols.items.len) return null;
        return self.symbolText(&sem.symbols.items[idx]);
    }

    /// SymbolRef가 semantic을 가리키면 Symbol.nameText, 아니면 null.
    fn refName(self: *const Module, ref: symbol_mod.SymbolRef) ?[]const u8 {
        const idx = ref.semanticIndex() orelse return null;
        const sem = self.semantic orelse return null;
        if (idx >= sem.symbols.items.len) return null;
        return self.symbolText(&sem.symbols.items[idx]);
    }

    /// Semantic symbol 이름을 모듈 AST 기준으로 읽는다.
    /// transformer/generated symbol 이름은 source span이 아니라 AST string_table span일 수 있다.
    fn symbolText(self: *const Module, sym: *const Symbol) ?[]const u8 {
        if (sym.synthetic_name.len > 0) return sym.synthetic_name;
        if (self.ast) |*ast| return ast.getText(sym.name);
        @panic("Module semantic symbol name requires AST text storage");
    }

    /// Compare the actual imported child with the scanner's ModuleExportName
    /// field. Identifier metadata is already StringValue. Literal metadata uses
    /// parser.moduleExportName's exact syntax-preserving representation; equal
    /// source syntax proves equal StringValue without decoding its data twice.
    fn importPropertyMatches(ast: *const Ast, index: @import("../parser/ast.zig").NodeIndex, value: []const u8) bool {
        if (index.isNone() or @backingInt(index) >= ast.nodes.items.len) return false;
        const node = ast.getNode(index);
        if (node.tag != .identifier_reference and node.tag != .binding_identifier and node.tag != .string_literal) return false;
        const name_span = if (node.tag == .string_literal) node.span else ast.identifierNameSpan(node);
        const from_table = name_span.start & Ast.STRING_TABLE_BIT != 0;
        if ((name_span.end & Ast.STRING_TABLE_BIT != 0) != from_table) return false;
        const start = name_span.start & ~Ast.STRING_TABLE_BIT;
        const end = name_span.end & ~Ast.STRING_TABLE_BIT;
        const text_len = if (from_table) ast.string_table.items.len else ast.source.len;
        if (start > end or end > text_len) return false;
        const raw = ast.getText(name_span);
        switch (node.tag) {
            .identifier_reference, .binding_identifier => return @import("../lexer/scanner.zig").Scanner.identifierValueEquals(raw, value),
            .string_literal => {
                if (raw.len < 2 or (raw[0] != '"' and raw[0] != 39) or raw[raw.len - 1] != raw[0]) return false;
                const inner = raw[1 .. raw.len - 1];
                if (std.mem.indexOfAny(u8, inner, "\\\"'") != null) return std.mem.eql(u8, raw, value);
                var plain = inner.len > 0;
                for (inner, 0..) |c, i| {
                    if (!(std.ascii.isAlphabetic(c) or c == '_' or c == '$' or (i > 0 and std.ascii.isDigit(c)))) plain = false;
                }
                if (plain) return std.mem.eql(u8, inner, value);
                return value.len == raw.len and value[0] == '"' and value[value.len - 1] == '"' and std.mem.eql(u8, inner, value[1 .. value.len - 1]);
            },
            else => return false,
        }
    }

    /// Check only the declaration supplied by the scanner. No AST-wide owner
    /// discovery or name-to-SID search participates in import authority.
    fn importBindingOwnsSource(self: *const Module, ib: ImportBinding, ast: *const Ast) bool {
        if (ib.local_role != .import_binding) return true; // typed storage handoff has its own declaration role
        const declaration = ib.local_declaration_node orelse return false;
        const local = ib.local_symbol_node orelse return false;
        // The source declaration may import the same property under several
        // distinct local names. A genuine sibling node/SID pair is not the
        // scanner's binding unless its original local datum also agrees.
        if (local.isNone() or @backingInt(local) >= ast.nodes.items.len) return false;
        const local_span = ast.identifierNameSpan(ast.getNode(local));
        const local_table = local_span.start & Ast.STRING_TABLE_BIT != 0;
        if ((local_span.end & Ast.STRING_TABLE_BIT != 0) != local_table) return false;
        const local_start = local_span.start & ~Ast.STRING_TABLE_BIT;
        const local_end = local_span.end & ~Ast.STRING_TABLE_BIT;
        const local_limit = if (local_table) ast.string_table.items.len else ast.source.len;
        if (local_start > local_end or local_end > local_limit) return false;
        if (!@import("../lexer/scanner.zig").Scanner.identifierValueEquals(ast.getText(local_span), ib.local_name)) return false;
        if (declaration.isNone() or @backingInt(declaration) >= ast.nodes.items.len or ib.import_record_index >= self.import_records.len) return false;
        const owner = ast.getNode(declaration);
        if (owner.tag != .import_declaration) return false;
        const e = owner.data.extra;
        if (e > ast.extra_data.items.len or ast.extra_data.items.len - e < 6) return false;
        const x = @import("../parser/module.zig").readImportDeclExtras(ast, e);
        if (x.specs_start > ast.extra_data.items.len or x.specs_len > ast.extra_data.items.len - x.specs_start) return false;
        const record = self.import_records[ib.import_record_index];
        if (record.source_node != x.source or x.source.isNone() or @backingInt(x.source) >= ast.nodes.items.len or ast.getNode(x.source).tag != .string_literal) return false;
        var matches: usize = 0;
        for (ast.extra_data.items[x.specs_start..][0..x.specs_len]) |raw| {
            if (raw >= ast.nodes.items.len) return false;
            const spec: @import("../parser/ast.zig").NodeIndex = @fromBackingInt(raw);
            const node = ast.getNode(spec);
            const actual_local = switch (node.tag) {
                .import_default_specifier, .import_namespace_specifier => spec,
                .import_specifier => if (!node.data.binary.right.isNone()) node.data.binary.right else node.data.binary.left,
                else => return false,
            };
            if (actual_local != local) continue;
            switch (node.tag) {
                .import_default_specifier => if (ib.kind != .default or !std.mem.eql(u8, ib.imported_name, "default")) return false,
                .import_namespace_specifier => if (ib.kind != .namespace or !std.mem.eql(u8, ib.imported_name, "*")) return false,
                .import_specifier => if (ib.kind != .named or node.data.binary.flags & @import("../parser/module.zig").SPEC_FLAG_TYPE_ONLY != 0 or !importPropertyMatches(ast, node.data.binary.left, ib.imported_name)) return false,
                else => unreachable,
            }
            matches += 1;
        }
        return matches == 1;
    }

    /// Validate the scanner-owned local node against the stored current-module
    /// reference before any canonical/output-name consumer may use it. A null
    /// canonical rename means no rename; it never relaxes identity validation.
    pub fn checkedImportBindingLocalName(self: *const Module, ib: ImportBinding) error{InvalidImportLocalSymbol}![]const u8 {
        if (self.semantic != null) {
            const actual = try self.checkedSourceImportLocalSymbol(ib);
            if (!actual.isValid() or !actual.eql(ib.local_symbol)) return error.InvalidImportLocalSymbol;
            return self.refName(actual) orelse error.InvalidImportLocalSymbol;
        }
        // Explicit graphless helper compatibility has no analyzer identity.
        if (ib.is_helper) return ib.local_name;
        return error.InvalidImportLocalSymbol;
    }

    /// Scanner-owned source identity is available before Linker publishes the
    /// derived local_symbol field. This entry never reads a spelling to find SID.
    pub fn checkedSourceImportLocalSymbol(self: *const Module, ib: ImportBinding) error{InvalidImportLocalSymbol}!symbol_mod.SymbolRef {
        const sem = self.semantic orelse return error.InvalidImportLocalSymbol;
        const ast = if (self.ast) |*value| value else return error.InvalidImportLocalSymbol;
        const actual = binding_scanner.resolveImportLocalSymbol(ib, .{ .module_index = self.index, .ast = ast, .symbol_ids = sem.symbol_ids, .symbols = sem.symbols.items });
        if (!actual.isValid() or !self.importBindingOwnsSource(ib, ast)) return error.InvalidImportLocalSymbol;
        return actual;
    }

    /// Existing infallible consumers retain a fail-closed contract. Output
    /// writers with an error channel use checkedImportBindingLocalName.
    pub fn importBindingLocalName(self: *const Module, ib: ImportBinding) []const u8 {
        return self.checkedImportBindingLocalName(ib) catch std.debug.panic(
            "import binding '{s}' in module '{s}' has invalid exact local identity",
            .{ ib.local_name, self.path },
        );
    }

    /// ExportBinding의 로컬 이름.
    /// `.local` export 는 semantic ref 가 있으면 canonical name 을 사용한다. semantic
    /// ref 가 없는 `.local` export 도 합법이다. 예: TypeScript namespace 내부 export 는
    /// scanner 가 저장한 `local_name` 이 emit 대상 이름이고 top-level semantic symbol 이
    /// 없을 수 있다. re-export 계열은 `local_name` 이 source module 의 exported name 을
    /// 의미하므로 semantic local ref 가 없는 것이 정상이다.
    pub fn exportBindingLocalName(self: *const Module, eb: ExportBinding) []const u8 {
        if (eb.kind != .local) return eb.local_name;
        return self.refName(eb.symbol) orelse eb.local_name;
    }

    /// (#4587 target a) preserve-modules CJS "exports-as-storage" 적격 판정.
    /// 재할당되는(`write_count > 0`) `.local` export 바인딩을 로컬 `var`/`let` 대신
    /// `exports.<name>` 를 저장소로 낮춘다: provider 는 `exports.A = ...` 로 저장하고,
    /// 소비자는 `require(...).A` 로 라이브 읽기. 이 술어는 provider rename 등록(metadata),
    /// 끝-할당 skip(emitter), 소비자 ns-access(chunks) 4곳이 **완전히 동일하게** 공유해야
    /// 정합이 유지된다.
    ///
    /// v1 스코프(엄격): `.local` + identity(`local_name == exported_name`) + `write_count > 0`
    /// + `!is_const && !is_function && !is_class` + 단순 `binding_identifier` 선언(destructuring
    /// 제외 — `exports.A` 를 pattern 안 식별자에 적용하면 `let {A: exports.A}` = SyntaxError).
    /// const/class/function 은 현행·#4584 로직을 그대로 유지하므로 절대 대상이 아니다.
    /// One shared nonlive authority for ordinary quoted CJS consumers/writers.
    /// The public key never chooses a symbol; the producer's exact local node
    /// must still carry the already selected export SymbolRef in this AST.
    pub const OrdinaryQuotedExport = struct { literal_syntax: []const u8, binding_value: []const u8 };

    pub fn ordinaryQuotedExportLiteral(self: *const Module, eb: ExportBinding) error{InvalidQuotedExportOrigin}!?OrdinaryQuotedExport {
        if (!eb.has_public_key_literal) {
            if (eb.public_key_literal != null or eb.public_key_origin != null or eb.public_key_binding_value != null) return error.InvalidQuotedExportOrigin;
            return null;
        }
        if (self.wrap_kind != .none or eb.kind != .local or
            std.mem.eql(u8, eb.exported_name, "default") or eb.hasSyntheticDefault(self.semanticSymbols())) return null;
        const sid = self.exportBindingSemanticIndex(eb) orelse return error.InvalidQuotedExportOrigin;
        const sem = self.semantic orelse return error.InvalidQuotedExportOrigin;
        const symbol = sem.symbols.items[sid];
        if (symbol.write_count != 0) return null;
        if (symbol.synthetic_kind != null or symbol.synthetic_name.len != 0) return error.InvalidQuotedExportOrigin;
        const origin = eb.public_key_origin orelse return error.InvalidQuotedExportOrigin;
        const ast = if (self.ast) |*actual| actual else return error.InvalidQuotedExportOrigin;
        if (origin.ast != ast) return error.InvalidQuotedExportOrigin;
        const spec = @backingInt(origin.specifier);
        const literal = @backingInt(origin.literal);
        const local_node = eb.local_symbol_node orelse return error.InvalidQuotedExportOrigin;
        const local = @backingInt(local_node);
        if (origin.specifier.isNone() or origin.literal.isNone() or local_node.isNone() or
            spec >= ast.nodes.items.len or literal >= ast.nodes.items.len or local >= ast.nodes.items.len or
            local >= sem.symbol_ids.len) return error.InvalidQuotedExportOrigin;
        const node = ast.nodes.items[spec];
        if (node.tag != .export_specifier or node.data.binary.left != local_node or
            node.data.binary.right != origin.literal or ast.nodes.items[literal].tag != .string_literal or
            sem.symbol_ids[local] != sid) return error.InvalidQuotedExportOrigin;
        const syntax = eb.public_key_literal orelse return error.InvalidQuotedExportOrigin;
        const span = ast.nodes.items[literal].span;
        if ((span.start & Ast.STRING_TABLE_BIT) != 0 or span.start > span.end or span.end > ast.source.len)
            return error.InvalidQuotedExportOrigin;
        const actual_syntax = ast.getText(span);
        if (syntax.ptr != actual_syntax.ptr or syntax.len != actual_syntax.len) return error.InvalidQuotedExportOrigin;
        var matches: usize = 0;
        for (self.export_bindings) |binding| {
            if (std.mem.eql(u8, binding.exported_name, eb.exported_name)) matches += 1;
        }
        if (matches != 1) return error.InvalidQuotedExportOrigin;
        const value = eb.public_key_binding_value orelse return error.InvalidQuotedExportOrigin;
        if (value.ptr != eb.local_name.ptr or value.len != eb.local_name.len) return error.InvalidQuotedExportOrigin;
        return .{ .literal_syntax = syntax, .binding_value = value };
    }

    pub fn exportBindingIsCjsStorage(self: *const Module, eb: ExportBinding) bool {
        // 래핑 모듈(__commonJS/__esm)은 본문이 클로저 안이라 codegen 의 storage 선언 변환
        // (bindings.zig, wrap_kind==.none 게이트)이 안 돈다 — 여기서 storage 로 표시하면
        // `let exports.A`(SyntaxError)가 되므로 **반드시** 함께 제외해 4곳 술어를 정합시킨다.
        if (self.wrap_kind != .none) return false;
        if (eb.kind != .local) return false;
        // The scanner already carries the exact local binding identity. Do not
        // reconstruct it from `local_name`: a stale or deliberately divergent
        // scope map must not redirect storage lowering to a different symbol.
        const sym_idx = self.exportBindingSemanticIndex(eb) orelse return false;
        const sem = self.semantic orelse return false;
        const sym = sem.symbols.items[sym_idx];
        const local = self.symbolText(&sym) orelse return false;
        // v1: identity export 만. aliased(`export { A as B }`)는 provider 가 storage 를 안 해
        // 소비자 ns-access 와 어긋나므로 제외. 이름 비교는 외부 export 계약만 판정하며
        // semantic symbol 선택에는 쓰지 않는다.
        if (!@import("../lexer/scanner.zig").Scanner.identifierValueEquals(local, eb.exported_name)) return false;
        if (sym.write_count == 0) return false;
        if (sym.decl_flags.is_const or sym.decl_flags.is_function or sym.decl_flags.is_class) return false;
        // v1: destructuring 선언(`export let { A } = obj`)은 제외. renames[sid]="exports.A" 를
        // pattern 안 식별자에 적용하면 SyntaxError 이므로 rename 자체를 등록하면 안 된다.
        // scan 시 declarator 구조에서 기록(binding_scanner/parser) — byte-span AST 재스캔 불요.
        if (eb.declared_via_pattern) return false;
        // (#4587 [4]) 초기값이 함수/화살표/클래스 표현식이면 제외 — `exports.f = () => 0` 로
        // 낮추면 NamedEvaluation 이 member target 이라 안 걸려 `f.name` 이 유실된다.
        // 제외 시 현행 로컬(`let f = () => 0` + 끝-할당) 유지 = `.name` 보존(무손실).
        if (eb.init_is_fn_or_class) return false;
        return true;
    }

    /// Return the scanner-owned semantic index for an export binding when it
    /// belongs to this module and still points into its semantic symbol table.
    /// This deliberately never re-searches `local_name` in `scope_maps`.
    pub fn exportBindingSemanticIndex(self: *const Module, eb: ExportBinding) ?u32 {
        const sym_idx = eb.symbol.semanticIndex() orelse return null;
        if (eb.symbol.moduleIndex() != self.index) return null;
        const sem = self.semantic orelse return null;
        if (sym_idx >= sem.symbols.items.len) return null;
        return sym_idx;
    }

    /// exported_name에 해당하는 SymbolRef 반환. 없으면 invalid.
    /// #1338 Phase 4c-1: 문자열 기반 lookup을 SymbolRef로 승격하기 위한 진입점.
    pub fn findExportSymbol(self: *const Module, exported_name: []const u8) symbol_mod.SymbolRef {
        if (self.findExportBinding(exported_name)) |eb| return eb.symbol;
        return symbol_mod.SymbolRef.invalid;
    }

    /// `import d from '<CJS>'` 를 `__toESM(require_x()).default` 대신 `require_x()` 로
    /// 낮출 수 있는지.
    ///
    /// `can_skip_cjs_default_interop` 가 importee 를 `module.exports = <값>` 한 형태로
    /// 좁혀 준다(`exports.x` 없음 · `__esModule` 없음). 그 shape 에서는 **두 interop 모드
    /// 모두** `.default` 가 `module.exports` 자신이다:
    ///   - babel: `__esModule` 이 없으므로 `__toESM` 이 `default = mod` 를 깐다
    ///   - node : 플래그와 무관하게 언제나 `default = mod`
    /// 따라서 importer 형식은 이 판단에 들어올 이유가 없다. 예전에는 `!isEsm()` 로 ESM
    /// importer 를 빼고 있었는데, 그건 "babel 모드인가" 의 대용이었고(그 시절 interop 은
    /// `isEsm()` 과 동치였다) 축약의 유효 조건은 아니었다.
    ///
    /// 호출처는 default import 에 한정해서 쓴다 — namespace 나 named 는 `__toESM` 이
    /// 만들어 주는 멤버 getter 가 필요하다.
    pub fn canUseDirectCjsDefaultImport(self: *const Module, importee: *const Module) bool {
        _ = self;
        return importee.wrap_kind == .cjs and importee.can_skip_cjs_default_interop;
    }

    /// `module.exports = ...` shape 한정 fast path (default import 의 `__toESM` skip).
    /// `__esModule` marker 또는 `exports.x` 할당이 같이 있으면 named export 가 진짜 있을 수 있어
    /// fast path 가 부정확해진다. wrap_kind 가 .cjs 인 모듈에만 의미 있음.
    pub fn computeCanSkipCjsDefaultInterop(
        is_cjs: bool,
        has_module_exports: bool,
        has_exports_dot: bool,
        has_esmodule_marker: bool,
    ) bool {
        return is_cjs and has_module_exports and !has_exports_dot and !has_esmodule_marker;
    }

    /// 번들 출력 순서 comparator.
    /// 래핑된 모듈(__esm/__commonJS)을 scope-hoisted 모듈보다 먼저 배치.
    /// var init_xxx = __esm(...) 선언이 init_xxx() 호출보다 앞에 와야 하므로,
    /// 같은 그룹 내에서는 exec_index 오름차순. exec_index 동률 (보통 dynamic-only
    /// 미방문 모듈의 maxInt 마커) 시 path 사전순 — worker race 비결정 차단.
    pub fn bundleOrderLessThan(_: void, a: *const Module, b: *const Module) bool {
        const a_wrapped = a.wrap_kind != .none;
        const b_wrapped = b.wrap_kind != .none;
        if (a_wrapped != b_wrapped) return a_wrapped;
        if (a.exec_index != b.exec_index) return a.exec_index < b.exec_index;
        return types.stringLessThan({}, a.path, b.path);
    }

    /// 파일시스템/파일명 계산에 쓸 경로 — Vite query-suffix 를 뗀 것 (#4467).
    ///
    /// `module.path` 는 `/abs/x.png?url` 처럼 query 를 **유지**한다 (같은 파일도
    /// query 마다 다른 모듈이라 dedup 키로 필요). 하지만 파일을 열거나 basename /
    /// extension 을 뽑을 때 그대로 쓰면 `x.png?url` 이라는 파일을 찾게 된다.
    pub fn diskPath(self: *const Module) []const u8 {
        return types.stripPathQuery(self.path);
    }

    pub fn init(index: ModuleIndex, path: []const u8) Module {
        return .{
            .codegen_output_owner = @import("codegen_output_domain.zig").newOwner(),
            .index = index,
            .path = path,
            .source = "",
            .ast = null,
            .import_records = &.{},
            .parse_arena = null,
            .semantic = null,
            .dependencies = .empty,
            .importers = .empty,
            .dynamic_imports = .empty,
            .dynamic_importers = .empty,
            .module_type = .unknown,
            .side_effects = true,
            .exec_index = std.math.maxInt(u32),
            .cycle_group = 0,
            .state = .reserved,
        };
    }

    /// 동적 import 추가.
    pub fn addDynamicImport(
        self: *Module,
        allocator: std.mem.Allocator,
        dep_index: ModuleIndex,
    ) !void {
        try self.dynamic_imports.append(allocator, dep_index);
    }

    /// 래퍼 키: dev_id가 있으면 사용, 없으면 basename.
    pub fn wrapperId(self: *const Module) []const u8 {
        return if (self.dev_id.len > 0) self.dev_id else std.fs.path.basename(self.path);
    }

    pub fn sourceDir(self: *const Module) []const u8 {
        return self.resolve_dir orelse std.fs.path.dirname(self.path) orelse ".";
    }

    pub fn deinit(self: *Module, allocator: std.mem.Allocator) void {
        if (self.codegen_output_domain) |domain| domain.destroy();
        self.codegen_output_domain = null;
        self.self_namespace_source_receipt = null;
        self.dependencies.deinit(allocator);
        self.importers.deinit(allocator);
        self.dynamic_imports.deinit(allocator);
        self.dynamic_importers.deinit(allocator);
        self.implicitly_loaded_after_one_of.deinit(allocator);
        self.implicitly_loaded_before.deinit(allocator);
        if (self.resolve_dir) |dir| allocator.free(dir);
        if (self.federation_id) |id| allocator.free(id); // #3318 P1-1 (setBoundary alloc)
        for (self.resolved_deps.items) |dep| {
            dep.path.deinit(allocator);
            if (dep.resolve_dir) |dir| dir.deinit(allocator);
        }
        self.resolved_deps.deinit(allocator);
        if (self.alias_table) |*t| t.deinit();
        if (self.export_index_by_name) |*map| map.deinit(allocator);
        // require.context: plugin 이 채운 outer slice + 각 inner string free (#1579 Phase 2).
        // contract: plugin 이 allocator 로 dupe 한 상태로 반환 → graph 가 일괄 해제.
        for (self.import_records) |record| {
            if (record.kind == .require_context) {
                if (record.context_matches) |matches| {
                    for (matches) |s| allocator.free(s);
                    allocator.free(matches);
                }
            }
        }
        // parse_arena가 Scanner/Parser/AST/source 메모리를 전부 소유.
        // ast.deinit()는 불필요 — arena.deinit()이 일괄 해제.
        if (self.parse_arena) |arena| destroyParseArena(allocator, arena);
    }

    /// Lazy 초기화. graph allocator로 합성 심볼 테이블을 만든다.
    /// 이미 있으면 no-op.
    pub fn ensureAliasTable(self: *Module, allocator: std.mem.Allocator) void {
        if (self.alias_table == null) {
            self.alias_table = AliasTable.init(allocator);
        }
    }
};

test "Module.importBindingLocalName allows helper binding local_name fallback" {
    var module = Module.init(@fromBackingInt(@intCast(0)), "synthetic.tsx");
    defer module.deinit(std.testing.allocator);

    const ib = ImportBinding{
        .kind = .named,
        .local_name = "_jsx",
        .imported_name = "jsx",
        .local_span = Span.EMPTY,
        .import_record_index = 0,
        .is_helper = true,
    };

    try std.testing.expectEqualStrings("_jsx", module.importBindingLocalName(ib));
}

test "Module.exportBindingLocalName keeps scanner local_name without semantic ref" {
    var module = Module.init(@fromBackingInt(@intCast(0)), "namespace.ts");
    defer module.deinit(std.testing.allocator);

    const eb = ExportBinding{
        .exported_name = "Red",
        .local_name = "Red",
        .local_span = Span.EMPTY,
        .kind = .local,
    };

    try std.testing.expectEqualStrings("Red", module.exportBindingLocalName(eb));
}

test "Module.exportBindingIsCjsStorage excludes non-eligible bindings (#4587)" {
    var module = Module.init(@fromBackingInt(@intCast(0)), "m.mjs");
    defer module.deinit(std.testing.allocator);
    // wrap_kind == .none (기본), semantic == null.

    const base = ExportBinding{
        .exported_name = "A",
        .local_name = "A",
        .local_span = Span.EMPTY,
        .kind = .local,
    };

    // re-export → storage 대상 아님
    {
        var eb = base;
        eb.kind = .re_export;
        try std.testing.expect(!module.exportBindingIsCjsStorage(eb));
    }
    // non-identity (export { A as B }) → 제외
    {
        var eb = base;
        eb.exported_name = "B";
        try std.testing.expect(!module.exportBindingIsCjsStorage(eb));
    }
    // destructuring 선언 (export let { A } = obj) → 제외(#5, SyntaxError 방지)
    {
        var eb = base;
        eb.declared_via_pattern = true;
        try std.testing.expect(!module.exportBindingIsCjsStorage(eb));
    }
    // 함수/화살표/클래스 초기값 → 제외(#4, NamedEvaluation 보존)
    {
        var eb = base;
        eb.init_is_fn_or_class = true;
        try std.testing.expect(!module.exportBindingIsCjsStorage(eb));
    }
    // 래핑 모듈(wrap_kind != .none) → 제외(codegen storage 변환이 안 돌아 SyntaxError 방지)
    {
        module.wrap_kind = .cjs;
        try std.testing.expect(!module.exportBindingIsCjsStorage(base));
        module.wrap_kind = .none;
    }
    // 위 가드를 모두 통과하는 shape 라도 semantic 이 없으면 false (write_count 판정 불가) —
    // 적격 판정은 semantic(write_count>0·비 const/fn/class)이 있어야 성립함을 확인.
    try std.testing.expect(!module.exportBindingIsCjsStorage(base));
}

test "Module.exportBindingIsCjsStorage uses the export SymbolId instead of a local-name re-search" {
    const allocator = std.testing.allocator;
    const SymbolKind = semantic_symbol.SymbolKind;

    var module = Module.init(@fromBackingInt(@as(u32, 0)), "m.mjs");
    defer module.deinit(allocator);

    const scope_maps = try allocator.alloc(std.StringHashMapUnmanaged(usize), 1);
    defer allocator.free(scope_maps);
    scope_maps[0] = .empty;
    defer scope_maps[0].deinit(allocator);
    // Deliberately point the source-name lookup at symbol 1. The ExportBinding
    // below owns symbol 0, so only the exact identity gives the right answer.
    try scope_maps[0].put(allocator, "A", 1);

    var semantic = ModuleSemanticData{
        .symbols = .empty,
        .scopes = &.{},
        .scope_maps = scope_maps,
        .exported_names = .empty,
        .symbol_ids = &.{},
        .unresolved_references = .empty,
    };
    defer semantic.symbols.deinit(allocator);
    try semantic.symbols.append(allocator, cjsStorageTestSymbol("A", .variable_let, 1));
    try semantic.symbols.append(allocator, cjsStorageTestSymbol("decoy", .variable_const, 0));
    module.semantic = semantic;

    const Scenario = struct {
        name: []const u8,
        target_kind: SymbolKind,
        target_writes: u32,
        decoy_kind: SymbolKind,
        decoy_writes: u32,
        declared_via_pattern: bool = false,
        init_is_fn_or_class: bool = false,
        expected_storage: bool,
    };
    const scenarios = [_]Scenario{
        .{ .name = "let over const", .target_kind = .variable_let, .target_writes = 1, .decoy_kind = .variable_const, .decoy_writes = 0, .expected_storage = true },
        .{ .name = "const over let", .target_kind = .variable_const, .target_writes = 1, .decoy_kind = .variable_let, .decoy_writes = 1, .expected_storage = false },
        .{ .name = "var over unwritten let", .target_kind = .variable_var, .target_writes = 1, .decoy_kind = .variable_let, .decoy_writes = 0, .expected_storage = true },
        .{ .name = "unwritten let over written var", .target_kind = .variable_let, .target_writes = 0, .decoy_kind = .variable_var, .decoy_writes = 2, .expected_storage = false },
        .{ .name = "written let over function", .target_kind = .variable_let, .target_writes = 2, .decoy_kind = .function_decl, .decoy_writes = 1, .expected_storage = true },
        .{ .name = "function over written let", .target_kind = .function_decl, .target_writes = 1, .decoy_kind = .variable_let, .decoy_writes = 2, .expected_storage = false },
        .{ .name = "class over written var", .target_kind = .class_decl, .target_writes = 1, .decoy_kind = .variable_var, .decoy_writes = 1, .expected_storage = false },
        .{ .name = "written var over class", .target_kind = .variable_var, .target_writes = 1, .decoy_kind = .class_decl, .decoy_writes = 1, .expected_storage = true },
        .{ .name = "frequently written let over const", .target_kind = .variable_let, .target_writes = 3, .decoy_kind = .variable_const, .decoy_writes = 1, .expected_storage = true },
        .{ .name = "const over frequently written let", .target_kind = .variable_const, .target_writes = 0, .decoy_kind = .variable_let, .decoy_writes = 4, .expected_storage = false },
        .{ .name = "pattern binding is not a storage target", .target_kind = .variable_let, .target_writes = 1, .decoy_kind = .variable_const, .decoy_writes = 0, .declared_via_pattern = true, .expected_storage = false },
        .{ .name = "function-valued initializer keeps named evaluation", .target_kind = .variable_let, .target_writes = 1, .decoy_kind = .variable_const, .decoy_writes = 0, .init_is_fn_or_class = true, .expected_storage = false },
    };

    var failures: usize = 0;
    for (scenarios) |scenario| {
        semantic.symbols.items[0] = cjsStorageTestSymbol("A", scenario.target_kind, scenario.target_writes);
        semantic.symbols.items[1] = cjsStorageTestSymbol("decoy", scenario.decoy_kind, scenario.decoy_writes);
        const binding = ExportBinding{
            .exported_name = "A",
            .local_name = "A",
            .local_span = Span.EMPTY,
            .kind = .local,
            .declared_via_pattern = scenario.declared_via_pattern,
            .init_is_fn_or_class = scenario.init_is_fn_or_class,
            .symbol = symbol_mod.SymbolRef.makeSemantic(module.index, 0),
        };
        const actual = module.exportBindingIsCjsStorage(binding);
        if (actual != scenario.expected_storage) {
            failures += 1;
            std.debug.print("CJS export identity case failed: {s}\n", .{scenario.name});
        }
    }
    try std.testing.expectEqual(@as(usize, 0), failures);

    // Restore an eligible target before checking the module and bounds guards.
    // Otherwise later scenarios could make a missing guard appear harmless.
    semantic.symbols.items[0] = cjsStorageTestSymbol("A", .variable_let, 1);

    const exact_binding = ExportBinding{
        .exported_name = "A",
        .local_name = "A",
        .local_span = Span.EMPTY,
        .kind = .local,
        .symbol = symbol_mod.SymbolRef.makeSemantic(module.index, 0),
    };
    try std.testing.expectEqual(@as(?u32, 0), module.exportBindingSemanticIndex(exact_binding));

    // local_name is scanner spelling, not an identity key. The exact semantic
    // symbol still identifies the exported binding when those spellings drift.
    var stale_local_name = exact_binding;
    stale_local_name.local_name = "decoy";
    try std.testing.expect(module.exportBindingIsCjsStorage(stale_local_name));

    var wrong_module = ExportBinding{
        .exported_name = "A",
        .local_name = "A",
        .local_span = Span.EMPTY,
        .kind = .local,
        .symbol = symbol_mod.SymbolRef.makeSemantic(@fromBackingInt(@as(u32, 1)), 0),
    };
    try std.testing.expectEqual(@as(?u32, null), module.exportBindingSemanticIndex(wrong_module));
    try std.testing.expect(!module.exportBindingIsCjsStorage(wrong_module));
    wrong_module.symbol = symbol_mod.SymbolRef.invalid;
    try std.testing.expectEqual(@as(?u32, null), module.exportBindingSemanticIndex(wrong_module));
    try std.testing.expect(!module.exportBindingIsCjsStorage(wrong_module));

    wrong_module.symbol = symbol_mod.SymbolRef.makeSemantic(module.index, 2);
    try std.testing.expectEqual(@as(?u32, null), module.exportBindingSemanticIndex(wrong_module));
    try std.testing.expect(!module.exportBindingIsCjsStorage(wrong_module));

    var aliased = wrong_module;
    aliased.symbol = symbol_mod.SymbolRef.makeSemantic(module.index, 0);
    aliased.exported_name = "B";
    try std.testing.expect(!module.exportBindingIsCjsStorage(aliased));
}

fn cjsStorageTestSymbol(name: []const u8, kind: semantic_symbol.SymbolKind, write_count: u32) Symbol {
    return .{
        .name = Span.EMPTY,
        .scope_id = SemanticScopeId.none,
        .kind = kind,
        .decl_flags = kind.declFlags(),
        .declaration_span = Span.EMPTY,
        .write_count = write_count,
        .synthetic_name = name,
    };
}

test "semantic owner tokens are unique and saturate without ABA reuse" {
    var sequence = std.atomic.Value(u64).init(1);
    try std.testing.expectEqual(@as(u64, 1), @backingInt(nextSemanticOwnerToken(&sequence)));
    try std.testing.expectEqual(@as(u64, 2), @backingInt(nextSemanticOwnerToken(&sequence)));
    sequence.store(std.math.maxInt(u64) - 1, .monotonic);
    try std.testing.expectEqual(std.math.maxInt(u64) - 1, @backingInt(nextSemanticOwnerToken(&sequence)));
    try std.testing.expectEqual(SemanticOwnerToken.unassigned, nextSemanticOwnerToken(&sequence));
    try std.testing.expectEqual(SemanticOwnerToken.unassigned, nextSemanticOwnerToken(&sequence));
    try std.testing.expectEqual(std.math.maxInt(u64), sequence.load(.monotonic));
}

test "escaped mutable storage retains exact export identity and existing eligibility guards" {
    const a = std.testing.allocator;
    var module = Module.init(@fromBackingInt(@as(u32, 0)), "escaped.mjs");
    defer module.deinit(a);
    var sem: ModuleSemanticData = .{ .symbols = .empty, .scopes = &.{}, .scope_maps = &.{}, .exported_names = .empty, .symbol_ids = &.{}, .unresolved_references = .empty };
    defer sem.symbols.deinit(a);
    try sem.symbols.append(a, cjsStorageTestSymbol("\\uAC12", .variable_let, 1));
    try sem.symbols.append(a, cjsStorageTestSymbol("decoy", .variable_const, 0));
    module.semantic = sem;
    const binding: ExportBinding = .{ .exported_name = "값", .local_name = "decoy", .local_span = Span.EMPTY, .kind = .local, .symbol = symbol_mod.SymbolRef.makeSemantic(module.index, 0) };
    try std.testing.expect(module.exportBindingIsCjsStorage(binding));
    const kinds = [_]semantic_symbol.SymbolKind{ .variable_const, .function_decl, .class_decl };
    for (kinds) |kind| {
        sem.symbols.items[0] = cjsStorageTestSymbol("\\uAC12", kind, 1);
        try std.testing.expect(!module.exportBindingIsCjsStorage(binding));
        sem.symbols.items[0] = cjsStorageTestSymbol("\\uAC12", .variable_let, 1);
        try std.testing.expect(module.exportBindingIsCjsStorage(binding));
    }
    sem.symbols.items[0].write_count = 0;
    try std.testing.expect(!module.exportBindingIsCjsStorage(binding));
    sem.symbols.items[0].write_count = 1;
    try std.testing.expect(module.exportBindingIsCjsStorage(binding));
    for (0..8) |case| {
        var bad = binding;
        switch (case) {
            0 => bad.symbol = symbol_mod.SymbolRef.makeSemantic(@fromBackingInt(@as(u32, 1)), 0),
            1 => bad.symbol = symbol_mod.SymbolRef.invalid,
            2 => bad.symbol = symbol_mod.SymbolRef.makeSemantic(module.index, 2),
            3 => bad.declared_via_pattern = true,
            4 => bad.init_is_fn_or_class = true,
            5 => bad.exported_name = "alias",
            6 => bad.exported_name = "\\uAC12",
            7 => bad.kind = .re_export,
            else => unreachable,
        }
        try std.testing.expect(!module.exportBindingIsCjsStorage(bad));
        try std.testing.expect(module.exportBindingIsCjsStorage(binding));
    }
    module.wrap_kind = .cjs;
    try std.testing.expect(!module.exportBindingIsCjsStorage(binding));
    module.wrap_kind = .none;
    try std.testing.expect(module.exportBindingIsCjsStorage(binding));
    module.semantic = null;
    try std.testing.expect(!module.exportBindingIsCjsStorage(binding));
    module.semantic = sem;
    try std.testing.expect(module.exportBindingIsCjsStorage(binding));
    const malformed = [_]struct { raw: []const u8, value: []const u8 }{
        .{ .raw = "\xff", .value = "\xff" },
        .{ .raw = "\xc0\xaf", .value = "\xc0\xaf" },
        .{ .raw = "\xed\xa0\x80", .value = "\xed\xa0\x80" },
        .{ .raw = "\"a\"", .value = "\"a\"" },
        .{ .raw = "#a", .value = "#a" },
        .{ .raw = "\\u0061", .value = "\\u0061" },
        .{ .raw = "\\uD835\\uDC9C", .value = "𝒜" },
        .{ .raw = "\xf4\x90\x80\x80", .value = "\xf4\x90\x80\x80" },
    };
    for (malformed) |case| {
        sem.symbols.items[0] = cjsStorageTestSymbol(case.raw, .variable_let, 1);
        var bad = binding;
        bad.exported_name = case.value;
        try std.testing.expect(!module.exportBindingIsCjsStorage(bad));
        sem.symbols.items[0] = cjsStorageTestSymbol("\\uAC12", .variable_let, 1);
        try std.testing.expect(module.exportBindingIsCjsStorage(binding));
    }
}

test "escaped mutable storage actual Bundler preserves declaration and update values" {
    const cases = [_]struct { declaration: []const u8, update: []const u8, value: []const u8 }{
        .{ .declaration = "\\uAC12", .update = "값", .value = "값" },
        .{ .declaration = "값", .update = "\\uAC12", .value = "값" },
        .{ .declaration = "\\uAC12", .update = "\\uAC12", .value = "값" },
        .{ .declaration = "\\u{1D49C}", .update = "𝒜", .value = "𝒜" },
    };
    for (cases) |case| for ([_]bool{ false, true }) |minify| {
        try checkEscapedMutableStorage(case.declaration, case.update, case.value, minify);
    };
    std.debug.print("escaped mutable storage original source4 profiles2 native8\n", .{});
}

fn checkEscapedMutableStorage(declaration: []const u8, update: []const u8, value: []const u8, minify: bool) !void {
    const a = std.testing.allocator;
    const helpers = @import("test_helpers.zig");
    const Bundler = @import("bundler.zig").Bundler;
    errdefer std.debug.print("escaped mutable storage failed decoded_bytes={d} minify={any}\n", .{ value.len, minify });
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const source = try std.fmt.allocPrint(a, "export let {s}=6;export function bump(){{{s}++}}", .{ declaration, update });
    defer a.free(source);
    const entry_source = try std.fmt.allocPrint(a, "import{{{s} as value,bump}}from './dep.mjs';bump();console.log(value);", .{value});
    defer a.free(entry_source);
    try helpers.writeFile(tmp.dir, "package.json", "{\"type\":\"commonjs\"}");
    try helpers.writeFile(tmp.dir, "dep.mjs", source);
    try helpers.writeFile(tmp.dir, "entry.mjs", entry_source);
    const entry = try helpers.absPath(&tmp, "entry.mjs");
    defer a.free(entry);
    const native = try std.process.run(a, std.testing.io, .{ .argv = &.{ "node", entry } });
    defer a.free(native.stdout);
    defer a.free(native.stderr);
    try std.testing.expect(native.term == .exited and native.term.exited == 0);
    try std.testing.expectEqualStrings("7\n", native.stdout);
    var bundler = Bundler.init(a, .{ .entry_points = &.{entry}, .format = .cjs, .platform = .node, .preserve_modules = true, .minify_identifiers = minify });
    defer bundler.deinit();
    const result = try bundler.bundle(std.testing.io);
    defer result.deinit(a);
    try std.testing.expect(!result.hasErrors());
    const outputs = result.outputs orelse return error.MissingStorageModuleOutputs;
    for (outputs) |output| try helpers.writeFile(tmp.dir, std.fs.path.basename(output.path), output.contents);
    const emitted = try helpers.absPath(&tmp, "entry.js");
    defer a.free(emitted);
    const actual = try std.process.run(a, std.testing.io, .{ .argv = &.{ "node", emitted } });
    defer a.free(actual.stdout);
    defer a.free(actual.stderr);
    if (!(actual.term == .exited and actual.term.exited == 0)) std.debug.print("escaped mutable storage runtime: {s}\n", .{actual.stderr});
    try std.testing.expect(actual.term == .exited and actual.term.exited == 0);
    try std.testing.expectEqualStrings(native.stdout, actual.stdout);
}

test "escaped mutable storage actual long provider and consumer preserve live values" {
    const a = std.testing.allocator;
    const encodings = [_]struct { value: []const u8, raw: []const u8 }{
        .{ .value = "a", .raw = "\\u0061" },
        .{ .value = "é", .raw = "\\u00E9" },
        .{ .value = "𝒜", .raw = "\\u{1D49C}" },
    };
    for ([_]usize{ 255, 256, 257, 4096 }) |length| for (encodings) |encoding| {
        var raw: std.ArrayList(u8) = .empty;
        defer raw.deinit(a);
        var value: std.ArrayList(u8) = .empty;
        defer value.deinit(a);
        for (0..length / encoding.value.len) |_| {
            try raw.appendSlice(a, encoding.raw);
            try value.appendSlice(a, encoding.value);
        }
        for (0..length % encoding.value.len) |_| {
            try raw.append(a, 'a');
            try value.append(a, 'a');
        }
        try std.testing.expectEqual(length, value.items.len);
        for ([_]bool{ false, true }) |minify|
            try checkEscapedMutableStorage(raw.items, value.items, value.items, minify);
    };
    std.debug.print("escaped mutable storage long source12 profiles2 native24\n", .{});
}
