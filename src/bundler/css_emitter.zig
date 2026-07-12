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

    var visited: std.AutoHashMapUnmanaged(ModuleIndex, void) = .empty;
    defer visited.deinit(allocator);

    collectCssModules(allocator, graph, entry_idx, &css_modules, &visited);

    if (css_modules.items.len == 0) return null;

    // exec_index 순으로 정렬 (CSS 출력 순서 = JS 실행 순서)
    std.mem.sort(*const Module, css_modules.items, {}, struct {
        fn lessThan(_: void, a: *const Module, b: *const Module) bool {
            return a.exec_index < b.exec_index;
        }
    }.lessThan);

    // CSS 소스 연결 (@import strip).
    // 보존 emit 영역 (출력 상단, CSS spec 순서):
    //   1. @charset (있으면 첫 byte 여야 함, 첫 모듈의 것만)
    //   2. external @import URL (#3321 P0-3)
    //   3. bare @layer 선언 (#3747)
    //   4. 본문 (strip_end 이후)
    // OOM 시 silent drop 회피 — collect / appendTo / appendCssModules 모두
    // error 시 null 반환.
    var output: std.ArrayListUnmanaged(u8) = .empty;
    defer output.deinit(allocator);

    // 출력 파일명을 본문보다 *먼저* 정한다 — url() 재작성이 출력 CSS 의 디렉토리를
    // 기준으로 상대경로를 만들어야 하기 때문 (#4466). 파일명 패턴은 본문 내용에
    // 의존하지 않으므로 순환은 없다.
    const entry_mod = graph.getModule(entry_idx) orelse return null;
    const entry_path = entry_mod.path;
    // PR B-4b sub-2: [dir] 토큰은 entry_dir-relative dir 로 치환. graph.entry_dir
    // 가 없으면(non-bundling 단일 emit) 빈 dir 폴백 — 토큰 + 인접 '/' skip.
    const entry_abs_dir = std.fs.path.dirname(entry_path) orelse "";
    const raw_dir = chunk_mod.entryRelativeDir(graph.entry_dir, entry_abs_dir);
    const css_path = applyCssNamingPattern(allocator, css_names, entry_path, raw_dir) catch return null;
    // 이 함수는 error union 이 아니라 `?OutputFile` 을 반환한다 — `errdefer` 는 아래의
    // 여러 `catch return null` 경로에서 **발동하지 않아** css_path 가 샌다.
    // 성공적으로 OutputFile 에 넘길 때만 소유권을 놓는 flag 로 관리한다.
    var css_path_owned = true;
    defer if (css_path_owned) allocator.free(css_path);
    const css_dir = std.fs.path.dirnamePosix(css_path) orelse "";

    var prefix_decls = PrefixDeclCollector.init();
    defer prefix_decls.deinit(allocator);
    for (css_modules.items) |mod| prefix_decls.collectFromModule(allocator, mod) catch return null;
    prefix_decls.appendCharsetTo(allocator, &output) catch return null;

    var ext_imports = ExternalImportCollector.init(allocator);
    defer ext_imports.deinit(allocator);
    for (css_modules.items) |mod| ext_imports.collectFromModule(allocator, mod) catch return null;
    ext_imports.appendTo(allocator, &output) catch return null;

    prefix_decls.appendLayersTo(allocator, &output) catch return null;

    appendCssModules(allocator, &output, graph, css_modules.items, css_dir) catch return null;

    if (output.items.len == 0) return null;

    const contents = output.toOwnedSlice(allocator) catch return null;
    css_path_owned = false; // 아래 OutputFile 로 소유권 이전
    return .{
        .path = css_path,
        .contents = contents,
    };
}

/// 정렬된 CSS 모듈들을 @import strip 후 줄바꿈 구분하여 buf 에 이어붙인다.
/// emitCssBundle(단일) / emitCssChunks(청크별) 가 공유.
///
/// `css_dir` = 출력 CSS 파일의 outdir 기준 디렉토리 ("" = outdir 루트).
/// 본문의 `url()` 자산 참조를 emit 된 자산 경로로 재작성할 때 상대경로 기준점이
/// 된다 (#4466).
fn appendCssModule(
    allocator: std.mem.Allocator,
    buf: *std.ArrayListUnmanaged(u8),
    graph: *const ModuleGraph,
    mod: *const Module,
    css_dir: []const u8,
) !void {
    const strip_end: u32 = if (mod.css_data) |cd| cd.strip_end else 0;
    // strip_end == source.len 케이스: @import 들로만 채워진 CSS (예: index aggregator
    // 가 모두 external @import). 옛 가드 `strip_end < source.len` 은 false →
    // 원본 통째 emit → ExternalImportCollector 의 prepend 와 합쳐져 같은 @import
    // 2회 출력. `<=` 로 boundary 포함시 빈 슬라이스 반환 → trimmed.len == 0 으로
    // early return.
    const body_start: u32 = if (strip_end > 0 and strip_end <= mod.source.len) strip_end else 0;
    const stripped = mod.source[body_start..];
    const trimmed = std.mem.trim(u8, stripped, " \t\n\r");
    if (trimmed.len == 0) return;

    try appendCssBodyRewritingUrls(allocator, buf, graph, mod, body_start, css_dir);

    if (stripped.len > 0 and stripped[stripped.len - 1] != '\n') {
        try buf.append(allocator, '\n');
    }
}

/// CSS 본문을 복사하면서 `.css_url` record 의 span 을 재작성된 자산 URL 로 치환한다.
///
/// record 의 span 은 `url(` 과 `)` *사이* 구간이라, 치환해도 `url(`/`)` 와 그 밖의
/// 모든 바이트(공백·주석·선언 순서)는 원문 그대로 보존된다. 재작성 대상이 없거나
/// resolve 실패한 record 는 원문을 그대로 흘려보낸다 — CSS 를 깨뜨리는 것보다
/// dangling 참조를 유지하는 쪽이 안전하고, 진단은 resolver 가 이미 냈다.
fn appendCssBodyRewritingUrls(
    allocator: std.mem.Allocator,
    buf: *std.ArrayListUnmanaged(u8),
    graph: *const ModuleGraph,
    mod: *const Module,
    body_start: u32,
    css_dir: []const u8,
) !void {
    const url_count: u32 = if (mod.css_data) |cd| cd.url_count else 0;
    if (url_count == 0) {
        try buf.appendSlice(allocator, mod.source[body_start..]);
        return;
    }

    // css_url record 는 parseCssModule 이 @import 뒤에 순서대로 넣는다 —
    // import_records 뒤쪽 url_count 개. span.start 오름차순이 보장된다
    // (extractCssUrls 가 좌→우 단일 패스).
    const records = mod.import_records;
    const url_start = records.len - url_count;

    var cursor: u32 = body_start;
    for (records[url_start..]) |rec| {
        if (rec.span.start < cursor or rec.span.end > mod.source.len) continue;

        const href = cssAssetHref(allocator, graph, rec, css_dir) catch null;
        if (href == null) continue; // 재작성 불가 → 원문 유지
        defer allocator.free(href.?);

        try buf.appendSlice(allocator, mod.source[cursor..rec.span.start]);
        try buf.append(allocator, '"');
        try appendCssStringEscaped(allocator, buf, href.?);
        try buf.append(allocator, '"');
        cursor = rec.span.end;
    }
    try buf.appendSlice(allocator, mod.source[cursor..]);
}

