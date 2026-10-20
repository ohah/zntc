//! AST Plugin 타입 + 유틸리티
//!
//! Plugin(plugin.zig)의 AST 훅(onFunction 등)이 사용하는 타입과 컨텍스트.
//! FunctionInfo, AstTransformCtx를 정의하고, 플러그인이 AST를 안전하게 조작하는 API를 제공.
//!
//! 사용 예:
//!   const plugins = [_]Plugin{ worklet_plugin.plugin() };
//!   var t = Transformer.init(alloc, ast, .{ .plugins = &plugins });

const std = @import("std");
const ast_mod = @import("../parser/ast.zig");
const Node = ast_mod.Node;
const Tag = Node.Tag;
pub const NodeIndex = ast_mod.NodeIndex;
const NodeList = ast_mod.NodeList;
const Ast = ast_mod.Ast;
const Scanner = @import("../lexer/scanner.zig").Scanner;
const token_mod = @import("../lexer/token.zig");
const Span = token_mod.Span;
const ScopeId = @import("../semantic/scope.zig").ScopeId;
const symbol_mod = @import("../semantic/symbol.zig");
const SymbolId = symbol_mod.SymbolId;
const SymbolKind = symbol_mod.SymbolKind;
const ast_walk = @import("../parser/ast_walk.zig");

// forward declaration — transformer.zig에서 실제 타입을 import
const transformer_mod = @import("transformer.zig");
const Transformer = transformer_mod.Transformer;
const Error = Transformer.Error;

// worklet 유틸리티 (기존 코드 재사용)
pub const worklet_mod = @import("transformer/worklet.zig");

// ================================================================
// FunctionInfo — 읽기 전용 함수 정보
// ================================================================

/// onFunction 훅에 전달되는 함수 노드 정보.
/// 읽기 전용 — 수정은 AstTransformCtx API를 통해 수행.
pub const FunctionInfo = struct {
    /// 변환된 함수 노드의 인덱스
    node_idx: NodeIndex,
    /// 노드 태그 (function_declaration / function_expression / arrow_function_expression)
    node_tag: Tag,
    /// 함수 이름 (null = 익명 함수/화살표)
    name: ?[]const u8,
    /// 함수 body 노드 인덱스 (변환 후)
    body_idx: NodeIndex,
    /// 파라미터 리스트 (변환 후) — formal_parameters 노드의 NodeList
    params: ast_mod.NodeList,
    /// 원본 (변환 전) — Babel과 동일하게 변환 전 AST로 closure 분석
    original_params: ast_mod.NodeList,
    original_body_idx: NodeIndex,
    /// 함수 플래그 (bit 0=async, bit 1=generator)
    flags: u32,
    /// 소스 파일 경로 (__initData.location 등에 사용)
    source_path: []const u8,
    /// auto-workletization으로 활성화된 경우 true.
    /// 'worklet' 디렉티브 없이도 worklet 변환이 필요한 함수.
    is_auto_worklet: bool = false,
};

// ================================================================
// AstTransformCtx — 플러그인 API
// ================================================================

