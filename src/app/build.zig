const std = @import("std");
const app_env = @import("env.zig");
const bundler_mod = @import("../bundler/mod.zig");
const transformer_mod = @import("../transformer/transformer.zig");

const Bundler = bundler_mod.Bundler;
const BundleOptions = bundler_mod.BundleOptions;
const DefineEntry = transformer_mod.DefineEntry;

pub const AppBuildOptions = struct {
    root: []const u8 = ".",
    outdir: []const u8 = "dist",
    entry_html: []const u8 = "index.html",
    public_dir: ?[]const u8 = "public",
    base: []const u8 = "/",
    mode: []const u8 = "production",
    env_dir: ?[]const u8 = null,
    env_prefixes: []const []const u8 = &.{ "VITE_", "ZTS_" },
    define: []const DefineEntry = &.{},
    minify: bool = false,
    sourcemap: bool = false,
    splitting: bool = true,
    /// styled-components 1st-party transform 활성화 (compiler.styledComponents).
    styled_components: bool = false,
    /// styled-components.ssr 옵션 — false 면 componentId 생략.
    styled_components_ssr: bool = true,
    /// styled-components.minify 옵션 — CSS template whitespace collapse.
    styled_components_minify: bool = false,
    /// emotion 1st-party transform (compiler.emotion).
    emotion: bool = false,
};

