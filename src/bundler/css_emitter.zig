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
const wyhash = @import("../util/wyhash.zig");

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
    css_names: []const u8,
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
        const css_path = try cssPathForChunk(allocator, chunk_graph.getChunk(cidx), css_names, buf.items);
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

/// JS 청크에 대응하는 CSS 출력 경로. `css_names` 패턴([name]/[hash]) 을 적용한다.
/// [hash] = CSS 내용 wyhash 로, JS 청크 해시와 독립 → CSS 만 바뀌면 CSS 파일명만
/// 바뀌어 immutable 캐싱이 깨지지 않는다. 패턴에 [hash] 가 없어도 청크 CSS 는
/// 캐시 안전을 위해 content-hash 를 강제 부여한다.
fn cssPathForChunk(
    allocator: std.mem.Allocator,
    chunk: *const Chunk,
    css_names: []const u8,
    contents: []const u8,
) ![]const u8 {
    if (chunk.name) |n| return applyCssChunkName(allocator, css_names, n, contents);
    if (chunk.filename) |f| return applyCssChunkName(allocator, css_names, std.fs.path.stem(f), contents);
    // "chunk" (5) + u32 십진 최대 10자리 = 15 < 16 → bufPrint 실패 불가.
    var idx_buf: [16]u8 = undefined;
    const idx_name = std.fmt.bufPrint(&idx_buf, "chunk{d}", .{@intFromEnum(chunk.index)}) catch unreachable;
    return applyCssChunkName(allocator, css_names, idx_name, contents);
}

