//! P1-3 (#3385): webpack-style container emit (remoteEntry).
//!
//! emitChunks 산출 후처리 — entry(remoteEntry) 청크의 eager bootstrap
//! `[var X = ]globalThis.__zntc_require("<id>");` 을 container 객체로 치환.
//! container = `{ get(expose):Promise<factory>, init(shareScope,initScope) }`,
//! `g.<name>` 에 대입(globalName 소유 = container).
//!
//! exposed 모듈은 P1-3 `chunk.zig` 가 동적-import 타깃과 동일하게 자기 lazy
//! 청크로 분리했으므로(reg_id = federation_id), get 은 동적-import wrapper
//! `__zntc_load_chunk(file).then(()=>__zntc_require(fed_id))` 를 그대로 emit
//! — exposed 번들 eval 은 get() 까지 지연(reg_split self-register 가 lazy
//! 보장). init-before-get 은 `__zntc_mf_inited` 가드 + MF2 런타임 계약
//! (RUNTIME-009)에 위임.
//!
//! 비-목표: init 의 실제 shared 글로벌 채움·shareScopeMap(P1-4), 별도
//! mf-manifest.json/remoteEntry.js 파일 에미터(P1-5), host remotes 소비(P1-6).
const std = @import("std");
const types = @import("types.zig");
const federation = @import("federation.zig");
const rt = @import("runtime_helpers.zig");
const emitter = @import("emitter.zig");
const mf_contract = @import("mf_contract.zig"); // P3-1 계약 검증 토대(P3-0)
const semver = @import("semver.zig"); // P3-2 shared 버전 호환 단일 소스

/// 부트스트랩 호출(=entry 청크 식별 앵커). cross-chunk/동적 wrapper 의
/// `__zntc_require("` 와 달리 `globalThis.` 접두가 붙는 건 부트스트랩뿐
/// (chunks.zig:809) → 유일 식별.
const BOOTSTRAP_ANCHOR = "globalThis.__zntc_require(\"";

const MfEmitError = error{RemoteEntryAnchorMissing};

const MF_RUNTIME_GLOBAL = federation.MF_RUNTIME_GLOBAL; // 단일 소스

/// 동적 import 어휘 앵커 — emitHostInit(재작성)·verifyHostContract(P3-1
/// 계약 검증)가 같은 스캐너를 공유(단일 소스).
const IMPORT_NEEDLE = "import(";

/// P3-5 (#3440): 런타임 가드. host 의 `import("remote/x")` 는
/// `<MF_GUARDED>(...)` 로 치환되고, prelude 가 이 글로벌을 정의 —
/// `loadRemote` 를 감싸 **거부 시 graceful 폴백**(셸 크래시 방지).
/// D3 "빌드 핀 + 런타임 가드"의 런타임 절반: P3-1/2/3 은 manifest 가
/// 로컬 resolve 가능할 때만 빌드 차단(http remote·배포후 drift 는
/// 검증 불가→skip) → 그 사각을 런타임 가드가 메움. 성공 경로는 불변
/// (loadRemote 결과 passthrough → S3/S4/P2-5 interop 보존), 거부만
/// catch. 폴백은 silent 아님: console.error + `__mfUnavailable:true`
/// (관측가능·비-차단). loadRemote 인자 그대로 forward(`arguments`).
const MF_GUARDED = "globalThis.__mfGuardedLoad";
const GUARD_DEF = MF_GUARDED ++ "=function(){var RR=globalThis." ++ MF_RUNTIME_GLOBAL ++
    ",a=arguments,id=a[0];function F(){return{default:function(){return null;},__mfUnavailable:true};}" ++
    "try{return Promise.resolve(RR.loadRemote.apply(RR,a)).catch(function(e){" ++
    "console.error(\"[mf] runtime guard: remote '\"+id+\"' failed to load (contract drift or unreachable; " ++
    "build-time P3 verification applies only when the manifest is locally resolvable). Rendering fallback.\",e);" ++
    "return F();});}catch(e){console.error(\"[mf] runtime guard: remote '\"+id+\"' sync error.\",e);" ++
    "return Promise.resolve(F());}};";

/// `mf.remotes` KV.value(`<name>@<entry>`) → (name, entry). `@` 첫 등장
/// split. name 부분 비면 KV.key fallback. `@` 없으면 value 전체=entry.
/// 한계: scoped-like value(`@scope/x@url`)는 첫 `@`(idx 0) split →
/// name="" → key fallback, entry 는 `@` 손실(`scope/x@url`). MF remote
/// value 관례는 `bareName@url` 라 비규약 입력 — 비지원(문서화).
fn parseRemote(kv: types.MfBundleConfig.KV) struct { name: []const u8, entry: []const u8 } {
    if (std.mem.indexOfScalar(u8, kv.value, '@')) |at| {
        const nm = kv.value[0..at];
        return .{ .name = if (nm.len > 0) nm else kv.key, .entry = kv.value[at + 1 ..] };
    }
    return .{ .name = kv.key, .entry = kv.value };
}

/// specifier 가 어떤 remote(`<key>`/`<key>/...`)에 매칭 — 판정 규칙은
/// federation.matchesRemoteSpec 단일 소스(런타임 external 판정과 동일).
fn isRemoteSpec(spec: []const u8, mf: *const types.MfBundleConfig) bool {
    for (mf.remotes) |kv| if (federation.matchesRemoteSpec(spec, kv.key)) return true;
    return false;
}

