const plugin_mod = @import("../plugin.zig");
const runtime_helper_modules = @import("../../runtime_helper_modules.zig");

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

pub fn shouldRunResolveId(self: anytype, specifier: []const u8) bool {
    return self.has_user_resolve_id_plugins or runtime_helper_modules.isVirtualId(specifier);
}

pub fn shouldRunLoad(self: anytype, path: []const u8) bool {
    return self.has_user_load_plugins or runtime_helper_modules.isVirtualId(path);
}
