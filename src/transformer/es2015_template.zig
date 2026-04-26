//! ES2015 다운레벨링: template literal
//!
//! --target < es2015 일 때 활성화.
//! `hello ${name}!` → "hello " + name + "!"
//! `${a}${b}` → "" + a + b
//! `text` → "text"
//!
//! 변환 알고리즘:
//!   1. template_literal(list) → list의 element/expression을 순회
//!   2. 각 template_element의 span에서 구분자(` } ${)를 제거하고 string_literal로 변환
//!   3. element와 expression을 + 연산자로 연결
//!   4. head가 빈 문자열이고 expression이 있으면 "" + expr 로 시작 (toString 보장)
//!
//! 스펙:
//! - https://tc39.es/ecma262/#sec-template-literals (ES2015)
//!
//! 참고:
//! - SWC: crates/swc_ecma_compat_es2015/src/template_literal.rs (~400줄)
//! - esbuild: pkg/js_parser/js_parser_lower.go (lowerTemplateLiteral)
//! - Babel: @babel/plugin-transform-template-literals

const std = @import("std");
const ast_mod = @import("../parser/ast.zig");
const Node = ast_mod.Node;
const NodeIndex = ast_mod.NodeIndex;
const Tag = Node.Tag;
const token_mod = @import("../lexer/token.zig");
const Span = token_mod.Span;

pub fn ES2015Template(comptime Transformer: type) type {
    return struct {
        /// template_literal을 string concatenation (+)으로 변환한다.
        ///
        /// template_literal 노드의 구조:
        ///   - data.none (no substitution): `text` → 단순 문자열
        ///   - data.list: [element, expr, element, expr, ..., element]
        ///     element는 template_element (텍스트 부분)
        ///     expr는 보간 표현식 (${...} 안의 값)
        ///
        /// 변환 결과:
        ///   `a${b}c${d}e` → "a" + b + "c" + d + "e"
        ///   `${x}` → "" + x
        ///   `text` → "text"
        pub fn lowerTemplateLiteral(self: *Transformer, node: Node) Transformer.Error!NodeIndex {
            const span = node.span;

            // Data는 extern union이므로 data.none=0 시 data.list는 미초기화.
            // 소스를 스캔하여 ${가 있는지로 substitution 여부를 판별한다.
            const source = self.ast.source;
            const is_substitution = blk: {
                var pos = span.start + 1;
                while (pos < span.end) {
                    if (source[pos] == '\\') {
                        pos += 2; // 이스케이프 스킵
                        continue;
                    }
                    if (source[pos] == '$' and pos + 1 < span.end and source[pos + 1] == '{') {
                        break :blk true;
                    }
                    pos += 1;
                }
                break :blk false;
            };

            if (!is_substitution) {
                const text = getTemplateElementText(source, span);
                return buildStringLiteral(self, text);
            }

            const tl_start = node.data.list.start;
            const tl_len = node.data.list.len;
            if (tl_len == 0) return NodeIndex.none;

            const first_elem = self.ast.getNode(@enumFromInt(self.ast.extra_data.items[tl_start]));
            const head_text = getTemplateElementText(self.ast.source, first_elem.span);

            if (tl_len == 1) {
                return buildStringLiteral(self, head_text);
            }

            // 빈 head라도 "" + expr 로 ��작해야 toString 보장
            var result = try buildStringLiteral(self, head_text);

            // visitNode가 AST를 ���형하므로 인덱스 루프 사용 (슬라이스 캐시 금��)
            var i: u32 = 1;
            while (i < tl_len) : (i += 1) {
                const raw_idx = self.ast.extra_data.items[tl_start + i];
                const member = self.ast.getNode(@enumFromInt(raw_idx));
                if (member.tag == .template_element) {
                    const text = getTemplateElementText(self.ast.source, member.span);
                    if (text.len > 0) {
                        const str_node = try buildStringLiteral(self, text);
                        result = try buildBinaryPlus(self, result, str_node, span);
                    }
                } else {
                    var visited = try self.visitNode(@enumFromInt(raw_idx));
                    if (!visited.isNone()) {
                        // 보간 표현식이 + 연산자 right에 올 때 우선순위 문제 방지.
                        // 예: `${1+2}` → "" + (1 + 2), `${x ? "a" : "b"}` → "" + (x ? "a" : "b")
                        if (needsParenForConcat(self, visited)) {
                            const es_helpers = @import("es_helpers.zig");
                            visited = try es_helpers.makeParenExpr(self, visited, span);
                        }
                        result = try buildBinaryPlus(self, result, visited, span);
                    }
                }
            }

            return result;
        }
    };
}

