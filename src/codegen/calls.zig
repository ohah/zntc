//! Codegen helpers for call/new/import.meta/require-style runtime expressions.

const std = @import("std");
const ast_mod = @import("../parser/ast.zig");
const Ast = ast_mod.Ast;
const Node = ast_mod.Node;
const NodeIndex = ast_mod.NodeIndex;
const dev = @import("../bundler/emitter/dev.zig");
const ImportRecord = @import("../bundler/types.zig").ImportRecord;
const precedence = @import("precedence.zig");
const Level = precedence.Level;
const ExprFlags = precedence.ExprFlags;

const IMPORT_META_URL_NODE = "require(\"url\").pathToFileURL(__filename).href";
const IMPORT_META_NODE_OBJECT = "{url:" ++ IMPORT_META_URL_NODE ++ ",dirname:__dirname,filename:__filename}";

/// transparent wrapper 를 벗겨 실제 노드를 반환. chain_expression + TS/Flow type cast
/// (`as T`/`<T>x`/`!`)는 항상 벗긴다. `include_paren=true` 면 parenthesized_expression 도
/// 벗긴다(출력 토큰 기준 — emitParen 투명). `false` 면 paren 은 경계로 남긴다 —
/// optional chain 을 끊으므로(`(a?.b).c` 의 `.c` 는 None, `a?.b!.c` 의 `.c` 는 Continue).
/// codegen 의 wrapper-skip 3종(투명검사/type-only/optional-chain)을 단일화.
pub fn skipWrappers(self: anytype, idx: NodeIndex, comptime include_paren: bool) NodeIndex {
    var cur = idx;
    var depth: u8 = 0;
    while (depth < 32) : (depth += 1) {
        if (cur.isNone() or @intFromEnum(cur) >= self.ast.nodes.items.len) return cur;
        const n = self.ast.getNode(cur);
        const transparent = n.tag == .chain_expression or
            ast_mod.Node.Tag.isTransparentTypeWrapper(n.tag) or
            (include_paren and n.tag == .parenthesized_expression);
        if (transparent) cur = n.data.unary.operand else return cur;
    }
    return cur;
}

/// `object` 가 (paren 을 건너지 않고 type-wrapper 만 건너서) optional `?.` 로 시작/연속되는
/// 체인인지 — 이 멤버/호출이 esbuild 의 OptionalChainContinue(체인 연속)인지 판정한다.
/// zntc 파서는 chain_expression 없이 paren 노드로만 체인을 끊으므로(transformer/define.zig
/// 주석) 트리 구조에서 유도한다: `a?.b.c` 의 `.c` 는 object(`a?.b`)가 optional → Continue
/// (끊지 않음), `(a?.b).c` 의 `.c` 는 object 가 paren → 체인 끊김 → None(끊음).
/// 단일 구현 `ast.spineHasOptionalChain` 에 위임(transformer 와 공용).
pub fn objectContinuesOptionalChain(self: anytype, idx: NodeIndex) bool {
    return ast_mod.spineHasOptionalChain(self.ast, idx);
}

/// expression 이 (paren 포함 transparent wrapper 를 벗긴 뒤) optional chain(Start/Continue)인지.
/// tagged template 의 tag 가 optional chain 이면 ECMAScript 상 SyntaxError 라 괄호로 감싸야
/// 한다 (esbuild ETemplate: `IsOptionalChain(tag)` → wrap). paren 까지 벗기는 이유는 emit 시
/// 투명 paren 이 사라져 `(a?.b)`x`` 가 `a?.b`x``(invalid)로 깨지기 때문.
pub fn isOptionalChainExpr(self: anytype, idx: NodeIndex) bool {
    // paren 까지 벗긴(출력 토큰 기준) 실제 노드가 chain 인지.
    return objectContinuesOptionalChain(self, skipWrappers(self, idx, true));
}

/// `undefined` peephole 의 callee/object/new.callee 슬롯 paren 검사.
/// node_dispatch.zig 가 `void 0` (no paren) 으로 출력하므로, member/call/new 슬롯의
/// caller 가 paren 으로 감싸 `void 0.x` → `void (0.x)` 오파싱 방지.
pub fn isUndefinedPeephole(self: anytype, idx: NodeIndex) bool {
    if (!self.options.minify_syntax) return false;
    if (idx.isNone() or @intFromEnum(idx) >= self.ast.nodes.items.len) return false;
    const n = self.ast.getNode(idx);
    if (n.tag != .identifier_reference) return false;
    const sym_id = if (self.options.linking_metadata) |meta|
        self.resolveSymbolId(idx, meta)
    else
        null;
    if (sym_id != null) return false;
    return std.mem.eql(u8, self.ast.getText(n.span), "undefined");
}

