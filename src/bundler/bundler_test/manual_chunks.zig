//! manualChunks 테스트 — 사용자 정의 청크 분할 (#1027).
//!
//! 최초 구현 범위 (Phase 1):
//!   - `ManualChunkEntry { name, patterns }` 으로 모듈 경로 substring 매칭
//!   - 매칭된 모듈을 지정 청크 이름으로 묶음
//!   - code_splitting=true 전제 (단일 파일 모드에서는 의미 없음)
//!
//! 향후 (Phase 2+):
//!   - regex 패턴, function callback (Rollup `manualChunks(id)` 시그니처)
//!   - async chunk 와의 우선순위 / 순환 의존 diagnostic

const std = @import("std");
const Bundler = @import("../bundler.zig").Bundler;
const types = @import("../types.zig");
const test_helpers = @import("../test_helpers.zig");
const writeFile = test_helpers.writeFile;
const absPath = test_helpers.absPath;
const hasChunk = test_helpers.hasChunk;
const chunkContaining = test_helpers.chunkContaining;

// ============================================================
// Baseline: manual_chunks 비어있으면 기존 자동 분할 동작
// ============================================================

test "manualChunks: empty list → 기존 code splitting 동작" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { a } from "./lib";
        \\console.log(a);
    );
    try writeFile(tmp.dir, "lib.ts", "export const a = 1;");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .code_splitting = true,
        .manual_chunks = &.{},
    });
    defer b.deinit();

    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    const outs = result.outputs orelse return error.TestUnexpectedResult;
    // 동적 import 없으므로 단일 청크
    try std.testing.expectEqual(@as(usize, 1), outs.len);
}

// ============================================================
// Phase 1: substring 매칭 — 지정 모듈을 전용 청크로 분리
// ============================================================

test "manualChunks: substring match → 지정 청크에 모듈 할당" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { a } from "./vendor-lib";
        \\import { b } from "./app-lib";
        \\console.log(a, b);
    );
    try writeFile(tmp.dir, "vendor-lib.ts", "export const a = \"VENDOR_MARKER\";");
    try writeFile(tmp.dir, "app-lib.ts", "export const b = \"APP_MARKER\";");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .code_splitting = true,
        .manual_chunks = &.{
            .{ .name = "vendor", .patterns = &.{"vendor-lib"} },
        },
    });
    defer b.deinit();

    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    const outs = result.outputs orelse return error.TestUnexpectedResult;

    // vendor 청크 존재
    try std.testing.expect(hasChunk(outs, "vendor"));
    // vendor 모듈 코드는 vendor 청크에
    const vendor_chunk = chunkContaining(outs, "VENDOR_MARKER") orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, vendor_chunk, "vendor") != null);
    // 매칭 안 된 app-lib 은 entry 청크에 (vendor 에 안 들어감)
    const app_chunk = chunkContaining(outs, "APP_MARKER") orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, app_chunk, "vendor") == null);
}

test "manualChunks: multi-pattern → 여러 모듈을 한 청크로" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { a } from "./alpha";
        \\import { b } from "./beta";
        \\console.log(a, b);
    );
    try writeFile(tmp.dir, "alpha.ts", "export const a = \"ALPHA\";");
    try writeFile(tmp.dir, "beta.ts", "export const b = \"BETA\";");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .code_splitting = true,
        .manual_chunks = &.{
            .{ .name = "shared", .patterns = &.{ "alpha", "beta" } },
        },
    });
    defer b.deinit();

    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    const outs = result.outputs orelse return error.TestUnexpectedResult;

    // shared 청크에 두 마커가 모두 있어야 함
    const alpha_chunk = chunkContaining(outs, "ALPHA") orelse return error.TestUnexpectedResult;
    const beta_chunk = chunkContaining(outs, "BETA") orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, alpha_chunk, "shared") != null);
    try std.testing.expect(std.mem.indexOf(u8, beta_chunk, "shared") != null);
    try std.testing.expectEqualStrings(alpha_chunk, beta_chunk);
}

test "manualChunks: multiple groups → 서로 다른 청크로 분리" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { a } from "./ui-lib";
        \\import { b } from "./data-lib";
        \\console.log(a, b);
    );
    try writeFile(tmp.dir, "ui-lib.ts", "export const a = \"UI\";");
    try writeFile(tmp.dir, "data-lib.ts", "export const b = \"DATA\";");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .code_splitting = true,
        .manual_chunks = &.{
            .{ .name = "ui", .patterns = &.{"ui-lib"} },
            .{ .name = "data", .patterns = &.{"data-lib"} },
        },
    });
    defer b.deinit();

    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    const outs = result.outputs orelse return error.TestUnexpectedResult;

    const ui_chunk = chunkContaining(outs, "UI") orelse return error.TestUnexpectedResult;
    const data_chunk = chunkContaining(outs, "DATA") orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, ui_chunk, "ui") != null);
    try std.testing.expect(std.mem.indexOf(u8, data_chunk, "data") != null);
    try std.testing.expect(!std.mem.eql(u8, ui_chunk, data_chunk));
}

