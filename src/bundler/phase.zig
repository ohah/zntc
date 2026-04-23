//! ZTS Bundler — Module mutation phase 강제 (#1779)
//!
//! Worker thread race-safety 를 type 시스템으로 강제하기 위한 accessor 계층.
//! ModuleGraph 가 phase 별 accessor 를 발급하고, 각 accessor 는 자기 phase 가
//! mutate 권한을 가진 field 의 setter 만 노출한다. 다른 phase 의 setter 호출은
//! 컴파일 타임에 차단된다.
//!
//! ### Phase 정의
//! - **init**: addModule 시점 (Module.init 한 번만)
//! - **parse**: 파일 읽기 + AST/semantic 구축. worker thread 에서 자기 module 만 write
//! - **resolve**: import specifier → module index 매칭. main thread
//! - **link**: DFS exec_index/cycle_group 할당. main thread, single-pass
//! - **emit**: 코드 생성 단계. read-only
//!
//! ### Multi-phase field 정책 (Phase 분류표 참조)
//! 5개 field 가 parse + resolve 양쪽에서 mutate 됨:
//! - `import_records` — parse 가 slice 확정, resolve 는 records[i].resolved 만 변경
//! - `exports_kind`, `wrap_kind` — parse 가 초기값, resolve 는 promote 만 (#1c 에서 정책 강제)
//! - `side_effects` — parse 가 default, resolve 가 package.json 정책 적용
//! - `uses_top_level_await` — parse 가 자기 모듈의 await 감지, resolve 가 transitive 전파
//!
//! 본 PR (#1a) 은 뼈대만. multi-phase 정책 강제는 #1c 에서.

const std = @import("std");
const types = @import("types.zig");
const ModuleIndex = types.ModuleIndex;
const ImportRecord = types.ImportRecord;
const ExportsKind = types.ExportsKind;
const WrapKind = types.WrapKind;
const ModuleDefFormat = types.ModuleDefFormat;
const Loader = types.Loader;

const module_mod = @import("module.zig");
const Module = module_mod.Module;
const ModuleSemanticData = module_mod.ModuleSemanticData;
const ImportBinding = module_mod.ImportBinding;
const ExportBinding = module_mod.ExportBinding;
const Ast = @import("../parser/ast.zig").Ast;
const stmt_info_mod = @import("stmt_info.zig");

const graph_mod = @import("graph.zig");
const ModuleGraph = graph_mod.ModuleGraph;

/// Module 의 mutation 권한이 부여되는 pipeline phase.
/// 디버깅/테스트 용 enum — 실제 강제는 ParseAccessor / ResolveAccessor / LinkAccessor
/// 의 method 분리로 이루어진다.
pub const ModulePhase = enum {
    init,
    parse,
    resolve,
    link,
    emit,
};

// ============================================================
// ParseAccessor
// ============================================================

