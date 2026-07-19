//! ESM 래퍼 (__esm) — emitEsmWrappedModule + export getter

const std = @import("std");
const types = @import("../types.zig");
const ModuleIndex = types.ModuleIndex;
const ModuleType = types.ModuleType;
const WrapKind = types.WrapKind;
const rt = @import("../runtime_helpers.zig");
const Module = @import("../module.zig").Module;
const ModuleGraph = @import("../graph.zig").ModuleGraph;
const ast_mod = @import("../../parser/ast.zig");
const Ast = ast_mod.Ast;
const NodeIndex = ast_mod.NodeIndex;
const ast_walk = @import("../../parser/ast_walk.zig");
const Transformer = @import("../../transformer/transformer.zig").Transformer;
const RuntimeHelpers = @import("../../transformer/runtime_helper_bits.zig").RuntimeHelpers;
const Codegen = @import("../../codegen/codegen.zig").Codegen;
const CodegenOptions = @import("../../codegen/codegen.zig").CodegenOptions;
const SourceMap = @import("../../codegen/sourcemap.zig");
const Linker = @import("../linker.zig").Linker;
const LinkingMetadata = @import("../linker.zig").LinkingMetadata;
const RenameTable = @import("../symbol.zig").RenameTable;
const tree_shaker_mod = @import("../tree_shaker.zig");
const TreeShaker = tree_shaker_mod.TreeShaker;
const statement_shaker = @import("../statement_shaker.zig");
const stmt_info_mod = @import("../stmt_info.zig");
const ExportBinding = @import("../binding_scanner.zig").ExportBinding;
const symbol_mod = @import("../symbol.zig");
const SymbolRef = symbol_mod.SymbolRef;
const semantic_symbol = @import("../../semantic/symbol.zig");
const parent = @import("../emitter.zig");
const EmitOptions = parent.EmitOptions;
const resolveNodeName = parent.resolveNodeName;
const needsPropertyQuote = parent.needsPropertyQuote;
const collectImportBindingNames = parent.collectImportBindingNames;
const appendRunBeforeMainCalls = parent.appendRunBeforeMainCalls;
const appendIndented = parent.appendIndented;
const appendModuleCall = parent.appendModuleCall;

/// SymbolRef가 `mod` 소유의 alias일 때 AliasId를 반환. 다른 모듈/공간이거나
/// invalid면 null. 아래 두 helper의 공통 unpack 단계.
fn localAliasId(ref: SymbolRef, mod: *const Module) ?symbol_mod.AliasId {
    return switch (ref) {
        .alias => |a| if (a.module == mod.index and !a.symbol.isNone()) a.symbol else null,
        .semantic => null,
    };
}

/// ExportBinding.symbol이 현재 모듈의 synthetic_default 심볼인지 확인.
/// 현재 모듈의 `_default = <expr>` 할당을 참조할 수 있음을 의미.
fn isSyntheticDefault(ref: SymbolRef, mod: *const Module) bool {
    return switch (ref) {
        .alias => false,
        .semantic => |s| blk: {
            if (s.module != mod.index or s.symbol.isNone()) break :blk false;
            const sem = mod.semantic orelse break :blk false;
            const idx: u32 = @intFromEnum(s.symbol);
            if (idx >= sem.symbols.items.len) break :blk false;
            const sk = sem.symbols.items[idx].synthetic_kind orelse break :blk false;
            break :blk sk == .default_export;
        },
    };
}

inline fn cjsInteropMode(options: *const EmitOptions, importer: *const Module) types.Interop {
    if (options.platform == .react_native) return .babel;
    return if (importer.def_format.isEsm()) .node else .babel;
}

/// synthetic default(`_default`)의 확정 이름. 충돌 시 linker/mangler 가 `_default$1` 등으로
/// 바꾼 것을 metadata 가 들고 있다(없으면 fallback `_default`). 값은 metadata 소유(borrow) —
/// hoisted_var_names 수집 시 dupe 불요(emitEsmWrappedModule 의 여러 site 가 이미 그렇게 쓴다).
fn defaultExportName(metadata: ?*const LinkingMetadata) []const u8 {
    return if (metadata) |md| md.default_export_name else "_default";
}

/// re_export_alias에 linker가 주입한 canonical_name을 반환. null이면
/// alias 심볼이 아니거나 linker가 resolve하지 못한 경우.
/// re-export 의 source 모듈을 resolve. resolved + non-self-cycle 인 정상 record 만 반환,
/// 그 외 (record_idx 누락 / out-of-range / resolved=none / self-cycle) 는 null.
/// 두 site (getter emit, init-call emit) 에서 공통 사용 (#2398). caller 는 반환 모듈의
/// `is_included` 를 검사해 tree-shake 제거 시 emit 생략.
inline fn resolvedReExportSource(l: *const Linker, m: *const Module, eb: ExportBinding) ?*const Module {
    const rec_idx = eb.import_record_index orelse return null;
    if (rec_idx >= m.import_records.len) return null;
    const src_idx = m.import_records[rec_idx].resolved;
    if (src_idx.isNone()) return null;
    if (src_idx == m.index) return null;
    return l.graph.getModule(src_idx);
}

/// re-export-like binding 판정. `.re_export` 로 정상 분류된 경우 + barrel alias
/// (`import X from './y'; export { X }`) 가 binding_scanner 에서 `.local` 로 정규화됐지만
/// `import_record_index` 가 남아있는 케이스 (#1321) 를 함께 catch. getter emit /
/// init-call emit / star getter resolution 세 site 에서 일관된 가드.
inline fn isReExportLike(eb: ExportBinding) bool {
    return eb.kind == .re_export or eb.import_record_index != null;
}

/// scope-hoisted re-export 의 target 모듈 + canonical name. tree-shake 로 제거된
/// source 또는 unresolved record 는 null (caller 가 getter 생략). 데이터만 반환해
/// `makeStarGetterValue` 의 inferred error set 재귀 cycle 을 회피.
const ReExportTarget = struct {
    mod: *const Module,
    index: u32,
    name: []const u8,
};

inline fn resolveReExportTarget(
    l: *const Linker,
    src_mod: *const Module,
    src_eb: ExportBinding,
) ?ReExportTarget {
    if (shouldSkipTreeShakenReExportSource(l, src_mod, src_eb)) return null;
    const rec_idx = src_eb.import_record_index orelse return null;
    if (rec_idx >= src_mod.import_records.len) return null;
    const target_idx = src_mod.import_records[rec_idx].resolved;
    if (target_idx.isNone() or target_idx == src_mod.index) return null;
    const target_mod = l.graph.getModule(target_idx) orelse return null;
    return .{
        .mod = target_mod,
        .index = @intFromEnum(target_idx),
        .name = src_mod.exportBindingLocalName(src_eb),
    };
}

inline fn shouldSkipTreeShakenReExportSource(l: *const Linker, m: *const Module, eb: ExportBinding) bool {
    if (!l.tree_shaker_active) return false;
    const rec_idx = eb.import_record_index orelse return false;
    if (rec_idx >= m.import_records.len) return false;
    const src_idx = m.import_records[rec_idx].resolved;
    if (src_idx.isNone()) return true;
    if (src_idx == m.index) return false;
    const src_mod = l.graph.getModule(src_idx) orelse return true;
    return !src_mod.is_included;
}

inline fn shouldEmitSyntheticDefaultReExport(l: ?*const Linker, m: *const Module, eb: ExportBinding) bool {
    const linker = l orelse return true;
    if (!linker.tree_shaker_active) return true;
    if (shouldSkipTreeShakenReExportSource(linker, m, eb)) return false;
    const shaker = linker.tree_shaker orelse return true;
    const module_index = m.index.toU32();
    return shaker.isExportUsed(module_index, "default") or
        shaker.isExportUsed(module_index, tree_shaker_mod.ALL_EXPORTS_SENTINEL);
}

fn reExportAliasCanonicalName(ref: SymbolRef, mod: *const Module) ?[]const u8 {
    const id = localAliasId(ref, mod) orelse return null;
    const table = mod.alias_table orelse return null;
    if (!table.hasCanonicalName(id)) return null;
    return table.getCanonicalName(id);
}

pub const EsmEmitResult = struct {
    code: []const u8,
    mappings: ?[]const SourceMap.Mapping = null,
    /// codegen builder 의 names 배열 (mangler rename 발생 시 원본 식별자 이름).
    /// `mappings[i].name_index` 가 가리키는 module-local 인덱스.
    names: []const []const u8 = &.{},
    /// `CompiledModule.entry_chain` 참조. runBeforeMain은 parent emitter가 module
    /// output 앞쪽에 직접 emit하므로 ESM-wrap 본문에는 넣지 않는다 (#3345).
    entry_chain: ?[]const u8 = null,
};