/// `css_names` 패턴의 `[name]`/`[hash]` 를 치환한다. `.css` 확장자를 보장하고,
/// 패턴에 `[hash]` 가 없으면 확장자 앞에 `-<hash>` 를 강제 삽입한다(청크 캐시 안전).
/// chunks.zig 의 `applyNamingPattern` 과 분리 유지 — 그쪽은 buffer 기반·[ext] 처리
/// 이고 여기는 CSS 전용(강제 hash + .css 보장)이라 의미가 다르다.
fn applyCssChunkName(
    allocator: std.mem.Allocator,
    pattern: []const u8,
    stem: []const u8,
    contents: []const u8,
) ![]const u8 {
    const h = wyhash.hashHex8(contents);
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    var had_hash = false;
    var i: usize = 0;
    while (i < pattern.len) {
        if (std.mem.startsWith(u8, pattern[i..], "[name]")) {
            try out.appendSlice(allocator, stem);
            i += "[name]".len;
        } else if (std.mem.startsWith(u8, pattern[i..], "[hash]")) {
            try out.appendSlice(allocator, &h);
            had_hash = true;
            i += "[hash]".len;
        } else {
            try out.append(allocator, pattern[i]);
            i += 1;
        }
    }
    if (!had_hash) {
        try out.append(allocator, '-');
        try out.appendSlice(allocator, &h);
    }
    if (!std.mem.endsWith(u8, out.items, ".css")) {
        try out.appendSlice(allocator, ".css");
    }
    return out.toOwnedSlice(allocator);
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

test "applyCssChunkName: empty stem still produces -hash.css" {
    const a = std.testing.allocator;
    const h = wyhash.hashHex8(".");
    const expect = try std.fmt.allocPrint(a, "-{s}.css", .{h});
    defer a.free(expect);
    const r = try applyCssChunkName(a, "[name]", "", ".");
    defer a.free(r);
    try std.testing.expectEqualStrings(expect, r);
}

test "applyCssChunkName: pattern with no placeholders forces -hash" {
    const a = std.testing.allocator;
    const h = wyhash.hashHex8("x");
    const expect = try std.fmt.allocPrint(a, "styles/main-{s}.css", .{h});
    defer a.free(expect);
    const r = try applyCssChunkName(a, "styles/main", "idx", "x");
    defer a.free(r);
    try std.testing.expectEqualStrings(expect, r);
}

test "applyCssChunkName: [name] only forces -hash before .css" {
    const a = std.testing.allocator;
    const h = wyhash.hashHex8(".x{}");
    const expect = try std.fmt.allocPrint(a, "route-a-{s}.css", .{h});
    defer a.free(expect);
    const r = try applyCssChunkName(a, "[name]", "route-a", ".x{}");
    defer a.free(r);
    try std.testing.expectEqualStrings(expect, r);
}

test "applyCssChunkName: explicit [hash] not duplicated" {
    const a = std.testing.allocator;
    const h = wyhash.hashHex8("body{}");
    const expect = try std.fmt.allocPrint(a, "v-{s}.css", .{h});
    defer a.free(expect);
    const r = try applyCssChunkName(a, "[name]-[hash]", "v", "body{}");
    defer a.free(r);
    try std.testing.expectEqualStrings(expect, r);
}

test "applyCssChunkName: explicit .css extension not doubled, dir preserved" {
    const a = std.testing.allocator;
    const h = wyhash.hashHex8("c");
    const expect = try std.fmt.allocPrint(a, "assets/idx.{s}.css", .{h});
    defer a.free(expect);
    const r = try applyCssChunkName(a, "assets/[name].[hash].css", "idx", "c");
    defer a.free(r);
    try std.testing.expectEqualStrings(expect, r);
}

test "applyCssChunkName: hash depends only on contents (determinism + sensitivity)" {
    const a = std.testing.allocator;
    const r1 = try applyCssChunkName(a, "[name]-[hash]", "s", ".s{color:red}");
    defer a.free(r1);
    const r2 = try applyCssChunkName(a, "[name]-[hash]", "s", ".s{color:red}");
    defer a.free(r2);
    try std.testing.expectEqualStrings(r1, r2);
    const r3 = try applyCssChunkName(a, "[name]-[hash]", "s", ".s{color:blue}");
    defer a.free(r3);
    try std.testing.expect(!std.mem.eql(u8, r1, r3));
    // stem 이 달라도 hash 부분은 동일 (contents 만 의존)
    const r4 = try applyCssChunkName(a, "[name]-[hash]", "OTHER", ".s{color:red}");
    defer a.free(r4);
    const h = wyhash.hashHex8(".s{color:red}");
    try std.testing.expect(std.mem.indexOf(u8, r1, &h) != null);
    try std.testing.expect(std.mem.indexOf(u8, r4, &h) != null);
}

test "cssPathForChunk: uses chunk.name + content hash" {
    const a = std.testing.allocator;
    const bits = try chunk_mod.BitSet.init(a, 1);
    var ch = Chunk.init(@enumFromInt(0), .common, bits);
    defer ch.deinit(a);
    ch.name = "vendor";
    const h = wyhash.hashHex8(".v{}");
    const expect = try std.fmt.allocPrint(a, "vendor-{s}.css", .{h});
    defer a.free(expect);
    const r = try cssPathForChunk(a, &ch, "[name]", ".v{}");
    defer a.free(r);
    try std.testing.expectEqualStrings(expect, r);
}

test "cssPathForChunk: falls back to filename stem then chunk index" {
    const a = std.testing.allocator;
    const bits1 = try chunk_mod.BitSet.init(a, 1);
    var ch1 = Chunk.init(@enumFromInt(0), .common, bits1);
    defer ch1.deinit(a);
    ch1.filename = "assets/route-a-9f8e.js";
    const r1 = try cssPathForChunk(a, &ch1, "[name]-[hash]", "c");
    defer a.free(r1);
    try std.testing.expect(std.mem.startsWith(u8, r1, "route-a-9f8e-"));
    try std.testing.expect(std.mem.endsWith(u8, r1, ".css"));

    const bits2 = try chunk_mod.BitSet.init(a, 1);
    var ch2 = Chunk.init(@enumFromInt(7), .common, bits2);
    defer ch2.deinit(a);
    const r2 = try cssPathForChunk(a, &ch2, "[name]-[hash]", "c");
    defer a.free(r2);
    try std.testing.expect(std.mem.startsWith(u8, r2, "chunk7-"));
}
