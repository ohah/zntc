//! Asset loader helpers for ModuleGraph.

const std = @import("std");
const wyhash = @import("../../util/wyhash.zig");
const fs = @import("../fs.zig");
const Module = @import("../module.zig").Module;
const types = @import("../types.zig");
const runtime_helpers = @import("../runtime_helpers.zig");
const mime = @import("../../server/mime.zig");
const asset_meta = @import("../asset_meta.zig");

/// JS 문자열 리터럴용 이스케이프. \ " \n \r \0 \u2028 \u2029 를 처리한다.
pub fn escapeJsString(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    // fast path: 이스케이프가 필요한 문자가 없으면 복사만
    var needs_escape = false;
    for (input) |c| {
        switch (c) {
            '\\', '"', '\n', '\r', 0 => {
                needs_escape = true;
                break;
            },
            0xe2 => {
                needs_escape = true; // UTF-8 U+2028/U+2029 시작 바이트
                break;
            },
            else => {},
        }
    }
    if (!needs_escape) return try allocator.dupe(u8, input);

    var buf: std.ArrayList(u8) = .empty;
    try buf.ensureTotalCapacity(allocator, input.len);
    var i: usize = 0;
    while (i < input.len) {
        const c = input[i];
        switch (c) {
            '\\' => try buf.appendSlice(allocator, "\\\\"),
            '"' => try buf.appendSlice(allocator, "\\\""),
            '\n' => try buf.appendSlice(allocator, "\\n"),
            '\r' => try buf.appendSlice(allocator, "\\r"),
            0 => try buf.appendSlice(allocator, "\\0"),
            0xe2 => {
                // U+2028 (LS) = E2 80 A8, U+2029 (PS) = E2 80 A9
                if (i + 2 < input.len and input[i + 1] == 0x80) {
                    if (input[i + 2] == 0xa8) {
                        try buf.appendSlice(allocator, "\\u2028");
                        i += 3;
                        continue;
                    } else if (input[i + 2] == 0xa9) {
                        try buf.appendSlice(allocator, "\\u2029");
                        i += 3;
                        continue;
                    }
                }
                try buf.append(allocator, c);
            },
            else => try buf.append(allocator, c),
        }
        i += 1;
    }
    return buf.toOwnedSlice(allocator);
}

/// 바이트 배열을 standard base64로 인코딩한다.
pub fn base64Encode(allocator: std.mem.Allocator, data: []const u8) ![]const u8 {
    const encoder = std.base64.standard.Encoder;
    const encoded_len = encoder.calcSize(data.len);
    const buf = try allocator.alloc(u8, encoded_len);
    _ = encoder.encode(buf, data);
    return buf;
}

/// raw bytes 를 asset loader 의 값 표현식으로 변환한다.
/// `file` / `copy` 는 asset_outputs 라이프사이클이 별개라 제외 — caller 가 별도 처리.
/// `javascript` / `json` / `css` / `none` 은 변환 없이 raw contents 가 source — null 반환.
/// (#2157)
pub fn sourceFromBytes(
    alloc: std.mem.Allocator,
    loader: types.Loader,
    raw: []const u8,
    module_path: []const u8,
    minify_whitespace: bool,
) ?[]const u8 {
    return switch (loader) {
        .text => blk: {
            const escaped = escapeJsString(alloc, raw) catch break :blk null;
            break :blk std.fmt.allocPrint(alloc, "\"{s}\"", .{escaped}) catch null;
        },
        .dataurl => blk: {
            const encoded = base64Encode(alloc, raw) catch break :blk null;
            const full_mime = mime.fromExtension(module_path);
            const mime_type = if (std.mem.indexOf(u8, full_mime, ";")) |semi|
                full_mime[0..semi]
            else
                full_mime;
            break :blk std.fmt.allocPrint(alloc, "\"data:{s};base64,{s}\"", .{ mime_type, encoded }) catch null;
        },
        .base64 => blk: {
            const encoded = base64Encode(alloc, raw) catch break :blk null;
            break :blk std.fmt.allocPrint(alloc, "\"{s}\"", .{encoded}) catch null;
        },
        .binary => blk: {
            const encoded = base64Encode(alloc, raw) catch break :blk null;
            const to_bin_name = runtime_helpers.helperName("__toBinary", minify_whitespace);
            break :blk std.fmt.allocPrint(alloc, "{s}(\"{s}\")", .{ to_bin_name, encoded }) catch null;
        },
        .empty => "undefined",
        .file, .copy, .javascript, .json, .css, .none => null,
    };
}

