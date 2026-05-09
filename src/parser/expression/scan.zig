//! Inline import/export scanning helpers used while parsing expressions.

const std = @import("std");
const ast_mod = @import("../ast.zig");
const NodeIndex = ast_mod.NodeIndex;
const NodeList = ast_mod.NodeList;
const Span = @import("../../lexer/token.zig").Span;
const Parser = @import("../parser.zig").Parser;
const scan_results_mod = @import("../scan_results.zig");
const import_scanner = @import("../../bundler/import_scanner.zig");

/// require("specifier") 호출을 감지하여 CJS import record를 추가한다.
/// call_expression이 생성되기 직전, callee(expr)와 arg_list가 확정된 시점에서 호출.
/// import_scanner.tryExtractRequire와 동일한 패턴을 인라인으로 검사한다.
pub fn scanRequireCall(self: *Parser, callee: NodeIndex, arg_list: NodeList) void {
    // callee가 identifier_reference "require"인지 확인
    if (callee.isNone()) return;
    if (@intFromEnum(callee) >= self.ast.nodes.items.len) return;
    const callee_node = self.ast.nodes.items[@intFromEnum(callee)];
    if (callee_node.tag != .identifier_reference) return;
    const callee_text = self.ast.source[callee_node.span.start..callee_node.span.end];
    if (!std.mem.eql(u8, callee_text, "require")) return;

    // 인수가 정확히 1개인지 확인
    if (arg_list.len != 1) return;

    // 인수가 string_literal인지 확인
    if (arg_list.start >= self.ast.extra_data.items.len) return;
    const arg_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[arg_list.start]);
    if (arg_idx.isNone()) return;
    if (@intFromEnum(arg_idx) >= self.ast.nodes.items.len) return;
    const arg_node = self.ast.nodes.items[@intFromEnum(arg_idx)];
    if (arg_node.tag != .string_literal) return;

    const raw = self.ast.source[arg_node.span.start..arg_node.span.end];
    const specifier = import_scanner.stripQuotes(raw) orelse raw;

    self.scan_import_records.append(self.allocator, .{
        .specifier = specifier,
        .kind = .require,
        .span = arg_node.span,
    }) catch {};
    self.scan_result.has_cjs_require = true;
}

/// import.meta.glob("pattern") 호출을 감지하여 glob import 레코드를 생성한다.
pub fn scanGlobCall(self: *Parser, callee: NodeIndex, arg_list: NodeList) void {
    if (callee.isNone() or @intFromEnum(callee) >= self.ast.nodes.items.len) return;
    const callee_node = self.ast.nodes.items[@intFromEnum(callee)];
    if (callee_node.tag != .static_member_expression) return;

    const extras = self.ast.extra_data.items;
    if (callee_node.data.extra + 2 >= extras.len) return;

    // object: meta_property (import.meta)
    const obj_idx: NodeIndex = @enumFromInt(extras[callee_node.data.extra]);
    if (obj_idx.isNone() or @intFromEnum(obj_idx) >= self.ast.nodes.items.len) return;
    const obj_node = self.ast.nodes.items[@intFromEnum(obj_idx)];
    if (obj_node.tag != .meta_property) return;
    if (obj_node.data.none != 0) return;

    // property: "glob"
    const prop_idx: NodeIndex = @enumFromInt(extras[callee_node.data.extra + 1]);
    if (prop_idx.isNone() or @intFromEnum(prop_idx) >= self.ast.nodes.items.len) return;
    const prop_node = self.ast.nodes.items[@intFromEnum(prop_idx)];
    const prop_name = self.ast.source[prop_node.span.start..prop_node.span.end];
    if (!std.mem.eql(u8, prop_name, "glob")) return;

    // 첫 번째 인수가 string_literal인지
    if (arg_list.len == 0) return;
    if (arg_list.start >= extras.len) return;
    const arg_idx: NodeIndex = @enumFromInt(extras[arg_list.start]);
    if (arg_idx.isNone() or @intFromEnum(arg_idx) >= self.ast.nodes.items.len) return;
    const arg_node = self.ast.nodes.items[@intFromEnum(arg_idx)];
    if (arg_node.tag != .string_literal) return;

    const raw = self.ast.source[arg_node.span.start..arg_node.span.end];
    const specifier = import_scanner.stripQuotes(raw) orelse raw;

    const opts = import_scanner.parseGlobOptions(
        self.ast.nodes.items,
        self.ast.extra_data.items,
        self.ast.source,
        extras,
        arg_list.start,
        arg_list.len,
    );

    self.scan_import_records.append(self.allocator, .{
        .specifier = specifier,
        .kind = .glob,
        .span = callee_node.span,
        .glob_eager = opts.eager,
        .glob_import_name = opts.import_name,
    }) catch {};
}

