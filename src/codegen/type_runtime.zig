//! Codegen helpers for TS/Flow declarations that emit runtime JavaScript.

const std = @import("std");
const ast_mod = @import("../parser/ast.zig");
const Node = ast_mod.Node;
const NodeIndex = ast_mod.NodeIndex;
const Ast = ast_mod.Ast;
const FlowEnumBaseType = @import("../parser/flow.zig").FlowEnumBaseType;
const SyntheticKind = @import("../semantic/symbol.zig").SyntheticKind;
const rt = @import("../bundler/runtime_helpers.zig");
pub const Error = std.mem.Allocator.Error || @import("errors.zig").Error;
const bindings = @import("bindings.zig");
const NamespaceFrame = @import("codegen.zig").NamespaceFrame;
const NamespacePrefix = @import("codegen.zig").NamespacePrefix;

/// enum Color { Red, Green = 5, Blue } →
/// var Color;((Color) => {Color[Color["Red"]=0]="Red";Color[Color["Green"]=5]="Green";Color[Color["Blue"]=6]="Blue";})(Color || (Color = {}));
pub fn emitEnumIIFE(self: anytype, node: Node, enum_idx: NodeIndex) !void {
    return emitEnumIIFEInner(self, node, enum_idx, null);
}

/// The exported enum declaration itself supplies the namespace member target.
/// Its local binding is initialized from that shared object before members run.
fn emitNamespaceEnumIIFE(self: anytype, node: Node, enum_idx: NodeIndex, namespace_param: NamespacePrefix) !void {
    return emitEnumIIFEInner(self, node, enum_idx, namespace_param);
}

fn emitEnumIIFEInner(self: anytype, node: Node, enum_idx: NodeIndex, namespace_param: ?NamespacePrefix) !void {
    try self.addSourceMapping(node.span);
    const e = node.data.extra;
    const name_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[e]);
    const members_start = self.ast.extra_data.items[e + 1];
    const members_len = self.ast.extra_data.items[e + 2];
    // extras[3]: bit0=const, bit1=ambient. 둘 다 transformer에서 제거되므로
    // 이 런타임 emitter에는 일반 enum(flags=0)만 도달한다.

    // enum 이름 텍스트 가져오기
    const name_node = self.ast.getNode(name_idx);
    const name_text = self.ast.getText(name_node.span);

    // 각 멤버의 resolved 값을 수집 (멤버 간 참조 인라이닝용)
    const member_indices = self.ast.extra_data.items[members_start .. members_start + members_len];

    // 멤버 이름→값 매핑 (enum 자기 참조 인라이닝용)
    var member_values: std.StringHashMapUnmanaged(EnumMemberValue) = .empty;
    defer member_values.deinit(self.allocator);

    // 1차 패스에서 needs_rename도 같이 판별 (별도 순회 불필요)
    var needs_rename = false;

    // 1차 패스: 멤버 값 수집 + needs_rename 판별 (출력 전에 실행)
    {
        var auto_value: i64 = 0;
        var auto_valid = true;
        for (member_indices) |raw_idx| {
            const member = self.ast.getNode(@enumFromInt(raw_idx));
            const member_name = self.ast.getNode(member.data.binary.left);
            const raw_text = self.ast.getText(member_name.span);
            const mt = Ast.stripStringQuotes(raw_text);
            const member_init_idx = member.data.binary.right;

            if (!needs_rename and std.mem.eql(u8, mt, name_text)) {
                needs_rename = true;
            }

            if (!member_init_idx.isNone()) {
                const init_node = self.ast.getNode(member_init_idx);
                if (init_node.tag == .numeric_literal) {
                    const num_text = self.ast.getText(init_node.span);
                    if (std.fmt.parseInt(i64, num_text, 10)) |v| {
                        try member_values.put(self.allocator, mt, .{ .int = v });
                        auto_value = v + 1;
                        auto_valid = true;
                    } else |_| {
                        try member_values.put(self.allocator, mt, .{ .raw = num_text });
                        auto_valid = false;
                    }
                } else if (init_node.tag == .identifier_reference) {
                    const ref_text = self.ast.getText(init_node.span);
                    if (member_values.get(ref_text)) |resolved| {
                        try member_values.put(self.allocator, mt, resolved);
                        switch (resolved) {
                            .int => |v| {
                                auto_value = v + 1;
                                auto_valid = true;
                            },
                            .raw, .str => {
                                auto_valid = false;
                            },
                        }
                    } else {
                        auto_valid = false;
                    }
                } else if (init_node.tag == .string_literal) {
                    const str_text = self.ast.getText(init_node.span);
                    try member_values.put(self.allocator, mt, .{ .str = str_text });
                    auto_valid = false;
                } else {
                    auto_valid = false;
                }
            } else {
                if (auto_valid) {
                    try member_values.put(self.allocator, mt, .{ .int = auto_value });
                    auto_value += 1;
                }
            }
        }
    }

    var owned_param: ?[]u8 = null;
    defer if (owned_param) |param| std.heap.page_allocator.free(param);
    const semantic_param_name = try enumIifeParamName(self, enum_idx);
    const param_name = semantic_param_name orelse if (needs_rename) blk: {
        var suffix: u32 = 0;
        while (true) : (suffix += 1) {
            const candidate = if (suffix == 0)
                try std.fmt.allocPrint(std.heap.page_allocator, "_{s}", .{name_text})
            else
                try std.fmt.allocPrint(std.heap.page_allocator, "_{s}{d}", .{ name_text, suffix });
            if (!generatedIifeParamReserved(self, candidate, null)) {
                owned_param = candidate;
                break :blk candidate;
            }
            std.heap.page_allocator.free(candidate);
        }
    } else name_text;

    // var Color = /* @__PURE__ */ ((Color) => { ...; return Color; })(Color || {});
    // esm_var_assign_only: var 선언은 이미 __esm 밖 top-level에 hoisted.
    // factory 안에서는 할당만 출력.
    if (!self.options.esm_var_assign_only) try self.write("var ");
    try self.emitNode(name_idx);
    try self.write(" = /* @__PURE__ */ ((");
    try self.write(param_name);
    try self.write(") => {");

    // 2차 패스: 각 멤버 출력
    var auto_value: i64 = 0;
    for (member_indices) |raw_idx| {
        const member = self.ast.getNode(@enumFromInt(raw_idx));
        // ts_enum_member: binary = { left=name, right=init_val }
        const member_name_idx = member.data.binary.left;
        const member_init_idx = member.data.binary.right;

        const member_name = self.ast.getNode(member_name_idx);
        const raw_text = self.ast.getText(member_name.span);
        // 문자열 리터럴 키의 따옴표 제거: 'a' → a, "a b" → a b
        const member_text = Ast.stripStringQuotes(raw_text);

        // String enum 멤버는 reverse mapping 을 만들지 않음 (TS spec).
        const is_string_member = if (member_values.get(member_text)) |resolved|
            resolved == .str
        else
            false;

        // single-line IIFE: 멤버별 anchor 가 없으면 직전 segment 로 fallback 되어
        // debugger 가 잘못된 line 을 표시.
        try self.addSourceMapping(member_name.span);

        // numeric: Color[Color["Red"]=0]="Red"  → outer wrap 추가
        // string : Color["X"]="x"               → wrap 없음
        if (!is_string_member) {
            try self.write(param_name);
            try self.writeByte('[');
        }
        try self.write(param_name);
        try self.write("[\"");
        try self.write(member_text);
        try self.write("\"]=");

        if (!member_init_idx.isNone()) {
            const init_node = self.ast.getNode(member_init_idx);
            // enum 멤버가 다른 멤버를 참조하는 경우 → 인라이닝
            if (init_node.tag == .identifier_reference) {
                const ref_text = self.ast.getText(init_node.span);
                if (member_values.get(ref_text)) |resolved| {
                    // 인라인된 값 출력 + 원본을 주석으로
                    switch (resolved) {
                        .int => |v| try emitInt(self, v),
                        .raw => |r| try self.write(r),
                        .str => |s| try self.write(s),
                    }
                    try self.write(" /* ");
                    try self.write(ref_text);
                    try self.write(" */");
                } else {
                    try self.emitNode(member_init_idx);
                }
            } else {
                // 이니셜라이저가 있으면 그대로 출력
                try self.emitNode(member_init_idx);
            }
            // auto_value 갱신: 1차 패스의 resolved 값을 사용 (identifier_reference 인라인 포함)
            if (member_values.get(member_text)) |resolved| {
                switch (resolved) {
                    .int => |v| {
                        auto_value = v + 1;
                    },
                    .raw, .str => {},
                }
            }
        } else {
            // 자동 증가 값 출력
            try emitInt(self, auto_value);
            auto_value += 1;
        }

        if (is_string_member) {
            try self.writeByte(';');
        } else {
            try self.write("]=\"");
            try self.write(member_text);
            try self.write("\";");
        }
    }

    // return Color;})(Color || {});
    // IIFE trailing 도 enum 이름 위치로 anchor — 마지막 멤버 segment 로의 fallback 방지.
    try self.addSourceMapping(name_node.span);
    try self.write("return ");
    try self.write(param_name);
    try self.write(";})(");
    try self.emitNode(name_idx);
    if (namespace_param) |ns| {
        const ns_name = self.namespacePrefixName(ns);
        try self.writeByte('=');
        try self.write(ns_name);
        try self.writeByte('.');
        try self.write(name_text);
        try self.write(" || (");
        try self.write(ns_name);
        try self.writeByte('.');
        try self.write(name_text);
        try self.write(" = {}));");
    } else {
        try self.write(" || {});");
    }
}

