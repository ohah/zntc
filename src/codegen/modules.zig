//! Codegen module import/export emission helpers.

const std = @import("std");
const ast_mod = @import("../parser/ast.zig");
const Node = ast_mod.Node;
const NodeIndex = ast_mod.NodeIndex;
const module_parser = @import("../parser/module.zig");
const rt = @import("../bundler/runtime_helpers.zig");
const linker_mod = @import("../bundler/linker.zig");

pub fn emitImport(self: anytype, node: Node) !void {
    try self.addSourceMapping(node.span);
    const x = module_parser.readImportDeclExtras(self.ast, node.data.extra);

    // `import type { ... }` / `import type X from ...` 같은 declaration-level type-only
    // 는 codegen 단계에서 전체 strip. parser 가 AST 를 보존하는 이유는 semantic 단계의
    // export 검증 + Phase D 의 type-only elision 정보 통합 — runtime 출력엔 흔적 X.
    if (x.is_type_only) return;

    if (self.options.module_format == .cjs) {
        return emitImportCJS(self, x.source, x.specs_start, x.specs_len);
    }

    try self.write("import ");
    switch (x.phase) {
        .defer_ => try self.write("defer "),
        .source => try self.write("source "),
        .none => {},
    }
    if (x.specs_len > 0) {
        try emitImportSpecifiers(self, x.specs_start, x.specs_len);
        try self.write(" from ");
    }
    try self.emitNode(x.source);
    if (x.attrs_len > 0) {
        try self.write(" with ");
        try emitImportAttributes(self, x.attrs_start, x.attrs_len);
    }
    try self.writeByte(';');
}

pub fn emitImportAttributes(self: anytype, attrs_start: u32, attrs_len: u32) !void {
    try self.writeByte('{');
    const indices = self.ast.extra_data.items[attrs_start .. attrs_start + attrs_len];
    for (indices, 0..) |raw_idx, i| {
        if (i > 0) try self.write(", ");
        const attr_node = self.ast.getNode(@enumFromInt(raw_idx));
        // 키는 identifier 또는 string literal — string_literal emit의 quote-strip을 피해 raw span 사용.
        const key_node = self.ast.getNode(attr_node.data.binary.left);
        try self.writeNodeSpan(key_node);
        try self.write(": ");
        const value = attr_node.data.binary.right;
        if (!value.isNone()) try self.emitNode(value);
    }
    try self.writeByte('}');
}

/// import specifiers를 타입별로 출력한다.
/// default → 이름만, namespace → * as 이름, named → { a, b }
pub fn emitImportSpecifiers(self: anytype, specs_start: u32, specs_len: u32) !void {
    const spec_indices = self.ast.extra_data.items[specs_start .. specs_start + specs_len];
    var first = true;
    var has_named = false;

    // 1단계: default, namespace 출력
    for (spec_indices) |raw_idx| {
        const spec: NodeIndex = @enumFromInt(raw_idx);
        if (spec.isNone()) continue;
        const spec_node = self.ast.getNode(spec);
        switch (spec_node.tag) {
            .import_default_specifier => {
                if (!first) try self.write(",");
                try self.addSourceMapping(spec_node.span);
                try self.writeNodeSpan(spec_node);
                first = false;
            },
            .import_namespace_specifier => {
                if (!first) try self.write(",");
                try self.write("* as ");
                try self.addSourceMapping(spec_node.span);
                try self.writeNodeSpan(spec_node);
                first = false;
            },
            .import_specifier => {
                has_named = true;
            },
            else => {},
        }
    }

    // 2단계: named specifiers를 { } 감싸서 출력
    if (has_named) {
        if (!first) try self.write(", ");
        try self.writeByte('{');
        if (!self.options.minify_whitespace) try self.writeByte(' ');
        const sep: []const u8 = self.listSep();
        var named_first = true;
        for (spec_indices) |raw_idx| {
            const spec: NodeIndex = @enumFromInt(raw_idx);
            if (spec.isNone()) continue;
            const spec_node = self.ast.getNode(spec);
            if (spec_node.tag == .import_specifier) {
                if (!named_first) try self.write(sep);
                try emitImportSpecifierRename(self, spec_node, " as ");
                named_first = false;
            }
        }
        if (!self.options.minify_whitespace) try self.writeByte(' ');
        try self.writeByte('}');
    }
}

