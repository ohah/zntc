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
pub const ImportBinding = @import("binding_scanner.zig").ImportBinding;
const ExportBinding = @import("binding_scanner.zig").ExportBinding;
const Span = @import("../lexer/token.zig").Span;
const NodeIndex = @import("../parser/ast.zig").NodeIndex;
const Ast = @import("../parser/ast.zig").Ast;

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
    /// module.parse_arena 또는 transformer.new_symbol_ids(emit_arena)가 소유.
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
    /// symbol_id → ConstValue. 크로스-모듈 상수 인라인용.
    /// import symbol이 canonical export의 const_value를 가지면 codegen이 리터럴로 대체.
    const_values: std.AutoHashMapUnmanaged(u32, @import("../semantic/symbol.zig").ConstValue) = .{},
    /// nested mangling에서 소유권을 이전받은 문자열. deinit에서 해제.
    owned_rename_values: std.ArrayListUnmanaged([]const u8) = .empty,
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
            symbol_id: u32,
            object_literal: []const u8,
            /// namespace 변수명 (동적 접근 시 변수 참조용)
            var_name: []const u8,
        };

        pub fn get(self: *const NsInlineObjects, sym_id: u32) ?*const Entry {
            for (self.entries) |*e| {
                if (e.symbol_id == sym_id) return e;
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
    modules: []const Module,
    /// 출력 포맷.
    format: types.Format,

    /// 모듈별 export 맵: "module_index\x00exported_name" → ExportEntry
    export_map: std.StringHashMap(ExportEntry),

    /// import→export 바인딩 결과: (module_index, local_span_key) → ResolvedBinding
    resolved_bindings: std.AutoHashMap(BindingKey, ResolvedBinding),

    diagnostics: std.ArrayList(BundlerDiagnostic),

    /// 이름 충돌 해결 결과: (module_index, export_name) → canonical_name.
    /// 충돌 없으면 원본 이름 유지 (엔트리 없음).
    canonical_names: std.StringHashMap([]const u8),
    /// canonical_names 값의 역방향 조회용. 리네임 후보가 기존 할당과 충돌하는지 O(1) 확인.
    canonical_names_used: std.StringHashMap(void),

    /// 자동 수집된 예약 글로벌 이름. 모든 모듈의 unresolved references를 합친 것.
    /// scope hoisting 시 모듈 top-level 변수가 이 이름을 shadowing하면 리네임.
    /// Rolldown 방식: 하드코딩 목록 대신 실제 사용된 글로벌만 예약.
    reserved_globals: std.StringHashMap(void),

    /// computeMangling 완료 후 true. buildMetadataForAst에서 nested mangling 수행 여부 결정.
    nested_mangling_enabled: bool = false,

    const ExportEntry = struct {
        binding: ExportBinding,
        module_index: ModuleIndex,
    };

    /// namespace 객체 preamble 생성 시 사용하는 export 쌍.
    const NsExportPair = struct {
        exported: []const u8,
        local: []const u8,
        /// buildInlineObjectStr에서 할당된 문자열인 경우 true.
        /// exports ArrayList 해제 시 owned=true인 local만 free.
        owned: bool = false,
    };

    /// re-export 체인 순환 방지 깊이 제한.
    const max_chain_depth = 100;

    const BindingKey = struct {
        module_index: u32,
        span_key: u64,
    };

    pub fn init(allocator: std.mem.Allocator, modules: []const Module, format: types.Format) Linker {
        return .{
            .allocator = allocator,
            .modules = modules,
            .format = format,
            .export_map = std.StringHashMap(ExportEntry).init(allocator),
            .resolved_bindings = std.AutoHashMap(BindingKey, ResolvedBinding).init(allocator),
            .diagnostics = .empty,
            .canonical_names = std.StringHashMap([]const u8).init(allocator),
            .canonical_names_used = std.StringHashMap(void).init(allocator),
            .reserved_globals = std.StringHashMap(void).init(allocator),
        };
    }

    pub fn deinit(self: *Linker) void {
        var eit = self.export_map.keyIterator();
        while (eit.next()) |key| {
            self.allocator.free(key.*);
        }
        self.export_map.deinit();
        self.resolved_bindings.deinit();
        // canonical_names의 키(makeExportKey 할당)와 값(fmt.allocPrint 할당) 해제
        var cit = self.canonical_names.iterator();
        while (cit.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.canonical_names.deinit();
        self.canonical_names_used.deinit();
        self.reserved_globals.deinit();
        self.diagnostics.deinit(self.allocator);
    }

    /// 링킹 실행: export 맵 구축 → import 바인딩 해결.
    pub fn link(self: *Linker) !void {
        try self.buildExportMap();
        try self.resolveImports();
    }

    /// 이름 충돌 감지 + 리네임에 사용하는 소유자 정보.
    const NameOwner = struct {
        module_index: u32,
        exec_index: u32,
    };

    /// name_to_owners HashMap의 타입 별칭.
    pub const NameToOwnersMap = std.StringHashMap(std.ArrayList(NameOwner));

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

            // import binding은 일반적으로 인라인되어 변수가 생성되지 않으므로 충돌 대상 아님.
            // 단, CJS 모듈을 import하면 preamble에서 `var X = require_xxx().X`로 변수가 생성되므로
            // 충돌 대상에 포함해야 한다.
            const sym_idx = scope_entry.value_ptr.*;
            if (sym_idx < sem.symbols.len and sem.symbols[sym_idx].decl_flags.is_import) {
                // CJS preamble 변수가 생성되는 경우에만 충돌 대상에 포함
                const generates_preamble = blk: {
                    for (m.import_bindings) |ib| {
                        if (!std.mem.eql(u8, ib.local_name, sym_name)) continue;
                        if (ib.import_record_index >= m.import_records.len) break :blk false;
                        const rec = m.import_records[ib.import_record_index];
                        // unresolved import → require() preamble
                        if (rec.resolved.isNone()) break :blk true;
                        // CJS 모듈 import → require_xxx() preamble
                        const cmod = @intFromEnum(rec.resolved);
                        if (cmod < self.modules.len and self.modules[cmod].wrap_kind == .cjs) break :blk true;
                        break :blk false;
                    }
                    break :blk false;
                };
                if (!generates_preamble) continue;
            }

            const entry = try name_to_owners.getOrPut(sym_name);
            if (!entry.found_existing) {
                entry.value_ptr.* = .empty;
            }
            try entry.value_ptr.append(self.allocator, .{
                .module_index = module_index,
                .exec_index = m.exec_index,
            });
        }

        // export default의 합성 _default 이름도 수집.
        // codegen에서 `export default X` → `var _default = X;`를 생성하는데,
        // 이 이름이 semantic scope에 없으므로 별도로 수집한다.
        for (m.export_bindings) |eb| {
            if (eb.kind != .local) continue;
            if (!std.mem.eql(u8, eb.exported_name, "default")) continue;
            if (std.mem.eql(u8, eb.local_name, "default")) continue;
            // scope에 이미 있으면 중복 추가 방지
            if (module_scope.get(eb.local_name) != null) continue;
            const entry = try name_to_owners.getOrPut(eb.local_name);
            if (!entry.found_existing) {
                entry.value_ptr.* = .empty;
            }
            try entry.value_ptr.append(self.allocator, .{
                .module_index = module_index,
                .exec_index = m.exec_index,
            });
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
                    const key = try makeExportKey(self.allocator, owner.module_index, name);
                    try self.putCanonicalName(key, candidate);
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

                const key = try makeExportKey(self.allocator, owner.module_index, name);
                try self.putCanonicalName(key, candidate);
                suffix += 1;
            }
        }
    }

    /// 모든 모듈의 unresolved references를 수집하여 reserved_globals에 합친다.
    /// Rolldown 방식: 하드코딩 목록 대신 실제 사용된 글로벌만 예약.
    pub fn collectReservedGlobals(self: *Linker) !void {
        self.reserved_globals.clearRetainingCapacity();
        for (self.modules) |m| {
            const sem = m.semantic orelse continue;
            var it = sem.unresolved_references.iterator();
            while (it.next()) |entry| {
                try self.reserved_globals.put(entry.key_ptr.*, {});
            }
        }
    }

    /// 이름 충돌 감지 + 리네임 계산 (Rolldown renamer 패턴).
    /// exec_index가 가장 낮은 모듈이 원본 이름 유지, 나머지는 $1, $2, ...
    pub fn computeRenames(self: *Linker) !void {
        // 0. 모든 모듈의 미해결 참조를 수집 → reserved_globals
        try self.collectReservedGlobals();

        // 1. 모든 모듈의 top-level export 이름 수집
        var name_to_owners = NameToOwnersMap.init(self.allocator);
        defer {
            var vit = name_to_owners.valueIterator();
            while (vit.next()) |list| list.deinit(self.allocator);
            name_to_owners.deinit();
        }

        for (self.modules, 0..) |m, i| {
            try self.collectModuleNames(m, @intCast(i), &name_to_owners);
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
    fn resolveNestedShadowConflicts(self: *Linker, name_to_owners: *const NameToOwnersMap) !void {
        for (self.modules, 0..) |m, mod_i| {
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
                    const key = try makeExportKey(self.allocator, cmod, export_local);

                    // 새 이름: target_name$N (기존 이름 충돌 없는 것)
                    var suffix: u32 = 1;
                    const candidate = try self.findAvailableCandidate(target_name, cmod, &suffix, name_to_owners);
                    try self.putCanonicalName(key, candidate);
                }
            }
        }
    }

    const NameEntry = struct {
        name: []const u8,
        total_refs: u32,
    };

    /// mangling 후보 수집 결과. computeMangling()에서 사용.
    const ManglingCandidates = struct {
        /// mangling 제외 대상 (export/import binding 이름)
        exported: std.StringHashMap(void),
        /// 빈도순 정렬된 mangling 후보 목록
        entries: std.ArrayListUnmanaged(NameEntry),

        fn deinit(mc: *ManglingCandidates, allocator: std.mem.Allocator) void {
            mc.exported.deinit();
            mc.entries.deinit(allocator);
        }
    };

    /// 모든 모듈의 top-level 심볼을 수집하고 reference_count 빈도순으로 정렬.
    /// mangling 제외 대상(export/import binding)도 함께 수집한다.
    fn collectManglingCandidates(self: *const Linker) !ManglingCandidates {
        var name_refs = std.StringHashMap(u32).init(self.allocator);
        defer name_refs.deinit();

        // export/import binding 이름 수집 (mangling 제외 대상)
        var exported = std.StringHashMap(void).init(self.allocator);
        errdefer exported.deinit();
        for (self.modules) |m| {
            for (m.export_bindings) |eb| {
                try exported.put(eb.exported_name, {});
                try exported.put(eb.local_name, {});
            }
            for (m.import_bindings) |ib| {
                try exported.put(ib.local_name, {});
            }
        }

        // top-level scope(scope_maps[0])의 심볼 reference_count를 이름별로 합산
        for (self.modules) |m| {
            const sem = m.semantic orelse continue;
            if (sem.scope_maps.len == 0) continue;
            var sit = sem.scope_maps[0].iterator();
            while (sit.next()) |entry| {
                const sym_name = entry.key_ptr.*;
                const sym_idx = entry.value_ptr.*;

                // mangling 제외 대상
                if (exported.contains(sym_name)) continue;
                if (sym_name.len <= 1) continue;
                if (std.mem.eql(u8, sym_name, "default")) continue;
                if (std.mem.eql(u8, sym_name, "arguments")) continue;

                const ref_count: u32 = if (sym_idx < sem.symbols.len) sem.symbols[sym_idx].reference_count else 0;
                const prev = name_refs.get(sym_name) orelse 0;
                try name_refs.put(sym_name, prev + ref_count);
            }
        }

        // 빈도순 정렬
        var entries: std.ArrayListUnmanaged(NameEntry) = .empty;
        errdefer entries.deinit(self.allocator);
        {
            var it = name_refs.iterator();
            while (it.next()) |entry| {
                try entries.append(self.allocator, .{
                    .name = entry.key_ptr.*,
                    .total_refs = entry.value_ptr.*,
                });
            }
        }
        std.mem.sortUnstable(NameEntry, entries.items, {}, struct {
            fn cmp(_: void, a: NameEntry, b: NameEntry) bool {
                if (a.total_refs != b.total_refs) return a.total_refs > b.total_refs;
                return std.mem.lessThan(u8, a.name, b.name);
            }
        }.cmp);

        return .{ .exported = exported, .entries = entries };
    }

    /// minify 활성화 시, scope hoisting 후 모든 top-level 이름을 짧은 이름으로 교체.
    /// computeRenames 이후에 호출해야 함 (충돌 해결 완료 상태).
    pub fn computeMangling(self: *Linker) !void {
        const Mangler = @import("../codegen/mangler.zig");

        // ================================================================
        // Top-level 심볼을 빈도순 Base54로 mangling (cross-module)
        // ================================================================

        // 1. mangling 후보 수집 + 빈도순 정렬
        var candidates = try self.collectManglingCandidates();
        defer candidates.deinit(self.allocator);

        // 2. 빈도순으로 Base54 이름 할당
        // 기존에 사용 중인 이름 수집 (충돌 방지)
        var all_names = std.StringHashMap(void).init(self.allocator);
        defer all_names.deinit();
        for (self.modules) |m| {
            const sem = m.semantic orelse continue;
            for (sem.scope_maps) |scope_map| {
                var sit = scope_map.iterator();
                while (sit.next()) |entry| {
                    try all_names.put(entry.key_ptr.*, {});
                }
            }
        }
        var cit = self.canonical_names.valueIterator();
        while (cit.next()) |v| {
            try all_names.put(v.*, {});
        }

        var name_map = std.StringHashMap([]const u8).init(self.allocator);
        defer {
            var vit = name_map.valueIterator();
            while (vit.next()) |v| self.allocator.free(v.*);
            name_map.deinit();
        }
        var used_names = std.StringHashMap(void).init(self.allocator);
        defer used_names.deinit();

        var name_counter: u32 = 0;
        var name_buf: [8]u8 = undefined;
        for (candidates.entries.items) |entry| {
            var new_name = Mangler.nextBase54Name(&name_counter, &name_buf);
            while (all_names.contains(new_name) or
                used_names.contains(new_name) or
                candidates.exported.contains(new_name))
            {
                new_name = Mangler.nextBase54Name(&name_counter, &name_buf);
            }

            if (!std.mem.eql(u8, entry.name, new_name)) {
                const duped = try self.allocator.dupe(u8, new_name);
                try name_map.put(entry.name, duped);
                try used_names.put(duped, {});
            }
        }

        // 3. canonical_names 업데이트 — 기존 rename된 이름도 mangling
        var update_list: std.ArrayList(struct { key: []const u8, val: []const u8 }) = .empty;
        defer update_list.deinit(self.allocator);

        var cnit = self.canonical_names.iterator();
        while (cnit.next()) |cn_entry| {
            const current_name = cn_entry.value_ptr.*;
            if (name_map.get(current_name)) |mangled| {
                try update_list.append(self.allocator, .{
                    .key = cn_entry.key_ptr.*,
                    .val = try self.allocator.dupe(u8, mangled),
                });
            }
        }
        for (update_list.items) |upd| {
            if (self.canonical_names.getPtr(upd.key)) |ptr| {
                self.allocator.free(ptr.*);
                ptr.* = upd.val;
            }
        }

        // 4. 아직 canonical_names에 없는 이름도 추가 (충돌 없던 이름)
        for (self.modules, 0..) |m, i| {
            const sem = m.semantic orelse continue;
            if (sem.scope_maps.len == 0) continue;
            var sit = sem.scope_maps[0].iterator();
            while (sit.next()) |scope_entry| {
                const sym_name = scope_entry.key_ptr.*;
                if (name_map.get(sym_name)) |mangled| {
                    const key = makeExportKey(self.allocator, @intCast(i), sym_name) catch continue;
                    if (!self.canonical_names.contains(key)) {
                        self.canonical_names.put(key, self.allocator.dupe(u8, mangled) catch continue) catch {
                            self.allocator.free(key);
                        };
                    } else {
                        self.allocator.free(key);
                    }
                }
            }
        }

        self.nested_mangling_enabled = true;
    }

    /// 다른 모듈의 리네임 대상으로 이미 할당된 이름인지 O(1) 확인.
    fn isCanonicalNameTaken(self: *const Linker, name: []const u8) bool {
        return self.canonical_names_used.contains(name);
    }

    /// canonical_names에 put하면서 역방향 맵도 동기화.
    fn putCanonicalName(self: *Linker, key: []const u8, value: []const u8) !void {
        if (self.canonical_names.fetchRemove(key)) |old| {
            _ = self.canonical_names_used.fetchRemove(old.value);
            self.allocator.free(old.key);
            self.allocator.free(old.value);
        }
        try self.canonical_names.put(key, value);
        try self.canonical_names_used.put(value, {});
    }

    /// 모듈의 중첩 스코프(비-모듈 스코프)에 해당 이름이 존재하는지 확인.
    fn hasNestedBinding(self: *const Linker, module_index: u32, name: []const u8) bool {
        if (module_index >= self.modules.len) return false;
        const m = self.modules[module_index];
        const sem = m.semantic orelse return false;

        // scope_maps[0]은 보통 모듈 스코프. 나머지가 중첩 스코프.
        for (sem.scope_maps, 0..) |scope_map, scope_idx| {
            if (scope_idx == 0) continue; // 모듈 스코프는 스킵
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
    pub fn getExportLocalName(self: *const Linker, module_index: u32, exported_name: []const u8) ?[]const u8 {
        var key_buf: [4096]u8 = undefined;
        const key = makeExportKeyBuf(&key_buf, module_index, exported_name);
        const entry = self.export_map.get(key) orelse return null;
        return entry.binding.local_name;
    }

    /// 특정 모듈+이름에 대한 canonical name 조회. 리네임 안 됐으면 null (원본 유지).
    pub fn getCanonicalName(self: *const Linker, module_index: u32, name: []const u8) ?[]const u8 {
        var key_buf: [4096]u8 = undefined;
        const key = makeExportKeyBuf(&key_buf, module_index, name);
        return self.canonical_names.get(key);
    }

    /// AST에서 import/export 노드를 식별하여 스킵 비트셋을 생성한다.
    /// buildMetadataForAst와 buildDevMetadataForAst에서 공유.
    fn buildSkipNodes(allocator: std.mem.Allocator, new_ast: *const Ast) !std.DynamicBitSet {
        const node_count = new_ast.nodes.items.len;
        var skip_nodes = try std.DynamicBitSet.initEmpty(allocator, node_count);
        errdefer skip_nodes.deinit();

        for (new_ast.nodes.items, 0..) |node, node_idx| {
            switch (node.tag) {
                .import_declaration => skip_nodes.set(node_idx),
                .export_named_declaration => {
                    const e = node.data.extra;
                    if (e + 3 < new_ast.extra_data.items.len) {
                        const decl_idx: NodeIndex = @enumFromInt(new_ast.extra_data.items[e]);
                        if (decl_idx.isNone()) {
                            skip_nodes.set(node_idx); // export { } 또는 re-export
                        }
                        // export const → codegen에서 export 키워드만 생략
                    }
                },
                // export default → codegen이 linking_metadata 체크하여 키워드만 생략
                .export_default_declaration => {},
                .export_all_declaration => skip_nodes.set(node_idx),
                else => {},
            }
        }
        return skip_nodes;
    }

    /// transformer 이후의 new_ast를 기반으로 LinkingMetadata를 생성한다.
    /// skip_nodes와 renames가 new_ast의 노드 인덱스와 일치.
    pub fn buildMetadataForAst(
        self: *const Linker,
        new_ast: *const Ast,
        module_index: u32,
        is_entry: bool,
        override_symbol_ids: ?[]const ?u32,
    ) !LinkingMetadata {
        if (module_index >= self.modules.len) {
            return .{
                .skip_nodes = try std.DynamicBitSet.initEmpty(self.allocator, 0),
                .renames = std.AutoHashMap(u32, []const u8).init(self.allocator),
                .final_exports = null,
                .symbol_ids = &.{},
                .allocator = self.allocator,
            };
        }

        const m = self.modules[module_index];

        // CJS 래핑 모듈은 스코프 호이스팅 대상이 아님.
        // 단, 내부 require() 호출은 번들된 require_xxx()로 치환해야 함.
        if (m.wrap_kind == .cjs) {
            const node_count = new_ast.nodes.items.len;
            var require_rewrites: std.StringHashMapUnmanaged([]const u8) = .{};
            for (m.import_records) |rec| {
                if (rec.resolved.isNone()) continue;
                const target = @intFromEnum(rec.resolved);
                if (target >= self.modules.len) continue;
                // 번들된 모듈을 가리키는 require() → require_xxx()로 치환
                // __commonJS로 래핑되는 모듈만 대상 (CJS, JSON 모두 wrap_kind=.cjs)
                if (self.modules[target].wrap_kind == .cjs) {
                    // 동일 specifier의 기존 값이 있으면 해제 (중복 require 방지)
                    if (require_rewrites.get(rec.specifier)) |old| {
                        self.allocator.free(old);
                    }
                    const var_name = try types.makeRequireVarName(self.allocator, self.modules[target].path);
                    try require_rewrites.put(self.allocator, rec.specifier, var_name);
                }
            }
            return .{
                .skip_nodes = try std.DynamicBitSet.initEmpty(self.allocator, node_count),
                .renames = std.AutoHashMap(u32, []const u8).init(self.allocator),
                .final_exports = null,
                .symbol_ids = if (m.semantic) |sem| sem.symbol_ids else &.{},
                .cjs_import_preamble = null,
                .require_rewrites = require_rewrites,
                .allocator = self.allocator,
            };
        }

        var skip_nodes = try buildSkipNodes(self.allocator, new_ast);
        errdefer skip_nodes.deinit();

        var renames = std.AutoHashMap(u32, []const u8).init(self.allocator);
        errdefer renames.deinit();

        // nested mangling에서 소유권을 이전받은 문자열 추적 (deinit에서 해제)
        var owned_nested_renames: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer {
            for (owned_nested_renames.items) |v| self.allocator.free(v);
            owned_nested_renames.deinit(self.allocator);
        }

        // 2. import 바인딩 리네임 (모듈의 semantic 기반)
        const sem = m.semantic orelse return .{
            .skip_nodes = skip_nodes,
            .renames = renames,
            .final_exports = null,
            .symbol_ids = &.{},
            .allocator = self.allocator,
        };

        // CJS import preamble 빌드용 버퍼
        var cjs_preamble_buf: std.ArrayList(u8) = .empty;
        defer cjs_preamble_buf.deinit(self.allocator);

        // namespace member rewrite 엔트리 수집 (esbuild 방식)
        var ns_rewrite_list: std.ArrayList(LinkingMetadata.NsMemberRewrites.Entry) = .empty;
        errdefer {
            for (ns_rewrite_list.items) |*e| e.map.deinit();
            ns_rewrite_list.deinit(self.allocator);
        }
        // namespace 인라인 객체 수집 (값 사용 시)
        var ns_inline_list: std.ArrayList(LinkingMetadata.NsInlineObjects.Entry) = .empty;
        errdefer {
            for (ns_inline_list.items) |e| {
                self.allocator.free(e.object_literal);
                self.allocator.free(e.var_name);
            }
            ns_inline_list.deinit(self.allocator);
        }

        // CJS 모듈별 require_xxx 변수명 캐시 (같은 모듈에서 여러 named import 시 중복 생성 방지)
        var cjs_var_cache = std.AutoHashMap(u32, []const u8).init(self.allocator);
        defer {
            var vit = cjs_var_cache.valueIterator();
            while (vit.next()) |v| self.allocator.free(v.*);
            cjs_var_cache.deinit();
        }

        if (sem.scope_maps.len > 0) {
            const module_scope = sem.scope_maps[0];

            // export된 local name을 미리 수집 — namespace import가 re-export되는지 O(1) 확인용
            var exported_locals = std.StringHashMap(void).init(self.allocator);
            defer exported_locals.deinit();
            for (m.export_bindings) |eb| {
                if (eb.kind == .local) try exported_locals.put(eb.local_name, {});
            }

            // import 바인딩 → canonical 이름
            for (m.import_bindings) |ib| {
                if (ib.import_record_index >= m.import_records.len) continue;
                const rec = m.import_records[ib.import_record_index];

                // resolve 미완료: external 또는 resolve 실패.
                // 모든 포맷에서 require() preamble 생성.
                // ESM 번들도 import 구문 없이 출력되므로 Node가 CJS로 파싱 (esbuild 동일).
                if (rec.resolved.isNone()) {
                    if (rec.kind == .static_import or rec.kind == .side_effect or rec.kind == .re_export) {
                        // minify 시 computeMangling이 이름을 축약하므로, preamble 변수 선언도
                        // canonical name을 사용해야 코드 참조와 일치한다.
                        const preamble_name = self.getCanonicalName(module_index, ib.local_name) orelse ib.local_name;
                        try cjs_preamble_buf.appendSlice(self.allocator, "var ");
                        try cjs_preamble_buf.appendSlice(self.allocator, preamble_name);
                        try cjs_preamble_buf.appendSlice(self.allocator, " = require(\"");
                        try cjs_preamble_buf.appendSlice(self.allocator, rec.specifier);
                        try cjs_preamble_buf.appendSlice(self.allocator, "\")");
                        // named import만 .property 접근 추가 (namespace/default는 모듈 전체)
                        if (ib.kind != .namespace and !std.mem.eql(u8, ib.imported_name, "default")) {
                            try cjs_preamble_buf.appendSlice(self.allocator, ".");
                            try cjs_preamble_buf.appendSlice(self.allocator, ib.imported_name);
                        }
                        try cjs_preamble_buf.appendSlice(self.allocator, ";\n");
                    }
                    continue;
                }

                const canonical_mod = @intFromEnum(rec.resolved);

                // CJS 모듈에서 import하는 경우: preamble에서 require_xxx() 호출 생성
                if (canonical_mod < self.modules.len and self.modules[canonical_mod].wrap_kind == .cjs) {
                    const preamble_name = self.getCanonicalName(module_index, ib.local_name) orelse ib.local_name;
                    const req_var = try getOrCreateRequireVar(self, &cjs_var_cache, @intCast(canonical_mod));
                    const interop_mode: types.Interop = if (m.def_format.isEsm()) .node else .babel;
                    try appendCjsImportPreamble(&cjs_preamble_buf, self.allocator, preamble_name, ib.imported_name, req_var, ib.kind == .namespace, interop_mode);
                    continue;
                }

                // namespace import: esbuild 방식 — ns.prop → canonical_name 직접 치환.
                // ns 자체를 값으로 사용할 때만 폴백으로 객체 생성.
                if (ib.kind == .namespace) {
                    const ns_sym_id = module_scope.get(ib.local_name) orelse continue;
                    const effective_syms = override_symbol_ids orelse sem.symbol_ids;

                    // esbuild 방식: ns.prop → 직접 치환, ns 값 사용 → 변수 선언 + 참조.
                    // export { ns } 패턴도 값 사용 — namespace 객체를 preamble 변수로 생성 필요.
                    const need_inline = isNamespaceUsedAsValue(self.allocator, new_ast, effective_syms, @intCast(ns_sym_id)) or
                        exported_locals.contains(ib.local_name);
                    try self.registerNamespaceRewrites(
                        &ns_rewrite_list,
                        if (need_inline) &ns_inline_list else null,
                        @intCast(ns_sym_id),
                        @intCast(canonical_mod),
                        ib.local_name,
                    );
                    continue;
                }

                // resolveImports()에서 이미 해결한 바인딩을 조회하거나, 직접 해결
                const resolved = self.getResolvedBinding(module_index, ib.local_span);

                // export * from CJS 패턴: canonical이 CJS 모듈을 가리키면
                // rename 대신 CJS preamble을 생성한다.
                if (resolved) |rb| {
                    const cjs_mod: u32 = @intCast(@intFromEnum(rb.canonical.module_index));
                    if (cjs_mod < self.modules.len and self.modules[cjs_mod].wrap_kind == .cjs) {
                        const preamble_name = self.getCanonicalName(module_index, ib.local_name) orelse ib.local_name;
                        const req_var = try getOrCreateRequireVar(self, &cjs_var_cache, cjs_mod);
                        const interop_mode2: types.Interop = if (m.def_format.isEsm()) .node else .babel;
                        try appendCjsImportPreamble(&cjs_preamble_buf, self.allocator, preamble_name, ib.imported_name, req_var, false, interop_mode2);
                        continue;
                    }
                }

                const target_name = blk: {
                    if (resolved) |rb| {
                        const local = self.resolveToLocalName(rb.canonical);
                        // namespace re-export 감지: export * as X → local_name == exported_name
                        // 이 경우 소스 모듈의 namespace 객체 preamble을 importer에 생성
                        const cmod: u32 = @intCast(@intFromEnum(rb.canonical.module_index));
                        if (cmod < self.modules.len) {
                            for (self.modules[cmod].export_bindings) |eb| {
                                if (eb.kind == .re_export_all and
                                    std.mem.eql(u8, eb.exported_name, rb.canonical.export_name) and
                                    !std.mem.eql(u8, eb.exported_name, "*"))
                                {
                                    // namespace re-export: ns_member_rewrites + 인라인 객체 등록
                                    if (eb.import_record_index) |rec_idx| {
                                        if (rec_idx < self.modules[cmod].import_records.len) {
                                            const src = self.modules[cmod].import_records[rec_idx].resolved;
                                            if (!src.isNone()) {
                                                const import_sym_id = module_scope.get(ib.local_name) orelse break :blk ib.imported_name;
                                                try self.registerNamespaceRewrites(
                                                    &ns_rewrite_list,
                                                    &ns_inline_list,
                                                    @intCast(import_sym_id),
                                                    @intFromEnum(src),
                                                    ib.local_name,
                                                );
                                                break :blk ib.local_name;
                                            }
                                        }
                                    }
                                }
                            }
                        }
                        // canonical의 export local_name이 namespace import인 경우 → 인라인 객체
                        const cmod2: u32 = @intCast(@intFromEnum(rb.canonical.module_index));
                        const export_local = self.getExportLocalName(cmod2, rb.canonical.export_name) orelse rb.canonical.export_name;
                        if (cmod2 < self.modules.len) {
                            for (self.modules[cmod2].import_bindings) |cib| {
                                if (cib.kind == .namespace and std.mem.eql(u8, cib.local_name, export_local)) {
                                    // namespace import → 인라인 객체로 처리
                                    const imp_sym = module_scope.get(ib.local_name) orelse break;
                                    const ns_target_mod = if (cib.import_record_index < self.modules[cmod2].import_records.len)
                                        @intFromEnum(self.modules[cmod2].import_records[cib.import_record_index].resolved)
                                    else
                                        break;
                                    try self.registerNamespaceRewrites(
                                        &ns_rewrite_list,
                                        &ns_inline_list,
                                        @intCast(imp_sym),
                                        @intCast(ns_target_mod),
                                        ib.local_name,
                                    );
                                    break :blk ib.local_name;
                                }
                            }
                        }
                        break :blk local;
                    }
                    break :blk ib.imported_name;
                };

                // import binding → target module의 canonical name으로 rename.
                // scope hoisting 후 import가 제거되므로, 같은 이름이라도
                // 항상 renames에 등록하여 codegen이 target 변수를 참조하도록 함.
                // 중첩 스코프 충돌은 resolveNestedShadowConflicts에서 이미 처리됨.
                if (!isReservedName(target_name)) {
                    if (module_scope.get(ib.local_name)) |sym_idx| {
                        try renames.put(@intCast(sym_idx), target_name);
                    }
                }
            }

            // 자체 top-level 심볼 리네임 (이름 충돌 + mangling)
            var sit = module_scope.iterator();
            while (sit.next()) |scope_entry| {
                const sym_name = scope_entry.key_ptr.*;
                if (self.getCanonicalName(module_index, sym_name)) |renamed| {
                    const sym_idx = scope_entry.value_ptr.*;
                    try renames.put(@intCast(sym_idx), renamed);
                }
            }

            // nested scope mangling (liveness 기반)
            // top-level은 computeMangling에서 처리됨 → nested만 수행
            if (self.nested_mangling_enabled and sem.symbols.len > 0) {
                const Mangler = @import("../codegen/mangler.zig");

                // top-level scope + export/import 심볼은 skip
                var skip_syms = try std.DynamicBitSet.initEmpty(self.allocator, sem.symbols.len);
                defer skip_syms.deinit();

                // scope_maps[0] (module scope)의 모든 심볼을 skip
                var skip_it = module_scope.iterator();
                while (skip_it.next()) |skip_entry| {
                    const sym_i = skip_entry.value_ptr.*;
                    if (sym_i < sem.symbols.len) skip_syms.set(sym_i);
                }

                var nested_result = try Mangler.mangle(self.allocator, .{
                    .scopes = sem.scopes,
                    .symbols = sem.symbols,
                    .scope_maps = sem.scope_maps,
                    .ref_scope_pairs = sem.ref_scope_pairs,
                    .source = m.source,
                    .skip_symbols = skip_syms,
                });

                // nested renames를 기존 renames에 merge (소유권 이전)
                var taken = nested_result.takeRenames();
                defer taken.deinit(); // HashMap 자체만 해제 (값은 owned_nested_renames가 관리)
                var nit = taken.iterator();
                while (nit.next()) |n_entry| {
                    if (!renames.contains(n_entry.key_ptr.*)) {
                        try renames.put(n_entry.key_ptr.*, n_entry.value_ptr.*);
                        try owned_nested_renames.append(self.allocator, n_entry.value_ptr.*);
                    } else {
                        self.allocator.free(n_entry.value_ptr.*);
                    }
                }
                nested_result.deinit(); // 빈 상태이므로 안전
            }
        }

        // CJS import preamble 저장
        var cjs_import_preamble: ?[]const u8 = null;
        if (cjs_preamble_buf.items.len > 0) {
            cjs_import_preamble = try self.allocator.dupe(u8, cjs_preamble_buf.items);
        }

        // export default의 합성 변수명 계산 (이름 충돌 시 _default$1 등)
        var default_export_name: []const u8 = "_default";
        for (m.export_bindings) |eb| {
            if (eb.kind == .local and std.mem.eql(u8, eb.exported_name, "default")) {
                if (!std.mem.eql(u8, eb.local_name, "default")) {
                    default_export_name = self.getCanonicalName(module_index, eb.local_name) orelse eb.local_name;
                }
                break;
            }
        }

        // 3. 엔트리 포인트 final exports
        const final_exports = try self.buildFinalExports(is_entry, module_index, m.export_bindings);

        // 크로스-모듈 상수 인라인: import binding의 canonical export가 상수이면 매핑
        const const_values = try self.buildCrossModuleConstValues(&self.modules[module_index], sem);

        // ns_member_rewrites / ns_inline_objects 소유권 이동 + namespace preamble 생성.
        // finalizeNamespaceData가 리스트를 소비(deinit)하므로, 이후 에러 시
        // errdefer가 이미 해제된 리스트에 접근하지 않도록 마지막에 호출한다.
        const ns_result = try finalizeNamespaceData(self.allocator, &ns_rewrite_list, &ns_inline_list, cjs_import_preamble);
        const ns_rewrites = ns_result.rewrites;
        const ns_inlines = ns_result.inlines;
        const combined_preamble = ns_result.combined_preamble;

        return .{
            .skip_nodes = skip_nodes,
            .renames = renames,
            .final_exports = final_exports,
            .symbol_ids = sem.symbol_ids,
            .cjs_import_preamble = combined_preamble,
            .default_export_name = default_export_name,
            .ns_member_rewrites = ns_rewrites,
            .ns_inline_objects = ns_inlines,
            .const_values = const_values,
            .owned_rename_values = owned_nested_renames,
            .allocator = self.allocator,
        };
    }

    /// 엔트리 포인트의 최종 export 문을 생성한다. (e.g. "export { x, y$1 as y };\n")
    /// is_entry가 false이거나 export가 없으면 null 반환.
    fn buildFinalExports(
        self: *const Linker,
        is_entry: bool,
        module_index: u32,
        export_bindings: []const ExportBinding,
    ) !?[]const u8 {
        if (!is_entry or export_bindings.len == 0) return null;

        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.allocator);
        try buf.appendSlice(self.allocator, "export {");
        var first = true;
        for (export_bindings) |eb| {
            if (eb.kind == .re_export_all) continue;
            if (std.mem.eql(u8, eb.exported_name, "*")) continue;
            if (!first) try buf.appendSlice(self.allocator, ",");
            first = false;
            const actual_name = self.getCanonicalName(module_index, eb.local_name) orelse eb.local_name;
            try buf.append(self.allocator, ' ');
            try buf.appendSlice(self.allocator, actual_name);
            if (!std.mem.eql(u8, actual_name, eb.exported_name)) {
                try buf.appendSlice(self.allocator, " as ");
                try buf.appendSlice(self.allocator, eb.exported_name);
            }
        }
        try buf.appendSlice(self.allocator, " };\n");
        if (!first) {
            return try self.allocator.dupe(u8, buf.items);
        }
        return null;
    }

    /// 크로스-모듈 상수 인라인 맵을 생성한다.
    /// import binding의 canonical export가 상수이면 symbol_id → ConstValue 매핑을 반환.
    fn buildCrossModuleConstValues(
        self: *const Linker,
        m: *const Module,
        sem: @import("module.zig").ModuleSemanticData,
    ) !std.AutoHashMapUnmanaged(u32, @import("../semantic/symbol.zig").ConstValue) {
        var const_values: std.AutoHashMapUnmanaged(u32, @import("../semantic/symbol.zig").ConstValue) = .{};
        for (m.import_bindings) |ib| {
            if (ib.import_record_index >= m.import_records.len) continue;
            const rec = m.import_records[ib.import_record_index];
            if (rec.resolved.isNone()) continue;
            const canon = self.resolveExportChain(rec.resolved, ib.imported_name, 0) orelse continue;
            const canon_mod_idx = @intFromEnum(canon.module_index);
            if (canon_mod_idx >= self.modules.len) continue;
            const target_module = self.modules[canon_mod_idx];
            const target_sem = target_module.semantic orelse continue;
            if (target_sem.scope_maps.len == 0) continue;
            // export_name → local_name 매핑
            var local_name = canon.export_name;
            for (target_module.export_bindings) |eb| {
                if (std.mem.eql(u8, eb.exported_name, canon.export_name)) {
                    local_name = eb.local_name;
                    break;
                }
            }
            const target_sym_idx = target_sem.scope_maps[0].get(local_name) orelse continue;
            if (target_sym_idx >= target_sem.symbols.len) continue;
            const cv = target_sem.symbols[target_sym_idx].const_value;
            if (cv.kind == .none or !cv.isSafeToInline()) continue;
            // import binding의 local symbol에 매핑
            if (sem.scope_maps.len > 0) {
                if (sem.scope_maps[0].get(ib.local_name)) |local_sym| {
                    try const_values.put(self.allocator, @intCast(local_sym), cv);
                }
            }
        }
        return const_values;
    }

    /// namespace 리스트의 소유권을 이동하고, namespace preamble을 CJS preamble과 합친다.
    /// ns_rewrite_list와 ns_inline_list는 이 함수 호출 후 deinit된다.
    fn finalizeNamespaceData(
        allocator: std.mem.Allocator,
        ns_rewrite_list: *std.ArrayList(LinkingMetadata.NsMemberRewrites.Entry),
        ns_inline_list: *std.ArrayList(LinkingMetadata.NsInlineObjects.Entry),
        cjs_import_preamble: ?[]const u8,
    ) !struct {
        rewrites: LinkingMetadata.NsMemberRewrites,
        inlines: LinkingMetadata.NsInlineObjects,
        combined_preamble: ?[]const u8,
    } {
        const ns_rewrites: LinkingMetadata.NsMemberRewrites = if (ns_rewrite_list.items.len > 0)
            .{ .entries = try allocator.dupe(LinkingMetadata.NsMemberRewrites.Entry, ns_rewrite_list.items) }
        else
            .{};
        ns_rewrite_list.deinit(allocator);

        const ns_inlines: LinkingMetadata.NsInlineObjects = if (ns_inline_list.items.len > 0)
            .{ .entries = try allocator.dupe(LinkingMetadata.NsInlineObjects.Entry, ns_inline_list.items) }
        else
            .{};
        ns_inline_list.deinit(allocator);

        // namespace 변수 선언을 preamble에 추가: var gql = {parse: parse, ...};
        var ns_preamble_buf: std.ArrayList(u8) = .empty;
        defer ns_preamble_buf.deinit(allocator);
        for (ns_inlines.entries) |entry| {
            try ns_preamble_buf.appendSlice(allocator, "var ");
            try ns_preamble_buf.appendSlice(allocator, entry.var_name);
            try ns_preamble_buf.appendSlice(allocator, " = ");
            try ns_preamble_buf.appendSlice(allocator, entry.object_literal);
            try ns_preamble_buf.appendSlice(allocator, ";\n");
        }
        const combined_preamble: ?[]const u8 = if (ns_preamble_buf.items.len > 0) blk: {
            // ns preamble이 있으면 cjs preamble과 합침
            const combined = try std.mem.concat(allocator, u8, &.{
                cjs_import_preamble orelse "",
                ns_preamble_buf.items,
            });
            if (cjs_import_preamble) |p| allocator.free(p);
            break :blk combined;
        } else cjs_import_preamble;

        return .{
            .rewrites = ns_rewrites,
            .inlines = ns_inlines,
            .combined_preamble = combined_preamble,
        };
    }

    /// Dev mode용 LinkingMetadata를 생성한다.
    ///
    /// 프로덕션 buildMetadataForAst와의 차이:
    ///   - renames 없음 (스코프 호이스팅 안 함, 각 모듈이 자체 스코프 유지)
    ///   - cjs_import_preamble: `const { x } = __zts_require("./path")` 형태
    ///   - final_exports: 모든 모듈에 `__zts_exports.x = x;` 형태 (entry만이 아닌 전체)
    pub fn buildDevMetadataForAst(
        self: *const Linker,
        new_ast: *const Ast,
        module_index: u32,
    ) !LinkingMetadata {
        if (module_index >= self.modules.len) {
            return .{
                .skip_nodes = try std.DynamicBitSet.initEmpty(self.allocator, 0),
                .renames = std.AutoHashMap(u32, []const u8).init(self.allocator),
                .final_exports = null,
                .symbol_ids = &.{},
                .allocator = self.allocator,
            };
        }

        const m = self.modules[module_index];

        // CJS 래핑 모듈은 dev mode에서도 기존대로 유지
        if (m.wrap_kind == .cjs) {
            const node_count = new_ast.nodes.items.len;
            return .{
                .skip_nodes = try std.DynamicBitSet.initEmpty(self.allocator, node_count),
                .renames = std.AutoHashMap(u32, []const u8).init(self.allocator),
                .final_exports = null,
                .symbol_ids = if (m.semantic) |sem| sem.symbol_ids else &.{},
                .cjs_import_preamble = null,
                .allocator = self.allocator,
            };
        }

        var skip_nodes = try buildSkipNodes(self.allocator, new_ast);
        errdefer skip_nodes.deinit();

        // 2. __zts_require preamble 생성
        var preamble_buf: std.ArrayList(u8) = .empty;
        defer preamble_buf.deinit(self.allocator);

        // import binding을 import_record_index별로 그룹핑하여 출력
        // 같은 소스에서 여러 이름을 가져오면: const { a, b } = __zts_require("./dep");
        var rec_idx: u32 = 0;
        while (rec_idx < m.import_records.len) : (rec_idx += 1) {
            const rec = m.import_records[rec_idx];
            if (rec.resolved.isNone()) continue;
            if (rec.kind == .dynamic_import) continue;

            // 이 record에 해당하는 binding 수집
            var has_default = false;
            var has_namespace = false;
            var default_local: []const u8 = "";
            var namespace_local: []const u8 = "";
            var named_count: usize = 0;

            for (m.import_bindings) |ib| {
                if (ib.import_record_index != rec_idx) continue;
                switch (ib.kind) {
                    .default => {
                        has_default = true;
                        default_local = ib.local_name;
                    },
                    .namespace => {
                        has_namespace = true;
                        namespace_local = ib.local_name;
                    },
                    .named => named_count += 1,
                }
            }

            if (!has_default and !has_namespace and named_count == 0) continue;

            // resolve된 모듈 경로
            const resolved_mod = @intFromEnum(rec.resolved);
            const resolved_path = if (resolved_mod < self.modules.len) self.modules[resolved_mod].path else rec.specifier;

            if (has_namespace) {
                // import * as ns from './dep' → const ns = __zts_require("./path");
                try preamble_buf.appendSlice(self.allocator, "var ");
                try preamble_buf.appendSlice(self.allocator, namespace_local);
                try preamble_buf.appendSlice(self.allocator, " = __zts_require(\"");
                try preamble_buf.appendSlice(self.allocator, resolved_path);
                try preamble_buf.appendSlice(self.allocator, "\");\n");
            }

            if (has_default) {
                // import foo from './dep' → var foo = __zts_require("./path").default;
                try preamble_buf.appendSlice(self.allocator, "var ");
                try preamble_buf.appendSlice(self.allocator, default_local);
                try preamble_buf.appendSlice(self.allocator, " = __zts_require(\"");
                try preamble_buf.appendSlice(self.allocator, resolved_path);
                try preamble_buf.appendSlice(self.allocator, "\").default;\n");
            }

            if (named_count > 0) {
                // import { a, b } from './dep' → var { a, b } = __zts_require("./path");
                try preamble_buf.appendSlice(self.allocator, "var { ");
                var first = true;
                for (m.import_bindings) |ib| {
                    if (ib.import_record_index != rec_idx or ib.kind != .named) continue;
                    if (!first) try preamble_buf.appendSlice(self.allocator, ", ");
                    first = false;
                    // import { foo as bar } → foo: bar
                    if (!std.mem.eql(u8, ib.imported_name, ib.local_name)) {
                        try preamble_buf.appendSlice(self.allocator, ib.imported_name);
                        try preamble_buf.appendSlice(self.allocator, ": ");
                        try preamble_buf.appendSlice(self.allocator, ib.local_name);
                    } else {
                        try preamble_buf.appendSlice(self.allocator, ib.local_name);
                    }
                }
                try preamble_buf.appendSlice(self.allocator, " } = __zts_require(\"");
                try preamble_buf.appendSlice(self.allocator, resolved_path);
                try preamble_buf.appendSlice(self.allocator, "\");\n");
            }
        }

        var cjs_import_preamble: ?[]const u8 = null;
        if (preamble_buf.items.len > 0) {
            cjs_import_preamble = try self.allocator.dupe(u8, preamble_buf.items);
        }

        // 3. __zts_exports 할당 생성 (모든 모듈, entry 여부 무관)
        var final_exports: ?[]const u8 = null;
        if (m.export_bindings.len > 0) {
            var buf: std.ArrayList(u8) = .empty;
            defer buf.deinit(self.allocator);

            for (m.export_bindings) |eb| {
                if (eb.kind == .re_export_all) continue;
                if (std.mem.eql(u8, eb.exported_name, "*")) continue;

                // __zts_exports.name = local_name;
                // re-export의 경우: __zts_exports.name = __zts_require("./dep").name;
                if (eb.kind == .re_export) {
                    if (eb.import_record_index) |iri| {
                        if (iri < m.import_records.len) {
                            const irec = m.import_records[iri];
                            if (!irec.resolved.isNone()) {
                                const re_mod = @intFromEnum(irec.resolved);
                                const re_path = if (re_mod < self.modules.len) self.modules[re_mod].path else irec.specifier;
                                try buf.appendSlice(self.allocator, "__zts_exports.");
                                try buf.appendSlice(self.allocator, eb.exported_name);
                                try buf.appendSlice(self.allocator, " = __zts_require(\"");
                                try buf.appendSlice(self.allocator, re_path);
                                try buf.appendSlice(self.allocator, "\").");
                                try buf.appendSlice(self.allocator, eb.local_name);
                                try buf.appendSlice(self.allocator, ";\n");
                                continue;
                            }
                        }
                    }
                }

                try buf.appendSlice(self.allocator, "__zts_exports.");
                try buf.appendSlice(self.allocator, eb.exported_name);
                try buf.appendSlice(self.allocator, " = ");
                try buf.appendSlice(self.allocator, eb.local_name);
                try buf.appendSlice(self.allocator, ";\n");
            }

            if (buf.items.len > 0) {
                final_exports = try self.allocator.dupe(u8, buf.items);
            }
        }

        const sem = m.semantic orelse return .{
            .skip_nodes = skip_nodes,
            .renames = std.AutoHashMap(u32, []const u8).init(self.allocator),
            .final_exports = final_exports,
            .symbol_ids = &.{},
            .cjs_import_preamble = cjs_import_preamble,
            .allocator = self.allocator,
        };

        return .{
            .skip_nodes = skip_nodes,
            .renames = std.AutoHashMap(u32, []const u8).init(self.allocator),
            .final_exports = final_exports,
            .symbol_ids = sem.symbol_ids,
            .cjs_import_preamble = cjs_import_preamble,
            .allocator = self.allocator,
        };
    }

    /// 특정 모듈에 대한 LinkingMetadata를 생성한다 (원본 AST 기준, 테스트용).
    pub fn buildMetadata(self: *const Linker, module_index: u32, is_entry: bool) !LinkingMetadata {
        if (module_index >= self.modules.len) {
            return .{
                .skip_nodes = try std.DynamicBitSet.initEmpty(self.allocator, 0),
                .renames = std.AutoHashMap(u32, []const u8).init(self.allocator),
                .final_exports = null,
                .symbol_ids = &.{},
                .allocator = self.allocator,
            };
        }

        const m = self.modules[module_index];
        const ast = m.ast orelse {
            return .{
                .skip_nodes = try std.DynamicBitSet.initEmpty(self.allocator, 0),
                .renames = std.AutoHashMap(u32, []const u8).init(self.allocator),
                .final_exports = null,
                .symbol_ids = &.{},
                .allocator = self.allocator,
            };
        };

        const node_count = ast.nodes.items.len;
        var skip_nodes = try std.DynamicBitSet.initEmpty(self.allocator, node_count);
        var renames = std.AutoHashMap(u32, []const u8).init(self.allocator);

        // 1. import_declaration → 전체 스킵
        for (ast.nodes.items, 0..) |node, node_idx| {
            if (node.tag == .import_declaration) {
                skip_nodes.set(node_idx);
            }
        }

        // 2. export 키워드 처리
        for (ast.nodes.items, 0..) |node, node_idx| {
            switch (node.tag) {
                .export_named_declaration => {
                    const e = node.data.extra;
                    if (e + 3 >= ast.extra_data.items.len) continue;
                    const decl_idx_raw = ast.extra_data.items[e];
                    const decl_idx: NodeIndex = @enumFromInt(decl_idx_raw);
                    const source_idx: NodeIndex = @enumFromInt(ast.extra_data.items[e + 3]);

                    if (!decl_idx.isNone()) {
                        // export const x = 1; → export 노드 스킵, declaration은 유지
                        // codegen은 skip_nodes에 있으면 emitNode를 건너뜀.
                        // declaration을 직접 출력하기 위해 export_named_declaration을 스킵하고
                        // declaration 노드만 남김.
                        // 하지만 이렇게 하면 declaration도 스킵됨...
                        // 대신: export_named_declaration을 스킵하지 않고,
                        // codegen에서 linking 모드일 때 "export " 키워드만 생략하도록 함.
                        // → skip_nodes 대신 codegen 분기로 처리 (PR #5 codegen 수정에서)
                    } else if (!source_idx.isNone()) {
                        // export { x } from './dep' — re-export: 전체 스킵
                        skip_nodes.set(node_idx);
                    } else {
                        // export { x } — 로컬 export: 전체 스킵 (심볼은 이미 선언됨)
                        skip_nodes.set(node_idx);
                    }
                },
                .export_default_declaration => {
                    // export default expr — 비-엔트리 모듈에서는 스킵
                    if (!is_entry) {
                        skip_nodes.set(node_idx);
                    }
                },
                .export_all_declaration => {
                    // export * from './dep' — 전체 스킵
                    skip_nodes.set(node_idx);
                },
                else => {},
            }
        }

        const sem = m.semantic orelse return .{
            .skip_nodes = skip_nodes,
            .renames = renames,
            .final_exports = null,
            .symbol_ids = &.{},
            .allocator = self.allocator,
        };

        // 3. import 바인딩: import된 심볼을 canonical 이름으로 치환
        // import binding의 심볼 인덱스를 모듈 스코프에서 이름으로 조회
        if (sem.scope_maps.len > 0) {
            const module_scope = sem.scope_maps[0];
            for (m.import_bindings) |ib| {
                if (ib.import_record_index >= m.import_records.len) continue;
                const rec = m.import_records[ib.import_record_index];
                if (rec.resolved.isNone()) continue;

                const canonical_mod = @intFromEnum(rec.resolved);
                const target_name = if (self.getCanonicalName(@intCast(canonical_mod), ib.imported_name)) |renamed|
                    renamed
                else
                    ib.imported_name;

                if (!std.mem.eql(u8, ib.local_name, target_name)) {
                    // 모듈 스코프에서 import binding의 심볼 인덱스 찾기
                    if (module_scope.get(ib.local_name)) |sym_idx| {
                        try renames.put(@intCast(sym_idx), target_name);
                    }
                }
            }
        }

        // 4. 이 모듈 자체의 top-level 심볼 리네임 (이름 충돌로 인한)
        if (sem.scope_maps.len > 0) {
            const module_scope = sem.scope_maps[0];
            var sit = module_scope.iterator();
            while (sit.next()) |scope_entry| {
                const sym_name = scope_entry.key_ptr.*;
                if (self.getCanonicalName(module_index, sym_name)) |renamed| {
                    const sym_idx = scope_entry.value_ptr.*;
                    try renames.put(@intCast(sym_idx), renamed);
                }
            }
        }

        // 5. 엔트리 포인트: final exports
        var final_exports: ?[]const u8 = null;
        if (is_entry and m.export_bindings.len > 0) {
            var buf: std.ArrayList(u8) = .empty;
            defer buf.deinit(self.allocator);
            try buf.appendSlice(self.allocator, "export {");
            var first = true;
            for (m.export_bindings) |eb| {
                if (eb.kind == .re_export_all) continue;
                if (std.mem.eql(u8, eb.exported_name, "*")) continue;

                if (!first) try buf.appendSlice(self.allocator, ",");
                first = false;

                // canonical 이름 (리네임됐으면 변경된 이름)
                const actual_name = self.getCanonicalName(module_index, eb.local_name) orelse eb.local_name;

                try buf.append(self.allocator, ' ');
                try buf.appendSlice(self.allocator, actual_name);
                if (!std.mem.eql(u8, actual_name, eb.exported_name)) {
                    try buf.appendSlice(self.allocator, " as ");
                    try buf.appendSlice(self.allocator, eb.exported_name);
                }
            }
            try buf.appendSlice(self.allocator, " };\n");
            if (!first) {
                final_exports = try self.allocator.dupe(u8, buf.items);
            }
        }

        return .{
            .skip_nodes = skip_nodes,
            .renames = renames,
            .final_exports = final_exports,
            .symbol_ids = sem.symbol_ids,
            .allocator = self.allocator,
        };
    }

    /// 모든 모듈의 export를 수집하여 export_map에 등록.
    fn buildExportMap(self: *Linker) !void {
        for (self.modules, 0..) |m, i| {
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
        for (self.modules, 0..) |m, i| {
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
        if (mod_i >= self.modules.len) return null;

        // 1. 직접 export 확인
        var key_buf: [4096]u8 = undefined;
        const key = makeExportKeyBuf(&key_buf, @intCast(mod_i), name);
        if (self.export_map.get(key)) |entry| {
            if (entry.binding.kind == .re_export) {
                // re-export: 소스 모듈로 재귀
                if (entry.binding.import_record_index) |rec_idx| {
                    const m = self.modules[mod_i];
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
            const m_local = self.modules[mod_i];
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
                            return self.resolveExportChain(source_mod, ib.imported_name, depth + 1);
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
        const m = self.modules[mod_i];
        for (m.export_bindings) |eb| {
            if (eb.kind != .re_export_all) continue;
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
        if (self.resolveExportChain(source_mod, name, depth)) |result| return result;
        const src_idx = @intFromEnum(source_mod);
        if (src_idx < self.modules.len and self.modules[src_idx].wrap_kind == .cjs) {
            return .{ .module_index = source_mod, .export_name = name };
        }
        return null;
    }

    /// namespace 식별자가 member access 이외의 위치에서 사용되는지 판별.
    /// `ns.prop`만 사용되면 false (직접 치환 가능), `console.log(ns)` 등이면 true (객체 필요).
    fn isNamespaceUsedAsValue(allocator: std.mem.Allocator, new_ast: *const Ast, symbol_ids: []const ?u32, ns_sym_id: u32) bool {
        const node_count = new_ast.nodes.items.len;
        if (node_count == 0) return false;

        // 1. member access의 object 위치를 비트셋으로 수집 — O(N) 스캔, O(1) 조회
        var safe = std.DynamicBitSet.initEmpty(allocator, node_count) catch return true;
        defer safe.deinit();

        for (new_ast.nodes.items) |node| {
            if (node.tag == .static_member_expression or node.tag == .private_field_expression) {
                const e = node.data.extra;
                if (new_ast.hasExtra(e, 2)) {
                    const obj_idx = new_ast.readExtra(e, 0);
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
                        const tag = new_ast.nodes.items[node_i].tag;
                        if (tag == .import_namespace_specifier or tag == .import_default_specifier or
                            tag == .import_specifier or tag == .binding_identifier) continue;
                    }
                    if (node_i >= node_count or !safe.isSet(node_i)) return true;
                }
            }
        }
        return false;
    }

    /// SymbolRef를 scope hoisting 후 최종 로컬 이름으로 해결.
    /// resolveExportChain → getExportLocalName → getCanonicalName 3단계를 캡슐화.
    pub fn resolveToLocalName(self: *const Linker, ref: SymbolRef) []const u8 {
        const cmod: u32 = @intCast(@intFromEnum(ref.module_index));
        const local = self.getExportLocalName(cmod, ref.export_name) orelse ref.export_name;
        const canonical = self.getCanonicalName(cmod, local) orelse local;
        return self.safeIdentifierName(canonical, cmod);
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
    /// buildMetadataForAst 내 3곳에서 동일 패턴을 공유.
    fn registerNamespaceRewrites(
        self: *const Linker,
        ns_rewrite_list: *std.ArrayList(LinkingMetadata.NsMemberRewrites.Entry),
        ns_inline_list: ?*std.ArrayList(LinkingMetadata.NsInlineObjects.Entry),
        symbol_id: u32,
        target_mod_idx: u32,
        var_name: []const u8,
    ) std.mem.Allocator.Error!void {
        var exports: std.ArrayList(NsExportPair) = .empty;
        // owned 문자열은 inner_map으로 소유권 이동 — 여기서 free하지 않음
        defer exports.deinit(self.allocator);
        var seen = std.StringHashMap(void).init(self.allocator);
        defer seen.deinit();
        var visited = std.AutoHashMap(u32, void).init(self.allocator);
        defer visited.deinit();
        try self.collectExportsRecursive(&exports, &seen, &visited, @enumFromInt(target_mod_idx), 0);

        var inner_map = std.StringHashMap([]const u8).init(self.allocator);
        for (exports.items) |exp| {
            try inner_map.put(exp.exported, exp.local);
        }
        try ns_rewrite_list.append(self.allocator, .{
            .symbol_id = symbol_id,
            .map = inner_map,
        });

        if (ns_inline_list) |list| {
            const obj_str = try self.buildInlineObjectStr(target_mod_idx, 0);
            // 충돌 방지: export 이름과 겹치지 않는 변수명 생성
            const ns_var_name = try self.makeUniqueNsVarName(var_name, &seen);
            try list.append(self.allocator, .{
                .symbol_id = symbol_id,
                .object_literal = obj_str,
                .var_name = ns_var_name,
            });
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
    fn buildInlineObjectStr(
        self: *const Linker,
        target_mod_idx: u32,
        depth: u32,
    ) std.mem.Allocator.Error![]const u8 {
        if (depth > max_chain_depth) return try self.allocator.dupe(u8, "{}");
        if (target_mod_idx >= self.modules.len) return try self.allocator.dupe(u8, "{}");

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
        const target = self.modules[target_mod_idx];
        var ns_re_exports = std.StringHashMap(u32).init(self.allocator); // exported_name → source_mod
        defer ns_re_exports.deinit();
        for (target.export_bindings) |eb| {
            if (eb.kind == .re_export_all and !std.mem.eql(u8, eb.exported_name, "*")) {
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

        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.allocator);
        try buf.appendSlice(self.allocator, "{");
        for (exports.items, 0..) |exp, idx| {
            if (idx > 0) try buf.appendSlice(self.allocator, ", ");
            if (std.mem.eql(u8, exp.exported, "default")) {
                try buf.appendSlice(self.allocator, "\"default\": ");
            } else {
                try buf.appendSlice(self.allocator, exp.exported);
                try buf.appendSlice(self.allocator, ": ");
            }
            // export * as ns 패턴이면 재귀 인라인
            if (ns_re_exports.get(exp.exported)) |src_mod| {
                const nested = try self.buildInlineObjectStr(src_mod, depth + 1);
                defer self.allocator.free(nested);
                try buf.appendSlice(self.allocator, nested);
            } else {
                try buf.appendSlice(self.allocator, exp.local);
            }
        }
        try buf.appendSlice(self.allocator, "}");
        return try self.allocator.dupe(u8, buf.items);
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
        if (mod_i >= self.modules.len) return;
        // diamond export * 패턴에서 동일 모듈 재방문 방지
        if (visited.contains(mod_i)) return;
        try visited.put(mod_i, {});
        const m = self.modules[mod_i];

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
            if (eb.kind == .re_export_all and std.mem.eql(u8, eb.exported_name, "*")) continue;
            if (seen.contains(eb.exported_name)) continue;
            try seen.put(eb.exported_name, {});

            const actual_local = if (eb.kind == .re_export_all and !std.mem.eql(u8, eb.exported_name, "*")) blk: {
                // export * as ns — 소스 모듈의 인라인 객체를 생성 (재귀)
                if (eb.import_record_index) |rec_idx| {
                    if (rec_idx < m.import_records.len) {
                        const src = m.import_records[rec_idx].resolved;
                        if (!src.isNone()) {
                            break :blk try self.buildInlineObjectStr(@intFromEnum(src), depth + 1);
                        }
                    }
                }
                break :blk eb.local_name;
            } else if (eb.kind == .re_export) blk: {
                if (self.resolveExportChain(module_idx, eb.exported_name, 0)) |canonical| {
                    // canonical이 export * as ns 패턴인지 확인
                    const cmod_i = @intFromEnum(canonical.module_index);
                    if (cmod_i < self.modules.len) {
                        for (self.modules[cmod_i].export_bindings) |ceb| {
                            if (ceb.kind == .re_export_all and
                                std.mem.eql(u8, ceb.exported_name, canonical.export_name) and
                                !std.mem.eql(u8, ceb.exported_name, "*"))
                            {
                                if (ceb.import_record_index) |rec_idx| {
                                    if (rec_idx < self.modules[cmod_i].import_records.len) {
                                        const src = self.modules[cmod_i].import_records[rec_idx].resolved;
                                        if (!src.isNone()) {
                                            break :blk try self.buildInlineObjectStr(@intFromEnum(src), depth + 1);
                                        }
                                    }
                                }
                            }
                        }
                    }
                    break :blk self.resolveToLocalName(canonical);
                }
                break :blk eb.local_name;
            } else blk: {
                // .local export: namespace import를 re-export하는 경우 인라인 객체 생성
                // 예: import * as X from './Module'; export { X }
                if (ns_imports.get(eb.local_name)) |rec_idx| {
                    if (rec_idx < m.import_records.len) {
                        const src = m.import_records[rec_idx].resolved;
                        if (!src.isNone()) {
                            break :blk try self.buildInlineObjectStr(@intFromEnum(src), depth + 1);
                        }
                    }
                }
                break :blk self.getCanonicalName(@intCast(mod_i), eb.local_name) orelse eb.local_name;
            };

            const safe_local = self.safeIdentifierName(actual_local, @intCast(mod_i));

            try exports.append(self.allocator, .{
                .exported = eb.exported_name,
                .local = safe_local,
                // actual_local로 체크: "{"이면 buildInlineObjectStr이 할당한 문자열.
                // safeIdentifierName은 소유권을 변경하지 않음 (canonical 참조 반환).
                .owned = actual_local.len > 0 and actual_local[0] == '{',
            });
        }

        // export * 재귀 — export * as ns는 이미 첫 루프에서 인라인 객체로 처리됨.
        // ESM 스펙: export *는 "default"를 제외 (ECMAScript 15.2.3.5).
        // seen에 "default"를 추가하여 하위 모듈의 default export가 수집되지 않도록 함.
        // 직접 선언된 export { default }는 위 첫 루프에서 이미 수집됨.
        try seen.put("default", {});
        for (m.export_bindings) |eb| {
            if (eb.kind != .re_export_all) continue;
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
        var cit = self.canonical_names.iterator();
        while (cit.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.canonical_names.clearRetainingCapacity();
        self.canonical_names_used.clearRetainingCapacity();
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
            const i = @intFromEnum(mod_idx);
            if (i >= self.modules.len) continue;
            const m = self.modules[i];
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
            const i = @intFromEnum(mod_idx);
            if (i >= self.modules.len) continue;
            try self.collectModuleNames(self.modules[i], @intCast(i), &name_to_owners);
        }

        // 2. 충돌하는 이름에 대해 리네임 계산 (cross-chunk 점유 마커는 skip)
        try self.calculateRenames(&name_to_owners, true);
    }

    const makeExportKey = types.makeModuleKey;
    const makeExportKeyBuf = types.makeModuleKeyBuf;
};

// ============================================================
// CJS preamble 헬퍼 (buildMetadataForAst에서 2곳에서 사용)
// ============================================================

/// CJS 모듈의 require_xxx 변수명을 캐시에서 가져오거나 새로 생성.
fn getOrCreateRequireVar(
    self: *const Linker,
    cache: *std.AutoHashMap(u32, []const u8),
    mod_idx: u32,
) ![]const u8 {
    if (cache.get(mod_idx)) |cached| return cached;
    const target_path = self.modules[mod_idx].path;
    const name = try types.makeRequireVarName(self.allocator, target_path);
    try cache.put(mod_idx, name);
    return name;
}

/// CJS import preamble 한 줄을 buf에 추가.
/// namespace: var local = __toESM(req_var());
/// default:   var local = __toESM(req_var()).default;
/// named:     var local = req_var().imported;
fn appendCjsImportPreamble(
    buf: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    local_name: []const u8,
    imported_name: []const u8,
    req_var: []const u8,
    is_namespace: bool,
    interop: types.Interop,
) !void {
    try buf.appendSlice(allocator, "var ");
    try buf.appendSlice(allocator, local_name);
    // Rolldown Interop: node → __toESM(req(), 1), babel → __toESM(req())
    const toesm_suffix: []const u8 = if (interop == .node) "(), 1)" else "())";
    if (is_namespace) {
        try buf.appendSlice(allocator, " = __toESM(");
        try buf.appendSlice(allocator, req_var);
        try buf.appendSlice(allocator, toesm_suffix);
        try buf.appendSlice(allocator, ";\n");
    } else if (std.mem.eql(u8, imported_name, "default")) {
        try buf.appendSlice(allocator, " = __toESM(");
        try buf.appendSlice(allocator, req_var);
        try buf.appendSlice(allocator, toesm_suffix);
        try buf.appendSlice(allocator, ".default;\n");
    } else {
        try buf.appendSlice(allocator, " = ");
        try buf.appendSlice(allocator, req_var);
        try buf.appendSlice(allocator, "().");
        try buf.appendSlice(allocator, imported_name);
        try buf.appendSlice(allocator, ";\n");
    }
}
