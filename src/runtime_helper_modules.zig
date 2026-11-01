//! ZNTC runtime helper virtual module loader (#1961).
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
//! - **Internal ID** (graph 안): `\x00zntc:runtime/<short>` (oxc 식 NULL prefix).
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
//! 의도적으로 등록되지 않는 helper 는 `__spreadArray` 와 `__arrayLikeToArray` 둘 뿐이다:
//! `__spreadArray` 는 transformer 가 emit 하지 않고 `__toConsumableArray` 가 대체하며,
//! `__arrayLikeToArray` 는 spread-array 모듈 내부 closure-internal 이라 외부 export 하지
//! 않는다 (아래 모듈 등록·테스트 참조). 그 외 `__toConsumableArray`/`__name`/`__toBinary`/
//! `__classPrivateMethodInit`/`__classPrivateFieldSet`/`__classCheckPrivateStaticAccess`/
//! `__using`/`__callDispose` 등은 모두 가상 모듈로 등록되어 있다.
//! 등록되지 않은 helper 가 import 되면 plugin 이 null 반환 → 호출자가 기존 preamble 경로로
//! fallback.

const std = @import("std");
const rt = @import("bundler/runtime_helpers.zig");
const plugin_mod = @import("bundler/plugin.zig");
const names = @import("runtime_helper_names.zig");

/// Internal virtual module ID prefix. NULL byte sentinel.
pub const ID_PREFIX = "\x00zntc:runtime/";

/// 외부 노출 prefix. sanitize 결과 chunk 파일명/import specifier/sourcemap 에서 사용.
pub const EXTERNAL_PREFIX = "runtime-";

/// helper module 의 source 빌드 옵션. plugin context 로 전달.
pub const SourceOptions = @import("runtime_helper_source_origin.zig").SourceOptions;
const source_origin = @import("runtime_helper_source_origin.zig");

pub const InteropFlavor = enum { to_esm, wrapped };

pub fn interopId(flavor: InteropFlavor) []const u8 {
    return switch (flavor) {
        .to_esm => ID_PREFIX ++ "to-esm",
        .wrapped => ID_PREFIX ++ "interop-wrap",
    };
}

