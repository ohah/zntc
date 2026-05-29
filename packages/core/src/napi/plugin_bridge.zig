const std = @import("std");
const zntc_lib = @import("zntc_lib");

const bundler_mod = zntc_lib.bundler;
const BundleOptions = bundler_mod.BundleOptions;
const types_mod = zntc_lib.bundler.types;
const common = @import("common.zig");
const result_mod = @import("result.zig");
const c = common.c;

const native_alloc = common.nativeAlloc();
const getStringArg = common.getStringArg;
const getNamedProperty = common.getNamedProperty;
const getObjectBool = common.getObjectBool;
const getObjectUint32 = common.getObjectUint32;
const getObjectString = common.getObjectString;
const getObjectBytes = common.getObjectBytes;
const parseStringArray = common.parseStringArray;

// ─── NapiPlugin: JS 플러그인 브릿지 ───
// 워커 스레드에서 JS 콜백을 호출하기 위한 napi_threadsafe_function 기반 브릿지.
// 워커 스레드: 요청 저장 → tsfn 호출 → condvar 대기
// 메인 스레드: JS 콜백 실행 → 결과 저장 → condvar 시그널

const plugin_mod = bundler_mod.plugin;
const ResolveCache = bundler_mod.ResolveCache;
const EmitStore = bundler_mod.EmitStore;
const graph_plugins_mod = bundler_mod.graph_plugins;
const Plugin = plugin_mod.Plugin;
const PluginError = plugin_mod.PluginError;

