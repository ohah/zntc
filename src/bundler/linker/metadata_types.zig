//! Linker metadata 타입 컨테이너.

const std = @import("std");
const BundlerDiagnostic = @import("../types.zig").BundlerDiagnostic;
const ConstValue = @import("../../semantic/symbol.zig").ConstValue;

/// 크로스 모듈 심볼 참조. 어떤 모듈의 어떤 export를 가리키는지.
/// codegen에 전달하는 per-module 메타데이터.
/// AST를 수정하지 않고 codegen이 출력 시 참조.
pub const LinkingMetadata = struct {
    /// 스킵할 AST 노드 인덱스 (import_declaration, export 키워드 등)
    skip_nodes: std.DynamicBitSet,
    /// symbol_id → 새 이름. codegen이 식별자 출력 시 symbol_ids[node_idx]로 조회.
    renames: std.AutoHashMap(u32, []const u8),
    /// dev 모드(`buildDevMetadata`) 가 채우는 모듈 단위 `exports.x = x;` 문자열.
    /// scope-hoisted 번들(`buildMetadataForAst`/`buildMetadata`) 은 `final_export_entries`
    /// 를 채우고 이 필드는 null.
    final_exports: ?[]const u8,
    /// scope-hoisted 엔트리의 최종 export entry. emitter 가 포맷별 (ESM/CJS/IIFE/UMD/AMD)
    /// 로 출력할 때 사용. `local`/`exported` 는 borrowed — 모듈 parse arena 또는 symbol
    /// table 소유 (deinit 은 slice 자체만 free).
    final_export_entries: ?[]const FinalExportEntry = null,
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
    const_values: std.AutoHashMapUnmanaged(u32, ConstValue) = .{},
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

    pub const FinalExportEntry = struct {
        local: []const u8,
        exported: []const u8,

        pub fn isDefault(self: FinalExportEntry) bool {
            return std.mem.eql(u8, self.exported, "default");
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
        if (self.final_export_entries) |entries| self.allocator.free(entries);
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
