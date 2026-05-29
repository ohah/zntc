const std = @import("std");
const lib = @import("zntc_lib");
const Scanner = lib.lexer.Scanner;
const Parser = lib.parser.Parser;
const Diagnostic = lib.diagnostic.Diagnostic;
const SemanticAnalyzer = lib.semantic.SemanticAnalyzer;
const Transformer = lib.transformer.Transformer;
const Codegen = lib.codegen.Codegen;
const TsConfig = lib.config.TsConfig;
const Bundler = lib.bundler.Bundler;
const BundleOptions = lib.bundler.BundleOptions;
const emitter = lib.bundler.emitter;
const app_command = @import("cli/app.zig");
const bench_command = @import("cli/bench.zig");
const standalone_modes = @import("cli/standalone.zig");
const usage_cli = @import("cli/usage.zig");
const cli_options = @import("cli/options.zig");
const watch_cli = @import("cli/watch.zig");
const env_flag = lib.env_flag;
/// Bun 스타일 crash report: panic 발생 시 배너 + 이슈 URL 출력 후 기본 경로로 abort.
/// root 선언이라야 컴파일러가 safety panic을 여기로 보낸다.
pub const panic = lib.crash_handler.panic;

/// CLI에서 파싱한 옵션들을 transpileFile / walkAndTranspile에 전달한다.
const TranspileOptions = struct {
    /// 핵심 트랜스파일 옵션 (transpile.zig에 직접 전달)
    core: lib.transpile.TranspileOptions = .{},
    /// --allow-overwrite: 출력 파일이 입력 파일을 덮어쓰는 것을 허용
    allow_overwrite: bool = false,
};

/// transpile.zig 에러 콜백: 파서/시맨틱 에러 발생 시 코드 프레임 출력
fn printErrors(source: []const u8, file_path: []const u8, scanner: *const Scanner, errors: []const lib.diagnostic.Diagnostic) void {
    // 고정 시그니처 콜백이라 threaded io 를 받을 수 없다. 0.16 의 debug lockStderr
    // (debug_io 기반) 로 stderr writer 를 얻고, 색상은 terminal_mode 로 판정한다.
    var buf: [4096]u8 = undefined;
    const locked = std.debug.lockStderr(&buf);
    defer std.debug.unlockStderr();
    const stderr = &locked.file_writer.interface;
    const use_color = switch (locked.terminal_mode) {
        .no_color => false,
        else => true,
    };
    const source_info = lib.rich_diagnostic.SourceInfo{
        .source = source,
        .line_offsets = scanner.line_offsets.items,
    };
    const renderer = lib.diagnostic_renderer;
    const rich_diag_mod = lib.rich_diagnostic;
    const opts: renderer.RenderOptions = .{ .color = use_color, .unicode = true };

    for (errors) |diag| {
        const rich = rich_diag_mod.fromDiagnostic(diag, file_path);
        renderer.render(stderr, rich, source_info, opts) catch {};
    }
    stderr.flush() catch {};
}

/// realpath 결과는 owned. 실패 (보통 출력 파일은 미존재) 시 caller-owned 인 raw
/// 경로로 fallback — 분기해서 owned 만 free 한다. JS 측 (packages/core/bin/zntc.mjs)
/// 도 같은 전략.
fn checkAllowOverwrite(
    allocator: std.mem.Allocator,
    io: std.Io,
    stderr: anytype,
    allow_overwrite: bool,
    entry_path: []const u8,
    out_path: []const u8,
) !void {
    if (allow_overwrite) return;

    const in_abs_owned = std.Io.Dir.cwd().realPathFileAlloc(io, entry_path, allocator) catch null;
    defer if (in_abs_owned) |p| allocator.free(p);
    const in_abs = in_abs_owned orelse entry_path;

    const out_abs_owned = std.Io.Dir.cwd().realPathFileAlloc(io, out_path, allocator) catch null;
    defer if (out_abs_owned) |p| allocator.free(p);
    const out_abs = out_abs_owned orelse out_path;

    if (std.mem.eql(u8, in_abs, out_abs)) {
        try stderr.print(
            "zntc: output file '{s}' would overwrite input file (use --allow-overwrite to permit)\n",
            .{out_path},
        );
        return error.TranspileFailed;
    }
}

/// 단일 파일을 트랜스파일한다.
/// file_path: 입력 파일 경로, output_path: 출력 파일 경로 (null이면 stdout)
/// source가 null이면 file_path에서 읽고, non-null이면 해당 소스를 사용한다 (stdin 등).
///
/// Arena allocator 패턴:
/// 함수 내부에서 ArenaAllocator를 생성하여 모든 모듈(Scanner, Parser, Analyzer,
/// Transformer, Codegen)이 같은 Arena를 사용한다. 함수가 끝나면 arena.deinit()으로
/// 모든 메모리를 일괄 해제한다.
/// - Scanner의 comments/line_offsets를 Codegen이 마지막에 참조하므로
///   Phase별 Arena 분리는 불가능 → 파일당 Arena 1개가 최적.
/// - source_override(stdin)는 호출자가 관리하는 메모리이므로 Arena와 무관.
/// - cg.generate() 반환값(buf.items)은 Arena 메모리의 slice이므로
///   파일 쓰기/stdout 출력 후에야 arena.deinit()이 실행되어야 한다.
fn transpileFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    file_path: []const u8,
    source_override: ?[]const u8,
    output_path: ?[]const u8,
    options: TranspileOptions,
) !void {
    const transpile_mod = lib.transpile;
    var stderr_buf: [2048]u8 = undefined;
    var stderr_state = std.Io.File.stderr().writer(io, &stderr_buf);
    const stderr = &stderr_state.interface;
    defer stderr.flush() catch {};
    var stdout_buf: [8192]u8 = undefined;
    var stdout_state = std.Io.File.stdout().writer(io, &stdout_buf);
    const stdout = &stdout_state.interface;
    defer stdout.flush() catch {};

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    // 소스 읽기
    const source = source_override orelse blk: {
        break :blk std.Io.Dir.cwd().readFileAlloc(io, file_path, arena_alloc, std.Io.Limit.limited(100 * 1024 * 1024)) catch |err| {
            try stderr.print("zntc: cannot read '{s}': {}\n", .{ file_path, err });
            return error.TranspileFailed;
        };
    };

    // 핵심 트랜스파일 — transpile.zig에 위임 (에러 시 코드 프레임 출력 콜백).
    // 파이프라인 단계별 타이밍은 `--profile` 플래그가 활성화됐을 때 `profile` 모듈이
    // hot-path timer 로 수집한다 (PR 3 이후 hot-path 에 삽입).
    //
    // sourcemap output filename: `--sourcemap` + `-o out.js` 인 single-file CLI 에서
    // map.file 필드 + sourceMappingURL footer 가 정확한 output 파일명을 가리키도록
    // basename 만 전달 (#2217). stdout 출력 모드는 빈 문자열 → footer 안 부착.
    var core_opts = options.core;
    if (core_opts.sourcemap and output_path != null) {
        core_opts.sourcemap_output_filename = std.fs.path.basename(output_path.?);
    }
    var result = transpile_mod.transpileWithCallback(allocator, source, file_path, core_opts, &printErrors) catch |err| {
        // 콜백에서 이미 상세 에러를 출력했으므로, 파싱/시맨틱 에러는 추가 메시지 불필요
        switch (err) {
            error.ParseError, error.SemanticError => {},
            else => {
                try stderr.print("zntc: {s}: {}\n", .{ file_path, err });
            },
        }
        return error.TranspileFailed;
    };
    defer result.deinit(allocator);

    if (output_path) |out_path| {
        try checkAllowOverwrite(arena_alloc, io, stderr, options.allow_overwrite, file_path, out_path);
    }

    // 출력
    if (output_path) |out_path| {
        if (std.fs.path.dirname(out_path)) |dir| {
            std.Io.Dir.cwd().createDirPath(io, dir) catch |err| {
                try stderr.print("zntc: cannot create directory '{s}': {}\n", .{ dir, err });
                return error.TranspileFailed;
            };
        }
        std.Io.Dir.cwd().writeFile(io, .{ .sub_path = out_path, .data = result.code }) catch |err| {
            try stderr.print("zntc: cannot write '{s}': {}\n", .{ out_path, err });
            return error.TranspileFailed;
        };
        if (result.sourcemap) |sm_json| {
            const map_path = try std.fmt.allocPrint(arena_alloc, "{s}.map", .{out_path});
            std.Io.Dir.cwd().writeFile(io, .{ .sub_path = map_path, .data = sm_json }) catch |err| {
                try stderr.print("zntc: cannot write '{s}': {}\n", .{ map_path, err });
            };
        }
    } else {
        try stdout.writeAll(result.code);
    }

    // 시맨틱 에러가 있었으면 exit 1 (tsc 호환: output은 생성하되 에러 코드 반환)
    if (result.diagnostics.len > 0) return error.TranspileFailed;
}

