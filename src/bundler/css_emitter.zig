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
fn appendCssModule(
    allocator: std.mem.Allocator,
    buf: *std.ArrayListUnmanaged(u8),
    mod: *const Module,
) !void {
    const strip_end: u32 = if (mod.css_data) |cd| cd.strip_end else 0;
    const stripped = if (strip_end > 0 and strip_end < mod.source.len) mod.source[strip_end..] else mod.source;
    const trimmed = std.mem.trim(u8, stripped, " \t\n\r");
    if (trimmed.len == 0) return;
    try buf.appendSlice(allocator, stripped);
    if (stripped.len > 0 and stripped[stripped.len - 1] != '\n') {
        try buf.append(allocator, '\n');
    }
}

fn appendCssModules(
    allocator: std.mem.Allocator,
    buf: *std.ArrayListUnmanaged(u8),
    css_modules: []const *const Module,
) !void {
    for (css_modules) |mod| try appendCssModule(allocator, buf, mod);
}

/// 한 CSS 모듈을 그 @import(css→css) 의존을 먼저 인라인한 뒤 emit 한다.
/// `visited` 는 *청크 단위* — 같은 청크 안에서만 dedup(여러 owned CSS 가 같은
/// shared 를 @import 해도 1회), 청크 간에는 복제(@import 는 쓰는 곳마다 존재).
/// deps-before-importer 순서로 @import 인라인 의미를 보존(순환은 visited 로 차단).
fn emitCssModuleTree(
    allocator: std.mem.Allocator,
    graph: *const ModuleGraph,
    idx: ModuleIndex,
    buf: *std.ArrayListUnmanaged(u8),
    visited: *std.AutoHashMap(ModuleIndex, void),
) !void {
    if (idx.isNone()) return;
    if (visited.contains(idx)) return;
    // 함수가 `!void` 라 OOM 은 propagate — `catch return` 으로 삼키면 silent skip 되어
    // @import 서브트리가 emit 누락된다.
    try visited.put(idx, {});
    const mod = graph.getModule(idx) orelse return;
    if (mod.module_type != .css) return;
    for (mod.dependencies.items) |dep| {
        if (graph.getModule(dep)) |dm| {
            if (dm.module_type == .css) try emitCssModuleTree(allocator, graph, dep, buf, visited);
        }
    }
    try appendCssModule(allocator, buf, mod);
}

/// 청크별 CSS 계획 항목. `path`/`contents` 는 `allocator` 소유.
/// `chunk_index` 로 동적 import 재작성 시점에 chunk→css href 를 연결한다(P0-3).
pub const CssChunkPlanEntry = struct {
    chunk_index: u32,
    path: []const u8,
    contents: []const u8,
};