/// template_element span에서 구분자를 제거한 텍스트 부분을 반환한다.
///
/// template_element span은 스캐너 토큰과 동일:
///   head:    `text${  → 앞 1(`), 뒤 2(${)
///   middle:  }text${  → 앞 1(}), 뒤 2(${)
///   tail:    }text`   → 앞 1(}), 뒤 1(`)
///   no_sub:  `text`   → 앞 1(`), 뒤 1(`)
pub fn getTemplateElementText(source: []const u8, span: Span) []const u8 {
    if (span.end <= span.start + 2) return "";

    const start = span.start + 1; // 앞: ` 또는 } (항상 1바이트)
    const last_char = source[span.end - 1];
    const trim_end: u32 = if (last_char == '`') 1 else 2; // ` → 1, { → 2 (${)
    const end = span.end - trim_end;

    if (end <= start) return "";
    return source[start..end];
}

/// raw template 텍스트를 string_literal 노드로 변환한다.
/// backslash를 이중 이스케이프하여 JS 문자열에서 원본 그대로 보이도록 한다.
/// `hello\nworld` → `"hello\\nworld"` (JS에서 실행 시 "hello\nworld" 문자열)
pub fn buildRawStringLiteral(self: anytype, text: []const u8) !NodeIndex {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(self.allocator);

    try buf.ensureUnusedCapacity(self.allocator, text.len * 2 + 2);
    buf.appendAssumeCapacity('"');

    var j: usize = 0;
    while (j < text.len) : (j += 1) {
        const c = text[j];
        if (c == '"') {
            buf.appendAssumeCapacity('\\');
            buf.appendAssumeCapacity('"');
        } else if (c == '\\') {
            // raw: backslash를 이중 이스케이프
            buf.appendAssumeCapacity('\\');
            buf.appendAssumeCapacity('\\');
        } else if (c == '\n') {
            buf.appendAssumeCapacity('\\');
            buf.appendAssumeCapacity('n');
        } else if (c == '\r') {
            buf.appendAssumeCapacity('\\');
            buf.appendAssumeCapacity('r');
        } else {
            buf.appendAssumeCapacity(c);
        }
    }

    buf.appendAssumeCapacity('"');

    // unicode brace escape lowering (#1388) — target 이 `\u{X}` 미지원이면 surrogate pair 로 치환.
    if (self.options.unsupported.unicode_brace_escape) {
        const unicode_escape_lower = @import("unicode_escape_lower.zig");
        if (try unicode_escape_lower.lowerContent(self.allocator, buf.items[1 .. buf.items.len - 1])) |lowered| {
            defer self.allocator.free(lowered);
            buf.clearRetainingCapacity();
            try buf.append(self.allocator, '"');
            try buf.appendSlice(self.allocator, lowered);
            try buf.append(self.allocator, '"');
        }
    }

    const str_span = try self.ast.addString(buf.items);
    return self.ast.addNode(.{
        .tag = .string_literal,
        .span = str_span,
        .data = .{ .string_ref = str_span },
    });
}