/// 디렉토리를 재귀 순회하며 .ts/.tsx 파일을 찾아 트랜스파일한다.
/// Asset 파일(file/copy 로더)을 출력 디렉토리에 쓴다.
fn writeAssetOutputs(allocator: std.mem.Allocator, io: std.Io, asset_outputs: ?[]const emitter.OutputFile, base_dir: []const u8) !void {
    const assets = asset_outputs orelse return;
    for (assets) |a| {
        const asset_path = try std.fs.path.join(allocator, &.{ base_dir, a.path });
        defer allocator.free(asset_path);
        if (std.fs.path.dirname(asset_path)) |dir| {
            std.Io.Dir.cwd().createDirPath(io, dir) catch {};
        }
        const af = try std.Io.Dir.cwd().createFile(io, asset_path, .{});
        defer af.close(io);
        try af.writeStreamingAll(io, a.contents);
    }
}

/// input_dir: 입력 디렉토리 경로, output_dir: 출력 디렉토리 경로
/// .d.ts 파일과 node_modules 디렉토리는 건너뛴다.
fn walkAndTranspile(
    allocator: std.mem.Allocator,
    io: std.Io,
    input_dir: []const u8,
    output_dir: []const u8,
    options: TranspileOptions,
) !void {
    var stderr_buf: [2048]u8 = undefined;
    var stderr_state = std.Io.File.stderr().writer(io, &stderr_buf);
    const stderr = &stderr_state.interface;
    defer stderr.flush() catch {};
    var stdout_buf: [8192]u8 = undefined;
    var stdout_state = std.Io.File.stdout().writer(io, &stdout_buf);
    const stdout = &stdout_state.interface;
    defer stdout.flush() catch {};

    // 입력 디렉토리 열기
    var dir = std.Io.Dir.cwd().openDir(io, input_dir, .{ .iterate = true }) catch |err| {
        try stderr.print("zntc: cannot open directory '{s}': {}\n", .{ input_dir, err });
        return error.WalkFailed;
    };
    defer dir.close(io);

    // 재귀적으로 파일 순회
    var walker = dir.walk(allocator) catch |err| {
        try stderr.print("zntc: cannot walk directory '{s}': {}\n", .{ input_dir, err });
        return error.WalkFailed;
    };
    defer walker.deinit();

    var file_count: usize = 0;
    var had_errors = false;

    while (walker.next(io) catch |err| {
        try stderr.print("zntc: error walking directory: {}\n", .{err});
        return error.WalkFailed;
    }) |entry| {
        // 디렉토리는 건너뛰되, node_modules는 순회 자체를 차단할 수 없으므로
        // 파일 경로에 node_modules가 포함되면 건너뛴다
        if (entry.kind != .file) continue;

        const path = entry.path; // input_dir 기준 상대 경로

        // node_modules 포함 경로 건너뛰기
        if (std.mem.indexOf(u8, path, "node_modules") != null) continue;

        // .ts 또는 .tsx 파일만 처리
        const is_ts = std.mem.endsWith(u8, path, ".ts");
        const is_tsx = std.mem.endsWith(u8, path, ".tsx");
        if (!is_ts and !is_tsx) continue;

        // .d.ts 파일 건너뛰기
        if (std.mem.endsWith(u8, path, ".d.ts")) continue;

        // 입력 파일의 전체 경로 구성
        const input_path = try std.fs.path.join(allocator, &.{ input_dir, path });
        defer allocator.free(input_path);

        // 출력 경로 구성: 확장자를 .js로 변경
        const basename_no_ext = if (is_tsx)
            path[0 .. path.len - 4] // ".tsx" 제거
        else
            path[0 .. path.len - 3]; // ".ts" 제거
        const output_rel = try std.fmt.allocPrint(allocator, "{s}.js", .{basename_no_ext});
        defer allocator.free(output_rel);

        const output_path = try std.fs.path.join(allocator, &.{ output_dir, output_rel });
        defer allocator.free(output_path);

        // 진행 상황 출력
        try stdout.print("{s} → {s}\n", .{ input_path, output_path });

        // 트랜스파일 실행
        transpileFile(allocator, io, input_path, null, output_path, options) catch {
            had_errors = true;
            continue;
        };
        file_count += 1;
    }

    if (file_count == 0 and !had_errors) {
        try stderr.print("zntc: no .ts/.tsx files found in '{s}'\n", .{input_dir});
    } else {
        try stdout.print("\nDone: {d} file(s) transpiled.\n", .{file_count});
    }

    if (had_errors) return error.WalkFailed;
}

