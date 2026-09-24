//! Class + Decorator 변환
//!
//! visitClass, visitClassWithAssignSemantics, experimental decorators,
//! field assignments, constructor injection 등.

const std = @import("std");
const ast_mod = @import("../../parser/ast.zig");
const Node = ast_mod.Node;
const NodeIndex = ast_mod.NodeIndex;
const NodeList = ast_mod.NodeList;
const transformer_mod = @import("../transformer.zig");
const Transformer = transformer_mod.Transformer;
const Error = Transformer.Error;
const class_visit_mod = @import("class_visit.zig");
pub const visitClass = class_visit_mod.visitClass;
const shouldDropClassExprName = class_visit_mod.shouldDropClassExprName;
// #3/#4: assign-semantics 경로의 private member 다운레벨용 (fast path 와 공유).
const classBodyHasStaticPrivateMember = class_visit_mod.classBodyHasStaticPrivateMember;
const wrapClassExprInIIFE = class_visit_mod.wrapClassExprInIIFE;
const es_helpers = @import("../es_helpers.zig");
const es2022 = @import("../es2022.zig");
const PrivateMethodMapping = Transformer.PrivateMethodMapping;

/// useDefineForClassFields=false / experimentalDecorators 처리.
/// 멤버를 개별 분류하여 instance field를 constructor로 이동하고,
/// experimental decorator를 __decorateClass 호출로 변환한다.
pub fn visitClassWithAssignSemantics(self: *Transformer, node: Node) Error!NodeIndex {
    // computed field 키의 선평가 대입(`_a = f()`)을 모은다. 클래스 **선언**은 앞 문장으로
    // 끼우면 되지만, 클래스 **식**은 값 자리라 문장을 끼울 수 없다 — pending_nodes 로
    // 넣으면 감싼 목록(예: `const` 선언자 목록)에 끼어들어 `const var _a;,_a = f();,C = …`
    // 같은 깨진 코드가 나온다. 그래서 식은 `(_a = f(), class {…})` 쉼표 식으로 낸다. (#4723)
    var key_assigns: std.ArrayListUnmanaged(NodeIndex) = .empty;
    defer key_assigns.deinit(self.allocator);
    const result = try visitClassWithAssignSemanticsInner(self, node, &key_assigns);
    if (key_assigns.items.len == 0 or result.isNone()) return result;
    try key_assigns.append(self.allocator, result);
    const list = try self.ast.addNodeList(key_assigns.items);
    const seq = try self.ast.addListNode(.sequence_expression, node.span, list);
    return self.ast.addNode(.{ .tag = .parenthesized_expression, .span = node.span, .data = .{ .unary = .{ .operand = seq, .flags = 0 } } });
}

