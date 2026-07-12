const std = @import("std");
const app_env = @import("env.zig");
const bundler_mod = @import("../bundler/mod.zig");
const rich_diagnostic = @import("../rich_diagnostic.zig");
const transformer_mod = @import("../transformer/transformer.zig");

const Bundler = bundler_mod.Bundler;
const BundleOptions = bundler_mod.BundleOptions;
const bundler_types = bundler_mod.types;
const css_scanner = bundler_mod.css_scanner;
const wyhash = @import("../util/wyhash.zig");
const Plugin = bundler_mod.plugin.Plugin;
const DefineEntry = transformer_mod.DefineEntry;
const JsxRuntime = @import("../codegen/codegen.zig").JsxRuntime;

/// app build / dev 의 JSX runtime 설정. `zntc --bundle` 과 동일 vocab. caller
/// (cli/app.zig) 가 CLI 옵션 + tsconfig 를 머지해 확정값을 전달한다.
pub const JsxConfig = struct {
    runtime: JsxRuntime = .classic,
    import_source: []const u8 = "react",
    factory: []const u8 = "React.createElement",
    fragment: []const u8 = "React.Fragment",
};

pub const AppBuildOptions = struct {
    root: []const u8 = ".",
    outdir: []const u8 = "dist",
    entry_html: []const u8 = "index.html",
    public_dir: ?[]const u8 = "public",
    base: []const u8 = "/",
    mode: []const u8 = "production",
    env_dir: ?[]const u8 = null,
    env_prefixes: []const []const u8 = &.{ "VITE_", "ZNTC_" },
    define: []const DefineEntry = &.{},
    minify: bool = false,
    sourcemap: bool = false,
    splitting: bool = true,
    jsx: JsxConfig = .{},
    /// styled-components 1st-party transform 활성화 (compiler.styledComponents).
    styled_components: bool = false,
    /// styled-components.ssr 옵션 — false 면 componentId 생략.
    styled_components_ssr: bool = true,
    /// styled-components.minify 옵션 — CSS template whitespace collapse.
    styled_components_minify: bool = false,
    /// styled-components.fileName 옵션 — displayName 에 `<basename>__` prefix.
    styled_components_file_name: bool = true,
    /// styled-components.pure 옵션 — `/* @__PURE__ */` annotation (tree-shaking).
    styled_components_pure: bool = false,
    /// styled-components.namespace 옵션 — componentId 에 `<namespace>__` prefix.
    styled_components_namespace: []const u8 = "",
    /// styled-components.meaninglessFileNames 옵션 — basename fallback list (default `["index"]`).
    styled_components_meaningless_file_names: []const []const u8 = &.{"index"},
    /// styled-components.topLevelImportPaths 옵션 — vendored fork import source list.
    styled_components_top_level_import_paths: []const []const u8 = &.{},
    /// styled-components.cssProp 옵션 — `<div css={...}>` JSX prop 을 styled component
    /// 로 extract. transform 구현은 후속 PR — 현재는 옵션 surface 만.
    styled_components_css_prop: bool = false,
    /// emotion 1st-party transform (compiler.emotion).
    emotion: bool = false,
    /// emotion.autoLabel 모드 — `.never` / `.always` (default) / `.dev_only`.
    emotion_auto_label: @import("../transformer/transformer.zig").AutoLabelMode = .always,
    /// emotion.sourceMap 옵션 — true 면 css 템플릿 끝에 inline sourceMap 주석을 append.
    emotion_source_map: bool = false,
    /// emotion.labelFormat 옵션 — label 포맷 템플릿.
    emotion_label_format: []const u8 = "",
    /// emotion.importMap re-export 케이스 단순화 — vendored emotion css source.
    emotion_extra_css_sources: []const []const u8 = &.{},
    /// emotion.importMap re-export 케이스 단순화 — vendored emotion styled source.
    emotion_extra_styled_sources: []const []const u8 = &.{},
    /// 확장자별 로더 오버라이드 (--loader:.ttf=file). 앱 빌더도 번들러와 동일한
    /// loader vocab 을 받는다 — 예전엔 `zntc build` 가 --loader 를 아예 거부해
    /// CSS/JS 가 참조하는 자산을 제어할 방법이 없었다 (#4466).
    loader_overrides: []const bundler_types.LoaderOverride = &.{},
    /// 에셋 파일명 패턴 (--asset-names).
    asset_names: []const u8 = "[name]-[hash]",
    /// 이 크기(byte) 이하의 asset 은 data URL 로 인라인 (--asset-inline-limit).
    /// 0 = 인라인 끔. 기본 4096 (#4466).
    asset_inline_limit: u32 = bundler_types.default_asset_inline_limit,
    /// JS plugin dispatcher 들 — `napiBuildAppSync` 의 `_pluginDispatcherSync` 를
    /// 통해 전달. 비어 있으면 plugin 없는 build. bundle pipeline 의 Bundler.init 에
    /// 그대로 전달 (#2538 4-4 PR-1).
    plugins: []const Plugin = &.{},
};

pub const AppDevPrepareOptions = struct {
    root: []const u8 = ".",
    outdir: []const u8 = ".zntc-dev",
    entry_html: []const u8 = "index.html",
    public_dir: ?[]const u8 = "public",
    base: []const u8 = "/",
    mode: []const u8 = "development",
    env_dir: ?[]const u8 = null,
    env_prefixes: []const []const u8 = &.{ "VITE_", "ZNTC_" },
};

pub const AppDevPrepareResult = struct {
    entry_path: []const u8,
    output_count: usize,

    pub fn deinit(self: *AppDevPrepareResult, allocator: std.mem.Allocator) void {
        allocator.free(self.entry_path);
    }
};

