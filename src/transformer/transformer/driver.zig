const std = @import("std");
const ast_mod = @import("../../parser/ast.zig");
const ast_walk = @import("../../parser/ast_walk.zig");
const es2015_params = @import("../es2015_params.zig");

const NodeIndex = ast_mod.NodeIndex;
const Error = std.mem.Allocator.Error;
const Span = @import("../../lexer/token.zig").Span;
const es_helpers = @import("../es_helpers.zig");

/// (#4596) **program 앞에 prepend 되는 합성 top-level 문장의 span 불변식**:
/// 대응하는 원본 소스 텍스트가 없으므로 span 은 *위치 anchor* 로만 쓰고 길이는 0 이어야 한다.
///
/// 여기서 prepend 하는 문장들의 span 후보로 손에 잡히는 것은 program root span(= 파일 전체)
/// 또는 변환을 유발한 원본 식(파일 중간) 인데, 둘 다 실제 소스 범위가 아니다. 그대로 달면:
///   - 파일 전체 범위: span 포함 관계로 "이 참조가 선언 안에 있나" 를 보는 소비자
///     (`NamespaceAccessIndex.decl_ranges` → `isInDecl`) 에게 모듈 전체를 덮는 선언 범위로
///     보여 그 모듈의 모든 참조가 skip 된다 → namespace 멤버 사용 0건 → tree-shaker 가
///     살아있는 export 제거 → dangling ReferenceError (#4596 의 루트커즈)
///   - 파일 중간 범위: prepend 로 문장 순서상 맨 앞에 오는데 span.start 는 뒤쪽이라
///     "top-level stmt span 은 소스 순서·비중첩" 을 가정하는 `stmt_info.findStmtForPos` /
///     `findContainingStmt` 의 이분 탐색 전제가 깨진다
///
/// zero-length anchor 는 두 소비자 모두에게 안전하다 — 아무 위치도 "포함" 하지 않고,
/// 정렬 기준으로도 program 시작이라 prepend 순서와 일치한다.
///
/// 강제 지점은 둘: (1) 여기 — 직접 prepend 하는 문장, (2) 주입 import 를 만드는
/// `jsx_runtime_imports.zig` / `runtime_helper_imports.zig` (자기가 만드는 하위 노드까지 접음).
fn anchorSyntheticTopLevel(self: anytype, stmts: []const NodeIndex, anchor_start: u32) void {
    for (stmts) |stmt| {
        if (stmt == .none) continue;
        const i: usize = @backingInt(stmt);
        if (i >= self.ast.nodes.items.len) continue;
        self.ast.nodes.items[i].span = .{ .start = anchor_start, .end = anchor_start };
    }
}

pub fn transform(self: anytype) Error!NodeIndex {
    const profile = @import("../../profile.zig");
    var scope = profile.begin(.transform);
    defer scope.end();

    // #1961: graph parse 단계의 pre-pass 가 이미 transform 한 ast 면 cached root 반환.
    // emitter 가 같은 ast 로 transformer 를 새로 만들 때 transform 을 다시 돌지 않도록.
    // caller 는 미리 transformer.runtime_helpers / .symbol_ids 를 module.transform_cache
    // 에서 hydrate 해 두어야 emit 시점에 동일한 결과 사용.
    if (self.ast.transformed_root) |cached| {
        return cached;
    }
    const ArrowStatements = @import("../native_arrow_statement_publication.zig");
    var arrow_statements: ArrowStatements.Batch = .{};
    const arrow_statement_lease = ArrowStatements.borrow(&self.native_arrow_statement_batch, &arrow_statements);
    defer arrow_statement_lease.restore();
    defer {
        for (arrow_statements.plans.items) |plan| {
            self.allocator.free(plan.handles);
            self.allocator.free(plan.prefix_rows);
        }
        arrow_statements.plans.deinit(self.allocator);
    }
    self.ast.assertInvariants();

    // worklet __pluginVersion 문자열 리터럴 span 사전 계산 (매 worklet당 할당 방지)
    if (self.options.worklet_plugin_version) |v| {
        const quoted = std.fmt.allocPrint(self.allocator, "\"{s}\"", .{v}) catch return Error.OutOfMemory;
        defer self.allocator.free(quoted);
        self.plugins.worklet.plugin_version_span = self.ast.addString(quoted) catch return Error.OutOfMemory;
    }

    // 블록 스코핑 리네임을 심볼 기준으로 미리 정한다 (#4760).
    try self.buildBlockRenameMap();
    try @import("../parameter_environment.zig").collectClassInferredNames(self);
    try @import("../native_parameter_cells.zig").normalize(self);

    // 파서의 마지막 노드가 루트 (program). parser_node_count - 1.
    const root_idx: NodeIndex = @fromBackingInt(@intCast(self.parser_node_count - 1));
    const saved_temp_counter = self.temp_var_counter;
    // worklet anonymous naming counter — Transformer 인스턴스 재사용 시 매 transform당 0부터 시작.
    self.plugins.worklet.anonymous_counter = 0;

    // (T1 도구 보강) sub-phase 측정: visit pass + pass2 + finalize. visitor 내부의
    // ts_strip / jsx / class_field / decorator 분리는 별도 작업 (visitor 코드 수정 필요).
    var root: NodeIndex = undefined;
    {
        var visit_scope = profile.begin(.transform_visit);
        defer visit_scope.end();
        root = try self.visitNode(root_idx);
    }

    // Pass 1 can create function nodes without attaching scopes until final
    // symbol completion. Register their output scopes now because parameter
    // lowering adds references to the bodies during Pass 2.
    if (self.semantic_edit_enabled)
        try self.registerGeneratedFunctionScopes(root, self.programScope());

    try @import("../es2015_generator.zig").ES2015Generator(@TypeOf(self.*)).appendAnnexBVariableStorage(self, root);
    try @import("../parameter_environment.zig").prependBodyFunctionNames(self, root);

    // Pass 2: ES2015 params lowering 일괄 적용
    // #4251: object rest 가 든 param (`{a, ...r}`, ES2018) 은 default_params 지원
    // 타겟(es2017)에서도 lowering 필요 → object_spread 도 게이트. per-function 은
    // lowerAllFunctionParams 가 target-aware 로 object-rest param 만 선별(default-
    // param-only 함수 과트리거 방지). Native defaults must retain their
    // parameter environment: lowering them because of a generated body
    // capture changes body shadowing, later-param TDZ, and direct eval.
    if (self.options.unsupported.default_params or self.options.unsupported.object_spread) {
        var pass2_scope = profile.begin(.transform_pass2);
        defer pass2_scope.end();
        try lowerAllFunctionParams(self, root);
    }

    var finalize_scope = profile.begin(.transform_finalize);
    defer finalize_scope.end();

    // 합성 top-level prepend 의 span anchor — `anchorSyntheticTopLevel` 의 doc 참고 (#4596).
    const synthetic_anchor: Span = blk: {
        const s = self.ast.getNode(root_idx).span.start;
        break :blk .{ .start = s, .end = s };
    };

    // top-level 임시 변수 호이스팅: var _a, _b, ... 선언을 program 앞에 삽입
    if (self.temp_var_counter > saved_temp_counter and !root.isNone()) {
        // program root span (파일 전체) 대신 zero-length anchor — 생성되는 var_declaration /
        // variable_declarator 가 모듈 전체를 덮는 범위를 갖지 않도록 (#4596).
        root = try self.hoistTempVars(root, saved_temp_counter, synthetic_anchor);
    }

    // ES2015 tagged template: _templateObject 캐싱 함수를 program 맨 앞에 호이스팅
    if (self.tagged_template_fns.items.len > 0 and !root.isNone()) {
        // 이 함수 노드의 span 은 변환을 유발한 템플릿 식(파일 중간) 이라, prepend 후 stmt span
        // 정렬 전제를 깨뜨린다 → anchor 로 접는다 (#4596).
        anchorSyntheticTopLevel(self, self.tagged_template_fns.items, synthetic_anchor.start);
        root = try self.prependStatementsToBody(root, self.tagged_template_fns.items);
    }

    // #1961: 사용된 runtime helper 별 named import statement 를 program 앞에 prepend.
    // graph parse 단계의 transformer pre-pass 가 set 하는 옵션으로만 활성 — emitter 의
    // in-place transformer 호출은 false 유지하여 helper specifier 가 출력에 새는 사고 방지.
    if (self.options.emit_runtime_helper_imports and !root.isNone()) {
        const helper_imports = @import("../runtime_helper_imports.zig");
        const root_span = self.ast.getNode(root).span;
        var imports: std.ArrayList(NodeIndex) = .empty;
        defer imports.deinit(self.allocator);
        try helper_imports.appendHelperImports(self, self.runtime_helpers, root_span, &imports);
        if (imports.items.len > 0) {
            root = try self.prependStatementsToBody(root, imports.items);
        }
    }

    // #3062: JSX automatic runtime import 를 정식 AST 노드로 추가.
    // standalone 과 bundler 가 같은 AST import 경로를 사용해 semantic/linker 단계에서
    // import binding 과 JSX call reference 를 하나의 symbol 로 추적한다.
    // Bundler pre-pass 는 runtime helper import 옵션을, standalone transpile 은 별도
    // JSX 옵션을 사용한다. emitter 의 in-place transform 호출에서는 둘 다 false다.
    if ((self.options.emit_runtime_helper_imports or self.options.emit_jsx_runtime_imports) and !root.isNone() and
        self.jsx_import_info.hasImports() and self.options.jsx_runtime != .classic)
    {
        const jsx_runtime_imports = @import("../jsx_runtime_imports.zig");
        const root_span = self.ast.getNode(root).span;
        var imports: std.ArrayList(NodeIndex) = .empty;
        defer imports.deinit(self.allocator);
        const is_dev = self.options.jsx_runtime == .automatic_dev;
        try jsx_runtime_imports.appendJsxRuntimeImports(
            self,
            self.jsx_import_info,
            self.options.jsx_import_source,
            is_dev,
            root_span,
            &imports,
        );
        if (imports.items.len > 0) {
            root = try self.prependStatementsToBody(root, imports.items);
        }
    }

    // styled-components css prop auto-imports are real module imports too.
    // Bind the import and generated css-prop references to one helper SymbolId.
    if (!root.isNone() and self.plugins.styled_components.css_prop_needs_import) {
        const styled_imports = @import("../styled_components_imports.zig");
        const root_span = self.ast.getNode(root).span;
        var imports: std.ArrayList(NodeIndex) = .empty;
        defer imports.deinit(self.allocator);
        try styled_imports.appendStyledComponentsImport(
            self,
            self.plugins.styled_components.css_prop_inject_name,
            self.plugins.styled_components.css_prop_inject_symbol_id,
            root_span,
            &imports,
        );
        if (imports.items.len > 0) {
            root = try self.prependStatementsToBody(root, imports.items);
        }
    }

    // React Fast Refresh: 컴포넌트 등록 코드를 프로그램 끝에 추가 ($RefreshReg$만, $RefreshSig$ 제거).
    // refreshEnabled() 가 path filter (Vite plugin-react 호환 — `.[jt]sx?$`/`.mjs$` + node_modules 제외) 까지 검증.
    if (self.refreshEnabled() and self.plugins.refresh.registrations.items.len > 0) {
        root = try self.appendRefreshRegistrations(root);
    }

    if (self.semantic_edit_enabled) {
        try self.completeGeneratedStateSymbols(root, self.programScope());
        ArrowStatements.publish(self, &arrow_statements, root) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => @panic("native arrow final statement publication rejected"),
        };
        try @import("../class_initializer_publication.zig").publish(self, root);
        try @import("../es2015_generator.zig").ES2015Generator(@TypeOf(self.*)).projectFunctionStorageCoordinates(self, root);
        try @import("../native_constructor_timing.zig").projectCoordinates(self, root);
        try @import("../native_arguments.zig").publish(self, root);
        try @import("../worklet_class_clone.zig").publish(self, root);
        try @import("../virtual_helper_provider_certificate.zig").beforeBinder(self, root);
        if (self.native_noop_source != null) {
            self.native_noop_before_binder = @import("../native_noop_graph.zig").beforeBinder(self, root) catch false;
            if (self.native_noop_before_binder) self.native_noop_before_binder_root = root;
        }
        try self.bindOutputScopesAndReferences(root, self.programScope());
    }

    self.ast.transformed_root = root;
    self.ast.assertInvariants();
    return root;
}

/// Pass 2: 모든 function-like 노드의 params를 일괄 lowering.
/// Pass 1에서 생성된 모든 function_declaration, function_expression, function,
/// method_definition 노드를 순회하며, default/rest/destructuring params가 있으면
/// lowerParams를 적용하고 extra_data를 in-place 수정한다.
fn isUninitializedVarDeclaration(self: anytype, idx: NodeIndex) bool {
    if (idx.isNone() or @backingInt(idx) >= self.ast.nodes.items.len) return false;
    const node = self.ast.getNode(idx);
    if (node.tag != .variable_declaration or self.ast.variableDeclarationKind(node) != .@"var") return false;
    const extra = self.ast.extra_data.items;
    const e = node.data.extra;
    if (e >= extra.len or extra.len - e < 3) return false;
    const start = extra[e + 1];
    const len = extra[e + 2];
    if (start > extra.len or len > extra.len - start) return false;
    for (extra[start .. start + len]) |raw| {
        if (raw >= self.ast.nodes.items.len) return false;
        const declarator = self.ast.nodes.items[raw];
        if (declarator.tag != .variable_declarator) return false;
        const de = declarator.data.extra;
        if (de >= extra.len or extra.len - de < 3 or @as(NodeIndex, @fromBackingInt(@intCast(extra[de + 2]))) != .none) return false;
    }
    return true;
}

/// Default checks run at function call time, before the function body. An
/// arrow in a default can read the generated lexical this/arguments captures,
/// so those declarations must precede the checks. Other body captures keep
/// their original position relative to the checks.
pub fn prependParameterInitializers(self: anytype, body_idx: NodeIndex, stmts: []const NodeIndex) Error!NodeIndex {
    const body = self.ast.getNode(body_idx);
    if (body.tag != .block_statement and body.tag != .function_body) return self.prependStatementsToBody(body_idx, stmts);
    const list = body.data.list;
    const extra = self.ast.extra_data.items;
    if (list.start > extra.len or list.len > extra.len - list.start) return self.prependStatementsToBody(body_idx, stmts);
    const old = extra[list.start .. list.start + list.len];
    var insert_at: usize = 0;
    var saw_capture = false;
    for (old, 0..) |raw, i| {
        if (self.parameter_capture_statements.contains(raw)) {
            saw_capture = true;
            insert_at = i + 1;
        } else if (!isUninitializedVarDeclaration(self, @fromBackingInt(@intCast(raw)))) {
            break;
        }
    }
    if (!saw_capture) return self.prependStatementsToBody(body_idx, stmts);

    const scratch_top = self.scratch.items.len;
    defer self.scratch.shrinkRetainingCapacity(scratch_top);
    for (old[0..insert_at]) |raw| try self.scratch.append(self.allocator, @fromBackingInt(@intCast(raw)));
    try self.scratch.appendSlice(self.allocator, stmts);
    for (old[insert_at..]) |raw| try self.scratch.append(self.allocator, @fromBackingInt(@intCast(raw)));
    const new_list = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
    return self.ast.addNode(.{ .tag = body.tag, .span = body.span, .data = .{ .list = new_list } });
}

fn hasScopedOutputReplacement(self: anytype, idx: NodeIndex) bool {
    const raw = @backingInt(idx);
    if (raw < self.parser_node_count or self.outputOwnedScope(idx) != null) return false;
    const node = self.ast.getNode(idx);
    if (node.tag != .function_expression and node.tag != .function and node.tag != .function_declaration and
        node.tag != .arrow_function_expression) return false;

    var owners = self.scope_owner_map.iterator();
    while (owners.next()) |entry| {
        const source_raw = entry.key_ptr.*;
        if (source_raw >= self.parser_node_count or source_raw >= self.ast.nodes.items.len) continue;
        const source = self.ast.nodes.items[source_raw];
        if (source.span.start != node.span.start or source.span.end != node.span.end) continue;
        if (source.tag != .function_expression and source.tag != .function and source.tag != .function_declaration and
            source.tag != .arrow_function_expression and source.tag != .method_definition) continue;

        const replacement_raw = self.scope_owner_remaps.get(source_raw) orelse continue;
        if (replacement_raw == raw or replacement_raw >= self.ast.nodes.items.len) continue;
        const replacement = self.ast.nodes.items[replacement_raw];
        if (replacement.span.start != node.span.start or replacement.span.end != node.span.end) continue;
        if (replacement.tag != .function_expression and replacement.tag != .function and replacement.tag != .function_declaration and
            replacement.tag != .arrow_function_expression) continue;
        const replacement_scope = self.outputOwnedScope(@fromBackingInt(@intCast(replacement_raw))) orelse continue;
        if (@backingInt(replacement_scope) == entry.value_ptr.*) return true;
    }
    return false;
}

/// With parameter expressions, parameters live in their own scope. Lowering
/// emits destructured parameter bindings as body `var` declarations, so their
/// symbols move to the function body scope with them (#5452).
fn moveLoweredPatternParameterBindings(
    self: anytype,
    params_list: ast_mod.NodeList,
    retained_params: ast_mod.NodeList,
    body_scope: @import("../../semantic/scope.zig").ScopeId,
) Error!void {
    if (!self.semantic_edit_enabled or body_scope.isNone()) return;
    const editor = if (self.semantic_editor) |*existing| existing else return;
    if (body_scope.toIndex() >= editor.scopes.items.len) return;
    // The parameter environment is the body scope's parent function scope.
    // Simple parameter lists bind patterns in the body scope itself, so no
    // symbol matches this parent there.
    const parameter_scope = editor.scopes.items[body_scope.toIndex()].parent;
    if (parameter_scope.isNone() or parameter_scope.toIndex() >= editor.scopes.items.len or
        editor.scopes.items[parameter_scope.toIndex()].kind != .function) return;
    const parameter_scope_raw = @backingInt(parameter_scope);
    var retained_bindings: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer retained_bindings.deinit(self.allocator);
    for (0..retained_params.len) |offset| {
        var bindings = try ast_walk.bindingIdentifiers(self.allocator, self.ast, self.ast.readExtraNode(retained_params.start, @intCast(offset)), .{ .cover_grammar_assignment = true });
        defer bindings.deinit();
        while (try bindings.next()) |binding| try retained_bindings.put(self.allocator, @backingInt(binding), {});
    }
    for (self.ast.extra_data.items[params_list.start .. params_list.start + params_list.len]) |raw_param| {
        const pattern = loweredParameterPattern(self, @fromBackingInt(@intCast(raw_param))) orelse continue;
        var bindings = try ast_walk.bindingIdentifiers(self.allocator, self.ast, pattern, .{});
        defer bindings.deinit();
        while (try bindings.next()) |binding| {
            // A native prefix pattern still binds in the parameter environment.
            if (retained_bindings.contains(@backingInt(binding))) continue;
            const id = self.getSymbolIdAt(binding) orelse continue;
            if (id >= editor.symbols.items.len) continue;
            if (@backingInt(editor.symbols.items[id].scope_id) != parameter_scope_raw) continue;
            try self.moveSymbolToOutputScope(id, body_scope);
        }
    }
}

/// Lowering a non-simple parameter list removes its native parameter carrier.
/// An unused engine keeps its exact identity at the emitted ordinary function;
/// observable/captured engines and colliding source bindings need their own protocol.
fn moveUnusedParameterEngine(self: anytype, function_owner: NodeIndex, old_params: NodeIndex, new_params: NodeIndex, body_scope: @import("../../semantic/scope.zig").ScopeId) Error!void {
    if (!self.semantic_edit_enabled or body_scope.isNone() or self.outputOwnedScope(function_owner) != body_scope) return;
    const function = self.ast.getNode(function_owner);
    switch (function.tag) {
        .function, .function_expression, .function_declaration, .method_definition => {},
        else => return,
    }
    if (self.ast.readExtraNode(function.data.extra, ast_mod.FunctionExtra.params) != new_params) return;
    const source_scope = self.outputOwnedScope(old_params) orelse return;
    if (source_scope == body_scope or source_scope.isNone()) return;
    const scopes = if (self.semantic_editor) |*editor| editor.scopes.items else self.scopes;
    const maps = if (self.semantic_editor) |*editor| editor.scope_maps.items else self.scope_maps;
    const symbols = if (self.semantic_editor) |*editor| editor.symbols.items else self.symbols;
    const references = if (self.semantic_editor) |*editor| editor.references.items else self.references;
    if (source_scope.toIndex() >= scopes.len or body_scope.toIndex() >= scopes.len or
        source_scope.toIndex() >= maps.len or body_scope.toIndex() >= maps.len or
        scopes[source_scope.toIndex()].kind != .function or scopes[body_scope.toIndex()].kind != .function or
        scopes[body_scope.toIndex()].parent != source_scope or maps[body_scope.toIndex()].get("arguments") != null) return;
    const params = self.ast.getNode(new_params).data.list;
    for (0..params.len) |offset| {
        if (@import("../native_constructor_timing.zig").simpleFormalBinding(self, self.ast.readExtraNode(params.start, @intCast(offset))) == null) return;
    }
    const handed_off = @import("../native_arguments.zig").completeParameterHandoff(self, function_owner, old_params, new_params, body_scope) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => std.debug.panic("native parameter handoff replacement failed: {s}", .{@errorName(err)}),
    };
    if (handed_off) return;
    var selected: ?u32 = null;
    for (symbols, 0..) |symbol, sid| {
        if (symbol.synthetic_kind != .implicit_arguments) continue;
        if (symbol.scope_id == body_scope) return;
        if (symbol.scope_id != source_scope) continue;
        if (symbol.kind != .parameter or symbol.reference_count != 0 or symbol.write_count != 0 or selected != null) return;
        selected = @intCast(sid);
    }
    const id = selected orelse return;
    if (maps[source_scope.toIndex()].get("arguments") != @as(?usize, id) or
        self.native_arguments_declaration_origins.contains(id)) return;
    var declarations: usize = 0;
    for (references) |row| {
        if (@backingInt(row.symbol_id) != id) continue;
        if (!row.node_index.isNone() or !row.declaration_node_index.isNone() or row.scope_id != source_scope or
            !std.meta.eql(row.flags, @as(@import("../../semantic/symbol.zig").ReferenceFlags, .{ .declare = true }))) return;
        declarations += 1;
    }
    if (declarations != 1) return;
    try self.moveSymbolToOutputScope(id, body_scope);
    try @import("../native_arguments.zig").record(self, @fromBackingInt(id), body_scope);
}

/// A native non-simple replacement retains the original parameter environment.
/// Publish its actual formal edge without relocating any binding or reference.
fn retainNativeParameterCarrier(self: anytype, function_owner: NodeIndex, old_params: NodeIndex, new_params: NodeIndex, body_scope: @import("../../semantic/scope.zig").ScopeId) Error!bool {
    if (!self.semantic_edit_enabled or body_scope.isNone() or old_params == new_params) return false;
    for ([_]NodeIndex{ function_owner, old_params, new_params }) |node|
        if (node.isNone() or @backingInt(node) >= self.ast.nodes.items.len) return false;
    const function = self.ast.getNode(function_owner);
    switch (function.tag) {
        .function, .function_expression, .function_declaration, .method_definition => {},
        else => return false,
    }
    if (self.outputOwnedScope(function_owner) != body_scope or
        self.ast.readExtraNode(function.data.extra, ast_mod.FunctionExtra.params) != new_params or
        self.ast.getNode(old_params).tag != .formal_parameters or self.ast.getNode(new_params).tag != .formal_parameters) return false;
    const source_scope = self.outputOwnedScope(old_params) orelse return false;
    if (source_scope.isNone() or source_scope == body_scope) return false;
    const scopes = if (self.semantic_editor) |*editor| editor.scopes.items else self.scopes;
    if (source_scope.toIndex() >= scopes.len or body_scope.toIndex() >= scopes.len or
        scopes[source_scope.toIndex()].kind != .function or scopes[body_scope.toIndex()].kind != .function or
        scopes[body_scope.toIndex()].parent != source_scope) return false;
    if (self.outputOwnedScope(new_params)) |existing| if (existing != source_scope) return false;
    const formals = self.ast.getNode(new_params).data.list;
    var non_simple = false;
    for (0..formals.len) |offset| {
        if (@import("../native_constructor_timing.zig").simpleFormalBinding(self, self.ast.readExtraNode(formals.start, @intCast(offset))) == null) non_simple = true;
    }
    if (!non_simple) return false;
    try self.remapCopiedScopeOwner(old_params, new_params);
    return true;
}

/// Bindings of identifier parameters lowered into body `var`s move to the
/// body scope, like lowered pattern bindings.
fn moveUnlinkedParameterBindings(
    self: anytype,
    bindings: []const NodeIndex,
    body_scope: @import("../../semantic/scope.zig").ScopeId,
) Error!void {
    if (!self.semantic_edit_enabled or body_scope.isNone() or bindings.len == 0) return;
    const editor = if (self.semantic_editor) |*existing| existing else return;
    if (body_scope.toIndex() >= editor.scopes.items.len) return;
    const parameter_scope = editor.scopes.items[body_scope.toIndex()].parent;
    if (parameter_scope.isNone()) return;
    for (bindings) |binding| {
        const id = self.getSymbolIdAt(binding) orelse continue;
        if (id >= editor.symbols.items.len) continue;
        if (editor.symbols.items[id].scope_id != parameter_scope) continue;
        try self.moveSymbolToOutputScope(id, body_scope);
    }
}

/// A sloppy-mode body that reads its own `arguments` (not a nested
/// function's).
fn sloppyBodyReadsArguments(self: anytype, scope: @import("../../semantic/scope.zig").ScopeId, body: NodeIndex) Error!bool {
    const scopes = if (self.semantic_editor) |*editor| editor.scopes.items else self.scopes;
    if (scope.isNone() or scope.toIndex() >= scopes.len or scopes[scope.toIndex()].is_strict) return false;
    const Scan = struct {
        ast: *const ast_mod.Ast,
        found: bool = false,
        fn visit(ctx: *@This(), _: NodeIndex, n: ast_mod.Node) ast_walk.WalkAction {
            switch (n.tag) {
                .identifier_reference => if (std.mem.eql(u8, ctx.ast.getText(n.data.string_ref), "arguments")) {
                    ctx.found = true;
                    return .stop;
                },
                .function_declaration, .function_expression, .function, .method_definition, .class_declaration, .class_expression => return .skip_children,
                else => {},
            }
            return .descend;
        }
    };
    var scan = Scan{ .ast = self.ast };
    try ast_walk.walkPreorderIterative(self.allocator, self.ast, body, &scan, Scan.visit);
    return scan.found;
}

/// The object/array pattern of a parameter, if it has one.
fn loweredParameterPattern(self: anytype, param_idx: NodeIndex) ?NodeIndex {
    if (param_idx.isNone() or @backingInt(param_idx) >= self.ast.nodes.items.len) return null;
    const param = self.ast.getNode(param_idx);
    var target: NodeIndex = switch (param.tag) {
        .formal_parameter => blk: {
            const slot = param.data.extra + ast_mod.FormalParameterExtra.pattern;
            if (slot >= self.ast.extra_data.items.len) return null;
            break :blk @fromBackingInt(@intCast(self.ast.extra_data.items[slot]));
        },
        else => param_idx,
    };
    if (target.isNone() or @backingInt(target) >= self.ast.nodes.items.len) return null;
    if (self.ast.getNode(target).tag == .assignment_pattern) target = self.ast.getNode(target).data.binary.left;
    if (target.isNone() or @backingInt(target) >= self.ast.nodes.items.len) return null;
    return switch (self.ast.getNode(target).tag) {
        .object_pattern, .array_pattern => target,
        else => null,
    };
}