const EnumMemberValue = union(enum) {
    int: i64,
    raw: []const u8, // float 등 숫자 원본 텍스트
    str: []const u8, // 문자열 리터럴 원본 텍스트
};

/// Flow enum 출력 — `babel-plugin-transform-flow-enums` 와 동작 동등 (런타임 helper
/// API: \`X.cast(v)\` / \`X.members()\` / \`X.getName(v)\` 등). \`flow-enums-runtime\`
/// package 의 callable 결과를 사용. 예전 \`Object.freeze({...})\` 형태는 helper API
/// 미지원이라 RN core 의 `VirtualViewMode.cast(value)` 같은 호출에서 TypeError.
///
/// extra = [name, members_start, members_len, base_type].
/// base_type (FlowEnumBaseType: 0=none/symbol-implicit, 1=string, 2=number,
/// 3=boolean, 4=symbol). init 가 .none 인 멤버는 base_type 에 따라 기본값:
///   - none / symbol → `Symbol("Name")`
///   - string → `"Name"` (멤버 이름)
///   - number → 인덱스 (0, 1, 2, ...)
///   - boolean → `false` (의미 없는 fallback)
///
/// emit 형태 (reference 와 동일):
///   - string body + all defaulted (mirrored): \`require('flow-enums-runtime').Mirrored(['A', 'B'])\`
///   - 그 외 (Symbol/number/boolean/string-with-init): \`require('flow-enums-runtime')({A:<v>, B:<v>})\`
///   - Symbol body: 각 member 의 init 으로 \`Symbol('name')\` 자동 emit
///   - number/boolean body + defaulted: ZNTC 가 default value (auto-increment / false) 채움
pub fn emitFlowEnum(self: anytype, node: Node) Error!void {
    try self.addSourceMapping(node.span);
    const e = node.data.extra;
    const name_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[e]);
    const members_start = self.ast.extra_data.items[e + 1];
    const members_len = self.ast.extra_data.items[e + 2];
    const base_type_raw = self.ast.extra_data.items[e + 3];
    const base_type: FlowEnumBaseType = @enumFromInt(base_type_raw);

    const members = self.ast.extra_data.items[members_start .. members_start + members_len];

    // Mirrored 케이스: string body + 첫 멤버 init 없음 (= all defaulted 가정 — reference 동일).
    const is_mirrored = base_type == .string and (members.len == 0 or
        self.ast.getNode(@enumFromInt(members[0])).data.binary.right == .none);

    try self.write("const ");
    // The enum binding is a source SymbolId. Route its declaration through
    // normal identifier emission so single-file mangling renames it together
    // with references instead of leaving the source spelling here.
    try self.emitNode(name_idx);
    try self.writeByte('=');
    if (self.resolveRequireRewriteSpecifier(rt.FLOW_ENUMS_RUNTIME_SPECIFIER)) |req_var| {
        try self.emitRewriteValue(req_var);
    } else {
        try self.write("require(\"" ++ rt.FLOW_ENUMS_RUNTIME_SPECIFIER ++ "\")");
    }

    if (is_mirrored) {
        try self.write(".Mirrored([");
        var emitted: u32 = 0;
        for (members) |raw_idx| {
            const member = self.ast.getNode(@enumFromInt(raw_idx));
            // 키 없는(무효) 멤버 — member.binary.left 무조건 getNode 하므로
            // .none 이면 OOB. 무효 입력에서만 발생, skip 으로 견고화.
            if (member.data.binary.left.isNone()) continue;
            if (emitted > 0) try self.writeByte(',');
            emitted += 1;
            const member_name_node = self.ast.getNode(member.data.binary.left);
            const member_name = Ast.stripStringQuotes(self.ast.getText(member_name_node.span));
            try self.writeByte('"');
            try self.write(member_name);
            try self.writeByte('"');
        }
        try self.write("]);");
        return;
    }

    try self.write("({");
    var auto_idx: u32 = 0;
    var emitted: u32 = 0;
    for (members) |raw_idx| {
        const member = self.ast.getNode(@enumFromInt(raw_idx));
        if (member.data.binary.left.isNone()) continue; // 무효 멤버 방어 (위와 동일)
        if (emitted > 0) try self.writeByte(',');
        emitted += 1;
        const member_name_node = self.ast.getNode(member.data.binary.left);
        const member_name = Ast.stripStringQuotes(self.ast.getText(member_name_node.span));
        try self.write(member_name);
        try self.writeByte(':');

        const init_idx = member.data.binary.right;
        if (!init_idx.isNone()) {
            try self.emitNode(init_idx);
        } else {
            try emitFlowEnumDefaultValue(self, base_type_raw, member_name, auto_idx);
        }
        auto_idx += 1;
    }
    try self.write("});");
}