const HtmlEntry = struct {
    module_scripts: std.ArrayList([]const u8) = .empty,
    stylesheets: std.ArrayList([]const u8) = .empty,
    asset_refs: std.ArrayList([]const u8) = .empty,

    fn deinit(self: *HtmlEntry, allocator: std.mem.Allocator) void {
        self.module_scripts.deinit(allocator);
        self.stylesheets.deinit(allocator);
        self.asset_refs.deinit(allocator);
    }
};

pub fn buildApp(allocator: std.mem.Allocator, io: std.Io, opts: AppBuildOptions) !usize {
    const root = try std.fs.path.resolve(allocator, &.{opts.root});
    defer allocator.free(root);
    const outdir = try std.fs.path.resolve(allocator, &.{ root, opts.outdir });
    defer allocator.free(outdir);
    const html_path = try std.fs.path.resolve(allocator, &.{ root, opts.entry_html });
    defer allocator.free(html_path);
    const html_dir = std.fs.path.dirname(html_path) orelse root;
    const base = try normalizeBase(allocator, opts.base);
    defer allocator.free(base);

    const raw_html = try std.Io.Dir.cwd().readFileAlloc(io, html_path, allocator, std.Io.Limit.limited(10 * 1024 * 1024));
    defer allocator.free(raw_html);

    var html_entry = try parseHtmlEntry(allocator, raw_html);
    defer html_entry.deinit(allocator);
    if (html_entry.module_scripts.items.len == 0) return error.MissingModuleScript;

    try std.Io.Dir.cwd().createDirPath(io, outdir);

    const entry_points = try allocator.alloc([]const u8, html_entry.module_scripts.items.len);
    defer {
        for (entry_points) |p| allocator.free(p);
        allocator.free(entry_points);
    }
    for (html_entry.module_scripts.items, 0..) |src, i| {
        entry_points[i] = (try resolveHtmlRef(allocator, root, html_dir, src)) orelse return error.UnsupportedEntryUrl;
    }

    var env_map = try app_env.loadEnv(allocator, io, .{
        .mode = opts.mode,
        .env_dir = opts.env_dir orelse root,
        .prefixes = opts.env_prefixes,
    });
    defer app_env.deinitMap(&env_map, allocator);

    const env_defines = try app_env.envToDefine(allocator, &env_map, opts.mode, base);
    defer app_env.freeDefines(allocator, env_defines);
    const merged_defines = try mergeDefines(allocator, env_defines, opts.define);
    defer allocator.free(merged_defines);

    var bundler = Bundler.init(allocator, .{
        .entry_points = entry_points,
        .format = .esm,
        .platform = .browser,
        .define = merged_defines,
        .minify_whitespace = opts.minify,
        .minify_identifiers = opts.minify,
        .minify_syntax = opts.minify,
        .code_splitting = opts.splitting,
        .sourcemap = .{ .enable = opts.sourcemap },
        .public_path = base,
        // PR B-4b sub-2: zntc bundler default 가 `[dir]/[name]` 으로 변경됐으나
        // app-builder 는 HTML link rewrite(`href="/src/main.css"`) 호환 위해
        // flat `[name]` 유지 — 별도 명시. 동기화는 sub-3 에서 (app-builder
        // semver/UX 정책 결정과 함께).
        .entry_names = if (opts.splitting) "[name]-[hash]" else "[name]",
        .chunk_names = "[name]-[hash]",
        .asset_names = opts.asset_names,
        .asset_inline_limit = opts.asset_inline_limit,
        .loader_overrides = opts.loader_overrides,
        .css_names = "[name]",
        .output_filename = "bundle.js",
        .root_dir = root,
        .jsx_runtime = opts.jsx.runtime,
        .jsx_import_source = opts.jsx.import_source,
        .jsx_factory = opts.jsx.factory,
        .jsx_fragment = opts.jsx.fragment,
        .styled_components = opts.styled_components,
        .styled_components_ssr = opts.styled_components_ssr,
        .styled_components_minify = opts.styled_components_minify,
        .styled_components_file_name = opts.styled_components_file_name,
        .styled_components_pure = opts.styled_components_pure,
        .styled_components_namespace = opts.styled_components_namespace,
        .styled_components_meaningless_file_names = opts.styled_components_meaningless_file_names,
        .styled_components_top_level_import_paths = opts.styled_components_top_level_import_paths,
        .styled_components_css_prop = opts.styled_components_css_prop,
        .emotion = opts.emotion,
        .emotion_auto_label = opts.emotion_auto_label,
        .emotion_source_map = opts.emotion_source_map,
        .emotion_label_format = opts.emotion_label_format,
        .emotion_extra_css_sources = opts.emotion_extra_css_sources,
        .emotion_extra_styled_sources = opts.emotion_extra_styled_sources,
        .plugins = opts.plugins,
    });
    defer bundler.deinit();

    var result = try bundler.bundle(io);
    defer result.deinit(allocator);
    if (result.hasErrors()) {
        printAppBundleDiagnostics(result.getDiagnostics());
        return error.BundleFailed;
    }

    var reserved: std.StringHashMapUnmanaged(void) = .empty;
    defer reserved.deinit(allocator);
    var reserved_keys: std.ArrayList([]const u8) = .empty;
    defer {
        for (reserved_keys.items) |key| allocator.free(key);
        reserved_keys.deinit(allocator);
    }
    // 원본 자산 경로 → 출력 파일명. 같은 자산을 여러 곳에서 참조해도 한 번만
    // 기록하고, 서로 다른 자산이 basename 을 다투면 hash 로 구분한다 (#4466).
    var emitted_assets: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer {
        var it = emitted_assets.iterator();
        while (it.next()) |e| {
            allocator.free(e.key_ptr.*);
            allocator.free(e.value_ptr.*);
        }
        emitted_assets.deinit(allocator);
    }
    try addReserved(allocator, &reserved, &reserved_keys, "index.html");

    var output_count: usize = 0;
    if (result.outputs) |outs| {
        for (outs) |out| {
            try writeOutput(allocator, io, outdir, out.path, out.contents);
            try addReserved(allocator, &reserved, &reserved_keys, out.path);
            output_count += 1;
            // chunk 별 sourcemap — eager / lazy 두 분기 모두 OutputFile.getSourceMapJSON
            // 로 통합 처리 (caller 소유 slice 반환, free 책임).
            if (try out.getSourceMapJSON(allocator)) |sm| {
                defer allocator.free(sm);
                const map_path = try std.fmt.allocPrint(allocator, "{s}.map", .{out.path});
                defer allocator.free(map_path);
                try writeOutput(allocator, io, outdir, map_path, sm);
                try addReserved(allocator, &reserved, &reserved_keys, map_path);
                output_count += 1;
            }
        }
    } else {
        try writeOutput(allocator, io, outdir, "bundle.js", result.output);
        try addReserved(allocator, &reserved, &reserved_keys, "bundle.js");
        output_count += 1;
        if (result.sourcemap) |sm| {
            try writeOutput(allocator, io, outdir, "bundle.js.map", sm);
            try addReserved(allocator, &reserved, &reserved_keys, "bundle.js.map");
            output_count += 1;
        }
    }
    var emitted_css: std.ArrayList([]const u8) = .empty;
    defer emitted_css.deinit(allocator);
    if (result.asset_outputs) |outs| {
        for (outs) |out| {
            try writeOutput(allocator, io, outdir, out.path, out.contents);
            try addReserved(allocator, &reserved, &reserved_keys, out.path);
            if (std.mem.endsWith(u8, out.path, ".css")) try emitted_css.append(allocator, out.path);
            output_count += 1;
        }
    }

    var html: []const u8 = try allocator.dupe(u8, raw_html);
    defer allocator.free(html);
    {
        const next = try replaceEnvTokens(allocator, html, &env_map, opts.mode, base);
        allocator.free(html);
        html = next;
    }

    // Entry chunks are emitted sorted by `exec_order` (post-order DFS index),
    // not by `entry_points` array order. Match each `<script type="module">` to
    // its chunk via `module_ids` (chunk → entry path) so the script `src` is
    // rewritten to the correct hashed output even when one entry imports another.
    const default_script_output = if (result.outputs) |outs| outs[0].path else "bundle.js";
    for (html_entry.module_scripts.items, 0..) |src, i| {
        const script_output = if (result.outputs) |outs|
            findEntryOutputPath(outs, entry_points[i]) orelse default_script_output
        else
            default_script_output;
        const parts = splitUrl(src);
        const new_url = try joinBaseUrlWithSuffix(allocator, base, script_output, parts.suffix);
        defer allocator.free(new_url);
        const next = try replaceOwned(allocator, html, src, new_url);
        allocator.free(html);
        html = next;
    }

    if (opts.splitting) {
        if (result.outputs) |outs| {
            const next = try injectModulePreloads(allocator, html, outs, html_entry.module_scripts.items.len, base);
            allocator.free(html);
            html = next;
        }
    }

    for (html_entry.stylesheets.items) |href| {
        if (try resolveHtmlRef(allocator, root, html_dir, href)) |style_path| {
            defer allocator.free(style_path);
            const rel = try stylesheetRelFromRoot(allocator, root, style_path);
            defer allocator.free(rel);
            const href_parts = splitUrl(href);
            const already_emitted = reserved.contains(rel);
            if (!already_emitted) {
                const contents = try std.Io.Dir.cwd().readFileAlloc(io, style_path, allocator, std.Io.Limit.limited(10 * 1024 * 1024));
                defer allocator.free(contents);
                const rewritten_css = try rewriteCssUrls(allocator, io, contents, style_path, outdir, base, &reserved, &reserved_keys, &output_count, &emitted_assets);
                defer allocator.free(rewritten_css);
                try writeOutput(allocator, io, outdir, rel, rewritten_css);
                try addReserved(allocator, &reserved, &reserved_keys, rel);
                output_count += 1;
            }
            const new_url = try joinBaseUrlWithSuffix(allocator, base, rel, href_parts.suffix);
            defer allocator.free(new_url);
            const next = try replaceOwned(allocator, html, href, new_url);
            allocator.free(html);
            html = next;
        }
    }

    for (emitted_css.items) |css_path| {
        if (htmlReferencesPath(html, css_path)) continue;
        const css_url = try joinBaseUrl(allocator, base, css_path);
        defer allocator.free(css_url);
        const tag = try std.fmt.allocPrint(allocator, "<link rel=\"stylesheet\" href=\"{s}\">", .{css_url});
        defer allocator.free(tag);
        const next = try injectIntoHtml(allocator, html, tag);
        allocator.free(html);
        html = next;
    }

    for (html_entry.asset_refs.items) |ref| {
        if (ref.len == 0 or isExternalUrl(ref) or ref[0] == '#') continue;
        const parts = splitUrl(ref);
        var rel_owned = false;
        const rel_for_url = if (parts.path.len > 0 and parts.path[0] == '/') blk: {
            const root_asset_path = try std.fs.path.resolve(allocator, &.{ root, parts.path[1..] });
            defer allocator.free(root_asset_path);
            std.Io.Dir.cwd().access(io, root_asset_path, .{}) catch break :blk parts.path[1..];
            rel_owned = true;
            break :blk try copyAssetFile(allocator, io, root_asset_path, outdir, &reserved, &reserved_keys, &output_count, &emitted_assets);
        } else blk: {
            const asset_path = (try resolveHtmlRef(allocator, root, html_dir, ref)) orelse continue;
            defer allocator.free(asset_path);
            rel_owned = true;
            break :blk try copyAssetFile(allocator, io, asset_path, outdir, &reserved, &reserved_keys, &output_count, &emitted_assets);
        };
        defer if (rel_owned) allocator.free(rel_for_url);
        if (rel_for_url.len > 0) {
            const new_url = try joinBaseUrlWithSuffix(allocator, base, rel_for_url, parts.suffix);
            defer allocator.free(new_url);
            const next = try replaceOwned(allocator, html, ref, new_url);
            allocator.free(html);
            html = next;
        }
    }

    if (opts.public_dir) |public_dir| {
        const public_abs = try std.fs.path.resolve(allocator, &.{ root, public_dir });
        defer allocator.free(public_abs);
        try copyPublicDir(allocator, io, public_abs, outdir, &reserved, &output_count);
    }

    try writeOutput(allocator, io, outdir, "index.html", html);
    output_count += 1;
    return output_count;
}

