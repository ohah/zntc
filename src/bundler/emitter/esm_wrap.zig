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
const Transformer = @import("../../transformer/transformer.zig").Transformer;
const RuntimeHelpers = @import("../../transformer/transformer.zig").RuntimeHelpers;
const Codegen = @import("../../codegen/codegen.zig").Codegen;
const CodegenOptions = @import("../../codegen/codegen.zig").CodegenOptions;
const SourceMap = @import("../../codegen/sourcemap.zig");
const Linker = @import("../linker.zig").Linker;
const LinkingMetadata = @import("../linker.zig").LinkingMetadata;
const TreeShaker = @import("../tree_shaker.zig").TreeShaker;
const statement_shaker = @import("../statement_shaker.zig");
const stmt_info_mod = @import("../stmt_info.zig");
const ExportBinding = @import("../binding_scanner.zig").ExportBinding;
const parent = @import("../emitter.zig");
const EmitOptions = parent.EmitOptions;
const resolveNodeName = parent.resolveNodeName;
const needsPropertyQuote = parent.needsPropertyQuote;
const collectImportBindingNames = parent.collectImportBindingNames;
const appendRunBeforeMainCalls = parent.appendRunBeforeMainCalls;
const appendIndented = parent.appendIndented;
const appendModuleCall = parent.appendModuleCall;

