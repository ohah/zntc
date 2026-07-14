const std = @import("std");
const types = @import("../types.zig");
const rt = @import("../runtime_helpers.zig");

/// CJS 모듈을 가져오는 ESM-side import 가 `__toESM` 래핑을 필요로 하는지.
/// namespace 또는 default import 면 `__toESM(req())` 형태로 emit, 그 외 named
/// 는 `req().prop` 직접 접근으로 충분.
///
/// `PreambleWriter.writeCjsImportInner` 의 emit 분기와
/// `emitter.moduleNeedsToEsmInterop` 의 detection 분기가 모두 이 함수를 통해
/// 동일 invariant 를 유지한다 — 어긋나면 preamble 이 `__toESM` 을 부르는데
/// 정의가 없는 ReferenceError 가 발생 (#812 회귀).
pub inline fn cjsImportNeedsToEsmInterop(is_namespace: bool, imported_name: []const u8) bool {
    return is_namespace or isDefaultExportName(imported_name);
}

/// module-export name 이 `default` 인가 — **따옴표 형태까지 포함**한다.
///
/// ES2022 arbitrary module namespace names 때문에 `import { "default" as d }` 가 유효하고,
/// node/esbuild 는 이걸 `import d from` 과 **동일하게** 다룬다. 그런데 binding_scanner 는
/// AST span 텍스트를 그대로 담아 이름에 **따옴표가 붙은 채** 저장한다(`"\"default\""`).
/// 그래서 bare `"default"` 와만 비교하면 이 형태가 default-interop 을 통째로 비껴가
/// `require_x()["default"]` = **undefined** 가 된다 (문법은 유효 → 무성 오컴파일).
///
/// default 판정 3곳(`cjsImportNeedsToEsmInterop` / `Linker.cjsInteropAccessExpr` /
/// `binding_scanner.isDefaultImport`)이 **반드시 lockstep** 이어야 하므로 여기 단일 소스로 둔다.
pub fn isDefaultExportName(name: []const u8) bool {
    return std.mem.eql(u8, unquoteName(name), "default");
}

/// 따옴표가 있으면 벗긴 알맹이, 없으면 원본.
pub fn unquoteName(name: []const u8) []const u8 {
    if (!isQuotedName(name)) return name;
    return name[1 .. name.len - 1];
}

/// 이름이 `obj.<name>` 점 접근에 그대로 쓸 수 있는 평범한 ASCII 식별자인지.
/// 비-ASCII 는 보수적으로 false (호출부가 quote → 항상 합법). 예약어(`default`)는
/// 멤버 접근 위치에선 유효하므로 true.
pub fn isPlainMemberName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name, 0..) |c, i| {
        const ok = std.ascii.isAlphabetic(c) or c == '_' or c == '$' or (i > 0 and std.ascii.isDigit(c));
        if (!ok) return false;
    }
    return true;
}

/// JS 문자열 리터럴(쌍따옴표) 을 buf 에 append. 제어문자/따옴표/백슬래시 escape.
pub fn appendJsStringLiteral(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), value: []const u8) !void {
    const hex = "0123456789abcdef";
    try buf.append(allocator, '"');
    for (value) |c| {
        switch (c) {
            '\\' => try buf.appendSlice(allocator, "\\\\"),
            '"' => try buf.appendSlice(allocator, "\\\""),
            '\n' => try buf.appendSlice(allocator, "\\n"),
            '\r' => try buf.appendSlice(allocator, "\\r"),
            '\t' => try buf.appendSlice(allocator, "\\t"),
            else => {
                if (c < 0x20) {
                    try buf.appendSlice(allocator, "\\u00");
                    try buf.append(allocator, hex[c >> 4]);
                    try buf.append(allocator, hex[c & 0x0f]);
                } else {
                    try buf.append(allocator, c);
                }
            },
        }
    }
    try buf.append(allocator, '"');
}

/// (#4510) import/export 이름이 **문자열 리터럴 소스 그대로**인지(`"foo-bar"` / `'foo-bar'`).
///
/// ES2022 arbitrary module namespace name(`import { 'foo-bar' as x }`)의 이름은 binding_scanner
/// 가 AST span 텍스트를 그대로 담아 **따옴표를 포함한 채** 저장된다(그래야 codegen 이
/// `export { local as "foo-bar" }` 를 원문 그대로 재출력할 수 있다). 즉 이 이름 자체가 이미
/// 유효한 JS 문자열 리터럴이므로 프로퍼티 키/computed 접근에 verbatim 으로 쓸 수 있다.
pub fn isQuotedName(name: []const u8) bool {
    if (name.len < 2) return false;
    const q = name[0];
    return (q == '"' or q == '\'') and name[name.len - 1] == q;
}

/// (#4510) 프로퍼티 키 텍스트를 buf 에 append — 식별자면 그대로, 문자열 리터럴 원문이면
/// verbatim(이미 quote 됨), 그 외엔 quote. 객체 키(`{ <key>: v }`)·computed 접근 공용.
pub fn appendPropertyKey(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), name: []const u8) !void {
    if (isPlainMemberName(name) or isQuotedName(name)) {
        try buf.appendSlice(allocator, name);
        return;
    }
    try appendJsStringLiteral(allocator, buf, name);
}