pub fn prepareDev(allocator: std.mem.Allocator, io: std.Io, opts: AppDevPrepareOptions) !AppDevPrepareResult {
    const root = try std.fs.path.resolve(allocator, &.{opts.root});
    defer allocator.free(root);
    const outdir = try std.fs.path.resolve(allocator, &.{ root, opts.outdir });
    defer allocator.free(outdir);
    const html_path = try std.fs.path.resolve(allocator, &.{ root, opts.entry_html });
    defer allocator.free(html_path);
    const html_dir = std.fs.path.dirname(html_path) orelse root;
    const base = try normalizeBase(allocator, opts.base);
    defer allocator.free(base);

    const raw_html = try std.Io.Dir.cwd().readFileAlloc(io, html_path, allocator, std.Io.Limit.limited(10 * 1024 * 1024));
    defer allocator.free(raw_html);

    var html_entry = try parseHtmlEntry(allocator, raw_html);
    defer html_entry.deinit(allocator);
    if (html_entry.module_scripts.items.len == 0) return error.MissingModuleScript;

    const entry_path = (try resolveHtmlRef(allocator, root, html_dir, html_entry.module_scripts.items[0])) orelse return error.UnsupportedEntryUrl;
    errdefer allocator.free(entry_path);

    var env_map = try app_env.loadEnv(allocator, io, .{
        .mode = opts.mode,
        .env_dir = opts.env_dir orelse root,
        .prefixes = opts.env_prefixes,
    });
    defer app_env.deinitMap(&env_map, allocator);

    try std.Io.Dir.cwd().createDirPath(io, outdir);
    var reserved: std.StringHashMapUnmanaged(void) = .empty;
    defer reserved.deinit(allocator);
    var reserved_keys: std.ArrayList([]const u8) = .empty;
    defer {
        for (reserved_keys.items) |key| allocator.free(key);
        reserved_keys.deinit(allocator);
    }
    // 원본 자산 경로 → 출력 파일명. 같은 자산을 여러 곳에서 참조해도 한 번만
    // 기록하고, 서로 다른 자산이 basename 을 다투면 hash 로 구분한다 (#4466).
    var emitted_assets: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer {
        var it = emitted_assets.iterator();
        while (it.next()) |e| {
            allocator.free(e.key_ptr.*);
            allocator.free(e.value_ptr.*);
        }
        emitted_assets.deinit(allocator);
    }
    try addReserved(allocator, &reserved, &reserved_keys, "index.html");
    try addReserved(allocator, &reserved, &reserved_keys, "bundle.js");

    var html: []const u8 = try allocator.dupe(u8, raw_html);
    defer allocator.free(html);
    {
        const next = try replaceEnvTokens(allocator, html, &env_map, opts.mode, base);
        allocator.free(html);
        html = next;
    }
    const script_url = try joinBaseUrl(allocator, base, "bundle.js");
    defer allocator.free(script_url);
    {
        const next = try replaceOwned(allocator, html, html_entry.module_scripts.items[0], script_url);
        allocator.free(html);
        html = next;
    }

    var output_count: usize = 0;
    for (html_entry.stylesheets.items) |href| {
        if (try resolveHtmlRef(allocator, root, html_dir, href)) |style_path| {
            defer allocator.free(style_path);
            const rel = try stylesheetRelFromRoot(allocator, root, style_path);
            defer allocator.free(rel);
            const href_parts = splitUrl(href);
            const already_emitted = reserved.contains(rel);
            if (!already_emitted) {
                const contents = try std.Io.Dir.cwd().readFileAlloc(io, style_path, allocator, std.Io.Limit.limited(10 * 1024 * 1024));
                defer allocator.free(contents);
                const rewritten_css = try rewriteCssUrls(allocator, io, contents, style_path, outdir, base, &reserved, &reserved_keys, &output_count, &emitted_assets);
                defer allocator.free(rewritten_css);
                try writeOutput(allocator, io, outdir, rel, rewritten_css);
                try addReserved(allocator, &reserved, &reserved_keys, rel);
                output_count += 1;
            }
            const new_url = try joinBaseUrlWithSuffix(allocator, base, rel, href_parts.suffix);
            defer allocator.free(new_url);
            const next = try replaceOwned(allocator, html, href, new_url);
            allocator.free(html);
            html = next;
        }
    }
    if (opts.public_dir) |public_dir| {
        const public_abs = try std.fs.path.resolve(allocator, &.{ root, public_dir });
        defer allocator.free(public_abs);
        try copyPublicDir(allocator, io, public_abs, outdir, &reserved, &output_count);
    }
    try writeOutput(allocator, io, outdir, "index.html", html);
    output_count += 1;

    return .{ .entry_path = entry_path, .output_count = output_count };
}

