//! BoringSSL thin Zig binding (epic #2538 4-1/4-2).
//!
//! PR-3 (4-2) 의 dev server TLS wrapper 가 의존할 extern fn 들의 거점. 본격
//! TlsContext/TlsConnection 은 `src/server/tls.zig` 에 — 본 파일은 raw symbol
//! 노출 + 상수 만.

const std = @import("std");

// ─── library init ────────────────────────────────────────────────────────────

// 1.1.0+ 부터 internal 자동 init 처리하지만, link 검증의 가장 가벼운 호출이라
// smoke test 가 사용.
pub extern "c" fn SSL_library_init() c_int;

// ─── SSL_CTX ─────────────────────────────────────────────────────────────────

pub const SSL_METHOD = opaque {};
pub const SSL_CTX = opaque {};
pub const SSL = opaque {};

/// TLS_method() 는 TLS server/client 양쪽 generic method. server 전용은
/// TLS_server_method() — 둘 다 BoringSSL 에서 사용 가능, server 전용이 더 정확.
pub extern "c" fn TLS_method() *const SSL_METHOD;
pub extern "c" fn TLS_server_method() *const SSL_METHOD;

pub extern "c" fn SSL_CTX_new(method: *const SSL_METHOD) ?*SSL_CTX;
pub extern "c" fn SSL_CTX_free(ctx: *SSL_CTX) void;

/// `type` = SSL_FILETYPE_PEM (PEM 형식) 만 사용. 반환 1 = 성공, 0 = 실패.
pub extern "c" fn SSL_CTX_use_certificate_file(
    ctx: *SSL_CTX,
    file: [*:0]const u8,
    @"type": c_int,
) c_int;

pub extern "c" fn SSL_CTX_use_PrivateKey_file(
    ctx: *SSL_CTX,
    file: [*:0]const u8,
    @"type": c_int,
) c_int;

/// cert 와 private key 가 매칭되는지 검증. 1 = 매칭, 0 = 불일치.
pub extern "c" fn SSL_CTX_check_private_key(ctx: *const SSL_CTX) c_int;

/// TLS 최소/최대 protocol version 설정. version = TLS1_2_VERSION 또는 TLS1_3_VERSION.
pub extern "c" fn SSL_CTX_set_min_proto_version(ctx: *SSL_CTX, version: u16) c_int;
pub extern "c" fn SSL_CTX_set_max_proto_version(ctx: *SSL_CTX, version: u16) c_int;

// ─── SSL (per-connection) ────────────────────────────────────────────────────

pub extern "c" fn SSL_new(ctx: *SSL_CTX) ?*SSL;
pub extern "c" fn SSL_free(ssl: *SSL) void;

/// 기존 file descriptor 위에 SSL 을 attach (BIO 우회). 반환 1 = 성공.
pub extern "c" fn SSL_set_fd(ssl: *SSL, fd: c_int) c_int;

/// server-side TLS handshake. >0 = handshake 완료, <=0 = error (SSL_get_error 로 분기).
pub extern "c" fn SSL_accept(ssl: *SSL) c_int;

/// 평문 read. >0 = byte 수, <=0 = error.
pub extern "c" fn SSL_read(ssl: *SSL, buf: [*]u8, num: c_int) c_int;

/// 평문 write. >0 = byte 수, <=0 = error.
pub extern "c" fn SSL_write(ssl: *SSL, buf: [*]const u8, num: c_int) c_int;

/// graceful shutdown. 0 = 진행 중, 1 = 완료.
pub extern "c" fn SSL_shutdown(ssl: *SSL) c_int;

/// SSL_read/write/accept 의 반환값을 받아 error code 로 변환.
pub extern "c" fn SSL_get_error(ssl: *const SSL, ret: c_int) c_int;

// ─── error queue ─────────────────────────────────────────────────────────────

/// thread-local error queue 의 top error code.
pub extern "c" fn ERR_get_error() c_ulong;

/// error code 를 사람이 읽을 수 있는 string 으로 변환 (buf 에 write, NUL 종료).
pub extern "c" fn ERR_error_string_n(e: c_ulong, buf: [*]u8, len: usize) void;

// ─── 상수 ────────────────────────────────────────────────────────────────────

pub const SSL_FILETYPE_PEM: c_int = 1;
pub const SSL_FILETYPE_ASN1: c_int = 2;

// SSL_get_error 반환 — IO retry 가 필요한 경우 분기.
pub const SSL_ERROR_NONE: c_int = 0;
pub const SSL_ERROR_SSL: c_int = 1;
pub const SSL_ERROR_WANT_READ: c_int = 2;
pub const SSL_ERROR_WANT_WRITE: c_int = 3;
pub const SSL_ERROR_WANT_X509_LOOKUP: c_int = 4;
pub const SSL_ERROR_SYSCALL: c_int = 5;
pub const SSL_ERROR_ZERO_RETURN: c_int = 6;
pub const SSL_ERROR_WANT_CONNECT: c_int = 7;
pub const SSL_ERROR_WANT_ACCEPT: c_int = 8;

// SSL_CTX_set_{min,max}_proto_version 인자.
pub const TLS1_VERSION: u16 = 0x0301;
pub const TLS1_1_VERSION: u16 = 0x0302;
pub const TLS1_2_VERSION: u16 = 0x0303;
pub const TLS1_3_VERSION: u16 = 0x0304;

// ─── helper ──────────────────────────────────────────────────────────────────

/// PR-3 의 TLS wrapper 가 의존할 거점 (forward declaration). 본 PR-2 의 link
/// 무결성은 아래 단위 test 가 검증.
pub fn init() c_int {
    return SSL_library_init();
}

/// ERR queue top error 를 fixed buffer 에 dump. caller 가 std.log 등에 출력.
pub fn lastErrorString(buf: []u8) []const u8 {
    const err = ERR_get_error();
    if (err == 0) return "no error in queue";
    ERR_error_string_n(err, buf.ptr, buf.len);
    const end = std.mem.indexOfScalar(u8, buf, 0) orelse buf.len;
    return buf[0..end];
}

test "BoringSSL: SSL_library_init link smoke" {
    // 0 (already initialized) 또는 1 (initialized now) — 둘 다 link 검증 PASS.
    // linker 가 libboringssl.a 의 symbol 을 묶지 않으면 test 자체가 link error.
    const rc = SSL_library_init();
    try std.testing.expect(rc == 0 or rc == 1);
}

test "BoringSSL: SSL_CTX create/free + version range" {
    const ctx = SSL_CTX_new(TLS_server_method()) orelse return error.SslCtxNewFailed;
    defer SSL_CTX_free(ctx);
    try std.testing.expect(SSL_CTX_set_min_proto_version(ctx, TLS1_2_VERSION) == 1);
    try std.testing.expect(SSL_CTX_set_max_proto_version(ctx, TLS1_3_VERSION) == 1);
}

test "BoringSSL: ERR queue empty 시 lastErrorString" {
    var buf: [256]u8 = undefined;
    const msg = lastErrorString(&buf);
    // ERR queue 가 비어 있거나 valid string. 정확 값 검증보다는 함수가 panic 안 함.
    try std.testing.expect(msg.len > 0);
}
