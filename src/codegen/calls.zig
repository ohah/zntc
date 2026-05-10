//! Codegen helpers for call/new/import.meta/require-style runtime expressions.

const std = @import("std");
const ast_mod = @import("../parser/ast.zig");
const Ast = ast_mod.Ast;
const Node = ast_mod.Node;
const NodeIndex = ast_mod.NodeIndex;
const dev = @import("../bundler/emitter/dev.zig");
const ImportRecord = @import("../bundler/types.zig").ImportRecord;

const IMPORT_META_URL_NODE = "require(\"url\").pathToFileURL(__filename).href";
const IMPORT_META_NODE_OBJECT = "{url:" ++ IMPORT_META_URL_NODE ++ ",dirname:__dirname,filename:__filename}";

pub fn emitCall(self: anytype, node: Node) !void {
    const e = node.data.extra;
    if (!self.ast.hasExtra(e, 3)) return;
    const callee = self.ast.readExtraNode(e, 0);
    const args_start = self.ast.readExtra(e, 1);
    const args_len = self.ast.readExtra(e, 2);
    const flags = self.ast.readExtra(e, 3);
    const CallFlags = ast_mod.CallFlags;
    const is_optional = (flags & CallFlags.optional_chain) != 0;
    const is_pure = (flags & CallFlags.is_pure) != 0;

    if (try tryRewriteRequire(self, callee, args_start, args_len)) return;
    if (try tryEmitGlobObject(self, callee, args_start, args_len)) return;
    if (try tryEmitRequireContextObject(self, node)) return;

    if (is_pure and !self.options.minify_whitespace) try self.write("/* @__PURE__ */ ");
    try self.emitNode(callee);
    if (is_optional) try self.write("?.");
    try self.writeByte('(');
    try self.emitNodeList(args_start, args_len, self.listSep());
    try self.writeByte(')');
}

/// AST 수준 교체 — 문자열 후처리보다 안전 (minify, 문자열 리터럴 내 패턴에 영향 안 받음).
fn tryEmitGlobObject(self: anytype, callee: ast_mod.NodeIndex, args_start: u32, args_len: u32) !bool {
    if (!self.has_glob_records) return false;
    if (callee.isNone() or @intFromEnum(callee) >= self.ast.nodes.items.len) return false;

    const callee_node = self.ast.getNode(callee);
    if (callee_node.tag != .static_member_expression) return false;

    const extras = self.ast.extra_data.items;
    if (callee_node.data.extra + 2 >= extras.len) return false;

    const obj_idx = @as(ast_mod.NodeIndex, @enumFromInt(extras[callee_node.data.extra]));
    const prop_idx = @as(ast_mod.NodeIndex, @enumFromInt(extras[callee_node.data.extra + 1]));
    if (obj_idx.isNone() or prop_idx.isNone()) return false;
    if (@intFromEnum(obj_idx) >= self.ast.nodes.items.len or @intFromEnum(prop_idx) >= self.ast.nodes.items.len) return false;

    const obj_node = self.ast.getNode(obj_idx);
    if (obj_node.tag != .meta_property or obj_node.data.none != 0) return false;

    const prop_node = self.ast.getNode(prop_idx);
    const prop_name = self.ast.getText(prop_node.span);
    if (!std.mem.eql(u8, prop_name, "glob")) return false;

    if (args_len == 0 or args_start >= extras.len) return false;
    const arg0_idx = @as(ast_mod.NodeIndex, @enumFromInt(extras[args_start]));
    if (arg0_idx.isNone() or @intFromEnum(arg0_idx) >= self.ast.nodes.items.len) return false;
    const arg0_node = self.ast.getNode(arg0_idx);
    if (arg0_node.tag != .string_literal) return false;
    const raw = self.ast.getText(arg0_node.span);
    const pattern = Ast.stripStringQuotes(raw);

    for (self.options.import_records) |rec| {
        if (rec.kind != .glob) continue;
        if (!std.mem.eql(u8, rec.specifier, pattern)) continue;

        if (rec.glob_matches) |matches| {
            try self.write("{\n");
            for (matches, 0..) |match_path, i| {
                if (i > 0) try self.write(",\n");
                try self.write("  \"");
                try writeJsStringContent(self, match_path);
                try self.write("\": ");

                if (rec.glob_eager) {
                    if (rec.glob_import_name) |import_name| {
                        try self.write("(await import(\"");
                        try writeJsStringContent(self, match_path);
                        try self.write("\")).");
                        try self.write(import_name);
                    } else {
                        try self.write("await import(\"");
                        try writeJsStringContent(self, match_path);
                        try self.write("\")");
                    }
                } else {
                    if (rec.glob_import_name) |import_name| {
                        try self.write("() => import(\"");
                        try writeJsStringContent(self, match_path);
                        try self.write("\").then(m => m.");
                        try self.write(import_name);
                        try self.write(")");
                    } else {
                        try self.write("() => import(\"");
                        try writeJsStringContent(self, match_path);
                        try self.write("\")");
                    }
                }
            }
            try self.write("\n}");
        } else {
            try self.write("{}");
        }
        return true;
    }

    return false;
}

