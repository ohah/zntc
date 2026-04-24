//! ZTS Bundler — Import Scanner
//!
//! 파싱된 AST를 순회하여 모든 import/export 소스 경로를 추출한다 (D079).
//! 파서를 수정하지 않고 AST 노드의 태그만 검사하여 ImportRecord 배열을 생성.
//!
//! 지원하는 구문:
//!   - import "./foo"                     → side_effect
//!   - import x from "./foo"              → static_import
//!   - import { a, b } from "./foo"       → static_import
//!   - import * as ns from "./foo"        → static_import
//!   - export { x } from "./foo"          → re_export
//!   - export * from "./foo"              → re_export
//!   - import("./foo")                    → dynamic_import
//!   - require("./foo")                   → require (CJS)
//!   - module.exports = ...              → CJS 신호 (has_module_exports)
//!   - exports.x = ...                   → CJS 신호 (has_exports_dot)
//!
//! AST extra_data 레이아웃:
//!   - import_declaration:         [specs_start, specs_len, source_node]
//!   - export_named_declaration:   [declaration, specs_start, specs_len, source]
//!   - export_all_declaration:     binary { left=exported_name, right=source_node }
//!   - import_expression:          unary { operand=arg }
//!   - call_expression:            extra [callee, args_start, args_len, flags]
//!   - assignment_expression:      binary { left, right, flags }
//!   - static_member_expression:   extra [object, property, flags]

const std = @import("std");
const Ast = @import("../parser/ast.zig").Ast;
const Node = @import("../parser/ast.zig").Node;
const NodeIndex = @import("../parser/ast.zig").NodeIndex;
const CallFlags = @import("../parser/ast.zig").CallFlags;
const MemberFlags = @import("../parser/ast.zig").MemberFlags;
const scan_results = @import("../parser/scan_results.zig");
const module_parser = @import("../parser/module.zig");
const DefineEntry = scan_results.DefineEntry;
const Span = @import("../lexer/token.zig").Span;
const types = @import("types.zig");
const ImportRecord = types.ImportRecord;
const ImportKind = types.ImportKind;

/// CJS 감지를 포함한 스캔 결과.
pub const ScanResult = struct {
    /// 추출된 import/export/require 레코드
    records: []ImportRecord,
    /// ESM 구문 (import/export) 존재 여부
    has_esm_syntax: bool,
    /// require("...") 호출 존재 여부
    has_cjs_require: bool,
    /// module.exports = ... 할당 존재 여부
    has_module_exports: bool,
    /// exports.xxx = ... 할당 존재 여부
    has_exports_dot: bool,
};

/// AST를 순회하여 import/export/require를 추출하고 CJS 신호를 감지한다.
/// ESM과 CJS 판별에 필요한 모든 정보를 한 번의 순회로 수집.
pub fn extractImportsWithCjsDetection(allocator: std.mem.Allocator, ast: *const Ast) !ScanResult {
    return extractImportsWithCjsDetectionAndDefines(allocator, ast, &.{});
}

