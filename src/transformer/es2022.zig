//! ES2022 다운레벨링
//!
//! --target < es2022 일 때 활성화.
//!
//! ## 1. Static Block → IIFE
//! class Foo { static { this.x = 1; } }
//! → class Foo {} (() => { Foo.x = 1; })();
//!
//! static block 안의 `this`는 클래스 자체를 참조한다.
//! IIFE로 추출하면 arrow function의 `this`가 outer scope를 가리키게 되므로,
//! `this` → 클래스 이름으로 치환해야 한다 (oxc 방식: this_depth 카운터).
//!
//! ## 2. Private Methods → WeakSet + standalone function (SWC 방식)
//! class Foo { #bar() { return 1; } baz() { return this.#bar(); } }
//! → var _bar = new WeakSet();
//!   function _bar_fn() { return 1; }
//!   class Foo { constructor() { _bar.add(this); } baz() { return _bar_fn.call(this); } }
//!
//! 2-pass 방식:
//!   Pass 1: body 스캔 → private method 매핑 수집
//!   Pass 2: current_private_methods 설정 후 body visit (this.#method() 호출 변환)
//!
//! 스펙:
//! - class static block: https://tc39.es/ecma262/#sec-static-blocks
//! - private methods: https://tc39.es/ecma262/#sec-private-names
//!
//! 참고:
//! - esbuild: internal/js_parser/js_parser_lower_class.go
//! - SWC: crates/swc_ecma_transforms_compat/src/class_properties/
//! - oxc: crates/oxc_transformer/src/es2022/

const std = @import("std");
const ast_mod = @import("../parser/ast.zig");
const Node = ast_mod.Node;
const NodeIndex = ast_mod.NodeIndex;
const NodeList = ast_mod.NodeList;
const Tag = Node.Tag;
const token_mod = @import("../lexer/token.zig");
const Span = token_mod.Span;
const es_helpers = @import("es_helpers.zig");