pub const AppDevPrepareOptions = struct {
    root: []const u8 = ".",
    outdir: []const u8 = ".zts-dev",
    entry_html: []const u8 = "index.html",
    public_dir: ?[]const u8 = "public",
    base: []const u8 = "/",
    mode: []const u8 = "development",
    env_dir: ?[]const u8 = null,
    env_prefixes: []const []const u8 = &.{ "VITE_", "ZTS_" },
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

pub fn buildApp(allocator: std.mem.Allocator, opts: AppBuildOptions) !usize {
    const root = try std.fs.path.resolve(allocator, &.{opts.root});
    defer allocator.free(root);
    const outdir = try std.fs.path.resolve(allocator, &.{ root, opts.outdir });
    defer allocator.free(outdir);
    const html_path = try std.fs.path.resolve(allocator, &.{ root, opts.entry_html });
    defer allocator.free(html_path);
    const html_dir = std.fs.path.dirname(html_path) orelse root;
    const base = try normalizeBase(allocator, opts.base);
    defer allocator.free(base);

    const raw_html = try std.fs.cwd().readFileAlloc(allocator, html_path, 10 * 1024 * 1024);
    defer allocator.free(raw_html);

    var html_entry = try parseHtmlEntry(allocator, raw_html);
    defer html_entry.deinit(allocator);
    if (html_entry.module_scripts.items.len == 0) return error.MissingModuleScript;

    try std.fs.cwd().makePath(outdir);

    const entry_points = try allocator.alloc([]const u8, html_entry.module_scripts.items.len);
    defer {
        for (entry_points) |p| allocator.free(p);
        allocator.free(entry_points);
    }
    for (html_entry.module_scripts.items, 0..) |src, i| {
        entry_points[i] = (try resolveHtmlRef(allocator, root, html_dir, src)) orelse return error.UnsupportedEntryUrl;
    }

    var env_map = try app_env.loadEnv(allocator, .{
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
        .entry_names = if (opts.splitting) "[name]-[hash]" else "[name]",
        .chunk_names = "[name]-[hash]",
        .asset_names = "[name]-[hash]",
        .output_filename = "bundle.js",
        .root_dir = root,
        .styled_components = opts.styled_components,
        .styled_components_ssr = opts.styled_components_ssr,
        .styled_components_minify = opts.styled_components_minify,
        .emotion = opts.emotion,
    });
    defer bundler.deinit();

    var result = try bundler.bundle();
    defer result.deinit(allocator);
    if (result.hasErrors()) {
        printAppBundleDiagnostics(result.getDiagnostics());
        return error.BundleFailed;
    }

    var reserved = std.StringHashMap(void).init(allocator);
    defer reserved.deinit();
    var reserved_keys: std.ArrayList([]const u8) = .empty;
    defer {
        for (reserved_keys.items) |key| allocator.free(key);
        reserved_keys.deinit(allocator);
    }
    try addReserved(allocator, &reserved, &reserved_keys, "index.html");

    var output_count: usize = 0;
    if (result.outputs) |outs| {
        for (outs) |out| {
            try writeOutput(allocator, outdir, out.path, out.contents);
            try addReserved(allocator, &reserved, &reserved_keys, out.path);
            output_count += 1;
        }
    } else {
        try writeOutput(allocator, outdir, "bundle.js", result.output);
        try addReserved(allocator, &reserved, &reserved_keys, "bundle.js");
        output_count += 1;
        if (result.sourcemap) |sm| {
            try writeOutput(allocator, outdir, "bundle.js.map", sm);
            try addReserved(allocator, &reserved, &reserved_keys, "bundle.js.map");
            output_count += 1;
        }
    }
    var emitted_css: std.ArrayList([]const u8) = .empty;
    defer emitted_css.deinit(allocator);
    if (result.asset_outputs) |outs| {
        for (outs) |out| {
            try writeOutput(allocator, outdir, out.path, out.contents);
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
                const contents = try std.fs.cwd().readFileAlloc(allocator, style_path, 10 * 1024 * 1024);
                defer allocator.free(contents);
                const rewritten_css = try rewriteCssUrls(allocator, contents, style_path, outdir, base, &reserved, &reserved_keys, &output_count);
                defer allocator.free(rewritten_css);
                try writeOutput(allocator, outdir, rel, rewritten_css);
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
            std.fs.cwd().access(root_asset_path, .{}) catch break :blk parts.path[1..];
            rel_owned = true;
            break :blk try copyAssetFile(allocator, root_asset_path, outdir, &reserved, &reserved_keys, &output_count);
        } else blk: {
            const asset_path = (try resolveHtmlRef(allocator, root, html_dir, ref)) orelse continue;
            defer allocator.free(asset_path);
            rel_owned = true;
            break :blk try copyAssetFile(allocator, asset_path, outdir, &reserved, &reserved_keys, &output_count);
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
        try copyPublicDir(allocator, public_abs, outdir, &reserved, &output_count);
    }

    try writeOutput(allocator, outdir, "index.html", html);
    output_count += 1;
    return output_count;
}

pub fn prepareDev(allocator: std.mem.Allocator, opts: AppDevPrepareOptions) !AppDevPrepareResult {
    const root = try std.fs.path.resolve(allocator, &.{opts.root});
    defer allocator.free(root);
    const outdir = try std.fs.path.resolve(allocator, &.{ root, opts.outdir });
    defer allocator.free(outdir);
    const html_path = try std.fs.path.resolve(allocator, &.{ root, opts.entry_html });
    defer allocator.free(html_path);
    const html_dir = std.fs.path.dirname(html_path) orelse root;
    const base = try normalizeBase(allocator, opts.base);
    defer allocator.free(base);

    const raw_html = try std.fs.cwd().readFileAlloc(allocator, html_path, 10 * 1024 * 1024);
    defer allocator.free(raw_html);

    var html_entry = try parseHtmlEntry(allocator, raw_html);
    defer html_entry.deinit(allocator);
    if (html_entry.module_scripts.items.len == 0) return error.MissingModuleScript;

    const entry_path = (try resolveHtmlRef(allocator, root, html_dir, html_entry.module_scripts.items[0])) orelse return error.UnsupportedEntryUrl;
    errdefer allocator.free(entry_path);

    var env_map = try app_env.loadEnv(allocator, .{
        .mode = opts.mode,
        .env_dir = opts.env_dir orelse root,
        .prefixes = opts.env_prefixes,
    });
    defer app_env.deinitMap(&env_map, allocator);

    try std.fs.cwd().makePath(outdir);
    var reserved = std.StringHashMap(void).init(allocator);
    defer reserved.deinit();
    var reserved_keys: std.ArrayList([]const u8) = .empty;
    defer {
        for (reserved_keys.items) |key| allocator.free(key);
        reserved_keys.deinit(allocator);
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
                const contents = try std.fs.cwd().readFileAlloc(allocator, style_path, 10 * 1024 * 1024);
                defer allocator.free(contents);
                const rewritten_css = try rewriteCssUrls(allocator, contents, style_path, outdir, base, &reserved, &reserved_keys, &output_count);
                defer allocator.free(rewritten_css);
                try writeOutput(allocator, outdir, rel, rewritten_css);
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
        try copyPublicDir(allocator, public_abs, outdir, &reserved, &output_count);
    }
    try writeOutput(allocator, outdir, "index.html", html);
    output_count += 1;

    return .{ .entry_path = entry_path, .output_count = output_count };
}

fn mergeDefines(allocator: std.mem.Allocator, env_defines: []const app_env.DefineEntry, user_defines: []const DefineEntry) ![]DefineEntry {
    var user_keys = std.StringHashMap(void).init(allocator);
    defer user_keys.deinit();
    try user_keys.ensureTotalCapacity(@intCast(user_defines.len));
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

fn splitUrl(value: []const u8) UrlParts {
    const idx = std.mem.indexOfAny(u8, value, "?#") orelse value.len;
    return .{ .path = value[0..idx], .suffix = value[idx..] };
}

fn isExternalUrl(value: []const u8) bool {
    return std.mem.startsWith(u8, value, "http://") or
        std.mem.startsWith(u8, value, "https://") or
        std.mem.startsWith(u8, value, "//") or
        std.mem.startsWith(u8, value, "data:");
}

/// `<link rel=stylesheet>` source 의 outdir-내 emit path 를 결정한다.
/// root 안의 파일은 root-기준 relative path 를 그대로 보존하여 동일 basename 충돌을 차단한다.
/// root 밖(예: 외부 디렉토리에서 symlink)은 fallback 으로 basename 을 사용.
fn stylesheetRelFromRoot(allocator: std.mem.Allocator, root: []const u8, style_path: []const u8) ![]const u8 {
    const rel = std.fs.path.relative(allocator, root, style_path) catch
        return allocator.dupe(u8, std.fs.path.basename(style_path));
    if (rel.len == 0 or std.mem.startsWith(u8, rel, "..")) {
        allocator.free(rel);
        return allocator.dupe(u8, std.fs.path.basename(style_path));
    }
    return rel;
}

fn writeOutput(allocator: std.mem.Allocator, outdir: []const u8, rel_path: []const u8, contents: []const u8) !void {
    const path = try std.fs.path.join(allocator, &.{ outdir, rel_path });
    defer allocator.free(path);
    if (std.fs.path.dirname(path)) |dir| try std.fs.cwd().makePath(dir);
    var file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(contents);
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
    var by_path = std.StringHashMap(usize).init(allocator);
    defer by_path.deinit();
    try by_path.ensureTotalCapacity(@intCast(outputs.len));
    for (outputs, 0..) |out, i| by_path.putAssumeCapacity(out.path, i);

    var seen = std.StringHashMap(void).init(allocator);
    defer seen.deinit();
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
    by_path: *const std.StringHashMap(usize),
    imports: []const []const u8,
    base: []const u8,
    seen: *std.StringHashMap(void),
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
    const stderr = std.fs.File.stderr().deprecatedWriter();
    for (diags) |d| {
        if (d.severity != .@"error") continue;
        const where = if (d.file_path.len > 0) d.file_path else "<input>";
        stderr.print("error[{s}]: {s}\n  at {s}\n", .{ @tagName(d.code), d.message, where }) catch {};
        if (d.suggestion) |s| stderr.print("  hint: {s}\n", .{s}) catch {};
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
    reserved: *std.StringHashMap(void),
    reserved_keys: *std.ArrayList([]const u8),
    key: []const u8,
) !void {
    if (reserved.contains(key)) return;
    const owned = try allocator.dupe(u8, key);
    errdefer allocator.free(owned);
    try reserved.put(owned, {});
    try reserved_keys.append(allocator, owned);
}

fn copyAssetFile(
    allocator: std.mem.Allocator,
    asset_path: []const u8,
    outdir: []const u8,
    reserved: *std.StringHashMap(void),
    reserved_keys: *std.ArrayList([]const u8),
    output_count: *usize,
) ![]const u8 {
    const name = std.fs.path.basename(asset_path);
    if (!reserved.contains(name)) {
        const contents = try std.fs.cwd().readFileAlloc(allocator, asset_path, 100 * 1024 * 1024);
        defer allocator.free(contents);
        try writeOutput(allocator, outdir, name, contents);
        try addReserved(allocator, reserved, reserved_keys, name);
        output_count.* += 1;
    }
    return try allocator.dupe(u8, name);
}

fn rewriteCssUrls(
    allocator: std.mem.Allocator,
    css: []const u8,
    style_path: []const u8,
    outdir: []const u8,
    base: []const u8,
    reserved: *std.StringHashMap(void),
    reserved_keys: *std.ArrayList([]const u8),
    output_count: *usize,
) ![]const u8 {
    const style_dir = std.fs.path.dirname(style_path) orelse ".";
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    var offset: usize = 0;
    while (std.mem.indexOf(u8, css[offset..], "url(")) |idx_rel| {
        const start = offset + idx_rel;
        const value_start = start + "url(".len;
        const close_rel = std.mem.indexOfScalar(u8, css[value_start..], ')') orelse break;
        const close = value_start + close_rel;
        try out.appendSlice(allocator, css[offset..start]);

        var raw = std.mem.trim(u8, css[value_start..close], " \t\r\n");
        if (raw.len >= 2 and ((raw[0] == '"' and raw[raw.len - 1] == '"') or (raw[0] == '\'' and raw[raw.len - 1] == '\''))) {
            raw = raw[1 .. raw.len - 1];
        }

        if (raw.len == 0 or raw[0] == '#' or isExternalUrl(raw)) {
            try out.appendSlice(allocator, css[start .. close + 1]);
        } else {
            const parts = splitUrl(raw);
            const root_absolute = parts.path.len > 0 and parts.path[0] == '/';
            const rel_for_url = if (root_absolute) parts.path[1..] else blk: {
                const asset_path = try std.fs.path.resolve(allocator, &.{ style_dir, parts.path });
                defer allocator.free(asset_path);
                break :blk try copyAssetFile(allocator, asset_path, outdir, reserved, reserved_keys, output_count);
            };
            defer if (!root_absolute) allocator.free(rel_for_url);
            const rewritten = try joinBaseUrlWithSuffix(allocator, base, rel_for_url, parts.suffix);
            defer allocator.free(rewritten);
            try out.appendSlice(allocator, "url(\"");
            try out.appendSlice(allocator, rewritten);
            try out.appendSlice(allocator, "\")");
        }
        offset = close + 1;
    }
    try out.appendSlice(allocator, css[offset..]);
    return try out.toOwnedSlice(allocator);
}

fn copyPublicDir(
    allocator: std.mem.Allocator,
    public_dir: []const u8,
    outdir: []const u8,
    reserved: *std.StringHashMap(void),
    output_count: *usize,
) !void {
    var dir = std.fs.cwd().openDir(public_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer dir.close();
    try copyPublicDirInner(allocator, public_dir, "", outdir, reserved, output_count);
}

fn copyPublicDirInner(
    allocator: std.mem.Allocator,
    public_dir: []const u8,
    rel_dir: []const u8,
    outdir: []const u8,
    reserved: *std.StringHashMap(void),
    output_count: *usize,
) !void {
    const abs_dir = if (rel_dir.len == 0) try allocator.dupe(u8, public_dir) else try std.fs.path.join(allocator, &.{ public_dir, rel_dir });
    defer allocator.free(abs_dir);
    var dir = try std.fs.cwd().openDir(abs_dir, .{ .iterate = true });
    defer dir.close();
    var it = dir.iterate();
    while (try it.next()) |entry| {
        const rel = if (rel_dir.len == 0) try allocator.dupe(u8, entry.name) else try std.fs.path.join(allocator, &.{ rel_dir, entry.name });
        defer allocator.free(rel);
        switch (entry.kind) {
            .directory => try copyPublicDirInner(allocator, public_dir, rel, outdir, reserved, output_count),
            .file => {
                if (reserved.contains(rel)) return error.PublicDirCollision;
                const src = try std.fs.path.join(allocator, &.{ public_dir, rel });
                defer allocator.free(src);
                const contents = try std.fs.cwd().readFileAlloc(allocator, src, 100 * 1024 * 1024);
                defer allocator.free(contents);
                try writeOutput(allocator, outdir, rel, contents);
                output_count.* += 1;
            },
            else => {},
        }
    }
}

test "app build emits rewritten html and public files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("src");
    try tmp.dir.makePath("public");
    try tmp.dir.writeFile(.{ .sub_path = "index.html", .data = "<title>%VITE_TITLE%</title><link rel=\"icon\" href=\"/favicon.svg\"><script type=\"module\" src=\"/src/main.ts\"></script>" });
    try tmp.dir.writeFile(.{ .sub_path = "src/main.ts", .data = "console.log(import.meta.env.VITE_TITLE, import.meta.env.BASE_URL);" });
    try tmp.dir.writeFile(.{ .sub_path = ".env.production", .data = "VITE_TITLE=ZTS App\n" });
    try tmp.dir.writeFile(.{ .sub_path = "public/favicon.svg", .data = "<svg></svg>" });
    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);

    const output_count = try buildApp(std.testing.allocator, .{ .root = root, .base = "/app/" });
    try std.testing.expect(output_count >= 3);

    const html_path = try std.fs.path.join(std.testing.allocator, &.{ root, "dist", "index.html" });
    defer std.testing.allocator.free(html_path);
    const html = try std.fs.cwd().readFileAlloc(std.testing.allocator, html_path, 1024 * 1024);
    defer std.testing.allocator.free(html);
    try std.testing.expect(std.mem.indexOf(u8, html, "ZTS App") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "/app/main-") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, ".js") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "/app/favicon.svg") != null);
}