/// P1-6 host emit: 스펙 `@module-federation/runtime` 재사용(D1 — 자체
/// 재구현 금지). src 앞에 init prelude(`globalThis.__mf_runtime.init({name,
/// remotes})`)를 prepend + 런타임 가드(`__mfGuardedLoad`, P3-5) 정의 +
/// 원격 동적 `import("remote/x")` 를 `globalThis.__mfGuardedLoad(
/// "remote/x")` 로 치환(가드가 내부에서 `loadRemote` 호출 + 거부 폴백).
/// runtime 은 applyMfRemotesSeam 이 external+글로벌(__mf_runtime) 처리 →
/// host 환경이 그 글로벌로 스펙 런타임 제공(P1-2/P1-3 글로벌-seam 모델
/// 일관, iife/umd/amd valid). 반환 = 새 owned 문자열(caller 가 기존 src
/// free). 정적 `import X from "remote/x"` 는 비-목표(async 강등 — 후속).
pub fn emitHostInit(
    allocator: std.mem.Allocator,
    src: []const u8,
    mf: *const types.MfBundleConfig,
    /// PR-2 (#3459): 링킹이 발견한 **정적** `import … from "remote/x"`
    /// specifier 집합(metadata.zig 수집). 비면 정적 import 없음 →
    /// 게이트 미emit(출력 byte 동일 = 동적-only/비-MF 무회귀). 비어있지
    /// 않으면 prelude 뒤에 async preload-gate 를 emit 하고 src(=host
    /// body) 를 그 `.then()` 안으로 deferral — seam 글로벌이 채워진
    /// 뒤 body 실행(표준 enhanced AsyncBoundaryPlugin 동형).
    static_specs: []const []const u8,
) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    // ── init prelude (멱등: runtime.init 자체 멱등) + 런타임 가드 정의 ──
    try out.appendSlice(allocator, "(function(){var R=globalThis." ++ MF_RUNTIME_GLOBAL ++ ";if(R&&R.init)R.init({\"name\":");
    try emitter.appendJsonString(&out, allocator, mf.name orelse "host");
    try out.appendSlice(allocator, ",\"remotes\":[");
    for (mf.remotes, 0..) |kv, i| {
        if (i > 0) try out.append(allocator, ',');
        const r = parseRemote(kv);
        try out.appendSlice(allocator, "{\"name\":");
        try emitter.appendJsonString(&out, allocator, r.name);
        try out.appendSlice(allocator, ",\"entry\":");
        try emitter.appendJsonString(&out, allocator, r.entry);
        try out.append(allocator, '}');
    }
    // #2 (감사): shareStrategy 를 init 인자로 배선 — 표준
    // @module-federation/runtime 이 Options.shareStrategy 로 읽어 협상
    // 순서(version-first|loaded-first) 적용(D1 위임, zntc 자체 협상 X).
    try out.appendSlice(allocator, "],\"shareStrategy\":");
    try emitter.appendJsonString(&out, allocator, mf.share_strategy);
    // P3-5: init 후 가드 정의(글로벌 — 모듈 스코프 재작성 코드가 호출).
    try out.appendSlice(allocator, "});" ++ GUARD_DEF ++ "})();");

    // PR-2 (#3459): 정적 remote import async preload-gate. 정적 import
    // 구문은 PR-1 이 elide 하고 `var X = __mf_remote_<san>[.default]`
    // (metadata.zig) preamble 만 남김 — 그 seam 글로벌을 host body
    // **실행 전** 채워야 binding 이 유효. 각 spec 을 __mfGuardedLoad
    // (P3-5 가드 — 거부 시 graceful 폴백, 비-reject) 로 병렬 preload →
    // seam 글로벌 대입 → 그 다음 `.then` 에서 host body(src) 실행.
    // 표준 @module-federation/enhanced AsyncBoundaryPlugin 의
    // `Promise.all(track).then(body)` 와 동형(정적 federated import =
    // entry async boundary). 정적 import 0개면 미emit → 출력 byte
    // 동일(동적-only/비-MF 무회귀). IIFE 함수본문 TLA 불가라 async
    // IIFE 아닌 `.then()` 콜백.
    const gated = static_specs.len > 0;
    if (gated) {
        try out.appendSlice(allocator, "Promise.all([");
        for (static_specs, 0..) |spec, si| {
            if (si > 0) try out.append(allocator, ',');
            try out.appendSlice(allocator, MF_GUARDED ++ "(");
            try emitter.appendJsonString(&out, allocator, spec);
            try out.append(allocator, ')');
        }
        try out.appendSlice(allocator, "]).then(function(__mfm){");
        for (static_specs, 0..) |spec, si| {
            const g = try federation.mfRemoteGlobalName(allocator, spec);
            defer allocator.free(g);
            try out.appendSlice(allocator, "globalThis.");
            try out.appendSlice(allocator, g);
            try out.appendSlice(allocator, "=__mfm[");
            try std.fmt.format(out.writer(allocator), "{d}", .{si});
            try out.appendSlice(allocator, "];");
        }
        try out.appendSlice(allocator, "}).then(function(){");
    }

    // ── 원격 동적 import 재작성: `import(<q><remote>...)` →
    //    `globalThis.__mfGuardedLoad(<q><remote>...)`(P3-5 가드 경유 —
    //    내부서 loadRemote + 거부 폴백). 매칭 외 구간은 appendSlice 청크
    //    복사(바이트별 append 회피, wrapContainer splice 관례). `import(`
    //    만 교체 — 따옴표·specifier·잔여(2nd-arg/attributes)·닫는 괄호는
    //    그대로 보존(가드가 인자 forward → 닫는 괄호 추적 불요). 스캔은
    //    nextRemoteImport 단일 소스(verifyHostContract 와 규칙 공유). ──
    var last: usize = 0;
    var i: usize = 0;
    while (nextRemoteImport(src, mf, &i)) |h| {
        try out.appendSlice(allocator, src[last..h.p]);
        try out.appendSlice(allocator, MF_GUARDED ++ "(");
        last = h.p + IMPORT_NEEDLE.len; // 따옴표부터는 다음 flush 가 보존
    }
    try out.appendSlice(allocator, src[last..]);
    if (gated) try out.appendSlice(allocator, "});"); // .then(function(){ <body> })
    return out.toOwnedSlice(allocator);
}

const RemoteImportHit = struct { p: usize, spec: []const u8 };

/// host src 의 다음 **원격** 동적 import. `import(` 어휘 스캔 +
/// federation.matchesRemoteSpec 단일 규칙(런타임 external 판정과 동일).
/// `i` 는 진행점(in/out) — 다음 호출이 그 뒤부터. 비원격/식별자경계
/// (`xfoo import(` 의 `myimport(`)·따옴표 없는 동적 import 는 내부에서
/// skip, 원격 매칭만 반환. emitHostInit(재작성)·verifyHostContract(P3-1
/// 계약 검증) 공용 → 스캔·매칭 중복 파서 금지(단일 소스).
fn nextRemoteImport(src: []const u8, mf: *const types.MfBundleConfig, i: *usize) ?RemoteImportHit {
    var k = i.*;
    while (std.mem.indexOfPos(u8, src, k, IMPORT_NEEDLE)) |p| {
        if (p > 0 and isIdentChar(src[p - 1])) { // `myimport(` 부분일치 배제
            k = p + IMPORT_NEEDLE.len;
            continue;
        }
        var j = p + IMPORT_NEEDLE.len;
        while (j < src.len and (src[j] == ' ' or src[j] == '\t')) j += 1;
        if (j < src.len and (src[j] == '"' or src[j] == '\'')) {
            const q = src[j];
            const s0 = j + 1;
            if (std.mem.indexOfScalarPos(u8, src, s0, q)) |s1| {
                if (isRemoteSpec(src[s0..s1], mf)) {
                    i.* = p + IMPORT_NEEDLE.len;
                    return .{ .p = p, .spec = src[s0..s1] };
                }
            }
        }
        k = p + IMPORT_NEEDLE.len;
    }
    i.* = k;
    return null;
}