pub fn ES2022(comptime Transformer: type) type {
    return struct {
        /// 클래스 바디에서 static block을 제거하고, IIFE로 변환하여 pending_nodes에 추가한다.
        /// 반환값: static block이 있었으면 true, 없었으면 false.
        ///
        /// class_name_span: 클래스 이름의 Span. null이면 익명 클래스 (this 치환 안 함).
        ///
        /// 동작:
        ///   1. 원본 class_body의 멤버를 순회
        ///   2. static_block이 아닌 멤버 → 그대로 방문하여 새 body에 추가
        ///   3. static_block → body에서 제거하고 IIFE로 변환, static_blocks에 수집
        ///   4. 호출자가 class 노드를 pending_nodes에 넣고, static_blocks의 IIFE를 그 뒤에 추가
        pub fn lowerStaticBlocks(
            self: *Transformer,
            body_idx: NodeIndex,
            new_body_out: *NodeIndex,
            static_block_iifes: *std.ArrayList(NodeIndex),
            class_name_span: ?Span,
        ) Transformer.Error!bool {
            const body_node = self.ast.getNode(body_idx);
            const body_start = body_node.data.list.start;
            const body_len = body_node.data.list.len;

            // 먼저 static block이 있는지 빠르게 확인 (read-only 스캔이므로 슬라이스 안전)
            var has_static_block = false;
            {
                const body_members = self.ast.extra_data.items[body_start .. body_start + body_len];
                for (body_members) |raw_idx| {
                    const member = self.ast.getNode(@enumFromInt(raw_idx));
                    if (member.tag == .static_block) {
                        has_static_block = true;
                        break;
                    }
                }
            }

            if (!has_static_block) return false;

            // static block이 있으면: 멤버를 분류하여 새 body를 생성
            const scratch_top = self.scratch.items.len;
            defer self.scratch.shrinkRetainingCapacity(scratch_top);

            // pending_nodes save/restore: 중첩 호출에 안전
            const pending_top = self.pending_nodes.items.len;
            defer self.pending_nodes.shrinkRetainingCapacity(pending_top);

            // while 인덱스 루프: visitNode/buildStaticBlockIIFE가 extra_data를 재할당할 수 있으므로 슬라이스 캐시 금지
            var j: u32 = 0;
            while (j < body_len) : (j += 1) {
                const raw_idx = self.ast.extra_data.items[body_start + j];
                const member = self.ast.getNode(@enumFromInt(raw_idx));
                if (member.tag == .static_block) {
                    // static block → IIFE로 변환
                    const iife = try buildStaticBlockIIFE(self, member, class_name_span);
                    try static_block_iifes.append(self.allocator, iife);
                } else {
                    // 일반 멤버 → 그대로 방문
                    const new_member = try self.visitNode(@enumFromInt(raw_idx));

                    // pending_nodes 드레인
                    if (self.pending_nodes.items.len > pending_top) {
                        try self.scratch.appendSlice(self.allocator, self.pending_nodes.items[pending_top..]);
                        self.pending_nodes.shrinkRetainingCapacity(pending_top);
                    }

                    if (!new_member.isNone()) {
                        try self.scratch.append(self.allocator, new_member);
                    }
                }
            }

            // 새 class_body 노드 생성
            const new_list = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
            new_body_out.* = try self.ast.addNode(.{
                .tag = .class_body,
                .span = body_node.span,
                .data = .{ .list = new_list },
            });

            return true;
        }

        // ================================================================
        // Private Methods (#method) → WeakSet + standalone function (SWC 방식)
        // ================================================================

        /// 클래스 바디에서 private method를 추출하여 WeakSet + standalone function으로 변환한다.
        ///
        /// 2-pass 방식:
        ///   Pass 1: body를 스캔하여 private method 매핑 수집
        ///   Pass 2: current_private_methods를 설정한 후 body 멤버를 visit (this.#method() 호출 변환)
        ///
        /// 반환: true이면 private method가 있어 변환 수행됨.
        pub fn lowerPrivateMethods(
            self: *Transformer,
            body_idx: NodeIndex,
            new_body_out: *NodeIndex,
            pre_stmts: *std.ArrayList(NodeIndex),
            ctor_init_stmts: *std.ArrayList(NodeIndex),
            mappings: *std.ArrayList(Transformer.PrivateMethodMapping),
            has_super: bool,
        ) Transformer.Error!bool {
            const body_node = self.ast.getNode(body_idx);
            const body_start = body_node.data.list.start;
            const body_len = body_node.data.list.len;
            const span = body_node.span;

            // ── Pass 1: private method 수집 + pre_stmts 생성 (read-only 스캔이므로 슬라이스 안전) ──
            {
                const body_members = self.ast.extra_data.items[body_start .. body_start + body_len];
                for (body_members) |raw_idx| {
                    const member = self.ast.getNode(@enumFromInt(raw_idx));
                    if (member.tag != .method_definition) continue;

                    const extras = self.ast.extra_data.items;
                    const me = member.data.extra;
                    const key: NodeIndex = @enumFromInt(extras[me]);
                    const flags = extras[me + 4];
                    const is_static = (flags & 0x01) != 0;

                    if (key.isNone() or is_static) continue;
                    const key_node = self.ast.getNode(key);
                    if (key_node.tag != .private_identifier) continue;

                    const orig_name = self.ast.source[key_node.span.start..key_node.span.end]; // "#bar"

                    const names = try es_helpers.makePrivateMethodNames(self.allocator, orig_name);

                    try mappings.append(self.allocator, .{
                        .original_name = orig_name,
                        .weakset_name = names.ws_name,
                        .func_name = names.fn_name,
                        .member_idx = @enumFromInt(raw_idx),
                    });
                }
            }

            if (mappings.items.len == 0) return false;

            // ── current_private_methods 설정 (Pass 2에서 this.#method() 변환에 필요) ──
            const saved_private_methods = self.current_private_methods;
            self.current_private_methods = mappings.items;
            defer self.current_private_methods = saved_private_methods;

            // ── Pass 2: pre_stmts 생성 + non-private 멤버 visit (단일 루프) ──
            // while 인덱스 루프: visitNode/buildStandaloneFunc가 extra_data를 재할당할 수 있으므로 슬라이스 캐시 금지
            var body_nodes: std.ArrayList(NodeIndex) = .empty;
            defer body_nodes.deinit(self.allocator);

            var found_constructor = false;
            var mapping_idx: usize = 0;

            var j: u32 = 0;
            while (j < body_len) : (j += 1) {
                const raw_idx = self.ast.extra_data.items[body_start + j];
                const member_idx: NodeIndex = @enumFromInt(raw_idx);

                // private method → WeakSet 선언 + standalone function + ctor init
                // Pass 1에서 저장한 member_idx로 판별 (재감지 불필요)
                if (mapping_idx < mappings.items.len and
                    @intFromEnum(mappings.items[mapping_idx].member_idx) == raw_idx)
                {
                    const mapping = mappings.items[mapping_idx];
                    mapping_idx += 1;

                    const ws_decl = try es_helpers.buildWeakCollectionDecl(self, "WeakSet", mapping.weakset_name, span);
                    try pre_stmts.append(self.allocator, ws_decl);

                    const func_decl = try es_helpers.buildStandaloneFunc(self, mapping.func_name, member_idx, span);
                    try pre_stmts.append(self.allocator, func_decl);

                    const init_stmt = try es_helpers.buildPrivateMethodInit(self, mapping.weakset_name, span);
                    try ctor_init_stmts.append(self.allocator, init_stmt);
                    continue;
                }

                // 일반 멤버 visit
                var new_member = try self.visitNode(@enumFromInt(raw_idx));

                if (new_member.isNone()) continue;

                // constructor에 WeakSet.add(this) 주입
                if (ctor_init_stmts.items.len > 0) {
                    const new_node = self.ast.getNode(new_member);
                    if (new_node.tag == .method_definition) {
                        const ne = new_node.data.extra;
                        const nkey: NodeIndex = @enumFromInt(self.ast.extra_data.items[ne]);
                        if (!nkey.isNone()) {
                            const nk = self.ast.getNode(nkey);
                            const kt = self.ast.source[nk.span.start..nk.span.end];
                            if (std.mem.eql(u8, kt, "constructor")) {
                                new_member = try injectIntoMethod(self, new_member, ctor_init_stmts.items);
                                found_constructor = true;
                            }
                        }
                    }
                }

                try body_nodes.append(self.allocator, new_member);
            }

            // constructor가 없으면 새로 생성하여 맨 앞에 삽입
            if (!found_constructor and ctor_init_stmts.items.len > 0) {
                const ctor = try buildNewConstructor(self, ctor_init_stmts.items, has_super, span);
                try body_nodes.insert(self.allocator, 0, ctor);
            }

            // 새 class_body 생성
            const new_list = try self.ast.addNodeList(body_nodes.items);
            new_body_out.* = try self.ast.addNode(.{
                .tag = .class_body,
                .span = span,
                .data = .{ .list = new_list },
            });

            return true;
        }

        /// method_definition의 body 앞에 문들을 삽입하여 새 method_definition 반환.
        fn injectIntoMethod(self: *Transformer, method_node_idx: NodeIndex, stmts: []const NodeIndex) Transformer.Error!NodeIndex {
            const node = self.ast.getNode(method_node_idx);
            const extras = self.ast.extra_data.items;
            const me = node.data.extra;

            const saved_key = extras[me];
            const saved_ps = extras[me + 1];
            const saved_pl = extras[me + 2];
            const saved_flags = extras[me + 4];
            const saved_deco_start = extras[me + 5];
            const saved_deco_len = extras[me + 6];
            const body_idx: NodeIndex = @enumFromInt(extras[me + 3]);

            const new_body = try self.prependStatementsToBody(body_idx, stmts);

            const new_me = try self.ast.addExtras(&.{
                saved_key,              saved_ps,    saved_pl,
                @intFromEnum(new_body), saved_flags, saved_deco_start,
                saved_deco_len,
            });
            return self.ast.addNode(.{
                .tag = .method_definition,
                .span = node.span,
                .data = .{ .extra = new_me },
            });
        }

        /// 빈 constructor method_definition에 init_stmts를 넣어 생성.
        fn buildNewConstructor(self: *Transformer, init_stmts: []const NodeIndex, has_super: bool, span: Span) Transformer.Error!NodeIndex {
            // body: [super(...args), ...init_stmts] (has_super일 때)
            //       [...init_stmts] (has_super가 아닐 때)
            const scratch_top = self.scratch.items.len;
            defer self.scratch.shrinkRetainingCapacity(scratch_top);

            var params_list = try self.ast.addNodeList(&.{});

            if (has_super) {
                // rest parameter: ...args
                const args_span = try self.ast.addString("args");
                const args_binding = try self.ast.addNode(.{
                    .tag = .binding_identifier,
                    .span = args_span,
                    .data = .{ .string_ref = args_span },
                });
                const rest_param = try self.ast.addNode(.{
                    .tag = .rest_element,
                    .span = args_span,
                    .data = .{ .unary = .{ .operand = args_binding, .flags = 0 } },
                });
                params_list = try self.ast.addNodeList(&.{rest_param});

                // super(...args)
                const super_node = try self.ast.addNode(.{
                    .tag = .super_expression,
                    .span = span,
                    .data = .{ .none = 0 },
                });
                const args_ref = try es_helpers.makeIdentifierRef(self, "args");
                const spread = try self.ast.addNode(.{
                    .tag = .spread_element,
                    .span = span,
                    .data = .{ .unary = .{ .operand = args_ref, .flags = 0 } },
                });
                const super_call = try es_helpers.makeCallExpr(self, super_node, &.{spread}, span);
                const super_stmt = try es_helpers.makeExprStmt(self, super_call, span);
                try self.scratch.append(self.allocator, super_stmt);
            }

            for (init_stmts) |stmt| {
                try self.scratch.append(self.allocator, stmt);
            }

            const body_list = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
            const ctor_body = try self.ast.addNode(.{
                .tag = .block_statement,
                .span = span,
                .data = .{ .list = body_list },
            });
            const ctor_name_span = try self.ast.addString("constructor");
            const ctor_key = try self.ast.addNode(.{
                .tag = .identifier_reference,
                .span = ctor_name_span,
                .data = .{ .string_ref = ctor_name_span },
            });
            const ctor_extra = try self.ast.addExtras(&.{
                @intFromEnum(ctor_key),
                params_list.start,
                params_list.len,
                @intFromEnum(ctor_body),
                0, 0, 0, // flags, deco_start, deco_len
            });
            return self.ast.addNode(.{
                .tag = .method_definition,
                .span = span,
                .data = .{ .extra = ctor_extra },
            });
        }

        /// this.#method(args) → __classPrivateMethodGet(this, _set, _fn).call(this, args)
        pub fn lowerPrivateMethodCall(self: *Transformer, node: Node) ?Transformer.Error!NodeIndex {
            // call_expression: extra = [callee, args_start, args_len, flags]
            const ce = node.data.extra;
            if (ce >= self.ast.extra_data.items.len) return null;
            const callee_idx: NodeIndex = self.readNodeIdx(ce, 0);
            if (callee_idx.isNone()) return null;

            const callee_node = self.ast.getNode(callee_idx);
            if (callee_node.tag != .private_field_expression) return null;

            // private_field_expression: extra = [object, property, flags]
            const pfe = callee_node.data.extra;
            if (pfe + 1 >= self.ast.extra_data.items.len) return null;
            const obj_idx: NodeIndex = self.readNodeIdx(pfe, 0);
            const prop_idx: NodeIndex = self.readNodeIdx(pfe, 1);
            if (prop_idx.isNone()) return null;

            const prop_node = self.ast.getNode(prop_idx);
            if (prop_node.tag != .private_identifier) return null;

            const orig_name = self.ast.source[prop_node.span.start..prop_node.span.end];

            // current_private_methods에서 매핑 찾기
            const mapping = findPrivateMethodMapping(self, orig_name) orelse return null;

            const args_start = self.readU32(ce, 1);
            const args_len = self.readU32(ce, 2);

            const new_obj = try self.visitNode(obj_idx);
            const get_call = try buildMethodGetCall(self, new_obj, mapping, node.span);

            const call_prop = try es_helpers.makeIdentifierRef(self, "call");
            const callee_member = try es_helpers.makeStaticMember(self, get_call, call_prop, node.span);

            const scratch_top = self.scratch.items.len;
            defer self.scratch.shrinkRetainingCapacity(scratch_top);
            // reuse new_obj instead of visiting again
            try self.scratch.append(self.allocator, new_obj);

            // visitNode가 extra_data를 재할당할 수 있으므로 인덱스 루프 사용
            var i_loop: u32 = 0;
            while (i_loop < args_len) : (i_loop += 1) {
                const arg_raw = self.ast.extra_data.items[args_start + i_loop];
                const new_arg = try self.visitNode(@enumFromInt(arg_raw));
                if (!new_arg.isNone()) {
                    try self.scratch.append(self.allocator, new_arg);
                }
            }

            return es_helpers.makeCallExpr(self, callee_member, self.scratch.items[scratch_top..], node.span);
        }

        /// private method 단독 참조 변환:
        ///   this.#method → __classPrivateMethodGet(this, _set, _fn).bind(this)
        pub fn lowerPrivateMethodGet(self: *Transformer, node: Node) ?Transformer.Error!NodeIndex {
            const pfe = node.data.extra;
            if (pfe + 1 >= self.ast.extra_data.items.len) return null;
            const obj_idx: NodeIndex = self.readNodeIdx(pfe, 0);
            const prop_idx: NodeIndex = self.readNodeIdx(pfe, 1);
            if (prop_idx.isNone()) return null;

            const prop_node = self.ast.getNode(prop_idx);
            if (prop_node.tag != .private_identifier) return null;

            const orig_name = self.ast.source[prop_node.span.start..prop_node.span.end];
            const mapping = findPrivateMethodMapping(self, orig_name) orelse return null;

            const new_obj = try self.visitNode(obj_idx);
            const get_call = try buildMethodGetCall(self, new_obj, mapping, node.span);

            const bind_prop = try es_helpers.makeIdentifierRef(self, "bind");
            const callee = try es_helpers.makeStaticMember(self, get_call, bind_prop, node.span);
            return es_helpers.makeCallExpr(self, callee, &.{new_obj}, node.span);
        }

        /// __classPrivateMethodGet(obj, _set, _fn) 호출 노드 생성.
        fn buildMethodGetCall(self: *Transformer, new_obj: NodeIndex, mapping: Transformer.PrivateMethodMapping, span: Span) Transformer.Error!NodeIndex {
            self.runtime_helpers.class_private_method_get = true;
            const helper_ref = try es_helpers.makeIdentifierRef(self, "__classPrivateMethodGet");
            const ws_ref = try es_helpers.makeIdentifierRef(self, mapping.weakset_name);
            const fn_ref = try es_helpers.makeIdentifierRef(self, mapping.func_name);
            return es_helpers.makeCallExpr(self, helper_ref, &.{ new_obj, ws_ref, fn_ref }, span);
        }

        /// current_private_methods에서 "#name"으로 매핑 검색.
        fn findPrivateMethodMapping(self: *const Transformer, orig_name: []const u8) ?Transformer.PrivateMethodMapping {
            for (self.current_private_methods) |m| {
                if (std.mem.eql(u8, m.original_name, orig_name)) return m;
            }
            return null;
        }

        // ================================================================
        // Private Fields (#field) → WeakMap + constructor init (Babel 방식)
        // ================================================================

        /// 클래스 바디에서 private instance field를 추출하여 WeakMap + ctor init으로 변환.
        ///
        /// class X { #f = 1; get(){ return this.#f; } }
        /// → var _f = new WeakMap();
        ///   class X {
        ///     constructor() { _f.set(this, 1); }
        ///     get() { return _f.get(this); }
        ///   }
        ///
        /// 2-pass (lowerPrivateMethods와 동일 구조):
        ///   Pass 1: body를 스캔하여 private field 매핑 수집 + body에서 property_definition 제거
        ///   Pass 2: current_private_fields를 설정한 후 body 멤버를 visit
        ///           → this.#f 참조는 transformer dispatch에서 기존 lowerPrivateFieldGet/Set 경유
        ///
        /// 반환: true이면 private field가 있어 변환 수행됨.
        ///
        /// TODO: static private field, this.#f++ update expression은 기존
        ///       lowerPrivateFieldUpdate 경로가 unsupported.class 게이트에 묶여 있어
        ///       별도 작업 필요.
        pub fn lowerPrivateFields(
            self: *Transformer,
            body_idx: NodeIndex,
            new_body_out: *NodeIndex,
            pre_stmts: *std.ArrayList(NodeIndex),
            ctor_init_stmts: *std.ArrayList(NodeIndex),
            mappings: *std.ArrayList(Transformer.PrivateFieldMapping),
            has_super: bool,
        ) Transformer.Error!bool {
            const body_node = self.ast.getNode(body_idx);
            const body_start = body_node.data.list.start;
            const body_len = body_node.data.list.len;
            const span = body_node.span;

            // ── Pass 1: private instance field 수집 (read-only 스캔) ──
            // 각 mapping의 member_raw_idx + init_idx 쌍을 병렬 배열로 임시 저장
            var field_member_raw: std.ArrayList(u32) = .empty;
            defer field_member_raw.deinit(self.allocator);
            var field_init_idx: std.ArrayList(NodeIndex) = .empty;
            defer field_init_idx.deinit(self.allocator);

            {
                const body_members = self.ast.extra_data.items[body_start .. body_start + body_len];
                for (body_members) |raw_idx| {
                    const member = self.ast.getNode(@enumFromInt(raw_idx));
                    if (member.tag != .property_definition) continue;

                    const pe = member.data.extra;
                    const key: NodeIndex = self.readNodeIdx(pe, 0);
                    if (key.isNone()) continue;
                    const key_node = self.ast.getNode(key);
                    if (key_node.tag != .private_identifier) continue;

                    const flags = self.readU32(pe, 2);
                    const is_static = (flags & 0x01) != 0;
                    if (is_static) continue; // TODO: static private field

                    const init_val: NodeIndex = self.readNodeIdx(pe, 1);
                    const orig_name = self.ast.source[key_node.span.start..key_node.span.end]; // "#f"

                    // "#f" → "_f"
                    const bare = orig_name[1..];
                    const var_name = try self.allocator.alloc(u8, 1 + bare.len);
                    var_name[0] = '_';
                    @memcpy(var_name[1..], bare);

                    try mappings.append(self.allocator, .{
                        .original_name = orig_name,
                        .var_name = var_name,
                    });
                    try field_member_raw.append(self.allocator, raw_idx);
                    try field_init_idx.append(self.allocator, init_val);
                }
            }

            if (mappings.items.len == 0) return false;

            // ── current_private_fields 설정 (Pass 2에서 this.#f 변환에 필요) ──
            const saved_private_fields = self.current_private_fields;
            self.current_private_fields = mappings.items;
            defer self.current_private_fields = saved_private_fields;

            // pre_stmts: var _f = new WeakMap();
            for (mappings.items) |m| {
                const ws_decl = try es_helpers.buildWeakCollectionDecl(self, "WeakMap", m.var_name, span);
                try pre_stmts.append(self.allocator, ws_decl);
            }

            // ── Pass 2: body 멤버 visit — private property_definition은 제거,
            //           constructor에는 _f.set(this, init) 주입 ──
            var body_nodes: std.ArrayList(NodeIndex) = .empty;
            defer body_nodes.deinit(self.allocator);

            var found_constructor = false;

            var j: u32 = 0;
            while (j < body_len) : (j += 1) {
                const raw_idx = self.ast.extra_data.items[body_start + j];

                // private field property_definition은 body에서 제거 (대신 ctor init 생성)
                var is_private_field_def = false;
                var init_for_this: NodeIndex = .none;
                var var_name_for_this: []const u8 = "";
                for (field_member_raw.items, field_init_idx.items, mappings.items) |fr, fi, m| {
                    if (fr == raw_idx) {
                        is_private_field_def = true;
                        init_for_this = fi;
                        var_name_for_this = m.var_name;
                        break;
                    }
                }
                if (is_private_field_def) {
                    const init_stmt = try buildPrivateFieldSetInit(self, var_name_for_this, init_for_this, span);
                    try ctor_init_stmts.append(self.allocator, init_stmt);
                    continue;
                }

                // 일반 멤버 visit (this.#f 참조는 dispatch에서 lowerPrivateFieldGet/Set 경유)
                var new_member = try self.visitNode(@enumFromInt(raw_idx));
                if (new_member.isNone()) continue;

                // constructor에 _f.set(this, init) 주입
                if (ctor_init_stmts.items.len > 0) {
                    const new_node = self.ast.getNode(new_member);
                    if (new_node.tag == .method_definition) {
                        const ne = new_node.data.extra;
                        const nkey: NodeIndex = @enumFromInt(self.ast.extra_data.items[ne]);
                        if (!nkey.isNone()) {
                            const nk = self.ast.getNode(nkey);
                            const kt = self.ast.source[nk.span.start..nk.span.end];
                            if (std.mem.eql(u8, kt, "constructor")) {
                                new_member = try injectIntoMethod(self, new_member, ctor_init_stmts.items);
                                found_constructor = true;
                            }
                        }
                    }
                }

                try body_nodes.append(self.allocator, new_member);
            }

            // constructor가 없으면 새로 생성하여 맨 앞에 삽입
            if (!found_constructor and ctor_init_stmts.items.len > 0) {
                const ctor = try buildNewConstructor(self, ctor_init_stmts.items, has_super, span);
                try body_nodes.insert(self.allocator, 0, ctor);
            }

            const new_list = try self.ast.addNodeList(body_nodes.items);
            new_body_out.* = try self.ast.addNode(.{
                .tag = .class_body,
                .span = span,
                .data = .{ .list = new_list },
            });

            return true;
        }

        /// _f.set(this, init) expression_statement 생성. (es2015_class의 buildPrivateFieldInit 동일)
        fn buildPrivateFieldSetInit(self: *Transformer, var_name: []const u8, init_idx: NodeIndex, span: Span) Transformer.Error!NodeIndex {
            const wm_ref = try es_helpers.makeIdentifierRef(self, var_name);
            const set_prop = try es_helpers.makeIdentifierRef(self, "set");
            const callee = try es_helpers.makeStaticMember(self, wm_ref, set_prop, span);
            const this_node = try self.ast.addNode(.{
                .tag = .this_expression,
                .span = span,
                .data = .{ .none = 0 },
            });
            const new_init = if (!init_idx.isNone()) try self.visitNode(init_idx) else try es_helpers.makeVoidZero(self, span);
            const call = try es_helpers.makeCallExpr(self, callee, &.{ this_node, new_init }, span);
            return self.ast.addNode(.{
                .tag = .expression_statement,
                .span = span,
                .data = .{ .unary = .{ .operand = call, .flags = 0 } },
            });
        }

        /// static block의 body를 IIFE `(() => { ...body... })()`로 변환.
        /// static block: unary node, operand = block_statement (function_body)
        ///
        /// class_name_span이 있으면 body 안의 this → 클래스 이름으로 치환.
        /// 치환은 transformer의 static_block_class_name / this_depth 필드를 통해
        /// visitNode(.this_expression) 단계에서 수행된다.
        pub fn buildStaticBlockIIFE(self: *Transformer, static_block_node: Node, class_name_span: ?Span) Transformer.Error!NodeIndex {
            // static block body 방문 시 this 치환 컨텍스트 설정
            const saved_class_name = self.static_block_class_name;
            const saved_this_depth = self.this_depth;
            self.static_block_class_name = class_name_span;
            self.this_depth = 0;
            defer {
                self.static_block_class_name = saved_class_name;
                self.this_depth = saved_this_depth;
            }

            // static block의 body를 방문
            const new_body = try self.visitNode(static_block_node.data.unary.operand);

            const span = static_block_node.span;

            // 빈 formal_parameters 노드 생성
            const empty_params_list = try self.ast.addNodeList(&.{});
            const params = try self.ast.addNode(.{
                .tag = .formal_parameters,
                .span = span,
                .data = .{ .list = empty_params_list },
            });

            // arrow_function_expression: extra = [params, body, flags]
            // flags = 0 (non-async)
            const arrow_extra = try self.ast.addExtras(&.{
                @intFromEnum(params),
                @intFromEnum(new_body),
                0, // flags
            });
            const arrow = try self.ast.addNode(.{
                .tag = .arrow_function_expression,
                .span = span,
                .data = .{ .extra = arrow_extra },
            });

            // 괄호로 감싸기: (arrow)
            const paren_arrow = try es_helpers.makeParenExpr(self, arrow, span);

            // call_expression: extra = [callee, args_start, args_len, flags]
            const empty_args = try self.ast.addNodeList(&.{});
            const call = try self.ast.addExtras(&.{
                @intFromEnum(paren_arrow),
                empty_args.start,
                empty_args.len,
                0, // flags
            });
            const call_node = try self.ast.addNode(.{
                .tag = .call_expression,
                .span = span,
                .data = .{ .extra = call },
            });

            // expression_statement로 감싸기
            return self.ast.addNode(.{
                .tag = .expression_statement,
                .span = span,
                .data = .{ .unary = .{ .operand = call_node, .flags = 0 } },
            });
        }
    };
}
