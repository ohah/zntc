//! Runtime initialization state for source lexical cells lowered to var.
//!
//! Source-local cells retain exact source SymbolIds across ordinary function,
//! block, loop, switch, catch and state-machine execution handoffs. A marker
//! distinguishes uninitialized storage from an initialized undefined value.
//! Dynamic eval/with and cross-module namespace publication remain separate
//! environment contracts; local program admission does not certify them.
const std = @import("std");
const ast = @import("../parser/ast.zig");
const scope_mod = @import("../semantic/scope.zig");
const helpers = @import("es_helpers.zig");
const NodeIndex = ast.NodeIndex;
const ScopeId = scope_mod.ScopeId;
const Kind = @import("../lexer/token.zig").Kind;

fn compoundOperator(flags: u16) ?Kind {
    return switch (flags) {
        @backingInt(Kind.plus_eq) => .plus,
        @backingInt(Kind.minus_eq) => .minus,
        @backingInt(Kind.star_eq) => .star,
        @backingInt(Kind.slash_eq) => .slash,
        @backingInt(Kind.percent_eq) => .percent,
        @backingInt(Kind.star2_eq) => .star2,
        @backingInt(Kind.amp_eq) => .amp,
        @backingInt(Kind.pipe_eq) => .pipe,
        @backingInt(Kind.caret_eq) => .caret,
        @backingInt(Kind.shift_left_eq) => .shift_left,
        @backingInt(Kind.shift_right_eq) => .shift_right,
        @backingInt(Kind.shift_right3_eq) => .shift_right3,
        else => null,
    };
}

fn logicalOperator(flags: u16) ?Kind {
    return switch (flags) {
        @backingInt(Kind.amp2_eq) => .amp2,
        @backingInt(Kind.pipe2_eq) => .pipe2,
        @backingInt(Kind.question2_eq) => .question2,
        else => null,
    };
}

const Cell = struct {
    binding: NodeIndex,
    body: NodeIndex,
    scope: ScopeId,
    initialization_end: u32,
    readonly: bool,
    demand: bool = false,
    written: bool = false,
};

const IterableReference = struct { symbol: u32, binding: NodeIndex };
const IterationDeclaration = struct {
    source_for: NodeIndex,
    body_scope: ScopeId,
    consumed: bool = false,
};

pub const Plan = struct {
    arena: std.heap.ArenaAllocator,
    cells: std.AutoHashMapUnmanaged(u32, Cell) = .empty,
    bodies: std.AutoHashMapUnmanaged(u32, std.ArrayListUnmanaged(u32)) = .empty,
    reads: std.AutoHashMapUnmanaged(u32, u32) = .empty,
    assignments: std.AutoHashMapUnmanaged(u32, void) = .empty,
    writes: std.AutoHashMapUnmanaged(u32, ScopeId) = .empty,
    header_first_bindings: std.AutoHashMapUnmanaged(u32, NodeIndex) = .empty,
    header_by_first_binding: std.AutoHashMapUnmanaged(u32, NodeIndex) = .empty,
    switch_first_test: std.AutoHashMapUnmanaged(u32, NodeIndex) = .empty,
    switch_only_default: std.AutoHashMapUnmanaged(u32, NodeIndex) = .empty,
    iterable_references: std.AutoHashMapUnmanaged(u32, IterableReference) = .empty,
    catch_patterns: std.AutoHashMapUnmanaged(u32, NodeIndex) = .empty,
    iteration_declarations: std.AutoHashMapUnmanaged(u32, IterationDeclaration) = .empty,
    module_flags: std.AutoHashMapUnmanaged(u32, NodeIndex) = .empty,
    module_initialized_values: std.AutoHashMapUnmanaged(u32, u32) = .empty,

    pub fn init(allocator: std.mem.Allocator) Plan {
        return .{ .arena = std.heap.ArenaAllocator.init(allocator) };
    }

    pub fn deinit(self: *Plan) void {
        self.arena.deinit();
    }

    pub fn hasDemand(self: *const Plan) bool {
        if (self.iterable_references.count() != 0 or self.module_flags.count() != 0) return true;
        var cells = self.cells.valueIterator();
        while (cells.next()) |cell| if (cell.demand and !cell.written) return true;
        return false;
    }

    fn registerDeclaration(plan: *Plan, self: anytype, statement: ast.Node, owner: u32, body: NodeIndex, bypassable: bool) !void {
        if (statement.tag != .variable_declaration or !self.ast.variableDeclarationKind(statement).isLexical()) return;
        const start = self.readU32(statement.data.extra, 1);
        const len = self.readU32(statement.data.extra, 2);
        for (0..len) |offset| {
            const declarator = self.ast.getNode(self.ast.readExtraNode(start, @intCast(offset)));
            if (declarator.tag != .variable_declarator) continue;
            const pattern = self.ast.readExtraNode(declarator.data.extra, 0);
            try plan.registerPattern(self, pattern, owner, body, if (bypassable) std.math.maxInt(u32) else declarator.span.end, false);
        }
    }

    fn registerPattern(plan: *Plan, self: anytype, pattern: NodeIndex, owner: u32, body: NodeIndex, initialization_end: u32, catch_parameter: bool) !void {
        var bindings = try @import("../parser/ast_walk.zig").bindingIdentifiers(plan.arena.allocator(), self.ast, pattern, .{});
        while (try bindings.next()) |binding| {
            if (self.ast.getNode(binding).tag != .binding_identifier) continue;
            const sid = self.getSymbolIdAt(binding) orelse continue;
            if (sid >= self.symbols.len) continue;
            const symbol = self.symbols[sid];
            if (symbol.scope_id.toIndex() != owner) continue;
            if (catch_parameter) {
                if (symbol.kind != .catch_binding) continue;
            } else if (symbol.kind != .variable_let and symbol.kind != .variable_const) continue;
            try plan.cells.put(plan.arena.allocator(), sid, .{
                .binding = binding,
                .body = body,
                .scope = symbol.scope_id,
                .initialization_end = initialization_end,
                .readonly = symbol.kind == .variable_const,
            });
        }
    }

    fn registerBody(plan: *Plan, self: anytype, body: NodeIndex, owner: u32) !void {
        const node = self.ast.getNode(body);
        if (node.tag != .block_statement and node.tag != .function_body and node.tag != .program) return;
        for (0..node.data.list.len) |offset| {
            var declaration = self.ast.getNode(self.ast.readExtraNode(node.data.list.start, @intCast(offset)));
            if (declaration.tag == .export_named_declaration) {
                const child = self.ast.readExtraNode(declaration.data.extra, 0);
                if (child.isNone()) continue;
                declaration = self.ast.getNode(child);
            }
            try plan.registerDeclaration(self, declaration, owner, body, false);
        }
    }

    pub fn prepare(plan: *Plan, self: anytype) !void {
        if (!self.options.unsupported.block_scoping or !self.semantic_edit_enabled) return;
        const allocator = plan.arena.allocator();
        var executions: std.AutoHashMapUnmanaged(u32, void) = .empty;
        const program: NodeIndex = @fromBackingInt(self.parser_node_count - 1);
        const program_scope = self.programScope();
        if (!program_scope.isNone() and program_scope.toIndex() < self.scopes.len) {
            const owner = self.scopes[program_scope.toIndex()];
            if (!owner.subtree_has_direct_eval and !owner.subtree_has_with) {
                try executions.put(allocator, program_scope.toIndex(), {});
                try plan.registerBody(self, program, program_scope.toIndex());
            }
        }
        for (0..self.parser_node_count) |raw| {
            const function = self.ast.nodes.items[raw];
            switch (function.tag) {
                .function_declaration, .function_expression, .function, .arrow_function_expression, .method_definition => {},
                else => continue,
            }
            const function_owner = self.scope_owner_map.get(@intCast(raw)) orelse continue;
            if (function_owner >= self.scopes.len or self.scopes[function_owner].subtree_has_direct_eval or self.scopes[function_owner].subtree_has_with) continue;
            const body = self.ast.functionBodyBlock(function) orelse continue;
            // Parameter-expression functions have a distinct actual body
            // execution owner; body lexicals do not belong to the parameter
            // environment attached to the function syntax itself.
            var owner = function_owner;
            if (self.scope_owner_map.get(@backingInt(body))) |body_owner| {
                if (body_owner < self.scopes.len and self.scopes[body_owner].kind == .function) owner = body_owner;
            }
            const source_scope = self.scopes[owner];
            if (source_scope.kind != .function or source_scope.subtree_has_direct_eval or source_scope.subtree_has_with) continue;
            try executions.put(allocator, owner, {});
            try plan.registerBody(self, body, owner);
        }
        for (0..self.parser_node_count) |raw| {
            const node = self.ast.nodes.items[raw];
            if (node.tag != .block_statement) continue;
            const owner = self.scope_owner_map.get(@intCast(raw)) orelse continue;
            if (owner >= self.scopes.len or (self.scopes[owner].kind != .block and self.scopes[owner].kind != .catch_clause)) continue;
            const execution = scope_mod.enclosingExecUnit(self.scopes, @fromBackingInt(owner)) orelse continue;
            if (!executions.contains(execution)) continue;
            try plan.registerBody(self, @fromBackingInt(@intCast(raw)), owner);
        }
        for (0..self.parser_node_count) |raw| {
            const node = self.ast.nodes.items[raw];
            if (node.tag != .catch_clause or node.data.binary.left.isNone()) continue;
            const pattern = self.ast.getNode(node.data.binary.left);
            if (pattern.tag != .object_pattern and pattern.tag != .array_pattern) continue;
            const owner = self.scope_owner_map.get(@intCast(raw)) orelse continue;
            if (owner >= self.scopes.len or self.scopes[owner].kind != .catch_clause) continue;
            const execution = scope_mod.enclosingExecUnit(self.scopes, @fromBackingInt(owner)) orelse continue;
            if (!executions.contains(execution)) continue;
            const clause: NodeIndex = @fromBackingInt(@as(u32, @intCast(raw)));
            try plan.registerPattern(self, node.data.binary.left, owner, clause, pattern.span.end, true);
            try plan.catch_patterns.put(allocator, @intCast(raw), node.data.binary.left);
        }
        // Case declarations share one lexical environment, but a matching
        // branch may bypass any earlier InitializeBinding operation.
        for (0..self.parser_node_count) |raw| {
            const node = self.ast.nodes.items[raw];
            if (node.tag != .switch_statement) continue;
            const owner = self.scope_owner_map.get(@intCast(raw)) orelse continue;
            if (owner >= self.scopes.len or self.scopes[owner].kind != .switch_block) continue;
            const execution = scope_mod.enclosingExecUnit(self.scopes, @fromBackingInt(owner)) orelse continue;
            if (!executions.contains(execution)) continue;
            const start = self.readU32(node.data.extra, 1);
            const len = self.readU32(node.data.extra, 2);
            var first_test: ?NodeIndex = null;
            var default_case: ?NodeIndex = null;
            for (0..len) |offset| {
                const case_idx = self.ast.readExtraNode(start, @intCast(offset));
                const case = self.ast.getNode(case_idx);
                if (case.tag != .switch_case) continue;
                const test_node = self.ast.readExtraNode(case.data.extra, 0);
                if (test_node.isNone()) {
                    default_case = case_idx;
                } else if (first_test == null) first_test = case_idx;
                const stmts = self.readU32(case.data.extra, 1);
                const count = self.readU32(case.data.extra, 2);
                for (0..count) |index|
                    try plan.registerDeclaration(self, self.ast.getNode(self.ast.readExtraNode(stmts, @intCast(index))), owner, @fromBackingInt(@as(u32, @intCast(raw))), true);
            }
            const source_switch: NodeIndex = @fromBackingInt(@as(u32, @intCast(raw)));
            if (first_test) |case_idx| {
                try plan.switch_first_test.put(allocator, @backingInt(case_idx), source_switch);
            } else if (default_case) |case_idx| {
                try plan.switch_only_default.put(allocator, @backingInt(case_idx), source_switch);
            }
        }
        // Header bindings belong to the source loop environment. Ordinary
        // loops and suspension ready-declaration plans share this exact list.
        for (0..self.parser_node_count) |raw| {
            const loop = self.ast.nodes.items[raw];
            if (loop.tag != .for_statement) continue;
            const owner = self.scope_owner_map.get(@intCast(raw)) orelse continue;
            if (owner >= self.scopes.len) continue;
            const execution = scope_mod.enclosingExecUnit(self.scopes, @fromBackingInt(owner)) orelse continue;
            if (!executions.contains(execution)) continue;
            const header = self.ast.readExtraNode(loop.data.extra, 0);
            if (header.isNone()) continue;
            const declaration = self.ast.getNode(header);
            if (declaration.tag != .variable_declaration or !self.ast.variableDeclarationKind(declaration).isLexical()) continue;
            const start = self.readU32(declaration.data.extra, 1);
            const len = self.readU32(declaration.data.extra, 2);
            if (len == 0) continue;
            const first_declarator = self.ast.getNode(self.ast.readExtraNode(start, 0));
            const first_pattern = self.ast.readExtraNode(first_declarator.data.extra, 0);
            try plan.header_first_bindings.put(allocator, @backingInt(header), first_pattern);
            try plan.header_by_first_binding.put(allocator, @backingInt(first_pattern), header);
            try plan.registerDeclaration(self, declaration, owner, header, false);
        }

        var source_value_references: std.AutoHashMapUnmanaged(u32, u32) = .empty;
        for (self.references) |reference| {
            if (reference.symbol_id.isNone() or reference.node_index.isNone() or reference.flags.declare or reference.flags.type_context or reference.flags.value_as_type) continue;
            try source_value_references.put(allocator, @backingInt(reference.node_index), @backingInt(reference.symbol_id));
        }
        // For-in/of RHS closures capture a distinct, permanently
        // uninitialized head environment, not an iteration's initialized cell.
        for (0..self.parser_node_count) |raw| {
            const loop = self.ast.nodes.items[raw];
            if (loop.tag != .for_in_statement and loop.tag != .for_of_statement and loop.tag != .for_await_of_statement) continue;
            const owner = self.scope_owner_map.get(@intCast(raw)) orelse continue;
            if (owner >= self.scopes.len) continue;
            const execution = scope_mod.enclosingExecUnit(self.scopes, @fromBackingInt(owner)) orelse continue;
            if (!executions.contains(execution)) continue;
            const head = self.ast.getNode(loop.data.ternary.a);
            if (head.tag != .variable_declaration or !self.ast.variableDeclarationKind(head).isLexical()) continue;
            const start = self.readU32(head.data.extra, 1);
            const count = self.readU32(head.data.extra, 2);
            var bindings: std.AutoHashMapUnmanaged(u32, NodeIndex) = .empty;
            for (0..count) |index| {
                const item = self.ast.getNode(self.ast.readExtraNode(start, @intCast(index)));
                if (item.tag != .variable_declarator) continue;
                const binding = self.ast.readExtraNode(item.data.extra, 0);
                const binding_tag = self.ast.getNode(binding).tag;
                if (binding_tag == .array_pattern or binding_tag == .object_pattern)
                    try plan.registerPattern(self, binding, owner, @fromBackingInt(@as(u32, @intCast(raw))), item.span.end, false);
                var leaves = try @import("../parser/ast_walk.zig").bindingIdentifiers(allocator, self.ast, binding, .{});
                defer leaves.deinit();
                while (try leaves.next()) |leaf| {
                    if (self.ast.getNode(leaf).tag != .binding_identifier) continue;
                    const sid = self.getSymbolIdAt(leaf) orelse continue;
                    if (sid >= self.symbols.len or self.symbols[sid].scope_id.toIndex() != owner) continue;
                    try bindings.put(allocator, sid, leaf);
                }
            }
            if (bindings.count() == 0) continue;
            var live: std.AutoHashMapUnmanaged(u32, void) = .empty;
            var pending: std.ArrayList(NodeIndex) = .empty;
            try pending.append(allocator, loop.data.ternary.b);
            while (pending.pop()) |node| {
                if (node.isNone()) continue;
                const node_raw = @backingInt(node);
                if (live.contains(node_raw)) continue;
                try live.put(allocator, node_raw, {});
                var children = @import("../parser/ast_walk.zig").children(self.ast, self.ast.getNode(node));
                while (children.next()) |child| try pending.append(allocator, child);
            }
            var rhs_nodes = live.keyIterator();
            while (rhs_nodes.next()) |node_raw_ptr| {
                const node_raw = node_raw_ptr.*;
                const sid = source_value_references.get(node_raw) orelse continue;
                const binding = bindings.get(sid) orelse continue;
                const role: IterableReference = .{ .symbol = sid, .binding = binding };
                const entry = try plan.iterable_references.getOrPut(allocator, node_raw);
                if (entry.found_existing and !std.meta.eql(entry.value_ptr.*, role)) @panic("iterable TDZ reference has conflicting source owners");
                entry.value_ptr.* = role;
            }
        }
        for (0..self.parser_node_count) |raw| {
            const node = self.ast.nodes.items[raw];
            if (node.tag == .update_expression) {
                const operand = self.ast.readExtraNode(node.data.extra, 0);
                const operand_tag = self.ast.getNode(operand).tag;
                if (operand_tag == .assignment_target_identifier or operand_tag == .identifier_reference)
                    try plan.assignments.put(allocator, @backingInt(operand), {});
                continue;
            }
            if (node.tag != .assignment_expression) continue;
            if (node.data.binary.flags != 0 and node.data.binary.flags != @backingInt(Kind.eq) and
                compoundOperator(node.data.binary.flags) == null and logicalOperator(node.data.binary.flags) == null) continue;
            const target = node.data.binary.left;
            switch (self.ast.getNode(target).tag) {
                .assignment_target_identifier => try plan.assignments.put(allocator, @backingInt(target), {}),
                .array_assignment_target, .object_assignment_target, .array_pattern, .object_pattern => {
                    // Select actual write leaves from the source target tree;
                    // computed keys/default RHS are not binding targets.
                    var leaves = try @import("../parser/ast_walk.zig").bindingIdentifiers(allocator, self.ast, target, .{});
                    defer leaves.deinit();
                    while (try leaves.next()) |leaf| try plan.assignments.put(allocator, @backingInt(leaf), {});
                },
                else => {},
            }
        }
        for (self.references) |reference| {
            if (reference.symbol_id.isNone() or reference.flags.declare or reference.flags.type_context or reference.flags.value_as_type) continue;
            const sid = @backingInt(reference.symbol_id);
            const cell = plan.cells.getPtr(sid) orelse continue;
            if (reference.node_index.isNone()) continue;
            const raw = @backingInt(reference.node_index);
            if (raw >= self.parser_node_count) continue;
            if (reference.flags.write) {
                if (plan.assignments.contains(raw)) {
                    try plan.writes.put(allocator, raw, reference.scope_id);
                    // Lowering const to mutable storage must preserve PutValue
                    // rejection even when this write follows initialization.
                    if (cell.readonly) cell.demand = true;
                } else cell.written = true;
            }
            const execution = scope_mod.enclosingExecUnit(self.scopes, reference.scope_id);
            const cell_execution = scope_mod.enclosingExecUnit(self.scopes, cell.scope);
            if (execution == null or cell_execution == null or execution.? != cell_execution.? or
                self.ast.getNode(reference.node_index).span.start <= cell.initialization_end) cell.demand = true;
            if (reference.flags.read and !reference.flags.write) try plan.reads.put(allocator, raw, sid);
        }
        // `delete local` does not perform GetValue. In sloppy source it is
        // false even before the lexical declaration; strict source is rejected
        // by the parser. Do not turn it into deletion of a checked call value.
        for (0..self.parser_node_count) |raw| {
            const node = self.ast.nodes.items[raw];
            if (node.tag != .unary_expression) continue;
            if ((self.readU32(node.data.extra, 1) & 0xffff) != @backingInt(@import("../lexer/token.zig").Kind.kw_delete)) continue;
            _ = plan.reads.remove(@backingInt(self.ast.readExtraNode(node.data.extra, 0)));
            _ = plan.iterable_references.remove(@backingInt(self.ast.readExtraNode(node.data.extra, 0)));
        }
        var inferred_names: @import("block_rename_table.zig").Table = .empty;
        var iterator = plan.cells.iterator();
        while (iterator.next()) |entry| {
            if (!entry.value_ptr.demand or entry.value_ptr.written) continue;
            try self.prepareLexicalTDZStorage(entry.value_ptr.binding, entry.value_ptr.scope);
            const body = try plan.bodies.getOrPut(allocator, @backingInt(entry.value_ptr.body));
            if (!body.found_existing) body.value_ptr.* = .empty;
            try body.value_ptr.append(allocator, entry.key_ptr.*);
            try inferred_names.put(allocator, entry.key_ptr.*, {});
        }
        var module_cells = plan.cells.iterator();
        while (module_cells.next()) |entry| {
            if (try @import("module_lexical_initialization.zig").prepare(self, entry.value_ptr.binding)) |flag| {
                try plan.module_flags.put(allocator, entry.key_ptr.*, flag);
                self.runtime_helpers.tdz = true;
            }
        }
        try @import("module_lexical_initialization.zig").prepareClasses(self, plan);
        try @import("module_lexical_initialization.zig").prepareFacades(self, plan);
        // A reset sequence wraps the first header initializer even when only
        // a later binding needs TDZ storage. Preserve that original binding's
        // NamedEvaluation through the common inferred-name producer as well.
        var headers = plan.header_first_bindings.iterator();
        while (headers.next()) |header| {
            if (!plan.bodies.contains(header.key_ptr.*)) continue;
            // A destructuring head has no single NamedEvaluation name.
            if (self.ast.getNode(header.value_ptr.*).tag == .binding_identifier) {
                const sid = self.getSymbolIdAt(header.value_ptr.*) orelse @panic("TDZ first header binding lost identity");
                try inferred_names.put(allocator, sid, {});
            }
        }
        var iterable = plan.iterable_references.valueIterator();
        while (iterable.next()) |role| try inferred_names.put(allocator, role.symbol, {});
        // Moving assignment RHS into a checked-write argument must not infer
        // the helper/temp name for an anonymous function or class.
        try @import("parameter_environment.zig").collectInferredNames(self, &inferred_names);
    }
};