// NOTE: 본 함수의 hoisted_var_names 수집 사이트 들은 모두 `arena_alloc.dupe` 로
// `getText` (string_table slice) 와 `resolveNodeName` (metadata.renames borrowed slice)
// 을 owned 화. 둘 다 후속 처리에서 dangling 가능 (#2429: per-chunk recompute 가
// canonical_strings free).
pub fn emitEsmWrappedModule(
    allocator: std.mem.Allocator,
    arena_alloc: std.mem.Allocator,
    esm_ast: *const Ast,
    root: NodeIndex,
    module: *const Module,
    metadata: ?*const LinkingMetadata,
    linker: ?*const Linker,
    options: anytype,
) !EsmEmitResult {
    const basename = module.wrapperId();
    // RFC #3940 L.4c-2a-ii: wrapper-name 을 build-scope rename_table 경유로. parity 로 byte-identical.
    const rename_tbl: ?*const RenameTable = if (linker) |l| &l.rename_table else null;

    const init_name = try module.allocInitName(allocator, rename_tbl);
    defer allocator.free(init_name);
    const exports_name = try module.allocExportsName(allocator, rename_tbl);
    defer allocator.free(exports_name);

    // AST top-level 문장을 분류
    const root_node = esm_ast.getNode(root);
    const stmt_list = root_node.data.list;
    const all_stmts = esm_ast.extra_data.items[stmt_list.start .. stmt_list.start + stmt_list.len];

    var hoisted_stmts: std.ArrayList(u32) = .empty;
    defer hoisted_stmts.deinit(allocator);
    var body_stmts: std.ArrayList(u32) = .empty;
    defer body_stmts.deinit(allocator);
    // strict execution order: 함수 선언을 factory body 최상단에 배치.
    // body_stmts보다 먼저 emit되어 intra-module forward reference 보존.
    var body_func_stmts: std.ArrayList(u32) = .empty;
    defer body_func_stmts.deinit(allocator);
    var hoisted_var_names: std.ArrayList([]const u8) = .empty;
    defer hoisted_var_names.deinit(allocator);

    // (#4574) preserve-modules × RN downlevel: 런타임 헬퍼(`__classCallCheck` 등)를 transform 이
    // `var __classCallCheck = function(){…}` 로 인라인한 뒤, 링커가 헬퍼 모듈에서 `import
    // { __classCallCheck }` 로도 가져온다. 인라인 initializer 는 elide 되지만 variable_declaration
    // 로 hoisting 된 **이름**이 import 와 이중 선언(SyntaxError)이 된다. helper-module import 로컬명은
    // hoisted var 에서 제외한다 — import 문이 그 바인딩을 선언하므로(진짜 소스).
    var helper_import_locals: std.StringHashMapUnmanaged(void) = .empty;
    defer helper_import_locals.deinit(allocator);
    if (linker) |l| {
        const helper_modules = @import("../../runtime_helper_modules.zig");
        for (module.import_bindings) |ib| {
            if (ib.import_record_index >= module.import_records.len) continue;
            const tgt = module.import_records[ib.import_record_index].resolved;
            if (tgt.isNone()) continue;
            const tm = l.graph.getModule(tgt) orelse continue;
            if (!helper_modules.isVirtualId(tm.path)) continue;
            try helper_import_locals.put(allocator, module.importBindingLocalName(ib), {});
        }
    }

    for (all_stmts) |raw_idx| {
        const ni: NodeIndex = @enumFromInt(raw_idx);
        if (ni.isNone()) continue;
        const stmt_node = esm_ast.nodes.items[raw_idx];

        // export_named_declaration의 inner decl 추출 (있으면)
        const export_inner: ?NodeIndex = switch (stmt_node.tag) {
            .export_named_declaration => blk: {
                const ei = stmt_node.data.extra;
                if (ei < esm_ast.extra_data.items.len) {
                    const idx: NodeIndex = @enumFromInt(esm_ast.extra_data.items[ei]);
                    if (!idx.isNone()) break :blk idx;
                }
                break :blk null;
            },
            .export_default_declaration => blk: {
                const idx = stmt_node.data.unary.operand;
                if (!idx.isNone()) break :blk idx;
                break :blk null;
            },
            else => null,
        };

        const effective_tag = if (export_inner) |idx|
            esm_ast.nodes.items[@intFromEnum(idx)].tag
        else
            stmt_node.tag;

        const var_decl_extra: ?u32 = switch (stmt_node.tag) {
            .variable_declaration => stmt_node.data.extra,
            else => if (export_inner) |idx| blk: {
                const inner = esm_ast.nodes.items[@intFromEnum(idx)];
                if (inner.tag == .variable_declaration) break :blk inner.data.extra;
                break :blk null;
            } else null,
        };

        switch (effective_tag) {
            .function_declaration => {
                if (options.strict_execution_order) {
                    // strict execution order: function을 __esm factory 안에 유지하되,
                    // factory body 최상단에 배치하여 intra-module forward reference 보존.
                    // 함수명은 top-level var로 선언 (export getter 접근용).
                    // codegen이 `function foo(){}` → `foo = function(){}` 로 변환.
                    const func_node = if (export_inner) |idx|
                        esm_ast.nodes.items[@intFromEnum(idx)]
                    else
                        stmt_node;
                    const fn_name_idx: NodeIndex = @enumFromInt(esm_ast.extra_data.items[func_node.data.extra]);
                    if (!fn_name_idx.isNone()) {
                        const fn_name_node = esm_ast.nodes.items[@intFromEnum(fn_name_idx)];
                        if (fn_name_node.tag == .binding_identifier) {
                            const raw_name = try arena_alloc.dupe(u8, esm_ast.getText(fn_name_node.data.string_ref));
                            const resolved = try arena_alloc.dupe(u8, resolveNodeName(metadata, @intFromEnum(fn_name_idx), raw_name));
                            try hoisted_var_names.append(allocator, resolved);
                        }
                    } else if (stmt_node.tag == .export_default_declaration) {
                        // (#4573) 익명 `export default function(){}` — 함수명이 없어 위 분기가
                        // hoist 를 못 한다. strict 경로는 codegen 이 `_default = function(){}` 로
                        // 할당하므로(익명 class 와 동일), synthetic `_default` 를 hoist 하지 않으면
                        // `export { _default }` 가 미선언 참조(SyntaxError). RN 프리셋에서만 strict.
                        try hoisted_var_names.append(allocator, defaultExportName(metadata));
                    }
                    // body_func_stmts: factory body 최상단에 배치 → forward reference 보존
                    try body_func_stmts.append(allocator, raw_idx);
                } else {
                    // strictExecutionOrder=false: function 을 __esm factory 밖으로 호이스팅 — `function foo(){}`
                    // 선언 자체가 모듈 top-level binding 을 생성하므로 별도 `var foo` 를 추가하면 ESM 모드에서
                    // 중복 선언 에러 (bun / strict 환경). export getter 는 함수명을 직접 참조 가능.
                    try hoisted_stmts.append(allocator, raw_idx);
                }
            },
            .class_declaration => {
                // class는 block-scoped → var 호이스팅 + init 안에서 할당문으로 변환.
                const class_node_src = if (export_inner) |idx|
                    esm_ast.nodes.items[@intFromEnum(idx)]
                else
                    stmt_node;

                const class_name_idx: NodeIndex = @enumFromInt(esm_ast.extra_data.items[class_node_src.data.extra]);
                if (!class_name_idx.isNone()) {
                    const name_node = esm_ast.nodes.items[@intFromEnum(class_name_idx)];
                    if (name_node.tag == .binding_identifier) {
                        const raw_name = try arena_alloc.dupe(u8, esm_ast.getText(name_node.data.string_ref));
                        const resolved = try arena_alloc.dupe(u8, resolveNodeName(metadata, @intFromEnum(class_name_idx), raw_name));
                        try hoisted_var_names.append(allocator, resolved);
                    }
                } else if (stmt_node.tag == .export_default_declaration) {
                    // (#4573) 익명 `export default class {}` — 클래스 이름이 없어 위 분기가
                    // hoist 를 못 한다. codegen 은 body(`__esm` 클로저) 안에서 synthetic
                    // `_default = class {…}` 로 할당하므로, 그 `var _default;` 를 top-level 로
                    // hoist 하지 않으면 `export { _default }` 가 미선언 참조(SyntaxError)가 된다.
                    // value/arrow default 는 else 분기(effective_tag ∉ decl)가 이미 hoist 한다.
                    const def_name = defaultExportName(metadata);
                    try hoisted_var_names.append(allocator, def_name);
                }
                try body_stmts.append(allocator, raw_idx);
            },
            .import_declaration => {
                // var 선언만 호이스팅 (할당은 래퍼 안). linker skip된 import는 제외.
                const import_skipped = if (metadata) |md| md.skip_nodes.isSet(raw_idx) else false;
                if (!import_skipped) {
                    try collectImportBindingNames(esm_ast, stmt_node, metadata, allocator, arena_alloc, &hoisted_var_names);
                }
                try body_stmts.append(allocator, raw_idx);
            },
            .variable_declaration => {
                // 변수명 수집 (래퍼 밖 var 선언용)
                const de = var_decl_extra orelse {
                    try body_stmts.append(allocator, raw_idx);
                    continue;
                };
                const dextras = esm_ast.extra_data.items[de .. de + 3];
                const decl_list_start = dextras[1];
                const decl_list_len = dextras[2];
                const declarators = esm_ast.extra_data.items[decl_list_start .. decl_list_start + decl_list_len];
                for (declarators) |decl_raw| {
                    const decl = esm_ast.nodes.items[decl_raw];
                    const de2 = decl.data.extra;
                    const name_raw: NodeIndex = @enumFromInt(esm_ast.extra_data.items[de2]);
                    const name_node = esm_ast.nodes.items[@intFromEnum(name_raw)];
                    if (name_node.tag == .binding_identifier) {
                        const raw_name = try arena_alloc.dupe(u8, esm_ast.getText(name_node.data.string_ref));
                        const resolved = try arena_alloc.dupe(u8, resolveNodeName(metadata, @intFromEnum(name_raw), raw_name));
                        try hoisted_var_names.append(allocator, resolved);
                    } else {
                        var it = try ast_walk.bindingIdentifiers(allocator, esm_ast, name_raw, .{});
                        defer it.deinit();
                        while (try it.next()) |bind_idx| {
                            const bind_node = esm_ast.nodes.items[@intFromEnum(bind_idx)];
                            if (bind_node.tag != .binding_identifier) continue;
                            const raw_name = try arena_alloc.dupe(u8, esm_ast.getText(bind_node.data.string_ref));
                            const resolved = try arena_alloc.dupe(u8, resolveNodeName(metadata, @intFromEnum(bind_idx), raw_name));
                            try hoisted_var_names.append(allocator, resolved);
                        }
                    }
                }
                // body에 넣어서 할당문으로 변환
                try body_stmts.append(allocator, raw_idx);
            },
            .ts_enum_declaration => {
                // TS enum → IIFE. codegen이 `var Name = ((Name) => {...})(Name || {})` 출력.
                // __esm factory 밖 top-level에 var Name; 선언 필요.
                const enum_node_src = if (export_inner) |idx|
                    esm_ast.nodes.items[@intFromEnum(idx)]
                else
                    stmt_node;
                const enum_name_idx: NodeIndex = @enumFromInt(esm_ast.extra_data.items[enum_node_src.data.extra]);
                if (!enum_name_idx.isNone()) {
                    const ename_node = esm_ast.nodes.items[@intFromEnum(enum_name_idx)];
                    if (ename_node.tag == .binding_identifier) {
                        const raw_name = try arena_alloc.dupe(u8, esm_ast.getText(ename_node.data.string_ref));
                        const resolved = try arena_alloc.dupe(u8, resolveNodeName(metadata, @intFromEnum(enum_name_idx), raw_name));
                        try hoisted_var_names.append(allocator, resolved);
                    }
                }
                try body_stmts.append(allocator, raw_idx);
            },
            else => {
                // effective_tag는 내부 노드의 태그이므로 export_default_declaration은
                // 이 분기에 도달한다. stmt_node.tag로 원본 태그를 확인하여 호이스팅.
                if (stmt_node.tag == .export_default_declaration) {
                    const def_name = defaultExportName(metadata);
                    try hoisted_var_names.append(allocator, def_name);
                }
                try body_stmts.append(allocator, raw_idx);
            },
        }
    }

    // `export { default } from './x'` 같은 순수 re-export도 body에서 `_default = <chain>`
    // 할당을 만들어내므로 hoisted_var 선언 필요. symbol table에 synthetic_default가
    // 등록돼 있으면 _default 변수가 실제로 emit된다는 뜻.
    {
        for (module.export_bindings) |eb| {
            if (eb.kind == .re_export and eb.hasSyntheticDefault(module.semanticSymbols())) {
                if (!shouldEmitSyntheticDefaultReExport(linker, module, eb)) continue;
                const def_name = defaultExportName(metadata);
                try hoisted_var_names.append(allocator, def_name);
                break;
            }
        }
    }

    // helper marker import binding (JSX runtime / runtime helper): top-level 에
    // var 선언이 필요. preamble 은 __esm init 블록 안에 삽입되므로, `var _jsxDEV = ...`
    // 형태면 호이스팅된 함수에서 접근 불가 (#1209). `var _jsxDEV;` 를 top-level 에
    // 선언하고 init 안에서 `_jsxDEV = ...` (할당만) 으로 처리.
    for (module.import_bindings) |ib| {
        if (ib.is_helper) {
            const hoist_name = if (linker) |l|
                l.getCanonicalByRef(ib.local_symbol) orelse module.importBindingLocalName(ib)
            else
                module.importBindingLocalName(ib);
            try hoisted_var_names.append(allocator, try arena_alloc.dupe(u8, hoist_name));
        }
    }

    // dev 모드 namespace 변수 호이스팅: named import를 namespace 접근 패턴으로
    // 전환할 때 __ns_N 변수를 __esm 바깥에 선언해야 호이스팅된 함수에서 접근 가능.
    if (metadata) |md| {
        if (md.dev_ns_vars) |ns_vars| {
            for (ns_vars) |ns_var| {
                try hoisted_var_names.append(allocator, ns_var);
            }
        }
    }

    // codegen 공통 옵션
    const cg_linking = if (metadata) |m| @as(?*const LinkingMetadata, m) else null;

    var wrapped: std.ArrayList(u8) = .empty;
    defer wrapped.deinit(allocator);

    // 1. exports namespace 객체
    try wrapped.appendSlice(allocator, "var ");
    try wrapped.appendSlice(allocator, exports_name);
    try wrapped.appendSlice(allocator, " = {};\n");

    // 2. 호이스팅된 var 선언 (중복 제거: import binding과 export default가 같은 심볼을 가리킬 수 있음)
    if (hoisted_var_names.items.len > 0) {
        var dedup_count: usize = 0;
        for (hoisted_var_names.items) |name| {
            const is_dup = for (hoisted_var_names.items[0..dedup_count]) |prev| {
                if (std.mem.eql(u8, prev, name)) break true;
            } else false;
            // (#4574) helper-module import 로컬명은 import 문이 선언 → hoisted var 중복 제거.
            if (is_dup or helper_import_locals.contains(name)) continue;
            hoisted_var_names.items[dedup_count] = name;
            dedup_count += 1;
        }
        hoisted_var_names.shrinkRetainingCapacity(dedup_count);

        try wrapped.appendSlice(allocator, "var ");
        for (hoisted_var_names.items, 0..) |name, i| {
            if (i > 0) try wrapped.appendSlice(allocator, ", ");
            try wrapped.appendSlice(allocator, name);
        }
        try wrapped.appendSlice(allocator, ";\n");
    }

    // 3. 호이스팅된 function 선언 (rolldown 방식: canonical 변수 직접 참조)
    var hoist_mappings: ?[]const SourceMap.Mapping = null;
    var hoist_names: []const []const u8 = &.{};
    var hoist_preamble_lines: u32 = 0;
    if (hoisted_stmts.items.len > 0) {
        var hoist_cg = Codegen.initWithOptions(arena_alloc, esm_ast, .{
            .minify_whitespace = options.minify_whitespace,
            .minify_syntax = options.minify_syntax,
            .module_format = .cjs,
            .skip_cjs_exports = true,
            .use_var_for_imports = true,
            .linking_metadata = cg_linking,
            .replace_import_meta = options.format != .esm,
            .platform = options.platform,
            .sourcemap = options.sourcemap.enable,
            .source_root = options.sourcemap.source_root orelse "",
            .sources_content = options.sourcemap.sources_content,
            .import_records = module.import_records,
            .require_context_module_id_root = options.root_dir,
            .assert_no_raw_private_syntax = options.unsupported.requiresPrivateDownlevel(),
        });
        if (options.sourcemap.enable) {
            hoist_cg.line_offsets = module.line_offsets;
            try hoist_cg.addSourceFile(parent.sourcemapSourcePath(module.path, options));
        }
        hoist_preamble_lines = @intCast(std.mem.count(u8, wrapped.items, "\n"));
        const hoisted_code = try hoist_cg.generateStatements(root, hoisted_stmts.items);
        try wrapped.appendSlice(allocator, hoisted_code);
        // 호이스팅 매핑 수집
        if (hoist_cg.sm_builder) |*sm| {
            if (sm.mappings.items.len > 0) {
                hoist_mappings = sm.mappings.items;
            }
            hoist_names = sm.names.items;
        }
    }

    // 4. __export (lazy getter — 호이스팅된 변수를 참조하므로 래퍼 밖에서 안전)
    //
    // export * from 처리:
    //   re_export_all 바인딩(exported_name == "*")을 소스 모듈의 wrap_kind에 따라 확장:
    //   - wrap_kind == .none (scope-hoisted): getter가 canonical 로컬 변수를 직접 참조
    //   - wrap_kind == .esm: getter가 exports_source.name을 참조
    //   - wrap_kind == .cjs: getter가 require_source().name을 참조
    //   ESM 스펙에 따라 "default"는 제외.
    {
        // star re-export 중복 방지용
        var direct_exports: std.StringHashMapUnmanaged(void) = .empty;
        defer direct_exports.deinit(allocator);
        for (module.export_bindings) |eb| {
            if (eb.kind == .local or eb.kind == .re_export) {
                try direct_exports.put(allocator, eb.exported_name, {});
            }
        }

        // star re-export 엔트리 수집
        // getter_value: 소스 wrap_kind에 따라 다름
        //   .none  → "foo"           (canonical 로컬 변수)
        //   .esm   → "exports_x.foo" (exports 객체 프로퍼티)
        //   .cjs   → "require_x().foo"
        const StarEntry = struct { name: []const u8, getter_value: []const u8 };
        var star_entries: std.ArrayList(StarEntry) = .empty;
        defer star_entries.deinit(allocator);
        var star_owned: std.ArrayList([]const u8) = .empty;
        defer {
            for (star_owned.items) |s| allocator.free(s);
            star_owned.deinit(allocator);
        }

        if (linker) |l| {
            // seen/visited는 루프 밖에서 할당하여 재사용 (export * from이 여러 개일 때 할당 절약)
            var seen: std.StringHashMapUnmanaged(void) = .empty;
            defer seen.deinit(allocator);
            var visited: std.AutoHashMapUnmanaged(u32, void) = .empty;
            defer visited.deinit(allocator);
            var sorted_names: std.ArrayList([]const u8) = .empty;
            defer sorted_names.deinit(allocator);

            for (module.export_bindings) |eb| {
                if (!eb.kind.isReExportAll()) continue;
                const rec_idx = eb.import_record_index orelse continue;
                if (rec_idx >= module.import_records.len) continue;
                const source_mod_idx = module.import_records[rec_idx].resolved;
                if (source_mod_idx.isNone()) continue;
                const src_i = @intFromEnum(source_mod_idx);
                const src_mod = l.graph.getModule(source_mod_idx) orelse continue;

                if (std.mem.eql(u8, eb.exported_name, "*")) {
                    seen.clearRetainingCapacity();
                    visited.clearRetainingCapacity();
                    try collectStarExportNames(allocator, l, src_i, &seen, &visited);

                    // hashmap 순회는 비결정 — 사전순 정렬 후 emit 해 namespace getter 출현 순서 결정.
                    sorted_names.clearRetainingCapacity();
                    var it = seen.iterator();
                    while (it.next()) |entry| {
                        try sorted_names.append(allocator, entry.key_ptr.*);
                    }
                    std.mem.sort([]const u8, sorted_names.items, {}, types.stringLessThan);

                    for (sorted_names.items) |name| {
                        if (std.mem.eql(u8, name, "default")) continue;
                        if (direct_exports.contains(name)) continue;

                        const getter_val = (try makeStarGetterValue(allocator, l, src_mod, src_i, name, options)) orelse continue;
                        try star_owned.append(allocator, getter_val);
                        try star_entries.append(allocator, .{
                            .name = name,
                            .getter_value = getter_val,
                        });
                        try direct_exports.put(allocator, name, {});
                    }
                } else {
                    // export * as ns from './dep' → namespace re-export
                    // getter는 소스 모듈의 exports 객체 자체를 참조
                    const getter_val = switch (src_mod.wrap_kind) {
                        .esm, .none => try makeNamespaceGetterValue(allocator, src_mod, options, rename_tbl),
                        .cjs => try allocCjsRequireCall(allocator, src_mod, options, rename_tbl),
                    };
                    try star_owned.append(allocator, getter_val);
                    if (!direct_exports.contains(eb.exported_name)) {
                        try star_entries.append(allocator, .{
                            .name = eb.exported_name,
                            .getter_value = getter_val,
                        });
                        try direct_exports.put(allocator, eb.exported_name, {});
                    }
                }
            }
        }

        if (direct_exports.count() > 0 or star_entries.items.len > 0) {
            // #1621: minify 시 __export → $x 축약.
            const export_name: []const u8 = if (options.minify_whitespace) rt.NAMES.EXPORT_MIN else "__export";
            try wrapped.appendSlice(allocator, export_name);
            try wrapped.appendSlice(allocator, "(");
            try wrapped.appendSlice(allocator, exports_name);
            try wrapped.appendSlice(allocator, ", {\n");

            for (module.export_bindings) |eb| {
                if (eb.kind == .local or eb.kind == .re_export) {
                    // tree-shake 로 제거된 re-export source 의 getter 는 dangling reference (#2398).
                    // Tree-shaker가 사용되지 않는 re-export source를 그래프에서 제외하면
                    // import record의 resolved가 none이 될 수 있다. 이 상태에서 getter를
                    // 만들면 `export { default as X } from`의 local name인 `default`가
                    // 값 위치에 남아 Hermes release parse에서 `return default;`가 된다.
                    if (isReExportLike(eb)) skip: {
                        const l = linker orelse break :skip;
                        if (shouldSkipTreeShakenReExportSource(l, module, eb)) continue;
                    }
                    // local export 의 declaration 이 tree-shaken 이면 namespace getter
                    // skip — 안 그러면 dangling reference 가 namespace object 안에 남고,
                    // 그 binding 은 emit 안 되어 mangle 가드도 함께 long source name 으로
                    // 남게 되어 size 회귀.
                    if (eb.kind == .local and !module.isLocalBindingAlive(module.exportBindingLocalName(eb))) continue;
                    try appendExportGetter(&wrapped, allocator, eb.exported_name, blk: {
                        // Symbol table이 단축 경로의 source of truth.
                        // binding_scanner가 `_default = <expr>`가 실제로 emit되는 default만
                        // synthetic_default로 표시하고, 나머지 re-export는 re_export_alias로
                        // 표현 → linker가 canonical_name을 채운다. barrel `export { X }`같은
                        // kind 오분류에도 영향받지 않음 (#1321 방어).
                        if (isSyntheticDefault(eb.symbol, module)) {
                            break :blk defaultExportName(metadata);
                        }
                        // direct re-export는 현재 모듈에 로컬 변수가 선언되지 않으므로
                        // source module의 getter/value를 직접 참조해야 한다 (#1425).
                        // barrel alias(`import X from './y'; export { X }`)는 binding_scanner가
                        // .re_export + local_name=ib.imported_name으로 정규화하므로(#1321),
                        // 매칭되는 import binding이 있으면 기존 경로로 폴백.
                        if (isReExportLike(eb)) re_export: {
                            const l = linker orelse break :re_export;
                            const rec_idx = eb.import_record_index orelse break :re_export;
                            if (rec_idx >= module.import_records.len) break :re_export;
                            const src_idx = module.import_records[rec_idx].resolved;
                            if (src_idx.isNone()) break :re_export;
                            // self-cycle 폴백: graph가 진단으로 거부했지만 codegen이 호출되어도
                            // 자기 참조 getter를 만들지 않도록.
                            if (src_idx == module.index) break :re_export;
                            const si = @intFromEnum(src_idx);
                            const src_mod = l.graph.getModule(src_idx) orelse break :re_export;

                            const local_name = module.exportBindingLocalName(eb);
                            const exported_local_name = if (module.ast) |*module_ast|
                                module_ast.getText(eb.local_span)
                            else
                                local_name;
                            for (module.import_bindings) |ib| {
                                if (ib.import_record_index != rec_idx) continue;
                                if (std.mem.eql(u8, ib.imported_name, local_name) or
                                    std.mem.eql(u8, ib.local_name, exported_local_name) or
                                    (std.mem.eql(u8, local_name, "default") and
                                        std.mem.eql(u8, ib.local_name, eb.exported_name)))
                                {
                                    // `import Path from './Path'; export { Path };`
                                    // 형태의 alias barrel 은 RN ESM wrap 에서 현재 모듈에
                                    // 실제 local storage 를 남기지 않는다. Non-CJS source 는
                                    // source module getter/local 에서 직접 읽어야 한다. CJS
                                    // default interop 은 현재 모듈 local binding 을 만들기 때문에
                                    // 기존 경로를 유지해야 한다.
                                    if (src_mod.wrap_kind != .cjs) {
                                        const getter_val = (try makeStarGetterValue(allocator, l, src_mod, si, ib.imported_name, options)) orelse continue;
                                        try star_owned.append(allocator, getter_val);
                                        break :blk getter_val;
                                    }
                                    break :blk l.getCanonicalByRef(ib.local_symbol) orelse module.importBindingLocalName(ib);
                                }
                            }

                            const getter_val = (try makeStarGetterValue(allocator, l, src_mod, si, local_name, options)) orelse continue;
                            try star_owned.append(allocator, getter_val);
                            break :blk getter_val;
                        }
                        // Some default-import alias barrels can remain `.local`
                        // because the export points at the importer-side semantic
                        // symbol. In RN ESM wrap the import declaration is still
                        // removed, so its getter must not return the importer-side
                        // renamed symbol either.
                        if (eb.kind == .local) imported_local: {
                            const l = linker orelse break :imported_local;
                            const exported_local_name = if (module.ast) |*module_ast|
                                module_ast.getText(eb.local_span)
                            else
                                module.exportBindingLocalName(eb);
                            for (module.import_bindings) |ib| {
                                if (!std.mem.eql(u8, ib.local_name, exported_local_name) and
                                    !std.mem.eql(u8, ib.local_name, eb.exported_name))
                                    continue;
                                if (ib.kind == .namespace) break :imported_local;
                                if (ib.import_record_index >= module.import_records.len) break :imported_local;
                                const src_idx = module.import_records[ib.import_record_index].resolved;
                                if (src_idx.isNone() or src_idx == module.index) break :imported_local;
                                const src_i = @intFromEnum(src_idx);
                                const src_mod = l.graph.getModule(src_idx) orelse break :imported_local;
                                if (src_mod.wrap_kind == .cjs) break :imported_local;
                                const getter_val = (try makeStarGetterValue(allocator, l, src_mod, src_i, ib.imported_name, options)) orelse continue;
                                try star_owned.append(allocator, getter_val);
                                break :blk getter_val;
                            }
                        }
                        if (reExportAliasCanonicalName(eb.symbol, module)) |canon| {
                            break :blk canon;
                        }
                        const local_name = module.exportBindingLocalName(eb);
                        // live binding override: import binding이 canonical name으로 변경된 경우
                        if (metadata) |md| {
                            if (md.export_getter_overrides.get(local_name)) |override|
                                break :blk override;
                        }
                        if (linker) |l| {
                            const mi: u32 = module.index.toU32();
                            if (l.getCanonicalName(mi, local_name)) |renamed|
                                break :blk renamed;
                        }
                        break :blk local_name;
                    }, options);
                }
            }
            for (star_entries.items) |entry| {
                try appendExportGetter(&wrapped, allocator, entry.name, entry.getter_value, options);
            }

            try wrapped.appendSlice(allocator, "});\n");
        }

        // (#3975) `export * from <CJS>`: CJS 는 정적 export_bindings 가 없어 위 getter
        // 열거로 안 잡힌다. wrapped 모듈의 exports 객체에 CJS 동적 멤버를 런타임 복사
        // (`__copyProps(exports_x, require_cjs())`) → `import * as ns`(__toESM(exports))·
        // named re-import 모두 CJS 멤버를 본다. esbuild __reExport 대응. plain CJS 는
        // default 키가 없어 default 누출 없음(`export *` 는 default 비전파, spec 일치).
        if (linker) |l| {
            for (module.export_bindings) |eb| {
                if (!(eb.kind.isReExportAll() and std.mem.eql(u8, eb.exported_name, "*"))) continue;
                const rec_idx = eb.import_record_index orelse continue;
                if (rec_idx >= module.import_records.len) continue;
                const src_idx = module.import_records[rec_idx].resolved;
                if (src_idx.isNone()) continue;
                const src_mod = l.graph.getModule(src_idx) orelse continue;
                if (src_mod.wrap_kind != .cjs) continue;
                const copy_props: []const u8 = if (options.minify_whitespace) rt.NAMES.COPY_PROPS_MIN else "__copyProps";
                try wrapped.appendSlice(allocator, copy_props);
                try wrapped.appendSlice(allocator, "(");
                try wrapped.appendSlice(allocator, exports_name);
                try wrapped.appendSlice(allocator, ", ");
                // direct-buf: dev_split 만 registry, 그 외는 원래 lexical append 경계 유지(byte-identical).
                if (options.isDevSplit()) {
                    try wrapped.appendSlice(allocator, "__zntc_modules[\"");
                    try wrapped.appendSlice(allocator, src_mod.dev_id);
                    try wrapped.appendSlice(allocator, "\"].fn());\n");
                } else {
                    const rv = try src_mod.allocRequireName(allocator, rename_tbl);
                    defer allocator.free(rv);
                    try wrapped.appendSlice(allocator, rv);
                    try wrapped.appendSlice(allocator, "());\n");
                }
            }
        }
    }

    // 5. body codegen (variable_declaration/class → 할당문만)
    // func_code의 sourcemap 매핑을 병합 단계까지 보존 (호이스팅된 함수 정의 매핑, #1315)
    var func_mappings: ?[]const SourceMap.Mapping = null;
    var func_names: []const []const u8 = &.{};
    var func_preamble_lines: u32 = 0;
    var body_cg = Codegen.initWithOptions(arena_alloc, esm_ast, .{
        .minify_whitespace = options.minify_whitespace,
        .minify_syntax = options.minify_syntax,
        .module_format = .cjs,
        .skip_cjs_exports = true,
        .use_var_for_imports = true,
        .esm_var_assign_only = true,
        .linking_metadata = cg_linking,
        .replace_import_meta = options.format != .esm,
        .platform = options.platform,
        .keep_names = options.keep_names,
        .sourcemap = options.sourcemap.enable,
        .source_root = options.sourcemap.source_root orelse "",
        .sources_content = options.sourcemap.sources_content,
        .import_records = module.import_records,
        .require_context_module_id_root = options.root_dir,
        .assert_no_raw_private_syntax = options.unsupported.requiresPrivateDownlevel(),
    });
    // 소스맵: 소스 파일 등록 + line_offsets 설정
    if (options.sourcemap.enable) {
        body_cg.line_offsets = module.line_offsets;
        try body_cg.addSourceFile(parent.sourcemapSourcePath(module.path, options));
    }
    // strict execution order: 함수 선언을 body 최상단에 배치 (forward reference 보존)
    var func_code: []const u8 = "";
    if (body_func_stmts.items.len > 0) {
        var func_cg = Codegen.initWithOptions(arena_alloc, esm_ast, .{
            .minify_whitespace = options.minify_whitespace,
            .minify_syntax = options.minify_syntax,
            .module_format = .cjs,
            .skip_cjs_exports = true,
            .use_var_for_imports = true,
            .esm_var_assign_only = true,
            .linking_metadata = cg_linking,
            .replace_import_meta = options.format != .esm,
            .platform = options.platform,
            .keep_names = options.keep_names,
            .sourcemap = options.sourcemap.enable,
            .source_root = options.sourcemap.source_root orelse "",
            .sources_content = options.sourcemap.sources_content,
            .import_records = module.import_records,
            .require_context_module_id_root = options.root_dir,
            .assert_no_raw_private_syntax = options.unsupported.requiresPrivateDownlevel(),
        });
        if (options.sourcemap.enable) {
            func_cg.line_offsets = module.line_offsets;
            try func_cg.addSourceFile(parent.sourcemapSourcePath(module.path, options));
        }
        func_code = try func_cg.generateStatements(root, body_func_stmts.items);
        if (func_cg.sm_builder) |*sm| {
            if (sm.mappings.items.len > 0) func_mappings = sm.mappings.items;
            func_names = sm.names.items;
        }
    }
    var body_code = try body_cg.generateStatements(root, body_stmts.items);

    // 5.1. Hermes 호환: hoisted var와 같은 이름의 named function expression 이름 제거.
    // Hermes는 "X = function X() {...}" 에서 named function expression의 이름 X가
    // 외부 스코프의 X 변수를 덮어쓰는 비표준 동작을 보임.
    // "= function NAME(" → "= function(" 으로 변환하여 이름 충돌 방지.
    for (hoisted_var_names.items) |hv_name| {
        // 리네이밍된 이름(Performance$1)에서 base name(Performance)을 추출하여 검색.
        // body_code는 리네이밍 전 원본 이름을 사용하므로 base name으로 매칭해야 함.
        const base_name = if (std.mem.indexOfScalar(u8, hv_name, '$')) |dollar| hv_name[0..dollar] else hv_name;
        const needle = try std.fmt.allocPrint(arena_alloc, "= function {s}(", .{base_name});
        const replacement = "= function(";
        var pos: usize = 0;
        while (std.mem.indexOf(u8, body_code[pos..], needle)) |rel| {
            const abs_start = pos + rel;
            // needle을 replacement로 교체 (길이가 다르므로 새 버퍼 필요)
            const new_code = try std.fmt.allocPrint(arena_alloc, "{s}{s}{s}", .{
                body_code[0..abs_start],
                replacement,
                body_code[abs_start + needle.len ..],
            });
            body_code = new_code;
            pos = abs_start + replacement.len;
        }
    }

    // 5.2. re-export default 할당문 생성.
    // export { default } from / export { default as X } from re-export는
    // import_bindings를 생성하지 않으므로 body codegen에서 할당문이 누락됨.
    // 소스 모듈의 wrap_kind에 따라 적절한 할당문을 직접 생성.
    var reexport_buf: std.ArrayList(u8) = .empty;
    defer reexport_buf.deinit(allocator);
    for (module.export_bindings) |eb| {
        if (eb.kind != .re_export) continue;
        if (!eb.hasSyntheticDefault(module.semanticSymbols())) continue;
        if (!shouldEmitSyntheticDefaultReExport(linker, module, eb)) continue;
        const rec_idx = eb.import_record_index orelse continue;
        if (rec_idx >= module.import_records.len) continue;
        const source_mod_idx = module.import_records[rec_idx].resolved;
        if (source_mod_idx.isNone()) continue;
        // 자기 자신을 re-export하는 경우 skip (자기참조 init 호출 방지)
        if (source_mod_idx == module.index) continue;

        const def_name = defaultExportName(metadata);
        const source_mod_i = @intFromEnum(source_mod_idx);

        if (linker) |l| {
            if (l.graph.getModule(source_mod_idx)) |source_mod| {
                const eq = if (options.minify_whitespace) "=" else " = ";

                try reexport_buf.appendSlice(allocator, def_name);
                try reexport_buf.appendSlice(allocator, eq);

                switch (source_mod.wrap_kind) {
                    .none => {
                        const src_name = l.getCanonicalName(@intCast(source_mod_i), "_default") orelse "_default";
                        try reexport_buf.appendSlice(allocator, src_name);
                    },
                    .esm => {
                        if (source_mod.uses_top_level_await) {
                            try reexport_buf.appendSlice(allocator, "(await ");
                        } else {
                            try reexport_buf.appendSlice(allocator, "(");
                        }
                        // dev 레지스트리 lowering([[useDevModuleRegistry]]) — dev_split 도 글로벌
                        // 레지스트리로 크로스청크 default re-export 해석(lexical init_X/exports_X 는
                        // 정의자 청크 스코프라 크로스청크 ReferenceError).
                        if (options.useDevModuleRegistry()) {
                            try reexport_buf.appendSlice(allocator, "__zntc_modules[\"");
                            try reexport_buf.appendSlice(allocator, source_mod.dev_id);
                            try reexport_buf.appendSlice(allocator, "\"].fn(), __toCommonJS(__zntc_modules[\"");
                            try reexport_buf.appendSlice(allocator, source_mod.dev_id);
                            try reexport_buf.appendSlice(allocator, "\"].exports))");
                        } else {
                            const iv = try source_mod.allocInitName(allocator, rename_tbl);
                            defer allocator.free(iv);
                            const ev = try source_mod.allocExportsName(allocator, rename_tbl);
                            defer allocator.free(ev);
                            // #1621: minify 시 __toCommonJS → $tC 축약.
                            const to_cjs_name: []const u8 = if (options.minify_whitespace) rt.NAMES.TOCOMMONJS_MIN else "__toCommonJS";
                            try reexport_buf.appendSlice(allocator, iv);
                            try reexport_buf.appendSlice(allocator, "(), ");
                            try reexport_buf.appendSlice(allocator, to_cjs_name);
                            try reexport_buf.appendSlice(allocator, "(");
                            try reexport_buf.appendSlice(allocator, ev);
                            try reexport_buf.appendSlice(allocator, "))");
                        }
                        try reexport_buf.appendSlice(allocator, ".default");
                    },
                    .cjs => {
                        // preamble에서 이미 __toESM으로 바인딩된 변수가 있으면
                        // 중복 require 호출 없이 해당 변수를 참조한다.
                        var found_preamble_var: ?[]const u8 = null;
                        for (module.import_bindings) |ib| {
                            if (ib.import_record_index == rec_idx and ib.importsDefault()) {
                                found_preamble_var = l.getCanonicalByRef(ib.local_symbol) orelse module.importBindingLocalName(ib);
                                break;
                            }
                        }
                        if (found_preamble_var) |pv| {
                            try reexport_buf.appendSlice(allocator, pv);
                        } else {
                            const interop_mode = cjsInteropMode(options, module);
                            // #1621: minify 시 __toESM → $tE 축약.
                            const to_esm_name: []const u8 = if (options.minify_whitespace) rt.NAMES.TOESM_MIN else "__toESM";
                            try reexport_buf.appendSlice(allocator, to_esm_name);
                            try reexport_buf.appendSlice(allocator, "(");
                            // direct-buf: dev_split 만 registry, 그 외는 원래 lexical append 경계 유지.
                            if (options.isDevSplit()) {
                                try reexport_buf.appendSlice(allocator, "__zntc_modules[\"");
                                try reexport_buf.appendSlice(allocator, source_mod.dev_id);
                                try reexport_buf.appendSlice(allocator, "\"].fn()");
                            } else {
                                const rv = try source_mod.allocRequireName(allocator, rename_tbl);
                                defer allocator.free(rv);
                                try reexport_buf.appendSlice(allocator, rv);
                                try reexport_buf.appendSlice(allocator, "()");
                            }
                            if (interop_mode == .node) {
                                try reexport_buf.appendSlice(allocator, ", 1).default");
                            } else {
                                try reexport_buf.appendSlice(allocator, ").default");
                            }
                        }
                    },
                }
                try reexport_buf.appendSlice(allocator, ";\n");
            }
        }
        break; // default re-export는 모듈당 하나만 존재
    }

    // 5.3. re-export 소스 모듈 init/require 호출 생성.
    // re_export, re_export_all 모두 import_bindings를 만들지 않으므로 linker preamble에 포함되지 않는다.
    // __esm body에서 소스 모듈을 초기화해야 lazy getter가 올바른 값을 반환하고,
    // 호이스팅된 함수가 참조하는 import binding이 init 시점에 할당된다.
    var star_init_buf: std.ArrayList(u8) = .empty;
    defer star_init_buf.deinit(allocator);
    if (linker) |l| {
        // 중복 init 방지 (같은 소스 모듈에 대해 여러 re-export가 있을 수 있음)
        var re_export_inited: std.AutoHashMapUnmanaged(u32, void) = .empty;
        defer re_export_inited.deinit(allocator);

        for (module.export_bindings) |eb| {
            if (!eb.kind.isReExportAll() and eb.kind != .re_export) continue;
            const rec_idx = eb.import_record_index orelse continue;
            if (rec_idx >= module.import_records.len) continue;
            const source_mod_idx = module.import_records[rec_idx].resolved;
            if (source_mod_idx.isNone()) continue;
            const src_i = @intFromEnum(source_mod_idx);
            const src_mod_ptr = l.graph.getModule(source_mod_idx) orelse continue;
            if (re_export_inited.contains(src_i)) continue;
            // tree-shake 로 제거된 source 의 init 호출은 dangling reference (#2398).
            // dev_mode 등 tree-shaker 미동작 환경은 is_included 비트 신뢰 불가라
            // tree_shaker_active 게이트 (metadata.zig:408,438 동일 정책).
            if (l.tree_shaker_active and !src_mod_ptr.is_included) continue;
            re_export_inited.put(allocator, src_i, {}) catch {};
            if (shouldLazyReExportInit(options, src_mod_ptr)) continue;

            try appendWrappedInitCall(&star_init_buf, allocator, src_mod_ptr, options, rename_tbl);
        }

        // Side-effect-only import (`import './x';`) → target이 ESM 래핑일 때만
        // barrel의 preamble에 init 호출을 추가한다. export_bindings에는 포함되지
        // 않아 기존 re-export loop가 건너뛰기 때문.
        // CJS 타겟은 body rewrite가 이미 `require_xxx()`를 주입하므로 제외 (중복 방지).
        // 누락 시 RN 런타임에서 target 모듈의 top-level이 실행되지 않아
        // global setup(예: Reanimated LayoutAnimationsManager) 실패 (#1193).
        for (module.import_records) |rec| {
            if (rec.kind != .side_effect) continue;
            if (rec.resolved.isNone()) continue;
            const src_i = @intFromEnum(rec.resolved);
            const src_mod = l.graph.getModule(rec.resolved) orelse continue;
            if (re_export_inited.contains(src_i)) continue;
            if (src_mod.wrap_kind != .esm) continue;
            re_export_inited.put(allocator, src_i, {}) catch {};

            try appendWrappedInitCall(&star_init_buf, allocator, src_mod, options, rename_tbl);
        }
    }

    // 6. __esm 래핑 — preamble(의존 모듈 init 호출)을 body 맨 앞에 삽입하여
    //    호이스팅된 함수가 호출되기 전에 의존 모듈이 초기화되도록 보장한다.
    const preamble_code = if (metadata) |md| md.cjs_import_preamble else null;

    const is_async = module.uses_top_level_await;

    // entry dependency chain은 entry factory 안의 nested require로 남긴다.
    // dependency를 top-level 개별 guard로 풀면 ErrorUtils 설치 후 throw가 swallow되어
    // entry 평가가 계속 진행된다. runBeforeMain은 single-file/chunk emitter가
    // Metro append script와 같이 user module 실행 전 top-level에서 별도로 호출한다.
    const unroll_run_before_main = module.is_entry_point and options.entry_error_guard;
    var entry_chain_buf: std.ArrayList(u8) = .empty;
    errdefer entry_chain_buf.deinit(allocator);

    // React Fast Refresh: body_code에 $RefreshReg$(_c, ...) 호출이 있을 때만
    // 모듈별 save/restore + boundary accept를 주입. 비컴포넌트 모듈은 건너뜀.
    const has_refresh = options.dev_mode and options.react_refresh and module.dev_id.len > 0 and
        std.mem.indexOf(u8, body_code, "$RefreshReg$(_") != null;

    // minified는 한 줄이므로 body_preamble_lines = 0, non-minified에서 갱신
    var body_preamble_lines: u32 = 0;

    if (options.minify_whitespace) {
        try wrapped.appendSlice(allocator, "var ");
        try wrapped.appendSlice(allocator, init_name);
        // #1621: minify 시 __esm → $e 축약.
        try wrapped.appendSlice(allocator, "=" ++ rt.NAMES.ESM_FACTORY_MIN ++ "({");
        if (is_async) try wrapped.appendSlice(allocator, "async ");
        try wrapped.appendSlice(allocator, "\"");
        try wrapped.appendSlice(allocator, basename);
        try wrapped.appendSlice(allocator, "\"(){");
        if (has_refresh) {
            try wrapped.appendSlice(allocator, "var __prevRefreshReg=__zntc_g.$RefreshReg$,__prevRefreshSig=__zntc_g.$RefreshSig$;");
            try wrapped.appendSlice(allocator, "__zntc_g.$RefreshReg$=function(type,id){var rt=__zntc_g.__ReactRefresh||__zntc_resolveRefresh();if(rt)rt.register(type,\"");
            try wrapped.appendSlice(allocator, module.dev_id);
            try wrapped.appendSlice(allocator, " \"+id)};");
            try wrapped.appendSlice(allocator, "__zntc_g.$RefreshSig$=function(){var rt=__zntc_g.__ReactRefresh||__zntc_resolveRefresh();if(rt)return rt.createSignatureFunctionForTransform();return function(t){return t}};");
        }
        if (func_code.len > 0) {
            func_preamble_lines = @intCast(std.mem.count(u8, wrapped.items, "\n"));
            try wrapped.appendSlice(allocator, func_code);
        }
        if (preamble_code) |p| {
            try writeChainPiece(&entry_chain_buf, &wrapped, allocator, p, false, false);
        }
        try writeChainPiece(&entry_chain_buf, &wrapped, allocator, star_init_buf.items, false, false);
        try wrapped.appendSlice(allocator, body_code);
        if (reexport_buf.items.len > 0) try wrapped.appendSlice(allocator, reexport_buf.items);
        if (has_refresh) {
            try wrapped.appendSlice(allocator, "__zntc_g.$RefreshReg$=__prevRefreshReg;__zntc_g.$RefreshSig$=__prevRefreshSig;");
            try wrapped.appendSlice(allocator, "__zntc_make_hot(\"");
            try wrapped.appendSlice(allocator, module.dev_id);
            try wrapped.appendSlice(allocator, "\").accept(function(m){if(__zntc_isReactRefreshBoundary(m))__zntc_enqueueUpdate();else __zntc_reload()});");
        }
        if (options.dev_mode) {
            try wrapped.appendSlice(allocator, "}},void 0,");
            try wrapped.appendSlice(allocator, exports_name);
            try wrapped.appendSlice(allocator, ");");
        } else {
            try wrapped.appendSlice(allocator, "}});");
        }
    } else {
        try wrapped.appendSlice(allocator, "var ");
        try wrapped.appendSlice(allocator, init_name);
        try wrapped.appendSlice(allocator, " = __esm({\n\t");
        if (is_async) try wrapped.appendSlice(allocator, "async ");
        try wrapped.appendSlice(allocator, "\"");
        try wrapped.appendSlice(allocator, basename);
        try wrapped.appendSlice(allocator, "\"() {\n");
        if (has_refresh) {
            try wrapped.appendSlice(allocator, "\tvar __prevRefreshReg = __zntc_g.$RefreshReg$, __prevRefreshSig = __zntc_g.$RefreshSig$;\n");
            try wrapped.appendSlice(allocator, "\t__zntc_g.$RefreshReg$ = function(type, id) {\n");
            try wrapped.appendSlice(allocator, "\t\tvar rt = __zntc_g.__ReactRefresh || __zntc_resolveRefresh();\n");
            try wrapped.appendSlice(allocator, "\t\tif (rt) rt.register(type, \"");
            try wrapped.appendSlice(allocator, module.dev_id);
            try wrapped.appendSlice(allocator, " \" + id);\n");
            try wrapped.appendSlice(allocator, "\t};\n");
            try wrapped.appendSlice(allocator, "\t__zntc_g.$RefreshSig$ = function() {\n");
            try wrapped.appendSlice(allocator, "\t\tvar rt = __zntc_g.__ReactRefresh || __zntc_resolveRefresh();\n");
            try wrapped.appendSlice(allocator, "\t\tif (rt) return rt.createSignatureFunctionForTransform();\n");
            try wrapped.appendSlice(allocator, "\t\treturn function(t) { return t; };\n");
            try wrapped.appendSlice(allocator, "\t};\n");
        }
        // func_code를 preamble 앞에 배치: 순환 참조에서 preamble이 의존 모듈을 init할 때
        // 이 모듈의 함수가 이미 할당된 상태여야 한다. (#1092)
        if (func_code.len > 0) {
            func_preamble_lines = @intCast(std.mem.count(u8, wrapped.items, "\n"));
            try wrapped.append(allocator, '\t');
            try appendIndented(&wrapped, allocator, func_code);
        }
        if (preamble_code) |p| {
            try writeChainPiece(&entry_chain_buf, &wrapped, allocator, p, false, true);
        }
        try writeChainPiece(&entry_chain_buf, &wrapped, allocator, star_init_buf.items, false, true);
        body_preamble_lines = @intCast(std.mem.count(u8, wrapped.items, "\n"));
        if (body_code.len > 0) {
            try wrapped.append(allocator, '\t');
            try appendIndented(&wrapped, allocator, body_code);
        }
        if (reexport_buf.items.len > 0) {
            try wrapped.append(allocator, '\t');
            try appendIndented(&wrapped, allocator, reexport_buf.items);
        }
        if (has_refresh) {
            try wrapped.appendSlice(allocator, "\t__zntc_g.$RefreshReg$ = __prevRefreshReg;\n");
            try wrapped.appendSlice(allocator, "\t__zntc_g.$RefreshSig$ = __prevRefreshSig;\n");
            try wrapped.appendSlice(allocator, "\t__zntc_make_hot(\"");
            try wrapped.appendSlice(allocator, module.dev_id);
            try wrapped.appendSlice(allocator, "\").accept(function(m) {\n");
            try wrapped.appendSlice(allocator, "\t\tif (__zntc_isReactRefreshBoundary(m)) __zntc_enqueueUpdate();\n");
            try wrapped.appendSlice(allocator, "\t\telse __zntc_reload();\n");
            try wrapped.appendSlice(allocator, "\t});\n");
        }
        if (options.dev_mode) {
            try wrapped.appendSlice(allocator, "\n\t}\n}, void 0, ");
            try wrapped.appendSlice(allocator, exports_name);
            try wrapped.appendSlice(allocator, ");\n");
        } else {
            try wrapped.appendSlice(allocator, "\n\t}\n});\n");
        }
    }

    // 소스맵 매핑 수집: hoisted + body 매핑을 병합하여 단일 슬라이스로 할당.
    // hoist/func/body 각 codegen builder 의 names 도 concat — 각 partition 의 mapping
    // name_index 에 partition offset 을 더해 통합 names 인덱스로 재매핑.
    var mappings: ?[]const SourceMap.Mapping = null;
    var names_merged: []const []const u8 = &.{};
    {
        const hm = hoist_mappings orelse &[_]SourceMap.Mapping{};
        const fm = func_mappings orelse &[_]SourceMap.Mapping{};
        const bm = if (body_cg.sm_builder) |*sm| sm.mappings.items else &[_]SourceMap.Mapping{};
        const hn = hoist_names;
        const fn_names = func_names;
        const bn = if (body_cg.sm_builder) |*sm| sm.names.items else &[_][]const u8{};
        const all_maps = [_][]const SourceMap.Mapping{ hm, fm, bm };
        const line_offsets = [_]u32{ hoist_preamble_lines, func_preamble_lines, body_preamble_lines };
        const name_offsets = [_]u32{ 0, @intCast(hn.len), @intCast(hn.len + fn_names.len) };
        const total = hm.len + fm.len + bm.len;
        if (total > 0) {
            // 각 줄의 첫 매핑이 column 0이 아니면, column 0 매핑을 추가.
            // DevTools가 col 0으로 소스맵을 역참조할 때 올바른 줄을 반환하도록.
            var col0_count: usize = 0;
            for (all_maps, line_offsets) |maps, offset| {
                var prev_gl: u32 = std.math.maxInt(u32);
                for (maps) |m| {
                    const gl = m.generated_line + offset;
                    if (gl != prev_gl) {
                        if (m.generated_column > 0) col0_count += 1;
                        prev_gl = gl;
                    }
                }
            }

            const buf = try allocator.alloc(SourceMap.Mapping, total + col0_count);
            var wi: usize = 0;
            for (all_maps, line_offsets, name_offsets) |maps, offset, name_off| {
                var prev_gl: u32 = std.math.maxInt(u32);
                for (maps) |m| {
                    const gl = m.generated_line + offset;
                    if (gl != prev_gl and m.generated_column > 0) {
                        // col0 line anchor — name 없음 (line 단위 fallback 용도).
                        buf[wi] = .{ .generated_line = gl, .generated_column = 0, .source_index = m.source_index, .original_line = m.original_line, .original_column = m.original_column };
                        wi += 1;
                    }
                    prev_gl = gl;
                    const shifted_name: ?u32 = if (m.name_index) |ni| ni + name_off else null;
                    buf[wi] = .{ .generated_line = gl, .generated_column = m.generated_column, .source_index = m.source_index, .original_line = m.original_line, .original_column = m.original_column, .name_index = shifted_name };
                    wi += 1;
                }
            }
            mappings = buf[0..wi];
        }

        // names concat — hoist + func + body. mapping.name_index 의 partition offset 과 정합.
        const total_names = hn.len + fn_names.len + bn.len;
        if (total_names > 0) {
            const names_buf = try allocator.alloc([]const u8, total_names);
            errdefer allocator.free(names_buf);
            var filled: usize = 0;
            errdefer for (names_buf[0..filled]) |s| allocator.free(s);
            for (hn) |n| {
                names_buf[filled] = try allocator.dupe(u8, n);
                filled += 1;
            }
            for (fn_names) |n| {
                names_buf[filled] = try allocator.dupe(u8, n);
                filled += 1;
            }
            for (bn) |n| {
                names_buf[filled] = try allocator.dupe(u8, n);
                filled += 1;
            }
            names_merged = names_buf;
        }
    }

    // entry_chain: runBeforeMain unroll 모드에서 caller (emitter.zig) 에 전달.
    // 빈 buffer 면 null.
    const entry_chain_owned: ?[]const u8 = if (unroll_run_before_main and entry_chain_buf.items.len > 0)
        try allocator.dupe(u8, entry_chain_buf.items)
    else
        null;
    entry_chain_buf.deinit(allocator);

    return .{
        .code = try allocator.dupe(u8, wrapped.items),
        .mappings = mappings,
        .names = names_merged,
        .entry_chain = entry_chain_owned,
    };
}

