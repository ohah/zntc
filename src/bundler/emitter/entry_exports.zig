//! Entry export emission helpers.

const std = @import("std");
const Span = @import("../../lexer/token.zig").Span;
const linker_mod = @import("../linker.zig");
const Linker = linker_mod.Linker;
const LinkingMetadata = linker_mod.LinkingMetadata;
const OutputExports = @import("../bundler.zig").OutputExports;
const FinalExportEntry = LinkingMetadata.FinalExportEntry;

fn appendEntryKey(out: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, entry: FinalExportEntry) !void {
    const keys = @import("../public_export_key.zig");
    const key = if (entry.public_key_literal) |literal| try keys.fromLiteralSyntax(allocator, literal) else try keys.fromSyntax(allocator, entry.exported);
    defer key.deinit(allocator);
    try @import("../emitter.zig").appendJsonString(out, allocator, key.text);
}

fn entryIsDefault(allocator: std.mem.Allocator, entry: FinalExportEntry) !bool {
    const keys = @import("../public_export_key.zig");
    const key = if (entry.public_key_literal) |literal| try keys.fromLiteralSyntax(allocator, literal) else try keys.fromSyntax(allocator, entry.exported);
    defer key.deinit(allocator);
    return std.mem.eql(u8, key.text, "default");
}

fn appendOrdinaryCjsExport(out: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, entry: FinalExportEntry, def_prop_name: ?[]const u8) !void {
    const def_prop = def_prop_name orelse return error.MissingCjsEntryDescriptorIdentity;
    try out.print(allocator, "{s}(exports,", .{def_prop});
    try appendEntryKey(out, allocator, entry);
    try out.print(allocator, ",{{enumerable:true,get:function(){{return {s};}}}});\n", .{entry.local});
}

pub fn needsCjsEntryDescriptors(allocator: std.mem.Allocator, entries: []const FinalExportEntry, mode: OutputExports) !bool {
    if (mode == .none or mode == .default_ or entries.len == 0) return false;
    if (mode == .named) return true;
    for (entries) |entry| if (!try entryIsDefault(allocator, entry)) return true;
    return false;
}

/// (#4120) CJS interop entry 의 `var <local> = <interop>;` materialize 문을 export 코드 앞에 emit.
/// require_X 는 같은 청크 모듈 본문에서 정의(var 호이스팅 + __commonJS memoize) — 단, 평가 순서상
/// CJS 모듈 본문이 이 materialize *전* 에 실행돼야 require_X() 가 함수다(emit 위치는 chunks.zig 보장).
fn appendMaterializations(
    out: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    entries: []const FinalExportEntry,
) !void {
    for (entries) |e| {
        if (e.materialize) |stmt| try out.appendSlice(allocator, stmt);
    }
}

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

/// Borrows the module body and returns an owned combined buffer only when
/// public exports exist. The caller retains all other emission buffers until
/// this fallible rendering succeeds.
pub fn appendWrappedEsmEntryExports(
    allocator: std.mem.Allocator,
    module_code: []const u8,
    entries: []const FinalExportEntry,
    minify_whitespace: bool,
) !?[]const u8 {
    const suffix = try emitEsmEntryExports(allocator, entries, minify_whitespace);
    defer allocator.free(suffix);
    if (suffix.len == 0) return null;
    return try std.mem.concat(allocator, u8, &.{ module_code, suffix });
}

/// Final-export aliases preserve ModuleExportName syntax: a quoted alias is
/// already a JS string literal. Other aliases are semantic identifier strings.
fn appendPublicKeyLiteral(out: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, alias: []const u8) !void {
    if (alias.len >= 2 and (alias[0] == '\'' or alias[0] == '"') and alias[alias.len - 1] == alias[0]) {
        try out.appendSlice(allocator, alias);
    } else try @import("../emitter.zig").appendJsonString(out, allocator, alias);
}

