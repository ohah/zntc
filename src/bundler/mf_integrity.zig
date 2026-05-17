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

/// P2-3 (#3423): P2-2 sidecar 를 **Ed25519** 서명. RS256 비채택 — Zig
/// 0.15.2 std.crypto 에 RSA 서명 부재(crypto.zig:174-176: sign 은 Ed25519/
/// ecdsa 만; Certificate.rsa 는 X.509 *검증* 전용). 표준 @module-federation
/// 에 서명 부재(zntc 고유, RFC §5.4 RS256 은 예시일 뿐) → 알고리즘 선택
/// 자유, alg 필드는 실제(`ed25519`) 정직 표기. seed=raw 32B(KeyPair.
/// generateDeterministic). 서명 결정적(sign(msg,null)) → sidecar 결정성
/// (P2-2)과 합쳐 `.sig` byte-재현. 별도 `.sig` 파일(자기참조 순환 회피 —
/// sidecar 불변). 반환 = `.sig` JSON(owned).
pub fn signSidecar(
    allocator: std.mem.Allocator,
    sidecar_bytes: []const u8,
    seed: [32]u8,
) ![]const u8 {
    const Ed = std.crypto.sign.Ed25519;
    const kp = Ed.KeyPair.generateDeterministic(seed) catch return error.MfSignKeyInvalid;
    const sig = kp.sign(sidecar_bytes, null) catch return error.MfSignFailed;
    const sig_bytes = sig.toBytes(); // 64B
    const pk_bytes = kp.public_key.toBytes(); // 32B
    const Enc = std.base64.standard.Encoder;
    const sig64 = try allocator.alloc(u8, Enc.calcSize(sig_bytes.len));
    defer allocator.free(sig64);
    _ = Enc.encode(sig64, &sig_bytes);
    const pk64 = try allocator.alloc(u8, Enc.calcSize(pk_bytes.len));
    defer allocator.free(pk64);
    _ = Enc.encode(pk64, &pk_bytes);
    var b: std.ArrayListUnmanaged(u8) = .empty;
    errdefer b.deinit(allocator);
    try b.appendSlice(allocator, "{\"version\":1,\"alg\":\"ed25519\",\"signature\":");
    try emitter.appendJsonString(&b, allocator, sig64);
    try b.appendSlice(allocator, ",\"publicKey\":");
    try emitter.appendJsonString(&b, allocator, pk64);
    try b.append(allocator, '}');
    return b.toOwnedSlice(allocator);
}

/// `.sig` JSON 으로 sidecar 무결성 서명 검증(round-trip/변조탐지). 런타임
/// 강제 verify 는 비-목표(P3/P4) — 인프라+테스트용. 실패 시 명확한 error.
pub fn verifySidecar(
    allocator: std.mem.Allocator,
    sidecar_bytes: []const u8,
    sig_json: []const u8,
) !void {
    const Sig = struct { alg: []const u8, signature: []const u8, publicKey: []const u8 };
    const parsed = std.json.parseFromSlice(Sig, allocator, sig_json, .{
        .ignore_unknown_fields = true,
    }) catch return error.MfSigMalformed;
    defer parsed.deinit();
    if (!std.mem.eql(u8, parsed.value.alg, "ed25519")) return error.MfSigUnsupportedAlg;
    const Ed = std.crypto.sign.Ed25519;
    const Dec = std.base64.standard.Decoder;
    var sigb: [Ed.Signature.encoded_length]u8 = undefined; // 64
    if ((Dec.calcSizeForSlice(parsed.value.signature) catch return error.MfSigMalformed) != sigb.len)
        return error.MfSigMalformed;
    Dec.decode(&sigb, parsed.value.signature) catch return error.MfSigMalformed;
    var pkb: [Ed.PublicKey.encoded_length]u8 = undefined; // 32
    if ((Dec.calcSizeForSlice(parsed.value.publicKey) catch return error.MfSigMalformed) != pkb.len)
        return error.MfSigMalformed;
    Dec.decode(&pkb, parsed.value.publicKey) catch return error.MfSigMalformed;
    const pk = Ed.PublicKey.fromBytes(pkb) catch return error.MfSigMalformed;
    Ed.Signature.fromBytes(sigb).verify(sidecar_bytes, pk) catch return error.MfSigMismatch;
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

test "signSidecar/verifySidecar: round-trip·변조탐지·결정성" {
    const a = std.testing.allocator;
    var seed: [32]u8 = undefined;
    for (&seed, 0..) |*x, i| x.* = @intCast(i); // 결정적 테스트 seed
    const payload = "{\"version\":1,\"algorithm\":\"sha256\",\"files\":{}}";
    const sig1 = try signSidecar(a, payload, seed);
    defer a.free(sig1);
    const sig2 = try signSidecar(a, payload, seed);
    defer a.free(sig2);
    try std.testing.expectEqualStrings(sig1, sig2); // 결정적 서명
    try std.testing.expect(std.mem.indexOf(u8, sig1, "\"alg\":\"ed25519\"") != null);
    try verifySidecar(a, payload, sig1); // round-trip OK
    // 변조: payload 1바이트 변경 → 불일치
    try std.testing.expectError(error.MfSigMismatch, verifySidecar(a, payload[0 .. payload.len - 1], sig1));
    // 깨진 sig JSON
    try std.testing.expectError(error.MfSigMalformed, verifySidecar(a, payload, "{not json"));
}
