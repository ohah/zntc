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
            const source = self.old_ast.source;
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

            const members = self.old_ast.extra_data.items[node.data.list.start .. node.data.list.start + node.data.list.len];
            if (members.len == 0) return NodeIndex.none;

            const first_elem = self.old_ast.getNode(@enumFromInt(members[0]));
            const head_text = getTemplateElementText(self.old_ast.source, first_elem.span);

            if (members.len == 1) {
                return buildStringLiteral(self, head_text);
            }

            // 빈 head라도 "" + expr 로 시작해야 toString 보장
            var result = try buildStringLiteral(self, head_text);

            var i: usize = 1;
            while (i < members.len) : (i += 1) {
                const member = self.old_ast.getNode(@enumFromInt(members[i]));
                if (member.tag == .template_element) {
                    const text = getTemplateElementText(self.old_ast.source, member.span);
                    if (text.len > 0) {
                        const str_node = try buildStringLiteral(self, text);
                        result = try buildBinaryPlus(self, result, str_node, span);
                    }
                } else {
                    const visited = try self.visitNode(@enumFromInt(members[i]));
                    if (!visited.isNone()) {
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
fn getTemplateElementText(source: []const u8, span: Span) []const u8 {
    if (span.end <= span.start + 2) return "";

    const start = span.start + 1; // 앞: ` 또는 } (항상 1바이트)
    const last_char = source[span.end - 1];
    const trim_end: u32 = if (last_char == '`') 1 else 2; // ` → 1, { → 2 (${)
    const end = span.end - trim_end;

    if (end <= start) return "";
    return source[start..end];
}

/// template 텍스트를 string_literal 노드로 변환한다.
/// \` → ` (backtick escape 제거), " → \" (quote escape 추가),
/// 실제 줄바꿈(\n, \r) → 이스케이프 시퀀스로 변환.
fn buildStringLiteral(self: anytype, text: []const u8) !NodeIndex {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(self.allocator);

    // 최악: 모든 문자가 이스케이프 확장 (2배) + 양쪽 따옴표
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
        } else {
            buf.appendAssumeCapacity(c);
        }
    }

    buf.appendAssumeCapacity('"');

    const str_span = try self.new_ast.addString(buf.items);
    return self.new_ast.addNode(.{
        .tag = .string_literal,
        .span = str_span,
        .data = .{ .string_ref = str_span },
    });
}

/// a + b binary expression을 만든다.
fn buildBinaryPlus(self: anytype, left: NodeIndex, right: NodeIndex, span: Span) !NodeIndex {
    return self.new_ast.addNode(.{
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
