//! ZNTC Source Map V3
//!
//! 소스맵 V3 생성기. VLQ 인코딩 + JSON 출력.
//!
//! 소스맵 V3 형식:
//!   {
//!     "version": 3,
//!     "file": "output.js",
//!     "sourceRoot": "",
//!     "sources": ["input.ts"],
//!     "names": [],
//!     "mappings": "AAAA,IAAI,CAAC,GAAG"
//!   }
//!
//! mappings: 세미콜론(;)으로 줄 구분, 콤마(,)로 세그먼트 구분.
//! 각 세그먼트: [출력열, 소스인덱스, 소스줄, 소스열, 이름인덱스] (VLQ 인코딩)
//!
//! 참고:
//! - references/esbuild/internal/sourcemap/sourcemap.go
//! - references/swc/crates/swc_sourcemap/src/vlq.rs

const std = @import("std");

// ============================================================
// VLQ Base64 인코딩 (D046)
// ============================================================

const base64_chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

/// VLQ (Variable-Length Quantity) 인코딩.
///
/// 동작 원리:
///   1. 부호 비트를 bit 0으로 이동 (음수면 1, 양수면 0)
///   2. 5비트씩 잘라서 base64 문자로 변환
///   3. 다음 청크가 있으면 continuation bit (bit 5) 설정
///
/// 예: 16 → 0b100000 → sign=0, 값=16 → 0b00001_00000
///     → 첫 digit: 00000 | continuation=1 → 'g' (32)
///     → 둘째 digit: 00001 | continuation=0 → 'B' (1)
///     → "gB"
pub fn encodeVLQ(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), value: i32) !void {
    // 부호 처리: bit 0 = sign, 나머지 = magnitude
    var v: u32 = if (value < 0)
        (@as(u32, @intCast(-value)) << 1) | 1
    else
        @as(u32, @intCast(value)) << 1;

    // 5비트씩 잘라서 base64 인코딩
    while (true) {
        var digit: u8 = @truncate(v & 0x1F); // 하위 5비트
        v >>= 5;
        if (v > 0) {
            digit |= 0x20; // continuation bit
        }
        try buf.append(allocator, base64_chars[digit]);
        if (v == 0) break;
    }
}

// ============================================================
// 소스맵 매핑 세그먼트
// ============================================================

/// 소스맵의 단일 매핑 세그먼트.
/// 출력 파일의 특정 위치가 소스의 어디에 대응하는지를 나타냄.
pub const Mapping = struct {
    /// 출력 파일의 줄 (0-based)
    generated_line: u32,
    /// 출력 파일의 열 (0-based)
    generated_column: u32,
    /// 소스 파일 인덱스 (sources 배열)
    source_index: u32 = 0,
    /// 소스 파일의 줄 (0-based)
    original_line: u32,
    /// 소스 파일의 열 (0-based)
    original_column: u32,
    /// names 배열 인덱스 (mangler rename 발생 시 원본 이름). null 이면 5-segment VLQ
    /// (line/col/source/orig_line/orig_col), non-null 이면 6-segment (+name_index).
    /// Sentry 같은 도구가 minified 식별자의 원본 이름을 복원하는 데 사용.
    name_index: ?u32 = null,

    pub fn lessThan(_: void, a: Mapping, b: Mapping) bool {
        if (a.generated_line != b.generated_line) return a.generated_line < b.generated_line;
        return a.generated_column < b.generated_column;
    }
};

// ============================================================
// 소스맵 옵션
// ============================================================

/// 소스맵 출력 형식 — esbuild / rolldown 호환 3-mode (#2152).
///
///  - `linked`   (default): `.map` 파일 emit + `//# sourceMappingURL=<file>.map` 주석.
///  - `external`           : `.map` 파일 emit, URL 주석 없음 — Sentry/CI 표준 (소스맵
///                           위치 비공개).
///  - `inline`             : `.map` 파일 emit 안 함, JSON 을 base64 data URL 로 주석에 embed
///                           (`//# sourceMappingURL=data:application/json;base64,...`).
pub const SourceMapMode = enum {
    linked,
    external,
    inline_,

    /// CLI / NAPI string 입력을 enum 으로 변환. invalid 면 null.
    pub fn fromString(s: []const u8) ?SourceMapMode {
        if (std.mem.eql(u8, s, "linked")) return .linked;
        if (std.mem.eql(u8, s, "external")) return .external;
        if (std.mem.eql(u8, s, "inline")) return .inline_;
        return null;
    }
};