fn stripDotSlash(s: []const u8) []const u8 {
    return if (std.mem.startsWith(u8, s, "./")) s[2..] else s;
}

/// host import spec(매칭 remote `key`)이 가리키는 expose 가 remote 가
/// 게시한 계약(`exposes`)에 존재하나. spec==key → 컨테이너 기본 expose
/// "."(드묾), 아니면 `key/<rest>`. manifest expose 는 mf.exposes 키 그대로
/// (관례 "./Widget") — 양쪽 선행 "./" 1회 정규화 후 정확 비교.
fn exposeListed(exposes: []const []const u8, spec: []const u8, key: []const u8) bool {
    const sub: []const u8 = if (std.mem.eql(u8, spec, key))
        "."
    else if (spec.len > key.len + 1 and std.mem.startsWith(u8, spec, key) and spec[key.len] == '/')
        spec[key.len + 1 ..]
    else
        spec; // 방어(matchesRemoteSpec 통과면 위 둘 중 하나)
    const sn = stripDotSlash(sub);
    for (exposes) |e| if (std.mem.eql(u8, stripDotSlash(e), sn)) return true;
    return false;
}

/// host↔remote shared 1쌍 판정(순수 — IO·로그 없음, 단위테스트 가능).
const SharedVerdict = enum {
    ok, // 호환(또는 검증 불가 = 정밀 fail-fast 로 통과)
    singleton_conflict, // singleton 불일치 — 결정적, 인스턴스 분열 → fail-fast
    version_warn, // host range 가 remote concrete version 불만족 → 경고(비차단)
};

/// host shared 선언 vs remote 가 게시한 shared. singleton 불일치는
/// 버전과 무관한 **결정적** 위반(런타임 인스턴스 분열 보장) → fail-fast.
/// 버전은 host required_version(range) 가 remote 의 concrete version 을
/// 만족하나 — semver.satisfies 가 `null`(remote.version 비-concrete:
/// zntc P2-0 는 version=range 대용 / range 지원밖)이면 **판정 불가 →
/// ok**(정밀 fail-fast: 거짓 경고 금지). `false` 일 때만 version_warn.
fn sharedVerdict(host: types.MfBundleConfig.SharedEntry, remote: mf_contract.SharedContract) SharedVerdict {
    if (host.singleton != remote.singleton) return .singleton_conflict;
    const hr = host.required_version orelse return .ok; // host 무제약 → 버전 검사 없음
    const sat = semver.satisfies(hr, remote.version) orelse return .ok; // 판정 불가 → 통과
    return if (sat) .ok else .version_warn;
}

/// P3-1 (#3436) expose + P3-2 (#3437) shared: 빌드타임 host 계약 검증.
/// host 가 `import("<remote>/<subpath>")` 하는 각 remote 의 게시
/// mf-manifest.json 을 1회 로드(P3-0 mf_contract 토대)해:
///   - **expose 부재** → fail-fast `error.MfHostExposeMissing`(S6 — 런타임
///     깨짐이 아니라 빌드 차단).
///   - **shared singleton 불일치** → fail-fast
///     `error.MfSharedSingletonConflict`(결정적, react 등 인스턴스 분열).
///   - **shared 버전 비호환**(host range ⊅ remote concrete version) →
///     **경고**(std.log.warn, 비차단) — D3 빌드타임 가시성. 판정 불가
///     (remote.version 비-concrete=zntc P2-0 / range 지원밖)는 skip.
/// manifest 로컬 resolve 불가(http=네트워크 비-목표 P4 / 부재 / 파싱불가)면
/// **검증 불가 ≠ 위반** → skip(정밀 fail-fast — 거짓 빌드중단 방지,
/// http remote·미산출 sibling 기존 동작 불변). 검증만 — emit/재작성
/// 부작용 없음(중복 파서 없음, nextRemoteImport·matchesRemoteSpec 단일
/// 소스 재사용). emitHostInit 게이트(remotes>0·단일출력)와 동일 적용점
/// 에서 emit *전* 호출. 같은 remote 다중 import 시 경고 중복 가능(소규모
/// — P3-1 선례대로 허용, dedup 은 후속).
pub fn verifyHostContract(
    allocator: std.mem.Allocator,
    src: []const u8,
    mf: *const types.MfBundleConfig,
    cwd: ?[]const u8,
    /// PR-3 (#3459): 정적 `import … from "remote/x"` 는 codegen 이
    /// elide(PR-1) → `nextRemoteImport`(동적 `import(` 스캔)에 안 잡힘.
    /// metadata.zig 가 수집한 정적 spec(emitHostInit 와 동일 집합)을
    /// 받아 동적과 **동일 per-spec 검증**(P3-1/2/3) 적용 — 정적 import
    /// 의 expose 부재 fail-fast 갭을 닫는다(verifyOneRemoteSpec 단일소스).
    static_specs: []const []const u8,
) !void {
    var i: usize = 0;
    while (nextRemoteImport(src, mf, &i)) |h|
        try verifyOneRemoteSpec(allocator, h.spec, mf, cwd);
    for (static_specs) |spec|
        try verifyOneRemoteSpec(allocator, spec, mf, cwd);
}

