const std = @import("std");
const debug_log = @import("../../debug_log.zig");
const runtime_polyfills = @import("../runtime_polyfills.zig");

pub fn selectModule(
    allocator: std.mem.Allocator,
    selected: *std.ArrayList(runtime_polyfills.ResolvedModule),
    seen: *std.StringHashMap(void),
    plan: runtime_polyfills.Plan,
    module: runtime_polyfills.ResolvedModule,
    reason: []const u8,
) !void {
    if (isExcluded(plan, module.module)) {
        if (debug_log.enabled(.runtime_polyfills)) {
            debug_log.print(
                .runtime_polyfills,
                "mode={s} feature={s} corejs_module={s} decision=excluded\n",
                .{ @tagName(plan.mode), reason, module.module },
            );
        }
        return;
    }
    if (seen.contains(module.module)) return;
    try seen.put(module.module, {});
    try selected.append(allocator, module);
    if (debug_log.enabled(.runtime_polyfills)) {
        debug_log.print(
            .runtime_polyfills,
            "mode={s} feature={s} corejs_module={s} module={s} decision=included\n",
            .{ @tagName(plan.mode), reason, module.module, module.path },
        );
    }
}

pub fn logUsage(module_path: []const u8, usage: runtime_polyfills.FeatureSet) void {
    if (!debug_log.enabled(.runtime_polyfills)) return;
    var it = usage.keyIterator();
    while (it.next()) |feature| {
        debug_log.print(
            .runtime_polyfills,
            "mode=usage module={s} feature={s} decision=detected\n",
            .{ module_path, feature.* },
        );
    }
}

pub fn logUnusedCandidate(candidate: runtime_polyfills.Candidate) void {
    if (!debug_log.enabled(.runtime_polyfills)) return;
    debug_log.print(
        .runtime_polyfills,
        "mode=usage feature={s} corejs_module={s} decision=unused\n",
        .{ candidate.feature, candidate.module },
    );
}

pub fn logPrelude(plan: runtime_polyfills.Plan, module: runtime_polyfills.ResolvedModule) void {
    if (!debug_log.enabled(.runtime_polyfills)) return;
    debug_log.print(
        .runtime_polyfills,
        "mode={s} corejs_module={s} module={s} decision=prelude\n",
        .{ @tagName(plan.mode), module.module, module.path },
    );
}

fn isExcluded(plan: runtime_polyfills.Plan, module_name: []const u8) bool {
    for (plan.exclude) |excluded| {
        if (std.mem.eql(u8, excluded, module_name)) return true;
    }
    return false;
}
