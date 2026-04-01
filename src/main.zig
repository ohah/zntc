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
    output_file: ?[]const u8 = null,
    output_dir: ?[]const u8 = null,
    minify_whitespace: bool = false,
    minify_identifiers: bool = false,
    minify_syntax: bool = false,
    module_format: lib.codegen.codegen.ModuleFormat = .esm,
    drop_console: bool = false,
    drop_debugger: bool = false,
    sourcemap: bool = false,
    ascii_only: bool = false,
    quote_style: lib.codegen.QuoteStyle = .double,
    watch: bool = false,
    watch_json: bool = false,
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
    unsupported: lib.transformer.TransformOptions.compat.UnsupportedFeatures = .{},
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
    keep_names: bool = false,
    plugin_paths: std.ArrayList([]const u8) = .empty,
    proxy_list: std.ArrayList(lib.server.DevServer.ProxyRule) = .empty,
    /// Flow 모드 강제 활성화. @flow pragma 없이도 .js/.jsx를 Flow로 파싱한다.
    flow: bool = false,
    /// .js 파일에서도 JSX 파싱 활성화. --platform=react-native 프리셋에서 자동 설정.
    jsx_in_js: bool = false,
    /// JSX 런타임 모드 (--jsx=classic|automatic|automatic-dev, --jsx-dev)
    jsx_runtime: lib.codegen.codegen.JsxRuntime = .classic,
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
        self.external_list.deinit(alloc);
        self.define_list.deinit(alloc);
        self.conditions_list.deinit(alloc);
        self.alias_list.deinit(alloc);
        self.loader_list.deinit(alloc);
        for (self.inject_list.items) |p| alloc.free(p);
        self.inject_list.deinit(alloc);
        self.plugin_paths.deinit(alloc);
        self.proxy_list.deinit(alloc);
        self.resolve_extensions_list.deinit(alloc);
        self.main_fields_list.deinit(alloc);
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
                return null;
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
                return null;
            }
        } else if (std.mem.eql(u8, arg, "--sourcemap")) {
            opts.sourcemap = true;
        } else if (std.mem.eql(u8, arg, "--project") or std.mem.eql(u8, arg, "-p")) {
            if (i + 1 < args.len) {
                i += 1;
                opts.project_path = args[i];
            }
        } else if (std.mem.eql(u8, arg, "--watch-json")) {
            opts.watch = true;
            opts.watch_json = true;
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
                    return null;
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
                    return null;
                }
            } else {
                try stderr.print("zts: --proxy requires a PATH=TARGET argument\n", .{});
                return null;
            }
        } else if (std.mem.eql(u8, arg, "--splitting")) {
            opts.splitting = true;
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
        } else if (std.mem.eql(u8, arg, "--format=iife")) {
            opts.bundle_format = .iife;
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
            // ES 타겟 먼저 시도 (es5, es2015, ..., esnext)
            if (std.meta.stringToEnum(compat.ESTarget, val)) |es| {
                opts.unsupported = compat.fromESTarget(es);
            } else {
                // 엔진 버전 파싱 (chrome80,safari14,node16)
                opts.unsupported = parseEngineTargets(val) orelse {
                    try stderr.print("zts: unknown target '{s}'\n", .{val});
                    return null;
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
                return null;
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
                return null;
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
        } else if (std.mem.eql(u8, arg, "--plugin")) {
            if (i + 1 < args.len) {
                i += 1;
                try opts.plugin_paths.append(allocator, args[i]);
            } else {
                try stderr.print("zts: --plugin requires a file path\n", .{});
                return null;
            }
        } else if (std.mem.startsWith(u8, arg, "--inject:")) {
            const inject_path = arg["--inject:".len..];
            // 절대 경로로 변환
            const abs = std.fs.cwd().realpathAlloc(allocator, inject_path) catch {
                try stderr.print("zts: cannot resolve inject path: {s}\n", .{inject_path});
                return null;
            };
            try opts.inject_list.append(allocator, abs);
        } else if (std.mem.startsWith(u8, arg, "--legal-comments=")) {
            const val = arg["--legal-comments=".len..];
            opts.legal_comments = CliOptions.LegalCommentsEnum.fromString(val) orelse {
                try stderr.print("zts: unknown legal-comments mode '{s}' (expected: none, inline, eof, linked, external)\n", .{val});
                return null;
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
                    return null;
                }
            } else {
                try stderr.print("zts: --loader requires .EXT=TYPE format: {s}\n", .{arg});
                return null;
            }
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try printUsage(stdout);
            return null;
        } else if (arg[0] != '-' or (arg.len == 1 and arg[0] == '-')) {
            opts.input_file = arg;
        } else {
            try stderr.print("zts: unknown option: {s}\n", .{arg});
            return null;
        }
    }

    // --bundle + --platform=browser + --format 미지정이면 IIFE로 기본 설정 (esbuild 호환).
    // 브라우저 <script> 태그에서 로드할 때 top-level 선언이 글로벌을 오염시키지 않도록
    // 번들 전체를 IIFE로 래핑한다. ESM 출력이 필요하면 --format=esm을 명시해야 한다.
    if (opts.is_bundle and opts.platform.isBrowserLike() and !opts.bundle_format_explicit) {
        opts.bundle_format = .iife;
    }

    // --bundle + --platform=browser이면 process.env.NODE_ENV를 자동 define (esbuild 호환).
    // 트랜스파일 모드에서는 적용하지 않음 (esbuild와 동일).
    // 사용자가 이미 --define:process.env.NODE_ENV=... 를 지정한 경우 덮어쓰지 않음.
    if (opts.is_bundle and opts.platform.isBrowserLike()) {
        var has_node_env = false;
        for (opts.define_list.items) |d| {
            if (std.mem.eql(u8, d.key, "process.env.NODE_ENV")) {
                has_node_env = true;
                break;
            }
        }
        if (!has_node_env) {
            try opts.define_list.append(allocator, .{
                .key = "process.env.NODE_ENV",
                .value = "\"production\"",
            });
        }
    }

    return opts;
}

