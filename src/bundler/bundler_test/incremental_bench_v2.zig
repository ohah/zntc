//! Production-realistic measurement: React-style 컴포넌트 fixture + cold/warm rebuild.
//! module_store 로 cache hit 률 + parse/semantic phase ns 측정.

const std = @import("std");
const Bundler = @import("../bundler.zig").Bundler;
const ModuleGraph = @import("../graph.zig").ModuleGraph;
const PersistentModuleStore = @import("../module_store.zig").PersistentModuleStore;
const ResolveCache = @import("../resolve_cache.zig").ResolveCache;
const test_helpers = @import("../test_helpers.zig");
const writeFile = test_helpers.writeFile;
const absPath = test_helpers.absPath;
const profile = @import("../../profile.zig");

test "incremental bench: react-style 10 components, cache hit on no-change" {
    profile.resetForTest();
    profile.setLevel(.summary);
    profile.addCategories(&.{
        "parse",
        "semantic",
        "graph_discover",
        "graph_discover_incr_mtime",
        "graph_discover_incr_cache_lookup",
        "graph_discover_incr_cache_hit_assign",
        "graph_discover_incr_replay",
    });

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // 10 React-style components + index entry
    try writeFile(tmp.dir, "Button.tsx", "import { Card } from './Card';\nexport function Button(p: {label: string}) { return null as any; }\n");
    try writeFile(tmp.dir, "Card.tsx", "export function Card(p: {title: string}) { return null as any; }\n");
    try writeFile(tmp.dir, "Header.tsx", "import { Button } from './Button';\nexport function Header() { return null as any; }\n");
    try writeFile(tmp.dir, "Footer.tsx", "import { Card } from './Card';\nexport function Footer() { return null as any; }\n");
    try writeFile(tmp.dir, "Sidebar.tsx", "import { Button } from './Button';\nimport { Card } from './Card';\nexport function Sidebar() { return null as any; }\n");
    try writeFile(tmp.dir, "Modal.tsx", "import { Card } from './Card';\nexport function Modal() { return null as any; }\n");
    try writeFile(tmp.dir, "Form.tsx", "import { Button } from './Button';\nexport function Form() { return null as any; }\n");
    try writeFile(tmp.dir, "Table.tsx", "import { Card } from './Card';\nexport function Table() { return null as any; }\n");
    try writeFile(tmp.dir, "Layout.tsx", "import { Header } from './Header';\nimport { Sidebar } from './Sidebar';\nimport { Footer } from './Footer';\nexport function Layout() { return null as any; }\n");
    try writeFile(tmp.dir, "App.tsx", "import { Layout } from './Layout';\nimport { Modal } from './Modal';\nimport { Form } from './Form';\nimport { Table } from './Table';\nexport function App() { return null as any; }\n");
    try writeFile(tmp.dir, "index.tsx", "import { App } from './App';\nconsole.log(App);\n");

    const entry = try absPath(&tmp, "index.tsx");
    defer std.testing.allocator.free(entry);

    var store = PersistentModuleStore.init(std.testing.allocator);
    defer store.deinit();

    // ─── Cold build (store empty) ──────────────────────────────
    {
        var b = Bundler.init(std.testing.allocator, .{
            .entry_points = &.{entry},
            .module_store = &store,
        });
        defer b.deinit();
        const r = try b.bundle(std.testing.io);
        defer r.deinit(std.testing.allocator);
        try std.testing.expect(r.output.len > 0);
    }
    const cold_parse = profile.totalNs(.parse);
    const cold_semantic = profile.totalNs(.semantic);
    const cold_discover = profile.totalNs(.graph_discover);
    const cold_total = cold_parse + cold_semantic + cold_discover;

    profile.resetCounters();

    // ─── Warm build (no source change, store hit) ──────────────
    {
        var b = Bundler.init(std.testing.allocator, .{
            .entry_points = &.{entry},
            .module_store = &store,
        });
        defer b.deinit();
        const r = try b.bundle(std.testing.io);
        defer r.deinit(std.testing.allocator);
        try std.testing.expect(r.output.len > 0);
    }
    const warm_parse = profile.totalNs(.parse);
    const warm_semantic = profile.totalNs(.semantic);
    const warm_discover = profile.totalNs(.graph_discover);
    const warm_total = warm_parse + warm_semantic + warm_discover;

    const parse_savings_pct = if (cold_parse == 0) @as(u64, 0) else 100 - (warm_parse * 100 / cold_parse);
    const sem_savings_pct = if (cold_semantic == 0) @as(u64, 0) else 100 - (warm_semantic * 100 / cold_semantic);
    const total_savings_pct = if (cold_total == 0) @as(u64, 0) else 100 - (warm_total * 100 / cold_total);

    std.debug.print(
        \\
        \\[incremental-bench v2] React 10-component fixture, no-change warm:
        \\  cold:  parse={d}ns semantic={d}ns discover={d}ns total={d}ns
        \\  warm:  parse={d}ns semantic={d}ns discover={d}ns total={d}ns
        \\  savings: parse={d}% semantic={d}% total={d}%
        \\  parse+sem / total cold = {d}%
        \\
    , .{
        cold_parse,        cold_semantic,   cold_discover,     cold_total,
        warm_parse,        warm_semantic,   warm_discover,     warm_total,
        parse_savings_pct, sem_savings_pct, total_savings_pct, if (cold_total == 0) @as(u64, 0) else (cold_parse + cold_semantic) * 100 / cold_total,
    });

    const w_mtime = profile.totalNs(.graph_discover_incr_mtime);
    const w_cl = profile.totalNs(.graph_discover_incr_cache_lookup);
    const w_ha = profile.totalNs(.graph_discover_incr_cache_hit_assign);
    const w_rp = profile.totalNs(.graph_discover_incr_replay);
    std.debug.print(
        \\  warm sub-phase (ns, % of discover):
        \\    mtime           = {d}ns ({d}%)
        \\    cache_lookup    = {d}ns ({d}%)
        \\    cache_hit_assign= {d}ns ({d}%)
        \\    replay          = {d}ns ({d}%)
        \\
    , .{
        w_mtime, if (warm_discover == 0) @as(u64, 0) else w_mtime * 100 / warm_discover,
        w_cl,    if (warm_discover == 0) @as(u64, 0) else w_cl * 100 / warm_discover,
        w_ha,    if (warm_discover == 0) @as(u64, 0) else w_ha * 100 / warm_discover,
        w_rp,    if (warm_discover == 0) @as(u64, 0) else w_rp * 100 / warm_discover,
    });
}
