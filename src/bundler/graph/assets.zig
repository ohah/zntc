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
    // fast path: 이스케이프가 필요한 문자가 없으면 input 슬라이스 그대로 borrow 반환.
    // caller 는 결과를 별도 free 하지 말 것 — owned 가 필요하면 명시적 dupe.
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
    if (!needs_escape) return input;

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

/// RN bundle 결과로 expose 되는 asset metadata. strings + scales 는 emit 시
/// caller 가 전달한 `metadata_alloc` 소유 — loader 는 이를 그 asset 모듈의 `parse_arena`
/// 로 주어, metadata 가 module 라이프사이클(deinit/store/reparse)에 자동 정합되게 한다.
/// `graph.rn_asset_metadata` list 는 finalize 가 module 들에서 borrow 로 재수집하며,
/// `BundleResult` 로 내보낼 때만 `dupeRnAssetMetadata` 로 long-lived 복제한다.
///
/// 노출되는 필드는 `rn-asset-copy` 의 release copy 경로가 실제 읽는 것만 (Metro
/// `getAssetDestPath{IOS,Android}` 입력). width/height/hash 는 source string 안
/// `registerAsset({...})` 호출로 RN runtime 에 직접 전달되므로 metadata struct 에
/// 중복 보관할 필요가 없다.
pub const RnAssetMetadata = struct {
    http_server_location: []const u8,
    file_system_location: []const u8,
    name: []const u8,
    type_name: []const u8,
    scales: []const u32,
};

/// `emitAssetRegistryCall` 의 결과. `source` 는 `source_alloc` 소유 (보통 module
/// parse_arena), `metadata.*` 는 `metadata_alloc` 소유 (long-lived). 두 슬라이스가
/// 같은 lifetime 아니라는 점에 주의 — 회수 시 각자의 allocator 사용.
pub const EmittedAsset = struct {
    source: []const u8,
    metadata: RnAssetMetadata,
};

pub fn freeRnAssetMetadata(allocator: std.mem.Allocator, meta: RnAssetMetadata) void {
    allocator.free(meta.http_server_location);
    allocator.free(meta.file_system_location);
    allocator.free(meta.name);
    allocator.free(meta.type_name);
    allocator.free(meta.scales);
}

/// `RnAssetMetadata` 를 `allocator` 로 deep-copy. `freeRnAssetMetadata` 의 짝.
/// 항목 strings 가 보통 module 의 `parse_arena`(short-lived) 소유라, graph 수명과
/// 분리해 `BundleResult` 로 내보낼 때 long-lived allocator 로 복제한다.
/// 부분 실패 시 errdefer 가 이미 dupe 된 슬라이스를 회수해 leak 을 막는다.
pub fn dupeRnAssetMetadata(allocator: std.mem.Allocator, meta: RnAssetMetadata) !RnAssetMetadata {
    const http = try allocator.dupe(u8, meta.http_server_location);
    errdefer allocator.free(http);
    const fs_loc = try allocator.dupe(u8, meta.file_system_location);
    errdefer allocator.free(fs_loc);
    const name = try allocator.dupe(u8, meta.name);
    errdefer allocator.free(name);
    const type_name = try allocator.dupe(u8, meta.type_name);
    errdefer allocator.free(type_name);
    const scales = try allocator.dupe(u32, meta.scales);
    return .{
        .http_server_location = http,
        .file_system_location = fs_loc,
        .name = name,
        .type_name = type_name,
        .scales = scales,
    };
}

/// `emitAssetRegistryCall` 의 입력 — caller (loader) 가 module 단위로 모은 값들.
/// allocator 와 분리해 positional swap 위험 차단 + named field 호출.
pub const AssetEmitInput = struct {
    registry_path: []const u8,
    abs_path: []const u8,
    bytes: []const u8,
    ext: []const u8,
    name_without_ext: []const u8,
    url: []const u8,
    scales: []const u32,
    primary_scale: u32 = 1,
    project_root: []const u8,
};

