//! Code splitting — emitChunks + hash/naming 유틸리티

const std = @import("std");
const types = @import("../types.zig");
const ModuleIndex = types.ModuleIndex;
const ModuleType = types.ModuleType;
const WrapKind = types.WrapKind;
const rt = @import("../runtime_helpers.zig");
const chunk_mod = @import("../chunk.zig");
const ChunkGraph = chunk_mod.ChunkGraph;
const Chunk = chunk_mod.Chunk;
const ChunkIndex = types.ChunkIndex;
const Module = @import("../module.zig").Module;
const ModuleGraph = @import("../graph.zig").ModuleGraph;
const ast_mod = @import("../../parser/ast.zig");
const Ast = ast_mod.Ast;
const NodeIndex = ast_mod.NodeIndex;
const Transformer = @import("../../transformer/transformer.zig").Transformer;
const RuntimeHelpers = @import("../../transformer/transformer.zig").RuntimeHelpers;
const Codegen = @import("../../codegen/codegen.zig").Codegen;
const CodegenOptions = @import("../../codegen/codegen.zig").CodegenOptions;
const SourceMap = @import("../../codegen/sourcemap.zig");
const Linker = @import("../linker.zig").Linker;
const LinkingMetadata = @import("../linker.zig").LinkingMetadata;
const TreeShaker = @import("../tree_shaker.zig").TreeShaker;
const statement_shaker = @import("../statement_shaker.zig");
const ExportBinding = @import("../binding_scanner.zig").ExportBinding;
const parent = @import("../emitter.zig");
const plugin_mod = @import("../plugin.zig");
const EmitOptions = parent.EmitOptions;
const OutputFile = parent.OutputFile;
const emitChunkRuntimeHelpers = parent.emitChunkRuntimeHelpers;
const emitModule = parent.emitModule;

