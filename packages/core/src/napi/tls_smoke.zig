//! TLS sanity NAPI entry — BoringSSL static link 의 runtime 동작 검증용.
//!
//! `tlsSelfCheck({ certPath, keyPath })` 를 호출하면 `TlsContext.init` 으로 cert/key
//! 를 한 번 로드 + 해제. 성공 시 undefined 반환, fail 시 throw.
//!
//! 용도:
//!   - NAPI binary 가 BoringSSL symbol 을 정상 호출하는지 자동 검증 (fix chain
//!     #3894 / #3898 / #3899 의 효과 잠금).
//!   - 사용자 RN dev 환경에서 cert/key 파일 자체의 유효성 빠르게 확인.
//!
//! **Dev-only entry — caller 신뢰 전제**: 임의 파일 경로 (`certPath`/`keyPath`) 를
//! 받아 BoringSSL 로 읽는다. NAPI 프로세스 권한으로 파일 시스템 접근 가능 — 신뢰
//! 안 되는 RPC 표면을 통해 노출하지 말 것. 일반 dev workflow 에서는 사용자 본인의
//! cert/key 파일을 자기 머신에서 검증하는 용도.
//!
//! 후속 PR: 본격 HTTPS dev server NAPI entry — listener thread + handle.

const std = @import("std");
const zntc_lib = @import("zntc_lib");
const common = @import("common.zig");
const c = common.c;

const tls = zntc_lib.server.tls;

const native_alloc = common.nativeAlloc();
const throwError = common.throwError;
const getObjectString = common.getObjectString;

/// tlsSelfCheck({ certPath: string, keyPath: string }) → undefined.
///
/// BoringSSL 의 SSL_CTX_new / SSL_CTX_use_certificate_file /
/// SSL_CTX_use_PrivateKey_file / SSL_CTX_check_private_key 를 순차 호출.
/// 실패 시 throw — 메시지에 Zig error name 포함.
pub fn napiTlsSelfCheck(env: c.napi_env, info: c.napi_callback_info) callconv(.c) c.napi_value {
    var argc: usize = 1;
    var argv: [1]c.napi_value = undefined;
    if (c.napi_get_cb_info(env, info, &argc, &argv, null, null) != c.napi_ok) {
        return throwError(env, "tlsSelfCheck: failed to get arguments");
    }
    if (argc < 1) return throwError(env, "tlsSelfCheck requires an options object");

    // **F3**: argv[0] type 검증. object 아니면 후속 getObjectString 이 "field required"
    // 로 throw 해 사용자가 type 문제를 missing field 로 오해. 명시 메시지로 분리.
    var arg_type: c.napi_valuetype = undefined;
    if (c.napi_typeof(env, argv[0], &arg_type) != c.napi_ok or arg_type != c.napi_object) {
        return throwError(env, "tlsSelfCheck: options must be an object");
    }

    var arena = std.heap.ArenaAllocator.init(native_alloc);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    const cert_path = getObjectString(env, argv[0], "certPath", arena_alloc) orelse
        return throwError(env, "tlsSelfCheck: 'certPath' string option is required");
    const key_path = getObjectString(env, argv[0], "keyPath", arena_alloc) orelse
        return throwError(env, "tlsSelfCheck: 'keyPath' string option is required");

    var ctx = tls.TlsContext.init(cert_path, key_path) catch |err| {
        var msg_buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrintZ(&msg_buf, "tlsSelfCheck: TlsContext.init failed: {}", .{err}) catch "tlsSelfCheck: TlsContext.init failed";
        return throwError(env, msg.ptr);
    };
    ctx.deinit();

    var undefined_val: c.napi_value = undefined;
    _ = c.napi_get_undefined(env, &undefined_val);
    return undefined_val;
}
