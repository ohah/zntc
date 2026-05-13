const std = @import("std");
const lib = @import("zntc_lib");
const BundleOptions = lib.bundler.BundleOptions;
const usage_cli = @import("usage.zig");

/// CLI 인자를 파싱한 결과를 담는 구조체.
/// main()에서 개별 변수 30여 개로 흩어져 있던 옵션을 하나로 모은다.
pub const CliOptions = struct {
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
    /// 소스맵 출력 형식 (#2152) — esbuild/rolldown 호환.
    sourcemap_mode: lib.codegen.sourcemap.SourceMapMode = .linked,
    /// CJS / UMD entry export 형식 (#2159) — Rollup output.exports 호환.
    output_exports: lib.bundler.OutputExports = .auto,
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
    /// --verbatim-module-syntax: null이면 tsconfig 값 사용, 명시적으로 설정되면 override.
    verbatim_module_syntax: ?bool = null,
    unsupported: lib.transformer.TransformOptions.compat.UnsupportedFeatures = .{},
    /// --target에서 파싱한 ES 타겟. top-level await 등 타겟 제한 검증에 사용.
    es_target: ?lib.transformer.TransformOptions.compat.ESTarget = null,
    /// 사용자가 --target을 명시적으로 전달했는지 (RN 프리셋 경고용).
    target_explicit: bool = false,
    /// 사용자가 명시적으로 `--legal-comments=` 를 전달했는지. RN preset 의 default
    /// override (.none) 가 사용자 명시값을 덮어쓰지 않게 하기 위함.
    legal_comments_explicit: bool = false,
    conditions_list: std.ArrayList([]const u8) = .empty,
    /// --profile=<CSV>: 활성화할 profile category 목록. e.g. "all", "parse,transform".
    profile_csv: ?[]const u8 = null,
    /// --profile-level=<summary|detailed|per-module|per-pass>.
    profile_level: ?[]const u8 = null,
    /// --profile-format=<table|tree|json|csv>.
    profile_format: ?[]const u8 = null,
    /// --stop-after=<scan|parse|semantic|transform|codegen> 파싱 결과. 지정된 phase
    /// 이후 파이프라인 skip → empty output (debug/profile 용).
    core_stop_after: ?lib.transpile.StopAfter = null,
    preserve_symlinks: bool = false,
    /// Metro `resolver.disableHierarchicalLookup` 호환 — parent dir walk-up 차단.
    disable_hierarchical_lookup: bool = false,
    alias_list: std.ArrayList(AliasEntry) = .empty,
    /// --fallback:NAME=PATH (webpack resolve.fallback). 일반 해석 실패 시에만 적용.
    /// PATH 대신 "false"로 쓰면 빈 모듈로 대체.
    fallback_list: std.ArrayList(FallbackEntry) = .empty,
    /// `zntc.config.json` 의 `manualChunks` (record form: `[{name, patterns}]`) 매핑.
    /// CLI flag 없음 — config.json 만. function form 은 JS-only 라 NAPI 경유.
    manual_chunks_list: std.ArrayList(ManualChunkEntry) = .empty,
    /// --block-list=PATTERN (반복). Metro resolver.blockList 호환.
    /// JS regex source 스타일 문자열 (`\/ios\/`, `\.bak$` 등).
    block_list: std.ArrayList([]const u8) = .empty,
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
    /// --asset-registry=PATH: Metro AssetRegistry 모듈 경로. null=일반 URL, ""(명시적 off),
    /// RN 플랫폼은 미지정 시 기본 경로 자동 적용.
    asset_registry: ?[]const u8 = null,
    /// 사용자가 명시적으로 --no-asset-registry를 전달했는지 (RN 프리셋 자동 적용 억제용).
    asset_registry_explicit_off: bool = false,
    loader_list: std.ArrayList(LoaderOverride) = .empty,
    metafile_path: ?[]const u8 = null,
    /// --mangle-report=<path>: mangler property 측정 JSON 저장 (#1760).
    mangle_report_path: ?[]const u8 = null,
    analyze: bool = false,
    legal_comments: @import("zntc_lib").bundler.types.LegalComments = .default,
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
    /// RN view config codegen — `*NativeComponent.{js,ts}` 의 `codegenNativeComponent`
    /// 호출을 inline view config 로 교체. `@react-native/codegen` 등가 (#2348).
    codegen_transform: bool = false,
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
    /// --watch-folder=DIR (반복): 번들 그래프 밖의 디렉토리를 감시 루트에 추가.
    /// Metro의 watchFolders에 대응. 내부 표현은 roots + include/exclude로 일반화되어
    /// 나중에 Rollup/Vite의 watch.include/exclude 스펙도 같은 필드로 매핑된다.
    watch_roots_list: std.ArrayList([]const u8) = .empty,
    /// --watch-include=GLOB (반복): roots 스캔 시 포함할 파일 glob 화이트리스트.
    watch_include_list: std.ArrayList([]const u8) = .empty,
    /// --watch-exclude=GLOB (반복): roots 스캔 시 제외할 파일 glob.
    watch_exclude_list: std.ArrayList([]const u8) = .empty,
    /// --clean: 빌드 전 출력 디렉토리 정리
    clean: bool = false,
    /// --jobs=N: 병렬 워커 스레드 수 (0=기본값/CPU코어수, 1=단일스레드)
    max_threads: u32 = 0,
    /// --preserve-modules: 모듈 1개 = 출력 파일 1개 (라이브러리 빌드용)
    preserve_modules: bool = false,
    /// --preserve-modules-root=<dir>: 출력 디렉토리 구조의 기준 경로
    preserve_modules_root: ?[]const u8 = null,
    /// --globals=SPEC=GLOBAL (rollup output.globals 호환, #1824).
    /// IIFE 포맷에서 external specifier → 전역 식별자 매핑. 반복/comma 분리 지원.
    /// 예: `--globals react=React --globals react-dom=ReactDOM`
    ///     `--globals=react=React,react-dom=ReactDOM`
    /// ArrayList 로 보관하고 BundleOptions 에 slice 로 전달. dedupe/정규화는 emitter 단에서.
    globals_list: std.ArrayList(lib.bundler.types.GlobalEntry) = .empty,
    /// inlineDynamicImports: dynamic import target 을 entry chunk 에 인라인 (Rollup 호환).
    /// CLI: `--inline-dynamic-imports` / config.json: `inlineDynamicImports`.
    inline_dynamic_imports: bool = false,
    /// 사용자가 `inline_dynamic_imports` 를 명시했는지. true / false 둘 다 추적 —
    /// 명시 false + single-file output 일 때 자동 승격을 막아야 의도가 보존됨 (#2209).
    inline_dynamic_imports_explicit: bool = false,

    const RnPlatform = enum {
        none,
        ios,
        android,
    };

    const AliasEntry = BundleOptions.AliasEntry;
    const FallbackEntry = @import("zntc_lib").bundler.types.FallbackEntry;
    const LoaderOverride = @import("zntc_lib").bundler.types.LoaderOverride;
    const ParsedLoader = @import("zntc_lib").bundler.types.ParsedLoader;
    const LegalCommentsEnum = @import("zntc_lib").bundler.types.LegalComments;
    const ManualChunkEntry = @import("zntc_lib").bundler.types.ManualChunkEntry;

    const LogLevel = enum {
        silent,
        @"error",
        warning,
        info,
        debug,
        verbose,
    };

    pub fn deinit(self: *CliOptions, alloc: std.mem.Allocator) void {
        self.extra_inputs.deinit(alloc);
        self.external_list.deinit(alloc);
        self.define_list.deinit(alloc);
        self.conditions_list.deinit(alloc);
        self.alias_list.deinit(alloc);
        self.fallback_list.deinit(alloc);
        self.manual_chunks_list.deinit(alloc);
        self.block_list.deinit(alloc);
        self.loader_list.deinit(alloc);
        for (self.inject_list.items) |p| alloc.free(p);
        self.inject_list.deinit(alloc);
        for (self.run_before_main_list.items) |p| alloc.free(p);
        self.run_before_main_list.deinit(alloc);
        for (self.polyfill_list.items) |p| alloc.free(p);
        self.polyfill_list.deinit(alloc);
        self.global_identifier_list.deinit(alloc);
        self.proxy_list.deinit(alloc);
        self.resolve_extensions_list.deinit(alloc);
        self.main_fields_list.deinit(alloc);
        self.drop_labels_list.deinit(alloc);
        self.pure_list.deinit(alloc);
        self.node_paths_list.deinit(alloc);
        for (self.watch_roots_list.items) |p| alloc.free(p);
        self.watch_roots_list.deinit(alloc);
        self.watch_include_list.deinit(alloc);
        self.watch_exclude_list.deinit(alloc);
        self.globals_list.deinit(alloc);
    }
};

