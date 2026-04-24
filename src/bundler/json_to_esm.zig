//! JSON → ESM AST 변환기
//!
//! JSON 텍스트를 `export default <value>;` 형태의 ESM AST로 변환한다.
//! 파서를 거치지 않고 AST 노드를 직접 생성하여, 일반 JS 모듈과 동일한
//! 파이프라인(semantic → import_scanner → binding_scanner → emitter)을 탄다.
//!
//! 원본 JSON 텍스트의 span을 그대로 사용하므로 소스맵도 정확하다.

const std = @import("std");
const ast_mod = @import("../parser/ast.zig");
const Ast = ast_mod.Ast;
const Node = ast_mod.Node;
const NodeIndex = ast_mod.NodeIndex;
const Span = @import("../lexer/token.zig").Span;
const unicode = @import("../lexer/unicode.zig");

/// JSON 텍스트를 ESM AST로 변환한다.
/// 결과 AST는 `export default <json_value>;` 한 문(statement)으로 구성.
///
/// allocator: AST 내부 ArrayList용 할당자 (parse_arena.allocator())
/// source: JSON 원본 텍스트 (AST.source로 설정, span이 직접 참조)
pub fn convert(allocator: std.mem.Allocator, source: []const u8) !Ast {
    var ast = Ast.init(allocator, source);

    var pos: u32 = 0;
    const value_node = try convertValue(&ast, source, &pos);

    // export default <value>;
    const export_default = try ast.addNode(.{
        .tag = .export_default_declaration,
        .span = .{ .start = 0, .end = @intCast(source.len) },
        .data = .{ .unary = .{ .operand = value_node, .flags = 0 } },
    });

    // 최상위 JSON 객체의 키를 named export로 추가 (esbuild/Node.js 호환)
    var extra_stmts: std.ArrayListUnmanaged(NodeIndex) = .empty;
    defer extra_stmts.deinit(allocator);
    try buildNamedExportsFromObject(&ast, value_node, &extra_stmts);

    // program (최상위 노드, 항상 마지막)
    var stmts: std.ArrayListUnmanaged(NodeIndex) = .empty;
    defer stmts.deinit(allocator);
    try stmts.append(allocator, export_default);
    try stmts.appendSlice(allocator, extra_stmts.items);
    const list = try ast.addNodeList(stmts.items);
    _ = try ast.addNode(.{
        .tag = .program,
        .span = .{ .start = 0, .end = @intCast(source.len) },
        .data = .{ .list = list },
    });

    return ast;
}

/// 최상위 JSON 값이 object_expression이면, 각 키에 대해
/// `export var <key> = <value>;` 를 생성한다 (esbuild/Node.js JSON named export 호환).
/// export_named_declaration + variable_declaration 조합이라 linker가 skip하지 않고
/// codegen이 `var <key> = <value>;` (export 키워드 생략)로 정상 출력한다.
fn buildNamedExportsFromObject(ast: *Ast, value_node: NodeIndex, out_stmts: *std.ArrayListUnmanaged(NodeIndex)) !void {
    const node = ast.getNode(value_node);
    if (node.tag != .object_expression) return;
    if (node.data.list.len == 0) return;

    var i: u32 = 0;
    while (i < node.data.list.len) : (i += 1) {
        const prop_idx: NodeIndex = @enumFromInt(ast.extra_data.items[node.data.list.start + i]);
        const prop = ast.getNode(prop_idx);
        if (prop.tag != .object_property) continue;

        const key_node = ast.getNode(prop.data.binary.left);
        if (key_node.tag != .string_literal) continue;

        const key_span = key_node.span;
        // JSON은 파서가 읽은 원문이라 합성 노드 아님 — string_table 참조일 수 없음.
        // getText 경유 후 quote strip.
        const key_raw = ast.getText(key_span);
        if (key_raw.len < 2) continue;
        const key_text = key_raw[1 .. key_raw.len - 1];
        if (!isValidIdentifier(key_text)) continue;

        const inner_span = Span{ .start = key_span.start + 1, .end = key_span.end - 1 };

        // 값 노드 복사 (object property와 공유하면 transformer에서 인덱스 불일치)
        const orig_value = ast.getNode(prop.data.binary.right);
        const value_copy = try ast.addNode(.{
            .tag = orig_value.tag,
            .span = orig_value.span,
            .data = orig_value.data,
        });

        const binding_ident = try ast.addNode(.{
            .tag = .binding_identifier,
            .span = inner_span,
            .data = .{ .string_ref = inner_span },
        });
        const declarator_extra = try ast.addExtras(&.{
            @intFromEnum(binding_ident),
            @intFromEnum(NodeIndex.none),
            @intFromEnum(value_copy),
        });
        const declarator = try ast.addNode(.{
            .tag = .variable_declarator,
            .span = .{ .start = inner_span.start, .end = orig_value.span.end },
            .data = .{ .extra = declarator_extra },
        });

        const decl_list = try ast.addNodeList(&.{declarator});
        const var_extra = try ast.addExtras(&.{ 0, decl_list.start, decl_list.len });
        const var_decl = try ast.addNode(.{
            .tag = .variable_declaration,
            .span = .{ .start = inner_span.start, .end = orig_value.span.end },
            .data = .{ .extra = var_extra },
        });

        // extras: [declaration, specifiers_start, specifiers_len, source, attrs_start, attrs_len]
        const none_node: u32 = @intFromEnum(NodeIndex.none);
        const export_extra = try ast.addExtras(&.{
            @intFromEnum(var_decl),
            0,         0, // specifiers empty
            none_node,
            0, 0, // attrs empty
        });
        const export_node = try ast.addNode(.{
            .tag = .export_named_declaration,
            .span = .{ .start = inner_span.start, .end = orig_value.span.end },
            .data = .{ .extra = export_extra },
        });
        try out_stmts.append(ast.allocator, export_node);
    }
}