fn emitFlowEnumDefaultValue(self: anytype, base_type: u32, member_name: []const u8, auto_idx: u32) std.mem.Allocator.Error!void {
    const kind: FlowEnumBaseType = @enumFromInt(base_type);
    switch (kind) {
        .none, .symbol => {
            try self.write("Symbol(\"");
            try self.write(member_name);
            try self.write("\")");
        },
        .string => {
            try self.writeByte('"');
            try self.write(member_name);
            try self.writeByte('"');
        },
        .number => {
            var buf: [16]u8 = undefined;
            const slice = std.fmt.bufPrint(&buf, "{d}", .{auto_idx}) catch unreachable;
            try self.write(slice);
        },
        // Flow 는 bigint enum 멤버에 명시 `= Nn` 을 강제(default 불가)하므로 정상
        // 입력에선 unreachable — exhaustive 보장 + 방어값(number 동형 + `n`).
        .bigint => {
            var buf: [17]u8 = undefined;
            const slice = std.fmt.bufPrint(&buf, "{d}n", .{auto_idx}) catch unreachable;
            try self.write(slice);
        },
        .boolean => try self.write("false"),
    }
}

/// namespace Foo { export const x = 1; } →
/// var Foo;((Foo) => {const x=1;Foo.x=x;})(Foo || (Foo = {}));
///
/// 현재 단순 구현: 내부 문을 그대로 출력하고, export 문은 Foo.name = name으로 변환.
pub fn emitNamespaceIIFE(self: anytype, node: Node, namespace_idx: NodeIndex) !void {
    return emitNamespaceIIFEInner(self, node, namespace_idx, .root);
}

const NamespacePlacement = union(enum) {
    root,
    local,
    property: NamespacePrefix,
};

/// Placement distinguishes a top-level namespace, a private nested binding,
/// and an exported namespace stored on its parent's object.
const NamespaceIifeParameter = struct {
    symbol_id: u32,
    name: []const u8,
};

/// A supplied owner map marks semantic codegen: in that mode a namespace IIFE
/// must resolve to its exact generated parameter symbol. The null-map path is
/// retained for low-level callers that intentionally skip semantic analysis.
fn namespaceIifeParameter(self: anytype, namespace_idx: NodeIndex) !?NamespaceIifeParameter {
    if (self.options.generated_iife_scope_owner_map == null) return null;
    const symbol_id = generatedIifeParamSymbolId(self, namespace_idx, .namespace_iife_parameter) orelse
        return error.MissingNamespaceIifeParameterSymbol;
    return .{
        .symbol_id = symbol_id,
        .name = generatedIifeParamNameFromSymbolId(self, symbol_id),
    };
}