/// require.context(...) 호출을 감지하여 require_context 레코드를 생성한다. (#1579)
/// inline scan 시점에는 call_expression 노드가 아직 안 만들어져 있어 callee+args 직접 전달.
/// import_scanner.tryExtractRequireContextFromCallee 에 위임 후 ScanImportRecord 로 변환.
pub fn scanRequireContextCall(self: *Parser, callee: NodeIndex, arg_list: NodeList, call_span: Span) void {
    const ir = import_scanner.tryExtractRequireContextFromCallee(
        &self.ast,
        callee,
        arg_list.start,
        arg_list.len,
        call_span,
        self.scan_defines,
    ) orelse return;

    const mode: scan_results_mod.RequireContextMode = @enumFromInt(@intFromEnum(ir.context_mode));
    self.scan_import_records.append(self.allocator, .{
        .specifier = ir.specifier,
        .kind = .require_context,
        .span = ir.span,
        .context_recursive = ir.context_recursive,
        .context_filter = ir.context_filter,
        .context_filter_flags = ir.context_filter_flags,
        .context_mode = mode,
        .context_invalid_reason = ir.context_invalid_reason,
    }) catch {};
    self.scan_result.has_cjs_require = true;
}

pub fn scanObjectDefinePropertyCjs(self: *Parser, callee: NodeIndex, arg_list: NodeList) void {
    if (callee.isNone() or @intFromEnum(callee) >= self.ast.nodes.items.len) return;
    const callee_node = self.ast.nodes.items[@intFromEnum(callee)];
    if (callee_node.tag != .static_member_expression) return;
    const e = callee_node.data.extra;
    if (e + 1 >= self.ast.extra_data.items.len) return;

    const obj_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[e]);
    const prop_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[e + 1]);
    if (obj_idx.isNone() or prop_idx.isNone()) return;
    if (@intFromEnum(obj_idx) >= self.ast.nodes.items.len or @intFromEnum(prop_idx) >= self.ast.nodes.items.len) return;
    const obj = self.ast.nodes.items[@intFromEnum(obj_idx)];
    const prop = self.ast.nodes.items[@intFromEnum(prop_idx)];
    if (obj.tag != .identifier_reference) return;
    if (!std.mem.eql(u8, self.ast.source[obj.span.start..obj.span.end], "Object")) return;
    if (!std.mem.eql(u8, self.ast.source[prop.span.start..prop.span.end], "defineProperty")) return;

    if (arg_list.len < 1 or arg_list.start >= self.ast.extra_data.items.len) return;
    const target_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[arg_list.start]);
    if (!isCjsExportTarget(self, target_idx)) return;

    self.scan_result.has_exports_dot = true;
    if (arg_list.len >= 2 and arg_list.start + 1 < self.ast.extra_data.items.len) {
        const key_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[arg_list.start + 1]);
        if (key_idx.isNone() or @intFromEnum(key_idx) >= self.ast.nodes.items.len) return;
        const key_node = self.ast.nodes.items[@intFromEnum(key_idx)];
        if (key_node.tag != .string_literal) return;
        const raw = self.ast.source[key_node.span.start..key_node.span.end];
        const key = import_scanner.stripQuotes(raw) orelse raw;
        if (std.mem.eql(u8, key, import_scanner.ES_MODULE_MARKER)) {
            self.scan_result.has_esmodule_marker = true;
        }
    }
}