pub const NapiPlugin = struct {
    name: []const u8,
    tsfn: c.napi_threadsafe_function,

    const HookType = enum { resolveId, load, transform, renderChunk, generateBundle, astFunction, resolveContext, buildStart, buildEnd, closeBundle };

    const PluginResponse = struct {
        resolved_path: ?[]const u8 = null,
        is_external: bool = false,
        /// 빈 모듈로 처리 (Metro `{ type: 'empty' }`, webpack `false` 폴백 매핑용).
        /// resolveId가 `{ disabled: true }` 반환 시 ZNTC가 `module.exports = {}` 처리.
        is_disabled: bool = false,
        code: ?[]const u8 = null,
        /// AST plugin: 제거할 디렉티브 이름
        strip_directive: ?[]const u8 = null,
        /// AST plugin: 함수 뒤에 삽입할 코드 문자열 배열
        trailing_code: ?[]const []const u8 = null,
        /// require.context: 매칭된 파일 경로 목록 (#1579 Phase 2.5).
        /// JS plugin 의 onResolveContext 가 반환한 `{ context: string[] }` 의 string[] 부분.
        /// outer slice = native_alloc 소유 (graph 가 free), inner string = JS lifetime.
        context_matches: ?[]const []const u8 = null,
        /// onLoad callback 의 `loader: 'text' | 'binary' | 'tsx' | ...`. (#2157)
        /// ParsedLoader.fromString 으로 변환된 결과. null = override 안 함.
        loader_override: ?bundler_mod.types.Loader = null,
        loader_module_type: ?bundler_mod.types.ModuleType = null,
        /// onLoad/onTransform callback 의 source map JSON chain. JS dispatcher 가 object map 을
        /// JSON string 으로 정규화해서 전달한다 (#1902).
        source_maps: ?[]const []const u8 = null,
        /// onLoad/onResolveId callback 의 `meta` (Rollup `ModuleInfo.meta`). JS dispatcher 가
        /// object 를 JSON string 으로 정규화해 전달 (#1880 PR2). native_alloc 소유.
        meta: ?[]const u8 = null,
        /// Rollup `syntheticNamedExports` (#3664 P2). true→"default", string→그대로 정규화한 fallback
        /// 대상 export 이름. null = 미설정. native_alloc 소유.
        synthetic_named_exports: ?[]const u8 = null,
        is_failure: bool = false,
        failure_plugin_name: ?[]const u8 = null,
        failure_hook_name: ?[]const u8 = null,
        failure_message: ?[]const u8 = null,
        failure_file: ?[]const u8 = null,
        failure_line: u32 = 0,
        failure_column: u32 = 0,
    };

    /// Per-call 요청 컨텍스트. 여러 워커 스레드가 동시에 호출해도 안전.
    const CallContext = struct {
        hook: HookType,
        arg1: []const u8,
        arg2: ?[]const u8,
        /// generateBundle 전용: OutputFile 배열 (callJsCallback에서 JS 배열로 변환)
        output_files: ?[]const bundler_mod.emitter.OutputFile = null,
        /// this.getModuleInfo (PR3 self-only) 용 현재 Module 포인터. non-null 이면 callJsCallback 이
        /// self-only getModuleInfo 함수를 dispatcher 4번째 인자로 전달 (graph 조회 없음 → race 없음).
        current_module: ?*const anyopaque = null,
        /// this.resolve (PR4) 용 ResolveCache 포인터. non-null 이면 resolve 함수를 dispatcher
        /// 5번째 인자로 전달 (순수 path resolution, plugin 재진입 없음 → race/deadlock 없음).
        resolve_cache: ?*anyopaque = null,
        /// this.emitFile (PR5) 용 EmitStore 포인터. non-null 이면 emitFile 함수를 dispatcher
        /// 6번째 인자로 전달. callJsCallback 은 메인 스레드 직렬이라 store write 동기화 불필요.
        emit_store: ?*anyopaque = null,
        response: ?PluginResponse = null,
        /// 0.16: std.Thread.Mutex/Condition 제거 → one-shot 핸드오프는 std.Io.Event.
        /// set(release)/wait(acquire) 가 response write 의 happens-before 를 보장하므로
        /// 별도 mutex 불필요. 워커가 set 이전엔 response 를 읽지 않는다.
        done: std.Io.Event = .unset,
    };

    /// JS 결과 객체에서 PluginResponse 필드를 추출한다.
    fn parseJsResult(env: c.napi_env, js_result: c.napi_value) PluginResponse {
        var result_type: c.napi_valuetype = undefined;
        _ = c.napi_typeof(env, js_result, &result_type);
        if (result_type == c.napi_null or result_type == c.napi_undefined) {
            return .{};
        }

        var resp = PluginResponse{};
        if (getObjectBool(env, js_result, "__zntcPluginFailure", false)) {
            resp.is_failure = true;
            resp.failure_plugin_name = getObjectString(env, js_result, "pluginName", native_alloc);
            resp.failure_hook_name = getObjectString(env, js_result, "hookName", native_alloc);
            resp.failure_message = getObjectString(env, js_result, "message", native_alloc);
            resp.failure_file = getObjectString(env, js_result, "file", native_alloc);
            resp.failure_line = getObjectUint32(env, js_result, "line", 0);
            resp.failure_column = getObjectUint32(env, js_result, "column", 0);
            return resp;
        }
        if (getObjectString(env, js_result, "path", native_alloc)) |path| {
            resp.resolved_path = path;
        }
        resp.is_external = getObjectBool(env, js_result, "external", false);
        resp.is_disabled = getObjectBool(env, js_result, "disabled", false);
        // plugin onLoad 의 `contents` — string / Uint8Array / Buffer 모두 받음. binary safe.
        // 빈 string 도 의도적 (loader: 'empty' 등) — allow empty.
        if (getObjectBytes(env, js_result, "contents", native_alloc)) |contents| {
            resp.code = contents;
        }
        if (resp.code == null) {
            if (getObjectString(env, js_result, "code", native_alloc)) |code| {
                resp.code = code;
            }
        }
        if (getObjectString(env, js_result, "map", native_alloc)) |map_json| {
            const maps = native_alloc.alloc([]const u8, 1) catch {
                native_alloc.free(map_json);
                return resp;
            };
            maps[0] = map_json;
            resp.source_maps = maps;
        } else if (getNamedProperty(env, js_result, "maps")) |maps_val| {
            resp.source_maps = parseStringArray(env, maps_val, native_alloc);
        }
        // ModuleInfo.meta (#1880 PR2 / #3664 P1): JS dispatcher 가 object 를 JSON string 으로 정규화.
        // load 결과는 runLoadForModule, transform 결과는 callCodeHook→setResponseMeta→
        // runTransformForModule 이 module.plugin_meta 에 deep merge. resolveId meta(cross-module
        // 귀속)는 별도 항목(#3664).
        if (getObjectString(env, js_result, "meta", native_alloc)) |meta_json| {
            resp.meta = meta_json;
        }
        // syntheticNamedExports (#3664 P2): string 이면 그 export 이름, boolean true 면 "default".
        if (getObjectString(env, js_result, "syntheticNamedExports", native_alloc)) |target| {
            resp.synthetic_named_exports = target;
        } else if (getNamedProperty(env, js_result, "syntheticNamedExports")) |sne_val| {
            var t: c.napi_valuetype = undefined;
            if (c.napi_typeof(env, sne_val, &t) == c.napi_ok and t == c.napi_boolean) {
                var b: bool = false;
                _ = c.napi_get_value_bool(env, sne_val, &b);
                if (b) resp.synthetic_named_exports = native_alloc.dupe(u8, "default") catch null;
            }
        }
        // AST plugin 응답 파싱
        if (getObjectString(env, js_result, "stripDirective", native_alloc)) |sd| {
            resp.strip_directive = sd;
        }
        if (getNamedProperty(env, js_result, "trailingCode")) |tc_val| {
            resp.trailing_code = parseStringArray(env, tc_val, native_alloc);
        }
        // require.context 응답 파싱: { context: string[] } (#1579 Phase 2.5)
        if (getNamedProperty(env, js_result, "context")) |ctx_val| {
            resp.context_matches = parseStringArray(env, ctx_val, native_alloc);
        }
        // onLoad: loader override (#2157). resp.code 가 있을 때만 의미 있어 gate — onResolve /
        // transform / lifecycle 응답에서 불필요한 NAPI getNamedProperty 회피.
        if (resp.code != null) {
            if (getObjectString(env, js_result, "loader", native_alloc)) |loader_str| {
                defer native_alloc.free(loader_str);
                if (bundler_mod.types.ParsedLoader.fromString(loader_str)) |parsed_loader| {
                    resp.loader_override = parsed_loader.loader;
                    resp.loader_module_type = parsed_loader.module_type;
                }
            }
        }
        return resp;
    }

    /// `parseJsResult` 가 native_alloc 으로 dupe 한 모든 conditional field 를 일괄 해제.
    /// hook 별로 채워지는 field 가 다르지만 미사용 field 는 null 이라 free 가 no-op.
    /// 개별 hook 에서 필드별 defer 를 늘어놓을 때 빠뜨리기 쉬운 leak 를 한 곳에서 막는다.
    fn freeResponseFields(resp: PluginResponse) void {
        if (resp.resolved_path) |s| native_alloc.free(s);
        if (resp.code) |s| native_alloc.free(s);
        if (resp.strip_directive) |s| native_alloc.free(s);
        if (resp.trailing_code) |tc| {
            for (tc) |s| native_alloc.free(s);
            native_alloc.free(tc);
        }
        if (resp.context_matches) |m| {
            for (m) |s| native_alloc.free(s);
            native_alloc.free(m);
        }
        if (resp.source_maps) |maps| {
            for (maps) |m| native_alloc.free(m);
            native_alloc.free(maps);
        }
        if (resp.meta) |s| native_alloc.free(s);
        if (resp.synthetic_named_exports) |s| native_alloc.free(s);
        if (resp.failure_plugin_name) |s| native_alloc.free(s);
        if (resp.failure_hook_name) |s| native_alloc.free(s);
        if (resp.failure_message) |s| native_alloc.free(s);
        if (resp.failure_file) |s| native_alloc.free(s);
    }

    fn setResponseSourceMaps(resp: PluginResponse, alloc: std.mem.Allocator, hook_ctx: *plugin_mod.HookContext) PluginError!void {
        const maps = resp.source_maps orelse return;
        if (maps.len == 0) return;
        // alloc 은 caller 의 parse_arena — 개별 free 불가 (CLAUDE.md memory ownership).
        // 부분 실패 시 arena.deinit() 이 일괄 해제하므로 errdefer 없이 OOM 만 전달한다.
        const copied = alloc.alloc([]const u8, maps.len) catch return error.OutOfMemory;
        for (maps, 0..) |map_json, i| {
            copied[i] = alloc.dupe(u8, map_json) catch return error.OutOfMemory;
        }
        hook_ctx.source_maps = copied;
    }

    /// transform hook 의 `{ meta }`(JSON 문자열)를 hook_ctx.meta 로 전달 (#1880 #3664 P1).
    /// resp.meta 는 native_alloc 소유(freeResponseFields 가 해제)라 caller(parse_arena)로 dupe —
    /// runTransformForModule 이 module.plugin_meta 에 merge 할 때 module 수명만큼 살아야 한다.
    fn setResponseMeta(resp: PluginResponse, alloc: std.mem.Allocator, hook_ctx: *plugin_mod.HookContext) PluginError!void {
        const m = resp.meta orelse return;
        if (m.len == 0) return;
        hook_ctx.meta = alloc.dupe(u8, m) catch return error.OutOfMemory;
    }

    /// CallContext에 응답을 기록하고 워커 스레드에 시그널을 보낸다.
    fn signalResponse(ctx: *CallContext, resp: PluginResponse) void {
        ctx.response = resp;
        ctx.done.set(common.io());
    }

    /// Promise의 .then() 콜백 — resolve 시 결과를 파싱하여 워커 스레드에 전달
    fn promiseThenCallback(env: c.napi_env, info: c.napi_callback_info) callconv(.c) c.napi_value {
        var argc: usize = 1;
        var argv: [1]c.napi_value = undefined;
        var cb_data: ?*anyopaque = null;
        _ = c.napi_get_cb_info(env, info, &argc, &argv, null, &cb_data);
        const ctx: *CallContext = @ptrCast(@alignCast(cb_data.?));
        signalResponse(ctx, if (argc > 0) parseJsResult(env, argv[0]) else .{});
        var undef: c.napi_value = undefined;
        _ = c.napi_get_undefined(env, &undef);
        return undef;
    }

    /// Promise의 .catch() 콜백 — reject 시 빈 응답으로 워커 스레드에 전달
    fn promiseCatchCallback(env: c.napi_env, info: c.napi_callback_info) callconv(.c) c.napi_value {
        var argc: usize = 1;
        var argv: [1]c.napi_value = undefined;
        var cb_data: ?*anyopaque = null;
        _ = c.napi_get_cb_info(env, info, &argc, &argv, null, &cb_data);
        const ctx: *CallContext = @ptrCast(@alignCast(cb_data.?));
        signalResponse(ctx, if (argc > 0) parseJsResult(env, argv[0]) else .{});
        var undef: c.napi_value = undefined;
        _ = c.napi_get_undefined(env, &undef);
        return undef;
    }

    /// this.getModuleInfo (PR3 self-only) 구현. data = 현재 transform 중인 Module 포인터.
    /// id 가 self 모듈 path 와 일치할 때만 그 모듈의 id/code/meta 를 반환(아니면 null) — graph 를
    /// 조회하지 않고 worker 가 load 단계에서 확정한 path/source/plugin_meta 만 읽으므로 race 없음.
    /// importers/exports 등 graph/linker 의존 필드는 transform 시점 미완성이라 빈 값(self-only 한계).
    fn selfModuleInfoCallback(env: c.napi_env, info: c.napi_callback_info) callconv(.c) c.napi_value {
        var js_null: c.napi_value = undefined;
        _ = c.napi_get_null(env, &js_null);

        var argc: usize = 1;
        var argv: [1]c.napi_value = undefined;
        var data: ?*anyopaque = null;
        if (c.napi_get_cb_info(env, info, &argc, &argv, null, &data) != c.napi_ok) return js_null;
        if (argc < 1) return js_null;

        const id = getStringArg(env, argv[0], native_alloc) orelse return js_null;
        defer native_alloc.free(id);

        const module: *const bundler_mod.Module = @ptrCast(@alignCast(data orelse return js_null));
        // self-only: 현재 transform 중인 모듈이 아니면 null.
        if (!std.mem.eql(u8, id, module.path)) return js_null;

        var js_obj: c.napi_value = undefined;
        _ = c.napi_create_object(env, &js_obj);

        var js_id: c.napi_value = undefined;
        _ = c.napi_create_string_utf8(env, module.path.ptr, module.path.len, &js_id);
        _ = c.napi_set_named_property(env, js_obj, "id", js_id);

        var js_code: c.napi_value = undefined;
        if (module.source.len == 0 or
            c.napi_create_string_utf8(env, module.source.ptr, module.source.len, &js_code) != c.napi_ok)
        {
            _ = c.napi_get_null(env, &js_code);
        }
        _ = c.napi_set_named_property(env, js_obj, "code", js_code);

        var js_meta: c.napi_value = undefined;
        if (module.plugin_meta) |meta_json| {
            js_meta = NapiManualChunksResolver.parseJsonToObject(env, meta_json);
        } else {
            _ = c.napi_create_object(env, &js_meta);
        }
        _ = c.napi_set_named_property(env, js_obj, "meta", js_meta);

        // graph/linker 의존 필드는 transform 시점 미완성 → 안전한 기본값.
        var js_false: c.napi_value = undefined;
        _ = c.napi_get_boolean(env, false, &js_false);
        var js_true: c.napi_value = undefined;
        _ = c.napi_get_boolean(env, true, &js_true);
        _ = c.napi_set_named_property(env, js_obj, "isEntry", js_false);
        _ = c.napi_set_named_property(env, js_obj, "isExternal", js_false);
        _ = c.napi_set_named_property(env, js_obj, "hasModuleSideEffects", js_true);
        _ = c.napi_set_named_property(env, js_obj, "isIncluded", js_false);
        _ = c.napi_set_named_property(env, js_obj, "syntheticNamedExports", js_false);
        inline for (.{ "exports", "importers", "dynamicImporters", "importedIds", "dynamicallyImportedIds", "implicitlyLoadedAfterOneOf", "implicitlyLoadedBefore" }) |field| {
            var arr: c.napi_value = undefined;
            _ = c.napi_create_array(env, &arr);
            _ = c.napi_set_named_property(env, js_obj, field, arr);
        }

        return js_obj;
    }

    /// this.resolve (PR4) 구현. data = *ResolveCache. argv[0]=source, argv[1]=importer?, argv[2]=opts?.
    /// native resolver(순수 path resolution, sharded-mutex thread-safe, plugin 재진입 없음)만 호출
    /// → `{ id, external }` 또는 null(미해결). graph 미접근 + sync 실행이라 race/deadlock 없음.
    fn resolveIdCallback(env: c.napi_env, info: c.napi_callback_info) callconv(.c) c.napi_value {
        var js_null: c.napi_value = undefined;
        _ = c.napi_get_null(env, &js_null);

        var argc: usize = 3;
        var argv: [3]c.napi_value = undefined;
        var data: ?*anyopaque = null;
        if (c.napi_get_cb_info(env, info, &argc, &argv, null, &data) != c.napi_ok) return js_null;
        if (argc < 1) return js_null;

        const source = getStringArg(env, argv[0], native_alloc) orelse return js_null;
        defer native_alloc.free(source);

        // importer(argv[1], optional) → source_dir. Rollup importer 는 파일 경로 → dirname.
        const importer: ?[]const u8 = if (argc >= 2) getStringArg(env, argv[1], native_alloc) else null;
        defer if (importer) |imp| native_alloc.free(imp);
        const source_dir: []const u8 = if (importer) |imp| (std.fs.path.dirname(imp) orelse ".") else ".";

        const resolve_cache: *ResolveCache = @ptrCast(@alignCast(data orelse return js_null));

        // external 패턴 매칭 specifier(node builtins / --packages=external / external 설정)는
        // resolveThreadSafe 가 null 을 반환하므로, 먼저 판정해 `{ id: source, external: true }` 로
        // 노출한다 (Rollup 호환 — plugin 이 external 여부로 분기). #1880 PR4.
        if (resolve_cache.isExternal(source)) {
            var js_ext_obj: c.napi_value = undefined;
            _ = c.napi_create_object(env, &js_ext_obj);
            var js_ext_id: c.napi_value = undefined;
            _ = c.napi_create_string_utf8(env, source.ptr, source.len, &js_ext_id);
            _ = c.napi_set_named_property(env, js_ext_obj, "id", js_ext_id);
            var js_ext_true: c.napi_value = undefined;
            _ = c.napi_get_boolean(env, true, &js_ext_true);
            _ = c.napi_set_named_property(env, js_ext_obj, "external", js_ext_true);
            return js_ext_obj;
        }

        const resolved = (resolve_cache.resolveThreadSafe(source_dir, source, .static_import) catch return js_null) orelse return js_null;
        // PR resolve interning: file/disabled 의 path 는 path_pool 소유 (borrow only) — free 금지.
        // virtual/external/custom/dataurl variant 는 cache 가 반환 안 함 (plugin 만 생성, 여기 도달 안 함).

        const id_path: ?[]const u8 = switch (resolved) {
            .file => |f| f.path,
            .virtual => |v| v.path,
            .external => |e| e.path,
            .disabled => |d| d.path,
            .custom => |cm| cm.path,
            .dataurl => null, // data: URL 은 id 없음 → null
        };
        const path = id_path orelse return js_null;

        var js_obj: c.napi_value = undefined;
        _ = c.napi_create_object(env, &js_obj);
        var js_id: c.napi_value = undefined;
        _ = c.napi_create_string_utf8(env, path.ptr, path.len, &js_id);
        _ = c.napi_set_named_property(env, js_obj, "id", js_id);
        var js_ext: c.napi_value = undefined;
        _ = c.napi_get_boolean(env, resolved == .external, &js_ext);
        _ = c.napi_set_named_property(env, js_obj, "external", js_ext);
        return js_obj;
    }

    /// this.emitFile (PR5/6) 구현. data = *EmitStore. argv[0] = JS 가 검증한
    /// `{ fileName?, name?, source }` (type='asset' 만 — chunk 검증은 JS 측에서 throw).
    /// 명시 fileName 이면 그대로, 없고 name 이면 source hash 로 파일명 자동 생성(emitAssetByName).
    /// reference id("asset-N") 를 string 으로 반환. 메인 스레드 직렬 호출이라 동기화 불필요.
    fn emitFileCallback(env: c.napi_env, info: c.napi_callback_info) callconv(.c) c.napi_value {
        var js_null: c.napi_value = undefined;
        _ = c.napi_get_null(env, &js_null);

        var argc: usize = 1;
        var argv: [1]c.napi_value = undefined;
        var data: ?*anyopaque = null;
        if (c.napi_get_cb_info(env, info, &argc, &argv, null, &data) != c.napi_ok) return js_null;
        if (argc < 1) return js_null;

        const store: *EmitStore = @ptrCast(@alignCast(data orelse return js_null));

        // chunk emit (#1880 PR7-2b/2c): chunkId 가 있으면 source 없이 chunk 요청 수집.
        // JS 가 type:'chunk' 일 때 { chunkId, chunkName?, chunkFileName? } 로 정규화해 넘긴다.
        if (getObjectString(env, argv[0], "chunkId", native_alloc)) |chunk_id| {
            defer native_alloc.free(chunk_id);
            const chunk_name = getObjectString(env, argv[0], "chunkName", native_alloc);
            defer if (chunk_name) |n| native_alloc.free(n);
            const chunk_file_name = getObjectString(env, argv[0], "chunkFileName", native_alloc);
            defer if (chunk_file_name) |f| native_alloc.free(f);
            // #3664: implicitlyLoadedAfterOneOf — chunk 가 로드되기 전 먼저 로드되는 모듈 id 들.
            const implicit = common.getObjectStringArray(env, argv[0], "chunkImplicitlyLoadedAfterOneOf", native_alloc);
            defer if (implicit) |arr| {
                for (arr) |s| native_alloc.free(s);
                native_alloc.free(arr);
            };
            const cref = store.emitChunk(chunk_id, chunk_name, chunk_file_name, implicit orelse &.{}) catch return js_null;
            var js_cref: c.napi_value = undefined;
            if (c.napi_create_string_utf8(env, cref.ptr, cref.len, &js_cref) != c.napi_ok) return js_null;
            return js_cref;
        }

        // source 는 string / Uint8Array / Buffer 모두 수용 (binary-safe asset). 빈 source 도 허용.
        const source = getObjectBytes(env, argv[0], "source", native_alloc) orelse return js_null;
        defer native_alloc.free(source);

        // 명시 fileName 우선; 없으면 name-only(hash 파일명 자동 생성). JS 가 둘 중 하나는 보장.
        const ref_id = blk: {
            if (getObjectString(env, argv[0], "fileName", native_alloc)) |file_name| {
                defer native_alloc.free(file_name);
                break :blk store.emitAsset(file_name, source) catch return js_null;
            }
            const name = getObjectString(env, argv[0], "name", native_alloc) orelse return js_null;
            defer native_alloc.free(name);
            break :blk store.emitAssetByName(name, source) catch return js_null;
        };
        var js_ref: c.napi_value = undefined;
        if (c.napi_create_string_utf8(env, ref_id.ptr, ref_id.len, &js_ref) != c.napi_ok) return js_null;
        return js_ref;
    }

    /// this.getFileName (PR6) 구현. data = *EmitStore. argv[0] = reference id. emit 된 asset 의
    /// 최종 파일명을 반환(미등록이면 null). asset hash 는 source 기반이라 emit 시점에 확정되므로
    /// lazy 없이 단순 lookup. 메인 스레드 직렬.
    fn getFileNameCallback(env: c.napi_env, info: c.napi_callback_info) callconv(.c) c.napi_value {
        var js_null: c.napi_value = undefined;
        _ = c.napi_get_null(env, &js_null);

        var argc: usize = 1;
        var argv: [1]c.napi_value = undefined;
        var data: ?*anyopaque = null;
        if (c.napi_get_cb_info(env, info, &argc, &argv, null, &data) != c.napi_ok) return js_null;
        if (argc < 1) return js_null;

        const store: *EmitStore = @ptrCast(@alignCast(data orelse return js_null));
        const ref_id = getStringArg(env, argv[0], native_alloc) orelse return js_null;
        defer native_alloc.free(ref_id);

        const file_name = store.getFileName(ref_id) orelse return js_null;
        var js_name: c.napi_value = undefined;
        if (c.napi_create_string_utf8(env, file_name.ptr, file_name.len, &js_name) != c.napi_ok) return js_null;
        return js_name;
    }

    /// threadsafe function의 call_js 콜백 (메인 스레드에서 실행)
    /// data = CallContext 포인터 (per-call, 워커 스레드가 스택에 소유하며 condvar 대기 중)
    pub fn callJsCallback(env: c.napi_env, js_callback: c.napi_value, _: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
        const ctx: *CallContext = @ptrCast(@alignCast(data.?));

        // JS dispatcher 호출: dispatcher(hookName, arg1, arg2)
        // HookType tag 이름이 dispatcher 가 기대하는 string 과 동일.
        const hook_name: []const u8 = @tagName(ctx.hook);
        var hook_str: c.napi_value = undefined;
        _ = c.napi_create_string_utf8(env, hook_name.ptr, hook_name.len, &hook_str);

        var js_arg1: c.napi_value = undefined;
        // generateBundle: arg1 대신 output_files JS 배열을 생성
        if (ctx.output_files) |files| {
            _ = c.napi_create_array_with_length(env, files.len, &js_arg1);
            for (files, 0..) |file, i| {
                var js_file: c.napi_value = undefined;
                _ = c.napi_create_object(env, &js_file);
                var js_path: c.napi_value = undefined;
                _ = c.napi_create_string_utf8(env, file.path.ptr, file.path.len, &js_path);
                _ = c.napi_set_named_property(env, js_file, "path", js_path);
                result_mod.setContentsBuffer(env, js_file, file.contents);
                _ = c.napi_set_element(env, js_arg1, @intCast(i), js_file);
            }
        } else {
            _ = c.napi_create_string_utf8(env, ctx.arg1.ptr, ctx.arg1.len, &js_arg1);
        }

        var js_arg2: c.napi_value = undefined;
        if (ctx.arg2) |a2| {
            _ = c.napi_create_string_utf8(env, a2.ptr, a2.len, &js_arg2);
        } else {
            _ = c.napi_get_null(env, &js_arg2);
        }

        var js_undefined: c.napi_value = undefined;
        _ = c.napi_get_undefined(env, &js_undefined);

        // this.getModuleInfo (PR3 self-only): current_module 이 있으면 self-only getModuleInfo 를
        // dispatcher 4번째 인자로 전달. graph 조회 없음 → discovery 병렬 단계 race 없음.
        var js_get_mod_info: c.napi_value = js_undefined;
        var js_resolve: c.napi_value = js_undefined;
        var js_emit_file: c.napi_value = js_undefined;
        var js_get_file_name: c.napi_value = js_undefined;
        var argc: usize = 3;
        if (ctx.current_module) |m| {
            _ = c.napi_create_function(env, "getModuleInfo", "getModuleInfo".len, selfModuleInfoCallback, @constCast(m), &js_get_mod_info);
            if (argc < 4) argc = 4;
        }
        // this.resolve (PR4): resolve_cache 가 있으면 5번째 인자로 resolve 함수 전달.
        if (ctx.resolve_cache) |rc| {
            _ = c.napi_create_function(env, "resolve", "resolve".len, resolveIdCallback, rc, &js_resolve);
            if (argc < 5) argc = 5;
        }
        // this.emitFile (PR5) 6번째 + this.getFileName (PR6) 7번째: emit_store 로 둘 다 전달.
        if (ctx.emit_store) |es| {
            _ = c.napi_create_function(env, "emitFile", "emitFile".len, emitFileCallback, es, &js_emit_file);
            _ = c.napi_create_function(env, "getFileName", "getFileName".len, getFileNameCallback, es, &js_get_file_name);
            argc = 7;
        }

        var js_result: c.napi_value = undefined;
        const args = [_]c.napi_value{ hook_str, js_arg1, js_arg2, js_get_mod_info, js_resolve, js_emit_file, js_get_file_name };
        if (c.napi_call_function(env, js_undefined, js_callback, argc, &args, &js_result) != c.napi_ok) {
            signalResponse(ctx, .{});
            return;
        }

        // Promise 체크: 결과가 Promise이면 .then()/.catch()로 비동기 대기
        var is_promise: bool = false;
        _ = c.napi_is_promise(env, js_result, &is_promise);
        if (is_promise) {
            // .then(onFulfilled) 등록
            var then_fn: c.napi_value = undefined;
            if (getNamedProperty(env, js_result, "then")) |t| {
                then_fn = t;
            } else {
                signalResponse(ctx, .{});
                return;
            }

            var on_fulfilled: c.napi_value = undefined;
            _ = c.napi_create_function(env, "onFulfilled", "onFulfilled".len, promiseThenCallback, @ptrCast(ctx), &on_fulfilled);
            var on_rejected: c.napi_value = undefined;
            _ = c.napi_create_function(env, "onRejected", "onRejected".len, promiseCatchCallback, @ptrCast(ctx), &on_rejected);

            var then_args = [_]c.napi_value{ on_fulfilled, on_rejected };
            var then_result: c.napi_value = undefined;
            if (c.napi_call_function(env, js_result, then_fn, 2, &then_args, &then_result) != c.napi_ok) {
                signalResponse(ctx, .{});
            }
            // Promise 경우: 여기서 리턴. 워커 스레드는 then/catch 콜백이 signal할 때까지 대기.
            return;
        }

        // 동기 결과: 즉시 파싱하여 시그널
        signalResponse(ctx, parseJsResult(env, js_result));
    }

    /// 워커 스레드에서 호출 — JS 콜백 실행 후 결과 대기.
    /// per-call CallContext를 스택에 생성하여 멀티스레드 안전.
    fn callHookFull(self: *NapiPlugin, hook: HookType, arg1: []const u8, arg2: ?[]const u8, files: ?[]const bundler_mod.emitter.OutputFile, current_module: ?*const anyopaque, resolve_cache: ?*anyopaque, emit_store: ?*anyopaque) ?PluginResponse {
        var ctx = CallContext{
            .hook = hook,
            .arg1 = arg1,
            .arg2 = arg2,
            .output_files = files,
            .current_module = current_module,
            .resolve_cache = resolve_cache,
            .emit_store = emit_store,
        };

        if (c.napi_call_threadsafe_function(self.tsfn, @ptrCast(&ctx), c.napi_tsfn_blocking) != c.napi_ok) {
            return null;
        }

        // 30초 타임아웃: Promise가 resolve/reject되지 않는 경우 hang 방지.
        // 0.16: Io.Condition 에 timedWait 가 없으므로 Io.Event.waitTimeout + 절대
        // deadline. waitTimeout 은 spurious wakeup 도 error.Timeout 으로 반환하므로,
        // deadline 이 아직 미래면 재대기(실제 timeout 만 null 반환).
        const io = common.io();
        const deadline: std.Io.Timeout = (std.Io.Timeout{ .duration = std.Io.Duration.fromSeconds(30) }).toDeadline(io);
        while (true) {
            ctx.done.waitTimeout(io, deadline) catch {
                if (deadline.toDurationFromNow(io)) |d| {
                    if (d.toNanoseconds() > 0) continue; // 아직 시간 남음 → spurious, 재대기
                }
                return null; // deadline 경과 → 실제 timeout
            };
            break; // is_set
        }

        return ctx.response;
    }

    fn callHook(self: *NapiPlugin, hook: HookType, arg1: []const u8, arg2: ?[]const u8) ?PluginResponse {
        return self.callHookFull(hook, arg1, arg2, null, null, null, null);
    }

    /// JSON string field 인코딩 — `"` `\` 와 control char escape.
    fn appendJsonString(buf: *std.ArrayList(u8), alloc: std.mem.Allocator, s: []const u8) !void {
        try buf.append(alloc, '"');
        for (s) |ch| switch (ch) {
            '"' => try buf.appendSlice(alloc, "\\\""),
            '\\' => try buf.appendSlice(alloc, "\\\\"),
            '\n' => try buf.appendSlice(alloc, "\\n"),
            '\r' => try buf.appendSlice(alloc, "\\r"),
            '\t' => try buf.appendSlice(alloc, "\\t"),
            else => if (ch < 0x20) {
                var hex: [6]u8 = undefined;
                const written = std.fmt.bufPrint(&hex, "\\u{x:0>4}", .{ch}) catch unreachable;
                try buf.appendSlice(alloc, written);
            } else {
                try buf.append(alloc, ch);
            },
        };
        try buf.append(alloc, '"');
    }

    // ─── AST 훅 타입 alias (NapiPluginAdapter 가 NapiPlugin.AstTransformCtx / FunctionInfo 로 참조) ───
    const AstTransformCtx = zntc_lib.transformer.ast_plugin_mod.AstTransformCtx;
    const FunctionInfo = zntc_lib.transformer.ast_plugin_mod.FunctionInfo;

    pub fn toPlugin(self: *NapiPlugin) Plugin {
        return NapiPluginAdapter(NapiPlugin).buildPlugin(self);
    }

    pub fn deinit(self: *NapiPlugin) void {
        _ = c.napi_release_threadsafe_function(self.tsfn, c.napi_tsfn_release);
        native_alloc.free(self.name);
        native_alloc.destroy(self);
    }
};

