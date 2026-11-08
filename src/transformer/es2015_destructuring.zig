//! ES2015 다운레벨링: destructuring
//!
//! --target < es2015 일 때 활성화.
//!
//! variable_declarator에서 binding pattern을 감지하여 개별 선언으로 분해:
//!   const { a, b } = obj → var _ref = obj; var a = _ref.a; var b = _ref.b;
//!   const [x, y] = arr  → var _ref = arr; var x = _ref[0]; var y = _ref[1];
//!   const { a = 1 } = obj → var _ref = obj; var a = _ref.a === void 0 ? 1 : _ref.a;
//!
//! 구현: variable_declaration 레벨에서 처리.
//! destructuring이 있는 declarator를 여러 declarator로 풀어서 대체한다.
//!
//! 스펙:
//! - https://tc39.es/ecma262/#sec-destructuring-assignment (ES2015)
//! - https://tc39.es/ecma262/#sec-destructuring-binding-patterns (ES2015)
//!
//! 참고:
//! - SWC: crates/swc_ecma_compat_es2015/src/destructuring.rs (~1388줄)

const std = @import("std");
const ast_mod = @import("../parser/ast.zig");
const ast_walk = @import("../parser/ast_walk.zig");
const Node = ast_mod.Node;
const NodeIndex = ast_mod.NodeIndex;
const NodeList = ast_mod.NodeList;
const Tag = Node.Tag;
const token_mod = @import("../lexer/token.zig");
const Span = token_mod.Span;
const es_helpers = @import("es_helpers.zig");
const es2015_class = @import("es2015_class.zig");
const es2015_block_scoping = @import("es2015_block_scoping.zig");

const InlineIteratorCleanup = struct {
    record: es_helpers.TempIdentityCapture,
    span: Span,
    depth: u32,
    order: usize,
};

pub const BindingPatternContext = struct {
    output_scope: ?@import("../semantic/scope.zig").ScopeId = null,
    use_scope: @import("../semantic/scope.zig").ScopeId,
    /// Initial evaluation owner already authenticated by the caller. Nested
    /// generated blocks keep this frontier for the source default expressions.
    source_scope: ?@import("../semantic/scope.zig").ScopeId = null,
    /// Exact declaration key for a producer-recorded iteration initializer.
    initialization_source: NodeIndex = .none,
    /// Query-local abrupt cleanup for expressions kept at their original slot.
    inline_cleanup: ?*std.ArrayList(InlineIteratorCleanup) = null,
    inline_depth: u32 = 0,
};

pub const BindingPatternStatementPlan = struct {
    statement: NodeIndex,
    value: NodeIndex,
};