// ============================================================
// rolldown parity 개념 (검증 개념만 이식, ZTS Phase 1 API 기준)
// ============================================================

test "manualChunks: transitive dependency follows matched module (rolldown include_dependencies_recursively)" {
    // 출처 개념: rolldown `advanced_chunks/include_dependencies_recursively`.
    // test regex 가 `foo.js` 만 매칭해도 snapshot 에서 `bar.js` (foo 의 dep) 가
    // 같은 vendor 청크에 들어감. 이유: dep 을 다른 청크로 두면 순서 보장/순환 이슈.
    // ZTS Phase 1 정책도 동일 — 매칭 모듈의 단독 dep 은 같은 청크로.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { foo } from "./foo";
        \\console.log(foo);
    );
    try writeFile(tmp.dir, "foo.ts",
        \\import { bar } from "./bar";
        \\export const foo = "FOO_MARKER " + bar;
    );
    try writeFile(tmp.dir, "bar.ts", "export const bar = \"BAR_MARKER\";");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .code_splitting = true,
        .manual_chunks = &.{
            .{ .name = "vendor", .patterns = &.{"foo"} },
        },
    });
    defer b.deinit();

    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    const outs = result.outputs orelse return error.TestUnexpectedResult;

    // foo 와 bar 가 모두 vendor 청크에
    const foo_chunk = chunkContaining(outs, "FOO_MARKER") orelse return error.TestUnexpectedResult;
    const bar_chunk = chunkContaining(outs, "BAR_MARKER") orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, foo_chunk, "vendor") != null);
    try std.testing.expectEqualStrings(foo_chunk, bar_chunk);
}

test "manualChunks: dynamic import target 은 manual 에서 제외 — async chunk 유지 (#1848/#1849 회피)" {
    // 정책: dynamic import target 모듈은 manualChunks 매칭돼도 별도 async chunk 유지.
    // 이유: dynamic import = "lazy load" 의미상 vendor 로 합치면 의도 반전. 또한 scope
    // hoisting 후 manual chunk 가 namespace 전체 export 를 재구성하는 건 scope hoisting
    // 의 핵심 가정과 충돌 (#1850 에서 근본 수정 검토). Rollup/rolldown 동일 정책.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\const lazy = import("./lazy");
        \\console.log(lazy);
    );
    try writeFile(tmp.dir, "lazy.ts", "export const v = \"LAZY_MARKER\";");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .code_splitting = true,
        .manual_chunks = &.{
            .{ .name = "vendor", .patterns = &.{"lazy"} },
        },
    });
    defer b.deinit();

    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    const outs = result.outputs orelse return error.TestUnexpectedResult;

    // lazy 는 vendor 청크로 가지 않고 async chunk 에 남아야 함.
    const lazy_chunk = chunkContaining(outs, "LAZY_MARKER") orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, lazy_chunk, "vendor") == null);
    // manual 매칭되는 다른 모듈이 없으므로 vendor 청크 자체가 생성되지 않아야 함.
    try std.testing.expect(!hasChunk(outs, "vendor"));
}

// ============================================================
// Phase 2: function resolver (Rollup `manualChunks(id)` 호환)
// ============================================================
// resolver 반환 이름은 동적으로 manual 청크를 생성. record 와 공존 시 resolver 우선.

fn resolverVendorSubstring(_: ?*anyopaque, id: []const u8) ?[]const u8 {
    if (std.mem.indexOf(u8, id, "vendor-lib") != null) return "vendor";
    return null;
}

fn resolverAlwaysNull(_: ?*anyopaque, _: []const u8) ?[]const u8 {
    return null;
}

fn resolverTwoGroups(_: ?*anyopaque, id: []const u8) ?[]const u8 {
    if (std.mem.indexOf(u8, id, "ui-") != null) return "ui";
    if (std.mem.indexOf(u8, id, "data-") != null) return "data";
    return null;
}

/// ctx 로 호출 카운터 전달 — 호출 검증용.
fn resolverCountingSink(ctx: ?*anyopaque, id: []const u8) ?[]const u8 {
    const counter: *usize = @ptrCast(@alignCast(ctx.?));
    counter.* += 1;
    if (std.mem.indexOf(u8, id, "match") != null) return "sink";
    return null;
}