/// host import spec 1개의 P3-1(expose)·P3-2(shared)·P3-3(무결성) 검증.
/// 동적(`nextRemoteImport`)·정적(`static_specs`) 양쪽이 공유하는 단일
/// 소스(중복 검증 로직 금지). spec 이 remote 와 매칭 안 됨 / manifest
/// 로컬 resolve 불가(http=P4·부재·파싱불가)면 **검증 불가 ≠ 위반 →
/// 통과**(정밀 fail-fast). 같은 spec 다중 import·정적∩동적 중복 검증
/// 가능(소규모 — P3-1 선례대로 허용, dedup 후속).
fn verifyOneRemoteSpec(
    allocator: std.mem.Allocator,
    spec: []const u8,
    mf: *const types.MfBundleConfig,
    cwd: ?[]const u8,
) !void {
    const kv = for (mf.remotes) |kv| {
        if (federation.matchesRemoteSpec(spec, kv.key)) break kv;
    } else return;
    const r = parseRemote(kv);
    // 검증 불가(http=P4 / 부재 / 파싱불가) = 위반 아님 → 통과(정밀
    // fail-fast). 단 OOM 은 빌드 자원 문제 → silent skip 금지, 전파.
    var rc = mf_contract.loadContract(allocator, cwd, r.entry) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return,
    };
    defer rc.deinit();
    // P3-3: 무결성 — sidecar(P2-2 SHA-256)/`.sig`(P2-3 Ed25519)와
    // manifest 일치. stale/변조면 fail-fast(D3 런타임가드의 빌드타임
    // 절반). sidecar/sig 부재·malformed = 검증 불가 ≠ 위반 → expose/
    // shared 로 진행(continue 아님 — 무결성 미검증이 P3-1/2 를 건너뛰면
    // 안 됨). 정밀 fail-fast: 확정 변조만 차단.
    mf_contract.verifyIntegrity(allocator, cwd, r.entry) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.MfIntegrityMismatch => {
            std.log.err(
                "zntc: MF 무결성 위반 — remote \"{s}\" 의 mf-manifest.json 이 sidecar(.integrity.json) SHA-256 과 불일치 (stale 또는 변조; 빌드 차단 — remote 재배포 필요)",
                .{kv.key},
            );
            return error.MfIntegrityMismatch;
        },
        error.MfIntegritySignatureInvalid => {
            std.log.err(
                "zntc: MF 서명 위반 — remote \"{s}\" 의 sidecar Ed25519 `.sig` 검증 실패 (변조 또는 잘못된 키; 빌드 차단)",
                .{kv.key},
            );
            return error.MfIntegritySignatureInvalid;
        },
        else => {}, // 검증 불가(sidecar 부재/malformed/network) → 진행
    };
    // P3-1: expose 존재
    if (!exposeListed(rc.exposes, spec, kv.key)) {
        std.log.err(
            "zntc: MF expose 계약 위반 — host import \"{s}\" 가 remote \"{s}\" 의 mf-manifest.json exposes 에 없음 (빌드 차단; remote 재배포 또는 스펙 정렬 필요)",
            .{ spec, kv.key },
        );
        return error.MfHostExposeMissing;
    }
    // P3-2: 양쪽이 선언한 shared 패키지의 singleton·버전 호환
    for (mf.shared) |hs| {
        for (rc.shared) |rs| {
            if (!std.mem.eql(u8, hs.name, rs.name)) continue;
            switch (sharedVerdict(hs, rs)) {
                .ok => {},
                .singleton_conflict => {
                    std.log.err(
                        "zntc: MF shared singleton 충돌 — '{s}' 가 host(singleton={}) ↔ remote \"{s}\"(singleton={}) 불일치 (빌드 차단; 인스턴스 분열 — 양측 shareConfig.singleton 정렬 필요)",
                        .{ hs.name, hs.singleton, kv.key, rs.singleton },
                    );
                    return error.MfSharedSingletonConflict;
                },
                .version_warn => std.log.warn(
                    "zntc: MF shared 버전 경고 — host requiredVersion '{s}' 가 remote \"{s}\" 의 '{s}' 게시버전 '{s}' 을 불만족 (런타임 버전협상 시 폴백 가능; 계약 정렬 권장)",
                    .{ hs.required_version orelse "", kv.key, rs.name, rs.version },
                ),
            }
        }
    }
}

fn isIdentChar(c: u8) bool {
    return c == '_' or c == '$' or std.ascii.isAlphanumeric(c);
}

/// `mf.name` 이 유효 JS 식별자인가(첫 글자 비-숫자).
fn isJsIdent(name: []const u8) bool {
    if (name.len == 0) return false;
    if (std.ascii.isDigit(name[0])) return false;
    for (name) |c| if (!isIdentChar(c)) return false;
    return true;
}

/// graph 에서 expose value(abs) 와 path 가 일치하는 모듈의 federation_id
/// (graph allocator 소유 — wrap 시점 graph 생존, borrow).
fn exposeFedId(graph: anytype, abs: []const u8) ?[]const u8 {
    const count = graph.moduleCount();
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const idx: types.ModuleIndex = @enumFromInt(@as(u32, @intCast(i)));
        const m = graph.getModule(idx) orelse continue;
        if (std.mem.eql(u8, m.path, abs)) return m.federation_id;
    }
    return null;
}

/// fed_id 의 self-register prefix(`({"<id>"`, min/비-min 공통)를 포함하는
/// 청크 산출의 파일명(basename) → `__zntc_load_chunk` 인자.
fn exposeChunkFile(outputs: []const emitter.OutputFile, allocator: std.mem.Allocator, fed_id: []const u8) !?[]const u8 {
    const needle = try std.fmt.allocPrint(allocator, "({{\"{s}\"", .{fed_id});
    defer allocator.free(needle);
    for (outputs) |o| {
        if (std.mem.indexOf(u8, o.contents, needle) != null)
            return std.fs.path.basename(o.path);
    }
    return null;
}

/// 부트스트랩 문장 `[var <id> = ]globalThis.__zntc_require("<id>");` 의
/// [start, end) 바이트 범위. start 는 선행 부트스트랩 접두를 흡수(남기면
/// `var X = <container>` / `return <container>` 가 되어 globalName 바인딩·
/// wrapper 반환 의미가 깨짐). 정본 두 형태(emitter/chunks.zig:801,809):
///   - iife: `[var <gn> = ]globalThis.__zntc_require("<id>");`
///   - umd/amd: `return globalThis.__zntc_require("<id>");`
/// → 이 함수는 그 출력 형태에 강결합. chunks.zig 부트스트랩 변경 시 동반
/// 수정 필요(앵커 없으면 wrapContainer 가 fail-fast).
fn bootstrapSpan(text: []const u8) ?struct { start: usize, end: usize } {
    const p = std.mem.indexOf(u8, text, BOOTSTRAP_ANCHOR) orelse return null;
    const rel = std.mem.indexOf(u8, text[p..], "\");") orelse return null;
    const end = p + rel + 3; // `")` + `;`

    var s = p;
    while (s > 0 and text[s - 1] == ' ') s -= 1;
    if (s > 0 and text[s - 1] == '=') {
        // iife: 선행 `[var <ident> ]=` 흡수
        s -= 1;
        while (s > 0 and text[s - 1] == ' ') s -= 1;
        while (s > 0 and isIdentChar(text[s - 1])) s -= 1;
        while (s > 0 and text[s - 1] == ' ') s -= 1;
        if (s >= 4 and std.mem.eql(u8, text[s - 4 .. s], "var ")) s -= 4;
    } else if (s >= 6 and std.mem.eql(u8, text[s - 6 .. s], "return") and
        (s == 6 or !isIdentChar(text[s - 7])))
    {
        // umd/amd: 선행 `return ` 흡수(`=` 분기와 대칭). 키워드 경계
        // 확인(앞이 식별자 문자 아님)으로 `xreturn` 오인 방지.
        s -= 6;
    }
    return .{ .start = s, .end = end };
}