pub fn appendParameterBodyVarCopies(
    self: anytype,
    function_scope: @import("../../semantic/scope.zig").ScopeId,
    reference_scope: @import("../../semantic/scope.zig").ScopeId,
    statements: *std.ArrayList(NodeIndex),
) Error!void {
    if (function_scope.isNone() or self.parameter_body_var_copies.items.len == 0) return;
    const symbols = if (self.semantic_editor) |*editor| editor.symbols.items else self.symbols;
    const rename_map = self.block_rename_map orelse return;
    for (self.parameter_body_var_copies.items) |copy| {
        if (copy.function_scope != function_scope) continue;
        if (copy.body_var_symbol_id >= symbols.len or copy.parameter_symbol_id >= symbols.len)
            std.debug.panic("parameter/body-var copy references an invalid SymbolId", .{});
        const parameter_name = rename_map.get(copy.parameter_symbol_id) orelse
            std.debug.panic("split parameter has no emitted name", .{});
        const body_symbol = symbols[copy.body_var_symbol_id];
        const body_name = if (body_symbol.synthetic_name.len > 0) body_symbol.synthetic_name else self.ast.getText(body_symbol.name);
        const body_name_span = try self.ast.addString(body_name);
        const parameter_name_span = try self.ast.addString(parameter_name);
        const target = try self.ast.addNode(.{
            .tag = .assignment_target_identifier,
            .span = copy.source_span,
            .data = .{ .string_ref = body_name_span },
        });
        const value = try es_helpers.makeIdentifierRefFromSpan(self, parameter_name_span);
        try self.addSyntheticRefInScope(
            target,
            @fromBackingInt(@intCast(copy.body_var_symbol_id)),
            reference_scope,
            .{ .write = true },
        );
        // The final output walk must preserve this producer-selected parameter
        // identity even when a same-named body `var` is visible in the wrapper.
        try self.addSyntheticRefInScope(value, @fromBackingInt(copy.parameter_symbol_id), reference_scope, .{ .read = true });
        try self.trackExactOutputRead(value, copy.parameter_symbol_id);
        try statements.append(self.allocator, try es_helpers.makeAssignStmt(self, target, value, copy.source_span, 0));
        if (copy.native_fdi_role) {
            const editor = if (self.semantic_editor) |*current| current else std.debug.panic("parameter/body-var copy has no semantic owner", .{});
            @import("../../semantic/parameter_body_var.zig").markLowered(editor.symbols.items, @fromBackingInt(copy.body_var_symbol_id), @fromBackingInt(copy.parameter_symbol_id)) catch
                std.debug.panic("parameter/body-var copy does not match its initial exact role", .{});
        }
    }
}

/// A moved parameter initializer must run before body `var`/function bindings
/// exist. If the body contains dynamic lookup, keep its original declarations
/// and direct eval together in a nested arrow function so the prologue cannot
/// see body-only names. Split parameter/body var identities before this step so
/// the arrow keeps a local copy while parameter expressions retain their binding.
fn supportsDynamicBodyWrapper(
    self: anytype,
    function_scope: @import("../../semantic/scope.zig").ScopeId,
    function_flags: u32,
) bool {
    if (!self.semantic_edit_enabled or function_scope.isNone() or
        self.options.unsupported.arrow or
        ((function_flags & ast_mod.FunctionFlags.is_async) != 0 and self.options.unsupported.async_await) or
        (function_flags & ast_mod.FunctionFlags.is_generator) != 0) return false;
    const scopes = if (self.semantic_editor) |*editor| editor.scopes.items else self.scopes;
    const scope_raw = function_scope.toIndex();
    if (scope_raw >= scopes.len) return false;
    return true;
}

fn reserveDynamicBodyWrapperScope(
    self: anytype,
    function_scope: @import("../../semantic/scope.zig").ScopeId,
    function_flags: u32,
) Error!?@import("../../semantic/scope.zig").ScopeId {
    if (!supportsDynamicBodyWrapper(self, function_scope, function_flags)) return null;
    return try self.reserveGeneratedFunctionScope(function_scope);
}

const DynamicParameterBody = struct { body: NodeIndex, arrow: NodeIndex, shadow: ?es2015_params.NativeArgumentShadow = null };

fn validNativeArgumentShadow(self: anytype, plan: es2015_params.NativeArgumentShadow) bool {
    const editor = if (self.semantic_editor) |*value| value else return false;
    if (plan.ast_owner != self.ast or plan.function_owner.isNone() or @backingInt(plan.function_owner) >= self.ast.nodes.items.len or plan.body_scope.isNone() or plan.scope.isNone() or plan.body_scope.toIndex() >= editor.scopes.items.len or plan.scope.toIndex() >= editor.scopes.items.len or plan.source_symbol >= editor.symbols.items.len) return false;
    const helper_id = plan.native_symbol orelse return false;
    if (helper_id >= editor.symbols.items.len or helper_id == plan.source_symbol or self.outputOwnedScope(plan.function_owner) != plan.body_scope) return false;
    const function = self.ast.getNode(plan.function_owner);
    switch (function.tag) {
        .function, .function_declaration, .function_expression => {},
        else => return false,
    }
    const source = editor.symbols.items[plan.source_symbol];
    const helper = editor.symbols.items[helper_id];
    if (helper.kind != .parameter or helper.scope_id != editor.scopes.items[plan.body_scope.toIndex()].parent or source.scope_id != plan.scope) return false;
    const params = self.ast.readExtraNode(function.data.extra, ast_mod.FunctionExtra.params);
    if (self.outputOwnedScope(params) != helper.scope_id) return false;
    const list = self.ast.getNode(params).data.list;
    if (list.len == 0) return false;
    const formal = self.ast.getNode(self.ast.readExtraNode(list.start, list.len - 1));
    if (formal.tag != .assignment_pattern or self.getSymbolIdAt(formal.data.binary.left) != @as(?u32, helper_id)) return false;
    if (plan.source_declaration.isNone() or @backingInt(plan.source_declaration) >= self.ast.nodes.items.len) return false;
    const declaration = self.ast.getNode(plan.source_declaration);
    var source_binding: NodeIndex = .none;
    if (!plan.block.isNone()) {
        if (@backingInt(plan.block) >= self.ast.nodes.items.len or self.outputOwnedScope(plan.block) != plan.scope or editor.scopes.items[plan.scope.toIndex()].kind != .block or editor.scopes.items[plan.scope.toIndex()].parent != plan.body_scope or source.kind != .variable_let or declaration.tag != .variable_declaration or self.ast.variableDeclarationKind(declaration) != .let) return false;
        const lexical = editor.scopes.items[plan.scope.toIndex()];
        const original = editor.scopes.items[plan.body_scope.toIndex()];
        if (lexical.subtree_has_direct_eval != original.subtree_has_direct_eval or lexical.subtree_has_with != original.subtree_has_with) return false;
        const start = self.ast.readExtra(declaration.data.extra, 1);
        if (self.ast.readExtra(declaration.data.extra, 2) != 1) return false;
        const declarator = self.ast.getNode(self.ast.readExtraNode(start, 0));
        source_binding = self.ast.readExtraNode(declarator.data.extra, 0);
        if (self.ast.readExtraNode(declarator.data.extra, 2).isNone()) return false;
        const block = self.ast.getNode(plan.block);
        if (block.tag != .block_statement) return false;
        var present: usize = 0;
        for (0..block.data.list.len) |i| if (self.ast.readExtraNode(block.data.list.start, @intCast(i)) == plan.source_declaration) {
            present += 1;
        };
        if (present != 1) return false;
    } else {
        if (plan.scope != plan.body_scope or source.kind != .parameter or declaration.tag != .expression_statement) return false;
        const assignment = self.ast.getNode(declaration.data.unary.operand);
        if (assignment.tag != .assignment_expression) return false;
        source_binding = assignment.data.binary.left;
    }
    if (self.getSymbolIdAt(source_binding) != @as(?u32, plan.source_symbol)) return false;
    return @import("../../lexer/scanner.zig").Scanner.identifierNamesEqual(self.ast.identifierNameText(self.ast.getNode(source_binding)), self.ast.identifierNameText(self.ast.getNode(formal.data.binary.left)));
}

fn validDynamicParameterEngineOwner(self: anytype, function_owner: NodeIndex, body_scope: @import("../../semantic/scope.zig").ScopeId, wrapper_scope: @import("../../semantic/scope.zig").ScopeId, wrapper: DynamicParameterBody) bool {
    if (!self.semantic_edit_enabled or self.options.unsupported.arrow or body_scope.isNone() or wrapper_scope.isNone() or
        self.outputOwnedScope(function_owner) != body_scope or self.outputOwnedScope(wrapper.arrow) != wrapper_scope) return false;
    const editor = if (self.semantic_editor) |*value| value else return false;
    const execution_scope = if (wrapper.shadow) |plan| plan.scope else body_scope;
    if (wrapper.shadow) |plan| {
        if (!validNativeArgumentShadow(self, plan) or plan.function_owner != function_owner or plan.body_scope != body_scope) return false;
        if (!plan.block.isNone() and (self.outputOwnedScope(plan.block) != plan.scope or editor.scopes.items[plan.scope.toIndex()].kind != .block or editor.scopes.items[plan.scope.toIndex()].parent != body_scope)) return false;
    }
    if (body_scope.toIndex() >= editor.scopes.items.len or wrapper_scope.toIndex() >= editor.scopes.items.len or
        editor.scopes.items[body_scope.toIndex()].kind != .function or
        editor.scopes.items[wrapper_scope.toIndex()].kind != .function or
        editor.scopes.items[wrapper_scope.toIndex()].parent != execution_scope) return false;
    const function = self.ast.getNode(function_owner);
    switch (function.tag) {
        .function, .function_expression, .function_declaration, .method_definition => {},
        else => return false,
    }
    const raw_flags = self.ast.extra_data.items[function.data.extra + ast_mod.FunctionExtra.flags];
    const flags = if (function.tag == .method_definition) ast_mod.methodFlagsToFunctionFlags(raw_flags) else raw_flags;
    if (flags & (ast_mod.FunctionFlags.is_async | ast_mod.FunctionFlags.is_generator) != 0 or
        self.ast.readExtraNode(function.data.extra, ast_mod.FunctionExtra.body) != wrapper.body) return false;
    const arrow = self.ast.getNode(wrapper.arrow);
    if (arrow.tag != .arrow_function_expression or self.ast.extra_data.items[arrow.data.extra + 2] != 0) return false;
    const body = self.ast.getNode(wrapper.body);
    if (body.tag != .block_statement and body.tag != .function_body) return false;
    if (body.data.list.len == 0) return false;
    var execution_body = body;
    if (wrapper.shadow) |plan| if (!plan.block.isNone()) {
        if (self.ast.readExtraNode(body.data.list.start, body.data.list.len - 1) != plan.block) return false;
        execution_body = self.ast.getNode(plan.block);
        if (execution_body.tag != .block_statement or execution_body.data.list.len == 0) return false;
    };
    const tail = self.ast.getNode(self.ast.readExtraNode(execution_body.data.list.start, execution_body.data.list.len - 1));
    if (tail.tag != .return_statement or tail.data.unary.operand.isNone()) return false;
    const call = self.ast.getNode(tail.data.unary.operand);
    return call.tag == .call_expression and self.ast.readExtraNode(call.data.extra, 0) == wrapper.arrow;
}

fn validImplicitArgumentsWrapper(self: anytype, function_scope: @import("../../semantic/scope.zig").ScopeId, wrapper_scope: @import("../../semantic/scope.zig").ScopeId, arrow: NodeIndex, body: NodeIndex) bool {
    const editor = if (self.semantic_editor) |*value| value else return false;
    if (function_scope.isNone() or wrapper_scope.isNone() or function_scope == wrapper_scope or function_scope.toIndex() >= editor.scopes.items.len or wrapper_scope.toIndex() >= editor.scopes.items.len) return false;
    if (editor.scopes.items[function_scope.toIndex()].kind != .function or editor.scopes.items[wrapper_scope.toIndex()].kind != .function or editor.scopes.items[wrapper_scope.toIndex()].parent != function_scope or self.outputOwnedScope(arrow) != wrapper_scope) return false;
    if (arrow.isNone() or body.isNone() or @backingInt(arrow) >= self.ast.nodes.items.len or @backingInt(body) >= self.ast.nodes.items.len) return false;
    const node = self.ast.getNode(arrow);
    if (node.tag != .arrow_function_expression or self.ast.readExtra(node.data.extra, ast_mod.ArrowExtra.flags) != 0 or self.ast.readExtraNode(node.data.extra, ast_mod.ArrowExtra.body) != body) return false;
    const body_tag = self.ast.getNode(body).tag;
    return body_tag == .block_statement or body_tag == .function_body;
}

fn validImplicitArgumentsShadowWrapper(self: anytype, function_scope: @import("../../semantic/scope.zig").ScopeId, execution_scope: @import("../../semantic/scope.zig").ScopeId, wrapper_scope: @import("../../semantic/scope.zig").ScopeId, arrow: NodeIndex, body: NodeIndex, shadow: ?es2015_params.NativeArgumentShadow) bool {
    if (execution_scope == function_scope) return validImplicitArgumentsWrapper(self, function_scope, wrapper_scope, arrow, body);
    const plan = shadow orelse return false;
    if (!validNativeArgumentShadow(self, plan) or plan.body_scope != function_scope or plan.scope != execution_scope or plan.block.isNone()) return false;
    const editor = &self.semantic_editor.?;
    if (wrapper_scope.isNone() or wrapper_scope.toIndex() >= editor.scopes.items.len or editor.scopes.items[wrapper_scope.toIndex()].kind != .function or editor.scopes.items[wrapper_scope.toIndex()].parent != execution_scope or self.outputOwnedScope(arrow) != wrapper_scope or arrow.isNone() or @backingInt(arrow) >= self.ast.nodes.items.len) return false;
    const node = self.ast.getNode(arrow);
    return node.tag == .arrow_function_expression and self.ast.readExtra(node.data.extra, ast_mod.ArrowExtra.flags) == 0 and self.ast.readExtraNode(node.data.extra, ast_mod.ArrowExtra.body) == body;
}

/// Native initialization of the source body-var cell uses that cell itself as
/// an actual wrapper formal. Do not expose a fresh private name to body eval.
fn appendImplicitArgumentsBodyCopy(self: anytype, function_scope: @import("../../semantic/scope.zig").ScopeId, execution_scope: @import("../../semantic/scope.zig").ScopeId, wrapper_scope: @import("../../semantic/scope.zig").ScopeId, arrow: NodeIndex, inner_body: NodeIndex, span: Span, shadow: ?es2015_params.NativeArgumentShadow) Error!?NodeIndex {
    if (!self.semantic_edit_enabled or self.options.unsupported.default_params) return null;
    if (!validImplicitArgumentsShadowWrapper(self, function_scope, execution_scope, wrapper_scope, arrow, inner_body, shadow)) @panic("implicit arguments copy has no actual lexical wrapper owner");
    const editor = if (self.semantic_editor) |*value| value else unreachable;
    if (editor.scopes.items[function_scope.toIndex()].is_strict) return null;
    var selected: ?usize = null;
    var parameter_id: @import("../../semantic/symbol.zig").SymbolId = .none;
    for (editor.symbols.items, 0..) |symbol, raw| {
        if (symbol.scope_id != function_scope or symbol.kind != .variable_var) continue;
        const role = (@import("../../semantic/parameter_body_var.zig").forSymbol(editor.symbols.items, @fromBackingInt(@as(u32, @intCast(raw)))) catch @panic("invalid implicit arguments FDI role")) orelse continue;
        const parameter = editor.symbols.items[@backingInt(role.parameter)];
        if (parameter.synthetic_kind != .implicit_arguments) continue;
        if (role.state != .native or parameter.scope_id != editor.scopes.items[function_scope.toIndex()].parent or parameter.kind != .parameter or selected != null)
            @panic("implicit arguments body copy lost its exact split environment");
        selected = raw;
        parameter_id = role.parameter;
    }
    const body_id = selected orelse return null;
    const live = try ast_walk.collectReachableNodeIndicesFrom(self.allocator, self.ast, inner_body);
    defer self.allocator.free(live);
    var actual_bindings: usize = 0;
    for (live) |raw| {
        if (self.ast.nodes.items[raw].tag != .binding_identifier or self.generated_body_binding_moves.get(raw) != @as(?u32, @intCast(body_id))) continue;
        if (self.getSymbolIdAt(@fromBackingInt(raw)) != @as(?u32, @intCast(body_id))) @panic("implicit arguments body binding changed its identity");
        actual_bindings += 1;
    }
    if (actual_bindings == 0) @panic("implicit arguments body copy has no actual wrapper binding");
    editor.relocateSymbol(@fromBackingInt(@as(u32, @intCast(body_id))), wrapper_scope) catch @panic("implicit arguments body cell cannot move to its actual wrapper");
    const input = try self.makeNativeArgumentsRef(editor.symbols.items[@backingInt(parameter_id)].scope_id, execution_scope, span);
    if (self.getSymbolIdAt(input) != @as(?u32, @intCast(@backingInt(parameter_id)))) @panic("implicit arguments copy selected another engine");
    if (!editor.scopes.items[wrapper_scope.toIndex()].blocksMangling()) @panic("implicit arguments carrier requires the actual dynamic body environment");
    const body_symbol = editor.symbols.items[body_id];
    const body_name = if (body_symbol.synthetic_name.len > 0) body_symbol.synthetic_name else self.ast.getText(body_symbol.name);
    const binding = try es_helpers.makeExactSyntheticBindingFromSpan(self, try self.ast.addString(body_name));
    editor.attachVarRedeclaration(binding, @fromBackingInt(@as(u32, @intCast(body_id))), wrapper_scope) catch @panic("implicit arguments formal cannot claim the exact body cell");
    try self.setGeneratedSymbolId(binding, @intCast(body_id));
    const params = try self.ast.addFormalParameters(try self.ast.addNodeList(&.{binding}), span);
    self.ast.extra_data.items[self.ast.getNode(arrow).data.extra + ast_mod.ArrowExtra.params] = @backingInt(params);
    @import("../../semantic/parameter_body_var.zig").markLowered(editor.symbols.items, @fromBackingInt(@as(u32, @intCast(body_id))), parameter_id) catch @panic("implicit arguments copy changed its source role");
    return input;
}

fn wrapFunctionBodyForParameterInitializers(
    self: anytype,
    body_idx: NodeIndex,
    parameter_initializers: []const NodeIndex,
    body_var_copies: []const NodeIndex,
    function_scope: @import("../../semantic/scope.zig").ScopeId,
    wrapper_scope: @import("../../semantic/scope.zig").ScopeId,
    is_async: bool,
    span: Span,
    shadow: ?es2015_params.NativeArgumentShadow,
) Error!DynamicParameterBody {
    const execution_scope = if (shadow) |plan| plan.scope else function_scope;
    const body = self.ast.getNode(body_idx);
    if (body.tag != .block_statement and body.tag != .function_body)
        std.debug.panic("dynamic parameter wrapper requires a block function body", .{});
    const list = body.data.list;
    const extra = self.ast.extra_data.items;
    if (list.start > extra.len or list.len > extra.len - list.start)
        std.debug.panic("dynamic parameter wrapper received an invalid function body list", .{});
    const old = extra[list.start .. list.start + list.len];

    // Parameter captures must stay outside the source body wrapper so the
    // moved initializers can read this/arguments/new.target before they run.
    var outer_prefix_len: usize = 0;
    for (old, 0..) |raw, i| {
        if (!self.parameter_capture_statements.contains(raw)) break;
        outer_prefix_len = i + 1;
    }

    const inner_top = self.scratch.items.len;
    defer self.scratch.shrinkRetainingCapacity(inner_top);
    var source_directive_end = outer_prefix_len;
    for (old[outer_prefix_len..]) |raw| {
        const statement = self.ast.getNode(@fromBackingInt(raw));
        if (statement.tag != .directive and (statement.tag != .expression_statement or self.ast.getNode(statement.data.unary.operand).tag != .string_literal)) break;
        source_directive_end += 1;
    }
    for (old[outer_prefix_len..source_directive_end]) |raw| try self.scratch.append(self.allocator, @fromBackingInt(raw));
    try self.scratch.appendSlice(self.allocator, body_var_copies);
    for (old[source_directive_end..]) |raw| try self.scratch.append(self.allocator, @fromBackingInt(@intCast(raw)));
    const inner_list = try self.ast.addNodeList(self.scratch.items[inner_top..]);
    const inner_body = try self.ast.addNode(.{
        .tag = .block_statement,
        .span = body.span,
        .data = .{ .list = inner_list },
    });
    const arrow_flags: u32 = if (is_async) ast_mod.ArrowFlags.is_async else 0;
    const arrow_extra = try self.ast.addExtras(&.{
        @backingInt(NodeIndex.none),
        @backingInt(inner_body),
        arrow_flags,
    });
    const arrow = try self.ast.addNode(.{
        .tag = .arrow_function_expression,
        .span = span,
        .data = .{ .extra = arrow_extra },
    });
    try self.bindReservedFunctionOwner(wrapper_scope, arrow);

    if (self.semantic_edit_enabled) {
        const editor = if (self.semantic_editor) |*value| value else unreachable;
        if (function_scope.isNone() or wrapper_scope.isNone() or wrapper_scope.toIndex() >= editor.scopes.items.len)
            std.debug.panic("dynamic parameter wrapper lost its generated scope", .{});
        const source_scope = editor.scopes.items[function_scope.toIndex()];
        editor.scopes.items[wrapper_scope.toIndex()].subtree_has_direct_eval = source_scope.subtree_has_direct_eval;
        editor.scopes.items[wrapper_scope.toIndex()].subtree_has_with = source_scope.subtree_has_with;
        try self.reparentGeneratedBodyScopes(function_scope, wrapper_scope, inner_body);
        try self.moveGeneratedFunctionBodyBindings(function_scope, wrapper_scope, inner_body);
        try @import("../class_strict_context.zig").moveSourceReferences(self, inner_body, function_scope, function_scope, wrapper_scope);
    }

    const implicit_input = if (!is_async) try appendImplicitArgumentsBodyCopy(self, function_scope, execution_scope, wrapper_scope, arrow, inner_body, span, shadow) else null;
    const call = if (implicit_input) |input| try es_helpers.makeCallExpr(self, arrow, &.{input}, span) else try es_helpers.makeCallExpr(self, arrow, &.{}, span);
    const return_stmt = try self.ast.addNode(.{
        .tag = .return_statement,
        .span = span,
        .data = .{ .unary = .{ .operand = call, .flags = 0 } },
    });
    const outer_top = self.scratch.items.len;
    defer self.scratch.shrinkRetainingCapacity(outer_top);
    for (old[0..outer_prefix_len]) |raw| try self.scratch.append(self.allocator, @fromBackingInt(@intCast(raw)));
    const parameter_top = self.scratch.items.len;
    try self.scratch.appendSlice(self.allocator, parameter_initializers);
    try self.scratch.append(self.allocator, return_stmt);
    if (shadow) |plan| if (!plan.block.isNone()) {
        self.ast.nodes.items[@backingInt(plan.block)].data.list = try self.ast.addNodeList(self.scratch.items[parameter_top..]);
        self.scratch.shrinkRetainingCapacity(parameter_top);
        try self.scratch.append(self.allocator, plan.block);
    };
    const outer_list = try self.ast.addNodeList(self.scratch.items[outer_top..]);
    return .{ .body = try self.ast.addNode(.{
        .tag = body.tag,
        .span = body.span,
        .data = .{ .list = outer_list },
    }), .arrow = arrow, .shadow = shadow };
}

/// A direct body function and a parameter-expression binding have distinct
/// source identities. Publish the function's planned wrapper storage before
/// moved pattern declarations claim the outer body scope.
fn moveParameterShadowFunctions(self: anytype, source_params: NodeIndex, source_body: NodeIndex, body_scope: @import("../../semantic/scope.zig").ScopeId, wrapper_scope: @import("../../semantic/scope.zig").ScopeId) Error!void {
    const parameter_scope = self.outputOwnedScope(source_params) orelse return;
    if (parameter_scope == body_scope) return;
    const editor = if (self.semantic_editor) |*value| value else @panic("parameter shadow functions require the current semantic owner");
    if (editor.scopes.items[body_scope.toIndex()].parent != parameter_scope or editor.scopes.items[wrapper_scope.toIndex()].parent != body_scope or editor.scopes.items[wrapper_scope.toIndex()].kind != .function) @panic("parameter shadow function has no planned lexical wrapper");
    var parameters = try ast_walk.bindingIdentifiers(self.allocator, self.ast, source_params, .{ .cover_grammar_assignment = true });
    defer parameters.deinit();
    var parameter_ids: std.ArrayList(u32) = .empty;
    defer parameter_ids.deinit(self.allocator);
    while (try parameters.next()) |binding| {
        const id = self.getSymbolIdAt(binding) orelse continue;
        const symbol = editor.symbols.items[id];
        if (symbol.kind == .parameter and symbol.scope_id == parameter_scope) try parameter_ids.append(self.allocator, id);
    }
    const list = self.ast.getNode(source_body).data.list;
    for (0..list.len) |i| {
        const node = self.ast.getNode(self.ast.readExtraNode(list.start, @intCast(i)));
        if (node.tag != .function_declaration) continue;
        const binding = self.ast.readExtraNode(node.data.extra, ast_mod.FunctionExtra.name);
        const id = self.getSymbolIdAt(binding) orelse @panic("direct body function lost its source identity");
        const symbol = editor.symbols.items[id];
        if (symbol.scope_id == wrapper_scope) continue; // Last duplicate uses the same exact cell.
        if (symbol.scope_id != body_scope or !symbol.kind.isFunctionLike()) @panic("direct body function has another storage owner");
        const name = if (symbol.synthetic_name.len > 0) symbol.synthetic_name else self.ast.getText(symbol.name);
        for (parameter_ids.items) |parameter_id| {
            const parameter = editor.symbols.items[parameter_id];
            const parameter_name = if (parameter.synthetic_name.len > 0) parameter.synthetic_name else self.ast.getText(parameter.name);
            if (!@import("../../lexer/scanner.zig").Scanner.identifierNamesEqual(name, parameter_name)) continue;
            if (id == parameter_id or editor.scope_maps.items[body_scope.toIndex()].get(name) != @as(?usize, id) or editor.scope_maps.items[parameter_scope.toIndex()].get(parameter_name) != @as(?usize, parameter_id)) @panic("parameter shadow function collision does not match its exact source maps");
            editor.relocateSymbol(@fromBackingInt(id), wrapper_scope) catch @panic("parameter shadow function cannot enter its actual wrapper storage");
            break;
        }
    }
}

