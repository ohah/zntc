//! require.context expansion helpers for ModuleGraph.

const std = @import("std");
const types = @import("../types.zig");
const plugin_mod = @import("../plugin.zig");
const graph_plugins = @import("plugins.zig");
const graph_mod = @import("../graph.zig");
const ModuleGraph = graph_mod.ModuleGraph;

/// require.context(...) 레코드의 매칭 파일 목록을 host plugin (resolveContext) 으로 채운다.
/// (#1579 Phase 2). ZNTC 자체 regex executor 가 없어서 host runtime 의 RegExp 위임 (#1771).
///
/// 처리 순서:
///   1. invalid record (`context_invalid_reason != null`) → require_context_invalid error.
///   2. plugin runner 호출 (first non-null wins) → 결과를 record.context_matches 에 저장.
///   3. plugin 미구현 → require_context_no_handler warning (record.context_matches 는 null 유지).
///
/// `self`: ModuleGraph (addDiag, plugins 접근용)
/// `module_path`: 현재 모듈 경로 (importer)
/// `records`: 모듈의 import_records (in-place 수정)
pub fn expandRecords(self: *ModuleGraph, mod_idx: usize) void {
    const module = self.modules.at(mod_idx);

    // scanWorker + resolveModuleImports 양쪽에서 호출됨. 이미 expand 됐으면 즉시 리턴
    // (has_any 루프보다 먼저 체크 — 재진입 시 records 전체 순회 회피).
    if (module.context_expansion_deps.len > 0) return;

    const records = module.import_records;
    var has_any = false;
    for (records) |r| {
        if (r.kind == .require_context) {
            has_any = true;
            break;
        }
    }
    if (!has_any) return;

    const module_path = module.path;
    const plugin_runner: ?plugin_mod.PluginRunner = graph_plugins.pluginRunnerWithBuiltins(self);

    // require.context 는 parse 산출물이라 arena 가 항상 존재. 없으면 (disabled/asset 등)
    // expand 자체가 의미 없고, graph allocator fallback 은 module.deinit 에서 free 누락 →
    // leak. 안전하게 early return.
    const arena = if (module.parse_arena) |a| a else return;
    const arena_alloc = arena.allocator();
    var expansion = std.ArrayList(types.ImportRecord).empty;

    for (records) |*record| {
        if (record.kind != .require_context) continue;
        if (record.context_matches != null) continue;

        // Invalid 인자 → diagnostic (Phase 1 의 reason 텍스트 그대로 사용). empty slice 로 마킹.
        if (record.context_invalid_reason) |reason| {
            self.addDiag(.require_context_invalid, .@"error", module_path, record.span, .resolve, reason, null);
            record.context_matches = &.{};
            continue;
        }

        // Plugin 호출
        if (plugin_runner) |runner| {
            var hook_ctx: plugin_mod.HookContext = .{};
            defer hook_ctx.deinit();
            const matches = runner.runResolveContext(
                record.specifier,
                record.context_recursive,
                record.context_filter,
                record.context_filter_flags,
                module_path,
                self.allocator,
                &hook_ctx,
            ) catch null;
            if (matches) |m| {
                record.context_matches = m;
                // 매치별 abs path resolve 결과를 record.context_resolved_paths 에 1:1 저장.
                // codegen 이 webpackContext IIFE 의 module wrapper 호출 (`__zntc_modules[<abs>]`) 에 사용.
                // null 슬롯 = resolve 실패 — codegen 이 throw stub 으로 emit.
                const source_dir = module.sourceDir();
                const resolved_paths_opt: ?[]?[]const u8 = arena_alloc.alloc(?[]const u8, m.len) catch null;
                for (m, 0..) |match_path, i| {
                    const joined = joinContextPath(arena_alloc, record.specifier, match_path) orelse {
                        if (resolved_paths_opt) |paths| paths[i] = null;
                        continue;
                    };
                    if (resolved_paths_opt) |paths| {
                        // default null — file variant 만 dupe 성공 시 덮어씀.
                        paths[i] = null;
                        if (self.resolve_cache.resolveThreadSafe(source_dir, joined, .require) catch null) |res| switch (res) {
                            // resolve_cache 가 self.allocator 로 path 할당 → arena 로 dupe 후 free.
                            .file => |f| {
                                paths[i] = arena_alloc.dupe(u8, f.path) catch null;
                                self.allocator.free(f.path);
                                if (f.resolve_dir) |dir| self.allocator.free(dir);
                            },
                            .disabled => |d| self.allocator.free(d.path),
                            .virtual, .dataurl, .external, .custom => {},
                        };
                    }
                    // graph dep 등록은 applyContextDepResults 에서 (cache hit 라 빠름).
                    expansion.append(arena_alloc, .{
                        .specifier = joined,
                        .kind = .require,
                        .span = record.span,
                    }) catch {};
                }
                if (resolved_paths_opt) |paths| record.context_resolved_paths = paths;
                continue;
            }
        }

        // Plugin 미구현 → warning. empty slice 로 마킹 (Phase 3 codegen 이 빈 stub 으로 emit).
        self.addDiag(
            .require_context_no_handler,
            .warning,
            module_path,
            record.span,
            .resolve,
            "require.context requires a host plugin to match files (ZNTC regex executor not yet implemented — see #1771)",
            null,
        );
        record.context_matches = &.{};
    }

    module.context_expansion_deps = expansion.toOwnedSlice(arena_alloc) catch &.{};
}

/// record.specifier (e.g. "./app" 또는 "../foo") 와 match_path (e.g. "./a.tsx") 를 결합.
/// codegen 의 emitJoinedPath 와 동일 로직 — dir trailing `/`, match `./` prefix 정규화.
/// 결과는 모듈 resolver 가 일반 require 처럼 처리할 수 있는 specifier.
fn joinContextPath(alloc: std.mem.Allocator, dir: []const u8, match: []const u8) ?[]u8 {
    const dir_clean = if (dir.len > 0 and dir[dir.len - 1] == '/') dir[0 .. dir.len - 1] else dir;
    const match_clean = if (match.len >= 2 and match[0] == '.' and match[1] == '/') match[2..] else match;
    const out = alloc.alloc(u8, dir_clean.len + 1 + match_clean.len) catch return null;
    @memcpy(out[0..dir_clean.len], dir_clean);
    out[dir_clean.len] = '/';
    @memcpy(out[dir_clean.len + 1 ..], match_clean);
    return out;
}