/// `appendSourceMappingURLComment` 의 입력. mode 별 conditional 인자를 struct
/// 로 묶어 호출 사이트 명료성 + default 활용.
pub const SourceMappingURLOptions = struct {
    mode: SourceMapMode,
    /// `linked` mode 에서 `<output_filename>.map` 형태로 부착되는 base 파일명.
    /// helper 가 `.map` 확장자를 자동 추가하므로 caller 는 .map 빼고 전달.
    /// `external` / `inline_` mode 에서는 무시.
    output_filename: []const u8 = "",
    /// `linked` mode 의 URL 앞에 `/` 를 부착해 dev server 절대 경로로 만든다.
    /// 다른 mode 에서는 무시.
    prefix_slash: bool = false,
    /// `inline_` mode 에서 base64 embed 할 JSON. caller 소유 — helper 는 base64
    /// encode 만 수행, free 는 `inline_json_slot` 가 담당. 다른 mode 에서는 무시.
    inline_json: ?[]const u8 = null,
};

/// `//# sourceMappingURL=` 주석을 mode 별로 output 에 부착한다. emitter.zig
/// (단일 번들) 와 chunks.zig 두 사이트가 동일한 분기 정책을 공유하도록 통합
/// (#2660).
///
/// - `linked`: `//# sourceMappingURL=<output_filename>.map\n` (옵션의
///   `prefix_slash` true 면 dev server 라우팅용 `/` prefix 부착)
/// - `external`: 주석 없음
/// - `inline_`: `options.inline_json` 의 base64 를 contents 에 embed. base64
///   embed 후 `inline_json_slot.*` 을 `free` + `null` 로 갱신해 caller 의
///   free 책임을 helper 가 인수. `inline_json_slot` 이 null 이면 (linked /
///   external 호출 등) slot 갱신은 skip.
///
/// `inline_json_slot` 은 inline_ 호출자가 owned slice 의 slot pointer 를 넘겨
/// helper 가 free + null 로 ownership 이전. linked / external 만 사용하는
/// caller 는 null 전달 가능.
pub fn appendSourceMappingURLComment(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    options: SourceMappingURLOptions,
    inline_json_slot: ?*?[]const u8,
) !void {
    switch (options.mode) {
        .linked => {
            try output.appendSlice(allocator, "//# sourceMappingURL=");
            if (options.prefix_slash) try output.append(allocator, '/');
            try output.appendSlice(allocator, options.output_filename);
            try output.appendSlice(allocator, ".map\n");
        },
        .external => {},
        .inline_ => {
            if (options.inline_json) |json| {
                try output.appendSlice(allocator, "//# sourceMappingURL=data:application/json;base64,");
                const Encoder = std.base64.standard.Encoder;
                const encoded_len = Encoder.calcSize(json.len);
                const old_len = output.items.len;
                try output.resize(allocator, old_len + encoded_len);
                _ = Encoder.encode(output.items[old_len .. old_len + encoded_len], json);
                try output.append(allocator, '\n');
                allocator.free(json);
                if (inline_json_slot) |slot| slot.* = null;
            }
        },
    }
}

/// Bundler 레벨 sourcemap 옵션 묶음. `EmitOptions.sourcemap` / `BundleOptions.sourcemap`
/// 양쪽에서 동일 구조체를 공유해 옵션 전파 중복을 제거한다. 단일-파일 경로
/// (`codegen.zig`, `transpile.zig`) 는 별도 옵션 구조체가 있어 현재 범위 밖.
pub const SourceMapOptions = struct {
    /// 소스맵 생성 활성화. dev mode 에서는 번들 레벨 소스맵을 생성한다.
    enable: bool = false,
    /// 출력 형식 — `enable=true` 일 때만 의미 있음.
    mode: SourceMapMode = .linked,
    /// Sentry Debug ID (`--sourcemap-debug-ids`). 번들 끝에 `//# debugId=<UUID>` 주석 추가 +
    /// 소스맵 JSON 에 `"debugId"` 필드 삽입. 번들과 맵에 동일 UUID 를 공유.
    debug_ids: bool = false,
    /// Metro `x_facebook_sources` function map (`--sourcemap-function-map`).
    /// Hermes 스택트레이스 심볼리케이션용. RN 플랫폼에서 자동 활성화.
    function_map: bool = false,
    /// Lazy sourcemap 경로 (Issue #1727 Phase B, Metro `_processSourceMapRequest` 패턴).
    /// true 면 emit 단계에서 JSON 을 생성하지 않고 `SourceMapBuilder` 를 result 로 이관.
    /// NAPI handle 이 요청 시 `generateJSON` 을 호출. `enable=false` 이면 무시된다.
    lazy: bool = false,
    /// sourceRoot 필드 값 (`--source-root`).
    source_root: ?[]const u8 = null,
    /// sourcesContent 포함 여부 (`--sources-content=false` 로 비활성).
    sources_content: bool = true,
};