/// code splitting 시 JS 청크별로 분리할 CSS 를 계획한다(파일명/내용 확정).
/// emitChunks 의 content-hash 계산 *전* 에 호출 가능해야 chunk→css href 를
/// 청크 prologue 에 주입할 수 있다. CSS 파일명은 CSS 내용 해시 기반이라 JS
/// 청크 해시와 독립적으로 이 시점에 확정된다.
///
/// 각 CSS 모듈은 그것을 import 하는 JS 모듈이 속한 *모든* 청크에 인라인
/// 복제된다(esbuild/webpack 동치 — single-owner min-rank dedup 폐기). 이유:
/// shared CSS 가 한 owner 청크에만 들어가면 다른 페이지/동적 청크가 단독
/// 진입될 때 그 규칙이 cascade 에 없어 미적용. dedup 은 청크 단위로만
/// (같은 청크 안에서 여러 JS 모듈이 같은 CSS 도달해도 1회).
/// CSS→CSS(@import) 의존은 emit 시점에 청크별로 다시 인라인된다(쓰는 곳마다
/// 존재 — #3321 P0-4). 반환 슬라이스/각 항목의 path/contents 는 모두
/// `allocator` 소유.
pub fn planCssChunks(
    allocator: std.mem.Allocator,
    graph: *const ModuleGraph,
    chunk_graph: *const ChunkGraph,
    css_names: []const u8,
) ![]CssChunkPlanEntry {
    const n_chunks = chunk_graph.chunkCount();
    if (n_chunks == 0) return allocator.alloc(CssChunkPlanEntry, 0);

    // 1패스: CSS 모듈 → 도달 가능한 *모든* 청크에 등재(esbuild/webpack 동치 —
    // single-owner dedup 폐기). 이유: ① b 페이지가 a-only 인 shared 규칙을
    // 잃어 .common 미적용 ② 동적 청크가 부모 청크 owner 의 CSS 에만 의존해
    // 단독 진입 시 스타일 미적용 — cascade 와 청크 독립 로드 의미가 깨졌다.
    // dedup 은 청크 단위로만(같은 청크 내 같은 CSS 가 여러 JS 모듈 경로로
    // 도달해도 1번). 청크 간 복제는 허용 — 동적 청크가 자기 CSS 를
    // <link> 로 가져가도록 `chunk_css_hrefs` 도 자동으로 채워진다.
    var chunk_mods = std.AutoHashMap(u32, std.ArrayListUnmanaged(*const Module)).init(allocator);
    defer {
        var vit = chunk_mods.valueIterator();
        while (vit.next()) |list| list.deinit(allocator);
        chunk_mods.deinit();
    }
    // (chunk_idx, css_module_idx) 쌍 dedup — 한 청크 내 같은 CSS 1회.
    var chunk_seen = std.AutoHashMap(ChunkCssKey, void).init(allocator);
    defer chunk_seen.deinit();
    var visited = std.AutoHashMap(ModuleIndex, void).init(allocator);
    defer visited.deinit();

    var it = graph.modulesIterator();
    while (it.next()) |m| {
        if (m.module_type == .css) continue;
        const ci = chunk_graph.getModuleChunk(m.index);
        if (ci.isNone()) continue;
        visited.clearRetainingCapacity();
        for (m.dependencies.items) |dep| {
            try walkCssOwner(allocator, graph, chunk_graph, dep, ci, &chunk_mods, &chunk_seen, &visited);
        }
    }

    if (chunk_mods.count() == 0) return allocator.alloc(CssChunkPlanEntry, 0);

    var out_list: std.ArrayListUnmanaged(CssChunkPlanEntry) = .empty;
    errdefer {
        for (out_list.items) |o| {
            allocator.free(o.path);
            allocator.free(o.contents);
        }
        out_list.deinit(allocator);
    }

    // @import 인라인 dedup 용 — 청크마다 clear (청크 간엔 복제 허용).
    var emit_visited = std.AutoHashMap(ModuleIndex, void).init(allocator);
    defer emit_visited.deinit();

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
        emit_visited.clearRetainingCapacity();
        for (list.items) |mod| {
            try emitCssModuleTree(allocator, graph, mod.index, &buf, &emit_visited);
        }
        if (buf.items.len == 0) continue;

        const cidx: ChunkIndex = @enumFromInt(@as(u32, @intCast(chunk_idx)));
        const css_path = try cssPathForChunk(allocator, chunk_graph.getChunk(cidx), css_names, buf.items);
        errdefer allocator.free(css_path);
        const contents = try buf.toOwnedSlice(allocator);
        // toOwnedSlice 후 buf 가 비워지므로 defer buf.deinit 은 contents 를 회수하지 않는다.
        // out_list.append 가 실패하면 contents 는 어디에도 매여 있지 않아 누수 — errdefer 보호.
        errdefer allocator.free(contents);
        try out_list.append(allocator, .{
            .chunk_index = @intCast(chunk_idx),
            .path = css_path,
            .contents = contents,
        });
    }

    return out_list.toOwnedSlice(allocator);
}

/// `plan` 의 path/contents 소유권을 OutputFile 로 이전한다(plan 컨테이너는
/// caller 가 해제). 실패 시 아직 이전 안 된 항목을 해제한다.
pub fn planToOutputFiles(
    allocator: std.mem.Allocator,
    plan: []const CssChunkPlanEntry,
) ![]OutputFile {
    const files = allocator.alloc(OutputFile, plan.len) catch |err| {
        for (plan) |e| {
            allocator.free(e.path);
            allocator.free(e.contents);
        }
        return err;
    };
    for (plan, 0..) |e, i| files[i] = .{ .path = e.path, .contents = e.contents };
    return files;
}