pub fn emitChunks(
    allocator: std.mem.Allocator,
    modules: []const Module,
    chunk_graph: *const ChunkGraph,
    options: EmitOptions,
    linker: ?*Linker,
) ![]OutputFile {
    // Code splitting은 ESM 출력만 지원 — CJS/IIFE에서는 네이티브 import()가 없음
    if (options.format != .esm) return error.CodeSplittingRequiresESM;

    var outputs: std.ArrayList(OutputFile) = .empty;
    errdefer {
        for (outputs.items) |o| {
            allocator.free(o.contents);
            allocator.free(o.path);
        }
        outputs.deinit(allocator);
    }

    // 청크를 exec_order 순으로 정렬하여 결정론적 출력 순서 보장.
    // 엔트리 청크가 먼저, 공통 청크가 나중에 오도록 정렬한다.
    const sorted_indices = try allocator.alloc(usize, chunk_graph.chunkCount());
    defer allocator.free(sorted_indices);
    for (sorted_indices, 0..) |*idx, i| idx.* = i;

    const SortCtx = struct {
        chunks: []const Chunk,
        fn lessThan(ctx: @This(), a: usize, b: usize) bool {
            const ca = ctx.chunks[a];
            const cb = ctx.chunks[b];
            // 엔트리 청크 우선
            const a_is_entry: u1 = if (ca.isEntryPoint()) 0 else 1;
            const b_is_entry: u1 = if (cb.isEntryPoint()) 0 else 1;
            if (a_is_entry != b_is_entry) return a_is_entry < b_is_entry;
            // 같은 종류 내에서는 exec_order 순
            return ca.exec_order < cb.exec_order;
        }
    };
    std.mem.sort(usize, sorted_indices, SortCtx{ .chunks = chunk_graph.chunks.items }, SortCtx.lessThan);

    for (sorted_indices) |ci| {
        const chunk = &chunk_graph.chunks.items[ci];

        var chunk_output: std.ArrayList(u8) = .empty;
        errdefer chunk_output.deinit(allocator);

        // 출력 확장자 (cross-chunk import 경로 + 파일명에 공용)
        const ext = options.out_extension_js orelse ".js";

        // banner 삽입 (각 청크 출력 앞)
        if (options.banner_js) |banner| {
            try chunk_output.appendSlice(allocator, banner);
            try chunk_output.append(allocator, '\n');
        }

        // 청크별 런타임 헬퍼 주입
        try emitChunkRuntimeHelpers(&chunk_output, allocator, chunk, modules, options);

        // 크로스 청크 import deconfliction:
        // 여러 청크에서 같은 이름의 심볼을 import할 때 충돌 방지.
        // 1단계: 모든 청크로부터의 import 이름 출현 횟수 카운트
        // 2단계: 중복 이름은 `import { x as x$2 }` 형태로 alias 부여
        var name_total_count: std.StringHashMapUnmanaged(u32) = .empty;
        defer name_total_count.deinit(allocator);
        for (chunk.cross_chunk_imports.items) |dep_chunk_idx| {
            const dep_ci = @intFromEnum(dep_chunk_idx);
            if (chunk.imports_from.get(dep_ci)) |syms| {
                for (syms.items) |name| {
                    const gop = try name_total_count.getOrPut(allocator, name);
                    if (!gop.found_existing) gop.value_ptr.* = 0;
                    gop.value_ptr.* += 1;
                }
            }
        }

        // 2단계: import 문 생성 (중복 이름은 alias 부여)
        var name_seen_count: std.StringHashMapUnmanaged(u32) = .empty;
        defer name_seen_count.deinit(allocator);

        // alias 문자열을 임시 저장 (defer free)
        var alias_strs: std.ArrayList([]const u8) = .empty;
        defer {
            for (alias_strs.items) |s| allocator.free(s);
            alias_strs.deinit(allocator);
        }

        for (chunk.cross_chunk_imports.items) |dep_chunk_idx| {
            const dep_chunk = chunk_graph.getChunk(dep_chunk_idx);
            var dep_buf: [128]u8 = undefined;
            const dep_stem = chunkPlaceholderStem(dep_chunk, &dep_buf, options);
            const dep_ci = @intFromEnum(dep_chunk_idx);

            // import 경로 결정: preserve-modules면 상대 경로, 아니면 "./{stem}{ext}"
            const resolved_path = if (options.preserve_modules) blk: {
                const src_path = chunk.rel_dir orelse "./";
                const dep_path = dep_chunk.rel_dir orelse "./";
                break :blk try computeRelativeImportPath(allocator, src_path, dep_path, ext, options.preserve_modules_root);
            } else try std.fmt.allocPrint(allocator, "./{s}{s}", .{ dep_stem, ext });
            defer allocator.free(resolved_path);

            // imports_from에서 이 청크→dep_chunk로 가져오는 심볼 목록 조회
            const symbols = chunk.imports_from.get(dep_ci);

            if (symbols != null and symbols.?.items.len > 0) {
                // 심볼 수준 import: import { a, b } from './chunk-xxx.js';
                if (!options.minify_whitespace) {
                    try chunk_output.appendSlice(allocator, "import { ");
                } else {
                    try chunk_output.appendSlice(allocator, "import{");
                }
                // 결정론적 출력을 위해 심볼명 정렬
                std.mem.sort([]const u8, symbols.?.items, {}, types.stringLessThan);
                for (symbols.?.items, 0..) |name, si| {
                    const total = name_total_count.get(name) orelse 1;
                    const seen_gop = try name_seen_count.getOrPut(allocator, name);
                    if (!seen_gop.found_existing) seen_gop.value_ptr.* = 0;
                    seen_gop.value_ptr.* += 1;
                    const seen = seen_gop.value_ptr.*;

                    if (total > 1 and seen > 1) {
                        const alias = try std.fmt.allocPrint(allocator, "{s}${d}", .{ name, seen });
                        try alias_strs.append(allocator, alias);
                        try chunk_output.appendSlice(allocator, name);
                        try chunk_output.appendSlice(allocator, " as ");
                        try chunk_output.appendSlice(allocator, alias);
                    } else {
                        try chunk_output.appendSlice(allocator, name);
                    }
                    if (si + 1 < symbols.?.items.len) {
                        if (!options.minify_whitespace) {
                            try chunk_output.appendSlice(allocator, ", ");
                        } else {
                            try chunk_output.append(allocator, ',');
                        }
                    }
                }
                if (!options.minify_whitespace) {
                    try chunk_output.appendSlice(allocator, " } from \"");
                    try chunk_output.appendSlice(allocator, resolved_path);
                    try chunk_output.appendSlice(allocator, "\";\n");
                } else {
                    try chunk_output.appendSlice(allocator, "}from\"");
                    try chunk_output.appendSlice(allocator, resolved_path);
                    try chunk_output.appendSlice(allocator, "\";");
                }
            } else {
                // 심볼 정보 없음 → side-effect import (실행 순서 보장용)
                if (!options.minify_whitespace) {
                    try chunk_output.appendSlice(allocator, "import \"");
                    try chunk_output.appendSlice(allocator, resolved_path);
                    try chunk_output.appendSlice(allocator, "\";\n");
                } else {
                    try chunk_output.appendSlice(allocator, "import\"");
                    try chunk_output.appendSlice(allocator, resolved_path);
                    try chunk_output.appendSlice(allocator, "\";");
                }
            }
        }

        // 청크 내 모듈을 exec_index 순으로 정렬
        const sorted_mods = try allocator.alloc(ModuleIndex, chunk.modules.items.len);
        defer allocator.free(sorted_mods);
        @memcpy(sorted_mods, chunk.modules.items);

        const ModSortCtx = struct {
            mods: []const Module,
            fn lessThan(ctx: @This(), a: ModuleIndex, b: ModuleIndex) bool {
                const ai = @intFromEnum(a);
                const bi = @intFromEnum(b);
                const a_exec = if (ai < ctx.mods.len) ctx.mods[ai].exec_index else std.math.maxInt(u32);
                const b_exec = if (bi < ctx.mods.len) ctx.mods[bi].exec_index else std.math.maxInt(u32);
                return a_exec < b_exec;
            }
        };
        std.mem.sort(ModuleIndex, sorted_mods, ModSortCtx{ .mods = modules }, ModSortCtx.lessThan);

        // cross-chunk import 이름 수집 — 점유 이름으로 등록하여 로컬과 충돌 방지.
        // alias가 부여된 이름(x$2 등)도 점유 이름에 포함하여 로컬 변수와의 충돌 방지.
        var occupied: std.ArrayList([]const u8) = .empty;
        defer occupied.deinit(allocator);
        {
            var ifit = chunk.imports_from.iterator();
            while (ifit.next()) |if_entry| {
                for (if_entry.value_ptr.items) |name| {
                    try occupied.append(allocator, name);
                }
            }
            // deconfliction alias 이름도 점유 목록에 추가
            for (alias_strs.items) |alias| {
                try occupied.append(allocator, alias);
            }
        }

        // per-chunk 리네임 계산: 각 청크는 독립된 네임스페이스이므로
        // 청크 내 모듈들만 대상으로 이름 충돌을 감지한다.
        if (linker) |l| {
            try l.computeRenamesForModules(sorted_mods, occupied.items);
        }

        // 엔트리 모듈 인덱스 (final exports용)
        const entry_mod_idx: ?u32 = switch (chunk.kind) {
            .entry_point => |info| @intFromEnum(info.module),
            .common => null,
        };

        for (sorted_mods) |mod_idx| {
            const mi = @intFromEnum(mod_idx);
            if (mi >= modules.len) continue;
            const m = &modules[mi];

            const is_entry = if (entry_mod_idx) |ei| mi == ei else false;
            const raw_code = try emitModule(allocator, m, options, linker, is_entry, null, null, null, null, null) orelse continue;
            defer allocator.free(raw_code);

            // 동적 import 경로 리라이트: import('./page') → import('./page.js')
            const code = try rewriteDynamicImports(allocator, raw_code, m, chunk_graph, options.public_path, ext, options);
            defer allocator.free(code);

            if (!options.minify_whitespace) {
                try chunk_output.appendSlice(allocator, "// --- ");
                try chunk_output.appendSlice(allocator, std.fs.path.basename(m.path));
                try chunk_output.appendSlice(allocator, " ---\n");
            }
            try chunk_output.appendSlice(allocator, code);
            if (!options.minify_whitespace) {
                try chunk_output.append(allocator, '\n');
            }
        }

        // 크로스 청크 export: exports_to에 심볼이 있으면 export 문 생성.
        // 다른 청크가 이 청크에서 심볼을 가져가는 경우에만 출력.
        // preserve-modules에서는 모듈 자체의 export가 유지되므로 cross-chunk export 불필요.
        // linker가 심볼을 rename한 경우 export { local_name as export_name } 형태로 출력.
        if (chunk.exports_to.count() > 0 and !options.preserve_modules) {
            // 결정론적 출력을 위해 이름을 정렬
            var export_names: std.ArrayList([]const u8) = .empty;
            defer export_names.deinit(allocator);
            var eit = chunk.exports_to.iterator();
            while (eit.next()) |entry| {
                try export_names.append(allocator, entry.key_ptr.*);
            }
            std.mem.sort([]const u8, export_names.items, {}, types.stringLessThan);

            if (!options.minify_whitespace) {
                try chunk_output.appendSlice(allocator, "export { ");
            } else {
                try chunk_output.appendSlice(allocator, "export{");
            }
            for (export_names.items, 0..) |name, ni| {
                // export_name의 원본 심볼이 이 청크에서 rename되었는지 확인.
                // rename된 경우: export { local_name as export_name }
                // rename 안 된 경우: export { export_name }
                const local_name = if (linker) |l| blk: {
                    // exports_to의 이름은 canonical export name.
                    // 이 이름을 선언한 모듈을 찾아 linker의 canonical_names를 조회한다.
                    var found_local: ?[]const u8 = null;
                    for (sorted_mods) |mod_idx| {
                        const mi = @intFromEnum(mod_idx);
                        if (mi >= modules.len) continue;
                        if (l.getCanonicalName(@intCast(mi), name)) |renamed| {
                            found_local = renamed;
                            break;
                        }
                        // export의 local_name이 다를 수 있으므로 export_map도 확인
                        if (l.getExportLocalName(@intCast(mi), name)) |local| {
                            if (l.getCanonicalName(@intCast(mi), local)) |renamed| {
                                found_local = renamed;
                                break;
                            }
                        }
                    }
                    break :blk found_local orelse name;
                } else name;

                try chunk_output.appendSlice(allocator, local_name);
                // local_name과 export_name이 다르면 as 절 추가
                if (!std.mem.eql(u8, local_name, name)) {
                    try chunk_output.appendSlice(allocator, " as ");
                    try chunk_output.appendSlice(allocator, name);
                }
                if (ni + 1 < export_names.items.len) {
                    if (!options.minify_whitespace) {
                        try chunk_output.appendSlice(allocator, ", ");
                    } else {
                        try chunk_output.append(allocator, ',');
                    }
                }
            }
            if (!options.minify_whitespace) {
                try chunk_output.appendSlice(allocator, " };\n");
            } else {
                try chunk_output.appendSlice(allocator, "};");
            }
        }

        // Plugin: renderChunk 훅 — 청크 완성 후, footer 전
        if (options.plugins.len > 0) {
            const runner = plugin_mod.PluginRunner.init(options.plugins);
            var rc_stem_buf: [128]u8 = undefined;
            const rc_chunk_name = chunkPlaceholderStem(chunk, &rc_stem_buf, options);
            const chunk_rc_result = runner.runRenderChunk(chunk_output.items, rc_chunk_name, allocator) catch |err| switch (err) {
                error.PluginFailed => null,
                error.OutOfMemory => return error.OutOfMemory,
            };
            if (chunk_rc_result) |result| {
                chunk_output.clearRetainingCapacity();
                try chunk_output.appendSlice(allocator, result);
                allocator.free(result);
            }
        }

        // footer 삽입 (각 청크 출력 뒤)
        if (options.footer_js) |footer| {
            try chunk_output.appendSlice(allocator, footer);
            try chunk_output.append(allocator, '\n');
        }

        // 출력 파일명 생성
        const filename = if (options.preserve_modules and chunk.rel_dir != null)
            // preserve-modules: 원본 경로에서 root를 제거한 상대 경로 사용
            try computePreserveModulesPath(allocator, chunk.rel_dir.?, ext, options.preserve_modules_root)
        else blk: {
            // 일반 code splitting: "{stem}{ext}" (placeholder hash 포함, 나중에 치환)
            var stem_buf: [128]u8 = undefined;
            const stem = chunkPlaceholderStem(chunk, &stem_buf, options);
            break :blk try std.fmt.allocPrint(allocator, "{s}{s}", .{ stem, ext });
        };
        errdefer allocator.free(filename);

        try outputs.append(allocator, .{
            .path = filename,
            .contents = try chunk_output.toOwnedSlice(allocator),
        });
    }

    // 2패스: content hash 계산 및 placeholder 치환.
    // 각 청크의 content에서 placeholder를 찾아 content hash로 교체한다.
    // esbuild도 동일한 2패스 접근을 사용 (placeholder → content hash).
    try resolveContentHashes(allocator, outputs.items, sorted_indices, chunk_graph);

    return outputs.toOwnedSlice(allocator);
}

