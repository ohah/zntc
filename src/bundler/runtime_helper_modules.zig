//! ZTS runtime helper virtual module loader (#1961).
//!
//! ## 배경
//!
//! ES5 다운레벨링 등에서 사용되는 runtime helper (`__generator`, `__async` 등) 는
//! 기존엔 `bundler/runtime_helpers.zig` 의 string 상수가 entry chunk preamble 에
//! prepend 되는 모델이었다. 단일 번들에선 helper 가 entry 한 곳에만 emit 되어 모든
//! 모듈이 free identifier 로 참조 가능했지만, code splitting + dynamic import 시
//! dynamic chunk 에 helper 정의가 없어 ReferenceError 발생 (#1961 의 `__generator`).
//!
//! 새 모델: helper 를 graph 의 1급 모듈로 만들면 chunk 간 helper 분배 == 일반 모듈의
//! chunk 분배. transformer 가 helper 사용 모듈 상단에 named import 를 emit 하면
//! plugin 이 resolveId/load 훅으로 source 를 반환 → graph 의 표준 module dedup
//! 메커니즘이 chunk 간 helper 공유를 자동 처리.
//!
//! ## 식별자 규약
//!
//! - **Internal ID** (graph 안): `\x00zts:runtime/<short>` (oxc 식 NULL prefix).
//!   NULL byte 가 다른 plugin/resolver 가 건드리지 못하게 하는 sentinel.
//! - **External ID** (chunk 파일명/import specifier/sourcemap source URL):
//!   `sanitizeId` 가 NULL prefix 제거 + `runtime-` prefix 부여. e.g. `runtime-generator`.
//! - **Module short name**: kebab-case (`generator`, `async`, `to-esm`, `es-decorator`).
//!
//! ## 묶음 모듈
//!
//! 일부 helper 정의 string 은 여러 helper 를 한 묶음으로 정의한다 (e.g.
//! DECORATOR_RUNTIME 의 `__decorateClass` + `__decorateParam` + `__defProp2`).
//! 묶음 단위 = 한 virtual module + 묶음 멤버 모두 named export. transformer 의
//! helper-base → module-short lookup 은 `moduleShortFor` 가 처리.
//!
//! ## 미등록 helper
//!
//! 다음 helper 들은 정의 string 상수 매핑이 아직 검증되지 않아 등록되지 않았다 —
//! `__spreadArray`, `__arrayLikeToArray`, `__toConsumableArray`, `__toBinary`,
//! `__name`, `__using`, `__callDispose`, `__classPrivateMethodInit`,
//! `__classPrivateMethodGet`, `__classPrivateFieldSet`,
//! `__classCheckPrivateStaticAccess`, `__classCheckPrivateStaticFieldDescriptor`,
//! `__classStaticPrivateFieldSpecGet`, `__classStaticPrivateFieldSpecSet`.
//! 미등록 helper 가 import 되면 plugin 이 null 반환 → 호출자가 기존 preamble 경로로
//! fallback. transformer 통합 PR 에서 이 helper 들의 매핑이 추가되며 fallback 도 제거된다.

const std = @import("std");
const rt = @import("runtime_helpers.zig");
const plugin_mod = @import("plugin.zig");
const names = @import("../runtime_helper_names.zig");

/// Internal virtual module ID prefix. NULL byte sentinel.
pub const ID_PREFIX = "\x00zts:runtime/";

/// 외부 노출 prefix. sanitize 결과 chunk 파일명/import specifier/sourcemap 에서 사용.
pub const EXTERNAL_PREFIX = "runtime-";

/// helper module 의 source 빌드 옵션. plugin context 로 전달.
pub const SourceOptions = struct {
    minify: bool = false,
    es5: bool = false,
    /// `__toESM`, `__toCommonJS`, `__export` 등 RN/Hermes 호환 configurable variant.
    configurable_exports: bool = false,
};

