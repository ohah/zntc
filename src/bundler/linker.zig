//! ZNTC Bundler — Linker
//!
//! 크로스 모듈 심볼 바인딩: 각 import를 대응하는 export에 연결한다.
//! re-export 체인을 따라가서 canonical export를 찾는다.
//!
//! 설계:
//!   - D059: Rolldown식 스코프 호이스팅
//!   - 메타데이터 방식: AST 수정 없이 codegen에서 치환
//!
//! 참고:
//!   - references/rolldown/crates/rolldown/src/stages/link_stage/bind_imports_and_exports.rs
//!   - references/esbuild/internal/linker/linker.go

const std = @import("std");
const spin = @import("../util/spin_lock.zig");
/// kill-switch: 보존-hit lNs 변경∪importer 한정 skip 을 끄고 전량 재계산(byte-identical 회귀
/// 진단/대조용). 설정 시 populateNamespaceAccesses 가 carrier 와 무관하게 모든 모듈 재계산.
const ns_access_skip_disabled = @import("../env_flag.zig").Once("ZNTC_NO_NS_ACCESS_SKIP");
const types = @import("types.zig");
const ModuleIndex = types.ModuleIndex;
const BundlerDiagnostic = types.BundlerDiagnostic;
const Module = @import("module.zig").Module;
const ModuleGraph = @import("graph.zig").ModuleGraph;
pub const ImportBinding = @import("binding_scanner.zig").ImportBinding;
const ExportBinding = @import("binding_scanner.zig").ExportBinding;
const Span = @import("../lexer/token.zig").Span;
const Ast = @import("../parser/ast.zig").Ast;
const semantic_symbol = @import("../semantic/symbol.zig");
const bundler_symbol = @import("symbol.zig");
const unified_mangler = @import("../codegen/unified_mangler.zig");
const profile = @import("../profile.zig");
const debug_log = @import("../debug_log.zig");
const CompiledModule = @import("compiled_module.zig").CompiledModule;
const rt_names = @import("../runtime_helper_names.zig");
const preamble_writer = @import("linker/preamble_writer.zig");
const namespace_access = @import("linker/namespace_access.zig");
const shared_namespace = @import("linker/shared_namespace.zig");
pub const PreambleWriter = preamble_writer.PreambleWriter;
pub const cjsImportNeedsToEsmInterop = preamble_writer.cjsImportNeedsToEsmInterop;
pub const LinkingMetadata = @import("linker/metadata_types.zig").LinkingMetadata;
pub const PreservedRenames = bundler_symbol.PreservedRenames;
pub const MangleReportCollector = @import("linker/mangle_report.zig").MangleReportCollector;
pub const MfStaticRemotes = @import("federation.zig").MfStaticRemotes;

/// namespace 접근 패턴에서 생성되는 변수 prefix.
/// metadata.zig, codegen.zig, emitter.zig에서 공유.
pub const NS_VAR_PREFIX = "__ns_";

/// CJS named import의 expression rename 형태: `require_xxx().prop`.
/// metadata.zig가 이 sentinel 형식으로 rename을 만들고 codegen이 substring 으로
/// 식별하므로 양쪽이 동일한 marker를 참조해야 한다.
pub const EXPR_RENAME_MARKER = "().";

/// `__ns_N.prop` 형태의 namespace-access rename 인지 판정.
pub inline fn isNamespaceRename(rename: []const u8) bool {
    return std.mem.startsWith(u8, rename, NS_VAR_PREFIX);
}

/// import 선언을 body에서 다시 emit하지 않아도 되는 expression rename인지 판정.
/// CJS named import는 `require_xxx().prop` 직접 참조로 치환되며, 별도 local
/// binding을 만들지 않는다. dev/HMR payload에서 원본 import가 CJS require로
/// 재출력되면 같은 binding을 중복 생성하므로 여기서 skip 대상으로 본다.
pub inline fn isImportExpressionRename(rename: []const u8) bool {
    return isNamespaceRename(rename) or std.mem.indexOf(u8, rename, EXPR_RENAME_MARKER) != null;
}

/// Metro inlineRequires가 eager/non-inline로 유지하는 RN core specifier.
/// 이 specifier들의 named CJS import는 `require_xxx().name` expression으로
/// 치환하지 않고 outer binding var를 만든다. 링커의 collision 수집과 metadata
/// preamble 생성이 같은 기준을 써야 한다.
const METRO_NON_INLINED_REQUIRE_SPECIFIERS = std.StaticStringMap(void).initComptime(.{
    .{ "React", {} },
    .{ "react", {} },
    .{ "react/jsx-dev-runtime", {} },
    .{ "react/jsx-runtime", {} },
    .{ "react-compiler-runtime", {} },
    .{ "react-native", {} },
});

pub inline fn isMetroNonInlinedRequireSpecifier(specifier: []const u8) bool {
    return METRO_NON_INLINED_REQUIRE_SPECIFIERS.has(specifier);
}

/// `Linker.collectUnifiedInput` 반환 컨테이너. unified_mangler.mangleAll 에
/// 그대로 넘길 수 있는 형태.
///
/// 수명 주의: `bitsets[i]` 는 `modules[i].module_scope_symbols` 의 backing
/// store. caller 는 `modules` 를 계속 사용하는 동안 `bitsets` 를 먼저
/// 해제해서는 안 된다. `deinit()` 이 올바른 순서로 처리.
pub const UnifiedCollect = struct {
    top_level_candidates: []@import("../codegen/unified_mangler.zig").TopLevelCandidate,
    modules: []@import("../codegen/unified_mangler.zig").ModuleMangleInput,
    bitsets: []std.DynamicBitSet,
    /// Phase A 의 base54 부여 시 회피해야 할 이름 (#2971): entry export name,
    /// import binding local name 등. 짧은 (1-char) 이름이 candidate 에서 제외되더라도
    /// reserved 에 들어가야 internal binding 의 mangle 결과가 동일 이름을 받지 않는다.
    /// string 자체는 module source 가 소유 — slice 만 owned.
    reserved_names: [][]const u8,
    /// `modules[i].cross_module_imports` 의 backing slice 들. modules 가 borrowed
    /// 라 별도 list 로 보관해 deinit 시 free.
    import_ref_slices: [][]const @import("../codegen/unified_mangler.zig").ImportRef,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *UnifiedCollect) void {
        self.allocator.free(self.top_level_candidates);
        self.allocator.free(self.modules);
        self.allocator.free(self.reserved_names);
        for (self.import_ref_slices) |s| self.allocator.free(s);
        self.allocator.free(self.import_ref_slices);
        for (self.bitsets) |*b| b.deinit();
        self.allocator.free(self.bitsets);
    }

    /// bitsets 소유권을 이전. 이후 `deinit` 이 bitsets 를 건드리지 않음.
    /// caller 가 각 bitset 과 slice 자체를 해제해야 함.
    pub fn takeBitsets(self: *UnifiedCollect) []std.DynamicBitSet {
        const b = self.bitsets;
        self.bitsets = &.{};
        return b;
    }
};

pub const SymbolRef = struct {
    module_index: ModuleIndex,
    /// 해당 모듈의 export 이름 (e.g. "x", "default")
    export_name: []const u8,
    /// Rollup `syntheticNamedExports` (#3664 P2). 정적으로 export 안 된 named import/re-export 가
    /// synthetic 모듈의 fallback 대상(default/named) export 의 member 일 때 그 member 이름.
    /// null = 일반 ref. 설정 시 codegen 은 `{module export local name}.{synthetic_member}` 로 rename.
    /// resolveExportChain 이 re-export 체인 끝에서 synthetic 을 만나면 채워 전달(직접 import·barrel
    /// forwarding 통합). HashMap 키/eql 에 안 쓰이므로 필드 추가 안전.
    synthetic_member: ?[]const u8 = null,
};

/// 해석된 import 바인딩. linker가 codegen에 전달.
pub const ResolvedBinding = struct {
    /// importer 모듈에서 사용하는 로컬 이름
    local_name: []const u8,
    /// 로컬 바인딩의 소스 위치 (rename 키)
    local_span: Span,
    /// 최종적으로 가리키는 export (re-export 체인 해결 후). synthetic 은 canonical.synthetic_member.
    canonical: SymbolRef,
};