/// 동적 import 경로를 청크 파일명으로 리라이트한다.
///
/// code splitting 시 `import('./page')` → `import('./page.js')` 변환.
/// 모듈의 import_records에서 dynamic_import 레코드를 찾아,
/// resolve된 대상 모듈이 속한 청크의 파일명으로 specifier를 교체한다.
///
/// 반환값은 항상 allocator 소유 — 리라이트 여부와 무관하게 caller가 free해야 한다.
fn rewriteDynamicImports(
    allocator: std.mem.Allocator,
    code: []const u8,
    module: *const Module,
    chunk_graph: *const ChunkGraph,
    public_path: []const u8,
    out_ext: []const u8,
    emit_options: EmitOptions,
) ![]const u8 {
    // dynamic import가 없으면 그대로 복사해서 반환
    if (module.import_records.len == 0) {
        return try allocator.dupe(u8, code);
    }

    // 리라이트할 레코드가 있는지 먼저 확인 (불필요한 할당 방지)
    var has_dynamic = false;
    for (module.import_records) |rec| {
        if (rec.kind == .dynamic_import and rec.resolved != .none) {
            const target_chunk = chunk_graph.getModuleChunk(rec.resolved);
            if (target_chunk != .none) {
                has_dynamic = true;
                break;
            }
        }
    }
    if (!has_dynamic) {
        return try allocator.dupe(u8, code);
    }

    // 리라이트 수행: 각 dynamic import specifier를 청크 파일명으로 교체.
    // import_records를 순회하면서 코드 내의 specifier 문자열을 찾아 교체한다.
    // codegen이 specifier를 원본 그대로 출력하므로 정확한 문자열 매칭이 가능.
    var result = try allocator.dupe(u8, code);
    errdefer allocator.free(result);

    for (module.import_records) |rec| {
        if (rec.kind != .dynamic_import) continue;
        if (rec.resolved == .none) continue;

        const target_chunk_idx = chunk_graph.getModuleChunk(rec.resolved);
        if (target_chunk_idx == .none) continue;

        const target_chunk = chunk_graph.getChunk(target_chunk_idx);

        // 청크 파일명 생성: public_path가 있으면 "{public_path}{stem}{ext}", 없으면 "./{stem}{ext}"
        var stem_buf: [128]u8 = undefined;
        const stem = chunkPlaceholderStem(target_chunk, &stem_buf, emit_options);
        const replacement = if (public_path.len > 0)
            try std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ public_path, stem, out_ext })
        else
            try std.fmt.allocPrint(allocator, "./{s}{s}", .{ stem, out_ext });
        defer allocator.free(replacement);

        // 코드에서 원본 specifier를 찾아 교체
        if (std.mem.indexOf(u8, result, rec.specifier)) |pos| {
            const new_result = try std.mem.concat(allocator, u8, &.{
                result[0..pos],
                replacement,
                result[pos + rec.specifier.len ..],
            });
            allocator.free(result);
            result = new_result;
        }
    }

    return result;
}

