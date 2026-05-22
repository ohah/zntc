const std = @import("std");
const types = @import("../types.zig");
const ModuleType = types.ModuleType;
const module_mod = @import("../module.zig");
const Module = module_mod.Module;
const Span = @import("../../lexer/token.zig").Span;
const plugin_mod = @import("../plugin.zig");
const runtime_helper_modules = @import("../../runtime_helper_modules.zig");
const graph_assets = @import("assets.zig");
const graph_diagnostics = @import("diagnostics.zig");
const graph_parse_helpers = @import("parse_helpers.zig");
const assetSourceFromBytes = graph_assets.sourceFromBytes;
const moduleTypeForLoader = graph_parse_helpers.moduleTypeForLoader;

pub const LoadHookResult = enum {
    skipped,
    applied,
    done,
};

pub const TransformHookResult = enum {
    skipped,
    applied,
    done,
};

/// `plugins_with_helpers` lazy init: prepend ZNTC builtin plugins such as runtime
/// helper modules and RN codegen before user plugins.
pub fn ensureBuiltinPlugins(self: anytype) void {
    if (self.plugins_with_helpers != null) return;
    self.has_user_resolve_id_plugins = false;
    self.has_user_load_plugins = false;
    self.has_transform_plugins = self.codegen_transform;
    for (self.plugins) |p| {
        if (p.resolveId != null) self.has_user_resolve_id_plugins = true;
        if (p.load != null) self.has_user_load_plugins = true;
        if (p.transform != null) self.has_transform_plugins = true;
    }

    const u = self.transform_options_base.unsupported;
    self.helper_plugin_opts = .{
        .minify = self.transform_options_base.minify_whitespace,
        .es5 = u.async_await or u.arrow,
        // React Native-like configurable exports are not graph-level yet.
        .configurable_exports = false,
    };
    const helper = runtime_helper_modules.makePlugin(&self.helper_plugin_opts);

    var builtin_count: usize = 1;
    if (self.codegen_transform) builtin_count += 1;

    const merged = self.allocator.alloc(plugin_mod.Plugin, self.plugins.len + builtin_count) catch return;
    var i: usize = 0;
    merged[i] = helper;
    i += 1;
    if (self.codegen_transform) {
        const codegen_plugin = @import("../../transformer/plugins/rn_codegen_plugin.zig");
        merged[i] = codegen_plugin.plugin();
        i += 1;
    }
    @memcpy(merged[i..], self.plugins);
    self.plugins_with_helpers = merged;
}

pub fn pluginRunnerWithBuiltins(self: anytype) ?plugin_mod.PluginRunner {
    const list = self.plugins_with_helpers orelse self.plugins;
    if (list.len == 0) return null;
    return plugin_mod.PluginRunner.init(list);
}

/// esbuild/Rollup 관례: NUL byte prefix 또는 query (`?` 포함) 가 있는 ID 는
/// plugin 이 직접 처리할 가상 모듈. user plugin 등록 없이도 hook 을 거치게 해
/// runtime_helper_modules 외 plugin (예: vue/svelte SFC) 의 가상 ID 도 인식한다.
/// NAPI bridge (plugin_bridge.zig) 가 resolveId 결과 wrap 시점에 같은 술어를
/// 사용하므로 single source of truth 로 두기 위해 `pub` 으로 export.
pub fn isPluginVirtualId(id: []const u8) bool {
    if (id.len == 0) return false;
    if (id[0] == '\x00') return true;
    return std.mem.indexOfScalar(u8, id, '?') != null;
}

pub fn shouldRunResolveId(self: anytype, specifier: []const u8) bool {
    return self.has_user_resolve_id_plugins or runtime_helper_modules.isVirtualId(specifier) or isPluginVirtualId(specifier);
}

pub fn shouldRunLoad(self: anytype, path: []const u8) bool {
    return self.has_user_load_plugins or runtime_helper_modules.isVirtualId(path) or isPluginVirtualId(path);
}