pub fn main(init: std.process.Init) !void {
    // Zig 0.16: juicy main — io / args / environ 을 Init 에서 받는다 (libc-free,
    // Zig start 가 채움). args 는 argsAlloc 제거로 Init.minimal.args 이터레이터
    // 수집, env 는 std.process.getEnvVarOwned 제거로 environ Map 스냅샷 캡처로 대체.
    const io = init.io;
    // env 스냅샷을 가장 먼저 등록 — env_flag.Once 가 첫 조회 결과를 캐시하므로
    // 어떤 env 조회보다 앞서야 한다.
    env_flag.captureEnviron(init.environ_map);

    // ReleaseFast/ReleaseSafe: mimalloc 사용 (스레드별 힙, 페이지 캐싱).
    // Debug: GPA 사용 (leak detection, double-free 감지).
    // init.gpa 는 무시하고 기존 allocator 전략 유지 (release 의 mimalloc 성능 특성 보존).
    const is_debug = @import("builtin").mode == .Debug;
    var gpa: if (is_debug) std.heap.DebugAllocator(.{}) else void =
        if (is_debug) .{} else {};
    defer if (is_debug) {
        _ = gpa.deinit();
    };
    const allocator: std.mem.Allocator = if (is_debug) gpa.allocator() else @import("mimalloc.zig").allocator;

    // stdout/stderr writer (0.16: deprecatedWriter 제거 → File.writer(io,buffer)).
    // length-0 buffer(`&.{}`)는 unbuffered — 쓰기 즉시 drain, flush 는 no-op. 따라서
    // std.process.exit 가 defer 를 우회해도 에러 메시지 유실이 없다 (std.debug 도 동일 패턴).
    var stdout_state = std.Io.File.stdout().writer(io, &.{});
    const stdout = &stdout_state.interface;
    var stderr_state = std.Io.File.stderr().writer(io, &.{});
    const stderr = &stderr_state.interface;

    lib.debug_log.initFromEnv(io);
    lib.profile.initFromEnv(io);

    // CLI 인자 파싱 (0.16: argsAlloc 제거 → Init.minimal.args 이터레이터 수집).
    // initAllocator 는 cross-platform (Windows/Wasi 는 내부 파싱 buffer 를 deinit 에서 해제).
    var arg_it = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer arg_it.deinit();
    var args_buf: std.ArrayList([]const u8) = .empty;
    defer args_buf.deinit(allocator);
    while (arg_it.next()) |a| try args_buf.append(allocator, a);
    const args = args_buf.items;

    // Subcommand dispatch — `zntc bench ...` 는 별도 경로.
    if (args.len >= 2 and std.mem.eql(u8, args[1], "bench")) {
        return bench_command.run(allocator, io, args[2..]);
    }
    if (args.len >= 2) {
        if (app_command.parseCommandName(args[1])) |command| {
            var app_opts = app_command.parseArgs(allocator, io, command, args[2..]) catch |err| switch (err) {
                error.HelpRequested => {
                    try usage_cli.printUsage(stdout);
                    return;
                },
                else => {
                    try stderr.print("zntc {s}: argument error: {}\n", .{ @tagName(command), err });
                    stderr.flush() catch {};
                    std.process.exit(1);
                },
            };
            defer app_opts.deinit(allocator);
            return app_command.run(allocator, io, app_opts);
        }
    }

    var opts = try cli_options.parseCliArguments(args, allocator, io) orelse return;
    defer opts.deinit(allocator);

    // --profile / --profile-level / --profile-format 반영 (env 와 합집합).
    if (opts.profile_csv) |csv| lib.profile.addFromCsv(csv);
    if (opts.profile_level) |lvl| {
        if (lib.profile.Level.fromString(lvl)) |parsed| {
            lib.profile.setLevel(parsed);
        } else {
            try stderr.print("zntc: invalid --profile-level='{s}' (expected summary|detailed|per-module|per-pass)\n", .{lvl});
            stderr.flush() catch {};
            std.process.exit(1);
        }
    }
    const profile_report_format: ?lib.profile.Format = if (opts.profile_format) |fmt| blk: {
        if (lib.profile.Format.fromString(fmt)) |parsed| {
            break :blk parsed;
        }
        try stderr.print("zntc: invalid --profile-format='{s}' (expected table|tree|json|csv)\n", .{fmt});
        stderr.flush() catch {};
        std.process.exit(1);
    } else null;

    // 작업 완료 후 profile 수집 결과 출력 (활성 category 가 있을 때만).
    defer {
        if (opts.profile_csv != null or profile_report_format != null) {
            const fmt = profile_report_format orelse .table;
            lib.profile.report(stderr, fmt) catch {};
        }
    }

    // crash report 컨텍스트: panic 시 어떤 입력/타겟에서 죽었는지 알려 준다.
    lib.crash_handler.setContext(.{
        .entry = "cli",
        .input_file = opts.input_file,
        .target = if (opts.es_target) |t| @tagName(t) else null,
    });

    // --test262
    if (opts.is_test262) {
        return standalone_modes.runTest262(allocator, io, opts.test262_dir);
    }

    // --tokenize
    if (opts.is_tokenize) {
        return standalone_modes.runTokenize(allocator, io, opts.input_file);
    }

    // --serve (정적 서버 또는 --bundle과 조합하여 번들 서빙)
    if (opts.is_serve) {
        return standalone_modes.runServe(allocator, io, .{
            .is_bundle = opts.is_bundle,
            .input_file = opts.input_file,
            .port = opts.serve_port,
            .host = opts.serve_host,
            .open = opts.serve_open,
            .proxy = opts.proxy_list.items,
            .cert_path = opts.serve_cert_path,
            .key_path = opts.serve_key_path,
        });
    }

    // tsconfig 로드 + 머지 — 번들/트랜스파일 양쪽에서 사용.
    // 우선순위 (esbuild 동등): --tsconfig-raw inline JSON > --project/--tsconfig-path 경로
    //                       > entry 디렉토리에서 상위로 자동 탐색.
    // 머지 규칙은 `lib.tsconfig_merge.merge` 의 공용 helper — NAPI/transpile 진입점과 일관.
    const entry_dir_start: []const u8 = if (opts.input_file) |inp|
        if (!std.mem.eql(u8, inp, "-")) (std.fs.path.dirname(inp) orelse ".") else "."
    else
        ".";
    var autodiscovered_dir: ?[]const u8 = null;
    defer if (autodiscovered_dir) |d| allocator.free(d);
    // raw 가 있으면 file 기반 path 무시 (paths/baseUrl 도 base 디렉토리 미정이라 skip).
    const tsconfig_dir_for_paths: ?[]const u8 = blk: {
        if (opts.tsconfig_raw != null) break :blk null;
        if (opts.project_path) |pp| break :blk pp;
        autodiscovered_dir = TsConfig.autodiscoverFromEntry(allocator, io, entry_dir_start);
        break :blk autodiscovered_dir;
    };
    var tsconfig: TsConfig = blk: {
        if (opts.tsconfig_raw) |raw| {
            break :blk TsConfig.parseFromString(allocator, raw) catch {
                try stderr.print("zntc: failed to parse --tsconfig-raw\n", .{});
                stderr.flush() catch {};
                std.process.exit(1);
            };
        }
        if (tsconfig_dir_for_paths) |p| {
            break :blk TsConfig.loadFromPath(allocator, io, p) catch TsConfig{};
        }
        break :blk TsConfig{};
    };
    defer tsconfig.deinit();

    // tsconfig `paths` 를 resolver 용 절대 경로 형태로 정규화. main 함수 끝까지 유지해야
    // bundler 가 shallow-copy 한 슬라이스가 dangle 하지 않는다.
    var resolved_paths: lib.config.ResolvedPaths = .{ .entries = &.{}, .owned_strings = &.{} };
    defer resolved_paths.deinit(allocator);

    // ExplicitFlags 빌드 — `?bool` 필드는 직접 forward, `bool` 필드 (sourcemap /
    // emit_decorator_metadata) 는 truthy 일 때만 explicit 으로 전달 (default false 와 explicit false
    // 구분 불가 — 기존 manual merge 의 한계 그대로 보존). jsx_factory/fragment/import_source 의
    // default 문자열 ("React.createElement" 등) 도 explicit 미설정으로 간주.
    const merged = lib.tsconfig_merge.merge(&tsconfig, .{
        .experimental_decorators = opts.experimental_decorators,
        .emit_decorator_metadata = if (opts.emit_decorator_metadata) true else null,
        .use_define_for_class_fields = opts.use_define_for_class_fields,
        .verbatim_module_syntax = opts.verbatim_module_syntax,
        .sourcemap = if (opts.sourcemap) true else null,
        .es_target = opts.es_target,
        .unsupported = if (opts.unsupported.hasAny()) opts.unsupported else null,
        .jsx_runtime = opts.jsx_runtime,
        .jsx_factory = if (std.mem.eql(u8, opts.jsx_factory, "React.createElement")) null else opts.jsx_factory,
        .jsx_fragment = if (std.mem.eql(u8, opts.jsx_fragment, "React.Fragment")) null else opts.jsx_fragment,
        .jsx_import_source = if (std.mem.eql(u8, opts.jsx_import_source, "react")) null else opts.jsx_import_source,
    });
    opts.experimental_decorators = merged.experimental_decorators;
    opts.emit_decorator_metadata = merged.emit_decorator_metadata;
    opts.use_define_for_class_fields = merged.use_define_for_class_fields;
    opts.verbatim_module_syntax = merged.verbatim_module_syntax;
    opts.sourcemap = merged.sourcemap;
    opts.es_target = merged.es_target;
    opts.unsupported = merged.unsupported;
    opts.jsx_runtime = merged.jsx_runtime;
    opts.jsx_factory = merged.jsx_factory;
    opts.jsx_fragment = merged.jsx_fragment;
    opts.jsx_import_source = merged.jsx_import_source;

    // main.zig 만의 inline 분기 — `tsconfig_merge` 가 처리하지 않는 필드 (module_format, output_dir).
    if (opts.module_format == .esm) {
        if (tsconfig.module) |mod| {
            if (std.ascii.eqlIgnoreCase(mod, "commonjs")) {
                opts.module_format = .cjs;
            }
        }
    }
    if (opts.output_dir == null) {
        if (tsconfig.out_dir) |od| {
            opts.output_dir = od;
        }
    }

    // tsconfig `paths` / `baseUrl` → resolver 의 `ts_paths` 로 전달.
    // raw 분기 (tsconfig_dir_for_paths == null) 는 base 디렉토리 미정이라 skip — esbuild 동등.
    // TS 스펙: 다중 candidate + wildcard anywhere + 후보 순차 시도를 resolver 가 수행.
    // 사용자 `--alias` 는 alias 경로로 계속 처리 — 둘은 독립이며 paths 가 먼저 매칭된다.
    if (tsconfig.paths.len > 0) {
        if (tsconfig_dir_for_paths) |dir_str| {
            const dir_for_join = lib.config.tsconfigDirFromPath(dir_str);
            resolved_paths = lib.config.resolveTsPaths(allocator, dir_for_join, &tsconfig) catch |err| blk: {
                try stderr.print("zntc: warning: tsconfig paths resolution failed: {}\n", .{err});
                break :blk lib.config.ResolvedPaths{ .entries = &.{}, .owned_strings = &.{} };
            };
        }
    }

    // --bundle
    if (opts.is_bundle) {
        const entry_file = opts.input_file orelse {
            try stderr.print("zntc: --bundle requires an entry file path\n", .{});
            std.process.exit(1);
        };
        const abs_entry = std.Io.Dir.cwd().realPathFileAlloc(io, entry_file, allocator) catch {
            try stderr.print("zntc: cannot resolve entry file '{s}'\n", .{entry_file});
            std.process.exit(1);
        };
        defer allocator.free(abs_entry);

        // --splitting은 --outdir 필수
        if (opts.splitting and opts.output_dir == null) {
            try stderr.print("zntc: --splitting requires --outdir\n", .{});
            std.process.exit(1);
        }

        // --preserve-modules는 --outdir 필수
        if (opts.preserve_modules and opts.output_dir == null) {
            try stderr.print("zntc: --preserve-modules requires --outdir\n", .{});
            std.process.exit(1);
        }

        // --preserve-modules-root를 절대 경로로 resolve (symlink 해결)
        var resolved_pm_root: ?[]const u8 = null;
        defer if (resolved_pm_root) |r| allocator.free(r);
        if (opts.preserve_modules_root) |pmr| {
            resolved_pm_root = std.Io.Dir.cwd().realPathFileAlloc(io, pmr, allocator) catch {
                try stderr.print("zntc: cannot resolve preserve-modules-root '{s}'\n", .{pmr});
                std.process.exit(1);
            };
            opts.preserve_modules_root = resolved_pm_root;
        }

        // --rn-platform은 --platform=react-native와 함께 사용해야 한다
        if (opts.rn_platform != .none and opts.platform != .react_native) {
            try stderr.print("zntc: --rn-platform requires --platform=react-native\n", .{});
            std.process.exit(1);
        }

        // --platform=react-native 프리셋: 사용자가 명시하지 않은 옵션에 RN 기본값 적용
        if (opts.platform == .react_native and opts.rn_platform == .none and opts.dev) {
            try stderr.print("zntc: warning: --platform=react-native --dev without --rn-platform may cause unresolved platform-specific modules (e.g. DevTools). Use --rn-platform=ios or --rn-platform=android.\n", .{});
        }
        if (opts.platform == .react_native) {
            // Hermes는 ES 버전으로 표현 불가능한 부분 지원 조합이라 target 직교성이 깨진다.
            // platform=react-native면 Hermes 매트릭스가 unsupported를 강제한다.
            if (opts.target_explicit) {
                try stderr.print("zntc: warning: --target ignored when --platform=react-native (Hermes matrix applied)\n", .{});
            }
            opts.unsupported = lib.transformer.TransformOptions.compat.fromHermesPreset();
            opts.es_target = null;
            // RN preset: 사용자가 `--legal-comments=` 명시 안 했으면 .none default (Metro 패턴 정합).
            if (!opts.legal_comments_explicit) opts.legal_comments = .none;

            if (opts.resolve_extensions_list.items.len == 0) {
                // Metro/롤다운 호환: ts → tsx 순서 (sourceExtensions 기본 순서)
                const native_and_base = &[_][]const u8{
                    ".native.ts", ".native.tsx", ".native.js", ".native.jsx",
                    ".ts",        ".tsx",        ".js",        ".jsx",
                    ".json",
                };
                switch (opts.rn_platform) {
                    .ios => {
                        try opts.resolve_extensions_list.appendSlice(allocator, &.{
                            ".ios.ts", ".ios.tsx", ".ios.js", ".ios.jsx",
                        });
                        try opts.resolve_extensions_list.appendSlice(allocator, native_and_base);
                    },
                    .android => {
                        try opts.resolve_extensions_list.appendSlice(allocator, &.{
                            ".android.ts", ".android.tsx", ".android.js", ".android.jsx",
                        });
                        try opts.resolve_extensions_list.appendSlice(allocator, native_and_base);
                    },
                    .none => {
                        try opts.resolve_extensions_list.appendSlice(allocator, &.{ ".ts", ".tsx", ".js", ".jsx", ".json" });
                    },
                }
            }
            // RN main_fields 기본값은 ResolveCache.defaultMainFieldsFor에서 플랫폼별로 적용.
            const rn_preset = lib.bundler.RN_BOOL_PRESET;
            opts.flow = rn_preset.flow;
            opts.jsx_in_js = rn_preset.jsx_in_js;
            opts.configurable_exports = rn_preset.configurable_exports;
            opts.strict_execution_order = rn_preset.strict_execution_order;
            opts.worklet_transform = rn_preset.worklet_transform;
            opts.codegen_transform = rn_preset.codegen_transform;
            // RN: 사용자가 --asset-registry/--no-asset-registry를 명시하지 않았으면 Metro 표준 경로 자동 적용.
            if (opts.asset_registry == null and !opts.asset_registry_explicit_off) {
                opts.asset_registry = lib.bundler.RN_DEFAULT_ASSET_REGISTRY;
            }
            // RN blockList 기본 패턴을 사용자 목록 앞에 prepend (Metro 동작과 동일).
            try opts.block_list.insertSlice(allocator, 0, lib.bundler.RN_DEFAULT_BLOCK_LIST);
            // Metro는 automatic JSX transform 사용 — 사용자가 명시하지 않았으면 자동 설정
            if (opts.jsx_runtime == null) {
                opts.jsx_runtime = .automatic;
            }
            // Metro function map: Hermes 스택트레이스 심볼리케이션 — RN에서 기본 활성화
            opts.sourcemap_function_map = true;

            // RN 에셋 기본 로더: Metro assetExts 호환.
            // 사용자 --loader 오버라이드가 loader_list 앞에 이미 있으므로
            // resolveLoader()에서 사용자 설정이 우선한다.
            const rn_asset_exts = [_][]const u8{
                // 이미지 (Metro defaults.js assetExts 전체)
                ".bmp",   ".gif",  ".jpg",  ".jpeg", ".png",  ".psd",
                ".svg",   ".webp", ".tiff", ".tif",  ".xml",
                // 비디오
                 ".m4v",
                ".mov",   ".mp4",  ".mpeg", ".mpg",  ".webm",
                // 오디오
                ".aac",
                ".aiff",  ".caf",  ".m4a",  ".mp3",  ".wav",
                // 문서
                 ".html",
                ".pdf",   ".yaml", ".yml",
                // 폰트
                 ".otf",  ".ttf",  ".woff",
                ".woff2",
            };
            for (rn_asset_exts) |ext| {
                const user_set = for (opts.loader_list.items) |existing| {
                    if (std.mem.eql(u8, existing.ext, ext)) break true;
                } else false;
                if (!user_set) {
                    try opts.loader_list.append(allocator, .{ .ext = ext, .loader = .file });
                }
            }
        }

        // abs_entry는 outer scope에서 free됨. extras는 entries_list에서 소유.
        var entries_extras: std.ArrayList([]const u8) = .empty;
        defer {
            for (entries_extras.items) |e| allocator.free(e);
            entries_extras.deinit(allocator);
        }
        for (opts.extra_inputs.items) |extra| {
            const abs = std.Io.Dir.cwd().realPathFileAlloc(io, extra, allocator) catch {
                try stderr.print("zntc: cannot resolve entry file '{s}'\n", .{extra});
                std.process.exit(1);
            };
            try entries_extras.append(allocator, abs);
        }
        var entries_list: std.ArrayList([]const u8) = .empty;
        defer entries_list.deinit(allocator);
        try entries_list.append(allocator, abs_entry);
        try entries_list.appendSlice(allocator, entries_extras.items);

        // BundleOptions를 변수로 추출 — 초기 번들과 watch 재번들에서 재사용
        const bundle_opts: BundleOptions = .{
            .entry_points = entries_list.items,
            .format = opts.bundle_format,
            .platform = opts.platform,
            .external = opts.external_list.items,
            .mf = opts.mf, // Module Federation (#3318 P1-1). null=비-MF.
            .minify_whitespace = opts.minify_whitespace,
            .minify_identifiers = opts.minify_identifiers,
            .minify_syntax = opts.minify_syntax,
            .code_splitting = opts.splitting,
            .define = opts.define_list.items,
            .experimental_decorators = opts.experimental_decorators orelse false,
            .emit_decorator_metadata = opts.emit_decorator_metadata,
            .use_define_for_class_fields = opts.use_define_for_class_fields orelse true,
            .verbatim_module_syntax = opts.verbatim_module_syntax orelse false,
            .unsupported = opts.unsupported,
            .conditions = opts.conditions_list.items,
            .preserve_symlinks = opts.preserve_symlinks,
            .resolve_symlink_siblings = opts.resolve_symlink_siblings,
            .disable_hierarchical_lookup = opts.disable_hierarchical_lookup,
            .alias = opts.alias_list.items,
            .ts_paths = resolved_paths.entries,
            .fallback = opts.fallback_list.items,
            .manual_chunks = opts.manual_chunks_list.items,
            .block_list = opts.block_list.items,
            .public_path = opts.public_path orelse "",
            .banner_js = opts.banner_js,
            .footer_js = opts.footer_js,
            .intro_js = opts.intro_js,
            .outro_js = opts.outro_js,
            .global_name = opts.global_name,
            .globals = opts.globals_list.items,
            .out_extension_js = opts.out_extension_js,
            .charset_utf8 = opts.charset_utf8,
            .entry_names = opts.entry_names,
            .chunk_names = opts.chunk_names,
            .asset_names = opts.asset_names,
            .asset_registry = opts.asset_registry,
            .loader_overrides = opts.loader_list.items,
            .metafile = opts.metafile_path != null or opts.analyze,
            .mangle_report_path = opts.mangle_report_path,
            .mf_sign_key_path = opts.mf_sign_key_path,
            .analyze = opts.analyze,
            .legal_comments = opts.legal_comments,
            .inject = opts.inject_list.items,
            .run_before_main = opts.run_before_main_list.items,
            .polyfills = opts.polyfill_list.items,
            .global_identifiers = opts.global_identifier_list.items,
            .keep_names = opts.keep_names,
            .shim_missing_exports = opts.shim_missing_exports,
            .max_threads = opts.max_threads,
            .flow = opts.flow,
            .jsx_in_js = opts.jsx_in_js,
            .configurable_exports = opts.configurable_exports or opts.dev, // HMR: export 재정의 필요
            .strict_execution_order = opts.strict_execution_order,
            .worklet_transform = opts.worklet_transform,
            .codegen_transform = opts.codegen_transform,
            .jsx_runtime = opts.jsx_runtime.?,
            .jsx_factory = opts.jsx_factory,
            .jsx_fragment = opts.jsx_fragment,
            .jsx_import_source = opts.jsx_import_source,
            .resolve_extensions = opts.resolve_extensions_list.items,
            .main_fields = opts.main_fields_list.items,
            .sourcemap = .{
                .enable = opts.sourcemap,
                .mode = opts.sourcemap_mode,
                .debug_ids = opts.sourcemap_debug_ids,
                .function_map = opts.sourcemap_function_map,
                .source_root = opts.source_root,
                .sources_content = opts.sources_content,
                // CLI 빌드는 eager 유지 — lazy 는 NAPI watch 세션 전용 (Issue #1727).
            },
            .output_filename = if (opts.output_file) |of| std.fs.path.basename(of) else "bundle.js",
            .outbase = opts.outbase,
            .packages_external = opts.packages_external,
            .ignore_annotations = opts.ignore_annotations,
            .jsx_side_effects = opts.jsx_side_effects,
            .drop_labels = opts.drop_labels_list.items,
            .drop_console = opts.drop_console,
            .drop_debugger = opts.drop_debugger,
            .output_exports = opts.output_exports,
            .pure = opts.pure_list.items,
            .tsconfig_raw = opts.tsconfig_raw,
            .node_paths = opts.node_paths_list.items,
            .line_limit = opts.line_limit,
            .preserve_modules = opts.preserve_modules,
            .preserve_modules_root = opts.preserve_modules_root,
            .inline_dynamic_imports = opts.inline_dynamic_imports,
            .min_chunk_size = opts.min_chunk_size,
            .dev_mode = opts.dev,
            .react_refresh = opts.dev,
            .root_dir = if (opts.dev or opts.sourcemap) (std.Io.Dir.cwd().realPathFileAlloc(io, ".", allocator) catch null) else null,
        };
        defer if (bundle_opts.root_dir) |rd| allocator.free(rd);

        // watch + dev: 초기 빌드에서도 module_codes 수집 (HMR 캐시 초기화용)
        var initial_opts = bundle_opts;
        if (opts.watch and opts.dev) initial_opts.collect_module_codes = true;
        var bundler = Bundler.init(allocator, initial_opts);
        defer bundler.deinit();

        const result = bundler.bundle(io) catch |err| {
            try stderr.print("zntc: bundle failed: {}\n", .{err});
            std.process.exit(1);
        };
        defer result.deinit(allocator);

        // 진단 메시지 출력 (log-level 필터링)
        if (opts.log_level != .silent) {
            for (result.getDiagnostics()) |d| {
                // log-level에 따른 필터링:
                // error: error만, warning: error+warning, info/debug/verbose: 전부
                const show = switch (opts.log_level) {
                    .silent => false,
                    .@"error" => d.severity == .@"error",
                    .warning => d.severity == .@"error" or d.severity == .warning,
                    .info, .debug, .verbose => true,
                };
                if (!show) continue;

                const sev_str: []const u8 = switch (d.severity) {
                    .@"error" => "error",
                    .warning => "warning",
                    .info => "info",
                };
                try stderr.print("[{s}] {s}: {s}\n", .{ sev_str, d.file_path, d.message });
                // (#3986) suggestion 은 *교정된 이름*이 아니라 unresolved specifier 또는
                // 조언 문장(producer 가 record.specifier / 전체 문장을 넣음)이다. ZNTC 엔
                // typo-detector 가 없어 'did you mean' 프레이밍은 항상 오도였다. app
                // bundle 진단(app/build.zig:719 `hint:`)과 동일하게 중립 hint 로 렌더.
                if (d.suggestion) |s| try stderr.print("  hint: {s}\n", .{s});
            }
        }

        // 에러 진단이 있으면 출력 생략 + exit 1 (watch 모드는 다음 변경 대기).
        // esbuild/rolldown 동작과 동일하게 빌드 실패를 exit code로 신호.
        if (result.hasErrors() and !opts.watch and !opts.is_serve) {
            std.process.exit(1);
        }

        if (opts.output_file) |out_path| {
            try checkAllowOverwrite(allocator, io, stderr, opts.allow_overwrite, abs_entry, out_path);
        }

        // 출력
        // --watch-json 모드에서는 stdout이 NDJSON 전용이므로
        // 상태 메시지와 raw 번들 출력은 억제
        var initial_bytes: usize = 0;
        if (result.outputs) |outputs| {
            // Code splitting: 다중 파일 출력 → --outdir 필수
            const out_dir = opts.output_dir orelse ".";
            std.Io.Dir.cwd().createDirPath(io,out_dir) catch {};
            for (outputs) |o| {
                initial_bytes += o.contents.len;
                const full_path = try std.fs.path.join(allocator, &.{ out_dir, o.path });
                defer allocator.free(full_path);
                // naming 패턴에 디렉토리가 포함된 경우 (예: chunks/[name]-[hash])
                // 하위 디렉토리를 생성해야 함
                if (std.fs.path.dirname(full_path)) |dir| {
                    std.Io.Dir.cwd().createDirPath(io,dir) catch {};
                }
                const file = try std.Io.Dir.cwd().createFile(io,full_path, .{});
                defer file.close(io);
                try file.writeStreamingAll(io,o.contents);
                if (!opts.watch_json) {
                    try stdout.print("  {s} ({d} bytes)\n", .{ full_path, o.contents.len });
                }
            }
            if (!opts.watch_json) {
                try stdout.print("Bundled → {d} chunks in {s}/\n", .{ outputs.len, out_dir });
            }
            try writeAssetOutputs(allocator, io, result.asset_outputs, out_dir);
        } else if (opts.output_file) |out_path| {
            // 단일 파일 출력
            if (std.fs.path.dirname(out_path)) |dir| {
                std.Io.Dir.cwd().createDirPath(io,dir) catch {};
            }
            const file = try std.Io.Dir.cwd().createFile(io,out_path, .{});
            defer file.close(io);
            try file.writeStreamingAll(io,result.output);
            initial_bytes = result.output.len;
            if (!opts.watch_json) {
                try stdout.print("Bundled → {s} ({d} bytes)\n", .{ out_path, result.output.len });
            }
            try writeAssetOutputs(allocator, io, result.asset_outputs, std.fs.path.dirname(out_path) orelse ".");

            // 소스맵 파일 출력
            if (result.sourcemap) |sm_json| {
                const map_path = try std.fmt.allocPrint(allocator, "{s}.map", .{out_path});
                defer allocator.free(map_path);
                std.Io.Dir.cwd().writeFile(io, .{ .sub_path = map_path, .data = sm_json }) catch |err| {
                    try stderr.print("zntc: cannot write '{s}': {}\n", .{ map_path, err });
                };
            }
        } else {
            // --watch-json: stdout은 NDJSON 전용이므로 raw 번들 출력 억제
            if (!opts.watch_json) {
                try stdout.print("{s}", .{result.output});
            }
            initial_bytes = result.output.len;
        }

        // metafile 출력
        if (opts.metafile_path) |mf_path| {
            if (result.metafile_json) |mf| {
                const file = try std.Io.Dir.cwd().createFile(io,mf_path, .{});
                defer file.close(io);
                try file.writeStreamingAll(io,mf);
            }
        }

        // analyze 출력 (stderr)
        if (opts.analyze) {
            if (result.metafile_json) |mf| {
                try stderr.print("\n{s}", .{mf});
            }
        }

        // --watch: 파일 변경 감지 후 재번들
        if (opts.watch) {
            // 증분 빌드용 파싱 캐시 + resolve 캐시 (watch 전체 수명동안 보존)
            const module_store_mod = @import("zntc_lib").bundler.module_store;
            var persistent_store = module_store_mod.PersistentModuleStore.init(allocator);
            defer persistent_store.deinit();

            // dev mode: per-module code 캐시 (HMR diff용)
            var module_code_cache = std.StringHashMap([]const u8).init(allocator);
            defer {
                var it = module_code_cache.iterator();
                while (it.next()) |entry| {
                    allocator.free(entry.key_ptr.*);
                    allocator.free(entry.value_ptr.*);
                }
                module_code_cache.deinit();
            }

            // 초기 빌드의 module_dev_codes로 캐시 초기화 (첫 rebuild부터 HMR diff 가능)
            if (result.module_dev_codes) |codes| {
                for (codes) |c| {
                    const id_copy = allocator.dupe(u8, c.id) catch continue;
                    const code_copy = allocator.dupe(u8, c.code) catch {
                        allocator.free(id_copy);
                        continue;
                    };
                    module_code_cache.put(id_copy, code_copy) catch {
                        allocator.free(id_copy);
                        allocator.free(code_copy);
                    };
                }
            }
            var persistent_resolve_cache = Bundler.initResolveCacheFromOptions(allocator, bundle_opts);
            defer persistent_resolve_cache.deinit();

            // 첫 빌드 결과의 모듈을 store에 저장 (bundler가 이미 deinit된 후이므로 직접 수집)
            // 첫 빌드는 module_store 없이 실행되었으므로 두 번째 빌드부터 캐시가 유효함.

            // 초기 module_paths에서 mtime 수집
            var mtime_map = std.StringHashMap(i128).init(allocator);
            defer {
                var it = mtime_map.keyIterator();
                while (it.next()) |k| allocator.free(k.*);
                mtime_map.deinit();
            }

            // 엔트리 파일도 감시 대상에 추가
            const entry_dupe = try allocator.dupe(u8, abs_entry);
            const entry_mtime = watch_cli.getFileMtime(io, abs_entry) catch 0;
            try mtime_map.put(entry_dupe, entry_mtime);

            if (result.module_paths) |paths| {
                for (paths) |p| watch_cli.upsertMtimePath(allocator, io, &mtime_map, p);
            }

            // --watch-folder: 번들 그래프 밖 루트를 재귀 스캔해 감시 대상에 추가
            for (opts.watch_roots_list.items) |root| {
                watch_cli.collectWatchRootMtimes(
                    allocator,
                    io,
                    root,
                    opts.watch_include_list.items,
                    opts.watch_exclude_list.items,
                    &mtime_map,
                ) catch |err| {
                    try stderr.print("[watch] failed to scan --watch-folder '{s}': {}\n", .{ root, err });
                };
            }

            if (opts.watch_json) {
                try stdout.print("{{\"type\":\"ready\",\"files\":{d},\"bytes\":{d}}}\n", .{ mtime_map.count(), initial_bytes });
            } else {
                try stderr.print("[watch] Watching {d} files for changes...\n", .{mtime_map.count()});
            }

            while (true) {
                // 0.16: std.Thread.sleep 제거 → io.sleep(duration, clock).
                io.sleep(std.Io.Duration.fromMilliseconds(500), .awake) catch {};

                // mtime 변경 확인 + 변경 파일 수집
                var changed = false;
                var changed_files: std.ArrayList([]const u8) = .empty;
                defer changed_files.deinit(allocator);

                var mit = mtime_map.iterator();
                while (mit.next()) |entry| {
                    const current_mtime = watch_cli.getFileMtime(entry.key_ptr.*) catch continue;
                    if (current_mtime != entry.value_ptr.*) {
                        if (!opts.watch_json) {
                            try stderr.print("[watch] Changed: {s}\n", .{entry.key_ptr.*});
                        }
                        entry.value_ptr.* = current_mtime;
                        changed = true;
                        changed_files.append(allocator, entry.key_ptr.*) catch {};
                    }
                }

                if (!changed) continue;

                // 재번들 — 증분 빌드: persistent_store + persistent_resolve_cache 재사용
                // dev mode rebuild에서만 module_codes 수집 (HMR용). 초기 빌드는 false (메모리 절감).
                var incremental_opts = bundle_opts;
                incremental_opts.collect_module_codes = opts.dev;
                incremental_opts.module_store = &persistent_store;
                var rebundler = Bundler.initWithResolveCache(allocator, incremental_opts, &persistent_resolve_cache);
                defer rebundler.deinit(); // resolve_cache는 외부 소유이므로 해제 안 됨

                const rebuild_result = rebundler.bundle(io) catch |err| {
                    if (opts.watch_json) {
                        try stdout.print("{{\"type\":\"rebuild\",\"success\":false,\"error\":\"{}\"}}\n", .{err});
                    } else {
                        try stderr.print("[watch] Bundle failed: {}\n", .{err});
                    }
                    continue;
                };
                defer rebuild_result.deinit(allocator);

                // 출력 파일 다시 쓰기
                var output_bytes: usize = 0;
                if (rebuild_result.outputs) |outputs| {
                    const out_dir = opts.output_dir orelse ".";
                    for (outputs) |o| {
                        output_bytes += o.contents.len;
                        const full_path = std.fs.path.join(allocator, &.{ out_dir, o.path }) catch continue;
                        defer allocator.free(full_path);
                        if (std.fs.path.dirname(full_path)) |dir| std.Io.Dir.cwd().createDirPath(io,dir) catch {};
                        const file = std.Io.Dir.cwd().createFile(io,full_path, .{}) catch continue;
                        defer file.close(io);
                        file.writeStreamingAll(io,o.contents) catch continue;
                    }
                    if (!opts.watch_json) {
                        try stderr.print("[watch] Rebuilt → {d} chunks\n", .{outputs.len});
                    }
                } else if (opts.output_file) |out_path| {
                    output_bytes = rebuild_result.output.len;
                    if (std.fs.path.dirname(out_path)) |dir| std.Io.Dir.cwd().createDirPath(io,dir) catch {};
                    const file = std.Io.Dir.cwd().createFile(io,out_path, .{}) catch continue;
                    defer file.close(io);
                    file.writeStreamingAll(io,rebuild_result.output) catch continue;
                    // rebuild 시에도 소스맵 갱신
                    if (rebuild_result.sourcemap) |sm_json| {
                        const map_path = try std.fmt.allocPrint(allocator, "{s}.map", .{out_path});
                        defer allocator.free(map_path);
                        std.Io.Dir.cwd().writeFile(io, .{ .sub_path = map_path, .data = sm_json }) catch |err| {
                            try stderr.print("zntc: cannot write '{s}': {}\n", .{ map_path, err });
                        };
                    }
                    if (!opts.watch_json) {
                        try stderr.print("[watch] Rebuilt → {s} ({d} bytes)\n", .{ out_path, rebuild_result.output.len });
                    }
                }

                // --watch-json: 재번들 성공 JSON 이벤트를 stdout에 NDJSON으로 출력
                if (opts.watch_json) {
                    try stdout.print("{{\"type\":\"rebuild\",\"success\":true,\"changed\":[", .{});
                    for (changed_files.items, 0..) |path, i| {
                        if (i > 0) try stdout.print(",", .{});
                        try watch_cli.writeJsonString(stdout, path);
                    }
                    try stdout.print("]", .{});

                    // --dev 모드: 캐시 대비 diff → 변경된 모듈만 updates로 출력
                    if (rebuild_result.module_dev_codes) |dev_codes| {
                        // 모듈 ID 집합 비교 — 카운트만 비교하면 false positive 가능 (#951)
                        const graph_changed_flag = blk: {
                            if (dev_codes.len != module_code_cache.count()) break :blk true;
                            for (dev_codes) |dc| {
                                if (!module_code_cache.contains(dc.id)) break :blk true;
                            }
                            break :blk false;
                        };
                        if (graph_changed_flag) {
                            // 모듈 집합 변경 (새 import 추가/삭제) → full reload
                            try stdout.print(",\"graph_changed\":true", .{});
                        } else {
                            // diff: 캐시와 비교하여 변경된 모듈만 수집
                            var changed_count: usize = 0;
                            for (dev_codes) |dc| {
                                const cached = module_code_cache.get(dc.id);
                                if (cached == null or !std.mem.eql(u8, cached.?, dc.code)) {
                                    changed_count += 1;
                                }
                            }

                            if (changed_count > 0) {
                                try stdout.print(",\"updates\":[", .{});
                                var first = true;
                                for (dev_codes) |dc| {
                                    const cached = module_code_cache.get(dc.id);
                                    if (cached == null or !std.mem.eql(u8, cached.?, dc.code)) {
                                        if (!first) try stdout.print(",", .{});
                                        first = false;
                                        try stdout.print("{{\"id\":", .{});
                                        try watch_cli.writeJsonString(stdout, dc.id);
                                        try stdout.print(",\"code\":", .{});
                                        try watch_cli.writeJsonString(stdout, dc.code);
                                        if (dc.map) |m| {
                                            try stdout.print(",\"map\":", .{});
                                            try watch_cli.writeJsonString(stdout, m);
                                        }
                                        try stdout.print("}}", .{});
                                    }
                                }
                                try stdout.print("]", .{});
                            } else {
                                // 코드 변경 없음 → 빈 updates 배열 (번개가 reload하지 않도록)
                                try stdout.print(",\"updates\":[]", .{});
                            }
                        }

                        // 캐시 업데이트
                        {
                            var it = module_code_cache.iterator();
                            while (it.next()) |entry| {
                                allocator.free(entry.key_ptr.*);
                                allocator.free(entry.value_ptr.*);
                            }
                            module_code_cache.clearRetainingCapacity();
                        }
                        for (dev_codes) |dc| {
                            const id_copy = allocator.dupe(u8, dc.id) catch continue;
                            const code_copy = allocator.dupe(u8, dc.code) catch {
                                allocator.free(id_copy);
                                continue;
                            };
                            module_code_cache.put(id_copy, code_copy) catch {
                                allocator.free(id_copy);
                                allocator.free(code_copy);
                            };
                        }
                    } else {
                        // dev_mode가 아닌 경우 기존 modules 필드 유지 (하위 호환)
                        try stdout.print(",\"modules\":[", .{});
                        if (rebuild_result.module_paths) |paths| {
                            for (paths, 0..) |p, i| {
                                if (i > 0) try stdout.print(",", .{});
                                try watch_cli.writeJsonString(stdout, p);
                            }
                        }
                        try stdout.print("]", .{});
                    }

                    try stdout.print(",\"bytes\":{d}}}\n", .{output_bytes});
                }

                // watch 대상 재구축 — 삭제된 모듈 제거 + 새 모듈 추가
                {
                    var kit = mtime_map.keyIterator();
                    while (kit.next()) |k| allocator.free(k.*);
                    mtime_map.clearRetainingCapacity();

                    watch_cli.upsertMtimePath(allocator, io, &mtime_map, abs_entry);
                    if (rebuild_result.module_paths) |paths| {
                        for (paths) |p| watch_cli.upsertMtimePath(allocator, io, &mtime_map, p);
                    }
                }
            }
        }

        return;
    }

    // 입력 경로가 디렉토리인지 확인
    const input_path_str = opts.input_file orelse {
        try usage_cli.printUsage(stdout);
        return;
    };

    // useDefineForClassFields: CLI 미지정이면 tsconfig에서 가져옴 (tsconfig 파싱 필요 — 아래 참고)
    // 주의: tsconfig에 useDefineForClassFields가 없고 experimentalDecorators=true이면
    // TypeScript 4.x 호환을 위해 useDefineForClassFields=false가 기본값.
    // (TS 5.0+에서는 experimentalDecorators 여부와 무관하게 true가 기본)
    // 여기서는 사용자가 명시하지 않은 경우 TS 5.0+ 기본값(true)을 따른다.

    // 트랜스파일 옵션 구성
    const options = TranspileOptions{
        .core = .{
            .module_format = opts.module_format,
            .minify_whitespace = opts.minify_whitespace,
            .minify_identifiers = opts.minify_identifiers,
            .minify_syntax = opts.minify_syntax,
            .drop_console = opts.drop_console,
            .drop_debugger = opts.drop_debugger,
            .sourcemap = opts.sourcemap,
            .sourcemap_debug_ids = opts.sourcemap_debug_ids,
            .ascii_only = opts.ascii_only,
            .quote_style = opts.quote_style,
            .define = opts.define_list.items,
            .platform = opts.platform,
            .use_define_for_class_fields = opts.use_define_for_class_fields orelse true,
            .experimental_decorators = opts.experimental_decorators orelse false,
            .emit_decorator_metadata = opts.emit_decorator_metadata,
            .verbatim_module_syntax = opts.verbatim_module_syntax orelse false,
            .unsupported = opts.unsupported,
            .es_target = opts.es_target,
            .source_root = opts.source_root orelse "",
            .sources_content = opts.sources_content,
            .charset_utf8 = opts.charset_utf8,
            .flow = opts.flow,
            .jsx_in_js = opts.jsx_in_js,
            .jsx_runtime = opts.jsx_runtime.?,
            .jsx_factory = opts.jsx_factory,
            .jsx_fragment = opts.jsx_fragment,
            .jsx_import_source = opts.jsx_import_source,
            .stop_after = opts.core_stop_after,
        },
        .allow_overwrite = opts.allow_overwrite,
    };

    const is_stdin = std.mem.eql(u8, input_path_str, "-");

    if (!is_stdin) {
        // statFile로 디렉토리 여부 판별
        const stat = std.Io.Dir.cwd().statFile(io, input_path_str, .{}) catch |err| {
            // statFile이 실패하면 openDir을 시도하여 디렉토리인지 확인
            // (일부 시스템에서 디렉토리에 statFile이 실패할 수 있음)
            var dir = std.Io.Dir.cwd().openDir(io, input_path_str, .{}) catch {
                // 파일도 디렉토리도 아닌 경우
                try stderr.print("zntc: cannot access '{s}': {}\n", .{ input_path_str, err });
                stderr.flush() catch {};
                std.process.exit(1);
            };
            dir.close(io);
            // 디렉토리 확인됨 — 아래 디렉토리 처리로 이동
            const out_dir = opts.output_dir orelse {
                try stderr.print("zntc: --outdir is required when input is a directory\n", .{});
                stderr.flush() catch {};
                std.process.exit(1);
            };
            walkAndTranspile(allocator, io, input_path_str, out_dir, options) catch std.process.exit(1);
            if (opts.watch) {
                try watch_cli.watchDirectory(transpileFile, allocator, io, input_path_str, out_dir, options, stderr);
            }
            return;
        };

        if (stat.kind == .directory) {
            const out_dir = opts.output_dir orelse {
                try stderr.print("zntc: --outdir is required when input is a directory\n", .{});
                stderr.flush() catch {};
                std.process.exit(1);
            };
            walkAndTranspile(allocator, io, input_path_str, out_dir, options) catch std.process.exit(1);
            if (opts.watch) {
                try watch_cli.watchDirectory(transpileFile, allocator, io, input_path_str, out_dir, options, stderr);
            }
            return;
        }
    }

    // 단일 파일 트랜스파일 (기존 로직)
    const file_path = if (is_stdin) "<stdin>" else input_path_str;

    if (is_stdin) {
        // 0.16: File.readToEndAlloc 제거 → readerStreaming(stdin 은 non-seekable) +
        // Reader.allocRemaining.
        var stdin_buf: [4096]u8 = undefined;
        var stdin_reader = std.Io.File.stdin().readerStreaming(io, &stdin_buf);
        const source = stdin_reader.interface.allocRemaining(allocator, std.Io.Limit.limited(100 * 1024 * 1024)) catch |err| {
            try stderr.print("zntc: cannot read stdin: {}\n", .{err});
            stderr.flush() catch {};
            std.process.exit(1);
        };
        defer allocator.free(source);
        transpileFile(allocator, io, file_path, source, opts.output_file, options) catch std.process.exit(1);
    } else {
        transpileFile(allocator, io, file_path, null, opts.output_file, options) catch std.process.exit(1);
        if (opts.watch) {
            watch_cli.watchFile(transpileFile, allocator, io, file_path, opts.output_file, options, stderr) catch std.process.exit(1);
        }
    }
}

// 에러 코드 프레임 출력 (D012).
// 형식:
//   file.ts:3:5: error: expected ';'
//     3 | const x =
//       |           ^
// printErrorCodeFrame — 삭제됨. diagnostic_renderer.render()로 대체.

test "basic" {
    try std.testing.expect(true);
}