/// JSON 키가 JS named export 식별자로 사용 가능한지 확인.
/// ASCII 범위만 지원 (JSON 이스케이프 키는 보수적으로 제외).
fn isValidIdentifier(s: []const u8) bool {
    if (s.len == 0) return false;
    if (!unicode.isIdentifierStart(s[0])) return false;
    for (s[1..]) |c| {
        if (!unicode.isIdentifierContinue(c)) return false;
    }
    // JS 예약어는 named export 변수명으로 사용 불가
    return !isJsReservedWord(s);
}

fn isJsReservedWord(s: []const u8) bool {
    const reserved = [_][]const u8{
        "break",     "case",       "catch",    "class",     "const",
        "continue",  "debugger",   "default",  "delete",    "do",
        "else",      "enum",       "export",   "extends",   "false",
        "finally",   "for",        "function", "if",        "import",
        "in",        "instanceof", "new",      "null",      "return",
        "super",     "switch",     "this",     "throw",     "true",
        "try",       "typeof",     "var",      "void",      "while",
        "with",      "yield",      "let",      "static",    "implements",
        "interface", "package",    "private",  "protected", "public",
    };
    for (reserved) |kw| {
        if (std.mem.eql(u8, s, kw)) return true;
    }
    return false;
}

/// JSON 변환 에러.
pub const ConvertError = error{
    UnexpectedEndOfInput,
    InvalidJsonValue,
    ExpectedString,
    UnterminatedString,
    InvalidBoolean,
    InvalidNull,
    ExpectedColon,
    UnterminatedObject,
    ExpectedCommaOrBrace,
    UnterminatedArray,
    ExpectedCommaOrBracket,
    OutOfMemory,
};

/// JSON 값을 재귀적으로 AST 노드로 변환한다.
fn convertValue(ast: *Ast, source: []const u8, pos: *u32) ConvertError!NodeIndex {
    skipWhitespace(source, pos);
    if (pos.* >= source.len) return error.UnexpectedEndOfInput;

    return switch (source[pos.*]) {
        '"' => convertString(ast, source, pos),
        '{' => convertObject(ast, source, pos),
        '[' => convertArray(ast, source, pos),
        't', 'f' => convertBoolean(ast, source, pos),
        'n' => convertNull(ast, source, pos),
        '-', '0'...'9' => convertNumber(ast, source, pos),
        else => error.InvalidJsonValue,
    };
}

/// JSON 문자열 → string_literal 노드.
/// span은 따옴표를 포함한 원본 텍스트를 참조.
fn convertString(ast: *Ast, source: []const u8, pos: *u32) ConvertError!NodeIndex {
    const start = pos.*;
    if (source[pos.*] != '"') return error.ExpectedString;
    pos.* += 1;

    while (pos.* < source.len) {
        const ch = source[pos.*];
        if (ch == '\\') {
            if (pos.* + 1 >= source.len) return error.UnterminatedString;
            pos.* += 2;
            continue;
        }
        if (ch == '"') {
            pos.* += 1;
            return ast.addNode(.{
                .tag = .string_literal,
                .span = .{ .start = start, .end = pos.* },
                .data = .{ .string_ref = .{ .start = start, .end = pos.* } },
            });
        }
        pos.* += 1;
    }
    return error.UnterminatedString;
}