fn enumIifeParamName(self: anytype, enum_idx: NodeIndex) !?[]const u8 {
    if (self.options.generated_iife_scope_owner_map == null) return null;
    const symbol_id = generatedIifeParamSymbolId(self, enum_idx, .enum_iife_parameter) orelse
        return error.MissingEnumIifeParameterSymbol;
    return generatedIifeParamNameFromSymbolId(self, symbol_id);
}

/// Emit a semantic bare enum-member reference as a property read on the
/// generated IIFE parameter. The virtual member SymbolId points at its owning
/// IIFE scope, where the matching enum parameter row supplies the output name.
pub fn emitEnumIifeMemberReference(self: anytype, node: Node, member: anytype) !bool {
    if (member.synthetic_kind != .enum_iife_member) return false;
    const owner_id = member.synthetic_owner_id orelse return error.InvalidEnumIifeMemberSymbol;
    const owner_raw = @intFromEnum(owner_id);
    if (owner_raw >= self.options.semantic_symbols.len) return error.InvalidEnumIifeMemberSymbol;
    const parameter = self.options.semantic_symbols[owner_raw];
    if (parameter.synthetic_kind != .enum_iife_parameter or parameter.scope_id != member.scope_id)
        return error.InvalidEnumIifeMemberSymbol;
    const parameter_name = generatedIifeParamNameFromSymbolId(self, owner_raw);

    try self.addSourceMappingWithName(node.span, self.ast.identifierNameText(node));
    try self.write(parameter_name);
    const raw_key = self.ast.getText(member.name);
    if (raw_key.len > 0 and (raw_key[0] == '\'' or raw_key[0] == '"')) {
        try self.writeByte('[');
        try self.writeStringLiteral(member.name);
        try self.writeByte(']');
    } else {
        try self.writeByte('.');
        try self.writeIdentifierSpan(member.name);
    }
    return true;
}

fn generatedIifeParamNameFromSymbolId(self: anytype, raw_id: u32) []const u8 {
    const symbol = self.options.semantic_symbols[@intCast(raw_id)];
    if (self.options.linking_metadata) |metadata| {
        if (metadata.renames.get(raw_id)) |renamed| return renamed;
    }
    return symbol.synthetic_name;
}

fn generatedIifeParamSymbolId(self: anytype, owner_idx: NodeIndex, expected_kind: SyntheticKind) ?u32 {
    const owners = self.options.generated_iife_scope_owner_map orelse return null;
    const scope = owners.get(@intFromEnum(owner_idx)) orelse return null;
    if (scope >= self.options.semantic_scope_maps.len) return null;
    var scope_bindings = self.options.semantic_scope_maps[scope].iterator();
    while (scope_bindings.next()) |binding| {
        const raw_id = binding.value_ptr.*;
        if (raw_id >= self.options.semantic_symbols.len) continue;
        const symbol = self.options.semantic_symbols[raw_id];
        if (symbol.synthetic_kind != expected_kind or @intFromEnum(symbol.scope_id) != scope) continue;
        return @intCast(raw_id);
    }
    return null;
}

