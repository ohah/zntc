//! ZTS Bundler — Linker
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
const NodeIndex = @import("../parser/ast.zig").NodeIndex;
const Ast = @import("../parser/ast.zig").Ast;
const semantic_symbol = @import("../semantic/symbol.zig");
const bundler_symbol = @import("symbol.zig");
const stmt_info_mod = @import("stmt_info.zig");
const profile = @import("../profile.zig");
const rt = @import("runtime_helpers.zig");
const ManglerStats = @import("../codegen/mangler.zig").ManglerStats;
const CompiledModule = @import("compiled_module.zig").CompiledModule;

/// namespace 접근 패턴에서 생성되는 변수 prefix.
/// metadata.zig, codegen.zig, emitter.zig에서 공유.
pub const NS_VAR_PREFIX = "__ns_";

/// `__ns_N.prop` 형태의 namespace-access rename 인지 판정.
/// CJS-in-ESM-wrapped named import가 이 rename을 가진다 (metadata.zig 참조).
pub inline fn isNamespaceRename(rename: []const u8) bool {
    return std.mem.startsWith(u8, rename, NS_VAR_PREFIX);
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
    allocator: std.mem.Allocator,

    pub fn deinit(self: *UnifiedCollect) void {
        self.allocator.free(self.top_level_candidates);
        self.allocator.free(self.modules);
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

/// `--mangle-report` 전용 측정 수집기 (#1760 property harness).
///
/// Bundler 가 생성해 `Linker.mangle_report` 에 꽂으면 `computeMangling` 과
/// `buildMetadataForAst` 내부 nested mangler 가 호출마다 통계를 append.
/// Unified mangler 마이그레이션 전/후의 수치 비교 baseline.
///
/// `buildMetadataForAst` 는 emitter 가 병렬 호출하므로 `recordNested` 는 mutex 보호.
pub const MangleReportCollector = struct {
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex = .{},

    top_level: ManglerStats = .{},
    /// top-level 충돌 방지 pool 크기 (scope_maps 이름 + canonical_strings 합집합).
    top_level_reserved_pool: usize = 0,

    nested: std.ArrayListUnmanaged(NestedEntry) = .empty,
    /// Bundle emit 후 채움.
    bundle_size_bytes: usize = 0,

    pub const NestedEntry = struct {
        /// linker 생명주기 내 유효 (module.path 차용).
        module_path: []const u8,
        stats: ManglerStats,
    };

    pub fn init(allocator: std.mem.Allocator) MangleReportCollector {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *MangleReportCollector) void {
        self.nested.deinit(self.allocator);
    }

    pub fn recordNested(
        self: *MangleReportCollector,
        module_path: []const u8,
        stats: ManglerStats,
    ) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.nested.append(self.allocator, .{ .module_path = module_path, .stats = stats });
    }

    pub fn writeJson(self: *const MangleReportCollector, writer: anytype) !void {
        var totals: ManglerStats = .{
            .slot_count = self.top_level.slot_count,
            .slot_name_length_sum = self.top_level.slot_name_length_sum,
            .renamed_symbol_count = self.top_level.renamed_symbol_count,
        };
        try writer.writeAll("{\n  \"top_level\": ");
        try writeStatsJson(writer, self.top_level);
        try writer.print(",\n  \"top_level_reserved_pool\": {d},\n  \"nested\": [", .{self.top_level_reserved_pool});
        for (self.nested.items, 0..) |entry, i| {
            try writer.writeAll(if (i == 0) "\n    " else ",\n    ");
            try writer.writeAll("{\"module_path\": ");
            try writeJsonString(writer, entry.module_path);
            try writer.writeAll(", \"stats\": ");
            try writeStatsJson(writer, entry.stats);
            try writer.writeAll("}");
            totals.slot_count += entry.stats.slot_count;
            totals.slot_name_length_sum += entry.stats.slot_name_length_sum;
            totals.renamed_symbol_count += entry.stats.renamed_symbol_count;
        }
        try writer.writeAll(if (self.nested.items.len == 0) "]" else "\n  ]");
        try writer.print(",\n  \"bundle_size_bytes\": {d},\n  \"totals\": ", .{self.bundle_size_bytes});
        try writeStatsJson(writer, totals);
        try writer.writeAll("\n}\n");
    }

    fn writeStatsJson(writer: anytype, s: ManglerStats) !void {
        try writer.print(
            "{{\"slot_count\": {d}, \"slot_name_length_sum\": {d}, \"name_counter_final\": {d}, \"reserved_size\": {d}, \"renamed_symbol_count\": {d}}}",
            .{ s.slot_count, s.slot_name_length_sum, s.name_counter_final, s.reserved_size, s.renamed_symbol_count },
        );
    }

    fn writeJsonString(writer: anytype, s: []const u8) !void {
        try writer.writeByte('"');
        for (s) |c| switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => try writer.writeByte(c),
        };
        try writer.writeByte('"');
    }
};