pub fn loaderReadsSource(loader: types.Loader) bool {
    return switch (loader) {
        .text, .dataurl, .base64, .binary, .file, .copy => true,
        else => false,
    };
}

pub const contentHash = wyhash.hashHex8;

/// asset naming 패턴 적용: [name] [hash] 치환 + 확장자 추가.
pub fn applyAssetNamingPattern(
    allocator: std.mem.Allocator,
    pattern: []const u8,
    name: []const u8,
    hash: *const [8]u8,
    ext: []const u8,
    dir: []const u8,
) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < pattern.len) {
        if (std.mem.startsWith(u8, pattern[i..], "[name]")) {
            try buf.appendSlice(allocator, name);
            i += "[name]".len;
        } else if (std.mem.startsWith(u8, pattern[i..], "[hash]")) {
            try buf.appendSlice(allocator, hash);
            i += "[hash]".len;
        } else if (std.mem.startsWith(u8, pattern[i..], "[dir]")) {
            // Windows 경로 구분자(\)를 URL 구분자(/)로 정규화
            for (dir) |c| {
                try buf.append(allocator, if (c == '\\') '/' else c);
            }
            i += "[dir]".len;
        } else if (std.mem.startsWith(u8, pattern[i..], "[ext]")) {
            // [ext]는 dot 없이 (예: "png")
            if (ext.len > 1) try buf.appendSlice(allocator, ext[1..]);
            i += "[ext]".len;
        } else {
            try buf.append(allocator, pattern[i]);
            i += 1;
        }
    }
    // 확장자 추가
    try buf.appendSlice(allocator, ext);
    return buf.toOwnedSlice(allocator);
}

/// RN bundle 결과로 expose 되는 asset metadata. strings 는 emit 시점에 사용한
/// allocator (loader 의 module parse_arena) 소유 — caller (graph) 가 long-lived
/// allocator 로 dupe 해 BundleResult 까지 lifetime 연장.
pub const RnAssetMetadata = struct {
    http_server_location: []const u8,
    file_system_location: []const u8,
    name: []const u8,
    type_name: []const u8,
    hash_hex: []const u8,
    scales: []const u32,
    width: u32,
    height: u32,
};

pub const EmittedAsset = struct {
    source: []const u8,
    metadata: RnAssetMetadata,
};

/// loader arena 소유 metadata 를 long-lived allocator 로 dupe.
/// BundleResult lifetime 동안 strings 가 살아남도록 graph allocator 에 owned copy 생성.
pub fn cloneRnAssetMetadata(
    allocator: std.mem.Allocator,
    meta: RnAssetMetadata,
) !RnAssetMetadata {
    return .{
        .http_server_location = try allocator.dupe(u8, meta.http_server_location),
        .file_system_location = try allocator.dupe(u8, meta.file_system_location),
        .name = try allocator.dupe(u8, meta.name),
        .type_name = try allocator.dupe(u8, meta.type_name),
        .hash_hex = try allocator.dupe(u8, meta.hash_hex),
        .scales = try allocator.dupe(u32, meta.scales),
        .width = meta.width,
        .height = meta.height,
    };
}

pub fn freeRnAssetMetadata(allocator: std.mem.Allocator, meta: RnAssetMetadata) void {
    allocator.free(meta.http_server_location);
    allocator.free(meta.file_system_location);
    allocator.free(meta.name);
    allocator.free(meta.type_name);
    allocator.free(meta.hash_hex);
    allocator.free(meta.scales);
}