pub const Linker = struct {
    allocator: std.mem.Allocator,
    /// Module storage 접근 포인터 (#1779 PR #2). 기존 `[]const Module` slice
    /// 필드를 대체. populate* 계열이 `moduleAtMut` 로 mutate 하므로 non-const.
    /// SegmentedList 교체 (#1779 PR #3) 시 Linker 는 건드리지 않아도 된다.
    graph: *ModuleGraph,
    /// 출력 포맷.
    format: types.Format,

    /// 모듈별 export 맵: "module_index\x00exported_name" → ExportEntry
    export_map: std.StringHashMapUnmanaged(ExportEntry) = .empty,

    /// import→export 바인딩 결과: (module_index, local_span_key) → ResolvedBinding
    resolved_bindings: std.AutoHashMapUnmanaged(BindingKey, ResolvedBinding) = .empty,

    diagnostics: std.ArrayList(BundlerDiagnostic),
    /// #1791 사용자 노출용 치명 진단 (예: IIFE 포맷에서 unresolved import).
    /// 기존 `diagnostics` 는 내부/테스트 전용 — bundler 가 BundleResult 로 wire 하지
    /// 않는다. 이 필드로 들어온 항목만 사용자에게 `build error` 로 노출된다.
    /// message 는 allocator 소유 (allocPrint) — linker.deinit 에서 일괄 해제.
    fatal_diagnostics: std.ArrayList(BundlerDiagnostic) = .empty,
    /// #1791 emitter 가 `emitModuleThread` 로 병렬 emit 중 `LinkingMetadata.pending_diagnostics`
    /// 를 linker 의 `fatal_diagnostics` 버퍼로 flush. 병렬 append 보호.
    diagnostics_mutex: spin.SpinLock = .{},

    /// rename_table value (최종 이름 string) 의 backing 저장소. linker가 소유 —
    /// deinit에서 일괄 해제. AliasTable.canonical_name은 caller-owned (별도 모델).
    canonical_strings: std.ArrayList([]const u8) = .empty,
    /// 충돌 검사용 set. 리네임 후보가 기존 canonical로 사용 중인지 O(1) 확인.
    /// 키는 canonical_strings가 소유 — 이 맵은 borrowed.
    canonical_names_used: std.StringHashMapUnmanaged(void) = .empty,

    /// RFC #3940 — build-scope `SymbolID → 최종 이름` 테이블. canonical write 단일 sink
    /// (`assignSymbolCanonical`) 가 기록한다. 값 string 은 borrow (canonical_strings 소유, 같은
    /// slice). `clearCanonicalNames` 시 함께 clear, `deinit` 에서 map 해제. emit/facade/dedup
    /// read 의 단일 출처 (L.5c 에서 `Symbol.canonical_name` field 제거 후 유일 rename store).
    rename_table: bundler_symbol.RenameTable = .{},

    /// 자동 수집된 예약 글로벌 이름. 모든 모듈의 unresolved references를 합친 것.
    /// scope hoisting 시 모듈 top-level 변수가 이 이름을 shadowing하면 리네임.
    reserved_globals: std.StringHashMapUnmanaged(void) = .empty,

    /// 외부에서 전달된 예약 전역 식별자 (--global-identifier).
    /// RN의 polyfillGlobal()로 등록되는 이름(Performance, EventCounts 등)을
    /// 모듈 변수로 사용하지 않도록 리네이밍.
    global_identifiers: []const []const u8 = &.{},

    /// RFC #3940 / 이슈 #4101 — cross-chunk 심볼 **전역 일관 네이밍**.
    /// `module_index → (export_name → 전역 이름)`. cross-chunk 로 노출/소비되는 심볼은
    /// provider/consumer 가 *같은* 이름을 써야 하는데, per-chunk `rename_table` 은 청크별로
    /// clear 되어 소비자가 provider 의 deconflict 이름을 못 본다(소비자 본문 collapse, #B).
    /// 이 맵은 cross-chunk 심볼만 **occupied 와 무관하게** 전역 deconflict 해(순환 끊기),
    /// per-chunk pass 가 reserved 로 받고 metadata/emit 이 참조할 단일 출처다.
    /// 값(전역 이름)은 이 맵이 소유(owned dupe) — borrowed-ptr UAF(#3933) 회피.
    /// **Inc-1: 채우기만(비활성 read)** — 동작 변경 0, 후속 increment 가 wire.
    cross_chunk_global_names: std.AutoHashMapUnmanaged(u32, std.StringHashMapUnmanaged([]const u8)) = .empty,
    /// #4101 ns collision: cross-chunk 전역명 deconflict 에서 *실제 동명 충돌*(예약어 회피
    /// 아님)이 1건이라도 발생했는지. true 일 때만 ns 객체 literal 을 finalize 에서 canonical
    /// 재빌드(getter 가 deconflict 된 inner const 참조) — 비충돌(대부분)은 frozen 유지해
    /// 재빌드 비용 0(#perf: RN/large 번들 finalize 회귀 방지).
    ns_collision_present: bool = false,

    /// computeRenames 동안만 사는 메모이즈: `module_index → 그 모듈의 nested scope(scope 0 제외)
    /// 바인딩 이름 union set`. `hasNestedBinding` 이 후보(`name$N`)마다 모듈의 모든 scope_maps 를
    /// 재스캔하던 것(rename당 O(scopes), cold lRen 의 ~83%)을 O(1) 멤버십으로 바꾼다. 키는 borrow
    /// (scope_maps 소유, semantic 수명 = graph > Linker). 빌드는 단일스레드 computeRenames 에서만,
    /// 조회는 const(레이스 없음). 캐시 미존재(per-chunk/빌드 전) 는 원본 스캔 fallback → byte-identical.
    nested_binding_cache: std.AutoHashMapUnmanaged(u32, std.StringHashMapUnmanaged(void)) = .empty,

    /// (#4120) `module_index → ChunkIndex` borrowed 슬라이스. `computeCrossChunkLinks` 직후
    /// bundler 가 `chunk_graph.module_to_chunk` 를 빌려 세팅 — emit 동안만 유효(소유권 X, free 금지).
    /// metadata 가 "consumer 모듈과 canonical CJS 모듈이 다른 청크인가"를 O(1) 판정해 cross-chunk
    /// CJS-interop preamble 을 억제(provider 청크가 진짜 바인딩 export → 일반 import)하는 데 쓴다.
    /// borrowed 라 finalize/단일번들 경로(splitting 아님)는 비워둔다(null) → 항상 same-chunk 취급.
    module_to_chunk: ?[]const types.ChunkIndex = null,

    /// dev mode: HMR용 모듈 참조를 __zntc_modules["id"].fn()으로 생성.
    /// init_xxx() 대신 동적 lookup을 사용하여 new Function()에서도 접근 가능.
    dev_mode: bool = false,
    /// code splitting emit 경로 여부. dev_mode 의 단일번들 HMR lowering
    /// (`__zntc_modules[dev_id]`)은 청크 경계를 넘지 못하므로(issue #4038),
    /// splitting 시엔 dev lowering 을 끄고 프로덕션 init(`init_X()`)을 쓴다.
    code_splitting: bool = false,

    /// Metro inlineRequires 호환 경로. RN에서는 함수 내부에서만 읽히는 import의
    /// module init을 top-level preamble에서 미루고, 참조 지점에서 lazy init한다.
    inline_requires: bool = false,

    /// 정적 import 평가 순서 보장. RN inlineRequires가 값 접근은 lazy로 유지해도
    /// static import 대상 모듈의 factory는 importer 본문 전에 한 번 실행해야 한다.
    strict_execution_order: bool = false,

    /// `EmitOptions.entry_error_guard` propagate. preamble 의 module init 호출을
    /// `__zntc_guarded(fn)` 으로 wrap 하여 outermost 에서 `ErrorUtils.reportFatalError`
    /// 로 swallow. helper 자체는 emitter prologue 에 주입.
    entry_error_guard: bool = false,

    /// #1621: minify 시 preamble/metadata 에서 __toESM/__toCommonJS 등을
    /// $tE/$tC 등 축약 이름으로 emit. bundler 가 `self.options.minify_whitespace`
    /// 를 linker 생성 직후 설정한다. dev_mode 에서는 `__zntc_g.__xxx` 경로를
    /// 사용하므로 이 플래그는 무시된다.
    minify_whitespace: bool = false,
    /// RN/Hermes: defineProperty 에 configurable:true 필요. G1-step2 의 ns arrow
    /// `__export` helper 변형 선택에 사용 (minify_whitespace 와 동일하게 생성 직후 set).
    configurable_exports: bool = false,

    /// --shim-missing-exports: missing export에 대해 `var xxx = void 0;` shim 생성.
    shim_missing_exports: bool = false,

    /// #1791 Phase D: value 참조가 0 인 import binding 을 preamble 생성에서 elide할지.
    /// tsconfig `verbatimModuleSyntax=true` 일 때는 transformer 와 동일하게 유지해
    /// 사용자 의도 (원본 import 보존) 를 존중한다. bundler 가 init 후 설정.
    verbatim_module_syntax: bool = false,

    /// emitter 가 TreeShaker 와 함께 호출됐는지. true 면 metadata builder 가 모듈의
    /// `is_included` 비트를 신뢰해 tree-shake 된 target 의 preamble emit 을 건너뛴다.
    /// false (linker 단독 빌드 / unit test) 면 기존 동작 유지.
    tree_shaker_active: bool = false,

    /// TreeShaker borrowed pointer — `tree_shaker_active=true` 일 때 set. metadata
    /// builder 의 namespace force_inline 결정이 `isExportUsed(mod, name)` 으로
    /// transitively used 여부 확인. unused namespace re-export 는 X_ns inline
    /// literal 생성 skip — namespace-heavy 라이브러리의 dead X_ns 제거.
    /// bundler 가 tree_shake.analyze() 후 set, deinit 전에 null 로 clear.
    tree_shaker: ?*const @import("tree_shaker.zig").TreeShaker = null,

    /// #1824 IIFE `--globals SPEC=GLOBAL` 매핑 (rollup `output.globals` 호환).
    /// `format == .iife` 일 때만 의미 있음. 매핑된 external specifier 는 UMD/AMD 와
    /// 동일한 factory-param preamble 경로로 처리되고, 매핑 안 된 external 은
    /// 기존 IIFE unresolved 에러 경로를 탄다. bundler 가 init 후 설정 — borrowed.
    iife_globals: []const types.GlobalEntry = &.{},

    /// PR-1 (#3459): MF host `mf.remotes` KV. 정적 `import X from
    /// "remote/x"` 의 unresolved external 을 metadata.zig 가 per-spec
    /// seam 글로벌(`__mf_remote_<san>`)로 매핑해 IIFE 에러를 회피.
    /// bundler 가 init 후 설정 — borrowed(opts.mf 소유). 비-MF 빌드는
    /// 빈 슬라이스 → 동작·출력 불변(무회귀).
    mf_remotes: []const types.MfBundleConfig.KV = &.{},

    /// --mangle-report 수집기 (#1760). `null` 이면 instrumentation skip.
    /// Bundler 가 생성 및 소유. Linker 는 참조만 보유.
    mangle_report: ?*MangleReportCollector = null,

    /// PR-2 (#3459): 정적 remote import specifier 수집기. metadata.zig
    /// 가 remote seam 합성 시 append → bundler 가 emitHostInit 에 전달.
    /// Bundler 소유, Linker 는 `?*` 참조(const-self 라도 pointee 변경 —
    /// mangle_report 선례). null=비-MF/비수집(동작 불변).
    mf_static_remotes: ?*MfStaticRemotes = null,

    /// #1760 Step 3c: `computeMangling` 이 mangleAll 결과 전체를 보관.
    /// `metadata.buildMetadataForAst` 이 현 모듈의 Phase B rename 을 여기서 조회.
    /// Phase A 와 Phase B 구분은 `unified_module_scopes[module_index]` bitset.
    unified_result: ?@import("../codegen/unified_mangler.zig").UnifiedMangleResult = null,
    /// 각 모듈의 module scope symbol bitset. `unified_result.renames` 의 entry 가
    /// Phase A (top-level) 인지 Phase B (nested) 인지 이 bitset 으로 판정.
    unified_module_scopes: []std.DynamicBitSet = &.{},

    /// resolveExportChain 메모이제이션 캐시.
    /// 키: makeModuleKeyBuf 형식 (4바이트 module_index + 0x00 + name).
    /// Phase 1(fixpoint) + Phase 2(BFS) 간 중복 resolve를 제거.
    /// re-export chain이 있을 때만 활성화 (단순 그래프에서는 오버헤드).
    chain_cache: std.StringHashMapUnmanaged(ChainCacheEntry) = .empty,
    chain_cache_enabled: bool = false,

    /// namespace import export 수집 캐시 (metadata.register_ns_rewrites hot path).
    /// 키: target_mod_idx. 같은 타겟을 여러 모듈이 namespace import 할 때
    /// `collectExportsRecursive` DFS 를 한 번만 수행하도록 linker 전역 공유.
    /// 값 slice 와 `owned=true` 인 local 문자열 모두 linker 소유 — deinit 에서 일괄 해제.
    /// Invariant: metadata 단계에서 append-only (put 만, remove/replace 없음).
    /// 슬라이스는 `allocator.dupe` 한 독립 할당이라 다른 키의 put 으로도 무효화되지 않음 —
    /// lock 해제 후에도 안전하게 읽기 가능.
    ns_export_cache: std.AutoHashMapUnmanaged(u32, []NsExportPair) = .empty,
    /// buildInlineObjectStr 결과 캐시. 키: target_mod_idx. 값 문자열 linker 소유.
    ns_inline_cache: std.AutoHashMapUnmanaged(u32, []const u8) = .empty,
    /// target module 별 공유 namespace object var. namespace 를 값으로 쓰는 여러 importer 가
    /// 같은 객체 선언을 중복 emit 하지 않도록 bundle/chunk preamble 에서 한 번만 쓴다.
    ns_shared_inline_cache: std.AutoHashMapUnmanaged(u32, SharedNsInline) = .empty,
    ns_shared_inline_order: std.ArrayListUnmanaged(u32) = .empty,
    ns_shared_var_names: std.StringHashMapUnmanaged(void) = .empty,
    /// (#3966) shared namespace var 이름의 결정적 충돌 해소. 같은 sanitized
    /// base (예: 서로 다른 디렉터리의 `core.js`) 를 갖는 모듈들 중 module_index
    /// (renumber 후 path-sorted, 결정적) 순서의 rank. rank>0 인 모듈만 저장
    /// (충돌 희소) — 부재 시 rank 0. 병렬 emit 의 first-come-first-served
    /// 이름 claim 이 `core_ns`/`core_ns_2` 를 run 마다 뒤바꾸던 비결정 제거.
    ns_base_rank: std.AutoHashMapUnmanaged(u32, u32) = .empty,
    ns_base_rank_built: bool = false,
    /// computeCrossChunkLinks(메타데이터 前 실행, chunk graph 보유)가 채우는
    /// "정의자 청크가 다른" namespace re-export target 집합. registerNamespace
    /// Rewrites 는 metadata 시점에 chunk 정보가 없으므로 이 집합으로 shared
    /// (cross-chunk, #3366) vs 비-shared(same-chunk self-contained, 타이밍
    /// 무관) inline 경로를 가른다 (#3367). 비어 있으면(splitting off 등)
    /// 전부 비-shared — 기존 단일번들 동작 유지.
    ns_cross_chunk_targets: std.AutoHashMapUnmanaged(u32, void) = .empty,
    use_shared_ns_preamble: bool = false,
    /// chunked(splitting) emit 경로 여부. 이 경로는 shared ns preamble 을
    /// per-module metadata **이전**에 emit 하므로, same-chunk target 은 정의자
    /// 청크 pre-materialize(#3366)가 닿지 않아 shared 가 타이밍상 빈다(#3367).
    /// 단일번들 경로(metadata 後 emit)는 무관해 false. useSharedNsInline 이 이
    /// 플래그로 경로를 가른다.
    ns_preamble_chunked: bool = false,
    /// ns_export_cache / ns_inline_cache 동시 접근 보호.
    /// emitter 가 `emitModuleThread` 로 buildMetadataForAst 를 병렬 호출하므로 필수.
    /// Fast path (get) → unlock → compute → lock → double-check → put 패턴으로
    /// DFS 자체는 lock 밖에서 수행해 경합 최소화.
    ns_cache_mutex: spin.SpinLock = .{},

    const ChainCacheEntry = struct {
        result: ?SymbolRef,
    };

    pub const SharedNsInline = struct {
        var_name: []const u8,
        object_literal: []const u8,
    };

    const ExportEntry = struct {
        binding: ExportBinding,
        module_index: ModuleIndex,
    };

    /// namespace 객체 preamble 생성 시 사용하는 export 쌍.
    pub const NsExportPair = struct {
        exported: []const u8,
        local: []const u8,
        /// buildInlineObjectStr에서 할당된 문자열인 경우 true.
        /// exports ArrayList 해제 시 owned=true인 local만 free.
        owned: bool = false,
        /// `import * as ns from './barrel'` 값 사용 시 namespace getter가 실제
        /// export source 모듈을 lazy init하기 위한 모듈 인덱스.
        init_mod: ?u32 = null,
        /// re_export_namespace (`export * as Foo from './src'`) / `import * as X; export {X}`
        /// 패턴에서 source 모듈 인덱스. registerNamespaceRewrites 가 이 정보로
        /// hoisted ns_var (예: `Foo_ns`) 를 한 번 declare 하고 inner_map 매핑을
        /// 변수명으로 둔다 (per-access inline literal 중복 emit 방지, #1928).
        ns_target_mod: ?u32 = null,
        /// (#4120) re-export 의 canonical 이 CJS 모듈인 경우 그 (module, export) ref. default/named
        /// 모두 런타임 interop 멤버라 진짜 로컬 바인딩이 없다(default=`_default` 미정의, named=
        /// `require_X().m` 표현식). `buildFinalExports`(entry/dynamic)가 이 ref 로 `var <syn> =
        /// <interop>;` materialize + 식별자 export 한다. 다른 caller(shared ns / fan-out)는 무시
        /// (기존 `local` 사용) — 순수 additive.
        cjs_interop: ?SymbolRef = null,
    };

    /// re-export 체인 순환 방지 깊이 제한.
    const max_chain_depth = 100;

    const BindingKey = struct {
        module_index: u32,
        span_key: u64,
    };

    pub fn init(allocator: std.mem.Allocator, graph: *ModuleGraph, format: types.Format) Linker {
        return initWithGlobalIdentifiers(allocator, graph, format, &.{});
    }

    pub fn initWithGlobalIdentifiers(allocator: std.mem.Allocator, graph: *ModuleGraph, format: types.Format, global_identifiers: []const []const u8) Linker {
        return .{
            .allocator = allocator,
            .graph = graph,
            .format = format,
            .export_map = .empty,
            .resolved_bindings = .empty,
            .diagnostics = .empty,
            .canonical_names_used = .empty,
            .reserved_globals = .empty,
            .global_identifiers = global_identifiers,
        };
    }

    /// per-emit format-dependent state set. 같은 Linker 가 다른 format 으로 reemit 될 때
    /// 매 emit 직전 호출. emit 루프 진입점에서 매 OutputConfig 마다 재호출 가능.
    pub const SetEmitFormatOpts = struct {
        iife_globals: []const types.GlobalEntry = &.{},
        mf_remotes: []const types.MfBundleConfig.KV = &.{},
        mf_static_remotes: ?*MfStaticRemotes = null,
        inline_requires: bool = false,
        entry_error_guard: bool = false,
    };

    pub fn setEmitFormat(self: *Linker, format: types.Format, opts: SetEmitFormatOpts) void {
        self.format = format;
        self.iife_globals = opts.iife_globals;
        self.mf_remotes = opts.mf_remotes;
        self.mf_static_remotes = opts.mf_static_remotes;
        self.inline_requires = opts.inline_requires;
        self.entry_error_guard = opts.entry_error_guard;
    }

    /// emit 경로별 transient state 초기화. splitting 경로가 set 한 ns_preamble_chunked /
    /// use_shared_ns_preamble 를 다음 emit 진입 전 reset. 단일 → 단일 reemit 시 stale 영향 차단.
    pub fn resetEmitTransients(self: *Linker) void {
        self.use_shared_ns_preamble = false;
        self.ns_preamble_chunked = false;
    }

    pub fn deinit(self: *Linker) void {
        if (self.unified_result) |*ur| ur.deinit();
        for (self.unified_module_scopes) |*b| b.deinit();
        if (self.unified_module_scopes.len > 0) self.allocator.free(self.unified_module_scopes);

        var eit = self.export_map.keyIterator();
        while (eit.next()) |key| {
            self.allocator.free(key.*);
        }
        self.export_map.deinit(self.allocator);
        self.resolved_bindings.deinit(self.allocator);
        for (self.canonical_strings.items) |s| self.allocator.free(s);
        self.canonical_strings.deinit(self.allocator);
        self.canonical_names_used.deinit(self.allocator);
        self.rename_table.deinit(self.allocator);
        self.reserved_globals.deinit(self.allocator);
        // nested-binding 캐시: inner set 해제(computeRenames 에러 경로 안전망; 정상 경로는 defer 가 이미 clear).
        self.clearNestedBindingCache();
        self.nested_binding_cache.deinit(self.allocator);
        // cross-chunk 전역 이름(#4101): owned value 해제 + inner/outer 맵 deinit.
        self.clearCrossChunkGlobalNames();
        self.cross_chunk_global_names.deinit(self.allocator);
        // chain_cache: 키는 allocator로 dupe됨
        var cc_it = self.chain_cache.keyIterator();
        while (cc_it.next()) |key| self.allocator.free(key.*);
        self.chain_cache.deinit(self.allocator);
        // ns_export_cache: 슬라이스 + owned local 해제
        var nec_it = self.ns_export_cache.iterator();
        while (nec_it.next()) |entry| {
            for (entry.value_ptr.*) |exp| {
                if (exp.owned) self.allocator.free(exp.local);
            }
            self.allocator.free(entry.value_ptr.*);
        }
        self.ns_export_cache.deinit(self.allocator);
        // ns_inline_cache: 문자열 해제
        var nic_it = self.ns_inline_cache.valueIterator();
        while (nic_it.next()) |v| self.allocator.free(v.*);
        self.ns_inline_cache.deinit(self.allocator);
        var ns_shared_it = self.ns_shared_inline_cache.valueIterator();
        while (ns_shared_it.next()) |v| {
            self.allocator.free(v.var_name);
            self.allocator.free(v.object_literal);
        }
        self.ns_shared_inline_cache.deinit(self.allocator);
        self.ns_shared_inline_order.deinit(self.allocator);
        self.ns_shared_var_names.deinit(self.allocator);
        self.ns_base_rank.deinit(self.allocator);
        self.ns_cross_chunk_targets.deinit(self.allocator);
        // #1791 fatal diag message 해제 (allocPrint owned)
        for (self.fatal_diagnostics.items) |d| self.allocator.free(d.message);
        self.fatal_diagnostics.deinit(self.allocator);
        self.diagnostics.deinit(self.allocator);
    }

    /// 내부 단축 helper. `self.graph.getModule(ModuleIndex.fromUsize(idx))` 의 반복 방지.
    pub inline fn getModule(self: *const Linker, idx: u32) ?*const Module {
        return self.graph.getModule(ModuleIndex.fromUsize(idx));
    }

    /// mutate 필요한 경로용.
    pub inline fn moduleAtMut(self: *const Linker, idx: u32) ?*Module {
        return self.graph.moduleAtMut(ModuleIndex.fromUsize(idx));
    }

    /// importer 의 import_record 가 가리키는 resolved source 모듈. 인덱스
    /// 범위 밖이거나 미해결이면 null.
    fn importedModule(self: *const Linker, importer: *const Module, record_idx: u32) ?*const Module {
        if (record_idx >= importer.import_records.len) return null;
        const src_idx = importer.import_records[record_idx].resolved;
        if (src_idx.isNone()) return null;
        return self.graph.getModule(src_idx);
    }

    fn isCjsDefaultBinding(self: *const Linker, importer: *const Module, ib: ImportBinding) bool {
        if (ib.kind != .default) return false;
        const src = self.importedModule(importer, ib.import_record_index) orelse return false;
        return src.wrap_kind == .cjs;
    }

    /// `import _ from './w'; _.foo()` 에서 source 가 `export default <named-local>`
    /// (예: `var lib={}; lib.foo=…; export default lib`, lodash-es lodash.default.js)
    /// 인 ESM default binding. CJS default 와 동일하게 scope-aware member 분석으로
    /// `namespace_used_properties` 를 채워, wrapper-barrel mutation 의 prop 단위
    /// 정밀 lazy 가 소비자 사용 prop 집합을 알 수 있게 한다.
    ///
    /// `is_wrapper_barrel` (=`export {default} from` re-export 형) 이 아니라
    /// `default_export_named_local` 를 본다 — 실제 mutation 패턴은 default 가
    /// 로컬 객체이고 `.local` export 라 `is_wrapper_barrel`/`isLazyBarrelCandidate`
    /// 가 false 이기 때문 (실측 확정).
    fn isEsmWrapperDefaultBinding(self: *const Linker, importer: *const Module, ib: ImportBinding) bool {
        if (ib.kind != .default) return false;
        const src = self.importedModule(importer, ib.import_record_index) orelse return false;
        return src.wrap_kind != .cjs and src.default_export_named_local;
    }

    /// `populateNamespaceAccesses` 의 analyze 대상 판별 — 4 kind 중 하나.
    /// PR #3737 의 `has_candidate` / `interest_set` / `should_analyze_binding` 가
    /// 동일한 판별을 사용하도록 helper 추출 (drift 방지).
    fn isNamespaceAnalysisCandidate(self: *const Linker, importer: *const Module, ib: ImportBinding) bool {
        if (ib.kind == .namespace) return true;
        if (ib.kind == .named and ib.namespace_used_properties == null) return true;
        if (self.isCjsDefaultBinding(importer, ib)) return true;
        if (self.isEsmWrapperDefaultBinding(importer, ib)) return true;
        return false;
    }

    /// 링킹 실행: export 맵 구축 → import 바인딩 해결.
    pub fn link(self: *Linker) !void {
        try self.buildExportMap();

        // re-export chain이 있으면 resolveExportChain 캐시 활성화.
        // 단순 그래프(re-export 없음)에서는 캐시 오버헤드가 이득보다 크므로 비활성.
        {
            var scan_scope = profile.begin(.link_chain_cache_scan);
            defer scan_scope.end();
            var it = self.graph.modulesIterator();
            while (it.next()) |m| {
                for (m.export_bindings) |eb| {
                    if (eb.kind.isAnyReExport()) {
                        self.chain_cache_enabled = true;
                        break;
                    }
                }
                if (self.chain_cache_enabled) break;
            }
        }

        try self.resolveImports();
    }

    /// 이름 충돌 감지 + 리네임에 사용하는 소유자 정보.
    const NameOwner = struct {
        module_index: u32,
        exec_index: u32,
        /// calculateRenames sort tie-break. exec_index 동률 시 path 사전순 (cross-chunk
        /// marker 는 ""), worker race 비결정성 방지.
        path: []const u8,
    };

    /// name_to_owners HashMap의 타입 별칭.
    pub const NameToOwnersMap = std.StringHashMapUnmanaged(std.ArrayList(NameOwner));

    /// name_to_owners에 (name, owner) 항목을 추가한다.
    fn addNameOwner(
        self: *const Linker,
        name_to_owners: *NameToOwnersMap,
        name: []const u8,
        owner: NameOwner,
    ) !void {
        const entry = try name_to_owners.getOrPut(self.allocator, name);
        if (!entry.found_existing) {
            entry.value_ptr.* = .empty;
        }
        try entry.value_ptr.append(self.allocator, owner);
    }

    /// 모듈의 top-level owner 이름을 **단일 출처**로 열거한다 (perf/hmr-link-rename-reuse).
    ///
    /// `collectModuleNames`(deconflict 입력 수집) 와 `buildRenameSnapshot` 의 fingerprint
    /// 빌더(G2 이름집합 해시) 가 *정확히 같은 필터* 를 봐야 한다 — 한쪽만 어떤 이름을
    /// 등록하면 가드가 거짓 통과/실패한다(드리프트=정확성 버그). 그래서 필터 로직을
    /// 여기 한 곳에 두고 양쪽이 호출한다.
    ///
    /// `cb(ctx, name)` 를 등록 대상 이름마다 호출한다. 두 소비자(collectModuleNames /
    /// fingerprint 빌더) 모두 이름만 필요하므로 sym_idx 는 노출하지 않는다.
    fn forEachTopLevelOwnerName(
        self: *Linker,
        m: Module,
        comptime Ctx: type,
        ctx: Ctx,
        comptime cb: fn (Ctx, []const u8) anyerror!void,
    ) !void {
        const sem = m.semantic orelse return;
        if (sem.scope_maps.len == 0) return;
        const module_scope = sem.scope_maps[0];

        var scope_it = module_scope.iterator();
        while (scope_it.next()) |scope_entry| {
            const sym_name = scope_entry.key_ptr.*;
            if (std.mem.eql(u8, sym_name, "default")) continue;

            // `_default` 합성 심볼은 scope_maps에도 등록되지만 owner 등록은 export_bindings
            // 경로(아래)에서 전담한다. 여기서도 등록하면 같은 모듈의 같은 이름이
            // 이중 owner가 되어 collectModuleNames 충돌 처리가 `_default$1` 접미사를
            // 생성한다 (#1598).
            const sym_idx_for_kind = scope_entry.value_ptr.*;
            if (sym_idx_for_kind < sem.symbols.items.len) {
                const sk = sem.symbols.items[sym_idx_for_kind].synthetic_kind;
                if (sk == .default_export) continue;
                if (m.wrap_kind == .cjs) {
                    // CJS 래퍼 내부의 사용자 로컬은 `__commonJS(function (...) { ... })`
                    // 안에 남으므로 번들 최상위 이름을 점유하지 않는다. 번들러가 직접
                    // 래퍼 밖에 emit하는 합성 심볼만 충돌 후보로 본다.
                    switch (sk orelse continue) {
                        .cjs_exports, .cjs_require, .esm_init => {},
                        else => continue,
                    }
                }
            }

            // import binding은 일반적으로 인라인되어 변수가 생성되지 않으므로 충돌 대상 아님.
            // 단, CJS 모듈을 import하면 preamble에서 `var X = require_xxx().X`로 변수가 생성되므로
            // 충돌 대상에 포함해야 한다.
            const sym_idx = scope_entry.value_ptr.*;
            if (sym_idx < sem.symbols.items.len and sem.symbols.items[sym_idx].decl_flags.is_import) {
                // import binding이 top-level 변수를 생성하는 경우에만 충돌 대상에 포함:
                // - CJS preamble: var X = require_xxx().X
                // - __esm 호이스팅: var X; (래퍼 밖으로 호이스팅)
                // - namespace import 의 inline ns_var (`var z = external_ns;`) 는
                //   wrap_kind 에 무관하게 emit 되므로 collision detection 대상.
                const generates_top_level_var = blk: {
                    for (m.import_bindings) |ib| {
                        if (!std.mem.eql(u8, ib.local_name, sym_name)) continue;
                        if (ib.kind == .namespace) break :blk true;
                        if (ib.import_record_index >= m.import_records.len) break :blk false;
                        const rec = m.import_records[ib.import_record_index];
                        if (rec.resolved.isNone()) break :blk !rec.is_lazy_resolved;
                        const target_idx = @intFromEnum(rec.resolved);
                        if (target_idx >= self.graph.moduleCount()) break :blk m.wrap_kind == .esm;
                        const target_module = self.getModule(target_idx).?;
                        const helper_modules = @import("../runtime_helper_modules.zig");
                        if (helper_modules.isVirtualId(target_module.path)) break :blk false;
                        const target_wrap = target_module.wrap_kind;
                        if (m.wrap_kind == .esm) {
                            // CJS named import는 `require_xxx().prop` 직접 참조로 치환하므로
                            // 별도 top-level var를 만들지 않는다. helper binding (JSX runtime
                            // 등) 은 call site 가 식별자 (`_jsx(...)`) 라 var 할당이 필요.
                            if (target_wrap == .cjs and ib.kind == .named and !ib.is_helper and
                                !isMetroNonInlinedRequireSpecifier(rec.specifier))
                            {
                                break :blk false;
                            }
                            // __esm: scope-hoisted 타겟의 import는 skip되어 var 미생성
                            break :blk target_wrap != .none;
                        } else {
                            // non-esm: CJS 타겟만 require() preamble에서 var 생성
                            break :blk target_wrap == .cjs;
                        }
                    }
                    // import_bindings에 매칭 없음: __esm은 기본 호이스팅, 그 외는 미생성
                    break :blk m.wrap_kind == .esm;
                };
                if (!generates_top_level_var) continue;
            }

            try cb(ctx, sym_name);
        }

        // codegen이 현재 모듈에 `_default` 합성 변수를 만드는 모든 export를 수집.
        // 충돌 시 _default$N으로 리네이밍되도록 등록한다.
        for (m.export_bindings) |eb| {
            if (eb.hasSyntheticDefault(m.semanticSymbols())) {
                try cb(ctx, "_default");
                continue;
            }
            if (eb.kind == .local and std.mem.eql(u8, eb.exported_name, "default")) {
                // export default function foo → foo 이름으로 등록
                const local = m.exportBindingLocalName(eb);
                if (module_scope.get(local) == null) {
                    try cb(ctx, local);
                }
            }
        }
    }

    /// 단일 모듈의 top-level 심볼 이름을 name_to_owners에 수집한다.
    /// 모듈 스코프의 모든 심볼 + export default 합성 _default 이름을 등록.
    /// import binding은 다른 모듈의 심볼을 참조하므로 건너뛴다.
    fn collectModuleNames(
        self: *Linker,
        m: Module,
        module_index: u32,
        name_to_owners: *NameToOwnersMap,
    ) !void {
        const Ctx = struct {
            linker: *Linker,
            map: *NameToOwnersMap,
            owner: NameOwner,
            fn add(c: @This(), name: []const u8) anyerror!void {
                try c.linker.addNameOwner(c.map, name, c.owner);
            }
        };
        const owner: NameOwner = .{ .module_index = module_index, .exec_index = m.exec_index, .path = m.path };
        try self.forEachTopLevelOwnerName(m, Ctx, .{
            .linker = self,
            .map = name_to_owners,
            .owner = owner,
        }, Ctx.add);
    }

    /// 후보 이름이 사용 가능한지 확인.
    /// 예약어/글로벌, 다른 모듈의 top-level 이름, 해당 모듈의 중첩 스코프 바인딩과 충돌하면 불가.
    pub fn isCandidateAvailable(
        self: *const Linker,
        candidate: []const u8,
        module_index: u32,
        name_to_owners: *const NameToOwnersMap,
    ) bool {
        if (self.isReservedOrGlobal(candidate)) return false;
        if (name_to_owners.contains(candidate)) return false;
        if (self.hasNestedBinding(module_index, candidate)) return false;
        // canonical_names에 이미 이 이름으로 리네임된 다른 모듈이 있으면 충돌.
        // resolveNestedShadowConflicts에서 target을 리네임할 때,
        // calculateRenames가 이미 할당한 이름과 겹치지 않도록 확인.
        if (self.isCanonicalNameTaken(candidate)) return false;
        return true;
    }

    /// 충돌 없는 후보 이름을 찾아 반환. suffix를 증가시키며 검색.
    /// 반환된 문자열은 allocator로 할당되었으므로 호출자가 소유.
    fn findAvailableCandidate(
        self: *const Linker,
        base_name: []const u8,
        module_index: u32,
        suffix_ptr: *u32,
        name_to_owners: *const NameToOwnersMap,
    ) ![]const u8 {
        var candidate = try std.fmt.allocPrint(self.allocator, "{s}${d}", .{ base_name, suffix_ptr.* });
        while (!self.isCandidateAvailable(candidate, module_index, name_to_owners)) {
            self.allocator.free(candidate);
            suffix_ptr.* += 1;
            candidate = try std.fmt.allocPrint(self.allocator, "{s}${d}", .{ base_name, suffix_ptr.* });
        }
        return candidate;
    }

    /// name_to_owners에서 충돌하는 이름을 찾아 리네임을 계산한다.
    /// exec_index가 가장 낮은 소유자가 원본 이름 유지, 나머지는 $1, $2, ...
    /// skip_max_module_index가 true이면 module_index == maxInt(u32)인 항목(cross-chunk
    /// import 점유 마커)은 rename 대상에서 제외한다.
    fn calculateRenames(
        self: *Linker,
        name_to_owners: *NameToOwnersMap,
        skip_max_module_index: bool,
    ) !void {
        var nit = name_to_owners.iterator();
        while (nit.next()) |entry| {
            const name = entry.key_ptr.*;
            const owners = entry.value_ptr.items;

            // 단일 소유자라도 예약어/글로벌을 shadowing하면 리네임 필요.
            // scope hoisting 후 const/let 선언이 TDZ를 만들어 다른 모듈의 전역 참조가 실패.
            if (owners.len == 1) {
                if (self.isReservedOrGlobal(name)) {
                    const owner = owners[0];
                    // 후보 이름도 예약어/다른 top-level/nested scope와 충돌할 수 있으므로 검증.
                    var suffix: u32 = 1;
                    const candidate = try self.findAvailableCandidate(name, owner.module_index, &suffix, name_to_owners);
                    try self.putCanonicalName(owner.module_index, name, candidate);
                }
                continue;
            }

            // exec_index 순으로 정렬 — 가장 낮은 게 원본 유지. 동률 (cross-chunk marker +
            // 같은 entry barrel) 시 path 사전순 — worker race 비결정 차단.
            std.mem.sort(NameOwner, entry.value_ptr.items, {}, struct {
                fn lessThan(_: void, a: NameOwner, b: NameOwner) bool {
                    if (a.exec_index != b.exec_index) return a.exec_index < b.exec_index;
                    return types.stringLessThan({}, a.path, b.path);
                }
            }.lessThan);

            // 첫 번째는 원본 유지, 나머지는 $1, $2, ...
            // 단, 예약어/글로벌은 첫 번째도 리네임해야 한다.
            // 그렇지 않으면 scope hoisting 후 TDZ가 발생한다.
            const name_is_reserved = self.isReservedOrGlobal(name);
            var suffix: u32 = 1;
            const start_idx: usize = if (name_is_reserved) 0 else 1;
            for (owners[start_idx..]) |owner| {
                // 점유 마커 (cross-chunk import)는 rename 대상이 아님
                if (skip_max_module_index and owner.module_index == std.math.maxInt(u32)) continue;

                // 충돌 없는 후보 이름 검색
                const candidate = try self.findAvailableCandidate(name, owner.module_index, &suffix, name_to_owners);

                try self.putCanonicalName(owner.module_index, name, candidate);
                suffix += 1;
            }
        }
    }

    /// 모든 모듈의 unresolved references를 수집하여 reserved_globals에 합친다.
    /// Rolldown 방식: 하드코딩 목록 대신 실제 사용된 글로벌만 예약.
    pub fn collectReservedGlobals(self: *Linker) !void {
        self.reserved_globals.clearRetainingCapacity();
        var mit = self.graph.modulesIterator();
        while (mit.next()) |m| {
            const sem = m.semantic orelse continue;
            var it = sem.unresolved_references.iterator();
            while (it.next()) |entry| {
                try self.reserved_globals.put(self.allocator, entry.key_ptr.*, {});
            }
        }
        // 외부 전달된 전역 식별자도 예약 (--global-identifier, RN polyfillGlobal 등)
        for (self.global_identifiers) |name| {
            try self.reserved_globals.put(self.allocator, name, {});
        }
    }

    /// 이름 충돌 감지 + 리네임 계산 (Rolldown renamer 패턴).
    /// exec_index가 가장 낮은 모듈이 원본 이름 유지, 나머지는 $1, $2, ...
    pub fn computeRenames(self: *Linker) !void {
        var scope = profile.begin(.link_compute_renames);
        defer scope.end();

        // 0. 모든 모듈의 미해결 참조를 수집 → reserved_globals
        try self.collectReservedGlobals();

        // 1. 모든 모듈의 top-level export 이름 수집
        var name_to_owners: NameToOwnersMap = .empty;
        defer {
            var vit = name_to_owners.valueIterator();
            while (vit.next()) |list| list.deinit(self.allocator);
            name_to_owners.deinit(self.allocator);
        }

        for (0..self.graph.moduleCount()) |i| {
            const m = self.getModule(@intCast(i)) orelse continue;
            try self.collectModuleNames(m.*, @intCast(i), &name_to_owners);
        }

        // 1.5. nested-binding 캐시 빌드 — 이후 calculateRenames/resolveNestedShadowConflicts 의
        // hasNestedBinding O(scopes) 재스캔을 O(1) 로. owner 모듈만(질의 대상). 빌드 실패(OOM)는
        // 캐시 비우고 전파 — 부분 캐시로 잘못된 멤버십 판정이 새지 않게(아래 build 가 보장).
        try self.buildNestedBindingCache(&name_to_owners);
        defer self.clearNestedBindingCache();

        // 2. 충돌하는 이름에 대해 리네임 계산
        try self.calculateRenames(&name_to_owners, false);

        // 3. import binding의 canonical name이 해당 모듈의 중첩 스코프와 충돌하는지 확인.
        // 충돌하면 target module의 canonical name을 한 단계 더 rename.
        // 예: d3-color의 cubehelix와 d3-interpolate 내부의 function cubehelix 충돌.
        try self.resolveNestedShadowConflicts(&name_to_owners);
    }

    /// computeRenames 전용: owner 모듈마다 nested scope(scope 0 제외) 바인딩 이름 union set 을
    /// 1회 빌드. 키는 borrow(scope_maps 소유). OOM 시 그 모듈의 부분 set 을 폐기하고 에러 전파
    /// (부분 캐시는 false-negative 멤버십을 내 byte-difference 를 만들 수 있으므로 절대 사용 금지).
    fn buildNestedBindingCache(self: *Linker, name_to_owners: *const NameToOwnersMap) !void {
        var vit = name_to_owners.valueIterator();
        while (vit.next()) |owners| {
            for (owners.items) |owner| {
                const gop = try self.nested_binding_cache.getOrPut(self.allocator, owner.module_index);
                if (gop.found_existing) continue; // 같은 모듈 중복 빌드 방지
                gop.value_ptr.* = .empty;
                const m = self.getModule(owner.module_index) orelse continue; // 빈 set = nested 없음(스캔과 동일)
                const sem = m.semantic orelse continue;
                for (sem.scope_maps, 0..) |scope_map, scope_idx| {
                    if (scope_idx == 0) continue; // top-level 제외(hasNestedBinding 스캔과 동일)
                    var it = scope_map.iterator();
                    while (it.next()) |e| {
                        gop.value_ptr.put(self.allocator, e.key_ptr.*, {}) catch |err| {
                            gop.value_ptr.deinit(self.allocator);
                            _ = self.nested_binding_cache.remove(owner.module_index);
                            return err;
                        };
                    }
                }
            }
        }
    }

    /// nested-binding 캐시 해제(inner set deinit + outer clear). computeRenames defer + deinit 양쪽 호출(멱등).
    fn clearNestedBindingCache(self: *Linker) void {
        var it = self.nested_binding_cache.valueIterator();
        while (it.next()) |set| set.deinit(self.allocator);
        self.nested_binding_cache.clearRetainingCapacity();
    }

    // ── HMR rename 보존/재사용 (perf/hmr-link-rename-reuse) ────────────────────

    /// `computeRenames` 직후, 현재 `rename_table` + `reserved_globals` 를 owned
    /// 스냅샷으로 박제한다. 다음 HMR rebuild 가 가드 통과 시 재주입해 computeRenames 를
    /// skip 한다. fingerprint 도 한 번에 빌드 (scope_maps[0] 1-pass, import 스캔은
    /// `forEachTopLevelOwnerName` 안에서만 — collectModuleNames 와 동일 비용).
    ///
    /// 모든 문자열은 스냅샷 arena 가 dupe 소유 — Linker.deinit 후에도 유효
    /// (canonical_strings borrow 금지, RFC #3933 dangling 회피).
    ///
    /// **반환 null (F5 보수적 fail-safe)**: `symbolLocalName` 은 totality 가 정적으로
    /// 보장되지 않는다(scope_maps[0] 역탐색 + synthetic fallback 둘 다 miss 하면 null).
    /// rename_table 키 중 하나라도 local 이름을 못 얻으면 그 심볼의 rename 이 스냅샷에서
    /// 조용히 누락된다 → reuse-hit rebuild 에서 그 rename 이 주입되지 않아 emit 이 원본
    /// 이름을 써, 이미 로드된(renamed) 번들과 silent wrong-binding. 가드(G0~G6)는
    /// 스냅샷 *자체* 의 불완전성은 못 잡는다. 그래서 불완전 스냅샷을 capture 하느니
    /// **null 을 반환해 capture 를 폐기** — 그러면 caller 가 reuse 를 비활성화하고
    /// 다음 rebuild 가 full computeRenames 를 돈다(정확성 > 성능). RN 8067 모듈 실측에선
    /// null 발생이 0 이지만 코드가 totality 를 보장 못 하므로 정적 안전장치를 둔다.
    pub fn buildRenameSnapshot(self: *Linker, gpa: std.mem.Allocator) !?PreservedRenames {
        var snap: PreservedRenames = .{
            .arena = std.heap.ArenaAllocator.init(gpa),
            .entries = &.{},
            .reserved_globals = &.{},
            .fingerprint = &.{},
            .module_count = @intCast(self.graph.moduleCount()),
        };
        errdefer snap.arena.deinit();
        const a = snap.arena.allocator();

        // 1. rename_table 엔트리 owned dupe. local_name 은 inject 시 by-name 재유도(G3)
        //    의 lookup 키 — SymbolID.inner 로 심볼을 찾아 그 이름을 dupe 한다.
        var entries: std.ArrayList(PreservedRenames.Entry) = .empty;
        try entries.ensureTotalCapacity(a, self.rename_table.count());
        var rit = self.rename_table.map.iterator();
        while (rit.next()) |e| {
            const id = e.key_ptr.*;
            // 불완전 스냅샷 폐기: local 이름을 못 얻는 키가 하나라도 있으면 이 빌드의
            // capture 를 통째로 무효화한다. 이미 alloc 한 arena 를 즉시 해제하고 null 반환
            // → reuse 비활성, 다음 rebuild full 재계산 (위 doc 참고).
            const local = self.symbolLocalName(id) orelse {
                debug_log.print(.rename_reuse, "buildRenameSnapshot: symbolLocalName(module={d},inner={d}) null → 스냅샷 폐기(capture 실패), reuse 비활성\n", .{
                    @intFromEnum(id.module),
                    @intFromEnum(id.inner),
                });
                snap.arena.deinit();
                return null;
            };
            entries.appendAssumeCapacity(.{
                .id = id,
                .local_name = try a.dupe(u8, local),
                .canonical = try a.dupe(u8, e.value_ptr.*),
            });
        }
        snap.entries = try entries.toOwnedSlice(a);

        // 2. reserved_globals owned dupe.
        var rg: std.ArrayList([]const u8) = .empty;
        try rg.ensureTotalCapacity(a, self.reserved_globals.count());
        var git = self.reserved_globals.keyIterator();
        while (git.next()) |k| rg.appendAssumeCapacity(try a.dupe(u8, k.*));
        snap.reserved_globals = try rg.toOwnedSlice(a);

        // 3. per-index fingerprint 1-pass.
        const mc = self.graph.moduleCount();
        const fps = try a.alloc(PreservedRenames.ModuleFingerprint, mc);
        for (0..mc) |i| {
            const m = self.getModule(@intCast(i)) orelse {
                fps[i] = .{
                    .path_hash = 0,
                    .exec_index = std.math.maxInt(u32),
                    .toplevel_name_set_hash = 0,
                    .unresolved_refs_hash = 0,
                    .nested_name_set_hash = 0,
                    .import_locals_wrap_hash = 0,
                };
                continue;
            };
            fps[i] = try self.moduleFingerprint(m.*);
        }
        snap.fingerprint = fps;

        return snap;
    }

    /// 재사용 안전성 가드 (G0~G4). 현재(fresh) 그래프가 스냅샷과 "rename deconflict
    /// 결과가 동일하게 나오는" 형태인지 판정한다. **하나라도 불확실하면 false → 호출자가
    /// full computeRenames** (기존 경로). fail-safe: 가드 버그의 최악은 perf 회귀이지
    /// 정확성 사고가 아니다 (G3 제외 — by-name 재유도가 테스트로 커버).
    ///
    /// per-index fingerprint 전체(path_hash/exec_index/toplevel_name_set_hash/
    /// unresolved_refs_hash)를 비교한다. 변경 모듈만 골라 비교하는 대신 *모든* 모듈을
    /// 비교 — 변경 안 된 모듈은 자명히 일치하고, 변경 모듈은 반드시 일치해야 하므로
    /// 더 보수적이며 단순(graph_changed 사전계산 불필요).
    /// - G0 모듈 추가/삭제: module_count 불일치 → false.
    /// - G1 index/exec_index: per-index path_hash + exec_index 비교.
    /// - G2 변경 모듈 이름집합: per-index toplevel_name_set_hash 비교.
    /// - G3 inner idx: inject 의 by-name 재유도가 담당 (가드 아님).
    /// - G4 reserved_globals: per-index unresolved_refs_hash 비교.
    /// - G5 nested shadow 입력: per-index nested_name_set_hash 비교
    ///   (scope_maps[1..] 이름이 import canonical 을 shadow → 추가 rename 유발).
    /// - G6 import local + wrap: per-index import_locals_wrap_hash 비교
    ///   (import local_name 집합 / ESM↔CJS wrap flip 시 synthetic 이름 landscape 변동).
    pub fn renameReuseGuard(self: *Linker, snap: *const PreservedRenames) bool {
        const mc = self.graph.moduleCount();
        // G0: 모듈 수 동일.
        if (mc != snap.module_count) return false;
        if (snap.fingerprint.len != mc) return false;

        // HMR 보존-hit(carrier changed_emit_paths non-null = 위상 보존)에서는 **변경 모듈만**
        // full fingerprint 를 검사하고 unchanged 는 아예 순회하지 않는다(lGuard O(N)→O(changed),
        // release link 의 ~32% 제거). unchanged 모듈은 #4174 renumber identity(위상 보존 시
        // module_index 불변) + 물리 보존(path/exec_index/semantic 불변)으로 fingerprint 가 자명히
        // snapshot 과 일치하기 때문. carrier 는 emit source-hash skip(#4172) / injectPreservedRenames
        // 가 이미 정확성에 신뢰하는 동일 출처라, 가드가 carrier 를 신뢰하는 것은 새로운 trust 가
        // 아니라 종전 #4173 의 per-unchanged G1 경량(redundant fail-safe)을 제거하는 것이다.
        // (#4173 G1 이 막던 renumber non-identity 는 #4174 가 구조적으로 차단.)
        // count(G0) 가 모듈 add/remove 를, carrier=null(위상 변경 시)이 fallback 전량 비교를 보장.
        if (self.graph.changed_emit_paths) |ch| {
            var it = ch.iterator();
            while (it.next()) |e| {
                const idx = self.graph.path_to_module.get(e.key_ptr.*) orelse return false;
                const i = @intFromEnum(idx);
                if (i >= mc) return false;
                const m = self.getModule(@intCast(i)) orelse return false;
                if (!self.fingerprintMatches(m.*, snap.fingerprint[i])) return false;
            }
            return true;
        }

        // carrier=null(fallback / 비보존): 전량 비교(종전).
        for (0..mc) |i| {
            const m = self.getModule(@intCast(i)) orelse return false;
            if (!self.fingerprintMatches(m.*, snap.fingerprint[i])) return false;
        }
        return true;
    }

    /// 모듈의 현재 fingerprint(G1 path/exec + G2 toplevel + G4 unresolved + G5 nested +
    /// G6 import-locals/wrap)가 snapshot 의 `old` 와 전부 일치하는지. OOM 은 fail-safe(false).
    fn fingerprintMatches(self: *Linker, m: Module, old: PreservedRenames.ModuleFingerprint) bool {
        const cur = self.moduleFingerprint(m) catch return false;
        return cur.path_hash == old.path_hash and
            cur.exec_index == old.exec_index and
            cur.toplevel_name_set_hash == old.toplevel_name_set_hash and
            cur.unresolved_refs_hash == old.unresolved_refs_hash and
            cur.nested_name_set_hash == old.nested_name_set_hash and
            cur.import_locals_wrap_hash == old.import_locals_wrap_hash;
    }

    /// SymbolID 에 해당하는 module-local 이름 (scope_maps[0] reverse lookup → synthetic_name
    /// fallback). `findSymbolIdx` 의 역방향 — idx 로 이름을 찾는다.
    ///
    /// **totality 미보장 (F5)**: 모듈이 그래프 밖이거나, semantic 이 없거나, idx 가
    /// scope_maps[0] 역탐색·synthetic fallback 둘 다 miss 하면 null. `buildRenameSnapshot`
    /// 이 이 null 을 만나면 스냅샷을 폐기한다(불완전 capture 방지). pub: linker_test.zig 가
    /// 이 null 케이스를 직접 구성해 capture 폐기를 검증한다.
    pub fn symbolLocalName(self: *const Linker, id: bundler_symbol.SymbolID) ?[]const u8 {
        const m = self.getModule(@intFromEnum(id.module)) orelse return null;
        const sem = m.semantic orelse return null;
        const idx = @intFromEnum(id.inner);
        if (sem.scope_maps.len > 0) {
            var it = sem.scope_maps[0].iterator();
            while (it.next()) |e| {
                if (e.value_ptr.* == idx) return e.key_ptr.*;
            }
        }
        if (idx < sem.symbols.items.len) {
            const sym = sem.symbols.items[idx];
            if (sym.synthetic_kind != null and sym.synthetic_name.len > 0) return sym.synthetic_name;
        }
        return null;
    }

    /// 모듈의 fingerprint 계산. order-independent 해시(sum)로 이름집합/unresolved 비교 —
    /// scope_maps iteration 순서(비결정)에 무관해야 가드가 안정적이다.
    /// pub: linker_test.zig 가 per-field 게이트 동작을 직접 대조 (which-gate 검증).
    pub fn moduleFingerprint(self: *Linker, m: Module) !PreservedRenames.ModuleFingerprint {
        var fp: PreservedRenames.ModuleFingerprint = .{
            .path_hash = std.hash.Wyhash.hash(0x5a, m.path),
            .exec_index = m.exec_index,
            .toplevel_name_set_hash = 0,
            .unresolved_refs_hash = 0,
            .nested_name_set_hash = 0,
            // wrap_kind 를 seed 로 접어 넣는다(빈 import 모듈도 wrap flip 을 감지).
            .import_locals_wrap_hash = @intFromEnum(m.wrap_kind) +% 1,
        };

        // top-level owner 이름집합 (G2) — collectModuleNames 와 동일 필터 공유.
        const Ctx = struct {
            acc: *u64,
            fn add(c: @This(), name: []const u8) anyerror!void {
                // order-independent: 각 이름 해시를 wrapping-add. 같은 집합 → 같은 합.
                c.acc.* +%= std.hash.Wyhash.hash(0xc0, name);
            }
        };
        try self.forEachTopLevelOwnerName(m, Ctx, .{ .acc = &fp.toplevel_name_set_hash }, Ctx.add);

        // nested binding 이름집합 (G5) — resolveNestedShadowConflicts/hasNestedBinding 입력.
        // forEachNestedBindingName 으로 shadow pass 와 동일한 scope_maps[1..] 집합을 본다.
        try forEachNestedBindingName(m, Ctx, .{ .acc = &fp.nested_name_set_hash }, Ctx.add);

        // import binding local_name 집합 (G6) — nested shadow 비교의 다른 한쪽.
        // 모든 binding 의 local_name 을 해시(namespace 포함, conservative superset).
        for (m.import_bindings) |ib| {
            fp.import_locals_wrap_hash +%= std.hash.Wyhash.hash(0xe0, ib.local_name);
        }

        // unresolved_references 집합 (G4) — collectReservedGlobals 입력.
        if (m.semantic) |sem| {
            var it = sem.unresolved_references.keyIterator();
            while (it.next()) |k| fp.unresolved_refs_hash +%= std.hash.Wyhash.hash(0xd0, k.*);
        }
        return fp;
    }

    /// 보존 스냅샷을 현재(fresh) 그래프의 `rename_table`/`reserved_globals` 에 주입한다.
    /// `renameReuseGuard` 통과 후에만 호출 — 이름집합/모듈순서 불변이 보장된 상태.
    ///
    /// **G3 (유일한 correctness-load-bearing)**: 변경 모듈은 재파싱돼 inner idx 가
    /// 흔들릴 수 있으므로, 스냅샷 엔트리의 `id.inner` 를 신뢰하지 않고 *이름으로 재유도*
    /// (`findSymbolIdx`, scope_maps[0] 대상) 해 fresh idx 로 재키잉한 뒤 주입한다. 이름은
    /// G2 가 불변 보장하므로 모든 엔트리가 재유도 성공(total). 변경 안 된 모듈도 같은
    /// 경로를 타 idx 가 그대로면 동일 결과 — 분기 없이 일관 처리.
    ///
    /// `assignSymbolCanonical` 싱크를 거쳐 rename_table/canonical_strings/canonical_names_used
    /// 를 일관 갱신 (computeRenames 와 동일 sink).
    pub fn injectPreservedRenames(self: *Linker, snap: *const PreservedRenames) !void {
        // reserved_globals 복원 (collectReservedGlobals 를 skip 하므로 직접).
        self.reserved_globals.clearRetainingCapacity();
        for (snap.reserved_globals) |name| {
            try self.reserved_globals.put(self.allocator, name, {});
        }
        // 외부 전달 전역 식별자도 동일하게 예약 (collectReservedGlobals 와 parity).
        for (self.global_identifiers) |name| {
            try self.reserved_globals.put(self.allocator, name, {});
        }

        for (snap.entries) |entry| {
            const module_index = @intFromEnum(entry.id.module);
            // by-name 재유도: 초기 idx 대신 fresh 그래프에서 이름으로 다시 찾는다.
            const fresh_idx = self.findSymbolIdx(module_index, entry.local_name) orelse continue;
            const id = bundler_symbol.SymbolID.make(@as(ModuleIndex, @enumFromInt(module_index)), fresh_idx);
            // 스냅샷 문자열 borrow — 매 빌드 N dupe(alloc) 제거(lInj 절감, RFC_PERSISTENT_LINKER
            // Phase 1). `entry.canonical` 은 snap(=PreservedRenames, IncrementalBundler 수명)
            // 소유라 emit 까지 유효하고, linker.deinit 가 free 하지 않는다.
            try self.assignSymbolCanonicalBorrowed(id, entry.canonical);
        }
    }

    /// import binding의 canonical name이 importer 모듈의 중첩 스코프에 같은 이름이
    /// 있으면, target module의 이름을 한 단계 더 rename하여 shadowing 충돌 방지.
    /// 단 ZNTC runtime helper module 은 cross-module 공유 symbol 이라 consumer 별로
    /// rename 하면 매 호출이 canonical_name 을 덮어써 최종 하나만 유효, 나머지
    /// `__extends$1`, `$2` ... 호출은 ReferenceError (미선언). helper module 은 rename
    /// 대상에서 제외 — 충돌은 consumer 측 nested binding 을 mangling 단계가 처리한다.
    fn resolveNestedShadowConflicts(self: *Linker, name_to_owners: *const NameToOwnersMap) !void {
        const helper_modules = @import("../runtime_helper_modules.zig");
        for (0..self.graph.moduleCount()) |mod_i| {
            const m = self.getModule(@intCast(mod_i)) orelse continue;
            for (m.import_bindings) |ib| {
                if (ib.kind == .namespace) continue;
                const resolved = self.getResolvedBinding(@intCast(mod_i), ib.local_span) orelse continue;
                const target_name = self.resolveToLocalName(resolved.canonical);

                // target_name이 이 모듈의 중첩 스코프에 있고, local_name과 다르면 충돌
                if (!std.mem.eql(u8, ib.local_name, target_name) and
                    self.hasNestedBinding(@intCast(mod_i), target_name))
                {
                    // target module의 canonical name을 한 단계 더 rename
                    const cmod: u32 = @intCast(@intFromEnum(resolved.canonical.module_index));
                    const target_module = self.getModule(cmod) orelse continue;
                    if (helper_modules.isVirtualId(target_module.path)) continue;
                    const export_local = self.getExportLocalName(cmod, resolved.canonical.export_name) orelse resolved.canonical.export_name;

                    // 새 이름: target_name$N (기존 이름 충돌 없는 것)
                    var suffix: u32 = 1;
                    const candidate = try self.findAvailableCandidate(target_name, cmod, &suffix, name_to_owners);
                    try self.putCanonicalName(cmod, export_local, candidate);
                }
            }
        }
    }

    /// unified_mangler.mangleAll() 을 호출하기 위한 입력 수집. `(module_index,
    /// symbol_id)` 단위 후보를 개별 생성한다 (이름별 집계 없음). 결과는
    /// caller 가 `deinit` 해야 함.
    /// `chunk_modules` 가 non-null 이면 그 집합에 포함된 모듈만 mangle candidate / Phase B
    /// 대상으로 삼는다 (#4045 per-chunk mangle). 나머지 모듈은 빈 입력으로 skip (bitset 만
    /// 보존해 `unified_module_scopes` 인덱싱 유지). `extra_reserved` 는 cross-chunk import 로
    /// 이 청크에 도입되는 이름 — 청크 내부 mangle 이 그 이름을 재사용하지 않도록 reserved 에
    /// 합친다. 전역 mangle(`computeMangling`)은 `(null, &.{})` 로 호출해 기존 동작 유지.
    pub fn collectUnifiedInput(
        self: *const Linker,
        chunk_modules: ?*const std.AutoHashMapUnmanaged(ModuleIndex, void),
        extra_reserved: []const []const u8,
    ) !UnifiedCollect {
        const um = @import("../codegen/unified_mangler.zig");
        // helper module / dead module / sem-less module 모두 같은 빈 입력으로
        // Phase B 를 skip 시킨다.
        const emptyInput = struct {
            fn make(source: []const u8, bitset: std.DynamicBitSet) um.ModuleMangleInput {
                return .{
                    .scopes = &.{},
                    .symbols = &.{},
                    .scope_maps = &.{},
                    .references = &.{},
                    .source = source,
                    .module_scope_symbols = bitset,
                };
            }
        }.make;

        const mod_count = self.graph.moduleCount();
        const modules = try self.allocator.alloc(um.ModuleMangleInput, mod_count);
        errdefer self.allocator.free(modules);

        const bitsets = try self.allocator.alloc(std.DynamicBitSet, mod_count);
        var created: usize = 0;
        errdefer {
            for (bitsets[0..created]) |*b| b.deinit();
            self.allocator.free(bitsets);
        }

        // modules[i].cross_module_imports 의 backing slice 들. 각 모듈마다 별도
        // alloc — deinit 시 일괄 free. emptyInput 케이스는 default &.{} 라 미할당.
        var import_ref_slices: std.ArrayListUnmanaged([]const um.ImportRef) = .empty;
        errdefer {
            for (import_ref_slices.items) |s| self.allocator.free(s);
            import_ref_slices.deinit(self.allocator);
        }

        var candidates: std.ArrayListUnmanaged(um.TopLevelCandidate) = .empty;
        errdefer candidates.deinit(self.allocator);

        // 두 set 을 한 module pass 로 채운다:
        //   - exported: candidate 단계 skip filter (entry export + external import 만)
        //   - reserved: Phase A base54 회피 set (위 + non-external import binding 까지)
        // (#2971) zod 의 \`class z\` 가 entry import alias \`z\` 와 충돌한 root cause —
        // inline 처리되어 var 가 안 만들어지더라도 entry source 의 reference 식별자는
        // 그대로 emit 되므로 mangler 가 같은 이름을 다른 binding 의 short name 으로
        // 부여하면 SyntaxError. is_external 무관하게 reserved 에 등록.
        var exported: std.StringHashMapUnmanaged(void) = .empty;
        defer exported.deinit(self.allocator);
        var reserved: std.StringHashMapUnmanaged(void) = .empty;
        defer reserved.deinit(self.allocator);

        // #4045: cross-chunk import 로 이 청크에 바인딩되는 이름(import binding local /
        // deconflict alias). 청크 내부 mangle 이 같은 이름을 다른 binding 의 short name 으로
        // 부여하면 cross-chunk 참조가 깨진다 → reserved 로 회피.
        for (extra_reserved) |name| {
            try reserved.put(self.allocator, name, {});
        }

        // Scope-hoisted output shares one top-level lexical environment. If a
        // minified top-level declaration reuses an unresolved global name
        // (`Set`, `Promise`, app-provided globals, ...), the declaration is
        // hoisted and shadows that global even in modules evaluated earlier.
        var global_it = self.reserved_globals.keyIterator();
        while (global_it.next()) |name| {
            try reserved.put(self.allocator, name.*, {});
        }

        var mit = self.graph.modulesIterator();
        while (mit.next()) |m| {
            if (m.is_entry_point) {
                for (m.export_bindings) |eb| {
                    const exported_name = eb.exported_name;
                    const local_name = m.exportBindingLocalName(eb);
                    try exported.put(self.allocator, exported_name, {});
                    try exported.put(self.allocator, local_name, {});
                    try reserved.put(self.allocator, exported_name, {});
                    try reserved.put(self.allocator, local_name, {});
                }
            }
            for (m.import_bindings) |ib| {
                if (ib.import_record_index >= m.import_records.len) continue;
                // External import bindings may not have a semantic local symbol when the
                // import is only preserved for output syntax. In that case the scanner
                // local name is the external contract we must not mangle.
                const local_name = if (ib.local_symbol.isValid()) m.importBindingLocalName(ib) else ib.local_name;
                try reserved.put(self.allocator, local_name, {});
                if (m.import_records[ib.import_record_index].is_external) {
                    try exported.put(self.allocator, local_name, {});
                }
            }
            // Phase B 는 1-char binding 을 literal 로 보존한다 (mangler.zig
            // shouldSkip `name.len <= 1`). bare scope-hoist 는 전 모듈이 한 scope
            // 라, *nested* scope 의 1-char local (예: `for (let i=0; ...)`) 도
            // 그 위치에서 free-ref 되는 Phase A top-level 이름과 같으면 shadow
            // → 잘못된 binding 참조 (effect: `pipe`→`i` 가 Hash.js `for(let i)`
            // 안에서 shadow → `i is not a function`). 기존 #2965 처리는
            // module scope(scope_maps[0]) 1-char 만 reserved 에 넣어 nested 를
            // 놓쳤다. 모든 scope 의 1-char 식별자를 Phase A reserved 에 등록해
            // Phase A 가 그 이름을 다른 top-level 에 부여하지 못하게 한다.
            // bounded: 1-char 이름은 최대 ~64종.
            if (m.semantic) |sem| {
                for (sem.scope_maps) |smap| {
                    var sm_it = smap.iterator();
                    while (sm_it.next()) |e| {
                        if (e.key_ptr.len <= 1) try reserved.put(self.allocator, e.key_ptr.*, {});
                    }
                }
            }
        }

        const helper_modules = @import("../runtime_helper_modules.zig");
        for (0..mod_count) |mi| {
            const m = self.getModule(@intCast(mi)).?;
            const sem_opt = m.semantic;

            // #4045 per-chunk mangle: 이 청크에 속하지 않은 모듈은 candidate / Phase B
            // 양쪽 제외 (emptyInput). 다른 청크 모듈의 심볼은 이 청크 mangle 에서 이름을
            // 받지 않으며, cross-chunk 로 참조되는 이름은 extra_reserved 가 이미 보호한다.
            // bitset 슬롯은 unified_module_scopes 인덱싱(metadata) 때문에 유지하되, 청크
            // 비포함 모듈은 그 청크 emit 시 읽히지 않으므로 0-bit 로 할당 — 다청크 빌드에서
            // 청크마다 전체 모듈 sym_count 만큼 bit storage 를 잡던 비용을 제거한다(#4 효율).
            const in_chunk = if (chunk_modules) |cm| cm.contains(@as(ModuleIndex, @enumFromInt(mi))) else true;
            const sym_count = if (in_chunk) (if (sem_opt) |s| s.symbols.items.len else 0) else 0;
            bitsets[created] = try std.DynamicBitSet.initEmpty(self.allocator, sym_count);
            created += 1;

            if (!in_chunk) {
                modules[mi] = emptyInput(m.source, bitsets[mi]);
                continue;
            }

            // tree-shake 후 dead 로 판정된 모듈은 후보에서 제외 — 짧은 이름 풀이
            // emit 안 될 binding 으로 잠식되는 회귀 방지. tree_shaker_active=false
            // 일 땐 is_included 가 default false 라 잘못 skip 되므로 active 일 때만 가드.
            if (self.tree_shaker_active and !m.is_included) {
                modules[mi] = emptyInput(m.source, bitsets[mi]);
                continue;
            }

            // #1961 PR 1h: ZNTC runtime helper virtual module 의 top-level 식별자
            // (`$aS` / `$gn` 등) 는 transformer 가 이미 축약 이름으로 emit 한 결과.
            // mangler 가 추가 rename 하면 cross-module binding 이 깨진다 (main 의
            // `$aS` import 호출 site 와 helper 의 var declaration 이 다른 이름).
            // helper module 은 후보 / Phase B 양쪽 skip — modules[mi] 는 빈 entry 로 init.
            const is_helper_module = helper_modules.isVirtualId(m.path);
            if (is_helper_module) {
                if (sem_opt) |sem| {
                    if (sem.scopes.len == 0 or !sem.scopes[0].blocksMangling()) {
                        for (sem.symbols.items, 0..) |*sym, si| {
                            const sk = sym.synthetic_kind orelse continue;
                            switch (sk) {
                                .cjs_exports, .cjs_require, .esm_init => {},
                                else => continue,
                            }
                            // RFC #3940 L.4c: dedup key 도 build-scope rename_table 경유. miss → synthetic_name.
                            const key = self.rename_table.get(bundler_symbol.SymbolID.make(@as(ModuleIndex, @enumFromInt(mi)), si)) orelse sym.synthetic_name;
                            if (key.len <= 1) continue;
                            if (exported.contains(key)) continue;
                            try candidates.append(self.allocator, .{
                                .module_index = @intCast(mi),
                                .symbol_id = @intCast(si),
                                .name = key,
                                .ref_count = if (sym.reference_count == 0) 1 else sym.reference_count,
                                .module_path = m.path,
                            });
                        }
                    }
                }
                modules[mi] = emptyInput(m.source, bitsets[mi]);
                continue;
            }

            if (sem_opt) |sem| {
                const blocks = sem.scopes.len > 0 and sem.scopes[0].blocksMangling();
                if (sem.scope_maps.len > 0) {
                    var sit = sem.scope_maps[0].iterator();
                    while (sit.next()) |entry| {
                        const sym_name = entry.key_ptr.*;
                        const sym_idx_usize = entry.value_ptr.*;
                        if (sym_idx_usize >= sym_count) continue;
                        const sym_idx: u32 = @intCast(sym_idx_usize);

                        // Phase B 는 module scope 심볼 skip (Phase A 담당).
                        bitsets[mi].set(sym_idx_usize);

                        if (blocks) continue;
                        if (exported.contains(sym_name)) continue;
                        if (sym_name.len <= 1) {
                            // candidate skip 한 1-char binding 도 reserved 에 등록 (#2965).
                            // entry deepEntry 의 \`const e = ...\` 같은 짧은 식별자는
                            // mangle 안 되고 source 그대로 emit 되므로 internal binding 의
                            // mangle 결과로 동일 이름 부여 시 충돌 — three 의 \`class e\` ↔
                            // entry \`const e = new Euler(...)\` 가 그 케이스.
                            try reserved.put(self.allocator, sym_name, {});
                            continue;
                        }
                        if (std.mem.eql(u8, sym_name, "default")) continue;
                        if (std.mem.eql(u8, sym_name, "arguments")) continue;

                        const sym = &sem.symbols.items[sym_idx];
                        if (sym.kind == .import_binding) continue;
                        // synthetic default 는 아래 별도 루프가 처리 —
                        // 같은 symbol 을 candidates 에 중복 추가하면
                        // mangleAll 의 renames.put 이 이전 value 를 덮어써 leak.
                        if (sym.synthetic_kind == .default_export) continue;
                        // statement-level dead 가드 — esbuild Part.IsLive / rolldown
                        // stmt_info_included 와 동일 효과. tree_shaker reconcile + namespace
                        // getter dead-export skip 과 같은 진실의 원천.
                        if (self.tree_shaker_active and !m.isStatementAliveBySym(sym_idx_usize)) continue;

                        // RFC #3940 L.4c: dedup key 를 build-scope rename_table 경유 (parity 로 동치).
                        const key = self.rename_table.get(bundler_symbol.SymbolID.make(@as(ModuleIndex, @enumFromInt(mi)), sym_idx)) orelse sym_name;
                        if (key.len <= 1) {
                            // canonical_name 이 sym_name 과 다른 1-char 케이스도 reserve
                            // (위 sym_name 분기와 대칭 — #2965).
                            try reserved.put(self.allocator, key, {});
                            continue;
                        }
                        if (exported.contains(key)) continue;

                        try candidates.append(self.allocator, .{
                            .module_index = @intCast(mi),
                            .symbol_id = sym_idx,
                            .name = key,
                            .ref_count = sym.reference_count,
                            .module_path = m.path,
                        });
                    }
                }

                if (!blocks) {
                    for (sem.symbols.items, 0..) |*sym, si| {
                        const sk = sym.synthetic_kind orelse continue;
                        switch (sk) {
                            .default_export, .cjs_exports, .cjs_require, .esm_init => {},
                        }
                        // default_export 는 wrapper 와 달리 cross-module emit 보장이 없다 —
                        // ref=0 이면 어디서도 import 하지 않아 codegen 이 binding 을 emit
                        // 하지 않는다. 그런 candidate 는 mangle 풀에서 제외.
                        if (sk == .default_export and sym.reference_count == 0) continue;
                        // RFC #3940 L.4c: dedup key 를 build-scope rename_table 경유 (parity 로 동치).
                        const key = self.rename_table.get(bundler_symbol.SymbolID.make(@as(ModuleIndex, @enumFromInt(mi)), si)) orelse sym.synthetic_name;
                        if (key.len <= 1) continue;
                        if (exported.contains(key)) continue;

                        // 래퍼 심볼(`init_<path>`, `exports_<path>`)은 소스 AST가 아니라
                        // 번들러가 직접 emit하므로 semantic reference_count가 보통 0이다.
                        // 그래도 선언과 cross-module 호출에 실제로 등장하고 RN 번들에서는
                        // 매우 길어지므로, 작은 0이 아닌 가중치로 최상위 망글 후보에 남긴다.
                        const ref_count: u32 = if ((sk == .cjs_exports or sk == .cjs_require or sk == .esm_init) and sym.reference_count == 0)
                            1
                        else
                            sym.reference_count;

                        try candidates.append(self.allocator, .{
                            .module_index = @intCast(mi),
                            .symbol_id = @intCast(si),
                            .name = key,
                            .ref_count = ref_count,
                            .module_path = m.path,
                        });
                    }
                }

                // cross_module_imports: 이 모듈이 import 한 cross-module symbol 의
                // source 위치 (= per_mod_reserved 에 broadcast → Phase B nested 가
                // 그 mangled 이름 회피). RFC #3288 (b): `.alias` (re-export chain
                // 중간 노드) 도 resolveExportChain 으로 궁극 `.semantic` source 를
                // 도출해 포함 — 누락 시 bare scope-hoist 후 nested 가 re-export
                // source 이름을 재사용해 silent-broken (PR (a) collision assert 가
                // 이 누락을 잡도록 설계됨). 미해결/순환은 외부·shim 이라 mangle
                // 대상 아님 → skip 안전.
                var ir_buf: std.ArrayListUnmanaged(um.ImportRef) = .empty;
                errdefer ir_buf.deinit(self.allocator);
                const appendSem = struct {
                    fn f(la: std.mem.Allocator, buf: *std.ArrayListUnmanaged(um.ImportRef), sr: bundler_symbol.SymbolRef) !void {
                        if (sr != .semantic) return;
                        const s = sr.semantic;
                        if (s.module.isNone() or s.symbol.isNone()) return;
                        try buf.append(la, .{
                            .source_module_index = @intFromEnum(s.module),
                            .source_symbol_id = @intFromEnum(s.symbol),
                        });
                    }
                }.f;
                for (m.import_bindings) |ib| {
                    if (ib.kind == .namespace) {
                        // import * as ns: codegen 이 ns.<prop> 를 target export 의
                        // canonical 직접 참조로 rewrite (ns_member_rewrites). 그
                        // source top-level 의 mangled 이름이 importer per_mod_reserved
                        // 에 없으면 nested 가 재사용 → silent-broken (`.alias` 와
                        // 평행, RFC #3288). namespace_used_properties 로 정밀 좁히고
                        // null(동적 접근/탈출) 은 보수적 전체 export.
                        if (ib.import_record_index >= m.import_records.len) continue;
                        const tgt = m.import_records[ib.import_record_index].resolved;
                        if (tgt.isNone()) continue;
                        const tm = self.getModule(@intFromEnum(tgt)) orelse continue;
                        if (ib.namespace_used_properties) |props| {
                            for (props) |p| {
                                if (self.resolveSemanticExportSource(tgt, p)) |sr|
                                    try appendSem(self.allocator, &ir_buf, sr);
                            }
                        } else {
                            for (tm.export_bindings) |eb| {
                                if (self.resolveSemanticExportSource(tgt, eb.exported_name)) |sr|
                                    try appendSem(self.allocator, &ir_buf, sr);
                            }
                        }
                        continue;
                    }
                    // 일반 named import 도 codegen/metadata 는 resolveExportChain 결과
                    // (최종 export source)를 직접 참조로 rewrite 할 수 있다. importer 의
                    // Phase B local 이름이 그 최종 source 의 Phase A mangled 이름을
                    // 재사용하면 bare scope-hoist 에서 `COLORS.white` → `local.white`
                    // 같은 silent-broken 이 발생하므로, import record 의 resolved module
                    // 기준으로 먼저 궁극 `.semantic` source 를 예약한다.
                    if (ib.import_record_index < m.import_records.len) {
                        const tgt = m.import_records[ib.import_record_index].resolved;
                        if (!tgt.isNone()) {
                            if (self.resolveSemanticExportSource(tgt, ib.imported_name)) |sr| {
                                try appendSem(self.allocator, &ir_buf, sr);
                                continue;
                            }
                        }
                    }
                    // fallback: 미해결/순환/non-semantic 은 외부·shim 이라 mangle 대상이
                    // 아니지만, populateImportSymbols 가 이미 source-side symbol 을 넣은
                    // 단순 import 는 기존 경로로 보존한다.
                    const sr: bundler_symbol.SymbolRef = switch (ib.symbol) {
                        .semantic => ib.symbol,
                        .alias => |a| blk: {
                            if (a.module.isNone()) continue;
                            break :blk self.resolveSemanticExportSource(a.module, ib.imported_name) orelse continue;
                        },
                    };
                    try appendSem(self.allocator, &ir_buf, sr);
                }
                const ir_owned = try ir_buf.toOwnedSlice(self.allocator);
                try import_ref_slices.append(self.allocator, ir_owned);

                modules[mi] = .{
                    .scopes = sem.scopes,
                    .symbols = sem.symbols.items,
                    .scope_maps = sem.scope_maps,
                    .references = sem.references,
                    .source = m.source,
                    .module_scope_symbols = bitsets[mi],
                    .cross_module_imports = ir_owned,
                    .wrapper_isolated = m.wrap_kind.isWrapped(),
                };
            } else {
                modules[mi] = emptyInput(m.source, bitsets[mi]);
            }
        }

        // reserved 를 owned slice 로 직접 alloc — ArrayList 중간단계 생략.
        // string 자체는 module source 가 소유, slice 만 새 array 로 복사.
        const reserved_names = try self.allocator.alloc([]const u8, reserved.count());
        errdefer self.allocator.free(reserved_names);
        var ri: usize = 0;
        var rit = reserved.iterator();
        while (rit.next()) |entry| : (ri += 1) reserved_names[ri] = entry.key_ptr.*;

        return .{
            .top_level_candidates = try candidates.toOwnedSlice(self.allocator),
            .modules = modules,
            .bitsets = bitsets,
            .reserved_names = reserved_names,
            .import_ref_slices = try import_ref_slices.toOwnedSlice(self.allocator),
            .allocator = self.allocator,
        };
    }

    /// minify 활성화 시, scope hoisting 후 모든 top-level 이름을 짧은 이름으로 교체.
    /// computeRenames 이후에 호출해야 함 (충돌 해결 완료 상태).
    ///
    /// #1760: unified `mangleAll()` 한 번의 호출로 top-level + nested 모두 결정.
    /// Phase A 결과는 `rename_table` 에 주입, Phase B 결과는
    /// linker 필드에 보관되어 `metadata.buildMetadataForAst` 가 조회 (Step 3c).
    pub fn computeMangling(self: *Linker) !void {
        var scope = profile.begin(.link_compute_mangling);
        defer scope.end();
        try self.collectReservedGlobals();
        // 전역 mangle: 청크 필터 없음(null), cross-chunk 예약 없음.
        try self.runUnifiedMangle(null, &.{});
    }

    /// `collectUnifiedInput` → `mangleAll` → Phase A 주입 → Phase B 보관 시퀀스.
    /// 전역(`computeMangling`)과 per-chunk(`computeChunkMangling`)가 공유한다. 호출자가
    /// `chunk_modules`/`extra_reserved` 와 `reserved_globals`(전역=collectReservedGlobals,
    /// per-chunk=청크 unresolved)를 미리 세팅한다.
    fn runUnifiedMangle(
        self: *Linker,
        chunk_modules: ?*const std.AutoHashMapUnmanaged(ModuleIndex, void),
        extra_reserved: []const []const u8,
    ) !void {
        var collected = try self.collectUnifiedInput(chunk_modules, extra_reserved);
        // bitsets 는 성공 시 takeBitsets 로 linker 이관, 그 전에 에러나면 여기서 해제
        // (mangleAll / dupe OOM 누수 방지). takeBitsets 후엔 collected.bitsets=&.{} 라
        // errdefer 가 실행돼도 빈 슬라이스 — 단, takeBitsets 뒤엔 try 가 없어 미실행.
        errdefer {
            for (collected.bitsets) |*b| b.deinit();
            self.allocator.free(collected.bitsets);
        }
        // candidates/modules/reserved/import_refs 는 성공/실패 공통 해제.
        defer {
            self.allocator.free(collected.top_level_candidates);
            self.allocator.free(collected.modules);
            self.allocator.free(collected.reserved_names);
            for (collected.import_ref_slices) |s| self.allocator.free(s);
            self.allocator.free(collected.import_ref_slices);
        }

        var result = try unified_mangler.mangleAll(self.allocator, .{
            .modules = collected.modules,
            .top_level_candidates = collected.top_level_candidates,
            .global_reserved = collected.reserved_names,
        });
        // result 소유권을 linker 로 이관 (deinit 은 linker.deinit 이 담당).
        errdefer result.deinit();

        try self.injectPhaseARenames(collected.top_level_candidates, &result);

        // mangle_report / mangle_dump 진단은 *전역* mangle(chunk_modules==null)에서만 낸다.
        // per-chunk(splitting)에서 내면 top_level 이 청크마다 덮어써지고 recordNested 가
        // 모듈을 청크 수만큼 중복 기록한다 — 리팩터 전 computeChunkMangling 은 두 블록 다
        // 없었으므로 동작 보존.
        if (chunk_modules == null) {
            if (self.mangle_report) |r| {
                r.top_level = result.phase_a;
                r.top_level_reserved_pool = result.phase_a.reserved_size;
                for (result.phase_b_modules, 0..) |stats, mi| {
                    const m = self.getModule(@intCast(mi)) orelse continue;
                    try r.recordNested(m.path, stats);
                }
            }
        }

        if (chunk_modules == null and debug_log.enabled(.mangle_dump)) {
            debug_log.print(.mangle_dump, "module\tsymbol_id\torig\tmangled\tref_count\tkind\tmod_included\n", .{});
            for (collected.top_level_candidates) |cand| {
                const key: unified_mangler.ModuleSymKey = .{ .module_index = cand.module_index, .symbol_id = cand.symbol_id };
                const mangled = result.renames.get(key) orelse cand.name;
                const cand_mod = self.getModule(cand.module_index) orelse continue;
                const sem = cand_mod.semantic orelse continue;
                if (cand.symbol_id >= sem.symbols.items.len) continue;
                const sym = &sem.symbols.items[cand.symbol_id];
                const kind_str = if (sym.synthetic_kind) |sk| @tagName(sk) else "user";
                debug_log.print(.mangle_dump, "{s}\t{d}\t{s}\t{s}\t{d}\t{s}\t{}\n", .{
                    cand_mod.path,
                    cand.symbol_id,
                    cand.name,
                    mangled,
                    cand.ref_count,
                    kind_str,
                    cand_mod.is_included,
                });
            }
        }

        self.unified_result = result;
        self.unified_module_scopes = collected.takeBitsets();
    }

    /// `mangleAll` 의 Phase A(top-level) 결과를 `rename_table` 에 주입한다.
    /// dup 는 canonical_strings 가 소유. result.renames 의 원본 문자열은 linker.deinit
    /// 이 해제 — Phase A 값은 이중 보관이지만 단순성 우선.
    fn injectPhaseARenames(
        self: *Linker,
        candidates: []const unified_mangler.TopLevelCandidate,
        result: *const unified_mangler.UnifiedMangleResult,
    ) !void {
        for (candidates) |cand| {
            const key: unified_mangler.ModuleSymKey = .{ .module_index = cand.module_index, .symbol_id = cand.symbol_id };
            const mangled = result.renames.get(key) orelse continue;
            const cand_mod = self.getModule(cand.module_index) orelse continue;
            const sem = cand_mod.semantic orelse continue;
            if (cand.symbol_id >= sem.symbols.items.len) continue;
            const dup = try self.allocator.dupe(u8, mangled);
            const id = bundler_symbol.SymbolID.make(@as(ModuleIndex, @enumFromInt(cand.module_index)), cand.symbol_id);
            try self.assignSymbolCanonical(id, dup);
        }
    }

    /// 다른 모듈의 리네임 대상으로 이미 할당된 이름인지 O(1) 확인.
    fn isCanonicalNameTaken(self: *const Linker, name: []const u8) bool {
        return self.canonical_names_used.contains(name);
    }

    // ── cross-chunk 전역 일관 네이밍(RFC #3940 / #4101) ─────────────────────────

    /// `(canonical_module, export_name)` 의 cross-chunk 전역 이름을 등록. `global_name` 은
    /// owned(caller 가 dupe 해 넘김) — 맵이 소유하고 `clearCrossChunkGlobalNames`/`deinit` 에서
    /// 해제. `export_name` 키는 borrow(export binding 소유, bundle 수명 안정).
    pub fn putCrossChunkGlobalName(self: *Linker, module_index: u32, export_name: []const u8, global_name: []const u8) !void {
        const gop = try self.cross_chunk_global_names.getOrPut(self.allocator, module_index);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        // 같은 (mod, name) 재등록 시 이전 owned value 해제(leak 방지).
        if (try gop.value_ptr.fetchPut(self.allocator, export_name, global_name)) |old| {
            self.allocator.free(old.value);
        }
    }

    /// cross-chunk 전역 이름 조회. 없으면 null(호출처는 기존 per-chunk fallback).
    pub fn getCrossChunkGlobalName(self: *const Linker, module_index: u32, export_name: []const u8) ?[]const u8 {
        const inner = self.cross_chunk_global_names.get(module_index) orelse return null;
        return inner.get(export_name);
    }

    /// (#4120) consumer 모듈과 canonical 모듈이 *다른* 청크에 있는지. `module_to_chunk` 가
    /// 세팅된 splitting emit 경로에서만 의미 있고, 미세팅(단일번들/finalize)이면 false(=same-chunk).
    /// 둘 중 하나라도 청크 미배정(.none)이면 보수적으로 false(기존 same-chunk preamble 유지).
    pub fn isCrossChunkConsumer(self: *const Linker, consumer_mod: u32, canonical_mod: u32) bool {
        const m2c = self.module_to_chunk orelse return false;
        if (consumer_mod >= m2c.len or canonical_mod >= m2c.len) return false;
        const cc = m2c[consumer_mod];
        const pc = m2c[canonical_mod];
        if (cc.isNone() or pc.isNone()) return false;
        return cc != pc;
    }

    /// 전역 이름 맵 비우기 — owned value 해제 + inner 맵 deinit.
    pub fn clearCrossChunkGlobalNames(self: *Linker) void {
        var it = self.cross_chunk_global_names.valueIterator();
        while (it.next()) |inner| {
            var vit = inner.valueIterator();
            while (vit.next()) |v| self.allocator.free(v.*);
            inner.deinit(self.allocator);
        }
        self.cross_chunk_global_names.clearRetainingCapacity();
    }

    /// (module_index, local_name)의 최종 이름(`rename_table`)을 설정. value 소유권은
    /// canonical_strings로 이전 (caller가 미리 dupe해서 넘김). Symbol을 못 찾으면
    /// value를 free하고 silently noop.
    fn putCanonicalName(self: *Linker, module_index: u32, name: []const u8, value: []const u8) !void {
        const idx = self.findSymbolIdx(module_index, name) orelse {
            self.allocator.free(value);
            return;
        };
        const id = bundler_symbol.SymbolID.make(@as(ModuleIndex, @enumFromInt(module_index)), idx);
        try self.assignSymbolCanonical(id, value);
    }

    /// SymbolID 에 최종 이름(canonical)을 할당하는 단일 write sink. value 소유권을
    /// canonical_strings로 이전 (deinit까지 보관). 같은 id 에 이전 이름이 있으면
    /// used set에서만 제거 후 `rename_table` 에 재기록한다.
    ///
    /// RFC #3940 Sub-PR-L.5c — `Symbol.canonical_name` field 제거 후 rename_table 이 유일 store.
    /// 호출처(`putCanonicalName`/`computeMangling`)는 모두 valid id(`SymbolID.make(real,real)`).
    fn assignSymbolCanonical(self: *Linker, id: bundler_symbol.SymbolID, value: []const u8) !void {
        if (id.isValid()) {
            if (self.rename_table.get(id)) |prior| _ = self.canonical_names_used.fetchRemove(prior);
        }
        try self.canonical_strings.append(self.allocator, value);
        try self.canonical_names_used.put(self.allocator, value, {});
        if (id.isValid()) try self.rename_table.put(self.allocator, id, value);
    }

    /// `assignSymbolCanonical` 의 reuse-hit 전용 변형 — emit 이 소비하는 `rename_table` 만
    /// 채운다. 단일 호출처 = `injectPreservedRenames`(reuse-hit, `PreservedRenames` 스냅샷,
    /// `IncrementalBundler.preserved_renames` 수명).
    ///
    /// 두 가지를 생략한다(reuse-hit 정밀화):
    ///  1. `canonical_strings.append` — `value` 는 스냅샷 소유라 linker.deinit 가 free 하면
    ///     안 됨(double-free/dangling 방지). rename_table/canonical_names_used 는 값 미소유라 put 안전.
    ///  2. `canonical_names_used.put`/`fetchRemove` — `canonical_names_used` 는 deconflict 의
    ///     `isCanonicalNameTaken`(=`findAvailableCandidate`) 만 읽는데, reuse-hit 은 computeRenames/
    ///     deconflict 를 통째로 skip 한다 → 이 맵은 reuse-hit 에서 *write-only(dead)*. 매 entry 의
    ///     put 은 낭비라 생략(lInj 절감). canonical_names_used 는 per-build(deinit) 라 다음 빌드에도
    ///     영향 없음. (fresh rename_table 이라 prior 도 없어 fetchRemove 도 dead.)
    fn assignSymbolCanonicalBorrowed(self: *Linker, id: bundler_symbol.SymbolID, value: []const u8) !void {
        if (id.isValid()) try self.rename_table.put(self.allocator, id, value);
    }

    /// scope_maps[0] → synthetic_name fallback으로 symbol 의 module-local index 찾기.
    /// `putCanonicalName`/`lookupSymbolCanonical` 이 SymbolID 구성에 idx 만 사용한다.
    fn findSymbolIdx(self: *const Linker, module_index: u32, name: []const u8) ?u32 {
        const m = self.getModule(module_index) orelse return null;
        const sem = m.semantic orelse return null;
        if (sem.scope_maps.len > 0) {
            if (sem.scope_maps[0].get(name)) |sym_idx| {
                if (sym_idx < sem.symbols.items.len) return @intCast(sym_idx);
            }
        }
        for (sem.symbols.items, 0..) |*sym, i| {
            if (sym.synthetic_kind != null and std.mem.eql(u8, sym.synthetic_name, name)) {
                return @intCast(i);
            }
        }
        return null;
    }

    /// nested-scope binding(scope_maps[1..]) 의 모든 이름을 1-pass 로 순회한다.
    /// `hasNestedBinding`(단일 lookup) 과 `moduleFingerprint`(집합 해시) 의 **공유
    /// 입력 소스** — 둘이 보는 nested 이름 집합이 정확히 같도록 단일 정의로 묶는다
    /// (드리프트 = G5 가 shadow pass 가 실제로 보는 것과 어긋남 = 정확성 버그).
    /// scope_maps[0](모듈 스코프)은 제외 — 그건 G2 toplevel 해시가 담당.
    fn forEachNestedBindingName(
        m: Module,
        comptime Ctx: type,
        ctx: Ctx,
        comptime cb: fn (Ctx, []const u8) anyerror!void,
    ) !void {
        const sem = m.semantic orelse return;
        for (sem.scope_maps, 0..) |scope_map, scope_idx| {
            if (scope_idx == 0) continue;
            var it = scope_map.iterator();
            while (it.next()) |e| try cb(ctx, e.key_ptr.*);
        }
    }

    /// 모듈의 중첩 스코프 (비-모듈 스코프) 에 해당 이름이 존재하는지 확인.
    /// esbuild/rolldown/rollup 과 동일하게 semantic.scope_maps 직접 scan — scope 깊이는
    /// 보통 1~10 정도라 별도 cache 없이 충분.
    // pub: shared_namespace.zig (RFC #3399 PR-2) 가 동일 scan 을 재사용 (단일 소스 — 복제 제거).
    // 순회하는 scope_maps[1..] 집합은 `forEachNestedBindingName` 과 동일해야 한다
    // (moduleFingerprint G5 해시가 같은 집합을 본다). 여기는 early-return lookup 이라
    // 별도 구현이지만 *순회 범위*(scope_idx != 0)는 한 군데서만 바뀌도록 주석으로 고정.
    pub fn hasNestedBinding(self: *const Linker, module_index: u32, name: []const u8) bool {
        // computeRenames 빌드한 union set 이 있으면 O(1) 멤버십. set 은 scope_maps[1..] 모든 키의
        // 정확한 union 이라 아래 스캔과 *동일* 결과(byte-identical). 미존재(per-chunk/빌드 전)면 스캔.
        if (self.nested_binding_cache.get(module_index)) |set| return set.contains(name);
        const m = self.getModule(module_index) orelse return false;
        const sem = m.semantic orelse return false;
        for (sem.scope_maps, 0..) |scope_map, scope_idx| {
            if (scope_idx == 0) continue;
            if (scope_map.get(name) != null) return true;
        }
        return false;
    }

    /// RFC #3399 PR-2: namespace `X.member` → exp.local 직접 재작성(ns-object
    /// 제거) 이 shadow-safe 한 빌드 경로인가. 안전성은 측정 우연이 아니라
    /// **mangler invariant**: `collectUnifiedInput` 이 namespace target export
    /// 를 항상 importer 의 cross_module_imports 로 등록 → `unified_mangler` 가
    /// 그 mangled 이름을 importer per-module reserved 에 넣어 nested local 이
    /// 절대 같은 이름을 받지 않음 (Debug panic 으로 기계 증명). 단 이는
    /// mangle 활성 시에만 성립 — 비-minify/dev/preserve-modules 는 exp.local
    /// 이 source 이름 그대로라 importer nested binding 과 자기-shadow 충돌
    /// 실재 → 보수적 shadow-skip 유지. 세 플래그 모두 graph 단일 출처에서
    /// 읽어 dev_mode 출처 혼용을 방지한다.
    pub fn nsMemberRewriteSafe(self: *const Linker) bool {
        return self.graph.minify_identifiers and
            !self.graph.preserve_modules and
            !self.graph.dev_mode;
    }

    /// ECMAScript 예약어 + CJS 런타임 + 브라우저/Node 주요 글로벌인지 확인.
    /// 브라우저 글로벌(window, document 등)은 unresolved_references 자동 수집의 안전망.
    /// (해당 글로벌을 참조하지 않는 모듈에서 선언하면 unresolved에 안 잡히므로)
    /// comptime StaticStringMap으로 O(1) 조회.
    pub fn isReservedName(name: []const u8) bool {
        const map = comptime std.StaticStringMap(void).initComptime(.{
            // ECMAScript 예약어 (keywords + future reserved words)
            .{ "break", {} },       .{ "case", {} },       .{ "catch", {} },      .{ "class", {} },
            .{ "const", {} },       .{ "continue", {} },   .{ "debugger", {} },   .{ "default", {} },
            .{ "delete", {} },      .{ "do", {} },         .{ "else", {} },       .{ "enum", {} },
            .{ "export", {} },      .{ "extends", {} },    .{ "false", {} },      .{ "finally", {} },
            .{ "for", {} },         .{ "function", {} },   .{ "if", {} },         .{ "import", {} },
            .{ "in", {} },          .{ "instanceof", {} }, .{ "new", {} },        .{ "null", {} },
            .{ "return", {} },      .{ "super", {} },      .{ "switch", {} },     .{ "this", {} },
            .{ "throw", {} },       .{ "true", {} },       .{ "try", {} },        .{ "typeof", {} },
            .{ "var", {} },         .{ "void", {} },       .{ "while", {} },      .{ "with", {} },
            .{ "yield", {} },       .{ "let", {} },        .{ "static", {} },     .{ "implements", {} },
            .{ "interface", {} },   .{ "package", {} },    .{ "private", {} },    .{ "protected", {} },
            .{ "public", {} },      .{ "await", {} },
            // ECMAScript 특수 식별자 (키워드는 아니지만 변수명으로 사용하면 문제)
                 .{ "undefined", {} },  .{ "NaN", {} },
            .{ "Infinity", {} },    .{ "arguments", {} },  .{ "eval", {} },
            // CJS 런타임 식별자 — 번들러가 합성하는 __commonJS/__require에서 사용.
            // semantic analyzer의 unresolved에 잡히지 않으므로 항상 예약.
                  .{ "require", {} },
            .{ "module", {} },      .{ "exports", {} },    .{ "__filename", {} }, .{ "__dirname", {} },
            // 브라우저/Node 공통 글로벌 — scope hoisting에서 재선언 방지.
            // unresolved_references에 잡히지 않는 경우를 대비한 안전망.
            .{ "window", {} },      .{ "document", {} },   .{ "self", {} },       .{ "globalThis", {} },
            .{ "location", {} },    .{ "navigator", {} },  .{ "console", {} },    .{ "setTimeout", {} },
            .{ "setInterval", {} }, .{ "fetch", {} },      .{ "process", {} },    .{ "global", {} },
        });
        return map.has(name);
    }

    /// JS 예약어이거나 자동 수집된 글로벌 이름인지 확인.
    /// scope hoisting 시 이름 충돌 판별에 사용. isReservedName(키워드) + reserved_globals(미해결 참조).
    fn isReservedOrGlobal(self: *const Linker, name: []const u8) bool {
        return isReservedName(name) or self.reserved_globals.contains(name);
    }

    /// export의 실제 local_name을 조회. default export에서 "default" → "greet" 등.
    /// #1338 Phase 4c-1: linker.export_map 해시 대신 Module 레지스트리 사용.
    /// 모듈당 export 선형 스캔 (< 20개 수준).
    pub fn getExportLocalName(self: *const Linker, module_index: u32, exported_name: []const u8) ?[]const u8 {
        const m = self.getModule(module_index) orelse return null;
        const eb = m.findExportBinding(exported_name) orelse return null;
        return m.exportBindingLocalName(eb.*);
    }

    /// 특정 모듈+이름에 대한 canonical name 조회. 리네임 안 됐으면 null (원본 유지).
    /// scope_maps[0] → synthetic_name 순으로 Symbol 탐색.
    pub fn getCanonicalName(self: *const Linker, module_index: u32, name: []const u8) ?[]const u8 {
        return self.lookupSymbolCanonical(module_index, name);
    }

    fn lookupSymbolCanonical(self: *const Linker, module_index: u32, name: []const u8) ?[]const u8 {
        const idx = self.findSymbolIdx(module_index, name) orelse return null;
        // emit 경로는 build-scope `rename_table` 을 읽는다 — `Symbol.canonical_name` field 는
        // RFC #3940 Sub-PR-L.5c 에서 제거됨. miss → null (원본 이름 유지).
        return self.rename_table.get(bundler_symbol.SymbolID.make(@as(ModuleIndex, @enumFromInt(module_index)), idx));
    }

    /// ExportBinding의 canonical local name을 kind별 safe한 방법으로 조회.
    /// `.local`은 `eb.symbol`(semantic) 기반 ref 조회; 그 외는 문자열 조회.
    /// `.re_export` alias는 chain-resolved canonical을 쓰므로 final exports/scope
    /// hoisting에서 원하는 "현재 모듈 rename"과 다름 → 문자열 경로 유지.
    pub fn getCanonicalForExport(self: *const Linker, eb: ExportBinding, module_index: u32) []const u8 {
        const m = self.getModule(module_index).?;
        const local = m.exportBindingLocalName(eb);
        if (eb.kind == .local) {
            const canonical = self.getCanonicalByRef(eb.symbol) orelse local;
            return self.safeIdentifierName(canonical, module_index);
        }
        return self.getCanonicalName(module_index, local) orelse local;
    }

    /// SymbolRef 기반 canonical name 조회 facade. #1328 Phase 4c-3.
    /// - alias: AliasTable이 canonical_name 소유 → 직접 반환 (별도 모델).
    /// - semantic: build-scope `rename_table` 조회 (RFC #3940 — `Symbol.canonical_name` field 는
    ///   L.5c 에서 제거됨). bounds 밖이면 null.
    /// 리네임 안 됐으면 null — caller가 원본 이름으로 fallback.
    pub fn getCanonicalByRef(self: *const Linker, ref: bundler_symbol.SymbolRef) ?[]const u8 {
        if (!ref.isValid()) return null;
        const m = self.graph.getModule(ref.moduleIndex()) orelse return null;
        return switch (ref) {
            .alias => |a| blk: {
                const t = if (m.alias_table) |*at| at else break :blk null;
                break :blk if (t.hasCanonicalName(a.symbol)) t.getCanonicalName(a.symbol) else null;
            },
            .semantic => |s| blk: {
                const sem = m.semantic orelse break :blk null;
                const idx: u32 = @intFromEnum(s.symbol);
                if (idx >= sem.symbols.items.len) break :blk null;
                break :blk self.rename_table.get(bundler_symbol.SymbolID.make(s.module, idx));
            },
        };
    }

    // ================================================================
    // Metadata 빌드 — linker/metadata.zig로 위임
    // ================================================================
    const metadata_mod = @import("linker/metadata.zig");
    pub const buildSkipNodes = metadata_mod.buildSkipNodes;
    pub const buildMetadataForAst = metadata_mod.buildMetadataForAst;
    pub const buildRequireRewrites = metadata_mod.buildRequireRewrites;
    pub const buildFinalExports = metadata_mod.buildFinalExports;
    pub const ConstValuesProfile = metadata_mod.ConstValuesProfile;
    pub const buildCrossModuleConstValues = metadata_mod.buildCrossModuleConstValues;
    pub const buildCrossModuleConstValuesProfiled = metadata_mod.buildCrossModuleConstValuesProfiled;
    pub const finalizeNamespaceData = metadata_mod.finalizeNamespaceData;
    pub const buildDevMetadataForAst = metadata_mod.buildDevMetadataForAst;
    pub const buildMetadata = metadata_mod.buildMetadata;

    fn buildExportMap(self: *Linker) !void {
        var scope = profile.begin(.link_build_export_map);
        defer scope.end();

        for (0..self.graph.moduleCount()) |i| {
            const m = self.getModule(@intCast(i)) orelse continue;
            const mod_idx: ModuleIndex = @enumFromInt(@as(u32, @intCast(i)));
            for (m.export_bindings) |eb| {
                if (std.mem.eql(u8, eb.exported_name, "*")) continue;
                const key = try makeExportKey(self.allocator, @intCast(i), eb.exported_name);
                // C2 수정: 중복 키 시 이전 키 해제
                if (self.export_map.fetchRemove(key)) |old| {
                    self.allocator.free(old.key);
                }
                try self.export_map.put(self.allocator, key, .{
                    .binding = eb,
                    .module_index = mod_idx,
                });
            }
        }
    }

    /// 모든 모듈의 import 바인딩을 해석하여 canonical export에 연결.
    fn resolveImports(self: *Linker) !void {
        var scope = profile.begin(.link_resolve_imports);
        defer scope.end();

        for (0..self.graph.moduleCount()) |i| {
            const m = self.getModule(@intCast(i)) orelse continue;
            for (m.import_bindings) |ib| {
                if (ib.kind == .namespace) continue; // namespace import는 별도 처리 (후순위)

                const source_record = if (ib.import_record_index < m.import_records.len)
                    m.import_records[ib.import_record_index]
                else
                    continue;

                if (source_record.resolved.isNone()) continue; // external 또는 미해석

                // re-export 체인을 따라가서 canonical export 찾기. synthetic_named_exports(직접 import
                // 또는 barrel re-export forwarding)는 resolveExportChain 이 canonical.synthetic_member 로
                // 전달한다(한 곳 통합).
                const canonical = self.resolveExportChain(
                    source_record.resolved,
                    ib.imported_name,
                    0,
                ) orelse {
                    // export를 찾을 수 없음 — 내부 진단(self.diagnostics, 테스트/디버그용) 유지.
                    self.addDiag(
                        .missing_export,
                        .@"error",
                        m.path,
                        ib.local_span,
                        .link,
                        "Imported name not found in module",
                        ib.imported_name,
                    );
                    // (#3978) 사용자 노출(BundleResult)은 *진짜 누락*만. resolveExportChain
                    // null 은 CJS 동적 exports / TS namespace·interface·const-enum / default-fn /
                    // handled-elsewhere 등 false-null 이 대부분(계측: unit 137 중 ~133 false).
                    // semantic.exported_names(analyzer 가 type-space 포함 *모든* export 이름 기록)를
                    // chain-aware 로 조회해 진짜 누락만 가려낸다. CJS/helper/type-only/shim 은 제외.
                    // esbuild/rolldown parity. (export_bindings 는 TS 구문 미기록이라 사용 불가.)
                    const tgt_cjs = if (self.graph.getModule(source_record.resolved)) |t| t.wrap_kind == .cjs else true;
                    var type_only = false;
                    // value_used: importer 의 로컬 바인딩이 *값* 위치에서 참조되는가. 미해결
                    // import 는 local_symbol 이 invalid 라 isImportBindingTypeOnly 가 판정 못 하므로
                    // module scope(scope_maps[0])에서 local_name → symbol 을 찾아 references 의
                    // value-use 를 직접 확인한다. type-only(타입 위치만 사용, strip)·미사용 import 는
                    // false → 진단 surface 안 함(런타임에 식별자가 emit 되지 않아 ReferenceError 없음).
                    var value_used = false;
                    if (m.semantic) |*sem| {
                        type_only = metadata_mod.isImportBindingTypeOnly(sem, ib);
                        if (sem.scope_maps.len > 0) {
                            if (sem.scope_maps[0].get(ib.local_name)) |sym_idx| {
                                for (sem.references) |r| {
                                    if (@intFromEnum(r.symbol_id) == sym_idx and r.isValueUse()) {
                                        value_used = true;
                                        break;
                                    }
                                }
                            }
                        }
                    }
                    // (#3982) ambiguous export*: 같은 이름이 2+ distinct star 소스에서
                    // 도달하면 resolveExportChain 이 null 을 주지만 이는 *누락*이 아니라
                    // *모호*다(ESM spec). named import 는 esbuild/rolldown/Node 처럼 build
                    // error 로 surface. 값으로 쓰는 import 만(미사용/type-only 제외).
                    if (value_used and !ib.is_helper and
                        self.resolveStarExport(source_record.resolved, ib.imported_name, 0) == .ambiguous)
                    {
                        const msg = std.fmt.allocPrint(self.allocator, "Ambiguous import \"{s}\" — exported by multiple modules via \"export *\"", .{ib.imported_name}) catch {
                            continue;
                        };
                        self.fatal_diagnostics.append(self.allocator, .{
                            .code = .ambiguous_export,
                            .severity = .@"error",
                            .message = msg,
                            .file_path = m.path,
                            .span = ib.local_span,
                            .step = .link,
                            .suggestion = ib.imported_name,
                        }) catch self.allocator.free(msg);
                        continue;
                    }
                    const genuine = value_used and !ib.is_helper and !tgt_cjs and !type_only and
                        !self.shim_missing_exports and
                        !self.moduleHasExportName(source_record.resolved, ib.imported_name, 0);
                    if (genuine) {
                        const msg = std.fmt.allocPrint(self.allocator, "No matching export \"{s}\" in module", .{ib.imported_name}) catch {
                            continue;
                        };
                        self.fatal_diagnostics.append(self.allocator, .{
                            .code = .missing_export,
                            .severity = .@"error",
                            .message = msg,
                            .file_path = m.path,
                            .span = ib.local_span,
                            .step = .link,
                            .suggestion = ib.imported_name,
                        }) catch self.allocator.free(msg);
                    }
                    continue;
                };

                const bk = BindingKey{
                    .module_index = @intCast(i),
                    .span_key = types.spanKey(ib.local_span),
                };
                try self.resolved_bindings.put(self.allocator, bk, .{
                    .local_name = ib.local_name,
                    .local_span = ib.local_span,
                    .canonical = canonical,
                });
            }
        }
    }

    /// re-export 체인을 따라가서 canonical export를 찾는다.
    /// 깊이 제한 100 (순환 re-export 방지).
    /// `(module, export_name)` → 그 export 가 궁극적으로 가리키는 declaring
    /// 모듈의 `.semantic` SymbolRef. resolveExportChain 으로 re-export chain 을
    /// 끝까지 따라간 뒤 declaring 모듈 export_bindings 에서 exported_name 매칭.
    /// chain 미해결 / 매칭 없음 / non-semantic(외부·shim) 은 null.
    /// `.alias` import 와 namespace member 접근이 공유하는 source 도출 (RFC #3288).
    fn resolveSemanticExportSource(self: *const Linker, module_idx: ModuleIndex, name: []const u8) ?bundler_symbol.SymbolRef {
        const chain = self.resolveExportChain(module_idx, name, 0) orelse return null;
        const cm = self.getModule(@intFromEnum(chain.module_index)) orelse return null;
        for (cm.export_bindings) |eb| {
            if (std.mem.eql(u8, eb.exported_name, chain.export_name)) {
                return if (eb.symbol == .semantic) eb.symbol else null;
            }
        }
        return null;
    }

    /// (#3978) scanner-level export 존재 여부(chain-aware). resolveExportChain 은
    /// 해석(rename/symbol) 까지 모델하느라 CJS 동적 exports·TS namespace/interface/
    /// const-enum·default-function 등을 false-null 로 떨군다. 이 함수는 semantic
    /// analyzer 가 기록한 *완전한* export-name 집합(exported_names — type-space 포함)을
    /// 조회해 "export 가 선언돼 있는가" 만 본다. missing_export 진단을 진짜 누락에만
    /// surface 하기 위한 보수적 게이트 — 불확실(모듈/semantic 부재·깊이초과·CJS)하면
    /// "있음"(true)으로 처리해 false-positive 진단을 피한다.
    pub fn moduleHasExportName(self: *const Linker, module_idx: ModuleIndex, name: []const u8, depth: u32) bool {
        if (depth > max_chain_depth) return true; // 불확실 → 보수적
        const m = self.graph.getModule(module_idx) orelse return true;
        if (m.wrap_kind == .cjs) return true; // CJS: 동적 exports, 정적 확인 불가 → 있다고 가정
        const sem = if (m.semantic) |*s| s else return true; // semantic 부재 → 보수적
        // exported_names: analyzer 가 기록한 named/default/re-export 이름 집합.
        if (sem.exported_names.contains(name)) return true;
        // namespace / const-enum 등 exported_names 에 안 잡히는 export 는 module-scope
        // 심볼의 is_exported 플래그로 추가 확인.
        if (sem.scope_maps.len > 0) {
            if (sem.scope_maps[0].get(name)) |sym_idx| {
                if (sym_idx < sem.symbols.items.len and sem.symbols.items[sym_idx].decl_flags.is_exported) return true;
            }
        }
        // export * from <src>: 구체 이름은 exported_names 에 없으므로 소스로 재귀
        // (ESM spec: export * 는 default 제외).
        if (!std.mem.eql(u8, name, "default")) {
            for (m.export_bindings) |eb| {
                if (eb.kind.isReExportAll() and std.mem.eql(u8, eb.exported_name, "*")) {
                    const rec_idx = eb.import_record_index orelse continue;
                    if (rec_idx >= m.import_records.len) continue;
                    const src = m.import_records[rec_idx].resolved;
                    if (!src.isNone() and self.moduleHasExportName(src, name, depth + 1)) return true;
                }
            }
        }
        // 여기 도달 = 이름 미발견. exported_names 가 *비어있으면* 이 모듈의 export 가
        // semantic 에 캡처되지 않은 형태(TS namespace/const-enum, ESM-wrap/scope-hoist 등)
        // → 모델 불완전이므로 보수적으로 "있음"(true) 처리해 false-positive 진단을 피한다.
        // 비어있지 않으면(실제 export 가 캡처됨) 진짜 미발견 → false(genuine missing).
        if (sem.exported_names.count() == 0) return true;
        return false;
    }

    pub fn resolveExportChain(
        self: *const Linker,
        module_idx: ModuleIndex,
        name: []const u8,
        depth: u32,
    ) ?SymbolRef {
        if (depth > max_chain_depth) return null;

        const mod_i = @intFromEnum(module_idx);
        if (mod_i >= self.graph.moduleCount()) return null;

        // 메모이제이션: chain_cache가 활성화된 경우에만 캐시 조회/저장.
        // re-export chain이 없는 단순 그래프에서는 캐시 오버헤드가 이득보다 큼.
        // depth=0에서만 캐시 (재귀 호출은 chain 내부라 캐시 불필요).
        if (depth == 0 and self.chain_cache_enabled) {
            var cache_key_buf: [4096]u8 = undefined;
            const cache_key = types.makeModuleKeyBuf(&cache_key_buf, @intCast(mod_i), name);
            if (self.chain_cache.get(cache_key)) |entry| {
                return entry.result;
            }

            const result = self.resolveExportChainInner(module_idx, name, depth, true);

            const owned_key = self.allocator.dupe(u8, cache_key) catch return result;
            const mutable_self: *Linker = @constCast(self);
            mutable_self.chain_cache.put(self.allocator, owned_key, .{ .result = result }) catch {
                self.allocator.free(owned_key);
            };
            return result;
        }

        return self.resolveExportChainInner(module_idx, name, depth, true);
    }

    /// resolveExportChain 내부 구현 (캐시 없이).
    /// `allow_synthetic`: synthetic_named_exports fallback(#3664 P2)을 적용할지. 직접 named import·
    /// named re-export forwarding 경로는 true, `export *`(re_export_all)는 false — Rollup 은 synthetic
    /// 이름을 non-enumerable 로 보아 star 로 전파하지 않으며, true 면 임의 이름이 synthetic.member 로
    /// 잘못 resolve 되어 missing_export 진단이 억제된다(code-review max 적발).
    fn resolveExportChainInner(
        self: *const Linker,
        module_idx: ModuleIndex,
        name: []const u8,
        depth: u32,
        allow_synthetic: bool,
    ) ?SymbolRef {
        if (depth > max_chain_depth) return null;

        const mod_i = @intFromEnum(module_idx);
        const m_any = self.graph.getModule(module_idx) orelse return null;

        // 1. 직접 export 확인
        var key_buf: [4096]u8 = undefined;
        const key = makeExportKeyBuf(&key_buf, @intCast(mod_i), name);
        if (self.export_map.get(key)) |entry| {
            if (entry.binding.kind == .re_export) {
                // re-export: 소스 모듈로 재귀
                if (entry.binding.import_record_index) |rec_idx| {
                    const m = m_any;
                    if (rec_idx < m.import_records.len) {
                        const source_mod = m.import_records[rec_idx].resolved;
                        if (!source_mod.isNone()) {
                            // namespace re-export (import * as ns; export { ns }):
                            // local_name이 "*"이면 소스 모듈에서 named export를 찾을 수 없으므로
                            // 현재 모듈의 바인딩을 반환 (namespace 객체는 linker가 생성)
                            if (std.mem.eql(u8, entry.binding.local_name, "*")) {
                                return .{
                                    .module_index = module_idx,
                                    .export_name = name,
                                };
                            }
                            // named re-export forwarding 은 synthetic 허용(barrel `export {foo} from synth`).
                            if (self.resolveOrCjsFallback(source_mod, entry.binding.local_name, depth + 1, true)) |result| {
                                return result;
                            }
                        }
                    }
                }
                return null;
            }
            // .local export: binding_scanner가 named barrel re-export는 .re_export로
            // 분류하지만, namespace barrel re-export는 .local로 유지한다.
            // namespace import인 경우 현재 모듈의 바인딩을 반환.
            const m_local = m_any;
            for (m_local.import_bindings) |ib| {
                if (std.mem.eql(u8, ib.local_name, entry.binding.local_name)) {
                    if (ib.kind == .namespace) {
                        return .{
                            .module_index = module_idx,
                            .export_name = name,
                        };
                    }
                    // binding_scanner의 re_export 분류를 우회한 named barrel re-export fallback
                    if (ib.import_record_index < m_local.import_records.len) {
                        const source_mod = m_local.import_records[ib.import_record_index].resolved;
                        if (!source_mod.isNone()) {
                            return self.resolveExportChainInner(source_mod, ib.imported_name, depth + 1, true);
                        }
                    }
                    break;
                }
            }
            return .{
                .module_index = module_idx,
                .export_name = name,
            };
        }

        // 2. export * 확인 (re_export_all). 모든 star 소스를 스캔해 동일 이름이
        // 2개 이상의 서로 다른 canonical 에서 도달하면 ESM spec 상 ambiguous(접근 불가)
        // → null 반환(#3982). diamond(같은 underlying 2경로)는 ambiguous 아님.
        const m = m_any;
        switch (self.resolveStarExport(module_idx, name, depth)) {
            .resolved => |result| return result,
            .ambiguous => return null,
            .none => {},
        }

        // 3. #3664 P2: synthetic_named_exports — 정적/re-export/export* 어디서도 못 찾으면 fallback
        // 대상(default/named) export 의 member 로 해석한다. target export 를 resolve 하고 synthetic_member
        // 에 원래 이름을 담아 codegen 이 `{target local}.{member}` 로 rename 하게 한다. 이 한 곳에서
        // 처리하므로 직접 named import 와 barrel re-export forwarding 이 통합되고 tree_shaker 도
        // resolveExportChain 으로 자동 따라온다. target 자기 참조(default→default)는 가드 + depth 로
        // bounded(무한 재귀 방지).
        if (allow_synthetic) {
            if (m.synthetic_named_exports) |target| {
                if (!std.mem.eql(u8, target, name)) {
                    if (self.resolveExportChainInner(module_idx, target, depth + 1, true)) |result| {
                        // nested synthetic(target 자체가 또 synthetic 의 member)은 단일 member access
                        // 로 표현 불가 → bail(missing). 단일 hop synthetic 만 지원.
                        if (result.synthetic_member != null) return null;
                        return .{
                            .module_index = result.module_index,
                            .export_name = result.export_name,
                            .synthetic_member = name,
                        };
                    }
                }
            }
        }

        return null;
    }

    /// resolveExportChain + CJS fallback. CJS 모듈은 정적 export가 없으므로
    /// resolve 실패 시 CJS 모듈 자체를 반환하여 소비자가 require_xxx()로 접근.
    fn resolveOrCjsFallback(self: *const Linker, source_mod: ModuleIndex, name: []const u8, depth: u32, allow_synthetic: bool) ?SymbolRef {
        if (self.resolveExportChainInner(source_mod, name, depth, allow_synthetic)) |result| return result;
        if (self.graph.getModule(source_mod)) |sm| {
            if (sm.wrap_kind == .cjs and sm.has_cjs_export_signal) return .{ .module_index = source_mod, .export_name = name };
        }
        return null;
    }

    /// 두 SymbolRef 가 같은 canonical(동일 정의)을 가리키는지. diamond(같은 underlying
    /// 모듈이 여러 경로로 re-export)는 ambiguous 가 아니므로 이 비교로 구별한다. #3982
    fn sameCanonical(a: SymbolRef, b: SymbolRef) bool {
        if (@intFromEnum(a.module_index) != @intFromEnum(b.module_index)) return false;
        if (!std.mem.eql(u8, a.export_name, b.export_name)) return false;
        const am = a.synthetic_member;
        const bm = b.synthetic_member;
        if (am == null and bm == null) return true;
        if (am == null or bm == null) return false;
        return std.mem.eql(u8, am.?, bm.?);
    }

    const StarResolve = union(enum) {
        /// star 소스 어디에서도 못 찾음
        none,
        /// 정확히 하나의 canonical 로 해석(또는 diamond — 모두 같은 canonical)
        resolved: SymbolRef,
        /// 2개 이상의 서로 다른 canonical 에서 도달 — ESM spec ambiguous
        ambiguous,
    };

    /// 모듈이 직접 export 하지 않으면서 2+ distinct `export *` 소스에서 같은 이름이
    /// 도달하는지(ESM ambiguous). namespace 멤버 rewrite(shared_namespace.zig)가
    /// ambiguous 멤버를 `void 0` 으로 매핑하기 위해 호출 — named 경로와 동일한
    /// resolveStarExport 판정을 공유해 drift 를 막는다. #3982
    /// 직접 export(또는 named re-export)면 그 정의가 우선이라 ambiguous 아님.
    pub fn isAmbiguousStarExport(self: *const Linker, module_idx: ModuleIndex, name: []const u8) bool {
        var key_buf: [4096]u8 = undefined;
        const dk = makeExportKeyBuf(&key_buf, module_idx.toU32(), name);
        if (self.export_map.contains(dk)) return false;
        return self.resolveStarExport(module_idx, name, 0) == .ambiguous;
    }

    /// `export * from` (exported_name=="*") re-export 개수. ambiguity 는 2+ star
    /// 소스에서만 가능하므로, 흔한 0~1 star 모듈에서 ambiguity 스캔을 건너뛰는 게이트.
    pub fn starReExportCount(self: *const Linker, module_idx: ModuleIndex) usize {
        const m = self.graph.getModule(module_idx) orelse return 0;
        var n: usize = 0;
        for (m.export_bindings) |eb| {
            if (eb.kind.isReExportAll() and std.mem.eql(u8, eb.exported_name, "*")) n += 1;
        }
        return n;
    }

    /// 모듈의 모든 `export *` 소스를 스캔해 `name` 의 해석 결과를 반환(#3982).
    /// 첫 매칭에서 멈추지 않고 전 소스를 확인 — 2+ distinct canonical 이면 ambiguous.
    /// resolveExportChainInner step2(named/re-export/tree-shake 경로)와 ambiguity
    /// 진단(resolveImports)이 공유해 스캔 로직 drift 를 방지한다.
    ///
    /// plain `export * from`(exported_name=="*")만 따른다. `export * as ns from`
    /// (re_export_namespace)은 단일 named export `ns`만 기여하고 소스의 *임의* 이름을
    /// 현재 namespace 로 끌어오지 않는다 — 따라가면 그 inner 이름(예: coerce.string)이
    /// plain star 소스의 동명 export(schemas.string)와 false-ambiguous 충돌해 정상
    /// export 가 사라진다(zod `z.string`===undefined 회귀). isReExportAll() 단독은
    /// 두 종류를 모두 포함하므로 exported_name=="*" 게이트를 함께 적용한다.
    fn resolveStarExport(self: *const Linker, module_idx: ModuleIndex, name: []const u8, depth: u32) StarResolve {
        const m = self.graph.getModule(module_idx) orelse return .none;
        var found: ?SymbolRef = null;
        var found_is_cjs = false;
        for (m.export_bindings) |eb| {
            if (!(eb.kind.isReExportAll() and std.mem.eql(u8, eb.exported_name, "*"))) continue;
            const rec_idx = eb.import_record_index orelse continue;
            if (rec_idx >= m.import_records.len) continue;
            const source_mod = m.import_records[rec_idx].resolved;
            if (source_mod.isNone()) continue;
            // CJS fallback은 실제 `module.exports`/`exports.*` 소스에만 유효. synthetic 은
            // star 전파 금지(allow_synthetic=false) — Rollup 동일.
            const result = self.resolveOrCjsFallback(source_mod, name, depth + 1, false) orelse continue;
            // resolveOrCjsFallback 은 CJS 소스에 대해 *임의의* 이름을 매칭(동적 exports)으로
            // 반환한다. 따라서 CJS 결과는 그 이름을 정적으로 *정의한다고 증명할 수 없으므로*
            // ambiguity 판정에서 제외한다 — 2+ CJS star 가 모든 이름을 거짓-ambiguous 로
            // 만드는 것을 방지(#3975 다중 CJS star). 런타임에 __copyProps first-wins 로 병합.
            // ESM 정적 export 끼리의 충돌만 진짜 ambiguous(#3982).
            const result_is_cjs = if (self.graph.getModule(result.module_index)) |rm| rm.wrap_kind == .cjs else false;
            if (found) |f| {
                if (!result_is_cjs and !found_is_cjs and !sameCanonical(f, result)) return .ambiguous;
                // 정적(ESM) 결과를 CJS 동적 결과보다 우선.
                if (found_is_cjs and !result_is_cjs) {
                    found = result;
                    found_is_cjs = false;
                }
            } else {
                found = result;
                found_is_cjs = result_is_cjs;
            }
        }
        return if (found) |f| .{ .resolved = f } else .none;
    }

    /// namespace 식별자가 member access 이외의 위치에서 사용되는지 판별.
    /// `ns.prop`만 사용되면 false (직접 치환 가능), `console.log(ns)` 등이면 true (객체 필요).
    pub fn isNamespaceUsedAsValue(allocator: std.mem.Allocator, ast: *const Ast, symbol_ids: []const ?u32, ns_sym_id: u32) bool {
        return namespace_access.isNamespaceUsedAsValue(allocator, ast, symbol_ids, ns_sym_id);
    }

    /// namespace re-export (`import * as X; export { X };`) 가 cross-module 에서
    /// transitively 사용되는지. metadata.zig 의 force_inline 결정 (3 caller) 이
    /// 공유 — unused re-export 는 X_ns inline literal 생성 skip → effect 같은
    /// namespace-heavy 라이브러리에서 dead X_ns elide.
    /// tree_shaker 미활성 (단위 테스트) 이면 보수적 true (기존 동작 유지).
    pub fn isNamespaceExportConsumed(self: *const Linker, module_index: u32, local_name: []const u8) bool {
        const ts = self.tree_shaker orelse return true;
        return ts.isExportUsed(module_index, local_name);
    }

    pub const NamespaceAccess = namespace_access.NamespaceAccess;

    /// namespace 심볼의 모든 참조를 스캔해 member-only 접근 여부와 접근된 프로퍼티 집합을 수집.
    /// tree-shaker가 이 정보를 바탕으로 target 모듈의 `export` 중 실제 필요한 것만 live로 표시.
    pub fn analyzeNamespaceAccess(
        allocator: std.mem.Allocator,
        ast: *const Ast,
        symbol_ids: []const ?u32,
        ns_sym_id: u32,
        /// top-level statement의 source span. 전달하면 각 access의 owning stmt 인덱스를
        /// `members[prop]`에 기록 (#1626 dead-scope gating). null이면 기록하지 않는다.
        stmt_spans: ?[]const Span,
    ) std.mem.Allocator.Error!NamespaceAccess {
        return namespace_access.analyzeNamespaceAccess(allocator, ast, symbol_ids, ns_sym_id, stmt_spans);
    }

    /// SymbolRef를 scope hoisting 후 최종 로컬 이름으로 해결.
    /// resolveExportChain → getExportLocalName → getCanonicalName 3단계를 캡슐화.
    pub fn resolveToLocalName(self: *const Linker, ref: SymbolRef) []const u8 {
        const cmod = ref.module_index.toU32();
        const local = self.getExportLocalName(cmod, ref.export_name) orelse ref.export_name;
        const canonical = self.getCanonicalName(cmod, local) orelse local;
        return self.safeIdentifierName(canonical, cmod);
    }

    /// #1328 Phase 3b: 각 모듈의 `re_export_alias` 합성 심볼에 대해 체인 resolve를
    /// 수행하고, 결과를 `canonical_name`에 저장한다. Phase 3c에서 emitter가 이 값을
    /// 직접 읽어 문자열 기반 `resolveExportChain` 호출을 제거한다.
    ///
    /// link() 이후에 호출되어야 한다 — export_map과 canonical_names가 준비된 상태를 전제.
    pub fn populateReExportAliases(self: *const Linker) void {
        var scope = profile.begin(.link_populate_re_export_aliases);
        defer scope.end();

        const count = self.graph.moduleCount();
        for (0..count) |idx| {
            const m = self.moduleAtMut(@intCast(idx)) orelse continue;
            const mod_idx: ModuleIndex = ModuleIndex.fromUsize(idx);
            const table_ptr = if (m.alias_table) |*t| t else continue;
            for (m.export_bindings) |eb| {
                if (eb.kind != .re_export) continue;
                const sym_id = switch (eb.symbol) {
                    .alias => |a| blk: {
                        if (a.module != mod_idx) break :blk null;
                        if (a.symbol.isNone()) break :blk null;
                        break :blk a.symbol;
                    },
                    else => null,
                } orelse continue;

                const ref = self.resolveExportChain(mod_idx, eb.exported_name, 0) orelse continue;
                const name = self.resolveToLocalName(ref);
                table_ptr.setCanonicalName(sym_id, name);
            }
        }
    }

    /// #1328 Phase 4d: 모든 모듈의 import_bindings를 훑어 source 모듈 export 심볼의
    /// `ref_count`를 증가시킨다. Tree-shaking의 companion metric — "몇 개 모듈이 이
    /// export를 참조하나"를 symbol level에서 집계.
    ///
    /// 현재 tree_shaker가 statement-level reachability로 수행하는 분석과 별개로,
    /// symbol 기반 usage 데이터를 축적한다. Phase 4e 이후 tree-shaker가 이 값을
    /// 활용하도록 통합할 예정.
    ///
    /// link() + populateReExportAliases() 이후에 호출되어야 한다.
    /// #1338 Phase 4c-2: ib.symbol로 직접 전환 — export_map 해시 lookup 제거.
    pub fn populateSymbolRefCounts(self: *const Linker) void {
        const count = self.graph.moduleCount();
        for (0..count) |i| {
            const importer = self.getModule(@intCast(i)) orelse continue;
            for (importer.import_bindings) |ib| {
                if (!ib.symbol.isValid()) continue;
                const source = self.graph.moduleAtMut(ib.symbol.moduleIndex()) orelse continue;
                switch (ib.symbol) {
                    .alias => |a| {
                        const table_ptr = if (source.alias_table) |*t| t else continue;
                        // Cached import_binding 이 rebuild 된 source 의 새 alias_table 보다
                        // 많은 alias id 를 가리킬 수 있어 (e.g. source 가 재파싱되며 re_export
                        // 엔트리가 줄어든 경우) 경계 검사. 벗어난 참조는 이번 build 에서
                        // stale — ref_count 증가 건너뜀.
                        if (@intFromEnum(a.symbol) >= table_ptr.count()) continue;
                        table_ptr.incRefCount(a.symbol);
                    },
                    .semantic => |s| {
                        const sem_ptr = if (source.semantic) |*sem| sem else continue;
                        const idx: u32 = @intFromEnum(s.symbol);
                        if (idx >= sem_ptr.symbols.items.len) continue;
                        sem_ptr.symbols.items[idx].reference_count += 1;
                    },
                }
            }
        }
    }

    /// 모든 모듈의 ImportBinding 심볼 필드를 채운다:
    ///   - `symbol`: source 모듈의 export SymbolRef (cross-module redirect).
    ///     invalid 유지는 source 모듈이 해당 export를 갖지 않는 경우.
    ///   - `local_symbol`: 현재 모듈 semantic top-level 심볼 (current-side 조회용).
    /// `populateReExportAliases` 이후에 호출되어야 alias canonical이 반영됨.
    pub fn populateImportSymbols(self: *const Linker) void {
        var scope = profile.begin(.link_populate_import_symbols);
        defer scope.end();

        const count = self.graph.moduleCount();
        for (0..count) |i| {
            const importer = self.moduleAtMut(@intCast(i)) orelse continue;
            const sem_opt = importer.semantic;
            const module_scope_opt = if (sem_opt) |sem|
                if (sem.scope_maps.len > 0) sem.scope_maps[0] else null
            else
                null;
            const mod_idx: bundler_symbol.ModuleIndex = @enumFromInt(i);

            for (importer.import_bindings) |*ib| {
                // current-side: scope_maps[0]에서 로컬 심볼 조회.
                // #3068: helper binding 은 user 가 같은 이름을 선언했어도 격리된
                // helper_scope_map 에서 lookup. 일반 module_scope.get 가 user 의 sym_idx 를
                // 반환하면 JSX call 이 user binding 으로 잘못 묶인다.
                if (module_scope_opt) |module_scope| {
                    const sym_lookup = if (ib.is_helper) blk: {
                        if (importer.semantic) |*sem| {
                            if (sem.helper_scope_map.get(ib.local_name)) |sym_idx| break :blk @as(?usize, sym_idx);
                        }
                        break :blk @as(?usize, null);
                    } else module_scope.get(ib.local_name);
                    if (sym_lookup) |sym_idx| {
                        ib.local_symbol = bundler_symbol.SymbolRef.makeSemantic(mod_idx, sym_idx);
                    }
                }

                // source-side: import_record 따라 source 모듈의 export 심볼 복사
                if (ib.import_record_index >= importer.import_records.len) continue;
                const source_mod_idx = importer.import_records[ib.import_record_index].resolved;
                if (source_mod_idx.isNone()) continue;
                const source = self.graph.getModule(source_mod_idx) orelse continue;
                // namespace import는 개별 심볼이 아닌 모듈 전체를 가리킴 — skip.
                if (ib.kind == .namespace) continue;
                if (source.findExportBinding(ib.imported_name)) |eb| {
                    ib.symbol = eb.symbol;
                }
            }
        }
    }

    /// `ib`가 특정 re-export의 consumer인지 판별 (#1603 공용 predicate).
    /// tree_shaker / emitter/chunks에서 "이 re-export를 통해 import한 .named 바인딩"을
    /// 찾는 순회에 공통 사용.
    pub fn isReExportNsConsumer(
        consumer: Module,
        ib: ImportBinding,
        reexporter_idx: u32,
        reexport_name: []const u8,
    ) bool {
        if (ib.kind != .named) return false;
        if (ib.import_record_index >= consumer.import_records.len) return false;
        const resolved = consumer.import_records[ib.import_record_index].resolved;
        if (resolved == .none) return false;
        if (@intFromEnum(resolved) != reexporter_idx) return false;
        return std.mem.eql(u8, ib.imported_name, reexport_name);
    }

    /// 두 가지 post-link 정밀화를 수행한다 (#1616):
    ///
    /// 1. `.named` + virtual namespace (`import { M } from './idx'`가
    ///    `export * as M from './src'`를 겨냥) — `collectNamespaceAccesses`가
    ///    `.named` 바인딩을 namespace로 보지 않아 null로 남는 것을 채움.
    ///
    /// 2. `.namespace` 재정밀화 — `collectNamespaceAccesses`는 text-based
    ///    identifier matching이라 함수 파라미터/로컬 선언에 의한 shadowing을
    ///    감지 못해 false-positive escape로 null을 설정하는 경우가 많다
    ///    (예: Effect `export const sort = dual(2, (self, O) => ...)` —
    ///    파라미터 O가 `import * as O`를 shadow해도 text match로는 탈출).
    ///    `analyzeNamespaceAccess`는 `semantic.symbol_ids` 기반이라 scope-aware.
    ///    `.namespace` 바인딩은 collectNamespaceAccesses 결과를 신뢰하지 않고
    ///    symbol-aware 판정으로 **덮어쓴다**.
    pub fn populateNamespaceAccesses(self: *const Linker) void {
        var scope = profile.begin(.link_populate_namespace_accesses);
        defer scope.end();

        // 보존-hit(carrier non-null = 위상 보존): lNs 출력(ib.namespace_used_properties)은 모듈
        // parse_arena 소유(AST-resident)라 unchanged 모듈은 직전 빌드 값이 보존된다 → **변경 ∪
        // 직접 importer** 만 재계산하고 나머지는 skip(byte-identical). 변경 모듈=재파싱(fresh AST →
        // 값 null)이라 재계산 필수, 변경 모듈을 import 하는 모듈=직접 source 의 게이팅(wrap_kind /
        // default_export_named_local / re_export_namespace)이 바뀔 수 있어 재계산. per-importer
        // 분석은 importer 자신의 AST + *직접* source 게이팅만 읽고 re-export 체인 끝은 안 보므로
        // 직접 importer 로 충분(이슈 #4176 위험#4). carrier=null(fallback)/키 미스/OOM → 전량
        // (recompute=null, fail-safe). RN 같은 namespace-heavy 앱의 warm lNs 절감(web 은 ~0%).
        var recompute: ?std.AutoHashMapUnmanaged(u32, void) = null;
        defer if (recompute) |*r| r.deinit(self.allocator);
        if (self.graph.changed_emit_paths != null and !ns_access_skip_disabled.enabled()) {
            const ch = self.graph.changed_emit_paths.?;
            var set: std.AutoHashMapUnmanaged(u32, void) = .empty;
            const ok = blk: {
                var it = ch.iterator();
                while (it.next()) |e| {
                    const idx = self.graph.path_to_module.get(e.key_ptr.*) orelse break :blk false;
                    set.put(self.allocator, @intFromEnum(idx), {}) catch break :blk false;
                    // path 는 resolve 됐는데 module 미존재 = graph 불일치 → importer 누락 위험,
                    // 전량 재계산으로 fail-safe(false-skip 차단).
                    const m = self.getModule(@intFromEnum(idx)) orelse break :blk false;
                    for (m.importers.items) |imp| set.put(self.allocator, @intFromEnum(imp), {}) catch break :blk false;
                    for (m.dynamic_importers.items) |imp| set.put(self.allocator, @intFromEnum(imp), {}) catch break :blk false;
                }
                break :blk true;
            };
            if (ok) recompute = set else set.deinit(self.allocator);
        }

        const mod_count = self.graph.moduleCount();
        for (0..mod_count) |i| {
            if (recompute) |r| if (!r.contains(@intCast(i))) continue;
            const importer = self.moduleAtMut(@intCast(i)) orelse continue;
            const sem = importer.semantic orelse continue;
            const ast = if (importer.ast) |*a| a else continue;
            // 결과 슬라이스는 module.parse_arena가 소유 — 모듈 수명 동안 유효하고
            // deinit 시 자동 해제. linker.allocator를 쓰면 누수 위험.
            const arena = if (importer.parse_arena) |pa| pa.allocator() else continue;

            if (sem.scope_maps.len == 0) continue;

            // 분석 대상 (namespace, virtual-namespace named, 또는 CJS default) import 가 하나도 없으면
            // index 구축 전에 outer skip — AST 전체 순회 비용 회피 (#1735).
            // helper `isNamespaceAnalysisCandidate` 로 has_candidate / interest_set / 분석 loop 의
            // predicate 통일 (PR #3737 drift 방지).
            const has_candidate = blk: {
                for (importer.import_bindings) |ib| {
                    if (self.isNamespaceAnalysisCandidate(importer, ib)) break :blk true;
                }
                break :blk false;
            };
            if (!has_candidate) continue;

            // PR #3738 (C6 perf): transform_prepass 가 build 한 index 를 share — build 1회 절약.
            // cache 가 없으면 (legacy / 비-JS / transform_prepass 미실행) 자체 build.
            // cache 의 interest_set 은 *모든 import local* (transform_prepass 시점 resolve 미완료
            // 라 보수적 over-include) — linker 의 4 kind candidate 는 그 superset 의 subset.
            var owned_ns_index: ?namespace_access.NamespaceAccessIndex = null;
            defer if (owned_ns_index) |*idx| idx.deinit(self.allocator);
            const ns_index_ptr: *const namespace_access.NamespaceAccessIndex = blk: {
                if (importer.namespace_access_index) |*cached| break :blk cached;
                // Fallback: 4 kind candidate 의 local_name 만 색인.
                var interest_set: std.StringHashMapUnmanaged(void) = .empty;
                defer interest_set.deinit(self.allocator);
                for (importer.import_bindings) |ib_pre| {
                    if (!self.isNamespaceAnalysisCandidate(importer, ib_pre)) continue;
                    if (ib_pre.local_name.len == 0) continue;
                    interest_set.put(self.allocator, ib_pre.local_name, {}) catch {};
                }
                owned_ns_index = namespace_access.NamespaceAccessIndex.buildOpt(self.allocator, ast, false, &interest_set) catch continue;
                break :blk &owned_ns_index.?;
            };

            // 모든 namespace import에 공통으로 쓰일 stmt span 배열을 importer당 1회 구축.
            const stmt_spans_opt: ?[]const Span = if (importer.prebuilt_stmt_info) |*infos| spans_blk: {
                const spans_buf = arena.alloc(Span, infos.stmts.len) catch break :spans_blk null;
                for (infos.stmts, 0..) |s, si| spans_buf[si] = s.span;
                break :spans_blk spans_buf;
            } else null;

            for (importer.import_bindings) |*ib| {
                const is_namespace = ib.kind == .namespace;
                const is_named_candidate = ib.kind == .named and ib.namespace_used_properties == null;
                if (ib.import_record_index >= importer.import_records.len) continue;
                const source_mod_idx = importer.import_records[ib.import_record_index].resolved;
                if (source_mod_idx.isNone()) continue;
                const source = self.graph.getModule(source_mod_idx) orelse continue;
                const is_cjs_default_candidate = ib.kind == .default and source.wrap_kind == .cjs;
                const is_esm_wrapper_default_candidate = ib.kind == .default and
                    !is_cjs_default_candidate and
                    source.default_export_named_local;
                const should_analyze_binding = is_namespace or is_named_candidate or
                    is_cjs_default_candidate or is_esm_wrapper_default_candidate;
                if (!should_analyze_binding) continue;

                // `.named` 경로는 virtual namespace (re_export_namespace 타겟)일 때만 처리.
                // `.namespace`/CJS default는 항상 scope-aware 재평가 대상 — member-only
                // 사용 패턴을 export pruning으로 연결.
                if (is_named_candidate) {
                    var is_virtual_ns = false;
                    for (source.export_bindings) |eb| {
                        if (eb.kind == .re_export_namespace and std.mem.eql(u8, eb.exported_name, ib.imported_name)) {
                            is_virtual_ns = true;
                            break;
                        }
                    }
                    if (!is_virtual_ns) continue;
                }

                // 소비자 모듈에서 local symbol id 조회. top-level import이므로 scope_maps[0].
                const sym_idx = sem.scope_maps[0].get(ib.local_name) orelse continue;

                // 분석은 linker.allocator에서 임시로 (내부 HashMap 용), 결과 슬라이스만 arena.
                var access = namespace_access.analyzeNamespaceAccessWithIndex(
                    self.allocator,
                    ast,
                    sem.symbol_ids,
                    @intCast(sym_idx),
                    stmt_spans_opt,
                    ns_index_ptr,
                    ib.local_name,
                ) catch continue;
                defer access.deinit(self.allocator);

                if (access.kind == .@"opaque") {
                    // `.namespace`/CJS default/ESM wrapper default 는 opaque(동적
                    // 접근·escape) 시 null 로 덮어써 전체 fallback — wrapper-barrel
                    // 정밀 lazy 가 보수적(전체 링크)으로 떨어지는 안전 경로.
                    // `.named` virtual ns 는 null 유지(기존 동작).
                    if (is_namespace or is_cjs_default_candidate or is_esm_wrapper_default_candidate) {
                        ib.namespace_used_properties = null;
                        ib.namespace_used_property_stmts = null;
                    }
                    continue;
                }

                // 접근된 멤버를 namespace_used_properties에 복사.
                // 문자열은 source buffer 참조 (ast.getText 결과) — module.parse_arena 수명 동안 유효.
                // 슬라이스 자체도 arena로 할당해 deinit 시 자동 해제.
                //
                // counter$4 진짜 근본 fix: analyzer 가 *post-transform symbol_id* 로 namespace
                // local 추적. transformer 가 namespace local 의 symbol_id 를 rebind (e.g.
                // `metric` → `metric_ns` 같이 rename 후 다른 symbol) 하면 analyzer 가 access 못
                // 잡아 access.members.count()=0 (empty). 이 empty 결과로 binding_scanner 의
                // 1차 결과 (non-empty) 를 덮어쓰면 → tree-shake namespace import seed 0회 →
                // namespace getter dangling (effect-ts `counter$4 is not defined`).
                // 따라서 empty result 면 binding_scanner 결과 유지.
                const count = access.members.count();
                if (count == 0) continue;
                const props = arena.alloc([]const u8, count) catch continue;
                const prop_stmts: ?[][]const u32 = if (stmt_spans_opt != null)
                    (arena.alloc([]const u32, count) catch null)
                else
                    null;

                var prop_i: usize = 0;
                var it = access.members.iterator();
                while (it.next()) |entry| : (prop_i += 1) {
                    props[prop_i] = entry.key_ptr.*;
                    if (prop_stmts) |ps| {
                        const src = entry.value_ptr.items;
                        const dst = arena.alloc(u32, src.len) catch continue;
                        @memcpy(dst, src);
                        ps[prop_i] = dst;
                    }
                }
                ib.namespace_used_properties = props;
                ib.namespace_used_property_stmts = if (prop_stmts) |ps| ps else null;
            }
        }
    }

    pub const registerNamespaceRewrites = shared_namespace.registerNamespaceRewrites;
    pub const ensureSharedNsVar = shared_namespace.ensureSharedNsVar;
    /// (#3975) namespace 객체의 ESM-local getter literal 생성 (CJS star/inner 혼합 케이스의
    /// per-module 런타임 구성에서 사용). buildInlineObjectStr 노출.
    pub const buildNamespaceInlineObject = shared_namespace.buildInlineObjectStr;

    /// computeCrossChunkLinks 가 cross-chunk namespace re-export target 마킹
    /// (#3367). metadata 시점엔 chunk 정보 부재 — registerNamespaceRewrites 가
    /// 이 마킹으로 shared(cross-chunk) vs 비-shared(same-chunk) 경로 선택.
    /// **불변식**: computeCrossChunkLinks(단일스레드, emitChunks 前 완료)에서만
    /// write. 이후 병렬 metadata 가 read-only 로 본다 — 그 뒤 write 시 데이터
    /// 레이스.
    pub fn markNsCrossChunk(self: *Linker, target: ModuleIndex) std.mem.Allocator.Error!void {
        try self.ns_cross_chunk_targets.put(self.allocator, target.toU32(), {});
    }

    /// shared(정의자 청크 preamble) vs 비-shared(모듈 self-preamble) namespace
    /// inline 경로 결정. 단일번들(metadata 後 emit, 다중 importer dedup #1940)·
    /// chunked-cross-chunk(#3366)는 shared. chunked-same-chunk 만 비-shared
    /// self-contained — chunked preamble 이 metadata 前이라 same-chunk
    /// pre-materialize 부재(#3367).
    pub fn useSharedNsInline(self: *const Linker, target_mod_idx: u32) bool {
        return self.use_shared_ns_preamble and
            (!self.ns_preamble_chunked or self.ns_cross_chunk_targets.contains(target_mod_idx));
    }

    /// dev 모듈 레지스트리(`__zntc_modules[dev_id].fn()`)로 모듈 참조를 lowering 할지.
    /// 레지스트리는 청크 경계를 넘어 모듈을 주소화하므로 크로스청크 해석이 가능하다.
    /// - 단일번들 dev(`dev and !splitting`): 레지스트리(기존 동작).
    /// - dev_split(`dev and splitting and lazy`): PR-2(#4088)가 글로벌 `__zntc_modules` 를
    ///   깔아 ESM(shared_namespace.zig:977)이 이미 쓰는 그 레지스트리로 CJS/require 도 통일 →
    ///   크로스청크 공유 CJS 의존(react/jsx-runtime 등) ReferenceError 해소.
    /// - 비-lazy splitting / production: lexical(`require_X`/`init_X`) 유지(레지스트리 substrate
    ///   부재 / dev_mode=false → byte-identical).
    ///
    /// 적용 범위: linker metadata 의 참조 lowering(`import` 바인딩 CJS 참조 + `require()` 호출
    /// rewrite). ⚠️ emitter 의 **re-export/`export *`/side-effect init** lowering
    /// (esm_wrap.zig:842/1203/1309 — `options.dev_mode and !options.code_splitting` 게이트, EmitOptions
    /// 에 lazy_compilation 부재라 미이전)은 아직 lexical 이라 dev_split 의 `export { x } from
    /// './cjsdep'` 같은 크로스청크 re-export-from-CJS 는 별도 follow-up. 새 dev-registry 게이트를
    /// 추가할 땐 이 predicate 를 쓸 것(raw `dev_mode and !code_splitting` 복사 금지).
    pub fn useDevModuleRegistry(self: *const Linker) bool {
        return self.dev_mode and (!self.code_splitting or self.graph.lazy_compilation);
    }
    pub const appendSharedNamespacePreamble = shared_namespace.appendSharedNamespacePreamble;
    pub const appendSharedNamespacePreambleFiltered = shared_namespace.appendSharedNamespacePreambleFiltered;
    pub const restoreSharedNamespaceDecls = shared_namespace.restoreSharedNamespaceDecls;
    pub const collectSharedNamespaceDecls = shared_namespace.collectSharedNamespaceDecls;

    /// "default"는 JS 예약어 — 값 위치에 식별자로 사용 불가.
    /// codegen 합성 변수명(_default)의 canonical name으로 대체.
    fn safeIdentifierName(self: *const Linker, name: []const u8, module_index: u32) []const u8 {
        if (std.mem.eql(u8, name, "default")) {
            return self.getCanonicalName(module_index, "_default") orelse "_default";
        }
        return name;
    }

    fn cjsNamespaceExportAccess(self: *const Linker, ref: SymbolRef) std.mem.Allocator.Error!?[]const u8 {
        const target = self.graph.getModule(ref.module_index) orelse return null;
        if (target.wrap_kind != .cjs) return null;
        if (std.mem.eql(u8, ref.export_name, "default")) return null;

        const req_var = try target.allocRequireName(self.allocator, &self.rename_table);
        defer self.allocator.free(req_var);
        return try std.fmt.allocPrint(self.allocator, "{s}().{s}", .{ req_var, ref.export_name });
    }

    /// (#4120) CJS interop 멤버의 materialize RHS(`var <syn> = <RHS>`). cross-chunk(provider 청크,
    /// chunks.zig) 와 entry/dynamic(buildFinalExports) 양쪽이 동일 형태를 써 단일번들 출력과 동형화.
    ///   - "default" + `module.exports = X` shape(can_skip): `require_X()`
    ///   - "default" 일반: `__toESM(require_X())[, 1)].default`
    ///   - named: `require_X().<member>`
    /// interop 모드(node `, 1` vs babel)는 CJS 모듈의 첫 importer def_format(없으면 babel)로 결정.
    /// caller-owned 반환. allocator 는 caller 가 정한 수명(metadata=self.allocator, emit=청크 alloc).
    pub fn cjsInteropAccessExpr(
        self: *const Linker,
        allocator: std.mem.Allocator,
        cjs_mod: *const Module,
        member: []const u8,
        minify: bool,
    ) ![]const u8 {
        const req_var = try cjs_mod.allocRequireName(allocator, &self.rename_table);
        defer allocator.free(req_var);
        if (std.mem.eql(u8, member, "default")) {
            if (cjs_mod.can_skip_cjs_default_interop) {
                return std.fmt.allocPrint(allocator, "{s}()", .{req_var});
            }
            const toesm: []const u8 = if (minify) rt_names.NAMES.TOESM_MIN else "__toESM";
            const suffix: []const u8 = if (self.cjsInteropIsNode(cjs_mod)) "(), 1)" else "())";
            return std.fmt.allocPrint(allocator, "{s}({s}{s}.default", .{ toesm, req_var, suffix });
        }
        return std.fmt.allocPrint(allocator, "{s}().{s}", .{ req_var, member });
    }

    /// (#4120) CJS interop default 의 `__toESM` 2번째 인자(node 모드) 여부. consumer 의
    /// cjsInteropMode 와 동형 — CJS 모듈 첫 importer 의 def_format(없으면 babel). RN 은 항상 babel.
    fn cjsInteropIsNode(self: *const Linker, cjs_mod: *const Module) bool {
        if (self.graph.resolve_cache.platform == .react_native) return false;
        for (cjs_mod.importers.items) |imp| {
            const im = self.graph.getModule(imp) orelse continue;
            return im.def_format.isEsm();
        }
        return false;
    }

    /// `import_records[idx].resolved` 가 valid 면 모듈 인덱스 반환, 아니면 null.
    /// `collectExportsRecursive` 의 3개 분기에서 공유.
    inline fn resolvedRecordModule(records: anytype, rec_idx_opt: ?u32) ?u32 {
        const rec_idx = rec_idx_opt orelse return null;
        if (rec_idx >= records.len) return null;
        const src = records[rec_idx].resolved;
        if (src.isNone()) return null;
        return @intFromEnum(src);
    }

    /// 모듈의 모든 export를 재귀적으로 수집 (export * 체인 포함).
    /// seen: export 이름 dedup, visited: 모듈 수준 dedup (diamond export * 방지).
    pub fn collectExportsRecursive(
        self: *const Linker,
        exports: *std.ArrayList(NsExportPair),
        seen: *std.StringHashMapUnmanaged(void),
        visited: *std.AutoHashMapUnmanaged(u32, void),
        module_idx: ModuleIndex,
        depth: u32,
    ) std.mem.Allocator.Error!void {
        if (depth > max_chain_depth) return;
        const mod_i = @intFromEnum(module_idx);
        const m = self.graph.getModule(module_idx) orelse return;
        // diamond export * 패턴에서 동일 모듈 재방문 방지
        if (visited.contains(mod_i)) return;
        try visited.put(self.allocator, mod_i, {});

        // namespace import를 O(1) 조회용 맵으로 수집 (local_name → import_record_index)
        var ns_imports: std.StringHashMapUnmanaged(u32) = .empty;
        defer ns_imports.deinit(self.allocator);
        for (m.import_bindings) |mib| {
            if (mib.kind == .namespace) {
                try ns_imports.put(self.allocator, mib.local_name, mib.import_record_index);
            }
        }

        for (m.export_bindings) |eb| {
            // 일반 export * from (exported_name == "*") → 재귀로 처리 (skip)
            // export * as ns (exported_name != "*") → named export로 포함
            if (eb.kind == .re_export_star) continue;
            if (seen.contains(eb.exported_name)) continue;
            try seen.put(self.allocator, eb.exported_name, {});

            const eb_local = m.exportBindingLocalName(eb);
            // ns_target_mod: hoisted ns_var 가 필요한 source 모듈 (registerNamespaceRewrites
            // 가 처리). inline literal 을 직접 만들어 inner_map 에 넣으면 emitStaticMember
            // 가 access site 마다 객체 literal 을 inline emit (#1928). 대신 source mod_idx
            // 만 기록하고 ns_var 등록은 호출 site 가 일임.
            var ns_target_mod: ?u32 = null;
            var owns_actual_local = false;
            var cjs_interop: ?SymbolRef = null;
            var init_mod: ?u32 = if (m.wrap_kind == .esm) mod_i else null;
            const actual_local = if (eb.kind == .re_export_namespace) blk: {
                ns_target_mod = resolvedRecordModule(m.import_records, eb.import_record_index);
                break :blk eb_local;
            } else if (eb.kind == .re_export) blk: {
                if (self.resolveExportChain(module_idx, eb.exported_name, 0)) |canonical| {
                    init_mod = if (self.graph.getModule(canonical.module_index)) |cmod|
                        if (cmod.wrap_kind == .esm) @intFromEnum(canonical.module_index) else null
                    else
                        null;
                    if (self.graph.getModule(canonical.module_index)) |cmod| {
                        for (cmod.export_bindings) |ceb| {
                            if (ceb.kind.isReExportAll() and
                                std.mem.eql(u8, ceb.exported_name, canonical.export_name) and
                                !std.mem.eql(u8, ceb.exported_name, "*"))
                            {
                                if (resolvedRecordModule(cmod.import_records, ceb.import_record_index)) |src_mod| {
                                    ns_target_mod = src_mod;
                                }
                            }
                        }
                    }
                    if (ns_target_mod == null) {
                        // (#4120) canonical 이 CJS 모듈이면 default/named 모두 런타임 interop 멤버라
                        // 진짜 로컬 바인딩이 없다. cjs_interop 에 ref 만 *additive* 기록 →
                        // buildFinalExports(entry/dynamic)가 ESM 은 `var <syn> = <interop>;` materialize +
                        // 식별자 export, CJS/iife 는 expr 를 RHS 로 직접 사용(표현식 specifier·미정의
                        // _default 회피, #4120 Bug A). `local` 자체는 기존대로 — shared ns / fan-out
                        // caller 가 expr(named)/`_default`(default)를 그대로 쓰기 때문(회귀 방지).
                        if (self.graph.getModule(canonical.module_index)) |cm| {
                            if (cm.wrap_kind == .cjs) cjs_interop = canonical;
                        }
                        if (try self.cjsNamespaceExportAccess(canonical)) |expr| {
                            owns_actual_local = true;
                            init_mod = null;
                            break :blk expr;
                        }
                        break :blk self.resolveToLocalName(canonical);
                    }
                    break :blk eb_local;
                }
                break :blk eb_local;
            } else blk: {
                ns_target_mod = resolvedRecordModule(m.import_records, ns_imports.get(eb_local));
                if (ns_target_mod == null) break :blk self.getCanonicalByRef(eb.symbol) orelse eb_local;
                break :blk eb_local;
            };

            const safe_local = if (owns_actual_local)
                actual_local
            else
                self.safeIdentifierName(actual_local, @intCast(mod_i));

            try exports.append(self.allocator, .{
                .exported = eb.exported_name,
                .local = safe_local,
                .owned = owns_actual_local,
                .init_mod = init_mod,
                .ns_target_mod = ns_target_mod,
                .cjs_interop = cjs_interop,
            });
        }

        // export * 재귀 — export * as ns는 이미 첫 루프에서 인라인 객체로 처리됨.
        // ESM 스펙: export *는 "default"를 제외 (ECMAScript 15.2.3.5).
        // seen에 "default"를 추가하여 하위 모듈의 default export가 수집되지 않도록 함.
        // 직접 선언된 export { default }는 위 첫 루프에서 이미 수집됨.
        try seen.put(self.allocator, "default", {});
        for (m.export_bindings) |eb| {
            if (!eb.kind.isReExportAll()) continue;
            if (!std.mem.eql(u8, eb.exported_name, "*")) continue; // export * as ns는 skip
            if (eb.import_record_index) |rec_idx| {
                if (rec_idx < m.import_records.len) {
                    const source_mod = m.import_records[rec_idx].resolved;
                    if (!source_mod.isNone()) {
                        try self.collectExportsRecursive(exports, seen, visited, source_mod, depth + 1);
                    }
                }
            }
        }
    }

    /// 특정 모듈+import에 대한 resolved binding 조회.
    pub fn getResolvedBinding(self: *const Linker, module_index: u32, span: Span) ?ResolvedBinding {
        const bk = BindingKey{
            .module_index = module_index,
            .span_key = types.spanKey(span),
        };
        return self.resolved_bindings.get(bk);
    }

    fn addDiag(
        self: *Linker,
        code: BundlerDiagnostic.ErrorCode,
        severity: BundlerDiagnostic.Severity,
        file_path: []const u8,
        span: Span,
        step: BundlerDiagnostic.Step,
        message: []const u8,
        suggestion: ?[]const u8,
    ) void {
        self.diagnostics.append(self.allocator, .{
            .code = code,
            .severity = severity,
            .message = message,
            .file_path = file_path,
            .span = span,
            .step = step,
            .suggestion = suggestion,
        }) catch {};
    }

    /// rename 결과를 초기화한다. canonical_strings 값을 해제하고 used set / rename_table 을 비운다.
    /// per-chunk rename에서 이전 청크의 결과를 제거할 때 사용.
    pub fn clearCanonicalNames(self: *Linker) void {
        for (self.canonical_strings.items) |s| self.allocator.free(s);
        self.canonical_strings.clearRetainingCapacity();
        self.canonical_names_used.clearRetainingCapacity();
        // 값이 방금 free 된 stale slice 를 가리키지 않도록 rename_table 도 함께 clear.
        self.rename_table.clear();
    }

    /// RFC #3940 Sub-PR-L.5a — graph carry-over 가 `module.pending_renames` 에 stash 한 rename
    /// (SymbolID→name) 을 build-scope `rename_table` 에 반영한다.
    ///
    /// tree-shake 단계 (link 후, `minify_identifiers=false` + const-materialization AST mutation)
    /// 의 semantic resync 가 symbol idx 를 재배정하면, `transform_prepass.captureRenamesToPending`
    /// 가 (tree_shaker 의 *const linker.rename_table 에서 읽어) new idx 로 module.pending_renames 에
    /// 모았다. 여기서 mutable linker 가 적용 — mutated module 의 resync-전 stale entry 를 prune 후
    /// pending 으로 완전 재선언 (구 `syncRenameTableFromCanonical` 의 clear-rebuild 시맨틱 보존).
    /// 소비 후 pending 을 비운다 (value 는 canonical_strings borrow — build-scope, store round-trip 전 clear).
    pub fn applyPendingRenames(self: *Linker) !void {
        var mit = self.graph.modules.iterator(0);
        while (mit.next()) |m| {
            if (m.pending_renames.count() == 0) continue;
            try self.rename_table.removeModule(self.allocator, m.index);
            var it = m.pending_renames.map.iterator();
            while (it.next()) |e| {
                try self.rename_table.put(self.allocator, e.key_ptr.*, e.value_ptr.*);
            }
            m.pending_renames.clear();
        }
    }

    /// unified mangling 산출물을 초기화한다. AST mutation 후 semantic을 재생성한 경우
    /// old symbol id 기준 mangling 결과를 emit에 재사용하면 잘못된 rename이 적용된다.
    pub fn clearMangling(self: *Linker) void {
        if (self.unified_result) |*ur| {
            ur.deinit();
            self.unified_result = null;
        }
        for (self.unified_module_scopes) |*b| b.deinit();
        if (self.unified_module_scopes.len > 0) self.allocator.free(self.unified_module_scopes);
        self.unified_module_scopes = &.{};
    }

    /// link() 이후 호출 — rename / mangling / populate* 시퀀스를 한 번에 실행.
    /// bundler 본 path / worker 청크 / tree-shake post-recompute 가 같은 시퀀스를
    /// 호출하므로 단일 엔트리로 묶어 drift 방지.
    pub fn finalize(self: *Linker, opts: struct {
        compute_renames: bool,
        compute_mangling: bool,
        clear_first: bool = false,
        populate_namespace_accesses: bool = true,
        /// dev HMR reuse-hit 전용 — ref_count(populateSymbolRefCounts) populate 를 skip.
        /// reuse-hit 는 computeRenames 도 skip 하고 capture_eligible 이 minify/splitting 을
        /// 제외하므로 ref_count 가 어디서도 소비되지 않는다(아래 populate 가드 주석 참조).
        skip_ref_counts: bool = false,
    }) !void {
        if (opts.clear_first) {
            self.clearCanonicalNames();
            self.clearMangling();
        }
        if (opts.compute_renames) {
            try self.computeRenames();
            if (opts.compute_mangling) try self.computeMangling();
        }
        self.populateReExportAliases();
        self.populateImportSymbols();
        if (opts.populate_namespace_accesses) self.populateNamespaceAccesses();
        // ref_count(populateSymbolRefCounts)는 mangle candidate 우선순위(collectUnifiedInput)에서
        // 소비된다 — 전역 computeMangling 뿐 아니라 code-splitting 의 per-chunk computeChunkMangling
        // (computeRenamesForModules)도 소비하므로 `compute_renames=false` 라고 무조건 skip 하면
        // splitting minified 출력의 짧은-이름 배정이 갈린다. 따라서 dev HMR reuse-hit
        // (skip_ref_counts=true)만 안전하게 skip한다: reuse-hit 는 computeRenames 를 skip 하고
        // capture_eligible 이 minify_identifiers/code_splitting 을 제외하므로 ref_count 가 어디서도
        // 소비되지 않는다. 전체 모듈 import_bindings O(N) 순회 절약(lnk). 첫빌드/fallback/splitting
        // (skip_ref_counts=false)은 종전대로 populate.
        if (!opts.skip_ref_counts) self.populateSymbolRefCounts();
    }

    /// pre-shake AST mutation (cross-module const materialize) 직후, 후속 BFS 가
    /// 읽는 populate* 만 좁게 재실행한다. rename/mangling/symbol_ref_counts 는
    /// 의도적으로 제외:
    ///   - rename/mangling: emit 단계 입력. 직후 numeric post-pass 가 또 mutation 할
    ///     수 있어 bundler 가 모든 mutation 이 settle 된 뒤 한 번만 계산해야 한다
    ///     (#2502: 두 번 호출되면 inner 결과가 outer `clear_first` 로 폐기 → 낭비).
    ///   - populateSymbolRefCounts: 증분 (`+= 1`) 이라 멱등하지 않음 — 두 번 부르면
    ///     2× 누적. mangler 가 rank-comparison 으로만 쓰니 결과는 같지만, 새 inner
    ///     에서 빼고 outer 의 한 번만 신뢰하는 편이 명확.
    /// `*const Linker` 시그니처 — populate* 모두 const-self interior mutation 만 함.
    pub fn refreshAfterAstMutation(self: *const Linker) void {
        self.populateReExportAliases();
        self.populateImportSymbols();
        self.populateNamespaceAccesses();
    }

    /// 특정 모듈들만 대상으로 이름 충돌을 감지하고 리네임을 계산한다.
    /// code splitting에서 사용 — 각 청크는 독립된 네임스페이스이므로
    /// 같은 이름이 다른 청크에 있어도 충돌하지 않는다.
    ///
    /// 기존 canonical_names를 초기화한 뒤, module_indices에 포함된
    /// 모듈의 top-level 심볼만 대상으로 충돌을 감지한다.
    /// cross-chunk import 이름을 점유로 등록하면서 이름 충돌을 해결한다.
    /// occupied_names: cross-chunk import로 이 청크에 도입되는 이름 목록.
    /// 이 이름들은 import 문으로 유지되므로 로컬 심볼과 충돌하면 로컬을 rename해야 함.
    pub fn computeRenamesForModules(
        self: *Linker,
        module_indices: []const ModuleIndex,
        occupied_names: []const []const u8,
    ) !void {
        // 이전 청크의 리네임 결과 제거
        self.clearCanonicalNames();

        // 미해결 참조 수집 (해당 청크의 모듈만)
        self.reserved_globals.clearRetainingCapacity();
        for (module_indices) |mod_idx| {
            const m = self.graph.getModule(mod_idx) orelse continue;
            const sem = m.semantic orelse continue;
            var urit = sem.unresolved_references.iterator();
            while (urit.next()) |entry| {
                try self.reserved_globals.put(self.allocator, entry.key_ptr.*, {});
            }
        }

        // 1. 지정된 모듈의 top-level 심볼 이름 수집
        var name_to_owners: NameToOwnersMap = .empty;
        defer {
            var vit = name_to_owners.valueIterator();
            while (vit.next()) |list| list.deinit(self.allocator);
            name_to_owners.deinit(self.allocator);
        }

        // cross-chunk import 이름을 "점유"로 등록 — exec_index=0 (가장 낮음)으로
        // 등록하여 충돌 시 로컬 심볼이 rename됨 (import 이름이 우선 유지)
        for (occupied_names) |name| {
            if (std.mem.eql(u8, name, "default")) continue;
            const entry = try name_to_owners.getOrPut(self.allocator, name);
            if (!entry.found_existing) {
                entry.value_ptr.* = .empty;
            }
            try entry.value_ptr.append(self.allocator, .{
                .module_index = std.math.maxInt(u32), // 특수 마커 — 실제 모듈 아님
                .exec_index = 0, // 가장 낮은 exec_index → 원본 이름 유지
                .path = "", // marker — 항상 정렬 우선 (사전순 최상)
            });
        }

        for (module_indices) |mod_idx| {
            const m = self.graph.getModule(mod_idx) orelse continue;
            try self.collectModuleNames(m.*, mod_idx.toU32(), &name_to_owners);
        }

        // 2. 충돌하는 이름에 대해 리네임 계산 (cross-chunk 점유 마커는 skip)
        try self.calculateRenames(&name_to_owners, true);

        // 2.5 #4101 cross-chunk 전역 네이밍 override — 이 청크가 export 하는 cross-chunk 심볼을
        // 전역 이름으로 고정. calculateRenames 의 per-chunk deconflict 순서(exec_index)가 전역
        // 순서(mod,name)와 어긋나면 어느 심볼이 `v`/`v$1` 을 갖는지 달라진다 → override 로 전역
        // 맵과 일치시켜 provider/consumer 가 같은 이름을 본다. dupe → putCanonicalName 이
        // canonical_strings 로 소유권 이전. (전역명==per-chunk 결과면 no-op. reserve 마커는 안 둔다
        // — non-cross-chunk 동명 심볼(dup.v)까지 밀어내 `v$2` 가 되는 부작용 때문. calculateRenames
        // 자연 순서가 cross-chunk owner 에게 preferred 를 주므로 override 는 divergence 만 교정.)
        // ⚠️ **lazy(dev_split) 전용** — production 은 `export { local as public }` 브리지가
        // public=전역명을 따로 노출(emit 측 처리)하므로 local 을 전역명으로 강제하면 안 된다
        // (브리지가 mangle 된 local 을 전역 public 으로 보존; override 하면 그 분리가 깨짐).
        // dev_split 은 emitLazyEntryExportAll 이 local 명을 그대로 노출하므로 local==전역명 필요.
        if (self.graph.lazy_compilation) {
            for (module_indices) |mod_idx| {
                const inner = self.cross_chunk_global_names.get(mod_idx.toU32()) orelse continue;
                var git = inner.iterator();
                while (git.next()) |e| {
                    const local = self.getExportLocalName(mod_idx.toU32(), e.key_ptr.*) orelse e.key_ptr.*;
                    const dup = try self.allocator.dupe(u8, e.value_ptr.*);
                    try self.putCanonicalName(mod_idx.toU32(), local, dup);
                }
            }
        }

        // 3. #4045: production code splitting + minify 시 deconflict 이후 청크 *내부*
        // 로컬 식별자를 축약(mangle)한다. deconflict(calculateRenames)를 먼저 돌려
        // 단일 번들의 computeRenames→computeMangling 순서를 그대로 재현 — 1-char
        // cross-module 충돌 등 mangleAll 이 skip 하는 케이스가 먼저 해소된다.
        // cross-chunk export 이름은 emit 의 `export { local as public }` 브리지가
        // 보존하므로 별도 예약 불필요. import 경계 이름만 occupied_names 로 보호.
        if (self.graph.minify_identifiers and self.graph.code_splitting) {
            try self.computeChunkMangling(module_indices, occupied_names);
        }
    }

    /// 단일 청크(`module_indices`)의 top-level + nested 식별자를 mangle 한다.
    /// `computeMangling`(전역)의 per-chunk 대응 — `collectUnifiedInput` 을 청크 필터로
    /// 호출하고 결과 Phase A 를 `rename_table` 에, Phase B 를 `unified_result` 에 보관한다.
    /// emit 루프는 청크 단위로 순차 실행되므로 청크마다 `unified_result` 를 덮어써도 안전
    /// (metadata 가 Phase B 값을 dupe 해 소유 — borrowed slice UAF 없음).
    fn computeChunkMangling(
        self: *Linker,
        module_indices: []const ModuleIndex,
        occupied_names: []const []const u8,
    ) !void {
        // 이전 청크의 Phase B 산출물 해제 (다음 emit 전 fresh). 첫 청크는 null → no-op.
        self.clearMangling();

        // 청크 멤버 집합 — collectUnifiedInput candidate 필터.
        var chunk_set: std.AutoHashMapUnmanaged(ModuleIndex, void) = .empty;
        defer chunk_set.deinit(self.allocator);
        try chunk_set.ensureUnusedCapacity(self.allocator, @intCast(module_indices.len));
        for (module_indices) |mi| chunk_set.putAssumeCapacity(mi, {});

        // deconflict 가 먼저 넣은 rename_table stale entry 는 injectPhaseARenames 의
        // assignSymbolCanonical 이 used set 에서 제거 후 덮어쓴다. occupied_names 는
        // cross-chunk import 경계 → collectUnifiedInput 이 reserved 로 보호.
        try self.runUnifiedMangle(&chunk_set, occupied_names);
    }

    pub const makeExportKey = types.makeModuleKey;
    pub const makeExportKeyBuf = types.makeModuleKeyBuf;
};

/// CJS 모듈의 require_xxx 변수명을 캐시에서 가져오거나 새로 생성.
pub fn getOrCreateRequireVar(
    self: *const Linker,
    cache: *std.AutoHashMapUnmanaged(u32, []const u8),
    mod_idx: u32,
) ![]const u8 {
    if (cache.get(mod_idx)) |cached| return cached;
    const target_mod = self.getModule(mod_idx).?;
    const name = try target_mod.allocRequireName(self.allocator, &self.rename_table);
    try cache.put(self.allocator, mod_idx, name);
    return name;
}