/// The producer owns the complete selected source before initial analysis.
/// This does not make it a live root; consumers activate the provider later.
pub fn interopSource(allocator: std.mem.Allocator, flavor: InteropFlavor, options: SourceOptions) ![]const u8 {
    const id = interopId(flavor);
    return buildSource(allocator, findModule(id[ID_PREFIX.len..]).?, options);
}

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
    /// Base exports imported before the initial parse, using their literal template names.
    dependencies: []const []const u8 = &.{},
    /// The template chooses dependency locals explicitly, independently of its exports.
    dependency_names: enum { base, variant } = .base,
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
        .dependencies = &.{"__values"},
        .helpers = &.{"__asyncValues"},
        .body = .{ .plain = rt.ASYNC_VALUES_RUNTIME, .min = rt.ASYNC_VALUES_RUNTIME_MIN },
    },
    .{
        .short = "async-generator",
        .dependencies = &.{"__await"},
        .helpers = &.{"__asyncGenerator"},
        .body = .{ .plain = rt.ASYNC_GENERATOR_RUNTIME, .min = rt.ASYNC_GENERATOR_RUNTIME_MIN },
    },
    .{
        // async generator 안 `yield* X` 위임 (#4628 · #4700). __await 에 의존한다 —
        // 최초 parse 전에 dependency import를 포함해 참조 identity를 부여한다.
        .short = "yield-star",
        .dependencies = &.{"__await"},
        .helpers = &.{"__yieldStar"},
        .body = .{
            .plain = rt.YIELD_STAR_RUNTIME,
            .min = rt.YIELD_STAR_RUNTIME_MIN,
        },
    },
    .{
        .short = "public-field",
        .helpers = &.{"__publicField"},
        .body = .{ .plain = rt.PUBLIC_FIELD_RUNTIME, .min = rt.PUBLIC_FIELD_RUNTIME_MIN },
    },
    .{
        .short = "to-property-key",
        .helpers = &.{"__toPropertyKey"},
        .body = .{ .plain = rt.TO_PROPERTY_KEY_RUNTIME, .min = rt.TO_PROPERTY_KEY_RUNTIME_MIN },
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
        .short = "class-define-property",
        .helpers = &.{"__classDefineProperty"},
        .body = .{ .plain = rt.CLASS_DEFINE_PROPERTY_RUNTIME, .min = rt.CLASS_DEFINE_PROPERTY_RUNTIME_MIN },
    },
    .{
        .short = "call-super",
        .helpers = &.{"__callSuper"},
        .body = .{ .plain = rt.CALL_SUPER_RUNTIME, .min = rt.CALL_SUPER_RUNTIME_MIN },
    },
    .{
        .short = "super-get",
        .helpers = &.{"__superGet"},
        .body = .{ .plain = rt.SUPER_GET_RUNTIME, .min = rt.SUPER_GET_RUNTIME_MIN },
    },
    .{
        .short = "super-set",
        .helpers = &.{"__superSet"},
        .body = .{ .plain = rt.SUPER_SET_RUNTIME, .min = rt.SUPER_SET_RUNTIME_MIN },
    },
    .{
        .short = "derived-constructor",
        .helpers = &.{ "__assertThisInitialized", "__assertThisUninitialized", "__possibleConstructorReturn", "__nativeCtorThis" },
        .body = .{ .plain = rt.DERIVED_CONSTRUCTOR_RUNTIME, .min = rt.DERIVED_CONSTRUCTOR_RUNTIME_MIN },
    },
    .{
        .short = "tdz",
        .helpers = &.{"__tdz"},
        .body = .{ .plain = rt.TDZ_RUNTIME, .min = rt.TDZ_RUNTIME_MIN },
    },
    .{
        .short = "read",
        .helpers = &.{"__read"},
        .body = .{ .plain = rt.READ_RUNTIME, .min = rt.READ_RUNTIME_MIN },
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
            .es5 = rt.TOESM_RUNTIME_ES5,
            .es5_min = rt.TOESM_RUNTIME_ES5_MIN,
            .configurable = rt.TOESM_RUNTIME_CONFIGURABLE,
            .configurable_min = rt.TOESM_RUNTIME_CONFIGURABLE_MIN,
        },
    },
    .{
        .short = "to-commonjs",
        .dependencies = &.{ "__defProp", "__copyProps", "__hasOwn" },
        .dependency_names = .variant,
        .helpers = &.{"__toCommonJS"},
        .body = .{
            .plain = rt.TOCOMMONJS_RUNTIME,
            .min = rt.TOCOMMONJS_RUNTIME_MIN,
            .es5 = rt.TOCOMMONJS_RUNTIME_ES5,
            .es5_min = rt.TOCOMMONJS_RUNTIME_ES5_MIN,
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
        .dependencies = &.{"__defProp"},
        .dependency_names = .variant,
        .helpers = &.{"__export"},
        .body = .{
            .plain = rt.EXPORT_RUNTIME,
            .min = rt.EXPORT_RUNTIME_MIN,
            .es5 = rt.EXPORT_RUNTIME_ES5,
            .es5_min = rt.EXPORT_RUNTIME_ES5_MIN,
            .configurable = rt.EXPORT_RUNTIME_CONFIGURABLE,
            .configurable_min = rt.EXPORT_RUNTIME_CONFIGURABLE_MIN,
        },
    },
    .{
        .short = "commonjs",
        .helpers = &.{"__commonJS"},
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
        .helpers = &.{ "__name", "__namedProperty" },
        .body = .{
            .plain = rt.KEEP_NAMES_RUNTIME ++ rt.NAMED_PROPERTY_RUNTIME,
            .min = rt.KEEP_NAMES_RUNTIME_MIN ++ rt.NAMED_PROPERTY_RUNTIME_MIN,
        },
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

    // RegExp named capture group downlevel — Hermes/ES5 호환.
    .{
        .short = "wrap-regex",
        .helpers = &.{"__wrapRegExp"},
        .body = .{ .plain = rt.WRAP_REGEXP_RUNTIME, .min = rt.WRAP_REGEXP_RUNTIME_MIN },
    },
    // Self-contained AST provider: unlike the individual export/to-commonjs
    // modules this group has no implicit cross-helper free references.
    .{
        .short = "interop-wrap",
        .helpers = &.{ "__create", "__getProtoOf", "__defProp", "__getOwnPropNames", "__getOwnPropDesc", "__hasOwn", "__copyProps", "__toESM", "__export", "__toCommonJS" },
        .body = .{
            .plain = rt.TOESM_RUNTIME ++ rt.EXPORT_RUNTIME ++ rt.TOCOMMONJS_RUNTIME,
            .min = rt.TOESM_RUNTIME_MIN ++ rt.EXPORT_RUNTIME_MIN ++ rt.TOCOMMONJS_RUNTIME_MIN,
            .es5 = rt.TOESM_RUNTIME_ES5 ++ rt.EXPORT_RUNTIME_ES5 ++ rt.TOCOMMONJS_RUNTIME_ES5,
            .es5_min = rt.TOESM_RUNTIME_ES5_MIN ++ rt.EXPORT_RUNTIME_ES5_MIN ++ rt.TOCOMMONJS_RUNTIME_ES5_MIN,
            .configurable = rt.TOESM_RUNTIME_CONFIGURABLE ++ rt.EXPORT_RUNTIME_CONFIGURABLE ++ rt.TOCOMMONJS_RUNTIME_CONFIGURABLE,
            .configurable_min = rt.TOESM_RUNTIME_CONFIGURABLE_MIN ++ rt.EXPORT_RUNTIME_CONFIGURABLE_MIN ++ rt.TOCOMMONJS_RUNTIME_CONFIGURABLE_MIN,
        },
    },
};

comptime {
    for (MODULES) |module| {
        for (module.dependencies) |base| {
            const provider = moduleShortFor(base) orelse @compileError("unregistered runtime helper dependency: " ++ base);
            if (std.mem.eql(u8, provider, module.short))
                @compileError("runtime helper dependency must use a different provider: " ++ base);
        }
    }
}

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

/// 이 런타임 helper 시스템이 export 하는 helper base name 인지 검사.
/// helper virtual module 내부의 helper-to-helper 참조는 같은 helper namespace 안에서
/// 해석되므로 브라우저/global 예약명으로 취급하면 안 된다.
pub fn isRegisteredHelperBaseName(base_name: []const u8) bool {
    return moduleShortFor(base_name) != null;
}

/// map 에 들어있는 등록 helper base name 을 제거한다.
/// NOTE(#4221): unresolved_references 의 키는 analyzer 소유 dupe — remove 는
/// 키를 해제하지 않는다 (현 호출처는 parse_arena 라 arena 가 일괄 회수).
pub fn removeRegisteredHelperBaseNames(map: *std.StringHashMapUnmanaged(void)) void {
    for (MODULES) |m| {
        for (m.helpers) |h| {
            _ = map.remove(h);
        }
    }
}

/// helper base name → virtual module 의 internal ID 생성.
/// 예: `__generator` → `\x00zntc:runtime/generator`. caller 가 소유.
/// 미등록 helper 는 null.
pub fn idForBase(allocator: std.mem.Allocator, base_name: []const u8) !?[]const u8 {
    const short = moduleShortFor(base_name) orelse return null;
    return try std.fmt.allocPrint(allocator, "{s}{s}", .{ ID_PREFIX, short });
}

/// virtual module specifier 를 외부 노출용 안전 ID 로 변환.
/// chunk 파일명 / import specifier (chunk 간) / sourcemap source URL 에서 NULL byte 가
/// 새지 않도록 sanitize. caller 가 소유.
/// `\x00zntc:runtime/generator` → `runtime-generator`
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
        .name = "zntc:runtime-helpers",
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
    _: *plugin_mod.HookContext,
) plugin_mod.PluginError!?plugin_mod.ResolvedModule {
    if (!isVirtualId(specifier)) return null;
    const short = specifier[ID_PREFIX.len..];
    if (findModule(short) == null) return null;
    // specifier 는 Module.import_records[i].specifier slice 의 borrow — parse_arena 소유.
    // owns_path=false: bundler 가 free 시도 금지.
    return .{ .virtual = .{ .path = specifier, .owner = .borrowed } };
}