/// callee 가 (래퍼 없이) 직접 function expression 인지 — IIFE auto-paren 대상.
/// esbuild 가 `ECall` 의 target 이 `EFunction` 이면 `IsParenthesized=true` 로 마킹하는 것과
/// 동형. paren(function)(source IIFE)은 emitParen 이 보존하므로 *직접* 노드만 검사해
/// 이중괄호를 피한다. arrow 는 .postfix(call-target) level 로 이미 wrap 돼 여기 불필요.
fn calleeIsBareFunctionExpr(self: anytype, idx: NodeIndex) bool {
    if (idx.isNone() or @intFromEnum(idx) >= self.ast.nodes.items.len) return false;
    return switch (self.ast.getNode(idx).tag) {
        .function_expression, .function => true,
        else => false,
    };
}

/// `void 0` peephole 가 적용될 자식 노드를 paren 으로 감싸 emit. 자식이 그 외엔 그대로 emit.
/// callee/object/new.callee 슬롯 4곳에서 공유 — 정책은 [[isUndefinedPeephole]].
pub fn emitNodeMaybeUndefParen(self: anytype, idx: NodeIndex, level: Level, flags: ExprFlags) !void {
    const need = isUndefinedPeephole(self, idx);
    if (need) try self.writeByte('(');
    try self.emitExpr(idx, level, flags);
    if (need) try self.writeByte(')');
}