/// Metro AssetRegistry.registerAsset() 호출식 + asset metadata 를 생성.
/// 두 allocator 분리 — fs.RealReadFileCache.readFile 의 `(long, short)` 컨벤션 준수:
/// `metadata_alloc`: metadata strings + scales backing — BundleResult 까지 살아남는 long-lived.
/// `source_alloc`: emit JS source (module.source) 의 backing — 보통 module parse_arena (short).
/// errdefer 가 partial-alloc leak 방지.
pub fn emitAssetRegistryCall(
    metadata_alloc: std.mem.Allocator,
    source_alloc: std.mem.Allocator,
    input: AssetEmitInput,
) !EmittedAsset {
    const dims = asset_meta.extractDimensions(input.bytes);
    const primary_scale = if (input.primary_scale == 0) 1 else input.primary_scale;
    const width = if (dims) |d| @divTrunc(d.width, primary_scale) else 0;
    const height = if (dims) |d| @divTrunc(d.height, primary_scale) else 0;
    const asset_type = asset_meta.AssetType.fromExtension(input.ext);
    const type_name = asset_type.typeName(input.ext);

    // Metro 호환: httpServerLocation = `/assets/` + projectRoot 기준 dirname.
    // RN 런타임이 `<dev-server>:<port><httpServerLocation>/<name>.<hash>.<type>` 형태로
    // URL 을 만들기 때문에 `.` 만 있으면 dev server 가 파일을 찾지 못한다 (#1428).
    // 임시 `rel` 버퍼는 source_alloc (parse_arena) — graph allocator fragmentation 회피.
    const http_loc_owned = blk: {
        if (input.project_root.len == 0) {
            const d = std.fs.path.dirname(input.url) orelse ".";
            break :blk try metadata_alloc.dupe(u8, d);
        }
        const rel = std.fs.path.relative(source_alloc, "", null, input.project_root, input.abs_path) catch {
            break :blk try metadata_alloc.dupe(u8, ".");
        };
        const rel_dir = std.fs.path.dirname(rel) orelse ".";
        break :blk try std.fmt.allocPrint(metadata_alloc, "/assets/{s}", .{rel_dir});
    };
    errdefer metadata_alloc.free(http_loc_owned);

    const fs_dir_owned = try metadata_alloc.dupe(u8, std.fs.path.dirname(input.abs_path) orelse ".");
    errdefer metadata_alloc.free(fs_dir_owned);
    const name_owned = try metadata_alloc.dupe(u8, input.name_without_ext);
    errdefer metadata_alloc.free(name_owned);
    const type_name_owned = try metadata_alloc.dupe(u8, type_name);
    errdefer metadata_alloc.free(type_name_owned);

    // Metro 호환: asset hash 는 raw bytes 의 MD5 32 hex (Metro `Assets.js` hashFiles).
    // RN 런타임/빌드 시스템이 캐시 키, 디스크 자산명 등에서 32 hex 를 가정하므로
    // 8 byte wyhash 로는 충돌 확률 + Metro 호환성 모두 부족 (#1428).
    // hash 는 source string 의 `registerAsset({"hash": "..."})` 안에만 들어가고
    // metadata struct 는 hash 를 노출하지 않으므로 stack 버퍼만으로 충분.
    var md5_digest: [16]u8 = undefined;
    std.crypto.hash.Md5.hash(input.bytes, &md5_digest, .{});
    var hash_hex: [32]u8 = undefined;
    const hex_chars = "0123456789abcdef";
    for (md5_digest, 0..) |b, i| {
        hash_hex[i * 2] = hex_chars[b >> 4];
        hash_hex[i * 2 + 1] = hex_chars[b & 0x0F];
    }

    const scales_owned = try metadata_alloc.dupe(u32, input.scales);
    errdefer metadata_alloc.free(scales_owned);

    // 사용자 경로/식별자에 따옴표·역슬래시·개행이 포함되면 JSON 파싱이 깨지므로 escape 필수.
    // escapeJsString 은 fast path 에서 input slice 를 borrow 반환 — source 임베드용이라
    // source_alloc lifetime 만 충족하면 됨 (대다수 케이스에 alloc 0).
    const http_loc_esc = try escapeJsString(source_alloc, http_loc_owned);
    const fs_dir_esc = try escapeJsString(source_alloc, fs_dir_owned);
    const name_esc = try escapeJsString(source_alloc, input.name_without_ext);
    const registry_esc = try escapeJsString(source_alloc, input.registry_path);

    // scales 배열 직렬화. 일반적으로 [1,2,3] 정도라 스택 버퍼로 충분.
    // 0.16: std.io.fixedBufferStream 제거 → std.Io.Writer.fixed (고정 버퍼 writer).
    var scales_stack_buf: [128]u8 = undefined;
    var sw: std.Io.Writer = .fixed(&scales_stack_buf);
    sw.writeByte('[') catch return error.OutOfMemory;
    for (input.scales, 0..) |s, i| {
        if (i > 0) sw.writeAll(", ") catch return error.OutOfMemory;
        sw.print("{d}", .{s}) catch return error.OutOfMemory;
    }
    sw.writeByte(']') catch return error.OutOfMemory;
    const scales_str = sw.buffered();

    const source = try std.fmt.allocPrint(source_alloc,
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
    , .{ registry_esc, http_loc_esc, width, height, scales_str, &hash_hex, name_esc, type_name, fs_dir_esc });

    return .{
        .source = source,
        .metadata = .{
            .http_server_location = http_loc_owned,
            .file_system_location = fs_dir_owned,
            .name = name_owned,
            .type_name = type_name_owned,
            .scales = scales_owned,
        },
    };
}

