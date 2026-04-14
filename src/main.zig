const std = @import("std");
const lib = @import("zts_lib");
const Scanner = lib.lexer.Scanner;
const Parser = lib.parser.Parser;
const Diagnostic = lib.diagnostic.Diagnostic;
const SemanticAnalyzer = lib.semantic.SemanticAnalyzer;
const Transformer = lib.transformer.Transformer;
const Codegen = lib.codegen.Codegen;
const TsConfig = lib.config.TsConfig;
const runner = lib.test262.runner;
const Bundler = lib.bundler.Bundler;
const BundleOptions = lib.bundler.BundleOptions;
const emitter = lib.bundler.emitter;
const SubprocessPlugin = lib.bundler.SubprocessPlugin;
const plugin_mod = lib.bundler.plugin;

/// CLI 인자를 파싱한 결과를 담는 구조체.
/// main()에서 개별 변수 30여 개로 흩어져 있던 옵션을 하나로 모은다.
const CliOptions = struct {
    input_file: ?[]const u8 = null,
    /// 추가 entry points (다중 entry CLI 지원). 첫 번째는 input_file로 들어가고
    /// 두 번째 이후가 여기에 누적된다. --bundle + --splitting 또는 --preserve-modules
    /// 에서 다중 entry 번들링에 사용.
    extra_inputs: std.ArrayList([]const u8) = .empty,
    output_file: ?[]const u8 = null,
    output_dir: ?[]const u8 = null,
    minify_whitespace: bool = false,
    minify_identifiers: bool = false,
    minify_syntax: bool = false,
    module_format: lib.codegen.codegen.ModuleFormat = .esm,
    drop_console: bool = false,
    drop_debugger: bool = false,
    sourcemap: bool = false,
    /// Sentry Debug ID (--sourcemap-debug-ids). 소스맵 + JS에 동일 UUID를 삽입.
    sourcemap_debug_ids: bool = false,
    /// Metro x_facebook_sources function map (--sourcemap-function-map).
    /// --platform=react-native 시 자동 활성화.
    sourcemap_function_map: bool = false,
    ascii_only: bool = false,
    quote_style: lib.codegen.QuoteStyle = .double,
    watch: bool = false,
    watch_json: bool = false,
    dev: bool = false,
    is_test262: bool = false,
    is_tokenize: bool = false,
    is_bundle: bool = false,
    is_serve: bool = false,
    serve_port: u16 = 12300,
    serve_host: []const u8 = "localhost",
    serve_open: bool = false,
    splitting: bool = false,
    external_list: std.ArrayList([]const u8) = .empty,
    define_list: std.ArrayList(DefineEntry) = .empty,
    platform: lib.bundler.Platform = .browser,
    bundle_format: lib.bundler.emitter.EmitOptions.Format = .esm,
    bundle_format_explicit: bool = false,
    test262_dir: ?[]const u8 = null,
    project_path: ?[]const u8 = null,
    use_define_for_class_fields: ?bool = null,
    experimental_decorators: ?bool = null,
    emit_decorator_metadata: bool = false,
    unsupported: lib.transformer.TransformOptions.compat.UnsupportedFeatures = .{},
    /// --target에서 파싱한 ES 타겟. top-level await 등 타겟 제한 검증에 사용.
    es_target: ?lib.transformer.TransformOptions.compat.ESTarget = null,
    /// 사용자가 --target을 명시적으로 전달했는지 (RN 프리셋 경고용).
    target_explicit: bool = false,
    conditions_list: std.ArrayList([]const u8) = .empty,
    timing: bool = false,
    preserve_symlinks: bool = false,
    alias_list: std.ArrayList(AliasEntry) = .empty,
    public_path: ?[]const u8 = null,
    banner_js: ?[]const u8 = null,
    footer_js: ?[]const u8 = null,
    global_name: ?[]const u8 = null,
    out_extension_js: ?[]const u8 = null,
    source_root: ?[]const u8 = null,
    sources_content: bool = true,
    log_level: LogLevel = .info,
    charset_utf8: bool = false,
    entry_names: []const u8 = "[name]",
    chunk_names: []const u8 = "[name]-[hash]",
    asset_names: []const u8 = "[name]-[hash]",
    loader_list: std.ArrayList(LoaderOverride) = .empty,
    metafile_path: ?[]const u8 = null,
    analyze: bool = false,
    legal_comments: @import("zts_lib").bundler.types.LegalComments = .default,
    inject_list: std.ArrayList([]const u8) = .empty,
    /// --run-before-main=<path>: 엔트리 모듈 직전에 실행할 모듈 (Metro runBeforeMainModule 호환).
    /// --inject와 동일한 메커니즘으로 엔트리 의존성에 추가하여 먼저 실행.
    run_before_main_list: std.ArrayList([]const u8) = .empty,
    /// --polyfill=<path>: 번들 시작 시 즉시 실행되는 폴리필 스크립트.
    /// 파일 내용을 읽어 IIFE로 감싸서 런타임 헬퍼 앞에 인라인. 모듈 그래프에 포함되지 않음.
    polyfill_list: std.ArrayList([]const u8) = .empty,
    /// --global-identifier=<name>: 예약 전역 식별자. scope hoisting 시 리네이밍 대상.
    global_identifier_list: std.ArrayList([]const u8) = .empty,
    keep_names: bool = false,
    shim_missing_exports: bool = false,
    plugin_paths: std.ArrayList([]const u8) = .empty,
    proxy_list: std.ArrayList(lib.server.DevServer.ProxyRule) = .empty,
    /// Flow 모드 강제 활성화. @flow pragma 없이도 .js/.jsx를 Flow로 파싱한다.
    flow: bool = false,
    /// .js 파일에서도 JSX 파싱 활성화. --platform=react-native 프리셋에서 자동 설정.
    jsx_in_js: bool = false,
    /// Object.defineProperty에 configurable: true 추가 (RN/Hermes 호환).
    /// --platform=react-native에서 자동 활성화.
    configurable_exports: bool = false,
    /// strict execution order: 함수 호이스팅 방지.
    strict_execution_order: bool = false,
    /// Reanimated worklet 변환: "worklet" 디렉티브 함수에 __workletHash/__closure/__initData 주입.
    /// --platform=react-native에서 자동 활성화. --worklet로 수동 제어.
    worklet_transform: bool = false,
    /// JSX 런타임 모드 (--jsx=classic|automatic|automatic-dev, --jsx-dev)
    /// null이면 사용자 미지정 — 플랫폼 프리셋 또는 tsconfig에서 결정.
    jsx_runtime: ?lib.codegen.codegen.JsxRuntime = null,
    /// JSX factory (--jsx-factory=h)
    jsx_factory: []const u8 = "React.createElement",
    /// JSX fragment factory (--jsx-fragment=Fragment)
    jsx_fragment: []const u8 = "React.Fragment",
    /// JSX import source (--jsx-import-source=preact)
    jsx_import_source: []const u8 = "react",
    /// 커스텀 확장자 탐색 순서 (--resolve-extensions=.ios.ts,.ts,...)
    resolve_extensions_list: std.ArrayList([]const u8) = .empty,
    /// package.json 필드 해석 순서 (--main-fields=react-native,browser,main)
    main_fields_list: std.ArrayList([]const u8) = .empty,
    /// React Native 서브 플랫폼 (--rn-platform=ios|android)
    rn_platform: RnPlatform = .none,
    /// --outbase: 엔트리 포인트 공통 기준 경로 (출력 디렉토리 구조 결정)
    outbase: ?[]const u8 = null,
    /// --packages=external: 모든 bare import를 external 처리
    packages_external: bool = false,
    /// --allow-overwrite: 출력 파일이 입력 파일을 덮어쓰는 것을 허용
    allow_overwrite: bool = false,
    /// --log-limit=N: 최대 에러/경고 출력 수 (0=무제한, 기본 0)
    log_limit: u32 = 0,
    /// --line-limit=N: 줄 길이 제한 (0=무제한)
    line_limit: u32 = 0,
    /// --jsx-side-effects: 미사용 JSX 표현식을 tree-shake하지 않음
    jsx_side_effects: bool = false,
    /// --ignore-annotations: @__PURE__, sideEffects 등 어노테이션 무시
    ignore_annotations: bool = false,
    /// --drop-labels=LABEL,...: 지정한 라벨의 labeled statement 제거
    drop_labels_list: std.ArrayList([]const u8) = .empty,
    /// --pure:NAME: 지정한 함수 호출을 순수(pure)로 마킹 (tree-shake 가능)
    pure_list: std.ArrayList([]const u8) = .empty,
    /// --tsconfig-raw=JSON: tsconfig.json을 인라인 JSON으로 오버라이드
    tsconfig_raw: ?[]const u8 = null,
    /// --node-paths=PATH,...: NODE_PATH 추가 탐색 경로
    node_paths_list: std.ArrayList([]const u8) = .empty,
    /// --watch-delay=MS: watch 리빌드 디바운스 지연 (밀리초)
    watch_delay_ms: u32 = 100,
    /// --clean: 빌드 전 출력 디렉토리 정리
    clean: bool = false,
    /// --jobs=N: 병렬 워커 스레드 수 (0=기본값/CPU코어수, 1=단일스레드)
    max_threads: u32 = 0,
    /// --preserve-modules: 모듈 1개 = 출력 파일 1개 (라이브러리 빌드용)
    preserve_modules: bool = false,
    /// --preserve-modules-root=<dir>: 출력 디렉토리 구조의 기준 경로
    preserve_modules_root: ?[]const u8 = null,

    const RnPlatform = enum {
        none,
        ios,
        android,
    };

    const AliasEntry = BundleOptions.AliasEntry;
    const LoaderOverride = @import("zts_lib").bundler.types.LoaderOverride;
    const LoaderEnum = @import("zts_lib").bundler.types.Loader;
    const LegalCommentsEnum = @import("zts_lib").bundler.types.LegalComments;

    const LogLevel = enum {
        silent,
        @"error",
        warning,
        info,
        debug,
        verbose,
    };

    fn deinit(self: *CliOptions, alloc: std.mem.Allocator) void {
        self.extra_inputs.deinit(alloc);
        self.external_list.deinit(alloc);
        self.define_list.deinit(alloc);
        self.conditions_list.deinit(alloc);
        self.alias_list.deinit(alloc);
        self.loader_list.deinit(alloc);
        for (self.inject_list.items) |p| alloc.free(p);
        self.inject_list.deinit(alloc);
        for (self.run_before_main_list.items) |p| alloc.free(p);
        self.run_before_main_list.deinit(alloc);
        for (self.polyfill_list.items) |p| alloc.free(p);
        self.polyfill_list.deinit(alloc);
        self.global_identifier_list.deinit(alloc);
        self.plugin_paths.deinit(alloc);
        self.proxy_list.deinit(alloc);
        self.resolve_extensions_list.deinit(alloc);
        self.main_fields_list.deinit(alloc);
        self.drop_labels_list.deinit(alloc);
        self.pure_list.deinit(alloc);
        self.node_paths_list.deinit(alloc);
    }
};