const PlaceholderInfo = struct {
    placeholder: [HASH_PLACEHOLDER_PREFIX.len + HASH_PLACEHOLDER_LEN]u8,
    real_hash: [HASH_PLACEHOLDER_LEN]u8,
};

/// content hash 계산 + placeholder 치환 (2패스).
/// 모든 청크의 출력이 완성된 후 호출.
/// 각 청크의 placeholder hash를 content hash로 교체한다.
fn resolveContentHashes(
    allocator: std.mem.Allocator,
    outputs: []OutputFile,
    sorted_indices: []const usize,
    chunk_graph: *const ChunkGraph,
) !void {
    if (outputs.len == 0) return;

    // 1단계: 각 청크의 placeholder hash와 content hash를 계산
    var infos = try allocator.alloc(PlaceholderInfo, outputs.len);
    defer allocator.free(infos);

    for (sorted_indices, 0..) |ci, out_idx| {
        if (out_idx >= outputs.len) break;
        const chunk = &chunk_graph.chunks.items[ci];

        buildPlaceholder(chunk, &infos[out_idx].placeholder);

        // content hash 계산
        contentHash(outputs[out_idx].contents, &infos[out_idx].real_hash);
    }

    // 2단계: 모든 출력에서 모든 placeholder를 content hash로 단일패스 치환.
    // O(N*M) → O(M) (M=content 길이, N=청크 수).
    const ph_total = HASH_PLACEHOLDER_PREFIX.len + HASH_PLACEHOLDER_LEN;
    for (outputs) |*out| {
        // contents: 모든 placeholder를 한 번의 스캔으로 치환
        const new_contents = try replaceAllPlaceholders(allocator, out.contents, infos, ph_total);
        allocator.free(out.contents);
        out.contents = new_contents;

        // path도 동일하게 치환
        const new_path = try replaceAllPlaceholders(allocator, out.path, infos, ph_total);
        allocator.free(out.path);
        out.path = new_path;
    }
}

