//! 이미지 파일 헤더에서 dimension과 MIME 서브타입을 추출.
//! 이미지 전체를 디코딩하지 않고 헤더 바이트만 읽는 최소 구현.
//!
//! 지원 포맷: PNG, JPEG, GIF, WEBP.
//! 지원 안 함: SVG(벡터 — 치수 없음, XML 파싱 필요), BMP, HEIC.

const std = @import("std");

pub const Dimensions = struct {
    width: u32,
    height: u32,
};

pub const AssetType = enum {
    png,
    jpg,
    gif,
    webp,
    unknown,

    pub fn fromExtension(ext: []const u8) AssetType {
        if (std.ascii.eqlIgnoreCase(ext, ".png")) return .png;
        if (std.ascii.eqlIgnoreCase(ext, ".jpg") or std.ascii.eqlIgnoreCase(ext, ".jpeg")) return .jpg;
        if (std.ascii.eqlIgnoreCase(ext, ".gif")) return .gif;
        if (std.ascii.eqlIgnoreCase(ext, ".webp")) return .webp;
        return .unknown;
    }

    /// RN AssetRegistry의 `type` 필드용 — 점 없는 확장자 이름.
    pub fn typeName(self: AssetType, fallback_ext: []const u8) []const u8 {
        return switch (self) {
            .png => "png",
            .jpg => "jpg",
            .gif => "gif",
            .webp => "webp",
            .unknown => if (fallback_ext.len > 0 and fallback_ext[0] == '.') fallback_ext[1..] else fallback_ext,
        };
    }
};

/// 파일 바이트에서 이미지 dimension을 추출. 알려진 포맷이 아니면 null.
pub fn extractDimensions(bytes: []const u8) ?Dimensions {
    if (parsePng(bytes)) |d| return d;
    if (parseGif(bytes)) |d| return d;
    if (parseWebp(bytes)) |d| return d;
    if (parseJpeg(bytes)) |d| return d;
    return null;
}

/// PNG: signature(8) + IHDR chunk(13 bytes) starts at byte 8.
/// IHDR: length(4) + "IHDR"(4) + width(4 BE) + height(4 BE) + ...
fn parsePng(b: []const u8) ?Dimensions {
    if (b.len < 24) return null;
    const sig = [_]u8{ 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A };
    if (!std.mem.eql(u8, b[0..8], &sig)) return null;
    if (!std.mem.eql(u8, b[12..16], "IHDR")) return null;
    const w = std.mem.readInt(u32, b[16..20], .big);
    const h = std.mem.readInt(u32, b[20..24], .big);
    return .{ .width = w, .height = h };
}

/// GIF: "GIF87a"/"GIF89a"(6) + width(2 LE) + height(2 LE).
fn parseGif(b: []const u8) ?Dimensions {
    if (b.len < 10) return null;
    if (!std.mem.startsWith(u8, b, "GIF87a") and !std.mem.startsWith(u8, b, "GIF89a")) return null;
    const w = std.mem.readInt(u16, b[6..8], .little);
    const h = std.mem.readInt(u16, b[8..10], .little);
    return .{ .width = w, .height = h };
}

/// WEBP: "RIFF"(4) + size(4) + "WEBP"(4) + VP8/VP8L/VP8X chunk.
fn parseWebp(b: []const u8) ?Dimensions {
    if (b.len < 30) return null;
    if (!std.mem.eql(u8, b[0..4], "RIFF")) return null;
    if (!std.mem.eql(u8, b[8..12], "WEBP")) return null;

    // VP8 (lossy): "VP8 " at 12, dimensions at offset 26-29 (14 bits each)
    if (std.mem.eql(u8, b[12..16], "VP8 ")) {
        const w_raw = std.mem.readInt(u16, b[26..28], .little);
        const h_raw = std.mem.readInt(u16, b[28..30], .little);
        return .{ .width = w_raw & 0x3FFF, .height = h_raw & 0x3FFF };
    }
    // VP8L (lossless): "VP8L" at 12, dimensions packed in 4 bytes at offset 21
    if (std.mem.eql(u8, b[12..16], "VP8L")) {
        if (b.len < 25) return null;
        const packed_bits = std.mem.readInt(u32, b[21..25], .little);
        const w = (packed_bits & 0x3FFF) + 1;
        const h = ((packed_bits >> 14) & 0x3FFF) + 1;
        return .{ .width = w, .height = h };
    }
    // VP8X (extended): "VP8X" + flags(4) + canvas_width-1(3 LE) + canvas_height-1(3 LE)
    if (std.mem.eql(u8, b[12..16], "VP8X")) {
        if (b.len < 30) return null;
        const w = 1 + @as(u32, b[24]) + (@as(u32, b[25]) << 8) + (@as(u32, b[26]) << 16);
        const h = 1 + @as(u32, b[27]) + (@as(u32, b[28]) << 8) + (@as(u32, b[29]) << 16);
        return .{ .width = w, .height = h };
    }
    return null;
}