pub fn read(self: anytype, source: NodeIndex, value: NodeIndex) !NodeIndex {
    const plan = self.lexical_tdz_plan orelse return value;
    if (plan.iterable_references.get(@backingInt(source))) |role| {
        try consumeIterableReference(self, source, role);
        if (value != source) try self.removeSemanticReference(value);
        return iterableFailure(self, role, self.ast.getNode(source).span);
    }
    const sid = plan.reads.get(@backingInt(source)) orelse return value;
    const cell = plan.cells.get(sid) orelse return value;
    if (!cell.demand or cell.written) return value;
    // The original value reference is retained as an argument. The helper owns
    // its own SID; it must never replace the user's value-reference identity.
    const name = try helpers.buildQuotedKeyLiteral(self, self.ast.getNode(cell.binding).data.string_ref);
    self.runtime_helpers.tdz = true;
    return helpers.makeCallExpr(self, try helpers.makeRuntimeHelperRef(self, "__tdz"), &.{ name, value }, self.ast.getNode(source).span);
}

pub fn assignment(self: anytype, source: NodeIndex) !?NodeIndex {
    const plan = self.lexical_tdz_plan orelse return null;
    const node = self.ast.getNode(source);
    const target = node.data.binary.left;
    if (plan.iterable_references.get(@backingInt(target))) |role| {
        // PutValue follows RHS for simple assignment; every compound/logical
        // operation first performs GetValue and therefore throws before RHS.
        const right = try self.visitNode(node.data.binary.right);
        try consumeIterableReference(self, target, role);
        const failure = try iterableFailure(self, role, node.span);
        const simple = node.data.binary.flags == 0 or node.data.binary.flags == @backingInt(Kind.eq);
        const expressions: [2]NodeIndex = if (simple) .{ right, failure } else .{ failure, right };
        return try self.ast.addNode(.{ .tag = .sequence_expression, .span = node.span, .data = .{ .list = try self.ast.addNodeList(&expressions) } });
    }
    if (!plan.writes.contains(@backingInt(target))) return null;
    const sid = self.getSymbolIdAt(target) orelse return null;
    // Consume the existing write's actual scope after any prior region move;
    // neither the source plan nor a pending collector scope selects this use.
    const reference_scope = try self.sourceWriteUseScope(target, sid);
    const cell = plan.cells.get(sid) orelse return null;
    if (!cell.demand or cell.written) return null;
    if (logicalOperator(node.data.binary.flags)) |operator| {
        const prepared = (try helpers.prepareAssignmentTargetRef(self, target, node.span)) orelse unreachable;
        helpers.retagAssignmentTargetAsReference(self, prepared.read);
        try self.splitLogicalAssignmentIdentifierReferences(prepared.read, null, prepared.write);
        try helpers.trackAssignmentTargetRefs(self, prepared, false, true);
        const name = try helpers.buildQuotedKeyLiteral(self, self.ast.getNode(cell.binding).data.string_ref);
        self.runtime_helpers.tdz = true;
        const checked_read = try helpers.makeCallExpr(self, try helpers.makeRuntimeHelperRef(self, "__tdz"), &.{ name, prepared.read }, node.span);
        const value = try self.visitNode(node.data.binary.right);
        const checked_write = try writeCheck(self, cell, reference_scope, value, node.span);
        const assign = try helpers.makeAssignExpr(self, prepared.write, checked_write, node.span, @backingInt(Kind.eq));
        if (operator == .question2 and self.options.unsupported.nullish_coalescing) {
            // A checked read is a call, not a duplicable identifier. Capture
            // its value once using the existing exact temp producer protocol.
            const captured = try helpers.captureToTrackedTemp(self, checked_read, node.span);
            const condition = try helpers.makeNeqNull(self, captured.paren_assign, node.span);
            const retained = try helpers.makeCapturedTempRef(self, captured, node.span, .{ .read = true });
            return try self.ast.addNode(.{ .tag = .conditional_expression, .span = node.span, .data = .{ .ternary = .{ .a = condition, .b = retained, .c = assign } } });
        }
        return try self.ast.addNode(.{ .tag = .logical_expression, .span = node.span, .data = .{ .binary = .{ .left = checked_read, .right = assign, .flags = @backingInt(operator) } } });
    }
    var emitted_target: NodeIndex = undefined;
    var value: NodeIndex = undefined;
    if (compoundOperator(node.data.binary.flags)) |operator| {
        const prepared = (try helpers.prepareAssignmentTargetRef(self, target, node.span)) orelse unreachable;
        try helpers.trackAssignmentTargetRefs(self, prepared, true, false);
        helpers.retagAssignmentTargetAsReference(self, prepared.value);
        try self.splitCompoundAssignmentIdentifierReference(prepared.read, prepared.value);
        emitted_target = prepared.read;
        const display = try helpers.buildQuotedKeyLiteral(self, self.ast.getNode(cell.binding).data.string_ref);
        self.runtime_helpers.tdz = true;
        const checked_left = try helpers.makeCallExpr(self, try helpers.makeRuntimeHelperRef(self, "__tdz"), &.{ display, prepared.value }, node.span);
        const right = try self.visitNode(node.data.binary.right);
        value = if (operator == .star2 and self.options.unsupported.exponentiation)
            try helpers.makeMathPowCall(self, checked_left, right, node.span)
        else
            try self.ast.addNode(.{ .tag = .binary_expression, .span = node.span, .data = .{ .binary = .{
                .left = checked_left,
                .right = right,
                .flags = @backingInt(operator),
            } } });
    } else {
        emitted_target = try self.visitNode(target);
        value = try self.visitNode(node.data.binary.right);
    }
    const checked = try writeCheck(self, cell, reference_scope, value, node.span);
    return try helpers.makeAssignExpr(self, emitted_target, checked, node.span, @backingInt(Kind.eq));
}

/// A user assignment pattern performs PutValue, unlike a declaration's
/// InitializeBinding. The common iterator builder supplies the original
/// target before consuming its reference and the already prepared RHS once.
/// A complete expression also represents a permanently uninitialized iterable
/// head without materializing an unreachable, incorrectly rebound target.
pub fn patternPutValue(self: anytype, source_target: NodeIndex, value: NodeIndex, use_scope: ScopeId) !?NodeIndex {
    const plan = self.lexical_tdz_plan orelse return null;
    const node = self.ast.getNode(source_target);
    if (plan.iterable_references.get(@backingInt(source_target))) |role| {
        try consumeIterableReference(self, source_target, role);
        const failure = try iterableFailure(self, role, node.span);
        return try self.ast.addNode(.{ .tag = .sequence_expression, .span = node.span, .data = .{ .list = try self.ast.addNodeList(&.{ value, failure }) } });
    }
    if (!plan.writes.contains(@backingInt(source_target))) return null;
    const sid = self.getSymbolIdAt(source_target) orelse @panic("pattern PutValue lost its original source SymbolId");
    const cell = plan.cells.get(sid) orelse return null;
    if (!cell.demand or cell.written) return null;
    const target = try self.visitNode(source_target);
    const checked = try writeCheck(self, cell, use_scope, value, node.span);
    return try helpers.makeAssignExpr(self, target, checked, node.span, @backingInt(Kind.eq));
}

fn writeCheck(self: anytype, cell: Cell, reference_scope: ScopeId, value: NodeIndex, span: @import("../lexer/token.zig").Span) !NodeIndex {
    const selected_name = if (self.tableRenameOf(cell.binding)) |selected| try self.ast.addString(selected) else self.ast.getNode(cell.binding).data.string_ref;
    const current = try self.makeIdentifierRefWithSymbolAt(selected_name, span, cell.binding);
    try self.trackUserReadFromBinding(current, cell.binding, reference_scope);
    const name = try helpers.buildQuotedKeyLiteral(self, self.ast.getNode(cell.binding).data.string_ref);
    const readonly = try helpers.makeBoolLiteral(self, cell.readonly);
    self.runtime_helpers.tdz = true;
    // Argument evaluation is left-to-right: RHS first, then the current cell.
    // A callback in the RHS can therefore change initialization state before
    // PutValue, without duplicating the RHS or capturing a stale checked read.
    return helpers.makeCallExpr(self, try helpers.makeRuntimeHelperRef(self, "__tdz"), &.{ name, value, readonly, current }, span);
}

pub fn update(self: anytype, source: NodeIndex) !?NodeIndex {
    const plan = self.lexical_tdz_plan orelse return null;
    const node = self.ast.getNode(source);
    const operand = self.ast.readExtraNode(node.data.extra, 0);
    if (plan.iterable_references.get(@backingInt(operand))) |role| {
        try consumeIterableReference(self, operand, role);
        return try iterableFailure(self, role, node.span);
    }
    if (!plan.writes.contains(@backingInt(operand))) return null;
    const sid = self.getSymbolIdAt(operand) orelse return null;
    const reference_scope = try self.sourceWriteUseScope(operand, sid);
    const cell = plan.cells.get(sid) orelse return null;
    if (!cell.demand or cell.written) return null;
    const prepared = (try helpers.prepareAssignmentTargetRef(self, operand, node.span)) orelse unreachable;
    try helpers.trackAssignmentTargetRefs(self, prepared, true, false);
    helpers.retagAssignmentTargetAsReference(self, prepared.value);
    try self.splitCompoundAssignmentIdentifierReference(prepared.read, prepared.value);
    const display = try helpers.buildQuotedKeyLiteral(self, self.ast.getNode(cell.binding).data.string_ref);
    self.runtime_helpers.tdz = true;
    const checked = try helpers.makeCallExpr(self, try helpers.makeRuntimeHelperRef(self, "__tdz"), &.{ display, prepared.value }, node.span);
    const current = try helpers.captureToTrackedTemp(self, checked, node.span);
    const current_update = try helpers.makeCapturedTempRef(self, current, node.span, .{ .read = true, .write = true });
    const update_extra = try self.ast.addExtras(&.{ @backingInt(current_update), self.readU32(node.data.extra, 1) });
    // Apply the original update operator to a private cell. This preserves
    // ToNumeric (including objects/BigInt), and does not mutate a const source
    // cell before its required PutValue TypeError.
    const numeric_update = try self.ast.addNode(.{ .tag = .update_expression, .span = node.span, .data = .{ .extra = update_extra } });
    const result = try helpers.captureToTrackedTemp(self, numeric_update, node.span);
    const updated = try helpers.makeCapturedTempRef(self, current, node.span, .{ .read = true });
    const put_value = try helpers.makeAssignExpr(self, prepared.read, try writeCheck(self, cell, reference_scope, updated, node.span), node.span, @backingInt(Kind.eq));
    const returned = try helpers.makeCapturedTempRef(self, result, node.span, .{ .read = true });
    return try self.ast.addNode(.{ .tag = .sequence_expression, .span = node.span, .data = .{ .list = try self.ast.addNodeList(&.{ current.paren_assign, result.paren_assign, put_value, returned }) } });
}

