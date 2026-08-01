//! `targetToUnsupported(spec)` — target 문자열을 `unsupported` 비트마스크로 환산한다.
//!
//! **왜 네이티브를 노출하나 (#4602)**
//!
//! CLI 는 `--target=safari11,chrome60` 같은 엔진 매트릭스를 `compat.browserslistToUnsupported`
//! 로 해석하는데, JS API 는 그 경로가 없어 엔진 이름 타겟이 **조용히 무시**됐다(`build()`) 거나
//! `invalid options JSON` 으로 죽었다(`transpile()` — DTO 의 `target` 이 `ESTarget` enum 이라
//! JSON 파싱 자체가 실패). 둘 다 CLI 와 다른 결과다.
//!
//! 그렇다고 TS 쪽에 파서를 하나 더 두면 **반드시 갈라진다** — 실제로 `packages/shared` 의
//! `parseBrowserslistEntry` 는 공백 없는 `safari11` 을 못 읽고 operator(`>=`)·Opera→Chromium
//! 변환도 없어, 같은 입력에 다른 답을 낸다. 그래서 규칙은 Zig 한 곳(`transformer/compat.zig`)
//! 에만 두고 JS 가 그걸 호출한다.
//!
//! 입력은 ES 타겟(`es2019`)과 엔진 매트릭스(`chrome80,safari14`) 둘 다 받는다 — CLI 의
//! `--target=` 처리와 동일한 순서(ES enum 먼저, 실패 시 엔진 매트릭스)다.
//! 해석 불가면 **throw** 한다. 조용히 0(esnext)을 돌려주면 원래 버그로 되돌아간다.

const std = @import("std");
const zntc_lib = @import("zntc_lib");
const common = @import("common.zig");
const c = common.c;

const compat = zntc_lib.transformer.TransformOptions.compat;
const native_alloc = common.nativeAlloc();
const throwError = common.throwError;
const getStringArg = common.getStringArg;

/// spec → `UnsupportedFeatures` 비트마스크. 해석 불가면 null.
/// CLI(`src/cli/options.zig` 의 `--target=`)와 **같은 순서·같은 파서**여야 한다.
pub fn unsupportedFromTargetSpec(spec: []const u8) ?compat.UnsupportedFeatures {
    if (std.meta.stringToEnum(compat.ESTarget, spec)) |es| return compat.fromESTarget(es);
    return compat.browserslistToUnsupported(spec);
}

/// 버전 없는 플랫폼/런타임 이름인지 — `target` 과 `platform` 을 혼동한 전형적인 입력.
fn platformNameConfusion(spec: []const u8) bool {
    for ([_][]const u8{ "node", "browser", "neutral", "react-native", "deno", "bun" }) |name| {
        if (std.ascii.eqlIgnoreCase(spec, name)) return true;
    }
    return false;
}

/// `targetToUnsupported(spec: string) => number`
pub fn napiTargetToUnsupported(env: c.napi_env, info: c.napi_callback_info) callconv(.c) c.napi_value {
    var argc: usize = 1;
    var argv: [1]c.napi_value = undefined;
    if (c.napi_get_cb_info(env, info, &argc, &argv, null, null) != c.napi_ok) {
        return throwError(env, "targetToUnsupported: failed to get arguments");
    }
    if (argc < 1) return throwError(env, "targetToUnsupported requires a target string");

    const spec = getStringArg(env, argv[0], native_alloc) orelse
        return throwError(env, "targetToUnsupported: target must be a non-empty string");
    defer native_alloc.free(spec);

    const bits = unsupportedFromTargetSpec(spec) orelse {
        var buf: [320]u8 = undefined;
        const shown = spec[0..@min(spec.len, 120)];
        // `target: 'node'` 는 `platform` 과 혼동한 사용이 압도적이다 — 우리 README 와 패키지
        // 빌드 스크립트에도 있었다. 그냥 "unknown target" 이라고만 하면 사용자가 무엇으로
        // 바꿔야 하는지 알 수 없으므로 정확히 짚어 준다.
        const msg = if (platformNameConfusion(spec))
            std.fmt.bufPrintZ(
                &buf,
                "unknown target '{s}' — did you mean platform: '{s}'? `target` is an ES version (es2020) or an engine version (node16, safari14); the runtime is set with `platform`",
                .{ shown, shown },
            ) catch "unknown target"
        else
            std.fmt.bufPrintZ(
                &buf,
                "unknown target '{s}' (expected an ES version like es2020, or an engine matrix like chrome80,safari14,node16)",
                .{shown},
            ) catch "unknown target";
        return throwError(env, msg);
    };

    var out: c.napi_value = undefined;
    const raw: u32 = @bitCast(bits);
    if (c.napi_create_uint32(env, raw, &out) != c.napi_ok) {
        return throwError(env, "targetToUnsupported: failed to create result");
    }
    return out;
}