/// CJS: import { foo } from './bar' → const {foo}=require('./bar');
/// CJS: import bar from './bar' → const bar=require('./bar').default;
/// CJS: import * as bar from './bar' → const bar=require('./bar');
/// __esm 래핑 모듈: const → var (호이스팅 지원)
pub fn emitImportCJS(self: anytype, source: NodeIndex, specs_start: u32, specs_len: u32) !void {
    if (specs_len == 0) {
        _ = try self.emitRequireRewriteOrCall(source);
        try self.writeByte(';');
        return;
    }

    // specifier 유형 분석 (키워드 생략 판단에 필요)
    const spec_indices = self.ast.extra_data.items[specs_start .. specs_start + specs_len];
    var has_default = false;
    var has_namespace = false;
    var named_count: u32 = 0;

    for (spec_indices) |raw_idx| {
        const spec = self.ast.getNode(@enumFromInt(raw_idx));
        switch (spec.tag) {
            .import_default_specifier => has_default = true,
            .import_namespace_specifier => has_namespace = true,
            .import_specifier => named_count += 1,
            else => {},
        }
    }

    // named import만 있고 모든 named binding이 expression rename이면
    // import 선언을 skip한다. CJS named import는 `require_xxx().prop`
    // 직접 참조로 치환되므로 body의 destructuring assignment가 불필요하다.
    if (named_count > 0 and !has_default and !has_namespace and self.options.linking_metadata != null) {
        const meta = self.options.linking_metadata.?;
        var all_expr_renamed = true;
        for (spec_indices) |raw_idx| {
            const spec = self.ast.getNode(@enumFromInt(raw_idx));
            if (spec.tag != .import_specifier) continue;
            const local_idx = spec.data.binary.right;
            if (!local_idx.isNone()) {
                if (self.resolveSymbolId(local_idx, meta)) |sid| {
                    if (meta.renames.get(sid)) |rename| {
                        if (!linker_mod.isImportExpressionRename(rename)) {
                            all_expr_renamed = false;
                            break;
                        }
                    } else {
                        all_expr_renamed = false;
                        break;
                    }
                } else {
                    all_expr_renamed = false;
                    break;
                }
            }
        }
        if (all_expr_renamed) return;
    }

    // __esm 호이스팅: var 선언이 래퍼 밖에 있으므로 body에서는 할당만.
    // named import ({a, b})는 destructuring assignment — var 생략 시 ({a,b}=expr) 괄호 필요.
    const skip_keyword = self.options.esm_var_assign_only;
    if (!skip_keyword)
        try self.write(if (self.options.use_var_for_imports) "var " else "const ");

    // named destructuring assignment: ({a,b}=expr); — 괄호 없으면 block으로 파싱됨
    // default+named 동시 (import Foo, {Bar}) 도 named 경로로 들어가므로 괄호 필요
    const needs_paren = skip_keyword and named_count > 0 and !has_namespace;
    if (needs_paren) try self.writeByte('(');

    if (has_namespace) {
        // import * as bar from './bar' → [var] bar=require('./bar');
        for (spec_indices) |raw_idx| {
            const spec = self.ast.getNode(@enumFromInt(raw_idx));
            if (spec.tag == .import_namespace_specifier) {
                try emitSpecifierWithRename(self, @enumFromInt(raw_idx), spec);
                break;
            }
        }
    } else if (has_default and named_count == 0) {
        // import bar from './bar' → [var] bar=require('./bar').default;
        for (spec_indices) |raw_idx| {
            const spec = self.ast.getNode(@enumFromInt(raw_idx));
            if (spec.tag == .import_default_specifier) {
                try emitSpecifierWithRename(self, @enumFromInt(raw_idx), spec);
                break;
            }
        }
    } else if (named_count > 0) {
        // import { foo, bar as baz } from './bar' → const {foo,bar:baz}=require('./bar');
        // import Foo, { bar } from './bar' → const {"default":Foo,bar}=require('./bar');
        try self.writeByte('{');
        var first = true;
        if (has_default) {
            for (spec_indices) |raw_idx| {
                const spec = self.ast.getNode(@enumFromInt(raw_idx));
                if (spec.tag == .import_default_specifier) {
                    try self.write("\"default\":");
                    try emitSpecifierWithRename(self, @enumFromInt(raw_idx), spec);
                    first = false;
                    break;
                }
            }
        }
        for (spec_indices) |raw_idx| {
            const spec = self.ast.getNode(@enumFromInt(raw_idx));
            if (spec.tag == .import_specifier) {
                if (!first) try self.writeByte(',');
                try emitImportSpecifierRename(self, spec, ":");
                first = false;
            }
        }
        try self.writeByte('}');
    }

    try self.writeByte('=');

    // __esm body에서 default/namespace import: __toESM(require_xxx()) 래핑 필요.
    // CJS module.exports = fn 패턴에서 .default 프로퍼티가 없으므로 __toESM이
    // 모듈 전체를 default로 설정해준다. default+named 혼합 시에도 적용 —
    // __toESM이 __esModule 체크 후 프로퍼티를 복사하므로 named 접근도 정상 동작.
    const wrap_toesm = self.options.esm_var_assign_only and (has_default or has_namespace);
    if (wrap_toesm) {
        // #1621: minify 시 __toESM → $tE 축약.
        try self.write(if (self.options.minify_whitespace) rt.NAMES.TOESM_MIN else "__toESM");
        try self.writeByte('(');
    }
    _ = try self.emitRequireRewriteOrCall(source);
    if (wrap_toesm) try self.writeByte(')');

    if (has_default and !has_namespace and named_count == 0) {
        try self.write(".default");
    }

    if (needs_paren) try self.writeByte(')');
    try self.writeByte(';');
}