// ============================================================
// 소스맵 빌더
// ============================================================

pub const SourceMapBuilder = struct {
    mappings: std.ArrayList(Mapping),
    sources: std.ArrayList([]const u8),
    /// 소스 파일 내용 (sourcesContent 배열용). addSourceContent()로 추가.
    source_contents: std.ArrayList([]const u8),
    buf: std.ArrayList(u8),
    allocator: std.mem.Allocator,
    /// sourceRoot 필드 값. 빈 문자열이면 ""로 출력.
    source_root: []const u8 = "",
    /// sourcesContent 포함 여부. true이고 source_contents가 비어있지 않으면 JSON에 포함.
    sources_content: bool = true,
    /// Sentry Debug ID. non-null이면 JSON에 "debugId" 필드를 추가한다.
    /// UUID v4 문자열 (예: "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx").
    /// lazy sourcemap 경로 (Issue #1727) 에서 builder 가 emit 함수 밖으로 이관되므로
    /// stack pointer 의존을 회피하기 위해 `setDebugId` 로 내부 버퍼에 복사해 저장한다.
    debug_id: ?[]const u8 = null,
    debug_id_buf: [36]u8 = undefined,
    /// x_google_ignoreList: DevTools에서 무시할 소스 인덱스 목록.
    /// 폴리필, node_modules 등 프레임워크 코드를 자동으로 스킵하도록 한다.
    ignored_sources: std.ArrayList(u32) = .empty,
    /// addMapping 호출 순서가 (generated_line, column) 오름차순인지 추적.
    /// false면 encodeMappings에서 정렬한다. 일반 모듈 emit은 순차적이지만
    /// emitter가 prologue 매핑을 모듈 매핑보다 늦게 추가할 수 있다.
    is_sorted: bool = true,
    last_gen_line: u32 = 0,
    last_gen_col: u32 = 0,
    /// sourcemap spec `names` 배열. mangler 가 rename 한 식별자의 원본 이름이
    /// 들어가고 mapping.name_index 가 이 배열을 가리킨다. Sentry / DevTools 가
    /// minified 식별자를 원본 이름으로 표시하는 데 사용.
    names: std.ArrayList([]const u8) = .empty,
    /// names 배열 dedup 용 — 같은 원본 이름 여러 번 등장 시 같은 인덱스 반환.
    /// 키는 builder allocator 로 dupe 된 문자열 (names 배열과 ownership 공유).
    name_index_map: std.StringHashMapUnmanaged(u32) = .empty,

    pub fn init(allocator: std.mem.Allocator) SourceMapBuilder {
        return .{
            .mappings = .empty,
            .sources = .empty,
            .source_contents = .empty,
            .buf = .empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *SourceMapBuilder) void {
        for (self.sources.items) |s| self.allocator.free(s);
        for (self.source_contents.items) |c| self.allocator.free(c);
        for (self.names.items) |n| self.allocator.free(n);
        self.mappings.deinit(self.allocator);
        self.sources.deinit(self.allocator);
        self.source_contents.deinit(self.allocator);
        self.ignored_sources.deinit(self.allocator);
        self.names.deinit(self.allocator);
        self.name_index_map.deinit(self.allocator);
        self.buf.deinit(self.allocator);
    }

    /// heap 할당된 builder 의 `deinit` + `allocator.destroy` 를 한 호출로 묶어 처리.
    /// lazy sourcemap 경로 (Issue #1727) 에서 `SourceMapBuilder` 를 포인터로 이관/보관하는
    /// 사이트가 여러 곳이라 반복 패턴을 하나로 통합.
    pub fn destroy(self: *SourceMapBuilder, allocator: std.mem.Allocator) void {
        self.deinit();
        allocator.destroy(self);
    }

    /// stack/외부 builder 를 heap 으로 옮긴다 (얕은 복사 + self-ref pointer
    /// 보정). 호출 후 원본 builder 는 drained — caller 는 그 deinit 을 skip
    /// 해야 한다 (보통 `*_moved = true` flag 로). lazy sourcemap 경로의 다중
    /// 호출 사이트 (단일 번들 / chunk / HMR per-module) 통합.
    pub fn moveToHeap(self: *const SourceMapBuilder, allocator: std.mem.Allocator) !*SourceMapBuilder {
        const heap_sm = try allocator.create(SourceMapBuilder);
        heap_sm.* = self.*;
        heap_sm.fixSelfReferences();
        return heap_sm;
    }

    /// UUID v4 문자열 (36 byte) 를 builder 내부 `debug_id_buf` 에 복사하고 `debug_id` 를
    /// 그 slice 로 설정. lazy 경로에서 builder 가 외부로 이관돼도 pointer 유효성 보장.
    pub fn setDebugId(self: *SourceMapBuilder, uuid: []const u8) void {
        std.debug.assert(uuid.len == 36);
        @memcpy(&self.debug_id_buf, uuid[0..36]);
        self.debug_id = &self.debug_id_buf;
    }

    /// 얕은 복사 (`dest.* = src;`) 로 builder 를 이동시킨 직후 호출. `debug_id` 는 내부
    /// `debug_id_buf` 를 가리키는 self-referential pointer 이므로 복사 후 원래 위치를
    /// 가리키게 되어 stale. 새 메모리 위치 기준으로 재설정.
    pub fn fixSelfReferences(self: *SourceMapBuilder) void {
        if (self.debug_id != null) self.debug_id = &self.debug_id_buf;
    }

    /// 소스를 x_google_ignoreList에 추가. DevTools가 해당 소스의 프레임을 스킵한다.
    pub fn addIgnoredSource(self: *SourceMapBuilder, source_index: u32) !void {
        try self.ignored_sources.append(self.allocator, source_index);
    }

    /// 소스 파일 추가. 인덱스를 반환. `source_name` 은 builder allocator 로 dupe 되어
    /// 내부 소유 — caller 의 arena 가 해제돼도 유효. lazy sourcemap 경로 (Issue #1727) 에서
    /// builder 를 emit 밖으로 이관해도 sources 배열이 안전.
    pub fn addSource(self: *SourceMapBuilder, source_name: []const u8) !u32 {
        const idx: u32 = @intCast(self.sources.items.len);
        const copy = try self.allocator.dupe(u8, source_name);
        errdefer self.allocator.free(copy);
        try self.sources.append(self.allocator, copy);
        return idx;
    }

    /// 소스 파일 내용 추가. sources 배열과 인덱스가 대응해야 한다. `addSource` 와 동일
    /// 소유권 규칙 — content 는 dupe 된다.
    pub fn addSourceContent(self: *SourceMapBuilder, content: []const u8) !void {
        const copy = try self.allocator.dupe(u8, content);
        errdefer self.allocator.free(copy);
        try self.source_contents.append(self.allocator, copy);
    }

    /// names 배열에 식별자 추가 — 같은 이름은 첫 인덱스 반환 (dedup). 키는 builder
    /// allocator 로 dupe 되어 names 배열과 ownership 공유. mangler rename 발생 시
    /// 원본 이름을 등록해 mapping.name_index 로 참조.
    pub fn addName(self: *SourceMapBuilder, name: []const u8) !u32 {
        if (self.name_index_map.get(name)) |idx| return idx;
        const copy = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(copy);
        const idx: u32 = @intCast(self.names.items.len);
        try self.names.append(self.allocator, copy);
        try self.name_index_map.put(self.allocator, copy, idx);
        return idx;
    }

    /// 매핑 추가. emitter 가 outer wrapper 진입 시 발행한 mapping 과 첫 자식 emitter
    /// 가 발행한 mapping 이 동일 (gen,src) 위치에 박히는 패턴이 잦아 (예: expression
    /// statement → operand expression 의 첫 토큰), 직전 mapping 과 모든 좌표가 같으면
    /// 중복 push 를 생략한다. 출력 VLQ size 와 mappings 배열 메모리 절감.
    pub fn addMapping(self: *SourceMapBuilder, mapping: Mapping) !void {
        if (self.mappings.items.len > 0) {
            const last = self.mappings.items[self.mappings.items.len - 1];
            if (last.generated_line == mapping.generated_line and
                last.generated_column == mapping.generated_column and
                last.source_index == mapping.source_index and
                last.original_line == mapping.original_line and
                last.original_column == mapping.original_column)
            {
                return;
            }
            if (self.is_sorted) {
                const out_of_order = mapping.generated_line < self.last_gen_line or
                    (mapping.generated_line == self.last_gen_line and mapping.generated_column < self.last_gen_col);
                if (out_of_order) self.is_sorted = false;
            }
        }
        self.last_gen_line = mapping.generated_line;
        self.last_gen_col = mapping.generated_column;
        try self.mappings.append(self.allocator, mapping);
    }

    /// 소스맵 JSON을 생성한다.
    pub fn generateJSON(self: *SourceMapBuilder, output_file: []const u8) ![]const u8 {
        self.buf.clearRetainingCapacity();

        // JSON 시작
        try self.buf.appendSlice(self.allocator, "{\"version\":3,");

        // debugId 필드 (Sentry Debug ID — version 바로 뒤)
        if (self.debug_id) |did| {
            try self.buf.appendSlice(self.allocator, "\"debugId\":\"");
            try self.buf.appendSlice(self.allocator, did);
            try self.buf.appendSlice(self.allocator, "\",");
        }

        try self.buf.appendSlice(self.allocator, "\"file\":\"");
        try self.buf.appendSlice(self.allocator, output_file);
        try self.buf.appendSlice(self.allocator, "\",\"sourceRoot\":\"");
        try self.buf.appendSlice(self.allocator, self.source_root);
        try self.buf.appendSlice(self.allocator, "\",\"sources\":[");

        // sources 배열 (JSON 문자열 이스케이프 — \0 등 제어 문자 처리)
        for (self.sources.items, 0..) |src, i| {
            if (i > 0) try self.buf.append(self.allocator, ',');
            try self.appendJsonString(src);
        }

        try self.buf.appendSlice(self.allocator, "],\"names\":[");

        // names 배열 — mangler rename 발생 시 등록된 원본 식별자들. mapping.name_index 가
        // 이 배열을 가리켜 Sentry 가 minified `f` → 원본 `calculateTotalPrice` 복원.
        for (self.names.items, 0..) |n, i| {
            if (i > 0) try self.buf.append(self.allocator, ',');
            try self.appendJsonString(n);
        }

        try self.buf.appendSlice(self.allocator, "],\"mappings\":\"");

        // mappings 인코딩
        try self.encodeMappings();

        try self.buf.append(self.allocator, '"');

        // sourcesContent (옵션에 따라 포함)
        if (self.sources_content and self.source_contents.items.len > 0) {
            try self.buf.appendSlice(self.allocator, ",\"sourcesContent\":[");
            for (self.source_contents.items, 0..) |content, i| {
                if (i > 0) try self.buf.append(self.allocator, ',');
                // JSON 문자열로 이스케이프
                try self.appendJsonString(content);
            }
            try self.buf.append(self.allocator, ']');
        }

        // x_google_ignoreList (DevTools 프레임 스킵용)
        if (self.ignored_sources.items.len > 0) {
            try self.buf.appendSlice(self.allocator, ",\"x_google_ignoreList\":[");
            for (self.ignored_sources.items, 0..) |idx, i| {
                if (i > 0) try self.buf.append(self.allocator, ',');
                // u32를 10진수 문자열로 변환
                var num_buf: [10]u8 = undefined;
                const num_str = std.fmt.bufPrint(&num_buf, "{d}", .{idx}) catch "0";
                try self.buf.appendSlice(self.allocator, num_str);
            }
            try self.buf.append(self.allocator, ']');
        }

        try self.buf.append(self.allocator, '}');

        return self.buf.items;
    }

    /// `generateJSON` 의 결과를 caller 소유 slice 로 반환. 내부 `buf` 의 소유권을
    /// builder 의 allocator 로 이전 (`toOwnedSlice`) 해 dupe + deinit-free 라운드
    /// 트립을 회피. caller 는 builder 와 동일 allocator 로 free 해야 한다.
    pub fn generateJSONOwned(self: *SourceMapBuilder, output_file: []const u8) ![]const u8 {
        _ = try self.generateJSON(output_file);
        return self.buf.toOwnedSlice(self.allocator);
    }

    /// 소스맵 JSON + x_facebook_sources를 함께 생성한다. 단일 source 전용.
    /// `fn_map`의 내용을 `"x_facebook_sources":[[{names,mappings}]]`로 직렬화.
    pub fn generateJSONWithFunctionMap(
        self: *SourceMapBuilder,
        allocator: std.mem.Allocator,
        output_file: []const u8,
        fn_map: *const @import("function_map.zig").FunctionMapBuilder,
    ) ![]const u8 {
        const base = try self.generateJSON(output_file);
        std.debug.assert(base.len > 0 and base[base.len - 1] == '}');
        self.buf.shrinkRetainingCapacity(base.len - 1);
        try self.buf.appendSlice(allocator, ",\"x_facebook_sources\":[[");
        try fn_map.appendJson(&self.buf);
        try self.buf.appendSlice(allocator, "]]");
        try self.buf.append(allocator, '}');
        return self.buf.items;
    }

    /// 소스맵 JSON + x_facebook_sources 배열을 함께 생성한다. 복수 source 지원.
    /// source_fn_maps[i]는 sources[i]에 해당하는 function map JSON
    /// (`{"names":[...],"mappings":"..."}`) 또는 null (function map 없음).
    /// x_facebook_sources 포맷: sources 순서와 1:1 대응하는 배열.
    /// 각 요소는 null 또는 [{names,mappings}] (Metro 스펙: 배열로 감싼 단일 객체).
    pub fn generateJSONWithPerSourceFunctionMaps(
        self: *SourceMapBuilder,
        allocator: std.mem.Allocator,
        output_file: []const u8,
        source_fn_maps: []const ?[]const u8,
    ) ![]const u8 {
        const base = try self.generateJSON(output_file);
        std.debug.assert(base.len > 0 and base[base.len - 1] == '}');
        self.buf.shrinkRetainingCapacity(base.len - 1);

        try self.buf.appendSlice(allocator, ",\"x_facebook_sources\":[");
        for (source_fn_maps, 0..) |fm_json, i| {
            if (i > 0) try self.buf.append(allocator, ',');
            if (fm_json) |json| {
                try self.buf.append(allocator, '[');
                try self.buf.appendSlice(allocator, json);
                try self.buf.append(allocator, ']');
            } else {
                try self.buf.appendSlice(allocator, "null");
            }
        }
        try self.buf.append(allocator, ']');
        try self.buf.append(allocator, '}');
        return self.buf.items;
    }

    /// 문자열을 JSON 이스케이프하여 buf에 추가한다.
    fn appendJsonString(self: *SourceMapBuilder, s: []const u8) !void {
        return appendJsonStringTo(self.allocator, &self.buf, s);
    }

    /// mappings 필드를 VLQ 인코딩.
    fn encodeMappings(self: *SourceMapBuilder) !void {
        if (!self.is_sorted) {
            std.mem.sort(Mapping, self.mappings.items, {}, Mapping.lessThan);
        }

        var prev_gen_col: i32 = 0;
        var prev_src_idx: i32 = 0;
        var prev_src_line: i32 = 0;
        var prev_src_col: i32 = 0;
        var prev_name_idx: i32 = 0;
        var prev_gen_line: u32 = 0;
        var is_first_segment_on_line = true;

        for (self.mappings.items) |m| {
            // 줄이 바뀌면 세미콜론 추가
            while (prev_gen_line < m.generated_line) {
                try self.buf.append(self.allocator, ';');
                prev_gen_line += 1;
                prev_gen_col = 0;
                is_first_segment_on_line = true;
            }

            // 같은 줄의 이전 세그먼트와 콤마로 구분
            if (!is_first_segment_on_line) {
                try self.buf.append(self.allocator, ',');
            }
            is_first_segment_on_line = false;

            // 4개 필드 VLQ 인코딩 (name_index 가 있으면 5번째 필드까지)
            // 1. 출력 열 (이전 세그먼트 대비 상대값)
            try encodeVLQ(self.allocator, &self.buf, @as(i32, @intCast(m.generated_column)) - prev_gen_col);
            // 2. 소스 인덱스 (상대값)
            try encodeVLQ(self.allocator, &self.buf, @as(i32, @intCast(m.source_index)) - prev_src_idx);
            // 3. 소스 줄 (상대값)
            try encodeVLQ(self.allocator, &self.buf, @as(i32, @intCast(m.original_line)) - prev_src_line);
            // 4. 소스 열 (상대값)
            try encodeVLQ(self.allocator, &self.buf, @as(i32, @intCast(m.original_column)) - prev_src_col);
            // 5. names 인덱스 (옵션) — mangler rename 발생 시만 발행. spec: prev_name_idx 는
            // mapping 단위가 아니라 file 전체에 걸쳐 누적 (5-segment mapping 끼리만 chain).
            if (m.name_index) |ni| {
                try encodeVLQ(self.allocator, &self.buf, @as(i32, @intCast(ni)) - prev_name_idx);
                prev_name_idx = @intCast(ni);
            }

            prev_gen_col = @intCast(m.generated_column);
            prev_src_idx = @intCast(m.source_index);
            prev_src_line = @intCast(m.original_line);
            prev_src_col = @intCast(m.original_column);
        }
    }
};

/// 문자열을 JSON 이스케이프하여 `buf`에 추가한다.
/// `SourceMapBuilder.appendJsonString` 및 `FunctionMapBuilder.appendJson`에서 공유.
pub fn appendJsonStringTo(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), s: []const u8) !void {
    try buf.append(allocator, '"');
    for (s) |c| {
        switch (c) {
            '"' => try buf.appendSlice(allocator, "\\\""),
            '\\' => try buf.appendSlice(allocator, "\\\\"),
            '\n' => try buf.appendSlice(allocator, "\\n"),
            '\r' => try buf.appendSlice(allocator, "\\r"),
            '\t' => try buf.appendSlice(allocator, "\\t"),
            else => {
                if (c < 0x20) {
                    try buf.appendSlice(allocator, "\\u00");
                    const hex = "0123456789abcdef";
                    try buf.append(allocator, hex[c >> 4]);
                    try buf.append(allocator, hex[c & 0x0f]);
                } else {
                    try buf.append(allocator, c);
                }
            },
        }
    }
    try buf.append(allocator, '"');
}

