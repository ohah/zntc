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
const token_mod = @import("../lexer/token.zig");
const Span = token_mod.Span;
const ScopeId = @import("../semantic/scope.zig").ScopeId;
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
        const Scanner = @import("../lexer/scanner.zig").Scanner;
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
            if (!copied.isNone()) try self.bindInjectedReferences(copied);
            result[count] = copied;
            count += 1;
        }

        if (count == 0) {
            alloc.free(result);
            return &.{};
        }
        return result[0..count];
    }

    /// Bind references parsed from plugin text at the scope where the
    /// trailing statement is inserted. The spelling is used once here to
    /// resolve the source binding; all later consumers receive its exact ID.
    fn bindInjectedReferences(self: *AstTransformCtx, root: NodeIndex) Error!void {
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

        const reachable = try ast_walk.collectReachableNodeIndicesFrom(transformer.allocator, transformer.ast, root);
        defer transformer.allocator.free(reachable);

        for (reachable) |raw| {
            if (raw >= transformer.ast.nodes.items.len) continue;
            const reference: NodeIndex = @fromBackingInt(@intCast(raw));
            const node = transformer.ast.nodes.items[raw];
            if (node.tag != .identifier_reference and node.tag != .assignment_target_identifier and node.tag != .jsx_identifier) continue;

            const name = transformer.ast.getText(node.data.string_ref);
            if (transformer.lexicalSymbolIdAtScope(name, self.insertion_scope)) |raw_id| {
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
    const code = try std.fmt.allocPrint(api.getAllocator(), "{s};", .{trailing_scope_fixture_names[index]});
    defer api.getAllocator().free(code);
    const statements = try api.parseAndInjectStatements(code);
    defer api.getAllocator().free(statements);
    for (statements) |statement| try api.addTrailingStatement(statement);
}

test "NAPI trailingCode references keep exact binding and insertion scope" {
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
    _ = root;
}