pub fn ES2015Destructuring(comptime Transformer: type) type {
    return struct {
        const SymbolKind = @import("../semantic/symbol.zig").SymbolKind;

        const DestructuringTemp = struct {
            binding: NodeIndex,
            identity: es_helpers.TempIdentityCapture,
        };

        fn tempSymbolKind(kind: ast_mod.VariableDeclarationKind) SymbolKind {
            return switch (kind) {
                .@"var" => .variable_var,
                .let => .variable_let,
                .@"const", .using, .await_using => .variable_const,
            };
        }

        fn makeDestructuringTempBinding(
            self: *Transformer,
            name_span: Span,
            decl_kind: ast_mod.VariableDeclarationKind,
        ) Transformer.Error!DestructuringTemp {
            if (self.temp_var_counter == 0)
                std.debug.panic("destructuring temp binding has no allocator slot", .{});
            const counter_index = self.temp_var_counter - 1;
            const allocated_span = self.temp_span_by_counter.get(counter_index) orelse
                std.debug.panic("destructuring temp binding lost its allocator slot", .{});
            if (allocated_span.start != name_span.start or allocated_span.end != name_span.end)
                std.debug.panic("destructuring temp binding disagrees with its allocator slot", .{});
            const temp_producer_id = self.temp_producer_id_by_counter.get(counter_index) orelse
                std.debug.panic("destructuring temp binding has no producer ID", .{});
            const binding = try es_helpers.makeSyntheticBinding(self, name_span);
            var identity: es_helpers.TempIdentityCapture = .{
                .span = name_span,
                .temp_producer_id = temp_producer_id,
            };
            // The lowering callsite already knows the emitted declaration
            // kind and current lexical owner. Capture the binding identity
            // before emitting any pattern reads.
            if (self.semantic_edit_enabled and !self.current_scope.isNone()) {
                const binding_name = self.ast.getNode(binding).data.string_ref;
                const id = (try self.declareSyntheticInScope(
                    binding,
                    binding_name,
                    tempSymbolKind(decl_kind),
                    self.current_scope,
                )) orelse std.debug.panic("semantic destructuring temp did not receive a SymbolId", .{});
                try self.recordTempProducerSymbolId(temp_producer_id, id);
                es_helpers.markStandaloneLateSyntheticTemp(self, id, self.current_scope);
                identity = .{
                    .span = name_span,
                    .symbol_id = id,
                    .reference_scope = self.current_scope,
                    .temp_producer_id = temp_producer_id,
                };
            }
            if (!self.namespace_iife_scope.isNone() and self.current_scope == self.namespace_iife_scope) {
                try self.destructuring_temp_bindings.put(self.allocator, @backingInt(binding), {});
                try self.namespace_temp_bindings.append(self.allocator, .{ .binding = binding, .span = name_span, .scope = self.current_scope });
            }
            // This temp already has an explicit declaration in the lowered
            // pattern. Do not emit a second, unbound `var _a` at the enclosing
            // function or program boundary during generic temp hoisting.
            es_helpers.consumeTempVarSpan(self, name_span);
            return .{ .binding = binding, .identity = identity };
        }

        fn makeDestructuringTempReadWithIdentity(
            self: *Transformer,
            node_span: Span,
            identity: es_helpers.TempIdentityCapture,
        ) Transformer.Error!NodeIndex {
            return es_helpers.makeTempRefFromIdentity(self, identity, node_span, .{ .read = true });
        }

        /// variable_declaration에 destructuring pattern이 있는지 확인.
        pub fn hasDestructuring(self: *const Transformer, node: Node) bool {
            const extras = self.ast.extra_data.items;
            const e = node.data.extra;
            if (e + 2 >= extras.len) return false;
            const list_start = extras[e + 1];
            const list_len = extras[e + 2];
            const decls = extras[list_start .. list_start + list_len];
            for (decls) |raw_idx| {
                const decl = self.ast.getNode(@fromBackingInt(@intCast(raw_idx)));
                if (decl.tag != .variable_declarator) continue;
                const name: NodeIndex = @fromBackingInt(@intCast(extras[decl.data.extra]));
                if (name.isNone()) continue;
                const name_node = self.ast.getNode(name);
                if (name_node.tag == .object_pattern or name_node.tag == .array_pattern) return true;
            }
            return false;
        }

        /// variable_declaration 안에 object rest (...rest)가 있는지 체크.
        /// ES2018 object rest는 target < es2018에서 __rest로 변환 필요.
        pub fn hasObjectRest(self: *const Transformer, node: Node) bool {
            const extras = self.ast.extra_data.items;
            const e = node.data.extra;
            if (e + 2 >= extras.len) return false;
            const list_start = extras[e + 1];
            const list_len = extras[e + 2];
            const decls = extras[list_start .. list_start + list_len];
            for (decls) |raw_idx| {
                const decl = self.ast.getNode(@fromBackingInt(@intCast(raw_idx)));
                if (decl.tag != .variable_declarator) continue;
                const name: NodeIndex = @fromBackingInt(@intCast(extras[decl.data.extra]));
                if (name.isNone()) continue;
                const name_node = self.ast.getNode(name);
                if (name_node.tag == .object_pattern) {
                    if (objectPatternHasRest(self, name_node)) return true;
                }
            }
            return false;
        }

        fn objectPatternHasRest(self: *const Transformer, pattern: Node) bool {
            return self.ast.nodeListSplitRest(pattern.data.list).rest_operand != null;
        }

        fn bindPatternTemp(
            self: *Transformer,
            binding: NodeIndex,
            name_span: Span,
            span: Span,
            decl_kind: ast_mod.VariableDeclarationKind,
            identity: es_helpers.TempIdentityCapture,
        ) Transformer.Error!void {
            if (!self.namespace_iife_scope.isNone() and self.current_scope == self.namespace_iife_scope and
                self.destructuring_temp_bindings.contains(@backingInt(binding))) return;
            if (self.getSymbolIdAt(binding)) |id| {
                if (identity.symbol_id) |producer_id| {
                    if (@backingInt(producer_id) != id)
                        std.debug.panic("destructuring temp binding changed its producer SymbolId", .{});
                } else if (self.semantic_edit_enabled and !self.current_scope.isNone()) {
                    std.debug.panic("known-owner destructuring temp lost its producer SymbolId", .{});
                }
                return;
            }
            const kind: @import("../semantic/symbol.zig").SymbolKind = switch (decl_kind) {
                .@"var" => .variable_var,
                .let => .variable_let,
                .@"const", .using, .await_using => .variable_const,
            };
            try self.bindSyntheticTempWithProducerIdentityInScope(
                binding,
                name_span,
                span,
                kind,
                self.current_scope,
                identity.temp_producer_id,
            );
            if (self.semantic_edit_enabled and !self.current_scope.isNone()) {
                const producer_id = identity.symbol_id orelse
                    std.debug.panic("known-owner destructuring temp was not identified at creation", .{});
                const binding_id = self.getSymbolIdAt(binding) orelse
                    std.debug.panic("known-owner destructuring temp failed to bind its producer SymbolId", .{});
                if (@backingInt(producer_id) != binding_id)
                    std.debug.panic("destructuring temp binding changed its producer SymbolId", .{});
            }
        }

        /// assignment-target 트리(object/array_assignment_target)에 object rest 가
        /// 중첩 포함되어 있는지 재귀 검사 (#4261). for-of/for-in LHS 게이트용 —
        /// top-level `object_assignment_target` rest 뿐 아니라 `for ([b, {a,...r}] of)`
        /// 처럼 array-target 안에 중첩된 object rest 도 검출. array rest(`[a,...r]`,
        /// ES2015)는 제외(object rest=ES2018 만 lowering 필요).
        pub fn destructuringTargetHasObjectRest(self: *const Transformer, node_idx: NodeIndex) bool {
            if (node_idx.isNone()) return false;
            const node = self.ast.getNode(node_idx);
            return switch (node.tag) {
                .object_assignment_target => blk: {
                    if (self.ast.nodeListSplitRest(node.data.list).rest_operand != null) break :blk true;
                    break :blk targetListHasObjectRest(self, node.data.list);
                },
                .array_assignment_target => targetListHasObjectRest(self, node.data.list),
                .assignment_target_property_property => destructuringTargetHasObjectRest(self, node.data.binary.right),
                .assignment_target_with_default => destructuringTargetHasObjectRest(self, node.data.binary.left),
                // `[a, ...{ b, ...r }] = src` — 배열 rest 안에 중첩된 객체 rest (#4789).
                .assignment_target_rest => destructuringTargetHasObjectRest(self, node.data.unary.operand),
                else => false,
            };
        }

        fn targetListHasObjectRest(self: *const Transformer, list: NodeList) bool {
            const items = self.ast.extra_data.items[list.start .. list.start + list.len];
            for (items) |raw| {
                if (destructuringTargetHasObjectRest(self, @fromBackingInt(@intCast(raw)))) return true;
            }
            return false;
        }

        fn makeTrackedBindingWriteRef(self: *Transformer, binding: NodeIndex, name_span: Span) Transformer.Error!NodeIndex {
            return makeTrackedBindingWriteRefAt(self, binding, name_span, name_span);
        }

        fn makeTrackedBindingWriteRefAt(self: *Transformer, binding: NodeIndex, name_span: Span, node_span: Span) Transformer.Error!NodeIndex {
            // Assignment patterns bypass the ordinary identifier visitor.
            // Preserve the class-name setter used to reject writes to the
            // immutable inner binding, including nested/default/rest targets.
            if (self.options.unsupported.class) {
                if (try es2015_class.ES2015Class(Transformer).classSelfAccess(self, binding)) |access| return access;
            }
            // A visit-free declaration plan retains the source binding leaf.
            // Its exact SID can already own a selected block-storage spelling
            // (notably a lowered for header). Carry that existing decision to
            // the new write reference without visiting/renaming the leaf.
            const selected_span = if (self.tableRenameOf(binding)) |renamed|
                try self.ast.addString(renamed)
            else
                name_span;
            const target = try self.makeIdentifierRefWithSymbolAt(selected_span, node_span, binding);
            if (self.getSymbolIdAt(binding)) |raw_id| {
                if (!try self.replaceUserReferenceWithCopy(binding, target)) {
                    const symbols = if (self.semantic_editor) |*editor| editor.symbols.items else self.symbols;
                    if (raw_id >= symbols.len) std.debug.panic("destructuring write binding symbol is out of range", .{});
                    try self.trackUserWriteFromBinding(target, binding, symbols[raw_id].scope_id);
                }
            }
            return target;
        }

        /// destructuring이 있는 variable_declaration을 분해한다.
        /// 각 destructuring declarator를 여러 개의 단순 declarator로 풀어서 반환.
        pub fn lowerDestructuringDeclaration(self: *Transformer, node: Node) Transformer.Error!NodeIndex {
            const e = node.data.extra;
            const span = node.span;
            const orig_kind = self.ast.variableDeclarationKind(node);
            const kind = if (self.options.unsupported.block_scoping) es2015_block_scoping.lowerKind(orig_kind) else orig_kind;
            // extras를 visitNode 전에 읽기 (재할당 방지)
            const list_start = self.readU32(e, 1);
            const list_len = self.readU32(e, 2);

            const scratch_top = self.scratch.items.len;
            defer self.scratch.shrinkRetainingCapacity(scratch_top);

            // visitNode가 AST를 변형하므로 인덱스 루프 사용
            var i_loop: u32 = 0;
            while (i_loop < list_len) : (i_loop += 1) {
                const raw_idx = self.ast.extra_data.items[list_start + i_loop];
                const decl = self.ast.getNode(@fromBackingInt(@intCast(raw_idx)));
                if (decl.tag != .variable_declarator) continue;

                // extras를 visitNode 전에 매번 직접 읽기 (재할당 방지)
                const name_idx: NodeIndex = self.readNodeIdx(decl.data.extra, 0);
                const init_idx: NodeIndex = self.readNodeIdx(decl.data.extra, 2);

                if (name_idx.isNone()) continue;
                const name_node = self.ast.getNode(name_idx);

                if (name_node.tag == .object_pattern or name_node.tag == .array_pattern) {
                    // destructuring → 분해
                    // 먼저 init을 임시 변수에 저장
                    const new_init = try self.visitNode(init_idx);
                    const pattern_init = if (name_node.tag == .array_pattern)
                        try buildArrayRead(self, new_init, name_node, span)
                    else
                        new_init;
                    const temp_span = try es_helpers.makeTempVarSpan(self);
                    const temp = try makeDestructuringTempBinding(self, temp_span, kind);

                    // var _ref = init
                    const ref_decl = try es_helpers.makeDeclarator(self, temp.binding, pattern_init, span);
                    try self.scratch.append(self.allocator, ref_decl);

                    // 패턴을 개별 declarator로 분해
                    try emitPatternDeclaratorsWithIdentity(self, name_node, temp.identity, span, kind);
                    try bindPatternTemp(self, temp.binding, temp_span, span, kind, temp.identity);
                } else {
                    // 일반 declarator: 그대로 visit
                    const new_decl = try self.visitNode(@fromBackingInt(@intCast(raw_idx)));
                    if (!new_decl.isNone()) {
                        try self.scratch.append(self.allocator, new_decl);
                    }
                }
            }

            // 새 variable_declaration — 원래 종류를 지킨다. `var` 로 바꾸면 블록 안 `const` 가
            // 블록 밖으로 새고 같은 이름 `let` 과 충돌한다 (#4790). let/const 를 못 쓰는 타깃은
            // 일반 선언과 같은 규칙(`lowerKind`)으로 낮춘다.
            const new_list = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
            const var_extra = try self.ast.addExtras(&.{ @backingInt(kind), new_list.start, new_list.len });
            return self.ast.addNode(.{
                .tag = .variable_declaration,
                .span = span,
                .data = .{ .extra = var_extra },
            });
        }

        /// Select only binding-pattern syntax; defaults' expressions, member
        /// keys and nested function bodies never participate in this demand.
        pub fn declarationNeedsIteratorStatements(self: *Transformer, declaration: Node) Transformer.Error!bool {
            if (declaration.tag != .variable_declaration) return false;
            var pending: std.ArrayList(NodeIndex) = .empty;
            defer pending.deinit(self.allocator);
            const start = self.ast.extra_data.items[declaration.data.extra + 1];
            const length = self.ast.extra_data.items[declaration.data.extra + 2];
            for (0..length) |index| {
                const declarator = self.ast.getNode(self.ast.readExtraNode(start, @intCast(index)));
                if (try expressionNeedsIteratorStatements(self, self.ast.readExtraNode(declarator.data.extra, 2))) return true;
                try pending.append(self.allocator, self.ast.readExtraNode(declarator.data.extra, 0));
            }
            while (pending.pop()) |index| {
                if (index.isNone()) continue;
                const node = self.ast.getNode(index);
                switch (node.tag) {
                    .array_pattern => return true,
                    .object_pattern => {
                        const split = self.ast.nodeListSplitRest(node.data.list);
                        for (split.elements) |raw| {
                            const property = self.ast.getNode(@fromBackingInt(raw));
                            if (property.tag == .binding_property) try pending.append(self.allocator, if (property.data.binary.right.isNone()) property.data.binary.left else property.data.binary.right);
                        }
                        if (split.rest_operand) |rest| try pending.append(self.allocator, rest);
                    },
                    .assignment_pattern => try pending.append(self.allocator, node.data.binary.left),
                    .binding_rest_element => try pending.append(self.allocator, node.data.unary.operand),
                    else => {},
                }
            }
            return false;
        }

        /// A statement-list consumer may publish a real try/finally region.
        /// Source declarations stay var storage in their original var owner;
        /// each source binding leaf remains the physical declaration anchor.
        pub fn lowerDestructuringDeclarationStatement(self: *Transformer, declaration: Node) Transformer.Error!NodeIndex {
            return lowerDestructuringDeclarationStatementImpl(self, declaration, .none);
        }

        pub fn lowerDestructuringDeclarationStatementAt(self: *Transformer, declaration: NodeIndex) Transformer.Error!NodeIndex {
            return lowerDestructuringDeclarationStatementImpl(self, self.ast.getNode(declaration), declaration);
        }

        fn lowerDestructuringDeclarationStatementImpl(self: *Transformer, declaration: Node, declaration_key: NodeIndex) Transformer.Error!NodeIndex {
            std.debug.assert(self.options.unsupported.block_scoping);
            const source_scope = self.current_scope;
            const block = try newPatternBlock(self, source_scope, declaration.span);
            const storage = if (self.semantic_edit_enabled) self.nearestVarScope(source_scope) else source_scope;
            const saved = self.current_scope;
            self.current_scope = block.scope;
            defer self.current_scope = saved;
            const context: BindingPatternContext = .{ .output_scope = if (storage.isNone()) null else storage, .use_scope = block.scope, .source_scope = source_scope, .initialization_source = declaration_key };
            var statements: std.ArrayList(NodeIndex) = .empty;
            defer statements.deinit(self.allocator);
            var declarations: std.ArrayList(NodeIndex) = .empty;
            defer declarations.deinit(self.allocator);
            const start = self.ast.extra_data.items[declaration.data.extra + 1];
            const length = self.ast.extra_data.items[declaration.data.extra + 2];
            for (0..length) |index| {
                const declarator_index = self.ast.readExtraNode(start, @intCast(index));
                const declarator = self.ast.getNode(declarator_index);
                const binding = self.ast.readExtraNode(declarator.data.extra, 0);
                const source_initializer = self.ast.readExtraNode(declarator.data.extra, 2);
                const pattern = self.ast.getNode(binding);
                const initializer = if (comptime @hasDecl(Transformer, "patternInitializer"))
                    if (pattern.tag == .array_pattern or pattern.tag == .object_pattern) try self.patternInitializer(binding, source_initializer) else source_initializer
                else
                    source_initializer;
                if (pattern.tag != .array_pattern and pattern.tag != .object_pattern) {
                    const value = if (try expressionNeedsIteratorStatements(self, initializer)) value: {
                        const prepared = if (comptime @hasDecl(Transformer, "patternInitializer"))
                            try self.patternInitializer(binding, initializer)
                        else
                            initializer;
                        const plan = try prepareIteratorExpressionStatement(self, prepared, context);
                        try statements.append(self.allocator, try self.visitNode(plan.statement));
                        break :value plan.value;
                    } else value: {
                        try movePatternExpression(self, initializer, source_scope, block.scope);
                        const visited = try self.visitNode(declarator_index);
                        const selected = self.ast.readExtraNode(self.ast.getNode(visited).data.extra, 2);
                        break :value if (comptime @hasDecl(Transformer, "patternInitializer"))
                            try self.patternInitializer(binding, selected)
                        else
                            selected;
                    };
                    const source_leaf = self.ast.getNode(binding);
                    const selected_name = if (self.renamedNameOf(binding)) |name| try self.ast.addString(name) else source_leaf.data.string_ref;
                    const physical = try self.makeUserBinding(selected_name, binding);
                    try declarations.append(self.allocator, try es_helpers.makeDeclarator(self, physical, .none, declaration.span));
                    if (!value.isNone()) try emitBindingPatternAt(self, binding, value, declaration.span, context, .retain, &statements);
                    continue;
                }
                var walker = try ast_walk.bindingIdentifiers(self.allocator, self.ast, binding, .{});
                defer walker.deinit();
                while (try walker.next()) |leaf| {
                    const source = self.ast.getNode(leaf);
                    const selected_name = if (self.renamedNameOf(leaf)) |name| try self.ast.addString(name) else source.data.string_ref;
                    // This is a new physical declaration, not a retained
                    // source leaf. Reuse the ordinary destructuring producer's
                    // exact binding-copy/reanchor handoff before emitting it.
                    const selected = try self.makeUserBinding(selected_name, leaf);
                    try declarations.append(self.allocator, try es_helpers.makeDeclarator(self, selected, .none, declaration.span));
                }
                const plan = try prepareBindingPatternStatement(self, pattern, initializer, declaration.span, context);
                try statements.append(self.allocator, try self.visitNode(plan.statement));
            }
            // The original lexical owner must keep the physical declarations.
            // Only iterator evaluation enters the generated region. Otherwise
            // outputBindingTargetScope would move source let/const storage into
            // the new block and detach earlier TDZ initialization references.
            if (declarations.items.len != 0) try self.pending_nodes.append(self.allocator, try es_helpers.makeVarDeclaration(self, declarations.items, .@"var", declaration.span));
            self.ast.nodes.items[@backingInt(block.node)].data.list = try self.ast.addNodeList(statements.items);
            return block.node;
        }

        /// binding pattern (object_pattern / array_pattern) 을 destructuring assignment sequence
        /// 로 분해. async/generator 선언/catch 준비 단계 (es2015_generator.prepareDeclarationPlan)
        /// 처럼 `var { x } = await ...` 가 `({ x: x } = _state.sent())` 같은 binding-pattern-as-LHS
        /// 형태로 떨어지는 경우에 사용 — ES5 환경에서는 invalid 라 lowering 필수 (#1960).
        ///
        /// 입력 `pattern` 은 binding pattern (이미 visit 끝났거나 raw), `rhs` 는 visit 끝난 노드.
        /// 결과는 `(_ref = rhs, x = _ref.x, ..., _ref)` sequence_expression. 호출자는 보통
        /// `makeExprStmt` 로 wrap 해서 statement 로 넣는다.
        /// Keep only producer-owned pattern storage in the actual state-machine
        /// wrapper. Nested functions still allocate against their own scopes;
        /// no generated spelling is used to recover a storage identity.
        fn reservePatternTemp(self: *Transformer, span: Span, output_scope: ?@import("../semantic/scope.zig").ScopeId) Transformer.Error!es_helpers.TempIdentityCapture {
            const identity = if (output_scope) |scope|
                if (!scope.isNone()) try es_helpers.reserveTrackedTempIdentityInOutputScope(self, span, scope, self.current_scope) else try es_helpers.reserveTrackedTempIdentity(self, span)
            else
                try es_helpers.reserveTrackedTempIdentity(self, span);
            if (output_scope != null and self.state_machine_depth > 0 and
                output_scope.? == self.generator_state_machine_scope)
            {
                const Generator = @import("es2015_generator.zig").ES2015Generator(Transformer);
                try Generator.appendGeneratorTempSpanWithIdentity(self, identity.span, identity.symbol_id, identity.owner_scope);
                const producer = &self.generator_temp_producer_identities.items[self.generator_temp_producer_identities.items.len - 1];
                producer.temp_producer_id = identity.temp_producer_id;
                producer.producer_owned = true;
            }
            return identity;
        }

        pub fn lowerBindingPatternAssignment(
            self: *Transformer,
            pattern: Node,
            rhs: NodeIndex,
            span: Span,
            producer_output_scope: ?@import("../semantic/scope.zig").ScopeId,
        ) Transformer.Error!NodeIndex {
            return lowerBindingPatternAssignmentWithPreparation(self, pattern, rhs, span, producer_output_scope, .visit);
        }

        const PatternPreparation = enum { visit, retain };

        fn patternChild(self: *Transformer, index: NodeIndex, comptime preparation: PatternPreparation) Transformer.Error!NodeIndex {
            return if (preparation == .visit) self.visitNode(index) else index;
        }

        /// Build ordered simple assignments without visiting source defaults or
        /// keys. The state planner owns their later execution and suspension.
        pub fn prepareBindingPatternAssignment(self: *Transformer, pattern: Node, rhs: NodeIndex, span: Span, output_scope: @import("../semantic/scope.zig").ScopeId) Transformer.Error!NodeIndex {
            return lowerBindingPatternAssignmentWithPreparation(self, pattern, rhs, span, output_scope, .retain);
        }

        /// Only expression carriers whose evaluation order is explicitly
        /// represented below participate. Calls retain their own Reference
        /// protocol; this demand does not silently lift their arguments.
        /// Keep the original call/new Reference in the expression tree. Only
        /// iterator operations become comma expressions; abrupt cleanup belongs
        /// to the surrounding statement's real lexical region.
        pub fn referenceExpressionNeedsIterator(self: *Transformer, expression: NodeIndex) Transformer.Error!bool {
            const root = self.ast.getNode(expression);
            if (root.tag != .call_expression and root.tag != .new_expression) return false;
            const Pending = struct { node: NodeIndex, in_default: bool };
            var pending: std.ArrayList(Pending) = .empty;
            defer pending.deinit(self.allocator);
            var seen: std.AutoHashMapUnmanaged(NodeIndex, void) = .empty;
            defer seen.deinit(self.allocator);
            var selected: usize = 0;
            try pending.append(self.allocator, .{ .node = expression, .in_default = false });
            while (pending.pop()) |item| {
                const index = item.node;
                if (index.isNone()) continue;
                const slot = try seen.getOrPut(self.allocator, index);
                if (slot.found_existing) continue;
                const node = self.ast.getNode(index);
                if (assignmentNeedsIteratorStatements(self, node)) {
                    selected += 1;
                }
                switch (node.tag) {
                    .function_expression, .arrow_function_expression, .class_expression => continue,
                    else => {},
                }
                var children = ast_walk.children(self.ast, node);
                while (children.next()) |child| try pending.append(self.allocator, .{
                    .node = child,
                    .in_default = item.in_default or ((node.tag == .assignment_target_with_default or node.tag == .assignment_pattern) and child == node.data.binary.right),
                });
            }
            return selected != 0;
        }

        pub fn prepareReferenceExpressionStatement(self: *Transformer, expression: NodeIndex, outer: BindingPatternContext) Transformer.Error!BindingPatternStatementPlan {
            return prepareReferenceRegion(self, expression, outer, .none, .none);
        }

        pub fn forReferenceNeedsIterator(self: *Transformer, source: NodeIndex) Transformer.Error!bool {
            const loop = self.ast.getNode(source);
            if (loop.tag != .for_statement) return false;
            const condition = self.ast.readExtraNode(loop.data.extra, 1);
            const update = self.ast.readExtraNode(loop.data.extra, 2);
            const header = (!condition.isNone() and try referenceExpressionNeedsIterator(self, condition)) or
                (!update.isNone() and try referenceExpressionNeedsIterator(self, update));
            return header;
        }

        pub fn prepareIteratorForReference(self: *Transformer, source: NodeIndex, source_label: NodeIndex) Transformer.Error!NodeIndex {
            const loop = self.ast.getNode(source);
            const scope = self.outputOwnedScope(source) orelse self.current_scope;
            const expression = try self.ast.addNode(.{ .tag = .sequence_expression, .span = loop.span, .data = .{ .list = try self.ast.addNodeList(&.{ self.ast.readExtraNode(loop.data.extra, 1), self.ast.readExtraNode(loop.data.extra, 2) }) } });
            const plan = try prepareReferenceRegion(self, expression, .{ .use_scope = scope, .source_scope = scope }, source, source_label);
            return plan.statement;
        }

        fn prepareReferenceRegion(self: *Transformer, expression: NodeIndex, outer: BindingPatternContext, source_for: NodeIndex, source_label: NodeIndex) Transformer.Error!BindingPatternStatementPlan {
            const span = self.ast.getNode(expression).span;
            const source_scope = outer.source_scope orelse outer.use_scope;
            const region = try newPatternBlock(self, if (source_for.isNone()) outer.use_scope else self.outputScopeParent(source_scope), span);
            const body = try newPatternBlock(self, region.scope, span);
            const output_for = source_for;
            // Header evaluation retains the original for ScopeId. The typed
            // wrapper only reparents that owner beneath its fresh try body.
            const evaluation_scope = if (source_for.isNone()) body.scope else source_scope;
            var cleanup: std.ArrayList(InlineIteratorCleanup) = .empty;
            defer cleanup.deinit(self.allocator);
            const context: BindingPatternContext = .{
                .use_scope = evaluation_scope,
                .source_scope = source_scope,
                .output_scope = outer.output_scope orelse if (self.semantic_edit_enabled) self.nearestVarScope(outer.use_scope) else null,
                .inline_cleanup = &cleanup,
            };
            try movePatternExpression(self, expression, source_scope, evaluation_scope);
            const saved_scope = self.current_scope;
            self.current_scope = evaluation_scope;
            defer self.current_scope = saved_scope;
            // Children are processed first so nested source assignments retain
            // their exact evaluation slot in the enclosing default/RHS.
            const Pending = struct { node: NodeIndex, depth: u32 };
            var pending: std.ArrayList(Pending) = .empty;
            defer pending.deinit(self.allocator);
            var order: std.ArrayList(Pending) = .empty;
            defer order.deinit(self.allocator);
            var seen: std.AutoHashMapUnmanaged(NodeIndex, void) = .empty;
            defer seen.deinit(self.allocator);
            try pending.append(self.allocator, .{ .node = expression, .depth = 0 });
            while (pending.pop()) |item| {
                const index = item.node;
                if (index.isNone()) continue;
                const slot = try seen.getOrPut(self.allocator, index);
                if (slot.found_existing) continue;
                const node = self.ast.getNode(index);
                switch (node.tag) {
                    .function_expression, .arrow_function_expression, .class_expression => continue,
                    else => {},
                }
                try order.append(self.allocator, item);
                var children = ast_walk.children(self.ast, node);
                while (children.next()) |child| try pending.append(self.allocator, .{
                    .node = child,
                    .depth = item.depth + @as(u32, if (node.tag == .array_assignment_target or
                        ((node.tag == .assignment_target_with_default or node.tag == .assignment_pattern) and child == node.data.binary.right)) 1 else 0),
                });
            }
            while (order.pop()) |item| {
                const index = item.node;
                const node = self.ast.getNode(index);
                if (!assignmentNeedsIteratorStatements(self, node)) continue;
                const rhs = try reservePatternTemp(self, node.span, context.output_scope);
                var statements: std.ArrayList(NodeIndex) = .empty;
                defer statements.deinit(self.allocator);
                try appendPatternExpression(self, &statements, try es_helpers.makeAssignExpr(self, try patternTempRef(self, rhs, evaluation_scope, node.span, true), node.data.binary.right, node.span, 0), node.span);
                var assignment_context = context;
                assignment_context.inline_depth = item.depth;
                try emitBindingPatternAt(self, node.data.binary.left, try patternTempRef(self, rhs, evaluation_scope, node.span, false), node.span, assignment_context, .retain, &statements);
                var values: std.ArrayList(NodeIndex) = .empty;
                defer values.deinit(self.allocator);
                for (statements.items) |statement| {
                    const emitted = self.ast.getNode(statement);
                    // Nested statement-producing defaults require their own
                    // region bridge; never silently flatten their control flow.
                    if (emitted.tag != .expression_statement) std.debug.panic("inline iterator expression produced non-expression control flow", .{});
                    try values.append(self.allocator, emitted.data.unary.operand);
                }
                try values.append(self.allocator, try patternTempRef(self, rhs, evaluation_scope, node.span, false));
                self.ast.nodes.items[@backingInt(index)] = .{ .tag = .sequence_expression, .span = node.span, .data = .{ .list = try self.ast.addNodeList(values.items) } };
            }
            const result: ?es_helpers.TempIdentityCapture = if (source_for.isNone()) try reservePatternTemp(self, span, context.output_scope) else null;
            self.ast.nodes.items[@backingInt(body.node)].data.list = try self.ast.addNodeList(&.{if (result) |identity|
                try es_helpers.makeExprStmt(self, try es_helpers.makeAssignExpr(self, try patternTempRef(self, identity, body.scope, span, true), try iteratorValueBoundary(self, expression, span), span, 0), span)
            else if (source_label.isNone())
                output_for
            else label: {
                var labeled = self.ast.getNode(source_label);
                if (labeled.tag != .labeled_statement or labeled.data.binary.right != source_for)
                    std.debug.panic("iterator Reference label lost its exact source loop", .{});
                labeled.data.binary.right = output_for;
                break :label try self.ast.addNode(labeled);
            }});
            const thrown = try reservePatternTemp(self, span, context.output_scope);
            const caught_name = try es_helpers.makeTempVarSpan(self);
            const caught = try es_helpers.makeSyntheticBinding(self, caught_name);
            es_helpers.consumeTempVarSpan(self, caught_name);
            const catch_body = try self.ast.addNode(.{ .tag = .block_statement, .span = span, .data = .{ .list = try self.ast.addNodeList(&.{}) } });
            const clause = try self.ast.addNode(.{ .tag = .catch_clause, .span = span, .data = .{ .binary = .{ .left = caught, .right = catch_body, .flags = 0 } } });
            const catch_scope = if (self.semantic_edit_enabled) try self.addGeneratedScope(region.scope, clause, .catch_clause) else region.scope;
            const catch_body_scope = if (self.semantic_edit_enabled) try self.addGeneratedScope(catch_scope, catch_body, .block) else catch_scope;
            const caught_sid = if (self.semantic_edit_enabled) try self.declareSyntheticInScope(caught, span, .catch_binding, catch_scope) else null;
            const caught_ref = try es_helpers.makeExactSyntheticRefAt(self, caught_name, span);
            if (caught_sid) |sid| try self.addSyntheticRefInScope(caught_ref, sid, catch_body_scope, .{ .read = true });
            const mark = try es_helpers.makeExprStmt(self, try es_helpers.makeAssignExpr(self, try patternTempRef(self, thrown, catch_body_scope, span, true), try es_helpers.makeBoolLiteral(self, true), span, 0), span);
            const rethrow = try self.ast.addNode(.{ .tag = .throw_statement, .span = span, .data = .{ .unary = .{ .operand = caught_ref, .flags = 0 } } });
            self.ast.nodes.items[@backingInt(catch_body)].data.list = try self.ast.addNodeList(&.{ mark, rethrow });
            const final_body = try newPatternBlock(self, region.scope, span);
            var final_statements: std.ArrayList(NodeIndex) = .empty;
            defer final_statements.deinit(self.allocator);
            std.mem.sort(InlineIteratorCleanup, cleanup.items, {}, struct {
                fn before(_: void, left: InlineIteratorCleanup, right: InlineIteratorCleanup) bool {
                    if (left.depth != right.depth) return left.depth > right.depth;
                    return left.order > right.order;
                }
            }.before);
            for (cleanup.items) |entry| {
                try appendPatternExpression(self, &final_statements, try iteratorOperation(self, try patternTempRef(self, entry.record, final_body.scope, entry.span, false), try patternTempRef(self, thrown, final_body.scope, span, false), 4, entry.span), entry.span);
            }
            self.ast.nodes.items[@backingInt(final_body.node)].data.list = try self.ast.addNodeList(final_statements.items);
            var statements: std.ArrayList(NodeIndex) = .empty;
            defer statements.deinit(self.allocator);
            // Each invocation resets even records in unselected branches.
            for (cleanup.items) |entry| try appendPatternExpression(self, &statements, try es_helpers.makeAssignExpr(self, try patternTempRef(self, entry.record, region.scope, entry.span, true), try es_helpers.makeVoidZero(self, entry.span), entry.span, 0), entry.span);
            try appendPatternExpression(self, &statements, try es_helpers.makeAssignExpr(self, try patternTempRef(self, thrown, region.scope, span, true), try es_helpers.makeBoolLiteral(self, false), span, 0), span);
            try statements.append(self.allocator, try self.ast.addNode(.{ .tag = .try_statement, .span = span, .data = .{ .ternary = .{ .a = body.node, .b = clause, .c = final_body.node } } }));
            self.ast.nodes.items[@backingInt(region.node)].data.list = try self.ast.addNodeList(statements.items);
            if (!source_for.isNone() and self.semantic_edit_enabled) {
                self.semantic_editor.?.publishIteratorForReferenceRegion(source_for, source_label, region.node, body.node, output_for, source_scope) catch |err| {
                    if (err == error.OutOfMemory) return error.OutOfMemory;
                    std.debug.panic("invalid typed iterator for Reference region: {s}", .{@errorName(err)});
                };
            }
            return .{ .statement = region.node, .value = if (result) |identity| try patternTempRef(self, identity, outer.use_scope, span, false) else .none };
        }

        pub fn expressionNeedsIteratorStatements(self: *Transformer, expression: NodeIndex) Transformer.Error!bool {
            if (!expression.isNone() and try referenceExpressionNeedsIterator(self, expression)) return true;
            var pending: std.ArrayList(NodeIndex) = .empty;
            defer pending.deinit(self.allocator);
            try pending.append(self.allocator, expression);
            while (pending.pop()) |index| {
                if (index.isNone()) continue;
                const node = self.ast.getNode(index);
                if (assignmentNeedsIteratorStatements(self, node)) return true;
                switch (node.tag) {
                    .parenthesized_expression => try pending.append(self.allocator, node.data.unary.operand),
                    .sequence_expression => for (0..node.data.list.len) |offset| {
                        try pending.append(self.allocator, self.ast.readExtraNode(node.data.list.start, @intCast(offset)));
                    },
                    .logical_expression => try pending.appendSlice(self.allocator, &.{ node.data.binary.left, node.data.binary.right }),
                    .conditional_expression => try pending.appendSlice(self.allocator, &.{ node.data.ternary.a, node.data.ternary.b, node.data.ternary.c }),
                    else => {},
                }
            }
            return false;
        }

        fn iteratorValueBoundary(self: *Transformer, value: NodeIndex, span: Span) Transformer.Error!NodeIndex {
            return self.ast.addNode(.{ .tag = .sequence_expression, .span = span, .data = .{ .list = try self.ast.addNodeList(&.{ try es_helpers.makeNumericLiteral(self, 0), value }) } });
        }

        pub fn prepareIteratorExpressionStatement(self: *Transformer, expression: NodeIndex, context: BindingPatternContext) Transformer.Error!BindingPatternStatementPlan {
            if (try referenceExpressionNeedsIterator(self, expression))
                return prepareReferenceExpressionStatement(self, expression, context);
            var direct = expression;
            while (self.ast.getNode(direct).tag == .parenthesized_expression)
                direct = self.ast.getNode(direct).data.unary.operand;
            const assignment = self.ast.getNode(direct);
            // The binding plan already owns the exact RHS value. A second
            // result cell adds only a dead write for discarded assignments.
            if (assignmentNeedsIteratorStatements(self, assignment))
                return prepareBindingPatternStatement(self, self.ast.getNode(assignment.data.binary.left), assignment.data.binary.right, assignment.span, context);
            const span = self.ast.getNode(expression).span;
            const root = try newPatternBlock(self, context.use_scope, span);
            var actual = context;
            actual.source_scope = context.source_scope orelse context.use_scope;
            actual.use_scope = root.scope;
            if (actual.output_scope == null and self.semantic_edit_enabled) actual.output_scope = self.nearestVarScope(context.use_scope);
            const saved = self.current_scope;
            self.current_scope = actual.use_scope;
            defer self.current_scope = saved;
            var statements: std.ArrayList(NodeIndex) = .empty;
            defer statements.deinit(self.allocator);
            const value = try emitIteratorExpressionValue(self, expression, actual, &statements);
            const result = try reservePatternTemp(self, span, actual.output_scope);
            try appendPatternExpression(self, &statements, try es_helpers.makeAssignExpr(self, try patternTempRef(self, result, actual.use_scope, span, true), try iteratorValueBoundary(self, value, span), span, 0), span);
            self.ast.nodes.items[@backingInt(root.node)].data.list = try self.ast.addNodeList(statements.items);
            return .{ .statement = root.node, .value = try patternTempRef(self, result, context.use_scope, span, false) };
        }

        fn emitIteratorExpressionValue(self: *Transformer, expression: NodeIndex, context: BindingPatternContext, out: *std.ArrayList(NodeIndex)) Transformer.Error!NodeIndex {
            const Statements = std.ArrayList(NodeIndex);
            const Value = struct { node: NodeIndex, context: BindingPatternContext, out: *Statements };
            const Assign = struct { identity: es_helpers.TempIdentityCapture, context: BindingPatternContext, out: *Statements, span: Span };
            const Finish = struct {
                condition: NodeIndex,
                yes: PatternBlock,
                no: ?PatternBlock,
                yes_statements: *Statements,
                no_statements: ?*Statements,
                identity: es_helpers.TempIdentityCapture,
                context: BindingPatternContext,
                out: *Statements,
                span: Span,
            };
            const Work = union(enum) {
                value: Value,
                discard: struct { out: *Statements, span: Span },
                conditional: Value,
                logical: Value,
                assign: Assign,
                finish: Finish,
            };
            var work: std.ArrayList(Work) = .empty;
            defer work.deinit(self.allocator);
            var values: std.ArrayList(NodeIndex) = .empty;
            defer values.deinit(self.allocator);
            var owned: std.ArrayList(*Statements) = .empty;
            defer {
                for (owned.items) |statements| {
                    statements.deinit(self.allocator);
                    self.allocator.destroy(statements);
                }
                owned.deinit(self.allocator);
            }
            const saved = self.current_scope;
            defer self.current_scope = saved;
            try work.append(self.allocator, .{ .value = .{ .node = expression, .context = context, .out = out } });
            while (work.pop()) |next| switch (next) {
                .value => |item| {
                    self.current_scope = item.context.use_scope;
                    const node = self.ast.getNode(item.node);
                    if (assignmentNeedsIteratorStatements(self, node)) {
                        const plan = try prepareBindingPatternStatement(self, self.ast.getNode(node.data.binary.left), node.data.binary.right, node.span, item.context);
                        try item.out.append(self.allocator, plan.statement);
                        try values.append(self.allocator, plan.value);
                    } else switch (node.tag) {
                        .parenthesized_expression => try work.append(self.allocator, .{ .value = .{ .node = node.data.unary.operand, .context = item.context, .out = item.out } }),
                        .sequence_expression => {
                            var offset = node.data.list.len;
                            while (offset > 0) {
                                offset -= 1;
                                if (offset + 1 < node.data.list.len) try work.append(self.allocator, .{ .discard = .{ .out = item.out, .span = node.span } });
                                try work.append(self.allocator, .{ .value = .{ .node = self.ast.readExtraNode(node.data.list.start, offset), .context = item.context, .out = item.out } });
                            }
                        },
                        .conditional_expression, .logical_expression => {
                            try work.append(self.allocator, if (node.tag == .conditional_expression) .{ .conditional = item } else .{ .logical = item });
                            try work.append(self.allocator, .{ .value = .{ .node = if (node.tag == .conditional_expression) node.data.ternary.a else node.data.binary.left, .context = item.context, .out = item.out } });
                        },
                        else => try values.append(self.allocator, try patternExpression(self, item.node, item.context, .retain)),
                    }
                },
                .discard => |item| try appendPatternExpression(self, item.out, values.pop().?, item.span),
                .assign => |item| {
                    self.current_scope = item.context.use_scope;
                    try appendPatternExpression(self, item.out, try es_helpers.makeAssignExpr(self, try patternTempRef(self, item.identity, item.context.use_scope, item.span, true), try iteratorValueBoundary(self, values.pop().?, item.span), item.span, 0), item.span);
                },
                .conditional, .logical => |item| {
                    self.current_scope = item.context.use_scope;
                    const node = self.ast.getNode(item.node);
                    const left = values.pop().?;
                    const identity = try reservePatternTemp(self, node.span, item.context.output_scope);
                    var condition = left;
                    if (next == .logical) {
                        try appendPatternExpression(self, item.out, try es_helpers.makeAssignExpr(self, try patternTempRef(self, identity, item.context.use_scope, node.span, true), try iteratorValueBoundary(self, left, node.span), node.span, 0), node.span);
                        const read = try patternTempRef(self, identity, item.context.use_scope, node.span, false);
                        const op: token_mod.Kind = @fromBackingInt(@intCast(node.data.binary.flags));
                        condition = switch (op) {
                            .amp2 => read,
                            .pipe2 => try es_helpers.makeUnaryNot(self, read, node.span),
                            .question2 => nullish: {
                                const is_null = try self.ast.addNode(.{ .tag = .binary_expression, .span = node.span, .data = .{ .binary = .{ .left = read, .right = try es_helpers.makeNullLiteral(self), .flags = @backingInt(token_mod.Kind.eq3) } } });
                                const is_void = try self.ast.addNode(.{ .tag = .binary_expression, .span = node.span, .data = .{ .binary = .{ .left = try patternTempRef(self, identity, item.context.use_scope, node.span, false), .right = try es_helpers.makeVoidZero(self, node.span), .flags = @backingInt(token_mod.Kind.eq3) } } });
                                break :nullish try self.ast.addNode(.{ .tag = .logical_expression, .span = node.span, .data = .{ .binary = .{ .left = is_null, .right = is_void, .flags = @backingInt(token_mod.Kind.pipe2) } } });
                            },
                            else => std.debug.panic("iterator expression has an invalid logical operator", .{}),
                        };
                    }
                    const yes = try newPatternBlock(self, item.context.use_scope, node.span);
                    const yes_statements = try self.allocator.create(Statements);
                    yes_statements.* = .empty;
                    owned.append(self.allocator, yes_statements) catch |err| {
                        self.allocator.destroy(yes_statements);
                        return err;
                    };
                    const no: ?PatternBlock = if (next == .conditional) try newPatternBlock(self, item.context.use_scope, node.span) else null;
                    const no_statements: ?*Statements = if (no != null) no_list: {
                        const statements = try self.allocator.create(Statements);
                        statements.* = .empty;
                        owned.append(self.allocator, statements) catch |err| {
                            self.allocator.destroy(statements);
                            return err;
                        };
                        break :no_list statements;
                    } else null;
                    try work.append(self.allocator, .{ .finish = .{ .condition = condition, .yes = yes, .no = no, .yes_statements = yes_statements, .no_statements = no_statements, .identity = identity, .context = item.context, .out = item.out, .span = node.span } });
                    if (no) |alternative| {
                        var alternate_context = item.context;
                        alternate_context.use_scope = alternative.scope;
                        try work.append(self.allocator, .{ .assign = .{ .identity = identity, .context = alternate_context, .out = no_statements.?, .span = node.span } });
                        try work.append(self.allocator, .{ .value = .{ .node = node.data.ternary.c, .context = alternate_context, .out = no_statements.? } });
                    }
                    var yes_context = item.context;
                    yes_context.use_scope = yes.scope;
                    try work.append(self.allocator, .{ .assign = .{ .identity = identity, .context = yes_context, .out = yes_statements, .span = node.span } });
                    try work.append(self.allocator, .{ .value = .{ .node = if (next == .conditional) node.data.ternary.b else node.data.binary.right, .context = yes_context, .out = yes_statements } });
                },
                .finish => |item| {
                    self.ast.nodes.items[@backingInt(item.yes.node)].data.list = try self.ast.addNodeList(item.yes_statements.items);
                    if (item.no) |alternative| self.ast.nodes.items[@backingInt(alternative.node)].data.list = try self.ast.addNodeList(item.no_statements.?.items);
                    try item.out.append(self.allocator, try self.ast.addNode(.{ .tag = .if_statement, .span = item.span, .data = .{ .ternary = .{ .a = item.condition, .b = item.yes.node, .c = if (item.no) |alternative| alternative.node else .none } } }));
                    try values.append(self.allocator, try patternTempRef(self, item.identity, item.context.use_scope, item.span, false));
                },
            };
            if (values.items.len != 1) std.debug.panic("iterator expression lost its unique value", .{});
            return values.items[0];
        }

        pub fn arrayAssignmentValue(self: *Transformer, expression: NodeIndex) ?Node {
            var selected = expression;
            while (!selected.isNone() and self.ast.getNode(selected).tag == .parenthesized_expression)
                selected = self.ast.getNode(selected).data.unary.operand;
            if (selected.isNone()) return null;
            const assignment = self.ast.getNode(selected);
            return if (assignmentNeedsIteratorStatements(self, assignment)) assignment else null;
        }

        pub fn lowerIteratorValueStatement(self: *Transformer, statement: Node, expression: NodeIndex) Transformer.Error!NodeIndex {
            const source_scope = self.current_scope;
            const region = try newPatternBlock(self, source_scope, statement.span);
            const plan = try prepareIteratorExpressionStatement(self, expression, .{ .use_scope = region.scope, .source_scope = source_scope });
            const saved = self.current_scope;
            self.current_scope = region.scope;
            defer self.current_scope = saved;
            const ready = try self.visitNode(plan.statement);
            var tail = statement;
            tail.data.unary.operand = plan.value;
            const returned = try self.ast.addNode(tail);
            self.ast.nodes.items[@backingInt(region.node)].data.list = try self.ast.addNodeList(&.{ ready, returned });
            return region.node;
        }

        pub fn assignmentNeedsIteratorStatements(self: *Transformer, assignment: Node) bool {
            if (assignment.tag != .assignment_expression) return false;
            return self.ast.getNode(assignment.data.binary.left).tag == .array_assignment_target;
        }

        /// Statement-producing binding initialization. Each array owns its own
        /// IteratorRecord and try/finally lifetime; no source suspension moves
        /// under a callback. The caller owns scheduling this actual ready AST.
        pub fn prepareBindingPatternStatement(self: *Transformer, pattern: Node, rhs: NodeIndex, span: Span, context: BindingPatternContext) Transformer.Error!BindingPatternStatementPlan {
            return bindingPatternStatement(self, pattern, rhs, span, context, .retain);
        }

        pub fn lowerBindingPatternStatement(self: *Transformer, pattern: Node, rhs: NodeIndex, span: Span, context: BindingPatternContext) Transformer.Error!BindingPatternStatementPlan {
            return bindingPatternStatement(self, pattern, rhs, span, context, .visit);
        }

        fn bindingPatternStatement(self: *Transformer, pattern: Node, rhs: NodeIndex, span: Span, context: BindingPatternContext, comptime preparation: PatternPreparation) Transformer.Error!BindingPatternStatementPlan {
            const saved = self.current_scope;
            defer self.current_scope = saved;
            const block = try newPatternBlock(self, context.use_scope, span);
            var actual = context;
            actual.source_scope = context.source_scope orelse context.use_scope;
            actual.use_scope = block.scope;
            if (actual.output_scope == null and self.semantic_edit_enabled) actual.output_scope = self.nearestVarScope(context.use_scope);
            self.current_scope = actual.use_scope;
            var statements: std.ArrayList(NodeIndex) = .empty;
            defer statements.deinit(self.allocator);
            const value = try reservePatternTemp(self, span, actual.output_scope);
            try movePatternExpression(self, rhs, actual.source_scope.?, actual.use_scope);
            try appendPatternExpression(self, &statements, try es_helpers.makeAssignExpr(self, try patternTempRef(self, value, actual.use_scope, span, true), rhs, span, 0), span);
            if (!actual.initialization_source.isNone()) {
                if (comptime @hasDecl(Transformer, "iterationInitialization"))
                    try self.iterationInitialization(actual.initialization_source, block.node, actual.use_scope, &statements);
                actual.initialization_source = .none;
            }
            try emitBindingPatternStatements(self, pattern, try patternTempRef(self, value, actual.use_scope, span, false), span, actual, preparation, &statements);
            self.ast.nodes.items[@backingInt(block.node)].data.list = try self.ast.addNodeList(statements.items);
            return .{ .statement = block.node, .value = try patternTempRef(self, value, context.use_scope, span, false) };
        }

        const PatternBlock = struct { node: NodeIndex, scope: @import("../semantic/scope.zig").ScopeId };

        fn newPatternBlock(self: *Transformer, parent: @import("../semantic/scope.zig").ScopeId, span: Span) Transformer.Error!PatternBlock {
            const block = try self.ast.addNode(.{ .tag = .block_statement, .span = span, .data = .{ .list = try self.ast.addNodeList(&.{}) } });
            const scope = if (self.semantic_edit_enabled) try self.addGeneratedScope(parent, block, .block) else parent;
            return .{ .node = block, .scope = scope };
        }

        /// Move only this actual source expression frontier into its generated
        /// evaluation block. Bindings retain their source/storage SymbolIds.
        pub fn movePatternExpression(self: *Transformer, root: NodeIndex, source: @import("../semantic/scope.zig").ScopeId, target: @import("../semantic/scope.zig").ScopeId) Transformer.Error!void {
            if (!self.semantic_edit_enabled or source == target or root.isNone()) return;
            try self.reparentGeneratedBodyScopes(source, target, root);
            var pending: std.ArrayList(NodeIndex) = .empty;
            defer pending.deinit(self.allocator);
            var seen: std.AutoHashMapUnmanaged(NodeIndex, void) = .empty;
            defer seen.deinit(self.allocator);
            try pending.append(self.allocator, root);
            while (pending.pop()) |index| {
                if (index.isNone()) continue;
                const slot = try seen.getOrPut(self.allocator, index);
                if (slot.found_existing) continue;
                const editor = &self.semantic_editor.?;
                const maybe = editor.referenceForNode(index) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => std.debug.panic("iterator expression lost its source reference: {s}", .{@errorName(err)}),
                };
                if (maybe) |reference| {
                    if (!reference.flags.declare and reference.scope_id == source) {
                        if (self.tracked_runtime_helper_ref_index.contains(@backingInt(index))) try self.relocateRuntimeHelperRef(index, target) else editor.moveReference(index, target, reference.stmt_idx, reference.scope_stmt_idx) catch |err| switch (err) {
                            error.OutOfMemory => return error.OutOfMemory,
                            else => std.debug.panic("iterator expression cannot move its source reference: {s}", .{@errorName(err)}),
                        };
                    }
                }
                var children = ast_walk.children(self.ast, self.ast.getNode(index));
                while (children.next()) |child| try pending.append(self.allocator, child);
            }
        }

        fn patternExpression(self: *Transformer, source: NodeIndex, context: BindingPatternContext, comptime preparation: PatternPreparation) Transformer.Error!NodeIndex {
            try movePatternExpression(self, source, context.source_scope orelse context.use_scope, context.use_scope);
            return patternChild(self, source, preparation);
        }

        fn appendPatternExpression(self: *Transformer, out: *std.ArrayList(NodeIndex), expression: NodeIndex, span: Span) Transformer.Error!void {
            try out.append(self.allocator, try es_helpers.makeExprStmt(self, expression, span));
        }

        fn patternTempRef(self: *Transformer, identity: es_helpers.TempIdentityCapture, scope: @import("../semantic/scope.zig").ScopeId, span: Span, write: bool) Transformer.Error!NodeIndex {
            var at_use = identity;
            at_use.reference_scope = scope;
            return es_helpers.makeTempRefFromIdentity(self, at_use, span, if (write) .{ .write = true } else .{ .read = true });
        }

        fn iteratorOperation(self: *Transformer, value: NodeIndex, argument: NodeIndex, operation: u32, span: Span) Transformer.Error!NodeIndex {
            self.runtime_helpers.read = true;
            return es_helpers.makeCallExpr(self, try es_helpers.makeRuntimeHelperRef(self, "__read"), &.{ value, argument, try es_helpers.makeNumericLiteral(self, operation) }, span);
        }

        fn iteratorStep(self: *Transformer, record: es_helpers.TempIdentityCapture, operation: u32, context: BindingPatternContext, span: Span) Transformer.Error!NodeIndex {
            return iteratorOperation(self, try patternTempRef(self, record, context.use_scope, span, false), try es_helpers.makeNumericLiteral(self, 0), operation, span);
        }

        fn emitBindingPatternStatements(self: *Transformer, pattern: Node, rhs: NodeIndex, span: Span, context: BindingPatternContext, comptime preparation: PatternPreparation, out: *std.ArrayList(NodeIndex)) Transformer.Error!void {
            const saved = self.current_scope;
            self.current_scope = context.use_scope;
            defer self.current_scope = saved;
            switch (pattern.tag) {
                .assignment_pattern, .assignment_target_with_default => {
                    const original_target = pattern.data.binary.left;
                    const target_node = self.ast.getNode(original_target);
                    const selected_target = if (target_node.tag == .static_member_expression or target_node.tag == .computed_member_expression or target_node.tag == .private_field_expression)
                        try prepareIteratorAssignmentReference(self, original_target, span, context, preparation, out)
                    else
                        original_target;
                    const value = try reservePatternTemp(self, span, context.output_scope);
                    try appendPatternExpression(self, out, try es_helpers.makeAssignExpr(self, try patternTempRef(self, value, context.use_scope, span, true), rhs, span, 0), span);
                    const check = try self.ast.addNode(.{ .tag = .binary_expression, .span = span, .data = .{ .binary = .{
                        .left = try patternTempRef(self, value, context.use_scope, span, false),
                        .right = try es_helpers.makeVoidZero(self, span),
                        .flags = @backingInt(token_mod.Kind.eq3),
                    } } });
                    if (try expressionNeedsIteratorStatements(self, pattern.data.binary.right)) {
                        const branch = try newPatternBlock(self, context.use_scope, span);
                        var branch_context = context;
                        branch_context.use_scope = branch.scope;
                        const default_plan = try prepareIteratorExpressionStatement(self, pattern.data.binary.right, branch_context);
                        const update = try es_helpers.makeExprStmt(self, try es_helpers.makeAssignExpr(self, try patternTempRef(self, value, branch.scope, span, true), default_plan.value, span, 0), span);
                        self.ast.nodes.items[@backingInt(branch.node)].data.list = try self.ast.addNodeList(&.{ default_plan.statement, update });
                        try out.append(self.allocator, try self.ast.addNode(.{ .tag = .if_statement, .span = span, .data = .{ .ternary = .{ .a = check, .b = branch.node, .c = .none } } }));
                        return emitBindingPatternAt(self, selected_target, try patternTempRef(self, value, context.use_scope, span, false), span, context, preparation, out);
                    }
                    const selected = try self.ast.addNode(.{ .tag = .conditional_expression, .span = span, .data = .{ .ternary = .{
                        .a = check,
                        .b = try patternExpression(self, pattern.data.binary.right, context, preparation),
                        .c = try patternTempRef(self, value, context.use_scope, span, false),
                    } } });
                    return emitBindingPatternAt(self, selected_target, selected, span, context, preparation, out);
                },
                .array_pattern, .array_assignment_target => return emitIteratorBindingStatements(self, pattern, rhs, span, context, preparation, out),
                .object_pattern, .object_assignment_target => return emitObjectBindingStatements(self, pattern, rhs, span, context, preparation, out),
                else => std.debug.panic("iterator binding plan received a non-binding pattern tag: {s}", .{@tagName(pattern.tag)}),
            }
        }

        fn emitIteratorBindingStatements(self: *Transformer, pattern: Node, rhs: NodeIndex, span: Span, context: BindingPatternContext, comptime preparation: PatternPreparation, out: *std.ArrayList(NodeIndex)) Transformer.Error!void {
            if (context.inline_cleanup) |cleanup| {
                const record = try reservePatternTemp(self, span, context.output_scope);
                try cleanup.append(self.allocator, .{ .record = record, .span = span, .depth = context.inline_depth, .order = cleanup.items.len });
                const opened = try iteratorOperation(self, rhs, try es_helpers.makeNumericLiteral(self, 0), 0, span);
                try appendPatternExpression(self, out, try es_helpers.makeAssignExpr(self, try patternTempRef(self, record, context.use_scope, span, true), opened, span, 0), span);
                var inner = context;
                inner.inline_depth += 1;
                const split = self.ast.nodeListSplitRest(pattern.data.list);
                for (0..split.elements.len) |offset| {
                    const leaf = self.ast.readExtraNode(pattern.data.list.start, @intCast(offset));
                    if (self.ast.getNode(leaf).tag == .elision)
                        try appendPatternExpression(self, out, try iteratorStep(self, record, 2, context, span), span)
                    else
                        try emitBindingPatternAt(self, leaf, try iteratorStep(self, record, 1, context, span), span, inner, preparation, out);
                }
                if (split.rest_operand) |leaf|
                    try emitBindingPatternAt(self, leaf, try iteratorStep(self, record, 3, context, span), span, inner, preparation, out);
                try appendPatternExpression(self, out, try iteratorOperation(self, try patternTempRef(self, record, context.use_scope, span, false), try es_helpers.makeBoolLiteral(self, false), 4, span), span);
                return;
            }
            const record = try reservePatternTemp(self, span, context.output_scope);
            const thrown = try reservePatternTemp(self, span, context.output_scope);
            try appendPatternExpression(self, out, try es_helpers.makeAssignExpr(self, try patternTempRef(self, record, context.use_scope, span, true), try es_helpers.makeVoidZero(self, span), span, 0), span);
            try appendPatternExpression(self, out, try es_helpers.makeAssignExpr(self, try patternTempRef(self, thrown, context.use_scope, span, true), try es_helpers.makeBoolLiteral(self, false), span, 0), span);
            const try_block = try newPatternBlock(self, context.use_scope, span);
            var inside = context;
            inside.use_scope = try_block.scope;
            const saved_scope = self.current_scope;
            defer self.current_scope = saved_scope;
            self.current_scope = inside.use_scope;
            var body: std.ArrayList(NodeIndex) = .empty;
            defer body.deinit(self.allocator);
            try movePatternExpression(self, rhs, context.use_scope, inside.use_scope);
            const opened = try iteratorOperation(self, rhs, try es_helpers.makeNumericLiteral(self, 0), 0, span);
            try appendPatternExpression(self, &body, try es_helpers.makeAssignExpr(self, try patternTempRef(self, record, inside.use_scope, span, true), opened, span, 0), span);
            const split = self.ast.nodeListSplitRest(pattern.data.list);
            const length = split.elements.len;
            const rest = split.rest_operand;
            for (0..length) |index| {
                const leaf = self.ast.readExtraNode(pattern.data.list.start, @intCast(index));
                const node = self.ast.getNode(leaf);
                if (node.tag == .elision) {
                    try appendPatternExpression(self, &body, try iteratorStep(self, record, 2, inside, span), span);
                } else try emitBindingPatternAt(self, leaf, try iteratorStep(self, record, 1, inside, span), span, inside, preparation, &body);
            }
            if (rest) |leaf| try emitBindingPatternAt(self, leaf, try iteratorStep(self, record, 3, inside, span), span, inside, preparation, &body);
            self.ast.nodes.items[@backingInt(try_block.node)].data.list = try self.ast.addNodeList(body.items);
            self.current_scope = context.use_scope;
            const caught_name = try es_helpers.makeTempVarSpan(self);
            const caught = try es_helpers.makeSyntheticBinding(self, caught_name);
            es_helpers.consumeTempVarSpan(self, caught_name);
            const catch_body = try self.ast.addNode(.{ .tag = .block_statement, .span = span, .data = .{ .list = try self.ast.addNodeList(&.{}) } });
            const clause = try self.ast.addNode(.{ .tag = .catch_clause, .span = span, .data = .{ .binary = .{ .left = caught, .right = catch_body, .flags = 0 } } });
            const catch_scope = if (self.semantic_edit_enabled) try self.addGeneratedScope(context.use_scope, clause, .catch_clause) else context.use_scope;
            const catch_body_scope = if (self.semantic_edit_enabled) try self.addGeneratedScope(catch_scope, catch_body, .block) else catch_scope;
            const caught_sid = if (self.semantic_edit_enabled) try self.declareSyntheticInScope(caught, span, .catch_binding, catch_scope) else null;
            const caught_ref = try es_helpers.makeExactSyntheticRefAt(self, caught_name, span);
            if (caught_sid) |sid| try self.addSyntheticRefInScope(caught_ref, sid, catch_body_scope, .{ .read = true });
            const mark = try es_helpers.makeExprStmt(self, try es_helpers.makeAssignExpr(self, try patternTempRef(self, thrown, catch_body_scope, span, true), try es_helpers.makeBoolLiteral(self, true), span, 0), span);
            const rethrow = try self.ast.addNode(.{ .tag = .throw_statement, .span = span, .data = .{ .unary = .{ .operand = caught_ref, .flags = 0 } } });
            self.ast.nodes.items[@backingInt(catch_body)].data.list = try self.ast.addNodeList(&.{ mark, rethrow });
            const final_body = try newPatternBlock(self, context.use_scope, span);
            self.current_scope = final_body.scope;
            const closed = try iteratorOperation(self, try patternTempRef(self, record, final_body.scope, span, false), try patternTempRef(self, thrown, final_body.scope, span, false), 4, span);
            self.ast.nodes.items[@backingInt(final_body.node)].data.list = try self.ast.addNodeList(&.{try es_helpers.makeExprStmt(self, closed, span)});
            try out.append(self.allocator, try self.ast.addNode(.{ .tag = .try_statement, .span = span, .data = .{ .ternary = .{ .a = try_block.node, .b = clause, .c = final_body.node } } }));
        }

        /// A default initializer runs after IteratorStep. Its member Reference
        /// base and computed key expression must already have been evaluated.
        /// ToPropertyKey remains at PutValue, after the default completes.
        fn prepareIteratorAssignmentReference(self: *Transformer, source: NodeIndex, span: Span, context: BindingPatternContext, comptime preparation: PatternPreparation, out: *std.ArrayList(NodeIndex)) Transformer.Error!NodeIndex {
            const member = self.ast.getNode(source);
            const object = self.ast.readExtraNode(member.data.extra, 0);
            const property = self.ast.readExtraNode(member.data.extra, 1);
            const unwrapped_object = es_helpers.unwrapTransparentWrappers(self, object);
            const selected_object = if (!unwrapped_object.isNone() and self.ast.getNode(unwrapped_object).tag == .super_expression)
                object
            else captured: {
                const base = try reservePatternTemp(self, span, context.output_scope);
                try appendPatternExpression(self, out, try es_helpers.makeAssignExpr(self, try patternTempRef(self, base, context.use_scope, span, true), try patternExpression(self, object, context, preparation), span, 0), span);
                break :captured try patternTempRef(self, base, context.use_scope, span, false);
            };
            const selected_property = if (member.tag == .computed_member_expression) key: {
                const identity = try reservePatternTemp(self, span, context.output_scope);
                const converted = try patternExpression(self, property, context, preparation);
                try appendPatternExpression(self, out, try es_helpers.makeAssignExpr(self, try patternTempRef(self, identity, context.use_scope, span, true), converted, span, 0), span);
                break :key try patternTempRef(self, identity, context.use_scope, span, false);
            } else property;
            return self.ast.addNode(.{ .tag = member.tag, .span = member.span, .data = .{ .extra = try self.ast.addExtras(&.{ @backingInt(selected_object), @backingInt(selected_property), self.ast.readExtra(member.data.extra, 2) }) } });
        }

        fn emitBindingPatternAt(self: *Transformer, binding: NodeIndex, rhs: NodeIndex, span: Span, context: BindingPatternContext, comptime preparation: PatternPreparation, out: *std.ArrayList(NodeIndex)) Transformer.Error!void {
            const node = self.ast.getNode(binding);
            if (node.tag == .private_field_expression) {
                if (try es2015_class.ES2015Class(Transformer).tryLowerPrivateFieldAssign(self, binding, rhs, span)) |write| {
                    try appendPatternExpression(self, out, write, span);
                    return;
                }
                // A retained native private target must stay a PutValue target,
                // rather than being visited as a private-field GetValue.
                try appendPatternExpression(self, out, try es_helpers.makeAssignExpr(self, binding, rhs, span, 0), span);
                return;
            }
            if (node.tag == .assignment_target_identifier or node.tag == .identifier_reference) {
                if (comptime @hasDecl(Transformer, "patternPutValue")) {
                    if (try self.patternPutValue(binding, rhs, context.use_scope)) |checked| {
                        try appendPatternExpression(self, out, checked, span);
                        return;
                    }
                }
                const target = try makeTrackedBindingWriteRefAt(self, binding, node.data.string_ref, span);
                if (self.semantic_edit_enabled) {
                    const row = (self.semantic_editor.?.referenceForNode(target) catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        else => std.debug.panic("iterator assignment source write invalid: {s}", .{@errorName(err)}),
                    }) orelse
                        std.debug.panic("iterator assignment has no exact source write", .{});
                    try movePatternExpression(self, target, row.scope_id, context.use_scope);
                }
                try appendPatternExpression(self, out, try es_helpers.makeAssignExpr(self, target, rhs, span, 0), span);
                return;
            }
            if (try es2015_class.ES2015Class(Transformer).trySuperAssignTarget(self, binding, rhs, span)) |write| {
                try appendPatternExpression(self, out, write, span);
                return;
            }
            if (node.tag == .static_member_expression or node.tag == .computed_member_expression) {
                const target = try patternExpression(self, binding, context, preparation);
                try appendPatternExpression(self, out, try es_helpers.makeAssignExpr(self, target, rhs, span, 0), span);
                return;
            }
            if (node.tag == .binding_identifier) {
                const target = try makeTrackedBindingWriteRefAt(self, binding, node.data.string_ref, span);
                if (self.semantic_edit_enabled) {
                    const editor = &self.semantic_editor.?;
                    const row = (editor.referenceForNode(target) catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        else => std.debug.panic("iterator binding write lost its source identity: {s}", .{@errorName(err)}),
                    }) orelse std.debug.panic("iterator binding write has no exact reference row", .{});
                    try movePatternExpression(self, target, row.scope_id, context.use_scope);
                }
                try appendPatternExpression(self, out, try es_helpers.makeAssignExpr(self, target, rhs, span, 0), span);
                return;
            }
            return emitBindingPatternStatements(self, node, rhs, span, context, preparation, out);
        }

        fn emitObjectBindingStatements(self: *Transformer, pattern: Node, rhs: NodeIndex, span: Span, context: BindingPatternContext, comptime preparation: PatternPreparation, out: *std.ArrayList(NodeIndex)) Transformer.Error!void {
            const identity = try reservePatternTemp(self, span, context.output_scope);
            try appendPatternExpression(self, out, try es_helpers.makeAssignExpr(self, try patternTempRef(self, identity, context.use_scope, span, true), rhs, span, 0), span);
            // RequireObjectCoercible has no iterator/Symbol dependency. Strict
            // checks also retain HTMLDDA's distinct, non-nullish behavior.
            const is_null = try self.ast.addNode(.{ .tag = .binary_expression, .span = span, .data = .{ .binary = .{ .left = try patternTempRef(self, identity, context.use_scope, span, false), .right = try es_helpers.makeNullLiteral(self), .flags = @backingInt(token_mod.Kind.eq3) } } });
            const is_void = try self.ast.addNode(.{ .tag = .binary_expression, .span = span, .data = .{ .binary = .{ .left = try patternTempRef(self, identity, context.use_scope, span, false), .right = try es_helpers.makeVoidZero(self, span), .flags = @backingInt(token_mod.Kind.eq3) } } });
            const nullish = try self.ast.addNode(.{ .tag = .logical_expression, .span = span, .data = .{ .binary = .{ .left = is_null, .right = is_void, .flags = @backingInt(token_mod.Kind.pipe2) } } });
            const fail = try es_helpers.makeCallExpr(self, try es_helpers.makeVoidZero(self, span), &.{}, span);
            try appendPatternExpression(self, out, try self.ast.addNode(.{ .tag = .logical_expression, .span = span, .data = .{ .binary = .{ .left = nullish, .right = fail, .flags = @backingInt(token_mod.Kind.amp2) } } }), span);
            const split = self.ast.nodeListSplitRest(pattern.data.list);
            const length = split.elements.len;
            const rest = split.rest_operand;
            var exclude: std.ArrayList(NodeIndex) = .empty;
            defer exclude.deinit(self.allocator);
            for (0..length) |index| {
                const property = self.ast.getNode(self.ast.readExtraNode(pattern.data.list.start, @intCast(index)));
                if (property.tag != .binding_property and property.tag != .assignment_target_property_identifier and property.tag != .assignment_target_property_property) continue;
                const key = property.data.binary.left;
                const target = if (property.tag == .assignment_target_property_identifier and
                    (property.data.binary.flags & 1) != 0 and !property.data.binary.right.isNone())
                    try self.ast.addNode(.{ .tag = .assignment_target_with_default, .span = property.span, .data = .{ .binary = .{ .left = key, .right = property.data.binary.right, .flags = 0 } } })
                else if (property.tag == .assignment_target_property_identifier or property.data.binary.right.isNone()) key else property.data.binary.right;
                if (self.ast.getNode(key).tag == .computed_property_key) try movePatternExpression(self, self.ast.getNode(key).data.unary.operand, context.source_scope orelse context.use_scope, context.use_scope);
                const scratch_top = self.scratch.items.len;
                const access = try emitObjectMemberAccessForRestWithPreparation(self, try patternTempRef(self, identity, context.use_scope, span, false), self.ast.getNode(key), key, &exclude, rest != null, .assign, span, .@"var", identity.owner_scope, preparation);
                for (scratch_top..self.scratch.items.len) |capture| try appendPatternExpression(self, out, self.scratch.items[capture], span);
                self.scratch.shrinkRetainingCapacity(scratch_top);
                try emitBindingPatternAt(self, target, access.member, span, context, preparation, out);
            }
            if (rest) |target| {
                self.runtime_helpers.rest = true;
                const parts = try buildRestCallWithPreparation(self, target, identity.span, exclude.items, span, identity, .retain);
                try emitBindingPatternAt(self, target, parts.call, span, context, preparation, out);
            }
        }

        fn lowerBindingPatternAssignmentWithPreparation(
            self: *Transformer,
            pattern: Node,
            rhs: NodeIndex,
            span: Span,
            producer_output_scope: ?@import("../semantic/scope.zig").ScopeId,
            comptime preparation: PatternPreparation,
        ) Transformer.Error!NodeIndex {
            const temp_identity = try reservePatternTemp(self, span, producer_output_scope);
            const temp_span = temp_identity.span;
            const scratch_top = self.scratch.items.len;
            defer self.scratch.shrinkRetainingCapacity(scratch_top);

            // _ref = rhs — 배열 패턴은 `__read` 로 배열을 만든다. 이터러블(Set·제너레이터)에
            // 인덱스·slice 를 바로 쓰면 틀린다 (#4791, 선언 경로와 같은 규칙).
            const init_lhs = try es_helpers.makeTempRefFromIdentity(self, temp_identity, span, .{ .write = true });
            const init_value = if (pattern.tag == .array_pattern) try buildArrayRead(self, rhs, pattern, span) else rhs;
            const init_assign = try es_helpers.makeAssignExpr(self, init_lhs, init_value, span, 0);
            try self.scratch.append(self.allocator, init_assign);

            if (pattern.tag == .object_pattern) {
                try emitObjectPatternAssignments(self, pattern, temp_span, span, temp_identity, preparation);
            } else if (pattern.tag == .array_pattern) {
                try emitArrayPatternAssignments(self, pattern, temp_span, span, temp_identity, preparation);
            }

            // 마지막에 _ref 노출 — destructuring assignment 의 평가 결과 (rhs) 와 일관
            try self.scratch.append(self.allocator, try makeDestructuringTempReadWithIdentity(self, temp_span, temp_identity));

            const seq_list = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
            return self.ast.addNode(.{
                .tag = .sequence_expression,
                .span = span,
                .data = .{ .list = seq_list },
            });
        }

        /// object_pattern 의 각 binding_property 를 `target = _ref.key` assignment 로 emit.
        /// emitObjectPatternDeclarators 와 같은 traversal — declarator 대신 assignment 를 만든다.
        fn emitObjectPatternAssignments(
            self: *Transformer,
            pattern: Node,
            ref_span: Span,
            span: Span,
            identity: es_helpers.TempIdentityCapture,
            comptime preparation: PatternPreparation,
        ) Transformer.Error!void {
            const opd_start = pattern.data.list.start;
            const split = self.ast.nodeListSplitRest(pattern.data.list);
            const non_rest_len: u32 = @intCast(split.elements.len);
            // rest 가 있으면 앞 속성들의 키를 제외 목록으로 모은다(계산된 키는 한 번만 평가).
            var exclude_keys: std.ArrayList(NodeIndex) = .empty;
            defer exclude_keys.deinit(self.allocator);
            var i_loop: u32 = 0;
            while (i_loop < non_rest_len) : (i_loop += 1) {
                const raw_idx = self.ast.extra_data.items[opd_start + i_loop];
                const prop = self.ast.getNode(@fromBackingInt(@intCast(raw_idx)));
                if (prop.tag != .binding_property) continue;

                const key_idx = prop.data.binary.left;
                const value_idx = prop.data.binary.right;
                if (key_idx.isNone()) continue;

                const ref = try makeDestructuringTempReadWithIdentity(self, ref_span, identity);
                const key_node = self.ast.getNode(key_idx);
                const access_result = try emitObjectMemberAccessForRestWithPreparation(
                    self,
                    ref,
                    key_node,
                    key_idx,
                    &exclude_keys,
                    split.rest_operand != null,
                    .assign,
                    span,
                    .@"var",
                    identity.owner_scope,
                    preparation,
                );
                const member_access = access_result.member;

                if (value_idx.isNone() or @backingInt(value_idx) == @backingInt(key_idx)) {
                    // shorthand: { x } → x = _ref.x
                    const target_ref = try makeTrackedBindingWriteRef(self, key_idx, key_node.data.string_ref);
                    const assign = try es_helpers.makeAssignExpr(self, target_ref, member_access, span, 0);
                    try self.scratch.append(self.allocator, assign);
                } else {
                    const value_node = self.ast.getNode(value_idx);
                    if (value_node.tag == .object_pattern or value_node.tag == .array_pattern) {
                        // nested: { a: { b } } → _inner = _ref.a, b = _inner.b
                        _ = try emitNestedPatternAssignment(self, value_node, member_access, span, identity.owner_scope, preparation);
                    } else if (value_node.tag == .assignment_pattern) {
                        // default: { a = 1 } 또는 { a: b = 1 } — _ref.key === void 0 ? default : _ref.key
                        const inner_target = value_node.data.binary.left;
                        const inner_target_node = self.ast.getNode(inner_target);
                        const default_val = try patternChild(self, value_node.data.binary.right, preparation);
                        const defaulted = try buildDefaulted(
                            self,
                            member_access,
                            default_val,
                            ref_span,
                            key_idx,
                            key_node.tag,
                            access_result.computed_key_temp_identity,
                            identity,
                            span,
                            null,
                        );
                        if (try emitNestedPatternAssignment(self, inner_target_node, defaulted, span, identity.owner_scope, preparation)) continue;
                        const target_ref = if (inner_target_node.tag == .binding_identifier)
                            try makeTrackedBindingWriteRef(self, inner_target, inner_target_node.data.string_ref)
                        else
                            try patternChild(self, inner_target, preparation);
                        try self.propagateSymbolId(inner_target, target_ref);
                        const assign = try es_helpers.makeAssignExpr(self, target_ref, defaulted, span, 0);
                        try self.scratch.append(self.allocator, assign);
                    } else {
                        // long-form: { a: b } → b = _ref.a
                        const target_ref = if (value_node.tag == .binding_identifier)
                            try makeTrackedBindingWriteRef(self, value_idx, value_node.data.string_ref)
                        else
                            try patternChild(self, value_idx, preparation);
                        try self.propagateSymbolId(value_idx, target_ref);
                        const assign = try es_helpers.makeAssignExpr(self, target_ref, member_access, span, 0);
                        try self.scratch.append(self.allocator, assign);
                    }
                }
            }
            // rest property: `rest = __rest(_ref, [앞 키들])` (#4750). 예전엔 무시해 rest 가
            // undefined 로 남았다 — 상태 기계가 `let {…, ...r} = v` 를 이 경로로 낮춘다.
            if (split.rest_operand) |rest_inner| {
                const parts = try buildRestCallWithPreparation(self, rest_inner, ref_span, exclude_keys.items, span, identity, preparation);
                const target = try restAssignTarget(self, rest_inner, parts.binding);
                try self.scratch.append(self.allocator, try es_helpers.makeAssignExpr(self, target, parts.call, span, 0));
                self.runtime_helpers.rest = true;
            }
        }

        /// rest 대입 좌변. 식별자는 **참조** 노드로 — 바인딩 노드를 좌변에 두면 minify 가
        /// 선언과 잇지 못한다(#4712).
        fn restAssignTarget(self: *Transformer, rest_inner: NodeIndex, visited: NodeIndex) Transformer.Error!NodeIndex {
            const vn = self.ast.getNode(visited);
            if (vn.tag != .binding_identifier) return visited;
            const target = try makeTrackedBindingWriteRef(self, rest_inner, vn.data.string_ref);
            return target;
        }

        /// 기본값이 붙은 대상이 다시 패턴이면(`{ b: [c] = d }`) 임시 변수에 담고 재귀로 푼다.
        /// 패턴을 대입 좌변에 그대로 두면 es5 에 구조분해 문법이 남고 minify 가 이름을 잇지
        /// 못한다 (#4712). 처리했으면 true.
        fn emitNestedPatternAssignment(self: *Transformer, target: Node, value: NodeIndex, span: Span, output_scope: @import("../semantic/scope.zig").ScopeId, comptime preparation: PatternPreparation) Transformer.Error!bool {
            if (target.tag != .object_pattern and target.tag != .array_pattern) return false;
            const inner_identity = try reservePatternTemp(self, span, output_scope);
            const inner_span = inner_identity.span;
            const inner_lhs = try es_helpers.makeTempRefFromIdentity(self, inner_identity, span, .{ .write = true });
            const inner_value = if (target.tag == .array_pattern) try buildArrayRead(self, value, target, span) else value;
            try self.scratch.append(self.allocator, try es_helpers.makeAssignExpr(self, inner_lhs, inner_value, span, 0));
            if (target.tag == .object_pattern) {
                try emitObjectPatternAssignments(self, target, inner_span, span, inner_identity, preparation);
            } else {
                try emitArrayPatternAssignments(self, target, inner_span, span, inner_identity, preparation);
            }
            return true;
        }

        /// array_pattern 의 각 element 를 `target = _ref[idx]` assignment 로 emit.
        fn emitArrayPatternAssignments(
            self: *Transformer,
            pattern: Node,
            ref_span: Span,
            span: Span,
            identity: es_helpers.TempIdentityCapture,
            comptime preparation: PatternPreparation,
        ) Transformer.Error!void {
            const apd_start = pattern.data.list.start;
            const split = self.ast.nodeListSplitRest(pattern.data.list);
            const non_rest_len: u32 = @intCast(split.elements.len);
            var idx: u32 = 0;
            while (idx < non_rest_len) : (idx += 1) {
                const raw_idx = self.ast.extra_data.items[apd_start + idx];
                const elem = self.ast.getNode(@fromBackingInt(@intCast(raw_idx)));
                if (elem.tag == .elision) continue;

                const elem_access = try makeArrayAccess(self, ref_span, idx, span, identity);

                if (elem.tag == .assignment_pattern) {
                    const inner_target = elem.data.binary.left;
                    const inner_target_node = self.ast.getNode(inner_target);
                    const default_val = try patternChild(self, elem.data.binary.right, preparation);
                    const void_zero = try es_helpers.makeVoidZero(self, span);
                    const elem_access2 = try makeArrayAccess(self, ref_span, idx, span, identity);
                    const eq_check = try self.ast.addNode(.{
                        .tag = .binary_expression,
                        .span = span,
                        .data = .{ .binary = .{ .left = elem_access, .right = void_zero, .flags = @backingInt(token_mod.Kind.eq3) } },
                    });
                    const conditional = try self.ast.addNode(.{
                        .tag = .conditional_expression,
                        .span = span,
                        .data = .{ .ternary = .{ .a = eq_check, .b = default_val, .c = elem_access2 } },
                    });
                    if (try emitNestedPatternAssignment(self, inner_target_node, conditional, span, identity.owner_scope, preparation)) continue;
                    const target_ref = if (inner_target_node.tag == .binding_identifier)
                        try makeTrackedBindingWriteRef(self, inner_target, inner_target_node.data.string_ref)
                    else
                        try patternChild(self, inner_target, preparation);
                    try self.propagateSymbolId(inner_target, target_ref);
                    const assign = try es_helpers.makeAssignExpr(self, target_ref, conditional, span, 0);
                    try self.scratch.append(self.allocator, assign);
                } else if (elem.tag == .object_pattern or elem.tag == .array_pattern) {
                    _ = try emitNestedPatternAssignment(self, elem, elem_access, span, identity.owner_scope, preparation);
                } else {
                    const target_ref = if (elem.tag == .binding_identifier)
                        try makeTrackedBindingWriteRef(self, @fromBackingInt(@intCast(raw_idx)), elem.data.string_ref)
                    else
                        try patternChild(self, @fromBackingInt(@intCast(raw_idx)), preparation);
                    try self.propagateSymbolId(@fromBackingInt(@intCast(raw_idx)), target_ref);
                    const assign = try es_helpers.makeAssignExpr(self, target_ref, elem_access, span, 0);
                    try self.scratch.append(self.allocator, assign);
                }
            }
            // rest element: `rest = _ref.slice(N)` (#4750). 패턴이면 재귀로 푼다.
            if (split.rest_operand) |rest_inner| {
                const slice = try buildArraySlice(self, ref_span, non_rest_len, span, identity);
                const rest_node = self.ast.getNode(rest_inner);
                if (try emitNestedPatternAssignment(self, rest_node, slice, span, identity.owner_scope, preparation)) return;
                const target = if (rest_node.tag == .binding_identifier)
                    try restAssignTarget(self, rest_inner, try patternChild(self, rest_inner, preparation))
                else
                    try patternChild(self, rest_inner, preparation);
                try self.scratch.append(self.allocator, try es_helpers.makeAssignExpr(self, target, slice, span, 0));
            }
        }

        /// assignment destructuring을 sequence expression으로 변환.
        /// ({a, b} = obj) → (_ref = obj, a = _ref.a, b = _ref.b, _ref)
        /// `value_used`: the assignment's value is read (not a discarded
        /// expression statement).
        pub fn lowerDestructuringAssignment(self: *Transformer, node: Node, value_used: bool) Transformer.Error!NodeIndex {
            return lowerDestructuringAssignmentWithRight(self, node, try self.visitNode(node.data.binary.right), value_used);
        }

        /// `new_right` is the right side already in the output AST (a state
        /// machine replaced its `yield`s, #5728).
        pub fn lowerDestructuringAssignmentWithRight(self: *Transformer, node: Node, new_right: NodeIndex, value_used: bool) Transformer.Error!NodeIndex {
            return lowerDestructuringAssignmentWithRightInOutputScope(self, node, new_right, value_used, null);
        }

        pub fn lowerDestructuringAssignmentWithRightInOutputScope(self: *Transformer, node: Node, new_right: NodeIndex, value_used: bool, output_scope: ?@import("../semantic/scope.zig").ScopeId) Transformer.Error!NodeIndex {
            const span = node.span;
            const left_idx = node.data.binary.left;

            const left_node = self.ast.getNode(left_idx);
            const scratch_top = self.scratch.items.len;
            defer self.scratch.shrinkRetainingCapacity(scratch_top);

            // An array pattern reads a `__read` copy, but the assignment's value
            // is the right side itself (`([a] = arr) === arr`): keep it in a
            // temp when the value is read (#4799).
            const is_array = left_node.tag == .array_assignment_target or left_node.tag == .array_pattern;
            const value_temp: ?es_helpers.TempCapture = if (is_array and value_used) blk: {
                if (output_scope == null) break :blk try es_helpers.captureToTrackedTemp(self, new_right, span);
                const identity = try reservePatternTemp(self, span, output_scope);
                const counter = self.temp_var_counter - 1;
                const write = try es_helpers.makeTempRefFromIdentity(self, identity, span, .{ .write = true });
                break :blk .{
                    .span = identity.span,
                    .paren_assign = try es_helpers.makeAssignExpr(self, write, new_right, span, 0),
                    .symbol_id = identity.symbol_id,
                    .reference_scope = identity.reference_scope,
                    .temp_counter_index = counter,
                    .temp_producer_id = identity.temp_producer_id,
                };
            } else null;
            const array_source = if (value_temp) |temp| temp.paren_assign else new_right;
            const assignment_right = if (is_array)
                try buildArrayRead(self, array_source, left_node, span)
            else
                new_right;
            const temp_identity = try reservePatternTemp(self, span, output_scope);
            const temp_span = temp_identity.span;

            // _ref = obj
            const temp_ref = try es_helpers.makeTempRefFromIdentity(self, temp_identity, span, .{ .write = true });
            const init_assign = try self.ast.addNode(.{
                .tag = .assignment_expression,
                .span = span,
                .data = .{ .binary = .{ .left = temp_ref, .right = assignment_right, .flags = 0 } },
            });
            try self.scratch.append(self.allocator, init_assign);

            // 각 property/element를 assignment로 변환
            if (left_node.tag == .object_assignment_target) {
                try emitObjectAssignments(self, left_node, temp_span, span, temp_identity);
            } else if (left_node.tag == .array_assignment_target) {
                try emitArrayAssignments(self, left_node, temp_span, span, temp_identity);
            }

            // 마지막에 _ref 반환 (array pattern 의 값은 원래 우변)
            try self.scratch.append(self.allocator, if (value_temp) |temp| blk: {
                // The capture already owns the exact identity. Drop the
                // span index before creating this final read so the known
                // owner cannot silently fall back to name/span lookup.
                if (temp.symbol_id != null)
                    self.forgetSyntheticTempSymbolLookup(temp.span, temp.reference_scope);
                break :blk try es_helpers.makeCapturedTempRef(self, temp, span, .{ .read = true });
            } else try makeDestructuringTempReadWithIdentity(self, temp_span, temp_identity));

            // sequence expression
            const seq_list = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
            return self.ast.addNode(.{
                .tag = .sequence_expression,
                .span = span,
                .data = .{ .list = seq_list },
            });
        }

        /// object_assignment_target의 각 property를 assignment로 변환.
        fn emitObjectAssignments(
            self: *Transformer,
            target: Node,
            ref_span: Span,
            span: Span,
            identity: es_helpers.TempIdentityCapture,
        ) Transformer.Error!void {
            const oa_start = target.data.list.start;
            const split = self.ast.nodeListSplitRest(target.data.list);
            const non_rest_len: u32 = @intCast(split.elements.len);
            var exclude_keys: std.ArrayList(NodeIndex) = .empty;
            defer exclude_keys.deinit(self.allocator);
            // visitNode가 AST를 변형하므로 인덱스 루프 사용
            var i_loop: u32 = 0;
            while (i_loop < non_rest_len) : (i_loop += 1) {
                const raw_idx = self.ast.extra_data.items[oa_start + i_loop];
                const prop = self.ast.getNode(@fromBackingInt(@intCast(raw_idx)));

                const key_idx = prop.data.binary.left;
                if (key_idx.isNone()) continue;

                const ref = try makeDestructuringTempReadWithIdentity(self, ref_span, identity);
                const key_node = self.ast.getNode(key_idx);
                const access_result = try emitObjectMemberAccessForRest(
                    self,
                    ref,
                    key_node,
                    key_idx,
                    &exclude_keys,
                    split.rest_operand != null,
                    .assign,
                    span,
                    .@"var",
                    identity.owner_scope,
                );
                const access = access_result.member;

                if (prop.tag == .assignment_target_property_identifier) {
                    // 새로 만든 노드는 symbol_ids 밖이라 심볼을 안 물려주면 mangler rename 이
                    // 통째로 스킵된다 — `({o: {s, w = 1}} = box)` 가 es5 로 낮아질 때
                    // 원본 이름으로 대입돼 미선언 전역이 된다 (#4493 의 es5 표면).
                    const target_name = if (self.renamedNameOf(key_idx)) |renamed|
                        try self.ast.addString(renamed)
                    else
                        key_node.data.string_ref;
                    // shorthand_with_default: {a = 1} → a = _ref.a === void 0 ? 1 : _ref.a
                    // flags bit 0 = shorthand_with_default, right = default value
                    const is_shorthand_default = (prop.data.binary.flags & 0x01) != 0;
                    const rhs = if (is_shorthand_default and !prop.data.binary.right.isNone()) blk: {
                        const default_val = try self.visitNode(prop.data.binary.right);
                        break :blk try buildDefaulted(
                            self,
                            access,
                            default_val,
                            ref_span,
                            key_idx,
                            key_node.tag,
                            access_result.computed_key_temp_identity,
                            identity,
                            span,
                            null,
                        );
                    } else access;
                    if (comptime @hasDecl(Transformer, "patternPutValue")) {
                        if (try self.patternPutValue(key_idx, rhs, self.current_scope)) |checked| {
                            try self.scratch.append(self.allocator, checked);
                            continue;
                        }
                    }
                    const target_node = try makeTrackedBindingWriteRefAt(self, key_idx, target_name, key_node.span);

                    const assign = try self.ast.addNode(.{
                        .tag = .assignment_expression,
                        .span = span,
                        .data = .{ .binary = .{ .left = target_node, .right = rhs, .flags = 0 } },
                    });
                    try self.scratch.append(self.allocator, assign);
                } else {
                    // long-form {a: b} 또는 {a: b = 1}
                    const right_idx = prop.data.binary.right;
                    const right_node = self.ast.getNode(right_idx);

                    if (right_node.tag == .assignment_target_with_default) {
                        const default_val = try self.visitNode(right_node.data.binary.right);
                        const rhs = try buildDefaulted(
                            self,
                            access,
                            default_val,
                            ref_span,
                            key_idx,
                            key_node.tag,
                            access_result.computed_key_temp_identity,
                            identity,
                            span,
                            null,
                        );
                        try emitTargetAssignOrRecurse(self, right_node.data.binary.left, rhs, span, identity.owner_scope);
                    } else {
                        try emitTargetAssignOrRecurse(self, right_idx, access, span, identity.owner_scope);
                    }
                }
            }

            if (split.rest_operand) |rest_inner| {
                const rest_assign = try buildRestAssignment(self, rest_inner, ref_span, exclude_keys.items, span, identity);
                try self.scratch.append(self.allocator, rest_assign);
                self.runtime_helpers.rest = true;
            }
        }

        /// array_assignment_target의 각 element를 assignment로 변환.
        fn emitArrayAssignments(
            self: *Transformer,
            target: Node,
            ref_span: Span,
            span: Span,
            identity: es_helpers.TempIdentityCapture,
        ) Transformer.Error!void {
            const aa_start = target.data.list.start;
            const split = self.ast.nodeListSplitRest(target.data.list);
            const non_rest_len: u32 = @intCast(split.elements.len);
            // visitNode가 AST를 변형하므로 인덱스 루프 사용
            var idx: u32 = 0;
            while (idx < non_rest_len) : (idx += 1) {
                const raw_idx = self.ast.extra_data.items[aa_start + idx];
                const elem = self.ast.getNode(@fromBackingInt(@intCast(raw_idx)));
                if (elem.tag == .elision) continue;

                // _ref[idx]
                const access = try makeArrayAccess(self, ref_span, idx, span, identity);

                if (elem.tag == .assignment_target_with_default) {
                    // [x = 1] → x = _ref[0] === void 0 ? 1 : _ref[0]
                    const default_val = try self.visitNode(elem.data.binary.right);
                    const void_zero = try es_helpers.makeVoidZero(self, span);
                    const eq_check = try self.ast.addNode(.{
                        .tag = .binary_expression,
                        .span = span,
                        .data = .{ .binary = .{ .left = access, .right = void_zero, .flags = @backingInt(token_mod.Kind.eq3) } },
                    });
                    // _ref[idx] 다시 생성 (access는 eq_check에서 소비)
                    const access2 = try makeArrayAccess(self, ref_span, idx, span, identity);
                    const conditional = try self.ast.addNode(.{
                        .tag = .conditional_expression,
                        .span = span,
                        .data = .{ .ternary = .{ .a = eq_check, .b = default_val, .c = access2 } },
                    });
                    try emitTargetAssignOrRecurse(self, elem.data.binary.left, conditional, span, identity.owner_scope);
                } else {
                    // target = _ref[idx]. nested destructuring, private field, 일반 assignment 분기.
                    try emitTargetAssignOrRecurse(self, @fromBackingInt(@intCast(raw_idx)), access, span, identity.owner_scope);
                }
            }
            // rest element: `rest = _ref.slice(N)` (#4789). `_ref` 는 `__read` 로 만든 배열이라
            // 이터러블이어도 slice 가 있다. 좌변이 패턴·멤버·private 이면 같은 분기로 간다.
            if (split.rest_operand) |rest_inner| {
                const slice = try buildArraySlice(self, ref_span, non_rest_len, span, identity);
                try emitTargetAssignOrRecurse(self, rest_inner, slice, span, identity.owner_scope);
            }
        }

        /// target(old AST)에 value(new AST)를 배정. target 종류에 따라 분기:
        ///   - private_field_expression → `__classPrivateFieldSet(...)` (#1485).
        ///   - object/array_assignment_target → 임시 변수 + 재귀 emit (nested destructuring).
        ///   - 나머지 (identifier, member expr 등) → 일반 `target = value` assignment.
        /// 생성된 표현식은 self.scratch 에 push된다 (lowerDestructuringAssignment 패턴 유지).
        fn emitTargetAssignOrRecurse(self: *Transformer, target_old_idx: NodeIndex, value: NodeIndex, span: Span, output_scope: @import("../semantic/scope.zig").ScopeId) Transformer.Error!void {
            if (try es2015_class.ES2015Class(Transformer).tryLowerPrivateFieldAssign(self, target_old_idx, value, span)) |call| {
                try self.scratch.append(self.allocator, call);
                return;
            }
            // #4244: super member target (`[super.x] = …`, `({a: super.x} = o)`) →
            // __superSet write helper. generic `visitNode(target)=value` 는 super.x 를
            // READ(`__superGet`)로 내려 `__superGet(...)=v` (Invalid LHS) 를 만든다.
            if (try es2015_class.ES2015Class(Transformer).trySuperAssignTarget(self, target_old_idx, value, span)) |super_set| {
                try self.scratch.append(self.allocator, super_set);
                return;
            }
            const target_node = self.ast.getNode(target_old_idx);
            if (target_node.tag == .object_assignment_target or target_node.tag == .array_assignment_target or target_node.tag == .object_pattern or target_node.tag == .array_pattern) {
                // nested: _inner = value; 각 element 재귀 emit.
                const inner_identity = try reservePatternTemp(self, span, output_scope);
                const inner_span = inner_identity.span;
                const inner_lhs = try es_helpers.makeTempRefFromIdentity(self, inner_identity, span, .{ .write = true });
                const inner_value = if (target_node.tag == .array_assignment_target or target_node.tag == .array_pattern)
                    try buildArrayRead(self, value, target_node, span)
                else
                    value;
                const init = try self.ast.addNode(.{
                    .tag = .assignment_expression,
                    .span = span,
                    .data = .{ .binary = .{ .left = inner_lhs, .right = inner_value, .flags = 0 } },
                });
                try self.scratch.append(self.allocator, init);
                if (target_node.tag == .object_assignment_target or target_node.tag == .object_pattern) {
                    try emitObjectAssignments(self, target_node, inner_span, span, inner_identity);
                } else {
                    try emitArrayAssignments(self, target_node, inner_span, span, inner_identity);
                }
                return;
            }
            if (target_node.tag == .assignment_target_identifier or target_node.tag == .identifier_reference) {
                if (comptime @hasDecl(Transformer, "patternPutValue")) {
                    if (try self.patternPutValue(target_old_idx, value, self.current_scope)) |checked| {
                        try self.scratch.append(self.allocator, checked);
                        return;
                    }
                }
            }
            const visited_target = switch (target_node.tag) {
                .identifier_reference, .assignment_target_identifier, .binding_identifier => try makeTrackedBindingWriteRef(self, target_old_idx, target_node.data.string_ref),
                else => try self.visitNode(target_old_idx),
            };
            const assign = try self.ast.addNode(.{
                .tag = .assignment_expression,
                .span = span,
                .data = .{ .binary = .{ .left = visited_target, .right = value, .flags = 0 } },
            });
            try self.scratch.append(self.allocator, assign);
        }

        /// Parameter lowering has already reserved the root temp's exact
        /// identity. Keep that handle attached through every generated read.
        pub fn emitPatternDeclaratorsWithIdentity(
            self: *Transformer,
            pattern: Node,
            identity: es_helpers.TempIdentityCapture,
            span: Span,
            decl_kind: ast_mod.VariableDeclarationKind,
        ) Transformer.Error!void {
            if (self.semantic_edit_enabled and !self.current_scope.isNone()) {
                const symbol_id = identity.symbol_id orelse
                    std.debug.panic("known-owner destructuring pattern has no producer SymbolId", .{});
                if (symbol_id.isNone() or identity.reference_scope.isNone())
                    std.debug.panic("known-owner destructuring pattern has an invalid producer identity", .{});
            }
            return emitPatternDeclaratorsInternal(self, pattern, identity.span, span, decl_kind, identity);
        }

        fn emitPatternDeclaratorsInternal(
            self: *Transformer,
            pattern: Node,
            ref_span: Span,
            span: Span,
            decl_kind: ast_mod.VariableDeclarationKind,
            identity: es_helpers.TempIdentityCapture,
        ) Transformer.Error!void {
            if (pattern.tag == .object_pattern) {
                try emitObjectPatternDeclarators(self, pattern, ref_span, span, decl_kind, identity);
            } else if (pattern.tag == .array_pattern) {
                try emitArrayPatternDeclarators(self, pattern, ref_span, span, decl_kind, identity);
            }
        }

        /// object_pattern의 각 property를 declarator로 변환.
        /// { a, b: c, d = 1 } → var a = _ref.a, c = _ref.b, d = _ref.d === void 0 ? 1 : _ref.d
        /// { a, ...rest } → var a = _ref.a, rest = __rest(_ref, ["a"])
        fn emitObjectPatternDeclarators(self: *Transformer, pattern: Node, ref_span: Span, span: Span, decl_kind: ast_mod.VariableDeclarationKind, root_identity: es_helpers.TempIdentityCapture) Transformer.Error!void {
            const opd_start = pattern.data.list.start;
            const split = self.ast.nodeListSplitRest(pattern.data.list);

            var exclude_keys: std.ArrayList(NodeIndex) = .empty;
            defer exclude_keys.deinit(self.allocator);

            // 각 property를 declarator로 변환하면서 rest exclude key도 같은 평가 결과로 수집한다.
            // visitNode가 AST를 변형하므로 인덱스 루프 사용 (split.elements 슬라이스는 stale 가능)
            const non_rest_len: u32 = @intCast(split.elements.len);
            var i_loop: u32 = 0;
            while (i_loop < non_rest_len) : (i_loop += 1) {
                const raw_idx = self.ast.extra_data.items[opd_start + i_loop];
                const prop = self.ast.getNode(@fromBackingInt(@intCast(raw_idx)));

                if (prop.tag != .binding_property) continue;

                const key_idx = prop.data.binary.left;
                const value_idx = prop.data.binary.right;

                const ref = try makeDestructuringTempReadWithIdentity(self, ref_span, root_identity);
                const key_node = self.ast.getNode(key_idx);

                const access_result = try emitObjectMemberAccessForRest(
                    self,
                    ref,
                    key_node,
                    key_idx,
                    &exclude_keys,
                    split.rest_operand != null,
                    .decl,
                    span,
                    decl_kind,
                    .none,
                );
                const member_access = access_result.member;

                // value 처리: shorthand vs long-form, default value
                if (value_idx.isNone() or @backingInt(value_idx) == @backingInt(key_idx)) {
                    // shorthand: { a } → var a = _ref.a
                    // block scoping rename이 필요한 경우 이름 교체.
                    // 파서가 만든 식별자는 span 과 string_ref 가 같아 이름 span 을 노드 위치로 쓴다.
                    var binding_name = key_node.data.string_ref;
                    if (self.options.unsupported.block_scoping) {
                        if (self.renamedNameOf(key_idx)) |new_name| {
                            binding_name = try self.ast.addString(new_name);
                        }
                    }
                    const binding = try self.makeUserBinding(binding_name, key_idx);
                    const decl = try es_helpers.makeDeclarator(self, binding, member_access, span);
                    try self.scratch.append(self.allocator, decl);
                } else {
                    const value_node = self.ast.getNode(value_idx);
                    if (value_node.tag == .assignment_pattern) {
                        const left_node = self.ast.getNode(value_node.data.binary.left);
                        if (left_node.tag == .object_pattern or left_node.tag == .array_pattern) {
                            // (#3979) default 가 있는 *중첩* 패턴: { a: { c = 2 } = {} }
                            //   → var _ref2 = _ref.a === void 0 ? {} : _ref.a; var c = _ref2.c ...
                            // left 가 패턴이면 visitNode 로 verbatim 방출(invalid ES5)하지 말고
                            // defaulted 값을 임시변수에 담아 재귀(non-default 중첩 분기와 동일 lowering).
                            const default_val = try self.visitNode(value_node.data.binary.right);
                            try rewritePatternDefaultTDZ(self, default_val, pattern, i_loop);
                            const defaulted = try buildDefaulted(
                                self,
                                member_access,
                                default_val,
                                ref_span,
                                key_idx,
                                key_node.tag,
                                access_result.computed_key_temp_identity,
                                root_identity,
                                span,
                                decl_kind,
                            );
                            const nested_span = try es_helpers.makeTempVarSpan(self);
                            const nested_temp = try makeDestructuringTempBinding(self, nested_span, decl_kind);
                            const nested_init = if (left_node.tag == .array_pattern)
                                try buildArrayRead(self, defaulted, left_node, span)
                            else
                                defaulted;
                            const nested_decl = try es_helpers.makeDeclarator(self, nested_temp.binding, nested_init, span);
                            try self.scratch.append(self.allocator, nested_decl);
                            try emitPatternDeclaratorsWithIdentity(self, left_node, nested_temp.identity, span, decl_kind);
                            try bindPatternTemp(self, nested_temp.binding, nested_span, span, decl_kind, nested_temp.identity);
                        } else {
                            // default: { a = 1 } → var a = _ref.a === void 0 ? 1 : _ref.a
                            const binding = try self.visitNode(value_node.data.binary.left);
                            const default_val = try self.visitNode(value_node.data.binary.right);
                            try rewritePatternDefaultTDZ(self, default_val, pattern, i_loop);
                            if (!self.options.unsupported.destructuring) {
                                // Native object binding captures GetV once without
                                // adding a compiler lexical name visible to eval.
                                try self.scratch.append(self.allocator, try makeNativeDefaultDeclarator(self, binding, member_access, default_val, span));
                                continue;
                            }
                            const defaulted = try buildDefaulted(
                                self,
                                member_access,
                                default_val,
                                ref_span,
                                key_idx,
                                key_node.tag,
                                access_result.computed_key_temp_identity,
                                root_identity,
                                span,
                                decl_kind,
                            );
                            const decl = try es_helpers.makeDeclarator(self, binding, defaulted, span);
                            try self.scratch.append(self.allocator, decl);
                        }
                    } else if (value_node.tag == .object_pattern or value_node.tag == .array_pattern) {
                        // nested: { a: { b } } → var _ref2 = _ref.a; var b = _ref2.b
                        const nested_span = try es_helpers.makeTempVarSpan(self);
                        const nested_temp = try makeDestructuringTempBinding(self, nested_span, decl_kind);
                        const nested_init = if (value_node.tag == .array_pattern)
                            try buildArrayRead(self, member_access, value_node, span)
                        else
                            member_access;
                        const nested_decl = try es_helpers.makeDeclarator(self, nested_temp.binding, nested_init, span);
                        try self.scratch.append(self.allocator, nested_decl);
                        try emitPatternDeclaratorsWithIdentity(self, value_node, nested_temp.identity, span, decl_kind);
                        try bindPatternTemp(self, nested_temp.binding, nested_span, span, decl_kind, nested_temp.identity);
                    } else {
                        // long-form: { a: b } → var b = _ref.a
                        const binding = try self.visitNode(value_idx);
                        const decl = try es_helpers.makeDeclarator(self, binding, member_access, span);
                        try self.scratch.append(self.allocator, decl);
                    }
                }
            }

            // rest: var rest = __rest(_ref, ["a", "b"])
            if (split.rest_operand) |rest_inner| {
                const rest_decl = try buildRestDeclarator(self, rest_inner, ref_span, exclude_keys.items, span, root_identity);
                try self.scratch.append(self.allocator, rest_decl);
                self.runtime_helpers.rest = true;
            }
        }

        /// array_pattern의 각 요소를 declarator로 변환.
        /// [x, y] → var x = _ref[0], y = _ref[1]
        fn emitArrayPatternDeclarators(self: *Transformer, pattern: Node, ref_span: Span, span: Span, decl_kind: ast_mod.VariableDeclarationKind, root_identity: es_helpers.TempIdentityCapture) Transformer.Error!void {
            const apd_start = pattern.data.list.start;
            const split = self.ast.nodeListSplitRest(pattern.data.list);
            const non_rest_len: u32 = @intCast(split.elements.len);

            // visitNode가 AST를 변형하므로 인덱스 루프 사용
            var idx: u32 = 0;
            while (idx < non_rest_len) : (idx += 1) {
                const raw_idx = self.ast.extra_data.items[apd_start + idx];
                const elem = self.ast.getNode(@fromBackingInt(@intCast(raw_idx)));

                if (elem.tag == .elision) continue; // 빈 슬롯 스킵

                // _ref[idx]
                const elem_access = try makeArrayAccess(self, ref_span, idx, span, root_identity);

                if (elem.tag == .assignment_pattern) {
                    const left_node = self.ast.getNode(elem.data.binary.left);
                    if (left_node.tag == .object_pattern or left_node.tag == .array_pattern) {
                        // (#3979) default 가 있는 *중첩* 패턴: [ { a = 1 } = {} ] / [ [c=2] = [] ]
                        // left 가 패턴이면 verbatim 방출(invalid ES5)하지 말고 defaulted 값을
                        // 임시변수에 담아 재귀(non-default 중첩 분기와 동일 lowering).
                        const default_val = try self.visitNode(elem.data.binary.right);
                        try rewritePatternDefaultTDZ(self, default_val, pattern, idx);
                        const void_zero = try es_helpers.makeVoidZero(self, span);
                        const elem_access2 = try makeArrayAccess(self, ref_span, idx, span, root_identity);
                        const eq_check = try self.ast.addNode(.{
                            .tag = .binary_expression,
                            .span = span,
                            .data = .{ .binary = .{ .left = elem_access, .right = void_zero, .flags = @backingInt(token_mod.Kind.eq3) } },
                        });
                        const conditional = try self.ast.addNode(.{
                            .tag = .conditional_expression,
                            .span = span,
                            .data = .{ .ternary = .{ .a = eq_check, .b = default_val, .c = elem_access2 } },
                        });
                        const nested_span = try es_helpers.makeTempVarSpan(self);
                        const nested_temp = try makeDestructuringTempBinding(self, nested_span, decl_kind);
                        const nested_init = if (left_node.tag == .array_pattern)
                            try buildArrayRead(self, conditional, left_node, span)
                        else
                            conditional;
                        const nested_decl = try es_helpers.makeDeclarator(self, nested_temp.binding, nested_init, span);
                        try self.scratch.append(self.allocator, nested_decl);
                        try emitPatternDeclaratorsWithIdentity(self, left_node, nested_temp.identity, span, decl_kind);
                        try bindPatternTemp(self, nested_temp.binding, nested_span, span, decl_kind, nested_temp.identity);
                    } else {
                        // default: [x = 1] → var x = _ref[0] === void 0 ? 1 : _ref[0]
                        const binding = try self.visitNode(elem.data.binary.left);
                        const default_val = try self.visitNode(elem.data.binary.right);
                        try rewritePatternDefaultTDZ(self, default_val, pattern, idx);
                        const void_zero = try es_helpers.makeVoidZero(self, span);
                        const elem_access2 = try makeArrayAccess(self, ref_span, idx, span, root_identity);
                        const eq_check = try self.ast.addNode(.{
                            .tag = .binary_expression,
                            .span = span,
                            .data = .{ .binary = .{ .left = elem_access, .right = void_zero, .flags = @backingInt(token_mod.Kind.eq3) } },
                        });
                        const conditional = try self.ast.addNode(.{
                            .tag = .conditional_expression,
                            .span = span,
                            .data = .{ .ternary = .{ .a = eq_check, .b = default_val, .c = elem_access2 } },
                        });
                        const decl = try es_helpers.makeDeclarator(self, binding, conditional, span);
                        try self.scratch.append(self.allocator, decl);
                    }
                } else if (elem.tag == .object_pattern or elem.tag == .array_pattern) {
                    // nested: [[a, b]] → var _ref2 = _ref[0]; var a = _ref2[0]; ...
                    const nested_span = try es_helpers.makeTempVarSpan(self);
                    const nested_temp = try makeDestructuringTempBinding(self, nested_span, decl_kind);
                    const nested_init = if (elem.tag == .array_pattern)
                        try buildArrayRead(self, elem_access, elem, span)
                    else
                        elem_access;
                    const nested_decl = try es_helpers.makeDeclarator(self, nested_temp.binding, nested_init, span);
                    try self.scratch.append(self.allocator, nested_decl);
                    try emitPatternDeclaratorsWithIdentity(self, elem, nested_temp.identity, span, decl_kind);
                    try bindPatternTemp(self, nested_temp.binding, nested_span, span, decl_kind, nested_temp.identity);
                } else {
                    // 단순: [x] → var x = _ref[0]
                    const binding = try self.visitNode(@fromBackingInt(@intCast(raw_idx)));
                    const decl = try es_helpers.makeDeclarator(self, binding, elem_access, span);
                    try self.scratch.append(self.allocator, decl);
                }
            }

            // ...rest → var rest = _ref.slice(N)
            if (split.rest_operand) |rest_inner| {
                const rest_init = try buildArraySlice(self, ref_span, non_rest_len, span, root_identity);
                const rest_node = self.ast.getNode(rest_inner);
                if (rest_node.tag == .object_pattern or rest_node.tag == .array_pattern) {
                    // `[a, ...[b, c]]` — 패턴을 그대로 두면 es5 에 구조 분해 문법이 남는다 (#4791).
                    // slice 결과는 이미 배열이라 `__read` 없이 임시 변수에 받아 재귀한다.
                    const nested_span = try es_helpers.makeTempVarSpan(self);
                    const nested_temp = try makeDestructuringTempBinding(self, nested_span, decl_kind);
                    try self.scratch.append(self.allocator, try es_helpers.makeDeclarator(self, nested_temp.binding, rest_init, span));
                    try emitPatternDeclaratorsWithIdentity(self, rest_node, nested_temp.identity, span, decl_kind);
                    try bindPatternTemp(self, nested_temp.binding, nested_span, span, decl_kind, nested_temp.identity);
                    return;
                }
                const rest_binding = try self.visitNode(rest_inner);
                const rest_decl = try es_helpers.makeDeclarator(self, rest_binding, rest_init, span);
                try self.scratch.append(self.allocator, rest_decl);
            }
        }

        /// _ref.key === void 0 ? default : _ref.key (또는 _ref["key"])
        /// The one-use own-data wrapper has no user hooks. Its value is the
        /// already selected property access, and native binding initialization
        /// applies the actual source default without a new lexical temporary.
        fn makeNativeDefaultDeclarator(self: *Transformer, binding: NodeIndex, access: NodeIndex, fallback: NodeIndex, span: Span) Transformer.Error!NodeIndex {
            const key = try es_helpers.makePropertyName(self, "value");
            const default = try self.ast.addNode(.{ .tag = .assignment_pattern, .span = span, .data = .{ .binary = .{ .left = binding, .right = fallback, .flags = 0 } } });
            const property = try self.ast.addNode(.{ .tag = .binding_property, .span = span, .data = .{ .binary = .{ .left = key, .right = default, .flags = 0 } } });
            const pattern = try self.ast.addNode(.{ .tag = .object_pattern, .span = span, .data = .{ .list = try self.ast.addNodeList(&.{property}) } });
            const value_key = try es_helpers.makePropertyName(self, "value");
            const value = try self.ast.addNode(.{ .tag = .object_property, .span = span, .data = .{ .binary = .{ .left = value_key, .right = access, .flags = 0 } } });
            const object = try self.ast.addNode(.{ .tag = .object_expression, .span = span, .data = .{ .list = try self.ast.addNodeList(&.{value}) } });
            return es_helpers.makeDeclarator(self, pattern, object, span);
        }

        fn buildDefaulted(
            self: *Transformer,
            access: NodeIndex,
            default_val: NodeIndex,
            ref_span: Span,
            key_idx: NodeIndex,
            key_tag: Node.Tag,
            computed_key_temp_identity: ?es_helpers.TempIdentityCapture,
            root_identity: es_helpers.TempIdentityCapture,
            span: Span,
            declaration_kind: ?ast_mod.VariableDeclarationKind,
        ) Transformer.Error!NodeIndex {
            _ = ref_span;
            _ = key_idx;
            if (key_tag == .computed_property_key and computed_key_temp_identity == null)
                @panic("computed destructuring default lost its captured property key");
            // GetV happens exactly once. A getter can change state or throw;
            // the conditional's defined branch must reuse that same value.
            // Declaration consumers (including Pass 2 parameter prologues)
            // already own a physical declarator list. Capture GetV there;
            // leaving a late counter slot would hoist a function-owned temp
            // into the program after parameter lowering has finished.
            var value: es_helpers.TempIdentityCapture = undefined;
            const captured = if (declaration_kind) |kind| capture: {
                const name = try es_helpers.makeTempVarSpan(self);
                const temp = try makeDestructuringTempBinding(self, name, kind);
                try self.scratch.append(self.allocator, try es_helpers.makeDeclarator(self, temp.binding, access, span));
                try bindPatternTemp(self, temp.binding, name, span, kind, temp.identity);
                value = temp.identity;
                break :capture try makeDestructuringTempReadWithIdentity(self, name, value);
            } else capture: {
                value = try reservePatternTemp(self, span, root_identity.owner_scope);
                break :capture try es_helpers.makeAssignExpr(self, try patternTempRef(self, value, self.current_scope, span, true), access, span, 0);
            };
            const eq_check = try self.ast.addNode(.{
                .tag = .binary_expression,
                .span = span,
                .data = .{ .binary = .{ .left = captured, .right = try es_helpers.makeVoidZero(self, span), .flags = @backingInt(token_mod.Kind.eq3) } },
            });
            return self.ast.addNode(.{
                .tag = .conditional_expression,
                .span = span,
                .data = .{ .ternary = .{ .a = eq_check, .b = default_val, .c = try patternTempRef(self, value, self.current_scope, span, false) } },
            });
        }

        /// _ref[idx] computed member expression 생성 (배열 인덱스 접근).
        fn makeArrayAccess(self: *Transformer, ref_span: Span, idx: usize, span: Span, identity: es_helpers.TempIdentityCapture) Transformer.Error!NodeIndex {
            const ref = try makeDestructuringTempReadWithIdentity(self, ref_span, identity);
            const idx_node = try es_helpers.makeNumericLiteral(self, @intCast(idx));
            return es_helpers.makeComputedMember(self, ref, idx_node, span);
        }

        /// _ref.slice(N) 호출 생성 (array rest 변환용).
        fn buildArraySlice(self: *Transformer, ref_span: Span, start_idx: usize, span: Span, identity: es_helpers.TempIdentityCapture) Transformer.Error!NodeIndex {
            // _ref.slice
            const ref = try makeDestructuringTempReadWithIdentity(self, ref_span, identity);
            const slice_prop = try es_helpers.makePropertyName(self, "slice");
            const callee = try es_helpers.makeStaticMember(self, ref, slice_prop, span);

            // slice(N)
            const idx_node = try es_helpers.makeNumericLiteral(self, @intCast(start_idx));
            return es_helpers.makeCallExpr(self, callee, &.{idx_node}, span);
        }

        pub fn buildArrayRead(self: *Transformer, value: NodeIndex, pattern: Node, span: Span) Transformer.Error!NodeIndex {
            self.runtime_helpers.read = true;
            const callee = try es_helpers.makeRuntimeHelperRef(self, "__read");
            const read_len = arrayPatternReadLimit(self, pattern);
            if (read_len) |len| {
                const len_node = try es_helpers.makeNumericLiteral(self, len);
                return es_helpers.makeCallExpr(self, callee, &.{ value, len_node }, span);
            }
            return es_helpers.makeCallExpr(self, callee, &.{value}, span);
        }

        fn arrayPatternReadLimit(self: *Transformer, pattern: Node) ?u32 {
            const split = self.ast.nodeListSplitRest(pattern.data.list);
            if (split.rest_operand != null) return null;
            return @intCast(split.elements.len);
        }

        fn rewritePatternDefaultTDZ(self: *Transformer, default_val: NodeIndex, pattern: Node, start_idx: u32) Transformer.Error!void {
            var names: std.ArrayList(Span) = .empty;
            defer names.deinit(self.allocator);
            try collectPatternBindingNamesFrom(self, pattern, start_idx, &names);
            try es_helpers.rewriteTDZReferences(self, default_val, names.items);
        }

        fn collectPatternBindingNamesFrom(self: *Transformer, pattern: Node, start_idx: u32, out: *std.ArrayList(Span)) Transformer.Error!void {
            const split = self.ast.nodeListSplitRest(pattern.data.list);
            const non_rest_len: u32 = @intCast(split.elements.len);
            var i: u32 = start_idx;
            while (i < non_rest_len) : (i += 1) {
                const raw = self.ast.extra_data.items[pattern.data.list.start + i];
                try collectBindingNames(self, @fromBackingInt(@intCast(raw)), out);
            }
            if (split.rest_operand) |rest| try collectBindingNames(self, rest, out);
        }

        fn collectBindingNames(self: *Transformer, idx: NodeIndex, out: *std.ArrayList(Span)) Transformer.Error!void {
            var it = try ast_walk.bindingIdentifiers(self.allocator, self.ast, idx, .{});
            defer it.deinit();
            while (try it.next()) |leaf_idx| {
                try out.append(self.allocator, self.ast.getNode(leaf_idx).data.string_ref);
            }
        }

        const ComputedKeyMode = enum { decl, assign };
        const ObjectMemberAccessResult = struct {
            member: NodeIndex,
            computed_key_temp_identity: ?es_helpers.TempIdentityCapture = null,
        };

        /// object pattern 의 한 property 에 대해 `_ref[key]` member access 를 만들고, rest 가 있으면
        /// exclude key 도 같은 capture 결과로 모아둔다.
        ///
        /// computed key (`{[k()]: a}`) 는 member 접근과 nested default의 fallback이 같은 값/identity를
        /// 사용하도록 한 번 임시 변수로 캡처한다 — declarator 컨텍스트에서는 `_key=expr` declarator,
        /// assignment-target 컨텍스트에서는 `(_key=expr)` assignment_expression 형태로 `self.scratch` 에 push 한다.
        ///
        /// non-computed key (identifier/string/number) 는 캡처 없이 곧장 member access 를 만들고,
        /// rest exclude가 필요한 경우에만 raw key를 문자열 이름으로 등록한다.
        fn emitObjectMemberAccessForRest(
            self: *Transformer,
            ref: NodeIndex,
            key_node: Node,
            key_idx: NodeIndex,
            exclude_keys: *std.ArrayList(NodeIndex),
            include_exclude_key: bool,
            mode: ComputedKeyMode,
            span: Span,
            decl_kind: ast_mod.VariableDeclarationKind,
            producer_output_scope: @import("../semantic/scope.zig").ScopeId,
        ) Transformer.Error!ObjectMemberAccessResult {
            return emitObjectMemberAccessForRestWithPreparation(self, ref, key_node, key_idx, exclude_keys, include_exclude_key, mode, span, decl_kind, producer_output_scope, .visit);
        }

        fn emitObjectMemberAccessForRestWithPreparation(
            self: *Transformer,
            ref: NodeIndex,
            key_node: Node,
            key_idx: NodeIndex,
            exclude_keys: *std.ArrayList(NodeIndex),
            include_exclude_key: bool,
            mode: ComputedKeyMode,
            span: Span,
            decl_kind: ast_mod.VariableDeclarationKind,
            producer_output_scope: @import("../semantic/scope.zig").ScopeId,
            comptime preparation: PatternPreparation,
        ) Transformer.Error!ObjectMemberAccessResult {
            if (key_node.tag == .computed_property_key) {
                var computed_key_temp_identity: ?es_helpers.TempIdentityCapture = null;
                const key_span = switch (mode) {
                    .decl => try es_helpers.makeTempVarSpan(self),
                    .assign => blk: {
                        // State-machine lowering knows the eventual var owner
                        // even though the callback scope itself is created
                        // later. Keep the producer ID across that handoff.
                        const identity = try reservePatternTemp(self, span, if (producer_output_scope.isNone()) null else producer_output_scope);
                        computed_key_temp_identity = identity;
                        break :blk identity.span;
                    },
                };
                var direct_temp: ?DestructuringTemp = null;
                const capture: NodeIndex = switch (mode) {
                    .decl => blk: {
                        const key_temp = try makeDestructuringTempBinding(self, key_span, decl_kind);
                        direct_temp = key_temp;
                        computed_key_temp_identity = key_temp.identity;
                        const key_value = try patternChild(self, key_node.data.unary.operand, preparation);
                        break :blk try es_helpers.makeDeclarator(self, key_temp.binding, key_value, span);
                    },
                    .assign => blk: {
                        const identity = computed_key_temp_identity.?;
                        const write = try es_helpers.makeTempRefFromIdentity(self, identity, span, .{ .write = true });
                        break :blk try self.ast.addNode(.{
                            .tag = .assignment_expression,
                            .span = span,
                            .data = .{ .binary = .{
                                .left = write,
                                .right = try patternChild(self, key_node.data.unary.operand, preparation),
                                .flags = @backingInt(token_mod.Kind.eq),
                            } },
                        });
                    },
                };
                try self.scratch.append(self.allocator, capture);
                const key_identity = computed_key_temp_identity orelse
                    @panic("computed destructuring key lost its producer identity");
                if (include_exclude_key) {
                    try exclude_keys.append(self.allocator, try makeDestructuringTempReadWithIdentity(self, span, key_identity));
                }
                const member_ref = try makeDestructuringTempReadWithIdentity(self, span, key_identity);
                const member = try es_helpers.makeComputedMember(self, ref, member_ref, span);
                if (direct_temp) |temp| try bindPatternTemp(self, temp.binding, key_span, span, decl_kind, temp.identity);
                return .{ .member = member, .computed_key_temp_identity = computed_key_temp_identity };
            }
            if (include_exclude_key) try exclude_keys.append(self.allocator, try makeRestExcludeKey(self, key_node));
            return .{ .member = try es_helpers.makeMemberFromKeyIdx(self, ref, key_idx, span) };
        }

        fn makeRestExcludeKey(self: *Transformer, key_node: Node) Transformer.Error!NodeIndex {
            // __rest 헬퍼는 `e[i] = String(e[i])` 로 exclusion 원소를 런타임 정규화
            // (runtime_helpers.zig REST_RUNTIME). 따라서 #4242:
            switch (key_node.tag) {
                .identifier_reference, .binding_identifier => {
                    // 이름 표기 — \u escape 는 디코드해야 es5 에서 잔존(SyntaxError)
                    // /이중escape 안 됨. escape 없으면 byte-identical.
                    const raw = self.ast.getText(key_node.span);
                    if (std.mem.indexOfScalar(u8, raw, '\\') == null) {
                        return self.wrapInStringLiteral(raw);
                    }
                    const group_name = @import("../regexp/group_name.zig");
                    var decoded: std.ArrayList(u8) = .empty;
                    defer decoded.deinit(self.allocator);
                    try group_name.appendCanonical(self.allocator, &decoded, raw);
                    return self.wrapInStringLiteral(decoded.items);
                },
                // string/numeric/bigint key 는 노드 그대로 — 헬퍼 String() 이
                // 정규화. 이전: string 은 strip+requote 로 `'q"z'`→`"q"z"`
                // SyntaxError, numeric/bigint 는 `else=>""` 빈 exclusion(누락).
                .string_literal, .numeric_literal, .bigint_literal => {
                    return self.ast.addNode(.{
                        .tag = key_node.tag,
                        .span = key_node.span,
                        .data = key_node.data,
                    });
                },
                else => return self.wrapInStringLiteral(""),
            }
        }

        /// `__rest(_ref, [exclude_keys...])` 호출과 visit 된 binding 을 한 쌍으로 빌드.
        /// declarator 컨텍스트와 assignment 컨텍스트가 같은 11-step 보일러플레이트를 공유 (#1287).
        const RestCallParts = struct { binding: NodeIndex, call: NodeIndex };

        fn buildRestCall(
            self: *Transformer,
            rest_idx: NodeIndex,
            ref_span: Span,
            exclude_keys: []const NodeIndex,
            span: Span,
            identity: es_helpers.TempIdentityCapture,
        ) Transformer.Error!RestCallParts {
            return buildRestCallWithPreparation(self, rest_idx, ref_span, exclude_keys, span, identity, .visit);
        }

        fn buildRestCallWithPreparation(
            self: *Transformer,
            rest_idx: NodeIndex,
            ref_span: Span,
            exclude_keys: []const NodeIndex,
            span: Span,
            identity: es_helpers.TempIdentityCapture,
            comptime preparation: PatternPreparation,
        ) Transformer.Error!RestCallParts {
            const binding = try patternChild(self, rest_idx, preparation);
            const rest_callee = try es_helpers.makeRuntimeHelperRef(self, "__rest");
            const ref = try makeDestructuringTempReadWithIdentity(self, ref_span, identity);

            const scratch_top = self.scratch.items.len;
            defer self.scratch.shrinkRetainingCapacity(scratch_top);
            for (exclude_keys) |key| {
                try self.scratch.append(self.allocator, key);
            }
            const arr_list = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
            const arr_node = try self.ast.addNode(.{
                .tag = .array_expression,
                .span = span,
                .data = .{ .list = arr_list },
            });
            const call = try es_helpers.makeCallExpr(self, rest_callee, &.{ ref, arr_node }, span);
            return .{ .binding = binding, .call = call };
        }

        /// rest = __rest(_ref, [...]) declarator (declaration 컨텍스트).
        fn buildRestDeclarator(
            self: *Transformer,
            rest_idx: NodeIndex,
            ref_span: Span,
            exclude_keys: []const NodeIndex,
            span: Span,
            identity: es_helpers.TempIdentityCapture,
        ) Transformer.Error!NodeIndex {
            const parts = try buildRestCall(self, rest_idx, ref_span, exclude_keys, span, identity);
            return es_helpers.makeDeclarator(self, parts.binding, parts.call, span);
        }

        /// rest = __rest(_ref, [...]) assignment (assignment-target 컨텍스트).
        fn buildRestAssignment(
            self: *Transformer,
            rest_idx: NodeIndex,
            ref_span: Span,
            exclude_keys: []const NodeIndex,
            span: Span,
            identity: es_helpers.TempIdentityCapture,
        ) Transformer.Error!NodeIndex {
            const parts = try buildRestCall(self, rest_idx, ref_span, exclude_keys, span, identity);
            return self.ast.addNode(.{
                .tag = .assignment_expression,
                .span = span,
                .data = .{ .binary = .{ .left = parts.binding, .right = parts.call, .flags = 0 } },
            });
        }
        /// for_in_statement를 기본적으로 visit (ternary 자식 3개 재귀 방문).
        fn visitForInDefault(self: *Transformer, node: Node) Transformer.Error!NodeIndex {
            const new_a = try self.visitNode(node.data.ternary.a);
            const new_b = try self.visitNode(node.data.ternary.b);
            const new_c = try self.visitNode(node.data.ternary.c);
            return self.ast.addNode(.{
                .tag = node.tag,
                .span = node.span,
                .data = .{ .ternary = .{ .a = new_a, .b = new_b, .c = new_c } },
            });
        }

        /// for-in/for-of 루프의 binding destructuring을 분해한다 (node.tag 보존).
        /// for (var [i,j,k] in obj) { body }
        /// → for (var _ref in obj) { var i = _ref[0], j = _ref[1], k = _ref[2]; body }
        /// for (const { a, ...r } of arr) { body }  (#4254: object rest at es2015~17)
        /// → for (var _ref of arr) { var a = _ref.a, r = __rest(_ref, ["a"]); body }
        ///
        /// for-in/for-of 는 left 에 단일 binding 만 허용하므로 destructuring pattern 을
        /// 임시 변수로 교체하고 body 앞에 분해 선언문을 삽입한다. LHS 슬롯에 multi-
        /// declarator 를 직접 넣으면(`for(var _a,a=_a.a,... of)`) invalid 문법이 된다.
        const IterationBody = struct {
            wrapper: ?NodeIndex,
            scope: @import("../semantic/scope.zig").ScopeId,
        };

        // Reserve the actual body environment before visiting a non-block
        // statement. References created by lowering must be born in the block
        // which will contain both the pattern prefix and that statement.
        pub fn validateIterationBodyOwner(self: *Transformer, source: NodeIndex, node: Node) error{InvalidIterationBodyOwner}!?@import("../semantic/scope.zig").ScopeId {
            if (source.isNone() or @backingInt(source) >= self.ast.nodes.items.len) return error.InvalidIterationBodyOwner;
            const actual = self.ast.getNode(source);
            if ((actual.tag != .for_in_statement and actual.tag != .for_of_statement) or actual.tag != node.tag)
                return error.InvalidIterationBodyOwner;
            if (actual.data.ternary.a != node.data.ternary.a or actual.data.ternary.b != node.data.ternary.b or
                actual.data.ternary.c != node.data.ternary.c)
                return error.InvalidIterationBodyOwner;
            const body = node.data.ternary.c;
            if (body.isNone() or @backingInt(body) >= self.ast.nodes.items.len) return error.InvalidIterationBodyOwner;
            if (!self.semantic_edit_enabled) return null;
            const scopes = if (self.semantic_editor) |*editor| editor.scopes.items else self.scopes;
            if (self.current_scope.isNone() or self.current_scope.toIndex() >= scopes.len) return error.InvalidIterationBodyOwner;
            if (self.outputOwnedScope(source)) |loop_scope| {
                if (loop_scope != self.current_scope or scopes[loop_scope.toIndex()].kind != .block)
                    return error.InvalidIterationBodyOwner;
            } else if (@backingInt(source) < self.parser_node_count) return error.InvalidIterationBodyOwner;
            if (self.ast.getNode(body).tag != .block_statement) return null;
            const body_scope = self.outputOwnedScope(body) orelse return error.InvalidIterationBodyOwner;
            if (body_scope.toIndex() >= scopes.len or scopes[body_scope.toIndex()].kind != .block or
                scopes[body_scope.toIndex()].parent != self.current_scope or body_scope == self.current_scope)
                return error.InvalidIterationBodyOwner;
            return body_scope;
        }

        fn prepareIterationBody(self: *Transformer, body: NodeIndex, span: Span, known_scope: ?@import("../semantic/scope.zig").ScopeId) Transformer.Error!IterationBody {
            const tag = self.ast.getNode(body).tag;
            if (tag == .block_statement or tag == .function_body) {
                return .{ .wrapper = null, .scope = known_scope orelse self.current_scope };
            }
            const block = try @import("loop_scope_producer.zig").createBlock(self, self.current_scope, span);
            if (self.semantic_edit_enabled)
                try @import("loop_scope_producer.zig").moveExpression(self, body, self.current_scope, block.scope);
            return .{ .wrapper = block.node, .scope = if (self.semantic_edit_enabled) block.scope else self.current_scope };
        }

        fn assembleIterationBody(self: *Transformer, plan: IterationBody, body: NodeIndex, prefix: NodeIndex) Transformer.Error!NodeIndex {
            if (plan.wrapper) |wrapper| {
                try @import("loop_scope_producer.zig").fillBlock(self, wrapper, &.{ prefix, body });
                return wrapper;
            }
            const result = try self.prependStatementsToBody(body, &.{prefix});
            try self.remapCopiedScopeOwner(body, result);
            return result;
        }

        fn assembleIterationStatements(self: *Transformer, plan: IterationBody, body: NodeIndex, prefix: []const NodeIndex) Transformer.Error!NodeIndex {
            if (plan.wrapper) |wrapper| {
                var statements: std.ArrayList(NodeIndex) = .empty;
                defer statements.deinit(self.allocator);
                try statements.appendSlice(self.allocator, prefix);
                if (!body.isNone()) try statements.append(self.allocator, body);
                try @import("loop_scope_producer.zig").fillBlock(self, wrapper, statements.items);
                return wrapper;
            }
            const result = try self.prependStatementsToBody(body, prefix);
            try self.remapCopiedScopeOwner(body, result);
            return result;
        }

        pub fn lowerForInOfDestructuring(self: *Transformer, source: NodeIndex, node: Node) Transformer.Error!NodeIndex {
            const span = node.span;
            const left = node.data.ternary.a; // variable_declaration
            const right = node.data.ternary.b; // right-hand side expression
            const body = node.data.ternary.c; // body

            const left_node = self.ast.getNode(left);

            // assignment-target LHS (`for ({a, ...r} of arr)`) 는 binding 이 아니므로
            // 별도 처리: body 에 `({a,...r} = _ref)` assignment 를 prepend (#4254 후속).
            if (left_node.tag == .object_assignment_target or left_node.tag == .array_assignment_target) {
                return lowerForInOfAssignTargetDestructuring(self, source, node);
            }

            // variable_declaration에서 첫 번째 declarator의 패턴을 추출
            const le = left_node.data.extra;
            const list_start = self.readU32(le, 1);
            const list_len = self.readU32(le, 2);
            if (list_len == 0) return visitForInDefault(self, node);

            const first_decl_idx: NodeIndex = @fromBackingInt(@intCast(self.ast.extra_data.items[list_start]));
            const first_decl = self.ast.getNode(first_decl_idx);
            if (first_decl.tag != .variable_declarator) return visitForInDefault(self, node);

            const binding_idx: NodeIndex = self.readNodeIdx(first_decl.data.extra, 0);
            if (binding_idx.isNone()) return visitForInDefault(self, node);
            const binding_node = self.ast.getNode(binding_idx);

            // destructuring pattern이 아니면 일반 처리
            if (binding_node.tag != .array_pattern and binding_node.tag != .object_pattern) {
                return visitForInDefault(self, node);
            }

            const known_body_scope = validateIterationBodyOwner(self, source, node) catch
                @panic("destructuring iteration has no exact source/body owner");

            // 1) 임시 변수 _ref 생성
            const temp_span = try es_helpers.makeTempVarSpan(self);

            // 2) for-in의 left를 var _ref 로 교체
            // #4254: per-iteration 바인딩 보존 — block_scoping native(es2015+)면
            // 원본 let/const 유지. var 로 강등하면 loop temp/destructure 가 함수
            // 스코프 단일 바인딩으로 붕괴해 closure capture 가 깨진다(마지막 iter
            // 값만 캡처). block_scoping 미지원(es5)이면 var (for-of 는 es5 에서 이
            // 경로 미도달=lowerForOfStatement; for-in 만, 기존 var 동작 유지).
            const orig_kind = self.ast.variableDeclarationKind(left_node);
            const out_kind: ast_mod.VariableDeclarationKind = if (self.options.unsupported.block_scoping) .@"var" else orig_kind;
            const temp = try makeDestructuringTempBinding(self, temp_span, out_kind);
            const temp_decl = try es_helpers.makeDeclarator(self, temp.binding, NodeIndex.none, span);
            const new_left = try es_helpers.makeVarDeclaration(self, &.{temp_decl}, out_kind, span);

            // 3) right를 visit
            const new_right = try self.visitNode(right);

            // 4) Reserve the emitted body owner before creating its reads.
            const body_plan = try prepareIterationBody(self, body, span, known_body_scope);
            const loop_scope = self.current_scope;
            self.current_scope = body_plan.scope;
            defer self.current_scope = loop_scope;
            const new_body = try self.visitNode(body);

            if (self.options.unsupported.destructuring and self.options.unsupported.block_scoping and binding_node.tag == .array_pattern) {
                // The physical declarations remain directly in the actual
                // iteration body. Only iterator evaluation owns the nested
                // ready region; do not drain its declarations outside the loop.
                try movePatternExpression(self, binding_idx, loop_scope, body_plan.scope);
                var body_identity = temp.identity;
                body_identity.reference_scope = body_plan.scope;
                const value = try makeDestructuringTempReadWithIdentity(self, span, body_identity);
                const declarator = try es_helpers.makeDeclarator(self, binding_idx, value, span);
                const declaration = try es_helpers.makeVarDeclaration(self, &.{declarator}, out_kind, span);
                const pending_start = self.pending_nodes.items.len;
                if (comptime @hasDecl(Transformer, "recordIterationDeclaration"))
                    try self.recordIterationDeclaration(source, body_plan.scope, declaration);
                const ready = try lowerDestructuringDeclarationStatementAt(self, declaration);
                var prefix: std.ArrayList(NodeIndex) = .empty;
                defer prefix.deinit(self.allocator);
                try prefix.appendSlice(self.allocator, self.pending_nodes.items[pending_start..]);
                self.pending_nodes.shrinkRetainingCapacity(pending_start);
                try prefix.append(self.allocator, ready);
                try bindPatternTemp(self, temp.binding, temp_span, span, out_kind, temp.identity);
                const final_body = try assembleIterationStatements(self, body_plan, new_body, prefix.items);
                return self.ast.addNode(.{ .tag = node.tag, .span = span, .data = .{ .ternary = .{ .a = new_left, .b = new_right, .c = final_body } } });
            }

            // 5) body 앞에 삽입할 destructuring 선언문들을 생성
            //    var i = _ref[0], j = _ref[1], k = _ref[2]
            const scratch_top = self.scratch.items.len;
            defer self.scratch.shrinkRetainingCapacity(scratch_top);

            var body_identity = temp.identity;
            body_identity.reference_scope = body_plan.scope;
            try emitPatternDeclaratorsWithIdentity(self, binding_node, body_identity, span, out_kind);
            try bindPatternTemp(self, temp.binding, temp_span, span, out_kind, temp.identity);

            // scratch에 쌓인 declarator들로 variable_declaration 생성
            const decl_list = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
            const var_extra = try self.ast.addExtras(&.{ @backingInt(out_kind), decl_list.start, decl_list.len });
            const destr_decl = try self.ast.addNode(.{
                .tag = .variable_declaration,
                .span = span,
                .data = .{ .extra = var_extra },
            });

            // 6) body 앞에 destructuring 선언문 삽입
            const final_body = if (!new_body.isNone())
                try assembleIterationBody(self, body_plan, new_body, destr_decl)
            else
                new_body;

            // 7) 새 for_in/for_of_statement 생성 (입력 tag 보존)
            return self.ast.addNode(.{
                .tag = node.tag,
                .span = span,
                .data = .{ .ternary = .{ .a = new_left, .b = new_right, .c = final_body } },
            });
        }

        /// for-of/for-in 의 LHS 가 assignment-target object/array rest 일 때
        /// (`for ({a, ...r} of arr)`), body 에 `({a,...r} = _ref)` 를 prepend (#4254 후속).
        /// `for (kind _ref of arr) { ({a,...r} = _ref); body }`. 그 assignment 는
        /// visit 시 lowerDestructuringAssignment(#4251 object_spread 게이트)가 __rest
        /// 로 lowering. assignment target(a/r)은 outer 변수라 _ref 만 per-iteration
        /// 바인딩(closure 는 outer 캡처).
        fn lowerForInOfAssignTargetDestructuring(self: *Transformer, source: NodeIndex, node: Node) Transformer.Error!NodeIndex {
            const span = node.span;
            const left = node.data.ternary.a; // object/array_assignment_target
            const right = node.data.ternary.b;
            const body = node.data.ternary.c;
            const known_body_scope = validateIterationBodyOwner(self, source, node) catch
                @panic("destructuring iteration has no exact source/body owner");

            const temp_span = try es_helpers.makeTempVarSpan(self);
            const out_kind: ast_mod.VariableDeclarationKind = if (self.options.unsupported.block_scoping) .@"var" else .@"const";
            const temp = try makeDestructuringTempBinding(self, temp_span, out_kind);
            const temp_decl = try es_helpers.makeDeclarator(self, temp.binding, NodeIndex.none, span);
            const new_left = try es_helpers.makeVarDeclaration(self, &.{temp_decl}, out_kind, span);

            const new_right = try self.visitNode(right);
            const body_plan = try prepareIterationBody(self, body, span, known_body_scope);
            const loop_scope = self.current_scope;
            self.current_scope = body_plan.scope;
            defer self.current_scope = loop_scope;
            const new_body = try self.visitNode(body);

            // ({a,...r} = _ref) — visit 시 lowerDestructuringAssignment 로 __rest lowering.
            var body_identity = temp.identity;
            body_identity.reference_scope = body_plan.scope;
            const ref_for_assign = try makeDestructuringTempReadWithIdentity(self, span, body_identity);
            if (self.options.unsupported.destructuring and self.ast.getNode(left).tag == .array_assignment_target) {
                const ready = try prepareBindingPatternStatement(self, self.ast.getNode(left), ref_for_assign, span, .{ .use_scope = body_plan.scope, .source_scope = loop_scope });
                const prefix = try self.visitNode(ready.statement);
                try bindPatternTemp(self, temp.binding, temp_span, span, out_kind, temp.identity);
                const final_body = try assembleIterationStatements(self, body_plan, new_body, &.{prefix});
                return self.ast.addNode(.{ .tag = node.tag, .span = span, .data = .{ .ternary = .{ .a = new_left, .b = new_right, .c = final_body } } });
            }
            const assign = try es_helpers.makeAssignExpr(self, left, ref_for_assign, span, 0);
            const visited_assign = try self.visitNode(assign);
            try bindPatternTemp(self, temp.binding, temp_span, span, out_kind, temp.identity);
            const assign_stmt = try es_helpers.makeExprStmt(self, visited_assign, span);

            const final_body = if (!new_body.isNone())
                try assembleIterationBody(self, body_plan, new_body, assign_stmt)
            else
                new_body;

            return self.ast.addNode(.{
                .tag = node.tag,
                .span = span,
                .data = .{ .ternary = .{ .a = new_left, .b = new_right, .c = final_body } },
            });
        }
    };
}