/// 엔진 타겟 문자열을 파싱. "chrome80,safari14,node16" → UnsupportedFeatures.
fn parseEngineTargets(val: []const u8) ?lib.transformer.TransformOptions.compat.UnsupportedFeatures {
    const compat = lib.transformer.TransformOptions.compat;
    var targets: [16]compat.EngineVersion = undefined;
    var count: usize = 0;
    var iter = std.mem.splitScalar(u8, val, ',');
    while (iter.next()) |part| {
        if (part.len == 0) continue;
        const ev = compat.EngineVersion.fromString(part) orelse return null;
        if (count >= targets.len) return null;
        targets[count] = ev;
        count += 1;
    }
    if (count == 0) return null;
    return compat.unsupportedFeatures(targets[0..count]);
}

/// CLI 인자를 파싱하여 CliOptions를 반환한다.
/// --help 출력이나 파싱 에러로 프로그램을 종료해야 하면 null을 반환한다.
fn parseCliArguments(args: []const []const u8, allocator: std.mem.Allocator) !?CliOptions {
    const stdout = std.fs.File.stdout().deprecatedWriter();
    const stderr = std.fs.File.stderr().deprecatedWriter();

    if (args.len < 2) {
        try printUsage(stdout);
        return null;
    }

    var opts = CliOptions{};

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--test262")) {
            opts.is_test262 = true;
            if (i + 1 < args.len) {
                i += 1;
                opts.test262_dir = args[i];
            }
        } else if (std.mem.eql(u8, arg, "--tokenize")) {
            opts.is_tokenize = true;
        } else if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--out-file")) {
            if (i + 1 < args.len) {
                i += 1;
                opts.output_file = args[i];
            }
        } else if (std.mem.eql(u8, arg, "--outdir")) {
            if (i + 1 < args.len) {
                i += 1;
                opts.output_dir = args[i];
            }
        } else if (std.mem.eql(u8, arg, "--minify")) {
            opts.minify_whitespace = true;
            opts.minify_identifiers = true;
            opts.minify_syntax = true;
        } else if (std.mem.eql(u8, arg, "--minify-whitespace")) {
            opts.minify_whitespace = true;
        } else if (std.mem.eql(u8, arg, "--minify-identifiers")) {
            opts.minify_identifiers = true;
        } else if (std.mem.eql(u8, arg, "--minify-syntax")) {
            opts.minify_syntax = true;
        } else if (std.mem.eql(u8, arg, "--format=cjs")) {
            opts.module_format = .cjs;
            opts.bundle_format = .cjs;
            opts.bundle_format_explicit = true;
        } else if (std.mem.eql(u8, arg, "--format=esm")) {
            opts.module_format = .esm;
            opts.bundle_format = .esm;
            opts.bundle_format_explicit = true;
        } else if (std.mem.eql(u8, arg, "--drop=console")) {
            opts.drop_console = true;
        } else if (std.mem.eql(u8, arg, "--drop=debugger")) {
            opts.drop_debugger = true;
        } else if (std.mem.startsWith(u8, arg, "--define:")) {
            // --define:KEY=VALUE (esbuild 호환 문법)
            const kv = arg["--define:".len..];
            if (std.mem.indexOf(u8, kv, "=")) |eq_pos| {
                try opts.define_list.append(allocator, .{
                    .key = kv[0..eq_pos],
                    .value = kv[eq_pos + 1 ..],
                });
            } else {
                try stderr.print("zts: --define requires KEY=VALUE format: {s}\n", .{arg});
                std.process.exit(1);
            }
        } else if (std.mem.eql(u8, arg, "--ascii-only")) {
            opts.ascii_only = true;
        } else if (std.mem.startsWith(u8, arg, "--quotes=")) {
            const val = arg["--quotes=".len..];
            if (std.mem.eql(u8, val, "double")) {
                opts.quote_style = .double;
            } else if (std.mem.eql(u8, val, "single")) {
                opts.quote_style = .single;
            } else if (std.mem.eql(u8, val, "preserve")) {
                opts.quote_style = .preserve;
            } else {
                try stderr.print("zts: invalid --quotes value: {s} (expected: double, single, preserve)\n", .{val});
                std.process.exit(1);
            }
        } else if (std.mem.eql(u8, arg, "--sourcemap")) {
            opts.sourcemap = true;
        } else if (std.mem.eql(u8, arg, "--sourcemap-debug-ids")) {
            opts.sourcemap_debug_ids = true;
        } else if (std.mem.eql(u8, arg, "--sourcemap-function-map")) {
            opts.sourcemap_function_map = true;
        } else if (std.mem.eql(u8, arg, "--project") or std.mem.eql(u8, arg, "-p")) {
            if (i + 1 < args.len) {
                i += 1;
                opts.project_path = args[i];
            }
        } else if (std.mem.eql(u8, arg, "--watch-json")) {
            opts.watch = true;
            opts.watch_json = true;
        } else if (std.mem.eql(u8, arg, "--dev")) {
            opts.dev = true;
        } else if (std.mem.eql(u8, arg, "--watch") or std.mem.eql(u8, arg, "-w")) {
            opts.watch = true;
        } else if (std.mem.eql(u8, arg, "--flow")) {
            opts.flow = true;
        } else if (std.mem.eql(u8, arg, "--jsx-in-js")) {
            opts.jsx_in_js = true;
        } else if (std.mem.startsWith(u8, arg, "--jsx=")) {
            const val = arg["--jsx=".len..];
            if (std.mem.eql(u8, val, "automatic")) {
                opts.jsx_runtime = .automatic;
            } else if (std.mem.eql(u8, val, "automatic-dev") or std.mem.eql(u8, val, "react-jsxdev")) {
                opts.jsx_runtime = .automatic_dev;
            } else {
                opts.jsx_runtime = .classic;
            }
        } else if (std.mem.eql(u8, arg, "--jsx-dev")) {
            opts.jsx_runtime = .automatic_dev;
        } else if (std.mem.startsWith(u8, arg, "--jsx-factory=")) {
            opts.jsx_factory = arg["--jsx-factory=".len..];
        } else if (std.mem.startsWith(u8, arg, "--jsx-fragment=")) {
            opts.jsx_fragment = arg["--jsx-fragment=".len..];
        } else if (std.mem.startsWith(u8, arg, "--jsx-import-source=")) {
            opts.jsx_import_source = arg["--jsx-import-source=".len..];
        } else if (std.mem.startsWith(u8, arg, "--resolve-extensions=")) {
            const val = arg["--resolve-extensions=".len..];
            var it = std.mem.splitScalar(u8, val, ',');
            while (it.next()) |ext| {
                if (ext.len > 0) try opts.resolve_extensions_list.append(allocator, ext);
            }
        } else if (std.mem.startsWith(u8, arg, "--main-fields=")) {
            const val = arg["--main-fields=".len..];
            var it = std.mem.splitScalar(u8, val, ',');
            while (it.next()) |field| {
                if (field.len > 0) try opts.main_fields_list.append(allocator, field);
            }
        } else if (std.mem.eql(u8, arg, "--timing")) {
            opts.timing = true;
        } else if (std.mem.eql(u8, arg, "--bundle")) {
            opts.is_bundle = true;
        } else if (std.mem.eql(u8, arg, "--serve")) {
            opts.is_serve = true;
        } else if (std.mem.eql(u8, arg, "--port")) {
            if (i + 1 < args.len) {
                i += 1;
                opts.serve_port = std.fmt.parseInt(u16, args[i], 10) catch {
                    try stderr.print("zts: invalid port number: {s}\n", .{args[i]});
                    std.process.exit(1);
                };
            }
        } else if (std.mem.eql(u8, arg, "--host")) {
            // --host 0.0.0.0 또는 --host (값 없으면 0.0.0.0)
            if (i + 1 < args.len and !std.mem.startsWith(u8, args[i + 1], "-")) {
                i += 1;
                opts.serve_host = args[i];
            } else {
                opts.serve_host = "0.0.0.0";
            }
        } else if (std.mem.eql(u8, arg, "--open")) {
            opts.serve_open = true;
        } else if (std.mem.eql(u8, arg, "--proxy")) {
            if (i + 1 < args.len) {
                i += 1;
                const kv = args[i];
                if (std.mem.indexOf(u8, kv, "=")) |eq_pos| {
                    const path_str = kv[0..eq_pos];
                    const target_str = kv[eq_pos + 1 ..];
                    // target에서 host:port 추출 (http://host:port)
                    const after_scheme = if (std.mem.indexOf(u8, target_str, "://")) |s| target_str[s + 3 ..] else target_str;
                    var target_host: []const u8 = after_scheme;
                    var target_port: u16 = 80;
                    if (std.mem.indexOf(u8, after_scheme, ":")) |colon| {
                        target_host = after_scheme[0..colon];
                        target_port = std.fmt.parseInt(u16, after_scheme[colon + 1 ..], 10) catch 80;
                    }
                    try opts.proxy_list.append(allocator, .{
                        .path = path_str,
                        .target = target_str,
                        .target_host = target_host,
                        .target_port = target_port,
                    });
                } else {
                    try stderr.print("zts: --proxy requires PATH=TARGET format (e.g. /api=http://localhost:8080)\n", .{});
                    std.process.exit(1);
                }
            } else {
                try stderr.print("zts: --proxy requires a PATH=TARGET argument\n", .{});
                std.process.exit(1);
            }
        } else if (std.mem.eql(u8, arg, "--splitting")) {
            opts.splitting = true;
        } else if (std.mem.eql(u8, arg, "--preserve-modules")) {
            opts.preserve_modules = true;
        } else if (std.mem.startsWith(u8, arg, "--preserve-modules-root=")) {
            opts.preserve_modules_root = arg["--preserve-modules-root=".len..];
        } else if (std.mem.eql(u8, arg, "--external")) {
            if (i + 1 < args.len) {
                i += 1;
                if (args[i].len > 0) {
                    try opts.external_list.append(allocator, args[i]);
                }
            }
        } else if (std.mem.startsWith(u8, arg, "--external=")) {
            const val = arg["--external=".len..];
            if (val.len > 0) {
                try opts.external_list.append(allocator, val);
            }
        } else if (std.mem.startsWith(u8, arg, "--conditions=")) {
            const val = arg["--conditions=".len..];
            // 쉼표로 분리된 조건 목록 (esbuild 호환: --conditions=production,development)
            var it = std.mem.splitScalar(u8, val, ',');
            while (it.next()) |cond| {
                if (cond.len > 0) try opts.conditions_list.append(allocator, cond);
            }
        } else if (std.mem.eql(u8, arg, "--platform=node")) {
            opts.platform = .node;
        } else if (std.mem.eql(u8, arg, "--platform=browser")) {
            opts.platform = .browser;
        } else if (std.mem.eql(u8, arg, "--platform=neutral")) {
            opts.platform = .neutral;
        } else if (std.mem.eql(u8, arg, "--platform=react-native") or std.mem.eql(u8, arg, "--platform=react_native")) {
            opts.platform = .react_native;
        } else if (std.mem.startsWith(u8, arg, "--rn-platform=")) {
            const val = arg["--rn-platform=".len..];
            opts.rn_platform = std.meta.stringToEnum(CliOptions.RnPlatform, val) orelse {
                try stderr.print("zts: unknown --rn-platform '{s}' (expected: ios, android)\n", .{val});
                std.process.exit(1);
            };
        } else if (std.mem.eql(u8, arg, "--format=iife")) {
            opts.bundle_format = .iife;
            opts.bundle_format_explicit = true;
        } else if (std.mem.eql(u8, arg, "--format=umd")) {
            opts.bundle_format = .umd;
            opts.bundle_format_explicit = true;
        } else if (std.mem.eql(u8, arg, "--format=amd")) {
            opts.bundle_format = .amd;
            opts.bundle_format_explicit = true;
        } else if (std.mem.eql(u8, arg, "--experimental-decorators")) {
            opts.experimental_decorators = true;
        } else if (std.mem.eql(u8, arg, "--use-define-for-class-fields=false")) {
            opts.use_define_for_class_fields = false;
        } else if (std.mem.eql(u8, arg, "--use-define-for-class-fields=true")) {
            opts.use_define_for_class_fields = true;
        } else if (std.mem.startsWith(u8, arg, "--target=")) {
            const val = arg["--target=".len..];
            const compat = lib.transformer.TransformOptions.compat;
            opts.target_explicit = true;
            // ES 타겟 먼저 시도 (es5, es2015, ..., esnext)
            if (std.meta.stringToEnum(compat.ESTarget, val)) |es| {
                opts.unsupported = compat.fromESTarget(es);
                opts.es_target = es;
            } else {
                // 엔진 버전 파싱 (chrome80,safari14,node16)
                opts.unsupported = parseEngineTargets(val) orelse {
                    try stderr.print("zts: unknown target '{s}'\n", .{val});
                    std.process.exit(1);
                };
            }
        } else if (std.mem.eql(u8, arg, "--preserve-symlinks")) {
            opts.preserve_symlinks = true;
        } else if (std.mem.startsWith(u8, arg, "--alias:")) {
            // --alias:react=preact/compat (esbuild 호환)
            const kv = arg["--alias:".len..];
            if (std.mem.indexOf(u8, kv, "=")) |eq_pos| {
                try opts.alias_list.append(allocator, .{
                    .from = kv[0..eq_pos],
                    .to = kv[eq_pos + 1 ..],
                });
            } else {
                try stderr.print("zts: --alias requires FROM=TO format: {s}\n", .{arg});
                std.process.exit(1);
            }
        } else if (std.mem.startsWith(u8, arg, "--public-path=")) {
            opts.public_path = arg["--public-path=".len..];
        } else if (std.mem.startsWith(u8, arg, "--banner:js=")) {
            opts.banner_js = arg["--banner:js=".len..];
        } else if (std.mem.startsWith(u8, arg, "--footer:js=")) {
            opts.footer_js = arg["--footer:js=".len..];
        } else if (std.mem.startsWith(u8, arg, "--global-name=")) {
            opts.global_name = arg["--global-name=".len..];
        } else if (std.mem.startsWith(u8, arg, "--out-extension:")) {
            // --out-extension:.js=.mjs (esbuild 호환)
            const kv = arg["--out-extension:".len..];
            if (std.mem.startsWith(u8, kv, ".js=")) {
                opts.out_extension_js = kv[".js=".len..];
            }
        } else if (std.mem.startsWith(u8, arg, "--source-root=")) {
            opts.source_root = arg["--source-root=".len..];
        } else if (std.mem.eql(u8, arg, "--sources-content=false")) {
            opts.sources_content = false;
        } else if (std.mem.startsWith(u8, arg, "--log-level=")) {
            const val = arg["--log-level=".len..];
            opts.log_level = std.meta.stringToEnum(CliOptions.LogLevel, val) orelse {
                try stderr.print("zts: unknown log-level '{s}' (expected: silent, error, warning, info, debug, verbose)\n", .{val});
                std.process.exit(1);
            };
        } else if (std.mem.eql(u8, arg, "--charset=utf8")) {
            opts.charset_utf8 = true;
        } else if (std.mem.startsWith(u8, arg, "--entry-names=")) {
            opts.entry_names = arg["--entry-names=".len..];
        } else if (std.mem.startsWith(u8, arg, "--chunk-names=")) {
            opts.chunk_names = arg["--chunk-names=".len..];
        } else if (std.mem.startsWith(u8, arg, "--asset-names=")) {
            opts.asset_names = arg["--asset-names=".len..];
        } else if (std.mem.startsWith(u8, arg, "--metafile=")) {
            opts.metafile_path = arg["--metafile=".len..];
        } else if (std.mem.eql(u8, arg, "--metafile")) {
            opts.metafile_path = "meta.json";
        } else if (std.mem.eql(u8, arg, "--analyze")) {
            opts.analyze = true;
        } else if (std.mem.eql(u8, arg, "--keep-names")) {
            opts.keep_names = true;
        } else if (std.mem.eql(u8, arg, "--shim-missing-exports")) {
            opts.shim_missing_exports = true;
        } else if (std.mem.startsWith(u8, arg, "--outbase=")) {
            opts.outbase = arg["--outbase=".len..];
        } else if (std.mem.eql(u8, arg, "--packages=external")) {
            opts.packages_external = true;
        } else if (std.mem.eql(u8, arg, "--allow-overwrite")) {
            opts.allow_overwrite = true;
        } else if (std.mem.startsWith(u8, arg, "--log-limit=")) {
            const val = arg["--log-limit=".len..];
            opts.log_limit = std.fmt.parseInt(u32, val, 10) catch {
                try stderr.print("zts: --log-limit requires a number: {s}\n", .{val});
                std.process.exit(1);
            };
        } else if (std.mem.startsWith(u8, arg, "--line-limit=")) {
            const val = arg["--line-limit=".len..];
            opts.line_limit = std.fmt.parseInt(u32, val, 10) catch {
                try stderr.print("zts: --line-limit requires a number: {s}\n", .{val});
                std.process.exit(1);
            };
        } else if (std.mem.eql(u8, arg, "--jsx-side-effects")) {
            opts.jsx_side_effects = true;
        } else if (std.mem.eql(u8, arg, "--ignore-annotations")) {
            opts.ignore_annotations = true;
        } else if (std.mem.startsWith(u8, arg, "--drop-labels=")) {
            const val = arg["--drop-labels=".len..];
            var label_iter = std.mem.splitScalar(u8, val, ',');
            while (label_iter.next()) |label| {
                if (label.len > 0) try opts.drop_labels_list.append(allocator, label);
            }
        } else if (std.mem.startsWith(u8, arg, "--pure:")) {
            const name = arg["--pure:".len..];
            if (name.len > 0) try opts.pure_list.append(allocator, name);
        } else if (std.mem.startsWith(u8, arg, "--tsconfig-raw=")) {
            opts.tsconfig_raw = arg["--tsconfig-raw=".len..];
        } else if (std.mem.startsWith(u8, arg, "--node-paths=")) {
            const val = arg["--node-paths=".len..];
            var path_iter = std.mem.splitScalar(u8, val, ',');
            while (path_iter.next()) |p| {
                if (p.len > 0) try opts.node_paths_list.append(allocator, p);
            }
        } else if (std.mem.startsWith(u8, arg, "--watch-delay=")) {
            const val = arg["--watch-delay=".len..];
            opts.watch_delay_ms = std.fmt.parseInt(u32, val, 10) catch {
                try stderr.print("zts: --watch-delay requires a number (ms): {s}\n", .{val});
                std.process.exit(1);
            };
        } else if (std.mem.eql(u8, arg, "--clean")) {
            opts.clean = true;
        } else if (std.mem.startsWith(u8, arg, "--jobs=")) {
            const val = arg["--jobs=".len..];
            opts.max_threads = std.fmt.parseInt(u32, val, 10) catch {
                try stderr.print("zts: --jobs requires a number: {s}\n", .{val});
                std.process.exit(1);
            };
        } else if (std.mem.eql(u8, arg, "--plugin")) {
            if (i + 1 < args.len) {
                i += 1;
                try opts.plugin_paths.append(allocator, args[i]);
            } else {
                try stderr.print("zts: --plugin requires a file path\n", .{});
                std.process.exit(1);
            }
        } else if (std.mem.startsWith(u8, arg, "--inject:") or
            std.mem.startsWith(u8, arg, "--run-before-main=") or
            std.mem.startsWith(u8, arg, "--polyfill="))
        {
            // 경로 기반 옵션 공통 처리: 값 추출 → 절대 경로 변환 → 대상 리스트에 추가
            const sep_pos = std.mem.indexOfScalar(u8, arg, ':') orelse std.mem.indexOfScalar(u8, arg, '=').?;
            const option_name = arg[0 .. sep_pos + 1];
            const raw_path = arg[sep_pos + 1 ..];
            const abs = std.fs.cwd().realpathAlloc(allocator, raw_path) catch {
                try stderr.print("zts: cannot resolve {s} path: {s}\n", .{ option_name, raw_path });
                std.process.exit(1);
            };
            const target_list = if (std.mem.startsWith(u8, arg, "--inject:"))
                &opts.inject_list
            else if (std.mem.startsWith(u8, arg, "--run-before-main="))
                &opts.run_before_main_list
            else
                &opts.polyfill_list;
            try target_list.append(allocator, abs);
        } else if (std.mem.startsWith(u8, arg, "--global-identifier=")) {
            const name = arg["--global-identifier=".len..];
            if (name.len > 0) {
                try opts.global_identifier_list.append(allocator, name);
            }
        } else if (std.mem.startsWith(u8, arg, "--legal-comments=")) {
            const val = arg["--legal-comments=".len..];
            opts.legal_comments = CliOptions.LegalCommentsEnum.fromString(val) orelse {
                try stderr.print("zts: unknown legal-comments mode '{s}' (expected: none, inline, eof, linked, external)\n", .{val});
                std.process.exit(1);
            };
            if (opts.legal_comments == .linked or opts.legal_comments == .external) {
                try stderr.print("zts: --legal-comments={s} is not yet fully implemented, falling back to eof behavior\n", .{val});
            }
        } else if (std.mem.startsWith(u8, arg, "--loader:")) {
            // --loader:.png=file (esbuild 호환)
            const kv = arg["--loader:".len..];
            if (std.mem.indexOf(u8, kv, "=")) |eq_pos| {
                const ext_str = kv[0..eq_pos];
                const loader_str = kv[eq_pos + 1 ..];
                if (CliOptions.LoaderEnum.fromString(loader_str)) |loader| {
                    try opts.loader_list.append(allocator, .{
                        .ext = ext_str,
                        .loader = loader,
                    });
                } else {
                    try stderr.print("zts: unknown loader '{s}' (expected: file, dataurl, text, binary, copy, json, css, empty, js)\n", .{loader_str});
                    std.process.exit(1);
                }
            } else {
                try stderr.print("zts: --loader requires .EXT=TYPE format: {s}\n", .{arg});
                std.process.exit(1);
            }
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try printUsage(stdout);
            return null;
        } else if (arg[0] != '-' or (arg.len == 1 and arg[0] == '-')) {
            if (opts.input_file == null) {
                opts.input_file = arg;
            } else {
                try opts.extra_inputs.append(allocator, arg);
            }
        } else {
            try stderr.print("zts: unknown option: {s}\n", .{arg});
            std.process.exit(1);
        }
    }

    // --bundle + --platform=browser + --format 미지정이면 IIFE로 기본 설정 (esbuild 호환).
    // 브라우저 <script> 태그에서 로드할 때 top-level 선언이 글로벌을 오염시키지 않도록
    // 번들 전체를 IIFE로 래핑한다. ESM 출력이 필요하면 --format=esm을 명시해야 한다.
    // react-native는 IIFE 불필요 — Metro/Rollipop도 IIFE 없이 글로벌 스코프에서 실행.
    // preamble과 __esm 래핑이 스코프 격리를 담당.
    if (opts.is_bundle and opts.platform == .browser and !opts.bundle_format_explicit and !opts.preserve_modules) {
        opts.bundle_format = .iife;
    }

    // --bundle + --platform=browser/react-native이면 자동 define (esbuild 호환).
    // 트랜스파일 모드에서는 적용하지 않음 (esbuild와 동일).
    // 사용자가 이미 동일 키를 --define: 로 지정한 경우 덮어쓰지 않음.
    if (opts.is_bundle and opts.platform.isBrowserLike()) {
        var has_node_env = false;
        var has_dev = false;
        for (opts.define_list.items) |d| {
            if (std.mem.eql(u8, d.key, "process.env.NODE_ENV")) has_node_env = true;
            if (std.mem.eql(u8, d.key, "__DEV__")) has_dev = true;
        }
        const is_dev = opts.dev or opts.is_serve or opts.watch;
        if (!has_node_env) {
            try opts.define_list.append(allocator, .{
                .key = "process.env.NODE_ENV",
                .value = if (is_dev) "\"development\"" else "\"production\"",
            });
        }
        // RN만: __DEV__를 자동 define (Metro 호환).
        if (!has_dev and opts.platform == .react_native) {
            try opts.define_list.append(allocator, .{
                .key = "__DEV__",
                .value = if (is_dev) "true" else "false",
            });
        }
    }

    return opts;
}