fn visitClassWithAssignSemanticsInner(self: *Transformer, node: Node, key_assigns: *std.ArrayListUnmanaged(NodeIndex)) Error!NodeIndex {
    const e = node.data.extra;
    const super_idx = self.readNodeIdx(e, ast_mod.ClassExtra.super);
    const has_super = !super_idx.isNone();
    const raw_name_idx = self.readNodeIdx(e, ast_mod.ClassExtra.name);
    var new_name = try self.visitNode(raw_name_idx);
    const new_super = try self.visitNode(super_idx);
    // 뒤에서 임시 이름으로 바꾸면 span 이 달라져 makeCurrentClassRef 가 심볼을 붙이지 않는다.
    const saved_class_name_node = self.current_class_name_node;
    self.current_class_name_node = new_name;
    defer self.current_class_name_node = saved_class_name_node;

    // #4 fix(super_class): fast path(class_visit.zig)와 동일하게 private method body 내 super.x 가
    // 올바른 super class span 으로 lowering 되도록 current_super_class 를 set. assign-semantics
    // 경로가 이 set 을 누락하면 lowerPrivateMembers 의 standalone fn body visit / classifyClassMember
    // 의 method body visit 에서 super-prop lowering 이 null/stale 참조로 깨진다.
    const saved_super_class = self.current_super_class;
    const saved_super_class_old_idx = self.current_super_class_old_idx;
    // #3680-F5/F6: inner class 가 extends 없으면 null 로 명시적 reset (outer 누수 차단).
    // F6: super_class 와 동시에 old_idx 도 set — fast path 에서도 super lowering 활성화돼 symbol propagation 필요.
    if (has_super) {
        self.current_super_class = self.ast.getNode(super_idx).span;
        self.current_super_class_old_idx = super_idx;
    } else {
        self.current_super_class = null;
        self.current_super_class_old_idx = .none;
    }
    defer self.current_super_class = saved_super_class;
    defer self.current_super_class_old_idx = saved_super_class_old_idx;
    // 클래스 안의 `super` 는 이 클래스 기준 — 바깥 객체 메서드의 home 을 끊는다 (#4729).
    const saved_super_home = self.current_super_home_object;
    self.current_super_home_object = null;
    defer self.current_super_home_object = saved_super_home;
    // V4 fix: es2015_class.zig (IIFE path) parity — outer is_static/static_receiver 누수 차단.
    const saved_super_is_static = self.current_super_is_static;
    const saved_super_static_receiver = self.current_super_static_receiver;
    self.current_super_is_static = false;
    self.current_super_static_receiver = null;
    defer self.current_super_is_static = saved_super_is_static;
    defer self.current_super_static_receiver = saved_super_static_receiver;
    // #3680: inner class body 안의 super 는 lexical 로 valid — outer standalone fn flag reset.
    const saved_super_in_extracted_fn = self.current_super_in_extracted_fn;
    self.current_super_in_extracted_fn = false;
    defer self.current_super_in_extracted_fn = saved_super_in_extracted_fn;

    // #3/#4 fix(이중-visit 회피): lowerPrivateMembers 를 skip_visit_and_keep_private=true 로 호출하면
    // current_private_* 를 호출자가 set/복원해야 한다(lowerPrivateMembers 내부 defer 가 건너뛴다).
    // 그래야 classifyClassMember 의 단일 visit 이 current_private set 상태로 this.# rewrite +
    // decorator 수집을 둘 다 수행한다(이중-visit + decorator strip 회피).
    const saved_private_methods_outer = self.current_private_methods;
    const saved_private_fields_outer = self.current_private_fields;
    defer {
        self.current_private_methods = saved_private_methods_outer;
        self.current_private_fields = saved_private_fields_outer;
    }

    // #3/#4: assign-semantics(experimental_decorators / useDefineForClassFields:false) 경로도
    // private member 를 다운레벨해야 한다 — 안 하면 es2021 타깃에서 raw `#` 가 남아 실행 불가.
    // fast path(class_visit.zig)와 동일하게 lowerPrivateMembers 로 new_body(private 제거 +
    // this.# rewrite + ctor init prepend)를 만들고, weakset 선언(priv_pre_stmts)은 emitPrivatePrelude
    // 가 class 정의 앞에 emit 한다. (lowerPrivateMembers 가 current_private 를 set 후 new_body 를
    // 통째 visit 하므로 this.# 가 그 안에서 rewrite 된다.)
    var body_idx = self.readNodeIdx(e, ast_mod.ClassExtra.body);
    const lower_pm = self.options.unsupported.class_private_method;
    const lower_pf = self.options.unsupported.class_private_field;
    var priv_pre_stmts: std.ArrayList(NodeIndex) = .empty;
    defer priv_pre_stmts.deinit(self.allocator);
    // V_ASSIGN fix: assign-semantics path 도 static descriptor 를 별도 array 로 받아
    // class declaration 뒤에 emit — receiver=D 의 TDZ 회피.
    var assign_static_descriptors: std.ArrayList(NodeIndex) = .empty;
    defer assign_static_descriptors.deinit(self.allocator);
    var pm_mappings: std.ArrayList(PrivateMethodMapping) = .empty;
    defer {
        for (pm_mappings.items) |pm| {
            self.allocator.free(pm.weakset_name);
            self.allocator.free(pm.func_name);
        }
        pm_mappings.deinit(self.allocator);
    }
    var pf_mappings: std.ArrayList(Transformer.PrivateFieldMapping) = .empty;
    defer {
        for (pf_mappings.items) |pf| {
            self.allocator.free(pf.var_name);
        }
        pf_mappings.deinit(self.allocator);
    }
    if (lower_pm or lower_pf) {
        // class_expression + static private → 이름 부여(static init 참조 / IIFE).
        if (node.tag == .class_expression and new_name.isNone() and
            classBodyHasStaticPrivateMember(self, body_idx, lower_pm, lower_pf))
        {
            const tmp_span = try es_helpers.makeTempVarSpan(self);
            new_name = try es_helpers.makeBindingIdentifier(self, tmp_span);
        }
        var new_body_pl: NodeIndex = .none;
        var ctor_stmts_pl: std.ArrayList(NodeIndex) = .empty;
        defer ctor_stmts_pl.deinit(self.allocator);
        const class_name_text: ?[]const u8 = if (self.getClassNameSpan(new_name)) |s|
            self.ast.getText(s)
        else
            null;
        const had_any = try es2022.ES2022(Transformer).lowerPrivateMembers(
            self,
            body_idx,
            &new_body_pl,
            &priv_pre_stmts,
            &ctor_stmts_pl,
            &pm_mappings,
            &pf_mappings,
            lower_pm,
            lower_pf,
            has_super,
            class_name_text,
            new_name,
            true, // skip_visit_and_keep_private — public member 는 classifyClassMember 가 단일 visit.
            // V_ASSIGN fix: descriptor 를 별도 array 로 받아 class 뒤에 emit (TDZ 회피).
            &assign_static_descriptors,
        );
        if (had_any) body_idx = new_body_pl;
    }

    // 필드를 낮추면 멤버들이 생성자·IIFE 등 **다른 자리**로 흩어진다. 그 경우 모든 멤버의
    // computed 키를 소스 순서대로 **클래스 앞에서 한 번** 평가해 temp 로 바꿔 둔다 (#4723).
    //  - 필드 키가 생성자로 들어가면 인스턴스마다 재평가된다(스펙: 정의 시점 1회).
    //  - 메서드/접근자 키가 IIFE 안에 남으면 키의 `yield`/`await` 가 새 함수 안으로 들어가
    //    파싱조차 안 되고, 필드 키만 빼면 키 평가 순서가 뒤바뀐다.
    var pre_hoisted_keys = false;
    if (classBodyHasFieldAndComputedKey(self, body_idx)) {
        body_idx = try hoistAllComputedKeys(self, node.tag, body_idx, key_assigns);
        pre_hoisted_keys = true;
    }

    // 원본(또는 private 다운레벨된) class_body를 직접 순회
    const body_node = self.ast.getNode(body_idx);
    const body_members_start = body_node.data.list.start;
    const body_members_len = body_node.data.list.len;

    // 멤버 분류: class_members(새 body), field_assignments(constructor 이동 대상),
    // member_decorators(experimental decorator 대상)를 동시에 수집한다.
    const scratch_top = self.scratch.items.len;
    defer self.scratch.shrinkRetainingCapacity(scratch_top);

    var class_members: std.ArrayList(NodeIndex) = .empty;
    defer class_members.deinit(self.allocator);

    var field_assignments: std.ArrayList(FieldAssignment) = .empty;
    defer field_assignments.deinit(self.allocator);

    var member_decorators: std.ArrayList(MemberDecoratorInfo) = .empty;
    defer {
        for (member_decorators.items) |md| {
            self.allocator.free(md.decorators);
        }
        member_decorators.deinit(self.allocator);
    }

    var existing_constructor: ?NodeIndex = null;
    var existing_constructor_pos: ?usize = null;

    // ES2022 다운레벨링: static block → IIFE (target < es2022)
    var static_block_iifes: std.ArrayList(NodeIndex) = .empty;
    defer static_block_iifes.deinit(self.allocator);

    var static_block_field_counts: std.ArrayList(u32) = .empty;
    defer static_block_field_counts.deinit(self.allocator);
    var static_field_assignments: std.ArrayList(FieldAssignment) = .empty;
    defer static_field_assignments.deinit(self.allocator);

    var ctor_param_decos: std.ArrayList(NodeIndex) = .empty;
    defer ctor_param_decos.deinit(self.allocator);

    // emitDecoratorMetadata: constructor 파라미터 위치 (원본 AST에서 수집)
    var ctor_params: ast_mod.NodeList = .{ .start = 0, .len = 0 };

    var ctx = ClassMemberContext{
        .class_members = &class_members,
        .field_assignments = &field_assignments,
        .member_decorators = &member_decorators,
        .existing_constructor = &existing_constructor,
        .existing_constructor_pos = &existing_constructor_pos,
        .static_block_iifes = if (self.options.unsupported.class_static_block) &static_block_iifes else null,
        .static_block_field_counts = if (self.options.unsupported.class_static_block) &static_block_field_counts else null,
        // static field 를 class 밖으로 옮겨야 하는 조건은 instance field 와 같다 —
        // 옵션이 assign 의미론이거나, 타겟이 class field 를 모르거나 (#4629).
        .static_field_assignments = if (!self.options.use_define_for_class_fields or
            self.options.unsupported.class_field) &static_field_assignments else null,
        .ctor_param_decos = &ctor_param_decos,
        .has_super = has_super,
        .ctor_params = &ctor_params,
    };

    // 익명 클래스 식인데 static field / static block 을 **클래스 밖 문장**으로 낮춰야 하면
    // 그 문장들이 클래스를 가리킬 이름이 필요하다. 이름 없이 진행하면 static field 할당이
    // `.none` 이름을 역참조해 **컴파일러가 죽는다**(#4723 — #4629 가 es2015~es2021 에서
    // field 를 낮추기 시작하며 드러남). 분류(static block 의 this 치환) **전에** 붙인다.
    if (node.tag == .class_expression and new_name.isNone() and
        classBodyNeedsNameForStatics(self, body_idx, ctx.static_field_assignments != null))
    {
        const tmp_span = try es_helpers.makeTempVarSpan(self);
        new_name = try es_helpers.makeBindingIdentifier(self, tmp_span);
    }

    // ES2022 static block this 치환을 위한 클래스 이름 추출
    if (self.options.unsupported.class_static_block) {
        ctx.class_name_span = self.getClassNameSpan(new_name);
    }

    // classifyClassMember가 AST를 변형하므로 인덱스 루프 사용
    {
        var i_bm: u32 = 0;
        while (i_bm < body_members_len) : (i_bm += 1) {
            const raw_idx = self.ast.extra_data.items[body_members_start + i_bm];
            try self.classifyClassMember(raw_idx, &ctx);
        }
    }

    // computed key 호이스트: class 전에 var _a; _a = foo; 삽입 (esbuild 호환)
    // computed key 는 **클래스 정의 시점에 한 번만** 평가돼야 한다 — 의미론(assign/define)과
    // 무관한 스펙 규칙이다. 예전엔 assign 의미론에서만 켰는데, #4629 가 define 의미론(기본값)
    // 으로 field 를 낮추기 시작하면서 키가 생성자 안으로 들어가 **인스턴스마다 재평가**됐다.
    // (위의 hoistAllComputedKeys 가 이미 했으면 건너뛴다 — 두 번 빼면 `_c = _a` 가 생긴다.)
    if (!pre_hoisted_keys) {
        for (field_assignments.items) |*field| {
            if (field.is_computed) {
                const key_node = self.ast.getNode(field.key);
                const actual_key = if (key_node.tag == .computed_property_key)
                    key_node.data.unary.operand
                else
                    field.key;

                // computed field 별 고유 이름. 예전의 하드코딩 `_a`/`_b` 는 같은 스코프의
                // 다른 temp(상태 기계 temp 등)와 이름이 겹칠 수 있었다. makeTempVarSpan 의
                // temp 는 감싼 함수/프로그램 최상단에 자동으로 `var` 선언된다.
                const temp_span = try es_helpers.makeTempVarSpan(self);

                // _a = foo; 대입
                const temp_ref = try self.ast.addNode(.{
                    .tag = .identifier_reference,
                    .span = temp_span,
                    .data = .{ .string_ref = temp_span },
                });
                const assign = try self.ast.addNode(.{
                    .tag = .assignment_expression,
                    .span = field.span,
                    .data = .{ .binary = .{ .left = temp_ref, .right = actual_key, .flags = 0 } },
                });
                if (node.tag == .class_expression) {
                    try key_assigns.append(self.allocator, assign);
                } else {
                    try self.pending_nodes.append(self.allocator, try es_helpers.makeExprStmt(self, assign, field.span));
                }

                // field의 key를 임시 변수로 교체
                const new_computed = try self.ast.addNode(.{
                    .tag = .computed_property_key,
                    .span = field.span,
                    .data = .{ .unary = .{ .operand = temp_ref, .flags = 0 } },
                });
                field.key = new_computed;
            }
        }
    }

    // instance field를 constructor에 삽입 (useDefineForClassFields=false)
    if (field_assignments.items.len > 0) {
        try self.applyFieldAssignments(
            &class_members,
            field_assignments.items,
            existing_constructor,
            existing_constructor_pos,
            has_super,
        );
    }

    // class body 노드 생성
    const body_list = try self.ast.addNodeList(class_members.items);
    const new_body = try self.ast.addNode(.{
        .tag = .class_body,
        .span = body_node.span,
        .data = .{ .list = body_list },
    });

    const old_deco_len = self.readU32(e, ast_mod.ClassExtra.deco_len);
    const has_any_decorator = old_deco_len > 0 or
        member_decorators.items.len > 0 or
        ctor_param_decos.items.len > 0;

    // #1596: fast path (#1587) 와 동일 최적화를 non-fast-path 에도 적용.
    // class name 이 runtime 에 참조되는 경우 — static field (`Foo.x=...`),
    // static block 다운레벨 (`this` 치환), decorator 중 하나라도 있으면 보존.
    if (shouldDropClassExprName(self, node.tag, raw_name_idx)) {
        const has_static_extras = static_field_assignments.items.len > 0 or
            static_block_iifes.items.len > 0;
        if (!has_any_decorator and !has_static_extras) {
            new_name = NodeIndex.none;
        }
    }

    // experimentalDecorators — decorator를 class에서 제거하고 __decorateClass 호출 생성
    if (self.options.experimental_decorators) {
        const old_deco_start = self.readU32(e, ast_mod.ClassExtra.deco_start);

        if (has_any_decorator) {
            // #3/#4: private weakset 선언은 `let Foo = class {...}` 분해 앞에 와야 한다.
            for (priv_pre_stmts.items) |stmt| try self.pending_nodes.append(self.allocator, stmt);
            return try self.transformExperimentalDecorators(
                node,
                new_name,
                self.readNodeIdx(e, 0),
                new_super,
                new_body,
                old_deco_start,
                old_deco_len,
                member_decorators.items,
                static_block_iifes.items,
                static_field_assignments.items,
                ctor_param_decos.items,
                ctor_params,
            );
        }
    }

    // decorator 리스트 복사 (experimental이 아닌 경우)
    const new_decos = if (!self.options.experimental_decorators)
        try self.visitExtraList(.{ .start = self.readU32(e, ast_mod.ClassExtra.deco_start), .len = old_deco_len })
    else
        NodeList{ .start = 0, .len = 0 };

    const none = @intFromEnum(NodeIndex.none);

    // static field / static block이 있으면 class 뒤에 할당문 추가
    const has_static_fields = static_field_assignments.items.len > 0;
    const has_static_blocks = static_block_iifes.items.len > 0;

    if (has_static_fields or has_static_blocks) {
        const class_result = try self.addExtraNode(node.tag, node.span, &.{
            @intFromEnum(new_name), @intFromEnum(new_super), @intFromEnum(new_body),
            none,                   0,                       0,
            new_decos.start,        new_decos.len,
        });
        // 클래스 뒤에 올 문장들: private static descriptor → (소스 순서대로) static field / block.
        var post: std.ArrayListUnmanaged(NodeIndex) = .empty;
        defer post.deinit(self.allocator);
        // V_ASSIGN fix: private static descriptor 는 class 뒤, static field 할당과 IIFE 의 앞에.
        try post.appendSlice(self.allocator, assign_static_descriptors.items);
        // static field 와 static block 은 **소스 순서**대로 평가돼야 한다 (#4629).
        // `static a = …; static { … } static b = …` 에서 block 이 뒤로 밀리면
        // block 이 보는 값이 달라진다. counts[i] = 그 block 앞에 있던 field 수.
        var emitted_fields: u32 = 0;
        for (static_block_iifes.items, 0..) |iife, i| {
            const upto: u32 = if (i < static_block_field_counts.items.len)
                static_block_field_counts.items[i]
            else
                @intCast(static_field_assignments.items.len);
            while (emitted_fields < upto) : (emitted_fields += 1) {
                try post.append(self.allocator, try self.buildStaticFieldAssignment(new_name, static_field_assignments.items[emitted_fields]));
            }
            try post.append(self.allocator, iife);
        }
        while (emitted_fields < static_field_assignments.items.len) : (emitted_fields += 1) {
            try post.append(self.allocator, try self.buildStaticFieldAssignment(new_name, static_field_assignments.items[emitted_fields]));
        }

        // 클래스 **식**은 값 자리라 문장을 앞뒤에 끼울 수 없다 — IIFE 로 감싸 클래스를
        // 돌려준다. 예전엔 여기서도 pending 에 넣고 `.none` 을 돌려줘 식이 통째로 사라질
        // 경로였다(이름이 없어 그 전에 크래시했을 뿐). (#4723)
        if (node.tag == .class_expression) {
            return wrapClassExprInIIFE(self, &.{}, priv_pre_stmts.items, class_result, post.items, new_name, node.span);
        }
        // #3/#4: private weakset 선언은 class 정의/static 할당 앞에.
        for (priv_pre_stmts.items) |stmt| try self.pending_nodes.append(self.allocator, stmt);
        try self.pending_nodes.append(self.allocator, class_result);
        for (post.items) |stmt| try self.pending_nodes.append(self.allocator, stmt);
        return .none;
    }

    // #3/#4: private member 다운레벨이 있었으면 weakset 선언(priv_pre_stmts)을 class 앞에 emit.
    // class_expression 은 statement 위치가 아니므로 IIFE 로 래핑(fast path 와 동일), class_declaration
    // 은 pending 에 prelude + class 를 순서대로 넣는다.
    // V_ASSIGN fix: descriptor 만 있고 priv_pre_stmts 가 비어도 emit 경로 활성화.
    if (priv_pre_stmts.items.len > 0 or assign_static_descriptors.items.len > 0) {
        const class_result = try self.addExtraNode(node.tag, node.span, &.{
            @intFromEnum(new_name), @intFromEnum(new_super), @intFromEnum(new_body),
            none,                   0,                       0,
            new_decos.start,        new_decos.len,
        });
        if (node.tag == .class_expression) {
            return wrapClassExprInIIFE(
                self,
                &.{},
                priv_pre_stmts.items,
                class_result,
                assign_static_descriptors.items,
                new_name,
                node.span,
            );
        }
        for (priv_pre_stmts.items) |stmt| try self.pending_nodes.append(self.allocator, stmt);
        try self.pending_nodes.append(self.allocator, class_result);
        // V_ASSIGN fix: descriptor 를 class 뒤에 emit.
        for (assign_static_descriptors.items) |desc| try self.pending_nodes.append(self.allocator, desc);
        return .none;
    }

    return self.addExtraNode(node.tag, node.span, &.{
        @intFromEnum(new_name), @intFromEnum(new_super), @intFromEnum(new_body),
        none,                   0,                       0,
        new_decos.start,        new_decos.len,
    });
}