/// import_default_specifier / import_namespace_specifier의 이름을 renames 적용하여 출력.
/// 이 노드들은 identifier_reference가 아니라 별도 태그이므로 emitNode에서 renames를 거치지 않음.
pub fn emitSpecifierWithRename(self: anytype, idx: NodeIndex, spec: Node) !void {
    try self.addSourceMapping(spec.span);
    if (self.options.linking_metadata) |meta| {
        const ni = @intFromEnum(idx);
        if (ni < meta.symbol_ids.len) {
            if (meta.symbol_ids[ni]) |sid| {
                if (meta.renames.get(sid)) |renamed| {
                    try self.write(renamed);
                    return;
                }
            }
        }
    }
    try self.writeSpan(spec.data.string_ref);
}

/// import specifier의 imported + rename separator + local 출력.
/// ESM은 " as ", CJS는 ":" 를 separator로 사용한다.
/// imported 쪽은 항상 원본 이름을 사용 (exports 객체의 프로퍼티 키).
/// local 쪽은 rename 적용 (로컬 변수명).
pub fn emitImportSpecifierRename(self: anytype, spec_node: Node, sep: []const u8) !void {
    const imported = spec_node.data.binary.left;
    const local = spec_node.data.binary.right;
    // imported: 항상 원본 이름 (exports 객체 키 = rename 전 이름)
    const imported_node = self.ast.getNode(imported);
    try self.addSourceMapping(imported_node.span);
    try self.writeSpan(imported_node.span);
    // local이 rename 되었거나 원본 imported와 다른 경우 → separator + local 출력
    const needs_rename = blk: {
        if (local.isNone() or @intFromEnum(local) == @intFromEnum(imported)) break :blk false;
        // 원본 텍스트가 다르면 항상 rename 필요 (import { foo as bar })
        const imp_text = self.ast.getText(self.ast.getNode(imported).span);
        const loc_text = self.ast.getText(self.ast.getNode(local).span);
        if (!std.mem.eql(u8, imp_text, loc_text)) break :blk true;
        // 원본 텍스트가 같아도 linker가 rename했으면 separator 필요
        // (e.g., import { Foo } → {Foo: Foo$1})
        if (self.options.linking_metadata) |meta| {
            if (self.resolveSymbolId(local, meta)) |sid| {
                if (meta.renames.get(sid)) |_| break :blk true;
            }
        }
        break :blk false;
    };
    if (needs_rename) {
        try self.write(sep);
        try self.emitNode(local);
    }
}

