//! 이 zts 바이너리의 빌드 식별자 — 디스크 캐시(#4438) 무효화 키의 컴파일러-버전 dimension.
//!
//! parser/semantic/transformer 로직이 바뀐 rebuild 후 같은 source 여도 결과가 달라질 수 있다.
//! in-memory 캐시는 프로세스 재시작으로 자연 무효화되지만 disk cache 는 그렇지 않으므로,
//! 바이너리를 식별하는 값을 캐시 키에 넣어야 한다(증분 컴파일러가 빌드 해시를 박는 것과 동일 발상).
//!
//! 식별자 = hash(git_sha + optimize mode + zig 버전). git 이 없으면 git 부분이 "unknown"
//! (tarball 빌드 등) — 같은 tarball 은 한 버전이라 무방. optimize mode 포함은 release-only 회귀
//! (debug 통과해도 ReleaseFast 에서만 깨지는 차이)를 다른 빌드로 분리하기 위함. git_sha 는
//! `git rev-parse HEAD`(clone depth 무관)라 full/shallow clone 이 같은 commit 에 같은 값.
//!
//! ⚠️ working tree 가 dirty 면 git_sha 가 `<sha>-dirty` 로 **고정**되어 dirty 변경 내용을
//! 구분하지 못한다. disk cache 를 켤 때(graph 통합) dirty 빌드는 캐시를 신뢰하지 않거나
//! (opt-in off) commit 후 사용해야 stale 을 피한다.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");

/// 세 dimension 을 NUL 구분자로 해시(고정 필드라 충돌 안전). pure 헬퍼라 테스트가 각 dimension
/// 의 민감도를 rebuild 없이 검증할 수 있다. 0 은 1 로 매핑 — `cache_key` 에서 0 은 가드 무력화
/// 신호라 build_id 가 (천문학적 확률로) 0 을 내면 안 된다.
fn compute(git_sha: []const u8, mode_tag: []const u8, zig_ver: []const u8) u64 {
    var h = std.hash.Wyhash.init(0);
    h.update(git_sha);
    h.update(&[_]u8{0});
    h.update(mode_tag);
    h.update(&[_]u8{0});
    h.update(zig_ver);
    const v = h.final();
    return if (v == 0) 1 else v;
}

/// 이 바이너리의 빌드 식별자(u64). graph 통합이 `cache_key.compute` 의 `compiler_build_id` 로
/// 넘긴다(항상 0 이 아님).
pub fn current() u64 {
    return compute(build_options.git_sha, @tagName(builtin.mode), builtin.zig_version_string);
}

/// 이 zts **바이너리가 dirty working tree 에서 컴파일됐는지**(컴파일타임 git 상태). dirty 면
/// git_sha 가 `<sha>-dirty` 로 고정돼 변경 내용을 구분 못 하므로(같은 마커로 다른 코드가 같은
/// build_id) disk cache 의 컴파일러-버전 가드가 무력 — caller(bundler)가 dirty 빌드는 disk cache
/// 를 비활성화하는 데 쓴다. 릴리스(클린) 바이너리 사용자는 항상 false(영향 없음).
pub fn isDirty() bool {
    return std.mem.indexOf(u8, build_options.git_sha, "-dirty") != null;
}

test "build_id: 각 dimension 이 키를 바꾸고 0 이 아님" {
    const t = std.testing;
    try t.expect(current() != 0);
    // 결정성.
    try t.expectEqual(compute("abc", "Debug", "0.16.0"), compute("abc", "Debug", "0.16.0"));
    // 각 dimension 변경 → 키 변경(하나라도 해시에서 빠지면 cross-build cache poisoning).
    try t.expect(compute("abc", "Debug", "0.16.0") != compute("abd", "Debug", "0.16.0")); // git_sha
    try t.expect(compute("abc", "Debug", "0.16.0") != compute("abc", "ReleaseFast", "0.16.0")); // mode
    try t.expect(compute("abc", "Debug", "0.16.0") != compute("abc", "Debug", "0.16.1")); // zig ver
}