/// expose 명·federation_id·lazy 청크 파일명 묶음. 모두 borrow
/// (name=mf.exposes KV, fed_id=graph 모듈, chunk_file=outputs[].path basename)
/// — wrapContainer 수명 동안 mf/graph/outputs 생존. 슬라이스만 caller free.
// pub: P3-0 mf_contract.zig 의 emit↔parse 라운드트립 테스트가 스키마
// 단일 소스 박제를 위해 buildManifest 와 함께 소비(RFC §7.3).
pub const ExposeInfo = struct { name: []const u8, fed_id: []const u8, chunk_file: []const u8 };

/// exposes → (명, fed_id, lazy 청크 파일) 수집. container.get 맵과
/// mf-manifest 가 **동일 스캔**을 쓰므로 단일 소스(exposeFedId/
/// exposeChunkFile 재사용). 미해결 expose 는 warn 후 skip(부분 산출).
fn collectExposes(
    allocator: std.mem.Allocator,
    outputs: []const emitter.OutputFile,
    mf: *const types.MfBundleConfig,
    graph: anytype,
    cwd: ?[]const u8,
) ![]ExposeInfo {
    var list: std.ArrayListUnmanaged(ExposeInfo) = .empty;
    errdefer list.deinit(allocator);
    for (mf.exposes) |kv| {
        const abs = federation.resolveAbs(allocator, cwd, kv.value) catch continue;
        defer allocator.free(abs);
        const fed_id = exposeFedId(graph, abs) orelse {
            std.log.warn("[mf] expose '{s}' has no federation_id (P1-1 미표시) — container.get 누락", .{kv.key});
            continue;
        };
        const file = (try exposeChunkFile(outputs, allocator, fed_id)) orelse {
            std.log.warn("[mf] expose '{s}' 청크 산출 없음 — container.get 누락", .{kv.key});
            continue;
        };
        try list.append(allocator, .{ .name = kv.key, .fed_id = fed_id, .chunk_file = file });
    }
    return list.toOwnedSlice(allocator);
}