/// `extractImportsWithCjsDetection` 의 defines 받는 버전. (#1579 Phase 2.6)
/// require.context 의 `process.env.X` 같은 인자를 build-time 정적 평가.
pub fn extractImportsWithCjsDetectionAndDefines(
    allocator: std.mem.Allocator,
    ast: *const Ast,
    defines: []const DefineEntry,
) !ScanResult {
    var records: std.ArrayList(ImportRecord) = .empty;
    var has_esm_syntax = false;
    var has_cjs_require = false;
    var has_module_exports = false;
    var has_exports_dot = false;

    for (ast.nodes.items) |node| {
        switch (node.tag) {
            .import_declaration => {
                has_esm_syntax = true;
                if (tryExtractImportDecl(ast, node)) |record| {
                    try records.append(allocator, record);
                }
            },
            .export_all_declaration => {
                has_esm_syntax = true;
                if (tryExtractExportAll(ast, node)) |record| {
                    try records.append(allocator, record);
                }
            },
            .export_named_declaration => {
                has_esm_syntax = true;
                if (tryExtractExportNamed(ast, node)) |record| {
                    try records.append(allocator, record);
                }
            },
            .export_default_declaration => {
                has_esm_syntax = true;
            },
            .import_expression => {
                if (tryExtractDynamicImport(ast, node)) |record| {
                    try records.append(allocator, record);
                }
            },
            .call_expression => {
                // Order: require.context (specific, callee=member) → require (callee=ident) → glob (callee=meta).
                // 더 specific 한 패턴 먼저 시도해야 일반 require 가 require.context 를 가리지 않는다.
                if (tryExtractRequireContextWithDefines(ast, node, defines)) |record| {
                    has_cjs_require = true;
                    try records.append(allocator, record);
                } else if (tryExtractRequire(ast, node)) |record| {
                    has_cjs_require = true;
                    try records.append(allocator, record);
                } else if (tryExtractGlob(ast, node)) |record| {
                    try records.append(allocator, record);
                }
            },
            .new_expression => {
                if (tryExtractWorkerNew(ast, node)) |record| {
                    try records.append(allocator, record);
                }
            },
            .assignment_expression => {
                if (!has_module_exports and isModuleExportsAssign(ast, node)) {
                    has_module_exports = true;
                }
                if (!has_exports_dot and isExportsDotAssign(ast, node)) {
                    has_exports_dot = true;
                }
            },
            else => {},
        }
    }

    return .{
        .records = try records.toOwnedSlice(allocator),
        .has_esm_syntax = has_esm_syntax,
        .has_cjs_require = has_cjs_require,
        .has_module_exports = has_module_exports,
        .has_exports_dot = has_exports_dot,
    };
}

/// AST를 순회하여 모든 import/export 소스 경로를 추출한다.
/// 반환된 슬라이스의 specifier는 소스 코드를 가리키는 참조이므로
/// 소스가 유효한 동안만 사용 가능.
/// CJS 감지가 불필요한 경우의 간편 API (binding_scanner 등에서 사용).
pub fn extractImports(allocator: std.mem.Allocator, ast: *const Ast) ![]ImportRecord {
    const result = try extractImportsWithCjsDetection(allocator, ast);
    return result.records;
}

/// import_declaration: extra [specs_start, specs_len, source_node]
/// specs_len == 0이면 side_effect, 아니면 static_import.
fn tryExtractImportDecl(ast: *const Ast, node: Node) ?ImportRecord {
    const e = node.data.extra;
    if (e + 2 >= ast.extra_data.items.len) return null;

    const extras = ast.extra_data.items[e .. e + 3];
    const specs_len = extras[1];
    const source_idx: NodeIndex = @enumFromInt(extras[2]);

    const specifier = getStringLiteralText(ast, source_idx) orelse return null;
    const source_node = ast.getNode(source_idx);

    return .{
        .specifier = specifier,
        .kind = if (specs_len == 0) .side_effect else .static_import,
        .span = source_node.span,
    };
}

/// export * from "./foo": binary { left=exported_name, right=source_node }
fn tryExtractExportAll(ast: *const Ast, node: Node) ?ImportRecord {
    const x = module_parser.readExportAllExtras(ast, node.data.extra);
    const source_idx = x.source;
    const specifier = getStringLiteralText(ast, source_idx) orelse return null;
    const source_node = ast.getNode(source_idx);

    return .{
        .specifier = specifier,
        .kind = .re_export,
        .span = source_node.span,
    };
}

/// export { x } from "./foo": extra [declaration, specs_start, specs_len, source]
/// source가 none이면 re-export가 아님 (export { x } — 로컬 export).
fn tryExtractExportNamed(ast: *const Ast, node: Node) ?ImportRecord {
    const e = node.data.extra;
    if (e + 3 >= ast.extra_data.items.len) return null;

    const source_raw = ast.extra_data.items[e + 3];
    const source_idx: NodeIndex = @enumFromInt(source_raw);
    if (source_idx.isNone()) return null;

    const specifier = getStringLiteralText(ast, source_idx) orelse return null;
    const source_node = ast.getNode(source_idx);

    return .{
        .specifier = specifier,
        .kind = .re_export,
        .span = source_node.span,
    };
}