/// AST 변환 컨텍스트.
/// 플러그인이 AST를 안전하게 읽고/쓰는 API를 제공한다.
/// 내부적으로 Transformer를 위임 호출하므로 별도 상태를 가지지 않는다.
pub const AstTransformCtx = struct {
    transformer: *Transformer,
    /// `onFunction` trailing statements execute beside the function, so their
    /// references resolve in the exact lexical scope that owns that list.
    insertion_scope: ScopeId = .none,

    /// 플러그인이 body를 수정한 경우 새 body 인덱스.
    /// dispatcher가 이 값을 확인하여 result 노드의 extra_data를 패치한다.
    modified_body: ?NodeIndex = null,

    /// 플러그인이 함수 노드 전체를 교체한 경우 새 노드 인덱스.
    /// function_expression worklet → IIFE factory 변환 등에 사용.
    replaced_node: ?NodeIndex = null,

    /// 현재 함수 방문의 closure 분석 캐시.
    /// 여러 플러그인(worklet_plugin, napi_entry 등)이 같은 closure 결과를 공유한다.
    /// ctx 소유권 — dispatcher가 종료 시 deinitClosureCache() 호출로 해제.
    closure_cache: ?struct {
        /// 캐시 대상 함수 식별자 — 향후 ctx 재사용 시 다른 함수 요청을 자동 재계산하도록.
        node_idx: NodeIndex,
        vars: []const worklet_mod.ClosureVar,
    } = null,

    // --- 디렉티브 ---

    /// 함수 body의 첫 문장이 지정된 디렉티브인지 확인.
    /// 예: hasDirective(body, "worklet") → true/false
    pub fn hasDirective(self: *AstTransformCtx, body_idx: NodeIndex, directive: []const u8) bool {
        return worklet_mod.isWorkletDirectiveGeneric(self.transformer, body_idx, directive);
    }

    /// 함수 body에서 첫 디렉티브 문장을 제거한 새 body를 반환.
    /// 동시에 modified_body를 설정하여 dispatcher가 result 노드를 패치할 수 있게 한다.
    pub fn stripDirective(self: *AstTransformCtx, body_idx: NodeIndex) Error!NodeIndex {
        const new_body = try worklet_mod.stripWorkletDirective(self.transformer, body_idx);
        self.modified_body = new_body;
        return new_body;
    }

    // --- 스코프 분석 ---

    /// 함수의 closure 변수(외부 참조)를 추출.
    /// 항상 **변환 전 원본** body/params로 분석 (Babel 호환) — 호출부 실수 방지.
    /// 같은 ctx에서 반복 호출 시 캐시 반환 (issue #1114).
    /// 반환된 슬라이스는 ctx가 소유 — 호출부가 free하지 말 것.
    pub fn getClosureVars(
        self: *AstTransformCtx,
        info: *const FunctionInfo,
    ) Error![]const worklet_mod.ClosureVar {
        if (self.closure_cache) |cached| {
            if (cached.node_idx == info.node_idx) return cached.vars;
            // 다른 함수 요청 — 기존 캐시 해제 후 재계산
            self.deinitClosureCache();
        }
        const vars = try worklet_mod.collectClosureVars(
            self.transformer,
            info.original_body_idx,
            info.original_params,
            if (info.node_tag == .method_definition) null else info.name,
        );
        self.closure_cache = .{ .node_idx = info.node_idx, .vars = vars };
        return vars;
    }

    /// 캐시된 closure 결과 해제. dispatcher가 dispatchFunctionPlugins 종료 시 호출.
    pub fn deinitClosureCache(self: *AstTransformCtx) void {
        if (self.closure_cache) |cached| {
            const alloc = self.getAllocator();
            for (cached.vars) |cv| {
                alloc.free(cv.name);
                if (cv.class_factory_base) |b| alloc.free(b);
                if (cv.closure_key) |key| alloc.free(key);
            }
            alloc.free(cached.vars);
            self.closure_cache = null;
        }
    }

    // --- AST 노드 생성 (Transformer/Ast 위임) ---

    pub fn addNode(self: *AstTransformCtx, node: Node) Error!NodeIndex {
        return self.transformer.ast.addNode(node);
    }

    /// Register an identifier-only var/let/const binding created by a plugin
    /// in the exact lexical scope that owns this function's trailing list.
    /// A graphless transformer has no SymbolId to return; when semantic output
    /// is enabled, a missing insertion scope is an invariant violation.
    pub fn registerSyntheticBinding(self: *AstTransformCtx, binding: NodeIndex, kind: SymbolKind) Error!?SymbolId {
        const transformer = self.transformer;
        if (!transformer.semantic_edit_enabled) return null;
        if (self.insertion_scope.isNone())
            std.debug.panic("plugin-generated binding has no exact insertion ScopeId", .{});

        const node = transformer.ast.getNode(binding);
        if (node.tag != .binding_identifier)
            std.debug.panic("plugin-generated binding registration requires an identifier node", .{});

        switch (kind) {
            .variable_var, .variable_let, .variable_const => {},
            else => std.debug.panic("plugin trailing binding has an unsupported SymbolKind", .{}),
        }

        // The parsed plugin snippet may use an escaped spelling such as
        // `\\u0078`. Normalize the binding before it enters the semantic
        // scope map so equivalent spellings share the same producer identity.
        const raw_name = transformer.ast.getText(node.data.string_ref);
        var decode_buffer: [256]u8 = undefined;
        if (Scanner.decodeIdentifierEscapesInto(raw_name, &decode_buffer)) |decoded_name| {
            if (!std.mem.eql(u8, raw_name, decoded_name)) {
                const normalized_span = try transformer.ast.addString(decoded_name);
                transformer.ast.nodes.items[@backingInt(binding)].span = normalized_span;
                transformer.ast.nodes.items[@backingInt(binding)].data.string_ref = normalized_span;
            }
        }
        const name_span = transformer.ast.getNode(binding).data.string_ref;
        const name = transformer.ast.getText(name_span);

        // Keep the source lexical scope as origin_scope. SemanticEditor moves
        // `var` to its nearest var owner while preserving that origin.
        const expected_owner = if (kind == .variable_var)
            transformer.nearestVarScope(self.insertion_scope)
        else
            self.insertion_scope;
        var reused_var_symbol = false;
        const symbol_id = blk: {
            if (kind == .variable_var) {
                const scopes = if (transformer.semantic_editor) |*editor| editor.scopes.items else transformer.scopes;
                const scope_maps = if (transformer.semantic_editor) |*editor| editor.scope_maps.items else transformer.scope_maps;
                const symbols = if (transformer.semantic_editor) |*editor| editor.symbols.items else transformer.symbols;
                if (expected_owner.toIndex() >= scopes.len or expected_owner.toIndex() >= scope_maps.len)
                    std.debug.panic("plugin-generated var has an invalid owner ScopeId", .{});
                if (scope_maps[expected_owner.toIndex()].get(name)) |raw_id| {
                    if (raw_id >= symbols.len) std.debug.panic("plugin-generated var found an invalid SymbolId", .{});
                    const symbol = symbols[raw_id];
                    if (symbol.scope_id != expected_owner)
                        std.debug.panic("plugin-generated var scope map points outside its owner", .{});
                    const existing_name = if (symbol.synthetic_name.len > 0)
                        symbol.synthetic_name
                    else
                        transformer.ast.getText(symbol.name);
                    if (!Scanner.identifierNamesEqual(existing_name, name))
                        std.debug.panic("plugin-generated var scope map name does not match its SymbolId", .{});
                    const can_redeclare = symbol.kind == .parameter or symbol.kind == .variable_var or symbol.kind.isFunctionLike();
                    if (can_redeclare) {
                        if (raw_id > std.math.maxInt(u32))
                            std.debug.panic("plugin-generated var SymbolId exceeds its representation", .{});
                        const existing_id: SymbolId = @fromBackingInt(@intCast(raw_id));
                        try transformer.bindSyntheticVarRedeclaration(binding, existing_id, self.insertion_scope);
                        reused_var_symbol = true;
                        break :blk existing_id;
                    }
                }
            }
            break :blk (try transformer.declareSyntheticInScope(binding, node.span, kind, self.insertion_scope)) orelse return null;
        };
        const editor = if (transformer.semantic_editor) |*semantic_editor| semantic_editor else std.debug.panic("plugin-generated binding lost its semantic editor", .{});
        const raw_symbol_id: usize = @intCast(@backingInt(symbol_id));
        if (raw_symbol_id >= editor.symbols.items.len)
            std.debug.panic("plugin-generated binding has an invalid SymbolId", .{});
        const symbol = editor.symbols.items[raw_symbol_id];
        if (symbol.scope_id != expected_owner or (!reused_var_symbol and symbol.origin_scope != self.insertion_scope))
            std.debug.panic("plugin-generated binding has an inexact producer ScopeId", .{});
        return symbol_id;
    }

    /// Attach a plugin-created reference to the exact SymbolId returned by
    /// `registerSyntheticBinding`; this avoids a later name-based lookup.
    pub fn bindReferenceToSymbol(self: *AstTransformCtx, reference: NodeIndex, symbol_id: SymbolId) Error!void {
        if (!self.transformer.semantic_edit_enabled) return;
        const tag = self.transformer.ast.getNode(reference).tag;
        switch (tag) {
            .identifier_reference, .assignment_target_identifier, .jsx_identifier => {},
            else => std.debug.panic("plugin exact reference registration requires an identifier reference", .{}),
        }
        try self.transformer.trackExactOutputReference(reference, @backingInt(symbol_id));
    }

    pub fn addString(self: *AstTransformCtx, text: []const u8) Error!Span {
        return self.transformer.ast.addString(text);
    }

    pub fn addExtraNode(self: *AstTransformCtx, tag: Tag, span: Span, extras: []const u32) Error!NodeIndex {
        return self.transformer.addExtraNode(tag, span, extras);
    }

    pub fn addNodeList(self: *AstTransformCtx, items: []const NodeIndex) Error!NodeList {
        return self.transformer.ast.addNodeList(items);
    }

    // --- 코드 삽입 ---

    /// 현재 노드 뒤에 문장을 삽입한다.
    /// visitExtraList의 trailing_nodes 메커니즘을 통해 부모 리스트에 추가.
    pub fn addTrailingStatement(self: *AstTransformCtx, stmt: NodeIndex) Error!void {
        try self.transformer.trailing_nodes.append(self.transformer.allocator, stmt);
    }

    /// body 앞에 문장들을 삽입한 새 body를 반환.
    pub fn prependToBody(self: *AstTransformCtx, body: NodeIndex, stmts: []const NodeIndex) Error!NodeIndex {
        return self.transformer.prependStatementsToBody(body, stmts);
    }

    // --- AST 읽기 ---

    pub fn getNode(self: *AstTransformCtx, idx: NodeIndex) Node {
        return self.transformer.ast.getNode(idx);
    }

    pub fn getText(self: *AstTransformCtx, span: Span) []const u8 {
        return self.transformer.ast.getText(span);
    }

    pub fn getSource(self: *AstTransformCtx) []const u8 {
        return self.transformer.ast.source;
    }

    pub fn getAllocator(self: *AstTransformCtx) std.mem.Allocator {
        return self.transformer.allocator;
    }

    // --- 코드 파싱 (JS AST 플러그인용) ---

    /// 코드 문자열을 파싱하여 statement NodeIndex 배열을 반환한다.
    /// JS AST 플러그인의 trailingCode 문자열을 AST 노드로 변환하는 데 사용.
    /// 반환된 슬라이스는 caller가 getAllocator().free()로 해제해야 한다.
    pub fn parseAndInjectStatements(self: *AstTransformCtx, code: []const u8) Error![]const NodeIndex {
        const Parser = @import("../parser/parser.zig").Parser;
        const alloc = self.transformer.allocator;

        const scanner_ptr = alloc.create(Scanner) catch return error.OutOfMemory;
        scanner_ptr.* = Scanner.init(alloc, code) catch return error.OutOfMemory;
        defer {
            scanner_ptr.deinit();
            alloc.destroy(scanner_ptr);
        }

        const parser_ptr = alloc.create(Parser) catch return error.OutOfMemory;
        parser_ptr.* = Parser.init(alloc, scanner_ptr);
        defer {
            parser_ptr.deinit();
            alloc.destroy(parser_ptr);
        }

        _ = parser_ptr.parse() catch return error.OutOfMemory;

        const root_idx = parser_ptr.ast.nodes.items.len - 1;
        const root = parser_ptr.ast.nodes.items[root_idx];
        if (root.tag != .program) return &.{};

        const list = root.data.list;
        if (list.len == 0) return &.{};

        // 파싱된 노드를 transformer의 AST에 복사
        var result = alloc.alloc(NodeIndex, list.len) catch return error.OutOfMemory;
        errdefer alloc.free(result);
        var count: usize = 0;
        var si: u32 = 0;
        while (si < list.len) : (si += 1) {
            const stmt_raw = parser_ptr.ast.extra_data.items[list.start + si];
            const stmt_idx: NodeIndex = @fromBackingInt(@intCast(stmt_raw));
            if (stmt_idx.isNone()) continue;

            // 파싱된 AST의 노드를 transformer AST에 복사
            const copied = self.copyNodeFromParsedAst(&parser_ptr.ast, stmt_idx) catch continue;
            if (copied.isNone()) continue;
            result[count] = copied;
            count += 1;
        }

        if (count == 0) {
            alloc.free(result);
            return &.{};
        }

        var generated_symbols: std.StringHashMapUnmanaged(SymbolId) = .empty;
        var generated_symbol_names: std.ArrayList([]const u8) = .empty;
        defer {
            generated_symbols.deinit(alloc);
            for (generated_symbol_names.items) |name| alloc.free(name);
            generated_symbol_names.deinit(alloc);
        }

        // Register every generated declaration before binding any reference
        // in the snippet. This preserves forward references and TDZ identity
        // when a plugin injects multiple statements at once.
        for (result[0..count]) |statement| try self.registerInjectedDeclarations(statement, &generated_symbols, &generated_symbol_names);
        for (result[0..count]) |statement| try self.bindInjectedReferences(statement, &generated_symbols);
        return result[0..count];
    }

    fn registerInjectedDeclarations(
        self: *AstTransformCtx,
        root: NodeIndex,
        generated_symbols: *std.StringHashMapUnmanaged(SymbolId),
        generated_symbol_names: *std.ArrayList([]const u8),
    ) Error!void {
        if (!self.transformer.semantic_edit_enabled) return;
        if (self.insertion_scope.isNone())
            std.debug.panic("plugin trailing code has no exact insertion ScopeId", .{});

        const reachable = try ast_walk.collectReachableNodeIndicesFrom(self.transformer.allocator, self.transformer.ast, root);
        defer self.transformer.allocator.free(reachable);

        for (reachable) |raw| {
            if (raw >= self.transformer.ast.nodes.items.len) continue;
            const declaration = self.transformer.ast.nodes.items[raw];
            if (declaration.tag != .variable_declaration) continue;

            const symbol_kind: SymbolKind = switch (self.transformer.ast.variableDeclarationKind(declaration)) {
                .@"var" => .variable_var,
                .let => .variable_let,
                .@"const" => .variable_const,
                .using, .await_using => std.debug.panic("using declarations are unsupported in plugin trailing code", .{}),
            };
            const extra = declaration.data.extra;
            const start = self.transformer.ast.extra_data.items[extra + 1];
            const len = self.transformer.ast.extra_data.items[extra + 2];
            var i: u32 = 0;
            while (i < len) : (i += 1) {
                const declarator_raw = self.transformer.ast.extra_data.items[start + i];
                if (declarator_raw >= self.transformer.ast.nodes.items.len)
                    std.debug.panic("plugin trailing declaration has an invalid declarator", .{});
                const declarator = self.transformer.ast.nodes.items[declarator_raw];
                if (declarator.tag != .variable_declarator)
                    std.debug.panic("plugin trailing declaration has an unsupported declarator", .{});
                const binding = self.transformer.ast.readExtraNode(declarator.data.extra, 0);
                const symbol_id = (try self.registerSyntheticBinding(binding, symbol_kind)) orelse
                    std.debug.panic("plugin trailing declaration lost its exact SymbolId", .{});
                const name = self.transformer.ast.getText(self.transformer.ast.getNode(binding).data.string_ref);
                const stable_name = try self.transformer.allocator.dupe(u8, name);
                generated_symbol_names.append(self.transformer.allocator, stable_name) catch {
                    self.transformer.allocator.free(stable_name);
                    return error.OutOfMemory;
                };
                try generated_symbols.put(self.transformer.allocator, stable_name, symbol_id);
            }
        }
    }

    /// Collect only identifier nodes that occur in lexical reference positions.
    /// The parser also tags static member and object property names as
    /// `identifier_reference`; those names must not resolve to lexical symbols.
    fn collectInjectedReferenceNodeIndices(self: *AstTransformCtx, root: NodeIndex) Error![]u32 {
        const transformer = self.transformer;
        const allocator = transformer.allocator;
        const ast = transformer.ast;
        if (root.isNone() or ast.nodes.items.len == 0) return &.{};

        var visited = try allocator.alloc(bool, ast.nodes.items.len);
        defer allocator.free(visited);
        @memset(visited, false);

        var references: std.ArrayList(u32) = .empty;
        errdefer references.deinit(allocator);
        var stack: std.ArrayList(NodeIndex) = .empty;
        defer stack.deinit(allocator);
        try stack.append(allocator, root);

        while (stack.pop()) |idx| {
            if (idx.isNone()) continue;
            const raw = @backingInt(idx);
            if (raw >= ast.nodes.items.len or visited[raw]) continue;
            visited[raw] = true;

            const node = ast.nodes.items[raw];
            switch (node.tag) {
                .identifier_reference, .assignment_target_identifier, .jsx_identifier => {
                    try references.append(allocator, raw);
                    continue;
                },
                .static_member_expression => {
                    // Its first extra is the object and its second extra is the
                    // IdentifierName property. Only the object is an expression.
                    const extra = node.data.extra;
                    if (extra < ast.extra_data.items.len) {
                        const object: NodeIndex = @fromBackingInt(@intCast(ast.extra_data.items[extra]));
                        if (!object.isNone()) try stack.append(allocator, object);
                    }
                    continue;
                },
                .object_property => {
                    // Match semantic analysis: `{foo}` uses foo as a lexical
                    // reference, `{foo: value}` uses only value, and `{[key]:
                    // value}` evaluates both the computed key and the value.
                    const key = node.data.binary.left;
                    const value = node.data.binary.right;
                    if (!key.isNone()) {
                        const key_node = ast.getNode(key);
                        if (value.isNone() or key_node.tag == .computed_property_key)
                            try stack.append(allocator, key);
                    }
                    if (!value.isNone()) try stack.append(allocator, value);
                    continue;
                },
                else => {},
            }

            var children = ast_walk.children(ast, node);
            while (children.next()) |child| {
                if (!child.isNone() and @backingInt(child) < ast.nodes.items.len)
                    try stack.append(allocator, child);
            }
        }

        return references.toOwnedSlice(allocator);
    }

    /// Bind references parsed from plugin text at the scope where the
    /// trailing statement is inserted. The spelling is used once here to
    /// resolve the source binding; all later consumers receive its exact ID.
    fn bindInjectedReferences(
        self: *AstTransformCtx,
        root: NodeIndex,
        generated_symbols: *const std.StringHashMapUnmanaged(SymbolId),
    ) Error!void {
        const transformer = self.transformer;
        if (self.insertion_scope.isNone()) {
            // Graphless transformer calls have no lexical identity contract.
            // A semantic edit, however, cannot silently lose this owner.
            if (transformer.semantic_edit_enabled)
                std.debug.panic("plugin trailing code has no exact insertion ScopeId", .{});
            return;
        }

        const scopes = if (transformer.semantic_editor) |*editor| editor.scopes.items else transformer.scopes;
        const scope_maps = if (transformer.semantic_editor) |*editor| editor.scope_maps.items else transformer.scope_maps;
        if (self.insertion_scope.toIndex() >= scopes.len or self.insertion_scope.toIndex() >= scope_maps.len)
            std.debug.panic("plugin trailing code has an invalid insertion ScopeId", .{});

        const references = try self.collectInjectedReferenceNodeIndices(root);
        defer transformer.allocator.free(references);

        for (references) |raw| {
            if (raw >= transformer.ast.nodes.items.len) continue;
            const reference: NodeIndex = @fromBackingInt(@intCast(raw));
            const node = transformer.ast.nodes.items[raw];

            const raw_name = transformer.ast.getText(node.data.string_ref);
            var decode_buffer: [256]u8 = undefined;
            var name = raw_name;
            if (Scanner.decodeIdentifierEscapesInto(raw_name, &decode_buffer)) |decoded_name| {
                if (!std.mem.eql(u8, raw_name, decoded_name)) {
                    const normalized_span = try transformer.ast.addString(decoded_name);
                    transformer.ast.nodes.items[raw].span = normalized_span;
                    transformer.ast.nodes.items[raw].data.string_ref = normalized_span;
                    name = decoded_name;
                }
            }
            if (generated_symbols.get(name)) |symbol_id| {
                try self.bindReferenceToSymbol(reference, symbol_id);
            } else if (transformer.lexicalSymbolIdAtScope(name, self.insertion_scope)) |raw_id| {
                if (transformer.semantic_edit_enabled) {
                    try transformer.trackExactOutputReference(reference, raw_id);
                } else {
                    if (transformer.symbol_ids.items.len <= raw)
                        try transformer.symbol_ids.appendNTimes(transformer.allocator, null, raw + 1 - transformer.symbol_ids.items.len);
                    if (transformer.symbol_ids.items[raw]) |existing| {
                        if (existing != raw_id) std.debug.panic("plugin trailing reference changed SymbolId", .{});
                    } else transformer.symbol_ids.items[raw] = raw_id;
                }
            } else {
                try transformer.markExplicitGlobalReference(reference);
            }
        }
    }

    /// 파싱된 AST에서 노드를 재귀적으로 transformer AST에 복사한다.
    fn copyNodeFromParsedAst(self: *AstTransformCtx, src_ast: *const Ast, src_idx: NodeIndex) Error!NodeIndex {
        if (src_idx.isNone()) return .none;
        const src_node = src_ast.nodes.items[@backingInt(src_idx)];

        // 소스 텍스트 참조 → string_table로 복사 (span이 src_ast.source를 참조하므로)
        var new_span = src_node.span;
        if (src_node.span.start & ast_mod.Ast.STRING_TABLE_BIT == 0 and
            src_node.span.start < src_node.span.end and
            src_node.span.end <= @as(u32, @intCast(src_ast.source.len)))
        {
            const text = src_ast.source[src_node.span.start..src_node.span.end];
            new_span = self.transformer.ast.addString(text) catch return error.OutOfMemory;
        }

        // data 복사는 태그에 따라 다름 — 간단한 노드만 지원
        return switch (src_node.tag) {
            // 리프 노드: data를 그대로 복사하되 span 갱신
            .identifier_reference,
            .binding_identifier,
            .string_literal,
            .numeric_literal,
            .boolean_literal,
            .null_literal,
            .this_expression,
            => self.transformer.ast.addNode(.{
                .tag = src_node.tag,
                .span = new_span,
                .data = .{ .string_ref = new_span },
            }),

            // 단항: operand 재귀 복사
            .expression_statement,
            .return_statement,
            .throw_statement,
            => blk: {
                const new_operand = try self.copyNodeFromParsedAst(src_ast, src_node.data.unary.operand);
                break :blk self.transformer.ast.addNode(.{
                    .tag = src_node.tag,
                    .span = new_span,
                    .data = .{ .unary = .{ .operand = new_operand, .flags = src_node.data.unary.flags } },
                });
            },

            // 이항: left/right 재귀 복사
            .assignment_expression,
            .binary_expression,
            .object_property,
            => blk: {
                const new_left = try self.copyNodeFromParsedAst(src_ast, src_node.data.binary.left);
                const new_right = try self.copyNodeFromParsedAst(src_ast, src_node.data.binary.right);
                break :blk self.transformer.ast.addNode(.{
                    .tag = src_node.tag,
                    .span = new_span,
                    .data = .{ .binary = .{ .left = new_left, .right = new_right, .flags = src_node.data.binary.flags } },
                });
            },

            // 리스트: 각 요소 재귀 복사
            .object_expression,
            .array_expression,
            .sequence_expression,
            => blk: {
                const src_list = src_node.data.list;
                const scratch_top = self.transformer.scratch.items.len;
                defer self.transformer.scratch.shrinkRetainingCapacity(scratch_top);
                var i: u32 = 0;
                while (i < src_list.len) : (i += 1) {
                    const elem_raw = src_ast.extra_data.items[src_list.start + i];
                    const copied = try self.copyNodeFromParsedAst(src_ast, @fromBackingInt(@intCast(elem_raw)));
                    try self.transformer.scratch.append(self.transformer.allocator, copied);
                }
                const new_list = try self.transformer.ast.addNodeList(
                    self.transformer.scratch.items[scratch_top..],
                );
                break :blk self.transformer.ast.addNode(.{
                    .tag = src_node.tag,
                    .span = new_span,
                    .data = .{ .list = new_list },
                });
            },

            // Computed object property names contain an expression whose
            // lexical references must survive the plugin AST copy.
            .computed_property_key => blk: {
                const operand = try self.copyNodeFromParsedAst(src_ast, src_node.data.unary.operand);
                break :blk self.transformer.ast.addNode(.{
                    .tag = .computed_property_key,
                    .span = new_span,
                    .data = .{ .unary = .{ .operand = operand, .flags = src_node.data.unary.flags } },
                });
            },

            // Identifier-only var/let/const declarations. Keeping the binding
            // node in the copied AST lets insertion-scope registration attach
            // its producer-selected SymbolId before references are resolved.
            .variable_declaration => blk: {
                const kind = src_ast.variableDeclarationKind(src_node);
                if (kind != .@"var" and kind != .let and kind != .@"const") break :blk .none;
                const e = src_node.data.extra;
                if (e > src_ast.extra_data.items.len or src_ast.extra_data.items.len - e < 3) break :blk .none;
                const src_start = src_ast.extra_data.items[e + 1];
                const src_len = src_ast.extra_data.items[e + 2];
                if (src_start > src_ast.extra_data.items.len or src_len > src_ast.extra_data.items.len - src_start)
                    break :blk .none;

                var i: u32 = 0;
                while (i < src_len) : (i += 1) {
                    const raw = src_ast.extra_data.items[src_start + i];
                    if (raw >= src_ast.nodes.items.len) break :blk .none;
                    const declarator = src_ast.nodes.items[raw];
                    if (declarator.tag != .variable_declarator) break :blk .none;
                    const de = declarator.data.extra;
                    if (de > src_ast.extra_data.items.len or src_ast.extra_data.items.len - de < 3)
                        break :blk .none;
                    const binding = src_ast.readExtraNode(de, 0);
                    if (binding.isNone() or src_ast.getNode(binding).tag != .binding_identifier or
                        !src_ast.readExtraNode(de, 1).isNone()) break :blk .none;
                }

                const scratch_top = self.transformer.scratch.items.len;
                defer self.transformer.scratch.shrinkRetainingCapacity(scratch_top);
                i = 0;
                while (i < src_len) : (i += 1) {
                    const raw = src_ast.extra_data.items[src_start + i];
                    const copied = try self.copyNodeFromParsedAst(src_ast, @fromBackingInt(@intCast(raw)));
                    if (copied.isNone()) break :blk .none;
                    try self.transformer.scratch.append(self.transformer.allocator, copied);
                }
                const list = try self.transformer.ast.addNodeList(self.transformer.scratch.items[scratch_top..]);
                const extra = try self.transformer.ast.addExtras(&.{
                    src_ast.extra_data.items[e],
                    list.start,
                    list.len,
                });
                break :blk self.transformer.ast.addNode(.{
                    .tag = .variable_declaration,
                    .span = new_span,
                    .data = .{ .extra = extra },
                });
            },

            // A variable declarator's binding and initializer are copied
            // independently. Type annotations are rejected because plugin
            // trailing code is parsed as JavaScript.
            .variable_declarator => blk: {
                const e = src_node.data.extra;
                if (e > src_ast.extra_data.items.len or src_ast.extra_data.items.len - e < 3) break :blk .none;
                const name = src_ast.readExtraNode(e, 0);
                const type_annotation = src_ast.readExtraNode(e, 1);
                const initializer = src_ast.readExtraNode(e, 2);
                if (name.isNone() or src_ast.getNode(name).tag != .binding_identifier or !type_annotation.isNone())
                    break :blk .none;
                const copied_name = try self.copyNodeFromParsedAst(src_ast, name);
                const copied_initializer = if (initializer.isNone()) .none else try self.copyNodeFromParsedAst(src_ast, initializer);
                if (copied_name.isNone() or (!initializer.isNone() and copied_initializer.isNone())) break :blk .none;
                const extra = try self.transformer.ast.addExtras(&.{
                    @backingInt(copied_name),
                    @backingInt(NodeIndex.none),
                    @backingInt(copied_initializer),
                });
                break :blk self.transformer.ast.addNode(.{
                    .tag = .variable_declarator,
                    .span = new_span,
                    .data = .{ .extra = extra },
                });
            },

            // extra 노드 (static_member_expression, call_expression 등):
            // extra_data를 복사하되, 자식 노드 인덱스는 재귀 복사
            .static_member_expression => blk: {
                const e = src_node.data.extra;
                const obj = try self.copyNodeFromParsedAst(src_ast, @fromBackingInt(@intCast(src_ast.extra_data.items[e])));
                const prop = try self.copyNodeFromParsedAst(src_ast, @fromBackingInt(@intCast(src_ast.extra_data.items[e + 1])));
                const flags = src_ast.extra_data.items[e + 2];
                break :blk self.addExtraNode(.static_member_expression, new_span, &.{
                    @backingInt(obj), @backingInt(prop), flags,
                });
            },

            // 지원하지 않는 노드: data에 AST 인덱스가 포함될 수 있으므로
            // raw 복사는 dangling index 위험. 안전하게 스킵.
            else => .none,
        };
    }

    // --- 코드 생성 ---

    /// 함수 body를 self-contained 코드 문자열로 직렬화.
    /// closure 변수가 있으면 `const {v1, v2} = this.__closure;`를 body 앞에 삽입.
    /// 반환된 슬라이스는 caller가 getAllocator().free()로 해제해야 한다.
    pub fn generateCode(
        self: *AstTransformCtx,
        func_name: []const u8,
        body_idx: NodeIndex,
        closure_vars: []const worklet_mod.ClosureVar,
        params: ast_mod.NodeList,
        flags: u32,
    ) Error![]const u8 {
        return worklet_mod.generateInitCode(
            self.transformer,
            func_name,
            body_idx,
            closure_vars,
            params,
            flags,
        );
    }
};