pub fn runLoadForModule(self: anytype, module: *Module, runner: ?plugin_mod.PluginRunner) LoadHookResult {
    const plugin_runner = runner orelse return .skipped;
    if (!shouldRunLoad(self, module.path)) return .skipped;

    // load 결과를 실제 모듈 소스로 채택하기 전까지는 임시 arena가 소유한다.
    const tmp_arena = module_mod.createParseArena(self.allocator) orelse {
        module.state = .ready;
        return .done;
    };
    var hook_ctx: plugin_mod.HookContext = .{};
    const load_result = plugin_runner.runLoad(module.path, tmp_arena.allocator(), &hook_ctx) catch |err| switch (err) {
        error.PluginFailed => {
            graph_diagnostics.addPluginFailureDiag(self, hook_ctx.failure, module.path, Span.EMPTY, .resolve);
            module_mod.destroyParseArena(self.allocator, tmp_arena);
            module.state = .ready;
            return .done;
        },
        error.OutOfMemory => {
            module_mod.destroyParseArena(self.allocator, tmp_arena);
            module.state = .ready;
            return .done;
        },
    };

    if (load_result) |plugin_result| {
        module.parse_arena = tmp_arena;
        const arena_alloc = tmp_arena.allocator();
        const load_source_maps = hook_ctx.source_maps orelse &.{};
        if (load_source_maps.len > 0) {
            if (!graph_diagnostics.validatePluginSourceMaps(self, load_source_maps, module.path, Span.EMPTY, .transform, "load")) {
                module_mod.destroyParseArena(self.allocator, tmp_arena);
                module.parse_arena = null;
                module.state = .ready;
                return .done;
            }
            module.plugin_source_maps = load_source_maps;
        }

        // plugin 이 부여한 meta (JSON 문자열) 를 모듈에 귀속 (#1880 PR2).
        // plugin_result.meta 는 pluginLoad 가 parse_arena(tmp_arena) 로 dupe 했으므로 그대로 borrow.
        if (plugin_result.meta) |m| module.plugin_meta = m;

        if (plugin_result.loader) |loader_override| {
            module.loader = loader_override;
            module.module_type = plugin_result.module_type orelse
                moduleTypeForLoader(ModuleType.fromExtension(std.fs.path.extension(module.path)), loader_override);
            if (assetSourceFromBytes(arena_alloc, loader_override, plugin_result.contents, module.path, self.transform_options_base.minify_whitespace)) |expr| {
                module.source = expr;
                module.module_type = .js;
                module.exports_kind = .commonjs;
                module.wrap_kind = .cjs;
                module.side_effects = false;
                module.state = .ready;
                return .done;
            }
            // 여기서 값 표현식으로 낮출 수 없는 loader는 JS 파이프라인으로 계속 진행한다.
            module.source = plugin_result.contents;
        } else {
            // plugin contract: load 가 loader 명시 안 하면 contents 는 JS 로 가정.
            // 기본은 `.javascript` + `.js` 로 강제 (esbuild / rolldown 동일 — #3024 회귀
            // 해소). 다만 plugin 가상 ID (NUL prefix 또는 query 포함) 의 경우 addModule
            // 의 `loaderExtensionFor` 가 이미 SFC sub-import 의 `lang.X` query 로
            // `.css/.ts` 등을 결정해뒀고, 그게 plugin 이 반환한 실제 컨텐츠 확장자다 — 그
            // 때만 module 의 loader/module_type 을 유지한다 (#3022). `isPluginVirtualId`
            // 는 같은 파일의 single source of truth.
            const is_virtual_id = isPluginVirtualId(module.path);
            const has_explicit_non_js_loader = module.loader != .javascript and module.loader != .none;
            const is_typescript_module_type = module.module_type == .ts or module.module_type == .tsx;
            const keep_module_typing = is_virtual_id and
                (has_explicit_non_js_loader or
                    (module.loader == .javascript and is_typescript_module_type));
            if (!keep_module_typing) {
                module.loader = .javascript;
                module.module_type = .js;
            }
            module.source = plugin_result.contents;
        }
        return .applied;
    }

    module_mod.destroyParseArena(self.allocator, tmp_arena);
    return .skipped;
}

pub fn runTransformForModule(
    self: anytype,
    module: *Module,
    arena_alloc: std.mem.Allocator,
    runner: ?plugin_mod.PluginRunner,
) TransformHookResult {
    const plugin_runner = runner orelse return .skipped;
    if (!self.has_transform_plugins) return .skipped;

    // this.getModuleInfo (PR3 self-only): graph 대신 현재 모듈 포인터만 전달.
    // graph 조회를 하지 않으므로 discovery 병렬 단계의 race 가 없다. self 모듈의 path/source/
    // plugin_meta 는 worker 가 load 단계에서 이미 확정해 안전하게 읽을 수 있다.
    var hook_ctx: plugin_mod.HookContext = .{ .current_module = @ptrCast(module) };
    const transform_result = plugin_runner.runTransform(module.source, module.path, arena_alloc, &hook_ctx) catch |err| switch (err) {
        error.PluginFailed => {
            graph_diagnostics.addPluginFailureDiag(self, hook_ctx.failure, module.path, Span.EMPTY, .transform);
            module.state = .ready;
            return .done;
        },
        error.OutOfMemory => {
            module.state = .ready;
            return .done;
        },
    };
    if (transform_result) |result| {
        if (hook_ctx.source_maps) |maps| {
            if (!graph_diagnostics.validatePluginSourceMaps(self, maps, module.path, Span.EMPTY, .transform, "transform")) {
                module.state = .ready;
                return .done;
            }
            if (module.plugin_source_maps.len > 0) {
                module.plugin_source_maps = std.mem.concat(arena_alloc, []const u8, &.{
                    module.plugin_source_maps,
                    maps,
                }) catch {
                    module.state = .ready;
                    return .done;
                };
            } else {
                module.plugin_source_maps = maps;
            }
        }
        module.source = result;
        return .applied;
    }
    return .skipped;
}
