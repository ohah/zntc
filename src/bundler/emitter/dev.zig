//! Dev mode 번들링 — emitDevBundle, wrapWithRegister, emitDevModule
//! HMR 런타임 + __zts_register() 팩토리 래핑.

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
const parent = @import("../emitter.zig");
const EmitOptions = parent.EmitOptions;

pub const DevBundleResult = struct {
    /// 전체 번들 출력 (HMR 런타임 + 모든 모듈 __zts_register). allocator 소유.
    output: []const u8,
    /// 모듈별 __zts_register() 코드. HMR 모듈 단위 업데이트용. allocator 소유.
    module_codes: []const ModuleDevCode,
    /// 번들 소스맵 JSON (V3). null이면 소스맵 미생성. allocator 소유.
    sourcemap: ?[]const u8 = null,

    pub const ModuleDevCode = struct {
        id: []const u8,
        code: []const u8,
    };

    pub fn deinitCodes(codes: []const ModuleDevCode, allocator: std.mem.Allocator) void {
        for (codes) |c| {
            allocator.free(c.id);
            allocator.free(c.code);
        }
        allocator.free(codes);
    }
};

pub fn emitDevBundle(
    allocator: std.mem.Allocator,
    graph: *const ModuleGraph,
    options: EmitOptions,
    linker: ?*const Linker,
) !DevBundleResult {
    // 1. JS/JSON 모듈 필터 + exec_index 순 정렬
    var sorted: std.ArrayList(*const Module) = .empty;
    defer sorted.deinit(allocator);

    for (graph.modules.items) |*m| {
        const m_is_asset = m.loader.isAsset() and m.source.len > 0;
        if ((m.module_type == .javascript and (m.ast != null or m.is_disabled or m_is_asset)) or m.module_type == .json) {
            try sorted.append(allocator, m);
        }
    }

    std.mem.sort(*const Module, sorted.items, {}, Module.bundleOrderLessThan);

    // 2. 출력 빌드
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);

    // 소스맵 줄 번호 추적 (banner + polyfill + HMR 런타임 포함)
    var bundle_line: u32 = 0;

    // banner 주입 (--banner:js)
    if (options.banner_js) |banner| {
        try output.appendSlice(allocator, banner);
        try output.append(allocator, '\n');
        bundle_line += 1;
    }

    // 폴리필 주입 (--polyfill): IIFE로 감싸서 즉시 실행.
    for (options.polyfills) |poly| {
        if (!options.minify_whitespace) {
            try output.appendSlice(allocator, "// --- polyfill: ");
            try output.appendSlice(allocator, poly.name);
            try output.appendSlice(allocator, " ---\n");
            bundle_line += 1;
        }
        try output.appendSlice(allocator, "(function(){");
        if (!options.minify_whitespace) try output.append(allocator, '\n');
        try output.appendSlice(allocator, poly.content);
        if (!options.minify_whitespace) try output.append(allocator, '\n');
        try output.appendSlice(allocator, "})();\n");
        bundle_line += @intCast(std.mem.count(u8, poly.content, "\n") + 3);
    }

    // HMR 런타임 주입
    if (options.minify_whitespace) {
        try output.appendSlice(allocator, rt.HMR_RUNTIME_MIN);
    } else {
        try output.appendSlice(allocator, rt.HMR_RUNTIME);
    }

    // CJS/ESM interop 헬퍼 주입: __toESM (CJS default import 호환)
    // ES5 호환 여부에 따라 configurable 버전 선택 (React Native/Hermes는 configurable 필요)
    {
        const before_len = output.items.len;
        try rt.appendCjsRuntime(&output, allocator, options.minify_whitespace, options.unsupported.arrow);
        bundle_line += @intCast(std.mem.count(u8, output.items[before_len..], "\n"));
    }

    // ES5 런타임 헬퍼 주입: dev mode에서는 모듈이 factory 스코프 안에서 실행되므로
    // 헬퍼를 글로벌 스코프(모듈 밖)에 미리 정의해야 한다.
    // unsupported.arrow == true면 ES5 타겟 → 모든 ES5 헬퍼를 무조건 주입.
    if (options.unsupported.arrow or options.unsupported.class) {
        const all_helpers: RuntimeHelpers = .{
            .class_call_check = true,
            .call_super = true,
            .extends = true,
            .async_helper = true,
            .generator = true,
            .rest = true,
            .spread_array = true,
            .values = true,
            .tagged_template_literal = true,
        };
        const before_len = output.items.len;
        try rt.appendRuntimeHelpers(&output, allocator, all_helpers, options.minify_whitespace, options.unsupported.arrow);
        bundle_line += @intCast(std.mem.count(u8, output.items[before_len..], "\n"));
    }

    // per-module codes 수집 (한 번의 transform 패스에서 동시 생성)
    var module_codes: std.ArrayList(DevBundleResult.ModuleDevCode) = .empty;
    errdefer {
        for (module_codes.items) |c| {
            allocator.free(c.id);
            allocator.free(c.code);
        }
        module_codes.deinit(allocator);
    }

    // 번들 레벨 소스맵 빌더 (소스맵 활성화 시)
    var bundle_sm: ?SourceMap.SourceMapBuilder = if (options.sourcemap) blk: {
        var sm = SourceMap.SourceMapBuilder.init(allocator);
        sm.source_root = options.source_root orelse "";
        sm.sources_content = options.sources_content;
        break :blk sm;
    } else null;
    defer if (bundle_sm) |*sm| sm.deinit();

    // HMR 런타임 줄 수 반영
    bundle_line += if (!options.minify_whitespace) rt.HMR_RUNTIME_LINES else 1;

    // 3. 각 모듈을 __zts_register로 래핑
    for (sorted.items) |m| {
        const module_id = makeModuleId(m.path, options.root_dir);
        const emit_result = try emitDevModule(allocator, m, options, linker) orelse continue;
        defer allocator.free(emit_result.code);
        defer if (emit_result.mappings) |maps| allocator.free(maps);

        // dependency map 빌드: CJS require("../foo") → resolved module ID
        var dep_entries: std.ArrayList(DepMapEntry) = .empty;
        defer dep_entries.deinit(allocator);
        for (m.import_records) |rec| {
            if (rec.is_external) continue;
            if (rec.resolved.isNone()) continue;
            const resolved_idx = @intFromEnum(rec.resolved);
            if (resolved_idx >= graph.modules.items.len) continue;
            const resolved_mod = graph.modules.items[resolved_idx];
            const resolved_id = makeModuleId(resolved_mod.path, options.root_dir);
            // specifier가 이미 resolved_id와 같으면 맵에 추가할 필요 없음
            if (!std.mem.eql(u8, rec.specifier, resolved_id)) {
                try dep_entries.append(allocator, .{
                    .specifier = rec.specifier,
                    .resolved_id = resolved_id,
                });
            }
        }

        // __zts_register 래핑 코드 생성
        const dep_map: ?[]const DepMapEntry = if (dep_entries.items.len > 0) dep_entries.items else null;
        const wrapped = try wrapWithRegister(allocator, module_id, emit_result.code, dep_map, options.minify_whitespace);
        errdefer allocator.free(wrapped);

        // per-module code 저장 (collect_module_codes=true일 때만, 메모리 절감)
        if (options.collect_module_codes) {
            try module_codes.append(allocator, .{
                .id = try allocator.dupe(u8, module_id),
                .code = try allocator.dupe(u8, wrapped),
            });
        }

        // 번들에 추가
        if (!options.minify_whitespace) {
            try output.appendSlice(allocator, "// --- ");
            try output.appendSlice(allocator, std.fs.path.basename(m.path));
            try output.appendSlice(allocator, " ---\n");
            bundle_line += 1; // comment line
        }
        try output.appendSlice(allocator, wrapped);

        // 소스맵: 모듈 매핑을 번들 오프셋으로 조정하여 추가
        if (bundle_sm) |*sm| {
            if (emit_result.mappings) |maps| {
                // __zts_register header 1줄 + preamble 줄 수
                const offset = 1 + emit_result.preamble_lines;
                try addModuleMappings(
                    sm,
                    module_id,
                    m.source,
                    maps,
                    bundle_line,
                    offset,
                    options.sources_content,
                    true, // dev 모드: tab 들여쓰기 보정
                );
            }
        }

        // 번들 줄 번호 추적
        bundle_line += @intCast(std.mem.count(u8, wrapped, "\n"));
        allocator.free(wrapped);
        if (!options.minify_whitespace) {
            bundle_line += 1; // trailing newline
            try output.append(allocator, '\n');
        }
    }

    // entry point 실행: lazy evaluation이므로 명시적으로 require해야 모듈 체인 시작
    for (sorted.items) |m| {
        if (m.is_entry_point) {
            const entry_id = makeModuleId(m.path, options.root_dir);
            try output.appendSlice(allocator, "__zts_require(\"");
            try output.appendSlice(allocator, entry_id);
            try output.appendSlice(allocator, "\");\n");
            bundle_line += 1;
        }
    }

    // Sentry Debug ID (UUID v4) — sourcemap_debug_ids 활성화 시 생성
    var debug_id_buf: [36]u8 = undefined;
    const debug_id: ?[]const u8 = if (options.sourcemap_debug_ids) blk: {
        SourceMap.generateUuidV4(&debug_id_buf);
        break :blk &debug_id_buf;
    } else null;

    // 소스맵 JSON 생성
    var sourcemap_json: ?[]const u8 = null;
    if (bundle_sm) |*sm| {
        sm.debug_id = debug_id;
        const json = try sm.generateJSON(options.output_filename);
        sourcemap_json = try allocator.dupe(u8, json);
    }

    // 소스맵 참조 추가
    if (sourcemap_json != null) {
        try output.appendSlice(allocator, "//# sourceMappingURL=/");
        try output.appendSlice(allocator, options.output_filename);
        try output.appendSlice(allocator, ".map\n");
    }

    // debugId 주석 추가 (sourceMappingURL 뒤)
    if (debug_id) |did| {
        try output.appendSlice(allocator, "//# debugId=");
        try output.appendSlice(allocator, did);
        try output.append(allocator, '\n');
    }

    return .{
        .output = try output.toOwnedSlice(allocator),
        .module_codes = if (options.collect_module_codes) try module_codes.toOwnedSlice(allocator) else &.{},
        .sourcemap = sourcemap_json,
    };
}