/// `require.context(...)` 호출을 webpackContext IIFE 로 emit.
/// Metro `contextModuleTemplates.js` 의 sync mode 패턴 mirror.
/// 매칭은 record.span (= call_expression span) 으로 — `tryExtractRequireContextFromCallee`
/// 가 record.span 을 call_span 으로 채우는 invariant 에 의존.
fn tryEmitRequireContextObject(self: anytype, node: Node) !bool {
    if (!self.has_require_context_records) return false;

    const rec: *const ImportRecord = blk: {
        for (self.options.import_records) |*r| {
            if (r.kind == .require_context and std.meta.eql(r.span, node.span))
                break :blk r;
        }
        return false;
    };

    try self.write("(function(){var map={");
    if (rec.context_matches) |matches| {
        for (matches, 0..) |match_path, i| {
            if (i > 0) try self.writeByte(',');
            try self.writeByte('"');
            try writeJsStringContent(self, match_path);
            try self.write("\":function(){return ");
            // RN/Hermes runtime 에는 `require` global 이 없으므로 graph 에 등록된
            // module wrapper 호출로 emit. abs path 가 있으면 직접 호출, 없으면
            // (resolve 실패 등) throw — raw `require()` fallback 은 런타임 폭발 유발.
            const resolved_abs: ?[]const u8 = if (i < rec.context_resolved_paths.len)
                rec.context_resolved_paths[i]
            else
                null;
            if (resolved_abs) |abs| {
                // `ctx(req)` 는 Metro/webpack 의 require.context semantic 대로 module
                // exports 를 반환해야 한다. `fn()` 만 호출하면 init 은 실행되지만 exports
                // 는 undefined — expo-router 가 `ctx(req)` 반환값을 route module 로 사용해
                // tree 구성이 실패하고 "Unmatched Route" 로 fallback.
                // 다른 require 호출과 동일한 `(fn(), __toCommonJS(.exports))` 패턴으로 emit.
                // `__zntc_modules` 의 key 는 모듈 등록 ID — emitter 가 `dev.makeModuleId`
                // 로 normalize 해서 등록하므로 lookup 도 동일 normalize 적용 (#2466 follow-up).
                const id = dev.makeModuleId(abs, self.options.require_context_module_id_root);
                try self.write("(__zntc_modules[\"");
                try writeJsStringContent(self, id);
                try self.write("\"].fn(),__toCommonJS(__zntc_modules[\"");
                try writeJsStringContent(self, id);
                try self.write("\"].exports))");
            } else {
                try self.write("(function(){throw new Error(\"require.context match unresolved: \"+");
                try self.writeByte('"');
                try writeJsStringContent(self, match_path);
                try self.write("\");})()");
            }
            try self.write(";}");
        }
    }
    try self.write(
        \\};function ctx(req){var fn=map[req];if(!fn){var e=new Error("Cannot find module '"+req+"'");e.code="MODULE_NOT_FOUND";throw e;}return fn();}ctx.keys=function(){return Object.keys(map);};ctx.resolve=function(req){if(!(req in map)){var e=new Error("Cannot find module '"+req+"'");e.code="MODULE_NOT_FOUND";throw e;}return req;};return ctx;})()
    );
    return true;
}