// ============================================================
// 테스트
// ============================================================

test "sourceRoot — default empty string" {
    var sm = SourceMapBuilder.init(std.testing.allocator);
    defer sm.deinit();
    _ = try sm.addSource("input.ts");
    const json = try sm.generateJSON("output.js");
    // 기본값: sourceRoot가 빈 문자열
    try std.testing.expect(std.mem.indexOf(u8, json, "\"sourceRoot\":\"\"") != null);
}

test "sourceRoot — custom value" {
    var sm = SourceMapBuilder.init(std.testing.allocator);
    defer sm.deinit();
    sm.source_root = "https://example.com/";
    _ = try sm.addSource("input.ts");
    const json = try sm.generateJSON("output.js");
    try std.testing.expect(std.mem.indexOf(u8, json, "\"sourceRoot\":\"https://example.com/\"") != null);
}

test "sourcesContent — included by default" {
    var sm = SourceMapBuilder.init(std.testing.allocator);
    defer sm.deinit();
    _ = try sm.addSource("input.ts");
    try sm.addSourceContent("const x = 1;\n");
    const json = try sm.generateJSON("output.js");
    // sourcesContent 배열이 JSON에 포함되어야 한다
    try std.testing.expect(std.mem.indexOf(u8, json, "\"sourcesContent\":[\"const x = 1;\\n\"]") != null);
}

