//! Codegen helpers for binding patterns and variable declarations.

const std = @import("std");
const ast_mod = @import("../parser/ast.zig");
const Node = ast_mod.Node;
const NodeIndex = ast_mod.NodeIndex;
const writer = @import("writer.zig");
const expressions = @import("expressions.zig");
const ExprFlags = @import("precedence.zig").ExprFlags;

const writeNewline = writer.writeNewline;
const writeSpace = writer.writeSpace;

// ================================================================
// Pattern 출력
// ================================================================

pub fn emitAssignmentPattern(self: anytype, node: Node) !void {
    try self.addSourceMapping(node.span);
    try self.emitNode(node.data.binary.left);
    try self.writeByte('=');
    // default value level = .comma: 최상위 sequence(`[x=(a,b)]`)가 콤마 구분자와 섞이지
    // 않게 괄호로 감싼다 (esbuild binding default = LComma).
    try self.emitExpr(node.data.binary.right, .comma, .{});
}

pub fn emitBindingProperty(self: anytype, node: Node) !void {
    try self.addSourceMapping(node.span);
    // key는 원본 span 출력 (프로퍼티 이름이므로 rename 적용 안 함).
    // computed property key ([expr])는 내부 표현식에 rename이 필요하므로 emitNode 사용.
    const key_node = self.ast.getNode(node.data.binary.left);
    if (key_node.tag == .computed_property_key) {
        try self.emitNode(node.data.binary.left);
    } else {
        try self.writeSpan(key_node.span);
    }
    // shorthand (right=none): `{key}` — 기본은 콜론 생략. 단 대입 대상 위치에 치환이 걸리면
    // `key:치환값` longhand 로 펼친다 (#2977 yargs). 안 펼치면 노드 하나가 키이자 대입 대상이라
    // **프로퍼티 이름까지 같이 바뀐다** — CJS 래퍼에서 `({exports} = o)` 가 `({$e} = o)` 로
    // 나가 진짜 `exports` 파라미터는 영영 대입되지 않고 미선언 전역만 오염된다 (#4515).
    // `let {x}=obj`(binding_property) 와 `({x}=obj)`(assignment_target_property_identifier)
    // 양쪽에 적용. expressions.zig 의 emitObjectProperty shorthand 분기와 동일한 판단이되,
    // slot 이 `.assignment_target` 이라 값 전용 치환(peephole/상수인라인)은 제외된다.
    if (node.data.binary.right.isNone()) {
        if (expressions.identifierEmitsSubstituted(self, node.data.binary.left, .assignment_target)) {
            try self.writeByte(':');
            try self.emitNode(node.data.binary.left);
        }
        return;
    }
    {
        // shorthand_with_default: { x = val } → x:x=val
        // cover grammar에서 assignment_target_property_identifier로 변환된 경우,
        // right가 default value이고 key가 binding name이다.
        // 출력: key:key=default (TS 모드의 binding_property와 동일한 형태)
        const shorthand_with_default: u16 = 0x01; // Parser.shorthand_with_default과 동일
        const is_shorthand_default = (node.data.binary.flags & shorthand_with_default) != 0;
        if (is_shorthand_default and node.tag == .assignment_target_property_identifier) {
            try self.writeByte(':');
            // value(=대입 대상 바인딩) 위치. writeSpan 은 원본 span 을 그대로 복사해서 mangler
            // rename / ns / CJS 파라미터 치환을 통째로 건너뛴다 — `({o: {s, w = 1}} = box)` 의
            // `w` 가 리네임 대상이면 미선언 전역에 대입되고 진짜 지역 변수는 영영 대입되지
            // 않는다 (#4493 — ReferenceError / 무성 오염).
            //
            // 반대로 **무조건** emitNode 를 태우면, 이 노드가 대입 대상인데도 태그가
            // `identifier_reference` 라서 값 전용 치환이 발동한다 — `({undefined = 1} = o)` 가
            // `{undefined:void 0=1}` 로 방출돼 번들 전체가 SyntaxError.
            //
            // 그래서 "값 전용 치환이 안 터질 때만" emitNode 를 태운다(targetIdentSafeToEmit).
            // #4493 은 이 자리를 `identifierHasRename` 으로 게이트했는데 그러면 rename 이 없는
            // CJS `exports`/`module` 재작성이 통째로 누락됐다 (#4515) — 게이트 조건을 "치환
            // 유무" 가 아니라 "값 전용 치환의 위험 유무" 로 바로잡은 것이 핵심이다.
            //
            // key 는 위에서 이미 원본 span 으로 출력했으므로 프로퍼티 이름은 보존된다.
            if (expressions.targetIdentSafeToEmit(self, node.data.binary.left)) {
                try self.emitNode(node.data.binary.left);
            } else {
                try self.writeSpan(key_node.span);
            }
            try self.writeByte('=');
            // default value level = .comma: 최상위 sequence(`({x=(a,b)}=o)`)가 괄호로 감싸진다
            // (default 는 AssignmentExpression 이라 `x=a,b` 는 다른 의미 — silent miscompile).
            try self.emitExpr(node.data.binary.right, .comma, .{});
        } else {
            try self.writeByte(':');
            try self.emitNode(node.data.binary.right);
        }
    }
}