fn lowerAllFunctionParams(self: anytype, root: NodeIndex) Error!void {
    const Self = @TypeOf(self.*);
    const node_count = self.ast.nodes.items.len;
    const reachable = try ast_walk.collectReachableNodeIndicesFrom(self.allocator, self.ast, root);
    defer self.allocator.free(reachable);
    for (reachable) |raw| {
        if (raw >= node_count) continue;
        const i: usize = raw;
        const node = self.ast.nodes.items[i];
        if (hasScopedOutputReplacement(self, @fromBackingInt(@intCast(raw)))) continue;
        const saved_scope = self.current_scope;
        defer self.current_scope = saved_scope;
        if (self.transformed_scope_owner_map.get(@intCast(i)) orelse self.scope_owner_map.get(@intCast(i))) |scope_id| {
            self.current_scope = @fromBackingInt(@intCast(scope_id));
        }
        switch (node.tag) {
            .function_declaration, .function_expression, .function, .method_definition => {
                // extra layout: [name_or_key(0), params(1), body(2), ...]
                const e = node.data.extra;
                if (e + 2 >= self.ast.extra_data.items.len) continue;
                const params_idx: NodeIndex = @fromBackingInt(@intCast(self.ast.extra_data.items[e + 1]));
                if (params_idx.isNone() or @backingInt(params_idx) >= self.ast.nodes.items.len) continue;
                const params_node = self.ast.getNode(params_idx);
                if (params_node.tag != .formal_parameters) continue;
                const params_list = params_node.data.list;
                if (params_list.len == 0) continue;
                // #4251: default_params 미지원(es5..es2015)이면 전체(default/rest/
                // destructuring) lowering. object_spread 만 미지원(es2016/es2017)이면
                // object rest 든 param 만 — default-param-only 함수 불필요 lowering 회피.
                // #4819: defaults after the first lowered object-rest
                // parameter still move into the body to preserve evaluation
                // order. When body dynamic lookup would expose body vars to
                // those defaults, a lexical arrow wrapper isolates the source
                // body for supported sync/async functions. Generators, targets
                // without arrows, and same-name parameter/body declarations
                // stay on the conservative path pending exact value-copying.
                const needs_lowering = if (self.options.unsupported.default_params)
                    es2015_params.ES2015Params(Self).hasDefaultOrRest(self, params_list)
                else
                    try es2015_params.ES2015Params(Self).hasObjectRestParam(self, params_list);
                if (!needs_lowering) continue;
                const raw_flags = if (e + ast_mod.FunctionExtra.flags < self.ast.extra_data.items.len)
                    self.ast.extra_data.items[e + ast_mod.FunctionExtra.flags]
                else
                    0;
                const function_flags = if (node.tag == .method_definition)
                    ast_mod.methodFlagsToFunctionFlags(raw_flags)
                else
                    raw_flags;
                const parameter_env = @import("../parameter_environment.zig");
                if (try parameter_env.parameterListHasDynamicLookup(self, params_list)) continue;
                const source_body_idx = self.ast.functionBodyBlock(node) orelse continue;
                const shared_native_environment = try parameter_env.sharedNativeParameterEnvironment(self, @fromBackingInt(@as(u32, @intCast(i))), params_idx, self.current_scope);
                const body_has_dynamic_lookup = try parameter_env.functionBodyHasDynamicLookup(
                    self,
                    self.current_scope,
                    source_body_idx,
                );
                // Moving a default expression into this body changes what
                // direct eval/with can see. Only proceed when the source body
                // can be isolated in a generated arrow scope; otherwise keep
                // the original parameter syntax intact.
                if (body_has_dynamic_lookup and
                    !supportsDynamicBodyWrapper(self, self.current_scope, function_flags)) continue;

                const body_wrapper_scope = if (body_has_dynamic_lookup and !shared_native_environment)
                    try reserveDynamicBodyWrapperScope(self, self.current_scope, function_flags)
                else
                    null;
                if (body_wrapper_scope) |scope| try moveParameterShadowFunctions(self, params_idx, source_body_idx, self.current_scope, scope);

                // A non-simple parameter list gives a sloppy function unmapped
                // `arguments`; lowered parameters would be mapped again (#5668).
                var unlinked_parameters: std.ArrayList(NodeIndex) = .empty;
                defer unlinked_parameters.deinit(self.allocator);
                if (self.options.unsupported.default_params and
                    try sloppyBodyReadsArguments(self, self.current_scope, source_body_idx))
                    self.unlinked_parameter_bindings = &unlinked_parameters;
                var lr = try es2015_params.ES2015Params(Self).lowerParamsPass2ForFunction(self, params_list, node.span, .{
                    .ast_owner = self.ast,
                    .function_node = @fromBackingInt(@as(u32, @intCast(i))),
                    .params_node = params_idx,
                    .body_scope = self.current_scope,
                });
                self.unlinked_parameter_bindings = null;
                defer lr.body_stmts.deinit(self.allocator);
                const parameter_execution_scope = if (lr.argument_shadow) |plan| plan.scope else self.current_scope;
                if (lr.argument_shadow) |plan| if (!plan.block.isNone()) {
                    const wrapper_scope = body_wrapper_scope orelse @panic("native lexical shadow requires its planned body wrapper");
                    self.semantic_editor.?.reparentScope(wrapper_scope, plan.scope) catch @panic("native body wrapper cannot enter its real parameter shadow block");
                };
                // Parameter initializers now execute in the emitted function
                // body. Move direct expression provenance and nested lexical
                // roots at this producer, before publishing the new body.
                if (self.semantic_edit_enabled) {
                    if (self.outputOwnedScope(params_idx)) |parameter_scope| {
                        for (lr.body_stmts.items) |statement| {
                            try self.reparentGeneratedBodyScopes(parameter_scope, parameter_execution_scope, statement);
                            try @import("../class_strict_context.zig").moveSourceReferences(self, statement, parameter_scope, parameter_scope, parameter_execution_scope);
                        }
                    }
                }
                try moveLoweredPatternParameterBindings(self, params_list, lr.new_params, self.current_scope);
                try moveUnlinkedParameterBindings(self, unlinked_parameters.items, self.current_scope);
                const parameter_initializer_len = lr.body_stmts.items.len;
                const copy_scope = body_wrapper_scope orelse self.current_scope;
                try appendParameterBodyVarCopies(self, self.current_scope, copy_scope, &lr.body_stmts);

                // formal_parameters 노드를 새로 만들어 extras[e+1]에 연결.
                // (여러 function 노드가 동일 params_idx를 공유할 수 있으므로 in-place mutation 금지:
                //  prependToFunctionBody 등은 params_idx를 복사하여 새 function 노드를 만든다.)
                const new_params_node = try self.ast.addFormalParameters(lr.new_params, params_node.span);
                self.ast.extra_data.items[e + 1] = @backingInt(new_params_node);
                const retained_carrier = try retainNativeParameterCarrier(self, @fromBackingInt(@as(u32, @intCast(i))), params_idx, new_params_node, self.current_scope);
                if (!retained_carrier) @import("../worklet_class_clone.zig").handoffSimpleParameterDeclarations(self, @fromBackingInt(@as(u32, @intCast(i))), params_idx, new_params_node, self.current_scope) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => std.debug.panic("lowered worklet formals lost their declaration handoff: {s}", .{@errorName(err)}),
                };
                if (lr.native_formal_scope) |scope| {
                    if (!retained_carrier or self.outputOwnedScope(new_params_node) != scope)
                        @panic("native formal bindings lost their exact planned parameter carrier");
                }
                if (body_wrapper_scope == null and function_flags & (ast_mod.FunctionFlags.is_async | ast_mod.FunctionFlags.is_generator) == 0)
                    try moveUnusedParameterEngine(self, @fromBackingInt(@as(u32, @intCast(i))), params_idx, new_params_node, self.current_scope);

                if (lr.body_stmts.items.len > 0) {
                    const body_idx: NodeIndex = @fromBackingInt(@intCast(self.ast.extra_data.items[e + 2]));
                    if (!body_idx.isNone()) {
                        const wrapper = if (body_wrapper_scope) |wrapper_scope|
                            try wrapFunctionBodyForParameterInitializers(
                                self,
                                body_idx,
                                lr.body_stmts.items[0..parameter_initializer_len],
                                lr.body_stmts.items[parameter_initializer_len..],
                                self.current_scope,
                                wrapper_scope,
                                (function_flags & ast_mod.FunctionFlags.is_async) != 0,
                                node.span,
                                lr.argument_shadow,
                            )
                        else
                            null;
                        const new_body = if (wrapper) |value| value.body else if (shared_native_environment) shared_body: {
                            const plan = try @import("../native_constructor_function_cells.zig").prepareSharedParameterBody(self, @fromBackingInt(@as(u32, @intCast(i))), params_idx, new_params_node, body_idx, self.current_scope);
                            const statements = self.scratch.items.len;
                            defer self.scratch.shrinkRetainingCapacity(statements);
                            try self.scratch.appendSlice(self.allocator, lr.body_stmts.items);
                            for (0..plan.storage_declarations.len) |j| try self.scratch.append(self.allocator, self.ast.readExtraNode(plan.storage_declarations.start, @intCast(j)));
                            for (0..plan.entry_initializers.len) |j| try self.scratch.append(self.allocator, self.ast.readExtraNode(plan.entry_initializers.start, @intCast(j)));
                            self.ast.nodes.items[@backingInt(body_idx)].data.list = plan.remaining_body;
                            break :shared_body try prependParameterInitializers(self, body_idx, self.scratch.items[statements..]);
                        } else try prependParameterInitializers(self, body_idx, lr.body_stmts.items);
                        self.ast.extra_data.items[e + 2] = @backingInt(new_body);
                        if (wrapper) |value| {
                            if (function_flags & (ast_mod.FunctionFlags.is_async | ast_mod.FunctionFlags.is_generator) == 0) {
                                if (!validDynamicParameterEngineOwner(self, @fromBackingInt(@as(u32, @intCast(i))), self.current_scope, body_wrapper_scope.?, value))
                                    @panic("dynamic parameter engine lost its exact lexical wrapper owner");
                                try moveUnusedParameterEngine(self, @fromBackingInt(@as(u32, @intCast(i))), params_idx, new_params_node, self.current_scope);
                            }
                        }
                    }
                }
                if (lr.retained_prefix) |proof| if (!try es2015_params.ES2015Params(Self).validRetainedPrefix(self, proof, new_params_node))
                    @panic("retained native prefix lost its exact binding or storage owner");
            },
            // #4251: arrow 의 object rest param 은 es2017(arrow 지원, object_spread
            // 미지원)에서 arrow→function 변환 없이(this 보존) param 만 lowering.
            // es5 에선 arrow 가 Pass 1 에서 function 으로 변환돼 위 arm 이 처리 →
            // 여기 도달하는 건 orphan(무해). default/array-rest arrow param 도 그
            // 경로라, 여기선 object rest 만 대상(hasObjectRestParam).
            .arrow_function_expression => {
                // arrow 가 미지원(es5..es2015)이면 Pass 1 에서 function 으로 변환됨 →
                // 여기 남은 arrow 노드는 orphan(변환 전 원본). 처리하면 temp 카운터를
                // 소비해 live function 의 temp 이름이 밀리고 dead `var _a` 가 샌다.
                // arrow 가 지원되는 타겟(es2016/es2017)에서만 keep-arrow lowering.
                if (self.options.unsupported.arrow) continue;
                const e = node.data.extra;
                if (e + 1 >= self.ast.extra_data.items.len) continue;
                const params_idx: NodeIndex = @fromBackingInt(@intCast(self.ast.extra_data.items[e + 0]));
                if (params_idx.isNone() or @backingInt(params_idx) >= self.ast.nodes.items.len) continue;
                const params_node = self.ast.getNode(params_idx);
                if (params_node.tag != .formal_parameters) continue;
                const params_list = params_node.data.list;
                if (params_list.len == 0) continue;
                if (!(try es2015_params.ES2015Params(Self).hasObjectRestParam(self, params_list))) continue;
                // (이전 #4251 array-rest skip 제거: lowerParamsImpl 이 default_params
                //  지원 타겟에선 array-rest 를 native 유지하므로 arrow arguments 크래시
                //  없음. object rest 만 temp+body 분해.)
                var lr = try es2015_params.ES2015Params(Self).lowerParamsPass2ForNativeArrow(self, params_list, node.span, .{
                    .ast_owner = self.ast,
                    .function_node = @fromBackingInt(@as(u32, @intCast(i))),
                    .params_node = params_idx,
                    .body_scope = self.current_scope,
                });
                defer lr.body_stmts.deinit(self.allocator);
                // The result owns these slices until batch append succeeds.
                // Cover every allocation/error edge during body assembly too.
                defer if (lr.native_arrow_statements) |unregistered| {
                    self.allocator.free(unregistered.handles);
                    self.allocator.free(unregistered.prefix_rows);
                };
                if (self.semantic_edit_enabled) {
                    if (self.outputOwnedScope(params_idx)) |parameter_scope| {
                        for (lr.body_stmts.items) |statement| {
                            try self.reparentGeneratedBodyScopes(parameter_scope, self.current_scope, statement);
                            try @import("../class_strict_context.zig").moveSourceReferences(self, statement, parameter_scope, parameter_scope, self.current_scope);
                        }
                    }
                }

                const new_params_node = try self.ast.addFormalParameters(lr.new_params, params_node.span);
                self.ast.extra_data.items[e + 0] = @backingInt(new_params_node);
                if (lr.native_arrow_formals) |plan| {
                    es2015_params.ES2015Params(Self).publishNativeArrowFormals(self, plan, new_params_node) catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        error.InvalidNativeArrowParameterOwner => @panic("native arrow formals lost their actual expression environment"),
                    };
                }

                if (lr.body_stmts.items.len > 0) {
                    const body_idx: NodeIndex = @fromBackingInt(@intCast(self.ast.extra_data.items[e + 1]));
                    if (!body_idx.isNone()) {
                        // arrow expression body → `{ return expr; }` 먼저 (implicit
                        // return 보존), 그 후 rest 추출문 prepend. (es2015_arrow 동형.)
                        const body_node = self.ast.getNode(body_idx);
                        const block_body = if (body_node.tag != .block_statement and body_node.tag != .function_body) blk: {
                            const ret = try self.ast.addNode(.{
                                .tag = .return_statement,
                                .span = node.span,
                                .data = .{ .unary = .{ .operand = body_idx, .flags = 0 } },
                            });
                            const list = try self.ast.addNodeList(&.{ret});
                            break :blk try self.ast.addNode(.{
                                .tag = .block_statement,
                                .span = node.span,
                                .data = .{ .list = list },
                            });
                        } else body_idx;
                        const new_body = try self.prependStatementsToBody(block_body, lr.body_stmts.items);
                        self.ast.extra_data.items[e + 1] = @backingInt(new_body);
                    }
                }
                if (lr.native_arrow_statements) |statement_plan| {
                    var assembled = statement_plan;
                    @import("../native_arrow_statement_publication.zig").assemble(self, &assembled, new_params_node, self.ast.readExtraNode(e, ast_mod.ArrowExtra.body), root) catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        else => @panic("native arrow body assembly rejected its creation handles"),
                    };
                    try self.native_arrow_statement_batch.?.plans.append(self.allocator, assembled);
                    lr.native_arrow_statements = null; // The batch now owns both slices.
                }
            },
            else => {},
        }
    }
}

test "lowered parameter import provenance moves before generic output validation" {
    const Scanner = @import("../../lexer/scanner.zig").Scanner;
    const Parser = @import("../../parser/parser.zig").Parser;
    const Analyzer = @import("../../semantic/analyzer.zig").SemanticAnalyzer;
    const Transformer = @import("../transformer.zig").Transformer;
    const ScopeId = @import("../../semantic/scope.zig").ScopeId;
    for ([_][]const u8{
        "function read(value=import('./dep.cjs')){let body=1;return value}",
        "function read(value=()=>import('./dep.cjs')){let body=1;return value}",
        "const object={read(value=import('./dep.cjs')){let body=1;return value}};",
    }, 0..) |source, context| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var scanner = try Scanner.init(a, source);
        var parser = Parser.init(a, &scanner);
        _ = try parser.parse();
        var analyzer = Analyzer.init(a, &parser.ast);
        try analyzer.analyze();
        var body_scope: ScopeId = .none;
        for (analyzer.symbols.items) |symbol|
            if (std.mem.eql(u8, symbol.nameText(parser.ast.source), "body")) {
                body_scope = symbol.scope_id;
            };
        try std.testing.expect(!body_scope.isNone());
        var entries = analyzer.node_scope_provenance.iterator();
        const entry = entries.next().?;
        const import_node = entry.key_ptr.*;
        const original_scope = entry.value_ptr.scope;
        try std.testing.expect(original_scope != body_scope);
        var transformer = try Transformer.init(a, &parser.ast, .{ .unsupported = @import("../compat.zig").fromESTarget(.es5), .emit_runtime_helper_imports = false });
        try transformer.initSymbolIds(analyzer.symbol_ids.items);
        transformer.symbols = analyzer.symbols.items;
        transformer.references = analyzer.references.items;
        transformer.scopes = analyzer.scopes.items;
        transformer.scope_maps = analyzer.scope_maps.items;
        transformer.scope_owner_map = analyzer.scope_owner_map;
        transformer.node_scope_provenance = analyzer.node_scope_provenance;
        transformer.semantic_edit_enabled = true;
        const root: NodeIndex = @fromBackingInt(@as(u32, @intCast(transformer.ast.nodes.items.len - 1)));
        try transformer.buildBlockRenameMap();
        const visited_root = try transformer.visitNode(root);
        try transformer.registerGeneratedFunctionScopes(visited_root, transformer.programScope());
        const live = try ast_walk.collectReachableNodeIndicesFrom(a, transformer.ast, visited_root);
        const parameter_scope = analyzer.scopes.items[body_scope.toIndex()].parent;
        var parameter_owners: usize = 0;
        for (live) |raw| {
            const owner: NodeIndex = @fromBackingInt(raw);
            if (transformer.outputOwnedScope(owner) != @as(?ScopeId, body_scope)) continue;
            const function = transformer.ast.getNode(owner);
            if (function.tag != .function_declaration and function.tag != .function_expression and function.tag != .method_definition) continue;
            const parameters = transformer.readNodeIdx(function.data.extra, 1);
            try std.testing.expectEqual(@as(?ScopeId, parameter_scope), transformer.outputOwnedScope(parameters));
            parameter_owners += 1;
        }
        try std.testing.expectEqual(@as(usize, 1), parameter_owners);
        try lowerAllFunctionParams(&transformer, visited_root);
        const editor = &transformer.semantic_editor.?;
        const moved = editor.node_scope_provenance.get(import_node).?;
        try std.testing.expectEqual(import_node, moved.source_node);
        if (context != 1) {
            try std.testing.expectEqual(body_scope, moved.scope);
        } else {
            try std.testing.expectEqual(original_scope, moved.scope);
            try std.testing.expectEqual(body_scope, editor.scopes.items[original_scope.toIndex()].parent);
        }
    }
}

test "lowered unused native arguments keeps its SID at the actual function owner" {
    const Scanner = @import("../../lexer/scanner.zig").Scanner;
    const Parser = @import("../../parser/parser.zig").Parser;
    const Analyzer = @import("../../semantic/analyzer.zig").SemanticAnalyzer;
    const Transformer = @import("../transformer.zig").Transformer;
    const ScopeId = @import("../../semantic/scope.zig").ScopeId;
    for ([_][]const u8{
        "function read(value=1){let body=1;return value+body}",
        "const read=function(value=1){let body=1;return value+body};",
        "const object={read(value=1){let body=1;return value+body}};",
        "function read(value={}){let body=1;return value+body}",
        "function read(value=[]){let body=1;return value+body}",
    }) |source| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var scanner = try Scanner.init(a, source);
        var parser = Parser.init(a, &scanner);
        _ = try parser.parse();
        var analyzer = Analyzer.init(a, &parser.ast);
        analyzer.enable_stmt_info = true;
        analyzer.enable_exact_declaration_anchors = true;
        try analyzer.analyze();
        var body_scope: ScopeId = .none;
        var engine: ?u32 = null;
        for (analyzer.symbols.items, 0..) |symbol, id| {
            if (std.mem.eql(u8, symbol.nameText(parser.ast.source), "body")) body_scope = symbol.scope_id;
            if (symbol.kind == .parameter and symbol.synthetic_kind == .implicit_arguments) {
                try std.testing.expect(engine == null);
                engine = @intCast(id);
            }
        }
        const id = engine orelse return error.MissingNativeEngine;
        const source_scope = analyzer.symbols.items[id].scope_id;
        try std.testing.expect(!body_scope.isNone() and source_scope != body_scope);
        var t = try Transformer.init(a, &parser.ast, .{ .unsupported = @import("../compat.zig").fromESTarget(.es5), .emit_runtime_helper_imports = false });
        try t.initSymbolIds(analyzer.symbol_ids.items);
        t.symbols = analyzer.symbols.items;
        t.references = analyzer.references.items;
        t.scopes = analyzer.scopes.items;
        t.scope_maps = analyzer.scope_maps.items;
        t.scope_owner_map = analyzer.scope_owner_map;
        t.unresolved_references = &analyzer.unresolved_references;
        t.semantic_edit_enabled = true;
        const root: NodeIndex = @fromBackingInt(@as(u32, @intCast(t.ast.nodes.items.len - 1)));
        try t.buildBlockRenameMap();
        const output = try t.visitNode(root);
        try t.registerGeneratedFunctionScopes(output, t.programScope());
        try lowerAllFunctionParams(&t, output);
        const editor = &t.semantic_editor.?;
        var actual_owners: usize = 0;
        var actual_owner: ?u32 = null;
        const live = try ast_walk.collectReachableNodeIndicesFrom(a, t.ast, output);
        for (live) |raw| {
            const owner: NodeIndex = @fromBackingInt(raw);
            if (t.outputOwnedScope(owner) != body_scope) continue;
            const function = t.ast.getNode(owner);
            switch (function.tag) {
                .function, .function_expression, .function_declaration, .method_definition => {},
                else => continue,
            }
            const params = t.ast.readExtraNode(function.data.extra, ast_mod.FunctionExtra.params);
            try std.testing.expect(t.outputOwnedScope(params) == null);
            actual_owners += 1;
            actual_owner = raw;
        }
        try std.testing.expectEqual(@as(usize, 1), actual_owners);
        try std.testing.expectEqual(@as(?ScopeId, body_scope), t.native_arguments_declaration_origins.get(id));
        // Final program assembly changes positions, never the engine identity.
        const empty = try t.ast.addNode(.{ .tag = .empty_statement, .span = .{ .start = 0, .end = 0 }, .data = .{ .none = 0 } });
        const old_list = t.ast.getNode(output).data.list;
        const entries = try a.alloc(NodeIndex, old_list.len + 1);
        entries[0] = empty;
        for (0..old_list.len) |offset| entries[offset + 1] = t.ast.readExtraNode(old_list.start, @intCast(offset));
        t.ast.nodes.items[@backingInt(output)].data.list = try t.ast.addNodeList(entries);
        try @import("../native_arguments.zig").publish(&t, output);
        const contexts = try @import("../../semantic/statement_coordinates.zig").collect(a, t.ast, output);
        const expected_context = contexts[actual_owner.?].?;
        try std.testing.expectEqual(@as(u32, 1), expected_context.stmt_idx);
        try std.testing.expectEqual(body_scope, editor.symbols.items[id].scope_id);
        try std.testing.expectEqual(@as(?usize, id), editor.scope_maps.items[body_scope.toIndex()].get("arguments"));
        try std.testing.expect(editor.scope_maps.items[source_scope.toIndex()].get("arguments") == null);
        var declarations: usize = 0;
        for (editor.references.items) |row| {
            if (@backingInt(row.symbol_id) != id) continue;
            try std.testing.expect(row.flags.declare and row.node_index.isNone() and row.declaration_node_index.isNone());
            try std.testing.expectEqual(body_scope, row.scope_id);
            try std.testing.expectEqual(expected_context.stmt_idx, row.stmt_idx);
            try std.testing.expectEqual(expected_context.scope_stmt_idx, row.scope_stmt_idx);
            declarations += 1;
        }
        try std.testing.expectEqual(@as(usize, 1), declarations);
    }
}

