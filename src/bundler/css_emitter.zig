//! CSS 번들 Emitter
//!
//! 엔트리 JS 모듈에서 도달 가능한 CSS 모듈을 수집하고,
//! @import 규칙을 strip한 뒤 exec_index 순으로 연결하여
//! 단일 CSS 파일을 생성한다.

const std = @import("std");
const Module = @import("module.zig").Module;
const types = @import("types.zig");
const ModuleIndex = types.ModuleIndex;
const ChunkIndex = types.ChunkIndex;
const ModuleGraph = @import("graph.zig").ModuleGraph;
const chunk_mod = @import("chunk.zig");
const ChunkGraph = chunk_mod.ChunkGraph;
const Chunk = chunk_mod.Chunk;
const emitter = @import("emitter.zig");
const OutputFile = emitter.OutputFile;

/// 엔트리 모듈에서 도달 가능한 CSS 모듈을 수집하여 연결된 CSS 번들을 생성한다.
/// CSS 모듈이 없으면 null을 반환한다.
pub fn emitCssBundle(
    allocator: std.mem.Allocator,
    graph: *const ModuleGraph,
    entry_idx: ModuleIndex,
    css_names: []const u8,
) ?OutputFile {
    // DFS로 엔트리에서 도달 가능한 CSS 모듈 수집
    var css_modules: std.ArrayListUnmanaged(*const Module) = .empty;
    defer css_modules.deinit(allocator);

    var visited = std.AutoHashMap(ModuleIndex, void).init(allocator);
    defer visited.deinit();

    collectCssModules(allocator, graph, entry_idx, &css_modules, &visited);

    if (css_modules.items.len == 0) return null;

    // exec_index 순으로 정렬 (CSS 출력 순서 = JS 실행 순서)
    std.mem.sort(*const Module, css_modules.items, {}, struct {
        fn lessThan(_: void, a: *const Module, b: *const Module) bool {
            return a.exec_index < b.exec_index;
        }
    }.lessThan);

    // CSS 소스 연결 (@import strip)
    var output: std.ArrayListUnmanaged(u8) = .empty;
    defer output.deinit(allocator);

    appendCssModules(allocator, &output, css_modules.items) catch {};

    if (output.items.len == 0) return null;

    // 출력 파일명 결정
    const entry_mod = graph.getModule(entry_idx) orelse return null;
    const entry_path = entry_mod.path;
    const css_path = applyCssNamingPattern(allocator, css_names, entry_path) catch return null;

    return .{
        .path = css_path,
        .contents = output.toOwnedSlice(allocator) catch return null,
    };
}

/// 정렬된 CSS 모듈들을 @import strip 후 줄바꿈 구분하여 buf 에 이어붙인다.
/// emitCssBundle(단일) / emitCssChunks(청크별) 가 공유.
fn appendCssModules(
    allocator: std.mem.Allocator,
    buf: *std.ArrayListUnmanaged(u8),
    css_modules: []const *const Module,
) !void {
    for (css_modules) |mod| {
        const strip_end: u32 = if (mod.css_data) |cd| cd.strip_end else 0;
        const stripped = if (strip_end > 0 and strip_end < mod.source.len) mod.source[strip_end..] else mod.source;
        const trimmed = std.mem.trim(u8, stripped, " \t\n\r");
        if (trimmed.len == 0) continue;
        try buf.appendSlice(allocator, stripped);
        if (stripped.len > 0 and stripped[stripped.len - 1] != '\n') {
            try buf.append(allocator, '\n');
        }
    }
}

