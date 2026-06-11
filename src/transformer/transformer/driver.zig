const std = @import("std");
const ast_mod = @import("../../parser/ast.zig");
const es2015_params = @import("../es2015_params.zig");

const NodeIndex = ast_mod.NodeIndex;
const Error = std.mem.Allocator.Error;

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

    // 파서의 마지막 노드가 루트 (program). parser_node_count - 1.
    const root_idx: NodeIndex = @enumFromInt(self.parser_node_count - 1);
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

    // Pass 2: ES2015 params lowering 일괄 적용
    // #4251: object rest 가 든 param (`{a, ...r}`, ES2018) 은 default_params 지원
    // 타겟(es2017)에서도 lowering 필요 → object_spread 도 게이트. per-function 은
    // lowerAllFunctionParams 가 target-aware 로 object-rest param 만 선별(default-
    // param-only 함수 과트리거 방지).
    if (self.options.unsupported.default_params or self.options.unsupported.object_spread) {
        var pass2_scope = profile.begin(.transform_pass2);
        defer pass2_scope.end();
        try lowerAllFunctionParams(self);
    }

    var finalize_scope = profile.begin(.transform_finalize);
    defer finalize_scope.end();

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

    // #3062: JSX automatic runtime import 를 정식 AST 노드로 추가.
    // 기존엔 `JsxImportInfo.buildImportString` 으로 만든 string 을 `transpile.zig`
    // 가 출력 앞에 prepend 하던 single-file 경로뿐이라, bundle 흐름은 별도 synthetic
    // ImportRecord/Binding 우회 경로 (parser_metadata) 를 사용했다. transformer 가
    // 정식 AST 노드를 만들면 bundle 의 resync 도 일반 import 로 처리한다.
    // 동일 게이트 (`emit_runtime_helper_imports`) — bundle pre-pass 만 true, emitter
    // in-place transform 호출은 false 유지.
    if (self.options.emit_runtime_helper_imports and !root.isNone() and
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

    // React Fast Refresh: 컴포넌트 등록 코드를 프로그램 끝에 추가 ($RefreshReg$만, $RefreshSig$ 제거).
    // refreshEnabled() 가 path filter (Vite plugin-react 호환 — `.[jt]sx?$`/`.mjs$` + node_modules 제외) 까지 검증.
    if (self.refreshEnabled() and self.plugins.refresh.registrations.items.len > 0) {
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
                // #4251: default_params 미지원(es5..es2015)이면 전체(default/rest/
                // destructuring) lowering. object_spread 만 미지원(es2016/es2017)이면
                // object rest 든 param 만 — default-param-only 함수 불필요 lowering 회피.
                const needs_lowering = if (self.options.unsupported.default_params)
                    es2015_params.ES2015Params(Self).hasDefaultOrRest(self, params_list)
                else
                    es2015_params.ES2015Params(Self).hasObjectRestParam(self, params_list);
                if (!needs_lowering) continue;

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
                const params_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[e + 0]);
                if (params_idx.isNone() or @intFromEnum(params_idx) >= self.ast.nodes.items.len) continue;
                const params_node = self.ast.getNode(params_idx);
                if (params_node.tag != .formal_parameters) continue;
                const params_list = params_node.data.list;
                if (params_list.len == 0) continue;
                if (!es2015_params.ES2015Params(Self).hasObjectRestParam(self, params_list)) continue;
                // (이전 #4251 array-rest skip 제거: lowerParamsImpl 이 default_params
                //  지원 타겟에선 array-rest 를 native 유지하므로 arrow arguments 크래시
                //  없음. object rest 만 temp+body 분해.)
                var lr = try es2015_params.ES2015Params(Self).lowerParamsPass2(self, params_list, node.span);
                defer lr.body_stmts.deinit(self.allocator);

                const new_params_node = try self.ast.addFormalParameters(lr.new_params, params_node.span);
                self.ast.extra_data.items[e + 0] = @intFromEnum(new_params_node);

                if (lr.body_stmts.items.len > 0) {
                    const body_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[e + 1]);
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
                        self.ast.extra_data.items[e + 1] = @intFromEnum(new_body);
                    }
                }
            },
            else => {},
        }
    }
}