/// Publish the public namespace without snapshotting wrapper-owned values.
/// The public-key ledger reads the exact wrapper namespace storage; its
/// source getters own live declarations and fixed expression-default facades.
pub fn appendWrappedCjsNamedEntryExports(
    allocator: std.mem.Allocator,
    module_code: []const u8,
    namespace_name: []const u8,
    entries: []const FinalExportEntry,
    def_prop_name: []const u8,
) !?[]const u8 {
    if (entries.len == 0) return null;
    var suffix: std.ArrayListUnmanaged(u8) = .empty;
    defer suffix.deinit(allocator);
    for (entries) |entry| {
        try suffix.print(allocator, "{s}(exports,", .{def_prop_name});
        try appendEntryKey(&suffix, allocator, entry);
        try suffix.print(allocator, ",{{enumerable:true,get:function(){{return {s}[", .{namespace_name});
        try appendEntryKey(&suffix, allocator, entry);
        try suffix.appendSlice(allocator, "];}});\n");
    }
    // A real public __esModule export owns its key, including quoted aliases.
    // Only the absent compiler interop marker is added; no getter is evaluated.
    if (try readyNamespaceNeedsMarker(allocator, entries, true, .named))
        try suffix.print(allocator, "{s}(exports,\"__esModule\",{{value:true}});\n", .{def_prop_name});
    return try std.mem.concat(allocator, u8, &.{ module_code, suffix.items });
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

    // (#4120) CJS interop entry: export 문 *전* 에 `var <local> = <interop>;` 을 깐다(식별자 export).
    try appendMaterializations(&out, allocator, entries);

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

    // (#4120) CJS interop entry: factory `return {...}` 앞에 `var <local> = <interop>;` materialize
    // (factory scope 내 — require_X 본문은 청크 emit 순서상 이 앞에 실행됨).
    try appendMaterializations(&out, allocator, entries);

    // `return + object literal` 의 minify-whitespace 정책. AST 기반 emit 가 아닌 순수 text
    // 합성이라 [[operandStartsIdentifierLikeDepth]] (statements.zig) 와 정책 동기화 필요 —
    // 변경 시 함께 update.
    try out.appendSlice(allocator, if (minify_whitespace) "return{" else "return {");
    for (entries, 0..) |e, i| {
        if (i > 0) try out.appendSlice(allocator, ",");
        if (!minify_whitespace) try out.append(allocator, ' ');
        try out.appendSlice(allocator, "get ");
        try appendEntryKey(&out, allocator, e);
        try out.print(allocator, "(){{return {s};}}", .{e.local});
    }
    try out.appendSlice(allocator, if (minify_whitespace) "};\n" else " };\n");
    return try out.toOwnedSlice(allocator);
}

/// Publish a library value only after its registered initializer settles.
/// No callback parameter or temporary binding is introduced: all value operands
/// come from the existing final-export entries and remain live through getters.
pub fn readyNamespaceNeedsMarker(allocator: std.mem.Allocator, entries: []const FinalExportEntry, cjs: bool, mode: OutputExports) !bool {
    if (!cjs or mode == .none or mode == .default_) return false;
    var has_default = false;
    var has_named = false;
    var has_marker = false;
    for (entries) |entry| {
        const keys = @import("../public_export_key.zig");
        const key = if (entry.public_key_literal) |literal| try keys.fromLiteralSyntax(allocator, literal) else try keys.fromSyntax(allocator, entry.exported);
        defer key.deinit(allocator);
        if (std.mem.eql(u8, key.text, "default")) has_default = true else has_named = true;
        if (std.mem.eql(u8, key.text, "__esModule")) has_marker = true;
    }
    return has_default and !has_marker and (mode == .named or has_named);
}

pub fn emitReadyEntryExports(
    allocator: std.mem.Allocator,
    entries: []const FinalExportEntry,
    promise_name: ?[]const u8,
    cjs: bool,
    mode: OutputExports,
    assign_cjs: bool,
    def_prop_name: ?[]const u8,
) ![]const u8 {
    if (cjs and mode == .none) return try allocator.dupe(u8, "");
    var default_local: ?[]const u8 = null;
    var has_named = false;
    var has_es_module_key = false;
    for (entries) |entry| {
        const keys = @import("../public_export_key.zig");
        const key = if (entry.public_key_literal) |literal| try keys.fromLiteralSyntax(allocator, literal) else try keys.fromSyntax(allocator, entry.exported);
        defer key.deinit(allocator);
        if (std.mem.eql(u8, key.text, "default")) default_local = entry.local else has_named = true;
        if (std.mem.eql(u8, key.text, "__esModule")) has_es_module_key = true;
    }
    if (cjs and mode == .default_ and (has_named or default_local == null)) return error.OutputExportsDefaultRequiresSingleDefault;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    if (promise_name) |promise| {
        try out.appendSlice(allocator, if (assign_cjs) "module.exports = " else "return ");
        try out.appendSlice(allocator, promise);
        try out.appendSlice(allocator, ".then(function() {\n");
    }
    try appendMaterializations(&out, allocator, entries);
    if (cjs and (mode == .default_ or (mode == .auto and default_local != null and !has_named))) {
        try out.print(allocator, "return {s};\n", .{default_local.?});
    } else {
        const marker = cjs and default_local != null and !has_es_module_key;
        if (marker) {
            const def_prop = def_prop_name orelse return error.MissingAsyncEntryMarkerIdentity;
            try out.print(allocator, "return {s}({{", .{def_prop});
        } else try out.appendSlice(allocator, "return {");
        for (entries, 0..) |entry, i| {
            if (i != 0) try out.appendSlice(allocator, ",");
            try out.appendSlice(allocator, "get ");
            if (entry.public_key_literal) |literal| {
                const keys = @import("../public_export_key.zig");
                const key = try keys.fromLiteralSyntax(allocator, literal);
                defer key.deinit(allocator);
                const quoted = try std.json.Stringify.valueAlloc(allocator, key.text, .{});
                defer allocator.free(quoted);
                try out.appendSlice(allocator, quoted);
            } else {
                try out.appendSlice(allocator, entry.exported);
            }
            try out.print(allocator, "() {{ return {s}; }}", .{entry.local});
        }
        try out.appendSlice(allocator, if (marker) "},\"__esModule\",{value:true});\n" else "};\n");
    }
    if (promise_name != null) try out.appendSlice(allocator, "});\n");
    return try out.toOwnedSlice(allocator);
}