/// placeholder 해시 길이 (8자리 hex).
const HASH_PLACEHOLDER_LEN = 8;
/// placeholder 구분 문자열. 최종 출력에서 content hash로 치환된다.
/// 다른 코드에서 절대 등장하지 않을 문자열을 사용.
const HASH_PLACEHOLDER_PREFIX = "\x00ZH";

/// 청크의 인덱스 해시로 placeholder 바이트를 생성한다.
/// chunkPlaceholderStem과 resolveContentHashes에서 공용.
fn buildPlaceholder(chunk: *const Chunk, ph: *[HASH_PLACEHOLDER_PREFIX.len + HASH_PLACEHOLDER_LEN]u8) void {
    @memcpy(ph[0..HASH_PLACEHOLDER_PREFIX.len], HASH_PLACEHOLDER_PREFIX);
    const idx_hash = chunkIndexHash(chunk);
    _ = std.fmt.bufPrint(ph[HASH_PLACEHOLDER_PREFIX.len..], "{x:0>8}", .{@as(u32, @truncate(idx_hash))}) catch unreachable;
}

/// 청크의 placeholder stem을 반환한다 (확장자 없음).
/// cross-chunk import 등 content가 아직 없는 시점에서 사용.
/// 최종 출력 시 placeholder를 content hash로 치환한다.
fn chunkPlaceholderStem(chunk: *const Chunk, buf: []u8, options: EmitOptions) []const u8 {
    const is_entry = chunk.name != null;
    const base_name = chunk.name orelse "chunk";
    const pattern = if (is_entry) options.entry_names else options.chunk_names;

    var hash_buf: [HASH_PLACEHOLDER_PREFIX.len + HASH_PLACEHOLDER_LEN]u8 = undefined;
    buildPlaceholder(chunk, &hash_buf);

    return applyNamingPattern(buf, pattern, base_name, &hash_buf);
}

/// 모듈 인덱스 기반 해시 (placeholder 식별자용, content hash 아님).
fn chunkIndexHash(chunk: *const Chunk) u64 {
    var hasher = std.hash.Wyhash.init(0);
    var sort_buf: [256]u32 = undefined;
    const mod_count = @min(chunk.modules.items.len, 256);
    for (chunk.modules.items[0..mod_count], sort_buf[0..mod_count]) |mod_idx, *sb| {
        sb.* = @intFromEnum(mod_idx);
    }
    std.mem.sort(u32, sort_buf[0..mod_count], {}, std.sort.asc(u32));
    for (sort_buf[0..mod_count]) |idx| {
        hasher.update(std.mem.asBytes(&idx));
    }
    return hasher.final();
}

/// content hash 계산: 청크의 최종 출력 코드를 Wyhash하여 8자리 hex 반환.
/// placeholder 바이트를 건너뛰어 자기 참조 순환을 방지한다.
pub fn contentHash(content: []const u8, buf: *[HASH_PLACEHOLDER_LEN]u8) void {
    const ph_total = HASH_PLACEHOLDER_PREFIX.len + HASH_PLACEHOLDER_LEN;
    var hasher = std.hash.Wyhash.init(0);
    var i: usize = 0;
    var run_start: usize = 0; // 현재 non-placeholder 구간의 시작
    while (i < content.len) {
        if (i + ph_total <= content.len and
            std.mem.eql(u8, content[i..][0..HASH_PLACEHOLDER_PREFIX.len], HASH_PLACEHOLDER_PREFIX))
        {
            // placeholder 앞까지의 구간을 벌크 해싱
            if (i > run_start) hasher.update(content[run_start..i]);
            i += ph_total;
            run_start = i;
        } else {
            i += 1;
        }
    }
    // 마지막 구간 벌크 해싱
    if (i > run_start) hasher.update(content[run_start..i]);
    const h = hasher.final();
    _ = std.fmt.bufPrint(buf, "{x:0>8}", .{@as(u32, @truncate(h))}) catch unreachable;
}

/// 모든 placeholder를 단일패스로 치환한다.
/// input을 1회 스캔하면서 "\x00ZH" prefix를 만나면 infos에서 매칭하여 real_hash로 치환.
fn replaceAllPlaceholders(allocator: std.mem.Allocator, input: []const u8, infos: []const PlaceholderInfo, ph_total: usize) ![]const u8 {
    // placeholder가 있는지 빠르게 확인 (없으면 복사만)
    if (std.mem.indexOf(u8, input, HASH_PLACEHOLDER_PREFIX) == null) {
        return try allocator.dupe(u8, input);
    }

    // 최대 크기: 원본과 동일 (placeholder가 real_hash보다 길어서 줄어듦)
    var result: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    var run_start: usize = 0;
    while (i + ph_total <= input.len) {
        if (std.mem.eql(u8, input[i..][0..HASH_PLACEHOLDER_PREFIX.len], HASH_PLACEHOLDER_PREFIX)) {
            // run_start..i 까지의 일반 텍스트 복사
            try result.appendSlice(allocator, input[run_start..i]);
            // infos에서 매칭하는 placeholder 찾기
            const ph_bytes = input[i..][0..ph_total];
            var found = false;
            for (infos) |info| {
                if (std.mem.eql(u8, ph_bytes, &info.placeholder)) {
                    try result.appendSlice(allocator, &info.real_hash);
                    found = true;
                    break;
                }
            }
            if (!found) {
                // 매칭 안 되면 원본 유지
                try result.appendSlice(allocator, ph_bytes);
            }
            i += ph_total;
            run_start = i;
        } else {
            i += 1;
        }
    }
    // 나머지 복사
    try result.appendSlice(allocator, input[run_start..]);
    return result.toOwnedSlice(allocator);
}

