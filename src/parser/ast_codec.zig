//! AST 직렬화 codec — 디스크 캐시(#4438) PR1.
//!
//! zts AST 는 인덱스/오프셋 기반(relocatable)이라 `nodes`/`extra_data`/`string_table`
//! 을 flat memcpy 하고 `source` 베이스만 새로 잡으면 완전 복원된다 (Span 이 offset+len
//! 기반이라 노드 내 텍스트 참조가 베이스와 무관). 따라서 무거운 직렬화 라이브러리 없이
//! 단순 바이트 복사로 충분하다.
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
// v2: #4438 필드별 결정적 직렬화 + leaf sub-variant 폭(none=4/wide=8). v1(통째 memcpy)과
// 바이트 레이아웃이 완전히 달라 구버전 캐시를 읽으면 위험 → bump 로 version mismatch=miss degrade.
// cache_key.CODEC_FORMAT 가 이 값을 키에 접으므로 구 캐시는 키 자체가 달라져 무효화된다.
pub const FORMAT_VERSION: u32 = 2;

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

comptime {
    // serialize/deserialize 는 Ast 의 특정 필드 subset 만 다룬다(나머지는 빈 값으로 복원하거나
    // 직렬화 불필요로 분류됨). Ast 가 새 필드를 얻으면 — 특히 source-backed slice(`jsx_pragma_*`
    // 류)나 deserialize 정확성에 영향을 주는 필드면 — 직렬화 누락 시 cache-hit 후 stale 출력이
    // 된다. 다른 codec(semantic/module/cache_key)처럼 필드 수를 못박아, 변경 시 새 필드를
    // "직렬화 / 빈값복원" 중 어디로 분류할지 재검토를 컴파일 에러로 강제한다.
    if (@typeInfo(Ast).@"struct".fields.len != 24)
        @compileError("Ast 필드 수가 바뀜 — 새 필드의 직렬화 필요 여부를 판정해 ast_codec 갱신 후 이 수를 갱신할 것.");
}

// ── serialize ───────────────────────────────────────────────────────────────

// IO 원시함수/Reader 는 공유 `util/codec_io.zig` 사용(semantic_codec/module_codec 와 동일 1벌).
const putU32 = codec_io.putU32;
const putU64 = codec_io.putU64;
const putBytes = codec_io.putBytes;

/// Node 배열을 결정적으로 직렬화한다. `sliceAsBytes` 통째 memcpy 는 struct 꼬리 padding
/// (`tag:u16` 뒤 2B)과 `Data` union 의 active variant 밖 꼬리 바이트가 미초기화라 같은 입력도
/// byte 가 달라진다(#4438). 노드별로 의미 필드만 명시 직렬화한다:
///   `[count:u32]` 다음 노드마다 `span.start(u32) span.end(u32) tag(u16) data[0..dataWidth(tag)]`.
/// data 는 active variant 의 의미 폭만 쓰고 padding/union 꼬리는 stream 에서 제외 →
/// 결정적. deserialize 가 0-init Node 에 정확히 역으로 복원(꼬리는 0).
///
/// `dataWidth` 는 leaf 을 sub-variant 별로 세분한다: none-only leaf=4(꼬리 [4..8] poison 을
/// stream 에서 제외), string_ref/number_bytes 를 쓰는 wide leaf=8. wide leaf 의 `.none` 노드는
/// 파서가 `Data.noneLeaf` 로 꼬리를 0-채워 만들므로 8B 전부 결정적(ast.zig WIDE_LEAF_TAGS 참조).
fn putNodes(buf: *std.ArrayList(u8), alloc: std.mem.Allocator, nodes: []const Node) !void {
    try putU32(buf, alloc, @intCast(nodes.len));
    for (nodes) |n| {
        try putU32(buf, alloc, n.span.start);
        try putU32(buf, alloc, n.span.end);
        const tag_int: u16 = @intFromEnum(n.tag);
        try buf.appendSlice(alloc, std.mem.asBytes(&tag_int));
        const width = Node.Tag.dataWidth(n.tag);
        try buf.appendSlice(alloc, std.mem.asBytes(&n.data)[0..width]);
    }
}

/// StringHashMap 키 집합을 **정렬 후** 직렬화한다(`[count:u32]` + 키마다 `[len:u32][bytes]`).
/// HashMap iteration 순서는 비결정적이라 정렬 없이는 같은 입력도 byte stream 이 달라진다(#4438).
fn putSortedKeySet(buf: *std.ArrayList(u8), alloc: std.mem.Allocator, m: *const std.StringHashMapUnmanaged(void)) !void {
    try putU32(buf, alloc, @intCast(m.count()));
    if (m.count() == 0) return;
    const keys = try alloc.alloc([]const u8, m.count());
    defer alloc.free(keys);
    var it = m.keyIterator();
    var i: usize = 0;
    while (it.next()) |k| : (i += 1) keys[i] = k.*;
    std.mem.sortUnstable([]const u8, keys, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);
    for (keys) |k| try putBytes(buf, alloc, k);
}

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
    try putNodes(&payload, alloc, ast.nodes.items);
    try putBytes(&payload, alloc, std.mem.sliceAsBytes(ast.extra_data.items));
    try putBytes(&payload, alloc, ast.string_table.items);

    // declare_only_names 키 (transpile.zig type-only export 판정용). 키는 source/string_table
    // backed slice 라 문자열 자체를 저장하고, deserialize 가 string_table 에 귀속시켜 복원.
    // 키를 정렬(lexicographic)해 HashMap iteration 순서 비결정성을 제거한다 — 같은 입력은
    // 항상 같은 byte stream (캐시 결정성). deserialize 는 순서 무관(키 set 복원).
    try putSortedKeySet(&payload, alloc, &ast.declare_only_names);

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

    var ast: Ast = .{
        .nodes = .empty,
        .extra_data = .empty,
        .source = source,
        .string_table = .empty,
        .string_interns = .empty,
        .allocator = alloc,
    };
    errdefer ast.deinit();

    // 노드는 `putNodes` 의 짝으로 명시 역직렬화한다(통째 memcpy 아님). 각 Node 를 0-init 후
    // span/tag/data(active variant 폭만) 복원 — data 의 union 꼬리는 0(직렬화에서 제외됨)이라
    // 결정적이며 reader 가 폭 밖을 읽지 않으므로 동치.
    const node_count = try r.u32v();
    try ast.nodes.ensureTotalCapacityPrecise(alloc, node_count);
    var ni: u32 = 0;
    while (ni < node_count) : (ni += 1) {
        const start = try r.u32v();
        const end = try r.u32v();
        const tag_int = std.mem.bytesToValue(u16, (try r.take(2))[0..2]);
        const tag = std.enums.fromInt(Node.Tag, tag_int) orelse return error.Truncated;
        const width = Node.Tag.dataWidth(tag);
        const dbytes = try r.take(width);
        var node = Node{ .tag = tag, .span = .{ .start = start, .end = end }, .data = std.mem.zeroes(Node.Data) };
        @memcpy(std.mem.asBytes(&node.data)[0..width], dbytes);
        ast.nodes.appendAssumeCapacity(node);
    }

    const extra_bytes = try r.bytes();
    const strtab_bytes = try r.bytes();

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