// ─── NapiPluginAdapter: NapiPlugin / NapiSyncPlugin 의 공유 per-hook adapter ───
// 두 bridge 가 transport (TSFN vs 메인-스레드 직접 호출) 만 다르고 hook adapter 본체는 동일했다.
// `Self` 가 아래 method/필드를 갖춘 struct 라면 모두 사용 가능:
//   - `name: []const u8`
//   - `callHook(self, hook, arg1, arg2) ?NapiPlugin.PluginResponse`
//   - `callHookFull(self, hook, arg1, arg2, files) ?NapiPlugin.PluginResponse`
fn NapiPluginAdapter(comptime Self: type) type {
    const HookType = NapiPlugin.HookType;
    const PluginResponse = NapiPlugin.PluginResponse;

    return struct {
        fn failWithResponse(
            self: *Self,
            resp: PluginResponse,
            alloc: std.mem.Allocator,
            hook_ctx: *plugin_mod.HookContext,
        ) PluginError {
            const failure = plugin_mod.PluginFailure.init(
                alloc,
                resp.failure_plugin_name orelse self.name,
                resp.failure_hook_name orelse "plugin",
                resp.failure_message orelse "Plugin hook failed",
                resp.failure_file orelse "",
                resp.failure_line,
                resp.failure_column,
            ) catch return error.OutOfMemory;
            hook_ctx.failure = failure;
            return error.PluginFailed;
        }

        fn callCodeHook(
            self: *Self,
            hook: HookType,
            arg1: []const u8,
            arg2: ?[]const u8,
            alloc: std.mem.Allocator,
            hook_ctx: *plugin_mod.HookContext,
        ) PluginError!?[]const u8 {
            // PR3 current_module(getModuleInfo) + PR4 resolve_cache(this.resolve) + PR5 emit_store(this.emitFile) 를 transform/renderChunk 에 전달.
            const resp = self.callHookFull(hook, arg1, arg2, null, hook_ctx.current_module, hook_ctx.resolve_cache, hook_ctx.emit_store) orelse return null;
            defer NapiPlugin.freeResponseFields(resp);
            if (resp.is_failure) return failWithResponse(self, resp, alloc, hook_ctx);
            // meta 는 code 유무와 무관하게 전달 — Rollup transform 은 code 없이 { meta } 만 반환 가능
            // (#1880 #3664 P1). runTransformForModule 이 hook_ctx.meta 를 module.plugin_meta 에 merge.
            try NapiPlugin.setResponseMeta(resp, alloc, hook_ctx);
            if (resp.code) |result_code| {
                const result = alloc.dupe(u8, result_code) catch return error.OutOfMemory;
                try NapiPlugin.setResponseSourceMaps(resp, alloc, hook_ctx);
                return result;
            }
            return null;
        }

        /// (deferred 4) plugin response → owned ResolvedModule builder. dupe + `.owned`
        /// 패턴 한 곳에 모아 drift 방지 — 한 site 만 dupe 빠뜨려도 owner 와 mismatch 면
        /// bundler 가 borrowed slice 를 free 시도 → panic.
        ///
        /// **Invariants** (review finding):
        /// - `module_type = .js`: 현재 module_registry.zig:100 `fromExtension(ext)` 가
        ///   덮어쓰므로 dead — 향후 plugin 제공 module_type 을 trust 하면 caller 명시
        ///   파라미터로 확장 필요.
        /// - `.virtual.plugin_data`: null 고정 — Rollup pluginContext meta thread 도입 시
        ///   시그니처 확장 필요.
        /// - NAPI 가 향후 `.external/.custom/.dataurl` 변환을 노출하면 동일한 buildOwnedX
        ///   helper 추가 (inline alloc.dupe + .owner=.owned 패턴 회귀 차단).
        fn buildOwnedFile(alloc: std.mem.Allocator, path: []const u8) PluginError!plugin_mod.ResolvedModule {
            return .{ .file = .{
                .path = alloc.dupe(u8, path) catch return error.OutOfMemory,
                .module_type = .js,
                .owner = .owned,
            } };
        }

        fn buildOwnedVirtual(alloc: std.mem.Allocator, path: []const u8) PluginError!plugin_mod.ResolvedModule {
            return .{ .virtual = .{
                .path = alloc.dupe(u8, path) catch return error.OutOfMemory,
                .owner = .owned,
            } };
        }

        fn buildOwnedDisabled(alloc: std.mem.Allocator, path: []const u8) PluginError!plugin_mod.ResolvedModule {
            return .{ .disabled = .{
                .path = alloc.dupe(u8, path) catch return error.OutOfMemory,
                .module_type = .js,
                .owner = .owned,
            } };
        }

        fn pluginResolveId(
            ctx: ?*anyopaque,
            specifier: []const u8,
            importer: ?[]const u8,
            alloc: std.mem.Allocator,
            hook_ctx: *plugin_mod.HookContext,
        ) PluginError!?plugin_mod.ResolvedModule {
            const self: *Self = @ptrCast(@alignCast(ctx.?));
            // this.resolve (PR4): resolveId hook 에 resolve_cache 전달. this.emitFile (PR5): emit_store 전달.
            const resp = self.callHookFull(.resolveId, specifier, importer, null, null, hook_ctx.resolve_cache, hook_ctx.emit_store) orelse return null;
            defer NapiPlugin.freeResponseFields(resp);
            if (resp.is_failure) return failWithResponse(self, resp, alloc, hook_ctx);

            // disabled: 빈 모듈로 처리. path는 식별용 — resolved_path 또는 specifier 그대로.
            // Metro `{ type: 'empty' }` 매핑, webpack `resolve.fallback: false`와 동등.
            if (resp.is_disabled) {
                return try buildOwnedDisabled(alloc, resp.resolved_path orelse specifier);
            }

            if (resp.resolved_path) |path| {
                // esbuild/Rollup 관례: NUL byte prefix 또는 query (`?` 포함) 가 있는 ID 는
                // fs 에 실재하지 않는 가상 모듈. `.file` 로 wrap 하면 native resolver 가
                // fs lookup 을 시도해 `Cannot resolve module` 진단을 낸다. `.virtual` 로
                // 격상해 plugin 의 load hook 이 본문을 채울 때까지 그래프에 등록만 한다.
                // (#3022 — vue/svelte SFC 의 `\0plugin-vue:...` 및 `?vue&type=style&lang.css`)
                // 술어는 graph/plugins.zig 와 동일 — 한 곳에서만 정의 (drift 방지).
                if (graph_plugins_mod.isPluginVirtualId(path)) {
                    return try buildOwnedVirtual(alloc, path);
                }
                return try buildOwnedFile(alloc, path);
            }
            return null;
        }

        fn pluginLoad(
            ctx: ?*anyopaque,
            path: []const u8,
            alloc: std.mem.Allocator,
            hook_ctx: *plugin_mod.HookContext,
        ) PluginError!?plugin_mod.LoadResult {
            const self: *Self = @ptrCast(@alignCast(ctx.?));
            // this.resolve (PR4): load hook 에 resolve_cache 전달. this.emitFile (PR5): emit_store 전달.
            const resp = self.callHookFull(.load, path, null, null, null, hook_ctx.resolve_cache, hook_ctx.emit_store) orelse return null;
            defer NapiPlugin.freeResponseFields(resp);
            if (resp.is_failure) return failWithResponse(self, resp, alloc, hook_ctx);
            const result_code = resp.code orelse return null;
            const contents = alloc.dupe(u8, result_code) catch return error.OutOfMemory;
            try NapiPlugin.setResponseSourceMaps(resp, alloc, hook_ctx);
            // resp.meta 는 native_alloc 소유(freeResponseFields 가 해제) → caller(parse_arena) 로 dupe (#1880 PR2).
            const meta_dup: ?[]const u8 = if (resp.meta) |m| (alloc.dupe(u8, m) catch return error.OutOfMemory) else null;
            // syntheticNamedExports 도 동일하게 parse_arena 로 dupe (#3664 P2).
            const synth_dup: ?[]const u8 = if (resp.synthetic_named_exports) |s| (alloc.dupe(u8, s) catch return error.OutOfMemory) else null;
            return .{ .contents = contents, .loader = resp.loader_override, .module_type = resp.loader_module_type, .meta = meta_dup, .synthetic_named_exports = synth_dup };
        }

        fn pluginTransform(
            ctx: ?*anyopaque,
            code: []const u8,
            id: []const u8,
            alloc: std.mem.Allocator,
            hook_ctx: *plugin_mod.HookContext,
        ) PluginError!?[]const u8 {
            const self: *Self = @ptrCast(@alignCast(ctx.?));
            return callCodeHook(self, .transform, code, id, alloc, hook_ctx);
        }

        fn pluginRenderChunk(
            ctx: ?*anyopaque,
            code: []const u8,
            chunk_name: []const u8,
            alloc: std.mem.Allocator,
            hook_ctx: *plugin_mod.HookContext,
        ) PluginError!?[]const u8 {
            const self: *Self = @ptrCast(@alignCast(ctx.?));
            return callCodeHook(self, .renderChunk, code, chunk_name, alloc, hook_ctx);
        }

        fn pluginGenerateBundle(ctx: ?*anyopaque, output_files: []const bundler_mod.emitter.OutputFile, hook_ctx: *plugin_mod.HookContext) void {
            const self: *Self = @ptrCast(@alignCast(ctx.?));
            // PR7-2c: emit_store 를 전달해 generateBundle hook 의 this.getFileName(chunkRef) 활성화
            // (back-fill 된 chunk 파일명 조회). discovery hook 과 달리 generateBundle 은 청킹 후라 확정.
            if (self.callHookFull(.generateBundle, "", null, output_files, null, null, hook_ctx.emit_store)) |resp| {
                NapiPlugin.freeResponseFields(resp);
            }
        }

        fn pluginBuildStart(ctx: ?*anyopaque, hook_ctx: *plugin_mod.HookContext) PluginError!void {
            const self: *Self = @ptrCast(@alignCast(ctx.?));
            const resp = self.callHook(.buildStart, "", null) orelse return;
            defer NapiPlugin.freeResponseFields(resp);
            if (resp.is_failure) return failWithResponse(self, resp, native_alloc, hook_ctx);
        }

        fn pluginBuildEnd(
            ctx: ?*anyopaque,
            build_error: ?*const bundler_mod.types.BundlerDiagnostic,
            hook_ctx: *plugin_mod.HookContext,
        ) PluginError!void {
            const self: *Self = @ptrCast(@alignCast(ctx.?));
            // Phase 1 minimal forward — message string 만 JS Error 로 wrap.
            // code/severity/file_path/span/step/suggestion 손실은 follow-up 으로 RollupError 호환
            // 객체 (`{ code, message, file, line }`) 직렬화 검토 (#2156 follow-up).
            const msg = if (build_error) |d| d.message else "";
            const resp = self.callHook(.buildEnd, msg, null) orelse return;
            defer NapiPlugin.freeResponseFields(resp);
            if (resp.is_failure) return failWithResponse(self, resp, native_alloc, hook_ctx);
        }

        fn pluginResolveContext(
            ctx: ?*anyopaque,
            dir: []const u8,
            recursive: bool,
            filter_pattern: ?[]const u8,
            filter_flags: ?[]const u8,
            importer: []const u8,
            alloc: std.mem.Allocator,
            hook_ctx: *plugin_mod.HookContext,
        ) PluginError!?[]const []const u8 {
            const self: *Self = @ptrCast(@alignCast(ctx.?));

            // JSON 직렬화: { dir, recursive, filter?, flags?, importer }
            var json_buf: std.ArrayList(u8) = .empty;
            defer json_buf.deinit(native_alloc);
            json_buf.append(native_alloc, '{') catch return null;
            json_buf.appendSlice(native_alloc, "\"dir\":") catch return null;
            NapiPlugin.appendJsonString(&json_buf, native_alloc, dir) catch return null;
            json_buf.appendSlice(native_alloc, ",\"recursive\":") catch return null;
            json_buf.appendSlice(native_alloc, if (recursive) "true" else "false") catch return null;
            if (filter_pattern) |fp| {
                json_buf.appendSlice(native_alloc, ",\"filter\":") catch return null;
                NapiPlugin.appendJsonString(&json_buf, native_alloc, fp) catch return null;
            }
            if (filter_flags) |ff| {
                json_buf.appendSlice(native_alloc, ",\"flags\":") catch return null;
                NapiPlugin.appendJsonString(&json_buf, native_alloc, ff) catch return null;
            }
            json_buf.appendSlice(native_alloc, ",\"importer\":") catch return null;
            NapiPlugin.appendJsonString(&json_buf, native_alloc, importer) catch return null;
            json_buf.append(native_alloc, '}') catch return null;

            const resp = self.callHookFull(.resolveContext, json_buf.items, null, null, null, null, null) orelse return null;
            defer NapiPlugin.freeResponseFields(resp);
            if (resp.is_failure) return failWithResponse(self, resp, alloc, hook_ctx);

            const matches = resp.context_matches orelse return null;

            // caller (graph) allocator 로 dupe — outer slice + inner strings.
            // ImportRecord.context_matches contract: outer/inner 모두 graph 가 free.
            const out = alloc.alloc([]const u8, matches.len) catch return null;
            for (matches, 0..) |s, i| {
                out[i] = alloc.dupe(u8, s) catch {
                    // 부분 실패: 이미 할당한 것들 free 후 null 반환
                    for (out[0..i]) |prev| alloc.free(prev);
                    alloc.free(out);
                    return null;
                };
            }
            return out;
        }

        fn pluginAstFunction(
            ctx: ?*anyopaque,
            api: *NapiPlugin.AstTransformCtx,
            func: NapiPlugin.FunctionInfo,
        ) PluginError!void {
            const self: *Self = @ptrCast(@alignCast(ctx.?));

            const json = serializeFunctionInfo(api, func) catch return;
            defer native_alloc.free(json);

            const resp = self.callHook(.astFunction, json, null) orelse return;
            defer NapiPlugin.freeResponseFields(resp);
            // onFunction 은 transformer 가 PluginFailed 를 swallow 하므로 metadata 는 미전달.
            if (resp.is_failure) return error.PluginFailed;

            if (resp.strip_directive != null) {
                _ = api.stripDirective(func.body_idx) catch return;
            }
            if (resp.trailing_code) |codes| {
                for (codes) |code_str| {
                    const stmts = api.parseAndInjectStatements(code_str) catch continue;
                    for (stmts) |stmt| {
                        api.addTrailingStatement(stmt) catch continue;
                    }
                }
            }
        }

        /// `Plugin` vtable 빌더. `closeBundle` 은 native 에서 호출 안 함 — Rollup 의미 보존을
        /// 위해 JS layer (writeOutputFiles 후) 가 dispatcher 로 직접 호출. native bundle() 끝
        /// 시점은 contents 결정 직후라 disk write *전* 이므로 closeBundle 자리 부적합.
        fn buildPlugin(self: *Self) Plugin {
            return .{
                .name = self.name,
                .context = @ptrCast(self),
                .resolveId = pluginResolveId,
                .load = pluginLoad,
                .transform = pluginTransform,
                .renderChunk = pluginRenderChunk,
                .generateBundle = pluginGenerateBundle,
                .onFunction = pluginAstFunction,
                .resolveContext = pluginResolveContext,
                .buildStart = pluginBuildStart,
                .buildEnd = pluginBuildEnd,
                .closeBundle = null,
            };
        }
    };
}