/// (#4510) 멤버 접근 텍스트(`.foo` / `["foo-bar"]`) 를 allocator 소유 문자열로 만든다.
///
/// 멤버명이 식별자가 아니면 점 접근(`req_x()."foo-bar"`)은 **문법 오류**다 — computed 접근
/// (`req_x()["foo-bar"]`)으로 써야 한다. CJS interop 식을 만드는 모든 경로(preamble writer /
/// `Linker.cjsInteropAccessExpr` / metadata 의 expression rename)가 이 함수 하나를 쓴다.
pub fn allocMemberAccess(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    if (isPlainMemberName(name)) {
        return std.fmt.allocPrint(allocator, ".{s}", .{name});
    }
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.append(allocator, '[');
    try appendPropertyKey(allocator, &buf, name);
    try buf.append(allocator, ']');
    return buf.toOwnedSlice(allocator);
}

/// CJS/dev preamble 생성용 writer.
pub const PreambleWriter = struct {
    buf: std.ArrayList(u8) = .empty,
    allocator: std.mem.Allocator,
    /// #1621: minify 시 preamble 내부 runtime helper 호출을 축약 이름으로 emit.
    /// Linker.minify_whitespace 와 동일 값. dev 경로에서는 무관 (별도 writer).
    minify: bool = false,

    pub fn init(allocator: std.mem.Allocator) PreambleWriter {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *PreambleWriter) void {
        self.buf.deinit(self.allocator);
    }

    pub fn isEmpty(self: *const PreambleWriter) bool {
        return self.buf.items.len == 0;
    }

    /// 버퍼 내용을 allocator로 복제하여 반환. 비어있으면 null.
    pub fn toOwned(self: *const PreambleWriter) !?[]const u8 {
        if (self.isEmpty()) return null;
        return try self.allocator.dupe(u8, self.buf.items);
    }

    /// 버퍼 내용을 다른 슬라이스와 concat하여 반환. 비어있으면 other를 그대로 반환.
    pub fn concatWith(self: *const PreambleWriter, other: ?[]const u8) !?[]const u8 {
        if (self.isEmpty()) return other;
        const combined = try std.mem.concat(self.allocator, u8, &.{
            other orelse "",
            self.buf.items,
        });
        if (other) |p| self.allocator.free(p);
        return combined;
    }

    pub inline fn write(self: *PreambleWriter, s: []const u8) !void {
        try self.buf.appendSlice(self.allocator, s);
    }

    /// (#4510) 멤버 접근 emit — 평범한 식별자면 `.foo`, 아니면 `["foo-bar"]`.
    fn writeMemberAccess(self: *PreambleWriter, name: []const u8) !void {
        if (isPlainMemberName(name)) {
            try self.write(".");
            try self.write(name);
            return;
        }
        try self.write("[");
        try appendPropertyKey(self.allocator, &self.buf, name);
        try self.write("]");
    }

    pub fn writeUnresolvedRequire(
        self: *PreambleWriter,
        local_name: []const u8,
        specifier: []const u8,
        imported_name: []const u8,
        is_namespace: bool,
    ) !void {
        return self.writeUnresolvedRequireInner(local_name, specifier, imported_name, is_namespace, false);
    }

    /// ESM-wrapped 모듈의 synthetic JSX binding 등에서 사용.
    /// top-level에 이미 `var _jsxDEV, _Fragment;` 선언이 있으므로 init 함수 본문에서는
    /// `var` 없이 할당만 해야 함 (var 재선언 시 outer scope shadowing → #1209).
    pub fn writeUnresolvedRequireAssignOnly(
        self: *PreambleWriter,
        local_name: []const u8,
        specifier: []const u8,
        imported_name: []const u8,
        is_namespace: bool,
    ) !void {
        return self.writeUnresolvedRequireInner(local_name, specifier, imported_name, is_namespace, true);
    }

    fn writeUnresolvedRequireInner(
        self: *PreambleWriter,
        local_name: []const u8,
        specifier: []const u8,
        imported_name: []const u8,
        is_namespace: bool,
        assign_only: bool,
    ) !void {
        if (!assign_only) try self.write("var ");
        try self.write(local_name);
        try self.write(" = require(\"");
        try self.write(specifier);
        try self.write("\")");
        // named import만 .property 접근 추가 (namespace/default는 모듈 전체)
        if (!is_namespace and !std.mem.eql(u8, imported_name, "default")) {
            try self.writeMemberAccess(imported_name);
        }
        try self.write(";\n");
    }

    pub fn writeCjsImport(
        self: *PreambleWriter,
        local_name: []const u8,
        imported_name: []const u8,
        req_var: []const u8,
        is_namespace: bool,
        interop: types.Interop,
    ) !void {
        try self.writeCjsImportInner(local_name, imported_name, req_var, is_namespace, interop, false);
    }

    pub fn writeCjsImportAssignOnly(
        self: *PreambleWriter,
        local_name: []const u8,
        imported_name: []const u8,
        req_var: []const u8,
        is_namespace: bool,
        interop: types.Interop,
    ) !void {
        try self.writeCjsImportInner(local_name, imported_name, req_var, is_namespace, interop, true);
    }

    pub fn writeCjsImportInner(
        self: *PreambleWriter,
        local_name: []const u8,
        imported_name: []const u8,
        req_var: []const u8,
        is_namespace: bool,
        interop: types.Interop,
        assign_only: bool,
    ) !void {
        if (!assign_only) try self.write("var ");
        try self.write(local_name);
        try self.write(" = ");
        if (cjsImportNeedsToEsmInterop(is_namespace, imported_name)) {
            // Rolldown Interop: node → __toESM(req(), 1), babel → __toESM(req())
            // #1621: minify 시 __toESM → $tE 축약.
            const toesm_name: []const u8 = if (self.minify) rt.NAMES.TOESM_MIN else "__toESM";
            const toesm_suffix: []const u8 = if (interop == .node) "(), 1)" else "())";
            try self.write(toesm_name);
            try self.write("(");
            try self.write(req_var);
            try self.write(toesm_suffix);
            if (!is_namespace) try self.write(".default");
            try self.write(";\n");
        } else {
            try self.write(req_var);
            try self.write("()");
            // (#4510) `import { 'foo-bar' as x }` 같은 비-식별자 멤버명은 점 접근이 문법
            // 오류(`req_x()."foo-bar"`) → computed 접근으로 emit.
            try self.writeMemberAccess(imported_name);
            try self.write(";\n");
        }
    }

    /// `module.exports = ...` shape 의 CJS default import 를 `__toESM` 래핑 없이
    /// `[var ]local = req_var();` 로 직접 emit. canUseDirectCjsDefaultImport 가 true 일 때만 호출.
    pub fn writeCjsDirectDefault(
        self: *PreambleWriter,
        local_name: []const u8,
        req_var: []const u8,
        assign_only: bool,
    ) !void {
        if (!assign_only) try self.write("var ");
        try self.write(local_name);
        try self.write(" = ");
        try self.write(req_var);
        try self.write("();\n");
    }

    pub fn writeDevRequire(self: *PreambleWriter, local_name: []const u8, path: []const u8, suffix: ?[]const u8) !void {
        return self.writeDevRequireInterop(local_name, path, suffix, false, false);
    }

    /// CJS interop 포함: [var ]x = [__toESM(]__zntc_require("path")[)][.default];
    /// assign_only=true 일 때 var 키워드 생략 (namespace 패턴에서 호이스팅된 변수에 할당만).
    pub fn writeDevRequireInterop(self: *PreambleWriter, local_name: []const u8, path: []const u8, suffix: ?[]const u8, to_esm: bool, assign_only: bool) !void {
        if (!assign_only) try self.write("var ");
        try self.write(local_name);
        try self.write(" = ");
        if (to_esm) try self.write("__toESM(");
        try self.write("__zntc_require(\"");
        try self.write(path);
        try self.write("\")");
        if (to_esm) try self.write(")");
        if (suffix) |s| try self.write(s);
        try self.write(";\n");
    }

    pub const NamePair = struct { local: []const u8, imported: []const u8 };

    pub fn writeDevRequireNamed(
        self: *PreambleWriter,
        named_bindings: []const NamePair,
        path: []const u8,
    ) !void {
        try self.write("var { ");
        for (named_bindings, 0..) |nb, i| {
            if (i > 0) try self.write(", ");
            if (!std.mem.eql(u8, nb.imported, nb.local)) {
                // (#4510) 비-식별자 멤버명은 destructuring 키로도 quote 필요
                // (`var { "foo-bar": x } = …`). shorthand 는 애초에 불가능.
                try appendPropertyKey(self.allocator, &self.buf, nb.imported);
                try self.write(": ");
                try self.write(nb.local);
            } else {
                try self.write(nb.local);
            }
        }
        try self.write(" } = __zntc_require(\"");
        try self.write(path);
        try self.write("\");\n");
    }

    pub fn writeNamespaceObject(self: *PreambleWriter, var_name: []const u8, object_literal: []const u8) !void {
        try self.write("var ");
        try self.write(var_name);
        try self.write(" = ");
        try self.write(object_literal);
        try self.write(";\n");
    }

    /// (#3975) `export * from <CJS>` 의 동적 멤버를 런타임에 namespace 객체로 복사.
    /// `__copyProps(<ns>, <req>());` — esbuild `__reExport(ns, __toESM(require()))` 대응.
    /// plain CJS(`exports.x=`)는 module.exports 에 `default` 키가 없어 raw require() 복사로
    /// 충분하며 default 누출이 없다(`export *` 는 default 비전파 — spec 일치).
    pub fn writeNamespaceCopyProps(self: *PreambleWriter, ns_name: []const u8, req_var: []const u8) !void {
        const copy_props_name: []const u8 = if (self.minify) rt.NAMES.COPY_PROPS_MIN else "__copyProps";
        try self.write(copy_props_name);
        try self.write("(");
        try self.write(ns_name);
        try self.write(", ");
        try self.write(req_var);
        try self.write("());\n");
    }
};