fn emitNamespaceIIFEInner(self: anytype, node: Node, namespace_idx: NodeIndex, placement: NamespacePlacement) !void {
    try self.addSourceMapping(node.span);
    const name_idx = node.data.binary.left;
    const body_idx = node.data.binary.right;

    // 중첩 namespace (A.B.C)인 경우: right가 ts_module_declaration
    const body_node = self.ast.getNode(body_idx);
    if (body_node.tag == .ts_module_declaration) {
        const name_node = self.ast.getNode(name_idx);
        const name_text = self.ast.getText(name_node.span);
        const local_name = namespaceLocalName(self, name_idx, name_text);
        const namespace_parameter = try namespaceIifeParameter(self, namespace_idx);
        const iife_param_name = if (namespace_parameter) |parameter| parameter.name else name_text;
        const namespace_prefix: NamespacePrefix = .{
            .symbol_id = if (namespace_parameter) |parameter| parameter.symbol_id else null,
            .fallback_name = iife_param_name,
        };

        // A nested namespace is block-scoped whether it is private or exported.
        if (namespacePlacementIsNested(placement)) {
            try self.write("let ");
        } else {
            try self.write("var ");
        }
        try self.write(local_name);
        try self.writeByte(';');
        try self.write("((");
        try self.write(iife_param_name);
        try self.write(") => {");
        const outer_declared_names = self.declared_names;
        self.declared_names = .empty;
        defer {
            self.declared_names.deinit(self.allocator);
            self.declared_names = outer_declared_names;
        }
        // 내부 namespace를 재귀 출력 (부모 이름 전달)
        try emitNamespaceIIFEInner(self, body_node, body_idx, .{ .property = namespace_prefix });
        try emitNamespaceIIFEClosing(self, placement, local_name, name_text);
        return;
    }

    // body가 block_statement인 경우 (일반 namespace)
    const name_node = self.ast.getNode(name_idx);
    const name_text = self.ast.getText(name_node.span);
    const local_name = namespaceLocalName(self, name_idx, name_text);

    // Nested namespaces use lexical bindings; top-level namespaces use var.
    // 같은 이름이 이미 선언되었으면 var/let 생략 (function + namespace 병합 등)
    if (!self.declared_names.contains(name_text) and !self.declared_names.contains(local_name)) {
        if (namespacePlacementIsNested(placement)) {
            try self.write("let ");
        } else {
            try self.write("var ");
        }
        try self.write(local_name);
        try self.writeByte(';');
    }
    self.declared_names.put(self.allocator, name_text, {}) catch {};
    self.declared_names.put(self.allocator, local_name, {}) catch {};

    // Each namespace body is emitted as its own function. Names declared by
    // one IIFE cannot suppress declarations in a later merged IIFE.
    const outer_declared_names = self.declared_names;
    self.declared_names = .empty;
    defer {
        self.declared_names.deinit(self.allocator);
        self.declared_names = outer_declared_names;
    }

    // 1단계: export된 이름 수집 (IIFE 열기 전에 — 파라미터 충돌 감지용)
    var ns_export_map: std.StringHashMapUnmanaged(void) = .empty;
    defer ns_export_map.deinit(self.allocator);
    if (body_node.tag == .block_statement) {
        const list = body_node.data.list;
        const indices = self.ast.extra_data.items[list.start .. list.start + list.len];
        for (indices) |raw_idx| {
            const stmt_node = self.ast.getNode(@enumFromInt(raw_idx));
            if (stmt_node.tag == .export_named_declaration) {
                const e = stmt_node.data.extra;
                const decl_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[e]);
                if (!decl_idx.isNone()) {
                    collectExportNames(self, &ns_export_map, decl_idx) catch {};
                }
            }
        }
    }

    // The synthetic parameter must not capture any source identifier. Its
    // spelling is selected from the exact AST identifiers and linker renames;
    // exported references themselves are resolved by SymbolId below.
    var owned_param: ?[]u8 = null;
    defer if (owned_param) |p| std.heap.page_allocator.free(p);
    const namespace_parameter = try namespaceIifeParameter(self, namespace_idx);
    var param_name = if (namespace_parameter) |parameter| parameter.name else name_text;
    const namespace_param_context = NamespaceParamContext{ .name_idx = name_idx, .body_idx = body_idx };
    if (namespace_parameter == null and
        (ns_export_map.contains(name_text) or generatedIifeParamReserved(self, name_text, namespace_param_context)))
    {
        var suffix: u32 = 0;
        while (true) : (suffix += 1) {
            const candidate = if (suffix == 0)
                try std.fmt.allocPrint(std.heap.page_allocator, "_{s}", .{name_text})
            else
                try std.fmt.allocPrint(std.heap.page_allocator, "_{s}{d}", .{ name_text, suffix });
            if (!generatedIifeParamReserved(self, candidate, null)) {
                owned_param = candidate;
                param_name = candidate;
                break;
            }
            std.heap.page_allocator.free(candidate);
        }
    }
    const namespace_prefix: NamespacePrefix = .{
        .symbol_id = if (namespace_parameter) |parameter| parameter.symbol_id else null,
        .fallback_name = param_name,
    };

    // ((Foo) => { ... })(Foo || (Foo = {}));
    try self.write("((");
    try self.write(param_name);
    try self.write(") => {");

    var frame: NamespaceFrame = .{
        .prefix = namespace_prefix,
        .parent = self.ns_frame,
    };
    const saved_frame = self.ns_frame;
    self.ns_frame = &frame;
    defer self.ns_frame = saved_frame;

    // 3단계: body 출력 (export 문은 Foo.name = expr 형태로 변환)
    if (body_node.tag == .block_statement) {
        const list = body_node.data.list;
        const indices = self.ast.extra_data.items[list.start .. list.start + list.len];
        for (indices) |raw_idx| {
            const stmt_node = self.ast.getNode(@enumFromInt(raw_idx));
            switch (stmt_node.tag) {
                .export_named_declaration => {
                    const e = stmt_node.data.extra;
                    const extras = self.ast.extra_data.items[e .. e + 4];
                    const decl_idx: NodeIndex = @enumFromInt(extras[0]);
                    if (decl_idx.isNone() and extras[2] > 0 and @as(NodeIndex, @enumFromInt(extras[3])).isNone()) {
                        // Some declaration transforms replace an exported class
                        // with a local declaration plus `export { Local as Name }`.
                        // Inside a TS namespace that specifier is the namespace
                        // export edge, not an ECMAScript module export. Preserve
                        // the edge here and emit the local through its SymbolId so
                        // later renames stay attached to the binding.
                        try emitNamespaceExportSpecifiers(self, namespace_prefix, extras[1], extras[2]);
                        continue;
                    }
                    if (!decl_idx.isNone()) {
                        const decl_node = self.ast.getNode(decl_idx);
                        // export namespace bar {} → 중첩 namespace (부모 이름 전달)
                        if (decl_node.tag == .ts_module_declaration) {
                            try emitNamespaceIIFEInner(self, decl_node, decl_idx, .{ .property = namespace_prefix });
                        } else if (decl_node.tag == .variable_declaration) {
                            // 단순 바인딩(identifier)은 직접 프로퍼티 할당: ns.a=1;
                            // destructuring(array_pattern/object_pattern)이 섞이면 선언자마다 따로 낸다.
                            if (isSimpleVarDeclaration(self, decl_idx)) {
                                try emitNamespaceVarDirectAssign(self, namespace_prefix, decl_idx);
                            } else {
                                try emitNamespaceVarMixed(self, namespace_prefix, decl_idx);
                            }
                        } else if (decl_node.tag == .ts_enum_declaration) {
                            // The exported declaration names the exact member of this
                            // namespace object. Reuse its existing object across
                            // merged namespace IIFEs before evaluating enum members.
                            try emitNamespaceEnumIIFE(self, decl_node, decl_idx, namespace_prefix);
                        } else {
                            try self.emitNode(decl_idx);
                            try emitNamespaceExport(self, namespace_prefix, decl_idx);
                        }
                    }
                },
                .export_default_declaration => {
                    try self.write(self.namespacePrefixName(namespace_prefix));
                    try self.write(".default=");
                    try self.emitNode(stmt_node.data.unary.operand);
                    try self.writeByte(';');
                },
                .ts_module_declaration => {
                    try emitNamespaceIIFEInner(self, stmt_node, @enumFromInt(raw_idx), .local);
                },
                else => try self.emitNode(@enumFromInt(raw_idx)),
            }
        }
    }

    try emitNamespaceIIFEClosing(self, placement, local_name, name_text);
}

