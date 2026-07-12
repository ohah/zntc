//! JSON Schema 생성기 — `TranspileOptionsDto`의 comptime `@typeInfo`를 반사해
//! JSON Schema Draft-07을 emit한다. build.zig의 `schema` step에서 실행.
//!
//! 단일 진실의 소스 = Zig struct. enum 허용값은 `@typeInfo(T).@"enum".fields`
//! 로 자동 수집하므로 수동 매핑 없음. 필드를 바꾸면 schema가 자동 갱신.

const std = @import("std");
const TranspileOptionsDto = @import("zntc_lib").transpile.TranspileOptionsDto;

/// 필드별 사용자용 설명. Zig comptime에 남길 수 없는 자연어 텍스트라 별도 정의.
/// 키는 DTO 필드명과 정확히 일치. CI에서 누락 검증 권장.
const field_docs = std.StaticStringMap([]const u8).initComptime(.{
    .{ "target", "ES downlevel target. Unset = esnext (no feature lowering)." },
    .{ "unsupported", "Direct unsupported feature bitmask (browserslist override). Takes precedence over `target`." },
    .{ "flow", "Enable Flow type stripping." },
    .{ "jsxInJs", "Allow JSX in `.js`/`.jsx` files (not just `.tsx`)." },
    .{ "jsx", "JSX runtime. `classic` = React.createElement, `automatic` = jsx-runtime import." },
    .{ "jsxFactory", "Classic-mode JSX factory (default: React.createElement)." },
    .{ "jsxFragment", "Classic-mode Fragment factory (default: React.Fragment)." },
    .{ "jsxImportSource", "Automatic-mode import source (default: react)." },
    .{ "dropConsole", "Remove `console.*` calls." },
    .{ "dropDebugger", "Remove `debugger` statements." },
    .{ "asciiOnly", "Escape non-ASCII characters as hex escape sequences." },
    .{ "charsetUtf8", "Preserve non-ASCII characters verbatim." },
    .{ "experimentalDecorators", "Legacy TC39 stage-1 decorators." },
    .{ "emitDecoratorMetadata", "Emit decorator metadata (requires experimentalDecorators)." },
    .{ "useDefineForClassFields", "Use `[[Define]]` semantics for class fields (default: true)." },
    .{ "format", "Module format for the output." },
    .{ "quotes", "Preferred string quote style." },
    .{ "platform", "Target platform — affects built-in externals and Node polyfills." },
    .{ "minifyWhitespace", "Remove whitespace." },
    .{ "minifyIdentifiers", "Mangle local identifiers." },
    .{ "minifySyntax", "Apply syntax-level minification." },
    .{ "sourcemap", "Generate sourcemap JSON." },
    .{ "sourcemapDebugIds", "Embed Sentry-compatible Debug IDs." },
    .{ "sourcesContent", "Include original source in sourcemap (default: true)." },
    .{ "sourceRoot", "SourceMap `sourceRoot` field." },
    .{ "define", "Define list: `{ key, value }` pairs. `value` is raw JSON (strings must include quotes)." },
    .{ "assetInlineLimit", "Inline assets at or below this size (bytes) as data URLs instead of emitting files. 0 disables inlining (default: 4096)." },
});

/// DTO의 모든 필드를 순회하며 `"properties": {...}` 내부를 생성.
/// 각 필드는 optional이므로 `null`을 허용하는 타입 unwrap 후 실제 타입으로 schema emit.
fn writeProperties(writer: anytype) !void {
    const fields = @typeInfo(TranspileOptionsDto).@"struct".fields;
    inline for (fields, 0..) |field, i| {
        if (i > 0) try writer.writeAll(",");
        try writer.print("\n    \"{s}\": ", .{field.name});
        const inner_type = @typeInfo(field.type).optional.child;
        try writeTypeSchema(writer, inner_type, field.name);
    }
}