/// A wrapped module's registered namespace, rather than an inaccessible body
/// local, owns every public value read after initialization.
pub fn emitReadyNamespaceExports(
    allocator: std.mem.Allocator,
    entries: []const FinalExportEntry,
    namespace_name: []const u8,
    readiness: ?[]const u8,
    cjs: bool,
    mode: OutputExports,
    assign_cjs: bool,
    def_prop_name: ?[]const u8,
) ![]const u8 {
    var projected: std.ArrayList(FinalExportEntry) = .empty;
    defer {
        for (projected.items) |entry| allocator.free(entry.local);
        projected.deinit(allocator);
    }
    for (entries) |entry| {
        const keys = @import("../public_export_key.zig");
        const key = if (entry.public_key_literal) |literal| try keys.fromLiteralSyntax(allocator, literal) else try keys.fromSyntax(allocator, entry.exported);
        defer key.deinit(allocator);
        const quoted = try std.json.Stringify.valueAlloc(allocator, key.text, .{});
        defer allocator.free(quoted);
        const local = try std.fmt.allocPrint(allocator, "{s}[{s}]", .{ namespace_name, quoted });
        errdefer allocator.free(local);
        var mapped = entry;
        mapped.local = local;
        mapped.materialize = null;
        try projected.append(allocator, mapped);
    }
    return emitReadyEntryExports(allocator, projected.items, readiness, cjs, mode, assign_cjs, def_prop_name);
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
    /// (#4532 증상4) require 앞에 hoist 된 function-decl export 명 집합 — bottom 방출서 제외(중복 방지).
    /// null 이면 제외 없음.
    skip_hoisted: ?*const std.StringHashMapUnmanaged(void),
    def_prop_name: ?[]const u8,
) ![]const u8 {
    if (mode == .none) return try allocator.dupe(u8, "");
    if (entries.len == 0) return try allocator.dupe(u8, "");

    const skip = struct {
        fn f(s: ?*const std.StringHashMapUnmanaged(void), e: FinalExportEntry) bool {
            return if (s) |set| (!e.isDefault() and set.contains(e.exported)) else false;
        }
    }.f;

    // default / named 분리
    var default_local: ?[]const u8 = null;
    var has_named = false;
    for (entries) |e| {
        if (try entryIsDefault(allocator, e)) {
            default_local = e.local;
        } else {
            has_named = true;
        }
    }

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    // (#4120) CJS interop entry: `exports.x = local`/`module.exports = local` 전에
    // `var <local> = <interop>;` materialize. require_X 본문은 청크 emit 순서상 이 앞에 실행됨.
    try appendMaterializations(&out, allocator, entries);

    switch (mode) {
        .none => {},
        .default_ => {
            if (has_named or default_local == null) return error.OutputExportsDefaultRequiresSingleDefault;
            try out.print(allocator, "module.exports = {s};\n", .{default_local.?});
        },
        .named => {
            for (entries) |e| {
                if (skip(skip_hoisted, e)) continue;
                try appendOrdinaryCjsExport(&out, allocator, e, def_prop_name);
            }
            if (try readyNamespaceNeedsMarker(allocator, entries, true, mode)) {
                const def_prop = def_prop_name orelse return error.MissingCjsEntryDescriptorIdentity;
                try out.print(allocator, "{s}(exports,\"__esModule\",{{value:true}});\n", .{def_prop});
            }
        },
        .auto => {
            if (default_local) |dl| {
                if (!has_named) {
                    // default-only → single module.exports
                    try out.print(allocator, "module.exports = {s};\n", .{dl});
                } else {
                    // mixed — named 형태 + esModule flag
                    for (entries) |e| {
                        if (skip(skip_hoisted, e)) continue;
                        try appendOrdinaryCjsExport(&out, allocator, e, def_prop_name);
                    }
                    if (try readyNamespaceNeedsMarker(allocator, entries, true, mode)) {
                        const def_prop = def_prop_name orelse return error.MissingCjsEntryDescriptorIdentity;
                        try out.print(allocator, "{s}(exports,\"__esModule\",{{value:true}});\n", .{def_prop});
                    }
                }
            } else {
                // named-only — esModule flag 없음 (Rollup 기본 auto 동작)
                for (entries) |e| {
                    if (skip(skip_hoisted, e)) continue;
                    try appendOrdinaryCjsExport(&out, allocator, e, def_prop_name);
                }
            }
        },
    }

    return try out.toOwnedSlice(allocator);
}