fn namespacePlacementIsNested(placement: NamespacePlacement) bool {
    return switch (placement) {
        .root => false,
        .local, .property => true,
    };
}

fn emitNamespaceIIFEClosing(
    self: anytype,
    placement: NamespacePlacement,
    local_name: []const u8,
    name_text: []const u8,
) !void {
    switch (placement) {
        .root, .local => try emitIIFEClosing(self, local_name),
        .property => |parent_prefix| {
            const parent_name = self.namespacePrefixName(parent_prefix);
            try self.write("})(");
            try self.write(local_name);
            try self.write(" = ");
            try self.write(parent_name);
            try self.writeByte('.');
            try self.write(name_text);
            try self.write(" || (");
            try self.write(parent_name);
            try self.writeByte('.');
            try self.write(name_text);
            try self.write(" = {}));");
        },
    }
}

/// enum/namespace IIFE 닫는 부분: })(name || (name = {}));
fn emitIIFEClosing(self: anytype, name_text: []const u8) !void {
    try self.write("})(");
    try self.write(name_text);
    try self.write(" || (");
    try self.write(name_text);
    try self.write(" = {}));");
}

fn emitNamespaceExportSpecifiers(self: anytype, ns_prefix: NamespacePrefix, specs_start: u32, specs_len: u32) !void {
    const ns_name = self.namespacePrefixName(ns_prefix);
    const spec_indices = self.ast.extra_data.items[specs_start .. specs_start + specs_len];
    for (spec_indices) |raw_idx| {
        const spec = self.ast.getNode(@enumFromInt(raw_idx));
        if (spec.tag != .export_specifier) continue;
        const local_idx = spec.data.binary.left;
        const exported_idx = spec.data.binary.right;
        if (local_idx.isNone() or exported_idx.isNone()) continue;
        const local = self.ast.getNode(local_idx);
        if (local.tag != .identifier_reference and local.tag != .binding_identifier) continue;

        const exported = self.ast.getNode(exported_idx);
        try self.addSourceMapping(exported.span);
        try self.write(ns_name);
        switch (exported.tag) {
            .identifier_reference, .binding_identifier => {
                try self.writeByte('.');
                try self.writeIdentifierSpan(exported.data.string_ref);
            },
            .string_literal => {
                try self.writeByte('[');
                try self.writeStringLiteral(exported.span);
                try self.writeByte(']');
            },
            else => continue,
        }
        try self.writeByte('=');
        try self.emitNode(local_idx);
        try self.writeByte(';');
    }
}

/// namespace 내부의 export 선언에서 이름을 추출하여 Foo.name = name; 형태로 출력.
fn emitNamespaceExport(self: anytype, ns_prefix: NamespacePrefix, decl_idx: NodeIndex) !void {
    const ns_name = self.namespacePrefixName(ns_prefix);
    const decl = self.ast.getNode(decl_idx);
    switch (decl.tag) {
        .variable_declaration => {
            // const x = 1, y = 2; → Foo.x = x; Foo.y = y;
            // var [a, b] = ref; → Foo.a = a; Foo.b = b;
            const e = decl.data.extra;
            const extras = self.ast.extra_data.items[e .. e + 3];
            const list_start = extras[1];
            const list_len = extras[2];
            const declarators = self.ast.extra_data.items[list_start .. list_start + list_len];
            for (declarators) |raw_idx| {
                const declarator = self.ast.getNode(@enumFromInt(raw_idx));
                const de = declarator.data.extra;
                const d_extras = self.ast.extra_data.items[de .. de + 3];
                const name_idx: NodeIndex = @enumFromInt(d_extras[0]);
                try emitNamespaceBindingExport(self, ns_prefix, name_idx);
            }
        },
        .function_declaration, .class_declaration, .ts_enum_declaration => {
            // function foo() {} → Foo.foo = foo;
            const e = decl.data.extra;
            const name_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[e]);
            if (!name_idx.isNone()) {
                const fn_name_node = self.ast.getNode(name_idx);
                const fn_name = self.ast.getText(fn_name_node.span);
                try self.write(ns_name);
                try self.writeByte('.');
                try self.write(fn_name);
                try self.writeByte('=');
                // The namespace property keeps the source export name, while
                // the local binding may have a SymbolId-based linker rename.
                try self.emitNode(name_idx);
                try self.writeByte(';');
            }
        },
        else => {},
    }
}

/// 바인딩 패턴에서 모든 binding_identifier를 추출하여 ns.name = name; 형태로 출력.
/// binding_identifier → ns.x = x;
/// array_pattern → 각 요소 재귀
/// object_pattern → 각 프로퍼티의 value 재귀
fn emitNamespaceBindingExport(self: anytype, ns_prefix: NamespacePrefix, name_idx: NodeIndex) !void {
    if (name_idx.isNone()) return;
    const ns_name = self.namespacePrefixName(ns_prefix);
    const node = self.ast.getNode(name_idx);
    switch (node.tag) {
        .binding_identifier => {
            const var_name = self.ast.getText(node.span);
            try self.write(ns_name);
            try self.writeByte('.');
            try self.write(var_name);
            try self.writeByte('=');
            // Export keys are public source names; local values must follow
            // the binding's SymbolId rename just like ordinary references.
            try self.emitNode(name_idx);
            try self.writeByte(';');
        },
        .array_pattern => {
            const split = self.ast.nodeListSplitRest(node.data.list);
            for (split.elements) |raw_idx| {
                try emitNamespaceBindingExport(self, ns_prefix, @enumFromInt(raw_idx));
            }
            if (split.rest_operand) |op| {
                try emitNamespaceBindingExport(self, ns_prefix, op);
            }
        },
        .object_pattern => {
            const split = self.ast.nodeListSplitRest(node.data.list);
            for (split.elements) |raw_idx| {
                const prop = self.ast.getNode(@enumFromInt(raw_idx));
                // property_property: binary.right = value (binding pattern)
                try emitNamespaceBindingExport(self, ns_prefix, prop.data.binary.right);
            }
            if (split.rest_operand) |op| {
                try emitNamespaceBindingExport(self, ns_prefix, op);
            }
        },
        // `[b = 7]`·`{ x = 1 }` — 바인딩 패턴의 기본값은 `assignment_pattern` 이다. 빠뜨리면
        // 그 이름이 namespace 에 안 실린다.
        .assignment_target_with_default, .assignment_pattern => {
            try emitNamespaceBindingExport(self, ns_prefix, node.data.binary.left);
        },
        else => {},
    }
}