/// dir="./pages", match="./a.tsx" → "./pages/a.tsx" (trailing `/`, leading `./` 정규화).
/// Escape 포함 — 경로 세그먼트에 `"`/`\` 가 들어와도 JS 문자열 리터럴이 깨지지 않음.
fn emitJoinedPath(self: anytype, dir: []const u8, match: []const u8) !void {
    const dir_clean = if (dir.len > 0 and dir[dir.len - 1] == '/') dir[0 .. dir.len - 1] else dir;
    const match_clean = if (match.len >= 2 and match[0] == '.' and match[1] == '/') match[2..] else match;
    try writeJsStringContent(self, dir_clean);
    try self.writeByte('/');
    try writeJsStringContent(self, match_clean);
}

/// JS string 내용 부분 (따옴표 제외) 를 escape 해서 출력.
/// `\`, `"`, 제어 문자를 처리 — resolver/FS 경로가 예외적으로 포함할 수 있는 문자 대비.
/// 기존 `writeStringLiteral` 은 이미 quoted 소스 span 을 처리하는 용도라 raw string 에 부적합.
fn writeJsStringContent(self: anytype, s: []const u8) !void {
    var flush_start: usize = 0;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        const esc: ?[]const u8 = switch (c) {
            '\\' => "\\\\",
            '"' => "\\\"",
            '\n' => "\\n",
            '\r' => "\\r",
            '\t' => "\\t",
            0x08 => "\\b",
            0x0C => "\\f",
            else => null,
        };
        if (esc) |e| {
            if (i > flush_start) try self.write(s[flush_start..i]);
            try self.write(e);
            flush_start = i + 1;
        } else if (c < 0x20) {
            if (i > flush_start) try self.write(s[flush_start..i]);
            const hex = "0123456789abcdef";
            var buf: [6]u8 = .{ '\\', 'u', '0', '0', hex[(c >> 4) & 0xF], hex[c & 0xF] };
            try self.write(&buf);
            flush_start = i + 1;
        }
    }
    if (flush_start < s.len) try self.write(s[flush_start..]);
}

/// string_literal 노드에서 specifier를 추출하고 require_rewrites 맵에서 조회.
/// 매칭되면 변수명 반환, 아니면 null. 출력은 하지 않음.
fn resolveRequireRewrite(self: anytype, source: ast_mod.NodeIndex) ?[]const u8 {
    const meta = self.options.linking_metadata orelse return null;
    if (meta.require_rewrites.count() == 0 or source.isNone()) return null;

    const node = self.ast.getNode(source);
    if (node.tag != .string_literal) return null;

    const raw = self.ast.getText(node.data.string_ref);
    const specifier = Ast.stripStringQuotes(raw);

    return meta.require_rewrites.get(specifier);
}

pub fn resolveRequireRewriteSpecifier(self: anytype, specifier: []const u8) ?[]const u8 {
    const meta = self.options.linking_metadata orelse return null;
    if (meta.require_rewrites.count() == 0) return null;
    return meta.require_rewrites.get(specifier);
}

/// rewrite 값을 출력한다. 값이 완전한 표현식('('로 시작)이면 그대로,
/// 변수명이면 "()"를 붙여 호출한다.
pub fn emitRewriteValue(self: anytype, req_var: []const u8) !void {
    try self.write(req_var);
    // (init_xxx(), __toCommonJS(...)) 같은 완전한 표현식은 ()를 붙이지 않음
    if (req_var.len == 0 or req_var[0] != '(') {
        try self.write("()");
    }
}

/// require_xxx() 또는 (init_xxx(), __toCommonJS(...))를 출력. 성공 시 true.
pub fn emitRequireRewriteOrCall(self: anytype, source: ast_mod.NodeIndex) !bool {
    if (resolveRequireRewrite(self, source)) |req_var| {
        try emitRewriteValue(self, req_var);
        return true;
    }
    try self.write("require(");
    try self.emitNode(source);
    try self.writeByte(')');
    return false;
}