pub fn emitExportNamed(self: anytype, node: Node) !void {
    try self.addSourceMapping(node.span);
    const x = module_parser.readExportNamedExtras(self.ast, node.data.extra);

    if (self.options.module_format == .cjs) {
        return emitExportNamedCJS(self, x.decl, x.specs_start, x.specs_len, x.source);
    }

    // 번들 모드: export 키워드 생략, declaration만 출력.
    // 단일 파일 transpile 은 rename map 전달용으로만 linking_metadata 를 쓰므로 분기 제외.
    if (self.options.linking_metadata) |lm| {
        if (lm.is_bundle_context and !x.decl.isNone()) {
            try self.emitNode(x.decl);
            return;
        }
    }

    try self.write("export ");
    if (!x.decl.isNone()) {
        try self.emitNode(x.decl);
    } else {
        try self.writeByte('{');
        if (self.options.minify_whitespace) {
            try self.emitNodeList(x.specs_start, x.specs_len, ",");
        } else {
            try self.writeByte(' ');
            try self.emitNodeList(x.specs_start, x.specs_len, ", ");
            try self.writeByte(' ');
        }
        try self.writeByte('}');
        if (!x.source.isNone()) {
            try self.write(" from ");
            try self.emitNode(x.source);
            if (x.attrs_len > 0) {
                try self.write(" with ");
                try emitImportAttributes(self, x.attrs_start, x.attrs_len);
            }
        }
        try self.writeByte(';');
    }
}

/// ESM export specifier: `foo` 또는 `foo as bar`
/// writeNodeSpan 대신 사용 — 원본 span에 공백이 포함될 수 있으므로 구조적으로 출력.
pub fn emitExportSpecifier(self: anytype, node: Node) !void {
    const local_idx = node.data.binary.left;
    const exported_idx = node.data.binary.right;
    const local_node = self.ast.getNode(local_idx);
    const exported_node = self.ast.getNode(exported_idx);
    const local_text = self.ast.getText(local_node.span);
    const exported_text = self.ast.getText(exported_node.span);
    try self.addSourceMapping(local_node.span);
    try self.write(local_text);
    if (!std.mem.eql(u8, local_text, exported_text)) {
        try self.write(" as ");
        try self.addSourceMapping(exported_node.span);
        try self.write(exported_text);
    }
}

/// CJS: export const x = 1 → const x=1;exports.x=x;
/// CJS: export { foo } → exports.foo=foo;
/// CJS: export { foo, default as Bar } from './bar' → exports.foo=require("./bar").foo;exports.Bar=require("./bar").default;
pub fn emitExportNamedCJS(self: anytype, decl: NodeIndex, specs_start: u32, specs_len: u32, source: NodeIndex) !void {
    if (self.options.skip_cjs_named_export_decls) return;

    if (!decl.isNone() and @intFromEnum(decl) < self.ast.nodes.items.len) {
        // export const x = 1 → const x=1; (+ exports.x=x; unless __esm)
        try self.emitNode(decl);
        if (!self.options.skip_cjs_exports)
            try emitCJSExportBinding(self, decl);
        return;
    } else if (self.options.skip_cjs_exports) {
        // __esm 모듈: export { } 구문은 __export()가 처리하므로 생략
        return;
    } else {
        const has_source = !source.isNone() and @intFromEnum(source) < self.ast.nodes.items.len;
        const spec_indices = self.ast.extra_data.items[specs_start .. specs_start + specs_len];
        for (spec_indices) |raw_idx| {
            const spec = self.ast.getNode(@enumFromInt(raw_idx));
            if (spec.tag != .export_specifier) continue;

            // export_specifier: { left=local/imported, right=exported }
            // alias 없으면 exported == local (파서가 동일 인덱스 할당)
            const local_idx = spec.data.binary.left;
            const exported_idx = spec.data.binary.right;
            const exported_text = self.ast.getText(self.ast.getNode(exported_idx).span);
            const local_text = self.ast.getText(self.ast.getNode(local_idx).span);

            try self.write(self.options.cjs_exports_name);
            try self.writeByte('.');
            try self.write(exported_text);
            try self.writeByte('=');
            if (has_source) {
                try self.write("require(");
                try self.emitNode(source);
                try self.write(").");
            }
            try self.write(local_text);
            try self.writeByte(';');
        }
    }
}

