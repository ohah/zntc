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
const Codegen = @import("codegen/codegen.zig").Codegen;
const rt = @import("bundler/runtime_helpers.zig");

pub const TranspileOptions = struct {
    /// Flow 타입 스트리핑 활성화
    flow: bool = false,
    /// .js 파일에서도 JSX 파싱 활성화
    jsx_in_js: bool = false,
    /// define 글로벌 치환
    define: []const @import("transformer/transformer.zig").DefineEntry = &.{},
    /// ES 타겟
    unsupported: @import("transformer/transformer.zig").TransformOptions.compat.UnsupportedFeatures = .{},
    /// useDefineForClassFields
    use_define_for_class_fields: bool = true,
    /// experimentalDecorators
    experimental_decorators: bool = false,
    /// minify whitespace
    minify_whitespace: bool = false,
    /// minify syntax (constant folding, DCE)
    minify_syntax: bool = false,
    /// JSX 런타임
    jsx_runtime: @import("codegen/codegen.zig").JsxRuntime = .classic,
    /// JSX factory
    jsx_factory: []const u8 = "React.createElement",
    /// JSX fragment
    jsx_fragment: []const u8 = "React.Fragment",
    /// JSX import source
    jsx_import_source: []const u8 = "react",
};

pub const TranspileError = error{
    ParseError,
    SemanticError,
    TransformError,
    CodegenError,
    OutOfMemory,
};

pub const TranspileResult = struct {
    /// 변환된 JS 코드. allocator 소유.
    code: []const u8,
    /// 런타임 헬퍼 포함 여부 (코드 앞에 prepend됨)
    has_helpers: bool,

    pub fn deinit(self: TranspileResult, allocator: std.mem.Allocator) void {
        allocator.free(self.code);
    }
};

/// 소스 문자열을 트랜스파일한다. I/O 없음, 순수 함수.
///
/// file_path는 확장자 감지용으로만 사용 (실제 파일 읽기 안 함).
/// 반환된 code는 allocator 소유 — caller가 deinit() 또는 free() 해야 함.
pub fn transpile(
    allocator: std.mem.Allocator,
    source: []const u8,
    file_path: []const u8,
    options: TranspileOptions,
) TranspileError!TranspileResult {
    // Arena: 파싱~코드젠까지 임시 데이터. 최종 output만 allocator로 복제.
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    // 1. 파싱
    var scanner = Scanner.init(arena_alloc, source) catch return error.OutOfMemory;
    var parser = Parser.init(arena_alloc, &scanner);
    parser.configureFromExtension(std.fs.path.extension(file_path));

    // Flow 설정
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
    if (parser.errors.items.len > 0) return error.ParseError;

    // 2. Semantic analysis
    var analyzer = SemanticAnalyzer.init(arena_alloc, &parser.ast);
    analyzer.is_strict_mode = parser.is_strict_mode;
    analyzer.is_module = parser.is_module;
    analyzer.is_ts = parser.is_ts;
    analyzer.is_flow = parser.is_flow;
    analyzer.analyze() catch return error.SemanticError;
    if (analyzer.errors.items.len > 0) return error.SemanticError;

    // 3. 변환
    var transformer = Transformer.init(arena_alloc, &parser.ast, .{
        .define = options.define,
        .use_define_for_class_fields = options.use_define_for_class_fields,
        .experimental_decorators = options.experimental_decorators,
        .unsupported = options.unsupported,
    });
    transformer.old_symbol_ids = analyzer.symbol_ids.items;
    transformer.symbols = analyzer.symbols.items;
    const root = transformer.transform() catch return error.TransformError;

    if (options.minify_syntax) {
        @import("root.zig").transformer.minify.minify(&transformer.new_ast);
    }

    // 4. 코드 생성
    var cg = Codegen.initWithOptions(arena_alloc, &transformer.new_ast, .{
        .minify_whitespace = options.minify_whitespace,
        .jsx_runtime = options.jsx_runtime,
        .jsx_factory = options.jsx_factory,
        .jsx_fragment = options.jsx_fragment,
        .jsx_import_source = options.jsx_import_source,
        .jsx_filename = file_path,
    });
    cg.comments = scanner.comments.items;
    const raw_output = cg.generate(root) catch return error.CodegenError;

    // 5. 런타임 헬퍼 prepend
    const rh = transformer.runtime_helpers;
    const has_helpers = @as(u16, @bitCast(rh)) != 0;
    const output = if (has_helpers) blk: {
        var buf: std.ArrayList(u8) = .empty;
        rt.appendRuntimeHelpers(&buf, arena_alloc, rh, options.minify_whitespace, transformer.runtime_es5_compat) catch
            break :blk raw_output;
        buf.appendSlice(arena_alloc, raw_output) catch break :blk raw_output;
        break :blk buf.items;
    } else raw_output;

    // Arena 밖으로 복제 (arena.deinit 뒤에도 유효하게)
    const result = allocator.dupe(u8, output) catch return error.OutOfMemory;
    return .{ .code = result, .has_helpers = has_helpers };
}
