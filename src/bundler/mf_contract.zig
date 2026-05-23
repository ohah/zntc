//! P3-0 (#3435): 빌드타임 계약 검증 토대 — host 빌드가 `mf.remotes` 의
//! remote 가 게시한 `mf-manifest.json` 을 resolve+parse 하여
//! `RemoteContract` 데이터 모델로 만든다. **검증 없음(파싱·표면만)** —
//! expose 존재(P3-1)·shared 버전 호환(P3-2)·무결성(P3-3)·런타임 가드
//! (P3-5)는 이 토대를 소비하는 후속 단위가 얹는다(중복 파서 금지).
//!
//! 스키마 단일 소스: `federation_emit.zig:buildManifest` 가 emit 하는
//! `@module-federation/sdk@2.4.0` Manifest 형태(name/exposes[].name/
//! shared[].{name,version,requiredVersion,singleton})를 그대로 읽는다.
//! emit↔parse 정합은 inline test 가 buildManifest 산출을 라운드트립으로
//! 박제(스키마 drift 시 컴파일·테스트 fail = 단일 소스 보장).
//!
//! 경계(RFC §7.3 ③): remote manifest 의 **네트워크 fetch(http/https)는
//! 비-목표** — local/file resolve 우선(`MfContractNetworkUnsupported`).
//! 신뢰 모델·캐시·HTTP 다운로드는 P4(RN 보안 모델)/후속. 에러 명명은
//! `mf_integrity.zig` 의 `MfSig*` 선례를 답습(`MfContract*`).
const std = @import("std");
const mf_integrity = @import("mf_integrity.zig"); // P3-3 computeSri/verifySidecar 재사용

pub const MfContractError = error{
    /// JSON 파싱 실패 또는 manifest 스키마 불일치.
    MfContractMalformed,
    /// remote entry 가 http/https — 빌드타임 네트워크 fetch 비-목표(P4).
    MfContractNetworkUnsupported,
    /// resolve 된 manifest 파일이 없음(sibling 빌드 미산출 등) — P3-1 이
    /// "remote manifest 부재"를 파싱 실패와 구분해 fail-fast 메시지.
    MfContractManifestNotFound,
    /// P3-3: sidecar 가 가리키는 SHA-256 다이제스트 ≠ 실제 manifest
    /// (stale 또는 변조) — 빌드 fail-fast.
    MfIntegrityMismatch,
    /// P3-3: `.sig`(Ed25519) 가 sidecar 와 불일치(변조/잘못된 키) —
    /// 빌드 fail-fast.
    MfIntegritySignatureInvalid,
};

/// OOM 은 빌드 환경 자원 문제이므로 manifest 결함(MfContractMalformed)과
/// 섞지 않는다(진단 정확성). std.json/alloc 의 OutOfMemory 는 그대로 전파.
const ParseError = MfContractError || std.mem.Allocator.Error;

/// remote 가 게시한 shared 의존 1건(계약면). version 은 remote 가 박은 값,
/// required_version 은 remote 의 요구 range — P3-2 가 host 요구와 교차검증.
pub const SharedContract = struct {
    name: []const u8,
    version: []const u8,
    required_version: []const u8,
    singleton: bool,
};

/// remote 가 게시한 계약면(파싱 결과). 모든 슬라이스/문자열은 `arena`
/// 소유 — `manifest_bytes` 수명과 독립(alloc_always). 소비 측은
/// `defer rc.deinit()` 하나로 일괄 해제(CLAUDE.md arena 규약: 개별
/// deinit 금지, 단일 소유자만 arena.deinit()).
pub const RemoteContract = struct {
    arena: std.heap.ArenaAllocator,
    /// manifest.name (= container globalName).
    name: []const u8,
    /// manifest.exposes[].name (공개 키, 예 "./Widget"). P3-1 이 host
    /// import 와 대조.
    exposes: []const []const u8,
    /// manifest.shared[] (name/version/requiredVersion/singleton). P3-2.
    shared: []const SharedContract,

    pub fn deinit(self: *RemoteContract) void {
        self.arena.deinit();
    }
};

// federation_emit.buildManifest 가 emit 하는 키만 추림(나머지 무시).
// 필드명 = JSON 키 그대로(camelCase requiredVersion) — std.json 매핑.
const ExposeJson = struct { name: []const u8 = "" };
const SharedJson = struct {
    name: []const u8 = "",
    version: []const u8 = "",
    requiredVersion: []const u8 = "",
    singleton: bool = false,
};
const ManifestJson = struct {
    name: []const u8 = "",
    exposes: []const ExposeJson = &.{},
    shared: []const SharedJson = &.{},
};