test "dynamic body wrapper publishes the actual simple parameter engine owner" {
    const Scanner = @import("../../lexer/scanner.zig").Scanner;
    const Parser = @import("../../parser/parser.zig").Parser;
    const Analyzer = @import("../../semantic/analyzer.zig").SemanticAnalyzer;
    const Transformer = @import("../transformer.zig").Transformer;
    const ScopeId = @import("../../semantic/scope.zig").ScopeId;
    var sibling_controls: usize = 0;
    var simple_cases: usize = 0;
    var retained_non_simple_cases: usize = 0;
    var no_split_environment_cases: usize = 0;
    source_cases: for ([_][]const u8{
        "let outside=3;function run({a,...rest},value=outside){let body=1;var outside=4;eval('outside');return [a,value,outside,rest.b,body]}",
        "let outside=3;function sameName({a,...rest},value=outside){let body=1;var outside=4,a;eval('a');return [a,value,outside,rest.b,body]}",
        "function sameNameClosure({a,...rest},read=()=>a){let body=1;var a;eval('a=11');return [a,read(),rest.b,body]}",
        "function read({a,...rest},value=2){let body=1;eval('a');return [a,value,rest,body]}",
        "const read=function({a,...rest},value=2){let body=1;eval('a');return [a,value,rest,body]};",
        "const object={read({a,...rest},value=2){let body=1;eval('a');return [a,value,rest,body]}};",
        "class Read{read({a,...rest},value=2){let body=1;eval('a');return [a,value,rest,body]}}",
        "const read=function self({a,...rest},value=2){let body=1;eval('a');return [a,value,rest,body]};",
        "function read([{a,...rest}],value=2){let body=1;eval('a');return [a,value,rest,body]}",
        "function read({a,...rest},value=2,tail=3){let body=1;eval('a');return [a,value,rest,tail,body]}",
        "function read({a,...rest}={a:2},value=3){let body=1;eval('a');return [a,value,rest,body]}",
        "const read=function({a,...rest}={a:2},value=3){let body=1;eval('a');return [a,value,rest,body]};",
        "const object={read({a,...rest}={a:2},value=3){let body=1;eval('a');return [a,value,rest,body]}};",
        "class Read{read({a,...rest}={a:2},value=3){let body=1;eval('a');return [a,value,rest,body]}}",
        "const read=function self({a,...rest}={a:2},value=3){let body=1;eval('a');return [a,value,rest,body]};",
        "function read([{a,...rest}]=[{a:2}],value=3){let body=1;eval('a');return [a,value,rest,body]}",
        "function read(head=1,{a,...rest}){let body=1;eval('a');return [a,head,rest,body]}",
        "function read({a,...rest},...tail){let body=1;eval('a');return [a,tail,rest,body]}",
        "function read([head]=[1],{a,...rest}){let body=1;eval('a');return [a,head,rest,body]}",
        "function read({a,...rest},...[tail]){let body=1;eval('a');return [a,tail,rest,body]}",
        "function read(head=1,{a,...rest},...tail){let body=1;eval('a');return [a,head,tail,rest,body]}",
        "function read(head=1,{a,...rest},...[tail]){let body=1;eval('a');return [a,head,tail,rest,body]}",
        "function read([head]=[1],{a,...rest},get=()=>head){let body=1;var head;eval('head=9');return [head,get(),a,rest,body]}",
        "const object={read({a,...rest},value=2){let body=1;const sibling=()=>body;eval('a');return [a,value,rest,sibling()]}};",
        "function read({a,...rest},get=()=>a){let body=1;function a(){return 9}eval('a');return [a(),get(),body]}",
    }) |source| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var scanner = try Scanner.init(a, source);
        var parser = Parser.init(a, &scanner);
        _ = try parser.parse();
        var analyzer = Analyzer.init(a, &parser.ast);
        analyzer.enable_stmt_info = true;
        analyzer.enable_exact_declaration_anchors = true;
        try analyzer.analyze();
        var body_scope: ScopeId = .none;
        var engine: ?u32 = null;
        for (analyzer.symbols.items, 0..) |symbol, id| {
            if (std.mem.eql(u8, symbol.nameText(parser.ast.source), "body")) body_scope = symbol.scope_id;
            if (symbol.kind == .parameter and symbol.synthetic_kind == .implicit_arguments) {
                try std.testing.expect(engine == null);
                engine = @intCast(id);
            }
        }
        const source_scope = if (engine) |sid| analyzer.symbols.items[sid].scope_id else ScopeId.none;
        try std.testing.expect(!body_scope.isNone() and source_scope != body_scope);
        if (engine == null) {
            var initial_owners = analyzer.scope_owner_map.iterator();
            while (initial_owners.next()) |entry| {
                try std.testing.expect(parser.ast.getNode(@fromBackingInt(entry.key_ptr.*)).tag != .formal_parameters);
            }
        }
        var t = try Transformer.init(a, &parser.ast, .{ .unsupported = @import("../compat.zig").fromESTarget(.es2017), .emit_runtime_helper_imports = false });
        try t.initSymbolIds(analyzer.symbol_ids.items);
        t.symbols = analyzer.symbols.items;
        t.references = analyzer.references.items;
        t.scopes = analyzer.scopes.items;
        t.scope_maps = analyzer.scope_maps.items;
        t.scope_owner_map = analyzer.scope_owner_map;
        t.unresolved_references = &analyzer.unresolved_references;
        t.semantic_edit_enabled = true;
        const root: NodeIndex = @fromBackingInt(@as(u32, @intCast(t.ast.nodes.items.len - 1)));
        try t.buildBlockRenameMap();
        const output = try t.visitNode(root);
        try t.registerGeneratedFunctionScopes(output, t.programScope());
        try lowerAllFunctionParams(&t, output);
        const editor = &t.semantic_editor.?;
        var actual_owners: usize = 0;
        var actual_owner: ?u32 = null;
        const live = try ast_walk.collectReachableNodeIndicesFrom(a, t.ast, output);
        if (engine == null) {
            var owners: usize = 0;
            for (live) |raw| {
                const owner: NodeIndex = @fromBackingInt(raw);
                if (t.outputOwnedScope(owner) != body_scope) continue;
                const function = t.ast.getNode(owner);
                switch (function.tag) {
                    .function, .function_expression, .function_declaration, .method_definition => {},
                    else => continue,
                }
                const params = t.ast.readExtraNode(function.data.extra, ast_mod.FunctionExtra.params);
                try std.testing.expect(t.outputOwnedScope(params) == null);
                var bindings = try ast_walk.bindingIdentifiers(a, t.ast, params, .{ .cover_grammar_assignment = true });
                var count: usize = 0;
                while (try bindings.next()) |binding| {
                    const binding_id = t.getSymbolIdAt(binding) orelse return error.MissingNativeParameterBinding;
                    try std.testing.expectEqual(body_scope, editor.symbols.items[binding_id].scope_id);
                    count += 1;
                }
                try std.testing.expect(count > 0);
                owners += 1;
            }
            try std.testing.expectEqual(@as(usize, 1), owners);
            no_split_environment_cases += 1;
            continue :source_cases;
        }
        const id = engine.?;
        for (live) |raw| {
            const owner: NodeIndex = @fromBackingInt(raw);
            if (t.outputOwnedScope(owner) != body_scope) continue;
            const function = t.ast.getNode(owner);
            switch (function.tag) {
                .function, .function_expression, .function_declaration, .method_definition => {},
                else => continue,
            }
            const params = t.ast.readExtraNode(function.data.extra, ast_mod.FunctionExtra.params);
            const actual_formals = t.ast.getNode(params).data.list;

            var actual_simple = true;
            for (0..actual_formals.len) |offset| {
                if (@import("../native_constructor_timing.zig").simpleFormalBinding(&t, t.ast.readExtraNode(actual_formals.start, @intCast(offset))) == null) actual_simple = false;
            }
            if (!actual_simple) {
                // Native defaults keep their original environment and IDs;
                // only the exact current formal carrier changes.
                try std.testing.expectEqual(source_scope, editor.symbols.items[id].scope_id);
                try std.testing.expectEqual(@as(?ScopeId, source_scope), t.outputOwnedScope(params));
                const scope_utils = @import("../output_scope_test_utils.zig");
                var actual_parents = try scope_utils.buildParentMap(a, t.ast, output);
                var actual_scope_owners: std.AutoHashMapUnmanaged(u32, u32) = .empty;
                for (live) |candidate| {
                    if (t.outputOwnedScope(@fromBackingInt(candidate))) |scope| try actual_scope_owners.put(a, candidate, @backingInt(scope));
                }
                var native_bindings = try ast_walk.bindingIdentifiers(a, t.ast, params, .{ .cover_grammar_assignment = true });
                var native_binding_count: usize = 0;
                while (try native_bindings.next()) |binding| {
                    const binding_id = t.getSymbolIdAt(binding) orelse return error.MissingNativeParameterBinding;
                    try std.testing.expectEqual(source_scope, editor.symbols.items[binding_id].scope_id);
                    try std.testing.expectEqual(@as(?ScopeId, source_scope), scope_utils.expectedScope(t.ast, output, &actual_parents, &actual_scope_owners, @backingInt(binding)));
                    if (binding_id >= analyzer.symbols.items.len) {
                        var raw_reads: usize = 0;
                        for (editor.references.items) |row| {
                            if (@backingInt(row.symbol_id) != binding_id or !row.flags.read) continue;
                            try std.testing.expect(!row.node_index.isNone());
                            try std.testing.expectEqual(body_scope, row.scope_id);
                            try std.testing.expectEqual(@as(?ScopeId, body_scope), scope_utils.expectedScope(t.ast, output, &actual_parents, &actual_scope_owners, @backingInt(row.node_index)));
                            raw_reads += 1;
                        }
                        try std.testing.expect(raw_reads > 0);
                    }
                    native_binding_count += 1;
                }
                try std.testing.expect(native_binding_count > 0);
                var native_engine_declarations: usize = 0;
                for (editor.references.items) |row| {
                    if (@backingInt(row.symbol_id) != id) continue;
                    try std.testing.expect(row.node_index.isNone() and row.declaration_node_index.isNone() and row.flags.declare);
                    try std.testing.expectEqual(source_scope, row.scope_id);
                    native_engine_declarations += 1;
                }
                try std.testing.expectEqual(@as(usize, 1), native_engine_declarations);
                try std.testing.expect(t.native_arguments_declaration_origins.get(id) == null);
                var old_params: NodeIndex = .none;
                var source_parameter_owners: usize = 0;
                var source_owners = analyzer.scope_owner_map.iterator();
                while (source_owners.next()) |entry| {
                    const source_node: NodeIndex = @fromBackingInt(entry.key_ptr.*);
                    if (entry.value_ptr.* != @backingInt(source_scope) or t.ast.getNode(source_node).tag != .formal_parameters) continue;
                    old_params = source_node;
                    source_parameter_owners += 1;
                }
                try std.testing.expectEqual(@as(usize, 1), source_parameter_owners);
                const rows_before = try a.dupe(@import("../../semantic/symbol.zig").Reference, editor.references.items);
                const symbols_before = try a.dupe(@import("../../semantic/symbol.zig").Symbol, editor.symbols.items);
                try std.testing.expect(!try retainNativeParameterCarrier(&t, owner, old_params, params, source_scope));
                try std.testing.expect(!try retainNativeParameterCarrier(&t, owner, params, params, body_scope));
                try std.testing.expect(!try retainNativeParameterCarrier(&t, owner, old_params, old_params, body_scope));
                const foreign_formals = try t.ast.addFormalParameters(actual_formals, t.ast.getNode(params).span);
                try std.testing.expect(!try retainNativeParameterCarrier(&t, owner, old_params, foreign_formals, body_scope));
                try std.testing.expect(t.outputOwnedScope(foreign_formals) == null);
                const saved_kind = editor.scopes.items[source_scope.toIndex()].kind;
                editor.scopes.items[source_scope.toIndex()].kind = .block;
                try std.testing.expect(!try retainNativeParameterCarrier(&t, owner, old_params, params, body_scope));
                editor.scopes.items[source_scope.toIndex()].kind = saved_kind;
                const saved_parent = editor.scopes.items[body_scope.toIndex()].parent;
                editor.scopes.items[body_scope.toIndex()].parent = t.programScope();
                try std.testing.expect(!try retainNativeParameterCarrier(&t, owner, old_params, params, body_scope));
                editor.scopes.items[body_scope.toIndex()].parent = saved_parent;
                const new_scope = t.transformed_scope_owner_map.get(@backingInt(params)).?;
                try t.transformed_scope_owner_map.put(a, @backingInt(params), @backingInt(body_scope));
                try std.testing.expect(!try retainNativeParameterCarrier(&t, owner, old_params, params, body_scope));
                try t.transformed_scope_owner_map.put(a, @backingInt(params), new_scope);
                const saved_formals = t.ast.getNode(params).data.list;
                var first_binding = try ast_walk.bindingIdentifiers(a, t.ast, params, .{ .cover_grammar_assignment = true });
                const binding = (try first_binding.next()).?;
                t.ast.nodes.items[@backingInt(params)].data.list = try t.ast.addNodeList(&.{binding});
                try std.testing.expect(!try retainNativeParameterCarrier(&t, owner, old_params, params, body_scope));
                t.ast.nodes.items[@backingInt(params)].data.list = saved_formals;
                try std.testing.expect(try retainNativeParameterCarrier(&t, owner, old_params, params, body_scope));
                try std.testing.expectEqual(@as(?ScopeId, source_scope), t.outputOwnedScope(params));
                try std.testing.expectEqualDeep(rows_before, editor.references.items);
                try std.testing.expectEqualDeep(symbols_before, editor.symbols.items);
                retained_non_simple_cases += 1;
                std.debug.print("retained non-simple parameter carrier id={d} sourceScope={d} newParams={d}\n", .{ id, source_scope.toIndex(), @backingInt(params) });
                continue :source_cases;
            }
            try std.testing.expect(t.outputOwnedScope(params) == null);
            simple_cases += 1;
            try std.testing.expectEqual(source_scope, editor.scopes.items[body_scope.toIndex()].parent);
            const actual_body = t.ast.readExtraNode(function.data.extra, ast_mod.FunctionExtra.body);
            const body_list = t.ast.getNode(actual_body).data.list;
            const return_node = t.ast.getNode(t.ast.readExtraNode(body_list.start, body_list.len - 1));
            const call = t.ast.getNode(return_node.data.unary.operand);
            const arrow = t.ast.readExtraNode(call.data.extra, 0);
            const wrapper_scope = t.outputOwnedScope(arrow).?;
            const wrapper: DynamicParameterBody = .{ .body = actual_body, .arrow = arrow };
            try std.testing.expect(validDynamicParameterEngineOwner(&t, owner, body_scope, wrapper_scope, wrapper));
            try std.testing.expect(!validDynamicParameterEngineOwner(&t, owner, source_scope, wrapper_scope, wrapper));
            try std.testing.expect(!validDynamicParameterEngineOwner(&t, owner, body_scope, source_scope, wrapper));
            const arrow_flags = t.ast.extra_data.items[t.ast.getNode(arrow).data.extra + 2];
            t.ast.extra_data.items[t.ast.getNode(arrow).data.extra + 2] = ast_mod.ArrowFlags.is_async;
            try std.testing.expect(!validDynamicParameterEngineOwner(&t, owner, body_scope, wrapper_scope, wrapper));
            t.ast.extra_data.items[t.ast.getNode(arrow).data.extra + 2] = arrow_flags;
            const saved_parent = editor.scopes.items[wrapper_scope.toIndex()].parent;
            editor.scopes.items[wrapper_scope.toIndex()].parent = source_scope;
            try std.testing.expect(!validDynamicParameterEngineOwner(&t, owner, body_scope, wrapper_scope, wrapper));
            editor.scopes.items[wrapper_scope.toIndex()].parent = saved_parent;
            const saved_unsupported_arrow = t.options.unsupported.arrow;
            t.options.unsupported.arrow = true;
            try std.testing.expect(!validDynamicParameterEngineOwner(&t, owner, body_scope, wrapper_scope, wrapper));
            t.options.unsupported.arrow = saved_unsupported_arrow;
            for (live) |candidate_raw| {
                const candidate: NodeIndex = @fromBackingInt(candidate_raw);
                if (candidate == arrow or t.ast.getNode(candidate).tag != .arrow_function_expression) continue;
                const sibling_scope = t.outputOwnedScope(candidate) orelse continue;
                try std.testing.expect(!validDynamicParameterEngineOwner(&t, owner, body_scope, sibling_scope, .{ .body = actual_body, .arrow = candidate }));
                sibling_controls += 1;
            }
            try std.testing.expect(validDynamicParameterEngineOwner(&t, owner, body_scope, wrapper_scope, wrapper));
            std.debug.print("dynamic wrapper engine id={d} sourceScope={d} bodyScope={d} actualOwner={d} newParams={d} simple=true recorded={any}\n", .{ id, source_scope.toIndex(), body_scope.toIndex(), raw, @backingInt(params), t.native_arguments_declaration_origins.get(id) });
            actual_owners += 1;
            actual_owner = raw;
        }
        try std.testing.expectEqual(@as(usize, 1), actual_owners);
        try std.testing.expectEqual(@as(?ScopeId, body_scope), t.native_arguments_declaration_origins.get(id));
        const source_contexts = try @import("../../semantic/statement_coordinates.zig").collect(a, t.ast, output);
        const original_context = source_contexts[actual_owner.?].?;
        // Final program assembly changes positions, never the engine identity.
        const empty = try t.ast.addNode(.{ .tag = .empty_statement, .span = .{ .start = 0, .end = 0 }, .data = .{ .none = 0 } });
        const old_list = t.ast.getNode(output).data.list;
        const entries = try a.alloc(NodeIndex, old_list.len + 1);
        entries[0] = empty;
        for (0..old_list.len) |offset| entries[offset + 1] = t.ast.readExtraNode(old_list.start, @intCast(offset));
        t.ast.nodes.items[@backingInt(output)].data.list = try t.ast.addNodeList(entries);
        try @import("../native_arguments.zig").publish(&t, output);
        const contexts = try @import("../../semantic/statement_coordinates.zig").collect(a, t.ast, output);
        const expected_context = contexts[actual_owner.?].?;
        try std.testing.expectEqual(original_context.stmt_idx + 1, expected_context.stmt_idx);
        try std.testing.expectEqual(body_scope, editor.symbols.items[id].scope_id);
        try std.testing.expectEqual(@as(?usize, id), editor.scope_maps.items[body_scope.toIndex()].get("arguments"));
        try std.testing.expect(editor.scope_maps.items[source_scope.toIndex()].get("arguments") == null);
        var declarations: usize = 0;
        for (editor.references.items) |row| {
            if (@backingInt(row.symbol_id) != id) continue;
            try std.testing.expect(row.flags.declare and row.node_index.isNone() and row.declaration_node_index.isNone());
            try std.testing.expectEqual(body_scope, row.scope_id);
            try std.testing.expectEqual(expected_context.stmt_idx, row.stmt_idx);
            try std.testing.expectEqual(expected_context.scope_stmt_idx, row.scope_stmt_idx);
            declarations += 1;
        }
        try std.testing.expectEqual(@as(usize, 1), declarations);
    }
    try std.testing.expect(sibling_controls > 0);
    try std.testing.expectEqual(@as(usize, 3), simple_cases);
    try std.testing.expectEqual(@as(usize, 20), retained_non_simple_cases);
    try std.testing.expectEqual(@as(usize, 2), no_split_environment_cases);
}

test "dynamic body wrapper native runtime and source arguments controls" {
    const Case = struct { source: []const u8, call: []const u8 };
    for ([_]Case{
        .{ .source = "let outside=3;function run({a,...rest},value=outside){let body=1;var outside=4;eval('outside');return [a,value,outside,rest.b,body]}", .call = "run({a:1,b:2})" },
        .{ .source = "let outside=3;function sameName({a,...rest},value=outside){let body=1;var outside=4,a;eval('a');return [a,value,outside,rest.b,body]}", .call = "sameName({a:7,b:8})" },
        .{ .source = "function sameNameClosure({a,...rest},read=()=>a){let body=1;var a;eval('a=11');return [a,read(),rest.b,body]}", .call = "sameNameClosure({a:12,b:13})" },
        .{ .source = "function read({a,...rest},value=2){let body=1;eval('a');return [a,value,rest,body]}", .call = "read({a:1,b:2})" },
        .{ .source = "const read=function({a,...rest},value=2){let body=1;eval('a');return [a,value,rest,body]};", .call = "read({a:1,b:2})" },
        .{ .source = "const object={read({a,...rest},value=2){let body=1;eval('a');return [a,value,rest,body]}};", .call = "object.read({a:1,b:2})" },
        .{ .source = "class Read{read({a,...rest},value=2){let body=1;eval('a');return [a,value,rest,body]}}", .call = "new Read().read({a:1,b:2})" },
        .{ .source = "const read=function self({a,...rest},value=2){let body=1;eval('a');return [a,value,rest,body]};", .call = "read({a:1,b:2})" },
        .{ .source = "function read([{a,...rest}],value=2){let body=1;eval('a');return [a,value,rest,body]}", .call = "read([{a:1,b:2}])" },
        .{ .source = "function read({a,...rest},value=2,tail=3){let body=1;eval('a');return [a,value,rest,tail,body]}", .call = "read({a:1,b:2})" },
        .{ .source = "function read({a,...rest},value=2,arguments){eval('arguments');return [a,value,arguments,rest.b]}", .call = "read({a:1,b:2},undefined,'source')" },
        .{ .source = "function read({a,...rest},value=2){var arguments=['source'];eval('arguments');return [a,value,arguments[0],rest.b]}", .call = "read({a:1,b:2})" },
        .{ .source = "function read({a,...rest},value=2){eval('a');return [a,value,arguments.length,rest.b]}", .call = "read({a:1,b:2})" },
        .{ .source = "function read({a,...rest},value=2){const get=()=>arguments;eval('a');return [a,value,get().length,rest.b]}", .call = "read({a:1,b:2})" },
        .{ .source = "function read({a,...rest}={a:2},value=3){let body=1;eval('a');return [a,value,rest,body]}", .call = "read()" },
        .{ .source = "const read=function({a,...rest}={a:2},value=3){let body=1;eval('a');return [a,value,rest,body]};", .call = "read()" },
        .{ .source = "const object={read({a,...rest}={a:2},value=3){let body=1;eval('a');return [a,value,rest,body]}};", .call = "object.read()" },
        .{ .source = "class Read{read({a,...rest}={a:2},value=3){let body=1;eval('a');return [a,value,rest,body]}}", .call = "new Read().read()" },
        .{ .source = "const read=function self({a,...rest}={a:2},value=3){let body=1;eval('a');return [a,value,rest,body]};", .call = "read()" },
        .{ .source = "function read([{a,...rest}]=[{a:2}],value=3){let body=1;eval('a');return [a,value,rest,body]}", .call = "read()" },
        .{ .source = "function read(head=1,{a,...rest}){let body=1;eval('a');return [a,head,rest,body]}", .call = "read(undefined,{a:2,b:3})" },
        .{ .source = "function read({a,...rest},...tail){let body=1;eval('a');return [a,tail,rest,body]}", .call = "read({a:2,b:3},5,6)" },
        .{ .source = "function read([head]=[1],{a,...rest}){let body=1;eval('a');return [a,head,rest,body]}", .call = "read(undefined,{a:2,b:3})" },
        .{ .source = "function read({a,...rest},...[tail]){let body=1;eval('a');return [a,tail,rest,body]}", .call = "read({a:2,b:3},5,6)" },
        .{ .source = "function read(head=1,{a,...rest},...tail){let body=1;eval('a');return [a,head,tail,rest,body]}", .call = "read(undefined,{a:2,b:3},5,6)" },
        .{ .source = "function read(head=1,{a,...rest},...[tail]){let body=1;eval('a');return [a,head,tail,rest,body]}", .call = "read(undefined,{a:2,b:3},5,6)" },
        .{ .source = "function read([head]=[1],{a,...rest},get=()=>head){let body=1;var head;eval('head=9');return [head,get(),a,rest,body]}", .call = "read(undefined,{a:2,b:3})" },
        .{ .source = "function read({a,...rest},value=2){eval('arguments[1]=9');return [value,read.length]}", .call = "read({a:1,b:2},undefined)" },
        .{ .source = "function read({a,...rest},value=2){eval('a');arguments[1]=9;return value}", .call = "read({a:1,b:2},undefined)" },
        .{ .source = "function read({a,...rest},value=2){eval('a');return [value,arguments[1]]}", .call = "read({a:1,b:2},undefined)" },
        .{ .source = "function read({a,...rest},value=2){eval('a');try{return arguments.callee===read}catch(e){return e.name}}", .call = "read({a:1,b:2})" },
        .{ .source = "function read({a,...rest},value=(arguments[1]=4,2)){eval('a');return [value,arguments[1]]}", .call = "read({a:1,b:2},undefined)" },
        .{ .source = "function read({a,...rest}){eval('a');try{return [read.length,arguments.callee]}catch(e){return [read.length,e.name]}}", .call = "read({a:1,b:2})" },
        .{ .source = "function read({[1+1]:a,...rest}){eval('a');try{return [read.length,arguments.callee]}catch(e){return [read.length,e.name]}}", .call = "read({2:1,b:2})" },
        .{ .source = "function read({a=1,...rest}){eval('a');try{return [read.length,arguments.callee]}catch(e){return [read.length,e.name]}}", .call = "read({b:2})" },
        .{ .source = "function read({a,...rest},value=2){var arguments;eval('arguments');return [value,typeof arguments]}", .call = "read({a:1,b:2})" },
        .{ .source = "function read({a,...rest},get=()=>arguments){var arguments;eval('arguments=[\"body\"]');return [get()[0].a,arguments[0]]}", .call = "read({a:1,b:2})" },
        .{ .source = "function read({a,...rest},value=2){var arguments=['source'];eval('arguments');return [value,arguments[0]]}", .call = "read({a:1,b:2})" },
        .{ .source = "function read({a,...rest},value=2){function arguments(){return 'own'}eval('arguments');return [value,arguments()]}", .call = "read({a:1,b:2})" },
        .{ .source = "function read({a,...rest}){var a=9;eval('a');return a}", .call = "read({a:1,b:2})" },
        .{ .source = "function read({a,...rest}){function a(){return 9}eval('a');return a()}", .call = "read({a:1,b:2})" },
        .{ .source = "function read({a,...rest}){function a(){return 8}function a(){return 9}eval('a');return [a(),a.name]}", .call = "read({a:1,b:2})" },
        .{ .source = "function read({a,...rest}){function a(){return a}const old=a;a=9;eval('a');return [old()===a,a,old.name]}", .call = "read({a:1,b:2})" },
        .{ .source = "function read({a,...rest}){function a(){return other()}function other(){return 9}eval('a');return [a(),other.name]}", .call = "read({a:1,b:2})" },
        .{ .source = "function read({a,...rest},value=2){function a(){return 9}eval('a');return [a(),value]}", .call = "read({a:1,b:2})" },
        .{ .source = "function read({a,...rest}){function nested(){var a=8;return a}eval('a');return [a,nested()]}", .call = "read({a:1,b:2})" },
        .{ .source = "function read({a,...rest},get=()=>a){let body=1;function a(){return 9}eval('a');return [a(),get(),body]}", .call = "read({a:1,b:2})" },
        .{ .source = "function read({a,...rest},value=2){var a;function a(){return 9}eval('a');return [a(),value]}", .call = "read({a:1,b:2})" },
        .{ .source = "function read({a,...rest},value=2){function a(){return 9}var a;eval('a');return [a(),value]}", .call = "read({a:1,b:2})" },
        .{ .source = "function read({a,...rest}){var a;function a(){return 9}eval('a');return a()}", .call = "read({a:1,b:2})" },
        .{ .source = "function read({a,...rest},value=2,code){var arguments;try{return typeof eval(code)}catch(e){return e.name}}", .call = "read({a:1},undefined,String.fromCharCode(95,98))" },
        .{ .source = "function read({a,...rest},code){try{return typeof eval(code)}catch(e){return e.name}}", .call = "read({a:1},String.fromCharCode(95,98))" },
        .{ .source = "function read({a,...rest},code){return JSON.stringify(eval(code))}", .call = "read({a:1,b:2},String.fromCharCode(114,101,115,116))" },
        .{ .source = "function read({a,...rest},code){return JSON.stringify(eval(code))}", .call = "read({a:1,b:2},String.fromCharCode(114,101,115,116),9,10)" },
        .{ .source = "function read({a=1,...rest},code){try{return typeof eval(code)}catch(e){return e.name}}", .call = "read({a:1},String.fromCharCode(95,98))" },
        .{ .source = "function read({a=1,...rest},code){return JSON.stringify(eval(code))}", .call = "read({b:2},String.fromCharCode(114,101,115,116),9,10)" },
        .{ .source = "function read({a=1,...rest},code){var rest;return JSON.stringify(eval(code))}", .call = "read({b:2},String.fromCharCode(114,101,115,116),9,10)" },
        .{ .source = "function read({[rest]:a,...rest},code){eval('a');return a}function run(){try{return read({undefined:7},'a',9)}catch(e){return e.name}}", .call = "run()" },
        .{ .source = "function read({a=rest,...rest},code){eval('a');return a}function run(){try{return read({},'a',9)}catch(e){return e.name}}", .call = "run()" },
        .{ .source = "function read({a=()=>rest,...rest},code){var rest;return [a().b,JSON.stringify(eval(code))]}", .call = "read({b:2},String.fromCharCode(114,101,115,116),9)" },
        .{ .source = "function read({a=()=>rest,...rest},code){function rest(){return 9}return [a().b,eval(code)()]}", .call = "read({b:2},String.fromCharCode(114,101,115,116),9)" },
    }, 0..) |case, index| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const source = try std.fmt.allocPrint(a, "{s};console.log(JSON.stringify({s}));", .{ case.source, case.call });
        const native = try std.process.run(a, std.testing.io, .{ .argv = &.{ "node", "-e", source } });
        try std.testing.expect(native.term == .exited and native.term.exited == 0);
        for ([_]@import("../compat.zig").ESTarget{ .es2015, .es2017 }) |target| for ([_]bool{ false, true }) |minify| {
            errdefer std.debug.print("dynamic wrapper runtime source={d} target={s} min={any}\n", .{ index, @tagName(target), minify });
            const result = try @import("../../transpile.zig").transpile(a, source, "input.cjs", .{
                .unsupported = @import("../compat.zig").fromESTarget(target),
                .minify_identifiers = minify,
                .minify_syntax = minify,
                .minify_whitespace = minify,
            });
            const actual = try std.process.run(a, std.testing.io, .{ .argv = &.{ "node", "-e", result.code } });
            if (!(actual.term == .exited and actual.term.exited == 0)) std.debug.print("{s}\n{s}\n", .{ result.code, actual.stderr });
            try std.testing.expect(actual.term == .exited and actual.term.exited == 0);
            try std.testing.expectEqualStrings(native.stdout, actual.stdout);
        };
    }
}

test "dynamic body wrapper Flow canonical rest carrier native controls" {
    const Case = struct { source: []const u8, reference: []const u8, call: []const u8 };
    for ([_]Case{
        .{ .source = "// @flow\nconst React={forwardRef:fn=>fn};component Card(ref?: mixed,...props:{label?:string}){return props.label}", .reference = "const React={forwardRef:fn=>fn};function Card({...props},ref){return props.label}", .call = "Card({label:'ok'})" },
        .{ .source = "// @flow\nconst React={forwardRef:fn=>fn};component Card(ref?: mixed,value:string,...props:{label?:string}){return [value,props.label,ref]}", .reference = "const React={forwardRef:fn=>fn};function Card({value,...props},ref){return [value,props.label,ref]}", .call = "Card({value:'v',label:'ok'},'r')" },
        .{ .source = "// @flow\nconst React={forwardRef:fn=>fn};component Card(value:string,...props:{label?:string}){return [value,props.label]}", .reference = "const React={forwardRef:fn=>fn};function Card({value,...props}){return [value,props.label]}", .call = "Card({value:'v',label:'ok'})" },
        .{ .source = "// @flow\nconst React={forwardRef:fn=>fn};component Card(value:string='fallback',...props:{label?:string}){return [value,props.label]}", .reference = "const React={forwardRef:fn=>fn};function Card({value='fallback',...props}){return [value,props.label]}", .call = "Card({label:'ok'})" },
        .{ .source = "// @flow\nconst React={forwardRef:fn=>fn};function outer(){const text='nested';component Card(ref?:mixed,...props:{label?:string}){return [text,props.label]}return Card({label:'ok'})}", .reference = "const React={forwardRef:fn=>fn};function outer(){const text='nested';function Card({...props},ref){return [text,props.label]}return Card({label:'ok'})}", .call = "outer()" },
        .{ .source = "// @flow\nconst React={forwardRef:fn=>fn};const Card_withRef='user';component Card(ref?:mixed,...props:{label?:string}){return [Card_withRef,props.label]}", .reference = "const React={forwardRef:fn=>fn};const Card_withRef='user';function Card({...props},ref){return [Card_withRef,props.label]}", .call = "Card({label:'ok'})" },
        .{ .source = "// @flow\nconst React={forwardRef:fn=>fn};component Card(ref?:mixed,value:string='fallback',...props:{label?:string}){return [value,props.label,ref]}", .reference = "const React={forwardRef:fn=>fn};function Card({value='fallback',...props},ref){return [value,props.label,ref]}", .call = "Card({label:'ok'},'r')" },
        .{ .source = "// @flow\nconst React={forwardRef:fn=>fn};component Card(ref?:mixed,...props:{label?:string}){return props.label}component Other(ref?:mixed,...props:{label?:string}){return props.label}", .reference = "const React={forwardRef:fn=>fn};function Card({...props},ref){return props.label}function Other({...props},ref){return props.label}", .call = "[Card({label:'a'}),Other({label:'b'})]" },
        .{ .source = "// @flow\nconst React={forwardRef:fn=>fn};component Card(value:string){return value}", .reference = "const React={forwardRef:fn=>fn};function Card({value}){return value}", .call = "Card({value:'plain'})" },
        .{ .source = "// @flow\nconst React={forwardRef:fn=>fn};component Card(...props:{label?:string}){return props.label}", .reference = "const React={forwardRef:fn=>fn};function Card(props){return props.label}", .call = "Card({label:'only'})" },
        .{ .source = "// @flow\nfunction Card({value,...props}){return [value,props.label]}", .reference = "function Card({value,...props}){return [value,props.label]}", .call = "Card({value:'v',label:'ok'})" },
    }, 0..) |case, index| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const source = try std.fmt.allocPrint(a, "{s};console.log(JSON.stringify({s}));", .{ case.source, case.call });
        const reference = try std.fmt.allocPrint(a, "{s};console.log(JSON.stringify({s}));", .{ case.reference, case.call });
        const native = try std.process.run(a, std.testing.io, .{ .argv = &.{ "node", "-e", reference } });
        try std.testing.expect(native.term == .exited and native.term.exited == 0);
        for ([_]@import("../compat.zig").ESTarget{ .es2015, .es2017 }) |target| for ([_]bool{ false, true }) |minify| {
            errdefer std.debug.print("dynamic wrapper runtime source={d} target={s} min={any}\n", .{ index, @tagName(target), minify });
            std.debug.print("Flow rest case={d} target={s} min={any}\n", .{ index, @tagName(target), minify });
            const result = try @import("../../transpile.zig").transpile(a, source, "input.flow", .{
                .unsupported = @import("../compat.zig").fromESTarget(target),
                .minify_identifiers = minify,
                .minify_syntax = minify,
                .minify_whitespace = minify,
            });
            const actual = try std.process.run(a, std.testing.io, .{ .argv = &.{ "node", "-e", result.code } });
            if (!(actual.term == .exited and actual.term.exited == 0)) std.debug.print("{s}\n{s}\n", .{ result.code, actual.stderr });
            try std.testing.expect(actual.term == .exited and actual.term.exited == 0);
            try std.testing.expectEqualStrings(native.stdout, actual.stdout);
        };
    }
}