test "sourcesContent — excluded when false" {
    var sm = SourceMapBuilder.init(std.testing.allocator);
    defer sm.deinit();
    sm.sources_content = false;
    _ = try sm.addSource("input.ts");
    try sm.addSourceContent("const x = 1;\n");
    const json = try sm.generateJSON("output.js");
    // sources_content=false이면 sourcesContent가 없어야 한다
    try std.testing.expect(std.mem.indexOf(u8, json, "sourcesContent") == null);
}

test "sourcesContent — empty contents not included" {
    var sm = SourceMapBuilder.init(std.testing.allocator);
    defer sm.deinit();
    _ = try sm.addSource("input.ts");
    // source_contents를 추가하지 않으면 빈 배열이므로 sourcesContent 생략
    const json = try sm.generateJSON("output.js");
    try std.testing.expect(std.mem.indexOf(u8, json, "sourcesContent") == null);
}

test "sourcesContent — JSON escaping" {
    var sm = SourceMapBuilder.init(std.testing.allocator);
    defer sm.deinit();
    _ = try sm.addSource("input.ts");
    try sm.addSourceContent("let s = \"hello\\nworld\";\n");
    const json = try sm.generateJSON("output.js");
    // 따옴표와 백슬래시가 이스케이프되어야 한다
    try std.testing.expect(std.mem.indexOf(u8, json, "sourcesContent") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\\\"hello") != null);
}