fn mergeDefines(allocator: std.mem.Allocator, env_defines: []const app_env.DefineEntry, user_defines: []const DefineEntry) ![]DefineEntry {
    var user_keys: std.StringHashMapUnmanaged(void) = .empty;
    defer user_keys.deinit(allocator);
    try user_keys.ensureTotalCapacity(allocator, @intCast(user_defines.len));
    for (user_defines) |entry| user_keys.putAssumeCapacity(entry.key, {});

    var list: std.ArrayList(DefineEntry) = .empty;
    errdefer list.deinit(allocator);
    try list.ensureTotalCapacity(allocator, env_defines.len + user_defines.len);
    for (env_defines) |entry| {
        if (!user_keys.contains(entry.key)) list.appendAssumeCapacity(.{ .key = entry.key, .value = entry.value });
    }
    for (user_defines) |entry| list.appendAssumeCapacity(entry);
    return try list.toOwnedSlice(allocator);
}

fn normalizeBase(allocator: std.mem.Allocator, raw: []const u8) ![]const u8 {
    if (raw.len == 0) return allocator.dupe(u8, "/");
    if (std.mem.eql(u8, raw, ".")) return allocator.dupe(u8, "");
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    if (raw[0] != '/') try out.append(allocator, '/');
    try out.appendSlice(allocator, raw);
    if (out.items.len > 0 and out.items[out.items.len - 1] != '/') try out.append(allocator, '/');
    return try out.toOwnedSlice(allocator);
}

