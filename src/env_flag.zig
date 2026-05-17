//! 프로세스 1회 캐시 env-presence boolean flag.
//!
//! `std.once` thread-safe 1회 평가 + WASI 가드 + `hasEnvVarConstant`
//! (allocator 불필요) 패턴이 transpile fast-path / shared-namespace rewrite
//! kill-switch 등에서 토큰 단위로 중복되던 것을 단일 소스로 통합 (RFC #3399
//! PR-3 cleanup). 새 토글은 이 제너릭을 쓴다.

const std = @import("std");
const builtin = @import("builtin");

/// `env_name` 환경변수의 *존재 여부* 를 프로세스당 1회 평가해 캐시한다.
/// thread-safe (std.once). 같은 comptime `env_name` 인스턴스화는 동일 타입
/// (캐시 공유), 다른 이름은 독립 캐시. WASI(+!link_libc) 는 항상 false.
///
/// 사용: `const fooEnabled = env_flag.Once("ZNTC_FOO");` → `fooEnabled.enabled()`.
pub fn Once(comptime env_name: []const u8) type {
    return struct {
        var once = std.once(compute);
        var value: bool = false;

        fn compute() void {
            if (comptime builtin.os.tag == .wasi and !builtin.link_libc) {
                value = false;
                return;
            }
            value = std.process.hasEnvVarConstant(env_name);
        }

        pub fn enabled() bool {
            once.call();
            return value;
        }
    };
}

test "Once: 미설정 env 는 false" {
    // 테스트 환경에 거의 없을 임의 이름 — 존재하지 않으면 false.
    const f = Once("ZNTC_ENV_FLAG_UNITTEST_ABSENT_XYZ");
    try std.testing.expect(!f.enabled());
    // 1회 캐시: 재호출도 동일.
    try std.testing.expect(!f.enabled());
}