test "lowered unused native arguments rejects malformed ownership without identity recovery" {
    const Scanner = @import("../../lexer/scanner.zig").Scanner;
    const Parser = @import("../../parser/parser.zig").Parser;
    const Analyzer = @import("../../semantic/analyzer.zig").SemanticAnalyzer;
    const Transformer = @import("../transformer.zig").Transformer;
    const ScopeId = @import("../../semantic/scope.zig").ScopeId;
    const Mutation = enum { owner_missing, owner_wrong_valid_scope, body_parent, source_map_wrong_valid_sid, target_occupied, hidden_target_engine, wrong_kind, wrong_role, duplicate_declaration, missing_declaration, wrong_declaration_scope, observable_row, counted_reference, unpublished_parameters, non_simple_parameters };
    for (std.enums.values(Mutation)) |mutation| {
        errdefer std.debug.print("unused engine rejected ownership mutation: {s}\n", .{@tagName(mutation)});
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var scanner = try Scanner.init(a, "function read(value=1){let body=1;return body}");
        var parser = Parser.init(a, &scanner);
        const root = try parser.parse();
        var analyzer = Analyzer.init(a, &parser.ast);
        analyzer.enable_stmt_info = true;
        analyzer.enable_exact_declaration_anchors = true;
        try analyzer.analyze();
        var engine: ?u32 = null;
        var body_binding: ?u32 = null;
        for (analyzer.symbols.items, 0..) |symbol, index| {
            if (symbol.synthetic_kind == .implicit_arguments) engine = @intCast(index);
            if (std.mem.eql(u8, symbol.nameText(parser.ast.source), "body")) body_binding = @intCast(index);
        }
        const id = engine orelse return error.MissingNativeEngine;
        const body_id = body_binding orelse return error.MissingBodyBinding;
        const old_scope = analyzer.symbols.items[id].scope_id;
        const body_scope: ScopeId = analyzer.symbols.items[body_id].scope_id;
        var t = try Transformer.init(a, &parser.ast, .{});
        try t.initSymbolIds(analyzer.symbol_ids.items);
        t.symbols = analyzer.symbols.items;
        t.references = analyzer.references.items;
        t.scopes = analyzer.scopes.items;
        t.scope_maps = analyzer.scope_maps.items;
        t.scope_owner_map = analyzer.scope_owner_map;
        t.semantic_edit_enabled = true;
        // Start an editor without changing the known source identity.
        try t.moveSymbolToOutputScope(id, old_scope);
        const editor = &t.semantic_editor.?;
        const owner = t.ast.readExtraNode(t.ast.getNode(root).data.list.start, 0);
        const extra = t.ast.getNode(owner).data.extra;
        const old_params = t.ast.readExtraNode(extra, ast_mod.FunctionExtra.params);
        var new_params = try t.ast.addFormalParameters(.{ .start = 0, .len = 0 }, t.ast.getNode(old_params).span);
        t.ast.extra_data.items[extra + ast_mod.FunctionExtra.params] = @backingInt(new_params);
        var declaration: ?usize = null;
        for (editor.references.items, 0..) |row, index| if (@backingInt(row.symbol_id) == id and row.flags.declare) {
            try std.testing.expect(declaration == null);
            declaration = index;
        };
        const row_index = declaration orelse return error.MissingNativeDeclaration;
        switch (mutation) {
            .owner_missing => {
                _ = t.scope_owner_map.remove(@backingInt(owner));
                _ = editor.scope_owner_map.remove(@backingInt(owner));
            },
            .owner_wrong_valid_scope => try t.transformed_scope_owner_map.put(a, @backingInt(owner), @backingInt(t.programScope())),
            .body_parent => editor.scopes.items[body_scope.toIndex()].parent = t.programScope(),
            .source_map_wrong_valid_sid => try editor.scope_maps.items[old_scope.toIndex()].put(a, "arguments", body_id),
            .target_occupied => try editor.scope_maps.items[body_scope.toIndex()].put(a, "arguments", body_id),
            .hidden_target_engine => {
                var hidden = editor.symbols.items[id];
                hidden.scope_id = body_scope;
                try editor.symbols.append(a, hidden);
            },
            .wrong_kind => editor.symbols.items[id].kind = .variable_var,
            .wrong_role => editor.symbols.items[id].synthetic_kind = .enum_iife_parameter,
            .duplicate_declaration => try editor.references.append(a, editor.references.items[row_index]),
            .missing_declaration => editor.references.items[row_index].flags.declare = false,
            .wrong_declaration_scope => editor.references.items[row_index].scope_id = t.programScope(),
            .observable_row => editor.references.items[row_index].flags.read = true,
            .counted_reference => editor.symbols.items[id].reference_count = 1,
            .unpublished_parameters => t.ast.extra_data.items[extra + ast_mod.FunctionExtra.params] = @backingInt(old_params),
            .non_simple_parameters => {
                new_params = old_params;
                t.ast.extra_data.items[extra + ast_mod.FunctionExtra.params] = @backingInt(old_params);
            },
        }
        const symbol_count = editor.symbols.items.len;
        const reference_count = editor.references.items.len;
        try moveUnusedParameterEngine(&t, owner, old_params, new_params, body_scope);
        try std.testing.expectEqual(old_scope, editor.symbols.items[id].scope_id);
        try std.testing.expectEqual(symbol_count, editor.symbols.items.len);
        try std.testing.expectEqual(reference_count, editor.references.items.len);
        try std.testing.expect(!t.native_arguments_declaration_origins.contains(id));
    }
}

test "dynamic body wrapper preserves real parameter expression environments" {
    const Scanner = @import("../../lexer/scanner.zig").Scanner;
    const Parser = @import("../../parser/parser.zig").Parser;
    const Analyzer = @import("../../semantic/analyzer.zig").SemanticAnalyzer;
    for ([_]struct { source: []const u8, expressions: bool, length: u32 }{
        .{ .source = "function read([head=1],{a,...rest},value=2){eval('a');return [read.length,head,a,value]}", .expressions = true, .length = 2 },
        .{ .source = "function read({head=1},{a,...rest},value=2){eval('a');return [read.length,head,a,value]}", .expressions = true, .length = 2 },
        .{ .source = "function read({a,...rest},value){var a;eval('a');return [read.length,arguments.length,typeof Object.getOwnPropertyDescriptor(arguments,'callee').get]}", .expressions = false, .length = 2 },
        .{ .source = "function read({[1+1]:a,...rest},value){eval('a');return [read.length,arguments.length,typeof Object.getOwnPropertyDescriptor(arguments,'callee').get]}", .expressions = true, .length = 2 },
        .{ .source = "function read({a=1,...rest},value){eval('a');return [read.length,arguments.length,typeof Object.getOwnPropertyDescriptor(arguments,'callee').get]}", .expressions = true, .length = 2 },
        .{ .source = "function read({a,...rest},value=2){eval('a');return [read.length,arguments.length,typeof Object.getOwnPropertyDescriptor(arguments,'callee').get]}", .expressions = true, .length = 1 },
    }) |case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const result = try @import("../../transpile.zig").transpile(a, case.source, "input.cjs", .{ .unsupported = @import("../compat.zig").fromESTarget(.es2017) });
        var scanner = try Scanner.init(a, result.code);
        var parser = Parser.init(a, &scanner);
        _ = try parser.parse();
        var analyzer = Analyzer.init(a, &parser.ast);
        try analyzer.analyze();
        var owners: usize = 0;
        for (parser.ast.nodes.items, 0..) |node, raw| {
            if (node.tag != .function_declaration) continue;
            const name = parser.ast.readExtraNode(node.data.extra, ast_mod.FunctionExtra.name);
            if (name.isNone() or !std.mem.eql(u8, parser.ast.getText(parser.ast.getNode(name).data.string_ref), "read")) continue;
            owners += 1;
            const params = parser.ast.readExtraNode(node.data.extra, ast_mod.FunctionExtra.params);
            const list = parser.ast.getNode(params).data.list;
            try std.testing.expectEqual(case.expressions, try ast_walk.parameterListHasExpressions(a, &parser.ast, list));
            const body_scope = analyzer.scope_owner_map.get(@intCast(raw)).?;
            const parameter_scope = analyzer.scope_owner_map.get(@backingInt(params));
            if (case.expressions) {
                try std.testing.expect(parameter_scope != null and parameter_scope.? != body_scope);
                try std.testing.expectEqual(parameter_scope.?, @as(u32, @intCast(analyzer.scopes.items[body_scope].parent.toIndex())));
            } else {
                try std.testing.expect(parameter_scope == null or parameter_scope.? == body_scope);
            }
            const runtime_source = try std.fmt.allocPrint(a, "{s};console.log(JSON.stringify([read.length,read.length==={d},[[],[{{a:1}}],[{{a:1}},3],[{{a:1}},3,4]].map(args=>{{try{{return read(...args)}}catch(e){{return e.name}}}})]));", .{ case.source, case.length });
            const runtime_actual = try std.fmt.allocPrint(a, "{s};console.log(JSON.stringify([read.length,read.length==={d},[[],[{{a:1}}],[{{a:1}},3],[{{a:1}},3,4]].map(args=>{{try{{return read(...args)}}catch(e){{return e.name}}}})]));", .{ result.code, case.length });
            const native = try std.process.run(a, std.testing.io, .{ .argv = &.{ "node", "-e", runtime_source } });
            const actual = try std.process.run(a, std.testing.io, .{ .argv = &.{ "node", "-e", runtime_actual } });
            try std.testing.expect(native.term == .exited and native.term.exited == 0);
            try std.testing.expect(actual.term == .exited and actual.term.exited == 0);
            try std.testing.expectEqualStrings(native.stdout, actual.stdout);
        }
        try std.testing.expectEqual(@as(usize, 1), owners);
    }
}

test "dynamic body wrapper retained prefix preserves exact formal storage before final walk" {
    const Scanner = @import("../../lexer/scanner.zig").Scanner;
    const Parser = @import("../../parser/parser.zig").Parser;
    const Analyzer = @import("../../semantic/analyzer.zig").SemanticAnalyzer;
    const Transformer = @import("../transformer.zig").Transformer;
    const scope_utils = @import("../output_scope_test_utils.zig");
    const Params = es2015_params.ES2015Params(Transformer);
    for ([_][]const u8{
        "function read([head=1],{a,...rest},value=2){eval('a');return [read.length,head,a,value]}",
        "function read({head=1},{a,...rest},value=2){eval('a');return [read.length,head,a,value]}",
        "function read([head],{a,...rest},value=2){eval('a');return [read.length,head,a,value]}",
        "function read({head},{a,...rest},value=2){eval('a');return [read.length,head,a,value]}",
        "function read([[head]],{a,...rest},value=2){eval('a');return [read.length,head,a,value]}",
        "function read([head],{other},{a,...rest},value=2){eval('a');return [read.length,head,other,a,value]}",
        "function read([head],{a,...rest},value=2){eval('arguments[2]=9');return [read.length,value,arguments[2]]}",
        "function read([head],{a=1,...rest},code){return [read.length,head,a,eval(code)]}",
        "function read([head],{a,...rest}){eval('arguments[0]=[9]');return [read.length,head,a,rest]}",
        "function read([head],{a,...rest},get=()=>head){eval('a');return [read.length,get(),rest]}",
        "function read([head],{a,...rest},get=()=>head){var head;eval('head=9');return [head,get(),rest]}",
        "function read([head],{a,...rest},get=()=>head){function head(){return 9}eval('head');return [head(),get(),rest]}",
    }) |source| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var scanner = try Scanner.init(a, source);
        var parser = Parser.init(a, &scanner);
        _ = try parser.parse();
        var analyzer = Analyzer.init(a, &parser.ast);
        analyzer.enable_stmt_info = true;
        analyzer.enable_exact_declaration_anchors = true;
        try analyzer.analyze();
        var t = try Transformer.init(a, &parser.ast, .{ .unsupported = @import("../compat.zig").fromESTarget(.es2017), .emit_runtime_helper_imports = false });
        try t.initSymbolIds(analyzer.symbol_ids.items);
        t.symbols = analyzer.symbols.items;
        t.references = analyzer.references.items;
        t.scopes = analyzer.scopes.items;
        t.scope_maps = analyzer.scope_maps.items;
        t.scope_owner_map = analyzer.scope_owner_map;
        t.unresolved_references = &analyzer.unresolved_references;
        t.semantic_edit_enabled = true;
        const root: NodeIndex = @fromBackingInt(@as(u32, @intCast(t.ast.nodes.items.len - 1)));
        const source_function = t.ast.readExtraNode(t.ast.getNode(root).data.list.start, 0);
        const body_scope = t.outputOwnedScope(source_function).?;
        try t.buildBlockRenameMap();
        const output = try t.visitNode(root);
        try t.registerGeneratedFunctionScopes(output, t.programScope());
        var actual_function: NodeIndex = .none;
        for (try ast_walk.collectReachableNodeIndicesFrom(a, t.ast, output)) |raw| {
            const idx: NodeIndex = @fromBackingInt(raw);
            if (t.ast.getNode(idx).tag == .function_declaration and t.outputOwnedScope(idx) == body_scope) actual_function = idx;
        }
        try std.testing.expect(!actual_function.isNone());
        const old_params = t.ast.readExtraNode(t.ast.getNode(actual_function).data.extra, ast_mod.FunctionExtra.params);
        const old_list = t.ast.getNode(old_params).data.list;
        const count = (try Params.firstObjectRestParamIndex(&t, old_list)).?;
        try std.testing.expect(count > 0);
        const old_has_expr = try ast_walk.parameterListHasExpressions(a, t.ast, old_list);
        const symbols = if (t.semantic_editor) |*editor| editor.symbols.items else t.symbols;
        const scopes = if (t.semantic_editor) |*editor| editor.scopes.items else t.scopes;
        const prefix_nodes = try a.alloc(NodeIndex, count);
        var bindings: std.ArrayList(es2015_params.RetainedPrefixBinding) = .empty;
        var prefix_has_expressions = false;
        for (prefix_nodes, 0..) |*node, offset| {
            node.* = t.ast.readExtraNode(old_list.start, @intCast(offset));
            prefix_has_expressions = prefix_has_expressions or try ast_walk.parameterHasExpressions(a, t.ast, node.*);
            var walker = try ast_walk.bindingIdentifiers(a, t.ast, node.*, .{});
            while (try walker.next()) |binding| {
                const id = t.getSymbolIdAt(binding).?;
                const symbol = symbols[id];
                try bindings.append(a, .{ .node = binding, .symbol = id, .scope = symbol.scope_id, .kind = symbol.kind, .flags = symbol.decl_flags });
            }
        }
        const proof: es2015_params.RetainedPrefixProof = .{
            .ast_owner = t.ast,
            .function_owner = actual_function,
            .body_scope = body_scope,
            .body_parent = scopes[body_scope.toIndex()].parent,
            .parameter_scope = t.outputOwnedScope(old_params),
            .nodes = prefix_nodes,
            .has_expressions = prefix_has_expressions,
            .bindings = try bindings.toOwnedSlice(a),
        };
        try lowerAllFunctionParams(&t, output);
        const params = t.ast.readExtraNode(t.ast.getNode(actual_function).data.extra, ast_mod.FunctionExtra.params);
        try std.testing.expect(try Params.validRetainedPrefix(&t, proof, params));
        try std.testing.expectEqual(old_has_expr, try ast_walk.parameterListHasExpressions(a, t.ast, t.ast.getNode(params).data.list));
        if (prefix_has_expressions) {
            // Independently inspect the actual physical default edge. A
            // retained native expression must not be used as an arity proxy.
            var original_cutoff = old_list.len;
            for (0..old_list.len) |j| {
                const formal = t.ast.getNode(t.ast.readExtraNode(old_list.start, @intCast(j)));
                if (formal.tag == .assignment_pattern or (formal.tag == .formal_parameter and !t.ast.readExtraNode(formal.data.extra, ast_mod.FormalParameterExtra.default).isNone())) {
                    original_cutoff = @intCast(j);
                    break;
                }
            }
            const actual_list = t.ast.getNode(params).data.list;
            try std.testing.expectEqual(old_list.len, actual_list.len);
            var actual_cutoff = actual_list.len;
            for (0..actual_list.len) |j| {
                const formal = t.ast.getNode(t.ast.readExtraNode(actual_list.start, @intCast(j)));
                if (formal.tag == .assignment_pattern or (formal.tag == .formal_parameter and !t.ast.readExtraNode(formal.data.extra, ast_mod.FormalParameterExtra.default).isNone())) {
                    actual_cutoff = @intCast(j);
                    break;
                }
            }
            try std.testing.expectEqual(original_cutoff, actual_cutoff);
            try std.testing.expect(original_cutoff >= count);
        }
        const live = try ast_walk.collectReachableNodeIndicesFrom(a, t.ast, output);
        var parents = try scope_utils.buildParentMap(a, t.ast, output);
        var owners: std.AutoHashMapUnmanaged(u32, u32) = .empty;
        for (live) |raw| if (t.outputOwnedScope(@fromBackingInt(raw))) |scope| {
            try owners.put(a, raw, @backingInt(scope));
        };
        for (proof.bindings) |binding| {
            try std.testing.expectEqual(@as(?@import("../../semantic/scope.zig").ScopeId, binding.scope), scope_utils.expectedScope(t.ast, output, &parents, &owners, @backingInt(binding.node)));
            var rows: usize = 0;
            for (t.semantic_editor.?.references.items) |row| {
                if (row.flags.declare and row.declaration_node_index == binding.node) {
                    try std.testing.expectEqual(binding.symbol, @as(u32, @intCast(@backingInt(row.symbol_id))));
                    try std.testing.expectEqual(binding.scope, row.scope_id);
                    rows += 1;
                }
            }
            try std.testing.expectEqual(@as(usize, 1), rows);
        }
        var wrong = proof;
        var foreign_ast = t.ast.*;
        wrong.ast_owner = &foreign_ast;
        try std.testing.expect(!try Params.validRetainedPrefix(&t, wrong, params));
        wrong = proof;
        wrong.function_owner = t.ast.functionBodyBlock(t.ast.getNode(actual_function)).?;
        try std.testing.expect(!try Params.validRetainedPrefix(&t, wrong, params));
        wrong = proof;
        wrong.body_parent = body_scope;
        try std.testing.expect(!try Params.validRetainedPrefix(&t, wrong, params));
        wrong = proof;
        wrong.parameter_scope = body_scope;
        try std.testing.expect(!try Params.validRetainedPrefix(&t, wrong, params));
        const alternate = @import("../native_constructor_timing.zig").simpleFormalBinding(&t, t.ast.readExtraNode(t.ast.getNode(params).data.list.start, @intCast(count))).?;
        const alternate_id = t.getSymbolIdAt(alternate).?;
        try std.testing.expect(alternate_id != proof.bindings[0].symbol);
        const wrong_bindings = try a.dupe(es2015_params.RetainedPrefixBinding, proof.bindings);
        wrong_bindings[0].symbol = alternate_id;
        wrong = proof;
        wrong.bindings = wrong_bindings;
        try std.testing.expect(!try Params.validRetainedPrefix(&t, wrong, params));
        wrong_bindings[0] = proof.bindings[0];
        wrong_bindings[0].scope = t.programScope();
        try std.testing.expect(!try Params.validRetainedPrefix(&t, wrong, params));
        wrong_bindings[0] = proof.bindings[0];
        wrong_bindings[0].kind = .variable_var;
        try std.testing.expect(!try Params.validRetainedPrefix(&t, wrong, params));
        wrong_bindings[0] = proof.bindings[0];
        wrong_bindings[0].flags.is_const = !wrong_bindings[0].flags.is_const;
        try std.testing.expect(!try Params.validRetainedPrefix(&t, wrong, params));
        const binding_id = proof.bindings[0].symbol;
        const saved_scope = t.semantic_editor.?.symbols.items[binding_id].scope_id;
        t.semantic_editor.?.symbols.items[binding_id].scope_id = t.programScope();
        try std.testing.expect(!try Params.validRetainedPrefix(&t, proof, params));
        t.semantic_editor.?.symbols.items[binding_id].scope_id = saved_scope;
        const saved_parent = t.semantic_editor.?.scopes.items[body_scope.toIndex()].parent;
        t.semantic_editor.?.scopes.items[body_scope.toIndex()].parent = body_scope;
        try std.testing.expect(!try Params.validRetainedPrefix(&t, proof, params));
        t.semantic_editor.?.scopes.items[body_scope.toIndex()].parent = saved_parent;
        const function_extra = t.ast.getNode(actual_function).data.extra;
        const saved_formal = t.ast.readExtraNode(function_extra, ast_mod.FunctionExtra.params);
        t.ast.extra_data.items[function_extra + ast_mod.FunctionExtra.params] = @backingInt(old_params);
        try std.testing.expect(!try Params.validRetainedPrefix(&t, proof, params));
        t.ast.extra_data.items[function_extra + ast_mod.FunctionExtra.params] = @backingInt(saved_formal);
        const wrong_nodes = try a.dupe(NodeIndex, proof.nodes);
        wrong_nodes[0] = alternate;
        wrong = proof;
        wrong.nodes = wrong_nodes;
        try std.testing.expect(!try Params.validRetainedPrefix(&t, wrong, params));
        try std.testing.expect(try Params.validRetainedPrefix(&t, proof, params));
    }
}

