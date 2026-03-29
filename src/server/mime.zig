const std = @import("std");

/// 파일 확장자로부터 MIME type을 반환한다.
/// 알 수 없는 확장자는 "application/octet-stream"을 반환한다.
pub fn fromExtension(path: []const u8) []const u8 {
    const ext = std.fs.path.extension(path);
    return lookup(ext);
}

fn lookup(ext: []const u8) []const u8 {
    // 확장자는 `.html` 형태 (dot 포함)
    const map = .{
        // HTML
        .{ ".html", "text/html; charset=utf-8" },
        .{ ".htm", "text/html; charset=utf-8" },
        // JavaScript
        .{ ".js", "application/javascript; charset=utf-8" },
        .{ ".mjs", "application/javascript; charset=utf-8" },
        .{ ".jsx", "application/javascript; charset=utf-8" },
        // TypeScript (dev 서버에서 소스 참조 시)
        .{ ".ts", "application/javascript; charset=utf-8" },
        .{ ".tsx", "application/javascript; charset=utf-8" },
        // CSS
        .{ ".css", "text/css; charset=utf-8" },
        // JSON
        .{ ".json", "application/json; charset=utf-8" },
        // Images
        .{ ".png", "image/png" },
        .{ ".jpg", "image/jpeg" },
        .{ ".jpeg", "image/jpeg" },
        .{ ".gif", "image/gif" },
        .{ ".svg", "image/svg+xml" },
        .{ ".ico", "image/x-icon" },
        .{ ".webp", "image/webp" },
        .{ ".avif", "image/avif" },
        // Fonts
        .{ ".woff", "font/woff" },
        .{ ".woff2", "font/woff2" },
        .{ ".ttf", "font/ttf" },
        .{ ".otf", "font/otf" },
        // Source maps
        .{ ".map", "application/json" },
        // WASM
        .{ ".wasm", "application/wasm" },
        // Text
        .{ ".txt", "text/plain; charset=utf-8" },
        .{ ".xml", "application/xml; charset=utf-8" },
        // Video/Audio
        .{ ".mp4", "video/mp4" },
        .{ ".webm", "video/webm" },
        .{ ".mp3", "audio/mpeg" },
        .{ ".ogg", "audio/ogg" },
    };

    inline for (map) |entry| {
        if (std.mem.eql(u8, ext, entry[0])) return entry[1];
    }

    return "application/octet-stream";
}
