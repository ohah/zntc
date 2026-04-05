//! ZTS Bundler — Emitter
//!
//! 모듈 그래프의 모듈들을 exec_index 순서로 변환+코드젠하여
//! 단일 파일 번들로 출력한다.
//!
//! 책임:
//!   - exec_index 순서 정렬
//!   - 각 모듈: Transformer → Codegen
//!   - 포맷별 래핑 (ESM/CJS/IIFE)
//!   - import/export 처리는 linker(별도 PR)에서 담당
//!
//! 설계:
//!   - Rollup 방식: emitter(finaliser)와 linker 분리 (유지보수 우선)
//!   - D058: exec_index 순서 = ESM 실행 순서

const std = @import("std");
const types = @import("types.zig");
const ModuleIndex = types.ModuleIndex;
const ModuleType = types.ModuleType;
const WrapKind = types.WrapKind;
const rt = @import("runtime_helpers.zig");

const chunk_mod = @import("chunk.zig");
const ChunkGraph = chunk_mod.ChunkGraph;
const Chunk = chunk_mod.Chunk;
const ChunkIndex = types.ChunkIndex;
const Module = @import("module.zig").Module;
const ModuleGraph = @import("graph.zig").ModuleGraph;
const ast_mod = @import("../parser/ast.zig");
const Ast = ast_mod.Ast;
const NodeIndex = ast_mod.NodeIndex;
const Transformer = @import("../transformer/transformer.zig").Transformer;
const RuntimeHelpers = @import("../transformer/transformer.zig").RuntimeHelpers;
const Codegen = @import("../codegen/codegen.zig").Codegen;
const CodegenOptions = @import("../codegen/codegen.zig").CodegenOptions;
const SourceMap = @import("../codegen/sourcemap.zig");
const Linker = @import("linker.zig").Linker;
const LinkingMetadata = @import("linker.zig").LinkingMetadata;
const TreeShaker = @import("tree_shaker.zig").TreeShaker;
const statement_shaker = @import("statement_shaker.zig");
const stmt_info_mod = @import("stmt_info.zig");
const ExportBinding = @import("binding_scanner.zig").ExportBinding;
const plugin_mod = @import("plugin.zig");

pub const EmitOptions = struct {
    format: Format = .esm,
    minify_whitespace: bool = false,
    /// AST 레벨 최적화 (constant folding, DCE 등)
    minify_syntax: bool = false,
    /// 소스맵 생성 활성화. dev mode에서는 번들 레벨 소스맵을 생성한다.
    sourcemap: bool = false,
    /// dev mode: 각 모듈을 __zts_register() 팩토리로 래핑하고
    /// HMR 런타임을 주입한다. import.meta.hot API 지원.
    dev_mode: bool = false,
    /// dev mode에서 모듈 ID 생성 시 기준 경로 (상대 경로 계산용).
    /// null이면 절대 경로를 그대로 사용.
    root_dir: ?[]const u8 = null,
    /// React Fast Refresh 활성화. $RefreshReg$/$RefreshSig$ 주입.
    react_refresh: bool = false,
    /// define 글로벌 치환 (--define:KEY=VALUE)
    define: []const @import("../transformer/transformer.zig").DefineEntry = &.{},
    /// legacy decorator 변환
    experimental_decorators: bool = false,
    /// useDefineForClassFields=false
    use_define_for_class_fields: bool = true,
    /// Unsupported features bitmask (ES/엔진 타겟에서 변환됨)
    unsupported: @import("../transformer/transformer.zig").TransformOptions.compat.UnsupportedFeatures = .{},
    /// 타겟 플랫폼. import.meta polyfill 방식을 결정한다.
    platform: @import("../codegen/codegen.zig").Platform = .browser,
    /// 에셋/청크 URL prefix (동적 import 경로에 적용)
    public_path: []const u8 = "",
    /// 번들 출력 앞에 삽입할 텍스트
    banner_js: ?[]const u8 = null,
    /// 번들 출력 뒤에 삽입할 텍스트
    footer_js: ?[]const u8 = null,
    /// IIFE 포맷에서 export를 바인딩할 글로벌 변수명
    global_name: ?[]const u8 = null,
    /// 출력 파일 확장자 오버라이드 (.mjs, .cjs 등)
    out_extension_js: ?[]const u8 = null,
    /// 출력 파일명 (소스맵 참조용, 예: "out.js")
    output_filename: []const u8 = "bundle.js",
    /// 소스맵 sourceRoot 필드
    source_root: ?[]const u8 = null,
    /// 소스맵에 sourcesContent 포함 여부
    sources_content: bool = true,
    /// UTF-8 문자를 이스케이프하지 않고 그대로 출력
    charset_utf8: bool = false,
    /// 엔트리 청크 파일명 패턴 (예: "[name]", "[name]-[hash]", "[dir]/[name]-[hash]")
    entry_names: []const u8 = "[name]",
    /// 공통 청크 파일명 패턴 (예: "[name]-[hash]", "chunks/[name]-[hash]")
    chunk_names: []const u8 = "[name]-[hash]",
    /// 에셋 파일명 패턴 (예: "[name]-[hash]", "assets/[name]-[hash]")
    asset_names: []const u8 = "[name]-[hash]",
    /// legal comments 처리 모드
    legal_comments: types.LegalComments = .default,
    /// --keep-names: minify 시 함수/클래스 .name 프로퍼티 보존
    keep_names: bool = false,
    /// JSX 런타임 모드
    jsx_runtime: @import("../codegen/codegen.zig").JsxRuntime = .classic,
    /// classic 모드 JSX factory
    jsx_factory: []const u8 = "React.createElement",
    /// classic 모드 Fragment factory
    jsx_fragment: []const u8 = "React.Fragment",
    /// automatic 모드 import source
    jsx_import_source: []const u8 = "react",
    /// 플러그인 배열. bundler에서 전파.
    plugins: []const plugin_mod.Plugin = &.{},
    /// 번들 시작 시 즉시 실행 폴리필. 각 항목은 { .name, .content }.
    /// IIFE로 감싸서 런타임 헬퍼 앞에 인라인. 파일 I/O는 bundler에서 완료.
    polyfills: []const PolyfillEntry = &.{},
    /// 엔트리 모듈 직전에 실행할 모듈 경로 (--run-before-main).
    /// 해당 모듈의 require_xxx() / init_xxx() 호출을 엔트리 코드 앞에 삽입.
    run_before_main: []const []const u8 = &.{},
    /// Object.defineProperty에 configurable: true 추가 (RN/Hermes 호환).
    configurable_exports: bool = false,

    pub const PolyfillEntry = struct {
        name: []const u8,
        content: []const u8,
    };

    pub const Format = types.Format;
};

pub const OutputFile = struct {
    path: []const u8,
    contents: []const u8,
};

/// 번들 출력 결과. output + 소스맵.
pub const EmitResult = struct {
    /// 번들 코드. allocator 소유.
    output: []const u8,
    /// 소스맵 JSON (V3). null이면 소스맵 미생성. allocator 소유.
    sourcemap: ?[]const u8 = null,

    pub fn deinit(self: *const EmitResult, allocator: std.mem.Allocator) void {
        allocator.free(self.output);
        if (self.sourcemap) |sm| allocator.free(sm);
    }
};

/// 모듈 그래프를 단일 번들로 출력한다.
pub fn emit(
    allocator: std.mem.Allocator,
    graph: *const ModuleGraph,
    options: EmitOptions,
    linker: ?*const Linker,
) !EmitResult {
    return emitWithTreeShaking(allocator, graph, options, linker, null);
}

