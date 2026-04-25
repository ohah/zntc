const std = @import("std");
pub const codegen_mod = @import("../codegen.zig");
pub const Codegen = codegen_mod.Codegen;
pub const CodegenOptions = codegen_mod.CodegenOptions;
pub const Scanner = @import("../../lexer/scanner.zig").Scanner;
pub const Parser = @import("../../parser/parser.zig").Parser;
pub const transformer_mod = @import("../../transformer/transformer.zig");
pub const Transformer = transformer_mod.Transformer;
pub const TransformOptions = transformer_mod.TransformOptions;
const SourceMapBuilder = @import("../sourcemap.zig").SourceMapBuilder;
pub const Mapping = @import("../sourcemap.zig").Mapping;
/// Arena 기반 테스트 결과. deinit()으로 모든 메모리를 일괄 해제.
pub const TestResult = struct {
    output: []const u8,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *TestResult) void {
        self.arena.deinit();
    }
};

/// 소스맵 테스트 결과. output + mappings 접근 가능.
pub const SourceMapTestResult = struct {
    output: []const u8,
    mappings: []const Mapping,
    source_map_json: []const u8,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *SourceMapTestResult) void {
        self.arena.deinit();
    }

    /// 출력에서 target 문자열의 시작 위치에 매핑이 존재하는지 확인.
    /// 매핑의 original_column이 expected_src_col과 일치하는지도 검증.
    pub fn expectMappingAt(self: *const SourceMapTestResult, target: []const u8, expected_src_line: u32, expected_src_col: u32) !void {
        // 출력에서 target의 위치 (줄/열) 계산
        const pos = std.mem.indexOf(u8, self.output, target) orelse
            return error.TargetNotFound;
        var gen_line: u32 = 0;
        var gen_col: u32 = 0;
        for (self.output[0..pos]) |c| {
            if (c == '\n') {
                gen_line += 1;
                gen_col = 0;
            } else {
                gen_col += 1;
            }
        }
        // 해당 출력 위치에 가장 가까운 매핑 찾기
        var best: ?Mapping = null;
        for (self.mappings) |m| {
            if (m.generated_line == gen_line and m.generated_column <= gen_col) {
                if (best == null or m.generated_column > best.?.generated_column) {
                    best = m;
                }
            }
        }
        const m = best orelse return error.NoMappingFound;
        try std.testing.expectEqual(expected_src_line, m.original_line);
        try std.testing.expectEqual(expected_src_col, m.original_column);
    }
};

/// 소스맵 활성화 e2e. 매핑 결과에 접근 가능.
/// 소유권: 반환된 arena는 caller 소유 (`defer r.arena.deinit()` 필수).
pub fn e2eSourceMap(backing_allocator: std.mem.Allocator, source: []const u8) !SourceMapTestResult {
    var arena = std.heap.ArenaAllocator.init(backing_allocator);
    errdefer arena.deinit();
    const allocator = arena.allocator();

    var scanner = try Scanner.init(allocator, source);
    var parser = Parser.init(allocator, &scanner);
    parser.configureFromExtension(".ts");
    _ = try parser.parse();

    var t = try Transformer.init(allocator, &parser.ast, .{});
    const root = try t.transform();

    var cg = Codegen.initWithOptions(allocator, t.ast, .{ .sourcemap = true });
    cg.line_offsets = scanner.line_offsets.items;
    try cg.addSourceFile("input.ts");
    const output = try cg.generate(root);
    const json = try cg.generateSourceMap("output.js") orelse "";
    const json_copy = try allocator.dupe(u8, json);

    // 매핑을 arena에 복사
    const mappings = if (cg.sm_builder) |*sm|
        try allocator.dupe(Mapping, sm.mappings.items)
    else
        &[_]Mapping{};

    return .{
        .output = output,
        .mappings = mappings,
        .source_map_json = json_copy,
        .arena = arena,
    };
}

/// 기본 e2e: minify 모드 (기존 테스트 호환)
pub fn e2e(allocator: std.mem.Allocator, source: []const u8) !TestResult {
    return e2eWithOptions(allocator, source, .{ .minify_whitespace = true });
}

