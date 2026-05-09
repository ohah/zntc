//! Regex replacement helpers for Transformer.

const std = @import("std");
const ast_mod = @import("../../parser/ast.zig");
const Node = ast_mod.Node;
const NodeIndex = ast_mod.NodeIndex;
const NodeList = ast_mod.NodeList;
const regex_lower = @import("../regex_lower.zig");
const transformer_mod = @import("../transformer.zig");
const Transformer = transformer_mod.Transformer;
const Error = Transformer.Error;

/// `x.replace(re, "...$<n>...")` / `x.replace(/.../u, \`...$<n>...\`)` 패턴 매칭 + replacement 변환.
/// 매칭 실패 (callee 형태 다름, regex pattern 미상, replacement 가 literal 형태 아님 등) 시 null.
///
/// 지원:
///   - args[0]: regex literal `/.../`, 또는 `const re = /.../;` 로 선언된 변수 (symbol_id 기반 추적)
///   - args[1]: string literal, 또는 interpolation 없는 template literal (\`...\`)
pub fn tryRewriteReplaceNamedRefs(self: *Transformer, callee_idx: NodeIndex, args_start: u32) Error!?NodeList {
    const callee = self.ast.getNode(callee_idx);
    if (callee.tag != .static_member_expression) return null;
    const ce = callee.data.extra;
    if (ce + 1 >= self.ast.extra_data.items.len) return null;
    const prop_idx = self.readNodeIdx(ce, 1);
    const prop = self.ast.getNode(prop_idx);
    if (prop.tag != .identifier_reference) return null;
    const prop_name = self.ast.getText(prop.span);
    if (!std.mem.eql(u8, prop_name, "replace") and !std.mem.eql(u8, prop_name, "replaceAll")) return null;

    const arg0_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[args_start]);
    const arg1_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[args_start + 1]);

    const pattern = (resolveRegexPatternForCall(self, arg0_idx)) orelse return null;
    const mapping = try regex_lower.extractNamedGroupMap(self.allocator, pattern);
    defer self.allocator.free(mapping);
    if (mapping.len == 0) return null;

    const replacement = (try extractReplacementContent(self, arg1_idx)) orelse return null;
    defer self.allocator.free(replacement.content);

    const new_content = (try regex_lower.rewriteReplacementNamedRefs(self.allocator, replacement.content, mapping)) orelse return null;
    defer self.allocator.free(new_content);

    const quote: u8 = if (replacement.is_template) '"' else replacement.quote;
    const new_raw = try std.fmt.allocPrint(self.allocator, "{c}{s}{c}", .{ quote, new_content, quote });
    defer self.allocator.free(new_raw);
    const new_span = try self.ast.addString(new_raw);
    const new_str_node = try self.ast.addNode(.{
        .tag = .string_literal,
        .span = new_span,
        .data = .{ .string_ref = new_span },
    });
    const new_arg0 = try self.visitNode(arg0_idx);
    return self.ast.addNodeList(&[_]NodeIndex{ new_arg0, new_str_node }) catch return Error.OutOfMemory;
}

/// `const re = /.../;` 형태의 declarator 들을 self.regex_var_map 에 등록.
/// destructuring/function call init/non-regex init 은 모두 skip.
pub fn collectConstRegexDeclarators(self: *Transformer, list_start: u32, list_len: u32) Error!void {
    var i: u32 = 0;
    while (i < list_len) : (i += 1) {
        const decl_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[list_start + i]);
        const decl = self.ast.getNode(decl_idx);
        if (decl.tag != .variable_declarator) continue;
        const de = decl.data.extra;
        if (de + 2 >= self.ast.extra_data.items.len) continue;
        const name_idx = self.readNodeIdx(de, 0);
        const init_idx = self.readNodeIdx(de, 2);
        if (name_idx.isNone() or init_idx.isNone()) continue;
        const name_node = self.ast.getNode(name_idx);
        if (name_node.tag != .binding_identifier) continue;
        const init_node = self.ast.getNode(init_idx);
        if (init_node.tag != .regexp_literal) continue;
        const raw = self.ast.getText(init_node.span);
        if (raw.len < 3 or raw[0] != '/') continue;
        const last_slash = std.mem.lastIndexOfScalar(u8, raw, '/') orelse continue;
        if (last_slash == 0) continue;
        const sym_id = self.getSymbolIdAt(name_idx) orelse continue;
        const owned_pattern = try self.allocator.dupe(u8, raw[1..last_slash]);
        errdefer self.allocator.free(owned_pattern);
        // 중복 선언 (eg. block-shadow) 시 이전 entry 해제. OOM 은 상위로 전파 — 조용히 삼키면
        // 후속 lookup 이 실패해 #1473 변환이 silent 누락되는 regression.
        if (try self.regex_var_map.fetchPut(self.allocator, sym_id, owned_pattern)) |old| {
            self.allocator.free(old.value);
        }
    }
}

/// arg0 가 regex literal 또는 추적된 const regex 변수면 pattern slice 반환.
/// 반환 슬라이스의 수명: ast.string_table (literal) 또는 self.regex_var_map (변수) — 둘 다 변환 동안 유효.
fn resolveRegexPatternForCall(self: *const Transformer, arg_idx: NodeIndex) ?[]const u8 {
    if (arg_idx.isNone()) return null;
    const node = self.ast.getNode(arg_idx);
    switch (node.tag) {
        .regexp_literal => {
            const raw = self.ast.getText(node.span);
            if (raw.len < 3 or raw[0] != '/') return null;
            const last_slash = std.mem.lastIndexOfScalar(u8, raw, '/') orelse return null;
            if (last_slash == 0) return null;
            return raw[1..last_slash];
        },
        .identifier_reference => {
            const sym = self.getSymbolIdAt(arg_idx) orelse return null;
            return self.regex_var_map.get(sym);
        },
        else => return null,
    }
}

const ReplacementContent = struct {
    content: []u8, // owned dup of literal body
    quote: u8, // string literal 의 따옴표 (template 인 경우 무관)
    is_template: bool,
};

/// arg1 가 string literal 또는 interpolation 없는 template literal 이면 그 본문 (escape 보존)을 owned 로 반환.
fn extractReplacementContent(self: *Transformer, arg_idx: NodeIndex) Error!?ReplacementContent {
    if (arg_idx.isNone()) return null;
    const node = self.ast.getNode(arg_idx);
    switch (node.tag) {
        .string_literal => {
            const raw = self.ast.getText(node.data.string_ref);
            if (raw.len < 2) return null;
            const q = raw[0];
            if (q != '"' and q != '\'') return null;
            const body = raw[1 .. raw.len - 1];
            const owned = try self.allocator.dupe(u8, body);
            return .{ .content = owned, .quote = q, .is_template = false };
        },
        .template_literal => {
            // 보간 없는 template literal (`text`): parser 가 data: .none 으로 저장 + span 은 backtick 포함 전체.
            // 보간 있는 경우(template_head 진입): data: .list 형식 — 우리는 보간 없는 케이스만 지원.
            if (node.data.none != 0) return null;
            const raw = self.ast.getText(node.span);
            if (raw.len < 2 or raw[0] != '`' or raw[raw.len - 1] != '`') return null;
            const body = raw[1 .. raw.len - 1];
            // 본문 안에 ${ 가 있으면 보간 있는 케이스 — 안전하게 fallback.
            if (std.mem.indexOf(u8, body, "${") != null) return null;
            const owned = try self.allocator.dupe(u8, body);
            return .{ .content = owned, .quote = '"', .is_template = true };
        },
        else => return null,
    }
}