const trailing_scope_fixture_count = 10;
const trailing_scope_fixture_names = [_][]const u8{
    "shared", "shared", "value2", "value3", "value4", "value5", "value6", "value7", "value8", "value9",
};
const trailing_scope_fixture_kinds = [_][]const u8{
    "const", "let", "var", "const", "let", "var", "var", "let", "var", "const",
};
const trailing_scope_fixture_symbol_kinds = [_]SymbolKind{
    .variable_const, .variable_let, .variable_var, .variable_const, .variable_let,
    .variable_var,   .variable_var, .variable_let, .variable_var,   .variable_const,
};

const TrailingScopeFixtureState = struct {
    insertion_scopes: [trailing_scope_fixture_count]?u32 = @splat(null),
};

fn injectIdentityFixtureTrailingCode(
    ctx: ?*anyopaque,
    api: *AstTransformCtx,
    func: FunctionInfo,
) @import("../bundler/plugin.zig").PluginError!void {
    const name = func.name orelse return;
    if (!std.mem.startsWith(u8, name, "marker")) return;
    const index = std.fmt.parseInt(usize, name["marker".len..], 10) catch return error.PluginFailed;
    if (index >= trailing_scope_fixture_count) return error.PluginFailed;
    const state: *TrailingScopeFixtureState = @ptrCast(@alignCast(ctx orelse return error.PluginFailed));
    state.insertion_scopes[index] = @backingInt(api.insertion_scope);
    const code = try std.fmt.allocPrint(
        api.getAllocator(),
        "__pluginBinding{d}; {s} __pluginBinding{d} = {s}; __pluginBinding{d};",
        .{ index, trailing_scope_fixture_kinds[index], index, trailing_scope_fixture_names[index], index },
    );
    defer api.getAllocator().free(code);
    const statements = try api.parseAndInjectStatements(code);
    defer api.getAllocator().free(statements);
    for (statements) |statement| try api.addTrailingStatement(statement);
}

