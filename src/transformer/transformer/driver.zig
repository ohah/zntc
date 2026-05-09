const std = @import("std");
const ast_mod = @import("../../parser/ast.zig");
const es2015_params = @import("../es2015_params.zig");

const NodeIndex = ast_mod.NodeIndex;
const Error = std.mem.Allocator.Error;

pub fn transform(self: anytype) Error!NodeIndex {
    var scope = @import("../../profile.zig").begin(.transform);
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

    // 파서의 마지막 노드가 루트 (program). parser_node_count - 1.
    const root_idx: NodeIndex = @enumFromInt(self.parser_node_count - 1);
    const saved_temp_counter = self.temp_var_counter;
    // worklet anonymous naming counter — Transformer 인스턴스 재사용 시 매 transform당 0부터 시작.
    self.plugins.worklet.anonymous_counter = 0;
    var root = try self.visitNode(root_idx);

    // Pass 2: ES2015 params lowering 일괄 적용
    if (self.options.unsupported.default_params) {
        try lowerAllFunctionParams(self);
    }

    // top-level 임시 변수 호이스팅: var _a, _b, ... 선언을 program 앞에 삽입
    if (self.temp_var_counter > saved_temp_counter and !root.isNone()) {
        root = try self.hoistTempVars(root, saved_temp_counter, self.ast.getNode(root_idx).span);
    }

    // ES2015 tagged template: _templateObject 캐싱 함수를 program 맨 앞에 호이스팅
    if (self.tagged_template_fns.items.len > 0 and !root.isNone()) {
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

    // React Fast Refresh: 컴포넌트 등록 코드를 프로그램 끝에 추가 ($RefreshReg$만, $RefreshSig$ 제거)
    if (self.options.react_refresh and self.plugins.refresh.registrations.items.len > 0) {
        root = try self.appendRefreshRegistrations(root);
    }

    self.ast.transformed_root = root;
    self.ast.assertInvariants();
    return root;
}

/// Pass 2: 모든 function-like 노드의 params를 일괄 lowering.
/// Pass 1에서 생성된 모든 function_declaration, function_expression, function,
/// method_definition 노드를 순회하며, default/rest/destructuring params가 있으면
/// lowerParams를 적용하고 extra_data를 in-place 수정한다.
fn lowerAllFunctionParams(self: anytype) Error!void {
    const Self = @TypeOf(self.*);
    const node_count = self.ast.nodes.items.len;
    var i: usize = 0;
    while (i < node_count) : (i += 1) {
        const node = self.ast.nodes.items[i];
        switch (node.tag) {
            .function_declaration, .function_expression, .function, .method_definition => {
                // extra layout: [name_or_key(0), params(1), body(2), ...]
                const e = node.data.extra;
                if (e + 2 >= self.ast.extra_data.items.len) continue;
                const params_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[e + 1]);
                if (params_idx.isNone() or @intFromEnum(params_idx) >= self.ast.nodes.items.len) continue;
                const params_node = self.ast.getNode(params_idx);
                if (params_node.tag != .formal_parameters) continue;
                const params_list = params_node.data.list;
                if (params_list.len == 0) continue;
                if (!es2015_params.ES2015Params(Self).hasDefaultOrRest(self, params_list)) continue;

                var lr = try es2015_params.ES2015Params(Self).lowerParamsPass2(self, params_list, node.span);
                defer lr.body_stmts.deinit(self.allocator);

                // formal_parameters 노드를 새로 만들어 extras[e+1]에 연결.
                // (여러 function 노드가 동일 params_idx를 공유할 수 있으므로 in-place mutation 금지:
                //  prependToFunctionBody 등은 params_idx를 복사하여 새 function 노드를 만든다.)
                const new_params_node = try self.ast.addFormalParameters(lr.new_params, params_node.span);
                self.ast.extra_data.items[e + 1] = @intFromEnum(new_params_node);

                if (lr.body_stmts.items.len > 0) {
                    const body_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[e + 2]);
                    if (!body_idx.isNone()) {
                        const new_body = try self.prependStatementsToBody(body_idx, lr.body_stmts.items);
                        self.ast.extra_data.items[e + 2] = @intFromEnum(new_body);
                    }
                }
            },
            else => {},
        }
    }
}