/// `.css_url` record 가 가리키는 자산의 최종 CSS href. 재작성 대상이 아니면 null.
///
/// - 파일로 방출된 자산(`asset_data`) → `--public-path` 접두, 없으면 출력 CSS
///   위치 기준 상대경로. `?query#fragment` suffix 는 원문 그대로 다시 붙인다.
/// - data URL 로 인라인된 자산(`asset_dataurl`) → data URL 그대로. suffix 는
///   붙이지 않는다 (data URL 에 `?#iefix` 를 이어붙이면 URL 이 깨진다).
fn cssAssetHref(
    allocator: std.mem.Allocator,
    graph: *const ModuleGraph,
    rec: @import("types.zig").ImportRecord,
    css_dir: []const u8,
) !?[]const u8 {
    if (rec.resolved.isNone()) return null;
    const asset = graph.getModule(rec.resolved) orelse return null;

    if (asset.asset_data) |ad| {
        if (graph.public_path.len > 0) {
            return try std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ graph.public_path, ad.output_name, rec.css_url_suffix });
        }
        const rel = try relativeUrlFrom(allocator, css_dir, ad.output_name);
        defer allocator.free(rel);
        return try std.fmt.allocPrint(allocator, "{s}{s}", .{ rel, rec.css_url_suffix });
    }

    if (asset.asset_dataurl.len > 0) {
        return try allocator.dupe(u8, asset.asset_dataurl);
    }

    // asset 이 아님 (예: `url(./other.css)` 처럼 CSS 를 가리키는 경우) → 원문 유지.
    return null;
}

/// outdir 기준 상대경로 `to_path` 를, 같은 outdir 기준의 `from_dir` 에서 가리키는
/// URL 로 변환한다. 둘 다 outdir 기준 `/` 구분 경로라 파일시스템을 건드리지 않는다.
///
/// ""          → "logo-a1.png"  ⇒ "./logo-a1.png"
/// "assets"    → "assets/x.png" ⇒ "./x.png"      (공통 prefix 제거)
/// "css"       → "assets/x.png" ⇒ "../assets/x.png"
fn relativeUrlFrom(allocator: std.mem.Allocator, from_dir: []const u8, to_path: []const u8) ![]const u8 {
    var from = std.mem.trim(u8, from_dir, "/");
    var to = to_path;

    // 공통 선행 세그먼트 제거 — `../a/x` 대신 `./x` 가 나오도록.
    while (from.len > 0) {
        const from_seg_end = std.mem.indexOfScalar(u8, from, '/') orelse from.len;
        const to_seg_end = std.mem.indexOfScalar(u8, to, '/') orelse break;
        if (!std.mem.eql(u8, from[0..from_seg_end], to[0..to_seg_end])) break;
        from = if (from_seg_end == from.len) "" else from[from_seg_end + 1 ..];
        to = to[to_seg_end + 1 ..];
    }

    // 남은 from 세그먼트 수만큼 상위로 올라간다.
    var up: usize = 0;
    if (from.len > 0) {
        up = 1;
        for (from) |c| {
            if (c == '/') up += 1;
        }
    }

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    if (up == 0) {
        try out.appendSlice(allocator, "./");
    } else {
        for (0..up) |_| try out.appendSlice(allocator, "../");
    }
    try out.appendSlice(allocator, to);
    return out.toOwnedSlice(allocator);
}

/// External @import URL (`http:`/`https:`/`//`/`data:`) 을 dedup 수집 + 출력 CSS
/// 상단에 보존 (#3321 P0-3, esbuild parity). CSS spec 상 모든 @import 는 모든
/// 일반 규칙보다 *앞* 에 와야 하므로 chunk 본문 emit 보다 먼저 호출.
///
/// dedup key = (specifier, condition_tail) tuple — `@import "x" print` 와
/// `@import "x" screen` 은 서로 다른 항목 (media-query 별 lookup 동작이 달라
/// silent drop 금지). condition_tail 도 함께 보존 emit.
///
/// 등장 순서 (모듈 emit 순회 시 첫 발견) 보존 — 결정적.
const ExternalImportEntry = struct {
    specifier: []const u8,
    condition_tail: []const u8,
};
const ExternalImportCollector = struct {
    /// key = "<specifier>\x00<condition_tail>" — `\x00` 은 CSS spec 상 합법
    /// URL/condition 에 등장 불가라 안전한 separator.
    seen: std.StringHashMapUnmanaged(void) = .empty,
    list: std.ArrayListUnmanaged(ExternalImportEntry),

    fn init(allocator: std.mem.Allocator) ExternalImportCollector {
        _ = allocator;
        return .{
            .seen = .empty,
            .list = .empty,
        };
    }

    fn deinit(self: *ExternalImportCollector, allocator: std.mem.Allocator) void {
        var kit = self.seen.keyIterator();
        while (kit.next()) |k| allocator.free(k.*);
        self.seen.deinit(allocator);
        self.list.deinit(allocator);
    }

    /// 모듈의 import_records 에서 external @import specifier 를 수집.
    /// entry 의 specifier/condition_tail 슬라이스는 record 가 가리키는 모듈
    /// parse_arena 소유 — chunk emit 동안만 사용하므로 안전.
    ///
    /// OOM 안전성: list.append 가 먼저 성공해야 seen.put 한다. 순서 반대면
    /// seen 만 들어가고 list 비어 `found_existing` 으로 영구 skip → silent
    /// drop 회귀.
    fn collectFromModule(self: *ExternalImportCollector, allocator: std.mem.Allocator, mod: *const Module) !void {
        for (mod.import_records) |rec| {
            // CSS 모듈의 import_records 에는 `@import`(.side_effect) 와 본문 url()
            // 자산(.css_url) 이 **함께** 들어있다 (#4466). 여기서 다루는 건 @import 뿐 —
            // kind 를 안 보면, `--packages=external` 등으로 external 판정된 url() 자산이
            // 출력 CSS 상단에 `@import "hero.png";` 로 튀어나와 브라우저가 PNG 를
            // stylesheet 로 fetch 한다.
            if (rec.kind == .css_url) continue;
            if (!rec.is_external) continue;
            if (rec.specifier.len == 0) continue;
            const composite_key = try std.fmt.allocPrint(allocator, "{s}\x00{s}", .{ rec.specifier, rec.css_condition_tail });
            errdefer allocator.free(composite_key);
            const gop = try self.seen.getOrPut(allocator, composite_key);
            if (gop.found_existing) {
                allocator.free(composite_key);
                continue;
            }
            // append 실패하면 errdefer 가 key 회수 + getOrPut 한 entry 도 제거.
            self.list.append(allocator, .{
                .specifier = rec.specifier,
                .condition_tail = rec.css_condition_tail,
            }) catch |e| {
                _ = self.seen.remove(composite_key);
                return e;
            };
        }
    }

    /// 수집된 external specifier 를 `@import "<url>"<tail>;\n` 형태로 buf 에
    /// prepend 가능한 위치(보통 buf 시작 또는 banner 직후)에 emit. 호출자가
    /// buf 의 적절한 시점에 호출해야 한다.
    ///
    /// specifier 안의 `"` 는 CSS spec 의 `\22` escape (16진수+공백) 로 안전
    /// 출력 — `data:text/css,body{content:"x"}` 같은 quote-포함 URL 도 invalid
    /// CSS / injection 표면 없이 보존.
    fn appendTo(self: *const ExternalImportCollector, allocator: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8)) !void {
        for (self.list.items) |entry| {
            try buf.appendSlice(allocator, "@import \"");
            try appendCssStringEscaped(allocator, buf, entry.specifier);
            try buf.append(allocator, '"');
            if (entry.condition_tail.len > 0) {
                try buf.appendSlice(allocator, entry.condition_tail);
            }
            try buf.appendSlice(allocator, ";\n");
        }
    }
};