test "dynamic body wrapper implicit arguments copy is born in actual scopes" {
    const Scanner = @import("../../lexer/scanner.zig").Scanner;
    const Parser = @import("../../parser/parser.zig").Parser;
    const Analyzer = @import("../../semantic/analyzer.zig").SemanticAnalyzer;
    const Transformer = @import("../transformer.zig").Transformer;
    const scope_utils = @import("../output_scope_test_utils.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source = "function read({a,...rest},value=2){'custom directive';var arguments;eval('arguments');return [value,typeof arguments]}";
    var scanner = try Scanner.init(a, source);
    var parser = Parser.init(a, &scanner);
    _ = try parser.parse();
    var analyzer = Analyzer.init(a, &parser.ast);
    analyzer.enable_stmt_info = true;
    analyzer.enable_exact_declaration_anchors = true;
    try analyzer.analyze();
    var variable: ?u32 = null;
    var parameter: ?u32 = null;
    for (analyzer.symbols.items, 0..) |_, raw| {
        const role = (try @import("../../semantic/parameter_body_var.zig").forSymbol(analyzer.symbols.items, @fromBackingInt(@as(u32, @intCast(raw))))) orelse continue;
        if (analyzer.symbols.items[@backingInt(role.parameter)].synthetic_kind != .implicit_arguments) continue;
        try std.testing.expect(variable == null);
        variable = @intCast(raw);
        parameter = @intCast(@backingInt(role.parameter));
    }
    const v = variable.?;
    const p = parameter.?;
    const original_scope = analyzer.symbols.items[v].scope_id;
    var t = try Transformer.init(a, &parser.ast, .{ .unsupported = @import("../compat.zig").fromESTarget(.es2017), .emit_runtime_helper_imports = false });
    try t.initSymbolIds(analyzer.symbol_ids.items);
    t.symbols = analyzer.symbols.items;
    t.references = analyzer.references.items;
    t.scopes = analyzer.scopes.items;
    t.scope_maps = analyzer.scope_maps.items;
    t.scope_owner_map = analyzer.scope_owner_map;
    t.unresolved_references = &analyzer.unresolved_references;
    t.semantic_edit_enabled = true;
    const root: NodeIndex = @fromBackingInt(@as(u32, @intCast(t.ast.nodes.items.len - 1)));
    try t.buildBlockRenameMap();
    const output = try t.visitNode(root);
    try t.registerGeneratedFunctionScopes(output, t.programScope());
    try lowerAllFunctionParams(&t, output);
    const editor = &t.semantic_editor.?;
    const wrapper_scope = editor.symbols.items[v].scope_id;
    try std.testing.expect(wrapper_scope != original_scope);
    try std.testing.expectEqual(original_scope, editor.scopes.items[wrapper_scope.toIndex()].parent);
    const role = (try @import("../../semantic/parameter_body_var.zig").forSymbol(editor.symbols.items, @fromBackingInt(v))).?;
    try std.testing.expectEqual(@as(u32, p), @as(u32, @intCast(@backingInt(role.parameter))));
    try std.testing.expect(role.state == .lowered);
    const live = try ast_walk.collectReachableNodeIndicesFrom(a, t.ast, output);
    var parents = try scope_utils.buildParentMap(a, t.ast, output);
    var owners: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    for (live) |raw| if (t.outputOwnedScope(@fromBackingInt(raw))) |scope| {
        try owners.put(a, raw, @backingInt(scope));
    };
    var actual_wrappers: usize = 0;
    for (live) |raw| {
        const node = t.ast.nodes.items[raw];
        if (node.tag != .arrow_function_expression or t.outputOwnedScope(@fromBackingInt(raw)) != wrapper_scope) continue;
        actual_wrappers += 1;
        const arrow: NodeIndex = @fromBackingInt(raw);
        const body = t.ast.readExtraNode(node.data.extra, ast_mod.ArrowExtra.body);
        try std.testing.expect(validImplicitArgumentsWrapper(&t, original_scope, wrapper_scope, arrow, body));
        try std.testing.expect(!validImplicitArgumentsWrapper(&t, wrapper_scope, original_scope, arrow, body));
        try std.testing.expect(!validImplicitArgumentsWrapper(&t, original_scope, editor.symbols.items[p].scope_id, arrow, body));
        try std.testing.expect(!validImplicitArgumentsWrapper(&t, original_scope, wrapper_scope, body, body));
        const saved_parent = editor.scopes.items[wrapper_scope.toIndex()].parent;
        editor.scopes.items[wrapper_scope.toIndex()].parent = t.programScope();
        try std.testing.expect(!validImplicitArgumentsWrapper(&t, original_scope, wrapper_scope, arrow, body));
        editor.scopes.items[wrapper_scope.toIndex()].parent = saved_parent;
        const params = t.ast.readExtraNode(node.data.extra, ast_mod.ArrowExtra.params);
        const list = t.ast.getNode(params).data.list;
        try std.testing.expectEqual(@as(u32, 1), list.len);
        const binding = t.ast.readExtraNode(list.start, 0);
        const carrier_id = t.getSymbolIdAt(binding).?;
        try std.testing.expectEqual(v, carrier_id);
        try std.testing.expect(editor.symbols.items[v].kind == .variable_var);
        try std.testing.expectEqual(wrapper_scope, editor.symbols.items[carrier_id].scope_id);
        var body_reads: usize = 0;
        var carrier_declarations: usize = 0;
        var original_declarations: usize = 0;
        var parameter_reads: usize = 0;
        for (editor.references.items) |row| {
            const id = @backingInt(row.symbol_id);
            if (id == v and row.flags.declare) {
                try std.testing.expectEqual(wrapper_scope, row.scope_id);
                if (row.declaration_node_index == binding) carrier_declarations += 1 else original_declarations += 1;
            }
            if (row.node_index.isNone()) continue;
            if (id == v and row.flags.read) {
                try std.testing.expectEqual(wrapper_scope, row.scope_id);
                body_reads += 1;
            }
            if (id == p and row.flags.read) {
                try std.testing.expectEqual(original_scope, row.scope_id);
                parameter_reads += 1;
            }
            if ((id == v and row.flags.read) or (id == p and row.flags.read))
                try std.testing.expectEqual(@as(?@import("../../semantic/scope.zig").ScopeId, row.scope_id), scope_utils.expectedScope(t.ast, output, &parents, &owners, @backingInt(row.node_index)));
        }
        try std.testing.expectEqual(@as(usize, 1), body_reads);
        try std.testing.expectEqual(@as(usize, 1), carrier_declarations);
        try std.testing.expectEqual(@as(usize, 1), original_declarations);
        try std.testing.expectEqual(@as(usize, 1), parameter_reads);
        const stmts = t.ast.getNode(body).data.list;
        const directive = t.ast.getNode(t.ast.readExtraNode(stmts.start, 0));
        try std.testing.expect(directive.tag == .directive);
    }
    try std.testing.expectEqual(@as(usize, 1), actual_wrappers);
}

test "dynamic body wrapper lexical parameter shadow is exact before final walk" {
    const Scanner = @import("../../lexer/scanner.zig").Scanner;
    const Parser = @import("../../parser/parser.zig").Parser;
    const Analyzer = @import("../../semantic/analyzer.zig").SemanticAnalyzer;
    const Transformer = @import("../transformer.zig").Transformer;
    const scope_utils = @import("../output_scope_test_utils.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source = "function read({a=()=>rest,...rest},code){var arguments;var rest;return [a(),eval(code),arguments]}";
    var scanner = try Scanner.init(a, source);
    var parser = Parser.init(a, &scanner);
    _ = try parser.parse();
    var analyzer = Analyzer.init(a, &parser.ast);
    analyzer.enable_stmt_info = true;
    analyzer.enable_exact_declaration_anchors = true;
    try analyzer.analyze();
    var source_rest: ?u32 = null;
    for (analyzer.symbols.items, 0..) |symbol, raw| {
        if (symbol.kind == .parameter and std.mem.eql(u8, symbol.nameText(parser.ast.source), "rest")) source_rest = @intCast(raw);
    }
    var t = try Transformer.init(a, &parser.ast, .{ .unsupported = @import("../compat.zig").fromESTarget(.es2017), .emit_runtime_helper_imports = false });
    try t.initSymbolIds(analyzer.symbol_ids.items);
    t.symbols = analyzer.symbols.items;
    t.references = analyzer.references.items;
    t.scopes = analyzer.scopes.items;
    t.scope_maps = analyzer.scope_maps.items;
    t.scope_owner_map = analyzer.scope_owner_map;
    t.unresolved_references = &analyzer.unresolved_references;
    t.semantic_edit_enabled = true;
    const root: NodeIndex = @fromBackingInt(@as(u32, @intCast(t.ast.nodes.items.len - 1)));
    try t.buildBlockRenameMap();
    const output = try t.visitNode(root);
    try t.registerGeneratedFunctionScopes(output, t.programScope());
    try lowerAllFunctionParams(&t, output);
    const editor = &t.semantic_editor.?;
    const live = try ast_walk.collectReachableNodeIndicesFrom(a, t.ast, output);
    var parents = try scope_utils.buildParentMap(a, t.ast, output);
    var owners: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    for (live) |raw| if (t.outputOwnedScope(@fromBackingInt(raw))) |scope| {
        try owners.put(a, raw, @backingInt(scope));
    };
    const source_id = source_rest.?;
    const lexical_scope = editor.symbols.items[source_id].scope_id;
    try std.testing.expect(editor.symbols.items[source_id].kind == .variable_let);
    var source_declaration: NodeIndex = .none;
    var declarations: usize = 0;
    for (live) |raw| {
        const node = t.ast.nodes.items[raw];
        if (node.tag != .variable_declaration or t.ast.variableDeclarationKind(node) != .let) continue;
        const start = t.ast.readExtra(node.data.extra, 1);
        if (t.ast.readExtra(node.data.extra, 2) != 1) continue;
        const decl = t.ast.getNode(t.ast.readExtraNode(start, 0));
        const binding = t.ast.readExtraNode(decl.data.extra, 0);
        if (t.getSymbolIdAt(binding) != source_id) continue;
        declarations += 1;
        source_declaration = @fromBackingInt(raw);
        try std.testing.expect(!t.ast.readExtraNode(decl.data.extra, 2).isNone());
        try std.testing.expectEqual(@as(?@import("../../semantic/scope.zig").ScopeId, lexical_scope), scope_utils.expectedScope(t.ast, output, &parents, &owners, @backingInt(binding)));
    }
    try std.testing.expectEqual(@as(usize, 1), declarations);
    var plan: es2015_params.NativeArgumentShadow = .{
        .ast_owner = t.ast,
        .function_owner = .none,
        .body_scope = editor.scopes.items[lexical_scope.toIndex()].parent,
        .scope = lexical_scope,
        .source_symbol = source_id,
        .source_declaration = source_declaration,
    };
    for (live) |raw| {
        const idx: NodeIndex = @fromBackingInt(raw);
        const node = t.ast.getNode(idx);
        if (node.tag == .block_statement and t.outputOwnedScope(idx) == lexical_scope) plan.block = idx;
        if (node.tag != .function_declaration or t.outputOwnedScope(idx) != plan.body_scope) continue;
        plan.function_owner = idx;
        const params = t.ast.readExtraNode(node.data.extra, ast_mod.FunctionExtra.params);
        const list = t.ast.getNode(params).data.list;
        const last = t.ast.getNode(t.ast.readExtraNode(list.start, list.len - 1));
        try std.testing.expect(last.tag == .assignment_pattern);
        plan.native_symbol = t.getSymbolIdAt(last.data.binary.left);
    }
    try std.testing.expect(validNativeArgumentShadow(&t, plan));
    var wrong = plan;
    wrong.source_symbol = plan.native_symbol.?;
    try std.testing.expect(!validNativeArgumentShadow(&t, wrong));
    wrong = plan;
    wrong.native_symbol = plan.source_symbol;
    try std.testing.expect(!validNativeArgumentShadow(&t, wrong));
    wrong = plan;
    wrong.scope = plan.body_scope;
    try std.testing.expect(!validNativeArgumentShadow(&t, wrong));
    wrong = plan;
    wrong.function_owner = plan.block;
    try std.testing.expect(!validNativeArgumentShadow(&t, wrong));
    wrong = plan;
    wrong.source_declaration = plan.block;
    try std.testing.expect(!validNativeArgumentShadow(&t, wrong));
    const saved_flags = editor.scopes.items[lexical_scope.toIndex()].subtree_has_direct_eval;
    try std.testing.expect(saved_flags);
    editor.scopes.items[lexical_scope.toIndex()].subtree_has_direct_eval = false;
    try std.testing.expect(!validNativeArgumentShadow(&t, plan));
    editor.scopes.items[lexical_scope.toIndex()].subtree_has_direct_eval = saved_flags;
    const saved_parent = editor.scopes.items[lexical_scope.toIndex()].parent;
    editor.scopes.items[lexical_scope.toIndex()].parent = t.programScope();
    try std.testing.expect(!validNativeArgumentShadow(&t, plan));
    editor.scopes.items[lexical_scope.toIndex()].parent = saved_parent;
    try std.testing.expect(validNativeArgumentShadow(&t, plan));

    var reads: usize = 0;
    for (editor.references.items) |row| {
        if (@backingInt(row.symbol_id) != source_id or !row.flags.read or row.node_index.isNone()) continue;
        var reachable = false;
        for (live) |raw| if (raw == @backingInt(row.node_index)) {
            reachable = true;
            break;
        };
        if (!reachable) continue;
        reads += 1;
        try std.testing.expectEqual(@as(?@import("../../semantic/scope.zig").ScopeId, row.scope_id), scope_utils.expectedScope(t.ast, output, &parents, &owners, @backingInt(row.node_index)));
    }
    try std.testing.expect(reads > 0);
}

test "dynamic body wrapper shared function cells retain source identities before final walk" {
    const Scanner = @import("../../lexer/scanner.zig").Scanner;
    const Parser = @import("../../parser/parser.zig").Parser;
    const Analyzer = @import("../../semantic/analyzer.zig").SemanticAnalyzer;
    const Transformer = @import("../transformer.zig").Transformer;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source = "function read({a,...rest}){function a(){return a}function other(){return 8}let body=1;eval('a');return [a,other]}";
    var scanner = try Scanner.init(a, source);
    var parser = Parser.init(a, &scanner);
    _ = try parser.parse();
    var analyzer = Analyzer.init(a, &parser.ast);
    analyzer.enable_stmt_info = true;
    analyzer.enable_exact_declaration_anchors = true;
    try analyzer.analyze();
    var source_owner: NodeIndex = .none;
    for (parser.ast.nodes.items, 0..) |node, raw| {
        if (node.tag != .function_declaration) continue;
        const binding = parser.ast.readExtraNode(node.data.extra, ast_mod.FunctionExtra.name);
        if (std.mem.eql(u8, parser.ast.getText(parser.ast.getNode(binding).data.string_ref), "read")) source_owner = @fromBackingInt(@as(u32, @intCast(raw)));
    }
    const original = parser.ast.getNode(source_owner);
    const body_scope = analyzer.scope_owner_map.get(@backingInt(source_owner)).?;
    const params = parser.ast.readExtraNode(original.data.extra, ast_mod.FunctionExtra.params);
    try std.testing.expect(analyzer.scope_owner_map.get(@backingInt(params)) == null);
    var parameters = try ast_walk.bindingIdentifiers(a, &parser.ast, params, .{ .cover_grammar_assignment = true });
    const parameter_binding = (try parameters.next()).?;
    const source_rest_binding = (try parameters.next()).?;
    const source_rest_id = analyzer.symbol_ids.items[@backingInt(source_rest_binding)].?;
    const id = analyzer.symbol_ids.items[@backingInt(parameter_binding)].?;
    try std.testing.expect(analyzer.symbols.items[id].kind == .parameter);
    try std.testing.expectEqual(body_scope, @as(u32, @intCast(analyzer.symbols.items[id].scope_id.toIndex())));
    const original_body = parser.ast.readExtraNode(original.data.extra, ast_mod.FunctionExtra.body);
    const original_list = parser.ast.getNode(original_body).data.list;
    const declaration = parser.ast.readExtraNode(original_list.start, 0);
    const function_binding = parser.ast.readExtraNode(parser.ast.getNode(declaration).data.extra, ast_mod.FunctionExtra.name);
    try std.testing.expectEqual(id, analyzer.symbol_ids.items[@backingInt(function_binding)].?);
    const function_scope = analyzer.scope_owner_map.get(@backingInt(declaration)).?;
    const other = parser.ast.readExtraNode(original_list.start, 1);
    const other_scope = analyzer.scope_owner_map.get(@backingInt(other)).?;
    var t = try Transformer.init(a, &parser.ast, .{ .unsupported = @import("../compat.zig").fromESTarget(.es2017), .emit_runtime_helper_imports = false });
    try t.initSymbolIds(analyzer.symbol_ids.items);
    t.symbols = analyzer.symbols.items;
    t.references = analyzer.references.items;
    t.scopes = analyzer.scopes.items;
    t.scope_maps = analyzer.scope_maps.items;
    t.scope_owner_map = analyzer.scope_owner_map;
    t.unresolved_references = &analyzer.unresolved_references;
    t.semantic_edit_enabled = true;
    const root: NodeIndex = @fromBackingInt(@as(u32, @intCast(t.ast.nodes.items.len - 1)));
    try t.buildBlockRenameMap();
    const output = try t.visitNode(root);
    try t.registerGeneratedFunctionScopes(output, t.programScope());
    try lowerAllFunctionParams(&t, output);
    const editor = &t.semantic_editor.?;
    try std.testing.expect(editor.symbols.items[id].kind == .parameter);
    try std.testing.expectEqual(body_scope, @as(u32, @intCast(editor.symbols.items[id].scope_id.toIndex())));
    try std.testing.expectEqual(id, t.getSymbolIdAt(parameter_binding).?);
    const live = try ast_walk.collectReachableNodeIndicesFrom(a, t.ast, output);
    var values: usize = 0;
    var untouched: usize = 0;
    var writes: usize = 0;
    for (live) |raw| {
        const node = t.ast.nodes.items[raw];
        if (t.outputOwnedScope(@fromBackingInt(raw))) |scope| {
            if (scope.toIndex() == body_scope and node.tag == .function_declaration) {
                const actual_params = t.ast.readExtraNode(node.data.extra, ast_mod.FunctionExtra.params);
                const actual_list = t.ast.getNode(actual_params).data.list;
                const tail = t.ast.getNode(t.ast.readExtraNode(actual_list.start, actual_list.len - 1));
                try std.testing.expect(tail.tag == .rest_element);
                try std.testing.expectEqual(source_rest_id, t.getSymbolIdAt(tail.data.unary.operand).?);
                try std.testing.expect(editor.symbols.items[source_rest_id].kind == .parameter);
                try std.testing.expectEqual(body_scope, @as(u32, @intCast(editor.symbols.items[source_rest_id].scope_id.toIndex())));
                try std.testing.expect(t.outputOwnedScope(actual_params) == null);
            }
            if (scope.toIndex() == function_scope) {
                try std.testing.expect(node.tag == .function_expression);
                try std.testing.expect(t.ast.readExtraNode(node.data.extra, ast_mod.FunctionExtra.name).isNone());
                try std.testing.expectEqual(body_scope, @as(u32, @intCast(editor.scopes.items[function_scope].parent.toIndex())));
                values += 1;
            }
            if (scope.toIndex() == other_scope) {
                try std.testing.expect(node.tag == .function_declaration);
                untouched += 1;
            }
        }
        if (node.tag == .assignment_expression) {
            const target = node.data.binary.left;
            if (t.getSymbolIdAt(target) != @as(?u32, id)) continue;
            var rows: usize = 0;
            for (editor.references.items) |row| {
                if (row.node_index != target) continue;
                try std.testing.expect(row.flags.write and !row.flags.read);
                try std.testing.expectEqual(id, @as(u32, @intCast(@backingInt(row.symbol_id))));
                try std.testing.expectEqual(body_scope, @as(u32, @intCast(row.scope_id.toIndex())));
                rows += 1;
            }
            try std.testing.expectEqual(@as(usize, 1), rows);
            writes += 1;
        }
    }
    var live_anchors: usize = 0;
    for (editor.references.items) |row| {
        try std.testing.expect(!row.flags.declare or row.declaration_node_index != function_binding);
        if (@backingInt(row.symbol_id) != id or !row.flags.declare or row.declaration_node_index.isNone()) continue;
        for (live) |raw| if (@backingInt(row.declaration_node_index) == raw) {
            live_anchors += 1;
        };
    }
    try std.testing.expectEqual(@as(usize, 1), live_anchors);
    try std.testing.expectEqual(@as(usize, 1), values);
    try std.testing.expectEqual(@as(usize, 1), untouched);
    try std.testing.expectEqual(@as(usize, 1), writes);
}

test "dynamic body wrapper source var redeclaration keeps the function declaration anchor" {
    try checkSourceVarFunctionAnchors(false);
    try checkSourceVarFunctionAnchors(true);
}

fn checkSourceVarFunctionAnchors(interned_names: bool) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source = "function read({a,...rest},value=2){var a;function a(){return 9}eval('a');return [a(),value]}";
    var scanner = try @import("../../lexer/scanner.zig").Scanner.init(a, source);
    var parser = @import("../../parser/parser.zig").Parser.init(a, &scanner);
    const root = try parser.parse();
    if (interned_names) {
        const shared = try parser.ast.addString("a");
        for (parser.ast.nodes.items) |*node| {
            if (node.tag != .binding_identifier and node.tag != .identifier_reference) continue;
            if (!std.mem.eql(u8, parser.ast.getText(node.data.string_ref), "a")) continue;
            node.span = shared;
            node.data.string_ref = shared;
        }
    }
    var analyzer = @import("../../semantic/analyzer.zig").SemanticAnalyzer.init(a, &parser.ast);
    analyzer.enable_stmt_info = true;
    analyzer.enable_exact_declaration_anchors = true;
    try analyzer.analyze();
    const function = parser.ast.getNode(parser.ast.readExtraNode(parser.ast.getNode(root).data.list.start, 0));
    const body = parser.ast.getNode(parser.ast.readExtraNode(function.data.extra, ast_mod.FunctionExtra.body)).data.list;
    const variable = parser.ast.getNode(parser.ast.readExtraNode(body.start, 0));
    const declarator = parser.ast.getNode(parser.ast.readExtraNode(parser.ast.readExtra(variable.data.extra, 1), 0));
    const var_binding = parser.ast.readExtraNode(declarator.data.extra, 0);
    const declaration = parser.ast.getNode(parser.ast.readExtraNode(body.start, 1));
    const fn_binding = parser.ast.readExtraNode(declaration.data.extra, ast_mod.FunctionExtra.name);
    const id = analyzer.symbol_ids.items[@backingInt(fn_binding)].?;
    try std.testing.expectEqual(id, analyzer.symbol_ids.items[@backingInt(var_binding)].?);
    var variable_anchors: usize = 0;
    var function_anchors: usize = 0;
    for (analyzer.references.items) |row| {
        if (@backingInt(row.symbol_id) != id or !row.flags.declare) continue;
        if (row.declaration_node_index == var_binding) {
            try std.testing.expectEqual(@as(u32, 0), row.scope_stmt_idx);
            variable_anchors += 1;
        }
        if (row.declaration_node_index == fn_binding) {
            try std.testing.expectEqual(@as(u32, 1), row.scope_stmt_idx);
            function_anchors += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 1), variable_anchors);
    try std.testing.expectEqual(@as(usize, 1), function_anchors);
}

test "dynamic body wrapper retained expression-free prefix native controls" {
    const Case = struct { source: []const u8, call: []const u8 };
    for ([_]Case{
        .{ .source = "function read([head],{a,...rest},value=2){eval('a');return [read.length,head,a,value]}", .call = "read([1],{a:2,b:3})" },
        .{ .source = "function read({head},{a,...rest},value=2){eval('a');return [read.length,head,a,value]}", .call = "read({head:1},{a:2,b:3})" },
        .{ .source = "function read([[head]],{a,...rest},value=2){eval('a');return [read.length,head,a,value]}", .call = "read([[1]],{a:2,b:3})" },
        .{ .source = "function read([head],{other},{a,...rest},value=2){eval('a');return [read.length,head,other,a,value]}", .call = "read([1],{other:4},{a:2,b:3})" },
        .{ .source = "function read([head],{a,...rest},value=2){eval('arguments[2]=9');return [read.length,value,arguments[2]]}", .call = "read([1],{a:2,b:3})" },
        .{ .source = "function read([head],{a=1,...rest},code){return [read.length,head,a,eval(code)]}", .call = "read([1],{b:3},String.fromCharCode(114,101,115,116),9)" },
        .{ .source = "function read([head],{a,...rest}){eval('arguments[0]=[9]');return [read.length,head,a,rest]}", .call = "read([1],{a:2,b:3})" },
        .{ .source = "function read([head],{a,...rest},get=()=>head){eval('a');return [read.length,get(),rest]}", .call = "read([1],{a:2,b:3})" },
        .{ .source = "function read([head],{a,...rest},get=()=>head){var head;eval('head=9');return [head,get(),rest]}", .call = "read([1],{a:2,b:3})" },
        .{ .source = "function read([head],{a,...rest},get=()=>head){function head(){return 9}eval('head');return [head(),get(),rest]}", .call = "read([1],{a:2,b:3})" },
    }, 0..) |case, index| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const source = try std.fmt.allocPrint(a, "{s};console.log(JSON.stringify({s}));", .{ case.source, case.call });
        const native = try std.process.run(a, std.testing.io, .{ .argv = &.{ "node", "-e", source } });
        try std.testing.expect(native.term == .exited and native.term.exited == 0);
        for ([_]@import("../compat.zig").ESTarget{ .es2015, .es2017 }) |target| for ([_]bool{ false, true }) |minify| {
            errdefer std.debug.print("dynamic wrapper runtime source={d} target={s} min={any}\n", .{ index, @tagName(target), minify });
            const result = try @import("../../transpile.zig").transpile(a, source, "input.cjs", .{
                .unsupported = @import("../compat.zig").fromESTarget(target),
                .minify_identifiers = minify,
                .minify_syntax = minify,
                .minify_whitespace = minify,
            });
            const actual = try std.process.run(a, std.testing.io, .{ .argv = &.{ "node", "-e", result.code } });
            if (!(actual.term == .exited and actual.term.exited == 0)) std.debug.print("{s}\n{s}\n", .{ result.code, actual.stderr });
            try std.testing.expect(actual.term == .exited and actual.term.exited == 0);
            try std.testing.expectEqualStrings(native.stdout, actual.stdout);
        };
    }
}

test "dynamic body wrapper retained expression prefix arity-only native controls" {
    const Case = struct { source: []const u8, call: []const u8 };
    for ([_]Case{
        .{ .source = "function read([head=1],{a,...rest},value=2){eval('a');return [read.length,head,a,value]}", .call = "read([],{a:2,b:3})" },
        .{ .source = "function read([head=1],{a,...rest},value=2){eval('a');return [read.length,head,a,value,arguments.length]}", .call = "read([4],{a:2,b:3},9,8)" },
        .{ .source = "function read({head=1},{a,...rest},value=2){eval('a');return [read.length,head,a,value]}", .call = "read({},{a:2,b:3})" },
        .{ .source = "function read([head=1],{a,...rest},value=2){eval('arguments[2]=9');return [read.length,value,arguments[2]]}", .call = "read([],{a:2,b:3})" },
    }, 0..) |case, index| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const source = try std.fmt.allocPrint(a, "{s};console.log(JSON.stringify({s}));", .{ case.source, case.call });
        const native = try std.process.run(a, std.testing.io, .{ .argv = &.{ "node", "-e", source } });
        try std.testing.expect(native.term == .exited and native.term.exited == 0);
        for ([_]@import("../compat.zig").ESTarget{ .es2015, .es2017 }) |target| for ([_]bool{ false, true }) |minify| {
            errdefer std.debug.print("dynamic wrapper runtime source={d} target={s} min={any}\n", .{ index, @tagName(target), minify });
            const result = try @import("../../transpile.zig").transpile(a, source, "input.cjs", .{
                .unsupported = @import("../compat.zig").fromESTarget(target),
                .minify_identifiers = minify,
                .minify_syntax = minify,
                .minify_whitespace = minify,
            });
            const actual = try std.process.run(a, std.testing.io, .{ .argv = &.{ "node", "-e", result.code } });
            if (!(actual.term == .exited and actual.term.exited == 0)) std.debug.print("{s}\n{s}\n", .{ result.code, actual.stderr });
            try std.testing.expect(actual.term == .exited and actual.term.exited == 0);
            try std.testing.expectEqualStrings(native.stdout, actual.stdout);
        };
    }
}

test "native arrow formal birth keeps actual expression parameter storage before output walk" {
    const Scanner = @import("../../lexer/scanner.zig").Scanner;
    const Parser = @import("../../parser/parser.zig").Parser;
    const Analyzer = @import("../../semantic/analyzer.zig").SemanticAnalyzer;
    const Transformer = @import("../transformer.zig").Transformer;
    const ScopeId = @import("../../semantic/scope.zig").ScopeId;
    const scope_utils = @import("../output_scope_test_utils.zig");
    const Params = es2015_params.ES2015Params(Transformer);
    var owner_gaps: usize = 0;
    var storage_gaps: usize = 0;
    var declaration_scope_gaps: usize = 0;
    var structural_scope_gaps: usize = 0;
    var cases_checked: usize = 0;
    var raw_bindings_checked: usize = 0;
    for ([_][]const u8{
        "const read=([head=1],{a,...rest})=>{eval('a');return[head,a,read.length]}",
        "const read=({head=1},{a,...rest})=>{eval('a');return[head,a]}",
        "const read=([[head=1]],{a,...rest})=>{eval('a');return[head,a]}",
        "const read=([head=1],{other},{a,...rest})=>{eval('a');return[head,other,a]}",
        "const read=({[Number(2)]:head},{a,...rest})=>{eval('a');return[head,a]}",
        "const read=(get=()=>2,{a,...rest})=>{eval('a');return[get(),a]}",
        "const read=(get=function local(marker=2){return marker},{a,...rest})=>{eval('a');return[get(),a]}",
        "const read=(head=1,{a,...rest})=>{eval('a');return[head,a]}",
        "const read=([{head=1}],{a,...rest})=>{eval('a');return[head,a]}",
        "const read=([head=1],{a,...rest},{b,...tail})=>{eval('a');return[head,a,b,rest,tail]}",
    }, 0..) |source, case_index| {
        errdefer std.debug.print("native arrow formal birth source={d}: {s}\n", .{ case_index, source });
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var scanner = try Scanner.init(a, source);
        var parser = Parser.init(a, &scanner);
        parser.configureFromExtension(".cjs");
        const root = try parser.parse();
        try std.testing.expectEqual(@as(usize, 0), parser.errors.items.len);
        var analyzer = Analyzer.init(a, &parser.ast);
        analyzer.is_strict_mode = parser.is_strict_mode;
        analyzer.enable_stmt_info = true;
        analyzer.enable_exact_declaration_anchors = true;
        try analyzer.analyze();
        const declaration = parser.ast.getNode(parser.ast.readExtraNode(parser.ast.getNode(root).data.list.start, 0));
        const declarator = parser.ast.getNode(parser.ast.readExtraNode(parser.ast.readExtra(declaration.data.extra, 1), 0));
        const source_arrow = parser.ast.readExtraNode(declarator.data.extra, 2);
        try std.testing.expectEqual(ast_mod.Node.Tag.arrow_function_expression, parser.ast.getNode(source_arrow).tag);
        const source_body_scope: ScopeId = @fromBackingInt(analyzer.scope_owner_map.get(@backingInt(source_arrow)).?);
        var t = try Transformer.init(a, &parser.ast, .{ .unsupported = @import("../compat.zig").fromESTarget(.es2017), .emit_runtime_helper_imports = false });
        try t.initSymbolIds(analyzer.symbol_ids.items);
        t.symbols = analyzer.symbols.items;
        t.references = analyzer.references.items;
        t.scopes = analyzer.scopes.items;
        t.scope_maps = analyzer.scope_maps.items;
        t.scope_owner_map = analyzer.scope_owner_map;
        t.unresolved_references = &analyzer.unresolved_references;
        t.semantic_edit_enabled = true;
        try t.buildBlockRenameMap();
        const output = try t.visitNode(root);
        try t.registerGeneratedFunctionScopes(output, t.programScope());
        var actual_arrow: NodeIndex = .none;
        for (try ast_walk.collectReachableNodeIndicesFrom(a, t.ast, output)) |raw| {
            const idx: NodeIndex = @fromBackingInt(raw);
            if (t.ast.getNode(idx).tag != .arrow_function_expression or t.outputOwnedScope(idx) != source_body_scope) continue;
            try std.testing.expect(actual_arrow.isNone());
            actual_arrow = idx;
        }
        try std.testing.expect(!actual_arrow.isNone());
        const old_params = t.ast.readExtraNode(t.ast.getNode(actual_arrow).data.extra, ast_mod.ArrowExtra.params);
        const old_list = t.ast.getNode(old_params).data.list;
        const parameter_scope = t.outputOwnedScope(old_params).?;
        try std.testing.expect(parameter_scope != source_body_scope);
        const scopes = if (t.semantic_editor) |*editor| editor.scopes.items else t.scopes;
        try std.testing.expectEqual(parameter_scope, scopes[source_body_scope.toIndex()].parent);
        const prefix_count = (try Params.firstObjectRestParamIndex(&t, old_list)).?;
        try std.testing.expect(prefix_count > 0);
        const prefix = try a.alloc(NodeIndex, prefix_count);
        var original_bindings: std.ArrayList(es2015_params.RetainedPrefixBinding) = .empty;
        var prefix_has_expressions = false;
        for (prefix, 0..) |*item, index| {
            item.* = t.ast.readExtraNode(old_list.start, @intCast(index));
            prefix_has_expressions = prefix_has_expressions or try ast_walk.parameterHasExpressions(a, t.ast, item.*);
            var bindings = try ast_walk.bindingIdentifiers(a, t.ast, item.*, .{ .cover_grammar_assignment = true });
            while (try bindings.next()) |binding| {
                const sid = t.getSymbolIdAt(binding).?;
                const symbols = if (t.semantic_editor) |*editor| editor.symbols.items else t.symbols;
                const symbol = symbols[sid];
                try std.testing.expectEqual(parameter_scope, symbol.scope_id);
                try original_bindings.append(a, .{ .node = binding, .symbol = sid, .scope = symbol.scope_id, .kind = symbol.kind, .flags = symbol.decl_flags });
            }
        }
        try std.testing.expect(prefix_has_expressions);
        try lowerAllFunctionParams(&t, output);
        const actual_params = t.ast.readExtraNode(t.ast.getNode(actual_arrow).data.extra, ast_mod.ArrowExtra.params);
        try std.testing.expect(actual_params != old_params);
        const actual_list = t.ast.getNode(actual_params).data.list;
        try std.testing.expectEqual(old_list.len, actual_list.len);
        try std.testing.expect(try ast_walk.parameterListHasExpressions(a, t.ast, actual_list));
        for (prefix, 0..) |original, index| try std.testing.expectEqual(original, t.ast.readExtraNode(actual_list.start, @intCast(index)));
        const editor = &t.semantic_editor.?;
        for (original_bindings.items) |original| {
            try std.testing.expectEqual(@as(?u32, original.symbol), t.getSymbolIdAt(original.node));
            const symbol = editor.symbols.items[original.symbol];
            try std.testing.expectEqual(original.scope, symbol.scope_id);
            try std.testing.expectEqual(original.kind, symbol.kind);
            try std.testing.expect(std.meta.eql(original.flags, symbol.decl_flags));
        }
        const owner = t.outputOwnedScope(actual_params);
        if (owner != parameter_scope) owner_gaps += 1;
        const reachable = try ast_walk.collectReachableNodeIndicesFrom(a, t.ast, output);
        var parents = try scope_utils.buildParentMap(a, t.ast, output);
        var owners: std.AutoHashMapUnmanaged(u32, u32) = .empty;
        for (reachable) |raw| if (t.outputOwnedScope(@fromBackingInt(raw))) |scope| {
            try owners.put(a, raw, @backingInt(scope));
        };
        for (prefix_count..actual_list.len) |index| {
            const formal = t.ast.readExtraNode(actual_list.start, @intCast(index));
            const binding = @import("../native_constructor_timing.zig").simpleFormalBinding(&t, formal).?;
            const sid = t.getSymbolIdAt(binding).?;
            const symbol = editor.symbols.items[sid];
            if (symbol.scope_id != parameter_scope) storage_gaps += 1;
            if (scope_utils.expectedScope(t.ast, output, &parents, &owners, @backingInt(binding)) != parameter_scope) structural_scope_gaps += 1;
            var declarations: usize = 0;
            var reads: usize = 0;
            for (editor.references.items) |row| {
                if (@backingInt(row.symbol_id) != sid) continue;
                if (row.flags.declare and row.declaration_node_index == binding) {
                    declarations += 1;
                    if (row.scope_id != parameter_scope) declaration_scope_gaps += 1;
                }
                if (!row.flags.declare and row.flags.read) {
                    reads += 1;
                    try std.testing.expectEqual(source_body_scope, row.scope_id);
                    try std.testing.expectEqual(@as(?ScopeId, source_body_scope), scope_utils.expectedScope(t.ast, output, &parents, &owners, @backingInt(row.node_index)));
                }
            }
            try std.testing.expectEqual(@as(usize, 1), declarations);
            try std.testing.expect(reads > 0);
            raw_bindings_checked += 1;
            std.debug.print("native-arrow-birth case={d} formal={d} raw={d} sid={d} expectedP={d} actualStorage={d} expectedReadB={d} reads={d} owner={any}\n", .{ case_index, @backingInt(actual_params), @backingInt(binding), sid, @backingInt(parameter_scope), @backingInt(symbol.scope_id), @backingInt(source_body_scope), reads, owner });
        }
        // Reparse emitted syntax independently: the actual native arrow really
        // has distinct P/B environments, not merely a retained scope-map alias.
        var codegen = @import("../../codegen/codegen.zig").Codegen.init(a, t.ast);
        const code = try codegen.generate(output);
        var fresh_scanner = try Scanner.init(a, code);
        var fresh_parser = Parser.init(a, &fresh_scanner);
        fresh_parser.configureFromExtension(".cjs");
        const fresh_root = try fresh_parser.parse();
        try std.testing.expectEqual(@as(usize, 0), fresh_parser.errors.items.len);
        var fresh_analyzer = Analyzer.init(a, &fresh_parser.ast);
        fresh_analyzer.is_strict_mode = fresh_parser.is_strict_mode;
        try fresh_analyzer.analyze();
        const fresh_declaration = fresh_parser.ast.getNode(fresh_parser.ast.readExtraNode(fresh_parser.ast.getNode(fresh_root).data.list.start, 0));
        const fresh_declarator = fresh_parser.ast.getNode(fresh_parser.ast.readExtraNode(fresh_parser.ast.readExtra(fresh_declaration.data.extra, 1), 0));
        const fresh_arrow = fresh_parser.ast.readExtraNode(fresh_declarator.data.extra, 2);
        const fresh_params = fresh_parser.ast.readExtraNode(fresh_parser.ast.getNode(fresh_arrow).data.extra, ast_mod.ArrowExtra.params);
        try std.testing.expect(try ast_walk.parameterListHasExpressions(a, &fresh_parser.ast, fresh_parser.ast.getNode(fresh_params).data.list));
        const fresh_body_scope = fresh_analyzer.scope_owner_map.get(@backingInt(fresh_arrow)).?;
        const fresh_parameter_scope = fresh_analyzer.scope_owner_map.get(@backingInt(fresh_params)).?;
        try std.testing.expect(fresh_parameter_scope != fresh_body_scope);
        try std.testing.expectEqual(@as(ScopeId, @fromBackingInt(fresh_parameter_scope)), fresh_analyzer.scopes.items[fresh_body_scope].parent);
        cases_checked += 1;
    }
    std.debug.print("native-arrow-birth summary cases={d} rawbindings={d} ownerGaps={d} storageGaps={d} declarationScopeGaps={d} structuralScopeGaps={d}\n", .{ cases_checked, raw_bindings_checked, owner_gaps, storage_gaps, declaration_scope_gaps, structural_scope_gaps });
    try std.testing.expectEqual(@as(usize, 10), cases_checked);
    try std.testing.expect(raw_bindings_checked >= 10);
    try std.testing.expectEqual(@as(usize, 0), owner_gaps);
    try std.testing.expectEqual(@as(usize, 0), storage_gaps);
    try std.testing.expectEqual(@as(usize, 0), declaration_scope_gaps);
    try std.testing.expectEqual(@as(usize, 0), structural_scope_gaps);
}