/// Tagged template literal 의 cooked 영역 텍스트가 ES2018 "Lifting Template Literal
/// Restriction" 스펙 기준 invalid escape sequence 를 포함하는지 검사한다.
///
/// invalid 면 cooked array 의 해당 element 는 `undefined` 여야 하고
/// (https://tc39.es/ecma262/#sec-template-literal-lexical-components),
/// 그렇지 않으면 raw text 그대로 cooked string 으로 emit 했을 때 JS 엔진의
/// parse 단계에서 "\\x can only be followed by a hex character sequence" 류
/// SyntaxError 가 발생한다.
///
/// invalid 패턴:
/// - `\\x` 뒤 hex 두 글자 아님
/// - `\\u` 뒤 hex 네 글자 아님 / `\\u{...}` 형태가 아예 없거나 코드포인트 > 0x10FFFF
/// - `\\1` ~ `\\9` legacy octal escape (template literal 컨텍스트에선 항상 invalid)
/// - `\\0` 뒤가 decimal digit (즉 `\\01`, `\\09` 등) 도 legacy octal 로 해석 → invalid
pub fn templateCookedHasInvalidEscape(text: []const u8) bool {
    // backslash 가 없으면 escape 도 없다 — 가장 흔한 경우 short-circuit (SIMD-accelerated).
    var i: usize = std.mem.indexOfScalar(u8, text, '\\') orelse return false;
    while (i < text.len) {
        if (text[i] != '\\') {
            i += 1;
            continue;
        }
        i += 1;
        if (i >= text.len) return false; // trailing backslash 는 lexer 가 syntax error 처리
        const c = text[i];
        switch (c) {
            'x' => {
                if (i + 2 >= text.len) return true;
                if (!std.ascii.isHex(text[i + 1]) or !std.ascii.isHex(text[i + 2])) return true;
                i += 3;
            },
            'u' => {
                i += 1;
                if (i >= text.len) return true;
                if (text[i] == '{') {
                    var j = i + 1;
                    var code: u32 = 0;
                    var n: u32 = 0;
                    while (j < text.len and text[j] != '}') : (j += 1) {
                        const d = text[j];
                        if (!std.ascii.isHex(d)) return true;
                        code = (code << 4) | @as(u32, std.fmt.charToDigit(d, 16) catch return true);
                        n += 1;
                        if (n > 6) return true;
                    }
                    if (j >= text.len) return true; // missing '}'
                    if (n == 0) return true;
                    if (code > 0x10FFFF) return true;
                    i = j + 1;
                } else {
                    if (i + 4 > text.len) return true;
                    var k: usize = 0;
                    while (k < 4) : (k += 1) {
                        if (!std.ascii.isHex(text[i + k])) return true;
                    }
                    i += 4;
                }
            },
            '0' => {
                if (i + 1 < text.len and text[i + 1] >= '0' and text[i + 1] <= '9') return true;
                i += 1;
            },
            '1', '2', '3', '4', '5', '6', '7', '8', '9' => return true,
            else => i += 1, // \\n, \\r, \\t, \\', \\", \\\\, \\`, \\$, etc. valid
        }
    }
    return false;
}

/// Tagged template 의 cooked element 노드 생성: invalid escape 면 `void 0`, 아니면 string literal.
/// ES2018 "Lifting Template Literal Restriction" 적용 — visitTaggedTemplate 의 두 분기 공통.
pub fn buildCookedElement(self: anytype, text: []const u8, span: Span) !NodeIndex {
    const es_helpers = @import("es_helpers.zig");
    if (templateCookedHasInvalidEscape(text)) {
        return es_helpers.makeVoidZero(self, span);
    }
    return buildStringLiteral(self, text);
}

/// template 텍스트를 string_literal 노드로 변환한다.
/// \` → ` (backtick escape 제거), " → \" (quote escape 추가),
/// 실제 줄바꿈(\n, \r) 및 U+2028/U+2029 → 이스케이프 시퀀스로 변환.
pub fn buildStringLiteral(self: anytype, text: []const u8) !NodeIndex {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(self.allocator);

    // 최악: U+2028/2029가 3바이트→6바이트(2배), 그 외 최대 2배 + 양쪽 따옴표
    try buf.ensureUnusedCapacity(self.allocator, text.len * 2 + 2);
    buf.appendAssumeCapacity('"');

    var j: usize = 0;
    while (j < text.len) : (j += 1) {
        const c = text[j];
        if (c == '"') {
            buf.appendAssumeCapacity('\\');
            buf.appendAssumeCapacity('"');
        } else if (c == '\\' and j + 1 < text.len and text[j + 1] == '`') {
            buf.appendAssumeCapacity('`');
            j += 1;
        } else if (c == '\n') {
            buf.appendAssumeCapacity('\\');
            buf.appendAssumeCapacity('n');
        } else if (c == '\r') {
            buf.appendAssumeCapacity('\\');
            buf.appendAssumeCapacity('r');
        } else if (c == 0xe2 and j + 2 < text.len and text[j + 1] == 0x80 and (text[j + 2] == 0xa8 or text[j + 2] == 0xa9)) {
            // U+2028 (Line Separator) / U+2029 (Paragraph Separator)
            // 템플릿 리터럴에서는 유효하지만 ES5 문자열 리터럴에서는 줄바꿈으로 취급
            const sep: u8 = if (text[j + 2] == 0xa8) '8' else '9';
            try buf.appendSlice(self.allocator, "\\u202");
            try buf.append(self.allocator, sep);
            j += 2;
        } else {
            buf.appendAssumeCapacity(c);
        }
    }

    buf.appendAssumeCapacity('"');

    if (self.options.unsupported.unicode_brace_escape) {
        const unicode_escape_lower = @import("unicode_escape_lower.zig");
        if (try unicode_escape_lower.lowerContent(self.allocator, buf.items[1 .. buf.items.len - 1])) |lowered| {
            defer self.allocator.free(lowered);
            buf.clearRetainingCapacity();
            try buf.append(self.allocator, '"');
            try buf.appendSlice(self.allocator, lowered);
            try buf.append(self.allocator, '"');
        }
    }

    const str_span = try self.ast.addString(buf.items);
    return self.ast.addNode(.{
        .tag = .string_literal,
        .span = str_span,
        .data = .{ .string_ref = str_span },
    });
}