/// `--globals SPEC=GLOBAL` 인자를 파싱하여 `opts.globals_list` 에 추가한다.
/// comma 로 여러 항목 구분 가능. 유효하지 않으면 stderr 에 경고 후 무시.
fn parseGlobalsArg(opts: *CliOptions, allocator: std.mem.Allocator, val: []const u8, stderr: anytype) !void {
    var it = std.mem.splitScalar(u8, val, ',');
    while (it.next()) |part| {
        if (part.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, part, '=') orelse {
            try stderr.print("zntc: --globals requires SPEC=GLOBAL format: '{s}' (skipped)\n", .{part});
            continue;
        };
        const spec = part[0..eq];
        const name = part[eq + 1 ..];
        if (spec.len == 0 or name.len == 0) {
            try stderr.print("zntc: --globals empty spec or name: '{s}' (skipped)\n", .{part});
            continue;
        }
        try opts.globals_list.append(allocator, .{ .specifier = spec, .global_name = name });
    }
}

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

/// `zntc.config.json`이 cwd에 있으면 파싱해 opts의 defaults를 세팅한다.
/// CLI 인자가 뒤에서 이 값을 덮어쓴다 → "CLI > config.json".
///
/// 매핑되는 필드:
///  - TranspileOptions: target/sourcemap/minify/jsx/platform/format/quotes/drop/flow 등
///  - bundler-only (#2105): external/alias/define/loader/conditions/resolveExtensions/
///    mainFields/banner/footer/{asset,chunk,entry}Names/preserveModules*/inlineDynamicImports/
///    manualChunks (record form)
///
/// `intro`/`outro` 는 BundleOptions 미지원 — 별도 PR (FIXME). function-form
/// `manualChunks` 는 JS-only 라 JSON 에서는 record form 만 받는다.
fn applyZntcConfigJson(opts: *CliOptions, allocator: std.mem.Allocator) !void {
    const f = try std.fs.cwd().openFile("zntc.config.json", .{});
    defer f.close();
    const content = try f.readToEndAlloc(allocator, 1 * 1024 * 1024);
    defer allocator.free(content);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    // raw DTO 파싱 — `optionsFromJson` 은 TranspileOptions 만 추출하므로 bundler-only
    // 필드를 동시에 매핑하려면 DTO 직접 파싱이 필요.
    const dto = std.json.parseFromSliceLeaky(
        lib.transpile.ConfigOptionsDto,
        arena_alloc,
        content,
        .{ .ignore_unknown_fields = true },
    ) catch return error.InvalidConfig;

    // ─── TranspileOptions-shaped 필드 ──────────────────────────────────────
    // optionsFromJson 과 공유 helper — silent drift 차단. dto 명시 시 항상 override
    // (boolean 필드도 false 명시 가능). string 은 config 수명 만료 후 살아남도록 dupe.
    try lib.transpile.applyTranspileSharedFields(opts, &dto, allocator, true);

    // ─── bundler-only 필드 (#2105) ─────────────────────────────────────────
    if (dto.external) |list| for (list) |s| {
        try opts.external_list.append(allocator, try allocator.dupe(u8, s));
    };
    if (dto.alias) |list| for (list) |a| {
        try opts.alias_list.append(allocator, .{
            .from = try allocator.dupe(u8, a.from),
            .to = try allocator.dupe(u8, a.to),
        });
    };
    if (dto.define) |list| for (list) |d| {
        try opts.define_list.append(allocator, .{
            .key = try allocator.dupe(u8, d.key),
            .value = try allocator.dupe(u8, d.value),
        });
    };
    if (dto.loader) |list| for (list) |l| {
        const parsed_loader = lib.bundler.types.ParsedLoader.fromString(l.loader) orelse continue;
        try opts.loader_list.append(allocator, .{
            .ext = try allocator.dupe(u8, l.ext),
            .loader = parsed_loader.loader,
            .module_type = parsed_loader.module_type,
        });
    };
    if (dto.conditions) |list| for (list) |s| {
        try opts.conditions_list.append(allocator, try allocator.dupe(u8, s));
    };
    if (dto.resolveExtensions) |list| for (list) |s| {
        try opts.resolve_extensions_list.append(allocator, try allocator.dupe(u8, s));
    };
    if (dto.mainFields) |list| for (list) |s| {
        try opts.main_fields_list.append(allocator, try allocator.dupe(u8, s));
    };
    if (dto.banner) |s| if (s.len > 0) {
        opts.banner_js = try allocator.dupe(u8, s);
    };
    if (dto.footer) |s| if (s.len > 0) {
        opts.footer_js = try allocator.dupe(u8, s);
    };
    if (dto.entryNames) |s| if (s.len > 0) {
        opts.entry_names = try allocator.dupe(u8, s);
    };
    if (dto.chunkNames) |s| if (s.len > 0) {
        opts.chunk_names = try allocator.dupe(u8, s);
    };
    if (dto.assetNames) |s| if (s.len > 0) {
        opts.asset_names = try allocator.dupe(u8, s);
    };
    if (dto.preserveModules == true) opts.preserve_modules = true;
    if (dto.preserveModulesRoot) |s| if (s.len > 0) {
        opts.preserve_modules_root = try allocator.dupe(u8, s);
    };
    if (dto.inlineDynamicImports) |v| {
        opts.inline_dynamic_imports = v;
        opts.inline_dynamic_imports_explicit = true;
    }
    // manualChunks: record form 매핑 — `[{name, patterns}]`. function form 은 JS-only.
    if (dto.manualChunks) |list| for (list) |e| {
        const patterns = try allocator.alloc([]const u8, e.patterns.len);
        for (e.patterns, 0..) |p, i| patterns[i] = try allocator.dupe(u8, p);
        try opts.manual_chunks_list.append(allocator, .{
            .name = try allocator.dupe(u8, e.name),
            .patterns = patterns,
        });
    };
}

