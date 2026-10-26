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
        try @import("../es2015_generator.zig").ES2015Generator(@TypeOf(self.*)).projectFunctionStorageCoordinates(self, root);
        try @import("../native_constructor_timing.zig").projectCoordinates(self, root);
        try @import("../native_arguments.zig").publish(self, root);
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
    for (self.ast.extra_data.items[params_list.start .. params_list.start + params_list.len]) |raw_param| {
        const pattern = loweredParameterPattern(self, @fromBackingInt(@intCast(raw_param))) orelse continue;
        var bindings = try ast_walk.bindingIdentifiers(self.allocator, self.ast, pattern, .{});
        defer bindings.deinit();
        while (try bindings.next()) |binding| {
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

const DynamicParameterBody = struct { body: NodeIndex, arrow: NodeIndex };

fn validDynamicParameterEngineOwner(self: anytype, function_owner: NodeIndex, body_scope: @import("../../semantic/scope.zig").ScopeId, wrapper_scope: @import("../../semantic/scope.zig").ScopeId, wrapper: DynamicParameterBody) bool {
    if (!self.semantic_edit_enabled or self.options.unsupported.arrow or body_scope.isNone() or wrapper_scope.isNone() or
        self.outputOwnedScope(function_owner) != body_scope or self.outputOwnedScope(wrapper.arrow) != wrapper_scope) return false;
    const editor = if (self.semantic_editor) |*value| value else return false;
    if (body_scope.toIndex() >= editor.scopes.items.len or wrapper_scope.toIndex() >= editor.scopes.items.len or
        editor.scopes.items[body_scope.toIndex()].kind != .function or
        editor.scopes.items[wrapper_scope.toIndex()].kind != .function or
        editor.scopes.items[wrapper_scope.toIndex()].parent != body_scope) return false;
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
    const tail = self.ast.getNode(self.ast.readExtraNode(body.data.list.start, body.data.list.len - 1));
    if (tail.tag != .return_statement or tail.data.unary.operand.isNone()) return false;
    const call = self.ast.getNode(tail.data.unary.operand);
    return call.tag == .call_expression and self.ast.readExtraNode(call.data.extra, 0) == wrapper.arrow;
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
) Error!DynamicParameterBody {
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
    try self.scratch.appendSlice(self.allocator, body_var_copies);
    for (old[outer_prefix_len..]) |raw| try self.scratch.append(self.allocator, @fromBackingInt(@intCast(raw)));
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
    }

    const call = try es_helpers.makeCallExpr(self, arrow, &.{}, span);
    const return_stmt = try self.ast.addNode(.{
        .tag = .return_statement,
        .span = span,
        .data = .{ .unary = .{ .operand = call, .flags = 0 } },
    });
    const outer_top = self.scratch.items.len;
    defer self.scratch.shrinkRetainingCapacity(outer_top);
    for (old[0..outer_prefix_len]) |raw| try self.scratch.append(self.allocator, @fromBackingInt(@intCast(raw)));
    try self.scratch.appendSlice(self.allocator, parameter_initializers);
    try self.scratch.append(self.allocator, return_stmt);
    const outer_list = try self.ast.addNodeList(self.scratch.items[outer_top..]);
    return .{ .body = try self.ast.addNode(.{
        .tag = body.tag,
        .span = body.span,
        .data = .{ .list = outer_list },
    }), .arrow = arrow };
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
                // Parameter initializers now execute in the emitted function
                // body. Move direct expression provenance and nested lexical
                // roots at this producer, before publishing the new body.
                if (self.semantic_edit_enabled) {
                    if (self.outputOwnedScope(params_idx)) |parameter_scope| {
                        for (lr.body_stmts.items) |statement| {
                            try self.reparentGeneratedBodyScopes(parameter_scope, self.current_scope, statement);
                            try @import("../class_strict_context.zig").moveSourceReferences(self, statement, parameter_scope, parameter_scope, self.current_scope);
                        }
                    }
                }
                try moveLoweredPatternParameterBindings(self, params_list, self.current_scope);
                try moveUnlinkedParameterBindings(self, unlinked_parameters.items, self.current_scope);
                const parameter_initializer_len = lr.body_stmts.items.len;
                const body_wrapper_scope = if (lr.body_stmts.items.len > 0)
                    if (body_has_dynamic_lookup)
                        try reserveDynamicBodyWrapperScope(self, self.current_scope, function_flags)
                    else
                        null
                else
                    null;
                const copy_scope = body_wrapper_scope orelse self.current_scope;
                try appendParameterBodyVarCopies(self, self.current_scope, copy_scope, &lr.body_stmts);

                // formal_parameters 노드를 새로 만들어 extras[e+1]에 연결.
                // (여러 function 노드가 동일 params_idx를 공유할 수 있으므로 in-place mutation 금지:
                //  prependToFunctionBody 등은 params_idx를 복사하여 새 function 노드를 만든다.)
                const new_params_node = try self.ast.addFormalParameters(lr.new_params, params_node.span);
                self.ast.extra_data.items[e + 1] = @backingInt(new_params_node);
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
                            )
                        else
                            null;
                        const new_body = if (wrapper) |value| value.body else try prependParameterInitializers(self, body_idx, lr.body_stmts.items);
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
                var lr = try es2015_params.ES2015Params(Self).lowerParamsPass2(self, params_list, node.span);
                defer lr.body_stmts.deinit(self.allocator);
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
            const actual_formals = t.ast.getNode(params).data.list;
            var actual_simple = true;
            for (0..actual_formals.len) |offset| {
                if (@import("../native_constructor_timing.zig").simpleFormalBinding(&t, t.ast.readExtraNode(actual_formals.start, @intCast(offset))) == null) actual_simple = false;
            }
            if (!actual_simple) {
                // This retained native default requires a separate parameter
                // carrier publication; do not pretend it became body storage.
                try std.testing.expectEqual(source_scope, editor.symbols.items[id].scope_id);
                try std.testing.expect(t.native_arguments_declaration_origins.get(id) == null);
                retained_non_simple_cases += 1;
                std.debug.print("retained non-simple parameter carrier residual id={d} sourceScope={d} newParams={d}\n", .{ id, source_scope.toIndex(), @backingInt(params) });
                continue :source_cases;
            }
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
                if (editor.scopes.items[sibling_scope.toIndex()].parent != body_scope) continue;
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
    try std.testing.expectEqual(@as(usize, 10), simple_cases);
    try std.testing.expectEqual(@as(usize, 1), retained_non_simple_cases);
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
