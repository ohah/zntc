//! CJS 래퍼 (__commonJS) — Asset/Disabled 모듈용 팩토리 함수 emit.
//!
//! 일반 CJS 번들(module.wrap_kind == .cjs)의 __commonJS 래핑은 emitter.zig의
//! emitModule이 직접 생성한다. 이 파일은 source가 이미 값 표현식 형태인 특수
//! 케이스를 담당: asset (file/copy 로더) + disabled (browser 빌드의 Node 빌트인).

const std = @import("std");
const types = @import("../types.zig");
const rt = @import("../runtime_helpers.zig");
const Module = @import("../module.zig").Module;
const EmitOptions = @import("../emitter.zig").EmitOptions;

/// Disabled 모듈: platform=browser에서 Node 빌트인 모듈을 빈 __commonJS wrapper로 출력.
/// esbuild 호환 형식: `var require_util = __commonJS({ "(disabled)"(exports, module) {} });`
pub fn emitDisabledModule(allocator: std.mem.Allocator, module: *const Module, minify: bool) !?[]const u8 {
    const var_name = try types.makeRequireVarName(allocator, module.path);
    defer allocator.free(var_name);

    var buf: std.ArrayList(u8) = .empty;
    if (minify) {
        try buf.appendSlice(allocator, "var ");
        try buf.appendSlice(allocator, var_name);
        // #1621: minify 시 __commonJS → $cj 축약 (#1618 follow-up).
        try buf.appendSlice(allocator, "=" ++ rt.NAMES.CJS_FACTORY_MIN ++ "({\"(disabled)\"(exports,module){}});");
    } else {
        try buf.appendSlice(allocator, "var ");
        try buf.appendSlice(allocator, var_name);
        try buf.appendSlice(allocator, " = __commonJS({\n\t\"(disabled)\"(exports, module) {\n\t}\n});\n");
    }
    return try buf.toOwnedSlice(allocator);
}

/// Asset 모듈(file/copy 로더)을 CJS wrap 패턴으로 출력. source엔 값 표현식이 저장됨.
/// linker가 `require_X()` 호출을 생성하므로, 모든 포맷에서 CJS 패턴을 사용.
pub fn emitAssetModule(allocator: std.mem.Allocator, module: *const Module, options: *const EmitOptions) !?[]const u8 {
    if (module.source.len == 0) return null;
    return emitCjsWrapper(allocator, module.path, module.source, options.minify_whitespace);
}

/// `var require_X = __commonJS({ "filename"(exports, module) { module.exports = <source>; } });`
/// 형태의 __commonJS wrapper를 생성.
pub fn emitCjsWrapper(allocator: std.mem.Allocator, path: []const u8, source: []const u8, minify: bool) !?[]const u8 {
    const var_name = try types.makeRequireVarName(allocator, path);
    defer allocator.free(var_name);

    var buf: std.ArrayList(u8) = .empty;
    if (minify) {
        try buf.appendSlice(allocator, "var ");
        try buf.appendSlice(allocator, var_name);
        // #1621: minify 시 __commonJS → $cj 축약 (#1618 follow-up).
        try buf.appendSlice(allocator, "=" ++ rt.NAMES.CJS_FACTORY_MIN ++ "({\"");
        try buf.appendSlice(allocator, std.fs.path.basename(path));
        try buf.appendSlice(allocator, "\"(exports,module){module.exports=");
        try buf.appendSlice(allocator, source);
        try buf.appendSlice(allocator, "}});");
    } else {
        try buf.appendSlice(allocator, "var ");
        try buf.appendSlice(allocator, var_name);
        try buf.appendSlice(allocator, " = __commonJS({\n\t\"");
        try buf.appendSlice(allocator, std.fs.path.basename(path));
        try buf.appendSlice(allocator, "\"(exports, module) {\nmodule.exports=");
        try buf.appendSlice(allocator, source);
        try buf.appendSlice(allocator, ";\n\t}\n});\n");
    }
    return try buf.toOwnedSlice(allocator);
}