test "emitCjsEntryExports: auto mode default-only → module.exports" {
    const entries = &.{FinalExportEntry{ .local = "x", .exported = "default" }};
    const out = try emitCjsEntryExports(std.testing.allocator, entries, .auto, null, "__defProp");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("module.exports = x;\n", out);
}

test "emitCjsEntryExports: auto mode named-only → exports.X (no esModule)" {
    const entries = &.{
        FinalExportEntry{ .local = "a", .exported = "a" },
        FinalExportEntry{ .local = "b", .exported = "b" },
    };
    const out = try emitCjsEntryExports(std.testing.allocator, entries, .auto, null, "__defProp");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("__defProp(exports,\"a\",{enumerable:true,get:function(){return a;}});\n__defProp(exports,\"b\",{enumerable:true,get:function(){return b;}});\n", out);
}

test "emitCjsEntryExports: auto mode mixed → exports.X + esModule" {
    const entries = &.{
        FinalExportEntry{ .local = "a", .exported = "a" },
        FinalExportEntry{ .local = "b", .exported = "default" },
    };
    const out = try emitCjsEntryExports(std.testing.allocator, entries, .auto, null, "__defProp");
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "__defProp(exports,\"a\",{enumerable:true,get:function(){return a;}});") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "__defProp(exports,\"default\",{enumerable:true,get:function(){return b;}});") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "__esModule") != null);
}

test "emitCjsEntryExports: named mode → 항상 named + esModule (default 있으면)" {
    const entries = &.{FinalExportEntry{ .local = "x", .exported = "default" }};
    const out = try emitCjsEntryExports(std.testing.allocator, entries, .named, null, "__defProp");
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "__defProp(exports,\"default\",{enumerable:true,get:function(){return x;}});") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "__esModule") != null);
}

test "emitCjsEntryExports: default_ mode default-only → module.exports" {
    const entries = &.{FinalExportEntry{ .local = "x", .exported = "default" }};
    const out = try emitCjsEntryExports(std.testing.allocator, entries, .default_, null, "__defProp");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("module.exports = x;\n", out);
}

test "emitCjsEntryExports: default_ mode named 섞이면 error" {
    const entries = &.{
        FinalExportEntry{ .local = "a", .exported = "a" },
        FinalExportEntry{ .local = "b", .exported = "default" },
    };
    const result = emitCjsEntryExports(std.testing.allocator, entries, .default_, null, "__defProp");
    try std.testing.expectError(error.OutputExportsDefaultRequiresSingleDefault, result);
}

test "emitCjsEntryExports: none mode → 빈 string" {
    const entries = &.{
        FinalExportEntry{ .local = "a", .exported = "a" },
        FinalExportEntry{ .local = "b", .exported = "b" },
    };
    const out = try emitCjsEntryExports(std.testing.allocator, entries, .none, null, "__defProp");
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
    try std.testing.expectEqualStrings("return { get \"a\"(){return a;}, get \"b\"(){return b$1;}, get \"default\"(){return x;} };\n", out);
}

test "emitWrappedEntryExports: minify 시 공백/newline 제거 (#3096)" {
    const entries = &.{
        FinalExportEntry{ .local = "a", .exported = "a" },
        FinalExportEntry{ .local = "b$1", .exported = "b" },
    };
    const out = try emitWrappedEntryExports(std.testing.allocator, entries, true);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("return{get \"a\"(){return a;},get \"b\"(){return b$1;}};\n", out);
}