// ─── NapiSyncPlugin: buildSync() sync-only JS plugin bridge ───
// buildSync() 은 NAPI main thread 를 블로킹하므로 TSFN으로 main thread 에 재진입할 수 없다.
// sync dispatcher 를 직접 호출하고 Promise/thenable 은 plugin_error 로 즉시 실패시킨다.

pub const NapiSyncPlugin = struct {
    name: []const u8,
    env: c.napi_env,
    callback_ref: c.napi_ref,

    fn makeFailure(
        plugin_name: []const u8,
        hook_name: []const u8,
        message: []const u8,
        file_path: ?[]const u8,
    ) NapiPlugin.PluginResponse {
        return .{
            .is_failure = true,
            .failure_plugin_name = native_alloc.dupe(u8, plugin_name) catch null,
            .failure_hook_name = native_alloc.dupe(u8, hook_name) catch null,
            .failure_message = native_alloc.dupe(u8, message) catch null,
            .failure_file = if (file_path) |fp| native_alloc.dupe(u8, fp) catch null else null,
        };
    }

    fn clearPendingException(env: c.napi_env) void {
        var pending: bool = false;
        if (c.napi_is_exception_pending(env, &pending) == c.napi_ok and pending) {
            var exception: c.napi_value = undefined;
            _ = c.napi_get_and_clear_last_exception(env, &exception);
        }
    }

    fn callHookFull(
        self: *NapiSyncPlugin,
        hook: NapiPlugin.HookType,
        arg1: []const u8,
        arg2: ?[]const u8,
        files: ?[]const bundler_mod.emitter.OutputFile,
        current_module: ?*const anyopaque,
        resolve_cache: ?*anyopaque,
        emit_store: ?*anyopaque,
    ) ?NapiPlugin.PluginResponse {
        // buildSync 는 this.getModuleInfo/this.resolve/this.emitFile 미지원 — async build() 만 PR3/4/5 지원.
        _ = current_module;
        _ = resolve_cache;
        _ = emit_store;
        var js_callback: c.napi_value = undefined;
        if (c.napi_get_reference_value(self.env, self.callback_ref, &js_callback) != c.napi_ok) {
            return null;
        }

        const hook_name = @tagName(hook);
        var hook_str: c.napi_value = undefined;
        _ = c.napi_create_string_utf8(self.env, hook_name.ptr, hook_name.len, &hook_str);

        var js_arg1: c.napi_value = undefined;
        if (files) |output_files| {
            _ = c.napi_create_array_with_length(self.env, output_files.len, &js_arg1);
            for (output_files, 0..) |file, i| {
                var js_file: c.napi_value = undefined;
                _ = c.napi_create_object(self.env, &js_file);
                var js_path: c.napi_value = undefined;
                _ = c.napi_create_string_utf8(self.env, file.path.ptr, file.path.len, &js_path);
                _ = c.napi_set_named_property(self.env, js_file, "path", js_path);
                result_mod.setContentsBuffer(self.env, js_file, file.contents);
                _ = c.napi_set_element(self.env, js_arg1, @intCast(i), js_file);
            }
        } else {
            _ = c.napi_create_string_utf8(self.env, arg1.ptr, arg1.len, &js_arg1);
        }

        var js_arg2: c.napi_value = undefined;
        if (arg2) |a2| {
            _ = c.napi_create_string_utf8(self.env, a2.ptr, a2.len, &js_arg2);
        } else {
            _ = c.napi_get_null(self.env, &js_arg2);
        }

        var js_result: c.napi_value = undefined;
        const args = [_]c.napi_value{ hook_str, js_arg1, js_arg2 };
        var js_undefined: c.napi_value = undefined;
        _ = c.napi_get_undefined(self.env, &js_undefined);
        if (c.napi_call_function(self.env, js_undefined, js_callback, 3, &args, &js_result) != c.napi_ok) {
            clearPendingException(self.env);
            return makeFailure(self.name, hook_name, "Plugin hook failed", arg2);
        }

        var is_promise: bool = false;
        _ = c.napi_is_promise(self.env, js_result, &is_promise);
        if (is_promise) {
            return makeFailure(
                self.name,
                hook_name,
                "buildSync() does not support async plugin hooks. Return a synchronous value or use build() instead.",
                arg2,
            );
        }

        return NapiPlugin.parseJsResult(self.env, js_result);
    }

    fn callHook(self: *NapiSyncPlugin, hook: NapiPlugin.HookType, arg1: []const u8, arg2: ?[]const u8) ?NapiPlugin.PluginResponse {
        return self.callHookFull(hook, arg1, arg2, null, null, null, null);
    }

    pub fn toPlugin(self: *NapiSyncPlugin) Plugin {
        return NapiPluginAdapter(NapiSyncPlugin).buildPlugin(self);
    }

    pub fn deinit(self: *NapiSyncPlugin) void {
        _ = c.napi_delete_reference(self.env, self.callback_ref);
        native_alloc.free(self.name);
        native_alloc.destroy(self);
    }
};