/// Helper 정의 변형. plain/min 은 필수, es5/configurable 은 해당 helper 가 그 variant
/// 를 제공할 때만 채워진다. `pickBody` 가 옵션 조합에 따라 적절한 variant 를 선택.
const BodyVariants = struct {
    plain: []const u8,
    min: []const u8,
    es5: ?[]const u8 = null,
    es5_min: ?[]const u8 = null,
    configurable: ?[]const u8 = null,
    configurable_min: ?[]const u8 = null,
};

/// Helper 정의 묶음. 한 묶음 = 한 virtual module.
const HelperModule = struct {
    /// virtual module 의 short name (URL 마지막 segment, kebab-case).
    short: []const u8,
    /// 이 module 에 정의된 helper base name 들 (named export 대상).
    helpers: []const []const u8,
    /// helper 정의 string 의 variant 모음.
    body: BodyVariants,
};

const MODULES = [_]HelperModule{
    // ES2015+ 다운레벨링 (transformer 가 emit)
    .{
        .short = "generator",
        .helpers = &.{"__generator"},
        .body = .{ .plain = rt.GENERATOR_RUNTIME, .min = rt.GENERATOR_RUNTIME_MIN },
    },
    .{
        .short = "async",
        .helpers = &.{"__async"},
        .body = .{
            .plain = rt.ASYNC_RUNTIME,
            .min = rt.ASYNC_RUNTIME_MIN,
            .es5 = rt.ASYNC_RUNTIME_ES5,
            .es5_min = rt.ASYNC_RUNTIME_ES5_MIN,
        },
    },
    .{
        .short = "await",
        .helpers = &.{"__await"},
        .body = .{ .plain = rt.AWAIT_RUNTIME, .min = rt.AWAIT_RUNTIME_MIN },
    },
    .{
        .short = "async-values",
        .helpers = &.{"__asyncValues"},
        .body = .{ .plain = rt.ASYNC_VALUES_RUNTIME, .min = rt.ASYNC_VALUES_RUNTIME_MIN },
    },
    .{
        .short = "async-generator",
        .helpers = &.{"__asyncGenerator"},
        .body = .{ .plain = rt.ASYNC_GENERATOR_RUNTIME, .min = rt.ASYNC_GENERATOR_RUNTIME_MIN },
    },
    .{
        .short = "values",
        .helpers = &.{"__values"},
        .body = .{ .plain = rt.VALUES_RUNTIME, .min = rt.VALUES_RUNTIME_MIN },
    },
    .{
        .short = "extends",
        .helpers = &.{"__extends"},
        .body = .{ .plain = rt.EXTENDS_RUNTIME, .min = rt.EXTENDS_RUNTIME_MIN },
    },
    .{
        .short = "class-call-check",
        .helpers = &.{"__classCallCheck"},
        .body = .{ .plain = rt.CLASS_CALL_CHECK_RUNTIME, .min = rt.CLASS_CALL_CHECK_RUNTIME_MIN },
    },
    .{
        .short = "call-super",
        .helpers = &.{"__callSuper"},
        .body = .{ .plain = rt.CALL_SUPER_RUNTIME, .min = rt.CALL_SUPER_RUNTIME_MIN },
    },
    .{
        .short = "rest",
        .helpers = &.{"__rest"},
        .body = .{ .plain = rt.REST_RUNTIME, .min = rt.REST_RUNTIME_MIN },
    },
    .{
        .short = "tagged-template",
        .helpers = &.{"__taggedTemplateLiteral"},
        .body = .{ .plain = rt.TAGGED_TEMPLATE_RUNTIME, .min = rt.TAGGED_TEMPLATE_RUNTIME_MIN },
    },

    // Decorator (TypeScript experimental — `experimentalDecorators`)
    .{
        .short = "decorator",
        .helpers = &.{ "__decorateClass", "__decorateParam", "__defProp2" },
        .body = .{ .plain = rt.DECORATOR_RUNTIME, .min = rt.DECORATOR_RUNTIME_MIN },
    },
    .{
        .short = "metadata",
        .helpers = &.{"__metadata"},
        .body = .{ .plain = rt.METADATA_RUNTIME, .min = rt.METADATA_RUNTIME_MIN },
    },

    // TC39 Stage 3 decorator (TypeScript 5.0+)
    .{
        .short = "es-decorator",
        .helpers = &.{ "__esDecorate", "__runInitializers", "__setFunctionName", "__propKey" },
        .body = .{ .plain = rt.ES_DECORATOR_RUNTIME, .min = rt.ES_DECORATOR_RUNTIME_MIN },
    },

    // Bundler interop — 현재는 emitter wrap 단계에서 직접 사용. transformer/emitter
    // 통합 시점에 graph 경로로 전환 결정.
    .{
        .short = "to-esm",
        .helpers = &.{
            "__create",
            "__getProtoOf",
            "__defProp",
            "__getOwnPropNames",
            "__getOwnPropDesc",
            "__hasOwn",
            "__copyProps",
            "__toESM",
        },
        .body = .{
            .plain = rt.TOESM_RUNTIME,
            .min = rt.TOESM_RUNTIME_MIN,
            .configurable = rt.TOESM_RUNTIME_CONFIGURABLE,
            .configurable_min = rt.TOESM_RUNTIME_CONFIGURABLE_MIN,
        },
    },
    .{
        .short = "to-commonjs",
        .helpers = &.{"__toCommonJS"},
        .body = .{
            .plain = rt.TOCOMMONJS_RUNTIME,
            .min = rt.TOCOMMONJS_RUNTIME_MIN,
            .configurable = rt.TOCOMMONJS_RUNTIME_CONFIGURABLE,
            .configurable_min = rt.TOCOMMONJS_RUNTIME_CONFIGURABLE_MIN,
        },
    },
    .{
        .short = "esm-init",
        .helpers = &.{"__esm"},
        .body = .{
            .plain = rt.ESM_RUNTIME,
            .min = rt.ESM_RUNTIME_MIN,
            .es5 = rt.ESM_RUNTIME_ES5,
            .es5_min = rt.ESM_RUNTIME_ES5_MIN,
        },
    },
    .{
        .short = "export",
        .helpers = &.{"__export"},
        .body = .{
            .plain = rt.EXPORT_RUNTIME,
            .min = rt.EXPORT_RUNTIME_MIN,
            .configurable = rt.EXPORT_RUNTIME_CONFIGURABLE,
            .configurable_min = rt.EXPORT_RUNTIME_CONFIGURABLE_MIN,
        },
    },
    .{
        .short = "commonjs",
        .helpers = &.{ "__commonJS", "__require" },
        .body = .{
            .plain = rt.CJS_RUNTIME,
            .min = rt.CJS_RUNTIME_MIN,
            .es5 = rt.CJS_RUNTIME_ES5,
            .es5_min = rt.CJS_RUNTIME_ES5_MIN,
        },
    },

    // ES2015 spread 연산 — `__toConsumableArray` 만 외부 호출, `__arrayLikeToArray` 는
    // 모듈 내 closure-internal (export 불필요, tree-shake 단순화 위해 미노출).
    .{
        .short = "spread-array",
        .helpers = &.{"__toConsumableArray"},
        .body = .{ .plain = rt.SPREAD_ARRAY_RUNTIME, .min = rt.SPREAD_ARRAY_RUNTIME_MIN },
    },

    // --keep-names + binary loader
    .{
        .short = "keep-names",
        .helpers = &.{"__name"},
        .body = .{ .plain = rt.KEEP_NAMES_RUNTIME, .min = rt.KEEP_NAMES_RUNTIME_MIN },
    },
    .{
        .short = "to-binary",
        .helpers = &.{"__toBinary"},
        .body = .{ .plain = rt.TO_BINARY_RUNTIME, .min = rt.TO_BINARY_RUNTIME_MIN },
    },

    // ES2022 private field/method downlevel
    .{
        .short = "class-private-method-init",
        .helpers = &.{"__classPrivateMethodInit"},
        .body = .{ .plain = rt.PRIVATE_METHOD_INIT_RUNTIME, .min = rt.PRIVATE_METHOD_INIT_RUNTIME_MIN },
    },
    .{
        .short = "class-private-method-get",
        .helpers = &.{"__classPrivateMethodGet"},
        .body = .{ .plain = rt.PRIVATE_METHOD_GET_RUNTIME, .min = rt.PRIVATE_METHOD_GET_RUNTIME_MIN },
    },
    .{
        .short = "class-private-field-set",
        .helpers = &.{"__classPrivateFieldSet"},
        .body = .{ .plain = rt.PRIVATE_FIELD_SET_RUNTIME, .min = rt.PRIVATE_FIELD_SET_RUNTIME_MIN },
    },
    .{
        .short = "class-static-private-field",
        .helpers = &.{
            "__classCheckPrivateStaticAccess",
            "__classCheckPrivateStaticFieldDescriptor",
            "__classStaticPrivateFieldSpecGet",
            "__classStaticPrivateFieldSpecSet",
        },
        .body = .{ .plain = rt.STATIC_PRIVATE_FIELD_RUNTIME, .min = rt.STATIC_PRIVATE_FIELD_RUNTIME_MIN },
    },

    // ES2025 explicit resource management (`using` / `await using`)
    .{
        .short = "using",
        .helpers = &.{ "__using", "__callDispose" },
        .body = .{
            .plain = rt.USING_RUNTIME,
            .min = rt.USING_RUNTIME_MIN,
            .es5 = rt.USING_RUNTIME_ES5,
            .es5_min = rt.USING_RUNTIME_ES5_MIN,
        },
    },
};

