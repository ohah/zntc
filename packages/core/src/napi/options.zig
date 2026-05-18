//! NAPI build option parsing for `@zntc/core`.

const std = @import("std");
const zntc_lib = @import("zntc_lib");
const common = @import("common.zig");
const c = common.c;

const bundler_mod = zntc_lib.bundler;
const BundleOptions = bundler_mod.BundleOptions;
const Platform = zntc_lib.codegen.codegen.Platform;
const JsxRuntime = zntc_lib.codegen.codegen.JsxRuntime;
const EmitFormat = bundler_mod.emitter.EmitOptions.Format;
const SourceMap = zntc_lib.codegen.sourcemap;
const profile_mod = zntc_lib.profile;
const transformer_mod = zntc_lib.transformer.transformer;
const AutoLabelMode = transformer_mod.AutoLabelMode;
const DefineEntry = transformer_mod.DefineEntry;
const ModuleSpecifierMapEntry = transformer_mod.ModuleSpecifierMapEntry;
const compat = transformer_mod.TransformOptions.compat;
const config_mod = zntc_lib.config;
const TsConfig = config_mod.TsConfig;
const tsconfig_merge = zntc_lib.tsconfig_merge;

const native_alloc = std.heap.c_allocator;

const throwError = common.throwError;
const getStringArg = common.getStringArg;
const getNamedProperty = common.getNamedProperty;
const getObjectBool = common.getObjectBool;
const getObjectBoolOptional = common.getObjectBoolOptional;
const getObjectUint32 = common.getObjectUint32;
const getObjectString = common.getObjectString;
const getObjectStringArray = common.getObjectStringArray;
const parseStringArray = common.parseStringArray;
const getObjectKeyValuePairs = common.getObjectKeyValuePairs;
const getObjectKeyValuePairsWithNullable = common.getObjectKeyValuePairsWithNullable;

/// `emotionAutoLabel` 옵션을 enum 값으로 파싱. JS 측에서 string ("never"/"always"/
/// "dev-only") 또는 boolean (legacy: false=never, true=always) 으로 보낼 수 있음.
/// 누락 시 기본 `.always`.
pub fn getAutoLabelMode(env: c.napi_env, obj: c.napi_value, alloc: std.mem.Allocator) AutoLabelMode {
    const val = getNamedProperty(env, obj, "emotionAutoLabel") orelse return .always;
    var ty: c.napi_valuetype = undefined;
    if (c.napi_typeof(env, val, &ty) != c.napi_ok) return .always;
    switch (ty) {
        c.napi_boolean => {
            var b: bool = true;
            _ = c.napi_get_value_bool(env, val, &b);
            return if (b) .always else .never;
        },
        c.napi_string => {
            const s = getStringArg(env, val, alloc) orelse return .always;
            defer alloc.free(s);
            if (std.mem.eql(u8, s, "never")) return .never;
            if (std.mem.eql(u8, s, "always")) return .always;
            if (std.mem.eql(u8, s, "dev-only")) return .dev_only;
            return .always;
        },
        else => return .always,
    }
}

/// `sourcemapMode` 옵션 (#2152) — `"linked"` / `"external"` / `"inline"` 한정.
/// 미지정 또는 invalid 면 `.linked` (default).
fn parseSourceMapMode(env: c.napi_env, obj: c.napi_value) SourceMap.SourceMapMode {
    var buf: [16]u8 = undefined;
    const val = getNamedProperty(env, obj, "sourcemapMode") orelse return .linked;
    var len: usize = 0;
    if (c.napi_get_value_string_utf8(env, val, &buf, buf.len, &len) != c.napi_ok) return .linked;
    return SourceMap.SourceMapMode.fromString(buf[0..len]) orelse .linked;
}

/// `logLevel` 옵션 (#2158) — `"silent"` / `"error"` / `"warning"` / `"info"` / `"debug"` / `"verbose"`.
/// 미지정 또는 invalid 면 `.warning` (default — errors + warnings 모두 emit).
pub const LogLevelFilter = struct { allow_errors: bool, allow_warnings: bool };
pub const LogFilterOptions = struct { filter: LogLevelFilter, limit: u32 };

fn parseLogLevelFilter(env: c.napi_env, obj: c.napi_value) LogLevelFilter {
    var buf: [16]u8 = undefined;
    const val = getNamedProperty(env, obj, "logLevel") orelse return .{ .allow_errors = true, .allow_warnings = true };
    var len: usize = 0;
    if (c.napi_get_value_string_utf8(env, val, &buf, buf.len, &len) != c.napi_ok) {
        return .{ .allow_errors = true, .allow_warnings = true };
    }
    const s = buf[0..len];
    if (std.mem.eql(u8, s, "silent")) return .{ .allow_errors = false, .allow_warnings = false };
    if (std.mem.eql(u8, s, "error")) return .{ .allow_errors = true, .allow_warnings = false };
    return .{ .allow_errors = true, .allow_warnings = true };
}

pub fn parseLogFilterOptions(env: c.napi_env, obj: c.napi_value) LogFilterOptions {
    return .{
        .filter = parseLogLevelFilter(env, obj),
        .limit = getObjectUint32(env, obj, "logLimit", 0),
    };
}

/// `outputExports` 옵션 (#2159) — `"auto"` / `"named"` / `"default"` / `"none"`.
/// 미지정 또는 invalid 면 `.auto` (Rollup default).
fn parseOutputExports(env: c.napi_env, obj: c.napi_value) bundler_mod.OutputExports {
    var buf: [16]u8 = undefined;
    const val = getNamedProperty(env, obj, "outputExports") orelse return .auto;
    var len: usize = 0;
    if (c.napi_get_value_string_utf8(env, val, &buf, buf.len, &len) != c.napi_ok) return .auto;
    return bundler_mod.OutputExports.fromString(buf[0..len]) orelse .auto;
}

fn resolveEntryPoint(alloc: std.mem.Allocator, path: []const u8) ?[]const u8 {
    const resolved = std.fs.cwd().realpathAlloc(alloc, path) catch return alloc.dupe(u8, path) catch null;
    return resolved;
}

// ─── runtimePolyfillPlan 객체 파싱 헬퍼 ───
// JS wrapper 가 8 개 parallel 배열 대신 단일 객체로 plan 을 넘기게 했으므로
// 여기서 한 번에 푼다. 길이 equality 같은 invariant 가 객체 구조에 자연스럽게 들어가
// 별도 검증이 필요 없다.

const RuntimePolyfillParseError = error{InvalidPlan} || std.mem.Allocator.Error;