// ================================================================
// Class member / field assignment helpers — transformer/class_member_helpers.zig로 위임
// ================================================================
const class_member_helpers = @import("class_member_helpers.zig");

pub const ClassMemberContext = class_member_helpers.ClassMemberContext;
pub const FieldAssignment = class_member_helpers.FieldAssignment;
pub const MemberDecoratorInfo = class_member_helpers.MemberDecoratorInfo;
pub const buildStaticFieldAssignment = class_member_helpers.buildStaticFieldAssignment;
pub const classifyClassMember = class_member_helpers.classifyClassMember;
pub const classifyPropertyDefinition = class_member_helpers.classifyPropertyDefinition;
pub const classifyMethodDefinition = class_member_helpers.classifyMethodDefinition;
pub const applyFieldAssignments = class_member_helpers.applyFieldAssignments;
pub const insertFieldAssignmentsIntoConstructor = class_member_helpers.insertFieldAssignmentsIntoConstructor;
pub const isSuperCallStatement = class_member_helpers.isSuperCallStatement;
pub const buildConstructorWithFieldAssignments = class_member_helpers.buildConstructorWithFieldAssignments;
pub const buildThisAssignment = class_member_helpers.buildThisAssignment;
pub const visitDecoratorExpression = class_member_helpers.visitDecoratorExpression;
pub const collectMemberDecorators = class_member_helpers.collectMemberDecorators;
pub const collectParamDecorators = class_member_helpers.collectParamDecorators;
pub const appendParamDecorators = class_member_helpers.appendParamDecorators;
pub const buildDecorateParamCall = class_member_helpers.buildDecorateParamCall;