/// import("./foo"): unary { operand=arg }
/// operand가 string_literal이면 추출, 아니면 null (computed → 정적 분석 불가).
fn tryExtractDynamicImport(ast: *const Ast, node: Node) ?ImportRecord {
    const arg_idx = node.data.binary.left;
    if (arg_idx.isNone()) return null;

    const arg_node = ast.getNode(arg_idx);
    if (arg_node.tag != .string_literal) return null;

    const specifier = stripQuotes(ast.getText(arg_node.span)) orelse return null;

    return .{
        .specifier = specifier,
        .kind = .dynamic_import,
        .span = arg_node.span,
    };
}

/// require.context(dir, recursive?, filter?, mode?) 호출 감지 (#1579 Phase 1).
/// callee 가 static_member_expression `require.context` 인 경우만 처리.
/// 4 인자를 literal 정적 평가 (string/bool/regex/mode string literal). undefined 는 default 폴백.
/// invalid 인자는 record 의 context_invalid_reason 에 기록 (graph 단계에서 diagnostic emit).
/// 다른 callee (Symbol.context, require['context'], require?.context 등) 는 무시 — null 리턴.
///
/// `tryExtractGlob` 와 같은 모양. Reference: Metro `processRequireContextCall`
/// (`metro/src/ModuleGraph/worker/collectDependencies.js`).
pub fn tryExtractRequireContext(ast: *const Ast, node: Node) ?ImportRecord {
    return tryExtractRequireContextWithDefines(ast, node, &.{});
}

/// `tryExtractRequireContext` 의 defines 받는 버전. (#1579 Phase 2.6)
pub fn tryExtractRequireContextWithDefines(
    ast: *const Ast,
    node: Node,
    defines: []const DefineEntry,
) ?ImportRecord {
    if (node.tag != .call_expression) return null;
    const e = node.data.extra;
    if (!ast.hasExtra(e, 3)) return null;

    const callee_idx = ast.readExtraNode(e, 0);
    const args_start = ast.readExtra(e, 1);
    const args_len = ast.readExtra(e, 2);
    const call_flags = ast.readExtra(e, 3);

    if (call_flags & CallFlags.optional_chain != 0) return null;

    return tryExtractRequireContextFromCallee(ast, callee_idx, args_start, args_len, node.span, defines);
}