/// 파일 상단 `@charset` / bare `@layer` 선언 보존 collector (#3747).
///
/// **@charset**: CSS spec 상 파일의 첫 byte 여야 valid, 1 stylesheet 에 1 개만
/// 효력. 번들에서 첫 발견 모듈의 charset 만 emit, 이후는 silent drop.
///
/// **@layer (bare)**: cascade layer 순서 정의. 모듈 등장 순서대로 모두 emit
/// (CSS spec: 추가 bare `@layer` 는 첫 등장이 ordering 고정 후 no-op 이라
/// 안전).
const PrefixDeclCollector = struct {
    /// 첫 발견 @charset text (예: `@charset "UTF-8"`). null = 미발견.
    charset_text: ?[]const u8 = null,
    /// bare @layer 선언 텍스트 등장 순서.
    layer_texts: std.ArrayListUnmanaged([]const u8) = .empty,

    fn init() PrefixDeclCollector {
        return .{};
    }

    fn deinit(self: *PrefixDeclCollector, allocator: std.mem.Allocator) void {
        self.layer_texts.deinit(allocator);
    }

    fn collectFromModule(self: *PrefixDeclCollector, allocator: std.mem.Allocator, mod: *const Module) !void {
        const cd = mod.css_data orelse return;
        for (cd.prefix_decls) |pd| {
            switch (pd.kind) {
                .charset => {
                    if (self.charset_text == null) self.charset_text = pd.text;
                    // 이후 charset 은 silent drop (CSS spec: 1 개만 효력).
                },
                .layer_bare => {
                    try self.layer_texts.append(allocator, pd.text);
                },
            }
        }
    }

    /// emit 순서: @charset (있으면 1줄) → caller 가 그 다음에 external @import +
    /// @layer 를 emit. 본 함수는 *charset* 만 prepend — @layer 는 별도 호출.
    /// (CSS spec: @charset 은 반드시 첫 byte. @layer 와 @import 는 상호 자유 순서.)
    fn appendCharsetTo(self: *const PrefixDeclCollector, allocator: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8)) !void {
        if (self.charset_text) |t| {
            try buf.appendSlice(allocator, t);
            try buf.appendSlice(allocator, ";\n");
        }
    }

    fn appendLayersTo(self: *const PrefixDeclCollector, allocator: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8)) !void {
        for (self.layer_texts.items) |t| {
            try buf.appendSlice(allocator, t);
            try buf.appendSlice(allocator, ";\n");
        }
    }
};

/// CSS double-quoted string literal 안전 escape. `"` → `\22 `, `\` → `\\`.
/// CSS spec §4.3.5 (Escape): hex escape `\<1-6 hex digits>` 다음 공백 1개로
/// terminate. 다음 문자가 hex 면 ambiguity → 항상 trailing space 부착.
fn appendCssStringEscaped(allocator: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try buf.appendSlice(allocator, "\\22 "),
            '\\' => try buf.appendSlice(allocator, "\\\\"),
            '\n' => try buf.appendSlice(allocator, "\\A "),
            '\r' => try buf.appendSlice(allocator, "\\D "),
            else => try buf.append(allocator, c),
        }
    }
}

fn appendCssModules(
    allocator: std.mem.Allocator,
    buf: *std.ArrayListUnmanaged(u8),
    graph: *const ModuleGraph,
    css_modules: []const *const Module,
    css_dir: []const u8,
) !void {
    for (css_modules) |mod| try appendCssModule(allocator, buf, graph, mod, css_dir);
}

/// CSS 모듈 트리를 dep-first 로 순회하며 @charset / @layer prefix decl 을
/// collector 에 모은다 (#3747). external @import 와 동일한 deps-first 순회.
fn collectPrefixDeclsTree(
    graph: *const ModuleGraph,
    idx: ModuleIndex,
    collector: *PrefixDeclCollector,
    visited: *std.AutoHashMapUnmanaged(ModuleIndex, void),
    allocator: std.mem.Allocator,
) !void {
    if (idx.isNone()) return;
    if (visited.contains(idx)) return;
    try visited.put(allocator, idx, {});
    const mod = graph.getModule(idx) orelse return;
    if (mod.module_type != .css) return;
    for (mod.dependencies.items) |dep| {
        if (graph.getModule(dep)) |dm| {
            if (dm.module_type == .css)
                try collectPrefixDeclsTree(graph, dep, collector, visited, allocator);
        }
    }
    try collector.collectFromModule(allocator, mod);
}