test "wrapped ESM entries publish their canonical default binding" {
    const Bundler = @import("../bundler.zig").Bundler;
    const helpers = @import("../test_helpers.zig");
    for ([_][]const u8{
        "export default function(){return value();}",
        "export default function answer(){return value();}",
        "export default ()=>value();",
        "export default class{run(){return value();}}",
        "export default class Box{run(){return value();}}",
        "export default {n:42};",
        "export default [42];",
        "export default 42;",
        "const answer=42;export default answer;",
        "export default value();",
    }) |body| for ([_]bool{ false, true }) |minify| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const source = try std.fmt.allocPrint(std.testing.allocator, "import{{value}}from'./dep.mjs';{s}export const marker=7;export{{marker as publicAlias}};globalThis.entryValue=value;", .{body});
        defer std.testing.allocator.free(source);
        try helpers.writeFile(tmp.dir, "package.json", "{\"type\":\"module\"}");
        try helpers.writeFile(tmp.dir, "entry.mjs", source);
        try helpers.writeFile(tmp.dir, "second.mjs", "import{value}from'./dep.mjs';globalThis.second=value;");
        try helpers.writeFile(tmp.dir, "dep.mjs", "export function value(){return 42;}");
        const entry = try helpers.absPath(&tmp, "entry.mjs");
        defer std.testing.allocator.free(entry);
        const second = try helpers.absPath(&tmp, "second.mjs");
        defer std.testing.allocator.free(second);
        const options: @import("../bundler.zig").BundleOptions = .{ .entry_points = &.{ entry, second }, .platform = .react_native, .format = .esm, .code_splitting = true, .strict_execution_order = true, .entry_error_guard = true, .minify_identifiers = minify, .minify_syntax = minify, .minify_whitespace = minify };
        var cache = Bundler.initResolveCacheFromOptions(std.testing.allocator, options);
        defer cache.deinit();
        var graph = @import("../graph.zig").ModuleGraph.init(std.testing.allocator, &cache);
        defer graph.deinit();
        var bundler = Bundler.initWithGraph(std.testing.allocator, options, &cache, &graph);
        defer bundler.deinit();
        const output = try bundler.bundle(std.testing.io);
        defer output.deinit(std.testing.allocator);
        try std.testing.expect(!output.hasErrors());
        const module = graph.getModule(graph.path_to_module.get(entry).?).?;
        try std.testing.expectEqual(@TypeOf(module.wrap_kind).esm, module.wrap_kind);
        for (output.outputs.?) |file| try helpers.writeFile(tmp.dir, std.fs.path.basename(file.path), file.contents);
        const emitted = try helpers.absPath(&tmp, "entry.js");
        defer std.testing.allocator.free(emitted);
        const script = try std.fmt.allocPrint(std.testing.allocator, "const ns=await import('file://{s}');const d=ns.default;const result=typeof d==='function'?(d.prototype?.run?new d().run():d()):Array.isArray(d)?d[0]:d?.n??d;console.log(JSON.stringify({{keys:Object.keys(ns),result,marker:ns.marker,alias:ns.publicAlias}}));", .{emitted});
        defer std.testing.allocator.free(script);
        const execution = try std.process.run(std.testing.allocator, std.testing.io, .{ .argv = &.{ "node", "--input-type=module", "-e", script }, .stdout_limit = .limited(16384), .stderr_limit = .limited(16384) });
        defer std.testing.allocator.free(execution.stdout);
        defer std.testing.allocator.free(execution.stderr);
        try std.testing.expectEqualStrings("{\"keys\":[\"default\",\"marker\",\"publicAlias\"],\"result\":42,\"marker\":7,\"alias\":7}\n", execution.stdout);
    };
}

fn checkWrappedExportAllocation(allocator: std.mem.Allocator) !void {
    const body = "var local=42;";
    const entries = [_]FinalExportEntry{.{ .local = "local", .exported = "default" }};
    const combined = (try appendWrappedEsmEntryExports(allocator, body, &entries, false)).?;
    defer allocator.free(combined);
    try std.testing.expectEqualStrings("var local=42;export { local as default };\n", combined);
    try std.testing.expectEqualStrings("var local=42;", body);
}

test "wrapped entry export concatenation frees allocation failures without consuming the body" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, checkWrappedExportAllocation, .{});
    try std.testing.expectEqual(@as(?[]const u8, null), try appendWrappedEsmEntryExports(std.testing.allocator, "var local=42;", &.{}, false));
}

fn checkWrappedCjsExportAllocation(allocator: std.mem.Allocator) !void {
    const body = "var namespace={};";
    const entries = [_]FinalExportEntry{
        .{ .local = "must_not_be_evaluated", .exported = "default" },
        .{ .local = "must_not_be_evaluated", .exported = "'x-y'" },
    };
    const combined = (try appendWrappedCjsNamedEntryExports(allocator, body, "namespace", &entries, "__defProp")).?;
    defer allocator.free(combined);
    try std.testing.expectEqualStrings("var namespace={};__defProp(exports,\"default\",{enumerable:true,get:function(){return namespace[\"default\"];}});\n__defProp(exports,\"x-y\",{enumerable:true,get:function(){return namespace[\"x-y\"];}});\n__defProp(exports,\"__esModule\",{value:true});\n", combined);
    try std.testing.expectEqualStrings("var namespace={};", body);
    try std.testing.expect(std.mem.indexOf(u8, combined, "must_not_be_evaluated") == null);
}

