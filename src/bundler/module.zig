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
const binding_scanner = @import("binding_scanner.zig");
pub const ImportBinding = binding_scanner.ImportBinding;
pub const ExportBinding = binding_scanner.ExportBinding;
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

/// Semantic analyzer 결과. parse_arena가 소유하는 데이터의 참조.
/// linker가 import→export 연결 + 이름 충돌 해결에 사용.
pub const ModuleSemanticData = struct {
    /// Semantic 심볼 배열. parse_arena가 backing 메모리를 소유.
    /// #1328 Phase 4e-2 / RFC #1338: ArrayList로 보관하여 bundler가
    /// `extendSymbol`로 합성 심볼을 post-semantic 단계에 추가할 수 있게 한다.
    /// 읽기는 `.items` 사용.
    symbols: std.ArrayList(Symbol),
    scopes: []const Scope,
    /// 스코프별 이름→심볼 인덱스 조회. scope_maps[scope_id].get("x") → symbol index.
    scope_maps: []const std.StringHashMapUnmanaged(usize),
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

pub const Module = struct {
    index: ModuleIndex,
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
    /// semantic analyzer 결과. parse_arena가 소유. linker에서 사용.
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

    /// wrap_kind != .none 모듈의 `init_<path>` 함수 심볼 id (semantic 공간).
    /// null = 미래핑 또는 semantic 없음 (fallback: makeInitVarName 재할당).
    init_symbol: ?SemanticSymbolId = null,
    /// wrap_kind != .none 모듈의 `exports_<path>` 객체 심볼 id.
    exports_symbol: ?SemanticSymbolId = null,
    /// wrap_kind == .cjs 모듈의 `require_<path>` 함수 심볼 id.
    require_symbol: ?SemanticSymbolId = null,

    /// RFC #3940 L.5a — post-link tree-shake AST mutation 후 semantic resync 시 carry-over 된
    /// rename (SymbolID→name). tree_shaker(const linker)가 resync 전 `rename_table` 에서 캡처해
    /// new idx 로 채우고, bundler 의 post-shake finalize 가 `applyPendingRenames` 로 mutable
    /// `rename_table` 에 반영 후 비운다. value 는 `Linker.canonical_strings` borrow (같은 build
    /// finalize 내 소비). build-scope 라 store round-trip 전 반드시 clear (cross-build dangling 방지).
    /// 맵 backing 은 `parse_arena` 소유 — 개별 `deinit` 금지 (`arena.deinit` 가 일괄 해제, #1287).
    pending_renames: RenameTable = .{},

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
    exec_index: u32,
    /// 순환 참조 그룹 ID. 0 = 순환 없음 (D065)
    cycle_group: u32,
    state: State,
    /// 파일 mtime (나노초). graph.build / store 히트 경로에서 설정.
    /// 0 = 미확인 (가상 모듈, plugin 소스 등). compiled output cache key 구성에 사용.
    mtime: i128 = 0,
    /// file/copy 로더의 asset 출력 정보. null이면 asset이 아님.
    asset_data: ?AssetData = null,
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
        /// @import 규칙 개수.
        import_count: u32,
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
        const idx: u32 = @intFromEnum(id);
        if (idx >= sem.symbols.items.len) return null;
        if (rt) |t| {
            if (t.get(SymbolID.make(self.index, idx))) |n| if (n.len > 0) return n;
        }
        const name = sem.symbols.items[idx].synthetic_name;
        return if (name.len > 0) name else null;
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

    /// `getInitName()`의 할당 버전 — 등록된 경우 dupe, 아니면 fresh 생성.
    /// 기존 `types.makeInitVarName(alloc, path)` 호출지의 drop-in 대체.
    pub fn allocInitName(self: *const Module, allocator: std.mem.Allocator, rt: ?*const RenameTable) ![]const u8 {
        if (self.getInitName(rt)) |n| return allocator.dupe(u8, n);
        return types.makeInitVarName(allocator, self.path);
    }

    pub fn allocExportsName(self: *const Module, allocator: std.mem.Allocator, rt: ?*const RenameTable) ![]const u8 {
        if (self.getExportsName(rt)) |n| return allocator.dupe(u8, n);
        return types.makeExportsVarName(allocator, self.path);
    }

    pub fn allocRequireName(self: *const Module, allocator: std.mem.Allocator, rt: ?*const RenameTable) ![]const u8 {
        if (self.getRequireName(rt)) |n| return allocator.dupe(u8, n);
        return types.makeRequireVarName(allocator, self.path);
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

    /// `local_name` 으로 module-scope binding 을 찾아 declaration stmt reachability
    /// 검사. semantic / scope_maps 가 없으면 true. namespace getter 빌더 (esm_wrap,
    /// shared_namespace) 가 사용.
    ///
    /// `local_name` 이 *post-rename final name* (e.g. cross-module collision 회피 후
    /// `counter$4`) 인 경우 scope_maps lookup 이 fail (scope_maps 는 source name index).
    /// fallback 으로 root-scope symbol 들의 nameText 와 비교 — symbol.nameText 가
    /// rename 결과를 반영하므로 final name 매칭 가능. 이 fallback 이 없으면 namespace
    /// getter 가 dead declaration 을 reference (effect-ts 의 `counter$4 is not defined`
    /// 회귀 케이스).
    pub fn isLocalBindingAlive(self: *const Module, local_name: []const u8) bool {
        // counter$4 진짜 fix: tree_shaker_active && !is_included 면 module 자체가 emit 안 됨 →
        // 모든 binding dead. 이전엔 stmt-level reachable 만 봤지만 module 전체 drop 케이스
        // (effect-ts 의 `internal/metric.js` 가 namespace 합성 후 module 자체 drop) 에서
        // false negative — namespace getter 가 dangling.
        if (self.tree_shaker_active and !self.is_included) return false;
        const sem = self.semantic orelse return true;
        if (sem.scope_maps.len == 0) return true;
        if (sem.scope_maps[0].get(local_name)) |sym_idx| {
            return self.isStatementAliveBySym(sym_idx);
        }
        // Fallback 1: scope_maps lookup 실패 (post-rename name 등). root-scope symbol 들의
        // nameText 와 비교. symbol.nameText 가 rename 결과를 반영하므로 final name 매칭.
        for (sem.symbols.items, 0..) |sym, i| {
            if (!sym.scope_id.isNone()) {
                if (sym.scope_id.toIndex() != 0) continue;
            }
            const name = self.symbolText(&sym) orelse continue;
            if (std.mem.eql(u8, name, local_name)) {
                return self.isStatementAliveBySym(i);
            }
        }
        // Fallback 2: cross-module collision avoidance suffix (`$N`) 제거 후 다시 scope_maps
        // lookup. effect-ts 같이 다른 module 의 동일 export 와 충돌해 `counter$4` 같이 rename
        // 된 경우 — original `counter` 가 scope_maps 에 있어 정확한 reachability 판정 가능.
        var trimmed = local_name;
        if (std.mem.lastIndexOfScalar(u8, local_name, '$')) |dollar_idx| {
            const tail = local_name[dollar_idx + 1 ..];
            var all_digits = tail.len > 0;
            for (tail) |c| {
                if (c < '0' or c > '9') {
                    all_digits = false;
                    break;
                }
            }
            if (all_digits) trimmed = local_name[0..dollar_idx];
        }
        if (!std.mem.eql(u8, trimmed, local_name)) {
            if (sem.scope_maps[0].get(trimmed)) |sym_idx| {
                return self.isStatementAliveBySym(sym_idx);
            }
        }
        return true; // 모두 실패 — conservative true (false negative 회피)
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

    /// SymbolId → 이름. semantic Symbol.nameText 호출의 short-cut.
    /// 인덱스 범위 밖이거나 semantic 없으면 null.
    pub fn symbolName(self: *const Module, id: SemanticSymbolId) ?[]const u8 {
        const sem = self.semantic orelse return null;
        const idx: u32 = @intFromEnum(id);
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

    /// ImportBinding의 현재 모듈 로컬 이름.
    /// 일반 import 는 semantic ref 에서 이름을 가져온다. helper marker binding (JSX
    /// runtime / runtime helper) 은 user 가 같은 이름을 점유했을 때 semantic scope 에
    /// 로컬이 없을 수 있으므로 scanner 가 저장한 `local_name` 이 fallback.
    pub fn importBindingLocalName(self: *const Module, ib: ImportBinding) []const u8 {
        if (self.refName(ib.local_symbol)) |name| return name;
        if (ib.is_helper) return ib.local_name;
        std.debug.panic(
            "non-helper import binding '{s}' in module '{s}' has no semantic local symbol",
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

    /// exported_name에 해당하는 SymbolRef 반환. 없으면 invalid.
    /// #1338 Phase 4c-1: 문자열 기반 lookup을 SymbolRef로 승격하기 위한 진입점.
    pub fn findExportSymbol(self: *const Module, exported_name: []const u8) symbol_mod.SymbolRef {
        if (self.findExportBinding(exported_name)) |eb| return eb.symbol;
        return symbol_mod.SymbolRef.invalid;
    }

    pub fn canUseDirectCjsDefaultImport(self: *const Module, importee: *const Module) bool {
        return importee.wrap_kind == .cjs and
            importee.can_skip_cjs_default_interop and
            !self.def_format.isEsm();
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

    pub fn init(index: ModuleIndex, path: []const u8) Module {
        return .{
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
    var module = Module.init(@enumFromInt(0), "synthetic.tsx");
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
    var module = Module.init(@enumFromInt(0), "namespace.ts");
    defer module.deinit(std.testing.allocator);

    const eb = ExportBinding{
        .exported_name = "Red",
        .local_name = "Red",
        .local_span = Span.EMPTY,
        .kind = .local,
    };

    try std.testing.expectEqualStrings("Red", module.exportBindingLocalName(eb));
}