/// new Worker(new URL("./worker.ts", import.meta.url)) 패턴을 inline scan으로 수집한다.
/// graph 후처리 AST walk를 피하기 위해 new_expression 생성 시점의 callee/args를 사용한다.
pub fn scanWorkerNewExpression(self: *Parser, callee: NodeIndex, arg_list: NodeList) void {
    if (!isIdentifierText(self, callee, "Worker") and !isIdentifierText(self, callee, "SharedWorker")) return;
    if (arg_list.len < 1 or arg_list.start >= self.ast.extra_data.items.len) return;

    const url_new_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[arg_list.start]);
    if (url_new_idx.isNone() or @intFromEnum(url_new_idx) >= self.ast.nodes.items.len) return;
    const url_new = self.ast.nodes.items[@intFromEnum(url_new_idx)];
    if (url_new.tag != .new_expression) return;

    const ue = url_new.data.extra;
    if (!self.ast.hasExtra(ue, 2)) return;
    const url_callee_idx = self.ast.readExtraNode(ue, 0);
    if (!isIdentifierText(self, url_callee_idx, "URL")) return;

    const url_args_len = self.ast.readExtra(ue, 2);
    if (url_args_len < 2) return;

    const url_args_start = self.ast.readExtra(ue, 1);
    if (url_args_start + 1 >= self.ast.extra_data.items.len) return;

    const spec_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[url_args_start]);
    const specifier = getStringLiteralText(self, spec_idx) orelse return;
    const spec_node = self.ast.getNode(spec_idx);

    const meta_url_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[url_args_start + 1]);
    if (!isImportMetaUrlNode(self, meta_url_idx)) return;

    self.scan_import_records.append(self.allocator, .{
        .specifier = specifier,
        .kind = .worker,
        .span = spec_node.span,
        .url_span = url_new.span,
    }) catch {};
}

fn isIdentifierText(self: *Parser, idx: NodeIndex, expected: []const u8) bool {
    if (idx.isNone() or @intFromEnum(idx) >= self.ast.nodes.items.len) return false;
    const node = self.ast.nodes.items[@intFromEnum(idx)];
    if (node.tag != .identifier_reference) return false;
    return std.mem.eql(u8, self.ast.source[node.span.start..node.span.end], expected);
}

fn getStringLiteralText(self: *Parser, idx: NodeIndex) ?[]const u8 {
    if (idx.isNone() or @intFromEnum(idx) >= self.ast.nodes.items.len) return null;
    const node = self.ast.nodes.items[@intFromEnum(idx)];
    if (node.tag != .string_literal) return null;
    const raw = self.ast.source[node.span.start..node.span.end];
    return import_scanner.stripQuotes(raw) orelse raw;
}

fn isImportMetaUrlNode(self: *Parser, idx: NodeIndex) bool {
    if (idx.isNone() or @intFromEnum(idx) >= self.ast.nodes.items.len) return false;
    const node = self.ast.nodes.items[@intFromEnum(idx)];
    if (node.tag != .static_member_expression) return false;

    const me = node.data.extra;
    if (!self.ast.hasExtra(me, 1)) return false;

    const obj_idx = self.ast.readExtraNode(me, 0);
    if (obj_idx.isNone() or @intFromEnum(obj_idx) >= self.ast.nodes.items.len) return false;
    const obj = self.ast.nodes.items[@intFromEnum(obj_idx)];
    if (obj.tag != .meta_property or obj.data.none != 0) return false;

    const prop_idx = self.ast.readExtraNode(me, 1);
    if (prop_idx.isNone() or @intFromEnum(prop_idx) >= self.ast.nodes.items.len) return false;
    const prop = self.ast.nodes.items[@intFromEnum(prop_idx)];
    return std.mem.eql(u8, self.ast.source[prop.span.start..prop.span.end], "url");
}