test "preserved CJS public renderer borrows typed namespace and frees allocation failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, checkWrappedCjsExportAllocation, .{});
    try std.testing.expectEqual(@as(?[]const u8, null), try appendWrappedCjsNamedEntryExports(std.testing.allocator, "body;", "namespace", &.{}, "__defProp"));
}

test "preserved CJS public keys use one StringValue decoding pass" {
    const keys = @import("../public_export_key.zig");
    const cases = [_]struct { syntax: []const u8, value: []const u8 }{
        .{ .syntax = "init_provider", .value = "init_provider" },
        .{ .syntax = "\"init_provider\"", .value = "init_provider" },
        .{ .syntax = "\"\\u0069nit_provider\"", .value = "init_provider" },
        .{ .syntax = "\"\\\\u0069nit_provider\"", .value = "\\u0069nit_provider" },
        .{ .syntax = "\"\\\"init_provider\\\"\"", .value = "\"init_provider\"" },
        .{ .syntax = "\"\\xE9\"", .value = "é" },
        .{ .syntax = "\"\\uD83D\\uDE00\"", .value = "😀" },
        .{ .syntax = "\"\\u{1F600}\"", .value = "😀" },
        .{ .syntax = "\"i\\\xe2\x80\xa8nit_provider\"", .value = "init_provider" },
    };
    for (cases) |case| {
        const key = try keys.fromSyntax(std.testing.allocator, case.syntax);
        defer key.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings(case.value, key.text);
    }
    try std.testing.expectError(error.InvalidPublicExportName, keys.fromSyntax(std.testing.allocator, "\"\\uD800\""));
}

fn checkOrdinaryQuotedExportAllocation(allocator: std.mem.Allocator) !void {
    const entries = [_]FinalExportEntry{
        .{ .local = "known_local", .exported = "\"\\\\u0061\"", .public_key_literal = "\"\\\\u0061\"" },
        .{ .local = "other_local", .exported = "\"한글\"", .public_key_literal = "\"한글\"" },
    };
    const emitted = try emitCjsEntryExports(allocator, &entries, .named, null, "__defProp");
    defer allocator.free(emitted);
    try std.testing.expectEqualStrings("__defProp(exports,\"\\\\u0061\",{enumerable:true,get:function(){return known_local;}});\n__defProp(exports,\"한글\",{enumerable:true,get:function(){return other_local;}});\n", emitted);
}

test "quoted ordinary CJS export writers preserve certified StringValue and allocation ownership" {
    try checkOrdinaryQuotedExportAllocation(std.testing.allocator);
    try std.testing.checkAllAllocationFailures(std.testing.allocator, checkOrdinaryQuotedExportAllocation, .{});
}

test "ready marker demand follows decoded final public keys and actual output role" {
    const a = std.testing.allocator;
    const quoted_default = [_]FinalExportEntry{.{ .local = "value", .exported = "\"default\"", .public_key_literal = "\"default\"" }};
    try std.testing.expect(try readyNamespaceNeedsMarker(a, &quoted_default, true, .named));
    try std.testing.expect(!try readyNamespaceNeedsMarker(a, &quoted_default, true, .auto));
    try std.testing.expect(!try readyNamespaceNeedsMarker(a, &quoted_default, true, .none));
    try std.testing.expect(!try readyNamespaceNeedsMarker(a, &quoted_default, false, .named));
    const public_marker = [_]FinalExportEntry{
        quoted_default[0],
        .{ .local = "source_marker", .exported = "\"__esModule\"", .public_key_literal = "\"__esModule\"" },
    };
    try std.testing.expect(!try readyNamespaceNeedsMarker(a, &public_marker, true, .named));
}

const public_entry_observation = "const before=ns.value;ns.update();console.log(JSON.stringify({before,after:ns.value,proto:ns['__proto__'],own:Object.prototype.hasOwnProperty.call(ns,'__proto__'),keys:Object.keys(ns).sort(),result:typeof ns.default==='function'?ns.default():ns.default}));";