// ============================================================
// Public API
// ============================================================

/// helper base name → 묶음 module 의 short name lookup.
/// transformer 가 import statement 의 specifier 결정에 사용.
/// 미등록 helper 는 null 반환 — caller 가 기존 preamble 경로로 fallback.
pub fn moduleShortFor(base_name: []const u8) ?[]const u8 {
    for (MODULES) |m| {
        for (m.helpers) |h| {
            if (std.mem.eql(u8, h, base_name)) return m.short;
        }
    }
    return null;
}

/// helper base name → virtual module 의 internal ID 생성.
/// 예: `__generator` → `\x00zts:runtime/generator`. caller 가 소유.
/// 미등록 helper 는 null.
pub fn idForBase(allocator: std.mem.Allocator, base_name: []const u8) !?[]const u8 {
    const short = moduleShortFor(base_name) orelse return null;
    return try std.fmt.allocPrint(allocator, "{s}{s}", .{ ID_PREFIX, short });
}

/// virtual module specifier 를 외부 노출용 안전 ID 로 변환.
/// chunk 파일명 / import specifier (chunk 간) / sourcemap source URL 에서 NULL byte 가
/// 새지 않도록 sanitize. caller 가 소유.
/// `\x00zts:runtime/generator` → `runtime-generator`
/// virtual prefix 가 아니면 입력 그대로 dupe.
pub fn sanitizeId(allocator: std.mem.Allocator, id: []const u8) ![]const u8 {
    if (!isVirtualId(id)) return try allocator.dupe(u8, id);
    const short = id[ID_PREFIX.len..];
    return try std.fmt.allocPrint(allocator, "{s}{s}", .{ EXTERNAL_PREFIX, short });
}

