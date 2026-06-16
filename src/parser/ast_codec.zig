//! AST 직렬화 codec — 디스크 캐시(#4438) PR1.
//!
//! zts AST 는 인덱스/오프셋 기반(relocatable)이라 `nodes`/`extra_data`/`string_table`
//! 을 flat memcpy 하고 `source` 베이스만 새로 잡으면 완전 복원된다 (Span 이 offset+len
//! 기반이라 노드 내 텍스트 참조가 베이스와 무관). 따라서 rkyv 같은 무거운 직렬화 라이브러리
//! 없이 단순 바이트 복사로 충분하다.
//!
//! 안전: `[MAGIC][FORMAT_VERSION][checksum(payload)]` 헤더로 버전 스큐/손상을 방어한다.
//! 검증 실패는 항상 `error` 를 반환 — 호출자는 캐시를 버리고 재파싱(fail-safe). 잘못된
//! 캐시를 조용히 사용해 stale 출력을 내는 것보다 재파싱(느림)이 항상 안전하다는 비대칭 원칙.
//!
//! PR1 범위 = AST 만. semantic(symbols/scopes/references) / import_records / Module 레벨은
//! 후속 PR. `string_interns`(parse dedup 최적화 — codegen/transformer 가 read 안 함, 확인됨)
//! 는 빈 맵으로 복원. `declare_only_names`(transpile.zig 의 type-only export 판정이 read)는
//! 직렬화한다 — 누락 시 `declare const X; export {X}` 가 value export 로 잘못 출력된다.
//!
//! 포맷은 host endian/정렬 native — cross-arch 캐시 공유엔 부적합(magic 불일치 시 fail-safe
//! 재파싱으로 안전, silent corruption 아님). 로컬 캐시 전제.

const std = @import("std");
const ast_mod = @import("ast.zig");
const Ast = ast_mod.Ast;
const Node = ast_mod.Node;
const NodeIndex = ast_mod.NodeIndex;
const wyhash = @import("../util/wyhash.zig");
const codec_io = @import("../util/codec_io.zig");

pub const MAGIC: u32 = 0x5A4E5443; // "ZNTC"
pub const FORMAT_VERSION: u32 = 1;

/// null `?[]const u8` 표식 (jsx_pragma offset 자리).
const NULL_OFFSET: u32 = std.math.maxInt(u32);
/// header = magic(4) + version(4) + checksum(8)
const HEADER_LEN: usize = 16;

pub const Error = error{
    BadMagic,
    UnsupportedVersion,
    ChecksumMismatch,
    Truncated,
} || std.mem.Allocator.Error;

// ── serialize ───────────────────────────────────────────────────────────────

// IO 원시함수/Reader 는 공유 `util/codec_io.zig` 사용(semantic_codec/module_codec 와 동일 1벌).
const putU32 = codec_io.putU32;
const putU64 = codec_io.putU64;
const putBytes = codec_io.putBytes;

/// jsx_pragma 등 source-backed optional slice → (offset, len). null 이면 offset=NULL_OFFSET.
fn putPragma(buf: *std.ArrayList(u8), alloc: std.mem.Allocator, ast: *const Ast, p: ?[]const u8) !void {
    if (p) |s| {
        const off: usize = @intFromPtr(s.ptr) - @intFromPtr(ast.source.ptr);
        try putU32(buf, alloc, @intCast(off));
        try putU32(buf, alloc, @intCast(s.len));
    } else {
        try putU32(buf, alloc, NULL_OFFSET);
        try putU32(buf, alloc, 0);
    }
}

/// AST 를 `out` 에 직렬화한다 (append). 헤더(magic/version/checksum) + payload.
pub fn serialize(ast: *const Ast, out: *std.ArrayList(u8), alloc: std.mem.Allocator) !void {
    // payload 를 먼저 별도 버퍼에 만들고 checksum 을 계산한 뒤 헤더와 함께 기록.
    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(alloc);

    try putBytes(&payload, alloc, ast.source);
    try putBytes(&payload, alloc, std.mem.sliceAsBytes(ast.nodes.items));
    try putBytes(&payload, alloc, std.mem.sliceAsBytes(ast.extra_data.items));
    try putBytes(&payload, alloc, ast.string_table.items);

    // declare_only_names 키 (transpile.zig type-only export 판정용). 키는 source/string_table
    // backed slice 라 문자열 자체를 저장하고, deserialize 가 string_table 에 귀속시켜 복원.
    try putU32(&payload, alloc, @intCast(ast.declare_only_names.count()));
    var decl_it = ast.declare_only_names.keyIterator();
    while (decl_it.next()) |k| try putBytes(&payload, alloc, k.*);

    // 메타 플래그 7개 (1바이트씩)
    const flags = [_]bool{
        ast.has_jsx,                   ast.has_jsx_key_after_spread,
        ast.has_decorator,             ast.has_ts_namespace_or_enum,
        ast.has_ts_import_equals,      ast.has_ts_export_equals,
        ast.has_flow_enum_declaration,
    };
    for (flags) |f| try payload.append(alloc, if (f) @as(u8, 1) else 0);

    // jsx_pragma 4개 (source-backed offset/len)
    try putPragma(&payload, alloc, ast, ast.jsx_pragma_factory);
    try putPragma(&payload, alloc, ast, ast.jsx_pragma_fragment);
    try putPragma(&payload, alloc, ast, ast.jsx_pragma_runtime);
    try putPragma(&payload, alloc, ast, ast.jsx_pragma_import_source);

    // transform 상태 (?u32 / ?NodeIndex) — present 바이트 + 값
    try putU32(&payload, alloc, if (ast.transform_boundary) |b| b else NULL_OFFSET);
    try putU32(&payload, alloc, if (ast.transformed_root) |r| @intFromEnum(r) else NULL_OFFSET);

    const checksum = wyhash.hashU64(payload.items);
    try putU32(out, alloc, MAGIC);
    try putU32(out, alloc, FORMAT_VERSION);
    try putU64(out, alloc, checksum);
    try out.appendSlice(alloc, payload.items);
}