/// tree-shaking 적용된 번들 출력. shaker가 null이면 모든 모듈 포함 (기존 동작).
pub fn emitWithTreeShaking(
    allocator: std.mem.Allocator,
    graph: *const ModuleGraph,
    options: EmitOptions,
    linker: ?*const Linker,
    shaker: ?*const TreeShaker,
) !EmitResult {
    // 1. JS/JSON 모듈 필터 + exec_index 순으로 정렬
    var sorted: std.ArrayList(*const Module) = .empty;
    defer sorted.deinit(allocator);

    for (graph.modules.items, 0..) |*m, i| {
        const is_asset = m.loader.isAsset() and m.source.len > 0;
        const is_js = (m.module_type == .javascript or m.module_type == .json) and (m.ast != null or m.is_disabled or is_asset);
        if (is_js) {
            // tree-shaking: 미포함 모듈 스킵
            if (shaker) |s| {
                if (!s.isIncluded(@intCast(i))) continue;
            }
            try sorted.append(allocator, m);
        }
    }

    std.mem.sort(*const Module, sorted.items, {}, Module.bundleOrderLessThan);

    // 2. 각 모듈을 변환 + 코드젠
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);

    // banner 삽입 (포맷별 prologue 직전)
    if (options.banner_js) |banner| {
        try output.appendSlice(allocator, banner);
        try output.append(allocator, '\n');
    }

    // 포맷별 prologue
    switch (options.format) {
        .iife => {
            if (options.global_name) |gn| {
                if (std.mem.indexOfScalar(u8, gn, '.') != null) {
                    try output.appendSlice(allocator, "/* [ZTS WARNING] Dotted globalName (\"");
                    try output.appendSlice(allocator, gn);
                    try output.appendSlice(allocator, "\") is not yet supported. Use a simple name. */\n");
                    try output.appendSlice(allocator, "(function() {\n");
                } else {
                    try output.appendSlice(allocator, "var ");
                    try output.appendSlice(allocator, gn);
                    try output.appendSlice(allocator, " = (function() {\n");
                }
            } else {
                try output.appendSlice(allocator, "(function() {\n");
            }
        },
        .cjs => try output.appendSlice(allocator, "\"use strict\";\n"),
        .esm => {},
    }

    // 폴리필 주입 (--polyfill): IIFE로 감싸서 즉시 실행.
    // Metro/롤리팝과 동일하게 모듈 그래프 밖에서 런타임 헬퍼보다 먼저 실행.
    for (options.polyfills) |poly| {
        if (!options.minify_whitespace) {
            try output.appendSlice(allocator, "// --- polyfill: ");
            try output.appendSlice(allocator, poly.name);
            try output.appendSlice(allocator, " ---\n");
        }
        try output.appendSlice(allocator, "(function(){");
        if (!options.minify_whitespace) try output.append(allocator, '\n');
        try output.appendSlice(allocator, poly.content);
        if (!options.minify_whitespace) try output.append(allocator, '\n');
        try output.appendSlice(allocator, "})();\n");
    }

    // 런타임 헬퍼 주입
    try emitBundleRuntimeHelpers(&output, allocator, sorted.items, options);

    // TLA 검증: 비-ESM 출력에서 TLA 사용 시 경고 주석 삽입.
    // Top-Level Await는 ESM 전용 기능이므로 CJS/IIFE 포맷에서는 동작하지 않는다.
    // DFS로 exec_index가 부여된 모듈만 확인한다 — 동적 import로만 도달하는 모듈은
    // exec_index가 maxInt(u32)이며, 비동기 로딩이므로 경고 불필요.
    if (options.format != .esm) {
        for (sorted.items) |m| {
            if (m.uses_top_level_await and m.exec_index != std.math.maxInt(u32)) {
                try output.appendSlice(allocator, "/* [ZTS WARNING] Top-level await requires ESM output format. */\n");
                break;
            }
        }
    }

    // ESM 출력 + external: esbuild와 동일하게 require() preamble만 사용.
    // import 구문이 없으면 Node가 CJS로 파싱하여 require()가 동작한다.
    // (createRequire shim은 ESM 파싱을 유발하여 var 재선언 에러를 일으킴)

    // 런타임 헬퍼 수집: 모듈별 transform에서 실제 사용된 헬퍼만 추적
    var collected_helpers: RuntimeHelpers = .{};

    // 엔트리 모듈 인덱스 (final exports / CJS auto-invoke용).
    // Module.is_entry_point 플래그로 정확히 식별 — 정렬 순서나 exec_index와 무관.
    const entry_idx: ?u32 = blk: {
        for (sorted.items) |m| {
            if (m.is_entry_point) break :blk @intFromEnum(m.index);
        }
        break :blk null;
    };

    // Phase 1: used_names 사전 계산 (순차 — 모듈 간 의존)
    const used_names_list = try computeAllUsedNames(allocator, sorted.items, graph, shaker);
    defer {
        for (used_names_list) |un| {
            allocator.free(un.names);
        }
        allocator.free(used_names_list);
    }

    // Phase 2: emitModule 병렬 실행 (2개 이상이면 스레드 풀, 아니면 순차)
    var results = try allocator.alloc(ModuleEmitResult, sorted.items.len);
    defer {
        for (results) |r| {
            if (r.code) |c| allocator.free(c);
            if (r.mappings) |m| allocator.free(m);
        }
        allocator.free(results);
    }
    for (results) |*r| r.* = .{};

    var use_pool = sorted.items.len >= 2;
    var pool: std.Thread.Pool = undefined;
    if (use_pool) {
        use_pool = if (pool.init(.{ .allocator = allocator })) |_| true else |_| false;
    }
    defer if (use_pool) pool.deinit();

    if (use_pool) {
        var wg: std.Thread.WaitGroup = .{};
        for (sorted.items, 0..) |m, i| {
            const is_entry = if (entry_idx) |ei| @intFromEnum(m.index) == ei else false;
            const used_names: ?[]const []const u8 = if (used_names_list[i].all_used) null else used_names_list[i].names;
            pool.spawnWg(&wg, emitModuleThread, .{ allocator, m, options, linker, is_entry, used_names, shaker, &results[i] });
        }
        pool.waitAndWork(&wg);
    } else {
        for (sorted.items, 0..) |m, i| {
            const is_entry = if (entry_idx) |ei| @intFromEnum(m.index) == ei else false;
            const used_names: ?[]const []const u8 = if (used_names_list[i].all_used) null else used_names_list[i].names;
            results[i].code = emitModule(allocator, m, options, linker, is_entry, used_names, shaker, &results[i].helpers, &results[i].mappings) catch null;
        }
    }

    // Phase 3: 순차 합류 — exec_index 순서대로 concat + helpers 합산 + 소스맵 수집
    var module_output: std.ArrayList(u8) = .empty;
    defer module_output.deinit(allocator);

    // 소스맵 빌더 (소스맵 활성화 시)
    var bundle_sm: ?SourceMap.SourceMapBuilder = if (options.sourcemap) blk: {
        var sm = SourceMap.SourceMapBuilder.init(allocator);
        sm.source_root = options.source_root orelse "";
        sm.sources_content = options.sources_content;
        break :blk sm;
    } else null;
    defer if (bundle_sm) |*sm| sm.deinit();

    // output에 이미 추가된 prologue/banner/polyfill/runtime helper 줄 수 추적
    // (module_output과 별도로 output에 먼저 들어감 — 아래에서 합류 시 사용)
    // 이 시점에서는 아직 runtime helper가 추가되지 않았으므로 0으로 시작하고
    // merge 시 output.items의 줄 수를 기준 오프셋으로 사용
    var module_line: u32 = 0;

    for (sorted.items, 0..) |m, i| {
        // helpers 합산 (bitwise OR)
        collected_helpers = @bitCast(@as(u16, @bitCast(collected_helpers)) | @as(u16, @bitCast(results[i].helpers)));

        const code = results[i].code orelse continue;

        // --run-before-main: 엔트리 모듈 직전에 해당 모듈의 require/init 호출 삽입.
        const is_entry = if (entry_idx) |ei| @intFromEnum(m.index) == ei else false;
        if (is_entry and options.run_before_main.len > 0) {
            for (options.run_before_main) |rbm_path| {
                for (graph.modules.items) |*rbm| {
                    if (std.mem.eql(u8, rbm.path, rbm_path)) {
                        const call_name = if (rbm.wrap_kind == .cjs)
                            types.makeRequireVarName(allocator, rbm.path) catch null
                        else
                            types.makeInitVarName(allocator, rbm.path) catch null;
                        if (call_name) |name| {
                            defer allocator.free(name);
                            try module_output.appendSlice(allocator, name);
                            try module_output.appendSlice(allocator, "();\n");
                            module_line += 1;
                        }
                        break;
                    }
                }
            }
        }

        if (!options.minify_whitespace) {
            try module_output.appendSlice(allocator, "// --- ");
            try module_output.appendSlice(allocator, std.fs.path.basename(m.path));
            try module_output.appendSlice(allocator, " ---\n");
            module_line += 1;
        }

        // 소스맵: 모듈 매핑을 번들 오프셋으로 조정하여 추가
        if (bundle_sm) |*sm| {
            if (results[i].mappings) |maps| {
                const module_id = makeModuleId(m.path, options.root_dir);
                const source_idx = try sm.addSource(module_id);
                for (maps) |mapping| {
                    try sm.addMapping(.{
                        .generated_line = module_line + mapping.generated_line,
                        .generated_column = mapping.generated_column,
                        .source_index = source_idx,
                        .original_line = mapping.original_line,
                        .original_column = mapping.original_column,
                    });
                }
            }
        }

        try module_output.appendSlice(allocator, code);
        module_line += @intCast(std.mem.count(u8, code, "\n"));
        if (!options.minify_whitespace) {
            try module_output.append(allocator, '\n');
            module_line += 1;
        }
    }

    // ES2015 런타임 헬퍼 주입: transformer가 실제 사용한 헬퍼만 주입
    try rt.appendRuntimeHelpers(&output, allocator, collected_helpers, options.minify_whitespace, options.unsupported.arrow);

    // 모듈 코드 합류
    try output.appendSlice(allocator, module_output.items);

    // Plugin: renderChunk 훅 — 단일 파일 모드에서도 적용
    if (options.plugins.len > 0) {
        const runner = plugin_mod.PluginRunner.init(options.plugins);
        const rc_result = runner.runRenderChunk(output.items, "bundle", allocator) catch |err| switch (err) {
            error.PluginFailed => null,
            error.OutOfMemory => return error.OutOfMemory,
        };
        if (rc_result) |result| {
            output.clearRetainingCapacity();
            try output.appendSlice(allocator, result);
            allocator.free(result);
        }
    }

    // CJS 엔트리 자동 호출: __commonJS로 래핑된 엔트리 모듈은 require_xxx()를 호출해야 실행됨.
    // esbuild와 동일하게 번들 끝(IIFE epilogue 직전)에 require_xxx() 삽입.
    // entry_idx로 실제 엔트리 모듈을 찾는다 (exec_index 기반).
    if (entry_idx) |ei| {
        for (sorted.items) |em| {
            if (@intFromEnum(em.index) == ei and em.wrap_kind == .cjs) {
                const call_name = try types.makeRequireVarName(allocator, em.path);
                defer allocator.free(call_name);
                try output.appendSlice(allocator, call_name);
                try output.appendSlice(allocator, "();\n");
                break;
            }
        }
    }

    // 포맷별 epilogue
    switch (options.format) {
        .iife => try output.appendSlice(allocator, "})();\n"),
        .cjs, .esm => {},
    }

    // legal comments (eof 모드): 모든 모듈의 legal comment를 파일 끝에 모아서 출력
    const lc_mode = resolveDefaultLegalComments(options.legal_comments, options.minify_whitespace);
    if (lc_mode == .eof or lc_mode == .linked or lc_mode == .external) {
        try collectLegalComments(&output, allocator, sorted.items, lc_mode);
    }

    // footer 삽입 (포맷별 epilogue 직후)
    if (options.footer_js) |footer| {
        try output.appendSlice(allocator, footer);
        try output.append(allocator, '\n');
    }

    // prologue(banner/polyfill/runtime helper) 줄 수 → 소스맵 오프셋에 반영
    const prologue_lines: u32 = @intCast(std.mem.count(u8, output.items, "\n"));

    // 소스맵 JSON 생성
    var sourcemap_json: ?[]const u8 = null;
    if (bundle_sm) |*sm| {
        // prologue 줄 수를 모든 매핑에 추가
        if (prologue_lines > 0) {
            for (sm.mappings.items) |*mapping| {
                mapping.generated_line += prologue_lines;
            }
        }
        const json = try sm.generateJSON(options.output_filename);
        sourcemap_json = try allocator.dupe(u8, json);
    }

    // 소스맵 참조 추가
    if (sourcemap_json != null) {
        try output.appendSlice(allocator, "//# sourceMappingURL=");
        try output.appendSlice(allocator, options.output_filename);
        try output.appendSlice(allocator, ".map\n");
    }

    return .{
        .output = try output.toOwnedSlice(allocator),
        .sourcemap = sourcemap_json,
    };
}

/// Dev mode 번들 출력.
///
/// 각 모듈을 `__zts_register(id, factory)` 팩토리로 래핑하고
/// HMR 런타임을 번들 상단에 주입한다.
/// 스코프 호이스팅 대신 모듈 레지스트리 기반 import/export를 사용.
///
/// 출력 형태:
/// ```js
/// // HMR Runtime
/// var __zts_modules = {}; ...
///
/// // Module: ./src/utils.ts
/// __zts_register("./src/utils.ts", function(__zts_module, __zts_exports) {
///   var { add } = __zts_require("./src/math.ts");
///   const result = add(1, 2);
///   __zts_exports.result = result;
/// });
/// ```
/// Dev mode 번들 결과. 전체 번들 + per-module codes + 소스맵을 한 번의 transform 패스로 생성.
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

        // __zts_register 래핑 코드 생성
        const wrapped = try wrapWithRegister(allocator, module_id, emit_result.code, options.minify_whitespace);
        errdefer allocator.free(wrapped);

        // per-module code 저장
        try module_codes.append(allocator, .{
            .id = try allocator.dupe(u8, module_id),
            .code = try allocator.dupe(u8, wrapped),
        });

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
                const source_idx = try sm.addSource(module_id);
                // __zts_register header는 1줄 ("__zts_register(..., function(...) {\n")
                const wrapper_header_lines: u32 = 1;
                // preamble(__zts_require 줄)은 mapping.generated_line에 포함되어 있으므로
                // 별도 offset 불필요 — emitDevModule이 preamble+code를 concat한 후 codegen 생성.

                for (maps) |mapping| {
                    try sm.addMapping(.{
                        .generated_line = bundle_line + wrapper_header_lines + mapping.generated_line,
                        .generated_column = if (mapping.generated_line == 0)
                            mapping.generated_column
                        else
                            mapping.generated_column + 1, // tab 들여쓰기 오프셋
                        .source_index = source_idx,
                        .original_line = mapping.original_line,
                        .original_column = mapping.original_column,
                    });
                }
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

    // 소스맵 JSON 생성
    var sourcemap_json: ?[]const u8 = null;
    if (bundle_sm) |*sm| {
        const json = try sm.generateJSON(options.output_filename);
        sourcemap_json = try allocator.dupe(u8, json);
    }

    // 소스맵 참조 추가
    if (sourcemap_json != null) {
        try output.appendSlice(allocator, "//# sourceMappingURL=/");
        try output.appendSlice(allocator, options.output_filename);
        try output.appendSlice(allocator, ".map\n");
    }

    return .{
        .output = try output.toOwnedSlice(allocator),
        .module_codes = try module_codes.toOwnedSlice(allocator),
        .sourcemap = sourcemap_json,
    };
}