/// CSS 모듈 트리를 dep-first 로 순회하며 external @import URL 을 collector
/// 에 모은다. emit 트리 순회와 동일한 deps-before-importer 순서로 등장 순서
/// 결정성을 유지 (collector 의 list 가 first-seen order 보존).
fn collectExternalImportsTree(
    graph: *const ModuleGraph,
    idx: ModuleIndex,
    collector: *ExternalImportCollector,
    visited: *std.AutoHashMapUnmanaged(ModuleIndex, void),
    allocator: std.mem.Allocator,
) !void {
    if (idx.isNone()) return;
    if (visited.contains(idx)) return;
    try visited.put(allocator, idx, {});
    const mod = graph.getModule(idx) orelse return;
    if (mod.module_type != .css) return;
    for (mod.dependencies.items) |dep| {
        if (graph.getModule(dep)) |dm| {
            if (dm.module_type == .css)
                try collectExternalImportsTree(graph, dep, collector, visited, allocator);
        }
    }
    try collector.collectFromModule(allocator, mod);
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
    visited: *std.AutoHashMapUnmanaged(ModuleIndex, void),
    css_dir: []const u8,
) !void {
    if (idx.isNone()) return;
    if (visited.contains(idx)) return;
    // 함수가 `!void` 라 OOM 은 propagate — `catch return` 으로 삼키면 silent skip 되어
    // @import 서브트리가 emit 누락된다.
    try visited.put(allocator, idx, {});
    const mod = graph.getModule(idx) orelse return;
    if (mod.module_type != .css) return;
    for (mod.dependencies.items) |dep| {
        if (graph.getModule(dep)) |dm| {
            if (dm.module_type == .css) try emitCssModuleTree(allocator, graph, dep, buf, visited, css_dir);
        }
    }
    try appendCssModule(allocator, buf, graph, mod, css_dir);
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
    var chunk_mods: std.AutoHashMapUnmanaged(u32, std.ArrayListUnmanaged(*const Module)) = .empty;
    defer {
        var vit = chunk_mods.valueIterator();
        while (vit.next()) |list| list.deinit(allocator);
        chunk_mods.deinit(allocator);
    }
    // (chunk_idx, css_module_idx) 쌍 dedup — 한 청크 내 같은 CSS 1회.
    var chunk_seen: std.AutoHashMapUnmanaged(ChunkCssKey, void) = .empty;
    defer chunk_seen.deinit(allocator);
    var visited: std.AutoHashMapUnmanaged(ModuleIndex, void) = .empty;
    defer visited.deinit(allocator);

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
    var emit_visited: std.AutoHashMapUnmanaged(ModuleIndex, void) = .empty;
    defer emit_visited.deinit(allocator);

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

        // 보존 emit 영역 (chunk 단위 dedup, CSS spec 순서):
        //   1. @charset (chunk 첫 모듈의 것, #3747)
        //   2. external @import URL (#3321 P0-3)
        //   3. bare @layer (#3747)
        //   4. 본문
        // chunk 간 emit 은 허용 (모듈이 여러 chunk 에 인라인되면 각 chunk 의
        // 상단에 1 번씩 등장 — 런타임 fetch dedup 은 브라우저 책임).
        var prefix_decls = PrefixDeclCollector.init();
        defer prefix_decls.deinit(allocator);
        var ext_imports = ExternalImportCollector.init(allocator);
        defer ext_imports.deinit(allocator);

        emit_visited.clearRetainingCapacity();
        // prefix decl / external collect 는 emit 과 동일 dep 트리 순회 —
        // emitCssModuleTree 가 본문 emit 도중 visited 를 마킹해 같은 dep 가
        // 2번 walk 되지 않으므로 별도 일회 순회.
        var collect_visited: std.AutoHashMapUnmanaged(ModuleIndex, void) = .empty;
        defer collect_visited.deinit(allocator);
        for (list.items) |mod| {
            try collectPrefixDeclsTree(graph, mod.index, &prefix_decls, &collect_visited, allocator);
        }
        collect_visited.clearRetainingCapacity();
        for (list.items) |mod| {
            try collectExternalImportsTree(graph, mod.index, &ext_imports, &collect_visited, allocator);
        }
        try prefix_decls.appendCharsetTo(allocator, &buf);
        try ext_imports.appendTo(allocator, &buf);
        try prefix_decls.appendLayersTo(allocator, &buf);

        const cidx: ChunkIndex = @enumFromInt(@as(u32, @intCast(chunk_idx)));

        // url() 재작성이 출력 CSS 디렉토리 기준 상대경로를 만들어야 하는데, 최종
        // 경로는 내용 해시([hash])에 의존한다 → 순환. 디렉토리는 내용과 무관하므로
        // (패턴의 [dir]/리터럴 경로만 좌우) 빈 내용으로 한 번 계산해 dirname 만
        // 취한다. 패턴 해석을 복제하지 않아 cssPathForChunk 와 항상 일관 (#4466).
        const css_dir = blk: {
            const probe = try cssPathForChunk(allocator, chunk_graph.getChunk(cidx), css_names, "");
            defer allocator.free(probe);
            break :blk try allocator.dupe(u8, std.fs.path.dirnamePosix(probe) orelse "");
        };
        defer allocator.free(css_dir);

        for (list.items) |mod| {
            try emitCssModuleTree(allocator, graph, mod.index, &buf, &emit_visited, css_dir);
        }
        if (buf.items.len == 0) continue;

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

    // 두 entry 가 같은 stem(예: pages/a/index.tsx + pages/b/index.tsx) 이면
    // cssPathForChunk 가 둘 다 같은 path 를 반환해 writeOutputFiles 가 한쪽을
    // overwrite — silent CSS 손실. JS 청크 placeholder 와 달리 CSS 는 안정
    // 파일명(app-builder HTML link rewrite 호환) 을 위해 hash 를 강제하지 않는
    // 정책이라, 충돌이 *발생한 그룹에 한해서만* content-hash 를 자동 부여한다.
    // 그룹 내 contents 가 모두 같으면(우연한 동일 emit) overwrite 가 무해하므로
    // 건드리지 않는다 — 안정 파일명 invariant 유지.
    try disambiguatePathCollisions(allocator, out_list.items);

    return out_list.toOwnedSlice(allocator);
}

/// `planCssChunks` 내부에서 호출되는 CssChunkPlanEntry 용 wrapper.
/// 정책/메커니즘은 `disambiguatePathCollisionsGeneric` docstring 참조.
fn disambiguatePathCollisions(
    allocator: std.mem.Allocator,
    items: []CssChunkPlanEntry,
) !void {
    return disambiguatePathCollisionsGeneric(CssChunkPlanEntry, allocator, items);
}

/// `disambiguatePathCollisions` 의 OutputFile 용 wrapper. 비-splitting /
/// preserve-modules 경로(`bundler.zig` 의 `emitCssBundle` 루프) 가 entry 별
/// 단일 CSS 를 `css_output_files` 에 모은 뒤, splitting 경로와 같은 정책으로
/// path 충돌을 처리한다.
///
/// **호출자 계약** (`pub` 이지만 강한 invariant 의존):
/// - `items[i].path` 와 `items[i].contents` 는 모두 인자 `allocator` 가 alloc 한
///   슬라이스여야 한다 — 함수가 in-place 로 path 를 `free` + 새 path 로 swap.
///   static literal/arena/다른 allocator 슬라이스를 섞으면 mismatched-free 로 UB.
/// - `items` 안에 `.path` 외 다른 필드가 같은 path 문자열을 *참조* 하면(예:
///   sourcemap 의 file:, module_ids 가 entry path 를 borrow), swap 이후
///   그 참조는 stale 이 된다. 현재 CSS OutputFile 은 sourcemap/imports 등이
///   default 이라 안전 — 향후 채우는 PR 은 같이 update 또는 dedup 정책 명시 필요.
pub fn disambiguateOutputFilePaths(
    allocator: std.mem.Allocator,
    items: []OutputFile,
) !void {
    return disambiguatePathCollisionsGeneric(OutputFile, allocator, items);
}