// ── deserialize ──────────────────────────────────────────────────────────────

const Reader = codec_io.Reader;

/// jsx_pragma 복원: `(offset, len)` → source-backed slice. off==NULL_OFFSET 이면 null.
/// ast-specific(source 베이스 의존)이라 codec_io.Reader 가 아닌 ast_codec 의 free 헬퍼.
fn readPragma(r: *Reader, source: []const u8) Error!?[]const u8 {
    const off = try r.u32v();
    const len = try r.u32v();
    if (off == NULL_OFFSET) return null;
    const end = std.math.add(u32, off, len) catch return error.Truncated;
    if (end > source.len) return error.Truncated;
    return source[off..][0..len];
}

/// flat bytes → 새 Ast. magic/version/checksum 검증 후 복원. 검증 실패는 error(재파싱 fallback).
/// 반환된 `ast.source` 는 새로 dupe 된 메모리이며 `Ast.deinit` 가 해제하지 않으므로,
/// 호출자가 `ast.deinit()` 전에 `allocator.free(ast.source)` 책임을 진다.
pub fn deserialize(data: []const u8, alloc: std.mem.Allocator) Error!Ast {
    if (data.len < HEADER_LEN) return error.Truncated;
    const magic = std.mem.bytesToValue(u32, data[0..4]);
    if (magic != MAGIC) return error.BadMagic;
    const version = std.mem.bytesToValue(u32, data[4..8]);
    if (version != FORMAT_VERSION) return error.UnsupportedVersion;
    const checksum = std.mem.bytesToValue(u64, data[8..16]);
    const payload = data[HEADER_LEN..];
    if (wyhash.hashU64(payload) != checksum) return error.ChecksumMismatch;

    var r = Reader{ .buf = payload };

    const source = try alloc.dupe(u8, try r.bytes());
    errdefer alloc.free(source);
    const nodes_bytes = try r.bytes();
    const extra_bytes = try r.bytes();
    const strtab_bytes = try r.bytes();

    var ast: Ast = .{
        .nodes = .empty,
        .extra_data = .empty,
        .source = source,
        .string_table = .empty,
        .string_interns = .empty,
        .allocator = alloc,
    };
    errdefer ast.deinit();

    // 손상된 캐시가 비배수 길이를 주면 @memcpy(dest.len != src.len) 가 패닉 → fail-safe 위반.
    if (nodes_bytes.len % @sizeOf(Node) != 0) return error.Truncated;
    try ast.nodes.resize(alloc, nodes_bytes.len / @sizeOf(Node));
    @memcpy(std.mem.sliceAsBytes(ast.nodes.items), nodes_bytes);

    if (extra_bytes.len % @sizeOf(u32) != 0) return error.Truncated;
    try ast.extra_data.resize(alloc, extra_bytes.len / @sizeOf(u32));
    @memcpy(std.mem.sliceAsBytes(ast.extra_data.items), extra_bytes);

    try ast.string_table.appendSlice(alloc, strtab_bytes);

    // declare_only_names: 키를 string_table 에 append 후 슬라이스로 등록 (소유권=string_table,
    // ast.deinit 가 일괄 해제). append 가 realloc 할 수 있으니 전부 append 후 offset 으로 슬라이스
    // 를 만들어 put (2-pass — 1-pass 면 먼저 만든 슬라이스가 realloc 으로 dangling).
    const decl_count = try r.u32v();
    if (decl_count > 0) {
        const KeySpan = struct { off: usize, len: usize };
        const spans = try alloc.alloc(KeySpan, decl_count);
        defer alloc.free(spans);
        for (spans) |*sp| {
            const kb = try r.bytes();
            sp.* = .{ .off = ast.string_table.items.len, .len = kb.len };
            try ast.string_table.appendSlice(alloc, kb);
        }
        for (spans) |sp| {
            try ast.declare_only_names.put(alloc, ast.string_table.items[sp.off..][0..sp.len], {});
        }
    }

    ast.has_jsx = (try r.byte()) != 0;
    ast.has_jsx_key_after_spread = (try r.byte()) != 0;
    ast.has_decorator = (try r.byte()) != 0;
    ast.has_ts_namespace_or_enum = (try r.byte()) != 0;
    ast.has_ts_import_equals = (try r.byte()) != 0;
    ast.has_ts_export_equals = (try r.byte()) != 0;
    ast.has_flow_enum_declaration = (try r.byte()) != 0;

    ast.jsx_pragma_factory = try readPragma(&r, source);
    ast.jsx_pragma_fragment = try readPragma(&r, source);
    ast.jsx_pragma_runtime = try readPragma(&r, source);
    ast.jsx_pragma_import_source = try readPragma(&r, source);

    const tb = try r.u32v();
    ast.transform_boundary = if (tb == NULL_OFFSET) null else tb;
    const tr = try r.u32v();
    ast.transformed_root = if (tr == NULL_OFFSET) null else @enumFromInt(tr);

    return ast;
}