/// 단일 placeholder를 실제 content hash로 치환한다.
/// 반환값은 allocator 소유.
fn replacePlaceholders(allocator: std.mem.Allocator, input: []const u8, placeholder_hash: []const u8, real_hash: []const u8) ![]const u8 {
    // placeholder_hash는 "\x00ZH" + 8hex, real_hash는 8hex
    // 치환 대상: placeholder_hash 전체 → real_hash
    const ph_len = HASH_PLACEHOLDER_PREFIX.len + HASH_PLACEHOLDER_LEN;
    if (placeholder_hash.len != ph_len) return try allocator.dupe(u8, input);

    // 치환 횟수 카운트
    var count: usize = 0;
    var pos: usize = 0;
    while (pos + ph_len <= input.len) {
        if (std.mem.eql(u8, input[pos..][0..ph_len], placeholder_hash)) {
            count += 1;
            pos += ph_len;
        } else {
            pos += 1;
        }
    }
    if (count == 0) return try allocator.dupe(u8, input);

    // 새 버퍼 할당 + 치환
    const new_len = input.len - count * ph_len + count * real_hash.len;
    const result = try allocator.alloc(u8, new_len);
    var src: usize = 0;
    var dst: usize = 0;
    while (src < input.len) {
        if (src + ph_len <= input.len and
            std.mem.eql(u8, input[src..][0..ph_len], placeholder_hash))
        {
            @memcpy(result[dst..][0..real_hash.len], real_hash);
            dst += real_hash.len;
            src += ph_len;
        } else {
            result[dst] = input[src];
            dst += 1;
            src += 1;
        }
    }
    return result;
}

/// naming pattern을 적용한다.
/// [name] → base_name, [hash] → hash_str 로 치환.
/// buf에 결과를 쓰고 슬라이스를 반환.
pub fn applyNamingPattern(buf: []u8, pattern: []const u8, name: []const u8, hash_str: []const u8) []const u8 {
    var dst: usize = 0;
    var i: usize = 0;
    while (i < pattern.len) {
        if (i + "[name]".len <= pattern.len and std.mem.eql(u8, pattern[i..][0.."[name]".len], "[name]")) {
            const end = @min(dst + name.len, buf.len);
            @memcpy(buf[dst..end], name[0 .. end - dst]);
            dst = end;
            i += "[name]".len;
        } else if (i + "[hash]".len <= pattern.len and std.mem.eql(u8, pattern[i..][0.."[hash]".len], "[hash]")) {
            const end = @min(dst + hash_str.len, buf.len);
            @memcpy(buf[dst..end], hash_str[0 .. end - dst]);
            dst = end;
            i += "[hash]".len;
        } else {
            if (dst < buf.len) {
                buf[dst] = pattern[i];
                dst += 1;
            }
            i += 1;
        }
    }
    return buf[0..dst];
}

/// used_names 사전 계산 결과.
const UsedNamesEntry = struct {
    names: []const []const u8,
    all_used: bool, // true이면 emitModule에 null 전달 (모든 export 사용)
};