test "app dev prepare emits html and returns script entry" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("src");
    try tmp.dir.makePath("public");
    try tmp.dir.writeFile(.{ .sub_path = "index.html", .data = "<title>%VITE_TITLE%</title><script type=\"module\" src=\"/src/main.ts\"></script>" });
    try tmp.dir.writeFile(.{ .sub_path = "src/main.ts", .data = "console.log(import.meta.env.VITE_TITLE);" });
    try tmp.dir.writeFile(.{ .sub_path = ".env.development", .data = "VITE_TITLE=Dev App\n" });
    try tmp.dir.writeFile(.{ .sub_path = "public/favicon.svg", .data = "<svg></svg>" });
    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);

    var result = try prepareDev(std.testing.allocator, .{ .root = root, .base = "/app/" });
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.endsWith(u8, result.entry_path, "src/main.ts"));

    const html_path = try std.fs.path.join(std.testing.allocator, &.{ root, ".zts-dev", "index.html" });
    defer std.testing.allocator.free(html_path);
    const html = try std.fs.cwd().readFileAlloc(std.testing.allocator, html_path, 1024 * 1024);
    defer std.testing.allocator.free(html);
    try std.testing.expect(std.mem.indexOf(u8, html, "Dev App") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "/app/bundle.js") != null);
}

