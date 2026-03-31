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
const Symbol = @import("../semantic/symbol.zig").Symbol;
const RefScopePair = @import("../semantic/symbol.zig").RefScopePair;
const Scope = @import("../semantic/scope.zig").Scope;
const binding_scanner = @import("binding_scanner.zig");
pub const ImportBinding = binding_scanner.ImportBinding;
pub const ExportBinding = binding_scanner.ExportBinding;

/// Semantic analyzer 결과. parse_arena가 소유하는 데이터의 참조.
/// linker가 import→export 연결 + 이름 충돌 해결에 사용.
pub const ModuleSemanticData = struct {
    symbols: []const Symbol,
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
    /// mangler용 참조 scope 페어. liveness BitSet 계산에 사용.
    ref_scope_pairs: []const RefScopePair = &.{},
};

pub const Module = struct {
    index: ModuleIndex,
    /// 절대 파일 경로. graph의 path_to_module 키와 동일한 메모리를 참조 (빌림).
    path: []const u8,
    /// 소스 코드. parse_arena에서 할당 (Module.arena가 소유).
    source: []const u8,
    /// 파싱된 AST. parse_arena에서 할당 (Module.arena가 소유).
    ast: ?Ast,
    /// import_scanner가 추출한 레코드. graph allocator에서 할당 (소스 텍스트를 참조).
    import_records: []ImportRecord,
    /// 모듈별 Arena — Scanner/Parser/AST/Semantic 메모리를 소유. graph.deinit에서 해제.
    parse_arena: ?std.heap.ArenaAllocator,
    /// semantic analyzer 결과. parse_arena가 소유. linker에서 사용.
    semantic: ?ModuleSemanticData,
    /// Scanner의 line offset 테이블. parse_arena가 소유. 소스맵 생성에 사용.
    /// line_offsets[i] = i번째 줄의 시작 byte offset.
    line_offsets: []const u32 = &.{},
    /// legal comment 텍스트 목록 (parse_arena 소유). eof/linked/external 모드에서 사용.
    legal_comments: []const []const u8 = &.{},
    /// import 바인딩 상세. graph allocator 소유 (소스 텍스트 참조).
    import_bindings: []ImportBinding = &.{},
    /// export 바인딩 상세. graph allocator 소유 (소스 텍스트 참조).
    export_bindings: []ExportBinding = &.{},

    /// 내가 import하는 모듈들 (순방향)
    dependencies: std.ArrayList(ModuleIndex),
    /// 나를 import하는 모듈들 (역방향, D078 HMR용)
    importers: std.ArrayList(ModuleIndex),
    /// 동적 import (별도 관리, code splitting용)
    dynamic_imports: std.ArrayList(ModuleIndex),

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
    /// platform=browser에서 Node 빌트인 모듈을 빈 CJS로 대체 (esbuild "(disabled)" 방식).
    /// AST가 없고, emitter가 빈 __commonJS wrapper를 출력한다.
    is_disabled: bool = false,
    /// JSON 모듈이 CJS require()로 참조되는지 여부.
    /// true면 ESM 포맷에서도 __commonJS 래핑 필요 (linker가 require_X() 이름 생성).
    /// false면 ESM에서 scope-hoisted var로 출력 가능.
    has_cjs_importer: bool = false,
    /// package.json "module" 필드를 통해 resolve된 파일.
    /// .js 확장자라도 ESM으로 파싱해야 함.
    is_module_field: bool = false,
    /// DFS 후위 순서 = ESM 실행 순서 (D058, D076).
    /// maxInt = 미방문 (DFS에서 할당되지 않음).
    exec_index: u32,
    /// 순환 참조 그룹 ID. 0 = 순환 없음 (D065)
    cycle_group: u32,
    state: State,
    /// file/copy 로더의 asset 출력 정보. null이면 asset이 아님.
    asset_data: ?AssetData = null,

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

    /// CJS importee에 대한 interop 모드 결정 (Rolldown 방식).
    /// importer(self)가 ESM 정의 형식이면 Node 모드, 아니면 Babel 모드.
    pub fn interop(self: *const Module, importee: *const Module) ?types.Interop {
        if (importee.exports_kind != .commonjs) return null;
        return if (self.def_format.isEsm()) .node else .babel;
    }

    /// exec_index 기준 오름차순 comparator.
    pub fn execIndexLessThan(_: void, a: *const Module, b: *const Module) bool {
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
            .module_type = .unknown,
            .side_effects = true,
            .exec_index = std.math.maxInt(u32),
            .cycle_group = 0,
            .state = .reserved,
        };
    }

    /// 양방향 의존성 추가 (D078).
    /// self → dep 순방향 + dep → self 역방향을 동시에 업데이트.
    pub fn addDependency(
        self: *Module,
        allocator: std.mem.Allocator,
        dep_index: ModuleIndex,
        all_modules: []Module,
    ) !void {
        if (dep_index.isNone()) return;
        const idx = @intFromEnum(dep_index);
        if (idx >= all_modules.len) return;

        try self.dependencies.append(allocator, dep_index);
        var dep = &all_modules[idx];
        try dep.importers.append(allocator, self.index);
    }

    /// 동적 import 추가.
    pub fn addDynamicImport(
        self: *Module,
        allocator: std.mem.Allocator,
        dep_index: ModuleIndex,
    ) !void {
        try self.dynamic_imports.append(allocator, dep_index);
    }

    pub fn deinit(self: *Module, allocator: std.mem.Allocator) void {
        self.dependencies.deinit(allocator);
        self.importers.deinit(allocator);
        self.dynamic_imports.deinit(allocator);
        // parse_arena가 Scanner/Parser/AST/source 메모리를 전부 소유.
        // ast.deinit()는 불필요 — arena.deinit()이 일괄 해제.
        if (self.parse_arena) |*arena| arena.deinit();
    }
};