/// Parse phase mutation accessor. parser/scanner worker 가 자기 module 의
/// AST/semantic/source/import_records 등 parse 결과를 write.
///
/// **Worker thread 사용 규약**: 이 accessor 를 받은 worker 는 인자로 받은
/// `module_idx` 의 module 만 mutate. 다른 module 은 read 도 금지 (graph
/// 전체를 보는 책임은 main thread).
pub const ParseAccessor = struct {
    graph: *ModuleGraph,

    pub inline fn read(self: ParseAccessor, idx: ModuleIndex) ?*const Module {
        return self.graph.getModule(idx);
    }

    // ---- 단일-phase parse field setter ----

    pub inline fn setSource(self: ParseAccessor, idx: ModuleIndex, source: []const u8) void {
        if (self.graph.moduleAtMut(idx)) |m| m.source = source;
    }

    pub inline fn setAst(self: ParseAccessor, idx: ModuleIndex, ast: ?Ast) void {
        if (self.graph.moduleAtMut(idx)) |m| m.ast = ast;
    }

    pub inline fn setSemantic(self: ParseAccessor, idx: ModuleIndex, semantic: ?ModuleSemanticData) void {
        if (self.graph.moduleAtMut(idx)) |m| m.semantic = semantic;
    }

    pub inline fn setParseArena(self: ParseAccessor, idx: ModuleIndex, arena: ?std.heap.ArenaAllocator) void {
        if (self.graph.moduleAtMut(idx)) |m| m.parse_arena = arena;
    }

    pub inline fn setImportBindings(self: ParseAccessor, idx: ModuleIndex, bindings: []ImportBinding) void {
        if (self.graph.moduleAtMut(idx)) |m| m.import_bindings = bindings;
    }

    pub inline fn setExportBindings(self: ParseAccessor, idx: ModuleIndex, bindings: []ExportBinding) void {
        if (self.graph.moduleAtMut(idx)) |m| m.export_bindings = bindings;
    }

    pub inline fn setLineOffsets(self: ParseAccessor, idx: ModuleIndex, offsets: []const u32) void {
        if (self.graph.moduleAtMut(idx)) |m| m.line_offsets = offsets;
    }

    pub inline fn setLegalComments(self: ParseAccessor, idx: ModuleIndex, comments: []const []const u8) void {
        if (self.graph.moduleAtMut(idx)) |m| m.legal_comments = comments;
    }

    pub inline fn setPrebuiltStmtInfo(self: ParseAccessor, idx: ModuleIndex, info: ?stmt_info_mod.ModuleStmtInfos) void {
        if (self.graph.moduleAtMut(idx)) |m| m.prebuilt_stmt_info = info;
    }

    pub inline fn setMtime(self: ParseAccessor, idx: ModuleIndex, mtime: i128) void {
        if (self.graph.moduleAtMut(idx)) |m| m.mtime = mtime;
    }

    pub inline fn setLoader(self: ParseAccessor, idx: ModuleIndex, loader: Loader) void {
        if (self.graph.moduleAtMut(idx)) |m| m.loader = loader;
    }

    pub inline fn setDefFormat(self: ParseAccessor, idx: ModuleIndex, format: ModuleDefFormat) void {
        if (self.graph.moduleAtMut(idx)) |m| m.def_format = format;
    }

    pub inline fn setState(self: ParseAccessor, idx: ModuleIndex, state: Module.State) void {
        if (self.graph.moduleAtMut(idx)) |m| m.state = state;
    }

    pub inline fn setAssetData(self: ParseAccessor, idx: ModuleIndex, data: ?Module.AssetData) void {
        if (self.graph.moduleAtMut(idx)) |m| m.asset_data = data;
    }

    pub inline fn setCssData(self: ParseAccessor, idx: ModuleIndex, data: ?Module.CssData) void {
        if (self.graph.moduleAtMut(idx)) |m| m.css_data = data;
    }

    // ---- multi-phase field (parse 측: 초기값/slice 확정) ----
    // TODO #1c: import_records 의 slice identity 를 parse 단계에서 freeze.
    // resolve 가 records[i].resolved 만 변경하도록 강제.

    pub inline fn setImportRecords(self: ParseAccessor, idx: ModuleIndex, records: []ImportRecord) void {
        if (self.graph.moduleAtMut(idx)) |m| m.import_records = records;
    }

    pub inline fn setExportsKind(self: ParseAccessor, idx: ModuleIndex, kind: ExportsKind) void {
        if (self.graph.moduleAtMut(idx)) |m| m.exports_kind = kind;
    }

    pub inline fn setWrapKind(self: ParseAccessor, idx: ModuleIndex, kind: WrapKind) void {
        if (self.graph.moduleAtMut(idx)) |m| m.wrap_kind = kind;
    }

    pub inline fn setSideEffects(self: ParseAccessor, idx: ModuleIndex, value: bool) void {
        if (self.graph.moduleAtMut(idx)) |m| m.side_effects = value;
    }

    /// 자기 모듈의 `await` 감지 결과. resolve 단계에서 transitive 전파 (#1c 에서 정책 강제).
    pub inline fn setUsesTopLevelAwait(self: ParseAccessor, idx: ModuleIndex, value: bool) void {
        if (self.graph.moduleAtMut(idx)) |m| m.uses_top_level_await = value;
    }
};

// ============================================================
// ResolveAccessor
// ============================================================