/// path 충돌(`items[i].path` 가 동일 + `contents` 가 다름) 인 그룹에 한해
/// content-hash disambiguator(`<stem>-<wyhash8>.css`) 를 자동 부여한다.
/// 같은 path + 같은 contents 인 그룹은 그대로 둔다 — disk write last-wins
/// 가 무해하고, app-builder HTML link rewrite 의 안정 파일명 invariant 유지.
///
/// `T` 는 `.path: []const u8` 와 `.contents: []const u8` 두 필드를 갖는
/// 구조체여야 한다(`CssChunkPlanEntry`, `OutputFile`). 호출자가 잘못된 T 를
/// 넘기지 않도록 함수 시작에서 `comptime` 가드한다.
///
/// **두 패스 정책** — StringHashMap key-lifetime safety:
/// - 1패스: `items[i].path` 만 읽어 groups + new_paths(인덱스 i → 새 path 또는 null).
/// - 2패스: groups 를 *완전히 폐기* 한 뒤 `items[i].path` 를 free 하고 new_path 로 swap.
/// 이렇게 분리하면 groups 의 키(= `items[i].path` 슬라이스)가 살아있는 동안엔
/// free 가 발생하지 않아 use-after-free 가능성이 원천 차단된다 — 향후 본문에
/// groups 재조회를 추가하는 패치에도 안전. **2패스 본문에 fallible 호출을
/// 추가하지 말 것** — `new_paths[i] = null` 로 비우기 전에 error 가 나면
/// `errdefer` 가 swap 된 new path 를 again free 해 double-free 가 된다.
fn disambiguatePathCollisionsGeneric(
    comptime T: type,
    allocator: std.mem.Allocator,
    items: []T,
) !void {
    comptime {
        if (!@hasField(T, "path")) @compileError("disambiguatePathCollisionsGeneric: T must have field 'path'");
        if (!@hasField(T, "contents")) @compileError("disambiguatePathCollisionsGeneric: T must have field 'contents'");
    }
    if (items.len < 2) return;

    // 새 path 후보(없으면 null) — 1패스 결과를 2패스로 전달.
    const new_paths = try allocator.alloc(?[]const u8, items.len);
    defer allocator.free(new_paths);
    @memset(new_paths, null);
    // 1패스 도중 alloc 한 new_path 중 2패스에 도달 못한(=중간 OOM) 것을 정리.
    errdefer for (new_paths) |p| if (p) |s| allocator.free(s);

    {
        var groups: std.StringHashMapUnmanaged(std.ArrayListUnmanaged(usize)) = .empty;
        defer {
            var vit = groups.valueIterator();
            while (vit.next()) |list| list.deinit(allocator);
            groups.deinit(allocator);
        }
        for (items, 0..) |e, i| {
            const gop = try groups.getOrPut(allocator, e.path);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(allocator, i);
        }

        var git = groups.iterator();
        while (git.next()) |grp| {
            const idxs = grp.value_ptr.items;
            if (idxs.len < 2) continue;
            const ref = items[idxs[0]].contents;
            var all_same = true;
            for (idxs[1..]) |i| {
                if (!std.mem.eql(u8, items[i].contents, ref)) {
                    all_same = false;
                    break;
                }
            }
            if (all_same) continue;

            for (idxs) |i| {
                // 1패스에선 alloc 만 — items[i].path 는 아직 안 건드린다.
                new_paths[i] = try insertContentHash(allocator, items[i].path, items[i].contents);
            }
        }
        // 여기서 defer 블록이 돌며 groups 를 완전 해제. 이 시점 이후엔 groups 가
        // items[i].path 를 더 이상 키로 보지 않으므로 2패스의 free 가 안전.
    }

    // 2패스: 1패스에서 new_path 가 할당된 인덱스만 old 를 free 하고 swap.
    for (items, 0..) |*e, i| {
        if (new_paths[i]) |np| {
            allocator.free(e.path);
            e.path = np;
            new_paths[i] = null; // 더 이상 errdefer 가 회수하지 않게 비운다.
        }
    }
}

/// `path` 의 마지막 `.css` 확장자 직전에 `-<hash8>` 를 삽입한다. 확장자가
/// 없으면 끝에 그대로 붙인다(현재 경로 생성기는 항상 `.css` 보장).
fn insertContentHash(allocator: std.mem.Allocator, path: []const u8, contents: []const u8) ![]const u8 {
    const h = wyhash.hashHex8(contents);
    if (std.mem.endsWith(u8, path, ".css")) {
        const stem = path[0 .. path.len - 4];
        return std.fmt.allocPrint(allocator, "{s}-{s}.css", .{ stem, h });
    }
    return std.fmt.allocPrint(allocator, "{s}-{s}", .{ path, h });
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
    chunk_mods: *std.AutoHashMapUnmanaged(u32, std.ArrayListUnmanaged(*const Module)),
    chunk_seen: *std.AutoHashMapUnmanaged(ChunkCssKey, void),
    visited: *std.AutoHashMapUnmanaged(ModuleIndex, void),
) !void {
    if (idx.isNone()) return;
    if (visited.contains(idx)) return;
    // 함수가 `!void` 로 바뀌었으니 visited.put OOM 도 try 로 propagate.
    // 옛 `catch return` 은 silent skip → CSS 서브트리 누락 + 호출자가 OOM 도
    // 감지 못함. 같은 함수 내 chunk_seen/chunk_mods 가 try 를 쓰는 것과도 일관.
    try visited.put(allocator, idx, {});
    const mod = graph.getModule(idx) orelse return;

    if (mod.module_type == .css) {
        if (mod.css_data == null) return;
        const ci_u32 = @intFromEnum(ci);
        // 청크 단위 dedup — 같은 청크 안에서 여러 JS 모듈이 같은 CSS 도달해도 1회.
        const seen_gop = try chunk_seen.getOrPut(allocator, .{ .chunk = ci_u32, .css = idx });
        if (seen_gop.found_existing) return;
        const list_gop = try chunk_mods.getOrPut(allocator, ci_u32);
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
    // PR B-4a: chunk.name_dir 활성화 — `[dir]` 토큰이 패턴에 있으면 sanitize
    // 거친 entry-relative dir 가 치환된다. default 패턴(`[name]`) 엔 [dir] 토큰이
    // 없어 사용자 영향 0.
    const dir = chunk.name_dir orelse "";
    if (chunk.name) |n| return applyCssChunkNameWithDir(allocator, css_names, n, contents, dir);
    if (chunk.filename) |f| return applyCssChunkNameWithDir(allocator, css_names, std.fs.path.stem(f), contents, dir);
    // "chunk" (5) + u32 십진 최대 10자리 = 15 < 16 → bufPrint 실패 불가.
    var idx_buf: [16]u8 = undefined;
    const idx_name = std.fmt.bufPrint(&idx_buf, "chunk{d}", .{@intFromEnum(chunk.index)}) catch unreachable;
    return applyCssChunkNameWithDir(allocator, css_names, idx_name, contents, dir);
}

/// `css_names` 패턴의 `[name]`/`[hash]` 를 충실히 치환하고 `.css` 확장자를
/// 보장한다. `[hash]`(= CSS 내용 wyhash) 는 패턴에 명시됐을 때만 삽입한다 —
/// 강제 삽입은 app-builder 의 안정 파일명(`[name]`→`main.css`, HTML link
/// rewrite) 기대를 깨므로 하지 않는다. 캐시 버스팅이 필요하면 css_names 에
/// `[hash]` 를 넣는다(JS 청크의 entry_names/chunk_names 와 동일 계약).
/// `[dir]` 토큰을 지원하려면 `applyCssChunkNameWithDir` 를 사용한다 — 이
/// 4-arg 변형은 dir = "" 로 위임하므로 패턴에 [dir] 가 있어도 빈 dir 정리
/// 규칙(leading-slash 제거)이 동일 적용된다.
/// chunks.zig 의 `applyNamingPattern` 과 분리 유지 — 그쪽은 buffer 기반·[ext]
/// 처리이고 여기는 CSS 전용(.css 보장)이라 의미가 다르다.
fn applyCssChunkName(
    allocator: std.mem.Allocator,
    pattern: []const u8,
    stem: []const u8,
    contents: []const u8,
) ![]const u8 {
    return applyCssChunkNameWithDir(allocator, pattern, stem, contents, "");
}

/// `applyCssChunkName` 의 [dir] 토큰 지원 변형. JS 의
/// `chunks.applyNamingPatternWithDir` 와 동일 규칙으로 [dir] 을 처리해 JS/
/// CSS naming 일관성을 유지한다(F5: PR B-2 의 목적).
///
/// **빈 dir 정리 규칙** — esbuild parity:
/// [dir] 가 빈 문자열로 치환될 때, 토큰 *바로 다음* 문자가 `/` 면 그
/// 슬래시도 함께 skip 해 leading/double-slash 를 방지한다.
/// dir 안 Windows 백슬래시는 URL 구분자 `/` 로 정규화한다.
///
/// 현재 PR(B-2)에선 `applyCssChunkName` 만 새 함수에 위임하고, 호출자
/// (`cssPathForChunk`) 는 여전히 4-arg 시그니처로 dir 정보 미전달 — PR B-4
/// 가 호출자도 `chunk.name_dir` 활용하도록 활성화 예정.
fn applyCssChunkNameWithDir(
    allocator: std.mem.Allocator,
    pattern: []const u8,
    stem: []const u8,
    contents: []const u8,
    dir: []const u8,
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
        } else if (std.mem.startsWith(u8, pattern[i..], "[dir]")) {
            if (dir.len > 0) {
                for (dir) |c| {
                    try out.append(allocator, if (c == '\\') '/' else c);
                }
                i += "[dir]".len;
            } else {
                // 빈 dir — 토큰만 skip + 인접한 '/' 도 함께 skip (esbuild parity).
                i += "[dir]".len;
                if (i < pattern.len and pattern[i] == '/') i += 1;
            }
        } else {
            try out.append(allocator, pattern[i]);
            i += 1;
        }
    }
    // PR B-3 가드:
    // (1) C1 degenerate pattern: stem 부분(.css 확장자 제외)이 비었거나 슬래시
    //     뿐이면 모든 청크가 같은 path 로 collision. fallback "chunk" stem 으로
    //     대체해 사용자가 비정상 패턴을 즉시 인지하게 한다. 패턴 `[dir]` 단독,
    //     `[dir]/[name].css` + 빈 stem, `/` 단독 등 모두 커버.
    // (2) C6 대소문자: `endsWith(".css")` 가 대소문자 구분이라 `.CSS` 패턴 시
    //     `.css.css` 이중 추가. case-insensitive 비교로 보정.
    const has_css_ext = out.items.len >= 4 and asciiEqIgnoreCase(out.items[out.items.len - 4 ..], ".css");
    const stem_part = if (has_css_ext) out.items[0 .. out.items.len - 4] else out.items;
    const stem_empty = stem_part.len == 0 or allCharsAreSlash(stem_part);
    if (stem_empty) {
        // 결과가 사실상 "<slashes?>.css?" 형태 — 통째로 버리고 fallback 대체.
        out.clearRetainingCapacity();
        try out.appendSlice(allocator, "chunk.css");
    } else if (!has_css_ext) {
        try out.appendSlice(allocator, ".css");
    }
    return out.toOwnedSlice(allocator);
}