test "NAPI trailing declarations and references keep exact binding and insertion scope" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var scanner = try @import("../lexer/scanner.zig").Scanner.init(alloc,
        \\let shared = 0; function marker0() {}
        \\{ const shared = 1; function marker1() {} }
        \\function outer2() { let value2 = 2; function marker2() {} { const value3 = 3; function marker3() {} } }
        \\function outer4(value7) { let value4 = 4; function marker4() {} function marker7() {} function inner5() { let value5 = 5; function marker5() {} { let value6 = 6; function marker6() {} } } }
        \\let value8 = 8; class C { method() { function marker8() {} } }
        \\let value9 = 9; const arrow9 = () => { function marker9() {} };
    );
    var parser = @import("../parser/parser.zig").Parser.init(alloc, &scanner);
    _ = try parser.parse();

    var analyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer.init(alloc, &parser.ast);
    try analyzer.analyze();
    var expected_scopes: [trailing_scope_fixture_count]?u32 = @splat(null);
    for (parser.ast.nodes.items, 0..) |node, raw| {
        if (node.tag != .function_declaration or node.data.extra >= parser.ast.extra_data.items.len) continue;
        const name_raw = parser.ast.extra_data.items[node.data.extra];
        if (name_raw >= parser.ast.nodes.items.len) continue;
        const name_node = parser.ast.nodes.items[name_raw];
        if (name_node.tag != .binding_identifier) continue;
        const name = parser.ast.getText(name_node.data.string_ref);
        for (0..trailing_scope_fixture_count) |index| {
            const expected_name = try std.fmt.allocPrint(alloc, "marker{d}", .{index});
            if (!std.mem.eql(u8, name, expected_name)) continue;
            const function_scope = analyzer.scope_owner_map.get(@intCast(raw)) orelse return error.TestUnexpectedResult;
            expected_scopes[index] = @backingInt(analyzer.scopes.items[function_scope].parent);
        }
    }

    var expected_ids: [trailing_scope_fixture_count]?usize = @splat(null);
    for (0..trailing_scope_fixture_count) |index| {
        try std.testing.expect(expected_scopes[index] != null);
        var scope: ScopeId = @fromBackingInt(expected_scopes[index].?);
        var hops: usize = 0;
        while (!scope.isNone() and hops < analyzer.scopes.items.len) : (hops += 1) {
            const scope_index = scope.toIndex();
            if (analyzer.scope_maps.items[scope_index].get(trailing_scope_fixture_names[index])) |symbol| {
                expected_ids[index] = symbol;
                break;
            }
            scope = analyzer.scopes.items[scope_index].parent;
        }
        try std.testing.expect(expected_ids[index] != null);
    }
    var state = TrailingScopeFixtureState{};

    const plugins = [_]transformer_mod.Plugin{.{
        .name = "exact-trailing-reference-test",
        .context = @ptrCast(&state),
        .onFunction = injectIdentityFixtureTrailingCode,
    }};
    var transformer = try Transformer.init(alloc, &parser.ast, .{ .plugins = &plugins });
    try transformer.initSymbolIds(analyzer.symbol_ids.items);
    transformer.symbols = analyzer.symbols.items;
    transformer.references = analyzer.references.items;
    transformer.scopes = analyzer.scopes.items;
    transformer.scope_maps = analyzer.scope_maps.items;
    transformer.scope_owner_map = analyzer.scope_owner_map;
    transformer.unresolved_references = &analyzer.unresolved_references;
    transformer.semantic_edit_enabled = true;

    const root = try transformer.transform();
    const live_editor = if (transformer.semantic_editor) |*editor| editor else return error.TestUnexpectedResult;
    var live_generated_symbol_count: usize = 0;
    for (transformer.ast.nodes.items, 0..) |node, raw| {
        if (node.tag != .binding_identifier) continue;
        const name = transformer.ast.getText(node.data.string_ref);
        for (0..trailing_scope_fixture_count) |index| {
            const expected_name = try std.fmt.allocPrint(alloc, "__pluginBinding{d}", .{index});
            if (!std.mem.eql(u8, name, expected_name)) continue;
            const binding: NodeIndex = @fromBackingInt(@intCast(raw));
            const sid = transformer.getSymbolIdAt(binding) orelse return error.TestUnexpectedResult;
            const symbol = live_editor.symbols.items[sid];
            const insertion_scope: ScopeId = @fromBackingInt(state.insertion_scopes[index].?);
            const expected_owner = if (symbol.kind == .variable_var)
                transformer.nearestVarScope(insertion_scope)
            else
                insertion_scope;
            try std.testing.expectEqual(trailing_scope_fixture_symbol_kinds[index], symbol.kind);
            try std.testing.expectEqual(expected_owner, symbol.scope_id);
            try std.testing.expectEqual(insertion_scope, symbol.origin_scope);
            live_generated_symbol_count += 1;
        }
    }
    try std.testing.expectEqual(trailing_scope_fixture_count, live_generated_symbol_count);
    const edited = (try transformer.finishSemanticEdit()).?;
    var found_references: [trailing_scope_fixture_count]bool = @splat(false);
    var found_reference_count: usize = 0;

    for (edited.references) |reference| {
        if (reference.node_index.isNone()) continue;
        const ref_node = transformer.ast.getNode(reference.node_index);
        if (ref_node.tag != .identifier_reference) continue;
        const ref_name = transformer.ast.getText(ref_node.data.string_ref);
        var fixture_index: ?usize = null;
        for (0..trailing_scope_fixture_count) |index| {
            if (std.mem.eql(u8, ref_name, trailing_scope_fixture_names[index]) and
                state.insertion_scopes[index] == @backingInt(reference.scope_id))
            {
                fixture_index = index;
                break;
            }
        }
        const index = fixture_index orelse continue;
        try std.testing.expect(!found_references[index]);
        found_references[index] = true;
        found_reference_count += 1;
        const sid = @backingInt(reference.symbol_id);
        try std.testing.expectEqual(@as(?u32, @intCast(sid)), edited.symbol_ids[@backingInt(reference.node_index)]);
        try std.testing.expectEqual(@as(u32, @intCast(expected_ids[index].?)), sid);
        try std.testing.expectEqual(expected_scopes[index].?, @backingInt(reference.scope_id));
        try std.testing.expectEqual(expected_scopes[index].?, state.insertion_scopes[index].?);
        try std.testing.expect(reference.flags.read);
    }

    try std.testing.expectEqual(trailing_scope_fixture_count, found_reference_count);
    for (found_references) |found| try std.testing.expect(found);
    try std.testing.expect(state.insertion_scopes[0].? != state.insertion_scopes[1].?);
    const nested_var_scope: ScopeId = @fromBackingInt(state.insertion_scopes[6].?);
    try std.testing.expect(nested_var_scope != transformer.nearestVarScope(nested_var_scope));

    var generated_symbol_ids: [trailing_scope_fixture_count]?u32 = @splat(null);
    var generated_binding_count: usize = 0;
    for (transformer.ast.nodes.items, 0..) |node, raw| {
        if (node.tag != .binding_identifier) continue;
        const name = transformer.ast.getText(node.data.string_ref);
        for (0..trailing_scope_fixture_count) |index| {
            const expected_name = try std.fmt.allocPrint(alloc, "__pluginBinding{d}", .{index});
            if (!std.mem.eql(u8, name, expected_name)) continue;
            try std.testing.expect(generated_symbol_ids[index] == null);
            const sid = edited.symbol_ids[raw] orelse return error.TestUnexpectedResult;
            generated_symbol_ids[index] = sid;
            generated_binding_count += 1;
            const symbol = edited.symbols.items[sid];
            try std.testing.expectEqual(trailing_scope_fixture_symbol_kinds[index], symbol.kind);
            const insertion_scope: ScopeId = @fromBackingInt(state.insertion_scopes[index].?);
            const expected_owner = if (symbol.kind == .variable_var)
                transformer.nearestVarScope(insertion_scope)
            else
                insertion_scope;
            try std.testing.expectEqual(@backingInt(expected_owner), @backingInt(symbol.scope_id));
        }
    }
    try std.testing.expectEqual(trailing_scope_fixture_count, generated_binding_count);

    var generated_reference_counts: [trailing_scope_fixture_count]usize = @splat(0);
    for (edited.references) |reference| {
        if (reference.node_index.isNone()) continue;
        const node = transformer.ast.getNode(reference.node_index);
        if (node.tag != .identifier_reference) continue;
        const name = transformer.ast.getText(node.data.string_ref);
        for (0..trailing_scope_fixture_count) |index| {
            const expected_name = try std.fmt.allocPrint(alloc, "__pluginBinding{d}", .{index});
            if (!std.mem.eql(u8, name, expected_name)) continue;
            const sid = generated_symbol_ids[index] orelse return error.TestUnexpectedResult;
            try std.testing.expectEqual(sid, @backingInt(reference.symbol_id));
            try std.testing.expectEqual(state.insertion_scopes[index].?, @backingInt(reference.scope_id));
            try std.testing.expectEqual(@as(?u32, sid), edited.symbol_ids[@backingInt(reference.node_index)]);
            generated_reference_counts[index] += 1;
        }
    }
    for (generated_reference_counts) |count| try std.testing.expectEqual(@as(usize, 2), count);
    _ = root;
}