/// `mf-manifest.json` 바이트 → `RemoteContract`. unknown 필드 무시
/// (metaData/remotes/exposes.assets 등 표준 부가키 관용). 모든 문자열은
/// arena 로 dup(alloc_always) — caller 가 manifest_bytes 를 free 해도 안전.
/// host-only manifest(exposes/shared 키 부재)는 빈 슬라이스(관용 — 검증은
/// P3-1+ 책임). 실패 시 `MfContractMalformed`.
pub fn parseContract(gpa: std.mem.Allocator, manifest_bytes: []const u8) ParseError!RemoteContract {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    const m = std.json.parseFromSliceLeaky(ManifestJson, a, manifest_bytes, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.MfContractMalformed, // 스키마/구문 결함
    };

    const exposes = try a.alloc([]const u8, m.exposes.len);
    for (m.exposes, 0..) |e, i| exposes[i] = e.name;

    const shared = try a.alloc(SharedContract, m.shared.len);
    for (m.shared, 0..) |s, i| shared[i] = .{
        .name = s.name,
        .version = s.version,
        .required_version = s.requiredVersion,
        .singleton = s.singleton,
    };

    return .{ .arena = arena, .name = m.name, .exposes = exposes, .shared = shared };
}

fn isHttp(s: []const u8) bool {
    return std.mem.startsWith(u8, s, "http://") or std.mem.startsWith(u8, s, "https://");
}

/// remote spec entry(`parseRemote` 의 entry — remoteEntry URL/경로) →
/// 그 remote 의 `mf-manifest.json` **로컬 경로**(owned, caller free).
/// 규약: entry 가 `.json` 으로 끝나면 그 자체가 manifest, 아니면
/// `<entry 디렉터리>/mf-manifest.json`(zntc 가 remoteEntry 와 나란히 산출 —
/// federation_emit). 정규화만(realpath 안 함 — sibling 빌드 산출이라
/// 아직 미존재 가능, FS 비의존 = 단위테스트 결정적). http/https 는
/// `MfContractNetworkUnsupported`(네트워크 fetch=P4/후속, RFC §7.3 ③).
pub fn resolveManifestPath(
    gpa: std.mem.Allocator,
    cwd: ?[]const u8,
    entry: []const u8,
) !([]const u8) {
    if (isHttp(entry)) return error.MfContractNetworkUnsupported;
    const base = cwd orelse ".";
    const joined = if (std.fs.path.isAbsolute(entry))
        try gpa.dupe(u8, entry)
    else
        try std.fs.path.join(gpa, &.{ base, entry });
    if (std.mem.endsWith(u8, joined, ".json")) return joined;
    defer gpa.free(joined);
    const dir = std.fs.path.dirname(joined) orelse base;
    return std.fs.path.join(gpa, &.{ dir, "mf-manifest.json" });
}

/// resolveManifestPath → 파일 읽기 → parseContract 의 편의 결합.
/// local/file only. manifest 최대 4MiB(표준 manifest 는 수 KB).
pub fn loadContract(
    gpa: std.mem.Allocator,
    cwd: ?[]const u8,
    entry: []const u8,
) !RemoteContract {
    const path = try resolveManifestPath(gpa, cwd, entry);
    defer gpa.free(path);
    const bytes = std.fs.cwd().readFileAlloc(gpa, path, 4 * 1024 * 1024) catch |e| switch (e) {
        error.FileNotFound => return error.MfContractManifestNotFound, // 부재 ≠ 결함
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.MfContractMalformed, // 읽기 실패(권한·IO 등)
    };
    defer gpa.free(bytes);
    return parseContract(gpa, bytes);
}