test "ES2015 destructuring module compiles" {
    _ = ES2015Destructuring;
}

test "lazy iterator binding declarations preserve default abrupt elision and nested close order" {
    const cases = [_][]const u8{
        "globalThis.Symbol={};function f(){const[value]=[42];return value}console.log(f());",
        "const log=[];const it={[Symbol.iterator](){log.push('open');return{next(){log.push('next');return{value:undefined,done:false}},return(){log.push('close');return{done:true}}}}};try{let[a=(()=>{log.push('default');throw Error('body')})(),b]=it}catch(e){log.push(e.message)}console.log(JSON.stringify(log));",
        "const log=[];const it={[Symbol.iterator](){return{next(){log.push('next');return{get value(){log.push('value');return 42},done:false}},return(){log.push('close');return{done:true}}}}};let[,x]=it;console.log(JSON.stringify([x,log]));",
        "const log=[];const it={[Symbol.iterator](){log.push('open');return{next(){log.push('next');return{value:42,done:false}},return(){log.push('close');return{done:true}}}}};let[]=it;console.log(JSON.stringify(log));",
        "const log=[];function make(name,value){return{[Symbol.iterator](){return{next(){log.push(name+':next');return{value,done:false}},return(){log.push(name+':close');return{done:true}}}}}}try{let[[x=(()=>{throw Error('body')})()],y]=make('outer',make('inner',undefined))}catch(e){log.push(e.message)}console.log(JSON.stringify(log));",
        "const log=[];let n=0;const it={[Symbol.iterator](){return{next(){log.push('next:'+n);return n++<3?{value:n===1?undefined:n,done:false}:{done:true}},return(){log.push('close');return{done:true}}}}};let[x=(log.push('default'),42),...tail]=it;console.log(JSON.stringify([x,tail,log]));",
    };
    for (cases, 0..) |source, index| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        const native = try std.process.run(allocator, std.testing.io, .{ .argv = &.{ "node", "-e", source } });
        try std.testing.expect(native.term == .exited and native.term.exited == 0);
        for ([_]bool{ false, true }) |minify| {
            const result = try @import("../transpile.zig").transpile(allocator, source, "input.cjs", .{
                .unsupported = @import("transformer.zig").TransformOptions.compat.fromESTarget(.es5),
                .minify_identifiers = minify,
                .minify_syntax = minify,
                .minify_whitespace = minify,
            });
            const actual = try std.process.run(allocator, std.testing.io, .{ .argv = &.{ "node", "-e", result.code } });
            if (actual.term != .exited or actual.term.exited != 0 or !std.mem.eql(u8, native.stdout, actual.stdout)) {
                std.debug.print("lazy iterator binding case={d} minify={} native={s} actual={s} stderr={s} code={s}\n", .{ index, minify, native.stdout, actual.stdout, actual.stderr, result.code });
            }
            try std.testing.expect(actual.term == .exited and actual.term.exited == 0);
            try std.testing.expectEqualStrings(native.stdout, actual.stdout);
        }
    }
}