fn parseHtmlEntry(allocator: std.mem.Allocator, html: []const u8) !HtmlEntry {
    var entry = HtmlEntry{};
    errdefer entry.deinit(allocator);
    try scanTagAttr(allocator, html, "script", "src", &entry.module_scripts, "type", "module");
    try scanTagAttr(allocator, html, "link", "href", &entry.stylesheets, "rel", "stylesheet");
    try scanTagAttr(allocator, html, "link", "href", &entry.asset_refs, "rel", "icon");
    try scanTagAttr(allocator, html, "img", "src", &entry.asset_refs, null, null);
    try scanTagAttr(allocator, html, "source", "src", &entry.asset_refs, null, null);
    return entry;
}

fn scanTagAttr(
    allocator: std.mem.Allocator,
    html: []const u8,
    tag: []const u8,
    attr: []const u8,
    out: *std.ArrayList([]const u8),
    filter_attr: ?[]const u8,
    filter_value: ?[]const u8,
) !void {
    const open = try std.fmt.allocPrint(allocator, "<{s}", .{tag});
    defer allocator.free(open);
    var offset: usize = 0;
    while (std.mem.indexOf(u8, html[offset..], open)) |idx_rel| {
        const start = offset + idx_rel;
        const close_rel = std.mem.indexOfScalar(u8, html[start..], '>') orelse break;
        const tag_text = html[start .. start + close_rel + 1];
        offset = start + close_rel + 1;
        if (filter_attr) |fa| {
            const fv = filter_value orelse "";
            const actual = extractAttr(tag_text, fa) orelse continue;
            if (!std.ascii.eqlIgnoreCase(actual, fv)) continue;
        }
        if (extractAttr(tag_text, attr)) |value| try out.append(allocator, value);
    }
}

fn extractAttr(tag_text: []const u8, attr: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < tag_text.len) : (i += 1) {
        if (i > 0 and (std.ascii.isAlphanumeric(tag_text[i - 1]) or tag_text[i - 1] == '-' or tag_text[i - 1] == '_')) continue;
        if (!std.ascii.startsWithIgnoreCase(tag_text[i..], attr)) continue;
        var j = i + attr.len;
        while (j < tag_text.len and std.ascii.isWhitespace(tag_text[j])) j += 1;
        if (j >= tag_text.len or tag_text[j] != '=') continue;
        j += 1;
        while (j < tag_text.len and std.ascii.isWhitespace(tag_text[j])) j += 1;
        if (j >= tag_text.len or (tag_text[j] != '"' and tag_text[j] != '\'')) continue;
        const quote = tag_text[j];
        j += 1;
        const value_start = j;
        while (j < tag_text.len and tag_text[j] != quote) j += 1;
        if (j >= tag_text.len) return null;
        return tag_text[value_start..j];
    }
    return null;
}

fn resolveHtmlRef(allocator: std.mem.Allocator, root: []const u8, html_dir: []const u8, value: []const u8) !?[]const u8 {
    if (value.len == 0 or value[0] == '#') return null;
    if (isExternalUrl(value)) return null;
    const end = std.mem.indexOfAny(u8, value, "?#") orelse value.len;
    const path = value[0..end];
    if (path.len > 0 and path[0] == '/') return try std.fs.path.resolve(allocator, &.{ root, path[1..] });
    return try std.fs.path.resolve(allocator, &.{ html_dir, path });
}

const UrlParts = struct {
    path: []const u8,
    suffix: []const u8,
};

/// `?query` / `#fragment` 분리 — CSS 스캐너와 동일 규칙 (단일 구현 재사용).
fn splitUrl(value: []const u8) UrlParts {
    const parts = css_scanner.splitUrlSuffix(value);
    return .{ .path = parts.path, .suffix = parts.suffix };
}

/// external URL 판정 — CSS 스캐너와 동일 규칙 (`http(s):` / `//` / `data:`).
fn isExternalUrl(value: []const u8) bool {
    return css_scanner.isExternalCssSpecifier(value);
}

/// `<link rel=stylesheet>` source 의 outdir-내 emit path 를 결정한다.
/// root 안의 파일은 root-기준 relative path 를 그대로 보존하여 동일 basename 충돌을 차단한다.
/// root 밖(예: 외부 디렉토리에서 symlink)은 fallback 으로 basename 을 사용.
fn stylesheetRelFromRoot(allocator: std.mem.Allocator, root: []const u8, style_path: []const u8) ![]const u8 {
    const rel = std.fs.path.relative(allocator, "", null, root, style_path) catch
        return allocator.dupe(u8, std.fs.path.basename(style_path));
    if (rel.len == 0 or std.mem.startsWith(u8, rel, "..")) {
        allocator.free(rel);
        return allocator.dupe(u8, std.fs.path.basename(style_path));
    }
    return rel;
}

