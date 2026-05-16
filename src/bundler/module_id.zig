//! 연합 경계 안정 모듈 ID (RFC docs/RFC_CJS_IIFE_CODE_SPLITTING.md §4.4)
//!
//! CJS/IIFE code splitting 의 런타임 require 레지스트리(`__zntc_mods`/
//! `__zntc_require`)가 청크 경계를 넘어 모듈을 식별하는 **결정적 ID**.
//!
//! **MF RFC `docs/RFC_MODULE_FEDERATION.md` §4.1 "연합 경계 안정 모듈 ID"와
//! 동일한 하위 인프라** — 한 번 구현해 P3(CJS/IIFE splitting)·MF P1(container/
//! shared scope)·P3-C(수렴)가 공유한다. 중복 구현 금지(RFC §3 표).
//!
//! 스킴(확정, RFC §7 / MF RFC §9 공동 결정): **relative-path 기반**.
//! - root(공통 조상/preserve-modules-root) 기준 상대경로
//! - posix 구분자(`/`) 정규화 — 빌드 결정성·OS 독립
//! - 소스 확장자 → 논리 `.js` 로 치환 — **출력 포맷/확장자와 무관**하게 안정
//!   (같은 모듈은 cjs/iife/esm 어디서나 같은 ID → MF 계약 핀 안정)
//! - 디버깅·스택트레이스 가독성·MF expose 키 자연 호환
//!
//! 내부(청크 내 호이스팅) 모듈에는 ID 를 부여하지 않는다 — 경계 모듈만.

const std = @import("std");

/// 모듈 절대경로 → 안정 모듈 ID. 반환값은 allocator 소유.
///
/// `abs_path`: 모듈 절대경로(소스 파일).
/// `root`: ID 의 기준 디렉터리(공통 조상 또는 preserve-modules-root). null 또는
///   매칭 실패 시 basename 으로 폴백(결정성 유지, 단 경로 정보 손실).
pub fn moduleId(
    allocator: std.mem.Allocator,
    abs_path: []const u8,
    root: ?[]const u8,
) ![]const u8 {
    const rel = relativeUnderRoot(abs_path, root) orelse
        std.fs.path.basename(abs_path);

    // 확장자 제거 후 논리 ".js" 부착. 확장자 없으면 그대로 + ".js".
    // 출력 길이는 정확히 stem.len+3 (stem 1:1 복사 + ".js") — ArrayList 불요.
    const ext = std.fs.path.extension(rel);
    const stem = rel[0 .. rel.len - ext.len];
    const buf = try allocator.alloc(u8, stem.len + 3);
    for (stem, 0..) |c, i| buf[i] = if (c == '\\') '/' else c;
    @memcpy(buf[stem.len..], ".js");
    return buf;
}

/// `abs_path` 가 `root` 하위면 root 상대경로(선행 '/' 제거), 아니면 null.
/// `computeRelativeImportPath` 의 `stripRoot` 와 동일 의미 — 경계 식별 전용으로
/// 별도 노출(레이어 분리: module_id 는 emit 비의존).
///
/// **컴포넌트 경계 정렬 필수**: 단순 byte-prefix 면 `/projsrc/a.ts` 가 root
/// `/proj` 하위로 오인돼 `/proj/src/a.ts` 와 ID 충돌(레지스트리 키 충돌 →
/// 잘못된 모듈 로드). norm 직후가 경로 끝 또는 '/' 일 때만 매칭.
fn relativeUnderRoot(abs_path: []const u8, root: ?[]const u8) ?[]const u8 {
    const r = root orelse return null;
    if (r.len == 0) return null;
    const norm = if (r[r.len - 1] == '/') r[0 .. r.len - 1] else r;
    if (!std.mem.startsWith(u8, abs_path, norm)) return null;
    // norm 경계가 컴포넌트 경계여야 함. norm=="" (root="/") 는 절대경로
    // 선두 '/' 가 경계 역할 → 통과.
    if (norm.len > 0 and norm.len < abs_path.len and abs_path[norm.len] != '/') return null;
    var rel = abs_path[norm.len..];
    if (rel.len > 0 and rel[0] == '/') rel = rel[1..];
    if (rel.len == 0) return null;
    return rel;
}

/// 여러 절대경로의 공통 조상 디렉터리(posix). 모듈 ID 의 root 가 명시되지 않은
/// code splitting 모드(non-preserve-modules)에서 결정적 root 산출에 사용.
/// 경로 0개 → "", 1개 → 그 dirname. 결과는 allocator 소유.
///
/// 결정성: 입력 순서 무관(공통 prefix 는 교환법칙 성립). 호출자가 정렬 불필요.
pub fn commonAncestorDir(
    allocator: std.mem.Allocator,
    paths: []const []const u8,
) ![]const u8 {
    if (paths.len == 0) return allocator.dupe(u8, "");
    if (paths.len == 1) {
        const d = std.fs.path.dirname(paths[0]) orelse "";
        return allocator.dupe(u8, d);
    }

    // 첫 경로의 dir 를 후보로, 나머지와 컴포넌트 단위 공통 prefix 축소.
    var common: []const u8 = std.fs.path.dirname(paths[0]) orelse "";
    for (paths[1..]) |p| {
        common = sharedDirPrefix(common, p);
        if (common.len == 0) break;
    }
    return allocator.dupe(u8, common);
}