test "lazy iterator binding bundle keeps the parsed runtime provider and close order" {
    const helpers = @import("../bundler/test_helpers.zig");
    const Bundler = @import("../bundler/bundler.zig").Bundler;
    const source = "const log=[];const it={[Symbol.iterator](){log.push('open');return{next(){log.push('next');return{value:undefined,done:false}},return(){log.push('close');return{done:true}}}}};try{let[a=(()=>{log.push('default');throw Error('body')})(),b]=it}catch(e){log.push(e.message)}console.log(JSON.stringify(log));";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const native = try std.process.run(allocator, std.testing.io, .{ .argv = &.{ "node", "-e", source } });
    try std.testing.expect(native.term == .exited and native.term.exited == 0);
    for ([_]bool{ false, true }) |minify| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try helpers.writeFile(tmp.dir, "input.cjs", source);
        const input = try helpers.absPath(&tmp, "input.cjs");
        defer std.testing.allocator.free(input);
        var bundler = Bundler.init(std.testing.allocator, .{
            .entry_points = &.{input},
            .format = .cjs,
            .platform = .node,
            .unsupported = @import("transformer.zig").TransformOptions.compat.fromESTarget(.es5),
            .minify_identifiers = minify,
            .minify_syntax = minify,
            .minify_whitespace = minify,
        });
        defer bundler.deinit();
        const result = try bundler.bundle(std.testing.io);
        defer result.deinit(std.testing.allocator);
        try std.testing.expect(!result.hasErrors());
        const actual = try std.process.run(allocator, std.testing.io, .{ .argv = &.{ "node", "-e", result.output } });
        if (actual.term != .exited or actual.term.exited != 0 or !std.mem.eql(u8, native.stdout, actual.stdout)) {
            std.debug.print("lazy iterator provider minify={} native={s} actual={s} stderr={s} code={s}\n", .{ minify, native.stdout, actual.stdout, actual.stderr, result.output });
        }
        try std.testing.expect(actual.term == .exited and actual.term.exited == 0);
        try std.testing.expectEqualStrings(native.stdout, actual.stdout);
    }
}