const DefineEntry = lib.transformer.DefineEntry;

/// CLI에서 파싱한 옵션들을 transpileFile / walkAndTranspile에 전달한다.
const TranspileOptions = struct {
    /// 핵심 트랜스파일 옵션 (transpile.zig에 직접 전달)
    core: lib.transpile.TranspileOptions = .{},
    /// CLI 전용: 파이프라인 단계별 소요시간 출력 (--timing)
    timing: bool = false,
    /// --allow-overwrite: 출력 파일이 입력 파일을 덮어쓰는 것을 허용
    allow_overwrite: bool = false,
};

/// transpile.zig 에러 콜백: 파서/시맨틱 에러 발생 시 코드 프레임 출력
fn printErrors(source: []const u8, file_path: []const u8, scanner: *const Scanner, errors: []const lib.diagnostic.Diagnostic) void {
    const stderr_file = std.fs.File.stderr();
    const stderr = stderr_file.deprecatedWriter();
    const use_color = lib.ansi_mod.isTty(stderr_file);
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
    file_path: []const u8,
    source_override: ?[]const u8,
    output_path: ?[]const u8,
    options: TranspileOptions,
) !void {
    const transpile_mod = lib.transpile;
    const stderr = std.fs.File.stderr().deprecatedWriter();
    const stdout = std.fs.File.stdout().deprecatedWriter();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    // 타이밍 측정용 타이머 (--timing일 때만 시작)
    var timer: ?std.time.Timer = if (options.timing) std.time.Timer.start() catch null else null;
    var t_read: u64 = 0;
    var t_scan: u64 = 0;
    var t_transpile: u64 = 0;

    // 소스 읽기
    const source = source_override orelse blk: {
        break :blk std.fs.cwd().readFileAlloc(arena_alloc, file_path, 100 * 1024 * 1024) catch |err| {
            try stderr.print("zts: cannot read '{s}': {}\n", .{ file_path, err });
            return error.TranspileFailed;
        };
    };
    if (timer) |*t| {
        t_read = t.read();
        t.reset();
    }

    // --timing: scan-only 패스로 순수 토큰화 시간 측정
    if (options.timing) {
        if (timer) |*t| t.reset();
        var scan_only = try Scanner.init(arena_alloc, source);
        const ext = std.fs.path.extension(file_path);
        if (std.mem.eql(u8, ext, ".mts") or std.mem.eql(u8, ext, ".mjs") or
            std.mem.eql(u8, ext, ".ts") or std.mem.eql(u8, ext, ".tsx") or
            std.mem.eql(u8, ext, ".cts"))
        {
            scan_only.is_module = true;
        }
        try scan_only.next();
        while (scan_only.token.kind != .eof) {
            try scan_only.next();
        }
        if (timer) |*t| {
            t_scan = t.read();
            t.reset();
        }
    }

    // 핵심 트랜스파일 — transpile.zig에 위임 (에러 시 코드 프레임 출력 콜백)
    var result = transpile_mod.transpileWithCallback(allocator, source, file_path, options.core, &printErrors) catch |err| {
        // 콜백에서 이미 상세 에러를 출력했으므로, 파싱/시맨틱 에러는 추가 메시지 불필요
        switch (err) {
            error.ParseError, error.SemanticError => {},
            else => {
                try stderr.print("zts: {s}: {}\n", .{ file_path, err });
            },
        }
        return error.TranspileFailed;
    };
    defer result.deinit(allocator);

    if (timer) |*t| {
        t_transpile = t.read();
        t.reset();
    }

    // --allow-overwrite 체크
    if (!options.allow_overwrite) {
        if (output_path) |out_path| {
            const in_abs = std.fs.cwd().realpathAlloc(arena_alloc, file_path) catch file_path;
            const out_abs = std.fs.cwd().realpathAlloc(arena_alloc, out_path) catch out_path;
            if (std.mem.eql(u8, in_abs, out_abs)) {
                try stderr.print("zts: output file '{s}' would overwrite input file (use --allow-overwrite to permit)\n", .{out_path});
                return error.TranspileFailed;
            }
        }
    }

    // 출력
    if (output_path) |out_path| {
        if (std.fs.path.dirname(out_path)) |dir| {
            std.fs.cwd().makePath(dir) catch |err| {
                try stderr.print("zts: cannot create directory '{s}': {}\n", .{ dir, err });
                return error.TranspileFailed;
            };
        }
        std.fs.cwd().writeFile(.{ .sub_path = out_path, .data = result.code }) catch |err| {
            try stderr.print("zts: cannot write '{s}': {}\n", .{ out_path, err });
            return error.TranspileFailed;
        };
        if (result.sourcemap) |sm_json| {
            const map_path = try std.fmt.allocPrint(arena_alloc, "{s}.map", .{out_path});
            std.fs.cwd().writeFile(.{ .sub_path = map_path, .data = sm_json }) catch |err| {
                try stderr.print("zts: cannot write '{s}': {}\n", .{ map_path, err });
            };
        }
    } else {
        try stdout.writeAll(result.code);
    }

    // 시맨틱 에러가 있었으면 exit 1 (tsc 호환: output은 생성하되 에러 코드 반환)
    if (result.has_errors) return error.TranspileFailed;

    // --timing
    if (options.timing) {
        const total = t_read + t_transpile;
        const f_scan = @as(f64, @floatFromInt(t_scan)) / 1_000_000.0;
        const f_transpile = @as(f64, @floatFromInt(t_transpile)) / 1_000_000.0;
        try stderr.print(
            \\
            \\  Timing for '{s}' ({d} bytes):
            \\    read:      {d:.3} ms
            \\    scan:      {d:.3} ms  (standalone)
            \\    transpile: {d:.3} ms  (parse+semantic+transform+codegen)
            \\    ─────────────────
            \\    total:     {d:.3} ms  (excludes standalone scan)
            \\
        , .{
            file_path,
            source.len,
            @as(f64, @floatFromInt(t_read)) / 1_000_000.0,
            f_scan,
            f_transpile,
            @as(f64, @floatFromInt(total)) / 1_000_000.0,
        });
    }
}