/// __zts_register("id", {depMap}, function(...) { code }) 래핑 코드를 생성한다.
/// depMap: import specifier → resolved module ID 맵 (CJS require() resolve용).
/// emitDevBundle과 외부에서 공용으로 사용.
pub fn wrapWithRegister(
    allocator: std.mem.Allocator,
    module_id: []const u8,
    code: []const u8,
    dep_map: ?[]const DepMapEntry,
    minify: bool,
) ![]const u8 {
    var wrapped: std.ArrayList(u8) = .empty;
    errdefer wrapped.deinit(allocator);

    try wrapped.appendSlice(allocator, "__zts_register(\"");
    try wrapped.appendSlice(allocator, module_id);

    // dependency map: {"../foo": "resolved/foo.js", ...}
    try wrapped.appendSlice(allocator, if (minify) "\"," else "\", ");
    if (dep_map) |deps| {
        try wrapped.append(allocator, '{');
        for (deps, 0..) |dep, i| {
            if (i > 0) try wrapped.append(allocator, ',');
            try wrapped.append(allocator, '"');
            try wrapped.appendSlice(allocator, dep.specifier);
            try wrapped.appendSlice(allocator, if (minify) "\":\"" else "\": \"");
            try wrapped.appendSlice(allocator, dep.resolved_id);
            try wrapped.append(allocator, '"');
        }
        try wrapped.append(allocator, '}');
    } else {
        try wrapped.appendSlice(allocator, "null");
    }

    if (minify) {
        try wrapped.appendSlice(allocator, ",function(module,exports,require){");
        try wrapped.appendSlice(allocator, code);
        try wrapped.appendSlice(allocator, "});");
    } else {
        try wrapped.appendSlice(allocator, ", function(module, exports, require) {\n");
        // 모듈 코드 들여쓰기
        var rest: []const u8 = code;
        while (std.mem.indexOfScalar(u8, rest, '\n')) |nl| {
            try wrapped.appendSlice(allocator, rest[0 .. nl + 1]);
            try wrapped.append(allocator, '\t');
            rest = rest[nl + 1 ..];
        }
        try wrapped.appendSlice(allocator, rest);
        try wrapped.appendSlice(allocator, "\n});");
    }

    return wrapped.toOwnedSlice(allocator);
}