/// `tryExtractRequireContext` 의 callee+args 직접 받는 변형. (#1579 Phase 2)
/// parser inline scan (call_expression 노드 만들기 *전*에 호출) 에서 사용.
/// `defines`: build-time 정적 평가용 — `process.env.X` 같은 member chain 을 string 으로
/// 평가 (Metro `path.evaluate()` 와 동등 능력). 비어있으면 evaluator 가 literal 만 처리. (#1579 Phase 2.6)
pub fn tryExtractRequireContextFromCallee(
    ast: *const Ast,
    callee_idx: NodeIndex,
    args_start: u32,
    args_len: u32,
    call_span: Span,
    defines: []const DefineEntry,
) ?ImportRecord {
    if (callee_idx.isNone() or @intFromEnum(callee_idx) >= ast.nodes.items.len) return null;
    const callee = ast.getNode(callee_idx);
    const extras = ast.extra_data.items;

    // callee 는 static_member_expression `require.context` 여야 한다
    if (callee.tag != .static_member_expression) return null;
    if (!ast.hasExtra(callee.data.extra, 2)) return null;

    const member_obj_idx = ast.readExtraNode(callee.data.extra, 0);
    const member_prop_idx = ast.readExtraNode(callee.data.extra, 1);
    const member_flags = ast.readExtra(callee.data.extra, 2);

    // `require?.context` 무시
    if (member_flags & MemberFlags.optional_chain != 0) return null;

    if (member_obj_idx.isNone() or member_prop_idx.isNone()) return null;
    if (@intFromEnum(member_obj_idx) >= ast.nodes.items.len or @intFromEnum(member_prop_idx) >= ast.nodes.items.len) return null;
    const obj_node = ast.getNode(member_obj_idx);
    const prop_node = ast.getNode(member_prop_idx);

    // object: identifier_reference "require"
    if (obj_node.tag != .identifier_reference) return null;
    if (!std.mem.eql(u8, ast.getText(obj_node.span), "require")) return null;

    // property: text 가 "context" 여야 함 (identifier 또는 escaped_keyword)
    if (!std.mem.eql(u8, ast.getText(prop_node.span), "context")) return null;

    // 여기까지 왔으면 require.context(...) 호출 확정. record 생성 + 인자 평가.
    var record = ImportRecord{
        .specifier = "",
        .kind = .require_context,
        .span = call_span,
    };

    // 인자 0개 → invalid (no args)
    if (args_len == 0) {
        record.context_invalid_reason = "require.context requires at least one argument (directory)";
        return record;
    }

    // 인자 5개 이상 → invalid (too many args)
    if (args_len > 4) {
        record.context_invalid_reason = "require.context expects at most 4 arguments";
        return record;
    }

    if (args_start + args_len > extras.len) return null;

    // spread element 검사 (전체 인자 사전 스캔)
    var i: u32 = 0;
    while (i < args_len) : (i += 1) {
        const arg_idx = ast.readExtraNode(args_start, i);
        if (@intFromEnum(arg_idx) >= ast.nodes.items.len) return null;
        if (ast.getNode(arg_idx).tag == .spread_element) {
            record.context_invalid_reason = "require.context arguments cannot use spread";
            return record;
        }
    }

    // arg[0]: directory (string literal 또는 define-replaced string, 필수)
    {
        const arg_idx = ast.readExtraNode(args_start, 0);
        if (evalToString(ast, arg_idx, defines)) |s| {
            record.specifier = s;
        } else {
            record.context_invalid_reason = "require.context first argument must be a string literal (directory)";
            return record;
        }
    }

    // arg[1]: recursive (boolean literal, default true). undefined 는 default 폴백.
    if (args_len >= 2) {
        const arg_idx = ast.readExtraNode(args_start, 1);
        const arg_node = ast.getNode(arg_idx);
        if (isUndefinedLiteral(ast, arg_node)) {
            // default true 유지
        } else if (arg_node.tag == .boolean_literal) {
            record.context_recursive = std.mem.eql(u8, ast.getText(arg_node.span), "true");
        } else {
            record.context_invalid_reason = "require.context second argument must be a boolean literal (recursive)";
            return record;
        }
    }

    // arg[2]: filter (regex literal, default null). undefined 는 default 폴백.
    if (args_len >= 3) {
        const arg_idx = ast.readExtraNode(args_start, 2);
        const arg_node = ast.getNode(arg_idx);
        if (isUndefinedLiteral(ast, arg_node)) {
            // default null 유지
        } else if (arg_node.tag == .regexp_literal) {
            if (parseRegexLiteral(ast.getText(arg_node.span))) |parts| {
                record.context_filter = parts.pattern;
                if (parts.flags.len > 0) {
                    record.context_filter_flags = parts.flags;
                }
            } else {
                record.context_invalid_reason = "require.context third argument must be a regular expression literal (filter)";
                return record;
            }
        } else {
            record.context_invalid_reason = "require.context third argument must be a regular expression literal (filter)";
            return record;
        }
    }

    // arg[3]: mode (string literal one of sync/eager/lazy/lazy-once, default 'sync'). undefined 폴백.
    if (args_len >= 4) {
        const arg_idx = ast.readExtraNode(args_start, 3);
        const arg_node = ast.getNode(arg_idx);
        if (isUndefinedLiteral(ast, arg_node)) {
            // default sync 유지
        } else if (evalToString(ast, arg_idx, defines)) |mode_str| {
            const mode = parseRequireContextMode(mode_str) orelse {
                record.context_invalid_reason = "require.context fourth argument must be 'sync', 'eager', 'lazy', or 'lazy-once'";
                return record;
            };
            record.context_mode = mode;
        } else {
            record.context_invalid_reason = "require.context fourth argument must be a string literal (mode)";
            return record;
        }
    }

    return record;
}

/// Identifier / member access / string literal 을 string 으로 정적 평가. (#1579 Phase 2.6)
/// - `string_literal` → text (quotes 제거)
/// - `identifier_reference` / `static_member_expression` → defines lookup 후 unquoted string
/// - 그 외 → null (evaluator 가 처리 못하는 표현식)
///
/// Metro `path.evaluate()` 와 동등 능력 — `process.env.NODE_ENV` 같은 build-time 상수 평가.
fn evalToString(ast: *const Ast, idx: NodeIndex, defines: []const DefineEntry) ?[]const u8 {
    if (idx.isNone() or @intFromEnum(idx) >= ast.nodes.items.len) return null;

    // 1. String literal — 직접 추출
    if (getStringLiteralText(ast, idx)) |s| return s;

    // 2. Identifier 또는 member access — defines lookup
    if (defines.len == 0) return null;
    const node = ast.getNode(idx);
    const text = switch (node.tag) {
        .identifier_reference, .static_member_expression => ast.getText(node.span),
        else => return null,
    };
    for (defines) |def| {
        if (std.mem.eql(u8, def.key, text)) {
            return parseDefineStringValue(def.value);
        }
    }
    return null;
}