/// internal ID 인지 검사.
pub fn isVirtualId(id: []const u8) bool {
    return std.mem.startsWith(u8, id, ID_PREFIX);
}

/// builtin runtime helper plugin 을 생성. graph 가 plugin slice 에 prepend.
/// `opts` 는 caller 소유 — bundler 가 빌드 옵션 기반으로 만들어 lifetime 동안 유지.
pub fn makePlugin(opts: *const SourceOptions) plugin_mod.Plugin {
    return .{
        .name = "zts:runtime-helpers",
        .context = @ptrCast(@constCast(opts)),
        .resolveId = resolveIdHook,
        .load = loadHook,
    };
}

// ============================================================
// Plugin hooks
// ============================================================

fn resolveIdHook(
    _: ?*anyopaque,
    specifier: []const u8,
    _: ?[]const u8,
    _: std.mem.Allocator,
) plugin_mod.PluginError!?plugin_mod.ResolvedModule {
    if (!isVirtualId(specifier)) return null;
    const short = specifier[ID_PREFIX.len..];
    if (findModule(short) == null) return null;
    return .{ .virtual = .{ .path = specifier } };
}

fn loadHook(
    ctx: ?*anyopaque,
    path: []const u8,
    allocator: std.mem.Allocator,
) plugin_mod.PluginError!?[]const u8 {
    if (!isVirtualId(path)) return null;
    const short = path[ID_PREFIX.len..];
    const m = findModule(short) orelse return null;
    const default_opts = SourceOptions{};
    const opts: *const SourceOptions = if (ctx) |c|
        @ptrCast(@alignCast(c))
    else
        &default_opts;
    return try buildSource(allocator, m, opts.*);
}