test "native arrow formal birth rejects changed owner tuples transactionally" {
    const Scanner = @import("../../lexer/scanner.zig").Scanner;
    const Parser = @import("../../parser/parser.zig").Parser;
    const Analyzer = @import("../../semantic/analyzer.zig").SemanticAnalyzer;
    const Transformer = @import("../transformer.zig").Transformer;
    const ScopeId = @import("../../semantic/scope.zig").ScopeId;
    const Params = es2015_params.ES2015Params(Transformer);
    const source = "const read=([head=1],{a,...rest})=>{eval('a');return[head,a]};const other=([other=2],{x,...remaining})=>{eval('x');return[other,x]}";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var scanner = try Scanner.init(a, source);
    var parser = Parser.init(a, &scanner);
    parser.configureFromExtension(".cjs");
    const root = try parser.parse();
    try std.testing.expectEqual(@as(usize, 0), parser.errors.items.len);
    var analyzer = Analyzer.init(a, &parser.ast);
    analyzer.is_strict_mode = parser.is_strict_mode;
    analyzer.enable_stmt_info = true;
    analyzer.enable_exact_declaration_anchors = true;
    try analyzer.analyze();
    var body_scopes: [2]ScopeId = undefined;
    for (0..2) |index| {
        const declaration = parser.ast.getNode(parser.ast.readExtraNode(parser.ast.getNode(root).data.list.start, @intCast(index)));
        const declarator = parser.ast.getNode(parser.ast.readExtraNode(parser.ast.readExtra(declaration.data.extra, 1), 0));
        const arrow = parser.ast.readExtraNode(declarator.data.extra, 2);
        body_scopes[index] = @fromBackingInt(analyzer.scope_owner_map.get(@backingInt(arrow)).?);
    }
    var t = try Transformer.init(a, &parser.ast, .{ .unsupported = @import("../compat.zig").fromESTarget(.es2017), .emit_runtime_helper_imports = false });
    try t.initSymbolIds(analyzer.symbol_ids.items);
    t.symbols = analyzer.symbols.items;
    t.references = analyzer.references.items;
    t.scopes = analyzer.scopes.items;
    t.scope_maps = analyzer.scope_maps.items;
    t.scope_owner_map = analyzer.scope_owner_map;
    t.unresolved_references = &analyzer.unresolved_references;
    t.semantic_edit_enabled = true;
    try t.buildBlockRenameMap();
    const output = try t.visitNode(root);
    try t.registerGeneratedFunctionScopes(output, t.programScope());
    var arrows: [2]NodeIndex = .{ .none, .none };
    for (try ast_walk.collectReachableNodeIndicesFrom(a, t.ast, output)) |raw| {
        const idx: NodeIndex = @fromBackingInt(raw);
        if (t.ast.getNode(idx).tag != .arrow_function_expression) continue;
        for (body_scopes, 0..) |scope, index| if (t.outputOwnedScope(idx) == scope) {
            try std.testing.expect(arrows[index].isNone());
            arrows[index] = idx;
        };
    }
    try std.testing.expect(!arrows[0].isNone() and !arrows[1].isNone());
    var old_params: [2]NodeIndex = undefined;
    var plans: [2]es2015_params.NativeArrowFormalPlan = undefined;
    const saved_scope = t.current_scope;
    for (arrows, 0..) |arrow, index| {
        old_params[index] = t.ast.readExtraNode(t.ast.getNode(arrow).data.extra, ast_mod.ArrowExtra.params);
        t.current_scope = body_scopes[index];
        plans[index] = (try Params.planNativeArrowFormals(&t, t.ast.getNode(old_params[index]).data.list, .{ .ast_owner = t.ast, .function_node = arrow, .params_node = old_params[index], .body_scope = body_scopes[index] })).?;
    }
    t.current_scope = saved_scope;
    var foreign_ast = try t.ast.cloneForTransformer(a);
    try std.testing.expectEqual(t.ast.getNode(arrows[0]).tag, foreign_ast.getNode(arrows[0]).tag);
    const source_owner = plans[0].owner;
    const source_list = t.ast.getNode(old_params[0]).data.list;
    t.current_scope = body_scopes[0];
    var wrong_source = source_owner;
    wrong_source.ast_owner = &foreign_ast;
    try std.testing.expectError(error.InvalidNativeArrowParameterOwner, Params.planNativeArrowFormals(&t, source_list, wrong_source));
    wrong_source = source_owner;
    wrong_source.function_node = arrows[1];
    try std.testing.expectError(error.InvalidNativeArrowParameterOwner, Params.planNativeArrowFormals(&t, source_list, wrong_source));
    wrong_source = source_owner;
    wrong_source.params_node = old_params[1];
    try std.testing.expectError(error.InvalidNativeArrowParameterOwner, Params.planNativeArrowFormals(&t, source_list, wrong_source));
    wrong_source = source_owner;
    wrong_source.body_scope = body_scopes[1];
    try std.testing.expectError(error.InvalidNativeArrowParameterOwner, Params.planNativeArrowFormals(&t, source_list, wrong_source));
    try std.testing.expect((try Params.planNativeArrowFormals(&t, source_list, source_owner)) != null);
    t.current_scope = saved_scope;
    try lowerAllFunctionParams(&t, output);
    const actual_params = t.ast.readExtraNode(t.ast.getNode(arrows[0]).data.extra, ast_mod.ArrowExtra.params);
    const other_params = t.ast.readExtraNode(t.ast.getNode(arrows[1]).data.extra, ast_mod.ArrowExtra.params);
    try std.testing.expect(try Params.validNativeArrowFormals(&t, plans[0], actual_params));
    try std.testing.expect(try Params.validNativeArrowFormals(&t, plans[1], other_params));
    const editor = &t.semantic_editor.?;
    const parameter_scope = plans[0].prefix.parameter_scope.?;
    const other_parameter_scope = plans[1].prefix.parameter_scope.?;
    try std.testing.expect(parameter_scope != other_parameter_scope);
    const raw_binding = @import("../native_constructor_timing.zig").simpleFormalBinding(&t, t.ast.readExtraNode(t.ast.getNode(actual_params).data.list.start, 1)).?;
    const raw_sid = t.getSymbolIdAt(raw_binding).?;
    const Reject = struct {
        fn call(tr: anytype, plan: es2015_params.NativeArrowFormalPlan, params: NodeIndex) !void {
            const Traits = es2015_params.ES2015Params(@TypeOf(tr.*));
            const e = &tr.semantic_editor.?;
            const counts = .{ e.scopes.items.len, e.symbols.items.len, e.references.items.len, tr.transformed_scope_owner_map.count(), tr.scope_owner_remaps.count(), tr.scope_owner_origins.count(), e.scope_owner_map.count() };
            const existing_owner = tr.outputOwnedScope(params);
            try std.testing.expectError(error.InvalidNativeArrowParameterOwner, Traits.publishNativeArrowFormals(tr, plan, params));
            try std.testing.expectEqual(counts[0], e.scopes.items.len);
            try std.testing.expectEqual(counts[1], e.symbols.items.len);
            try std.testing.expectEqual(counts[2], e.references.items.len);
            try std.testing.expectEqual(counts[3], tr.transformed_scope_owner_map.count());
            try std.testing.expectEqual(counts[4], tr.scope_owner_remaps.count());
            try std.testing.expectEqual(counts[5], tr.scope_owner_origins.count());
            try std.testing.expectEqual(counts[6], e.scope_owner_map.count());
            try std.testing.expectEqual(existing_owner, tr.outputOwnedScope(params));
        }
    };
    const Fault = enum { foreign_owner, foreign_prefix, sibling_plan, sibling_function, sibling_source_formals, sibling_body, sibling_parameter_scope, prefix_sid, prefix_scope, prefix_flags };
    var rejected: usize = 0;
    for (std.enums.values(Fault)) |fault| {
        var bad = plans[0];
        switch (fault) {
            .foreign_owner => bad.owner.ast_owner = &foreign_ast,
            .foreign_prefix => bad.prefix.ast_owner = &foreign_ast,
            .sibling_plan => bad = plans[1],
            .sibling_function => {
                bad.owner.function_node = arrows[1];
                bad.prefix.function_owner = arrows[1];
            },
            .sibling_source_formals => bad.owner.params_node = old_params[1],
            .sibling_body => {
                bad.owner.body_scope = body_scopes[1];
                bad.prefix.body_scope = body_scopes[1];
            },
            .sibling_parameter_scope => {
                bad.prefix.parameter_scope = other_parameter_scope;
                bad.prefix.body_parent = other_parameter_scope;
            },
            .prefix_sid, .prefix_scope, .prefix_flags => {
                const changed = try a.dupe(es2015_params.RetainedPrefixBinding, bad.prefix.bindings);
                switch (fault) {
                    .prefix_sid => changed[0].symbol = raw_sid,
                    .prefix_scope => changed[0].scope = other_parameter_scope,
                    .prefix_flags => changed[0].flags.is_parameter = false,
                    else => unreachable,
                }
                bad.prefix.bindings = changed;
            },
        }
        try Reject.call(&t, bad, actual_params);
        try std.testing.expect(try Params.validNativeArrowFormals(&t, plans[0], actual_params));
        rejected += 1;
        std.debug.print("native-arrow-owner hostile={s} rejected+restored\n", .{@tagName(fault)});
    }
    try Reject.call(&t, plans[0], other_params);
    rejected += 1;
    // A valid sibling ScopeId cannot replace the actual new-formal carrier.
    const actual_key = @backingInt(actual_params);
    const stored_owner = t.transformed_scope_owner_map.get(actual_key).?;
    try t.transformed_scope_owner_map.put(a, actual_key, @backingInt(other_parameter_scope));
    try Reject.call(&t, plans[0], actual_params);
    try t.transformed_scope_owner_map.put(a, actual_key, stored_owner);
    try std.testing.expect(try Params.validNativeArrowFormals(&t, plans[0], actual_params));
    rejected += 1;
    // Actual syntax with no parameter expressions must fail independently of
    // planned truth. This remains a structurally valid native simple list.
    const original_list = t.ast.getNode(actual_params).data.list;
    const simple_list = try t.ast.addNodeList(&.{ plans[0].prefix.bindings[0].node, raw_binding });
    t.ast.nodes.items[@backingInt(actual_params)].data.list = simple_list;
    try std.testing.expect(!try ast_walk.parameterListHasExpressions(a, t.ast, simple_list));
    try Reject.call(&t, plans[0], actual_params);
    t.ast.nodes.items[@backingInt(actual_params)].data.list = original_list;
    try std.testing.expect(try Params.validNativeArrowFormals(&t, plans[0], actual_params));
    rejected += 1;
    const storage = editor.symbols.items[raw_sid].scope_id;
    editor.symbols.items[raw_sid].scope_id = other_parameter_scope;
    try Reject.call(&t, plans[0], actual_params);
    editor.symbols.items[raw_sid].scope_id = storage;
    try std.testing.expect(try Params.validNativeArrowFormals(&t, plans[0], actual_params));
    rejected += 1;
    var declaration_row: ?usize = null;
    for (editor.references.items, 0..) |row, index| {
        if (row.flags.declare and row.declaration_node_index == raw_binding) {
            try std.testing.expect(declaration_row == null);
            declaration_row = index;
        }
    }
    const index = declaration_row.?;
    const declared_scope = editor.references.items[index].scope_id;
    editor.references.items[index].scope_id = body_scopes[1];
    try Reject.call(&t, plans[0], actual_params);
    editor.references.items[index].scope_id = declared_scope;
    try std.testing.expect(try Params.validNativeArrowFormals(&t, plans[0], actual_params));
    rejected += 1;
    // A declaration anchor is not a runtime reference. Keep the source
    // symbol's declaration facts independent of these reference-row flags.
    const pure_anchor = editor.references.items[index];
    try std.testing.expect(pure_anchor.node_index.isNone());
    try std.testing.expect(std.meta.eql(pure_anchor.flags, @import("../../semantic/symbol.zig").ReferenceFlags{ .declare = true }));
    for ([_]@import("../../semantic/symbol.zig").ReferenceFlags{
        .{ .declare = true, .read = true },
        .{ .declare = true, .write = true },
    }) |mixed_flags| {
        editor.references.items[index].flags = mixed_flags;
        try Reject.call(&t, plans[0], actual_params);
        editor.references.items[index] = pure_anchor;
        try std.testing.expect(try Params.validNativeArrowFormals(&t, plans[0], actual_params));
        rejected += 1;
    }
    var live_read: NodeIndex = .none;
    for (editor.references.items) |row| {
        if (!row.flags.declare and row.flags.read and @backingInt(row.symbol_id) == raw_sid) {
            try std.testing.expect(!row.node_index.isNone());
            live_read = row.node_index;
            break;
        }
    }
    try std.testing.expect(!live_read.isNone());
    editor.references.items[index].node_index = live_read;
    try Reject.call(&t, plans[0], actual_params);
    editor.references.items[index] = pure_anchor;
    try std.testing.expect(try Params.validNativeArrowFormals(&t, plans[0], actual_params));
    rejected += 1;
    std.debug.print("native-arrow-anchor hostile=read/write/runtime-node rejected+restored pure-declare=true\n", .{});
    const node_raw = @backingInt(raw_binding);
    const old_mirror = t.symbol_ids.items[node_raw];
    const old_editor_id = editor.symbol_ids.items[node_raw];
    const same_scope_wrong_sid = plans[0].prefix.bindings[0].symbol;
    t.symbol_ids.items[node_raw] = same_scope_wrong_sid;
    editor.symbol_ids.items[node_raw] = same_scope_wrong_sid;
    try Reject.call(&t, plans[0], actual_params);
    t.symbol_ids.items[node_raw] = old_mirror;
    editor.symbol_ids.items[node_raw] = old_editor_id;
    try std.testing.expect(try Params.validNativeArrowFormals(&t, plans[0], actual_params));
    rejected += 1;
    const saved_rows = try a.dupe(@import("../../semantic/symbol.zig").Reference, editor.references.items);
    _ = editor.references.orderedRemove(index);
    try Reject.call(&t, plans[0], actual_params);
    editor.references.clearRetainingCapacity();
    try editor.references.appendSlice(a, saved_rows);
    try std.testing.expect(try Params.validNativeArrowFormals(&t, plans[0], actual_params));
    rejected += 1;
    try editor.references.append(a, saved_rows[index]);
    try Reject.call(&t, plans[0], actual_params);
    editor.references.shrinkRetainingCapacity(saved_rows.len);
    try std.testing.expect(try Params.validNativeArrowFormals(&t, plans[0], actual_params));
    rejected += 1;
    try Params.publishNativeArrowFormals(&t, plans[0], actual_params);
    try std.testing.expectEqual(@as(?ScopeId, parameter_scope), t.outputOwnedScope(actual_params));
    try std.testing.expectEqual(@as(usize, 21), rejected);
    std.debug.print("native-arrow-owner summary source-rejections=4 publication-rejections={d} restored-positive=true\n", .{rejected});
}

test "native arrow formal birth creates raw reads before assembly relocation" {
    const Scanner = @import("../../lexer/scanner.zig").Scanner;
    const Parser = @import("../../parser/parser.zig").Parser;
    const Analyzer = @import("../../semantic/analyzer.zig").SemanticAnalyzer;
    const Transformer = @import("../transformer.zig").Transformer;
    const ScopeId = @import("../../semantic/scope.zig").ScopeId;
    const Params = es2015_params.ES2015Params(Transformer);
    const source = "const read=([head=1],{a,...rest})=>{eval('a');return[head,a]};const other=([other=2],{x,...remaining})=>{eval('x');return[other,x]}";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var scanner = try Scanner.init(a, source);
    var parser = Parser.init(a, &scanner);
    parser.configureFromExtension(".cjs");
    const root = try parser.parse();
    try std.testing.expectEqual(@as(usize, 0), parser.errors.items.len);
    var analyzer = Analyzer.init(a, &parser.ast);
    analyzer.is_strict_mode = parser.is_strict_mode;
    analyzer.enable_stmt_info = true;
    analyzer.enable_exact_declaration_anchors = true;
    try analyzer.analyze();
    var body_scopes: [2]ScopeId = undefined;
    for (0..2) |index| {
        const declaration = parser.ast.getNode(parser.ast.readExtraNode(parser.ast.getNode(root).data.list.start, @intCast(index)));
        const declarator = parser.ast.getNode(parser.ast.readExtraNode(parser.ast.readExtra(declaration.data.extra, 1), 0));
        const arrow = parser.ast.readExtraNode(declarator.data.extra, 2);
        body_scopes[index] = @fromBackingInt(analyzer.scope_owner_map.get(@backingInt(arrow)).?);
    }
    var t = try Transformer.init(a, &parser.ast, .{ .unsupported = @import("../compat.zig").fromESTarget(.es2017), .emit_runtime_helper_imports = false });
    try t.initSymbolIds(analyzer.symbol_ids.items);
    t.symbols = analyzer.symbols.items;
    t.references = analyzer.references.items;
    t.scopes = analyzer.scopes.items;
    t.scope_maps = analyzer.scope_maps.items;
    t.scope_owner_map = analyzer.scope_owner_map;
    t.unresolved_references = &analyzer.unresolved_references;
    t.semantic_edit_enabled = true;
    try t.buildBlockRenameMap();
    const output = try t.visitNode(root);
    try t.registerGeneratedFunctionScopes(output, t.programScope());
    var arrows: [2]NodeIndex = .{ .none, .none };
    for (try ast_walk.collectReachableNodeIndicesFrom(a, t.ast, output)) |raw| {
        const idx: NodeIndex = @fromBackingInt(raw);
        if (t.ast.getNode(idx).tag != .arrow_function_expression) continue;
        for (body_scopes, 0..) |scope, index| if (t.outputOwnedScope(idx) == scope) {
            try std.testing.expect(arrows[index].isNone());
            arrows[index] = idx;
        };
    }
    try std.testing.expect(!arrows[0].isNone() and !arrows[1].isNone());
    var checked: usize = 0;
    for (arrows, 0..) |arrow, index| {
        const params = t.ast.readExtraNode(t.ast.getNode(arrow).data.extra, ast_mod.ArrowExtra.params);
        const parameter_scope = t.outputOwnedScope(params).?;
        t.current_scope = body_scopes[index];
        var lowered = try Params.lowerParamsPass2ForNativeArrow(&t, t.ast.getNode(params).data.list, t.ast.getNode(arrow).span, .{
            .ast_owner = t.ast,
            .function_node = arrow,
            .params_node = params,
            .body_scope = body_scopes[index],
        });
        defer lowered.body_stmts.deinit(a);
        try std.testing.expect(lowered.native_arrow_formals != null);
        // Inspect the creator result before driver.moveSourceReferences can
        // relocate a wrongly born P read to its eventual body B.
        const raw = t.ast.readExtraNode(lowered.new_params.start, 1);
        const binding = @import("../native_constructor_timing.zig").simpleFormalBinding(&t, raw).?;
        const sid = t.getSymbolIdAt(binding).?;
        const editor = &t.semantic_editor.?;
        try std.testing.expectEqual(parameter_scope, editor.symbols.items[sid].scope_id);
        var reads: usize = 0;
        var declarations: usize = 0;
        for (editor.references.items) |row| {
            if (@backingInt(row.symbol_id) != sid) continue;
            if (row.flags.declare) {
                declarations += 1;
                try std.testing.expectEqual(binding, row.declaration_node_index);
                try std.testing.expectEqual(parameter_scope, row.scope_id);
            } else {
                reads += 1;
                try std.testing.expect(row.flags.read and !row.flags.write);
                try std.testing.expectEqual(body_scopes[index], row.scope_id);
            }
        }
        try std.testing.expectEqual(@as(usize, 1), declarations);
        try std.testing.expect(reads > 0);
        checked += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), checked);
    std.debug.print("native-arrow-creator summary cases=2 before-assembly=true storageP/readB=true\n", .{});
}