/// 변수/함수/클래스 선언에서 이름을 추출하여 exports.name=name; 출력.
/// variable_declarator의 이름은 span 텍스트에서 직접 추출 (extra 경유 불필요).
pub fn emitCJSExportBinding(self: anytype, decl_idx: NodeIndex) !void {
    const decl = self.ast.getNode(decl_idx);
    switch (decl.tag) {
        .variable_declaration => {
            const e = decl.data.extra;
            const list_start = self.ast.extra_data.items[e + 1];
            const list_len = self.ast.extra_data.items[e + 2];
            const declarators = self.ast.extra_data.items[list_start .. list_start + list_len];
            for (declarators) |raw_idx| {
                const declarator = self.ast.getNode(@enumFromInt(raw_idx));
                const de = declarator.data.extra;
                const name_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[de]);
                if (!name_idx.isNone()) {
                    const name_node = self.ast.getNode(name_idx);
                    const name = self.ast.getText(name_node.data.string_ref);
                    // linker가 rename한 경우 변수 참조는 rename된 이름을 사용해야 함
                    // (예: JSON named export에서 $id → $id$1로 충돌 회피 시)
                    const ref_name = if (self.options.linking_metadata) |meta|
                        if (self.resolveSymbolId(name_idx, meta)) |sid|
                            (meta.renames.get(sid) orelse name)
                        else
                            name
                    else
                        name;
                    try self.write(self.options.cjs_exports_name);
                    try self.writeByte('.');
                    try self.write(name);
                    try self.writeByte('=');
                    try self.write(ref_name);
                    try self.writeByte(';');
                }
            }
        },
        .function_declaration, .class_declaration => {
            const e = decl.data.extra;
            const name_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[e]);
            if (!name_idx.isNone()) {
                const name_node = self.ast.getNode(name_idx);
                const name = self.ast.getText(name_node.data.string_ref);
                const ref_name = if (self.options.linking_metadata) |meta|
                    if (self.resolveSymbolId(name_idx, meta)) |sid|
                        (meta.renames.get(sid) orelse name)
                    else
                        name
                else
                    name;
                try self.write(self.options.cjs_exports_name);
                try self.writeByte('.');
                try self.write(name);
                try self.writeByte('=');
                try self.write(ref_name);
                try self.writeByte(';');
            }
        },
        else => {},
    }
}

pub fn emitExportDefault(self: anytype, node: Node) !void {
    try self.addSourceMapping(node.span);
    if (self.options.module_format == .cjs) {
        if (self.options.skip_cjs_exports) {
            // __esm 모듈: export는 __export()가 처리.
            // named decl (export default function foo) → 선언만 출력
            // named ref (export default NativeModules) → 이미 선언됨, 무시
            // anonymous expr (export default {...}) → var _default = expr;
            const inner = node.data.unary.operand;
            if (!inner.isNone()) {
                const inner_node = self.ast.getNode(inner);
                const is_named_decl = (inner_node.tag == .function_declaration or inner_node.tag == .class_declaration) and
                    !(@as(NodeIndex, @enumFromInt(self.ast.extra_data.items[inner_node.data.extra]))).isNone();
                if (is_named_decl) {
                    // export default function foo() {} → 선언만 출력
                    try self.emitNode(inner);
                } else {
                    const def_name = if (self.options.linking_metadata) |md| md.default_export_name else "_default";
                    if (std.mem.startsWith(u8, def_name, "_default")) {
                        // 합성 변수 (_default, _default$1 등): var 선언 + 할당 필요.
                        if (!self.options.esm_var_assign_only) try self.write("var ");
                        try self.write(def_name);
                        try self.writeByte('=');
                        try self.emitNode(inner);
                        try self.writeByte(';');
                    } else if (!self.isExportDefaultSelfRef(inner, def_name)) {
                        // namespace import이면 ns var name을 직접 사용 (rename과 다름).
                        if (!(try tryEmitNsVarAssignment(self, def_name, inner))) {
                            // mangling으로 이름이 바뀐 경우 (View → View$44) 할당 필요.
                            try self.write(def_name);
                            try self.writeByte('=');
                            try self.emitNode(inner);
                            try self.writeByte(';');
                        }
                    }
                }
            }
            return;
        }
        try self.write(self.options.cjs_module_name);
        try self.write(".exports=");
        try self.emitNode(node.data.unary.operand);
        try self.writeByte(';');
        return;
    }
    // 번들 모드: export default 키워드 생략, 내부 선언만 출력.
    if (self.options.linking_metadata) |lm| {
        if (lm.is_bundle_context) {
            const inner = node.data.unary.operand;
            if (!inner.isNone()) {
                const inner_node = self.ast.getNode(inner);
                // 이름이 있는 function/class → 그대로 출력
                const is_named_decl = (inner_node.tag == .function_declaration or inner_node.tag == .class_declaration) and
                    !(@as(NodeIndex, @enumFromInt(self.ast.extra_data.items[inner_node.data.extra]))).isNone();
                if (is_named_decl) {
                    try self.emitNode(inner);
                } else {
                    const def_name = lm.default_export_name;
                    if (!self.isExportDefaultSelfRef(inner, def_name)) {
                        // namespace import는 실제 값이 `X_ns` 변수에 저장되므로
                        // `def_name = X_ns;` 로 할당. 일반 케이스는 inner 표현식 직접 대입.
                        if (!(try tryEmitNsVarAssignment(self, def_name, inner))) {
                            try emitDefaultVarAssignment(self, def_name, inner);
                        }
                    }
                }
            }
            return;
        }
    }
    try self.write("export default ");
    const inner_idx = node.data.unary.operand;
    // contextual name: 익명 function/arrow/class → "default"
    if (self.fn_map_builder != null and self.isFunctionLike(inner_idx)) {
        const saved = self.pending_fn_name;
        self.pending_fn_name = try self.allocator.dupe(u8, "default");
        defer {
            if (self.pending_fn_name) |s| self.allocator.free(s);
            self.pending_fn_name = saved;
        }
        try self.emitNode(inner_idx);
    } else {
        try self.emitNode(inner_idx);
    }
    // class/function 선언 뒤에는 세미콜론 불필요
    if (!inner_idx.isNone()) {
        const inner_tag = self.ast.getNode(inner_idx).tag;
        if (inner_tag != .class_declaration and inner_tag != .function_declaration) {
            try self.writeByte(';');
        }
    }
}