/// rbm / preamble / star_init chunk 를 entry chain unroll 모드면 chain_buf 에, 아니면
/// wrapped factory body 에 emit. `indent=true` 면 factory body 안에서 한 칸 들여쓰기.
fn writeChainPiece(
    chain_buf: *std.ArrayList(u8),
    wrapped: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    src: []const u8,
    unroll: bool,
    indent: bool,
) !void {
    if (src.len == 0) return;
    if (unroll) {
        try chain_buf.appendSlice(allocator, src);
        return;
    }
    if (indent) {
        try wrapped.append(allocator, '\t');
        try appendIndented(wrapped, allocator, src);
    } else {
        try wrapped.appendSlice(allocator, src);
    }
}

/// 래핑된 소스 모듈의 init/require 호출을 buffer에 추가한다.
/// re-export (`export * from`, `export { x } from`) 및 side-effect-only import
/// (`import './x';`)에서 소스 모듈 초기화 코드를 생성할 때 공용으로 쓴다.
///
/// `entry_error_guard` 활성 시 `__zntc_guarded(function(){return <call>;})` 으로 wrap.
/// helper 의 `__zntc_in_guard` state 가 nested 호출을 자동 skip 하므로 outermost
/// (entry trigger 등) 만 실제 catch. TLA 모듈은 await 가 lambda 안에 못 들어가서 wrap 안 함.
fn appendWrappedInitCall(
    buf: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    src_mod: *const Module,
    options: *const EmitOptions,
    rename_tbl: ?*const RenameTable,
) !void {
    const is_tla = src_mod.wrap_kind == .esm and src_mod.uses_top_level_await;
    const guard = src_mod.shouldGuard(options.entry_error_guard);
    switch (src_mod.wrap_kind) {
        .esm => {
            if (is_tla) try buf.appendSlice(allocator, "await ");
            if (guard) try buf.appendSlice(allocator, if (options.minify_whitespace) rt.GUARD_LAMBDA_OPEN_MIN else rt.GUARD_LAMBDA_OPEN);
            // 비-dev_split(RN/단일번들 dev) 분기는 원래 코드 구조를 그대로 유지 → byte-identical
            // 출력(append 횟수는 결과 바이트와 무관·소스맵에도 영향 없음 — 버퍼는 raw 바이트, 소스맵
            // 매핑은 codegen body 와 줄 수만 반영). .esm init 은 기존에 단일번들 dev 도 registry 였으므로
            // useDevModuleRegistry(dev and (!split or lazy)).
            if (options.useDevModuleRegistry()) {
                try buf.appendSlice(allocator, "__zntc_modules[\"");
                try buf.appendSlice(allocator, src_mod.dev_id);
                try buf.appendSlice(allocator, "\"].fn()");
            } else {
                const iv = try src_mod.allocInitName(allocator, rename_tbl);
                defer allocator.free(iv);
                try buf.appendSlice(allocator, iv);
                try buf.appendSlice(allocator, "()");
            }
            try buf.appendSlice(allocator, if (guard) rt.GUARD_LAMBDA_CLOSE else rt.INIT_CALL_END);
        },
        .cjs => {
            if (guard) try buf.appendSlice(allocator, if (options.minify_whitespace) rt.GUARD_LAMBDA_OPEN_MIN else rt.GUARD_LAMBDA_OPEN);
            // .cjs init 은 기존에 단일번들 dev 도 lexical → dev_split 만 registry(isDevSplit).
            if (options.isDevSplit()) {
                try buf.appendSlice(allocator, "__zntc_modules[\"");
                try buf.appendSlice(allocator, src_mod.dev_id);
                try buf.appendSlice(allocator, "\"].fn()");
            } else {
                const rv = try src_mod.allocRequireName(allocator, rename_tbl);
                defer allocator.free(rv);
                try buf.appendSlice(allocator, rv);
                try buf.appendSlice(allocator, "()");
            }
            try buf.appendSlice(allocator, if (guard) rt.GUARD_LAMBDA_CLOSE else rt.INIT_CALL_END);
        },
        .none => {},
    }
}