pub fn e2eCJS(allocator: std.mem.Allocator, source: []const u8) !TestResult {
    return e2eWithOptions(allocator, source, .{ .module_format = .cjs, .minify_whitespace = true });
}

pub fn e2eJSX(allocator: std.mem.Allocator, source: []const u8) !TestResult {
    return e2eFull(allocator, source, .{
        .jsx_transform = true,
        .jsx_runtime = .classic,
    }, .{ .minify_whitespace = true }, ".tsx");
}

/// 풀 옵션 e2e. ext로 확장자 지정 (".ts" 기본, ".tsx"면 JSX 모드).
/// Arena로 전체 파이프라인을 실행. output은 arena 메모리를 가리키므로
/// TestResult.deinit() 전에 사용해야 한다.
///
/// 소유권: 반환된 TestResult.arena는 **caller 소유**. caller가 반드시
/// `defer r.arena.deinit();` 호출 필요. 성공 경로에선 errdefer가 실행되지
/// 않으므로 caller defer가 유일한 해제 경로. 누락 시 arena 누수 (테스트 전용
/// 이라 프로덕션 영향은 없음).
pub fn e2eFull(backing_allocator: std.mem.Allocator, source: []const u8, t_options: TransformOptions, cg_options: CodegenOptions, ext: []const u8) !TestResult {
    var arena = std.heap.ArenaAllocator.init(backing_allocator);
    errdefer arena.deinit();
    const allocator = arena.allocator();

    var scanner = try Scanner.init(allocator, source);
    var parser = Parser.init(allocator, &scanner);
    parser.configureFromExtension(ext);
    _ = try parser.parse();
    // Parser diagnostics 가 누적되어 있는데 silent ignore 하면 spec-violation source 가
    // codegen 까지 흘러들어 test 가 false-pass — silent regression 위험 (#1906). errors
    // 가 있으면 첫 메시지를 stderr 에 dump 하고 test fail 처리. 의도된 negative test 는
    // `e2eFullExpectingErrors` 사용.
    if (parser.errors.items.len > 0) {
        const first = parser.errors.items[0];
        std.debug.print("\nparser error in e2eFull: {s}\n  source: {s}\n", .{ first.message, source });
        return error.ParserDiagnosticsPresent;
    }

    var t = try Transformer.init(allocator, &parser.ast, t_options);
    t.line_offsets = scanner.line_offsets.items;
    const root = try t.transform();

    var cg = Codegen.initWithOptions(allocator, t.ast, cg_options);
    const raw_output = try cg.generate(root);

    // JSX import prepend (transformer가 JSX lowering 수행한 경우)
    const output = if (t.jsx_import_info.hasImports()) blk: {
        const is_dev = t.options.jsx_runtime == .automatic_dev;
        if (t.jsx_import_info.buildImportString(allocator, t.options.jsx_import_source, is_dev)) |import_str| {
            var combined: std.ArrayList(u8) = .empty;
            try combined.ensureTotalCapacity(allocator, import_str.len + raw_output.len);
            combined.appendSliceAssumeCapacity(import_str);
            combined.appendSliceAssumeCapacity(raw_output);
            break :blk combined.items;
        } else break :blk raw_output;
    } else raw_output;

    return .{ .output = output, .arena = arena };
}

pub fn e2eWithOptions(allocator: std.mem.Allocator, source: []const u8, cg_options: CodegenOptions) !TestResult {
    return e2eFull(allocator, source, .{}, cg_options, ".ts");
}

// --- ES downlevel helpers ---

pub fn e2eTarget(allocator: std.mem.Allocator, source: []const u8, target: TransformOptions.compat.ESTarget) !TestResult {
    return e2eFull(allocator, source, .{ .unsupported = TransformOptions.compat.fromESTarget(target) }, .{ .minify_whitespace = true }, ".ts");
}

pub fn expectAsyncStateMachine(output: []const u8) !void {
    try std.testing.expect(std.mem.indexOf(u8, output, "__async") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "__generator") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "function*") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "yield") == null);
}

/// `e2eTarget(.es5)` + 표준 async state-machine 검증 (`expectAsyncStateMachine` +
/// `assertNoAsyncSelfLoop`). 호출자는 deinit 만 책임 + 추가 assertion 자유.
pub fn e2eES5Async(allocator: std.mem.Allocator, source: []const u8) !TestResult {
    var r = try e2eTarget(allocator, source, .es5);
    errdefer r.deinit();
    try expectAsyncStateMachine(r.output);
    try assertNoAsyncSelfLoop(r.output);
    return r;
}