// ─── NapiManualChunksResolver: `manualChunks(id)` JS 함수 브리지 (#1027 Phase 2) ───
// Rollup manualChunks 동일 시그니처. 모듈당 1회 sync 호출 (pre-pass 에서 수집).
// worker thread 에서 call → tsfn 으로 main dispatch → condvar 대기 → 결과 반환.
// NapiPlugin 의 축약 버전 (1 hook, no filter, sync only, promise 불필요).

pub const NapiManualChunksResolver = struct {
    tsfn: c.napi_threadsafe_function,
    /// JS resolver 가 반환한 chunk name 의 dedup cache. parseJsResult 가
    /// `native_alloc.dupe` 한 owned slice 를 보관, 같은 이름이 다시 반환되면
    /// cache hit 으로 기존 slice 재사용 → 중복 alloc 0. chunk graph 가 이
    /// slice 들을 borrow 하지만 free 책임은 없음 (record-form `mc.name` 와
    /// 동일 borrow 패턴). resolver.deinit 에서 일괄 free.
    ///
    /// **Lifetime invariant**: `chunk_graph` (Bundler.bundle() 내부 local) 의
    /// lifetime 동안 cache 가 유지되어야 borrow 가 안전. build_async/build_sync
    /// 는 build 마다 새 resolver 생성·소멸. watch 는 watch session 동안 동일
    /// resolver 재사용 → rebuild 마다 cache 가 단조 증가 (bounded by unique JS
    /// 반환 name 집합 — 일반 사용 시 'vendor'/'react' 등 소수, 악의적 JS 가
    /// rebuild-varying name 반환 시만 unbounded). rebuild N+1 시작 시 N 의
    /// chunk_graph 는 이미 deinit 되어 cache slice borrow 없음 — 단, 의도적
    /// dedup 정책상 clear 안 함.
    ///
    /// **TSFN UAF 회피**: `napi_release_threadsafe_function(release)` 는 비동기
    /// 라 deinit 직후 `destroy(self)` 가 in-flight callJsCallback (self 를
    /// ctx_ptr 로 deref) 와 race 가능. 호출자가 'deinit 시점에 in-flight TSFN
    /// 없음' invariant 보장 — buildCompleteTsfn 은 worker 의 동기 resolve() 가
    /// 모두 끝나고 completion_tsfn 받은 후에 실행, WatchAsyncData.deinit 도
    /// stop_flag 로 worker 종료 후. 향후 caller flow 변경 시 이 invariant 보전.
    name_cache: std.StringHashMap(void),

    const CallContext = struct {
        id: []const u8,
        graph: ?*const anyopaque,
        result: ?[]const u8 = null,
        /// 0.16: std.Thread.Mutex/Condition 제거 → one-shot 핸드오프는 std.Io.Event.
        done: std.Io.Event = .unset,
    };

    /// ModuleIndex 배열 → JS string[]. invalid index 는 skip 해서 compact 한 배열 반환.
    fn pathArrayFromIndices(
        env: c.napi_env,
        graph: ?*const anyopaque,
        indices: []const types_mod.ModuleIndex,
    ) c.napi_value {
        var js_arr: c.napi_value = undefined;
        _ = c.napi_create_array(env, &js_arr);
        var write_idx: u32 = 0;
        for (indices) |idx| {
            const p = types_mod.getModulePathByIndex(graph, idx) orelse continue;
            var js_p: c.napi_value = undefined;
            _ = c.napi_create_string_utf8(env, p.ptr, p.len, &js_p);
            _ = c.napi_set_element(env, js_arr, write_idx, js_p);
            write_idx += 1;
        }
        return js_arr;
    }

    /// JSON 문자열 → JS object (global `JSON.parse`). 실패/예외 시 빈 객체 `{}` 반환.
    /// plugin meta(JSON string)를 ModuleInfo.meta JS object 로 복원할 때 사용 (#1880 PR2).
    fn parseJsonToObject(env: c.napi_env, json: []const u8) c.napi_value {
        var empty_obj: c.napi_value = undefined;
        _ = c.napi_create_object(env, &empty_obj);
        var global: c.napi_value = undefined;
        if (c.napi_get_global(env, &global) != c.napi_ok) return empty_obj;
        const json_ns = getNamedProperty(env, global, "JSON") orelse return empty_obj;
        const parse_fn = getNamedProperty(env, json_ns, "parse") orelse return empty_obj;
        var js_str: c.napi_value = undefined;
        _ = c.napi_create_string_utf8(env, json.ptr, json.len, &js_str);
        var result: c.napi_value = undefined;
        const args = [_]c.napi_value{js_str};
        if (c.napi_call_function(env, json_ns, parse_fn, 1, &args, &result) != c.napi_ok) {
            var pending: bool = false;
            _ = c.napi_is_exception_pending(env, &pending);
            if (pending) {
                var e: c.napi_value = undefined;
                _ = c.napi_get_and_clear_last_exception(env, &e);
            }
            return empty_obj;
        }
        return result;
    }

    /// JS `meta.getModuleInfo(id)` 구현. napi function 의 data 슬롯에 graph 포인터를
    /// 담아 전달받는다. 동일 bundle() 안에서 모든 resolver 호출이 같은 graph 를 공유.
    fn getModuleInfoCallback(env: c.napi_env, info: c.napi_callback_info) callconv(.c) c.napi_value {
        var js_null: c.napi_value = undefined;
        _ = c.napi_get_null(env, &js_null);

        var argc: usize = 1;
        var argv: [1]c.napi_value = undefined;
        var data: ?*anyopaque = null;
        if (c.napi_get_cb_info(env, info, &argc, &argv, null, &data) != c.napi_ok) return js_null;
        if (argc < 1) return js_null;

        const id = getStringArg(env, argv[0], native_alloc) orelse return js_null;
        defer native_alloc.free(id);

        const graph: ?*const anyopaque = @ptrCast(data);
        const mod_info = types_mod.getModuleInfo(graph, id) orelse return js_null;

        var js_obj: c.napi_value = undefined;
        _ = c.napi_create_object(env, &js_obj);

        var js_id_str: c.napi_value = undefined;
        _ = c.napi_create_string_utf8(env, mod_info.id.ptr, mod_info.id.len, &js_id_str);
        _ = c.napi_set_named_property(env, js_obj, "id", js_id_str);

        var js_is_entry: c.napi_value = undefined;
        _ = c.napi_get_boolean(env, mod_info.is_entry, &js_is_entry);
        _ = c.napi_set_named_property(env, js_obj, "isEntry", js_is_entry);

        var js_is_external: c.napi_value = undefined;
        _ = c.napi_get_boolean(env, mod_info.is_external, &js_is_external);
        _ = c.napi_set_named_property(env, js_obj, "isExternal", js_is_external);

        var js_has_side_effects: c.napi_value = undefined;
        _ = c.napi_get_boolean(env, mod_info.has_module_side_effects, &js_has_side_effects);
        _ = c.napi_set_named_property(env, js_obj, "hasModuleSideEffects", js_has_side_effects);

        var js_code: c.napi_value = undefined;
        if (mod_info.code) |src| {
            // UTF-8 검증 실패 시 null 로 fallback (binary loader 등 비-UTF8 source 대응)
            if (c.napi_create_string_utf8(env, src.ptr, src.len, &js_code) != c.napi_ok) {
                _ = c.napi_get_null(env, &js_code);
            }
        } else {
            _ = c.napi_get_null(env, &js_code);
        }
        _ = c.napi_set_named_property(env, js_obj, "code", js_code);

        var js_is_included: c.napi_value = undefined;
        _ = c.napi_get_boolean(env, mod_info.is_included, &js_is_included);
        _ = c.napi_set_named_property(env, js_obj, "isIncluded", js_is_included);

        var js_synthetic: c.napi_value = undefined;
        _ = c.napi_get_boolean(env, mod_info.synthetic_named_exports, &js_synthetic);
        _ = c.napi_set_named_property(env, js_obj, "syntheticNamedExports", js_synthetic);

        var js_exports: c.napi_value = undefined;
        _ = c.napi_create_array(env, &js_exports);
        for (mod_info.exports, 0..) |name, i| {
            var js_name: c.napi_value = undefined;
            _ = c.napi_create_string_utf8(env, name.ptr, name.len, &js_name);
            _ = c.napi_set_element(env, js_exports, @intCast(i), js_name);
        }
        _ = c.napi_set_named_property(env, js_obj, "exports", js_exports);

        _ = c.napi_set_named_property(env, js_obj, "implicitlyLoadedAfterOneOf", pathArrayFromIndices(env, graph, mod_info.implicitly_loaded_after_one_of));
        _ = c.napi_set_named_property(env, js_obj, "implicitlyLoadedBefore", pathArrayFromIndices(env, graph, mod_info.implicitly_loaded_before));

        _ = c.napi_set_named_property(env, js_obj, "importers", pathArrayFromIndices(env, graph, mod_info.importers));
        _ = c.napi_set_named_property(env, js_obj, "dynamicImporters", pathArrayFromIndices(env, graph, mod_info.dynamic_importers));
        _ = c.napi_set_named_property(env, js_obj, "importedIds", pathArrayFromIndices(env, graph, mod_info.imported_ids));
        _ = c.napi_set_named_property(env, js_obj, "dynamicallyImportedIds", pathArrayFromIndices(env, graph, mod_info.dynamically_imported_ids));

        // ModuleInfo.meta (#1880 PR2): plugin 이 부여한 JSON 을 object 로 복원. 미설정 시 빈 객체 {}.
        var js_meta: c.napi_value = undefined;
        if (mod_info.meta) |meta_json| {
            js_meta = parseJsonToObject(env, meta_json);
        } else {
            _ = c.napi_create_object(env, &js_meta);
        }
        _ = c.napi_set_named_property(env, js_obj, "meta", js_meta);

        return js_obj;
    }

    /// threadsafe function 의 call_js 콜백 (main thread).
    fn callJsCallback(env: c.napi_env, js_callback: c.napi_value, ctx_ptr: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
        const ctx: *CallContext = @ptrCast(@alignCast(data.?));
        const self: *NapiManualChunksResolver = @ptrCast(@alignCast(ctx_ptr.?));

        var js_id: c.napi_value = undefined;
        _ = c.napi_create_string_utf8(env, ctx.id.ptr, ctx.id.len, &js_id);

        var js_meta: c.napi_value = undefined;
        _ = c.napi_create_object(env, &js_meta);
        if (ctx.graph) |g| {
            var js_get_mod_info: c.napi_value = undefined;
            _ = c.napi_create_function(
                env,
                "getModuleInfo",
                "getModuleInfo".len,
                getModuleInfoCallback,
                @constCast(g),
                &js_get_mod_info,
            );
            _ = c.napi_set_named_property(env, js_meta, "getModuleInfo", js_get_mod_info);
        }

        var js_undefined: c.napi_value = undefined;
        _ = c.napi_get_undefined(env, &js_undefined);

        var js_result: c.napi_value = undefined;
        const args = [_]c.napi_value{ js_id, js_meta };
        if (c.napi_call_function(env, js_undefined, js_callback, 2, &args, &js_result) != c.napi_ok) {
            // JS exception 은 uncaught 로 전파되기 전에 clear — 번들 중단 방지.
            // manualChunks 가 throw 하면 해당 모듈은 null (auto 분배) 로 취급.
            var is_pending: bool = false;
            _ = c.napi_is_exception_pending(env, &is_pending);
            if (is_pending) {
                var exception: c.napi_value = undefined;
                _ = c.napi_get_and_clear_last_exception(env, &exception);
            }
            signalResult(ctx, null);
            return;
        }

        // null / undefined / string 만 허용. Promise 등 object 는 에러로 간주 (null).
        var vtype: c.napi_valuetype = undefined;
        _ = c.napi_typeof(env, js_result, &vtype);
        if (vtype != c.napi_string) {
            signalResult(ctx, null);
            return;
        }

        // UTF-8 길이 측정 → NUL terminator 용 +1 임시 alloc → 정확 크기로 dupe →
        // 임시 즉시 free. `bufsize=len+1` 호출이 buf 끝에 NUL 을 작성하므로
        // alloc 크기 < bufsize 면 1바이트 OOB write (#dev-leak-investigation
        // sweep). `common.getStringArg` 와 동일 root cause / contract.
        var len: usize = 0;
        _ = c.napi_get_value_string_utf8(env, js_result, null, 0, &len);
        const tmp = native_alloc.alloc(u8, len + 1) catch {
            signalResult(ctx, null);
            return;
        };
        defer native_alloc.free(tmp);
        var written: usize = 0;
        _ = c.napi_get_value_string_utf8(env, js_result, tmp.ptr, len + 1, &written);
        const slice = tmp[0..written];

        // dedup cache: 같은 chunk name 이 반복 반환되어도 alloc 1회. chunk_graph
        // 가 이 slice 를 borrow (deinit 시 free 안 함) — resolver.deinit 가 일괄
        // 회수. ZNTC 일반 사용 시 manualChunks resolver 가 'vendor' / 'react'
        // 같은 소수의 group name 을 N 개 모듈에 반복 반환 → cache hit 비율 매우
        // 높음.
        const gop = self.name_cache.getOrPut(slice) catch {
            signalResult(ctx, null);
            return;
        };
        if (gop.found_existing) {
            signalResult(ctx, gop.key_ptr.*);
            return;
        }
        const owned = native_alloc.dupe(u8, slice) catch {
            // miss-but-OOM: 방금 추가한 reserved slot 제거 (slice tmp 는 곧 free).
            _ = self.name_cache.remove(slice);
            signalResult(ctx, null);
            return;
        };
        // hashmap key 를 owned slice 로 update — getOrPut 직후의 borrow (tmp) 가
        // defer 로 곧 free 되므로 owned 로 갈아끼우지 않으면 dangling key 가 됨.
        gop.key_ptr.* = owned;
        signalResult(ctx, owned);
    }

    fn signalResult(ctx: *CallContext, result: ?[]const u8) void {
        ctx.result = result;
        ctx.done.set(common.io());
    }

    /// Zig resolver 인터페이스 — `ManualChunksResolveFn` 과 동일 시그니처.
    /// worker thread 에서 호출됨. JS 호출 후 동기 대기.
    fn resolve(ctx_ptr: ?*anyopaque, id: []const u8, graph: ?*const anyopaque) ?[]const u8 {
        const self: *NapiManualChunksResolver = @ptrCast(@alignCast(ctx_ptr.?));
        var call_ctx = CallContext{ .id = id, .graph = graph };

        if (c.napi_call_threadsafe_function(self.tsfn, &call_ctx, c.napi_tsfn_blocking) != c.napi_ok) {
            return null;
        }

        // 0.16: Io.Event 로 one-shot 대기 (signalResult 가 set).
        call_ctx.done.waitUncancelable(common.io());

        return call_ctx.result;
    }

    pub fn deinit(self: *NapiManualChunksResolver) void {
        _ = c.napi_release_threadsafe_function(self.tsfn, c.napi_tsfn_release);
        // dedup cache 의 owned chunk name slice 들 free + map deinit. chunk_graph
        // 가 이 resolver 의 lifetime 동안만 cache 의 slice 를 borrow 하므로
        // 안전.
        var it = self.name_cache.keyIterator();
        while (it.next()) |k| native_alloc.free(k.*);
        self.name_cache.deinit();
        native_alloc.destroy(self);
    }
};