pub fn emitCall(self: anytype, node: Node, level: Level, flags: ExprFlags) !void {
    _ = level; // wrap(level>=.new | forbid_call | optional-chain | pure) 은 exprNeedsParens 중앙 처리.
    _ = flags; // callee 의 has_non_optional_chain_parent 는 call 자신의 optional-ness 로 계산
    // (incoming flags 전파 안 함). forbid_call 도 callee 로 전파 안 함 — esbuild ECall parity.
    try self.addSourceMapping(node.span);
    const e = node.data.extra;
    if (!self.ast.hasExtra(e, 3)) return;
    const callee = self.ast.readExtraNode(e, 0);
    const args_start = self.ast.readExtra(e, 1);
    const args_len = self.ast.readExtra(e, 2);
    const call_flags = self.ast.readExtra(e, 3);
    const CallFlags = ast_mod.CallFlags;
    const is_optional = (call_flags & CallFlags.optional_chain) != 0;
    const is_pure = (call_flags & CallFlags.is_pure) != 0;

    if (try tryRewriteRequire(self, callee, args_start, args_len)) return;
    if (try tryEmitGlobObject(self, callee, args_start, args_len)) return;
    if (try tryEmitRequireContextObject(self, node)) return;

    // pure-comment 가 버퍼 위치를 밀면 callee(예: stmt-start 의 function expression)가
    // statement-start 마크와 어긋난다 → save/restore 로 마크를 comment 뒤로 옮긴다
    // (esbuild ECall). 그래야 `/* @__PURE__ */ (function(){})()` 의 괄호가 살아난다.
    if (is_pure and !self.options.minify_whitespace) {
        const start_flags = self.saveExprStartFlags();
        try self.write("/* @__PURE__ */ ");
        self.restoreExprStartFlags(start_flags);
    }
    // callee level = .postfix. self 가 None(체인 밖)이면 callee 에 has_non_optional_chain_parent
    // set(callee 가 optional-chain start/continue 면 exprNeedsParens 가 wrap). forbid_call 은
    // 전파 안 함 — call 이 자기 wrap 에서 소진(esbuild ECall parity).
    const self_in_chain = is_optional or objectContinuesOptionalChain(self, callee);
    const callee_flags = ExprFlags{ .has_non_optional_chain_parent = !self_in_chain };
    // IIFE: callee 가 *직접* function expression 이면 괄호로 감싼다 (esbuild 가 ECall target
    // 이 EFunction 이면 IsParenthesized 자동 마킹하는 것과 동형, `function(){}()`→`(function(){})()`).
    // source `(function(){})()` 는 callee=paren(function)이라 직접 노드가 아니어서 emitParen 이
    // 보존(이중괄호 회피). arrow 는 .postfix(call-target) level 로 exprNeedsParens 가 이미 wrap.
    const iife_wrap = calleeIsBareFunctionExpr(self, callee);
    if (iife_wrap) try self.writeByte('(');
    try emitNodeMaybeUndefParen(self, callee, Level.postfix, callee_flags);
    if (iife_wrap) try self.writeByte(')');
    if (is_optional) try self.write("?.");
    try self.writeByte('(');
    try self.emitExpressionNodeList(args_start, args_len, self.listSep());
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

    var rec_index: usize = 0;
    const rec: *const ImportRecord = blk: {
        for (self.options.import_records, 0..) |*r, ri| {
            if (r.kind == .require_context and std.meta.eql(r.span, node.span)) {
                rec_index = ri;
                break :blk r;
            }
        }
        return false;
    };
    // emitter 가 미리 계산한 init-call 참조 (code_splitting / production 단일번들 —
    // `__zntc_modules` 미사용 경로). null/빈 슬라이스면 dev 단일번들 → __zntc_modules fallback.
    const init_refs: []const ?[]const u8 = if (rec_index < self.options.require_context_init_refs.len)
        self.options.require_context_init_refs[rec_index]
    else
        &.{};

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
            // emitter 가 init-call 참조를 계산했으면(code_splitting/production 단일번들)
            // `(init_X(),__toCommonJS(exports_X))` 직접 참조 — `__zntc_modules`(dev 전용,
            // 청크 경계 미지원)를 우회(issue #4039 + production require.context).
            const pre_ref: ?[]const u8 = if (i < init_refs.len) init_refs[i] else null;
            if (pre_ref) |ref| {
                try self.write(ref);
            } else if (resolved_abs) |abs| {
                // dev 단일번들: `ctx(req)` 는 Metro/webpack semantic 대로 module exports 를
                // 반환해야 한다. `__zntc_modules` 의 key 는 `dev.makeModuleId` normalize 한
                // 등록 ID (#2466). HMR 런타임(dev_mode)이 `__zntc_modules` 를 주입한다.
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

/// `new Animated.Value()` 처럼 callee 자체엔 call 이 없어도 linker rename 후
/// `Animated`가 `require_x().Animated` 같은 call 포함 표현식으로 바뀌면 `new` 의 첫
/// `()` 가 그 call 에 붙어 `(new require_x()).Animated.Value()` 로 결합이 달라진다 →
/// member chain 의 leaf 식별자가 rename→call 이면 callee 전체를 괄호로 감싼다.
/// AST 노드로는 식별자(identifier_reference)라 precedence(AST 기반)가 못 잡는 유일한
/// new-callee 케이스이므로 ad-hoc 으로 유지 (#4042 PR7). 나머지(callee 안의 call/
/// binary/conditional/sequence/… )는 precedence(.new + forbid_call)가 재유도한다.
fn newCalleeNeedsRenameParens(self: anytype, idx: NodeIndex) bool {
    var cur = idx;
    while (true) {
        const n = self.ast.getNode(cur);
        switch (n.tag) {
            .identifier_reference => return identifierRenameContainsCall(self, cur),
            .static_member_expression, .computed_member_expression, .private_field_expression => {
                cur = self.ast.readExtraNode(n.data.extra, 0);
            },
            // paren 은 투명(codegen 이 괄호 미출력) — 안쪽으로 따라가 rename leaf 검사.
            .parenthesized_expression => cur = n.data.unary.operand,
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

pub fn emitNew(self: anytype, node: Node, level: Level, flags: ExprFlags) !void {
    _ = level; // wrap(level>=.call | pure-comment) 은 exprNeedsParens 중앙 처리.
    _ = flags;
    try self.addSourceMapping(node.span);
    const e = node.data.extra;
    if (!self.ast.hasExtra(e, 3)) return;
    const callee = self.ast.readExtraNode(e, 0);
    const args_start = self.ast.readExtra(e, 1);
    const args_len = self.ast.readExtra(e, 2);
    const new_flags = self.ast.readExtra(e, 3);
    const CallFlags = ast_mod.CallFlags;
    const is_pure = (new_flags & CallFlags.is_pure) != 0;

    if (is_pure and !self.options.minify_whitespace) try self.write("/* @__PURE__ */ ");

    if (try tryEmitWorkerURL(self, callee, args_start, args_len)) return;

    try self.write("new ");
    // callee 의 군더더기 괄호(`new (a)()`)는 emitParen 투명화가 제거하고, callee 안에
    // call/binary/conditional/sequence 등이 섞이면 precedence(.new + forbid_call)가
    // 괄호를 재유도한다. precedence 가 못 잡는 건 rename→call 체인(식별자)뿐이라 그것만 ad-hoc.
    const needs_parens = newCalleeNeedsRenameParens(self, callee);
    if (needs_parens) try self.writeByte('(');
    // callee = .new + forbid_call + has_non_optional_chain_parent(set): `new (foo())` 보존 +
    // optional chain 끊기(`new (a?.b)()`/`new (a?.b.c)()`/`new (a?.[b])()` — new 의 첫 `()` 가
    // optional chain 안으로 들어가면 SyntaxError). new 타겟은 member object 처럼 non-optional
    // 체인 부모다. `undefined`→`void 0` peephole 슬롯이라 emitNodeMaybeUndefParen 경유.
    try emitNodeMaybeUndefParen(self, callee, Level.new, .{ .forbid_call = true, .has_non_optional_chain_parent = true });
    if (needs_parens) try self.writeByte(')');
    try self.writeByte('(');
    try self.emitExpressionNodeList(args_start, args_len, self.listSep());
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
    try self.addSourceMapping(node.span);
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

pub fn emitImportExpr(self: anytype, node: Node, level: Level, flags: ExprFlags) !void {
    _ = level;
    _ = flags;
    try self.addSourceMapping(node.span);
    try self.write("import(");
    // specifier / options 는 argument 위치 → .comma (esbuild EImportCall).
    try self.emitExpr(node.data.binary.left, .comma, .{});
    if (!node.data.binary.right.isNone()) {
        try self.write(if (self.options.minify_whitespace) "," else ", ");
        try self.emitExpr(node.data.binary.right, .comma, .{});
    }
    try self.writeByte(')');
}