/// `case N:_state.sent();return [3,N]` (await resume 직후 자기 case label 으로 jump = self-loop).
/// 정상은 forward jump (`[3,M]` with M > N) 또는 end (`[2]`). 모든 `_state.sent();return [3,M]` 출현
/// 별로 그 직전 `case N:` 를 찾아 N == M 이면 self-loop. case 수 무제한.
/// (zts/issues/1887 회귀 방지 — `collectIfOperations` sentinel/fixup 패턴 검증.)
///
/// 패턴은 emitter 의 minified emit format 에 의존 — `es2015_generator.zig` 의 `__generator`
/// state machine 출력 + `_state` identifier (mangle 대상 제외) + `case N:` 형태.
/// emit 형식 변경 시 false negative 방지를 위해 self-test (`testing-detection-positive`) 동반.
pub fn assertNoAsyncSelfLoop(output: []const u8) !void {
    var search_start: usize = 0;
    while (std.mem.indexOfPos(u8, output, search_start, ASYNC_SENT_RETURN_PREFIX)) |sent_pos| {
        const target_start = sent_pos + ASYNC_SENT_RETURN_PREFIX.len;
        const target_end = std.mem.indexOfScalarPos(u8, output, target_start, ']') orelse break;
        const target_str = std.mem.trim(u8, output[target_start..target_end], " ");
        const target_label = std.fmt.parseInt(u32, target_str, 10) catch {
            search_start = target_end;
            continue;
        };
        const before = output[0..sent_pos];
        const case_pos = std.mem.lastIndexOf(u8, before, ASYNC_CASE_PREFIX) orelse {
            search_start = target_end;
            continue;
        };
        const num_start = case_pos + ASYNC_CASE_PREFIX.len;
        const num_end = std.mem.indexOfScalarPos(u8, output, num_start, ':') orelse break;
        const case_label = std.fmt.parseInt(u32, output[num_start..num_end], 10) catch {
            search_start = target_end;
            continue;
        };
        if (case_label == target_label) {
            std.debug.print("\nself-loop detected: case {d} → return [3,{d}] in:\n{s}\n", .{ case_label, target_label, output });
            return error.AsyncSelfLoopDetected;
        }
        search_start = target_end;
    }
}

/// `assertNoAsyncSelfLoop` 가 의존하는 emitter 출력 markers. emitter 변경 시 동반 update.
/// 출처: `src/transformer/es2015_generator.zig` 의 `__generator` state machine + `_state.sent()`.
const ASYNC_SENT_RETURN_PREFIX = "_state.sent();return [3,";
const ASYNC_CASE_PREFIX = "case ";

test "assertNoAsyncSelfLoop: positive control — detect intentional self-loop" {
    // emitter 출력 형식이 silent 하게 변경돼서 assertion 이 false negative 로 통과하는 회귀 방지.
    // 인공 self-loop string → detection 작동 확인.
    const synthetic = "case 1:_state.sent();return [3,1];case 2:return [2];";
    try std.testing.expectError(error.AsyncSelfLoopDetected, assertNoAsyncSelfLoop(synthetic));
}

test "assertNoAsyncSelfLoop: positive control — accept forward jump" {
    // 정상 forward jump (case 1 → label 2) 은 통과해야.
    const synthetic = "case 1:_state.sent();return [3,2];case 2:return [2];";
    try assertNoAsyncSelfLoop(synthetic);
}

test "assertNoAsyncSelfLoop: positive control — accept multiple cases without self-loop" {
    // 여러 await — 각 case 의 jump target 이 자기보다 큰 label 이면 모두 정상.
    const synthetic = "case 1:_state.sent();return [3,3];case 2:_state.sent();return [3,5];case 6:return [2];";
    try assertNoAsyncSelfLoop(synthetic);
}

// --- Flow helpers ---

pub fn e2eFlow(backing_allocator: std.mem.Allocator, source: []const u8) !TestResult {
    return e2eFlowImpl(backing_allocator, source, false);
}