/// a + b binary expression을 만든다.
/// 보간 표현식이 string concat (+) right operand에 올 때 괄호가 필요한지 판별.
/// +보다 낮은 우선순위(conditional, assignment, comma 등)나
/// 같은 우선순위(+, -)는 left-to-right 결합으로 의미가 달라지므로 괄호 필요.
/// 리터럴, identifier, call, member 등 원자적 표현식은 괄호 불필요.
fn needsParenForConcat(self: anytype, idx: NodeIndex) bool {
    if (idx.isNone()) return false;
    const node = self.ast.getNode(idx);
    return switch (node.tag) {
        // 괄호 불필요: 원자적 표현식
        .identifier_reference,
        .this_expression,
        .numeric_literal,
        .string_literal,
        .boolean_literal,
        .null_literal,
        .bigint_literal,
        .regexp_literal,
        .template_literal,
        .array_expression,
        .object_expression,
        .call_expression,
        .new_expression,
        .static_member_expression,
        .computed_member_expression,
        .parenthesized_expression,
        .tagged_template_expression,
        .unary_expression,
        .update_expression,
        .await_expression,
        .private_field_expression,
        => false,
        // 그 외(binary, conditional, assignment, sequence, yield 등)는 괄호 필요
        else => true,
    };
}

fn buildBinaryPlus(self: anytype, left: NodeIndex, right: NodeIndex, span: Span) !NodeIndex {
    return self.ast.addNode(.{
        .tag = .binary_expression,
        .span = span,
        .data = .{ .binary = .{
            .left = left,
            .right = right,
            .flags = @intFromEnum(token_mod.Kind.plus),
        } },
    });
}

test "ES2015 template module compiles" {
    _ = ES2015Template;
}

test "templateCookedHasInvalidEscape — \\x with non-hex" {
    try std.testing.expect(templateCookedHasInvalidEscape("\\xz0"));
    try std.testing.expect(templateCookedHasInvalidEscape("\\x")); // truncated
    try std.testing.expect(!templateCookedHasInvalidEscape("\\xff"));
}

test "templateCookedHasInvalidEscape — \\u short" {
    try std.testing.expect(templateCookedHasInvalidEscape("\\uz"));
    try std.testing.expect(templateCookedHasInvalidEscape("\\u00")); // truncated
    try std.testing.expect(!templateCookedHasInvalidEscape("\\u00ff"));
}

test "templateCookedHasInvalidEscape — \\u{...}" {
    try std.testing.expect(!templateCookedHasInvalidEscape("\\u{1f4af}"));
    try std.testing.expect(templateCookedHasInvalidEscape("\\u{z}"));
    try std.testing.expect(templateCookedHasInvalidEscape("\\u{}")); // empty
    try std.testing.expect(templateCookedHasInvalidEscape("\\u{110000}")); // > U+10FFFF
    try std.testing.expect(templateCookedHasInvalidEscape("\\u{1f4af")); // missing }
}

test "templateCookedHasInvalidEscape — legacy octal escape" {
    try std.testing.expect(templateCookedHasInvalidEscape("\\1"));
    try std.testing.expect(templateCookedHasInvalidEscape("\\9"));
    try std.testing.expect(templateCookedHasInvalidEscape("\\01"));
    // \0 단독은 valid (NUL)
    try std.testing.expect(!templateCookedHasInvalidEscape("\\0"));
    try std.testing.expect(!templateCookedHasInvalidEscape("hello \\0 world"));
}

test "templateCookedHasInvalidEscape — common valid escapes" {
    try std.testing.expect(!templateCookedHasInvalidEscape("hello\\nworld"));
    try std.testing.expect(!templateCookedHasInvalidEscape("\\t\\r\\b\\f\\v"));
    try std.testing.expect(!templateCookedHasInvalidEscape("\\\\\\'\\\""));
    try std.testing.expect(!templateCookedHasInvalidEscape("\\`\\$"));
}

test "templateCookedHasInvalidEscape — compat-table es5 case" {
    // strings`\1\xz\uz\u{110000}\u{z}` — 모든 escape 가 invalid
    try std.testing.expect(templateCookedHasInvalidEscape("\\1\\xz\\uz\\u{110000}\\u{z}"));
}