pub const DepMapEntry = struct {
    specifier: []const u8,
    resolved_id: []const u8,
};

/// Dev mode 단일 모듈 emit 결과.
pub const DevModuleEmitResult = struct {
    code: []const u8,
    /// 소스맵 매핑 (소스맵 활성화 시). generated_line/col은 code 기준 (오프셋 미적용).
    mappings: ?[]const SourceMap.Mapping = null,
    /// preamble(cjs_import_preamble 등)으로 인한 줄 오프셋.
    preamble_lines: u32 = 0,
    /// 이 모듈이 사용하는 런타임 헬퍼 플래그 (ES5 등)
    helpers: RuntimeHelpers = .{},
};

/// Dev mode용 단일 모듈 변환.
/// 프로덕션 emitModule과의 차이:
///   - buildDevMetadataForAst 사용 (rename 없음, __zts_require preamble)
///   - final_exports → exports.x = x; 형태
pub fn emitDevModule(
    allocator: std.mem.Allocator,
    module: *const Module,
    options: EmitOptions,
    linker: ?*const Linker,
) !?DevModuleEmitResult {
    const ast = &(module.ast orelse return null);

    var emit_arena = std.heap.ArenaAllocator.init(allocator);
    defer emit_arena.deinit();
    const arena_alloc = emit_arena.allocator();

    // JSX lowering: 번들 모드에서 Transformer가 jsx_element → call_expression 변환
    const jsx_active_dev = ast.has_jsx;
    var transformer = try Transformer.init(arena_alloc, ast, .{
        .react_refresh = options.react_refresh,
        .define = options.define,
        .experimental_decorators = options.experimental_decorators,
        .use_define_for_class_fields = options.use_define_for_class_fields,
        .unsupported = options.unsupported,
        .jsx_transform = jsx_active_dev,
        .jsx_runtime = options.jsx_runtime,
        .jsx_factory = options.jsx_factory,
        .jsx_fragment = options.jsx_fragment,
        .jsx_import_source = options.jsx_import_source,
        .jsx_filename = module.path,
    });
    if (module.semantic) |sem| {
        transformer.initSymbolIds(sem.symbol_ids) catch return error.OutOfMemory;
    }
    transformer.line_offsets = module.line_offsets;
    const root = try transformer.transform();

    // Dev mode 메타데이터: rename 없음, __zts_require preamble, exports epilogue
    var metadata: ?LinkingMetadata = null;
    defer if (metadata) |*md| md.deinit();

    if (linker) |l| {
        var md = try l.buildDevMetadataForAst(
            &transformer.ast,
            @intFromEnum(module.index),
            options.root_dir,
        );
        if (transformer.symbol_ids.items.len > 0) {
            md.symbol_ids = transformer.symbol_ids.items;
        }
        metadata = md;
    }

    // propagateCrossModulePurity 생략: dev mode에서는 tree-shaking이 꺼져 있으므로
    // @__NO_SIDE_EFFECTS__ cross-module 전파가 불필요하다.

    var cg = Codegen.initWithOptions(arena_alloc, &transformer.ast, .{
        .minify_whitespace = options.minify_whitespace,
        .module_format = .esm,
        .sourcemap = options.sourcemap,
        .linking_metadata = if (metadata) |*md| md else null,
        .platform = options.platform,
        .ascii_only = false,
        .source_root = options.source_root orelse "",
        .sources_content = options.sources_content,
    });
    // 소스맵용: line_offsets와 소스 파일 등록
    if (options.sourcemap) {
        cg.line_offsets = module.line_offsets;
        try cg.addSourceFile(makeModuleId(module.path, options.root_dir));
    }
    const code = try cg.generate(root);

    // 소스맵 매핑 복사 (arena 해제 전에)
    var mappings: ?[]SourceMap.Mapping = null;
    if (cg.sm_builder) |*sm| {
        if (sm.mappings.items.len > 0) {
            mappings = try allocator.dupe(SourceMap.Mapping, sm.mappings.items);
        }
    }

    // preamble (__zts_require) + code + epilogue (exports)
    const preamble = if (metadata) |md| md.cjs_import_preamble else null;
    const final_exports = if (metadata) |md| md.final_exports else null;

    // React Fast Refresh: 컴포넌트가 있는 모듈에 hot.accept() 자동 삽입
    const has_refresh = options.react_refresh and std.mem.indexOf(u8, code, "$RefreshReg$") != null;
    const hot_accept_suffix: []const u8 = if (has_refresh) "\nmodule.hot.accept();\n" else "";

    const needs_concat = preamble != null or final_exports != null or has_refresh;
    const preamble_line_count: u32 = if (preamble) |p| @intCast(std.mem.count(u8, p, "\n")) else 0;
    const final_code = if (needs_concat)
        try std.mem.concat(allocator, u8, &.{
            preamble orelse "",
            code,
            final_exports orelse "",
            hot_accept_suffix,
        })
    else
        try allocator.dupe(u8, code);

    return .{
        .code = final_code,
        .mappings = mappings,
        .preamble_lines = preamble_line_count,
        .helpers = transformer.runtime_helpers,
    };
}