/// P2-2 sidecar(`{version,algorithm,files:{<basename>:"sha256-<b64>"}}`)
/// 에서 `name` 파일의 기대 SRI(owned dup) 또는 null(키 부재). 동적 키
/// map 은 std.json ArrayHashMap 으로 파싱. 파싱 실패는 null(검증 불가
/// ≠ 위반 — 호출측이 skip). pure(FS 비의존, inline test 가능).
fn sidecarFileSri(gpa: std.mem.Allocator, sidecar_bytes: []const u8, name: []const u8) !?[]const u8 {
    const Sidecar = struct {
        algorithm: []const u8 = "",
        files: std.json.ArrayHashMap([]const u8) = .{},
    };
    const parsed = std.json.parseFromSlice(Sidecar, gpa, sidecar_bytes, .{
        .ignore_unknown_fields = true,
    }) catch return null; // sidecar malformed = 검증 불가
    defer parsed.deinit();
    const sri = parsed.value.files.map.get(name) orelse return null;
    return try gpa.dupe(u8, sri);
}

/// P3-3 (#3438): 빌드타임 무결성 검증. host 가 소비하는 remote 의
/// 게시 manifest 가 그 옆 sidecar(`<manifest>.integrity.json`, P2-2
/// SHA-256)와 일치하나 — 불일치(stale/변조) → fail-fast
/// `MfIntegrityMismatch`. `.sig`(P2-3 Ed25519, opt-in) 가 있으면
/// sidecar 서명 검증(`mf_integrity.verifySidecar` 재사용) — 불일치 →
/// `MfIntegritySignatureInvalid`. **sidecar/`.sig` 부재·malformed·키
/// 부재 = 검증 불가 ≠ 위반 → 조용히 통과(정밀 fail-fast — 비-zntc
/// remote·미서명 무회귀, P3-1/P3-2 "검증 불가 ≠ 위반" 답습)**. D3
/// "런타임 가드"의 빌드타임 절반(런타임 강제 verify·청크 무결성은
/// P3-5/RN). manifest 는 loadContract 와 별도 1회 더 read(SRI 계산용
/// — KB·소수 remote, P3-1/2 per-import 비용 모델 답습; 응집 위해
/// mf_contract 단일 위치). 네트워크 entry → resolveManifestPath 가
/// `MfContractNetworkUnsupported`(호출측 skip).
pub fn verifyIntegrity(gpa: std.mem.Allocator, cwd: ?[]const u8, entry: []const u8) !void {
    const path = try resolveManifestPath(gpa, cwd, entry);
    defer gpa.free(path);
    const manifest = std.fs.cwd().readFileAlloc(gpa, path, 4 * 1024 * 1024) catch |e| switch (e) {
        error.FileNotFound => return error.MfContractManifestNotFound,
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.MfContractMalformed,
    };
    defer gpa.free(manifest);

    const sc_path = try std.fmt.allocPrint(gpa, "{s}.integrity.json", .{path});
    defer gpa.free(sc_path);
    const sidecar = std.fs.cwd().readFileAlloc(gpa, sc_path, 4 * 1024 * 1024) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return, // sidecar 부재/읽기불가 = 검증 불가 ≠ 위반 → skip
    };
    defer gpa.free(sidecar);

    // SHA-256: sidecar 가 기대하는 manifest SRI vs 실제 재계산.
    const expected = (try sidecarFileSri(gpa, sidecar, std.fs.path.basename(path))) orelse return;
    defer gpa.free(expected);
    const actual = try mf_integrity.computeSri(gpa, manifest);
    defer gpa.free(actual);
    if (!std.mem.eql(u8, expected, actual)) return error.MfIntegrityMismatch;

    // Ed25519: `.sig`(opt-in) 있으면 sidecar 서명 검증.
    const sig_path = try std.fmt.allocPrint(gpa, "{s}.sig", .{sc_path});
    defer gpa.free(sig_path);
    const sig = std.fs.cwd().readFileAlloc(gpa, sig_path, 64 * 1024) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return, // 미서명(P2-3 opt-in) = 검증 불가 ≠ 위반 → skip
    };
    defer gpa.free(sig);
    // verifySidecar 에러셋 = MfSig*(OOM 은 내부서 MfSigMalformed 로 매핑)
    // → 어느 실패든 서명 무효(변조/잘못된 키).
    mf_integrity.verifySidecar(gpa, sidecar, sig) catch return error.MfIntegritySignatureInvalid;
}

// ── inline tests (zig build test — mod.zig 등록) ──────────────────────