/// 청크 인덱스 → CSS href(basename) 배열(길이 `n_chunks`). 값은 plan 의
/// path 를 빌려온 slice — `plan` 이 살아있는 동안만 유효. 동적 import 된
/// 청크가 자기 CSS 를 런타임 `<link>` 로 로드하도록 emitChunks 에 전달한다.
pub fn planChunkHrefs(
    allocator: std.mem.Allocator,
    plan: []const CssChunkPlanEntry,
    n_chunks: usize,
) ![]?[]const u8 {
    const hrefs = try allocator.alloc(?[]const u8, n_chunks);
    @memset(hrefs, null);
    for (plan) |e| {
        if (e.chunk_index < n_chunks) hrefs[e.chunk_index] = std.fs.path.basename(e.path);
    }
    return hrefs;
}

/// `planCssChunks` 결과를 OutputFile 목록으로 변환한다(기존 호출부 호환).
pub fn emitCssChunks(
    allocator: std.mem.Allocator,
    graph: *const ModuleGraph,
    chunk_graph: *const ChunkGraph,
    css_names: []const u8,
) ![]OutputFile {
    const plan = try planCssChunks(allocator, graph, chunk_graph, css_names);
    defer allocator.free(plan);
    return planToOutputFiles(allocator, plan);
}

/// `chunk_mods`/`chunk_seen` 의 청크 dedup 키. AutoHashMap 이 자동 hash/eql.
const ChunkCssKey = struct { chunk: u32, css: ModuleIndex };