/// __export() 내부의 "name: () => value,\n" 한 줄을 출력한다.
/// `configurable_exports` 가 true 면 RN/Hermes 호환을 위해 arrow 대신
/// function expression getter 사용 (this binding / inline cache 시맨틱 차이).
fn appendExportGetter(
    buf: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    name: []const u8,
    value: []const u8,
    options: anytype,
) !void {
    const es5 = options.configurable_exports;
    const min = options.minify_whitespace;
    if (!min) try buf.appendSlice(allocator, "\t");
    if (needsPropertyQuote(name)) {
        try buf.appendSlice(allocator, "\"");
        try buf.appendSlice(allocator, name);
        try buf.appendSlice(allocator, "\"");
    } else {
        try buf.appendSlice(allocator, name);
    }
    if (es5) {
        try buf.appendSlice(allocator, if (min) ":function(){return " else ": function() { return ");
        try buf.appendSlice(allocator, value);
        try buf.appendSlice(allocator, if (min) "}," else "; },\n");
    } else {
        try buf.appendSlice(allocator, if (min) ":()=>" else ": () => ");
        try buf.appendSlice(allocator, value);
        try buf.appendSlice(allocator, if (min) "," else ",\n");
    }
}

/// export * from 체인을 따라가며 모든 export 이름을 수집한다.
/// ESM 스펙: export *는 "default"를 제외한 모든 named export를 전파한다.
/// diamond export * 패턴(A→B,C / B,C→D)에서 무한 재귀를 방지하기 위해 visited로 모듈 추적.
fn collectStarExportNames(
    allocator: std.mem.Allocator,
    l: *const Linker,
    mod_idx: u32,
    seen: *std.StringHashMapUnmanaged(void),
    visited: *std.AutoHashMapUnmanaged(u32, void),
) !void {
    const m = l.graph.getModule(ModuleIndex.fromUsize(mod_idx)) orelse return;
    if (visited.contains(mod_idx)) return;
    try visited.put(allocator, mod_idx, {});

    // 직접 선언된 export 수집 (local + re_export + named re_export_all)
    for (m.export_bindings) |eb| {
        if (eb.kind == .re_export_star) continue;
        if (!seen.contains(eb.exported_name)) {
            try seen.put(allocator, eb.exported_name, {});
        }
    }

    // export * from 재귀 — 소스 모듈의 export도 수집
    for (m.export_bindings) |eb| {
        if (!eb.kind.isReExportAll()) continue;
        if (!std.mem.eql(u8, eb.exported_name, "*")) continue;
        const rec_idx = eb.import_record_index orelse continue;
        if (rec_idx >= m.import_records.len) continue;
        const source_mod_idx = m.import_records[rec_idx].resolved;
        if (source_mod_idx.isNone()) continue;
        try collectStarExportNames(allocator, l, @intFromEnum(source_mod_idx), seen, visited);
    }
}