/// variable_declaration의 모든 declarator가 단순 binding_identifier인지 확인.
/// destructuring (array_pattern, object_pattern)이 있으면 false.
fn isSimpleVarDeclaration(self: anytype, decl_idx: NodeIndex) bool {
    const decl = self.ast.getNode(decl_idx);
    const e = decl.data.extra;
    const extras = self.ast.extra_data.items[e .. e + 3];
    const list_start = extras[1];
    const list_len = extras[2];
    const declarators = self.ast.extra_data.items[list_start .. list_start + list_len];
    for (declarators) |raw_idx| {
        const declarator = self.ast.getNode(@enumFromInt(raw_idx));
        const de = declarator.data.extra;
        const name_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[de]);
        const name_node = self.ast.getNode(name_idx);
        if (name_node.tag != .binding_identifier) return false;
    }
    return true;
}

/// namespace 내부의 export variable_declaration을 직접 ns.prop = init 형태로 출력.
/// local 변수를 만들지 않으므로 reserved word 문제(let await)와 stale local 문제를 모두 해결.
/// 예: export let a = 1, b = a → ns.a=1;ns.b=ns.a;
fn emitNamespaceVarDirectAssign(self: anytype, ns_prefix: NamespacePrefix, decl_idx: NodeIndex) !void {
    const ns_name = self.namespacePrefixName(ns_prefix);
    const decl = self.ast.getNode(decl_idx);
    const keyword = bindings.declarationKeyword(self, self.ast.variableDeclarationKind(decl));
    const e = decl.data.extra;
    const extras = self.ast.extra_data.items[e .. e + 3];
    const list_start = extras[1];
    const list_len = extras[2];
    const declarators = self.ast.extra_data.items[list_start .. list_start + list_len];
    for (declarators) |raw_idx| {
        const declarator = self.ast.getNode(@enumFromInt(raw_idx));
        const de = declarator.data.extra;
        const d_extras = self.ast.extra_data.items[de .. de + 3];
        const name_idx: NodeIndex = @enumFromInt(d_extras[0]);
        const init_idx: NodeIndex = @enumFromInt(d_extras[2]);
        // init이 없으면 할당할 값이 없으므로 스킵 (esbuild 호환)
        if (init_idx.isNone()) continue;
        const var_name_node = self.ast.getNode(name_idx);
        const var_name = self.ast.getText(var_name_node.span);
        if (isDestructuringTempBinding(self, name_idx)) {
            try self.write(keyword);
            // The transformed declaration and its generated references share
            // a semantic SymbolId. Emit the binding through codegen so an
            // identifier rename cannot affect only the reads.
            try self.emitNode(name_idx);
            try self.writeByte('=');
            try self.emitNode(init_idx);
            try self.writeByte(';');
            continue;
        }
        try self.write(ns_name);
        try self.writeByte('.');
        try self.write(var_name);
        try self.writeByte('=');
        try self.emitNode(init_idx);
        try self.writeByte(';');
    }
}

/// 패턴 선언자가 섞인 export 선언을 선언자마다 따로 낸다: 단순 이름은 `ns.x=init;`,
/// 패턴은 `let [a]=init;ns.a=a;`. 한 선언으로 지역 선언하면 단순 이름은 export 목록에 있어
/// 같은 선언 안의 참조가 `ns.x` 로 치환되는데, 그 값은 선언이 끝난 뒤에야 복사되므로 아직
/// 비어 있다 — `export const x = 1, [y] = [x]` 에서 y 가 undefined. 구조 분해를 낮추며 생긴
/// 임시 변수(`_a = o, a = _a.a`)가 minify 의 선언 병합으로 패턴 선언자와 한 선언이 될 때도 같다.
fn emitNamespaceVarMixed(self: anytype, ns_prefix: NamespacePrefix, decl_idx: NodeIndex) !void {
    const ns_name = self.namespacePrefixName(ns_prefix);
    const decl = self.ast.getNode(decl_idx);
    const keyword = bindings.declarationKeyword(self, self.ast.variableDeclarationKind(decl));
    const e = decl.data.extra;
    const list_start = self.ast.extra_data.items[e + 1];
    const list_len = self.ast.extra_data.items[e + 2];
    var i: u32 = 0;
    while (i < list_len) : (i += 1) {
        const raw_idx = self.ast.extra_data.items[list_start + i];
        const declarator = self.ast.getNode(@enumFromInt(raw_idx));
        const de = declarator.data.extra;
        const name_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[de]);
        const init_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[de + 2]);
        const name_node = self.ast.getNode(name_idx);
        if (name_node.tag == .binding_identifier) {
            // init 이 없으면 할당할 값이 없다 (emitNamespaceVarDirectAssign 과 같음).
            if (init_idx.isNone()) continue;
            if (isDestructuringTempBinding(self, name_idx)) {
                try self.write(keyword);
                // Keep the declaration spelling in sync with the generated
                // reads that go through emitNode and the SymbolId mangler.
                try self.emitNode(name_idx);
                try self.writeByte('=');
                try self.emitNode(init_idx);
                try self.writeByte(';');
                continue;
            }
            try self.write(ns_name);
            try self.writeByte('.');
            try self.write(self.ast.getText(name_node.span));
            try self.writeByte('=');
            try self.emitNode(init_idx);
            try self.writeByte(';');
        } else {
            try self.write(keyword);
            try self.emitNode(@enumFromInt(raw_idx));
            try self.writeByte(';');
            try emitNamespaceBindingExport(self, ns_prefix, name_idx);
        }
    }
}