fn findModule(short: []const u8) ?*const HelperModule {
    for (&MODULES) |*m| {
        if (std.mem.eql(u8, m.short, short)) return m;
    }
    return null;
}

// ============================================================
// Source builder
// ============================================================

/// 옵션 조합에 따른 body variant 선택. variant 가 정의되지 않은 옵션은 plain/min 으로
/// fallback — 호출자가 module 의 helper 종류와 무관하게 같은 옵션 set 을 사용 가능.
fn pickBody(body: BodyVariants, opts: SourceOptions) []const u8 {
    if (opts.configurable_exports) {
        if (opts.minify) {
            if (body.configurable_min) |b| return b;
        } else {
            if (body.configurable) |b| return b;
        }
    }
    if (opts.es5) {
        if (opts.minify) {
            if (body.es5_min) |b| return b;
        } else {
            if (body.es5) |b| return b;
        }
    }
    return if (opts.minify) body.min else body.plain;
}

fn buildSource(allocator: std.mem.Allocator, m: *const HelperModule, opts: SourceOptions) ![]const u8 {
    return buildExports(allocator, pickBody(m.body, opts), m.helpers, opts.minify);
}

/// helper 정의 + named export suffix 결합.
/// minify 시 정의 안 식별자가 short name (e.g. `$gn`) 이라 export alias 로 base name
/// 노출 — consumer 는 항상 base name 으로 import 가능.
///   `var $gn=...; export { $gn as __generator };`
fn buildExports(
    allocator: std.mem.Allocator,
    body: []const u8,
    bases: []const []const u8,
    minify: bool,
) ![]const u8 {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(allocator);
    try list.appendSlice(allocator, body);
    try list.appendSlice(allocator, "\nexport { ");
    for (bases, 0..) |base, i| {
        if (i > 0) try list.appendSlice(allocator, ", ");
        const local = names.helperName(base, minify);
        if (std.mem.eql(u8, local, base)) {
            try list.appendSlice(allocator, base);
        } else {
            try list.appendSlice(allocator, local);
            try list.appendSlice(allocator, " as ");
            try list.appendSlice(allocator, base);
        }
    }
    try list.appendSlice(allocator, " };\n");
    return try list.toOwnedSlice(allocator);
}

// ============================================================
// 단위 테스트
// ============================================================

test "moduleShortFor: 등록된 helper 매핑" {
    try std.testing.expectEqualStrings("generator", moduleShortFor("__generator").?);
    try std.testing.expectEqualStrings("async", moduleShortFor("__async").?);
    try std.testing.expectEqualStrings("await", moduleShortFor("__await").?);
    try std.testing.expectEqualStrings("decorator", moduleShortFor("__decorateClass").?);
    try std.testing.expectEqualStrings("decorator", moduleShortFor("__decorateParam").?);
    try std.testing.expectEqualStrings("decorator", moduleShortFor("__defProp2").?);
    try std.testing.expectEqualStrings("es-decorator", moduleShortFor("__esDecorate").?);
    try std.testing.expectEqualStrings("to-esm", moduleShortFor("__toESM").?);
    try std.testing.expectEqualStrings("to-esm", moduleShortFor("__create").?);
    try std.testing.expectEqualStrings("commonjs", moduleShortFor("__commonJS").?);
    try std.testing.expectEqualStrings("rest", moduleShortFor("__rest").?);
}