/// Define value 가 quoted JS string (`"..."`, `'...'`, `` `...` `` template) 이면 unquote.
/// 기타 (bool/number/표현식) 은 null — 호출자가 string 컨텍스트가 아니라고 판정.
fn parseDefineStringValue(value: []const u8) ?[]const u8 {
    if (value.len < 2) return null;
    const first = value[0];
    const last = value[value.len - 1];
    if ((first == '"' and last == '"') or
        (first == '\'' and last == '\'') or
        (first == '`' and last == '`'))
    {
        return value[1 .. value.len - 1];
    }
    return null;
}

/// `undefined` identifier 리터럴 여부. 글로벌 undefined 가 가려진 경우는 무시 (관례).
fn isUndefinedLiteral(ast: *const Ast, node: Node) bool {
    if (node.tag != .identifier_reference) return false;
    return std.mem.eql(u8, ast.getText(node.span), "undefined");
}

/// `/pattern/flags` 형태의 regex literal 텍스트를 분해. 마지막 `/` 이후를 flags 로 취급.
fn parseRegexLiteral(text: []const u8) ?struct { pattern: []const u8, flags: []const u8 } {
    if (text.len < 2 or text[0] != '/') return null;
    var i: usize = text.len;
    while (i > 1) : (i -= 1) {
        if (text[i - 1] == '/') {
            return .{ .pattern = text[1 .. i - 1], .flags = text[i..] };
        }
    }
    return null;
}

fn parseRequireContextMode(s: []const u8) ?@import("types.zig").RequireContextMode {
    const Mode = @import("types.zig").RequireContextMode;
    if (std.mem.eql(u8, s, "sync")) return Mode.sync;
    if (std.mem.eql(u8, s, "eager")) return Mode.eager;
    if (std.mem.eql(u8, s, "lazy")) return Mode.lazy;
    if (std.mem.eql(u8, s, "lazy-once")) return Mode.lazy_once;
    return null;
}

/// require("string_literal") 호출을 감지하여 ImportRecord로 변환.
/// call_expression extra: [callee, args_start, args_len, flags]
/// callee가 identifier_reference "require"이고 인수가 string_literal 1개인 경우만 추출.
fn tryExtractRequire(ast: *const Ast, node: Node) ?ImportRecord {
    const e = node.data.extra;
    // extra에 최소 3개 (callee, args_start, args_len)가 필요
    if (!ast.hasExtra(e, 2)) return null;

    // callee가 identifier_reference "require"인지 확인
    const callee_idx = ast.readExtraNode(e, 0);
    if (callee_idx.isNone()) return null;
    const callee_ni = @intFromEnum(callee_idx);
    if (callee_ni >= ast.nodes.items.len) return null;
    const callee = ast.nodes.items[callee_ni];
    if (callee.tag != .identifier_reference) return null;

    const callee_text = ast.getText(callee.span);
    if (!std.mem.eql(u8, callee_text, "require")) return null;

    // 인수가 정확히 1개인지 확인
    const args_len = ast.readExtra(e, 2);
    if (args_len != 1) return null;

    // 인수가 string_literal인지 확인
    const args_start = ast.readExtra(e, 1);
    if (args_start >= ast.extra_data.items.len) return null;
    const arg_idx: NodeIndex = @enumFromInt(ast.extra_data.items[args_start]);

    const specifier = getStringLiteralText(ast, arg_idx) orelse return null;
    const arg_node = ast.getNode(arg_idx);

    return .{
        .specifier = specifier,
        .kind = .require,
        .span = arg_node.span,
    };
}

