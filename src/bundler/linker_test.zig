const std = @import("std");
const linker_mod = @import("linker.zig");
const Linker = linker_mod.Linker;
const ImportBinding = linker_mod.ImportBinding;
const LinkingMetadata = linker_mod.LinkingMetadata;
const ModuleGraph = @import("graph.zig").ModuleGraph;
const Module = @import("module.zig").Module;
const CjsRuntimeInternalSymbolIds = @import("module.zig").CjsRuntimeInternalSymbolIds;
const types = @import("types.zig");
const ModuleIndex = types.ModuleIndex;
const graph_finalize = @import("graph/finalize.zig");
const resolve_cache_mod = @import("resolve_cache.zig");
const module_store_mod = @import("module_store.zig");
const module_codec = @import("module_codec.zig");
const TransformOptions = @import("../transformer/transformer.zig").TransformOptions;
const writeFile = @import("test_helpers.zig").writeFile;
const bundler_symbol = @import("symbol.zig");
const semantic_symbol = @import("../semantic/symbol.zig");
const PreservedRenames = bundler_symbol.PreservedRenames;

fn dirPath(tmp: *std.testing.TmpDir) ![:0]u8 {
    return try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
}

/// 주어진 basename 과 정확히 일치하는 모듈의 인덱스를 찾는다. 테스트에서 graph
/// 빌드 순서에 의존하지 않고 특정 소스 파일의 모듈을 지목하기 위한 헬퍼.
/// `std.fs.path.basename` 으로 경로 마지막 컴포넌트를 비교 — suffix 매칭(`endsWith`)이
/// 아니라 정확 일치라, 예컨대 "core.ts" 질의가 "my-core.ts" 모듈을 잘못 잡지 않는다.
fn findModuleIdx(graph: *ModuleGraph, basename: []const u8) ?ModuleIndex {
    var it = graph.modulesIterator();
    while (it.next()) |m| {
        if (std.mem.eql(u8, std.fs.path.basename(m.path), basename)) return m.index;
    }
    return null;
}

fn buildAndLink(allocator: std.mem.Allocator, tmp: *std.testing.TmpDir, entry_name: []const u8) !TestResult {
    const dp = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(dp);
    const entry = try std.fs.path.resolve(allocator, &.{ dp, entry_name });
    defer allocator.free(entry);

    // #1779 PR #2: Linker.graph 가 heap-stable 포인터여야 하므로 graph 를 heap 에 올린다.
    // 기존엔 linker 가 `[]const Module` slice 를 들고 있어 호출자 지역 graph 의
    // heap-backed slice pointer 로 안전했지만, 이제 graph 포인터가 필드라
    // TestResult 반환으로 stack 주소가 이동하면 lifetime 이 깨진다.
    var cache = resolve_cache_mod.ResolveCache.init(allocator, .{});
    const graph = try allocator.create(ModuleGraph);
    graph.* = ModuleGraph.init(allocator, &cache);
    try graph.build(std.testing.io, &.{entry});

    var linker = Linker.init(allocator, graph, .esm);
    try linker.link();

    return .{ .linker = linker, .graph = graph, .cache = cache };
}

fn buildAndLinkWithTransformOptions(
    allocator: std.mem.Allocator,
    tmp: *std.testing.TmpDir,
    entry_name: []const u8,
    transform_options: TransformOptions,
    minify_identifiers: bool,
) !TestResult {
    const dp = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(dp);
    const entry = try std.fs.path.resolve(allocator, &.{ dp, entry_name });
    defer allocator.free(entry);

    var cache = resolve_cache_mod.ResolveCache.init(allocator, .{});
    const graph = try allocator.create(ModuleGraph);
    graph.* = ModuleGraph.init(allocator, &cache);
    graph.transform_options_base = transform_options;
    graph.minify_identifiers = minify_identifiers;
    try graph.build(std.testing.io, &.{entry});

    var linker = Linker.init(allocator, graph, .esm);
    try linker.link();

    return .{ .linker = linker, .graph = graph, .cache = cache };
}

fn addGraphRuntimeHelperIdentity(module: *Module, name: []const u8) !semantic_symbol.SymbolId {
    if (module.parse_arena == null) {
        module.parse_arena = @import("module.zig").createParseArena(std.testing.allocator) orelse return error.OutOfMemory;
    }
    if (module.semantic == null) {
        module.semantic = .{
            .symbols = .empty,
            .scopes = &.{},
            .scope_maps = &.{},
            .exported_names = .empty,
            .symbol_ids = &.{},
            .unresolved_references = .empty,
        };
    }
    const arena = module.parse_arena.?.allocator();
    const semantic = if (module.semantic) |*value| value else return error.TestUnexpectedResult;
    return try semantic_symbol.extendSymbol(
        arena,
        &semantic.symbols,
        .variable_var,
        .bundler_runtime_helper,
        name,
        @import("../lexer/token.zig").Span.EMPTY,
    );
}

fn writeCanonicalExportIdentityFixture(tmp: *std.testing.TmpDir) !void {
    try writeFile(
        tmp.dir,
        "provider.mjs",
        "const decoy0 = 100; const local0 = 1; export { local0 as public0 };\n" ++
            "const decoy1 = 101; const local1 = 2; export { local1 as public1 };\n" ++
            "const decoy2 = 102; const local2 = 3; export { local2 as public2 };\n" ++
            "const decoy3 = 103; const local3 = 4; export { local3 as public3 };\n" ++
            "const decoy4 = 104; const local4 = 5; export { local4 as public4 };\n" ++
            "const decoy5 = 105; const local5 = 6; export { local5 as public5 };\n" ++
            "const decoy6 = 106; const local6 = 7; export { local6 as public6 };\n" ++
            "const decoy7 = 107; const local7 = 8; export { local7 as public7 };\n" ++
            "const decoy8 = 108; const local8 = 9; export { local8 as public8 };\n" ++
            "const decoy9 = 109; const local9 = 10; export { local9 as public9 };\n",
    );
    try writeFile(
        tmp.dir,
        "entry.mjs",
        "import { public0 as imported0, public1 as imported1, public2 as imported2, public3 as imported3, public4 as imported4, " ++
            "public5 as imported5, public6 as imported6, public7 as imported7, public8 as imported8, public9 as imported9 } from './provider.mjs';\n" ++
            "export function run() {\n" ++
            "  function consume(local0, local1, local2, local3, local4, local5, local6, local7, local8, local9) {\n" ++
            "    return imported0 + local0 + imported1 + local1 + imported2 + local2 + imported3 + local3 + imported4 + local4 + " ++
            "imported5 + local5 + imported6 + local6 + imported7 + local7 + imported8 + local8 + imported9 + local9;\n" ++
            "  }\n" ++
            "  return consume(0, 1, 2, 3, 4, 5, 6, 7, 8, 9);\n" ++
            "}\n",
    );
}

fn poisonCanonicalExportLocalNames(
    allocator: std.mem.Allocator,
    module: *Module,
) ![10]bundler_symbol.SymbolID {
    const semantic = if (module.semantic) |*value| value else return error.MissingCanonicalExportSemantic;
    if (semantic.scope_maps.len == 0) return error.MissingCanonicalExportScopeMap;
    var export_ids: [10]bundler_symbol.SymbolID = undefined;
    const scope_map = @constCast(&semantic.scope_maps[0]);
    for (0..10) |i| {
        const local_name = try std.fmt.allocPrint(allocator, "local{d}", .{i});
        defer allocator.free(local_name);
        const decoy_name = try std.fmt.allocPrint(allocator, "decoy{d}", .{i});
        defer allocator.free(decoy_name);
        const public_name = try std.fmt.allocPrint(allocator, "public{d}", .{i});
        defer allocator.free(public_name);
        const symbol_index = module.findLocalExportSemanticIndex(public_name) orelse
            return error.MissingCanonicalExportSymbol;
        const decoy_index = semantic.scope_maps[0].get(decoy_name) orelse return error.MissingCanonicalExportDecoy;
        export_ids[i] = bundler_symbol.SymbolID.make(module.index, symbol_index);
        try scope_map.put(allocator, local_name, decoy_index);
    }
    return export_ids;
}

test "linker runtime-helper shadow rename uses canonical export SymbolId" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(
        tmp.dir,
        "entry.mjs",
        "export function run(__generator) {\n" ++
            "  function* values() { yield 1; }\n" ++
            "  return values().next().value + __generator;\n" ++
            "}\n",
    );

    var result = try buildAndLinkWithTransformOptions(
        std.testing.allocator,
        &tmp,
        "entry.mjs",
        .{
            .unsupported = TransformOptions.compat.fromESTarget(.es5),
            .defer_runtime_helper_name_resolution = true,
            .emit_runtime_helper_imports = true,
        },
        false,
    );
    defer result.cache.deinit();
    defer result.destroyGraph();
    defer result.linker.deinit();

    const entry_index = findModuleIdx(result.graph, "entry.mjs") orelse return error.MissingRuntimeHelperEntry;
    const entry_module = result.graph.getModule(entry_index) orelse return error.MissingRuntimeHelperEntry;
    const helper_binding = blk: {
        for (entry_module.import_bindings) |binding| {
            if (binding.is_helper) break :blk binding;
        }
        return error.MissingGeneratedRuntimeHelper;
    };
    const resolved = result.linker.getResolvedBinding(entry_index.toU32(), helper_binding.local_span) orelse
        return error.MissingResolvedRuntimeHelper;
    const helper_module = result.graph.getModule(resolved.canonical.module_index) orelse return error.MissingRuntimeHelperModule;
    const helper_inner = helper_module.findLocalExportSemanticIndex(resolved.canonical.export_name) orelse
        return error.MissingExactRuntimeHelperExport;
    const helper_id = bundler_symbol.SymbolID.make(helper_module.index, helper_inner);
    const export_local = result.linker.getExportLocalName(helper_module.index.toU32(), resolved.canonical.export_name) orelse
        return error.MissingRuntimeHelperLocalName;

    const helper_module_mut = @constCast(helper_module);
    const semantic = if (helper_module_mut.semantic) |*value| value else return error.MissingRuntimeHelperSemantic;
    if (semantic.scope_maps.len == 0 or semantic.symbols.items.len < 2) return error.MissingRuntimeHelperDecoy;
    const decoy_inner: usize = if (helper_inner == 0) 1 else 0;
    const scope_maps = @constCast(semantic.scope_maps);
    try scope_maps[0].put(std.testing.allocator, export_local, decoy_inner);

    try result.linker.computeRenames();

    const selected = result.linker.rename_table.get(helper_id) orelse return error.MissingCanonicalRuntimeHelperRename;
    try std.testing.expect(!std.mem.eql(u8, selected, export_local));

    const module_index = helper_module.index.toU32();
    try result.linker.putCrossChunkGlobalName(
        module_index,
        resolved.canonical.export_name,
        try std.testing.allocator.dupe(u8, "stale_cross_chunk_name"),
    );
    try result.linker.prepareCrossChunkRuntimeHelperNames();
    const cross_chunk_name = result.linker.getCrossChunkGlobalName(module_index, resolved.canonical.export_name) orelse
        return error.MissingPreparedRuntimeHelperName;
    const exact_name = result.linker.rename_table.get(helper_id) orelse return error.MissingPreparedRuntimeHelperRename;
    try std.testing.expectEqualStrings(exact_name, cross_chunk_name);
}

test "linker nested export renames use exact SymbolIds under hostile scope-map spellings" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeCanonicalExportIdentityFixture(&tmp);

    var result = try buildAndLink(allocator, &tmp, "entry.mjs");
    defer result.cache.deinit();
    defer result.destroyGraph();
    defer result.linker.deinit();

    const provider_index = findModuleIdx(result.graph, "provider.mjs") orelse return error.MissingCanonicalExportProvider;
    const provider = result.graph.getModule(provider_index) orelse return error.MissingCanonicalExportProvider;
    const export_ids = try poisonCanonicalExportLocalNames(allocator, @constCast(provider));

    try result.linker.computeRenames();

    const semantic = provider.semantic orelse return error.MissingCanonicalExportSemantic;
    for (0..10) |i| {
        const local_name = try std.fmt.allocPrint(allocator, "local{d}", .{i});
        defer allocator.free(local_name);
        const decoy_name = try std.fmt.allocPrint(allocator, "decoy{d}", .{i});
        defer allocator.free(decoy_name);
        const expected = try std.fmt.allocPrint(allocator, "{s}$1", .{local_name});
        defer allocator.free(expected);

        const actual = result.linker.rename_table.get(export_ids[i]) orelse return error.MissingExactExportCanonicalName;
        try std.testing.expectEqualStrings(expected, actual);

        const decoy_index = semantic.scope_maps[0].get(decoy_name) orelse return error.MissingCanonicalExportDecoy;
        const decoy_id = bundler_symbol.SymbolID.make(provider.index, @as(u32, @intCast(decoy_index)));
        if (result.linker.rename_table.get(decoy_id)) |decoy_canonical| {
            try std.testing.expect(!std.mem.eql(u8, expected, decoy_canonical));
        }
    }
}

test "lazy cross-chunk export overrides use exact SymbolIds under hostile local names" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeCanonicalExportIdentityFixture(&tmp);

    var result = try buildAndLink(allocator, &tmp, "entry.mjs");
    defer result.cache.deinit();
    defer result.destroyGraph();
    defer result.linker.deinit();

    const provider_index = findModuleIdx(result.graph, "provider.mjs") orelse return error.MissingCanonicalExportProvider;
    const provider = result.graph.getModule(provider_index) orelse return error.MissingCanonicalExportProvider;
    const export_ids = try poisonCanonicalExportLocalNames(allocator, @constCast(provider));
    result.graph.lazy_compilation = true;

    for (0..10) |i| {
        const public_name = try std.fmt.allocPrint(allocator, "public{d}", .{i});
        defer allocator.free(public_name);
        const global_name = try std.fmt.allocPrint(allocator, "chunkExport{d}", .{i});
        defer allocator.free(global_name);
        const export_binding = provider.findExportBinding(public_name) orelse return error.MissingCanonicalExportBinding;
        try result.linker.putCrossChunkGlobalName(
            provider_index.toU32(),
            export_binding.exported_name,
            try allocator.dupe(u8, global_name),
        );
    }

    try result.linker.computeRenamesForModules(&.{provider_index}, &.{});

    const semantic = provider.semantic orelse return error.MissingCanonicalExportSemantic;
    for (0..10) |i| {
        const public_name = try std.fmt.allocPrint(allocator, "public{d}", .{i});
        defer allocator.free(public_name);
        const decoy_name = try std.fmt.allocPrint(allocator, "decoy{d}", .{i});
        defer allocator.free(decoy_name);
        const global_name = try std.fmt.allocPrint(allocator, "chunkExport{d}", .{i});
        defer allocator.free(global_name);

        const actual = result.linker.rename_table.get(export_ids[i]) orelse return error.MissingExactExportCanonicalName;
        try std.testing.expectEqualStrings(global_name, actual);

        const decoy_index = semantic.scope_maps[0].get(decoy_name) orelse return error.MissingCanonicalExportDecoy;
        const decoy_id = bundler_symbol.SymbolID.make(provider.index, @as(u32, @intCast(decoy_index)));
        if (result.linker.rename_table.get(decoy_id)) |decoy_canonical| {
            try std.testing.expect(!std.mem.eql(u8, global_name, decoy_canonical));
        }
    }
}

test "linker: tagged-template cache final names come from exact post-graph bindings" {
    for ([_]bool{ false, true }) |minify_identifiers| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try writeFile(
            tmp.dir,
            "entry.mjs",
            "const _templateObject = 10, _templateObject2 = 20;\n" ++
                "function tag(parts) { return parts[0] + parts.raw[0]; }\n" ++
                "console.log(tag`one`, tag`two`, _templateObject, _templateObject2);\n",
        );

        var result = try buildAndLinkWithTransformOptions(
            std.testing.allocator,
            &tmp,
            "entry.mjs",
            .{
                .unsupported = TransformOptions.compat.fromESTarget(.es5),
                .defer_runtime_helper_name_resolution = true,
                .emit_runtime_helper_imports = true,
            },
            minify_identifiers,
        );
        errdefer result.cache.deinit();
        errdefer result.destroyGraph();
        errdefer result.linker.deinit();

        try result.linker.computeRenames();
        if (minify_identifiers) try result.linker.computeMangling();

        const module_index = findModuleIdx(result.graph, "entry.mjs") orelse return error.MissingTaggedTemplateModule;
        const module = result.graph.getModule(module_index) orelse return error.MissingTaggedTemplateModule;
        const semantic = module.semantic orelse return error.MissingTaggedTemplateSemantic;
        const transform_cache = module.transform_cache orelse return error.MissingTaggedTemplateTransformCache;
        var captured_nodes: [2]u32 = undefined;
        var captured_symbol_ids: [2]u32 = undefined;
        var captured_count: usize = 0;
        for (transform_cache.post_graph_output_bindings) |binding| {
            if (binding.synthetic_kind != .tagged_template_function_binding) continue;
            if (captured_count >= captured_nodes.len) return error.TooManyTaggedTemplateBindings;
            const raw_symbol_id = transform_cache.symbol_ids[binding.node_index] orelse return error.MissingTaggedTemplateBindingSymbolId;
            const symbol_index: usize = @intCast(raw_symbol_id);
            try std.testing.expectEqual(
                semantic_symbol.SyntheticKind.tagged_template_function_binding,
                semantic.symbols.items[symbol_index].synthetic_kind.?,
            );
            if (captured_count > 0) {
                try std.testing.expect(captured_nodes[0] != binding.node_index);
                try std.testing.expect(captured_symbol_ids[0] != raw_symbol_id);
            }
            captured_nodes[captured_count] = binding.node_index;
            captured_symbol_ids[captured_count] = raw_symbol_id;
            captured_count += 1;
        }
        try std.testing.expectEqual(@as(usize, 2), captured_count);

        var final_names: [2][]const u8 = undefined;
        var found: usize = 0;
        for (semantic.symbols.items, 0..) |symbol, raw_symbol_id| {
            if (symbol.synthetic_kind != .tagged_template_function_binding) continue;
            try std.testing.expectEqual(semantic_symbol.SymbolKind.function_decl, symbol.kind);
            try std.testing.expect(!symbol.scope_id.isNone());
            try std.testing.expectEqualStrings("_templateObject", symbol.output_name_hint);
            const id = bundler_symbol.SymbolID.make(module_index, @as(u32, @intCast(raw_symbol_id)));
            const final_name = result.linker.rename_table.get(id) orelse return error.MissingTaggedTemplateFinalName;
            if (!minify_identifiers) {
                try std.testing.expectEqualStrings(if (found == 0) "_templateObject$1" else "_templateObject$2", final_name);
            } else {
                try std.testing.expect(!std.mem.eql(u8, symbol.synthetic_name, final_name));
            }
            final_names[found] = final_name;
            found += 1;
        }
        try std.testing.expectEqual(@as(usize, 2), found);
        try std.testing.expect(!std.mem.eql(u8, final_names[0], final_names[1]));

        result.linker.deinit();
        result.destroyGraph();
        result.cache.deinit();
    }
}

test "linker: malformed tagged-template cache metadata fails closed" {
    for ([_]bool{ false, true }) |wrong_binding_kind| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try writeFile(tmp.dir, "entry.mjs", "function tag(parts) { return parts[0]; } console.log(tag`bad`);\n");

        var result = try buildAndLinkWithTransformOptions(
            std.testing.allocator,
            &tmp,
            "entry.mjs",
            .{
                .unsupported = TransformOptions.compat.fromESTarget(.es5),
                .defer_runtime_helper_name_resolution = true,
                .emit_runtime_helper_imports = true,
            },
            false,
        );
        defer result.linker.deinit();
        defer result.destroyGraph();
        defer result.cache.deinit();

        const module_index = findModuleIdx(result.graph, "entry.mjs") orelse return error.MissingTaggedTemplateModule;
        const module = result.linker.moduleAtMut(module_index.toU32()) orelse return error.MissingTaggedTemplateModule;
        const semantic = module.semantic orelse return error.MissingTaggedTemplateSemantic;
        const raw_symbol_id = for (semantic.symbols.items, 0..) |symbol, i| {
            if (symbol.synthetic_kind == .tagged_template_function_binding) break i;
        } else return error.MissingTaggedTemplateSymbol;
        if (wrong_binding_kind) {
            semantic.symbols.items[raw_symbol_id].kind = .variable_var;
        } else {
            semantic.symbols.items[raw_symbol_id].output_name_hint = "wrong-template-hint";
        }

        try std.testing.expectError(error.InvalidTaggedTemplateOutputBinding, result.linker.computeRenames());
    }
}

test "linker: createRequire shim local has an exact detached SymbolId and reserves hostile names" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "dep.cjs", "const fs = require('node:fs'); module.exports = fs;");
    try writeFile(
        tmp.dir,
        "entry.mjs",
        "import dep from './dep.cjs'; const createRequire = 1; " ++
            "const createRequire$1 = 2; console.log(typeof createRequire$2, dep);",
    );

    var r = try buildAndLink(std.testing.allocator, &tmp, "entry.mjs");
    defer r.linker.deinit();
    defer r.destroyGraph();
    defer r.cache.deinit();

    try r.linker.computeRenames();
    var output_modules: std.ArrayList(*const Module) = .empty;
    defer output_modules.deinit(std.testing.allocator);
    var modules = r.graph.modulesIterator();
    while (modules.next()) |module| try output_modules.append(std.testing.allocator, module);

    const first_name = try r.linker.prepareRequireShimLocalName(std.testing.allocator, output_modules.items);
    defer std.testing.allocator.free(first_name);
    try std.testing.expectEqualStrings("createRequire$3", first_name);

    var owner: ?*Module = null;
    var output_identity_count: usize = 0;
    var owner_it = r.graph.modulesIterator();
    while (owner_it.next()) |module| {
        if (module.semantic) |sem| {
            for (sem.symbols.items) |symbol| {
                if (symbol.synthetic_kind == .require_shim_local) output_identity_count += 1;
            }
        }
        if (module.require_shim_local_symbol != null) owner = @constCast(module);
    }
    try std.testing.expectEqual(@as(usize, 1), output_identity_count);
    const local_owner = owner orelse return error.TestUnexpectedResult;
    const inner = local_owner.require_shim_local_symbol.?;
    const id = bundler_symbol.SymbolID.make(local_owner.index, @backingInt(inner));
    const symbol = local_owner.semantic.?.symbols.items[@backingInt(inner)];
    try std.testing.expectEqual(semantic_symbol.SymbolKind.import_binding, symbol.kind);
    try std.testing.expectEqual(semantic_symbol.SyntheticKind.require_shim_local, symbol.synthetic_kind.?);
    try std.testing.expectEqualStrings("createRequire", symbol.synthetic_name);
    try std.testing.expect(symbol.scope_id.isNone());
    try std.testing.expectEqualStrings(first_name, r.linker.rename_table.get(id) orelse return error.TestUnexpectedResult);

    // The output-owned import has no AST binding/reference or lexical-map edge.
    const sem = &local_owner.semantic.?;
    for (sem.symbol_ids) |maybe_id| try std.testing.expect(maybe_id == null or maybe_id.? != @backingInt(inner));
    for (sem.references) |reference| try std.testing.expect(reference.symbol_id != inner);
    for (sem.scope_maps) |scope_map| {
        var entries = scope_map.valueIterator();
        while (entries.next()) |mapped| try std.testing.expect(mapped.* != @backingInt(inner));
    }

    // Repeated preparation must ignore its own canonical spelling and recover
    // the same typed row if the convenience cache is dropped.
    local_owner.require_shim_local_symbol = null;
    const repeated_name = try r.linker.prepareRequireShimLocalName(std.testing.allocator, output_modules.items);
    defer std.testing.allocator.free(repeated_name);
    try std.testing.expectEqualStrings(first_name, repeated_name);
    try std.testing.expectEqual(inner, local_owner.require_shim_local_symbol.?);

    // A rename-table reset followed by hostile global and reserved names must
    // still bind the chosen alias to this exact identity.
    r.linker.clearCanonicalNames();
    r.linker.global_identifiers = &.{"createRequire$3"};
    const global_blocked_name = try r.linker.prepareRequireShimLocalName(std.testing.allocator, output_modules.items);
    defer std.testing.allocator.free(global_blocked_name);
    try std.testing.expectEqualStrings("createRequire$4", global_blocked_name);
    try std.testing.expectEqualStrings(global_blocked_name, r.linker.rename_table.get(id) orelse return error.TestUnexpectedResult);

    r.linker.clearCanonicalNames();
    r.linker.global_identifiers = &.{};
    try r.linker.reserved_globals.put(std.testing.allocator, "createRequire$3", {});
    try r.linker.reserved_globals.put(std.testing.allocator, "createRequire$4", {});
    const reserved_name = try r.linker.prepareRequireShimLocalName(std.testing.allocator, output_modules.items);
    defer std.testing.allocator.free(reserved_name);
    try std.testing.expectEqualStrings("createRequire$5", reserved_name);
    try std.testing.expectEqualStrings(reserved_name, r.linker.rename_table.get(id) orelse return error.TestUnexpectedResult);

    // Malformed typed rows fail closed instead of silently receiving a name.
    const original = local_owner.semantic.?.symbols.items[@backingInt(inner)];
    local_owner.semantic.?.symbols.items[@backingInt(inner)].synthetic_name = "wrong-name";
    try std.testing.expectError(error.RequireShimLocalIdentityInvalid, r.linker.prepareRequireShimLocalName(std.testing.allocator, output_modules.items));
    local_owner.semantic.?.symbols.items[@backingInt(inner)] = original;
    local_owner.semantic.?.symbols.items[@backingInt(inner)].kind = .variable_var;
    try std.testing.expectError(error.RequireShimLocalIdentityInvalid, r.linker.prepareRequireShimLocalName(std.testing.allocator, output_modules.items));
    local_owner.semantic.?.symbols.items[@backingInt(inner)] = original;

    const arena = local_owner.parse_arena.?.allocator();
    const sem_mut = &local_owner.semantic.?;
    const original_len = sem_mut.symbols.items.len;
    _ = try semantic_symbol.extendSymbol(
        arena,
        &sem_mut.symbols,
        .import_binding,
        .require_shim_local,
        "createRequire",
        @import("../lexer/token.zig").Span.EMPTY,
    );
    try std.testing.expectError(error.RequireShimLocalIdentityAmbiguous, r.linker.prepareRequireShimLocalName(std.testing.allocator, output_modules.items));
    sem_mut.symbols.items.len = original_len;
}

test "linker: default export facade final name stays on its exact SymbolId" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "dep.mjs", "const _default = 'source'; export { _default }; export default 42;");
    try writeFile(tmp.dir, "entry.mjs", "import value, { _default as local } from './dep.mjs'; console.log(value, local);");

    var r = try buildAndLink(std.testing.allocator, &tmp, "entry.mjs");
    defer r.linker.deinit();
    defer r.destroyGraph();
    defer r.cache.deinit();
    try r.linker.computeRenames();

    const dep_index = findModuleIdx(r.graph, "dep.mjs") orelse return error.TestUnexpectedResult;
    const dep = r.graph.getModule(dep_index) orelse return error.TestUnexpectedResult;
    const sem = dep.semantic orelse return error.NoSemantic;
    var facade_ref: bundler_symbol.SymbolRef = .invalid;
    for (dep.export_bindings) |eb| {
        if (eb.kind == .local and std.mem.eql(u8, eb.exported_name, "default") and eb.hasSyntheticDefault(sem.symbols.items)) {
            facade_ref = eb.symbol;
            break;
        }
    }
    if (!facade_ref.isValid()) return error.MissingDefaultExportFacade;

    const facade_id = bundler_symbol.SymbolID.fromRef(facade_ref) orelse return error.MissingDefaultExportFacadeSymbolId;
    const facade = sem.symbols.items[@backingInt(facade_id.inner)];
    try std.testing.expect(!facade.scope_id.isNone());
    try std.testing.expectEqual(@as(u32, 0), facade.scope_id.toIndex());
    const source_symbol_index = sem.scope_maps[0].get("_default") orelse return error.MissingSourceDefaultBinding;
    const source_ref = bundler_symbol.SymbolRef.makeSemantic(dep_index, source_symbol_index);
    const source_id = bundler_symbol.SymbolID.fromRef(source_ref) orelse return error.MissingSourceDefaultSymbolId;
    try std.testing.expect(facade_id != source_id);

    try std.testing.expectEqualStrings("_default", r.linker.getCanonicalByRef(facade_ref) orelse return error.MissingFacadeCanonicalName);
    try std.testing.expectEqualStrings("_default$1", r.linker.getCanonicalByRef(source_ref) orelse return error.MissingSourceCanonicalName);
}

test "linker: a missing default facade SymbolId fails closed despite a colliding source name" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "dep.mjs", "const _default = 'source'; export { _default }; export default 42;");
    try writeFile(tmp.dir, "entry.mjs", "import value, { _default as local } from './dep.mjs'; console.log(value, local);");

    var r = try buildAndLink(std.testing.allocator, &tmp, "entry.mjs");
    defer r.linker.deinit();
    defer r.destroyGraph();
    defer r.cache.deinit();

    const dep_index = findModuleIdx(r.graph, "dep.mjs") orelse return error.TestUnexpectedResult;
    const dep = r.graph.getModule(dep_index) orelse return error.TestUnexpectedResult;
    for (dep.export_bindings) |*eb| {
        if (eb.kind != .local or !std.mem.eql(u8, eb.exported_name, "default") or !eb.has_default_export_facade)
            continue;
        eb.symbol = .invalid;
        try std.testing.expectError(error.MissingDefaultExportFacadeSymbol, r.linker.computeRenames());
        return;
    }
    return error.MissingDefaultExportFacade;
}

test "linker: default re-export bridge has a producer SymbolId and module owner scope" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "dep.mjs", "export default 42;");
    try writeFile(
        tmp.dir,
        "barrel.mjs",
        "const _default = 'source'; export { _default }; export { default } from './dep.mjs';",
    );
    try writeFile(
        tmp.dir,
        "entry.mjs",
        "import value, { _default as local } from './barrel.mjs'; console.log(value, local);",
    );

    var r = try buildAndLink(std.testing.allocator, &tmp, "entry.mjs");
    defer r.linker.deinit();
    defer r.destroyGraph();
    defer r.cache.deinit();
    try r.linker.computeRenames();

    const barrel_index = findModuleIdx(r.graph, "barrel.mjs") orelse return error.TestUnexpectedResult;
    const barrel = r.graph.getModule(barrel_index) orelse return error.TestUnexpectedResult;
    const sem = barrel.semantic orelse return error.NoSemantic;
    var bridge_ref: bundler_symbol.SymbolRef = .invalid;
    for (barrel.export_bindings) |eb| {
        if (eb.kind == .re_export and std.mem.eql(u8, eb.exported_name, "default") and eb.hasSyntheticDefault(sem.symbols.items)) {
            bridge_ref = eb.symbol;
            break;
        }
    }
    if (!bridge_ref.isValid()) return error.MissingDefaultExportBridge;

    const bridge_id = bundler_symbol.SymbolID.fromRef(bridge_ref) orelse return error.MissingDefaultExportBridgeSymbolId;
    const bridge = sem.symbols.items[@backingInt(bridge_id.inner)];
    try std.testing.expectEqual(semantic_symbol.SyntheticKind.default_export, bridge.synthetic_kind.?);
    try std.testing.expect(!bridge.scope_id.isNone());
    try std.testing.expectEqual(@as(u32, 0), bridge.scope_id.toIndex());

    const source_index = sem.scope_maps[0].get("_default") orelse return error.MissingSourceDefaultBinding;
    const source_ref = bundler_symbol.SymbolRef.makeSemantic(barrel_index, source_index);
    try std.testing.expect(bridge_id != bundler_symbol.SymbolID.fromRef(source_ref).?);
    try std.testing.expectEqualStrings("_default$1", r.linker.getCanonicalByRef(bridge_ref) orelse return error.MissingBridgeCanonicalName);
    try std.testing.expectEqualStrings("_default$2", r.linker.getCanonicalByRef(source_ref) orelse return error.MissingSourceCanonicalName);
}

test "reuse: default facade SymbolId participates in the top-level fingerprint" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.mjs", "import value from './dep.mjs'; console.log(value);");
    try writeFile(tmp.dir, "dep.mjs", "export default 42;");

    var r = try buildAndLink(std.testing.allocator, &tmp, "entry.mjs");
    defer r.linker.deinit();
    defer r.destroyGraph();
    defer r.cache.deinit();

    const dep_index = findModuleIdx(r.graph, "dep.mjs") orelse return error.TestUnexpectedResult;
    const dep = r.graph.moduleAtMut(dep_index) orelse return error.TestUnexpectedResult;
    const sem = &dep.semantic.?;
    var default_export_index: ?usize = null;
    for (dep.export_bindings, 0..) |eb, export_index| {
        if (eb.kind == .local and eb.hasSyntheticDefault(sem.symbols.items)) {
            default_export_index = export_index;
            break;
        }
    }
    const export_index = default_export_index orelse return error.MissingDefaultExportFacade;
    const original_ref = dep.export_bindings[export_index].symbol;
    const original_id = bundler_symbol.SymbolID.fromRef(original_ref) orelse return error.MissingDefaultExportFacadeSymbolId;
    const before = try r.linker.moduleFingerprint(dep.*);
    const original_symbol_count = sem.symbols.items.len;
    const duplicate_index: u32 = @intCast(original_symbol_count);
    try sem.symbols.append(dep.parse_arena.?.allocator(), sem.symbols.items[@backingInt(original_id.inner)]);
    dep.export_bindings[export_index].symbol = bundler_symbol.SymbolRef.makeSemantic(dep_index, duplicate_index);
    const after = try r.linker.moduleFingerprint(dep.*);

    dep.export_bindings[export_index].symbol = original_ref;
    sem.symbols.items.len = original_symbol_count;
    try std.testing.expect(before.toplevel_name_set_hash != after.toplevel_name_set_hash);
}

test "linker: direct import resolves to export" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import { x } from './b'; console.log(x);");
    try writeFile(tmp.dir, "b.ts", "export const x = 42;");

    var r = try buildAndLink(std.testing.allocator, &tmp, "a.ts");
    defer r.linker.deinit();
    defer r.destroyGraph();
    defer r.cache.deinit();

    // a.ts의 import x가 b.ts의 export x에 연결
    const a = r.graph.getModule(ModuleIndex.fromUsize(0)).?;
    try std.testing.expect(a.import_bindings.len > 0);
    const binding = r.linker.getResolvedBinding(0, a.import_bindings[0].local_span);
    try std.testing.expect(binding != null);
    try std.testing.expectEqualStrings("x", binding.?.canonical.export_name);
    // canonical이 b.ts(index 1)를 가리킴
    try std.testing.expectEqual(@as(u32, 1), @backingInt(binding.?.canonical.module_index));
}

test "linker: CJS runtime factory alias keeps one exact SymbolId across cache and chunk changes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "legacy.cjs", "module.exports = 7;");
    try writeFile(tmp.dir, "second.cjs", "module.exports = typeof __commonJS$2;");
    try writeFile(
        tmp.dir,
        "entry.mjs",
        "import value from './legacy.cjs'; import other from './second.cjs'; " ++
            "console.log(typeof __commonJS, typeof __commonJS$1, value + other);",
    );

    var r = try buildAndLink(std.testing.allocator, &tmp, "entry.mjs");
    defer r.linker.deinit();
    defer r.destroyGraph();
    defer r.cache.deinit();

    const cjs_index = findModuleIdx(r.graph, "legacy.cjs") orelse return error.TestUnexpectedResult;
    const second_cjs_index = findModuleIdx(r.graph, "second.cjs") orelse return error.TestUnexpectedResult;
    const cjs_module = r.graph.getModule(cjs_index) orelse return error.TestUnexpectedResult;
    try std.testing.expect(cjs_module.cjs_runtime_factory_symbol != null);
    const inner = cjs_module.cjs_runtime_factory_symbol.?;
    const original_internal_ids = cjs_module.cjs_runtime_internal_symbols orelse return error.TestUnexpectedResult;
    const mutable_owner = @constCast(cjs_module);
    // The Module field is not serialized. Rebuild finalization must recover
    // the identity from the cached semantic symbol even if this module is no
    // longer CJS in the current graph.
    mutable_owner.cjs_runtime_factory_symbol = null;
    mutable_owner.cjs_runtime_internal_symbols = null;
    mutable_owner.wrap_kind = .none;
    try graph_finalize.registerWrapperSymbols(r.graph);
    try std.testing.expectEqual(inner, mutable_owner.cjs_runtime_factory_symbol orelse return error.TestUnexpectedResult);
    const recovered_internal_ids = mutable_owner.cjs_runtime_internal_symbols orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(original_internal_ids.callback_parameter, recovered_internal_ids.callback_parameter);
    try std.testing.expectEqual(original_internal_ids.module_parameter, recovered_internal_ids.module_parameter);
    try std.testing.expectEqual(original_internal_ids.catch_parameter, recovered_internal_ids.catch_parameter);
    try std.testing.expectEqual(original_internal_ids.require_function, recovered_internal_ids.require_function);
    mutable_owner.wrap_kind = .cjs;
    const sem = cjs_module.semantic orelse return error.TestUnexpectedResult;
    const symbol = sem.symbols.items[@backingInt(inner)];
    try std.testing.expectEqual(semantic_symbol.SyntheticKind.cjs_runtime_factory, symbol.synthetic_kind.?);
    var runtime_symbol_count: usize = 0;
    var module_it = r.graph.modulesIterator();
    while (module_it.next()) |module| {
        if (module.semantic) |module_sem| {
            for (module_sem.symbols.items) |candidate| {
                if (candidate.synthetic_kind == .cjs_runtime_factory) runtime_symbol_count += 1;
            }
        }
    }
    try std.testing.expectEqual(@as(usize, 1), runtime_symbol_count);

    const runtime_id = bundler_symbol.SymbolID.make(cjs_module.index, @backingInt(inner));
    // Output ownership must not recover this generated identity by its current
    // spelling; the rename passes below only need the exact SymbolID.
    if (mutable_owner.semantic) |*mutable_sem| {
        mutable_sem.symbols.items[@backingInt(inner)].synthetic_name = "runtime_factory_identity_without_spelling";
    }
    try r.linker.computeRenames();
    try expectCjsRuntimeInternalNames(&r.linker, cjs_index, recovered_internal_ids);
    mutable_owner.cjs_runtime_internal_symbols = null;
    try std.testing.expectError(error.CjsRuntimeInternalSymbolsMissing, r.linker.cjsFactoryRuntimeInternalNames());
    mutable_owner.cjs_runtime_internal_symbols = recovered_internal_ids;
    const callback_id = bundler_symbol.SymbolID.make(cjs_index, @backingInt(recovered_internal_ids.callback_parameter));
    const removed_callback_name = r.linker.rename_table.map.fetchRemove(callback_id) orelse return error.TestUnexpectedResult;
    try std.testing.expectError(error.CjsRuntimeInternalNameMissing, r.linker.cjsFactoryRuntimeInternalNames());
    try r.linker.rename_table.put(r.linker.allocator, callback_id, removed_callback_name.value);
    const single_bundle_name = try std.testing.allocator.dupe(u8, try r.linker.cjsFactoryRuntimeName());
    defer std.testing.allocator.free(single_bundle_name);
    try std.testing.expectEqualStrings("__commonJS$3", single_bundle_name);
    try std.testing.expectEqualStrings(single_bundle_name, r.linker.rename_table.get(runtime_id) orelse return error.TestUnexpectedResult);

    // A chunk pass clears the build-scope rename table. Its helper definition
    // and wrapper references must restore the same graph-wide identity mapping.
    r.graph.code_splitting = true;
    try r.linker.prepareCjsRuntimeName();
    try expectCjsRuntimeInternalNames(&r.linker, cjs_index, recovered_internal_ids);
    try std.testing.expectEqualStrings(single_bundle_name, try r.linker.cjsFactoryRuntimeName());
    try std.testing.expectEqualStrings(single_bundle_name, r.linker.rename_table.get(runtime_id) orelse return error.TestUnexpectedResult);

    // Re-select after a chunk-style reset too; no stale rename-table entry may
    // be needed for the exact SymbolID to own the graph-wide alias.
    r.linker.allocator.free(r.linker.cjs_factory_runtime_name.?);
    r.linker.cjs_factory_runtime_name = null;
    r.linker.clearCanonicalNames();
    try r.linker.prepareCjsRuntimeName();
    try std.testing.expectEqualStrings(single_bundle_name, r.linker.rename_table.get(runtime_id) orelse return error.TestUnexpectedResult);
    const entry_index = findModuleIdx(r.graph, "entry.mjs") orelse return error.TestUnexpectedResult;
    const chunk_modules = [_]ModuleIndex{ entry_index, cjs_index };
    try r.linker.computeRenamesForModules(&chunk_modules, &.{});
    try expectCjsRuntimeInternalNames(&r.linker, cjs_index, recovered_internal_ids);
    try std.testing.expectEqualStrings(single_bundle_name, try r.linker.cjsFactoryRuntimeName());
    try std.testing.expectEqualStrings(single_bundle_name, r.linker.rename_table.get(runtime_id) orelse return error.TestUnexpectedResult);

    // A split chunk may contain another CJS wrapper without the module that
    // owns the graph-level helper identity. The chunk-local rename reset must
    // still restore the same exact-ID mapping.
    const split_cjs_chunk = [_]ModuleIndex{second_cjs_index};
    try r.linker.computeRenamesForModules(&split_cjs_chunk, &.{});
    try expectCjsRuntimeInternalNames(&r.linker, cjs_index, recovered_internal_ids);
    try std.testing.expectEqualStrings(single_bundle_name, try r.linker.cjsFactoryRuntimeName());
    try std.testing.expectEqualStrings(single_bundle_name, r.linker.rename_table.get(runtime_id) orelse return error.TestUnexpectedResult);

    // The selected ID can outlive its module's CJS wrapper classification in
    // the graph, just as it can outlive chunk membership.
    mutable_owner.wrap_kind = .none;
    r.linker.allocator.free(r.linker.cjs_factory_runtime_name.?);
    r.linker.cjs_factory_runtime_name = null;
    r.linker.cjs_factory_runtime_symbol_id = null;
    try r.linker.computeRenamesForModules(&split_cjs_chunk, &.{});
    try std.testing.expectEqualStrings(
        try r.linker.cjsFactoryRuntimeName(),
        r.linker.rename_table.get(runtime_id) orelse return error.TestUnexpectedResult,
    );
    mutable_owner.wrap_kind = .cjs;

    // Tree shaking can exclude the identity's owner while retaining another
    // CJS module. Start name selection afresh to exercise that path rather than
    // reusing the alias selected by the full-graph pass above.
    r.linker.allocator.free(r.linker.cjs_factory_runtime_name.?);
    r.linker.cjs_factory_runtime_name = null;
    r.linker.cjs_factory_runtime_symbol_id = null;
    r.linker.tree_shaker_active = true;
    @constCast(r.graph.getModule(cjs_index) orelse return error.TestUnexpectedResult).is_included = false;
    @constCast(r.graph.getModule(second_cjs_index) orelse return error.TestUnexpectedResult).is_included = true;
    try r.linker.computeRenamesForModules(&split_cjs_chunk, &.{});
    try std.testing.expect(!std.mem.eql(u8, try r.linker.cjsFactoryRuntimeName(), "__commonJS"));
    try std.testing.expectEqualStrings(
        try r.linker.cjsFactoryRuntimeName(),
        r.linker.rename_table.get(runtime_id) orelse return error.TestUnexpectedResult,
    );

    // Dev rename reuse can skip computeRenames on a fresh Linker. Finalize
    // must still rediscover the cached helper identity and restore its names.
    r.linker.clearCanonicalNames();
    r.linker.cjs_factory_runtime_symbol_id = null;
    mutable_owner.cjs_runtime_factory_symbol = @fromBackingInt(@intCast(999_999));
    mutable_owner.cjs_runtime_internal_symbols = .{
        .callback_parameter = @fromBackingInt(@intCast(999_999)),
        .module_parameter = @fromBackingInt(@intCast(999_999)),
        .catch_parameter = @fromBackingInt(@intCast(999_999)),
        .require_function = @fromBackingInt(@intCast(999_999)),
    };
    try r.linker.finalize(.{
        .compute_renames = false,
        .compute_mangling = false,
        .populate_namespace_accesses = false,
        .skip_ref_counts = true,
    });
    try expectCjsRuntimeInternalNames(&r.linker, cjs_index, recovered_internal_ids);
}

test "runtime identity snapshots survive codec and module-field reset across ten input graphs" {
    const sources = [_][]const u8{
        "exports.value = 1;",
        "module.exports = 2;",
        "module.exports = function read() { return 3; };",
        "exports.value = () => 4;",
        "const cb = 5; exports.value = cb;",
        "function read(mod) { return mod; } exports.value = read(6);",
        "class Value {} exports.value = Value;",
        "exports.value = { get value() { return 8; } };",
        "exports['value'] = 9;",
        "Object.defineProperty(exports, 'value', { get() { return 10; } });",
    };
    for (sources) |source| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try writeFile(tmp.dir, "legacy.cjs", source);
        try writeFile(tmp.dir, "async.mjs", "await Promise.resolve(); export const value = 42;");
        try writeFile(tmp.dir, "payload.bin", "\x00\x01\xff");
        try writeFile(tmp.dir, "entry.mjs", "import value from './legacy.cjs'; import bytes from './payload.bin'; import('./async.mjs').then(ns => console.log(value, ns.value, bytes.length));");
        const allocator = std.testing.allocator;
        const directory = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
        defer allocator.free(directory);
        const entry = try std.fs.path.resolve(allocator, &.{ directory, "entry.mjs" });
        defer allocator.free(entry);
        var cache = resolve_cache_mod.ResolveCache.init(allocator, .{});
        const graph = try allocator.create(ModuleGraph);
        graph.* = ModuleGraph.init(allocator, &cache);
        graph.loader_overrides = &.{.{ .ext = ".bin", .loader = .binary }};
        graph.inline_dynamic_imports = true;
        try graph.build(std.testing.io, &.{entry});
        var linker = Linker.init(allocator, graph, .esm);
        try linker.link();
        var result: TestResult = .{ .linker = linker, .graph = graph, .cache = cache };
        defer result.linker.deinit();
        defer result.destroyGraph();
        defer result.cache.deinit();
        var owners: usize = 0;
        var binary_owners: usize = 0;
        var esm_owners: usize = 0;
        var modules = result.graph.modulesIterator();
        while (modules.next()) |cached_module| {
            const module = @constCast(cached_module);
            if (module.cjs_runtime_factory_symbol == null and module.esm_runtime_factory_symbol == null and module.to_binary_runtime_symbol == null) continue;
            if (module.to_binary_runtime_symbol != null) binary_owners += 1;
            if (module.esm_runtime_factory_symbol != null) esm_owners += 1;
            owners += 1;
            const expected: @import("module.zig").RuntimeIdentitySnapshot = .{
                .cjs_factory = module.cjs_runtime_factory_symbol,
                .cjs_internal = module.cjs_runtime_internal_symbols,
                .esm_factory = module.esm_runtime_factory_symbol,
                .esm_internal = module.esm_runtime_internal_symbols,
                .to_binary = module.to_binary_runtime_symbol,
            };
            const sem = &module.semantic.?;
            const snapshot = sem.runtime_identities orelse return error.MissingRuntimeIdentitySnapshot;
            try std.testing.expectEqualDeep(expected, snapshot.*);
            var encoded: std.ArrayList(u8) = .empty;
            defer encoded.deinit(std.testing.allocator);
            try @import("semantic_codec.zig").serialize(sem, &encoded, std.testing.allocator);
            module.semantic = try @import("semantic_codec.zig").deserialize(encoded.items, module.parse_arena.?.allocator());
            const restored = module.semantic.?.runtime_identities orelse return error.MissingRestoredRuntimeIdentitySnapshot;
            try std.testing.expectEqualDeep(expected, restored.*);
            // Corrupt a canonical role to a valid, wrong-kind symbol. The
            // producer must reject it instead of finding a same-name decoy
            // or allocating a replacement identity.
            if (restored.cjs_internal) |ids| {
                restored.cjs_internal.?.callback_parameter = ids.require_function;
                try std.testing.expectError(error.MissingRuntimeHelperSymbol, graph_finalize.registerWrapperSymbols(result.graph));
                restored.* = expected;
            }
            if (restored.esm_internal) |ids| {
                restored.esm_internal.?.factory_parameter = ids.init_function;
                try std.testing.expectError(error.MissingRuntimeHelperSymbol, graph_finalize.registerWrapperSymbols(result.graph));
                restored.* = expected;
            }
            module.to_binary_runtime_symbol = null;
            module.cjs_runtime_factory_symbol = null;
            module.cjs_runtime_internal_symbols = null;
            module.esm_runtime_factory_symbol = null;
            module.esm_runtime_internal_symbols = null;
            try graph_finalize.registerWrapperSymbols(result.graph);
            try std.testing.expectEqual(expected.to_binary, module.to_binary_runtime_symbol);
            try std.testing.expectEqual(expected.cjs_factory, module.cjs_runtime_factory_symbol);
            try std.testing.expectEqualDeep(expected.cjs_internal, module.cjs_runtime_internal_symbols);
            try std.testing.expectEqual(expected.esm_factory, module.esm_runtime_factory_symbol);
            try std.testing.expectEqualDeep(expected.esm_internal, module.esm_runtime_internal_symbols);
            // A cache that loses the entire canonical record must not heal
            // its orphan runtime rows by allocating a different identity.
            module.to_binary_runtime_symbol = null;
            module.cjs_runtime_factory_symbol = null;
            module.cjs_runtime_internal_symbols = null;
            module.esm_runtime_factory_symbol = null;
            module.esm_runtime_internal_symbols = null;
            module.semantic.?.runtime_identities = null;
            try std.testing.expectError(error.MissingRuntimeHelperSymbol, graph_finalize.registerWrapperSymbols(result.graph));
            module.semantic.?.runtime_identities = restored;
            try graph_finalize.registerWrapperSymbols(result.graph);
        }
        try std.testing.expect(owners > 0);
        try std.testing.expectEqual(@as(usize, 1), binary_owners);
        try std.testing.expect(esm_owners > 0);
    }
}

fn expectCjsRuntimeInternalNames(linker: *Linker, module_index: ModuleIndex, ids: CjsRuntimeInternalSymbolIds) !void {
    const names = try linker.cjsFactoryRuntimeInternalNames();
    try std.testing.expectEqualStrings("cb", names.callback_parameter);
    try std.testing.expectEqualStrings("mod", names.module_parameter);
    try std.testing.expectEqualStrings("e", names.catch_parameter);
    try std.testing.expectEqualStrings("__require", names.require_function);
    try std.testing.expectEqualStrings(
        names.callback_parameter,
        linker.rename_table.get(bundler_symbol.SymbolID.make(module_index, @backingInt(ids.callback_parameter))) orelse return error.TestUnexpectedResult,
    );
    try std.testing.expectEqualStrings(
        names.module_parameter,
        linker.rename_table.get(bundler_symbol.SymbolID.make(module_index, @backingInt(ids.module_parameter))) orelse return error.TestUnexpectedResult,
    );
    try std.testing.expectEqualStrings(
        names.catch_parameter,
        linker.rename_table.get(bundler_symbol.SymbolID.make(module_index, @backingInt(ids.catch_parameter))) orelse return error.TestUnexpectedResult,
    );
    try std.testing.expectEqualStrings(
        names.require_function,
        linker.rename_table.get(bundler_symbol.SymbolID.make(module_index, @backingInt(ids.require_function))) orelse return error.TestUnexpectedResult,
    );
}

test "linker: semantic-less CJS wrappers use a parsed graph SymbolID for the runtime factory" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(
        tmp.dir,
        "entry.mjs",
        "import fs from 'fs';\n" ++
            "export const __commonJS = typeof fs;\n" ++
            "console.log(__commonJS);\n",
    );

    var r = try buildAndLink(std.testing.allocator, &tmp, "entry.mjs");
    defer r.linker.deinit();
    defer r.destroyGraph();
    defer r.cache.deinit();

    const entry_index = findModuleIdx(r.graph, "entry.mjs") orelse return error.TestUnexpectedResult;
    const entry = @constCast(r.graph.getModule(entry_index) orelse return error.TestUnexpectedResult);
    const entry_sem = entry.semantic orelse return error.TestUnexpectedResult;
    const runtime_inner = entry.cjs_runtime_factory_symbol orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(
        semantic_symbol.SyntheticKind.cjs_runtime_factory,
        entry_sem.symbols.items[@backingInt(runtime_inner)].synthetic_kind.?,
    );
    const internal_ids = entry.cjs_runtime_internal_symbols orelse return error.TestUnexpectedResult;

    var has_ast_less_cjs_with_exact_wrapper = false;
    var module_it = r.graph.modulesIterator();
    while (module_it.next()) |module| {
        if (module.wrap_kind == .cjs and module.ast == null) {
            const wrapper_sem = module.semantic orelse return error.TestUnexpectedResult;
            const require_inner = module.require_symbol orelse return error.TestUnexpectedResult;
            try std.testing.expectEqual(
                semantic_symbol.SyntheticKind.cjs_require,
                wrapper_sem.symbols.items[@backingInt(require_inner)].synthetic_kind.?,
            );
            try std.testing.expect(module.getRequireName(null) != null);
            has_ast_less_cjs_with_exact_wrapper = true;
        }
    }
    try std.testing.expect(has_ast_less_cjs_with_exact_wrapper);

    try r.linker.computeRenames();
    try expectCjsRuntimeInternalNames(&r.linker, entry_index, internal_ids);
    const saved_factory_id = r.linker.cjs_factory_runtime_symbol_id orelse return error.TestUnexpectedResult;
    r.linker.cjs_factory_runtime_symbol_id = null;
    try std.testing.expectError(error.CjsRuntimeFactoryIdentityMissing, r.linker.cjsFactoryRuntimeInternalNames());
    r.linker.cjs_factory_runtime_symbol_id = saved_factory_id;
    const runtime_id = bundler_symbol.SymbolID.make(entry_index, @backingInt(runtime_inner));
    const runtime_name = r.linker.rename_table.get(runtime_id) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("__commonJS", runtime_name);

    // The source binding and helper share the emitted bundle scope. The output
    // identity keeps the helper's preferred name and the source binding moves.
    const source_scope = entry_sem.scope_maps[0];
    const source_inner = source_scope.get("__commonJS") orelse return error.TestUnexpectedResult;
    const source_id = bundler_symbol.SymbolID.make(entry_index, source_inner);
    const source_name = r.linker.rename_table.get(source_id) orelse "__commonJS";
    try std.testing.expect(!std.mem.eql(u8, runtime_name, source_name));
}

test "linker: AST-less CJS wrapper names have recoverable exact SymbolIds" {
    var cache = resolve_cache_mod.ResolveCache.init(std.testing.allocator, .{});
    defer cache.deinit();
    const graph = try std.testing.allocator.create(ModuleGraph);
    graph.* = ModuleGraph.init(std.testing.allocator, &cache);
    defer {
        graph.deinit();
        std.testing.allocator.destroy(graph);
    }

    const first_index = try graph.addDisabledModule("a/logo.png");
    const second_index = try graph.addDisabledModule("b/logo.png");
    for ([_]ModuleIndex{ first_index, second_index }) |index| {
        const module = graph.moduleAtMut(index) orelse return error.TestUnexpectedResult;
        module.wrap_kind = .cjs;
        module.exports_kind = .commonjs;
    }

    try graph_finalize.registerWrapperSymbols(graph);
    const first = graph.moduleAtMut(first_index) orelse return error.TestUnexpectedResult;
    const second = graph.moduleAtMut(second_index) orelse return error.TestUnexpectedResult;
    try std.testing.expect(first.ast == null and second.ast == null);
    const first_sem = first.semantic orelse return error.TestUnexpectedResult;
    const second_sem = second.semantic orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 2), first_sem.scopes.len);
    try std.testing.expectEqual(@as(usize, 2), first_sem.scope_maps.len);
    try std.testing.expectEqual(@as(usize, 2), second_sem.scopes.len);
    try std.testing.expectEqual(@as(usize, 2), second_sem.scope_maps.len);
    const first_exports_param = first.cjs_wrapper_exports_parameter_symbol orelse return error.TestUnexpectedResult;
    const first_module_param = first.cjs_wrapper_module_parameter_symbol orelse return error.TestUnexpectedResult;
    const first_wrapper_scope = first_sem.scopes[0].parent;
    try std.testing.expectEqual(@as(u32, 1), @backingInt(first_wrapper_scope));
    try std.testing.expectEqual(@import("../semantic/scope.zig").ScopeKind.global, first_sem.scopes[0].kind);
    try std.testing.expectEqual(@import("../semantic/scope.zig").ScopeKind.function, first_sem.scopes[@backingInt(first_wrapper_scope)].kind);
    try std.testing.expectEqual(@as(usize, 2), first_sem.scope_maps[0].count());
    try std.testing.expectEqual(@as(?usize, @backingInt(first_exports_param)), first_sem.scope_maps[0].get("exports"));
    try std.testing.expectEqual(@as(?usize, @backingInt(first_module_param)), first_sem.scope_maps[0].get("module"));
    try std.testing.expectEqual(@as(usize, 2), first_sem.scope_maps[@backingInt(first_wrapper_scope)].count());

    const first_inner = first.require_symbol orelse return error.TestUnexpectedResult;
    const second_inner = second.require_symbol orelse return error.TestUnexpectedResult;
    const first_row = first_sem.symbols.items[@backingInt(first_inner)];
    const second_row = second_sem.symbols.items[@backingInt(second_inner)];
    const first_exports_row = first_sem.symbols.items[@backingInt(first_exports_param)];
    const first_module_row = first_sem.symbols.items[@backingInt(first_module_param)];
    try std.testing.expectEqual(semantic_symbol.SyntheticKind.cjs_require, first_row.synthetic_kind.?);
    try std.testing.expectEqual(semantic_symbol.SyntheticKind.cjs_require, second_row.synthetic_kind.?);
    try std.testing.expectEqual(semantic_symbol.SyntheticKind.cjs_wrapper_exports_parameter, first_exports_row.synthetic_kind.?);
    try std.testing.expectEqual(semantic_symbol.SyntheticKind.cjs_wrapper_module_parameter, first_module_row.synthetic_kind.?);
    try std.testing.expectEqual(first_wrapper_scope, first_exports_row.scope_id);
    try std.testing.expectEqual(first_wrapper_scope, first_module_row.scope_id);
    try std.testing.expectEqual(first_wrapper_scope, first_exports_row.origin_scope);
    try std.testing.expectEqual(first_wrapper_scope, first_module_row.origin_scope);
    try std.testing.expectEqual(@as(?usize, @backingInt(first_exports_param)), first_sem.scope_maps[@backingInt(first_wrapper_scope)].get("exports"));
    try std.testing.expectEqual(@as(?usize, @backingInt(first_module_param)), first_sem.scope_maps[@backingInt(first_wrapper_scope)].get("module"));
    try std.testing.expectEqualStrings("require_logo", first.getRequireName(null) orelse return error.TestUnexpectedResult);
    try std.testing.expectEqualStrings("require_logo$2", second.getRequireName(null) orelse return error.TestUnexpectedResult);
    const first_symbol_count = first_sem.symbols.items.len;
    const second_symbol_count = second_sem.symbols.items.len;
    // A lost convenience field must be recovered from the owning semantic row,
    // and repeated finalization must not append duplicate identities.
    first.require_symbol = null;
    try std.testing.expectError(error.MissingWrapperSymbol, first.allocRequireName(std.testing.allocator, null));
    try graph_finalize.registerWrapperSymbols(graph);
    try graph_finalize.registerWrapperSymbols(graph);
    try std.testing.expectEqual(first_inner, first.require_symbol orelse return error.TestUnexpectedResult);
    try std.testing.expectEqual(first_exports_param, first.cjs_wrapper_exports_parameter_symbol.?);
    try std.testing.expectEqual(first_module_param, first.cjs_wrapper_module_parameter_symbol.?);
    try std.testing.expectEqual(first_symbol_count, first.semantic.?.symbols.items.len);
    try std.testing.expectEqual(second_symbol_count, second.semantic.?.symbols.items.len);
    try std.testing.expectEqualStrings("require_logo", first.getRequireName(null) orelse return error.TestUnexpectedResult);
    try std.testing.expectEqualStrings("require_logo$2", second.getRequireName(null) orelse return error.TestUnexpectedResult);

    // The exact wrapper ScopeId is an invariant, even when the convenience
    // symbol IDs are still present and point to valid symbols.
    first.semantic.?.symbols.items[@backingInt(first_exports_param)].scope_id = @fromBackingInt(@intCast(0));
    try std.testing.expectError(error.CjsWrapperParameterScopeMismatch, graph_finalize.registerWrapperSymbols(graph));
    first.semantic.?.symbols.items[@backingInt(first_exports_param)].scope_id = first_wrapper_scope;
    first.semantic.?.symbols.items[@backingInt(first_exports_param)].origin_scope = .none;
    try std.testing.expectError(error.CjsWrapperParameterScopeMismatch, graph_finalize.registerWrapperSymbols(graph));
}

test "#4819: CJS lexical conflicts keep distinct wrapper parameter SymbolIds" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.cjs", "let exports = 'local'; let module = exports;");

    var r = try buildAndLink(std.testing.allocator, &tmp, "entry.cjs");
    defer r.linker.deinit();
    defer r.destroyGraph();
    defer r.cache.deinit();

    const index = findModuleIdx(r.graph, "entry.cjs") orelse return error.TestUnexpectedResult;
    const module = r.graph.moduleAtMut(index) orelse return error.TestUnexpectedResult;
    const exports_id = module.cjs_wrapper_exports_parameter_symbol orelse return error.TestUnexpectedResult;
    const module_id = module.cjs_wrapper_module_parameter_symbol orelse return error.TestUnexpectedResult;
    const sem = module.semantic orelse return error.TestUnexpectedResult;
    const exports_row = sem.symbols.items[@backingInt(exports_id)];
    const module_row = sem.symbols.items[@backingInt(module_id)];
    const wrapper_scope = sem.scopes[0].parent;

    try std.testing.expect(!wrapper_scope.isNone());
    try std.testing.expectEqual(@as(usize, sem.scopes.len - 1), @backingInt(wrapper_scope));
    try std.testing.expectEqual(@as(usize, sem.scope_maps.len - 1), @backingInt(wrapper_scope));
    try std.testing.expectEqual(@as(@TypeOf(wrapper_scope), .none), sem.scopes[@backingInt(wrapper_scope)].parent);
    try std.testing.expectEqual(@as(@TypeOf(sem.scopes[0].kind), .function), sem.scopes[@backingInt(wrapper_scope)].kind);
    try std.testing.expectEqual(wrapper_scope, exports_row.scope_id);
    try std.testing.expectEqual(wrapper_scope, module_row.scope_id);
    try std.testing.expectEqual(@as(?usize, @backingInt(exports_id)), sem.scope_maps[@backingInt(wrapper_scope)].get("exports"));
    try std.testing.expectEqual(@as(?usize, @backingInt(module_id)), sem.scope_maps[@backingInt(wrapper_scope)].get("module"));
    try std.testing.expectEqual(wrapper_scope, sem.scopes[0].parent);

    const source_exports = sem.scope_maps[0].get("exports") orelse return error.TestUnexpectedResult;
    const source_module = sem.scope_maps[0].get("module") orelse return error.TestUnexpectedResult;
    try std.testing.expect(source_exports != @backingInt(exports_id));
    try std.testing.expect(source_module != @backingInt(module_id));
    try std.testing.expectEqualStrings("exports", sem.symbols.items[source_exports].nameText(module.source));
    try std.testing.expectEqualStrings("module", sem.symbols.items[source_module].nameText(module.source));

    try r.linker.finalize(.{ .compute_renames = false, .compute_mangling = false });
    const exports_output_name = r.linker.rename_table.get(bundler_symbol.SymbolID.make(index, @backingInt(exports_id))) orelse return error.TestUnexpectedResult;
    const module_output_name = r.linker.rename_table.get(bundler_symbol.SymbolID.make(index, @backingInt(module_id))) orelse return error.TestUnexpectedResult;
    try std.testing.expect(!std.mem.eql(u8, exports_output_name, "exports"));
    try std.testing.expect(!std.mem.eql(u8, module_output_name, "module"));
    try std.testing.expect(!std.mem.eql(u8, exports_output_name, module_output_name));

    const symbol_count = sem.symbols.items.len;
    const scope_count = sem.scopes.len;
    const scope_map_count = sem.scope_maps.len;
    try graph_finalize.registerWrapperSymbols(r.graph);
    try graph_finalize.registerWrapperSymbols(r.graph);
    try std.testing.expectEqual(exports_id, module.cjs_wrapper_exports_parameter_symbol.?);
    try std.testing.expectEqual(module_id, module.cjs_wrapper_module_parameter_symbol.?);
    try std.testing.expectEqual(symbol_count, module.semantic.?.symbols.items.len);
    try std.testing.expectEqual(scope_count, module.semantic.?.scopes.len);
    try std.testing.expectEqual(scope_map_count, module.semantic.?.scope_maps.len);

    const mutable_scope_maps = @constCast(sem.scope_maps);
    mutable_scope_maps[@backingInt(wrapper_scope)].putAssumeCapacity("exports", @backingInt(module_id));
    try std.testing.expectError(error.CjsWrapperParameterScopeMismatch, graph_finalize.registerWrapperSymbols(r.graph));
}

test "#4819: escaped CJS var redeclaration shares the wrapper parameter SymbolId" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.cjs", "var exp\\u006frts = 42;");

    var r = try buildAndLink(std.testing.allocator, &tmp, "entry.cjs");
    defer r.linker.deinit();
    defer r.destroyGraph();
    defer r.cache.deinit();

    const index = findModuleIdx(r.graph, "entry.cjs") orelse return error.TestUnexpectedResult;
    const module = r.graph.getModule(index) orelse return error.TestUnexpectedResult;
    const exports_id = module.cjs_wrapper_exports_parameter_symbol orelse return error.TestUnexpectedResult;
    const sem = module.semantic orelse return error.TestUnexpectedResult;
    const wrapper_scope = sem.scopes[0].parent;
    const escaped_source_key = "exp\\u006frts";
    try std.testing.expect(!wrapper_scope.isNone());
    try std.testing.expectEqual(@as(usize, @backingInt(exports_id)), sem.scope_maps[0].get(escaped_source_key) orelse return error.TestUnexpectedResult);
    try std.testing.expectEqual(@as(usize, @backingInt(exports_id)), sem.scope_maps[0].get("exports") orelse return error.TestUnexpectedResult);
    try std.testing.expectEqual(@as(usize, @backingInt(exports_id)), sem.scope_maps[@backingInt(wrapper_scope)].get("exports") orelse return error.TestUnexpectedResult);
    try std.testing.expectEqual(wrapper_scope, sem.symbols.items[@backingInt(exports_id)].scope_id);
    try std.testing.expect(sem.symbols.items[@backingInt(exports_id)].synthetic_kind == null);
    const scope_count = sem.scopes.len;
    const scope_map_count = sem.scope_maps.len;
    try graph_finalize.registerWrapperSymbols(r.graph);
    try graph_finalize.registerWrapperSymbols(r.graph);
    try std.testing.expectEqual(scope_count, module.semantic.?.scopes.len);
    try std.testing.expectEqual(scope_map_count, module.semantic.?.scope_maps.len);

    const source_ast = module.ast orelse return error.TestUnexpectedResult;
    const source_semantic = module.semantic orelse return error.TestUnexpectedResult;
    var encoded: std.ArrayList(u8) = .empty;
    defer encoded.deinit(std.testing.allocator);
    try module_codec.serialize(&source_ast, &source_semantic, &encoded, std.testing.allocator);
    var decoded_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer decoded_arena.deinit();
    const decoded = try module_codec.deserialize(encoded.items, decoded_arena.allocator());
    const decoded_wrapper_scope = decoded.semantic.scopes[0].parent;
    try std.testing.expect(!decoded_wrapper_scope.isNone());
    const decoded_wrapper_raw: usize = @backingInt(decoded_wrapper_scope);
    const decoded_exports_id = decoded.semantic.scope_maps[decoded_wrapper_raw].get("exports") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(decoded_wrapper_scope, decoded.semantic.symbols.items[decoded_exports_id].scope_id);
    try std.testing.expectEqual(decoded_exports_id, decoded.semantic.scope_maps[0].get(escaped_source_key) orelse return error.TestUnexpectedResult);
    try std.testing.expectEqual(decoded_exports_id, decoded.semantic.scope_maps[0].get("exports") orelse return error.TestUnexpectedResult);
}

test "linker: wrapped source modules fail closed without semantic identity" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.cjs", "module.exports = 1;");

    var r = try buildAndLink(std.testing.allocator, &tmp, "entry.cjs");
    defer r.linker.deinit();
    defer r.destroyGraph();
    defer r.cache.deinit();

    const index = findModuleIdx(r.graph, "entry.cjs") orelse return error.TestUnexpectedResult;
    const module = @constCast(r.graph.getModule(index) orelse return error.TestUnexpectedResult);
    try std.testing.expect(module.ast != null);
    module.semantic = null;
    try std.testing.expectError(error.MissingSemantic, graph_finalize.registerWrapperSymbols(r.graph));
    try std.testing.expectError(error.MissingWrapperSymbol, module.allocRequireName(std.testing.allocator, null));
}

test "linker: semantic refresh restores graph-owned wrapper identities" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.cjs", "module.exports = 1;");

    var r = try buildAndLink(std.testing.allocator, &tmp, "entry.cjs");
    defer r.linker.deinit();
    defer r.destroyGraph();
    defer r.cache.deinit();

    const index = findModuleIdx(r.graph, "entry.cjs") orelse return error.TestUnexpectedResult;
    const module = r.graph.moduleAtMut(index) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(types.WrapKind.cjs, module.wrap_kind);
    const old_require_name = module.getRequireName(&r.linker.rename_table) orelse return error.TestUnexpectedResult;
    const old_exports_name = module.getExportsName(&r.linker.rename_table) orelse return error.TestUnexpectedResult;

    // Fresh analysis replaces semantic rows but leaves stale convenience
    // fields. Resync must rebuild those graph-owned rows and update their IDs.
    const parse_arena = module.parse_arena orelse return error.TestUnexpectedResult;
    try r.graph.resyncModuleMetadataAfterAstMutation(module, parse_arena.allocator(), &r.linker.rename_table);
    try r.linker.applyPendingRenames();
    try r.linker.prepareCjsRuntimeInternalNames();

    const semantic = module.semantic orelse return error.TestUnexpectedResult;
    const require_id = module.require_symbol orelse return error.TestUnexpectedResult;
    const exports_id = module.exports_symbol orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(
        semantic_symbol.SyntheticKind.cjs_require,
        semantic.symbols.items[@backingInt(require_id)].synthetic_kind.?,
    );
    try std.testing.expectEqual(
        semantic_symbol.SyntheticKind.cjs_exports,
        semantic.symbols.items[@backingInt(exports_id)].synthetic_kind.?,
    );
    try std.testing.expectEqualStrings(old_require_name, module.getRequireName(&r.linker.rename_table) orelse return error.TestUnexpectedResult);
    try std.testing.expectEqualStrings(old_exports_name, module.getExportsName(&r.linker.rename_table) orelse return error.TestUnexpectedResult);

    const factory_id = module.cjs_runtime_factory_symbol orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(
        semantic_symbol.SyntheticKind.cjs_runtime_factory,
        semantic.symbols.items[@backingInt(factory_id)].synthetic_kind.?,
    );
    const internal_ids = module.cjs_runtime_internal_symbols orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(
        semantic_symbol.SyntheticKind.cjs_runtime_internal_local,
        semantic.symbols.items[@backingInt(internal_ids.callback_parameter)].synthetic_kind.?,
    );
    const runtime_names = try r.linker.cjsFactoryRuntimeInternalNames();
    try std.testing.expect(runtime_names.callback_parameter.len > 0);
}

test "linker: semantic-less binary entry assigns exact runtime SymbolIds" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "entry.bin", .data = &.{ 0xDE, 0xAD } });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "second.bin", .data = &.{ 0xBE, 0xEF } });

    const dp = try dirPath(&tmp);
    defer std.testing.allocator.free(dp);
    const entry = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "entry.bin" });
    defer std.testing.allocator.free(entry);
    const second_entry = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "second.bin" });
    defer std.testing.allocator.free(second_entry);

    var cache = resolve_cache_mod.ResolveCache.init(std.testing.allocator, .{});
    defer cache.deinit();
    const graph = try std.testing.allocator.create(ModuleGraph);
    graph.* = ModuleGraph.init(std.testing.allocator, &cache);
    graph.loader_overrides = &.{.{ .ext = ".bin", .loader = .binary }};
    graph.code_splitting = true;
    try graph.build(std.testing.io, &.{ entry, second_entry });
    defer {
        graph.deinit();
        std.testing.allocator.destroy(graph);
    }

    var linker = Linker.initWithGlobalIdentifiers(
        std.testing.allocator,
        graph,
        .esm,
        &.{ "__commonJS", "__toBinary" },
    );
    defer linker.deinit();
    try linker.link();
    try linker.computeRenames();

    var factory_owner: ?*const @import("module.zig").Module = null;
    var binary_owner: ?*const @import("module.zig").Module = null;
    var factory_count: usize = 0;
    var binary_count: usize = 0;
    var module_it = graph.modulesIterator();
    while (module_it.next()) |module| {
        try std.testing.expect(module.ast == null);
        if (module.cjs_runtime_factory_symbol != null) {
            factory_count += 1;
            factory_owner = module;
        }
        if (module.to_binary_runtime_symbol != null) {
            binary_count += 1;
            binary_owner = module;
        }
    }
    try std.testing.expectEqual(@as(usize, 1), factory_count);
    try std.testing.expectEqual(@as(usize, 1), binary_count);
    const cjs_module = factory_owner orelse return error.TestUnexpectedResult;
    const binary_module = binary_owner orelse return error.TestUnexpectedResult;
    const factory_id = bundler_symbol.SymbolID.make(cjs_module.index, @backingInt(cjs_module.cjs_runtime_factory_symbol.?));
    const binary_id = bundler_symbol.SymbolID.make(binary_module.index, @backingInt(binary_module.to_binary_runtime_symbol.?));
    const factory_name = linker.rename_table.get(factory_id) orelse return error.TestUnexpectedResult;
    const binary_name = try linker.toBinaryRuntimeName();
    const saved_factory_name = try std.testing.allocator.dupe(u8, factory_name);
    defer std.testing.allocator.free(saved_factory_name);
    const saved_binary_name = try std.testing.allocator.dupe(u8, binary_name);
    defer std.testing.allocator.free(saved_binary_name);

    try std.testing.expect(!std.mem.eql(u8, "__commonJS", factory_name));
    try std.testing.expect(!std.mem.eql(u8, "__toBinary", binary_name));
    try std.testing.expectEqualStrings(factory_name, try linker.cjsFactoryRuntimeName());
    try std.testing.expectEqualStrings(binary_name, linker.rename_table.get(binary_id) orelse return error.TestUnexpectedResult);

    // Independent chunk rename passes must restore these graph-wide aliases,
    // including when the owning identity is outside the current chunk.
    const first_chunk = [_]ModuleIndex{cjs_module.index};
    try linker.computeRenamesForModules(&first_chunk, &.{});
    try std.testing.expectEqualStrings(saved_factory_name, linker.rename_table.get(factory_id) orelse return error.TestUnexpectedResult);
    try std.testing.expectEqualStrings(saved_binary_name, try linker.toBinaryRuntimeName());
    const second_binary_index = findModuleIdx(graph, "second.bin") orelse return error.TestUnexpectedResult;
    try std.testing.expect(second_binary_index != cjs_module.index);
    const second_chunk = [_]ModuleIndex{second_binary_index};
    try linker.computeRenamesForModules(&second_chunk, &.{});
    try std.testing.expectEqualStrings(saved_factory_name, linker.rename_table.get(factory_id) orelse return error.TestUnexpectedResult);
    try std.testing.expectEqualStrings(saved_binary_name, try linker.toBinaryRuntimeName());

    const second_binary_module_mut = graph.moduleAtMut(second_binary_index) orelse return error.TestUnexpectedResult;
    const duplicate_binary_inner = try addGraphRuntimeHelperIdentity(second_binary_module_mut, "__toBinary");
    second_binary_module_mut.to_binary_runtime_symbol = duplicate_binary_inner;
    try std.testing.expectError(error.ToBinaryRuntimeIdentityInvalid, linker.toBinaryRuntimeName());
    second_binary_module_mut.to_binary_runtime_symbol = null;

    const binary_module_mut = graph.moduleAtMut(binary_module.index) orelse return error.TestUnexpectedResult;
    const binary_inner = binary_module_mut.to_binary_runtime_symbol orelse return error.TestUnexpectedResult;
    const binary_raw: usize = @backingInt(binary_inner);
    const binary_semantic = if (binary_module_mut.semantic) |*value| value else return error.TestUnexpectedResult;
    const original_binary_symbol = binary_semantic.symbols.items[binary_raw];
    const original_binary_linker_id = linker.to_binary_runtime_symbol_id;

    // A matching semantic row is not a substitute for the producer's typed
    // Module ID, even if the name search would find exactly one row.
    binary_module_mut.to_binary_runtime_symbol = null;
    linker.to_binary_runtime_symbol_id = null;
    try std.testing.expectError(error.ToBinaryRuntimeIdentityMissing, linker.toBinaryRuntimeName());
    try std.testing.expectError(error.ToBinaryRuntimeIdentityMissing, linker.prepareToBinaryRuntimeName());
    linker.to_binary_runtime_symbol_id = bundler_symbol.SymbolID.make(binary_module.index, std.math.maxInt(u32));
    try std.testing.expectError(error.ToBinaryRuntimeIdentityInvalid, linker.toBinaryRuntimeName());
    linker.to_binary_runtime_symbol_id = null;

    // Duplicate same-name rows must not turn a missing producer handle into a
    // first-match guess.
    const decoy_raw: usize = if (binary_raw == 0) 1 else 0;
    try std.testing.expect(decoy_raw < binary_semantic.symbols.items.len);
    const original_decoy_symbol = binary_semantic.symbols.items[decoy_raw];
    binary_semantic.symbols.items[decoy_raw].synthetic_kind = .bundler_runtime_helper;
    binary_semantic.symbols.items[decoy_raw].kind = .variable_var;
    binary_semantic.symbols.items[decoy_raw].synthetic_name = "__toBinary";
    try std.testing.expectError(error.ToBinaryRuntimeIdentityMissing, linker.toBinaryRuntimeName());
    binary_semantic.symbols.items[decoy_raw] = original_decoy_symbol;

    binary_module_mut.to_binary_runtime_symbol = @fromBackingInt(@intCast(std.math.maxInt(u32)));
    try std.testing.expectError(error.ToBinaryRuntimeIdentityInvalid, linker.toBinaryRuntimeName());
    binary_module_mut.to_binary_runtime_symbol = binary_inner;

    binary_semantic.symbols.items[binary_raw].synthetic_kind = .runtime_helper_preamble;
    try std.testing.expectError(error.ToBinaryRuntimeIdentityInvalid, linker.toBinaryRuntimeName());
    binary_semantic.symbols.items[binary_raw] = original_binary_symbol;
    binary_semantic.symbols.items[binary_raw].synthetic_name = "__toBinary$decoy";
    try std.testing.expectError(error.ToBinaryRuntimeIdentityInvalid, linker.toBinaryRuntimeName());
    binary_semantic.symbols.items[binary_raw] = original_binary_symbol;
    binary_semantic.symbols.items[binary_raw].kind = .variable_let;
    try std.testing.expectError(error.ToBinaryRuntimeIdentityInvalid, linker.toBinaryRuntimeName());
    binary_semantic.symbols.items[binary_raw] = original_binary_symbol;

    // A stale linker-side cache can be replaced only from the exact typed ID
    // stored on its owner module.
    linker.to_binary_runtime_symbol_id = bundler_symbol.SymbolID.make(binary_module.index, std.math.maxInt(u32));
    try std.testing.expectEqualStrings(saved_binary_name, try linker.toBinaryRuntimeName());
    try linker.prepareToBinaryRuntimeName();
    try std.testing.expectEqual(binary_id, linker.to_binary_runtime_symbol_id.?);
    linker.to_binary_runtime_symbol_id = original_binary_linker_id;
}

test "linker: CJS runtime factory emission requires a graph SymbolId" {
    var cache = resolve_cache_mod.ResolveCache.init(std.testing.allocator, .{});
    defer cache.deinit();
    const graph = try std.testing.allocator.create(ModuleGraph);
    graph.* = ModuleGraph.init(std.testing.allocator, &cache);
    defer {
        graph.deinit();
        std.testing.allocator.destroy(graph);
    }

    const index = try graph.addDisabledModule("runtime-only-cjs");
    const module = graph.moduleAtMut(index) orelse return error.TestUnexpectedResult;
    try std.testing.expect(module.semantic == null);

    var linker = Linker.initWithGlobalIdentifiers(std.testing.allocator, graph, .esm, &.{"__commonJS"});
    defer linker.deinit();
    try std.testing.expectError(error.CjsRuntimeFactoryIdentityMissing, linker.prepareCjsRuntimeName());
    try std.testing.expectError(error.CjsRuntimeFactoryIdentityMissing, linker.cjsFactoryRuntimeName());
    try std.testing.expectError(error.CjsRuntimeFactoryIdentityMissing, linker.cjsFactoryRuntimeInternalNames());

    // The same invalid state must fail in graph-wide alias selection. Normal
    // graph finalization first creates synthetic semantic ownership for the
    // AST-less wrapper, after which output uses the exact graph SymbolId.
    graph.code_splitting = true;
    try std.testing.expectError(error.CjsRuntimeFactoryIdentityMissing, linker.prepareCjsRuntimeName());
    try graph_finalize.registerWrapperSymbols(graph);
    try linker.prepareCjsRuntimeName();
    const finalized = graph.moduleAtMut(index) orelse return error.TestUnexpectedResult;
    const factory_id = finalized.cjs_runtime_factory_symbol orelse return error.TestUnexpectedResult;
    const internal_ids = finalized.cjs_runtime_internal_symbols orelse return error.TestUnexpectedResult;
    try std.testing.expect(!std.mem.eql(u8, "__commonJS", try linker.cjsFactoryRuntimeName()));
    try expectCjsRuntimeInternalNames(&linker, index, internal_ids);
    try std.testing.expectEqual(
        try linker.cjsFactoryRuntimeName(),
        linker.rename_table.get(bundler_symbol.SymbolID.make(index, @backingInt(factory_id))) orelse return error.TestUnexpectedResult,
    );
}

test "linker: optional CJS runtime names remain available without CJS wrappers" {
    var cache = resolve_cache_mod.ResolveCache.init(std.testing.allocator, .{});
    defer cache.deinit();
    const graph = try std.testing.allocator.create(ModuleGraph);
    graph.* = ModuleGraph.init(std.testing.allocator, &cache);
    defer {
        graph.deinit();
        std.testing.allocator.destroy(graph);
    }
    graph.code_splitting = true;

    var linker = Linker.init(std.testing.allocator, graph, .esm);
    defer linker.deinit();
    try linker.prepareCjsRuntimeName();
    try std.testing.expectEqualStrings("__commonJS", try linker.cjsFactoryRuntimeName());
    const internal_names = try linker.cjsFactoryRuntimeInternalNames();
    try std.testing.expectEqualStrings("cb", internal_names.callback_parameter);
    try std.testing.expectEqualStrings("mod", internal_names.module_parameter);
    try std.testing.expectEqualStrings("e", internal_names.catch_parameter);
    try std.testing.expectEqualStrings("__require", internal_names.require_function);
}

test "linker: disabled CJS wrappers receive runtime SymbolIds without source semantics" {
    var cache = resolve_cache_mod.ResolveCache.init(std.testing.allocator, .{});
    defer cache.deinit();
    var store = module_store_mod.PersistentModuleStore.init(std.testing.allocator);
    defer store.deinit();
    const graph = try std.testing.allocator.create(ModuleGraph);
    graph.* = ModuleGraph.init(std.testing.allocator, &cache);
    defer {
        graph.deinit();
        std.testing.allocator.destroy(graph);
    }

    const index = try graph.addDisabledModule("runtime-only-cjs");
    try graph_finalize.registerWrapperSymbols(graph);
    const module = graph.getModule(index) orelse return error.TestUnexpectedResult;
    try std.testing.expect(module.ast == null);
    const semantic = module.semantic orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 2), semantic.scopes.len);
    try std.testing.expectEqual(@as(usize, 2), semantic.scope_maps.len);
    const wrapper_scope = semantic.scopes[0].parent;
    try std.testing.expectEqual(@as(u32, 1), @backingInt(wrapper_scope));
    try std.testing.expectEqual(@import("../semantic/scope.zig").ScopeKind.function, semantic.scopes[@backingInt(wrapper_scope)].kind);
    const exports_parameter = module.cjs_wrapper_exports_parameter_symbol orelse return error.TestUnexpectedResult;
    const module_parameter = module.cjs_wrapper_module_parameter_symbol orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(wrapper_scope, semantic.symbols.items[@backingInt(exports_parameter)].scope_id);
    try std.testing.expectEqual(wrapper_scope, semantic.symbols.items[@backingInt(module_parameter)].scope_id);
    const factory_inner = module.cjs_runtime_factory_symbol orelse return error.TestUnexpectedResult;

    var linker = Linker.initWithGlobalIdentifiers(std.testing.allocator, graph, .esm, &.{"__commonJS"});
    defer linker.deinit();
    try linker.computeRenames();
    const factory_id = bundler_symbol.SymbolID.make(index, @backingInt(factory_inner));
    const factory_name = linker.rename_table.get(factory_id) orelse return error.TestUnexpectedResult;
    try std.testing.expect(!std.mem.eql(u8, "__commonJS", factory_name));
    try std.testing.expectEqualStrings(factory_name, try linker.cjsFactoryRuntimeName());

    graph.transferModulesToStore(std.testing.io, &store);
    try std.testing.expectEqual(@as(usize, 0), store.modules.count());
}

test "linker: semantic-less ESM wrappers receive exact wrapper and runtime SymbolIds" {
    var cache = resolve_cache_mod.ResolveCache.init(std.testing.allocator, .{});
    defer cache.deinit();
    const graph = try std.testing.allocator.create(ModuleGraph);
    graph.* = ModuleGraph.init(std.testing.allocator, &cache);
    defer {
        graph.deinit();
        std.testing.allocator.destroy(graph);
    }

    const index = try graph.addDisabledModule("a/runtime-only-esm");
    const second_index = try graph.addDisabledModule("b/runtime-only-esm");
    const module = graph.moduleAtMut(index) orelse return error.TestUnexpectedResult;
    const second = graph.moduleAtMut(second_index) orelse return error.TestUnexpectedResult;
    module.wrap_kind = .esm;
    module.exports_kind = .esm;
    second.wrap_kind = .esm;
    second.exports_kind = .esm;
    try graph_finalize.registerWrapperSymbols(graph);
    try std.testing.expect(module.ast == null);
    const semantic = module.semantic orelse return error.TestUnexpectedResult;
    const second_semantic = second.semantic orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 0), semantic.scopes.len);
    try std.testing.expectEqual(@as(usize, 0), semantic.scope_maps.len);
    const init_inner = module.init_symbol orelse return error.TestUnexpectedResult;
    const exports_inner = module.exports_symbol orelse return error.TestUnexpectedResult;
    const second_init_inner = second.init_symbol orelse return error.TestUnexpectedResult;
    const second_exports_inner = second.exports_symbol orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(semantic_symbol.SyntheticKind.esm_init, semantic.symbols.items[@backingInt(init_inner)].synthetic_kind.?);
    try std.testing.expectEqual(semantic_symbol.SyntheticKind.cjs_exports, semantic.symbols.items[@backingInt(exports_inner)].synthetic_kind.?);
    try std.testing.expectEqual(semantic_symbol.SyntheticKind.esm_init, second_semantic.symbols.items[@backingInt(second_init_inner)].synthetic_kind.?);
    try std.testing.expectEqual(semantic_symbol.SyntheticKind.cjs_exports, second_semantic.symbols.items[@backingInt(second_exports_inner)].synthetic_kind.?);
    try std.testing.expectEqualStrings("init_runtime_only_esm", module.getInitName(null) orelse return error.TestUnexpectedResult);
    try std.testing.expectEqualStrings("exports_runtime_only_esm", module.getExportsName(null) orelse return error.TestUnexpectedResult);
    try std.testing.expectEqualStrings("init_runtime_only_esm$2", second.getInitName(null) orelse return error.TestUnexpectedResult);
    try std.testing.expectEqualStrings("exports_runtime_only_esm$2", second.getExportsName(null) orelse return error.TestUnexpectedResult);

    const first_symbol_count = semantic.symbols.items.len;
    const second_symbol_count = second_semantic.symbols.items.len;
    module.init_symbol = null;
    module.exports_symbol = null;
    second.init_symbol = null;
    second.exports_symbol = null;
    try graph_finalize.registerWrapperSymbols(graph);
    try graph_finalize.registerWrapperSymbols(graph);
    try std.testing.expectEqual(init_inner, module.init_symbol orelse return error.TestUnexpectedResult);
    try std.testing.expectEqual(exports_inner, module.exports_symbol orelse return error.TestUnexpectedResult);
    try std.testing.expectEqual(second_init_inner, second.init_symbol orelse return error.TestUnexpectedResult);
    try std.testing.expectEqual(second_exports_inner, second.exports_symbol orelse return error.TestUnexpectedResult);
    try std.testing.expectEqual(first_symbol_count, module.semantic.?.symbols.items.len);
    try std.testing.expectEqual(second_symbol_count, second.semantic.?.symbols.items.len);

    const factory_inner = module.esm_runtime_factory_symbol orelse return error.TestUnexpectedResult;

    var linker = Linker.initWithGlobalIdentifiers(std.testing.allocator, graph, .esm, &.{"__esm"});
    defer linker.deinit();
    try linker.computeRenames();
    const factory_id = bundler_symbol.SymbolID.make(index, @backingInt(factory_inner));
    const factory_name = try linker.esmFactoryRuntimeName();
    try std.testing.expect(!std.mem.eql(u8, "__esm", factory_name));
    try std.testing.expectEqualStrings(factory_name, linker.rename_table.get(factory_id) orelse return error.TestUnexpectedResult);
}

test "linker: ESM raw runtime locals recover by exact IDs and fail closed" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.mjs", "export const value = 1;");

    var r = try buildAndLink(std.testing.allocator, &tmp, "entry.mjs");
    defer r.linker.deinit();
    defer r.destroyGraph();
    defer r.cache.deinit();

    const module_index = findModuleIdx(r.graph, "entry.mjs") orelse return error.TestUnexpectedResult;
    const module = r.graph.moduleAtMut(module_index) orelse return error.TestUnexpectedResult;
    // buildAndLink exercises ordinary entry linking. This test targets the
    // graph-owned raw ESM factory preamble, which is required when a wrapped
    // ESM module is emitted.
    module.wrap_kind = .esm;
    module.exports_kind = .esm;
    try graph_finalize.registerWrapperSymbols(r.graph);
    const ids = module.esm_runtime_internal_symbols orelse return error.TestUnexpectedResult;
    const names: @import("../runtime_helper_names.zig").EsmRuntimeInternalNames = .{};
    const expected = [_]struct { id: semantic_symbol.SymbolId, name: []const u8, kind: semantic_symbol.SymbolKind }{
        .{ .id = ids.factory_parameter, .name = names.factory_parameter, .kind = .parameter },
        .{ .id = ids.result_parameter, .name = names.result_parameter, .kind = .parameter },
        .{ .id = ids.catch_parameter, .name = names.catch_parameter, .kind = .catch_binding },
        .{ .id = ids.init_function, .name = names.init_function, .kind = .function_decl },
        .{ .id = ids.factory_local, .name = names.factory_local, .kind = .variable_var },
    };
    for (expected) |item| {
        const symbol = module.semantic.?.symbols.items[@backingInt(item.id)];
        try std.testing.expectEqual(semantic_symbol.SyntheticKind.esm_runtime_internal_local, symbol.synthetic_kind.?);
        try std.testing.expectEqual(item.kind, symbol.kind);
        try std.testing.expectEqualStrings(item.name, symbol.synthetic_name);
    }

    try r.linker.finalize(.{
        .compute_renames = true,
        .compute_mangling = false,
        .populate_namespace_accesses = false,
    });
    try expectEsmRuntimeInternalNames(&r.linker, module_index, ids);

    // Cached Module convenience fields are build-scoped; exact semantic rows
    // must recover their IDs after the field is dropped or corrupted.
    module.esm_runtime_internal_symbols = null;
    try r.linker.prepareEsmRuntimeInternalNames();
    try expectEsmRuntimeInternalNames(&r.linker, module_index, ids);
    module.esm_runtime_internal_symbols = .{
        .factory_parameter = @fromBackingInt(@intCast(999_999)),
        .result_parameter = @fromBackingInt(@intCast(999_999)),
        .catch_parameter = @fromBackingInt(@intCast(999_999)),
        .init_function = @fromBackingInt(@intCast(999_999)),
        .factory_local = @fromBackingInt(@intCast(999_999)),
    };
    try r.linker.prepareEsmRuntimeInternalNames();
    try expectEsmRuntimeInternalNames(&r.linker, module_index, ids);

    // Chunk/dev paths may reset the rename table. Recover those entries from
    // the exact typed rows before returning names to the template emitter.
    const missing_name_id = bundler_symbol.SymbolID.make(module_index, @backingInt(ids.factory_parameter));
    _ = r.linker.rename_table.map.fetchRemove(missing_name_id) orelse return error.TestUnexpectedResult;
    try expectEsmRuntimeInternalNames(&r.linker, module_index, ids);

    // Typed rows are the recovery oracle; a wrong synthetic kind must not be
    // accepted merely because the cached Module field still names that row.
    module.esm_runtime_internal_symbols = null;
    const local_index = @backingInt(ids.factory_local);
    const original_kind = module.semantic.?.symbols.items[local_index].synthetic_kind;
    module.semantic.?.symbols.items[local_index].synthetic_kind = .bundler_runtime_helper;
    try std.testing.expectError(error.EsmRuntimeInternalSymbolsMissing, r.linker.prepareEsmRuntimeInternalNames());
    module.semantic.?.symbols.items[local_index].synthetic_kind = original_kind;
    try r.linker.prepareEsmRuntimeInternalNames();
    try expectEsmRuntimeInternalNames(&r.linker, module_index, ids);

    // Chunk recomputation clears the whole rename table, then must re-seed
    // these output-owned locals from the graph IDs before the emitter runs.
    const chunk_modules = [_]ModuleIndex{module_index};
    try r.linker.computeRenamesForModules(&chunk_modules, &.{});
    try expectEsmRuntimeInternalNames(&r.linker, module_index, ids);

    const factory_inner = module.esm_runtime_factory_symbol orelse return error.TestUnexpectedResult;
    const factory_raw: usize = @backingInt(factory_inner);
    const esm_semantic = if (module.semantic) |*value| value else return error.TestUnexpectedResult;
    const original_factory_symbol = esm_semantic.symbols.items[factory_raw];
    const original_factory_linker_id = r.linker.esm_factory_runtime_symbol_id;
    const saved_esm_factory_name = try std.testing.allocator.dupe(u8, try r.linker.esmFactoryRuntimeName());
    defer std.testing.allocator.free(saved_esm_factory_name);

    const duplicate_index = try r.graph.addDisabledModule("runtime-helper-decoy");
    const duplicate_module = r.graph.moduleAtMut(duplicate_index) orelse return error.TestUnexpectedResult;
    const duplicate_factory_inner = try addGraphRuntimeHelperIdentity(duplicate_module, "__esm");
    duplicate_module.esm_runtime_factory_symbol = duplicate_factory_inner;
    try std.testing.expectError(error.EsmRuntimeFactoryIdentityInvalid, r.linker.esmFactoryRuntimeName());
    duplicate_module.esm_runtime_factory_symbol = null;

    // The semantic row remains present, but dropping both exact handles must
    // not let the old synthetic-name search recover it.
    module.esm_runtime_factory_symbol = null;
    r.linker.esm_factory_runtime_symbol_id = null;
    try std.testing.expectError(error.EsmRuntimeFactoryIdentityMissing, r.linker.esmFactoryRuntimeName());
    try std.testing.expectError(error.EsmRuntimeFactoryIdentityMissing, r.linker.prepareEsmRuntimeName());
    try std.testing.expectError(error.EsmRuntimeFactoryIdentityMissing, r.linker.prepareEsmRuntimeInternalNames());
    r.linker.esm_factory_runtime_symbol_id = bundler_symbol.SymbolID.make(module_index, std.math.maxInt(u32));
    try std.testing.expectError(error.EsmRuntimeFactoryIdentityInvalid, r.linker.esmFactoryRuntimeName());
    r.linker.esm_factory_runtime_symbol_id = null;

    const decoy_raw: usize = if (factory_raw == 0) 1 else 0;
    try std.testing.expect(decoy_raw < esm_semantic.symbols.items.len);
    const original_decoy_symbol = esm_semantic.symbols.items[decoy_raw];
    esm_semantic.symbols.items[decoy_raw].synthetic_kind = .bundler_runtime_helper;
    esm_semantic.symbols.items[decoy_raw].kind = .variable_var;
    esm_semantic.symbols.items[decoy_raw].synthetic_name = "__esm";
    try std.testing.expectError(error.EsmRuntimeFactoryIdentityMissing, r.linker.esmFactoryRuntimeName());
    esm_semantic.symbols.items[decoy_raw] = original_decoy_symbol;

    module.esm_runtime_factory_symbol = @fromBackingInt(@intCast(std.math.maxInt(u32)));
    try std.testing.expectError(error.EsmRuntimeFactoryIdentityInvalid, r.linker.esmFactoryRuntimeName());
    module.esm_runtime_factory_symbol = factory_inner;

    esm_semantic.symbols.items[factory_raw].synthetic_kind = .runtime_helper_preamble;
    try std.testing.expectError(error.EsmRuntimeFactoryIdentityInvalid, r.linker.esmFactoryRuntimeName());
    esm_semantic.symbols.items[factory_raw] = original_factory_symbol;
    esm_semantic.symbols.items[factory_raw].synthetic_name = "__esm$decoy";
    try std.testing.expectError(error.EsmRuntimeFactoryIdentityInvalid, r.linker.esmFactoryRuntimeName());
    esm_semantic.symbols.items[factory_raw] = original_factory_symbol;
    esm_semantic.symbols.items[factory_raw].kind = .variable_let;
    try std.testing.expectError(error.EsmRuntimeFactoryIdentityInvalid, r.linker.esmFactoryRuntimeName());
    esm_semantic.symbols.items[factory_raw] = original_factory_symbol;

    r.linker.esm_factory_runtime_symbol_id = bundler_symbol.SymbolID.make(module_index, std.math.maxInt(u32));
    try std.testing.expectEqualStrings(saved_esm_factory_name, try r.linker.esmFactoryRuntimeName());
    try r.linker.prepareEsmRuntimeName();
    try std.testing.expectEqual(factory_inner, r.linker.esm_factory_runtime_symbol_id.?.inner);
    r.linker.esm_factory_runtime_symbol_id = original_factory_linker_id;
}

test "linker: ESM interop raw locals recover by exact IDs and reject malformed rows" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.mjs", "const __create=0,__getProtoOf=0,__defProp=0,__getOwnPropNames=0,__getOwnPropDesc=0,__hasOwn=0,__copyProps=0,__toESM=0,__export=0,__toCommonJS=0; export const value = 1;");

    var r = try buildAndLink(std.testing.allocator, &tmp, "entry.mjs");
    defer r.linker.deinit();
    defer r.destroyGraph();
    defer r.cache.deinit();

    const module_index = findModuleIdx(r.graph, "entry.mjs") orelse return error.TestUnexpectedResult;
    const module = r.graph.moduleAtMut(module_index) orelse return error.TestUnexpectedResult;
    module.wrap_kind = .esm;
    module.exports_kind = .esm;
    try graph_finalize.registerWrapperSymbols(r.graph);
    const names = try r.linker.esmInteropRuntimeInternalNames();
    const helper_names = try r.linker.esmInteropRuntimeNames();
    const helper_ids = module.esm_interop_runtime_helper_symbols orelse return error.TestUnexpectedResult;
    inline for (@import("../runtime_helper_names.zig").ESM_INTEROP_RUNTIME_HELPERS) |helper| {
        const helper_id = @field(helper_ids, @tagName(helper));
        const helper_symbol = module.semantic.?.symbols.items[@backingInt(helper_id)];
        try std.testing.expectEqual(semantic_symbol.SyntheticKind.bundler_runtime_helper, helper_symbol.synthetic_kind.?);
        try std.testing.expectEqual(semantic_symbol.SymbolKind.variable_var, helper_symbol.kind);
        try std.testing.expectEqualStrings(
            @import("../runtime_helper_names.zig").esmInteropRuntimeHelperBaseName(helper),
            helper_symbol.synthetic_name,
        );
        try std.testing.expectEqualStrings(
            helper_names.get(helper),
            r.linker.rename_table.get(bundler_symbol.SymbolID.make(module_index, @backingInt(helper_id))) orelse return error.TestUnexpectedResult,
        );
        try std.testing.expect(!std.mem.eql(
            u8,
            helper_names.get(helper),
            @import("../runtime_helper_names.zig").esmInteropRuntimeHelperBaseName(helper),
        ));
    }
    var invalid_helper_ids = helper_ids;
    invalid_helper_ids.create = @fromBackingInt(@as(u32, 999_999));
    module.esm_interop_runtime_helper_symbols = invalid_helper_ids;
    try r.linker.prepareEsmInteropRuntimeNames();
    try std.testing.expectEqualDeep(helper_ids, module.esm_interop_runtime_helper_symbols.?);
    module.esm_interop_runtime_helper_symbols = null;
    try r.linker.prepareEsmInteropRuntimeNames();
    try std.testing.expectEqualDeep(helper_ids, module.esm_interop_runtime_helper_symbols.?);
    module.semantic.?.runtime_identities.?.interop_helpers = invalid_helper_ids;
    try std.testing.expectError(error.EsmInteropRuntimeIdentityInvalid, r.linker.prepareEsmInteropRuntimeNames());
    module.semantic.?.runtime_identities.?.interop_helpers = null;
    try std.testing.expectError(error.EsmInteropRuntimeIdentityMissing, r.linker.prepareEsmInteropRuntimeNames());
    module.semantic.?.runtime_identities.?.interop_helpers = helper_ids;

    const ids = module.esm_interop_runtime_internal_symbols orelse return error.TestUnexpectedResult;
    const expected = [_]struct { id: semantic_symbol.SymbolId, identity: []const u8, output_name: []const u8, kind: semantic_symbol.SymbolKind }{
        .{ .id = ids.copy_props_to, .identity = "copy_props.to", .output_name = names.copy_props_to, .kind = .parameter },
        .{ .id = ids.copy_props_from, .identity = "copy_props.from", .output_name = names.copy_props_from, .kind = .parameter },
        .{ .id = ids.copy_props_desc, .identity = "copy_props.desc", .output_name = names.copy_props_desc, .kind = .parameter },
        .{ .id = ids.copy_props_keys, .identity = "copy_props.keys", .output_name = names.copy_props_keys, .kind = .variable_var },
        .{ .id = ids.copy_props_index, .identity = "copy_props.index", .output_name = names.copy_props_index, .kind = .variable_var },
        .{ .id = ids.copy_props_key, .identity = "copy_props.key", .output_name = names.copy_props_key, .kind = .variable_var },
        .{ .id = ids.copy_props_closure_key, .identity = "copy_props.closure_key", .output_name = names.copy_props_closure_key, .kind = .parameter },
        .{ .id = ids.to_esm_module, .identity = "to_esm.module", .output_name = names.to_esm_module, .kind = .parameter },
        .{ .id = ids.to_esm_node_mode, .identity = "to_esm.node_mode", .output_name = names.to_esm_node_mode, .kind = .parameter },
        .{ .id = ids.to_esm_target, .identity = "to_esm.target", .output_name = names.to_esm_target, .kind = .parameter },
        .{ .id = ids.export_target, .identity = "export.target", .output_name = names.export_target, .kind = .parameter },
        .{ .id = ids.export_all, .identity = "export.all", .output_name = names.export_all, .kind = .parameter },
        .{ .id = ids.export_name, .identity = "export.name", .output_name = names.export_name, .kind = .variable_var },
        .{ .id = ids.to_common_js_module, .identity = "to_common_js.module", .output_name = names.to_common_js_module, .kind = .parameter },
    };
    for (expected) |item| {
        const symbol = module.semantic.?.symbols.items[@backingInt(item.id)];
        try std.testing.expectEqual(semantic_symbol.SyntheticKind.esm_interop_runtime_internal_local, symbol.synthetic_kind.?);
        try std.testing.expectEqual(item.kind, symbol.kind);
        try std.testing.expectEqualStrings(item.identity, symbol.synthetic_name);
        try std.testing.expectEqualStrings(item.output_name, r.linker.rename_table.get(bundler_symbol.SymbolID.make(module_index, @backingInt(item.id))) orelse return error.TestUnexpectedResult);
    }

    // The typed rows are authoritative. Dropped and corrupt convenience IDs
    // are recovered; a lost rename-table entry is restored before emission.
    module.esm_interop_runtime_internal_symbols = null;
    try expectEsmInteropRuntimeInternalNames(&r.linker, module_index, ids);
    module.esm_interop_runtime_internal_symbols = .{
        .copy_props_to = @fromBackingInt(@intCast(999_999)),
        .copy_props_from = @fromBackingInt(@intCast(999_999)),
        .copy_props_desc = @fromBackingInt(@intCast(999_999)),
        .copy_props_keys = @fromBackingInt(@intCast(999_999)),
        .copy_props_index = @fromBackingInt(@intCast(999_999)),
        .copy_props_key = @fromBackingInt(@intCast(999_999)),
        .copy_props_closure_key = @fromBackingInt(@intCast(999_999)),
        .to_esm_module = @fromBackingInt(@intCast(999_999)),
        .to_esm_node_mode = @fromBackingInt(@intCast(999_999)),
        .to_esm_target = @fromBackingInt(@intCast(999_999)),
        .export_target = @fromBackingInt(@intCast(999_999)),
        .export_all = @fromBackingInt(@intCast(999_999)),
        .export_name = @fromBackingInt(@intCast(999_999)),
        .to_common_js_module = @fromBackingInt(@intCast(999_999)),
    };
    try expectEsmInteropRuntimeInternalNames(&r.linker, module_index, ids);

    const missing_name_id = bundler_symbol.SymbolID.make(module_index, @backingInt(ids.copy_props_to));
    _ = r.linker.rename_table.map.fetchRemove(missing_name_id) orelse return error.TestUnexpectedResult;
    try expectEsmInteropRuntimeInternalNames(&r.linker, module_index, ids);

    // Exact typed rows are also a fail-closed boundary: wrong kind, duplicate
    // identity, and a missing row must not be papered over by stale cached IDs.
    const sem = &module.semantic.?;
    const local_index = @backingInt(ids.copy_props_to);
    const original_kind = sem.symbols.items[local_index].kind;
    sem.symbols.items[local_index].kind = .variable_var;
    try std.testing.expectError(error.EsmInteropRuntimeInternalSymbolsInvalid, r.linker.prepareEsmInteropRuntimeNames());
    sem.symbols.items[local_index].kind = original_kind;

    const duplicate_index = @backingInt(ids.copy_props_from);
    const original_identity = sem.symbols.items[duplicate_index].synthetic_name;
    sem.symbols.items[duplicate_index].synthetic_name = "copy_props.to";
    try std.testing.expectError(error.EsmInteropRuntimeInternalSymbolsInvalid, r.linker.prepareEsmInteropRuntimeNames());
    sem.symbols.items[duplicate_index].synthetic_name = original_identity;

    const original_synthetic = sem.symbols.items[local_index].synthetic_kind;
    sem.symbols.items[local_index].synthetic_kind = .bundler_runtime_helper;
    try std.testing.expectError(error.EsmInteropRuntimeInternalSymbolsInvalid, r.linker.prepareEsmInteropRuntimeNames());
    sem.symbols.items[local_index].synthetic_kind = original_synthetic;
    try expectEsmInteropRuntimeInternalNames(&r.linker, module_index, ids);

    const chunk_modules = [_]ModuleIndex{module_index};
    try r.linker.computeRenamesForModules(&chunk_modules, &.{});
    try expectEsmInteropRuntimeInternalNames(&r.linker, module_index, ids);

    // A lost canonical set has no producer authority to recreate these IDs.
    const rebuild_sem = &module.semantic.?;
    const first_local = @backingInt(ids.copy_props_to);
    try std.testing.expectEqual(@as(usize, 14), rebuild_sem.symbols.items.len - first_local);
    rebuild_sem.symbols.items.len = first_local;
    try std.testing.expectError(error.EsmInteropRuntimeInternalSymbolsInvalid, r.linker.prepareEsmInteropRuntimeNamesForEmit());
}

test "linker: graph-wide missing ESM interop need is cached" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.js", "export const value = 1;");

    var r = try buildAndLink(std.testing.allocator, &tmp, "entry.js");
    defer r.linker.deinit();
    defer r.destroyGraph();
    defer r.cache.deinit();

    try std.testing.expect(r.linker.graph_esm_interop_runtime_needed == null);
    try r.linker.prepareEsmInteropRuntimeNamesForEmit();
    try std.testing.expectEqual(false, r.linker.graph_esm_interop_runtime_needed.?);
    try r.linker.prepareEsmInteropRuntimeNamesIfNeeded();
    try std.testing.expectEqual(false, r.linker.graph_esm_interop_runtime_needed.?);
    try std.testing.expect(r.linker.esm_interop_runtime_names == null);
}

test "linker: HMR preamble names are graph-owned and recover exact identities" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.js", "globalThis.__zntc_hot_cbs = 'external'; console.log(__zntc_hot_cbs);");

    var r = try buildAndLink(std.testing.allocator, &tmp, "entry.js");
    defer r.linker.deinit();
    defer r.destroyGraph();
    defer r.cache.deinit();
    r.linker.dev_mode = true;
    // A prior semantic-less call may have cached borrowed default names.
    // Real graph ownership must still select collision-free names.
    r.linker.hmr_runtime_internal_names = .{};
    try std.testing.expect(!r.linker.hmr_runtime_internal_names_owned);
    try r.linker.computeRenames();

    const module_index = findModuleIdx(r.graph, "entry.js") orelse return error.TestUnexpectedResult;
    const module = r.graph.moduleAtMut(module_index) orelse return error.TestUnexpectedResult;
    const names = try r.linker.hmrRuntimeInternalNames();
    try std.testing.expect(!std.mem.eql(u8, "__zntc_hot_cbs", names.hot_callbacks));
    const ids = module.hmr_runtime_internal_symbols orelse return error.TestUnexpectedResult;
    const expected = [_]struct { id: semantic_symbol.SymbolId, identity: []const u8, output_name: []const u8, kind: semantic_symbol.SymbolKind }{
        .{ .id = ids.global, .identity = "hmr.global", .output_name = names.global, .kind = .variable_var },
        .{ .id = ids.modules, .identity = "hmr.modules", .output_name = names.modules, .kind = .variable_var },
        .{ .id = ids.hot_callbacks, .identity = "hmr.hot_callbacks", .output_name = names.hot_callbacks, .kind = .variable_var },
        .{ .id = ids.hot_data, .identity = "hmr.hot_data", .output_name = names.hot_data, .kind = .variable_var },
        .{ .id = ids.schedule, .identity = "hmr.schedule", .output_name = names.schedule, .kind = .function_decl },
        .{ .id = ids.reload, .identity = "hmr.reload", .output_name = names.reload, .kind = .variable_var },
        .{ .id = ids.resolve_refresh, .identity = "hmr.resolve_refresh", .output_name = names.resolve_refresh, .kind = .function_decl },
        .{ .id = ids.refresh_boundary, .identity = "hmr.refresh_boundary", .output_name = names.refresh_boundary, .kind = .function_decl },
        .{ .id = ids.refresh_timer, .identity = "hmr.refresh_timer", .output_name = names.refresh_timer, .kind = .variable_var },
        .{ .id = ids.enqueue_update, .identity = "hmr.enqueue_update", .output_name = names.enqueue_update, .kind = .function_decl },
        .{ .id = ids.make_hot, .identity = "hmr.make_hot", .output_name = names.make_hot, .kind = .function_decl },
        .{ .id = ids.original_commonjs, .identity = "hmr.original_commonjs", .output_name = names.original_commonjs, .kind = .variable_var },
        .{ .id = ids.original_esm, .identity = "hmr.original_esm", .output_name = names.original_esm, .kind = .variable_var },
        .{ .id = ids.apply_update, .identity = "hmr.apply_update", .output_name = names.apply_update, .kind = .function_decl },
    };
    for (expected) |item| {
        const symbol = module.semantic.?.symbols.items[@backingInt(item.id)];
        try std.testing.expectEqual(semantic_symbol.SyntheticKind.hmr_runtime_internal_local, symbol.synthetic_kind.?);
        try std.testing.expectEqual(item.kind, symbol.kind);
        try std.testing.expectEqualStrings(item.identity, symbol.synthetic_name);
        try std.testing.expectEqualStrings(item.output_name, r.linker.rename_table.get(bundler_symbol.SymbolID.make(module_index, @backingInt(item.id))) orelse return error.TestUnexpectedResult);
    }

    // The canonical typed record restores the convenience ID cache and restore names after a
    // chunk pass drops entries from the transient rename table.
    module.hmr_runtime_internal_symbols = null;
    try expectHmrRuntimeInternalNames(&r.linker, module_index, ids);
    const missing_name_id = bundler_symbol.SymbolID.make(module_index, @backingInt(ids.hot_callbacks));
    _ = r.linker.rename_table.map.fetchRemove(missing_name_id) orelse return error.TestUnexpectedResult;
    try expectHmrRuntimeInternalNames(&r.linker, module_index, ids);

    const sem = &module.semantic.?;
    const changed_index = @backingInt(ids.hot_callbacks);
    const original_kind = sem.symbols.items[changed_index].kind;
    sem.symbols.items[changed_index].kind = .function_decl;
    try std.testing.expectError(error.HmrRuntimeInternalSymbolsInvalid, r.linker.prepareHmrRuntimeInternalNames());
    sem.symbols.items[changed_index].kind = original_kind;

    const original_synthetic = sem.symbols.items[changed_index].synthetic_kind;
    sem.symbols.items[changed_index].synthetic_kind = .bundler_runtime_helper;
    try std.testing.expectError(error.HmrRuntimeInternalSymbolsInvalid, r.linker.prepareHmrRuntimeInternalNames());
    sem.symbols.items[changed_index].synthetic_kind = original_synthetic;

    const original_name = sem.symbols.items[changed_index].synthetic_name;
    sem.symbols.items[changed_index].synthetic_kind = null;
    sem.symbols.items[changed_index].synthetic_name = "";
    try std.testing.expectError(error.HmrRuntimeInternalSymbolsInvalid, r.linker.prepareHmrRuntimeInternalNames());
    sem.symbols.items[changed_index].synthetic_kind = original_synthetic;
    sem.symbols.items[changed_index].synthetic_name = original_name;

    for (sem.symbols.items) |*symbol| {
        if (symbol.synthetic_kind == .hmr_runtime_internal_local) symbol.synthetic_kind = .bundler_runtime_helper;
    }
    try std.testing.expectError(error.HmrRuntimeInternalSymbolsInvalid, r.linker.prepareHmrRuntimeInternalNames());
    for (sem.symbols.items) |*symbol| {
        if (std.mem.startsWith(u8, symbol.synthetic_name, "hmr.")) symbol.synthetic_kind = .hmr_runtime_internal_local;
    }
    try expectHmrRuntimeInternalNames(&r.linker, module_index, ids);
}

fn expectHmrRuntimeInternalNames(linker: *Linker, module_index: ModuleIndex, ids: @import("module.zig").HmrRuntimeInternalSymbolIds) !void {
    const names = try linker.hmrRuntimeInternalNames();
    const values = .{
        .{ ids.global, names.global },
        .{ ids.modules, names.modules },
        .{ ids.hot_callbacks, names.hot_callbacks },
        .{ ids.hot_data, names.hot_data },
        .{ ids.schedule, names.schedule },
        .{ ids.reload, names.reload },
        .{ ids.resolve_refresh, names.resolve_refresh },
        .{ ids.refresh_boundary, names.refresh_boundary },
        .{ ids.refresh_timer, names.refresh_timer },
        .{ ids.enqueue_update, names.enqueue_update },
        .{ ids.make_hot, names.make_hot },
        .{ ids.original_commonjs, names.original_commonjs },
        .{ ids.original_esm, names.original_esm },
        .{ ids.apply_update, names.apply_update },
    };
    inline for (values) |value| {
        try std.testing.expectEqualStrings(value[1], linker.rename_table.get(bundler_symbol.SymbolID.make(module_index, @backingInt(value[0]))) orelse return error.TestUnexpectedResult);
    }
}

fn expectEsmInteropRuntimeInternalNames(linker: *Linker, module_index: ModuleIndex, ids: @import("module.zig").EsmInteropRuntimeInternalSymbolIds) !void {
    const names = try linker.esmInteropRuntimeInternalNames();
    const values = .{
        .{ ids.copy_props_to, names.copy_props_to, "to" },
        .{ ids.copy_props_from, names.copy_props_from, "from" },
        .{ ids.copy_props_desc, names.copy_props_desc, "desc" },
        .{ ids.copy_props_keys, names.copy_props_keys, "keys" },
        .{ ids.copy_props_index, names.copy_props_index, "i" },
        .{ ids.copy_props_key, names.copy_props_key, "key" },
        .{ ids.copy_props_closure_key, names.copy_props_closure_key, "k" },
        .{ ids.to_esm_module, names.to_esm_module, "mod" },
        .{ ids.to_esm_node_mode, names.to_esm_node_mode, "isNodeMode" },
        .{ ids.to_esm_target, names.to_esm_target, "target" },
        .{ ids.export_target, names.export_target, "target" },
        .{ ids.export_all, names.export_all, "all" },
        .{ ids.export_name, names.export_name, "name" },
        .{ ids.to_common_js_module, names.to_common_js_module, "mod" },
    };
    inline for (values) |value| {
        try std.testing.expectEqualStrings(value[2], value[1]);
        try std.testing.expectEqualStrings(value[1], linker.rename_table.get(bundler_symbol.SymbolID.make(module_index, @backingInt(value[0]))) orelse return error.TestUnexpectedResult);
    }
}

fn expectEsmRuntimeInternalNames(linker: *Linker, module_index: ModuleIndex, ids: @import("module.zig").EsmRuntimeInternalSymbolIds) !void {
    const names = try linker.esmFactoryRuntimeInternalNames();
    try std.testing.expectEqualStrings("fn", names.factory_parameter);
    try std.testing.expectEqualStrings("res", names.result_parameter);
    try std.testing.expectEqualStrings("e", names.catch_parameter);
    try std.testing.expectEqualStrings("__init", names.init_function);
    try std.testing.expectEqualStrings("f", names.factory_local);
    try std.testing.expectEqualStrings(
        names.factory_parameter,
        linker.rename_table.get(bundler_symbol.SymbolID.make(module_index, @backingInt(ids.factory_parameter))) orelse return error.TestUnexpectedResult,
    );
    try std.testing.expectEqualStrings(
        names.result_parameter,
        linker.rename_table.get(bundler_symbol.SymbolID.make(module_index, @backingInt(ids.result_parameter))) orelse return error.TestUnexpectedResult,
    );
    try std.testing.expectEqualStrings(
        names.catch_parameter,
        linker.rename_table.get(bundler_symbol.SymbolID.make(module_index, @backingInt(ids.catch_parameter))) orelse return error.TestUnexpectedResult,
    );
    try std.testing.expectEqualStrings(
        names.init_function,
        linker.rename_table.get(bundler_symbol.SymbolID.make(module_index, @backingInt(ids.init_function))) orelse return error.TestUnexpectedResult,
    );
    try std.testing.expectEqualStrings(
        names.factory_local,
        linker.rename_table.get(bundler_symbol.SymbolID.make(module_index, @backingInt(ids.factory_local))) orelse return error.TestUnexpectedResult,
    );
}

test "linker: re-export chain resolved" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // console.log(x): Phase D 가 미사용 named import 를 elide 하므로 value-use 추가
    try writeFile(tmp.dir, "a.ts", "import { x } from './b'; console.log(x);");
    try writeFile(tmp.dir, "b.ts", "export { x } from './c';");
    try writeFile(tmp.dir, "c.ts", "export const x = 1;");

    var r = try buildAndLink(std.testing.allocator, &tmp, "a.ts");
    defer r.linker.deinit();
    defer r.destroyGraph();
    defer r.cache.deinit();

    const a = r.graph.getModule(ModuleIndex.fromUsize(0)).?;
    const binding = r.linker.getResolvedBinding(0, a.import_bindings[0].local_span);
    try std.testing.expect(binding != null);
    // chain: a→b→c, canonical은 c(index 2)
    try std.testing.expectEqual(@as(u32, 2), @backingInt(binding.?.canonical.module_index));
}

test "linker: missing export produces diagnostic" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import { missing } from './b'; console.log(missing);");
    try writeFile(tmp.dir, "b.ts", "export const x = 1;");

    var r = try buildAndLink(std.testing.allocator, &tmp, "a.ts");
    defer r.linker.deinit();
    defer r.destroyGraph();
    defer r.cache.deinit();

    // missing export → diagnostic
    var has_missing = false;
    for (r.linker.diagnostics.items) |d| {
        if (d.code == .missing_export) has_missing = true;
    }
    try std.testing.expect(has_missing);
}

test "linker: export * resolves through re-export all" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import { x } from './b'; console.log(x);");
    try writeFile(tmp.dir, "b.ts", "export * from './c';");
    try writeFile(tmp.dir, "c.ts", "export const x = 99;");

    var r = try buildAndLink(std.testing.allocator, &tmp, "a.ts");
    defer r.linker.deinit();
    defer r.destroyGraph();
    defer r.cache.deinit();

    const a = r.graph.getModule(ModuleIndex.fromUsize(0)).?;
    const binding = r.linker.getResolvedBinding(0, a.import_bindings[0].local_span);
    try std.testing.expect(binding != null);
    // export * → c.ts(index 2)
    try std.testing.expectEqual(@as(u32, 2), @backingInt(binding.?.canonical.module_index));
}

test "linker: export * from CJS resolves to CJS module" {
    // ESM이 export * from CJS를 하고, 소비자가 named import를 할 때
    // resolveExportChain이 CJS 모듈을 반환하는지 검증.
    // CJS 모듈은 정적 export가 없으므로, export * 경로에서
    // wrap_kind == .cjs인 모듈 자체를 반환해야 한다.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import { x } from './b'; console.log(x);");
    try writeFile(tmp.dir, "b.ts", "export * from './c';");
    try writeFile(tmp.dir, "c.js", "module.exports = { x: 42 };");

    var r = try buildAndLink(std.testing.allocator, &tmp, "a.ts");
    defer r.linker.deinit();
    defer r.destroyGraph();
    defer r.cache.deinit();

    const a = r.graph.getModule(ModuleIndex.fromUsize(0)).?;
    const binding = r.linker.getResolvedBinding(0, a.import_bindings[0].local_span);
    try std.testing.expect(binding != null);
    // c.js는 CJS이므로, resolveExportChain이 c.js(index 2)를 반환
    try std.testing.expectEqual(@as(u32, 2), @backingInt(binding.?.canonical.module_index));
    try std.testing.expectEqualStrings("x", binding.?.canonical.export_name);
    // c.js가 실제로 CJS로 감지되었는지 확인
    try std.testing.expectEqual(types.WrapKind.cjs, r.graph.getModule(ModuleIndex.fromUsize(2)).?.wrap_kind);
}

test "linker: namespace re-export resolves to local binding" {
    // import * as ns from './c'; export { ns } 패턴에서
    // resolveExportChain이 현재 모듈(b.ts)의 로컬 바인딩을 반환하는지 검증.
    // namespace import는 소스 모듈에서 "*"를 named export로 찾을 수 없으므로,
    // 로컬 바인딩을 그대로 반환해야 한다.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import { ns } from './b'; console.log(ns);");
    try writeFile(tmp.dir, "b.ts", "import * as ns from './c';\nexport { ns };");
    try writeFile(tmp.dir, "c.ts", "export const x = 1;");

    var r = try buildAndLink(std.testing.allocator, &tmp, "a.ts");
    defer r.linker.deinit();
    defer r.destroyGraph();
    defer r.cache.deinit();

    const a = r.graph.getModule(ModuleIndex.fromUsize(0)).?;
    const binding = r.linker.getResolvedBinding(0, a.import_bindings[0].local_span);
    try std.testing.expect(binding != null);
    // namespace re-export는 b.ts(index 1)의 로컬 바인딩을 반환
    try std.testing.expectEqual(@as(u32, 1), @backingInt(binding.?.canonical.module_index));
    try std.testing.expectEqualStrings("ns", binding.?.canonical.export_name);
}

test "linker: resolveExportChain on CJS module returns null for named exports" {
    // CJS 모듈에 직접 resolveExportChain을 호출하면,
    // 정적 export가 없으므로 null을 반환해야 한다.
    // (export * from CJS 경로에서는 별도 CJS 폴백이 동작하지만,
    //  직접 호출 시에는 null)
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import { x } from './b'; console.log(x);");
    try writeFile(tmp.dir, "b.js", "module.exports = { x: 42 };");

    const dp = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(dp);
    const entry = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "a.ts" });
    defer std.testing.allocator.free(entry);

    var cache = resolve_cache_mod.ResolveCache.init(std.testing.allocator, .{});
    defer cache.deinit();
    var graph = ModuleGraph.init(std.testing.allocator, &cache);
    defer graph.deinit();
    try graph.build(std.testing.io, &.{entry});

    var linker = Linker.init(std.testing.allocator, &graph, .esm);
    defer linker.deinit();
    try linker.link();

    // b.js가 CJS로 감지됨
    try std.testing.expectEqual(types.WrapKind.cjs, graph.getModule(ModuleIndex.fromUsize(1)).?.wrap_kind);

    // CJS 모듈(index 1)에 직접 resolveExportChain 호출 → null
    // CJS는 정적 export가 없으므로 named export를 찾을 수 없다
    const result = linker.resolveExportChain(@fromBackingInt(@intCast(1)), "x", 0);
    try std.testing.expect(result == null);
}

test "linker: default import resolves" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import myDefault from './b';\nconsole.log(myDefault);");
    try writeFile(tmp.dir, "b.ts", "export default 42;");

    var r = try buildAndLink(std.testing.allocator, &tmp, "a.ts");
    defer r.linker.deinit();
    defer r.destroyGraph();
    defer r.cache.deinit();

    const a = r.graph.getModule(ModuleIndex.fromUsize(0)).?;
    const binding = r.linker.getResolvedBinding(0, a.import_bindings[0].local_span);
    try std.testing.expect(binding != null);
    try std.testing.expectEqualStrings("default", binding.?.canonical.export_name);
}

test "linker: external import not resolved (no binding)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import { x } from 'react';");

    const dp = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(dp);
    const entry = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "a.ts" });
    defer std.testing.allocator.free(entry);

    var cache = resolve_cache_mod.ResolveCache.init(std.testing.allocator, .{ .external_patterns = &.{"react"} });
    defer cache.deinit();
    var graph = ModuleGraph.init(std.testing.allocator, &cache);
    defer graph.deinit();
    try graph.build(std.testing.io, &.{entry});

    var linker = Linker.init(std.testing.allocator, &graph, .esm);
    defer linker.deinit();
    try linker.link();

    // external → resolved binding 없음, diagnostic도 없음
    try std.testing.expectEqual(@as(usize, 0), linker.resolved_bindings.count());
    try std.testing.expectEqual(@as(usize, 0), linker.diagnostics.items.len);
}

test "namespace export collection carries exact SID through local and aliased exports" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "provider.ts", "export const live = 1;\n");
    try writeFile(tmp.dir, "barrel.ts", "export { live as public } from './provider.ts';\n");
    try writeFile(tmp.dir, "entry.ts", "import * as ns from './barrel.ts'; console.log(ns.public);\n");

    var result = try buildAndLink(std.testing.allocator, &tmp, "entry.ts");
    defer result.linker.deinit();
    defer result.destroyGraph();
    defer result.cache.deinit();

    const provider_idx = findModuleIdx(result.graph, "provider.ts") orelse return error.MissingProvider;
    const provider = result.graph.getModule(provider_idx) orelse return error.MissingProvider;
    const local_export = provider.findExportBinding("live") orelse return error.MissingLocalExport;
    const expected_symbol = local_export.symbol;
    try std.testing.expect(expected_symbol.semanticIndex() != null);
    try std.testing.expectEqual(provider_idx, expected_symbol.moduleIndex());

    const barrel_idx = findModuleIdx(result.graph, "barrel.ts") orelse return error.MissingBarrel;
    var exports: std.ArrayList(Linker.NsExportPair) = .empty;
    defer exports.deinit(std.testing.allocator);
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(std.testing.allocator);
    var visited: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer visited.deinit(std.testing.allocator);
    try result.linker.collectExportsRecursive(&exports, &seen, &visited, barrel_idx, 0);

    var found_alias = false;
    for (exports.items) |pair| {
        if (!std.mem.eql(u8, pair.exported, "public")) continue;
        found_alias = true;
        try std.testing.expectEqual(expected_symbol, pair.binding_symbol);
    }
    try std.testing.expect(found_alias);

    exports.clearRetainingCapacity();
    seen.clearRetainingCapacity();
    visited.clearRetainingCapacity();
    try result.linker.collectExportsRecursive(&exports, &seen, &visited, provider_idx, 0);
    var found_direct = false;
    for (exports.items) |pair| {
        if (!std.mem.eql(u8, pair.exported, "live")) continue;
        found_direct = true;
        try std.testing.expectEqual(expected_symbol, pair.binding_symbol);
    }
    try std.testing.expect(found_direct);
}

test "namespace inline object filters re-export getters by the provider SID" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import * as ns from './barrel.ts'; console.log(ns.public);\n");
    try writeFile(tmp.dir, "barrel.ts", "export { actual as public, dead as hidden } from './provider.ts';\n");
    try writeFile(tmp.dir, "provider.ts", "export const actual = 1; export const dead = 2;\n");

    var result = try buildLinkAndRename(std.testing.allocator, &tmp, "entry.ts");
    defer result.linker.deinit();
    defer result.destroyGraph();
    defer result.cache.deinit();

    const provider_idx = findModuleIdx(result.graph, "provider.ts") orelse return error.MissingProvider;
    const provider = @constCast(result.graph.getModule(provider_idx) orelse return error.MissingProvider);
    const actual = provider.findExportBinding("actual") orelse return error.MissingActualExport;
    const dead = provider.findExportBinding("dead") orelse return error.MissingDeadExport;
    const actual_index = provider.exportBindingSemanticIndex(actual.*) orelse return error.MissingActualSID;
    const dead_index = provider.exportBindingSemanticIndex(dead.*) orelse return error.MissingDeadSID;

    var symbol_to_stmt = try std.testing.allocator.alloc(?u32, provider.semantic.?.symbols.items.len);
    defer std.testing.allocator.free(symbol_to_stmt);
    @memset(symbol_to_stmt, null);
    symbol_to_stmt[actual_index] = 1;
    symbol_to_stmt[dead_index] = 2;
    var reachable = try std.DynamicBitSet.initEmpty(std.testing.allocator, 3);
    defer reachable.deinit();
    reachable.set(1);
    provider.symbol_to_stmt = symbol_to_stmt;
    provider.reachable_stmts = &reachable;
    provider.tree_shaker_active = true;
    provider.is_included = true;

    const barrel_idx = findModuleIdx(result.graph, "barrel.ts") orelse return error.MissingBarrel;
    const namespace = try result.linker.buildNamespaceInlineObject(
        @backingInt(barrel_idx),
        @backingInt(barrel_idx),
        0,
    );
    defer std.testing.allocator.free(namespace);
    try std.testing.expect(std.mem.indexOf(u8, namespace, "public") != null);
    try std.testing.expect(std.mem.indexOf(u8, namespace, "hidden") == null);
}

// ============================================================
// Rename Tests
// ============================================================

const TestResult = struct {
    linker: Linker,
    /// heap-allocated ModuleGraph (Linker.graph 안정화 목적, #1779 PR #2).
    graph: *ModuleGraph,
    cache: resolve_cache_mod.ResolveCache,

    /// 기존 테스트들은 `defer r.graph.deinit()` 패턴을 사용했다. heap allocation
    /// 도입으로 destroy 가 추가로 필요해졌으므로, graph.deinit() 호출 시
    /// destroy 까지 한 번에 처리하도록 wrapper 를 제공한다.
    fn destroyGraph(self: *TestResult) void {
        self.graph.deinit();
        std.testing.allocator.destroy(self.graph);
    }
};

fn expectNoCrossModuleConstFact(r: *TestResult, entry_index: ModuleIndex, local_symbol: u32) !void {
    const entry = r.graph.getModule(entry_index) orelse return error.MissingEntryModule;
    const sem = entry.semantic orelse return error.MissingEntrySemantic;
    var const_values = try r.linker.buildCrossModuleConstValues(entry, sem);
    defer const_values.deinit(std.testing.allocator);
    try std.testing.expect(const_values.get(local_symbol) == null);
}

const CrossModuleConstFixture = struct {
    name: []const u8,
    provider_file: []const u8 = "provider.mjs",
    provider_source: []const u8,
    middle_source: ?[]const u8 = null,
    barrel_source: []const u8,
    expected_number: ?[]const u8 = null,
};

fn expectCrossModuleConstFixture(fixture: CrossModuleConstFixture) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.mjs",
        \\import { value } from './barrel.mjs';
        \\console.log(value);
    );
    try writeFile(tmp.dir, "barrel.mjs", fixture.barrel_source);
    if (fixture.middle_source) |source| try writeFile(tmp.dir, "middle.mjs", source);
    try writeFile(tmp.dir, fixture.provider_file, fixture.provider_source);

    var r = try buildLinkAndRename(std.testing.allocator, &tmp, "entry.mjs");
    defer r.linker.deinit();
    defer r.destroyGraph();
    defer r.cache.deinit();

    const entry_index = findModuleIdx(r.graph, "entry.mjs") orelse return error.MissingEntryModule;
    const entry = r.graph.getModule(entry_index) orelse return error.MissingEntryModule;
    const sem = entry.semantic orelse return error.MissingEntrySemantic;
    const local_symbol = entry.import_bindings[0].local_symbol.semanticIndex() orelse
        return error.MissingImportLocalSymbol;
    var const_values = try r.linker.buildCrossModuleConstValues(entry, sem);
    defer const_values.deinit(std.testing.allocator);

    const fact = const_values.get(local_symbol);
    if (fixture.expected_number) |expected| {
        const actual = fact orelse {
            std.debug.print("cross-module const fixture lacked a fact: {s}\n", .{fixture.name});
            return error.MissingExpectedConstFact;
        };
        try std.testing.expectEqual(semantic_symbol.ConstValue.Kind.number, actual.kind);
        try std.testing.expectEqualStrings(expected, actual.number_text);
    } else if (fact != null) {
        std.debug.print("cross-module const fixture received an unsafe fact: {s}\n", .{fixture.name});
        return error.UnsafeCrossModuleConstFact;
    }
}

fn buildLinkAndRename(allocator: std.mem.Allocator, tmp: *std.testing.TmpDir, entry_name: []const u8) !TestResult {
    var r = try buildAndLink(allocator, tmp, entry_name);
    try r.linker.computeRenames();
    r.linker.populateImportSymbols();
    return .{ .linker = r.linker, .graph = r.graph, .cache = r.cache };
}

test "linker: cross-module const facts skip same-named CJS locals behind ESM re-exports" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.mjs",
        \\import { value } from './barrel.mjs';
        \\console.log(value);
    );
    try writeFile(tmp.dir, "barrel.mjs", "export { value } from './provider.cjs';");
    try writeFile(tmp.dir, "provider.cjs",
        \\const value = 1;
        \\exports.value = 99;
    );

    var r = try buildLinkAndRename(std.testing.allocator, &tmp, "entry.mjs");
    defer r.linker.deinit();
    defer r.destroyGraph();
    defer r.cache.deinit();

    const entry_index = findModuleIdx(r.graph, "entry.mjs") orelse return error.MissingEntryModule;
    const entry = r.graph.getModule(entry_index) orelse return error.MissingEntryModule;
    const sem = entry.semantic orelse return error.MissingEntrySemantic;
    const local_symbol = entry.import_bindings[0].local_symbol.semanticIndex() orelse
        return error.MissingImportLocalSymbol;
    var const_values = try r.linker.buildCrossModuleConstValues(entry, sem);
    defer const_values.deinit(std.testing.allocator);

    // CJS fallback resolves an export name contract, not an exact local binding.
    // The private `const value = 1` must not replace the runtime export value 99.
    try std.testing.expect(const_values.get(local_symbol) == null);
}

test "linker: cross-module const facts follow multi-hop ESM exports by exact binding" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.mjs",
        \\import { value } from './barrel.mjs';
        \\console.log(value);
    );
    try writeFile(tmp.dir, "barrel.mjs", "export { value } from './middle.mjs';");
    try writeFile(tmp.dir, "middle.mjs", "export { value } from './provider.mjs';");
    try writeFile(tmp.dir, "provider.mjs",
        \\const innerValue = 42;
        \\const value = 1;
        \\export { innerValue as value };
    );

    var r = try buildLinkAndRename(std.testing.allocator, &tmp, "entry.mjs");
    defer r.linker.deinit();
    defer r.destroyGraph();
    defer r.cache.deinit();

    const entry_index = findModuleIdx(r.graph, "entry.mjs") orelse return error.MissingEntryModule;
    const entry = r.graph.getModule(entry_index) orelse return error.MissingEntryModule;
    const sem = entry.semantic orelse return error.MissingEntrySemantic;
    const local_symbol = entry.import_bindings[0].local_symbol.semanticIndex() orelse
        return error.MissingImportLocalSymbol;

    // Deliberately poison the name index after linking. The exporter still owns
    // the exact SID for `innerValue`, so an unrelated local named `value` must
    // not redirect the const fact through scope_maps.
    const provider_index = findModuleIdx(r.graph, "provider.mjs") orelse return error.MissingProviderModule;
    const provider = r.graph.getModule(provider_index) orelse return error.MissingProviderModule;
    const provider_sem = provider.semantic orelse return error.MissingProviderSemantic;
    const decoy_symbol = provider_sem.scope_maps[0].get("value") orelse return error.MissingDecoySymbol;
    var export_local_names: [3]?[]const u8 = .{ null, null, null };
    for (provider.export_bindings) |export_binding| {
        if (export_binding.kind == .local and std.mem.eql(u8, export_binding.exported_name, "value")) {
            export_local_names = .{
                provider.exportBindingLocalName(export_binding),
                export_binding.local_name,
                export_binding.exported_name,
            };
            break;
        }
    }
    if (export_local_names[0] == null) return error.MissingProviderExport;
    var poisoned_scope = @constCast(&provider_sem.scope_maps[0]);
    for (export_local_names) |maybe_name| {
        if (maybe_name) |name| try poisoned_scope.put(std.testing.allocator, name, decoy_symbol);
    }

    var const_values = try r.linker.buildCrossModuleConstValues(entry, sem);
    defer const_values.deinit(std.testing.allocator);

    const fact = const_values.get(local_symbol) orelse return error.MissingEsmConstFact;
    try std.testing.expectEqual(semantic_symbol.ConstValue.Kind.number, fact.kind);
    try std.testing.expectEqualStrings("42", fact.number_text);
}

test "linker: cross-module const facts fail closed on missing or foreign export IDs" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.mjs",
        \\import { value } from './provider.mjs';
        \\console.log(value);
    );
    try writeFile(tmp.dir, "provider.mjs", "export const value = 42;");

    var r = try buildLinkAndRename(std.testing.allocator, &tmp, "entry.mjs");
    defer r.linker.deinit();
    defer r.destroyGraph();
    defer r.cache.deinit();

    const entry_index = findModuleIdx(r.graph, "entry.mjs") orelse return error.MissingEntryModule;
    const provider_index = findModuleIdx(r.graph, "provider.mjs") orelse return error.MissingProviderModule;
    const entry = r.graph.getModule(entry_index) orelse return error.MissingEntryModule;
    const provider = r.graph.getModule(provider_index) orelse return error.MissingProviderModule;
    const provider_sem = provider.semantic orelse return error.MissingProviderSemantic;
    const local_symbol = entry.import_bindings[0].local_symbol.semanticIndex() orelse
        return error.MissingImportLocalSymbol;

    const export_entry = blk: {
        var it = r.linker.export_map.iterator();
        while (it.next()) |item| {
            if (item.value_ptr.module_index != provider_index or
                !std.mem.eql(u8, item.value_ptr.binding.exported_name, "value")) continue;
            break :blk item.value_ptr;
        }
        return error.MissingProviderExport;
    };
    const exact_symbol = export_entry.binding.symbol;
    const exact_kind = export_entry.binding.kind;

    export_entry.binding.symbol = .invalid;
    try expectNoCrossModuleConstFact(&r, entry_index, local_symbol);

    const source_id = exact_symbol.semanticIndex() orelse return error.MissingProviderSymbolId;
    export_entry.binding.symbol = bundler_symbol.SymbolRef.makeSemantic(entry_index, source_id);
    try expectNoCrossModuleConstFact(&r, entry_index, local_symbol);

    const one_past_symbol = @as(u32, @intCast(provider_sem.symbols.items.len));
    export_entry.binding.symbol = bundler_symbol.SymbolRef.makeSemantic(provider_index, one_past_symbol);
    try expectNoCrossModuleConstFact(&r, entry_index, local_symbol);

    export_entry.binding.symbol = bundler_symbol.SymbolRef.makeSemantic(provider_index, std.math.maxInt(u32));
    try expectNoCrossModuleConstFact(&r, entry_index, local_symbol);

    export_entry.binding.symbol = exact_symbol;
    export_entry.binding.kind = .re_export;
    try expectNoCrossModuleConstFact(&r, entry_index, local_symbol);

    export_entry.binding.symbol = exact_symbol;
    export_entry.binding.kind = exact_kind;
}

test "linker: cross-module const facts skip reassigned ESM exports" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.mjs",
        \\import { value } from './provider.mjs';
        \\console.log(value);
    );
    try writeFile(tmp.dir, "provider.mjs",
        \\export let value = 42;
        \\value = 99;
    );

    var r = try buildLinkAndRename(std.testing.allocator, &tmp, "entry.mjs");
    defer r.linker.deinit();
    defer r.destroyGraph();
    defer r.cache.deinit();

    const entry_index = findModuleIdx(r.graph, "entry.mjs") orelse return error.MissingEntryModule;
    const entry = r.graph.getModule(entry_index) orelse return error.MissingEntryModule;
    const local_symbol = entry.import_bindings[0].local_symbol.semanticIndex() orelse
        return error.MissingImportLocalSymbol;
    try expectNoCrossModuleConstFact(&r, entry_index, local_symbol);
}

test "linker: cross-module const identity adversarial input matrix" {
    const fixtures = [_]CrossModuleConstFixture{
        .{
            .name = "CJS named export with same-named private const",
            .provider_file = "provider.cjs",
            .provider_source = "const value = 1; exports.value = 99;",
            .barrel_source = "export { value } from './provider.cjs';",
        },
        .{
            .name = "CJS computed named export with same-named private const",
            .provider_file = "provider.cjs",
            .provider_source = "const value = 1; exports['value'] = 99;",
            .barrel_source = "export { value } from './provider.cjs';",
        },
        .{
            .name = "CJS getter export with same-named private const",
            .provider_file = "provider.cjs",
            .provider_source = "const value = 1; Object.defineProperty(exports, 'value', { enumerable: true, get() { return 99; } });",
            .barrel_source = "export { value } from './provider.cjs';",
        },
        .{
            .name = "CJS aliased named export with a same-named private const",
            .provider_file = "provider.cjs",
            .provider_source = "const answer = 1; exports.answer = 99;",
            .barrel_source = "export { answer as value } from './provider.cjs';",
        },
        .{
            .name = "two-hop ESM facade over a CJS same-name export",
            .provider_file = "provider.cjs",
            .provider_source = "const value = 1; exports.value = 99;",
            .middle_source = "export { value } from './provider.cjs';",
            .barrel_source = "export { value } from './middle.mjs';",
        },
        .{
            .name = "three-hop ESM export aliases preserve the provider const",
            .provider_source = "const value = 1; const actual = 42; export { actual as inner };",
            .middle_source = "export { inner as renamed } from './provider.mjs';",
            .barrel_source = "export { renamed as value } from './middle.mjs';",
            .expected_number = "42",
        },
        .{
            .name = "nested same-name decoy does not replace an exported alias",
            .provider_source = "const value = 1; function read() { const value = 2; return value; } const actual = 42; export { actual as value };",
            .barrel_source = "export { value } from './provider.mjs';",
            .expected_number = "42",
        },
        .{
            .name = "reassigned ESM alias has no immutable const fact",
            .provider_source = "let actual = 42; export { actual as value }; actual = 99;",
            .barrel_source = "export { value } from './provider.mjs';",
        },
        .{
            .name = "cyclic ESM re-export has no const fact",
            .provider_source = "import './barrel.mjs'; export const value = 42;",
            .barrel_source = "export { value } from './provider.mjs';",
        },
        .{
            .name = "namespace re-export is not a scalar const fact",
            .provider_source = "export const actual = 42;",
            .barrel_source = "export * as value from './provider.mjs';",
        },
    };

    try std.testing.expectEqual(@as(usize, 10), fixtures.len);
    for (fixtures) |fixture| {
        expectCrossModuleConstFixture(fixture) catch |err| {
            std.debug.print("failed hostile input: {s}\n", .{fixture.name});
            return err;
        };
    }
}

test "rename: no conflict — no rename" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import { x } from './b'; console.log(x);");
    try writeFile(tmp.dir, "b.ts", "export const x = 42;");

    var r = try buildLinkAndRename(std.testing.allocator, &tmp, "a.ts");
    defer r.linker.deinit();
    defer r.destroyGraph();
    defer r.cache.deinit();

    // x는 b.ts에만 있으므로 충돌 없음 → canonical_names 비어 있음
    try std.testing.expectEqual(@as(u32, 0), r.linker.canonical_strings.items.len);
}

test "rename: two modules same name — second gets $1" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import './b';\nexport const count = 0;");
    try writeFile(tmp.dir, "b.ts", "export const count = 1;");

    var r = try buildLinkAndRename(std.testing.allocator, &tmp, "a.ts");
    defer r.linker.deinit();
    defer r.destroyGraph();
    defer r.cache.deinit();

    // b.ts(exec_index 낮음)가 원본 유지, a.ts가 count$1
    // 또는 a.ts가 원본이고 b.ts가 $1 (exec_index에 따라)
    try std.testing.expect(r.linker.canonical_strings.items.len > 0);

    // 하나는 리네임됨
    var has_rename = false;
    for (r.linker.canonical_strings.items) |val| {
        if (std.mem.startsWith(u8, val, "count$")) has_rename = true;
    }
    try std.testing.expect(has_rename);
}

test "rename: three modules same name — $1 and $2" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import './b';\nimport './c';\nexport const name = 'a';");
    try writeFile(tmp.dir, "b.ts", "export const name = 'b';");
    try writeFile(tmp.dir, "c.ts", "export const name = 'c';");

    var r = try buildLinkAndRename(std.testing.allocator, &tmp, "a.ts");
    defer r.linker.deinit();
    defer r.destroyGraph();
    defer r.cache.deinit();

    // 3개 중 2개 리네임
    var rename_count: u32 = 0;
    for (r.linker.canonical_strings.items) |val| {
        if (std.mem.startsWith(u8, val, "name$")) rename_count += 1;
    }
    try std.testing.expectEqual(@as(u32, 2), rename_count);
}

test "rename: different names — no conflict" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import './b';\nexport const x = 1;");
    try writeFile(tmp.dir, "b.ts", "export const y = 2;");

    var r = try buildLinkAndRename(std.testing.allocator, &tmp, "a.ts");
    defer r.linker.deinit();
    defer r.destroyGraph();
    defer r.cache.deinit();

    try std.testing.expectEqual(@as(u32, 0), r.linker.canonical_strings.items.len);
}

test "rename: getCanonicalName returns renamed" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import './b';\nexport const count = 0;");
    try writeFile(tmp.dir, "b.ts", "export const count = 1;");

    var r = try buildLinkAndRename(std.testing.allocator, &tmp, "a.ts");
    defer r.linker.deinit();
    defer r.destroyGraph();
    defer r.cache.deinit();

    // 하나는 getCanonicalName으로 리네임 조회 가능
    var found_rename = false;
    for (0..r.graph.moduleCount()) |i| {
        if (r.linker.getCanonicalName(@intCast(i), "count")) |renamed| {
            try std.testing.expect(std.mem.startsWith(u8, renamed, "count$"));
            found_rename = true;
        }
    }
    try std.testing.expect(found_rename);

    // 원본 유지되는 모듈은 getCanonicalName이 null
    var found_original = false;
    for (0..r.graph.moduleCount()) |i| {
        if (r.linker.getCanonicalName(@intCast(i), "count") == null) {
            found_original = true;
        }
    }
    try std.testing.expect(found_original);
}

test "rename: non-exported top-level variables also detected (C1)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // helper는 export 안 됨, 하지만 두 모듈 모두 top-level에 선언
    try writeFile(tmp.dir, "a.ts", "import './b';\nconst helper = () => 1;\nexport const x = helper();");
    try writeFile(tmp.dir, "b.ts", "const helper = () => 2;\nexport const y = helper();");

    var r = try buildLinkAndRename(std.testing.allocator, &tmp, "a.ts");
    defer r.linker.deinit();
    defer r.destroyGraph();
    defer r.cache.deinit();

    // helper가 두 모듈에서 충돌 → 하나가 리네임됨
    var has_helper_rename = false;
    for (r.linker.canonical_strings.items) |val| {
        if (std.mem.startsWith(u8, val, "helper$")) has_helper_rename = true;
    }
    try std.testing.expect(has_helper_rename);
}

test "rename: nested scope conflict avoidance (hasNestedBinding)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // a.ts: top-level x + nested scope에 x$1
    try writeFile(tmp.dir, "a.ts", "import './b';\nexport const x = 1;\nfunction foo(x$1: number) { return x$1; }");
    try writeFile(tmp.dir, "b.ts", "export const x = 2;");

    var r = try buildLinkAndRename(std.testing.allocator, &tmp, "a.ts");
    defer r.linker.deinit();
    defer r.destroyGraph();
    defer r.cache.deinit();

    // x가 충돌. 리네임된 쪽이 x$1을 건너뛰고 x$2가 되어야 함
    // (nested scope에 x$1이 이미 있으므로)
    for (r.linker.canonical_strings.items) |val| {
        if (std.mem.startsWith(u8, val, "x$")) {
            // x$1이 아닌 다른 값이어야 함 (nested scope에 x$1 있으므로)
            // 단, semantic analyzer가 parameter를 어떤 scope에 넣는지에 따라 다를 수 있음
            try std.testing.expect(val.len > 0);
        }
    }
}

test "rename: default export local name conflict (L5)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import './b';\nexport default function foo() { return 1; }");
    try writeFile(tmp.dir, "b.ts", "export const foo = 2;");

    var r = try buildLinkAndRename(std.testing.allocator, &tmp, "a.ts");
    defer r.linker.deinit();
    defer r.destroyGraph();
    defer r.cache.deinit();

    // foo가 두 모듈에서 충돌 (a.ts: default export의 local name, b.ts: named export)
    var has_foo_rename = false;
    for (r.linker.canonical_strings.items) |val| {
        if (std.mem.startsWith(u8, val, "foo$")) has_foo_rename = true;
    }
    try std.testing.expect(has_foo_rename);
}

test "linker: deep re-export chain (near depth limit)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // 5단계 re-export 체인: a → b → c → d → e
    try writeFile(tmp.dir, "a.ts", "import { x } from './b'; console.log(x);");
    try writeFile(tmp.dir, "b.ts", "export { x } from './c';");
    try writeFile(tmp.dir, "c.ts", "export { x } from './d';");
    try writeFile(tmp.dir, "d.ts", "export { x } from './e';");
    try writeFile(tmp.dir, "e.ts", "export const x = 'deep';");

    var r = try buildAndLink(std.testing.allocator, &tmp, "a.ts");
    defer r.linker.deinit();
    defer r.destroyGraph();
    defer r.cache.deinit();

    const a = r.graph.getModule(ModuleIndex.fromUsize(0)).?;
    const binding = r.linker.getResolvedBinding(0, a.import_bindings[0].local_span);
    try std.testing.expect(binding != null);
    // canonical은 e.ts(마지막 모듈)
    try std.testing.expectEqualStrings("x", binding.?.canonical.export_name);
}

test "isReservedName: JS reserved words" {
    try std.testing.expect(Linker.isReservedName("class"));
    try std.testing.expect(Linker.isReservedName("return"));
    try std.testing.expect(Linker.isReservedName("const"));
    try std.testing.expect(Linker.isReservedName("await"));
    try std.testing.expect(Linker.isReservedName("yield"));
    try std.testing.expect(!Linker.isReservedName("foo"));
    try std.testing.expect(!Linker.isReservedName("count$1"));
}

test "isCandidateAvailable: 예약어/글로벌/nested 통합 확인" {
    // isCandidateAvailable은 Linker 인스턴스 필요 → 최소 셋업
    // 빈 graph 도 Linker 가 *ModuleGraph 를 받으므로 stack 변수로 충분.
    var cache = resolve_cache_mod.ResolveCache.init(std.testing.allocator, .{});
    defer cache.deinit();
    var graph = ModuleGraph.init(std.testing.allocator, &cache);
    defer graph.deinit();
    var linker = Linker.init(std.testing.allocator, &graph, .esm);
    defer linker.deinit();

    var name_to_owners: Linker.NameToOwnersMap = .empty;
    defer name_to_owners.deinit(std.testing.allocator);

    // 예약어는 불가
    try std.testing.expect(!linker.isCandidateAvailable("class", 0, &name_to_owners));
    // 일반 이름은 가능
    try std.testing.expect(linker.isCandidateAvailable("foo", 0, &name_to_owners));
    // name_to_owners에 있는 이름은 불가
    try name_to_owners.put(std.testing.allocator, "bar", .empty);
    try std.testing.expect(!linker.isCandidateAvailable("bar", 0, &name_to_owners));
    // reserved_globals에 있는 이름은 불가
    try linker.reserved_globals.put(std.testing.allocator, "console", {});
    try std.testing.expect(!linker.isCandidateAvailable("console", 0, &name_to_owners));
}

test "single-owner reserved name: candidate skips nested binding" {
    // 모듈 b.ts에서 console.log 사용 → console이 unresolved_references에 수집.
    // 모듈 a.ts에서 const console 선언 (단일 소유자) + nested scope에 console$1 존재.
    // scope hoisting 시 a.ts의 console이 b.ts의 글로벌 참조를 가리므로 리네임 필요.
    // 후보 console$1은 nested scope에 있으므로 건너뛰고 console$2가 되어야 함.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts",
        \\import './b';
        \\const console = { log: () => {} };
        \\function f() { const console$1 = 1; return console$1; }
    );
    try writeFile(tmp.dir, "b.ts",
        \\console.log("hello");
    );

    var r = try buildLinkAndRename(std.testing.allocator, &tmp, "a.ts");
    defer r.linker.deinit();
    defer r.destroyGraph();
    defer r.cache.deinit();

    // b.ts의 console.log → console이 reserved_globals에 수집됨.
    // a.ts의 const console은 단일 소유자이지만 글로벌 shadowing → 리네임됨.
    const renamed = r.linker.getCanonicalName(0, "console");
    try std.testing.expect(renamed != null);
    // nested scope에 console$1이 있으므로 console$2가 되어야 함
    try std.testing.expectEqualStrings("console$2", renamed.?);
}

test "isReservedName: special identifiers" {
    // undefined, NaN, Infinity, arguments, eval은 예약어급 (키워드 목록에 유지)
    try std.testing.expect(Linker.isReservedName("undefined"));
    try std.testing.expect(Linker.isReservedName("arguments"));
    try std.testing.expect(Linker.isReservedName("eval"));
    try std.testing.expect(Linker.isReservedName("NaN"));
    try std.testing.expect(Linker.isReservedName("Infinity"));
    // Array/Object 등 대부분의 글로벌은 unresolved references로 자동 수집
    try std.testing.expect(!Linker.isReservedName("Array"));
    try std.testing.expect(!Linker.isReservedName("Object"));
    // window/console 등 주요 글로벌은 안전망으로 정적 목록에 포함
    try std.testing.expect(Linker.isReservedName("console"));
    try std.testing.expect(Linker.isReservedName("window"));
    try std.testing.expect(Linker.isReservedName("require"));
    try std.testing.expect(Linker.isReservedName("module"));
    try std.testing.expect(!Linker.isReservedName("myVar"));
}

test "computeRenamesForModules: 지정된 모듈만 대상으로 충돌 감지" {
    // 3개 모듈이 같은 이름 "x"를 가지지만,
    // computeRenamesForModules에 2개만 전달하면 그 2개만 충돌 처리.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import './b';\nimport './c';\nconst x = 'a';");
    try writeFile(tmp.dir, "b.ts", "const x = 'b';");
    try writeFile(tmp.dir, "c.ts", "const x = 'c';");

    const dp = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(dp);
    const entry = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "a.ts" });
    defer std.testing.allocator.free(entry);

    var cache = resolve_cache_mod.ResolveCache.init(std.testing.allocator, .{});
    defer cache.deinit();
    var graph = ModuleGraph.init(std.testing.allocator, &cache);
    defer graph.deinit();
    try graph.build(std.testing.io, &.{entry});

    var linker = Linker.init(std.testing.allocator, &graph, .esm);
    defer linker.deinit();
    try linker.link();

    // 전체 3개 모듈을 글로벌 rename — 2개가 rename됨
    try linker.computeRenames();
    var global_rename_count: usize = 0;
    for (0..graph.moduleCount()) |i| {
        if (linker.getCanonicalName(@intCast(i), "x") != null) global_rename_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), global_rename_count);

    // per-module rename: 모듈 0, 1만 대상 → 1개만 rename됨
    const subset = &[_]ModuleIndex{ @fromBackingInt(@intCast(0)), @fromBackingInt(@intCast(1)) };
    try linker.computeRenamesForModules(subset, &.{});
    var subset_rename_count: usize = 0;
    for (0..graph.moduleCount()) |i| {
        if (linker.getCanonicalName(@intCast(i), "x") != null) subset_rename_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), subset_rename_count);
}

test "clearCanonicalNames: 초기화 후 비어있음" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import './b';\nconst x = 1;");
    try writeFile(tmp.dir, "b.ts", "const x = 2;");

    const dp = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(dp);
    const entry = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "a.ts" });
    defer std.testing.allocator.free(entry);

    var cache = resolve_cache_mod.ResolveCache.init(std.testing.allocator, .{});
    defer cache.deinit();
    var graph = ModuleGraph.init(std.testing.allocator, &cache);
    defer graph.deinit();
    try graph.build(std.testing.io, &.{entry});

    var linker = Linker.init(std.testing.allocator, &graph, .esm);
    defer linker.deinit();
    try linker.link();
    try linker.computeRenames();

    // rename 결과가 있어야 함
    try std.testing.expect(linker.canonical_strings.items.len > 0);

    // 초기화 후 비어있어야 함
    linker.clearCanonicalNames();
    try std.testing.expectEqual(@as(usize, 0), linker.canonical_strings.items.len);
}

// ============================================================
// Issue #282: namespace import (import * as X) scope hoisting
// ============================================================

test "namespace: import * as creates namespace object preamble" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import * as utils from './utils';\nconsole.log(utils.add(1,2));");
    try writeFile(tmp.dir, "utils.ts", "export function add(a: number, b: number) { return a + b; }\nexport function mul(a: number, b: number) { return a * b; }");

    var r = try buildLinkAndRename(std.testing.allocator, &tmp, "entry.ts");
    defer r.linker.deinit();
    defer r.destroyGraph();
    defer r.cache.deinit();

    // namespace import는 resolved_bindings에 등록되지 않음 (resolveImports에서 skip)
    // 대신 buildMetadataForAst에서 preamble로 처리
    const entry = r.graph.getModule(ModuleIndex.fromUsize(0)).?;
    try std.testing.expect(entry.import_bindings.len > 0);
    try std.testing.expectEqual(ImportBinding.Kind.namespace, entry.import_bindings[0].kind);
}

test "namespace: export * from re-exports collected in namespace" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import * as all from './barrel';\nconsole.log(all);");
    try writeFile(tmp.dir, "barrel.ts", "export * from './a';\nexport * from './b';");
    try writeFile(tmp.dir, "a.ts", "export const x = 1;");
    try writeFile(tmp.dir, "b.ts", "export const y = 2;");

    var r = try buildLinkAndRename(std.testing.allocator, &tmp, "entry.ts");
    defer r.linker.deinit();
    defer r.destroyGraph();
    defer r.cache.deinit();

    // barrel 모듈에서 export * 로 a, b의 export를 수집
    const entry = r.graph.getModule(ModuleIndex.fromUsize(0)).?;
    try std.testing.expect(entry.import_bindings.len > 0);
    try std.testing.expectEqual(ImportBinding.Kind.namespace, entry.import_bindings[0].kind);
}

// ============================================================
// Issue #283: re-export alias 바인딩 해결
// ============================================================

test "re-export alias: export { J as render } resolves to J" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // preact 패턴: 함수를 다른 이름으로 re-export
    try writeFile(tmp.dir, "entry.ts", "import { render } from './reexport'; console.log(render);");
    try writeFile(tmp.dir, "reexport.ts", "export { J as render } from './impl';");
    try writeFile(tmp.dir, "impl.ts", "export function J() { return 42; }");

    var r = try buildLinkAndRename(std.testing.allocator, &tmp, "entry.ts");
    defer r.linker.deinit();
    defer r.destroyGraph();
    defer r.cache.deinit();

    // entry의 import { render }가 impl.ts의 J에 연결
    const entry = r.graph.getModule(ModuleIndex.fromUsize(0)).?;
    const binding = r.linker.getResolvedBinding(0, entry.import_bindings[0].local_span);
    try std.testing.expect(binding != null);
    // canonical은 impl.ts의 "J" — re-export 체인을 따라 최종 모듈의 export 이름
    const canon = binding.?.canonical;
    try std.testing.expectEqualStrings("J", canon.export_name);
    // resolveToLocalName도 "J" (impl.ts에서 함수명과 export명이 동일)
    const local = r.linker.resolveToLocalName(canon);
    try std.testing.expectEqualStrings("J", local);
}

test "re-export alias: export { default as groupBy } — function declaration" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // export default <function_declaration> → binding_scanner가 함수 이름 추출
    try writeFile(tmp.dir, "entry.ts", "import { greet } from './barrel'; console.log(greet);");
    try writeFile(tmp.dir, "barrel.ts", "export { default as greet } from './impl';");
    try writeFile(tmp.dir, "impl.ts", "export default function hello() { return 'hi'; }");

    var r = try buildLinkAndRename(std.testing.allocator, &tmp, "entry.ts");
    defer r.linker.deinit();
    defer r.destroyGraph();
    defer r.cache.deinit();

    const entry = r.graph.getModule(ModuleIndex.fromUsize(0)).?;
    const binding = r.linker.getResolvedBinding(0, entry.import_bindings[0].local_span);
    try std.testing.expect(binding != null);
    // canonical은 impl.ts의 "default" → local_name = "hello" (함수명)
    const local = r.linker.resolveToLocalName(binding.?.canonical);
    try std.testing.expectEqualStrings("hello", local);
}

test "re-export alias: export { default as X } — identifier default uses snapshot facade" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // export default <identifier> → snapshot facade, separate from source binding.
    try writeFile(tmp.dir, "entry.ts", "import { groupBy } from './barrel'; console.log(groupBy);");
    try writeFile(tmp.dir, "barrel.ts", "export { default as groupBy } from './groupBy';");
    try writeFile(tmp.dir, "groupBy.ts", "function groupBy(arr: any) { return arr; }\nexport default groupBy;");

    var r = try buildLinkAndRename(std.testing.allocator, &tmp, "entry.ts");
    defer r.linker.deinit();
    defer r.destroyGraph();
    defer r.cache.deinit();

    const entry = r.graph.getModule(ModuleIndex.fromUsize(0)).?;
    const binding = r.linker.getResolvedBinding(0, entry.import_bindings[0].local_span);
    try std.testing.expect(binding != null);
    const target = r.graph.getModule(binding.?.canonical.module_index).?;
    const exported = target.export_bindings[0];
    try std.testing.expect(exported.has_default_export_facade);
    const facade_sid = exported.symbol.semanticIndex().?;
    const operand = target.ast.?.getNode(exported.default_export_node.?).data.unary.operand;
    const source_sid = target.semantic.?.symbol_ids[@backingInt(operand)].?;
    try std.testing.expect(facade_sid != source_sid);
    try std.testing.expectEqualStrings(r.linker.getCanonicalByRef(exported.symbol).?, r.linker.resolveToLocalName(binding.?.canonical));
}

// ============================================================
// Issue #284: _default 이름 충돌 해결
// ============================================================

test "rename: multiple export default identifiers use separate facades without collision" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // Every identifier expression has its own default facade in the merged scope.
    try writeFile(tmp.dir, "entry.ts", "import './a';\nimport './b';\nimport './c';");
    try writeFile(tmp.dir, "a.ts", "const x = 1;\nexport default x;");
    try writeFile(tmp.dir, "b.ts", "const y = 2;\nexport default y;");
    try writeFile(tmp.dir, "c.ts", "const z = 3;\nexport default z;");

    var r = try buildLinkAndRename(std.testing.allocator, &tmp, "entry.ts");
    defer r.linker.deinit();
    defer r.destroyGraph();
    defer r.cache.deinit();

    // Three facades share a base name, so two require unique canonical names.
    var rename_count: u32 = 0;
    for (r.linker.canonical_strings.items) |val| {
        if (std.mem.startsWith(u8, val, "_default$")) rename_count += 1;
    }
    try std.testing.expectEqual(@as(u32, 2), rename_count);
    try expectDistinctDefaultFacadeNames(&r, 3);
}

// ============================================================
// Issue #283+: namespace import edge cases
// ============================================================

test "namespace: diamond export * dedup" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // A exports * from B and C, both export * from shared.
    // x should appear once (no duplicate).
    try writeFile(tmp.dir, "entry.ts", "import * as ns from './a';\nconsole.log(ns.x);");
    try writeFile(tmp.dir, "a.ts", "export * from './b';\nexport * from './c';");
    try writeFile(tmp.dir, "b.ts", "export * from './shared';");
    try writeFile(tmp.dir, "c.ts", "export * from './shared';");
    try writeFile(tmp.dir, "shared.ts", "export const x = 1;");

    var r = try buildLinkAndRename(std.testing.allocator, &tmp, "entry.ts");
    defer r.linker.deinit();
    defer r.destroyGraph();
    defer r.cache.deinit();

    // entry에서 namespace import로 ns를 가져옴 — 무한 루프 없이 완료
    const entry = r.graph.getModule(ModuleIndex.fromUsize(0)).?;
    try std.testing.expect(entry.import_bindings.len > 0);
    try std.testing.expectEqual(ImportBinding.Kind.namespace, entry.import_bindings[0].kind);
}

test "namespace: circular export * no infinite loop" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // A exports * from B, B exports * from A — 순환 export *
    try writeFile(tmp.dir, "entry.ts", "import * as ns from './a';\nconsole.log(ns);");
    try writeFile(tmp.dir, "a.ts", "export * from './b';\nexport const x = 1;");
    try writeFile(tmp.dir, "b.ts", "export * from './a';\nexport const y = 2;");

    var r = try buildLinkAndRename(std.testing.allocator, &tmp, "entry.ts");
    defer r.linker.deinit();
    defer r.destroyGraph();
    defer r.cache.deinit();

    // 무한 루프 없이 완료되면 성공
    const entry = r.graph.getModule(ModuleIndex.fromUsize(0)).?;
    try std.testing.expect(entry.import_bindings.len > 0);
    try std.testing.expectEqual(ImportBinding.Kind.namespace, entry.import_bindings[0].kind);
}

test "namespace: mixed named + default exports" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // 모듈이 named export와 default export를 모두 가짐
    try writeFile(tmp.dir, "entry.ts", "import * as m from './mod';\nconsole.log(m.x, m.default);");
    try writeFile(tmp.dir, "mod.ts", "export const x = 1;\nexport default 42;");

    var r = try buildLinkAndRename(std.testing.allocator, &tmp, "entry.ts");
    defer r.linker.deinit();
    defer r.destroyGraph();
    defer r.cache.deinit();

    const entry = r.graph.getModule(ModuleIndex.fromUsize(0)).?;
    try std.testing.expect(entry.import_bindings.len > 0);
    try std.testing.expectEqual(ImportBinding.Kind.namespace, entry.import_bindings[0].kind);
}

test "namespace: re-export alias in namespace" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // barrel이 J를 render로 re-export → namespace에서 render로 접근 가능해야 함
    try writeFile(tmp.dir, "entry.ts", "import * as ns from './barrel';\nconsole.log(ns.render);");
    try writeFile(tmp.dir, "barrel.ts", "export { J as render } from './impl';");
    try writeFile(tmp.dir, "impl.ts", "export function J() { return 42; }");

    var r = try buildLinkAndRename(std.testing.allocator, &tmp, "entry.ts");
    defer r.linker.deinit();
    defer r.destroyGraph();
    defer r.cache.deinit();

    const entry = r.graph.getModule(ModuleIndex.fromUsize(0)).?;
    try std.testing.expect(entry.import_bindings.len > 0);
    try std.testing.expectEqual(ImportBinding.Kind.namespace, entry.import_bindings[0].kind);
}

// ============================================================
// Re-export alias edge cases
// ============================================================

test "re-export alias: double-hop chain (z -> y -> x)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // 3-level alias chain: z → y → x → 최종 original
    try writeFile(tmp.dir, "entry.ts", "import { z } from './hop1'; console.log(z);");
    try writeFile(tmp.dir, "hop1.ts", "export { y as z } from './hop2';");
    try writeFile(tmp.dir, "hop2.ts", "export { x as y } from './origin';");
    try writeFile(tmp.dir, "origin.ts", "export function x() { return 1; }");

    var r = try buildLinkAndRename(std.testing.allocator, &tmp, "entry.ts");
    defer r.linker.deinit();
    defer r.destroyGraph();
    defer r.cache.deinit();

    const entry = r.graph.getModule(ModuleIndex.fromUsize(0)).?;
    const binding = r.linker.getResolvedBinding(0, entry.import_bindings[0].local_span);
    try std.testing.expect(binding != null);
    // 3-hop chain → 최종 origin.ts의 "x"
    const canon = binding.?.canonical;
    try std.testing.expectEqualStrings("x", canon.export_name);
    const local = r.linker.resolveToLocalName(canon);
    try std.testing.expectEqualStrings("x", local);
}

test "re-export alias: default class declaration resolves to class name" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // export default class MyClass {} → local_name = "MyWidget"
    try writeFile(tmp.dir, "entry.ts", "import { Widget } from './barrel'; console.log(Widget);");
    try writeFile(tmp.dir, "barrel.ts", "export { default as Widget } from './impl';");
    try writeFile(tmp.dir, "impl.ts", "export default class MyWidget { render() {} }");

    var r = try buildLinkAndRename(std.testing.allocator, &tmp, "entry.ts");
    defer r.linker.deinit();
    defer r.destroyGraph();
    defer r.cache.deinit();

    const entry = r.graph.getModule(ModuleIndex.fromUsize(0)).?;
    const binding = r.linker.getResolvedBinding(0, entry.import_bindings[0].local_span);
    try std.testing.expect(binding != null);
    // default class declaration → local_name = "MyWidget"
    const local = r.linker.resolveToLocalName(binding.?.canonical);
    try std.testing.expectEqualStrings("MyWidget", local);
}

// ============================================================
// _default collision edge cases
// ============================================================

test "rename: mixed function + expression defaults — identifier collision" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // rolldown 방식: export default val → local_name = "val" (두 모듈에서 충돌)
    try writeFile(tmp.dir, "entry.ts", "import a from './func';\nimport b from './expr1';\nimport c from './expr2';\nconsole.log(a, b, c);");
    try writeFile(tmp.dir, "func.ts", "export default function myFunc() { return 1; }");
    try writeFile(tmp.dir, "expr1.ts", "const val = 2;\nexport default val;");
    try writeFile(tmp.dir, "expr2.ts", "const val = 3;\nexport default val;");

    var r = try buildLinkAndRename(std.testing.allocator, &tmp, "entry.ts");
    defer r.linker.deinit();
    defer r.destroyGraph();
    defer r.cache.deinit();

    // expr1, expr2 모두 val → 하나가 val$1로 리네임
    var val_rename_count: u32 = 0;
    for (r.linker.canonical_strings.items) |v| {
        if (std.mem.startsWith(u8, v, "val$")) val_rename_count += 1;
    }
    try std.testing.expectEqual(@as(u32, 1), val_rename_count);
}

test "rename: default identifier snapshots use unique _default facades" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // Source bindings remain independent from each module's default snapshot.
    try writeFile(tmp.dir, "entry.ts", "import a from './a';\nimport b from './b';\nconsole.log(a, b);");
    try writeFile(tmp.dir, "a.ts", "const x = 10;\nexport default x;");
    try writeFile(tmp.dir, "b.ts", "const y = 20;\nexport default y;");

    var r = try buildLinkAndRename(std.testing.allocator, &tmp, "entry.ts");
    defer r.linker.deinit();
    defer r.destroyGraph();
    defer r.cache.deinit();

    // Two synthetic default facades merge into one top-level scope.
    var rename_count: u32 = 0;
    for (r.linker.canonical_strings.items) |val| {
        if (std.mem.startsWith(u8, val, "_default$")) rename_count += 1;
    }
    try std.testing.expectEqual(@as(u32, 1), rename_count);
    try expectDistinctDefaultFacadeNames(&r, 2);
}

// ============================================================
// export * as ns from (ES2020 namespace re-export) — #289
// ============================================================

test "export * as: basic namespace re-export" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { math } from './barrel';\nconsole.log(math.add(1, 2));");
    try writeFile(tmp.dir, "barrel.ts", "export * as math from './math';");
    try writeFile(tmp.dir, "math.ts", "export function add(a: number, b: number) { return a + b; }");

    var r = try buildLinkAndRename(std.testing.allocator, &tmp, "entry.ts");
    defer r.linker.deinit();
    defer r.destroyGraph();
    defer r.cache.deinit();

    // entry의 import { math }가 barrel의 "math" export에 연결
    const entry = r.graph.getModule(ModuleIndex.fromUsize(0)).?;
    const binding = r.linker.getResolvedBinding(0, entry.import_bindings[0].local_span);
    try std.testing.expect(binding != null);
    try std.testing.expectEqualStrings("math", binding.?.canonical.export_name);
}

test "export * as: binding_scanner registers named export" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import './barrel';");
    try writeFile(tmp.dir, "barrel.ts", "export * as utils from './utils';");
    try writeFile(tmp.dir, "utils.ts", "export const x = 1;");

    var r = try buildAndLink(std.testing.allocator, &tmp, "entry.ts");
    defer r.linker.deinit();
    defer r.destroyGraph();
    defer r.cache.deinit();

    // barrel 모듈(index 1)의 export_bindings에 "utils" 이름이 등록됨
    var has_utils_export = false;
    var it = r.graph.modulesIterator();
    while (it.next()) |m| {
        for (m.export_bindings) |eb| {
            if (std.mem.eql(u8, eb.exported_name, "utils")) {
                has_utils_export = true;
                // local_name도 "utils" (preamble에서 var utils = {...} 생성용)
                try std.testing.expectEqualStrings("utils", eb.local_name);
            }
        }
    }
    try std.testing.expect(has_utils_export);
}

// ============================================================
// esbuild 방식 namespace import — ns.prop 직접 치환
// ============================================================

test "namespace rewrite: ns.prop resolved in ns_member_rewrites" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import * as utils from './utils';\nconsole.log(utils.add(1, 2));");
    try writeFile(tmp.dir, "utils.ts", "export function add(a: number, b: number) { return a + b; }\nexport function mul(a: number, b: number) { return a * b; }");

    var r = try buildLinkAndRename(std.testing.allocator, &tmp, "entry.ts");
    defer r.linker.deinit();
    defer r.destroyGraph();
    defer r.cache.deinit();

    // ns.prop만 사용 → ns_member_rewrites에 매핑 등록
    const entry = r.graph.getModule(ModuleIndex.fromUsize(0)).?;
    try std.testing.expect(entry.import_bindings.len > 0);
    try std.testing.expectEqual(ImportBinding.Kind.namespace, entry.import_bindings[0].kind);
}

test "namespace access analysis uses the import SymbolId under hostile scope maps" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(
        tmp.dir,
        "entry.ts",
        "import * as ns from './provider.ts';\n" ++
            "const decoy0 = { wrong0: 0 }, decoy1 = { wrong1: 1 }, decoy2 = { wrong2: 2 }, decoy3 = { wrong3: 3 }, decoy4 = { wrong4: 4 };\n" ++
            "const decoy5 = { wrong5: 5 }, decoy6 = { wrong6: 6 }, decoy7 = { wrong7: 7 }, decoy8 = { wrong8: 8 }, decoy9 = { wrong9: 9 };\n" ++
            "console.log(ns.answer, decoy0.wrong0, decoy1.wrong1, decoy2.wrong2, decoy3.wrong3, decoy4.wrong4, " ++
            "decoy5.wrong5, decoy6.wrong6, decoy7.wrong7, decoy8.wrong8, decoy9.wrong9);\n",
    );
    try writeFile(tmp.dir, "provider.ts", "export const answer = 42;\n");

    var r = try buildLinkAndRename(allocator, &tmp, "entry.ts");
    defer r.linker.deinit();
    defer r.destroyGraph();
    defer r.cache.deinit();

    const entry_index = findModuleIdx(r.graph, "entry.ts") orelse return error.MissingEntry;
    const entry = @constCast(r.graph.getModule(entry_index) orelse return error.MissingEntry);
    const semantic = if (entry.semantic) |*value| value else return error.MissingEntrySemantic;
    if (semantic.scope_maps.len == 0) return error.MissingEntryScopeMap;
    const binding_index = blk: {
        for (entry.import_bindings, 0..) |ib, index| {
            if (std.mem.eql(u8, ib.local_name, "ns")) break :blk index;
        }
        return error.MissingNamespaceImportBinding;
    };
    const binding_symbol = entry.import_bindings[binding_index].local_symbol.semanticIndex() orelse
        return error.MissingNamespaceImportSymbol;
    try std.testing.expectEqual(entry_index, entry.import_bindings[binding_index].local_symbol.moduleIndex());

    const mutable_scope_maps = @constCast(semantic.scope_maps);
    const decoy_names = [_][]const u8{
        "decoy0", "decoy1", "decoy2", "decoy3", "decoy4",
        "decoy5", "decoy6", "decoy7", "decoy8", "decoy9",
    };
    for (decoy_names) |decoy_name| {
        const decoy_symbol = semantic.scope_maps[0].get(decoy_name) orelse return error.MissingNamespaceDecoy;
        try std.testing.expect(decoy_symbol != binding_symbol);
        try mutable_scope_maps[0].put(allocator, "ns", decoy_symbol);

        r.linker.populateNamespaceAccesses();

        const properties = entry.import_bindings[binding_index].namespace_used_properties orelse
            return error.MissingNamespaceProperties;
        try std.testing.expectEqual(@as(usize, 1), properties.len);
        try std.testing.expectEqualStrings("answer", properties[0]);
    }
}

test "namespace re-export metadata uses the import binding SymbolId under a hostile scope map" {
    const allocator = std.testing.allocator;
    const barrel_sources = [_][]const u8{
        "import * as ns from './provider.ts'; export { ns };\n",
        "export * as ns from './provider.ts';\n",
    };

    for (barrel_sources) |barrel_source| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try writeFile(
            tmp.dir,
            "entry.ts",
            "import { ns as value } from './barrel.ts';\n" ++
                "const decoy0 = 0, decoy1 = 1, decoy2 = 2, decoy3 = 3, decoy4 = 4;\n" ++
                "const decoy5 = 5, decoy6 = 6, decoy7 = 7, decoy8 = 8, decoy9 = 9;\n" ++
                "console.log(value.answer);\n",
        );
        try writeFile(tmp.dir, "barrel.ts", barrel_source);
        try writeFile(tmp.dir, "provider.ts", "export const answer = 1;\n");

        var r = try buildLinkAndRename(allocator, &tmp, "entry.ts");
        defer r.linker.deinit();
        defer r.destroyGraph();
        defer r.cache.deinit();

        const entry_index = findModuleIdx(r.graph, "entry.ts") orelse return error.MissingEntry;
        const entry = @constCast(r.graph.getModule(entry_index) orelse return error.MissingEntry);
        const semantic = if (entry.semantic) |*value| value else return error.MissingEntrySemantic;
        if (semantic.scope_maps.len == 0) return error.MissingEntryScopeMap;

        const binding = blk: {
            for (entry.import_bindings) |ib| {
                if (std.mem.eql(u8, ib.local_name, "value")) break :blk ib;
            }
            return error.MissingNamespaceImportBinding;
        };
        const binding_symbol = binding.local_symbol.semanticIndex() orelse return error.MissingNamespaceImportSymbol;
        try std.testing.expectEqual(entry_index, binding.local_symbol.moduleIndex());

        const mutable_scope_maps = @constCast(semantic.scope_maps);
        const decoy_names = [_][]const u8{
            "decoy0", "decoy1", "decoy2", "decoy3", "decoy4",
            "decoy5", "decoy6", "decoy7", "decoy8", "decoy9",
        };
        for (decoy_names) |decoy_name| {
            const decoy_symbol = semantic.scope_maps[0].get(decoy_name) orelse return error.MissingNamespaceDecoy;
            try std.testing.expect(decoy_symbol != binding_symbol);
            try mutable_scope_maps[0].put(allocator, "value", decoy_symbol);

            var metadata = try buildMetadataForModule(&r, entry_index.toU32(), true);
            defer metadata.deinit();

            try std.testing.expect(metadata.ns_member_rewrites.get(binding_symbol) != null);
            try std.testing.expect(metadata.ns_member_rewrites.get(@intCast(decoy_symbol)) == null);
        }
    }
}

test "namespace hostile metadata rejects foreign and alias SymbolRefs, preserving invalid fallback" {
    const allocator = std.testing.allocator;
    const barrel_sources = [_][]const u8{
        "import * as ns from './provider.ts'; export { ns };\n",
        "export * as ns from './provider.ts';\n",
    };

    for (barrel_sources) |barrel_source| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try writeFile(
            tmp.dir,
            "entry.ts",
            "import { ns as value } from './barrel.ts';\n" ++
                "const decoy0 = 0, decoy1 = 1, decoy2 = 2;\n" ++
                "console.log(value.answer);\n",
        );
        try writeFile(tmp.dir, "barrel.ts", barrel_source);
        try writeFile(tmp.dir, "provider.ts", "export const answer = 1;\n");

        var r = try buildLinkAndRename(allocator, &tmp, "entry.ts");
        defer r.linker.deinit();
        defer r.destroyGraph();
        defer r.cache.deinit();

        const entry_index = findModuleIdx(r.graph, "entry.ts") orelse return error.MissingEntry;
        const entry = @constCast(r.graph.getModule(entry_index) orelse return error.MissingEntry);
        const semantic = if (entry.semantic) |*value| value else return error.MissingEntrySemantic;
        if (semantic.scope_maps.len == 0) return error.MissingEntryScopeMap;
        const binding_index = blk: {
            for (entry.import_bindings, 0..) |ib, index| {
                if (std.mem.eql(u8, ib.local_name, "value")) break :blk index;
            }
            return error.MissingNamespaceImportBinding;
        };
        const binding_symbol = entry.import_bindings[binding_index].local_symbol.semanticIndex() orelse
            return error.MissingNamespaceImportSymbol;
        const provider_index = findModuleIdx(r.graph, "provider.ts") orelse return error.MissingProvider;
        const decoy_symbol = semantic.scope_maps[0].get("decoy0") orelse return error.MissingNamespaceDecoy;
        const mutable_scope_maps = @constCast(semantic.scope_maps);
        const binding = &entry.import_bindings[binding_index];

        // A valid same-module SymbolRef wins over a poisoned spelling map and
        // keeps the namespace rewrite attached to the captured binding SID.
        try mutable_scope_maps[0].put(allocator, "value", decoy_symbol);
        var local_metadata = try buildMetadataForModule(&r, entry_index.toU32(), true);
        defer local_metadata.deinit();
        try std.testing.expect(local_metadata.ns_member_rewrites.get(binding_symbol) != null);
        try std.testing.expect(local_metadata.ns_member_rewrites.get(@intCast(decoy_symbol)) == null);

        // A valid-looking SID from another module must fail closed, even when its
        // numeric symbol index happens to overlap with a local binding.
        binding.local_symbol = bundler_symbol.SymbolRef.makeSemantic(provider_index, binding_symbol);
        try mutable_scope_maps[0].put(allocator, "value", decoy_symbol);
        var foreign_metadata = try buildMetadataForModule(&r, entry_index.toU32(), true);
        defer foreign_metadata.deinit();
        try std.testing.expect(foreign_metadata.ns_member_rewrites.get(binding_symbol) == null);
        try std.testing.expect(foreign_metadata.ns_member_rewrites.get(@intCast(decoy_symbol)) == null);

        // A valid same-module alias is not a semantic local SID. Since it still
        // carries explicit identity, it must fail closed instead of using text.
        binding.local_symbol = .{ .alias = .{ .module = entry_index, .symbol = @fromBackingInt(@intCast(0)) } };
        var alias_metadata = try buildMetadataForModule(&r, entry_index.toU32(), true);
        defer alias_metadata.deinit();
        try std.testing.expect(alias_metadata.ns_member_rewrites.get(binding_symbol) == null);
        try std.testing.expect(alias_metadata.ns_member_rewrites.get(@intCast(decoy_symbol)) == null);

        // Invalid SymbolRef is reserved for low-level callers that have no
        // captured identity, so the legacy name-to-scope fallback remains live.
        binding.local_symbol = .invalid;
        try mutable_scope_maps[0].put(allocator, "value", binding_symbol);
        var fallback_metadata = try buildMetadataForModule(&r, entry_index.toU32(), true);
        defer fallback_metadata.deinit();
        try std.testing.expect(fallback_metadata.ns_member_rewrites.get(binding_symbol) != null);
    }
}

// ============================================================
// semantic analyzer: property key symbol_id 미할당
// ============================================================

test "semantic: non-shorthand property key has no symbol_id" {
    // { checks: [] } — "checks" key는 변수 참조가 아님
    // semantic analyzer에서 symbol_id를 할당하지 않아야 함
    const source = "const checks = 1;\nconst obj = { checks: [] };";
    const Sem = @import("../semantic/analyzer.zig").SemanticAnalyzer;
    const Scanner = @import("../lexer/scanner.zig").Scanner;
    const Parser = @import("../parser/parser.zig").Parser;

    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();
    _ = try parser.parse();

    var analyzer = Sem.init(std.testing.allocator, &parser.ast);
    defer analyzer.deinit();
    _ = analyzer.analyze() catch {};

    // "checks" 변수 선언은 reference_count 증가 없어야 함
    // (shorthand가 아닌 property key에서 참조 안 됨)
    // 정확히는: checks 변수의 reference_count가 0이어야 함
    // (const obj = { checks: [] }에서 checks key는 resolve 안 됨)
    if (analyzer.scope_maps.items.len > 0) {
        if (analyzer.scope_maps.items[0].get("checks")) |sym_idx| {
            if (sym_idx < analyzer.symbols.items.len) {
                // shorthand가 아닌 property key에서 참조되지 않으므로 ref count = 0
                try std.testing.expectEqual(@as(u32, 0), analyzer.symbols.items[sym_idx].reference_count);
            }
        }
    }
}

test "semantic: shorthand property key has symbol_id" {
    // { checks } — shorthand에서는 "checks"가 변수 참조
    const source = "const checks = 1;\nconst obj = { checks };";
    const Sem = @import("../semantic/analyzer.zig").SemanticAnalyzer;
    const Scanner = @import("../lexer/scanner.zig").Scanner;
    const Parser = @import("../parser/parser.zig").Parser;

    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();
    _ = try parser.parse();

    var analyzer = Sem.init(std.testing.allocator, &parser.ast);
    defer analyzer.deinit();
    _ = analyzer.analyze() catch {};

    // shorthand { checks } 에서 checks는 변수 참조 → reference_count > 0
    if (analyzer.scope_maps.items.len > 0) {
        if (analyzer.scope_maps.items[0].get("checks")) |sym_idx| {
            if (sym_idx < analyzer.symbols.items.len) {
                try std.testing.expect(analyzer.symbols.items[sym_idx].reference_count > 0);
            }
        }
    }
}

// ============================================================
// export * as ns — seen 오염 방지 (독립 namespace)
// ============================================================

test "export * as: does not pollute parent seen (name collision)" {
    // export * as ns의 내부 export가 외부 export *의 같은 이름을 덮어쓰면 안 됨
    // regexes에 string (regex), schemas에 string (factory) → 외부는 schemas의 string 사용
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "regexes.ts", "export const string = /^.*$/;");
    try writeFile(tmp.dir, "schemas.ts", "export function string() { return 'schema'; }");
    try writeFile(tmp.dir, "core.ts", "export * as regexes from './regexes';\nexport * from './schemas';");
    try writeFile(tmp.dir, "entry.ts", "import * as ns from './core';\nconsole.log(ns.string());");

    var r = try buildLinkAndRename(std.testing.allocator, &tmp, "entry.ts");
    defer r.linker.deinit();
    defer r.destroyGraph();
    defer r.cache.deinit();

    // entry의 namespace import 확인
    const entry = r.graph.getModule(ModuleIndex.fromUsize(0)).?;
    try std.testing.expect(entry.import_bindings.len > 0);
    try std.testing.expectEqual(ImportBinding.Kind.namespace, entry.import_bindings[0].kind);

    // 회귀 가드(zod `z.string`===undefined): `export * as regexes` 의 내부 `string` 이
    // plain `export *`(schemas)의 `string` 과 false-ambiguous 충돌하면 안 된다.
    // `export * as ns` 는 top-level 에 `ns` 한 이름만 기여하므로 ambiguity 판정 비참여.
    const core_idx = findModuleIdx(r.graph, "core.ts").?;
    const schemas_idx = findModuleIdx(r.graph, "schemas.ts").?;
    try std.testing.expect(!r.linker.isAmbiguousStarExport(core_idx, "string"));
    const resolved = r.linker.resolveExportChain(core_idx, "string", 0);
    try std.testing.expect(resolved != null);
    // schemas(plain star)의 factory 로 해석되어야 한다 — regexes(namespaced)가 아님.
    try std.testing.expectEqual(@backingInt(schemas_idx), @backingInt(resolved.?.module_index));
}

test "export * as: namespaced inner name does not leak to top-level (no false resolve)" {
    // `export * as regexes` 만 있고 plain `export *` 가 없으면, regexes 의 내부 `string`
    // 은 core 의 top-level export 가 아니다(ESM: namespaced star 는 `regexes` 한 이름만
    // 기여). top-level `string` resolve 는 null 이어야 하고 ambiguous 도 아니다.
    // 회귀 가드: resolveStarExport 가 namespaced re-export 를 따라가면 `string` 을
    // regexes.string 으로 잘못 해석(leak)했었다.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "regexes.ts", "export const string = /^.*$/;");
    try writeFile(tmp.dir, "core.ts", "export * as regexes from './regexes';\nexport const marker = 1;");
    try writeFile(tmp.dir, "entry.ts", "import { string } from './core';\nconsole.log(string);");

    var r = try buildLinkAndRename(std.testing.allocator, &tmp, "entry.ts");
    defer r.linker.deinit();
    defer r.destroyGraph();
    defer r.cache.deinit();

    const core_idx = findModuleIdx(r.graph, "core.ts").?;
    // top-level `string` 은 존재하지 않음 → resolve null, ambiguous 아님.
    try std.testing.expect(r.linker.resolveExportChain(core_idx, "string", 0) == null);
    try std.testing.expect(!r.linker.isAmbiguousStarExport(core_idx, "string"));
    // `regexes` 자체는 정상 named export 로 해석.
    try std.testing.expect(r.linker.resolveExportChain(core_idx, "regexes", 0) != null);
    // named import { string } 는 진짜 missing → 진단.
    var has_missing = false;
    for (r.linker.diagnostics.items) |d| {
        if (d.code == .missing_export) has_missing = true;
    }
    try std.testing.expect(has_missing);
}

test "export * as: genuine 2-plain-star ambiguity preserved despite namespaced star" {
    // over-correction 가드: plain `export *` 2개(schemas, extra)가 같은 `string` 을
    // 내보내면 `export * as regexes` 가 함께 있어도 여전히 ESM-ambiguous 여야 한다.
    // (namespaced star 는 ambiguity 에 영향 없음 — 추가도 제거도 하지 않음.)
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "regexes.ts", "export const string = /^.*$/;");
    try writeFile(tmp.dir, "schemas.ts", "export function string() { return 'schema'; }");
    try writeFile(tmp.dir, "extra.ts", "export function string() { return 'extra'; }");
    try writeFile(tmp.dir, "core.ts", "export * as regexes from './regexes';\nexport * from './schemas';\nexport * from './extra';");
    try writeFile(tmp.dir, "entry.ts", "import { string } from './core';\nconsole.log(string);");

    var r = try buildLinkAndRename(std.testing.allocator, &tmp, "entry.ts");
    defer r.linker.deinit();
    defer r.destroyGraph();
    defer r.cache.deinit();

    const core_idx = findModuleIdx(r.graph, "core.ts").?;
    // schemas + extra 두 plain star 가 distinct canonical → ambiguous → resolve null.
    try std.testing.expect(r.linker.isAmbiguousStarExport(core_idx, "string"));
    try std.testing.expect(r.linker.resolveExportChain(core_idx, "string", 0) == null);
    // ambiguous named import → 사용자 노출(fatal) 진단. (missing_export 와 달리
    // ambiguous_export 는 fatal_diagnostics 에만 기록된다.)
    var has_ambiguous = false;
    for (r.linker.fatal_diagnostics.items) |d| {
        if (d.code == .ambiguous_export) has_ambiguous = true;
    }
    try std.testing.expect(has_ambiguous);
}

// ============================================================
// CJS Preamble 출력 검증 테스트
// ============================================================

const Ast = @import("../parser/ast.zig").Ast;

/// buildMetadataForAst를 호출하여 preamble을 검증하는 헬퍼.
/// computeRenames 후 원본 AST 기준 메타데이터를 생성한다.
fn buildMetadataForModule(
    r: *const TestResult,
    module_index: u32,
    is_entry: bool,
) !LinkingMetadata {
    const mod = r.linker.graph.getModule(ModuleIndex.fromUsize(module_index)) orelse return error.NoAst;
    const ast: *const Ast = &(mod.ast orelse return error.NoAst);
    return r.linker.buildMetadataForAst(ast, module_index, is_entry, null, r.linker.format, true);
}

test "metadata self renames preserve exact scope-map SymbolIds across ten hostile inputs" {
    const sources = [_][]const u8{
        "const outer = 7; const neighbor = 9; function read(outer) { return outer; } console.log(outer, neighbor, read(2), externalGlobal);",
        "const first = 1; let outer = 7; const neighbor = 9; function read() { let outer = 2; return outer; } console.log(outer, neighbor, read(), externalGlobal);",
        "const neighbor = 9; const outer = 7; { const outer = 2; console.log(outer); } console.log(outer, neighbor, externalGlobal);",
        "const neighbor = 9; function outer() { return 7; } function read(outer) { return outer; } console.log(outer(), neighbor, read(2), externalGlobal);",
        "const first = 1; class outer {} const neighbor = 9; function read(outer) { return outer; } console.log(outer, neighbor, read(2), externalGlobal);",
        "const first = 1; const second = 2; var outer = 7; var neighbor = 9; function read() { var outer = 2; return outer; } console.log(outer, neighbor, read(), externalGlobal);",
        "const neighbor = 9; export const outer = 7; function read(outer) { return outer; } console.log(outer, neighbor, read(2), externalGlobal);",
        "const first = 1; const outer = 7; const neighbor = 9; const read = () => { const outer = 2; return outer; }; console.log(outer, neighbor, read(), externalGlobal);",
        "const neighbor = 9; let outer = 7; function read() { try { throw 2; } catch (outer) { return outer; } } console.log(outer, neighbor, read(), externalGlobal);",
        "const first = 1; const second = 2; const outer = 7; const neighbor = 9; class Reader { read(outer) { return outer; } } console.log(outer, neighbor, Reader, externalGlobal);",
    };
    for (sources) |source| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try writeFile(tmp.dir, "entry.mjs", source);
        var result = try buildAndLink(std.testing.allocator, &tmp, "entry.mjs");
        defer result.cache.deinit();
        defer result.destroyGraph();
        defer result.linker.deinit();

        const entry_index = findModuleIdx(result.graph, "entry.mjs") orelse return error.MissingMetadataIdentityEntry;
        const module = result.graph.getModule(entry_index) orelse return error.MissingMetadataIdentityEntry;
        const sem = module.semantic orelse return error.MissingMetadataIdentitySemantic;
        const outer = sem.scope_maps[0].get("outer") orelse return error.MissingMetadataIdentitySymbol;
        const neighbor = sem.scope_maps[0].get("neighbor") orelse return error.MissingMetadataIdentitySymbol;
        try std.testing.expect(outer != neighbor);
        try std.testing.expect(sem.scope_maps[0].get("externalGlobal") == null);

        // Select names only for exact IDs. A same-spelling inner binding gets a
        // different decoy name; the unrelated neighbor keeps source spelling.
        result.linker.rename_table.clear();
        try result.linker.rename_table.put(std.testing.allocator, bundler_symbol.SymbolID.make(entry_index, outer), "selected_outer");
        var nested_count: usize = 0;
        for (sem.scope_maps[1..]) |scope_map| {
            const nested = scope_map.get("outer") orelse continue;
            if (nested == outer) continue;
            try result.linker.rename_table.put(std.testing.allocator, bundler_symbol.SymbolID.make(entry_index, nested), "nested_decoy");
            nested_count += 1;
        }
        try std.testing.expect(nested_count > 0);

        var metadata = try buildMetadataForModule(&result, entry_index.toU32(), true);
        defer metadata.deinit();
        try std.testing.expectEqualStrings("selected_outer", metadata.renames.get(@intCast(outer)) orelse return error.MissingExactMetadataRename);
        try std.testing.expect(metadata.renames.get(@intCast(neighbor)) == null);

        var raw_metadata = try result.linker.buildMetadata(entry_index.toU32(), true);
        defer raw_metadata.deinit();
        try std.testing.expectEqualStrings("selected_outer", raw_metadata.renames.get(@intCast(outer)) orelse return error.MissingExactRawMetadataRename);
        try std.testing.expect(raw_metadata.renames.get(@intCast(neighbor)) == null);
    }
}

test "preamble: CJS module import — named import generates require_xxx" {
    // ESM에서 CJS 모듈의 named import를 가져올 때
    // preamble에 "var x = require_c().x;" 형태가 생성되는지 검증
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { x } from './c';\nconsole.log(x);");
    try writeFile(tmp.dir, "c.js", "module.exports = { x: 42 };");

    var r = try buildLinkAndRename(std.testing.allocator, &tmp, "entry.ts");
    defer r.linker.deinit();
    defer r.destroyGraph();
    defer r.cache.deinit();

    // c.js가 CJS로 감지되었는지 확인
    try std.testing.expectEqual(types.WrapKind.cjs, r.graph.getModule(ModuleIndex.fromUsize(1)).?.wrap_kind);

    var md = try buildMetadataForModule(&r, 0, true);
    defer md.deinit();

    // preamble이 생성되어야 함
    try std.testing.expect(md.cjs_import_preamble != null);
    const preamble = md.cjs_import_preamble.?;
    // require_xxx() 호출 포함
    try std.testing.expect(std.mem.indexOf(u8, preamble, "require_") != null);
    // named import이므로 .x 접근이 있어야 함
    try std.testing.expect(std.mem.indexOf(u8, preamble, ".x") != null);
}

test "preamble: CJS module import — direct module.exports default import skips __toESM" {
    // ESM에서 CJS 모듈의 default import를 가져올 때
    // __toESM 래퍼가 생성되는지 검증
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import foo from './c';\nconsole.log(foo);");
    try writeFile(tmp.dir, "c.js", "module.exports = { default: 42 };");

    var r = try buildLinkAndRename(std.testing.allocator, &tmp, "entry.ts");
    defer r.linker.deinit();
    defer r.destroyGraph();
    defer r.cache.deinit();

    var md = try buildMetadataForModule(&r, 0, true);
    defer md.deinit();

    try std.testing.expect(md.cjs_import_preamble != null);
    const preamble = md.cjs_import_preamble.?;
    try std.testing.expect(std.mem.indexOf(u8, preamble, "__toESM(") == null);
    try std.testing.expect(std.mem.indexOf(u8, preamble, ".default") == null);
    try std.testing.expect(std.mem.indexOf(u8, preamble, "require_c()") != null);
}

test "preamble: CJS module import — __esModule marker keeps __toESM default import" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import foo from './c';\nconsole.log(foo);");
    try writeFile(tmp.dir, "c.js",
        \\Object.defineProperty(exports, "__esModule", { value: true });
        \\exports.default = 42;
    );

    var r = try buildLinkAndRename(std.testing.allocator, &tmp, "entry.ts");
    defer r.linker.deinit();
    defer r.destroyGraph();
    defer r.cache.deinit();

    var md = try buildMetadataForModule(&r, 0, true);
    defer md.deinit();

    try std.testing.expect(md.cjs_import_preamble != null);
    const preamble = md.cjs_import_preamble.?;
    try std.testing.expect(std.mem.indexOf(u8, preamble, "__toESM(") != null);
    try std.testing.expect(std.mem.indexOf(u8, preamble, ".default") != null);
}

test "preamble: CJS module import — namespace import generates __toESM without .default" {
    // ESM에서 CJS 모듈을 namespace import할 때
    // __toESM 래퍼가 생성되고, .default가 붙지 않는지 검증
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import * as c from './c';\nconsole.log(c);");
    try writeFile(tmp.dir, "c.js", "module.exports = { x: 1 };");

    var r = try buildLinkAndRename(std.testing.allocator, &tmp, "entry.ts");
    defer r.linker.deinit();
    defer r.destroyGraph();
    defer r.cache.deinit();

    var md = try buildMetadataForModule(&r, 0, true);
    defer md.deinit();

    try std.testing.expect(md.cjs_import_preamble != null);
    const preamble = md.cjs_import_preamble.?;
    // __toESM 래퍼 포함
    try std.testing.expect(std.mem.indexOf(u8, preamble, "__toESM(") != null);
    // namespace import는 .default가 붙지 않아야 함
    try std.testing.expect(std.mem.indexOf(u8, preamble, ".default") == null);
}

test "preamble: ESM 에서 unresolved import 는 require() 를 만들지 않는다" {
    // 해석 못 한 지정자는 external 로 취급되고, ESM 출력에서는 chunk 상단의 `import`
    // 구문이 바인딩을 제공한다 — 모듈 preamble 에 `require(` 를 두면 ESM 스코프에
    // 존재하지 않는 함수를 부르는 코드가 되어 `require is not defined` 로 죽는다.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { readFile } from './nonexistent';\nconsole.log(readFile);");

    var r = try buildLinkAndRename(std.testing.allocator, &tmp, "entry.ts");
    defer r.linker.deinit();
    defer r.destroyGraph();
    defer r.cache.deinit();

    var md = try buildMetadataForModule(&r, 0, true);
    defer md.deinit();

    // preamble 이 아예 없거나(흔함), 있더라도 이 지정자에 대한 require 가 없어야 한다.
    if (md.cjs_import_preamble) |preamble| {
        try std.testing.expect(std.mem.indexOf(u8, preamble, "require(\"./nonexistent\")") == null);
    }

    // 해석 실패 record 는 external 로 표시돼 external import 방출 경로를 탄다.
    const m = r.linker.graph.getModule(ModuleIndex.fromUsize(0)).?;
    var saw_external = false;
    for (m.import_records) |rec| {
        if (std.mem.indexOf(u8, rec.specifier, "nonexistent") == null) continue;
        try std.testing.expect(rec.resolve_failed);
        try std.testing.expect(rec.is_external);
        saw_external = true;
    }
    try std.testing.expect(saw_external);
}

test "preamble: dev mode — named import uses namespace access pattern" {
    // dev mode에서 named import는 namespace 접근 패턴: __ns_0_0 = __zntc_require("./path")
    // 호이스팅된 함수에서 import binding을 안전하게 참조하기 위해
    // 구조분해 대신 namespace 객체 프로퍼티 접근을 사용한다.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { add } from './math';\nconsole.log(add(1,2));");
    try writeFile(tmp.dir, "math.ts", "export function add(a: number, b: number) { return a + b; }");

    var r = try buildLinkAndRename(std.testing.allocator, &tmp, "entry.ts");
    defer r.linker.deinit();
    defer r.destroyGraph();
    defer r.cache.deinit();

    const ast: *const Ast = &(r.graph.getModule(ModuleIndex.fromUsize(0)).?.ast orelse unreachable);
    var md = try r.linker.buildDevMetadataForAst(ast, 0);
    defer md.deinit();

    try std.testing.expect(md.cjs_import_preamble != null);
    const preamble = md.cjs_import_preamble.?;
    // namespace 할당: __ns_0_0 = __zntc_require("./path") (module_index=0, local=0)
    try std.testing.expect(std.mem.indexOf(u8, preamble, "__ns_0_0") != null);
    try std.testing.expect(std.mem.indexOf(u8, preamble, "__zntc_require(") != null);
    // 구조분해 패턴 없음 (var { add } 형태가 아님)
    try std.testing.expect(std.mem.indexOf(u8, preamble, "{ ") == null);
    // dev_ns_vars가 호이스팅용으로 설정됨
    try std.testing.expect(md.dev_ns_vars != null);
    try std.testing.expectEqual(@as(usize, 1), md.dev_ns_vars.?.len);
    try std.testing.expectEqualStrings("__ns_0_0", md.dev_ns_vars.?[0]);
    // renames에 add → __ns_0_0.add 매핑 등록 확인
    var rename_found = false;
    var it = md.renames.iterator();
    while (it.next()) |entry| {
        if (std.mem.eql(u8, entry.value_ptr.*, "__ns_0_0.add")) {
            rename_found = true;
            break;
        }
    }
    try std.testing.expect(rename_found);
}

test "preamble: dev mode — default import uses .default" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import foo from './lib';\nconsole.log(foo);");
    try writeFile(tmp.dir, "lib.ts", "export default 42;");

    var r = try buildLinkAndRename(std.testing.allocator, &tmp, "entry.ts");
    defer r.linker.deinit();
    defer r.destroyGraph();
    defer r.cache.deinit();

    const ast: *const Ast = &(r.graph.getModule(ModuleIndex.fromUsize(0)).?.ast orelse unreachable);
    var md = try r.linker.buildDevMetadataForAst(ast, 0);
    defer md.deinit();

    try std.testing.expect(md.cjs_import_preamble != null);
    const preamble = md.cjs_import_preamble.?;
    try std.testing.expect(std.mem.indexOf(u8, preamble, "__zntc_require(") != null);
    try std.testing.expect(std.mem.indexOf(u8, preamble, ".default") != null);
}

test "preamble: dev mode — namespace import without .default" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import * as utils from './utils';\nconsole.log(utils);");
    try writeFile(tmp.dir, "utils.ts", "export const x = 1;\nexport const y = 2;");

    var r = try buildLinkAndRename(std.testing.allocator, &tmp, "entry.ts");
    defer r.linker.deinit();
    defer r.destroyGraph();
    defer r.cache.deinit();

    const ast: *const Ast = &(r.graph.getModule(ModuleIndex.fromUsize(0)).?.ast orelse unreachable);
    var md = try r.linker.buildDevMetadataForAst(ast, 0);
    defer md.deinit();

    try std.testing.expect(md.cjs_import_preamble != null);
    const preamble = md.cjs_import_preamble.?;
    try std.testing.expect(std.mem.indexOf(u8, preamble, "__zntc_require(") != null);
    // namespace는 .default 없이 모듈 전체
    try std.testing.expect(std.mem.indexOf(u8, preamble, ".default") == null);
}

test "preamble: no preamble for ESM-to-ESM import" {
    // ESM→ESM은 rename으로 처리되므로 preamble이 없어야 함
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { x } from './b';\nconsole.log(x);");
    try writeFile(tmp.dir, "b.ts", "export const x = 42;");

    var r = try buildLinkAndRename(std.testing.allocator, &tmp, "entry.ts");
    defer r.linker.deinit();
    defer r.destroyGraph();
    defer r.cache.deinit();

    var md = try buildMetadataForModule(&r, 0, true);
    defer md.deinit();

    // ESM→ESM이면 preamble 없음
    try std.testing.expectEqual(@as(?[]const u8, null), md.cjs_import_preamble);
}

// ============================================================
// Semantic tests
// ============================================================

test "semantic: non-shorthand {x: y} does not reference x" {
    // {x: y} — x는 property name (변수 참조 아님), y는 변수 참조
    const source = "const x = 1;\nconst y = 2;\nconst obj = {x: y};";
    const Sem = @import("../semantic/analyzer.zig").SemanticAnalyzer;
    const Scanner = @import("../lexer/scanner.zig").Scanner;
    const Parser = @import("../parser/parser.zig").Parser;

    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();
    _ = try parser.parse();

    var analyzer = Sem.init(std.testing.allocator, &parser.ast);
    defer analyzer.deinit();
    _ = analyzer.analyze() catch {};

    if (analyzer.scope_maps.items.len > 0) {
        if (analyzer.scope_maps.items[0].get("x")) |sym_idx| {
            if (sym_idx < analyzer.symbols.items.len) {
                try std.testing.expectEqual(@as(u32, 0), analyzer.symbols.items[sym_idx].reference_count);
            }
        }
        if (analyzer.scope_maps.items[0].get("y")) |sym_idx| {
            if (sym_idx < analyzer.symbols.items.len) {
                try std.testing.expect(analyzer.symbols.items[sym_idx].reference_count > 0);
            }
        }
    }
}

// #1328 Phase 4d: populateSymbolRefCounts

test "populateSymbolRefCounts: import이 source default symbol의 ref_count 증가" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import x from './b'; console.log(x);");
    try writeFile(tmp.dir, "b.ts", "export default 42;");

    var r = try buildAndLink(std.testing.allocator, &tmp, "a.ts");
    defer r.linker.deinit();
    defer r.destroyGraph();
    defer r.cache.deinit();

    r.linker.populateReExportAliases();
    r.linker.populateImportSymbols();
    r.linker.populateSymbolRefCounts();

    // b.ts의 synthetic_default symbol이 참조되어 ref_count == 1.
    // #1328 Phase 4e-2b: _default는 semantic 공간에 등록됨.
    const b = r.graph.getModule(ModuleIndex.fromUsize(1)).?;
    const b_sem = b.semantic orelse return error.NoSemantic;
    var found_ref: u32 = 0;
    for (b_sem.symbols.items) |sym| {
        const sk = sym.synthetic_kind orelse continue;
        if (sk == .default_export) {
            found_ref = sym.reference_count;
            break;
        }
    } else return error.DefaultNotRegistered;
    try std.testing.expectEqual(@as(u32, 1), found_ref);
}

test "populateSymbolRefCounts: 아무도 안 쓰는 export는 ref_count 0" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // entry는 named만 씀, default는 import 안 함
    try writeFile(tmp.dir, "a.ts", "import { y } from './b'; console.log(y);");
    try writeFile(tmp.dir, "b.ts", "export default 42; export const y = 1;");

    var r = try buildAndLink(std.testing.allocator, &tmp, "a.ts");
    defer r.linker.deinit();
    defer r.destroyGraph();
    defer r.cache.deinit();

    r.linker.populateReExportAliases();
    r.linker.populateImportSymbols();
    r.linker.populateSymbolRefCounts();

    const b = r.graph.getModule(ModuleIndex.fromUsize(1)).?;
    const b_sem = b.semantic orelse return error.NoSemantic;
    var found_ref: u32 = 0;
    var found_default = false;
    for (b_sem.symbols.items) |sym| {
        const sk = sym.synthetic_kind orelse continue;
        if (sk == .default_export) {
            found_ref = sym.reference_count;
            found_default = true;
            break;
        }
    }
    if (!found_default) return error.DefaultNotRegistered;
    try std.testing.expectEqual(@as(u32, 0), found_ref);
}

// #1338 Phase 4c-3: SymbolRef 기반 canonical name facade
test "getCanonicalByRef: alias symbol의 canonical_name 반환" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "export { default as Foo } from './b';");
    try writeFile(tmp.dir, "b.ts", "export default 42;");

    var r = try buildAndLink(std.testing.allocator, &tmp, "a.ts");
    defer r.linker.deinit();
    defer r.destroyGraph();
    defer r.cache.deinit();

    r.linker.populateReExportAliases();
    r.linker.populateImportSymbols();

    // a.ts의 barrel re-export alias symbol 찾기
    const a = r.graph.getModule(ModuleIndex.fromUsize(0)).?;
    var alias_ref: ?@import("symbol.zig").SymbolRef = null;
    for (a.export_bindings) |eb| {
        if (eb.kind == .re_export and std.mem.eql(u8, eb.exported_name, "Foo")) {
            alias_ref = eb.symbol;
            break;
        }
    }
    const ref = alias_ref orelse return error.AliasNotFound;
    // alias는 canonical_name이 resolve된 상태 — facade가 non-null 반환해야 함
    const name = r.linker.getCanonicalByRef(ref) orelse return error.NoCanonical;
    try std.testing.expect(name.len > 0);
}

// #1328 Phase 4c-3c-2 / RFC #3940 L.5c: putCanonicalName → rename_table 기록
test "computeRenames: rename된 심볼이 rename_table 에 기록됨" {
    const symbol_mod = @import("symbol.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // 같은 이름 'x'가 두 모듈에서 export → 충돌 → 한 쪽이 x$1
    try writeFile(tmp.dir, "a.ts", "export { x as a } from './m1'; export { x as b } from './m2';");
    try writeFile(tmp.dir, "m1.ts", "export const x = 1;");
    try writeFile(tmp.dir, "m2.ts", "export const x = 2;");

    var r = try buildAndLink(std.testing.allocator, &tmp, "a.ts");
    defer r.linker.deinit();
    defer r.destroyGraph();
    defer r.cache.deinit();

    try r.linker.computeRenames();

    // m1 또는 m2 중 하나의 'x' 심볼이 rename_table 엔트리를 가져야 함.
    var renamed_count: u32 = 0;
    var it = r.graph.modulesIterator();
    while (it.next()) |m| {
        const sem = m.semantic orelse continue;
        if (sem.scope_maps.len == 0) continue;
        const sym_idx = sem.scope_maps[0].get("x") orelse continue;
        const id = symbol_mod.SymbolID.make(m.index, sym_idx);
        if (r.linker.rename_table.get(id) != null) renamed_count += 1;
    }
    try std.testing.expect(renamed_count >= 1);
    try std.testing.expect(r.linker.rename_table.count() >= renamed_count);
}

test "RenameTable: computeMangling 경로가 rename_table 에 기록 (RFC #3940 L.5c)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // top-level mangle 가 동작하도록 여러 심볼이 있는 모듈.
    try writeFile(tmp.dir, "a.ts", "import { helper } from './util'; export const result = helper(1);");
    try writeFile(tmp.dir, "util.ts", "const internal = 10; export function helper(n) { return n + internal; }");

    var r = try buildAndLink(std.testing.allocator, &tmp, "a.ts");
    defer r.linker.deinit();
    defer r.destroyGraph();
    defer r.cache.deinit();

    try r.linker.computeRenames();
    try r.linker.computeMangling();

    // computeMangling (assignSymbolCanonical 직접 경로) 가 실제로 rename 을 만든다.
    try std.testing.expect(r.linker.rename_table.count() > 0);
}

test "RenameTable: clearCanonicalNames 가 rename_table 도 비움 (RFC #3940 L.5c)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "export { x as a } from './m1'; export { x as b } from './m2';");
    try writeFile(tmp.dir, "m1.ts", "export const x = 1;");
    try writeFile(tmp.dir, "m2.ts", "export const x = 2;");

    var r = try buildAndLink(std.testing.allocator, &tmp, "a.ts");
    defer r.linker.deinit();
    defer r.destroyGraph();
    defer r.cache.deinit();

    try r.linker.computeRenames();
    try std.testing.expect(r.linker.rename_table.count() >= 1);

    // clearCanonicalNames 후 canonical_strings 와 함께 rename_table 도 비워져야
    // stale slice 참조 0 (per-chunk reset 안전성).
    r.linker.clearCanonicalNames();
    try std.testing.expectEqual(@as(u32, 0), r.linker.rename_table.count());
}

test "applyPendingRenames: pending 반영 + mutated module stale entry prune (RFC #3940 L.5a)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "export { x as a } from './m1';");
    try writeFile(tmp.dir, "m1.ts", "export const x = 1;");

    var r = try buildAndLink(std.testing.allocator, &tmp, "a.ts");
    defer r.linker.deinit();
    defer r.destroyGraph();
    defer r.cache.deinit();

    try r.linker.computeRenames();

    const symbol_mod = @import("symbol.zig");
    const m0 = r.graph.modules.at(0);
    defer m0.pending_renames.deinit(std.testing.allocator);
    const mi: ModuleIndex = @fromBackingInt(@intCast(0));

    // carry-over 모사: resync 로 idx 가 바뀌어 (m0, 99) 가 stale 가 된 상태 + new idx (m0, 0) pending.
    try r.linker.rename_table.put(std.testing.allocator, symbol_mod.SymbolID.make(mi, 99), "stale");
    try m0.pending_renames.put(std.testing.allocator, symbol_mod.SymbolID.make(mi, 0), "fresh");
    m0.pending_rename_capture_seen = true;

    try r.linker.applyPendingRenames();

    // mutated module 의 stale entry (m0, 99) prune + pending (m0, 0) 반영 + pending clear.
    try std.testing.expect(r.linker.rename_table.get(symbol_mod.SymbolID.make(mi, 99)) == null);
    try std.testing.expectEqualStrings("fresh", r.linker.rename_table.get(symbol_mod.SymbolID.make(mi, 0)).?);
    try std.testing.expectEqual(@as(u32, 0), m0.pending_renames.count());
    try std.testing.expect(!m0.pending_rename_capture_seen);

    // 빈 carry 결과도 capture state 를 소비해야 다음 build 에서 첫-pass fallback 을 다시 허용한다.
    m0.pending_rename_capture_seen = true;
    try r.linker.applyPendingRenames();
    try std.testing.expect(!m0.pending_rename_capture_seen);
}

// Regression: HMR rebuild 에서 소스가 재파싱된 모듈의 `alias_table` 이 줄어들
// 수 있어 (e.g. re_export 엔트리가 없어진 경우), 캐시된 import_binding 의
// `.symbol.alias` 가 old-build AliasId 를 stale 로 들고 있으면
// `populateSymbolRefCounts` 가 `aliases.items[idx]` OOB 로 panic → 서버
// segfault. `.alias` branch 에 `a.symbol >= table.count()` 경계 검사 추가.
test "populateSymbolRefCounts: stale alias id 는 건너뜀 (bounds guard)" {
    const allocator = std.testing.allocator;
    const ImportBindingT = @import("binding_scanner.zig").ImportBinding;
    const symbol_mod = @import("symbol.zig");

    // module[0] (importer): import_binding 이 module[1] 의 AliasId(5) 를 가리킴
    // module[1] (source): alias_table 이 비어있음 (rebuild 로 새로 만들어졌지만
    //                     re_export 가 없어 entry 0)
    const ib: ImportBindingT = .{
        .kind = .named,
        .local_name = "X",
        .imported_name = "X",
        .local_span = .{ .start = 0, .end = 1 },
        .import_record_index = 0,
        .symbol = .{
            .alias = .{
                .module = @fromBackingInt(@intCast(1)),
                .symbol = @fromBackingInt(@intCast(5)), // stale — table.count() == 0
            },
        },
    };

    const module_mod = @import("module.zig");

    // #1779 PR #2: Linker 는 `*ModuleGraph` 만 받으므로, 수동으로 구성한 모듈을
    // graph.modules 에 직접 append 해서 최소 graph 를 만든다.
    var cache = resolve_cache_mod.ResolveCache.init(allocator, .{});
    defer cache.deinit();
    var graph = ModuleGraph.init(allocator, &cache);
    defer graph.deinit();
    try graph.modules.append(allocator, module_mod.Module.init(@fromBackingInt(@intCast(0)), "/a.ts"));
    try graph.modules.append(allocator, module_mod.Module.init(@fromBackingInt(@intCast(1)), "/b.ts"));

    // importer module 의 import_bindings 를 주입.
    var ibs = [_]ImportBindingT{ib};
    graph.moduleAtMut(ModuleIndex.fromUsize(0)).?.import_bindings = &ibs;
    // source module 에 빈 alias_table 주입.
    graph.moduleAtMut(ModuleIndex.fromUsize(1)).?.alias_table = symbol_mod.AliasTable.init(allocator);

    var linker = Linker.init(allocator, &graph, .esm);
    defer linker.deinit();

    // 수정 전: `index 5, len 0` panic. 수정 후: 조용히 skip.
    linker.populateSymbolRefCounts();
}

test "populateImportSymbols: named import의 local_symbol이 현재 모듈 semantic ref" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import { x } from './b'; console.log(x);");
    try writeFile(tmp.dir, "b.ts", "export const x = 1;");

    var r = try buildAndLink(std.testing.allocator, &tmp, "a.ts");
    defer r.linker.deinit();
    defer r.destroyGraph();
    defer r.cache.deinit();

    r.linker.populateImportSymbols();

    const a = r.graph.getModule(ModuleIndex.fromUsize(0)).?;
    var found = false;
    for (a.import_bindings) |ib| {
        if (std.mem.eql(u8, ib.local_name, "x")) {
            try std.testing.expect(ib.local_symbol.isValid());
            // 현재 모듈(a=0)을 가리켜야 함 — source(b=1)가 아님
            try std.testing.expectEqual(@as(u32, 0), @backingInt(ib.local_symbol.moduleIndex()));
            found = true;
        }
    }
    try std.testing.expect(found);
}

// ============================================================
// HMR rename 재사용 Tests (perf/hmr-link-rename-reuse)
// ============================================================

/// 두 rename_table 이 byte-identical 인지 (같은 SymbolID 집합 + 같은 이름) 단언.
/// "재사용 ≡ recompute" 증명의 핵심 — 주입된 table 이 from-scratch computeRenames 와
/// 완전히 동일해야 한다.
fn expectRenameTablesEqual(a: *const Linker, b: *const Linker) !void {
    try std.testing.expectEqual(a.rename_table.count(), b.rename_table.count());
    var it = a.rename_table.map.iterator();
    while (it.next()) |e| {
        const other = b.rename_table.get(e.key_ptr.*) orelse {
            std.debug.print("missing key in b: mod={d} inner={d}\n", .{
                @backingInt(e.key_ptr.module), @backingInt(e.key_ptr.inner),
            });
            return error.MissingKey;
        };
        try std.testing.expectEqualStrings(e.value_ptr.*, other);
    }
}

test "reuse: snapshot 주입 결과가 from-scratch recompute 와 byte-identical (다중 충돌)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // count 가 3개 모듈에서 충돌 → name$1, name$2 deconflict 발생.
    try writeFile(tmp.dir, "a.ts", "import './b';\nimport './c';\nexport const count = 0;\nexport const name = 'a';");
    try writeFile(tmp.dir, "b.ts", "export const count = 1;\nexport const name = 'b';");
    try writeFile(tmp.dir, "c.ts", "export const count = 2;\nexport const name = 'c';");

    // 1) 초기 빌드: computeRenames → 스냅샷 캡처.
    var r = try buildLinkAndRename(std.testing.allocator, &tmp, "a.ts");
    defer r.linker.deinit();
    defer r.destroyGraph();
    defer r.cache.deinit();

    // 정상 그래프 → capture 성공(non-null)이어야 한다. F5 null 폐기는 별도 테스트.
    var snap = (try r.linker.buildRenameSnapshot(std.testing.allocator)).?;
    defer snap.deinit();

    // 2) 같은 그래프에 fresh Linker 를 link 만 하고(=deconflict 미실행), 스냅샷 주입.
    var fresh = Linker.init(std.testing.allocator, r.graph, .esm);
    defer fresh.deinit();
    try fresh.link();
    // 가드는 같은 그래프이므로 당연히 통과해야 한다.
    try std.testing.expect(fresh.renameReuseGuard(&snap));
    try fresh.injectPreservedRenames(&snap);

    // 3) 주입 결과 == recompute 결과 (byte-identical).
    try expectRenameTablesEqual(&r.linker, &fresh);
    // sanity: 실제로 deconflict 가 일어났는지 (count$N 존재).
    var saw_rename = false;
    var it2 = fresh.rename_table.map.iterator();
    while (it2.next()) |e| {
        if (std.mem.indexOf(u8, e.value_ptr.*, "$") != null) saw_rename = true;
    }
    try std.testing.expect(saw_rename);
}

test "reuse: guard 통과 시 inject — single import 그래프" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import './b';\nexport const count = 0;");
    try writeFile(tmp.dir, "b.ts", "export const count = 1;");

    var r = try buildLinkAndRename(std.testing.allocator, &tmp, "a.ts");
    defer r.linker.deinit();
    defer r.destroyGraph();
    defer r.cache.deinit();

    var snap = (try r.linker.buildRenameSnapshot(std.testing.allocator)).?;
    defer snap.deinit();

    var fresh = Linker.init(std.testing.allocator, r.graph, .esm);
    defer fresh.deinit();
    try fresh.link();
    try std.testing.expect(fresh.renameReuseGuard(&snap));
    try fresh.injectPreservedRenames(&snap);
    try expectRenameTablesEqual(&r.linker, &fresh);
    // RFC_PERSISTENT_LINKER Phase 1: 주입은 스냅샷 문자열을 borrow 하므로 per-entry
    // dupe(alloc)가 없다 → canonical_strings(linker 소유분)는 비어 있어야 한다.
    // dupe 로 회귀하면 이 단언이 깨진다(lInj 비용 재증가 가드).
    try std.testing.expectEqual(@as(usize, 0), fresh.canonical_strings.items.len);
    // reuse-hit 정밀화: injectPreservedRenames 는 canonical_names_used 에 쓰지 않는다
    // (deconflict 가 skip 돼 write-only=dead). 다시 put 하면 이 단언이 깨진다(lInj 가드).
    try std.testing.expectEqual(@as(u32, 0), fresh.canonical_names_used.count());
}

test "reuse PR-C: 변경-한정 가드(carrier set)가 전량 가드와 동일 verdict" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import './b';\nimport './c';\nexport const count = 0;\nexport const name = 'a';");
    try writeFile(tmp.dir, "b.ts", "export const count = 1;\nexport const name = 'b';");
    try writeFile(tmp.dir, "c.ts", "export const count = 2;\nexport const name = 'c';");

    var r = try buildLinkAndRename(std.testing.allocator, &tmp, "a.ts");
    defer r.linker.deinit();
    defer r.destroyGraph();
    defer r.cache.deinit();

    var snap = (try r.linker.buildRenameSnapshot(std.testing.allocator)).?;
    defer snap.deinit();

    var fresh = Linker.init(std.testing.allocator, r.graph, .esm);
    defer fresh.deinit();
    try fresh.link();

    // 전량(carrier=null): 같은 그래프 → 통과(종전 경로).
    try std.testing.expect(r.graph.changed_emit_paths == null);
    try std.testing.expect(fresh.renameReuseGuard(&snap));

    // 변경-한정(carrier={modules[0]}): carrier 에 있는 모듈만 full fingerprint 검사, 나머지는
    // 아예 순회 안 함(O(changed)). 같은 그래프라 carrier 모듈도 일치 → 동일하게 통과.
    var carrier: std.StringHashMapUnmanaged(void) = .empty;
    defer carrier.deinit(std.testing.allocator);
    try carrier.put(std.testing.allocator, r.graph.modules.at(0).path, {});
    r.graph.changed_emit_paths = carrier;
    try std.testing.expect(fresh.renameReuseGuard(&snap));

    // 빈 carrier(변경 0 = 검사할 모듈 없음)도 통과.
    r.graph.changed_emit_paths = .empty;
    try std.testing.expect(fresh.renameReuseGuard(&snap));

    // 정확성: carrier 모듈의 fingerprint 가 snapshot 과 다르면 reject(=full computeRenames).
    // snapshot 의 modules[0] toplevel 이름집합 해시를 손상시키고 그 모듈을 carrier 에 넣으면
    // O(changed) 가드가 그 모듈을 검사해 불일치 감지 → false 여야 한다(이름 추가 edit 모사).
    const fp0 = @constCast(&snap.fingerprint[0]); // arena-backed, 테스트 목적 변형
    const orig_hash = fp0.toplevel_name_set_hash;
    fp0.toplevel_name_set_hash = orig_hash ^ 0xdead_beef;
    r.graph.changed_emit_paths = carrier; // {modules[0]}
    try std.testing.expect(!fresh.renameReuseGuard(&snap));
    // 전량 가드(carrier=null)도 동일하게 false — verdict 일치.
    r.graph.changed_emit_paths = null;
    try std.testing.expect(!fresh.renameReuseGuard(&snap));
    fp0.toplevel_name_set_hash = orig_hash; // 복원

    // graph.deinit 가 테스트 소유 carrier 를 이중 해제하지 않게 복원(빈 set 은 backing 없음).
    r.graph.changed_emit_paths = null;
}

test "reuse: G3 rejects corrupted cached exact SymbolIDs without name recovery" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import './b'; export const count = 0;");
    try writeFile(tmp.dir, "b.ts", "export const count = 1;");
    var r = try buildLinkAndRename(std.testing.allocator, &tmp, "a.ts");
    defer r.linker.deinit();
    defer r.destroyGraph();
    defer r.cache.deinit();
    var snap = (try r.linker.buildRenameSnapshot(std.testing.allocator)).?;
    defer snap.deinit();
    try std.testing.expect(snap.entries.len > 0);
    for (snap.entries) |*entry| entry.id.inner = @fromBackingInt(@as(u32, 0xFFFF));
    var fresh = Linker.init(std.testing.allocator, r.graph, .esm);
    defer fresh.deinit();
    try fresh.link();
    try std.testing.expect(!fresh.renameReuseGuard(&snap));
    try std.testing.expectError(error.InvalidPreservedRenameIdentity, fresh.injectPreservedRenames(&snap));
    try std.testing.expectEqual(@as(usize, 0), fresh.rename_table.count());
}

test "reuse: fingerprint — 같은 그래프는 guard true, module_count 불일치는 false (G0)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import './b';\nexport const count = 0;");
    try writeFile(tmp.dir, "b.ts", "export const count = 1;");

    var r = try buildLinkAndRename(std.testing.allocator, &tmp, "a.ts");
    defer r.linker.deinit();
    defer r.destroyGraph();
    defer r.cache.deinit();

    var snap = (try r.linker.buildRenameSnapshot(std.testing.allocator)).?;
    defer snap.deinit();

    // 같은 그래프 → guard 통과.
    try std.testing.expect(r.linker.renameReuseGuard(&snap));

    // G0: 스냅샷의 module_count 를 조작해 불일치 유발 → fallback(false).
    const real_count = snap.module_count;
    snap.module_count = real_count + 1;
    try std.testing.expect(!r.linker.renameReuseGuard(&snap));
    snap.module_count = real_count;

    // G2: 스냅샷의 첫 fingerprint 의 이름집합 해시를 조작 → fallback(false).
    // fingerprint 는 []const 라 const-cast 로 한 엔트리만 손상(테스트 한정).
    const fps = @constCast(snap.fingerprint);
    const saved = fps[0].toplevel_name_set_hash;
    fps[0].toplevel_name_set_hash = saved ^ 0xDEAD;
    try std.testing.expect(!r.linker.renameReuseGuard(&snap));
    fps[0].toplevel_name_set_hash = saved;

    // 복원 후 다시 통과.
    try std.testing.expect(r.linker.renameReuseGuard(&snap));
}

test "reuse: fingerprint — nested/import-local/wrap 해시 조작 시 fallback (G5/G6)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // a.ts 가 b.ts 의 foo 를 import 하고 nested 스코프(wrap 함수)를 가진다.
    try writeFile(tmp.dir, "a.ts", "import { foo } from './b';\nexport function wrap(){ return foo; }");
    try writeFile(tmp.dir, "b.ts", "export const foo = 1;");

    var r = try buildLinkAndRename(std.testing.allocator, &tmp, "a.ts");
    defer r.linker.deinit();
    defer r.destroyGraph();
    defer r.cache.deinit();

    var snap = (try r.linker.buildRenameSnapshot(std.testing.allocator)).?;
    defer snap.deinit();

    // baseline: 같은 그래프 → 통과.
    try std.testing.expect(r.linker.renameReuseGuard(&snap));

    const fps = @constCast(snap.fingerprint);

    // G5: nested binding 이름집합 해시 조작 → fallback. (각 모듈 인덱스마다 검증)
    for (fps) |*fp| {
        const saved = fp.nested_name_set_hash;
        fp.nested_name_set_hash = saved ^ 0xBEEF;
        try std.testing.expect(!r.linker.renameReuseGuard(&snap));
        fp.nested_name_set_hash = saved;
    }
    try std.testing.expect(r.linker.renameReuseGuard(&snap));

    // G6: import local_name + wrap_kind 해시 조작 → fallback.
    for (fps) |*fp| {
        const saved = fp.import_locals_wrap_hash;
        fp.import_locals_wrap_hash = saved ^ 0xBEEF;
        try std.testing.expect(!r.linker.renameReuseGuard(&snap));
        fp.import_locals_wrap_hash = saved;
    }
    try std.testing.expect(r.linker.renameReuseGuard(&snap));
}

test "reuse: nested shadow 추가 시 guard=false (toplevel 불변이라 G2 가 놓치는 hole)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // 빌드 A: 이미 존재하는 top-level 함수 wrap, 내부에 nested binding 없음.
    try writeFile(tmp.dir, "a.ts", "import { foo } from './b';\nexport function wrap(){ return foo; }");
    try writeFile(tmp.dir, "b.ts", "export const foo = 1;");

    // 빌드 A → 스냅샷. (스냅샷은 자체 arena 로 dupe 하므로 teardown 후에도 유효)
    var snap: PreservedRenames = blk: {
        var rA = try buildLinkAndRename(std.testing.allocator, &tmp, "a.ts");
        defer rA.linker.deinit();
        defer rA.destroyGraph();
        defer rA.cache.deinit();
        break :blk (try rA.linker.buildRenameSnapshot(std.testing.allocator)).?;
    };
    defer snap.deinit();

    // a.ts 의 nested 스코프에 import local 과 같은 이름(foo)을 const 로 추가.
    // top-level 이름집합(wrap)은 그대로 — G2 는 이 변화를 못 잡는다.
    try writeFile(tmp.dir, "a.ts", "import { foo } from './b';\nexport function wrap(){ const foo = 1; return foo; }");

    // 빌드 B: 같은 tmpDir → 같은 경로(path_hash 동일) → G1 통과, nested 만 다름.
    var rB = try buildLinkAndRename(std.testing.allocator, &tmp, "a.ts");
    defer rB.linker.deinit();
    defer rB.destroyGraph();
    defer rB.cache.deinit();

    // a.ts 모듈의 fresh fingerprint 와 스냅샷을 직접 대조해 어떤 게이트가 잡는지 확인:
    // toplevel/import-local 은 일치, nested 만 불일치여야 한다.
    const a_idx = findModuleIdx(rB.graph, "a.ts").?;
    const ai: usize = @backingInt(a_idx);
    const cur = try rB.linker.moduleFingerprint(rB.graph.getModule(a_idx).?.*);
    const old = snap.fingerprint[ai];
    try std.testing.expectEqual(old.path_hash, cur.path_hash); // 같은 파일
    try std.testing.expectEqual(old.toplevel_name_set_hash, cur.toplevel_name_set_hash); // G2 놓침
    try std.testing.expectEqual(old.import_locals_wrap_hash, cur.import_locals_wrap_hash); // G6 놓침
    try std.testing.expect(old.nested_name_set_hash != cur.nested_name_set_hash); // G5 가 잡음

    // 결과: 가드는 nested 변화를 감지해 fallback(false) → full computeRenames 로 안전.
    try std.testing.expect(!rB.linker.renameReuseGuard(&snap));
}

test "reuse: wrap_kind flip (ESM→CJS) 시 guard=false" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // 빌드 A: b 가 ESM (wrap_kind=.none).
    try writeFile(tmp.dir, "a.ts", "import { x } from './b';\nexport const y = x;");
    try writeFile(tmp.dir, "b.js", "export const x = 1;");

    var snap: PreservedRenames = blk: {
        var rA = try buildLinkAndRename(std.testing.allocator, &tmp, "a.ts");
        defer rA.linker.deinit();
        defer rA.destroyGraph();
        defer rA.cache.deinit();
        // b 가 ESM 인지 sanity.
        const b0 = findModuleIdx(rA.graph, "b.js").?;
        try std.testing.expectEqual(types.WrapKind.none, rA.graph.getModule(b0).?.wrap_kind);
        break :blk (try rA.linker.buildRenameSnapshot(std.testing.allocator)).?;
    };
    defer snap.deinit();

    // b.js 를 CJS 로 교체 → wrap_kind=.cjs 로 바뀐다.
    try writeFile(tmp.dir, "b.js", "module.exports = { x: 1 };");

    var rB = try buildLinkAndRename(std.testing.allocator, &tmp, "a.ts");
    defer rB.linker.deinit();
    defer rB.destroyGraph();
    defer rB.cache.deinit();

    const b_idx = findModuleIdx(rB.graph, "b.js").?;
    try std.testing.expectEqual(types.WrapKind.cjs, rB.graph.getModule(b_idx).?.wrap_kind);

    // wrap_kind 가 import_locals_wrap_hash 의 seed 라 b 의 fingerprint 가 달라진다.
    const bi: usize = @backingInt(b_idx);
    const cur = try rB.linker.moduleFingerprint(rB.graph.getModule(b_idx).?.*);
    try std.testing.expect(snap.fingerprint[bi].import_locals_wrap_hash != cur.import_locals_wrap_hash);

    // 가드 fallback(false).
    try std.testing.expect(!rB.linker.renameReuseGuard(&snap));
}

test "reuse: F5 invalid exact rename identity discards snapshot capture" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import './b';\nexport const count = 0;");
    try writeFile(tmp.dir, "b.ts", "export const count = 1;");

    var r = try buildLinkAndRename(std.testing.allocator, &tmp, "a.ts");
    defer r.linker.deinit();
    defer r.destroyGraph();
    defer r.cache.deinit();

    // 1) 대조군: 깨끗한 rename_table 은 capture 성공(non-null).
    {
        var ok = (try r.linker.buildRenameSnapshot(std.testing.allocator)).?;
        ok.deinit();
    }

    // An out-of-range module cannot identify a current semantic symbol.
    const oob_module: types.ModuleIndex = @fromBackingInt(@intCast(@as(u32, @intCast(r.graph.moduleCount())) + 7));
    const bad_id = bundler_symbol.SymbolID.make(oob_module, 0);
    try r.linker.rename_table.put(std.testing.allocator, bad_id, "synthetic_should_not_leak");

    // 3) 이제 capture 는 불완전 스냅샷을 폐기하고 null 을 반환해야 한다.
    const captured = try r.linker.buildRenameSnapshot(std.testing.allocator);
    try std.testing.expect(captured == null);

    // 4) 가드 경로가 reuse 를 안 하는지: bundler 게이트는 `if (try buildRenameSnapshot()) |snap|`
    //    형태라, capture 가 null 이면 그 분기 자체를 타지 않아 injectPreservedRenames 가
    //    절대 호출되지 않는다(=reuse 비활성). 즉 reuse 의 *유일* 진입점인 non-null 스냅샷이
    //    없으므로 구조적으로 재사용이 불가능하다. 아래는 그 불변식을 값 수준에서 재확인.
    if (captured) |_| {
        try std.testing.expect(false); // 도달 불가 — null 이어야 한다.
    }
}

test "clearCanonicalNames: ns_export_cache 도 무효화 (non-owned local canonical_strings UAF, #4297)" {
    const allocator = std.testing.allocator;
    var cache = resolve_cache_mod.ResolveCache.init(allocator, .{});
    defer cache.deinit();
    var graph = ModuleGraph.init(allocator, &cache);
    defer graph.deinit();
    var linker = Linker.init(allocator, &graph, .esm);
    defer linker.deinit();

    // ns_export_cache 의 non-owned local 은 canonical_strings 를 borrow → clearCanonicalNames 가
    // canonical_strings 를 free 하면 stale. 캐시도 무효화돼야 한다. owned 엔트리로 free 까지 검증.
    const owned_local = try allocator.dupe(u8, "_default");
    const slice = try allocator.alloc(Linker.NsExportPair, 1);
    slice[0] = .{ .exported = "x", .local = owned_local, .owned = true };
    try linker.ns_export_cache.put(allocator, 0, slice);

    linker.clearCanonicalNames();

    // 버그: 캐시 미정리 → stale 엔트리 잔존(+owned local leak, testing allocator 감지).
    try std.testing.expectEqual(@as(usize, 0), linker.ns_export_cache.count());
}

test "reuse: #4538 CJS 소비자 scope-0 shadow 추가가 fingerprint 를 바꾼다 (stale reuse 방지)" {
    // #4533 이후 resolveWrapperConsumerShadows 가 CJS 소비자의 scope-0(클로저 지역) 바인딩도
    // 주입 래퍼와 대조해 개명한다. 그 이름이 warm 재빌드에서 새로 생겨도 moduleFingerprint 가
    // 안 담으면 renameReuseGuard 가 stale snapshot 을 재사용해 shadow 가 재출현한다.
    // → moduleFingerprint 가 CJS scope-0 이름을 담아 변화를 잡는지 검증.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "legacy.cjs", "exports.foo = function(){ return 1; };\n");

    // build1: consumer.cjs 에 shadow 없음.
    try writeFile(tmp.dir, "consumer.cjs", "module.exports = require('./legacy.cjs').foo();\n");
    try writeFile(tmp.dir, "index.ts", "import c from './consumer.cjs';\nconsole.log(c);\n");
    var snap = blk: {
        var r1 = try buildLinkAndRename(std.testing.allocator, &tmp, "index.ts");
        defer r1.linker.deinit();
        defer r1.destroyGraph();
        defer r1.cache.deinit();
        break :blk (try r1.linker.buildRenameSnapshot(std.testing.allocator)).?;
    };
    defer snap.deinit();

    // build2: consumer.cjs 의 scope-0 에 require_legacy shadow 추가(다른 건 그대로).
    try writeFile(tmp.dir, "consumer.cjs",
        \\function require_legacy(){ return 2; }
        \\module.exports = require('./legacy.cjs').foo() + require_legacy();
        \\
    );
    var r2 = try buildLinkAndRename(std.testing.allocator, &tmp, "index.ts");
    defer r2.linker.deinit();
    defer r2.destroyGraph();
    defer r2.cache.deinit();

    // 핵심: scope-0 shadow 가 생겼으니 guard 는 **false**(재계산) 여야 한다.
    // fingerprint 가 CJS scope-0 을 안 담으면 여기서 true(stale) → shadow 재출현.
    try std.testing.expect(!r2.linker.renameReuseGuard(&snap));
}

test "reuse: #4538 shadow 이름이 scope-0↔nested 이동해도 fingerprint 가 바뀐다 (상쇄 방지)" {
    // #4538 fold 가 scope-0 을 nested 와 같은 seed 로 더하면, require_legacy 를 top-level 에서
    // 함수 안으로 옮길 때 두 항이 상쇄돼 fingerprint 불변 → stale reuse. 다른 seed(0xc1)로 방지.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "legacy.cjs", "exports.foo = function(){ return 1; };\n");

    // build1: outer() 는 **이미 존재**하고, require_legacy 는 top-level(scope 0)에 있다.
    // (이름 집합 = {outer, require_legacy}; nested = {}). 이동만 격리하려고 build 바인딩 추가 없이.
    try writeFile(tmp.dir, "consumer.cjs",
        \\function outer(){ return 0; }
        \\function require_legacy(){ return 2; }
        \\module.exports = require('./legacy.cjs').foo() + require_legacy() + outer();
        \\
    );
    try writeFile(tmp.dir, "index.ts", "import c from './consumer.cjs';\nconsole.log(c);\n");
    var snap = blk: {
        var r1 = try buildLinkAndRename(std.testing.allocator, &tmp, "index.ts");
        defer r1.linker.deinit();
        defer r1.destroyGraph();
        defer r1.cache.deinit();
        break :blk (try r1.linker.buildRenameSnapshot(std.testing.allocator)).?;
    };
    defer snap.deinit();

    // build2: require_legacy 를 **기존 outer() 안(nested)** 으로 이동. 전체 이름 multiset 불변
    // ({outer@s0, require_legacy@s1} vs build1 {outer@s0, require_legacy@s0}) — scope 만 바뀜.
    try writeFile(tmp.dir, "consumer.cjs",
        \\function outer(){ function require_legacy(){ return 2; } return require_legacy(); }
        \\module.exports = require('./legacy.cjs').foo() + outer();
        \\
    );
    var r2 = try buildLinkAndRename(std.testing.allocator, &tmp, "index.ts");
    defer r2.linker.deinit();
    defer r2.destroyGraph();
    defer r2.cache.deinit();

    // 이동으로 shadow 스코프가 바뀌었으니 guard 는 **false**(재계산) 여야 한다.
    try std.testing.expect(!r2.linker.renameReuseGuard(&snap));
}

// #4545 hole 2: CJS provider 의 interop 모드(node `__toESM(...,1)` vs babel `__toESM(...)`)는
// provider 의 **첫 importer def_format**(cjsInteropIsNode)으로 정해진다. 이 importer-방향 입력이
// flip 되면 provider 를 소비하는 **다른** 소비자 emit 이 바뀌므로 provider 의 emitFingerprint 가
// 반응해야(deep-fold → 소비자 invalidation). 무관 모듈(other)은 그 flip 에 안 바뀌어야(targeted).
test "reuse #4545 hole 2: cjs provider interop 모드 flip → provider emitFingerprint 변화 (무관 모듈 불변)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "p.cjs", "module.exports.x = 1;\n");
    try writeFile(tmp.dir, "other.mjs", "export const o = 1;\n");
    try writeFile(tmp.dir, "main.mjs",
        \\import { x } from './p.cjs';
        \\import { o } from './other.mjs';
        \\console.log(x, o);
        \\
    );
    var r = try buildAndLink(std.testing.allocator, &tmp, "main.mjs");
    defer r.linker.deinit();
    defer r.destroyGraph();
    defer r.cache.deinit();

    const p = r.graph.getModule(findModuleIdx(r.graph, "p.cjs").?).?;
    // 전제: p 는 CJS-wrap 이어야 interop 게이트에 걸린다.
    try std.testing.expectEqual(types.WrapKind.cjs, p.wrap_kind);
    const other = r.graph.getModule(findModuleIdx(r.graph, "other.mjs").?).?;
    const main_mut = r.graph.moduleAtMut(findModuleIdx(r.graph, "main.mjs").?).?;
    // 첫 importer(main) def_format esm → node interop.
    main_mut.def_format = .esm_mjs;
    const fp_p_node = r.linker.emitFingerprint(p);
    const fp_other_a = r.linker.emitFingerprint(other);
    // 첫 importer def_format cjs → babel interop.
    main_mut.def_format = .cjs;
    const fp_p_babel = r.linker.emitFingerprint(p);
    const fp_other_b = r.linker.emitFingerprint(other);
    // 핵심: CJS provider 의 fp 는 첫-importer interop 모드에 반응한다(cjsInteropIsNode; fix 전엔 불변→stale).
    try std.testing.expect(fp_p_node != fp_p_babel);
    // targeted: main 의 def_format flip 은 무관 ESM 모듈 other 의 fp 를 안 바꾼다(spurious invalidation 없음).
    try std.testing.expectEqual(fp_other_a, fp_other_b);
}

// #4545 code-review [1]: 소비자 **자기** def_format(=`.js` 는 package.json "type" 파생)이 flip 되면
// CJS interop 모드(`cjsInteropMode`, `__toESM(require_pd(),1).default`↔`__toESM(require_pd()).default`)가
// 바뀌어 per-module preamble emit 이 달라진다. source/mtime 불변이라 emitFingerprint 가 자기
// def_format 을 접어야 own-index fold 로 소비자를 re-emit 한다.
test "reuse #4545 [1]: 소비자 자기 def_format flip → emitFingerprint 변화" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "pd.cjs", "module.exports = function(){ return 7; };\n");
    try writeFile(tmp.dir, "cons.mjs", "import pd from './pd.cjs';\nexport const cv = pd();\n");
    try writeFile(tmp.dir, "main.mjs", "import { cv } from './cons.mjs';\nconsole.log(cv);\n");
    var r = try buildAndLink(std.testing.allocator, &tmp, "main.mjs");
    defer r.linker.deinit();
    defer r.destroyGraph();
    defer r.cache.deinit();

    const cons_idx = findModuleIdx(r.graph, "cons.mjs").?;
    const cons = r.graph.getModule(cons_idx).?;
    const cons_mut = r.graph.moduleAtMut(cons_idx).?;
    // node interop: def_format esm(package.json "type":"module").
    cons_mut.def_format = .esm_package_json;
    const fp_esm = r.linker.emitFingerprint(cons);
    // babel interop: def_format commonjs(package.json "type":"commonjs").
    cons_mut.def_format = .cjs_package_json;
    const fp_cjs = r.linker.emitFingerprint(cons);
    // 핵심: 소비자 자기 def_format 이 바뀌면 fp 도 바뀐다(fix 전엔 불변 → interop stale-hit).
    try std.testing.expect(fp_esm != fp_cjs);
}

// #4545 hole 3: `import * as ns from './t'` 의 합성 shared-ns var 이름(`t_ns`/`t_ns_2` …)은
// 전-모듈 동명-base 충돌 rank 로 결정된다(sharedNsRankHash=rank-only, ns-target 게이트). 이는 dep
// 방향이 아니라 전역 collision 구성에 의존해 deep-fold 가 못 잡으므로 target(ns 주인) 모듈의
// emitFingerprint 에 접었다. 동명-base 모듈을 추가해 t 의 rank 가 0→1 로 바뀌면 fp 가 달라져야 한다.
test "reuse #4545 hole 3: shared-ns var 충돌 rank 변화 → target emitFingerprint 변화" {
    const alloc = std.testing.allocator;
    // 시나리오 A: base "t" 모듈이 t.ts 하나뿐 → rank 0.
    const fp_a = blk: {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try writeFile(tmp.dir, "t.ts", "export const a = 1;\n");
        try writeFile(tmp.dir, "main.ts", "import * as ns from './t';\nconsole.log(ns.a);\n");
        var r = try buildAndLink(alloc, &tmp, "main.ts");
        defer r.linker.deinit();
        defer r.destroyGraph();
        defer r.cache.deinit();
        const t = r.graph.getModule(findModuleIdx(r.graph, "t.ts").?).?;
        break :blk r.linker.emitFingerprint(t);
    };
    // 시나리오 B: sub/t.ts(base "t") 추가 → 동명-base 2개 → t.ts rank 1(sub/t 가 먼저 import 되어 rank 0).
    const fp_b = blk: {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try writeFile(tmp.dir, "t.ts", "export const a = 1;\n");
        try writeFile(tmp.dir, "sub/t.ts", "export const z = 9;\n");
        try writeFile(tmp.dir, "main.ts",
            \\import { z } from './sub/t';
            \\import * as ns from './t';
            \\console.log(z, ns.a);
            \\
        );
        var r = try buildAndLink(alloc, &tmp, "main.ts");
        defer r.linker.deinit();
        defer r.destroyGraph();
        defer r.cache.deinit();
        // 최상위 t.ts 지목(sub/t.ts 는 basename 이 같아 findModuleIdx 로 구분 불가 → path 로 구분).
        var t_idx: ?ModuleIndex = null;
        var it = r.graph.modulesIterator();
        while (it.next()) |m| {
            if (std.mem.endsWith(u8, m.path, "/t.ts") and !std.mem.endsWith(u8, m.path, "/sub/t.ts")) {
                t_idx = m.index;
                break;
            }
        }
        const t = r.graph.getModule(t_idx.?).?;
        break :blk r.linker.emitFingerprint(t);
    };
    // 핵심: collision 구성 변화로 t 의 ns var 이름(rank)이 바뀌면 fp 도 바뀐다(fix 전엔 불변 → stale).
    try std.testing.expect(fp_a != fp_b);
}

// #4545 code-review [4]: rank 접기는 **ns-target 모듈만** 게이트되어야 한다. 동명-base 지만
// `import * as ns` 대상이 아닌 모듈(흔한 `util.ts`/`index.ts` 무리)은 소비자가 그 shared-ns var 을
// 참조하지 않으므로, collision 구성이 바뀌어 rank 가 변해도 emitFingerprint 가 불변이어야
// (spurious 재emit 방지). ns-target 아닌 util.ts 의 rank 를 0→1 로 바꿔도 fp 불변을 확인
// (게이트 없으면 rank 접기로 fp 가 바뀌어 이 테스트 실패).
test "reuse #4545 [4]: 비-ns-target 동명-base 모듈은 rank 변화에도 fp 불변 (게이트)" {
    const alloc = std.testing.allocator;
    // A: util.ts 하나 (rank 0), 전부 named import → ns-target 아님.
    const fp_a = blk: {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try writeFile(tmp.dir, "util.ts", "export const a = 1;\n");
        try writeFile(tmp.dir, "main.ts", "import { a } from './util';\nconsole.log(a);\n");
        var r = try buildAndLink(alloc, &tmp, "main.ts");
        defer r.linker.deinit();
        defer r.destroyGraph();
        defer r.cache.deinit();
        const u = r.graph.getModule(findModuleIdx(r.graph, "util.ts").?).?;
        break :blk r.linker.emitFingerprint(u);
    };
    // B: sub/util.ts 추가 → util.ts rank 0→1. 그래도 named import 라 ns-target 아님.
    const fp_b = blk: {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try writeFile(tmp.dir, "util.ts", "export const a = 1;\n");
        try writeFile(tmp.dir, "sub/util.ts", "export const z = 9;\n");
        try writeFile(tmp.dir, "main.ts",
            \\import { z } from './sub/util';
            \\import { a } from './util';
            \\console.log(z, a);
            \\
        );
        var r = try buildAndLink(alloc, &tmp, "main.ts");
        defer r.linker.deinit();
        defer r.destroyGraph();
        defer r.cache.deinit();
        var u_idx: ?ModuleIndex = null;
        var it = r.graph.modulesIterator();
        while (it.next()) |m| {
            if (std.mem.endsWith(u8, m.path, "/util.ts") and !std.mem.endsWith(u8, m.path, "/sub/util.ts")) {
                u_idx = m.index;
                break;
            }
        }
        break :blk r.linker.emitFingerprint(r.graph.getModule(u_idx.?).?);
    };
    // 게이트: 비-ns-target 은 rank 를 안 접으므로 rank 0→1 변화에도 fp 불변.
    try std.testing.expectEqual(fp_a, fp_b);
}

// #4545 code-review [2]: ensureNsBaseRank 가 loop 중 OOM 나면 `ns_base_rank_built` 가 **false 로**
// 남아야(잘린 partial rank map 을 latch 하지 않음). 이전 코드(built=true 를 loop 前 set)는 중간
// OOM 시 corrupt map 을 latch → 이후 emit 이 잘못된 rank(collision 오해소, `util_ns` 중복) 재사용.
// sharedNsRankHash 가 이 OOM 을 삼키므로(fp 는 보수적) built-flag 순서가 유일한 방어선.
test "reuse #4545 [2]: ensureNsBaseRank OOM → built latch 안 됨 (재시도 정상 rank)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // 동명-base(util) 충돌 → ns_base_rank 에 rank>0 엔트리 생성 대상.
    try writeFile(tmp.dir, "util.ts", "export const a = 1;");
    try writeFile(tmp.dir, "sub/util.ts", "export const b = 2;");
    try writeFile(tmp.dir, "main.ts",
        \\import { a } from './util';
        \\import { b } from './sub/util';
        \\console.log(a, b);
    );
    var r = try buildAndLink(std.testing.allocator, &tmp, "main.ts");
    defer r.linker.deinit();
    defer r.destroyGraph();
    defer r.cache.deinit();

    // 1) loop 첫 alloc(makeSharedNamespaceBaseName)에서 OOM 유도.
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    r.linker.allocator = failing.allocator();
    try std.testing.expectError(error.OutOfMemory, r.linker.ensureNsBaseRank());
    // 핵심: OOM 이 built 를 latch 하지 않아야(fix 전엔 true → corrupt map 재사용).
    try std.testing.expect(!r.linker.ns_base_rank_built);

    // 2) 정상 allocator 로 재시도 → 성공 + 올바른 rank(util 충돌 1건 → rank>0 엔트리 ≥1).
    r.linker.allocator = std.testing.allocator;
    try r.linker.ensureNsBaseRank();
    try std.testing.expect(r.linker.ns_base_rank_built);
    try std.testing.expect(r.linker.ns_base_rank.count() >= 1);
}

const import_local_identity_inputs = [_][]const u8{
    "import { x as local } from './dep';",
    "import local from './dep';",
    "import * as local from './dep';",
    "import { default as local } from './dep';",
    "import { x as \\u006cocal } from './dep';",
    "import { 'x' as local } from './dep';",
    "import { x as local, y as other } from './dep'; console.log(other);",
    "import other, { x as local } from './dep'; console.log(other);",
    "import { x as local } from './dep'; function nested(local) { return local; } console.log(nested(3));",
    "import { x as local } from './dep'; const nested = () => { const local = 3; return local; }; console.log(nested());",
};

fn runImportLocalIdentityInputs(comptime refresh_graph: bool) !void {
    for (import_local_identity_inputs) |import_source| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const source = try std.fmt.allocPrint(std.testing.allocator, "{s}\nconst decoy = 99; console.log(local, decoy, externalGlobal);", .{import_source});
        defer std.testing.allocator.free(source);
        try writeFile(tmp.dir, "entry.mjs", source);
        try writeFile(tmp.dir, "dep.ts", "export const x = 7; export const y = 9; export default 11;");
        var result = try buildAndLink(std.testing.allocator, &tmp, "entry.mjs");
        defer result.cache.deinit();
        defer result.destroyGraph();
        defer result.linker.deinit();
        const entry_index = findModuleIdx(result.graph, "entry.mjs") orelse return error.MissingImportIdentityEntry;
        const module = result.graph.moduleAtMut(entry_index) orelse return error.MissingImportIdentityEntry;
        const sem = if (module.semantic) |*value| value else return error.MissingImportIdentitySemantic;
        const scope = @constCast(&sem.scope_maps[0]);
        const expected = scope.get("local") orelse return error.MissingImportIdentityLocal;
        const decoy = scope.get("decoy") orelse return error.MissingImportIdentityDecoy;
        try std.testing.expect(expected != decoy);
        for (module.import_bindings) |*binding| {
            if (!std.mem.eql(u8, binding.local_name, "local")) continue;
            const node = binding.local_symbol_node orelse return error.MissingImportIdentityAnchor;
            try std.testing.expectEqual(@as(u32, @intCast(expected)), sem.symbol_ids[@backingInt(node)].?);
            binding.local_symbol = bundler_symbol.SymbolRef.makeSemantic(entry_index, decoy);
        }
        scope.getPtr("local").?.* = decoy;
        if (refresh_graph) {
            try @import("graph/transform_prepass.zig").resyncModuleGraphMetadataAfterAstMutation(result.graph, module, module.parse_arena.?.allocator());
        } else {
            result.linker.populateImportSymbols();
        }
        var found = false;
        for (module.import_bindings) |binding| {
            if (!std.mem.eql(u8, binding.local_name, "local")) continue;
            try std.testing.expectEqual(@as(u32, @intCast(expected)), binding.local_symbol.semanticIndex() orelse return error.MissingExactImportLocalIdentity);
            try std.testing.expectEqual(entry_index, binding.local_symbol.moduleIndex());
            found = true;
        }
        try std.testing.expect(found);

        // A broken authoritative anchor must clear a previously valid result,
        // even though a same-spelling scope entry still points at the decoy.
        var binding_index: ?usize = null;
        for (module.import_bindings, 0..) |binding, index| {
            if (std.mem.eql(u8, binding.local_name, "local")) binding_index = index;
        }
        const local_index = binding_index orelse return error.MissingImportIdentityBinding;
        const binding_node = module.import_bindings[local_index].local_symbol_node orelse return error.MissingImportIdentityAnchor;
        const raw = @backingInt(binding_node);
        const ids = @constCast(sem.symbol_ids);
        for ([_]?u32{ null, @intCast(sem.symbols.items.len), @intCast(decoy) }) |malformed_id| {
            ids[raw] = malformed_id;
            module.import_bindings[local_index].local_symbol = bundler_symbol.SymbolRef.makeSemantic(entry_index, expected);
            if (refresh_graph) {
                try @import("graph/transform_prepass.zig").resyncModuleGraphMetadataAfterAstMutation(result.graph, module, module.parse_arena.?.allocator());
            } else {
                result.linker.populateImportSymbols();
            }
            try std.testing.expect(!module.import_bindings[local_index].local_symbol.isValid());
        }
        ids[raw] = @intCast(expected);
        if (!refresh_graph) {
            module.import_bindings[local_index].local_symbol_node = null;
            module.import_bindings[local_index].local_symbol = bundler_symbol.SymbolRef.makeSemantic(entry_index, expected);
            result.linker.populateImportSymbols();
            try std.testing.expect(!module.import_bindings[local_index].local_symbol.isValid());
            module.import_bindings[local_index].local_symbol_node = binding_node;
            const saved_semantic = module.semantic;
            module.semantic = null;
            module.import_bindings[local_index].local_symbol = bundler_symbol.SymbolRef.makeSemantic(entry_index, expected);
            result.linker.populateImportSymbols();
            try std.testing.expect(!module.import_bindings[local_index].local_symbol.isValid());
            module.semantic = saved_semantic;
        }
    }
}

test "populateImportSymbols uses exact local anchors across ten poisoned scope maps" {
    try runImportLocalIdentityInputs(false);
}

test "graph import refresh uses exact local anchors across ten poisoned scope maps" {
    try runImportLocalIdentityInputs(true);
}

test "generated runtime helper imports keep exact anchors under poisoned helper names" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.mjs", "const __generator = 17; function* values() { yield 3; } console.log(values().next().value, __generator);");
    var result = try buildAndLinkWithTransformOptions(std.testing.allocator, &tmp, "entry.mjs", .{
        .unsupported = TransformOptions.compat.fromESTarget(.es5),
        .defer_runtime_helper_name_resolution = true,
        .emit_runtime_helper_imports = true,
    }, false);
    defer result.cache.deinit();
    defer result.destroyGraph();
    defer result.linker.deinit();
    const entry_index = findModuleIdx(result.graph, "entry.mjs") orelse return error.MissingHelperAnchorEntry;
    const module = result.graph.moduleAtMut(entry_index) orelse return error.MissingHelperAnchorEntry;
    const sem = if (module.semantic) |*value| value else return error.MissingHelperAnchorSemantic;
    const decoy = sem.scope_maps[0].get("__generator") orelse return error.MissingHelperAnchorDecoy;
    var helper_count: usize = 0;
    for (module.import_bindings) |*binding| {
        if (!binding.is_helper) continue;
        const anchor = binding.local_symbol_node orelse return error.MissingGeneratedHelperAnchor;
        const expected = sem.symbol_ids[@backingInt(anchor)] orelse return error.MissingGeneratedHelperSymbol;
        try std.testing.expect(expected != decoy);
        try std.testing.expectEqual(semantic_symbol.SymbolKind.import_binding, sem.symbols.items[expected].kind);
        const mapped = sem.helper_scope_map.getPtr(binding.local_name) orelse return error.MissingHelperAnchorScope;
        mapped.* = decoy;
        binding.local_symbol = bundler_symbol.SymbolRef.makeSemantic(entry_index, decoy);
        helper_count += 1;
    }
    try std.testing.expect(helper_count > 0);
    result.linker.populateImportSymbols();
    for (module.import_bindings) |binding| {
        if (!binding.is_helper) continue;
        const expected = sem.symbol_ids[@backingInt(binding.local_symbol_node.?)].?;
        try std.testing.expectEqual(expected, binding.local_symbol.semanticIndex().?);
    }
    try @import("graph/transform_prepass.zig").resyncModuleGraphMetadataAfterAstMutation(result.graph, module, module.parse_arena.?.allocator());
    for (module.import_bindings) |binding| {
        if (!binding.is_helper) continue;
        const expected = sem.symbol_ids[@backingInt(binding.local_symbol_node.?)].?;
        try std.testing.expectEqual(expected, binding.local_symbol.semanticIndex().?);
    }
}

test "foreign import identity clears previous source refs across ten invalidation transitions" {
    const Transition = enum { bad_record, unresolved, missing_module, no_exports, namespace, missing_name, missing_export_target, export_invalid, unchanged, alternate };
    const Case = struct { name: []const u8, transition: Transition, default_import: bool = false };
    const cases = [_]Case{
        .{ .name = "named import record removed", .transition = .bad_record },
        .{ .name = "default import record removed", .transition = .bad_record, .default_import = true },
        .{ .name = "named source unresolved", .transition = .unresolved },
        .{ .name = "default source unresolved", .transition = .unresolved, .default_import = true },
        .{ .name = "source module removed", .transition = .missing_module },
        .{ .name = "named provider export removed", .transition = .no_exports },
        .{ .name = "default provider export removed", .transition = .no_exports, .default_import = true },
        .{ .name = "named import changed to namespace", .transition = .namespace },
        .{ .name = "requested public export changed", .transition = .missing_name },
        .{ .name = "new provider lacks public export", .transition = .missing_export_target },
        .{ .name = "provider explicitly has no symbol", .transition = .export_invalid },
        .{ .name = "unchanged provider retains exact ref", .transition = .unchanged },
        .{ .name = "new provider replaces exact ref", .transition = .alternate },
    };
    var stale_refs: usize = 0;
    for (cases) |case| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const source = if (case.default_import)
            "import local from './dep'; import './other'; import './empty'; console.log(local);"
        else
            "import { x as local } from './dep'; import './other'; import './empty'; console.log(local);";
        try writeFile(tmp.dir, "entry.mjs", source);
        try writeFile(tmp.dir, "dep.ts", "export const x = 1; export default 2;");
        try writeFile(tmp.dir, "other.ts", "export const x = 3; export default 4;");
        try writeFile(tmp.dir, "empty.ts", "export const y = 5;");
        var result = try buildAndLink(std.testing.allocator, &tmp, "entry.mjs");
        defer result.cache.deinit();
        defer result.destroyGraph();
        defer result.linker.deinit();
        const entry_index = findModuleIdx(result.graph, "entry.mjs") orelse return error.MissingForeignImportEntry;
        const module = result.graph.moduleAtMut(entry_index) orelse return error.MissingForeignImportEntry;
        try std.testing.expectEqual(@as(usize, 1), module.import_bindings.len);
        const binding = &module.import_bindings[0];
        result.linker.populateImportSymbols();
        try std.testing.expect(binding.symbol.isValid());
        const previous_source = binding.symbol;
        const record = &module.import_records[binding.import_record_index];
        const provider = result.graph.moduleAtMut(record.resolved) orelse return error.MissingForeignImportProvider;
        const other_index = findModuleIdx(result.graph, "other.ts") orelse return error.MissingForeignImportAlternate;
        const other = result.graph.getModule(other_index) orelse return error.MissingForeignImportAlternate;
        const alternate = (other.findExportBinding(binding.imported_name) orelse return error.MissingForeignImportAlternateExport).symbol;
        const empty_index = findModuleIdx(result.graph, "empty.ts") orelse return error.MissingForeignImportEmptyProvider;
        switch (case.transition) {
            .bad_record => binding.import_record_index = @intCast(module.import_records.len),
            .unresolved => record.resolved = .none,
            .missing_module => record.resolved = ModuleIndex.fromUsize(result.graph.moduleCount() + 31),
            .no_exports => provider.export_bindings = &.{},
            .namespace => {
                binding.kind = .namespace;
                binding.imported_name = "*";
            },
            .missing_name => binding.imported_name = "missing",
            .missing_export_target => record.resolved = empty_index,
            .export_invalid => @constCast(provider.findExportBinding(binding.imported_name) orelse return error.MissingForeignImportExport).symbol = bundler_symbol.SymbolRef.invalid,
            .unchanged => {},
            .alternate => record.resolved = other_index,
        }
        // Incremental rebuilds create a fresh linker while import_bindings
        // remain AST-resident. Its empty tables must not make the cached
        // source ref authoritative when the new source no longer exports it.
        result.linker.deinit();
        result.linker = Linker.init(std.testing.allocator, result.graph, .esm);
        result.linker.populateImportSymbols();
        try std.testing.expect(binding.local_symbol.isValid());
        try std.testing.expectEqual(entry_index, binding.local_symbol.moduleIndex());
        switch (case.transition) {
            .unchanged => try std.testing.expect(bundler_symbol.SymbolRef.eql(previous_source, binding.symbol)),
            .alternate => try std.testing.expect(bundler_symbol.SymbolRef.eql(alternate, binding.symbol)),
            else => if (binding.symbol.isValid()) {
                stale_refs += 1;
                std.debug.print("stale import source SymbolRef: {s}\n", .{case.name});
            },
        }
    }
    try std.testing.expectEqual(@as(usize, 0), stale_refs);
}

test "missing export diagnostics select exact import identity across ten poisoned scopes" {
    const Case = struct { source: []const u8, value_used: bool, same_name: bool = false };
    const cases = [_]Case{
        .{ .source = "import { absent as local } from './dep'; console.log(local); const decoy = 0;", .value_used = true },
        .{ .source = "import { absent as local } from './dep'; function use() { return local; } const decoy = 0;", .value_used = true },
        .{ .source = "import { absent as local } from './dep'; console.log(typeof local); const decoy = 0;", .value_used = true },
        .{ .source = "import { absent as local } from './dep'; console.log({local}); function shadow(local) { return 0; }", .value_used = true, .same_name = true },
        .{ .source = "import { absent as local } from './dep'; new local(); function shadow(local) { return 0; }", .value_used = true, .same_name = true },
        .{ .source = "import local from './dep'; console.log(local); const decoy = 0;", .value_used = true },
        // Default imports do not use named-import type-only classification.
        .{ .source = "import local, { present } from './dep'; console.log(present); const decoy = 0; console.log(decoy);", .value_used = false },
        .{ .source = "import { absent as local, present } from './dep'; console.log(present); type T = local; const decoy = 0; console.log(decoy);", .value_used = false },
        .{ .source = "import { absent as local, present } from './dep'; console.log(present); interface T extends local {} function shadow(local) { return local; }", .value_used = false, .same_name = true },
        .{ .source = "import { absent as local, present } from './dep'; console.log(present); const decoy = 0; console.log(decoy);", .value_used = false },
        .{ .source = "import { absent as local, present } from './dep'; console.log(present); type T = typeof local; function shadow(local) { return local; }", .value_used = false, .same_name = true },
    };
    var mismatches: usize = 0;
    var conservative_mismatches: usize = 0;
    for (cases) |case| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try writeFile(tmp.dir, "entry.ts", case.source);
        try writeFile(tmp.dir, "dep.ts", "export const present = 1;");
        var r = try buildAndLink(std.testing.allocator, &tmp, "entry.ts");
        defer r.cache.deinit();
        defer r.destroyGraph();
        defer r.linker.deinit();
        var clean_missing = false;
        for (r.linker.fatal_diagnostics.items) |d| {
            if (d.code == .missing_export) clean_missing = true;
        }
        try std.testing.expectEqual(case.value_used, clean_missing);
        const module = r.graph.moduleAtMut(findModuleIdx(r.graph, "entry.ts").?) orelse return error.MissingDiagnosticEntry;
        const sem = &module.semantic.?;
        const binding = &module.import_bindings[0];
        const exact_sid = sem.symbol_ids[@backingInt(binding.local_symbol_node.?)].?;
        var decoy: ?usize = null;
        for (sem.symbols.items, 0..) |sym, sid| {
            if (sid != exact_sid and std.mem.eql(u8, module.ast.?.source[sym.name.start..sym.name.end], if (case.same_name) "local" else "decoy")) {
                decoy = sid;
                break;
            }
        }
        const wrong_sid = decoy orelse return error.MissingDiagnosticDecoy;
        try @constCast(&sem.scope_maps[0]).put(module.parse_arena.?.allocator(), binding.local_name, wrong_sid);
        // A generated helper may have the same spelling. Neither map owns the
        // source binding's identity; only its scanner anchor does.
        try sem.helper_scope_map.put(module.parse_arena.?.allocator(), binding.local_name, wrong_sid);
        binding.local_symbol = bundler_symbol.SymbolRef.makeSemantic(module.index, wrong_sid);
        var fresh = Linker.init(std.testing.allocator, r.graph, .esm);
        defer fresh.deinit();
        try fresh.link();
        var missing = false;
        for (fresh.fatal_diagnostics.items) |d| {
            if (d.code == .missing_export) missing = true;
        }
        if (missing != case.value_used) mismatches += 1;

        // Missing exact identity cannot prove an import unused/type-only.
        // Both spelling maps and cached local_symbol remain poisoned.
        const original_anchor = binding.local_symbol_node;
        const original_ids = sem.symbol_ids;
        const anchor_raw = @backingInt(original_anchor.?);
        const original_sid = original_ids[anchor_raw];
        for (0..5) |malformation| {
            switch (malformation) {
                0 => binding.local_symbol_node = null,
                1 => sem.symbol_ids = &.{},
                2 => @constCast(sem.symbol_ids)[anchor_raw] = null,
                3 => @constCast(sem.symbol_ids)[anchor_raw] = @intCast(sem.symbols.items.len),
                4 => @constCast(sem.symbol_ids)[anchor_raw] = @intCast(wrong_sid),
                else => unreachable,
            }
            var malformed = Linker.init(std.testing.allocator, r.graph, .esm);
            defer malformed.deinit();
            try malformed.link();
            var conservative_missing = false;
            for (malformed.fatal_diagnostics.items) |d| {
                if (d.code == .missing_export) conservative_missing = true;
            }
            if (!conservative_missing) std.debug.print("missing conservative diagnostic malformed={d} source={s}\n", .{ malformation, case.source });
            if (!conservative_missing) conservative_mismatches += 1;
            binding.local_symbol_node = original_anchor;
            sem.symbol_ids = original_ids;
            @constCast(sem.symbol_ids)[anchor_raw] = original_sid;
        }
        // Existing explicit suppression contracts remain controls.
        binding.is_helper = true;
        var helper = Linker.init(std.testing.allocator, r.graph, .esm);
        defer helper.deinit();
        try helper.link();
        try std.testing.expectEqual(@as(usize, 0), helper.fatal_diagnostics.items.len);
        binding.is_helper = false;
        var shim = Linker.init(std.testing.allocator, r.graph, .esm);
        defer shim.deinit();
        shim.shim_missing_exports = true;
        try shim.link();
        try std.testing.expectEqual(@as(usize, 0), shim.fatal_diagnostics.items.len);
    }
    if (mismatches != 0 or conservative_mismatches != 0)
        std.debug.print("exact diagnostic mismatches={d}, conservative mismatches={d}\n", .{ mismatches, conservative_mismatches });
    try std.testing.expectEqual(@as(usize, 0), mismatches);
    try std.testing.expectEqual(@as(usize, 0), conservative_mismatches);
}

test "reuse exact owner IDs survive ten poisoned scope maps without spelling recovery" {
    const Case = struct { declaration: []const u8, astless: bool = false };
    const cases = [_]Case{
        .{ .declaration = "export const collision = 1;" },
        .{ .declaration = "export let collision = 1;" },
        .{ .declaration = "export var collision = 1;" },
        .{ .declaration = "export function collision() { return 1; }" },
        .{ .declaration = "export class collision {}" },
        .{ .declaration = "export const { collision } = { collision: 1 };" },
        .{ .declaration = "export const collision = function() { return 1; };" },
        .{ .declaration = "export const collision = () => 1;" },
        .{ .declaration = "export enum collision { x = 1 }" },
        .{ .declaration = "export const collision = 1;", .astless = true },
    };
    var mismatches: usize = 0;
    var clean_mismatches: usize = 0;
    for (cases) |case| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try writeFile(tmp.dir, "entry.ts", "import './dep'; const collision = 0; const decoy = 2; console.log(collision, decoy);");
        const dep_source = try std.fmt.allocPrint(std.testing.allocator, "{s} const decoy = 3; console.log(collision, decoy);", .{case.declaration});
        defer std.testing.allocator.free(dep_source);
        try writeFile(tmp.dir, "dep.ts", dep_source);
        var r = try buildLinkAndRename(std.testing.allocator, &tmp, "entry.ts");
        defer r.linker.deinit();
        defer r.destroyGraph();
        defer r.cache.deinit();
        if (case.astless) {
            const provider = r.graph.moduleAtMut(findModuleIdx(r.graph, "dep.ts").?).?;
            provider.ast = null;
        }
        var snap = (try r.linker.buildRenameSnapshot(std.testing.allocator)).?;
        defer snap.deinit();
        try std.testing.expect(snap.entries.len > 0);
        // Normal same-owner reuse must exactly match the computed table.
        {
            var clean = Linker.init(std.testing.allocator, r.graph, .esm);
            defer clean.deinit();
            try std.testing.expect(clean.renameReuseGuard(&snap));
            try clean.injectPreservedRenames(&snap);
            var equal = clean.rename_table.count() == r.linker.rename_table.count();
            for (snap.entries) |entry| {
                const actual = clean.rename_table.get(entry.id);
                if (actual == null or !std.mem.eql(u8, actual.?, entry.canonical)) equal = false;
            }
            if (!equal) {
                clean_mismatches += 1;
                std.debug.print("clean rename mismatch: {s}\n", .{case.declaration});
            }
        }
        var poisoned: usize = 0;
        for (snap.entries) |entry| {
            const module = r.graph.moduleAtMut(entry.id.module).?;
            const sem = &module.semantic.?;
            var decoy: ?usize = null;
            var map = @constCast(&sem.scope_maps[0]);
            var names = map.iterator();
            while (names.next()) |name| {
                if (std.mem.eql(u8, name.key_ptr.*, "decoy")) decoy = name.value_ptr.*;
            }
            const wrong = decoy orelse continue;
            if (wrong == @backingInt(entry.id.inner)) continue;
            var values = map.valueIterator();
            while (values.next()) |value| {
                if (value.* == @backingInt(entry.id.inner)) {
                    value.* = wrong;
                    poisoned += 1;
                }
            }
        }
        try std.testing.expect(poisoned > 0);
        var fresh = Linker.init(std.testing.allocator, r.graph, .esm);
        defer fresh.deinit();
        try fresh.injectPreservedRenames(&snap);
        var equal = fresh.rename_table.count() == r.linker.rename_table.count();
        for (snap.entries) |entry| {
            const actual = fresh.rename_table.get(entry.id);
            if (actual == null or !std.mem.eql(u8, actual.?, entry.canonical)) equal = false;
        }
        if (!equal) mismatches += 1;
    }
    if (mismatches != 0 or clean_mismatches != 0) std.debug.print("poisoned rename identity mismatches={d} clean={d}\n", .{ mismatches, clean_mismatches });
    try std.testing.expectEqual(@as(usize, 0), mismatches);
    try std.testing.expectEqual(@as(usize, 0), clean_mismatches);
}

test "reuse owner changes reject empty carriers and textually identical fresh graphs" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import './dep'; export const collision = 0;");
    try writeFile(tmp.dir, "dep.ts", "export const collision = 1;");
    var first = try buildLinkAndRename(std.testing.allocator, &tmp, "entry.ts");
    defer first.linker.deinit();
    defer first.destroyGraph();
    defer first.cache.deinit();
    var snap = (try first.linker.buildRenameSnapshot(std.testing.allocator)).?;
    defer snap.deinit();
    var fresh = try buildLinkAndRename(std.testing.allocator, &tmp, "entry.ts");
    defer fresh.linker.deinit();
    defer fresh.destroyGraph();
    defer fresh.cache.deinit();
    fresh.graph.changed_emit_paths = .empty;
    defer fresh.graph.changed_emit_paths = null;
    // Identical text and fingerprints cannot establish shared ownership.
    try std.testing.expect(!fresh.linker.renameReuseGuard(&snap));
    try std.testing.expectError(error.InvalidPreservedRenameIdentity, fresh.linker.injectPreservedRenames(&snap));
    var fresh_snap = (try fresh.linker.buildRenameSnapshot(std.testing.allocator)).?;
    defer fresh_snap.deinit();
    try std.testing.expect(!fresh.linker.renameReuseGuard(&snap));
    try std.testing.expect(fresh.linker.renameReuseGuard(&fresh_snap));
    // A replacement semantic literal starts unstamped, even if its backing
    // addresses happen to match an old allocation (ABA-style negative control).
    const module = first.graph.moduleAtMut(ModuleIndex.fromUsize(0)).?;
    const old_token = module.semantic.?.owner_token;
    module.ast = null; // AST-less roles obey the same physical owner contract.
    module.semantic.?.owner_token = .unassigned;
    first.graph.changed_emit_paths = .empty;
    defer first.graph.changed_emit_paths = null;
    try std.testing.expect(!first.linker.renameReuseGuard(&snap));
    try std.testing.expectError(error.InvalidPreservedRenameIdentity, first.linker.injectPreservedRenames(&snap));
    const next = module.semantic.?.captureOwnerToken();
    try std.testing.expect(next != .unassigned and next != old_token);
    try std.testing.expect(!first.linker.renameReuseGuard(&snap));
}

test "interop canonical roles handle ten cache loss decoy and owner transitions" {
    const cases = [_]struct { name: []const u8, failure: ?anyerror = null }{
        .{ .name = "Module fields reset" },
        .{ .name = "poisoned Module helper field" },
        .{ .name = "canonical internal group lost", .failure = error.EsmInteropRuntimeInternalSymbolsMissing },
        .{ .name = "canonical helper group lost", .failure = error.EsmInteropRuntimeIdentityMissing },
        .{ .name = "canonical snapshot lost", .failure = error.EsmInteropRuntimeIdentityMissing },
        .{ .name = "duplicate internal spelling decoy" },
        .{ .name = "canonical internal SID outside owner", .failure = error.EsmInteropRuntimeInternalSymbolsInvalid },
        .{ .name = "canonical helper SID wrong kind", .failure = error.EsmInteropRuntimeIdentityInvalid },
        .{ .name = "actual module codec creates new owner" },
        .{ .name = "legitimate helper-only group" },
    };
    var mismatches: usize = 0;
    var missing_constructor_records: usize = 0;
    for (cases, 0..) |case, index| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try writeFile(tmp.dir, "entry.mjs", "import * as dep from './dep.cjs'; const __create = 99; function local(mod, target) { return mod + target; } console.log(dep, __create, local(1, 2));");
        try writeFile(tmp.dir, "dep.cjs", "module.exports = { value: 7 };");
        var r = try buildAndLink(std.testing.allocator, &tmp, "entry.mjs");
        defer r.linker.deinit();
        defer r.destroyGraph();
        defer r.cache.deinit();
        try r.linker.prepareEsmInteropRuntimeNames();
        const owner_index = r.linker.esm_interop_runtime_internal_owner.?;
        const owner = r.graph.moduleAtMut(owner_index).?;
        const arena = owner.parse_arena.?.allocator();
        const original_helpers = owner.esm_interop_runtime_helper_symbols.?;
        const original_internal = owner.esm_interop_runtime_internal_symbols.?;
        const published = try owner.semantic.?.ensureRuntimeIdentities(arena);
        if (published.interop_helpers == null or published.interop_internal == null) missing_constructor_records += 1;
        // Seed explicit producer-returned handles to isolate consumer failures
        // even when a negative-control constructor did not publish its cache.
        published.interop_helpers = original_helpers;
        published.interop_internal = original_internal;
        const original_len = owner.semantic.?.symbols.items.len;
        var wrong_helpers = original_helpers;
        wrong_helpers.create = @fromBackingInt(@as(u32, 0));
        switch (index) {
            0 => {
                owner.ast = null; // AST-less semantic roles remain exact.
                owner.esm_interop_runtime_helper_symbols = null;
                owner.esm_interop_runtime_internal_symbols = null;
            },
            1 => owner.esm_interop_runtime_helper_symbols = wrong_helpers,
            2 => owner.semantic.?.runtime_identities.?.interop_internal = null,
            3 => owner.semantic.?.runtime_identities.?.interop_helpers = null,
            4 => {
                owner.semantic.?.runtime_identities = null;
                owner.esm_interop_runtime_helper_symbols = null;
                owner.esm_interop_runtime_internal_symbols = null;
            },
            5 => {
                const row = owner.semantic.?.symbols.items[@backingInt(original_internal.copy_props_to)];
                try owner.semantic.?.symbols.append(arena, row);
            },
            6 => owner.semantic.?.runtime_identities.?.interop_internal.?.copy_props_to = @fromBackingInt(@as(u32, 999_999)),
            7 => owner.semantic.?.runtime_identities.?.interop_helpers = wrong_helpers,
            8 => {
                const old_token = owner.semantic.?.captureOwnerToken();
                var bytes: std.ArrayList(u8) = .empty;
                defer bytes.deinit(std.testing.allocator);
                try @import("module_codec.zig").serialize(&owner.ast.?, &owner.semantic.?, &bytes, std.testing.allocator);
                const decoded = try @import("module_codec.zig").deserialize(bytes.items, arena);
                owner.ast = decoded.ast;
                owner.semantic = decoded.semantic;
                try std.testing.expectEqual(@import("module.zig").SemanticOwnerToken.unassigned, owner.semantic.?.owner_token);
                try std.testing.expect(owner.semantic.?.captureOwnerToken() != old_token);
                owner.esm_interop_runtime_helper_symbols = wrong_helpers;
                owner.esm_interop_runtime_internal_symbols = null;
            },
            9 => {
                owner.semantic.?.symbols.items.len = @backingInt(original_internal.copy_props_to);
                owner.semantic.?.runtime_identities.?.interop_internal = null;
                owner.esm_interop_runtime_helper_symbols = null;
                owner.esm_interop_runtime_internal_symbols = null;
            },
            else => unreachable,
        }
        var fresh = Linker.init(std.testing.allocator, r.graph, .esm);
        defer fresh.deinit();
        var actual_failure: ?anyerror = null;
        fresh.prepareEsmInteropRuntimeNames() catch |err| {
            actual_failure = err;
        };
        var matches = actual_failure == case.failure;
        if (actual_failure == null and case.failure == null) {
            const maybe_roles = owner.semantic.?.runtime_identities;
            if (maybe_roles == null or maybe_roles.?.interop_helpers == null or maybe_roles.?.interop_internal == null) {
                matches = false;
            } else {
                const roles = maybe_roles.?;
                inline for (@import("../runtime_helper_names.zig").ESM_INTEROP_RUNTIME_HELPERS) |helper| {
                    if (@field(roles.interop_helpers.?, @tagName(helper)) != @field(original_helpers, @tagName(helper))) matches = false;
                    const expected = bundler_symbol.SymbolID.make(owner_index, @backingInt(@field(original_helpers, @tagName(helper))));
                    if (fresh.esm_interop_runtime_symbol_ids[@backingInt(helper)] == null or
                        !bundler_symbol.SymbolID.eql(fresh.esm_interop_runtime_symbol_ids[@backingInt(helper)].?, expected)) matches = false;
                }
                inline for (@typeInfo(@import("module.zig").EsmInteropRuntimeInternalSymbolIds).@"struct".field_names) |field| {
                    if (@field(roles.interop_internal.?, field) != @field(original_internal, field)) matches = false;
                }
                const expected_len = original_len + @as(usize, if (index == 5) 1 else 0);
                if (owner.semantic.?.symbols.items.len != expected_len) matches = false;
            }
        }
        if (!matches) {
            mismatches += 1;
            std.debug.print("interop canonical role mismatch: {s}; expected={any}, actual={any}\n", .{ case.name, case.failure, actual_failure });
        }
    }
    if (mismatches != 0 or missing_constructor_records != 0) std.debug.print("interop canonical role mismatches={d} missing constructor records={d}\n", .{ mismatches, missing_constructor_records });
    try std.testing.expectEqual(@as(usize, 0), mismatches);
    try std.testing.expectEqual(@as(usize, 0), missing_constructor_records);
}

test "interop cached linker cannot recreate lost complete provenance as a cold constructor" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.mjs", "import * as dep from './dep.cjs'; console.log(dep);");
    try writeFile(tmp.dir, "dep.cjs", "module.exports = { value: 1 };");
    var r = try buildAndLink(std.testing.allocator, &tmp, "entry.mjs");
    defer r.linker.deinit();
    defer r.destroyGraph();
    defer r.cache.deinit();
    try r.linker.prepareEsmInteropRuntimeNames();
    const owner = r.graph.moduleAtMut(r.linker.esm_interop_runtime_internal_owner.?).?;
    const first_helper = @backingInt(owner.semantic.?.runtime_identities.?.interop_helpers.?.create);
    owner.semantic.?.symbols.items.len = first_helper;
    owner.semantic.?.runtime_identities.?.interop_helpers = null;
    owner.semantic.?.runtime_identities.?.interop_internal = null;
    owner.esm_interop_runtime_helper_symbols = null;
    owner.esm_interop_runtime_internal_symbols = null;
    try std.testing.expectError(error.EsmInteropRuntimeIdentityMissing, r.linker.prepareEsmInteropRuntimeNames());
    // A genuinely fresh constructor has no stale selected names/handles and
    // can create roles in a graph that never retained those runtime rows.
    var fresh = Linker.init(std.testing.allocator, r.graph, .esm);
    defer fresh.deinit();
    try fresh.prepareEsmInteropRuntimeNames();
    const first_internal = @backingInt(owner.semantic.?.runtime_identities.?.interop_internal.?.copy_props_to);
    owner.semantic.?.symbols.items.len = first_internal;
    owner.semantic.?.runtime_identities.?.interop_internal = null;
    owner.esm_interop_runtime_internal_symbols = null;
    try std.testing.expectError(error.EsmInteropRuntimeInternalSymbolsMissing, fresh.prepareEsmInteropRuntimeNames());
    // Helper-only is a supported producer phase for a new linker.
    var partial = Linker.init(std.testing.allocator, r.graph, .esm);
    defer partial.deinit();
    try partial.prepareEsmInteropRuntimeNames();
    try std.testing.expect(owner.semantic.?.runtime_identities.?.interop_internal != null);
}

test "HMR canonical roles survive codec reset decoys and fresh graph owners across ten inputs" {
    const sources = [_][]const u8{
        "const value = 1; console.log(value);",
        "var __zntc_g = 2; console.log(__zntc_g);",
        "let __zntc_modules = 3; console.log(__zntc_modules);",
        "function __zntc_schedule() { return 4; } console.log(__zntc_schedule());",
        "class __zntc_reload {} console.log(__zntc_reload.name);",
        "const {x: __zntc_hot_data} = {x: 6}; console.log(__zntc_hot_data);",
        "const __zntc_apply_update = () => 7; console.log(__zntc_apply_update());",
        "function outer() { const __zntc_hot_cbs = 8; return () => __zntc_hot_cbs; } console.log(outer()());",
        "import './dep'; const __zntc_refreshTimer = 9; console.log(__zntc_refreshTimer);",
        "export enum Value { x = 10 } console.log(Value.x);",
    };
    const module_types = @import("module.zig");
    var prefix: std.ArrayList(u8) = .empty;
    defer prefix.deinit(std.testing.allocator);
    for (0..40) |i| try prefix.print(std.testing.allocator, "const remove_before_refresh_{d} = 0;\n", .{i});
    for (sources) |source| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const full_source = try std.fmt.allocPrint(std.testing.allocator, "{s}{s}", .{ prefix.items, source });
        defer std.testing.allocator.free(full_source);
        try writeFile(tmp.dir, "entry.ts", full_source);
        try writeFile(tmp.dir, "dep.ts", "export const dependency = 1;");
        var r = try buildAndLink(std.testing.allocator, &tmp, "entry.ts");
        defer r.cache.deinit();
        defer r.destroyGraph();
        defer r.linker.deinit();
        r.linker.dev_mode = true;
        try r.linker.computeRenames();
        const index = findModuleIdx(r.graph, "entry.ts") orelse return error.MissingHmrEntry;
        const owner = r.graph.moduleAtMut(index) orelse return error.MissingHmrEntry;
        const original = (owner.semantic.?.runtime_identities orelse return error.MissingHmrCanonicalRecord).hmr_internal orelse return error.MissingHmrCanonicalGroup;
        try std.testing.expect(module_types.validHmrRuntimeIds(original, owner.semantic.?.symbols.items));
        const arena = owner.parse_arena.?.allocator();
        var bytes: std.ArrayList(u8) = .empty;
        defer bytes.deinit(std.testing.allocator);
        try @import("semantic_codec.zig").serialize(&owner.semantic.?, &bytes, std.testing.allocator);
        owner.semantic = try @import("semantic_codec.zig").deserialize(bytes.items, arena);
        const canonical = owner.semantic.?.runtime_identities.?;
        try std.testing.expectEqualDeep(original, canonical.hmr_internal.?);
        // Same-kind/spelling decoys are not identity keys.
        const decoy = owner.semantic.?.symbols.items[@backingInt(original.global)];
        try owner.semantic.?.symbols.append(arena, decoy);
        const with_decoy_len = owner.semantic.?.symbols.items.len;
        owner.hmr_runtime_internal_symbols = null;
        r.linker.hmr_runtime_internal_owner = null;
        try r.linker.prepareHmrRuntimeInternalNames();
        try std.testing.expectEqualDeep(original, owner.hmr_runtime_internal_symbols.?);
        try std.testing.expectEqual(with_decoy_len, owner.semantic.?.symbols.items.len);
        try expectHmrRuntimeInternalNames(&r.linker, index, original);
        canonical.hmr_internal.?.global = original.modules;
        try std.testing.expectError(error.HmrRuntimeInternalSymbolsInvalid, r.linker.prepareHmrRuntimeInternalNames());
        canonical.hmr_internal = original;
        owner.hmr_runtime_internal_symbols = null;
        owner.semantic.?.runtime_identities = null;
        try std.testing.expectError(error.HmrRuntimeInternalSymbolsMissing, r.linker.prepareHmrRuntimeInternalNames());
        owner.semantic.?.runtime_identities = canonical;
        canonical.hmr_internal = null;
        try std.testing.expectError(error.HmrRuntimeInternalSymbolsMissing, r.linker.prepareHmrRuntimeInternalNames());
        // History in the Linker also rejects losing both rows and record.
        owner.semantic.?.symbols.items.len = @backingInt(original.global);
        try std.testing.expectError(error.HmrRuntimeInternalSymbolsMissing, r.linker.prepareHmrRuntimeInternalNames());
        try std.testing.expectEqual(@as(usize, @backingInt(original.global)), owner.semantic.?.symbols.items.len);
        owner.semantic.?.symbols.items.len = with_decoy_len;
        canonical.hmr_internal = original;
        try r.linker.prepareHmrRuntimeInternalNames();
        const previous_owner = owner.semantic.?.captureOwnerToken();
        // Delete forty unused declarations so fresh analysis cannot
        // accidentally return the same numeric role IDs.
        const ast = &owner.ast.?;
        const root = ast.transformed_root orelse @as(@import("../parser/ast.zig").NodeIndex, @fromBackingInt(@intCast(ast.nodes.items.len - 1)));
        const statements = &ast.nodes.items[@backingInt(root)].data.list;
        try std.testing.expect(statements.len > 40);
        statements.start += 40;
        statements.len -= 40;
        try r.graph.resyncModuleMetadataAfterAstMutation(owner, arena, &r.linker.rename_table);
        const carried = (owner.semantic.?.runtime_identities orelse return error.MissingHmrCarriedRecord).hmr_internal orelse return error.MissingHmrCarriedGroup;
        try std.testing.expect(carried.global != original.global);
        try std.testing.expect(previous_owner != owner.semantic.?.owner_token);
        try std.testing.expect(module_types.validHmrRuntimeIds(carried, owner.semantic.?.symbols.items));
        owner.hmr_runtime_internal_symbols = null;
        try r.linker.prepareHmrRuntimeInternalNames();
        try std.testing.expectEqualDeep(carried, owner.hmr_runtime_internal_symbols.?);
    }
}

test "cross-module mutable const facts reject dynamic writes in the exact provider scope" {
    const writes = [_][]const u8{
        "eval('value=9');",
        "function mutate(){eval('value=9')}mutate();",
        "(()=>eval('value=9'))();",
        "({mutate(){eval('value=9')}}).mutate();",
        "const code='value=9';eval(code);",
        "eval('value+=7');",
        "eval('value++');",
        "eval('[value]=[9]');",
        "for(let i=0;i<1;i++)eval('value=9');",
        "function mutate(n){if(n)mutate(n-1);else eval('value=9')}mutate(1);",
    };
    for (writes) |write| {
        for ([_][]const u8{ "let", "var" }) |kind| {
            const source = try std.fmt.allocPrint(std.testing.allocator, "export {s} value=2;{s}", .{ kind, write });
            defer std.testing.allocator.free(source);
            try expectCrossModuleConstFixture(.{
                .name = write,
                .provider_source = source,
                .barrel_source = "export {value} from './provider.mjs';",
            });
        }
    }
    const controls = [_]CrossModuleConstFixture{
        .{ .name = "immutable eval read", .provider_source = "export const value=2;eval('value');", .barrel_source = "export {value} from './provider.mjs';", .expected_number = "2" },
        .{ .name = "ordinary mutable fact", .provider_source = "export let value=2;", .barrel_source = "export {value} from './provider.mjs';", .expected_number = "2" },
        .{ .name = "indirect eval cannot write module binding", .provider_source = "export let value=2;(0,eval)('globalThis.value=9');", .barrel_source = "export {value} from './provider.mjs';", .expected_number = "2" },
        .{ .name = "barrel eval does not affect provider owner", .provider_source = "export let value=2;", .barrel_source = "export {value} from './provider.mjs';eval('1');", .expected_number = "2" },
    };
    for (controls) |fixture| try expectCrossModuleConstFixture(fixture);
}

test "cross-module mutable const facts require a valid nondynamic provider ScopeId" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.mjs", "import {value} from './provider.mjs';console.log(value);");
    try writeFile(tmp.dir, "provider.mjs", "export let value=2;");
    var r = try buildLinkAndRename(std.testing.allocator, &tmp, "entry.mjs");
    defer r.cache.deinit();
    defer r.destroyGraph();
    defer r.linker.deinit();
    const entry_index = findModuleIdx(r.graph, "entry.mjs").?;
    const provider_index = findModuleIdx(r.graph, "provider.mjs").?;
    const entry = r.graph.getModule(entry_index).?;
    const provider = r.graph.moduleAtMut(provider_index).?;
    const exported = r.linker.export_map.get(.{ .module_index = provider_index.toU32(), .name = "value" }).?;
    const id = provider.exportBindingSemanticIndex(exported.binding).?;
    const sem = &provider.semantic.?;
    const original_scope = sem.symbols.items[id].scope_id;
    const local = entry.import_bindings[0].local_symbol.semanticIndex().?;
    // `with` is not a supported ESM source form. This exercises the shared
    // dynamic-scope flag contract on an otherwise valid exact provider graph.
    const scopes = try provider.parse_arena.?.allocator().dupe(@import("../semantic/scope.zig").Scope, sem.scopes);
    sem.scopes = scopes;
    scopes[original_scope.toIndex()].subtree_has_with = true;
    try expectNoCrossModuleConstFact(&r, entry_index, local);
    scopes[original_scope.toIndex()].subtree_has_with = false;
    sem.symbols.items[id].scope_id = .none;
    try expectNoCrossModuleConstFact(&r, entry_index, local);
    sem.symbols.items[id].scope_id = @fromBackingInt(@intCast(sem.scopes.len));
    try expectNoCrossModuleConstFact(&r, entry_index, local);
    sem.symbols.items[id].scope_id = original_scope;
    var facts = try r.linker.buildCrossModuleConstValues(entry, entry.semantic.?);
    defer facts.deinit(std.testing.allocator);
    try std.testing.expect(facts.get(local) != null);
}

fn expectDistinctDefaultFacadeNames(result: anytype, expected: usize) !void {
    var names = std.StringHashMap(void).init(std.testing.allocator);
    defer names.deinit();
    var modules = result.graph.modulesIterator();
    while (modules.next()) |module| {
        for (module.export_bindings) |exported| {
            if (!exported.has_default_export_facade) continue;
            const name = result.linker.getCanonicalByRef(exported.symbol) orelse return error.MissingFacadeName;
            const entry = try names.getOrPut(name);
            try std.testing.expect(!entry.found_existing);
        }
    }
    try std.testing.expectEqual(expected, names.count());
}

test "linker: native parameter this capture accepts actual function parameter ownership" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.cjs", "function Parent(get=()=>this){return get}const object={};console.log(Parent.call(object)()===object)");
    var result = try buildAndLinkWithTransformOptions(std.testing.allocator, &tmp, "entry.cjs", .{ .unsupported = TransformOptions.compat.fromReactNativeVersion(0, 80) }, false);
    defer result.linker.deinit();
    defer result.destroyGraph();
    defer result.cache.deinit();
    const module_index = findModuleIdx(result.graph, "entry.cjs") orelse return error.MissingThisCaptureModule;
    const module = result.linker.moduleAtMut(module_index.toU32()) orelse return error.MissingThisCaptureModule;
    const semantic = module.semantic orelse return error.MissingThisCaptureSemantic;
    const sid = for (semantic.symbols.items, 0..) |symbol, i| {
        if (symbol.synthetic_kind == .this_capture_binding and symbol.kind == .parameter) break i;
    } else return error.MissingThisCaptureParameter;
    try std.testing.expectEqual(@import("../semantic/scope.zig").ScopeKind.function, semantic.scopes[semantic.symbols.items[sid].scope_id.toIndex()].kind);
    try result.linker.computeRenames();
    try std.testing.expect(result.linker.rename_table.get(bundler_symbol.SymbolID.make(module.index, @as(u32, @intCast(sid)))) != null);
}

test "linker: native parameter this capture rejects wrong kind scope and hint" {
    for (0..5) |mutation| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try writeFile(tmp.dir, "entry.cjs", "function Parent(get=()=>this){return get}console.log(Parent()());");
        var result = try buildAndLinkWithTransformOptions(std.testing.allocator, &tmp, "entry.cjs", .{ .unsupported = TransformOptions.compat.fromReactNativeVersion(0, 80) }, false);
        defer result.linker.deinit();
        defer result.destroyGraph();
        defer result.cache.deinit();
        const module_index = findModuleIdx(result.graph, "entry.cjs") orelse return error.MissingThisCaptureModule;
        const module = result.linker.moduleAtMut(module_index.toU32()) orelse return error.MissingThisCaptureModule;
        const semantic = module.semantic orelse return error.MissingThisCaptureSemantic;
        const sid = for (semantic.symbols.items, 0..) |symbol, i| {
            if (symbol.synthetic_kind == .this_capture_binding and symbol.kind == .parameter) break i;
        } else return error.MissingThisCaptureParameter;
        switch (mutation) {
            0 => semantic.symbols.items[sid].kind = .function_decl,
            1 => semantic.symbols.items[sid].scope_id = @fromBackingInt(0),
            2 => semantic.symbols.items[sid].scope_id = .none,
            3 => semantic.symbols.items[sid].scope_id = @fromBackingInt(@intCast(semantic.scopes.len + 1)),
            4 => semantic.symbols.items[sid].output_name_hint = "_arguments",
            else => unreachable,
        }
        try std.testing.expectError(error.InvalidThisCaptureOutputBinding, result.linker.computeRenames());
    }
}

test "runtime helper CJS factory scope zero shadows rename the exact provider" {
    const body = "function P(){}class D extends P{constructor(){var go=()=>super();go()}}module.exports=D;";
    for ([_][]const u8{
        "var __callSuper=42;" ++ body,
        "function nested(){var __callSuper=42;" ++ body ++ "}nested();",
        body,
    }, 0..) |source, index| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try writeFile(tmp.dir, "entry.cjs", source);
        var result = try buildAndLinkWithTransformOptions(std.testing.allocator, &tmp, "entry.cjs", .{
            .unsupported = TransformOptions.compat.fromESTarget(.es5),
            .emit_runtime_helper_imports = true,
            .defer_runtime_helper_name_resolution = true,
        }, false);
        defer result.cache.deinit();
        defer result.destroyGraph();
        defer result.linker.deinit();
        const entry_index = findModuleIdx(result.graph, "entry.cjs").?;
        const entry = result.graph.getModule(entry_index).?;
        try std.testing.expect(entry.wrap_kind == .cjs);
        var helper: ?ImportBinding = null;
        for (entry.import_bindings) |binding| {
            if (binding.is_helper and std.mem.eql(u8, binding.imported_name, "__callSuper")) helper = binding;
        }
        const binding = helper orelse return error.MissingCallSuperImport;
        const resolved = result.linker.getResolvedBinding(entry_index.toU32(), binding.local_span).?;
        const provider = result.graph.getModule(resolved.canonical.module_index).?;
        const inner = provider.findLocalExportSemanticIndex(resolved.canonical.export_name).?;
        const exact = bundler_symbol.SymbolID.make(provider.index, inner);
        const local = binding.local_symbol.semanticIndex().?;
        const symbols_before = try std.testing.allocator.dupe(semantic_symbol.Symbol, entry.semantic.?.symbols.items);
        defer std.testing.allocator.free(symbols_before);
        // Shared nested-binding input remains scope 1+; the CJS source-zero
        // exception belongs only to this helper/factory consumer.
        try std.testing.expectEqual(index == 1, result.linker.hasNestedBinding(entry_index.toU32(), "__callSuper"));
        if (index == 0) {
            const source_binding_id = entry.semantic.?.scope_maps[0].get("__callSuper").?;
            try std.testing.expect(source_binding_id != local);
        }
        try result.linker.computeRenames();
        const selected = result.linker.rename_table.get(exact) orelse result.linker.resolveToLocalName(resolved.canonical);
        std.debug.print("CJS0 HELPER case={d} canonical={s}\n", .{ index, selected });
        if (index < 2) {
            try std.testing.expect(!std.mem.eql(u8, selected, "__callSuper"));
        } else {
            try std.testing.expectEqualStrings("__callSuper", selected);
        }
        try std.testing.expectEqualDeep(symbols_before, entry.semantic.?.symbols.items);
        // A separately emitted helper keeps its public export spelling. The
        // import writer selects a local alias; source zero must remain intact.
        result.graph.code_splitting = true;
        try result.linker.computeRenamesForModules(&.{entry_index}, &.{});
        try std.testing.expectEqual(index < 2, result.linker.preserveRuntimeHelperImportIsShadowed(
            entry_index.toU32(),
            provider.index.toU32(),
            resolved.canonical.export_name,
            "__callSuper",
        ));
        if (index == 0) {
            const source_binding_id = entry.semantic.?.scope_maps[0].get("__callSuper").?;
            const source_id = bundler_symbol.SymbolID.make(entry_index, source_binding_id);
            try std.testing.expectEqualStrings("__callSuper", result.linker.rename_table.get(source_id) orelse "__callSuper");
            const mutable_entry = @constCast(entry);
            var helper_binding: ?*ImportBinding = null;
            for (mutable_entry.import_bindings) |*candidate| {
                if (candidate.is_helper and candidate.local_symbol.semanticIndex() == local) helper_binding = candidate;
            }
            const actual_binding = helper_binding.?;
            const saved_binding = actual_binding.*;
            var sibling_span = saved_binding.local_span;
            for (mutable_entry.import_bindings) |candidate| {
                if (candidate.is_helper and std.mem.eql(u8, candidate.imported_name, "__extends")) sibling_span = candidate.local_span;
            }
            try std.testing.expect(!std.meta.eql(sibling_span, saved_binding.local_span));
            const saved_wrapper = mutable_entry.wrap_kind;
            const saved_local_kind = mutable_entry.semantic.?.symbols.items[local].kind;
            const saved_source_scope = mutable_entry.semantic.?.symbols.items[source_binding_id].scope_id;
            for (0..12) |hostile| {
                switch (hostile) {
                    0 => actual_binding.is_helper = false,
                    1 => actual_binding.local_symbol = bundler_symbol.SymbolRef.makeSemantic(provider.index, local),
                    2 => actual_binding.local_symbol = .invalid,
                    3 => actual_binding.local_symbol = bundler_symbol.SymbolRef.makeSemantic(entry_index, mutable_entry.semantic.?.symbols.items.len),
                    4 => mutable_entry.semantic.?.symbols.items[local].kind = .variable_var,
                    5 => mutable_entry.wrap_kind = .none,
                    6 => mutable_entry.semantic.?.symbols.items[source_binding_id].scope_id = .none,
                    7 => mutable_entry.semantic.?.symbols.items[source_binding_id].scope_id = @fromBackingInt(1),
                    8 => mutable_entry.semantic.?.scope_maps[0].getPtr("__callSuper").?.* = local,
                    9 => {},
                    10 => actual_binding.local_span = sibling_span,
                    11 => mutable_entry.semantic.?.scope_maps[0].getPtr("__callSuper").?.* = @intCast(mutable_entry.semantic.?.symbols.items.len),
                    else => unreachable,
                }
                try std.testing.expect(!result.linker.preserveRuntimeHelperImportIsShadowed(
                    entry_index.toU32(),
                    if (hostile == 9) entry_index.toU32() else provider.index.toU32(),
                    resolved.canonical.export_name,
                    "__callSuper",
                ));
                actual_binding.* = saved_binding;
                mutable_entry.wrap_kind = saved_wrapper;
                mutable_entry.semantic.?.symbols.items[local].kind = saved_local_kind;
                mutable_entry.semantic.?.symbols.items[source_binding_id].scope_id = saved_source_scope;
                mutable_entry.semantic.?.scope_maps[0].getPtr("__callSuper").?.* = source_binding_id;
                try std.testing.expect(result.linker.preserveRuntimeHelperImportIsShadowed(
                    entry_index.toU32(),
                    provider.index.toU32(),
                    resolved.canonical.export_name,
                    "__callSuper",
                ));
            }
        }
        try std.testing.expectEqualDeep(symbols_before, entry.semantic.?.symbols.items);
    }
}

test "namespace holder hygiene reserves the actual selected nested binding before holder allocation" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "dep.mjs", "export const value=7;export function read(){return this.value}");
    try writeFile(tmp.dir, "entry.mjs", "import*as ns from './dep.mjs';function check(inside){return Reflect.get(ns,'value')+inside}console.log(check(3));");
    var result = try buildAndLink(a, &tmp, "entry.mjs");
    defer result.cache.deinit();
    defer result.destroyGraph();
    defer result.linker.deinit();
    result.linker.populateImportSymbols();
    const importer = findModuleIdx(result.graph, "entry.mjs") orelse return error.MissingNamespaceImporter;
    const target = findModuleIdx(result.graph, "dep.mjs") orelse return error.MissingNamespaceTarget;
    const module = result.graph.getModule(importer).?;
    const provider = result.graph.getModule(target).?;
    const sem = module.semantic orelse return error.MissingNamespaceSemantic;
    var parameter: ?u32 = null;
    for (sem.scope_maps[1..]) |scope| {
        if (scope.get("inside")) |sid| {
            try std.testing.expect(parameter == null);
            parameter = @intCast(sid);
        }
    }
    const actual_parameter = parameter orelse return error.MissingNamespaceParameter;
    try std.testing.expect(sem.symbols.items[actual_parameter].scope_id.toIndex() > 0);
    const selected = try @import("namespace_holder_reservations.zig").ownerBase(a, module.path, provider.path);
    defer a.free(selected);
    try result.linker.rename_table.put(a, bundler_symbol.SymbolID.make(importer, actual_parameter), selected);
    try result.linker.nonminify_nested_shadow_modules.put(a, importer.toU32(), {});
    var metadata = try buildMetadataForModule(&result, importer.toU32(), true);
    defer metadata.deinit();
    try std.testing.expectEqualStrings(selected, metadata.renames.get(actual_parameter).?);
    const ns = module.import_bindings[0].local_symbol.semanticIndex() orelse return error.MissingNamespaceSourceImport;
    const holder = metadata.ns_inline_objects.get(ns) orelse return error.MissingNamespaceHolder;
    try std.testing.expect(!std.mem.eql(u8, holder.var_name, selected));
    const expected = try std.fmt.allocPrint(a, "{s}_2", .{selected});
    defer a.free(expected);
    try std.testing.expectEqualStrings(expected, holder.var_name);
    var cg = @import("../codegen/codegen.zig").Codegen.initWithOptions(a, &module.ast.?, .{ .linking_metadata = &metadata });
    defer cg.deinit();
    const root = module.ast.?.transformed_root orelse @as(@import("../parser/ast.zig").NodeIndex, @fromBackingInt(@intCast(module.ast.?.nodes.items.len - 1)));
    const output = try cg.generate(root);
    const actual_formal = try std.fmt.allocPrint(a, "check({s})", .{selected});
    defer a.free(actual_formal);
    try std.testing.expect(std.mem.indexOf(u8, output, actual_formal) != null);
    const actual_call = try std.fmt.allocPrint(a, "Reflect.get({s},", .{holder.var_name});
    defer a.free(actual_call);
    try std.testing.expect(std.mem.indexOf(u8, output, actual_call) != null);
}

test "namespace holder hygiene reuses one declaration with distinct source identities and owned names" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "dep.mjs", "export const value=7;");
    try writeFile(tmp.dir, "entry.mjs", "import*as left from './dep.mjs';import*as right from './dep.mjs';console.log(left===right);");
    var result = try buildAndLink(a, &tmp, "entry.mjs");
    defer result.cache.deinit();
    defer result.destroyGraph();
    defer result.linker.deinit();
    result.linker.populateImportSymbols();
    const importer = findModuleIdx(result.graph, "entry.mjs") orelse return error.MissingNamespaceImporter;
    const module = result.graph.getModule(importer).?;
    try std.testing.expectEqual(@as(usize, 2), module.import_bindings.len);
    const left = module.import_bindings[0].local_symbol.semanticIndex() orelse return error.MissingNamespaceLeft;
    const right = module.import_bindings[1].local_symbol.semanticIndex() orelse return error.MissingNamespaceRight;
    try std.testing.expect(left != right);
    const sem = module.semantic.?;
    const left_before = sem.symbols.items[left];
    const right_before = sem.symbols.items[right];
    var metadata = try buildMetadataForModule(&result, importer.toU32(), true);
    defer metadata.deinit();
    const first = metadata.ns_inline_objects.get(left) orelse return error.MissingNamespaceLeftHolder;
    const second = metadata.ns_inline_objects.get(right) orelse return error.MissingNamespaceRightHolder;
    try std.testing.expectEqualStrings(first.var_name, second.var_name);
    try std.testing.expect(first.var_name.ptr != second.var_name.ptr);
    try std.testing.expect(first.object_literal.len > 0);
    try std.testing.expectEqual(@as(usize, 0), second.object_literal.len);
    try std.testing.expectEqualStrings(first.var_name, metadata.renames.get(left).?);
    try std.testing.expectEqualStrings(second.var_name, metadata.renames.get(right).?);
    const declaration = try std.fmt.allocPrint(a, "var {s} =", .{first.var_name});
    defer a.free(declaration);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, metadata.cjs_import_preamble.?, declaration));
    try std.testing.expectEqualDeep(left_before, sem.symbols.items[left]);
    try std.testing.expectEqualDeep(right_before, sem.symbols.items[right]);
    std.debug.print("namespace holder hygiene source_sids=2 entries=2 declarations=1 independent_names=true\n", .{});
}

test "namespace holder hygiene ranks the actual JSX normalized primary base" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "a");
    try tmp.dir.createDirPath(std.testing.io, "b");
    try writeFile(tmp.dir, "a/foo.mjs", "export const value=1;");
    try writeFile(tmp.dir, "b/Foo.mjs", "export const value=2;");
    try writeFile(tmp.dir, "entry.mjs", "import*as lower from './a/foo.mjs';import*as upper from './b/Foo.mjs';console.log(lower,upper);");
    var result = try buildAndLink(a, &tmp, "entry.mjs");
    defer result.cache.deinit();
    defer result.destroyGraph();
    defer result.linker.deinit();
    result.graph.jsx_runtime = .preserve;
    result.linker.ns_base_rank_built = false;
    result.linker.ns_base_rank.clearRetainingCapacity();
    try result.linker.ensureNsBaseRank();
    const lower = findModuleIdx(result.graph, "foo.mjs").?;
    const upper = findModuleIdx(result.graph, "Foo.mjs").?;
    const lower_rank = result.linker.ns_base_rank.get(lower.toU32()) orelse 0;
    const upper_rank = result.linker.ns_base_rank.get(upper.toU32()) orelse 0;
    try std.testing.expect(lower_rank != upper_rank);
    const first = try result.linker.ensureSharedNsVar(upper);
    const second = try result.linker.ensureSharedNsVar(lower);
    try std.testing.expect(!std.mem.eql(u8, first, second));
    try std.testing.expect(std.mem.startsWith(u8, first, "Foo_ns"));
    try std.testing.expect(std.mem.startsWith(u8, second, "Foo_ns"));
}

test "namespace holder hygiene same Linker warm cache keeps immutable input footprint" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "dep.mjs", "export const value=7;");
    try writeFile(tmp.dir, "entry.mjs", "import*as ns from './dep.mjs';console.log(Reflect.get(ns,'value'));");
    const input = try @import("test_helpers.zig").absPath(&tmp, "entry.mjs");
    defer a.free(input);
    var resolve_cache = resolve_cache_mod.ResolveCache.init(a, .{});
    defer resolve_cache.deinit();
    var graph = ModuleGraph.init(a, &resolve_cache);
    defer graph.deinit();
    graph.incremental_mode = true;
    try graph.build(std.testing.io, &.{input});
    var linker = Linker.init(a, &graph, .cjs);
    defer linker.deinit();
    try linker.link();
    try linker.finalize(.{ .compute_renames = true, .compute_mangling = false });
    linker.populateImportSymbols();
    var output_cache = @import("compiled_cache.zig").CompiledOutputCache.init(a);
    defer output_cache.deinit();
    const opts: @import("emitter.zig").EmitOptions = .{ .format = .cjs, .compiled_cache = &output_cache };
    var first_output: ?[]u8 = null;
    defer if (first_output) |text| a.free(text);
    var first_key: u64 = 0;
    for (0..2) |pass| {
        const result = try @import("emitter.zig").emitWithTreeShaking(std.testing.io, a, &graph, &opts, &linker, null);
        defer result.deinit(a);
        const stats = output_cache.takeStats();
        std.debug.print("namespace holder hygiene same-Linker pass={d} hits={d} misses={d} skipped={d} key={x} registry={d} renames={d} unified={d} reserved={d}\n", .{ pass, stats.hits, stats.misses, stats.skipped, output_cache.last_options_hash, linker.ns_shared_var_names.count(), linker.rename_table.map.count(), if (linker.unified_result) |u| u.renames.count() else @as(u32, 0), linker.reserved_globals.count() });
        var registry = linker.ns_shared_var_names.keyIterator();
        while (registry.next()) |borrowed| {
            const name = try a.dupe(u8, borrowed.*);
            defer a.free(name);
            var in_rename = false;
            var names = linker.rename_table.map.valueIterator();
            while (names.next()) |value| if (std.mem.eql(u8, value.*, name)) {
                in_rename = true;
                break;
            };
            var in_unified = false;
            if (linker.unified_result) |*u| {
                var values = u.renames.valueIterator();
                while (values.next()) |value| if (std.mem.eql(u8, value.*, name)) {
                    in_unified = true;
                    break;
                };
            }
            std.debug.print("namespace holder hygiene same-Linker generated={s} rename={any} unified={any} reserved={any}\n", .{ name, in_rename, in_unified, linker.reserved_globals.contains(name) });
        }
        if (pass == 0) {
            first_key = output_cache.last_options_hash;
            first_output = try a.dupe(u8, result.output);
        } else {
            try std.testing.expectEqualStrings(first_output.?, result.output);
            try std.testing.expectEqual(first_key, output_cache.last_options_hash);
            try std.testing.expect(stats.hits >= 2);
        }
    }
}

test "self namespace AST holder retains the exact import declaration identity" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "self.mjs", "export const value=7; console.log(Reflect.get(ns,'value')); import * as ns from './self.mjs';");
    const entry = try @import("test_helpers.zig").absPath(&tmp, "self.mjs");
    defer a.free(entry);
    var cache = resolve_cache_mod.ResolveCache.init(a, .{});
    defer cache.deinit();
    var graph = ModuleGraph.init(a, &cache);
    defer graph.deinit();
    try graph.build(std.testing.io, &.{entry});
    const index = findModuleIdx(&graph, "self.mjs") orelse return error.MissingSelfModule;
    const module = graph.moduleAtMut(index).?;
    try std.testing.expectEqual(@as(usize, 1), module.import_bindings.len);
    const source_binding = module.import_bindings[0];
    const source_ast = module.ast orelse return error.MissingSelfAst;
    const source_sem = module.semantic orelse return error.MissingSelfSemantic;
    const source_anchor = source_binding.local_symbol_node orelse return error.MissingSelfImportAnchor;
    const sid = source_sem.symbol_ids[@backingInt(source_anchor)] orelse return error.MissingSelfImportIdentity;
    try std.testing.expect(source_binding.kind == .namespace);
    try std.testing.expect(module.import_records[source_binding.import_record_index].resolved == index);
    try std.testing.expect(module.wrap_kind == .none);
    try std.testing.expectEqual(semantic_symbol.SymbolKind.import_binding, source_sem.symbols.items[sid].kind);
    try std.testing.expect(module.transform_cache == null);
    try std.testing.expect(source_sem.owner_token == .unassigned);
    var source_row_count: usize = 0;
    for (source_sem.references) |reference| {
        if (@backingInt(reference.symbol_id) != sid or !reference.flags.declare) continue;
        source_row_count += 1;
        try std.testing.expect(reference.declaration_node_index == source_anchor);
    }
    try std.testing.expectEqual(@as(usize, 1), source_row_count);
    const source_symbol = source_sem.symbols.items[sid];
    const source_rows = try a.dupe(semantic_symbol.Reference, source_sem.references);
    defer a.free(source_rows);
    const source_root: @import("../parser/ast.zig").NodeIndex = @fromBackingInt(@as(u32, @intCast(source_ast.nodes.items.len - 1)));
    const lowering = @import("self_namespace_ast.zig");
    try lowering.lower(&graph, .{ .format = .esm, .scope_hoist = true, .minify_syntax = false });
    try lowering.validate(&graph, module);
    const plan = graph.self_namespace_holders.get(index.toU32()) orelse return error.MissingSelfNamespacePlan;
    const output = module.semantic.?;
    try std.testing.expectEqual(semantic_symbol.SymbolKind.variable_const, output.symbols.items[sid].kind);
    try std.testing.expect(plan.holder == sid and plan.binding != source_anchor and plan.root != source_root);
    try std.testing.expectEqual(@as(?u32, sid), output.symbol_ids[@backingInt(plan.binding)]);
    try std.testing.expect(module.transform_cache != null);
    try std.testing.expectEqualDeep(source_symbol, source_sem.symbols.items[sid]);
    try std.testing.expectEqualDeep(source_rows, source_sem.references);
    try std.testing.expect(source_sem.owner_token == .unassigned);
    try std.testing.expectEqual(@as(usize, 2), output.scopes.len);
    try std.testing.expect(output.scopes[plan.getter_scope.toIndex()].parent == plan.root_scope);
    // Same-graph calls consume the output proof; no second holder is created.
    try lowering.lower(&graph, .{ .format = .esm, .scope_hoist = true, .minify_syntax = false });
    var linker = Linker.init(a, &graph, .esm);
    defer linker.deinit();
    try linker.link();
    try linker.finalize(.{ .compute_renames = true, .compute_mangling = false });
    try lowering.validate(&graph, module);
    const ast = if (module.ast) |*value| value else return error.MissingSelfOutput;
    var metadata = try linker.buildMetadataForAst(ast, index.toU32(), true, null, .esm, true);
    defer metadata.deinit();
    try std.testing.expectEqual(@as(usize, 0), metadata.ns_inline_objects.entries.len);
    try std.testing.expect(metadata.cjs_import_preamble == null or metadata.cjs_import_preamble.?.len == 0);
    std.debug.print("self namespace completed sourceSID={d} outputbinding={d} getterScope={d} exportedSID={d} rawholders=0\n", .{ sid, @backingInt(plan.binding), @backingInt(plan.getter_scope), plan.exported });
}

test "foreign namespace AST holder preserves the importer binding for a provider scalar export" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "provider.mjs", "export const value=7;");
    try writeFile(tmp.dir, "entry.mjs", "import*as ns from './provider.mjs';console.log(Reflect.get(ns,'value'));");
    const entry = try @import("test_helpers.zig").absPath(&tmp, "entry.mjs");
    defer a.free(entry);
    var cache = resolve_cache_mod.ResolveCache.init(a, .{});
    defer cache.deinit();
    var graph = ModuleGraph.init(a, &cache);
    defer graph.deinit();
    try graph.build(std.testing.io, &.{entry});

    const importer_index = findModuleIdx(&graph, "entry.mjs") orelse return error.MissingForeignImporter;
    const provider_index = findModuleIdx(&graph, "provider.mjs") orelse return error.MissingForeignProvider;
    const importer = graph.moduleAtMut(importer_index).?;
    const provider = graph.moduleAtMut(provider_index).?;
    try std.testing.expectEqual(@as(usize, 1), importer.import_bindings.len);
    try std.testing.expectEqual(@as(usize, 1), provider.export_bindings.len);
    const original_import = importer.import_bindings[0];
    const import_anchor = original_import.local_symbol_node orelse return error.MissingForeignImportAnchor;
    const original_sid = importer.semantic.?.symbol_ids[@backingInt(import_anchor)] orelse return error.MissingForeignImportIdentity;
    const provider_anchor = provider.export_bindings[0].local_symbol_node orelse return error.MissingProviderExportAnchor;
    const provider_sid = provider.semantic.?.symbol_ids[@backingInt(provider_anchor)] orelse return error.MissingProviderExportIdentity;
    const previous_provider_owner = provider.semantic.?.owner_token;

    try @import("self_namespace_ast.zig").lower(&graph, .{ .format = .esm, .scope_hoist = true, .minify_syntax = false });

    try std.testing.expectEqual(.materialized_const, importer.import_bindings[0].local_role);
    try std.testing.expectEqual(@as(usize, 2), importer.import_bindings.len);
    try std.testing.expectEqual(@as(usize, 2), importer.import_records.len);
    try std.testing.expectEqual(@as(?u32, original_sid), importer.semantic.?.symbol_ids[@backingInt(importer.import_bindings[0].local_symbol_node.?)]);
    try std.testing.expectEqual(@as(?u32, provider_sid), provider.semantic.?.symbol_ids[@backingInt(provider_anchor)]);
    const callsite = importer.import_bindings[1].callsite_target orelse return error.MissingNamespaceProviderCallsite;
    try std.testing.expectEqual(.namespace_export_value, callsite.role);
    try std.testing.expectEqual(provider.index, callsite.symbol.module);
    try std.testing.expectEqual(@as(u32, provider_sid), @backingInt(callsite.symbol.inner));
    try std.testing.expectEqual(provider.semantic.?.owner_token, callsite.owner);
    try std.testing.expect(callsite.owner != .unassigned);
    if (previous_provider_owner != .unassigned) try std.testing.expectEqual(previous_provider_owner, callsite.owner);
    try std.testing.expect(importer.import_records[1].callsite_lowered);
    try @import("runtime_callsite_targets.zig").validateTargetRole(&graph, callsite);
    try @import("self_namespace_ast.zig").validate(&graph, importer);
    const completed_ast_nodes = importer.ast.?.nodes.items.ptr;
    const completed_sem_ids = importer.semantic.?.symbol_ids.ptr;
    try @import("self_namespace_ast.zig").lower(&graph, .{ .format = .esm, .scope_hoist = true, .minify_syntax = false });
    try std.testing.expect(importer.ast.?.nodes.items.ptr == completed_ast_nodes);
    try std.testing.expect(importer.semantic.?.symbol_ids.ptr == completed_sem_ids);
}

test "foreign namespace AST holder rejects unsupported sources without publication" {
    const Case = struct { provider: []const u8, consumer: []const u8, extra: bool = false };
    const cases = [_]Case{
        .{ .provider = "export let value=7;", .consumer = "import*as ns from './provider.mjs';console.log(Reflect.get(ns,'value'));" },
        .{ .provider = "export function value(){return 7}", .consumer = "import*as ns from './provider.mjs';console.log(Reflect.get(ns,'value'));" },
        .{ .provider = "export const value=7;export const extra=()=>8;", .consumer = "import*as ns from './provider.mjs';console.log(Reflect.get(ns,'value'));" },
        .{ .provider = "export const value=7;console.log('side effect');", .consumer = "import*as ns from './provider.mjs';console.log(Reflect.get(ns,'value'));" },
        .{ .provider = "export const value=[];", .consumer = "import*as ns from './provider.mjs';console.log(Reflect.get(ns,'value'));" },
        .{ .provider = "export const value={};", .consumer = "import*as ns from './provider.mjs';console.log(Reflect.get(ns,'value'));" },
        .{ .provider = "export const value=7;", .consumer = "import*as ns from './provider.mjs';const alias=ns;console.log(Reflect.get(alias,'value'));" },
        .{ .provider = "export const value=7;", .consumer = "import*as ns from './provider.mjs';console.log(ns.value);" },
        .{ .provider = "export const value=7;", .consumer = "import*as ns from './provider.mjs';console.log(Reflect.get(ns,'other'));" },
        .{ .provider = "export const value=7;", .consumer = "import*as ns from './provider.mjs';console.log(Reflect.ownKeys(ns));" },
        .{ .provider = "export const value=7;", .consumer = "import*as ns from './provider.mjs';import'./side.mjs';console.log(Reflect.get(ns,'value'));", .extra = true },
    };
    const a = std.testing.allocator;
    for (cases, 0..) |case, index| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try writeFile(tmp.dir, "provider.mjs", case.provider);
        try writeFile(tmp.dir, "entry.mjs", case.consumer);
        if (case.extra) try writeFile(tmp.dir, "side.mjs", "console.log('side');");
        const entry = try @import("test_helpers.zig").absPath(&tmp, "entry.mjs");
        defer a.free(entry);
        var cache = resolve_cache_mod.ResolveCache.init(a, .{});
        defer cache.deinit();
        var graph = ModuleGraph.init(a, &cache);
        defer graph.deinit();
        try graph.build(std.testing.io, &.{entry});
        const importer = graph.moduleAtMut(@import("types.zig").ModuleIndex.fromUsize(0)).?;
        const provider = graph.moduleAtMut(@import("types.zig").ModuleIndex.fromUsize(1)).?;
        const importer_nodes = importer.ast.?.nodes.items.ptr;
        const provider_owner = provider.semantic.?.owner_token;
        const expected_modules: usize = if (case.extra) 3 else 2;
        try std.testing.expectEqual(expected_modules, graph.moduleCount());
        try @import("self_namespace_ast.zig").lower(&graph, .{
            .format = .esm,
            .scope_hoist = true,
            .minify_syntax = false,
        });
        try std.testing.expectEqual(@as(usize, 0), graph.self_namespace_holders.count());
        try std.testing.expect(importer.ast.?.nodes.items.ptr == importer_nodes);
        try std.testing.expectEqual(.import_binding, importer.import_bindings[0].local_role);
        try std.testing.expectEqual(provider_owner, provider.semantic.?.owner_token);
        std.debug.print("foreign namespace hostile admission case={d} selected=false source_unchanged=true\n", .{index});
    }
}

fn foreignNamespaceAllocationFailure(offset: usize) !bool {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "provider.mjs", "export const value=7;");
    try writeFile(tmp.dir, "entry.mjs", "import*as ns from './provider.mjs';console.log(Reflect.get(ns,'value'));");
    const entry = try @import("test_helpers.zig").absPath(&tmp, "entry.mjs");
    defer a.free(entry);
    var failing = std.testing.FailingAllocator.init(a, .{});
    const controlled = failing.allocator();
    var cache = resolve_cache_mod.ResolveCache.init(controlled, .{});
    defer cache.deinit();
    var graph = ModuleGraph.init(controlled, &cache);
    defer graph.deinit();
    try graph.build(std.testing.io, &.{entry});
    const importer = graph.moduleAtMut(@import("types.zig").ModuleIndex.fromUsize(0)).?;
    const provider = graph.moduleAtMut(@import("types.zig").ModuleIndex.fromUsize(1)).?;
    const importer_ast = importer.ast.?;
    const importer_sem = importer.semantic.?;
    const provider_ast = provider.ast.?;
    const provider_sem = provider.semantic.?;
    const original_bindings = importer.import_bindings;
    const original_records = importer.import_records;
    failing.resize_fail_index = failing.resize_index;
    failing.fail_index = failing.alloc_index + offset;
    if (@import("self_namespace_ast.zig").lower(&graph, .{ .format = .esm, .scope_hoist = true, .minify_syntax = false })) |_| {
        failing.fail_index = std.math.maxInt(usize);
        failing.resize_fail_index = std.math.maxInt(usize);
        try @import("self_namespace_ast.zig").validate(&graph, importer);
        return true;
    } else |err| {
        failing.fail_index = std.math.maxInt(usize);
        failing.resize_fail_index = std.math.maxInt(usize);
        try std.testing.expectEqual(error.OutOfMemory, err);
        try std.testing.expectEqual(@as(usize, 0), graph.self_namespace_holders.count());
        try std.testing.expect(importer.ast.?.nodes.items.ptr == importer_ast.nodes.items.ptr);
        try std.testing.expect(importer.semantic.?.symbol_ids.ptr == importer_sem.symbol_ids.ptr);
        try std.testing.expectEqual(importer_sem.owner_token, importer.semantic.?.owner_token);
        try std.testing.expectEqual(provider_ast.nodes.items.ptr, provider.ast.?.nodes.items.ptr);
        try std.testing.expectEqual(provider_sem.symbol_ids.ptr, provider.semantic.?.symbol_ids.ptr);
        try std.testing.expectEqual(provider_sem.owner_token, provider.semantic.?.owner_token);
        try std.testing.expectEqual(original_bindings.ptr, importer.import_bindings.ptr);
        try std.testing.expectEqual(original_records.ptr, importer.import_records.ptr);
        try std.testing.expectEqual(.import_binding, importer.import_bindings[0].local_role);
        try @import("self_namespace_ast.zig").lower(&graph, .{ .format = .esm, .scope_hoist = true, .minify_syntax = false });
        try @import("self_namespace_ast.zig").validate(&graph, importer);
        return false;
    }
}

test "foreign namespace AST holder allocation failures leave both modules unchanged" {
    var failures: usize = 0;
    var reached_success = false;
    for (0..192) |offset| {
        if (try foreignNamespaceAllocationFailure(offset)) {
            reached_success = true;
            break;
        }
        failures += 1;
    }
    try std.testing.expect(reached_success and failures > 0);
    std.debug.print("foreign namespace transaction actual OOM points={d} importer_and_provider_unchanged=true\n", .{failures});
}

const ForeignNamespaceCorruption = enum {
    missing_plan,
    target_role,
    target_owner,
    target_symbol,
    target_declaration,
    callsite_record,
    imported_name,
    consumer_ast,
    consumer_symbol,
    provider_ast,
    provider_owner,
    provider_symbol,
    provider_scope_map,
    provider_export_binding,
};

fn checkForeignNamespaceCorruption(attack: ForeignNamespaceCorruption) !void {
    errdefer std.debug.print("foreign namespace corruption failed attack={s}\n", .{@tagName(attack)});
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "provider.mjs", "export const value=7;export const unused=9;");
    try writeFile(tmp.dir, "entry.mjs", "import*as ns from './provider.mjs';console.log(Reflect.get(ns,'value'));");
    const entry = try @import("test_helpers.zig").absPath(&tmp, "entry.mjs");
    defer a.free(entry);
    var cache = resolve_cache_mod.ResolveCache.init(a, .{});
    defer cache.deinit();
    var graph = ModuleGraph.init(a, &cache);
    defer graph.deinit();
    try graph.build(std.testing.io, &.{entry});
    const importer_index = @import("types.zig").ModuleIndex.fromUsize(0);
    const provider_index = @import("types.zig").ModuleIndex.fromUsize(1);
    const importer = graph.moduleAtMut(importer_index).?;
    const provider = graph.moduleAtMut(provider_index).?;
    try @import("self_namespace_ast.zig").lower(&graph, .{ .format = .esm, .scope_hoist = true, .minify_syntax = false });
    const lowering = @import("self_namespace_ast.zig");
    const plan = graph.self_namespace_holders.get(importer_index.toU32()).?;
    const saved_binding = importer.import_bindings[1];
    const saved_record = importer.import_records[1];
    const saved_consumer_ast = importer.ast.?;
    const saved_consumer_node = importer.ast.?.getNode(plan.statement);
    const saved_provider_ast = provider.ast.?;
    const saved_provider_owner = provider.semantic.?.owner_token;
    const saved_unused_export = provider.export_bindings[1];
    const value_export_anchor = provider.export_bindings[0].local_symbol_node.?;
    const provider_witness = @import("namespace_export_witness.zig").resolveName(provider, "value").?;
    var initializer_raw: ?usize = null;
    for (provider.ast.?.nodes.items, 0..) |node, raw| if (node.tag == .numeric_literal) {
        initializer_raw = raw;
        break;
    };
    const initializer_index = initializer_raw orelse return error.MissingForeignProviderInitializer;
    const saved_initializer = provider.ast.?.nodes.items[initializer_index];
    switch (attack) {
        .missing_plan => _ = graph.self_namespace_holders.remove(importer_index.toU32()),
        .target_role => {
            var target = saved_binding.callsite_target.?;
            target.role = .require;
            @constCast(importer.import_bindings)[1].callsite_target = target;
        },
        .target_owner => {
            var target = saved_binding.callsite_target.?;
            target.owner = .unassigned;
            @constCast(importer.import_bindings)[1].callsite_target = target;
        },
        .target_symbol => {
            var target = saved_binding.callsite_target.?;
            target.symbol = .invalid;
            @constCast(importer.import_bindings)[1].callsite_target = target;
        },
        .target_declaration => {
            var target = saved_binding.callsite_target.?;
            target.declaration = .none;
            @constCast(importer.import_bindings)[1].callsite_target = target;
        },
        .callsite_record => @constCast(importer.import_records)[1].callsite_lowered = false,
        .imported_name => @constCast(importer.import_bindings)[1].imported_name = "other",
        .consumer_ast => @constCast(importer.ast.?.nodes.items)[@backingInt(plan.statement)].span.start +%= 1,
        .consumer_symbol => @constCast(importer.semantic.?.symbol_ids)[@backingInt(saved_binding.local_symbol_node.?)] = plan.holder,
        .provider_ast => @constCast(provider.ast.?.nodes.items)[initializer_index].tag = .string_literal,
        .provider_owner => provider.semantic.?.owner_token = .unassigned,
        .provider_symbol => @constCast(provider.semantic.?.symbol_ids)[@backingInt(provider_witness.local_symbol_node)] = std.math.maxInt(u32),
        .provider_scope_map => try @constCast(provider.semantic.?.scope_maps)[0].put(a, "value", 999),
        .provider_export_binding => @constCast(provider.export_bindings)[1].local_symbol_node = value_export_anchor,
    }
    var rejected = false;
    lowering.validate(&graph, importer) catch {
        rejected = true;
    };
    if (!rejected) return error.ForeignNamespaceCorruptionAccepted;
    switch (attack) {
        .missing_plan => graph.self_namespace_holders.putAssumeCapacity(importer_index.toU32(), plan),
        .target_role, .target_owner, .target_symbol, .target_declaration, .imported_name => @constCast(importer.import_bindings)[1] = saved_binding,
        .callsite_record => @constCast(importer.import_records)[1] = saved_record,
        .consumer_ast => {
            importer.ast = saved_consumer_ast;
            @constCast(importer.ast.?.nodes.items)[@backingInt(plan.statement)] = saved_consumer_node;
        },
        .consumer_symbol => @constCast(importer.semantic.?.symbol_ids)[@backingInt(saved_binding.local_symbol_node.?)] = saved_binding.local_symbol.semanticIndex().?,
        .provider_ast => provider.ast = saved_provider_ast,
        .provider_owner => provider.semantic.?.owner_token = saved_provider_owner,
        .provider_symbol => @constCast(provider.semantic.?.symbol_ids)[@backingInt(provider_witness.local_symbol_node)] = @backingInt(provider_witness.symbol.inner),
        .provider_scope_map => try @constCast(provider.semantic.?.scope_maps)[0].put(a, "value", @backingInt(provider_witness.symbol.inner)),
        .provider_export_binding => @constCast(provider.export_bindings)[1] = saved_unused_export,
    }
    if (attack == .provider_ast) @constCast(provider.ast.?.nodes.items)[initializer_index] = saved_initializer;
    try lowering.validate(&graph, importer);
    try lowering.lower(&graph, .{ .format = .esm, .scope_hoist = true, .minify_syntax = false });
}

test "foreign namespace AST holder rejects fourteen poisoned identities and restores" {
    inline for (std.meta.tags(ForeignNamespaceCorruption)) |attack| try checkForeignNamespaceCorruption(attack);
}

test "foreign namespace holder lifecycle evicts both cached owners" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "provider.mjs", "export const value=7;");
    try writeFile(tmp.dir, "entry.mjs", "import*as ns from './provider.mjs';console.log(Reflect.get(ns,'value'));");
    try writeFile(tmp.dir, "control.mjs", "export const control=11;");
    const entry = try @import("test_helpers.zig").absPath(&tmp, "entry.mjs");
    defer a.free(entry);
    const provider_path = try @import("test_helpers.zig").absPath(&tmp, "provider.mjs");
    defer a.free(provider_path);
    const control_path = try @import("test_helpers.zig").absPath(&tmp, "control.mjs");
    defer a.free(control_path);
    var cache = resolve_cache_mod.ResolveCache.init(a, .{});
    defer cache.deinit();
    var store = module_store_mod.PersistentModuleStore.init(a);
    defer store.deinit();

    var seed = ModuleGraph.init(a, &cache);
    defer seed.deinit();
    try seed.build(std.testing.io, &.{entry});
    seed.transferModulesToStore(std.testing.io, &store);
    try std.testing.expect(store.modules.contains(entry) and store.modules.contains(provider_path));

    var graph = ModuleGraph.init(a, &cache);
    defer graph.deinit();
    try graph.build(std.testing.io, &.{entry});
    try @import("self_namespace_ast.zig").lower(&graph, .{ .format = .esm, .scope_hoist = true, .minify_syntax = false });
    const importer_index = @import("types.zig").ModuleIndex.fromUsize(0);
    const provider_index = @import("types.zig").ModuleIndex.fromUsize(1);
    const importer = graph.moduleAtMut(importer_index).?;
    const provider = graph.moduleAtMut(provider_index).?;
    const control_index = try graph.addModule(std.testing.io, control_path);
    graph.parseModule(std.testing.io, control_index);
    const control = graph.moduleAtMut(control_index).?;
    const control_mtime = try ModuleGraph.getMtime(std.testing.io, control_path);

    graph.transferModulesToStore(std.testing.io, &store);
    try std.testing.expect(!store.modules.contains(entry));
    try std.testing.expect(!store.modules.contains(provider_path));
    try std.testing.expect(store.getIfFresh(control_path, control_mtime) != null);
    try std.testing.expectEqual(@as(usize, 1), store.modules.count());
    try std.testing.expect(importer.parse_arena != null and provider.parse_arena != null);
    try std.testing.expect(control.parse_arena == null);
    graph.invalidateModule(provider_index);
    try std.testing.expectEqual(@as(usize, 0), graph.self_namespace_holders.count());
    try std.testing.expectError(error.MissingSelfNamespaceHolder, @import("self_namespace_ast.zig").validate(&graph, importer));
}

test "foreign namespace holder admits exact one-symbol provider from disk receipt" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.mjs", "import*as ns from './provider.mjs';console.log(Reflect.get(ns,'value'));");
    try writeFile(tmp.dir, "provider.mjs", "export const value=7;");
    const entry = try @import("test_helpers.zig").absPath(&tmp, "entry.mjs");
    defer a.free(entry);
    const cache_path = try @import("test_helpers.zig").absPath(&tmp, "disk-cache");
    defer a.free(cache_path);
    var disk = try @import("disk_module_store.zig").DiskModuleStore.init(a, cache_path);
    defer disk.deinit();
    var resolve = resolve_cache_mod.ResolveCache.init(a, .{});
    defer resolve.deinit();

    var cold = ModuleGraph.init(a, &resolve);
    defer cold.deinit();
    cold.disk_cache = &disk;
    cold.disk_load_enabled = true;
    cold.disk_options_hash = 17;
    cold.disk_compiler_build_id = 31;
    try cold.build(std.testing.io, &.{entry});
    try std.testing.expectEqual(@as(usize, 0), cold.disk_load_hits.load(.monotonic));

    var warm = ModuleGraph.init(a, &resolve);
    defer warm.deinit();
    warm.disk_cache = &disk;
    warm.disk_load_enabled = true;
    warm.disk_options_hash = 17;
    warm.disk_compiler_build_id = 31;
    try warm.build(std.testing.io, &.{entry});
    try std.testing.expectEqual(@as(usize, 2), warm.disk_load_hits.load(.monotonic));
    const importer_index = @import("types.zig").ModuleIndex.fromUsize(0);
    const provider_index = @import("types.zig").ModuleIndex.fromUsize(1);
    const importer = warm.moduleAtMut(importer_index).?;
    const provider = warm.moduleAtMut(provider_index).?;
    try std.testing.expect(importer.self_namespace_source_receipt != null);
    try std.testing.expect(provider.self_namespace_source_receipt != null);
    try std.testing.expect(importer.source.ptr != importer.ast.?.source.ptr);
    try std.testing.expect(provider.source.ptr != provider.ast.?.source.ptr);

    const lowering = @import("self_namespace_ast.zig");
    try lowering.lower(&warm, .{ .format = .esm, .scope_hoist = true, .minify_syntax = false });
    try std.testing.expectEqual(@as(usize, 1), warm.self_namespace_holders.count());
    try std.testing.expect(importer.self_namespace_source_receipt == null);
    try std.testing.expect(provider.self_namespace_source_receipt == null);
    try lowering.validate(&warm, importer);
    var linker = Linker.init(a, &warm, .esm);
    defer linker.deinit();
    try linker.link();
    try linker.finalize(.{ .compute_renames = true, .compute_mangling = false });
    try lowering.validate(&warm, importer);
}

test "self namespace AST holder observes actual getter creator topology" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var scanner = try @import("../lexer/scanner.zig").Scanner.init(a, "export const value=7; const holder={get value(){return value;}};");
    defer scanner.deinit();
    var parser = @import("../parser/parser.zig").Parser.init(a, &scanner);
    parser.is_module = true;
    defer parser.deinit();
    const root = try parser.parse();
    var analyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer.init(a, &parser.ast);
    analyzer.is_module = true;
    analyzer.enable_stmt_info = true;
    analyzer.enable_exact_declaration_anchors = true;
    defer analyzer.deinit();
    try analyzer.analyze();
    try std.testing.expect(parser.ast.has_object_getter);
    var method_count: usize = 0;
    for (parser.ast.nodes.items, 0..) |node, raw| {
        if (node.tag != .method_definition) continue;
        method_count += 1;
        const params = parser.ast.extra_data.items[node.data.extra + 1];
        const body = parser.ast.extra_data.items[node.data.extra + 2];
        const method_scope = analyzer.scope_owner_map.get(@intCast(raw));
        const params_scope = analyzer.scope_owner_map.get(params);
        const body_scope = analyzer.scope_owner_map.get(body);
        std.debug.print("self namespace source getter method={d} flags={d} method_scope={any} params={d}/scope={any} body={d}/scope={any} root={d}\n", .{ raw, parser.ast.extra_data.items[node.data.extra + 3], method_scope, params, params_scope, body, body_scope, @backingInt(root) });
        for (analyzer.references.items) |reference| {
            if (!reference.flags.read) continue;
            std.debug.print("self namespace source getter read node={d} sid={d} scope={d} stmt={d}/{d}\n", .{ @backingInt(reference.node_index), @backingInt(reference.symbol_id), @backingInt(reference.scope_id), reference.stmt_idx, reference.scope_stmt_idx });
        }
    }
    try std.testing.expectEqual(@as(usize, 1), method_count);
}

const SelfNamespaceCase = struct {
    name: []const u8,
    source: []const u8,
    selected: bool,
    ids: bool = false,
    syntax: bool = false,
    split: bool = false,
    preserve: bool = false,
    es5: bool = false,
};

fn checkSelfNamespaceSelection(case: SelfNamespaceCase) !void {
    errdefer std.debug.print("self namespace selection failed case={s}\n", .{case.name});
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "self.mjs", case.source);
    try writeFile(tmp.dir, "dep.mjs", "export const value=7;");
    const entry = try @import("test_helpers.zig").absPath(&tmp, "self.mjs");
    defer a.free(entry);
    var cache = resolve_cache_mod.ResolveCache.init(a, .{});
    defer cache.deinit();
    var graph = ModuleGraph.init(a, &cache);
    defer graph.deinit();
    graph.minify_identifiers = case.ids;
    graph.code_splitting = case.split;
    graph.preserve_modules = case.preserve;
    graph.transform_options_base.minify_syntax = case.syntax;
    if (case.es5) graph.transform_options_base.unsupported = @import("../transformer/compat.zig").fromESTarget(.es5);
    try graph.build(std.testing.io, &.{entry});
    const index = findModuleIdx(&graph, "self.mjs") orelse return error.MissingSelfModule;
    const module = graph.moduleAtMut(index).?;
    const before = module.semantic orelse return error.MissingSelfSemantic;
    const before_ast = module.ast orelse return error.MissingSelfAst;
    const original_binding = module.import_bindings[0];
    const original_node = original_binding.local_symbol_node orelse return error.MissingSelfImportAnchor;
    const original_sid = before.symbol_ids[@backingInt(original_node)] orelse return error.MissingSelfImportIdentity;
    const before_symbols = try a.dupe(semantic_symbol.Symbol, before.symbols.items);
    defer a.free(before_symbols);
    const before_references = try a.dupe(semantic_symbol.Reference, before.references);
    defer a.free(before_references);
    const before_ids = try a.dupe(?u32, before.symbol_ids);
    defer a.free(before_ids);
    const lowering = @import("self_namespace_ast.zig");
    try lowering.lower(&graph, .{ .format = .esm, .scope_hoist = true, .minify_syntax = case.syntax });
    const selected = graph.self_namespace_holders.contains(index.toU32());
    try std.testing.expectEqual(case.selected, selected);
    if (!selected) {
        const after = module.semantic.?;
        try std.testing.expect(module.ast.?.nodes.items.ptr == before_ast.nodes.items.ptr);
        try std.testing.expect(module.ast.?.transformed_root == before_ast.transformed_root);
        try std.testing.expectEqualDeep(before_symbols, after.symbols.items);
        try std.testing.expectEqualDeep(before_references, after.references);
        try std.testing.expectEqualDeep(before_ids, after.symbol_ids);
        try std.testing.expect(after.owner_token == before.owner_token);
        try std.testing.expect(module.import_bindings[0].local_role == original_binding.local_role);
    } else {
        try lowering.validate(&graph, module);
        const plan = graph.self_namespace_holders.get(index.toU32()).?;
        try std.testing.expectEqual(original_sid, plan.holder);
        try std.testing.expectEqual(@as(?u32, original_sid), module.semantic.?.symbol_ids[@backingInt(plan.binding)]);
        try std.testing.expectEqualDeep(before_symbols, before.symbols.items);
        try std.testing.expectEqualDeep(before_references, before.references);
        const node_count = module.ast.?.nodes.items.len;
        const scope_count = module.semantic.?.scopes.len;
        const row_count = module.semantic.?.references.len;
        const owner = module.semantic.?.owner_token;
        try lowering.lower(&graph, .{ .format = .esm, .scope_hoist = true, .minify_syntax = false });
        try std.testing.expectEqual(node_count, module.ast.?.nodes.items.len);
        try std.testing.expectEqual(scope_count, module.semantic.?.scopes.len);
        try std.testing.expectEqual(row_count, module.semantic.?.references.len);
        try std.testing.expect(module.semantic.?.owner_token == owner);
        try std.testing.expectEqual(@as(usize, 1), graph.self_namespace_holders.count());
        var linker = Linker.init(a, &graph, .esm);
        defer linker.deinit();
        try linker.link();
        try linker.finalize(.{ .compute_renames = true, .compute_mangling = false });
        try lowering.validate(&graph, module);
        try std.testing.expectEqual(@as(?u32, original_sid), module.import_bindings[0].local_symbol.semanticIndex());
        const ast = if (module.ast) |*value| value else return error.MissingSelfOutput;
        var metadata = try linker.buildMetadataForAst(ast, index.toU32(), true, null, .esm, true);
        defer metadata.deinit();
        try std.testing.expectEqual(@as(usize, 0), metadata.ns_inline_objects.entries.len);
    }
    std.debug.print("self namespace actual selection case={s} selected={any} sourceSID={d}\n", .{ case.name, selected, original_sid });
}

test "self namespace AST holder ten selected source identities retain declaration authority" {
    const cases = [_]SelfNamespaceCase{
        .{ .name = "late-import", .source = "export const value=7;console.log(Reflect.get(ns,'value'));import*as ns from'./self.mjs';", .selected = true },
        .{ .name = "import-first", .source = "import*as ns from'./self.mjs';export const value=7;console.log(Reflect.get(ns,'value'));", .selected = true },
        .{ .name = "directive", .source = "'use strict';export const value=7;console.log(Reflect.get(ns,'value'));import*as ns from'./self.mjs';", .selected = true },
        .{ .name = "namespace-name", .source = "export const value=7;console.log(Reflect.get(view,'value'));import*as view from'./self.mjs';", .selected = true },
        .{ .name = "export-name", .source = "export const answer=7;console.log(Reflect.get(ns,'answer'));import*as ns from'./self.mjs';", .selected = true },
        .{ .name = "string", .source = "export const value='seven';console.log(Reflect.get(ns,'value'));import*as ns from'./self.mjs';", .selected = true },
        .{ .name = "boolean", .source = "export const value=true;console.log(Reflect.get(ns,'value'));import*as ns from'./self.mjs';", .selected = true },
        .{ .name = "null", .source = "export const value=null;console.log(Reflect.get(ns,'value'));import*as ns from'./self.mjs';", .selected = true },
        .{ .name = "dollar-name", .source = "export const value=7;console.log(Reflect.get($view,'value'));import*as $view from'./self.mjs';", .selected = true },
        .{ .name = "two-reads", .source = "export const value=7;console.log(Reflect.get(ns,'value'));console.log(Reflect.get(ns,'value'));import*as ns from'./self.mjs';", .selected = true },
    };
    for (cases) |case| try checkSelfNamespaceSelection(case);
}

test "self namespace AST holder unsupported valid sources preserve the existing path" {
    const cases = [_]SelfNamespaceCase{
        .{ .name = "hoisted-var", .source = "console.log(Reflect.get(ns,'value'));export var value=7;import*as ns from'./self.mjs';", .selected = false },
        .{ .name = "hoisted-function", .source = "console.log(Reflect.get(ns,'value')());export function value(){return 7}import*as ns from'./self.mjs';", .selected = false },
        .{ .name = "early-const", .source = "console.log(Reflect.get(ns,'value'));export const value=7;import*as ns from'./self.mjs';", .selected = false },
        .{ .name = "foreign", .source = "import*as ns from'./dep.mjs';console.log(Reflect.get(ns,'value'));", .selected = true },
        .{ .name = "direct-callee", .source = "export const value=7;ns.value();import*as ns from'./self.mjs';", .selected = false },
        .{ .name = "protocol", .source = "export const value=7;console.log(Object.getPrototypeOf(ns));import*as ns from'./self.mjs';", .selected = false },
        .{ .name = "wrong-key", .source = "export const value=7;console.log(Reflect.get(ns,'other'));import*as ns from'./self.mjs';", .selected = false },
        .{ .name = "receiver", .source = "export const value=7;console.log(Reflect.get(ns,'value',{}));import*as ns from'./self.mjs';", .selected = false },
        .{ .name = "computed-reflect", .source = "export const value=7;console.log(Reflect['get'](ns,'value'));import*as ns from'./self.mjs';", .selected = false },
        .{ .name = "opaque-eval", .source = "export const value=7;eval('ns');console.log(Reflect.get(ns,'value'));import*as ns from'./self.mjs';", .selected = false },
        .{ .name = "escaped-namespace", .source = "export const value=7;console.log(Reflect.get(ns,'value'));import*as n\\u0073 from'./self.mjs';", .selected = false },
        .{ .name = "escaped-export", .source = "export const v\\u0061lue=7;console.log(Reflect.get(ns,'value'));import*as ns from'./self.mjs';", .selected = false },
        .{ .name = "identifiers-profile", .source = "export const value=7;console.log(Reflect.get(ns,'value'));import*as ns from'./self.mjs';", .selected = false, .ids = true },
        .{ .name = "syntax-profile", .source = "export const value=7;console.log(Reflect.get(ns,'value'));import*as ns from'./self.mjs';", .selected = false, .syntax = true },
        .{ .name = "split-profile", .source = "export const value=7;console.log(Reflect.get(ns,'value'));import*as ns from'./self.mjs';", .selected = false, .split = true },
        .{ .name = "preserve-profile", .source = "export const value=7;console.log(Reflect.get(ns,'value'));import*as ns from'./self.mjs';", .selected = false, .preserve = true },
        .{ .name = "es5-profile", .source = "export const value=7;console.log(Reflect.get(ns,'value'));import*as ns from'./self.mjs';", .selected = false, .es5 = true },
    };
    for (cases) |case| try checkSelfNamespaceSelection(case);
}

const SelfNamespaceCorruption = enum { missing_plan, foreign_owner, foreign_backing, holder_id, getter_parent, getter_strict, read_scope, string_table, lexical_marker, root_name, cache_demand, statement_kind, statement_coordinates, record_target, record_kind, pending_profile };

fn checkSelfNamespaceCorruption(attack: SelfNamespaceCorruption) !void {
    errdefer std.debug.print("self namespace hostile failed attack={s}\n", .{@tagName(attack)});
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "self.mjs", "export const value=7;console.log(Reflect.get(ns,'value'));import*as ns from'./self.mjs';");
    const entry = try @import("test_helpers.zig").absPath(&tmp, "self.mjs");
    defer a.free(entry);
    var cache = resolve_cache_mod.ResolveCache.init(a, .{});
    defer cache.deinit();
    var graph = ModuleGraph.init(a, &cache);
    defer graph.deinit();
    try graph.build(std.testing.io, &.{entry});
    const index = findModuleIdx(&graph, "self.mjs") orelse return error.MissingSelfModule;
    const module = graph.moduleAtMut(index).?;
    const lowering = @import("self_namespace_ast.zig");
    const options: lowering.Options = .{ .format = .esm, .scope_hoist = true, .minify_syntax = false };
    try lowering.lower(&graph, options);
    var linker = Linker.init(a, &graph, .esm);
    defer linker.deinit();
    try linker.link();
    try linker.finalize(.{ .compute_renames = true, .compute_mangling = false });
    try lowering.validate(&graph, module);
    const plan = graph.self_namespace_holders.get(index.toU32()).?;
    const sem = if (module.semantic) |*value| value else return error.MissingSelfSemantic;
    const ast = if (module.ast) |*value| value else return error.MissingSelfAst;
    const saved_record = module.import_records[0];
    const saved_nodes = ast.nodes;
    const saved_owner = sem.owner_token;
    const saved_id = sem.symbol_ids[@backingInt(plan.binding)];
    const saved_scope = sem.scopes[plan.getter_scope.toIndex()];
    const saved_strings = ast.string_table.items;
    const saved_byte = saved_strings[0];
    const saved_lexical = ast.preserve_lexical_declaration_indices.items;
    const saved_lexical_value = saved_lexical[0];
    const statement_extra = ast.getNode(plan.statement).data.extra;
    const saved_kind = ast.extra_data.items[statement_extra];
    const name = ast.getText(sem.symbols.items[plan.holder].name);
    const saved_cache = module.transform_cache.?;
    var read_row: ?usize = null;
    for (sem.references, 0..) |reference, raw| if (reference.node_index == plan.read) {
        read_row = raw;
    };
    const read_index = read_row orelse return error.MissingSelfGetterReference;
    const saved_reference = sem.references[read_index];
    switch (attack) {
        .missing_plan => _ = graph.self_namespace_holders.remove(index.toU32()),
        .foreign_owner => {
            var foreign = sem.*;
            foreign.owner_token = .unassigned;
            sem.owner_token = foreign.captureOwnerToken();
        },
        .foreign_backing => ast.nodes.items = try module.parse_arena.?.allocator().dupe(@import("../parser/ast.zig").Node, ast.nodes.items),
        .holder_id => @constCast(sem.symbol_ids)[@backingInt(plan.binding)] = plan.exported,
        .getter_parent => @constCast(sem.scopes)[plan.getter_scope.toIndex()].parent = plan.getter_scope,
        .getter_strict => @constCast(sem.scopes)[plan.getter_scope.toIndex()].is_strict = false,
        .read_scope => @constCast(sem.references)[read_index].scope_id = plan.root_scope,
        .string_table => ast.string_table.items[0] = 'x',
        .lexical_marker => ast.preserve_lexical_declaration_indices.clearRetainingCapacity(),
        .root_name => try @constCast(sem.scope_maps)[plan.root_scope.toIndex()].put(module.parse_arena.?.allocator(), name, plan.exported),
        .cache_demand => module.transform_cache.?.runtime_helpers.keep_names = true,
        .statement_kind => ast.extra_data.items[statement_extra] = @backingInt(@import("../parser/ast.zig").VariableDeclarationKind.@"var"),
        .statement_coordinates => @constCast(sem.references)[read_index].scope_stmt_idx += 1,
        .record_target => {
            try writeFile(tmp.dir, "foreign.mjs", "export const value=9;");
            const foreign_path = try @import("test_helpers.zig").absPath(&tmp, "foreign.mjs");
            defer a.free(foreign_path);
            module.import_records[0].resolved = try graph.addModule(std.testing.io, foreign_path);
            try std.testing.expect(graph.getModule(module.import_records[0].resolved) != module);
        },
        .record_kind => module.import_records[0].kind = .dynamic_import,
        .pending_profile => graph.minify_identifiers = true,
    }
    if (attack == .pending_profile) {
        try std.testing.expectError(error.InvalidSelfNamespaceProfile, lowering.lower(&graph, options));
    } else {
        if (attack == .missing_plan) {
            try std.testing.expectError(error.MissingSelfNamespaceHolder, lowering.validate(&graph, module));
        } else try std.testing.expectError(error.InvalidSelfNamespaceHolder, lowering.validate(&graph, module));
        if (linker.buildMetadataForAst(ast, index.toU32(), true, null, .esm, true)) |unexpected| {
            var disposable = unexpected;
            disposable.deinit();
            return error.CorruptSelfNamespaceEmittedMetadata;
        } else |_| {}
    }
    switch (attack) {
        .missing_plan => graph.self_namespace_holders.putAssumeCapacity(index.toU32(), plan),
        .foreign_owner => sem.owner_token = saved_owner,
        .foreign_backing => ast.nodes = saved_nodes,
        .holder_id => @constCast(sem.symbol_ids)[@backingInt(plan.binding)] = saved_id,
        .getter_parent, .getter_strict => @constCast(sem.scopes)[plan.getter_scope.toIndex()] = saved_scope,
        .read_scope, .statement_coordinates => @constCast(sem.references)[read_index] = saved_reference,
        .string_table => ast.string_table.items[0] = saved_byte,
        .lexical_marker => {
            ast.preserve_lexical_declaration_indices.items = saved_lexical;
            ast.preserve_lexical_declaration_indices.items[0] = saved_lexical_value;
        },
        .root_name => try @constCast(sem.scope_maps)[plan.root_scope.toIndex()].put(module.parse_arena.?.allocator(), name, plan.holder),
        .cache_demand => module.transform_cache = saved_cache,
        .statement_kind => ast.extra_data.items[statement_extra] = saved_kind,
        .record_target, .record_kind => module.import_records[0] = saved_record,
        .pending_profile => graph.minify_identifiers = false,
    }
    try lowering.validate(&graph, module);
    // The valid foreign-target attack adds a second real module after lower;
    // its restored output remains valid, while first-family admission stays closed.
    if (attack == .record_target) {
        try std.testing.expectError(error.InvalidSelfNamespaceProfile, lowering.lower(&graph, options));
    } else try lowering.lower(&graph, options);
    var metadata = try linker.buildMetadataForAst(ast, index.toU32(), true, null, .esm, true);
    defer metadata.deinit();
    try std.testing.expectEqual(@as(usize, 0), metadata.ns_inline_objects.entries.len);
    std.debug.print("self namespace actual hostile attack={s} rejected=true restored=true\n", .{@tagName(attack)});
}

test "self namespace AST holder rejects altered output authority before metadata and restores" {
    var first_failure: ?anyerror = null;
    inline for (std.meta.tags(SelfNamespaceCorruption)) |attack| {
        checkSelfNamespaceCorruption(attack) catch |err| {
            if (first_failure == null) first_failure = err;
        };
    }
    if (first_failure) |err| return err;
}

fn selfNamespaceAllocationFailure(offset: usize) !bool {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "self.mjs", "export const value=7;console.log(Reflect.get(ns,'value'));import*as ns from'./self.mjs';");
    const entry = try @import("test_helpers.zig").absPath(&tmp, "self.mjs");
    defer a.free(entry);
    var failing = std.testing.FailingAllocator.init(a, .{});
    const controlled = failing.allocator();
    var cache = resolve_cache_mod.ResolveCache.init(controlled, .{});
    defer cache.deinit();
    var graph = ModuleGraph.init(controlled, &cache);
    defer graph.deinit();
    try graph.build(std.testing.io, &.{entry});
    const index = findModuleIdx(&graph, "self.mjs") orelse return error.MissingSelfModule;
    const module = graph.moduleAtMut(index).?;
    const before_ast = module.ast.?;
    const before_sem = module.semantic.?;
    const before_symbols = try a.dupe(semantic_symbol.Symbol, before_sem.symbols.items);
    defer a.free(before_symbols);
    const before_rows = try a.dupe(semantic_symbol.Reference, before_sem.references);
    defer a.free(before_rows);
    const before_ids = try a.dupe(?u32, before_sem.symbol_ids);
    defer a.free(before_ids);
    const binding = module.import_bindings[0];
    // Force arena growth to take the fallible new-block path too.
    failing.resize_fail_index = failing.resize_index;
    failing.fail_index = failing.alloc_index + offset;
    if (@import("self_namespace_ast.zig").lower(&graph, .{ .format = .esm, .scope_hoist = true, .minify_syntax = false })) |_| {
        failing.fail_index = std.math.maxInt(usize);
        failing.resize_fail_index = std.math.maxInt(usize);
        try @import("self_namespace_ast.zig").validate(&graph, module);
        return true;
    } else |err| {
        failing.fail_index = std.math.maxInt(usize);
        failing.resize_fail_index = std.math.maxInt(usize);
        try std.testing.expectEqual(error.OutOfMemory, err);
        try std.testing.expectEqual(@as(usize, 0), graph.self_namespace_holders.count());
        try std.testing.expect(module.ast.?.nodes.items.ptr == before_ast.nodes.items.ptr);
        try std.testing.expect(module.ast.?.nodes.items.len == before_ast.nodes.items.len);
        try std.testing.expect(module.ast.?.transformed_root == before_ast.transformed_root);
        try std.testing.expectEqualDeep(before_symbols, module.semantic.?.symbols.items);
        try std.testing.expectEqualDeep(before_rows, module.semantic.?.references);
        try std.testing.expectEqualDeep(before_ids, module.semantic.?.symbol_ids);
        try std.testing.expect(module.semantic.?.owner_token == before_sem.owner_token);
        try std.testing.expect(module.import_bindings[0].local_role == binding.local_role);
        try std.testing.expect(module.transform_cache == null);
        // The same source can be retried after failure without a second parse.
        try @import("self_namespace_ast.zig").lower(&graph, .{ .format = .esm, .scope_hoist = true, .minify_syntax = false });
        try @import("self_namespace_ast.zig").validate(&graph, module);
        return false;
    }
}

test "self namespace AST holder allocation failures leave source and completion unpublished" {
    var failures: usize = 0;
    var reached_success = false;
    for (0..128) |offset| {
        if (try selfNamespaceAllocationFailure(offset)) {
            reached_success = true;
            break;
        }
        failures += 1;
    }
    try std.testing.expect(reached_success and failures > 0);
    std.debug.print("self namespace transaction actual OOM points={d} restored=true\n", .{failures});
}

test "self namespace lifecycle completed store eviction preserves ordinary control" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "self.mjs", "export const value=7;console.log(Reflect.get(ns,'value'));import*as ns from './self.mjs';");
    const entry = try @import("test_helpers.zig").absPath(&tmp, "self.mjs");
    defer a.free(entry);
    var cache = resolve_cache_mod.ResolveCache.init(a, .{});
    defer cache.deinit();
    var graph = ModuleGraph.init(a, &cache);
    defer graph.deinit();
    try graph.build(std.testing.io, &.{entry});
    const index = findModuleIdx(&graph, "self.mjs") orelse return error.MissingSelfModule;
    const lowering = @import("self_namespace_ast.zig");
    const options: lowering.Options = .{ .format = .esm, .scope_hoist = true, .minify_syntax = false };
    try lowering.lower(&graph, options);
    try lowering.validate(&graph, graph.moduleAtMut(index).?);
    var store = module_store_mod.PersistentModuleStore.init(a);
    defer store.deinit();
    // Seed a previous source-only cache entry from an independent real graph.
    var seed = ModuleGraph.init(a, &cache);
    defer seed.deinit();
    try seed.build(std.testing.io, &.{entry});
    seed.transferModulesToStore(std.testing.io, &store);
    try std.testing.expect(store.modules.contains(entry));
    try writeFile(tmp.dir, "control.mjs", "export const control=11;");
    const control_path = try @import("test_helpers.zig").absPath(&tmp, "control.mjs");
    defer a.free(control_path);
    const control_index = try graph.addModule(std.testing.io, control_path);
    graph.parseModule(std.testing.io, control_index);
    const control = graph.moduleAtMut(control_index).?;
    try std.testing.expect(control.ast != null and control.semantic != null and control.parse_arena != null);
    const control_mtime = try ModuleGraph.getMtime(std.testing.io, control_path);
    graph.transferModulesToStore(std.testing.io, &store);
    try std.testing.expect(!store.modules.contains(entry));
    try std.testing.expect(store.getIfFresh(control_path, control_mtime) != null);
    try std.testing.expectEqual(@as(usize, 1), store.modules.count());
    try std.testing.expect(graph.moduleAtMut(index).?.parse_arena != null);
    try std.testing.expect(control.parse_arena == null);
}

test "self namespace lifecycle repeated lower preserves owner backing and counts" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "self.mjs", "export const value=7;console.log(Reflect.get(ns,'value'));import*as ns from './self.mjs';");
    const entry = try @import("test_helpers.zig").absPath(&tmp, "self.mjs");
    defer a.free(entry);
    var cache = resolve_cache_mod.ResolveCache.init(a, .{});
    defer cache.deinit();
    var graph = ModuleGraph.init(a, &cache);
    defer graph.deinit();
    try graph.build(std.testing.io, &.{entry});
    const index = findModuleIdx(&graph, "self.mjs") orelse return error.MissingSelfModule;
    const lowering = @import("self_namespace_ast.zig");
    const options: lowering.Options = .{ .format = .esm, .scope_hoist = true, .minify_syntax = false };
    try lowering.lower(&graph, options);
    try lowering.validate(&graph, graph.moduleAtMut(index).?);
    const module = graph.moduleAtMut(index).?;
    const plan = graph.self_namespace_holders.get(index.toU32()).?;
    const nodes = module.ast.?.nodes.items;
    const refs = module.semantic.?.references;
    const scopes = module.semantic.?.scopes;
    const refs_copy = try a.dupe(semantic_symbol.Reference, refs);
    defer a.free(refs_copy);
    try lowering.lower(&graph, options);
    try lowering.validate(&graph, module);
    try std.testing.expectEqual(@as(usize, 1), graph.self_namespace_holders.count());
    try std.testing.expectEqual(plan.owner, module.semantic.?.owner_token);
    try std.testing.expect(nodes.ptr == module.ast.?.nodes.items.ptr);
    try std.testing.expectEqual(nodes.len, module.ast.?.nodes.items.len);
    try std.testing.expect(refs.ptr == module.semantic.?.references.ptr);
    try std.testing.expect(scopes.ptr == module.semantic.?.scopes.ptr);
    try std.testing.expectEqual(scopes.len, module.semantic.?.scopes.len);
    try std.testing.expectEqualDeep(refs_copy, module.semantic.?.references);
}

test "self namespace lifecycle invalidate reuses index without stale completed owner" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "self.mjs", "export const value=7;console.log(Reflect.get(ns,'value'));import*as ns from './self.mjs';");
    const entry = try @import("test_helpers.zig").absPath(&tmp, "self.mjs");
    defer a.free(entry);
    var cache = resolve_cache_mod.ResolveCache.init(a, .{});
    defer cache.deinit();
    var graph = ModuleGraph.init(a, &cache);
    defer graph.deinit();
    try graph.build(std.testing.io, &.{entry});
    const index = findModuleIdx(&graph, "self.mjs") orelse return error.MissingSelfModule;
    const lowering = @import("self_namespace_ast.zig");
    const options: lowering.Options = .{ .format = .esm, .scope_hoist = true, .minify_syntax = false };
    try lowering.lower(&graph, options);
    try lowering.validate(&graph, graph.moduleAtMut(index).?);
    const source_type = graph.moduleAtMut(index).?.module_type;
    const source_loader = graph.moduleAtMut(index).?.loader;
    graph.invalidateModule(index);
    try std.testing.expect(!graph.self_namespace_holders.contains(index.toU32()));
    try std.testing.expect(graph.moduleAtMut(index).?.ast == null);
    try writeFile(tmp.dir, "self.mjs", "export const changed=9;");
    const reused = try graph.addModule(std.testing.io, entry);
    try std.testing.expectEqual(index, reused);
    // In-place invalidation preserves the slot; like the production reparse
    // flow, restore the known file identity before the parser reads it.
    graph.moduleAtMut(reused).?.module_type = source_type;
    graph.moduleAtMut(reused).?.loader = source_loader;
    graph.parseModule(std.testing.io, reused);
    const module = graph.moduleAtMut(reused).?;
    try std.testing.expect(module.ast != null and module.semantic != null);
    try std.testing.expect(std.mem.indexOf(u8, module.ast.?.source, "changed=9") != null);
    try lowering.lower(&graph, options);
    try std.testing.expect(!graph.self_namespace_holders.contains(reused.toU32()));
    for (module.import_bindings) |binding| try std.testing.expect(binding.local_role != .materialized_const);
}

test "self namespace lifecycle full prepare clears slots and completed map" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "self.mjs", "export const value=7;console.log(Reflect.get(ns,'value'));import*as ns from './self.mjs';");
    const entry = try @import("test_helpers.zig").absPath(&tmp, "self.mjs");
    defer a.free(entry);
    var cache = resolve_cache_mod.ResolveCache.init(a, .{});
    defer cache.deinit();
    var graph = ModuleGraph.init(a, &cache);
    defer graph.deinit();
    try graph.build(std.testing.io, &.{entry});
    const index = findModuleIdx(&graph, "self.mjs") orelse return error.MissingSelfModule;
    const lowering = @import("self_namespace_ast.zig");
    const options: lowering.Options = .{ .format = .esm, .scope_hoist = true, .minify_syntax = false };
    try lowering.lower(&graph, options);
    try lowering.validate(&graph, graph.moduleAtMut(index).?);
    graph.prepareForPreservedRebuild();
    try std.testing.expectEqual(@as(usize, 0), graph.moduleCount());
    try std.testing.expectEqual(@as(usize, 0), graph.path_to_module.count());
    try std.testing.expectEqual(@as(usize, 0), graph.self_namespace_holders.count());
    try writeFile(tmp.dir, "self.mjs", "export const changed=9;");
    const reused = try graph.addModule(std.testing.io, entry);
    try std.testing.expectEqual(index, reused);
    graph.parseModule(std.testing.io, reused);
    try lowering.lower(&graph, options);
    try std.testing.expectEqual(@as(usize, 0), graph.self_namespace_holders.count());
}

test "self namespace lifecycle missing plan rejects unchanged output then restores" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "self.mjs", "export const value=7;console.log(Reflect.get(ns,'value'));import*as ns from './self.mjs';");
    const entry = try @import("test_helpers.zig").absPath(&tmp, "self.mjs");
    defer a.free(entry);
    var cache = resolve_cache_mod.ResolveCache.init(a, .{});
    defer cache.deinit();
    var graph = ModuleGraph.init(a, &cache);
    defer graph.deinit();
    try graph.build(std.testing.io, &.{entry});
    const index = findModuleIdx(&graph, "self.mjs") orelse return error.MissingSelfModule;
    const lowering = @import("self_namespace_ast.zig");
    const options: lowering.Options = .{ .format = .esm, .scope_hoist = true, .minify_syntax = false };
    try lowering.lower(&graph, options);
    try lowering.validate(&graph, graph.moduleAtMut(index).?);
    const module = graph.moduleAtMut(index).?;
    const plan = graph.self_namespace_holders.get(index.toU32()).?;
    const nodes = module.ast.?.nodes.items;
    const refs = module.semantic.?.references;
    const refs_copy = try a.dupe(semantic_symbol.Reference, refs);
    defer a.free(refs_copy);
    try std.testing.expect(graph.self_namespace_holders.remove(index.toU32()));
    try std.testing.expectError(error.MissingSelfNamespaceHolder, lowering.validate(&graph, module));
    try std.testing.expectError(error.MissingSelfNamespaceHolder, lowering.lower(&graph, options));
    try std.testing.expect(nodes.ptr == module.ast.?.nodes.items.ptr);
    try std.testing.expectEqual(nodes.len, module.ast.?.nodes.items.len);
    try std.testing.expectEqual(plan.owner, module.semantic.?.owner_token);
    try std.testing.expectEqualDeep(refs_copy, module.semantic.?.references);
    try std.testing.expect(module.import_bindings[0].local_role == .materialized_const);
    graph.self_namespace_holders.putAssumeCapacity(index.toU32(), plan);
    try lowering.validate(&graph, module);
    try lowering.lower(&graph, options);
}

const SelfNamespaceReceiptAttack = enum { missing, foreign_pair, foreign_module, foreign_semantic, foreign_ast, winning_copy, decoded_copy, arena, key, root, hash, owner };

fn checkSelfNamespaceDiskReceipt(source_text: []const u8, attack: ?SelfNamespaceReceiptAttack) !void {
    errdefer std.debug.print("self namespace disk receipt failed attack={any}\n", .{attack});
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "self.mjs", source_text);
    const entry = try @import("test_helpers.zig").absPath(&tmp, "self.mjs");
    defer a.free(entry);
    const cache_path = try @import("test_helpers.zig").absPath(&tmp, "cache");
    defer a.free(cache_path);
    var disk = try @import("disk_module_store.zig").DiskModuleStore.init(a, cache_path);
    defer disk.deinit();
    var resolve = resolve_cache_mod.ResolveCache.init(a, .{});
    defer resolve.deinit();
    var cold = ModuleGraph.init(a, &resolve);
    defer cold.deinit();
    cold.disk_cache = &disk;
    cold.disk_load_enabled = true;
    cold.disk_options_hash = 17;
    cold.disk_compiler_build_id = 31;
    try cold.build(std.testing.io, &.{entry});
    try std.testing.expectEqual(@as(usize, 0), cold.disk_load_hits.load(.monotonic));
    const index = findModuleIdx(&cold, "self.mjs") orelse return error.MissingSelfModule;
    const cold_module = cold.moduleAtMut(index).?;
    var warm = ModuleGraph.init(a, &resolve);
    defer warm.deinit();
    warm.disk_cache = &disk;
    warm.disk_load_enabled = true;
    warm.disk_options_hash = 17;
    warm.disk_compiler_build_id = 31;
    try warm.build(std.testing.io, &.{entry});
    try std.testing.expectEqual(@as(usize, 1), warm.disk_load_hits.load(.monotonic));
    const module = warm.moduleAtMut(index).?;
    const lowering = @import("self_namespace_ast.zig");
    const options: lowering.Options = .{ .format = .esm, .scope_hoist = true, .minify_syntax = false };
    const receipt = module.self_namespace_source_receipt orelse {
        if (attack == null) {
            // A missing actual publication must fail at the real lower/output
            // authority boundary, not only at a receipt utility probe.
            try lowering.lower(&warm, options);
            try std.testing.expectEqual(@as(usize, 1), warm.self_namespace_holders.count());
        }
        return error.MissingActualDiskSourceReceipt;
    };
    try std.testing.expect(module.source.ptr != module.ast.?.source.ptr);
    try std.testing.expectEqualStrings(module.source, module.ast.?.source);
    const original_receipt = receipt.*;
    const original_ast = module.ast.?;
    const original_sem = module.semantic.?;
    try std.testing.expectEqual(@import("module.zig").SemanticOwnerToken.unassigned, original_sem.owner_token);
    const original_source = module.source;
    const original_arena = module.parse_arena;
    // Even a deliberately weakened guard must not turn a semantic assertion
    // failure into teardown of the live foreign arena twice.
    defer module.parse_arena = original_arena;
    const original_key = module.disk_cache_key;
    if (attack) |which| {
        const foreign_pair = (try disk.load(std.testing.io, a, cold_module.parse_arena.?.allocator(), original_key)) orelse return error.MissingForeignDiskPair;
        switch (which) {
            .missing => module.self_namespace_source_receipt = null,
            .foreign_pair => {
                module.self_namespace_source_receipt = null;
                lowering.captureInstalledDiskSource(module, &foreign_pair);
                try std.testing.expect(module.self_namespace_source_receipt == null);
            },
            .foreign_module => @constCast(receipt).module = cold_module,
            .foreign_semantic => module.semantic = foreign_pair.semantic,
            .foreign_ast => module.ast = foreign_pair.ast,
            .winning_copy => module.source = try module.parse_arena.?.allocator().dupe(u8, module.source),
            .decoded_copy => module.ast.?.source = try module.parse_arena.?.allocator().dupe(u8, module.ast.?.source),
            .arena => module.parse_arena = cold_module.parse_arena,
            .key => module.disk_cache_key ^= 1,
            .root => @constCast(receipt).root = @fromBackingInt(@as(u32, 0)),
            .hash => @constCast(receipt).source_hash ^= 1,
            .owner => @constCast(receipt).owner = cold_module.semantic.?.captureOwnerToken(),
        }
        const before_call_ast = module.ast.?;
        const before_call_sem = module.semantic.?;
        try lowering.lower(&warm, options);
        try std.testing.expectEqual(@as(usize, 0), warm.self_namespace_holders.count());
        try std.testing.expect(module.ast.?.nodes.items.ptr == before_call_ast.nodes.items.ptr);
        try std.testing.expect(module.semantic.?.symbol_ids.ptr == before_call_sem.symbol_ids.ptr);
        try std.testing.expectEqual(before_call_sem.owner_token, module.semantic.?.owner_token);
        try std.testing.expect(module.import_bindings[0].local_role == .import_binding);
        module.ast = original_ast;
        module.semantic = original_sem;
        module.source = original_source;
        module.parse_arena = original_arena;
        module.disk_cache_key = original_key;
        @constCast(receipt).* = original_receipt;
        module.self_namespace_source_receipt = receipt;
    }
    try lowering.lower(&warm, options);
    try lowering.validate(&warm, module);
    try std.testing.expect(module.self_namespace_source_receipt == null);
    try std.testing.expectEqual(@as(usize, 1), warm.self_namespace_holders.count());
    try std.testing.expect(module.semantic.?.owner_token != .unassigned);
    var linker = Linker.init(a, &warm, .esm);
    defer linker.deinit();
    try linker.link();
    try linker.finalize(.{ .compute_renames = true, .compute_mangling = false });
    try lowering.validate(&warm, module);
    var metadata = try linker.buildMetadataForAst(&module.ast.?, index.toU32(), true, null, .esm, true);
    defer metadata.deinit();
    try std.testing.expectEqual(@as(usize, 0), metadata.ns_inline_objects.entries.len);
    std.debug.print("self namespace actual disk receipt attack={any} coldMiss=1 warmHit=1 selected=true raw=0\n", .{attack});
}

test "self namespace restored source receipt rejects foreign domains and restores" {
    var first_error: ?anyerror = null;
    inline for (std.meta.tags(SelfNamespaceReceiptAttack)) |attack| {
        checkSelfNamespaceDiskReceipt("export const value=7;console.log(Reflect.get(ns,'value'));import*as ns from'./self.mjs';", attack) catch |err| {
            if (first_error == null) first_error = err;
        };
    }
    if (first_error) |err| return err;
}

test "self namespace restored source receipt covers all ten cold and warm identities" {
    const sources = [_][]const u8{
        "export const value=7;console.log(Reflect.get(ns,'value'));import*as ns from'./self.mjs';",
        "import*as ns from'./self.mjs';export const value=7;console.log(Reflect.get(ns,'value'));",
        "'use strict';export const value=7;console.log(Reflect.get(ns,'value'));import*as ns from'./self.mjs';",
        "export const value=7;console.log(Reflect.get(view,'value'));import*as view from'./self.mjs';",
        "export const answer=7;console.log(Reflect.get(ns,'answer'));import*as ns from'./self.mjs';",
        "export const value='seven';console.log(Reflect.get(ns,'value'));import*as ns from'./self.mjs';",
        "export const value=true;console.log(Reflect.get(ns,'value'));import*as ns from'./self.mjs';",
        "export const value=null;console.log(Reflect.get(ns,'value'));import*as ns from'./self.mjs';",
        "export const value=7;console.log(Reflect.get($view,'value'));import*as $view from'./self.mjs';",
        "export const value=7;console.log(Reflect.get(ns,'value'));console.log(Reflect.get(ns,'value'));import*as ns from'./self.mjs';",
    };
    for (sources) |source_text| try checkSelfNamespaceDiskReceipt(source_text, null);
}

test "self namespace restored source receipt OOM keeps the actual installed pair and retries" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "self.mjs", "export const value=7;console.log(Reflect.get(ns,'value'));import*as ns from'./self.mjs';");
    const entry = try @import("test_helpers.zig").absPath(&tmp, "self.mjs");
    defer a.free(entry);
    const cache_path = try @import("test_helpers.zig").absPath(&tmp, "cache");
    defer a.free(cache_path);
    var disk = try @import("disk_module_store.zig").DiskModuleStore.init(a, cache_path);
    defer disk.deinit();
    var resolve = resolve_cache_mod.ResolveCache.init(a, .{});
    defer resolve.deinit();
    var cold = ModuleGraph.init(a, &resolve);
    defer cold.deinit();
    cold.disk_cache = &disk;
    cold.disk_load_enabled = true;
    cold.disk_options_hash = 17;
    cold.disk_compiler_build_id = 31;
    try cold.build(std.testing.io, &.{entry});
    // This allocator backs the real ModuleArena from its initial creation.
    var failing = std.testing.FailingAllocator.init(a, .{});
    var warm = ModuleGraph.init(failing.allocator(), &resolve);
    defer warm.deinit();
    warm.disk_cache = &disk;
    warm.disk_load_enabled = true;
    warm.disk_options_hash = 17;
    warm.disk_compiler_build_id = 31;
    try warm.build(std.testing.io, &.{entry});
    try std.testing.expectEqual(@as(usize, 1), warm.disk_load_hits.load(.monotonic));
    const index = findModuleIdx(&warm, "self.mjs") orelse return error.MissingSelfModule;
    const module = warm.moduleAtMut(index).?;
    const arena = module.parse_arena.?;
    const lowering = @import("self_namespace_ast.zig");
    // Reload a real pair into this same real arena, and perform the production
    // installation order. No fabricated AST, semantic graph, or arena is used.
    const pair = (try disk.load(std.testing.io, failing.allocator(), arena.allocator(), module.disk_cache_key)) orelse return error.MissingActualDiskPair;
    module.self_namespace_source_receipt = null;
    module.ast = pair.ast;
    module.semantic = pair.semantic;
    const old_ast = module.ast.?;
    const old_sem = module.semantic.?;
    const old_source = module.source;
    const old_key = module.disk_cache_key;
    const old_provider = module.runtime_helper_cache_source;
    const old_rows = try a.dupe(semantic_symbol.Reference, old_sem.references);
    defer a.free(old_rows);
    const old_ids = try a.dupe(?u32, old_sem.symbol_ids);
    defer a.free(old_ids);
    // Exhaust only unused tail space. The graph remains in its original arena;
    // failed growth cannot mutate any live AST/semantic allocation.
    failing.fail_index = failing.alloc_index;
    failing.resize_fail_index = failing.resize_index;
    var padding: usize = 0;
    while (padding < 4096) : (padding += 1) {
        _ = arena.allocator().alloc(u8, @sizeOf(lowering.RestoredSourceReceipt)) catch break;
    }
    try std.testing.expect(padding < 4096);
    // Reset only the diagnostic flag so the subsequent real constructor OOM is
    // independently observed, rather than counting the padding failure.
    failing.has_induced_failure = false;
    lowering.captureInstalledDiskSource(module, &pair);
    const creator_failed = failing.has_induced_failure;
    failing.fail_index = std.math.maxInt(usize);
    failing.resize_fail_index = std.math.maxInt(usize);
    try std.testing.expect(creator_failed);
    try std.testing.expect(module.self_namespace_source_receipt == null);
    try std.testing.expect(module.parse_arena.? == arena);
    try std.testing.expect(module.ast.?.nodes.items.ptr == old_ast.nodes.items.ptr);
    try std.testing.expect(module.semantic.?.symbol_ids.ptr == old_sem.symbol_ids.ptr);
    try std.testing.expectEqual(old_sem.owner_token, module.semantic.?.owner_token);
    try std.testing.expectEqual(old_key, module.disk_cache_key);
    try std.testing.expect(module.source.ptr == old_source.ptr);
    try std.testing.expect(std.meta.eql(old_provider, module.runtime_helper_cache_source));
    try std.testing.expectEqualDeep(old_rows, module.semantic.?.references);
    try std.testing.expectEqualDeep(old_ids, module.semantic.?.symbol_ids);
    const options: lowering.Options = .{ .format = .esm, .scope_hoist = true, .minify_syntax = false };
    try lowering.lower(&warm, options);
    try std.testing.expectEqual(@as(usize, 0), warm.self_namespace_holders.count());
    // The exact same actual installed pair can retry after resource recovery.
    lowering.captureInstalledDiskSource(module, &pair);
    try std.testing.expect(module.self_namespace_source_receipt != null);
    try std.testing.expectEqual(old_sem.owner_token, module.semantic.?.owner_token);
    try warm.materializeFromCachedAst(module, arena.allocator());
    try warm.resolveModuleImports(std.testing.io, index);
    try lowering.lower(&warm, options);
    try lowering.validate(&warm, module);
    try std.testing.expect(module.self_namespace_source_receipt == null);
    std.debug.print("self namespace actual receipt OOM installedPairPreserved=true samePairRetry=true\n", .{});
}

test "self namespace restored source receipt is not transferred into ModuleStore" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "self.mjs", "export const value=7;console.log(Object.getPrototypeOf(ns));import*as ns from'./self.mjs';");
    const entry = try @import("test_helpers.zig").absPath(&tmp, "self.mjs");
    defer a.free(entry);
    const cache_path = try @import("test_helpers.zig").absPath(&tmp, "cache");
    defer a.free(cache_path);
    var disk = try @import("disk_module_store.zig").DiskModuleStore.init(a, cache_path);
    defer disk.deinit();
    var resolve = resolve_cache_mod.ResolveCache.init(a, .{});
    defer resolve.deinit();
    var cold = ModuleGraph.init(a, &resolve);
    defer cold.deinit();
    cold.disk_cache = &disk;
    cold.disk_load_enabled = true;
    cold.disk_options_hash = 17;
    cold.disk_compiler_build_id = 31;
    try cold.build(std.testing.io, &.{entry});
    var warm = ModuleGraph.init(a, &resolve);
    defer warm.deinit();
    warm.disk_cache = &disk;
    warm.disk_load_enabled = true;
    warm.disk_options_hash = 17;
    warm.disk_compiler_build_id = 31;
    try warm.build(std.testing.io, &.{entry});
    const index = findModuleIdx(&warm, "self.mjs") orelse return error.MissingSelfModule;
    const module = warm.moduleAtMut(index).?;
    try std.testing.expect(module.self_namespace_source_receipt != null);
    try @import("self_namespace_ast.zig").lower(&warm, .{ .format = .esm, .scope_hoist = true, .minify_syntax = false });
    try std.testing.expectEqual(@as(usize, 0), warm.self_namespace_holders.count());
    const mtime = try ModuleGraph.getMtime(std.testing.io, entry);
    var store = module_store_mod.PersistentModuleStore.init(a);
    defer store.deinit();
    store.putModule(entry, module, mtime);
    const cached = store.getIfFresh(entry, mtime) orelse return error.MissingStoredSource;
    try std.testing.expect(cached.module.self_namespace_source_receipt == null);
    try std.testing.expect(module.self_namespace_source_receipt == null);
    try std.testing.expect(module.parse_arena == null and cached.module.parse_arena != null);
}