// ============================================================
// UUID v4 생성 (Sentry Debug ID용)
// ============================================================

/// 크립토 난수 기반 UUID v4를 생성한다.
/// RFC 4122: version=4 (bytes[6] 상위 4비트 = 0100), variant=10xx (bytes[8] 상위 2비트).
/// 결과: "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx" (36자).
/// Zig 0.16: std.crypto.random 제거 (난수는 io 를 요구). transpile/emit 경로는
/// io-free 를 유지해야 하므로 입력 content 의 해시로 UUID 를 만든다 — 같은 입력 →
/// 같은 debugId (reproducible build, 결정성 epic #3564 와 정합). bundle 의
/// `//# debugId` 주석과 sourcemap 의 debugId 가 동일 값을 공유하는 Sentry 요건도
/// 만족 (한 번 생성해 양쪽에 사용). 난수성은 불필요 — 빌드별 유일성만 요구되며
/// content hash 가 그것을 제공.
pub fn generateUuidV4(buf: *[36]u8, seed_content: []const u8) void {
    var bytes: [16]u8 = undefined;
    const h0 = std.hash.Wyhash.hash(0x9e3779b97f4a7c15, seed_content);
    const h1 = std.hash.Wyhash.hash(0xd1b54a32d192ed03, seed_content);
    std.mem.writeInt(u64, bytes[0..8], h0, .little);
    std.mem.writeInt(u64, bytes[8..16], h1, .little);
    bytes[6] = (bytes[6] & 0x0f) | 0x40; // version 4
    bytes[8] = (bytes[8] & 0x3f) | 0x80; // variant 10xx
    const hex = "0123456789abcdef";
    var i: usize = 0;
    for (bytes, 0..) |b, idx| {
        if (idx == 4 or idx == 6 or idx == 8 or idx == 10) {
            buf[i] = '-';
            i += 1;
        }
        buf[i] = hex[b >> 4];
        buf[i + 1] = hex[b & 0xf];
        i += 2;
    }
}