/// emitChunks 산출을 in-place 로 container 화 + mf-manifest.json 산출.
/// 반환: manifest JSON(allocator 소유, caller=bundler.zig 가 asset_outputs
/// 로 편입·해제). host(exposes 없음)면 null. 게이트는 호출부
/// (`if (options.mf) |mf|`, bundler.zig — markBoundary 와 동일 관례).
pub fn wrapContainer(
    allocator: std.mem.Allocator,
    outputs: []emitter.OutputFile,
    mf: *const types.MfBundleConfig,
    graph: anytype,
    public_path: []const u8,
) !?[]const u8 {
    if (mf.exposes.len == 0) return null; // host(shared/remotes-only) = container 아님
    const name = mf.name orelse return null; // remote 는 P1-0 검증이 name 강제

    const cwd = federation.cwdRealpath(allocator); // WASI-safe(comptime 분기)
    defer if (cwd) |c| allocator.free(c);

    const exposes = try collectExposes(allocator, outputs, mf, graph, cwd);
    defer allocator.free(exposes);

    // ── container 객체 문자열 빌드(min-무관 compact, 유효 JS) ──
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);
    const w = buf.writer(allocator);

    try buf.appendSlice(allocator, "(function(g){var __zntc_mf_container={get:function(e){var M={");
    for (exposes, 0..) |ex, ei| {
        if (ei > 0) try buf.appendSlice(allocator, ",");
        // MF2 계약: get(expose) ⇒ Promise<factory>, factory() ⇒ Module
        // (webpack remoteEntry: `.then(()=>()=>require(id))`). 모듈 자체가
        // 아니라 thunk resolve — factory() 호출 전엔 미평가(추가 lazy).
        try w.print(
            "\"{s}\":function(){{return __zntc_load_chunk(\"{s}\").then(function(){{return function(){{return __zntc_require(\"{s}\")}}}})}}",
            .{ ex.name, ex.chunk_file, ex.fed_id },
        );
    }
    try w.print(
        "}};if(!M[e])throw new Error(\"Module \\\"\"+e+\"\\\" does not exist in container {s}.\");return M[e]()}},",
        .{name},
    );
    // init(P1-4): runtime 은 `init(shareScope, initScope, remoteEntryInit
    // Options)` 로 호출하며 **반환값을 await**(@module-federation/runtime-core
    // module/index.js:73) → init 을 async(Promise 반환) 로 만들어 shared
    // 해석을 끝낸 *후* host 가 get() 호출(init-before-get). 멱등: 같은
    // Promise 재반환. 인자 `s` = host 의 해당 scope 객체(shareScopeMap 전체
    // 아님 — runtime-core 가 scope 만 전달). 버전 satisfy/singleton 판정은
    // host runtime(getRegisteredShare) 책임 → container 는 scope[pkg] 의
    // 가용 버전 1개를 취해 글로벌 seam 에 대입만(과설계 금지).
    try buf.appendSlice(allocator, "init:function(s,i){if(g.__zntc_mf_inited)return g.__zntc_mf_inited;g.__zntc_mf_inited=(async function(){");
    for (mf.shared) |se| {
        const glob = se.global_seam; // borrow (mfBundleFromDto 1회 생성·소유)
        // scope[pkg] = { "<ver>": { lib?, get?:()=>Promise<factory|module> } }.
        // eager=lib(모듈|팩토리), lazy=get→factory thunk(우리 get 과 동형) |
        // 직접 모듈. 두 형태 모두 흡수(host 등록형은 PR-B 실 runtime 검증).
        // K[0] = 첫 버전 채택 — 버전 satisfy/다중버전 선택은 host runtime
        // (getRegisteredShare) 책임이라 scope 에 이미 해소된 버전만 옴(P1-4
        // 비-목표, P1-6 다중-remote 에서 정밀화). se.name 은 JS 문자열에 raw
        // 삽입 — npm 패키지명은 `"`/제어문자 불가라 escape 불요(mf.name 은
        // 임의값 가능해 appendJsStringLiteral, pkg 명은 규약상 안전).
        try w.print(
            "if(s&&s[\"{s}\"]){{var V=s[\"{s}\"],K=Object.keys(V);if(K.length){{var e=V[K[0]],L;" ++
                "if(e){{if(e.lib){{L=(typeof e.lib===\"function\")?e.lib():e.lib;}}" ++
                "else if(e.get){{var f=await e.get();L=(typeof f===\"function\")?f():f;}}}}" ++
                "if(L)g.{s}=L;}}}}",
            .{ se.name, se.name, glob },
        );
    }
    try buf.appendSlice(allocator, "return true;})();return g.__zntc_mf_inited;}};");
    // MF2 계약: @module-federation/runtime 은 container 를
    // `globalThis["__FEDERATION_<name>:custom__"]` 에서 읽는다(getRemote
    // EntryExports default key, rspack/webpack MF 산출과 동일). 추가로
    // 친화 글로벌(window.<name>)도 — 직접 접근/디버깅용.
    try w.print("g[\"__FEDERATION_{s}:custom__\"]=__zntc_mf_container;", .{name});
    if (isJsIdent(name)) {
        try w.print("g.{s}=__zntc_mf_container;", .{name});
    } else {
        try buf.appendSlice(allocator, "g[");
        try emitter.appendJsStringLiteral(allocator, &buf, name);
        try buf.appendSlice(allocator, "]=__zntc_mf_container;");
    }
    // MF2 runtime(Node) 의 loadScriptNode 는 entry 를 (exports,module,...)
    // 래퍼로 vm 실행 후 module.exports 를 container 로 읽는다(webpack MF
    // commonjs-module 타깃). 브라우저는 module 부재 → 글로벌 사용. UMD 식
    // 이중 노출로 runtime-Node interop + 브라우저 둘 다 충족.
    try buf.appendSlice(allocator, "if(typeof module!==\"undefined\"&&module&&module.exports)module.exports=__zntc_mf_container;");
    try buf.appendSlice(allocator, "})");
    try buf.appendSlice(allocator, rt.ZNTC_IIFE_GLOBAL);
    try buf.appendSlice(allocator, ";");

    // ── remoteEntry(부트스트랩 보유 청크) 의 bootstrap 을 container 로 치환 ──
    for (outputs) |*o| {
        const span = bootstrapSpan(o.contents) orelse continue;
        // entry 청크 = remoteEntry. o.path 는 splice 후에도 불변(해시 확정)
        // → basename = manifest.metaData.remoteEntry.name.
        const remote_entry = std.fs.path.basename(o.path);
        var next: std.ArrayListUnmanaged(u8) = .empty;
        errdefer next.deinit(allocator);
        try next.appendSlice(allocator, o.contents[0..span.start]);
        try next.appendSlice(allocator, buf.items);
        try next.appendSlice(allocator, o.contents[span.end..]);
        // toOwnedSlice 성공 *후* 기존 contents free — 먼저 free 하면
        // toOwnedSlice OOM 시 o.contents 가 dangling, bundler.zig 의
        // outputs errdefer 가 그걸 재-free → double-free.
        const owned = try next.toOwnedSlice(allocator);
        allocator.free(o.contents);
        o.contents = owned;
        // mf-manifest.json (S4 박제 스키마 — runtime SnapshotHandler 가
        // metaData/exposes/shared 필수). 같은 시점이라 모든 해시 확정.
        return try buildManifest(allocator, name, mf, exposes, remote_entry, public_path);
    }
    // mf 빌드인데 reg_split 부트스트랩이 없음 = 잘못된 구성(format/splitting).
    // 조용한 오작동(container 없는 산출) 금지 — federation.zig 진단 관례.
    std.log.err("[mf] remoteEntry 부트스트랩 앵커 없음 — mf 빌드는 --format=iife/umd/amd + splitting 필요", .{});
    return MfEmitError.RemoteEntryAnchorMissing;
}

/// JSON 문자열 리터럴 — emitter.zig 단일 소스(metafile 과 공유, 0x08/
/// 0x0C 포함 C0 전체 escape). 중립 모듈이라 circular import 없음.
const appendJsonStr = emitter.appendJsonString;