// 호출처에서 alloc 은 항상 native_alloc 이라, 양쪽이 갈라지면 owned_strings 와
// 다른 allocator 로 free 시도해서 곧 망가진다. 시그니처에서 alloc 을 제거해
// 일관성을 강제한다.
fn ownPlanString(
    env: c.napi_env,
    elem: c.napi_value,
    key: [*:0]const u8,
    error_msg: [*:0]const u8,
    owned_strings: *std.ArrayList([]const u8),
) RuntimePolyfillParseError![]const u8 {
    const s = getObjectString(env, elem, key, native_alloc) orelse {
        _ = throwError(env, error_msg);
        return error.InvalidPlan;
    };
    errdefer native_alloc.free(s);
    try owned_strings.append(native_alloc, s);
    return s;
}

fn planArrayLen(env: c.napi_env, arr_val: c.napi_value, error_msg: [*:0]const u8) RuntimePolyfillParseError!u32 {
    var is_array: bool = false;
    _ = c.napi_is_array(env, arr_val, &is_array);
    if (!is_array) {
        _ = throwError(env, error_msg);
        return error.InvalidPlan;
    }
    var len: u32 = 0;
    _ = c.napi_get_array_length(env, arr_val, &len);
    return len;
}

fn parseRuntimePolyfillCandidatesArray(
    env: c.napi_env,
    plan_val: c.napi_value,
    owned_strings: *std.ArrayList([]const u8),
) RuntimePolyfillParseError![]const bundler_mod.runtime_polyfills.Candidate {
    const arr_val = getNamedProperty(env, plan_val, "candidates") orelse return &.{};
    const len = try planArrayLen(env, arr_val, "runtimePolyfillPlan.candidates must be an array");
    if (len == 0) return &.{};
    const buf = try native_alloc.alloc(bundler_mod.runtime_polyfills.Candidate, len);
    errdefer native_alloc.free(buf);
    for (0..len) |i| {
        var elem: c.napi_value = undefined;
        if (c.napi_get_element(env, arr_val, @intCast(i), &elem) != c.napi_ok) {
            _ = throwError(env, "runtimePolyfillPlan.candidates entry inaccessible");
            return error.InvalidPlan;
        }
        const feature = try ownPlanString(env, elem, "feature", "runtimePolyfillPlan.candidates[].feature missing", owned_strings);
        if (feature.len == 0) {
            _ = throwError(env, "runtimePolyfillPlan.candidates[].feature must be non-empty");
            return error.InvalidPlan;
        }
        const module = try ownPlanString(env, elem, "module", "runtimePolyfillPlan.candidates[].module missing", owned_strings);
        const path = try ownPlanString(env, elem, "path", "runtimePolyfillPlan.candidates[].path missing", owned_strings);
        buf[i] = .{ .feature = feature, .module = module, .path = path };
    }
    return buf;
}

fn parseRuntimePolyfillResolvedArray(
    env: c.napi_env,
    plan_val: c.napi_value,
    key: [*:0]const u8,
    owned_strings: *std.ArrayList([]const u8),
) RuntimePolyfillParseError![]const bundler_mod.runtime_polyfills.ResolvedModule {
    const arr_val = getNamedProperty(env, plan_val, key) orelse return &.{};
    const len = try planArrayLen(env, arr_val, "runtimePolyfillPlan resolved-module array must be an array");
    if (len == 0) return &.{};
    const buf = try native_alloc.alloc(bundler_mod.runtime_polyfills.ResolvedModule, len);
    errdefer native_alloc.free(buf);
    for (0..len) |i| {
        var elem: c.napi_value = undefined;
        if (c.napi_get_element(env, arr_val, @intCast(i), &elem) != c.napi_ok) {
            _ = throwError(env, "runtimePolyfillPlan resolved-module entry inaccessible");
            return error.InvalidPlan;
        }
        const module = try ownPlanString(env, elem, "module", "runtimePolyfillPlan resolved-module[].module missing", owned_strings);
        const path = try ownPlanString(env, elem, "path", "runtimePolyfillPlan resolved-module[].path missing", owned_strings);
        buf[i] = .{ .module = module, .path = path };
    }
    return buf;
}

fn parseRuntimePolyfillPlan(
    env: c.napi_env,
    opts_obj: c.napi_value,
    owned_strings: *std.ArrayList([]const u8),
    owned_string_arrays: *std.ArrayList([]const []const u8),
) RuntimePolyfillParseError!?bundler_mod.runtime_polyfills.Plan {
    const plan_val = getNamedProperty(env, opts_obj, "runtimePolyfillPlan") orelse return null;

    const mode_str = try ownPlanString(env, plan_val, "mode", "runtimePolyfillPlan.mode missing", owned_strings);
    const mode = bundler_mod.runtime_polyfills.Mode.fromString(mode_str) orelse {
        _ = throwError(env, "runtimePolyfillPlan.mode unknown");
        return error.InvalidPlan;
    };

    const candidates = try parseRuntimePolyfillCandidatesArray(env, plan_val, owned_strings);
    const entry_modules = try parseRuntimePolyfillResolvedArray(env, plan_val, "entry", owned_strings);
    const include = try parseRuntimePolyfillResolvedArray(env, plan_val, "include", owned_strings);

    var exclude: []const []const u8 = &.{};
    if (getNamedProperty(env, plan_val, "exclude")) |arr_val| {
        const parsed = parseStringArray(env, arr_val, native_alloc) orelse {
            _ = throwError(env, "runtimePolyfillPlan.exclude must be a string array");
            return error.InvalidPlan;
        };
        for (parsed) |s| try owned_strings.append(native_alloc, s);
        try owned_string_arrays.append(native_alloc, parsed);
        exclude = parsed;
    }

    return .{
        .mode = mode,
        .candidates = candidates,
        .entry_modules = entry_modules,
        .include = include,
        .exclude = exclude,
    };
}