/// assignment_expression의 left가 `obj.prop` 형태의 static_member_expression인지 확인하고,
/// object의 identifier 텍스트를 반환한다. property 텍스트도 함께 반환.
fn getAssignMemberParts(ast: *const Ast, node: Node) ?struct { object: []const u8, property: []const u8 } {
    const left_idx = node.data.binary.left;
    if (left_idx.isNone()) return null;
    const left_ni = @intFromEnum(left_idx);
    if (left_ni >= ast.nodes.items.len) return null;
    const left = ast.nodes.items[left_ni];
    if (left.tag != .static_member_expression) return null;

    const me = left.data.extra;
    if (!ast.hasExtra(me, 1)) return null;

    const obj_idx = ast.readExtraNode(me, 0);
    if (obj_idx.isNone()) return null;
    const obj_ni = @intFromEnum(obj_idx);
    if (obj_ni >= ast.nodes.items.len) return null;
    const obj = ast.nodes.items[obj_ni];
    if (obj.tag != .identifier_reference) return null;

    const prop_idx = ast.readExtraNode(me, 1);
    if (prop_idx.isNone()) return null;
    const prop_ni = @intFromEnum(prop_idx);
    if (prop_ni >= ast.nodes.items.len) return null;
    const prop = ast.nodes.items[prop_ni];

    return .{
        .object = ast.getText(obj.span),
        .property = ast.getText(prop.span),
    };
}

/// assignment_expression의 left가 module.exports인지 확인.
fn isModuleExportsAssign(ast: *const Ast, node: Node) bool {
    const parts = getAssignMemberParts(ast, node) orelse return false;
    return std.mem.eql(u8, parts.object, "module") and std.mem.eql(u8, parts.property, "exports");
}

/// assignment_expression의 left가 exports.xxx인지 확인.
fn isExportsDotAssign(ast: *const Ast, node: Node) bool {
    const parts = getAssignMemberParts(ast, node) orelse return false;
    return std.mem.eql(u8, parts.object, "exports");
}

/// string_literal 노드의 텍스트를 따옴표 없이 반환한다.
/// 소스 코드에서 직접 참조하므로 할당 없음 (zero-copy).
fn getStringLiteralText(ast: *const Ast, idx: NodeIndex) ?[]const u8 {
    if (idx.isNone()) return null;
    if (@intFromEnum(idx) >= ast.nodes.items.len) return null;

    const node = ast.getNode(idx);
    if (node.tag != .string_literal) return null;

    return stripQuotes(ast.getText(node.span));
}

/// new Worker(new URL('./worker.ts', import.meta.url)) 패턴 감지.
/// new_expression extra: [callee, args_start, args_len, flags]
fn tryExtractWorkerNew(ast: *const Ast, node: Node) ?ImportRecord {
    const e = node.data.extra;
    if (!ast.hasExtra(e, 2)) return null;

    // callee가 "Worker" 또는 "SharedWorker"인지 확인
    const callee_idx = ast.readExtraNode(e, 0);
    if (callee_idx.isNone()) return null;
    const callee_ni = @intFromEnum(callee_idx);
    if (callee_ni >= ast.nodes.items.len) return null;
    const callee = ast.nodes.items[callee_ni];
    if (callee.tag != .identifier_reference) return null;
    const callee_text = ast.getText(callee.span);
    if (!std.mem.eql(u8, callee_text, "Worker") and !std.mem.eql(u8, callee_text, "SharedWorker")) return null;

    // 인수가 1개 이상인지
    const args_len = ast.readExtra(e, 2);
    if (args_len < 1) return null;

    // 첫 번째 인수: new URL(...)인지 확인
    const args_start = ast.readExtra(e, 1);
    if (args_start >= ast.extra_data.items.len) return null;
    const url_new_idx: NodeIndex = @enumFromInt(ast.extra_data.items[args_start]);
    if (url_new_idx.isNone()) return null;
    const url_ni = @intFromEnum(url_new_idx);
    if (url_ni >= ast.nodes.items.len) return null;
    const url_new = ast.nodes.items[url_ni];
    if (url_new.tag != .new_expression) return null;

    // new URL의 callee가 "URL"인지
    const ue = url_new.data.extra;
    if (!ast.hasExtra(ue, 2)) return null;
    const url_callee_idx = ast.readExtraNode(ue, 0);
    if (url_callee_idx.isNone()) return null;
    const uc_ni = @intFromEnum(url_callee_idx);
    if (uc_ni >= ast.nodes.items.len) return null;
    const url_callee = ast.nodes.items[uc_ni];
    if (url_callee.tag != .identifier_reference) return null;
    if (!std.mem.eql(u8, ast.getText(url_callee.span), "URL")) return null;

    // new URL의 인수가 2개인지
    const url_args_len = ast.readExtra(ue, 2);
    if (url_args_len < 2) return null;

    const url_args_start = ast.readExtra(ue, 1);
    if (url_args_start + 1 >= ast.extra_data.items.len) return null;

    // 첫 번째 인수: string_literal (worker 경로)
    const spec_idx: NodeIndex = @enumFromInt(ast.extra_data.items[url_args_start]);
    const specifier = getStringLiteralText(ast, spec_idx) orelse return null;
    const spec_node = ast.getNode(spec_idx);

    // 두 번째 인수: import.meta.url 패턴 확인
    const meta_url_idx: NodeIndex = @enumFromInt(ast.extra_data.items[url_args_start + 1]);
    if (!isImportMetaUrl(ast, meta_url_idx)) return null;

    return .{
        .specifier = specifier,
        .kind = .worker,
        .span = spec_node.span,
        .url_span = url_new.span, // new URL(...) 전체 범위
    };
}