fn writeOutput(allocator: std.mem.Allocator, io: std.Io, outdir: []const u8, rel_path: []const u8, contents: []const u8) !void {
    const path = try std.fs.path.join(allocator, &.{ outdir, rel_path });
    defer allocator.free(path);
    if (std.fs.path.dirname(path)) |dir| try std.Io.Dir.cwd().createDirPath(io, dir);
    var file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    defer file.close(io);
    try file.writeStreamingAll(io, contents);
}

fn replaceEnvTokens(allocator: std.mem.Allocator, html_in: []const u8, env_map: *const app_env.EnvMap, mode: []const u8, base: []const u8) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < html_in.len) {
        if (html_in[i] == '%') {
            if (std.mem.indexOfScalar(u8, html_in[i + 1 ..], '%')) |end_rel| {
                const key = html_in[i + 1 .. i + 1 + end_rel];
                if (envValue(env_map, mode, base, key)) |value| {
                    try out.appendSlice(allocator, value);
                    i += end_rel + 2;
                    continue;
                }
            }
        }
        try out.append(allocator, html_in[i]);
        i += 1;
    }
    return try out.toOwnedSlice(allocator);
}

fn envValue(env_map: *const app_env.EnvMap, mode: []const u8, base: []const u8, key: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, key, "MODE")) return mode;
    if (std.mem.eql(u8, key, "PROD")) return if (std.mem.eql(u8, mode, "production")) "true" else "false";
    if (std.mem.eql(u8, key, "DEV")) return if (std.mem.eql(u8, mode, "production")) "false" else "true";
    if (std.mem.eql(u8, key, "SSR")) return "false";
    if (std.mem.eql(u8, key, "BASE_URL")) return base;
    return env_map.get(key);
}

fn replaceOwned(allocator: std.mem.Allocator, haystack: []const u8, needle: []const u8, replacement: []const u8) ![]const u8 {
    if (needle.len == 0) return allocator.dupe(u8, haystack);
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    var offset: usize = 0;
    while (std.mem.indexOf(u8, haystack[offset..], needle)) |idx_rel| {
        const idx = offset + idx_rel;
        try out.appendSlice(allocator, haystack[offset..idx]);
        try out.appendSlice(allocator, replacement);
        offset = idx + needle.len;
    }
    try out.appendSlice(allocator, haystack[offset..]);
    return try out.toOwnedSlice(allocator);
}

fn htmlReferencesPath(html: []const u8, rel_path: []const u8) bool {
    if (std.mem.indexOf(u8, html, rel_path) != null) return true;
    const base = std.fs.path.basename(rel_path);
    return std.mem.indexOf(u8, html, base) != null;
}

fn injectIntoHtml(allocator: std.mem.Allocator, html: []const u8, tag: []const u8) ![]const u8 {
    const targets = [_][]const u8{ "</head>", "<script" };
    for (targets) |target| {
        if (std.mem.indexOf(u8, html, target)) |idx| {
            var out = std.ArrayList(u8).empty;
            errdefer out.deinit(allocator);
            try out.appendSlice(allocator, html[0..idx]);
            try out.appendSlice(allocator, tag);
            try out.append(allocator, '\n');
            try out.appendSlice(allocator, html[idx..]);
            return try out.toOwnedSlice(allocator);
        }
    }
    return std.fmt.allocPrint(allocator, "{s}\n{s}", .{ tag, html });
}

fn injectModulePreloads(
    allocator: std.mem.Allocator,
    html: []const u8,
    outputs: []const bundler_mod.emitter.OutputFile,
    entry_count: usize,
    base: []const u8,
) ![]const u8 {
    if (outputs.len == 0 or entry_count == 0) return allocator.dupe(u8, html);

    // path → outputs index 를 한 번만 빌드. 이전엔 recursive walker 가 매 import 마다
    // outputs 를 선형 스캔 (O(N²)) 했음. outputs 자체에 대한 alias 라 owned key 불필요.
    var by_path: std.StringHashMapUnmanaged(usize) = .empty;
    defer by_path.deinit(allocator);
    try by_path.ensureTotalCapacity(allocator, @intCast(outputs.len));
    for (outputs, 0..) |out, i| by_path.putAssumeCapacity(out.path, i);

    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(allocator);
    var seen_keys: std.ArrayList([]const u8) = .empty;
    defer {
        for (seen_keys.items) |key| allocator.free(key);
        seen_keys.deinit(allocator);
    }
    var tags = std.ArrayList(u8).empty;
    defer tags.deinit(allocator);

    const limit = @min(entry_count, outputs.len);
    for (outputs[0..limit]) |out| {
        try appendModulePreloadImports(allocator, outputs, &by_path, out.imports, base, &seen, &seen_keys, &tags);
    }
    if (tags.items.len == 0) return allocator.dupe(u8, html);
    return injectIntoHtml(allocator, html, tags.items);
}

fn appendModulePreloadImports(
    allocator: std.mem.Allocator,
    outputs: []const bundler_mod.emitter.OutputFile,
    by_path: *const std.StringHashMapUnmanaged(usize),
    imports: []const []const u8,
    base: []const u8,
    seen: *std.StringHashMapUnmanaged(void),
    seen_keys: *std.ArrayList([]const u8),
    tags: *std.ArrayList(u8),
) !void {
    for (imports) |path| {
        if (!isJavaScriptOutput(path) or seen.contains(path)) continue;
        try addReserved(allocator, seen, seen_keys, path);

        const url = try joinBaseUrl(allocator, base, path);
        defer allocator.free(url);
        const tag = try std.fmt.allocPrint(allocator, "<link rel=\"modulepreload\" href=\"{s}\">", .{url});
        defer allocator.free(tag);
        if (tags.items.len > 0) try tags.append(allocator, '\n');
        try tags.appendSlice(allocator, tag);

        if (by_path.get(path)) |idx| {
            try appendModulePreloadImports(allocator, outputs, by_path, outputs[idx].imports, base, seen, seen_keys, tags);
        }
    }
}