test "app build rewrites stylesheet url assets and relative html assets" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("src");
    try tmp.dir.writeFile(.{ .sub_path = "index.html", .data = "<link rel=\"stylesheet\" href=\"/src/style.css?v=1\"><img src=\"/src/logo.png?raw#x\"><script type=\"module\" src=\"/src/main.ts\"></script>" });
    try tmp.dir.writeFile(.{ .sub_path = "src/main.ts", .data = "console.log('x');" });
    try tmp.dir.writeFile(.{ .sub_path = "src/style.css", .data = ".hero{background:url('./bg.png?v=2#hash')}" });
    try tmp.dir.writeFile(.{ .sub_path = "src/bg.png", .data = "bg" });
    try tmp.dir.writeFile(.{ .sub_path = "src/logo.png", .data = "logo" });
    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);

    _ = try buildApp(std.testing.allocator, .{ .root = root, .base = "/app/", .public_dir = null });

    // stylesheet 는 source root-기준 relative path 로 emit (dist/src/style.css).
    const style_path = try std.fs.path.join(std.testing.allocator, &.{ root, "dist", "src", "style.css" });
    defer std.testing.allocator.free(style_path);
    const css = try std.fs.cwd().readFileAlloc(std.testing.allocator, style_path, 1024 * 1024);
    defer std.testing.allocator.free(css);
    try std.testing.expect(std.mem.indexOf(u8, css, "url(\"/app/bg.png?v=2#hash\")") != null);

    const html_path = try std.fs.path.join(std.testing.allocator, &.{ root, "dist", "index.html" });
    defer std.testing.allocator.free(html_path);
    const html = try std.fs.cwd().readFileAlloc(std.testing.allocator, html_path, 1024 * 1024);
    defer std.testing.allocator.free(html);
    try std.testing.expect(std.mem.indexOf(u8, html, "href=\"/app/src/style.css?v=1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "src=\"/app/logo.png?raw#x\"") != null);

    try tmp.dir.access("dist/bg.png", .{});
    try tmp.dir.access("dist/logo.png", .{});
}