/// 모든 모듈의 used_names를 사전 계산한다 (순차).
/// tree-shaking의 used export names 로직을 emit 루프에서 분리.
pub fn computeAllUsedNames(
    allocator: std.mem.Allocator,
    sorted: []*const Module,
    graph: *const ModuleGraph,
    shaker: ?*const TreeShaker,
) ![]UsedNamesEntry {
    var list = try allocator.alloc(UsedNamesEntry, sorted.len);
    for (list) |*e| e.* = .{ .names = &.{}, .all_used = true };

    const s = shaker orelse return list;

    // ── 역방향 룩업 맵 사전 구축 ──
    // target_module_index → 해당 모듈을 import하는 바인딩 목록
    // 기존: 매 모듈의 export마다 모든 importer × 모든 binding을 순회 (O(n × e × i × b))
    // 최적화: 맵을 한 번 구축하여 O(1) 룩업 (O(n × relevant_bindings))
    const RevKind = enum { import_binding_named, import_binding_other, re_export, re_export_all };
    const RevEntry = struct {
        importer_module_index: u32,
        /// import_binding: imported_name / re_export: local_name (= 소스 모듈의 exported_name)
        imported_name: []const u8,
        /// import_binding: local_name (importer 내 바인딩 이름)
        local_name: []const u8,
        /// re_export_all인 경우 importer의 exported_name ("*"이면 unnamed re_export_all)
        exported_name: []const u8,
        kind: RevKind,
    };

    var reverse_map = std.AutoHashMapUnmanaged(u32, std.ArrayListUnmanaged(RevEntry)).empty;
    defer {
        var it = reverse_map.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit(allocator);
        }
        reverse_map.deinit(allocator);
    }

    // 모든 모듈의 import_bindings + export_bindings(re-export)를 순회하여 역방향 맵 구축
    for (graph.modules.items) |*importer| {
        const imp_i: u32 = @intFromEnum(importer.index);

        // export_bindings 중 re_export / re_export_all → 타겟 모듈로 역매핑
        for (importer.export_bindings) |ieb| {
            if (ieb.kind != .re_export_all and ieb.kind != .re_export) continue;
            const rec_idx = ieb.import_record_index orelse continue;
            if (rec_idx >= importer.import_records.len) continue;
            const target = importer.import_records[rec_idx].resolved;
            if (target == .none) continue;
            const target_i: u32 = @intFromEnum(target);
            const gop = try reverse_map.getOrPut(allocator, target_i);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(allocator, .{
                .importer_module_index = imp_i,
                .imported_name = ieb.local_name,
                .local_name = ieb.local_name,
                .exported_name = ieb.exported_name,
                .kind = if (ieb.kind == .re_export_all) .re_export_all else .re_export,
            });
        }

        // import_bindings → 타겟 모듈로 역매핑
        for (importer.import_bindings) |ib| {
            if (ib.import_record_index >= importer.import_records.len) continue;
            const target = importer.import_records[ib.import_record_index].resolved;
            if (target == .none) continue;
            const target_i: u32 = @intFromEnum(target);
            const gop = try reverse_map.getOrPut(allocator, target_i);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(allocator, .{
                .importer_module_index = imp_i,
                .imported_name = ib.imported_name,
                .local_name = ib.local_name,
                .exported_name = "",
                .kind = if (ib.kind == .named) .import_binding_named else .import_binding_other,
            });
        }
    }

    for (sorted, 0..) |m, idx| {
        const mod_idx: u32 = @intFromEnum(m.index);
        // "*" 마킹이 있고 BFS reachable_stmts가 없으면 모든 export 사용
        if (s.isExportUsed(mod_idx, "*") and s.getModuleStmtInfos(mod_idx) == null) {
            list[idx] = .{ .names = &.{}, .all_used = true };
            continue;
        }

        var names_buf: std.ArrayListUnmanaged([]const u8) = .empty;
        var all_used = false;

        // 현재 모듈을 타겟으로 하는 역방향 엔트리 (없으면 빈 슬라이스)
        const rev_entries: []const RevEntry = if (reverse_map.getPtr(mod_idx)) |entries_list|
            entries_list.items
        else
            &.{};

        for (m.export_bindings) |eb| {
            if (eb.kind == .re_export_all) continue;
            if (!s.isExportUsed(mod_idx, eb.exported_name)) continue;

            // 크로스-모듈 BFS 도달성
            if (s.getModuleStmtInfos(mod_idx)) |ts_infos| {
                if (m.semantic) |sem| {
                    if (sem.scope_maps.len > 0) {
                        if (sem.scope_maps[0].get(eb.local_name)) |sym_idx| {
                            if (ts_infos.declaredStmtBySymbol(@intCast(sym_idx))) |stmt_idx| {
                                if (!s.isStmtReachable(mod_idx, stmt_idx)) continue;
                            }
                        }
                    }
                }
            }

            // StmtInfo 도달성: 모든 importer에서 이 export의 import가 dead이면 제외
            // 역방향 맵으로 O(relevant_bindings) 탐색
            if (eb.kind == .local and m.importers.items.len > 0) {
                const is_dead = is_dead: {
                    var found_any = false;
                    for (rev_entries) |re| {
                        switch (re.kind) {
                            // re_export_all: 이 모듈 전체를 re-export → dead 아님
                            .re_export_all => break :is_dead false,
                            // re_export: imported_name이 이 export의 exported_name과 같으면 dead 아님
                            .re_export => {
                                if (std.mem.eql(u8, re.imported_name, eb.exported_name))
                                    break :is_dead false;
                            },
                            // import_binding: imported_name이 이 export의 exported_name과 매칭
                            .import_binding_named, .import_binding_other => {
                                if (!std.mem.eql(u8, re.imported_name, eb.exported_name)) continue;
                                found_any = true;
                                if (s.isImportLiveInModule(re.importer_module_index, re.local_name))
                                    break :is_dead false;
                            },
                        }
                    }
                    break :is_dead found_any;
                };
                if (is_dead) continue;
            }

            names_buf.append(allocator, eb.local_name) catch {
                all_used = true;
                break;
            };
            if (!std.mem.eql(u8, eb.exported_name, eb.local_name)) {
                names_buf.append(allocator, eb.exported_name) catch {
                    all_used = true;
                    break;
                };
            }
        }

        if (!all_used) {
            // cross-module: importer의 named binding도 포함 (역방향 맵 활용)
            for (rev_entries) |re| {
                if (all_used) break;
                switch (re.kind) {
                    .re_export_all => {
                        // re_export_all with exported_name != "*" → all_used
                        if (!std.mem.eql(u8, re.exported_name, "*")) {
                            all_used = true;
                        }
                    },
                    .re_export => {},
                    .import_binding_named => {
                        if (!s.isImportLiveInModule(re.importer_module_index, re.local_name)) continue;
                        names_buf.append(allocator, re.imported_name) catch {
                            all_used = true;
                            break;
                        };
                    },
                    .import_binding_other => {},
                }
            }
        }

        if (all_used) {
            names_buf.deinit(allocator);
            list[idx] = .{ .names = &.{}, .all_used = true };
        } else {
            list[idx] = .{
                .names = names_buf.toOwnedSlice(allocator) catch blk: {
                    // OOM: 내부 버퍼 해제 후 all_used 처리 (불완전한 이름 목록 방지)
                    names_buf.deinit(allocator);
                    break :blk &.{};
                },
                .all_used = false,
            };
        }
    }

    return list;
}

// ============================================================
// preserve-modules 경로 유틸리티
// ============================================================