fn asciiEqIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        const xl = if (x >= 'A' and x <= 'Z') x + 32 else x;
        const yl = if (y >= 'A' and y <= 'Z') y + 32 else y;
        if (xl != yl) return false;
    }
    return true;
}

fn allCharsAreSlash(s: []const u8) bool {
    for (s) |c| if (c != '/') return false;
    return true;
}

/// DFS로 모듈 그래프를 탐색하여 CSS 모듈을 수집한다.
fn collectCssModules(
    allocator: std.mem.Allocator,
    graph: *const ModuleGraph,
    idx: ModuleIndex,
    result: *std.ArrayListUnmanaged(*const Module),
    visited: *std.AutoHashMapUnmanaged(ModuleIndex, void),
) void {
    if (idx == .none) return;
    if (visited.contains(idx)) return;
    const mod = graph.getModule(idx) orelse return;
    visited.put(allocator, idx, {}) catch return;

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
/// `[name]` → 엔트리 파일의 basename (확장자 제거).
/// `[dir]`  → entry_dir-relative dir (caller 가 entryRelativeDir 로 계산해 전달).
/// `[hash]` 는 본 entry-단위 single-bundle 경로에선 미지원 — content-hash 가
/// 필요한 사용자는 splitting:true (planCssChunks 경로) 사용.
/// 빈 `dir` 폴백: 토큰 + 인접 `/` 함께 skip — esbuild parity (applyCssChunkNameWithDir 와 동일 규칙).
fn applyCssNamingPattern(
    allocator: std.mem.Allocator,
    pattern: []const u8,
    entry_path: []const u8,
    dir: []const u8,
) ![]const u8 {
    // 엔트리 파일의 basename 추출 (확장자 제거)
    const basename = std.fs.path.basename(entry_path);
    const name = if (std.mem.lastIndexOf(u8, basename, ".")) |dot|
        basename[0..dot]
    else
        basename;

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < pattern.len) {
        if (std.mem.startsWith(u8, pattern[i..], "[name]")) {
            try out.appendSlice(allocator, name);
            i += "[name]".len;
        } else if (std.mem.startsWith(u8, pattern[i..], "[dir]")) {
            if (dir.len > 0) {
                for (dir) |c| try out.append(allocator, if (c == '\\') '/' else c);
                i += "[dir]".len;
            } else {
                i += "[dir]".len;
                if (i < pattern.len and pattern[i] == '/') i += 1;
            }
        } else {
            try out.append(allocator, pattern[i]);
            i += 1;
        }
    }
    try out.appendSlice(allocator, ".css");
    // degenerate (e.g. pattern="[dir]" + 빈 dir → ".css") fallback.
    if (out.items.len <= ".css".len) {
        out.clearRetainingCapacity();
        try out.appendSlice(allocator, "chunk.css");
    }
    return out.toOwnedSlice(allocator);
}

// ============================================================
// 테스트
// ============================================================

test "applyCssNamingPattern: default pattern" {
    const result = try applyCssNamingPattern(std.testing.allocator, "[name]", "/app/src/index.ts", "");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("index.css", result);
}

test "applyCssNamingPattern: custom pattern" {
    const result = try applyCssNamingPattern(std.testing.allocator, "styles/[name]", "/app/src/main.tsx", "");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("styles/main.css", result);
}

test "applyCssNamingPattern: [dir] token + entry-relative dir" {
    const r = try applyCssNamingPattern(std.testing.allocator, "[dir]/[name]", "/app/src/pages-a/index.ts", "pages-a");
    defer std.testing.allocator.free(r);
    try std.testing.expectEqualStrings("pages-a/index.css", r);
}

test "applyCssNamingPattern: [dir]/[name] with empty dir skips token + slash" {
    // F7 회귀 가드: 새 default `[dir]/[name]` + 빈 dir → literal `[dir]/` 가
    // 파일명에 baked 되던 버그. 빈 dir 시 토큰 + 인접 `/` 함께 skip.
    const r = try applyCssNamingPattern(std.testing.allocator, "[dir]/[name]", "/app/src/index.ts", "");
    defer std.testing.allocator.free(r);
    try std.testing.expectEqualStrings("index.css", r);
}

