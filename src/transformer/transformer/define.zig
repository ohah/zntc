//! Define replacement helpers for Transformer.

const std = @import("std");
const ast_mod = @import("../../parser/ast.zig");
const Ast = ast_mod.Ast;
const Node = ast_mod.Node;
const NodeIndex = ast_mod.NodeIndex;
const transformer_mod = @import("../transformer.zig");
const Transformer = transformer_mod.Transformer;
const Error = Transformer.Error;

/// define 치환 엔트리. key=식별자 텍스트, value=치환 문자열.
/// `parser.scan_results.DefineEntry` 와 동일 정의 — parser 의 inline scan 도 같은 entries 사용.
pub const DefineEntry = @import("../../parser/scan_results.zig").DefineEntry;

/// 정규화 버퍼 크기. `process.env.NODE_ENV`류 식별자 체인은 훨씬 짧지만 여유.
/// 초과 시 normalizeOptionalChain은 null을 반환해 치환을 스킵한다.
const DEFINE_KEY_NORM_BUF: usize = 256;

/// 번들 맥락에서 의미 없는 global root 접두어.
/// `globalThis.X`, `window.X`, `self.X` → X로 간주해 define 키와 매칭.
const GLOBAL_ROOT_PREFIXES = [_][]const u8{ "globalThis.", "window.", "self." };

/// optional chaining 토큰 `?.`를 `.`로 치환한 정규화 문자열을 buf에 쓴다.
/// 정규화된 길이가 buf 용량을 초과하면 null (극히 드문 경로 — 치환 포기).
fn normalizeOptionalChain(text: []const u8, buf: []u8) ?[]const u8 {
    const needed = std.mem.replacementSize(u8, text, "?.", ".");
    if (needed > buf.len) return null;
    _ = std.mem.replace(u8, text, "?.", ".", buf);
    return buf[0..needed];
}

/// define 키 매칭 — 엄격 일치 또는 GLOBAL_ROOT_PREFIXES 제거 후 일치.
/// 예: `globalThis.process.env.NODE_ENV`를 키 `process.env.NODE_ENV`로 매치.
fn matchDefineKey(text: []const u8, key: []const u8) bool {
    if (std.mem.eql(u8, text, key)) return true;
    for (GLOBAL_ROOT_PREFIXES) |pfx| {
        if (std.mem.startsWith(u8, text, pfx) and std.mem.eql(u8, text[pfx.len..], key)) return true;
    }
    return false;
}

fn getDefineCandidateText(ast: *const Ast, node: Node) ?[]const u8 {
    return switch (node.tag) {
        .identifier_reference,
        .static_member_expression,
        .chain_expression,
        => ast.getText(node.span),
        else => null,
    };
}

pub fn astUsesDefine(ast: *const Ast, defines: []const DefineEntry) bool {
    if (defines.len == 0) return false;

    for (ast.nodes.items) |node| {
        const raw_text = getDefineCandidateText(ast, node) orelse continue;

        // tryDefineReplace와 동일하게 optional chain을 정규화한 뒤 define key와 매칭한다.
        var norm_buf: [DEFINE_KEY_NORM_BUF]u8 = undefined;
        const text = if (std.mem.indexOfScalar(u8, raw_text, '?') != null)
            normalizeOptionalChain(raw_text, &norm_buf) orelse continue
        else
            raw_text;

        for (defines) |entry| {
            if (matchDefineKey(text, entry.key)) return true;
        }
    }
    return false;
}

/// 노드가 define 치환 대상이면 새 string_literal 노드를 반환.
/// 대상: identifier_reference / static_member_expression / chain_expression.
///
/// 매칭 규칙(#1552):
///   - optional chaining(`?.`)이 포함된 식은 `.`로 정규화 후 매칭.
///     방어적 접근 패턴(`globalThis.process?.env?.NODE_ENV`)까지 커버.
///   - `globalThis.` / `window.` / `self.` 접두어는 번들 맥락에서 의미 없는
///     global root이므로 벗기고 define key와 비교.
pub fn tryDefineReplace(self: *Transformer, node: Node) ?Error!NodeIndex {
    const raw_text = getDefineCandidateText(self.ast, node) orelse return null;

    // parser는 `a?.b`를 chain_expression 없이 static_member_expression + optional
    // flag로 표현하므로, `?` 존재 여부로만 정규화 필요를 판별.
    var norm_buf: [DEFINE_KEY_NORM_BUF]u8 = undefined;
    const text = if (std.mem.indexOfScalar(u8, raw_text, '?') != null)
        normalizeOptionalChain(raw_text, &norm_buf) orelse return null
    else
        raw_text;

    for (self.options.define) |entry| {
        if (!matchDefineKey(text, entry.key)) continue;
        // intern map 이 같은 entry.value 의 두 번째 호출부터 hit → 캐시 효과 흡수.
        const value_span = self.ast.addString(entry.value) catch return Error.OutOfMemory;
        // 값이 따옴표로 시작하면 string_literal, 아니면 identifier_reference.
        // "production" → string_literal, false/true/숫자 → identifier_reference.
        const is_string = entry.value.len >= 2 and (entry.value[0] == '"' or entry.value[0] == '\'');
        return self.ast.addNode(.{
            .tag = if (is_string) .string_literal else .identifier_reference,
            .span = value_span,
            .data = .{ .string_ref = value_span },
        });
    }
    return null;
}