fn shouldLazyReExportInit(options: *const EmitOptions, src_mod: *const Module) bool {
    return options.platform == .react_native and
        src_mod.wrap_kind != .none and
        !(src_mod.wrap_kind == .esm and src_mod.uses_top_level_await);
}

// dev_split 에서 모듈 참조를 글로벌 레지스트리로 lowering 한다([[useDevModuleRegistry]]). lexical
// (`require_X`/`init_X`/`exports_X`)은 정의자 청크 팩토리 스코프에 갇혀 크로스청크 불가지만,
// 글로벌 `__zntc_modules` 는 청크 경계를 넘어 주소화 가능(ESM init 이 이미 쓰는 방식). 정의자
// 청크에서도 안전(레지스트리에 등록돼 있음) → dev_split 이면 same/cross 무관 레지스트리 통일.
// 비-registry(production/비-lazy splitting)는 lexical 유지 → byte-identical.

// getter value(`require_X().name`/`exports_X.name`)는 *기존*에 단일번들 dev·RN 에서 lexical 이었다
// (getter 는 같은 번들 스코프라 lexical 로 충분). dev_split 만 크로스청크라 registry 가 필요 →
// 이 두 헬퍼는 `isDevSplit()` 게이트로 좁혀 단일번들 dev·RN byte-identical 보존, dev_split 만
// registry. (init-call 류는 호출처에서 원래 코드 구조를 그대로 유지 — append 횟수는 결과 바이트와
// 무관하나, 리뷰 diff 를 최소화하고 비-dev_split 경로를 한눈에 byte-identical 로 보이게 하기 위함.)

