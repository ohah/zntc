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

/// 부트스트랩 호출(=entry 청크 식별 앵커). cross-chunk/동적 wrapper 의
/// `__zntc_require("` 와 달리 `globalThis.` 접두가 붙는 건 부트스트랩뿐
/// (chunks.zig:809) → 유일 식별.
const BOOTSTRAP_ANCHOR = "globalThis.__zntc_require(\"";

const MfEmitError = error{RemoteEntryAnchorMissing};

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

/// emitChunks 산출을 in-place 로 container 화. 게이트는 호출부
/// (`if (options.mf) |mf|`, bundler.zig — markBoundary 와 동일 관례).
pub fn wrapContainer(
    allocator: std.mem.Allocator,
    outputs: []emitter.OutputFile,
    mf: *const types.MfBundleConfig,
    graph: anytype,
) !void {
    if (mf.exposes.len == 0) return; // host(shared/remotes-only) = container 아님
    const name = mf.name orelse return; // remote 는 P1-0 검증이 name 강제

    const cwd = federation.cwdRealpath(allocator); // WASI-safe(comptime 분기)
    defer if (cwd) |c| allocator.free(c);

    // ── container 객체 문자열 빌드(min-무관 compact, 유효 JS) ──
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);
    const w = buf.writer(allocator);

    try buf.appendSlice(allocator, "(function(g){var __zntc_mf_container={get:function(e){var M={");
    var first = true;
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
        if (!first) try buf.appendSlice(allocator, ",");
        first = false;
        // MF2 계약: get(expose) ⇒ Promise<factory>, factory() ⇒ Module
        // (webpack remoteEntry: `.then(()=>()=>require(id))`). 모듈 자체가
        // 아니라 thunk resolve — factory() 호출 전엔 미평가(추가 lazy).
        // "<expose>":function(){return __zntc_load_chunk("<file>").then(function(){return function(){return __zntc_require("<fed_id>")}})}
        try w.print(
            "\"{s}\":function(){{return __zntc_load_chunk(\"{s}\").then(function(){{return function(){{return __zntc_require(\"{s}\")}}}})}}",
            .{ kv.key, file, fed_id },
        );
    }
    try w.print(
        "}};if(!M[e])throw new Error(\"Module \\\"\"+e+\"\\\" does not exist in container {s}.\");return M[e]()}},",
        .{name},
    );
    // init: P1-3 은 init-before-get 가드만(shared 글로벌 채움은 P1-4).
    // runtime 은 init(shareScope, initScope, remoteEntryInitOptions) 로 호출
    // (s,i 외 무시).
    try buf.appendSlice(allocator, "init:function(s,i){if(g.__zntc_mf_inited)return;g.__zntc_mf_inited=true;}};");
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
        return;
    }
    // mf 빌드인데 reg_split 부트스트랩이 없음 = 잘못된 구성(format/splitting).
    // 조용한 오작동(container 없는 산출) 금지 — federation.zig 진단 관례.
    std.log.err("[mf] remoteEntry 부트스트랩 앵커 없음 — mf 빌드는 --format=iife/umd/amd + splitting 필요", .{});
    return MfEmitError.RemoteEntryAnchorMissing;
}