/// JS 함수 값 → NapiManualChunksResolver 생성 + BundleOptions 에 설치.
/// 성공 시 resolver 포인터 반환 (caller 가 deinit 책임), 실패 시 null.
pub fn installManualChunksResolver(
    env: c.napi_env,
    fn_val: c.napi_value,
    opts: *BundleOptions,
) ?*NapiManualChunksResolver {
    const resolver = native_alloc.create(NapiManualChunksResolver) catch return null;
    resolver.* = .{
        .tsfn = undefined,
        .name_cache = std.StringHashMap(void).init(native_alloc),
    };

    var resource_name: c.napi_value = undefined;
    _ = c.napi_create_string_utf8(env, "zntc_manual_chunks", "zntc_manual_chunks".len, &resource_name);
    if (c.napi_create_threadsafe_function(
        env,
        fn_val,
        null,
        resource_name,
        0, // unlimited queue
        1, // initial thread count
        null,
        null,
        @ptrCast(resolver),
        NapiManualChunksResolver.callJsCallback,
        &resolver.tsfn,
    ) != c.napi_ok) {
        // StringHashMap.init 은 zero-alloc 이라 현재 leak 0 이지만, 추후 init
        // 변경 시 fragile — defensive deinit.
        resolver.name_cache.deinit();
        native_alloc.destroy(resolver);
        return null;
    }

    opts.manual_chunks_resolver = NapiManualChunksResolver.resolve;
    opts.manual_chunks_ctx = @ptrCast(resolver);
    return resolver;
}