// ================================================================
// Legacy experimental decorators — transformer/legacy_decorator_helpers.zig로 위임
// ================================================================
const legacy_decorator_helpers = @import("legacy_decorator_helpers.zig");

pub const transformExperimentalDecorators = legacy_decorator_helpers.transformExperimentalDecorators;
pub const buildDecorateClassMemberCall = legacy_decorator_helpers.buildDecorateClassMemberCall;
pub const buildDecorateClassCall = legacy_decorator_helpers.buildDecorateClassCall;

// ================================================================
// emitDecoratorMetadata — transformer/decorator_metadata.zig로 위임
// ================================================================
const decorator_metadata = @import("decorator_metadata.zig");

pub const serializeTypeAnnotation = decorator_metadata.serializeTypeAnnotation;
pub const extractTypeFromSource = decorator_metadata.extractTypeFromSource;
pub const buildMetadataCall = decorator_metadata.buildMetadataCall;
pub const buildParamTypesArray = decorator_metadata.buildParamTypesArray;
pub const appendMemberMetadata = decorator_metadata.appendMemberMetadata;
pub const appendClassMetadata = decorator_metadata.appendClassMetadata;

// ============================================================
// TC39 Stage 3 Decorator Transform (TypeScript 5.0+ 호환)
// ============================================================
//
// TypeScript/Babel/SWC 공통 출력: __esDecorate + __runInitializers + IIFE 래핑.
// experimental_decorators=false일 때, class/member에 decorator가 있으면 이 경로를 탄다.