test "lazy iterator traditional for initializer closes before test and preserves captured cells" {
    const cases = [_][]const u8{
        "const log=[];const source={[Symbol.iterator](){log.push('open');return{next(){log.push('next');return{value:42,done:false}},return(){log.push('close');return{done:true}}}}};for(var[value]=source;(log.push('test'),false);){}console.log(JSON.stringify([value,log]));",
        "const log=[];const source={[Symbol.iterator](){log.push('open');return{next(){log.push('next');return{value:42,done:false}},return(){log.push('close');return{done:true}}}}};for(let[]=source;(log.push('test'),false);){}console.log(JSON.stringify(log));",
        "const log=[];const source={[Symbol.iterator](){let n=0;log.push('open');return{next(){log.push('next');return{value:n++?7:undefined,done:false}},return(){log.push('close');return{done:true}}}}};for(let[x=(log.push('default'),42),y]=source;(log.push('test'),x<43);x++){log.push(x,y)}console.log(JSON.stringify(log));",
        "const saved=[];for(let[value]=[42];value<44;value++){saved.push(()=>value)}console.log(JSON.stringify(saved.map(f=>f())));",
    };
    for (cases, 0..) |source, index| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        const native = try std.process.run(allocator, std.testing.io, .{ .argv = &.{ "node", "-e", source } });
        try std.testing.expect(native.term == .exited and native.term.exited == 0);
        for ([_]bool{ false, true }) |minify| {
            const result = try @import("../transpile.zig").transpile(allocator, source, "input.cjs", .{
                .unsupported = @import("transformer.zig").TransformOptions.compat.fromESTarget(.es5),
                .minify_identifiers = minify,
                .minify_syntax = minify,
                .minify_whitespace = minify,
            });
            const actual = try std.process.run(allocator, std.testing.io, .{ .argv = &.{ "node", "-e", result.code } });
            if (actual.term != .exited or actual.term.exited != 0 or !std.mem.eql(u8, native.stdout, actual.stdout)) {
                std.debug.print("lazy iterator for case={d} minify={} native={s} actual={s} stderr={s} code={s}\n", .{ index, minify, native.stdout, actual.stdout, actual.stderr, result.code });
            }
            try std.testing.expect(actual.term == .exited and actual.term.exited == 0);
            try std.testing.expectEqualStrings(native.stdout, actual.stdout);
        }
    }
}

