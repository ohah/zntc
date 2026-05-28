//! CJS 래퍼 (__commonJS) — Asset/Disabled 모듈용 팩토리 함수 emit.
//!
//! 일반 CJS 번들(module.wrap_kind == .cjs)의 __commonJS 래핑은 emitter.zig의
//! emitModule이 직접 생성한다. 이 파일은 source가 이미 값 표현식 형태인 특수
//! 케이스를 담당: asset (file/copy 로더) + disabled (browser 빌드의 Node 빌트인).

const std = @import("std");
const rt = @import("../runtime_helpers.zig");
const module_mod = @import("../module.zig");
const Module = module_mod.Module;
const EmitOptions = @import("../emitter.zig").EmitOptions;

/// Disabled 모듈: platform=browser에서 Node 빌트인 모듈을 빈 __commonJS wrapper로 출력.
/// wrapper key는 dev/HMR registry 조회와 일치해야 하므로 module.wrapperId()를 쓴다.
pub fn emitDisabledModule(allocator: std.mem.Allocator, module: *const Module, minify: bool) !?[]const u8 {
    // RFC #3940 L.4c-2a-i: free fn (linker 없음) → rt null, canonical field 경로 (parity 로 동치).
    const var_name = try module.allocRequireName(allocator, null);
    defer allocator.free(var_name);
    const wrapper_id = module.wrapperId();

    var buf: std.ArrayList(u8) = .empty;
    if (module.disabled_throw_on_require) {
        const specifier = optionalMissingSpecifier(module);
        if (minify) {
            try buf.appendSlice(allocator, "var ");
            try buf.appendSlice(allocator, var_name);
            // body 가 throw 만 — exports/module 참조 없음 → param 인자 0개.
            try buf.appendSlice(allocator, "=" ++ rt.NAMES.CJS_FACTORY_MIN ++ "(()=>{");
            try appendOptionalMissingThrow(allocator, &buf, specifier, true);
            try buf.appendSlice(allocator, "});");
        } else {
            try buf.writer(allocator).print("var {s} = __commonJS({{\n\t\"{s}\"(exports, module) {{\n\t\t", .{ var_name, wrapper_id });
            try appendOptionalMissingThrow(allocator, &buf, specifier, false);
            try buf.appendSlice(allocator, "\t}\n});\n");
        }
        return try buf.toOwnedSlice(allocator);
    }

    if (minify) {
        try buf.appendSlice(allocator, "var ");
        try buf.appendSlice(allocator, var_name);
        // #1621: minify 시 __commonJS → $cj 축약. 빈 body — param 0개.
        try buf.appendSlice(allocator, "=" ++ rt.NAMES.CJS_FACTORY_MIN ++ "(()=>{});");
    } else {
        try buf.writer(allocator).print("var {s} = __commonJS({{\n\t\"{s}\"(exports, module) {{\n\t}}\n}});\n", .{ var_name, wrapper_id });
    }
    return try buf.toOwnedSlice(allocator);
}

fn optionalMissingSpecifier(module: *const Module) []const u8 {
    if (std.mem.startsWith(u8, module.path, module_mod.OPTIONAL_MISSING_MODULE_PREFIX)) {
        return module.path[module_mod.OPTIONAL_MISSING_MODULE_PREFIX.len..];
    }
    return module.path;
}

fn appendOptionalMissingThrow(
    allocator: std.mem.Allocator,
    buf: *std.ArrayList(u8),
    specifier: []const u8,
    minify: bool,
) !void {
    if (minify) {
        try buf.appendSlice(allocator, "var e=new Error(\"Cannot find module \\\"\"+");
        try appendJsStringLiteral(allocator, buf, specifier);
        try buf.appendSlice(allocator, "+\"\\\"\");e.code=\"MODULE_NOT_FOUND\";throw e;");
        return;
    }

    try buf.appendSlice(allocator, "var e = new Error(\"Cannot find module \\\"\" + ");
    try appendJsStringLiteral(allocator, buf, specifier);
    try buf.appendSlice(allocator, " + \"\\\"\");\n\t\te.code = \"MODULE_NOT_FOUND\";\n\t\tthrow e;\n");
}

pub fn appendJsStringLiteral(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), value: []const u8) !void {
    const hex = "0123456789abcdef";
    try buf.append(allocator, '"');
    for (value) |c| {
        switch (c) {
            '\\' => try buf.appendSlice(allocator, "\\\\"),
            '"' => try buf.appendSlice(allocator, "\\\""),
            '\n' => try buf.appendSlice(allocator, "\\n"),
            '\r' => try buf.appendSlice(allocator, "\\r"),
            '\t' => try buf.appendSlice(allocator, "\\t"),
            else => {
                if (c < 0x20) {
                    try buf.appendSlice(allocator, "\\u00");
                    try buf.append(allocator, hex[c >> 4]);
                    try buf.append(allocator, hex[c & 0x0f]);
                } else {
                    try buf.append(allocator, c);
                }
            },
        }
    }
    try buf.append(allocator, '"');
}

/// Asset 모듈(file/copy 로더)을 CJS wrap 패턴으로 출력. source엔 값 표현식이 저장됨.
/// linker가 `require_X()` 호출을 생성하므로, 모든 포맷에서 CJS 패턴을 사용.
pub fn emitAssetModule(allocator: std.mem.Allocator, module: *const Module, options: *const EmitOptions) !?[]const u8 {
    if (module.source.len == 0) return null;
    return emitCjsWrapper(allocator, module, module.source, options.minify_whitespace);
}

/// `var require_X = __commonJS({ "filename"(exports, module) { module.exports = <source>; } });`
/// 형태의 __commonJS wrapper를 생성.
pub fn emitCjsWrapper(allocator: std.mem.Allocator, module: *const Module, source: []const u8, minify: bool) !?[]const u8 {
    // RFC #3940 L.4c-2a-i: free fn (linker 없음) → rt null, canonical field 경로 (parity 로 동치).
    const var_name = try module.allocRequireName(allocator, null);
    defer allocator.free(var_name);

    var buf: std.ArrayList(u8) = .empty;
    if (minify) {
        try buf.appendSlice(allocator, "var ");
        try buf.appendSlice(allocator, var_name);
        // #1621: minify 시 __commonJS → $cj 축약. callback parameter 는 Node/Metro
        // 호환성을 위해 `exports, module` 유지.
        try buf.appendSlice(allocator, "=" ++ rt.NAMES.CJS_FACTORY_MIN ++ "((exports,module)=>{module.exports=");
        try buf.appendSlice(allocator, source);
        try buf.appendSlice(allocator, "});");
    } else {
        try buf.appendSlice(allocator, "var ");
        try buf.appendSlice(allocator, var_name);
        try buf.appendSlice(allocator, " = __commonJS({\n\t\"");
        try buf.appendSlice(allocator, std.fs.path.basename(module.path));
        try buf.appendSlice(allocator, "\"(exports, module) {\nmodule.exports=");
        try buf.appendSlice(allocator, source);
        try buf.appendSlice(allocator, ";\n\t}\n});\n");
    }
    return try buf.toOwnedSlice(allocator);
}