/// CJS require('specifier') → require_xxx() 치환. 성공 시 true.
fn tryRewriteRequire(self: anytype, callee: ast_mod.NodeIndex, args_start: u32, args_len: u32) !bool {
    if (callee.isNone() or args_len != 1) return false;

    const callee_node = self.ast.getNode(callee);
    if (callee_node.tag != .identifier_reference) return false;

    const callee_text = self.ast.getText(callee_node.data.string_ref);
    if (!std.mem.eql(u8, callee_text, "require")) return false;

    if (args_start >= self.ast.extra_data.items.len) return false;
    const arg_idx: ast_mod.NodeIndex = @enumFromInt(self.ast.extra_data.items[args_start]);

    if (resolveRequireRewrite(self, arg_idx)) |req_var| {
        try emitRewriteValue(self, req_var);
        return true;
    }
    return false;
}

/// `new MemberExpression Arguments` 문법상 callee 는 MemberExpression 이어야 함.
/// callee 의 member chain 안에 call_expression 이 있으면 `new A(x)` 가 `new (A)(x)` 로
/// 잘못 파싱되어 뒤따르는 `()` 가 외부 call 로 붙음 (#1507). 감싸서 Primary 로 승격.
fn newCalleeNeedsParens(self: anytype, idx: NodeIndex) bool {
    var cur = idx;
    while (true) {
        const n = self.ast.getNode(cur);
        switch (n.tag) {
            .call_expression => return true,
            .identifier_reference => return identifierRenameContainsCall(self, cur),
            .static_member_expression, .computed_member_expression, .private_field_expression => {
                cur = self.ast.readExtraNode(n.data.extra, 0);
            },
            // `new MemberExpression` callee 슬롯이 아닌 expression: paren 을 벗기면 결합이 깨진다.
            // `new (a||b)()` → `new a||b()` 가 `(new a)||b()` 로 결합 (#2960).
            // function/class expression 은 PrimaryExpression 이라 callee 슬롯에 직접 가능 (#1586).
            .logical_expression,
            .binary_expression,
            .conditional_expression,
            .assignment_expression,
            .sequence_expression,
            .arrow_function_expression,
            .new_expression,
            .yield_expression,
            .await_expression,
            .import_expression,
            .unary_expression,
            .update_expression,
            => return true,
            else => return false,
        }
    }
}

/// `new Animated.Value()` 처럼 AST callee 자체에는 call 이 없더라도, linker rename 후
/// `Animated`가 `require_xxx().Animated` 같은 call 포함 표현식으로 바뀔 수 있다.
/// 이때 `new require_xxx().Animated.Value()`는 생성자 결합이 달라지므로 callee 전체를
/// 괄호로 감싸야 한다.
fn identifierRenameContainsCall(self: anytype, idx: NodeIndex) bool {
    const meta = self.options.linking_metadata orelse return false;
    const sid = self.resolveSymbolId(idx, meta) orelse return false;
    const rename = meta.renames.get(sid) orelse return false;
    return std.mem.indexOf(u8, rename, "()") != null;
}

/// import.meta.url 의 출력 형태를 한 곳에서 결정 (drift 방지).
/// - ESM 출력: `import.meta.url` 그대로
/// - CJS/replace_import_meta + node: `require("url").pathToFileURL(__filename).href`
/// - CJS/replace_import_meta + browser/neutral: `""`
/// emitMember 의 import.meta.url 분기 + emitNew 의 worker URL 두 번째 인자가 공유.
pub fn writeImportMetaUrl(self: anytype) !void {
    if (self.options.module_format == .cjs or self.options.replace_import_meta) {
        if (self.options.platform == .node) {
            try self.write(IMPORT_META_URL_NODE);
            return;
        }
        try self.write("\"\"");
        return;
    }
    try self.write("import.meta.url");
}

/// `new URL("specifier", import.meta.url)` 가 worker 등록된 specifier 를 가리키면
/// `new URL("./<filename>", <import.meta.url polyfill>)` 로 직접 emit. 매칭 시 true 반환.
/// graph.zig 가 worker_threads 패턴을 detect 해 worker_map 에 등록 → codegen 은 lookup 만.
/// 매칭 안 되면 평범한 emitNew 흐름으로 fallback.
fn tryEmitWorkerURL(self: anytype, callee: ast_mod.NodeIndex, args_start: u32, args_len: u32) !bool {
    const worker_map = self.options.worker_map orelse return false;
    if (worker_map.count() == 0 or args_len == 0) return false;

    const callee_node = self.ast.getNode(callee);
    if (callee_node.tag != .identifier_reference) return false;
    if (!std.mem.eql(u8, self.ast.getText(callee_node.span), "URL")) return false;

    const extras = self.ast.extra_data.items;
    if (args_start >= extras.len) return false;
    const arg0_idx: ast_mod.NodeIndex = @enumFromInt(extras[args_start]);
    if (arg0_idx.isNone() or @intFromEnum(arg0_idx) >= self.ast.nodes.items.len) return false;
    const arg0_node = self.ast.getNode(arg0_idx);
    if (arg0_node.tag != .string_literal) return false;
    const spec = Ast.stripStringQuotes(self.ast.getText(arg0_node.span));

    const filename = worker_map.get(spec) orelse return false;

    try self.write("new URL(\"./");
    try self.write(filename);
    try self.write("\", ");
    try writeImportMetaUrl(self);
    try self.writeByte(')');
    return true;
}