/// __zts_register("id", function(...) { code }) 래핑 코드를 생성한다.
/// emitDevBundle과 외부에서 공용으로 사용.
pub fn wrapWithRegister(
    allocator: std.mem.Allocator,
    module_id: []const u8,
    code: []const u8,
    minify: bool,
) ![]const u8 {
    var wrapped: std.ArrayList(u8) = .empty;
    errdefer wrapped.deinit(allocator);

    try wrapped.appendSlice(allocator, "__zts_register(\"");
    try wrapped.appendSlice(allocator, module_id);

    if (minify) {
        try wrapped.appendSlice(allocator, "\",function(__zts_module,__zts_exports){");
        try wrapped.appendSlice(allocator, code);
        try wrapped.appendSlice(allocator, "});");
    } else {
        try wrapped.appendSlice(allocator, "\", function(__zts_module, __zts_exports) {\n");
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

/// Dev mode 단일 모듈 emit 결과.
pub const DevModuleEmitResult = struct {
    code: []const u8,
    /// 소스맵 매핑 (소스맵 활성화 시). generated_line/col은 code 기준 (오프셋 미적용).
    mappings: ?[]const SourceMap.Mapping = null,
};

/// Dev mode용 단일 모듈 변환.
/// 프로덕션 emitModule과의 차이:
///   - buildDevMetadataForAst 사용 (rename 없음, __zts_require preamble)
///   - final_exports → __zts_exports.x = x; 형태
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

    var transformer = Transformer.init(arena_alloc, ast, .{
        .react_refresh = options.react_refresh,
        .define = options.define,
        .experimental_decorators = options.experimental_decorators,
        .use_define_for_class_fields = options.use_define_for_class_fields,
        .unsupported = options.unsupported,
    });
    if (module.semantic) |sem| {
        transformer.old_symbol_ids = sem.symbol_ids;
    }
    const root = try transformer.transform();

    // Dev mode 메타데이터: rename 없음, __zts_require preamble, __zts_exports epilogue
    var metadata: ?LinkingMetadata = null;
    defer if (metadata) |*md| md.deinit();

    if (linker) |l| {
        var md = try l.buildDevMetadataForAst(
            &transformer.new_ast,
            @intFromEnum(module.index),
        );
        if (transformer.new_symbol_ids.items.len > 0) {
            md.symbol_ids = transformer.new_symbol_ids.items;
        }
        metadata = md;
    }

    // propagateCrossModulePurity 생략: dev mode에서는 tree-shaking이 꺼져 있으므로
    // @__NO_SIDE_EFFECTS__ cross-module 전파가 불필요하다.

    var cg = Codegen.initWithOptions(arena_alloc, &transformer.new_ast, .{
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

    // preamble (__zts_require) + code + epilogue (__zts_exports)
    const preamble = if (metadata) |md| md.cjs_import_preamble else null;
    const final_exports = if (metadata) |md| md.final_exports else null;

    // React Fast Refresh: 컴포넌트가 있는 모듈에 hot.accept() 자동 삽입
    const has_refresh = options.react_refresh and std.mem.indexOf(u8, code, "$RefreshReg$") != null;
    const hot_accept_suffix: []const u8 = if (has_refresh) "\n__zts_module.hot.accept();\n" else "";

    const needs_concat = preamble != null or final_exports != null or has_refresh;
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
    };
}

/// 모듈 경로를 dev bundle용 ID로 변환.
/// root_dir이 있으면 상대 경로, 없으면 절대 경로 그대로 사용.
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

/// 청크 그래프를 기반으로 다중 출력 파일을 생성한다 (code splitting).
///
/// 각 청크마다 하나의 OutputFile을 생성:
///   1. 크로스 청크 의존성에 대한 side-effect import 문 삽입 (실행 순서 보장)
///   2. 청크 내 모듈들을 exec_index 순서로 변환+코드젠
///   3. 출력 파일명은 엔트리 청크는 모듈명, 공통 청크는 chunk-{wyhash} 형식 (content-addressable)
///
/// 반환된 OutputFile 배열과 각 OutputFile의 path/contents는 모두 allocator 소유.
pub fn emitChunks(
    allocator: std.mem.Allocator,
    modules: []const Module,
    chunk_graph: *const ChunkGraph,
    options: EmitOptions,
    linker: ?*Linker,
) ![]OutputFile {
    // Code splitting은 ESM 출력만 지원 — CJS/IIFE에서는 네이티브 import()가 없음
    if (options.format != .esm) return error.CodeSplittingRequiresESM;

    var outputs: std.ArrayList(OutputFile) = .empty;
    errdefer {
        for (outputs.items) |o| {
            allocator.free(o.contents);
            allocator.free(o.path);
        }
        outputs.deinit(allocator);
    }

    // 청크를 exec_order 순으로 정렬하여 결정론적 출력 순서 보장.
    // 엔트리 청크가 먼저, 공통 청크가 나중에 오도록 정렬한다.
    const sorted_indices = try allocator.alloc(usize, chunk_graph.chunkCount());
    defer allocator.free(sorted_indices);
    for (sorted_indices, 0..) |*idx, i| idx.* = i;

    const SortCtx = struct {
        chunks: []const Chunk,
        fn lessThan(ctx: @This(), a: usize, b: usize) bool {
            const ca = ctx.chunks[a];
            const cb = ctx.chunks[b];
            // 엔트리 청크 우선
            const a_is_entry: u1 = if (ca.isEntryPoint()) 0 else 1;
            const b_is_entry: u1 = if (cb.isEntryPoint()) 0 else 1;
            if (a_is_entry != b_is_entry) return a_is_entry < b_is_entry;
            // 같은 종류 내에서는 exec_order 순
            return ca.exec_order < cb.exec_order;
        }
    };
    std.mem.sort(usize, sorted_indices, SortCtx{ .chunks = chunk_graph.chunks.items }, SortCtx.lessThan);

    for (sorted_indices) |ci| {
        const chunk = &chunk_graph.chunks.items[ci];

        var chunk_output: std.ArrayList(u8) = .empty;
        errdefer chunk_output.deinit(allocator);

        // 출력 확장자 (cross-chunk import 경로 + 파일명에 공용)
        const ext = options.out_extension_js orelse ".js";

        // banner 삽입 (각 청크 출력 앞)
        if (options.banner_js) |banner| {
            try chunk_output.appendSlice(allocator, banner);
            try chunk_output.append(allocator, '\n');
        }

        // 청크별 런타임 헬퍼 주입
        try emitChunkRuntimeHelpers(&chunk_output, allocator, chunk, modules, options);

        // 크로스 청크 import deconfliction:
        // 여러 청크에서 같은 이름의 심볼을 import할 때 충돌 방지.
        // 1단계: 모든 청크로부터의 import 이름 출현 횟수 카운트
        // 2단계: 중복 이름은 `import { x as x$2 }` 형태로 alias 부여
        var name_total_count: std.StringHashMapUnmanaged(u32) = .empty;
        defer name_total_count.deinit(allocator);
        for (chunk.cross_chunk_imports.items) |dep_chunk_idx| {
            const dep_ci = @intFromEnum(dep_chunk_idx);
            if (chunk.imports_from.get(dep_ci)) |syms| {
                for (syms.items) |name| {
                    const gop = try name_total_count.getOrPut(allocator, name);
                    if (!gop.found_existing) gop.value_ptr.* = 0;
                    gop.value_ptr.* += 1;
                }
            }
        }

        // 2단계: import 문 생성 (중복 이름은 alias 부여)
        var name_seen_count: std.StringHashMapUnmanaged(u32) = .empty;
        defer name_seen_count.deinit(allocator);

        // alias 문자열을 임시 저장 (defer free)
        var alias_strs: std.ArrayList([]const u8) = .empty;
        defer {
            for (alias_strs.items) |s| allocator.free(s);
            alias_strs.deinit(allocator);
        }

        for (chunk.cross_chunk_imports.items) |dep_chunk_idx| {
            const dep_chunk = chunk_graph.getChunk(dep_chunk_idx);
            var dep_buf: [128]u8 = undefined;
            const dep_stem = chunkPlaceholderStem(dep_chunk, &dep_buf, options);
            const dep_ci = @intFromEnum(dep_chunk_idx);

            // imports_from에서 이 청크→dep_chunk로 가져오는 심볼 목록 조회
            const symbols = chunk.imports_from.get(dep_ci);

            if (symbols != null and symbols.?.items.len > 0) {
                // 심볼 수준 import: import { a, b } from './chunk-xxx.js';
                if (!options.minify_whitespace) {
                    try chunk_output.appendSlice(allocator, "import { ");
                } else {
                    try chunk_output.appendSlice(allocator, "import{");
                }
                // 결정론적 출력을 위해 심볼명 정렬
                std.mem.sort([]const u8, symbols.?.items, {}, types.stringLessThan);
                for (symbols.?.items, 0..) |name, si| {
                    const total = name_total_count.get(name) orelse 1;
                    const seen_gop = try name_seen_count.getOrPut(allocator, name);
                    if (!seen_gop.found_existing) seen_gop.value_ptr.* = 0;
                    seen_gop.value_ptr.* += 1;
                    const seen = seen_gop.value_ptr.*;

                    if (total > 1 and seen > 1) {
                        // 중복 이름 → alias 부여: import { x as x$2 }
                        const alias = try std.fmt.allocPrint(allocator, "{s}${d}", .{ name, seen });
                        try alias_strs.append(allocator, alias);
                        try chunk_output.appendSlice(allocator, name);
                        try chunk_output.appendSlice(allocator, " as "); // `as`는 키워드이므로 공백 필수
                        try chunk_output.appendSlice(allocator, alias);
                    } else {
                        try chunk_output.appendSlice(allocator, name);
                    }
                    if (si + 1 < symbols.?.items.len) {
                        if (!options.minify_whitespace) {
                            try chunk_output.appendSlice(allocator, ", ");
                        } else {
                            try chunk_output.append(allocator, ',');
                        }
                    }
                }
                if (!options.minify_whitespace) {
                    try chunk_output.appendSlice(allocator, " } from \"./");
                    try chunk_output.appendSlice(allocator, dep_stem);
                    try chunk_output.appendSlice(allocator, ext);
                    try chunk_output.appendSlice(allocator, "\";\n");
                } else {
                    try chunk_output.appendSlice(allocator, "}from\"./");
                    try chunk_output.appendSlice(allocator, dep_stem);
                    try chunk_output.appendSlice(allocator, ext);
                    try chunk_output.appendSlice(allocator, "\";");
                }
            } else {
                // 심볼 정보 없음 → side-effect import (실행 순서 보장용)
                if (!options.minify_whitespace) {
                    try chunk_output.appendSlice(allocator, "import \"./");
                    try chunk_output.appendSlice(allocator, dep_stem);
                    try chunk_output.appendSlice(allocator, ext);
                    try chunk_output.appendSlice(allocator, "\";\n");
                } else {
                    try chunk_output.appendSlice(allocator, "import\"./");
                    try chunk_output.appendSlice(allocator, dep_stem);
                    try chunk_output.appendSlice(allocator, ext);
                    try chunk_output.appendSlice(allocator, "\";");
                }
            }
        }

        // 청크 내 모듈을 exec_index 순으로 정렬
        const sorted_mods = try allocator.alloc(ModuleIndex, chunk.modules.items.len);
        defer allocator.free(sorted_mods);
        @memcpy(sorted_mods, chunk.modules.items);

        const ModSortCtx = struct {
            mods: []const Module,
            fn lessThan(ctx: @This(), a: ModuleIndex, b: ModuleIndex) bool {
                const ai = @intFromEnum(a);
                const bi = @intFromEnum(b);
                const a_exec = if (ai < ctx.mods.len) ctx.mods[ai].exec_index else std.math.maxInt(u32);
                const b_exec = if (bi < ctx.mods.len) ctx.mods[bi].exec_index else std.math.maxInt(u32);
                return a_exec < b_exec;
            }
        };
        std.mem.sort(ModuleIndex, sorted_mods, ModSortCtx{ .mods = modules }, ModSortCtx.lessThan);

        // cross-chunk import 이름 수집 — 점유 이름으로 등록하여 로컬과 충돌 방지.
        // alias가 부여된 이름(x$2 등)도 점유 이름에 포함하여 로컬 변수와의 충돌 방지.
        var occupied: std.ArrayList([]const u8) = .empty;
        defer occupied.deinit(allocator);
        {
            var ifit = chunk.imports_from.iterator();
            while (ifit.next()) |if_entry| {
                for (if_entry.value_ptr.items) |name| {
                    try occupied.append(allocator, name);
                }
            }
            // deconfliction alias 이름도 점유 목록에 추가
            for (alias_strs.items) |alias| {
                try occupied.append(allocator, alias);
            }
        }

        // per-chunk 리네임 계산: 각 청크는 독립된 네임스페이스이므로
        // 청크 내 모듈들만 대상으로 이름 충돌을 감지한다.
        if (linker) |l| {
            try l.computeRenamesForModules(sorted_mods, occupied.items);
        }

        // 엔트리 모듈 인덱스 (final exports용)
        const entry_mod_idx: ?u32 = switch (chunk.kind) {
            .entry_point => |info| @intFromEnum(info.module),
            .common => null,
        };

        for (sorted_mods) |mod_idx| {
            const mi = @intFromEnum(mod_idx);
            if (mi >= modules.len) continue;
            const m = &modules[mi];

            const is_entry = if (entry_mod_idx) |ei| mi == ei else false;
            const raw_code = try emitModule(allocator, m, options, linker, is_entry, null, null, null, null) orelse continue;
            defer allocator.free(raw_code);

            // 동적 import 경로 리라이트: import('./page') → import('./page.js')
            const code = try rewriteDynamicImports(allocator, raw_code, m, chunk_graph, options.public_path, ext, options);
            defer allocator.free(code);

            if (!options.minify_whitespace) {
                try chunk_output.appendSlice(allocator, "// --- ");
                try chunk_output.appendSlice(allocator, std.fs.path.basename(m.path));
                try chunk_output.appendSlice(allocator, " ---\n");
            }
            try chunk_output.appendSlice(allocator, code);
            if (!options.minify_whitespace) {
                try chunk_output.append(allocator, '\n');
            }
        }

        // 크로스 청크 export: exports_to에 심볼이 있으면 export 문 생성.
        // 다른 청크가 이 청크에서 심볼을 가져가는 경우에만 출력.
        // linker가 심볼을 rename한 경우 export { local_name as export_name } 형태로 출력.
        if (chunk.exports_to.count() > 0) {
            // 결정론적 출력을 위해 이름을 정렬
            var export_names: std.ArrayList([]const u8) = .empty;
            defer export_names.deinit(allocator);
            var eit = chunk.exports_to.iterator();
            while (eit.next()) |entry| {
                try export_names.append(allocator, entry.key_ptr.*);
            }
            std.mem.sort([]const u8, export_names.items, {}, types.stringLessThan);

            if (!options.minify_whitespace) {
                try chunk_output.appendSlice(allocator, "export { ");
            } else {
                try chunk_output.appendSlice(allocator, "export{");
            }
            for (export_names.items, 0..) |name, ni| {
                // export_name의 원본 심볼이 이 청크에서 rename되었는지 확인.
                // rename된 경우: export { local_name as export_name }
                // rename 안 된 경우: export { export_name }
                const local_name = if (linker) |l| blk: {
                    // exports_to의 이름은 canonical export name.
                    // 이 이름을 선언한 모듈을 찾아 linker의 canonical_names를 조회한다.
                    var found_local: ?[]const u8 = null;
                    for (sorted_mods) |mod_idx| {
                        const mi = @intFromEnum(mod_idx);
                        if (mi >= modules.len) continue;
                        if (l.getCanonicalName(@intCast(mi), name)) |renamed| {
                            found_local = renamed;
                            break;
                        }
                        // export의 local_name이 다를 수 있으므로 export_map도 확인
                        if (l.getExportLocalName(@intCast(mi), name)) |local| {
                            if (l.getCanonicalName(@intCast(mi), local)) |renamed| {
                                found_local = renamed;
                                break;
                            }
                        }
                    }
                    break :blk found_local orelse name;
                } else name;

                try chunk_output.appendSlice(allocator, local_name);
                // local_name과 export_name이 다르면 as 절 추가
                if (!std.mem.eql(u8, local_name, name)) {
                    try chunk_output.appendSlice(allocator, " as ");
                    try chunk_output.appendSlice(allocator, name);
                }
                if (ni + 1 < export_names.items.len) {
                    if (!options.minify_whitespace) {
                        try chunk_output.appendSlice(allocator, ", ");
                    } else {
                        try chunk_output.append(allocator, ',');
                    }
                }
            }
            if (!options.minify_whitespace) {
                try chunk_output.appendSlice(allocator, " };\n");
            } else {
                try chunk_output.appendSlice(allocator, "};");
            }
        }

        // Plugin: renderChunk 훅 — 청크 완성 후, footer 전
        if (options.plugins.len > 0) {
            const runner = plugin_mod.PluginRunner.init(options.plugins);
            var rc_stem_buf: [128]u8 = undefined;
            const rc_chunk_name = chunkPlaceholderStem(chunk, &rc_stem_buf, options);
            const chunk_rc_result = runner.runRenderChunk(chunk_output.items, rc_chunk_name, allocator) catch |err| switch (err) {
                error.PluginFailed => null,
                error.OutOfMemory => return error.OutOfMemory,
            };
            if (chunk_rc_result) |result| {
                chunk_output.clearRetainingCapacity();
                try chunk_output.appendSlice(allocator, result);
                allocator.free(result);
            }
        }

        // footer 삽입 (각 청크 출력 뒤)
        if (options.footer_js) |footer| {
            try chunk_output.appendSlice(allocator, footer);
            try chunk_output.append(allocator, '\n');
        }

        // 출력 파일명 생성: "{stem}{ext}" (placeholder hash 포함, 나중에 치환)
        var stem_buf: [128]u8 = undefined;
        const stem = chunkPlaceholderStem(chunk, &stem_buf, options);
        const filename = try std.fmt.allocPrint(allocator, "{s}{s}", .{ stem, ext });
        errdefer allocator.free(filename);

        try outputs.append(allocator, .{
            .path = filename,
            .contents = try chunk_output.toOwnedSlice(allocator),
        });
    }

    // 2패스: content hash 계산 및 placeholder 치환.
    // 각 청크의 content에서 placeholder를 찾아 content hash로 교체한다.
    // esbuild도 동일한 2패스 접근을 사용 (placeholder → content hash).
    try resolveContentHashes(allocator, outputs.items, sorted_indices, chunk_graph);

    return outputs.toOwnedSlice(allocator);
}

/// 동적 import 경로를 청크 파일명으로 리라이트한다.
///
/// code splitting 시 `import('./page')` → `import('./page.js')` 변환.
/// 모듈의 import_records에서 dynamic_import 레코드를 찾아,
/// resolve된 대상 모듈이 속한 청크의 파일명으로 specifier를 교체한다.
///
/// 반환값은 항상 allocator 소유 — 리라이트 여부와 무관하게 caller가 free해야 한다.
fn rewriteDynamicImports(
    allocator: std.mem.Allocator,
    code: []const u8,
    module: *const Module,
    chunk_graph: *const ChunkGraph,
    public_path: []const u8,
    out_ext: []const u8,
    emit_options: EmitOptions,
) ![]const u8 {
    // dynamic import가 없으면 그대로 복사해서 반환
    if (module.import_records.len == 0) {
        return try allocator.dupe(u8, code);
    }

    // 리라이트할 레코드가 있는지 먼저 확인 (불필요한 할당 방지)
    var has_dynamic = false;
    for (module.import_records) |rec| {
        if (rec.kind == .dynamic_import and rec.resolved != .none) {
            const target_chunk = chunk_graph.getModuleChunk(rec.resolved);
            if (target_chunk != .none) {
                has_dynamic = true;
                break;
            }
        }
    }
    if (!has_dynamic) {
        return try allocator.dupe(u8, code);
    }

    // 리라이트 수행: 각 dynamic import specifier를 청크 파일명으로 교체.
    // import_records를 순회하면서 코드 내의 specifier 문자열을 찾아 교체한다.
    // codegen이 specifier를 원본 그대로 출력하므로 정확한 문자열 매칭이 가능.
    var result = try allocator.dupe(u8, code);
    errdefer allocator.free(result);

    for (module.import_records) |rec| {
        if (rec.kind != .dynamic_import) continue;
        if (rec.resolved == .none) continue;

        const target_chunk_idx = chunk_graph.getModuleChunk(rec.resolved);
        if (target_chunk_idx == .none) continue;

        const target_chunk = chunk_graph.getChunk(target_chunk_idx);

        // 청크 파일명 생성: public_path가 있으면 "{public_path}{stem}{ext}", 없으면 "./{stem}{ext}"
        var stem_buf: [128]u8 = undefined;
        const stem = chunkPlaceholderStem(target_chunk, &stem_buf, emit_options);
        const replacement = if (public_path.len > 0)
            try std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ public_path, stem, out_ext })
        else
            try std.fmt.allocPrint(allocator, "./{s}{s}", .{ stem, out_ext });
        defer allocator.free(replacement);

        // 코드에서 원본 specifier를 찾아 교체
        if (std.mem.indexOf(u8, result, rec.specifier)) |pos| {
            const new_result = try std.mem.concat(allocator, u8, &.{
                result[0..pos],
                replacement,
                result[pos + rec.specifier.len ..],
            });
            allocator.free(result);
            result = new_result;
        }
    }

    return result;
}