/// preserve-modules: 모듈의 절대 경로에서 root를 제거하고 출력 상대 경로를 생성한다.
/// 예: abs_path="/Users/me/project/src/utils.ts", root="/Users/me/project/src"
///     → "utils.js"
/// root가 null이면 파일명만 사용 (stem + ext).
fn computePreserveModulesPath(
    allocator: std.mem.Allocator,
    abs_path: []const u8,
    out_ext: []const u8,
    root: ?[]const u8,
) ![]const u8 {
    const stem = std.fs.path.stem(std.fs.path.basename(abs_path));

    if (root) |r| {
        // root 경로를 기준으로 상대 경로 계산
        // abs_path가 root로 시작하면 그 뒷부분을 사용
        const normalized_root = if (r.len > 0 and r[r.len - 1] == '/') r[0 .. r.len - 1] else r;
        if (std.mem.startsWith(u8, abs_path, normalized_root)) {
            var rel = abs_path[normalized_root.len..];
            // 선행 '/' 제거
            if (rel.len > 0 and rel[0] == '/') rel = rel[1..];
            // 확장자를 교체
            const rel_stem = rel[0 .. rel.len - (std.fs.path.extension(rel).len)];
            return std.fmt.allocPrint(allocator, "{s}{s}", .{ rel_stem, out_ext });
        }
    }

    // root가 없거나 매칭 실패 → 공통 부모를 자동 감지하지 않고 파일명만 사용
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ stem, out_ext });
}

/// preserve-modules: 두 모듈 간의 상대 import 경로를 계산한다.
/// src_abs: import하는 모듈의 절대 경로
/// dep_abs: import 대상 모듈의 절대 경로
/// dep_stem: 대상 청크의 stem 이름 (fallback용)
/// ext: 출력 확장자
/// root: preserve-modules-root (null 가능)
///
/// 반환값: "./utils.js" 또는 "../lib/helper.js" 형태의 상대 경로 (allocator 소유)
fn computeRelativeImportPath(
    allocator: std.mem.Allocator,
    src_abs: []const u8,
    dep_abs: []const u8,
    ext: []const u8,
    root: ?[]const u8,
) ![]const u8 {
    // root가 있으면 root 기준 상대 경로에서 계산
    if (root) |r| {
        const normalized_root = if (r.len > 0 and r[r.len - 1] == '/') r[0 .. r.len - 1] else r;

        const src_rel = stripRoot(src_abs, normalized_root);
        const dep_rel = stripRoot(dep_abs, normalized_root);

        if (src_rel != null and dep_rel != null) {
            // 둘 다 root 아래 → 상대 경로 계산
            const src_dir = std.fs.path.dirname(src_rel.?) orelse "";
            const dep_rel_no_ext = dep_rel.?[0 .. dep_rel.?.len - std.fs.path.extension(dep_rel.?).len];
            const rel = try computeRelativePath(allocator, src_dir, dep_rel_no_ext, ext);
            return rel;
        }
    }

    // root 없거나 매칭 실패 → 절대 경로 기준으로 computeRelativePath에 위임
    const src_dir = std.fs.path.dirname(src_abs) orelse "";
    const dep_no_ext = dep_abs[0 .. dep_abs.len - std.fs.path.extension(dep_abs).len];
    return computeRelativePath(allocator, src_dir, dep_no_ext, ext);
}

/// 절대 경로에서 root prefix를 제거한다.
/// 예: stripRoot("/a/b/c.ts", "/a/b") → "c.ts"
fn stripRoot(abs_path: []const u8, root: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, abs_path, root)) {
        var rel = abs_path[root.len..];
        if (rel.len > 0 and rel[0] == '/') rel = rel[1..];
        return rel;
    }
    return null;
}

/// src_dir에서 dep_path로의 상대 경로를 계산한다.
/// 두 경로 모두 root 기준의 상대 경로여야 한다.
fn computeRelativePath(
    allocator: std.mem.Allocator,
    src_dir: []const u8,
    dep_path_no_ext: []const u8,
    ext: []const u8,
) ![]const u8 {
    // 공통 prefix 찾기
    var common_len: usize = 0;
    const min_len = @min(src_dir.len, dep_path_no_ext.len);
    for (0..min_len) |i| {
        if (src_dir.len > i and dep_path_no_ext.len > i and src_dir[i] == dep_path_no_ext[i]) {
            if (src_dir[i] == '/') common_len = i + 1;
        } else break;
    }
    // 전체가 일치하면 (src_dir가 dep_path_no_ext의 prefix이거나 같을 때)
    if (min_len == src_dir.len and (dep_path_no_ext.len == src_dir.len or
        (dep_path_no_ext.len > src_dir.len and dep_path_no_ext[src_dir.len] == '/')))
    {
        common_len = src_dir.len;
        if (dep_path_no_ext.len > src_dir.len) common_len += 1; // '/' 건너뛰기
    }

    // src_dir에서 common 이후의 깊이
    const src_remaining = if (common_len <= src_dir.len) src_dir[common_len..] else "";
    var depth: usize = 0;
    if (src_remaining.len > 0) {
        depth = 1;
        for (src_remaining) |c| {
            if (c == '/') depth += 1;
        }
    }

    const dep_remaining = if (common_len <= dep_path_no_ext.len) dep_path_no_ext[common_len..] else dep_path_no_ext;

    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);

    if (depth == 0) {
        try result.appendSlice(allocator, "./");
    } else {
        for (0..depth) |_| {
            try result.appendSlice(allocator, "../");
        }
    }
    try result.appendSlice(allocator, dep_remaining);
    try result.appendSlice(allocator, ext);

    return result.toOwnedSlice(allocator);
}
