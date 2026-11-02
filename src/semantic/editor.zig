//! 변환 중 AST 변경과 함께 의미 정보를 갱신하는 명시적 편집기 (#4819).
//!
//! SymbolId는 한 번 부여하면 이 편집기의 수명 동안 재배정하지 않는다. 이름이나
//! 소스 위치로 바인딩을 다시 찾지 않고, 생성자가 넘긴 scope와 SymbolId를 사용한다.

const std = @import("std");
const Scanner = @import("../lexer/scanner.zig").Scanner;
const ast_mod = @import("../parser/ast.zig");
const scope_mod = @import("scope.zig");
const symbol_mod = @import("symbol.zig");
const scope_owner_proof = @import("scope_owner_proof.zig");

const Ast = ast_mod.Ast;
const NodeIndex = ast_mod.NodeIndex;
const Span = @import("../lexer/token.zig").Span;
const Scope = scope_mod.Scope;
const ScopeId = scope_mod.ScopeId;
const ScopeKind = scope_mod.ScopeKind;
const Symbol = symbol_mod.Symbol;
const SymbolId = symbol_mod.SymbolId;
const SymbolKind = symbol_mod.SymbolKind;
const SyntheticKind = symbol_mod.SyntheticKind;
const Reference = symbol_mod.Reference;
const ReferenceFlags = symbol_mod.ReferenceFlags;

pub const Error = std.mem.Allocator.Error || error{
    InvalidScope,
    InvalidSymbol,
    InvalidNode,
    ScopeOwnerConflict,
    DuplicateBinding,
    AlreadyBound,
    ReferenceNotFound,
};

/// Captured by a producer from its actual source graph before detaching AST.
pub const KnownUnreachableFunction = struct {
    owner: NodeIndex,
    scope: ScopeId,
    params: NodeIndex,
    body: NodeIndex,
    body_scope: ScopeId,
};

/// Arena-owned immutable source graph captured before an in-place producer.
/// Its domain is the actual stable candidate header, never an equal clone.
pub const SourceOwnedFunction = struct {
    domain: *const Ast,
    source_backing: []const u8,
    source: *const Ast,
    graph: *const SemanticEditor,
    functions: []const KnownUnreachableFunction,
    subtree: []const u32,
};

fn sameRetirementNodePayload(a: ast_mod.Node, b: ast_mod.Node) bool {
    if (a.tag != b.tag or !std.meta.eql(a.span, b.span)) return false;
    const width = a.tag.dataWidth();
    return std.mem.eql(u8, std.mem.asBytes(&a.data)[0..width], std.mem.asBytes(&b.data)[0..width]);
}

fn sameInlineBindingEvent(a: @import("inlined_binding_retirement.zig").Event, b: @import("inlined_binding_retirement.zig").Event) bool {
    if (a.domain != b.domain or a.symbol_id != b.symbol_id or !@import("source_owned_retirement.zig").equalSymbol(a.before, b.before) or
        !std.meta.eql(a.declaration, b.declaration) or !std.meta.eql(a.read_origin, b.read_origin) or a.read_step_count != b.read_step_count or a.statement != b.statement or a.binding != b.binding or
        !sameRetirementNodePayload(a.statement_node, b.statement_node) or !sameRetirementNodePayload(a.binding_node, b.binding_node) or
        !sameRetirementNodePayload(a.initializer_node, b.initializer_node) or a.wrapped_initializer != b.wrapped_initializer) return false;
    const x = a.witness;
    const y = b.witness;
    return x.declarator == y.declarator and x.initializer == y.initializer and x.read == y.read and
        sameRetirementNodePayload(x.declarator_node, y.declarator_node) and
        sameRetirementNodePayload(x.read_node, y.read_node) and std.meta.eql(x.read_reference, y.read_reference) and
        x.statement_kind == y.statement_kind and x.source_epoch == y.source_epoch and std.meta.eql(x.source_frame, y.source_frame) and
        std.meta.eql(x.read_frame, y.read_frame);
}

/// 기존 analyzer 결과를 복사해 가변 상태로 보관한다. 원본 slice는 변경하지 않는다.
/// allocator는 모듈 arena여야 한다. 생성한 이름은 최종 출력까지 살아 있어야 한다.
pub const SemanticEditor = struct {
    allocator: std.mem.Allocator,
    ast: *Ast,
    symbols: std.ArrayList(Symbol) = .empty,
    scopes: std.ArrayList(Scope) = .empty,
    scope_maps: std.ArrayList(std.StringHashMapUnmanaged(usize)) = .empty,
    scope_owner_map: std.AutoHashMapUnmanaged(u32, u32) = .empty,
    node_scope_provenance: @import("node_scope_provenance.zig").Map = .empty,
    helper_scope_map: std.StringHashMapUnmanaged(usize) = .empty,
    references: std.ArrayList(Reference) = .empty,
    reference_index: std.AutoHashMapUnmanaged(u32, usize) = .empty,
    reference_index_built: bool = false,
    symbol_ids: std.ArrayList(?u32) = .empty,
    scope_reparented: bool = false,
    source_owned_retirements: @import("source_owned_retirement.zig").Map = .empty,
    scope_history: @import("scope_frame_history.zig").Recorder = .{},

    /// 편집 완료 후 번들러 모듈 또는 단일 파일 출력 경로에 넘길 소유 데이터.
    /// 모든 slice는 init에 전달한 모듈 arena가 소유한다.
    pub const Result = struct {
        symbols: std.ArrayList(Symbol),
        source_owned_retirements: @import("source_owned_retirement.zig").Map = .empty,
        scope_history: @import("scope_frame_history.zig").History = .{},
        scopes: []Scope,
        scope_maps: []std.StringHashMapUnmanaged(usize),
        scope_owner_map: std.AutoHashMapUnmanaged(u32, u32),
        node_scope_provenance: @import("node_scope_provenance.zig").Map = .empty,
        helper_scope_map: std.StringHashMapUnmanaged(usize),
        references: []Reference,
        symbol_ids: []?u32,
    };

    pub fn init(
        allocator: std.mem.Allocator,
        ast: *Ast,
        symbols: []const Symbol,
        scopes: []const Scope,
        scope_maps: []const std.StringHashMapUnmanaged(usize),
        scope_owner_map: std.AutoHashMapUnmanaged(u32, u32),
        references: []const Reference,
        symbol_ids: []const ?u32,
        helper_scope_map: std.StringHashMapUnmanaged(usize),
    ) Error!SemanticEditor {
        if (scopes.len != scope_maps.len) return error.InvalidScope;
        var self: SemanticEditor = .{ .allocator = allocator, .ast = ast };
        errdefer self.deinit();
        try self.symbols.appendSlice(allocator, symbols);
        try self.scopes.appendSlice(allocator, scopes);
        for (scope_maps) |source_map| {
            var map: std.StringHashMapUnmanaged(usize) = .empty;
            errdefer map.deinit(allocator);
            var iter = source_map.iterator();
            while (iter.next()) |entry| {
                try map.put(allocator, entry.key_ptr.*, entry.value_ptr.*);
            }
            try self.scope_maps.append(allocator, map);
        }
        var owner_iter = scope_owner_map.iterator();
        while (owner_iter.next()) |entry| {
            try self.scope_owner_map.put(allocator, entry.key_ptr.*, entry.value_ptr.*);
        }
        var helper_iter = helper_scope_map.iterator();
        while (helper_iter.next()) |entry| {
            try self.helper_scope_map.put(allocator, entry.key_ptr.*, entry.value_ptr.*);
        }
        try self.references.appendSlice(allocator, references);
        try self.symbol_ids.appendSlice(allocator, symbol_ids);
        return self;
    }

    pub fn deinit(self: *SemanticEditor) void {
        for (self.scope_maps.items) |*map| map.deinit(self.allocator);
        self.scope_maps.deinit(self.allocator);
        self.scope_owner_map.deinit(self.allocator);
        self.node_scope_provenance.deinit(self.allocator);
        self.helper_scope_map.deinit(self.allocator);
        self.symbols.deinit(self.allocator);
        self.scopes.deinit(self.allocator);
        self.references.deinit(self.allocator);
        self.reference_index.deinit(self.allocator);
        self.symbol_ids.deinit(self.allocator);
        self.source_owned_retirements.deinit(self.allocator);
        self.scope_history.deinit(self.allocator);
    }

    pub fn finish(self: *SemanticEditor) Error!Result {
        // Every reachable source import expression must retain its actual use
        // scope. Expression provenance is never inferred from scope ownership.
        const reachable = try @import("../parser/ast_walk.zig").collectReachableNodeIndices(self.allocator, self.ast);
        defer self.allocator.free(reachable);
        for (reachable) |raw| {
            const node: NodeIndex = @fromBackingInt(@intCast(raw));
            if (self.ast.getNode(node).tag != .import_expression) continue;
            const scope = self.node_scope_provenance.get(node) orelse return error.InvalidScope;
            if (!self.validScope(scope.scope)) return error.InvalidScope;
        }
        const provenance_root = self.ast.transformed_root orelse if (self.ast.nodes.items.len == 0) NodeIndex.none else @as(NodeIndex, @fromBackingInt(@as(u32, @intCast(self.ast.nodes.items.len - 1))));
        if (self.node_scope_provenance.count() > 0 and !try @import("../transformer/symbol_coverage.zig").validateNodeScopeProvenance(self.allocator, self.ast, provenance_root, &self.scope_owner_map, &self.node_scope_provenance)) return error.InvalidScope;
        var uses = self.node_scope_provenance.iterator();
        while (uses.next()) |entry| {
            if (entry.key_ptr.isNone() or @backingInt(entry.key_ptr.*) >= self.ast.nodes.items.len) return error.InvalidNode;
            if (!self.validScope(entry.value_ptr.scope)) return error.InvalidScope;
        }
        if (self.scope_reparented) {
            for (self.references.items) |ref| {
                if (!self.visibleFrom(ref.symbol_id, ref.scope_id)) return error.InvalidScope;
            }
        }
        // Generated owner child carriers can follow the last identifier in
        // the AST. Publish their actual domain as null slots too, so cached
        // History edges share the same bound as this graph's dense ID table.
        if (self.symbol_ids.items.len < self.ast.nodes.items.len)
            try self.symbol_ids.appendNTimes(self.allocator, null, self.ast.nodes.items.len - self.symbol_ids.items.len);
        const scope_history = self.scope_history.finish(self.allocator) catch |err| return historyError(err);
        const scopes = try self.scopes.toOwnedSlice(self.allocator);
        const scope_maps = try self.scope_maps.toOwnedSlice(self.allocator);
        const references = try self.references.toOwnedSlice(self.allocator);
        const symbol_ids = try self.symbol_ids.toOwnedSlice(self.allocator);
        const retirements = self.source_owned_retirements;
        const symbols = self.symbols;
        const scope_owner_map = self.scope_owner_map;
        const node_scope_provenance = self.node_scope_provenance;
        const helper_scope_map = self.helper_scope_map;
        self.symbols = .empty;
        self.source_owned_retirements = .empty;
        self.scope_owner_map = .empty;
        self.node_scope_provenance = .empty;
        self.helper_scope_map = .empty;
        return .{
            .symbols = symbols,
            .source_owned_retirements = retirements,
            .scope_history = scope_history,
            .scopes = scopes,
            .scope_maps = scope_maps,
            .scope_owner_map = scope_owner_map,
            .node_scope_provenance = node_scope_provenance,
            .helper_scope_map = helper_scope_map,
            .references = references,
            .symbol_ids = symbol_ids,
        };
    }

    pub fn importSourceOwnedRetirements(self: *SemanticEditor, source: @import("source_owned_retirement.zig").Map) Error!void {
        var entries = source.iterator();
        while (entries.next()) |entry| {
            if (self.source_owned_retirements.contains(entry.key_ptr.*)) return error.InvalidSymbol;
            try self.source_owned_retirements.put(self.allocator, entry.key_ptr.*, entry.value_ptr.*);
        }
    }

    pub fn scopeHistoryView(self: *const SemanticEditor) @import("scope_frame_history.zig").History {
        return .{ .source_scopes = self.scope_history.source_scopes, .source_owners = self.scope_history.source_owners, .source_initializers = self.scope_history.source_initializers, .source_computed_awaits = self.scope_history.source_computed_awaits, .worklet_class_creators = self.scope_history.worklet_class_creators.items, .lowered_worklet_classes = self.scope_history.lowered_worklet_classes.items, .source_class_keys = self.scope_history.source_class_keys, .source_dropped_statements = self.scope_history.source_dropped_statements.items, .source_drop_edges = self.scope_history.source_drop_edges.items, .events = self.scope_history.events.items };
    }

    pub fn importScopeHistory(self: *SemanticEditor, source: @import("scope_frame_history.zig").History) Error!void {
        if (self.scope_history.enabled) return error.InvalidScope;
        self.scope_history = @import("scope_frame_history.zig").Recorder.fromHistory(self.allocator, source) catch |err| return historyError(err);
    }

    fn historyError(err: @import("scope_frame_history.zig").Error) Error {
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.InvalidNode => error.InvalidNode,
            else => error.InvalidScope,
        };
    }

    pub fn importNodeScopeProvenance(self: *SemanticEditor, source: @import("node_scope_provenance.zig").Map) Error!void {
        var entries = source.iterator();
        while (entries.next()) |entry| {
            if (!self.scope_history.enabled and entry.value_ptr.source_external != null) {
                self.scope_history = @import("scope_frame_history.zig").Recorder.init(self.allocator, self.ast, self.scopes.items, &self.scope_owner_map) catch |err| return historyError(err);
            }
            try self.node_scope_provenance.put(self.allocator, entry.key_ptr.*, entry.value_ptr.*);
        }
    }

    pub fn recordNodeScopeProvenance(self: *SemanticEditor, node: NodeIndex, scope: ScopeId) Error!void {
        if (!self.validScope(scope)) return error.InvalidScope;
        if (node.isNone() or @backingInt(node) >= self.ast.nodes.items.len) return error.InvalidNode;
        var entry = self.node_scope_provenance.get(node) orelse @import("node_scope_provenance.zig").Entry{ .scope = scope, .source_node = node };
        if (!self.validScope(entry.scope)) return error.InvalidScope;
        if (entry.source_external) |origin| {
            entry.source_external = try @import("source_external_origin.zig").moved(self.allocator, origin, node, entry.source_node, entry.scope, scope, self.scopes.items, self.scope_history.epoch());
        }
        entry.scope = scope;
        try self.node_scope_provenance.put(self.allocator, node, entry);
    }

    pub fn copyNodeScopeProvenance(self: *SemanticEditor, source: NodeIndex, target: NodeIndex) Error!void {
        const scope = self.node_scope_provenance.get(source) orelse return error.InvalidScope;
        if (!self.validScope(scope.scope) or target.isNone() or @backingInt(target) >= self.ast.nodes.items.len) return error.InvalidScope;
        try self.node_scope_provenance.put(self.allocator, target, scope);
    }

    fn validScope(self: *const SemanticEditor, id: ScopeId) bool {
        return !id.isNone() and id.toIndex() < self.scopes.items.len;
    }

    fn validSymbol(self: *const SemanticEditor, id: SymbolId) bool {
        return !id.isNone() and @backingInt(id) < self.symbols.items.len;
    }

    fn validTextSpan(self: *const SemanticEditor, span: Span) bool {
        const start_is_string = span.start & Ast.STRING_TABLE_BIT != 0;
        const end_is_string = span.end & Ast.STRING_TABLE_BIT != 0;
        if (start_is_string != end_is_string) return false;
        const start: usize = @intCast(span.start & ~Ast.STRING_TABLE_BIT);
        const end: usize = @intCast(span.end & ~Ast.STRING_TABLE_BIT);
        const limit = if (start_is_string) self.ast.string_table.items.len else self.ast.source.len;
        return start <= end and end <= limit;
    }

    fn visibleFrom(self: *const SemanticEditor, symbol: SymbolId, scope: ScopeId) bool {
        if (!self.validSymbol(symbol) or !self.validScope(scope)) return false;
        const target = self.symbols.items[@backingInt(symbol)].scope_id;
        var current = scope;
        var hops: usize = 0;
        while (hops < self.scopes.items.len) : (hops += 1) {
            if (current == target) return true;
            current = self.scopes.items[current.toIndex()].parent;
            if (current.isNone() or !self.validScope(current)) return false;
        }
        return false;
    }

    /// Move an existing binding to its emitted storage scope. The SymbolId and
    /// its references remain unchanged; the caller must also move any source
    /// scopes whose live references now execute beneath the new storage scope.
    pub fn relocateSymbol(self: *SemanticEditor, id: SymbolId, target: ScopeId) Error!void {
        if (!self.validSymbol(id)) return error.InvalidSymbol;
        const symbol = &self.symbols.items[@backingInt(id)];
        const name = if (symbol.synthetic_name.len > 0) symbol.synthetic_name else self.ast.getText(symbol.name);
        try self.relocateSymbolWithName(id, target, name, null);
    }

    /// Move and attach an existing binding using its exact emitted name. This
    /// keeps the SymbolId while rekeying the scope map for transforms that
    /// lower distinct same-text bindings into one storage scope with unique
    /// output names.
    fn relocateToOutputBindingName(self: *SemanticEditor, id: SymbolId, target: ScopeId, output_binding: NodeIndex) Error!usize {
        if (!self.validSymbol(id)) return error.InvalidSymbol;
        if (!self.validScope(target)) return error.InvalidScope;
        if (output_binding.isNone() or @backingInt(output_binding) >= self.ast.nodes.items.len) return error.InvalidNode;
        const node = self.ast.getNode(output_binding);
        if (node.tag != .binding_identifier) return error.InvalidNode;
        const output_name_span = node.data.string_ref;
        if (!self.validTextSpan(output_name_span)) return error.InvalidNode;
        if (self.ast.getText(output_name_span).len == 0) return error.InvalidNode;
        const slot = try self.ensureNodeSlot(output_binding);
        if (self.symbol_ids.items[slot]) |existing| {
            if (existing != @backingInt(id)) return error.AlreadyBound;
        }
        const output_name = self.ast.getText(output_name_span);
        const stable_output_name = try self.ast.getTextStable(self.allocator, output_name_span);
        try self.relocateSymbolWithName(id, target, output_name, stable_output_name);
        return slot;
    }

    pub fn relocateSymbolAsPreservingAnchors(self: *SemanticEditor, id: SymbolId, target: ScopeId, output_binding: NodeIndex) Error!void {
        const slot = try self.relocateToOutputBindingName(id, target, output_binding);
        self.symbol_ids.items[slot] = @backingInt(id);
    }

    pub fn relocateSymbolAs(self: *SemanticEditor, id: SymbolId, target: ScopeId, output_binding: NodeIndex) Error!void {
        const slot = try self.relocateToOutputBindingName(id, target, output_binding);
        var has_declaration = false;
        for (self.references.items) |*reference| {
            if (reference.symbol_id != id or !reference.flags.declare) continue;
            reference.scope_id = target;
            reference.declaration_node_index = output_binding;
            has_declaration = true;
        }
        if (!has_declaration) try self.ensureDeclarationAtNode(id, target, output_binding);
        self.symbol_ids.items[slot] = @backingInt(id);
    }

    fn relocateSymbolWithName(self: *SemanticEditor, id: SymbolId, target: ScopeId, target_name: []const u8, stable_output_name: ?[]const u8) Error!void {
        if (!self.validSymbol(id)) return error.InvalidSymbol;
        if (!self.validScope(target)) return error.InvalidScope;
        const symbol = &self.symbols.items[@backingInt(id)];
        const source = symbol.scope_id;
        if (!self.validScope(source)) return error.InvalidScope;
        const name = if (symbol.synthetic_name.len > 0) symbol.synthetic_name else self.ast.getText(symbol.name);
        if (source == target and std.mem.eql(u8, name, target_name)) return;
        const decoded_name = try Scanner.decodeIdentifierEscapesAlloc(self.allocator, name);
        defer if (decoded_name.ptr != name.ptr) self.allocator.free(decoded_name);
        const source_map = &self.scope_maps.items[source.toIndex()];
        if (source_map.get(name) != @as(?usize, @backingInt(id))) return error.InvalidSymbol;
        const target_map = &self.scope_maps.items[target.toIndex()];
        if (target_map.get(target_name)) |existing| {
            if (existing != @backingInt(id)) return error.DuplicateBinding;
            if (source != target) return error.DuplicateBinding;
        }
        if (source != target and (self.scopes.items[target.toIndex()].symbol_count == std.math.maxInt(u16) or
            self.scopes.items[source.toIndex()].symbol_count == 0)) return error.InvalidScope;
        // A generated output name can point into Ast.string_table, which may
        // reallocate during later transforms. Store the owned copy when the
        // emitted binding was string-table backed.
        try target_map.put(self.allocator, stable_output_name orelse target_name, @backingInt(id));
        _ = source_map.remove(name);
        if (self.takeDecodedAlias(source, name, decoded_name, @backingInt(id))) |alias| {
            // 같은 표기로 옮길 때만 디코딩 별칭도 따라간다. 새 이름으로 바뀌면 별칭은 더 이상 맞지 않는다.
            if (std.mem.eql(u8, target_name, name) and target_map.get(alias) == null) {
                try target_map.put(self.allocator, alias, @backingInt(id));
            }
        }
        if (source != target) {
            self.scopes.items[source.toIndex()].symbol_count -= 1;
            self.scopes.items[target.toIndex()].symbol_count += 1;
        }
        if (stable_output_name) |output_name| symbol.synthetic_name = output_name;
        symbol.scope_id = target;
        symbol.origin_scope = target;
        // The declaration record represents the binding site too. When the
        // declaration is moved with its SymbolId, keep that record in the
        // destination scope so finish() can validate the relocated graph.
        for (self.references.items) |*reference| {
            if (reference.symbol_id == id and reference.flags.declare)
                reference.scope_id = target;
        }
        self.scope_reparented = true;
    }

    /// Reserve the emitted spelling before lowering parameter initializers.
    /// The source graph can contain both a parameter and a later same-named
    /// body function (or repeated functions), with the scope map pointing only
    /// at the final body function. Rekey each exact SID without removing that
    /// distinct winner until its own emitted spelling is reserved.
    /// This is not a general escape hatch for inconsistent scope maps.
    pub fn renameParameterEnvironmentBinding(self: *SemanticEditor, id: SymbolId, output_name: []const u8) Error!void {
        try self.renameParameterEnvironmentBindingImpl(id, output_name, false);
    }

    /// A dynamic body wrapper gives a colliding body `var` its own local
    /// binding. In that one proven case, rename the parameter side even though
    /// body `eval` marks its parent parameter scope as un-mangleable.
    pub fn renameParameterEnvironmentBindingForDynamicBody(
        self: *SemanticEditor,
        id: SymbolId,
        output_name: []const u8,
    ) Error!void {
        try self.renameParameterEnvironmentBindingImpl(id, output_name, true);
    }

    fn renameParameterEnvironmentBindingImpl(
        self: *SemanticEditor,
        id: SymbolId,
        output_name: []const u8,
        allow_dynamic_body_var_shadow: bool,
    ) Error!void {
        if (!self.validSymbol(id)) return error.InvalidSymbol;
        const symbol = &self.symbols.items[@backingInt(id)];
        if (!self.validScope(symbol.scope_id)) return error.InvalidScope;
        const scope = self.scopes.items[symbol.scope_id.toIndex()];
        if (scope.kind != .function or
            (scope.blocksMangling() and
                (!allow_dynamic_body_var_shadow or !self.hasDynamicBodyVarShadow(id)))) return error.InvalidScope;
        if (symbol.kind != .parameter and symbol.kind != .variable_var and
            symbol.kind != .variable_let and symbol.kind != .variable_const and
            symbol.kind != .class_decl and !symbol.kind.isFunctionLike()) return error.InvalidSymbol;
        if (output_name.len == 0) return error.InvalidNode;
        const map = &self.scope_maps.items[symbol.scope_id.toIndex()];
        const old_name = if (symbol.synthetic_name.len > 0) symbol.synthetic_name else self.ast.getText(symbol.name);
        const old_id = map.get(old_name) orelse return error.InvalidSymbol;
        if (old_id != @backingInt(id)) {
            if ((symbol.kind != .parameter and !symbol.kind.isFunctionLike()) or old_id >= self.symbols.items.len) return error.InvalidSymbol;
            const body_symbol = self.symbols.items[old_id];
            if (!body_symbol.kind.isFunctionLike() or body_symbol.scope_id != symbol.scope_id) return error.InvalidSymbol;
            const body_name = if (body_symbol.synthetic_name.len > 0) body_symbol.synthetic_name else self.ast.getText(body_symbol.name);
            if (!std.mem.eql(u8, body_name, old_name)) return error.InvalidSymbol;
        } else if (symbol.kind == .parameter) {
            // Parameter expressions and a non-simple function body now have
            // distinct source scopes. When the corresponding body map still
            // contains this spelling, it is valid evidence only for the
            // function declaration alias that used to share the map entry.
            if (self.parameterBodyFunctionScope(symbol.scope_id)) |body_scope| {
                if (self.scope_maps.items[body_scope.toIndex()].get(old_name)) |body_id| {
                    if (body_id != @backingInt(id)) {
                        if (body_id >= self.symbols.items.len) return error.InvalidSymbol;
                        const body_symbol = self.symbols.items[body_id];
                        // A body `var` with the parameter's spelling is a distinct
                        // binding once parameter expressions split the environments;
                        // lowering copies the parameter value into it (#5452).
                        const valid_body_alias = body_symbol.kind.isFunctionLike() or
                            body_symbol.kind == .variable_var;
                        if (!valid_body_alias or body_symbol.scope_id != body_scope)
                            return error.InvalidSymbol;
                        const body_name = if (body_symbol.synthetic_name.len > 0) body_symbol.synthetic_name else self.ast.getText(body_symbol.name);
                        if (!std.mem.eql(u8, body_name, old_name)) return error.InvalidSymbol;
                    }
                }
            }
        }
        if (map.contains(output_name)) return error.DuplicateBinding;
        const decoded_name = try Scanner.decodeIdentifierEscapesAlloc(self.allocator, old_name);
        defer if (decoded_name.ptr != old_name.ptr) self.allocator.free(decoded_name);
        const stable_name = try self.allocator.dupe(u8, output_name);
        try map.put(self.allocator, stable_name, @backingInt(id));
        if (old_id == @backingInt(id)) _ = map.remove(old_name);
        _ = self.takeDecodedAlias(symbol.scope_id, old_name, decoded_name, @backingInt(id));
        symbol.synthetic_name = stable_name;
        const declaration_node = self.bindingNodeForSymbol(id) orelse .none;
        try self.ensureDeclarationAtNode(id, symbol.scope_id, declaration_node);
    }

    fn hasDynamicBodyVarShadow(self: *const SemanticEditor, id: SymbolId) bool {
        if (!self.validSymbol(id)) return false;
        const parameter = self.symbols.items[@backingInt(id)];
        if (parameter.kind != .parameter) return false;
        const body_scope = self.parameterBodyFunctionScope(parameter.scope_id) orelse return false;
        if (!self.scopes.items[body_scope.toIndex()].blocksMangling()) return false;
        const name = if (parameter.synthetic_name.len > 0) parameter.synthetic_name else self.ast.getText(parameter.name);
        const body_raw = self.scope_maps.items[body_scope.toIndex()].get(name) orelse return false;
        if (body_raw >= self.symbols.items.len or body_raw == @backingInt(id)) return false;
        const body_var = self.symbols.items[body_raw];
        return body_var.kind == .variable_var and body_var.scope_id == body_scope;
    }

    fn parameterBodyFunctionScope(self: *const SemanticEditor, parameter_scope: ScopeId) ?ScopeId {
        if (!self.validScope(parameter_scope)) return null;
        for (self.ast.nodes.items, 0..) |function, raw| {
            const slot: u32 = switch (function.tag) {
                .arrow_function_expression => 0,
                .function_declaration, .function_expression, .function, .method_definition => 1,
                else => continue,
            };
            if (!self.ast.hasExtra(function.data.extra, slot)) continue;
            const params_raw = self.ast.extra_data.items[function.data.extra + slot];
            if (params_raw == @backingInt(NodeIndex.none) or
                self.scope_owner_map.get(params_raw) != @as(?u32, @backingInt(parameter_scope))) continue;
            const body_raw = self.scope_owner_map.get(@intCast(raw)) orelse continue;
            if (body_raw >= self.scopes.items.len) continue;
            const body_scope: ScopeId = @fromBackingInt(@intCast(body_raw));
            if (self.scopes.items[body_raw].kind == .function and self.scopes.items[body_raw].parent == parameter_scope)
                return body_scope;
        }
        return null;
    }

    pub fn attachExistingBinding(self: *SemanticEditor, node: NodeIndex, id: SymbolId) Error!void {
        if (!self.validSymbol(id)) return error.InvalidSymbol;
        const slot = try self.ensureNodeSlot(node);
        if (self.ast.getNode(node).tag != .binding_identifier) return error.InvalidNode;
        if (self.symbol_ids.items[slot]) |existing| {
            if (existing != @backingInt(id)) return error.AlreadyBound;
        } else {
            self.symbol_ids.items[slot] = @backingInt(id);
        }
        self.reanchorDeclaration(id, node);
    }

    /// Attach a generated `var` redeclaration to its existing var-scope
    /// identity. Source analysis merges these declarations without replacing
    /// the original declaration reference, so keep that behavior here too.
    pub fn attachVarRedeclaration(self: *SemanticEditor, node: NodeIndex, id: SymbolId, lexical_scope: ScopeId) Error!void {
        if (!self.validSymbol(id)) return error.InvalidSymbol;
        const slot = try self.ensureNodeSlot(node);
        const binding = self.ast.getNode(node);
        if (binding.tag != .binding_identifier) return error.InvalidNode;
        const target = try self.bindingScope(lexical_scope, .variable_var);
        const symbol = self.symbols.items[@backingInt(id)];
        if (symbol.scope_id != target) return error.InvalidScope;
        const compatible_kind = symbol.kind == .parameter or symbol.kind == .variable_var or symbol.kind.isFunctionLike();
        if (!compatible_kind) return error.DuplicateBinding;
        const existing_name = if (symbol.synthetic_name.len > 0) symbol.synthetic_name else self.ast.getText(symbol.name);
        const incoming_name = self.ast.getText(binding.data.string_ref);
        if (!Scanner.identifierNamesEqual(existing_name, incoming_name)) return error.InvalidSymbol;
        if (self.symbol_ids.items[slot]) |existing| {
            if (existing != @backingInt(id)) return error.AlreadyBound;
        } else {
            // The analyzer records each duplicate `var` declaration as a
            // declaration row so tree shaking keeps its initializer write.
            // Parameter merges intentionally have no extra declaration row.
            if (symbol.kind == .variable_var or symbol.kind.isFunctionLike()) {
                try self.references.append(self.allocator, .{
                    .node_index = .none,
                    .declaration_node_index = node,
                    .scope_id = target,
                    .symbol_id = id,
                    .stmt_idx = Reference.NO_STMT,
                    .scope_stmt_idx = Reference.NO_STMT,
                    .flags = .{ .declare = true },
                });
            }
            self.symbol_ids.items[slot] = @backingInt(id);
        }
    }

    /// Change the exact identity of an output binding after a lowering splits
    /// one source binding into separate storage and callback bindings.
    pub fn rebindBinding(self: *SemanticEditor, node: NodeIndex, id: SymbolId) Error!void {
        if (!self.validSymbol(id)) return error.InvalidSymbol;
        const slot = try self.ensureNodeSlot(node);
        const binding = self.ast.getNode(node);
        if (binding.tag != .binding_identifier) return error.InvalidNode;
        const symbol = self.symbols.items[@backingInt(id)];
        const expected_name = if (symbol.synthetic_name.len > 0) symbol.synthetic_name else self.ast.getText(symbol.name);
        if (!std.mem.eql(u8, self.ast.getText(binding.data.string_ref), expected_name)) return error.InvalidSymbol;
        self.symbol_ids.items[slot] = @backingInt(id);
        self.reanchorDeclaration(id, node);
    }

    fn reanchorDeclaration(self: *SemanticEditor, id: SymbolId, binding: NodeIndex) void {
        // One var-scope binding can have several declarations (`function f`
        // twice, `var f` + `function f`), each anchoring its own row (#5803).
        // A rebound copy keeps its source name's span, so move only the rows
        // anchored at that source position; a lone row moves as before.
        var rows: usize = 0;
        for (self.references.items) |reference| {
            if (reference.symbol_id == id and reference.flags.declare) rows += 1;
        }
        const binding_span = self.ast.getNode(binding).span;
        for (self.references.items) |*reference| {
            if (reference.symbol_id != id or !reference.flags.declare) continue;
            if (rows > 1 and !reference.declaration_node_index.isNone() and
                @backingInt(reference.declaration_node_index) < self.ast.nodes.items.len and
                !std.meta.eql(self.ast.getNode(reference.declaration_node_index).span, binding_span)) continue;
            reference.declaration_node_index = binding;
        }
    }

    /// Give one emitted storage binding a fresh SymbolId while retaining the
    /// source SymbolId for a callback parameter that represents each iteration.
    pub fn splitBindingIdentity(
        self: *SemanticEditor,
        node: NodeIndex,
        expected: SymbolId,
        lexical_scope: ScopeId,
        kind: SymbolKind,
        declaration_span: Span,
    ) Error!SymbolId {
        const slot = try self.ensureNodeSlot(node);
        const binding = self.ast.getNode(node);
        if (binding.tag != .binding_identifier) return error.InvalidNode;
        const old_span = binding.data.string_ref;
        // 출력 바인딩은 디코딩한 이름으로 선언한다 — `\u0078` 원문 키만 두면 `x` 로 쓴 참조가
        // 이 심볼을 scope map 에서 찾지 못한다 (#5667). 같은 식별자라 출력 의미는 같다.
        const raw_name = self.ast.getText(old_span);
        const name = try Scanner.decodeIdentifierEscapesAlloc(self.allocator, raw_name);
        defer if (name.ptr != raw_name.ptr) self.allocator.free(name);
        // A copied output binding can already carry the exact ID in the
        // Transformer's side table while this editor's lazy copy still has an
        // empty slot. Attach that caller-verified identity before splitting.
        if (self.symbol_ids.items[slot]) |existing| {
            if (existing != @backingInt(expected)) return error.InvalidSymbol;
        } else {
            self.symbol_ids.items[slot] = @backingInt(expected);
        }
        const target = try self.bindingScope(lexical_scope, kind);
        if (self.scope_maps.items[target.toIndex()].get(name)) |existing_raw| {
            if (existing_raw >= self.symbols.items.len) return error.InvalidSymbol;
            const existing = self.symbols.items[existing_raw];
            const existing_name = if (existing.synthetic_name.len > 0) existing.synthetic_name else self.ast.getText(existing.name);
            // Multiple emitted `var` declarations with the same function
            // scope and name are one JavaScript binding. Preserve that exact
            // runtime identity instead of manufacturing a duplicate map key.
            if (kind == .variable_var and existing.kind == .variable_var and
                existing.scope_id == target and Scanner.identifierNamesEqual(existing_name, name))
            {
                const existing_id: SymbolId = @fromBackingInt(@intCast(@as(u32, @intCast(existing_raw))));
                self.symbol_ids.items[slot] = @backingInt(existing_id);
                return existing_id;
            }
            // Block function declarations can share one analyzer SymbolId
            // through aliases in sibling lexical scopes. If output emission
            // splits those declarations into distinct block bindings, replace
            // only this alias before declaring the output identity.
            if (existing_raw == @backingInt(expected) and existing.scope_id != target) {
                _ = self.scope_maps.items[target.toIndex()].remove(name);
            } else {
                return error.DuplicateBinding;
            }
        }
        const name_span = try self.ast.addString(name);
        self.ast.nodes.items[@backingInt(node)].data.string_ref = name_span;
        self.symbol_ids.items[slot] = null;
        return self.declare(node, name_span, declaration_span, lexical_scope, kind, Reference.NO_STMT, Reference.NO_STMT) catch |err| {
            self.ast.nodes.items[@backingInt(node)].data.string_ref = old_span;
            self.symbol_ids.items[slot] = @backingInt(expected);
            return err;
        };
    }

    pub fn symbolVisibleFrom(self: *const SemanticEditor, symbol: SymbolId, scope: ScopeId) bool {
        return self.visibleFrom(symbol, scope);
    }

    fn requireIdentifier(self: *const SemanticEditor, idx: NodeIndex) Error!void {
        if (idx.isNone() or @backingInt(idx) >= self.ast.nodes.items.len) return error.InvalidNode;
        switch (self.ast.getNode(idx).tag) {
            .binding_identifier, .identifier_reference, .assignment_target_identifier, .jsx_identifier => {},
            else => return error.InvalidNode,
        }
    }

    fn ensureNodeSlot(self: *SemanticEditor, idx: NodeIndex) Error!usize {
        try self.requireIdentifier(idx);
        const i = @backingInt(idx);
        if (self.symbol_ids.items.len <= i) {
            try self.symbol_ids.appendNTimes(self.allocator, null, i + 1 - self.symbol_ids.items.len);
        }
        return i;
    }

    fn ensureHelperImportSlot(self: *SemanticEditor, idx: NodeIndex) Error!usize {
        if (idx.isNone() or @backingInt(idx) >= self.ast.nodes.items.len) return error.InvalidNode;
        const i: usize = @intCast(@backingInt(idx));
        if (self.symbol_ids.items.len <= i) {
            try self.symbol_ids.appendNTimes(self.allocator, null, i + 1 - self.symbol_ids.items.len);
        }
        return i;
    }

    fn appendReference(self: *SemanticEditor, ref: Reference) Error!void {
        if (self.reference_index_built and !ref.node_index.isNone()) {
            const key = @backingInt(ref.node_index);
            if (self.reference_index.contains(key)) return error.AlreadyBound;
            try self.reference_index.put(self.allocator, key, self.references.items.len);
            errdefer _ = self.reference_index.remove(key);
        }
        try self.references.append(self.allocator, ref);
    }

    fn ensureReferenceIndex(self: *SemanticEditor) Error!void {
        if (self.reference_index_built) return;
        for (self.references.items, 0..) |ref, i| {
            if (!ref.node_index.isNone() and !self.reference_index.contains(@backingInt(ref.node_index))) {
                try self.reference_index.put(self.allocator, @backingInt(ref.node_index), i);
            }
        }
        self.reference_index_built = true;
    }

    /// Return the single stored reference for this node, building the index on
    /// first use. Transform finalizers use this before relocating live copies.
    pub fn referenceForNode(self: *SemanticEditor, node: NodeIndex) Error!?Reference {
        if (node.isNone()) return null;
        try self.ensureReferenceIndex();
        const index = self.reference_index.get(@backingInt(node)) orelse return null;
        return self.references.items[index];
    }

    pub const EmptyArrowScopeElision = struct {
        owner: NodeIndex,
        scope: ScopeId,
        parent: ScopeId,
        /// Exact arrow payload captured by the producer before its call is folded.
        source: @import("../parser/ast.zig").Node,
    };

    /// Retire a proven empty arrow frame after an in-place IIFE fold. Existing
    /// symbols keep their IDs/storage scopes; only uses and child owners cross
    /// this exact now-absent lexical boundary. No name resolution happens here.
    pub fn elideEmptyArrowScopeOwner(self: *SemanticEditor, plan: EmptyArrowScopeElision) Error!void {
        if (plan.owner.isNone() or @backingInt(plan.owner) >= self.ast.nodes.items.len or
            !self.validScope(plan.scope) or !self.validScope(plan.parent) or
            self.scope_owner_map.get(@backingInt(plan.owner)) != @backingInt(plan.scope)) return error.InvalidScope;
        const source = plan.source;
        const actual_source = self.ast.getNode(plan.owner);
        if (source.tag != actual_source.tag or source.tag != .arrow_function_expression or
            !std.meta.eql(source.span, actual_source.span) or source.data.extra != actual_source.data.extra) return error.InvalidNode;
        if (source.tag != .arrow_function_expression or self.ast.functionParams(source).len != 0 or
            !self.ast.hasExtra(source.data.extra, @import("../parser/ast.zig").ArrowExtra.flags) or
            self.ast.readExtra(source.data.extra, @import("../parser/ast.zig").ArrowExtra.flags) & @import("../parser/ast.zig").ArrowFlags.is_async != 0) return error.InvalidNode;
        const frame = self.scopes.items[plan.scope.toIndex()];
        if (frame.parent != plan.parent or frame.kind != .function or frame.blocksMangling() or
            frame.symbol_count != 0 or self.scope_maps.items[plan.scope.toIndex()].count() != 0 or
            frame.is_strict != self.scopes.items[plan.parent.toIndex()].is_strict) return error.InvalidScope;
        for (self.symbols.items) |symbol| if (symbol.scope_id == plan.scope) return error.InvalidScope;
        for (self.references.items) |reference| {
            if (reference.scope_id == plan.scope and !self.visibleFrom(reference.symbol_id, plan.parent)) return error.InvalidScope;
        }
        var provenance = self.node_scope_provenance.valueIterator();
        while (provenance.next()) |entry| if (entry.scope == plan.scope and entry.with_environment) return error.InvalidScope;
        // Prepare immutable use-scope receipts before changing any graph row.
        const PreparedOrigin = struct { node: NodeIndex, entry: @import("node_scope_provenance.zig").Entry };
        var prepared_origins: std.ArrayList(PreparedOrigin) = .empty;
        defer prepared_origins.deinit(self.allocator);
        var origin_entries = self.node_scope_provenance.iterator();
        while (origin_entries.next()) |entry| {
            if (entry.value_ptr.scope != plan.scope) continue;
            var next = entry.value_ptr.*;
            if (next.source_external) |origin| next.source_external = try @import("source_external_origin.zig").elided(self.allocator, origin, entry.key_ptr.*, next.source_node, plan.scope, plan.parent, self.scopes.items, plan.owner, plan.source, self.scope_history.epoch());
            next.scope = plan.parent;
            try prepared_origins.append(self.allocator, .{ .node = entry.key_ptr.*, .entry = next });
        }
        // Each actual child reparent has its own trigger scope; propagated
        // strict/dynamic rows are recorded by the same operation.
        for (self.scopes.items, 0..) |child, raw| {
            if (child.parent == plan.scope) try self.reparentScope(@fromBackingInt(@as(u32, @intCast(raw))), plan.parent);
        }
        for (self.references.items) |*reference| if (reference.scope_id == plan.scope) {
            reference.scope_id = plan.parent;
        };
        for (prepared_origins.items) |prepared| self.node_scope_provenance.getPtr(prepared.node).?.* = prepared.entry;
        _ = try self.removeScopeOwner(plan.owner);
        self.scope_reparented = true;
    }

    /// Publish only the supplied actual scope-owner edge. Recording happens
    /// before the map mutation; no final-map reconciliation creates history.
    pub fn putScopeOwner(self: *SemanticEditor, owner: NodeIndex, scope: ScopeId) Error!void {
        if (!self.validScope(scope) or owner.isNone() or @backingInt(owner) >= self.ast.nodes.items.len) return error.InvalidScope;
        const raw = @backingInt(owner);
        const before = self.scope_owner_map.get(raw);
        if (before == @backingInt(scope)) return;
        const epoch = self.scope_history.events.items.len;
        errdefer self.scope_history.events.shrinkRetainingCapacity(epoch);
        if (before) |old| self.scope_history.recordOwner(self.allocator, self.ast, @fromBackingInt(old), self.scopes.items[old], owner, .none, .{}) catch |err| return historyError(err);
        self.scope_history.recordOwner(self.allocator, self.ast, scope, self.scopes.items[scope.toIndex()], .none, owner, .{}) catch |err| return historyError(err);
        try self.scope_owner_map.put(self.allocator, raw, @backingInt(scope));
    }

    pub fn removeScopeOwner(self: *SemanticEditor, owner: NodeIndex) Error!bool {
        const raw = @backingInt(owner);
        const scope = self.scope_owner_map.get(raw) orelse return false;
        self.scope_history.recordOwner(self.allocator, self.ast, @fromBackingInt(scope), self.scopes.items[scope], owner, .none, .{}) catch |err| return historyError(err);
        return self.scope_owner_map.remove(raw);
    }

    /// AST가 새 어휘 경계를 만들 때 호출한다. strict는 부모에서 자식으로 전파된다.
    pub fn addScope(self: *SemanticEditor, parent: ScopeId, owner: NodeIndex, kind: ScopeKind, is_strict: bool) Error!ScopeId {
        if (!parent.isNone() and !self.validScope(parent)) return error.InvalidScope;
        if (parent.isNone() and self.scopes.items.len != 0) return error.InvalidScope;
        if (!owner.isNone() and @backingInt(owner) >= self.ast.nodes.items.len) return error.InvalidNode;
        const intrinsically_strict = kind == .module or kind == .class_body or kind == .class_static_block;
        const strict = is_strict or intrinsically_strict or
            (if (parent.isNone()) false else self.scopes.items[parent.toIndex()].is_strict);
        const id: ScopeId = @fromBackingInt(@intCast(@as(u32, @intCast(self.scopes.items.len))));
        const frame: Scope = .{ .parent = parent, .kind = kind, .is_strict = strict };
        const epoch = self.scope_history.events.items.len;
        errdefer self.scope_history.events.shrinkRetainingCapacity(epoch);
        self.scope_history.recordBirth(self.allocator, self.ast, id, frame, owner, .{}) catch |err| return historyError(err);
        try self.scopes.append(self.allocator, frame);
        errdefer _ = self.scopes.pop();
        try self.scope_maps.append(self.allocator, .empty);
        if (!owner.isNone()) try self.scope_owner_map.put(self.allocator, @backingInt(owner), @backingInt(id));
        return id;
    }

    /// 동일한 어휘 경계를 가진 노드를 트랜스포머가 복사했을 때 소유자를 새 AST 노드로 옮긴다.
    /// 기존 노드를 재방문해도 scope_id를 새로 만들지 않는다.
    pub fn remapScopeOwner(self: *SemanticEditor, old_owner: NodeIndex, new_owner: NodeIndex) Error!void {
        if (old_owner.isNone() or new_owner.isNone() or
            @backingInt(old_owner) >= self.ast.nodes.items.len or
            @backingInt(new_owner) >= self.ast.nodes.items.len) return error.InvalidNode;
        const old_key = @backingInt(old_owner);
        const new_key = @backingInt(new_owner);
        const old_tag = self.ast.getNode(old_owner).tag;
        const new_tag = self.ast.getNode(new_owner).tag;
        if (old_tag != new_tag and
            !(old_tag == .arrow_function_expression and new_tag == .function_expression) and
            !(old_tag == .for_of_statement and new_tag == .for_statement) and
            !(old_tag == .for_await_of_statement and new_tag == .while_statement) and
            !(old_tag == .block_statement and new_tag == .while_statement) and
            !(old_tag == .class_declaration and new_tag == .class_expression) and
            !(old_tag == .class_expression and new_tag == .class_declaration) and
            !(old_tag == .function_declaration and new_tag == .function_expression) and
            !(old_tag == .method_definition and (new_tag == .function_declaration or new_tag == .function_expression)))
            return error.InvalidNode;
        const scope_id = self.scope_owner_map.get(old_key) orelse return error.InvalidScope;
        if (old_key == new_key) return;
        if (scope_id >= self.scopes.items.len) return error.InvalidScope;
        if (self.scope_owner_map.get(new_key)) |existing| {
            if (existing != scope_id) return error.ScopeOwnerConflict;
        }
        // Preserve the actual copy edge as one ordered transition. A pair of
        // independent insertion/removal events loses its source-owner lineage.
        try self.scope_owner_map.ensureUnusedCapacity(self.allocator, 1);
        self.scope_history.recordOwner(self.allocator, self.ast, @fromBackingInt(scope_id), self.scopes.items[scope_id], old_owner, new_owner, .{}) catch |err| return historyError(err);
        _ = self.scope_owner_map.remove(old_key);
        self.scope_owner_map.putAssumeCapacity(new_key, scope_id);
    }

    /// Transfer an owner after a controlled in-place rewrite changed the old
    /// node's tag before semantic edits are finalized. The caller must have
    /// recorded this exact replacement; all node, scope, and conflict checks
    /// still apply here.
    pub fn remapScopeOwnerAfterInPlaceRewrite(self: *SemanticEditor, old_owner: NodeIndex, new_owner: NodeIndex) Error!void {
        if (old_owner.isNone() or new_owner.isNone() or
            @backingInt(old_owner) >= self.ast.nodes.items.len or
            @backingInt(new_owner) >= self.ast.nodes.items.len) return error.InvalidNode;
        const old_key = @backingInt(old_owner);
        const new_key = @backingInt(new_owner);
        const scope_id = self.scope_owner_map.get(old_key) orelse return error.InvalidScope;
        if (old_key == new_key) return;
        if (self.scope_owner_map.get(new_key)) |existing| {
            if (existing != scope_id) return error.ScopeOwnerConflict;
        } else {
            try self.putScopeOwner(new_owner, @fromBackingInt(scope_id));
        }
        _ = try self.removeScopeOwner(old_owner);
    }

    /// Remove an empty generated block boundary after a lowering flattens its
    /// owner node out of the output AST. Children keep their own scopes and
    /// are reparented to the removed scope's parent; a scope with bindings or
    /// references cannot be elided.
    pub fn elideEmptyGeneratedScopeOwner(self: *SemanticEditor, owner: NodeIndex) Error!bool {
        if (owner.isNone() or @backingInt(owner) >= self.ast.nodes.items.len) return error.InvalidNode;
        const owner_raw = @backingInt(owner);
        const scope_raw = self.scope_owner_map.get(owner_raw) orelse return false;
        if (scope_raw >= self.scopes.items.len) return error.InvalidScope;
        const scope_id: ScopeId = @fromBackingInt(@intCast(scope_raw));
        const scope = self.scopes.items[scope_raw];
        if (scope.kind != .block and scope.kind != .switch_block) return false;
        if (scope.parent.isNone() or !self.validScope(scope.parent)) return error.InvalidScope;
        if (scope.symbol_count != 0 or self.scope_maps.items[scope_raw].count() != 0) return false;
        for (self.symbols.items) |symbol| {
            if (symbol.scope_id == scope_id or symbol.origin_scope == scope_id) return false;
        }
        for (self.references.items) |reference| {
            if (reference.scope_id == scope_id) return false;
        }
        var owner_iter = self.scope_owner_map.iterator();
        while (owner_iter.next()) |entry| {
            if (entry.key_ptr.* != owner_raw and entry.value_ptr.* == scope_raw) return false;
        }

        const parent = scope.parent;
        const prepared_scopes = try self.allocator.dupe(Scope, self.scopes.items);
        defer self.allocator.free(prepared_scopes);
        prepared_scopes[parent.toIndex()].subtree_has_direct_eval =
            prepared_scopes[parent.toIndex()].subtree_has_direct_eval or scope.subtree_has_direct_eval;
        prepared_scopes[parent.toIndex()].subtree_has_with =
            prepared_scopes[parent.toIndex()].subtree_has_with or scope.subtree_has_with;
        self.scope_history.recordFrames(self.allocator, self.ast, self.scopes.items, prepared_scopes, &self.scope_owner_map, scope_id, parent, .{}) catch |err| return historyError(err);
        @memcpy(self.scopes.items, prepared_scopes);
        for (self.scopes.items, 0..) |child, child_index| {
            if (child.parent == scope_id) try self.reparentScope(@fromBackingInt(@intCast(@as(u32, @intCast(child_index)))), parent);
        }
        _ = try self.removeScopeOwner(owner);
        return true;
    }

    /// AST 서브트리를 새 함수 안으로 옮길 때 기존 스코프 ID를 유지하며 부모만 바꾼다.
    /// 호출자는 이전 부모에만 보이던 참조를 finish 전에 재바인딩하거나 제거해야 한다.
    pub fn reparentScope(self: *SemanticEditor, scope: ScopeId, new_parent: ScopeId) Error!void {
        if (!self.validScope(scope) or !self.validScope(new_parent)) return error.InvalidScope;
        if (self.scopes.items[scope.toIndex()].parent.isNone()) return error.InvalidScope;
        var cursor = new_parent;
        var hops: usize = 0;
        while (!cursor.isNone()) : (hops += 1) {
            if (hops >= self.scopes.items.len or !self.validScope(cursor) or cursor == scope) return error.InvalidScope;
            cursor = self.scopes.items[cursor.toIndex()].parent;
        }
        if (self.scopes.items[scope.toIndex()].parent == new_parent) return;

        if (self.scope_history.enabled) {
            const before = try self.allocator.dupe(Scope, self.scopes.items);
            defer self.allocator.free(before);
            const epoch = self.scope_history.events.items.len;
            const before_reparented = self.scope_reparented;
            // This recorder is disabled only inside the existing deterministic
            // operation; the original before array is restored on any error.
            self.scope_history.enabled = false;
            self.reparentScope(scope, new_parent) catch |err| {
                @memcpy(self.scopes.items, before);
                self.scope_reparented = before_reparented;
                self.scope_history.enabled = true;
                return err;
            };
            self.scope_history.enabled = true;
            self.scope_history.recordFrames(self.allocator, self.ast, before, self.scopes.items, &self.scope_owner_map, scope, new_parent, .{}) catch |err| {
                @memcpy(self.scopes.items, before);
                self.scope_reparented = before_reparented;
                self.scope_history.events.shrinkRetainingCapacity(epoch);
                return historyError(err);
            };
            return;
        }
        const was_strict = self.scopes.items[scope.toIndex()].is_strict;
        self.scopes.items[scope.toIndex()].parent = new_parent;
        self.scope_reparented = true;
        const new_strict = self.scopes.items[new_parent.toIndex()].is_strict;
        if (new_strict and !was_strict) {
            for (self.scopes.items, 0..) |*candidate, i| {
                var ancestor: ScopeId = @fromBackingInt(@intCast(@as(u32, @intCast(i))));
                var depth: usize = 0;
                while (!ancestor.isNone() and depth < self.scopes.items.len) : (depth += 1) {
                    if (!self.validScope(ancestor)) return error.InvalidScope;
                    if (ancestor == scope) {
                        candidate.is_strict = true;
                        break;
                    }
                    ancestor = self.scopes.items[ancestor.toIndex()].parent;
                }
            }
        }
        const moved = self.scopes.items[scope.toIndex()];
        cursor = new_parent;
        hops = 0;
        while (!cursor.isNone() and hops < self.scopes.items.len) : (hops += 1) {
            const ancestor = &self.scopes.items[cursor.toIndex()];
            ancestor.subtree_has_direct_eval = ancestor.subtree_has_direct_eval or moved.subtree_has_direct_eval;
            ancestor.subtree_has_with = ancestor.subtree_has_with or moved.subtree_has_with;
            cursor = ancestor.parent;
        }
    }

    /// analyzer 는 escape 로 쓴 이름(`\u0078`)을 원문 키와 디코딩 키(`x`) 둘 다로 넣는다.
    /// 원문 키를 옮기거나 지울 때 디코딩 키가 옛 스코프에 남으면 `x` 참조가 이 심볼로
    /// 잘못 풀린다 (#5667). 디코딩 키가 같은 심볼을 가리키면 떼어내 그 키를 돌려준다.
    fn takeDecodedAlias(self: *SemanticEditor, scope: ScopeId, name: []const u8, decoded_name: []const u8, symbol_index: usize) ?[]const u8 {
        if (std.mem.eql(u8, decoded_name, name)) return null;
        const map = &self.scope_maps.items[scope.toIndex()];
        if (map.get(decoded_name) != symbol_index) return null;
        return (map.fetchRemove(decoded_name) orelse return null).key;
    }

    /// Move one exact binding when lowering replaces its lexical boundary with
    /// a generated boundary that encloses all surviving references.
    pub fn moveSymbolToScope(self: *SemanticEditor, symbol: SymbolId, new_scope: ScopeId) Error!void {
        if (!self.validSymbol(symbol) or !self.validScope(new_scope)) return error.InvalidScope;
        const symbol_index = @backingInt(symbol);
        const old_scope = self.symbols.items[symbol_index].scope_id;
        if (old_scope == new_scope) return;
        if (!self.validScope(old_scope)) return error.InvalidScope;
        // A renamed symbol (e.g. a split parameter) is keyed by its emitted spelling.
        const synthetic_name = self.symbols.items[symbol_index].synthetic_name;
        const name = if (synthetic_name.len > 0)
            synthetic_name
        else
            try self.ast.getTextStable(self.allocator, self.symbols.items[symbol_index].name);
        if (self.scope_maps.items[old_scope.toIndex()].get(name) != symbol_index) return error.InvalidScope;
        const decoded_name = try Scanner.decodeIdentifierEscapesAlloc(self.allocator, name);
        defer if (decoded_name.ptr != name.ptr) self.allocator.free(decoded_name);
        if (self.scope_maps.items[new_scope.toIndex()].get(name)) |existing| {
            if (existing != symbol_index) return error.DuplicateBinding;
        } else {
            try self.scope_maps.items[new_scope.toIndex()].put(self.allocator, name, symbol_index);
        }
        _ = self.scope_maps.items[old_scope.toIndex()].remove(name);
        if (self.takeDecodedAlias(old_scope, name, decoded_name, symbol_index)) |alias| {
            if (self.scope_maps.items[new_scope.toIndex()].get(alias) == null) {
                try self.scope_maps.items[new_scope.toIndex()].put(self.allocator, alias, symbol_index);
            }
        }
        std.debug.assert(self.scopes.items[old_scope.toIndex()].symbol_count > 0);
        self.scopes.items[old_scope.toIndex()].symbol_count -= 1;
        self.scopes.items[new_scope.toIndex()].symbol_count +|= 1;
        self.symbols.items[symbol_index].scope_id = new_scope;
        for (self.references.items) |*reference| {
            if (reference.symbol_id == symbol and reference.flags.declare) reference.scope_id = new_scope;
        }
    }

    /// 서브트리 이전 시 기존 참조가 새 바인딩을 가리키도록 바꾼다.
    pub fn rebindReference(self: *SemanticEditor, node: NodeIndex, symbol: SymbolId) Error!void {
        if (!self.validSymbol(symbol)) return error.InvalidSymbol;
        try self.ensureReferenceIndex();
        const slot = try self.ensureNodeSlot(node);
        const i = self.reference_index.get(@backingInt(node)) orelse return error.ReferenceNotFound;
        const ref = &self.references.items[i];
        if (ref.flags.declare) return error.InvalidNode;
        if (!self.visibleFrom(symbol, ref.scope_id)) return error.InvalidScope;
        self.removeCounts(ref.symbol_id, ref.flags);
        ref.symbol_id = symbol;
        self.symbol_ids.items[slot] = @backingInt(symbol);
        self.addCounts(symbol, ref.flags);
    }

    /// 참조의 위치와 대상을 함께 바꾼다. 이전 대상은 새 스코프에서 보이지 않고
    /// 새 대상은 이전 스코프에서 보이지 않는 경우에도 최종 쌍만 유효하면 이동한다.
    /// 오류가 나면 Reference, SymbolId, 사용 횟수는 변경하지 않는다.
    pub fn relocateReference(
        self: *SemanticEditor,
        node: NodeIndex,
        scope: ScopeId,
        symbol: SymbolId,
        stmt_idx: u32,
        scope_stmt_idx: u32,
    ) Error!void {
        if (!self.validScope(scope)) return error.InvalidScope;
        if (!self.validSymbol(symbol)) return error.InvalidSymbol;
        try self.requireIdentifier(node);
        if (self.ast.getNode(node).tag == .binding_identifier) return error.InvalidNode;
        try self.ensureReferenceIndex();
        const i = self.reference_index.get(@backingInt(node)) orelse return error.ReferenceNotFound;
        const current = self.references.items[i];
        if (current.flags.declare or (!current.flags.read and !current.flags.write)) return error.InvalidNode;
        if (!self.validScope(current.scope_id)) return error.InvalidScope;
        if (!self.validSymbol(current.symbol_id)) return error.InvalidSymbol;
        const slot = @backingInt(node);
        if (slot >= self.symbol_ids.items.len or self.symbol_ids.items[slot] != @as(?u32, @backingInt(current.symbol_id)))
            return error.InvalidSymbol;
        if (!self.visibleFrom(symbol, scope)) return error.InvalidScope;

        if (current.symbol_id != symbol and countsAsValue(current.flags)) {
            const source_counts = self.symbols.items[@backingInt(current.symbol_id)];
            const target_counts = self.symbols.items[@backingInt(symbol)];
            if (source_counts.reference_count == 0 or target_counts.reference_count == std.math.maxInt(u32))
                return error.InvalidSymbol;
            if (current.flags.write and
                (source_counts.write_count == 0 or target_counts.write_count == std.math.maxInt(u32)))
                return error.InvalidSymbol;
        }

        if (current.symbol_id != symbol) {
            self.removeCounts(current.symbol_id, current.flags);
            self.addCounts(symbol, current.flags);
        }
        self.references.items[i].scope_id = scope;
        self.references.items[i].symbol_id = symbol;
        self.references.items[i].stmt_idx = stmt_idx;
        self.references.items[i].scope_stmt_idx = scope_stmt_idx;
        self.symbol_ids.items[slot] = @backingInt(symbol);
    }

    /// AST 복사가 만든 새 식별자에 원본 참조의 대상과 read/write 플래그를 복제한다.
    /// 원본 노드가 최종 AST에서 사라졌다면 caller가 removeReference로 정리한다.
    pub fn cloneReference(self: *SemanticEditor, source: NodeIndex, clone: NodeIndex, scope: ScopeId, stmt_idx: u32, scope_stmt_idx: u32) Error!void {
        try self.ensureReferenceIndex();
        const source_i = self.reference_index.get(@backingInt(source)) orelse return error.ReferenceNotFound;
        const ref = self.references.items[source_i];
        if (ref.flags.declare) return error.InvalidNode;
        return self.addCopiedReference(clone, ref.symbol_id, scope, ref.flags, stmt_idx, scope_stmt_idx);
    }

    pub fn cloneReferenceAtSameLocation(self: *SemanticEditor, source: NodeIndex, clone: NodeIndex) Error!void {
        try self.ensureReferenceIndex();
        const i = self.reference_index.get(@backingInt(source)) orelse return error.ReferenceNotFound;
        const ref = self.references.items[i];
        return self.cloneReference(source, clone, ref.scope_id, ref.stmt_idx, ref.scope_stmt_idx);
    }

    fn bindingScope(self: *const SemanticEditor, lexical_scope: ScopeId, kind: SymbolKind) Error!ScopeId {
        if (!self.validScope(lexical_scope)) return error.InvalidScope;
        if (kind != .variable_var) return lexical_scope;
        var scope = lexical_scope;
        var hops: usize = 0;
        while (hops < self.scopes.items.len) : (hops += 1) {
            if (self.scopes.items[scope.toIndex()].kind.isVarScope()) return scope;
            scope = self.scopes.items[scope.toIndex()].parent;
            if (scope.isNone() or !self.validScope(scope)) return error.InvalidScope;
        }
        return error.InvalidScope;
    }

    /// Reserve a generated `var` identity before its final declaration node
    /// exists. The hoister later attaches the emitted binding to this SymbolId.
    pub fn reserveSyntheticTempSymbol(
        self: *SemanticEditor,
        name_span: Span,
        declaration_span: Span,
        lexical_scope: ScopeId,
    ) Error!SymbolId {
        if (name_span.start & Ast.STRING_TABLE_BIT == 0) return error.InvalidNode;
        const target = try self.bindingScope(lexical_scope, .variable_var);
        const name = try self.ast.getTextStable(self.allocator, name_span);
        if (self.scope_maps.items[target.toIndex()].contains(name)) return error.DuplicateBinding;

        const id: SymbolId = @fromBackingInt(@intCast(@as(u32, @intCast(self.symbols.items.len))));
        try self.symbols.append(self.allocator, .{
            .name = name_span,
            .scope_id = target,
            .origin_scope = lexical_scope,
            .kind = .variable_var,
            .decl_flags = SymbolKind.variable_var.declFlags(),
            .declaration_span = declaration_span,
            .synthetic_name = name,
        });
        errdefer _ = self.symbols.pop();
        try self.scope_maps.items[target.toIndex()].put(self.allocator, name, @backingInt(id));
        errdefer _ = self.scope_maps.items[target.toIndex()].remove(name);
        try self.references.append(self.allocator, .{
            .node_index = .none,
            .declaration_node_index = .none,
            .scope_id = target,
            .symbol_id = id,
            .stmt_idx = Reference.NO_STMT,
            .scope_stmt_idx = Reference.NO_STMT,
            .flags = .{ .declare = true },
        });
        self.scopes.items[target.toIndex()].symbol_count +|= 1;
        return id;
    }

    /// 새 합성 바인딩을 선언한다. name_span은 AST string table의 이름이어야 한다.
    /// stmt_idx는 최상위 문장, scope_stmt_idx는 직접 소속된 스코프의 문장 인덱스다.
    pub fn declare(
        self: *SemanticEditor,
        binding: NodeIndex,
        name_span: Span,
        declaration_span: Span,
        lexical_scope: ScopeId,
        kind: SymbolKind,
        stmt_idx: u32,
        scope_stmt_idx: u32,
    ) Error!SymbolId {
        const node_slot = try self.ensureNodeSlot(binding);
        if (self.ast.getNode(binding).tag != .binding_identifier) return error.InvalidNode;
        if (name_span.start & Ast.STRING_TABLE_BIT == 0) return error.InvalidNode;
        if (!std.mem.eql(u8, self.ast.getText(self.ast.getNode(binding).data.string_ref), self.ast.getText(name_span))) return error.InvalidNode;
        if (self.symbol_ids.items[node_slot] != null) return error.AlreadyBound;
        const target = try self.bindingScope(lexical_scope, kind);
        const name = try self.ast.getTextStable(self.allocator, name_span);
        if (self.scope_maps.items[target.toIndex()].get(name)) |_| {
            return error.DuplicateBinding;
        }
        const id: SymbolId = @fromBackingInt(@intCast(@as(u32, @intCast(self.symbols.items.len))));
        try self.symbols.append(self.allocator, .{
            .name = name_span,
            .scope_id = target,
            .origin_scope = lexical_scope,
            .kind = kind,
            .decl_flags = kind.declFlags(),
            .declaration_span = declaration_span,
            .synthetic_name = name,
        });
        try self.scope_maps.items[target.toIndex()].put(self.allocator, name, @backingInt(id));
        try self.references.append(self.allocator, .{
            .node_index = .none,
            .declaration_node_index = binding,
            .scope_id = target,
            .symbol_id = id,
            .stmt_idx = stmt_idx,
            .scope_stmt_idx = scope_stmt_idx,
            .flags = .{ .declare = true },
        });
        self.symbol_ids.items[node_slot] = @backingInt(id);
        self.scopes.items[target.toIndex()].symbol_count +|= 1;
        return id;
    }

    /// 헬퍼 import의 local은 parser reference 노드거나 default specifier 노드다.
    /// 사용자 동명 선언과 충돌해도 별도 helper_scope_map에 보관한다.
    pub fn declareHelperImport(self: *SemanticEditor, local: NodeIndex, name_span: Span, declaration_span: Span, scope: ScopeId) Error!SymbolId {
        if (!self.validScope(scope)) return error.InvalidScope;
        if (name_span.start & Ast.STRING_TABLE_BIT == 0) return error.InvalidNode;
        const slot = try self.ensureHelperImportSlot(local);
        switch (self.ast.getNode(local).tag) {
            .identifier_reference, .import_default_specifier => {},
            else => return error.InvalidNode,
        }
        if (self.symbol_ids.items[slot] != null) return error.AlreadyBound;
        if (self.helper_scope_map.contains(self.ast.getText(name_span))) return error.DuplicateBinding;
        const id = try self.reserveRuntimeHelperSymbol(name_span, declaration_span, scope, false, false);
        try self.attachRuntimeHelperImport(local, id, declaration_span);
        return id;
    }

    /// Reserve a helper SymbolId as soon as its first generated reference is
    /// created. The later import specifier attaches to this same ID; the local
    /// spelling only interns the helper declaration in helper_scope_map.
    pub fn reserveRuntimeHelperSymbol(
        self: *SemanticEditor,
        name_span: Span,
        declaration_span: Span,
        scope: ScopeId,
        is_preamble: bool,
        defer_import_name: bool,
    ) Error!SymbolId {
        if (!self.validScope(scope)) return error.InvalidScope;
        if (name_span.start & Ast.STRING_TABLE_BIT == 0) return error.InvalidNode;
        const name = try self.ast.getTextStable(self.allocator, name_span);
        if (self.helper_scope_map.get(name)) |raw_id| {
            if (raw_id >= self.symbols.items.len) return error.InvalidSymbol;
            const existing = self.symbols.items[raw_id];
            const expected_kind: ?SyntheticKind = if (is_preamble)
                .runtime_helper_preamble
            else if (defer_import_name)
                .runtime_helper_import
            else
                null;
            if (existing.scope_id != scope or existing.kind != .import_binding or
                !std.mem.eql(u8, existing.synthetic_name, name) or
                existing.synthetic_kind != expected_kind)
                return error.DuplicateBinding;
            return @fromBackingInt(@intCast(raw_id));
        }

        const id: SymbolId = @fromBackingInt(@intCast(@as(u32, @intCast(self.symbols.items.len))));
        try self.symbols.append(self.allocator, .{
            .name = name_span,
            .scope_id = scope,
            .origin_scope = scope,
            .kind = .import_binding,
            .decl_flags = SymbolKind.import_binding.declFlags(),
            .declaration_span = declaration_span,
            .synthetic_kind = if (is_preamble) .runtime_helper_preamble else if (defer_import_name) .runtime_helper_import else null,
            .synthetic_name = name,
            .output_name_hint = if (defer_import_name and !is_preamble) name else "",
        });
        errdefer _ = self.symbols.pop();
        try self.helper_scope_map.put(self.allocator, name, @backingInt(id));
        errdefer _ = self.helper_scope_map.remove(name);
        var added_scope_binding = false;
        if (!self.scope_maps.items[scope.toIndex()].contains(name)) {
            try self.scope_maps.items[scope.toIndex()].put(self.allocator, name, @backingInt(id));
            self.scopes.items[scope.toIndex()].symbol_count +|= 1;
            added_scope_binding = true;
        }
        errdefer if (added_scope_binding) {
            _ = self.scope_maps.items[scope.toIndex()].remove(name);
            self.scopes.items[scope.toIndex()].symbol_count -= 1;
        };
        try self.references.append(self.allocator, .{
            .node_index = .none,
            .scope_id = scope,
            .symbol_id = id,
            .stmt_idx = Reference.NO_STMT,
            .scope_stmt_idx = Reference.NO_STMT,
            .flags = .{ .declare = true },
        });
        return id;
    }

    /// Attach the generated import's local node to a helper ID reserved by an
    /// earlier call. This does not create a second declaration or SymbolId.
    pub fn attachRuntimeHelperImport(self: *SemanticEditor, local: NodeIndex, id: SymbolId, declaration_span: Span) Error!void {
        if (!self.validSymbol(id)) return error.InvalidSymbol;
        const slot = try self.ensureHelperImportSlot(local);
        switch (self.ast.getNode(local).tag) {
            .identifier_reference, .import_default_specifier => {},
            else => return error.InvalidNode,
        }
        if (self.symbol_ids.items[slot] != null) return error.AlreadyBound;
        const symbol = &self.symbols.items[@backingInt(id)];
        if (symbol.kind != .import_binding or symbol.synthetic_kind == .runtime_helper_preamble)
            return error.InvalidSymbol;
        const local_name = try self.ast.getTextStable(self.allocator, self.ast.getNode(local).data.string_ref);
        if (!std.mem.eql(u8, symbol.synthetic_name, local_name) or
            self.helper_scope_map.get(local_name) != @as(?usize, @backingInt(id)))
            return error.InvalidSymbol;
        var declaration_reference: ?*Reference = null;
        for (self.references.items) |*reference| {
            if (reference.symbol_id != id or !reference.flags.declare) continue;
            if (!reference.declaration_node_index.isNone() and reference.declaration_node_index != local)
                return error.InvalidSymbol;
            declaration_reference = reference;
            break;
        }
        const declaration = declaration_reference orelse return error.ReferenceNotFound;
        self.symbol_ids.items[slot] = @backingInt(id);
        symbol.name = self.ast.getNode(local).data.string_ref;
        symbol.declaration_span = declaration_span;
        declaration.declaration_node_index = local;
    }

    /// 단일 파일 출력의 AST 밖 런타임 helper 선언을 helper 심볼로 등록한다.
    /// 이름은 최종 preamble이 출력할 alias이며, AST 노드 대신 helper_scope_map으로 연결한다.
    pub fn declareRuntimeHelperPreamble(self: *SemanticEditor, name_span: Span, declaration_span: Span, scope: ScopeId) Error!SymbolId {
        if (!self.validScope(scope)) return error.InvalidScope;
        if (name_span.start & Ast.STRING_TABLE_BIT == 0) return error.InvalidNode;
        const name = self.ast.getText(name_span);
        if (self.helper_scope_map.contains(name)) return error.DuplicateBinding;
        return self.reserveRuntimeHelperSymbol(name_span, declaration_span, scope, true, false);
    }

    fn countsAsValue(flags: ReferenceFlags) bool {
        return !flags.declare and !flags.type_context and !flags.value_as_type;
    }

    fn addCounts(self: *SemanticEditor, id: SymbolId, flags: ReferenceFlags) void {
        if (!countsAsValue(flags)) return;
        const sym = &self.symbols.items[@backingInt(id)];
        sym.reference_count += 1;
        if (flags.write) sym.write_count += 1;
    }

    fn removeCounts(self: *SemanticEditor, id: SymbolId, flags: ReferenceFlags) void {
        if (!countsAsValue(flags)) return;
        const sym = &self.symbols.items[@backingInt(id)];
        std.debug.assert(sym.reference_count > 0);
        sym.reference_count -= 1;
        if (flags.write) {
            std.debug.assert(sym.write_count > 0);
            sym.write_count -= 1;
        }
    }

    /// 참조 대상은 이름 검색 없이 호출자가 넘긴 SymbolId로 확정한다.
    pub fn addReference(
        self: *SemanticEditor,
        node: NodeIndex,
        symbol: SymbolId,
        scope: ScopeId,
        flags: ReferenceFlags,
        stmt_idx: u32,
        scope_stmt_idx: u32,
    ) Error!void {
        if (!self.validSymbol(symbol)) return error.InvalidSymbol;
        if (!self.validScope(scope)) return error.InvalidScope;
        if (!self.visibleFrom(symbol, scope)) return error.InvalidScope;
        const slot = try self.ensureNodeSlot(node);
        if (self.ast.getNode(node).tag == .binding_identifier or flags.declare) return error.InvalidNode;
        if (self.symbol_ids.items[slot] != null) return error.AlreadyBound;
        try self.appendReference(.{
            .node_index = node,
            .scope_id = scope,
            .symbol_id = symbol,
            .stmt_idx = stmt_idx,
            .scope_stmt_idx = scope_stmt_idx,
            .flags = flags,
        });
        self.symbol_ids.items[slot] = @backingInt(symbol);
        self.addCounts(symbol, flags);
    }

    /// 새 참조에 SymbolId가 먼저 복사된 경로에서 Reference를 명시적으로 붙인다.
    /// 같은 ID여도 이미 Reference가 있으면 중복으로 거부한다.
    pub fn addCopiedReference(
        self: *SemanticEditor,
        node: NodeIndex,
        symbol: SymbolId,
        scope: ScopeId,
        flags: ReferenceFlags,
        stmt_idx: u32,
        scope_stmt_idx: u32,
    ) Error!void {
        if (!self.validSymbol(symbol)) return error.InvalidSymbol;
        if (!self.validScope(scope) or !self.visibleFrom(symbol, scope)) return error.InvalidScope;
        const slot = try self.ensureNodeSlot(node);
        if (self.ast.getNode(node).tag == .binding_identifier or flags.declare) return error.InvalidNode;
        if (self.symbol_ids.items[slot]) |existing| {
            if (existing != @backingInt(symbol)) return error.AlreadyBound;
        }
        try self.ensureReferenceIndex();
        try self.appendReference(.{
            .node_index = node,
            .scope_id = scope,
            .symbol_id = symbol,
            .stmt_idx = stmt_idx,
            .scope_stmt_idx = scope_stmt_idx,
            .flags = flags,
        });
        self.symbol_ids.items[slot] = @backingInt(symbol);
        self.addCounts(symbol, flags);
    }

    /// Update one node's access mode without changing its symbol or location.
    /// Compound-assignment lowering uses this to turn its original target into
    /// a write and add a separate read reference for the generated value use.
    pub fn updateReferenceFlags(self: *SemanticEditor, node: NodeIndex, flags: ReferenceFlags) Error!void {
        if (flags.declare) return error.InvalidNode;
        try self.ensureReferenceIndex();
        const i = self.reference_index.get(@backingInt(node)) orelse return error.ReferenceNotFound;
        const current = self.references.items[i];
        if (current.flags.declare) return error.InvalidNode;
        if (!self.validSymbol(current.symbol_id) or !self.validScope(current.scope_id)) return error.InvalidSymbol;
        self.removeCounts(current.symbol_id, current.flags);
        self.references.items[i].flags = flags;
        self.addCounts(current.symbol_id, flags);
    }

    /// Preserve declaration evidence when a transform materializes an AST
    /// binding for a symbol that already exists (for example an export facade).
    /// The legacy declaration row stays node-less for stmt-info consumers, and
    /// the optional exact anchor records the AST binding separately.
    pub fn ensureDeclaration(self: *SemanticEditor, symbol: SymbolId, scope: ScopeId) Error!void {
        return self.ensureDeclarationAtNode(symbol, scope, self.bindingNodeForSymbol(symbol) orelse .none);
    }

    fn bindingNodeForSymbol(self: *const SemanticEditor, symbol: SymbolId) ?NodeIndex {
        for (self.symbol_ids.items, 0..) |maybe_id, raw| {
            if (maybe_id != @backingInt(symbol) or raw >= self.ast.nodes.items.len) continue;
            if (self.ast.nodes.items[raw].tag == .binding_identifier) return @fromBackingInt(@intCast(raw));
        }
        return null;
    }

    pub fn ensureDeclarationAtNode(
        self: *SemanticEditor,
        symbol: SymbolId,
        scope: ScopeId,
        declaration_node_index: NodeIndex,
    ) Error!void {
        if (!self.validSymbol(symbol) or !self.validScope(scope)) return error.InvalidScope;
        if (self.symbols.items[@backingInt(symbol)].scope_id != scope) return error.InvalidScope;
        for (self.references.items) |*reference| {
            if (reference.symbol_id == symbol and reference.flags.declare) {
                if (reference.declaration_node_index.isNone() and !declaration_node_index.isNone())
                    reference.declaration_node_index = declaration_node_index;
                return;
            }
        }
        try self.references.append(self.allocator, .{
            .node_index = .none,
            .declaration_node_index = declaration_node_index,
            .scope_id = scope,
            .symbol_id = symbol,
            .stmt_idx = Reference.NO_STMT,
            .scope_stmt_idx = Reference.NO_STMT,
            .flags = .{ .declare = true },
        });
    }

    /// 서브트리를 다른 문장이나 스코프로 옮긴 경우 참조의 소유권을 수정한다.
    pub fn moveReference(self: *SemanticEditor, node: NodeIndex, scope: ScopeId, stmt_idx: u32, scope_stmt_idx: u32) Error!void {
        if (!self.validScope(scope)) return error.InvalidScope;
        try self.ensureReferenceIndex();
        const i = self.reference_index.get(@backingInt(node)) orelse return error.ReferenceNotFound;
        const ref = &self.references.items[i];
        if (!self.visibleFrom(ref.symbol_id, scope)) return error.InvalidScope;
        ref.scope_id = scope;
        ref.stmt_idx = stmt_idx;
        ref.scope_stmt_idx = scope_stmt_idx;
    }

    /// 제거된 참조의 사용 횟수도 되돌린다. 다른 참조의 순서는 유지한다.
    pub fn removeReference(self: *SemanticEditor, node: NodeIndex) Error!void {
        try self.ensureReferenceIndex();
        const key = @backingInt(node);
        const i = self.reference_index.get(key) orelse return error.ReferenceNotFound;
        const ref = self.references.items[i];
        if (!self.validSymbol(ref.symbol_id)) return error.InvalidSymbol;
        self.removeCounts(ref.symbol_id, ref.flags);
        _ = self.references.orderedRemove(i);
        _ = self.reference_index.remove(key);
        for (self.references.items[i..], i..) |moved, new_i| {
            if (!moved.node_index.isNone()) {
                if (self.reference_index.getPtr(@backingInt(moved.node_index))) |indexed| indexed.* = new_i;
            }
        }
        if (key < self.symbol_ids.items.len) self.symbol_ids.items[key] = null;
    }

    /// Remove several references while preserving the order of the survivors.
    /// Compacting once avoids shifting and reindexing the full tail for every
    /// removed reference. The editor allocator is the module arena, so the
    /// selection bitset is released with the semantic snapshot.
    pub fn removeReferences(self: *SemanticEditor, nodes: []const NodeIndex) Error!void {
        if (nodes.len == 0) return;
        try self.ensureReferenceIndex();

        var removed = try std.DynamicBitSet.initEmpty(self.allocator, self.references.items.len);
        for (nodes) |node| {
            const key = @backingInt(node);
            const i = self.reference_index.get(key) orelse return error.ReferenceNotFound;
            if (i >= self.references.items.len or removed.isSet(i)) return error.ReferenceNotFound;
            const ref = self.references.items[i];
            if (!self.validSymbol(ref.symbol_id)) return error.InvalidSymbol;
            removed.set(i);
        }

        var write: usize = 0;
        for (self.references.items, 0..) |ref, read| {
            if (removed.isSet(read)) {
                self.removeCounts(ref.symbol_id, ref.flags);
                if (!ref.node_index.isNone()) {
                    const key = @backingInt(ref.node_index);
                    _ = self.reference_index.remove(key);
                    if (key < self.symbol_ids.items.len) self.symbol_ids.items[key] = null;
                }
                continue;
            }

            if (write != read) {
                self.references.items[write] = ref;
                if (!ref.node_index.isNone()) {
                    if (self.reference_index.getPtr(@backingInt(ref.node_index))) |indexed| {
                        indexed.* = write;
                    }
                }
            }
            write += 1;
        }
        self.references.shrinkRetainingCapacity(write);
    }

    /// Discard declaration rows anchored at one exact, removed binding node.
    /// Other declarations and reads/writes of this same SymbolId remain live.
    /// Declaration rows use node_index=.none, so removeReference cannot select
    /// them by their binding anchor.
    /// Move only the exact source declaration anchor selected by its producer.
    /// A copied first binding must not absorb the other declarations of a
    /// merged enum. Validate every matching row before any mutation.
    pub fn reanchorDeclarationFromNode(self: *SemanticEditor, owner: *const Ast, source: NodeIndex, output: NodeIndex, expected: SymbolId) Error!usize {
        if (owner != self.ast) return error.InvalidNode;
        if (!self.validSymbol(expected)) return error.InvalidSymbol;
        if (source.isNone() or output.isNone() or @backingInt(source) >= self.ast.nodes.items.len or
            @backingInt(output) >= self.ast.nodes.items.len or self.ast.getNode(source).tag != .binding_identifier or
            self.ast.getNode(output).tag != .binding_identifier) return error.InvalidNode;
        const input_raw = @backingInt(source);
        const output_raw = @backingInt(output);
        if (input_raw >= self.symbol_ids.items.len or output_raw >= self.symbol_ids.items.len or
            self.symbol_ids.items[input_raw] != @backingInt(expected) or self.symbol_ids.items[output_raw] != @backingInt(expected)) return error.InvalidSymbol;
        var matches: usize = 0;
        for (self.references.items) |reference| {
            if (!reference.flags.declare or reference.declaration_node_index != source) continue;
            if (reference.symbol_id != expected) return error.InvalidSymbol;
            matches += 1;
        }
        if (matches == 0) return error.ReferenceNotFound;
        // Distinct statement records may legitimately share one canonical
        // source-var anchor. Preserve them all, but reject an exact duplicate
        // tuple (including a collision with the proposed output anchor).
        for (self.references.items, 0..) |reference, index| {
            if (!reference.flags.declare or reference.declaration_node_index != source) continue;
            var moved = reference;
            moved.declaration_node_index = output;
            for (self.references.items[0..index]) |earlier| {
                var other = earlier;
                if (other.flags.declare and other.declaration_node_index == source) other.declaration_node_index = output;
                if (std.meta.eql(moved, other)) return error.DuplicateBinding;
            }
            for (self.references.items[index + 1 ..]) |later| {
                if (later.flags.declare and later.declaration_node_index == output and std.meta.eql(moved, later)) return error.DuplicateBinding;
            }
        }
        for (self.references.items) |*reference| {
            if (reference.flags.declare and reference.declaration_node_index == source)
                reference.declaration_node_index = output;
        }
        return matches;
    }

    /// Candidate-only import storage handoff. The caller proves the module
    /// owner/backing and installs the prefix AST plus coordinates atomically.
    /// This primitive neither publishes a complete holder nor changes uses.
    pub const KnownNamespaceDeclarationMove = struct {
        ast: *const Ast,
        root: NodeIndex,
        root_scope: ScopeId,
        symbol: SymbolId,
        source_specifier: NodeIndex,
        source_declaration: NodeIndex,
        declaration_row: usize,
        expected_source_flags: symbol_mod.DeclFlags,
        output_binding: NodeIndex,
        output_declarator: NodeIndex,
        output_statement: NodeIndex,
    };

    pub fn moveKnownNamespaceImportToConst(self: *SemanticEditor, input: KnownNamespaceDeclarationMove) Error!void {
        if (input.ast != self.ast) return error.InvalidNode;
        const nodes = [_]NodeIndex{ input.root, input.source_specifier, input.source_declaration, input.output_binding, input.output_declarator, input.output_statement };
        for (nodes) |node| if (node.isNone() or @backingInt(node) >= self.ast.nodes.items.len) return error.InvalidNode;
        if (!self.validSymbol(input.symbol)) return error.InvalidSymbol;
        if (!self.validScope(input.root_scope)) return error.InvalidScope;
        const root = self.ast.getNode(input.root);
        const root_scope = self.scopes.items[input.root_scope.toIndex()];
        if (root.tag != .program or root_scope.kind != .module or !root_scope.parent.isNone() or
            self.scope_owner_map.get(@backingInt(input.root)) != @as(?u32, @backingInt(input.root_scope))) return error.InvalidScope;
        const symbol = self.symbols.items[@backingInt(input.symbol)];
        const namespace_flags: symbol_mod.DeclFlags = .{ .is_import = true, .is_namespace_import = true };
        if (symbol.kind != .import_binding or symbol.synthetic_kind != null or
            input.expected_source_flags.toInt() != namespace_flags.toInt() or
            symbol.decl_flags.toInt() != input.expected_source_flags.toInt() or
            symbol.scope_id != input.root_scope or symbol.origin_scope != input.root_scope or
            symbol.synthetic_name.len != 0 or symbol.output_name_hint.len != 0 or symbol.synthetic_owner_id != null)
            return error.InvalidSymbol;
        // Keep the source span and its borrowed scope-map key unchanged.
        if (!self.validTextSpan(symbol.name) or symbol.name.start & Ast.STRING_TABLE_BIT != 0) return error.InvalidSymbol;
        const name = self.ast.getText(symbol.name);
        if (name.len == 0 or (!std.ascii.isAlphabetic(name[0]) and name[0] != '_' and name[0] != '$')) return error.InvalidSymbol;
        for (name) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '_' and byte != '$') return error.InvalidSymbol;
        if (self.scope_maps.items[input.root_scope.toIndex()].get(name) != @as(?usize, @backingInt(input.symbol))) return error.InvalidSymbol;
        const source_raw = @backingInt(input.source_specifier);
        const output_raw = @backingInt(input.output_binding);
        if (input.source_specifier == input.output_binding or source_raw >= self.symbol_ids.items.len or
            self.symbol_ids.items[source_raw] != @as(?u32, @backingInt(input.symbol)) or
            (output_raw < self.symbol_ids.items.len and self.symbol_ids.items[output_raw] != null)) return error.InvalidSymbol;
        const source = self.ast.getNode(input.source_declaration);
        if (self.ast.getNode(input.source_specifier).tag != .import_namespace_specifier or source.tag != .import_declaration or
            !self.ast.hasExtra(source.data.extra, 5)) return error.InvalidNode;
        const extra = self.ast.extra_data.items;
        const spec_start = extra[source.data.extra];
        if (extra[source.data.extra + 1] != 1 or spec_start >= extra.len or extra[spec_start] != source_raw or
            extra[source.data.extra + 3] != 0 or extra[source.data.extra + 5] != 0) return error.InvalidNode;
        if (root.data.list.start > extra.len or root.data.list.len > extra.len - root.data.list.start) return error.InvalidNode;
        var source_count: usize = 0;
        for (extra[root.data.list.start..][0..root.data.list.len]) |raw| {
            if (raw >= self.ast.nodes.items.len or raw == @backingInt(input.output_statement)) return error.InvalidNode;
            if (raw == @backingInt(input.source_declaration)) source_count += 1;
        }
        if (source_count != 1) return error.InvalidNode;
        const binding = self.ast.getNode(input.output_binding);
        const declarator = self.ast.getNode(input.output_declarator);
        const statement = self.ast.getNode(input.output_statement);
        if (binding.tag != .binding_identifier or !std.meta.eql(binding.data.string_ref, symbol.name) or
            declarator.tag != .variable_declarator or !self.ast.hasExtra(declarator.data.extra, 2) or
            statement.tag != .variable_declaration or !self.ast.hasExtra(statement.data.extra, 2)) return error.InvalidNode;
        if (extra[declarator.data.extra] != output_raw or extra[declarator.data.extra + 1] != @backingInt(NodeIndex.none) or
            extra[declarator.data.extra + 2] == @backingInt(NodeIndex.none) or extra[declarator.data.extra + 2] >= self.ast.nodes.items.len or
            extra[statement.data.extra] != @backingInt(ast_mod.VariableDeclarationKind.@"const") or extra[statement.data.extra + 2] != 1) return error.InvalidNode;
        const declarations = extra[statement.data.extra + 1];
        if (declarations >= extra.len or extra[declarations] != @backingInt(input.output_declarator)) return error.InvalidNode;
        if (input.declaration_row >= self.references.items.len) return error.ReferenceNotFound;
        var count: usize = 0;
        for (self.references.items, 0..) |reference, index| {
            if (!reference.flags.declare) continue;
            if (reference.declaration_node_index == input.output_binding) return error.InvalidSymbol;
            if (reference.symbol_id != input.symbol and reference.declaration_node_index != input.source_specifier) continue;
            if (reference.symbol_id != input.symbol or index != input.declaration_row or reference.declaration_node_index != input.source_specifier or
                reference.scope_id != input.root_scope or !reference.node_index.isNone() or
                !std.meta.eql(reference.flags, ReferenceFlags{ .declare = true })) return error.InvalidSymbol;
            count += 1;
        }
        if (count != 1) return error.ReferenceNotFound;
        // No fallible operation follows this reservation. A failed call leaves
        // all logical editor state, source metadata, and AST untouched.
        try self.symbol_ids.ensureTotalCapacity(self.allocator, @as(usize, output_raw) + 1);
        while (self.symbol_ids.items.len <= output_raw) self.symbol_ids.appendAssumeCapacity(null);
        self.symbol_ids.items[output_raw] = @backingInt(input.symbol);
        self.symbols.items[@backingInt(input.symbol)].kind = .variable_const;
        self.symbols.items[@backingInt(input.symbol)].decl_flags = SymbolKind.variable_const.declFlags();
        self.references.items[input.declaration_row].declaration_node_index = input.output_binding;
    }

    pub fn removeDeclarationAtNode(self: *SemanticEditor, binding: NodeIndex, expected: SymbolId) Error!usize {
        if (!self.validSymbol(expected)) return error.InvalidSymbol;
        if (binding.isNone() or @backingInt(binding) >= self.ast.nodes.items.len or
            self.ast.getNode(binding).tag != .binding_identifier) return error.InvalidNode;
        const raw = @backingInt(binding);
        if (raw >= self.symbol_ids.items.len or self.symbol_ids.items[raw] != @backingInt(expected)) return error.InvalidSymbol;
        // Validate the complete selection before changing the graph.
        var matches: usize = 0;
        for (self.references.items) |reference| {
            if (!reference.flags.declare or reference.declaration_node_index != binding) continue;
            if (reference.symbol_id != expected) return error.InvalidSymbol;
            matches += 1;
        }
        if (matches == 0) return error.ReferenceNotFound;
        if (matches != 1) return error.DuplicateBinding;
        var write: usize = 0;
        var removed: usize = 0;
        for (self.references.items) |reference| {
            if (reference.flags.declare and reference.declaration_node_index == binding) {
                self.removeCounts(reference.symbol_id, reference.flags);
                removed += 1;
                continue;
            }
            self.references.items[write] = reference;
            write += 1;
        }
        self.references.shrinkRetainingCapacity(write);
        self.reference_index.clearRetainingCapacity();
        self.reference_index_built = false;
        // This operation removes only the declaration row. The producer owns
        // detaching its discarded AST binding, and any runtime mapping survives.
        return removed;
    }

    /// Retire a complete unreachable source function while preserving every
    /// SymbolId/ScopeId slot. The AST producer must already have detached the
    /// whole expression/declaration; reachability and ownership are recomputed
    /// here rather than accepted from a caller-provided removed-node bitmap.
    /// All validation/allocation precedes the first edit. Dead scope records
    /// and orphan symbol rows keep their original provenance, never a fake
    /// parent or a replacement scope zero.
    pub fn captureFunctionRetirementSource(self: *const SemanticEditor, known: KnownUnreachableFunction) Error!*const SourceOwnedFunction {
        if (known.owner.isNone() or @backingInt(known.owner) >= self.ast.nodes.items.len or
            known.scope.isNone() or known.scope.toIndex() >= self.scopes.items.len or
            self.scope_owner_map.get(@backingInt(known.owner)) != @backingInt(known.scope)) return error.InvalidScope;
        const node = self.ast.getNode(known.owner);
        if (node.tag != .function_declaration and node.tag != .function_expression and node.tag != .arrow_function_expression) return error.InvalidNode;
        const slot: u32 = if (node.tag == .arrow_function_expression) 0 else ast_mod.FunctionExtra.params;
        if (!self.ast.hasExtra(node.data.extra, slot + 1) or
            self.ast.readExtraNode(node.data.extra, slot) != known.params or
            self.ast.readExtraNode(node.data.extra, slot + 1) != known.body or
            self.scope_owner_map.get(@backingInt(known.body)) != (if (known.body_scope.isNone()) @as(?u32, null) else @backingInt(known.body_scope))) return error.InvalidNode;
        const source = try self.allocator.create(Ast);
        source.* = try self.ast.cloneForTransformer(self.allocator);
        // Snapshot bytes, rather than assuming equality from a borrowed pointer.
        source.source = try self.allocator.dupe(u8, self.ast.source);
        const graph = try self.allocator.create(SemanticEditor);
        graph.* = try SemanticEditor.init(self.allocator, source, self.symbols.items, self.scopes.items, self.scope_maps.items, self.scope_owner_map, self.references.items, self.symbol_ids.items, self.helper_scope_map);
        try graph.importScopeHistory(self.scopeHistoryView());
        try graph.importSourceOwnedRetirements(self.source_owned_retirements);
        graph.node_scope_provenance = try self.node_scope_provenance.clone(self.allocator);
        const plan = try self.allocator.create(SourceOwnedFunction);
        plan.* = .{
            .domain = self.ast,
            .source_backing = self.ast.source,
            .source = source,
            .graph = graph,
            .functions = try self.allocator.dupe(KnownUnreachableFunction, &.{known}),
            .subtree = try @import("../parser/ast_walk.zig").collectReachableNodeIndicesFrom(self.allocator, source, known.owner),
        };
        return plan;
    }

    pub fn captureFunctionRetirementSources(self: *const SemanticEditor, functions: []const KnownUnreachableFunction) Error!*const SourceOwnedFunction {
        if (functions.len == 0) return error.InvalidNode;
        const first = try self.captureFunctionRetirementSource(functions[0]);
        var union_nodes: std.ArrayList(u32) = .empty;
        var membership = try std.DynamicBitSet.initEmpty(self.allocator, self.ast.nodes.items.len);
        for (functions, 0..) |known, index| {
            for (functions[0..index]) |previous| if (previous.owner == known.owner) return error.InvalidNode;
            if (known.owner.isNone() or @backingInt(known.owner) >= self.ast.nodes.items.len or
                known.scope.isNone() or known.scope.toIndex() >= self.scopes.items.len or
                self.scope_owner_map.get(@backingInt(known.owner)) != @backingInt(known.scope)) return error.InvalidScope;
            const node = self.ast.getNode(known.owner);
            if (node.tag != .function_declaration and node.tag != .function_expression and node.tag != .arrow_function_expression) return error.InvalidNode;
            const slot: u32 = if (node.tag == .arrow_function_expression) 0 else ast_mod.FunctionExtra.params;
            if (!self.ast.hasExtra(node.data.extra, slot + 1) or
                self.ast.readExtraNode(node.data.extra, slot) != known.params or self.ast.readExtraNode(node.data.extra, slot + 1) != known.body or
                self.scope_owner_map.get(@backingInt(known.body)) != (if (known.body_scope.isNone()) @as(?u32, null) else @backingInt(known.body_scope))) return error.InvalidNode;
            const nodes = try @import("../parser/ast_walk.zig").collectReachableNodeIndicesFrom(self.allocator, self.ast, known.owner);
            for (nodes) |raw| {
                // Capture may include nested functions. Selection, made from
                // this immutable source after transformation, must be disjoint.
                if (membership.isSet(raw)) continue;
                membership.set(raw);
                try union_nodes.append(self.allocator, raw);
            }
        }
        const plan = try self.allocator.create(SourceOwnedFunction);
        plan.* = first.*;
        plan.functions = try self.allocator.dupe(KnownUnreachableFunction, functions);
        plan.subtree = try union_nodes.toOwnedSlice(self.allocator);
        return plan;
    }

    pub fn retireSelectedSourceOwnedFunctions(self: *SemanticEditor, source: *const SourceOwnedFunction, selected_owners: []const NodeIndex, receipt: @import("function_retirement_receipt.zig").ApplicationReceipt) Error!bool {
        if (selected_owners.len == 0 or source.domain != self.ast or receipt.domain != source.domain) return false;
        var selected: std.ArrayList(KnownUnreachableFunction) = .empty;
        var union_nodes: std.ArrayList(u32) = .empty;
        var membership = try std.DynamicBitSet.initEmpty(self.allocator, source.source.nodes.items.len);
        for (selected_owners) |owner| {
            var found: ?KnownUnreachableFunction = null;
            for (source.functions) |known| if (known.owner == owner) {
                if (found != null) return false;
                found = known;
            };
            const known = found orelse return false;
            const nodes = try @import("../parser/ast_walk.zig").collectReachableNodeIndicesFrom(self.allocator, source.source, known.owner);
            for (nodes) |raw| {
                if (membership.isSet(raw)) return false;
                membership.set(raw);
                try union_nodes.append(self.allocator, raw);
            }
            try selected.append(self.allocator, known);
        }
        var plan = source.*;
        plan.functions = selected.items;
        plan.subtree = union_nodes.items;
        return self.retireSourceOwnedFunction(&plan, receipt);
    }

    /// Consume only after the domain-bound journal has applied references and
    /// owners, and before it retires any generic declaration anchors.
    pub fn retireSourceOwnedFunction(self: *SemanticEditor, plan: *const SourceOwnedFunction, receipt: @import("function_retirement_receipt.zig").ApplicationReceipt) Error!bool {
        if (self.ast != plan.domain or receipt.domain != plan.domain or
            self.ast.source.ptr != plan.source_backing.ptr or self.ast.source.len != plan.source_backing.len or
            !std.mem.eql(u8, self.ast.source, plan.source.source) or
            self.symbols.items.len != plan.graph.symbols.items.len or self.scopes.items.len != plan.graph.scopes.items.len or
            self.scope_maps.items.len != plan.graph.scope_maps.items.len or self.symbol_ids.items.len != self.ast.nodes.items.len) return false;
        const walk = @import("../parser/ast_walk.zig");
        const live_nodes = try walk.collectReachableNodeIndices(self.allocator, self.ast);
        var live = try std.DynamicBitSet.initEmpty(self.allocator, self.ast.nodes.items.len);
        for (live_nodes) |raw| live.set(raw);
        var lineage = try std.DynamicBitSet.initEmpty(self.allocator, self.ast.nodes.items.len);
        for (plan.subtree) |raw| {
            if (raw >= lineage.capacity() or live.isSet(raw)) return false;
            lineage.set(raw);
        }
        const payloads = try self.allocator.dupe(ast_mod.Node, plan.source.nodes.items);
        var copied_references: std.AutoHashMapUnmanaged(u32, Reference) = .empty;
        var copied_owners = try plan.graph.scope_owner_map.clone(self.allocator);
        for (plan.graph.references.items) |row| {
            if (row.flags.declare or row.node_index.isNone()) continue;
            const entry = try copied_references.getOrPut(self.allocator, @backingInt(row.node_index));
            if (entry.found_existing) return false;
            entry.value_ptr.* = row;
        }
        for (receipt.materialized_reads) |materialized| {
            if (materialized.node.isNone()) return false;
            const raw = @backingInt(materialized.node);
            if (raw >= payloads.len or raw >= plan.graph.symbol_ids.items.len or
                !sameRetirementNodePayload(payloads[raw], materialized.before_node) or
                materialized.before_node.tag != .identifier_reference or
                plan.graph.symbol_ids.items[raw] != @as(?u32, materialized.before_symbol_id) or
                @backingInt(materialized.before_reference.symbol_id) != materialized.before_symbol_id or
                materialized.before_reference.node_index != materialized.node or
                !std.meta.eql(materialized.before_reference.flags, @as(ReferenceFlags, .{ .read = true })) or
                !std.meta.eql(copied_references.get(raw), @as(?Reference, materialized.before_reference))) return false;
            switch (materialized.after_node.tag) {
                .numeric_literal, .string_literal, .boolean_literal, .null_literal, .bigint_literal => {},
                else => return false,
            }
            var removal_count: usize = 0;
            for (receipt.reference_changes) |change| {
                if (change.after == null and std.meta.eql(change.before, @as(?Reference, materialized.before_reference))) removal_count += 1;
            }
            if (removal_count != 1) return false;
            payloads[raw] = materialized.after_node;
            _ = copied_references.remove(raw);
        }
        for (receipt.copies) |copy| {
            if (copy.source.isNone() or copy.target.isNone()) return false;
            const from = @backingInt(copy.source);
            const to = @backingInt(copy.target);
            if (from >= lineage.capacity() or to >= lineage.capacity() or from >= payloads.len or to >= payloads.len or
                copy.source_reachable != live.isSet(from) or copy.target_reachable != live.isSet(to)) return false;
            if (!sameRetirementNodePayload(payloads[from], copy.source_node) or !sameRetirementNodePayload(payloads[to], copy.target_node) or
                copied_owners.get(from) != (if (copy.source_owner) |scope| @as(?u32, @backingInt(scope)) else null)) return false;
            var source_reference = copied_references.get(from);
            if (source_reference) |*row| {
                // Empty-arrow scope elision is a separate exact producer. It
                // may already have updated the journal's source row.
                if (copy.source_reference) |actual| {
                    for (receipt.owner_changes) |change| {
                        if (change.effect == .empty_arrow_elide and row.scope_id == change.scope and actual.scope_id != row.scope_id)
                            row.scope_id = change.parent orelse return false;
                    }
                }
            }
            if (!std.meta.eql(source_reference, copy.source_reference)) return false;
            if (source_reference) |row| {
                var next = row;
                if (copied_references.get(to)) |previous| {
                    next.scope_id = previous.scope_id;
                    next.stmt_idx = previous.stmt_idx;
                    next.scope_stmt_idx = previous.scope_stmt_idx;
                }
                next.node_index = copy.target;
                try copied_references.put(self.allocator, to, next);
            } else _ = copied_references.remove(to);
            if (copy.source_owner) |scope| {
                if (copied_owners.get(to)) |previous| if (previous != @backingInt(scope)) return false;
                try copied_owners.put(self.allocator, to, @backingInt(scope));
            } else _ = copied_owners.remove(to);
            payloads[to] = copy.source_node;
            // Keep original source membership even after an overwrite. This
            // intentionally rejects ambiguous reuse instead of repairing it.
            if (lineage.isSet(from)) lineage.set(to);
        }
        for (receipt.copies) |copy| {
            const raw = @backingInt(copy.target);
            if (!sameRetirementNodePayload(payloads[raw], self.ast.getNode(copy.target))) return false;
        }
        // The receipt cannot authorize an arbitrary new SID, access mode, or
        // lexical use scope merely because its after row matches the editor.
        const root = self.ast.transformed_root orelse @as(NodeIndex, @fromBackingInt(@as(u32, @intCast(self.ast.nodes.items.len - 1))));
        const positions = @import("statement_coordinates.zig").collect(self.allocator, self.ast, root) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return false,
        };
        for (self.references.items) |row| {
            if (row.flags.declare) continue;
            if (row.node_index.isNone()) return false;
            const raw = @backingInt(row.node_index);
            var original = copied_references.get(raw) orelse return false;
            for (receipt.owner_changes) |change| {
                if (change.effect == .empty_arrow_elide and original.scope_id == change.scope) original.scope_id = change.parent orelse return false;
            }
            if (row.symbol_id != original.symbol_id or row.scope_id != original.scope_id or !std.meta.eql(row.flags, original.flags) or
                raw >= positions.len or positions[raw] == null or row.stmt_idx != positions[raw].?.stmt_idx or row.scope_stmt_idx != positions[raw].?.scope_stmt_idx) return false;
        }
        for (live_nodes) |raw| if (lineage.isSet(raw)) return false;
        // Replay actual row deltas into scratch storage, not into the editor.
        var expected = try SemanticEditor.init(self.allocator, self.ast, plan.graph.symbols.items, plan.graph.scopes.items, plan.graph.scope_maps.items, plan.graph.scope_owner_map, plan.graph.references.items, plan.graph.symbol_ids.items, plan.graph.helper_scope_map);
        try expected.importScopeHistory(plan.graph.scopeHistoryView());
        try expected.importSourceOwnedRetirements(plan.graph.source_owned_retirements);
        expected.node_scope_provenance = try plan.graph.node_scope_provenance.clone(self.allocator);
        try expected.symbol_ids.resize(self.allocator, self.symbol_ids.items.len);
        @memset(expected.symbol_ids.items[plan.graph.symbol_ids.items.len..], null);
        for (receipt.reference_changes) |change| {
            if (change.before == null and change.after == null) return false;
            if (change.before) |before| {
                if (before.flags.declare) return false;
                var found: ?usize = null;
                for (expected.references.items, 0..) |row, i| if (std.meta.eql(row, before)) {
                    if (found != null) return false;
                    found = i;
                };
                _ = expected.references.orderedRemove(found orelse return false);
                expected.removeCounts(before.symbol_id, before.flags);
                if (before.node_index.isNone() or @backingInt(before.node_index) >= expected.symbol_ids.items.len or
                    expected.symbol_ids.items[@backingInt(before.node_index)] != @as(?u32, @backingInt(before.symbol_id))) return false;
                expected.symbol_ids.items[@backingInt(before.node_index)] = null;
            }
            if (change.after) |after| {
                if (after.flags.declare or after.node_index.isNone() or
                    @backingInt(after.node_index) >= self.symbol_ids.items.len or
                    @backingInt(after.symbol_id) >= self.symbols.items.len or
                    self.symbol_ids.items[@backingInt(after.node_index)] != @as(?u32, @backingInt(after.symbol_id))) return false;
                // A copied live read from the retired source must have a
                // recorded copy lineage, never merely the same spelling/SID.
                for (plan.graph.references.items) |original| {
                    if (!original.node_index.isNone() and @backingInt(original.node_index) < lineage.capacity() and
                        lineage.isSet(@backingInt(original.node_index)) and original.symbol_id == after.symbol_id and
                        (change.before == null or change.before.?.node_index != after.node_index)) return false;
                }
                try expected.references.append(self.allocator, after);
                expected.addCounts(after.symbol_id, after.flags);
                const previous = expected.symbol_ids.items[@backingInt(after.node_index)];
                if (previous != null and previous != @as(?u32, @backingInt(after.symbol_id))) return false;
                expected.symbol_ids.items[@backingInt(after.node_index)] = @backingInt(after.symbol_id);
            }
        }
        if (expected.references.items.len != self.references.items.len) return false;
        for (expected.references.items) |row| {
            var count: usize = 0;
            for (self.references.items) |actual| if (std.meta.eql(row, actual)) {
                count += 1;
            };
            if (count != 1) return false;
        }
        for (expected.symbols.items, self.symbols.items) |before, actual| if (!std.meta.eql(before, actual)) return false;
        if (!std.mem.eql(?u32, expected.symbol_ids.items, self.symbol_ids.items)) return false;
        for (receipt.owner_changes) |change| {
            if (change.source_owner.isNone() or change.scope.isNone() or change.scope.toIndex() >= expected.scopes.items.len or
                expected.scope_owner_map.get(@backingInt(change.source_owner)) != @backingInt(change.scope)) return false;
            // A source closure already consumed by an owner-elision producer
            // is a different operation, not a second whole-function retire.
            if (@backingInt(change.source_owner) >= lineage.capacity() or lineage.isSet(@backingInt(change.source_owner))) return false;
            switch (change.effect) {
                .move => {
                    const target = change.target_owner orelse return false;
                    if (target.isNone() or @backingInt(target) >= lineage.capacity() or lineage.isSet(@backingInt(target))) return false;
                    if (expected.scope_owner_map.get(@backingInt(target))) |other| if (other != @backingInt(change.scope)) return false;
                    try expected.scope_owner_map.put(self.allocator, @backingInt(target), @backingInt(change.scope));
                },
                .empty_arrow_elide => {
                    const parent = change.parent orelse return false;
                    if (change.target_owner != null or parent.isNone() or parent.toIndex() >= expected.scopes.items.len or
                        expected.scopes.items[change.scope.toIndex()].parent != parent or
                        expected.scopes.items[change.scope.toIndex()].symbol_count != 0 or
                        expected.scope_maps.items[change.scope.toIndex()].count() != 0) return false;
                    for (expected.scopes.items) |*scope| if (scope.parent == change.scope) {
                        scope.parent = parent;
                    };
                },
            }
            _ = expected.scope_owner_map.remove(@backingInt(change.source_owner));
        }
        if (expected.scope_owner_map.count() != self.scope_owner_map.count()) return false;
        var owners = expected.scope_owner_map.iterator();
        while (owners.next()) |entry| if (self.scope_owner_map.get(entry.key_ptr.*) != entry.value_ptr.*) return false;
        for (expected.scopes.items, self.scopes.items) |before, actual| if (!std.meta.eql(before, actual)) return false;
        for (expected.scope_maps.items, self.scope_maps.items) |before, actual| {
            if (before.count() != actual.count()) return false;
            var entries = before.iterator();
            while (entries.next()) |entry| if (actual.get(entry.key_ptr.*) != entry.value_ptr.*) return false;
        }
        if (expected.helper_scope_map.count() != self.helper_scope_map.count()) return false;
        var helpers = expected.helper_scope_map.iterator();
        while (helpers.next()) |entry| if (self.helper_scope_map.get(entry.key_ptr.*) != entry.value_ptr.*) return false;
        for (receipt.provenance_changes) |change| {
            if (!std.meta.eql(expected.node_scope_provenance.get(change.node), change.before)) return false;
            if (change.after) |after| try expected.node_scope_provenance.put(self.allocator, change.node, after) else _ = expected.node_scope_provenance.remove(change.node);
        }
        if (expected.node_scope_provenance.count() != self.node_scope_provenance.count()) return false;
        var provenance = expected.node_scope_provenance.iterator();
        while (provenance.next()) |entry| if (!std.meta.eql(self.node_scope_provenance.get(entry.key_ptr.*), @as(?@import("node_scope_provenance.zig").Entry, entry.value_ptr.*))) return false;
        // Prepare the whole batch in a separate editor. Even a later closure
        // rejecting or running out of memory leaves the caller untouched.
        var candidate = try SemanticEditor.init(self.allocator, self.ast, self.symbols.items, self.scopes.items, self.scope_maps.items, self.scope_owner_map, self.references.items, self.symbol_ids.items, self.helper_scope_map);
        try candidate.importScopeHistory(self.scopeHistoryView());
        try candidate.importSourceOwnedRetirements(self.source_owned_retirements);
        candidate.node_scope_provenance = try self.node_scope_provenance.clone(self.allocator);
        candidate.scope_reparented = self.scope_reparented;
        for (plan.functions) |known| {
            const subtree = try walk.collectReachableNodeIndicesFrom(self.allocator, plan.source, known.owner);
            if (!try candidate.retireFunctionSourceClosure(known, plan.source, subtree, &live)) return false;
        }
        self.* = candidate;
        return true;
    }

    pub fn retireUnreachableFunctionSubtree(self: *SemanticEditor, known: KnownUnreachableFunction) Error!bool {
        const walk = @import("../parser/ast_walk.zig");
        if (known.owner.isNone() or @backingInt(known.owner) >= self.ast.nodes.items.len) return false;
        const live_nodes = try walk.collectReachableNodeIndices(self.allocator, self.ast);
        defer self.allocator.free(live_nodes);
        var live = try std.DynamicBitSet.initEmpty(self.allocator, self.ast.nodes.items.len);
        defer live.deinit();
        for (live_nodes) |raw| live.set(raw);
        if (live.isSet(@backingInt(known.owner))) return false;
        const subtree = try walk.collectReachableNodeIndicesFrom(self.allocator, self.ast, known.owner);
        defer self.allocator.free(subtree);
        return self.retireFunctionSourceClosure(known, self.ast, subtree, &live);
    }

    fn retireFunctionSourceClosure(self: *SemanticEditor, known: KnownUnreachableFunction, source_ast: *const Ast, subtree: []const u32, live: *const std.DynamicBitSet) Error!bool {
        const owner = known.owner;
        if (self.scopes.items.len != self.scope_maps.items.len) return false;
        if (owner.isNone() or @backingInt(owner) >= source_ast.nodes.items.len) return false;
        const node = source_ast.getNode(owner);
        if (node.tag != .function_expression and node.tag != .function_declaration and node.tag != .arrow_function_expression) return false;
        const parameter_slot: u32 = if (node.tag == .arrow_function_expression) 0 else ast_mod.FunctionExtra.params;
        if (!source_ast.hasExtra(node.data.extra, parameter_slot + 1)) return false;
        const params = source_ast.readExtraNode(node.data.extra, parameter_slot);
        const body = source_ast.readExtraNode(node.data.extra, parameter_slot + 1);
        if (params != known.params or body != known.body) return false;
        if (params.isNone() or body.isNone() or @backingInt(params) >= source_ast.nodes.items.len or @backingInt(body) >= source_ast.nodes.items.len or
            source_ast.getNode(params).tag != .formal_parameters) return false;
        const function_scope = self.scope_owner_map.get(@backingInt(owner)) orelse return false;
        if (function_scope != @backingInt(known.scope)) return false;
        if (function_scope >= self.scopes.items.len or self.scopes.items[function_scope].kind != .function or
            self.scopes.items[function_scope].parent.isNone()) return false;
        const actual_body_scope = self.scope_owner_map.get(@backingInt(body));
        if (known.body_scope.isNone()) {
            // Ordinary parser functions can visit their body directly in the
            // known function scope without a second scope-owner map entry.
            if (actual_body_scope != null) return false;
        } else {
            const raw = known.body_scope.toIndex();
            if (actual_body_scope != raw or raw >= self.scopes.items.len) return false;
            if (raw != function_scope and
                ((self.scopes.items[raw].kind != .block and self.scopes.items[raw].kind != .function) or
                    self.scopes.items[raw].parent != known.scope)) return false;
        }
        var removed = try std.DynamicBitSet.initEmpty(self.allocator, self.ast.nodes.items.len);
        defer removed.deinit();
        for (subtree) |raw| {
            if (raw >= removed.capacity() or live.isSet(raw)) return false;
            removed.set(raw);
        }
        // A named function expression owns a distinct self-name block frame
        // outside its parameter/function frame. Select it only through the
        // actual source name binding and known G.parent relation.
        var source_name: NodeIndex = .none;
        var source_name_symbol: SymbolId = .none;
        if (node.tag != .arrow_function_expression and source_ast.hasExtra(node.data.extra, ast_mod.FunctionExtra.name)) {
            source_name = source_ast.readExtraNode(node.data.extra, ast_mod.FunctionExtra.name);
            if (!source_name.isNone()) {
                const raw = @backingInt(source_name);
                if (raw >= self.symbol_ids.items.len) return false;
                source_name_symbol = @fromBackingInt(self.symbol_ids.items[raw] orelse return false);
            }
        }
        var closure_scope = function_scope;
        if (node.tag == .function_expression and source_ast.hasExtra(node.data.extra, ast_mod.FunctionExtra.name)) {
            const name = source_ast.readExtraNode(node.data.extra, ast_mod.FunctionExtra.name);
            if (!name.isNone()) {
                const raw = @backingInt(name);
                if (raw >= self.symbol_ids.items.len or raw >= source_ast.nodes.items.len or source_ast.nodes.items[raw].tag != .binding_identifier) return false;
                const sid = self.symbol_ids.items[raw] orelse return false;
                if (sid >= self.symbols.items.len) return false;
                const symbol = self.symbols.items[sid];
                const frame = self.scopes.items[function_scope].parent;
                if (!self.validScope(frame) or frame.toIndex() == function_scope or symbol.scope_id != frame or symbol.origin_scope != frame or
                    self.scopes.items[frame.toIndex()].kind != .block or self.scopes.items[frame.toIndex()].parent.isNone() or
                    !self.validScope(self.scopes.items[frame.toIndex()].parent) or self.scopes.items[frame.toIndex()].symbol_count != 1 or
                    self.scope_maps.items[frame.toIndex()].count() != 1 or !std.meta.eql(symbol.name, source_ast.nodes.items[raw].span) or
                    !std.meta.eql(symbol.declaration_span, source_ast.nodes.items[raw].span)) return false;
                switch (symbol.kind) {
                    .function_decl, .generator_decl, .async_function_decl, .async_generator_decl => {},
                    else => return false,
                }
                var entries = self.scope_maps.items[frame.toIndex()].valueIterator();
                if (entries.next().?.* != sid) return false;
                var frame_owners = self.scope_owner_map.valueIterator();
                while (frame_owners.next()) |actual| if (actual.* == frame.toIndex()) return false;
                closure_scope = frame.toIndex();
            }
        }
        var scopes = try std.DynamicBitSet.initEmpty(self.allocator, self.scopes.items.len);
        defer scopes.deinit();
        for (self.scopes.items, 0..) |_, raw| {
            var cursor: ScopeId = @fromBackingInt(@intCast(raw));
            var fuel = self.scopes.items.len + 1;
            while (!cursor.isNone() and fuel > 0) : (fuel -= 1) {
                if (!self.validScope(cursor)) return false;
                if (cursor.toIndex() == closure_scope) scopes.set(raw);
                cursor = self.scopes.items[cursor.toIndex()].parent;
            }
            if (!cursor.isNone()) return false;
            if (scopes.isSet(raw) and self.scopes.items[raw].blocksMangling()) return false;
        }
        var owners = self.scope_owner_map.iterator();
        while (owners.next()) |entry| {
            if (entry.value_ptr.* >= scopes.capacity() or entry.key_ptr.* >= removed.capacity()) return false;
            if (scopes.isSet(entry.value_ptr.*) != removed.isSet(entry.key_ptr.*)) return false;
        }
        var retired = try std.DynamicBitSet.initEmpty(self.allocator, self.symbols.items.len);
        defer retired.deinit();
        for (self.symbols.items, 0..) |symbol, id| {
            // Graph-owned output-only slots elsewhere in the module may be
            // detached. They are not part of this lexical retirement.
            if (self.validScope(symbol.scope_id) and scopes.isSet(symbol.scope_id.toIndex())) retired.set(id);
        }
        for (subtree) |raw| {
            if (raw >= self.symbol_ids.items.len) return false;
            if (self.symbol_ids.items[raw]) |id| {
                if (id >= self.symbols.items.len or !self.validScope(self.symbols.items[id].scope_id) or
                    !self.validScope(self.symbols.items[id].origin_scope)) return false;
            }
            if (source_ast.nodes.items[raw].tag == .binding_identifier) {
                const id = self.symbol_ids.items[raw] orelse return false;
                if (id >= retired.capacity()) return false;
                retired.set(id);
            }
        }
        const Alias = struct { scope: usize, key: []const u8 };
        var aliases: std.ArrayListUnmanaged(Alias) = .empty;
        defer aliases.deinit(self.allocator);
        const retired_per_scope = try self.allocator.alloc(usize, self.scopes.items.len);
        defer self.allocator.free(retired_per_scope);
        @memset(retired_per_scope, 0);
        var next_retirements = try self.source_owned_retirements.clone(self.allocator);
        var retirement_published = false;
        defer if (!retirement_published) next_retirements.deinit(self.allocator);
        for (self.symbols.items, 0..) |symbol, id| {
            if (!retired.isSet(id)) continue;
            if (next_retirements.contains(@intCast(id))) return false;
            if (!self.validScope(symbol.scope_id) or !self.validScope(symbol.origin_scope)) return false;
            if (self.scopes.items[symbol.scope_id.toIndex()].blocksMangling() or
                self.scopes.items[symbol.origin_scope.toIndex()].blocksMangling()) return false;
            if (symbol.synthetic_name.len == 0 and (symbol.name.start > symbol.name.end or symbol.name.end > source_ast.source.len)) return false;
            if (!std.meta.eql(symbol.decl_flags, symbol.kind.declFlags()) or symbol.isExported() or symbol.synthetic_owner_id != null or symbol.output_name_hint.len != 0 or
                !symbol.annex_b_alias.variable.isNone() or symbol.annex_b_alias.state != .native or symbol.decl_flags.is_annex_b_function) return false;
            // The analyzer's intrinsic arguments slot has no AST binding. Its
            // exact function owner/span and unique pure declaration are the
            // authority; arbitrary generated/runtime symbols remain rejected.
            const intrinsic_arguments = symbol.synthetic_kind == .implicit_arguments and symbol.kind == .parameter and
                std.mem.eql(u8, symbol.synthetic_name, "arguments") and symbol.scope_id == symbol.origin_scope;
            if ((symbol.isSynthetic() or symbol.synthetic_name.len != 0) and !intrinsic_arguments) return false;
            var declaration_witness: ?Reference = null;
            var declarations: usize = 0;
            var reads: u32 = 0;
            var writes: u32 = 0;
            for (self.references.items) |reference| {
                if (@backingInt(reference.symbol_id) != id) continue;
                if (reference.flags.declare) {
                    if (!std.meta.eql(reference.flags, @as(ReferenceFlags, .{ .declare = true })) or !reference.node_index.isNone() or reference.scope_id != symbol.scope_id) return false;
                    if (reference.declaration_node_index.isNone()) {
                        if (!intrinsic_arguments) return false;
                        var found_owner = false;
                        var known_owners = self.scope_owner_map.iterator();
                        while (known_owners.next()) |entry| {
                            if (entry.value_ptr.* != symbol.scope_id.toIndex() or !removed.isSet(entry.key_ptr.*)) continue;
                            const actual = source_ast.nodes.items[entry.key_ptr.*];
                            if ((actual.tag == .function_expression or actual.tag == .function_declaration) and
                                actual.span.start == symbol.declaration_span.start and actual.span.end == symbol.declaration_span.end) found_owner = true;
                        }
                        if (!found_owner) return false;
                    } else {
                        const raw = @backingInt(reference.declaration_node_index);
                        if (raw >= removed.capacity() or !removed.isSet(raw) or source_ast.nodes.items[raw].tag != .binding_identifier or
                            self.symbol_ids.items[raw] != @as(?u32, @intCast(id))) return false;
                    }
                    declarations += 1;
                    declaration_witness = reference;
                } else {
                    if (reference.node_index.isNone() or @backingInt(reference.node_index) >= removed.capacity() or
                        !removed.isSet(@backingInt(reference.node_index))) return false;
                    if (!reference.flags.type_context and !reference.flags.value_as_type) {
                        if (reference.flags.read or reference.flags.write) reads = std.math.add(u32, reads, 1) catch return false;
                        if (reference.flags.write) writes = std.math.add(u32, writes, 1) catch return false;
                    }
                }
            }
            if (declarations != 1 or reads != symbol.reference_count or writes != symbol.write_count) return false;
            if (!scopes.isSet(symbol.scope_id.toIndex())) {
                if (node.tag != .function_declaration or !source_ast.hasExtra(node.data.extra, ast_mod.FunctionExtra.name)) return false;
                const binding = source_ast.readExtraNode(node.data.extra, ast_mod.FunctionExtra.name);
                if (binding.isNone() or self.symbol_ids.items[@backingInt(binding)] != @as(?u32, @intCast(id)) or symbol.scope_id != self.scopes.items[function_scope].parent) return false;
            } else if (!scopes.isSet(symbol.origin_scope.toIndex())) return false;
            const declaration = declaration_witness orelse return false;
            try next_retirements.put(self.allocator, @intCast(id), .{
                .symbol_id = @fromBackingInt(@as(u32, @intCast(id))),
                .before = symbol,
                .declaration = declaration,
                .declaration_node = if (declaration.declaration_node_index.isNone()) null else source_ast.getNode(declaration.declaration_node_index),
                .source_owner = owner,
                .source_owner_node = node,
                .source_scope = known.scope,
                .source_parent = self.scopes.items[function_scope].parent,
                .source_name = source_name,
                .source_name_symbol = source_name_symbol,
                .closure_scope = @fromBackingInt(closure_scope),
                .closure_parent = self.scopes.items[closure_scope].parent,
                .reason = .source_function_closure,
            });
            retired_per_scope[symbol.scope_id.toIndex()] += 1;
        }
        for (self.symbol_ids.items, 0..) |id, raw| {
            if (id) |actual| {
                if (actual >= retired.capacity()) return false;
                if (retired.isSet(actual) and (raw >= removed.capacity() or !removed.isSet(raw))) return false;
            }
        }
        for (self.scope_maps.items, 0..) |map, raw| {
            var entries = map.iterator();
            while (entries.next()) |entry| {
                const id = entry.value_ptr.*;
                if (id >= retired.capacity()) return false;
                if (retired.isSet(id)) {
                    const symbol = self.symbols.items[id];
                    if (symbol.scope_id.toIndex() != raw) return false;
                    const name = symbol.nameText(source_ast.source);
                    if (!std.mem.eql(u8, name, entry.key_ptr.*) and !Scanner.identifierValueEquals(name, entry.key_ptr.*)) return false;
                    try aliases.append(self.allocator, .{ .scope = raw, .key = entry.key_ptr.* });
                } else if (scopes.isSet(raw)) return false;
            }
            if (retired_per_scope[raw] > self.scopes.items[raw].symbol_count) return false;
        }
        var helper_names = self.helper_scope_map.valueIterator();
        while (helper_names.next()) |id| if (id.* >= retired.capacity() or retired.isSet(id.*)) return false;
        for (self.references.items) |reference| {
            const id = @backingInt(reference.symbol_id);
            if (id >= retired.capacity() or !self.validScope(reference.scope_id)) return false;
            if (reference.node_index.isNone()) {
                if (!reference.flags.declare) return false;
            } else {
                const raw = @backingInt(reference.node_index);
                if (raw >= removed.capacity()) return false;
                if (scopes.isSet(reference.scope_id.toIndex()) and !removed.isSet(raw)) return false;
                if (removed.isSet(raw) and (raw >= self.symbol_ids.items.len or self.symbol_ids.items[raw] != @as(?u32, @intCast(id)) or reference.flags.declare)) return false;
            }
        }
        var uses = self.node_scope_provenance.iterator();
        while (uses.next()) |entry| {
            const raw = @backingInt(entry.key_ptr.*);
            if (raw >= removed.capacity() or !self.validScope(entry.value_ptr.scope)) return false;
            if (scopes.isSet(entry.value_ptr.scope.toIndex()) and !removed.isSet(raw)) return false;
        }
        if (self.scope_history.enabled) {
            for (subtree) |raw| if (self.scope_owner_map.get(raw)) |scope_id| {
                self.scope_history.recordOwner(self.allocator, self.ast, @fromBackingInt(scope_id), self.scopes.items[scope_id], @fromBackingInt(raw), .none, .{}) catch |err| return historyError(err);
            };
        }
        // No fallible work follows. Stable array slots and source provenance
        // survive; only dead lexical edges/maps/counts/owner mappings retire.
        var write: usize = 0;
        for (self.references.items) |reference| {
            if (retired.isSet(@backingInt(reference.symbol_id)) or
                (!reference.node_index.isNone() and removed.isSet(@backingInt(reference.node_index))))
            {
                self.removeCounts(reference.symbol_id, reference.flags);
                continue;
            }
            self.references.items[write] = reference;
            write += 1;
        }
        self.references.shrinkRetainingCapacity(write);
        self.reference_index.clearRetainingCapacity();
        self.reference_index_built = false;
        for (aliases.items) |alias| _ = self.scope_maps.items[alias.scope].remove(alias.key);
        for (retired_per_scope, 0..) |count, raw| self.scopes.items[raw].symbol_count -= @intCast(count);
        for (subtree) |raw| {
            self.symbol_ids.items[raw] = null;
            _ = self.scope_owner_map.remove(raw);
            _ = self.node_scope_provenance.remove(@fromBackingInt(raw));
        }
        self.source_owned_retirements.deinit(self.allocator);
        self.source_owned_retirements = next_retirements;
        retirement_published = true;
        return true;
    }

    pub fn captureFunctionNameEnvironments(self: *SemanticEditor, root: NodeIndex, native_engines: *const std.AutoHashMapUnmanaged(u32, ScopeId)) Error![]const @import("function_name_retirement.zig").Source {
        return @import("function_name_retirement.zig").captureAll(self.allocator, self, root, native_engines);
    }

    /// Prepare the complete graph privately, including reparent History. No
    /// original row/map/history mutation occurs on rejection or allocation fail.
    /// Consume only the declaration selected by the minifier's actual inline
    /// event. The candidate owns all graph edits; the AST is read-only here.
    /// Replay only the producer's ordered identity edits. A copied read keeps
    /// its original reference authority even when its physical node and scope
    /// have changed before the declaration is selected for inlining.
    const InlineReadAnchor = struct { node: NodeIndex, before_node: ast_mod.Node };

    fn validateInlineReadLineage(self: *const SemanticEditor, event: @import("inlined_binding_retirement.zig").Event, receipt: @import("function_retirement_receipt.zig").ApplicationReceipt) Error![]InlineReadAnchor {
        if (event.read_step_count > receipt.reference_steps.len or event.read_origin.symbol_id != event.symbol_id) return error.InvalidSymbol;
        const State = struct { current: Reference, origin: Reference, payload: ?ast_mod.Node = null };
        var state: std.AutoHashMapUnmanaged(u32, State) = .empty;
        defer state.deinit(self.allocator);
        for (receipt.identity_baseline) |row| {
            if (row.node_index.isNone() or row.flags.declare or !self.validSymbol(row.symbol_id) or !self.validScope(row.scope_id)) return error.InvalidNode;
            const raw = @backingInt(row.node_index);
            if (raw >= self.ast.nodes.items.len or state.contains(raw)) return error.InvalidNode;
            try state.put(self.allocator, raw, .{ .current = row, .origin = row });
        }
        const original = state.get(@backingInt(event.read_origin.node_index)) orelse return error.ReferenceNotFound;
        if (!std.meta.eql(original.current, event.read_origin)) return error.InvalidSymbol;
        var copy_index: usize = 0;
        for (receipt.reference_steps[0..event.read_step_count]) |step| {
            if (step.source.isNone() or step.target.isNone() or @backingInt(step.source) >= self.ast.nodes.items.len or @backingInt(step.target) >= self.ast.nodes.items.len) return error.InvalidNode;
            const source = state.get(@backingInt(step.source));
            const target = state.get(@backingInt(step.target));
            const source_row = if (source) |item| @as(?Reference, item.current) else null;
            const target_row = if (target) |item| @as(?Reference, item.current) else null;
            if (!std.meta.eql(source_row, step.source_reference) or !std.meta.eql(target_row, step.target_reference)) return error.InvalidSymbol;
            const origin = if (source) |item| @as(?Reference, item.origin) else null;
            if (!std.meta.eql(origin, step.read_origin)) return error.InvalidSymbol;
            switch (step.kind) {
                .copy => {
                    if (step.scope != null or step.parent != null or step.source == step.target or copy_index >= receipt.copies.len) return error.InvalidNode;
                    const copy = receipt.copies[copy_index];
                    copy_index += 1;
                    if (copy.source != step.source or copy.target != step.target or !std.meta.eql(copy.source_reference, step.source_reference)) return error.InvalidNode;
                    if (source) |item| if (item.payload) |payload| if (!sameRetirementNodePayload(payload, copy.source_node)) return error.InvalidNode;
                    if (target) |item| if (item.payload) |payload| if (!sameRetirementNodePayload(payload, copy.target_node)) return error.InvalidNode;
                    const reference_payload = copy.source_node.tag == .identifier_reference or copy.source_node.tag == .assignment_target_identifier or copy.source_node.tag == .jsx_identifier;
                    if (step.source_reference != null and !reference_payload) return error.InvalidNode;
                    var expected: ?Reference = null;
                    if (step.source_reference) |row| {
                        var after = row;
                        after.node_index = step.target;
                        if (step.target_reference) |previous| {
                            after.scope_id = previous.scope_id;
                            after.stmt_idx = previous.stmt_idx;
                            after.scope_stmt_idx = previous.scope_stmt_idx;
                        }
                        expected = after;
                    }
                    if (!std.meta.eql(expected, step.result_reference)) return error.InvalidSymbol;
                    if (expected) |after| {
                        try state.put(self.allocator, @backingInt(step.target), .{ .current = after, .origin = origin orelse return error.InvalidSymbol, .payload = copy.source_node });
                    } else _ = state.remove(@backingInt(step.target));
                },
                .empty_arrow_elide => {
                    const from = step.scope orelse return error.InvalidScope;
                    const parent = step.parent orelse return error.InvalidScope;
                    if (step.source != step.target or source == null or !self.validScope(from) or !self.validScope(parent) or source.?.current.scope_id != from) return error.InvalidScope;
                    var owner_matches: usize = 0;
                    for (receipt.owner_changes) |owner| if (owner.effect == .empty_arrow_elide and owner.scope == from and owner.parent == parent) {
                        owner_matches += 1;
                    };
                    if (owner_matches != 1) return error.InvalidScope;
                    var after = source.?.current;
                    after.scope_id = parent;
                    if (!std.meta.eql(@as(?Reference, after), step.result_reference)) return error.InvalidSymbol;
                    state.getPtr(@backingInt(step.source)).?.current = after;
                },
                .consume => {
                    if (step.scope != null or step.parent != null or step.source != step.target or source == null or step.result_reference != null) return error.InvalidNode;
                    _ = state.remove(@backingInt(step.source));
                },
            }
        }
        const selected = state.get(@backingInt(event.witness.read)) orelse return error.ReferenceNotFound;
        if (!std.meta.eql(selected.current, event.witness.read_reference) or !std.meta.eql(selected.origin, event.read_origin)) return error.InvalidSymbol;
        if (event.wrapped_initializer) {
            if (event.read_step_count >= receipt.reference_steps.len) return error.InvalidNode;
            const consumed = receipt.reference_steps[event.read_step_count];
            if (consumed.kind != .consume or consumed.source != event.witness.read or consumed.target != event.witness.read or
                !std.meta.eql(consumed.source_reference, @as(?Reference, event.witness.read_reference)) or
                !std.meta.eql(consumed.target_reference, @as(?Reference, event.witness.read_reference)) or
                !std.meta.eql(consumed.read_origin, @as(?Reference, event.read_origin)) or consumed.result_reference != null) return error.InvalidNode;
        }
        var anchors: std.ArrayList(InlineReadAnchor) = .empty;
        errdefer anchors.deinit(self.allocator);
        var values = state.iterator();
        while (values.next()) |entry| {
            const item = entry.value_ptr.*;
            if (item.current.symbol_id != event.symbol_id or !std.meta.eql(item.origin, event.read_origin)) continue;
            if (item.payload) |payload| try anchors.append(self.allocator, .{ .node = @fromBackingInt(entry.key_ptr.*), .before_node = payload });
        }
        return anchors.toOwnedSlice(self.allocator);
    }

    pub fn retireInlinedLocalBindings(self: *SemanticEditor, events: []const @import("inlined_binding_retirement.zig").Event, root: NodeIndex, receipt: @import("function_retirement_receipt.zig").ApplicationReceipt) Error!usize {
        if (events.len == 0) return 0;
        const Retirement = @import("source_owned_retirement.zig");
        if (receipt.domain != self.ast or root.isNone() or @backingInt(root) >= self.ast.nodes.items.len) return error.InvalidNode;
        const nodes = try @import("../parser/ast_walk.zig").collectReachableNodeIndicesFrom(self.allocator, self.ast, root);
        defer self.allocator.free(nodes);
        var live = try std.DynamicBitSet.initEmpty(self.allocator, self.ast.nodes.items.len);
        defer live.deinit();
        for (nodes) |raw| live.set(raw);
        var candidate = try SemanticEditor.init(self.allocator, self.ast, self.symbols.items, self.scopes.items, self.scope_maps.items, self.scope_owner_map, self.references.items, self.symbol_ids.items, self.helper_scope_map);
        defer candidate.deinit();
        try candidate.importScopeHistory(self.scopeHistoryView());
        try candidate.importNodeScopeProvenance(self.node_scope_provenance);
        try candidate.importSourceOwnedRetirements(self.source_owned_retirements);
        var count: usize = 0;
        for (events, 0..) |event, event_index| {
            const payload = event.witness;
            const sid = @backingInt(event.symbol_id);
            if (event.domain != self.ast or !candidate.validSymbol(event.symbol_id) or !candidate.validScope(event.before.scope_id)) return error.InvalidSymbol;
            for (events[0..event_index]) |previous| if (previous.symbol_id == event.symbol_id or previous.binding == event.binding) return error.DuplicateBinding;
            // The existing whole-function proof remains authoritative when the
            // containing closure was removed before local inline consumption.
            if (candidate.source_owned_retirements.get(sid)) |known| {
                if (known.reason == .source_function_closure) continue;
                return error.DuplicateBinding;
            }
            var attestations: usize = 0;
            for (receipt.inlined_bindings) |known| if (known.symbol_id == event.symbol_id) {
                if (!sameInlineBindingEvent(known, event)) return error.InvalidNode;
                attestations += 1;
            };
            if (attestations != 1) return error.InvalidNode;
            const read_anchors = try candidate.validateInlineReadLineage(event, receipt);
            defer candidate.allocator.free(read_anchors);
            inline for (.{ event.statement, event.binding, payload.declarator, payload.initializer, payload.read }) |node| {
                if (node.isNone() or @backingInt(node) >= candidate.ast.nodes.items.len) return error.InvalidNode;
            }
            if (event.statement_node.tag != .variable_declaration or candidate.ast.getNode(event.statement).tag != .empty_statement or
                !std.meta.eql(candidate.ast.getNode(event.statement).span, event.statement_node.span) or live.isSet(@backingInt(event.binding)) or live.isSet(@backingInt(payload.declarator)) or
                !sameRetirementNodePayload(candidate.ast.getNode(event.binding), event.binding_node)) return error.InvalidNode;
            var removals: usize = 0;
            for (receipt.reference_changes) |change| {
                const before = change.before orelse continue;
                if (!std.meta.eql(before, event.read_origin)) continue;
                if (change.after) |after| if (after.symbol_id == event.symbol_id) return error.InvalidSymbol;
                removals += 1;
            }
            if (removals != 1) return error.ReferenceNotFound;
            var copies: usize = 0;
            for (receipt.copies) |copy| if (copy.source == payload.initializer and copy.target == payload.read and
                sameRetirementNodePayload(copy.source_node, event.initializer_node) and sameRetirementNodePayload(copy.target_node, payload.read_node))
            {
                copies += 1;
            };
            if (copies != @as(usize, if (event.wrapped_initializer) 0 else 1)) return error.InvalidNode;
            var expected = event.before;
            expected.reference_count = 0;
            expected.write_count = 0;
            if (!Retirement.equalSymbol(expected, candidate.symbols.items[sid])) return error.InvalidSymbol;
            var declarations: usize = 0;
            for (candidate.references.items) |row| if (row.symbol_id == event.symbol_id) {
                if (!std.meta.eql(row, event.declaration)) return error.InvalidSymbol;
                declarations += 1;
            };
            if (declarations != 1 or event.binding != event.declaration.declaration_node_index) return error.ReferenceNotFound;
            var protected = candidate.helper_scope_map.valueIterator();
            while (protected.next()) |id| if (id.* == sid) return error.InvalidSymbol;
            if (candidate.scope_owner_map.contains(@backingInt(event.binding))) return error.InvalidScope;
            var aliases: std.ArrayList(struct { scope: usize, key: []const u8 }) = .empty;
            defer aliases.deinit(candidate.allocator);
            for (candidate.scope_maps.items, 0..) |map, scope_index| {
                var rows = map.iterator();
                while (rows.next()) |row| if (row.value_ptr.* == sid) {
                    if (scope_index != event.before.scope_id.toIndex()) return error.InvalidScope;
                    try aliases.append(candidate.allocator, .{ .scope = scope_index, .key = row.key_ptr.* });
                };
            }
            if (aliases.items.len == 0 or candidate.scopes.items[event.before.scope_id.toIndex()].symbol_count == 0) return error.InvalidScope;
            for (candidate.symbol_ids.items, 0..) |id, raw| if (id == sid and raw != @backingInt(event.binding)) {
                if (raw == @backingInt(payload.read)) {
                    const tag = candidate.ast.nodes.items[raw].tag;
                    if (tag == .identifier_reference or tag == .assignment_target_identifier or tag == .binding_identifier) return error.InvalidSymbol;
                    continue;
                }
                // Flow and other source binding producers keep their original
                // declaration anchor after attaching the same SID to its real
                // output binding. Only an exact, initially inactive snapshot
                // from this journal may be consumed with that output binding.
                if (live.isSet(raw) or candidate.scope_owner_map.contains(@intCast(raw))) return error.InvalidSymbol;
                var matches: usize = 0;
                for (read_anchors) |anchor| if (@backingInt(anchor.node) == raw) {
                    if (!sameRetirementNodePayload(candidate.ast.nodes.items[raw], anchor.before_node)) return error.InvalidSymbol;
                    matches += 1;
                };
                for (receipt.inactive_bindings) |anchor| if (@backingInt(anchor.node) == raw) {
                    if (anchor.symbol_id != event.symbol_id or !std.meta.eql(anchor.before_node.span, event.before.name) or
                        !sameRetirementNodePayload(candidate.ast.nodes.items[raw], anchor.before_node)) return error.InvalidSymbol;
                    switch (anchor.before_node.tag) {
                        .binding_identifier, .flow_match_binding_pattern, .identifier_reference => {},
                        .flow_match_rest => if (anchor.before_node.data.none == 0) return error.InvalidSymbol,
                        else => return error.InvalidSymbol,
                    }
                    matches += 1;
                };
                if (matches != 1) return error.InvalidSymbol;
                for (candidate.references.items) |row| if (row.node_index == @as(NodeIndex, @fromBackingInt(@as(u32, @intCast(raw)))) or row.declaration_node_index == @as(NodeIndex, @fromBackingInt(@as(u32, @intCast(raw))))) return error.InvalidSymbol;
            };
            try candidate.source_owned_retirements.put(candidate.allocator, sid, .{
                .symbol_id = event.symbol_id,
                .before = event.before,
                .declaration = event.declaration,
                .declaration_node = event.binding_node,
                .source_owner = event.statement,
                .source_owner_node = event.statement_node,
                .source_scope = event.before.scope_id,
                .source_parent = payload.source_frame.parent,
                .source_name = event.binding,
                .source_name_symbol = event.symbol_id,
                .closure_scope = .none,
                .closure_parent = .none,
                .reason = .inlined_local_binding,
                .inlined_binding = payload,
            });
            _ = try candidate.removeDeclarationAtNode(event.binding, event.symbol_id);
            for (aliases.items) |alias| _ = candidate.scope_maps.items[alias.scope].remove(alias.key);
            candidate.scopes.items[event.before.scope_id.toIndex()].symbol_count -= 1;
            for (candidate.symbol_ids.items, 0..) |id, raw| if (id == sid) {
                candidate.symbol_ids.items[raw] = null;
            };
            _ = candidate.node_scope_provenance.remove(event.binding);
            count += 1;
        }
        if (count == 0) return 0;
        const history = candidate.scopeHistoryView();
        var arena = std.heap.ArenaAllocator.init(candidate.allocator);
        defer arena.deinit();
        const frame_index = try @import("scope_frame_history.zig").validateAndIndex(arena.allocator(), candidate.ast, candidate.scopes.items, &candidate.scope_owner_map, &history, null);
        const roots: Retirement.Roots = .{ .node_scope_provenance = &candidate.node_scope_provenance, .scope_history = &history };
        if (!frame_index.valid or !try Retirement.validateWithIndex(candidate.allocator, candidate.ast, &candidate.source_owned_retirements, &live, candidate.symbols.items, candidate.symbol_ids.items, candidate.scopes.items, candidate.scope_maps.items, &candidate.scope_owner_map, candidate.references.items, &candidate.helper_scope_map, roots, &frame_index)) return error.InvalidSymbol;
        std.mem.swap(SemanticEditor, self, &candidate);
        return count;
    }

    pub fn retireFunctionNameEnvironments(self: *SemanticEditor, sources: []const @import("function_name_retirement.zig").Source, receipt: @import("function_retirement_receipt.zig").ApplicationReceipt, roots: @import("source_owned_retirement.zig").Roots) Error!usize {
        if (sources.len == 0) return 0;
        const Names = @import("function_name_retirement.zig");
        if (receipt.domain != self.ast) return error.InvalidNode;
        if (sources[0].root.isNone() or @backingInt(sources[0].root) >= self.ast.nodes.items.len) return error.InvalidNode;
        const nodes = try @import("../parser/ast_walk.zig").collectReachableNodeIndicesFrom(self.allocator, self.ast, sources[0].root);
        defer self.allocator.free(nodes);
        var live = try std.DynamicBitSet.initEmpty(self.allocator, self.ast.nodes.items.len);
        defer live.deinit();
        for (nodes) |raw| live.set(raw);
        var candidate = try SemanticEditor.init(self.allocator, self.ast, self.symbols.items, self.scopes.items, self.scope_maps.items, self.scope_owner_map, self.references.items, self.symbol_ids.items, self.helper_scope_map);
        defer candidate.deinit();
        try candidate.importScopeHistory(self.scopeHistoryView());
        try candidate.importNodeScopeProvenance(self.node_scope_provenance);
        try candidate.importSourceOwnedRetirements(self.source_owned_retirements);
        var count: usize = 0;
        for (sources, 0..) |source, index| {
            const w = source.witness;
            const e = w.event;
            const sid = @backingInt(e.symbol_id);
            if (source.domain != self.ast or source.backing.ptr != self.ast.source.ptr or source.backing.len != self.ast.source.len or source.root != sources[0].root or
                !candidate.validSymbol(e.symbol_id) or e.owner.isNone() or @backingInt(e.owner) >= live.capacity() or e.name.isNone() or @backingInt(e.name) >= candidate.symbol_ids.items.len) return error.InvalidNode;
            for (sources[0..index]) |previous| if (previous.witness.event.symbol_id == e.symbol_id or previous.witness.event.owner == e.owner) return error.DuplicateBinding;
            // A wholly dead function is consumed by the existing whole-function
            // source closure path. This API never retires its live body.
            if (!live.isSet(@backingInt(e.owner))) continue;
            var events: usize = 0;
            for (receipt.function_name_elisions) |event| if (event.owner == e.owner) {
                if (!Names.sameEvent(event, e)) return error.InvalidNode;
                events += 1;
            };
            if (events == 0 and self.ast.readExtraNode(e.owner_node.data.extra, ast_mod.FunctionExtra.name) == e.name) continue;
            if (events != 1) return error.InvalidNode;
            if (candidate.source_owned_retirements.get(sid)) |prior| {
                if (!Names.validateState(prior, self.ast, &live, candidate.symbols.items, candidate.symbol_ids.items, candidate.scopes.items, &candidate.scope_owner_map, candidate.references.items)) return error.InvalidSymbol;
                continue;
            }
            if (!candidate.scope_history.enabled or !candidate.validScope(w.name_scope) or !candidate.validScope(w.body_scope) or !candidate.validScope(w.outer_scope) or
                source.before.scope_id != w.name_scope or source.before.origin_scope != w.name_scope or !source.before.kind.isFunctionLike() or source.before.isSynthetic() or source.before.isExported() or
                source.before.reference_count != 0 or source.before.write_count != 0 or source.before.decl_flags.preserve_class_name or
                !@import("source_owned_retirement.zig").equalSymbol(source.before, candidate.symbols.items[sid]) or candidate.symbol_ids.items[@backingInt(e.name)] != sid or live.isSet(@backingInt(e.name))) return error.InvalidSymbol;
            if (!std.meta.eql(candidate.scopes.items[w.name_scope.toIndex()], w.name_frame) or !std.meta.eql(candidate.scopes.items[w.body_scope.toIndex()], w.body_frame) or
                w.name_frame.kind != .block or w.name_frame.parent != w.outer_scope or w.name_frame.symbol_count != 1 or w.name_frame.blocksMangling() or w.body_frame.kind != .function or w.body_frame.blocksMangling() or candidate.scopes.items[w.outer_scope.toIndex()].blocksMangling()) return error.InvalidScope;
            const owner = self.ast.getNode(e.owner);
            if (owner.tag != .function_expression or !self.ast.hasExtra(owner.data.extra, ast_mod.FunctionExtra.flags) or e.owner_node.tag != owner.tag or owner.data.extra != e.owner_node.data.extra or !std.meta.eql(owner.span, e.owner_node.span) or
                !self.ast.readExtraNode(owner.data.extra, ast_mod.FunctionExtra.name).isNone() or self.ast.readExtraNode(owner.data.extra, ast_mod.FunctionExtra.params) != e.parameters or self.ast.readExtraNode(owner.data.extra, ast_mod.FunctionExtra.body) != e.body or
                !@import("import_erasure.zig").equalNode(self.ast.getNode(e.name), e.name_node) or !std.meta.eql(source.before.name, e.name_node.data.string_ref) or !std.meta.eql(source.before.declaration_span, e.name_node.span) or
                candidate.scope_owner_map.get(@backingInt(e.owner)) != @as(?u32, @backingInt(w.body_scope)) or (candidate.scope_owner_map.get(@backingInt(e.body)) != null and candidate.scope_owner_map.get(@backingInt(e.body)) != @as(?u32, @backingInt(w.body_scope)))) return error.InvalidNode;
            if (!Names.validateFormals(w, self.ast, candidate.symbols.items, candidate.symbol_ids.items, candidate.references.items)) return error.InvalidSymbol;
            const formal_scope = if (!w.parameter_scope.isNone() and !w.retire_parameters) w.parameter_scope else w.body_scope;
            if (candidate.scope_owner_map.get(@backingInt(e.parameters))) |parameter_owner| if (parameter_owner != @backingInt(formal_scope)) return error.InvalidScope;
            if (w.parameter_scope.isNone()) {
                if (w.retire_parameters or w.body_frame.parent != w.name_scope) return error.InvalidScope;
            } else {
                if (!candidate.validScope(w.parameter_scope) or !std.meta.eql(candidate.scopes.items[w.parameter_scope.toIndex()], w.parameter_frame) or w.body_frame.parent != w.parameter_scope or
                    w.parameter_frame.parent != w.name_scope or w.parameter_frame.kind != .function or w.parameter_frame.blocksMangling()) return error.InvalidScope;
                if (w.retire_parameters) {
                    if (w.parameter_frame.symbol_count != 0 or candidate.scope_maps.items[w.parameter_scope.toIndex()].count() != 0) return error.InvalidScope;
                } else if (candidate.scope_owner_map.get(@backingInt(e.parameters)) != @as(?u32, @backingInt(w.parameter_scope)) or !live.isSet(@backingInt(e.parameters))) return error.InvalidScope;
            }
            for (candidate.symbols.items, 0..) |row, raw| if (row.scope_id == w.name_scope or (w.retire_parameters and !w.parameter_scope.isNone() and row.scope_id == w.parameter_scope)) {
                if (raw != sid) return error.InvalidSymbol;
            };
            var declarations: usize = 0;
            for (candidate.references.items) |row| {
                if (row.symbol_id == e.symbol_id) {
                    if (!std.meta.eql(row, source.declaration)) return error.InvalidSymbol;
                    declarations += 1;
                } else if (row.scope_id == w.name_scope or (w.retire_parameters and !w.parameter_scope.isNone() and row.scope_id == w.parameter_scope)) return error.InvalidScope;
            }
            if (declarations != 1 or source.declaration.node_index != .none or source.declaration.scope_id != w.name_scope or source.declaration.declaration_node_index != e.name or !std.meta.eql(source.declaration.flags, @as(ReferenceFlags, .{ .declare = true }))) return error.InvalidSymbol;
            for (candidate.symbol_ids.items, 0..) |id, raw| if (id == sid and raw != @backingInt(e.name)) return error.InvalidSymbol;
            for (candidate.scopes.items, 0..) |frame, raw| if (frame.parent == w.name_scope or (w.retire_parameters and !w.parameter_scope.isNone() and frame.parent == w.parameter_scope)) {
                if (raw != w.body_scope.toIndex() and (w.parameter_scope.isNone() or raw != w.parameter_scope.toIndex())) return error.InvalidScope;
            };
            if (!Names.validateOwnerAliases(w, self.ast, &live, &candidate.scope_owner_map, false)) return error.InvalidScope;
            var helpers = candidate.helper_scope_map.valueIterator();
            while (helpers.next()) |id| if (id.* == sid) return error.InvalidSymbol;
            for (roots.symbol_ids) |id| if (id == sid) return error.InvalidSymbol;
            if (roots.runtime_helper_symbols) |map| {
                var values = map.valueIterator();
                while (values.next()) |id| if (@backingInt(id.*) == sid) return error.InvalidSymbol;
            }
            inline for (.{ roots.class_self_symbols, roots.namespace_member_owners, roots.namespace_declaration_owners }) |maybe_map| if (maybe_map) |map| {
                var values = map.valueIterator();
                while (values.next()) |id| if (id.* == sid) return error.InvalidSymbol;
            };
            for (candidate.scope_maps.items, 0..) |map, raw_scope| {
                var rows = map.iterator();
                while (rows.next()) |row| if (row.value_ptr.* == sid) {
                    if (raw_scope != w.name_scope.toIndex() or !std.mem.eql(u8, row.key_ptr.*, self.ast.getText(source.before.name))) return error.InvalidScope;
                };
            }
            if (candidate.scope_maps.items[w.name_scope.toIndex()].count() != 1) return error.InvalidScope;
            try candidate.source_owned_retirements.put(candidate.allocator, sid, .{ .symbol_id = e.symbol_id, .before = source.before, .declaration = source.declaration, .declaration_node = e.name_node, .source_owner = e.owner, .source_owner_node = e.owner_node, .source_scope = w.body_scope, .source_parent = w.outer_scope, .source_name = e.name, .source_name_symbol = e.symbol_id, .closure_scope = w.name_scope, .closure_parent = w.outer_scope, .reason = .elided_function_name, .function_name_elision = w });
            for (w.owners) |alias| {
                candidate.scope_history.recordOwner(candidate.allocator, candidate.ast, alias.scope, candidate.scopes.items[alias.scope.toIndex()], alias.owner.node, .none, .{}) catch |err| return historyError(err);
                _ = candidate.scope_owner_map.remove(@backingInt(alias.owner.node));
            }
            try candidate.reparentScope(if (!w.parameter_scope.isNone() and !w.retire_parameters) w.parameter_scope else w.body_scope, w.outer_scope);
            _ = try candidate.removeDeclarationAtNode(e.name, e.symbol_id);
            candidate.scope_maps.items[w.name_scope.toIndex()].clearRetainingCapacity();
            candidate.scopes.items[w.name_scope.toIndex()].symbol_count -= 1;
            candidate.symbol_ids.items[@backingInt(e.name)] = null;
            _ = candidate.node_scope_provenance.remove(e.name);
            count += 1;
        }
        var candidate_roots = roots;
        candidate_roots.node_scope_provenance = &candidate.node_scope_provenance;
        const candidate_history = candidate.scopeHistoryView();
        candidate_roots.scope_history = &candidate_history;
        var index_arena = std.heap.ArenaAllocator.init(candidate.allocator);
        defer index_arena.deinit();
        const frame_index = try @import("scope_frame_history.zig").validateAndIndex(index_arena.allocator(), candidate.ast, candidate.scopes.items, &candidate.scope_owner_map, &candidate_history, null);
        if (!frame_index.valid or !try @import("source_owned_retirement.zig").validateWithIndex(candidate.allocator, candidate.ast, &candidate.source_owned_retirements, &live, candidate.symbols.items, candidate.symbol_ids.items, candidate.scopes.items, candidate.scope_maps.items, &candidate.scope_owner_map, candidate.references.items, &candidate.helper_scope_map, candidate_roots, &frame_index)) return error.InvalidScope;
        if (count == 0) return 0;
        // The candidate and history are complete. Swap is nonfallible; defer
        // now destroys the old graph backing, never either borrowed AST.
        std.mem.swap(SemanticEditor, self, &candidate);
        return count;
    }

    /// Capture only identities handed off by the actual static-class creator.
    pub fn captureStaticCaptureAliases(self: *SemanticEditor, root: NodeIndex, completed: anytype) Error![]const @import("static_capture_retirement.zig").Source {
        return @import("static_capture_retirement.zig").captureAll(self.allocator, self, root, completed);
    }

    /// Consume an exact alias copy without inventing a new output identity.
    /// All validation/allocation precedes map, declaration and ID publication.
    pub fn retireStaticCaptureAliases(self: *SemanticEditor, sources: []const @import("static_capture_retirement.zig").Source, receipt: @import("function_retirement_receipt.zig").ApplicationReceipt, roots: @import("source_owned_retirement.zig").Roots) Error!usize {
        if (sources.len == 0) return 0;
        const Static = @import("static_capture_retirement.zig");
        const Retirement = @import("source_owned_retirement.zig");
        if (sources[0].root.isNone() or @backingInt(sources[0].root) >= self.ast.nodes.items.len) return error.InvalidNode;
        const nodes = try @import("../parser/ast_walk.zig").collectReachableNodeIndicesFrom(self.allocator, self.ast, sources[0].root);
        defer self.allocator.free(nodes);
        var live = try std.DynamicBitSet.initEmpty(self.allocator, self.ast.nodes.items.len);
        defer live.deinit();
        for (nodes) |raw| live.set(raw);
        var selected: std.ArrayList(struct { source: Static.Source, witness: Static.Witness }) = .empty;
        defer selected.deinit(self.allocator);
        const Alias = struct { scope: usize, key: []const u8 };
        var aliases: std.ArrayList(Alias) = .empty;
        defer aliases.deinit(self.allocator);
        for (sources, 0..) |source, source_index| {
            if (source.root != sources[0].root or source.domain != self.ast or source.source_buffer.ptr != self.ast.source.ptr or source.source_buffer.len != self.ast.source.len) return error.InvalidNode;
            const raw = @backingInt(source.symbol_id);
            if (!self.validSymbol(source.symbol_id)) return error.InvalidSymbol;
            for (sources[0..source_index]) |previous| if (previous.symbol_id == source.symbol_id) return error.DuplicateBinding;
            if (self.source_owned_retirements.get(raw)) |existing| {
                if (existing.reason != .static_class_capture_alias or !Retirement.equalSymbol(existing.before, source.before) or
                    !Static.validateState(existing, self.ast, &live, self.symbols.items, self.symbol_ids.items, self.scopes.items, &self.scope_owner_map, self.references.items)) return error.InvalidSymbol;
                continue;
            }
            const witness = (try Static.prepare(self, source, receipt, &live)) orelse continue;
            var expected = source.before;
            expected.reference_count = 0;
            expected.write_count = 0;
            if (!Retirement.equalSymbol(expected, self.symbols.items[raw]) or !self.validScope(expected.scope_id) or
                self.scopes.items[expected.scope_id.toIndex()].parent != source.parent or self.scopes.items[expected.scope_id.toIndex()].symbol_count == 0) return error.InvalidSymbol;
            var scope_retirements: usize = 1;
            for (selected.items) |previous| if (previous.source.before.scope_id == expected.scope_id) {
                scope_retirements += 1;
            };
            if (self.scopes.items[expected.scope_id.toIndex()].symbol_count < scope_retirements) return error.InvalidScope;
            const binding = source.declaration.declaration_node_index;
            if (@backingInt(binding) >= self.symbol_ids.items.len or self.symbol_ids.items[@backingInt(binding)] != raw or
                !@import("import_erasure.zig").equalNode(self.ast.getNode(binding), source.binding_node)) return error.InvalidNode;
            var declarations: usize = 0;
            for (self.references.items) |row| if (row.symbol_id == source.symbol_id) {
                if (!std.meta.eql(row, source.declaration)) return error.InvalidSymbol;
                declarations += 1;
            };
            if (declarations != 1) return error.ReferenceNotFound;
            for (self.symbol_ids.items, 0..) |id, node| if (id == raw and node != @backingInt(binding)) return error.InvalidSymbol;
            var protected = self.helper_scope_map.valueIterator();
            while (protected.next()) |id| if (id.* == raw) return error.InvalidSymbol;
            for (roots.symbol_ids) |id| if (id == raw) return error.InvalidSymbol;
            if (roots.runtime_helper_symbols) |map| {
                var values = map.valueIterator();
                while (values.next()) |id| if (@backingInt(id.*) == raw) return error.InvalidSymbol;
            }
            inline for (.{ roots.class_self_symbols, roots.namespace_member_owners, roots.namespace_declaration_owners }) |maybe_map| if (maybe_map) |map| {
                var values = map.valueIterator();
                while (values.next()) |id| if (id.* == raw) return error.InvalidSymbol;
            };
            inline for (.{ roots.namespace_member_owners, roots.namespace_declaration_owners }) |maybe_map| if (maybe_map) |map| {
                if (map.contains(raw)) return error.InvalidSymbol;
            };
            var found_alias: usize = 0;
            for (self.scope_maps.items, 0..) |map, scope| {
                var entries = map.iterator();
                while (entries.next()) |entry| if (entry.value_ptr.* == raw) {
                    if (scope != expected.scope_id.toIndex() or !std.mem.eql(u8, entry.key_ptr.*, self.ast.getText(expected.name))) return error.InvalidScope;
                    try aliases.append(self.allocator, .{ .scope = scope, .key = entry.key_ptr.* });
                    found_alias += 1;
                };
            }
            if (found_alias == 0 or self.scope_owner_map.contains(@backingInt(binding))) return error.InvalidScope;
            try selected.append(self.allocator, .{ .source = source, .witness = witness });
        }
        if (selected.items.len == 0) return 0;
        var next = try self.source_owned_retirements.clone(self.allocator);
        errdefer next.deinit(self.allocator);
        try next.ensureUnusedCapacity(self.allocator, @intCast(selected.items.len));
        for (selected.items) |item| {
            const source = item.source;
            next.putAssumeCapacity(@backingInt(source.symbol_id), .{
                .symbol_id = source.symbol_id,
                .before = source.before,
                .declaration = source.declaration,
                .declaration_node = source.binding_node,
                .source_owner = source.owner,
                .source_owner_node = source.owner_node,
                .source_scope = source.before.scope_id,
                .source_parent = source.parent,
                .source_name = source.class_binding,
                .source_name_symbol = source.class_symbol,
                .closure_scope = .none,
                .closure_parent = .none,
                .reason = .static_class_capture_alias,
                .static_capture_alias = item.witness,
            });
        }
        // No fallible work follows. Every source slot keeps its original birth.
        for (selected.items) |item| {
            const source = item.source;
            var write: usize = 0;
            for (self.references.items) |row| {
                if (row.symbol_id == source.symbol_id) continue;
                self.references.items[write] = row;
                write += 1;
            }
            self.references.shrinkRetainingCapacity(write);
            self.symbol_ids.items[@backingInt(source.declaration.declaration_node_index)] = null;
            _ = self.node_scope_provenance.remove(source.declaration.declaration_node_index);
            self.scopes.items[source.before.scope_id.toIndex()].symbol_count -= 1;
        }
        for (aliases.items) |alias| _ = self.scope_maps.items[alias.scope].remove(alias.key);
        self.reference_index.clearRetainingCapacity();
        self.reference_index_built = false;
        self.source_owned_retirements.deinit(self.allocator);
        self.source_owned_retirements = next;
        return selected.items.len;
    }

    /// Remove the semantic declaration for a local const whose exact binding
    /// node is unreachable after syntax minification. The caller must remove
    /// every reference first. Keep the SymbolId row stable as an orphaned slot;
    /// clear only its dead AST mapping and scope-name entries.
    pub fn removeUnreachableLocalConstDeclaration(
        self: *SemanticEditor,
        binding_node: NodeIndex,
        reachable: *const std.DynamicBitSet,
    ) Error!SymbolId {
        return self.removeUnreachableLocalLexicalDeclarationImpl(binding_node, reachable, true);
    }

    /// Remove an unreachable local `let` or `const` declaration after its
    /// exact references have been removed. The stable SymbolId remains in the
    /// symbol array; callers may later rehome it if its lexical scope is also
    /// elided.
    pub fn removeUnreachableLocalLexicalDeclaration(
        self: *SemanticEditor,
        binding_node: NodeIndex,
        reachable: *const std.DynamicBitSet,
    ) Error!SymbolId {
        return self.removeUnreachableLocalLexicalDeclarationImpl(binding_node, reachable, false);
    }

    /// Remove a dead function-, module-, or class-static-block-scoped `var`
    /// declaration after its exact static references have been removed. Global
    /// vars create observable global properties. Class static blocks are
    /// eligible only when their AST node and body are the exact two owners of
    /// the strict var scope. Keep its SymbolId row stable as an unbound slot.
    pub fn removeUnreachableLocalVarDeclaration(
        self: *SemanticEditor,
        binding_node: NodeIndex,
        reachable: *const std.DynamicBitSet,
    ) Error!SymbolId {
        if (binding_node.isNone()) return error.InvalidNode;
        const raw = @backingInt(binding_node);
        if (raw >= self.ast.nodes.items.len or raw >= self.symbol_ids.items.len or
            raw >= reachable.capacity() or reachable.isSet(raw) or
            self.ast.nodes.items[raw].tag != .binding_identifier) return error.InvalidNode;
        const symbol_raw = self.symbol_ids.items[raw] orelse return error.InvalidSymbol;
        if (symbol_raw >= self.symbols.items.len) return error.InvalidSymbol;
        const symbol_id: SymbolId = @fromBackingInt(symbol_raw);
        const symbol = self.symbols.items[symbol_raw];
        if (symbol.kind != .variable_var or symbol.isExported() or symbol.isSynthetic() or
            symbol.synthetic_name.len != 0 or symbol.synthetic_owner_id != null or
            symbol.output_name_hint.len != 0 or symbol.reference_count != 0 or
            symbol.write_count != 0 or symbol.scope_id.isNone() or
            symbol.scope_id.toIndex() >= self.scopes.items.len or
            symbol.origin_scope.isNone() or symbol.origin_scope.toIndex() >= self.scopes.items.len or
            symbol.name.start & Ast.STRING_TABLE_BIT != 0 or !self.validTextSpan(symbol.name) or
            !symbol.annex_b_alias.variable.isNone() or symbol.annex_b_alias.state != .native or
            symbol.annex_b_alias.source_assignment_count != 0) return error.InvalidSymbol;

        const scope_id = symbol.scope_id;
        const scope_raw = scope_id.toIndex();
        const scope = self.scopes.items[scope_raw];
        if ((scope.kind != .function and scope.kind != .module and scope.kind != .class_static_block) or
            (scope.kind == .module and !scope.is_strict) or
            (scope.kind == .function and
                scope_owner_proof.exactClassStaticBlockScopeOwners(
                    self.ast,
                    self.scopes.items,
                    &self.scope_owner_map,
                    reachable,
                    @intCast(scope_raw),
                )) or
            (scope.kind == .class_static_block and
                (!scope.is_strict or scope.parent.isNone() or
                    scope.parent.toIndex() >= self.scopes.items.len or
                    self.scopes.items[scope.parent.toIndex()].kind != .class_body or
                    !scope_owner_proof.exactClassStaticBlockScopeOwners(
                        self.ast,
                        self.scopes.items,
                        &self.scope_owner_map,
                        reachable,
                        @intCast(scope_raw),
                    ))) or
            scope.subtree_has_direct_eval or scope.subtree_has_with)
            return error.InvalidScope;
        var origin_scope = symbol.origin_scope;
        var hops: usize = 0;
        while (origin_scope != scope_id and hops < self.scopes.items.len) : (hops += 1) {
            if (origin_scope.isNone() or origin_scope.toIndex() >= self.scopes.items.len)
                return error.InvalidScope;
            origin_scope = self.scopes.items[origin_scope.toIndex()].parent;
        }
        if (origin_scope != scope_id) return error.InvalidScope;

        var declaration_index: ?usize = null;
        for (self.references.items, 0..) |reference, index| {
            if (reference.symbol_id != symbol_id) continue;
            if (!reference.flags.declare or reference.flags.read or reference.flags.write or
                reference.flags.type_context or reference.flags.value_as_type or
                reference.scope_id != scope_id or reference.node_index != .none or
                reference.declaration_node_index != binding_node or declaration_index != null)
                return error.InvalidSymbol;
            declaration_index = index;
        }
        const declaration = declaration_index orelse return error.ReferenceNotFound;

        const name = symbol.nameText(self.ast.source);
        const scope_map = &self.scope_maps.items[scope_raw];
        if (name.len == 0 or scope_map.get(name) != symbol_raw or
            self.scopes.items[scope_raw].symbol_count == 0 or self.scope_owner_map.contains(raw))
            return error.InvalidScope;
        var mapped_symbols: std.AutoHashMapUnmanaged(usize, void) = .empty;
        defer mapped_symbols.deinit(self.allocator);
        var map_entries = scope_map.iterator();
        while (map_entries.next()) |entry| {
            const mapped_raw = entry.value_ptr.*;
            if (mapped_raw >= self.symbols.items.len or self.symbols.items[mapped_raw].scope_id != scope_id)
                return error.InvalidScope;
            try mapped_symbols.put(self.allocator, mapped_raw, {});
        }
        if (mapped_symbols.count() != self.scopes.items[scope_raw].symbol_count)
            return error.InvalidScope;

        // Remove both source and decoded keys only when they point to this ID.
        const decoded_name = try Scanner.decodeIdentifierEscapesAlloc(self.allocator, name);
        defer if (decoded_name.ptr != name.ptr) self.allocator.free(decoded_name);
        _ = self.takeDecodedAlias(scope_id, name, decoded_name, symbol_raw);
        _ = scope_map.remove(name);
        self.scopes.items[scope_raw].symbol_count -= 1;
        _ = self.references.orderedRemove(declaration);
        if (self.reference_index_built) {
            for (self.references.items[declaration..], declaration..) |reference, index| {
                if (reference.node_index.isNone()) continue;
                if (self.reference_index.getPtr(@backingInt(reference.node_index))) |stored_index|
                    stored_index.* = index;
            }
        }
        self.symbol_ids.items[raw] = null;
        _ = self.node_scope_provenance.remove(binding_node);
        self.symbols.items[symbol_raw].origin_scope = scope_id;
        self.symbols.items[symbol_raw].const_kind = .none;
        return symbol_id;
    }

    fn removeUnreachableLocalLexicalDeclarationImpl(
        self: *SemanticEditor,
        binding_node: NodeIndex,
        reachable: *const std.DynamicBitSet,
        const_only: bool,
    ) Error!SymbolId {
        if (binding_node.isNone()) return error.InvalidNode;
        const raw = @backingInt(binding_node);
        if (raw >= self.ast.nodes.items.len or raw >= self.symbol_ids.items.len or
            raw >= reachable.capacity() or reachable.isSet(raw) or
            self.ast.nodes.items[raw].tag != .binding_identifier) return error.InvalidNode;
        const symbol_raw = self.symbol_ids.items[raw] orelse return error.InvalidSymbol;
        if (symbol_raw >= self.symbols.items.len) return error.InvalidSymbol;
        const symbol_id: SymbolId = @fromBackingInt(symbol_raw);
        const symbol = self.symbols.items[symbol_raw];
        if ((const_only and symbol.kind != .variable_const) or
            (!const_only and symbol.kind != .variable_const and symbol.kind != .variable_let) or
            symbol.isExported() or symbol.isSynthetic() or
            symbol.synthetic_name.len != 0 or symbol.synthetic_owner_id != null or
            symbol.output_name_hint.len != 0 or symbol.reference_count != 0 or
            symbol.write_count != 0 or symbol.scope_id.isNone() or
            symbol.scope_id.toIndex() >= self.scopes.items.len or
            symbol.name.start & Ast.STRING_TABLE_BIT != 0 or !self.validTextSpan(symbol.name))
            return error.InvalidSymbol;

        var declaration_index: ?usize = null;
        for (self.references.items, 0..) |reference, index| {
            if (reference.symbol_id != symbol_id) continue;
            if (!reference.flags.declare or reference.flags.read or reference.flags.write or
                reference.flags.type_context or reference.flags.value_as_type or
                reference.scope_id != symbol.scope_id or reference.node_index != .none or
                reference.declaration_node_index != binding_node or declaration_index != null)
                return error.InvalidSymbol;
            declaration_index = index;
        }
        const declaration = declaration_index orelse return error.ReferenceNotFound;

        const name = symbol.nameText(self.ast.source);
        const scope_raw = symbol.scope_id.toIndex();
        const scope_map = &self.scope_maps.items[scope_raw];
        if (name.len == 0 or scope_map.get(name) != symbol_raw or
            self.scopes.items[scope_raw].symbol_count == 0 or
            self.scope_owner_map.contains(raw)) return error.InvalidScope;

        // Analyzer maps keep both escaped and decoded keys for source names.
        // Remove only aliases that point to this exact SymbolId.
        const decoded_name = try Scanner.decodeIdentifierEscapesAlloc(self.allocator, name);
        defer if (decoded_name.ptr != name.ptr) self.allocator.free(decoded_name);
        _ = self.takeDecodedAlias(symbol.scope_id, name, decoded_name, symbol_raw);
        _ = scope_map.remove(name);
        self.scopes.items[scope_raw].symbol_count -= 1;
        _ = self.references.orderedRemove(declaration);
        if (self.reference_index_built) {
            for (self.references.items[declaration..], declaration..) |reference, index| {
                if (reference.node_index.isNone()) continue;
                if (self.reference_index.getPtr(@backingInt(reference.node_index))) |stored_index|
                    stored_index.* = index;
            }
        }
        self.symbol_ids.items[raw] = null;
        _ = self.node_scope_provenance.remove(binding_node);
        return symbol_id;
    }

    /// Move an unreachable lexical SymbolId out of a block scope that will be
    /// elided. Its declaration and every AST/reference identity must already
    /// be gone; the stable row is retained under the live parent scope.
    pub fn rehomeUnreachableLocalLexicalSymbol(
        self: *SemanticEditor,
        symbol_id: SymbolId,
        source_scope: ScopeId,
    ) Error!void {
        if (!self.validSymbol(symbol_id) or !self.validScope(source_scope)) return error.InvalidSymbol;
        const source_raw = source_scope.toIndex();
        const scope = self.scopes.items[source_raw];
        if ((scope.kind != .block and scope.kind != .switch_block) or
            scope.parent.isNone() or !self.validScope(scope.parent)) return error.InvalidScope;

        const symbol_raw = @backingInt(symbol_id);
        const symbol = &self.symbols.items[symbol_raw];
        if ((symbol.kind != .variable_const and symbol.kind != .variable_let) or
            symbol.scope_id != source_scope or symbol.origin_scope != source_scope or
            symbol.isExported() or symbol.isSynthetic() or symbol.synthetic_name.len != 0 or
            symbol.synthetic_owner_id != null or symbol.output_name_hint.len != 0 or
            symbol.reference_count != 0 or symbol.write_count != 0 or
            !symbol.annex_b_alias.variable.isNone() or symbol.annex_b_alias.state != .native or
            symbol.annex_b_alias.source_assignment_count != 0 or symbol.scope_id.isNone()) return error.InvalidSymbol;

        for (self.references.items) |reference| {
            if (reference.symbol_id == symbol_id) return error.InvalidSymbol;
        }
        for (self.symbol_ids.items) |mapped_symbol| {
            if (mapped_symbol == symbol_raw) return error.InvalidSymbol;
        }
        for (self.scope_maps.items) |scope_map| {
            var entries = scope_map.iterator();
            while (entries.next()) |entry| {
                if (entry.value_ptr.* == symbol_raw) return error.InvalidScope;
            }
        }

        symbol.scope_id = scope.parent;
        symbol.origin_scope = scope.parent;
        symbol.const_kind = .none;
    }
};

const DeadLocalConstMutation = enum {
    none,
    reachable_binding,
    wrong_binding_node,
    missing_symbol_identity,
    wrong_symbol_identity,
    exported_symbol,
    non_const_symbol,
    synthetic_name,
    live_reference,
    missing_scope_name,
    wrong_scope_name_identity,
    wrong_declaration_anchor,
    duplicate_declaration,
    nonzero_reference_count,
    nonzero_write_count,
    output_name_hint,
    scope_owner_sidecar,
};

fn deadLocalConstRemovalForTest(mutation: DeadLocalConstMutation) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source = if (mutation == .live_reference or mutation == .wrong_binding_node)
        "const local = 1; function read() { return local; } const other = 2;"
    else
        "const local = 1; const other = 2;";
    var scanner = try Scanner.init(allocator, source);
    defer scanner.deinit();
    var parser = @import("../parser/parser.zig").Parser.init(allocator, &scanner);
    parser.is_module = true;
    defer parser.deinit();
    const root = try parser.parse();
    var analyzer = @import("analyzer.zig").SemanticAnalyzer.init(allocator, &parser.ast);
    analyzer.is_module = true;
    analyzer.enable_stmt_info = true;
    analyzer.enable_exact_declaration_anchors = true;
    defer analyzer.deinit();
    try analyzer.analyze();

    var local_id: ?u32 = null;
    var other_id: ?u32 = null;
    var local_binding: ?NodeIndex = null;
    for (analyzer.symbols.items, 0..) |symbol, index| {
        const name = symbol.nameText(source);
        if (std.mem.eql(u8, name, "local")) local_id = @intCast(index);
        if (std.mem.eql(u8, name, "other")) other_id = @intCast(index);
    }
    const local_symbol = local_id orelse return error.MissingLocalSymbol;
    const other_symbol = other_id orelse return error.MissingOtherSymbol;
    for (parser.ast.nodes.items, 0..) |node, raw| {
        if (node.tag == .binding_identifier and raw < analyzer.symbol_ids.items.len and
            analyzer.symbol_ids.items[raw] == local_symbol)
        {
            local_binding = @fromBackingInt(@intCast(raw));
            break;
        }
    }
    const binding = local_binding orelse return error.MissingLocalBinding;
    var local_reference: ?NodeIndex = null;
    if (mutation == .wrong_binding_node) {
        for (analyzer.references.items) |reference| {
            if (@backingInt(reference.symbol_id) == local_symbol and !reference.flags.declare) {
                local_reference = reference.node_index;
                break;
            }
        }
        if (local_reference == null) return error.MissingLocalReference;
    }
    const scope_id = analyzer.symbols.items[local_symbol].scope_id;
    var editor = try analyzer.beginEdit();
    defer editor.deinit();

    if (mutation != .reachable_binding) {
        if (parser.ast.nodes.items[@backingInt(root)].tag != .program) return error.InvalidProgram;
        parser.ast.nodes.items[@backingInt(root)].data.list.len = 0;
    }
    switch (mutation) {
        .none, .reachable_binding => {},
        .wrong_binding_node => {},
        .missing_symbol_identity => editor.symbol_ids.items[@backingInt(binding)] = null,
        .wrong_symbol_identity => editor.symbol_ids.items[@backingInt(binding)] = other_symbol,
        .exported_symbol => editor.symbols.items[local_symbol].decl_flags.is_exported = true,
        .non_const_symbol => editor.symbols.items[local_symbol].kind = .variable_let,
        .synthetic_name => editor.symbols.items[local_symbol].synthetic_name = "generated",
        .live_reference => {},
        .missing_scope_name => _ = editor.scope_maps.items[scope_id.toIndex()].remove("local"),
        .wrong_scope_name_identity => try editor.scope_maps.items[scope_id.toIndex()].put(allocator, "local", other_symbol),
        .wrong_declaration_anchor => for (editor.references.items) |*reference| {
            if (reference.symbol_id == @as(@TypeOf(reference.symbol_id), @fromBackingInt(@intCast(local_symbol))) and reference.flags.declare) {
                reference.declaration_node_index = .none;
                break;
            }
        },
        .duplicate_declaration => {
            const declaration = for (editor.references.items) |reference| {
                if (reference.symbol_id == @as(@TypeOf(reference.symbol_id), @fromBackingInt(@intCast(local_symbol))) and reference.flags.declare) break reference;
            } else return error.MissingLocalDeclaration;
            try editor.references.append(allocator, declaration);
        },
        .nonzero_reference_count => editor.symbols.items[local_symbol].reference_count = 1,
        .nonzero_write_count => editor.symbols.items[local_symbol].write_count = 1,
        .output_name_hint => editor.symbols.items[local_symbol].output_name_hint = "kept-name",
        .scope_owner_sidecar => try editor.scope_owner_map.put(allocator, @backingInt(binding), @backingInt(scope_id)),
    }

    var reachable = try std.DynamicBitSet.initEmpty(allocator, parser.ast.nodes.items.len);
    defer reachable.deinit();
    const live_nodes = try @import("../parser/ast_walk.zig").collectReachableNodeIndicesFrom(
        allocator,
        &parser.ast,
        root,
    );
    defer allocator.free(live_nodes);
    for (live_nodes) |raw| reachable.set(raw);

    const symbol_id: SymbolId = @fromBackingInt(local_symbol);
    const removal_node = if (mutation == .wrong_binding_node)
        local_reference orelse return error.MissingLocalReference
    else
        binding;
    const result = editor.removeUnreachableLocalConstDeclaration(removal_node, &reachable);
    switch (mutation) {
        .none => {
            const removed = try result;
            try std.testing.expectEqual(symbol_id, removed);
            try std.testing.expectEqual(@as(?u32, null), editor.symbol_ids.items[@backingInt(binding)]);
            try std.testing.expectEqual(@as(?usize, null), editor.scope_maps.items[scope_id.toIndex()].get("local"));
            try std.testing.expectEqual(@as(u16, 1), editor.scopes.items[scope_id.toIndex()].symbol_count);
        },
        .reachable_binding, .wrong_binding_node => try std.testing.expectError(error.InvalidNode, result),
        .missing_scope_name, .wrong_scope_name_identity, .scope_owner_sidecar => try std.testing.expectError(error.InvalidScope, result),
        else => try std.testing.expectError(error.InvalidSymbol, result),
    }
}

test "dead local const removal keeps SymbolId stable and rejects hostile graph mutations" {
    inline for (std.meta.tags(DeadLocalConstMutation)) |mutation| {
        try deadLocalConstRemovalForTest(mutation);
    }
}

const DeadLocalLexicalRehomeMutation = enum {
    none,
    nonlexical_kind,
    wrong_scope_id,
    wrong_origin_scope,
    exported,
    synthetic_name,
    reference_count,
    write_count,
    live_ast_identity,
    source_scope_map_alias,
    parent_scope_map_alias,
    reference_row,
    annex_b_identity,
    wrong_scope_kind,
};

fn deadLocalLexicalRehomeForTest(kind: SymbolKind, mutation: DeadLocalLexicalRehomeMutation) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const declaration = if (kind == .variable_let) "let local=1;" else "const local=1;";
    const source = try std.fmt.allocPrint(allocator, "if (true) {{{s}}}", .{declaration});
    var scanner = try Scanner.init(allocator, source);
    defer scanner.deinit();
    var parser = @import("../parser/parser.zig").Parser.init(allocator, &scanner);
    parser.is_module = true;
    defer parser.deinit();
    const root = try parser.parse();
    var analyzer = @import("analyzer.zig").SemanticAnalyzer.init(allocator, &parser.ast);
    analyzer.is_module = true;
    analyzer.enable_stmt_info = true;
    analyzer.enable_exact_declaration_anchors = true;
    defer analyzer.deinit();
    try analyzer.analyze();

    var local_id: ?u32 = null;
    var binding: ?NodeIndex = null;
    var owner: ?NodeIndex = null;
    for (analyzer.symbols.items, 0..) |symbol, index| {
        if (std.mem.eql(u8, symbol.nameText(source), "local")) local_id = @intCast(index);
    }
    const symbol_raw = local_id orelse return error.MissingLocalSymbol;
    for (parser.ast.nodes.items, 0..) |node, raw| {
        if (node.tag == .binding_identifier and raw < analyzer.symbol_ids.items.len and
            analyzer.symbol_ids.items[raw] == symbol_raw) binding = @fromBackingInt(@intCast(raw));
        if (node.tag == .block_statement) owner = @fromBackingInt(@intCast(raw));
    }
    const binding_node = binding orelse return error.MissingLocalBinding;
    const owner_node = owner orelse return error.MissingBlockOwner;
    const source_scope = analyzer.symbols.items[symbol_raw].scope_id;
    const parent_scope = analyzer.scopes.items[source_scope.toIndex()].parent;
    if (parent_scope.isNone()) return error.MissingParentScope;

    var editor = try analyzer.beginEdit();
    defer editor.deinit();
    parser.ast.nodes.items[@backingInt(root)].data.list.len = 0;
    var reachable = try std.DynamicBitSet.initEmpty(allocator, parser.ast.nodes.items.len);
    defer reachable.deinit();
    const live_nodes = try @import("../parser/ast_walk.zig").collectReachableNodeIndicesFrom(
        allocator,
        &parser.ast,
        root,
    );
    defer allocator.free(live_nodes);
    for (live_nodes) |raw| reachable.set(raw);

    const removed = try editor.removeUnreachableLocalLexicalDeclaration(binding_node, &reachable);
    try std.testing.expectEqual(@as(SymbolId, @fromBackingInt(symbol_raw)), removed);
    try std.testing.expectEqual(@as(?u32, null), editor.symbol_ids.items[@backingInt(binding_node)]);
    try std.testing.expectEqual(@as(?usize, null), editor.scope_maps.items[source_scope.toIndex()].get("local"));
    try std.testing.expectEqual(@as(u16, 0), editor.scopes.items[source_scope.toIndex()].symbol_count);

    switch (mutation) {
        .none => {},
        .nonlexical_kind => editor.symbols.items[symbol_raw].kind = .parameter,
        .wrong_scope_id => editor.symbols.items[symbol_raw].scope_id = parent_scope,
        .wrong_origin_scope => editor.symbols.items[symbol_raw].origin_scope = parent_scope,
        .exported => editor.symbols.items[symbol_raw].decl_flags.is_exported = true,
        .synthetic_name => editor.symbols.items[symbol_raw].synthetic_name = "generated",
        .reference_count => editor.symbols.items[symbol_raw].reference_count = 1,
        .write_count => editor.symbols.items[symbol_raw].write_count = 1,
        .live_ast_identity => editor.symbol_ids.items[@backingInt(binding_node)] = symbol_raw,
        .source_scope_map_alias => try editor.scope_maps.items[source_scope.toIndex()].put(allocator, "alias", symbol_raw),
        .parent_scope_map_alias => try editor.scope_maps.items[parent_scope.toIndex()].put(allocator, "alias", symbol_raw),
        .reference_row => try editor.references.append(allocator, .{
            .node_index = .none,
            .scope_id = source_scope,
            .symbol_id = removed,
        }),
        .annex_b_identity => {
            editor.symbols.items[symbol_raw].annex_b_alias.variable = removed;
            editor.symbols.items[symbol_raw].annex_b_alias.state = .lowered;
        },
        .wrong_scope_kind => editor.scopes.items[source_scope.toIndex()].kind = .function,
    }
    const rehome_result = editor.rehomeUnreachableLocalLexicalSymbol(removed, source_scope);
    if (mutation == .none) {
        try rehome_result;
    } else if (mutation == .source_scope_map_alias or mutation == .parent_scope_map_alias) {
        try std.testing.expectError(error.InvalidScope, rehome_result);
        return;
    } else if (mutation == .wrong_scope_kind) {
        try std.testing.expectError(error.InvalidScope, rehome_result);
        return;
    } else {
        try std.testing.expectError(error.InvalidSymbol, rehome_result);
        return;
    }

    try std.testing.expectEqual(parent_scope, editor.symbols.items[symbol_raw].scope_id);
    try std.testing.expectEqual(parent_scope, editor.symbols.items[symbol_raw].origin_scope);
    try std.testing.expect(try editor.elideEmptyGeneratedScopeOwner(owner_node));
    try std.testing.expect(!editor.scope_owner_map.contains(@backingInt(owner_node)));
    _ = try editor.finish();
}

test "dead local let and const declarations retain SymbolId through scope elision" {
    try deadLocalLexicalRehomeForTest(.variable_let, .none);
    try deadLocalLexicalRehomeForTest(.variable_const, .none);
}

test "dead local lexical rehome rejects hostile graph mutations" {
    inline for (std.meta.tags(DeadLocalLexicalRehomeMutation)) |mutation| {
        try deadLocalLexicalRehomeForTest(.variable_const, mutation);
    }
}

test "parameter rename preserves the body function binding and rejects inconsistent maps" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source = "function f({x}, read = () => x) { function x() { return 8; } return [read(), x()]; }";
    var scanner = try @import("../lexer/scanner.zig").Scanner.init(allocator, source);
    var parser = @import("../parser/parser.zig").Parser.init(allocator, &scanner);
    parser.configureFromExtension(".mjs");
    _ = try parser.parse();
    var analyzer = @import("analyzer.zig").SemanticAnalyzer.init(allocator, &parser.ast);
    analyzer.is_strict_mode = parser.is_strict_mode;
    analyzer.is_module = parser.is_module;
    try analyzer.analyze();
    var editor = try SemanticEditor.init(allocator, &parser.ast, analyzer.symbols.items, analyzer.scopes.items, analyzer.scope_maps.items, analyzer.scope_owner_map, analyzer.references.items, analyzer.symbol_ids.items, analyzer.helper_scope_map);
    var parameter_id: SymbolId = .none;
    var function_id: SymbolId = .none;
    for (editor.symbols.items, 0..) |symbol, i| {
        if (!std.mem.eql(u8, parser.ast.getText(symbol.name), "x")) continue;
        if (symbol.kind == .parameter) parameter_id = @fromBackingInt(@intCast(i));
        if (symbol.kind == .function_decl) function_id = @fromBackingInt(@intCast(i));
    }
    try std.testing.expect(!parameter_id.isNone() and !function_id.isNone());
    const scope = editor.symbols.items[@backingInt(parameter_id)].scope_id;
    const body_scope = editor.parameterBodyFunctionScope(scope) orelse return error.TestUnexpectedResult;
    const count = editor.scopes.items[scope.toIndex()].symbol_count;
    const references = try allocator.dupe(Reference, editor.references.items);
    const node_ids = try allocator.dupe(?u32, editor.symbol_ids.items);
    try std.testing.expectError(error.DuplicateBinding, editor.renameParameterEnvironmentBinding(parameter_id, "read"));
    const invalid_id: SymbolId = @fromBackingInt(@intCast(@as(u32, @intCast(editor.symbols.items.len))));
    try std.testing.expectError(error.InvalidSymbol, editor.renameParameterEnvironmentBinding(invalid_id, "x$1"));
    // A same-spelled lexical body binding is not evidence of the parameter/body
    // redeclaration represented by this operation. (A body `var` is: lowering
    // copies the parameter value into it, #5452.)
    editor.symbols.items[@backingInt(function_id)].kind = .variable_let;
    try std.testing.expectError(error.InvalidSymbol, editor.renameParameterEnvironmentBinding(parameter_id, "x$1"));
    editor.symbols.items[@backingInt(function_id)].kind = .function_decl;
    editor.scopes.items[scope.toIndex()].subtree_has_direct_eval = true;
    try std.testing.expectError(error.InvalidScope, editor.renameParameterEnvironmentBinding(parameter_id, "x$1"));
    editor.scopes.items[scope.toIndex()].subtree_has_direct_eval = false;
    try editor.renameParameterEnvironmentBinding(parameter_id, "x$1");
    try std.testing.expectEqual(@as(?usize, null), editor.scope_maps.items[scope.toIndex()].get("x"));
    try std.testing.expectEqual(@as(?usize, @backingInt(function_id)), editor.scope_maps.items[body_scope.toIndex()].get("x"));
    try std.testing.expectEqual(@as(?usize, @backingInt(parameter_id)), editor.scope_maps.items[scope.toIndex()].get("x$1"));
    try std.testing.expectEqualStrings("x$1", editor.symbols.items[@backingInt(parameter_id)].synthetic_name);
    try std.testing.expectEqual(count, editor.scopes.items[scope.toIndex()].symbol_count);
    try std.testing.expectEqualDeep(references, editor.references.items[0..references.len]);
    var declaration_count: usize = 0;
    for (editor.references.items) |reference| {
        if (reference.symbol_id == parameter_id and reference.flags.declare) declaration_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), declaration_count);
    try std.testing.expectEqualSlices(?u32, node_ids, editor.symbol_ids.items);
    _ = try editor.finish();
}

test "synthetic declaration, explicit references, move and removal keep stable IDs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var ast = Ast.init(allocator, "");
    defer ast.deinit();
    var editor = try SemanticEditor.init(allocator, &ast, &.{}, &.{}, &.{}, .empty, &.{}, &.{}, .empty);
    defer editor.deinit();
    const root = try editor.addScope(.none, .none, .module, true);
    const block_owner = try ast.addNode(.{
        .tag = .block_statement,
        .span = Span.EMPTY,
        .data = .{ .list = try ast.addNodeList(&.{}) },
    });
    const block = try editor.addScope(root, block_owner, .block, false);
    try std.testing.expectEqual(@as(?u32, @backingInt(block)), editor.scope_owner_map.get(@backingInt(block_owner)));
    try std.testing.expect(editor.scopes.items[block.toIndex()].is_strict);
    const name = try ast.addString("_this");
    const binding = try ast.addNode(.{ .tag = .binding_identifier, .span = name, .data = .{ .string_ref = name } });
    const ref_node = try ast.addNode(.{ .tag = .identifier_reference, .span = name, .data = .{ .string_ref = name } });
    const id = try editor.declare(binding, name, Span.EMPTY, block, .variable_var, 2, 1);
    try std.testing.expectEqual(root, editor.symbols.items[@backingInt(id)].scope_id);
    try editor.addReference(ref_node, id, block, .{ .read = true }, 2, 1);
    try std.testing.expectEqual(@as(u32, 1), editor.symbols.items[@backingInt(id)].reference_count);
    try editor.moveReference(ref_node, root, 3, 0);
    try std.testing.expectEqual(@as(u32, 3), editor.references.items[1].stmt_idx);
    try editor.removeReference(ref_node);
    try std.testing.expectEqual(@as(u32, 0), editor.symbols.items[@backingInt(id)].reference_count);
    try std.testing.expectEqual(@as(?u32, @backingInt(id)), editor.symbol_ids.items[@backingInt(binding)]);
    try std.testing.expectEqual(@as(?u32, null), editor.symbol_ids.items[@backingInt(ref_node)]);
    const result = try editor.finish();
    try std.testing.expectEqual(@as(usize, 2), result.scopes.len);
    try std.testing.expectEqual(@as(?u32, @backingInt(block)), result.scope_owner_map.get(@backingInt(block_owner)));
    try std.testing.expectEqual(@as(usize, 1), result.symbols.items.len);
    try std.testing.expectEqual(@as(usize, 1), result.references.len);
}

test "empty flattened block scope elision reparents children and preserves dynamic lookup flags" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var ast = Ast.init(allocator, "");
    defer ast.deinit();
    var editor = try SemanticEditor.init(allocator, &ast, &.{}, &.{}, &.{}, .empty, &.{}, &.{}, .empty);
    defer editor.deinit();
    const root = try editor.addScope(.none, .none, .module, true);
    const wrapper_owner = try ast.addNode(.{ .tag = .block_statement, .span = Span.EMPTY, .data = .{ .list = try ast.addNodeList(&.{}) } });
    const wrapper = try editor.addScope(root, wrapper_owner, .block, false);
    const child_owner = try ast.addNode(.{ .tag = .block_statement, .span = Span.EMPTY, .data = .{ .list = try ast.addNodeList(&.{}) } });
    const child = try editor.addScope(wrapper, child_owner, .block, false);
    editor.scopes.items[wrapper.toIndex()].subtree_has_direct_eval = true;
    editor.scopes.items[wrapper.toIndex()].subtree_has_with = true;

    const name = try ast.addString("outer");
    const binding = try ast.addNode(.{ .tag = .binding_identifier, .span = name, .data = .{ .string_ref = name } });
    const reference = try ast.addNode(.{ .tag = .identifier_reference, .span = name, .data = .{ .string_ref = name } });
    const id = try editor.declare(binding, name, Span.EMPTY, root, .variable_let, 0, 0);
    try editor.addReference(reference, id, child, .{ .read = true }, 0, 0);

    try std.testing.expect(try editor.elideEmptyGeneratedScopeOwner(wrapper_owner));
    try std.testing.expectEqual(@as(?u32, null), editor.scope_owner_map.get(@backingInt(wrapper_owner)));
    try std.testing.expectEqual(root, editor.scopes.items[child.toIndex()].parent);
    try std.testing.expect(editor.scopes.items[root.toIndex()].subtree_has_direct_eval);
    try std.testing.expect(editor.scopes.items[root.toIndex()].subtree_has_with);
    _ = try editor.finish();
}

test "empty flattened block scope elision refuses a scope with a local binding" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var ast = Ast.init(allocator, "");
    defer ast.deinit();
    var editor = try SemanticEditor.init(allocator, &ast, &.{}, &.{}, &.{}, .empty, &.{}, &.{}, .empty);
    defer editor.deinit();
    const root = try editor.addScope(.none, .none, .module, true);
    const owner = try ast.addNode(.{ .tag = .block_statement, .span = Span.EMPTY, .data = .{ .list = try ast.addNodeList(&.{}) } });
    const scope = try editor.addScope(root, owner, .block, false);
    const name = try ast.addString("local");
    const binding = try ast.addNode(.{ .tag = .binding_identifier, .span = name, .data = .{ .string_ref = name } });
    _ = try editor.declare(binding, name, Span.EMPTY, scope, .variable_let, 0, 0);

    try std.testing.expect(!(try editor.elideEmptyGeneratedScopeOwner(owner)));
    try std.testing.expectEqual(@as(?u32, @backingInt(scope)), editor.scope_owner_map.get(@backingInt(owner)));
}

test "empty flattened block scope elision refuses a stale scope-map entry" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var ast = Ast.init(allocator, "");
    defer ast.deinit();
    var editor = try SemanticEditor.init(allocator, &ast, &.{}, &.{}, &.{}, .empty, &.{}, &.{}, .empty);
    defer editor.deinit();
    const root = try editor.addScope(.none, .none, .module, true);
    const owner = try ast.addNode(.{ .tag = .block_statement, .span = Span.EMPTY, .data = .{ .list = try ast.addNodeList(&.{}) } });
    const scope = try editor.addScope(root, owner, .block, false);
    try editor.scope_maps.items[scope.toIndex()].put(allocator, "stale", 0);

    try std.testing.expect(!(try editor.elideEmptyGeneratedScopeOwner(owner)));
    try std.testing.expectEqual(@as(?u32, @backingInt(scope)), editor.scope_owner_map.get(@backingInt(owner)));
}

test "class self storage relocation preserves identity and rejects occupied target atomically" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var ast = Ast.init(allocator, "");
    defer ast.deinit();
    var editor = try SemanticEditor.init(allocator, &ast, &.{}, &.{}, &.{}, .empty, &.{}, &.{}, .empty);
    defer editor.deinit();
    const root = try editor.addScope(.none, .none, .module, true);
    const source = try editor.addScope(root, .none, .class_body, true);
    const occupied = try editor.addScope(root, .none, .function, true);
    const destination = try editor.addScope(root, .none, .function, true);
    const name = try ast.addString("C");
    const source_binding = try ast.addNode(.{ .tag = .binding_identifier, .span = name, .data = .{ .string_ref = name } });
    const duplicate_binding = try ast.addNode(.{ .tag = .binding_identifier, .span = name, .data = .{ .string_ref = name } });
    const generated_binding = try ast.addNode(.{ .tag = .binding_identifier, .span = name, .data = .{ .string_ref = name } });
    const id = try editor.declare(source_binding, name, Span.EMPTY, source, .class_decl, 0, 0);
    _ = try editor.declare(duplicate_binding, name, Span.EMPTY, occupied, .function_decl, 0, 0);
    try std.testing.expectError(error.DuplicateBinding, editor.relocateSymbol(id, occupied));
    try std.testing.expectEqual(source, editor.symbols.items[@backingInt(id)].scope_id);
    try std.testing.expectEqual(@as(?usize, @backingInt(id)), editor.scope_maps.items[source.toIndex()].get("C"));
    try editor.reparentScope(source, destination);
    try editor.relocateSymbol(id, destination);
    try editor.attachExistingBinding(generated_binding, id);
    try editor.attachExistingBinding(generated_binding, id);
    try std.testing.expectEqual(destination, editor.symbols.items[@backingInt(id)].scope_id);
    try std.testing.expectEqual(@as(?usize, @backingInt(id)), editor.scope_maps.items[destination.toIndex()].get("C"));
    try std.testing.expectEqual(@as(?usize, null), editor.scope_maps.items[source.toIndex()].get("C"));
    try std.testing.expectEqual(@as(?u32, @backingInt(id)), editor.symbol_ids.items[@backingInt(generated_binding)]);
    _ = try editor.finish();
}

test "same-text bindings relocate under their exact emitted names" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var ast = Ast.init(allocator, "");
    defer ast.deinit();
    var editor = try SemanticEditor.init(allocator, &ast, &.{}, &.{}, &.{}, .empty, &.{}, &.{}, .empty);
    defer editor.deinit();
    const root = try editor.addScope(.none, .none, .module, true);
    const storage_scope = try editor.addScope(root, .none, .function, false);
    const left_scope = try editor.addScope(storage_scope, .none, .block, false);
    const right_scope = try editor.addScope(storage_scope, .none, .block, false);
    const conflict_scope = try editor.addScope(storage_scope, .none, .block, false);

    const original_name = try ast.addString("_err3");
    const left_source_binding = try ast.addNode(.{ .tag = .binding_identifier, .span = original_name, .data = .{ .string_ref = original_name } });
    const right_source_binding = try ast.addNode(.{ .tag = .binding_identifier, .span = original_name, .data = .{ .string_ref = original_name } });
    const conflict_source_binding = try ast.addNode(.{ .tag = .binding_identifier, .span = original_name, .data = .{ .string_ref = original_name } });
    const left_id = try editor.declare(left_source_binding, original_name, Span.EMPTY, left_scope, .variable_let, 0, 0);
    const right_id = try editor.declare(right_source_binding, original_name, Span.EMPTY, right_scope, .variable_let, 1, 0);
    const conflict_id = try editor.declare(conflict_source_binding, original_name, Span.EMPTY, conflict_scope, .variable_let, 2, 0);
    try std.testing.expect(left_id != right_id and right_id != conflict_id and left_id != conflict_id);

    const left_name = try ast.addString("_err3$4");
    const right_name = try ast.addString("_err3$6");
    const left_output = try ast.addNode(.{ .tag = .binding_identifier, .span = left_name, .data = .{ .string_ref = left_name } });
    const right_output = try ast.addNode(.{ .tag = .binding_identifier, .span = right_name, .data = .{ .string_ref = right_name } });
    editor.references.clearRetainingCapacity(); // model a lowering that removed the source declaration row
    try editor.relocateSymbolAs(left_id, storage_scope, left_output);
    try editor.relocateSymbolAs(right_id, storage_scope, right_output);

    // Force the AST string table to move after relocation. Scope-map keys must
    // remain valid even though the output binding spans still use table offsets.
    for (0..1024) |_| _ = try ast.addString("_relocation_growth");

    try std.testing.expectEqual(@as(?usize, @backingInt(left_id)), editor.scope_maps.items[storage_scope.toIndex()].get("_err3$4"));
    try std.testing.expectEqual(@as(?usize, @backingInt(right_id)), editor.scope_maps.items[storage_scope.toIndex()].get("_err3$6"));
    try std.testing.expectEqual(@as(?usize, null), editor.scope_maps.items[left_scope.toIndex()].get("_err3"));
    try std.testing.expectEqualStrings("_err3$4", editor.symbols.items[@backingInt(left_id)].nameText(ast.source));
    try std.testing.expectEqualStrings("_err3$6", editor.symbols.items[@backingInt(right_id)].nameText(ast.source));
    try std.testing.expectEqual(@as(?u32, @backingInt(left_id)), editor.symbol_ids.items[@backingInt(left_output)]);
    try std.testing.expectEqual(@as(?u32, @backingInt(right_id)), editor.symbol_ids.items[@backingInt(right_output)]);
    try std.testing.expectEqual(@as(usize, 2), editor.references.items.len);
    for (editor.references.items) |reference| {
        try std.testing.expect(reference.flags.declare and reference.node_index.isNone());
        try std.testing.expectEqual(storage_scope, reference.scope_id);
    }

    const conflict_output = try ast.addNode(.{ .tag = .binding_identifier, .span = left_name, .data = .{ .string_ref = left_name } });
    try std.testing.expectError(error.DuplicateBinding, editor.relocateSymbolAs(conflict_id, storage_scope, conflict_output));
    try std.testing.expectEqual(conflict_scope, editor.symbols.items[@backingInt(conflict_id)].scope_id);
    try std.testing.expectEqual(@as(?usize, @backingInt(conflict_id)), editor.scope_maps.items[conflict_scope.toIndex()].get("_err3"));
    try std.testing.expectEqual(@as(?usize, @backingInt(left_id)), editor.scope_maps.items[storage_scope.toIndex()].get("_err3$4"));
    try std.testing.expectEqual(@as(u16, 2), editor.scopes.items[storage_scope.toIndex()].symbol_count);
    _ = try editor.finish();
}

test "relocateSymbolAs moves declaration reference with emitted binding" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var ast = Ast.init(allocator, "x");
    defer ast.deinit();
    var editor = try SemanticEditor.init(allocator, &ast, &.{}, &.{}, &.{}, .empty, &.{}, &.{}, .empty);
    defer editor.deinit();

    const root = try editor.addScope(.none, .none, .module, true);
    const source_scope = try editor.addScope(root, .none, .block, false);
    const target_scope = try editor.addScope(root, .none, .function, false);
    const original_name = try ast.addString("original");
    const source_binding = try ast.addNode(.{ .tag = .binding_identifier, .span = original_name, .data = .{ .string_ref = original_name } });
    const source_name_span = Span{ .start = 0, .end = 1 };
    const output_binding = try ast.addNode(.{ .tag = .binding_identifier, .span = source_name_span, .data = .{ .string_ref = source_name_span } });
    const id = try editor.declare(source_binding, original_name, Span.EMPTY, source_scope, .variable_let, 0, 0);

    try editor.relocateSymbolAs(id, target_scope, output_binding);

    try std.testing.expectEqual(target_scope, editor.symbols.items[@backingInt(id)].scope_id);
    try std.testing.expectEqual(target_scope, editor.references.items[0].scope_id);
    try std.testing.expectEqualStrings("x", editor.symbols.items[@backingInt(id)].synthetic_name);
    try std.testing.expectEqual(@as(?usize, @backingInt(id)), editor.scope_maps.items[target_scope.toIndex()].get("x"));
    try std.testing.expectEqual(@as(?u32, @backingInt(id)), editor.symbol_ids.items[@backingInt(output_binding)]);
    _ = try editor.finish();
}

test "relocateSymbolAs rejects invalid emitted name spans without changing bindings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var ast = Ast.init(allocator, "x");
    defer ast.deinit();
    var editor = try SemanticEditor.init(allocator, &ast, &.{}, &.{}, &.{}, .empty, &.{}, &.{}, .empty);
    defer editor.deinit();

    const root = try editor.addScope(.none, .none, .module, true);
    const target_scope = try editor.addScope(root, .none, .function, false);
    const source_scope = try editor.addScope(target_scope, .none, .block, false);
    const original_name = try ast.addString("original");
    const source_binding = try ast.addNode(.{ .tag = .binding_identifier, .span = original_name, .data = .{ .string_ref = original_name } });
    const id = try editor.declare(source_binding, original_name, Span.EMPTY, source_scope, .variable_let, 0, 0);

    const invalid_spans = [_]Span{
        .{ .start = 0, .end = 2 },
        .{ .start = 0, .end = 0 },
        .{ .start = Ast.STRING_TABLE_BIT, .end = 1 },
    };
    for (invalid_spans) |invalid_span| {
        const output_binding = try ast.addNode(.{ .tag = .binding_identifier, .span = invalid_span, .data = .{ .string_ref = invalid_span } });
        const prior_symbol_id_len = editor.symbol_ids.items.len;
        try std.testing.expectError(error.InvalidNode, editor.relocateSymbolAs(id, target_scope, output_binding));
        try std.testing.expectEqual(prior_symbol_id_len, editor.symbol_ids.items.len);
    }

    try std.testing.expectEqual(source_scope, editor.symbols.items[@backingInt(id)].scope_id);
    try std.testing.expectEqual(@as(?usize, @backingInt(id)), editor.scope_maps.items[source_scope.toIndex()].get("original"));
    try std.testing.expectEqual(@as(?usize, null), editor.scope_maps.items[target_scope.toIndex()].get("x"));
    _ = try editor.finish();
}

fn makeLongEscapedIdentifier(
    allocator: std.mem.Allocator,
    len: usize,
    escaped_index: usize,
    braced_escape: bool,
) !struct { plain: []u8, escaped: []u8, other: []u8 } {
    const plain = try allocator.alloc(u8, len);
    @memset(plain, 'a');
    const other = try allocator.dupe(u8, plain);
    other[len - 1] = 'b';
    const escaped = if (braced_escape)
        try std.fmt.allocPrint(allocator, "{s}\\u{{61}}{s}", .{ plain[0..escaped_index], plain[escaped_index + 1 ..] })
    else
        try std.fmt.allocPrint(allocator, "{s}\\u0061{s}", .{ plain[0..escaped_index], plain[escaped_index + 1 ..] });
    return .{ .plain = plain, .escaped = escaped, .other = other };
}

fn longEscapedCaseLength(case_index: usize) usize {
    const lengths = [_]usize{ 255, 256, 257, 258, 263, 311, 511, 1024, 4096, 8192 };
    return lengths[case_index];
}

fn longEscapedCaseIndex(case_index: usize, len: usize) usize {
    return switch (case_index) {
        0 => 0,
        1 => len - 1,
        2 => len / 2,
        3 => 1,
        4 => len - 2,
        5 => 127,
        6 => 255,
        7 => 512,
        8 => 2048,
        else => len - 1,
    };
}

test "SemanticEditor moves ten long escaped decoded aliases with the same SymbolId" {
    const Parser = @import("../parser/parser.zig").Parser;
    const SemanticAnalyzer = @import("analyzer.zig").SemanticAnalyzer;
    var failures: usize = 0;
    for (0..10) |case_index| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        const len = longEscapedCaseLength(case_index);
        const identifier = try makeLongEscapedIdentifier(allocator, len, longEscapedCaseIndex(case_index, len), case_index % 2 == 1);
        const source = try std.fmt.allocPrint(allocator, "let {s}=1; let {s}=2;", .{ identifier.escaped, identifier.other });
        var scanner = try Scanner.init(allocator, source);
        var parser = Parser.init(allocator, &scanner);
        parser.configureFromExtension(".js");
        _ = try parser.parse();
        try std.testing.expectEqual(@as(usize, 0), parser.errors.items.len);
        var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
        try analyzer.analyze();
        try std.testing.expectEqual(@as(usize, 0), analyzer.errors.items.len);
        var editor = try SemanticEditor.init(
            allocator,
            &parser.ast,
            analyzer.symbols.items,
            analyzer.scopes.items,
            analyzer.scope_maps.items,
            analyzer.scope_owner_map,
            analyzer.references.items,
            analyzer.symbol_ids.items,
            analyzer.helper_scope_map,
        );

        var escaped_id: ?SymbolId = null;
        var other_id: ?SymbolId = null;
        for (parser.ast.nodes.items, 0..) |node, raw| {
            if (node.tag != .binding_identifier) continue;
            const spelling = parser.ast.getText(node.span);
            if (std.mem.eql(u8, spelling, identifier.escaped)) {
                escaped_id = @fromBackingInt(editor.symbol_ids.items[raw] orelse return error.MissingEscapedBindingId);
            } else if (std.mem.eql(u8, spelling, identifier.other)) {
                other_id = @fromBackingInt(editor.symbol_ids.items[raw] orelse return error.MissingOtherBindingId);
            }
        }
        const moved = escaped_id orelse return error.MissingEscapedBinding;
        const untouched = other_id orelse return error.MissingOtherBinding;
        if (moved == untouched) failures += 1;
        const old_scope = editor.symbols.items[@backingInt(moved)].scope_id;
        const target_scope = try editor.addScope(old_scope, .none, .function, false);
        if (editor.scope_maps.items[old_scope.toIndex()].get(identifier.plain) != @as(?usize, @backingInt(moved))) failures += 1;
        try editor.moveSymbolToScope(moved, target_scope);
        if (editor.scope_maps.items[old_scope.toIndex()].get(identifier.plain) != null) failures += 1;
        if (editor.scope_maps.items[target_scope.toIndex()].get(identifier.plain) != @as(?usize, @backingInt(moved))) failures += 1;
        if (editor.scope_maps.items[old_scope.toIndex()].get(identifier.other) != @as(?usize, @backingInt(untouched))) failures += 1;
        if (editor.scope_maps.items[target_scope.toIndex()].get(identifier.other) != null) failures += 1;
        if (editor.symbols.items[@backingInt(moved)].scope_id != target_scope) failures += 1;
        _ = try editor.finish();
    }
    try std.testing.expectEqual(@as(usize, 0), failures);
}

test "SemanticEditor does not move a long escaped alias owned by another SymbolId" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const identifier = try makeLongEscapedIdentifier(allocator, 311, 203, true);
    var ast = Ast.init(allocator, "");
    var editor = try SemanticEditor.init(allocator, &ast, &.{}, &.{}, &.{}, .empty, &.{}, &.{}, .empty);
    const root = try editor.addScope(.none, .none, .module, true);
    const source_scope = try editor.addScope(root, .none, .block, false);
    const foreign_scope = try editor.addScope(root, .none, .block, false);
    const target_scope = try editor.addScope(root, .none, .function, false);
    const escaped_name = try ast.addString(identifier.escaped);
    const escaped_binding = try ast.addNode(.{ .tag = .binding_identifier, .span = escaped_name, .data = .{ .string_ref = escaped_name } });
    const moved_id = try editor.declare(escaped_binding, escaped_name, Span.EMPTY, source_scope, .variable_let, 0, 0);
    const foreign_name = try ast.addString("foreign");
    const foreign_binding = try ast.addNode(.{ .tag = .binding_identifier, .span = foreign_name, .data = .{ .string_ref = foreign_name } });
    const foreign_id = try editor.declare(foreign_binding, foreign_name, Span.EMPTY, foreign_scope, .variable_let, 1, 0);
    try editor.scope_maps.items[source_scope.toIndex()].put(allocator, identifier.plain, @backingInt(foreign_id));

    try editor.moveSymbolToScope(moved_id, target_scope);

    try std.testing.expectEqual(@as(?usize, @backingInt(foreign_id)), editor.scope_maps.items[source_scope.toIndex()].get(identifier.plain));
    try std.testing.expectEqual(@as(?usize, null), editor.scope_maps.items[target_scope.toIndex()].get(identifier.plain));
    try std.testing.expectEqual(@as(?usize, @backingInt(moved_id)), editor.scope_maps.items[target_scope.toIndex()].get(identifier.escaped));
}

test "relocateSymbolAs transfers ten long escaped decoded aliases with the same SymbolId" {
    var failures: usize = 0;
    for (0..10) |case_index| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        const len = longEscapedCaseLength(case_index);
        const identifier = try makeLongEscapedIdentifier(allocator, len, longEscapedCaseIndex(case_index, len), case_index % 2 == 1);
        var ast = Ast.init(allocator, "");
        var editor = try SemanticEditor.init(allocator, &ast, &.{}, &.{}, &.{}, .empty, &.{}, &.{}, .empty);
        const root = try editor.addScope(.none, .none, .module, true);
        const source_scope = try editor.addScope(root, .none, .block, false);
        const target_scope = try editor.addScope(root, .none, .function, false);
        const source_name = try ast.addString(identifier.escaped);
        const source_binding = try ast.addNode(.{ .tag = .binding_identifier, .span = source_name, .data = .{ .string_ref = source_name } });
        const id = try editor.declare(source_binding, source_name, Span.EMPTY, source_scope, .variable_let, 0, 0);
        try editor.scope_maps.items[source_scope.toIndex()].put(allocator, identifier.plain, @backingInt(id));
        const output_name = try ast.addString(identifier.escaped);
        const output_binding = try ast.addNode(.{ .tag = .binding_identifier, .span = output_name, .data = .{ .string_ref = output_name } });

        try editor.relocateSymbolAs(id, target_scope, output_binding);

        if (editor.scope_maps.items[source_scope.toIndex()].get(identifier.escaped) != null) failures += 1;
        if (editor.scope_maps.items[source_scope.toIndex()].get(identifier.plain) != null) failures += 1;
        if (editor.scope_maps.items[target_scope.toIndex()].get(identifier.escaped) != @as(?usize, @backingInt(id))) failures += 1;
        if (editor.scope_maps.items[target_scope.toIndex()].get(identifier.plain) != @as(?usize, @backingInt(id))) failures += 1;
        if (editor.symbols.items[@backingInt(id)].scope_id != target_scope) failures += 1;
        _ = try editor.finish();
    }
    try std.testing.expectEqual(@as(usize, 0), failures);
}

test "parameter rename removes ten long escaped decoded aliases with the same SymbolId" {
    var failures: usize = 0;
    for (0..10) |case_index| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        const len = longEscapedCaseLength(case_index);
        const identifier = try makeLongEscapedIdentifier(allocator, len, longEscapedCaseIndex(case_index, len), case_index % 2 == 1);
        var ast = Ast.init(allocator, "");
        var editor = try SemanticEditor.init(allocator, &ast, &.{}, &.{}, &.{}, .empty, &.{}, &.{}, .empty);
        const root = try editor.addScope(.none, .none, .module, true);
        const function_scope = try editor.addScope(root, .none, .function, false);
        const name = try ast.addString(identifier.escaped);
        const binding = try ast.addNode(.{ .tag = .binding_identifier, .span = name, .data = .{ .string_ref = name } });
        const id = try editor.declare(binding, name, Span.EMPTY, function_scope, .parameter, 0, 0);
        try editor.scope_maps.items[function_scope.toIndex()].put(allocator, identifier.plain, @backingInt(id));
        const output_name = try std.fmt.allocPrint(allocator, "parameter{d}", .{case_index});

        try editor.renameParameterEnvironmentBinding(id, output_name);

        if (editor.scope_maps.items[function_scope.toIndex()].get(identifier.escaped) != null) failures += 1;
        if (editor.scope_maps.items[function_scope.toIndex()].get(identifier.plain) != null) failures += 1;
        if (editor.scope_maps.items[function_scope.toIndex()].get(output_name) != @as(?usize, @backingInt(id))) failures += 1;
        if (!std.mem.eql(u8, editor.symbols.items[@backingInt(id)].synthetic_name, output_name)) failures += 1;
        _ = try editor.finish();
    }
    try std.testing.expectEqual(@as(usize, 0), failures);
}

test "dead const removal clears ten long escaped decoded aliases with the same SymbolId" {
    const Parser = @import("../parser/parser.zig").Parser;
    const SemanticAnalyzer = @import("analyzer.zig").SemanticAnalyzer;
    var failures: usize = 0;
    for (0..10) |case_index| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        const len = longEscapedCaseLength(case_index);
        const identifier = try makeLongEscapedIdentifier(allocator, len, longEscapedCaseIndex(case_index, len), case_index % 2 == 1);
        const source = try std.fmt.allocPrint(allocator, "const {s}=1;", .{identifier.escaped});
        var scanner = try Scanner.init(allocator, source);
        var parser = Parser.init(allocator, &scanner);
        parser.configureFromExtension(".js");
        parser.is_module = true;
        const root = try parser.parse();
        var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
        analyzer.is_module = true;
        analyzer.enable_stmt_info = true;
        analyzer.enable_exact_declaration_anchors = true;
        try analyzer.analyze();
        var editor = try SemanticEditor.init(
            allocator,
            &parser.ast,
            analyzer.symbols.items,
            analyzer.scopes.items,
            analyzer.scope_maps.items,
            analyzer.scope_owner_map,
            analyzer.references.items,
            analyzer.symbol_ids.items,
            analyzer.helper_scope_map,
        );
        const binding = for (parser.ast.nodes.items, 0..) |node, raw| {
            if (node.tag == .binding_identifier and std.mem.eql(u8, parser.ast.getText(node.span), identifier.escaped))
                break @as(NodeIndex, @fromBackingInt(@intCast(raw)));
        } else return error.MissingLongEscapedBinding;
        const symbol_raw = editor.symbol_ids.items[@backingInt(binding)] orelse return error.MissingLongEscapedBindingId;
        const id: SymbolId = @fromBackingInt(symbol_raw);
        const scope = editor.symbols.items[symbol_raw].scope_id;
        if (editor.scope_maps.items[scope.toIndex()].get(identifier.plain) != @as(?usize, symbol_raw)) failures += 1;
        parser.ast.nodes.items[@backingInt(root)].data.list.len = 0;
        var reachable = try std.DynamicBitSet.initEmpty(allocator, parser.ast.nodes.items.len);

        const removed = try editor.removeUnreachableLocalConstDeclaration(binding, &reachable);

        if (removed != id) failures += 1;
        if (editor.scope_maps.items[scope.toIndex()].get(identifier.escaped) != null) failures += 1;
        if (editor.scope_maps.items[scope.toIndex()].get(identifier.plain) != null) failures += 1;
        if (editor.symbol_ids.items[@backingInt(binding)] != null) failures += 1;
        if (editor.scopes.items[scope.toIndex()].symbol_count != 0) failures += 1;
    }
    try std.testing.expectEqual(@as(usize, 0), failures);
}

test "splitBindingIdentity reuses a same-scope var for ten long escaped spellings" {
    var failures: usize = 0;
    for (0..10) |case_index| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        const len = longEscapedCaseLength(case_index);
        const identifier = try makeLongEscapedIdentifier(allocator, len, longEscapedCaseIndex(case_index, len), case_index % 2 == 1);
        var ast = Ast.init(allocator, "");
        var editor = try SemanticEditor.init(allocator, &ast, &.{}, &.{}, &.{}, .empty, &.{}, &.{}, .empty);
        const root = try editor.addScope(.none, .none, .module, true);
        const function_scope = try editor.addScope(root, .none, .function, false);
        const block_scope = try editor.addScope(function_scope, .none, .block, false);
        const name = try ast.addString(identifier.plain);
        const existing_binding = try ast.addNode(.{ .tag = .binding_identifier, .span = name, .data = .{ .string_ref = name } });
        const other_name = try ast.addString(identifier.other);
        const other_binding = try ast.addNode(.{ .tag = .binding_identifier, .span = other_name, .data = .{ .string_ref = other_name } });
        const source_name = try ast.addString("source");
        const source_binding = try ast.addNode(.{ .tag = .binding_identifier, .span = source_name, .data = .{ .string_ref = source_name } });
        const output_name = try ast.addString(identifier.escaped);
        const output_binding = try ast.addNode(.{ .tag = .binding_identifier, .span = output_name, .data = .{ .string_ref = output_name } });
        const existing_id = try editor.declare(existing_binding, name, Span.EMPTY, function_scope, .variable_var, 0, 0);
        const other_id = try editor.declare(other_binding, other_name, Span.EMPTY, function_scope, .variable_var, 1, 0);
        const source_id = try editor.declare(source_binding, source_name, Span.EMPTY, block_scope, .variable_const, 1, 0);

        const split_id = try editor.splitBindingIdentity(output_binding, source_id, block_scope, .variable_var, Span.EMPTY);

        if (existing_id != split_id) failures += 1;
        if (editor.symbol_ids.items[@backingInt(output_binding)] != @as(?u32, @backingInt(existing_id))) failures += 1;
        if (editor.scope_maps.items[function_scope.toIndex()].get(identifier.plain) != @as(?usize, @backingInt(existing_id))) failures += 1;
        if (editor.scope_maps.items[function_scope.toIndex()].get(identifier.other) != @as(?usize, @backingInt(other_id))) failures += 1;
        if (editor.scope_maps.items[function_scope.toIndex()].get(identifier.escaped) != null) failures += 1;
        if (split_id == other_id) failures += 1;
        if (editor.symbols.items.len != 3) failures += 1;
    }
    try std.testing.expectEqual(@as(usize, 0), failures);
}

test "splitBindingIdentity reuses a same-scope var declaration" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var ast = Ast.init(allocator, "");
    defer ast.deinit();
    var editor = try SemanticEditor.init(allocator, &ast, &.{}, &.{}, &.{}, .empty, &.{}, &.{}, .empty);
    defer editor.deinit();
    const root = try editor.addScope(.none, .none, .module, true);
    const function_scope = try editor.addScope(root, .none, .function, false);
    const block_scope = try editor.addScope(function_scope, .none, .block, false);
    const name = try ast.addString("_d");
    const existing_binding = try ast.addNode(.{ .tag = .binding_identifier, .span = name, .data = .{ .string_ref = name } });
    const source_binding = try ast.addNode(.{ .tag = .binding_identifier, .span = name, .data = .{ .string_ref = name } });
    const output_binding = try ast.addNode(.{ .tag = .binding_identifier, .span = name, .data = .{ .string_ref = name } });
    const existing_id = try editor.declare(existing_binding, name, Span.EMPTY, function_scope, .variable_var, 0, 0);
    const source_id = try editor.declare(source_binding, name, Span.EMPTY, block_scope, .variable_const, 1, 0);

    const split_id = try editor.splitBindingIdentity(output_binding, source_id, block_scope, .variable_var, Span.EMPTY);

    try std.testing.expectEqual(existing_id, split_id);
    try std.testing.expectEqual(@as(?u32, @backingInt(existing_id)), editor.symbol_ids.items[@backingInt(output_binding)]);
    try std.testing.expectEqual(@as(?usize, @backingInt(existing_id)), editor.scope_maps.items[function_scope.toIndex()].get("_d"));
    try std.testing.expectEqual(function_scope, editor.symbols.items[@backingInt(existing_id)].scope_id);
    _ = try editor.finish();
}

test "relocateSymbolAs accepts a source-backed emitted binding name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var ast = Ast.init(allocator, "_err3$4");
    defer ast.deinit();
    var editor = try SemanticEditor.init(allocator, &ast, &.{}, &.{}, &.{}, .empty, &.{}, &.{}, .empty);
    defer editor.deinit();
    const root = try editor.addScope(.none, .none, .module, true);
    const source_scope = try editor.addScope(root, .none, .block, false);
    const storage_scope = try editor.addScope(root, .none, .function, false);
    const source_name = try ast.addString("_err3");
    const source_binding = try ast.addNode(.{
        .tag = .binding_identifier,
        .span = source_name,
        .data = .{ .string_ref = source_name },
    });
    const id = try editor.declare(source_binding, source_name, Span.EMPTY, source_scope, .variable_let, 0, 0);
    const output_name: Span = .{ .start = 0, .end = 7 };
    const output_binding = try ast.addNode(.{
        .tag = .binding_identifier,
        .span = output_name,
        .data = .{ .string_ref = output_name },
    });

    try editor.relocateSymbolAs(id, storage_scope, output_binding);

    try std.testing.expectEqual(storage_scope, editor.symbols.items[@backingInt(id)].scope_id);
    try std.testing.expectEqual(@as(?usize, @backingInt(id)), editor.scope_maps.items[storage_scope.toIndex()].get("_err3$4"));
    try std.testing.expectEqual(@as(?usize, null), editor.scope_maps.items[source_scope.toIndex()].get("_err3"));
    try std.testing.expectEqual(@as(?u32, @backingInt(id)), editor.symbol_ids.items[@backingInt(output_binding)]);
    try std.testing.expectEqualStrings("_err3$4", editor.symbols.items[@backingInt(id)].nameText(ast.source));
    _ = try editor.finish();
}

test "existing facade symbols receive one declaration row when lowered to bindings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var ast = Ast.init(allocator, "");
    defer ast.deinit();
    var editor = try SemanticEditor.init(allocator, &ast, &.{}, &.{}, &.{}, .empty, &.{}, &.{}, .empty);
    defer editor.deinit();

    const root = try editor.addScope(.none, .none, .module, true);
    const name = try ast.addString("_default");
    const binding = try ast.addNode(.{ .tag = .binding_identifier, .span = name, .data = .{ .string_ref = name } });
    const id = try editor.declare(binding, name, Span.EMPTY, root, .variable_const, Reference.NO_STMT, Reference.NO_STMT);
    editor.references.clearRetainingCapacity(); // analyzer facade without stmt-info declaration evidence

    try editor.ensureDeclaration(id, root);
    try editor.ensureDeclaration(id, root);
    try std.testing.expectEqual(@as(usize, 1), editor.references.items.len);
    try std.testing.expect(editor.references.items[0].node_index.isNone());
    try std.testing.expectEqual(id, editor.references.items[0].symbol_id);
    try std.testing.expect(editor.references.items[0].flags.declare);
    try std.testing.expectEqual(@as(u32, 0), editor.symbols.items[@backingInt(id)].reference_count);
}

test "same provisional name in separate scopes never shares a symbol" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var ast = Ast.init(allocator, "");
    defer ast.deinit();
    var editor = try SemanticEditor.init(allocator, &ast, &.{}, &.{}, &.{}, .empty, &.{}, &.{}, .empty);
    defer editor.deinit();
    const root = try editor.addScope(.none, .none, .module, true);
    const left = try editor.addScope(root, .none, .function, false);
    const right = try editor.addScope(root, .none, .function, false);
    const name = try ast.addString("_this");
    const left_binding = try ast.addNode(.{ .tag = .binding_identifier, .span = name, .data = .{ .string_ref = name } });
    const right_binding = try ast.addNode(.{ .tag = .binding_identifier, .span = name, .data = .{ .string_ref = name } });
    const left_ref = try ast.addNode(.{ .tag = .identifier_reference, .span = name, .data = .{ .string_ref = name } });
    const right_ref = try ast.addNode(.{ .tag = .identifier_reference, .span = name, .data = .{ .string_ref = name } });
    const left_id = try editor.declare(left_binding, name, Span.EMPTY, left, .variable_var, 0, 0);
    const right_id = try editor.declare(right_binding, name, Span.EMPTY, right, .variable_var, 1, 0);
    try std.testing.expect(left_id != right_id);
    try editor.addReference(left_ref, left_id, left, .{ .read = true }, 0, 0);
    try editor.addReference(right_ref, right_id, right, .{ .read = true }, 1, 0);
    const wrong_ref = try ast.addNode(.{ .tag = .identifier_reference, .span = name, .data = .{ .string_ref = name } });
    try std.testing.expectError(error.InvalidScope, editor.addReference(wrong_ref, left_id, right, .{ .read = true }, 1, 0));
    try std.testing.expectError(error.InvalidScope, editor.moveReference(left_ref, right, 1, 0));
    try std.testing.expectEqual(@as(?u32, @backingInt(left_id)), editor.symbol_ids.items[@backingInt(left_ref)]);
    try std.testing.expectEqual(@as(?u32, @backingInt(right_id)), editor.symbol_ids.items[@backingInt(right_ref)]);
    try std.testing.expectError(error.DuplicateBinding, editor.declare(
        try ast.addNode(.{ .tag = .binding_identifier, .span = name, .data = .{ .string_ref = name } }),
        name,
        Span.EMPTY,
        left,
        .variable_var,
        0,
        1,
    ));
}

test "relocate reference crosses sibling scopes with one final visibility check" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var ast = Ast.init(allocator, "");
    var editor = try SemanticEditor.init(allocator, &ast, &.{}, &.{}, &.{}, .empty, &.{}, &.{}, .empty);

    const root = try editor.addScope(.none, .none, .module, true);
    const header = try editor.addScope(root, .none, .block, false);
    const generated_fn = try editor.addScope(root, .none, .function, false);
    const name = try ast.addString("index");
    const header_binding = try ast.addNode(.{ .tag = .binding_identifier, .span = name, .data = .{ .string_ref = name } });
    const param_binding = try ast.addNode(.{ .tag = .binding_identifier, .span = name, .data = .{ .string_ref = name } });
    const ref = try ast.addNode(.{ .tag = .assignment_target_identifier, .span = name, .data = .{ .string_ref = name } });
    const header_id = try editor.declare(header_binding, name, Span.EMPTY, header, .variable_let, 1, 0);
    const param_id = try editor.declare(param_binding, name, Span.EMPTY, generated_fn, .parameter, 1, 0);
    try editor.addReference(ref, header_id, header, .{ .read = true, .write = true }, 2, 3);

    try std.testing.expectError(error.InvalidScope, editor.moveReference(ref, generated_fn, 4, 5));
    try std.testing.expectError(error.InvalidScope, editor.rebindReference(ref, param_id));
    try std.testing.expectEqual(@as(u32, 1), editor.symbols.items[@backingInt(header_id)].reference_count);
    try std.testing.expectEqual(@as(u32, 1), editor.symbols.items[@backingInt(header_id)].write_count);
    try editor.relocateReference(ref, generated_fn, param_id, 4, 5);

    const ref_i = editor.reference_index.get(@backingInt(ref)).?;
    const relocated = editor.references.items[ref_i];
    try std.testing.expectEqual(generated_fn, relocated.scope_id);
    try std.testing.expectEqual(param_id, relocated.symbol_id);
    try std.testing.expectEqual(@as(u32, 4), relocated.stmt_idx);
    try std.testing.expectEqual(@as(u32, 5), relocated.scope_stmt_idx);
    try std.testing.expect(relocated.flags.read and relocated.flags.write);
    try std.testing.expectEqual(@as(?u32, @backingInt(param_id)), editor.symbol_ids.items[@backingInt(ref)]);
    try std.testing.expectEqual(@as(u32, 0), editor.symbols.items[@backingInt(header_id)].reference_count);
    try std.testing.expectEqual(@as(u32, 0), editor.symbols.items[@backingInt(header_id)].write_count);
    try std.testing.expectEqual(@as(u32, 1), editor.symbols.items[@backingInt(param_id)].reference_count);
    try std.testing.expectEqual(@as(u32, 1), editor.symbols.items[@backingInt(param_id)].write_count);

    try editor.relocateReference(ref, generated_fn, param_id, 4, 5);
    try std.testing.expectEqualDeep(relocated, editor.references.items[ref_i]);
    try std.testing.expectEqual(@as(u32, 1), editor.symbols.items[@backingInt(param_id)].reference_count);
    try std.testing.expectEqual(@as(u32, 1), editor.symbols.items[@backingInt(param_id)].write_count);
    try editor.removeReference(ref);
    try std.testing.expectEqual(@as(u32, 0), editor.symbols.items[@backingInt(param_id)].reference_count);
    try std.testing.expectEqual(@as(u32, 0), editor.symbols.items[@backingInt(param_id)].write_count);
    try std.testing.expectEqual(@as(?u32, null), editor.symbol_ids.items[@backingInt(ref)]);
    try std.testing.expect(editor.reference_index.get(@backingInt(ref)) == null);
}

test "relocate reference after reparenting restores final visibility" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var ast = Ast.init(allocator, "");
    var editor = try SemanticEditor.init(allocator, &ast, &.{}, &.{}, &.{}, .empty, &.{}, &.{}, .empty);

    const root = try editor.addScope(.none, .none, .module, true);
    const header = try editor.addScope(root, .none, .block, false);
    const body = try editor.addScope(header, .none, .block, false);
    const generated_fn = try editor.addScope(root, .none, .function, false);
    const name = try ast.addString("index");
    const binding = try ast.addNode(.{ .tag = .binding_identifier, .span = name, .data = .{ .string_ref = name } });
    const param = try ast.addNode(.{ .tag = .binding_identifier, .span = name, .data = .{ .string_ref = name } });
    const ref = try ast.addNode(.{ .tag = .identifier_reference, .span = name, .data = .{ .string_ref = name } });
    const header_id = try editor.declare(binding, name, Span.EMPTY, header, .variable_let, 0, 0);
    const param_id = try editor.declare(param, name, Span.EMPTY, generated_fn, .parameter, 0, 0);
    try editor.addReference(ref, header_id, body, .{ .read = true }, 1, 1);

    try editor.reparentScope(body, generated_fn);
    try std.testing.expectError(error.InvalidScope, editor.finish());
    try editor.relocateReference(ref, body, param_id, Reference.NO_STMT, Reference.NO_STMT);
    const result = try editor.finish();
    try std.testing.expectEqual(@as(?u32, @backingInt(param_id)), result.symbol_ids[@backingInt(ref)]);
    try std.testing.expectEqual(@as(u32, 0), result.symbols.items[@backingInt(header_id)].reference_count);
    try std.testing.expectEqual(@as(u32, 1), result.symbols.items[@backingInt(param_id)].reference_count);
}

test "failed relocation leaves references symbols counts and index intact" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var ast = Ast.init(allocator, "");
    var editor = try SemanticEditor.init(allocator, &ast, &.{}, &.{}, &.{}, .empty, &.{}, &.{}, .empty);

    const root = try editor.addScope(.none, .none, .module, true);
    const left = try editor.addScope(root, .none, .block, false);
    const right = try editor.addScope(root, .none, .function, false);
    const other = try editor.addScope(root, .none, .function, false);
    const name = try ast.addString("value");
    const binding = try ast.addNode(.{ .tag = .binding_identifier, .span = name, .data = .{ .string_ref = name } });
    const right_binding = try ast.addNode(.{ .tag = .binding_identifier, .span = name, .data = .{ .string_ref = name } });
    const other_binding = try ast.addNode(.{ .tag = .binding_identifier, .span = name, .data = .{ .string_ref = name } });
    const ref = try ast.addNode(.{ .tag = .assignment_target_identifier, .span = name, .data = .{ .string_ref = name } });
    const later = try ast.addNode(.{ .tag = .identifier_reference, .span = name, .data = .{ .string_ref = name } });
    const missing = try ast.addNode(.{ .tag = .identifier_reference, .span = name, .data = .{ .string_ref = name } });
    const invalid_node = try ast.addNode(.{ .tag = .null_literal, .span = Span.EMPTY, .data = .{ .none = 0 } });
    const left_id = try editor.declare(binding, name, Span.EMPTY, left, .variable_let, 0, 0);
    const right_id = try editor.declare(right_binding, name, Span.EMPTY, right, .parameter, 0, 0);
    const other_id = try editor.declare(other_binding, name, Span.EMPTY, other, .parameter, 0, 0);
    try editor.addReference(ref, left_id, left, .{ .read = true, .write = true }, 1, 2);
    try editor.addReference(later, left_id, left, .{ .read = true }, 3, 4);
    try editor.ensureReferenceIndex();
    const old_index = editor.reference_index.get(@backingInt(ref)).?;
    const before = editor.references.items[old_index];

    try std.testing.expectError(error.InvalidScope, editor.relocateReference(ref, .none, right_id, 8, 9));
    try std.testing.expectError(error.InvalidSymbol, editor.relocateReference(ref, right, .none, 8, 9));
    try std.testing.expectError(error.InvalidScope, editor.relocateReference(ref, right, other_id, 8, 9));
    try std.testing.expectError(error.InvalidNode, editor.relocateReference(binding, right, right_id, 8, 9));
    try std.testing.expectError(error.InvalidNode, editor.relocateReference(invalid_node, right, right_id, 8, 9));
    try std.testing.expectError(error.ReferenceNotFound, editor.relocateReference(missing, right, right_id, 8, 9));
    try std.testing.expectEqualDeep(before, editor.references.items[old_index]);
    try std.testing.expectEqual(@as(?u32, @backingInt(left_id)), editor.symbol_ids.items[@backingInt(ref)]);
    try std.testing.expectEqual(@as(u32, 2), editor.symbols.items[@backingInt(left_id)].reference_count);
    try std.testing.expectEqual(@as(u32, 1), editor.symbols.items[@backingInt(left_id)].write_count);
    try std.testing.expectEqual(@as(u32, 0), editor.symbols.items[@backingInt(right_id)].reference_count);
    try std.testing.expectEqual(@as(u32, 0), editor.symbols.items[@backingInt(other_id)].reference_count);
    try std.testing.expectEqual(old_index, editor.reference_index.get(@backingInt(ref)).?);

    editor.references.items[old_index].flags = .{ .declare = true };
    try std.testing.expectError(error.InvalidNode, editor.relocateReference(ref, right, right_id, 8, 9));
    editor.references.items[old_index].flags = .{};
    try std.testing.expectError(error.InvalidNode, editor.relocateReference(ref, right, right_id, 8, 9));
    editor.references.items[old_index].flags = before.flags;
    editor.references.items[old_index].scope_id = .none;
    try std.testing.expectError(error.InvalidScope, editor.relocateReference(ref, right, right_id, 8, 9));
    editor.references.items[old_index].scope_id = before.scope_id;
    editor.symbol_ids.items[@backingInt(ref)] = @backingInt(other_id);
    try std.testing.expectError(error.InvalidSymbol, editor.relocateReference(ref, right, right_id, 8, 9));
    editor.symbol_ids.items[@backingInt(ref)] = @backingInt(left_id);
    editor.symbols.items[@backingInt(right_id)].write_count = std.math.maxInt(u32);
    try std.testing.expectError(error.InvalidSymbol, editor.relocateReference(ref, right, right_id, 8, 9));
    editor.symbols.items[@backingInt(right_id)].write_count = 0;
    try std.testing.expectEqualDeep(before, editor.references.items[old_index]);
    try std.testing.expectEqual(@as(u32, 2), editor.symbols.items[@backingInt(left_id)].reference_count);

    try editor.removeReference(ref);
    const later_i = editor.reference_index.get(@backingInt(later)).?;
    try std.testing.expectEqual(later, editor.references.items[later_i].node_index);
    try editor.relocateReference(later, right, right_id, 10, 11);
    try std.testing.expectEqual(@as(?u32, @backingInt(right_id)), editor.symbol_ids.items[@backingInt(later)]);
    try std.testing.expectEqual(@as(u32, 0), editor.symbols.items[@backingInt(left_id)].reference_count);
    try std.testing.expectEqual(@as(u32, 1), editor.symbols.items[@backingInt(right_id)].reference_count);
}

test "relocate type references without adding value counts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var ast = Ast.init(allocator, "");
    var editor = try SemanticEditor.init(allocator, &ast, &.{}, &.{}, &.{}, .empty, &.{}, &.{}, .empty);

    const root = try editor.addScope(.none, .none, .module, true);
    const left = try editor.addScope(root, .none, .block, false);
    const right = try editor.addScope(root, .none, .function, false);
    const name = try ast.addString("TypeName");
    const left_binding = try ast.addNode(.{ .tag = .binding_identifier, .span = name, .data = .{ .string_ref = name } });
    const right_binding = try ast.addNode(.{ .tag = .binding_identifier, .span = name, .data = .{ .string_ref = name } });
    const type_ref = try ast.addNode(.{ .tag = .identifier_reference, .span = name, .data = .{ .string_ref = name } });
    const query_ref = try ast.addNode(.{ .tag = .identifier_reference, .span = name, .data = .{ .string_ref = name } });
    const left_id = try editor.declare(left_binding, name, Span.EMPTY, left, .variable_let, 0, 0);
    const right_id = try editor.declare(right_binding, name, Span.EMPTY, right, .parameter, 0, 0);
    const type_flags: ReferenceFlags = .{ .read = true, .type_context = true };
    const query_flags: ReferenceFlags = .{ .read = true, .value_as_type = true };
    try editor.addReference(type_ref, left_id, left, type_flags, 1, 2);
    try editor.addReference(query_ref, left_id, left, query_flags, 3, 4);

    try std.testing.expectEqual(@as(u32, 0), editor.symbols.items[@backingInt(left_id)].reference_count);
    try std.testing.expectEqual(@as(u32, 0), editor.symbols.items[@backingInt(left_id)].write_count);
    try editor.relocateReference(type_ref, right, right_id, 5, 6);
    try editor.relocateReference(query_ref, right, right_id, 7, 8);

    const relocated_type = editor.references.items[editor.reference_index.get(@backingInt(type_ref)).?];
    const relocated_query = editor.references.items[editor.reference_index.get(@backingInt(query_ref)).?];
    try std.testing.expectEqual(right, relocated_type.scope_id);
    try std.testing.expectEqual(right_id, relocated_type.symbol_id);
    try std.testing.expectEqual(@as(u32, 5), relocated_type.stmt_idx);
    try std.testing.expectEqual(@as(u32, 6), relocated_type.scope_stmt_idx);
    try std.testing.expectEqualDeep(type_flags, relocated_type.flags);
    try std.testing.expect(!relocated_type.isValueUse());
    try std.testing.expectEqual(right, relocated_query.scope_id);
    try std.testing.expectEqual(right_id, relocated_query.symbol_id);
    try std.testing.expectEqual(@as(u32, 7), relocated_query.stmt_idx);
    try std.testing.expectEqual(@as(u32, 8), relocated_query.scope_stmt_idx);
    try std.testing.expectEqualDeep(query_flags, relocated_query.flags);
    try std.testing.expect(!relocated_query.isValueUse());
    try std.testing.expectEqual(@as(?u32, @backingInt(right_id)), editor.symbol_ids.items[@backingInt(type_ref)]);
    try std.testing.expectEqual(@as(?u32, @backingInt(right_id)), editor.symbol_ids.items[@backingInt(query_ref)]);
    try std.testing.expectEqual(@as(u32, 0), editor.symbols.items[@backingInt(left_id)].reference_count);
    try std.testing.expectEqual(@as(u32, 0), editor.symbols.items[@backingInt(left_id)].write_count);
    try std.testing.expectEqual(@as(u32, 0), editor.symbols.items[@backingInt(right_id)].reference_count);
    try std.testing.expectEqual(@as(u32, 0), editor.symbols.items[@backingInt(right_id)].write_count);
}

test "helper import remains isolated from a user binding with the same name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var ast = Ast.init(allocator, "");
    defer ast.deinit();
    var editor = try SemanticEditor.init(allocator, &ast, &.{}, &.{}, &.{}, .empty, &.{}, &.{}, .empty);
    defer editor.deinit();
    const root = try editor.addScope(.none, .none, .module, true);
    const name = try ast.addString("__extends");
    const user_binding = try ast.addNode(.{ .tag = .binding_identifier, .span = name, .data = .{ .string_ref = name } });
    const helper_local = try ast.addNode(.{ .tag = .identifier_reference, .span = name, .data = .{ .string_ref = name } });
    const helper_call = try ast.addNode(.{ .tag = .identifier_reference, .span = name, .data = .{ .string_ref = name } });
    const user_id = try editor.declare(user_binding, name, Span.EMPTY, root, .variable_const, 0, 0);
    const helper_id = try editor.declareHelperImport(helper_local, name, Span.EMPTY, root);
    try std.testing.expect(user_id != helper_id);
    try std.testing.expectEqual(@as(?usize, @backingInt(user_id)), editor.scope_maps.items[root.toIndex()].get("__extends"));
    try std.testing.expectEqual(@as(?usize, @backingInt(helper_id)), editor.helper_scope_map.get("__extends"));
    try editor.addReference(helper_call, helper_id, root, .{ .read = true }, 0, 0);
    try std.testing.expectEqual(@as(u32, 0), editor.symbols.items[@backingInt(user_id)].reference_count);
    try std.testing.expectEqual(@as(u32, 1), editor.symbols.items[@backingInt(helper_id)].reference_count);
    const result = try editor.finish();
    try std.testing.expectEqual(@as(?usize, @backingInt(helper_id)), result.helper_scope_map.get("__extends"));
}

test "reparenting a scope requires captured references to be rebound" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var ast = Ast.init(allocator, "");
    defer ast.deinit();
    var editor = try SemanticEditor.init(allocator, &ast, &.{}, &.{}, &.{}, .empty, &.{}, &.{}, .empty);
    defer editor.deinit();
    const root = try editor.addScope(.none, .none, .global, false);
    const outer = try editor.addScope(root, .none, .block, false);
    const generated_fn = try editor.addScope(root, .none, .function, true);
    const body = try editor.addScope(outer, .none, .block, false);
    const nested = try editor.addScope(body, .none, .function, false);
    const name = try ast.addString("captured");
    const outer_binding = try ast.addNode(.{ .tag = .binding_identifier, .span = name, .data = .{ .string_ref = name } });
    const param_binding = try ast.addNode(.{ .tag = .binding_identifier, .span = name, .data = .{ .string_ref = name } });
    const ref = try ast.addNode(.{ .tag = .identifier_reference, .span = name, .data = .{ .string_ref = name } });
    const outer_id = try editor.declare(outer_binding, name, Span.EMPTY, outer, .variable_let, 0, 0);
    const param_id = try editor.declare(param_binding, name, Span.EMPTY, generated_fn, .parameter, 0, 0);
    try editor.addReference(ref, outer_id, nested, .{ .read = true }, 0, 0);
    editor.scopes.items[body.toIndex()].subtree_has_direct_eval = true;
    editor.scopes.items[body.toIndex()].subtree_has_with = true;
    editor.scopes.items[outer.toIndex()].subtree_has_direct_eval = true;
    editor.scopes.items[outer.toIndex()].subtree_has_with = true;
    try editor.reparentScope(body, generated_fn);
    try std.testing.expectEqual(generated_fn, editor.scopes.items[body.toIndex()].parent);
    try std.testing.expect(editor.scopes.items[body.toIndex()].is_strict);
    try std.testing.expect(editor.scopes.items[nested.toIndex()].is_strict);
    try std.testing.expect(editor.scopes.items[generated_fn.toIndex()].blocksMangling());
    try std.testing.expect(editor.scopes.items[outer.toIndex()].blocksMangling());
    try std.testing.expectError(error.InvalidScope, editor.reparentScope(generated_fn, nested));
    try std.testing.expectError(error.InvalidScope, editor.reparentScope(root, generated_fn));
    try std.testing.expectError(error.InvalidScope, editor.finish());
    try editor.rebindReference(ref, param_id);
    try std.testing.expectEqual(@as(u32, 0), editor.symbols.items[@backingInt(outer_id)].reference_count);
    try std.testing.expectEqual(@as(u32, 1), editor.symbols.items[@backingInt(param_id)].reference_count);
    const result = try editor.finish();
    try std.testing.expectEqual(@as(?u32, @backingInt(param_id)), result.symbol_ids[@backingInt(ref)]);
}

test "JSX identifier references can be rebound and relocated" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var ast = Ast.init(allocator, "");
    defer ast.deinit();
    var editor = try SemanticEditor.init(allocator, &ast, &.{}, &.{}, &.{}, .empty, &.{}, &.{}, .empty);
    defer editor.deinit();

    const root = try editor.addScope(.none, .none, .module, true);
    const child = try editor.addScope(root, .none, .function, false);
    const name = try ast.addString("Component");
    const renamed_name = try ast.addString("RenamedComponent");
    const first_binding = try ast.addNode(.{ .tag = .binding_identifier, .span = name, .data = .{ .string_ref = name } });
    const second_binding = try ast.addNode(.{ .tag = .binding_identifier, .span = renamed_name, .data = .{ .string_ref = renamed_name } });
    const jsx_ref = try ast.addNode(.{ .tag = .jsx_identifier, .span = name, .data = .{ .string_ref = name } });
    const first_id = try editor.declare(first_binding, name, Span.EMPTY, root, .variable_let, 0, 0);
    const second_id = try editor.declare(second_binding, renamed_name, Span.EMPTY, root, .variable_const, 1, 0);
    try editor.addReference(jsx_ref, first_id, root, .{ .read = true }, 2, 0);

    try editor.rebindReference(jsx_ref, second_id);
    try editor.relocateReference(jsx_ref, child, second_id, 3, 1);

    const reference = (try editor.referenceForNode(jsx_ref)).?;
    try std.testing.expectEqual(child, reference.scope_id);
    try std.testing.expectEqual(second_id, reference.symbol_id);
    try std.testing.expectEqual(@as(u32, 0), editor.symbols.items[@backingInt(first_id)].reference_count);
    try std.testing.expectEqual(@as(u32, 1), editor.symbols.items[@backingInt(second_id)].reference_count);
    _ = try editor.finish();
}

test "cloned reference keeps target and write flags without stealing the source" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var ast = Ast.init(allocator, "");
    defer ast.deinit();
    var editor = try SemanticEditor.init(allocator, &ast, &.{}, &.{}, &.{}, .empty, &.{}, &.{}, .empty);
    defer editor.deinit();
    const root = try editor.addScope(.none, .none, .global, false);
    const sibling = try editor.addScope(root, .none, .function, false);
    const inner = try editor.addScope(sibling, .none, .block, false);
    const name = try ast.addString("value");
    const binding = try ast.addNode(.{ .tag = .binding_identifier, .span = name, .data = .{ .string_ref = name } });
    const source = try ast.addNode(.{ .tag = .assignment_target_identifier, .span = name, .data = .{ .string_ref = name } });
    const clone = try ast.addNode(.{ .tag = .assignment_target_identifier, .span = name, .data = .{ .string_ref = name } });
    const wrong_clone = try ast.addNode(.{ .tag = .assignment_target_identifier, .span = name, .data = .{ .string_ref = name } });
    const symbol = try editor.declare(binding, name, Span.EMPTY, sibling, .variable_let, 0, 0);
    try editor.addReference(source, symbol, inner, .{ .read = true, .write = true }, 2, 3);
    editor.symbol_ids.items[try editor.ensureNodeSlot(clone)] = @backingInt(symbol);
    editor.symbol_ids.items[try editor.ensureNodeSlot(wrong_clone)] = 999;
    try editor.cloneReference(source, clone, inner, 4, 5);
    try std.testing.expectEqual(@as(u32, 2), editor.symbols.items[@backingInt(symbol)].reference_count);
    try std.testing.expectEqual(@as(u32, 2), editor.symbols.items[@backingInt(symbol)].write_count);
    try std.testing.expectError(error.AlreadyBound, editor.cloneReference(source, clone, inner, 4, 5));
    try std.testing.expectError(error.AlreadyBound, editor.cloneReferenceAtSameLocation(source, wrong_clone));
    try std.testing.expectError(error.ReferenceNotFound, editor.cloneReference(binding, clone, inner, 4, 5));
    try std.testing.expectError(error.InvalidScope, editor.cloneReference(source, binding, root, 4, 5));
    try editor.removeReference(source);
    try std.testing.expectEqual(@as(u32, 1), editor.symbols.items[@backingInt(symbol)].reference_count);
    try std.testing.expectEqual(@as(u32, 1), editor.symbols.items[@backingInt(symbol)].write_count);
    const later = try ast.addNode(.{ .tag = .assignment_target_identifier, .span = name, .data = .{ .string_ref = name } });
    try editor.cloneReferenceAtSameLocation(clone, later);
    try std.testing.expectEqual(@as(u32, 2), editor.symbols.items[@backingInt(symbol)].reference_count);
    try editor.removeReference(later);
    try std.testing.expectEqual(@as(u32, 1), editor.symbols.items[@backingInt(symbol)].reference_count);
    const result = try editor.finish();
    try std.testing.expectEqual(@as(?u32, null), result.symbol_ids[@backingInt(source)]);
    try std.testing.expectEqual(@as(?u32, @backingInt(symbol)), result.symbol_ids[@backingInt(clone)]);
    try std.testing.expectEqual(@as(u32, 4), result.references[result.references.len - 1].stmt_idx);
    try std.testing.expectEqual(@as(u32, 5), result.references[result.references.len - 1].scope_stmt_idx);
}

test "compound assignment split keeps one write and adds one exact read" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var ast = Ast.init(allocator, "");
    defer ast.deinit();
    var editor = try SemanticEditor.init(allocator, &ast, &.{}, &.{}, &.{}, .empty, &.{}, &.{}, .empty);
    defer editor.deinit();
    const root = try editor.addScope(.none, .none, .global, false);
    const name = try ast.addString("value");
    const binding = try ast.addNode(.{ .tag = .binding_identifier, .span = name, .data = .{ .string_ref = name } });
    const target = try ast.addNode(.{ .tag = .assignment_target_identifier, .span = name, .data = .{ .string_ref = name } });
    const value_read = try ast.addNode(.{ .tag = .identifier_reference, .span = name, .data = .{ .string_ref = name } });
    const symbol = try editor.declare(binding, name, Span.EMPTY, root, .variable_var, 0, 0);
    try editor.addReference(target, symbol, root, .{ .read = true, .write = true }, 1, 2);

    try editor.addCopiedReference(value_read, symbol, root, .{ .read = true }, 1, 2);
    try editor.updateReferenceFlags(target, .{ .write = true });

    const target_ref = (try editor.referenceForNode(target)).?;
    const value_ref = (try editor.referenceForNode(value_read)).?;
    try std.testing.expect(!target_ref.flags.read and target_ref.flags.write);
    try std.testing.expect(value_ref.flags.read and !value_ref.flags.write);
    try std.testing.expectEqual(@as(u32, 2), editor.symbols.items[@backingInt(symbol)].reference_count);
    try std.testing.expectEqual(@as(u32, 1), editor.symbols.items[@backingInt(symbol)].write_count);
    try std.testing.expectError(error.InvalidNode, editor.updateReferenceFlags(target, .{ .declare = true }));
    try std.testing.expectEqual(@as(u32, 2), editor.symbols.items[@backingInt(symbol)].reference_count);
    try std.testing.expectEqual(@as(u32, 1), editor.symbols.items[@backingInt(symbol)].write_count);
}

test "batched reference removal preserves survivor order and updates indices" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var ast = Ast.init(allocator, "");
    defer ast.deinit();
    var editor = try SemanticEditor.init(allocator, &ast, &.{}, &.{}, &.{}, .empty, &.{}, &.{}, .empty);
    defer editor.deinit();

    const root = try editor.addScope(.none, .none, .global, false);
    const a_name = try ast.addString("a");
    const b_name = try ast.addString("b");
    const a_binding = try ast.addNode(.{ .tag = .binding_identifier, .span = a_name, .data = .{ .string_ref = a_name } });
    const b_binding = try ast.addNode(.{ .tag = .binding_identifier, .span = b_name, .data = .{ .string_ref = b_name } });
    const a_symbol = try editor.declare(a_binding, a_name, Span.EMPTY, root, .variable_const, 0, 0);
    const b_symbol = try editor.declare(b_binding, b_name, Span.EMPTY, root, .variable_let, 0, 0);

    const a_first = try ast.addNode(.{ .tag = .identifier_reference, .span = a_name, .data = .{ .string_ref = a_name } });
    const b_write = try ast.addNode(.{ .tag = .assignment_target_identifier, .span = b_name, .data = .{ .string_ref = b_name } });
    const a_second = try ast.addNode(.{ .tag = .identifier_reference, .span = a_name, .data = .{ .string_ref = a_name } });
    const b_read = try ast.addNode(.{ .tag = .identifier_reference, .span = b_name, .data = .{ .string_ref = b_name } });
    try editor.addReference(a_first, a_symbol, root, .{ .read = true }, 1, 0);
    try editor.addReference(b_write, b_symbol, root, .{ .write = true }, 2, 0);
    try editor.addReference(a_second, a_symbol, root, .{ .read = true }, 3, 0);
    try editor.addReference(b_read, b_symbol, root, .{ .read = true }, 4, 0);

    try editor.removeReferences(&.{ a_first, a_second });
    try std.testing.expectEqual(@as(usize, 4), editor.references.items.len);
    try std.testing.expectEqual(@as(u32, 0), editor.symbols.items[@backingInt(a_symbol)].reference_count);
    try std.testing.expectEqual(@as(u32, 2), editor.symbols.items[@backingInt(b_symbol)].reference_count);
    try std.testing.expectEqual(@as(u32, 1), editor.symbols.items[@backingInt(b_symbol)].write_count);
    try std.testing.expectError(error.ReferenceNotFound, editor.removeReferences(&.{a_first}));
    try std.testing.expectError(error.ReferenceNotFound, editor.removeReferences(&.{ b_write, b_write }));

    const first_survivor = (try editor.referenceForNode(b_write)).?;
    const second_survivor = (try editor.referenceForNode(b_read)).?;
    try std.testing.expectEqual(@as(u32, 2), first_survivor.stmt_idx);
    try std.testing.expectEqual(@as(u32, 4), second_survivor.stmt_idx);
    try std.testing.expectEqual(@as(?u32, null), editor.symbol_ids.items[@backingInt(a_first)]);
    try std.testing.expectEqual(@as(?u32, null), editor.symbol_ids.items[@backingInt(a_second)]);

    const result = try editor.finish();
    try std.testing.expectEqual(@as(usize, 4), result.references.len);
    try std.testing.expectEqual(@as(u32, 2), result.references[2].stmt_idx);
    try std.testing.expectEqual(@as(u32, 4), result.references[3].stmt_idx);
}

test "invalid identities and type-only references cannot corrupt liveness" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var ast = Ast.init(allocator, "");
    defer ast.deinit();
    var editor = try SemanticEditor.init(allocator, &ast, &.{}, &.{}, &.{}, .empty, &.{}, &.{}, .empty);
    defer editor.deinit();
    const root = try editor.addScope(.none, .none, .module, true);
    const name = try ast.addString("temp");
    const binding = try ast.addNode(.{ .tag = .binding_identifier, .span = name, .data = .{ .string_ref = name } });
    const type_ref = try ast.addNode(.{ .tag = .identifier_reference, .span = name, .data = .{ .string_ref = name } });
    const write_ref = try ast.addNode(.{ .tag = .assignment_target_identifier, .span = name, .data = .{ .string_ref = name } });
    const id = try editor.declare(binding, name, Span.EMPTY, root, .variable_let, 0, 0);
    try std.testing.expectError(error.InvalidSymbol, editor.addReference(type_ref, .none, root, .{ .read = true }, 0, 0));
    try std.testing.expectError(error.InvalidScope, editor.addReference(type_ref, id, .none, .{ .read = true }, 0, 0));
    try editor.addReference(type_ref, id, root, .{ .read = true, .type_context = true }, 0, 0);
    try std.testing.expectEqual(@as(u32, 0), editor.symbols.items[@backingInt(id)].reference_count);
    try std.testing.expectError(error.AlreadyBound, editor.addReference(type_ref, id, root, .{ .read = true }, 0, 0));
    try editor.addReference(write_ref, id, root, .{ .write = true }, 0, 0);
    try std.testing.expectEqual(@as(u32, 1), editor.symbols.items[@backingInt(id)].write_count);
    try editor.removeReference(write_ref);
    try std.testing.expectEqual(@as(u32, 0), editor.symbols.items[@backingInt(id)].write_count);
    try std.testing.expectError(error.ReferenceNotFound, editor.removeReference(write_ref));
}

test "enum outer binding exact reanchor preserves source var tuples and rejects corrupt selections transactionally" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tree = Ast.init(a, "");
    var editor = try SemanticEditor.init(a, &tree, &.{}, &.{}, &.{}, .empty, &.{}, &.{}, .empty);
    const root = try editor.addScope(.none, .none, .module, true);
    const source_scope = try editor.addScope(root, .none, .block, true);
    const target_scope = try editor.addScope(root, .none, .function, true);
    const name = try tree.addString("E");
    const source = try tree.addNode(.{ .tag = .binding_identifier, .span = name, .data = .{ .string_ref = name } });
    const output_name = try tree.addString("E$1");
    const output = try tree.addNode(.{ .tag = .binding_identifier, .span = output_name, .data = .{ .string_ref = output_name } });
    const missing = try tree.addNode(.{ .tag = .binding_identifier, .span = name, .data = .{ .string_ref = name } });
    const id = try editor.declare(source, name, Span.EMPTY, source_scope, .variable_let, 1, 2);
    editor.symbol_ids.items[try editor.ensureNodeSlot(output)] = @backingInt(id);
    editor.symbol_ids.items[try editor.ensureNodeSlot(missing)] = @backingInt(id);
    // Two source var statements can legitimately retain the same canonical
    // declaration anchor while their statement coordinates remain distinct.
    var second = editor.references.items[0];
    second.stmt_idx = 4;
    second.scope_stmt_idx = 5;
    try editor.references.append(a, second);
    const read = try tree.addNode(.{ .tag = .identifier_reference, .span = name, .data = .{ .string_ref = name } });
    try editor.addReference(read, id, source_scope, .{ .read = true }, 7, 8);
    const other_name = try tree.addString("other");
    const other_binding = try tree.addNode(.{ .tag = .binding_identifier, .span = other_name, .data = .{ .string_ref = other_name } });
    const other_id = try editor.declare(other_binding, other_name, Span.EMPTY, root, .variable_var, 9, 10);
    const before = try a.dupe(Reference, editor.references.items);
    try std.testing.expectError(error.InvalidSymbol, editor.reanchorDeclarationFromNode(&tree, source, output, other_id));
    for (before, editor.references.items) |expected, actual| try std.testing.expect(std.meta.eql(expected, actual));
    var foreign = Ast.init(a, "");
    const foreign_name = try foreign.addString("E");
    const foreign_source = try foreign.addNode(.{ .tag = .binding_identifier, .span = foreign_name, .data = .{ .string_ref = foreign_name } });
    try std.testing.expectEqual(source, foreign_source);
    try std.testing.expectError(error.InvalidNode, editor.reanchorDeclarationFromNode(&foreign, foreign_source, output, id));
    for (before, editor.references.items) |expected, actual| try std.testing.expect(std.meta.eql(expected, actual));
    try std.testing.expectError(error.ReferenceNotFound, editor.reanchorDeclarationFromNode(&tree, missing, output, id));
    try std.testing.expectError(error.InvalidSymbol, editor.reanchorDeclarationFromNode(&tree, source, output, @fromBackingInt(99)));
    try editor.references.append(a, editor.references.items[0]);
    const duplicate = try a.dupe(Reference, editor.references.items);
    try std.testing.expectError(error.DuplicateBinding, editor.reanchorDeclarationFromNode(&tree, source, output, id));
    for (duplicate, editor.references.items) |expected, actual| try std.testing.expect(std.meta.eql(expected, actual));
    _ = editor.references.pop();
    editor.references.items[0].symbol_id = @fromBackingInt(99);
    const wrong = try a.dupe(Reference, editor.references.items);
    try std.testing.expectError(error.InvalidSymbol, editor.reanchorDeclarationFromNode(&tree, source, output, id));
    for (wrong, editor.references.items) |expected, actual| try std.testing.expect(std.meta.eql(expected, actual));
    editor.references.items[0] = before[0];
    try std.testing.expectEqual(@as(usize, 2), try editor.reanchorDeclarationFromNode(&tree, source, output, id));
    for (before, editor.references.items) |original, actual| {
        var expected = original;
        if (expected.flags.declare and expected.symbol_id == id) expected.declaration_node_index = output;
        try std.testing.expect(std.meta.eql(expected, actual));
    }
    try std.testing.expectEqual(@as(?u32, @backingInt(id)), editor.symbol_ids.items[@backingInt(read)]);
    try editor.reparentScope(source_scope, target_scope);
    try editor.relocateSymbolAsPreservingAnchors(id, target_scope, output);
    for (editor.references.items) |reference| {
        if (reference.flags.declare and reference.symbol_id == id) {
            try std.testing.expectEqual(output, reference.declaration_node_index);
            try std.testing.expectEqual(target_scope, reference.scope_id);
        }
    }
    try std.testing.expectEqual(@as(?u32, @backingInt(id)), editor.symbol_ids.items[@backingInt(read)]);
}

const NamespaceMoveMutation = enum { none, foreign_ast, wrong_row, wrong_symbol, wrong_scope, no_source, bad_output, prebound_output, duplicate_row, wrong_parent, wrong_name, wrong_const_kind, extra_flags, foreign_source_anchor, foreign_output_anchor, reserved_row, mixed_row, node_index_row, valid_sibling_symbol, valid_sibling_scope, allocation_failure };

fn namespaceMoveForTest(mutation: NamespaceMoveMutation) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var scanner = try Scanner.init(a, "export const value=7; Reflect.get(ns,'value'); import * as ns from './self.mjs'; function sibling(){}");
    defer scanner.deinit();
    var parser = @import("../parser/parser.zig").Parser.init(a, &scanner);
    parser.is_module = true;
    defer parser.deinit();
    const root = try parser.parse();
    var analyzer = @import("analyzer.zig").SemanticAnalyzer.init(a, &parser.ast);
    analyzer.is_module = true;
    analyzer.enable_stmt_info = true;
    analyzer.enable_exact_declaration_anchors = true;
    defer analyzer.deinit();
    try analyzer.analyze();
    const root_node = parser.ast.getNode(root);
    var source_declaration: NodeIndex = .none;
    for (parser.ast.extra_data.items[root_node.data.list.start..][0..root_node.data.list.len]) |raw| {
        const node: NodeIndex = @fromBackingInt(raw);
        if (parser.ast.getNode(node).tag == .import_declaration) source_declaration = node;
    }
    if (source_declaration.isNone()) return error.MissingNamespaceImport;
    const source_extra = parser.ast.getNode(source_declaration).data.extra;
    const source_specifier: NodeIndex = @fromBackingInt(parser.ast.extra_data.items[parser.ast.extra_data.items[source_extra]]);
    const raw_sid = analyzer.symbol_ids.items[@backingInt(source_specifier)] orelse return error.MissingNamespaceIdentity;
    const sid: SymbolId = @fromBackingInt(raw_sid);
    const scope = analyzer.symbols.items[raw_sid].scope_id;
    var declaration_row: ?usize = null;
    for (analyzer.references.items, 0..) |row, index| {
        if (row.symbol_id == sid and row.flags.declare and row.declaration_node_index == source_specifier) declaration_row = index;
    }
    var editor = try analyzer.beginEdit();
    defer editor.deinit();
    // Ensure the output is beyond the existing ID capacity, so allocation
    // failure tests the real final reservation rather than a no-op allocator.
    for (0..editor.symbol_ids.capacity + 1) |_| _ = try parser.ast.addNode(.{ .tag = .null_literal, .span = .EMPTY, .data = .{ .none = 0 } });
    const name = editor.symbols.items[raw_sid].name;
    const output_binding = try parser.ast.addNode(.{ .tag = .binding_identifier, .span = name, .data = .{ .string_ref = name } });
    const initializer = try parser.ast.addNode(.{ .tag = .object_expression, .span = .EMPTY, .data = .{ .list = .{ .start = 0, .len = 0 } } });
    const declarator = try parser.ast.addNode(.{ .tag = .variable_declarator, .span = .EMPTY, .data = .{ .extra = try parser.ast.addExtras(&.{ @backingInt(output_binding), @backingInt(NodeIndex.none), @backingInt(initializer) }) } });
    const list = try parser.ast.addNodeList(&.{declarator});
    const statement = try parser.ast.addNode(.{ .tag = .variable_declaration, .span = .EMPTY, .data = .{ .extra = try parser.ast.addExtras(&.{ @backingInt(ast_mod.VariableDeclarationKind.@"const"), list.start, list.len }) } });
    var input: SemanticEditor.KnownNamespaceDeclarationMove = .{
        .ast = &parser.ast,
        .root = root,
        .root_scope = scope,
        .symbol = sid,
        .source_specifier = source_specifier,
        .source_declaration = source_declaration,
        .declaration_row = declaration_row orelse return error.MissingNamespaceDeclaration,
        .expected_source_flags = editor.symbols.items[raw_sid].decl_flags,
        .output_binding = output_binding,
        .output_declarator = declarator,
        .output_statement = statement,
    };
    const original_input = input;
    const original_row = editor.references.items[input.declaration_row];
    const original_binding = parser.ast.getNode(output_binding);
    const original_const_kind = parser.ast.extra_data.items[parser.ast.getNode(statement).data.extra];
    var foreign_ast = parser.ast;
    var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    switch (mutation) {
        .none => {},
        .foreign_ast => input.ast = &foreign_ast,
        .wrong_row => input.declaration_row = editor.references.items.len,
        .wrong_symbol => input.symbol = @fromBackingInt(@as(u32, @intCast(editor.symbols.items.len))),
        .wrong_scope => input.root_scope = .none,
        .valid_sibling_symbol => {
            for (analyzer.references.items) |reference| {
                if (reference.flags.declare and reference.symbol_id != sid) {
                    input.symbol = reference.symbol_id;
                    break;
                }
            }
            try std.testing.expect(input.symbol != sid);
        },
        .valid_sibling_scope => {
            for (analyzer.scopes.items, 0..) |sibling, raw| {
                if (sibling.kind == .function and sibling.parent == scope) {
                    input.root_scope = @fromBackingInt(@as(u32, @intCast(raw)));
                    break;
                }
            }
            try std.testing.expect(input.root_scope != scope);
        },
        .no_source => input.source_specifier = .none,
        .bad_output => input.output_binding = @fromBackingInt(@as(u32, @intCast(parser.ast.nodes.items.len))),
        .prebound_output => {
            const old_len = editor.symbol_ids.items.len;
            try editor.symbol_ids.resize(a, @as(usize, @backingInt(output_binding)) + 1);
            @memset(editor.symbol_ids.items[old_len..], null);
            editor.symbol_ids.items[@backingInt(output_binding)] = raw_sid;
        },
        .duplicate_row => try editor.references.append(a, editor.references.items[input.declaration_row]),
        .wrong_parent => input.output_declarator = initializer,
        .wrong_name => parser.ast.nodes.items[@backingInt(output_binding)].data.string_ref = .EMPTY,
        .wrong_const_kind => parser.ast.extra_data.items[parser.ast.getNode(statement).data.extra] = @backingInt(ast_mod.VariableDeclarationKind.@"var"),
        .extra_flags => editor.symbols.items[raw_sid].decl_flags.is_exported = true,
        .foreign_source_anchor, .foreign_output_anchor => {
            var foreign_row = original_row;
            var foreign_symbol: ?SymbolId = null;
            for (analyzer.references.items) |reference| {
                if (reference.flags.declare and reference.symbol_id != sid) {
                    foreign_symbol = reference.symbol_id;
                    break;
                }
            }
            foreign_row.symbol_id = foreign_symbol orelse return error.MissingValidSiblingIdentity;
            if (mutation == .foreign_output_anchor) foreign_row.declaration_node_index = output_binding;
            try editor.references.append(a, foreign_row);
        },
        .reserved_row => editor.references.items[input.declaration_row].flags._reserved = 1,
        .mixed_row => editor.references.items[input.declaration_row].flags.read = true,
        .node_index_row => editor.references.items[input.declaration_row].node_index = source_specifier,
        .allocation_failure => editor.allocator = failing.allocator(),
    }
    const before_symbol = editor.symbols.items[raw_sid];
    const before_rows = try a.dupe(Reference, editor.references.items);
    const before_ids = try a.dupe(?u32, editor.symbol_ids.items);
    const before_scopes = try a.dupe(Scope, editor.scopes.items);
    const before_nodes = try a.dupe(ast_mod.Node, parser.ast.nodes.items);
    const before_extra = try a.dupe(u32, parser.ast.extra_data.items);
    const before_scope_map_count = editor.scope_maps.items[scope.toIndex()].count();
    if (mutation == .none) {
        try editor.moveKnownNamespaceImportToConst(input);
    } else {
        if (editor.moveKnownNamespaceImportToConst(input)) |_| return error.InvalidNamespaceMoveAccepted else |err| {
            if (mutation == .allocation_failure) try std.testing.expectEqual(error.OutOfMemory, err);
        }
        editor.allocator = a;
        try std.testing.expectEqualDeep(before_symbol, editor.symbols.items[raw_sid]);
        try std.testing.expectEqualDeep(before_rows, editor.references.items);
        try std.testing.expectEqualDeep(before_ids, editor.symbol_ids.items);
        try std.testing.expectEqualDeep(before_scopes, editor.scopes.items);
        try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(before_nodes), std.mem.sliceAsBytes(parser.ast.nodes.items));
        try std.testing.expectEqualDeep(before_extra, parser.ast.extra_data.items);
        try std.testing.expectEqual(before_scope_map_count, editor.scope_maps.items[scope.toIndex()].count());
        try std.testing.expectEqual(@as(?usize, raw_sid), editor.scope_maps.items[scope.toIndex()].get(parser.ast.getText(name)));
        switch (mutation) {
            .prebound_output => editor.symbol_ids.items[@backingInt(output_binding)] = null,
            .duplicate_row, .foreign_source_anchor, .foreign_output_anchor => _ = editor.references.pop(),
            .extra_flags => editor.symbols.items[raw_sid].decl_flags = original_input.expected_source_flags,
            .wrong_name => parser.ast.nodes.items[@backingInt(output_binding)] = original_binding,
            .wrong_const_kind => parser.ast.extra_data.items[parser.ast.getNode(statement).data.extra] = original_const_kind,
            .reserved_row, .mixed_row, .node_index_row => editor.references.items[input.declaration_row] = original_row,
            else => {},
        }
        try editor.moveKnownNamespaceImportToConst(original_input);
    }
    var expected_symbol = analyzer.symbols.items[raw_sid];
    expected_symbol.kind = .variable_const;
    expected_symbol.decl_flags = SymbolKind.variable_const.declFlags();
    try std.testing.expectEqualDeep(expected_symbol, editor.symbols.items[raw_sid]);
    try std.testing.expectEqual(@as(?u32, raw_sid), editor.symbol_ids.items[@backingInt(output_binding)]);
    try std.testing.expect(editor.references.items[original_input.declaration_row].declaration_node_index == output_binding);
    for (analyzer.references.items, 0..) |row, index| {
        var expected = row;
        if (index == original_input.declaration_row) expected.declaration_node_index = output_binding;
        try std.testing.expectEqualDeep(expected, editor.references.items[index]);
    }
}

test "known namespace declaration move uses actual parser identity and preserves source metadata" {
    try namespaceMoveForTest(.none);
}

test "known namespace declaration move rejects foreign contracts transactionally and restores" {
    inline for (std.meta.tags(NamespaceMoveMutation)) |mutation| {
        if (mutation != .none) try namespaceMoveForTest(mutation);
    }
}

const UnreachableFunctionMutation = enum { none, live_owner, wrong_scope, wrong_params, wrong_body, paired_owner, live_descendant, exported, synthetic, escaping_read, escaping_alias, redeclaration, dynamic_scope };

fn unreachableFunctionRetirementForTest(mutation: UnreachableFunctionMutation, fail_at: ?usize) !bool {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const input = "var keep=10;(function(p){let x=p;return x+keep});function live(q){return q}console.log(keep);";
    var scanner = try Scanner.init(a, input);
    var parser = @import("../parser/parser.zig").Parser.init(a, &scanner);
    parser.configureFromExtension(".js");
    _ = try parser.parse();
    try std.testing.expectEqual(@as(usize, 0), parser.errors.items.len);
    var analyzer = @import("analyzer.zig").SemanticAnalyzer.init(a, &parser.ast);
    analyzer.enable_exact_declaration_anchors = true;
    try analyzer.analyze();
    var owner: NodeIndex = .none;
    var sibling: NodeIndex = .none;
    for (parser.ast.nodes.items, 0..) |node, raw| {
        if (node.tag == .function_expression) owner = @fromBackingInt(@intCast(raw));
        if (node.tag == .function_declaration) sibling = @fromBackingInt(@intCast(raw));
    }
    const node = parser.ast.getNode(owner);
    var known = KnownUnreachableFunction{ .owner = owner, .scope = @fromBackingInt(analyzer.scope_owner_map.get(@backingInt(owner)).?), .params = parser.ast.readExtraNode(node.data.extra, ast_mod.FunctionExtra.params), .body = parser.ast.readExtraNode(node.data.extra, ast_mod.FunctionExtra.body), .body_scope = if (analyzer.scope_owner_map.get(@backingInt(parser.ast.readExtraNode(node.data.extra, ast_mod.FunctionExtra.body)))) |value| @fromBackingInt(value) else .none };
    std.debug.print("FUNCTION_RETIRE_SOURCE owner={d} scope={d} params={d} body={d} bodyOwner={any}\n", .{ @backingInt(owner), @backingInt(known.scope), @backingInt(known.params), @backingInt(known.body), analyzer.scope_owner_map.get(@backingInt(known.body)) });
    var editor = try SemanticEditor.init(a, &parser.ast, analyzer.symbols.items, analyzer.scopes.items, analyzer.scope_maps.items, analyzer.scope_owner_map, analyzer.references.items, analyzer.symbol_ids.items, analyzer.helper_scope_map);
    defer editor.deinit();
    const root = parser.ast.nodes.items.len - 1;
    const program = parser.ast.nodes.items[root];
    const removed_statement = parser.ast.extra_data.items[program.data.list.start + 1];
    if (mutation != .live_owner) parser.ast.nodes.items[removed_statement].tag = .empty_statement;
    const param_list = parser.ast.getNode(known.params).data.list;
    const parameter: NodeIndex = @fromBackingInt(parser.ast.extra_data.items[param_list.start]);
    const parameter_node = parser.ast.getNode(parameter);
    const binding = if (parameter_node.tag == .formal_parameter) parser.ast.readExtraNode(parameter_node.data.extra, 0) else parameter;
    const id = editor.symbol_ids.items[@backingInt(binding)].?;
    switch (mutation) {
        .none, .live_owner => {},
        .wrong_scope => known.scope = editor.scopes.items[known.scope.toIndex()].parent,
        .wrong_params => known.params = known.body,
        .wrong_body => known.body = known.params,
        .paired_owner => {
            const other = editor.scope_owner_map.get(@backingInt(sibling)).?;
            try editor.scope_owner_map.put(a, @backingInt(owner), other);
            try editor.scope_owner_map.put(a, @backingInt(known.body), other);
            editor.symbols.items[id].scope_id = @fromBackingInt(other);
        },
        .live_descendant => {
            const shared = parser.ast.getNode(known.body).data.list;
            const last: NodeIndex = @fromBackingInt(parser.ast.extra_data.items[shared.start + shared.len - 1]);
            const read = parser.ast.getNode(last).data.unary.operand;
            const extra_stmt = try parser.ast.addNode(.{ .tag = .expression_statement, .span = .EMPTY, .data = .{ .unary = .{ .operand = read, .flags = 0 } } });
            const start: u32 = @intCast(parser.ast.extra_data.items.len);
            const previous = try a.dupe(u32, parser.ast.extra_data.items[program.data.list.start..][0..program.data.list.len]);
            try parser.ast.extra_data.appendSlice(a, previous);
            try parser.ast.extra_data.append(a, @backingInt(extra_stmt));
            const new_root = try parser.ast.addListNode(.program, program.span, .{ .start = start, .len = program.data.list.len + 1 });
            parser.ast.transformed_root = new_root;
        },
        .exported => editor.symbols.items[id].decl_flags.is_exported = true,
        .synthetic => editor.symbols.items[id].synthetic_kind = .runtime_helper_import,
        .escaping_read => {
            var row: ?Reference = null;
            for (editor.references.items) |reference| if (@backingInt(reference.symbol_id) == id and reference.flags.read) {
                row = reference;
                break;
            };
            var escaped = row.?;
            escaped.node_index = sibling;
            try editor.references.append(a, escaped);
            editor.symbols.items[id].reference_count += 1;
        },
        .escaping_alias => try editor.scope_maps.items[0].put(a, "p", id),
        .redeclaration => {
            var row: ?Reference = null;
            for (editor.references.items) |reference| if (@backingInt(reference.symbol_id) == id and reference.flags.declare) {
                row = reference;
                break;
            };
            try editor.references.append(a, row.?);
        },
        .dynamic_scope => editor.scopes.items[known.scope.toIndex()].subtree_has_direct_eval = true,
    }
    const before_ids = try a.dupe(?u32, editor.symbol_ids.items);
    const before_symbols = try a.dupe(Symbol, editor.symbols.items);
    const before_references = try a.dupe(Reference, editor.references.items);
    const before_scopes = try a.dupe(Scope, editor.scopes.items);
    const before_owner_count = editor.scope_owner_map.count();
    var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = fail_at orelse std.math.maxInt(usize) });
    editor.allocator = failing.allocator();
    const accepted = editor.retireUnreachableFunctionSubtree(known) catch |err| {
        editor.allocator = a;
        try std.testing.expectEqual(error.OutOfMemory, err);
        try std.testing.expectEqualDeep(before_ids, editor.symbol_ids.items);
        try std.testing.expectEqualDeep(before_symbols, editor.symbols.items);
        try std.testing.expectEqualDeep(before_references, editor.references.items);
        try std.testing.expectEqualDeep(before_scopes, editor.scopes.items);
        try std.testing.expectEqual(before_owner_count, editor.scope_owner_map.count());
        return false;
    };
    editor.allocator = a;
    if (mutation != .none) {
        try std.testing.expect(!accepted);
        try std.testing.expectEqualDeep(before_ids, editor.symbol_ids.items);
        try std.testing.expectEqualDeep(before_symbols, editor.symbols.items);
        try std.testing.expectEqualDeep(before_references, editor.references.items);
        try std.testing.expectEqualDeep(before_scopes, editor.scopes.items);
        try std.testing.expectEqual(before_owner_count, editor.scope_owner_map.count());
    } else {
        try std.testing.expect(accepted);
        try std.testing.expectEqual(before_ids.len, editor.symbol_ids.items.len);
        try std.testing.expectEqual(before_symbols.len, editor.symbols.items.len);
        try std.testing.expectEqual(before_scopes.len, editor.scopes.items.len);
        try std.testing.expect(editor.symbol_ids.items[@backingInt(binding)] == null);
        try std.testing.expect(!editor.scope_owner_map.contains(@backingInt(owner)));
        try std.testing.expectEqual(@as(usize, 0), editor.scope_maps.items[known.scope.toIndex()].count());
        try std.testing.expectEqual(@as(u16, 0), editor.scopes.items[known.scope.toIndex()].symbol_count);
        _ = try editor.finish();
    }
    return accepted;
}

test "Buffer whole unreachable function retirement preserves slots and rejects paired escaping witnesses" {
    inline for (std.meta.tags(UnreachableFunctionMutation)) |mutation| _ = try unreachableFunctionRetirementForTest(mutation, null);
}

test "Buffer whole unreachable function retirement OOM leaves editor unpublished and retries" {
    var failures: usize = 0;
    var success = false;
    for (0..64) |index| {
        if (try unreachableFunctionRetirementForTest(.none, index)) {
            success = true;
            break;
        }
        failures += 1;
    }
    try std.testing.expect(success and failures > 0);
    std.debug.print("BUFFER_FUNCTION_RETIREMENT_OOM windows={d} retry=true\n", .{failures});
}

const SourceFunctionRetirementMutation = enum { none, foreign_domain, missing_reference_receipt, live_owner, changed_binding, changed_owner, forged_source_payload, forged_target_payload, forged_copy_reference, forged_copy_owner, forged_reference_flags, forged_reference_scope };

fn sourceFunctionRetirementForTest(mutation: SourceFunctionRetirementMutation, fail_at: ?usize) !bool {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const input = "var keep=10;(function(p){let x=p;return x+keep});console.log(keep,keep);";
    var scanner = try Scanner.init(a, input);
    var parser = @import("../parser/parser.zig").Parser.init(a, &scanner);
    parser.configureFromExtension(".js");
    _ = try parser.parse();
    try std.testing.expectEqual(@as(usize, 0), parser.errors.items.len);
    var analyzer = @import("analyzer.zig").SemanticAnalyzer.init(a, &parser.ast);
    analyzer.enable_stmt_info = true;
    analyzer.enable_exact_declaration_anchors = true;
    try analyzer.analyze();
    var editor = try SemanticEditor.init(a, &parser.ast, analyzer.symbols.items, analyzer.scopes.items, analyzer.scope_maps.items, analyzer.scope_owner_map, analyzer.references.items, analyzer.symbol_ids.items, analyzer.helper_scope_map);
    var owner: NodeIndex = .none;
    for (parser.ast.nodes.items, 0..) |node, raw| if (node.tag == .function_expression) {
        owner = @fromBackingInt(@intCast(raw));
    };
    const node = parser.ast.getNode(owner);
    const body = parser.ast.readExtraNode(node.data.extra, ast_mod.FunctionExtra.body);
    const known = KnownUnreachableFunction{
        .owner = owner,
        .scope = @fromBackingInt(editor.scope_owner_map.get(@backingInt(owner)).?),
        .params = parser.ast.readExtraNode(node.data.extra, ast_mod.FunctionExtra.params),
        .body = body,
        .body_scope = if (editor.scope_owner_map.get(@backingInt(body))) |raw| @fromBackingInt(raw) else .none,
    };
    const plan = try editor.captureFunctionRetirementSources(&.{known});
    var changes: std.ArrayList(@import("function_retirement_receipt.zig").ReferenceChange) = .empty;
    // Apply the producer's actual row removals while preserving declaration
    // anchors for the source-owned whole-function consumer.
    for (plan.graph.references.items) |row| {
        if (row.flags.declare or row.node_index.isNone()) continue;
        var inside = false;
        for (plan.subtree) |raw| if (raw == @backingInt(row.node_index)) {
            inside = true;
        };
        if (!inside) continue;
        try editor.removeReference(row.node_index);
        try changes.append(a, .{ .before = row, .after = null });
    }
    const root = parser.ast.nodes.items[parser.ast.nodes.items.len - 1];
    if (mutation != .live_owner) parser.ast.nodes.items[parser.ast.extra_data.items[root.data.list.start + 1]].tag = .empty_statement;
    // The old backing is deliberately rewritten. Only the immutable source
    // snapshot can still identify its original body and declaration edges.
    parser.ast.nodes.items[@backingInt(body)].data.list.len = 0;
    // An actual harmless copy outside the retired closure supplies paired
    // source/target payloads and a reference for independent forgery tests.
    var live_reads: std.ArrayList(Reference) = .empty;
    for (editor.references.items) |row| {
        if (!row.flags.declare and !row.node_index.isNone() and row.scope_id == editor.scopes.items[known.scope.toIndex()].parent)
            try live_reads.append(a, row);
    }
    try std.testing.expectEqual(@as(usize, 2), live_reads.items.len);
    const from = live_reads.items[0].node_index;
    const to = live_reads.items[1].node_index;
    var copies = [_]@import("function_retirement_receipt.zig").Copy{.{
        .source = from,
        .target = to,
        .source_node = parser.ast.getNode(from),
        .target_node = parser.ast.getNode(to),
        .source_reference = live_reads.items[0],
        .source_owner = null,
        .source_reachable = true,
        .target_reachable = true,
    }};
    parser.ast.nodes.items[@backingInt(to)] = parser.ast.getNode(from);
    var receipt: @import("function_retirement_receipt.zig").ApplicationReceipt = .{
        .domain = &parser.ast,
        .reference_changes = changes.items,
        .owner_changes = &.{},
        .provenance_changes = &.{},
        .copies = &copies,
    };
    var foreign_header = parser.ast;
    switch (mutation) {
        .none, .live_owner => {},
        .foreign_domain => receipt.domain = &foreign_header,
        .missing_reference_receipt => receipt.reference_changes = &.{},
        .changed_binding => {
            for (editor.references.items) |row| if (row.flags.declare and !row.declaration_node_index.isNone() and row.scope_id == known.scope) {
                editor.symbol_ids.items[@backingInt(row.declaration_node_index)] = null;
                break;
            };
        },
        .changed_owner => _ = editor.scope_owner_map.remove(@backingInt(owner)),
        .forged_source_payload => copies[0].source_node.span.start += 1,
        .forged_target_payload => copies[0].target_node.span.start += 1,
        .forged_copy_reference => copies[0].source_reference.?.flags.write = true,
        .forged_copy_owner => copies[0].source_owner = known.scope,
        .forged_reference_flags, .forged_reference_scope => {
            const before = live_reads.items[1];
            if (mutation == .forged_reference_flags) {
                var flags = before.flags;
                flags.write = true;
                try editor.updateReferenceFlags(to, flags);
            } else try editor.moveReference(to, known.scope, before.stmt_idx, before.scope_stmt_idx);
            var after: ?Reference = null;
            for (editor.references.items) |row| if (row.node_index == to) {
                after = row;
            };
            try changes.append(a, .{ .before = before, .after = after.? });
            receipt.reference_changes = changes.items;
        },
    }
    const before_ids = try a.dupe(?u32, editor.symbol_ids.items);
    const before_symbols = try a.dupe(Symbol, editor.symbols.items);
    const before_rows = try a.dupe(Reference, editor.references.items);
    const before_scopes = try a.dupe(Scope, editor.scopes.items);
    const before_owner_count = editor.scope_owner_map.count();
    var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = fail_at orelse std.math.maxInt(usize) });
    editor.allocator = failing.allocator();
    const accepted = editor.retireSourceOwnedFunction(plan, receipt) catch |err| {
        try std.testing.expect(err == error.OutOfMemory);
        try std.testing.expectEqualSlices(?u32, before_ids, editor.symbol_ids.items);
        try std.testing.expectEqualDeep(before_symbols, editor.symbols.items);
        try std.testing.expectEqualDeep(before_rows, editor.references.items);
        try std.testing.expectEqualDeep(before_scopes, editor.scopes.items);
        try std.testing.expectEqual(before_owner_count, editor.scope_owner_map.count());
        editor.allocator = a;
        try std.testing.expect(try editor.retireSourceOwnedFunction(plan, receipt));
        return false;
    };
    // Retirement has returned successfully. The independent finish check is
    // not another allocation window inside that operation.
    editor.allocator = a;
    if (mutation != .none) {
        try std.testing.expect(!accepted);
        try std.testing.expectEqualSlices(?u32, before_ids, editor.symbol_ids.items);
        try std.testing.expectEqualDeep(before_rows, editor.references.items);
        try std.testing.expectEqualDeep(before_symbols, editor.symbols.items);
        try std.testing.expectEqualDeep(before_scopes, editor.scopes.items);
        try std.testing.expectEqual(before_owner_count, editor.scope_owner_map.count());
    } else {
        try std.testing.expect(accepted);
        try std.testing.expect(!editor.scope_owner_map.contains(@backingInt(owner)));
        try std.testing.expectEqual(@as(usize, 0), editor.scope_maps.items[known.scope.toIndex()].count());
        try std.testing.expectEqual(@as(u16, 0), editor.scopes.items[known.scope.toIndex()].symbol_count);
        _ = try editor.finish();
    }
    return accepted;
}

test "Buffer source owned function retirement uses immutable pre rewrite closure and rejects foreign receipts" {
    inline for (std.meta.tags(SourceFunctionRetirementMutation)) |mutation| _ = try sourceFunctionRetirementForTest(mutation, null);
}

test "Buffer source owned function retirement batch OOM preserves graph and retries" {
    var failures: usize = 0;
    var success = false;
    for (0..256) |index| {
        if (try sourceFunctionRetirementForTest(.none, index)) {
            success = true;
            break;
        }
        failures += 1;
    }
    try std.testing.expect(success and failures > 0);
    std.debug.print("BUFFER_SOURCE_FUNCTION_RETIREMENT_OOM windows={d} retry=true\n", .{failures});
}

test "empty arrow elision preserves actual source identities and refuses stale plans" {
    const Parser = @import("../parser/parser.zig").Parser;
    const Analyzer = @import("analyzer.zig").SemanticAnalyzer;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var scanner = try Scanner.init(a, "const value=42;function sibling(){};console.log((()=>value)());");
    var parser = Parser.init(a, &scanner);
    parser.configureFromExtension(".js");
    _ = try parser.parse();
    var analyzer = Analyzer.init(a, &parser.ast);
    try analyzer.analyze();
    var editor = try analyzer.beginEdit();
    var owner: NodeIndex = .none;
    var sibling_scope: ScopeId = .none;
    for (parser.ast.nodes.items, 0..) |node, raw| {
        if (node.tag == .arrow_function_expression) owner = @fromBackingInt(@as(u32, @intCast(raw)));
        if (node.tag == .function_declaration) sibling_scope = @fromBackingInt(editor.scope_owner_map.get(@intCast(raw)).?);
    }
    try std.testing.expect(!owner.isNone() and !sibling_scope.isNone());
    const scope: ScopeId = @fromBackingInt(editor.scope_owner_map.get(@backingInt(owner)).?);
    const parent = editor.scopes.items[scope.toIndex()].parent;
    const plan: SemanticEditor.EmptyArrowScopeElision = .{ .owner = owner, .scope = scope, .parent = parent, .source = parser.ast.getNode(owner) };
    var original: ?Reference = null;
    for (editor.references.items) |reference| if (!reference.flags.declare and reference.scope_id == scope) {
        original = reference;
    };
    const reference = original orelse return error.MissingActualArrowReference;
    var stale = plan;
    stale.parent = sibling_scope;
    try std.testing.expectError(error.InvalidScope, editor.elideEmptyArrowScopeOwner(stale));
    stale = plan;
    stale.source.tag = .function_expression;
    try std.testing.expectError(error.InvalidNode, editor.elideEmptyArrowScopeOwner(stale));
    editor.scopes.items[scope.toIndex()].subtree_has_direct_eval = true;
    try std.testing.expectError(error.InvalidScope, editor.elideEmptyArrowScopeOwner(plan));
    editor.scopes.items[scope.toIndex()].subtree_has_direct_eval = false;
    try editor.scope_maps.items[scope.toIndex()].put(a, "poison", @backingInt(reference.symbol_id));
    try std.testing.expectError(error.InvalidScope, editor.elideEmptyArrowScopeOwner(plan));
    _ = editor.scope_maps.items[scope.toIndex()].remove("poison");
    try std.testing.expectEqual(@as(?u32, @backingInt(scope)), editor.scope_owner_map.get(@backingInt(owner)));
    try std.testing.expectEqual(scope, (try editor.referenceForNode(reference.node_index)).?.scope_id);
    try editor.elideEmptyArrowScopeOwner(plan);
    try std.testing.expectEqual(@as(?u32, null), editor.scope_owner_map.get(@backingInt(owner)));
    const actual = (try editor.referenceForNode(reference.node_index)).?;
    try std.testing.expectEqual(reference.symbol_id, actual.symbol_id);
    try std.testing.expectEqual(reference.node_index, actual.node_index);
    try std.testing.expectEqualDeep(reference.flags, actual.flags);
    try std.testing.expectEqual(parent, actual.scope_id);
}

const SourceFunctionSelectionMutation = enum { none, select_live, duplicate, unknown, materialized_node, materialized_sid, materialized_role, live_copy };

fn sourceFunctionSelectionForTest(mutation: SourceFunctionSelectionMutation) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const input = "var keep=10;(function(p){let x=p;return x+keep});function live(){return keep}console.log(keep);";
    var scanner = try Scanner.init(a, input);
    var parser = @import("../parser/parser.zig").Parser.init(a, &scanner);
    parser.configureFromExtension(".js");
    _ = try parser.parse();
    try std.testing.expectEqual(@as(usize, 0), parser.errors.items.len);
    var analyzer = @import("analyzer.zig").SemanticAnalyzer.init(a, &parser.ast);
    analyzer.enable_stmt_info = true;
    analyzer.enable_exact_declaration_anchors = true;
    try analyzer.analyze();
    var editor = try SemanticEditor.init(a, &parser.ast, analyzer.symbols.items, analyzer.scopes.items, analyzer.scope_maps.items, analyzer.scope_owner_map, analyzer.references.items, analyzer.symbol_ids.items, analyzer.helper_scope_map);
    var functions: std.ArrayList(KnownUnreachableFunction) = .empty;
    var dead_owner: NodeIndex = .none;
    var live_owner: NodeIndex = .none;
    for (parser.ast.nodes.items, 0..) |node, raw| {
        if (node.tag != .function_expression and node.tag != .function_declaration) continue;
        const owner: NodeIndex = @fromBackingInt(@intCast(raw));
        const body = parser.ast.readExtraNode(node.data.extra, ast_mod.FunctionExtra.body);
        try functions.append(a, .{
            .owner = owner,
            .scope = @fromBackingInt(editor.scope_owner_map.get(@intCast(raw)).?),
            .params = parser.ast.readExtraNode(node.data.extra, ast_mod.FunctionExtra.params),
            .body = body,
            .body_scope = if (editor.scope_owner_map.get(@backingInt(body))) |scope| @fromBackingInt(scope) else .none,
        });
        if (node.tag == .function_expression) dead_owner = owner else live_owner = owner;
    }
    try std.testing.expectEqual(@as(usize, 2), functions.items.len);
    const plan = try editor.captureFunctionRetirementSources(functions.items);
    const dead = try @import("../parser/ast_walk.zig").collectReachableNodeIndicesFrom(a, plan.source, dead_owner);
    const dead_scope: ScopeId = @fromBackingInt(editor.scope_owner_map.get(@backingInt(dead_owner)).?);
    var materialized_row: ?Reference = null;
    var target_row: ?Reference = null;
    for (editor.references.items) |row| {
        if (!row.flags.read or row.node_index.isNone() or editor.symbols.items[@backingInt(row.symbol_id)].scope_id != editor.scopes.items[dead_scope.toIndex()].parent) continue;
        if (row.scope_id == dead_scope) materialized_row = row;
        if (row.scope_id == editor.scopes.items[dead_scope.toIndex()].parent) target_row = row;
    }
    const original = materialized_row.?;
    const before_node = parser.ast.getNode(original.node_index);
    var numeric: ?ast_mod.Node = null;
    for (parser.ast.nodes.items) |node| if (node.tag == .numeric_literal) {
        numeric = node;
    };
    var materialized = [_]@import("function_retirement_receipt.zig").MaterializedRead{.{
        .node = original.node_index,
        .before_node = before_node,
        .after_node = numeric.?,
        .before_reference = original,
        .before_symbol_id = @backingInt(original.symbol_id),
    }};
    var copies = [_]@import("function_retirement_receipt.zig").Copy{.{
        .source = original.node_index,
        .target = target_row.?.node_index,
        .source_node = before_node,
        .target_node = parser.ast.getNode(target_row.?.node_index),
        .source_reference = original,
        .source_owner = null,
        .source_reachable = false,
        .target_reachable = true,
    }};
    if (mutation == .live_copy) {
        parser.ast.nodes.items[@backingInt(target_row.?.node_index)] = before_node;
    } else parser.ast.nodes.items[@backingInt(original.node_index)] = numeric.?;
    var changes: std.ArrayList(@import("function_retirement_receipt.zig").ReferenceChange) = .empty;
    for (plan.graph.references.items) |row| {
        if (row.flags.declare or row.node_index.isNone()) continue;
        var inside = false;
        for (dead) |raw| if (raw == @backingInt(row.node_index)) {
            inside = true;
        };
        if (!inside) continue;
        try editor.removeReference(row.node_index);
        try changes.append(a, .{ .before = row, .after = null });
    }
    const root = parser.ast.nodes.items[parser.ast.nodes.items.len - 1];
    parser.ast.nodes.items[parser.ast.extra_data.items[root.data.list.start + 1]].tag = .empty_statement;
    for (functions.items) |known| if (known.owner == dead_owner) {
        parser.ast.nodes.items[@backingInt(known.body)].data.list.len = 0;
    };
    const receipt: @import("function_retirement_receipt.zig").ApplicationReceipt = .{
        .domain = &parser.ast,
        .reference_changes = changes.items,
        .owner_changes = &.{},
        .provenance_changes = &.{},
        .copies = if (mutation == .live_copy) &copies else &.{},
        .materialized_reads = if (mutation == .live_copy) &.{} else &materialized,
    };
    switch (mutation) {
        .materialized_node => materialized[0].before_node.span.start += 1,
        .materialized_sid => materialized[0].before_symbol_id += 1,
        .materialized_role => materialized[0].after_node.tag = .identifier_reference,
        else => {},
    }
    const owners: []const NodeIndex = switch (mutation) {
        .select_live => &[_]NodeIndex{ dead_owner, live_owner },
        .duplicate => &[_]NodeIndex{ dead_owner, dead_owner },
        .unknown => &[_]NodeIndex{.none},
        else => &[_]NodeIndex{dead_owner},
    };
    const before_ids = try a.dupe(?u32, editor.symbol_ids.items);
    const before_rows = try a.dupe(Reference, editor.references.items);
    const before_symbols = try a.dupe(Symbol, editor.symbols.items);
    const before_scopes = try a.dupe(Scope, editor.scopes.items);
    const owner_count = editor.scope_owner_map.count();
    const accepted = try editor.retireSelectedSourceOwnedFunctions(plan, owners, receipt);
    if (mutation == .none) {
        try std.testing.expect(accepted);
        try std.testing.expect(!editor.scope_owner_map.contains(@backingInt(dead_owner)));
        try std.testing.expect(editor.scope_owner_map.contains(@backingInt(live_owner)));
        try std.testing.expectEqual(@as(usize, 0), editor.scope_maps.items[dead_scope.toIndex()].count());
        _ = try editor.finish();
    } else {
        try std.testing.expect(!accepted);
        try std.testing.expectEqualSlices(?u32, before_ids, editor.symbol_ids.items);
        try std.testing.expectEqualDeep(before_rows, editor.references.items);
        try std.testing.expectEqualDeep(before_symbols, editor.symbols.items);
        try std.testing.expectEqualDeep(before_scopes, editor.scopes.items);
        try std.testing.expectEqual(owner_count, editor.scope_owner_map.count());
    }
}

test "Buffer source owned function selection materializes known reads and rejects live copied descendants" {
    inline for (std.meta.tags(SourceFunctionSelectionMutation)) |mutation| try sourceFunctionSelectionForTest(mutation);
}

test "Buffer source owned function retirement preserves dynamic parent declaration visibility" {
    for ([_][]const u8{
        "var keep=10;function removed(p){return p+keep}console.log(keep);",
        "var keep=10;function removed(p){return p+keep}eval('typeof removed');",
        "var keep=10;function removed(p){return p+keep}with({}){this['removed']}",
    }, 0..) |input, case_index| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var scanner = try Scanner.init(a, input);
        var parser = @import("../parser/parser.zig").Parser.init(a, &scanner);
        parser.configureFromExtension(".js");
        _ = try parser.parse();
        try std.testing.expectEqual(@as(usize, 0), parser.errors.items.len);
        var analyzer = @import("analyzer.zig").SemanticAnalyzer.init(a, &parser.ast);
        analyzer.enable_stmt_info = true;
        analyzer.enable_exact_declaration_anchors = true;
        try analyzer.analyze();
        var editor = try SemanticEditor.init(a, &parser.ast, analyzer.symbols.items, analyzer.scopes.items, analyzer.scope_maps.items, analyzer.scope_owner_map, analyzer.references.items, analyzer.symbol_ids.items, analyzer.helper_scope_map);
        var owner: NodeIndex = .none;
        for (parser.ast.nodes.items, 0..) |node, raw| if (node.tag == .function_declaration) {
            owner = @fromBackingInt(@intCast(raw));
        };
        const node = parser.ast.getNode(owner);
        const body = parser.ast.readExtraNode(node.data.extra, ast_mod.FunctionExtra.body);
        const name = parser.ast.readExtraNode(node.data.extra, ast_mod.FunctionExtra.name);
        const sid = editor.symbol_ids.items[@backingInt(name)].?;
        const symbol = editor.symbols.items[sid];
        try std.testing.expectEqual(case_index != 0, editor.scopes.items[symbol.scope_id.toIndex()].blocksMangling());
        try std.testing.expectEqual(case_index != 0, editor.scopes.items[symbol.origin_scope.toIndex()].blocksMangling());
        const known: KnownUnreachableFunction = .{
            .owner = owner,
            .scope = @fromBackingInt(editor.scope_owner_map.get(@backingInt(owner)).?),
            .params = parser.ast.readExtraNode(node.data.extra, ast_mod.FunctionExtra.params),
            .body = body,
            .body_scope = if (editor.scope_owner_map.get(@backingInt(body))) |raw| @fromBackingInt(raw) else .none,
        };
        const plan = try editor.captureFunctionRetirementSources(&.{known});
        var changes: std.ArrayList(@import("function_retirement_receipt.zig").ReferenceChange) = .empty;
        for (plan.graph.references.items) |row| {
            if (row.flags.declare or row.node_index.isNone()) continue;
            var inside = false;
            for (plan.subtree) |raw| if (raw == @backingInt(row.node_index)) {
                inside = true;
            };
            if (!inside) continue;
            try editor.removeReference(row.node_index);
            try changes.append(a, .{ .before = row, .after = null });
        }
        const root_index: NodeIndex = @fromBackingInt(@intCast(parser.ast.nodes.items.len - 1));
        const root = parser.ast.getNode(root_index);
        var removed_statements: usize = 0;
        var write: usize = 0;
        for (parser.ast.extra_data.items[root.data.list.start..][0..root.data.list.len]) |raw| {
            if (raw == @backingInt(owner)) {
                removed_statements += 1;
                continue;
            }
            parser.ast.extra_data.items[root.data.list.start + write] = raw;
            write += 1;
        }
        try std.testing.expectEqual(@as(usize, 1), removed_statements);
        parser.ast.nodes.items[@backingInt(root_index)].data.list.len = @intCast(write);
        parser.ast.transformed_root = root_index;
        const positions = try @import("statement_coordinates.zig").collect(a, &parser.ast, root_index);
        const remaining_rows = try a.dupe(Reference, editor.references.items);
        for (remaining_rows) |before| {
            if (before.flags.declare or before.node_index.isNone()) continue;
            const position = positions[@backingInt(before.node_index)].?;
            if (before.stmt_idx == position.stmt_idx and before.scope_stmt_idx == position.scope_stmt_idx) continue;
            try editor.moveReference(before.node_index, before.scope_id, position.stmt_idx, position.scope_stmt_idx);
            var after = before;
            after.stmt_idx = position.stmt_idx;
            after.scope_stmt_idx = position.scope_stmt_idx;
            try changes.append(a, .{ .before = before, .after = after });
            std.debug.print("BUFFER_PARENT_COORD case={d} node={d} top={d}->{d} scope={d}->{d}\n", .{ case_index, @backingInt(before.node_index), before.stmt_idx, after.stmt_idx, before.scope_stmt_idx, after.scope_stmt_idx });
        }
        const receipt: @import("function_retirement_receipt.zig").ApplicationReceipt = .{
            .domain = &parser.ast,
            .reference_changes = changes.items,
            .owner_changes = &.{},
            .provenance_changes = &.{},
            .copies = &.{},
        };
        const before_ids = try a.dupe(?u32, editor.symbol_ids.items);
        const before_rows = try a.dupe(Reference, editor.references.items);
        const before_symbols = try a.dupe(Symbol, editor.symbols.items);
        const before_scopes = try a.dupe(Scope, editor.scopes.items);
        const owner_count = editor.scope_owner_map.count();
        const accepted = try editor.retireSelectedSourceOwnedFunctions(plan, &.{owner}, receipt);
        std.debug.print("BUFFER_PARENT_DYNAMIC case={d} scope={d} origin={d} source_refs={d} accepted={}\n", .{ case_index, @backingInt(symbol.scope_id), @backingInt(symbol.origin_scope), symbol.reference_count, accepted });
        try std.testing.expectEqual(case_index == 0, accepted);
        if (accepted) continue;
        try std.testing.expectEqualSlices(?u32, before_ids, editor.symbol_ids.items);
        try std.testing.expectEqualDeep(before_rows, editor.references.items);
        try std.testing.expectEqualDeep(before_symbols, editor.symbols.items);
        try std.testing.expectEqualDeep(before_scopes, editor.scopes.items);
        try std.testing.expectEqual(owner_count, editor.scope_owner_map.count());
    }
}

test "source function retirement includes only its actual named expression self frame" {
    const Mutation = enum { none, kind, parent, origin, map, owner, name_span, declaration_span, name_tag, foreign_sid };
    for ([_][]const u8{ "(function self(p){const local=p;return local});console.log(42);", "(function self(p){const local=arguments[0];return local});console.log(42);" }) |source| {
        inline for (std.meta.tags(Mutation)) |mutation| {
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            var scanner = try Scanner.init(a, source);
            var parser = @import("../parser/parser.zig").Parser.init(a, &scanner);
            parser.configureFromExtension(".js");
            const root = try parser.parse();
            var analyzer = @import("analyzer.zig").SemanticAnalyzer.init(a, &parser.ast);
            analyzer.enable_exact_declaration_anchors = true;
            analyzer.collect_unresolved_reference_nodes = true;
            try analyzer.analyze();
            var editor = try analyzer.beginEdit();
            var owner: NodeIndex = .none;
            for (parser.ast.nodes.items, 0..) |node, raw| if (node.tag == .function_expression) {
                owner = @fromBackingInt(@as(u32, @intCast(raw)));
            };
            const node = parser.ast.getNode(owner);
            const scope: ScopeId = @fromBackingInt(editor.scope_owner_map.get(@backingInt(owner)).?);
            const name = parser.ast.readExtraNode(node.data.extra, ast_mod.FunctionExtra.name);
            const sid = editor.symbol_ids.items[@backingInt(name)].?;
            const frame = editor.symbols.items[sid].scope_id;
            try std.testing.expectEqual(frame, editor.scopes.items[scope.toIndex()].parent);
            try std.testing.expectEqual(.block, editor.scopes.items[frame.toIndex()].kind);
            const body = parser.ast.readExtraNode(node.data.extra, ast_mod.FunctionExtra.body);
            const known: KnownUnreachableFunction = .{ .owner = owner, .scope = scope, .params = parser.ast.readExtraNode(node.data.extra, ast_mod.FunctionExtra.params), .body = body, .body_scope = if (editor.scope_owner_map.get(@backingInt(body))) |value| @fromBackingInt(value) else .none };
            // Remove the actual source expression statement edge, preserving the
            // function's immutable backing and every known declaration witness.
            const list = &parser.ast.nodes.items[@backingInt(root)].data.list;
            list.start += 1;
            list.len -= 1;
            switch (mutation) {
                .none => {},
                .kind => editor.scopes.items[frame.toIndex()].kind = .function,
                .parent => editor.scopes.items[frame.toIndex()].parent = .none,
                .origin => editor.symbols.items[sid].origin_scope = scope,
                .map => {
                    var values = editor.scope_maps.items[frame.toIndex()].valueIterator();
                    values.next().?.* = sid + 1;
                },
                .owner => try editor.scope_owner_map.put(a, @backingInt(name), frame.toIndex()),
                .name_span => editor.symbols.items[sid].name.end -= 1,
                .declaration_span => editor.symbols.items[sid].declaration_span.end -= 1,
                .name_tag => parser.ast.nodes.items[@backingInt(name)].tag = .identifier_reference,
                .foreign_sid => editor.symbol_ids.items[@backingInt(name)] = sid + 1,
            }
            try std.testing.expectEqual(mutation == .none, try editor.retireUnreachableFunctionSubtree(known));
            if (mutation == .none) {
                const retirement = @import("source_owned_retirement.zig");
                const live_nodes = try @import("../parser/ast_walk.zig").collectReachableNodeIndicesFrom(a, &parser.ast, root);
                var live = try std.DynamicBitSet.initEmpty(a, parser.ast.nodes.items.len);
                for (live_nodes) |raw| live.set(raw);
                try std.testing.expect(editor.source_owned_retirements.contains(sid));
                try std.testing.expect(try retirement.validate(a, &parser.ast, &editor.source_owned_retirements, &live, editor.symbols.items, editor.symbol_ids.items, editor.scopes.items, editor.scope_maps.items, &editor.scope_owner_map, editor.references.items, &editor.helper_scope_map, .{ .node_scope_provenance = &editor.node_scope_provenance }));
                const coverage = @import("../transformer/symbol_coverage.zig");
                const empty_nodes: std.AutoHashMapUnmanaged(u32, void) = .empty;
                const empty_origins: std.AutoHashMapUnmanaged(u32, u32) = .empty;
                const legacy = try coverage.checkExactQuiet(a, &parser.ast, root, @intCast(parser.ast.nodes.items.len), editor.symbol_ids.items, editor.symbols.items, editor.scopes.items, editor.scope_maps.items, &editor.scope_owner_map, editor.references.items, &.{}, &editor.helper_scope_map, &analyzer.unresolved_reference_nodes, &empty_nodes, &empty_origins, .{ .pre_transform_scope_count = editor.scopes.items.len });
                try std.testing.expectEqual(editor.source_owned_retirements.count(), legacy.scope_map_mismatch);
                try std.testing.expect(!legacy.isClean());
                var legacy_strict = try coverage.checkOutputSymbolIdentity(a, &parser.ast, root, @intCast(parser.ast.nodes.items.len), editor.symbol_ids.items, editor.symbols.items, editor.scopes.items, &editor.scope_owner_map, editor.references.items, .{ .unresolved_reference_nodes = &analyzer.unresolved_reference_nodes, .explicit_global_reference_nodes = &empty_nodes, .reference_origin_map = &empty_origins }, null);
                defer legacy_strict.deinit(a);
                var retired_arguments: usize = 0;
                var retired_it = editor.source_owned_retirements.valueIterator();
                while (retired_it.next()) |entry| if (entry.before.synthetic_kind == .implicit_arguments) {
                    retired_arguments += 1;
                };
                try std.testing.expectEqual(retired_arguments, legacy_strict.orphan_symbols);
                var normal = try coverage.checkOutputNormalFormQuiet(a, &parser.ast, root, @intCast(parser.ast.nodes.items.len), editor.symbol_ids.items, editor.symbols.items, editor.scopes.items, editor.scope_maps.items, &editor.scope_owner_map, editor.references.items, &.{}, &editor.helper_scope_map, &analyzer.unresolved_reference_nodes, &empty_nodes, &empty_origins, .{ .pre_transform_scope_count = editor.scopes.items.len }, &editor.source_owned_retirements, .{ .node_scope_provenance = &editor.node_scope_provenance });
                defer normal.deinit(a);
                try std.testing.expectEqual(@as(usize, 0), normal.retirement_state_mismatch);
                try std.testing.expectEqual(@as(usize, 0), normal.strict.orphan_symbols);
                try std.testing.expect(normal.exact.isClean());
                try std.testing.expect(normal.hasCompleteOutputIdentityBeforeNames());
                const witness = editor.source_owned_retirements.get(sid).?;
                editor.source_owned_retirements.getPtr(sid).?.before.origin_scope = scope;
                try std.testing.expect(!try retirement.validate(a, &parser.ast, &editor.source_owned_retirements, &live, editor.symbols.items, editor.symbol_ids.items, editor.scopes.items, editor.scope_maps.items, &editor.scope_owner_map, editor.references.items, &editor.helper_scope_map, .{ .node_scope_provenance = &editor.node_scope_provenance }));
                editor.source_owned_retirements.getPtr(sid).?.* = witness;
                editor.symbol_ids.items[@backingInt(name)] = sid;
                try std.testing.expect(!try retirement.validate(a, &parser.ast, &editor.source_owned_retirements, &live, editor.symbols.items, editor.symbol_ids.items, editor.scopes.items, editor.scope_maps.items, &editor.scope_owner_map, editor.references.items, &editor.helper_scope_map, .{ .node_scope_provenance = &editor.node_scope_provenance }));
                editor.symbol_ids.items[@backingInt(name)] = null;
                editor.scopes.items[frame.toIndex()].subtree_has_direct_eval = true;
                try std.testing.expect(!try retirement.validate(a, &parser.ast, &editor.source_owned_retirements, &live, editor.symbols.items, editor.symbol_ids.items, editor.scopes.items, editor.scope_maps.items, &editor.scope_owner_map, editor.references.items, &editor.helper_scope_map, .{ .node_scope_provenance = &editor.node_scope_provenance }));
                editor.scopes.items[frame.toIndex()].subtree_has_direct_eval = false;
                try editor.node_scope_provenance.put(a, name, .{ .scope = scope, .source_node = name });
                try std.testing.expect(!try retirement.validate(a, &parser.ast, &editor.source_owned_retirements, &live, editor.symbols.items, editor.symbol_ids.items, editor.scopes.items, editor.scope_maps.items, &editor.scope_owner_map, editor.references.items, &editor.helper_scope_map, .{ .node_scope_provenance = &editor.node_scope_provenance }));
                _ = editor.node_scope_provenance.remove(name);
                try editor.scope_owner_map.put(a, @backingInt(name), scope.toIndex());
                try std.testing.expect(!try retirement.validate(a, &parser.ast, &editor.source_owned_retirements, &live, editor.symbols.items, editor.symbol_ids.items, editor.scopes.items, editor.scope_maps.items, &editor.scope_owner_map, editor.references.items, &editor.helper_scope_map, .{ .node_scope_provenance = &editor.node_scope_provenance }));
                _ = editor.scope_owner_map.remove(@backingInt(name));
                try std.testing.expect(!try retirement.validate(a, &parser.ast, &editor.source_owned_retirements, &live, editor.symbols.items, editor.symbol_ids.items, editor.scopes.items, editor.scope_maps.items, &editor.scope_owner_map, editor.references.items, &editor.helper_scope_map, .{ .symbol_ids = &.{sid}, .node_scope_provenance = &editor.node_scope_provenance }));
                analyzer.applyEdit(try editor.finish());
                const repeated = try analyzer.beginEdit();
                try std.testing.expectEqualDeep(witness.before, repeated.source_owned_retirements.get(sid).?.before);
                try std.testing.expect(try retirement.validate(a, &parser.ast, &repeated.source_owned_retirements, &live, repeated.symbols.items, repeated.symbol_ids.items, repeated.scopes.items, repeated.scope_maps.items, &repeated.scope_owner_map, repeated.references.items, &repeated.helper_scope_map, .{ .node_scope_provenance = &repeated.node_scope_provenance }));
                var data: @import("../bundler/module.zig").ModuleSemanticData = .{
                    .symbols = analyzer.symbols,
                    .scopes = analyzer.scopes.items,
                    .scope_maps = analyzer.scope_maps.items,
                    .scope_owner_map = analyzer.scope_owner_map,
                    .symbol_ids = analyzer.symbol_ids.items,
                    .references = analyzer.references.items,
                    .exported_names = analyzer.exported_names,
                    .unresolved_references = analyzer.unresolved_references,
                    .helper_scope_map = analyzer.helper_scope_map,
                    .node_scope_provenance = analyzer.node_scope_provenance,
                    .source_owned_retirements = analyzer.source_owned_retirements,
                };
                var wire: std.ArrayList(u8) = .empty;
                try @import("../bundler/semantic_codec.zig").serialize(&data, &wire, a);
                var decoded = try @import("../bundler/semantic_codec.zig").deserialize(wire.items, a);
                var cached_edit = try decoded.beginEdit(a, &parser.ast);
                decoded.applyEdit(try cached_edit.finish());
                try std.testing.expect(retirement.equalSymbol(witness.before, decoded.source_owned_retirements.get(sid).?.before));
                try std.testing.expect(try retirement.validate(a, &parser.ast, &decoded.source_owned_retirements, &live, decoded.symbols.items, decoded.symbol_ids, decoded.scopes, decoded.scope_maps, &decoded.scope_owner_map, decoded.references, &decoded.helper_scope_map, .{ .node_scope_provenance = &decoded.node_scope_provenance }));
            }
        }
    }
}