test "app build does not collide when bundler emits CSS that HTML also references" {
    // entry main.ts 가 import './main.css' 하고 HTML 도 같은 파일을 link 로 참조하는 시나리오.
    // bundler 는 entry basename 기반으로 main.css 를 asset_output 으로 emit (splitting=false 이면
    // entry_names = "[name]") → reserved 에 main.css 등록. HTML stylesheet 의 source 는
    // root-기준 relative path "src/main.css" 로 별도 emit 되므로 충돌하지 않는다 (서로 다른 path).
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("src");
    try tmp.dir.writeFile(.{
        .sub_path = "index.html",
        .data = "<link rel=\"stylesheet\" href=\"/src/main.css\"><script type=\"module\" src=\"/src/main.ts\"></script>",
    });
    try tmp.dir.writeFile(.{ .sub_path = "src/main.ts", .data = "import './main.css';\nconsole.log('x');" });
    try tmp.dir.writeFile(.{ .sub_path = "src/main.css", .data = ".hero{color:red}" });
    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);

    _ = try buildApp(std.testing.allocator, .{
        .root = root,
        .base = "/",
        .public_dir = null,
        .splitting = false,
    });

    const html_path = try std.fs.path.join(std.testing.allocator, &.{ root, "dist", "index.html" });
    defer std.testing.allocator.free(html_path);
    const html = try std.fs.cwd().readFileAlloc(std.testing.allocator, html_path, 1024 * 1024);
    defer std.testing.allocator.free(html);
    try std.testing.expect(std.mem.indexOf(u8, html, "href=\"/src/main.css\"") != null);
    try tmp.dir.access("dist/src/main.css", .{});
    try tmp.dir.access("dist/main.css", .{});
}