test "debugId — included in JSON when set" {
    var sm = SourceMapBuilder.init(std.testing.allocator);
    defer sm.deinit();
    _ = try sm.addSource("input.ts");
    sm.debug_id = "12345678-1234-4abc-9def-123456789abc";
    const json = try sm.generateJSON("output.js");
    // version 뒤에 debugId가 있어야 한다
    try std.testing.expect(std.mem.indexOf(u8, json, "\"debugId\":\"12345678-1234-4abc-9def-123456789abc\"") != null);
}

test "debugId — not included when null" {
    var sm = SourceMapBuilder.init(std.testing.allocator);
    defer sm.deinit();
    _ = try sm.addSource("input.ts");
    const json = try sm.generateJSON("output.js");
    try std.testing.expect(std.mem.indexOf(u8, json, "debugId") == null);
}

test "generateUuidV4 — format and version/variant" {
    var buf: [36]u8 = undefined;
    generateUuidV4(&buf, "deterministic-seed-content");
    // 하이픈 위치: 8, 13, 18, 23
    try std.testing.expectEqual(@as(u8, '-'), buf[8]);
    try std.testing.expectEqual(@as(u8, '-'), buf[13]);
    try std.testing.expectEqual(@as(u8, '-'), buf[18]);
    try std.testing.expectEqual(@as(u8, '-'), buf[23]);
    // version nibble = '4'
    try std.testing.expectEqual(@as(u8, '4'), buf[14]);
    // variant nibble ∈ {8, 9, a, b}
    const variant = buf[19];
    try std.testing.expect(variant == '8' or variant == '9' or variant == 'a' or variant == 'b');
}