/// CJS require 호출식. dev_split: `__zntc_modules["id"].fn()`, else: `require_X()`. =module.exports.
fn allocCjsRequireCall(allocator: std.mem.Allocator, mod: *const Module, options: *const EmitOptions, rename_tbl: ?*const RenameTable) ![]const u8 {
    if (options.isDevSplit()) {
        return std.fmt.allocPrint(allocator, "__zntc_modules[\"{s}\"].fn()", .{mod.dev_id});
    }
    const rv = try mod.allocRequireName(allocator, rename_tbl);
    defer allocator.free(rv);
    return std.fmt.allocPrint(allocator, "{s}()", .{rv});
}

/// ESM 네임스페이스 객체 ref. dev_split: `__zntc_modules["id"].exports`, else: `exports_X`.
fn allocEsmExportsRef(allocator: std.mem.Allocator, mod: *const Module, options: *const EmitOptions, rename_tbl: ?*const RenameTable) ![]const u8 {
    if (options.isDevSplit()) {
        return std.fmt.allocPrint(allocator, "__zntc_modules[\"{s}\"].exports", .{mod.dev_id});
    }
    return mod.allocExportsName(allocator, rename_tbl);
}

fn makeLazyEsmGetterValue(
    allocator: std.mem.Allocator,
    src_mod: *const Module,
    target: []const u8,
    options: *const EmitOptions,
    rename_tbl: ?*const RenameTable,
) ![]const u8 {
    if (!shouldLazyReExportInit(options, src_mod) or src_mod.wrap_kind != .esm) {
        return try allocator.dupe(u8, target);
    }

    // RN 전용(shouldLazyReExportInit=react_native) — dev_split(web) 미경유(web 은 위 early-return).
    // 원래 게이트(`dev_mode and !code_splitting`)·구조 그대로 유지 → RN/단일번들 dev byte-identical.
    const init_call = if (options.dev_mode and !options.code_splitting) blk: {
        break :blk try std.fmt.allocPrint(allocator, "__zntc_modules[\"{s}\"].fn()", .{src_mod.dev_id});
    } else blk: {
        const iv = try src_mod.allocInitName(allocator, rename_tbl);
        defer allocator.free(iv);
        break :blk try std.fmt.allocPrint(allocator, "{s}()", .{iv});
    };
    defer allocator.free(init_call);

    const init_expr = if (src_mod.shouldGuard(options.entry_error_guard)) blk: {
        const guard_name: []const u8 = if (options.minify_whitespace) rt.GUARD_FN_NAME_MIN else rt.GUARD_FN_NAME;
        break :blk try std.fmt.allocPrint(allocator, "{s}(function(){{return {s}}})", .{ guard_name, init_call });
    } else try allocator.dupe(u8, init_call);
    defer allocator.free(init_expr);

    return try std.fmt.allocPrint(allocator, "({s}, {s})", .{ init_expr, target });
}