const PlaceholderInfo = struct {
    placeholder: [HASH_PLACEHOLDER_PREFIX.len + HASH_PLACEHOLDER_LEN]u8,
    real_hash: [HASH_PLACEHOLDER_LEN]u8,
};

/// content hash 계산 + placeholder 치환 (2패스).
/// 모든 청크의 출력이 완성된 후 호출.
/// 각 청크의 placeholder hash를 content hash로 교체한다.
fn resolveContentHashes(
    allocator: std.mem.Allocator,
    outputs: []OutputFile,
    sorted_indices: []const usize,
    chunk_graph: *const ChunkGraph,
) !void {
    if (outputs.len == 0) return;

    // 1단계: 각 청크의 placeholder hash와 content hash를 계산
    var infos = try allocator.alloc(PlaceholderInfo, outputs.len);
    defer allocator.free(infos);

    for (sorted_indices, 0..) |ci, out_idx| {
        if (out_idx >= outputs.len) break;
        const chunk = &chunk_graph.chunks.items[ci];

        buildPlaceholder(chunk, &infos[out_idx].placeholder);

        // content hash 계산
        contentHash(outputs[out_idx].contents, &infos[out_idx].real_hash);
    }

    // 2단계: 모든 출력에서 모든 placeholder를 content hash로 단일패스 치환.
    // O(N*M) → O(M) (M=content 길이, N=청크 수).
    const ph_total = HASH_PLACEHOLDER_PREFIX.len + HASH_PLACEHOLDER_LEN;
    for (outputs) |*out| {
        // contents: 모든 placeholder를 한 번의 스캔으로 치환
        const new_contents = try replaceAllPlaceholders(allocator, out.contents, infos, ph_total);
        allocator.free(out.contents);
        out.contents = new_contents;

        // path도 동일하게 치환
        const new_path = try replaceAllPlaceholders(allocator, out.path, infos, ph_total);
        allocator.free(out.path);
        out.path = new_path;
    }
}

/// placeholder 해시 길이 (8자리 hex).
const HASH_PLACEHOLDER_LEN = 8;
/// placeholder 구분 문자열. 최종 출력에서 content hash로 치환된다.
/// 다른 코드에서 절대 등장하지 않을 문자열을 사용.
const HASH_PLACEHOLDER_PREFIX = "\x00ZH";

/// 청크의 인덱스 해시로 placeholder 바이트를 생성한다.
/// chunkPlaceholderStem과 resolveContentHashes에서 공용.
fn buildPlaceholder(chunk: *const Chunk, ph: *[HASH_PLACEHOLDER_PREFIX.len + HASH_PLACEHOLDER_LEN]u8) void {
    @memcpy(ph[0..HASH_PLACEHOLDER_PREFIX.len], HASH_PLACEHOLDER_PREFIX);
    const idx_hash = chunkIndexHash(chunk);
    _ = std.fmt.bufPrint(ph[HASH_PLACEHOLDER_PREFIX.len..], "{x:0>8}", .{@as(u32, @truncate(idx_hash))}) catch unreachable;
}

/// 청크의 placeholder stem을 반환한다 (확장자 없음).
/// cross-chunk import 등 content가 아직 없는 시점에서 사용.
/// 최종 출력 시 placeholder를 content hash로 치환한다.
fn chunkPlaceholderStem(chunk: *const Chunk, buf: []u8, options: EmitOptions) []const u8 {
    const is_entry = chunk.name != null;
    const base_name = chunk.name orelse "chunk";
    const pattern = if (is_entry) options.entry_names else options.chunk_names;

    var hash_buf: [HASH_PLACEHOLDER_PREFIX.len + HASH_PLACEHOLDER_LEN]u8 = undefined;
    buildPlaceholder(chunk, &hash_buf);

    return applyNamingPattern(buf, pattern, base_name, &hash_buf);
}