/// BundleOptions 의 native_alloc-owned typed slices 일괄 free (#2396).
/// 내부 문자열은 owned_strings 가 소유 — 본 함수는 entry/target 배열 자체만 free.
/// 새 typed slice 옵션 추가 시 본 함수에 한 줄만 추가.
pub fn freeOptionsTypedSlices(opts: *const BundleOptions) void {
    if (opts.define.len > 0) native_alloc.free(opts.define);
    if (opts.module_specifier_map.len > 0) native_alloc.free(opts.module_specifier_map);
    if (opts.alias.len > 0) native_alloc.free(opts.alias);
    if (opts.ts_paths.len > 0) {
        for (opts.ts_paths) |entry| {
            if (entry.targets.len > 0) native_alloc.free(entry.targets);
        }
        native_alloc.free(opts.ts_paths);
    }
    if (opts.fallback.len > 0) native_alloc.free(opts.fallback);
    if (opts.globals.len > 0) native_alloc.free(opts.globals);
    if (opts.loader_overrides.len > 0) native_alloc.free(opts.loader_overrides);
    // PR-plumb (#3318): mf 있을 때만(비-MF 무영향). opts.external=combined
    // (ext_c), opts.globals=combined(gl_c, 위 줄에서 free). exts/옛 entries_buf
    // 는 owned_string_arrays/파싱블록이 별도 소유 → 여기서 안 건드림(이중
    // 해제 없음). mfb 의 dup 문자열은 freeMfBundle 단일 소스(CLI 와 공유).
    if (opts.mf) |mfb| {
        native_alloc.free(opts.external); // combined 컨테이너(원소 borrow)
        bundler_mod.mf_options.freeMfBundle(native_alloc, mfb);
    }
    if (opts.runtime_polyfills) |plan| {
        if (plan.candidates.len > 0) native_alloc.free(plan.candidates);
        if (plan.entry_modules.len > 0) native_alloc.free(plan.entry_modules);
        if (plan.include.len > 0) native_alloc.free(plan.include);
    }
}