/// Resolve phase mutation accessor. main thread 가 import specifier 매칭 결과를
/// 적용할 때 사용. dependency/importer/dynamic_import 인접 리스트 append 도 여기.
pub const ResolveAccessor = struct {
    graph: *ModuleGraph,

    pub inline fn read(self: ResolveAccessor, idx: ModuleIndex) ?*const Module {
        return self.graph.getModule(idx);
    }

    // ---- 단일-phase resolve field setter ----

    pub inline fn setIsModuleField(self: ResolveAccessor, idx: ModuleIndex, value: bool) void {
        if (self.graph.moduleAtMut(idx)) |m| m.is_module_field = value;
    }

    pub inline fn setSideEffectsUserDefined(self: ResolveAccessor, idx: ModuleIndex, value: bool) void {
        if (self.graph.moduleAtMut(idx)) |m| m.side_effects_user_defined = value;
    }

    pub inline fn setIsDisabled(self: ResolveAccessor, idx: ModuleIndex, value: bool) void {
        if (self.graph.moduleAtMut(idx)) |m| m.is_disabled = value;
    }

    pub inline fn setIsEntryPoint(self: ResolveAccessor, idx: ModuleIndex, value: bool) void {
        if (self.graph.moduleAtMut(idx)) |m| m.is_entry_point = value;
    }

    // ---- multi-phase field (resolve 측: 인덱스 단위 update / promote) ----
    // TODO #1c: ResolveAccessor 에서 slice 재할당 setter 제거하고 element-wise update 만 노출.

    /// import_records[rec_i].resolved = dep_idx. slice identity 는 건드리지 않음.
    pub inline fn setRecordResolved(self: ResolveAccessor, idx: ModuleIndex, rec_i: usize, dep: ModuleIndex) void {
        const m = self.graph.moduleAtMut(idx) orelse return;
        if (rec_i >= m.import_records.len) return;
        m.import_records[rec_i].resolved = dep;
    }

    /// exports_kind 승격. parse 가 .none 으로 초기화한 경우만 set 가능 (#1c 에서 강제).
    pub inline fn promoteExportsKind(self: ResolveAccessor, idx: ModuleIndex, kind: ExportsKind) void {
        if (self.graph.moduleAtMut(idx)) |m| m.exports_kind = kind;
    }

    /// wrap_kind 승격. .none → .esm/.cjs 만 허용 (#1c 에서 강제).
    pub inline fn promoteWrapKind(self: ResolveAccessor, idx: ModuleIndex, kind: WrapKind) void {
        if (self.graph.moduleAtMut(idx)) |m| m.wrap_kind = kind;
    }

    /// package.json sideEffects 정책 적용. true → false 단조 변환만 (#1c 에서 강제).
    pub inline fn applySideEffectsPolicy(self: ResolveAccessor, idx: ModuleIndex, value: bool) void {
        if (self.graph.moduleAtMut(idx)) |m| m.side_effects = value;
    }

    /// transitive TLA 전파. parse 가 자기 모듈 await 만 마킹, resolve 가 TLA 모듈을
    /// import 한 모듈에 true 전파 (단조 false→true).
    pub inline fn propagateUsesTopLevelAwait(self: ResolveAccessor, idx: ModuleIndex, value: bool) void {
        if (self.graph.moduleAtMut(idx)) |m| m.uses_top_level_await = value;
    }

    /// 인접 리스트 append. PR #2 에서 Module.addDependency 시그니처 변경 시 함께 정리.
    pub fn appendDependency(self: ResolveAccessor, idx: ModuleIndex, dep: ModuleIndex) !void {
        const m = self.graph.moduleAtMut(idx) orelse return;
        try m.addDependency(self.graph.allocator, dep, self.graph.modules.items);
    }

    pub fn appendDynamicImport(self: ResolveAccessor, idx: ModuleIndex, dep: ModuleIndex) !void {
        const m = self.graph.moduleAtMut(idx) orelse return;
        try m.addDynamicImport(self.graph.allocator, dep);
    }

    /// alias_table lazy 초기화 (existing Module.ensureAliasTable wrapper).
    pub fn ensureAliasTable(self: ResolveAccessor, idx: ModuleIndex) void {
        if (self.graph.moduleAtMut(idx)) |m| m.ensureAliasTable(self.graph.allocator);
    }
};

// ============================================================
// LinkAccessor
// ============================================================

/// Link phase mutation accessor. DFS 후위 순회로 exec_index/cycle_group 부여.
/// linker.populate* 함수들도 여기 경유 (PR #2 에서 시그니처 통일).
pub const LinkAccessor = struct {
    graph: *ModuleGraph,

    pub inline fn read(self: LinkAccessor, idx: ModuleIndex) ?*const Module {
        return self.graph.getModule(idx);
    }

    pub inline fn setExecIndex(self: LinkAccessor, idx: ModuleIndex, value: u32) void {
        if (self.graph.moduleAtMut(idx)) |m| m.exec_index = value;
    }

    pub inline fn setCycleGroup(self: LinkAccessor, idx: ModuleIndex, value: u32) void {
        if (self.graph.moduleAtMut(idx)) |m| m.cycle_group = value;
    }

    /// dev mode 모듈 ID. bundler 가 build() 끝 emit 직전 단계에서 한 번만 write.
    pub inline fn setDevId(self: LinkAccessor, idx: ModuleIndex, dev_id: []const u8) void {
        if (self.graph.moduleAtMut(idx)) |m| m.dev_id = dev_id;
    }
};

// ============================================================
// Tests
// ============================================================

test "ModulePhase enum has 5 variants" {
    try std.testing.expectEqual(@as(usize, 5), @typeInfo(ModulePhase).@"enum".fields.len);
}

test "accessor structs are zero-cost" {
    // *ModuleGraph 만 보관 → @sizeOf(*ModuleGraph) 와 동일해야 함.
    try std.testing.expectEqual(@sizeOf(*ModuleGraph), @sizeOf(ParseAccessor));
    try std.testing.expectEqual(@sizeOf(*ModuleGraph), @sizeOf(ResolveAccessor));
    try std.testing.expectEqual(@sizeOf(*ModuleGraph), @sizeOf(LinkAccessor));
}