/// Stage 3 decorator가 있는 멤버(method/property/accessor)가 하나라도 있는지 확인.
/// class_body를 순회하여 decorator가 달린 멤버 존재 여부만 빠르게 판단한다.
pub fn hasAnyMemberDecorators(self: *Transformer, class_extra: u32) bool {
    const body_idx = self.readNodeIdx(class_extra, 2);
    if (body_idx.isNone()) return false;
    const body_node = self.ast.getNode(body_idx);
    const start = body_node.data.list.start;
    const len = body_node.data.list.len;

    var i: u32 = 0;
    while (i < len) : (i += 1) {
        const member_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[start + i]);
        if (member_idx.isNone()) continue;
        const member = self.ast.getNode(member_idx);
        const me = member.data.extra;

        if (member.tag == .property_definition or member.tag == .accessor_property) {
            const deco_len = self.readU32(me, ast_mod.PropertyExtra.deco_len);
            if (deco_len > 0) return true;
        } else if (member.tag == .method_definition) {
            const deco_len = self.readU32(me, ast_mod.MethodExtra.deco_len);
            if (deco_len > 0) return true;
        }
    }
    return false;
}

/// Stage 3 decorator 생성 헬퍼 위임.
const stage3_helpers = @import("stage3_decorator_helpers.zig");