test "parseContract: buildManifest 스키마 — name/exposes/shared 추출, unknown 무시" {
    const a = std.testing.allocator;
    // federation_emit.zig:362-444 가 emit 하는 형태(metaData/remotes/
    // exposes.assets 등 부가키 포함 — 전부 무시되어야).
    const json =
        \\{"id":"app","name":"app","metaData":{"name":"app","type":"app",
        \\"buildInfo":{"buildVersion":"0.1.0"},"globalName":"app"},
        \\"shared":[{"id":"app:react","name":"react","version":"^19",
        \\"singleton":true,"requiredVersion":"^19","hash":"","assets":{}}],
        \\"remotes":[{"entry":"x","federationContainerName":"y"}],
        \\"exposes":[{"id":"app:Widget","name":"./Widget","path":"./Widget",
        \\"assets":{"js":{"async":["w.js"]}}},
        \\{"id":"app:Btn","name":"./Btn","path":"./Btn","assets":{}}]}
    ;
    var rc = try parseContract(a, json);
    defer rc.deinit();
    try std.testing.expectEqualStrings("app", rc.name);
    try std.testing.expectEqual(@as(usize, 2), rc.exposes.len);
    try std.testing.expectEqualStrings("./Widget", rc.exposes[0]);
    try std.testing.expectEqualStrings("./Btn", rc.exposes[1]);
    try std.testing.expectEqual(@as(usize, 1), rc.shared.len);
    try std.testing.expectEqualStrings("react", rc.shared[0].name);
    try std.testing.expectEqualStrings("^19", rc.shared[0].version);
    try std.testing.expectEqualStrings("^19", rc.shared[0].required_version);
    try std.testing.expect(rc.shared[0].singleton);
}

test "parseContract: host-only(exposes/shared 키 부재) 관용 — 빈 슬라이스" {
    const a = std.testing.allocator;
    var rc = try parseContract(a, "{\"name\":\"host\",\"metaData\":{}}");
    defer rc.deinit();
    try std.testing.expectEqualStrings("host", rc.name);
    try std.testing.expectEqual(@as(usize, 0), rc.exposes.len);
    try std.testing.expectEqual(@as(usize, 0), rc.shared.len);
}

test "parseContract: 깨진 JSON → MfContractMalformed" {
    try std.testing.expectError(error.MfContractMalformed, parseContract(std.testing.allocator, "{not json"));
}

test "parseContract: arena 자기완결 — manifest_bytes free 후에도 유효" {
    const a = std.testing.allocator;
    const src = "{\"name\":\"r\",\"exposes\":[{\"name\":\"./X\"}]}";
    const buf = try a.dupe(u8, src);
    var rc = try parseContract(a, buf);
    defer rc.deinit();
    a.free(buf); // 입력 해제 — alloc_always 라 rc 는 독립 소유
    try std.testing.expectEqualStrings("r", rc.name);
    try std.testing.expectEqualStrings("./X", rc.exposes[0]);
}

test "resolveManifestPath: .json 직접·remoteEntry sibling·절대·http 거부" {
    const a = std.testing.allocator;
    // 1) .json 직접 → 그대로(정규화)
    const p1 = try resolveManifestPath(a, "/proj", "rmt/mf-manifest.json");
    defer a.free(p1);
    try std.testing.expectEqualStrings("/proj/rmt/mf-manifest.json", p1);
    // 2) remoteEntry.js → sibling mf-manifest.json
    const p2 = try resolveManifestPath(a, "/proj", "rmt/dist/remoteEntry.js");
    defer a.free(p2);
    try std.testing.expectEqualStrings("/proj/rmt/dist/mf-manifest.json", p2);
    // 3) 절대 entry → cwd 무시
    const p3 = try resolveManifestPath(a, "/proj", "/abs/r/mf-manifest.json");
    defer a.free(p3);
    try std.testing.expectEqualStrings("/abs/r/mf-manifest.json", p3);
    // 4) http/https → 비-목표
    try std.testing.expectError(error.MfContractNetworkUnsupported, resolveManifestPath(a, "/p", "https://cdn/x/remoteEntry.js"));
    try std.testing.expectError(error.MfContractNetworkUnsupported, resolveManifestPath(a, "/p", "http://cdn/x/mf-manifest.json"));
}