/// static_member_expression(object=meta_property "import.meta", property="url")인지 확인.
fn isImportMetaUrl(ast: *const Ast, idx: NodeIndex) bool {
    if (idx.isNone()) return false;
    const ni = @intFromEnum(idx);
    if (ni >= ast.nodes.items.len) return false;
    const node = ast.nodes.items[ni];
    if (node.tag != .static_member_expression) return false;

    const me = node.data.extra;
    if (!ast.hasExtra(me, 1)) return false;

    // object: meta_property (import.meta)
    const obj_idx = ast.readExtraNode(me, 0);
    if (obj_idx.isNone()) return false;
    const obj_ni = @intFromEnum(obj_idx);
    if (obj_ni >= ast.nodes.items.len) return false;
    const obj = ast.nodes.items[obj_ni];
    if (obj.tag != .meta_property) return false;
    if (!std.mem.eql(u8, ast.getText(obj.span), "import.meta")) return false;

    // property: "url"
    const prop_idx = ast.readExtraNode(me, 1);
    if (prop_idx.isNone()) return false;
    const prop_ni = @intFromEnum(prop_idx);
    if (prop_ni >= ast.nodes.items.len) return false;
    const prop = ast.nodes.items[prop_ni];
    if (!std.mem.eql(u8, ast.getText(prop.span), "url")) return false;

    return true;
}

/// AST를 순회하여 Worker 패턴만 추출한다.
/// inline scan 모드에서 Worker 감지를 보완하기 위해 사용.
/// new Worker(new URL('./worker.ts', import.meta.url)) 패턴만 감지.
pub fn extractWorkerRecords(allocator: std.mem.Allocator, ast: *const Ast) ![]ImportRecord {
    var records = std.ArrayListUnmanaged(ImportRecord).empty;
    for (ast.nodes.items) |node| {
        if (node.tag == .new_expression) {
            if (tryExtractWorkerNew(ast, node)) |record| {
                try records.append(allocator, record);
            }
        }
    }
    return records.toOwnedSlice(allocator);
}

/// 따옴표(`'`, `"`)를 벗긴다. 최소 2글자 이상이어야 함.
pub fn stripQuotes(text: []const u8) ?[]const u8 {
    if (text.len < 2) return null;
    const first = text[0];
    if (first == '\'' or first == '"') {
        return text[1 .. text.len - 1];
    }
    return null;
}