test "native arrow formal birth P5 publishes raw coordinates after actual helper prefix before output walk" {
    const Scanner = @import("../../lexer/scanner.zig").Scanner;
    const Parser = @import("../../parser/parser.zig").Parser;
    const Analyzer = @import("../../semantic/analyzer.zig").SemanticAnalyzer;
    const Transformer = @import("../transformer.zig").Transformer;
    const ScopeId = @import("../../semantic/scope.zig").ScopeId;
    const scope_utils = @import("../output_scope_test_utils.zig");
    const Params = es2015_params.ES2015Params(Transformer);
    var cases_checked: usize = 0;
    var raw_bindings_checked: usize = 0;
    var raw_reads_checked: usize = 0;
    var assembly_gaps: usize = 0;
    var prefix_gaps: usize = 0;
    for ([_][]const u8{
        "const read=([head=1],{a,...rest})=>{eval('a');return[head,a,read.length]}",
        "const read=({head=1},{a,...rest})=>{eval('a');return[head,a]}",
        "const read=([[head=1]],{a,...rest})=>{eval('a');return[head,a]}",
        "const read=([head=1],{other},{a,...rest})=>{eval('a');return[head,other,a]}",
        "const read=({[Number(2)]:head},{a,...rest})=>{eval('a');return[head,a]}",
        "const read=(get=()=>2,{a,...rest})=>{eval('a');return[get(),a]}",
        "const read=(get=function local(marker=2){return marker},{a,...rest})=>{eval('a');return[get(),a]}",
        "const read=(head=1,{a,...rest})=>{eval('a');return[head,a]}",
        "const read=([{head=1}],{a,...rest})=>{eval('a');return[head,a]}",
        "const read=([head=1],{a,...rest},{b,...tail})=>{eval('a');return[head,a,b,rest,tail]}",
    }, 0..) |source, case_index| {
        errdefer std.debug.print("native arrow formal birth source={d}: {s}\n", .{ case_index, source });
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var scanner = try Scanner.init(a, source);
        var parser = Parser.init(a, &scanner);
        parser.configureFromExtension(".cjs");
        const root = try parser.parse();
        try std.testing.expectEqual(@as(usize, 0), parser.errors.items.len);
        var analyzer = Analyzer.init(a, &parser.ast);
        analyzer.is_strict_mode = parser.is_strict_mode;
        analyzer.enable_stmt_info = true;
        analyzer.enable_exact_declaration_anchors = true;
        try analyzer.analyze();
        const declaration = parser.ast.getNode(parser.ast.readExtraNode(parser.ast.getNode(root).data.list.start, 0));
        const declarator = parser.ast.getNode(parser.ast.readExtraNode(parser.ast.readExtra(declaration.data.extra, 1), 0));
        const source_arrow = parser.ast.readExtraNode(declarator.data.extra, 2);
        try std.testing.expectEqual(ast_mod.Node.Tag.arrow_function_expression, parser.ast.getNode(source_arrow).tag);
        const source_body_scope: ScopeId = @fromBackingInt(analyzer.scope_owner_map.get(@backingInt(source_arrow)).?);
        var t = try Transformer.init(a, &parser.ast, .{ .unsupported = @import("../compat.zig").fromESTarget(.es2017), .emit_runtime_helper_imports = true });
        try t.initSymbolIds(analyzer.symbol_ids.items);
        t.symbols = analyzer.symbols.items;
        t.references = analyzer.references.items;
        t.scopes = analyzer.scopes.items;
        t.scope_maps = analyzer.scope_maps.items;
        t.scope_owner_map = analyzer.scope_owner_map;
        t.unresolved_references = &analyzer.unresolved_references;
        t.semantic_edit_enabled = true;
        try t.buildBlockRenameMap();
        var output = try t.visitNode(root);
        try t.registerGeneratedFunctionScopes(output, t.programScope());
        var actual_arrow: NodeIndex = .none;
        for (try ast_walk.collectReachableNodeIndicesFrom(a, t.ast, output)) |raw| {
            const idx: NodeIndex = @fromBackingInt(raw);
            if (t.ast.getNode(idx).tag != .arrow_function_expression or t.outputOwnedScope(idx) != source_body_scope) continue;
            try std.testing.expect(actual_arrow.isNone());
            actual_arrow = idx;
        }
        try std.testing.expect(!actual_arrow.isNone());
        const old_params = t.ast.readExtraNode(t.ast.getNode(actual_arrow).data.extra, ast_mod.ArrowExtra.params);
        const old_list = t.ast.getNode(old_params).data.list;
        const parameter_scope = t.outputOwnedScope(old_params).?;
        const prefix_count = (try Params.firstObjectRestParamIndex(&t, old_list)).?;
        const source_rows = try a.dupe(@import("../../semantic/symbol.zig").Reference, t.references);
        var batch: @import("../native_arrow_statement_publication.zig").Batch = .{};
        t.native_arrow_statement_batch = &batch;
        try lowerAllFunctionParams(&t, output);
        const actual_params = t.ast.readExtraNode(t.ast.getNode(actual_arrow).data.extra, ast_mod.ArrowExtra.params);
        const actual_list = t.ast.getNode(actual_params).data.list;
        const editor = &t.semantic_editor.?;
        const Handle = struct { row: usize, node: NodeIndex, sid: u32, scope: ScopeId, flags: @import("../../semantic/symbol.zig").ReferenceFlags };
        var handles: std.ArrayList(Handle) = .empty;
        for (prefix_count..actual_list.len) |offset| {
            const raw_formal = t.ast.readExtraNode(actual_list.start, @intCast(offset));
            const binding = @import("../native_constructor_timing.zig").simpleFormalBinding(&t, raw_formal).?;
            const sid = t.getSymbolIdAt(binding).?;
            try std.testing.expectEqual(parameter_scope, editor.symbols.items[sid].scope_id);
            raw_bindings_checked += 1;
            var declarations: usize = 0;
            for (editor.references.items, 0..) |row, row_index| {
                if (@backingInt(row.symbol_id) != sid) continue;
                if (row.flags.declare) {
                    try std.testing.expect(row.node_index.isNone());
                    try std.testing.expectEqual(binding, row.declaration_node_index);
                    try std.testing.expectEqual(parameter_scope, row.scope_id);
                    try std.testing.expect(std.meta.eql(row.flags, @import("../../semantic/symbol.zig").ReferenceFlags{ .declare = true }));
                    declarations += 1;
                } else {
                    try std.testing.expect(row.flags.read and !row.flags.write);
                    try std.testing.expectEqual(source_body_scope, row.scope_id);
                    raw_reads_checked += 1;
                }
                try handles.append(a, .{ .row = row_index, .node = if (row.flags.declare) binding else row.node_index, .sid = sid, .scope = row.scope_id, .flags = row.flags });
            }
            try std.testing.expectEqual(@as(usize, 1), declarations);
        }
        var before_parents = try scope_utils.buildParentMap(a, t.ast, output);
        for (handles.items) |handle| {
            const expected = scope_utils.expectedStatementCoordinates(t.ast, &before_parents, @backingInt(handle.node)) orelse return error.TestUnexpectedResult;
            const row = editor.references.items[handle.row];
            if (row.stmt_idx != expected.stmt_idx or row.scope_stmt_idx != expected.scope_stmt_idx) assembly_gaps += 1;
        }
        // Exercise the actual driver helper-prefix producer, not a made-up
        // statement or a generic output finalizer that would heal the rows.
        var imports: std.ArrayList(NodeIndex) = .empty;
        try @import("../runtime_helper_imports.zig").appendHelperImports(&t, t.runtime_helpers, t.ast.getNode(output).span, &imports);
        try std.testing.expect(imports.items.len > 0);
        const prefix_len: u32 = @intCast(imports.items.len);
        output = try t.prependStatementsToBody(output, imports.items);
        try @import("../native_arrow_statement_publication.zig").publish(&t, &batch, output);
        var after_parents = try scope_utils.buildParentMap(a, t.ast, output);
        var case_gaps: usize = 0;
        for (handles.items) |handle| {
            const before = scope_utils.expectedStatementCoordinates(t.ast, &before_parents, @backingInt(handle.node)) orelse return error.TestUnexpectedResult;
            const after = scope_utils.expectedStatementCoordinates(t.ast, &after_parents, @backingInt(handle.node)) orelse return error.TestUnexpectedResult;
            try std.testing.expectEqual(before.stmt_idx + prefix_len, after.stmt_idx);
            // Formal bindings inherit the surrounding program context; body
            // reads keep their nested body-local statement index.
            try std.testing.expectEqual(if (handle.flags.declare) before.scope_stmt_idx + prefix_len else before.scope_stmt_idx, after.scope_stmt_idx);
            const row = editor.references.items[handle.row];
            try std.testing.expectEqual(handle.sid, @backingInt(row.symbol_id));
            try std.testing.expectEqual(handle.scope, row.scope_id);
            try std.testing.expect(std.meta.eql(handle.flags, row.flags));
            if (row.stmt_idx != after.stmt_idx or row.scope_stmt_idx != after.scope_stmt_idx) case_gaps += 1;
        }
        // The original prefix source rows are not ours to rewrite while
        // assembling the new formal/body edges or injecting helper imports.
        for (source_rows) |original| {
            if (original.node_index.isNone()) continue;
            for (editor.references.items) |row| {
                if (row.node_index != original.node_index) continue;
                try std.testing.expectEqual(original.stmt_idx, row.stmt_idx);
                try std.testing.expectEqual(original.scope_stmt_idx, row.scope_stmt_idx);
            }
        }
        prefix_gaps += case_gaps;
        cases_checked += 1;
        std.debug.print("native-arrow-P5 case={d} handles={d} helperPrefix={d} actualCoordinateGaps={d} before-finalizer=true\n", .{ case_index, handles.items.len, prefix_len, case_gaps });
    }
    std.debug.print("native-arrow-P5 summary cases={d} rawbindings={d} rawreads={d} assemblyGaps={d} helperPrefixGaps={d} genericWalk=false\n", .{ cases_checked, raw_bindings_checked, raw_reads_checked, assembly_gaps, prefix_gaps });
    try std.testing.expectEqual(@as(usize, 10), cases_checked);
    try std.testing.expectEqual(@as(usize, 11), raw_bindings_checked);
    try std.testing.expectEqual(@as(usize, 22), raw_reads_checked);
    // Stage two validates local placement; global coordinates remain uncommitted
    // until actual program-prefix assembly has completed.
    try std.testing.expectEqual(@as(usize, 33), assembly_gaps);
    try std.testing.expectEqual(@as(usize, 0), prefix_gaps);
}

test "native arrow formal birth P5 rejects foreign placement atomically before commit" {
    const Scanner = @import("../../lexer/scanner.zig").Scanner;
    const Parser = @import("../../parser/parser.zig").Parser;
    const Analyzer = @import("../../semantic/analyzer.zig").SemanticAnalyzer;
    const Transformer = @import("../transformer.zig").Transformer;
    const ScopeId = @import("../../semantic/scope.zig").ScopeId;
    const Params = es2015_params.ES2015Params(Transformer);
    const source = "const read=([head=1],{a,...rest})=>{{}eval('a');return[head,a]};const other=([other=2],{x,...remaining})=>{eval('x');return[other,x]}";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var scanner = try Scanner.init(a, source);
    var parser = Parser.init(a, &scanner);
    parser.configureFromExtension(".cjs");
    const root = try parser.parse();
    try std.testing.expectEqual(@as(usize, 0), parser.errors.items.len);
    var analyzer = Analyzer.init(a, &parser.ast);
    analyzer.is_strict_mode = parser.is_strict_mode;
    analyzer.enable_stmt_info = true;
    analyzer.enable_exact_declaration_anchors = true;
    try analyzer.analyze();
    var body_scopes: [2]ScopeId = undefined;
    for (0..2) |index| {
        const declaration = parser.ast.getNode(parser.ast.readExtraNode(parser.ast.getNode(root).data.list.start, @intCast(index)));
        const declarator = parser.ast.getNode(parser.ast.readExtraNode(parser.ast.readExtra(declaration.data.extra, 1), 0));
        const arrow = parser.ast.readExtraNode(declarator.data.extra, 2);
        body_scopes[index] = @fromBackingInt(analyzer.scope_owner_map.get(@backingInt(arrow)).?);
    }
    var t = try Transformer.init(a, &parser.ast, .{ .unsupported = @import("../compat.zig").fromESTarget(.es2017), .emit_runtime_helper_imports = true });
    try t.initSymbolIds(analyzer.symbol_ids.items);
    t.symbols = analyzer.symbols.items;
    t.references = analyzer.references.items;
    t.scopes = analyzer.scopes.items;
    t.scope_maps = analyzer.scope_maps.items;
    t.scope_owner_map = analyzer.scope_owner_map;
    t.unresolved_references = &analyzer.unresolved_references;
    t.semantic_edit_enabled = true;
    try t.buildBlockRenameMap();
    const output = try t.visitNode(root);
    try t.registerGeneratedFunctionScopes(output, t.programScope());
    var arrows: [2]NodeIndex = .{ .none, .none };
    for (try ast_walk.collectReachableNodeIndicesFrom(a, t.ast, output)) |raw| {
        const idx: NodeIndex = @fromBackingInt(raw);
        if (t.ast.getNode(idx).tag != .arrow_function_expression) continue;
        for (body_scopes, 0..) |scope, index| if (t.outputOwnedScope(idx) == scope) {
            try std.testing.expect(arrows[index].isNone());
            arrows[index] = idx;
        };
    }
    try std.testing.expect(!arrows[0].isNone() and !arrows[1].isNone());
    const Statements = @import("../native_arrow_statement_publication.zig");
    var batch: Statements.Batch = .{};
    t.native_arrow_statement_batch = &batch;
    try lowerAllFunctionParams(&t, output);
    try std.testing.expectEqual(@as(usize, 2), batch.plans.items.len);
    const Reject = struct {
        fn call(tr: anytype, plans: *Statements.Batch, root_node: NodeIndex) !void {
            const allocator = tr.allocator;
            const rows = try allocator.dupe(@import("../../semantic/symbol.zig").Reference, tr.semantic_editor.?.references.items);
            var published: std.ArrayList(?@import("../../semantic/statement_coordinates.zig").Context) = .empty;
            for (plans.plans.items) |plan| for (plan.handles) |handle| {
                try published.append(allocator, handle.published);
            };
            try std.testing.expectError(error.InvalidNativeArrowStatementPublication, Statements.publish(tr, plans, root_node));
            try std.testing.expectEqual(rows.len, tr.semantic_editor.?.references.items.len);
            for (rows, tr.semantic_editor.?.references.items) |before, after| try std.testing.expect(std.meta.eql(before, after));
            var index: usize = 0;
            for (plans.plans.items) |plan| for (plan.handles) |handle| {
                try std.testing.expect(std.meta.eql(published.items[index], handle.published));
                index += 1;
            };
        }
    };
    var foreign_ast = try t.ast.cloneForTransformer(a);
    const before = batch.plans.items[0];
    const second = batch.plans.items[1];
    var read_index: usize = 0;
    for (before.handles, 0..) |handle, index| if (!handle.flags.declare) {
        read_index = index;
        break;
    };
    const original_handle = before.handles[read_index];
    const other_read = second.handles[read_index];
    const editor = &t.semantic_editor.?;
    var rejected: usize = 0;
    const Fault = enum { ast_domain, params_edge, body_edge, valid_sid, valid_scope, read_flags, foreign_read, local_index, missing_handle };
    for (std.enums.values(Fault)) |fault| {
        switch (fault) {
            .ast_domain => batch.plans.items[0].formals.owner.ast_owner = &foreign_ast,
            .params_edge => batch.plans.items[0].actual_params = second.actual_params,
            .body_edge => batch.plans.items[0].body = second.body,
            .valid_sid => batch.plans.items[0].handles[read_index].id = other_read.id,
            .valid_scope => batch.plans.items[0].handles[read_index].scope = other_read.scope,
            .read_flags => batch.plans.items[0].handles[read_index].flags = .{ .write = true },
            .foreign_read => batch.plans.items[0].handles[read_index] = other_read,
            .local_index => batch.plans.items[0].handles[read_index].local += 1,
            .missing_handle => batch.plans.items[0].handles = before.handles[0 .. before.handles.len - 1],
        }
        try Reject.call(&t, &batch, output);
        before.handles[read_index] = original_handle;
        batch.plans.items[0] = before;
        rejected += 1;
    }
    var read_row: usize = 0;
    for (editor.references.items, 0..) |row, index| if (row.node_index == original_handle.node) {
        read_row = index;
        break;
    };
    const saved_row = editor.references.items[read_row];
    // Equal-to-actual coordinate numbers alone grant no external authority.
    var parents = try @import("../output_scope_test_utils.zig").buildParentMap(a, t.ast, output);
    const actual = @import("../output_scope_test_utils.zig").expectedStatementCoordinates(t.ast, &parents, @backingInt(original_handle.node)).?;
    editor.references.items[read_row].stmt_idx = actual.stmt_idx;
    editor.references.items[read_row].scope_stmt_idx = actual.scope_stmt_idx;
    try Reject.call(&t, &batch, output);
    editor.references.items[read_row] = saved_row;
    rejected += 1;
    try editor.references.append(a, saved_row);
    try Reject.call(&t, &batch, output);
    editor.references.shrinkRetainingCapacity(editor.references.items.len - 1);
    rejected += 1;
    const extra = t.ast.getNode(arrows[0]).data.extra;
    const old_body = t.ast.readExtraNode(extra, ast_mod.ArrowExtra.body);
    t.ast.extra_data.items[extra + ast_mod.ArrowExtra.body] = @backingInt(second.body);
    try Reject.call(&t, &batch, output);
    t.ast.extra_data.items[extra + ast_mod.ArrowExtra.body] = @backingInt(old_body);
    rejected += 1;
    try std.testing.expectError(error.InvalidNode, Statements.agree(&t, @backingInt(original_handle.node), null, original_handle.flags));
    try Statements.publish(&t, &batch, output);
    for (batch.plans.items) |plan| {
        try std.testing.expect(try Params.validNativeArrowFormals(&t, plan.formals, plan.actual_params));
        for (plan.handles) |handle| {
            try std.testing.expect(handle.published != null);
            if (!handle.flags.declare) try std.testing.expect((try Statements.agree(&t, @backingInt(handle.node), null, handle.flags)) != null);
        }
    }
    try Statements.validateCommitted(&t, &batch, output);
    const committed_read = editor.references.items[read_row];
    for (0..4) |fault| {
        switch (fault) {
            0 => editor.references.items[read_row].scope_id = other_read.scope,
            1 => editor.references.items[read_row].symbol_id = other_read.id,
            2 => editor.references.items[read_row].flags = .{ .write = true },
            3 => editor.references.items[read_row].stmt_idx = 1,
            else => unreachable,
        }
        const corrupt_rows = try a.dupe(@import("../../semantic/symbol.zig").Reference, editor.references.items);
        try std.testing.expectError(error.InvalidNativeArrowStatementPublication, Statements.validateCommitted(&t, &batch, output));
        try std.testing.expectError(error.InvalidNode, @import("semantic_edit.zig").bindOutputScopesAndReferencesChecked(&t, output, t.programScope()));
        for (corrupt_rows, editor.references.items) |before_row, after_row| try std.testing.expect(std.meta.eql(before_row, after_row));
        editor.references.items[read_row] = committed_read;
        try Statements.validateCommitted(&t, &batch, output);
    }
    // Move the first generated statement into an existing empty source
    // block at the same numeric top/local position. Its real lexical owner
    // changes although both coordinate numbers remain exactly equal.
    const body_list = t.ast.getNode(before.body).data.list;
    var source_block: NodeIndex = .none;
    var source_block_index: usize = 0;
    for (0..body_list.len) |offset| {
        const child = t.ast.readExtraNode(body_list.start, @intCast(offset));
        const child_node = t.ast.getNode(child);
        if (child_node.tag == .block_statement and child_node.data.list.len == 0) {
            source_block = child;
            source_block_index = offset;
            break;
        }
    }
    try std.testing.expect(!source_block.isNone() and source_block_index != 0);
    try std.testing.expect(t.outputOwnedScope(source_block) != null);
    try std.testing.expect(t.outputOwnedScope(source_block).? != before.formals.owner.body_scope);
    const empty_list = t.ast.getNode(source_block).data.list;
    const first_statement = t.ast.readExtraNode(body_list.start, 0);
    t.ast.nodes.items[@backingInt(source_block)].data.list = try t.ast.addNodeList(&.{first_statement});
    var moved_items: std.ArrayList(NodeIndex) = .empty;
    for (0..body_list.len) |offset| {
        if (offset == source_block_index) continue;
        try moved_items.append(a, if (offset == 0) source_block else t.ast.readExtraNode(body_list.start, @intCast(offset)));
    }
    t.ast.nodes.items[@backingInt(before.body)].data.list = try t.ast.addNodeList(moved_items.items);
    var moved_parents = try @import("../output_scope_test_utils.zig").buildParentMap(a, t.ast, output);
    const same_numbers = @import("../output_scope_test_utils.zig").expectedStatementCoordinates(t.ast, &moved_parents, @backingInt(original_handle.node)).?;
    try std.testing.expectEqual(batch.plans.items[0].handles[read_index].published.?.stmt_idx, same_numbers.stmt_idx);
    try std.testing.expectEqual(batch.plans.items[0].handles[read_index].published.?.scope_stmt_idx, same_numbers.scope_stmt_idx);
    const owner_changed_rows = try a.dupe(@import("../../semantic/symbol.zig").Reference, editor.references.items);
    try std.testing.expectError(error.InvalidNativeArrowStatementPublication, Statements.validateCommitted(&t, &batch, output));
    try std.testing.expectError(error.InvalidNode, @import("semantic_edit.zig").bindOutputScopesAndReferencesChecked(&t, output, t.programScope()));
    for (owner_changed_rows, editor.references.items) |before_row, after_row| try std.testing.expect(std.meta.eql(before_row, after_row));
    t.ast.nodes.items[@backingInt(before.body)].data.list = body_list;
    t.ast.nodes.items[@backingInt(source_block)].data.list = empty_list;
    try Statements.validateCommitted(&t, &batch, output);
    // A valid sibling ScopeId on the unchanged actual body is separately
    // rejected, rather than deriving reference scope from its old row.
    const body_key = @backingInt(before.body);
    const saved_body_owner = t.transformed_scope_owner_map.get(body_key);
    try t.transformed_scope_owner_map.put(a, body_key, @backingInt(second.formals.owner.body_scope));
    try std.testing.expectError(error.InvalidNativeArrowStatementPublication, Statements.validateCommitted(&t, &batch, output));
    try std.testing.expectError(error.InvalidNode, @import("semantic_edit.zig").bindOutputScopesAndReferencesChecked(&t, output, t.programScope()));
    if (saved_body_owner) |value| try t.transformed_scope_owner_map.put(a, body_key, value) else _ = t.transformed_scope_owner_map.remove(body_key);
    try Statements.validateCommitted(&t, &batch, output);
    // A real helper import is spliced after a valid commit. Neither row nor
    // snapshot changed, yet both are now stale relative to the actual root.
    var imports: std.ArrayList(NodeIndex) = .empty;
    try @import("../runtime_helper_imports.zig").appendHelperImports(&t, t.runtime_helpers, t.ast.getNode(output).span, &imports);
    try std.testing.expect(imports.items.len > 0);
    const prefixed = try t.prependStatementsToBody(output, imports.items);
    const before_reject = try a.dupe(@import("../../semantic/symbol.zig").Reference, editor.references.items);
    try std.testing.expectError(error.InvalidNativeArrowStatementPublication, Statements.validateCommitted(&t, &batch, prefixed));
    try std.testing.expectError(error.InvalidNode, @import("semantic_edit.zig").bindOutputScopesAndReferencesChecked(&t, prefixed, t.programScope()));
    for (before_reject, editor.references.items) |before_row, after_row| try std.testing.expect(std.meta.eql(before_row, after_row));
    // The actual program-splice producer explicitly republishes, then the
    // read-only consumer accepts the current placement without healing it.
    try Statements.publish(&t, &batch, prefixed);
    try Statements.validateCommitted(&t, &batch, prefixed);
    try t.bindOutputScopesAndReferences(prefixed, t.programScope());
    // Both declarations and reads survive generic consumption unchanged.
    for (batch.plans.items) |plan| for (plan.handles) |handle| {
        var matched: usize = 0;
        for (editor.references.items) |row| {
            const node = if (row.flags.declare) row.declaration_node_index else row.node_index;
            if (node != handle.node) continue;
            try std.testing.expectEqual(handle.id, row.symbol_id);
            try std.testing.expectEqual(handle.scope, row.scope_id);
            try std.testing.expect(std.meta.eql(handle.flags, row.flags));
            try std.testing.expectEqual(handle.published.?.stmt_idx, row.stmt_idx);
            try std.testing.expectEqual(handle.published.?.scope_stmt_idx, row.scope_stmt_idx);
            matched += 1;
        }
        try std.testing.expectEqual(@as(usize, 1), matched);
    };
    try std.testing.expectEqual(@as(usize, 12), rejected);
    std.debug.print("native-arrow-P5 hostile=12 atomic-reject+restore before-helper-prefix=true generic-consumer=true stale-program-splice-rejected=true committed-tuple-hostile4=true same-coordinates-new-owner-rejected=true body-known-owner-rejected=true\n", .{});
}

test "native arrow formal birth P5 borrowed batch restores nested and error lifetimes" {
    const Statements = @import("../native_arrow_statement_publication.zig");
    var original: Statements.Batch = .{};
    var outer: Statements.Batch = .{};
    var inner: Statements.Batch = .{};
    var slot: ?*Statements.Batch = &original;
    const Nested = struct {
        fn fail(pointer: *?*Statements.Batch, first: *Statements.Batch, second: *Statements.Batch) error{ExpectedExit}!void {
            const outer_lease = Statements.borrow(pointer, first);
            defer outer_lease.restore();
            {
                const inner_lease = Statements.borrow(pointer, second);
                defer inner_lease.restore();
                std.debug.assert(pointer.* == second);
            }
            std.debug.assert(pointer.* == first);
            return error.ExpectedExit;
        }
    };
    try std.testing.expectError(error.ExpectedExit, Nested.fail(&slot, &outer, &inner));
    try std.testing.expectEqual(@as(?*Statements.Batch, &original), slot);
    const success = Statements.borrow(&slot, &outer);
    try std.testing.expectEqual(@as(?*Statements.Batch, &outer), slot);
    success.restore();
    try std.testing.expectEqual(@as(?*Statements.Batch, &original), slot);
}

test "native arrow formal birth P5 production driver preserves nested rows with helper on and off" {
    const Scanner = @import("../../lexer/scanner.zig").Scanner;
    const Parser = @import("../../parser/parser.zig").Parser;
    const Analyzer = @import("../../semantic/analyzer.zig").SemanticAnalyzer;
    const Transformer = @import("../transformer.zig").Transformer;
    const Statements = @import("../native_arrow_statement_publication.zig");
    const scope_utils = @import("../output_scope_test_utils.zig");
    const arrow = "([head=1],{a,...rest})=>{eval('a');return[head,a,rest.b]}";
    const sources = [_][]const u8{
        "const read=" ++ arrow,
        "function outer(){return " ++ arrow ++ "}const read=outer()",
        "class Box{make(){return " ++ arrow ++ "}}const read=new Box().make()",
        "class Box{constructor(){this.read=" ++ arrow ++ "}}const read=new Box().read",
        "let read;{read=" ++ arrow ++ "}",
    };
    var controls: usize = 0;
    for (sources, 0..) |source, case_index| for ([_]bool{ false, true }) |imports| {
        errdefer std.debug.print("native-arrow-P5 production case={d} imports={any}\n", .{ case_index, imports });
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var scanner = try Scanner.init(a, source);
        var parser = Parser.init(a, &scanner);
        parser.configureFromExtension(".cjs");
        _ = try parser.parse();
        try std.testing.expectEqual(@as(usize, 0), parser.errors.items.len);
        var analyzer = Analyzer.init(a, &parser.ast);
        analyzer.enable_stmt_info = true;
        analyzer.enable_exact_declaration_anchors = true;
        try analyzer.analyze();
        var t = try Transformer.init(a, &parser.ast, .{ .unsupported = @import("../compat.zig").fromESTarget(.es2017), .emit_runtime_helper_imports = imports });
        try t.initSymbolIds(analyzer.symbol_ids.items);
        t.symbols = analyzer.symbols.items;
        t.references = analyzer.references.items;
        t.scopes = analyzer.scopes.items;
        t.scope_maps = analyzer.scope_maps.items;
        t.scope_owner_map = analyzer.scope_owner_map;
        t.unresolved_references = &analyzer.unresolved_references;
        t.semantic_edit_enabled = true;
        var outer_batch: Statements.Batch = .{};
        t.native_arrow_statement_batch = &outer_batch;
        const output = try t.transform();
        try std.testing.expectEqual(@as(?*Statements.Batch, &outer_batch), t.native_arrow_statement_batch);
        try std.testing.expectEqual(@as(usize, 0), outer_batch.plans.items.len);
        var parents = try scope_utils.buildParentMap(a, t.ast, output);
        var generated_formals: usize = 0;
        var reads: usize = 0;
        const editor = &t.semantic_editor.?;
        for (try ast_walk.collectReachableNodeIndicesFrom(a, t.ast, output)) |raw| {
            const idx: NodeIndex = @fromBackingInt(raw);
            const node = t.ast.getNode(idx);
            if (node.tag != .arrow_function_expression) continue;
            const actual_params = t.ast.readExtraNode(node.data.extra, ast_mod.ArrowExtra.params);
            const list = t.ast.getNode(actual_params).data.list;
            for (0..list.len) |offset| {
                const formal = t.ast.readExtraNode(list.start, @intCast(offset));
                const binding = @import("../native_constructor_timing.zig").simpleFormalBinding(&t, formal) orelse continue;
                if (@backingInt(binding) < t.parser_node_count) continue;
                const sid = t.getSymbolIdAt(binding).?;
                generated_formals += 1;
                var declarations: usize = 0;
                for (editor.references.items) |row| {
                    if (@backingInt(row.symbol_id) != sid) continue;
                    const anchor = if (row.flags.declare) row.declaration_node_index else row.node_index;
                    const expected = scope_utils.expectedStatementCoordinates(t.ast, &parents, @backingInt(anchor)) orelse return error.TestUnexpectedResult;
                    try std.testing.expectEqual(expected.stmt_idx, row.stmt_idx);
                    try std.testing.expectEqual(expected.scope_stmt_idx, row.scope_stmt_idx);
                    if (row.flags.declare) {
                        try std.testing.expect(row.node_index.isNone());
                        try std.testing.expectEqual(binding, row.declaration_node_index);
                        try std.testing.expect(std.meta.eql(row.flags, @import("../../semantic/symbol.zig").ReferenceFlags{ .declare = true }));
                        declarations += 1;
                    } else {
                        try std.testing.expect(row.flags.read and !row.flags.write);
                        reads += 1;
                    }
                }
                try std.testing.expectEqual(@as(usize, 1), declarations);
            }
        }
        try std.testing.expectEqual(@as(usize, 1), generated_formals);
        try std.testing.expectEqual(@as(usize, 2), reads);
        controls += 1;
    };
    // Runtime oracle is separate from the internal helper-import surface.
    for (sources) |declaration| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const source = try std.fmt.allocPrint(a, "{s};console.log(JSON.stringify(read([],{{a:2,b:3}})))", .{declaration});
        const native = try std.process.run(a, std.testing.io, .{ .argv = &.{ "node", "-e", source } });
        try std.testing.expect(native.term == .exited and native.term.exited == 0);
        for ([_]bool{ false, true }) |min| {
            const result = try @import("../../transpile.zig").transpile(a, source, "input.cjs", .{ .unsupported = @import("../compat.zig").fromESTarget(.es2017), .minify_identifiers = min, .minify_syntax = min, .minify_whitespace = min });
            const actual = try std.process.run(a, std.testing.io, .{ .argv = &.{ "node", "-e", result.code } });
            try std.testing.expect(actual.term == .exited and actual.term.exited == 0);
            try std.testing.expectEqualStrings(native.stdout, actual.stdout);
        }
    }
    try std.testing.expectEqual(@as(usize, 10), controls);
    std.debug.print("native-arrow-P5 production=10 helper-on/off nested=true declaration+read-final=true native-runtime=10\n", .{});
}