const StaticMemberInjectedReferenceState = struct {
    binding: NodeIndex = .none,
    lexical_reference: NodeIndex = .none,
    property_nodes: [16]NodeIndex = @splat(.none),
    property_count: usize = 0,
};

const ObjectPropertyInjectedReferenceState = struct {
    binding: NodeIndex = .none,
    static_key_nodes: [16]NodeIndex = @splat(.none),
    static_key_count: usize = 0,
    computed_key_count: usize = 0,
};

fn injectObjectPropertyReferenceFixture(
    ctx: ?*anyopaque,
    api: *AstTransformCtx,
    func: FunctionInfo,
) @import("../bundler/plugin.zig").PluginError!void {
    if (func.name == null or !std.mem.eql(u8, func.name.?, "marker")) return;
    const state: *ObjectPropertyInjectedReferenceState = @ptrCast(@alignCast(ctx orelse return error.PluginFailed));
    const statements = try api.parseAndInjectStatements(
        "const foo = 1; " ++
            "const obj0 = { foo: 0 }; " ++
            "const obj1 = { foo: 1, value: foo }; " ++
            "const obj2 = { outer: { foo: 2 } }; " ++
            "const obj3 = { [foo]: 3 }; " ++
            "const obj4 = { foo }; " ++
            "const obj5 = { outer: { [foo.foo]: 5 } }; " ++
            "const obj6 = [{ foo: foo }]; " ++
            "const obj7 = { [foo]: { foo: 7 } }; " ++
            "const obj8 = { outer: { foo: 8, [foo]: foo } }; " ++
            "const obj9 = { foo: 9, outer: [{ foo }, { [foo]: { foo: 10 } }] }; " ++
            "foo;",
    );
    defer api.getAllocator().free(statements);

    for (statements) |statement| {
        const statement_node = api.getNode(statement);
        if (statement_node.tag == .variable_declaration and state.binding.isNone()) {
            const extra = statement_node.data.extra;
            const start = api.transformer.ast.extra_data.items[extra + 1];
            const declarator_raw = api.transformer.ast.extra_data.items[start];
            const declarator = api.transformer.ast.nodes.items[declarator_raw];
            const binding = api.transformer.ast.readExtraNode(declarator.data.extra, 0);
            if (std.mem.eql(u8, api.getText(api.getNode(binding).data.string_ref), "foo"))
                state.binding = binding;
        }

        const reachable = try ast_walk.collectReachableNodeIndicesFrom(api.getAllocator(), api.transformer.ast, statement);
        defer api.getAllocator().free(reachable);
        for (reachable) |raw| {
            const reachable_node = api.transformer.ast.nodes.items[raw];
            if (reachable_node.tag == .computed_property_key) state.computed_key_count += 1;
            if (reachable_node.tag != .object_property) continue;
            const key = reachable_node.data.binary.left;
            const value = reachable_node.data.binary.right;
            if (key.isNone() or value.isNone()) continue;
            const key_node = api.getNode(key);
            if (key_node.tag != .identifier_reference or
                !std.mem.eql(u8, api.getText(key_node.data.string_ref), "foo")) continue;
            if (state.static_key_count >= state.static_key_nodes.len) return error.PluginFailed;
            state.static_key_nodes[state.static_key_count] = key;
            state.static_key_count += 1;
        }
        try api.addTrailingStatement(statement);
    }
}