pub const Stage3MemberInfo = stage3_helpers.Stage3MemberInfo;
pub const FieldInitNames = stage3_helpers.FieldInitNames;
pub const memberKeyToStringLiteral = stage3_helpers.memberKeyToStringLiteral;
pub const wrapInStringLiteral = stage3_helpers.wrapInStringLiteral;
pub const collectStage3Decorators = stage3_helpers.collectStage3Decorators;
pub const buildEsDecorateCall = stage3_helpers.buildEsDecorateCall;
pub const buildClassEsDecorateCall = stage3_helpers.buildClassEsDecorateCall;
pub const buildContextObject = stage3_helpers.buildContextObject;
pub const buildAccessObject = stage3_helpers.buildAccessObject;
pub const buildMetadataDecl = stage3_helpers.buildMetadataDecl;
pub const buildClassReassign = stage3_helpers.buildClassReassign;
pub const buildRunInitializersCall = stage3_helpers.buildRunInitializersCall;
pub const buildRunInitializersCall2 = stage3_helpers.buildRunInitializersCall2;
pub const buildStage3LetDeclarations = stage3_helpers.buildStage3LetDeclarations;
pub const makeObjProp = stage3_helpers.makeObjProp;
pub const makeLet = stage3_helpers.makeLet;
pub const buildFieldInitNames = stage3_helpers.buildFieldInitNames;
pub const buildMetadataDefineProperty = stage3_helpers.buildMetadataDefineProperty;
pub const buildGetterMethod = stage3_helpers.buildGetterMethod;
pub const buildSetterMethod = stage3_helpers.buildSetterMethod;
pub const extractCleanVarName = stage3_helpers.extractCleanVarName;
pub const appendEsDecorateStmt = stage3_helpers.appendEsDecorateStmt;