/// 모듈 경로를 dev bundle용 ID로 변환.
/// root_dir이 있으면 상대 경로, 없으면 절대 경로 그대로 사용.
/// 모듈의 소스맵 매핑을 번들 레벨 SourceMapBuilder에 추가한다.
/// sourcesContent 등록 + preamble/wrapper 오프셋 반영을 한 곳에서 처리.
pub fn addModuleMappings(
    sm: *SourceMap.SourceMapBuilder,
    module_id: []const u8,
    source: []const u8,
    maps: []const SourceMap.Mapping,
    base_line: u32,
    preamble_lines: u32,
    sources_content: bool,
    /// dev 모드에서 tab 들여쓰기 보정이 필요하면 true
    indent_offset: bool,
) !void {
    const source_idx = try sm.addSource(module_id);
    if (sources_content and source.len > 0) {
        try sm.addSourceContent(source);
    }
    for (maps) |mapping| {
        try sm.addMapping(.{
            .generated_line = base_line + preamble_lines + mapping.generated_line,
            .generated_column = if (indent_offset and mapping.generated_line != 0)
                mapping.generated_column + 1
            else
                mapping.generated_column,
            .source_index = source_idx,
            .original_line = mapping.original_line,
            .original_column = mapping.original_column,
        });
    }
}

pub fn makeModuleId(path: []const u8, root_dir: ?[]const u8) []const u8 {
    const root = root_dir orelse return path;
    if (root.len == 0) return path;

    // root_dir prefix를 제거하여 상대 경로 생성
    if (std.mem.startsWith(u8, path, root)) {
        var rel = path[root.len..];
        // 선행 '/' 제거
        if (rel.len > 0 and rel[0] == '/') rel = rel[1..];
        if (rel.len > 0) return rel;
    }
    return path;
}