/// Metro AssetRegistry.registerAsset() 호출식 + asset metadata 를 생성.
/// RN 런타임은 호출식 객체의 키를 정확히 요구하므로 shape 를 Metro 1:1 로 맞춘다.
/// metadata 는 mjs 측 release asset copy 가 string parse 없이 직접 받기 위한 사이드채널.
pub fn emitAssetRegistryCall(
    alloc: std.mem.Allocator,
    registry_path: []const u8,
    abs_path: []const u8,
    bytes: []const u8,
    hash: *const [8]u8,
    ext: []const u8,
    name_without_ext: []const u8,
    url: []const u8,
    scales: []const u32,
    project_root: []const u8,
) !EmittedAsset {
    const dims = asset_meta.extractDimensions(bytes);
    const width = if (dims) |d| d.width else 0;
    const height = if (dims) |d| d.height else 0;
    const asset_type = asset_meta.AssetType.fromExtension(ext);
    const type_name = asset_type.typeName(ext);

    // Metro 호환: httpServerLocation = `/assets/` + projectRoot 기준 상대 경로의 dirname.
    // RN 런타임이 `<dev-server>:<port><httpServerLocation>/<name>.<hash>.<type>` 형태로
    // URL을 만들기 때문에 `.`만 있으면 dev server가 파일을 찾지 못한다 (#1428).
    const http_loc_raw = blk: {
        if (project_root.len == 0) break :blk std.fs.path.dirname(url) orelse ".";
        const rel = std.fs.path.relative(alloc, project_root, abs_path) catch break :blk ".";
        defer alloc.free(rel);
        const rel_dir = std.fs.path.dirname(rel) orelse ".";
        break :blk std.fmt.allocPrint(alloc, "/assets/{s}", .{rel_dir}) catch ".";
    };
    const fs_dir_raw = std.fs.path.dirname(abs_path) orelse ".";

    // 사용자 경로/식별자에 따옴표·역슬래시·개행이 포함되면 JSON 파싱이 깨지므로 escape 필수.
    // RN/Metro에서 파일명에 특수문자 있을 가능성은 낮지만 안전하게 처리.
    const http_loc = try escapeJsString(alloc, http_loc_raw);
    const fs_dir = try escapeJsString(alloc, fs_dir_raw);
    const name_esc = try escapeJsString(alloc, name_without_ext);
    const registry_esc = try escapeJsString(alloc, registry_path);

    // Metro 호환: asset hash는 raw bytes의 MD5 32자 hex (Metro `Assets.js`의 hashFiles 결과).
    // RN 런타임/빌드 시스템이 캐시 키, 디스크 자산명 등에서 32자를 가정하므로
    // 8byte wyhash hex로는 충돌 확률 + Metro 호환성 모두 부족 (#1428).
    // 인자의 hash(`*const [8]u8`)는 기존 caller 호환을 위해 남겨두지만 미사용.
    _ = hash;
    var md5_digest: [16]u8 = undefined;
    std.crypto.hash.Md5.hash(bytes, &md5_digest, .{});
    const hash_hex = try alloc.alloc(u8, 32);
    const hex_chars = "0123456789abcdef";
    for (md5_digest, 0..) |b, i| {
        hash_hex[i * 2] = hex_chars[b >> 4];
        hash_hex[i * 2 + 1] = hex_chars[b & 0x0F];
    }

    // scales 배열 직렬화. 일반적으로 [1,2,3] 정도라 스택 버퍼로 충분.
    var scales_stack_buf: [128]u8 = undefined;
    var scales_stream = std.io.fixedBufferStream(&scales_stack_buf);
    const sw = scales_stream.writer();
    sw.writeByte('[') catch return error.OutOfMemory;
    for (scales, 0..) |s, i| {
        if (i > 0) sw.writeAll(", ") catch return error.OutOfMemory;
        std.fmt.format(sw, "{d}", .{s}) catch return error.OutOfMemory;
    }
    sw.writeByte(']') catch return error.OutOfMemory;
    const scales_str = scales_stream.getWritten();

    const source = try std.fmt.allocPrint(alloc,
        \\module.exports = require("{s}").registerAsset({{
        \\  "__packager_asset": true,
        \\  "httpServerLocation": "{s}",
        \\  "width": {d},
        \\  "height": {d},
        \\  "scales": {s},
        \\  "hash": "{s}",
        \\  "name": "{s}",
        \\  "type": "{s}",
        \\  "fileSystemLocation": "{s}"
        \\}})
    , .{ registry_esc, http_loc, width, height, scales_str, hash_hex, name_esc, type_name, fs_dir });

    return .{
        .source = source,
        .metadata = .{
            .http_server_location = http_loc_raw,
            .file_system_location = fs_dir_raw,
            .name = name_without_ext,
            .type_name = type_name,
            .hash_hex = hash_hex,
            .scales = scales,
            .width = width,
            .height = height,
        },
    };
}