const stage3_transform = @import("stage3_decorator_transform.zig");
pub const transformStage3Decorators = stage3_transform.transformStage3Decorators;

/// 클래스 본문에 **클래스 밖 문장으로 낮춰질** static 멤버가 있는지.
/// `lowers_static_fields` = static field 를 할당문으로 빼는 중인지(ctx 기준).
fn classBodyNeedsNameForStatics(self: *Transformer, body_idx: NodeIndex, lowers_static_fields: bool) bool {
    if (body_idx.isNone()) return false;
    const body = self.ast.getNode(body_idx);
    var i: u32 = 0;
    while (i < body.data.list.len) : (i += 1) {
        const member = self.ast.getNode(@enumFromInt(self.ast.extra_data.items[body.data.list.start + i]));
        switch (member.tag) {
            .static_block => if (self.options.unsupported.class_static_block) return true,
            .property_definition => if (lowers_static_fields and
                (self.readU32(member.data.extra, ast_mod.PropertyExtra.flags) & ast_mod.PropertyFlags.is_static) != 0) return true,
            else => {},
        }
    }
    return false;
}

/// 필드(property_definition / accessor_property)가 하나라도 있고, 어떤 멤버든 computed 키가 있는지.
fn classBodyHasFieldAndComputedKey(self: *Transformer, body_idx: NodeIndex) bool {
    if (body_idx.isNone()) return false;
    const body = self.ast.getNode(body_idx);
    var has_field = false;
    var has_computed = false;
    var i: u32 = 0;
    while (i < body.data.list.len) : (i += 1) {
        const member = self.ast.getNode(@enumFromInt(self.ast.extra_data.items[body.data.list.start + i]));
        switch (member.tag) {
            .property_definition, .accessor_property => has_field = true,
            .method_definition => {},
            else => continue,
        }
        const key: NodeIndex = @enumFromInt(self.ast.extra_data.items[member.data.extra]);
        if (!key.isNone() and self.ast.getNode(key).tag == .computed_property_key) has_computed = true;
    }
    return has_field and has_computed;
}