pub const ScaleCollection = struct {
    scales: []const u32,
    variants: []const Module.ScaleVariant,
};

pub const ScaleInfo = struct {
    logical_name: []const u8,
    scale: u32,
};

/// `name@3x` 같은 Metro scale suffix 를 분리한다. 현재 RN asset copy 경로는 정수
/// scale 만 보관하므로 `@1.5x` 는 기존 base-name 취급을 유지한다.
pub fn parseScaleSuffix(name_without_ext: []const u8) ?ScaleInfo {
    if (name_without_ext.len < 4 or name_without_ext[name_without_ext.len - 1] != 'x') return null;
    var digit_start = name_without_ext.len - 1;
    while (digit_start > 0 and std.ascii.isDigit(name_without_ext[digit_start - 1])) {
        digit_start -= 1;
    }
    if (digit_start == name_without_ext.len - 1) return null;
    if (digit_start == 0 or name_without_ext[digit_start - 1] != '@') return null;
    const scale = std.fmt.parseUnsigned(u32, name_without_ext[digit_start .. name_without_ext.len - 1], 10) catch return null;
    if (scale == 0) return null;
    return .{
        .logical_name = name_without_ext[0 .. digit_start - 1],
        .scale = scale,
    };
}

fn scaleVariantBaseName(alloc: std.mem.Allocator, logical_name: []const u8, scale: u32) ![]const u8 {
    if (scale == 1) return try alloc.dupe(u8, logical_name);
    return try std.fmt.allocPrint(alloc, "{s}@{d}x", .{ logical_name, scale });
}

/// `name.ext`의 sibling을 스캔해 `name@2x.ext`, `name@3x.ext` 등을 수집.
/// Metro 호환: base(1x)가 없어도 scale variant 만 있으면 해당 scale 로 등록한다.
pub fn collectScaleVariants(
    alloc: std.mem.Allocator,
    io: std.Io,
    abs_path: []const u8,
    name_without_ext: []const u8,
    ext: []const u8,
    asset_names: []const u8,
    dir_pattern: []const u8,
    primary_scale: u32,
) !ScaleCollection {
    const fs_dir = std.fs.path.dirname(abs_path) orelse return ScaleCollection{ .scales = &.{1}, .variants = &.{} };

    var scale_list: std.ArrayList(u32) = .empty;
    defer scale_list.deinit(alloc);

    var variants: std.ArrayList(Module.ScaleVariant) = .empty;
    defer variants.deinit(alloc);

    // Metro 기본 assetResolutions 의 정수 scale subset. @1.5x 는 현재 u32 metadata
    // 모델에서 표현하지 못하므로 기존처럼 일반 파일명으로만 처리한다.
    var scale: u32 = 1;
    while (scale <= 4) : (scale += 1) {
        const variant_basename = try scaleVariantBaseName(alloc, name_without_ext, scale);
        defer alloc.free(variant_basename);
        const variant_name = try std.fmt.allocPrint(alloc, "{s}{s}", .{ variant_basename, ext });
        defer alloc.free(variant_name);
        const variant_path = try std.fs.path.join(alloc, &.{ fs_dir, variant_name });
        defer alloc.free(variant_path);

        fs.access(io, variant_path) catch continue;
        try scale_list.append(alloc, scale);

        if (scale == primary_scale and std.mem.eql(u8, variant_path, abs_path)) {
            continue;
        }

        const loaded = fs.readFile(io, alloc, variant_path, 100 * 1024 * 1024) catch continue;
        const hash = contentHash(loaded.contents);
        const output_name = try applyAssetNamingPattern(alloc, asset_names, variant_basename, &hash, ext, dir_pattern);

        try variants.append(alloc, .{
            .scale = scale,
            .output_name = output_name,
            .raw_content = loaded.contents,
        });
    }

    if (scale_list.items.len == 0) {
        try scale_list.append(alloc, if (primary_scale == 0) 1 else primary_scale);
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