/// 디렉토리를 재귀 순회하며 .ts/.tsx 파일을 찾아 트랜스파일한다.
/// Asset 파일(file/copy 로더)을 출력 디렉토리에 쓴다.
fn writeAssetOutputs(allocator: std.mem.Allocator, asset_outputs: ?[]const emitter.OutputFile, base_dir: []const u8) !void {
    const assets = asset_outputs orelse return;
    for (assets) |a| {
        const asset_path = try std.fs.path.join(allocator, &.{ base_dir, a.path });
        defer allocator.free(asset_path);
        if (std.fs.path.dirname(asset_path)) |dir| {
            std.fs.cwd().makePath(dir) catch {};
        }
        const af = try std.fs.cwd().createFile(asset_path, .{});
        defer af.close();
        try af.writeAll(a.contents);
    }
}

/// input_dir: 입력 디렉토리 경로, output_dir: 출력 디렉토리 경로
/// .d.ts 파일과 node_modules 디렉토리는 건너뛴다.
fn walkAndTranspile(
    allocator: std.mem.Allocator,
    input_dir: []const u8,
    output_dir: []const u8,
    options: TranspileOptions,
) !void {
    const stderr = std.fs.File.stderr().deprecatedWriter();
    const stdout = std.fs.File.stdout().deprecatedWriter();

    // 입력 디렉토리 열기
    var dir = std.fs.cwd().openDir(input_dir, .{ .iterate = true }) catch |err| {
        try stderr.print("zts: cannot open directory '{s}': {}\n", .{ input_dir, err });
        return error.WalkFailed;
    };
    defer dir.close();

    // 재귀적으로 파일 순회
    var walker = dir.walk(allocator) catch |err| {
        try stderr.print("zts: cannot walk directory '{s}': {}\n", .{ input_dir, err });
        return error.WalkFailed;
    };
    defer walker.deinit();

    var file_count: usize = 0;
    var had_errors = false;

    while (walker.next() catch |err| {
        try stderr.print("zts: error walking directory: {}\n", .{err});
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
        transpileFile(allocator, input_path, null, output_path, options) catch {
            had_errors = true;
            continue;
        };
        file_count += 1;
    }

    if (file_count == 0 and !had_errors) {
        try stderr.print("zts: no .ts/.tsx files found in '{s}'\n", .{input_dir});
    } else {
        try stdout.print("\nDone: {d} file(s) transpiled.\n", .{file_count});
    }

    if (had_errors) return error.WalkFailed;
}

pub fn main() !void {
    const stdout = std.fs.File.stdout().deprecatedWriter();
    const stderr = std.fs.File.stderr().deprecatedWriter();
    // ReleaseFast/ReleaseSafe: mimalloc 사용 (스레드별 힙, 페이지 캐싱).
    // Debug: GPA 사용 (leak detection, double-free 감지).
    const is_debug = @import("builtin").mode == .Debug;
    var gpa: if (is_debug) std.heap.GeneralPurposeAllocator(.{}) else void =
        if (is_debug) .{} else {};
    defer if (is_debug) {
        _ = gpa.deinit();
    };
    const allocator: std.mem.Allocator = if (is_debug) gpa.allocator() else @import("mimalloc.zig").allocator;

    // CLI 인자 파싱
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var opts = try parseCliArguments(args, allocator) orelse return;
    defer opts.deinit(allocator);

    // zts.config.{js,ts,mjs,mts,cjs,cts} 자동 탐색 (--plugin 미지정 시)
    if (opts.plugin_paths.items.len == 0 and (opts.is_bundle or opts.is_serve)) {
        const config_names = [_][]const u8{
            "zts.config.ts",  "zts.config.js",  "zts.config.mts",
            "zts.config.mjs", "zts.config.cts", "zts.config.cjs",
        };
        for (&config_names) |name| {
            if (std.fs.cwd().statFile(name)) |_| {
                try opts.plugin_paths.append(allocator, name);
                try stderr.print("[zts] Using config: {s}\n", .{name});
                break;
            } else |_| {}
        }
    }

    // --test262
    if (opts.is_test262) {
        const dir_path = opts.test262_dir orelse {
            try stderr.print("zts: --test262 requires a directory path\n", .{});
            std.process.exit(1);
        };
        const abs_path = try std.fs.cwd().realpathAlloc(allocator, dir_path);
        defer allocator.free(abs_path);
        try stdout.print("Running Test262: {s}\n", .{abs_path});
        const summary = try runner.runDirectory(allocator, abs_path, false);
        try summary.print(stdout);
        return;
    }

    // --tokenize
    if (opts.is_tokenize) {
        const file_path = opts.input_file orelse {
            try stderr.print("zts: --tokenize requires a file path\n", .{});
            std.process.exit(1);
        };
        const source = try std.fs.cwd().readFileAlloc(allocator, file_path, 10 * 1024 * 1024);
        defer allocator.free(source);

        var scanner = try Scanner.init(allocator, source);
        defer scanner.deinit();

        while (true) {
            try scanner.next();
            const lc = scanner.getLineColumn(scanner.token.span.start);
            try stdout.print("{d}:{d}\t{s}\t\"{s}\"\n", .{
                lc.line + 1,
                lc.column + 1,
                scanner.token.kind.symbol(),
                scanner.tokenText(),
            });
            if (scanner.token.kind == .eof) break;
        }
        return;
    }

    // --serve (정적 서버 또는 --bundle과 조합하여 번들 서빙)
    if (opts.is_serve) {
        // --serve --bundle entry.ts → entry의 디렉토리를 root로 사용
        const serve_dir: []const u8 = if (opts.is_bundle and opts.input_file != null) blk: {
            break :blk std.fs.path.dirname(opts.input_file.?) orelse ".";
        } else opts.input_file orelse ".";

        const entry: ?[]const u8 = if (opts.is_bundle) blk: {
            break :blk opts.input_file orelse {
                try stderr.print("zts: --serve --bundle requires an entry file path\n", .{});
                std.process.exit(1);
            };
        } else null;

        // Subprocess 플러그인 spawn (--serve + --plugin)
        var serve_subprocess_list: std.ArrayList(*SubprocessPlugin) = .empty;
        defer {
            for (serve_subprocess_list.items) |sp| sp.shutdown();
            serve_subprocess_list.deinit(allocator);
        }
        var serve_plugin_list: std.ArrayList(plugin_mod.Plugin) = .empty;
        defer serve_plugin_list.deinit(allocator);

        for (opts.plugin_paths.items) |config_path| {
            const sp = SubprocessPlugin.spawn(allocator, config_path) catch |err| {
                try stderr.print("zts: plugin '{s}' spawn failed: {}\n", .{ config_path, err });
                std.process.exit(1);
            };
            try serve_subprocess_list.append(allocator, sp);
            try serve_plugin_list.append(allocator, sp.toPlugin());
        }

        // config 파일의 server 옵션 적용 (CLI가 우선)
        if (serve_subprocess_list.items.len > 0) {
            const sp = serve_subprocess_list.items[0];
            if (sp.config.server) |srv| {
                if (opts.serve_port == 12300) { // CLI 기본값이면 config 사용
                    if (srv.port) |p| opts.serve_port = p;
                }
                if (std.mem.eql(u8, opts.serve_host, "localhost")) {
                    if (srv.host) |h| opts.serve_host = h;
                }
                if (!opts.serve_open) {
                    if (srv.open) |o| opts.serve_open = o;
                }
            }
        }

        var dev_server = lib.server.DevServer.init(allocator, .{
            .root_dir = serve_dir,
            .port = opts.serve_port,
            .host = opts.serve_host,
            .open = opts.serve_open,
            .entry_point = entry,
            .plugins = serve_plugin_list.items,
            .proxy = opts.proxy_list.items,
        }) catch |err| {
            try stderr.print("zts: failed to start dev server: {}\n", .{err});
            std.process.exit(1);
        };
        defer dev_server.deinit();
        dev_server.start() catch |err| {
            try stderr.print("zts: dev server failed: {}\n", .{err});
            std.process.exit(1);
        };
        return;
    }

    // tsconfig.json 로드 — 번들/트랜스파일 양쪽에서 사용.
    // 우선순위: --project 경로 > 입력 파일의 부모 디렉토리 > CWD
    const tsconfig_dir_early: []const u8 = if (opts.project_path) |pp|
        pp
    else if (opts.input_file) |inp|
        if (!std.mem.eql(u8, inp, "-")) (std.fs.path.dirname(inp) orelse ".") else "."
    else
        ".";
    var tsconfig = TsConfig.load(allocator, tsconfig_dir_early) catch TsConfig{};
    defer tsconfig.deinit();

    // tsconfig 값 적용 — CLI 옵션이 우선, 미지정 옵션만 tsconfig에서 가져옴
    if (opts.module_format == .esm) {
        if (tsconfig.module) |mod| {
            if (std.ascii.eqlIgnoreCase(mod, "commonjs")) {
                opts.module_format = .cjs;
            }
        }
    }
    if (!opts.sourcemap and tsconfig.source_map) {
        opts.sourcemap = true;
    }
    if (opts.output_dir == null) {
        if (tsconfig.out_dir) |od| {
            opts.output_dir = od;
        }
    }
    if (opts.experimental_decorators == null and tsconfig.experimental_decorators) {
        opts.experimental_decorators = true;
    }
    // emitDecoratorMetadata는 experimentalDecorators가 활성화된 경우에만 유효
    if (tsconfig.emit_decorator_metadata and (opts.experimental_decorators orelse false)) {
        opts.emit_decorator_metadata = true;
    }
    // JSX: CLI/플랫폼 프리셋이 미지정이면 tsconfig에서 가져옴
    if (opts.jsx_runtime == null) {
        if (tsconfig.jsx) |jsx_mode| {
            if (std.mem.eql(u8, jsx_mode, "react-jsx") or std.mem.eql(u8, jsx_mode, "react-jsxdev")) {
                opts.jsx_runtime = if (std.mem.eql(u8, jsx_mode, "react-jsxdev")) .automatic_dev else .automatic;
            }
        }
    }
    // JSX 최종 fallback: CLI/플랫폼/tsconfig 어디서도 지정하지 않으면 classic
    if (opts.jsx_runtime == null) {
        opts.jsx_runtime = .classic;
    }
    if (std.mem.eql(u8, opts.jsx_factory, "React.createElement")) {
        opts.jsx_factory = tsconfig.jsx_factory;
    }
    if (std.mem.eql(u8, opts.jsx_fragment, "React.Fragment")) {
        opts.jsx_fragment = tsconfig.jsx_fragment_factory;
    }
    if (std.mem.eql(u8, opts.jsx_import_source, "react")) {
        opts.jsx_import_source = tsconfig.jsx_import_source;
    }

    // --bundle
    if (opts.is_bundle) {
        const entry_file = opts.input_file orelse {
            try stderr.print("zts: --bundle requires an entry file path\n", .{});
            std.process.exit(1);
        };
        const abs_entry = std.fs.cwd().realpathAlloc(allocator, entry_file) catch {
            try stderr.print("zts: cannot resolve entry file '{s}'\n", .{entry_file});
            std.process.exit(1);
        };
        defer allocator.free(abs_entry);

        // --splitting은 --outdir 필수
        if (opts.splitting and opts.output_dir == null) {
            try stderr.print("zts: --splitting requires --outdir\n", .{});
            std.process.exit(1);
        }

        // --preserve-modules는 --outdir 필수
        if (opts.preserve_modules and opts.output_dir == null) {
            try stderr.print("zts: --preserve-modules requires --outdir\n", .{});
            std.process.exit(1);
        }

        // --preserve-modules-root를 절대 경로로 resolve (symlink 해결)
        var resolved_pm_root: ?[]const u8 = null;
        defer if (resolved_pm_root) |r| allocator.free(r);
        if (opts.preserve_modules_root) |pmr| {
            resolved_pm_root = std.fs.cwd().realpathAlloc(allocator, pmr) catch {
                try stderr.print("zts: cannot resolve preserve-modules-root '{s}'\n", .{pmr});
                std.process.exit(1);
            };
            opts.preserve_modules_root = resolved_pm_root;
        }

        // Subprocess 플러그인 spawn (--plugin 옵션이 있을 때)
        var subprocess_list: std.ArrayList(*SubprocessPlugin) = .empty;
        defer {
            for (subprocess_list.items) |sp| sp.shutdown();
            subprocess_list.deinit(allocator);
        }
        var plugin_list: std.ArrayList(plugin_mod.Plugin) = .empty;
        defer plugin_list.deinit(allocator);

        for (opts.plugin_paths.items) |config_path| {
            const sp = SubprocessPlugin.spawn(allocator, config_path) catch {
                try stderr.print("zts: failed to load plugin '{s}'\n", .{config_path});
                std.process.exit(1);
            };
            try subprocess_list.append(allocator, sp);
            try plugin_list.append(allocator, sp.toPlugin());
        }

        // --rn-platform은 --platform=react-native와 함께 사용해야 한다
        if (opts.rn_platform != .none and opts.platform != .react_native) {
            try stderr.print("zts: --rn-platform requires --platform=react-native\n", .{});
            std.process.exit(1);
        }

        // --platform=react-native 프리셋: 사용자가 명시하지 않은 옵션에 RN 기본값 적용
        if (opts.platform == .react_native and opts.rn_platform == .none and opts.dev) {
            try stderr.print("zts: warning: --platform=react-native --dev without --rn-platform may cause unresolved platform-specific modules (e.g. DevTools). Use --rn-platform=ios or --rn-platform=android.\n", .{});
        }
        if (opts.platform == .react_native) {
            // Hermes는 ES 버전으로 표현 불가능한 부분 지원 조합이라 target 직교성이 깨진다.
            // platform=react-native면 Hermes 매트릭스가 unsupported를 강제한다.
            if (opts.target_explicit) {
                try stderr.print("zts: warning: --target ignored when --platform=react-native (Hermes matrix applied)\n", .{});
            }
            opts.unsupported = lib.transformer.TransformOptions.compat.fromHermesPreset();
            opts.es_target = null;

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
            if (opts.main_fields_list.items.len == 0) {
                try opts.main_fields_list.appendSlice(allocator, &.{ "react-native", "browser", "module", "main" });
            }
            const rn_preset = lib.bundler.RN_BOOL_PRESET;
            opts.flow = rn_preset.flow;
            opts.jsx_in_js = rn_preset.jsx_in_js;
            opts.configurable_exports = rn_preset.configurable_exports;
            opts.strict_execution_order = rn_preset.strict_execution_order;
            opts.worklet_transform = rn_preset.worklet_transform;
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
            const abs = std.fs.cwd().realpathAlloc(allocator, extra) catch {
                try stderr.print("zts: cannot resolve entry file '{s}'\n", .{extra});
                std.process.exit(1);
            };
            try entries_extras.append(allocator, abs);
        }
        var entries_list: std.ArrayList([]const u8) = .empty;
        defer entries_list.deinit(allocator);
        try entries_list.append(allocator, abs_entry);
        try entries_list.appendSlice(allocator, entries_extras.items);

        // BundleOptions를 변수로 추출 — 초기 번들과 watch 재번들에서 재사용
        var bundle_opts: BundleOptions = .{
            .entry_points = entries_list.items,
            .format = opts.bundle_format,
            .platform = opts.platform,
            .external = opts.external_list.items,
            .minify_whitespace = opts.minify_whitespace,
            .minify_identifiers = opts.minify_identifiers,
            .minify_syntax = opts.minify_syntax,
            .code_splitting = opts.splitting,
            .define = opts.define_list.items,
            .experimental_decorators = opts.experimental_decorators orelse false,
            .emit_decorator_metadata = opts.emit_decorator_metadata,
            .use_define_for_class_fields = opts.use_define_for_class_fields orelse true,
            .unsupported = opts.unsupported,
            .conditions = opts.conditions_list.items,
            .timing = opts.timing,
            .preserve_symlinks = opts.preserve_symlinks,
            .alias = opts.alias_list.items,
            .public_path = opts.public_path orelse "",
            .banner_js = opts.banner_js,
            .footer_js = opts.footer_js,
            .global_name = opts.global_name,
            .out_extension_js = opts.out_extension_js,
            .source_root = opts.source_root,
            .sources_content = opts.sources_content,
            .charset_utf8 = opts.charset_utf8,
            .entry_names = opts.entry_names,
            .chunk_names = opts.chunk_names,
            .asset_names = opts.asset_names,
            .loader_overrides = opts.loader_list.items,
            .metafile = opts.metafile_path != null or opts.analyze,
            .analyze = opts.analyze,
            .legal_comments = opts.legal_comments,
            .inject = opts.inject_list.items,
            .run_before_main = opts.run_before_main_list.items,
            .polyfills = opts.polyfill_list.items,
            .global_identifiers = opts.global_identifier_list.items,
            .keep_names = opts.keep_names,
            .shim_missing_exports = opts.shim_missing_exports,
            .plugins = plugin_list.items,
            .max_threads = opts.max_threads,
            .flow = opts.flow,
            .jsx_in_js = opts.jsx_in_js,
            .configurable_exports = opts.configurable_exports or opts.dev, // HMR: export 재정의 필요
            .strict_execution_order = opts.strict_execution_order,
            .worklet_transform = opts.worklet_transform,
            .jsx_runtime = opts.jsx_runtime.?,
            .jsx_factory = opts.jsx_factory,
            .jsx_fragment = opts.jsx_fragment,
            .jsx_import_source = opts.jsx_import_source,
            .resolve_extensions = opts.resolve_extensions_list.items,
            .main_fields = opts.main_fields_list.items,
            .sourcemap = opts.sourcemap,
            .sourcemap_debug_ids = opts.sourcemap_debug_ids,
            .sourcemap_function_map = opts.sourcemap_function_map,
            .output_filename = if (opts.output_file) |of| std.fs.path.basename(of) else "bundle.js",
            .outbase = opts.outbase,
            .packages_external = opts.packages_external,
            .ignore_annotations = opts.ignore_annotations,
            .jsx_side_effects = opts.jsx_side_effects,
            .drop_labels = opts.drop_labels_list.items,
            .pure = opts.pure_list.items,
            .tsconfig_raw = opts.tsconfig_raw,
            .node_paths = opts.node_paths_list.items,
            .line_limit = opts.line_limit,
            .preserve_modules = opts.preserve_modules,
            .preserve_modules_root = opts.preserve_modules_root,
            .dev_mode = opts.dev,
            .react_refresh = opts.dev,
            .root_dir = if (opts.dev or opts.sourcemap) (std.fs.cwd().realpathAlloc(allocator, ".") catch null) else null,
        };
        defer if (bundle_opts.root_dir) |rd| allocator.free(rd);

        // config 파일 옵션 적용 — 첫 번째 플러그인의 config만 사용 (CLI가 우선)
        if (subprocess_list.items.len > 0) {
            const sp = subprocess_list.items[0];
            // loader
            if (opts.loader_list.items.len == 0) {
                const config_loaders = sp.getLoaderOverrides(allocator) catch &.{};
                if (config_loaders.len > 0) bundle_opts.loader_overrides = config_loaders;
            }
            // external
            if (opts.external_list.items.len == 0) {
                const config_ext = sp.getExternals();
                if (config_ext.len > 0) bundle_opts.external = config_ext;
            }
            // define: config의 define을 CLI/자동 define에 병합 (중복 키는 CLI 우선)
            {
                const config_defines = sp.getDefines(allocator) catch &.{};
                for (config_defines) |cd| {
                    var exists = false;
                    for (opts.define_list.items) |d| {
                        if (std.mem.eql(u8, d.key, cd.key)) {
                            exists = true;
                            break;
                        }
                    }
                    if (!exists) try opts.define_list.append(allocator, cd);
                }
                bundle_opts.define = opts.define_list.items;
            }
            // alias (기존 미적용 → 수정)
            if (opts.alias_list.items.len == 0) {
                const config_aliases = sp.getAliases(allocator) catch &.{};
                if (config_aliases.len > 0) bundle_opts.alias = config_aliases;
            }
            // sourcemap
            if (!opts.sourcemap) {
                if (sp.config.sourcemap) |sm| if (sm) {
                    opts.sourcemap = true;
                };
            }
            // minify
            if (!opts.minify_whitespace and !opts.minify_syntax) {
                if (sp.config.minify) |m| if (m) {
                    bundle_opts.minify_whitespace = true;
                    bundle_opts.minify_syntax = true;
                };
            }
            // format
            if (!opts.bundle_format_explicit) {
                if (sp.config.format) |fmt| {
                    if (std.meta.stringToEnum(emitter.EmitOptions.Format, fmt)) |f| {
                        bundle_opts.format = f;
                    }
                }
            }
            // platform
            if (sp.config.platform) |plat| {
                if (opts.platform == .browser) { // CLI 기본값이면 config 적용
                    if (std.mem.eql(u8, plat, "node")) {
                        bundle_opts.platform = .node;
                    } else if (std.mem.eql(u8, plat, "neutral")) {
                        bundle_opts.platform = .neutral;
                    }
                }
            }
            // splitting
            if (!opts.splitting) {
                if (sp.config.splitting) |s| if (s) {
                    bundle_opts.code_splitting = true;
                };
            }
            // preserveModules
            if (!opts.preserve_modules) {
                if (sp.config.preserveModules) |pm| if (pm) {
                    bundle_opts.preserve_modules = true;
                };
                if (sp.config.preserveModulesRoot) |pmr| {
                    bundle_opts.preserve_modules_root = pmr;
                }
            }
            // jsx
            if (opts.jsx_runtime == null) {
                if (sp.config.jsx) |jsx_mode| {
                    if (std.mem.eql(u8, jsx_mode, "automatic")) {
                        bundle_opts.jsx_runtime = .automatic;
                    } else if (std.mem.eql(u8, jsx_mode, "automatic-dev")) {
                        bundle_opts.jsx_runtime = .automatic_dev;
                    } else if (std.mem.eql(u8, jsx_mode, "classic")) {
                        bundle_opts.jsx_runtime = .classic;
                    }
                }
            }
            if (sp.config.jsxFactory) |f| bundle_opts.jsx_factory = f;
            if (sp.config.jsxFragment) |f| bundle_opts.jsx_fragment = f;
            if (sp.config.jsxImportSource) |s| bundle_opts.jsx_import_source = s;
            // banner/footer
            if (opts.banner_js == null) {
                if (sp.getBannerJs()) |b| bundle_opts.banner_js = b;
            }
            if (opts.footer_js == null) {
                if (sp.getFooterJs()) |f| bundle_opts.footer_js = f;
            }
            // publicPath
            if (opts.public_path == null) {
                if (sp.config.publicPath) |pp| bundle_opts.public_path = pp;
            }
            // inject
            if (opts.inject_list.items.len == 0) {
                const config_inject = sp.getInject();
                if (config_inject.len > 0) bundle_opts.inject = config_inject;
            }
            // globalName
            if (opts.global_name == null) {
                if (sp.config.globalName) |gn| bundle_opts.global_name = gn;
            }
            // keepNames
            if (!opts.keep_names) {
                if (sp.config.keepNames) |kn| if (kn) {
                    bundle_opts.keep_names = true;
                };
            }
            // legalComments
            if (sp.config.legalComments) |lc| {
                if (std.mem.eql(u8, lc, "none")) {
                    bundle_opts.legal_comments = .none;
                } else if (std.mem.eql(u8, lc, "inline")) {
                    bundle_opts.legal_comments = .@"inline";
                } else if (std.mem.eql(u8, lc, "eof")) {
                    bundle_opts.legal_comments = .eof;
                }
            }
        }

        // watch + dev: 초기 빌드에서도 module_codes 수집 (HMR 캐시 초기화용)
        var initial_opts = bundle_opts;
        if (opts.watch and opts.dev) initial_opts.collect_module_codes = true;
        var bundler = Bundler.init(allocator, initial_opts);
        defer bundler.deinit();

        const result = bundler.bundle() catch |err| {
            try stderr.print("zts: bundle failed: {}\n", .{err});
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
                try stderr.print("[{s}] {s}: {s}", .{ sev_str, d.file_path, d.message });
                if (d.suggestion) |s| try stderr.print(" (did you mean '{s}'?)", .{s});
                try stderr.print("\n", .{});
            }
        }

        // --allow-overwrite 체크: 출력 파일이 입력 파일을 덮어쓰지 않도록
        if (!opts.allow_overwrite) {
            const entry_abs = abs_entry;
            if (opts.output_file) |out_path| {
                const out_abs = std.fs.cwd().realpathAlloc(allocator, out_path) catch out_path;
                if (std.mem.eql(u8, entry_abs, out_abs)) {
                    try stderr.print("zts: output file '{s}' would overwrite input file (use --allow-overwrite to permit)\n", .{out_path});
                    return error.TranspileFailed;
                }
            }
        }

        // 출력
        // --watch-json 모드에서는 stdout이 NDJSON 전용이므로
        // 상태 메시지와 raw 번들 출력은 억제
        var initial_bytes: usize = 0;
        if (result.outputs) |outputs| {
            // Code splitting: 다중 파일 출력 → --outdir 필수
            const out_dir = opts.output_dir orelse ".";
            std.fs.cwd().makePath(out_dir) catch {};
            for (outputs) |o| {
                initial_bytes += o.contents.len;
                const full_path = try std.fs.path.join(allocator, &.{ out_dir, o.path });
                defer allocator.free(full_path);
                // naming 패턴에 디렉토리가 포함된 경우 (예: chunks/[name]-[hash])
                // 하위 디렉토리를 생성해야 함
                if (std.fs.path.dirname(full_path)) |dir| {
                    std.fs.cwd().makePath(dir) catch {};
                }
                const file = try std.fs.cwd().createFile(full_path, .{});
                defer file.close();
                try file.writeAll(o.contents);
                if (!opts.watch_json) {
                    try stdout.print("  {s} ({d} bytes)\n", .{ full_path, o.contents.len });
                }
            }
            if (!opts.watch_json) {
                try stdout.print("Bundled → {d} chunks in {s}/\n", .{ outputs.len, out_dir });
            }
            try writeAssetOutputs(allocator, result.asset_outputs, out_dir);
        } else if (opts.output_file) |out_path| {
            // 단일 파일 출력
            if (std.fs.path.dirname(out_path)) |dir| {
                std.fs.cwd().makePath(dir) catch {};
            }
            const file = try std.fs.cwd().createFile(out_path, .{});
            defer file.close();
            try file.writeAll(result.output);
            initial_bytes = result.output.len;
            if (!opts.watch_json) {
                try stdout.print("Bundled → {s} ({d} bytes)\n", .{ out_path, result.output.len });
            }
            try writeAssetOutputs(allocator, result.asset_outputs, std.fs.path.dirname(out_path) orelse ".");

            // 소스맵 파일 출력
            if (result.sourcemap) |sm_json| {
                const map_path = try std.fmt.allocPrint(allocator, "{s}.map", .{out_path});
                defer allocator.free(map_path);
                std.fs.cwd().writeFile(.{ .sub_path = map_path, .data = sm_json }) catch |err| {
                    try stderr.print("zts: cannot write '{s}': {}\n", .{ map_path, err });
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
                const file = try std.fs.cwd().createFile(mf_path, .{});
                defer file.close();
                try file.writeAll(mf);
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
            const module_store_mod = @import("zts_lib").bundler.module_store;
            const ResolveCache = @import("zts_lib").bundler.ResolveCache;
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
            var persistent_resolve_cache = ResolveCache.init(allocator, .{
                .platform = bundle_opts.platform,
                .external_patterns = bundle_opts.external,
                .custom_conditions = bundle_opts.conditions,
                .preserve_symlinks = bundle_opts.preserve_symlinks,
                .alias = bundle_opts.alias,
                .resolve_extensions = bundle_opts.resolve_extensions,
                .main_fields = bundle_opts.main_fields,
                .packages_external = bundle_opts.packages_external,
                .node_paths = bundle_opts.node_paths,
            });
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
            const entry_mtime = getFileMtime(abs_entry) catch 0;
            try mtime_map.put(entry_dupe, entry_mtime);

            if (result.module_paths) |paths| {
                for (paths) |p| {
                    const duped = allocator.dupe(u8, p) catch continue;
                    const mt = getFileMtime(p) catch continue;
                    mtime_map.put(duped, mt) catch continue;
                }
            }

            // config 파일도 감시 대상에 추가
            for (opts.plugin_paths.items) |config_path| {
                const abs_config = std.fs.cwd().realpathAlloc(allocator, config_path) catch continue;
                const config_mt = getFileMtime(abs_config) catch 0;
                mtime_map.put(abs_config, config_mt) catch {
                    allocator.free(abs_config);
                };
            }

            if (opts.watch_json) {
                try stdout.print("{{\"type\":\"ready\",\"files\":{d},\"bytes\":{d}}}\n", .{ mtime_map.count(), initial_bytes });
            } else {
                try stderr.print("[watch] Watching {d} files for changes...\n", .{mtime_map.count()});
            }

            while (true) {
                std.Thread.sleep(500 * std.time.ns_per_ms);

                // mtime 변경 확인 + 변경 파일 수집
                var changed = false;
                var config_changed = false;
                var changed_files: std.ArrayList([]const u8) = .empty;
                defer changed_files.deinit(allocator);

                var mit = mtime_map.iterator();
                while (mit.next()) |entry| {
                    const current_mtime = getFileMtime(entry.key_ptr.*) catch continue;
                    if (current_mtime != entry.value_ptr.*) {
                        if (!opts.watch_json) {
                            try stderr.print("[watch] Changed: {s}\n", .{entry.key_ptr.*});
                        }
                        entry.value_ptr.* = current_mtime;
                        changed = true;
                        changed_files.append(allocator, entry.key_ptr.*) catch {};
                        // config 파일이 변경되었는지 확인
                        for (opts.plugin_paths.items) |config_path| {
                            const abs_config = std.fs.cwd().realpathAlloc(allocator, config_path) catch continue;
                            defer allocator.free(abs_config);
                            if (std.mem.eql(u8, entry.key_ptr.*, abs_config)) {
                                config_changed = true;
                                break;
                            }
                        }
                    }
                }

                if (!changed) continue;

                // config 변경 시 플러그인 프로세스 재시작
                if (config_changed) {
                    try stderr.print("[watch] Config changed, restarting plugins...\n", .{});
                    for (subprocess_list.items) |sp| sp.shutdown();
                    subprocess_list.clearRetainingCapacity();
                    plugin_list.clearRetainingCapacity();

                    for (opts.plugin_paths.items) |config_path| {
                        const sp = SubprocessPlugin.spawn(allocator, config_path) catch |err| {
                            try stderr.print("[watch] Plugin restart failed: {}\n", .{err});
                            continue;
                        };
                        try subprocess_list.append(allocator, sp);
                        try plugin_list.append(allocator, sp.toPlugin());
                    }
                    // bundle_opts의 plugins를 갱신
                    bundle_opts.plugins = plugin_list.items;
                }

                // 재번들 — 증분 빌드: persistent_store + persistent_resolve_cache 재사용
                // dev mode rebuild에서만 module_codes 수집 (HMR용). 초기 빌드는 false (메모리 절감).
                var incremental_opts = bundle_opts;
                incremental_opts.collect_module_codes = opts.dev;
                incremental_opts.module_store = &persistent_store;
                var rebundler = Bundler.initWithResolveCache(allocator, incremental_opts, &persistent_resolve_cache);
                defer rebundler.deinit(); // resolve_cache는 외부 소유이므로 해제 안 됨

                const rebuild_result = rebundler.bundle() catch |err| {
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
                        if (std.fs.path.dirname(full_path)) |dir| std.fs.cwd().makePath(dir) catch {};
                        const file = std.fs.cwd().createFile(full_path, .{}) catch continue;
                        defer file.close();
                        file.writeAll(o.contents) catch continue;
                    }
                    if (!opts.watch_json) {
                        try stderr.print("[watch] Rebuilt → {d} chunks\n", .{outputs.len});
                    }
                } else if (opts.output_file) |out_path| {
                    output_bytes = rebuild_result.output.len;
                    if (std.fs.path.dirname(out_path)) |dir| std.fs.cwd().makePath(dir) catch {};
                    const file = std.fs.cwd().createFile(out_path, .{}) catch continue;
                    defer file.close();
                    file.writeAll(rebuild_result.output) catch continue;
                    // rebuild 시에도 소스맵 갱신
                    if (rebuild_result.sourcemap) |sm_json| {
                        const map_path = try std.fmt.allocPrint(allocator, "{s}.map", .{out_path});
                        defer allocator.free(map_path);
                        std.fs.cwd().writeFile(.{ .sub_path = map_path, .data = sm_json }) catch |err| {
                            try stderr.print("zts: cannot write '{s}': {}\n", .{ map_path, err });
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
                        try writeJsonString(stdout, path);
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
                                        try writeJsonString(stdout, dc.id);
                                        try stdout.print(",\"code\":", .{});
                                        try writeJsonString(stdout, dc.code);
                                        if (dc.map) |m| {
                                            try stdout.print(",\"map\":", .{});
                                            try writeJsonString(stdout, m);
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
                                try writeJsonString(stdout, p);
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

                    // 엔트리 재추가
                    const re_entry = allocator.dupe(u8, abs_entry) catch continue;
                    const re_mtime = getFileMtime(abs_entry) catch 0;
                    mtime_map.put(re_entry, re_mtime) catch continue;

                    if (rebuild_result.module_paths) |paths| {
                        for (paths) |p| {
                            const duped = allocator.dupe(u8, p) catch continue;
                            const mt = getFileMtime(p) catch continue;
                            mtime_map.put(duped, mt) catch continue;
                        }
                    }
                }
            }
        }

        return;
    }

    // 입력 경로가 디렉토리인지 확인
    const input_path_str = opts.input_file orelse {
        try printUsage(stdout);
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
        },
        .timing = opts.timing,
        .allow_overwrite = opts.allow_overwrite,
    };

    const is_stdin = std.mem.eql(u8, input_path_str, "-");

    if (!is_stdin) {
        // statFile로 디렉토리 여부 판별
        const stat = std.fs.cwd().statFile(input_path_str) catch |err| {
            // statFile이 실패하면 openDir을 시도하여 디렉토리인지 확인
            // (일부 시스템에서 디렉토리에 statFile이 실패할 수 있음)
            var dir = std.fs.cwd().openDir(input_path_str, .{}) catch {
                // 파일도 디렉토리도 아닌 경우
                try stderr.print("zts: cannot access '{s}': {}\n", .{ input_path_str, err });
                std.process.exit(1);
            };
            dir.close();
            // 디렉토리 확인됨 — 아래 디렉토리 처리로 이동
            const out_dir = opts.output_dir orelse {
                try stderr.print("zts: --outdir is required when input is a directory\n", .{});
                std.process.exit(1);
            };
            walkAndTranspile(allocator, input_path_str, out_dir, options) catch std.process.exit(1);
            if (opts.watch) {
                try watchDirectory(allocator, input_path_str, out_dir, options, stderr);
            }
            return;
        };

        if (stat.kind == .directory) {
            const out_dir = opts.output_dir orelse {
                try stderr.print("zts: --outdir is required when input is a directory\n", .{});
                std.process.exit(1);
            };
            walkAndTranspile(allocator, input_path_str, out_dir, options) catch std.process.exit(1);
            if (opts.watch) {
                try watchDirectory(allocator, input_path_str, out_dir, options, stderr);
            }
            return;
        }
    }

    // 단일 파일 트랜스파일 (기존 로직)
    const file_path = if (is_stdin) "<stdin>" else input_path_str;

    if (is_stdin) {
        const source = std.fs.File.stdin().readToEndAlloc(allocator, 100 * 1024 * 1024) catch |err| {
            try stderr.print("zts: cannot read stdin: {}\n", .{err});
            std.process.exit(1);
        };
        defer allocator.free(source);
        transpileFile(allocator, file_path, source, opts.output_file, options) catch std.process.exit(1);
    } else {
        transpileFile(allocator, file_path, null, opts.output_file, options) catch std.process.exit(1);
        if (opts.watch) {
            watchFile(allocator, file_path, opts.output_file, options, stderr) catch std.process.exit(1);
        }
    }
}

/// 단일 파일을 폴링 방식으로 감시한다 (D048).
/// 파일의 mtime을 500ms마다 확인하여 변경되면 재트랜스파일한다.
/// Ctrl+C로 종료될 때까지 무한 루프를 돈다.
fn watchFile(
    allocator: std.mem.Allocator,
    file_path: []const u8,
    output_path: ?[]const u8,
    options: TranspileOptions,
    stderr: anytype,
) !void {
    const stdout = std.fs.File.stdout().deprecatedWriter();

    // 초기 mtime 저장
    var last_mtime = getFileMtime(file_path) catch |err| {
        try stderr.print("zts: cannot stat '{s}': {}\n", .{ file_path, err });
        return error.WatchFailed;
    };

    try stdout.print("[watch] Watching for file changes...\n", .{});

    while (true) {
        std.Thread.sleep(500 * std.time.ns_per_ms);

        const current_mtime = getFileMtime(file_path) catch continue;

        if (current_mtime != last_mtime) {
            last_mtime = current_mtime;
            try stdout.print("[watch] File changed: {s}\n", .{file_path});
            transpileFile(allocator, file_path, null, output_path, options) catch |err| {
                try stderr.print("zts: watch re-transpile error: {}\n", .{err});
            };
        }
    }
}

/// 디렉토리를 폴링 방식으로 감시한다 (D048).
/// 매 500ms마다 디렉토리를 재순회하여 .ts/.tsx 파일의 mtime을 확인하고,
/// 변경된 파일만 재트랜스파일한다.
fn watchDirectory(
    allocator: std.mem.Allocator,
    input_dir: []const u8,
    output_dir: []const u8,
    options: TranspileOptions,
    stderr: anytype,
) !void {
    const stdout = std.fs.File.stdout().deprecatedWriter();

    // mtime 맵: 파일 경로(소유) -> mtime
    var mtime_map = std.StringHashMap(i128).init(allocator);
    defer {
        var it = mtime_map.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
        }
        mtime_map.deinit();
    }

    // 초기 mtime 수집
    try collectMtimes(allocator, input_dir, &mtime_map);

    try stdout.print("[watch] Watching for file changes...\n", .{});

    while (true) {
        std.Thread.sleep(500 * std.time.ns_per_ms);

        // 현재 파일 상태 수집
        var current_mtimes = std.StringHashMap(i128).init(allocator);
        defer {
            var it = current_mtimes.iterator();
            while (it.next()) |entry| {
                allocator.free(entry.key_ptr.*);
            }
            current_mtimes.deinit();
        }

        collectMtimes(allocator, input_dir, &current_mtimes) catch continue;

        // 변경된 파일 찾기
        var it = current_mtimes.iterator();
        while (it.next()) |entry| {
            const path = entry.key_ptr.*;
            const current_mtime = entry.value_ptr.*;

            const old_mtime = mtime_map.get(path);
            if (old_mtime == null or old_mtime.? != current_mtime) {
                try stdout.print("[watch] File changed: {s}\n", .{path});

                // 출력 경로 계산
                // path는 input_dir/relative 형태이므로 input_dir 접두사를 제거
                const rel_path = if (std.mem.startsWith(u8, path, input_dir))
                    path[input_dir.len + 1 ..] // +1 for path separator
                else
                    path;

                const is_tsx = std.mem.endsWith(u8, rel_path, ".tsx");
                const basename_no_ext = if (is_tsx)
                    rel_path[0 .. rel_path.len - 4]
                else
                    rel_path[0 .. rel_path.len - 3];
                const output_rel = try std.fmt.allocPrint(allocator, "{s}.js", .{basename_no_ext});
                defer allocator.free(output_rel);
                const out_path = try std.fs.path.join(allocator, &.{ output_dir, output_rel });
                defer allocator.free(out_path);

                transpileFile(allocator, path, null, out_path, options) catch |err| {
                    try stderr.print("zts: watch re-transpile error: {}\n", .{err});
                };

                // mtime 맵 업데이트 - 키를 복제하여 저장
                const owned_key = try allocator.dupe(u8, path);
                if (mtime_map.fetchPut(owned_key, current_mtime) catch null) |old| {
                    allocator.free(old.key);
                }
            }
        }
    }
}

/// JSON 문자열을 이스케이프하여 출력한다 (--watch-json용).
fn writeJsonString(writer: anytype, s: []const u8) !void {
    try writer.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => if (c < 0x20) {
                // RFC 8259: 제어 문자 (0x00-0x1F)는 \u00XX로 이스케이프
                try writer.print("\\u{x:0>4}", .{@as(u16, c)});
            } else {
                try writer.writeByte(c);
            },
        }
    }
    try writer.writeByte('"');
}