test "encodeMappings — out-of-order insertions are sorted before VLQ encoding" {
    // VLQ 스트림은 generated_line/column 오름차순이어야 하므로 호출 순서가 뒤섞이면
    // 정렬되어야 한다. 정렬이 없으면 작은 line의 매핑이 인코딩 시 누락된다.
    var sm = SourceMapBuilder.init(std.testing.allocator);
    defer sm.deinit();

    const a = try sm.addSource("module.js");
    const b = try sm.addSource("polyfill.js");

    // 모듈 매핑(line 5)을 먼저 추가
    try sm.addMapping(.{ .generated_line = 5, .generated_column = 0, .source_index = a, .original_line = 0, .original_column = 0 });
    // prologue identity 매핑(line 0~2)을 나중에 추가 — 정렬 안 되면 누락됨
    try sm.addMapping(.{ .generated_line = 0, .generated_column = 0, .source_index = b, .original_line = 0, .original_column = 0 });
    try sm.addMapping(.{ .generated_line = 1, .generated_column = 0, .source_index = b, .original_line = 1, .original_column = 0 });
    try sm.addMapping(.{ .generated_line = 2, .generated_column = 0, .source_index = b, .original_line = 2, .original_column = 0 });

    const json = try sm.generateJSON("out.js");
    // mappings 필드 추출
    const key = "\"mappings\":\"";
    const start = std.mem.indexOf(u8, json, key).? + key.len;
    const end = std.mem.indexOfScalarPos(u8, json, start, '"').?;
    const mappings = json[start..end];

    // 라인 0,1,2,3,4,5 → 첫 라인은 ";" 없이 시작
    // line 0 mapping이 누락되면 첫 글자가 ";" 가 됨
    try std.testing.expect(mappings.len > 0);
    try std.testing.expect(mappings[0] != ';');
    // 정확히 5개의 ";" 가 있어야 함 (line 5에 매핑 도달까지)
    var semi: usize = 0;
    for (mappings) |c| if (c == ';') {
        semi += 1;
    };
    try std.testing.expectEqual(@as(usize, 5), semi);
}
