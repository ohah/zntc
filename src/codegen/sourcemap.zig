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
        self.buf.deinit(self.allocator);
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

        // sources 배열
        for (self.sources.items, 0..) |src, i| {
            if (i > 0) try self.buf.append(self.allocator, ',');
            try self.buf.append(self.allocator, '"');
            try self.buf.appendSlice(self.allocator, src);
            try self.buf.append(self.allocator, '"');
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

        try self.buf.append(self.allocator, '}');

        return self.buf.items;
    }

    /// 문자열을 JSON 이스케이프하여 buf에 추가한다.
    fn appendJsonString(self: *SourceMapBuilder, s: []const u8) !void {
        try self.buf.append(self.allocator, '"');
        for (s) |c| {
            switch (c) {
                '"' => try self.buf.appendSlice(self.allocator, "\\\""),
                '\\' => try self.buf.appendSlice(self.allocator, "\\\\"),
                '\n' => try self.buf.appendSlice(self.allocator, "\\n"),
                '\r' => try self.buf.appendSlice(self.allocator, "\\r"),
                '\t' => try self.buf.appendSlice(self.allocator, "\\t"),
                else => {
                    if (c < 0x20) {
                        // 제어 문자 → \u00XX
                        try self.buf.appendSlice(self.allocator, "\\u00");
                        const hex = "0123456789abcdef";
                        try self.buf.append(self.allocator, hex[c >> 4]);
                        try self.buf.append(self.allocator, hex[c & 0x0f]);
                    } else {
                        try self.buf.append(self.allocator, c);
                    }
                },
            }
        }
        try self.buf.append(self.allocator, '"');
    }

    /// mappings 필드를 VLQ 인코딩.
    fn encodeMappings(self: *SourceMapBuilder) !void {
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