test "legacy lexical TDZ ordinary function source cells preserve early closure reads and initialized undefined" {
    const sources = [_][]const u8{
        "function f(){console.log(g());const k=1;function g(){return typeof k}}try{f()}catch(e){console.log(e.name)}",
        "function f(){return k;let k=42}try{f()}catch(e){console.log(e.name)}",
        "function f(){const k=k;return k}try{f()}catch(e){console.log(e.name)}",
        "function f(){let k;function g(){return k}return g()}console.log(String(f()))",
        "function f(){const k=void 0;function g(){return typeof k}return g()}console.log(f())",
        "function f(early){function g(){return k}if(early)return g();const k=42;return g()}console.log(f(false));try{f(true)}catch(e){console.log(e.name)}console.log(f(false))",
        "function f(){'use strict';function g(){return this}const k=42;function read(){return k}return [g()===void 0,read()]}console.log(JSON.stringify(f()))",
        "function f(){const k=42;function g(){const k=7;return k}function h(){return k}return [g(),h()]}console.log(JSON.stringify(f()))",
        "function f(){function g(){return typeof k}const k=42;return [g(),k]}console.log(JSON.stringify(f()))",
        "function f(){try{return typeof k}catch(e){return e.name}let k}console.log(f())",
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    for (sources) |source| {
        const native = try std.process.run(allocator, std.testing.io, .{ .argv = &.{ "node", "-e", source } });
        try std.testing.expect(native.term == .exited and native.term.exited == 0);
        for ([_]bool{ false, true }) |full| {
            const output = try @import("../transpile.zig").transpile(allocator, source, "input.cjs", .{
                .unsupported = @import("compat.zig").fromESTarget(.es5),
                .minify_syntax = full,
                .minify_identifiers = full,
                .minify_whitespace = full,
            });
            const actual = try std.process.run(allocator, std.testing.io, .{ .argv = &.{ "node", "-e", output.code } });
            if (actual.term != .exited or actual.term.exited != 0 or !std.mem.eql(u8, native.stdout, actual.stdout))
                std.debug.print("lexical TDZ full={} source={s}\noutput={s}\nstderr={s}\nexpected={s} actual={s}\n", .{ full, source, output.code, actual.stderr, native.stdout, actual.stdout });
            try std.testing.expect(actual.term == .exited and actual.term.exited == 0);
            try std.testing.expectEqualStrings(native.stdout, actual.stdout);
        }
    }
}

test "legacy lexical TDZ runtime distinguishes initialized undefined and preserves checked write order" {
    const runtime = @import("../bundler/runtime_helpers.zig");
    const body =
        \\var events=[],cell=__tdz;
        \\function observe(fn){try{return fn()}catch(error){return error.name}}
        \\events.push(observe(function(){return __tdz('cell')}));
        \\events.push(observe(function(){return __tdz('cell',cell)}));
        \\cell=void 0;events.push(String(__tdz('cell',cell)));
        \\cell=42;events.push(__tdz('cell',cell));
        \\events.push(observe(function(){return __tdz('cell',cell,true)}));
        \\cell=__tdz;
        \\events.push(observe(function(){var rhs=(events.push('rhs'),7);__tdz('cell',cell);cell=rhs}));
        \\events.push(observe(function(){var old=__tdz('cell',cell);events.push('not-reached');return old}));
        \\console.log(JSON.stringify(events));
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source = try std.mem.concat(allocator, u8, &.{ runtime.TDZ_RUNTIME, body });
    const actual = try std.process.run(allocator, std.testing.io, .{ .argv = &.{ "node", "-e", source } });
    try std.testing.expect(actual.term == .exited and actual.term.exited == 0);
    try std.testing.expectEqualStrings("[\"ReferenceError\",\"ReferenceError\",\"undefined\",42,\"TypeError\",\"rhs\",\"ReferenceError\",\"ReferenceError\"]\n", actual.stdout);
}

test "legacy lexical TDZ using handoff throws before registration and retains normal disposal" {
    const sources = [_][]const u8{
        "const log=[];function f(){log.push(g());using a={[Symbol.dispose](){log.push('disposed')}};const k=1;function g(){return 'g'+typeof k}}try{f()}catch(e){log.push(e.name)}console.log(log.join())",
        "const log=[];function f(){using a={[Symbol.dispose](){log.push('disposed')}};const k=42;function g(){return k}log.push(g())}f();console.log(log.join())",
    };
    const expected = [_][]const u8{ "ReferenceError\n", "42,disposed\n" };
    const compat = @import("compat.zig");
    const profiles = [_]compat.UnsupportedFeatures{ compat.fromESTarget(.es5), compat.fromReactNativeVersion(0, 76) };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    for (sources, expected) |source, expected_stdout| {
        const native = try std.process.run(allocator, std.testing.io, .{ .argv = &.{ "node", "-e", source } });
        try std.testing.expect(native.term == .exited and native.term.exited == 0);
        try std.testing.expectEqualStrings(expected_stdout, native.stdout);
        for (profiles) |unsupported| {
            try std.testing.expect(unsupported.block_scoping);
            for ([_]bool{ false, true }) |full| {
                const output = try @import("../transpile.zig").transpile(allocator, source, "input.cjs", .{
                    .unsupported = unsupported,
                    .minify_syntax = full,
                    .minify_identifiers = full,
                    .minify_whitespace = full,
                });
                const actual = try std.process.run(allocator, std.testing.io, .{ .argv = &.{ "node", "-e", output.code } });
                if (actual.term != .exited or actual.term.exited != 0 or !std.mem.eql(u8, native.stdout, actual.stdout))
                    std.debug.print("lexical TDZ using full={} source={s}\noutput={s}\nstderr={s}\nexpected={s} actual={s}\n", .{ full, source, output.code, actual.stderr, native.stdout, actual.stdout });
                try std.testing.expect(actual.term == .exited and actual.term.exited == 0);
                try std.testing.expectEqualStrings(native.stdout, actual.stdout);
            }
        }
    }
}

test "legacy lexical TDZ simple PutValue evaluates RHS before current cell check" {
    const sources = [_][]const u8{
        "function f(){var log=[];try{k=(log.push('rhs'),42)}catch(e){log.push(e.name)}let k=7;return [log,k]}console.log(JSON.stringify(f()))",
        "function f(){var log=[];try{k=(log.push('rhs'),42)}catch(e){log.push(e.name)}const k=7;return [log,k]}console.log(JSON.stringify(f()))",
        "function f(){const k=42;function write(){k=7}try{write()}catch(e){return [e.name,k]}}console.log(JSON.stringify(f()))",
        "function f(){let k=42;function write(){return k=7}return [write(),k]}console.log(JSON.stringify(f()))",
        "function f(){let k=42;function write(){k=void 0}write();return [typeof k,String(k)]}console.log(JSON.stringify(f()))",
        "function f(){function write(){k=42}try{write()}catch(e){return e.name}let k}console.log(f())",
        "function f(){let k;function write(){k=function(){}}write();return [k.name,k()]}console.log(JSON.stringify(f()))",
        "function f(){let k=42;function write(k){k=7;return k}function read(){return k}return [write(1),read()]}console.log(JSON.stringify(f()))",
        "function f(depth){function write(){k=7}if(depth){var other=f(0);try{write()}catch(e){return [other,e.name]}}let k=42;write();return k}console.log(JSON.stringify(f(1)))",
        "function f(){function* write(){k=yield 'rhs'}var iterator=write();var first=iterator.next();let k=42;var last=iterator.next(7);return [first,last,k]}console.log(JSON.stringify(f()))",
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    for (sources) |source| {
        const native = try std.process.run(allocator, std.testing.io, .{ .argv = &.{ "node", "-e", source } });
        try std.testing.expect(native.term == .exited and native.term.exited == 0);
        for ([_]bool{ false, true }) |full| {
            const output = try @import("../transpile.zig").transpile(allocator, source, "input.cjs", .{
                .unsupported = @import("compat.zig").fromESTarget(.es5),
                .minify_syntax = full,
                .minify_identifiers = full,
                .minify_whitespace = full,
            });
            const actual = try std.process.run(allocator, std.testing.io, .{ .argv = &.{ "node", "-e", output.code } });
            if (actual.term != .exited or actual.term.exited != 0 or !std.mem.eql(u8, native.stdout, actual.stdout))
                std.debug.print("lexical TDZ PutValue full={} source={s}\noutput={s}\nstderr={s}\nexpected={s} actual={s}\n", .{ full, source, output.code, actual.stderr, native.stdout, actual.stdout });
            try std.testing.expect(actual.term == .exited and actual.term.exited == 0);
            try std.testing.expectEqualStrings(native.stdout, actual.stdout);
        }
    }
}

test "legacy lexical TDZ runtime constructors and helper local cannot be captured by source names" {
    const sources = [_][]const u8{
        "const ReferenceError=class Wrong extends Error{};function f(){return g();const k=1;function g(){return typeof k}}try{f()}catch(e){console.log(JSON.stringify([e instanceof globalThis.ReferenceError,e instanceof ReferenceError]))}",
        "const TypeError=class Wrong extends Error{};function f(){const k=42;function write(){k=7}try{write()}catch(e){return [e instanceof globalThis.TypeError,e instanceof TypeError,k]}}console.log(JSON.stringify(f()))",
        "const __tdz=42;function f(){return g();const k=1;function g(){return typeof k}}try{f()}catch(e){console.log(JSON.stringify([e.name,__tdz]))}",
    };
    const expected = [_][]const u8{ "[true,false]\n", "[true,false,42]\n", "[\"ReferenceError\",42]\n" };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    for (sources, expected) |source, stdout| {
        const native = try std.process.run(allocator, std.testing.io, .{ .argv = &.{ "node", "-e", source } });
        try std.testing.expect(native.term == .exited and native.term.exited == 0);
        try std.testing.expectEqualStrings(stdout, native.stdout);
        for ([_]bool{ false, true }) |full| {
            const output = try @import("../transpile.zig").transpile(allocator, source, "input.cjs", .{
                .unsupported = @import("compat.zig").fromESTarget(.es5),
                .minify_syntax = full,
                .minify_identifiers = full,
                .minify_whitespace = full,
            });
            const actual = try std.process.run(allocator, std.testing.io, .{ .argv = &.{ "node", "-e", output.code } });
            if (actual.term != .exited or actual.term.exited != 0 or !std.mem.eql(u8, native.stdout, actual.stdout))
                std.debug.print("lexical TDZ source-name capture full={} source={s}\noutput={s}\nstderr={s}\nexpected={s} actual={s}\n", .{ full, source, output.code, actual.stderr, native.stdout, actual.stdout });
            try std.testing.expect(actual.term == .exited and actual.term.exited == 0);
            try std.testing.expectEqualStrings(native.stdout, actual.stdout);
        }
    }
}

test "legacy lexical TDZ compound GetValue precedes RHS and const PutValue follows coercion" {
    const sources = [_][]const u8{
        "function f(){var log=[];try{k+=(log.push('rhs'),7)}catch(e){log.push(e.name)}let k=42;return log}console.log(JSON.stringify(f()))",
        "function f(){var log=[];try{k**=(log.push('rhs'),2)}catch(e){log.push(e.name)}const k=42;return log}console.log(JSON.stringify(f()))",
        "function f(){var log=[];const k={valueOf(){log.push('left');return 2}};function write(){k+=(log.push('rhs'),{valueOf(){log.push('right');return 3}})}try{write()}catch(e){log.push(e.name)}return [log,typeof k]}console.log(JSON.stringify(f()))",
        "function f(){const k=42;function write(){k+=Symbol('bad')}try{write()}catch(e){return [e.name,k]}}console.log(JSON.stringify(f()))",
        "function f(){let k=2;function write(){k+=3;k*=4;k-=1;k/=3;k%=5;return k}return [write(),k]}console.log(JSON.stringify(f()))",
        "function f(){let k=7;function write(){k&=6;k|=8;k^=3;k<<=1;k>>=1;k>>>=1;return k}return [write(),k]}console.log(JSON.stringify(f()))",
        "function f(){let k=2;function write(){return k**=3}return [write(),k]}console.log(JSON.stringify(f()))",
        "function f(){let k=2;function write(){k+=(k=10,3)}write();return k}console.log(f())",
        "function f(){let k=2;function* write(){k+=yield 'rhs'}var iterator=write();var first=iterator.next();k=10;var last=iterator.next(3);return [first,last,k]}console.log(JSON.stringify(f()))",
        "function f(){let k='x';function write(){return k+=1}return [write(),k]}console.log(JSON.stringify(f()))",
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    for (sources) |source| {
        const native = try std.process.run(allocator, std.testing.io, .{ .argv = &.{ "node", "-e", source } });
        try std.testing.expect(native.term == .exited and native.term.exited == 0);
        for ([_]bool{ false, true }) |full| {
            const output = try @import("../transpile.zig").transpile(allocator, source, "input.cjs", .{
                .unsupported = @import("compat.zig").fromESTarget(.es5),
                .minify_syntax = full,
                .minify_identifiers = full,
                .minify_whitespace = full,
            });
            const actual = try std.process.run(allocator, std.testing.io, .{ .argv = &.{ "node", "-e", output.code } });
            if (actual.term != .exited or actual.term.exited != 0 or !std.mem.eql(u8, native.stdout, actual.stdout))
                std.debug.print("lexical TDZ compound full={} source={s}\noutput={s}\nstderr={s}\nexpected={s} actual={s}\n", .{ full, source, output.code, actual.stderr, native.stdout, actual.stdout });
            try std.testing.expect(actual.term == .exited and actual.term.exited == 0);
            try std.testing.expectEqualStrings(native.stdout, actual.stdout);
        }
    }
}

test "legacy lexical TDZ logical assignments check GetValue and retain lazy PutValue" {
    const sources = [_][]const u8{
        "function f(){var log=[];try{k&&=(log.push('rhs'),7)}catch(e){log.push(e.name)}let k=42;return log}console.log(JSON.stringify(f()))",
        "function f(){var log=[];try{k||=(log.push('rhs'),7)}catch(e){log.push(e.name)}let k=42;return log}console.log(JSON.stringify(f()))",
        "function f(){var log=[];try{k??=(log.push('rhs'),7)}catch(e){log.push(e.name)}let k=42;return log}console.log(JSON.stringify(f()))",
        "function f(){var log=[];const k=0;function write(){return k&&=(log.push('rhs'),7)}return [write(),k,log]}console.log(JSON.stringify(f()))",
        "function f(){var log=[];const k=42;function write(){return k||=(log.push('rhs'),7)}return [write(),k,log]}console.log(JSON.stringify(f()))",
        "function f(){var log=[];const k=false;function write(){return k??=(log.push('rhs'),7)}return [write(),k,log]}console.log(JSON.stringify(f()))",
        "function f(){var log=[];const k=void 0;function write(){return k??=(log.push('rhs'),7)}try{write()}catch(e){log.push(e.name)}return [String(k),log]}console.log(JSON.stringify(f()))",
        "function f(){let k=42;function write(){return k&&=(k=10,7)}return [write(),k]}console.log(JSON.stringify(f()))",
        "function f(){let k;function* write(){k??=yield 'rhs'}var iterator=write();var first=iterator.next();k=10;var last=iterator.next(7);return [first,last,k]}console.log(JSON.stringify(f()))",
        "function f(){let k=0;function write(){k||=42;k&&=7;k??=9;return k}return [write(),k]}console.log(JSON.stringify(f()))",
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    for (sources) |source| {
        const native = try std.process.run(allocator, std.testing.io, .{ .argv = &.{ "node", "-e", source } });
        try std.testing.expect(native.term == .exited and native.term.exited == 0);
        for ([_]bool{ false, true }) |full| {
            const output = try @import("../transpile.zig").transpile(allocator, source, "input.cjs", .{
                .unsupported = @import("compat.zig").fromESTarget(.es5),
                .minify_syntax = full,
                .minify_identifiers = full,
                .minify_whitespace = full,
            });
            const actual = try std.process.run(allocator, std.testing.io, .{ .argv = &.{ "node", "-e", output.code } });
            if (actual.term != .exited or actual.term.exited != 0 or !std.mem.eql(u8, native.stdout, actual.stdout))
                std.debug.print("lexical TDZ logical full={} source={s}\noutput={s}\nstderr={s}\nexpected={s} actual={s}\n", .{ full, source, output.code, actual.stderr, native.stdout, actual.stdout });
            try std.testing.expect(actual.term == .exited and actual.term.exited == 0);
            try std.testing.expectEqualStrings(native.stdout, actual.stdout);
        }
    }
}

test "legacy lexical TDZ updates preserve ToNumeric const PutValue and prefix postfix results" {
    const sources = [_][]const u8{
        "function f(){try{return k++}catch(e){return e.name}let k=42}console.log(f())",
        "function f(){try{return --k}catch(e){return e.name}const k=42}console.log(f())",
        "function f(){let k='2';function write(){return [k++,++k,k--,--k]}return [write(),k]}console.log(JSON.stringify(f()))",
        "function f(){const k=42;function write(){return k++}try{write()}catch(e){return [e.name,k]}}console.log(JSON.stringify(f()))",
        "function f(){var log=[];const k={valueOf(){log.push('coerce');return 2}};function write(){return ++k}try{write()}catch(e){log.push(e.name)}return [log,typeof k]}console.log(JSON.stringify(f()))",
        "function f(){let k;function write(){return k++}return [String(write()),String(k)]}console.log(JSON.stringify(f()))",
        "function f(){let k=1n;function write(){return [k++,++k]}return [write().map(String),String(k)]}console.log(JSON.stringify(f()))",
        "function f(){let k={valueOf(){k=10;return 2}};function write(){return k++}return [write(),k]}console.log(JSON.stringify(f()))",
        "function f(){let k=2;function* write(){yield k++;yield ++k}var iterator=write();var first=iterator.next();k=10;var second=iterator.next();return [first,second,k]}console.log(JSON.stringify(f()))",
        "function f(depth){function write(){return ++k}if(depth){var other=f(0);try{write()}catch(e){return [other,e.name]}}let k=42;return write()}console.log(JSON.stringify(f(1)))",
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    for (sources) |source| {
        const native = try std.process.run(allocator, std.testing.io, .{ .argv = &.{ "node", "-e", source } });
        try std.testing.expect(native.term == .exited and native.term.exited == 0);
        for ([_]bool{ false, true }) |full| {
            const output = try @import("../transpile.zig").transpile(allocator, source, "input.cjs", .{
                .unsupported = @import("compat.zig").fromESTarget(.es5),
                .minify_syntax = full,
                .minify_identifiers = full,
                .minify_whitespace = full,
            });
            const actual = try std.process.run(allocator, std.testing.io, .{ .argv = &.{ "node", "-e", output.code } });
            if (actual.term != .exited or actual.term.exited != 0 or !std.mem.eql(u8, native.stdout, actual.stdout))
                std.debug.print("lexical TDZ update full={} source={s}\noutput={s}\nstderr={s}\nexpected={s} actual={s}\n", .{ full, source, output.code, actual.stderr, native.stdout, actual.stdout });
            try std.testing.expect(actual.term == .exited and actual.term.exited == 0);
            try std.testing.expectEqualStrings(native.stdout, actual.stdout);
        }
    }
}

test "legacy lexical TDZ constructor shadow renames retain original source class and function names" {
    const sources = [_][]const u8{
        "const ReferenceError=class{};function f(){return g();const k=1;function g(){return typeof k}}var result=[ReferenceError.name];try{f()}catch(e){result.push(e instanceof globalThis.ReferenceError,e instanceof ReferenceError)}console.log(JSON.stringify(result))",
        "function ReferenceError(){}function f(){return g();const k=1;function g(){return typeof k}}var result=[ReferenceError.name];try{f()}catch(e){result.push(e instanceof globalThis.ReferenceError,e instanceof ReferenceError)}console.log(JSON.stringify(result))",
        "const Object={};function ReferenceError(){}function f(){return g();const k=1;function g(){return typeof k}}var result=[ReferenceError.name];try{f()}catch(e){result.push(e instanceof globalThis.ReferenceError,e instanceof ReferenceError)}console.log(JSON.stringify(result))",
        "const ReferenceError=function(){};function f(){return g();const k=1;function g(){return typeof k}}var result=[ReferenceError.name];try{f()}catch(e){result.push(e instanceof globalThis.ReferenceError,e instanceof ReferenceError)}console.log(JSON.stringify(result))",
        "class ReferenceError{}function f(){return g();const k=1;function g(){return typeof k}}var result=[ReferenceError.name];try{f()}catch(e){result.push(e instanceof globalThis.ReferenceError,e instanceof ReferenceError)}console.log(JSON.stringify(result))",
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    for (sources) |source| {
        const native = try std.process.run(allocator, std.testing.io, .{ .argv = &.{ "node", "--input-type=module", "-e", source } });
        try std.testing.expect(native.term == .exited and native.term.exited == 0);
        try std.testing.expectEqualStrings("[\"ReferenceError\",true,false]\n", native.stdout);
        // Identifier mangling is deliberately disabled: this is source-name
        // preservation during a required compiler rename, not keepNames policy.
        for ([_]bool{ false, true }) |compact| {
            for ([_]bool{ false, true }) |keep_names| {
                const output = try @import("../transpile.zig").transpile(allocator, source, "input.mjs", .{
                    .unsupported = @import("compat.zig").fromESTarget(.es5),
                    .minify_syntax = compact,
                    .minify_identifiers = false,
                    .minify_whitespace = compact,
                    .keep_names = keep_names,
                });
                const actual = try std.process.run(allocator, std.testing.io, .{ .argv = &.{ "node", "--input-type=module", "-e", output.code } });
                if (actual.term != .exited or actual.term.exited != 0 or !std.mem.eql(u8, native.stdout, actual.stdout))
                    std.debug.print("lexical TDZ constructor .name compact={} source={s}\noutput={s}\nstderr={s}\nexpected={s} actual={s}\n", .{ compact, source, output.code, actual.stderr, native.stdout, actual.stdout });
                try std.testing.expect(actual.term == .exited and actual.term.exited == 0);
                try std.testing.expectEqualStrings(native.stdout, actual.stdout);
            }
        }
    }
}

test "legacy lexical TDZ hoisted name restoration preserves program directives hashbang and early reads" {
    const sources = [_][]const u8{
        "'use strict';function ReferenceError(){}function f(){return g();const k=1;function g(){return typeof k}}var out=[ReferenceError.name,(function(){return this})()===void 0];try{f()}catch(e){out.push(e.name)}console.log(JSON.stringify(out))",
        "#!/usr/bin/env node\n'use strict';function ReferenceError(){}function f(){return g();const k=1;function g(){return typeof k}}var out=[ReferenceError.name,(function(){return this})()===void 0];try{f()}catch(e){out.push(e.name)}console.log(JSON.stringify(out))",
        "var out=[read()];function read(){return ReferenceError.name}function ReferenceError(){}function f(){return g();const k=1;function g(){return typeof k}}try{f()}catch(e){out.push(e.name)}console.log(JSON.stringify(out))",
        "var out=[];try{throw ReferenceError.name}catch(name){out.push(name)}function ReferenceError(){}function f(){return g();const k=1;function g(){return typeof k}}try{f()}catch(e){out.push(e.name)}console.log(JSON.stringify(out))",
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    for (sources) |source| {
        const native = try std.process.run(allocator, std.testing.io, .{ .argv = &.{ "node", "-e", source } });
        try std.testing.expect(native.term == .exited and native.term.exited == 0);
        for ([_]bool{ false, true }) |compact| {
            const output = try @import("../transpile.zig").transpile(allocator, source, "input.cjs", .{
                .unsupported = @import("compat.zig").fromESTarget(.es5),
                .minify_syntax = compact,
                .minify_identifiers = false,
                .minify_whitespace = compact,
                .keep_names = false,
            });
            const actual = try std.process.run(allocator, std.testing.io, .{ .argv = &.{ "node", "-e", output.code } });
            if (actual.term != .exited or actual.term.exited != 0 or !std.mem.eql(u8, native.stdout, actual.stdout))
                std.debug.print("lexical TDZ program name compact={} source={s}\noutput={s}\nstderr={s}\nexpected={s} actual={s}\n", .{ compact, source, output.code, actual.stderr, native.stdout, actual.stdout });
            try std.testing.expect(actual.term == .exited and actual.term.exited == 0);
            try std.testing.expectEqualStrings(native.stdout, actual.stdout);
        }
    }
}

pub fn appendBodyBindings(self: anytype, source_body: NodeIndex, output: *std.ArrayList(NodeIndex)) !void {
    const plan = self.lexical_tdz_plan orelse return;
    const body_cells = plan.bodies.get(@backingInt(source_body)) orelse return;
    for (body_cells.items) |sid| {
        const cell = plan.cells.get(sid).?;
        if (self.getSymbolIdAt(cell.binding) != sid)
            @panic("lexical TDZ entry lost its source binding identity");
        try output.append(self.allocator, cell.binding);
    }
}

const EmptyStateEntry = struct { binding: NodeIndex, symbol: ?u32, span: @import("../lexer/token.zig").Span, wrapper_scope: ScopeId };

pub fn prepend(self: anytype, source_body: NodeIndex, statements: ast.NodeList) !ast.NodeList {
    return prependImpl(self, source_body, statements, @as([]const EmptyStateEntry, &.{}), .none, .none);
}

/// State collectors provide their actual prepared storage receipts. The reset
/// is scheduled at source-body entry, never at every callback resumption.
pub fn prependState(self: anytype, source_body: NodeIndex, statements: ast.NodeList, entries: anytype, wrapper: ScopeId, execution_scope: ScopeId) !ast.NodeList {
    const plan = self.lexical_tdz_plan orelse return statements;
    if (!plan.bodies.contains(@backingInt(source_body))) return statements;
    if (wrapper.isNone() or execution_scope.isNone())
        @panic("selected lexical TDZ state entry has no actual output owner");
    return prependImpl(self, source_body, statements, entries, wrapper, execution_scope);
}

fn prependImpl(self: anytype, source_body: NodeIndex, statements: ast.NodeList, entries: anytype, wrapper: ScopeId, execution_scope: ScopeId) !ast.NodeList {
    const plan = self.lexical_tdz_plan orelse return statements;
    const body_cells = plan.bodies.get(@backingInt(source_body));
    const module_entry = @backingInt(source_body) == self.parser_node_count - 1 and plan.module_flags.count() != 0;
    if (body_cells == null and !module_entry) return statements;
    var output: std.ArrayList(NodeIndex) = .empty;
    defer output.deinit(self.allocator);
    // Directives must remain a directive prologue, especially strictness.
    var directive_count: u32 = 0;
    while (directive_count < statements.len) : (directive_count += 1) {
        const statement = self.ast.readExtraNode(statements.start, directive_count);
        const node = self.ast.getNode(statement);
        if (node.tag != .directive and
            (node.tag != .expression_statement or self.ast.getNode(node.data.unary.operand).tag != .string_literal)) break;
        try output.append(self.allocator, statement);
    }
    if (module_entry) try @import("module_lexical_initialization.zig").appendDeclarations(self, source_body, &output);
    const cells = if (body_cells) |present| present.items else &.{};
    for (cells) |sid| {
        const cell = plan.cells.get(sid).?;
        if (self.getSymbolIdAt(cell.binding) != sid)
            @panic("lexical TDZ reset changed its exact source SymbolId");
        const binding_node = self.ast.getNode(cell.binding);
        var name = if (self.tableRenameOf(cell.binding)) |selected| try self.ast.addString(selected) else binding_node.data.string_ref;
        var reference_scope = cell.scope;
        if (!wrapper.isNone()) {
            if (wrapper != self.generator_state_machine_scope or execution_scope.isNone())
                @panic("lexical TDZ reset has no actual state execution owner");
            var matches: usize = 0;
            for (entries) |storage| {
                if (storage.binding != cell.binding) continue;
                if (storage.symbol != sid or storage.wrapper_scope != wrapper)
                    @panic("lexical TDZ state storage receipt changed its source or owner");
                matches += 1;
                name = storage.span;
            }
            if (matches != 1) @panic("lexical TDZ reset requires one exact state storage receipt");
            reference_scope = execution_scope;
        }
        const anchor = @import("../lexer/token.zig").Span{ .start = self.ast.getNode(source_body).span.start, .end = self.ast.getNode(source_body).span.start };
        const target = try self.makeIdentifierRefWithSymbolAt(name, anchor, cell.binding);
        if (!wrapper.isNone()) {
            // The exact storage receipt above is consumed now, but its physical
            // hoisted declaration is installed only after callback assembly.
            // The existing generator reference producer attaches the write
            // after physical storage and callback scopes are installed, before
            // statement coordinates are published. Keep its exact SID/role.
            try self.trackGeneratorStateReference(target, @fromBackingInt(sid), execution_scope, .{ .write = true });
        } else {
            try self.trackUserWriteFromBinding(target, cell.binding, reference_scope);
        }
        self.runtime_helpers.tdz = true;
        const reset = try helpers.makeAssignExpr(self, target, try helpers.makeRuntimeHelperRef(self, "__tdz"), anchor, 0);
        try output.append(self.allocator, try helpers.makeExprStmt(self, reset, anchor));
    }
    if (output.items.len == directive_count) return statements;
    for (directive_count..statements.len) |offset|
        try output.append(self.allocator, self.ast.readExtraNode(statements.start, @intCast(offset)));
    return self.ast.addNodeList(output.items);
}

test "legacy lexical TDZ body entry storage receipts preserve block loop and suspension activation" {
    const sources = [_][]const u8{
        "function f(){var out=[];let value=42;{try{out.push(typeof value)}catch(e){out.push(e.name)}let value=7;out.push(value)}out.push(value);return out}console.log(JSON.stringify(f()))",
        "function f(){var out=[],index=0;while(index<2){try{out.push(read())}catch(e){out.push(e.name)}let value=index++;function read(){return value}out.push(read())}return out}console.log(JSON.stringify(f()))",
        "function f(){var readers=[],out=[];for(var index=0;index<2;index++){try{out.push((()=>value)())}catch(e){out.push(e.name)}let value=index;readers.push(()=>value)}return [out,readers.map(fn=>fn())]}console.log(JSON.stringify(f()))",
        "function f(){var out=[];for(var index=0;index<2;index++){try{out.push(read())}catch(e){out.push(e.name)}let value;function read(){return value}out.push(String(read()))}return out}console.log(JSON.stringify(f()))",
        "function f(){var out=[],index=0;while(index++<2){try{try{out.push(value)}catch(e){out.push(e.name)}let value=42;out.push(value)}finally{out.push('finally')}}return out}console.log(JSON.stringify(f()))",
        "function f(){var out=[];for(var index=0;index<2;index++){try{throw index}catch(error){try{out.push(typeof value)}catch(e){out.push(e.name)}let value=error;out.push(value)}}return out}console.log(JSON.stringify(f()))",
        "function f(){var out=[];outer:{try{out.push(value)}catch(e){out.push(e.name)}let value=42;out.push(value);break outer}return out}console.log(JSON.stringify(f()))",
        "function f(){var out=[];for(var index=0;index<2;index++){switch(index){case 0:case 1:{try{out.push(value)}catch(e){out.push(e.name)}let value=index;out.push(value);break}}}return out}console.log(JSON.stringify(f()))",
        "function* run(){try{yield read()}catch(e){yield e.name}let value=42;function read(){return value}yield read()}console.log(JSON.stringify([...run()]))",
        "async function run(){var out=[];try{out.push(read())}catch(e){out.push(e.name)}let value=await Promise.resolve(42);function read(){return value}out.push(read());return out}run().then(out=>console.log(JSON.stringify(out)))",
        "function* run(){for(var index=0;index<2;index++){try{yield read()}catch(e){yield e.name}let value=yield index;function read(){return value}yield read()}}var iterator=run(),out=[];out.push(iterator.next());out.push(iterator.next());out.push(iterator.next(42));out.push(iterator.next());out.push(iterator.next());out.push(iterator.next(43));console.log(JSON.stringify(out))",
        "async function run(){var out=[];for(var index=0;index<2;index++){try{out.push(read())}catch(e){out.push(e.name)}let value=await Promise.resolve(index);function read(){return value}out.push(read())}return out}run().then(out=>console.log(JSON.stringify(out)))",
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    for (sources) |source| {
        const native = try std.process.run(allocator, std.testing.io, .{ .argv = &.{ "node", "-e", source } });
        try std.testing.expect(native.term == .exited and native.term.exited == 0);
        for ([_]bool{ false, true }) |full| {
            const output = @import("../transpile.zig").transpile(allocator, source, "input.cjs", .{
                .unsupported = @import("compat.zig").fromESTarget(.es5),
                .minify_syntax = full,
                .minify_identifiers = full,
                .minify_whitespace = full,
            }) catch |err| {
                std.debug.print("lexical TDZ entry compile full={} source={s} error={s}\n", .{ full, source, @errorName(err) });
                return err;
            };
            const actual = try std.process.run(allocator, std.testing.io, .{ .argv = &.{ "node", "-e", output.code } });
            if (actual.term != .exited or actual.term.exited != 0 or !std.mem.eql(u8, native.stdout, actual.stdout))
                std.debug.print("lexical TDZ entry full={} source={s}\noutput={s}\nstderr={s}\nexpected={s} actual={s}\n", .{ full, source, output.code, actual.stderr, native.stdout, actual.stdout });
            try std.testing.expect(actual.term == .exited and actual.term.exited == 0);
            try std.testing.expectEqualStrings(native.stdout, actual.stdout);
        }
    }
}

pub fn entryInitialization(self: anytype, source_header: NodeIndex, value: NodeIndex) !NodeIndex {
    const plan = self.lexical_tdz_plan orelse return value;
    const cells = plan.bodies.get(@backingInt(source_header)) orelse return value;
    var expressions: std.ArrayList(NodeIndex) = .empty;
    defer expressions.deinit(self.allocator);
    const span = self.ast.getNode(source_header).span;
    for (cells.items) |sid| {
        const cell = plan.cells.get(sid) orelse @panic("header cell receipt missing");
        if (cell.body != source_header or self.getSymbolIdAt(cell.binding) != sid)
            @panic("header entry changed its source binding identity");
        const original = self.ast.getNode(cell.binding);
        const name = if (self.tableRenameOf(cell.binding)) |selected|
            try self.ast.addString(selected)
        else
            original.data.string_ref;
        const target = try self.makeIdentifierRefWithSymbolAt(name, original.span, cell.binding);
        // Retained native loops are owned by the ordinary capture producer,
        // which consumes this reference immediately when splitting storage.
        // Only this exact state collector may defer its final reference scope.
        if (self.state_machine_depth > 0 and self.generator_native_region_state_depth != self.state_machine_depth) {
            try self.trackGeneratorStateReference(target, @fromBackingInt(sid), cell.scope, .{ .write = true });
        } else {
            try self.trackUserWriteFromBinding(target, cell.binding, cell.scope);
        }
        self.runtime_helpers.tdz = true;
        try expressions.append(self.allocator, try helpers.makeAssignExpr(
            self,
            target,
            try helpers.makeRuntimeHelperRef(self, "__tdz"),
            original.span,
            0,
        ));
    }
    if (expressions.items.len == 0) return value;
    try expressions.append(self.allocator, value);
    return self.ast.addNode(.{ .tag = .sequence_expression, .span = span, .data = .{ .list = try self.ast.addNodeList(expressions.items) } });
}

// Rebuild only the first already-visited initializer. Source initializers were
// visited once, including NamedEvaluation preparation; runtime resets precede
// the first RHS and all subsequent declarators.
pub fn headerDeclaration(self: anytype, source: NodeIndex, visited: NodeIndex) !NodeIndex {
    const plan = self.lexical_tdz_plan orelse return visited;
    if (!plan.bodies.contains(@backingInt(source))) return visited;
    const declaration = self.ast.getNode(visited);
    if (declaration.tag != .variable_declaration) @panic("TDZ header lost declaration");
    const start = self.readU32(declaration.data.extra, 1);
    const len = self.readU32(declaration.data.extra, 2);
    if (len == 0) @panic("TDZ header lost first declarator");
    const first = self.ast.getNode(self.ast.readExtraNode(start, 0));
    if (first.tag != .variable_declarator) @panic("TDZ header lost simple initializer");
    const initializer = self.ast.readExtraNode(first.data.extra, 2);
    if (initializer.isNone()) @panic("lowered lexical header has no initialization");
    const replaced = try self.addExtraNode(.variable_declarator, first.span, &.{
        self.readU32(first.data.extra, 0),                               self.readU32(first.data.extra, 1),
        @backingInt(try entryInitialization(self, source, initializer)),
    });
    var entries: std.ArrayList(NodeIndex) = .empty;
    defer entries.deinit(self.allocator);
    try entries.append(self.allocator, replaced);
    for (1..len) |offset| try entries.append(self.allocator, self.ast.readExtraNode(start, @intCast(offset)));
    const list = try self.ast.addNodeList(entries.items);
    return self.addExtraNode(.variable_declaration, declaration.span, &.{
        self.readU32(declaration.data.extra, 0), list.start, list.len,
    });
}

test "legacy lexical TDZ traditional header entry preserves ordered initialization and captured storage" {
    const sources = [_][]const u8{
        "function f(){for(let value=value;false;){} }try{f()}catch(e){console.log(e.name)}",
        "function f(){for(let first=last,last=42;false;){} }try{f()}catch(e){console.log(e.name)}",
        "function f(){for(let first=42,last=first;last<43;last++)console.log(first,last)}f()",
        "function f(){function read(){return value}for(let value=read();false;){} }try{f()}catch(e){console.log(e.name)}",
        "function f(){var readers=[];for(let value=0;value<2;value++)readers.push(()=>value);return readers.map(f=>f())}console.log(JSON.stringify(f()))",
        "function f(){for(let value; ;){console.log(String(value));break}}f()",
        "function f(){for(let value=void 0; ;){console.log(typeof value);break}}f()",
        "function f(){var events=[];try{for(let value=(events.push('rhs'),value=42);false;){} }catch(e){events.push(e.name)}return events}console.log(JSON.stringify(f()))",
        "function f(early){for(let read=()=>value,value=early?read():42; ;){return [read.name,read()]}}try{f(true)}catch(e){console.log(e.name)}console.log(f(false))",
        "function f(){let value=7;for(let value=42; ;){console.log(value);break}console.log(value)}f()",
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    for (sources) |source| {
        const native = try std.process.run(allocator, std.testing.io, .{ .argv = &.{ "node", "-e", source } });
        try std.testing.expect(native.term == .exited and native.term.exited == 0);
        for ([_]bool{ false, true }) |full| {
            const output = @import("../transpile.zig").transpile(allocator, source, "input.cjs", .{
                .unsupported = @import("compat.zig").fromESTarget(.es5),
                .minify_syntax = full,
                .minify_identifiers = full,
                .minify_whitespace = full,
            }) catch |err| {
                std.debug.print("lexical TDZ header full={} source={s} error={s}\n", .{ full, source, @errorName(err) });
                return err;
            };
            const actual = try std.process.run(allocator, std.testing.io, .{ .argv = &.{ "node", "-e", output.code } });
            if (actual.term != .exited or actual.term.exited != 0 or !std.mem.eql(u8, native.stdout, actual.stdout))
                std.debug.print("lexical TDZ header full={} source={s}\noutput={s}\nstderr={s}\nexpected={s} actual={s}\n", .{ full, source, output.code, actual.stderr, native.stdout, actual.stdout });
            try std.testing.expect(actual.term == .exited and actual.term.exited == 0);
            try std.testing.expectEqualStrings(native.stdout, actual.stdout);
        }
    }
}

test "legacy lexical TDZ first analysis binds later header cells inside earlier initializers" {
    const source = "function f(){for(let read=()=>/*use*/value,/*decl*/value=42;;){return read()}}";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var scanner = try @import("../lexer/scanner.zig").Scanner.init(allocator, source);
    var parser = @import("../parser/parser.zig").Parser.init(allocator, &scanner);
    _ = try parser.parse();
    try std.testing.expectEqual(@as(usize, 0), parser.errors.items.len);
    var analyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer.init(allocator, &parser.ast);
    analyzer.enable_exact_declaration_anchors = true;
    try analyzer.analyze();
    try std.testing.expectEqual(@as(usize, 0), analyzer.errors.items.len);
    const read_start = (std.mem.indexOf(u8, source, "/*use*/") orelse unreachable) + "/*use*/".len;
    const binding_start = (std.mem.indexOf(u8, source, "/*decl*/") orelse unreachable) + "/*decl*/".len;
    var read_node: ?u32 = null;
    var binding: ?u32 = null;
    for (parser.ast.nodes.items, 0..) |node, raw| {
        if (node.tag == .identifier_reference and node.span.start == read_start) read_node = @intCast(raw);
        if (node.tag == .binding_identifier and node.span.start == binding_start) binding = @intCast(raw);
    }
    try std.testing.expect(read_node != null and binding != null);
    const read_sid = analyzer.symbol_ids.items[read_node.?];
    const binding_sid = analyzer.symbol_ids.items[binding.?];
    try std.testing.expect(read_sid != null and binding_sid != null);
    try std.testing.expectEqual(binding_sid, read_sid);
    var header_owner: ?u32 = null;
    for (parser.ast.nodes.items, 0..) |node, raw| {
        if (node.tag == .for_statement) header_owner = analyzer.scope_owner_map.get(@intCast(raw));
    }
    try std.testing.expect(header_owner != null);
    try std.testing.expectEqual(header_owner.?, @backingInt(analyzer.symbols.items[binding_sid.?].scope_id));
    try std.testing.expect(!analyzer.unresolved_references.contains("value"));
}

/// The ready declaration planner has the exact original first binding even
/// after the declaration node itself was normalized or copied.
/// Called by the actual loop producer after selecting the physical iteration
/// body. The key is the produced declaration node, never a spelling lookup.
pub fn recordIterationDeclaration(self: anytype, source_for: NodeIndex, body_scope: ScopeId, declaration: NodeIndex) !void {
    const plan = self.lexical_tdz_plan orelse return;
    const scopes = if (self.semantic_editor) |*editor| editor.scopes.items else self.scopes;
    const selected = plan.bodies.get(@backingInt(source_for)) orelse return;
    if (selected.items.len == 0) return;
    if (source_for.isNone() or @backingInt(source_for) >= self.parser_node_count or body_scope.isNone() or body_scope.toIndex() >= scopes.len)
        @panic("iteration TDZ declaration has no actual source or body scope");
    const loop = self.ast.getNode(source_for);
    if (loop.tag != .for_in_statement and loop.tag != .for_of_statement and loop.tag != .for_await_of_statement)
        @panic("iteration TDZ declaration changed its source loop role");
    const node = self.ast.getNode(declaration);
    if (node.tag != .variable_declaration) @panic("iteration TDZ declaration has no physical variable declaration");
    var present: std.AutoHashMapUnmanaged(u32, void) = .empty;
    const allocator = plan.arena.allocator();
    const start = self.readU32(node.data.extra, 1);
    const count = self.readU32(node.data.extra, 2);
    for (0..count) |index| {
        const item = self.ast.getNode(self.ast.readExtraNode(start, @intCast(index)));
        if (item.tag != .variable_declarator) @panic("iteration TDZ declaration lost its declarator");
        const pattern = self.ast.readExtraNode(item.data.extra, 0);
        var leaves = try @import("../parser/ast_walk.zig").bindingIdentifiers(allocator, self.ast, pattern, .{});
        defer leaves.deinit();
        while (try leaves.next()) |leaf| {
            const sid = self.getSymbolIdAt(leaf) orelse @panic("iteration TDZ physical binding lost identity");
            try present.put(allocator, sid, {});
        }
    }
    for (selected.items) |sid| {
        const cell = plan.cells.get(sid) orelse @panic("iteration TDZ source cell disappeared");
        if (cell.body != source_for or self.getSymbolIdAt(cell.binding) != sid or !present.contains(sid))
            @panic("iteration TDZ physical declaration changed its exact source cell");
    }
    const entry = try plan.iteration_declarations.getOrPut(allocator, @backingInt(declaration));
    if (entry.found_existing) @panic("iteration TDZ physical declaration was published twice");
    entry.value_ptr.* = .{ .source_for = source_for, .body_scope = body_scope };
}

pub fn iterationSourceNeedsInitialization(self: anytype, source_for: NodeIndex) bool {
    const plan = self.lexical_tdz_plan orelse return false;
    return plan.bodies.contains(@backingInt(source_for));
}

pub fn iterationDeclarationNeedsInitialization(self: anytype, declaration: NodeIndex) bool {
    const plan = self.lexical_tdz_plan orelse return false;
    return plan.iteration_declarations.contains(@backingInt(declaration));
}

/// The common iterator producer invokes this after outer IteratorValue GetV,
/// before any inner GetIterator/default. Each physical plan consumes it once.
pub fn iterationInitialization(self: anytype, declaration: NodeIndex, ready_root: NodeIndex, ready_scope: ScopeId, out: *std.ArrayList(NodeIndex)) !void {
    const plan = self.lexical_tdz_plan orelse return;
    const receipt = plan.iteration_declarations.getPtr(@backingInt(declaration)) orelse return;
    const scopes = if (self.semantic_editor) |*editor| editor.scopes.items else self.scopes;
    if (receipt.consumed or ready_scope.isNone() or ready_scope.toIndex() >= scopes.len or
        ready_root.isNone() or self.ast.getNode(ready_root).tag != .block_statement or
        self.outputOwnedScope(ready_root) != ready_scope or
        scopes[ready_scope.toIndex()].kind != .block or out.items.len != 1)
        @panic("iteration TDZ initialization changed its actual ready frontier");
    // The declaration adapter owns one region block; the binding plan owns
    // its direct child. No function/header frontier may be crossed here.
    const region = scopes[ready_scope.toIndex()].parent;
    if (region.isNone() or region.toIndex() >= scopes.len or
        scopes[region.toIndex()].kind != .block or scopes[region.toIndex()].parent != receipt.body_scope)
        @panic("iteration TDZ initialization lost its declaration region");
    const cells = plan.bodies.get(@backingInt(receipt.source_for)) orelse @panic("iteration TDZ initialization lost its source cells");
    const span = self.ast.getNode(declaration).span;
    for (cells.items) |sid| {
        const cell = plan.cells.get(sid).?;
        if (self.getSymbolIdAt(cell.binding) != sid) @panic("iteration TDZ reset changed source identity");
        const binding = self.ast.getNode(cell.binding);
        const name = if (self.tableRenameOf(cell.binding)) |selected| try self.ast.addString(selected) else binding.data.string_ref;
        const target = try self.makeIdentifierRefWithSymbolAt(name, span, cell.binding);
        try self.trackUserWriteFromBinding(target, cell.binding, ready_scope);
        self.runtime_helpers.tdz = true;
        const reset = try helpers.makeAssignExpr(self, target, try helpers.makeRuntimeHelperRef(self, "__tdz"), span, 0);
        try out.append(self.allocator, try helpers.makeExprStmt(self, reset, span));
    }
    receipt.consumed = true;
}

pub fn headerInitializerForBinding(self: anytype, binding: NodeIndex, value: NodeIndex) !NodeIndex {
    const plan = self.lexical_tdz_plan orelse return value;
    const header = plan.header_by_first_binding.get(@backingInt(binding)) orelse return value;
    if (plan.header_first_bindings.get(@backingInt(header)) != binding)
        @panic("TDZ header first-binding receipt changed");
    return entryInitialization(self, header, value);
}

test "legacy lexical TDZ suspended header entry retains initialization phase and per iteration cells" {
    const sources = [_][]const u8{
        "function* f(){for(let value=(yield 0,value);false;){} }var it=f();console.log(it.next().value);try{it.next()}catch(e){console.log(e.name)}",
        "async function f(){for(let value=(await Promise.resolve(0),value);false;){} }f().catch(e=>console.log(e.name))",
        "function* f(){for(let read=()=>value,value=(yield 0,read());false;){} }var it=f();console.log(it.next().value);try{it.next()}catch(e){console.log(e.name)}",
        "function* f(){for(let value=void 0;;){yield 0;return typeof value}}var it=f();console.log(it.next().value,it.next().value)",
        "function* f(){var readers=[];for(let value=0;value<2;value++){readers.push(()=>value);yield value}return readers.map(fn=>fn())}var it=f();console.log(JSON.stringify([it.next(),it.next(),it.next()]))",
        "function* f(){for(let read=()=>value,value=(yield 0,42);;){return [read.name,read()]}}var it=f();console.log(it.next().value,JSON.stringify(it.next().value))",
        "async function f(){for(let read=()=>value,value=(await Promise.resolve(0),42);;){return [read.name,read()]}}f().then(x=>console.log(JSON.stringify(x)))",
        "function* f(){for(let value=42;(yield 0,value)<43;value++){yield value}}var it=f();console.log(JSON.stringify([it.next(),it.next(),it.next(),it.next()]))",
        "function* f(){for(let value=(yield 0,42);;){return ()=>value}}var a=f(),b=f();a.next();b.next();console.log(a.next().value(),b.next().value())",
        "function* f(){var events=[];try{for(let value=(yield 0,value=(events.push('rhs'),42));false;){} }catch(e){events.push(e.name)}return events}var it=f();it.next();console.log(JSON.stringify(it.next().value))",
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    for (sources) |source| {
        const native = try std.process.run(allocator, std.testing.io, .{ .argv = &.{ "node", "-e", source } });
        try std.testing.expect(native.term == .exited and native.term.exited == 0);
        for ([_]bool{ false, true }) |full| {
            const output = @import("../transpile.zig").transpile(allocator, source, "input.cjs", .{
                .unsupported = @import("compat.zig").fromESTarget(.es5),
                .minify_syntax = full,
                .minify_identifiers = full,
                .minify_whitespace = full,
            }) catch |err| {
                std.debug.print("lexical TDZ suspended header full={} source={s} error={s}\n", .{ full, source, @errorName(err) });
                return err;
            };
            const actual = try std.process.run(allocator, std.testing.io, .{ .argv = &.{ "node", "-e", output.code } });
            if (actual.term != .exited or actual.term.exited != 0 or !std.mem.eql(u8, native.stdout, actual.stdout))
                std.debug.print("lexical TDZ suspended header full={} source={s}\noutput={s}\nstderr={s}\nexpected={s} actual={s}\n", .{ full, source, output.code, actual.stderr, native.stdout, actual.stdout });
            try std.testing.expect(actual.term == .exited and actual.term.exited == 0);
            try std.testing.expectEqualStrings(native.stdout, actual.stdout);
        }
    }
}

/// The first non-default test always runs after discriminant GetValue and
/// before case search, even when a default clause precedes it in source.
pub fn switchCaseTest(self: anytype, source_case: NodeIndex, value: NodeIndex) !NodeIndex {
    const plan = self.lexical_tdz_plan orelse return value;
    const source_switch = plan.switch_first_test.get(@backingInt(source_case)) orelse return value;
    return entryInitialization(self, source_switch, value);
}

pub fn switchDefaultStatements(self: anytype, source_case: NodeIndex, statements: ast.NodeList) !ast.NodeList {
    const plan = self.lexical_tdz_plan orelse return statements;
    const source_switch = plan.switch_only_default.get(@backingInt(source_case)) orelse return statements;
    if (!plan.bodies.contains(@backingInt(source_switch))) return statements;
    const span = self.ast.getNode(source_case).span;
    const reset = try entryInitialization(self, source_switch, try helpers.makeVoidZero(self, span));
    var output: std.ArrayList(NodeIndex) = .empty;
    defer output.deinit(self.allocator);
    try output.append(self.allocator, try helpers.makeExprStmt(self, reset, span));
    for (0..statements.len) |offset| try output.append(self.allocator, self.ast.readExtraNode(statements.start, @intCast(offset)));
    return self.ast.addNodeList(output.items);
}

test "legacy lexical TDZ switch entry preserves discriminant case search and skipped initialization" {
    const sources = [_][]const u8{
        "function f(){var out=[];for(var index=0;index<2;index++){try{switch(index){case 0:let value=42;out.push(value);break;case 1:out.push(value)}}catch(e){out.push(e.name)}}return out}console.log(JSON.stringify(f()))",
        "function f(){let value=42;switch(value){case 42:let value=7;return value}}console.log(f())",
        "function f(){switch(0){default:let value=42;return value;case value:return 0}}try{f()}catch(e){console.log(e.name)}",
        "function f(){switch(0){default:try{return value}catch(e){return e.name}let value=42}}console.log(f())",
        "function f(){switch(0){case 0:let value=42;case 1:return value}}console.log(f())",
        "function f(){switch(0){case 0:let value=42;switch(0){case 0:try{return value}catch(e){return [e.name,42]}let value=7}}}console.log(JSON.stringify(f()))",
        "function* f(){switch(yield 0){case value:yield 1;let value=42}}var it=f();console.log(it.next().value);try{it.next(1)}catch(e){console.log(e.name)}",
        "function* f(){switch(0){case 0:let value=42;yield 0;return read();function read(){return value}}}var it=f();console.log(it.next().value,it.next().value)",
        "function f(){var readers=[];for(var index=0;index<2;index++){switch(index){case 0:case 1:let value=index;readers.push(()=>value)}}return readers.map(fn=>fn())}console.log(JSON.stringify(f()))",
        "function f(){var events=[];switch((events.push('disc'),0)){case(events.push('first'),0):let value=42;events.push(value);break;case(events.push('later'),1):events.push(value)}return events}console.log(JSON.stringify(f()))",
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    for (sources) |source| {
        const native = try std.process.run(allocator, std.testing.io, .{ .argv = &.{ "node", "-e", source } });
        try std.testing.expect(native.term == .exited and native.term.exited == 0);
        for ([_]bool{ false, true }) |full| {
            const output = @import("../transpile.zig").transpile(allocator, source, "input.cjs", .{
                .unsupported = @import("compat.zig").fromESTarget(.es5),
                .minify_syntax = full,
                .minify_identifiers = full,
                .minify_whitespace = full,
            }) catch |err| {
                std.debug.print("lexical TDZ switch full={} source={s} error={s}\n", .{ full, source, @errorName(err) });
                return err;
            };
            const actual = try std.process.run(allocator, std.testing.io, .{ .argv = &.{ "node", "-e", output.code } });
            if (actual.term != .exited or actual.term.exited != 0 or !std.mem.eql(u8, native.stdout, actual.stdout))
                std.debug.print("lexical TDZ switch full={} source={s}\noutput={s}\nstderr={s}\nexpected={s} actual={s}\n", .{ full, source, output.code, actual.stderr, native.stdout, actual.stdout });
            try std.testing.expect(actual.term == .exited and actual.term.exited == 0);
            try std.testing.expectEqualStrings(native.stdout, actual.stdout);
        }
    }
}

fn consumeIterableReference(self: anytype, source: NodeIndex, role: IterableReference) !void {
    if (self.getSymbolIdAt(role.binding) != role.symbol or self.getSymbolIdAt(source) != role.symbol)
        @panic("iterable TDZ use changed its exact source binding identity");
    // This source GetValue/PutValue cannot reach an iteration cell. Consume
    // that exact source edge; the replacement helper retains its own identity.
    try self.removeSemanticReference(source);
}

fn iterableFailure(self: anytype, role: IterableReference, span: @import("../lexer/token.zig").Span) !NodeIndex {
    const name = try helpers.buildQuotedKeyLiteral(self, self.ast.getNode(role.binding).data.string_ref);
    self.runtime_helpers.tdz = true;
    return helpers.makeCallExpr(self, try helpers.makeRuntimeHelperRef(self, "__tdz"), &.{name}, span);
}

test "legacy lexical TDZ iterable RHS retains permanently uninitialized head environment" {
    const sources = [_][]const u8{
        "function f(){for(let value of value){} }try{f()}catch(e){console.log(e.name)}",
        "function f(){for(let value of [typeof value]){} }try{f()}catch(e){console.log(e.name)}",
        "function f(){var saved,out=[];for(let value of(saved=()=>value,[42]))out.push(value);try{saved()}catch(e){out.push(e.name)}return out}console.log(JSON.stringify(f()))",
        "function f(){var events=[];try{for(let value of(value=(events.push('rhs'),[42]))){} }catch(e){events.push(e.name)}return events}console.log(JSON.stringify(f()))",
        "function f(){var events=[];try{for(let value of(value+=(events.push('rhs'),[]))){} }catch(e){events.push(e.name)}return events}console.log(JSON.stringify(f()))",
        "function f(){var saved,events=[];for(let value of(saved=()=>value??=(events.push('rhs'),1),[42]))events.push(value);try{saved()}catch(e){events.push(e.name)}return events}console.log(JSON.stringify(f()))",
        "function f(){var saved,out=[];for(let value of(saved=()=>value++,[42]))out.push(value);try{saved()}catch(e){out.push(e.name)}return out}console.log(JSON.stringify(f()))",
        "function f(){var saved,out=[];for(let key in(saved=()=>key,{a:1}))out.push(key);try{saved()}catch(e){out.push(e.name)}return out}console.log(JSON.stringify(f()))",
        "async function f(){for await(let value of(await Promise.resolve(0),value)){} }f().catch(e=>console.log(e.name))",
        "function* f(){for(let value of(yield 0,value)){} }var it=f();console.log(it.next().value);try{it.next()}catch(e){console.log(e.name)}",
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    for (sources) |source| {
        const native = try std.process.run(allocator, std.testing.io, .{ .argv = &.{ "node", "-e", source } });
        try std.testing.expect(native.term == .exited and native.term.exited == 0);
        for ([_]bool{ false, true }) |full| {
            const output = @import("../transpile.zig").transpile(allocator, source, "input.cjs", .{
                .unsupported = @import("compat.zig").fromESTarget(.es5),
                .minify_syntax = full,
                .minify_identifiers = full,
                .minify_whitespace = full,
            }) catch |err| {
                std.debug.print("lexical TDZ iterable full={} source={s} error={s}\n", .{ full, source, @errorName(err) });
                return err;
            };
            const actual = try std.process.run(allocator, std.testing.io, .{ .argv = &.{ "node", "-e", output.code } });
            if (actual.term != .exited or actual.term.exited != 0 or !std.mem.eql(u8, native.stdout, actual.stdout))
                std.debug.print("lexical TDZ iterable full={} source={s}\noutput={s}\nstderr={s}\nexpected={s} actual={s}\n", .{ full, source, output.code, actual.stderr, native.stdout, actual.stdout });
            try std.testing.expect(actual.term == .exited and actual.term.exited == 0);
            try std.testing.expectEqualStrings(native.stdout, actual.stdout);
        }
    }
}

/// The async iterator producer moves its RHS before ordinary expression
/// visiting. Consume only the exact permanent-head roles before that move;
/// ordinary source evaluation and iteration bindings are left untouched.
pub fn prepareIterableRelocation(self: anytype, root: NodeIndex) !void {
    const plan = self.lexical_tdz_plan orelse return;
    if (plan.iterable_references.count() == 0) return;
    var seen: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer seen.deinit(self.allocator);
    var pending: std.ArrayList(NodeIndex) = .empty;
    defer pending.deinit(self.allocator);
    try pending.append(self.allocator, root);
    while (pending.pop()) |source| {
        if (source.isNone()) continue;
        const raw = @backingInt(source);
        if (seen.contains(raw)) continue;
        try seen.put(self.allocator, raw, {});
        const node = self.ast.getNode(source);
        const replacement: ?NodeIndex = switch (node.tag) {
            .identifier_reference => if (plan.iterable_references.get(raw)) |role| blk: {
                try consumeIterableReference(self, source, role);
                break :blk try iterableFailure(self, role, node.span);
            } else null,
            .assignment_expression => if (plan.iterable_references.contains(@backingInt(node.data.binary.left)))
                try assignment(self, source)
            else
                null,
            .update_expression => if (plan.iterable_references.contains(@backingInt(self.ast.readExtraNode(node.data.extra, 0))))
                try update(self, source)
            else
                null,
            else => null,
        };
        if (replacement) |value| {
            self.ast.replaceNode(source, self.ast.getNode(value));
            continue;
        }
        var children = @import("../parser/ast_walk.zig").children(self.ast, node);
        while (children.next()) |child| try pending.append(self.allocator, child);
    }
}

test "legacy lexical TDZ declaration patterns initialize exact source leaves in order" {
    const sources = [_][]const u8{
        "function f(){return read();const {value}={value:42};function read(){return typeof value}}try{f()}catch(e){console.log(e.name)}",
        "function f(){var events=[];try{return read();const [value]={[Symbol.iterator](){events.push('iterate');return{next(){return{done:true}}}}};function read(){return value}}catch(e){return[events,e.name]}}console.log(JSON.stringify(f()))",
        "function f(){const [value]=[void 0];return typeof read();function read(){return value}}console.log(f())",
        "function f(){const {first=value,value=42}={};return first}try{f()}catch(e){console.log(e.name)}",
        "function f(){const [first=read(),value=42]=[];return first;function read(){return value}}try{f()}catch(e){console.log(e.name)}",
        "function f(){const {[value]:first,value=42}={};return first}try{f()}catch(e){console.log(e.name)}",
        "function f(early){if(early)return read();const {nested:{value}}={nested:{value:42}};return read();function read(){return value}}try{f(true)}catch(e){console.log(e.name)}console.log(f(false))",
        "function f(){var readers=[],out=[];for(var index=0;index<2;index++){try{out.push(read())}catch(e){out.push(e.name)}const {value}={value:index};function read(){return value}readers.push(read)}return[out,readers.map(fn=>fn())]}console.log(JSON.stringify(f()))",
        "function* f(){try{yield read()}catch(e){yield e.name}const {value}=yield 0;return read();function read(){return value}}var it=f();console.log(JSON.stringify([it.next(),it.next(),it.next({value:42})]))",
        "function* f(){try{yield read()}catch(e){yield e.name}const [value=yield 0]=[];return read();function read(){return value}}var it=f();console.log(JSON.stringify([it.next(),it.next(),it.next(42)]))",
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    for (sources) |source| {
        const native = try std.process.run(allocator, std.testing.io, .{ .argv = &.{ "node", "-e", source } });
        try std.testing.expect(native.term == .exited and native.term.exited == 0);
        for ([_]bool{ false, true }) |full| {
            const output = @import("../transpile.zig").transpile(allocator, source, "input.cjs", .{
                .unsupported = @import("compat.zig").fromESTarget(.es5),
                .minify_syntax = full,
                .minify_identifiers = full,
                .minify_whitespace = full,
            }) catch |err| {
                std.debug.print("lexical TDZ pattern full={} source={s} error={s}\n", .{ full, source, @errorName(err) });
                return err;
            };
            const actual = try std.process.run(allocator, std.testing.io, .{ .argv = &.{ "node", "-e", output.code } });
            if (actual.term != .exited or actual.term.exited != 0 or !std.mem.eql(u8, native.stdout, actual.stdout))
                std.debug.print("lexical TDZ pattern full={} source={s}\noutput={s}\nstderr={s}\nexpected={s} actual={s}\n", .{ full, source, output.code, actual.stderr, native.stdout, actual.stdout });
            try std.testing.expect(actual.term == .exited and actual.term.exited == 0);
            try std.testing.expectEqualStrings(native.stdout, actual.stdout);
        }
    }
}

test "legacy lexical TDZ array default abrupt completion closes before another iterator step" {
    const sources = [_][]const u8{
        "function f(){var events=[];const iterable={[Symbol.iterator](){return{next(){events.push('next');return{done:false,value:void 0}},return(){events.push('close');return{done:true}}}}};try{const [first=second,second=42]=iterable;events.push(first)}catch(e){events.push(e.name)}return events}console.log(JSON.stringify(f()))",
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    for (sources) |source| {
        const native = try std.process.run(allocator, std.testing.io, .{ .argv = &.{ "node", "-e", source } });
        try std.testing.expect(native.term == .exited and native.term.exited == 0);
        for ([_]bool{ false, true }) |full| {
            const output = @import("../transpile.zig").transpile(allocator, source, "input.cjs", .{
                .unsupported = @import("compat.zig").fromESTarget(.es5),
                .minify_syntax = full,
                .minify_identifiers = full,
                .minify_whitespace = full,
            }) catch |err| {
                std.debug.print("lexical TDZ iterator full={} source={s} error={s}\n", .{ full, source, @errorName(err) });
                return err;
            };
            const actual = try std.process.run(allocator, std.testing.io, .{ .argv = &.{ "node", "-e", output.code } });
            if (actual.term != .exited or actual.term.exited != 0 or !std.mem.eql(u8, native.stdout, actual.stdout))
                std.debug.print("lexical TDZ iterator full={} source={s}\noutput={s}\nstderr={s}\nexpected={s} actual={s}\n", .{ full, source, output.code, actual.stderr, native.stdout, actual.stdout });
            try std.testing.expect(actual.term == .exited and actual.term.exited == 0);
            try std.testing.expectEqualStrings(native.stdout, actual.stdout);
        }
    }
}

pub fn ordinaryCatch(self: anytype, source: NodeIndex, node: ast.Node) !?NodeIndex {
    if (!self.options.unsupported.destructuring) return null;
    const plan = self.lexical_tdz_plan orelse return null;
    const pattern = plan.catch_patterns.get(@backingInt(source)) orelse return null;
    if (!plan.bodies.contains(@backingInt(source))) return null;
    if (pattern != node.data.binary.left) @panic("catch TDZ pattern changed its source receipt");
    return try @import("lexical_tdz_catch.zig").lower(self, source, node);
}

test "legacy lexical TDZ catch patterns retain fresh native cells and initialization environments" {
    const sources = [_][]const u8{
        "function f(){try{throw{}}catch({first=value,value=42}){return first}}try{f()}catch(e){console.log(e.name)}",
        "function f(){try{throw{}}catch({first=41,read=()=>value,value=first+1}){return[read.name,read()]}}console.log(JSON.stringify(f()))",
        "function f(){var readers=[];for(var index=0;index<2;index++){try{throw{}}catch({read=()=>value,value=index}){readers.push(read)}}return readers.map(fn=>fn())}console.log(JSON.stringify(f()))",
        "function f(){const outer=42;try{throw{}}catch({read=()=>value,value=outer}){let outer=7;return[read(),outer]}}console.log(JSON.stringify(f()))",
        "function f(){var log=[];try{try{throw{}}catch({a=b,b=42}){log.push('body')}}catch(e){log.push(e.name)}finally{log.push('finally')}return log}console.log(JSON.stringify(f()))",
        "function f(){var out=[];outer:for(var index=0;index<2;index++){try{throw{}}catch({read=()=>value,value=index}){out.push(read());continue outer}out.push('bad')}return out}console.log(JSON.stringify(f()))",
        "function f(){try{throw[]}catch([first=value,value=42]){return first}}try{f()}catch(e){console.log(e.name)}",
        "function f(){try{throw{}}catch({[value]:first,value=42}){return first}}try{f()}catch(e){console.log(e.name)}",
        "function* f(){try{throw{}}catch({first=value,value=42}){yield first}}var it=f();try{it.next()}catch(e){console.log(e.name)}",
        "async function f(){try{throw{value:await Promise.resolve(42)}}catch({read=()=>value,value}){return read()}}f().then(x=>console.log(x))",
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    for (sources) |source| {
        const native = try std.process.run(allocator, std.testing.io, .{ .argv = &.{ "node", "-e", source } });
        try std.testing.expect(native.term == .exited and native.term.exited == 0);
        for ([_]bool{ false, true }) |full| {
            const output = @import("../transpile.zig").transpile(allocator, source, "input.cjs", .{
                .unsupported = @import("compat.zig").fromESTarget(.es5),
                .minify_syntax = full,
                .minify_identifiers = full,
                .minify_whitespace = full,
            }) catch |err| {
                std.debug.print("lexical TDZ catch full={} source={s} error={s}\n", .{ full, source, @errorName(err) });
                return err;
            };
            var output_scanner = try @import("../lexer/scanner.zig").Scanner.init(allocator, output.code);
            var output_parser = @import("../parser/parser.zig").Parser.init(allocator, &output_scanner);
            const output_root = try output_parser.parse();
            try std.testing.expectEqual(@as(usize, 0), output_parser.errors.items.len);
            var output_seen: std.AutoHashMapUnmanaged(u32, void) = .empty;
            var output_stack: std.ArrayList(NodeIndex) = .empty;
            try output_stack.append(allocator, output_root);
            while (output_stack.pop()) |current| {
                if (current.isNone() or output_seen.contains(@backingInt(current))) continue;
                try output_seen.put(allocator, @backingInt(current), {});
                const node = output_parser.ast.getNode(current);
                if (node.tag == .object_pattern or node.tag == .array_pattern)
                    std.debug.print("lexical TDZ catch retained pattern full={} source={s} tag={s}\noutput={s}\n", .{ full, source, @tagName(node.tag), output.code });
                try std.testing.expect(node.tag != .object_pattern and node.tag != .array_pattern);
                var children = @import("../parser/ast_walk.zig").children(&output_parser.ast, node);
                while (children.next()) |child| try output_stack.append(allocator, child);
            }
            const actual = try std.process.run(allocator, std.testing.io, .{ .argv = &.{ "node", "-e", output.code } });
            if (actual.term != .exited or actual.term.exited != 0 or !std.mem.eql(u8, native.stdout, actual.stdout))
                std.debug.print("lexical TDZ catch full={} source={s}\noutput={s}\nstderr={s}\nexpected={s} actual={s}\n", .{ full, source, output.code, actual.stderr, native.stdout, actual.stdout });
            try std.testing.expect(actual.term == .exited and actual.term.exited == 0);
            try std.testing.expectEqualStrings(native.stdout, actual.stdout);
        }
    }
}

test "legacy lexical TDZ method arrow and parameter body owners preserve source cells" {
    const sources = [_][]const u8{
        "var obj={method(){return read();const value=42;function read(){return typeof value}}};try{obj.method()}catch(e){console.log(e.name)}",
        "var obj={get value(){return read();const local=42;function read(){return local}}};try{obj.value}catch(e){console.log(e.name)}",
        "var obj={set value(input){read();let local=input;function read(){return local}}};try{obj.value=42}catch(e){console.log(e.name)}",
        "class C{method(){return read();const value=42;function read(){return value}}}try{new C().method()}catch(e){console.log(e.name)}",
        "class C{constructor(){read();const value=42;function read(){return value}}}try{new C()}catch(e){console.log(e.name)}",
        "class C{static method(){return read();const value=42;function read(){return value}}}try{C.method()}catch(e){console.log(e.name)}",
        "var f=()=>{return read();const value=42;function read(){return value}};try{f()}catch(e){console.log(e.name)}",
        "var f=async()=>{return read();const value=await Promise.resolve(42);function read(){return value}};f().catch(e=>console.log(e.name))",
        "function f(input=0){return read();const value=42;function read(){return typeof value}}try{f()}catch(e){console.log(e.name)}",
        "var obj={*method(){try{yield read()}catch(e){yield e.name}const value=42;function read(){return value}yield read()}};console.log(JSON.stringify([...obj.method()]))",
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    for (sources) |source| {
        const native = try std.process.run(allocator, std.testing.io, .{ .argv = &.{ "node", "-e", source } });
        try std.testing.expect(native.term == .exited and native.term.exited == 0);
        for ([_]bool{ false, true }) |full| {
            const output = @import("../transpile.zig").transpile(allocator, source, "input.cjs", .{
                .unsupported = @import("compat.zig").fromESTarget(.es5),
                .minify_syntax = full,
                .minify_identifiers = full,
                .minify_whitespace = full,
            }) catch |err| {
                std.debug.print("lexical TDZ method full={} source={s} error={s}\n", .{ full, source, @errorName(err) });
                return err;
            };
            const actual = try std.process.run(allocator, std.testing.io, .{ .argv = &.{ "node", "-e", output.code } });
            if (actual.term != .exited or actual.term.exited != 0 or !std.mem.eql(u8, native.stdout, actual.stdout))
                std.debug.print("lexical TDZ method full={} source={s}\noutput={s}\nstderr={s}\nexpected={s} actual={s}\n", .{ full, source, output.code, actual.stderr, native.stdout, actual.stdout });
            try std.testing.expect(actual.term == .exited and actual.term.exited == 0);
            try std.testing.expectEqualStrings(native.stdout, actual.stdout);
        }
    }
}

test "legacy lexical TDZ program local cells preserve early root reads and initialization" {
    const sources = [_][]const u8{
        "try{console.log(read())}catch(error){console.log(error.name)}const value=42;function read(){return typeof value}",
        "try{console.log(value)}catch(error){console.log(error.name)}const value=42;console.log(value)",
        "try{console.log(read())}catch(error){console.log(error.name)}let value;function read(){return typeof value}console.log(read())",
        "var events=[];for(var i=0;i<2;i++){try{events.push(read())}catch(error){events.push(error.name)}let value=42;function read(){return value}}console.log(JSON.stringify(events))",
        "try{console.log(read())}catch(error){console.log(error.name)}export const value=42;export function read(){return typeof value}console.log(read())",
        "try{console.log(read())}catch(error){console.log(error.name)}using resource={[Symbol.dispose](){console.log('disposed')}};const value=42;function read(){return value}console.log(read())",
        "var events=[];try{value=(events.push('rhs'),1)}catch(error){events.push(error.name)}let value=42;events.push(value);console.log(JSON.stringify(events))",
        "try{const [first=second,second=42]=[void 0];console.log(first)}catch(error){console.log(error.name)}",
        "var tasks=[];function capture(){tasks.push(()=>value)}capture();try{console.log(tasks[0]())}catch(error){console.log(error.name)}const value=42;console.log(tasks[0]())",
        "try{console.log(read())}catch(error){console.log(error.name)}const [value]=[42];function read(){return value}console.log(read())",
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    for (sources) |source| {
        const native = try std.process.run(allocator, std.testing.io, .{ .argv = &.{ "node", "--input-type=module", "-e", source } });
        try std.testing.expect(native.term == .exited and native.term.exited == 0);
        for ([_]bool{ false, true }) |full| {
            const output = try @import("../transpile.zig").transpile(allocator, source, "input.mjs", .{
                .unsupported = @import("compat.zig").fromESTarget(.es5),
                .minify_syntax = full,
                .minify_identifiers = full,
                .minify_whitespace = full,
            });
            const actual = try std.process.run(allocator, std.testing.io, .{ .argv = &.{ "node", "--input-type=module", "-e", output.code } });
            if (actual.term != .exited or actual.term.exited != 0 or !std.mem.eql(u8, native.stdout, actual.stdout))
                std.debug.print("lexical TDZ program local full={} source={s}\noutput={s}\nstderr={s}\nexpected={s} actual={s}\n", .{ full, source, output.code, actual.stderr, native.stdout, actual.stdout });
            try std.testing.expect(actual.term == .exited and actual.term.exited == 0);
            try std.testing.expectEqualStrings(native.stdout, actual.stdout);
        }
    }
}

test "legacy lexical TDZ lazy iterator builtin Symbol role retains source bindings and names" {
    const sources = [_][]const u8{
        "const Symbol={iterator:globalThis.Symbol.iterator};function f(){const [value]=[42];return value}console.log(f())",
        "function Symbol(){}function f(){const [value]=[42];return value}console.log(Symbol.name,f())",
        "class Symbol{}function f(){const [value]=[42];return value}console.log(Symbol.name,f())",
        "const Symbol=class{};function f(){const [value]=[42];return value}console.log(Symbol.name,f())",
        "export const Symbol={iterator:globalThis.Symbol.iterator};export function f(){const [value]=[42];return value}console.log(Symbol.iterator===globalThis.Symbol.iterator,f())",
        "const \\u0053ymbol={iterator:globalThis.Symbol.iterator};function f(){const [value]=[42];return value}console.log(f())",
        "class Symbol{static seen=this.name}function f(){const [value]=[42];return value}console.log(Symbol.seen,f())",
        "function f(){const [value]=[42];return value}console.log(f())",
        "function f(){const Symbol={iterator:globalThis.Symbol.iterator};const [value]=[42];return [Symbol.iterator===globalThis.Symbol.iterator,value]}console.log(JSON.stringify(f()))",
        "const Symbol=function(){};function f(){const [value]=[42];return value}console.log(Symbol.name,f())",
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    for (sources) |source| {
        const native = try std.process.run(allocator, std.testing.io, .{ .argv = &.{ "node", "--input-type=module", "-e", source } });
        try std.testing.expect(native.term == .exited and native.term.exited == 0);
        for ([_]bool{ false, true }) |full| {
            const output = try @import("../transpile.zig").transpile(allocator, source, "input.mjs", .{
                .unsupported = @import("compat.zig").fromESTarget(.es5),
                .minify_syntax = full,
                .minify_identifiers = full,
                .minify_whitespace = full,
                .keep_names = full,
            });
            const actual = try std.process.run(allocator, std.testing.io, .{ .argv = &.{ "node", "--input-type=module", "-e", output.code } });
            if (actual.term != .exited or actual.term.exited != 0 or !std.mem.eql(u8, native.stdout, actual.stdout))
                std.debug.print("lexical TDZ iterator Symbol full={} source={s}\noutput={s}\nstderr={s}\nexpected={s} actual={s}\n", .{ full, source, output.code, actual.stderr, native.stdout, actual.stdout });
            try std.testing.expect(actual.term == .exited and actual.term.exited == 0);
            try std.testing.expectEqualStrings(native.stdout, actual.stdout);
        }
    }
}

test "legacy lexical TDZ source const storage rejects same execution PutValue after initialization" {
    const sources = [_][]const u8{
        "function f(){const k=42;try{k=7}catch(error){return[error.name,k]}return['bad',k]}console.log(JSON.stringify(f()))",
        "function f(){var e=[];const k=42;try{k=(e.push('rhs'),7)}catch(error){e.push(error.name)}return[e,k]}console.log(JSON.stringify(f()))",
        "function f(){var e=[];const k=42;try{k+=(e.push('rhs'),7)}catch(error){e.push(error.name)}return[e,k]}console.log(JSON.stringify(f()))",
        "function f(){var e=[];const k=0;try{k||=(e.push('rhs'),7)}catch(error){e.push(error.name)}return[e,k]}console.log(JSON.stringify(f()))",
        "function f(){var e=[];const k=42;return[k||=(e.push('rhs'),7),k,e]}console.log(JSON.stringify(f()))",
        "function f(){var e=[];const k=null;try{k??=(e.push('rhs'),7)}catch(error){e.push(error.name)}return[e,k]}console.log(JSON.stringify(f()))",
        "function f(){const k=42;try{k++}catch(error){return[error.name,k]}}console.log(JSON.stringify(f()))",
        "function f(){const k=42n;try{++k}catch(error){return[error.name,String(k)]}}console.log(JSON.stringify(f()))",
        "function f(){var e=[];const k={valueOf(){e.push('numeric');return 1}};try{k++}catch(error){e.push(error.name)}return[e,typeof k]}console.log(JSON.stringify(f()))",
        "const TypeError=class Wrong extends Error{};function f(){const k=42;try{k=7}catch(error){return[error instanceof globalThis.TypeError,error instanceof TypeError,k]}}console.log(JSON.stringify(f()))",
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    for (sources) |source| {
        const native = try std.process.run(allocator, std.testing.io, .{ .argv = &.{ "node", "-e", source } });
        try std.testing.expect(native.term == .exited and native.term.exited == 0);
        for ([_]bool{ false, true }) |full| {
            const output = try @import("../transpile.zig").transpile(allocator, source, "input.cjs", .{
                .unsupported = @import("compat.zig").fromESTarget(.es5),
                .minify_syntax = full,
                .minify_identifiers = full,
                .minify_whitespace = full,
            });
            const actual = try std.process.run(allocator, std.testing.io, .{ .argv = &.{ "node", "-e", output.code } });
            if (actual.term != .exited or actual.term.exited != 0 or !std.mem.eql(u8, native.stdout, actual.stdout))
                std.debug.print("lexical TDZ iteration initialization full={} source={s}\noutput={s}\nstderr={s}\nexpected={s} actual={s}\n", .{ full, source, output.code, actual.stderr, native.stdout, actual.stdout });
            try std.testing.expect(actual.term == .exited and actual.term.exited == 0);
            try std.testing.expectEqualStrings(native.stdout, actual.stdout);
        }
    }
}

test "legacy lexical TDZ user assignment patterns perform checked PutValue and iterator close" {
    const sources = [_][]const u8{
        "function f(){try{[value]=[42]}catch(error){return error.name}let value;return value}console.log(f())",
        "function f(){try{({value}={value:42})}catch(error){return error.name}let value;return value}console.log(f())",
        "function f(){var e=[];const it={[Symbol.iterator](){return{next(){e.push('next');return{value:void 0,done:false}},return(){e.push('close');return{done:true}}}}};try{[value=(e.push('default'),42)]=it}catch(error){e.push(error.name)}let value;return e}console.log(JSON.stringify(f()))",
        "function f(){var e=[];const value=42;const it={[Symbol.iterator](){return{next(){e.push('next');return{value:7,done:false}},return(){e.push('close');return{done:true}}}}};try{[value]=it}catch(error){e.push(error.name)}return[e,value]}console.log(JSON.stringify(f()))",
        "function f(){let value=0;[value,value]=[1,2];return value}console.log(f())",
        "function f(){var e=[];function iterable(name,value){return{[Symbol.iterator](){return{next(){e.push('next:'+name);return{value:value,done:false}},return(){e.push('close:'+name);return{done:true}}}}}}const value=42;try{[[value]]=iterable('outer',iterable('inner',7))}catch(error){e.push(error.name)}return[e,value]}console.log(JSON.stringify(f()))",
        "function f(){var e=[];const value=1;try{({value}={get value(){e.push('get');return 2}})}catch(error){e.push(error.name)}return[e,value]}console.log(JSON.stringify(f()))",
        "function f(){try{[...value]=[1,2]}catch(error){return error.name}let value}console.log(f())",
        "function f(){var e=[],n=0;let first=0;const it={[Symbol.iterator](){return{next(){e.push('next');return{value:++n,done:false}},return(){e.push('close');return{done:true}}}}};try{[first,second]=it}catch(error){e.push(error.name)}let second;return[e,first]}console.log(JSON.stringify(f()))",
        "function f(){let value;[value]=[void 0];return typeof value}console.log(f())",
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    for (sources) |source| {
        const native = try std.process.run(allocator, std.testing.io, .{ .argv = &.{ "node", "-e", source } });
        try std.testing.expect(native.term == .exited and native.term.exited == 0);
        for ([_]bool{ false, true }) |full| {
            const output = try @import("../transpile.zig").transpile(allocator, source, "input.cjs", .{
                .unsupported = @import("compat.zig").fromESTarget(.es5),
                .minify_syntax = full,
                .minify_identifiers = full,
                .minify_whitespace = full,
            });
            const actual = try std.process.run(allocator, std.testing.io, .{ .argv = &.{ "node", "-e", output.code } });
            if (actual.term != .exited or actual.term.exited != 0 or !std.mem.eql(u8, native.stdout, actual.stdout))
                std.debug.print("lexical TDZ pattern PutValue full={} source={s}\noutput={s}\nstderr={s}\nexpected={s} actual={s}\n", .{ full, source, output.code, actual.stderr, native.stdout, actual.stdout });
            try std.testing.expect(actual.term == .exited and actual.term.exited == 0);
            try std.testing.expectEqualStrings(native.stdout, actual.stdout);
        }
    }
}

test "legacy lexical TDZ object assignment defaults retain actual target and GetValue ordering" {
    const sources = [_][]const u8{
        "function f(){try{({value=42}={})}catch(error){return error.name}let value;return value}console.log(f())",
        "function f(){var e=[];try{({value=(e.push('default'),42)}={})}catch(error){e.push(error.name)}let value;return e}console.log(JSON.stringify(f()))",
        "function f(){const value=void 0;try{({value=42}={})}catch(error){return[error.name,typeof value]}}console.log(JSON.stringify(f()))",
        "function f(){try{({item:value=42}={})}catch(error){return error.name}let value;return value}console.log(f())",
        "function f(){var e=[];function key(){e.push('key');return 'item'}try{({[key()]:value=(e.push('default'),42)}={})}catch(error){e.push(error.name)}let value;return e}console.log(JSON.stringify(f()))",
        "function f(){var e=[];const value=1;try{({value=(e.push('default'),42)}={})}catch(error){e.push(error.name)}return[e,value]}console.log(JSON.stringify(f()))",
        "function f(){let value;({value=42}={});return value}console.log(f())",
        "function f(){var e=[];try{({value=42}={get value(){e.push('get');return void 0}})}catch(error){e.push(error.name)}let value;return e}console.log(JSON.stringify(f()))",
        "function f(){var e=[];try{({value=42}={get value(){e.push('get');return 1}})}catch(error){e.push(error.name)}let value;return e}console.log(JSON.stringify(f()))",
        "function f(){var e=[];try{({first=second,second=42}={})}catch(error){e.push(error.name)}let first,second;return e}console.log(JSON.stringify(f()))",
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    for (sources) |source| {
        const native = try std.process.run(allocator, std.testing.io, .{ .argv = &.{ "node", "-e", source } });
        try std.testing.expect(native.term == .exited and native.term.exited == 0);
        for ([_]bool{ false, true }) |full| {
            const output = try @import("../transpile.zig").transpile(allocator, source, "input.cjs", .{
                .unsupported = @import("compat.zig").fromESTarget(.es5),
                .minify_syntax = full,
                .minify_identifiers = full,
                .minify_whitespace = full,
            });
            const actual = try std.process.run(allocator, std.testing.io, .{ .argv = &.{ "node", "-e", output.code } });
            if (actual.term != .exited or actual.term.exited != 0 or !std.mem.eql(u8, native.stdout, actual.stdout))
                std.debug.print("lexical TDZ object default PutValue full={} source={s}\noutput={s}\nstderr={s}\nexpected={s} actual={s}\n", .{ full, source, output.code, actual.stderr, native.stdout, actual.stdout });
            try std.testing.expect(actual.term == .exited and actual.term.exited == 0);
            try std.testing.expectEqualStrings(native.stdout, actual.stdout);
        }
    }
}

test "legacy lexical TDZ state iterator plans retain suspension close and source scope frontiers" {
    const sources = [_][]const u8{
        "var events=[];function make(name,value){return{[Symbol.iterator](){events.push('open:'+name);return{next(){events.push('next:'+name);return{done:false,value:value}},return(){events.push('close:'+name);return{done:true}}}}}};function* run(){const[value=(yield 0)]=make('one',undefined);return value}var it=run();events.push(it.next().value);events.push(it.return(42).value);console.log(JSON.stringify(events));",
        "var events=[];function make(name,value){return{[Symbol.iterator](){events.push('open:'+name);return{next(){events.push('next:'+name);return{done:false,value:value}},return(){events.push('close:'+name);return{done:true}}}}}};function* run(){const[first=(yield 0,second),second=42]=make('one',undefined);return first}var it=run();events.push(it.next().value);try{it.next()}catch(error){events.push(error.name)}console.log(JSON.stringify(events));",
        "var events=[];function make(name,value){return{[Symbol.iterator](){events.push('open:'+name);return{next(){events.push('next:'+name);return{done:false,value:value}},return(){events.push('close:'+name);return{done:true}}}}}};function* run(){{const[first=second,second=42]=make('one',undefined);yield first}}try{run().next()}catch(error){events.push(error.name)}console.log(JSON.stringify(events));",
        "var events=[];function make(name,value){return{[Symbol.iterator](){events.push('open:'+name);return{next(){events.push('next:'+name);return{done:false,value:value}},return(){events.push('close:'+name);return{done:true}}}}}};function* run(){[value]=yield 0;let value;return value}var it=run();events.push(it.next().value);try{it.next([42])}catch(error){events.push(error.name)}console.log(JSON.stringify(events));",
        "var events=[];function make(name,value){return{[Symbol.iterator](){events.push('open:'+name);return{next(){events.push('next:'+name);return{done:false,value:value}},return(){events.push('close:'+name);return{done:true}}}}}};function* run(){[first=(yield 0),second]=make('one',undefined);let first,second}var it=run();events.push(it.next().value);try{it.next(42)}catch(error){events.push(error.name)}console.log(JSON.stringify(events));",
        "var events=[];function make(name,value){return{[Symbol.iterator](){events.push('open:'+name);return{next(){events.push('next:'+name);return{done:false,value:value}},return(){events.push('close:'+name);return{done:true}}}}}};async function run(){const[value=(events.push('default'),await Promise.resolve(42))]=make('one',undefined);return value}run().then(value=>{events.push(value);console.log(JSON.stringify(events))});",
        "var events=[];function make(name,value){return{[Symbol.iterator](){events.push('open:'+name);return{next(){events.push('next:'+name);return{done:false,value:value}},return(){events.push('close:'+name);return{done:true}}}}}};async function run(){const first=1;[first,second]=await Promise.resolve(make('one',42));let second}run().catch(error=>{events.push(error.name);console.log(JSON.stringify(events))});",
        "var events=[];function make(name,value){return{[Symbol.iterator](){events.push('open:'+name);return{next(){events.push('next:'+name);return{done:false,value:value}},return(){events.push('close:'+name);return{done:true}}}}}};function* run(){const[[value=(yield 0)]]=make('outer',make('inner',undefined));return value}var it=run();events.push(it.next().value);events.push(it.return(42).value);console.log(JSON.stringify(events));",
        "var events=[];function make(name,value){return{[Symbol.iterator](){events.push('open:'+name);return{next(){events.push('next:'+name);return{done:false,value:value}},return(){events.push('close:'+name);return{done:true}}}}}};function* run(){try{throw[undefined]}catch([first=(yield 0,second),second=42]){return first}}var it=run();events.push(it.next().value);try{it.next()}catch(error){events.push(error.name)}console.log(JSON.stringify(events));",
        "var events=[];function make(name,value){return{[Symbol.iterator](){events.push('open:'+name);return{next(){events.push('next:'+name);return{done:false,value:value}},return(){events.push('close:'+name);return{done:true}}}}}};function* run(){for(var i=0;i<2;i++){try{const[value=value]=make('i'+i,undefined);yield value}catch(error){events.push(error.name)}}}run().next();console.log(JSON.stringify(events));",
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    for (sources) |source| {
        const native = try std.process.run(allocator, std.testing.io, .{ .argv = &.{ "node", "-e", source } });
        try std.testing.expect(native.term == .exited and native.term.exited == 0);
        for ([_]bool{ false, true }) |full| {
            const output = @import("../transpile.zig").transpile(allocator, source, "input.cjs", .{
                .unsupported = @import("compat.zig").fromESTarget(.es5),
                .minify_syntax = full,
                .minify_identifiers = full,
                .minify_whitespace = full,
            }) catch |err| {
                std.debug.print("lexical TDZ state iterator compile full={} source={s} error={s}\n", .{ full, source, @errorName(err) });
                return err;
            };
            const actual = try std.process.run(allocator, std.testing.io, .{ .argv = &.{ "node", "-e", output.code } });
            if (actual.term != .exited or actual.term.exited != 0 or !std.mem.eql(u8, native.stdout, actual.stdout))
                std.debug.print("lexical TDZ state iterator full={} source={s}\noutput={s}\nstderr={s}\nexpected={s} actual={s}\n", .{ full, source, output.code, actual.stderr, native.stdout, actual.stdout });
            try std.testing.expect(actual.term == .exited and actual.term.exited == 0);
            try std.testing.expectEqualStrings(native.stdout, actual.stdout);
        }
    }
}

test "legacy lexical TDZ iteration pattern initialization separates outer value from inner binding lifetime" {
    const sources = [_][]const u8{
        "function f(){try{for(let[first=second,second=42]of[[]]){}}catch(e){return e.name}}console.log(f())",
        "function f(){try{for(let{first=second,second=42}of[{}]){}}catch(e){return e.name}}console.log(f())",
        "function f(){try{for(let[first=second,second=42]in{'':1}){}}catch(e){return e.name}}console.log(f())",
        "function f(){try{for(let{first=first}of[{}]){}}catch(e){return e.name}}console.log(f())",
        "function f(){var out=[];for(let[value=void 0]of[[],[]]){out.push(typeof value)}return out}console.log(JSON.stringify(f()))",
        "function f(){var out=[];for(let[read=()=>value,value=42]of[[],[]]){out.push(read)}return out.map(fn=>fn())}console.log(JSON.stringify(f()))",
        "function f(){var out=[];for(let{read=()=>value,value=42}of[{},{}]){out.push(read)}return out.map(fn=>fn())}console.log(JSON.stringify(f()))",
        "const Symbol={};function f(){try{for(let{first=second,second=42}of[{}]){}}catch(e){return e.name}}console.log(f())",
        "async function f(){try{for await(let[first=second,second=42]of[[]]){}}catch(e){return e.name}}f().then(console.log)",
        "function* f(){try{for(let[first=second,second=42]of[[]]){yield first}}catch(e){yield e.name}}console.log(JSON.stringify([...f()]))",
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    for (sources) |source| {
        const native = try std.process.run(allocator, std.testing.io, .{ .argv = &.{ "node", "-e", source } });
        try std.testing.expect(native.term == .exited and native.term.exited == 0);
        for ([_]bool{ false, true }) |full| {
            const output = try @import("../transpile.zig").transpile(allocator, source, "input.cjs", .{
                .unsupported = @import("compat.zig").fromESTarget(.es5),
                .minify_syntax = full,
                .minify_identifiers = full,
                .minify_whitespace = full,
            });
            const actual = try std.process.run(allocator, std.testing.io, .{ .argv = &.{ "node", "-e", output.code } });
            if (actual.term != .exited or actual.term.exited != 0 or !std.mem.eql(u8, native.stdout, actual.stdout))
                std.debug.print("lexical TDZ iteration initialization full={} source={s}\noutput={s}\nstderr={s}\nexpected={s} actual={s}\n", .{ full, source, output.code, actual.stderr, native.stdout, actual.stdout });
            try std.testing.expect(actual.term == .exited and actual.term.exited == 0);
            try std.testing.expectEqualStrings(native.stdout, actual.stdout);
        }
    }
}
