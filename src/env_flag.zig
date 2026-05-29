//! 프로세스 environ 스냅샷 + env-presence/value 조회 (단일 소스).
//!
//! transpile fast-path / shared-namespace rewrite kill-switch 등 hot-path 토글과
//! profile/debug_log 의 env 설정 조회를 단일 소스로 통합 (RFC #3399 PR-3 cleanup).
//!
//! Zig 0.16: `std.process.{getEnvVarOwned,hasEnvVarConstant}` + `std.os.environ`
//! 전역 + `std.once` 가 모두 제거됐고, env 접근이 `std.process.Init` 의
//! `process.Environ` 로 일원화됐다. 진입점(main=juicy main / NAPI / WASM)이 시작 시
//! `captureEnviron` 으로 environ Map 을 1회 등록하면, 이후 leaf 모듈이
//! io/allocator/libc 없이 조회한다.
//!
//! env 는 프로세스 *불변* 상태이므로 read-only 전역 스냅샷이 정당하다 (가변 런타임
//! capability 인 io 의 전역 싱글톤 안티패턴과 구분). 미등록(null)이면 전부 미설정
//! 취급 — unit test(진입점 없음)는 env 플래그가 모두 off 로 보여 "기능 활성" 기본값과
//! 일치한다 (0.15 의 "env 미설정 → false" 와 동작 동일).

const std = @import("std");

/// 진입점에서 1회 등록하는 프로세스 environ 스냅샷 (decoded, cross-platform).
/// CLI=`init.environ_map`, NAPI=OS environ 으로 구성한 Map. lifetime=프로세스 전체.
var captured_env: ?*const std.process.Environ.Map = null;

/// 진입점(main/napi/wasm)에서 1회 호출. 이후 `get`/`Once` 가 이 스냅샷을 조회한다.
/// **반드시 다른 env 조회보다 먼저 호출** — `Once` 는 첫 `enabled()` 결과를 캐시하므로
/// 캡처 전에 평가되면 false 로 굳는다.
pub fn captureEnviron(map: *const std.process.Environ.Map) void {
    captured_env = map;
}

/// env 변수 *값* 조회. 반환 slice 는 캡처된 Map 소유(borrowed) — free 금지
/// (process lifetime 유효). 미캡처/미설정이면 null. allocator/io/libc 불필요.
pub fn get(key: []const u8) ?[]const u8 {
    const map = captured_env orelse return null;
    return map.get(key);
}

/// `env_name` 환경변수의 *존재 여부* 를 (사실상) 1회 평가해 캐시한다.
/// 같은 comptime `env_name` 인스턴스화는 동일 타입 (캐시 공유), 다른 이름은 독립 캐시.
///
/// 사용: `const fooEnabled = env_flag.Once("ZNTC_FOO");` → `fooEnabled.enabled()`.
pub fn Once(comptime env_name: []const u8) type {
    return struct {
        var initialized: bool = false;
        var value: bool = false;

        pub fn enabled() bool {
            // env presence 는 deterministic·idempotent 이라 race 시 중복 계산도
            // *결과* 가 동일 — std.once(0.16 제거) 의 "정확히 1회" 직렬화 대신
            // lock-free 게으른 캐시로 충분하다. 단, 워커 스레드가 첫 호출을 동시
            // 수행할 수 있으므로 value/initialized 접근을 모두 atomic 으로 둬
            // 데이터 레이스(UB)를 제거한다. (관측 동작은 std.once 와 동일.)
            if (@atomicLoad(bool, &initialized, .acquire)) {
                return @atomicLoad(bool, &value, .acquire);
            }
            const v = get(env_name) != null;
            @atomicStore(bool, &value, v, .release);
            @atomicStore(bool, &initialized, true, .release);
            return v;
        }
    };
}

test "Once: 미설정 env 는 false" {
    // unit test 는 captureEnviron 미호출 → captured_env=null → 모든 조회 false.
    const f = Once("ZNTC_ENV_FLAG_UNITTEST_ABSENT_XYZ");
    try std.testing.expect(!f.enabled());
    // 1회 캐시: 재호출도 동일.
    try std.testing.expect(!f.enabled());
}