fn findEntryOutputPath(outputs: []const bundler_mod.emitter.OutputFile, entry_path: []const u8) ?[]const u8 {
    for (outputs) |out| {
        if (out.kind != .chunk) continue;
        for (out.module_ids) |mid| {
            if (std.mem.eql(u8, mid, entry_path)) return out.path;
        }
    }
    return null;
}

fn isJavaScriptOutput(path: []const u8) bool {
    return std.mem.endsWith(u8, path, ".js") or std.mem.endsWith(u8, path, ".mjs");
}

fn printAppBundleDiagnostics(diags: []const bundler_mod.BundleResult.OwnedDiagnostic) void {
    // 0.16: threaded io 없이 stderr 진단 출력 — std.debug.print (debug_io, fd 2 직접).
    for (diags) |d| {
        if (d.severity != .@"error") continue;
        const where = if (d.file_path.len > 0) d.file_path else "<input>";
        // main.zig CLI 진단과 동일하게 [ZNTCxxxx] + docs URL 노출.
        if (rich_diagnostic.bundlerErrorCode(d.code)) |zc| {
            std.debug.print("[{s}] error: {s}\n  at {s}\n", .{ zc.format(), d.message, where });
            if (d.suggestion) |s| std.debug.print("  hint: {s}\n", .{s});
            std.debug.print("  docs: {s}\n", .{zc.docsUrl()});
        } else {
            std.debug.print("error[{s}]: {s}\n  at {s}\n", .{ @tagName(d.code), d.message, where });
            if (d.suggestion) |s| std.debug.print("  hint: {s}\n", .{s});
        }
    }
}

fn joinBaseUrl(allocator: std.mem.Allocator, base: []const u8, rel: []const u8) ![]const u8 {
    if (base.len == 0) return allocator.dupe(u8, rel);
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ base, rel });
}

fn joinBaseUrlWithSuffix(allocator: std.mem.Allocator, base: []const u8, rel: []const u8, suffix: []const u8) ![]const u8 {
    if (base.len == 0) return std.fmt.allocPrint(allocator, "{s}{s}", .{ rel, suffix });
    return std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ base, rel, suffix });
}

fn addReserved(
    allocator: std.mem.Allocator,
    reserved: *std.StringHashMapUnmanaged(void),
    reserved_keys: *std.ArrayList([]const u8),
    key: []const u8,
) !void {
    if (reserved.contains(key)) return;
    const owned = try allocator.dupe(u8, key);
    errdefer allocator.free(owned);
    try reserved.put(allocator, owned, {});
    try reserved_keys.append(allocator, owned);
}

/// 자산 파일 하나를 outdir 로 복사하고 출력 파일명을 돌려준다.
///
/// 이름 충돌 처리 (#4466): 예전엔 basename 만 쓰고 `reserved` 에 이미 있으면
/// **쓰기를 건너뛰고 같은 이름을 반환**했다. 그래서 서로 다른 `a/logo.png` 와
/// `b/logo.png` 가 둘 다 `logo.png` 로 매핑되고, 실제로는 a 의 내용만 기록돼
/// b 를 참조하던 규칙이 조용히 a 의 이미지를 그렸다 (silent wrong asset).
///
/// 이제 원본 경로별로 출력명을 기억하고, basename 이 *다른* 원본에 이미 잡혀
/// 있으면 content hash 를 붙여 (`logo-a1b2c3d4.png`) 구분한다. 충돌이 없는
/// 흔한 경우엔 예전과 똑같이 깨끗한 basename 이 나오므로 기존 출력이 흔들리지
/// 않는다.
fn copyAssetFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    asset_path: []const u8,
    outdir: []const u8,
    reserved: *std.StringHashMapUnmanaged(void),
    reserved_keys: *std.ArrayList([]const u8),
    output_count: *usize,
    emitted: *std.StringHashMapUnmanaged([]const u8),
) ![]const u8 {
    // 같은 원본을 두 번 참조 → 첫 결정을 그대로 재사용 (재읽기/재기록 없음).
    if (emitted.get(asset_path)) |name| return try allocator.dupe(u8, name);

    const contents = try std.Io.Dir.cwd().readFileAlloc(io, asset_path, allocator, std.Io.Limit.limited(100 * 1024 * 1024));
    defer allocator.free(contents);

    const base_name = std.fs.path.basename(asset_path);
    const name: []const u8 = if (!reserved.contains(base_name))
        try allocator.dupe(u8, base_name)
    else blk: {
        // basename 이 이미 다른 원본(또는 번들러 출력/public 파일)에 잡혔다 →
        // content hash 로 구분.
        const ext = std.fs.path.extension(base_name);
        const stem = base_name[0 .. base_name.len - ext.len];
        const hash = wyhash.hashHex8(contents);
        break :blk try std.fmt.allocPrint(allocator, "{s}-{s}{s}", .{ stem, hash, ext });
    };
    errdefer allocator.free(name);

    // 해시까지 붙였는데도 이미 있다면 = 같은 내용이 이미 기록된 것. 재기록 불필요.
    if (!reserved.contains(name)) {
        try writeOutput(allocator, io, outdir, name, contents);
        try addReserved(allocator, reserved, reserved_keys, name);
        output_count.* += 1;
    }

    // 반환값을 map 에 넣기 *전에* 먼저 만든다. put 이 성공한 뒤에는 name/src_key 의
    // 소유권이 map 으로 넘어가므로, 그 다음에 실패할 수 있는 할당을 두면 errdefer 가
    // map 이 들고 있는 메모리를 free 해 double free 가 된다.
    const ret = try allocator.dupe(u8, name);
    errdefer allocator.free(ret);

    const src_key = try allocator.dupe(u8, asset_path);
    errdefer allocator.free(src_key);

    // 여기서부터는 실패 가능 지점이 없다 — put 이 성공하면 map 이 name/src_key 소유.
    try emitted.put(allocator, src_key, name);
    return ret;
}