pub const ScaleCollection = struct {
    scales: []const u32,
    variants: []const Module.ScaleVariant,
};

/// `name.ext`의 sibling을 스캔해 `name@2x.ext`, `name@3x.ext` 등을 수집.
/// Metro는 base(1x)가 반드시 존재해야 하며 variant만 있으면 매칭 안 함 — 같은 규칙.
pub fn collectScaleVariants(
    alloc: std.mem.Allocator,
    abs_path: []const u8,
    name_without_ext: []const u8,
    ext: []const u8,
    asset_names: []const u8,
    dir_pattern: []const u8,
) !ScaleCollection {
    const fs_dir = std.fs.path.dirname(abs_path) orelse return ScaleCollection{ .scales = &.{1}, .variants = &.{} };

    var scale_list: std.ArrayList(u32) = .empty;
    defer scale_list.deinit(alloc);
    try scale_list.append(alloc, 1); // base

    var variants: std.ArrayList(Module.ScaleVariant) = .empty;
    defer variants.deinit(alloc);

    // @2x부터 @4x까지 검사 (RN 실전 최대치). @1x 명시는 base와 중복이므로 무시.
    // stat으로 존재 여부 먼저 확인 — 없으면 readFileAlloc의 큰 alloc + read 시도 회피.
    var scale: u32 = 2;
    while (scale <= 4) : (scale += 1) {
        const variant_name = try std.fmt.allocPrint(alloc, "{s}@{d}x{s}", .{ name_without_ext, scale, ext });
        defer alloc.free(variant_name);
        const variant_path = try std.fs.path.join(alloc, &.{ fs_dir, variant_name });
        defer alloc.free(variant_path);

        fs.access(variant_path) catch continue;
        const loaded = fs.readFile(alloc, variant_path, 100 * 1024 * 1024) catch continue;
        const hash = contentHash(loaded.contents);
        const variant_basename = try std.fmt.allocPrint(alloc, "{s}@{d}x", .{ name_without_ext, scale });
        defer alloc.free(variant_basename);
        const output_name = try applyAssetNamingPattern(alloc, asset_names, variant_basename, &hash, ext, dir_pattern);

        try scale_list.append(alloc, scale);
        try variants.append(alloc, .{
            .scale = scale,
            .output_name = output_name,
            .raw_content = loaded.contents,
        });
    }

    return ScaleCollection{
        .scales = try scale_list.toOwnedSlice(alloc),
        .variants = try variants.toOwnedSlice(alloc),
    };
}

/// asset 파일의 entry_dir 기준 상대 디렉토리 경로를 계산한다.
/// 예: entry_dir="/app/src", module="/app/src/images/icons/logo.png" → "images/icons"
/// entry_dir 밖이면 빈 문자열 반환.
pub fn computeAssetDir(module_path: []const u8, entry_dir: []const u8) []const u8 {
    if (entry_dir.len == 0) return "";
    const module_dir = std.fs.path.dirname(module_path) orelse return "";
    // entry_dir이 module_dir의 prefix인지 확인
    if (module_dir.len <= entry_dir.len) return "";
    if (!std.mem.startsWith(u8, module_dir, entry_dir)) return "";
    // 구분자 건너뛰기
    var start = entry_dir.len;
    if (start < module_dir.len and module_dir[start] == std.fs.path.sep) start += 1;
    if (start >= module_dir.len) return "";
    return module_dir[start..];
}