test "NAPI injected object property keys do not bind lexical SymbolIds" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var scanner = try @import("../lexer/scanner.zig").Scanner.init(alloc, "function marker() {}");
    var parser = @import("../parser/parser.zig").Parser.init(alloc, &scanner);
    _ = try parser.parse();
    var analyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer.init(alloc, &parser.ast);
    try analyzer.analyze();
    try std.testing.expectEqual(@as(usize, 0), analyzer.errors.items.len);

    var state = ObjectPropertyInjectedReferenceState{};
    const plugins = [_]transformer_mod.Plugin{.{
        .name = "object-property-reference-context-test",
        .context = @ptrCast(&state),
        .onFunction = injectObjectPropertyReferenceFixture,
    }};
    var transformer = try Transformer.init(alloc, &parser.ast, .{ .plugins = &plugins });
    try transformer.initSymbolIds(analyzer.symbol_ids.items);
    transformer.symbols = analyzer.symbols.items;
    transformer.references = analyzer.references.items;
    transformer.scopes = analyzer.scopes.items;
    transformer.scope_maps = analyzer.scope_maps.items;
    transformer.scope_owner_map = analyzer.scope_owner_map;
    transformer.unresolved_references = &analyzer.unresolved_references;
    transformer.semantic_edit_enabled = true;
    _ = try transformer.transform();

    try std.testing.expect(!state.binding.isNone());
    try std.testing.expectEqual(@as(usize, 8), state.static_key_count);
    try std.testing.expectEqual(@as(usize, 5), state.computed_key_count);
    const binding_symbol_id = transformer.getSymbolIdAt(state.binding) orelse return error.TestUnexpectedResult;
    for (state.static_key_nodes[0..state.static_key_count]) |key| {
        try std.testing.expectEqual(.identifier_reference, transformer.ast.getNode(key).tag);
        try std.testing.expectEqualStrings("foo", transformer.ast.getText(transformer.ast.getNode(key).data.string_ref));
        try std.testing.expect(transformer.getSymbolIdAt(key) == null);
    }

    const edited = (try transformer.finishSemanticEdit()).?;
    try std.testing.expectEqual(@as(u32, 11), edited.symbols.items[binding_symbol_id].reference_count);
    var exact_foo_reads: usize = 0;
    for (edited.references) |reference| {
        if (reference.flags.declare or @backingInt(reference.symbol_id) != binding_symbol_id) continue;
        try std.testing.expectEqual(.identifier_reference, transformer.ast.getNode(reference.node_index).tag);
        try std.testing.expectEqualStrings("foo", transformer.ast.getText(transformer.ast.getNode(reference.node_index).data.string_ref));
        exact_foo_reads += 1;
    }
    try std.testing.expectEqual(@as(usize, 11), exact_foo_reads);
}