/// JSON 숫자 → numeric_literal 노드.
fn convertNumber(ast: *Ast, source: []const u8, pos: *u32) ConvertError!NodeIndex {
    const start = pos.*;

    // optional '-'
    if (pos.* < source.len and source[pos.*] == '-') pos.* += 1;

    // integer part
    while (pos.* < source.len and source[pos.*] >= '0' and source[pos.*] <= '9') pos.* += 1;

    // fractional part
    if (pos.* < source.len and source[pos.*] == '.') {
        pos.* += 1;
        while (pos.* < source.len and source[pos.*] >= '0' and source[pos.*] <= '9') pos.* += 1;
    }

    // exponent part
    if (pos.* < source.len and (source[pos.*] == 'e' or source[pos.*] == 'E')) {
        pos.* += 1;
        if (pos.* < source.len and (source[pos.*] == '+' or source[pos.*] == '-')) pos.* += 1;
        while (pos.* < source.len and source[pos.*] >= '0' and source[pos.*] <= '9') pos.* += 1;
    }

    return ast.addNode(.{
        .tag = .numeric_literal,
        .span = .{ .start = start, .end = pos.* },
        .data = .{ .none = 0 },
    });
}

/// JSON boolean → boolean_literal 노드.
fn convertBoolean(ast: *Ast, source: []const u8, pos: *u32) ConvertError!NodeIndex {
    const start = pos.*;
    if (source.len >= pos.* + 4 and std.mem.eql(u8, source[pos.* .. pos.* + 4], "true")) {
        pos.* += 4;
    } else if (source.len >= pos.* + 5 and std.mem.eql(u8, source[pos.* .. pos.* + 5], "false")) {
        pos.* += 5;
    } else {
        return error.InvalidBoolean;
    }
    return ast.addNode(.{
        .tag = .boolean_literal,
        .span = .{ .start = start, .end = pos.* },
        .data = .{ .none = 0 },
    });
}

/// JSON null → null_literal 노드.
fn convertNull(ast: *Ast, source: []const u8, pos: *u32) ConvertError!NodeIndex {
    const start = pos.*;
    if (source.len >= pos.* + 4 and std.mem.eql(u8, source[pos.* .. pos.* + 4], "null")) {
        pos.* += 4;
        return ast.addNode(.{
            .tag = .null_literal,
            .span = .{ .start = start, .end = pos.* },
            .data = .{ .none = 0 },
        });
    }
    return error.InvalidNull;
}

/// JSON 오브젝트 → object_expression 노드.
fn convertObject(ast: *Ast, source: []const u8, pos: *u32) ConvertError!NodeIndex {
    const start = pos.*;
    pos.* += 1;
    skipWhitespace(source, pos);

    var props: std.ArrayListUnmanaged(NodeIndex) = .empty;
    defer props.deinit(ast.allocator);

    if (pos.* < source.len and source[pos.*] != '}') {
        while (true) {
            skipWhitespace(source, pos);
            const key_node = try convertString(ast, source, pos);
            skipWhitespace(source, pos);

            if (pos.* >= source.len or source[pos.*] != ':') return error.ExpectedColon;
            pos.* += 1;

            const value_node = try convertValue(ast, source, pos);

            // object_property: binary { left=key, right=value }
            const prop = try ast.addNode(.{
                .tag = .object_property,
                .span = .{
                    .start = ast.getNode(key_node).span.start,
                    .end = ast.getNode(value_node).span.end,
                },
                .data = .{ .binary = .{ .left = key_node, .right = value_node, .flags = 0 } },
            });
            try props.append(ast.allocator, prop);

            skipWhitespace(source, pos);
            if (pos.* >= source.len) return error.UnterminatedObject;
            if (source[pos.*] == '}') break;
            if (source[pos.*] != ',') return error.ExpectedCommaOrBrace;
            pos.* += 1;
        }
    }

    pos.* += 1;

    const list = try ast.addNodeList(props.items);
    return ast.addNode(.{
        .tag = .object_expression,
        .span = .{ .start = start, .end = pos.* },
        .data = .{ .list = list },
    });
}