/// 파일의 mtime(수정 시각)을 i128 나노초 단위로 반환한다.
fn getFileMtime(path: []const u8) !i128 {
    const stat = try std.fs.cwd().statFile(path);
    return stat.mtime;
}

/// 디렉토리를 순회하며 .ts/.tsx 파일의 mtime을 수집한다.
/// mtime_map에 파일 전체 경로(소유) -> mtime을 저장한다.
fn collectMtimes(
    allocator: std.mem.Allocator,
    input_dir: []const u8,
    mtime_map: *std.StringHashMap(i128),
) !void {
    var dir = try std.fs.cwd().openDir(input_dir, .{ .iterate = true });
    defer dir.close();

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;

        const path = entry.path;
        if (std.mem.indexOf(u8, path, "node_modules") != null) continue;

        const is_ts = std.mem.endsWith(u8, path, ".ts");
        const is_tsx = std.mem.endsWith(u8, path, ".tsx");
        if (!is_ts and !is_tsx) continue;
        if (std.mem.endsWith(u8, path, ".d.ts")) continue;

        // 전체 경로 구성
        const full_path = try std.fs.path.join(allocator, &.{ input_dir, path });

        const mtime = getFileMtime(full_path) catch {
            allocator.free(full_path);
            continue;
        };

        // full_path를 키로 소유권 이전
        mtime_map.put(full_path, mtime) catch {
            allocator.free(full_path);
            continue;
        };
    }
}