/// code splitting 시 JS 청크별로 CSS 를 분리하여 OutputFile 목록을 생성한다.
///
/// 각 CSS 모듈은 그것을 import 하는 JS 모듈이 속한 청크 중
/// `(chunk.exec_order, importer.exec_index)` 가 가장 앞서는 단 하나의 청크에
/// 귀속된다(전역 dedup — 공유 CSS 가 여러 청크에 복제되지 않음).
/// CSS→CSS(@import) 의존은 같은 귀속 청크로 함께 묶인다.
/// 반환 슬라이스와 각 OutputFile 의 path/contents 는 모두 `allocator` 소유.
/// 분리할 CSS 가 없으면 길이 0 슬라이스를 반환한다.
pub fn emitCssChunks(
    allocator: std.mem.Allocator,
    graph: *const ModuleGraph,
    chunk_graph: *const ChunkGraph,
) ![]OutputFile {
    const n_chunks = chunk_graph.chunkCount();
    if (n_chunks == 0) return allocator.alloc(OutputFile, 0);

    // 1패스: CSS 모듈 → 귀속 청크(최소 rank 우승). owner_rank/visited 는 DFS 중에만 필요.
    var owner = std.AutoHashMap(ModuleIndex, ChunkIndex).init(allocator);
    defer owner.deinit();
    var owner_rank = std.AutoHashMap(ModuleIndex, u64).init(allocator);
    defer owner_rank.deinit();
    var visited = std.AutoHashMap(ModuleIndex, void).init(allocator);
    defer visited.deinit();

    var it = graph.modulesIterator();
    while (it.next()) |m| {
        if (m.module_type == .css) continue;
        const ci = chunk_graph.getModuleChunk(m.index);
        if (ci.isNone()) continue;
        const ch = chunk_graph.getChunk(ci);
        const rank: u64 = (@as(u64, ch.exec_order) << 32) | @as(u64, m.exec_index);
        visited.clearRetainingCapacity();
        for (m.dependencies.items) |dep| {
            walkCssOwner(graph, dep, ci, rank, &owner, &owner_rank, &visited);
        }
    }

    if (owner.count() == 0) return allocator.alloc(OutputFile, 0);

    // owner 를 청크별 역색인으로 1회 변환 (청크마다 owner 전체를 재스캔하지 않도록).
    var chunk_mods = std.AutoHashMap(u32, std.ArrayListUnmanaged(*const Module)).init(allocator);
    defer {
        var vit = chunk_mods.valueIterator();
        while (vit.next()) |list| list.deinit(allocator);
        chunk_mods.deinit();
    }
    var oit = owner.iterator();
    while (oit.next()) |e| {
        const mm = graph.getModule(e.key_ptr.*) orelse continue;
        if (mm.module_type != .css or mm.css_data == null) continue;
        const gop = try chunk_mods.getOrPut(@intFromEnum(e.value_ptr.*));
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(allocator, mm);
    }

    var out_list: std.ArrayListUnmanaged(OutputFile) = .empty;
    errdefer {
        for (out_list.items) |o| {
            allocator.free(o.path);
            allocator.free(o.contents);
        }
        out_list.deinit(allocator);
    }

    // 청크 인덱스 순회 → 출력 순서가 결정적(HashMap 순회 순서와 무관).
    var chunk_idx: usize = 0;
    while (chunk_idx < n_chunks) : (chunk_idx += 1) {
        const list = chunk_mods.getPtr(@intCast(chunk_idx)) orelse continue;
        if (list.items.len == 0) continue;

        std.mem.sort(*const Module, list.items, {}, struct {
            fn lessThan(_: void, a: *const Module, b: *const Module) bool {
                return a.exec_index < b.exec_index;
            }
        }.lessThan);

        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(allocator);
        try appendCssModules(allocator, &buf, list.items);
        if (buf.items.len == 0) continue;

        const cidx: ChunkIndex = @enumFromInt(@as(u32, @intCast(chunk_idx)));
        const css_path = try cssPathForChunk(allocator, chunk_graph.getChunk(cidx));
        errdefer allocator.free(css_path);
        const contents = try buf.toOwnedSlice(allocator);
        try out_list.append(allocator, .{ .path = css_path, .contents = contents });
    }

    return out_list.toOwnedSlice(allocator);
}

/// CSS 서브그래프를 DFS 하며 각 CSS 모듈의 귀속 청크를 최소 rank 로 갱신한다.
/// JS 모듈은 따라가지 않는다(각 JS 모듈은 호출부에서 개별 처리).
/// `visited` 는 JS 모듈(루트)마다 clear 되며 `rank` 는 한 루트 안에서 불변 →
/// 같은 루트 내 재방문은 정보가 없어 skip 해도 안전하고, 다른 루트(다른 rank)
/// 에서는 visited 가 비워져 재평가되므로 최소 rank 가 누락되지 않는다.
fn walkCssOwner(
    graph: *const ModuleGraph,
    idx: ModuleIndex,
    ci: ChunkIndex,
    rank: u64,
    owner: *std.AutoHashMap(ModuleIndex, ChunkIndex),
    owner_rank: *std.AutoHashMap(ModuleIndex, u64),
    visited: *std.AutoHashMap(ModuleIndex, void),
) void {
    if (idx.isNone()) return;
    if (visited.contains(idx)) return;
    visited.put(idx, {}) catch return;
    const mod = graph.getModule(idx) orelse return;
    if (mod.module_type != .css) return;

    const better = if (owner_rank.get(idx)) |r| rank < r else true;
    if (better) {
        owner.put(idx, ci) catch return;
        owner_rank.put(idx, rank) catch return;
    }
    for (mod.dependencies.items) |dep| {
        walkCssOwner(graph, dep, ci, rank, owner, owner_rank, visited);
    }
}

/// JS 청크에 대응하는 CSS 출력 경로를 결정한다.
/// 청크의 최종 JS 파일명(basename)에서 확장자를 `.css` 로 치환 → JS 청크와 1:1 페어링.
fn cssPathForChunk(allocator: std.mem.Allocator, chunk: *const Chunk) ![]const u8 {
    const base = chunk.filename orelse chunk.name orelse {
        return std.fmt.allocPrint(allocator, "chunk{d}.css", .{@intFromEnum(chunk.index)});
    };
    return jsStemToCssName(allocator, std.fs.path.basename(base));
}

/// "route-a-abc123.js" → "route-a-abc123.css" (마지막 '.' 이후 확장자만 치환).
/// 확장자가 없으면 ".css" 를 덧붙인다.
fn jsStemToCssName(allocator: std.mem.Allocator, basename: []const u8) ![]const u8 {
    const stem = if (std.mem.lastIndexOfScalar(u8, basename, '.')) |dot|
        basename[0..dot]
    else
        basename;
    return std.fmt.allocPrint(allocator, "{s}.css", .{stem});
}

