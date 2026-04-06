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

    const str_span = try self.ast.addString(buf.items);
    return self.ast.addNode(.{
        .tag = .string_literal,
        .span = str_span,
        .data = .{ .string_ref = str_span },
    });
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