fn injectStaticMemberReferenceFixture(
    ctx: ?*anyopaque,
    api: *AstTransformCtx,
    func: FunctionInfo,
) @import("../bundler/plugin.zig").PluginError!void {
    if (func.name == null or !std.mem.eql(u8, func.name.?, "marker")) return;
    const state: *StaticMemberInjectedReferenceState = @ptrCast(@alignCast(ctx orelse return error.PluginFailed));
    const statements = try api.parseAndInjectStatements(
        "const foo = 1; obj.foo; x.foo; y.foo.foo; z.foo; obj.foo; foo.foo; " ++
            "y.foo.foo.foo; x.foo; z.foo; obj.foo.foo; foo;",
    );
    defer api.getAllocator().free(statements);

    for (statements) |statement| {
        const node = api.getNode(statement);
        if (node.tag == .variable_declaration) {
            const extra = node.data.extra;
            const start = api.transformer.ast.extra_data.items[extra + 1];
            const declarator_raw = api.transformer.ast.extra_data.items[start];
            const declarator = api.transformer.ast.nodes.items[declarator_raw];
            state.binding = api.transformer.ast.readExtraNode(declarator.data.extra, 0);
        } else if (node.tag == .expression_statement) {
            const expression = node.data.unary.operand;
            const expression_node = api.getNode(expression);
            if (expression_node.tag == .identifier_reference and
                std.mem.eql(u8, api.getText(expression_node.data.string_ref), "foo"))
            {
                state.lexical_reference = expression;
            }
        }

        const reachable = try ast_walk.collectReachableNodeIndicesFrom(api.getAllocator(), api.transformer.ast, statement);
        defer api.getAllocator().free(reachable);
        for (reachable) |raw| {
            const reachable_node = api.transformer.ast.nodes.items[raw];
            if (reachable_node.tag != .static_member_expression) continue;
            const property_raw = api.transformer.ast.extra_data.items[reachable_node.data.extra + 1];
            if (state.property_count >= state.property_nodes.len) return error.PluginFailed;
            state.property_nodes[state.property_count] = @fromBackingInt(@intCast(property_raw));
            state.property_count += 1;
        }
        try api.addTrailingStatement(statement);
    }
}

test "NAPI injected static member names do not bind lexical SymbolIds" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var scanner = try @import("../lexer/scanner.zig").Scanner.init(alloc, "var obj, x, y, z; function marker() {}");
    var parser = @import("../parser/parser.zig").Parser.init(alloc, &scanner);
    _ = try parser.parse();
    var analyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer.init(alloc, &parser.ast);
    try analyzer.analyze();
    try std.testing.expectEqual(@as(usize, 0), analyzer.errors.items.len);

    var state = StaticMemberInjectedReferenceState{};
    const plugins = [_]transformer_mod.Plugin{.{
        .name = "static-member-reference-context-test",
        .context = @ptrCast(&state),
        .onFunction = injectStaticMemberReferenceFixture,
    }};
    var transformer = try Transformer.init(alloc, &parser.ast, .{ .plugins = &plugins });
    try transformer.initSymbolIds(analyzer.symbol_ids.items);
    transformer.symbols = analyzer.symbols.items;
    transformer.references = analyzer.references.items;
    transformer.scopes = analyzer.scopes.items;
    transformer.scope_maps = analyzer.scope_maps.items;
    transformer.scope_owner_map = analyzer.scope_owner_map;
    transformer.unresolved_references = &analyzer.unresolved_references;
    transformer.semantic_edit_enabled = true;
    _ = try transformer.transform();

    try std.testing.expectEqual(@as(usize, 14), state.property_count);
    try std.testing.expect(!state.binding.isNone());
    try std.testing.expect(!state.lexical_reference.isNone());
    const binding_symbol_id = transformer.getSymbolIdAt(state.binding) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(binding_symbol_id, transformer.getSymbolIdAt(state.lexical_reference).?);
    for (state.property_nodes[0..state.property_count]) |property| {
        try std.testing.expectEqual(.identifier_reference, transformer.ast.getNode(property).tag);
        try std.testing.expectEqualStrings("foo", transformer.ast.getText(transformer.ast.getNode(property).data.string_ref));
        try std.testing.expect(transformer.getSymbolIdAt(property) == null);
    }

    const edited = (try transformer.finishSemanticEdit()).?;
    try std.testing.expectEqual(@as(u32, 2), edited.symbols.items[binding_symbol_id].reference_count);
    for (edited.references) |reference| {
        for (state.property_nodes[0..state.property_count]) |property| {
            try std.testing.expect(reference.node_index != property);
        }
    }
    try std.testing.expectEqual(@as(u32, binding_symbol_id), edited.symbol_ids[@backingInt(state.lexical_reference)].?);
}

const VarRedeclarationFixtureState = struct {
    bindings: [7]NodeIndex = @splat(.none),
    binding_count: usize = 0,
    insertion_scope: ?u32 = null,
    parameter_binding: NodeIndex = .none,
    parameter_reference: NodeIndex = .none,
    escaped_reference: NodeIndex = .none,
    nested_insertion_scope: ?u32 = null,
};

fn injectVarRedeclarationFixture(
    ctx: ?*anyopaque,
    api: *AstTransformCtx,
    func: FunctionInfo,
) @import("../bundler/plugin.zig").PluginError!void {
    const state: *VarRedeclarationFixtureState = @ptrCast(@alignCast(ctx orelse return error.PluginFailed));
    const code = if (func.name) |name| blk: {
        if (std.mem.eql(u8, name, "marker")) {
            state.insertion_scope = @backingInt(api.insertion_scope);
            break :blk "var existing = 41; var injected = 1; var injected = 2; var marker = 5; var \\u0078 = 1; var x = 2; var y = 31; throw \\u0078;";
        }
        if (std.mem.eql(u8, name, "nestedMarker")) {
            state.nested_insertion_scope = @backingInt(api.insertion_scope);
            break :blk "var value = value + 1; throw value;";
        }
        return;
    } else return;
    const statements = try api.parseAndInjectStatements(code);
    defer api.getAllocator().free(statements);
    for (statements) |statement| {
        const node = api.getNode(statement);
        if (node.tag == .variable_declaration) {
            const extra = node.data.extra;
            const start = api.transformer.ast.extra_data.items[extra + 1];
            const len = api.transformer.ast.extra_data.items[extra + 2];
            var i: u32 = 0;
            while (i < len) : (i += 1) {
                const declarator_raw = api.transformer.ast.extra_data.items[start + i];
                const declarator = api.transformer.ast.nodes.items[declarator_raw];
                const binding = api.transformer.ast.readExtraNode(declarator.data.extra, 0);
                if (std.mem.eql(u8, func.name.?, "marker")) {
                    if (state.binding_count >= state.bindings.len) return error.PluginFailed;
                    state.bindings[state.binding_count] = binding;
                    state.binding_count += 1;
                } else {
                    if (!std.mem.eql(u8, api.getText(api.getNode(binding).data.string_ref), "value"))
                        return error.PluginFailed;
                    state.parameter_binding = binding;
                }
            }
        } else if (node.tag == .throw_statement) {
            const reference = node.data.unary.operand;
            if (std.mem.eql(u8, func.name.?, "marker")) {
                state.escaped_reference = reference;
            } else {
                state.parameter_reference = reference;
            }
        }
        try api.addTrailingStatement(statement);
    }
}

