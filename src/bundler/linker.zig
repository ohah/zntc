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
const profile = @import("../profile.zig");
const debug_log = @import("../debug_log.zig");
const CompiledModule = @import("compiled_module.zig").CompiledModule;
const preamble_writer = @import("linker/preamble_writer.zig");
const namespace_access = @import("linker/namespace_access.zig");
const shared_namespace = @import("linker/shared_namespace.zig");
pub const PreambleWriter = preamble_writer.PreambleWriter;
pub const cjsImportNeedsToEsmInterop = preamble_writer.cjsImportNeedsToEsmInterop;
pub const LinkingMetadata = @import("linker/metadata_types.zig").LinkingMetadata;
pub const MangleReportCollector = @import("linker/mangle_report.zig").MangleReportCollector;

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
    allocator: std.mem.Allocator,

    pub fn deinit(self: *UnifiedCollect) void {
        self.allocator.free(self.top_level_candidates);
        self.allocator.free(self.modules);
        self.allocator.free(self.reserved_names);
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
};

/// 해석된 import 바인딩. linker가 codegen에 전달.
pub const ResolvedBinding = struct {
    /// importer 모듈에서 사용하는 로컬 이름
    local_name: []const u8,
    /// 로컬 바인딩의 소스 위치 (rename 키)
    local_span: Span,
    /// 최종적으로 가리키는 export (re-export 체인 해결 후)
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
    export_map: std.StringHashMap(ExportEntry),

    /// import→export 바인딩 결과: (module_index, local_span_key) → ResolvedBinding
    resolved_bindings: std.AutoHashMap(BindingKey, ResolvedBinding),

    diagnostics: std.ArrayList(BundlerDiagnostic),
    /// #1791 사용자 노출용 치명 진단 (예: IIFE 포맷에서 unresolved import).
    /// 기존 `diagnostics` 는 내부/테스트 전용 — bundler 가 BundleResult 로 wire 하지
    /// 않는다. 이 필드로 들어온 항목만 사용자에게 `build error` 로 노출된다.
    /// message 는 allocator 소유 (allocPrint) — linker.deinit 에서 일괄 해제.
    fatal_diagnostics: std.ArrayList(BundlerDiagnostic) = .empty,
    /// #1791 emitter 가 `emitModuleThread` 로 병렬 emit 중 `LinkingMetadata.pending_diagnostics`
    /// 를 linker 의 `fatal_diagnostics` 버퍼로 flush. 병렬 append 보호.
    diagnostics_mutex: std.Thread.Mutex = .{},

    /// semantic.Symbol.canonical_name 슬라이스의 backing 저장소. linker가 소유 —
    /// deinit에서 일괄 해제. AliasTable.canonical_name은 caller-owned (별도 모델).
    canonical_strings: std.ArrayList([]const u8) = .empty,
    /// canonical_strings에 등록되며 canonical_name이 채워진 Symbol 포인터.
    /// clearCanonicalNames가 O(touched)로 reset하기 위한 dirty list.
    canonical_symbols: std.ArrayList(*semantic_symbol.Symbol) = .empty,
    /// 충돌 검사용 set. 리네임 후보가 기존 canonical로 사용 중인지 O(1) 확인.
    /// 키는 canonical_strings가 소유 — 이 맵은 borrowed.
    canonical_names_used: std.StringHashMap(void),

    /// 자동 수집된 예약 글로벌 이름. 모든 모듈의 unresolved references를 합친 것.
    /// scope hoisting 시 모듈 top-level 변수가 이 이름을 shadowing하면 리네임.
    reserved_globals: std.StringHashMap(void),

    /// 외부에서 전달된 예약 전역 식별자 (--global-identifier).
    /// RN의 polyfillGlobal()로 등록되는 이름(Performance, EventCounts 등)을
    /// 모듈 변수로 사용하지 않도록 리네이밍.
    global_identifiers: []const []const u8 = &.{},

    /// dev mode: HMR용 모듈 참조를 __zntc_modules["id"].fn()으로 생성.
    /// init_xxx() 대신 동적 lookup을 사용하여 new Function()에서도 접근 가능.
    dev_mode: bool = false,

    /// Metro inlineRequires 호환 경로. RN에서는 함수 내부에서만 읽히는 import의
    /// module init을 top-level preamble에서 미루고, 참조 지점에서 lazy init한다.
    inline_requires: bool = false,

    /// `EmitOptions.entry_error_guard` propagate. preamble 의 module init 호출을
    /// `__zntc_guarded(fn)` 으로 wrap 하여 outermost 에서 `ErrorUtils.reportFatalError`
    /// 로 swallow. helper 자체는 emitter prologue 에 주입.
    entry_error_guard: bool = false,

    /// #1621: minify 시 preamble/metadata 에서 __toESM/__toCommonJS 등을
    /// $tE/$tC 등 축약 이름으로 emit. bundler 가 `self.options.minify_whitespace`
    /// 를 linker 생성 직후 설정한다. dev_mode 에서는 `__zntc_g.__xxx` 경로를
    /// 사용하므로 이 플래그는 무시된다.
    minify_whitespace: bool = false,

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

    /// #1824 IIFE `--globals SPEC=GLOBAL` 매핑 (rollup `output.globals` 호환).
    /// `format == .iife` 일 때만 의미 있음. 매핑된 external specifier 는 UMD/AMD 와
    /// 동일한 factory-param preamble 경로로 처리되고, 매핑 안 된 external 은
    /// 기존 IIFE unresolved 에러 경로를 탄다. bundler 가 init 후 설정 — borrowed.
    iife_globals: []const types.GlobalEntry = &.{},

    /// --mangle-report 수집기 (#1760). `null` 이면 instrumentation skip.
    /// Bundler 가 생성 및 소유. Linker 는 참조만 보유.
    mangle_report: ?*MangleReportCollector = null,

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
    chain_cache: std.StringHashMapUnmanaged(ChainCacheEntry) = .{},
    chain_cache_enabled: bool = false,

    /// namespace import export 수집 캐시 (metadata.register_ns_rewrites hot path).
    /// 키: target_mod_idx. 같은 타겟을 여러 모듈이 namespace import 할 때
    /// `collectExportsRecursive` DFS 를 한 번만 수행하도록 linker 전역 공유.
    /// 값 slice 와 `owned=true` 인 local 문자열 모두 linker 소유 — deinit 에서 일괄 해제.
    /// Invariant: metadata 단계에서 append-only (put 만, remove/replace 없음).
    /// 슬라이스는 `allocator.dupe` 한 독립 할당이라 다른 키의 put 으로도 무효화되지 않음 —
    /// lock 해제 후에도 안전하게 읽기 가능.
    ns_export_cache: std.AutoHashMapUnmanaged(u32, []NsExportPair) = .{},
    /// buildInlineObjectStr 결과 캐시. 키: target_mod_idx. 값 문자열 linker 소유.
    ns_inline_cache: std.AutoHashMapUnmanaged(u32, []const u8) = .{},
    /// target module 별 공유 namespace object var. namespace 를 값으로 쓰는 여러 importer 가
    /// 같은 객체 선언을 중복 emit 하지 않도록 bundle/chunk preamble 에서 한 번만 쓴다.
    ns_shared_inline_cache: std.AutoHashMapUnmanaged(u32, SharedNsInline) = .{},
    ns_shared_inline_order: std.ArrayListUnmanaged(u32) = .empty,
    ns_shared_var_names: std.StringHashMapUnmanaged(void) = .{},
    use_shared_ns_preamble: bool = false,
    /// ns_export_cache / ns_inline_cache 동시 접근 보호.
    /// emitter 가 `emitModuleThread` 로 buildMetadataForAst 를 병렬 호출하므로 필수.
    /// Fast path (get) → unlock → compute → lock → double-check → put 패턴으로
    /// DFS 자체는 lock 밖에서 수행해 경합 최소화.
    ns_cache_mutex: std.Thread.Mutex = .{},

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
            .export_map = std.StringHashMap(ExportEntry).init(allocator),
            .resolved_bindings = std.AutoHashMap(BindingKey, ResolvedBinding).init(allocator),
            .diagnostics = .empty,
            .canonical_names_used = std.StringHashMap(void).init(allocator),
            .reserved_globals = std.StringHashMap(void).init(allocator),
            .global_identifiers = global_identifiers,
        };
    }

    pub fn deinit(self: *Linker) void {
        if (self.unified_result) |*ur| ur.deinit();
        for (self.unified_module_scopes) |*b| b.deinit();
        if (self.unified_module_scopes.len > 0) self.allocator.free(self.unified_module_scopes);

        var eit = self.export_map.keyIterator();
        while (eit.next()) |key| {
            self.allocator.free(key.*);
        }
        self.export_map.deinit();
        self.resolved_bindings.deinit();
        for (self.canonical_strings.items) |s| self.allocator.free(s);
        self.canonical_strings.deinit(self.allocator);
        self.canonical_symbols.deinit(self.allocator);
        self.canonical_names_used.deinit();
        self.reserved_globals.deinit();
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

    fn isCjsDefaultBinding(self: *const Linker, importer: *const Module, ib: ImportBinding) bool {
        if (ib.kind != .default) return false;
        if (ib.import_record_index >= importer.import_records.len) return false;
        const src_idx = importer.import_records[ib.import_record_index].resolved;
        if (src_idx.isNone()) return false;
        const src = self.graph.getModule(src_idx) orelse return false;
        return src.wrap_kind == .cjs;
    }

    /// 링킹 실행: export 맵 구축 → import 바인딩 해결.
    pub fn link(self: *Linker) !void {
        try self.buildExportMap();

        // re-export chain이 있으면 resolveExportChain 캐시 활성화.
        // 단순 그래프(re-export 없음)에서는 캐시 오버헤드가 이득보다 크므로 비활성.
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

        try self.resolveImports();
    }

    /// 이름 충돌 감지 + 리네임에 사용하는 소유자 정보.
    const NameOwner = struct {
        module_index: u32,
        exec_index: u32,
    };

    /// name_to_owners HashMap의 타입 별칭.
    pub const NameToOwnersMap = std.StringHashMap(std.ArrayList(NameOwner));

    /// name_to_owners에 (name, owner) 항목을 추가한다.
    fn addNameOwner(
        self: *const Linker,
        name_to_owners: *NameToOwnersMap,
        name: []const u8,
        owner: NameOwner,
    ) !void {
        const entry = try name_to_owners.getOrPut(name);
        if (!entry.found_existing) {
            entry.value_ptr.* = .empty;
        }
        try entry.value_ptr.append(self.allocator, owner);
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
        const sem = m.semantic orelse return;
        if (sem.scope_maps.len == 0) return;
        const module_scope = sem.scope_maps[0];

        var scope_it = module_scope.iterator();
        while (scope_it.next()) |scope_entry| {
            const sym_name = scope_entry.key_ptr.*;
            if (std.mem.eql(u8, sym_name, "default")) continue;

            // `_default` 합성 심볼은 scope_maps에도 등록되지만 owner 등록은 export_bindings
            // 경로(line 394-)에서 전담한다. 여기서도 등록하면 같은 모듈의 같은 이름이
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
                            if (target_wrap == .cjs and ib.kind == .named and !ib.is_helper) break :blk false;
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

            try self.addNameOwner(name_to_owners, sym_name, .{
                .module_index = module_index,
                .exec_index = m.exec_index,
            });
        }

        // codegen이 현재 모듈에 `_default` 합성 변수를 만드는 모든 export를 수집.
        // 충돌 시 _default$N으로 리네이밍되도록 등록한다.
        const owner: NameOwner = .{ .module_index = module_index, .exec_index = m.exec_index };
        for (m.export_bindings) |eb| {
            if (eb.hasSyntheticDefault(m.semanticSymbols())) {
                try self.addNameOwner(name_to_owners, "_default", owner);
                continue;
            }
            if (eb.kind == .local and std.mem.eql(u8, eb.exported_name, "default")) {
                // export default function foo → foo 이름으로 등록
                const local = m.exportBindingLocalName(eb);
                if (module_scope.get(local) == null) {
                    try self.addNameOwner(name_to_owners, local, owner);
                }
            }
        }
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

            // exec_index 순으로 정렬 — 가장 낮은 게 원본 유지
            std.mem.sort(NameOwner, entry.value_ptr.items, {}, struct {
                fn lessThan(_: void, a: NameOwner, b: NameOwner) bool {
                    return a.exec_index < b.exec_index;
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
                try self.reserved_globals.put(entry.key_ptr.*, {});
            }
        }
        // 외부 전달된 전역 식별자도 예약 (--global-identifier, RN polyfillGlobal 등)
        for (self.global_identifiers) |name| {
            try self.reserved_globals.put(name, {});
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
        var name_to_owners = NameToOwnersMap.init(self.allocator);
        defer {
            var vit = name_to_owners.valueIterator();
            while (vit.next()) |list| list.deinit(self.allocator);
            name_to_owners.deinit();
        }

        for (0..self.graph.moduleCount()) |i| {
            const m = self.getModule(@intCast(i)) orelse continue;
            try self.collectModuleNames(m.*, @intCast(i), &name_to_owners);
        }

        // 2. 충돌하는 이름에 대해 리네임 계산
        try self.calculateRenames(&name_to_owners, false);

        // 3. import binding의 canonical name이 해당 모듈의 중첩 스코프와 충돌하는지 확인.
        // 충돌하면 target module의 canonical name을 한 단계 더 rename.
        // 예: d3-color의 cubehelix와 d3-interpolate 내부의 function cubehelix 충돌.
        try self.resolveNestedShadowConflicts(&name_to_owners);
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
    pub fn collectUnifiedInput(self: *const Linker) !UnifiedCollect {
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

        var candidates: std.ArrayListUnmanaged(um.TopLevelCandidate) = .empty;
        errdefer candidates.deinit(self.allocator);

        // 두 set 을 한 module pass 로 채운다:
        //   - exported: candidate 단계 skip filter (entry export + external import 만)
        //   - reserved: Phase A base54 회피 set (위 + non-external import binding 까지)
        // (#2971) zod 의 \`class z\` 가 entry import alias \`z\` 와 충돌한 root cause —
        // inline 처리되어 var 가 안 만들어지더라도 entry source 의 reference 식별자는
        // 그대로 emit 되므로 mangler 가 같은 이름을 다른 binding 의 short name 으로
        // 부여하면 SyntaxError. is_external 무관하게 reserved 에 등록.
        var exported = std.StringHashMap(void).init(self.allocator);
        defer exported.deinit();
        var reserved = std.StringHashMap(void).init(self.allocator);
        defer reserved.deinit();
        var mit = self.graph.modulesIterator();
        while (mit.next()) |m| {
            if (m.is_entry_point) {
                for (m.export_bindings) |eb| {
                    const exported_name = eb.exported_name;
                    const local_name = m.exportBindingLocalName(eb);
                    try exported.put(exported_name, {});
                    try exported.put(local_name, {});
                    try reserved.put(exported_name, {});
                    try reserved.put(local_name, {});
                }
            }
            for (m.import_bindings) |ib| {
                if (ib.import_record_index >= m.import_records.len) continue;
                // External import bindings may not have a semantic local symbol when the
                // import is only preserved for output syntax. In that case the scanner
                // local name is the external contract we must not mangle.
                const local_name = if (ib.local_symbol.isValid()) m.importBindingLocalName(ib) else ib.local_name;
                try reserved.put(local_name, {});
                if (m.import_records[ib.import_record_index].is_external) {
                    try exported.put(local_name, {});
                }
            }
        }

        const helper_modules = @import("../runtime_helper_modules.zig");
        for (0..mod_count) |mi| {
            const m = self.getModule(@intCast(mi)).?;
            const sem_opt = m.semantic;
            const sym_count = if (sem_opt) |s| s.symbols.items.len else 0;
            bitsets[created] = try std.DynamicBitSet.initEmpty(self.allocator, sym_count);
            created += 1;

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
                            const key = if (sym.canonical_name.len > 0) sym.canonical_name else sym.synthetic_name;
                            if (key.len <= 1) continue;
                            if (exported.contains(key)) continue;
                            try candidates.append(self.allocator, .{
                                .module_index = @intCast(mi),
                                .symbol_id = @intCast(si),
                                .name = key,
                                .ref_count = if (sym.reference_count == 0) 1 else sym.reference_count,
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
                            try reserved.put(sym_name, {});
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

                        const key = if (sym.canonical_name.len > 0) sym.canonical_name else sym_name;
                        if (key.len <= 1) {
                            // canonical_name 이 sym_name 과 다른 1-char 케이스도 reserve
                            // (위 sym_name 분기와 대칭 — #2965).
                            try reserved.put(key, {});
                            continue;
                        }
                        if (exported.contains(key)) continue;

                        try candidates.append(self.allocator, .{
                            .module_index = @intCast(mi),
                            .symbol_id = sym_idx,
                            .name = key,
                            .ref_count = sym.reference_count,
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
                        const key = if (sym.canonical_name.len > 0) sym.canonical_name else sym.synthetic_name;
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
                        });
                    }
                }

                modules[mi] = .{
                    .scopes = sem.scopes,
                    .symbols = sem.symbols.items,
                    .scope_maps = sem.scope_maps,
                    .references = sem.references,
                    .source = m.source,
                    .module_scope_symbols = bitsets[mi],
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
            .allocator = self.allocator,
        };
    }

    /// minify 활성화 시, scope hoisting 후 모든 top-level 이름을 짧은 이름으로 교체.
    /// computeRenames 이후에 호출해야 함 (충돌 해결 완료 상태).
    ///
    /// #1760: unified `mangleAll()` 한 번의 호출로 top-level + nested 모두 결정.
    /// Phase A 결과는 `Symbol.canonical_name` 에 주입 (emit 호환), Phase B 결과는
    /// linker 필드에 보관되어 `metadata.buildMetadataForAst` 가 조회 (Step 3c).
    pub fn computeMangling(self: *Linker) !void {
        var scope = profile.begin(.link_compute_mangling);
        defer scope.end();

        const um = @import("../codegen/unified_mangler.zig");

        var collected = try self.collectUnifiedInput();
        // bitsets 은 linker 로 이관 후 free, candidates/modules/reserved 는 여기서 해제.
        defer {
            self.allocator.free(collected.top_level_candidates);
            self.allocator.free(collected.modules);
            self.allocator.free(collected.reserved_names);
        }

        var result = try um.mangleAll(self.allocator, .{
            .modules = collected.modules,
            .top_level_candidates = collected.top_level_candidates,
            .global_reserved = collected.reserved_names,
        });
        // result 소유권을 linker 로 이관 (deinit 은 linker.deinit 이 담당).
        errdefer result.deinit();

        // Phase A 결과 (top-level 심볼) 를 `Symbol.canonical_name` 에 주입.
        // dup 는 canonical_strings 가 소유. result.renames 안의 원본 문자열은
        // linker.deinit 이 해제 — Phase A 값은 이중 보관이지만 단순성 우선.
        for (collected.top_level_candidates) |cand| {
            const key: um.ModuleSymKey = .{ .module_index = cand.module_index, .symbol_id = cand.symbol_id };
            const mangled = result.renames.get(key) orelse continue;
            const cand_mod = self.getModule(cand.module_index) orelse continue;
            const sem = cand_mod.semantic orelse continue;
            if (cand.symbol_id >= sem.symbols.items.len) continue;
            const sym = &sem.symbols.items[cand.symbol_id];
            const dup = try self.allocator.dupe(u8, mangled);
            try self.assignSymbolCanonical(sym, dup);
        }

        if (self.mangle_report) |r| {
            r.top_level = result.phase_a;
            r.top_level_reserved_pool = result.phase_a.reserved_size;
            for (result.phase_b_modules, 0..) |stats, mi| {
                const m = self.getModule(@intCast(mi)) orelse continue;
                try r.recordNested(m.path, stats);
            }
        }

        if (debug_log.enabled(.mangle_dump)) {
            debug_log.print(.mangle_dump, "module\tsymbol_id\torig\tmangled\tref_count\tkind\tmod_included\n", .{});
            for (collected.top_level_candidates) |cand| {
                const key: um.ModuleSymKey = .{ .module_index = cand.module_index, .symbol_id = cand.symbol_id };
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

    /// 다른 모듈의 리네임 대상으로 이미 할당된 이름인지 O(1) 확인.
    fn isCanonicalNameTaken(self: *const Linker, name: []const u8) bool {
        return self.canonical_names_used.contains(name);
    }

    /// (module_index, local_name)의 canonical_name을 설정. value 소유권은
    /// canonical_strings로 이전 (caller가 미리 dupe해서 넘김). Symbol을 못 찾으면
    /// value를 free하고 silently noop.
    fn putCanonicalName(self: *Linker, module_index: u32, name: []const u8, value: []const u8) !void {
        const sym = self.findSymbolMutable(module_index, name) orelse {
            self.allocator.free(value);
            return;
        };
        try self.assignSymbolCanonical(sym, value);
    }

    /// Symbol에 직접 canonical_name을 할당. value 소유권을 canonical_strings로 이전.
    /// 이전 canonical_name이 있으면 used set에서만 제거 (string은 deinit까지 보관).
    fn assignSymbolCanonical(self: *Linker, sym: *semantic_symbol.Symbol, value: []const u8) !void {
        const had_prior = sym.canonical_name.len > 0;
        if (had_prior) _ = self.canonical_names_used.fetchRemove(sym.canonical_name);
        try self.canonical_strings.append(self.allocator, value);
        try self.canonical_names_used.put(value, {});
        if (!had_prior) try self.canonical_symbols.append(self.allocator, sym);
        sym.canonical_name = value;
    }

    /// scope_maps[0] → synthetic_name fallback으로 mutable Symbol 찾기.
    /// `lookupSymbolCanonical`도 이 logic 위에서 동작.
    fn findSymbolMutable(self: *const Linker, module_index: u32, name: []const u8) ?*semantic_symbol.Symbol {
        const m = self.getModule(module_index) orelse return null;
        const sem = m.semantic orelse return null;
        if (sem.scope_maps.len > 0) {
            if (sem.scope_maps[0].get(name)) |sym_idx| {
                if (sym_idx < sem.symbols.items.len) {
                    return &sem.symbols.items[sym_idx];
                }
            }
        }
        for (sem.symbols.items) |*sym| {
            if (sym.synthetic_kind != null and std.mem.eql(u8, sym.synthetic_name, name)) {
                return sym;
            }
        }
        return null;
    }

    /// 모듈의 중첩 스코프 (비-모듈 스코프) 에 해당 이름이 존재하는지 확인.
    /// esbuild/rolldown/rollup 과 동일하게 semantic.scope_maps 직접 scan — scope 깊이는
    /// 보통 1~10 정도라 별도 cache 없이 충분.
    fn hasNestedBinding(self: *const Linker, module_index: u32, name: []const u8) bool {
        const m = self.getModule(module_index) orelse return false;
        const sem = m.semantic orelse return false;
        for (sem.scope_maps, 0..) |scope_map, scope_idx| {
            if (scope_idx == 0) continue;
            if (scope_map.get(name) != null) return true;
        }
        return false;
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
        const sym = self.findSymbolMutable(module_index, name) orelse return null;
        if (!sym.hasCanonicalName()) return null;
        return sym.canonical_name;
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
    /// - alias: AliasTable이 canonical_name 소유 → 직접 반환.
    /// - semantic: Symbol.canonical_name 직접 조회. 미설정 시 string map fallback
    ///   (synthetic 심볼 등 mirror 안 된 케이스).
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
                const sym = &sem.symbols.items[idx];
                if (sym.hasCanonicalName()) break :blk sym.canonical_name;
                break :blk null;
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
                try self.export_map.put(key, .{
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

                // re-export 체인을 따라가서 canonical export 찾기
                const canonical = self.resolveExportChain(
                    source_record.resolved,
                    ib.imported_name,
                    0,
                ) orelse {
                    // export를 찾을 수 없음
                    self.addDiag(
                        .missing_export,
                        .@"error",
                        m.path,
                        ib.local_span,
                        .link,
                        "Imported name not found in module",
                        ib.imported_name,
                    );
                    continue;
                };

                const bk = BindingKey{
                    .module_index = @intCast(i),
                    .span_key = types.spanKey(ib.local_span),
                };
                try self.resolved_bindings.put(bk, .{
                    .local_name = ib.local_name,
                    .local_span = ib.local_span,
                    .canonical = canonical,
                });
            }
        }
    }

    /// re-export 체인을 따라가서 canonical export를 찾는다.
    /// 깊이 제한 100 (순환 re-export 방지).
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

            const result = self.resolveExportChainInner(module_idx, name, depth);

            const owned_key = self.allocator.dupe(u8, cache_key) catch return result;
            const mutable_self: *Linker = @constCast(self);
            mutable_self.chain_cache.put(self.allocator, owned_key, .{ .result = result }) catch {
                self.allocator.free(owned_key);
            };
            return result;
        }

        return self.resolveExportChainInner(module_idx, name, depth);
    }

    /// resolveExportChain 내부 구현 (캐시 없이).
    fn resolveExportChainInner(
        self: *const Linker,
        module_idx: ModuleIndex,
        name: []const u8,
        depth: u32,
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
                            if (self.resolveOrCjsFallback(source_mod, entry.binding.local_name, depth + 1)) |result| {
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
                            return self.resolveExportChainInner(source_mod, ib.imported_name, depth + 1);
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

        // 2. export * 확인 (re_export_all)
        const m = m_any;
        for (m.export_bindings) |eb| {
            if (!eb.kind.isReExportAll()) continue;
            if (eb.import_record_index) |rec_idx| {
                if (rec_idx < m.import_records.len) {
                    const source_mod = m.import_records[rec_idx].resolved;
                    if (!source_mod.isNone()) {
                        // CJS fallback은 실제 `module.exports`/`exports.*` 소스에만 유효하다.
                        // 런타임 값이 비어 있는 type barrel이 임의의 이름을 소유하면 안 된다.
                        if (self.resolveOrCjsFallback(source_mod, name, depth + 1)) |result| {
                            return result;
                        }
                    }
                }
            }
        }

        return null;
    }

    /// resolveExportChain + CJS fallback. CJS 모듈은 정적 export가 없으므로
    /// resolve 실패 시 CJS 모듈 자체를 반환하여 소비자가 require_xxx()로 접근.
    fn resolveOrCjsFallback(self: *const Linker, source_mod: ModuleIndex, name: []const u8, depth: u32) ?SymbolRef {
        if (self.resolveExportChainInner(source_mod, name, depth)) |result| return result;
        if (self.graph.getModule(source_mod)) |sm| {
            if (sm.wrap_kind == .cjs and sm.has_cjs_export_signal) return .{ .module_index = source_mod, .export_name = name };
        }
        return null;
    }

    /// namespace 식별자가 member access 이외의 위치에서 사용되는지 판별.
    /// `ns.prop`만 사용되면 false (직접 치환 가능), `console.log(ns)` 등이면 true (객체 필요).
    pub fn isNamespaceUsedAsValue(allocator: std.mem.Allocator, ast: *const Ast, symbol_ids: []const ?u32, ns_sym_id: u32) bool {
        return namespace_access.isNamespaceUsedAsValue(allocator, ast, symbol_ids, ns_sym_id);
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

        const mod_count = self.graph.moduleCount();
        for (0..mod_count) |i| {
            const importer = self.moduleAtMut(@intCast(i)) orelse continue;
            const sem = importer.semantic orelse continue;
            const ast = if (importer.ast) |*a| a else continue;
            // 결과 슬라이스는 module.parse_arena가 소유 — 모듈 수명 동안 유효하고
            // deinit 시 자동 해제. linker.allocator를 쓰면 누수 위험.
            const arena = if (importer.parse_arena) |pa| pa.allocator() else continue;

            if (sem.scope_maps.len == 0) continue;

            // 분석 대상 (namespace, virtual-namespace named, 또는 CJS default) import 가 하나도 없으면
            // index 구축 전에 outer skip — AST 전체 순회 비용 회피 (#1735).
            const has_candidate = blk: {
                for (importer.import_bindings) |ib| {
                    if (ib.kind == .namespace) break :blk true;
                    if (ib.kind == .named and ib.namespace_used_properties == null) break :blk true;
                    if (self.isCjsDefaultBinding(importer, ib)) break :blk true;
                }
                break :blk false;
            };
            if (!has_candidate) continue;

            // importer 당 1회만 AST 순회해 NamespaceAccessIndex 구축.
            // 같은 모듈 안의 모든 namespace import 분석에 공유 (#1735).
            var ns_index = namespace_access.NamespaceAccessIndex.build(self.allocator, ast) catch continue;
            defer ns_index.deinit(self.allocator);

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
                if (!is_namespace and !is_named_candidate and !is_cjs_default_candidate) continue;

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
                    &ns_index,
                ) catch continue;
                defer access.deinit(self.allocator);

                if (access.kind == .@"opaque") {
                    // `.namespace`와 CJS default는 text-based 결과를 신뢰하지 않음 —
                    // null로 덮어써 전체 namespace/default fallback. `.named` virtual ns는
                    // null 유지(기존 동작).
                    if (is_namespace or is_cjs_default_candidate) {
                        ib.namespace_used_properties = null;
                        ib.namespace_used_property_stmts = null;
                    }
                    continue;
                }

                // 접근된 멤버를 namespace_used_properties에 복사.
                // 문자열은 source buffer 참조 (ast.getText 결과) — module.parse_arena 수명 동안 유효.
                // 슬라이스 자체도 arena로 할당해 deinit 시 자동 해제.
                const count = access.members.count();
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

        const req_var = try target.allocRequireName(self.allocator);
        defer self.allocator.free(req_var);
        return try std.fmt.allocPrint(self.allocator, "{s}().{s}", .{ req_var, ref.export_name });
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
        seen: *std.StringHashMap(void),
        visited: *std.AutoHashMap(u32, void),
        module_idx: ModuleIndex,
        depth: u32,
    ) std.mem.Allocator.Error!void {
        if (depth > max_chain_depth) return;
        const mod_i = @intFromEnum(module_idx);
        const m = self.graph.getModule(module_idx) orelse return;
        // diamond export * 패턴에서 동일 모듈 재방문 방지
        if (visited.contains(mod_i)) return;
        try visited.put(mod_i, {});

        // namespace import를 O(1) 조회용 맵으로 수집 (local_name → import_record_index)
        var ns_imports = std.StringHashMap(u32).init(self.allocator);
        defer ns_imports.deinit();
        for (m.import_bindings) |mib| {
            if (mib.kind == .namespace) {
                try ns_imports.put(mib.local_name, mib.import_record_index);
            }
        }

        for (m.export_bindings) |eb| {
            // 일반 export * from (exported_name == "*") → 재귀로 처리 (skip)
            // export * as ns (exported_name != "*") → named export로 포함
            if (eb.kind == .re_export_star) continue;
            if (seen.contains(eb.exported_name)) continue;
            try seen.put(eb.exported_name, {});

            const eb_local = m.exportBindingLocalName(eb);
            // ns_target_mod: hoisted ns_var 가 필요한 source 모듈 (registerNamespaceRewrites
            // 가 처리). inline literal 을 직접 만들어 inner_map 에 넣으면 emitStaticMember
            // 가 access site 마다 객체 literal 을 inline emit (#1928). 대신 source mod_idx
            // 만 기록하고 ns_var 등록은 호출 site 가 일임.
            var ns_target_mod: ?u32 = null;
            var owns_actual_local = false;
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
            });
        }

        // export * 재귀 — export * as ns는 이미 첫 루프에서 인라인 객체로 처리됨.
        // ESM 스펙: export *는 "default"를 제외 (ECMAScript 15.2.3.5).
        // seen에 "default"를 추가하여 하위 모듈의 default export가 수집되지 않도록 함.
        // 직접 선언된 export { default }는 위 첫 루프에서 이미 수집됨.
        try seen.put("default", {});
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

    /// canonical_names를 초기화한다. 키와 값의 메모리를 해제하고 맵을 비운다.
    /// per-chunk rename에서 이전 청크의 결과를 제거할 때 사용.
    pub fn clearCanonicalNames(self: *Linker) void {
        for (self.canonical_strings.items) |s| self.allocator.free(s);
        self.canonical_strings.clearRetainingCapacity();
        self.canonical_names_used.clearRetainingCapacity();
        // O(touched): putCanonicalName이 기록한 dirty 심볼만 reset.
        for (self.canonical_symbols.items) |sym| sym.canonical_name = "";
        self.canonical_symbols.clearRetainingCapacity();
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
        self.populateSymbolRefCounts();
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
                try self.reserved_globals.put(entry.key_ptr.*, {});
            }
        }

        // 1. 지정된 모듈의 top-level 심볼 이름 수집
        var name_to_owners = NameToOwnersMap.init(self.allocator);
        defer {
            var vit = name_to_owners.valueIterator();
            while (vit.next()) |list| list.deinit(self.allocator);
            name_to_owners.deinit();
        }

        // cross-chunk import 이름을 "점유"로 등록 — exec_index=0 (가장 낮음)으로
        // 등록하여 충돌 시 로컬 심볼이 rename됨 (import 이름이 우선 유지)
        for (occupied_names) |name| {
            if (std.mem.eql(u8, name, "default")) continue;
            const entry = try name_to_owners.getOrPut(name);
            if (!entry.found_existing) {
                entry.value_ptr.* = .empty;
            }
            try entry.value_ptr.append(self.allocator, .{
                .module_index = std.math.maxInt(u32), // 특수 마커 — 실제 모듈 아님
                .exec_index = 0, // 가장 낮은 exec_index → 원본 이름 유지
            });
        }

        for (module_indices) |mod_idx| {
            const m = self.graph.getModule(mod_idx) orelse continue;
            try self.collectModuleNames(m.*, mod_idx.toU32(), &name_to_owners);
        }

        // 2. 충돌하는 이름에 대해 리네임 계산 (cross-chunk 점유 마커는 skip)
        try self.calculateRenames(&name_to_owners, true);
    }

    pub const makeExportKey = types.makeModuleKey;
    pub const makeExportKeyBuf = types.makeModuleKeyBuf;
};

/// CJS 모듈의 require_xxx 변수명을 캐시에서 가져오거나 새로 생성.
pub fn getOrCreateRequireVar(
    self: *const Linker,
    cache: *std.AutoHashMap(u32, []const u8),
    mod_idx: u32,
) ![]const u8 {
    if (cache.get(mod_idx)) |cached| return cached;
    const target_mod = self.getModule(mod_idx).?;
    const name = try target_mod.allocRequireName(self.allocator);
    try cache.put(mod_idx, name);
    return name;
}