/// CSS 서브그래프를 DFS 하며 각 JS 청크 `ci` 가 도달 가능한 CSS 모듈을
/// `chunk_mods[ci]` 에 등재한다(per-chunk dedup). single-owner min-rank 정책은
/// 페이지/동적 청크 독립 로드 시 cascade 와 적용성을 깨므로 폐기 — 도달 모든
/// 청크에 인라인 복제(esbuild/webpack 동치). 자체 chunk 를 가진 JS 모듈에서
/// 멈추는 것은 그대로(과귀속 방지: 그 청크는 자기 순회에서 자기 CSS 를
/// 등재한다). chunk 미할당 JS(= tree-shaken 된 `.css.js` 류 side-effect proxy:
/// Sass/CSS Modules 가 `import "./x.scss"` → proxy → `import "./x.css"` 로
/// 생성)는 통과해 그 너머 CSS 를 현재 청크에 귀속한다 — 통과 안 하면
/// splitting 경로에서 CSS 가 통째로 누락된다(#3330).
/// `visited` 는 JS 모듈(루트)마다 clear — 한 루트 안 재방문은 새 정보 없음.
/// 다른 청크 루트에서는 visited 가 비워져 재평가되므로 누락되지 않는다.
/// JS 가 import 한 CSS 는 등재하고 멈춘다 — 그 CSS 가 @import 한 CSS 는
/// emit 시점에 `emitCssModuleTree` 가 인라인(@import 의미: 쓰는 곳마다 존재,
/// #3321 P0-4).
fn walkCssOwner(
    allocator: std.mem.Allocator,
    graph: *const ModuleGraph,
    chunk_graph: *const ChunkGraph,
    idx: ModuleIndex,
    ci: ChunkIndex,
    chunk_mods: *std.AutoHashMap(u32, std.ArrayListUnmanaged(*const Module)),
    chunk_seen: *std.AutoHashMap(ChunkCssKey, void),
    visited: *std.AutoHashMap(ModuleIndex, void),
) !void {
    if (idx.isNone()) return;
    if (visited.contains(idx)) return;
    // 함수가 `!void` 로 바뀌었으니 visited.put OOM 도 try 로 propagate.
    // 옛 `catch return` 은 silent skip → CSS 서브트리 누락 + 호출자가 OOM 도
    // 감지 못함. 같은 함수 내 chunk_seen/chunk_mods 가 try 를 쓰는 것과도 일관.
    try visited.put(idx, {});
    const mod = graph.getModule(idx) orelse return;

    if (mod.module_type == .css) {
        if (mod.css_data == null) return;
        const ci_u32 = @intFromEnum(ci);
        // 청크 단위 dedup — 같은 청크 안에서 여러 JS 모듈이 같은 CSS 도달해도 1회.
        const seen_gop = try chunk_seen.getOrPut(.{ .chunk = ci_u32, .css = idx });
        if (seen_gop.found_existing) return;
        const list_gop = try chunk_mods.getOrPut(ci_u32);
        if (!list_gop.found_existing) list_gop.value_ptr.* = .empty;
        try list_gop.value_ptr.append(allocator, mod);
        return;
    }

    // 비-CSS(JS 등): 자체 chunk 가 있으면 호출부 개별 순회가 담당하므로 멈춘다.
    // chunk 미할당(tree-shaken side-effect proxy)만 통과해 너머 CSS 를 찾는다.
    if (!chunk_graph.getModuleChunk(mod.index).isNone()) return;
    for (mod.dependencies.items) |dep| {
        try walkCssOwner(allocator, graph, chunk_graph, dep, ci, chunk_mods, chunk_seen, visited);
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

/// `css_names` 패턴의 `[name]`/`[hash]` 를 충실히 치환하고 `.css` 확장자를
/// 보장한다. `[hash]`(= CSS 내용 wyhash) 는 패턴에 명시됐을 때만 삽입한다 —
/// 강제 삽입은 app-builder 의 안정 파일명(`[name]`→`main.css`, HTML link
/// rewrite) 기대를 깨므로 하지 않는다. 캐시 버스팅이 필요하면 css_names 에
/// `[hash]` 를 넣는다(JS 청크의 entry_names/chunk_names 와 동일 계약).
/// chunks.zig 의 `applyNamingPattern` 과 분리 유지 — 그쪽은 buffer 기반·[ext]
/// 처리이고 여기는 CSS 전용(.css 보장)이라 의미가 다르다.
fn applyCssChunkName(
    allocator: std.mem.Allocator,
    pattern: []const u8,
    stem: []const u8,
    contents: []const u8,
) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < pattern.len) {
        if (std.mem.startsWith(u8, pattern[i..], "[name]")) {
            try out.appendSlice(allocator, stem);
            i += "[name]".len;
        } else if (std.mem.startsWith(u8, pattern[i..], "[hash]")) {
            const h = wyhash.hashHex8(contents);
            try out.appendSlice(allocator, &h);
            i += "[hash]".len;
        } else {
            try out.append(allocator, pattern[i]);
            i += 1;
        }
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

test "applyCssChunkName: empty stem → just .css (no forced hash)" {
    const a = std.testing.allocator;
    const r = try applyCssChunkName(a, "[name]", "", ".");
    defer a.free(r);
    try std.testing.expectEqualStrings(".css", r);
}

test "applyCssChunkName: pattern with no placeholders → literal + .css (no forced hash)" {
    const a = std.testing.allocator;
    const r = try applyCssChunkName(a, "styles/main", "idx", "x");
    defer a.free(r);
    try std.testing.expectEqualStrings("styles/main.css", r);
}

test "applyCssChunkName: [name] only → stem.css (no forced hash — app-builder 안정 파일명)" {
    const a = std.testing.allocator;
    const r = try applyCssChunkName(a, "[name]", "route-a", ".x{}");
    defer a.free(r);
    try std.testing.expectEqualStrings("route-a.css", r);
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

test "applyCssChunkName: multiple [hash] all replaced (no leftover token)" {
    const a = std.testing.allocator;
    const h = wyhash.hashHex8("c");
    const expect = try std.fmt.allocPrint(a, "x-{s}-{s}.css", .{ h, h });
    defer a.free(expect);
    const r = try applyCssChunkName(a, "x-[hash]-[hash]", "n", "c");
    defer a.free(r);
    try std.testing.expectEqualStrings(expect, r);
    try std.testing.expect(std.mem.indexOf(u8, r, "[hash]") == null);
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

test "cssPathForChunk: [name] → chunk.name.css (안정 파일명, 강제 hash 없음)" {
    const a = std.testing.allocator;
    const bits = try chunk_mod.BitSet.init(a, 1);
    var ch = Chunk.init(@enumFromInt(0), .common, bits);
    defer ch.deinit(a);
    ch.name = "vendor";
    const r = try cssPathForChunk(a, &ch, "[name]", ".v{}");
    defer a.free(r);
    try std.testing.expectEqualStrings("vendor.css", r);
}

test "cssPathForChunk: [name]-[hash] → chunk.name + content hash" {
    const a = std.testing.allocator;
    const bits = try chunk_mod.BitSet.init(a, 1);
    var ch = Chunk.init(@enumFromInt(0), .common, bits);
    defer ch.deinit(a);
    ch.name = "vendor";
    const h = wyhash.hashHex8(".v{}");
    const expect = try std.fmt.allocPrint(a, "vendor-{s}.css", .{h});
    defer a.free(expect);
    const r = try cssPathForChunk(a, &ch, "[name]-[hash]", ".v{}");
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