const appendJsonEscaped = zntc_lib.string_escape.appendEscaped;

/// FunctionInfo를 JSON 문자열로 직렬화한다.
/// JS dispatcher에 arg1로 전달되어 JS 측에서 JSON.parse()로 역직렬화.
fn serializeFunctionInfo(
    api: *NapiPlugin.AstTransformCtx,
    func: NapiPlugin.FunctionInfo,
) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    const alloc = native_alloc;

    try buf.appendSlice(alloc, "{\"name\":");
    if (func.name) |name| {
        try buf.append(alloc, '"');
        try appendJsonEscaped(&buf, alloc, name);
        try buf.append(alloc, '"');
    } else {
        try buf.appendSlice(alloc, "null");
    }

    // directives: body 첫 문장이 디렉티브(string literal)이면 추출
    var has_directives = false;
    try buf.appendSlice(alloc, ",\"directives\":[");
    if (!func.body_idx.isNone()) {
        const Ast = zntc_lib.parser.ast;
        const body = api.transformer.ast.getNode(func.body_idx);
        if ((body.tag == .block_statement or body.tag == .function_body) and body.data.list.len > 0) {
            const first_raw = api.transformer.ast.extra_data.items[body.data.list.start];
            const first_idx: Ast.NodeIndex = @enumFromInt(first_raw);
            if (!first_idx.isNone()) {
                const first = api.transformer.ast.getNode(first_idx);
                // directive 태그 또는 expression_statement > string_literal
                const directive_text: ?[]const u8 = if (first.tag == .directive) blk: {
                    const t = api.transformer.ast.getText(first.span);
                    break :blk if (t.len >= 2) t[1 .. t.len - 1] else null;
                } else if (first.tag == .expression_statement) blk: {
                    const op = api.transformer.ast.getNode(first.data.unary.operand);
                    if (op.tag == .string_literal) {
                        const t = api.transformer.ast.getText(op.data.string_ref);
                        break :blk if (t.len >= 2) t[1 .. t.len - 1] else null;
                    }
                    break :blk null;
                } else null;

                if (directive_text) |dt| {
                    try buf.append(alloc, '"');
                    try appendJsonEscaped(&buf, alloc, dt);
                    try buf.append(alloc, '"');
                    has_directives = true;
                }
            }
        }
    }
    try buf.append(alloc, ']');

    // closureVars: 디렉티브가 있을 때만 계산 (스코프 분석은 비용이 크므로).
    // ctx 캐시 덕분에 worklet_plugin이 먼저 계산했다면 재사용 (#1114).
    try buf.appendSlice(alloc, ",\"closureVars\":[");
    if (has_directives) {
        const closure_vars = api.getClosureVars(&func) catch &.{};
        for (closure_vars, 0..) |cv, i| {
            if (i > 0) try buf.append(alloc, ',');
            try buf.append(alloc, '"');
            try buf.appendSlice(alloc, cv.name);
            try buf.append(alloc, '"');
        }
    }
    try buf.append(alloc, ']');

    // params
    try buf.appendSlice(alloc, ",\"params\":[");
    {
        var pi: u32 = 0;
        while (pi < func.params.len) : (pi += 1) {
            if (pi > 0) try buf.append(alloc, ',');
            const param_raw = api.transformer.ast.extra_data.items[func.params.start + pi];
            const param_idx: zntc_lib.parser.ast.NodeIndex = @enumFromInt(param_raw);
            if (!param_idx.isNone()) {
                const param_node = api.transformer.ast.getNode(param_idx);
                const param_text = api.transformer.ast.getText(param_node.span);
                try buf.append(alloc, '"');
                try buf.appendSlice(alloc, param_text);
                try buf.append(alloc, '"');
            }
        }
    }
    try buf.append(alloc, ']');

    // sourcePath
    try buf.appendSlice(alloc, ",\"sourcePath\":\"");
    try appendJsonEscaped(&buf, alloc, func.source_path);
    try buf.append(alloc, '"');

    // flags
    try buf.appendSlice(alloc, ",\"flags\":{\"async\":");
    try buf.appendSlice(alloc, if (func.flags & 0x01 != 0) "true" else "false");
    try buf.appendSlice(alloc, ",\"generator\":");
    try buf.appendSlice(alloc, if (func.flags & 0x02 != 0) "true" else "false");
    try buf.append(alloc, '}');

    // bodyText: 소스 원본에서 추출
    try buf.appendSlice(alloc, ",\"bodyText\":");
    {
        const body_node = api.transformer.ast.getNode(func.body_idx);
        if (body_node.span.start < body_node.span.end and
            body_node.span.start & 0x8000_0000 == 0 and
            body_node.span.end <= @as(u32, @intCast(api.transformer.ast.source.len)))
        {
            const text = api.transformer.ast.source[body_node.span.start..body_node.span.end];
            try buf.append(alloc, '"');
            try appendJsonEscaped(&buf, alloc, text);
            try buf.append(alloc, '"');
        } else {
            try buf.appendSlice(alloc, "\"\"");
        }
    }

    try buf.append(alloc, '}');
    return buf.toOwnedSlice(alloc);
}

// ─── build() 비동기 (Promise) ───
