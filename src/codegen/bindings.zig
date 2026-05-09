//! Codegen helpers for binding patterns and variable declarations.

const ast_mod = @import("../parser/ast.zig");
const Node = ast_mod.Node;
const NodeIndex = ast_mod.NodeIndex;
const writer = @import("writer.zig");

const writeNewline = writer.writeNewline;
const writeSpace = writer.writeSpace;

// ================================================================
// Pattern 출력
// ================================================================

pub fn emitAssignmentPattern(self: anytype, node: Node) !void {
    try self.emitNode(node.data.binary.left);
    try self.writeByte('=');
    try self.emitNode(node.data.binary.right);
}

pub fn emitBindingProperty(self: anytype, node: Node) !void {
    // key는 원본 span 출력 (프로퍼티 이름이므로 rename 적용 안 함).
    // computed property key ([expr])는 내부 표현식에 rename이 필요하므로 emitNode 사용.
    const key_node = self.ast.getNode(node.data.binary.left);
    if (key_node.tag == .computed_property_key) {
        try self.emitNode(node.data.binary.left);
    } else {
        try self.writeSpan(key_node.span);
    }
    // shorthand: right가 none이면 {key} 형태 — 콜론 생략
    if (!node.data.binary.right.isNone()) {
        // shorthand_with_default: { x = val } → x:x=val
        // cover grammar에서 assignment_target_property_identifier로 변환된 경우,
        // right가 default value이고 key가 binding name이다.
        // 출력: key:key=default (TS 모드의 binding_property와 동일한 형태)
        const shorthand_with_default: u16 = 0x01; // Parser.shorthand_with_default과 동일
        const is_shorthand_default = (node.data.binary.flags & shorthand_with_default) != 0;
        if (is_shorthand_default and node.tag == .assignment_target_property_identifier) {
            try self.writeByte(':');
            try self.writeSpan(key_node.span);
            try self.writeByte('=');
            try self.emitNode(node.data.binary.right);
        } else {
            try self.writeByte(':');
            try self.emitNode(node.data.binary.right);
        }
    }
}

pub fn emitRest(self: anytype, node: Node) !void {
    try self.write("...");
    try self.emitNode(node.data.unary.operand);
}

// ================================================================
// Declaration 출력
// ================================================================

pub fn emitVariableDeclaration(self: anytype, node: Node) !void {
    const e = node.data.extra;
    const extras = self.ast.extra_data.items[e .. e + 3];
    const kind = self.ast.variableDeclarationKind(node);
    const list_start = extras[1];
    const list_len = extras[2];

    // __esm 호이스팅: top-level 단순 변수 선언만 키워드 제거 (할당문으로 변환).
    // indent_level == 0: factory body의 top-level에서만 적용.
    // 함수 안의 const/let/var는 그대로 유지해야 함.
    // destructuring 패턴이 있으면 normal 경로 (키워드 필요).
    if (self.options.esm_var_assign_only and self.indent_level == 0 and !self.in_for_init) {
        const declarators = self.ast.extra_data.items[list_start .. list_start + list_len];
        // destructuring 여부 확인: 하나라도 binding_identifier가 아니면 normal 경로
        var has_destructuring = false;
        for (declarators) |raw_decl_idx| {
            const decl_node = self.ast.nodes.items[raw_decl_idx];
            const dextras2 = self.ast.extra_data.items[decl_node.data.extra .. decl_node.data.extra + 3];
            const n_idx: NodeIndex = @enumFromInt(dextras2[0]);
            if (!n_idx.isNone() and self.ast.nodes.items[@intFromEnum(n_idx)].tag != .binding_identifier) {
                has_destructuring = true;
                break;
            }
        }
        if (!has_destructuring) {
            var has_output = false;
            for (declarators) |raw_decl_idx| {
                const decl_node = self.ast.nodes.items[raw_decl_idx];
                const de = decl_node.data.extra;
                const dextras = self.ast.extra_data.items[de .. de + 3];
                const name_idx: NodeIndex = @enumFromInt(dextras[0]);
                const init_idx: NodeIndex = @enumFromInt(dextras[2]);
                if (!init_idx.isNone()) {
                    if (has_output) try writeNewline(self);
                    try self.emitNode(name_idx);
                    try writeSpace(self);
                    try self.writeByte('=');
                    try writeSpace(self);
                    try self.emitNode(init_idx);
                    try self.writeByte(';');
                    has_output = true;
                }
            }
            return;
        }
        // destructuring → fall through to normal path (var 키워드 유지)
    }

    // #2198: cycle 모듈의 top-level let/const 는 var 로 강등 — 정의 전 참조 시
    // TDZ throw 대신 var 호이스팅 의미 (`undefined`) 로 fallback. for-init / nested
    // scope 는 영향 없음 (이 패스가 indent_level==0 의 ESM-flat 출력에서만 작용).
    const demote_to_var = self.options.force_var_for_cycle and
        self.indent_level == 0 and
        !self.in_for_init and
        (kind == .@"const" or kind == .let);
    const keyword = if (demote_to_var) "var " else switch (kind) {
        .@"var" => "var ",
        .let => "let ",
        .@"const" => "const ",
        .using => "using ",
        .await_using => "await using ",
    };
    try self.write(keyword);
    try self.emitNodeList(list_start, list_len, ",");
    // for문 init 위치에서는 세미콜론을 emitFor가 직접 출력하므로 생략
    if (!self.in_for_init) {
        try self.writeByte(';');
    }
}

pub fn emitVariableDeclarator(self: anytype, node: Node) !void {
    const e = node.data.extra;
    const extras = self.ast.extra_data.items[e .. e + 3];
    const name: NodeIndex = @enumFromInt(extras[0]);
    // extras[1] = type_ann (스킵)
    const init_val: NodeIndex = @enumFromInt(extras[2]);

    try self.emitNode(name);
    // skip_var_init: for-in hoisting으로 init가 별도 문장에 출력된 경우 스킵
    if (!init_val.isNone() and !self.skip_var_init) {
        try writeSpace(self);
        try self.writeByte('=');
        try writeSpace(self);
        // contextual name: binding_identifier = function/arrow/class → 변수명을 이름으로
        if (self.fn_map_builder != null and self.isFunctionLike(init_val)) {
            const saved = self.pending_fn_name;
            self.pending_fn_name = try self.ast.staticKeyName(self.allocator, name);
            defer {
                if (self.pending_fn_name) |s| self.allocator.free(s);
                self.pending_fn_name = saved;
            }
            try self.emitNode(init_val);
        } else {
            try self.emitNode(init_val);
        }
    }
}

pub fn emitFormalParam(self: anytype, node: Node) !void {
    const e = node.data.extra;
    // extra = [pattern, type_ann, default, flags, deco_start, deco_len]
    const extras = self.ast.extra_data.items[e .. e + 6];
    const pattern: NodeIndex = @enumFromInt(extras[0]);
    // extras[1] = type_ann (스킵), extras[3] = flags (스킵), extras[4..5] = decorators (스킵)
    const default_val: NodeIndex = @enumFromInt(extras[2]);

    try self.emitNode(pattern);
    if (!default_val.isNone()) {
        try self.writeByte('=');
        try self.emitNode(default_val);
    }
}
