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
const semantic_symbol = @import("../semantic/symbol.zig");
const bundler_symbol = @import("symbol.zig");

/// namespace 접근 패턴에서 생성되는 변수 prefix.
/// metadata.zig, codegen.zig, emitter.zig에서 공유.
pub const NS_VAR_PREFIX = "__ns_";

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
        self.export_getter_overrides.deinit(self.allocator);
        // dev_ns_vars 해제
        if (self.dev_ns_vars) |vars| {
            for (vars) |v| self.allocator.free(v);
            self.allocator.free(vars);
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

    /// --shim-missing-exports: missing export에 대해 `var xxx = void 0;` shim 생성.
    shim_missing_exports: bool = false,

    /// computeMangling 완료 후 true. buildMetadataForAst에서 nested mangling 수행 여부 결정.
    nested_mangling_enabled: bool = false,

    /// 모듈별 중첩 스코프 바인딩 이름 집합 (사전 구축).
    /// computeRenames에서 한 번 구축, hasNestedBinding에서 O(1) 조회.
    nested_name_sets: []std.StringHashMapUnmanaged(void) = &.{},

    /// resolveExportChain 메모이제이션 캐시.
    /// 키: makeModuleKeyBuf 형식 (4바이트 module_index + 0x00 + name).
    /// Phase 1(fixpoint) + Phase 2(BFS) 간 중복 resolve를 제거.
    /// re-export chain이 있을 때만 활성화 (단순 그래프에서는 오버헤드).
    chain_cache: std.StringHashMapUnmanaged(ChainCacheEntry) = .{},
    chain_cache_enabled: bool = false,

    const ChainCacheEntry = struct {
        result: ?SymbolRef,
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
    };

    /// re-export 체인 순환 방지 깊이 제한.
    const max_chain_depth = 100;

    const BindingKey = struct {
        module_index: u32,
        span_key: u64,
    };

    pub fn init(allocator: std.mem.Allocator, modules: []const Module, format: types.Format) Linker {
        return initWithGlobalIdentifiers(allocator, modules, format, &.{});
    }

    pub fn initWithGlobalIdentifiers(allocator: std.mem.Allocator, modules: []const Module, format: types.Format, global_identifiers: []const []const u8) Linker {
        return .{
            .allocator = allocator,
            .modules = modules,
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
        self.diagnostics.deinit(self.allocator);
    }

    /// 링킹 실행: export 맵 구축 → import 바인딩 해결.
    pub fn link(self: *Linker) !void {
        try self.buildExportMap();

        // re-export chain이 있으면 resolveExportChain 캐시 활성화.
        // 단순 그래프(re-export 없음)에서는 캐시 오버헤드가 이득보다 크므로 비활성.
        for (self.modules) |m| {
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
                        if (target_idx >= self.modules.len) break :blk m.wrap_kind == .esm;
                        const target_wrap = self.modules[target_idx].wrap_kind;
                        if (m.wrap_kind == .esm) {
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
        for (self.modules) |m| {
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

                    // 새 이름: target_name$N (기존 이름 충돌 없는 것)
                    var suffix: u32 = 1;
                    const candidate = try self.findAvailableCandidate(target_name, cmod, &suffix, name_to_owners);
                    try self.putCanonicalName(cmod, export_local, candidate);
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
                try exported.put(m.exportBindingLocalName(eb), {});
            }
            for (m.import_bindings) |ib| {
                try exported.put(m.importBindingLocalName(ib), {});
            }
        }

        // top-level scope(scope_maps[0])의 심볼 reference_count를 이름별로 합산
        for (self.modules) |m| {
            const sem = m.semantic orelse continue;
            if (sem.scope_maps.len == 0) continue;
            // direct eval / with이 이 모듈 내부 어디든 있으면 top-level 바인딩도
            // 동적으로 참조될 수 있으므로 전체 스킵 (#1258). rolldown/oxc 방식.
            if (sem.scopes.len > 0 and sem.scopes[0].blocksMangling()) continue;
            var sit = sem.scope_maps[0].iterator();
            while (sit.next()) |entry| {
                const sym_name = entry.key_ptr.*;
                const sym_idx = entry.value_ptr.*;

                // mangling 제외 대상
                if (exported.contains(sym_name)) continue;
                if (sym_name.len <= 1) continue;
                if (std.mem.eql(u8, sym_name, "default")) continue;
                if (std.mem.eql(u8, sym_name, "arguments")) continue;

                const ref_count: u32 = if (sym_idx < sem.symbols.items.len) sem.symbols.items[sym_idx].reference_count else 0;
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
        // 이미 할당된 canonical 이름들도 충돌 후보에서 제외.
        for (self.canonical_strings.items) |v| {
            try all_names.put(v, {});
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

        // 3. 기존 canonical_name이 mangling 대상이면 새 이름으로 교체.
        //    canonical_symbols dirty list로 O(D) — D = calculateRenames에서 충돌로
        //    rename된 심볼 수. 전체 심볼 순회 회피.
        // 주의: dirty list를 순회하며 assignSymbolCanonical을 호출하면 list가
        //   append되므로 고정 길이만 처리.
        const dirty_count = self.canonical_symbols.items.len;
        var di: usize = 0;
        while (di < dirty_count) : (di += 1) {
            const sym = self.canonical_symbols.items[di];
            if (name_map.get(sym.canonical_name)) |mangled| {
                const dup = try self.allocator.dupe(u8, mangled);
                try self.assignSymbolCanonical(sym, dup);
            }
        }

        // 4. 아직 canonical 미설정인 top-level 심볼에 mangled 이름 적용.
        //    O(M × top-level) — top-level scope만 순회 (전체 심볼 아님).
        for (self.modules, 0..) |m, i| {
            const sem = m.semantic orelse continue;
            if (sem.scope_maps.len == 0) continue;
            var sit = sem.scope_maps[0].iterator();
            while (sit.next()) |scope_entry| {
                const sym_name = scope_entry.key_ptr.*;
                const sym_idx = scope_entry.value_ptr.*;
                if (sym_idx >= sem.symbols.items.len) continue;
                if (sem.symbols.items[sym_idx].canonical_name.len > 0) continue;
                if (name_map.get(sym_name)) |mangled| {
                    const dup = self.allocator.dupe(u8, mangled) catch continue;
                    self.putCanonicalName(@intCast(i), sym_name, dup) catch {};
                }
            }
        }

        self.nested_mangling_enabled = true;
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
        if (module_index >= self.modules.len) return null;
        const m = &self.modules[module_index];
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
        if (module_index >= self.modules.len) return false;
        const m = self.modules[module_index];
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
        const sets = try self.allocator.alloc(std.StringHashMapUnmanaged(void), self.modules.len);
        for (sets) |*s| s.* = .{};

        for (self.modules, 0..) |m, i| {
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
        if (module_index >= self.modules.len) return null;
        const eb = self.modules[module_index].findExportBinding(exported_name) orelse return null;
        return eb.local_name;
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
        if (eb.kind == .local) {
            return self.getCanonicalByRef(eb.symbol) orelse eb.local_name;
        }
        return self.getCanonicalName(module_index, eb.local_name) orelse eb.local_name;
    }

    /// SymbolRef 기반 canonical name 조회 facade. #1328 Phase 4c-3.
    /// - alias: AliasTable이 canonical_name 소유 → 직접 반환.
    /// - semantic: Symbol.canonical_name 직접 조회. 미설정 시 string map fallback
    ///   (synthetic 심볼 등 mirror 안 된 케이스).
    /// 리네임 안 됐으면 null — caller가 원본 이름으로 fallback.
    pub fn getCanonicalByRef(self: *const Linker, ref: bundler_symbol.SymbolRef) ?[]const u8 {
        if (!ref.isValid()) return null;
        const mod_i = @intFromEnum(ref.moduleIndex());
        if (mod_i >= self.modules.len) return null;
        const m = &self.modules[mod_i];
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
        const m = self.modules[mod_i];
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
        const src_idx = @intFromEnum(source_mod);
        if (src_idx < self.modules.len and self.modules[src_idx].wrap_kind == .cjs) {
            return .{ .module_index = source_mod, .export_name = name };
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

    /// SymbolRef를 scope hoisting 후 최종 로컬 이름으로 해결.
    /// resolveExportChain → getExportLocalName → getCanonicalName 3단계를 캡슐화.
    pub fn resolveToLocalName(self: *const Linker, ref: SymbolRef) []const u8 {
        const cmod: u32 = @intCast(@intFromEnum(ref.module_index));
        const local = self.getExportLocalName(cmod, ref.export_name) orelse ref.export_name;
        const canonical = self.getCanonicalName(cmod, local) orelse local;
        return self.safeIdentifierName(canonical, cmod);
    }

    /// #1328 Phase 3b: 각 모듈의 `re_export_alias` 합성 심볼에 대해 체인 resolve를
    /// 수행하고, 결과를 `canonical_name`에 저장한다. Phase 3c에서 emitter가 이 값을
    /// 직접 읽어 문자열 기반 `resolveExportChain` 호출을 제거한다.
    ///
    /// link() 이후에 호출되어야 한다 — export_map과 canonical_names가 준비된 상태를 전제.
    pub fn populateReExportAliases(self: *const Linker, modules: []Module) void {
        for (modules, 0..) |*m, idx| {
            const mod_idx: ModuleIndex = @enumFromInt(idx);
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
    pub fn populateSymbolRefCounts(_: *const Linker, modules: []Module) void {
        for (modules) |*importer| {
            for (importer.import_bindings) |ib| {
                if (!ib.symbol.isValid()) continue;
                const source_i = @intFromEnum(ib.symbol.moduleIndex());
                if (source_i >= modules.len) continue;
                switch (ib.symbol) {
                    .alias => |a| {
                        const table_ptr = if (modules[source_i].alias_table) |*t| t else continue;
                        table_ptr.incRefCount(a.symbol);
                    },
                    .semantic => |s| {
                        const sem_ptr = if (modules[source_i].semantic) |*sem| sem else continue;
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
    pub fn populateImportSymbols(_: *const Linker, modules: []Module) void {
        for (modules, 0..) |*importer, i| {
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
                            ib.local_symbol = .{ .semantic = .{
                                .module = mod_idx,
                                .symbol = @enumFromInt(@as(u32, @intCast(sym_idx))),
                            } };
                        }
                    }
                }

                // source-side: import_record 따라 source 모듈의 export 심볼 복사
                if (ib.import_record_index >= importer.import_records.len) continue;
                const source_mod_idx = importer.import_records[ib.import_record_index].resolved;
                if (source_mod_idx.isNone()) continue;
                const source_i = @intFromEnum(source_mod_idx);
                if (source_i >= modules.len) continue;
                // namespace import는 개별 심볼이 아닌 모듈 전체를 가리킴 — skip.
                if (ib.kind == .namespace) continue;
                if (modules[source_i].findExportBinding(ib.imported_name)) |eb| {
                    ib.symbol = eb.symbol;
                }
            }

            // .local export 중 binding_scanner가 채우지 않은(`_default` 합성/`re_export`
            // 외) 일반 케이스의 eb.symbol을 scope_maps[0] 조회로 채움.
            if (module_scope_opt) |module_scope| {
                for (importer.export_bindings) |*eb| {
                    if (eb.kind != .local) continue;
                    if (eb.symbol.isValid()) continue; // 이미 채워짐
                    if (module_scope.get(eb.local_name)) |sym_idx| {
                        eb.symbol = .{ .semantic = .{
                            .module = mod_idx,
                            .symbol = @enumFromInt(@as(u32, @intCast(sym_idx))),
                        } };
                    }
                }
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
    /// buildMetadataForAst 내 3곳에서 동일 패턴을 공유.
    pub fn registerNamespaceRewrites(
        self: *const Linker,
        ns_rewrite_list: *std.ArrayList(LinkingMetadata.NsMemberRewrites.Entry),
        ns_inline_list: ?*std.ArrayList(LinkingMetadata.NsInlineObjects.Entry),
        symbol_id: u32,
        target_mod_idx: u32,
        var_name: []const u8,
        ns_export_cache: *std.AutoHashMap(u32, []NsExportPair),
        ns_inline_cache: *std.AutoHashMap(u32, []const u8),
    ) std.mem.Allocator.Error!void {
        // 캐시에서 조회, 없으면 수집 후 캐시에 저장
        const cached_exports = if (ns_export_cache.get(target_mod_idx)) |cached| cached else blk: {
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
            try self.collectExportsRecursive(&exports, &seen, &visited, @enumFromInt(target_mod_idx), 0, ns_inline_cache);

            const owned_slice = try self.allocator.dupe(NsExportPair, exports.items);
            // ArrayList 백킹 해제, 슬라이스로 소유권 이동 (owned 문자열은 슬라이스가 소유)
            exports.deinit(self.allocator);
            try ns_export_cache.put(target_mod_idx, owned_slice);
            break :blk owned_slice;
        };

        // 캐시된 exports로 inner_map 구축.
        // owned 문자열은 캐시가 소유하므로, inner_map에서 사용할 복사본 생성.
        var inner_map = std.StringHashMap([]const u8).init(self.allocator);
        for (cached_exports) |exp| {
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

        if (ns_inline_list) |list| {
            const obj_str = try self.buildInlineObjectStr(target_mod_idx, 0, ns_inline_cache);
            // seen 맵 재구성 — makeUniqueNsVarName에서 export 이름 충돌 확인용
            var seen = std.StringHashMap(void).init(self.allocator);
            defer seen.deinit();
            for (cached_exports) |exp| {
                try seen.put(exp.exported, {});
            }
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
    /// ns_inline_cache가 제공되면 동일 target_mod_idx에 대한 결과를 캐싱.
    fn buildInlineObjectStr(
        self: *const Linker,
        target_mod_idx: u32,
        depth: u32,
        ns_inline_cache: ?*std.AutoHashMap(u32, []const u8),
    ) std.mem.Allocator.Error![]const u8 {
        if (depth > max_chain_depth) return try self.allocator.dupe(u8, "{}");
        if (target_mod_idx >= self.modules.len) return try self.allocator.dupe(u8, "{}");

        // 캐시 히트: 복사본 반환 (호출자가 소유권을 가짐)
        if (ns_inline_cache) |cache| {
            if (cache.get(target_mod_idx)) |cached_str| {
                return try self.allocator.dupe(u8, cached_str);
            }
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
        try self.collectExportsRecursive(&exports, &seen, &visited, @enumFromInt(target_mod_idx), 0, ns_inline_cache);

        // export * as ns 패턴 수집 (별도 처리 — 재귀 인라인 필요)
        const target = self.modules[target_mod_idx];
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
                const nested = try self.buildInlineObjectStr(src_mod, depth + 1, ns_inline_cache);
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

        // 캐시에 result를 직접 저장하고, caller에게는 별도 dupe 반환
        if (ns_inline_cache) |cache| {
            try cache.put(target_mod_idx, result);
            return try self.allocator.dupe(u8, result);
        }

        return result;
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
        ns_inline_cache: ?*std.AutoHashMap(u32, []const u8),
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
            if (eb.kind == .re_export_star) continue;
            if (seen.contains(eb.exported_name)) continue;
            try seen.put(eb.exported_name, {});

            const actual_local = if (eb.kind == .re_export_namespace) blk: {
                // export * as ns — 소스 모듈의 인라인 객체를 생성 (재귀)
                if (eb.import_record_index) |rec_idx| {
                    if (rec_idx < m.import_records.len) {
                        const src = m.import_records[rec_idx].resolved;
                        if (!src.isNone()) {
                            break :blk try self.buildInlineObjectStr(@intFromEnum(src), depth + 1, ns_inline_cache);
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
                            if (ceb.kind.isReExportAll() and
                                std.mem.eql(u8, ceb.exported_name, canonical.export_name) and
                                !std.mem.eql(u8, ceb.exported_name, "*"))
                            {
                                if (ceb.import_record_index) |rec_idx| {
                                    if (rec_idx < self.modules[cmod_i].import_records.len) {
                                        const src = self.modules[cmod_i].import_records[rec_idx].resolved;
                                        if (!src.isNone()) {
                                            break :blk try self.buildInlineObjectStr(@intFromEnum(src), depth + 1, ns_inline_cache);
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
                            break :blk try self.buildInlineObjectStr(@intFromEnum(src), depth + 1, ns_inline_cache);
                        }
                    }
                }
                break :blk self.getCanonicalByRef(eb.symbol) orelse eb.local_name;
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
            if (!eb.kind.isReExportAll()) continue;
            if (!std.mem.eql(u8, eb.exported_name, "*")) continue; // export * as ns는 skip
            if (eb.import_record_index) |rec_idx| {
                if (rec_idx < m.import_records.len) {
                    const source_mod = m.import_records[rec_idx].resolved;
                    if (!source_mod.isNone()) {
                        try self.collectExportsRecursive(exports, seen, visited, source_mod, depth + 1, ns_inline_cache);
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

    pub const makeExportKey = types.makeModuleKey;
    pub const makeExportKeyBuf = types.makeModuleKeyBuf;
};

// ============================================================
// PreambleWriter — CJS/dev preamble 생성용 구조체
// ============================================================

pub const PreambleWriter = struct {
    buf: std.ArrayList(u8) = .empty,
    allocator: std.mem.Allocator,

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
        const toesm_suffix: []const u8 = if (interop == .node) "(), 1)" else "())";
        if (is_namespace) {
            try self.write(" = __toESM(");
            try self.write(req_var);
            try self.write(toesm_suffix);
            try self.write(";\n");
        } else if (std.mem.eql(u8, imported_name, "default")) {
            try self.write(" = __toESM(");
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
    const target_path = self.modules[mod_idx].path;
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
