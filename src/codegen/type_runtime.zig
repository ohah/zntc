//! Codegen helpers for TS/Flow declarations that emit runtime JavaScript.

const std = @import("std");
const ast_mod = @import("../parser/ast.zig");
const Node = ast_mod.Node;
const NodeIndex = ast_mod.NodeIndex;
const Ast = ast_mod.Ast;
const FlowEnumBaseType = @import("../parser/flow.zig").FlowEnumBaseType;
const rt = @import("../bundler/runtime_helpers.zig");

/// enum Color { Red, Green = 5, Blue } →
/// var Color;((Color) => {Color[Color["Red"]=0]="Red";Color[Color["Green"]=5]="Green";Color[Color["Blue"]=6]="Blue";})(Color || (Color = {}));
pub fn emitEnumIIFE(self: anytype, node: Node) !void {
    try self.addSourceMapping(node.span);
    const e = node.data.extra;
    const name_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[e]);
    const members_start = self.ast.extra_data.items[e + 1];
    const members_len = self.ast.extra_data.items[e + 2];
    // extras[3] = flags (0=일반, 1=const). const enum은 transformer에서 삭제됨.

    // enum 이름 텍스트 가져오기
    const name_node = self.ast.getNode(name_idx);
    const name_text = self.ast.getText(name_node.span);

    // 각 멤버의 resolved 값을 수집 (멤버 간 참조 인라이닝용)
    const member_indices = self.ast.extra_data.items[members_start .. members_start + members_len];

    // 멤버 이름→값 매핑 (enum 자기 참조 인라이닝용)
    var member_values: std.StringHashMapUnmanaged(EnumMemberValue) = .{};
    defer member_values.deinit(self.allocator);

    // 1차 패스에서 needs_rename도 같이 판별 (별도 순회 불필요)
    var needs_rename = false;

    // TS 식별자는 실전에서 256자를 넘지 않음
    var param_buf: [256]u8 = undefined;

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

    const param_name = if (needs_rename) blk: {
        const len = @min(name_text.len + 1, param_buf.len);
        param_buf[0] = '_';
        @memcpy(param_buf[1..len], name_text[0 .. len - 1]);
        break :blk param_buf[0..len];
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
    try self.write(" || {});");
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
pub fn emitFlowEnum(self: anytype, node: Node) std.mem.Allocator.Error!void {
    try self.addSourceMapping(node.span);
    const e = node.data.extra;
    const name_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[e]);
    const members_start = self.ast.extra_data.items[e + 1];
    const members_len = self.ast.extra_data.items[e + 2];
    const base_type_raw = self.ast.extra_data.items[e + 3];
    const base_type: FlowEnumBaseType = @enumFromInt(base_type_raw);

    const name_node = self.ast.getNode(name_idx);
    const name_text = self.ast.getText(name_node.span);

    const members = self.ast.extra_data.items[members_start .. members_start + members_len];

    // Mirrored 케이스: string body + 첫 멤버 init 없음 (= all defaulted 가정 — reference 동일).
    const is_mirrored = base_type == .string and (members.len == 0 or
        self.ast.getNode(@enumFromInt(members[0])).data.binary.right == .none);

    try self.write("const ");
    try self.write(name_text);
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
pub fn emitNamespaceIIFE(self: anytype, node: Node) !void {
    return emitNamespaceIIFEInner(self, node, null);
}

/// parent_ns: 부모 namespace 이름 (중첩 시 foo.bar 경로 생성용)
fn emitNamespaceIIFEInner(self: anytype, node: Node, parent_ns: ?[]const u8) !void {
    try self.addSourceMapping(node.span);
    const name_idx = node.data.binary.left;
    const body_idx = node.data.binary.right;

    // 중첩 namespace (A.B.C)인 경우: right가 ts_module_declaration
    const body_node = self.ast.getNode(body_idx);
    if (body_node.tag == .ts_module_declaration) {
        const name_node = self.ast.getNode(name_idx);
        const name_text = self.ast.getText(name_node.span);

        // 부모가 있으면 let, 없으면 var
        if (parent_ns != null) {
            try self.write("let ");
        } else {
            try self.write("var ");
        }
        try self.write(name_text);
        try self.writeByte(';');
        try self.write("((");
        try self.write(name_text);
        try self.write(") => {");
        // 내부 namespace를 재귀 출력 (부모 이름 전달)
        try emitNamespaceIIFEInner(self, body_node, name_text);
        // 중첩 closing: (bar = foo.bar || (foo.bar = {}))
        if (parent_ns) |pns| {
            try self.write("})(");
            try self.write(name_text);
            try self.write(" = ");
            try self.write(pns);
            try self.writeByte('.');
            try self.write(name_text);
            try self.write(" || (");
            try self.write(pns);
            try self.writeByte('.');
            try self.write(name_text);
            try self.write(" = {}));");
        } else {
            try emitIIFEClosing(self, name_text);
        }
        return;
    }

    // body가 block_statement인 경우 (일반 namespace)
    const name_node = self.ast.getNode(name_idx);
    const name_text = self.ast.getText(name_node.span);

    // 부모가 있으면 let, 없으면 var (esbuild 호환)
    // 같은 이름이 이미 선언되었으면 var/let 생략 (function + namespace 병합 등)
    if (!self.declared_names.contains(name_text)) {
        if (parent_ns != null) {
            try self.write("let ");
        } else {
            try self.write("var ");
        }
        try self.write(name_text);
        try self.writeByte(';');
    }
    self.declared_names.put(self.allocator, name_text, {}) catch {};

    // 1단계: export된 이름 수집 (IIFE 열기 전에 — 파라미터 충돌 감지용)
    var ns_export_map: std.StringHashMapUnmanaged(void) = .{};
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

    // 파라미터 이름: export 변수와 충돌하면 _ 접두사 (esbuild 호환)
    // namespace a { export var a = 123 } → ((_a) => { _a.a = 123 })(a || (a = {}))
    var param_buf: [256]u8 = undefined;
    const param_name = if (ns_export_map.contains(name_text)) blk: {
        const len = @min(name_text.len + 1, param_buf.len);
        param_buf[0] = '_';
        @memcpy(param_buf[1..len], name_text[0 .. len - 1]);
        break :blk param_buf[0..len];
    } else name_text;

    // ((Foo) => { ... })(Foo || (Foo = {}));
    try self.write("((");
    try self.write(param_name);
    try self.write(") => {");

    // 2단계: ns_prefix 설정 (identifier 출력 시 치환 활성화)
    const saved_prefix = self.ns_prefix;
    const saved_exports = self.ns_exports;
    if (ns_export_map.count() > 0) {
        self.ns_prefix = param_name;
        self.ns_exports = ns_export_map;
    }
    defer {
        self.ns_prefix = saved_prefix;
        self.ns_exports = saved_exports;
    }

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
                    if (!decl_idx.isNone()) {
                        const decl_node = self.ast.getNode(decl_idx);
                        // export namespace bar {} → 중첩 namespace (부모 이름 전달)
                        if (decl_node.tag == .ts_module_declaration) {
                            try emitNamespaceIIFEInner(self, decl_node, param_name);
                        } else if (decl_node.tag == .variable_declaration) {
                            // 단순 바인딩(identifier)은 직접 프로퍼티 할당: ns.a=1;
                            // destructuring(array_pattern/object_pattern)은 폴백: var [...]=ref; ns.a=a;
                            if (isSimpleVarDeclaration(self, decl_idx)) {
                                try emitNamespaceVarDirectAssign(self, param_name, decl_idx);
                            } else {
                                try self.emitNode(decl_idx);
                                try emitNamespaceExport(self, param_name, decl_idx);
                            }
                        } else {
                            try self.emitNode(decl_idx);
                            try emitNamespaceExport(self, param_name, decl_idx);
                        }
                    }
                },
                .export_default_declaration => {
                    try self.write(param_name);
                    try self.write(".default=");
                    try self.emitNode(stmt_node.data.unary.operand);
                    try self.writeByte(';');
                },
                .ts_module_declaration => {
                    try emitNamespaceIIFEInner(self, stmt_node, param_name);
                },
                else => try self.emitNode(@enumFromInt(raw_idx)),
            }
        }
    }

    // 부모가 있으면 중첩 closing: (name = parent.name || (parent.name = {}))
    if (parent_ns) |pns| {
        try self.write("})(");
        try self.write(name_text);
        try self.write(" = ");
        try self.write(pns);
        try self.writeByte('.');
        try self.write(name_text);
        try self.write(" || (");
        try self.write(pns);
        try self.writeByte('.');
        try self.write(name_text);
        try self.write(" = {}));");
    } else {
        try emitIIFEClosing(self, name_text);
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

/// namespace 내부의 export 선언에서 이름을 추출하여 Foo.name = name; 형태로 출력.
fn emitNamespaceExport(self: anytype, ns_name: []const u8, decl_idx: NodeIndex) !void {
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
                try emitNamespaceBindingExport(self, ns_name, name_idx);
            }
        },
        .function_declaration, .class_declaration => {
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
                try self.write(fn_name);
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
fn emitNamespaceBindingExport(self: anytype, ns_name: []const u8, name_idx: NodeIndex) !void {
    if (name_idx.isNone()) return;
    const node = self.ast.getNode(name_idx);
    switch (node.tag) {
        .binding_identifier => {
            const var_name = self.ast.getText(node.span);
            try self.write(ns_name);
            try self.writeByte('.');
            try self.write(var_name);
            try self.writeByte('=');
            try self.write(var_name);
            try self.writeByte(';');
        },
        .array_pattern => {
            const split = self.ast.nodeListSplitRest(node.data.list);
            for (split.elements) |raw_idx| {
                try emitNamespaceBindingExport(self, ns_name, @enumFromInt(raw_idx));
            }
            if (split.rest_operand) |op| {
                try emitNamespaceBindingExport(self, ns_name, op);
            }
        },
        .object_pattern => {
            const split = self.ast.nodeListSplitRest(node.data.list);
            for (split.elements) |raw_idx| {
                const prop = self.ast.getNode(@enumFromInt(raw_idx));
                // property_property: binary.right = value (binding pattern)
                try emitNamespaceBindingExport(self, ns_name, prop.data.binary.right);
            }
            if (split.rest_operand) |op| {
                try emitNamespaceBindingExport(self, ns_name, op);
            }
        },
        .assignment_target_with_default => {
            // { x = defaultVal } → x
            try emitNamespaceBindingExport(self, ns_name, node.data.binary.left);
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
fn emitNamespaceVarDirectAssign(self: anytype, ns_name: []const u8, decl_idx: NodeIndex) !void {
    const decl = self.ast.getNode(decl_idx);
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
        try self.write(ns_name);
        try self.writeByte('.');
        try self.write(var_name);
        try self.writeByte('=');
        try self.emitNode(init_idx);
        try self.writeByte(';');
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
                const name_node = self.ast.getNode(name_idx);
                const name = self.ast.getText(name_node.span);
                try map.put(self.allocator, name, {});
            }
        },
        .function_declaration, .class_declaration => {
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

fn emitInt(self: anytype, value: i64) !void {
    var buf: [20]u8 = undefined;
    const result = std.fmt.bufPrint(&buf, "{d}", .{value}) catch unreachable;
    try self.buf.appendSlice(self.allocator, result);
}