/// DFS로 모듈 그래프를 탐색하여 CSS 모듈을 수집한다.
fn collectCssModules(
    allocator: std.mem.Allocator,
    graph: *const ModuleGraph,
    idx: ModuleIndex,
    result: *std.ArrayListUnmanaged(*const Module),
    visited: *std.AutoHashMap(ModuleIndex, void),
) void {
    if (idx == .none) return;
    if (visited.contains(idx)) return;
    const mod = graph.getModule(idx) orelse return;
    visited.put(idx, {}) catch return;

    // 의존성 먼저 방문 (DFS)
    for (mod.dependencies.items) |dep_idx| {
        collectCssModules(allocator, graph, dep_idx, result, visited);
    }

    // CSS 모듈이면 결과에 추가
    if (mod.module_type == .css and mod.css_data != null) {
        result.append(allocator, mod) catch {};
    }
}

/// CSS 출력 파일명 패턴 적용.
/// [name] → 엔트리 파일의 basename (확장자 제거) + .css
fn applyCssNamingPattern(allocator: std.mem.Allocator, pattern: []const u8, entry_path: []const u8) ![]const u8 {
    // 엔트리 파일의 basename 추출 (확장자 제거)
    const basename = std.fs.path.basename(entry_path);
    const name = if (std.mem.lastIndexOf(u8, basename, ".")) |dot|
        basename[0..dot]
    else
        basename;

    // [name] 패턴 치환
    if (std.mem.indexOf(u8, pattern, "[name]")) |idx| {
        const before = pattern[0..idx];
        const after = pattern[idx + 6 ..]; // "[name]".len = 6
        return std.fmt.allocPrint(allocator, "{s}{s}{s}.css", .{ before, name, after });
    }

    // 패턴에 [name] 없으면 그대로 + .css
    return std.fmt.allocPrint(allocator, "{s}.css", .{pattern});
}

// ============================================================
// 테스트
// ============================================================

test "applyCssNamingPattern: default pattern" {
    const result = try applyCssNamingPattern(std.testing.allocator, "[name]", "/app/src/index.ts");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("index.css", result);
}

test "applyCssNamingPattern: custom pattern" {
    const result = try applyCssNamingPattern(std.testing.allocator, "styles/[name]", "/app/src/main.tsx");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("styles/main.css", result);
}

test "jsStemToCssName: hashed js chunk → css" {
    const r = try jsStemToCssName(std.testing.allocator, "route-a-abc123.js");
    defer std.testing.allocator.free(r);
    try std.testing.expectEqualStrings("route-a-abc123.css", r);
}

test "jsStemToCssName: mjs/cjs extension swapped" {
    const a = try jsStemToCssName(std.testing.allocator, "vendor.mjs");
    defer std.testing.allocator.free(a);
    try std.testing.expectEqualStrings("vendor.css", a);
    const b = try jsStemToCssName(std.testing.allocator, "common.cjs");
    defer std.testing.allocator.free(b);
    try std.testing.expectEqualStrings("common.css", b);
}

test "jsStemToCssName: no extension appends .css" {
    const r = try jsStemToCssName(std.testing.allocator, "chunkname");
    defer std.testing.allocator.free(r);
    try std.testing.expectEqualStrings("chunkname.css", r);
}

test "jsStemToCssName: only last dot is treated as extension" {
    const r = try jsStemToCssName(std.testing.allocator, "a.b.c-hash.js");
    defer std.testing.allocator.free(r);
    try std.testing.expectEqualStrings("a.b.c-hash.css", r);
}

test "cssPathForChunk: uses filename basename, strips dir" {
    const bits = try chunk_mod.BitSet.init(std.testing.allocator, 1);
    var ch = Chunk.init(@enumFromInt(0), .common, bits);
    defer ch.deinit(std.testing.allocator);
    ch.filename = "assets/route-a-9f8e.js";
    const r = try cssPathForChunk(std.testing.allocator, &ch);
    defer std.testing.allocator.free(r);
    try std.testing.expectEqualStrings("route-a-9f8e.css", r);
}

test "cssPathForChunk: falls back to name" {
    const bits1 = try chunk_mod.BitSet.init(std.testing.allocator, 1);
    var ch1 = Chunk.init(@enumFromInt(0), .common, bits1);
    defer ch1.deinit(std.testing.allocator);
    ch1.name = "vendor";
    const r1 = try cssPathForChunk(std.testing.allocator, &ch1);
    defer std.testing.allocator.free(r1);
    try std.testing.expectEqualStrings("vendor.css", r1);
}

test "cssPathForChunk: falls back to chunk index" {
    const bits2 = try chunk_mod.BitSet.init(std.testing.allocator, 1);
    var ch2 = Chunk.init(@enumFromInt(7), .common, bits2);
    defer ch2.deinit(std.testing.allocator);
    const r2 = try cssPathForChunk(std.testing.allocator, &ch2);
    defer std.testing.allocator.free(r2);
    try std.testing.expectEqualStrings("chunk7.css", r2);
}
