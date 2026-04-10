//! 단일 소스 트랜스파일 — I/O 없는 순수 함수.
//!
//! 입력: 소스 문자열 + 파일 경로(확장자 감지용) + 옵션
//! 출력: 변환된 JS 코드 (allocator 소유, caller가 free)
//!
//! 용도:
//!   - main.zig의 CLI transpileFile에서 핵심 로직으로 사용
//!   - bundler에서 폴리필 Flow strip
//!   - 향후 NAPI 바인딩의 단일 파일 API

const std = @import("std");
const Scanner = @import("lexer/mod.zig").Scanner;
const Parser = @import("parser/parser.zig").Parser;
const SemanticAnalyzer = @import("semantic/mod.zig").SemanticAnalyzer;
const Transformer = @import("transformer/transformer.zig").Transformer;
const TransformOptions = @import("transformer/transformer.zig").TransformOptions;
const DefineEntry = @import("transformer/transformer.zig").DefineEntry;
const Codegen = @import("codegen/codegen.zig").Codegen;
const SourceMap = @import("codegen/sourcemap.zig");
const Mangler = @import("codegen/mod.zig").mangler;
const LinkingMetadata = @import("bundler/linker.zig").LinkingMetadata;
const rt = @import("bundler/runtime_helpers.zig");
const Diagnostic = @import("diagnostic.zig").Diagnostic;

pub const TranspileOptions = struct {
    // --- 파싱 ---
    flow: bool = false,
    jsx_in_js: bool = false,

    // --- 변환 ---
    define: []const DefineEntry = &.{},
    unsupported: TransformOptions.compat.UnsupportedFeatures = .{},
    use_define_for_class_fields: bool = true,
    experimental_decorators: bool = false,
    emit_decorator_metadata: bool = false,
    drop_console: bool = false,
    drop_debugger: bool = false,

    // --- 코드 생성 ---
    module_format: @import("codegen/codegen.zig").ModuleFormat = .esm,
    minify_whitespace: bool = false,
    minify_identifiers: bool = false,
    minify_syntax: bool = false,
    ascii_only: bool = false,
    charset_utf8: bool = false,
    quote_style: @import("codegen/codegen.zig").QuoteStyle = .double,
    sourcemap: bool = false,
    /// Sentry Debug ID (--sourcemap-debug-ids). 소스맵 + JS에 동일 UUID를 삽입.
    sourcemap_debug_ids: bool = false,
    source_root: []const u8 = "",
    sources_content: bool = true,
    platform: @import("codegen/codegen.zig").Platform = .browser,

    // --- JSX ---
    jsx_runtime: @import("codegen/codegen.zig").JsxRuntime = .classic,
    jsx_factory: []const u8 = "React.createElement",
    jsx_fragment: []const u8 = "React.Fragment",
    jsx_import_source: []const u8 = "react",

    // --- 타겟 ---
    /// ES 타겟. null이면 타겟 제한 검증 없음.
    /// es2022 미만에서 top-level await 사용 시 진단을 발생시킨다.
    es_target: ?@import("transformer/compat.zig").ESTarget = null,
};

/// WASM/FFI 진입점 공용 플래그 디코더.
/// 비트마스크 → TranspileOptions 변환 (비트 레이아웃은 packages/wasm, packages/core 참조).
pub fn decodeFlags(flags: u32) TranspileOptions {
    return .{
        .sourcemap = flags & (1 << 0) != 0,
        .minify_whitespace = flags & (1 << 1) != 0,
        .minify_identifiers = flags & (1 << 2) != 0,
        .minify_syntax = flags & (1 << 3) != 0,
        .jsx_runtime = if (flags & (1 << 5) != 0)
            .automatic_dev
        else if (flags & (1 << 4) != 0)
            .automatic
        else
            .classic,
        .drop_console = flags & (1 << 6) != 0,
        .drop_debugger = flags & (1 << 7) != 0,
        .ascii_only = flags & (1 << 8) != 0,
        .flow = flags & (1 << 9) != 0,
        .experimental_decorators = flags & (1 << 10) != 0,
        .emit_decorator_metadata = flags & (1 << 11) != 0,
        .module_format = switch ((flags >> 12) & 0x3) {
            0 => .esm,
            1 => .cjs,
            else => .esm,
        },
        .quote_style = switch ((flags >> 14) & 0x3) {
            0 => .double,
            1 => .single,
            2 => .preserve,
            else => .double,
        },
        .use_define_for_class_fields = flags & (1 << 16) != 0,
        .charset_utf8 = flags & (1 << 17) != 0,
        .platform = switch ((flags >> 18) & 0x3) {
            0 => .browser,
            1 => .node,
            2 => .neutral,
            3 => .react_native,
            else => .browser,
        },
        .jsx_in_js = flags & (1 << 20) != 0,
        .sourcemap_debug_ids = flags & (1 << 21) != 0,
        .sources_content = flags & (1 << 22) != 0,
    };
}

pub const TranspileError = error{
    ParseError,
    SemanticError,
    TransformError,
    CodegenError,
    OutOfMemory,
};

