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

fn isIdentifierByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '$';
}

fn isWhitespaceByte(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

fn outputDeclaresIdentifier(output: []const u8, name: []const u8) bool {
    const keywords = [_][]const u8{ "function ", "var ", "let ", "const ", "class " };
    var buf: [160]u8 = undefined;
    for (keywords) |keyword| {
        const pattern = std.fmt.bufPrint(&buf, "{s}{s}", .{ keyword, name }) catch continue;
        var from: usize = 0;
        while (std.mem.indexOfPos(u8, output, from, pattern)) |pos| {
            const after = pos + pattern.len;
            if (after == output.len or !isIdentifierByte(output[after])) return true;
            from = pos + 1;
        }
    }
    return false;
}

fn splitExportLocalName(output: []const u8, public_name: []const u8) ![]const u8 {
    var marker_buf: [160]u8 = undefined;
    const marker = try std.fmt.bufPrint(&marker_buf, " as {s}", .{public_name});
    const marker_pos = std.mem.indexOf(u8, output, marker) orelse return error.TestUnexpectedResult;

    var end = marker_pos;
    while (end > 0 and isWhitespaceByte(output[end - 1])) end -= 1;
    var start = end;
    while (start > 0 and isIdentifierByte(output[start - 1])) start -= 1;
    if (start == end) return error.TestUnexpectedResult;
    return output[start..end];
}

fn pathBasename(path: []const u8) []const u8 {
    var start: usize = 0;
    for (path, 0..) |c, index| {
        if (c == '/' or c == '\\') start = index + 1;
    }
    return path[start..];
}

fn importRefersToOutput(import_path: []const u8, output_path: []const u8) bool {
    return std.mem.eql(u8, import_path, output_path) or
        std.mem.eql(u8, pathBasename(import_path), pathBasename(output_path));
}

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

    var provider_index: ?usize = null;
    for (outs, 0..) |out, index| {
        for (out.exports) |name| {
            if (std.mem.eql(u8, name, "sharedExportedValue")) {
                provider_index = index;
                break;
            }
        }
        if (provider_index != null) break;
    }
    const provider_idx = provider_index orelse return error.TestUnexpectedResult;
    const provider = outs[provider_idx];
    const local_name = try splitExportLocalName(provider.contents, "sharedExportedValue");

    // 실제 chunk export alias와 declaration을 연결한다. 공개 계약 이름은 유지되지만
    // provider 내부 local은 minify 되고, writer가 그 local을 export 해야 한다.
    try std.testing.expect(!std.mem.eql(u8, local_name, "sharedExportedValue"));
    try std.testing.expect(outputDeclaresIdentifier(provider.contents, local_name));
    try std.testing.expect(std.mem.indexOf(u8, provider.contents, "anotherInternalHelper") == null);

    var found_consumer = false;
    for (outs, 0..) |out, index| {
        if (index == provider_idx) continue;
        var imports_provider = false;
        for (out.imports) |import_path| {
            if (importRefersToOutput(import_path, provider.path)) {
                imports_provider = true;
                break;
            }
        }
        if (!imports_provider) continue;
        found_consumer = true;
        try std.testing.expect(std.mem.indexOf(u8, out.contents, "sharedExportedValue") != null);
    }
    try std.testing.expect(found_consumer);
}
