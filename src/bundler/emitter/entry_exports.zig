//! Entry export emission helpers.

const std = @import("std");
const Span = @import("../../lexer/token.zig").Span;
const linker_mod = @import("../linker.zig");
const Linker = linker_mod.Linker;
const LinkingMetadata = linker_mod.LinkingMetadata;
const OutputExports = @import("../bundler.zig").OutputExports;
const FinalExportEntry = LinkingMetadata.FinalExportEntry;

/// `output.exports = "default"` + named 섞인 케이스를 graph diagnostic 으로 emit (#2159).
/// pending_diagnostics 와 동일하게 linker 의 `fatal_diagnostics` 에 append — `result.errors`
/// 에 노출되어 사용자가 fail-fast 가능 (Rollup 도 동일 케이스 throw).
pub fn emitOutputExportsConflictDiag(
    linker: *const Linker,
    module_path: []const u8,
    mode: OutputExports,
) !void {
    const linker_mut = @constCast(linker);
    linker_mut.diagnostics_mutex.lock();
    defer linker_mut.diagnostics_mutex.unlock();
    const msg = try std.fmt.allocPrint(
        linker.allocator,
        "output.exports=\"{s}\" requires default-only entry, but named exports are present (use 'auto' or 'named' instead)",
        .{@tagName(mode)},
    );
    try linker_mut.fatal_diagnostics.append(linker.allocator, .{
        .code = .output_exports_conflict,
        .severity = .@"error",
        .message = msg,
        // borrowed — module.path 가 owner. 다른 진단 사이트 (linker/metadata.zig) 와 일관.
        // linker.fatal_diagnostics deinit 은 message 만 free 하므로 owned dupe 시 leak.
        .file_path = module_path,
        .span = Span.EMPTY,
        .step = .emit,
    });
}

/// Entry export struct를 ESM `export { ... }` 구문으로 출력.
/// #3096: minify_whitespace 시 brace 안 공백 / 항목 사이 공백 제거 (`export{a,b as c};`).
/// 후행 `\n` 은 유지 — bundle 끝의 `//# sourceMappingURL=` 주석이 같은 줄로 붙어
/// `--line-limit` 초과하던 회귀(#3096 후속) 방지.
pub fn emitEsmEntryExports(
    allocator: std.mem.Allocator,
    entries: []const FinalExportEntry,
    minify_whitespace: bool,
) ![]const u8 {
    if (entries.len == 0) return try allocator.dupe(u8, "");

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, if (minify_whitespace) "export{" else "export {");
    for (entries, 0..) |e, i| {
        if (i > 0) try out.appendSlice(allocator, ",");
        if (!minify_whitespace) try out.append(allocator, ' ');
        try out.appendSlice(allocator, e.local);
        if (!std.mem.eql(u8, e.local, e.exported)) {
            try out.appendSlice(allocator, " as ");
            try out.appendSlice(allocator, e.exported);
        }
    }
    try out.appendSlice(allocator, if (minify_whitespace) "};\n" else " };\n");
    return try out.toOwnedSlice(allocator);
}

/// IIFE/UMD/AMD factory 반환값으로 entry exports를 출력.
pub fn emitWrappedEntryExports(
    allocator: std.mem.Allocator,
    entries: []const FinalExportEntry,
    minify_whitespace: bool,
) ![]const u8 {
    if (entries.len == 0) return try allocator.dupe(u8, "");

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, if (minify_whitespace) "return{" else "return {");
    for (entries, 0..) |e, i| {
        if (i > 0) try out.appendSlice(allocator, ",");
        if (!minify_whitespace) try out.append(allocator, ' ');
        if (!e.isDefault() and std.mem.eql(u8, e.local, e.exported)) {
            try out.appendSlice(allocator, e.local);
        } else {
            try out.appendSlice(allocator, e.exported);
            try out.appendSlice(allocator, if (minify_whitespace) ":" else ": ");
            try out.appendSlice(allocator, e.local);
        }
    }
    try out.appendSlice(allocator, if (minify_whitespace) "};\n" else " };\n");
    return try out.toOwnedSlice(allocator);
}