// 스키마 단일 소스 박제: federation_emit.buildManifest 가 emit 한 실제
// manifest 를 parseContract 가 라운드트립. emit 스키마가 drift 하면 이
// 테스트가 fail = "P2-0/P2-1 sdk 타입 단일 재사용"(RFC §7.3) 강제.
test "emit↔parse 라운드트립: buildManifest 산출을 parseContract 가 복원" {
    const a = std.testing.allocator;
    const types = @import("types.zig");
    const fe = @import("federation_emit.zig");
    const shared = [_]types.MfBundleConfig.SharedEntry{
        .{ .name = "react", .singleton = true, .required_version = "^19" },
    };
    const mf = types.MfBundleConfig{
        .name = "app",
        .shared = &shared,
    };
    const exposes = [_]fe.ExposeInfo{
        .{ .name = "./Widget", .fed_id = "fid0", .chunk_file = "w.js" },
        .{ .name = "./Btn", .fed_id = "fid1", .chunk_file = "b.js" },
    };
    const manifest = try fe.buildManifest(a, "app", &mf, &exposes, "remoteEntry.js", "", "auto");
    defer a.free(manifest);

    var rc = try parseContract(a, manifest);
    defer rc.deinit();
    try std.testing.expectEqualStrings("app", rc.name);
    try std.testing.expectEqual(@as(usize, 2), rc.exposes.len);
    try std.testing.expectEqualStrings("./Widget", rc.exposes[0]);
    try std.testing.expectEqualStrings("./Btn", rc.exposes[1]);
    try std.testing.expectEqual(@as(usize, 1), rc.shared.len);
    try std.testing.expectEqualStrings("react", rc.shared[0].name);
    try std.testing.expect(rc.shared[0].singleton);
    // P2-0: version 은 required_version 대용 → 둘 다 "^19"
    try std.testing.expectEqualStrings("^19", rc.shared[0].version);
    try std.testing.expectEqualStrings("^19", rc.shared[0].required_version);
}

// sidecar build↔verify 단일 소스 박제: mf_integrity.buildSidecar 가
// 만든 실제 sidecar 를 sidecarFileSri 가 복원해 computeSri 와 일치.
// buildSidecar 스키마가 drift 하면 이 test 가 fail(P3-0 emit↔parse
// 라운드트립 선례 — 무결성 계약 단일 소스 강제).
test "sidecarFileSri: buildSidecar 라운드트립 + 키 부재 + malformed" {
    const a = std.testing.allocator;
    const manifest = "{\"name\":\"app\",\"exposes\":[]}";
    const sc = try mf_integrity.buildSidecar(a, "mf-manifest.json", manifest, &.{});
    defer a.free(sc);
    const got = (try sidecarFileSri(a, sc, "mf-manifest.json")).?;
    defer a.free(got);
    const want = try mf_integrity.computeSri(a, manifest);
    defer a.free(want);
    try std.testing.expectEqualStrings(want, got); // 빌드 SRI ≡ 재계산
    try std.testing.expect((try sidecarFileSri(a, sc, "nope.js")) == null); // 키 부재
    try std.testing.expect((try sidecarFileSri(a, "{not json", "x")) == null); // malformed = null
}

test "sidecarFileSri: 변조 manifest → SRI 불일치 탐지" {
    const a = std.testing.allocator;
    const sc = try mf_integrity.buildSidecar(a, "mf-manifest.json", "ORIG", &.{});
    defer a.free(sc);
    const expected = (try sidecarFileSri(a, sc, "mf-manifest.json")).?;
    defer a.free(expected);
    const tampered = try mf_integrity.computeSri(a, "TAMPERED");
    defer a.free(tampered);
    try std.testing.expect(!std.mem.eql(u8, expected, tampered)); // verifyIntegrity 의 mismatch 핵심
}

test "loadContract: 부재 → MfContractManifestNotFound, 디렉터리(IsDir) → MfContractMalformed" {
    const a = std.testing.allocator;
    // 부재(절대 .json) → 부재 ≠ 결함(P3-1 이 구분해 fail-fast 메시지)
    try std.testing.expectError(
        error.MfContractManifestNotFound,
        loadContract(a, null, "/zntc-nonexistent-xyzzy/mf-manifest.json"),
    );
    // read-fail(권한/IO 류) — 디렉터리를 manifest 경로로 → IsDir → 결함
    var td = std.testing.tmpDir(.{});
    defer td.cleanup();
    try td.dir.makeDir("d.json");
    const base = try td.dir.realpathAlloc(a, ".");
    defer a.free(base);
    const dirpath = try std.fs.path.join(a, &.{ base, "d.json" });
    defer a.free(dirpath);
    try std.testing.expectError(error.MfContractMalformed, loadContract(a, null, dirpath));
}