/// 에러 발생 시 호출되는 콜백. scanner와 source가 유효한 동안 호출됨.
/// main.zig에서 코드 프레임 출력용으로 사용.
pub const ErrorCallback = *const fn (
    source: []const u8,
    file_path: []const u8,
    scanner: *const Scanner,
    errors: []const Diagnostic,
) void;

pub const TranspileResult = struct {
    /// 변환된 JS 코드. allocator 소유.
    code: []const u8,
    /// 소스맵 JSON (sourcemap=true일 때). allocator 소유. null이면 미생성.
    sourcemap: ?[]const u8 = null,
    /// 런타임 헬퍼 포함 여부
    has_helpers: bool = false,
    /// 시맨틱 에러 여부 (tsc 호환: 에러가 있어도 output 생성)
    has_errors: bool = false,

    pub fn deinit(self: *TranspileResult, allocator: std.mem.Allocator) void {
        allocator.free(self.code);
        if (self.sourcemap) |sm| allocator.free(sm);
    }
};

/// 소스 문자열을 트랜스파일한다. I/O 없음, 순수 함수.
///
/// file_path는 확장자 감지용으로만 사용 (실제 파일 읽기 안 함).
/// 반환된 code/sourcemap은 allocator 소유 — caller가 deinit() 해야 함.
pub fn transpile(
    allocator: std.mem.Allocator,
    source: []const u8,
    file_path: []const u8,
    options: TranspileOptions,
) TranspileError!TranspileResult {
    return transpileWithCallback(allocator, source, file_path, options, null);
}