/// HTML 이 `<link rel="stylesheet">` 로 직접 건 CSS 의 url() 재작성.
/// (JS 가 `import` 한 CSS 는 번들러 CSS 파이프라인이 처리 — css_emitter.zig)
///
/// 스캔은 css_scanner.extractCssUrls 에 위임한다 (#4466). 예전엔
/// `indexOf("url(")` + `indexOfScalar(')')` substring 스캔이라 세 가지가 틀렸다:
///   - `/* url(x) */` 주석과 `content: "url(y)"` 문자열 안의 것을 자산으로 오인
///   - `blur(4px)` 같이 `url` 로 끝나지 않는 함수는 괜찮았지만 `myurl(` 은 오탐
///   - `url("a)b.png")` 처럼 따옴표 안에 `)` 가 있으면 거기서 잘려 CSS 파손
/// 이제 주석/문자열을 토큰으로 인식하는 스캐너를 쓰고 image-set() 도 함께 처리한다.
fn rewriteCssUrls(
    allocator: std.mem.Allocator,
    io: std.Io,
    css: []const u8,
    style_path: []const u8,
    outdir: []const u8,
    base: []const u8,
    reserved: *std.StringHashMapUnmanaged(void),
    reserved_keys: *std.ArrayList([]const u8),
    output_count: *usize,
    emitted: *std.StringHashMapUnmanaged([]const u8),
) ![]const u8 {
    const style_dir = std.fs.path.dirname(style_path) orelse ".";

    const urls = css_scanner.extractCssUrls(allocator, css, 0);
    defer allocator.free(urls);

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    var cursor: usize = 0;
    for (urls) |u| {
        if (u.span.start < cursor or u.span.end > css.len) continue;

        // 재작성 텍스트 계산. 실패하면 원문을 그대로 흘려보낸다 (빌드 중단 없음).
        const rel_for_url: ?[]const u8 = switch (u.kind) {
            // `/logo.png` — public 디렉토리 규약. 파일로 resolve 하지 않고
            // `--base` prefix 만 붙인다 (기존 동작 유지).
            .root_absolute => null,
            .relative => blk: {
                const asset_path = try std.fs.path.resolve(allocator, &.{ style_dir, u.specifier });
                defer allocator.free(asset_path);
                break :blk copyAssetFile(allocator, io, asset_path, outdir, reserved, reserved_keys, output_count, emitted) catch |err| switch (err) {
                    // 참조 대상이 없어도 빌드를 세우지 않는다 — 배포 스크립트가
                    // 나중에 넣는 자산이 흔하다 (번들러 CSS 경로와 동일한 정책).
                    error.FileNotFound => continue,
                    else => return err,
                };
            },
        };
        defer if (rel_for_url) |r| allocator.free(r);

        const url_body = rel_for_url orelse u.specifier[1..]; // root_absolute 는 선행 `/` 제거
        const rewritten = try joinBaseUrlWithSuffix(allocator, base, url_body, u.suffix);
        defer allocator.free(rewritten);

        try out.appendSlice(allocator, css[cursor..u.span.start]);
        try out.append(allocator, '"');
        try appendCssStringEscaped(allocator, &out, rewritten);
        try out.append(allocator, '"');
        cursor = u.span.end;
    }
    try out.appendSlice(allocator, css[cursor..]);
    return try out.toOwnedSlice(allocator);
}

/// CSS double-quoted string 안전 escape — 따옴표/백슬래시/개행이 든 경로가 문자열을
/// 조기 종료해 CSS 를 깨뜨리는 것을 막는다. css_emitter 의 동명 함수와 같은 규칙
/// (CSS spec §4.3.5: hex escape 뒤 공백 1개로 terminate).
fn appendCssStringEscaped(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try buf.appendSlice(allocator, "\\22 "),
            '\\' => try buf.appendSlice(allocator, "\\\\"),
            '\n' => try buf.appendSlice(allocator, "\\A "),
            '\r' => try buf.appendSlice(allocator, "\\D "),
            else => try buf.append(allocator, c),
        }
    }
}

fn copyPublicDir(
    allocator: std.mem.Allocator,
    io: std.Io,
    public_dir: []const u8,
    outdir: []const u8,
    reserved: *std.StringHashMapUnmanaged(void),
    output_count: *usize,
) !void {
    var dir = std.Io.Dir.cwd().openDir(io, public_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer dir.close(io);
    try copyPublicDirInner(allocator, io, public_dir, "", outdir, reserved, output_count);
}

fn copyPublicDirInner(
    allocator: std.mem.Allocator,
    io: std.Io,
    public_dir: []const u8,
    rel_dir: []const u8,
    outdir: []const u8,
    reserved: *std.StringHashMapUnmanaged(void),
    output_count: *usize,
) !void {
    const abs_dir = if (rel_dir.len == 0) try allocator.dupe(u8, public_dir) else try std.fs.path.join(allocator, &.{ public_dir, rel_dir });
    defer allocator.free(abs_dir);
    var dir = try std.Io.Dir.cwd().openDir(io, abs_dir, .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        const rel = if (rel_dir.len == 0) try allocator.dupe(u8, entry.name) else try std.fs.path.join(allocator, &.{ rel_dir, entry.name });
        defer allocator.free(rel);
        switch (entry.kind) {
            .directory => try copyPublicDirInner(allocator, io, public_dir, rel, outdir, reserved, output_count),
            .file => {
                if (reserved.contains(rel)) return error.PublicDirCollision;
                const src = try std.fs.path.join(allocator, &.{ public_dir, rel });
                defer allocator.free(src);
                const contents = try std.Io.Dir.cwd().readFileAlloc(io, src, allocator, std.Io.Limit.limited(100 * 1024 * 1024));
                defer allocator.free(contents);
                try writeOutput(allocator, io, outdir, rel, contents);
                output_count.* += 1;
            },
            else => {},
        }
    }
}
