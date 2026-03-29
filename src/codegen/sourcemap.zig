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
    buf: std.ArrayList(u8),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) SourceMapBuilder {
        return .{
            .mappings = .empty,
            .sources = .empty,
            .buf = .empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *SourceMapBuilder) void {
        self.mappings.deinit(self.allocator);
        self.sources.deinit(self.allocator);
        self.buf.deinit(self.allocator);
    }

    /// 소스 파일 추가. 인덱스를 반환.
    pub fn addSource(self: *SourceMapBuilder, source_name: []const u8) !u32 {
        const idx: u32 = @intCast(self.sources.items.len);
        try self.sources.append(self.allocator, source_name);
        return idx;
    }

    /// 매핑 추가.
    pub fn addMapping(self: *SourceMapBuilder, mapping: Mapping) !void {
        try self.mappings.append(self.allocator, mapping);
    }

    /// 소스맵 JSON을 생성한다.
    pub fn generateJSON(self: *SourceMapBuilder, output_file: []const u8) ![]const u8 {
        self.buf.clearRetainingCapacity();

        // JSON 시작
        try self.buf.appendSlice(self.allocator, "{\"version\":3,\"file\":\"");
        try self.buf.appendSlice(self.allocator, output_file);
        try self.buf.appendSlice(self.allocator, "\",\"sourceRoot\":\"\",\"sources\":[");

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

        try self.buf.appendSlice(self.allocator, "\"}");

        return self.buf.items;
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