/// CLI 인자를 파싱하여 CliOptions를 반환한다.
/// --help 출력이나 파싱 에러로 프로그램을 종료해야 하면 null을 반환한다.
pub fn parseCliArguments(args: []const []const u8, allocator: std.mem.Allocator) !?CliOptions {
    const stdout = std.fs.File.stdout().deprecatedWriter();
    const stderr = std.fs.File.stderr().deprecatedWriter();

    if (args.len < 2) {
        try usage_cli.printUsage(stdout);
        return null;
    }

    var opts = CliOptions{};
    // zntc.config.json이 있으면 defaults를 그쪽으로 초기화. CLI 인자는 뒤에서
    // 파싱되며 이 값을 덮어쓴다 ("CLI > config" 우선순위).
    applyZntcConfigJson(&opts, allocator) catch |err| switch (err) {
        error.FileNotFound => {},
        else => {
            try stderr.print("[zntc] zntc.config.json load failed: {}\n", .{err});
        },
    };

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
                try stderr.print("zntc: --define requires KEY=VALUE format: {s}\n", .{arg});
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
                try stderr.print("zntc: invalid --quotes value: {s} (expected: double, single, preserve)\n", .{val});
                std.process.exit(1);
            }
        } else if (std.mem.eql(u8, arg, "--sourcemap")) {
            opts.sourcemap = true;
            opts.sourcemap_mode = .linked;
        } else if (std.mem.startsWith(u8, arg, "--sourcemap=")) {
            // #2152 — `--sourcemap=linked|external|inline` 3-mode (esbuild/rolldown 호환).
            opts.sourcemap = true;
            const val = arg["--sourcemap=".len..];
            opts.sourcemap_mode = lib.codegen.sourcemap.SourceMapMode.fromString(val) orelse {
                try stderr.print("zntc: invalid --sourcemap value: {s} (expected: linked, external, inline)\n", .{val});
                std.process.exit(1);
            };
        } else if (std.mem.startsWith(u8, arg, "--output-exports=")) {
            // #2159 — `--output-exports=auto|named|default|none`
            const val = arg["--output-exports=".len..];
            opts.output_exports = lib.bundler.OutputExports.fromString(val) orelse {
                try stderr.print("zntc: invalid --output-exports value: {s} (expected: auto, named, default, none)\n", .{val});
                std.process.exit(1);
            };
        } else if (std.mem.eql(u8, arg, "--sourcemap-debug-ids")) {
            opts.sourcemap_debug_ids = true;
        } else if (std.mem.eql(u8, arg, "--sourcemap-function-map")) {
            opts.sourcemap_function_map = true;
        } else if (std.mem.eql(u8, arg, "--project") or std.mem.eql(u8, arg, "-p") or
            std.mem.eql(u8, arg, "--tsconfig-path"))
        {
            // `-p`, `--project` (tsc 전통), `--tsconfig-path` (NAPI 의 `tsconfigPath` 와 통일) 모두 지원.
            if (i + 1 < args.len) {
                i += 1;
                opts.project_path = args[i];
            }
        } else if (std.mem.startsWith(u8, arg, "--tsconfig-path=")) {
            opts.project_path = arg["--tsconfig-path=".len..];
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
            // CLI vocab: classic / automatic / automatic-dev / preserve. tsconfig vocab
            // (`react-jsx` / `react-jsxdev` / `react-native`) 은 CLI 가 받지 않음 —
            // `tsconfig_merge` 가 처리. unknown 값은 `.classic` 으로 silent fallback
            // (기존 동작 보존, NAPI 의 strict throw 와 의도적으로 다름).
            const val = arg["--jsx=".len..];
            opts.jsx_runtime = lib.codegen.codegen.JsxRuntime.fromString(val) orelse .classic;
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
        } else if (std.mem.startsWith(u8, arg, "--profile=")) {
            opts.profile_csv = arg["--profile=".len..];
        } else if (std.mem.startsWith(u8, arg, "--profile-level=")) {
            opts.profile_level = arg["--profile-level=".len..];
        } else if (std.mem.startsWith(u8, arg, "--profile-format=")) {
            opts.profile_format = arg["--profile-format=".len..];
        } else if (std.mem.startsWith(u8, arg, "--stop-after=")) {
            const val = arg["--stop-after=".len..];
            opts.core_stop_after = lib.transpile.StopAfter.fromString(val) orelse {
                try stderr.print("zntc: invalid --stop-after='{s}' (expected scan|parse|semantic|transform|codegen)\n", .{val});
                std.process.exit(1);
            };
        } else if (std.mem.eql(u8, arg, "--bundle")) {
            opts.is_bundle = true;
        } else if (std.mem.eql(u8, arg, "--serve")) {
            opts.is_serve = true;
        } else if (std.mem.eql(u8, arg, "--port")) {
            if (i + 1 < args.len) {
                i += 1;
                opts.serve_port = std.fmt.parseInt(u16, args[i], 10) catch {
                    try stderr.print("zntc: invalid port number: {s}\n", .{args[i]});
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
                    try stderr.print("zntc: --proxy requires PATH=TARGET format (e.g. /api=http://localhost:8080)\n", .{});
                    std.process.exit(1);
                }
            } else {
                try stderr.print("zntc: --proxy requires a PATH=TARGET argument\n", .{});
                std.process.exit(1);
            }
        } else if (std.mem.eql(u8, arg, "--splitting")) {
            opts.splitting = true;
        } else if (std.mem.eql(u8, arg, "--preserve-modules")) {
            opts.preserve_modules = true;
        } else if (std.mem.startsWith(u8, arg, "--preserve-modules-root=")) {
            opts.preserve_modules_root = arg["--preserve-modules-root=".len..];
        } else if (std.mem.eql(u8, arg, "--inline-dynamic-imports")) {
            // Rollup `inlineDynamicImports` 호환 — dynamic import target 을 entry 에 인라인.
            opts.inline_dynamic_imports = true;
            opts.inline_dynamic_imports_explicit = true;
        } else if (std.mem.eql(u8, arg, "--no-inline-dynamic-imports")) {
            // 명시적으로 인라인 끄기. single-file output + dynamic import 와 함께면
            // 자동 승격이 막히고 명확한 에러로 분리 정책 (--splitting / --preserve-modules)
            // 선택을 요구.
            opts.inline_dynamic_imports = false;
            opts.inline_dynamic_imports_explicit = true;
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
        } else if (std.mem.startsWith(u8, arg, "--external:")) {
            // esbuild 호환: --external:react (콜론 형식)
            const val = arg["--external:".len..];
            if (val.len > 0) {
                try opts.external_list.append(allocator, val);
            }
        } else if (std.mem.eql(u8, arg, "--globals")) {
            // --globals react=React (다음 인자)
            if (i + 1 < args.len) {
                i += 1;
                try parseGlobalsArg(&opts, allocator, args[i], stderr);
            }
        } else if (std.mem.startsWith(u8, arg, "--globals=")) {
            const val = arg["--globals=".len..];
            if (val.len > 0) try parseGlobalsArg(&opts, allocator, val, stderr);
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
                try stderr.print("zntc: unknown --rn-platform '{s}' (expected: ios, android)\n", .{val});
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
        } else if (std.mem.eql(u8, arg, "--verbatim-module-syntax")) {
            opts.verbatim_module_syntax = true;
        } else if (std.mem.eql(u8, arg, "--verbatim-module-syntax=false")) {
            opts.verbatim_module_syntax = false;
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
                    try stderr.print("zntc: unknown target '{s}'\n", .{val});
                    std.process.exit(1);
                };
            }
        } else if (std.mem.eql(u8, arg, "--preserve-symlinks")) {
            opts.preserve_symlinks = true;
        } else if (std.mem.eql(u8, arg, "--disable-hierarchical-lookup")) {
            opts.disable_hierarchical_lookup = true;
        } else if (std.mem.startsWith(u8, arg, "--alias:")) {
            // --alias:react=preact/compat (esbuild 호환)
            const kv = arg["--alias:".len..];
            if (std.mem.indexOf(u8, kv, "=")) |eq_pos| {
                try opts.alias_list.append(allocator, .{
                    .from = kv[0..eq_pos],
                    .to = kv[eq_pos + 1 ..],
                });
            } else {
                try stderr.print("zntc: --alias requires FROM=TO format: {s}\n", .{arg});
                std.process.exit(1);
            }
        } else if (std.mem.startsWith(u8, arg, "--block-list=")) {
            try opts.block_list.append(allocator, arg["--block-list=".len..]);
        } else if (std.mem.startsWith(u8, arg, "--fallback:")) {
            // --fallback:crypto=crypto-browserify (webpack resolve.fallback 호환)
            // --fallback:fs=false → 빈 모듈
            const kv = arg["--fallback:".len..];
            if (std.mem.indexOf(u8, kv, "=")) |eq_pos| {
                const value = kv[eq_pos + 1 ..];
                try opts.fallback_list.append(allocator, .{
                    .from = kv[0..eq_pos],
                    .to = if (std.mem.eql(u8, value, "false")) null else value,
                });
            } else {
                try stderr.print("zntc: --fallback requires NAME=PATH or NAME=false: {s}\n", .{arg});
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
                try stderr.print("zntc: unknown log-level '{s}' (expected: silent, error, warning, info, debug, verbose)\n", .{val});
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
        } else if (std.mem.startsWith(u8, arg, "--asset-registry=")) {
            opts.asset_registry = arg["--asset-registry=".len..];
        } else if (std.mem.eql(u8, arg, "--no-asset-registry")) {
            opts.asset_registry = null;
            opts.asset_registry_explicit_off = true;
        } else if (std.mem.startsWith(u8, arg, "--metafile=")) {
            opts.metafile_path = arg["--metafile=".len..];
        } else if (std.mem.eql(u8, arg, "--metafile")) {
            opts.metafile_path = "meta.json";
        } else if (std.mem.startsWith(u8, arg, "--mangle-report=")) {
            opts.mangle_report_path = arg["--mangle-report=".len..];
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
                try stderr.print("zntc: --log-limit requires a number: {s}\n", .{val});
                std.process.exit(1);
            };
        } else if (std.mem.startsWith(u8, arg, "--line-limit=")) {
            const val = arg["--line-limit=".len..];
            opts.line_limit = std.fmt.parseInt(u32, val, 10) catch {
                try stderr.print("zntc: --line-limit requires a number: {s}\n", .{val});
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
                try stderr.print("zntc: --watch-delay requires a number (ms): {s}\n", .{val});
                std.process.exit(1);
            };
        } else if (std.mem.startsWith(u8, arg, "--watch-folder=")) {
            const raw = arg["--watch-folder=".len..];
            const abs = std.fs.cwd().realpathAlloc(allocator, raw) catch {
                try stderr.print("zntc: cannot resolve --watch-folder path: {s}\n", .{raw});
                std.process.exit(1);
            };
            try opts.watch_roots_list.append(allocator, abs);
        } else if (std.mem.startsWith(u8, arg, "--watch-include=")) {
            try opts.watch_include_list.append(allocator, arg["--watch-include=".len..]);
        } else if (std.mem.startsWith(u8, arg, "--watch-exclude=")) {
            try opts.watch_exclude_list.append(allocator, arg["--watch-exclude=".len..]);
        } else if (std.mem.eql(u8, arg, "--clean")) {
            opts.clean = true;
        } else if (std.mem.startsWith(u8, arg, "--jobs=")) {
            const val = arg["--jobs=".len..];
            opts.max_threads = std.fmt.parseInt(u32, val, 10) catch {
                try stderr.print("zntc: --jobs requires a number: {s}\n", .{val});
                std.process.exit(1);
            };
        } else if (std.mem.startsWith(u8, arg, "--inject:") or
            std.mem.startsWith(u8, arg, "--run-before-main=") or
            std.mem.startsWith(u8, arg, "--polyfill="))
        {
            // 경로 기반 옵션 공통 처리: 값 추출 → 절대 경로 변환 → 대상 리스트에 추가
            const sep_pos = std.mem.indexOfScalar(u8, arg, ':') orelse std.mem.indexOfScalar(u8, arg, '=').?;
            const option_name = arg[0 .. sep_pos + 1];
            const raw_path = arg[sep_pos + 1 ..];
            const abs = std.fs.cwd().realpathAlloc(allocator, raw_path) catch {
                try stderr.print("zntc: cannot resolve {s} path: {s}\n", .{ option_name, raw_path });
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
                try stderr.print("zntc: unknown legal-comments mode '{s}' (expected: none, inline, eof, linked, external)\n", .{val});
                std.process.exit(1);
            };
            opts.legal_comments_explicit = true;
            if (opts.legal_comments == .linked or opts.legal_comments == .external) {
                try stderr.print("zntc: --legal-comments={s} is not yet fully implemented, falling back to eof behavior\n", .{val});
            }
        } else if (std.mem.startsWith(u8, arg, "--loader:")) {
            // --loader:.png=file (esbuild 호환)
            const kv = arg["--loader:".len..];
            if (std.mem.indexOf(u8, kv, "=")) |eq_pos| {
                const ext_str = kv[0..eq_pos];
                const loader_str = kv[eq_pos + 1 ..];
                if (CliOptions.ParsedLoader.fromString(loader_str)) |parsed_loader| {
                    try opts.loader_list.append(allocator, .{
                        .ext = ext_str,
                        .loader = parsed_loader.loader,
                        .module_type = parsed_loader.module_type,
                    });
                } else {
                    try stderr.print("zntc: unknown loader '{s}' (expected: file, dataurl, base64, text, binary, copy, json, css, empty, js, jsx, ts, tsx)\n", .{loader_str});
                    std.process.exit(1);
                }
            } else {
                try stderr.print("zntc: --loader requires .EXT=TYPE format: {s}\n", .{arg});
                std.process.exit(1);
            }
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try usage_cli.printUsage(stdout);
            return null;
        } else if (arg[0] != '-' or (arg.len == 1 and arg[0] == '-')) {
            if (opts.input_file == null) {
                opts.input_file = arg;
            } else {
                try opts.extra_inputs.append(allocator, arg);
            }
        } else {
            try stderr.print("zntc: unknown option: {s}\n", .{arg});
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

    // #2209: single-file output 모드에서 dynamic import 가 있으면 자동으로 entry chunk
    // 에 인라인 (esbuild 호환). graph.zig::promoteExportsKinds Pass 4 가 dynamic
    // target 을 `wrap_kind = .esm` 으로 promote → emitter 가 `import("./x")` 호출을
    // `init_x()` + `x_exports` 로 재작성. 이렇게 안 하면 default 모드에서 dynamic
    // target 이 inline 됐는데 호출은 외부 path 그대로 남아 `Cannot find module` 에러.
    if (opts.is_bundle and !opts.splitting and !opts.preserve_modules) {
        if (!opts.inline_dynamic_imports_explicit) {
            // 명시 안 함 — 자동 승격 (esbuild 호환).
            opts.inline_dynamic_imports = true;
        } else if (!opts.inline_dynamic_imports) {
            // 명시 false + single-file 은 논리 모순 (어떤 번들러도 처리 안 함).
            // 자동 승격 대신 명확한 에러로 분리 정책 (--splitting / --preserve-modules)
            // 선택을 요구.
            try stderr.print(
                "error: --no-inline-dynamic-imports requires --splitting or --preserve-modules in bundle mode\n",
                .{},
            );
            return error.InvalidArgs;
        }
    }

    // 자동 define:
    //   - `--bundle` + browser/react-native: esbuild 호환 — DOM/Metro 환경은 build-time 결정.
    //   - `--bundle` + `--minify-syntax`: Vite 호환 — 프로덕션 배포 의도 신호로 간주(#1552).
    // 트랜스파일 모드에서는 적용하지 않음. 사용자가 --define: 으로 명시 지정한 키는 덮어쓰지 않음.
    // Node 서버 번들에서 runtime NODE_ENV를 원하면 `--minify-syntax` 없이 `--bundle`만 쓰거나
    // `--define:process.env.NODE_ENV=process.env.NODE_ENV`로 identity 지정.
    if (opts.is_bundle and (opts.platform.isBrowserLike() or opts.minify_syntax)) {
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
