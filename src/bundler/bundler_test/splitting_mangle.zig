//! splitting_mangle.zig — code_splitting + minify_identifiers 시 청크 *내부* 로컬
//! 식별자가 mangle 되는지, 그리고 cross-chunk export/import 계약은 보존되는지 검증.
//!
//! 배경 (#4045): production code splitting(`--bundle --splitting --minify`)은 link/
//! post-shake 전역 mangle 을 두 경로 모두 건너뛰고, emit 의 per-chunk
//! `computeRenamesForModules` 가 충돌 deconflict 만 수행해 청크 내부 로컬이 풀네임으로
//! 남았다(번들 ~1.6배). 수정 후 per-chunk mangle 이 통합되어 내부 로컬은 축약되고,
//! cross-chunk 경계 심볼(`export { mangled as public }`)은 안정적으로 유지된다.

const std = @import("std");
const Bundler = @import("../bundler.zig").Bundler;
const test_helpers = @import("../test_helpers.zig");
const writeFile = test_helpers.writeFile;
const absPath = test_helpers.absPath;

// ============================================================
// 1. dynamic import 청크의 내부(비-export) 로컬은 mangle 된다.
// ============================================================

test "SplitMangle: 동적 청크 내부 로컬 식별자가 minify 시 축약된다" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // entry 가 lazy 를 동적 import → lazy 는 별도 청크.
    try writeFile(tmp.dir, "entry.ts",
        \\const m = import('./lazy');
        \\m.then((x) => console.log(x.publicApiName(3)));
    );
    // internalLongHelperFunction 은 export 되지 않고 청크 내부에서만 2회 참조 →
    // 인라인되지 않는 실 바인딩. publicApiName 은 cross-chunk 로 소비됨.
    try writeFile(tmp.dir, "lazy.ts",
        \\function internalLongHelperFunction(z) { return z * 2; }
        \\export function publicApiName(q) {
        \\  return internalLongHelperFunction(q) + internalLongHelperFunction(q + 1);
        \\}
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .format = .esm,
        .code_splitting = true,
        .minify_identifiers = true,
    });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    const outs = result.outputs orelse return error.TestUnexpectedResult;

    // 청크 전체에서 내부 헬퍼의 풀네임은 사라져야 한다 (mangle 됨).
    var has_internal_fullname = false;
    var has_public_contract = false;
    var has_behavior = false;
    for (outs) |o| {
        if (std.mem.indexOf(u8, o.contents, "internalLongHelperFunction") != null) has_internal_fullname = true;
        // cross-chunk export 계약 이름은 어딘가에 보존 (export { x as publicApiName } 형태).
        if (std.mem.indexOf(u8, o.contents, "publicApiName") != null) has_public_contract = true;
        if (std.mem.indexOf(u8, o.contents, "* 2") != null or std.mem.indexOf(u8, o.contents, "*2") != null) has_behavior = true;
    }
    try std.testing.expect(!has_internal_fullname); // 내부 로컬 mangle 됨
    try std.testing.expect(has_public_contract); // 경계 심볼 보존
    try std.testing.expect(has_behavior); // 동작 보존
}

// ============================================================
// 2. cross-chunk export/import 계약 이름은 mangle 후에도 일치한다.
// ============================================================

test "SplitMangle: cross-chunk import 이름과 export 이름이 minify 후에도 매칭된다" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // shared 모듈을 entry 와 lazy 가 공유 → shared 는 common 청크, sharedExportedValue 가
    // cross-chunk 경계 심볼. 내부 헬퍼 anotherInternalHelper 는 mangle 대상.
    try writeFile(tmp.dir, "entry.ts",
        \\import { sharedExportedValue } from './shared';
        \\const m = import('./lazy');
        \\m.then((x) => console.log(x.lazyExportedThing, sharedExportedValue));
    );
    try writeFile(tmp.dir, "lazy.ts",
        \\import { sharedExportedValue } from './shared';
        \\export const lazyExportedThing = sharedExportedValue + 1;
    );
    try writeFile(tmp.dir, "shared.ts",
        \\function anotherInternalHelper() { return 40; }
        \\export const sharedExportedValue = anotherInternalHelper() + 2;
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .format = .esm,
        .code_splitting = true,
        .minify_identifiers = true,
    });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    const outs = result.outputs orelse return error.TestUnexpectedResult;

    var has_internal = false;
    var import_count: usize = 0;
    var export_count: usize = 0;
    for (outs) |o| {
        if (std.mem.indexOf(u8, o.contents, "anotherInternalHelper") != null) has_internal = true;
        // 경계 심볼은 import/export 양쪽에 같은 public 이름으로 등장해야 cross-chunk 가 깨지지 않음.
        if (std.mem.indexOf(u8, o.contents, "sharedExportedValue") != null) import_count += 1;
    }
    // 내부 헬퍼는 mangle.
    try std.testing.expect(!has_internal);
    // 경계 심볼은 최소 한 청크(export)와 한 청크(import)에 등장 → 2개 이상 파일에서 발견.
    try std.testing.expect(import_count >= 2);
    _ = &export_count;
}