pub fn emitRest(self: anytype, node: Node) !void {
    try self.addSourceMapping(node.span);
    try self.write("...");
    try self.emitNode(node.data.unary.operand);
}

// ================================================================
// Declaration 출력
// ================================================================

pub fn emitVariableDeclaration(self: anytype, node: Node) !void {
    try self.addSourceMapping(node.span);
    const e = node.data.extra;
    const extras = self.ast.extra_data.items[e .. e + 3];
    const kind = self.ast.variableDeclarationKind(node);
    const list_start = extras[1];
    const list_len = extras[2];

    // (#4587 target a) preserve-modules CJS exports-as-storage: 재할당되는 export 바인딩이
    // `exports.<name>` 로 rename 됐으면(linking_metadata.renames), 그 선언을 `exports.A = init;`
    // 할당으로 낮춘다(`let exports.A` 회피). cheap 게이트(pm_cjs_storage + top-level)로 감싸
    // 흔한 경로엔 renames 조회 비용이 안 간다.
    if (self.options.pm_cjs_storage and self.indent_level == 0 and !self.in_for_init) {
        if (self.options.linking_metadata != null) {
            if (try emitPmCjsStorageDeclaration(self, list_start, list_len, kind)) return;
        }
    }

    // __esm 호이스팅: top-level 변수 선언은 래퍼 밖 `var`에 대응하는 할당문으로 변환.
    // indent_level == 0: factory body의 top-level에서만 적용.
    // 함수 안의 const/let/var는 그대로 유지해야 함.
    if (self.options.esm_var_assign_only and self.indent_level == 0 and !self.in_for_init) {
        const declarators = self.ast.extra_data.items[list_start .. list_start + list_len];
        var has_output = false;
        for (declarators) |raw_decl_idx| {
            const decl_node = self.ast.nodes.items[raw_decl_idx];
            const dextras2 = self.ast.extra_data.items[decl_node.data.extra .. decl_node.data.extra + 3];
            const n_idx: NodeIndex = @enumFromInt(dextras2[0]);
            const init_idx: NodeIndex = @enumFromInt(dextras2[2]);
            if (init_idx.isNone()) continue;

            if (n_idx.isNone()) continue;
            if (has_output) try writeNewline(self);
            const name_node = self.ast.nodes.items[@intFromEnum(n_idx)];
            const needs_paren = name_node.tag == .object_pattern;
            if (needs_paren) try self.writeByte('(');
            try self.emitNode(n_idx);
            try writeSpace(self);
            try self.writeByte('=');
            try writeSpace(self);
            try self.emitNode(init_idx);
            if (needs_paren) try self.writeByte(')');
            try self.writeByte(';');
            has_output = true;
        }
        return;
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
        // #3098: syntax minify 시 const → let. 런타임 의미 동일 (차이는 컴파일타임
        // 재할당 에러뿐) → 올바른 프로그램엔 영향 없음. `using`/`await using` 은
        // disposal 의미가 달라 제외.
        .@"const" => if (self.options.minify_syntax) "let " else "const ",
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

/// (#4587 target a) preserve-modules CJS exports-as-storage 선언 변환.
/// 선언 안에 storage declarator(단순 binding_identifier 이면서 renames 가 `"exports."` prefix)
/// 가 하나라도 있으면 declarator 를 partition 하여:
///   - storage: `exports.<name> = <init>;` (name 이 renames 로 `exports.X` 를 찍음, no-init 는 skip)
///   - 비-storage: 각각 `let/const/var <declarator>;` (소스 순서 보존)
/// 로 emit 하고 `true` 를 반환한다. storage 가 없으면 아무것도 안 쓰고 `false`(현행 경로).
/// destructuring declarator 는 storage 후보가 아니다(provider 술어 exportBindingIsCjsStorage 가
/// pattern 을 제외 → 그 안 식별자에 `exports.` rename 이 안 붙음) — 항상 비-storage 로 emit.
fn emitPmCjsStorageDeclaration(self: anytype, list_start: u32, list_len: u32, kind: anytype) !bool {
    const md = self.options.linking_metadata.?;
    const declarators = self.ast.extra_data.items[list_start .. list_start + list_len];

    const isStorage = struct {
        fn f(cg: anytype, meta: anytype, n_idx: NodeIndex) bool {
            if (n_idx.isNone()) return false;
            const name_node = cg.ast.nodes.items[@intFromEnum(n_idx)];
            if (name_node.tag == .object_pattern or name_node.tag == .array_pattern) return false;
            const sid = cg.resolveSymbolId(n_idx, meta) orelse return false;
            const r = meta.renames.get(sid) orelse return false;
            return std.mem.startsWith(u8, r, "exports.");
        }
    }.f;

    // 1st pass: storage declarator 유무 확인 (없으면 현행 경로로 넘김 — 부작용 0).
    var has_storage = false;
    for (declarators) |raw| {
        const decl_node = self.ast.nodes.items[raw];
        const de = self.ast.extra_data.items[decl_node.data.extra .. decl_node.data.extra + 3];
        const n_idx: NodeIndex = @enumFromInt(de[0]);
        if (isStorage(self, md, n_idx)) {
            has_storage = true;
            break;
        }
    }
    if (!has_storage) return false;

    // 비-storage declarator 용 keyword. cycle 강등(force_var_for_cycle)·const→let(minify_syntax)
    // 은 현행 경로와 동일 규칙.
    const demote_to_var = self.options.force_var_for_cycle and (kind == .@"const" or kind == .let);
    const keyword = if (demote_to_var) "var " else switch (kind) {
        .@"var" => "var ",
        .let => "let ",
        .@"const" => if (self.options.minify_syntax) "let " else "const ",
        .using => "using ",
        .await_using => "await using ",
    };

    // 2nd pass: 소스 순서대로 emit.
    var has_output = false;
    for (declarators) |raw| {
        const decl_node = self.ast.nodes.items[raw];
        const de = self.ast.extra_data.items[decl_node.data.extra .. decl_node.data.extra + 3];
        const n_idx: NodeIndex = @enumFromInt(de[0]);
        const init_idx: NodeIndex = @enumFromInt(de[2]);
        if (n_idx.isNone()) continue;

        if (isStorage(self, md, n_idx)) {
            // storage 는 이미 `exports.X` 슬롯이라 init 없으면 방출할 게 없다(undefined 시작).
            if (init_idx.isNone()) continue;
            if (has_output) try writeNewline(self);
            try self.emitNode(n_idx); // renames → `exports.X`
            try writeSpace(self);
            try self.writeByte('=');
            try writeSpace(self);
            try self.emitNode(init_idx);
            try self.writeByte(';');
            has_output = true;
        } else {
            // 비-storage: 각각 자체 `keyword <declarator>;` 문으로. declarator emit 이
            // `name = init` (또는 name-only)를 낸다.
            if (has_output) try writeNewline(self);
            try self.write(keyword);
            try self.emitNode(@enumFromInt(raw));
            try self.writeByte(';');
            has_output = true;
        }
    }
    return true;
}

pub fn emitVariableDeclarator(self: anytype, node: Node) !void {
    try self.addSourceMapping(node.span);
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
        // init level = .comma (esbuild SLocal declarator value = LComma): 최상위 sequence
        // (`let x=(a,b)`)가 괄호로 감싸져 declarator 구분 콤마와 섞이지 않게 한다. for-init
        // 안(`for(var x=(a in b);;)`)이면 forbid_in 전파 — top-level `in` 이 for-in 헤더로
        // 오파싱되지 않게 괄호 (array/call 등 중첩에선 자식 emit 이 flag clear).
        const init_flags = ExprFlags{ .forbid_in = self.in_for_init };
        // contextual name: binding_identifier = function/arrow/class → 변수명을 이름으로
        if (self.fn_map_builder != null and self.isFunctionLike(init_val)) {
            const saved = self.pending_fn_name;
            self.pending_fn_name = try self.ast.staticKeyName(self.allocator, name);
            defer {
                if (self.pending_fn_name) |s| self.allocator.free(s);
                self.pending_fn_name = saved;
            }
            try self.emitExpr(init_val, .comma, init_flags);
        } else {
            try self.emitExpr(init_val, .comma, init_flags);
        }
    }
}

pub fn emitFormalParam(self: anytype, node: Node) !void {
    try self.addSourceMapping(node.span);
    const e = node.data.extra;
    // extra = [pattern, type_ann, default, flags, deco_start, deco_len]
    const extras = self.ast.extra_data.items[e .. e + 6];
    const pattern: NodeIndex = @enumFromInt(extras[0]);
    // extras[1] = type_ann (스킵), extras[3] = flags (스킵), extras[4..5] = decorators (스킵)
    const default_val: NodeIndex = @enumFromInt(extras[2]);

    try self.emitNode(pattern);
    if (!default_val.isNone()) {
        try self.writeByte('=');
        // default value level = .comma: 최상위 sequence(`f(x=(a,b))`)가 파라미터 구분
        // 콤마와 섞이지 않게 괄호로 감싼다 (esbuild fn arg default = LComma).
        try self.emitExpr(default_val, .comma, .{});
    }
}