test "lazy iterator discarded assignments preserve reference default and close order" {
    const cases = [_][]const u8{
        "const log=[];let value;const source={get value(){log.push('get');return 42}};({value=7}=source);console.log(JSON.stringify([value,log]));",
        "const log=[];let value;const source={get x(){log.push('get');return 42}};({x:value=7}=source);console.log(JSON.stringify([value,log]));",
        "const log=[];let a;const source={[Symbol.iterator](){return{next(){log.push('next');return{value:undefined,done:false}},return(){log.push('close');return{done:true}}}}};try{const result=([a=(()=>{log.push('default');throw 7})()]=source);log.push(result===source)}catch(e){log.push(e)}console.log(JSON.stringify(log));",
        "const log=[];let a;const source={[Symbol.iterator](){return{next(){log.push('next');return{value:42,done:false}},return(){log.push('close');return{done:true}}}}};function run(){return([a]=source)}console.log(JSON.stringify([run()===source,a,log]));",
        "const log=[];let a;const source={[Symbol.iterator](){return{next(){log.push('next');return{value:42,done:false}},return(){log.push('close');return{done:true}}}}};try{throw([a]=source)}catch(e){log.push(e===source,a)}console.log(JSON.stringify(log));",
        "const log=[];let a,b;const source={[Symbol.iterator](){return{next(){log.push('next');return{value:{x:undefined,y:7},done:false}},return(){log.push('close');return{done:true}}}}};[{x:a=(log.push('default'),42),y:b}]=source;console.log(JSON.stringify([log,a,b]));",
        "const log=[];const object={set x(v){log.push('set:'+v)}};const key={toString(){log.push('key');return'x'}};function base(){log.push('base');return object}function getKey(){log.push('keyexpr');return key}const source={[Symbol.iterator](){return{next(){log.push('next');return{value:undefined,done:false}},return(){log.push('close');return{done:true}}}}};[base()[getKey()]=(log.push('default'),42)]=source;console.log(JSON.stringify(log));",
        "const log=[];let first,second;const source={[Symbol.iterator](){return{next(){log.push('next');return{value:undefined,done:false}},return(){log.push('close');return{done:true}}}}};try{[first=(()=>{throw 7})(),second]=source}catch(e){log.push(e)}console.log(JSON.stringify(log));",
        "const log=[];const object={set x(v){log.push('set:'+v)}};const key={toString(){log.push('key');return'x'}};const source={[Symbol.iterator](){return{next(){log.push('next');return{value:undefined,done:false}},return(){log.push('close');return{done:true}}}}};function base(){log.push('base');return object}[base()[key]=(log.push('default'),42)]=source;console.log(JSON.stringify(log));",
        "const log=[];let a,b;function source(label,values){return{[Symbol.iterator](){let i=0;return{next(){log.push(label+':next');return{value:values[i++],done:false}},return(){log.push(label+':close');return{done:true}}}}}}[[a],b]=source('outer',[source('inner',[42]),7]);console.log(JSON.stringify([log,a,b]));",
        "let first,rest;[first=42,...rest]=[undefined,7,8];console.log(JSON.stringify([first,rest]));",
        "const log=[];let a,b;function source(label){return{[Symbol.iterator](){return{next(){log.push(label+':next');return{value:undefined,done:false}},return(){log.push(label+':close');return{done:true}}}}}}[a=([b=7]=source('inner'),42)]=source('outer');console.log(JSON.stringify([log,a,b]));",
    };
    for (cases) |source| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        const native = try std.process.run(allocator, std.testing.io, .{ .argv = &.{ "node", "-e", source } });
        try std.testing.expect(native.term == .exited and native.term.exited == 0);
        for ([_]bool{ false, true }) |minify| {
            const result = try @import("../transpile.zig").transpile(allocator, source, "input.cjs", .{
                .unsupported = @import("transformer.zig").TransformOptions.compat.fromESTarget(.es5),
                .minify_identifiers = minify,
                .minify_syntax = minify,
                .minify_whitespace = minify,
            });
            const actual = try std.process.run(allocator, std.testing.io, .{ .argv = &.{ "node", "-e", result.code } });
            if (actual.term != .exited or actual.term.exited != 0 or !std.mem.eql(u8, native.stdout, actual.stdout))
                std.debug.print("lazy assignment minify={} native={s} actual={s} stderr={s} code={s}\n", .{ minify, native.stdout, actual.stdout, actual.stderr, result.code });
            try std.testing.expect(actual.term == .exited and actual.term.exited == 0);
            try std.testing.expectEqualStrings(native.stdout, actual.stdout);
        }
    }
}