pub fn e2eFlowModule(backing_allocator: std.mem.Allocator, source: []const u8) !TestResult {
    return e2eFlowImpl(backing_allocator, source, true);
}

pub fn e2eFlowImpl(backing_allocator: std.mem.Allocator, source: []const u8, is_module: bool) !TestResult {
    var arena = std.heap.ArenaAllocator.init(backing_allocator);
    errdefer arena.deinit();
    const allocator = arena.allocator();

    var scanner = try Scanner.init(allocator, source);
    var parser = Parser.init(allocator, &scanner);
    parser.configureFromExtension(".js");
    parser.is_flow = true;
    if (is_module) {
        parser.is_module = true;
        scanner.is_module = true;
    }
    _ = try parser.parse();

    var t = try Transformer.init(allocator, &parser.ast, .{});
    const root = try t.transform();

    var cg = Codegen.initWithOptions(allocator, t.ast, .{ .minify_whitespace = true });
    const output = try cg.generate(root);

    return .{ .output = output, .arena = arena };
}

// --- Engine target helpers ---

pub const compat = TransformOptions.compat;

pub fn e2eEngine(allocator: std.mem.Allocator, source: []const u8, targets: []const compat.EngineVersion) !TestResult {
    return e2eFull(allocator, source, .{ .unsupported = compat.unsupportedFeatures(targets) }, .{ .minify_whitespace = true }, ".ts");
}

// --- JSX helpers ---

pub fn e2eJSXAutomatic(allocator: std.mem.Allocator, source: []const u8) !TestResult {
    return e2eFull(allocator, source, .{
        .jsx_transform = true,
        .jsx_runtime = .automatic,
        .jsx_import_source = "react",
    }, .{}, ".tsx");
}

pub fn e2eJSXDev(allocator: std.mem.Allocator, source: []const u8) !TestResult {
    return e2eFull(allocator, source, .{
        .jsx_transform = true,
        .jsx_runtime = .automatic_dev,
        .jsx_import_source = "react",
        .jsx_filename = "test.tsx",
    }, .{}, ".tsx");
}

pub fn e2eJSXAutomaticTarget(allocator: std.mem.Allocator, source: []const u8, target: TransformOptions.compat.ESTarget) !TestResult {
    return e2eFull(allocator, source, .{
        .jsx_transform = true,
        .jsx_runtime = .automatic,
        .jsx_import_source = "react",
        .unsupported = TransformOptions.compat.fromESTarget(target),
    }, .{ .minify_whitespace = true }, ".tsx");
}

pub fn e2eDecorator(allocator: std.mem.Allocator, source: []const u8) !TestResult {
    return e2eFull(allocator, source, .{
        .experimental_decorators = true,
    }, .{ .minify_whitespace = true }, ".ts");
}

pub fn e2eDecoratorMetadata(allocator: std.mem.Allocator, source: []const u8) !TestResult {
    return e2eFull(allocator, source, .{
        .experimental_decorators = true,
        .emit_decorator_metadata = true,
    }, .{ .minify_whitespace = true }, ".ts");
}

/// Stage 3 (TC39) decorator e2e: experimental_decorators=false (기본값).
/// TypeScript 5.0+ 형식의 __esDecorate/__runInitializers 출력을 검증.
pub fn e2eStage3Decorator(allocator: std.mem.Allocator, source: []const u8) !TestResult {
    return e2eFull(allocator, source, .{
        // experimental_decorators 기본값 = false → Stage 3 경로
    }, .{}, ".ts");
}

pub fn e2eDecoratorES5(allocator: std.mem.Allocator, source: []const u8) !TestResult {
    return e2eFull(allocator, source, .{
        .experimental_decorators = true,
        .unsupported = TransformOptions.compat.fromESTarget(.es5),
    }, .{ .minify_whitespace = true }, ".ts");
}

pub fn e2eJSXClassicTarget(allocator: std.mem.Allocator, source: []const u8, target: TransformOptions.compat.ESTarget) !TestResult {
    return e2eFull(allocator, source, .{
        .jsx_transform = true,
        .jsx_runtime = .classic,
        .unsupported = TransformOptions.compat.fromESTarget(target),
    }, .{ .minify_whitespace = true }, ".tsx");
}