/// import.meta.glob("pattern") 호출을 감지하여 glob ImportRecord를 생성한다.
/// call_expression: extra [callee, args_start, args_len, flags]
///   callee: static_member_expression (import.meta.glob)
///     object: meta_property (import.meta, data.none == 0)
///     property: "glob"
///   args[0]: string_literal (패턴)
///   args[1]: object_expression (옵션, optional)
fn tryExtractGlob(ast: *const Ast, node: Node) ?ImportRecord {
    if (node.tag != .call_expression) return null;
    const extras = ast.extra_data.items;
    const e = node.data.extra;
    if (e + 2 >= extras.len) return null;

    const callee_idx: NodeIndex = @enumFromInt(extras[e]);
    const args_start = extras[e + 1];
    const args_len = extras[e + 2];
    if (args_len == 0) return null;
    if (callee_idx.isNone() or @intFromEnum(callee_idx) >= ast.nodes.items.len) return null;

    // callee가 static_member_expression(import.meta.glob)인지 확인
    const callee = ast.getNode(callee_idx);
    if (callee.tag != .static_member_expression) return null;
    if (callee.data.extra + 2 >= extras.len) return null;

    const obj_idx: NodeIndex = @enumFromInt(extras[callee.data.extra]);
    const prop_idx: NodeIndex = @enumFromInt(extras[callee.data.extra + 1]);
    if (obj_idx.isNone() or prop_idx.isNone()) return null;
    if (@intFromEnum(obj_idx) >= ast.nodes.items.len or @intFromEnum(prop_idx) >= ast.nodes.items.len) return null;

    // object: meta_property (import.meta)
    const obj = ast.getNode(obj_idx);
    if (obj.tag != .meta_property) return null;
    if (obj.data.none != 0) return null; // 0 = import.meta, 1 = new.target

    // property: "glob"
    const prop = ast.getNode(prop_idx);
    const prop_name = ast.getText(prop.span);
    if (!std.mem.eql(u8, prop_name, "glob")) return null;

    // args[0]: string_literal (패턴)
    if (args_start >= extras.len) return null;
    const arg0_idx: NodeIndex = @enumFromInt(extras[args_start]);
    if (arg0_idx.isNone() or @intFromEnum(arg0_idx) >= ast.nodes.items.len) return null;
    const arg0 = ast.getNode(arg0_idx);
    if (arg0.tag != .string_literal) return null;

    const pattern = stripQuotes(ast.getText(arg0.span)) orelse return null;

    const opts = parseGlobOptions(ast.nodes.items, ast.extra_data.items, ast.source, extras, args_start, args_len);

    return ImportRecord{
        .specifier = pattern,
        .kind = .glob,
        .span = node.span,
        .glob_eager = opts.eager,
        .glob_import_name = opts.import_name,
    };
}

/// import.meta.glob의 두 번째 인수 (object_expression)에서 eager/import 옵션을 추출한다.
/// scanGlobCall (expression.zig)과 tryExtractGlob 양쪽에서 공유.
pub const GlobOptions = struct { eager: bool = false, import_name: ?[]const u8 = null };

pub fn parseGlobOptions(
    nodes: []const @import("../parser/ast.zig").Node,
    extra_data: []const u32,
    source: []const u8,
    extras: []const u32,
    args_start: u32,
    args_len: u32,
) GlobOptions {
    var result = GlobOptions{};
    if (args_len <= 1 or args_start + 1 >= extras.len) return result;

    const arg1_raw = extras[args_start + 1];
    if (arg1_raw >= nodes.len) return result;
    const arg1 = nodes[arg1_raw];
    if (arg1.tag != .object_expression) return result;

    const props = arg1.data.list;
    if (props.start + props.len > extra_data.len) return result;
    const prop_indices = extra_data[props.start .. props.start + props.len];

    for (prop_indices) |prop_raw| {
        if (prop_raw >= nodes.len) continue;
        const prop_node = nodes[prop_raw];
        if (prop_node.tag != .object_property) continue;
        const key_idx = prop_node.data.binary.left;
        const val_idx = prop_node.data.binary.right;
        if (key_idx.isNone() or val_idx.isNone()) continue;
        if (@intFromEnum(key_idx) >= nodes.len or @intFromEnum(val_idx) >= nodes.len) continue;

        const key = nodes[@intFromEnum(key_idx)];
        const key_text = source[key.span.start..key.span.end];
        const val = nodes[@intFromEnum(val_idx)];

        if (std.mem.eql(u8, key_text, "eager")) {
            if (val.tag == .boolean_literal)
                result.eager = std.mem.eql(u8, source[val.span.start..val.span.end], "true");
        } else if (std.mem.eql(u8, key_text, "import")) {
            if (val.tag == .string_literal)
                result.import_name = stripQuotes(source[val.span.start..val.span.end]);
        }
    }
    return result;
}