test "NAPI plugin var redeclarations reuse the exact existing SymbolId" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var scanner = try @import("../lexer/scanner.zig").Scanner.init(
        alloc,
        "\"use strict\"; var existing = 40; var \\u0079 = 30; function marker() {} function outer(value) { { function nestedMarker() {} } }",
    );
    var parser = @import("../parser/parser.zig").Parser.init(alloc, &scanner);
    _ = try parser.parse();
    var analyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer.init(alloc, &parser.ast);
    try analyzer.analyze();
    try std.testing.expectEqual(@as(usize, 0), analyzer.errors.items.len);

    var state = VarRedeclarationFixtureState{};
    const plugins = [_]transformer_mod.Plugin{.{
        .name = "var-redeclaration-identity-test",
        .context = @ptrCast(&state),
        .onFunction = injectVarRedeclarationFixture,
    }};
    var transformer = try Transformer.init(alloc, &parser.ast, .{ .plugins = &plugins });
    try transformer.initSymbolIds(analyzer.symbol_ids.items);
    transformer.symbols = analyzer.symbols.items;
    transformer.references = analyzer.references.items;
    transformer.scopes = analyzer.scopes.items;
    transformer.scope_maps = analyzer.scope_maps.items;
    transformer.scope_owner_map = analyzer.scope_owner_map;
    transformer.unresolved_references = &analyzer.unresolved_references;
    transformer.semantic_edit_enabled = true;

    _ = try transformer.transform();
    try std.testing.expectEqual(state.bindings.len, state.binding_count);
    const insertion_scope: ScopeId = @fromBackingInt(state.insertion_scope orelse return error.TestUnexpectedResult);
    const var_scope = transformer.nearestVarScope(insertion_scope);
    const source_symbol_id = analyzer.scope_maps.items[var_scope.toIndex()].get("existing") orelse
        return error.TestUnexpectedResult;
    const function_symbol_id = analyzer.scope_maps.items[var_scope.toIndex()].get("marker") orelse
        return error.TestUnexpectedResult;
    const escaped_source_symbol_id = analyzer.scope_maps.items[var_scope.toIndex()].get("y") orelse
        return error.TestUnexpectedResult;
    var parameter_symbol_id: ?usize = null;
    for (analyzer.symbols.items, 0..) |symbol, raw| {
        if (symbol.kind == .parameter and std.mem.eql(u8, parser.ast.getText(symbol.name), "value")) {
            parameter_symbol_id = raw;
            break;
        }
    }
    const existing_binding_id = transformer.getSymbolIdAt(state.bindings[0]) orelse return error.TestUnexpectedResult;
    const first_injected_binding_id = transformer.getSymbolIdAt(state.bindings[1]) orelse return error.TestUnexpectedResult;
    const second_injected_binding_id = transformer.getSymbolIdAt(state.bindings[2]) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u32, @intCast(source_symbol_id)), existing_binding_id);
    try std.testing.expectEqual(first_injected_binding_id, second_injected_binding_id);
    try std.testing.expectEqual(@as(u32, @intCast(function_symbol_id)), transformer.getSymbolIdAt(state.bindings[3]).?);
    try std.testing.expectEqual(@as(u32, @intCast(escaped_source_symbol_id)), transformer.getSymbolIdAt(state.bindings[6]).?);
    try std.testing.expectEqual(transformer.getSymbolIdAt(state.bindings[4]).?, transformer.getSymbolIdAt(state.bindings[5]).?);
    try std.testing.expectEqual(transformer.getSymbolIdAt(state.bindings[4]).?, transformer.getSymbolIdAt(state.escaped_reference).?);
    try std.testing.expect(parameter_symbol_id != null);
    try std.testing.expect(!state.parameter_binding.isNone());
    try std.testing.expect(transformer.getSymbolIdAt(state.parameter_binding) != null);
    try std.testing.expectEqual(@as(u32, @intCast(parameter_symbol_id.?)), transformer.getSymbolIdAt(state.parameter_binding).?);

    const editor = if (transformer.semantic_editor) |*semantic_editor| semantic_editor else return error.TestUnexpectedResult;
    for (state.bindings, 0..) |binding, index| {
        const symbol_id = transformer.getSymbolIdAt(binding) orelse return error.TestUnexpectedResult;
        const symbol = editor.symbols.items[symbol_id];
        try std.testing.expectEqual(var_scope, symbol.scope_id);
        if (index != 3) try std.testing.expectEqual(.variable_var, symbol.kind);
    }
    const parameter_insertion_scope: ScopeId = @fromBackingInt(state.nested_insertion_scope orelse return error.TestUnexpectedResult);
    const parameter_owner_scope = editor.symbols.items[parameter_symbol_id.?].scope_id;
    try std.testing.expectEqual(parameter_owner_scope, transformer.nearestVarScope(parameter_insertion_scope));
    try std.testing.expectEqual(parameter_owner_scope, editor.symbols.items[transformer.getSymbolIdAt(state.parameter_binding).?].scope_id);
    const edited = (try transformer.finishSemanticEdit()).?;
    for (state.bindings) |binding| {
        const symbol_id = transformer.getSymbolIdAt(binding) orelse return error.TestUnexpectedResult;
        var found_declaration = false;
        for (edited.references) |reference| {
            if (reference.flags.declare and reference.declaration_node_index == binding and
                @backingInt(reference.symbol_id) == symbol_id)
            {
                found_declaration = true;
                break;
            }
        }
        try std.testing.expect(found_declaration);
    }

    var post_transform_analyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer.init(alloc, transformer.ast);
    post_transform_analyzer.enable_stmt_info = true;
    try post_transform_analyzer.analyze();
    try std.testing.expectEqual(@as(usize, 0), post_transform_analyzer.errors.items.len);
    const repeated_symbol_id = post_transform_analyzer.symbol_ids.items[@backingInt(state.bindings[1])] orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(
        post_transform_analyzer.symbol_ids.items[@backingInt(state.bindings[2])],
        @as(?u32, @intCast(repeated_symbol_id)),
    );
    var found_indexed_redeclaration = false;
    for (post_transform_analyzer.references.items) |reference| {
        if (reference.flags.declare and reference.declaration_node_index == state.bindings[2] and
            @backingInt(reference.symbol_id) == repeated_symbol_id)
        {
            try std.testing.expect(reference.stmt_idx != @import("../semantic/symbol.zig").Reference.NO_STMT);
            try std.testing.expect(reference.scope_stmt_idx != @import("../semantic/symbol.zig").Reference.NO_STMT);
            found_indexed_redeclaration = true;
            break;
        }
    }
    try std.testing.expect(found_indexed_redeclaration);
    const escaped_repeat_id = post_transform_analyzer.symbol_ids.items[@backingInt(state.bindings[4])] orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(
        post_transform_analyzer.symbol_ids.items[@backingInt(state.bindings[5])],
        @as(?u32, @intCast(escaped_repeat_id)),
    );
    const post_parameter_id = post_transform_analyzer.symbol_ids.items[@backingInt(state.parameter_binding)] orelse
        return error.TestUnexpectedResult;
    const post_parameter_ref_id = post_transform_analyzer.symbol_ids.items[@backingInt(state.parameter_reference)] orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(post_parameter_id, post_parameter_ref_id);
}
