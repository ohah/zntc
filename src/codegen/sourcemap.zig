//! ZTS Source Map V3
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

    pub fn lessThan(_: void, a: Mapping, b: Mapping) bool {
        if (a.generated_line != b.generated_line) return a.generated_line < b.generated_line;
        return a.generated_column < b.generated_column;
    }
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
    debug_id: ?[]const u8 = null,
    /// x_google_ignoreList: DevTools에서 무시할 소스 인덱스 목록.
    /// 폴리필, node_modules 등 프레임워크 코드를 자동으로 스킵하도록 한다.
    ignored_sources: std.ArrayList(u32) = .empty,
    /// addMapping 호출 순서가 (generated_line, column) 오름차순인지 추적.
    /// false면 encodeMappings에서 정렬한다. 일반 모듈 emit은 순차적이지만
    /// emitter가 prologue 매핑을 모듈 매핑보다 늦게 추가할 수 있다.
    is_sorted: bool = true,
    last_gen_line: u32 = 0,
    last_gen_col: u32 = 0,

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
        self.mappings.deinit(self.allocator);
        self.sources.deinit(self.allocator);
        self.source_contents.deinit(self.allocator);
        self.ignored_sources.deinit(self.allocator);
        self.buf.deinit(self.allocator);
    }

    /// 소스를 x_google_ignoreList에 추가. DevTools가 해당 소스의 프레임을 스킵한다.
    pub fn addIgnoredSource(self: *SourceMapBuilder, source_index: u32) !void {
        try self.ignored_sources.append(self.allocator, source_index);
    }

    /// 소스 파일 추가. 인덱스를 반환.
    pub fn addSource(self: *SourceMapBuilder, source_name: []const u8) !u32 {
        const idx: u32 = @intCast(self.sources.items.len);
        try self.sources.append(self.allocator, source_name);
        return idx;
    }

    /// 소스 파일 내용 추가. sources 배열과 인덱스가 대응해야 한다.
    pub fn addSourceContent(self: *SourceMapBuilder, content: []const u8) !void {
        try self.source_contents.append(self.allocator, content);
    }

    /// 매핑 추가.
    pub fn addMapping(self: *SourceMapBuilder, mapping: Mapping) !void {
        if (self.is_sorted and self.mappings.items.len > 0) {
            const out_of_order = mapping.generated_line < self.last_gen_line or
                (mapping.generated_line == self.last_gen_line and mapping.generated_column < self.last_gen_col);
            if (out_of_order) self.is_sorted = false;
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

        try self.buf.appendSlice(self.allocator, "],\"names\":[],\"mappings\":\"");

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

    /// 소스맵 JSON + x_facebook_sources를 함께 생성한다.
    /// `fn_map`이 있으면 `"x_facebook_sources":[[{names,mappings}]]` 추가.
    /// 단일 source 가정 — 복수 source는 PR#3(bundler integration)에서 처리.
    pub fn generateJSONWithFunctionMap(
        self: *SourceMapBuilder,
        allocator: std.mem.Allocator,
        output_file: []const u8,
        fn_map: *const @import("function_map.zig").FunctionMapBuilder,
    ) ![]const u8 {
        // 기존 JSON 생성 후 닫힘 `}` 직전에 x_facebook_sources 삽입.
        const base = try self.generateJSON(output_file);
        // base 마지막 `}` 제거 후 x_facebook_sources 추가.
        std.debug.assert(base.len > 0 and base[base.len - 1] == '}');
        self.buf.shrinkRetainingCapacity(base.len - 1);

        try self.buf.appendSlice(allocator, ",\"x_facebook_sources\":[[");
        try fn_map.appendJson(&self.buf);
        try self.buf.appendSlice(allocator, "]]");
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

            // 4개 필드 VLQ 인코딩
            // 1. 출력 열 (이전 세그먼트 대비 상대값)
            try encodeVLQ(self.allocator, &self.buf, @as(i32, @intCast(m.generated_column)) - prev_gen_col);
            // 2. 소스 인덱스 (상대값)
            try encodeVLQ(self.allocator, &self.buf, @as(i32, @intCast(m.source_index)) - prev_src_idx);
            // 3. 소스 줄 (상대값)
            try encodeVLQ(self.allocator, &self.buf, @as(i32, @intCast(m.original_line)) - prev_src_line);
            // 4. 소스 열 (상대값)
            try encodeVLQ(self.allocator, &self.buf, @as(i32, @intCast(m.original_column)) - prev_src_col);

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
pub fn generateUuidV4(buf: *[36]u8) void {
    var bytes: [16]u8 = undefined;
    std.crypto.random.bytes(&bytes);
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
    generateUuidV4(&buf);
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