fn loadHook(
    ctx: ?*anyopaque,
    path: []const u8,
    allocator: std.mem.Allocator,
    hook_context: *plugin_mod.HookContext,
) plugin_mod.PluginError!?plugin_mod.LoadResult {
    if (!isVirtualId(path)) return null;
    const short = path[ID_PREFIX.len..];
    const m = findModule(short) orelse return null;
    const default_opts = SourceOptions{};
    const opts: *const SourceOptions = if (ctx) |c|
        @ptrCast(@alignCast(c))
    else
        &default_opts;
    const contents = try buildSource(allocator, m, opts.*);
    if (catalogFor(m)) |catalog| hook_context.runtime_helper_source = .{
        .catalog = catalog,
        .catalog_descriptor = @ptrCast(m),
        .body_hash = @import("util/wyhash.zig").hashU64(selectedBody(m.body, opts.*).bytes),
        .variant = selectedBody(m.body, opts.*).variant,
        .requested = opts.*,
        .contents = contents,
        .contents_hash = @import("util/wyhash.zig").hashU64(contents),
    };
    return .{ .contents = contents };
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
const SelectedBody = struct { bytes: []const u8, variant: source_origin.Variant };
fn selectedBody(body: BodyVariants, opts: SourceOptions) SelectedBody {
    if (opts.configurable_exports) {
        if (opts.minify) {
            if (body.configurable_min) |b| return .{ .bytes = b, .variant = .configurable_min };
        } else {
            if (body.configurable) |b| return .{ .bytes = b, .variant = .configurable };
        }
    }
    if (opts.es5) {
        if (opts.minify) {
            if (body.es5_min) |b| return .{ .bytes = b, .variant = .es5_min };
        } else {
            if (body.es5) |b| return .{ .bytes = b, .variant = .es5 };
        }
    }
    return if (opts.minify) .{ .bytes = body.min, .variant = .min } else .{ .bytes = body.plain, .variant = .plain };
}
fn pickBody(body: BodyVariants, opts: SourceOptions) []const u8 {
    return selectedBody(body, opts).bytes;
}
fn catalogFor(m: *const HelperModule) ?source_origin.Catalog {
    const known = [_]struct { short: []const u8, catalog: source_origin.Catalog }{
        .{ .short = "public-field", .catalog = .public_field },
        .{ .short = "to-property-key", .catalog = .to_property_key },
        .{ .short = "keep-names", .catalog = .keep_names },
        .{ .short = "super-get", .catalog = .super_get },
        .{ .short = "super-set", .catalog = .super_set },
        .{ .short = "wrap-regex", .catalog = .wrap_regex },
    };
    for (known) |entry| if (m == findModule(entry.short).?) return entry.catalog;
    return null;
}
fn moduleForCatalog(catalog: source_origin.Catalog) *const HelperModule {
    return findModule(switch (catalog) {
        .public_field => "public-field",
        .to_property_key => "to-property-key",
        .keep_names => "keep-names",
        .super_get => "super-get",
        .super_set => "super-set",
        .wrap_regex => "wrap-regex",
    }).?;
}

/// The actual winning constructor, selected variant and exact result contents
/// must agree. Plugin names and virtual paths are not evidence of this role.
pub fn matchesConstructedSource(origin: source_origin.Origin, options: SourceOptions, contents: []const u8) bool {
    const descriptor = moduleForCatalog(origin.catalog);
    const body = selectedBody(descriptor.body, options);
    return origin.catalog_descriptor == @as(*const anyopaque, @ptrCast(descriptor)) and
        origin.body_hash == @import("util/wyhash.zig").hashU64(body.bytes) and
        std.meta.eql(origin.requested, options) and origin.variant == body.variant and
        source_origin.matchesContents(origin, contents);
}

pub fn acceptWinningLoad(outcome: plugin_mod.PluginRunner.LoadOutcome, options: *const SourceOptions) ?source_origin.Origin {
    const origin = outcome.runtime_helper_source orelse return null;
    const actual = outcome.winning_plugin;
    if (actual.load != loadHook or actual.context != @as(?*anyopaque, @ptrCast(@constCast(options))) or
        origin.catalog_descriptor != @as(*const anyopaque, @ptrCast(moduleForCatalog(origin.catalog))) or
        origin.body_hash != @import("util/wyhash.zig").hashU64(selectedBody(moduleForCatalog(origin.catalog).body, options.*).bytes) or
        !std.meta.eql(origin.requested, options.*) or origin.variant != selectedBody(moduleForCatalog(origin.catalog).body, options.*).variant or
        origin.contents.ptr != outcome.result.contents.ptr or origin.contents.len != outcome.result.contents.len or
        @import("util/wyhash.zig").hashU64(outcome.result.contents) != origin.contents_hash or
        outcome.result.loader != null or outcome.result.module_type != null or outcome.result.meta != null or outcome.result.synthetic_named_exports != null) return null;
    return origin;
}

fn buildSource(allocator: std.mem.Allocator, m: *const HelperModule, opts: SourceOptions) ![]const u8 {
    const exported = try buildExports(allocator, pickBody(m.body, opts), m.helpers, opts.minify);
    if (m.dependencies.len == 0) return exported;
    defer allocator.free(exported);

    var source: std.ArrayList(u8) = .empty;
    errdefer source.deinit(allocator);
    for (m.dependencies) |base| {
        const short = moduleShortFor(base) orelse unreachable; // validated at comptime below
        // Select the local spelling from the constructor's explicit template contract.
        // The imported name stays the provider's stable named export. Both identities
        // are created by the initial parser; no later spelling-based repair is needed.
        const local = names.helperName(base, m.dependency_names == .variant and opts.minify);
        try source.appendSlice(allocator, "import { ");
        try source.appendSlice(allocator, base);
        if (!std.mem.eql(u8, local, base)) {
            try source.appendSlice(allocator, " as ");
            try source.appendSlice(allocator, local);
        }
        try source.appendSlice(allocator, " } from \"\\x00zntc:runtime/");
        try source.appendSlice(allocator, short);
        try source.appendSlice(allocator, "\";\n");
    }
    try source.appendSlice(allocator, exported);
    return try source.toOwnedSlice(allocator);
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
    try std.testing.expectEqualStrings("export", moduleShortFor("__export").?);
    try std.testing.expectEqualStrings("to-commonjs", moduleShortFor("__toCommonJS").?);
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
    try std.testing.expectEqualStrings("\x00zntc:runtime/generator", id);
}

test "idForBase: 미등록 helper 는 null" {
    const allocator = std.testing.allocator;
    const id = try idForBase(allocator, "__spreadArray");
    try std.testing.expect(id == null);
}

test "sanitizeId: NULL prefix 제거 + runtime- prefix" {
    const allocator = std.testing.allocator;
    const safe = try sanitizeId(allocator, "\x00zntc:runtime/generator");
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
    try std.testing.expect(isVirtualId("\x00zntc:runtime/generator"));
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
    var hook_ctx: plugin_mod.HookContext = .{};
    const result = (try loadHook(@ptrCast(@constCast(&opts)), "\x00zntc:runtime/generator", allocator, &hook_ctx)).?;
    defer allocator.free(result.contents);
    try std.testing.expect(std.mem.indexOf(u8, result.contents, "__generator") != null);
}

test "loadHook: 비 virtual ID 는 null" {
    const allocator = std.testing.allocator;
    var hook_ctx: plugin_mod.HookContext = .{};
    const result = try loadHook(null, "/some/path.ts", allocator, &hook_ctx);
    try std.testing.expect(result == null);
}

test "loadHook: 미등록 short 는 null" {
    const allocator = std.testing.allocator;
    const opts = SourceOptions{};
    var hook_ctx: plugin_mod.HookContext = .{};
    const result = try loadHook(@ptrCast(@constCast(&opts)), "\x00zntc:runtime/no-such-helper", allocator, &hook_ctx);
    try std.testing.expect(result == null);
}

test "loadHook: ctx 의 minify 옵션이 source 에 반영 (alias export)" {
    // ctx 캐스트 회귀 방지 — ctx 가 무시되면 default_opts 사용해서 alias 가 없을 것.
    const allocator = std.testing.allocator;
    const opts = SourceOptions{ .minify = true };
    var hook_ctx: plugin_mod.HookContext = .{};
    const result = (try loadHook(@ptrCast(@constCast(&opts)), "\x00zntc:runtime/generator", allocator, &hook_ctx)).?;
    defer allocator.free(result.contents);
    try std.testing.expect(std.mem.indexOf(u8, result.contents, "$gn as __generator") != null);
}

test "resolveIdHook: virtual specifier 만 가로챔" {
    const allocator = std.testing.allocator;
    var hook_ctx: plugin_mod.HookContext = .{};
    const r1 = try resolveIdHook(null, "\x00zntc:runtime/generator", null, allocator, &hook_ctx);
    try std.testing.expect(r1 != null);
    try std.testing.expect(r1.? == .virtual);

    const r2 = try resolveIdHook(null, "./local.ts", null, allocator, &hook_ctx);
    try std.testing.expect(r2 == null);

    const r3 = try resolveIdHook(null, "\x00zntc:runtime/no-such-helper", null, allocator, &hook_ctx);
    try std.testing.expect(r3 == null);
}

test "makePlugin: hook 호출이 ctx 통해 동작" {
    // makePlugin 결과의 hook 호출까지 검증 — 단순 non-null 어설션이 아니라 e2e.
    const allocator = std.testing.allocator;
    const opts = SourceOptions{};
    const p = makePlugin(&opts);
    try std.testing.expectEqualStrings("zntc:runtime-helpers", p.name);

    var hook_ctx: plugin_mod.HookContext = .{};
    const resolved = (try p.resolveId.?(p.context, "\x00zntc:runtime/generator", null, allocator, &hook_ctx)).?;
    try std.testing.expect(resolved == .virtual);

    const loaded = (try p.load.?(p.context, "\x00zntc:runtime/generator", allocator, &hook_ctx)).?;
    defer allocator.free(loaded.contents);
    try std.testing.expect(std.mem.indexOf(u8, loaded.contents, "__generator") != null);
}

test "helper dependencies have exact import identities at initial analysis" {
    const Scanner = @import("lexer/scanner.zig").Scanner;
    const Parser = @import("parser/parser.zig").Parser;
    const Analyzer = @import("semantic/analyzer.zig").SemanticAnalyzer;
    const import_scanner = @import("bundler/import_scanner.zig");
    const inputs = [_]struct { module: []const u8, dependency: []const u8 }{
        .{ .module = "async-values", .dependency = "__values" },
        .{ .module = "async-generator", .dependency = "__await" },
        .{ .module = "yield-star", .dependency = "__await" },
    };
    for (inputs) |input| {
        for ([_]bool{ false, true }) |minify| {
            for ([_]bool{ false, true }) |es5| {
                var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
                defer arena.deinit();
                const allocator = arena.allocator();
                const source = try buildSource(allocator, findModule(input.module).?, .{ .minify = minify, .es5 = es5 });
                var scanner = try Scanner.init(allocator, source);
                var parser = Parser.init(allocator, &scanner);
                parser.is_module = true;
                scanner.is_module = true;
                _ = try parser.parse();
                try std.testing.expectEqual(@as(usize, 0), parser.errors.items.len);
                const imports = try import_scanner.extractImports(allocator, &parser.ast);
                try std.testing.expectEqual(@as(usize, 1), imports.len);
                const expected_id = (try idForBase(allocator, input.dependency)).?;
                try std.testing.expectEqualStrings(expected_id, imports[0].specifier);
                var analyzer = Analyzer.init(allocator, &parser.ast);
                analyzer.is_module = true;
                try analyzer.analyze();
                try std.testing.expect(!analyzer.unresolved_references.contains(input.dependency));
                var found: usize = 0;
                for (analyzer.symbols.items, 0..) |symbol, index| {
                    if (symbol.kind != .import_binding or !std.mem.eql(u8, parser.ast.getSourceText(symbol.name), input.dependency)) continue;
                    found += 1;
                    var reads: usize = 0;
                    for (analyzer.references.items) |reference| {
                        if (!reference.flags.read or @backingInt(reference.symbol_id) != index) continue;
                        reads += 1;
                        try std.testing.expect(reference.node_index != .none);
                        try std.testing.expectEqualStrings(input.dependency, parser.ast.identifierNameText(parser.ast.getNode(reference.node_index)));
                    }
                    try std.testing.expect(reads > 0);
                }
                try std.testing.expectEqual(@as(usize, 1), found);
            }
        }
    }
}

test "all helper sources bind registered dependency references at initial analysis" {
    const Scanner = @import("lexer/scanner.zig").Scanner;
    const Parser = @import("parser/parser.zig").Parser;
    const Analyzer = @import("semantic/analyzer.zig").SemanticAnalyzer;
    const variants = [_]SourceOptions{
        .{},                               .{ .minify = true },                               .{ .es5 = true }, .{ .es5 = true, .minify = true },
        .{ .configurable_exports = true }, .{ .configurable_exports = true, .minify = true },
    };
    var has_missing = false;
    for (MODULES) |module| {
        for (variants) |options| {
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            const allocator = arena.allocator();
            const source = try buildSource(allocator, &module, options);
            var scanner = try Scanner.init(allocator, source);
            var parser = Parser.init(allocator, &scanner);
            parser.is_module = true;
            scanner.is_module = true;
            _ = try parser.parse();
            try std.testing.expectEqual(@as(usize, 0), parser.errors.items.len);
            var analyzer = Analyzer.init(allocator, &parser.ast);
            analyzer.is_module = true;
            try analyzer.analyze();
            const import_scanner = @import("bundler/import_scanner.zig");
            const binding_scanner = @import("bundler/binding_scanner.zig");
            const imports = try import_scanner.extractImports(allocator, &parser.ast);
            const exports = try binding_scanner.extractExportBindings(allocator, &parser.ast, imports, &.{});
            try std.testing.expectEqual(module.helpers.len, exports.len);
            for (exports) |binding| {
                const node = binding.local_symbol_node orelse return error.TestUnexpectedResult;
                const id = analyzer.symbol_ids.items[@backingInt(node)] orelse return error.TestUnexpectedResult;
                try std.testing.expectEqual(@as(u32, 0), @backingInt(analyzer.symbols.items[id].scope_id));
            }
            var unresolved = analyzer.unresolved_references.keyIterator();
            while (unresolved.next()) |name| {
                if (isRegisteredHelperBaseName(name.*) or blk: {
                    for (MODULES) |provider| for (provider.helpers) |base| {
                        if (std.mem.eql(u8, name.*, names.helperName(base, true))) break :blk true;
                    };
                    break :blk false;
                }) {
                    std.debug.print("helper source {s} minify={any} es5={any} configurable={any} has unresolved dependency {s}\n", .{ module.short, options.minify, options.es5, options.configurable_exports, name.* });
                    has_missing = true;
                }
            }
        }
    }
    try std.testing.expect(!has_missing);
}

test "interop helper dependency aliases preserve exact initial import and provider export identities" {
    const Scanner = @import("lexer/scanner.zig").Scanner;
    const Parser = @import("parser/parser.zig").Parser;
    const Analyzer = @import("semantic/analyzer.zig").SemanticAnalyzer;
    const import_scanner = @import("bundler/import_scanner.zig");
    const binding_scanner = @import("bundler/binding_scanner.zig");
    const variants = [_]SourceOptions{
        .{},                               .{ .minify = true },                               .{ .es5 = true }, .{ .es5 = true, .minify = true },
        .{ .configurable_exports = true }, .{ .configurable_exports = true, .minify = true },
    };
    for ([_][]const u8{ "to-commonjs", "export" }) |short| {
        for (variants) |options| {
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            const allocator = arena.allocator();
            const module = findModule(short).?;
            const source = try buildSource(allocator, module, options);
            var scanner = try Scanner.init(allocator, source);
            var parser = Parser.init(allocator, &scanner);
            parser.is_module = true;
            scanner.is_module = true;
            _ = try parser.parse();
            try std.testing.expectEqual(@as(usize, 0), parser.errors.items.len);
            var analyzer = Analyzer.init(allocator, &parser.ast);
            analyzer.is_module = true;
            try analyzer.analyze();
            const imports = try import_scanner.extractImports(allocator, &parser.ast);
            const bindings = try binding_scanner.extractImportBindings(allocator, &parser.ast, imports, null);
            try std.testing.expectEqual(module.dependencies.len, bindings.len);

            // The provider is analyzed separately: local aliases must point to its
            // stable named export, whose exact source node already carries a SID.
            const provider_source = try buildSource(allocator, findModule("to-esm").?, options);
            var provider_scanner = try Scanner.init(allocator, provider_source);
            var provider_parser = Parser.init(allocator, &provider_scanner);
            provider_parser.is_module = true;
            provider_scanner.is_module = true;
            _ = try provider_parser.parse();
            var provider_analyzer = Analyzer.init(allocator, &provider_parser.ast);
            provider_analyzer.is_module = true;
            try provider_analyzer.analyze();
            const provider_imports = try import_scanner.extractImports(allocator, &provider_parser.ast);
            const exports = try binding_scanner.extractExportBindings(allocator, &provider_parser.ast, provider_imports, &.{});
            for (bindings, module.dependencies) |binding, base| {
                const local = names.helperName(base, options.minify);
                try std.testing.expectEqualStrings(base, binding.imported_name);
                try std.testing.expectEqualStrings(local, binding.local_name);
                try std.testing.expect(!binding.is_helper);
                try std.testing.expectEqualStrings(ID_PREFIX ++ "to-esm", imports[binding.import_record_index].specifier);
                const node = binding.local_symbol_node orelse return error.TestUnexpectedResult;
                const id = analyzer.symbol_ids.items[@backingInt(node)] orelse return error.TestUnexpectedResult;
                try std.testing.expectEqual(.import_binding, analyzer.symbols.items[id].kind);
                var reads: usize = 0;
                for (analyzer.references.items) |reference| {
                    if (!reference.flags.read or @backingInt(reference.symbol_id) != id) continue;
                    reads += 1;
                    try std.testing.expectEqualStrings(local, parser.ast.identifierNameText(parser.ast.getNode(reference.node_index)));
                }
                try std.testing.expect(reads > 0);
                var matched_export = false;
                for (exports) |export_binding| {
                    if (!std.mem.eql(u8, export_binding.exported_name, base)) continue;
                    const export_node = export_binding.local_symbol_node orelse return error.TestUnexpectedResult;
                    const export_id = provider_analyzer.symbol_ids.items[@backingInt(export_node)] orelse return error.TestUnexpectedResult;
                    try std.testing.expectEqualStrings(local, provider_parser.ast.getSourceText(provider_analyzer.symbols.items[export_id].name));
                    matched_export = true;
                }
                try std.testing.expect(matched_export);
            }
        }
    }
}

test "commonjs exposes only its factory while private function names keep exact inner identities" {
    const Scanner = @import("lexer/scanner.zig").Scanner;
    const Parser = @import("parser/parser.zig").Parser;
    const Analyzer = @import("semantic/analyzer.zig").SemanticAnalyzer;
    const ast = @import("parser/ast.zig");
    try std.testing.expect(moduleShortFor("__require") == null);
    try std.testing.expect(!isRegisteredHelperBaseName("__require"));
    const variants = [_]SourceOptions{ .{}, .{ .minify = true }, .{ .es5 = true }, .{ .es5 = true, .minify = true }, .{ .configurable_exports = true }, .{ .configurable_exports = true, .minify = true } };
    for (variants) |options| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        const module = findModule("commonjs").?;
        try std.testing.expectEqual(@as(usize, 1), module.helpers.len);
        try std.testing.expectEqualStrings("__commonJS", module.helpers[0]);
        const source = try buildSource(allocator, module, options);
        var scanner = try Scanner.init(allocator, source);
        var parser = Parser.init(allocator, &scanner);
        parser.is_module = true;
        scanner.is_module = true;
        _ = try parser.parse();
        var analyzer = Analyzer.init(allocator, &parser.ast);
        analyzer.is_module = true;
        try analyzer.analyze();
        try std.testing.expectEqual(@as(usize, 0), parser.errors.items.len);
        try std.testing.expect(!analyzer.unresolved_references.contains("__require"));
        try std.testing.expect(!analyzer.unresolved_references.contains(names.helperName("__require", true)));
        var private_names: usize = 0;
        for (parser.ast.nodes.items) |node| {
            if (node.tag != .function_expression) continue;
            const name = parser.ast.readExtraNode(node.data.extra, ast.FunctionExtra.name);
            if (name.isNone()) continue;
            const id = analyzer.symbol_ids.items[@backingInt(name)] orelse return error.TestUnexpectedResult;
            const owner = analyzer.symbols.items[id].scope_id;
            try std.testing.expect(!owner.isNone() and @backingInt(owner) > 0);
            try std.testing.expectEqualStrings("__require", parser.ast.identifierNameText(parser.ast.getNode(name)));
            private_names += 1;
        }
        try std.testing.expectEqual(@as(usize, if (options.minify) 0 else 1), private_names);
    }
}
