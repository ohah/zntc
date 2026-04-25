//! ZTS Bundler — Module
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
    scope_maps: []const std.StringHashMap(usize),
    /// export된 이름 목록. exported_names.get("x") → Span.
    exported_names: std.StringHashMap(Span),
    /// 노드 인덱스 → 심볼 인덱스 매핑. 식별자 노드만 유효값.
    symbol_ids: []const ?u32,
    /// 미해결 참조 (unresolved references). 스코프 체인에서 선언을 찾지 못한 이름.
    /// 번들러 linker가 scope hoisting 시 이 이름들을 예약하여 shadowing 방지.
    unresolved_references: std.StringHashMap(void),
    /// per-reference 배열. 현재 consumer: mangler liveness.
    references: []const Reference = &.{},

    /// 심볼 id에 해당하는 이름을 반환. `Symbol.nameText` 래퍼.
    pub fn symbolName(self: *const ModuleSemanticData, id: u32, source: []const u8) []const u8 {
        if (id >= self.symbols.items.len) return "";
        return self.symbols.items[id].nameText(source);
    }
};

pub const Module = struct {
    index: ModuleIndex,
    /// 절대 파일 경로. graph의 path_to_module 키와 동일한 메모리를 참조 (빌림).
    path: []const u8,
    /// dev mode 모듈 ID. bundler에서 한 번 계산 (path의 서브슬라이스, 할당 없음).
    dev_id: []const u8 = "",
    /// 소스 코드. parse_arena에서 할당 (Module.arena가 소유).
    source: []const u8,
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
    /// 이 모듈이 다른 모듈의 require.context match 로 등록된 경우 true. tree-shaker 가
    /// static import 없어도 root 취급해 번들에서 제거 안 함 — runtime require 대상이므로
    /// 모든 export 가 사용 가능해야.
    is_context_dep: bool = false,
    /// 모듈별 Arena — Scanner/Parser/AST/Semantic 메모리를 소유. graph.deinit에서 해제.
    parse_arena: ?std.heap.ArenaAllocator,
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
    /// Bundler-local 합성 심볼 테이블 (cross-module linking용). #1328 Phase 1.
    /// graph allocator 소유. null = 미초기화 (asset/disabled 모듈 등).
    alias_table: ?AliasTable = null,

    /// wrap_kind != .none 모듈의 `init_<path>` 함수 심볼 id (semantic 공간).
    /// null = 미래핑 또는 semantic 없음 (fallback: makeInitVarName 재할당).
    init_symbol: ?SemanticSymbolId = null,
    /// wrap_kind != .none 모듈의 `exports_<path>` 객체 심볼 id.
    exports_symbol: ?SemanticSymbolId = null,

    /// 내가 import하는 모듈들 (순방향)
    dependencies: std.ArrayList(ModuleIndex),
    /// 나를 import하는 모듈들 (역방향, D078 HMR용)
    importers: std.ArrayList(ModuleIndex),
    /// 동적 import (별도 관리, code splitting용)
    dynamic_imports: std.ArrayList(ModuleIndex),
    /// 나를 dynamic import 하는 모듈들 (역방향). `ModuleGraph.linkDynamicImport` 가 채움.
    dynamic_importers: std.ArrayList(ModuleIndex),

    module_type: ModuleType,
    /// 모듈의 로딩 방식 (file/dataurl/text/binary/copy 등).
    /// addModule에서 확장자 또는 --loader 옵션으로 결정.
    loader: types.Loader = .none,
    /// 모듈의 export 방식 (CJS/ESM 판별)
    exports_kind: types.ExportsKind = .none,
    /// 모듈 래핑 방식 (CJS → __commonJS 팩토리 함수)
    wrap_kind: types.WrapKind = .none,
    /// 모듈 정의 형식 (확장자/package.json 기반, Rolldown ModuleDefFormat)
    def_format: types.ModuleDefFormat = .unknown,
    /// Top-Level Await 사용 여부. TLA 모듈을 static import하는 모듈도 전이적으로 true.
    uses_top_level_await: bool = false,
    side_effects: bool,
    /// side_effects가 package.json `sideEffects` 필드에 의해 결정됐음을 표시.
    /// true면 tree-shaker의 auto-purity 분석이 이 값을 덮어쓸 수 없다.
    /// Rolldown `DeterminedSideEffects::UserDefined` 포팅.
    side_effects_user_defined: bool = false,
    /// platform=browser에서 Node 빌트인 모듈을 빈 CJS로 대체 (esbuild "(disabled)" 방식).
    /// AST가 없고, emitter가 빈 __commonJS wrapper를 출력한다.
    is_disabled: bool = false,
    /// `external` 패턴 매칭으로 번들에 포함되지 않는 모듈. graph 에는 phantom 으로 등록되어
    /// `meta.getModuleInfo` / `info.importedIds` 등 graph traversal API 의 1급 노드로 보이지만
    /// chunk 배정 / emit / tree-shake 에선 제외. AST 없음, source 없음, path = original specifier.
    is_external: bool = false,
    /// tree-shake 결과 — 번들에 포함된 모듈인지 (Rollup `info.isIncluded` 호환).
    /// `TreeShaker.analyze` 가 finalize 후 set. 기본 false 라 tree-shaking 비활성 시
    /// 의미 없음 — chunk gen 단계에서도 `m.side_effects or entry_set.isSet` 으로 항상 alive 처리.
    is_included: bool = false,
    /// package.json "module" 필드를 통해 resolve된 파일.
    /// .js 확장자라도 ESM으로 파싱해야 함.
    is_module_field: bool = false,
    /// 엔트리 포인트 여부. graph.build()에서 설정.
    /// esbuild의 entryPointKind과 동일 — 정렬 순서나 exec_index와 무관하게
    /// 엔트리를 100% 정확히 식별한다.
    is_entry_point: bool = false,
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

    /// 등록된 합성 심볼의 이름(synthetic_name)을 반환. 미등록이면 null.
    /// 반환 slice는 parse_arena가 소유 — 모듈 수명 내 유효.
    fn syntheticName(self: *const Module, maybe_id: ?SemanticSymbolId) ?[]const u8 {
        const id = maybe_id orelse return null;
        const sem = self.semantic orelse return null;
        const idx: u32 = @intFromEnum(id);
        if (idx >= sem.symbols.items.len) return null;
        const name = sem.symbols.items[idx].synthetic_name;
        return if (name.len > 0) name else null;
    }

    pub fn getInitName(self: *const Module) ?[]const u8 {
        return self.syntheticName(self.init_symbol);
    }

    /// `entry_error_guard` 활성 시 이 모듈의 init 호출을 `__zts_guarded(...)` 로 wrap 할지 결정.
    /// TLA (`uses_top_level_await`) 인 ESM 모듈은 await 가 lambda 안에 못 들어가므로 wrap 안 함.
    /// `wrap_kind == .none` (래핑 없음) 도 호출할 init 함수 자체가 없어 wrap 무의미.
    pub fn shouldGuard(self: *const Module, error_guard: bool) bool {
        if (!error_guard) return false;
        if (!self.wrap_kind.isWrapped()) return false;
        if (self.wrap_kind == .esm and self.uses_top_level_await) return false;
        return true;
    }

    pub fn getExportsName(self: *const Module) ?[]const u8 {
        return self.syntheticName(self.exports_symbol);
    }

    /// `getInitName()`의 할당 버전 — 등록된 경우 dupe, 아니면 fresh 생성.
    /// 기존 `types.makeInitVarName(alloc, path)` 호출지의 drop-in 대체.
    pub fn allocInitName(self: *const Module, allocator: std.mem.Allocator) ![]const u8 {
        if (self.getInitName()) |n| return allocator.dupe(u8, n);
        return types.makeInitVarName(allocator, self.path);
    }

    pub fn allocExportsName(self: *const Module, allocator: std.mem.Allocator) ![]const u8 {
        if (self.getExportsName()) |n| return allocator.dupe(u8, n);
        return types.makeExportsVarName(allocator, self.path);
    }

    /// Semantic 심볼 배열 slice. semantic이 없으면 빈 slice.
    /// `hasSyntheticDefault` 등 semantic-aware predicate 호출 시 편의.
    pub fn semanticSymbols(self: *const Module) []const Symbol {
        const sem = self.semantic orelse return &.{};
        return sem.symbols.items;
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
        return sem.symbols.items[idx].nameText(self.source);
    }

    /// SymbolRef가 semantic을 가리키면 Symbol.nameText, 아니면 null.
    fn refName(self: *const Module, ref: symbol_mod.SymbolRef) ?[]const u8 {
        const idx = ref.semanticIndex() orelse return null;
        const sem = self.semantic orelse return null;
        if (idx >= sem.symbols.items.len) return null;
        return sem.symbols.items[idx].nameText(self.source);
    }

    /// ImportBinding의 현재 모듈 로컬 이름. local_symbol에서 derive 가능하면
    /// Symbol.nameText, 아니면 ib.local_name 필드 fallback.
    pub fn importBindingLocalName(self: *const Module, ib: ImportBinding) []const u8 {
        return self.refName(ib.local_symbol) orelse ib.local_name;
    }

    /// ExportBinding의 로컬 이름. `.local` + semantic ref면 Symbol.nameText에서
    /// derive, 그 외엔 eb.local_name 필드 그대로 반환.
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

    /// CJS importee에 대한 interop 모드 결정 (Rolldown 방식).
    /// importer(self)가 ESM 정의 형식이면 Node 모드, 아니면 Babel 모드.
    pub fn interop(self: *const Module, importee: *const Module) ?types.Interop {
        if (importee.exports_kind != .commonjs) return null;
        return if (self.def_format.isEsm()) .node else .babel;
    }

    /// 번들 출력 순서 comparator.
    /// 래핑된 모듈(__esm/__commonJS)을 scope-hoisted 모듈보다 먼저 배치.
    /// var init_xxx = __esm(...) 선언이 init_xxx() 호출보다 앞에 와야 하므로,
    /// 같은 그룹 내에서는 exec_index 오름차순.
    pub fn bundleOrderLessThan(_: void, a: *const Module, b: *const Module) bool {
        const a_wrapped = a.wrap_kind != .none;
        const b_wrapped = b.wrap_kind != .none;
        if (a_wrapped != b_wrapped) return a_wrapped;
        return a.exec_index < b.exec_index;
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

    pub fn deinit(self: *Module, allocator: std.mem.Allocator) void {
        self.dependencies.deinit(allocator);
        self.importers.deinit(allocator);
        self.dynamic_imports.deinit(allocator);
        self.dynamic_importers.deinit(allocator);
        if (self.alias_table) |*t| t.deinit();
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
        if (self.parse_arena) |*arena| arena.deinit();
    }

    /// Lazy 초기화. graph allocator로 합성 심볼 테이블을 만든다.
    /// 이미 있으면 no-op.
    pub fn ensureAliasTable(self: *Module, allocator: std.mem.Allocator) void {
        if (self.alias_table == null) {
            self.alias_table = AliasTable.init(allocator);
        }
    }
};