/// 옵션 파싱 함수. owned_strings/owned_string_arrays에 할당된 메모리를 추적.
/// 반환된 BundleOptions의 문자열은 owned 리스트가 소유.
pub fn parseBuildOptions(
    env: c.napi_env,
    opts_obj: c.napi_value,
    owned_strings: *std.ArrayList([]const u8),
    owned_string_arrays: *std.ArrayList([]const []const u8),
) ?BundleOptions {
    // 문자열 소유권 추적 헬퍼 (OOM 시 false 반환)
    const trackStr = struct {
        fn f(list: *std.ArrayList([]const u8), s: []const u8) bool {
            list.append(native_alloc, s) catch return false;
            return true;
        }
    }.f;
    const trackArr = struct {
        fn f(list: *std.ArrayList([]const []const u8), arr: []const []const u8) bool {
            list.append(native_alloc, arr) catch return false;
            return true;
        }
    }.f;

    // entryPoints
    const raw_entries = getObjectStringArray(env, opts_obj, "entryPoints", native_alloc) orelse return null;
    for (raw_entries) |e| if (!trackStr(owned_strings, e)) return null;
    if (!trackArr(owned_string_arrays, raw_entries)) return null;

    const entries = native_alloc.alloc([]const u8, raw_entries.len) catch return null;
    if (!trackArr(owned_string_arrays, entries)) return null;
    for (raw_entries, 0..) |e, i| {
        entries[i] = resolveEntryPoint(native_alloc, e) orelse return null;
        if (!trackStr(owned_strings, entries[i])) return null;
    }

    // format
    const format_str = getObjectString(env, opts_obj, "format", native_alloc);
    if (format_str) |s| if (!trackStr(owned_strings, s)) return null;
    const format: EmitFormat = if (format_str) |s|
        std.meta.stringToEnum(EmitFormat, s) orelse .esm
    else
        .esm;

    // platform
    const platform_str = getObjectString(env, opts_obj, "platform", native_alloc);
    if (platform_str) |s| if (!trackStr(owned_strings, s)) return null;
    const platform: Platform = if (platform_str) |s|
        if (std.mem.eql(u8, s, "node")) .node else if (std.mem.eql(u8, s, "neutral")) .neutral else if (std.mem.eql(u8, s, "react-native")) .react_native else .browser
    else
        .browser;

    // external
    const external = getObjectStringArray(env, opts_obj, "external", native_alloc);
    if (external) |exts| {
        for (exts) |e| if (!trackStr(owned_strings, e)) return null;
        if (!trackArr(owned_string_arrays, exts)) return null;
    }

    // debug: 활성화할 디버그 로그 카테고리 목록 (ZNTC_DEBUG env 와 합집합).
    const debug_categories = getObjectStringArray(env, opts_obj, "debug", native_alloc);
    if (debug_categories) |cats| {
        for (cats) |s| if (!trackStr(owned_strings, s)) return null;
        if (!trackArr(owned_string_arrays, cats)) return null;
    }

    // profile / profileLevel / profileFormat: 프로세스 전역 `profile` 모듈 상태를 조작.
    // JS 에서 \{ profile: ["parse", "transform"], profileLevel: "detailed", profileFormat: "json" \}
    // 식으로 전달. env (ZNTC_PROFILE) 와 합집합. CLI `--profile=...` 와 동일한 의미.
    if (getObjectStringArray(env, opts_obj, "profile", native_alloc)) |cats| {
        for (cats) |s| if (!trackStr(owned_strings, s)) return null;
        if (!trackArr(owned_string_arrays, cats)) return null;
        profile_mod.resetCounters();
        profile_mod.addCategories(cats);
    }
    if (getObjectString(env, opts_obj, "profileLevel", native_alloc)) |lvl| {
        defer native_alloc.free(lvl);
        if (profile_mod.Level.fromString(lvl)) |parsed| {
            profile_mod.setLevel(parsed);
        }
    }
    // profileFormat 은 NAPI 반환 포맷 결정 — BundleOptions 에 별도 필드로 저장 (아래).

    // 문자열 옵션 헬퍼
    const ownStr = struct {
        fn f(e: c.napi_env, obj: c.napi_value, key: [*:0]const u8, list: *std.ArrayList([]const u8)) ?[]const u8 {
            const s = getObjectString(e, obj, key, native_alloc) orelse return null;
            list.append(native_alloc, s) catch {
                native_alloc.free(s);
                return null;
            };
            return s;
        }
    }.f;

    const banner_js = ownStr(env, opts_obj, "banner", owned_strings);
    const footer_js = ownStr(env, opts_obj, "footer", owned_strings);
    const intro_js = ownStr(env, opts_obj, "intro", owned_strings);
    const outro_js = ownStr(env, opts_obj, "outro", owned_strings);
    const global_name = ownStr(env, opts_obj, "globalName", owned_strings);
    const public_path = ownStr(env, opts_obj, "publicPath", owned_strings);
    const entry_names = ownStr(env, opts_obj, "entryNames", owned_strings);
    const chunk_names = ownStr(env, opts_obj, "chunkNames", owned_strings);
    const asset_names = ownStr(env, opts_obj, "assetNames", owned_strings);
    // assetRegistry: string (경로), null/undefined (플랫폼 프리셋 결정), false (명시적 off).
    // false를 구분하기 위해 boolean 타입을 별도 체크.
    const asset_registry: ?[]const u8 = blk: {
        if (getNamedProperty(env, opts_obj, "assetRegistry")) |v| {
            var t: c.napi_valuetype = undefined;
            _ = c.napi_typeof(env, v, &t);
            if (t == c.napi_boolean) {
                var b: bool = false;
                _ = c.napi_get_value_bool(env, v, &b);
                if (!b) break :blk null; // false → off (RN preset도 덮음)
            } else if (t == c.napi_string) {
                const s = getStringArg(env, v, native_alloc) orelse break :blk null;
                if (!trackStr(owned_strings, s)) return null;
                break :blk s;
            }
        }
        // 미지정 + RN 플랫폼 → 기본 경로. 그 외 → null.
        if (platform == .react_native) {
            break :blk bundler_mod.RN_DEFAULT_ASSET_REGISTRY;
        }
        break :blk null;
    };

    // JSX — string→enum 변환만 여기서. 최종 런타임/factory 결정은 tsconfig_merge 에 위임
    // (file/raw tsconfig 의 "jsx"/"jsxFactory" 등을 함께 고려).
    // 유효 vocab: "automatic" / "automatic-dev" / "classic" / "preserve"
    // (`transpile.zig::optionsFromJson` 의 enum-strict 동작과 일관). tsconfig vocab
    // ("react" / "react-jsx" / "react-jsxdev" / "react-native") 또는 typo 는 throw —
    // 이전 silent classic fallback 은 사용자 디버깅을 어렵게 했음.
    const jsx_str = ownStr(env, opts_obj, "jsx", owned_strings);
    const jsx_runtime_explicit: ?JsxRuntime = if (jsx_str) |s| blk: {
        if (JsxRuntime.fromString(s)) |r| break :blk r;
        // parseBuildOptions 반환 타입이 ?BundleOptions 라 throwError 의 napi_value 결과를 그대로
        // return 못 함 — discard 후 null 반환. caller 의 `orelse return throwError(...)` 가
        // already-pending exception 위에 다시 throw 시도하지만 NAPI spec 상 silent ignore 라 안전.
        _ = throwError(env, "invalid 'jsx' option (expected automatic / automatic-dev / classic / preserve)");
        return null;
    } else null;
    const jsx_factory = ownStr(env, opts_obj, "jsxFactory", owned_strings);
    const jsx_fragment = ownStr(env, opts_obj, "jsxFragment", owned_strings);
    const jsx_import_source = ownStr(env, opts_obj, "jsxImportSource", owned_strings);

    // inject
    const inject = getObjectStringArray(env, opts_obj, "inject", native_alloc);
    if (inject) |arr| {
        for (arr) |s| if (!trackStr(owned_strings, s)) return null;
        if (!trackArr(owned_string_arrays, arr)) return null;
    }

    // define: { "key": "value" } → []DefineEntry
    const define_pairs = getObjectKeyValuePairs(env, opts_obj, "define", native_alloc);
    var define_entries: []const DefineEntry = &.{};
    if (define_pairs) |pairs| {
        const defs = native_alloc.alloc(DefineEntry, pairs.len) catch return null;
        for (pairs, 0..) |pair, idx| {
            if (!trackStr(owned_strings, pair[0])) return null;
            if (!trackStr(owned_strings, pair[1])) return null;
            defs[idx] = .{ .key = pair[0], .value = pair[1] };
        }
        // pairs 배열 자체는 해제 (키/값은 owned_strings가 소유)
        native_alloc.free(pairs);
        define_entries = defs;
    }

    // moduleSpecifierMap: { 'lodash': 'lodash/{name}' } → []ModuleSpecifierMapEntry (#2393).
    // babel-plugin-lodash 등 cherry-pick 분해 generic 매핑.
    const msm_pairs = getObjectKeyValuePairs(env, opts_obj, "moduleSpecifierMap", native_alloc);
    var module_specifier_map: []const ModuleSpecifierMapEntry = &.{};
    if (msm_pairs) |pairs| {
        defer native_alloc.free(pairs);
        const msm_entries = native_alloc.alloc(ModuleSpecifierMapEntry, pairs.len) catch return null;
        for (pairs, 0..) |pair, idx| {
            if (!trackStr(owned_strings, pair[0])) return null;
            if (!trackStr(owned_strings, pair[1])) return null;
            msm_entries[idx] = .{ .module = pair[0], .template = pair[1] };
        }
        module_specifier_map = msm_entries;
    }

    // alias: { "from": "to" } → []AliasEntry (tsconfig paths 는 tsconfig 로드 후 아래에서 append).
    const alias_pairs = getObjectKeyValuePairs(env, opts_obj, "alias", native_alloc);
    var alias_list: std.ArrayList(bundler_mod.types.AliasEntry) = .empty;
    if (alias_pairs) |pairs| {
        defer native_alloc.free(pairs);
        for (pairs) |pair| {
            if (!trackStr(owned_strings, pair[0])) return null;
            if (!trackStr(owned_strings, pair[1])) return null;
            alias_list.append(native_alloc, .{ .from = pair[0], .to = pair[1] }) catch return null;
        }
    }

    // fallback: { "crypto": "crypto-browserify", "fs": false } → []FallbackEntry
    // 값이 `false`면 빈 모듈, 문자열이면 해당 specifier로 재해석.
    const fallback_pairs = getObjectKeyValuePairsWithNullable(env, opts_obj, "fallback", native_alloc);
    var fallback_entries: []const bundler_mod.types.FallbackEntry = &.{};
    if (fallback_pairs) |pairs| {
        const fbs = native_alloc.alloc(bundler_mod.types.FallbackEntry, pairs.len) catch return null;
        for (pairs, 0..) |pair, idx| {
            if (!trackStr(owned_strings, pair[0])) return null;
            if (pair[1]) |v| if (!trackStr(owned_strings, v)) return null;
            fbs[idx] = .{ .from = pair[0], .to = pair[1] };
        }
        native_alloc.free(pairs);
        fallback_entries = fbs;
    }

    const global_pairs = getObjectKeyValuePairs(env, opts_obj, "globals", native_alloc);
    var globals: []const bundler_mod.types.GlobalEntry = &.{};
    if (global_pairs) |pairs| {
        const entries_buf = native_alloc.alloc(bundler_mod.types.GlobalEntry, pairs.len) catch return null;
        for (pairs, 0..) |pair, idx| {
            if (!trackStr(owned_strings, pair[0])) return null;
            if (!trackStr(owned_strings, pair[1])) return null;
            entries_buf[idx] = .{ .specifier = pair[0], .global_name = pair[1] };
        }
        native_alloc.free(pairs);
        globals = entries_buf;
    }

    // loader: { ".png": "file", ".svg": "text" } → []LoaderOverride
    const loader_pairs = getObjectKeyValuePairs(env, opts_obj, "loader", native_alloc);
    var loader_overrides: []const bundler_mod.types.LoaderOverride = &.{};
    if (loader_pairs) |pairs| {
        const overrides = native_alloc.alloc(bundler_mod.types.LoaderOverride, pairs.len) catch return null;
        var valid_count: usize = 0;
        for (pairs) |pair| {
            if (!trackStr(owned_strings, pair[0])) return null;
            if (!trackStr(owned_strings, pair[1])) return null;
            const parsed_loader = bundler_mod.types.ParsedLoader.fromString(pair[1]) orelse continue;
            overrides[valid_count] = .{
                .ext = pair[0],
                .loader = parsed_loader.loader,
                .module_type = parsed_loader.module_type,
            };
            valid_count += 1;
        }
        native_alloc.free(pairs);
        loader_overrides = overrides[0..valid_count];
    }

    const conditions = getObjectStringArray(env, opts_obj, "conditions", native_alloc);
    if (conditions) |arr| {
        for (arr) |s| if (!trackStr(owned_strings, s)) return null;
        if (!trackArr(owned_string_arrays, arr)) return null;
    }

    const resolve_extensions = getObjectStringArray(env, opts_obj, "resolveExtensions", native_alloc);
    if (resolve_extensions) |arr| {
        for (arr) |s| if (!trackStr(owned_strings, s)) return null;
        if (!trackArr(owned_string_arrays, arr)) return null;
    }

    const main_fields = getObjectStringArray(env, opts_obj, "mainFields", native_alloc);
    if (main_fields) |arr| {
        for (arr) |s| if (!trackStr(owned_strings, s)) return null;
        if (!trackArr(owned_string_arrays, arr)) return null;
    }

    const target_str = getObjectString(env, opts_obj, "target", native_alloc);
    if (target_str) |s| if (!trackStr(owned_strings, s)) return null;
    // JS side (browserslist 해석 등)에서 미리 계산한 unsupported bitmask가 있으면 우선.
    // 0이면 미설정으로 간주 — 어차피 unsupported=0은 esnext와 동일해서 target 기반 경로로 fallback해도 결과 동일.
    const unsupported_override = getObjectUint32(env, opts_obj, "unsupported", 0);
    const unsupported: compat.UnsupportedFeatures = if (unsupported_override != 0)
        @bitCast(unsupported_override)
    else if (target_str) |s|
        if (std.meta.stringToEnum(compat.ESTarget, s)) |t| compat.fromESTarget(t) else .{}
    else
        .{};

    const outfile = ownStr(env, opts_obj, "outfile", owned_strings);
    const outbase = ownStr(env, opts_obj, "outbase", owned_strings);
    const tsconfig_raw = ownStr(env, opts_obj, "tsconfigRaw", owned_strings);
    const tsconfig_path_js = ownStr(env, opts_obj, "tsconfigPath", owned_strings);

    // tsconfig 로드 + 머지 — JS 옵션이 명시적으로 설정된 필드가 우선 (ExplicitFlags 경로).
    // raw 우선 (esbuild 동등): `tsconfigRaw` 가 있으면 file 기반 path / 자동 탐색을 모두 무시.
    // raw parse 실패는 silent (빈 TsConfig) — JS 측이 NAPI 호출 전 사전 검증해 명시 에러를 던진다.
    // 머지 규칙은 `src/tsconfig_merge.zig` 의 공용 helper — transpile.zig 와 일관.
    var tsconfig_holder: TsConfig = .{};
    var autodiscovered_dir: ?[]const u8 = null;
    defer if (autodiscovered_dir) |d| native_alloc.free(d);
    const tsconfig_path_opt: ?[]const u8 = if (tsconfig_raw != null) null else tsconfig_path_js orelse blk: {
        // entry 가 하나라도 있으면 그 dirname 기준, 없으면 cwd ("." → dirname → ".") 부터 탐색.
        const start_path: []const u8 = if (entries.len > 0) entries[0] else ".";
        autodiscovered_dir = TsConfig.autodiscoverFromEntry(native_alloc, start_path);
        break :blk autodiscovered_dir;
    };
    if (tsconfig_raw) |raw| {
        tsconfig_holder = TsConfig.parseFromString(native_alloc, raw) catch TsConfig{};
    } else if (tsconfig_path_opt) |p| {
        tsconfig_holder = TsConfig.loadFromPath(native_alloc, p) catch TsConfig{};
    }
    defer tsconfig_holder.deinit();

    const merged_tsconfig = tsconfig_merge.merge(&tsconfig_holder, .{
        .experimental_decorators = getObjectBoolOptional(env, opts_obj, "experimentalDecorators"),
        .emit_decorator_metadata = getObjectBoolOptional(env, opts_obj, "emitDecoratorMetadata"),
        .use_define_for_class_fields = getObjectBoolOptional(env, opts_obj, "useDefineForClassFields"),
        .verbatim_module_syntax = getObjectBoolOptional(env, opts_obj, "verbatimModuleSyntax"),
        .jsx_runtime = jsx_runtime_explicit,
        .jsx_factory = jsx_factory,
        .jsx_fragment = jsx_fragment,
        .jsx_import_source = jsx_import_source,
    });
    const experimental_decorators_eff = merged_tsconfig.experimental_decorators;
    const emit_decorator_metadata_eff = merged_tsconfig.emit_decorator_metadata;
    const use_define_for_class_fields_eff = merged_tsconfig.use_define_for_class_fields;
    const verbatim_module_syntax_eff = merged_tsconfig.verbatim_module_syntax;
    const jsx_runtime_eff = merged_tsconfig.jsx_runtime;
    const jsx_factory_eff = merged_tsconfig.jsx_factory;
    const jsx_fragment_eff = merged_tsconfig.jsx_fragment;
    const jsx_import_source_eff = merged_tsconfig.jsx_import_source;

    const alias_entries: []const bundler_mod.types.AliasEntry = alias_list.toOwnedSlice(native_alloc) catch return null;

    // tsconfig paths → resolver 의 ts_paths 로 전달 (alias 와 독립 경로).
    // TS 스펙대로 wildcard anywhere + 다중 후보 순차 시도를 resolver 가 담당.
    var ts_path_entries: []const TsConfig.PathEntry = &.{};
    if (tsconfig_path_opt != null and tsconfig_holder.paths.len > 0) {
        const dir_for_join = config_mod.tsconfigDirFromPath(tsconfig_path_opt.?);
        if (config_mod.resolveTsPaths(native_alloc, dir_for_join, &tsconfig_holder)) |resolved| {
            // target.prefix 로 join 된 절대 경로들을 tracker 에 등록 — opts 수명 동안 살아있도록.
            if (resolved.owned_strings.len > 0) {
                for (resolved.owned_strings) |s| if (!trackStr(owned_strings, s)) return null;
                if (!trackArr(owned_string_arrays, resolved.owned_strings)) return null;
            }
            ts_path_entries = resolved.entries;
            // entries 슬라이스와 각 entry.targets 슬라이스는 BundleOptions typed slice 정리 경로에서 해제.
        } else |_| {}
    }

    const out_extension_js = ownStr(env, opts_obj, "outExtension", owned_strings);
    const source_root = ownStr(env, opts_obj, "sourceRoot", owned_strings);
    const root_dir = ownStr(env, opts_obj, "rootDir", owned_strings);
    const preserve_modules_root = ownStr(env, opts_obj, "preserveModulesRoot", owned_strings);

    // legalComments: "none" | "inline" | "eof" | "linked"
    // RN preset: 사용자가 명시 안 했으면 .none default (Metro 패턴 정합).
    const legal_str = getObjectString(env, opts_obj, "legalComments", native_alloc);
    if (legal_str) |s| if (!trackStr(owned_strings, s)) return null;
    const legal_comments: bundler_mod.types.LegalComments = if (legal_str) |s|
        if (std.mem.eql(u8, s, "none")) .none else if (std.mem.eql(u8, s, "inline")) .@"inline" else if (std.mem.eql(u8, s, "eof")) .eof else if (std.mem.eql(u8, s, "linked")) .linked else .default
    else if (platform == .react_native)
        .none
    else
        .default;

    // globalIdentifiers: string[]
    const global_identifiers = getObjectStringArray(env, opts_obj, "globalIdentifiers", native_alloc);
    if (global_identifiers) |arr| {
        for (arr) |s| if (!trackStr(owned_strings, s)) return null;
        if (!trackArr(owned_string_arrays, arr)) return null;
    }

    // polyfills: string[]
    const polyfills = getObjectStringArray(env, opts_obj, "polyfills", native_alloc);
    if (polyfills) |arr| {
        for (arr) |s| if (!trackStr(owned_strings, s)) return null;
        if (!trackArr(owned_string_arrays, arr)) return null;
    }

    // runBeforeMain: string[]
    const run_before_main = getObjectStringArray(env, opts_obj, "runBeforeMain", native_alloc);
    if (run_before_main) |arr| {
        for (arr) |s| if (!trackStr(owned_strings, s)) return null;
        if (!trackArr(owned_string_arrays, arr)) return null;
    }

    const runtime_polyfill_plan = parseRuntimePolyfillPlan(env, opts_obj, owned_strings, owned_string_arrays) catch return null;

    // silentConsoleErrorPatterns: string[] (RegExp source strings)
    const silent_console_error_patterns = getObjectStringArray(env, opts_obj, "silentConsoleErrorPatterns", native_alloc);
    if (silent_console_error_patterns) |arr| {
        for (arr) |s| if (!trackStr(owned_strings, s)) return null;
        if (!trackArr(owned_string_arrays, arr)) return null;
    }

    // dropLabels: string[]
    const drop_labels = getObjectStringArray(env, opts_obj, "dropLabels", native_alloc);
    if (drop_labels) |arr| {
        for (arr) |s| if (!trackStr(owned_strings, s)) return null;
        if (!trackArr(owned_string_arrays, arr)) return null;
    }

    // emotionExtraCssSources / emotionExtraStyledSources: string[]
    const emotion_extra_css = getObjectStringArray(env, opts_obj, "emotionExtraCssSources", native_alloc);
    if (emotion_extra_css) |arr| {
        for (arr) |s| if (!trackStr(owned_strings, s)) return null;
        if (!trackArr(owned_string_arrays, arr)) return null;
    }
    const emotion_extra_styled = getObjectStringArray(env, opts_obj, "emotionExtraStyledSources", native_alloc);
    if (emotion_extra_styled) |arr| {
        for (arr) |s| if (!trackStr(owned_strings, s)) return null;
        if (!trackArr(owned_string_arrays, arr)) return null;
    }

    // styledComponentsMeaninglessFileNames: string[]
    const sc_meaningless = getObjectStringArray(env, opts_obj, "styledComponentsMeaninglessFileNames", native_alloc);
    if (sc_meaningless) |arr| {
        for (arr) |s| if (!trackStr(owned_strings, s)) return null;
        if (!trackArr(owned_string_arrays, arr)) return null;
    }

    // styledComponentsTopLevelImportPaths: string[]
    const sc_top_level = getObjectStringArray(env, opts_obj, "styledComponentsTopLevelImportPaths", native_alloc);
    if (sc_top_level) |arr| {
        for (arr) |s| if (!trackStr(owned_strings, s)) return null;
        if (!trackArr(owned_string_arrays, arr)) return null;
    }
    const styled_components_namespace = ownStr(env, opts_obj, "styledComponentsNamespace", owned_strings);
    const emotion_label_format = ownStr(env, opts_obj, "emotionLabelFormat", owned_strings);

    // pure: string[]
    const pure = getObjectStringArray(env, opts_obj, "pure", native_alloc);
    if (pure) |arr| {
        for (arr) |s| if (!trackStr(owned_strings, s)) return null;
        if (!trackArr(owned_string_arrays, arr)) return null;
    }

    // blockList: string[] (JS 쪽에서 RegExp는 .source로 변환해서 전달)
    const block_list = getObjectStringArray(env, opts_obj, "blockList", native_alloc);
    if (block_list) |arr| {
        for (arr) |s| if (!trackStr(owned_strings, s)) return null;
        if (!trackArr(owned_string_arrays, arr)) return null;
    }

    // nodePaths: string[]
    const node_paths = getObjectStringArray(env, opts_obj, "nodePaths", native_alloc);
    if (node_paths) |arr| {
        for (arr) |s| if (!trackStr(owned_strings, s)) return null;
        if (!trackArr(owned_string_arrays, arr)) return null;
    }

    // RN block_list 머지를 여기서 선계산(hoist) — return literal 안에 두면
    // mf 블록 *이후* fallible(concat OOM/trackArr) 가 생겨 mf 의 mfb/
    // combined 가 null 경로에서 leak. 위로 끌어 mf 블록 이후 무-fallible
    // 보장(merged 는 trackArr 로 owned_string_arrays 소유 → null 경로도 정리).
    const block_list_final: []const []const u8 = blk: {
        const user = block_list orelse &.{};
        if (platform == .react_native) {
            const merged = std.mem.concat(native_alloc, []const u8, &.{ bundler_mod.RN_DEFAULT_BLOCK_LIST, user }) catch return null;
            if (!trackArr(owned_string_arrays, merged)) return null;
            break :blk merged;
        }
        break :blk user;
    };

    // PR-plumb (#3318): Module Federation. `mfRaw`(index.ts =
    // JSON.stringify(config.mf))를 JSON string 으로 받아 **CLI 와 동일
    // 단일 소스**(`mf_options`; src/cli/options.zig applyZntcConfigJson 의
    // arena+parseFromSliceLeaky 선례와 동형)로 변환·seam 유도. 배경/
    // silent-drift 봉인 근거 = `mf_options.zig` 모듈 doc. mf 없으면 블록
    // 미진입 → external/globals/.mf 기존 그대로(비-MF byte 동일 무회귀).
    //
    // 메모리: 이 파일은 `catch return null`(에러 아님)이라 errdefer 무효
    // 이고, 호출자는 null 시 freeOptionsTypedSlices 를 안 거친다 → 블록
    // 내 실패는 **명시 free 로 롤백**해야 leak 0. 성공 시 mfb/combined 는
    // BundleOptions 로 넘어가 freeOptionsTypedSlices 가 mf-게이트로 해제
    // (combined 컨테이너만; 원소 borrow=mfb/static, exts/옛globals 는 각
    // owned_string_arrays/아래 free 소유). 블록 *이후* fallible 가 없도록
    // RN block_list 머지는 위에서 const 로 선계산(literal 내 잔존 X).
    const MfParsed = struct {
        mfb: bundler_mod.mf_options.MfBundleConfig,
        external: []const []const u8,
        globals: []const bundler_mod.types.GlobalEntry,
    };
    const mf_parsed: ?MfParsed = blk: {
        const raw = getObjectString(env, opts_obj, "mfRaw", native_alloc) orelse break :blk null;
        defer native_alloc.free(raw);
        var mf_arena = std.heap.ArenaAllocator.init(native_alloc);
        defer mf_arena.deinit();
        const dto = std.json.parseFromSliceLeaky(zntc_lib.transpile.MfConfigDto, mf_arena.allocator(), raw, .{ .ignore_unknown_fields = true }) catch return null;
        zntc_lib.transpile.validateMf(&dto) catch return null;
        // fromDto 실패 = 내부 errdefer 가 부분 mfb 해제(여기 롤백 불요).
        const mfb = bundler_mod.mf_options.fromDto(native_alloc, &dto) catch return null;
        // 이후 실패는 mfb(+필요 시 ext_c) 명시 free 후 return null.
        const se = bundler_mod.mf_options.seamExternals(native_alloc, mfb) catch {
            bundler_mod.mf_options.freeMfBundle(native_alloc, mfb);
            return null;
        };
        defer native_alloc.free(se); // 컨테이너만(원소 borrow)
        const sg = bundler_mod.mf_options.seamGlobals(native_alloc, mfb) catch {
            bundler_mod.mf_options.freeMfBundle(native_alloc, mfb);
            return null;
        };
        defer native_alloc.free(sg);
        const base_ext: []const []const u8 = external orelse &.{};
        const ext_c = std.mem.concat(native_alloc, []const u8, &.{ base_ext, se }) catch {
            bundler_mod.mf_options.freeMfBundle(native_alloc, mfb);
            return null;
        };
        const gl_c = std.mem.concat(native_alloc, bundler_mod.types.GlobalEntry, &.{ globals, sg }) catch {
            native_alloc.free(ext_c);
            bundler_mod.mf_options.freeMfBundle(native_alloc, mfb);
            return null;
        };
        // 옛 globals(entries_buf)는 어디서도 추적 안 됨 → concat 이 복사한
        // *후* 해제(cleanup 은 combined gl_c=opts.globals 만; exts 는
        // owned_string_arrays 소유라 미해제).
        if (globals.len > 0) native_alloc.free(globals);
        break :blk .{ .mfb = mfb, .external = ext_c, .globals = gl_c };
    };

    const minify = getObjectBool(env, opts_obj, "minify", false);
    return .{
        .entry_points = entries,
        .format = format,
        .platform = platform,
        .external = if (mf_parsed) |m| m.external else (external orelse &.{}),
        .mf = if (mf_parsed) |m| m.mfb else null,
        .debug = debug_categories orelse &.{},
        .define = define_entries,
        .alias = alias_entries,
        .ts_paths = ts_path_entries,
        .fallback = fallback_entries,
        .block_list = block_list_final,
        .minify_whitespace = if (minify) true else getObjectBool(env, opts_obj, "minifyWhitespace", false),
        .minify_identifiers = if (minify) true else getObjectBool(env, opts_obj, "minifyIdentifiers", false),
        .minify_syntax = if (minify) true else getObjectBool(env, opts_obj, "minifySyntax", false),
        // mf.exposes(remote) → expose=lazy 청크라 splitting 강제(CLI
        // options.zig 의 `if (mfb.exposes.len>0) opts.splitting=true` 미러).
        .code_splitting = getObjectBool(env, opts_obj, "splitting", false) or
            (if (mf_parsed) |m| m.mfb.exposes.len > 0 else false),
        .inline_dynamic_imports = getObjectBool(env, opts_obj, "inlineDynamicImports", false),
        .min_chunk_size = @as(usize, getObjectUint32(env, opts_obj, "minChunkSize", 0)),
        .sourcemap = .{
            .enable = getObjectBool(env, opts_obj, "sourcemap", false),
            .mode = parseSourceMapMode(env, opts_obj),
            .debug_ids = getObjectBool(env, opts_obj, "sourcemapDebugIds", false),
            .sources_content = getObjectBool(env, opts_obj, "sourcesContent", true),
            .source_root = source_root,
            // lazy 는 PR #2 에서 NAPI watch 세션에 한정해 true 로 설정.
        },
        .tree_shaking = getObjectBool(env, opts_obj, "treeShaking", true),
        .scope_hoist = getObjectBool(env, opts_obj, "scopeHoist", true),
        .metafile = getObjectBool(env, opts_obj, "metafile", false),
        .keep_names = getObjectBool(env, opts_obj, "keepNames", false),
        .shim_missing_exports = getObjectBool(env, opts_obj, "shimMissingExports", false),
        .flow = getObjectBool(env, opts_obj, "flow", false) or (platform == .react_native and bundler_mod.RN_BOOL_PRESET.flow),
        .jsx_in_js = getObjectBool(env, opts_obj, "jsxInJs", false) or (platform == .react_native and bundler_mod.RN_BOOL_PRESET.jsx_in_js),
        .charset_utf8 = getObjectBool(env, opts_obj, "charsetUtf8", false),
        .use_define_for_class_fields = use_define_for_class_fields_eff,
        .experimental_decorators = experimental_decorators_eff,
        .emit_decorator_metadata = emit_decorator_metadata_eff,
        .module_specifier_map = module_specifier_map,
        .verbatim_module_syntax = verbatim_module_syntax_eff,
        .banner_js = banner_js,
        .footer_js = footer_js,
        .intro_js = intro_js,
        .outro_js = outro_js,
        .global_name = global_name,
        .globals = if (mf_parsed) |m| m.globals else globals,
        .public_path = public_path orelse "",
        .entry_names = entry_names orelse "[name]",
        .chunk_names = chunk_names orelse "[name]-[hash]",
        .asset_names = asset_names orelse "[name]-[hash]",
        .asset_registry = asset_registry,
        .jsx_runtime = jsx_runtime_eff,
        .jsx_factory = jsx_factory_eff,
        .jsx_fragment = jsx_fragment_eff,
        .jsx_import_source = jsx_import_source_eff,
        .inject = inject orelse &.{},
        .max_threads = getObjectUint32(env, opts_obj, "jobs", 0),
        .loader_overrides = loader_overrides,
        .conditions = conditions orelse &.{},
        .resolve_extensions = resolve_extensions orelse &.{},
        .main_fields = main_fields orelse &.{},
        .unsupported = unsupported,
        .output_filename = outfile orelse "bundle.js",
        .outbase = outbase,
        .packages_external = getObjectBool(env, opts_obj, "packagesExternal", false),
        .preserve_symlinks = getObjectBool(env, opts_obj, "preserveSymlinks", false),
        .resolve_symlink_siblings = getObjectBool(env, opts_obj, "resolveSymlinkSiblings", false),
        .ignore_annotations = getObjectBool(env, opts_obj, "ignoreAnnotations", false),
        .jsx_side_effects = getObjectBool(env, opts_obj, "jsxSideEffects", false),
        .analyze = getObjectBool(env, opts_obj, "analyze", false),
        .drop_labels = drop_labels orelse &.{},
        // #2155: bundle 모드에도 transpile 동일 drop console/debugger 적용.
        .drop_console = getObjectBool(env, opts_obj, "dropConsole", false),
        .drop_debugger = getObjectBool(env, opts_obj, "dropDebugger", false),
        // #2159: CJS / UMD entry export 형식 — auto / named / default / none.
        .output_exports = parseOutputExports(env, opts_obj),
        .pure = pure orelse &.{},
        .tsconfig_raw = tsconfig_raw,
        .node_paths = node_paths orelse &.{},
        .line_limit = getObjectUint32(env, opts_obj, "lineLimit", 0),
        .out_extension_js = out_extension_js,
        .legal_comments = legal_comments,
        .preserve_modules = getObjectBool(env, opts_obj, "preserveModules", false),
        .preserve_modules_root = preserve_modules_root,
        .dev_mode = getObjectBool(env, opts_obj, "devMode", false),
        .root_dir = root_dir,
        .react_refresh = getObjectBool(env, opts_obj, "reactRefresh", false),
        .styled_components = getObjectBool(env, opts_obj, "styledComponents", false),
        .styled_components_ssr = getObjectBool(env, opts_obj, "styledComponentsSsr", true),
        .styled_components_minify = getObjectBool(env, opts_obj, "styledComponentsMinify", false),
        .styled_components_file_name = getObjectBool(env, opts_obj, "styledComponentsFileName", true),
        .styled_components_pure = getObjectBool(env, opts_obj, "styledComponentsPure", false),
        .styled_components_namespace = styled_components_namespace orelse "",
        .styled_components_meaningless_file_names = sc_meaningless orelse &.{"index"},
        .styled_components_top_level_import_paths = sc_top_level orelse &.{},
        .styled_components_css_prop = getObjectBool(env, opts_obj, "styledComponentsCssProp", false),
        .emotion = getObjectBool(env, opts_obj, "emotion", false),
        .emotion_auto_label = getAutoLabelMode(env, opts_obj, native_alloc),
        .emotion_source_map = getObjectBool(env, opts_obj, "emotionSourceMap", false),
        .emotion_label_format = emotion_label_format orelse "",
        .emotion_extra_css_sources = emotion_extra_css orelse &.{},
        .emotion_extra_styled_sources = emotion_extra_styled orelse &.{},
        .collect_module_codes = getObjectBool(env, opts_obj, "collectModuleCodes", false),
        // RN 프리셋(bundler.zig의 RN_BOOL_PRESET 단일 소스): platform=react-native이면
        // 사용자가 명시하지 않아도 CLI와 동일하게 auto-enable. worklet_transform 없이는
        // node_modules/react-native-reanimated의 'worklet' directive가 serialize되지
        // 않아 LayoutAnimation 등에서 JSI getObject assert 실패로 크래시 발생.
        .configurable_exports = getObjectBool(env, opts_obj, "configurableExports", false) or (platform == .react_native and bundler_mod.RN_BOOL_PRESET.configurable_exports),
        .strict_execution_order = getObjectBool(env, opts_obj, "strictExecutionOrder", false) or (platform == .react_native and bundler_mod.RN_BOOL_PRESET.strict_execution_order),
        .entry_error_guard = getObjectBool(env, opts_obj, "entryErrorGuard", false) or (platform == .react_native and bundler_mod.RN_BOOL_PRESET.entry_error_guard),
        .worklet_transform = getObjectBool(env, opts_obj, "workletTransform", false) or (platform == .react_native and bundler_mod.RN_BOOL_PRESET.worklet_transform),
        .worklet_plugin_version = ownStr(env, opts_obj, "workletPluginVersion", owned_strings),
        // ZNTC native codegen — default 가 RN preset (platform=react-native 시 true). 사용자가
        // `codegenTransform: false` 명시하면 그게 우선 (escape hatch 동작 보장). OR 패턴은
        // false override 가 RN preset 의 true 에 묻혀 무력화되는 버그 있었음.
        .codegen_transform = getObjectBool(env, opts_obj, "codegenTransform", platform == .react_native and bundler_mod.RN_BOOL_PRESET.codegen_transform),
        .global_identifiers = global_identifiers orelse &.{},
        .polyfills = polyfills orelse &.{},
        .run_before_main = run_before_main orelse &.{},
        .runtime_polyfills = runtime_polyfill_plan,
        .silent_console_error_patterns = silent_console_error_patterns orelse &.{},
    };
}