/// mf-manifest.json (webpack/rspack MF 호환, `@module-federation/sdk@2.4.0`
/// Manifest 타입 + runtime-core SnapshotHandler:161 필수필드 실측).
/// runtime 동작필수: metaData(remoteEntry/buildInfo/globalName/publicPath)·
/// exposes·shared(빈 배열 OK)·remotes. types/.d.ts·shared 정밀화는 비-목표
/// (P3/P1-6). public_path 비면 "auto"(runtime 이 manifestUrl 에서 추론).
/// buildVersion/pluginVersion="0.1.0" 박제: runtime 은 이 값을 snapshot
/// 식별/캐시 힌트로만 쓰고 의미 검증 안 함(generateSnapshotFromManifest)
/// — lockstep 패키지 버전 추적은 불필요(P1-6 비-목표). build-time 주입은
/// 후속 백로그.
pub fn buildManifest(
    allocator: std.mem.Allocator,
    name: []const u8,
    mf: *const types.MfBundleConfig,
    exposes: []const ExposeInfo,
    remote_entry: []const u8,
    public_path: []const u8,
) ![]const u8 {
    var b: std.ArrayListUnmanaged(u8) = .empty;
    errdefer b.deinit(allocator);
    const pp = if (public_path.len > 0) public_path else "auto";

    try b.appendSlice(allocator, "{\"id\":");
    try appendJsonStr(&b, allocator, name);
    try b.appendSlice(allocator, ",\"name\":");
    try appendJsonStr(&b, allocator, name);
    try b.appendSlice(allocator, ",\"metaData\":{\"name\":");
    try appendJsonStr(&b, allocator, name);
    // type:"app"(MFModuleType.APP — remote 도 app). remoteEntry.type:"global"
    // (P1-3 가 globalName 전역 노출 = webpack global 라이브러리). path:""→
    // runtime simpleJoinRemoteEntry 가 name 만 → publicPath+name URL 합성.
    try b.appendSlice(allocator, ",\"type\":\"app\",\"buildInfo\":{\"buildVersion\":\"0.1.0\",\"buildName\":");
    try appendJsonStr(&b, allocator, name);
    try b.appendSlice(allocator, "},\"remoteEntry\":{\"name\":");
    try appendJsonStr(&b, allocator, remote_entry);
    try b.appendSlice(allocator, ",\"path\":\"\",\"type\":\"global\"},\"types\":{\"path\":\"\",\"name\":\"\",\"zip\":\"\",\"api\":\"\"},\"globalName\":");
    try appendJsonStr(&b, allocator, name);
    try b.appendSlice(allocator, ",\"pluginVersion\":\"0.1.0\",\"publicPath\":");
    try appendJsonStr(&b, allocator, pp);
    // P2-0 (#3420): manifest.shared 정밀. `@module-federation/sdk`
    // ManifestShared = {id,name,version,singleton,requiredVersion,hash,
    // assets}. version 은 SharedEntry 에 설치버전이 없어(external+글로벌
    // seam 처리) requiredVersion 대용 — 정밀 버전 해석은 P2 비-목표(과설계
    // 경계). assets 빈(seam 이 로딩 담당, generateSnapshotFromManifest 가
    // name/version 으로 버전협상). hash=""(무결성=P2-2). remotes 는 P2-1.
    try b.appendSlice(allocator, "},\"shared\":[");
    for (mf.shared, 0..) |se, si| {
        if (si > 0) try b.append(allocator, ',');
        const rv = se.required_version orelse "";
        try b.appendSlice(allocator, "{\"id\":");
        const sid = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ name, se.name });
        defer allocator.free(sid);
        try appendJsonStr(&b, allocator, sid);
        try b.appendSlice(allocator, ",\"name\":");
        try appendJsonStr(&b, allocator, se.name);
        try b.appendSlice(allocator, ",\"version\":");
        try appendJsonStr(&b, allocator, rv);
        try b.appendSlice(allocator, ",\"singleton\":");
        try b.appendSlice(allocator, if (se.singleton) "true" else "false");
        try b.appendSlice(allocator, ",\"requiredVersion\":");
        try appendJsonStr(&b, allocator, rv);
        // #2 (감사): strictVersion additive 게시(producer contract).
        // 표준 sdk ManifestShared 스키마 필드는 아님 — ManifestShared-
        // typed consumer 는 무시(무해), 표준 강제는 host init shareConfig
        // 가 표준 runtime 에 위임(share.ts strictVersion→error). zntc 는
        // 이 게시값을 P3-2 빌드타임 fail-fast 격상에 사용(별 PR).
        try b.appendSlice(allocator, ",\"strictVersion\":");
        try b.appendSlice(allocator, if (se.strict_version) "true" else "false");
        try b.appendSlice(allocator, ",\"hash\":\"\",\"assets\":{\"js\":{\"sync\":[],\"async\":[]},\"css\":{\"sync\":[],\"async\":[]}}}");
    }
    // P2-1 (#3421): manifest.remotes 정밀. exposes 있는 remote 가 다른
    // remote 도 소비하면 그 의존을 manifest 로 기술(표준 contract — host 가
    // 이 remote 로드 시 transitive deps 인지). `@module-federation/sdk`
    // ManifestRemote = Omit<RemoteWithEntry,'name'> & {federationContainer
    // Name,moduleName,alias} = {entry,federationContainerName,moduleName,
    // alias}. generateSnapshotFromManifest 가 federationContainerName(키)+
    // entry 소비. parseRemote(emitHostInit 공용) 재사용. host-only(exposes
    // 0)는 wrapContainer null → manifest 미산출(표준 일치 — manifest 는
    // remote-producer 산출물).
    try b.appendSlice(allocator, "],\"remotes\":[");
    for (mf.remotes, 0..) |kv, ri| {
        if (ri > 0) try b.append(allocator, ',');
        const r = parseRemote(kv); // {name=container, entry}
        try b.appendSlice(allocator, "{\"entry\":");
        try appendJsonStr(&b, allocator, r.entry);
        try b.appendSlice(allocator, ",\"federationContainerName\":");
        try appendJsonStr(&b, allocator, r.name);
        try b.appendSlice(allocator, ",\"moduleName\":");
        try appendJsonStr(&b, allocator, r.name);
        try b.appendSlice(allocator, ",\"alias\":");
        try appendJsonStr(&b, allocator, kv.key); // 로컬 참조 alias
        try b.append(allocator, '}');
    }
    try b.appendSlice(allocator, "],\"exposes\":[");
    for (exposes, 0..) |ex, ei| {
        if (ei > 0) try b.append(allocator, ',');
        // id = "<name>:<expose키에서 './' 제거>" (MF 규약, 예 app:Widget).
        const short = if (std.mem.startsWith(u8, ex.name, "./")) ex.name[2..] else ex.name;
        try b.appendSlice(allocator, "{\"id\":");
        const id = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ name, short });
        defer allocator.free(id);
        try appendJsonStr(&b, allocator, id);
        try b.appendSlice(allocator, ",\"name\":");
        try appendJsonStr(&b, allocator, ex.name);
        try b.appendSlice(allocator, ",\"path\":");
        try appendJsonStr(&b, allocator, ex.name);
        // expose 는 자기 lazy 청크 → js.async=[청크], sync=[]. css 는 비-목표.
        try b.appendSlice(allocator, ",\"assets\":{\"js\":{\"sync\":[],\"async\":[");
        try appendJsonStr(&b, allocator, ex.chunk_file);
        try b.appendSlice(allocator, "]},\"css\":{\"sync\":[],\"async\":[]}}}");
    }
    try b.appendSlice(allocator, "]}");
    return b.toOwnedSlice(allocator);
}

// ── P3-1 inline tests (스캔·매칭 순수 로직 — 계약 IO 는 통합테스트) ──

fn tMf(remotes: []const types.MfBundleConfig.KV) types.MfBundleConfig {
    return .{ .name = "host", .remotes = remotes };
}

test "nextRemoteImport: 원격만 추출 — 비원격/식별자경계/따옴표없음 skip" {
    const remotes = [_]types.MfBundleConfig.KV{.{ .key = "app", .value = "app@./r/mf-manifest.json" }};
    const mf = tMf(&remotes);
    const src =
        "var a=import('app/Widget');myimport('app/X');import('lodash');" ++
        "import(\"app/B\");import(dyn);";
    var i: usize = 0;
    const h1 = nextRemoteImport(src, &mf, &i).?;
    try std.testing.expectEqualStrings("app/Widget", h1.spec);
    try std.testing.expectEqual(@as(u8, 'i'), src[h1.p]); // p = `import(` 시작
    const h2 = nextRemoteImport(src, &mf, &i).?;
    try std.testing.expectEqualStrings("app/B", h2.spec); // myimport/lodash skip
    try std.testing.expect(nextRemoteImport(src, &mf, &i) == null); // import(dyn) skip
}