/// 모든 멤버의 computed 키를 소스 순서대로 temp 에 평가하고, 키를 `[_t]` 로 바꾼 새
/// class_body 를 돌려준다. 대입은 클래스 **식**이면 `key_assigns`(쉼표 식)로, **선언**이면
/// 앞 문장(pending_nodes)으로 낸다.
fn hoistAllComputedKeys(self: *Transformer, tag: Node.Tag, body_idx: NodeIndex, key_assigns: *std.ArrayListUnmanaged(NodeIndex)) Error!NodeIndex {
    const body = self.ast.getNode(body_idx);
    var members: std.ArrayListUnmanaged(NodeIndex) = .empty;
    defer members.deinit(self.allocator);
    var i: u32 = 0;
    while (i < body.data.list.len) : (i += 1) {
        const member_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[body.data.list.start + i]);
        const member = self.ast.getNode(member_idx);
        const slot_count: usize = switch (member.tag) {
            .method_definition => 6, // MethodExtra: key, params, body, flags, deco_start, deco_len
            .property_definition, .accessor_property => 5, // PropertyExtra: key, init, flags, deco_start, deco_len
            else => {
                try members.append(self.allocator, member_idx);
                continue;
            },
        };
        const me = member.data.extra;
        const key_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[me]);
        if (key_idx.isNone() or self.ast.getNode(key_idx).tag != .computed_property_key) {
            try members.append(self.allocator, member_idx);
            continue;
        }
        const key_node = self.ast.getNode(key_idx);
        const value = try self.visitNode(key_node.data.unary.operand);
        const temp_span = try es_helpers.makeTempVarSpan(self);
        const assign = try self.ast.addNode(.{
            .tag = .assignment_expression,
            .span = key_node.span,
            .data = .{ .binary = .{ .left = try es_helpers.makeSyntheticRefFromSpan(self, temp_span), .right = value, .flags = 0 } },
        });
        if (tag == .class_expression) {
            try key_assigns.append(self.allocator, assign);
        } else {
            try self.pending_nodes.append(self.allocator, try es_helpers.makeExprStmt(self, assign, key_node.span));
        }
        const new_key = try self.ast.addNode(.{
            .tag = .computed_property_key,
            .span = key_node.span,
            .data = .{ .unary = .{ .operand = try es_helpers.makeSyntheticRefFromSpan(self, temp_span), .flags = key_node.data.unary.flags } },
        });
        var slots: [6]u32 = undefined;
        for (0..slot_count) |k| slots[k] = self.ast.extra_data.items[me + k];
        slots[0] = @intFromEnum(new_key);
        const new_extra = try self.ast.addExtras(slots[0..slot_count]);
        try members.append(self.allocator, try self.ast.addNode(.{ .tag = member.tag, .span = member.span, .data = .{ .extra = new_extra } }));
    }
    const list = try self.ast.addNodeList(members.items);
    return self.ast.addNode(.{ .tag = .class_body, .span = body.span, .data = .{ .list = list } });
}

/// es5 클래스 경로(`es2015_class` 의 IIFE/함수 lowering)용 진입점 (#4723).
///
/// es5 는 필드를 생성자 안(`__publicField(this, <키>, …)`)으로 옮기므로, computed 키를
/// 그대로 두면 **인스턴스마다 재평가**된다. 필드 + computed 키가 있으면 모든 멤버 키를
/// 소스 순서대로 먼저 temp 로 평가하고, 키가 바뀐 클래스 노드로 `lower` 를 부른다.
/// 클래스 식이면 결과를 `(_a = k1, …, <lowered>)` 쉼표 식으로 감싼다.
pub fn lowerClassWithPrehoistedKeys(
    self: *Transformer,
    node: Node,
    comptime lower: fn (*Transformer, Node) Error!NodeIndex,
) Error!NodeIndex {
    const body_idx = self.readNodeIdx(node.data.extra, ast_mod.ClassExtra.body);
    if (!classBodyHasFieldAndComputedKey(self, body_idx)) return lower(self, node);

    var key_assigns: std.ArrayListUnmanaged(NodeIndex) = .empty;
    defer key_assigns.deinit(self.allocator);
    const new_body = try hoistAllComputedKeys(self, node.tag, body_idx, &key_assigns);

    var slots: [8]u32 = undefined;
    for (0..8) |k| slots[k] = self.ast.extra_data.items[node.data.extra + k];
    slots[ast_mod.ClassExtra.body] = @intFromEnum(new_body);
    const new_extra = try self.ast.addExtras(&slots);
    const result = try lower(self, .{ .tag = node.tag, .span = node.span, .data = .{ .extra = new_extra } });

    if (key_assigns.items.len == 0 or result.isNone()) return result;
    try key_assigns.append(self.allocator, result);
    const list = try self.ast.addNodeList(key_assigns.items);
    const seq = try self.ast.addListNode(.sequence_expression, node.span, list);
    return self.ast.addNode(.{ .tag = .parenthesized_expression, .span = node.span, .data = .{ .unary = .{ .operand = seq, .flags = 0 } } });
}