test "app build preserves nested CSS source path (no basename collision)" {
    // 서브디렉토리에 같은 basename 의 CSS 파일을 두 개 두면, root-기준 relative path 가
    // 보존되어 outdir/src/a/style.css 와 outdir/src/b/style.css 로 분리 emit 된다.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("src/a");
    try tmp.dir.makePath("src/b");
    try tmp.dir.writeFile(.{
        .sub_path = "index.html",
        .data = "<link rel=\"stylesheet\" href=\"/src/a/style.css\"><link rel=\"stylesheet\" href=\"/src/b/style.css\"><script type=\"module\" src=\"/src/main.ts\"></script>",
    });
    try tmp.dir.writeFile(.{ .sub_path = "src/main.ts", .data = "console.log('x');" });
    try tmp.dir.writeFile(.{ .sub_path = "src/a/style.css", .data = ".a{color:red}" });
    try tmp.dir.writeFile(.{ .sub_path = "src/b/style.css", .data = ".b{color:blue}" });
    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);

    _ = try buildApp(std.testing.allocator, .{ .root = root, .base = "/", .public_dir = null });

    try tmp.dir.access("dist/src/a/style.css", .{});
    try tmp.dir.access("dist/src/b/style.css", .{});

    const html_path = try std.fs.path.join(std.testing.allocator, &.{ root, "dist", "index.html" });
    defer std.testing.allocator.free(html_path);
    const html = try std.fs.cwd().readFileAlloc(std.testing.allocator, html_path, 1024 * 1024);
    defer std.testing.allocator.free(html);
    try std.testing.expect(std.mem.indexOf(u8, html, "href=\"/src/a/style.css\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "href=\"/src/b/style.css\"") != null);
    const a_css_path = try std.fs.path.join(std.testing.allocator, &.{ root, "dist", "src", "a", "style.css" });
    defer std.testing.allocator.free(a_css_path);
    const a_css = try std.fs.cwd().readFileAlloc(std.testing.allocator, a_css_path, 1024);
    defer std.testing.allocator.free(a_css);
    try std.testing.expect(std.mem.indexOf(u8, a_css, ".a") != null);
}