test "exposeListed: ./ 정규화·정확매칭·부재·중첩·bare key" {
    const exposes = [_][]const u8{ "./Widget", "./a/B" };
    try std.testing.expect(exposeListed(&exposes, "app/Widget", "app")); // ./Widget ↔ Widget
    try std.testing.expect(exposeListed(&exposes, "app/a/B", "app")); // 중첩 보존
    try std.testing.expect(!exposeListed(&exposes, "app/Missing", "app")); // 부재
    try std.testing.expect(!exposeListed(&exposes, "app/widget", "app")); // 대소문자 구분
    const def = [_][]const u8{"."};
    try std.testing.expect(exposeListed(&def, "app", "app")); // spec==key → "."
    try std.testing.expect(!exposeListed(&exposes, "app", "app")); // 기본 expose 미게시
}

test "emitHostInit 회귀: 원격 import → __mfGuardedLoad(P3-5), 가드 정의, 비원격 보존" {
    const a = std.testing.allocator;
    const remotes = [_]types.MfBundleConfig.KV{.{ .key = "app", .value = "app@http://x/r.js" }};
    const mf = tMf(&remotes);
    const src = "const x=import(\"app/W\");const y=import(\"lodash\");";
    const out = try emitHostInit(a, src, &mf, &.{}); // 정적 없음 → 게이트 미emit
    defer a.free(out);
    // P3-5: 원격 동적 import 가 가드 경유(인자=specifier 그대로 forward)
    try std.testing.expect(std.mem.indexOf(u8, out, MF_GUARDED ++ "(\"app/W\")") != null);
    // 가드 정의(prelude) + 내부서 표준 loadRemote 호출(interop 보존)
    try std.testing.expect(std.mem.indexOf(u8, out, MF_GUARDED ++ "=function(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "RR.loadRemote.apply(RR,a)") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "__mfUnavailable:true") != null); // 폴백
    try std.testing.expect(std.mem.indexOf(u8, out, "import(\"lodash\")") != null); // 비원격 불변
    try std.testing.expect(std.mem.indexOf(u8, out, ".init({\"name\":\"host\"") != null); // prelude
    // 정적 specs 없음 → preload-gate 미emit(동적-only 무회귀)
    try std.testing.expect(std.mem.indexOf(u8, out, "Promise.all([") == null);
}

test "emitHostInit PR-2: 정적 specs → async preload-gate + body deferral" {
    const a = std.testing.allocator;
    const remotes = [_]types.MfBundleConfig.KV{.{ .key = "app", .value = "app@http://x/r.js" }};
    const mf = tMf(&remotes);
    // PR-1 이 emit 한 형태: 정적 import → seam 글로벌 binding(import 구문 없음)
    const src = "var W=__mf_remote_app_Widget.default;W();";
    const specs = [_][]const u8{ "app/Widget", "app/Btn" };
    const out = try emitHostInit(a, src, &mf, &specs);
    defer a.free(out);
    // prelude(가드 정의) 가 게이트 앞(동기) — __mfGuardedLoad 선정의
    const gate_at = std.mem.indexOf(u8, out, "Promise.all([").?;
    const guard_def_at = std.mem.indexOf(u8, out, MF_GUARDED ++ "=function(").?;
    try std.testing.expect(guard_def_at < gate_at);
    // 각 spec 을 가드 경유 병렬 preload
    try std.testing.expect(std.mem.indexOf(u8, out, MF_GUARDED ++ "(\"app/Widget\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, MF_GUARDED ++ "(\"app/Btn\")") != null);
    // seam 글로벌 대입(per-spec, mfRemoteGlobalName 단일소스 = san 규칙)
    try std.testing.expect(std.mem.indexOf(u8, out, "globalThis.__mf_remote_app_Widget=__mfm[0];") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "globalThis.__mf_remote_app_Btn=__mfm[1];") != null);
    // body(src) 가 .then 안으로 deferral(seam 대입 후 실행)
    const body_at = std.mem.indexOf(u8, out, "var W=__mf_remote_app_Widget.default;").?;
    const then_body_at = std.mem.indexOf(u8, out, "}).then(function(){").?;
    try std.testing.expect(then_body_at < body_at); // body 가 .then 콜백 내부
    try std.testing.expect(std.mem.endsWith(u8, out, "});")); // 게이트 닫힘
}

test "sharedVerdict: singleton 충돌 fail-fast / 버전 경고 / 판정불가 ok" {
    const SE = types.MfBundleConfig.SharedEntry;
    const SC = mf_contract.SharedContract;
    // singleton 불일치 → 결정적 충돌(버전 무관)
    try std.testing.expectEqual(SharedVerdict.singleton_conflict, sharedVerdict(
        .{ .name = "react", .singleton = true, .required_version = "^19" },
        .{ .name = "react", .version = "19.2.4", .required_version = "^19", .singleton = false },
    ));
    // singleton 일치 + host range 가 remote concrete version 불만족 → 경고
    try std.testing.expectEqual(SharedVerdict.version_warn, sharedVerdict(
        SE{ .name = "react", .singleton = true, .required_version = "^18" },
        SC{ .name = "react", .version = "19.2.4", .required_version = "^19", .singleton = true },
    ));
    // 호환 → ok
    try std.testing.expectEqual(SharedVerdict.ok, sharedVerdict(
        SE{ .name = "react", .singleton = true, .required_version = "^19" },
        SC{ .name = "react", .version = "19.2.4", .required_version = "^19", .singleton = true },
    ));
    // remote.version 비-concrete(zntc P2-0 version=range 대용) → 판정 불가 → ok
    try std.testing.expectEqual(SharedVerdict.ok, sharedVerdict(
        SE{ .name = "react", .singleton = true, .required_version = "^19" },
        SC{ .name = "react", .version = "^19", .required_version = "^19", .singleton = true },
    ));
    // host 무제약(required_version=null) → singleton 일치면 ok
    try std.testing.expectEqual(SharedVerdict.ok, sharedVerdict(
        SE{ .name = "react", .singleton = false, .required_version = null },
        SC{ .name = "react", .version = "19.2.4", .required_version = "^19", .singleton = false },
    ));
}