test "moduleShortFor: 미등록 helper 는 null" {
    // `__spreadArray` 는 transformer 가 emit 하지 않음 (`__toConsumableArray` 가 대체).
    // `__arrayLikeToArray` 는 spread-array 모듈 내 closure-internal — 외부 export 안 함.
    try std.testing.expect(moduleShortFor("__spreadArray") == null);
    try std.testing.expect(moduleShortFor("__arrayLikeToArray") == null);
    try std.testing.expect(moduleShortFor("not_a_helper") == null);
}

test "moduleShortFor: PR 1b 신규 등록 helper" {
    try std.testing.expectEqualStrings("spread-array", moduleShortFor("__toConsumableArray").?);
    try std.testing.expectEqualStrings("keep-names", moduleShortFor("__name").?);
    try std.testing.expectEqualStrings("to-binary", moduleShortFor("__toBinary").?);
    try std.testing.expectEqualStrings("class-private-method-init", moduleShortFor("__classPrivateMethodInit").?);
    try std.testing.expectEqualStrings("class-static-private-field", moduleShortFor("__classCheckPrivateStaticAccess").?);
    try std.testing.expectEqualStrings("class-static-private-field", moduleShortFor("__classStaticPrivateFieldSpecSet").?);
    try std.testing.expectEqualStrings("using", moduleShortFor("__using").?);
    try std.testing.expectEqualStrings("using", moduleShortFor("__callDispose").?);
}

test "idForBase: helper base → virtual ID" {
    const allocator = std.testing.allocator;
    const id = (try idForBase(allocator, "__generator")).?;
    defer allocator.free(id);
    try std.testing.expectEqualStrings("\x00zts:runtime/generator", id);
}

test "idForBase: 미등록 helper 는 null" {
    const allocator = std.testing.allocator;
    const id = try idForBase(allocator, "__spreadArray");
    try std.testing.expect(id == null);
}

test "sanitizeId: NULL prefix 제거 + runtime- prefix" {
    const allocator = std.testing.allocator;
    const safe = try sanitizeId(allocator, "\x00zts:runtime/generator");
    defer allocator.free(safe);
    try std.testing.expectEqualStrings("runtime-generator", safe);
}

test "sanitizeId: 비 virtual ID 는 그대로 (dupe)" {
    const allocator = std.testing.allocator;
    const safe = try sanitizeId(allocator, "/path/to/file.ts");
    defer allocator.free(safe);
    try std.testing.expectEqualStrings("/path/to/file.ts", safe);
}

test "isVirtualId" {
    try std.testing.expect(isVirtualId("\x00zts:runtime/generator"));
    try std.testing.expect(!isVirtualId("/local/path.ts"));
    try std.testing.expect(!isVirtualId(""));
}

test "buildSource: 정의 + named export 포함 (generator)" {
    const allocator = std.testing.allocator;
    const m = findModule("generator").?;
    const src = try buildSource(allocator, m, .{});
    defer allocator.free(src);
    try std.testing.expect(std.mem.indexOf(u8, src, "__generator") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "export { __generator };") != null);
}

test "buildSource: minify 시 short name 정의 + alias export" {
    const allocator = std.testing.allocator;
    const m = findModule("generator").?;
    const src = try buildSource(allocator, m, .{ .minify = true });
    defer allocator.free(src);
    try std.testing.expect(std.mem.indexOf(u8, src, "$gn") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "$gn as __generator") != null);
}

test "buildSource: ES5 variant 는 arrow function 없음 (async)" {
    const allocator = std.testing.allocator;
    const m = findModule("async").?;
    const src = try buildSource(allocator, m, .{ .es5 = true });
    defer allocator.free(src);
    try std.testing.expect(std.mem.indexOf(u8, src, "=>") == null);
    try std.testing.expect(std.mem.indexOf(u8, src, "function") != null);
}

test "buildSource: configurable variant 가 없으면 plain 으로 fallback (extends)" {
    // extends 는 configurable variant 미정의 — opts.configurable_exports=true 라도
    // plain 반환되어야 (옵션 set 은 모듈 무관 단일 set 이라 fallback 필요).
    const allocator = std.testing.allocator;
    const m = findModule("extends").?;
    const src = try buildSource(allocator, m, .{ .configurable_exports = true });
    defer allocator.free(src);
    try std.testing.expect(std.mem.indexOf(u8, src, "__extends") != null);
}