test "lazy iterator retains intrinsic array and custom iteration when host Symbol is absent" {
    const source = "const log=[];const source={[savedIteratorSymbol](){let n=0;return{next(){log.push('next');return{value:++n,done:false}},return(){log.push('close');return{done:true}}}}};const [value]=source;const [arrayValue]=[42];console.log(JSON.stringify([value,arrayValue,log]));";
    const preludes = [_][]const u8{
        "globalThis.savedIteratorSymbol=Symbol.iterator;globalThis.Symbol=undefined;",
        "globalThis.savedIteratorSymbol=Symbol.iterator;globalThis.Symbol={};",
        "globalThis.savedIteratorSymbol=Symbol.iterator;delete globalThis.Symbol;",
    };
    for (preludes) |prelude| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        const native_source = try std.fmt.allocPrint(allocator, "{s}\n{s}", .{ prelude, source });
        const native = try std.process.run(allocator, std.testing.io, .{ .argv = &.{ "node", "-e", native_source } });
        try std.testing.expect(native.term == .exited and native.term.exited == 0);
        for ([_]bool{ false, true }) |minify| {
            const result = try @import("../transpile.zig").transpile(allocator, source, "input.cjs", .{
                .unsupported = @import("transformer.zig").TransformOptions.compat.fromESTarget(.es5),
                .minify_identifiers = minify,
                .minify_syntax = minify,
                .minify_whitespace = minify,
            });
            const actual_source = try std.fmt.allocPrint(allocator, "{s}\n{s}", .{ prelude, result.code });
            const actual = try std.process.run(allocator, std.testing.io, .{ .argv = &.{ "node", "-e", actual_source } });
            if (actual.term != .exited or actual.term.exited != 0 or !std.mem.eql(u8, native.stdout, actual.stdout))
                std.debug.print("lazy host prelude={s} minify={} native={s} actual={s} stderr={s} code={s}\n", .{ prelude, minify, native.stdout, actual.stdout, actual.stderr, result.code });
            try std.testing.expect(actual.term == .exited and actual.term.exited == 0);
            try std.testing.expectEqualStrings(native.stdout, actual.stdout);
        }
    }
}