pub const EsmEmitResult = struct {
    code: []const u8,
    mappings: ?[]const SourceMap.Mapping = null,
};

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

    const init_name = try types.makeInitVarName(allocator, module.path);
    defer allocator.free(init_name);
    const exports_name = try types.makeExportsVarName(allocator, module.path);
    defer allocator.free(exports_name);

    // AST top-level 문장을 분류
    const root_node = esm_ast.getNode(root);
    const stmt_list = root_node.data.list;
    const all_stmts = esm_ast.extra_data.items[stmt_list.start .. stmt_list.start + stmt_list.len];

    var hoisted_stmts: std.ArrayList(u32) = .empty;
    defer hoisted_stmts.deinit(allocator);
    var body_stmts: std.ArrayList(u32) = .empty;
    defer body_stmts.deinit(allocator);
    var hoisted_var_names: std.ArrayList([]const u8) = .empty;
    defer hoisted_var_names.deinit(allocator);

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
                // rolldown 방식: function은 __esm 밖으로 호이스팅.
                // live binding으로 canonical 변수를 직접 참조하므로 TDZ 없음.
                try hoisted_stmts.append(allocator, raw_idx);
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
                        const raw_name = esm_ast.getText(name_node.data.string_ref);
                        try hoisted_var_names.append(allocator, resolveNodeName(metadata, @intFromEnum(class_name_idx), raw_name));
                    }
                }
                try body_stmts.append(allocator, raw_idx);
            },
            .import_declaration => {
                // var 선언만 호이스팅 (할당은 래퍼 안). linker skip된 import는 제외.
                const import_skipped = if (metadata) |md| md.skip_nodes.isSet(raw_idx) else false;
                if (!import_skipped) {
                    try collectImportBindingNames(esm_ast, stmt_node, metadata, allocator, &hoisted_var_names);
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
                        const raw_name = esm_ast.getText(name_node.data.string_ref);
                        try hoisted_var_names.append(allocator, resolveNodeName(metadata, @intFromEnum(name_raw), raw_name));
                    }
                }
                // body에 넣어서 할당문으로 변환
                try body_stmts.append(allocator, raw_idx);
            },
            else => {
                // effective_tag는 내부 노드의 태그이므로 export_default_declaration은
                // 이 분기에 도달한다. stmt_node.tag로 원본 태그를 확인하여 호이스팅.
                if (stmt_node.tag == .export_default_declaration) {
                    const def_name = if (metadata) |md| md.default_export_name else "_default";
                    try hoisted_var_names.append(allocator, def_name);
                }
                try body_stmts.append(allocator, raw_idx);
            },
        }
    }

    // re-export (export { default } from / export { default as X } from)는
    // AST에 export_default_declaration 노드가 없으므로 export_bindings에서 확인.
    for (module.export_bindings) |eb| {
        if (eb.kind == .re_export and std.mem.eql(u8, eb.local_name, "default")) {
            const def_name = if (metadata) |md| md.default_export_name else "_default";
            try hoisted_var_names.append(allocator, def_name);
            break;
        }
    }

    // synthetic JSX import binding: top-level에 var 선언이 필요.
    // preamble은 __esm init 블록 안에 삽입되므로, var _jsxDEV = ... 형태면
    // 호이스팅된 함수에서 접근 불가. var _jsxDEV;를 top-level에 선언하고
    // init 안에서 _jsxDEV = ... (할당만)으로 처리해야 함.
    for (module.import_bindings) |ib| {
        if (ib.local_span.start >= 0xFFFF_0000) {
            try hoisted_var_names.append(allocator, ib.local_name);
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
            if (is_dup) continue;
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
    var hoist_preamble_lines: u32 = 0;
    if (hoisted_stmts.items.len > 0) {
        var hoist_cg = Codegen.initWithOptions(arena_alloc, esm_ast, .{
            .minify_whitespace = options.minify_whitespace,
            .module_format = .cjs,
            .skip_cjs_exports = true,
            .use_var_for_imports = true,
            .linking_metadata = cg_linking,
            .replace_import_meta = options.format != .esm,
            .platform = options.platform,
            .sourcemap = options.sourcemap,
            .source_root = options.source_root orelse "",
            .sources_content = options.sources_content,
        });
        if (options.sourcemap) {
            hoist_cg.line_offsets = module.line_offsets;
            try hoist_cg.addSourceFile(parent.makeModuleId(module.path, options.root_dir));
        }
        // 호이스팅 코드 삽입 전 줄 수 (소스맵 오프셋)
        hoist_preamble_lines = @intCast(std.mem.count(u8, wrapped.items, "\n"));
        const hoisted_code = try hoist_cg.generateStatements(root, hoisted_stmts.items);
        try wrapped.appendSlice(allocator, hoisted_code);
        // 호이스팅 매핑 수집
        if (hoist_cg.sm_builder) |*sm| {
            if (sm.mappings.items.len > 0) {
                hoist_mappings = sm.mappings.items;
            }
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
        var direct_exports = std.StringHashMap(void).init(allocator);
        defer direct_exports.deinit();
        for (module.export_bindings) |eb| {
            if (eb.kind == .local or eb.kind == .re_export) {
                try direct_exports.put(eb.exported_name, {});
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
            var seen = std.StringHashMap(void).init(allocator);
            defer seen.deinit();
            var visited = std.AutoHashMap(u32, void).init(allocator);
            defer visited.deinit();

            for (module.export_bindings) |eb| {
                if (eb.kind != .re_export_all) continue;
                const rec_idx = eb.import_record_index orelse continue;
                if (rec_idx >= module.import_records.len) continue;
                const source_mod_idx = module.import_records[rec_idx].resolved;
                if (source_mod_idx.isNone()) continue;
                const src_i = @intFromEnum(source_mod_idx);
                if (src_i >= l.modules.len) continue;
                const src_mod = &l.modules[src_i];

                if (std.mem.eql(u8, eb.exported_name, "*")) {
                    seen.clearRetainingCapacity();
                    visited.clearRetainingCapacity();
                    try collectStarExportNames(l, src_i, &seen, &visited);

                    var it = seen.iterator();
                    while (it.next()) |entry| {
                        const name = entry.key_ptr.*;
                        if (std.mem.eql(u8, name, "default")) continue;
                        if (direct_exports.contains(name)) continue;

                        const getter_val = try makeStarGetterValue(allocator, l, src_mod, src_i, name);
                        try star_owned.append(allocator, getter_val);
                        try star_entries.append(allocator, .{
                            .name = name,
                            .getter_value = getter_val,
                        });
                        try direct_exports.put(name, {});
                    }
                } else {
                    // export * as ns from './dep' → namespace re-export
                    // getter는 소스 모듈의 exports 객체 자체를 참조
                    const getter_val = switch (src_mod.wrap_kind) {
                        .esm, .none => try types.makeExportsVarName(allocator, src_mod.path),
                        .cjs => blk: {
                            const rv = try types.makeRequireVarName(allocator, src_mod.path);
                            defer allocator.free(rv);
                            break :blk try std.fmt.allocPrint(allocator, "{s}()", .{rv});
                        },
                    };
                    try star_owned.append(allocator, getter_val);
                    if (!direct_exports.contains(eb.exported_name)) {
                        try star_entries.append(allocator, .{
                            .name = eb.exported_name,
                            .getter_value = getter_val,
                        });
                        try direct_exports.put(eb.exported_name, {});
                    }
                }
            }
        }

        if (direct_exports.count() > 0 or star_entries.items.len > 0) {
            try wrapped.appendSlice(allocator, "__export(");
            try wrapped.appendSlice(allocator, exports_name);
            try wrapped.appendSlice(allocator, ", {\n");

            for (module.export_bindings) |eb| {
                if (eb.kind == .local or eb.kind == .re_export) {
                    try appendExportGetter(&wrapped, allocator, eb.exported_name, blk: {
                        if (std.mem.eql(u8, eb.local_name, "default"))
                            break :blk if (metadata) |md| md.default_export_name else "_default";
                        // live binding override: import binding이 canonical name으로 변경된 경우
                        if (metadata) |md| {
                            if (md.export_getter_overrides.get(eb.local_name)) |override|
                                break :blk override;
                        }
                        if (linker) |l| {
                            const mi: u32 = @intFromEnum(module.index);
                            if (l.getCanonicalName(mi, eb.local_name)) |renamed|
                                break :blk renamed;
                        }
                        break :blk eb.local_name;
                    }, options.configurable_exports);
                }
            }
            for (star_entries.items) |entry| {
                try appendExportGetter(&wrapped, allocator, entry.name, entry.getter_value, options.configurable_exports);
            }

            try wrapped.appendSlice(allocator, "});\n");
        }
    }

    // 5. body codegen (variable_declaration/class → 할당문만)
    var body_cg = Codegen.initWithOptions(arena_alloc, esm_ast, .{
        .minify_whitespace = options.minify_whitespace,
        .module_format = .cjs,
        .skip_cjs_exports = true,
        .use_var_for_imports = true,
        .esm_var_assign_only = true,
        .linking_metadata = cg_linking,
        .replace_import_meta = options.format != .esm,
        .platform = options.platform,
        .keep_names = options.keep_names,
        .sourcemap = options.sourcemap,
        .source_root = options.source_root orelse "",
        .sources_content = options.sources_content,
    });
    // 소스맵: 소스 파일 등록 + line_offsets 설정
    if (options.sourcemap) {
        body_cg.line_offsets = module.line_offsets;
        try body_cg.addSourceFile(parent.makeModuleId(module.path, options.root_dir));
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
        if (!std.mem.eql(u8, eb.local_name, "default")) continue;
        const rec_idx = eb.import_record_index orelse continue;
        if (rec_idx >= module.import_records.len) continue;
        const source_mod_idx = module.import_records[rec_idx].resolved;
        if (source_mod_idx.isNone()) continue;
        // 자기 자신을 re-export하는 경우 skip (자기참조 init 호출 방지)
        if (source_mod_idx == module.index) continue;

        const def_name = if (metadata) |md| md.default_export_name else "_default";
        const source_mod_i = @intFromEnum(source_mod_idx);

        if (linker) |l| {
            if (source_mod_i < l.modules.len) {
                const source_mod = &l.modules[source_mod_i];
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
                        if (options.dev_mode) {
                            try reexport_buf.appendSlice(allocator, "__zts_modules[\"");
                            try reexport_buf.appendSlice(allocator, source_mod.dev_id);
                            try reexport_buf.appendSlice(allocator, "\"].fn(), __toCommonJS(__zts_modules[\"");
                            try reexport_buf.appendSlice(allocator, source_mod.dev_id);
                            try reexport_buf.appendSlice(allocator, "\"].exports))");
                        } else {
                            const iv = try types.makeInitVarName(allocator, source_mod.path);
                            defer allocator.free(iv);
                            const ev = try types.makeExportsVarName(allocator, source_mod.path);
                            defer allocator.free(ev);
                            try reexport_buf.appendSlice(allocator, iv);
                            try reexport_buf.appendSlice(allocator, "(), __toCommonJS(");
                            try reexport_buf.appendSlice(allocator, ev);
                            try reexport_buf.appendSlice(allocator, "))");
                        }
                        try reexport_buf.appendSlice(allocator, ".default");
                    },
                    .cjs => {
                        // preamble에서 이미 __toESM으로 바인딩된 변수가 있으면
                        // 중복 require 호출 없이 해당 변수를 참조한다.
                        const mi: u32 = @intFromEnum(module.index);
                        var found_preamble_var: ?[]const u8 = null;
                        for (module.import_bindings) |ib| {
                            if (ib.import_record_index == rec_idx and
                                std.mem.eql(u8, ib.imported_name, "default"))
                            {
                                found_preamble_var = l.getCanonicalName(mi, ib.local_name) orelse ib.local_name;
                                break;
                            }
                        }
                        if (found_preamble_var) |pv| {
                            try reexport_buf.appendSlice(allocator, pv);
                        } else {
                            const rv = try types.makeRequireVarName(allocator, source_mod.path);
                            defer allocator.free(rv);
                            const interop_mode: types.Interop = if (module.def_format.isEsm()) .node else .babel;
                            try reexport_buf.appendSlice(allocator, "__toESM(");
                            try reexport_buf.appendSlice(allocator, rv);
                            if (interop_mode == .node) {
                                try reexport_buf.appendSlice(allocator, "(), 1).default");
                            } else {
                                try reexport_buf.appendSlice(allocator, "()).default");
                            }
                        }
                    },
                }
                try reexport_buf.appendSlice(allocator, ";\n");
            }
        }
        break; // default re-export는 모듈당 하나만 존재
    }

    // 5.3. export * from 소스 모듈 init/require 호출 생성.
    // export * from은 import_bindings를 만들지 않으므로 linker preamble에 포함되지 않는다.
    // __esm body에서 소스 모듈을 초기화해야 lazy getter가 올바른 값을 반환한다.
    var star_init_buf: std.ArrayList(u8) = .empty;
    defer star_init_buf.deinit(allocator);
    if (linker) |l| {
        for (module.export_bindings) |eb| {
            if (eb.kind != .re_export_all) continue;
            const rec_idx = eb.import_record_index orelse continue;
            if (rec_idx >= module.import_records.len) continue;
            const source_mod_idx = module.import_records[rec_idx].resolved;
            if (source_mod_idx.isNone()) continue;
            const src_i = @intFromEnum(source_mod_idx);
            if (src_i >= l.modules.len) continue;

            const src_mod = &l.modules[src_i];
            switch (src_mod.wrap_kind) {
                .esm => {
                    if (src_mod.uses_top_level_await) try star_init_buf.appendSlice(allocator, "await ");
                    if (options.dev_mode) {
                        try star_init_buf.appendSlice(allocator, "__zts_modules[\"");
                        try star_init_buf.appendSlice(allocator, src_mod.dev_id);
                        try star_init_buf.appendSlice(allocator, "\"].fn();\n");
                    } else {
                        const iv = try types.makeInitVarName(allocator, src_mod.path);
                        defer allocator.free(iv);
                        try star_init_buf.appendSlice(allocator, iv);
                        try star_init_buf.appendSlice(allocator, "();\n");
                    }
                },
                .cjs => {
                    const rv = try types.makeRequireVarName(allocator, src_mod.path);
                    defer allocator.free(rv);
                    try star_init_buf.appendSlice(allocator, rv);
                    try star_init_buf.appendSlice(allocator, "();\n");
                },
                .none => {},
            }
        }
    }

    // 6. __esm 래핑 — preamble(의존 모듈 init 호출)을 body 맨 앞에 삽입하여
    //    호이스팅된 함수가 호출되기 전에 의존 모듈이 초기화되도록 보장한다.
    const preamble_code = if (metadata) |md| md.cjs_import_preamble else null;

    // 엔트리 모듈이 __esm 래핑된 경우(RN), run-before-main 호출을 body 맨 앞에 삽입.
    // InitializeCore 등이 의존 모듈보다 먼저 실행되어야 하므로 preamble보다 앞에 위치.
    var rbm_code: std.ArrayList(u8) = .empty;
    defer rbm_code.deinit(allocator);
    if (module.is_entry_point and options.run_before_main.len > 0) {
        if (linker) |l| {
            try appendRunBeforeMainCalls(&rbm_code, allocator, l.modules, options.run_before_main);
        }
    }

    const is_async = module.uses_top_level_await;

    // React Fast Refresh: body_code에 $RefreshReg$(_c, ...) 호출이 있을 때만
    // 모듈별 save/restore + boundary accept를 주입. 비컴포넌트 모듈은 건너뜀.
    const has_refresh = options.dev_mode and options.react_refresh and module.dev_id.len > 0 and
        std.mem.indexOf(u8, body_code, "$RefreshReg$(_") != null;

    // body code 삽입 전 줄 수 (소스맵 preamble 오프셋 — body 직전에 갱신)
    var body_preamble_lines: u32 = 0;

    if (options.minify_whitespace) {
        try wrapped.appendSlice(allocator, "var ");
        try wrapped.appendSlice(allocator, init_name);
        try wrapped.appendSlice(allocator, "=__esm({");
        if (is_async) try wrapped.appendSlice(allocator, "async ");
        try wrapped.appendSlice(allocator, "\"");
        try wrapped.appendSlice(allocator, basename);
        try wrapped.appendSlice(allocator, "\"(){");
        if (has_refresh) {
            try wrapped.appendSlice(allocator, "var __prevRefreshReg=__zts_g.$RefreshReg$,__prevRefreshSig=__zts_g.$RefreshSig$;");
            try wrapped.appendSlice(allocator, "__zts_g.$RefreshReg$=function(type,id){var rt=__zts_g.__ReactRefresh||__zts_resolveRefresh();if(rt)rt.register(type,\"");
            try wrapped.appendSlice(allocator, module.dev_id);
            try wrapped.appendSlice(allocator, " \"+id)};");
            try wrapped.appendSlice(allocator, "__zts_g.$RefreshSig$=function(){var rt=__zts_g.__ReactRefresh||__zts_resolveRefresh();if(rt)return rt.createSignatureFunctionForTransform();return function(t){return t}};");
        }
        if (rbm_code.items.len > 0) try wrapped.appendSlice(allocator, rbm_code.items);
        if (preamble_code) |p| try wrapped.appendSlice(allocator, p);
        if (star_init_buf.items.len > 0) try wrapped.appendSlice(allocator, star_init_buf.items);
        try wrapped.appendSlice(allocator, body_code);
        if (reexport_buf.items.len > 0) try wrapped.appendSlice(allocator, reexport_buf.items);
        if (has_refresh) {
            try wrapped.appendSlice(allocator, "__zts_g.$RefreshReg$=__prevRefreshReg;__zts_g.$RefreshSig$=__prevRefreshSig;");
            try wrapped.appendSlice(allocator, "__zts_make_hot(\"");
            try wrapped.appendSlice(allocator, module.dev_id);
            try wrapped.appendSlice(allocator, "\").accept(function(m){if(__zts_isReactRefreshBoundary(m))__zts_enqueueUpdate();else __zts_reload()});");
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
            try wrapped.appendSlice(allocator, "\tvar __prevRefreshReg = __zts_g.$RefreshReg$, __prevRefreshSig = __zts_g.$RefreshSig$;\n");
            try wrapped.appendSlice(allocator, "\t__zts_g.$RefreshReg$ = function(type, id) {\n");
            try wrapped.appendSlice(allocator, "\t\tvar rt = __zts_g.__ReactRefresh || __zts_resolveRefresh();\n");
            try wrapped.appendSlice(allocator, "\t\tif (rt) rt.register(type, \"");
            try wrapped.appendSlice(allocator, module.dev_id);
            try wrapped.appendSlice(allocator, " \" + id);\n");
            try wrapped.appendSlice(allocator, "\t};\n");
            try wrapped.appendSlice(allocator, "\t__zts_g.$RefreshSig$ = function() {\n");
            try wrapped.appendSlice(allocator, "\t\tvar rt = __zts_g.__ReactRefresh || __zts_resolveRefresh();\n");
            try wrapped.appendSlice(allocator, "\t\tif (rt) return rt.createSignatureFunctionForTransform();\n");
            try wrapped.appendSlice(allocator, "\t\treturn function(t) { return t; };\n");
            try wrapped.appendSlice(allocator, "\t};\n");
        }
        if (rbm_code.items.len > 0) {
            try wrapped.append(allocator, '\t');
            try appendIndented(&wrapped, allocator, rbm_code.items);
        }
        if (preamble_code) |p| {
            try wrapped.append(allocator, '\t');
            try appendIndented(&wrapped, allocator, p);
        }
        if (star_init_buf.items.len > 0) {
            try wrapped.append(allocator, '\t');
            try appendIndented(&wrapped, allocator, star_init_buf.items);
        }
        // body code 삽입 전 줄 수 캡처 (소스맵 preamble 오프셋용)
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
            try wrapped.appendSlice(allocator, "\t__zts_g.$RefreshReg$ = __prevRefreshReg;\n");
            try wrapped.appendSlice(allocator, "\t__zts_g.$RefreshSig$ = __prevRefreshSig;\n");
            try wrapped.appendSlice(allocator, "\t__zts_make_hot(\"");
            try wrapped.appendSlice(allocator, module.dev_id);
            try wrapped.appendSlice(allocator, "\").accept(function(m) {\n");
            try wrapped.appendSlice(allocator, "\t\tif (__zts_isReactRefreshBoundary(m)) __zts_enqueueUpdate();\n");
            try wrapped.appendSlice(allocator, "\t\telse __zts_reload();\n");
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

    // 소스맵 매핑 수집: hoisted + body 매핑을 병합
    // 각각 wrapped 내에서의 삽입 위치(줄 수)를 오프셋으로 적용한다.
    var mappings: ?[]const SourceMap.Mapping = null;
    {
        var merged: std.ArrayList(SourceMap.Mapping) = .empty;
        defer merged.deinit(allocator);

        // hoisted function 매핑 (var/exports 선언 뒤, __esm 앞)
        if (hoist_mappings) |hm| {
            try merged.ensureTotalCapacity(allocator, hm.len);
            for (hm) |m| {
                var adjusted = m;
                adjusted.generated_line += hoist_preamble_lines;
                merged.appendAssumeCapacity(adjusted);
            }
        }

        // body 매핑 (__esm factory 안)
        if (body_cg.sm_builder) |*sm| {
            if (sm.mappings.items.len > 0) {
                try merged.ensureUnusedCapacity(allocator, sm.mappings.items.len);
                for (sm.mappings.items) |m| {
                    var adjusted = m;
                    adjusted.generated_line += body_preamble_lines;
                    merged.appendAssumeCapacity(adjusted);
                }
            }
        }

        if (merged.items.len > 0) {
            mappings = try allocator.dupe(SourceMap.Mapping, merged.items);
        }
    }

    return .{
        .code = try allocator.dupe(u8, wrapped.items),
        .mappings = mappings,
    };
}

/// __export() 내부의 "name: () => value,\n" 한 줄을 출력한다.
/// property 이름에 따옴표가 필요하면 자동으로 감싼다.
fn appendExportGetter(
    buf: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    name: []const u8,
    value: []const u8,
    es5: bool,
) !void {
    try buf.appendSlice(allocator, "\t");
    if (needsPropertyQuote(name)) {
        try buf.appendSlice(allocator, "\"");
        try buf.appendSlice(allocator, name);
        try buf.appendSlice(allocator, "\"");
    } else {
        try buf.appendSlice(allocator, name);
    }
    if (es5) {
        try buf.appendSlice(allocator, ": function() { return ");
        try buf.appendSlice(allocator, value);
        try buf.appendSlice(allocator, "; },\n");
    } else {
        try buf.appendSlice(allocator, ": () => ");
        try buf.appendSlice(allocator, value);
        try buf.appendSlice(allocator, ",\n");
    }
}

/// export * from 체인을 따라가며 모든 export 이름을 수집한다.
/// ESM 스펙: export *는 "default"를 제외한 모든 named export를 전파한다.
/// diamond export * 패턴(A→B,C / B,C→D)에서 무한 재귀를 방지하기 위해 visited로 모듈 추적.
fn collectStarExportNames(
    l: *const Linker,
    mod_idx: u32,
    seen: *std.StringHashMap(void),
    visited: *std.AutoHashMap(u32, void),
) !void {
    if (mod_idx >= l.modules.len) return;
    if (visited.contains(mod_idx)) return;
    try visited.put(mod_idx, {});
    const m = &l.modules[mod_idx];

    // 직접 선언된 export 수집 (local + re_export + named re_export_all)
    for (m.export_bindings) |eb| {
        if (eb.kind == .re_export_all and std.mem.eql(u8, eb.exported_name, "*")) continue;
        if (!seen.contains(eb.exported_name)) {
            try seen.put(eb.exported_name, {});
        }
    }

    // export * from 재귀 — 소스 모듈의 export도 수집
    for (m.export_bindings) |eb| {
        if (eb.kind != .re_export_all) continue;
        if (!std.mem.eql(u8, eb.exported_name, "*")) continue;
        const rec_idx = eb.import_record_index orelse continue;
        if (rec_idx >= m.import_records.len) continue;
        const source_mod_idx = m.import_records[rec_idx].resolved;
        if (source_mod_idx.isNone()) continue;
        try collectStarExportNames(l, @intFromEnum(source_mod_idx), seen, visited);
    }
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
) ![]const u8 {
    switch (src_mod.wrap_kind) {
        .none => {
            // scope-hoisted: export의 local_name을 찾아 canonical name으로 변환
            for (src_mod.export_bindings) |src_eb| {
                if (std.mem.eql(u8, src_eb.exported_name, name)) {
                    const local = l.getCanonicalName(src_i, src_eb.local_name) orelse src_eb.local_name;
                    return try allocator.dupe(u8, local);
                }
            }
            // 직접 export에 없으면 소스의 re_export_all 체인을 따라간다.
            // resolveExportChain으로 canonical 이름을 찾는다.
            if (l.resolveExportChain(@enumFromInt(src_i), name, 0)) |resolved| {
                const canonical_mod_i = @intFromEnum(resolved.module_index);
                const canonical_mod = &l.modules[canonical_mod_i];
                // canonical 모듈이 래핑되어 있으면 exports_xxx.name 형태
                if (canonical_mod.wrap_kind == .esm) {
                    const ev = try types.makeExportsVarName(allocator, canonical_mod.path);
                    defer allocator.free(ev);
                    return try std.fmt.allocPrint(allocator, "{s}.{s}", .{ ev, name });
                }
                if (canonical_mod.wrap_kind == .cjs) {
                    const rv = try types.makeRequireVarName(allocator, canonical_mod.path);
                    defer allocator.free(rv);
                    return try std.fmt.allocPrint(allocator, "{s}().{s}", .{ rv, name });
                }
                // .none: canonical 로컬 변수
                for (canonical_mod.export_bindings) |ceb| {
                    if (std.mem.eql(u8, ceb.exported_name, resolved.export_name)) {
                        const local = l.getCanonicalName(canonical_mod_i, ceb.local_name) orelse ceb.local_name;
                        return try allocator.dupe(u8, local);
                    }
                }
            }
            // fallback: 이름 그대로 사용
            return try allocator.dupe(u8, name);
        },
        .esm => {
            const ev = try types.makeExportsVarName(allocator, src_mod.path);
            defer allocator.free(ev);
            return try std.fmt.allocPrint(allocator, "{s}.{s}", .{ ev, name });
        },
        .cjs => {
            const rv = try types.makeRequireVarName(allocator, src_mod.path);
            defer allocator.free(rv);
            return try std.fmt.allocPrint(allocator, "{s}().{s}", .{ rv, name });
        },
    }
}
