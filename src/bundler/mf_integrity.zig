//! P2-2 (#3422): MF 산출 SHA-256 무결성 다이제스트.
//!
//! **파일명 content-hash 는 Wyhash 불변**(RFC §9 — 부분 재배포 결정성 S5
//! 의존). 무결성만 SHA-256. content-hash 의 2패스 placeholder-skip
//! (chunks.zig) 와 **무관** — 최종 산출 바이트(placeholder 치환 완료) raw
//! 1패스. P2-3(RS256 서명)의 토대(sidecar 단일 파일 = 서명 대상).
//!
//! 표준 schema 불침습: `@module-federation` 에 서명/SHA 부재(zntc 고유, D3
//! 인접). manifest.metaData/ManifestShared.hash 인라인 금지 — 별도 sidecar
//! `mf-manifest.json.integrity.json`(표준 runtime 미fetch, interop 불침습).
const std = @import("std");
const emitter = @import("emitter.zig");
const OutputFile = emitter.OutputFile;

/// 바이트 → SRI(`sha256-<base64>`). owned(caller free). 표준 Subresource
/// Integrity 표기 — P2-3/P4 검증기 재사용.
pub fn computeSri(allocator: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    const Encoder = std.base64.standard.Encoder;
    const b64 = try allocator.alloc(u8, Encoder.calcSize(digest.len));
    defer allocator.free(b64);
    _ = Encoder.encode(b64, &digest);
    return std.fmt.allocPrint(allocator, "sha256-{s}", .{b64});
}

/// `{version,algorithm,files:{<basename>:"sha256-<b64>"}}` JSON(owned).
/// manifest + 모든 JS 출력 청크(`chunks`) 무결성. 결정성 위해 파일명 정렬.
/// CSS/worker 청크 무결성은 1차 비-목표(후속). JSON 문자열 escape 는
/// emitter.appendJsonString 단일 소스 재사용.
pub fn buildSidecar(
    allocator: std.mem.Allocator,
    manifest_name: []const u8,
    manifest_bytes: []const u8,
    chunks: []const OutputFile,
) ![]const u8 {
    const Entry = struct { name: []const u8, sri: []const u8 };
    var entries: std.ArrayListUnmanaged(Entry) = .empty;
    defer {
        for (entries.items) |e| allocator.free(e.sri);
        entries.deinit(allocator);
    }
    try entries.append(allocator, .{
        .name = manifest_name,
        .sri = try computeSri(allocator, manifest_bytes),
    });
    // basename 키 — 현 MF 산출은 flat outdir 라 동명 충돌 불가. nested
    // 출력 도입 시 P2-3(서명) 전 키 충돌 재검토 필요(현재 거짓양성).
    for (chunks) |c| {
        try entries.append(allocator, .{
            .name = std.fs.path.basename(c.path),
            .sri = try computeSri(allocator, c.contents),
        });
    }
    // 결정적 출력 — 파일명 사전순(맵 순회/청크 순서 비결정 차단).
    std.mem.sort(Entry, entries.items, {}, struct {
        fn lt(_: void, a: Entry, b: Entry) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lt);

    var b: std.ArrayListUnmanaged(u8) = .empty;
    errdefer b.deinit(allocator);
    try b.appendSlice(allocator, "{\"version\":1,\"algorithm\":\"sha256\",\"files\":{");
    for (entries.items, 0..) |e, i| {
        if (i > 0) try b.append(allocator, ',');
        try emitter.appendJsonString(&b, allocator, e.name);
        try b.append(allocator, ':');
        try emitter.appendJsonString(&b, allocator, e.sri);
    }
    try b.appendSlice(allocator, "}}");
    return b.toOwnedSlice(allocator);
}

test "computeSri: SHA-256 SRI 결정성·정확성" {
    const a = std.testing.allocator;
    // 빈 입력의 SHA-256 = e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
    // base64 = 47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU=
    const s1 = try computeSri(a, "");
    defer a.free(s1);
    try std.testing.expectEqualStrings("sha256-47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU=", s1);
    const s2 = try computeSri(a, "zntc");
    defer a.free(s2);
    const s3 = try computeSri(a, "zntc");
    defer a.free(s3);
    try std.testing.expectEqualStrings(s2, s3); // 결정성
    try std.testing.expect(!std.mem.eql(u8, s1, s2)); // 입력 다르면 다름
}