/// 모듈 인덱스 기반 해시 (placeholder 식별자용, content hash 아님).
fn chunkIndexHash(chunk: *const Chunk) u64 {
    var hasher = std.hash.Wyhash.init(0);
    var sort_buf: [256]u32 = undefined;
    const mod_count = @min(chunk.modules.items.len, 256);
    for (chunk.modules.items[0..mod_count], sort_buf[0..mod_count]) |mod_idx, *sb| {
        sb.* = @intFromEnum(mod_idx);
    }
    std.mem.sort(u32, sort_buf[0..mod_count], {}, std.sort.asc(u32));
    for (sort_buf[0..mod_count]) |idx| {
        hasher.update(std.mem.asBytes(&idx));
    }
    return hasher.final();
}

/// content hash 계산: 청크의 최종 출력 코드를 Wyhash하여 8자리 hex 반환.
/// placeholder 바이트를 건너뛰어 자기 참조 순환을 방지한다.
pub fn contentHash(content: []const u8, buf: *[HASH_PLACEHOLDER_LEN]u8) void {
    const ph_total = HASH_PLACEHOLDER_PREFIX.len + HASH_PLACEHOLDER_LEN;
    var hasher = std.hash.Wyhash.init(0);
    var i: usize = 0;
    var run_start: usize = 0; // 현재 non-placeholder 구간의 시작
    while (i < content.len) {
        if (i + ph_total <= content.len and
            std.mem.eql(u8, content[i..][0..HASH_PLACEHOLDER_PREFIX.len], HASH_PLACEHOLDER_PREFIX))
        {
            // placeholder 앞까지의 구간을 벌크 해싱
            if (i > run_start) hasher.update(content[run_start..i]);
            i += ph_total;
            run_start = i;
        } else {
            i += 1;
        }
    }
    // 마지막 구간 벌크 해싱
    if (i > run_start) hasher.update(content[run_start..i]);
    const h = hasher.final();
    _ = std.fmt.bufPrint(buf, "{x:0>8}", .{@as(u32, @truncate(h))}) catch unreachable;
}

/// 모든 placeholder를 단일패스로 치환한다.
/// input을 1회 스캔하면서 "\x00ZH" prefix를 만나면 infos에서 매칭하여 real_hash로 치환.
fn replaceAllPlaceholders(allocator: std.mem.Allocator, input: []const u8, infos: []const PlaceholderInfo, ph_total: usize) ![]const u8 {
    // placeholder가 있는지 빠르게 확인 (없으면 복사만)
    if (std.mem.indexOf(u8, input, HASH_PLACEHOLDER_PREFIX) == null) {
        return try allocator.dupe(u8, input);
    }

    // 최대 크기: 원본과 동일 (placeholder가 real_hash보다 길어서 줄어듦)
    var result: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    var run_start: usize = 0;
    while (i + ph_total <= input.len) {
        if (std.mem.eql(u8, input[i..][0..HASH_PLACEHOLDER_PREFIX.len], HASH_PLACEHOLDER_PREFIX)) {
            // run_start..i 까지의 일반 텍스트 복사
            try result.appendSlice(allocator, input[run_start..i]);
            // infos에서 매칭하는 placeholder 찾기
            const ph_bytes = input[i..][0..ph_total];
            var found = false;
            for (infos) |info| {
                if (std.mem.eql(u8, ph_bytes, &info.placeholder)) {
                    try result.appendSlice(allocator, &info.real_hash);
                    found = true;
                    break;
                }
            }
            if (!found) {
                // 매칭 안 되면 원본 유지
                try result.appendSlice(allocator, ph_bytes);
            }
            i += ph_total;
            run_start = i;
        } else {
            i += 1;
        }
    }
    // 나머지 복사
    try result.appendSlice(allocator, input[run_start..]);
    return result.toOwnedSlice(allocator);
}

/// 단일 placeholder를 실제 content hash로 치환한다.
/// 반환값은 allocator 소유.
fn replacePlaceholders(allocator: std.mem.Allocator, input: []const u8, placeholder_hash: []const u8, real_hash: []const u8) ![]const u8 {
    // placeholder_hash는 "\x00ZH" + 8hex, real_hash는 8hex
    // 치환 대상: placeholder_hash 전체 → real_hash
    const ph_len = HASH_PLACEHOLDER_PREFIX.len + HASH_PLACEHOLDER_LEN;
    if (placeholder_hash.len != ph_len) return try allocator.dupe(u8, input);

    // 치환 횟수 카운트
    var count: usize = 0;
    var pos: usize = 0;
    while (pos + ph_len <= input.len) {
        if (std.mem.eql(u8, input[pos..][0..ph_len], placeholder_hash)) {
            count += 1;
            pos += ph_len;
        } else {
            pos += 1;
        }
    }
    if (count == 0) return try allocator.dupe(u8, input);

    // 새 버퍼 할당 + 치환
    const new_len = input.len - count * ph_len + count * real_hash.len;
    const result = try allocator.alloc(u8, new_len);
    var src: usize = 0;
    var dst: usize = 0;
    while (src < input.len) {
        if (src + ph_len <= input.len and
            std.mem.eql(u8, input[src..][0..ph_len], placeholder_hash))
        {
            @memcpy(result[dst..][0..real_hash.len], real_hash);
            dst += real_hash.len;
            src += ph_len;
        } else {
            result[dst] = input[src];
            dst += 1;
            src += 1;
        }
    }
    return result;
}

/// naming pattern을 적용한다.
/// [name] → base_name, [hash] → hash_str 로 치환.
/// buf에 결과를 쓰고 슬라이스를 반환.
pub fn applyNamingPattern(buf: []u8, pattern: []const u8, name: []const u8, hash_str: []const u8) []const u8 {
    var dst: usize = 0;
    var i: usize = 0;
    while (i < pattern.len) {
        if (i + "[name]".len <= pattern.len and std.mem.eql(u8, pattern[i..][0.."[name]".len], "[name]")) {
            const end = @min(dst + name.len, buf.len);
            @memcpy(buf[dst..end], name[0 .. end - dst]);
            dst = end;
            i += "[name]".len;
        } else if (i + "[hash]".len <= pattern.len and std.mem.eql(u8, pattern[i..][0.."[hash]".len], "[hash]")) {
            const end = @min(dst + hash_str.len, buf.len);
            @memcpy(buf[dst..end], hash_str[0 .. end - dst]);
            dst = end;
            i += "[hash]".len;
        } else {
            if (dst < buf.len) {
                buf[dst] = pattern[i];
                dst += 1;
            }
            i += 1;
        }
    }
    return buf[0..dst];
}

/// used_names 사전 계산 결과.
const UsedNamesEntry = struct {
    names: []const []const u8,
    all_used: bool, // true이면 emitModule에 null 전달 (모든 export 사용)
};

/// 모든 모듈의 used_names를 사전 계산한다 (순차).
/// tree-shaking의 used export names 로직을 emit 루프에서 분리.
fn computeAllUsedNames(
    allocator: std.mem.Allocator,
    sorted: []*const Module,
    graph: *const ModuleGraph,
    shaker: ?*const TreeShaker,
) ![]UsedNamesEntry {
    var list = try allocator.alloc(UsedNamesEntry, sorted.len);
    for (list) |*e| e.* = .{ .names = &.{}, .all_used = true };

    const s = shaker orelse return list;

    for (sorted, 0..) |m, idx| {
        const mod_idx: u32 = @intFromEnum(m.index);
        // "*" 마킹이 있고 BFS reachable_stmts가 없으면 모든 export 사용
        if (s.isExportUsed(mod_idx, "*") and s.getModuleStmtInfos(mod_idx) == null) {
            list[idx] = .{ .names = &.{}, .all_used = true };
            continue;
        }

        var names_buf: std.ArrayListUnmanaged([]const u8) = .empty;
        var all_used = false;

        for (m.export_bindings) |eb| {
            if (eb.kind == .re_export_all) continue;
            if (!s.isExportUsed(mod_idx, eb.exported_name)) continue;

            // 크로스-모듈 BFS 도달성
            if (s.getModuleStmtInfos(mod_idx)) |ts_infos| {
                if (m.semantic) |sem| {
                    if (sem.scope_maps.len > 0) {
                        if (sem.scope_maps[0].get(eb.local_name)) |sym_idx| {
                            if (ts_infos.declaredStmtBySymbol(@intCast(sym_idx))) |stmt_idx| {
                                if (!s.isStmtReachable(mod_idx, stmt_idx)) continue;
                            }
                        }
                    }
                }
            }

            // StmtInfo 도달성: 모든 importer에서 이 export의 import가 dead이면 제외
            if (eb.kind == .local and m.importers.items.len > 0) {
                const is_dead = is_dead: {
                    var found_any = false;
                    for (m.importers.items) |importer_idx| {
                        const imp_i = @intFromEnum(importer_idx);
                        if (imp_i >= graph.modules.items.len) break :is_dead false;
                        const importer = &graph.modules.items[imp_i];
                        for (importer.export_bindings) |ieb| {
                            if (ieb.kind == .re_export_all or ieb.kind == .re_export) {
                                if (ieb.import_record_index) |rec_idx| {
                                    if (rec_idx < importer.import_records.len and
                                        importer.import_records[rec_idx].resolved == m.index)
                                    {
                                        if (ieb.kind == .re_export) {
                                            if (std.mem.eql(u8, ieb.local_name, eb.exported_name))
                                                break :is_dead false;
                                        } else {
                                            break :is_dead false;
                                        }
                                    }
                                }
                            }
                        }
                        for (importer.import_bindings) |ib| {
                            if (ib.import_record_index >= importer.import_records.len) continue;
                            if (importer.import_records[ib.import_record_index].resolved != m.index) continue;
                            if (!std.mem.eql(u8, ib.imported_name, eb.exported_name)) continue;
                            found_any = true;
                            if (s.isImportLiveInModule(@intCast(imp_i), ib.local_name))
                                break :is_dead false;
                        }
                    }
                    break :is_dead found_any;
                };
                if (is_dead) continue;
            }

            names_buf.append(allocator, eb.local_name) catch {
                all_used = true;
                break;
            };
            if (!std.mem.eql(u8, eb.exported_name, eb.local_name)) {
                names_buf.append(allocator, eb.exported_name) catch {
                    all_used = true;
                    break;
                };
            }
        }

        if (!all_used) {
            // cross-module: importer의 named binding도 포함
            for (m.importers.items) |importer_idx| {
                const imp_i = @intFromEnum(importer_idx);
                if (imp_i >= graph.modules.items.len) continue;
                const importer = &graph.modules.items[imp_i];
                for (importer.export_bindings) |eb| {
                    if (eb.kind == .re_export_all and !std.mem.eql(u8, eb.exported_name, "*")) {
                        if (eb.import_record_index) |rec_idx| {
                            if (rec_idx < importer.import_records.len and
                                importer.import_records[rec_idx].resolved == m.index)
                            {
                                all_used = true;
                                break;
                            }
                        }
                    }
                }
                if (all_used) break;
                for (importer.import_bindings) |ib| {
                    if (ib.kind != .named) continue;
                    if (ib.import_record_index >= importer.import_records.len) continue;
                    if (importer.import_records[ib.import_record_index].resolved != m.index) continue;
                    if (!s.isImportLiveInModule(@intCast(imp_i), ib.local_name)) continue;
                    names_buf.append(allocator, ib.imported_name) catch {
                        all_used = true;
                        break;
                    };
                }
                if (all_used) break;
            }
        }

        if (all_used) {
            names_buf.deinit(allocator);
            list[idx] = .{ .names = &.{}, .all_used = true };
        } else {
            list[idx] = .{
                .names = names_buf.toOwnedSlice(allocator) catch blk: {
                    // OOM: 내부 버퍼 해제 후 all_used 처리 (불완전한 이름 목록 방지)
                    names_buf.deinit(allocator);
                    break :blk &.{};
                },
                .all_used = false,
            };
        }
    }

    return list;
}