test "manualChunks resolver: returns chunk name → 해당 청크로 할당" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { a } from "./vendor-lib";
        \\console.log(a);
    );
    try writeFile(tmp.dir, "vendor-lib.ts", "export const a = \"VENDOR_MARKER\";");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .code_splitting = true,
        .manual_chunks_resolver = resolverVendorSubstring,
    });
    defer b.deinit();

    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    const outs = result.outputs orelse return error.TestUnexpectedResult;

    const vendor_chunk = chunkContaining(outs, "VENDOR_MARKER") orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, vendor_chunk, "vendor") != null);
}

test "manualChunks resolver: returning null → 기존 자동 분배" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { a } from "./lib";
        \\console.log(a);
    );
    try writeFile(tmp.dir, "lib.ts", "export const a = \"ONLY\";");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .code_splitting = true,
        .manual_chunks_resolver = resolverAlwaysNull,
    });
    defer b.deinit();

    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    const outs = result.outputs orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), outs.len);
    try std.testing.expect(std.mem.indexOf(u8, outs[0].contents, "ONLY") != null);
}

test "manualChunks resolver: multiple names → 각자 다른 청크로 동적 생성" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { a } from "./ui-lib";
        \\import { b } from "./data-lib";
        \\console.log(a, b);
    );
    try writeFile(tmp.dir, "ui-lib.ts", "export const a = \"UI\";");
    try writeFile(tmp.dir, "data-lib.ts", "export const b = \"DATA\";");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .code_splitting = true,
        .manual_chunks_resolver = resolverTwoGroups,
    });
    defer b.deinit();

    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    const outs = result.outputs orelse return error.TestUnexpectedResult;

    const ui_chunk = chunkContaining(outs, "UI") orelse return error.TestUnexpectedResult;
    const data_chunk = chunkContaining(outs, "DATA") orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, ui_chunk, "ui") != null);
    try std.testing.expect(std.mem.indexOf(u8, data_chunk, "data") != null);
    try std.testing.expect(!std.mem.eql(u8, ui_chunk, data_chunk));
}

test "manualChunks resolver: ctx 로 호출 카운터 전달" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { a } from "./match-a";
        \\import { b } from "./lib-b";
        \\console.log(a, b);
    );
    try writeFile(tmp.dir, "match-a.ts", "export const a = \"A_MATCH\";");
    try writeFile(tmp.dir, "lib-b.ts", "export const b = \"B\";");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var counter: usize = 0;

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .code_splitting = true,
        .manual_chunks_resolver = resolverCountingSink,
        .manual_chunks_ctx = &counter,
    });
    defer b.deinit();

    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // resolver 는 최소 3 모듈 (entry + 2 dep) 에 대해 호출됨
    try std.testing.expect(counter >= 3);
    // "match-a" 는 sink 청크, "lib-b" 는 auto
    const outs = result.outputs orelse return error.TestUnexpectedResult;
    const a_chunk = chunkContaining(outs, "A_MATCH") orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, a_chunk, "sink") != null);
}

test "manualChunks resolver + record 공존: resolver 우선" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { a } from "./vendor-lib";
        \\console.log(a);
    );
    try writeFile(tmp.dir, "vendor-lib.ts", "export const a = \"MIX\";");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    // record 는 "record-chunk", resolver 는 "vendor" — 모듈이 둘 다 매칭
    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .code_splitting = true,
        .manual_chunks = &.{
            .{ .name = "record-chunk", .patterns = &.{"vendor-lib"} },
        },
        .manual_chunks_resolver = resolverVendorSubstring,
    });
    defer b.deinit();

    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    const outs = result.outputs orelse return error.TestUnexpectedResult;

    // resolver 결과 ("vendor") 가 우선. "record-chunk" 는 생성되지 않음.
    const chunk = chunkContaining(outs, "MIX") orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, chunk, "vendor") != null);
    try std.testing.expect(!hasChunk(outs, "record-chunk"));
}

test "manualChunks: no match → 엔트리 청크에 머묾 (기존 동작)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { a } from "./lib";
        \\console.log(a);
    );
    try writeFile(tmp.dir, "lib.ts", "export const a = \"ONLY\";");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .code_splitting = true,
        .manual_chunks = &.{
            .{ .name = "vendor", .patterns = &.{"nonexistent-pattern"} },
        },
    });
    defer b.deinit();

    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    const outs = result.outputs orelse return error.TestUnexpectedResult;
    // 매칭 없음 → vendor 청크 생성 안 됨, 단일 entry 청크만
    try std.testing.expectEqual(@as(usize, 1), outs.len);
    try std.testing.expect(std.mem.indexOf(u8, outs[0].contents, "ONLY") != null);
}