/// inner가 namespace import (`import * as X`) 를 참조하면 `<def_name> = <X_ns>;` 할당을 emit.
/// 성공 시 true, namespace import가 아니면 false (caller가 기본 emit 수행).
/// `var Animated$6;` 선언과 `Animated_ns = {...}` 객체 사이 연결을 복원해 default getter가
/// 올바른 namespace 객체를 반환하도록 한다 (#1208).
pub fn tryEmitNsVarAssignment(self: anytype, def_name: []const u8, inner: NodeIndex) !bool {
    const md = self.options.linking_metadata orelse return false;
    const inner_node = self.ast.getNode(inner);
    if (inner_node.tag != .identifier_reference) return false;
    const sid = self.resolveSymbolId(inner, md) orelse return false;
    const entry = md.ns_inline_objects.get(sid) orelse return false;

    if (!self.options.esm_var_assign_only) try self.write("var ");
    try self.write(def_name);
    if (self.options.minify_whitespace) {
        try self.writeByte('=');
    } else {
        try self.write(" = ");
    }
    try self.write(entry.var_name);
    try self.writeByte(';');
    return true;
}

/// `var <name> = <inner>;` 출력 (export default 변환용).
pub fn emitDefaultVarAssignment(self: anytype, name: []const u8, inner: NodeIndex) !void {
    if (self.options.minify_whitespace) {
        try self.write("var ");
        try self.write(name);
        try self.writeByte('=');
    } else {
        try self.write("var ");
        try self.write(name);
        try self.write(" = ");
    }
    try self.emitNode(inner);
    try self.writeByte(';');
}

pub fn emitExportAll(self: anytype, node: Node) !void {
    try self.addSourceMapping(node.span);
    const x = module_parser.readExportAllExtras(self.ast, node.data.extra);
    if (self.options.module_format == .cjs) {
        // export * from './bar' → Object.assign(exports,require('./bar'));
        try self.write("Object.assign(");
        try self.write(self.options.cjs_exports_name);
        try self.write(",require(");
        try self.emitNode(x.source);
        try self.write("));");
        return;
    }
    // export * as ns from './foo' / export * from './foo'
    if (!x.exported_name.isNone()) {
        try self.write("export * as ");
        try self.emitNode(x.exported_name);
        try self.write(" from ");
    } else {
        try self.write("export * from ");
    }
    try self.emitNode(x.source);
    if (x.attrs_len > 0) {
        try self.write(" with ");
        try emitImportAttributes(self, x.attrs_start, x.attrs_len);
    }
    try self.writeByte(';');
}