/// JSON 배열 → array_expression 노드.
fn convertArray(ast: *Ast, source: []const u8, pos: *u32) ConvertError!NodeIndex {
    const start = pos.*;
    pos.* += 1;
    skipWhitespace(source, pos);

    var elems: std.ArrayListUnmanaged(NodeIndex) = .empty;
    defer elems.deinit(ast.allocator);

    if (pos.* < source.len and source[pos.*] != ']') {
        while (true) {
            const elem = try convertValue(ast, source, pos);
            try elems.append(ast.allocator, elem);

            skipWhitespace(source, pos);
            if (pos.* >= source.len) return error.UnterminatedArray;
            if (source[pos.*] == ']') break;
            if (source[pos.*] != ',') return error.ExpectedCommaOrBracket;
            pos.* += 1;
        }
    }

    pos.* += 1;

    const list = try ast.addNodeList(elems.items);
    return ast.addNode(.{
        .tag = .array_expression,
        .span = .{ .start = start, .end = pos.* },
        .data = .{ .list = list },
    });
}

/// JSON 공백 건너뛰기 (space, tab, CR, LF).
fn skipWhitespace(source: []const u8, pos: *u32) void {
    while (pos.* < source.len) {
        switch (source[pos.*]) {
            ' ', '\t', '\r', '\n' => pos.* += 1,
            else => break,
        }
    }
}

// ============================================================
// 테스트
// ============================================================

test "convert simple object" {
    const allocator = std.testing.allocator;
    const source = "{\"name\": \"zts\", \"version\": 1}";
    var ast = try convert(allocator, source);
    defer ast.deinit();

    // 마지막 노드가 program
    const program = ast.nodes.items[ast.nodes.items.len - 1];
    try std.testing.expectEqual(Node.Tag.program, program.tag);
    // export default + export var name + export var version = 3 statements
    try std.testing.expectEqual(@as(u32, 3), program.data.list.len);

    // program의 첫 번째 statement가 export_default_declaration
    const stmt_idx: NodeIndex = @enumFromInt(ast.extra_data.items[program.data.list.start]);
    const stmt = ast.getNode(stmt_idx);
    try std.testing.expectEqual(Node.Tag.export_default_declaration, stmt.tag);

    // export default의 value가 object_expression
    const obj = ast.getNode(stmt.data.unary.operand);
    try std.testing.expectEqual(Node.Tag.object_expression, obj.tag);
    try std.testing.expectEqual(@as(u32, 2), obj.data.list.len); // 2 properties

    // 2번째, 3번째 statement가 export_named_declaration (export var)
    const stmt2_idx: NodeIndex = @enumFromInt(ast.extra_data.items[program.data.list.start + 1]);
    try std.testing.expectEqual(Node.Tag.export_named_declaration, ast.getNode(stmt2_idx).tag);
}

test "convert array" {
    const allocator = std.testing.allocator;
    const source = "[1, \"hello\", true, null]";
    var ast = try convert(allocator, source);
    defer ast.deinit();

    const program = ast.nodes.items[ast.nodes.items.len - 1];
    const stmt_idx: NodeIndex = @enumFromInt(ast.extra_data.items[program.data.list.start]);
    const stmt = ast.getNode(stmt_idx);
    const arr = ast.getNode(stmt.data.unary.operand);
    try std.testing.expectEqual(Node.Tag.array_expression, arr.tag);
    try std.testing.expectEqual(@as(u32, 4), arr.data.list.len);

    // 개별 요소 태그 확인
    const elem0: NodeIndex = @enumFromInt(ast.extra_data.items[arr.data.list.start]);
    const elem1: NodeIndex = @enumFromInt(ast.extra_data.items[arr.data.list.start + 1]);
    const elem2: NodeIndex = @enumFromInt(ast.extra_data.items[arr.data.list.start + 2]);
    const elem3: NodeIndex = @enumFromInt(ast.extra_data.items[arr.data.list.start + 3]);
    try std.testing.expectEqual(Node.Tag.numeric_literal, ast.getNode(elem0).tag);
    try std.testing.expectEqual(Node.Tag.string_literal, ast.getNode(elem1).tag);
    try std.testing.expectEqual(Node.Tag.boolean_literal, ast.getNode(elem2).tag);
    try std.testing.expectEqual(Node.Tag.null_literal, ast.getNode(elem3).tag);
}