/// JPEG: SOI(0xFFD8) + 여러 marker segments. SOF0/SOF2(0xFFC0/0xFFC2) marker에 dimension.
fn parseJpeg(b: []const u8) ?Dimensions {
    if (b.len < 4) return null;
    if (b[0] != 0xFF or b[1] != 0xD8) return null;

    var i: usize = 2;
    while (i + 9 < b.len) {
        if (b[i] != 0xFF) return null;
        // padding FF는 스킵
        while (i < b.len and b[i] == 0xFF) i += 1;
        if (i >= b.len) return null;
        const marker = b[i];
        i += 1;

        // SOF0/SOF1/SOF2/SOF3 — dimension 있음 (JPEG baseline/extended/progressive/lossless)
        if (marker == 0xC0 or marker == 0xC1 or marker == 0xC2 or marker == 0xC3) {
            if (i + 7 >= b.len) return null;
            // segment: length(2) + precision(1) + height(2 BE) + width(2 BE)
            const h = std.mem.readInt(u16, b[i + 3 ..][0..2], .big);
            const w = std.mem.readInt(u16, b[i + 5 ..][0..2], .big);
            return .{ .width = w, .height = h };
        }

        // standalone markers (no segment): RST0-7, SOI, EOI 등
        if ((marker >= 0xD0 and marker <= 0xD9) or marker == 0x01) continue;

        // segment 건너뛰기
        if (i + 1 >= b.len) return null;
        const seg_len = std.mem.readInt(u16, b[i..][0..2], .big);
        if (seg_len < 2) return null;
        i += seg_len;
    }
    return null;
}

test "PNG dimensions" {
    // 1x1 PNG (red pixel)
    const bytes = [_]u8{
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
        0x00, 0x00, 0x00, 0x0D, 'I',  'H',  'D',  'R',
        0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
    };
    const d = extractDimensions(&bytes) orelse return error.ExpectedDims;
    try std.testing.expectEqual(@as(u32, 1), d.width);
    try std.testing.expectEqual(@as(u32, 1), d.height);
}

test "GIF dimensions" {
    const bytes = [_]u8{ 'G', 'I', 'F', '8', '9', 'a', 0x0A, 0x00, 0x14, 0x00 };
    const d = extractDimensions(&bytes) orelse return error.ExpectedDims;
    try std.testing.expectEqual(@as(u32, 10), d.width);
    try std.testing.expectEqual(@as(u32, 20), d.height);
}

test "unknown format returns null" {
    const bytes = [_]u8{ 'J', 'U', 'N', 'K' };
    try std.testing.expect(extractDimensions(&bytes) == null);
}

test "AssetType.fromExtension" {
    try std.testing.expectEqual(AssetType.png, AssetType.fromExtension(".png"));
    try std.testing.expectEqual(AssetType.png, AssetType.fromExtension(".PNG"));
    try std.testing.expectEqual(AssetType.jpg, AssetType.fromExtension(".jpg"));
    try std.testing.expectEqual(AssetType.jpg, AssetType.fromExtension(".jpeg"));
    try std.testing.expectEqual(AssetType.unknown, AssetType.fromExtension(".xyz"));
}