/// 스레드 풀에서 실행되는 emitModule 래퍼.
const ModuleEmitResult = struct {
    code: ?[]const u8 = null,
    helpers: RuntimeHelpers = .{},
    mappings: ?[]const SourceMap.Mapping = null,
};

/// JS 예약어이거나 유효한 식별자가 아니면 프로퍼티 키에 따옴표가 필요.
fn needsPropertyQuote(name: []const u8) bool {
    if (name.len == 0) return true;
    // JS 예약어 중 export 이름으로 자주 등장하는 것만 체크
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
    // 첫 문자가 숫자이거나 특수문자이면 따옴표 필요
    if (name[0] >= '0' and name[0] <= '9') return true;
    if (name[0] != '_' and name[0] != '$' and !(name[0] >= 'a' and name[0] <= 'z') and !(name[0] >= 'A' and name[0] <= 'Z')) return true;
    return false;
}

/// 들여쓰기를 적용하여 텍스트를 ArrayList에 추가. 줄바꿈 뒤에 탭을 삽입.
fn appendIndented(wrapped: *std.ArrayList(u8), allocator: std.mem.Allocator, text: []const u8) !void {
    for (text) |c| {
        try wrapped.append(allocator, c);
        if (c == '\n') try wrapped.append(allocator, '\t');
    }
}

fn emitModuleThread(
    allocator: std.mem.Allocator,
    module: *const Module,
    options: EmitOptions,
    linker: ?*const Linker,
    is_entry: bool,
    used_names: ?[]const []const u8,
    shaker: ?*const TreeShaker,
    result: *ModuleEmitResult,
) void {
    result.code = emitModule(allocator, module, options, linker, is_entry, used_names, shaker, &result.helpers, &result.mappings) catch null;
}