test "public entry getters retain ESM live values and own proto keys across library formats" {
    const Bundler = @import("../bundler.zig").Bundler;
    const helpers = @import("../test_helpers.zig");
    const Format = @import("../types.zig").Format;
    const Target = @import("../../transformer/compat.zig").ESTarget;
    const sources = [_][]const u8{
        "export let value=1;export function update(){value++}const proto='own';export{proto as '__proto__'};export default 42;",
        "const Object={tag:'object'},exports={tag:'exports'},module={tag:'module'},__defProp={tag:'helper'};export let value=1;export function update(){value++}const proto='own';export{proto as '__proto__'};export default function read(){return [Object.tag,exports.tag,module.tag,__defProp.tag,value]}",
    };
    for (sources) |source| for ([_]Format{ .cjs, .iife, .umd }) |format| for ([_]Target{ .es5, .esnext }) |target| for ([_]bool{ false, true }) |minify| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try helpers.writeFile(tmp.dir, "entry.mjs", source);
        const entry = try helpers.absPath(&tmp, "entry.mjs");
        defer std.testing.allocator.free(entry);
        const uri = try std.fmt.allocPrint(a, "file://{s}", .{entry});
        const quoted_uri = try std.json.Stringify.valueAlloc(a, uri, .{});
        const native_script = try std.mem.concat(a, u8, &.{ "const ns=await import(", quoted_uri, ");", public_entry_observation });
        const native = try std.process.run(a, std.testing.io, .{ .argv = &.{ "node", "--input-type=module", "-e", native_script } });
        try std.testing.expect(native.term == .exited and native.term.exited == 0);
        var bundler = Bundler.init(std.testing.allocator, .{
            .entry_points = &.{entry},
            .platform = .node,
            .format = format,
            .global_name = if (format == .cjs) null else "PublicEntry",
            .unsupported = @import("../../transformer/compat.zig").fromESTarget(target),
            .minify_identifiers = minify,
            .minify_syntax = minify,
            .minify_whitespace = minify,
        });
        defer bundler.deinit();
        const result = try bundler.bundle(std.testing.io);
        defer result.deinit(std.testing.allocator);
        try std.testing.expect(!result.hasErrors());
        try helpers.writeFile(tmp.dir, "output.cjs", result.output);
        const output = try helpers.absPath(&tmp, "output.cjs");
        defer std.testing.allocator.free(output);
        const quoted_output = try std.json.Stringify.valueAlloc(a, output, .{});
        const load = if (format == .iife)
            try std.mem.concat(a, u8, &.{ "const ctx={};require('vm').runInNewContext(require('fs').readFileSync(", quoted_output, ",'utf8'),ctx);const ns=ctx.PublicEntry;" })
        else
            try std.mem.concat(a, u8, &.{ "const ns=require(", quoted_output, ");" });
        const actual = try std.process.run(a, std.testing.io, .{ .argv = &.{ "node", "-e", try std.mem.concat(a, u8, &.{ load, public_entry_observation }) } });
        if (actual.term != .exited or actual.term.exited != 0 or !std.mem.eql(u8, native.stdout, actual.stdout))
            std.debug.print("public entry format={s} target={s} minify={} native={s} actual={s} stderr={s}\n", .{ @tagName(format), @tagName(target), minify, native.stdout, actual.stdout, actual.stderr });
        try std.testing.expect(actual.term == .exited and actual.term.exited == 0);
        try std.testing.expectEqualStrings("", actual.stderr);
        try std.testing.expectEqualStrings(native.stdout, actual.stdout);
    };
}

test "public entry auto mixed preserves wrapped PM namespace and transport" {
    const Bundler = @import("../bundler.zig").Bundler;
    const helpers = @import("../test_helpers.zig");
    const Target = @import("../../transformer/compat.zig").ESTarget;
    for ([_]Target{ .es5, .esnext }) |target| for ([_]bool{ false, true }) |minify| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try helpers.writeFile(tmp.dir, "entry.mjs", "import{value}from'./dep.mjs';export{value as 'x-y'};export default()=>value();");
        try helpers.writeFile(tmp.dir, "dep.mjs", "export function value(){return 42}");
        const entry = try helpers.absPath(&tmp, "entry.mjs");
        defer std.testing.allocator.free(entry);
        const uri = try std.json.Stringify.valueAlloc(a, try std.fmt.allocPrint(a, "file://{s}", .{entry}), .{});
        const observe = "console.log(JSON.stringify({keys:Object.keys(ns).filter(k=>k==='default'||k==='x-y').sort(),values:[ns['x-y'](),ns.default()]}));";
        const native = try std.process.run(a, std.testing.io, .{ .argv = &.{ "node", "--input-type=module", "-e", try std.mem.concat(a, u8, &.{ "const ns=await import(", uri, ");", observe }) } });
        try std.testing.expect(native.term == .exited and native.term.exited == 0);
        var bundler = Bundler.init(std.testing.allocator, .{
            .entry_points = &.{entry},
            .platform = .react_native,
            .format = .cjs,
            .code_splitting = true,
            .preserve_modules = true,
            .preserve_modules_root = std.fs.path.dirname(entry),
            .strict_execution_order = true,
            .output_exports = .auto,
            .unsupported = @import("../../transformer/compat.zig").fromESTarget(target),
            .minify_identifiers = minify,
            .minify_syntax = minify,
            .minify_whitespace = minify,
        });
        defer bundler.deinit();
        const result = try bundler.bundle(std.testing.io);
        defer result.deinit(std.testing.allocator);
        try std.testing.expect(!result.hasErrors());
        for (result.outputs.?) |file| try helpers.writeFile(tmp.dir, std.fs.path.basename(file.path), file.contents);
        const output = try helpers.absPath(&tmp, "entry.js");
        defer std.testing.allocator.free(output);
        const quoted = try std.json.Stringify.valueAlloc(a, output, .{});
        const actual = try std.process.run(a, std.testing.io, .{ .argv = &.{ "node", "-e", try std.mem.concat(a, u8, &.{ "const ns=require(", quoted, ");if(typeof ns.init_entry!=='function'||typeof ns.exports_entry!=='object')throw new Error('lost PM transport');", observe }) } });
        if (actual.term != .exited or actual.term.exited != 0 or !std.mem.eql(u8, native.stdout, actual.stdout)) {
            std.debug.print("public PM target={s} minify={} native={s} actual={s} stderr={s}\n", .{ @tagName(target), minify, native.stdout, actual.stdout, actual.stderr });
            for (result.outputs.?) |file| std.debug.print("public PM output {s}:\n{s}\n", .{ file.path, file.contents });
        }
        try std.testing.expect(actual.term == .exited and actual.term.exited == 0);
        try std.testing.expectEqualStrings("", actual.stderr);
        try std.testing.expectEqualStrings(native.stdout, actual.stdout);
    };
}