/// Entry export struct를 CJS 출력으로 변환.
/// mode 별 emit 분기:
///   auto    : default-only → `module.exports = X`, named-only → `exports.X = X`, mixed → 양쪽 + esModule
///   named   : 항상 named (`exports.X = X`) + esModule (default 있으면)
///   default_: default-only 만 — `module.exports = X`. named 섞이면 error.
///   none    : 빈 출력
///
/// caller-owned slice 반환. 빈 결과는 빈 string (null 아님 — caller 가 final_exports 자리에 넣음).
pub fn emitCjsEntryExports(
    allocator: std.mem.Allocator,
    entries: []const FinalExportEntry,
    mode: OutputExports,
) ![]const u8 {
    if (mode == .none) return try allocator.dupe(u8, "");
    if (entries.len == 0) return try allocator.dupe(u8, "");

    // default / named 분리
    var default_local: ?[]const u8 = null;
    var has_named = false;
    for (entries) |e| {
        if (e.isDefault()) {
            default_local = e.local;
        } else {
            has_named = true;
        }
    }

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    switch (mode) {
        .none => {},
        .default_ => {
            if (has_named or default_local == null) return error.OutputExportsDefaultRequiresSingleDefault;
            try out.writer(allocator).print("module.exports = {s};\n", .{default_local.?});
        },
        .named => {
            for (entries) |e| {
                try out.writer(allocator).print("exports.{s} = {s};\n", .{ e.exported, e.local });
            }
            if (default_local != null) {
                try out.appendSlice(allocator, "Object.defineProperty(exports, \"__esModule\", {value: true});\n");
            }
        },
        .auto => {
            if (default_local) |dl| {
                if (!has_named) {
                    // default-only → single module.exports
                    try out.writer(allocator).print("module.exports = {s};\n", .{dl});
                } else {
                    // mixed — named 형태 + esModule flag
                    for (entries) |e| {
                        try out.writer(allocator).print("exports.{s} = {s};\n", .{ e.exported, e.local });
                    }
                    try out.appendSlice(allocator, "Object.defineProperty(exports, \"__esModule\", {value: true});\n");
                }
            } else {
                // named-only — esModule flag 없음 (Rollup 기본 auto 동작)
                for (entries) |e| {
                    try out.writer(allocator).print("exports.{s} = {s};\n", .{ e.exported, e.local });
                }
            }
        },
    }

    return try out.toOwnedSlice(allocator);
}

test "emitCjsEntryExports: auto mode default-only → module.exports" {
    const entries = &.{FinalExportEntry{ .local = "x", .exported = "default" }};
    const out = try emitCjsEntryExports(std.testing.allocator, entries, .auto);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("module.exports = x;\n", out);
}

test "emitCjsEntryExports: auto mode named-only → exports.X (no esModule)" {
    const entries = &.{
        FinalExportEntry{ .local = "a", .exported = "a" },
        FinalExportEntry{ .local = "b", .exported = "b" },
    };
    const out = try emitCjsEntryExports(std.testing.allocator, entries, .auto);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("exports.a = a;\nexports.b = b;\n", out);
}

test "emitCjsEntryExports: auto mode mixed → exports.X + esModule" {
    const entries = &.{
        FinalExportEntry{ .local = "a", .exported = "a" },
        FinalExportEntry{ .local = "b", .exported = "default" },
    };
    const out = try emitCjsEntryExports(std.testing.allocator, entries, .auto);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "exports.a = a;") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "exports.default = b;") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "__esModule") != null);
}

test "emitCjsEntryExports: named mode → 항상 named + esModule (default 있으면)" {
    const entries = &.{FinalExportEntry{ .local = "x", .exported = "default" }};
    const out = try emitCjsEntryExports(std.testing.allocator, entries, .named);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "exports.default = x;") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "__esModule") != null);
}

test "emitCjsEntryExports: default_ mode default-only → module.exports" {
    const entries = &.{FinalExportEntry{ .local = "x", .exported = "default" }};
    const out = try emitCjsEntryExports(std.testing.allocator, entries, .default_);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("module.exports = x;\n", out);
}

test "emitCjsEntryExports: default_ mode named 섞이면 error" {
    const entries = &.{
        FinalExportEntry{ .local = "a", .exported = "a" },
        FinalExportEntry{ .local = "b", .exported = "default" },
    };
    const result = emitCjsEntryExports(std.testing.allocator, entries, .default_);
    try std.testing.expectError(error.OutputExportsDefaultRequiresSingleDefault, result);
}

test "emitCjsEntryExports: none mode → 빈 string" {
    const entries = &.{
        FinalExportEntry{ .local = "a", .exported = "a" },
        FinalExportEntry{ .local = "b", .exported = "b" },
    };
    const out = try emitCjsEntryExports(std.testing.allocator, entries, .none);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("", out);
}

test "emitEsmEntryExports: emits export statement from typed entries" {
    const entries = &.{
        FinalExportEntry{ .local = "a", .exported = "a" },
        FinalExportEntry{ .local = "b$1", .exported = "b" },
        FinalExportEntry{ .local = "x", .exported = "default" },
    };
    const out = try emitEsmEntryExports(std.testing.allocator, entries, false);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("export { a, b$1 as b, x as default };\n", out);
}

test "emitEsmEntryExports: minify 시 공백/newline 제거 (#3096)" {
    const entries = &.{
        FinalExportEntry{ .local = "a", .exported = "a" },
        FinalExportEntry{ .local = "b$1", .exported = "b" },
    };
    const out = try emitEsmEntryExports(std.testing.allocator, entries, true);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("export{a,b$1 as b};\n", out);
}

test "emitWrappedEntryExports: emits object return from typed entries" {
    const entries = &.{
        FinalExportEntry{ .local = "a", .exported = "a" },
        FinalExportEntry{ .local = "b$1", .exported = "b" },
        FinalExportEntry{ .local = "x", .exported = "default" },
    };
    const out = try emitWrappedEntryExports(std.testing.allocator, entries, false);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("return { a, b: b$1, default: x };\n", out);
}

test "emitWrappedEntryExports: minify 시 공백/newline 제거 (#3096)" {
    const entries = &.{
        FinalExportEntry{ .local = "a", .exported = "a" },
        FinalExportEntry{ .local = "b$1", .exported = "b" },
    };
    const out = try emitWrappedEntryExports(std.testing.allocator, entries, true);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("return{a,b:b$1};\n", out);
}