/// 단일 모듈을 Transformer → Codegen 파이프라인으로 처리.
/// 모듈별 arena에 AST가 보존되어 있으므로 재파싱 불필요.
/// emitChunks에서도 사용하므로 pub으로 노출.
pub fn emitModule(
    allocator: std.mem.Allocator,
    module: *const Module,
    options: EmitOptions,
    linker: ?*const Linker,
    is_entry: bool,
    used_export_names: ?[]const []const u8,
    shaker: ?*const TreeShaker,
    helpers_out: ?*RuntimeHelpers,
    mappings_out: ?*?[]const SourceMap.Mapping,
) !?[]const u8 {
    // Disabled 모듈 (platform=browser에서 Node 빌트인): 빈 __commonJS wrapper 출력.
    // esbuild 호환: var require_X = __commonJS({ "(disabled)"(exports, module) {} });
    if (module.is_disabled) {
        return emitDisabledModule(allocator, module, options.minify_whitespace);
    }

    // Asset 모듈: JSON 모듈과 동일한 패턴으로 출력.
    // source에 값 표현식이 저장되어 있고, var asset_X = <source>; 형태로 출력.
    if (module.loader.isAsset() and module.source.len > 0) {
        if (module.loader == .binary) {
            if (helpers_out) |h| h.to_binary = true;
        }
        return emitAssetModule(allocator, module, options);
    }

    const ast = &(module.ast orelse return null);

    // 변환용 arena (Transformer/Codegen 내부 메모리)
    var emit_arena = std.heap.ArenaAllocator.init(allocator);
    defer emit_arena.deinit();
    const arena_alloc = emit_arena.allocator();

    // Transformer: TS 타입 스트리핑, define 치환, decorator 변환 등
    var transformer = Transformer.init(arena_alloc, ast, .{
        .define = options.define,
        .experimental_decorators = options.experimental_decorators,
        .use_define_for_class_fields = options.use_define_for_class_fields,
        .unsupported = options.unsupported,
    });
    // symbol_ids 전파: semantic analyzer가 생성한 원본 AST의 symbol_ids를
    // transformer가 new_ast 기준으로 재매핑
    if (module.semantic) |sem| {
        transformer.old_symbol_ids = sem.symbol_ids;
    }
    const root = try transformer.transform();

    // AST 미니파이어: --minify 시 constant folding 등 AST 레벨 최적화
    if (options.minify_syntax) {
        @import("../transformer/minify.zig").minify(&transformer.new_ast);
    }

    // 런타임 헬퍼 사용 추적: transformer가 설정한 플래그를 out parameter로 전달
    // packed struct(u16)이므로 bitwise OR로 한번에 합친다
    if (helpers_out) |h| {
        h.* = @bitCast(@as(u16, @bitCast(h.*)) | @as(u16, @bitCast(transformer.runtime_helpers)));
    }

    // Linker 메타데이터 생성 (있으면) — new_ast 기준으로 구축
    var metadata: ?LinkingMetadata = null;
    defer if (metadata) |*m| m.deinit();

    if (linker) |l| {
        // transformer가 생성한 new_symbol_ids (있으면 우선 사용)
        const override_syms: ?[]const ?u32 = if (transformer.new_symbol_ids.items.len > 0)
            transformer.new_symbol_ids.items
        else
            null;
        // new_ast 기준으로 skip_nodes 구축 (transformer 이후이므로 노드 인덱스가 new_ast와 일치)
        var md = try l.buildMetadataForAst(
            &transformer.new_ast,
            @intFromEnum(module.index),
            is_entry,
            override_syms,
        );
        // transformer가 전파한 new_symbol_ids를 메타데이터에 설정
        if (override_syms) |syms| {
            md.symbol_ids = syms;
        }
        // statement-level tree-shaking: StmtInfo 기반 도달성 분석으로 미사용 statement 제거.
        // rolldown 방식: 심볼 인덱스로 추적하여 linker rename 후에도 정확한 판정.
        if (used_export_names) |names| {
            if (!is_entry and !module.wrap_kind.isWrapped()) {
                stmt_shake: {
                    const sem = module.semantic orelse {
                        statement_shaker.markUnusedStatements(
                            arena_alloc,
                            &transformer.new_ast,
                            root,
                            names,
                            &md.skip_nodes,
                        ) catch {};
                        break :stmt_shake;
                    };
                    const sym_ids: []const ?u32 = if (transformer.new_symbol_ids.items.len > 0)
                        transformer.new_symbol_ids.items
                    else
                        sem.symbol_ids;

                    // 크로스-모듈 BFS 결과: tree-shaker의 reachable_stmts로 skip_nodes 설정
                    const mod_idx: u32 = @intFromEnum(module.index);
                    if (shaker) |s| {
                        if (s.getModuleStmtInfos(mod_idx)) |ts_infos| {
                            // 변환 후 AST의 program statement list에서 span 매칭
                            const new_root = transformer.new_ast.nodes.items[transformer.new_ast.nodes.items.len - 1];
                            if (new_root.tag == .program and new_root.data.list.len > 0) {
                                const new_list = new_root.data.list;
                                if (new_list.start + new_list.len <= transformer.new_ast.extra_data.items.len) {
                                    const new_stmt_indices = transformer.new_ast.extra_data.items[new_list.start .. new_list.start + new_list.len];
                                    for (ts_infos.stmts, 0..) |ts_stmt, si| {
                                        if (s.isStmtReachable(mod_idx, @intCast(si))) continue;
                                        // 변환 후 top-level statement만 스캔 (O(stmts) not O(nodes))
                                        for (new_stmt_indices) |raw_ni| {
                                            const ni = @as(usize, raw_ni);
                                            if (ni >= transformer.new_ast.nodes.items.len) continue;
                                            const new_node = transformer.new_ast.nodes.items[ni];
                                            if (new_node.span.start == ts_stmt.span.start and
                                                new_node.span.end == ts_stmt.span.end and
                                                ni < md.skip_nodes.capacity())
                                            {
                                                md.skip_nodes.set(ni);
                                                break;
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    } else {
                        // tree-shaker 없으면 기존 방식 (모듈 내부 computeReachable)
                        if (stmt_info_mod.build(arena_alloc, &transformer.new_ast, sem.symbols, sym_ids)) |maybe_infos| {
                            if (maybe_infos) |infos| {
                                var used_sym_buf: std.ArrayListUnmanaged(u32) = .empty;
                                defer used_sym_buf.deinit(arena_alloc);
                                if (sem.scope_maps.len > 0) {
                                    for (names) |name| {
                                        if (sem.scope_maps[0].get(name)) |sym_idx| {
                                            used_sym_buf.append(arena_alloc, @intCast(sym_idx)) catch continue;
                                        } else {
                                            for (module.export_bindings) |eb| {
                                                if (std.mem.eql(u8, eb.exported_name, name)) {
                                                    if (sem.scope_maps[0].get(eb.local_name)) |sym_idx| {
                                                        used_sym_buf.append(arena_alloc, @intCast(sym_idx)) catch {};
                                                    }
                                                    break;
                                                }
                                            }
                                        }
                                    }
                                }
                                if (infos.computeReachable(arena_alloc, used_sym_buf.items)) |reachable| {
                                    for (infos.stmts, 0..) |stmt, si| {
                                        if (!reachable.isSet(si) and stmt.node_idx < md.skip_nodes.capacity()) {
                                            md.skip_nodes.set(stmt.node_idx);
                                        }
                                    }
                                } else |_| {}
                            }
                        } else |_| {}
                    }
                }
            }
        }

        metadata = md;
    }

    // Cross-module @__NO_SIDE_EFFECTS__ 전파:
    // import한 함수가 원본 모듈에서 no_side_effects로 선언되었으면
    // 현재 모듈의 해당 호출에 is_pure 플래그를 자동 설정한다.
    if (linker) |l| {
        const sym_ids = if (metadata) |md| md.symbol_ids else &.{};
        propagateCrossModulePurity(l, module, &transformer.new_ast, sym_ids, arena_alloc);
    }

    // Identifier mangling은 단일 파일 트랜스파일(main.zig)에서만 적용.
    // 번들 모드에서는 linker의 scope hoisting과 이름 충돌 해결이 먼저 필요하므로
    // 별도 통합이 필요 (후속 PR).

    // __esm 모듈: AST 수준 var/function 호이스팅 (esbuild/rolldown 방식)
    if (module.wrap_kind == .esm) {
        return try emitEsmWrappedModule(
            allocator,
            arena_alloc,
            &transformer.new_ast,
            root,
            module,
            if (metadata) |*m| @as(?*const LinkingMetadata, m) else null,
            linker,
            options,
        );
    }

    // Codegen: AST → JS 문자열
    var cg = Codegen.initWithOptions(arena_alloc, &transformer.new_ast, .{
        .minify_whitespace = options.minify_whitespace,
        // scope-hoisted 모듈은 항상 ESM codegen 사용 (bare declarations).
        // __commonJS 래핑 모듈만 CJS codegen (module.exports = ...).
        // 래핑 모듈(CJS/ESM)은 CJS codegen: import→require 변환
        .module_format = if (module.wrap_kind.isWrapped()) .cjs else .esm,
        // __esm 모듈: exports.x/module.exports 생성 억제 (__export()가 대신 처리)
        .skip_cjs_exports = module.wrap_kind == .esm,
        // __esm 모듈: const → var (TDZ 방지)
        .use_var_for_imports = module.wrap_kind == .esm,
        .linking_metadata = if (metadata) |*m| m else null,
        // 번들 모드에서 ESM이 아니면 import.meta → {} 치환 (esbuild 호환)
        // Node.js는 import.meta를 보면 ESM으로 재파싱하려 해서 에러 발생
        .replace_import_meta = options.format != .esm,
        .platform = options.platform,
        // --charset=utf8 → ascii_only=false (명시적 보장)
        .ascii_only = false,
        // 소스맵 옵션 전달
        .sourcemap = options.sourcemap,
        .source_root = options.source_root orelse "",
        .sources_content = options.sources_content,
        // keepNames: codegen이 rename된 함수/클래스를 수집
        .keep_names = options.keep_names,
        // JSX 런타임 설정
        .jsx_runtime = options.jsx_runtime,
        .jsx_factory = options.jsx_factory,
        .jsx_fragment = options.jsx_fragment,
        .jsx_import_source = options.jsx_import_source,
        .jsx_filename = module.path,
    });
    // 소스맵용: line_offsets와 소스 파일 등록
    if (options.sourcemap) {
        cg.line_offsets = module.line_offsets;
        try cg.addSourceFile(makeModuleId(module.path, options.root_dir));
    }
    var code = try cg.generate(root);

    // 소스맵 매핑 복사 (arena 해제 전에)
    if (mappings_out) |mout| {
        if (cg.sm_builder) |*sm| {
            if (sm.mappings.items.len > 0) {
                mout.* = try allocator.dupe(SourceMap.Mapping, sm.mappings.items);
            }
        }
    }

    // Plugin: transform 훅 — codegen 직후, CJS 래핑 전
    // 플러그인 결과를 arena로 복사하여 emit_arena와 같은 생명주기 보장
    if (options.plugins.len > 0) {
        const runner = plugin_mod.PluginRunner.init(options.plugins);
        const transform_result = runner.runTransform(code, module.path, allocator) catch |err| switch (err) {
            error.PluginFailed => null,
            error.OutOfMemory => return error.OutOfMemory,
        };
        if (transform_result) |result| {
            code = try arena_alloc.dupe(u8, result);
            allocator.free(result);
        }
    }

    // keepNames: codegen이 generate() 내에서 직접 __name() 호출을 buf에 append.
    // entries가 있으면 런타임 헬퍼 플래그만 설정.
    if (cg.keep_names_entries.items.len > 0) {
        if (helpers_out) |h| h.keep_names = true;
    }

    // CJS 래핑: __commonJS 팩토리 함수로 감싸기
    if (module.wrap_kind == .cjs) {
        const basename = std.fs.path.basename(module.path);
        const preamble_code = if (metadata) |md| md.cjs_import_preamble else null;

        const var_name = try types.makeRequireVarName(allocator, module.path);
        defer allocator.free(var_name);

        var wrapped: std.ArrayList(u8) = .empty;
        defer wrapped.deinit(allocator);

        if (options.minify_whitespace) {
            try wrapped.appendSlice(allocator, "var ");
            try wrapped.appendSlice(allocator, var_name);
            try wrapped.appendSlice(allocator, "=__commonJS({\"");
            try wrapped.appendSlice(allocator, basename);
            try wrapped.appendSlice(allocator, "\"(exports,module){");
            if (preamble_code) |p| try wrapped.appendSlice(allocator, p);
            try wrapped.appendSlice(allocator, code);
            try wrapped.appendSlice(allocator, "}});");
        } else {
            try wrapped.appendSlice(allocator, "var ");
            try wrapped.appendSlice(allocator, var_name);
            try wrapped.appendSlice(allocator, " = __commonJS({\n\t\"");
            try wrapped.appendSlice(allocator, basename);
            try wrapped.appendSlice(allocator, "\"(exports, module) {\n");
            if (preamble_code) |p| try appendIndented(&wrapped, allocator, p);
            try appendIndented(&wrapped, allocator, code);
            try wrapped.appendSlice(allocator, "\n\t}\n});\n");
        }

        return try allocator.dupe(u8, wrapped.items);
    }

    // __esm 래핑은 emitEsmWrappedModule()에서 처리 (early return)

    // CJS import preamble + final_exports를 하나의 concat으로 합침 (중간 할당 누수 방지)
    const preamble = if (metadata) |md| md.cjs_import_preamble else null;
    const raw_final_exports = if (metadata) |md| md.final_exports else null;

    // IIFE + globalName: "export { x }" → "return { x }" 변환.
    // IIFE (globalName 없음): export 구문은 IIFE 안에서 syntax error → 제거.
    // CJS: export 구문은 CJS 래핑과 무관 → 제거.
    // linker는 format-agnostic하게 "export {}" 를 생성하므로, emitter에서 포맷별 치환/제거.
    var iife_return_buf: ?[]const u8 = null;
    defer if (iife_return_buf) |buf| allocator.free(buf);

    const final_exports = if (raw_final_exports) |fe| blk: {
        if (options.format == .iife) {
            if (options.global_name != null) {
                if (std.mem.startsWith(u8, fe, "export {")) {
                    iife_return_buf = try std.mem.concat(allocator, u8, &.{ "return {", fe["export {".len..] });
                    break :blk iife_return_buf.?;
                }
            }
            // IIFE (globalName 없음): export는 syntax error이므로 제거
            break :blk @as(?[]const u8, null);
        }
        if (options.format == .cjs) {
            // CJS: export 구문은 불필요 (CJS 래핑이 exports 처리)
            break :blk @as(?[]const u8, null);
        }
        break :blk fe;
    } else null;

    if (preamble != null or final_exports != null) {
        return try std.mem.concat(allocator, u8, &.{
            preamble orelse "",
            code,
            final_exports orelse "",
        });
    }

    // arena 해제 전에 복사 (caller 소유)
    return try allocator.dupe(u8, code);
}

/// JSON 모듈을 CJS 형태로 출력: __commonJS 래핑 + module.exports = <JSON content>
/// Disabled 모듈: platform=browser에서 Node 빌트인 모듈을 빈 __commonJS wrapper로 출력.
/// esbuild 호환 형식: var require_util = __commonJS({ "(disabled)"(exports, module) {} });
fn emitDisabledModule(allocator: std.mem.Allocator, module: *const Module, minify: bool) !?[]const u8 {
    const var_name = try types.makeRequireVarName(allocator, module.path);
    defer allocator.free(var_name);

    var buf: std.ArrayList(u8) = .empty;
    if (minify) {
        try buf.appendSlice(allocator, "var ");
        try buf.appendSlice(allocator, var_name);
        try buf.appendSlice(allocator, "=__commonJS({\"(disabled)\"(exports,module){}});");
    } else {
        try buf.appendSlice(allocator, "var ");
        try buf.appendSlice(allocator, var_name);
        try buf.appendSlice(allocator, " = __commonJS({\n\t\"(disabled)\"(exports, module) {\n\t}\n});\n");
    }
    return try buf.toOwnedSlice(allocator);
}

/// Asset 모듈을 출력한다 (CJS wrap 패턴).
/// source에 값 표현식이 저장되어 있고, __commonJS wrapper로 래핑.
/// linker가 `require_X()` 호출을 생성하므로, 모든 포맷에서 CJS 패턴을 사용.
fn emitAssetModule(allocator: std.mem.Allocator, module: *const Module, options: EmitOptions) !?[]const u8 {
    if (module.source.len == 0) return null;
    return emitCjsWrapper(allocator, module.path, module.source, options.minify_whitespace);
}

/// __commonJS wrapper 출력 (Asset 모듈용).
/// var require_X = __commonJS({ "filename"(exports, module) { module.exports = <source>; } });
fn emitCjsWrapper(allocator: std.mem.Allocator, path: []const u8, source: []const u8, minify: bool) !?[]const u8 {
    const var_name = try types.makeRequireVarName(allocator, path);
    defer allocator.free(var_name);

    var buf: std.ArrayList(u8) = .empty;
    if (minify) {
        try buf.appendSlice(allocator, "var ");
        try buf.appendSlice(allocator, var_name);
        try buf.appendSlice(allocator, "=__commonJS({\"");
        try buf.appendSlice(allocator, std.fs.path.basename(path));
        try buf.appendSlice(allocator, "\"(exports,module){module.exports=");
        try buf.appendSlice(allocator, source);
        try buf.appendSlice(allocator, "}});");
    } else {
        try buf.appendSlice(allocator, "var ");
        try buf.appendSlice(allocator, var_name);
        try buf.appendSlice(allocator, " = __commonJS({\n\t\"");
        try buf.appendSlice(allocator, std.fs.path.basename(path));
        try buf.appendSlice(allocator, "\"(exports, module) {\nmodule.exports=");
        try buf.appendSlice(allocator, source);
        try buf.appendSlice(allocator, ";\n\t}\n});\n");
    }
    return try buf.toOwnedSlice(allocator);
}

/// Cross-module @__NO_SIDE_EFFECTS__ 전파.
///
/// 단일 모듈 내에서는 semantic analyzer가 callee symbol의 no_side_effects 플래그를 보고
/// call_expression에 is_pure를 자동 설정한다 (analyzer.zig:863-876).
/// 하지만 cross-module import의 경우, importing 모듈의 semantic analyzer는 원본 모듈의
/// symbol을 모르므로 is_pure가 설정되지 않는다.
///
/// 이 함수는 linker가 해석한 import→export 바인딩을 활용하여:
/// 1. import한 symbol이 원본 모듈에서 no_side_effects로 선언되었는지 확인
/// 2. 해당 symbol을 callee로 사용하는 call_expression에 is_pure 플래그 설정
fn propagateCrossModulePurity(
    linker: *const Linker,
    module: *const Module,
    new_ast: *Ast,
    symbol_ids: []const ?u32,
    allocator: std.mem.Allocator,
) void {
    const sem = module.semantic orelse return;
    if (sem.scope_maps.len == 0) return;
    if (module.import_bindings.len == 0) return;
    const module_scope = sem.scope_maps[0];
    const module_index: u32 = @intFromEnum(module.index);

    // 1단계: no_side_effects인 import binding의 local symbol_id를 수집한다.
    // 비트셋 대신 bool 배열 사용 — 스택 256개, 초과 시 arena fallback.
    var has_any_pure = false;
    const sym_count = sem.symbols.len;
    if (sym_count == 0) return;

    var pure_flags_buf: [256]bool = .{false} ** 256;
    const pure_flags: []bool = if (sym_count <= 256)
        pure_flags_buf[0..sym_count]
    else
        allocator.alloc(bool, sym_count) catch return;
    defer if (sym_count > 256) allocator.free(pure_flags);
    if (sym_count > 256) @memset(pure_flags, false);

    for (module.import_bindings) |ib| {
        if (ib.kind == .namespace) continue;

        const resolved = linker.getResolvedBinding(module_index, ib.local_span) orelse continue;

        const canon_mod_idx = @intFromEnum(resolved.canonical.module_index);
        if (canon_mod_idx >= linker.modules.len) continue;
        const target_module = linker.modules[canon_mod_idx];
        const target_sem = target_module.semantic orelse continue;

        if (target_sem.scope_maps.len == 0) continue;
        const target_scope = target_sem.scope_maps[0];

        // default export는 local_name이 다를 수 있음 ("default" → 실제 함수명)
        const target_sym_name = if (std.mem.eql(u8, resolved.canonical.export_name, "default"))
            linker.getExportLocalName(canon_mod_idx, "default") orelse resolved.canonical.export_name
        else
            resolved.canonical.export_name;

        const target_sym_idx = target_scope.get(target_sym_name) orelse continue;
        if (target_sym_idx >= target_sem.symbols.len) continue;
        if (!target_sem.symbols[target_sym_idx].decl_flags.no_side_effects) continue;

        const local_sym_idx = module_scope.get(ib.local_name) orelse continue;
        if (local_sym_idx >= sym_count) continue;

        pure_flags[local_sym_idx] = true;
        has_any_pure = true;
    }

    if (!has_any_pure) return;

    // 2단계: new_ast의 call/new expression 중 callee가 pure import이면 is_pure 설정
    const CallFlags = @import("../parser/ast.zig").CallFlags;

    for (new_ast.nodes.items) |node| {
        if (node.tag != .call_expression and node.tag != .new_expression) continue;

        const e = node.data.extra;
        if (!new_ast.hasExtra(e, 3)) continue;

        const callee_idx = new_ast.readExtraNode(e, 0);
        if (callee_idx.isNone()) continue;
        const callee_ni = @intFromEnum(callee_idx);

        if (callee_ni >= new_ast.nodes.items.len) continue;
        if (new_ast.nodes.items[callee_ni].tag != .identifier_reference) continue;

        if (callee_ni >= symbol_ids.len) continue;
        const sym_idx = symbol_ids[callee_ni] orelse continue;
        if (sym_idx >= sym_count) continue;

        if (pure_flags[sym_idx]) {
            new_ast.extra_data.items[e + 3] |= CallFlags.is_pure;
        }
    }
}

/// 런타임 헬퍼 문자열을 ArrayList에 주입한다 (re-export for backward compat).
pub const appendRuntimeHelpers = rt.appendRuntimeHelpers;

/// 번들 레벨 런타임 헬퍼 주입 (CJS interop + decorator + async).
/// emitWithTreeShaking에서 사용.
fn emitBundleRuntimeHelpers(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    sorted_modules: []const *const Module,
    options: EmitOptions,
) !void {
    // 런타임 헬퍼 주입: 래핑 모듈 유형에 따라 필요한 헬퍼 결정.
    var needs_cjs_runtime = false;
    var needs_esm_wrap_runtime = false;
    for (sorted_modules) |m| {
        if (m.wrap_kind == .cjs) needs_cjs_runtime = true;
        if (m.wrap_kind == .esm) needs_esm_wrap_runtime = true;
    }
    if (needs_cjs_runtime or needs_esm_wrap_runtime) {
        // __toESM, __copyProps, __defProp은 CJS/ESM 양쪽에서 공유
        try rt.appendCjsRuntime(output, allocator, options.minify_whitespace, options.configurable_exports);
    }
    if (needs_esm_wrap_runtime) {
        try rt.appendEsmWrapRuntime(output, allocator, options.minify_whitespace, options.configurable_exports);
    }
    if (options.experimental_decorators) {
        try rt.appendDecoratorRuntime(output, allocator, options.minify_whitespace);
    }
    if (options.unsupported.async_await) {
        try rt.appendAsyncRuntime(output, allocator, options.minify_whitespace);
    }
}

/// 청크별 런타임 헬퍼 주입.
/// emitChunks에서 사용.
fn emitChunkRuntimeHelpers(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    chunk: *const Chunk,
    modules: []const Module,
    options: EmitOptions,
) !void {
    var needs_cjs_runtime = false;
    var needs_esm_wrap_runtime = false;
    var needs_to_binary = false;
    for (chunk.modules.items) |mod_idx| {
        const mi = @intFromEnum(mod_idx);
        if (mi < modules.len) {
            if (modules[mi].wrap_kind == .cjs) needs_cjs_runtime = true;
            if (modules[mi].wrap_kind == .esm) needs_esm_wrap_runtime = true;
            if (modules[mi].loader == .binary) needs_to_binary = true;
        }
    }
    if (needs_cjs_runtime or needs_esm_wrap_runtime) {
        try rt.appendCjsRuntime(output, allocator, options.minify_whitespace, options.configurable_exports);
    }
    if (needs_esm_wrap_runtime) {
        try rt.appendEsmWrapRuntime(output, allocator, options.minify_whitespace, options.configurable_exports);
    }
    if (options.experimental_decorators) {
        try rt.appendDecoratorRuntime(output, allocator, options.minify_whitespace);
    }
    if (options.unsupported.async_await) {
        try rt.appendAsyncRuntime(output, allocator, options.minify_whitespace);
    }
    if (needs_to_binary) {
        try output.appendSlice(allocator, if (options.minify_whitespace) rt.TO_BINARY_RUNTIME_MIN else rt.TO_BINARY_RUNTIME);
    }
    if (options.keep_names) {
        try output.appendSlice(allocator, if (options.minify_whitespace) rt.KEEP_NAMES_RUNTIME_MIN else rt.KEEP_NAMES_RUNTIME);
    }
}

/// default → 실제 모드로 해석. default는 minify 시 eof, 아니면 inline.
fn resolveDefaultLegalComments(mode: types.LegalComments, minify: bool) types.LegalComments {
    if (mode != .default) return mode;
    return if (minify) .eof else .@"inline";
}

/// eof/linked/external 모드에서 legal comments를 수집하여 출력 끝에 추가.
/// 중복 제거: 같은 텍스트의 주석은 한 번만 출력.
fn collectLegalComments(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    sorted_modules: []const *const Module,
    mode: types.LegalComments,
) !void {
    _ = mode; // linked/external 분기는 향후 확장
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(allocator);
    var has_any = false;

    for (sorted_modules) |m| {
        for (m.legal_comments) |comment_text| {
            const gop = try seen.getOrPut(allocator, comment_text);
            if (gop.found_existing) continue;
            if (!has_any) {
                try output.appendSlice(allocator, "\n");
                has_any = true;
            }
            try output.appendSlice(allocator, comment_text);
            try output.append(allocator, '\n');
        }
    }
}

/// 노드 인덱스에 대해 rename이 적용된 최종 이름을 반환한다.
/// metadata의 symbol_ids → renames 조회. rename이 없으면 fallback 반환.
fn resolveNodeName(md: ?*const LinkingMetadata, node_idx: u32, fallback: []const u8) []const u8 {
    if (md) |m| {
        if (node_idx < m.symbol_ids.len) {
            if (m.symbol_ids[node_idx]) |sid| {
                if (m.renames.get(sid)) |renamed| return renamed;
            }
        }
    }
    return fallback;
}

/// import_declaration 노드에서 binding 이름을 수집한다 (호이스팅용).
fn collectImportBindingNames(
    esm_ast: *const Ast,
    stmt_node: anytype,
    md: ?*const LinkingMetadata,
    allocator: std.mem.Allocator,
    out: *std.ArrayList([]const u8),
) !void {
    const ie = stmt_node.data.extra;
    if (ie + 2 >= esm_ast.extra_data.items.len) return;
    const iextras = esm_ast.extra_data.items[ie .. ie + 3];
    const ispecs_start = iextras[0];
    const ispecs_len = iextras[1];
    if (ispecs_len == 0) return;
    const ispecs = esm_ast.extra_data.items[ispecs_start .. ispecs_start + ispecs_len];
    for (ispecs) |spec_raw| {
        const spec_node = esm_ast.nodes.items[spec_raw];
        switch (spec_node.tag) {
            .import_default_specifier, .import_namespace_specifier => {
                const name = esm_ast.getText(spec_node.data.string_ref);
                try out.append(allocator, resolveNodeName(md, spec_raw, name));
            },
            .import_specifier => {
                const local_idx = spec_node.data.binary.right;
                if (!local_idx.isNone()) {
                    const local_node = esm_ast.nodes.items[@intFromEnum(local_idx)];
                    const name = esm_ast.getText(local_node.data.string_ref);
                    try out.append(allocator, resolveNodeName(md, @intFromEnum(local_idx), name));
                }
            },
            else => {},
        }
    }
}

/// __esm 래핑 모듈의 코드를 생성한다 (rolldown 방식: function 호이스팅 + live binding).
///
/// 출력 구조:
///   var exports_xxx = {};
///   var hoisted_var1;                      ← var/class 이름 호이스팅
///   function hoisted_fn() { ... }          ← function 선언 호이스팅 (canonical 변수 직접 참조)
///   __export(exports_xxx, { ... });        ← lazy getter (래퍼 밖)
///   var init_xxx = __esm({ "file.js"() {
///     init_dep();                          ← 의존 모듈 init 호출 (preamble)
///     hoisted_var1 = init_value;           ← 할당문만 래퍼 안
///   } });
fn emitEsmWrappedModule(
    allocator: std.mem.Allocator,
    arena_alloc: std.mem.Allocator,
    esm_ast: *const Ast,
    root: NodeIndex,
    module: *const Module,
    metadata: ?*const LinkingMetadata,
    linker: ?*const Linker,
    options: anytype,
) ![]const u8 {
    const basename = std.fs.path.basename(module.path);

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
    if (hoisted_stmts.items.len > 0) {
        var hoist_cg = Codegen.initWithOptions(arena_alloc, esm_ast, .{
            .minify_whitespace = options.minify_whitespace,
            .module_format = .cjs,
            .skip_cjs_exports = true,
            .use_var_for_imports = true,
            .linking_metadata = cg_linking,
            .replace_import_meta = options.format != .esm,
            .platform = options.platform,
            .jsx_runtime = options.jsx_runtime,
            .jsx_factory = options.jsx_factory,
            .jsx_fragment = options.jsx_fragment,
            .jsx_import_source = options.jsx_import_source,
            .jsx_filename = module.path,
        });
        const hoisted_code = try hoist_cg.generateStatements(root, hoisted_stmts.items);
        try wrapped.appendSlice(allocator, hoisted_code);
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
                    });
                }
            }
            for (star_entries.items) |entry| {
                try appendExportGetter(&wrapped, allocator, entry.name, entry.getter_value);
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
        .jsx_runtime = options.jsx_runtime,
        .jsx_factory = options.jsx_factory,
        .jsx_fragment = options.jsx_fragment,
        .jsx_import_source = options.jsx_import_source,
        .jsx_filename = module.path,
    });
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
                        const iv = try types.makeInitVarName(allocator, source_mod.path);
                        defer allocator.free(iv);
                        const ev = try types.makeExportsVarName(allocator, source_mod.path);
                        defer allocator.free(ev);
                        try reexport_buf.appendSlice(allocator, "(");
                        try reexport_buf.appendSlice(allocator, iv);
                        try reexport_buf.appendSlice(allocator, "(), __toCommonJS(");
                        try reexport_buf.appendSlice(allocator, ev);
                        try reexport_buf.appendSlice(allocator, ")).default");
                    },
                    .cjs => {
                        const rv = try types.makeRequireVarName(allocator, source_mod.path);
                        defer allocator.free(rv);
                        try reexport_buf.appendSlice(allocator, rv);
                        try reexport_buf.appendSlice(allocator, "().default");
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
                    const iv = try types.makeInitVarName(allocator, src_mod.path);
                    defer allocator.free(iv);
                    try star_init_buf.appendSlice(allocator, iv);
                    try star_init_buf.appendSlice(allocator, "();\n");
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

    if (options.minify_whitespace) {
        try wrapped.appendSlice(allocator, "var ");
        try wrapped.appendSlice(allocator, init_name);
        try wrapped.appendSlice(allocator, "=__esm({\"");
        try wrapped.appendSlice(allocator, basename);
        try wrapped.appendSlice(allocator, "\"(){");
        if (preamble_code) |p| try wrapped.appendSlice(allocator, p);
        if (star_init_buf.items.len > 0) try wrapped.appendSlice(allocator, star_init_buf.items);
        try wrapped.appendSlice(allocator, body_code);
        if (reexport_buf.items.len > 0) try wrapped.appendSlice(allocator, reexport_buf.items);
        try wrapped.appendSlice(allocator, "}});");
    } else {
        try wrapped.appendSlice(allocator, "var ");
        try wrapped.appendSlice(allocator, init_name);
        try wrapped.appendSlice(allocator, " = __esm({\n\t\"");
        try wrapped.appendSlice(allocator, basename);
        try wrapped.appendSlice(allocator, "\"() {\n");
        if (preamble_code) |p| {
            try wrapped.append(allocator, '\t');
            try appendIndented(&wrapped, allocator, p);
        }
        if (star_init_buf.items.len > 0) {
            try wrapped.append(allocator, '\t');
            try appendIndented(&wrapped, allocator, star_init_buf.items);
        }
        if (body_code.len > 0) {
            try wrapped.append(allocator, '\t');
            try appendIndented(&wrapped, allocator, body_code);
        }
        if (reexport_buf.items.len > 0) {
            try wrapped.append(allocator, '\t');
            try appendIndented(&wrapped, allocator, reexport_buf.items);
        }
        try wrapped.appendSlice(allocator, "\n\t}\n});\n");
    }

    return try allocator.dupe(u8, wrapped.items);
}

/// __export() 내부의 "name: () => value,\n" 한 줄을 출력한다.
/// property 이름에 따옴표가 필요하면 자동으로 감싼다.
fn appendExportGetter(
    buf: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    name: []const u8,
    value: []const u8,
) !void {
    try buf.appendSlice(allocator, "\t");
    if (needsPropertyQuote(name)) {
        try buf.appendSlice(allocator, "\"");
        try buf.appendSlice(allocator, name);
        try buf.appendSlice(allocator, "\"");
    } else {
        try buf.appendSlice(allocator, name);
    }
    try buf.appendSlice(allocator, ": () => ");
    try buf.appendSlice(allocator, value);
    try buf.appendSlice(allocator, ",\n");
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