test "convert nested object" {
    const allocator = std.testing.allocator;
    const source = "{\"a\": {\"b\": [1, 2]}}";
    var ast = try convert(allocator, source);
    defer ast.deinit();

    const program = ast.nodes.items[ast.nodes.items.len - 1];
    const stmt_idx: NodeIndex = @enumFromInt(ast.extra_data.items[program.data.list.start]);
    const stmt = ast.getNode(stmt_idx);
    const obj = ast.getNode(stmt.data.unary.operand);
    try std.testing.expectEqual(Node.Tag.object_expression, obj.tag);

    // 첫 번째 프로퍼티의 value가 object_expression
    const prop_idx: NodeIndex = @enumFromInt(ast.extra_data.items[obj.data.list.start]);
    const prop = ast.getNode(prop_idx);
    try std.testing.expectEqual(Node.Tag.object_property, prop.tag);
    const nested_obj = ast.getNode(prop.data.binary.right);
    try std.testing.expectEqual(Node.Tag.object_expression, nested_obj.tag);

    // 중첩 오브젝트의 value가 array_expression
    const nested_prop_idx: NodeIndex = @enumFromInt(ast.extra_data.items[nested_obj.data.list.start]);
    const nested_prop = ast.getNode(nested_prop_idx);
    const arr = ast.getNode(nested_prop.data.binary.right);
    try std.testing.expectEqual(Node.Tag.array_expression, arr.tag);
    try std.testing.expectEqual(@as(u32, 2), arr.data.list.len);
}

test "convert scalar values" {
    const allocator = std.testing.allocator;

    // number
    {
        var ast = try convert(allocator, "42");
        defer ast.deinit();
        const program = ast.nodes.items[ast.nodes.items.len - 1];
        const stmt_idx: NodeIndex = @enumFromInt(ast.extra_data.items[program.data.list.start]);
        const val = ast.getNode(ast.getNode(stmt_idx).data.unary.operand);
        try std.testing.expectEqual(Node.Tag.numeric_literal, val.tag);
        try std.testing.expectEqualStrings("42", ast.getText(val.span));
    }

    // negative number
    {
        var ast = try convert(allocator, "-3.14e+2");
        defer ast.deinit();
        const program = ast.nodes.items[ast.nodes.items.len - 1];
        const stmt_idx: NodeIndex = @enumFromInt(ast.extra_data.items[program.data.list.start]);
        const val = ast.getNode(ast.getNode(stmt_idx).data.unary.operand);
        try std.testing.expectEqual(Node.Tag.numeric_literal, val.tag);
        try std.testing.expectEqualStrings("-3.14e+2", ast.getText(val.span));
    }

    // string
    {
        var ast = try convert(allocator, "\"hello\"");
        defer ast.deinit();
        const program = ast.nodes.items[ast.nodes.items.len - 1];
        const stmt_idx: NodeIndex = @enumFromInt(ast.extra_data.items[program.data.list.start]);
        const val = ast.getNode(ast.getNode(stmt_idx).data.unary.operand);
        try std.testing.expectEqual(Node.Tag.string_literal, val.tag);
        try std.testing.expectEqualStrings("\"hello\"", ast.getText(val.span));
    }

    // true
    {
        var ast = try convert(allocator, "true");
        defer ast.deinit();
        const program = ast.nodes.items[ast.nodes.items.len - 1];
        const stmt_idx: NodeIndex = @enumFromInt(ast.extra_data.items[program.data.list.start]);
        const val = ast.getNode(ast.getNode(stmt_idx).data.unary.operand);
        try std.testing.expectEqual(Node.Tag.boolean_literal, val.tag);
    }

    // null
    {
        var ast = try convert(allocator, "null");
        defer ast.deinit();
        const program = ast.nodes.items[ast.nodes.items.len - 1];
        const stmt_idx: NodeIndex = @enumFromInt(ast.extra_data.items[program.data.list.start]);
        const val = ast.getNode(ast.getNode(stmt_idx).data.unary.operand);
        try std.testing.expectEqual(Node.Tag.null_literal, val.tag);
    }
}

test "convert empty object and array" {
    const allocator = std.testing.allocator;

    {
        var ast = try convert(allocator, "{}");
        defer ast.deinit();
        const program = ast.nodes.items[ast.nodes.items.len - 1];
        const stmt_idx: NodeIndex = @enumFromInt(ast.extra_data.items[program.data.list.start]);
        const obj = ast.getNode(ast.getNode(stmt_idx).data.unary.operand);
        try std.testing.expectEqual(Node.Tag.object_expression, obj.tag);
        try std.testing.expectEqual(@as(u32, 0), obj.data.list.len);
    }

    {
        var ast = try convert(allocator, "[]");
        defer ast.deinit();
        const program = ast.nodes.items[ast.nodes.items.len - 1];
        const stmt_idx: NodeIndex = @enumFromInt(ast.extra_data.items[program.data.list.start]);
        const arr = ast.getNode(ast.getNode(stmt_idx).data.unary.operand);
        try std.testing.expectEqual(Node.Tag.array_expression, arr.tag);
        try std.testing.expectEqual(@as(u32, 0), arr.data.list.len);
    }
}