/// 주어진 Zig 타입에 해당하는 JSON schema 객체를 emit.
/// 재귀적으로 호출되며 bool/int/string/enum/slice를 모두 처리.
fn writeTypeSchema(writer: anytype, comptime T: type, comptime field_name: []const u8) !void {
    try writer.writeAll("{");

    switch (@typeInfo(T)) {
        .bool => try writer.writeAll("\"type\": \"boolean\""),
        .int => |info| {
            try writer.print("\"type\": \"integer\", \"minimum\": {d}, \"maximum\": {d}", .{
                std.math.minInt(T),
                std.math.maxInt(T),
            });
            _ = info;
        },
        .@"enum" => |info| {
            try writer.writeAll("\"type\": \"string\", \"enum\": [");
            inline for (info.fields, 0..) |ef, i| {
                if (i > 0) try writer.writeAll(", ");
                try writer.print("\"{s}\"", .{ef.name});
            }
            try writer.writeAll("]");
        },
        .pointer => |info| {
            // `[]const u8` = string
            if (info.size == .slice and info.child == u8) {
                try writer.writeAll("\"type\": \"string\"");
            } else if (info.size == .slice) {
                // Slice values (e.g. `[]const DefineEntry`, `[]const []const u8`) → array.
                try writer.writeAll("\"type\": \"array\", \"items\": ");
                switch (@typeInfo(info.child)) {
                    .@"struct" => try writeStructSchema(writer, info.child),
                    else => try writeTypeSchema(writer, info.child, ""),
                }
            } else {
                try writer.writeAll("\"type\": \"null\"");
            }
        },
        .@"struct" => try writeStructSchema(writer, T),
        else => try writer.writeAll("\"type\": \"null\""),
    }

    // 필드 설명 주입 (top-level 필드에만).
    if (field_docs.get(field_name)) |doc| {
        try writer.print(", \"description\": \"{s}\"", .{doc});
    }

    try writer.writeAll("}");
}

fn writeStructSchema(writer: anytype, comptime T: type) !void {
    try writer.writeAll("{\"type\": \"object\", \"properties\": {");
    const fields = @typeInfo(T).@"struct".fields;
    inline for (fields, 0..) |field, i| {
        if (i > 0) try writer.writeAll(", ");
        try writer.print("\"{s}\": ", .{field.name});
        const inner = if (@typeInfo(field.type) == .optional) @typeInfo(field.type).optional.child else field.type;
        try writeTypeSchema(writer, inner, "");
    }
    try writer.writeAll("}, \"additionalProperties\": false}");
}

pub fn main(init: std.process.Init) !void {
    // 0.16: juicy main — io / args 를 Init 에서. GPA→DebugAllocator, argsAlloc 제거.
    const io = init.io;
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var arg_it = try std.process.Args.Iterator.initAllocator(init.minimal.args, alloc);
    defer arg_it.deinit();
    var args_buf: std.ArrayList([]const u8) = .empty;
    defer args_buf.deinit(alloc);
    while (arg_it.next()) |a| try args_buf.append(alloc, a);
    const args = args_buf.items;
    if (args.len < 2) {
        std.debug.print("usage: emit_schema <output-path>\n", .{});
        std.process.exit(1);
    }
    const out_path = args[1];

    // 0.16: ArrayList.writer 제거 → Io.Writer.Allocating (writeProperties 가 *Io.Writer 받음).
    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    const writer = &aw.writer;

    try writer.writeAll(
        \\{
        \\  "$schema": "http://json-schema.org/draft-07/schema#",
        \\  "$id": "https://ohah.github.io/zntc/schemas/transpile-options.schema.json",
        \\  "title": "ZNTC Transpile Options",
        \\  "description": "Options for the ZNTC transpiler. Generated from Zig `TranspileOptionsDto` — edit src/transpile/options.zig and run `zig build schema` to regenerate.",
        \\  "type": "object",
        \\  "additionalProperties": false,
        \\  "properties": {
    );
    try writeProperties(writer);
    try writer.writeAll("\n  }\n}\n");

    const schema_bytes = aw.writer.buffered();
    // 출력 경로의 부모 디렉토리 생성 (schemas/가 아직 없을 수 있음).
    // 0.16: std.fs.cwd 제거 → Io.Dir.cwd + io; makePath→createDirPath.
    if (std.fs.path.dirname(out_path)) |dir| {
        std.Io.Dir.cwd().createDirPath(io, dir) catch {};
    }
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = out_path, .data = schema_bytes });
    std.debug.print("wrote {s} ({d} bytes)\n", .{ out_path, schema_bytes.len });
}