/// `dir` 와 `path` 의 공통 디렉터리 prefix(경로 컴포넌트 경계 정렬).
/// "/a/b/c" 와 "/a/b/d/e.ts" → "/a/b". 부분 컴포넌트 매칭 방지("/a/bc" vs "/a/bd").
fn sharedDirPrefix(dir: []const u8, path: []const u8) []const u8 {
    var i: usize = 0;
    const max = @min(dir.len, path.len);
    while (i < max and dir[i] == path[i]) : (i += 1) {}
    if (i == dir.len and (i == path.len or path[i] == '/')) return dir;
    while (i > 0 and dir[i - 1] != '/') : (i -= 1) {}
    if (i == 0) return dir[0..0];
    return dir[0 .. i - 1]; // 후행 '/' 제외
}

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

test "moduleId: root 하위 상대경로 + posix + .js 치환" {
    const a = testing.allocator;
    const id = try moduleId(a, "/proj/src/pages/home.tsx", "/proj");
    defer a.free(id);
    try testing.expectEqualStrings("src/pages/home.js", id);
}

test "moduleId: root 후행 슬래시 정규화" {
    const a = testing.allocator;
    const id = try moduleId(a, "/proj/src/a.ts", "/proj/");
    defer a.free(id);
    try testing.expectEqualStrings("src/a.js", id);
}

test "moduleId: root 미매칭 → basename 폴백" {
    const a = testing.allocator;
    const id = try moduleId(a, "/other/x/util.ts", "/proj");
    defer a.free(id);
    try testing.expectEqualStrings("util.js", id);
}

test "moduleId: 컴포넌트 경계 — /projsrc 는 /proj 하위 아님(ID 충돌 방지)" {
    const a = testing.allocator;
    // 단순 byte-prefix 면 "src/a.js" 가 돼 /proj/src/a.ts 와 충돌.
    const id = try moduleId(a, "/projsrc/a.ts", "/proj");
    defer a.free(id);
    try testing.expectEqualStrings("a.js", id); // basename 폴백
    // 진짜 하위는 정상 매칭(경계가 '/')
    const ok = try moduleId(a, "/proj/src/a.ts", "/proj");
    defer a.free(ok);
    try testing.expectEqualStrings("src/a.js", ok);
}

test "moduleId: root=\"/\" — 절대경로 선두 '/' 가 경계" {
    const a = testing.allocator;
    const id = try moduleId(a, "/proj/src/a.ts", "/");
    defer a.free(id);
    try testing.expectEqualStrings("proj/src/a.js", id);
}

test "moduleId: root null → basename 폴백" {
    const a = testing.allocator;
    const id = try moduleId(a, "/x/y/z.mjs", null);
    defer a.free(id);
    try testing.expectEqualStrings("z.js", id);
}

test "moduleId: 확장자 없는 모듈" {
    const a = testing.allocator;
    const id = try moduleId(a, "/proj/bin/cli", "/proj");
    defer a.free(id);
    try testing.expectEqualStrings("bin/cli.js", id);
}

test "moduleId: 출력 포맷 무관(같은 모듈=같은 ID)" {
    const a = testing.allocator;
    // .ts / .tsx / .js 어떤 소스든 동일 논리 ID — MF 계약 핀 안정성.
    const a1 = try moduleId(a, "/p/m.ts", "/p");
    defer a.free(a1);
    const a2 = try moduleId(a, "/p/m.tsx", "/p");
    defer a.free(a2);
    try testing.expectEqualStrings(a1, a2);
}

test "commonAncestorDir: 다중 경로 공통 조상" {
    const a = testing.allocator;
    const d = try commonAncestorDir(a, &.{ "/proj/src/a/x.ts", "/proj/src/b/y.ts" });
    defer a.free(d);
    try testing.expectEqualStrings("/proj/src", d);
}

test "commonAncestorDir: 컴포넌트 경계(부분 매칭 방지)" {
    const a = testing.allocator;
    // "/proj/src" vs "/proj/srclib" — "/proj/src" 로 새지 않고 "/proj".
    const d = try commonAncestorDir(a, &.{ "/proj/src/a.ts", "/proj/srclib/b.ts" });
    defer a.free(d);
    try testing.expectEqualStrings("/proj", d);
}

test "commonAncestorDir: 입력 순서 무관(결정성)" {
    const a = testing.allocator;
    const d1 = try commonAncestorDir(a, &.{ "/p/x/a.ts", "/p/y/b.ts", "/p/x/c.ts" });
    defer a.free(d1);
    const d2 = try commonAncestorDir(a, &.{ "/p/x/c.ts", "/p/x/a.ts", "/p/y/b.ts" });
    defer a.free(d2);
    try testing.expectEqualStrings(d1, d2);
    try testing.expectEqualStrings("/p", d1);
}

test "commonAncestorDir: 단일 경로 → dirname" {
    const a = testing.allocator;
    const d = try commonAncestorDir(a, &.{"/proj/src/only.ts"});
    defer a.free(d);
    try testing.expectEqualStrings("/proj/src", d);
}

test "commonAncestorDir: 빈 입력 → 빈 문자열" {
    const a = testing.allocator;
    const d = try commonAncestorDir(a, &.{});
    defer a.free(d);
    try testing.expectEqualStrings("", d);
}