/// 크로스 모듈 심볼 참조. 어떤 모듈의 어떤 export를 가리키는지.
/// codegen에 전달하는 per-module 메타데이터.
/// AST를 수정하지 않고 codegen이 출력 시 참조.
pub const LinkingMetadata = struct {
    /// 스킵할 AST 노드 인덱스 (import_declaration, export 키워드 등)
    skip_nodes: std.DynamicBitSet,
    /// symbol_id → 새 이름. codegen이 식별자 출력 시 symbol_ids[node_idx]로 조회.
    renames: std.AutoHashMap(u32, []const u8),
    /// 엔트리 포인트의 최종 export 문 (e.g. "export { x, y$1 as y };\n")
    final_exports: ?[]const u8,
    /// 노드 인덱스 → 심볼 인덱스 매핑. 빌림 — deinit에서 해제하지 않음.
    /// module.parse_arena 또는 transformer.symbol_ids(emit_arena)가 소유.
    symbol_ids: []const ?u32,
    /// CJS 모듈을 import하는 경우: require_xxx() 호출 preamble (e.g. "var lib = require_lib();\n")
    cjs_import_preamble: ?[]const u8 = null,
    /// export default의 합성 변수명. 이름 충돌 시 "_default$1" 등으로 변경됨.
    /// codegen이 `export default X` → `var <이름> = X;` 출력할 때 사용.
    default_export_name: []const u8 = "_default",
    /// namespace import의 member access 직접 치환 맵 (esbuild 방식).
    /// key: namespace 식별자의 symbol_id, value: export_name → canonical_local_name.
    /// codegen이 `ns.prop`를 만나면 이 맵으로 직접 치환 (namespace 객체 생성 불필요).
    ns_member_rewrites: NsMemberRewrites = .{},
    /// namespace가 값으로 사용될 때 인라인 객체 리터럴.
    /// codegen이 identifier_reference에서 ns 심볼을 만나면 이 문자열을 출력.
    ns_inline_objects: NsInlineObjects = .{},
    /// CJS 모듈 내부 require() 호출 치환 맵.
    /// require specifier 문자열 → require_xxx() 함수명.
    /// codegen이 require('path') 호출을 만나면 이 맵으로 치환.
    require_rewrites: std.StringHashMapUnmanaged([]const u8) = .{},
    /// __esm live binding에서 __export getter 값을 override.
    /// local_name → canonical_name. emitter가 __export getter 생성 시 사용.
    export_getter_overrides: std.StringHashMapUnmanaged([]const u8) = .{},
    /// symbol_id → ConstValue. 크로스-모듈 상수 인라인용.
    /// import symbol이 canonical export의 const_value를 가지면 codegen이 리터럴로 대체.
    const_values: std.AutoHashMapUnmanaged(u32, @import("../semantic/symbol.zig").ConstValue) = .{},
    /// nested mangling에서 소유권을 이전받은 문자열. deinit에서 해제.
    owned_rename_values: std.ArrayListUnmanaged([]const u8) = .empty,
    /// dev 모드 namespace import 변수명. esm_wrap에서 __esm 바깥으로 호이스팅.
    /// named import를 namespace 접근 패턴으로 전환할 때 사용.
    /// e.g., ["__ns_0", "__ns_1"] → 호이스팅: var __ns_0, __ns_1;
    dev_ns_vars: ?[]const []const u8 = null,
    /// true  = scope-hoisted 번들러 → codegen 이 export 키워드를 생략하고 declaration 만 출력.
    /// false = 단일 파일 transpile — rename map 전달 목적으로만 사용, export 선언 구조 보존.
    /// 기본값 true 는 현재 모든 생성 지점이 번들러(`buildMetadataForAst` 계열)라는 사실에
    /// 의존한다. 비-번들러 생성 지점을 추가할 때는 반드시 false 를 명시할 것.
    is_bundle_context: bool = true,
    /// #1791: build-time 에러 (e.g. IIFE 포맷 + unresolved import). `buildMetadataForAst`
    /// 가 병렬 호출되므로 직접 `linker.diagnostics` 에 append 하면 race. 대신 이 리스트에
    /// 쌓고 emitter 가 serial 경로에서 `linker.fatal_diagnostics` 로 flush.
    /// item.message 는 allocator 소유 — flush 시 소유권 이전, deinit 에서 free.
    pending_diagnostics: []const BundlerDiagnostic = &.{},
    allocator: std.mem.Allocator,

    pub const NsMemberRewrites = struct {
        /// symbol_id → (export_name → canonical_name) 매핑 배열.
        entries: []const Entry = &.{},

        pub const Entry = struct {
            symbol_id: u32,
            map: std.StringHashMap([]const u8),
        };

        /// symbol_id로 매핑 조회.
        pub fn get(self: *const NsMemberRewrites, sym_id: u32) ?*const std.StringHashMap([]const u8) {
            for (self.entries) |*e| {
                if (e.symbol_id == sym_id) return &e.map;
            }
            return null;
        }
    };

    pub const NsInlineObjects = struct {
        entries: []const Entry = &.{},

        pub const Entry = struct {
            /// `null` = declaration-only (preamble 에 `var X_ns = {...};` 만 emit, codegen
            /// `get(sid)` lookup 은 항상 miss). `re_export_namespace` 가 만든 hoisted ns_var
            /// 에 사용 (#1928).
            symbol_id: ?u32,
            object_literal: []const u8,
            var_name: []const u8,
            /// shared bundle preamble 경로에서 이 entry 가 참조하는 source module.
            /// null이면 기존 per-module preamble/declaration-only entry.
            shared_target_mod_idx: ?u32 = null,
        };

        pub fn get(self: *const NsInlineObjects, sym_id: u32) ?*const Entry {
            for (self.entries) |*e| {
                if (e.symbol_id) |sid| {
                    if (sid == sym_id) return e;
                }
            }
            return null;
        }
    };

    pub fn deinit(self: *LinkingMetadata) void {
        self.skip_nodes.deinit();
        // nested mangling에서 소유권을 이전받은 문자열 해제
        for (self.owned_rename_values.items) |v| self.allocator.free(v);
        self.owned_rename_values.deinit(self.allocator);
        self.renames.deinit();
        if (self.final_exports) |fe| self.allocator.free(fe);
        if (self.cjs_import_preamble) |p| self.allocator.free(p);
        self.const_values.deinit(self.allocator);
        // require_rewrites 해제 (keys는 import record 소유, values만 해제)
        {
            var vit = self.require_rewrites.valueIterator();
            while (vit.next()) |v| self.allocator.free(v.*);
            self.require_rewrites.deinit(self.allocator);
        }
        // ns_member_rewrites의 inner map과 entries 배열 해제
        if (self.ns_member_rewrites.entries.len > 0) {
            for (self.ns_member_rewrites.entries) |*e| {
                var m = @constCast(&e.map);
                // 인라인 객체 문자열 (allocator에서 할당됨) 해제
                var vit = m.valueIterator();
                while (vit.next()) |v| {
                    if (v.*.len > 0 and v.*[0] == '{') self.allocator.free(v.*);
                }
                m.deinit();
            }
            self.allocator.free(self.ns_member_rewrites.entries);
        }
        // ns_inline_objects 해제
        if (self.ns_inline_objects.entries.len > 0) {
            for (self.ns_inline_objects.entries) |e| {
                self.allocator.free(e.object_literal);
                self.allocator.free(e.var_name);
            }
            self.allocator.free(self.ns_inline_objects.entries);
        }
        self.export_getter_overrides.deinit(self.allocator);
        // dev_ns_vars 해제
        if (self.dev_ns_vars) |vars| {
            for (vars) |v| self.allocator.free(v);
            self.allocator.free(vars);
        }
        // Ownership: 정상 경로는 emitter 가 message 소유권을 `linker.fatal_diagnostics`
        // 로 이전한 후 slice 를 비우므로 여기서 no-op. flush 전 에러 경로에서만 해제.
        if (self.pending_diagnostics.len > 0) {
            for (self.pending_diagnostics) |d| self.allocator.free(d.message);
            self.allocator.free(self.pending_diagnostics);
        }
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

    /// dev mode: HMR용 모듈 참조를 __zts_modules["id"].fn()으로 생성.
    /// init_xxx() 대신 동적 lookup을 사용하여 new Function()에서도 접근 가능.
    dev_mode: bool = false,

    /// `EmitOptions.entry_error_guard` propagate. preamble 의 module init 호출을
    /// `__zts_guarded(fn)` 으로 wrap 하여 outermost 에서 `ErrorUtils.reportFatalError`
    /// 로 swallow. helper 자체는 emitter prologue 에 주입.
    entry_error_guard: bool = false,

    /// #1621: minify 시 preamble/metadata 에서 __toESM/__toCommonJS 등을
    /// $tE/$tC 등 축약 이름으로 emit. bundler 가 `self.options.minify_whitespace`
    /// 를 linker 생성 직후 설정한다. dev_mode 에서는 `__zts_g.__xxx` 경로를
    /// 사용하므로 이 플래그는 무시된다.
    minify_whitespace: bool = false,

    /// --shim-missing-exports: missing export에 대해 `var xxx = void 0;` shim 생성.
    shim_missing_exports: bool = false,

    /// #1791 Phase D: value 참조가 0 인 import binding 을 preamble 생성에서 elide할지.
    /// tsconfig `verbatimModuleSyntax=true` 일 때는 transformer 와 동일하게 유지해
    /// 사용자 의도 (원본 import 보존) 를 존중한다. bundler 가 init 후 설정.
    verbatim_module_syntax: bool = false,

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

    /// 모듈별 중첩 스코프 바인딩 이름 집합 (사전 구축).
    /// computeRenames에서 한 번 구축, hasNestedBinding에서 O(1) 조회.
    nested_name_sets: []std.StringHashMapUnmanaged(void) = &.{},

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

    const SharedNsInline = struct {
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
        for (self.nested_name_sets) |*set| {
            set.deinit(self.allocator);
        }
        if (self.nested_name_sets.len > 0) {
            self.allocator.free(self.nested_name_sets);
        }
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

    /// 링킹 실행: export 맵 구축 → import 바인딩 해결.
    pub fn link(self: *Linker) !void {
        try self.buildExportMap();

        // re-export chain이 있으면 resolveExportChain 캐시 활성화.
        // 단순 그래프(re-export 없음)에서는 캐시 오버헤드가 이득보다 크므로 비활성.
        var it = self.graph.modulesIterator();
        while (it.next()) |m| {
            for (m.export_bindings) |eb| {
                if (eb.kind == .re_export or eb.kind.isReExportAll()) {
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
            }

            // import binding은 일반적으로 인라인되어 변수가 생성되지 않으므로 충돌 대상 아님.
            // 단, CJS 모듈을 import하면 preamble에서 `var X = require_xxx().X`로 변수가 생성되므로
            // 충돌 대상에 포함해야 한다.
            const sym_idx = scope_entry.value_ptr.*;
            if (sym_idx < sem.symbols.items.len and sem.symbols.items[sym_idx].decl_flags.is_import) {
                // import binding이 top-level 변수를 생성하는 경우에만 충돌 대상에 포함:
                // - CJS preamble: var X = require_xxx().X
                // - __esm 호이스팅: var X; (래퍼 밖으로 호이스팅)
                const generates_top_level_var = blk: {
                    for (m.import_bindings) |ib| {
                        if (!std.mem.eql(u8, ib.local_name, sym_name)) continue;
                        if (ib.import_record_index >= m.import_records.len) break :blk false;
                        const rec = m.import_records[ib.import_record_index];
                        if (rec.resolved.isNone()) break :blk true;
                        const target_idx = @intFromEnum(rec.resolved);
                        if (target_idx >= self.graph.moduleCount()) break :blk m.wrap_kind == .esm;
                        const target_wrap = self.getModule(target_idx).?.wrap_kind;
                        if (m.wrap_kind == .esm) {
                            // CJS-in-ESM-wrapped named import는 __ns_N.prop rename으로 처리되어
                            // top-level var가 emit되지 않음 (metadata.zig:262-281 + emitter.zig:1565).
                            // → 이름 충돌 owner에서 제외해야 canonical rename이 __ns_ rename을 덮지 않는다.
                            if (target_wrap == .cjs and ib.kind == .named and !ib.isSynthetic()) break :blk false;
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

        // 1.5. 모듈별 중첩 스코프 바인딩 이름 집합을 구축.
        // calculateRenames/resolveNestedShadowConflicts에서 hasNestedBinding이 O(1)로 동작하도록 미리 구축.
        try self.buildNestedNameSets();

        // 2. 충돌하는 이름에 대해 리네임 계산
        try self.calculateRenames(&name_to_owners, false);

        // 3. import binding의 canonical name이 해당 모듈의 중첩 스코프와 충돌하는지 확인.
        // 충돌하면 target module의 canonical name을 한 단계 더 rename.
        // 예: d3-color의 cubehelix와 d3-interpolate 내부의 function cubehelix 충돌.
        try self.resolveNestedShadowConflicts(&name_to_owners);
    }

    /// import binding의 canonical name이 importer 모듈의 중첩 스코프에 같은 이름이
    /// 있으면, target module의 이름을 한 단계 더 rename하여 shadowing 충돌 방지.
    fn resolveNestedShadowConflicts(self: *Linker, name_to_owners: *const NameToOwnersMap) !void {
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

        var exported = std.StringHashMap(void).init(self.allocator);
        defer exported.deinit();
        var mit = self.graph.modulesIterator();
        while (mit.next()) |m| {
            if (m.is_entry_point) {
                for (m.export_bindings) |eb| {
                    try exported.put(eb.exported_name, {});
                    try exported.put(m.exportBindingLocalName(eb), {});
                }
            }
            for (m.import_bindings) |ib| {
                if (ib.import_record_index >= m.import_records.len) continue;
                if (!m.import_records[ib.import_record_index].is_external) continue;
                try exported.put(m.importBindingLocalName(ib), {});
            }
        }

        const helper_modules = @import("../runtime_helper_modules.zig");
        for (0..mod_count) |mi| {
            const m = self.getModule(@intCast(mi)).?;
            const sem_opt = m.semantic;
            const sym_count = if (sem_opt) |s| s.symbols.items.len else 0;
            bitsets[created] = try std.DynamicBitSet.initEmpty(self.allocator, sym_count);
            created += 1;

            // #1961 PR 1h: ZTS runtime helper virtual module 의 top-level 식별자
            // (`$aS` / `$gn` 등) 는 transformer 가 이미 축약 이름으로 emit 한 결과.
            // mangler 가 추가 rename 하면 cross-module binding 이 깨진다 (main 의
            // `$aS` import 호출 site 와 helper 의 var declaration 이 다른 이름).
            // helper module 은 후보 / Phase B 양쪽 skip — modules[mi] 는 빈 entry 로 init.
            const is_helper_module = helper_modules.isVirtualId(m.path);
            if (is_helper_module) {
                modules[mi] = .{
                    .scopes = &.{},
                    .symbols = &.{},
                    .scope_maps = &.{},
                    .references = &.{},
                    .source = m.source,
                    .module_scope_symbols = bitsets[mi],
                };
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
                        if (sym_name.len <= 1) continue;
                        if (std.mem.eql(u8, sym_name, "default")) continue;
                        if (std.mem.eql(u8, sym_name, "arguments")) continue;

                        const sym = &sem.symbols.items[sym_idx];
                        if (sym.kind == .import_binding) continue;
                        // synthetic default 는 아래 별도 루프가 처리 —
                        // 같은 symbol 을 candidates 에 중복 추가하면
                        // mangleAll 의 renames.put 이 이전 value 를 덮어써 leak.
                        if (sym.synthetic_kind == .default_export) continue;

                        const key = if (sym.canonical_name.len > 0) sym.canonical_name else sym_name;
                        if (key.len <= 1) continue;
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
                        if (sk != .default_export) continue;
                        const key = if (sym.canonical_name.len > 0) sym.canonical_name else sym.synthetic_name;
                        if (key.len <= 1) continue;
                        if (exported.contains(key)) continue;
                        try candidates.append(self.allocator, .{
                            .module_index = @intCast(mi),
                            .symbol_id = @intCast(si),
                            .name = key,
                            .ref_count = sym.reference_count,
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
                modules[mi] = .{
                    .scopes = &.{},
                    .symbols = &.{},
                    .scope_maps = &.{},
                    .references = &.{},
                    .source = m.source,
                    .module_scope_symbols = bitsets[mi],
                };
            }
        }

        return .{
            .top_level_candidates = try candidates.toOwnedSlice(self.allocator),
            .modules = modules,
            .bitsets = bitsets,
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
        // bitsets 은 linker 로 이관 후 free, candidates/modules 는 여기서 해제.
        defer {
            self.allocator.free(collected.top_level_candidates);
            self.allocator.free(collected.modules);
        }

        var result = try um.mangleAll(self.allocator, .{
            .modules = collected.modules,
            .top_level_candidates = collected.top_level_candidates,
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

    /// 모듈의 중첩 스코프(비-모듈 스코프)에 해당 이름이 존재하는지 확인.
    /// 첫 호출 시 해당 모듈의 nested name set을 lazy 구축하여 이후 O(1) 조회.
    fn hasNestedBinding(self: *const Linker, module_index: u32, name: []const u8) bool {
        if (module_index < self.nested_name_sets.len) {
            return self.nested_name_sets[module_index].contains(name);
        }

        // fallback
        const m = self.getModule(module_index) orelse return false;
        const sem = m.semantic orelse return false;
        for (sem.scope_maps, 0..) |scope_map, scope_idx| {
            if (scope_idx == 0) continue;
            if (scope_map.get(name) != null) return true;
        }
        return false;
    }

    /// 모듈별 중첩 스코프 바인딩 이름을 하나의 HashSet으로 병합.
    /// computeRenames에서 한 번 호출하면, 이후 hasNestedBinding이 O(1)로 동작.
    fn buildNestedNameSets(self: *Linker) !void {
        const count = self.graph.moduleCount();
        const sets = try self.allocator.alloc(std.StringHashMapUnmanaged(void), count);
        for (sets) |*s| s.* = .{};

        for (0..count) |i| {
            const m = self.getModule(@intCast(i)) orelse continue;
            const sem = m.semantic orelse continue;
            for (sem.scope_maps, 0..) |scope_map, scope_idx| {
                if (scope_idx == 0) continue; // 모듈 스코프는 스킵
                var it = scope_map.iterator();
                while (it.next()) |entry| {
                    try sets[i].put(self.allocator, entry.key_ptr.*, {});
                }
            }
        }
        self.nested_name_sets = sets;
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
            return self.getCanonicalByRef(eb.symbol) orelse local;
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
    pub const buildCrossModuleConstValues = metadata_mod.buildCrossModuleConstValues;
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
            if (sm.wrap_kind == .cjs) return .{ .module_index = source_mod, .export_name = name };
        }
        return null;
    }

    /// namespace 식별자가 member access 이외의 위치에서 사용되는지 판별.
    /// `ns.prop`만 사용되면 false (직접 치환 가능), `console.log(ns)` 등이면 true (객체 필요).
    pub fn isNamespaceUsedAsValue(allocator: std.mem.Allocator, ast: *const Ast, symbol_ids: []const ?u32, ns_sym_id: u32) bool {
        const node_count = ast.nodes.items.len;
        if (node_count == 0) return false;

        // 1. member access의 object 위치를 비트셋으로 수집 — O(N) 스캔, O(1) 조회
        var safe = std.DynamicBitSet.initEmpty(allocator, node_count) catch return true;
        defer safe.deinit();

        for (ast.nodes.items) |node| {
            if (node.tag == .static_member_expression or node.tag == .private_field_expression) {
                const e = node.data.extra;
                if (ast.hasExtra(e, 2)) {
                    const obj_idx = ast.readExtra(e, 0);
                    if (obj_idx < node_count) safe.set(obj_idx);
                }
            }
        }

        // 2. ns 심볼 참조 확인 — 안전 위치가 아닌 참조가 하나라도 있으면 값 사용
        for (symbol_ids, 0..) |maybe_sid, node_i| {
            if (maybe_sid) |sid| {
                if (sid == ns_sym_id) {
                    // import specifier/binding 선언 위치는 skip
                    if (node_i < node_count) {
                        const tag = ast.nodes.items[node_i].tag;
                        if (tag == .import_namespace_specifier or tag == .import_default_specifier or
                            tag == .import_specifier or tag == .binding_identifier) continue;
                    }
                    if (node_i >= node_count or !safe.isSet(node_i)) return true;
                }
            }
        }
        return false;
    }

    /// namespace 심볼에 대한 AST 수준의 멤버 접근 정밀도 분석 결과 (#1603 Phase 1).
    ///
    /// `kind == .member_only`: 모든 참조가 `ns.prop` 형태 — `members` 집합이 접근된 프로퍼티.
    /// `kind == .opaque`: 값으로 사용되거나 computed access 등 → `members`는 비어 있고 fallback 필요.
    pub const NamespaceAccess = struct {
        kind: Kind,
        /// property → 해당 `ns.prop` 접근이 발생한 top-level stmt 인덱스 목록.
        /// stmt_spans가 전달된 경우에만 채워지며, 없으면 빈 리스트.
        members: std.StringHashMapUnmanaged(std.ArrayListUnmanaged(u32)) = .{},

        pub const Kind = enum { member_only, @"opaque" };

        pub fn deinit(self: *NamespaceAccess, allocator: std.mem.Allocator) void {
            var it = self.members.valueIterator();
            while (it.next()) |list| list.deinit(allocator);
            self.members.deinit(allocator);
        }
    };

    /// `analyzeNamespaceAccess` 의 ns_sym_id-독립 인덱스.
    /// 같은 AST 를 여러 namespace import 로 분석할 때 (`populateNamespaceAccesses`) 공유해
    /// AST 전체 순회를 importer 당 1회로 줄인다 (#1735).
    const NamespaceAccessIndex = struct {
        /// obj_node_idx → prop_node_idx 매핑 (static/private member expression).
        prop_by_obj: std.AutoHashMapUnmanaged(u32, u32) = .{},
        /// import declaration span 범위 — 이 안의 identifier_reference 는 선언이므로 skip.
        decl_ranges: std.ArrayListUnmanaged(DeclRange) = .empty,

        pub const DeclRange = struct { start: u32, end: u32 };

        pub fn build(allocator: std.mem.Allocator, ast: *const Ast) std.mem.Allocator.Error!NamespaceAccessIndex {
            var self: NamespaceAccessIndex = .{};
            errdefer self.deinit(allocator);
            const node_count = ast.nodes.items.len;
            for (ast.nodes.items) |node| {
                switch (node.tag) {
                    .static_member_expression, .private_field_expression => {
                        const e = node.data.extra;
                        if (!ast.hasExtra(e, 2)) continue;
                        const obj_idx = ast.readExtra(e, 0);
                        const prop_idx = ast.readExtra(e, 1);
                        if (obj_idx < node_count and prop_idx < node_count) {
                            try self.prop_by_obj.put(allocator, obj_idx, prop_idx);
                        }
                    },
                    .import_declaration => {
                        try self.decl_ranges.append(allocator, .{ .start = node.span.start, .end = node.span.end });
                    },
                    else => {},
                }
            }
            return self;
        }

        pub fn deinit(self: *NamespaceAccessIndex, allocator: std.mem.Allocator) void {
            self.prop_by_obj.deinit(allocator);
            self.decl_ranges.deinit(allocator);
        }
    };

    /// namespace 심볼의 모든 참조를 스캔해 member-only 접근 여부와 접근된 프로퍼티 집합을 수집.
    /// tree-shaker가 이 정보를 바탕으로 target 모듈의 `export` 중 실제 필요한 것만 live로 표시.
    ///
    /// member_only 조건:
    ///   - 모든 ns 참조가 `static_member_expression` / `private_field_expression`의 object 위치
    ///   - import specifier / binding_identifier 등 선언 위치는 제외 (참조 아님)
    ///
    /// opaque 처리되는 경우:
    ///   - 값 전달(`f(ns)`), spread(`{...ns}`), 리플렉션(`Object.keys(ns)`)
    ///   - computed access (`ns[key]`) — key가 동적이라 정밀도 보장 불가
    ///
    /// 주의: members의 문자열은 `ast.getText` 결과 (source 버퍼 참조). ast 수명 동안만 유효.
    pub fn analyzeNamespaceAccess(
        allocator: std.mem.Allocator,
        ast: *const Ast,
        symbol_ids: []const ?u32,
        ns_sym_id: u32,
        /// top-level statement의 source span. 전달하면 각 access의 owning stmt 인덱스를
        /// `members[prop]`에 기록 (#1626 dead-scope gating). null이면 기록하지 않는다.
        stmt_spans: ?[]const Span,
    ) std.mem.Allocator.Error!NamespaceAccess {
        var index = try NamespaceAccessIndex.build(allocator, ast);
        defer index.deinit(allocator);
        return analyzeNamespaceAccessWithIndex(allocator, ast, symbol_ids, ns_sym_id, stmt_spans, &index);
    }

    /// `analyzeNamespaceAccess` 의 ns_sym_id-의존 후반부만 분리.
    /// 호출자가 `NamespaceAccessIndex` 를 한 번 구축해 여러 namespace 심볼에 재사용 (#1735).
    fn analyzeNamespaceAccessWithIndex(
        allocator: std.mem.Allocator,
        ast: *const Ast,
        symbol_ids: []const ?u32,
        ns_sym_id: u32,
        stmt_spans: ?[]const Span,
        index: *const NamespaceAccessIndex,
    ) std.mem.Allocator.Error!NamespaceAccess {
        const node_count = ast.nodes.items.len;
        var access: NamespaceAccess = .{ .kind = .member_only };
        errdefer access.deinit(allocator);
        if (node_count == 0) return access;

        for (symbol_ids, 0..) |maybe_sid, node_i| {
            const sid = maybe_sid orelse continue;
            if (sid != ns_sym_id) continue;
            if (node_i >= node_count) {
                // 인덱스 범위 밖 참조는 보수적으로 opaque
                // #1754: `members.deinit` 만 호출하면 value ArrayList 의 backing
                // buffer 가 leak. 전체 deinit 으로 value 까지 해제 후 초기화.
                access.deinit(allocator);
                access.members = .{};
                access.kind = .@"opaque";
                return access;
            }

            const node = ast.nodes.items[node_i];
            const tag = node.tag;
            // 선언 위치는 참조 아님 — 건너뜀
            if (tag == .import_namespace_specifier or tag == .import_default_specifier or
                tag == .import_specifier or tag == .binding_identifier) continue;

            // import/export declaration 내부 참조(specifier의 identifier_reference 등)도 skip
            var in_decl = false;
            for (index.decl_ranges.items) |r| {
                if (node.span.start >= r.start and node.span.end <= r.end) {
                    in_decl = true;
                    break;
                }
            }
            if (in_decl) continue;

            if (index.prop_by_obj.get(@intCast(node_i))) |prop_node_idx| {
                const prop_node = ast.nodes.items[prop_node_idx];
                const name = ast.getText(prop_node.span);
                if (name.len == 0) continue;

                const gop = try access.members.getOrPut(allocator, name);
                if (!gop.found_existing) gop.value_ptr.* = .empty;

                if (stmt_spans) |spans| {
                    // owning statement 인덱스 기록. 함수 body 내부 access도 그 함수의
                    // 선언 statement span 안에 있으므로 binary search로 귀속 가능.
                    if (stmt_info_mod.findStmtForPos(spans, node.span.start)) |stmt_idx| {
                        // 중복 방지: 같은 stmt에서 같은 prop이 여러 번 accessed될 수 있다.
                        const list = gop.value_ptr;
                        var exists = false;
                        for (list.items) |existing| {
                            if (existing == stmt_idx) {
                                exists = true;
                                break;
                            }
                        }
                        if (!exists) try list.append(allocator, stmt_idx);
                    }
                }
            } else {
                // member-expr object가 아닌 참조 위치 — opaque
                // #1754: `members.deinit` 만 호출하면 이전에 append 된 value ArrayList 의
                // backing buffer 가 leak. 전체 deinit 으로 value 까지 해제 후 초기화.
                access.deinit(allocator);
                access.members = .{};
                access.kind = .@"opaque";
                return access;
            }
        }

        return access;
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
                // current-side: scope_maps[0]에서 로컬 심볼 조회
                if (module_scope_opt) |module_scope| {
                    if (!ib.isSynthetic()) {
                        if (module_scope.get(ib.local_name)) |sym_idx| {
                            ib.local_symbol = bundler_symbol.SymbolRef.makeSemantic(mod_idx, sym_idx);
                        }
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
            const arena = if (importer.parse_arena) |*pa| pa.allocator() else continue;

            if (sem.scope_maps.len == 0) continue;

            // 분석 대상 (namespace 또는 virtual-namespace named) import 가 하나도 없으면
            // index 구축 전에 outer skip — AST 전체 순회 비용 회피 (#1735).
            const has_candidate = blk: {
                for (importer.import_bindings) |ib| {
                    const is_namespace = ib.kind == .namespace;
                    const is_named_candidate = ib.kind == .named and ib.namespace_used_properties == null;
                    if (is_namespace or is_named_candidate) break :blk true;
                }
                break :blk false;
            };
            if (!has_candidate) continue;

            // importer 당 1회만 AST 순회해 NamespaceAccessIndex 구축.
            // 같은 모듈 안의 모든 namespace import 분석에 공유 (#1735).
            var ns_index = NamespaceAccessIndex.build(self.allocator, ast) catch continue;
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
                if (!is_namespace and !is_named_candidate) continue;
                if (ib.import_record_index >= importer.import_records.len) continue;
                const source_mod_idx = importer.import_records[ib.import_record_index].resolved;
                if (source_mod_idx.isNone()) continue;
                const source = self.graph.getModule(source_mod_idx) orelse continue;

                // `.named` 경로는 virtual namespace (re_export_namespace 타겟)일 때만 처리.
                // `.namespace`는 항상 대상 — collectNamespaceAccesses 결과를 scope-aware로 재평가.
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
                var access = analyzeNamespaceAccessWithIndex(
                    self.allocator,
                    ast,
                    sem.symbol_ids,
                    @intCast(sym_idx),
                    stmt_spans_opt,
                    &ns_index,
                ) catch continue;
                defer access.deinit(self.allocator);

                if (access.kind == .@"opaque") {
                    // `.namespace`는 text-based 결과를 신뢰하지 않음 — null로 덮어써 fallback.
                    // `.named` virtual ns는 null 유지(기존 동작).
                    if (is_namespace) {
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

    /// "default"는 JS 예약어 — 값 위치에 식별자로 사용 불가.
    /// codegen 합성 변수명(_default)의 canonical name으로 대체.
    fn safeIdentifierName(self: *const Linker, name: []const u8, module_index: u32) []const u8 {
        if (std.mem.eql(u8, name, "default")) {
            return self.getCanonicalName(module_index, "_default") orelse "_default";
        }
        return name;
    }

    /// ESM namespace import를 위한 namespace 객체 preamble 생성.
    /// namespace import/re-export에 대해 ns_member_rewrites + ns_inline_objects를 등록.
    /// buildMetadataForAst 내 3곳에서 동일 패턴을 공유. 캐시는 linker 전역
    /// (`self.ns_export_cache` / `self.ns_inline_cache`) — 같은 target 을 여러
    /// importer 가 namespace import 할 때 collectExportsRecursive DFS 를 단 한 번만 수행.
    ///
    /// `force_inline`: caller 가 isNamespaceUsedAsValue / exported_locals 등으로 결정한
    /// 강제 inline 신호. shadow 충돌은 함수 안에서 자체 감지하여 ns_inline_list 를 활성화.
    pub fn registerNamespaceRewrites(
        self: *const Linker,
        ns_rewrite_list: *std.ArrayList(LinkingMetadata.NsMemberRewrites.Entry),
        ns_inline_list: *std.ArrayList(LinkingMetadata.NsInlineObjects.Entry),
        /// 같은 importer 안에서 여러 namespace import 가 같은 target source 의 inline ns_var
        /// 를 공유하도록 caller 가 owned. `cjs_var_cache` 와 같은 패턴 (`metadata.zig`).
        ns_target_to_var: *std.AutoHashMap(u32, []const u8),
        force_inline: bool,
        importer_mod_idx: u32,
        symbol_id: u32,
        target_mod_idx: u32,
        var_name: []const u8,
    ) std.mem.Allocator.Error!void {
        var scope = profile.begin(.metadata_register_ns_rewrites);
        defer scope.end();

        const mutable_self = @constCast(self);

        // Fast path: lock 으로 캐시 조회. 히트 시 즉시 반환, 미스 시 lock 밖에서 DFS 수행 후
        // double-check 로 put. DFS 자체는 lock 밖 — 다른 스레드가 먼저 같은 target 을
        // 계산할 경우 중복 수행되지만 최종적으로 하나만 캐시에 남음 (두 번째는 폐기).
        mutable_self.ns_cache_mutex.lock();
        const cache_hit: ?[]NsExportPair = self.ns_export_cache.get(target_mod_idx);
        mutable_self.ns_cache_mutex.unlock();

        const cached_exports = if (cache_hit) |cached| cached else blk: {
            var exports: std.ArrayList(NsExportPair) = .empty;
            // 에러 시에만 정리 — 정상 경로에서는 캐시로 소유권 이동
            errdefer {
                for (exports.items) |exp| {
                    if (exp.owned) self.allocator.free(exp.local);
                }
                exports.deinit(self.allocator);
            }
            var seen = std.StringHashMap(void).init(self.allocator);
            defer seen.deinit();
            var visited = std.AutoHashMap(u32, void).init(self.allocator);
            defer visited.deinit();
            try self.collectExportsRecursive(&exports, &seen, &visited, @enumFromInt(target_mod_idx), 0);

            mutable_self.ns_cache_mutex.lock();
            defer mutable_self.ns_cache_mutex.unlock();
            // double-check: 다른 스레드가 먼저 put 했을 수 있음 — 내 계산 폐기
            if (self.ns_export_cache.get(target_mod_idx)) |raced| {
                for (exports.items) |exp| {
                    if (exp.owned) self.allocator.free(exp.local);
                }
                exports.deinit(self.allocator);
                break :blk raced;
            }
            const owned_slice = try self.allocator.dupe(NsExportPair, exports.items);
            exports.deinit(self.allocator);
            try mutable_self.ns_export_cache.put(self.allocator, target_mod_idx, owned_slice);
            break :blk owned_slice;
        };

        var seen_exports = std.StringHashMap(void).init(self.allocator);
        defer seen_exports.deinit();
        for (cached_exports) |exp| {
            try seen_exports.put(exp.exported, {});
        }

        // importer 의 nested binding 과 충돌하는 export 는 inline 시 self-shadow 무한
        // 재귀 위험 → 매핑 등록을 건너뛰고 has_shadow 로 추적.
        // (예: `const setSelectedLog = (i) => LogBoxData.setSelectedLog(i);` 가
        //  `const setSelectedLog = (i) => setSelectedLog(i);` 로 inline 되는 케이스)
        //
        // 또한 ns_target_mod 가 있는 export (re_export_namespace 등) 는 target_mod 별
        // hoisted ns_var 를 만들고 inner_map 매핑은 그 변수명으로 둔다 — emitStaticMember
        // 가 access site 마다 객체 literal 을 inline emit 하는 회귀 방지 (#1928).
        var inner_map = std.StringHashMap([]const u8).init(self.allocator);
        var has_shadow = false;
        for (cached_exports) |exp| {
            if (self.hasNestedBinding(importer_mod_idx, exp.exported)) {
                has_shadow = true;
                continue;
            }
            if (exp.ns_target_mod) |target| {
                const ns_var = if (ns_target_to_var.get(target)) |cached|
                    cached
                else blk: {
                    const fresh = try self.makeUniqueNsVarName(exp.exported, &seen_exports);
                    try ns_target_to_var.put(target, fresh);
                    const obj_str = try self.buildInlineObjectStr(target, 0);
                    try ns_inline_list.append(self.allocator, .{
                        .symbol_id = null,
                        .object_literal = obj_str,
                        .var_name = fresh,
                    });
                    break :blk fresh;
                };
                // inner_map 은 ns_inline_list.entry.var_name pointer 를 borrow — ns_inline
                // 이 owner. inner_map.deinit 은 backing 만 해제, value pointer 는 안 건드림 →
                // 같은 메모리 double-free 없음.
                try inner_map.put(exp.exported, ns_var);
                continue;
            }
            const local = if (exp.owned)
                try self.allocator.dupe(u8, exp.local)
            else
                exp.local;
            try inner_map.put(exp.exported, local);
        }
        try ns_rewrite_list.append(self.allocator, .{
            .symbol_id = symbol_id,
            .map = inner_map,
        });

        // ns_inline_list 활성화 조건: caller 가 명시 (force_inline) 또는 shadow 충돌 발생.
        // 후자의 경우 codegen fallback 이 namespace 객체 access 로 emit 할 수 있도록 객체가 필요.
        if (force_inline or has_shadow) {
            if (self.use_shared_ns_preamble) {
                const ns_var_name = try self.getOrCreateSharedNamespaceVar(target_mod_idx, &seen_exports);
                try ns_inline_list.append(self.allocator, .{
                    .symbol_id = symbol_id,
                    .object_literal = try self.allocator.dupe(u8, ""),
                    .var_name = try self.allocator.dupe(u8, ns_var_name),
                    .shared_target_mod_idx = target_mod_idx,
                });
            } else {
                const obj_str = try self.buildInlineObjectStr(target_mod_idx, 0);
                const ns_var_name = try self.makeUniqueNsVarName(var_name, &seen_exports);
                try ns_inline_list.append(self.allocator, .{
                    .symbol_id = symbol_id,
                    .object_literal = obj_str,
                    .var_name = ns_var_name,
                });
            }
        }
    }

    fn getOrCreateSharedNamespaceVar(
        self: *const Linker,
        target_mod_idx: u32,
        seen_exports: *std.StringHashMap(void),
    ) std.mem.Allocator.Error![]const u8 {
        const mutable_self = @constCast(self);

        mutable_self.ns_cache_mutex.lock();
        if (self.ns_shared_inline_cache.get(target_mod_idx)) |cached| {
            mutable_self.ns_cache_mutex.unlock();
            return cached.var_name;
        }
        mutable_self.ns_cache_mutex.unlock();

        const object_literal = try self.buildInlineObjectStr(target_mod_idx, 0);
        errdefer self.allocator.free(object_literal);
        const base_name = try self.makeSharedNamespaceBaseName(target_mod_idx);
        defer self.allocator.free(base_name);

        mutable_self.ns_cache_mutex.lock();
        defer mutable_self.ns_cache_mutex.unlock();

        if (self.ns_shared_inline_cache.get(target_mod_idx)) |raced| {
            self.allocator.free(object_literal);
            return raced.var_name;
        }

        const fresh = try mutable_self.makeUniqueSharedNsVarNameLocked(base_name, seen_exports);
        errdefer self.allocator.free(fresh);
        try mutable_self.ns_shared_inline_order.append(self.allocator, target_mod_idx);
        errdefer _ = mutable_self.ns_shared_inline_order.pop();
        try mutable_self.ns_shared_inline_cache.put(self.allocator, target_mod_idx, .{
            .var_name = fresh,
            .object_literal = object_literal,
        });
        try mutable_self.ns_shared_var_names.put(self.allocator, fresh, {});
        return fresh;
    }

    pub fn appendSharedNamespacePreamble(self: *const Linker, out: *std.ArrayList(u8)) std.mem.Allocator.Error!void {
        const sorted_targets = try self.allocator.dupe(u32, self.ns_shared_inline_order.items);
        defer self.allocator.free(sorted_targets);
        const SortCtx = struct {
            linker: *const Linker,
            fn lessThan(ctx: @This(), a: u32, b: u32) bool {
                const ap = if (ctx.linker.getModule(a)) |m| m.path else "";
                const bp = if (ctx.linker.getModule(b)) |m| m.path else "";
                const order = std.mem.order(u8, ap, bp);
                if (order != .eq) return order == .lt;
                return a < b;
            }
        };
        std.mem.sort(u32, sorted_targets, SortCtx{ .linker = self }, SortCtx.lessThan);

        for (sorted_targets) |target_mod_idx| {
            const entry = self.ns_shared_inline_cache.get(target_mod_idx) orelse continue;
            try out.appendSlice(self.allocator, "var ");
            try out.appendSlice(self.allocator, entry.var_name);
            try out.appendSlice(self.allocator, " = ");
            try out.appendSlice(self.allocator, entry.object_literal);
            try out.appendSlice(self.allocator, ";\n");
        }
    }

    pub fn restoreSharedNamespaceDecls(self: *const Linker, decls: []const CompiledModule.SharedNsDecl) std.mem.Allocator.Error!void {
        const mutable_self = @constCast(self);
        for (decls) |decl| {
            const target_idx = self.graph.path_to_module.get(decl.target_path) orelse continue;
            const target_mod_idx = @intFromEnum(target_idx);

            mutable_self.ns_cache_mutex.lock();
            if (self.ns_shared_inline_cache.get(target_mod_idx) != null) {
                mutable_self.ns_cache_mutex.unlock();
                continue;
            }
            mutable_self.ns_cache_mutex.unlock();

            const owned_var = try self.allocator.dupe(u8, decl.var_name);
            errdefer self.allocator.free(owned_var);
            const owned_obj = try self.allocator.dupe(u8, decl.object_literal);
            errdefer self.allocator.free(owned_obj);

            mutable_self.ns_cache_mutex.lock();
            defer mutable_self.ns_cache_mutex.unlock();
            if (self.ns_shared_inline_cache.get(target_mod_idx) != null) {
                self.allocator.free(owned_var);
                self.allocator.free(owned_obj);
                continue;
            }
            if (self.ns_shared_var_names.contains(owned_var)) {
                self.allocator.free(owned_var);
                self.allocator.free(owned_obj);
                continue;
            }
            try mutable_self.ns_shared_inline_order.append(self.allocator, target_mod_idx);
            errdefer _ = mutable_self.ns_shared_inline_order.pop();
            try mutable_self.ns_shared_inline_cache.put(self.allocator, target_mod_idx, .{
                .var_name = owned_var,
                .object_literal = owned_obj,
            });
            try mutable_self.ns_shared_var_names.put(self.allocator, owned_var, {});
        }
    }

    pub fn collectSharedNamespaceDecls(
        self: *const Linker,
        allocator: std.mem.Allocator,
        md: *const LinkingMetadata,
    ) std.mem.Allocator.Error![]const CompiledModule.SharedNsDecl {
        var decls: std.ArrayList(CompiledModule.SharedNsDecl) = .empty;
        errdefer {
            for (decls.items) |d| {
                allocator.free(d.target_path);
                allocator.free(d.var_name);
                allocator.free(d.object_literal);
            }
            decls.deinit(allocator);
        }

        var seen = std.AutoHashMap(u32, void).init(allocator);
        defer seen.deinit();

        for (md.ns_inline_objects.entries) |entry| {
            const target_mod_idx = entry.shared_target_mod_idx orelse continue;
            if (seen.contains(target_mod_idx)) continue;
            try seen.put(target_mod_idx, {});

            const target = self.getModule(target_mod_idx) orelse continue;
            @constCast(self).ns_cache_mutex.lock();
            const shared_copy = if (self.ns_shared_inline_cache.get(target_mod_idx)) |shared| SharedNsInline{
                .var_name = shared.var_name,
                .object_literal = shared.object_literal,
            } else null;
            @constCast(self).ns_cache_mutex.unlock();
            const shared = shared_copy orelse continue;

            const target_path = try allocator.dupe(u8, target.path);
            errdefer allocator.free(target_path);
            const var_name = try allocator.dupe(u8, shared.var_name);
            errdefer allocator.free(var_name);
            const object_literal = try allocator.dupe(u8, shared.object_literal);
            errdefer allocator.free(object_literal);

            try decls.append(allocator, .{
                .target_path = target_path,
                .var_name = var_name,
                .object_literal = object_literal,
            });
        }

        return decls.toOwnedSlice(allocator);
    }

    fn makeSharedNamespaceBaseName(self: *const Linker, target_mod_idx: u32) std.mem.Allocator.Error![]const u8 {
        const target = self.getModule(target_mod_idx) orelse return self.allocator.dupe(u8, "ns");
        const basename = std.fs.path.basename(target.path);
        const without_ext = if (std.mem.lastIndexOf(u8, basename, ".")) |dot| basename[0..dot] else basename;

        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(self.allocator);
        if (without_ext.len == 0 or !(std.ascii.isAlphabetic(without_ext[0]) or without_ext[0] == '_' or without_ext[0] == '$')) {
            try buf.append(self.allocator, '_');
        }
        for (without_ext) |c| {
            if (std.ascii.isAlphanumeric(c) or c == '_' or c == '$') {
                try buf.append(self.allocator, c);
            } else {
                try buf.append(self.allocator, '_');
            }
        }
        return buf.toOwnedSlice(self.allocator);
    }

    fn makeUniqueSharedNsVarNameLocked(
        self: *Linker,
        base: []const u8,
        seen_exports: *std.StringHashMap(void),
    ) std.mem.Allocator.Error![]const u8 {
        var candidate = try std.fmt.allocPrint(self.allocator, "{s}_ns", .{base});
        if (!seen_exports.contains(candidate) and !self.ns_shared_var_names.contains(candidate)) return candidate;

        var i: usize = 2;
        while (true) : (i += 1) {
            self.allocator.free(candidate);
            candidate = try std.fmt.allocPrint(self.allocator, "{s}_ns_{d}", .{ base, i });
            if (!seen_exports.contains(candidate) and !self.ns_shared_var_names.contains(candidate)) return candidate;
        }
    }

    /// namespace preamble 변수명을 export 이름과 충돌하지 않도록 생성.
    /// "z" → "z_ns", 충돌 시 "z_ns2", "z_ns3", ...
    fn makeUniqueNsVarName(self: *const Linker, base: []const u8, exports: *const std.StringHashMap(void)) std.mem.Allocator.Error![]const u8 {
        // 첫 시도: base_ns
        const first = try std.mem.concat(self.allocator, u8, &.{ base, "_ns" });
        if (!exports.contains(first)) return first;
        self.allocator.free(first);

        // 충돌 시 progressive suffix: base_ns2, base_ns3, ...
        // export 수가 유한하므로 반드시 종료
        var suffix: u32 = 2;
        while (true) : (suffix += 1) {
            var buf: [16]u8 = undefined;
            const num_str = std.fmt.bufPrint(&buf, "{d}", .{suffix}) catch unreachable;
            const candidate = try std.mem.concat(self.allocator, u8, &.{ base, "_ns", num_str });
            if (!exports.contains(candidate)) return candidate;
            self.allocator.free(candidate);
        }
    }

    /// 모듈의 모든 export를 인라인 객체 문자열로 생성 (재귀적).
    /// `export * as ns` export는 소스 모듈의 인라인 객체로 중첩.
    /// 결과는 `self.ns_inline_cache` 에 target_mod_idx 별로 캐싱 — linker 전역 공유.
    fn buildInlineObjectStr(
        self: *const Linker,
        target_mod_idx: u32,
        depth: u32,
    ) std.mem.Allocator.Error![]const u8 {
        if (depth > max_chain_depth) return try self.allocator.dupe(u8, "{}");
        const target_any = self.getModule(target_mod_idx) orelse
            return try self.allocator.dupe(u8, "{}");

        const mutable_self = @constCast(self);

        // 캐시 히트: 복사본 반환 (호출자가 소유권을 가짐)
        mutable_self.ns_cache_mutex.lock();
        const cache_hit = self.ns_inline_cache.get(target_mod_idx);
        mutable_self.ns_cache_mutex.unlock();
        if (cache_hit) |cached_str| {
            return try self.allocator.dupe(u8, cached_str);
        }

        var exports: std.ArrayList(NsExportPair) = .empty;
        defer {
            for (exports.items) |exp| {
                if (exp.owned) self.allocator.free(exp.local);
            }
            exports.deinit(self.allocator);
        }
        var seen = std.StringHashMap(void).init(self.allocator);
        defer seen.deinit();
        var visited = std.AutoHashMap(u32, void).init(self.allocator);
        defer visited.deinit();
        try self.collectExportsRecursive(&exports, &seen, &visited, @enumFromInt(target_mod_idx), 0);

        // export * as ns 패턴 수집 (별도 처리 — 재귀 인라인 필요)
        const target = target_any;
        var ns_re_exports = std.StringHashMap(u32).init(self.allocator); // exported_name → source_mod
        defer ns_re_exports.deinit();
        for (target.export_bindings) |eb| {
            if (eb.kind == .re_export_namespace) {
                if (eb.import_record_index) |rec_idx| {
                    if (rec_idx < target.import_records.len) {
                        const src = target.import_records[rec_idx].resolved;
                        if (!src.isNone()) {
                            try ns_re_exports.put(eb.exported_name, @intFromEnum(src));
                        }
                    }
                }
            }
        }

        // getter 객체 생성 (Rolldown 호환): { get prop() { return local; } }
        // 값 복사 대신 getter를 사용하여 live binding을 보존한다.
        // circular dep에서 init 시점에 아직 undefined인 변수도 사용 시점에 올바르게 참조.
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.allocator);
        try buf.appendSlice(self.allocator, "{");
        for (exports.items, 0..) |exp, idx| {
            if (idx > 0) try buf.appendSlice(self.allocator, ", ");
            const needs_quote = needsPropertyQuoteForExport(exp.exported);
            // export * as ns 패턴이면 재귀 인라인 (값으로 참조)
            if (ns_re_exports.get(exp.exported)) |src_mod| {
                if (needs_quote) {
                    try buf.appendSlice(self.allocator, "\"");
                    try buf.appendSlice(self.allocator, exp.exported);
                    try buf.appendSlice(self.allocator, "\": ");
                } else {
                    try buf.appendSlice(self.allocator, exp.exported);
                    try buf.appendSlice(self.allocator, ": ");
                }
                const nested = try self.buildInlineObjectStr(src_mod, depth + 1);
                defer self.allocator.free(nested);
                try buf.appendSlice(self.allocator, nested);
            } else {
                // getter: get prop() { return local; }
                try buf.appendSlice(self.allocator, "get ");
                if (needs_quote) {
                    try buf.appendSlice(self.allocator, "\"");
                    try buf.appendSlice(self.allocator, exp.exported);
                    try buf.appendSlice(self.allocator, "\"");
                } else {
                    try buf.appendSlice(self.allocator, exp.exported);
                }
                try buf.appendSlice(self.allocator, "() { return ");
                try buf.appendSlice(self.allocator, exp.local);
                try buf.appendSlice(self.allocator, "; }");
            }
        }
        try buf.appendSlice(self.allocator, "}");
        const result = try self.allocator.dupe(u8, buf.items);

        // double-check 후 put. race 로 다른 스레드가 이미 put 했으면 내 result 폐기.
        mutable_self.ns_cache_mutex.lock();
        defer mutable_self.ns_cache_mutex.unlock();
        if (self.ns_inline_cache.get(target_mod_idx)) |raced| {
            self.allocator.free(result);
            return try self.allocator.dupe(u8, raced);
        }
        try mutable_self.ns_inline_cache.put(self.allocator, target_mod_idx, result);
        return try self.allocator.dupe(u8, result);
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
    fn collectExportsRecursive(
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
            const actual_local = if (eb.kind == .re_export_namespace) blk: {
                ns_target_mod = resolvedRecordModule(m.import_records, eb.import_record_index);
                break :blk eb_local;
            } else if (eb.kind == .re_export) blk: {
                if (self.resolveExportChain(module_idx, eb.exported_name, 0)) |canonical| {
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
                    if (ns_target_mod == null) break :blk self.resolveToLocalName(canonical);
                    break :blk eb_local;
                }
                break :blk eb_local;
            } else blk: {
                ns_target_mod = resolvedRecordModule(m.import_records, ns_imports.get(eb_local));
                if (ns_target_mod == null) break :blk self.getCanonicalByRef(eb.symbol) orelse eb_local;
                break :blk eb_local;
            };

            const safe_local = self.safeIdentifierName(actual_local, @intCast(mod_i));

            try exports.append(self.allocator, .{
                .exported = eb.exported_name,
                .local = safe_local,
                .owned = false,
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

// ============================================================
// PreambleWriter — CJS/dev preamble 생성용 구조체
// ============================================================

pub const PreambleWriter = struct {
    buf: std.ArrayList(u8) = .empty,
    allocator: std.mem.Allocator,
    /// #1621: minify 시 preamble 내부 runtime helper 호출을 축약 이름으로 emit.
    /// Linker.minify_whitespace 와 동일 값. dev 경로에서는 무관 (별도 writer).
    minify: bool = false,

    pub fn init(allocator: std.mem.Allocator) PreambleWriter {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *PreambleWriter) void {
        self.buf.deinit(self.allocator);
    }

    pub fn isEmpty(self: *const PreambleWriter) bool {
        return self.buf.items.len == 0;
    }

    /// 버퍼 내용을 allocator로 복제하여 반환. 비어있으면 null.
    pub fn toOwned(self: *const PreambleWriter) !?[]const u8 {
        if (self.isEmpty()) return null;
        return try self.allocator.dupe(u8, self.buf.items);
    }

    /// 버퍼 내용을 다른 슬라이스와 concat하여 반환. 비어있으면 other를 그대로 반환.
    pub fn concatWith(self: *const PreambleWriter, other: ?[]const u8) !?[]const u8 {
        if (self.isEmpty()) return other;
        const combined = try std.mem.concat(self.allocator, u8, &.{
            other orelse "",
            self.buf.items,
        });
        if (other) |p| self.allocator.free(p);
        return combined;
    }

    pub inline fn write(self: *PreambleWriter, s: []const u8) !void {
        try self.buf.appendSlice(self.allocator, s);
    }

    pub fn writeUnresolvedRequire(
        self: *PreambleWriter,
        local_name: []const u8,
        specifier: []const u8,
        imported_name: []const u8,
        is_namespace: bool,
    ) !void {
        return self.writeUnresolvedRequireInner(local_name, specifier, imported_name, is_namespace, false);
    }

    /// ESM-wrapped 모듈의 synthetic JSX binding 등에서 사용.
    /// top-level에 이미 `var _jsxDEV, _Fragment;` 선언이 있으므로 init 함수 본문에서는
    /// `var` 없이 할당만 해야 함 (var 재선언 시 outer scope shadowing → #1209).
    pub fn writeUnresolvedRequireAssignOnly(
        self: *PreambleWriter,
        local_name: []const u8,
        specifier: []const u8,
        imported_name: []const u8,
        is_namespace: bool,
    ) !void {
        return self.writeUnresolvedRequireInner(local_name, specifier, imported_name, is_namespace, true);
    }

    fn writeUnresolvedRequireInner(
        self: *PreambleWriter,
        local_name: []const u8,
        specifier: []const u8,
        imported_name: []const u8,
        is_namespace: bool,
        assign_only: bool,
    ) !void {
        if (!assign_only) try self.write("var ");
        try self.write(local_name);
        try self.write(" = require(\"");
        try self.write(specifier);
        try self.write("\")");
        // named import만 .property 접근 추가 (namespace/default는 모듈 전체)
        if (!is_namespace and !std.mem.eql(u8, imported_name, "default")) {
            try self.write(".");
            try self.write(imported_name);
        }
        try self.write(";\n");
    }

    pub fn writeCjsImport(
        self: *PreambleWriter,
        local_name: []const u8,
        imported_name: []const u8,
        req_var: []const u8,
        is_namespace: bool,
        interop: types.Interop,
    ) !void {
        try self.writeCjsImportInner(local_name, imported_name, req_var, is_namespace, interop, false);
    }

    pub fn writeCjsImportAssignOnly(
        self: *PreambleWriter,
        local_name: []const u8,
        imported_name: []const u8,
        req_var: []const u8,
        is_namespace: bool,
        interop: types.Interop,
    ) !void {
        try self.writeCjsImportInner(local_name, imported_name, req_var, is_namespace, interop, true);
    }

    pub fn writeCjsImportInner(
        self: *PreambleWriter,
        local_name: []const u8,
        imported_name: []const u8,
        req_var: []const u8,
        is_namespace: bool,
        interop: types.Interop,
        assign_only: bool,
    ) !void {
        if (!assign_only) try self.write("var ");
        try self.write(local_name);
        // Rolldown Interop: node → __toESM(req(), 1), babel → __toESM(req())
        // #1621: minify 시 __toESM → $tE 축약.
        const toesm_name: []const u8 = if (self.minify) rt.NAMES.TOESM_MIN else "__toESM";
        const toesm_suffix: []const u8 = if (interop == .node) "(), 1)" else "())";
        if (is_namespace) {
            try self.write(" = ");
            try self.write(toesm_name);
            try self.write("(");
            try self.write(req_var);
            try self.write(toesm_suffix);
            try self.write(";\n");
        } else if (std.mem.eql(u8, imported_name, "default")) {
            try self.write(" = ");
            try self.write(toesm_name);
            try self.write("(");
            try self.write(req_var);
            try self.write(toesm_suffix);
            try self.write(".default;\n");
        } else {
            try self.write(" = ");
            try self.write(req_var);
            try self.write("().");
            try self.write(imported_name);
            try self.write(";\n");
        }
    }

    pub fn writeDevRequire(self: *PreambleWriter, local_name: []const u8, path: []const u8, suffix: ?[]const u8) !void {
        return self.writeDevRequireInterop(local_name, path, suffix, false, false);
    }

    /// CJS interop 포함: [var ]x = [__toESM(]__zts_require("path")[)][.default];
    /// assign_only=true 일 때 var 키워드 생략 (namespace 패턴에서 호이스팅된 변수에 할당만).
    pub fn writeDevRequireInterop(self: *PreambleWriter, local_name: []const u8, path: []const u8, suffix: ?[]const u8, to_esm: bool, assign_only: bool) !void {
        if (!assign_only) try self.write("var ");
        try self.write(local_name);
        try self.write(" = ");
        if (to_esm) try self.write("__toESM(");
        try self.write("__zts_require(\"");
        try self.write(path);
        try self.write("\")");
        if (to_esm) try self.write(")");
        if (suffix) |s| try self.write(s);
        try self.write(";\n");
    }

    pub const NamePair = struct { local: []const u8, imported: []const u8 };

    pub fn writeDevRequireNamed(
        self: *PreambleWriter,
        named_bindings: []const NamePair,
        path: []const u8,
    ) !void {
        try self.write("var { ");
        for (named_bindings, 0..) |nb, i| {
            if (i > 0) try self.write(", ");
            if (!std.mem.eql(u8, nb.imported, nb.local)) {
                try self.write(nb.imported);
                try self.write(": ");
                try self.write(nb.local);
            } else {
                try self.write(nb.local);
            }
        }
        try self.write(" } = __zts_require(\"");
        try self.write(path);
        try self.write("\");\n");
    }

    pub fn writeNamespaceObject(self: *PreambleWriter, var_name: []const u8, object_literal: []const u8) !void {
        try self.write("var ");
        try self.write(var_name);
        try self.write(" = ");
        try self.write(object_literal);
        try self.write(";\n");
    }
};

/// CJS 모듈의 require_xxx 변수명을 캐시에서 가져오거나 새로 생성.
pub fn getOrCreateRequireVar(
    self: *const Linker,
    cache: *std.AutoHashMap(u32, []const u8),
    mod_idx: u32,
) ![]const u8 {
    if (cache.get(mod_idx)) |cached| return cached;
    const target_path = self.getModule(mod_idx).?.path;
    const name = try types.makeRequireVarName(self.allocator, target_path);
    try cache.put(mod_idx, name);
    return name;
}

/// JS 예약어인 export 이름은 프로퍼티 키에 따옴표 필요.
fn needsPropertyQuoteForExport(name: []const u8) bool {
    if (name.len == 0) return true;
    const reserved = [_][]const u8{
        "default", "class",      "function", "var",    "let",    "const",
        "if",      "else",       "for",      "while",  "do",     "switch",
        "case",    "break",      "continue", "return", "throw",  "try",
        "catch",   "finally",    "new",      "delete", "typeof", "void",
        "in",      "instanceof", "this",     "with",   "yield",  "await",
        "import",  "export",     "extends",  "super",  "enum",
    };
    for (reserved) |kw| {
        if (std.mem.eql(u8, name, kw)) return true;
    }
    if (name[0] >= '0' and name[0] <= '9') return true;
    if (name[0] != '_' and name[0] != '$' and !(name[0] >= 'a' and name[0] <= 'z') and !(name[0] >= 'A' and name[0] <= 'Z')) return true;
    return false;
}