/// 트랜스파일 옵션을 담는 구조체.
/// CLI에서 파싱한 옵션들을 transpileFile / walkAndTranspile에 전달한다.
const DefineEntry = lib.transformer.DefineEntry;

const TranspileOptions = struct {
    module_format: lib.codegen.codegen.ModuleFormat = .esm,
    minify_whitespace: bool = false,
    minify_identifiers: bool = false,
    minify_syntax: bool = false,
    drop_console: bool = false,
    drop_debugger: bool = false,
    sourcemap: bool = false,
    ascii_only: bool = false,
    quote_style: lib.codegen.QuoteStyle = .double,
    define: []const DefineEntry = &.{},
    platform: lib.codegen.codegen.Platform = .browser,
    /// useDefineForClassFields=false: instance field → constructor this.x = value
    use_define_for_class_fields: bool = true,
    /// experimentalDecorators: legacy decorator → __decorateClass 호출
    experimental_decorators: bool = false,
    /// ES 타겟 레벨
    unsupported: lib.transformer.TransformOptions.compat.UnsupportedFeatures = .{},
    /// 파이프라인 단계별 소요시간 출력
    timing: bool = false,
    /// 소스맵 sourceRoot 필드
    source_root: []const u8 = "",
    /// 소스맵에 sourcesContent 포함 여부
    sources_content: bool = true,
    /// UTF-8 문자를 이스케이프하지 않고 그대로 출력 (--charset=utf8)
    charset_utf8: bool = false,
    /// Flow 모드 강제 활성화 (--flow)
    flow: bool = false,
    /// .js 파일에서도 JSX 파싱 활성화 (--platform=react-native 프리셋)
    jsx_in_js: bool = false,
    /// JSX 런타임 모드
    jsx_runtime: lib.codegen.codegen.JsxRuntime = .classic,
    /// classic 모드 JSX factory
    jsx_factory: []const u8 = "React.createElement",
    /// classic 모드 Fragment factory
    jsx_fragment: []const u8 = "React.Fragment",
    /// automatic 모드 import source
    jsx_import_source: []const u8 = "react",
};

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
    const stderr = std.fs.File.stderr().deprecatedWriter();
    const stdout = std.fs.File.stdout().deprecatedWriter();

    // 파일당 Arena allocator: 모든 내부 할당을 Arena에서 수행하고,
    // 함수 끝에서 일괄 해제한다. backing allocator(GPA)는 debug leak detection용.
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    // 타이밍 측정용 타이머 (--timing일 때만 시작)
    var timer: ?std.time.Timer = if (options.timing) std.time.Timer.start() catch null else null;
    var t_read: u64 = 0;
    var t_scan: u64 = 0;
    var t_parse: u64 = 0;
    var t_semantic: u64 = 0;
    var t_transform: u64 = 0;
    var t_codegen: u64 = 0;

    // 소스 읽기 — Arena에서 할당하므로 별도 free 불필요
    const source = source_override orelse blk: {
        break :blk std.fs.cwd().readFileAlloc(arena_alloc, file_path, 100 * 1024 * 1024) catch |err| {
            try stderr.print("zts: cannot read '{s}': {}\n", .{ file_path, err });
            return;
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
        // Parser.applyExtension()과 동일한 확장자 목록으로 is_module 설정.
        const ext = std.fs.path.extension(file_path);
        if (std.mem.eql(u8, ext, ".mts") or std.mem.eql(u8, ext, ".mjs") or
            std.mem.eql(u8, ext, ".ts") or std.mem.eql(u8, ext, ".tsx") or
            std.mem.eql(u8, ext, ".cts"))
        {
            scan_only.is_module = true;
        }
        try scan_only.next(); // 첫 토큰 스캔 (init은 토큰을 스캔하지 않음)
        while (scan_only.token.kind != .eof) {
            try scan_only.next();
        }
        if (timer) |*t| {
            t_scan = t.read();
            t.reset();
        }
    }

    // 파싱 — 모든 모듈이 arena_alloc을 사용하므로 개별 deinit 불필요
    var scanner = try Scanner.init(arena_alloc, source);
    var parser = Parser.init(arena_alloc, &scanner);
    parser.configureFromExtension(std.fs.path.extension(file_path));

    // Flow 모드 설정: --flow CLI 또는 .js.flow 확장자 또는 @flow pragma
    // is_ts와 is_flow는 상호 배타 — TS 파일에서 --flow는 무시
    if (!parser.is_ts) {
        if (options.flow) {
            parser.is_flow = true;
            scanner.has_flow_pragma = true; // flow comment (/*:: */, /*: */) 활성화
            // .js 파일은 import/export 감지를 위해 Unambiguous 모드
            if (!parser.is_module) {
                parser.is_module = true;
                scanner.is_module = true;
                parser.is_unambiguous = true;
            }
        } else {
            parser.configureFlowFromPath(file_path);
        }
    }
    // .js 파일에서 JSX 파싱 활성화 (--platform=react-native 프리셋)
    if (options.jsx_in_js) {
        parser.is_jsx = true;
    }
    _ = parser.parse() catch |err| {
        try stderr.print("zts: parse error in '{s}': {}\n", .{ file_path, err });
        return;
    };
    if (timer) |*t| {
        t_parse = t.read();
        t.reset();
    }

    // 파서 에러 출력 (코드 프레임, D012)
    if (parser.errors.items.len > 0) {
        for (parser.errors.items) |diag| {
            try printErrorCodeFrame(stderr, source, file_path, &scanner, diag);
        }
        return; // 파서 에러가 있으면 변환하지 않음
    }

    // Semantic analysis (D038): 파서 에러가 없을 때만 실행
    var analyzer = SemanticAnalyzer.init(arena_alloc, &parser.ast);
    analyzer.is_strict_mode = parser.is_strict_mode;
    analyzer.is_module = parser.is_module;
    analyzer.is_ts = parser.is_ts;
    analyzer.is_flow = parser.is_flow;
    try analyzer.analyze();
    if (timer) |*t| {
        t_semantic = t.read();
        t.reset();
    }
    if (analyzer.errors.items.len > 0) {
        for (analyzer.errors.items) |diag| {
            try printErrorCodeFrame(stderr, source, file_path, &scanner, diag);
        }
        return;
    }

    // Identifier mangling (--minify 활성화 시)
    const Mangler = lib.codegen.mangler;
    const LinkingMetadata = lib.bundler.LinkingMetadata;

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

    // 변환
    var transformer = Transformer.init(arena_alloc, &parser.ast, .{
        .drop_console = options.drop_console,
        .drop_debugger = options.drop_debugger,
        .define = options.define,
        .use_define_for_class_fields = options.use_define_for_class_fields,
        .experimental_decorators = options.experimental_decorators,
        .unsupported = options.unsupported,
    });
    // unused import 제거를 위해 semantic 데이터를 transformer에 전달
    transformer.old_symbol_ids = analyzer.symbol_ids.items;
    transformer.symbols = analyzer.symbols.items;
    const root = transformer.transform() catch |err| {
        try stderr.print("zts: transform error in '{s}': {}\n", .{ file_path, err });
        return;
    };

    // AST 미니파이어: --minify 시 constant folding 등 AST 레벨 최적화
    if (options.minify_syntax) {
        @import("zts_lib").transformer.minify.minify(&transformer.new_ast);
    }

    if (timer) |*t| {
        t_transform = t.read();
        t.reset();
    }

    // Mangling 메타데이터 구성 (codegen에 전달)
    // renames는 mangle_result가 소유 — mangle_metadata.deinit()에서 해제하지 않음
    var mangle_metadata: ?LinkingMetadata = null;
    defer if (mangle_metadata) |*mm| {
        mm.skip_nodes.deinit();
        // mm.renames는 mangle_result가 소유하므로 여기서 해제하지 않음
    };

    if (mangle_result) |*mr| {
        const node_count = transformer.new_ast.nodes.items.len;
        mangle_metadata = .{
            .skip_nodes = try std.DynamicBitSet.initEmpty(arena_alloc, node_count),
            .renames = mr.renames, // 소유권 이전하지 않음 — mangle_result가 소유
            .final_exports = null,
            .symbol_ids = if (transformer.new_symbol_ids.items.len > 0)
                transformer.new_symbol_ids.items
            else if (analyzer.symbol_ids.items.len > 0)
                analyzer.symbol_ids.items
            else
                &.{},
            .allocator = arena_alloc,
        };
    }

    // 코드 생성
    var cg = Codegen.initWithOptions(arena_alloc, &transformer.new_ast, .{
        .module_format = options.module_format,
        .minify_whitespace = options.minify_whitespace,
        .sourcemap = options.sourcemap,
        .ascii_only = if (options.charset_utf8) false else options.ascii_only,
        .quote_style = options.quote_style,
        .linking_metadata = if (mangle_metadata) |*mm| mm else null,
        .platform = options.platform,
        .source_root = options.source_root,
        .sources_content = options.sources_content,
        .jsx_runtime = options.jsx_runtime,
        .jsx_factory = options.jsx_factory,
        .jsx_fragment = options.jsx_fragment,
        .jsx_import_source = options.jsx_import_source,
        .jsx_filename = file_path,
    });
    cg.comments = scanner.comments.items;
    if (options.sourcemap) {
        cg.addSourceFile(file_path) catch |err| {
            try stderr.print("zts: sourcemap init error in '{s}': {}\n", .{ file_path, err });
        };
        cg.line_offsets = scanner.line_offsets.items;
    }
    const raw_output = cg.generate(root) catch |err| {
        try stderr.print("zts: codegen error in '{s}': {}\n", .{ file_path, err });
        return;
    };
    if (timer) |*t| {
        t_codegen = t.read();
        t.reset();
    }

    // 런타임 헬퍼 주입: transformer가 사용한 헬퍼를 코드 앞에 prepend
    const rh = transformer.runtime_helpers;
    const output = if (@as(u16, @bitCast(rh)) != 0) blk: {
        var helper_buf: std.ArrayList(u8) = .empty;
        emitter.appendRuntimeHelpers(&helper_buf, arena_alloc, rh, options.minify_whitespace) catch |err| {
            try stderr.print("zts: helper injection error: {}\n", .{err});
            break :blk raw_output;
        };
        helper_buf.appendSlice(arena_alloc, raw_output) catch |err| {
            try stderr.print("zts: helper concat error: {}\n", .{err});
            break :blk raw_output;
        };
        break :blk helper_buf.items;
    } else raw_output;

    // 출력 — output은 Arena 메모리의 slice이므로 arena.deinit() 전에 완료해야 함
    if (output_path) |out_path| {
        // 출력 디렉토리가 없으면 생성
        if (std.fs.path.dirname(out_path)) |dir| {
            std.fs.cwd().makePath(dir) catch |err| {
                try stderr.print("zts: cannot create directory '{s}': {}\n", .{ dir, err });
                return;
            };
        }

        std.fs.cwd().writeFile(.{
            .sub_path = out_path,
            .data = output,
        }) catch |err| {
            try stderr.print("zts: cannot write '{s}': {}\n", .{ out_path, err });
            return;
        };

        // 소스맵 파일 출력 (.js.map)
        if (options.sourcemap) {
            if (cg.generateSourceMap(out_path) catch null) |sm_json| {
                const map_path = try std.fmt.allocPrint(arena_alloc, "{s}.map", .{out_path});
                std.fs.cwd().writeFile(.{
                    .sub_path = map_path,
                    .data = sm_json,
                }) catch |err| {
                    try stderr.print("zts: cannot write '{s}': {}\n", .{ map_path, err });
                };
            }
        }
    } else {
        try stdout.writeAll(output);
    }

    // --timing: 파이프라인 단계별 소요시간 출력
    if (options.timing) {
        const total = t_read + t_parse + t_semantic + t_transform + t_codegen;
        const f_scan = @as(f64, @floatFromInt(t_scan)) / 1_000_000.0;
        const f_parse = @as(f64, @floatFromInt(t_parse)) / 1_000_000.0;
        try stderr.print(
            \\
            \\  Timing for '{s}' ({d} bytes):
            \\    read:      {d:.3} ms
            \\    scan:      {d:.3} ms  (standalone)
            \\    parse:     {d:.3} ms  (scan+AST: scan ~{d:.3}, AST ~{d:.3})
            \\    semantic:  {d:.3} ms
            \\    transform: {d:.3} ms
            \\    codegen:   {d:.3} ms
            \\    ─────────────────
            \\    total:     {d:.3} ms  (excludes standalone scan)
            \\
        , .{
            file_path,
            source.len,
            @as(f64, @floatFromInt(t_read)) / 1_000_000.0,
            f_scan,
            f_parse,
            @min(f_scan, f_parse),
            @max(f_parse - f_scan, 0.0),
            @as(f64, @floatFromInt(t_semantic)) / 1_000_000.0,
            @as(f64, @floatFromInt(t_transform)) / 1_000_000.0,
            @as(f64, @floatFromInt(t_codegen)) / 1_000_000.0,
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
        return;
    };
    defer dir.close();

    // 재귀적으로 파일 순회
    var walker = dir.walk(allocator) catch |err| {
        try stderr.print("zts: cannot walk directory '{s}': {}\n", .{ input_dir, err });
        return;
    };
    defer walker.deinit();

    var file_count: usize = 0;

    while (walker.next() catch |err| {
        try stderr.print("zts: error walking directory: {}\n", .{err});
        return;
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
        try transpileFile(allocator, input_path, null, output_path, options);
        file_count += 1;
    }

    if (file_count == 0) {
        try stderr.print("zts: no .ts/.tsx files found in '{s}'\n", .{input_dir});
    } else {
        try stdout.print("\nDone: {d} file(s) transpiled.\n", .{file_count});
    }
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
            try stderr.print("Error: --test262 requires a directory path\n", .{});
            return;
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
            try stderr.print("Error: --tokenize requires a file path\n", .{});
            return;
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
                try stderr.print("Error: --serve --bundle requires an entry file path\n", .{});
                return;
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
                return;
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
            try stderr.print("Error: failed to start dev server: {}\n", .{err});
            return;
        };
        defer dev_server.deinit();
        dev_server.start() catch |err| {
            try stderr.print("Error: dev server failed: {}\n", .{err});
            return;
        };
        return;
    }

    // --bundle
    if (opts.is_bundle) {
        const entry_file = opts.input_file orelse {
            try stderr.print("Error: --bundle requires an entry file path\n", .{});
            return;
        };
        const abs_entry = std.fs.cwd().realpathAlloc(allocator, entry_file) catch |err| {
            try stderr.print("zts: cannot resolve '{s}': {}\n", .{ entry_file, err });
            return;
        };
        defer allocator.free(abs_entry);

        // --splitting은 --outdir 필수
        if (opts.splitting and opts.output_dir == null) {
            try stderr.print("Error: --splitting requires --outdir\n", .{});
            return;
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
            const sp = SubprocessPlugin.spawn(allocator, config_path) catch |err| {
                try stderr.print("zts: plugin '{s}' spawn failed: {}\n", .{ config_path, err });
                return;
            };
            try subprocess_list.append(allocator, sp);
            try plugin_list.append(allocator, sp.toPlugin());
        }

        // --platform=react-native 프리셋: 사용자가 명시하지 않은 옵션에 RN 기본값 적용
        if (opts.platform == .react_native) {
            if (opts.resolve_extensions_list.items.len == 0) {
                try opts.resolve_extensions_list.appendSlice(allocator, &.{ ".tsx", ".ts", ".jsx", ".js", ".json" });
            }
            if (opts.main_fields_list.items.len == 0) {
                try opts.main_fields_list.appendSlice(allocator, &.{ "react-native", "browser", "module", "main" });
            }
            opts.flow = true;
            opts.jsx_in_js = true; // RN의 .js 파일은 Flow + JSX 혼용
        }

        // BundleOptions를 변수로 추출 — 초기 번들과 watch 재번들에서 재사용
        var bundle_opts: BundleOptions = .{
            .entry_points = &.{abs_entry},
            .format = opts.bundle_format,
            .platform = opts.platform,
            .external = opts.external_list.items,
            .minify_whitespace = opts.minify_whitespace,
            .minify_identifiers = opts.minify_identifiers,
            .minify_syntax = opts.minify_syntax,
            .code_splitting = opts.splitting,
            .define = opts.define_list.items,
            .experimental_decorators = opts.experimental_decorators orelse false,
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
            .keep_names = opts.keep_names,
            .plugins = plugin_list.items,
            .flow = opts.flow,
            .jsx_in_js = opts.jsx_in_js,
            .resolve_extensions = opts.resolve_extensions_list.items,
            .main_fields = opts.main_fields_list.items,
        };

        // config 파일 옵션 적용 — 첫 번째 플러그인의 config만 사용 (CLI가 우선)
        if (subprocess_list.items.len > 0) {
            const sp = subprocess_list.items[0];
            if (opts.loader_list.items.len == 0) {
                const config_loaders = sp.getLoaderOverrides(allocator) catch &.{};
                if (config_loaders.len > 0) bundle_opts.loader_overrides = config_loaders;
            }
            if (opts.external_list.items.len == 0) {
                const config_ext = sp.getExternals();
                if (config_ext.len > 0) bundle_opts.external = config_ext;
            }
            if (!opts.sourcemap) {
                if (sp.config.sourcemap) |sm| if (sm) {
                    opts.sourcemap = true;
                };
            }
            if (!opts.minify_whitespace and !opts.minify_syntax) {
                if (sp.config.minify) |m| if (m) {
                    bundle_opts.minify_whitespace = true;
                    bundle_opts.minify_syntax = true;
                };
            }
        }

        var bundler = Bundler.init(allocator, bundle_opts);
        defer bundler.deinit();

        const result = bundler.bundle() catch |err| {
            try stderr.print("zts: bundle failed: {}\n", .{err});
            return;
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
            var persistent_resolve_cache = ResolveCache.init(allocator, .{
                .platform = bundle_opts.platform,
                .external_patterns = bundle_opts.external,
                .custom_conditions = bundle_opts.conditions,
                .preserve_symlinks = bundle_opts.preserve_symlinks,
                .alias = bundle_opts.alias,
                .resolve_extensions = bundle_opts.resolve_extensions,
                .main_fields = bundle_opts.main_fields,
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
                var incremental_opts = bundle_opts;
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
                    try stdout.print("],\"modules\":[", .{});
                    if (rebuild_result.module_paths) |paths| {
                        for (paths, 0..) |p, i| {
                            if (i > 0) try stdout.print(",", .{});
                            try writeJsonString(stdout, p);
                        }
                    }
                    try stdout.print("],\"bytes\":{d}}}\n", .{output_bytes});
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

    // tsconfig.json 로드.
    // 우선순위: --project 경로 > 입력이 디렉토리면 그 디렉토리 > 입력 파일의 부모 디렉토리
    const tsconfig_dir: []const u8 = if (opts.project_path) |pp|
        pp
    else if (!std.mem.eql(u8, input_path_str, "-"))
        // 파일이면 dirname, 디렉토리면 그대로
        std.fs.path.dirname(input_path_str) orelse "."
    else
        ".";

    var tsconfig = TsConfig.load(allocator, tsconfig_dir) catch TsConfig{};
    defer tsconfig.deinit();

    // tsconfig 값을 기본값으로 사용하되, CLI 옵션이 우선한다.
    // CLI에서 명시적으로 설정하지 않은 옵션만 tsconfig에서 가져온다.
    // module_format: tsconfig의 module이 "commonjs"이면 cjs 사용
    if (opts.module_format == .esm) { // CLI에서 --format=cjs를 안 했으면
        if (tsconfig.module) |mod| {
            if (std.ascii.eqlIgnoreCase(mod, "commonjs")) {
                opts.module_format = .cjs;
            }
        }
    }
    // sourcemap: tsconfig에서 true이면 적용 (CLI --sourcemap이 이미 true면 그대로)
    if (!opts.sourcemap and tsconfig.source_map) {
        opts.sourcemap = true;
    }
    // output_dir: tsconfig의 outDir를 기본값으로 사용
    if (opts.output_dir == null) {
        if (tsconfig.out_dir) |od| {
            opts.output_dir = od;
        }
    }
    // experimentalDecorators: CLI 미지정이면 tsconfig에서 가져옴
    if (opts.experimental_decorators == null and tsconfig.experimental_decorators) {
        opts.experimental_decorators = true;
    }
    // useDefineForClassFields: CLI 미지정이면 tsconfig에서 가져옴 (tsconfig 파싱 필요 — 아래 참고)
    // 주의: tsconfig에 useDefineForClassFields가 없고 experimentalDecorators=true이면
    // TypeScript 4.x 호환을 위해 useDefineForClassFields=false가 기본값.
    // (TS 5.0+에서는 experimentalDecorators 여부와 무관하게 true가 기본)
    // 여기서는 사용자가 명시하지 않은 경우 TS 5.0+ 기본값(true)을 따른다.

    // JSX: CLI가 미지정(classic)이면 tsconfig에서 가져옴
    if (opts.jsx_runtime == .classic) {
        if (tsconfig.jsx) |jsx_mode| {
            if (std.mem.eql(u8, jsx_mode, "react-jsx") or std.mem.eql(u8, jsx_mode, "react-jsxdev")) {
                opts.jsx_runtime = if (std.mem.eql(u8, jsx_mode, "react-jsxdev")) .automatic_dev else .automatic;
            }
        }
    }
    // jsxFactory/jsxFragmentFactory: CLI 기본값이면 tsconfig에서 가져옴
    if (std.mem.eql(u8, opts.jsx_factory, "React.createElement")) {
        opts.jsx_factory = tsconfig.jsx_factory;
    }
    if (std.mem.eql(u8, opts.jsx_fragment, "React.Fragment")) {
        opts.jsx_fragment = tsconfig.jsx_fragment_factory;
    }
    if (std.mem.eql(u8, opts.jsx_import_source, "react")) {
        opts.jsx_import_source = tsconfig.jsx_import_source;
    }

    // 트랜스파일 옵션 구성
    const options = TranspileOptions{
        .module_format = opts.module_format,
        .minify_whitespace = opts.minify_whitespace,
        .minify_identifiers = opts.minify_identifiers,
        .minify_syntax = opts.minify_syntax,
        .drop_console = opts.drop_console,
        .drop_debugger = opts.drop_debugger,
        .sourcemap = opts.sourcemap,
        .ascii_only = opts.ascii_only,
        .quote_style = opts.quote_style,
        .define = opts.define_list.items,
        .platform = opts.platform,
        .use_define_for_class_fields = opts.use_define_for_class_fields orelse true,
        .experimental_decorators = opts.experimental_decorators orelse false,
        .unsupported = opts.unsupported,
        .timing = opts.timing,
        .source_root = opts.source_root orelse "",
        .sources_content = opts.sources_content,
        .charset_utf8 = opts.charset_utf8,
        .flow = opts.flow,
        .jsx_in_js = opts.jsx_in_js,
        .jsx_runtime = opts.jsx_runtime,
        .jsx_factory = opts.jsx_factory,
        .jsx_fragment = opts.jsx_fragment,
        .jsx_import_source = opts.jsx_import_source,
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
                return;
            };
            dir.close();
            // 디렉토리 확인됨 — 아래 디렉토리 처리로 이동
            const out_dir = opts.output_dir orelse {
                try stderr.print("zts: --outdir is required when input is a directory\n", .{});
                return;
            };
            try walkAndTranspile(allocator, input_path_str, out_dir, options);
            if (opts.watch) {
                try watchDirectory(allocator, input_path_str, out_dir, options, stderr);
            }
            return;
        };

        if (stat.kind == .directory) {
            const out_dir = opts.output_dir orelse {
                try stderr.print("zts: --outdir is required when input is a directory\n", .{});
                return;
            };
            try walkAndTranspile(allocator, input_path_str, out_dir, options);
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
            return;
        };
        defer allocator.free(source);
        try transpileFile(allocator, file_path, source, opts.output_file, options);
    } else {
        try transpileFile(allocator, file_path, null, opts.output_file, options);
        if (opts.watch) {
            try watchFile(allocator, file_path, opts.output_file, options, stderr);
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
        return;
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
fn printErrorCodeFrame(writer: anytype, source: []const u8, file_path: []const u8, scanner: *const Scanner, err: Diagnostic) !void {
    const lc = scanner.getLineColumn(err.span.start);
    const line_num = lc.line + 1;
    const col_num = lc.column + 1;

    // 에러 헤더
    const kind_label: []const u8 = switch (err.kind) {
        .parse => "error",
        .semantic => "error[semantic]",
    };
    if (err.found) |found| {
        try writer.print("{s}:{d}:{d}: {s}: Expected '{s}' but found '{s}'\n", .{ file_path, line_num, col_num, kind_label, err.message, found });
    } else {
        try writer.print("{s}:{d}:{d}: {s}: {s}\n", .{ file_path, line_num, col_num, kind_label, err.message });
    }

    // 해당 줄 텍스트 추출
    const line_start = if (lc.line < scanner.line_offsets.items.len)
        scanner.line_offsets.items[lc.line]
    else
        0;

    var line_end = line_start;
    while (line_end < source.len and source[line_end] != '\n' and source[line_end] != '\r') {
        line_end += 1;
    }
    const line_text = source[line_start..line_end];

    // 줄 번호 너비 계산
    var num_width: usize = 0;
    var n = line_num;
    while (n > 0) : (n /= 10) {
        num_width += 1;
    }

    // 소스 줄 출력: "  3 | const x ="
    try writer.print("  {d} | {s}\n", .{ line_num, line_text });

    // 밑줄 출력: "    |           ^"
    // 줄 번호 자리만큼 공백
    var i: usize = 0;
    while (i < num_width + 2) : (i += 1) {
        try writer.writeByte(' ');
    }
    try writer.writeAll("| ");

    // 열 위치까지 공백
    i = 0;
    while (i < lc.column) : (i += 1) {
        // 원본에서 탭이면 탭으로 맞춤
        if (line_start + i < source.len and source[line_start + i] == '\t') {
            try writer.writeByte('\t');
        } else {
            try writer.writeByte(' ');
        }
    }

    // 밑줄
    const err_len = if (err.span.end > err.span.start)
        @min(err.span.end - err.span.start, line_end - (line_start + lc.column))
    else
        1;
    i = 0;
    while (i < err_len) : (i += 1) {
        try writer.writeByte('^');
    }
    try writer.writeByte('\n');

    // 힌트 출력 (예: "  hint: Try inserting a semicolon here")
    if (err.hint) |hint| {
        try writer.print("  hint: {s}\n", .{hint});
    }

    // 관련 위치 출력 (예: "  --> file.ts:1:10: opening '(' is here")
    if (err.related_span) |rel_span| {
        const rel_lc = scanner.getLineColumn(rel_span.start);
        const rel_line = rel_lc.line + 1;
        const rel_col = rel_lc.column + 1;
        const label = err.related_label orelse "related";
        try writer.print("  --> {s}:{d}:{d}: {s}\n", .{ file_path, rel_line, rel_col, label });
    }
}

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
        \\  --format=esm|cjs|iife            Module format (default: esm)
        \\  --drop=console                   Remove console.* calls
        \\  --drop=debugger                  Remove debugger statements
        \\  --define:KEY=VALUE               Replace KEY with VALUE globally
        \\  --sourcemap                      Generate source map (.js.map)
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
        \\  --external <pkg>                 Exclude package (repeatable)
        \\  --conditions=<cond,...>          Custom export conditions (e.g. production)
        \\  --platform=browser|node|neutral  Target platform (default: browser)
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