fn makeEsmExportGetterValue(
    allocator: std.mem.Allocator,
    src_mod: *const Module,
    name: []const u8,
    options: *const EmitOptions,
    rename_tbl: ?*const RenameTable,
) ![]const u8 {
    const ev = try allocEsmExportsRef(allocator, src_mod, options, rename_tbl);
    defer allocator.free(ev);
    const target = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ ev, name });
    defer allocator.free(target);
    return makeLazyEsmGetterValue(allocator, src_mod, target, options, rename_tbl);
}

fn makeNamespaceGetterValue(
    allocator: std.mem.Allocator,
    src_mod: *const Module,
    options: *const EmitOptions,
    rename_tbl: ?*const RenameTable,
) ![]const u8 {
    const ev = try allocEsmExportsRef(allocator, src_mod, options, rename_tbl);
    defer allocator.free(ev);
    return makeLazyEsmGetterValue(allocator, src_mod, ev, options, rename_tbl);
}

/// star re-export의 getter 값을 소스 모듈 wrap_kind에 따라 생성한다.
/// - .none (scope-hoisted): canonical 로컬 변수 이름 (linker rename 반영)
/// - .esm: "exports_source.name" (exports 객체 프로퍼티 접근)
/// - .cjs: "require_source().name" (require 호출 후 프로퍼티 접근)
fn makeStarGetterValue(
    allocator: std.mem.Allocator,
    l: *const Linker,
    src_mod: *const Module,
    src_i: u32,
    name: []const u8,
    options: *const EmitOptions,
) !?[]const u8 {
    if (l.tree_shaker_active and !src_mod.is_included) return null;
    // RFC #3940 L.4c-2a-ii: wrapper-name 을 build-scope rename_table 경유 (parity 로 byte-identical).
    const rename_tbl: ?*const RenameTable = &l.rename_table;

    switch (src_mod.wrap_kind) {
        .none => {
            // scope-hoisted: export의 local_name을 찾아 canonical name으로 변환
            for (src_mod.export_bindings) |src_eb| {
                if (!std.mem.eql(u8, src_eb.exported_name, name)) continue;
                if (isReExportLike(src_eb)) {
                    const target = resolveReExportTarget(l, src_mod, src_eb) orelse return null;
                    return try makeStarGetterValue(allocator, l, target.mod, target.index, target.name, options);
                }
                const local = l.getCanonicalForExport(src_eb, src_i);
                return try allocator.dupe(u8, local);
            }
            // 직접 export에 없으면 소스의 re_export_all 체인을 따라간다.
            // resolveExportChain으로 canonical 이름을 찾는다.
            if (l.resolveExportChain(@enumFromInt(src_i), name, 0)) |resolved| {
                const canonical_mod_i = resolved.module_index.toU32();
                const canonical_mod = l.graph.getModule(resolved.module_index) orelse return null;
                if (l.tree_shaker_active and !canonical_mod.is_included) return null;
                // canonical 모듈이 래핑되어 있으면 exports_xxx.name 형태
                if (canonical_mod.wrap_kind == .esm) {
                    const ev = try allocEsmExportsRef(allocator, canonical_mod, options, rename_tbl);
                    defer allocator.free(ev);
                    return try std.fmt.allocPrint(allocator, "{s}.{s}", .{ ev, resolved.export_name });
                }
                if (canonical_mod.wrap_kind == .cjs) {
                    const rv = try allocCjsRequireCall(allocator, canonical_mod, options, rename_tbl);
                    defer allocator.free(rv);
                    return try std.fmt.allocPrint(allocator, "{s}.{s}", .{ rv, resolved.export_name });
                }
                // .none: canonical 로컬 변수
                for (canonical_mod.export_bindings) |ceb| {
                    if (std.mem.eql(u8, ceb.exported_name, resolved.export_name)) {
                        const local = l.getCanonicalForExport(ceb, canonical_mod_i);
                        return try allocator.dupe(u8, local);
                    }
                }
            }
            // No source export was available. The caller should omit this getter.
            return null;
        },
        .esm => {
            return try makeEsmExportGetterValue(allocator, src_mod, name, options, rename_tbl);
        },
        .cjs => {
            const rv = try allocCjsRequireCall(allocator, src_mod, options, rename_tbl);
            defer allocator.free(rv);
            return try std.fmt.allocPrint(allocator, "{s}.{s}", .{ rv, name });
        },
    }
}