test "buildSource: 묶음 module — 모든 helper named export (decorator)" {
    const allocator = std.testing.allocator;
    const m = findModule("decorator").?;
    const src = try buildSource(allocator, m, .{});
    defer allocator.free(src);
    const last_export_pos = std.mem.lastIndexOf(u8, src, "export {").?;
    const export_tail = src[last_export_pos..];
    try std.testing.expect(std.mem.indexOf(u8, export_tail, "__decorateClass") != null);
    try std.testing.expect(std.mem.indexOf(u8, export_tail, "__decorateParam") != null);
    try std.testing.expect(std.mem.indexOf(u8, export_tail, "__defProp2") != null);
}

test "smoke: 모든 MODULES 의 helper 가 source 에 export 됨" {
    const allocator = std.testing.allocator;
    inline for (MODULES) |m| {
        const src = try buildSource(allocator, &m, .{});
        defer allocator.free(src);
        for (m.helpers) |base| {
            // base name 이 정의 부분 또는 export alias 로 등장
            try std.testing.expect(std.mem.indexOf(u8, src, base) != null);
        }
        // 정확히 하나의 export 문
        try std.testing.expect(std.mem.indexOf(u8, src, "\nexport { ") != null);
    }
}

test "loadHook: virtual ID → source 반환" {
    const allocator = std.testing.allocator;
    const opts = SourceOptions{};
    const src = (try loadHook(@ptrCast(@constCast(&opts)), "\x00zts:runtime/generator", allocator)).?;
    defer allocator.free(src);
    try std.testing.expect(std.mem.indexOf(u8, src, "__generator") != null);
}

test "loadHook: 비 virtual ID 는 null" {
    const allocator = std.testing.allocator;
    const result = try loadHook(null, "/some/path.ts", allocator);
    try std.testing.expect(result == null);
}

test "loadHook: 미등록 short 는 null" {
    const allocator = std.testing.allocator;
    const opts = SourceOptions{};
    const result = try loadHook(@ptrCast(@constCast(&opts)), "\x00zts:runtime/no-such-helper", allocator);
    try std.testing.expect(result == null);
}

test "loadHook: ctx 의 minify 옵션이 source 에 반영 (alias export)" {
    // ctx 캐스트 회귀 방지 — ctx 가 무시되면 default_opts 사용해서 alias 가 없을 것.
    const allocator = std.testing.allocator;
    const opts = SourceOptions{ .minify = true };
    const src = (try loadHook(@ptrCast(@constCast(&opts)), "\x00zts:runtime/generator", allocator)).?;
    defer allocator.free(src);
    try std.testing.expect(std.mem.indexOf(u8, src, "$gn as __generator") != null);
}

test "resolveIdHook: virtual specifier 만 가로챔" {
    const allocator = std.testing.allocator;
    const r1 = try resolveIdHook(null, "\x00zts:runtime/generator", null, allocator);
    try std.testing.expect(r1 != null);
    try std.testing.expect(r1.? == .virtual);

    const r2 = try resolveIdHook(null, "./local.ts", null, allocator);
    try std.testing.expect(r2 == null);

    const r3 = try resolveIdHook(null, "\x00zts:runtime/no-such-helper", null, allocator);
    try std.testing.expect(r3 == null);
}

test "makePlugin: hook 호출이 ctx 통해 동작" {
    // makePlugin 결과의 hook 호출까지 검증 — 단순 non-null 어설션이 아니라 e2e.
    const allocator = std.testing.allocator;
    const opts = SourceOptions{};
    const p = makePlugin(&opts);
    try std.testing.expectEqualStrings("zts:runtime-helpers", p.name);

    const resolved = (try p.resolveId.?(p.context, "\x00zts:runtime/generator", null, allocator)).?;
    try std.testing.expect(resolved == .virtual);

    const loaded = (try p.load.?(p.context, "\x00zts:runtime/generator", allocator)).?;
    defer allocator.free(loaded);
    try std.testing.expect(std.mem.indexOf(u8, loaded, "__generator") != null);
}