test "lazy iterator loop heads close before another binding initialization" {
    const cases = [_][]const u8{
        "const x=42;String.prototype[Symbol.iterator]=function(){return{next(){return{value:undefined,done:false}},return(){return{done:true}}}};let read;for(let[fn=()=>eval('x')]in{key:1}){let x=7;read=fn}console.log(read());",
        "const log=[];let a,b;String.prototype[Symbol.iterator]=function(){return{next(){log.push('next');return{value:undefined,done:false}},return(){log.push('close');return{done:true}}}};try{for([a=(()=>{log.push('default');throw 7})(),b]in{key:1}){log.push('body')}}catch(e){log.push(e)}console.log(JSON.stringify(log));",
        "const log=[];const inner={[Symbol.iterator](){return{next(){log.push('next');return{value:undefined,done:false}},return(){log.push('close');return{done:true}}}}};try{for(let[a=(()=>{log.push('default');throw 7})(),b]of[inner]){log.push('body')}}catch(e){log.push(e)}console.log(JSON.stringify(log));",
        "const log=[];let a,b;const inner={[Symbol.iterator](){return{next(){log.push('next');return{value:undefined,done:false}},return(){log.push('close');return{done:true}}}}};try{for([a=(()=>{log.push('default');throw 7})(),b]of[inner]){log.push('body')}}catch(e){log.push(e)}console.log(JSON.stringify(log));",
        "const saved=[];for(const[value]of[[1],[2]])saved.push(()=>value);console.log(JSON.stringify(saved.map(f=>f())));",
        "const log=[];String.prototype[Symbol.iterator]=function(){return{next(){log.push('next');return{value:undefined,done:false}},return(){log.push('close');return{done:true}}}};try{for(let[a=(()=>{log.push('default');throw 7})(),b]in{key:1}){log.push('body')}}catch(e){log.push(e)}console.log(JSON.stringify(log));",
    };
    for (cases) |source| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        const native = try std.process.run(allocator, std.testing.io, .{ .argv = &.{ "node", "-e", source } });
        try std.testing.expect(native.term == .exited and native.term.exited == 0);
        for ([_]bool{ false, true }) |minify| {
            const result = try @import("../transpile.zig").transpile(allocator, source, "input.cjs", .{
                .unsupported = @import("transformer.zig").TransformOptions.compat.fromESTarget(.es5),
                .minify_identifiers = minify,
                .minify_syntax = minify,
                .minify_whitespace = minify,
            });
            const actual = try std.process.run(allocator, std.testing.io, .{ .argv = &.{ "node", "-e", result.code } });
            if (actual.term != .exited or actual.term.exited != 0 or !std.mem.eql(u8, native.stdout, actual.stdout))
                std.debug.print("lazy head minify={} native={s} actual={s} stderr={s} code={s}\n", .{ minify, native.stdout, actual.stdout, actual.stderr, result.code });
            try std.testing.expect(actual.term == .exited and actual.term.exited == 0);
            try std.testing.expectEqualStrings(native.stdout, actual.stdout);
        }
    }
}

test "lazy iterator expression statements preserve sequence conditional and short circuit values" {
    const prefix = "const log=[];let a,b,last;function source(){return last={[Symbol.iterator](){return{next(){log.push('next');return{value:undefined,done:false}},return(){log.push('close');return{done:true}}}}}};";
    const bodies = [_][]const u8{
        "false&&([a=(()=>{log.push('default');throw 7})(),b]=source());log.push('skip');console.log(JSON.stringify(log));",
        "try{true&&([a=(()=>{log.push('default');throw 7})(),b]=source())}catch(e){log.push(e)}console.log(JSON.stringify(log));",
        "const result=0||([a=42]=source());console.log(JSON.stringify([result===last,a,log]));",
        "const result=0??([a=42]=source());console.log(JSON.stringify([result,log]));",
        "const result=null??([a=42]=source());console.log(JSON.stringify([result===last,a,log]));",
        "const result=false?([a]=source()):function(){};console.log(JSON.stringify([result.name,log]));",
        "try{log.push('before'),([a=(()=>{log.push('default');throw 7})(),b]=source()),log.push('after')}catch(e){log.push(e)}console.log(JSON.stringify(log));",
        "[a=([b=(log.push('inner-default'),7)]=source(),42)]=source();console.log(JSON.stringify([a,b,log]));",
        "function run(){return true?([a=42]=source()):0}const result=run();console.log(JSON.stringify([result===last,a,log]));",
        "const result=([a=42]=source())?(log.push('yes'),7):(log.push('no'),8);console.log(JSON.stringify([result,a,log]));",
    };
    for (bodies) |body| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        const source = try std.fmt.allocPrint(allocator, "{s}{s}", .{ prefix, body });
        const native = try std.process.run(allocator, std.testing.io, .{ .argv = &.{ "node", "-e", source } });
        try std.testing.expect(native.term == .exited and native.term.exited == 0);
        for ([_]bool{ false, true }) |minify| {
            const result = try @import("../transpile.zig").transpile(allocator, source, "input.cjs", .{
                .unsupported = @import("transformer.zig").TransformOptions.compat.fromESTarget(.es5),
                .keep_names = true,
                .minify_identifiers = minify,
                .minify_syntax = minify,
                .minify_whitespace = minify,
            });
            const actual = try std.process.run(allocator, std.testing.io, .{ .argv = &.{ "node", "-e", result.code } });
            if (actual.term != .exited or actual.term.exited != 0 or !std.mem.eql(u8, native.stdout, actual.stdout))
                std.debug.print("lazy expression body={s} minify={} native={s} actual={s} stderr={s} code={s}\n", .{ body, minify, native.stdout, actual.stdout, actual.stderr, result.code });
            try std.testing.expect(actual.term == .exited and actual.term.exited == 0);
            try std.testing.expectEqualStrings(native.stdout, actual.stdout);
        }
    }
}
