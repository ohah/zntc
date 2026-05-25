//! BoringSSL thin Zig binding (epic #2538 4-1 PR-2 — build link 검증 + 최소 노출).
//!
//! 본 파일은 dev_server.zig 의 TLS wrapper (PR-3) 가 의존할 최소 extern fn 들의
//! 거점. 현 단계에선 `init()` 한 함수만 노출 — `zig build test` 가 link 무결성
//! (libboringssl.a 가 실제 exe 에 묶이는지) 을 단위 test 로 검증한다.
//!
//! 본격 wrapper (SSL_CTX_new/SSL_accept/SSL_read/SSL_write 등) 는 PR-3 에 추가.

const std = @import("std");

// BoringSSL 의 옛 OpenSSL 호환 entry. 1.1.0+ 부터는 internal 이 자동 init 처리하므로
// 대부분 no-op 이지만, return 값 0 (이미 init 됨) 또는 1 (성공) 만 보장 — link 검증의
// 가장 가벼운 호출.
pub extern "c" fn SSL_library_init() c_int;

/// 후속 PR-3 의 TLS wrapper 가 의존할 거점 (forward declaration). 본 PR-2 의 link
/// 무결성은 아래 단위 test 가 검증.
pub fn init() c_int {
    return SSL_library_init();
}

test "BoringSSL: SSL_library_init link smoke" {
    // 0 (already initialized) 또는 1 (initialized now) — 둘 다 link 검증의 PASS.
    // 실제 값 검증 대신 호출 가능 여부만 — linker 가 libboringssl.a 의 symbol 을
    // exe 에 묶지 않으면 build/test 가 link error 로 실패.
    const rc = SSL_library_init();
    try std.testing.expect(rc == 0 or rc == 1);
}
