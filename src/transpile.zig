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
const OwnedDiagnostic = @import("diagnostic.zig").OwnedDiagnostic;

/// 파이프라인 조기 종료 지점. `--stop-after=<phase>` / `stopAfter` 옵션과 매핑.
///
/// 주로 debug/profile 용 — 특정 phase 까지만 실행하고 빈 output 반환. 예를 들어
/// `stop_after = .parse` 이면 AST 는 생성되지만 semantic/transform/codegen 은 skip.
/// `--profile` 과 결합해 phase 별 비용을 격리 측정할 수 있다.
pub const StopAfter = enum {
    scan,
    parse,
    semantic,
    transform,
    codegen,

    pub fn fromString(s: []const u8) ?StopAfter {
        const trimmed = std.mem.trim(u8, s, " \t");
        if (std.ascii.eqlIgnoreCase(trimmed, "scan")) return .scan;
        if (std.ascii.eqlIgnoreCase(trimmed, "parse")) return .parse;
        if (std.ascii.eqlIgnoreCase(trimmed, "semantic")) return .semantic;
        if (std.ascii.eqlIgnoreCase(trimmed, "transform")) return .transform;
        if (std.ascii.eqlIgnoreCase(trimmed, "codegen")) return .codegen;
        return null;
    }
};

pub const TranspileOptions = struct {
    // --- 파싱 ---
    flow: bool = false,
    jsx_in_js: bool = false,

    /// 파이프라인 조기 종료 지점. null(기본)이면 codegen 까지 실행.
    /// 지정 시 해당 phase 이후 단계는 skip — debug/profile 용.
    stop_after: ?StopAfter = null,

    // --- 변환 ---
    define: []const DefineEntry = &.{},
    unsupported: TransformOptions.compat.UnsupportedFeatures = .{},
    use_define_for_class_fields: bool = true,
    experimental_decorators: bool = false,
    emit_decorator_metadata: bool = false,
    verbatim_module_syntax: bool = false,
    /// tsconfig.json 경로 (파일 또는 디렉토리). 설정 시 로드해서 compilerOptions 적용.
    /// CLI `-p`/`--project` 의 프로그램적 등가물 — NAPI/WASM 경로에서 같은 동작을 JS 에 제공.
    tsconfig_path: ?[]const u8 = null,
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

/// WASM/NAPI 진입점 공용 JSON payload DTO.
/// TS 쪽 TranspileOptions와 camelCase 필드명으로 매핑된다.
/// 모든 필드가 optional이라 누락되어도 기본값 유지.
///
/// enum 타입은 Zig enum을 직접 사용 — std.json이 enum tag name으로 parse.
/// JS 래퍼가 kebab-case "react-native" → "react_native"로 변환해 전달한다.
///
/// 이 struct는 JSON schema emitter(tools/emit_schema.zig)가 comptime
/// `@typeInfo`로 반사해 단일 소스 보장. 필드를 바꾸면 schema도 함께 재생성.
pub const TranspileOptionsDto = struct {
    target: ?@import("transformer/compat.zig").ESTarget = null,
    unsupported: ?u32 = null,
    flow: ?bool = null,
    jsxInJs: ?bool = null,
    jsx: ?@import("codegen/codegen.zig").JsxRuntime = null,
    jsxFactory: ?[]const u8 = null,
    jsxFragment: ?[]const u8 = null,
    jsxImportSource: ?[]const u8 = null,
    dropConsole: ?bool = null,
    dropDebugger: ?bool = null,
    asciiOnly: ?bool = null,
    charsetUtf8: ?bool = null,
    experimentalDecorators: ?bool = null,
    emitDecoratorMetadata: ?bool = null,
    useDefineForClassFields: ?bool = null,
    verbatimModuleSyntax: ?bool = null,
    tsconfigPath: ?[]const u8 = null,
    format: ?@import("codegen/codegen.zig").ModuleFormat = null,
    quotes: ?@import("codegen/codegen.zig").QuoteStyle = null,
    platform: ?@import("codegen/codegen.zig").Platform = null,
    minifyWhitespace: ?bool = null,
    minifyIdentifiers: ?bool = null,
    minifySyntax: ?bool = null,
    sourcemap: ?bool = null,
    sourcemapDebugIds: ?bool = null,
    sourcesContent: ?bool = null,
    sourceRoot: ?[]const u8 = null,
    define: ?[]const DefineEntry = null,
    /// `--stop-after=<phase>` 동등. JSON 값은 `scan`/`parse`/`semantic`/`transform`/`codegen`.
    stopAfter: ?StopAfter = null,
};

/// JSON payload를 파싱해 `TranspileOptions`로 변환한다.
/// allocator는 arena 권장 — 반환된 값의 문자열/슬라이스 수명을 책임진다.
///
/// 오류: JSON 파싱 실패 / 알 수 없는 enum 문자열 → error 반환.
pub fn optionsFromJson(allocator: std.mem.Allocator, json: []const u8) !TranspileOptions {
    const parsed = std.json.parseFromSliceLeaky(TranspileOptionsDto, allocator, json, .{ .ignore_unknown_fields = true }) catch return error.InvalidOptions;

    var opts: TranspileOptions = .{};
    const compat = @import("transformer/compat.zig");

    if (parsed.target) |t| opts.es_target = t;
    if (parsed.unsupported) |u| {
        opts.unsupported = @bitCast(u);
    } else if (opts.es_target) |t| {
        opts.unsupported = compat.fromESTarget(t);
    }
    if (parsed.flow) |v| opts.flow = v;
    if (parsed.jsxInJs) |v| opts.jsx_in_js = v;
    if (parsed.jsx) |v| opts.jsx_runtime = v;
    if (parsed.jsxFactory) |s| if (s.len > 0) {
        opts.jsx_factory = s;
    };
    if (parsed.jsxFragment) |s| if (s.len > 0) {
        opts.jsx_fragment = s;
    };
    if (parsed.jsxImportSource) |s| if (s.len > 0) {
        opts.jsx_import_source = s;
    };
    if (parsed.dropConsole) |v| opts.drop_console = v;
    if (parsed.dropDebugger) |v| opts.drop_debugger = v;
    if (parsed.asciiOnly) |v| opts.ascii_only = v;
    if (parsed.charsetUtf8) |v| opts.charset_utf8 = v;
    if (parsed.experimentalDecorators) |v| opts.experimental_decorators = v;
    if (parsed.emitDecoratorMetadata) |v| opts.emit_decorator_metadata = v;
    if (parsed.useDefineForClassFields) |v| opts.use_define_for_class_fields = v;
    if (parsed.verbatimModuleSyntax) |v| opts.verbatim_module_syntax = v;
    if (parsed.tsconfigPath) |s| if (s.len > 0) {
        opts.tsconfig_path = s;
    };
    if (parsed.format) |v| opts.module_format = v;
    if (parsed.quotes) |v| opts.quote_style = v;
    if (parsed.platform) |v| opts.platform = v;
    if (parsed.minifyWhitespace) |v| opts.minify_whitespace = v;
    if (parsed.minifyIdentifiers) |v| opts.minify_identifiers = v;
    if (parsed.minifySyntax) |v| opts.minify_syntax = v;
    if (parsed.sourcemap) |v| opts.sourcemap = v;
    if (parsed.sourcemapDebugIds) |v| opts.sourcemap_debug_ids = v;
    if (parsed.sourcesContent) |v| opts.sources_content = v;
    if (parsed.sourceRoot) |s| if (s.len > 0) {
        opts.source_root = s;
    };
    if (parsed.define) |d| opts.define = d;
    if (parsed.stopAfter) |v| opts.stop_after = v;

    // tsconfig.json 로드 + merge — JSON에 명시적으로 설정된 값이 tsconfig 값을 덮어쓴다.
    // `parsed.<field> == null` 인 필드만 tsconfig 값으로 채움. 이로써 JSON > tsconfig > default 우선순위 유지.
    // WASM 타겟에선 filesystem 접근(path_open 등)이 preopen 없이 불가하므로 링크 단계에서
    // 해당 import 가 바인딩되지 못해 실패한다. 런타임에서도 호출할 수 없으므로 아예 스킵.
    const can_load_tsconfig = @import("builtin").os.tag != .wasi and @import("builtin").os.tag != .freestanding;
    if (can_load_tsconfig) if (opts.tsconfig_path) |path| {
        const TsConfig = @import("config.zig").TsConfig;
        const tsconfig_merge = @import("tsconfig_merge.zig");
        var ts = TsConfig.loadFromPath(allocator, path) catch return opts; // tsconfig 읽기 실패는 조용히 무시 (CLI와 동일)
        defer ts.deinit();

        const merged = tsconfig_merge.merge(&ts, .{
            .experimental_decorators = parsed.experimentalDecorators,
            .emit_decorator_metadata = parsed.emitDecoratorMetadata,
            .use_define_for_class_fields = parsed.useDefineForClassFields,
            .verbatim_module_syntax = parsed.verbatimModuleSyntax,
            .sourcemap = parsed.sourcemap,
            .es_target = parsed.target,
            .unsupported = if (parsed.unsupported) |u| @bitCast(u) else null,
        });
        opts.experimental_decorators = merged.experimental_decorators;
        opts.emit_decorator_metadata = merged.emit_decorator_metadata;
        opts.use_define_for_class_fields = merged.use_define_for_class_fields;
        opts.verbatim_module_syntax = merged.verbatim_module_syntax;
        opts.sourcemap = merged.sourcemap;
        opts.es_target = merged.es_target;
        opts.unsupported = merged.unsupported;
    };

    return opts;
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
    /// 시맨틱 에러 목록 (tsc 호환: codegen과 함께 반환).
    /// allocator 소유. 각 항목은 arena에서 복사된 OwnedDiagnostic.
    /// 파서 에러는 throw 경로라 여기 담기지 않는다 — on_error 콜백 참조.
    diagnostics: []const OwnedDiagnostic = &.{},
    /// 소스의 줄 시작 오프셋. diagnostics 렌더링에 필요.
    /// allocator 소유. diagnostics가 비었으면 비어 있을 수 있다.
    line_offsets: []const u32 = &.{},

    pub fn deinit(self: *TranspileResult, allocator: std.mem.Allocator) void {
        allocator.free(self.code);
        if (self.sourcemap) |sm| allocator.free(sm);
        for (self.diagnostics) |d| d.deinit(allocator);
        if (self.diagnostics.len > 0) allocator.free(self.diagnostics);
        if (self.line_offsets.len > 0) allocator.free(self.line_offsets);
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
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    // 1. 파싱
    var scanner = Scanner.init(arena_alloc, source) catch return error.OutOfMemory;

    // --stop-after=scan: 파서 호출 없이 토큰 drain 만 수행 (profile/debug 용).
    // Scanner 가 lazy 이므로 next() 로 EOF 까지 소비해야 실제 tokenization 비용이 발생.
    if (options.stop_after == .scan) {
        scanner.next() catch return error.ParseError;
        while (scanner.token.kind != .eof) {
            scanner.next() catch return error.ParseError;
        }
        return .{ .code = try allocator.dupe(u8, "") };
    }

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
    if (options.jsx_in_js and !parser.is_ts) {
        parser.is_jsx = true;
    }
    _ = parser.parse() catch return error.ParseError;
    if (parser.errors.items.len > 0) {
        if (on_error) |cb| cb(source, file_path, &scanner, parser.errors.items);
        return error.ParseError;
    }

    if (options.stop_after == .parse) {
        return .{ .code = try allocator.dupe(u8, "") };
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
    analyzer.unsupported = options.unsupported;
    analyzer.analyze() catch return error.SemanticError;
    if (analyzer.errors.items.len > 0) {
        if (on_error) |cb| cb(source, file_path, &scanner, analyzer.errors.items);
        // tsc처럼 에러와 함께 output도 생성 — 중단하지 않음
    }

    if (options.stop_after == .semantic) {
        return .{ .code = try allocator.dupe(u8, "") };
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
                .references = analyzer.references.items,
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
        .verbatim_module_syntax = options.verbatim_module_syntax,
        .unsupported = options.unsupported,
        // JSX lowering: JSX가 있는 모듈에서만 활성화
        .jsx_transform = parser.ast.has_jsx,
        .jsx_runtime = options.jsx_runtime,
        .jsx_factory = options.jsx_factory,
        .jsx_fragment = options.jsx_fragment,
        .jsx_import_source = options.jsx_import_source,
        .jsx_filename = file_path,
        // #1621: standalone transpile 경로도 minify 시 runtime helper 축약 이름 사용.
        .minify_whitespace = options.minify_whitespace,
    });
    transformer.initSymbolIds(analyzer.symbol_ids.items) catch return error.TransformError;
    transformer.symbols = analyzer.symbols.items;
    transformer.references = analyzer.references.items;
    transformer.line_offsets = scanner.line_offsets.items;
    const root = transformer.transform() catch return error.TransformError;

    if (options.stop_after == .transform) {
        return .{ .code = try allocator.dupe(u8, "") };
    }

    if (options.minify_syntax) {
        const minify_mod = @import("transformer/minify.zig");
        const ctx: minify_mod.MinifyCtx = .{
            .symbols = analyzer.symbols.items,
            .symbol_ids = transformer.symbol_ids.items,
            .scopes = analyzer.scopes.items,
            .unresolved_globals = null,
            .references = analyzer.references.items,
        };
        minify_mod.minify(transformer.ast, ctx, arena_alloc, root);
        minify_mod.mergeDecls(transformer.ast, null);
    }

    // 5. Mangling 메타데이터 구성. skip_nodes는 arena-owned이라 별도 deinit 불필요
    // (함수 종료 시 arena.deinit으로 일괄 해제).
    var mangle_metadata: ?LinkingMetadata = null;

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
            // 단일 파일 transpile: codegen 의 scope-hoisted 전용 분기를 타지 않도록 false.
            .is_bundle_context = false,
            .allocator = arena_alloc,
        };
    }

    // 6. 코드 생성
    var cg = Codegen.initWithOptions(arena_alloc, transformer.ast, .{
        .module_format = options.module_format,
        .minify_whitespace = options.minify_whitespace,
        .minify_syntax = options.minify_syntax,
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
    const has_helpers = @as(u32, @bitCast(rh)) != 0;
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

    // Arena 밖으로 복제 (arena는 함수 종료 시 defer로 해제 — line 167).
    // mangle_metadata.skip_nodes는 arena-owned이므로 별도 deinit 불필요.
    const result_code = allocator.dupe(u8, final_output) catch return error.OutOfMemory;
    errdefer allocator.free(result_code);

    // 시맨틱 에러 복사: arena → allocator. 실패 시 이미 복사된 항목들 roll back.
    const semantic_errors = analyzer.errors.items;
    const owned_diagnostics: []const OwnedDiagnostic = if (semantic_errors.len == 0) &.{} else blk: {
        const buf = allocator.alloc(OwnedDiagnostic, semantic_errors.len) catch return error.OutOfMemory;
        var filled: usize = 0;
        errdefer {
            for (buf[0..filled]) |d| d.deinit(allocator);
            allocator.free(buf);
        }
        for (semantic_errors) |d| {
            buf[filled] = try OwnedDiagnostic.init(d, allocator);
            filled += 1;
        }
        break :blk buf;
    };
    errdefer {
        for (owned_diagnostics) |d| d.deinit(allocator);
        if (owned_diagnostics.len > 0) allocator.free(owned_diagnostics);
    }

    // line_offsets도 복사 (diagnostics 렌더링용). 에러 없으면 생략.
    const owned_line_offsets: []const u32 = if (semantic_errors.len == 0)
        &.{}
    else
        allocator.dupe(u32, scanner.line_offsets.items) catch return error.OutOfMemory;

    return .{
        .code = result_code,
        .sourcemap = sourcemap_json,
        .has_helpers = has_helpers,
        .diagnostics = owned_diagnostics,
        .line_offsets = owned_line_offsets,
    };
}