pub fn emitNew(self: anytype, node: Node) !void {
    const e = node.data.extra;
    if (!self.ast.hasExtra(e, 3)) return;
    var callee = self.ast.readExtraNode(e, 0);
    const args_start = self.ast.readExtra(e, 1);
    const args_len = self.ast.readExtra(e, 2);
    const flags = self.ast.readExtra(e, 3);
    const CallFlags = ast_mod.CallFlags;
    const is_pure = (flags & CallFlags.is_pure) != 0;

    if (is_pure and !self.options.minify_whitespace) try self.write("/* @__PURE__ */ ");

    if (try tryEmitWorkerURL(self, callee, args_start, args_len)) return;

    try self.write("new ");
    // 원본의 잉여 parens 제거 (#1586): callee가 `(inner)` 형태이고 inner를
    // 직접 새 callee로 써도 `new MemberExpression` 문법이 깨지지 않으면 벗긴다.
    // newCalleeNeedsParens가 이미 call-chain 안전성을 판정하므로 재사용.
    if (self.options.minify_syntax) {
        while (true) {
            const cn = self.ast.getNode(callee);
            if (cn.tag != .parenthesized_expression) break;
            const inner = cn.data.unary.operand;
            if (newCalleeNeedsParens(self, inner)) break;
            callee = inner;
        }
    }
    const needs_parens = newCalleeNeedsParens(self, callee);
    if (needs_parens) try self.writeByte('(');
    try self.emitNode(callee);
    if (needs_parens) try self.writeByte(')');
    try self.writeByte('(');
    try self.emitNodeList(args_start, args_len, self.listSep());
    try self.writeByte(')');
}

/// import.meta → 플랫폼별 polyfill.
/// - ESM 출력: 그대로 유지
/// - CJS/번들 non-ESM + node: {url:require("url").pathToFileURL(__filename).href,dirname:__dirname,filename:__filename}
/// - CJS/번들 non-ESM + browser/neutral: {}
/// Node.js는 import.meta를 보면 ESM으로 재파싱하므로 제거 필요
/// import.meta.X 접근인지 확인하고 프로퍼티 이름을 반환. 아니면 null.
pub fn resolveImportMetaProp(self: anytype, object: NodeIndex, property: NodeIndex) ?[]const u8 {
    const obj_node = self.ast.getNode(object);
    if (obj_node.tag != .meta_property) return null;
    const obj_text = self.ast.getText(obj_node.span);
    if (!std.mem.eql(u8, obj_text, "import.meta")) return null;
    const prop_node = self.ast.getNode(property);
    return self.ast.getText(prop_node.data.string_ref);
}

pub fn emitMetaProperty(self: anytype, node: Node) !void {
    const text = self.ast.getText(node.span);
    if (std.mem.eql(u8, text, "import.meta")) {
        if (self.options.module_format == .cjs or self.options.replace_import_meta) {
            if (self.options.platform == .node) {
                try self.write(IMPORT_META_NODE_OBJECT);
            } else {
                try self.write("{}");
            }
            return;
        }
    }
    try self.writeNodeSpan(node);
}

pub fn emitImportExpr(self: anytype, node: Node) !void {
    try self.write("import(");
    try self.emitNode(node.data.binary.left);
    if (!node.data.binary.right.isNone()) {
        try self.write(if (self.options.minify_whitespace) "," else ", ");
        try self.emitNode(node.data.binary.right);
    }
    try self.writeByte(')');
}