/// 에러 콜백 포함 트랜스파일. 파서/시맨틱 에러 시 콜백을 호출한 뒤 에러를 반환.
pub fn transpileWithCallback(
    allocator: std.mem.Allocator,
    source: []const u8,
    file_path: []const u8,
    options: TranspileOptions,
    on_error: ?ErrorCallback,
) TranspileError!TranspileResult {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const arena_alloc = arena.allocator();

    // 1. 파싱
    var scanner = Scanner.init(arena_alloc, source) catch return error.OutOfMemory;
    var parser = Parser.init(arena_alloc, &scanner);
    parser.configureFromExtension(std.fs.path.extension(file_path));

    if (!parser.is_ts) {
        if (options.flow) {
            parser.is_flow = true;
            scanner.has_flow_pragma = true;
            if (!parser.is_module) {
                parser.is_module = true;
                scanner.is_module = true;
                parser.is_unambiguous = true;
            }
        } else {
            parser.configureFlowFromPath(file_path);
        }
    }
    if (options.jsx_in_js) {
        parser.is_jsx = true;
    }
    _ = parser.parse() catch return error.ParseError;
    if (parser.errors.items.len > 0) {
        if (on_error) |cb| cb(source, file_path, &scanner, parser.errors.items);
        return error.ParseError;
    }

    // 2. Semantic analysis
    // tsc 호환: 시맨틱 에러가 있어도 codegen을 진행한다.
    // 에러는 콜백으로 stderr에 출력하되, 변환 결과도 함께 반환한다.
    var analyzer = SemanticAnalyzer.init(arena_alloc, &parser.ast);
    analyzer.is_strict_mode = parser.is_strict_mode;
    analyzer.is_module = parser.is_module;
    analyzer.is_ts = parser.is_ts;
    analyzer.is_flow = parser.is_flow;
    analyzer.es_target = options.es_target;
    analyzer.analyze() catch return error.SemanticError;
    if (analyzer.errors.items.len > 0) {
        if (on_error) |cb| cb(source, file_path, &scanner, analyzer.errors.items);
        // tsc처럼 에러와 함께 output도 생성 — 중단하지 않음
    }

    // 3. Identifier mangling (--minify-identifiers)
    var mangle_result: ?Mangler.ManglerResult = null;
    defer if (mangle_result) |*mr| mr.deinit();

    if (options.minify_identifiers) {
        if (analyzer.symbols.items.len > 0 and analyzer.scope_maps.items.len > 0) {
            mangle_result = Mangler.mangle(arena_alloc, .{
                .scopes = analyzer.scopes.items,
                .symbols = analyzer.symbols.items,
                .scope_maps = analyzer.scope_maps.items,
                .ref_scope_pairs = analyzer.ref_scope_pairs.items,
                .source = source,
            }) catch null;
        }
    }

    // 4. 변환
    var transformer = try Transformer.init(arena_alloc, &parser.ast, .{
        .drop_console = options.drop_console,
        .drop_debugger = options.drop_debugger,
        .define = options.define,
        .use_define_for_class_fields = options.use_define_for_class_fields,
        .experimental_decorators = options.experimental_decorators,
        .emit_decorator_metadata = options.emit_decorator_metadata,
        .unsupported = options.unsupported,
        // JSX lowering: JSX가 있는 모듈에서만 활성화
        .jsx_transform = parser.ast.has_jsx,
        .jsx_runtime = options.jsx_runtime,
        .jsx_factory = options.jsx_factory,
        .jsx_fragment = options.jsx_fragment,
        .jsx_import_source = options.jsx_import_source,
        .jsx_filename = file_path,
    });
    transformer.initSymbolIds(analyzer.symbol_ids.items) catch return error.TransformError;
    transformer.symbols = analyzer.symbols.items;
    transformer.line_offsets = scanner.line_offsets.items;
    const root = transformer.transform() catch return error.TransformError;

    if (options.minify_syntax) {
        @import("transformer/minify.zig").minify(&transformer.ast);
    }

    // 5. Mangling 메타데이터 구성
    var mangle_metadata: ?LinkingMetadata = null;
    defer if (mangle_metadata) |*mm| mm.skip_nodes.deinit();

    if (mangle_result) |*mr| {
        const node_count = transformer.ast.nodes.items.len;
        mangle_metadata = .{
            .skip_nodes = std.DynamicBitSet.initEmpty(arena_alloc, node_count) catch return error.OutOfMemory,
            .renames = mr.renames,
            .final_exports = null,
            .symbol_ids = if (transformer.symbol_ids.items.len > 0)
                transformer.symbol_ids.items
            else if (analyzer.symbol_ids.items.len > 0)
                analyzer.symbol_ids.items
            else
                &.{},
            .allocator = arena_alloc,
        };
    }

    // 6. 코드 생성
    var cg = Codegen.initWithOptions(arena_alloc, &transformer.ast, .{
        .module_format = options.module_format,
        .minify_whitespace = options.minify_whitespace,
        .sourcemap = options.sourcemap,
        .ascii_only = if (options.charset_utf8) false else options.ascii_only,
        .quote_style = options.quote_style,
        .linking_metadata = if (mangle_metadata) |*mm| mm else null,
        .platform = options.platform,
        .source_root = options.source_root,
        .sources_content = options.sources_content,
        .strip_hashbang = options.unsupported.hashbang,
        // JSX: Transformer가 이미 call_expression으로 lowering 완료. codegen에 JSX 옵션 불필요.
    });
    cg.comments = scanner.comments.items;
    if (options.sourcemap) {
        cg.addSourceFile(file_path) catch {};
        cg.line_offsets = scanner.line_offsets.items;
    }
    const raw_output = cg.generate(root) catch return error.CodegenError;

    // 6.5. JSX import prepend (transformer가 JSX lowering 수행한 경우)
    const jsx_output = if (transformer.jsx_import_info.hasImports()) blk: {
        const is_dev = options.jsx_runtime == .automatic_dev;
        if (transformer.jsx_import_info.buildImportString(arena_alloc, options.jsx_import_source, is_dev)) |import_str| {
            var combined: std.ArrayList(u8) = .empty;
            combined.ensureTotalCapacity(arena_alloc, import_str.len + raw_output.len) catch break :blk raw_output;
            combined.appendSliceAssumeCapacity(import_str);
            combined.appendSliceAssumeCapacity(raw_output);
            break :blk combined.items;
        } else break :blk raw_output;
    } else raw_output;

    // 7. 런타임 헬퍼 prepend
    const rh = transformer.runtime_helpers;
    const has_helpers = @as(u16, @bitCast(rh)) != 0;
    const output = if (has_helpers) blk: {
        var buf: std.ArrayList(u8) = .empty;
        rt.appendRuntimeHelpers(&buf, arena_alloc, rh, options.minify_whitespace, transformer.runtime_es5_compat) catch
            break :blk jsx_output;
        buf.appendSlice(arena_alloc, jsx_output) catch break :blk jsx_output;
        break :blk buf.items;
    } else jsx_output;

    // 8. Sentry Debug ID (UUID v4) — sourcemap_debug_ids 활성화 시 생성
    var debug_id_buf: [36]u8 = undefined;
    const debug_id: ?[]const u8 = if (options.sourcemap_debug_ids) blk: {
        SourceMap.generateUuidV4(&debug_id_buf);
        break :blk &debug_id_buf;
    } else null;

    // 9. 소스맵 생성
    var sourcemap_json: ?[]const u8 = null;
    if (options.sourcemap) {
        if (cg.sm_builder) |*sm| {
            sm.debug_id = debug_id;
            if (sm.generateJSON(file_path) catch null) |sm_json| {
                sourcemap_json = allocator.dupe(u8, sm_json) catch null;
            }
        }
    }

    // 10. debugId 주석을 출력 코드 끝에 추가
    const final_output = if (debug_id) |did| blk: {
        var buf: std.ArrayList(u8) = .empty;
        buf.appendSlice(arena_alloc, output) catch break :blk output;
        buf.appendSlice(arena_alloc, "//# debugId=") catch break :blk output;
        buf.appendSlice(arena_alloc, did) catch break :blk output;
        buf.append(arena_alloc, '\n') catch break :blk output;
        break :blk buf.items;
    } else output;

    // Arena 밖으로 복제
    const result_code = allocator.dupe(u8, final_output) catch return error.OutOfMemory;
    arena.deinit();
    return .{
        .code = result_code,
        .sourcemap = sourcemap_json,
        .has_helpers = has_helpers,
        .has_errors = analyzer.errors.items.len > 0,
    };
}