test "applyCssChunkName: empty stem → 'chunk.css' fallback (PR B-3 — silent collision 차단)" {
    // PR B-3 이전엔 빈 stem 이 ".css" 로 출력됐고, 여러 청크가 빈 stem 일
    // 경우 모두 동일 path 로 collision 했다. 이제 fallback "chunk" stem 으로
    // 대체 (사용자가 비정상 입력을 즉시 인지). cssPathForChunk 의 정상 경로는
    // chunk.name/filename/idx fallback 으로 항상 non-empty stem 을 만든다.
    const a = std.testing.allocator;
    const r = try applyCssChunkName(a, "[name]", "", ".");
    defer a.free(r);
    try std.testing.expectEqualStrings("chunk.css", r);
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

// PR B-2: applyCssChunkNameWithDir — JS chunks 의 applyNamingPatternWithDir
// 와 동일한 [dir] 토큰 정책을 CSS naming 에도 적용. 기존 applyCssChunkName
// 시그니처는 보존(dir = "" 로 위임). 호출자(cssPathForChunk) 가 활성화하는
// 시점은 PR B-4 — 본 PR scope 에선 함수만 추가, 영향 0.

test "applyCssChunkNameWithDir: [dir]/[name] with dir" {
    const a = std.testing.allocator;
    const r = try applyCssChunkNameWithDir(a, "[dir]/[name]", "main", ".x{}", "pages-a");
    defer a.free(r);
    try std.testing.expectEqualStrings("pages-a/main.css", r);
}

test "applyCssChunkNameWithDir: 빈 dir → leading slash 제거" {
    // 단일 entry cwd 루트 또는 entry_dir 미설정 → dir == "" → [dir]/ 토큰이
    // leading slash 만들지 않도록 [dir]+다음 '/' 를 함께 skip (esbuild parity).
    const a = std.testing.allocator;
    const r = try applyCssChunkNameWithDir(a, "[dir]/[name]", "main", ".x{}", "");
    defer a.free(r);
    try std.testing.expectEqualStrings("main.css", r);
}

test "applyCssChunkNameWithDir: 중간 [dir]+빈 문자열 → 인접 '/' skip" {
    // "assets/[dir]/[name]" + 빈 dir → "assets/main.css" (double-slash 방지).
    const a = std.testing.allocator;
    const r = try applyCssChunkNameWithDir(a, "assets/[dir]/[name]", "main", ".x{}", "");
    defer a.free(r);
    try std.testing.expectEqualStrings("assets/main.css", r);
}

test "applyCssChunkNameWithDir: [dir]/[name]-[hash] 전 토큰 결합" {
    const a = std.testing.allocator;
    const h = wyhash.hashHex8(".x{}");
    const r = try applyCssChunkNameWithDir(a, "[dir]/[name]-[hash]", "main", ".x{}", "pages-b");
    defer a.free(r);
    const expect = try std.fmt.allocPrint(a, "pages-b/main-{s}.css", .{h});
    defer a.free(expect);
    try std.testing.expectEqualStrings(expect, r);
}

test "applyCssChunkNameWithDir: Windows 백슬래시 정규화" {
    const a = std.testing.allocator;
    const r = try applyCssChunkNameWithDir(a, "[dir]/[name]", "x", ".x{}", "win\\sub");
    defer a.free(r);
    try std.testing.expectEqualStrings("win/sub/x.css", r);
}

test "applyCssChunkName (기존 시그니처) 호환 — dir 없는 호출은 그대로" {
    // 옛 API 호환: dir 인자가 없는 4-arg 호출은 [dir] 토큰이 패턴에 있어도
    // 빈 dir 로 동작 — leading-slash 정리 동일 적용.
    const a = std.testing.allocator;
    const r1 = try applyCssChunkName(a, "[name]", "x", ".x{}");
    defer a.free(r1);
    try std.testing.expectEqualStrings("x.css", r1);
    const r2 = try applyCssChunkName(a, "[dir]/[name]", "x", ".x{}");
    defer a.free(r2);
    try std.testing.expectEqualStrings("x.css", r2);
}

// PR B-3 가드.

test "applyCssChunkName: C1 degenerate pattern — [dir] 단독 + 빈 dir → 'chunk.css' fallback" {
    // 사용자가 잘못 작성한 패턴(stem 토큰 누락)에서 빈 stem 으로 모든 청크가
    // 동일 `.css` 로 collision 되던 silent loss 차단. fallback 'chunk' stem
    // prepend.
    const a = std.testing.allocator;
    const r = try applyCssChunkName(a, "[dir]", "main", ".x{}");
    defer a.free(r);
    try std.testing.expectEqualStrings("chunk.css", r);
}

test "applyCssChunkName: C1 빈 패턴 → 'chunk.css' fallback" {
    const a = std.testing.allocator;
    const r = try applyCssChunkName(a, "", "main", ".x{}");
    defer a.free(r);
    try std.testing.expectEqualStrings("chunk.css", r);
}

test "applyCssChunkName: C1 슬래시만 있는 패턴 → 'chunk.css' fallback" {
    const a = std.testing.allocator;
    const r = try applyCssChunkName(a, "/", "main", ".x{}");
    defer a.free(r);
    try std.testing.expectEqualStrings("chunk.css", r);
}

test "applyCssChunkName: C6 대소문자 무시 — .CSS 패턴 시 이중 추가 방지" {
    const a = std.testing.allocator;
    const r = try applyCssChunkName(a, "[name].CSS", "main", ".x{}");
    defer a.free(r);
    // .CSS 가 이미 있으므로 .css 자동 추가 안 함.
    try std.testing.expectEqualStrings("main.CSS", r);
}

test "applyCssChunkName: C6 mixed case 처리" {
    const a = std.testing.allocator;
    const r = try applyCssChunkName(a, "[name].Css", "main", ".x{}");
    defer a.free(r);
    try std.testing.expectEqualStrings("main.Css", r);
}

test "applyCssChunkName: 정상 패턴은 fallback 동작 안 함" {
    // C1 fallback 이 정상 케이스에 잘못 끼어들지 않는지 회귀 가드.
    const a = std.testing.allocator;
    const r = try applyCssChunkName(a, "[name]", "main", ".x{}");
    defer a.free(r);
    try std.testing.expectEqualStrings("main.css", r);
}

test "applyCssChunkName: '.css' literal 패턴 + 빈 stem → 'chunk.css' fallback (C1 정밀화)" {
    // pattern `[name].css` 가 빈 stem 와 결합하면 결과가 `.css` — has_css_ext
    // true 라 이전엔 fallback skip 됐다. PR B-3 가 stem 부분(확장자 제외) 검사로
    // 정밀화 → 빈 stem 인식 → 'chunk.css' 로 대체.
    const a = std.testing.allocator;
    const r = try applyCssChunkName(a, "[name].css", "", ".x{}");
    defer a.free(r);
    try std.testing.expectEqualStrings("chunk.css", r);
}

test "applyCssChunkName: '.css' literal 패턴 + 슬래시뿐인 stem → 'chunk.css'" {
    const a = std.testing.allocator;
    const r = try applyCssChunkName(a, "/[name].css", "", ".x{}");
    defer a.free(r);
    try std.testing.expectEqualStrings("chunk.css", r);
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

test "insertContentHash: .css 확장자 직전에 -<hash> 삽입" {
    const a = std.testing.allocator;
    const r = try insertContentHash(a, "index.css", ".x{}");
    defer a.free(r);
    const h = wyhash.hashHex8(".x{}");
    const expect = try std.fmt.allocPrint(a, "index-{s}.css", .{h});
    defer a.free(expect);
    try std.testing.expectEqualStrings(expect, r);
}

test "insertContentHash: subdir 보존" {
    const a = std.testing.allocator;
    const r = try insertContentHash(a, "assets/page.css", ".y{}");
    defer a.free(r);
    const h = wyhash.hashHex8(".y{}");
    const expect = try std.fmt.allocPrint(a, "assets/page-{s}.css", .{h});
    defer a.free(expect);
    try std.testing.expectEqualStrings(expect, r);
}

test "insertContentHash: 확장자 없으면 끝에 -<hash>" {
    const a = std.testing.allocator;
    const r = try insertContentHash(a, "noext", ".z{}");
    defer a.free(r);
    const h = wyhash.hashHex8(".z{}");
    const expect = try std.fmt.allocPrint(a, "noext-{s}", .{h});
    defer a.free(expect);
    try std.testing.expectEqualStrings(expect, r);
}

test "disambiguatePathCollisions: 같은 path + 다른 contents 면 양쪽에 hash 부여" {
    const a = std.testing.allocator;
    var items = [_]CssChunkPlanEntry{
        .{ .chunk_index = 0, .path = try a.dupe(u8, "index.css"), .contents = try a.dupe(u8, ".a{}") },
        .{ .chunk_index = 1, .path = try a.dupe(u8, "index.css"), .contents = try a.dupe(u8, ".b{}") },
    };
    defer {
        for (items) |e| {
            a.free(e.path);
            a.free(e.contents);
        }
    }
    try disambiguatePathCollisions(a, &items);
    // 둘 다 path 가 변경(hash 부여) 됐어야 한다.
    try std.testing.expect(!std.mem.eql(u8, items[0].path, items[1].path));
    try std.testing.expect(std.mem.startsWith(u8, items[0].path, "index-"));
    try std.testing.expect(std.mem.startsWith(u8, items[1].path, "index-"));
    try std.testing.expect(std.mem.endsWith(u8, items[0].path, ".css"));
    try std.testing.expect(std.mem.endsWith(u8, items[1].path, ".css"));
}

test "disambiguatePathCollisions: 같은 path + 같은 contents 면 그대로(stable 파일명 유지)" {
    const a = std.testing.allocator;
    var items = [_]CssChunkPlanEntry{
        .{ .chunk_index = 0, .path = try a.dupe(u8, "index.css"), .contents = try a.dupe(u8, ".a{}") },
        .{ .chunk_index = 1, .path = try a.dupe(u8, "index.css"), .contents = try a.dupe(u8, ".a{}") },
    };
    defer {
        for (items) |e| {
            a.free(e.path);
            a.free(e.contents);
        }
    }
    try disambiguatePathCollisions(a, &items);
    try std.testing.expectEqualStrings("index.css", items[0].path);
    try std.testing.expectEqualStrings("index.css", items[1].path);
}

test "disambiguatePathCollisions: 충돌 없는 그룹은 그대로" {
    const a = std.testing.allocator;
    var items = [_]CssChunkPlanEntry{
        .{ .chunk_index = 0, .path = try a.dupe(u8, "a.css"), .contents = try a.dupe(u8, ".a{}") },
        .{ .chunk_index = 1, .path = try a.dupe(u8, "b.css"), .contents = try a.dupe(u8, ".b{}") },
    };
    defer {
        for (items) |e| {
            a.free(e.path);
            a.free(e.contents);
        }
    }
    try disambiguatePathCollisions(a, &items);
    try std.testing.expectEqualStrings("a.css", items[0].path);
    try std.testing.expectEqualStrings("b.css", items[1].path);
}

test "disambiguatePathCollisions: 3 way 충돌 + 부분 contents 동일" {
    const a = std.testing.allocator;
    var items = [_]CssChunkPlanEntry{
        .{ .chunk_index = 0, .path = try a.dupe(u8, "index.css"), .contents = try a.dupe(u8, ".a{}") },
        .{ .chunk_index = 1, .path = try a.dupe(u8, "index.css"), .contents = try a.dupe(u8, ".a{}") },
        .{ .chunk_index = 2, .path = try a.dupe(u8, "index.css"), .contents = try a.dupe(u8, ".c{}") },
    };
    defer {
        for (items) |e| {
            a.free(e.path);
            a.free(e.contents);
        }
    }
    try disambiguatePathCollisions(a, &items);
    // 그룹 안 contents 가 *모두 같지는 않으므로* 전원에 hash 부여.
    // (부분 동일을 미세하게 처리하면 결정성 + 단순성 모두 깨짐.)
    try std.testing.expect(std.mem.startsWith(u8, items[0].path, "index-"));
    try std.testing.expect(std.mem.startsWith(u8, items[1].path, "index-"));
    try std.testing.expect(std.mem.startsWith(u8, items[2].path, "index-"));
    // 같은 contents 인 0,1 은 같은 hash → 같은 path (디스크 overwrite 무해)
    try std.testing.expectEqualStrings(items[0].path, items[1].path);
    try std.testing.expect(!std.mem.eql(u8, items[0].path, items[2].path));
}

test "disambiguateOutputFilePaths: OutputFile 충돌 그룹에도 동일 정책" {
    const a = std.testing.allocator;
    var items = [_]OutputFile{
        .{ .path = try a.dupe(u8, "index.css"), .contents = try a.dupe(u8, ".a{}") },
        .{ .path = try a.dupe(u8, "index.css"), .contents = try a.dupe(u8, ".b{}") },
    };
    defer {
        for (items) |e| {
            a.free(e.path);
            a.free(e.contents);
        }
    }
    try disambiguateOutputFilePaths(a, &items);
    try std.testing.expect(!std.mem.eql(u8, items[0].path, items[1].path));
    try std.testing.expect(std.mem.startsWith(u8, items[0].path, "index-"));
    try std.testing.expect(std.mem.startsWith(u8, items[1].path, "index-"));
}

test "disambiguateOutputFilePaths: 같은 contents 면 stable 파일명 유지" {
    const a = std.testing.allocator;
    var items = [_]OutputFile{
        .{ .path = try a.dupe(u8, "shared.css"), .contents = try a.dupe(u8, ".s{}") },
        .{ .path = try a.dupe(u8, "shared.css"), .contents = try a.dupe(u8, ".s{}") },
    };
    defer {
        for (items) |e| {
            a.free(e.path);
            a.free(e.contents);
        }
    }
    try disambiguateOutputFilePaths(a, &items);
    try std.testing.expectEqualStrings("shared.css", items[0].path);
    try std.testing.expectEqualStrings("shared.css", items[1].path);
}