/// assignment_expression의 left에서 module.exports = ... / exports.x = ... 패턴을 감지한다.
/// import_scanner.isModuleExportsAssign / isExportsDotAssign / isEsModuleMarkerAssign 과
/// 같은 신호를 set 한다 (parser/import_scanner 두 경로 모두 ScanResult 채움).
pub fn scanAssignmentCjs(self: *Parser, left: NodeIndex) void {
    if (left.isNone()) return;
    if (@intFromEnum(left) >= self.ast.nodes.items.len) return;
    const left_node = self.ast.nodes.items[@intFromEnum(left)];
    if (left_node.tag != .static_member_expression) return;

    const me = left_node.data.extra;
    if (me + 1 >= self.ast.extra_data.items.len) return;

    // object: extra[0], property: extra[1]
    const obj_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[me]);
    if (obj_idx.isNone()) return;
    if (@intFromEnum(obj_idx) >= self.ast.nodes.items.len) return;
    const obj = self.ast.nodes.items[@intFromEnum(obj_idx)];

    const obj_text = if (obj.tag == .identifier_reference) self.ast.source[obj.span.start..obj.span.end] else "";

    if (std.mem.eql(u8, obj_text, "module")) {
        // module.exports = ...
        const prop_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[me + 1]);
        if (prop_idx.isNone()) return;
        if (@intFromEnum(prop_idx) >= self.ast.nodes.items.len) return;
        const prop = self.ast.nodes.items[@intFromEnum(prop_idx)];
        const prop_text = self.ast.source[prop.span.start..prop.span.end];
        if (std.mem.eql(u8, prop_text, "exports")) {
            self.scan_result.has_module_exports = true;
        }
    } else if (std.mem.eql(u8, obj_text, "exports")) {
        // exports.x = ...
        if (memberPropertyEqualsEsModule(self, me)) {
            self.scan_result.has_esmodule_marker = true;
        }
        self.scan_result.has_exports_dot = true;
    } else if (obj.tag == .static_member_expression) {
        const inner_me = obj.data.extra;
        if (inner_me + 1 >= self.ast.extra_data.items.len) return;
        const inner_obj_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[inner_me]);
        const inner_prop_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[inner_me + 1]);
        if (inner_obj_idx.isNone() or inner_prop_idx.isNone()) return;
        if (@intFromEnum(inner_obj_idx) >= self.ast.nodes.items.len or
            @intFromEnum(inner_prop_idx) >= self.ast.nodes.items.len) return;
        const inner_obj = self.ast.nodes.items[@intFromEnum(inner_obj_idx)];
        const inner_prop = self.ast.nodes.items[@intFromEnum(inner_prop_idx)];
        if (inner_obj.tag != .identifier_reference) return;
        const inner_obj_text = self.ast.source[inner_obj.span.start..inner_obj.span.end];
        const inner_prop_text = self.ast.source[inner_prop.span.start..inner_prop.span.end];
        if (std.mem.eql(u8, inner_obj_text, "module") and std.mem.eql(u8, inner_prop_text, "exports")) {
            // module.exports.x = ...
            if (memberPropertyEqualsEsModule(self, me)) {
                self.scan_result.has_esmodule_marker = true;
            }
            self.scan_result.has_exports_dot = true;
        }
    }
}

/// static_member_expression `obj.prop` 의 `me` extra index 에서 prop identifier 텍스트가
/// `__esModule` 인지. 호출자가 obj 식별을 끝낸 뒤 prop 부분만 확인할 때 사용.
fn memberPropertyEqualsEsModule(self: *Parser, me: u32) bool {
    if (me + 1 >= self.ast.extra_data.items.len) return false;
    const prop_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[me + 1]);
    if (prop_idx.isNone() or @intFromEnum(prop_idx) >= self.ast.nodes.items.len) return false;
    const prop = self.ast.nodes.items[@intFromEnum(prop_idx)];
    return std.mem.eql(u8, self.ast.source[prop.span.start..prop.span.end], import_scanner.ES_MODULE_MARKER);
}

fn isCjsExportTarget(self: *Parser, target_idx: NodeIndex) bool {
    if (target_idx.isNone() or @intFromEnum(target_idx) >= self.ast.nodes.items.len) return false;
    const target = self.ast.nodes.items[@intFromEnum(target_idx)];
    if (target.tag == .identifier_reference and std.mem.eql(u8, self.ast.source[target.span.start..target.span.end], "exports")) {
        return true;
    }
    if (target.tag != .static_member_expression) return false;
    const e = target.data.extra;
    if (e + 1 >= self.ast.extra_data.items.len) return false;
    const obj_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[e]);
    const prop_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[e + 1]);
    if (obj_idx.isNone() or prop_idx.isNone()) return false;
    if (@intFromEnum(obj_idx) >= self.ast.nodes.items.len or @intFromEnum(prop_idx) >= self.ast.nodes.items.len) return false;
    const obj = self.ast.nodes.items[@intFromEnum(obj_idx)];
    const prop = self.ast.nodes.items[@intFromEnum(prop_idx)];
    return obj.tag == .identifier_reference and
        std.mem.eql(u8, self.ast.source[obj.span.start..obj.span.end], "module") and
        std.mem.eql(u8, self.ast.source[prop.span.start..prop.span.end], "exports");
}