test "public entry raw CJS keeps its writable snapshot contract" {
    const Bundler = @import("../bundler.zig").Bundler;
    const helpers = @import("../test_helpers.zig");
    for ([_]bool{ false, true }) |minify| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try helpers.writeFile(tmp.dir, "entry.cjs", "module.exports={value:1};");
        const entry = try helpers.absPath(&tmp, "entry.cjs");
        defer std.testing.allocator.free(entry);
        var bundler = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry}, .platform = .node, .format = .cjs, .minify_identifiers = minify, .minify_syntax = minify, .minify_whitespace = minify });
        defer bundler.deinit();
        const result = try bundler.bundle(std.testing.io);
        defer result.deinit(std.testing.allocator);
        try std.testing.expect(!result.hasErrors());
        try helpers.writeFile(tmp.dir, "output.cjs", result.output);
        const output = try helpers.absPath(&tmp, "output.cjs");
        defer std.testing.allocator.free(output);
        const quoted = try std.json.Stringify.valueAlloc(std.testing.allocator, output, .{});
        defer std.testing.allocator.free(quoted);
        const script = try std.fmt.allocPrint(std.testing.allocator, "const ns=require({s});const d=Object.getOwnPropertyDescriptor(ns,'value');ns.value=42;console.log(JSON.stringify([ns.value,d.writable,Object.keys(ns)]));", .{quoted});
        defer std.testing.allocator.free(script);
        const actual = try std.process.run(std.testing.allocator, std.testing.io, .{ .argv = &.{ "node", "-e", script } });
        defer std.testing.allocator.free(actual.stdout);
        defer std.testing.allocator.free(actual.stderr);
        try std.testing.expect(actual.term == .exited and actual.term.exited == 0);
        try std.testing.expectEqualStrings("[42,true,[\"value\"]]\n", actual.stdout);
    }
}

test "public entry descriptor demand preserves quoted default and explicit marker ownership" {
    const a = std.testing.allocator;
    const only_default = [_]FinalExportEntry{.{ .local = "answer", .exported = "'default'", .public_key_literal = "'default'" }};
    try std.testing.expect(!try needsCjsEntryDescriptors(a, &only_default, .auto));
    const scalar = try emitCjsEntryExports(a, &only_default, .auto, null, null);
    defer a.free(scalar);
    try std.testing.expectEqualStrings("module.exports = answer;\n", scalar);
    const named = [_]FinalExportEntry{.{ .local = "answer", .exported = "value" }};
    try std.testing.expectError(error.MissingCjsEntryDescriptorIdentity, emitCjsEntryExports(a, &named, .auto, null, null));
    const explicit_marker = [_]FinalExportEntry{
        only_default[0],
        .{ .local = "user_marker", .exported = "'__esModule'", .public_key_literal = "'__esModule'" },
    };
    const emitted = try emitCjsEntryExports(a, &explicit_marker, .auto, null, "owned_def_prop");
    defer a.free(emitted);
    try std.testing.expect(std.mem.indexOf(u8, emitted, "return user_marker;") != null);
    try std.testing.expect(std.mem.indexOf(u8, emitted, "{value:true}") == null);
    try std.testing.expect(std.mem.indexOf(u8, emitted, "Object.defineProperty") == null);
}