/// 에러 코드 프레임 출력 (D012).
/// 형식:
///   file.ts:3:5: error: expected ';'
///     3 | const x =
///       |           ^
// printErrorCodeFrame — 삭제됨. diagnostic_renderer.render()로 대체.

fn printUsage(writer: anytype) !void {
    try writer.print(
        \\zts v0.1.0 - Zig TypeScript Transpiler
        \\
        \\Usage:
        \\  zts <file.ts>                    Transpile to stdout
        \\  zts <file.ts> -o <out.js>        Transpile to file
        \\  zts <dir/> --outdir <out/>       Transpile directory recursively
        \\  zts --bundle <entry.ts>          Bundle to stdout
        \\  zts --bundle <entry.ts> -o out   Bundle to file
        \\  zts --bundle <entry.ts> --splitting --outdir dist  Code splitting
        \\  zts - < input.ts                 Read from stdin
        \\
        \\Options:
        \\  -o, --out-file <path>            Output file path
        \\  --outdir <path>                  Output directory (for directory input)
        \\  --minify                         Minify output
        \\  --format=esm|cjs|iife|umd|amd    Module format (default: esm)
        \\  --drop=console                   Remove console.* calls
        \\  --drop=debugger                  Remove debugger statements
        \\  --define:KEY=VALUE               Replace KEY with VALUE globally
        \\  --sourcemap                      Generate source map (.js.map)
        \\  --sourcemap-debug-ids            Add Sentry debugId to JS and source map
        \\  --ascii-only                     Escape non-ASCII to \uXXXX
        \\  --quotes=<style>                 String quote style (double|single|preserve)
        \\  -w, --watch                      Watch for file changes
        \\  -p, --project <path>             Path to tsconfig.json directory
        \\  --tokenize                       Print tokens instead of transpiling
        \\  --test262 <dir>                  Run Test262 tests
        \\  -h, --help                       Show this help
        \\
        \\Dev server:
        \\  --serve [dir]                    Start static file server (default: .)
        \\  --serve --bundle <entry.ts>      Bundle and serve entry point
        \\  --port <number>                  Server port (default: 3000)
        \\
        \\Bundle options:
        \\  --bundle                         Enable bundle mode
        \\  --splitting                      Enable code splitting (requires --outdir)
        \\  --preserve-modules               One file per module (library builds, requires --outdir)
        \\  --preserve-modules-root=<dir>    Root directory for output structure
        \\  --external <pkg>                 Exclude package (repeatable)
        \\  --conditions=<cond,...>          Custom export conditions (e.g. production)
        \\  --platform=browser|node|neutral  Target platform (default: browser)
        \\  --rn-platform=ios|android        RN sub-platform (.ios.*/.android.* extensions)
        \\
        \\TypeScript options:
        \\  --experimental-decorators         Legacy decorator (__decorateClass)
        \\  --use-define-for-class-fields=false  Move fields to constructor (assign semantics)
        \\
        \\Flow options:
        \\  --flow                            Enable Flow type stripping (auto-detected via @flow pragma)
        \\
        \\Resolve options:
        \\  --resolve-extensions=<exts>       Comma-separated extension order (e.g. .ios.ts,.ts,.js)
        \\  --main-fields=<fields>            Comma-separated package.json field order (e.g. react-native,browser,main)
        \\
    , .{});
}

test "basic" {
    try std.testing.expect(true);
}