/// export 선언에서 이름을 추출하여 ns_export_map에 등록.
fn collectExportNames(self: anytype, map: *std.StringHashMapUnmanaged(void), decl_idx: NodeIndex) !void {
    const decl = self.ast.getNode(decl_idx);
    switch (decl.tag) {
        .variable_declaration => {
            const e = decl.data.extra;
            const list_start = self.ast.extra_data.items[e + 1];
            const list_len = self.ast.extra_data.items[e + 2];
            const declarators = self.ast.extra_data.items[list_start .. list_start + list_len];
            for (declarators) |raw_idx| {
                const declarator = self.ast.getNode(@enumFromInt(raw_idx));
                const name_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[declarator.data.extra]);
                if (isDestructuringTempBinding(self, name_idx)) continue;
                const name_node = self.ast.getNode(name_idx);
                const name = self.ast.getText(name_node.span);
                try map.put(self.allocator, name, {});
            }
        },
        .function_declaration, .class_declaration, .ts_enum_declaration => {
            const e = decl.data.extra;
            const name_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[e]);
            if (!name_idx.isNone()) {
                const name_node = self.ast.getNode(name_idx);
                const name = self.ast.getText(name_node.span);
                try map.put(self.allocator, name, {});
            }
        },
        else => {},
    }
}

fn isDestructuringTempBinding(self: anytype, idx: NodeIndex) bool {
    if (self.options.destructuring_temp_bindings) |bindings_map| {
        return bindings_map.contains(@intFromEnum(idx));
    }
    return false;
}

const NamespaceParamContext = struct {
    name_idx: NodeIndex,
    body_idx: NodeIndex,
};

fn generatedIifeParamReserved(
    self: anytype,
    candidate: []const u8,
    namespace_context: ?NamespaceParamContext,
) bool {
    var frame = self.ns_frame;
    while (frame) |active| : (frame = active.parent) {
        if (std.mem.eql(u8, self.namespacePrefixName(active.prefix), candidate)) return true;
    }
    if (self.options.linking_metadata) |metadata| {
        var it = metadata.renames.valueIterator();
        while (it.next()) |renamed| {
            if (std.mem.eql(u8, renamed.*, candidate)) return true;
        }
    }
    for (self.ast.nodes.items, 0..) |node, ni| {
        const relevant = switch (node.tag) {
            .binding_identifier,
            .import_default_specifier,
            .import_namespace_specifier,
            => true,
            .identifier_reference,
            .assignment_target_identifier,
            => namespace_context == null,
            else => false,
        };
        if (!relevant) continue;
        if (!std.mem.eql(u8, self.ast.identifierNameText(node), candidate)) continue;
        if (namespace_context) |context| {
            if (node.tag != .binding_identifier) return true;
            const binding_idx: NodeIndex = @enumFromInt(ni);
            if (binding_idx == context.name_idx) continue;
            // Separate merged declarations get separate IIFEs, so their
            // namespace names do not share this parameter's lexical scope.
            // Direct nested declarations do share the body scope and must
            // still reserve the spelling.
            if (isNamespaceDeclarationName(self, binding_idx) and
                !isDirectNamespaceNameInBody(self, context.body_idx, binding_idx))
            {
                continue;
            }
        }
        return true;
    }
    return false;
}

fn isNamespaceDeclarationName(self: anytype, name_idx: NodeIndex) bool {
    for (self.ast.nodes.items) |owner| {
        if (owner.tag == .ts_module_declaration and owner.data.binary.left == name_idx) return true;
    }
    return false;
}

fn isDirectNamespaceNameInBody(self: anytype, body_idx: NodeIndex, name_idx: NodeIndex) bool {
    if (body_idx.isNone()) return false;
    const body = self.ast.getNode(body_idx);
    if (body.tag == .ts_module_declaration) return body.data.binary.left == name_idx;
    if (body.tag != .block_statement) return false;

    const list = body.data.list;
    const indices = self.ast.extra_data.items[list.start .. list.start + list.len];
    for (indices) |raw_idx| {
        const stmt = self.ast.getNode(@enumFromInt(raw_idx));
        const decl_idx: NodeIndex = if (stmt.tag == .export_named_declaration) blk: {
            const extra_idx = stmt.data.extra;
            if (extra_idx >= self.ast.extra_data.items.len) continue;
            break :blk @enumFromInt(self.ast.extra_data.items[extra_idx]);
        } else @enumFromInt(raw_idx);
        if (decl_idx.isNone()) continue;
        const decl = self.ast.getNode(decl_idx);
        if (decl.tag == .ts_module_declaration and decl.data.binary.left == name_idx) return true;
    }
    return false;
}

fn namespaceLocalName(self: anytype, name_idx: NodeIndex, source_name: []const u8) []const u8 {
    if (self.options.linking_metadata) |metadata| {
        if (self.sourceSymbolId(name_idx)) |sid| {
            if (metadata.renames.get(sid)) |renamed| return renamed;
        }
    }
    return source_name;
}

fn emitInt(self: anytype, value: i64) !void {
    var buf: [20]u8 = undefined;
    const result = std.fmt.bufPrint(&buf, "{d}", .{value}) catch unreachable;
    try self.buf.appendSlice(self.allocator, result);
}
